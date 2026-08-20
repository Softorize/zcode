const std = @import("std");
const std_io = @import("std_io.zig");

/// Parser for CHANGELOG.md-style release notes. Ported in spirit
/// from claude-code-main/src/utils/releaseNotes.ts (parseChangelog
/// + getAllReleaseNotes + getRecentReleaseNotes), adapted to
/// zcode's build-time embedding model: the CHANGELOG content is
/// baked into the binary via build_options.changelog (see
/// build.zig readChangelogContent), so the REPL can surface
/// curated release notes without a network dependency or a file
/// lookup relative to the installed binary's install location.
///
/// The parser recognises a heading structure like:
///
///   # Changelog
///   All notable changes...
///
///   ## Unreleased
///   - bullet one
///   - bullet two
///
///   ## 0.10.124 - 2026-04-13
///   - release-notes port
///   - something else
///
///   ### Subheading
///   - bullet under subheading is still captured
///
/// Sub-headings (### ...) pass through as ordinary lines and
/// their bullet lines get attributed to the enclosing version.
/// Version labels may carry an optional " - YYYY-MM-DD" suffix
/// which is stripped before display. Versions with zero bullets
/// (e.g. a stub `## 0.0.1` with only prose) are dropped.
pub const VersionEntry = struct {
    version: []u8,
    notes: [][]u8,

    pub fn deinit(self: *VersionEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.version);
        for (self.notes) |n| allocator.free(n);
        allocator.free(self.notes);
    }
};

/// Free a slice of entries returned by `parseChangelog`.
pub fn freeEntries(allocator: std.mem.Allocator, entries: []VersionEntry) void {
    for (entries) |*e| e.deinit(allocator);
    allocator.free(entries);
}

/// Parse a changelog markdown document into an ordered list of
/// {version, notes[]}. The returned slice is in the order the
/// versions appear in the document (typically newest-first in
/// keepachangelog.com style). Caller owns the slice, each inner
/// version slice, and each bullet string; free via `freeEntries`.
pub fn parseChangelog(allocator: std.mem.Allocator, content: []const u8) ![]VersionEntry {
    var out = std.array_list.Managed(VersionEntry).init(allocator);
    errdefer {
        for (out.items) |*e| e.deinit(allocator);
        out.deinit();
    }

    // Accumulator for the currently-open version section. version
    // is borrowed from `content` until we flush, at which point we
    // dupe it into an owned slice alongside the notes.
    var current_version: ?[]const u8 = null;
    var current_notes = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (current_notes.items) |n| allocator.free(n);
        current_notes.deinit();
    }

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");

        if (std.mem.startsWith(u8, line, "## ")) {
            // End of previous section -- flush if it has notes.
            if (current_version) |version| {
                if (current_notes.items.len > 0) {
                    const owned_notes = try current_notes.toOwnedSlice();
                    errdefer {
                        for (owned_notes) |n| allocator.free(n);
                        allocator.free(owned_notes);
                    }
                    const duped_version = try allocator.dupe(u8, version);
                    errdefer allocator.free(duped_version);
                    try out.append(.{
                        .version = duped_version,
                        .notes = owned_notes,
                    });
                    current_notes = std.array_list.Managed([]u8).init(allocator);
                }
            }

            // Begin the next section. Strip a " - date" suffix and
            // trim surrounding whitespace.
            const after = std.mem.trim(u8, line[3..], " \t");
            if (after.len == 0) {
                current_version = null;
                continue;
            }
            const dash_space = std.mem.indexOf(u8, after, " - ");
            const version_slice = if (dash_space) |idx| std.mem.trim(u8, after[0..idx], " \t") else after;
            current_version = if (version_slice.len > 0) version_slice else null;
            continue;
        }

        if (current_version == null) continue;

        // Collect bullet lines. We accept any line whose FIRST two
        // non-whitespace characters are "- "; the bullet content is
        // everything after that. Reference's parser only checks
        // line.trim().startsWith('- '), which matches both
        // top-level and nested bullets -- we do the same.
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len < 2) continue;
        if (trimmed[0] != '-' or trimmed[1] != ' ') continue;
        const bullet = std.mem.trim(u8, trimmed[2..], " \t");
        if (bullet.len == 0) continue;
        try current_notes.append(try allocator.dupe(u8, bullet));
    }

    // Final flush for the last section.
    if (current_version) |version| {
        if (current_notes.items.len > 0) {
            const owned_notes = try current_notes.toOwnedSlice();
            errdefer {
                for (owned_notes) |n| allocator.free(n);
                allocator.free(owned_notes);
            }
            const duped_version = try allocator.dupe(u8, version);
            errdefer allocator.free(duped_version);
            try out.append(.{
                .version = duped_version,
                .notes = owned_notes,
            });
            current_notes = std.array_list.Managed([]u8).init(allocator);
        }
    }

    return out.toOwnedSlice();
}

