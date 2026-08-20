//! Startup config-key migration framework.
//!
//! This is a deep, single-purpose module. It runs an idempotent pass at
//! startup that renames or relocates deprecated config keys so that an old
//! config.toml upgrades cleanly without operator intervention. Each migration
//! is idempotent: it only acts when the OLD key is present AND the NEW key is
//! absent, so re-running on every startup is safe and no persisted
//! "migrations applied" ledger is required.
//!
//! Reference behavior (Claude Code): migrations like
//! `migrateReplBridgeEnabledToRemoteControlAtStartup` copy an old key to a new
//! one, delete the old, and are idempotent. zcode keeps a bespoke TOML config
//! stack, so most of the Claude-only keys (replBridgeEnabled, autoUpdates,
//! bypassPermissionsModeAccepted, MCP-approval) have no zcode equivalent. This
//! module delivers the framework plus the migrations that DO map to a zcode
//! key. Adding zcode-native key renames later just appends to the
//! `migrations` list and reuses the line-oriented `renameTomlKey` helper.
//!
//! Design notes:
//! - TOML rewriting is line-oriented (NOT parse-and-serialize) so comments,
//!   blank lines, and unrelated keys keep their formatting. We only touch the
//!   single line that defines the deprecated key.
//! - Writes go through an atomic temp-file + rename so a crash mid-write never
//!   leaves a torn config.

const std = @import("std");
const rt = @import("zcode_runtime");
const paths = @import("paths.zig");

const log = std.log.scoped(.config_migrations);

/// Cap on the config file we will rewrite. Matches the 1 MiB config size
/// limit enforced in config_parse.zig. readFileAlloc(.limited(N)) yields
/// error.StreamTooLong (NOT error.FileTooBig) when exceeded; we treat that as
/// "do not touch" and skip the migration rather than failing startup.
const MAX_CONFIG_BYTES: usize = 1_048_576;

/// A single startup migration. `run` returns true when it changed something
/// on disk (for logging). It takes the absolute path to the user config.toml
/// so it can be exercised in tests against a tmp file.
pub const Migration = struct {
    name: []const u8,
    run: *const fn (allocator: std.mem.Allocator, config_path: []const u8) anyerror!bool,
};

/// The ordered list of startup migrations. Each is idempotent.
///
/// Currently this carries a single example migration (`old_example_key` ->
/// `new_example_key`). zcode has no historically-renamed config keys yet; the
/// example exists so the framework is exercised end to end and so the next
/// real rename is a one-line append here. The Claude-only key migrations
/// (replBridgeEnabled, autoUpdates, etc.) are intentionally absent because no
/// zcode key maps to them (see module doc and the phase plan Out-of-scope).
pub const migrations = [_]Migration{
    .{ .name = "old_example_key -> new_example_key", .run = migrateOldExampleKey },
};

/// Run every migration once against the user config.toml resolved from
/// `paths.resolve`. `cwd` is accepted for forward compatibility (a future
/// migration may relocate workspace/local config), but the current
/// migrations operate only on the user config. A missing config file is a
/// no-op. Never fails startup: a failing migration is logged and skipped.
pub fn runAll(allocator: std.mem.Allocator, cwd: []const u8) void {
    _ = cwd;
    var resolved = paths.resolve(allocator) catch |err| {
        log.warn("config migrations skipped: could not resolve paths: {s}", .{@errorName(err)});
        return;
    };
    defer resolved.deinit(allocator);
    runAllAtPath(allocator, resolved.user_config_path);
}

/// Run every migration against an explicit config path. Split out from
/// `runAll` so tests can target a tmp config.toml without touching the real
/// ~/.zcode.
pub fn runAllAtPath(allocator: std.mem.Allocator, config_path: []const u8) void {
    for (migrations) |m| {
        const changed = m.run(allocator, config_path) catch |err| {
            log.warn("config migration '{s}' failed: {s}", .{ m.name, @errorName(err) });
            continue;
        };
        if (changed) log.info("applied config migration: {s}", .{m.name});
    }
}

/// Example migration: rename `old_example_key` to `new_example_key`.
fn migrateOldExampleKey(allocator: std.mem.Allocator, config_path: []const u8) !bool {
    return renameTomlKey(allocator, config_path, "old_example_key", "new_example_key");
}