/// Pretty-print up to `max_versions` entries from `entries` for
/// display in a REPL slash command. Matches the reference's
/// release-notes.ts formatter: one "Version X:" header per section
/// with a middle-dot bullet per note. Caller owns the returned
/// slice.
pub fn formatRecent(
    allocator: std.mem.Allocator,
    entries: []const VersionEntry,
    max_versions: usize,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    if (entries.len == 0) {
        try out.writer().writeAll("release-notes: no changelog available.\n");
        return out.toOwnedSlice();
    }

    const take = @min(entries.len, max_versions);
    for (entries[0..take], 0..) |entry, idx| {
        if (idx > 0) try out.writer().writeAll("\n");
        try out.writer().print("Version {s}:\n", .{entry.version});
        for (entry.notes) |note| {
            try out.writer().print("  \xc2\xb7 {s}\n", .{note});
        }
    }
    return out.toOwnedSlice();
}

// ── Version-diff filter (release-notes-on-startup) ──────────────────
//
// Ported from claude-code-main/src/utils/releaseNotes.ts
// getRecentReleaseNotes (lines 207-240): filter the parsed changelog
// to versions strictly newer than the last-seen version, newest-first,
// capped at MAX_RELEASE_NOTES_SHOWN = 5. The reference coerces the SHA
// off both versions before the semver compare; we mirror that by
// stripping the "+<hash>" build-metadata suffix zcode's build appends
// to the user-facing version string (build.zig computeVersionString
// produces "X.Y.Z+<hash>" or "X.Y.Z+<hash>.dirty").

/// Default cap on how many version sections the startup surface shows,
/// matching the reference's MAX_RELEASE_NOTES_SHOWN.
pub const MAX_RELEASE_NOTES_SHOWN: usize = 5;

/// Strip a "+<build-metadata>" suffix from a version string so the
/// bare "X.Y.Z" core remains. Mirrors update.zig:78 (the existing
/// update-check code does the same split at the first '+').
pub fn stripBuildMetadata(version: []const u8) []const u8 {
    const plus = std.mem.indexOfScalar(u8, version, '+') orelse return version;
    return version[0..plus];
}

/// Compare two version strings by semver, falling back to a byte-order
/// comparison when either fails to parse. Mirrors update.zig:729
/// compareVersions; reproduced here (rather than imported) to keep the
/// changelog module self-contained -- update.zig's copy is file-private.
pub fn compareVersions(a: []const u8, b: []const u8) std.math.Order {
    const pa = std.SemanticVersion.parse(a) catch return std.mem.order(u8, a, b);
    const pb = std.SemanticVersion.parse(b) catch return std.mem.order(u8, a, b);
    return pa.order(pb);
}

/// Filter `entries` to the version sections strictly newer than
/// `last_seen_version`, newest-first, capped at `max`. The build-metadata
/// suffix on either version is stripped before the semver compare.
///
/// Returns an empty slice when `last_seen >= current` (no upgrade, or the
/// notes have already been seen) so the startup surface stays silent on a
/// non-upgrade launch. An empty `last_seen` is treated as "never seen": every
/// entry up to `current` is eligible (capped at `max`).
///
/// The returned slice and its inner allocations are fresh deep copies owned by
/// the caller; free them via `freeEntries`. The input `entries` are untouched.
pub fn recentSince(
    allocator: std.mem.Allocator,
    entries: []const VersionEntry,
    last_seen_version: []const u8,
    current_version: []const u8,
    max: usize,
) ![]VersionEntry {
    const last_seen = stripBuildMetadata(last_seen_version);
    const current = stripBuildMetadata(current_version);

    // No upgrade (or already at/ahead of current): nothing to surface. An
    // empty last_seen means "never seen" -- skip this short-circuit so the
    // first eligible run can still show notes.
    if (last_seen.len > 0 and compareVersions(last_seen, current) != .lt) {
        return allocator.alloc(VersionEntry, 0);
    }

    var out = std.array_list.Managed(VersionEntry).init(allocator);
    errdefer {
        for (out.items) |*e| e.deinit(allocator);
        out.deinit();
    }

    for (entries) |entry| {
        if (out.items.len >= max) break;
        const ver = stripBuildMetadata(entry.version);
        // Strictly newer than the last-seen version. When last_seen is empty
        // (never seen) every entry passes this gate.
        if (last_seen.len > 0 and compareVersions(ver, last_seen) != .gt) continue;
        try out.append(try dupeEntry(allocator, entry));
    }

    return out.toOwnedSlice();
}

/// Deep-copy a single entry so the returned slice owns independent storage.
fn dupeEntry(allocator: std.mem.Allocator, entry: VersionEntry) !VersionEntry {
    const version = try allocator.dupe(u8, entry.version);
    errdefer allocator.free(version);

    var notes = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (notes.items) |n| allocator.free(n);
        notes.deinit();
    }
    for (entry.notes) |note| {
        try notes.append(try allocator.dupe(u8, note));
    }
    return .{ .version = version, .notes = try notes.toOwnedSlice() };
}