/// Line-oriented TOML key rename. Idempotent:
///   - no-op (returns false) if the file is missing,
///   - no-op if `old_key` is absent,
///   - if `new_key` is already present, still strips any stray `old_key`
///     line (the new value wins) and returns true only when a line changed.
///
/// Only the key token at the start of an assignment line is rewritten; the
/// value and any inline comment are preserved verbatim. Comments, blank
/// lines, and unrelated keys are left untouched. Section-qualified keys
/// (e.g. `[foo]` headers) are not matched - this renames top-level / flat
/// `key = value` lines, which is the shape zcode's config keys use.
pub fn renameTomlKey(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    old_key: []const u8,
    new_key: []const u8,
) !bool {
    const data = std.Io.Dir.cwd().readFileAlloc(rt.io, config_path, allocator, .limited(MAX_CONFIG_BYTES)) catch |err| switch (err) {
        error.FileNotFound => return false,
        // Treat an over-cap file as untouchable rather than failing startup.
        error.StreamTooLong => return false,
        else => return err,
    };
    defer allocator.free(data);

    const new_key_present = tomlHasKey(data, new_key);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var changed = false;
    var it = std.mem.splitScalar(u8, data, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(allocator, '\n');
        first = false;

        if (lineDefinesKey(line, old_key)) {
            changed = true;
            if (new_key_present) {
                // The new key already won; drop the stale old-key line by
                // skipping its content (the separating newline is handled by
                // the `first` bookkeeping above, so emit nothing here).
                continue;
            }
            // Rewrite the key token in place, preserving leading whitespace,
            // the assignment, value, and any inline comment.
            try rewriteKeyLine(allocator, &out, line, old_key, new_key);
        } else {
            try out.appendSlice(allocator, line);
        }
    }

    if (!changed) return false;

    try writeFileAtomic(allocator, config_path, out.items);
    return true;
}

/// True when `line` is a `<key> = ...` assignment for `key` (ignoring leading
/// whitespace). Does not match section headers or commented-out lines.
fn lineDefinesKey(line: []const u8, key: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (trimmed.len == 0 or trimmed[0] == '#') return false;
    if (!std.mem.startsWith(u8, trimmed, key)) return false;
    const rest = std.mem.trimStart(u8, trimmed[key.len..], " \t");
    return rest.len > 0 and rest[0] == '=';
}

/// True when any non-comment line in `data` defines `key`.
fn tomlHasKey(data: []const u8, key: []const u8) bool {
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (lineDefinesKey(line, key)) return true;
    }
    return false;
}

/// Emit `line` with the leading `old_key` token replaced by `new_key`,
/// preserving leading whitespace and everything from the `=` onward.
fn rewriteKeyLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    line: []const u8,
    old_key: []const u8,
    new_key: []const u8,
) !void {
    // Leading whitespace run.
    var lead: usize = 0;
    while (lead < line.len and (line[lead] == ' ' or line[lead] == '\t')) lead += 1;
    try out.appendSlice(allocator, line[0..lead]);
    try out.appendSlice(allocator, new_key);
    // Everything after the old key token (the inter-token whitespace, the
    // `=`, the value, and any inline comment) is preserved verbatim.
    try out.appendSlice(allocator, line[lead + old_key.len ..]);
}

/// Atomic write: temp file + rename, mode 0600. Mirrors the helper in
/// permission_rules.zig so a crash mid-write never tears the config.
fn writeFileAtomic(allocator: std.mem.Allocator, target: []const u8, bytes: []const u8) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{target});
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, bytes);
        file.sync(rt.io) catch {};
    }

    try std.Io.Dir.renameAbsolute(tmp_path, target, rt.io);
}

const testing = std.testing;
const test_helpers = @import("test_helpers.zig");

fn writeTmpConfig(tmp: *std.testing.TmpDir, contents: []const u8) !void {
    const file = try tmp.dir.createFile(rt.io, "config.toml", .{ .truncate = true });
    defer file.close(rt.io);
    try file.writeStreamingAll(rt.io, contents);
}

fn readTmpConfig(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(MAX_CONFIG_BYTES));
}

test "renameTomlKey: old present, new absent -> renamed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmpConfig(&tmp, "old_example_key = true\nother = 1\n");

    const path = try test_helpers.tmpDirPath(testing.allocator, &tmp, "config.toml");
    defer testing.allocator.free(path);

    const changed = try renameTomlKey(testing.allocator, path, "old_example_key", "new_example_key");
    try testing.expect(changed);

    const out = try readTmpConfig(testing.allocator, path);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "new_example_key = true") != null);
    try testing.expect(std.mem.indexOf(u8, out, "old_example_key") == null);
    // Unrelated key preserved.
    try testing.expect(std.mem.indexOf(u8, out, "other = 1") != null);
}