/// Combine the embedded-changelog parse + the version-diff filter, returning
/// the version sections newer than `last_seen_version` (newest-first, capped at
/// `MAX_RELEASE_NOTES_SHOWN`). This is the startup-surface equivalent of the
/// reference's checkForReleaseNotes (releaseNotes.ts:287-327). Returns an empty
/// slice when there is nothing new to show (no upgrade, empty changelog, or a
/// parse failure -- the startup surface must never error). Caller owns the
/// result; free via `freeEntries`.
pub fn checkForReleaseNotes(
    allocator: std.mem.Allocator,
    embedded_changelog: []const u8,
    last_seen_version: []const u8,
    current_version: []const u8,
) []VersionEntry {
    const empty: []VersionEntry = &.{};
    if (embedded_changelog.len == 0) return empty;

    const entries = parseChangelog(allocator, embedded_changelog) catch return empty;
    defer freeEntries(allocator, entries);

    return recentSince(
        allocator,
        entries,
        last_seen_version,
        current_version,
        MAX_RELEASE_NOTES_SHOWN,
    ) catch empty;
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "parseChangelog returns an empty slice on empty input" {
    const entries = try parseChangelog(testing.allocator, "");
    defer freeEntries(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "parseChangelog recognises multiple version headers" {
    const content =
        \\# Changelog
        \\
        \\## 1.2.3
        \\- first note
        \\- second note
        \\
        \\## 1.2.2
        \\- older note
        \\
    ;
    const entries = try parseChangelog(testing.allocator, content);
    defer freeEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("1.2.3", entries[0].version);
    try testing.expectEqual(@as(usize, 2), entries[0].notes.len);
    try testing.expectEqualStrings("first note", entries[0].notes[0]);
    try testing.expectEqualStrings("second note", entries[0].notes[1]);
    try testing.expectEqualStrings("1.2.2", entries[1].version);
    try testing.expectEqual(@as(usize, 1), entries[1].notes.len);
    try testing.expectEqualStrings("older note", entries[1].notes[0]);
}

test "parseChangelog strips trailing date from version header" {
    const content =
        \\## 0.10.100 - 2026-04-13
        \\- shipped today
    ;
    const entries = try parseChangelog(testing.allocator, content);
    defer freeEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("0.10.100", entries[0].version);
}

test "parseChangelog handles Unreleased section" {
    const content =
        \\# Changelog
        \\
        \\## Unreleased
        \\- pending change
    ;
    const entries = try parseChangelog(testing.allocator, content);
    defer freeEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("Unreleased", entries[0].version);
}

test "parseChangelog captures bullets under sub-headings" {
    const content =
        \\## 0.6.0
        \\
        \\### Security
        \\- bump crypto
        \\- patch auth
        \\
        \\### Resilience
        \\- circuit breaker
    ;
    const entries = try parseChangelog(testing.allocator, content);
    defer freeEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(@as(usize, 3), entries[0].notes.len);
    try testing.expectEqualStrings("bump crypto", entries[0].notes[0]);
    try testing.expectEqualStrings("patch auth", entries[0].notes[1]);
    try testing.expectEqualStrings("circuit breaker", entries[0].notes[2]);
}

test "parseChangelog drops versions with no bullets" {
    const content =
        \\## 0.0.1
        \\Some prose without any bullets.
        \\
        \\## 0.0.2
        \\- this one has a bullet
    ;
    const entries = try parseChangelog(testing.allocator, content);
    defer freeEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("0.0.2", entries[0].version);
}

test "parseChangelog ignores preamble before the first version header" {
    const content =
        \\# Changelog
        \\
        \\All notable changes to this project.
        \\- this bullet is NOT inside a version section
        \\
        \\## 1.0.0
        \\- first release
    ;
    const entries = try parseChangelog(testing.allocator, content);
    defer freeEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("1.0.0", entries[0].version);
    try testing.expectEqual(@as(usize, 1), entries[0].notes.len);
    try testing.expectEqualStrings("first release", entries[0].notes[0]);
}

test "parseChangelog flushes the final section without a trailing newline" {
    const content =
        \\## 2.0.0
        \\- last bullet
    ;
    const entries = try parseChangelog(testing.allocator, content);
    defer freeEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("2.0.0", entries[0].version);
    try testing.expectEqualStrings("last bullet", entries[0].notes[0]);
}

test "formatRecent limits output to max_versions" {
    const content =
        \\## 3.0.0
        \\- three
        \\## 2.0.0
        \\- two
        \\## 1.0.0
        \\- one
    ;
    const entries = try parseChangelog(testing.allocator, content);
    defer freeEntries(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 3), entries.len);

    const formatted = try formatRecent(testing.allocator, entries, 2);
    defer testing.allocator.free(formatted);

    try testing.expect(std.mem.indexOf(u8, formatted, "Version 3.0.0") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "Version 2.0.0") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "Version 1.0.0") == null);
    try testing.expect(std.mem.indexOf(u8, formatted, "\xc2\xb7 three") != null);
}

test "formatRecent handles empty entries cleanly" {
    const formatted = try formatRecent(testing.allocator, &.{}, 5);
    defer testing.allocator.free(formatted);
    try testing.expect(std.mem.indexOf(u8, formatted, "no changelog available") != null);
}

const sample_changelog =
    \\## 3.0.0
    \\- three
    \\## 2.0.0
    \\- two
    \\## 1.0.0
    \\- one
;

test "recentSince returns only versions newer than last_seen" {
    const entries = try parseChangelog(testing.allocator, sample_changelog);
    defer freeEntries(testing.allocator, entries);

    const recent = try recentSince(testing.allocator, entries, "2.0.0", "3.0.0", 5);
    defer freeEntries(testing.allocator, recent);

    try testing.expectEqual(@as(usize, 1), recent.len);
    try testing.expectEqualStrings("3.0.0", recent[0].version);
}