test "renameTomlKey: idempotent on second run" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmpConfig(&tmp, "old_example_key = true\n");

    const path = try test_helpers.tmpDirPath(testing.allocator, &tmp, "config.toml");
    defer testing.allocator.free(path);

    const first = try renameTomlKey(testing.allocator, path, "old_example_key", "new_example_key");
    try testing.expect(first);

    const second = try renameTomlKey(testing.allocator, path, "old_example_key", "new_example_key");
    try testing.expect(!second);

    const out = try readTmpConfig(testing.allocator, path);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "new_example_key = true") != null);
}

test "renameTomlKey: new key already present, old key dropped, new value preserved" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // New key already set to its own value; the stale old key must be removed
    // and the new value left untouched.
    try writeTmpConfig(&tmp, "new_example_key = false\nold_example_key = true\n");

    const path = try test_helpers.tmpDirPath(testing.allocator, &tmp, "config.toml");
    defer testing.allocator.free(path);

    const changed = try renameTomlKey(testing.allocator, path, "old_example_key", "new_example_key");
    try testing.expect(changed);

    const out = try readTmpConfig(testing.allocator, path);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "new_example_key = false") != null);
    try testing.expect(std.mem.indexOf(u8, out, "old_example_key") == null);
    // The old value (true) must NOT have leaked into the new key.
    try testing.expect(std.mem.indexOf(u8, out, "new_example_key = true") == null);
}

test "renameTomlKey: missing file is a no-op" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const path = try std.fs.path.join(testing.allocator, &.{ cwd, "config.toml" });
    defer testing.allocator.free(path);

    const changed = try renameTomlKey(testing.allocator, path, "old_example_key", "new_example_key");
    try testing.expect(!changed);
}

test "renameTomlKey: absent old key leaves file unchanged" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmpConfig(&tmp, "# a comment\nunrelated = 7\n");

    const path = try test_helpers.tmpDirPath(testing.allocator, &tmp, "config.toml");
    defer testing.allocator.free(path);

    const changed = try renameTomlKey(testing.allocator, path, "old_example_key", "new_example_key");
    try testing.expect(!changed);

    const out = try readTmpConfig(testing.allocator, path);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("# a comment\nunrelated = 7\n", out);
}

test "renameTomlKey: commented-out old key is not migrated" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmpConfig(&tmp, "# old_example_key = true\nkeep = 1\n");

    const path = try test_helpers.tmpDirPath(testing.allocator, &tmp, "config.toml");
    defer testing.allocator.free(path);

    const changed = try renameTomlKey(testing.allocator, path, "old_example_key", "new_example_key");
    try testing.expect(!changed);

    const out = try readTmpConfig(testing.allocator, path);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("# old_example_key = true\nkeep = 1\n", out);
}

test "renameTomlKey: preserves leading whitespace and inline comment" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmpConfig(&tmp, "  old_example_key   =  true  # note\n");

    const path = try test_helpers.tmpDirPath(testing.allocator, &tmp, "config.toml");
    defer testing.allocator.free(path);

    const changed = try renameTomlKey(testing.allocator, path, "old_example_key", "new_example_key");
    try testing.expect(changed);

    const out = try readTmpConfig(testing.allocator, path);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("  new_example_key   =  true  # note\n", out);
}

test "lineDefinesKey does not match a key that is a prefix of another" {
    // `old` must not match `old_example_key`.
    try testing.expect(!lineDefinesKey("old_example_key = 1", "old"));
    try testing.expect(lineDefinesKey("old_example_key = 1", "old_example_key"));
    try testing.expect(lineDefinesKey("  old_example_key=1", "old_example_key"));
    try testing.expect(!lineDefinesKey("[section]", "section"));
}

test "runAllAtPath applies the example migration end to end" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmpConfig(&tmp, "old_example_key = true\n");

    const path = try test_helpers.tmpDirPath(testing.allocator, &tmp, "config.toml");
    defer testing.allocator.free(path);

    runAllAtPath(testing.allocator, path);

    const out = try readTmpConfig(testing.allocator, path);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "new_example_key = true") != null);
    try testing.expect(std.mem.indexOf(u8, out, "old_example_key") == null);
}