test "recentSince returns empty when already at current (already seen)" {
    const entries = try parseChangelog(testing.allocator, sample_changelog);
    defer freeEntries(testing.allocator, entries);

    const recent = try recentSince(testing.allocator, entries, "3.0.0", "3.0.0", 5);
    defer freeEntries(testing.allocator, recent);

    try testing.expectEqual(@as(usize, 0), recent.len);
}

test "recentSince strips build-metadata suffix before comparison" {
    const entries = try parseChangelog(testing.allocator, sample_changelog);
    defer freeEntries(testing.allocator, entries);

    // last_seen carries a "+<hash>" suffix; current is the bare version. With
    // the suffix stripped both coerce to 3.0.0, so this is "already seen" and
    // nothing is surfaced.
    const recent = try recentSince(testing.allocator, entries, "3.0.0+abc1234", "3.0.0", 5);
    defer freeEntries(testing.allocator, recent);
    try testing.expectEqual(@as(usize, 0), recent.len);

    // The reverse: a "+<hash>.dirty" suffix on current must also be stripped so
    // an upgrade from 2.0.0 to 3.0.0 still surfaces the 3.0.0 entry.
    const recent2 = try recentSince(testing.allocator, entries, "2.0.0", "3.0.0+def5678.dirty", 5);
    defer freeEntries(testing.allocator, recent2);
    try testing.expectEqual(@as(usize, 1), recent2.len);
    try testing.expectEqualStrings("3.0.0", recent2[0].version);
}

test "recentSince treats empty last_seen as never-seen and caps at max" {
    const entries = try parseChangelog(testing.allocator, sample_changelog);
    defer freeEntries(testing.allocator, entries);

    // Empty last_seen => every entry eligible, but the cap of 2 limits the
    // result to the two newest (newest-first ordering preserved).
    const recent = try recentSince(testing.allocator, entries, "", "3.0.0", 2);
    defer freeEntries(testing.allocator, recent);

    try testing.expectEqual(@as(usize, 2), recent.len);
    try testing.expectEqualStrings("3.0.0", recent[0].version);
    try testing.expectEqualStrings("2.0.0", recent[1].version);
}

test "recentSince returns multiple newer versions newest-first" {
    const entries = try parseChangelog(testing.allocator, sample_changelog);
    defer freeEntries(testing.allocator, entries);

    const recent = try recentSince(testing.allocator, entries, "1.0.0", "3.0.0", 5);
    defer freeEntries(testing.allocator, recent);

    try testing.expectEqual(@as(usize, 2), recent.len);
    try testing.expectEqualStrings("3.0.0", recent[0].version);
    try testing.expectEqualStrings("2.0.0", recent[1].version);
}

test "checkForReleaseNotes filters embedded changelog by version diff" {
    const recent = checkForReleaseNotes(testing.allocator, sample_changelog, "2.0.0", "3.0.0");
    defer freeEntries(testing.allocator, recent);

    try testing.expectEqual(@as(usize, 1), recent.len);
    try testing.expectEqualStrings("3.0.0", recent[0].version);
    try testing.expectEqual(@as(usize, 1), recent[0].notes.len);
    try testing.expectEqualStrings("three", recent[0].notes[0]);
}

test "checkForReleaseNotes returns empty on an empty changelog" {
    const recent = checkForReleaseNotes(testing.allocator, "", "1.0.0", "3.0.0");
    defer freeEntries(testing.allocator, recent);
    try testing.expectEqual(@as(usize, 0), recent.len);
}

test "stripBuildMetadata strips the +hash suffix" {
    try testing.expectEqualStrings("0.11.73", stripBuildMetadata("0.11.73+abcd1234"));
    try testing.expectEqualStrings("0.11.73", stripBuildMetadata("0.11.73+abcd1234.dirty"));
    try testing.expectEqualStrings("0.11.73", stripBuildMetadata("0.11.73"));
}
