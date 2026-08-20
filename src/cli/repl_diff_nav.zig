//! Multi-file diff navigator (ui-render-08).
//!
//! Reference: src/components/diff/DiffDialog.tsx, DiffFileList.tsx,
//! DiffDetailView.tsx, src/components/StructuredDiffList.tsx -- a
//! fullscreen navigable review listing each changed file with +/- stats
//! and a detail pane for the selected file's hunks.
//!
//! This task (Task 7) is marked DEFERABLE / L in the phase plan. Per the
//! plan's time-box recommendation we ship the load-bearing, unit-testable
//! pieces: the parse-to-file-list step (reusing the same "diff --git"
//! splitting loop that formatDiffBlock uses) and a static list render. The
//! interactive selection state machine (Up/Down + detail re-render) is
//! intentionally left for a later phase; formatDiffBlock already renders the
//! per-file hunks, so the detail pane can reuse renderDiffSection when the
//! interactive overlay is wired up.
//!
//! No allocation: callers supply a fixed Seg/DiffFile buffer; the slices in
//! each DiffFile point into the caller's diff_text and are only valid for as
//! long as that buffer lives.

const std = @import("std");

/// One changed file parsed out of a unified multi-file diff.
///
/// `path` is the post-image path (the `b/...` side of the `diff --git`
/// header, with the `b/` stripped) and points into the source diff text.
/// `section` is the full byte range for this file's diff (from its
/// `diff --git` header up to the next one, exclusive), also a slice into
/// the source text.
pub const DiffFile = struct {
    path: []const u8,
    added: usize = 0,
    removed: usize = 0,
    hunks: usize = 0,
    new_file: bool = false,
    deleted_file: bool = false,
    section: []const u8,
};

/// Default cap for the on-stack DiffFile buffer used by callers. Diffs with
/// more changed files than this still parse the first MAX_NAV_FILES; the
/// caller is expected to report the remainder.
pub const MAX_NAV_FILES: usize = 64;

/// Parse a unified multi-file diff into a list of per-file entries.
///
/// Splits on `diff --git ` exactly the way formatDiffBlock does, then for
/// each section extracts the path and counts +/- lines and hunks. Returns
/// the populated prefix of `out`. Stops early once `out` is full (the
/// remaining files are simply not parsed); callers that care about the
/// overflow can compare the returned length against a re-count, but for the
/// navigator the cap is large enough that overflow is not user-visible.
pub fn parseDiffFiles(diff_text: []const u8, out: []DiffFile) []DiffFile {
    var count: usize = 0;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, diff_text, cursor, "diff --git ")) |start| {
        const next = std.mem.indexOfPos(u8, diff_text, start + 1, "\ndiff --git ");
        const section_end = if (next) |idx| idx + 1 else diff_text.len;
        const section = diff_text[start..section_end];
        cursor = section_end;

        if (count >= out.len) break;

        const stats = countSectionStats(section);
        out[count] = .{
            .path = extractDiffPath(section) orelse "diff",
            .added = stats.added,
            .removed = stats.removed,
            .hunks = stats.hunks,
            .new_file = stats.new_file,
            .deleted_file = stats.deleted_file,
            .section = section,
        };
        count += 1;
    }
    return out[0..count];
}

const SectionStats = struct {
    added: usize = 0,
    removed: usize = 0,
    hunks: usize = 0,
    new_file: bool = false,
    deleted_file: bool = false,
};

fn countSectionStats(section: []const u8) SectionStats {
    var stats: SectionStats = .{};
    var line_iter = std.mem.splitScalar(u8, section, '\n');
    while (line_iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "@@")) {
            stats.hunks += 1;
        } else if (std.mem.startsWith(u8, line, "+") and !std.mem.startsWith(u8, line, "+++")) {
            stats.added += 1;
        } else if (std.mem.startsWith(u8, line, "-") and !std.mem.startsWith(u8, line, "---")) {
            stats.removed += 1;
        } else if (std.mem.startsWith(u8, line, "new file mode ")) {
            stats.new_file = true;
        } else if (std.mem.startsWith(u8, line, "deleted file mode ")) {
            stats.deleted_file = true;
        }
    }
    return stats;
}

fn extractDiffPath(section: []const u8) ?[]const u8 {
    const first_line = std.mem.sliceTo(section, '\n');
    if (!std.mem.startsWith(u8, first_line, "diff --git ")) return null;

    var it = std.mem.tokenizeScalar(u8, first_line, ' ');
    _ = it.next();
    _ = it.next();
    const a_path = it.next() orelse return null;
    const b_path = it.next() orelse a_path;

    if (std.mem.startsWith(u8, b_path, "b/")) return b_path[2..];
    if (std.mem.startsWith(u8, a_path, "a/")) return a_path[2..];
    return b_path;
}

/// Render a static file-list view: one line per file with a selection
/// marker and +/- stats. `selected` highlights the active row (the
/// interactive Up/Down handler is deferred; passing 0 just marks the first
/// row). This is the non-interactive list pane of the navigator.
pub fn renderFileList(writer: anytype, files: []const DiffFile, selected: usize) !void {
    if (files.len == 0) {
        try writer.writeAll("no changed files\n");
        return;
    }
    for (files, 0..) |file, idx| {
        const marker: []const u8 = if (idx == selected) "> " else "  ";
        const tag: []const u8 = if (file.new_file)
            " (new)"
        else if (file.deleted_file)
            " (deleted)"
        else
            "";
        try writer.print("{s}{s}  +{d} -{d}{s}\n", .{ marker, file.path, file.added, file.removed, tag });
    }
}

test "parseDiffFiles parses a two-file diff into two entries" {
    const diff =
        "diff --git a/src/old.zig b/src/old.zig\n" ++
        "index 111..222 100644\n" ++
        "--- a/src/old.zig\n" ++
        "+++ b/src/old.zig\n" ++
        "@@ -1,2 +1,2 @@\n" ++
        "-old one\n" ++
        "+new one\n" ++
        " context\n" ++
        "diff --git a/README.md b/README.md\n" ++
        "index 333..444 100644\n" ++
        "--- a/README.md\n" ++
        "+++ b/README.md\n" ++
        "@@ -1 +1,3 @@\n" ++
        " keep\n" ++
        "+added a\n" ++
        "+added b\n";

    var buf: [MAX_NAV_FILES]DiffFile = undefined;
    const files = parseDiffFiles(diff, &buf);

    try std.testing.expectEqual(@as(usize, 2), files.len);

    try std.testing.expectEqualStrings("src/old.zig", files[0].path);
    try std.testing.expectEqual(@as(usize, 1), files[0].added);
    try std.testing.expectEqual(@as(usize, 1), files[0].removed);
    try std.testing.expectEqual(@as(usize, 1), files[0].hunks);

    try std.testing.expectEqualStrings("README.md", files[1].path);
    try std.testing.expectEqual(@as(usize, 2), files[1].added);
    try std.testing.expectEqual(@as(usize, 0), files[1].removed);
    try std.testing.expectEqual(@as(usize, 1), files[1].hunks);
}

test "parseDiffFiles detects new and deleted files" {
    const diff =
        "diff --git a/created.txt b/created.txt\n" ++
        "new file mode 100644\n" ++
        "index 000..abc\n" ++
        "--- /dev/null\n" ++
        "+++ b/created.txt\n" ++
        "@@ -0,0 +1 @@\n" ++
        "+hello\n" ++
        "diff --git a/gone.txt b/gone.txt\n" ++
        "deleted file mode 100644\n" ++
        "index abc..000\n" ++
        "--- a/gone.txt\n" ++
        "+++ /dev/null\n" ++
        "@@ -1 +0,0 @@\n" ++
        "-bye\n";

    var buf: [MAX_NAV_FILES]DiffFile = undefined;
    const files = parseDiffFiles(diff, &buf);

    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expect(files[0].new_file);
    try std.testing.expect(!files[0].deleted_file);
    try std.testing.expectEqualStrings("created.txt", files[0].path);

    try std.testing.expect(files[1].deleted_file);
    try std.testing.expect(!files[1].new_file);
    try std.testing.expectEqualStrings("gone.txt", files[1].path);
}

test "parseDiffFiles returns empty on text with no diff header" {
    var buf: [MAX_NAV_FILES]DiffFile = undefined;
    const files = parseDiffFiles("just some prose with no git diff\n", &buf);
    try std.testing.expectEqual(@as(usize, 0), files.len);
}

test "parseDiffFiles respects the out buffer cap" {
    const diff =
        "diff --git a/one b/one\n@@ -1 +1 @@\n-a\n+b\n" ++
        "diff --git a/two b/two\n@@ -1 +1 @@\n-c\n+d\n" ++
        "diff --git a/three b/three\n@@ -1 +1 @@\n-e\n+f\n";

    var buf: [2]DiffFile = undefined;
    const files = parseDiffFiles(diff, &buf);
    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings("one", files[0].path);
    try std.testing.expectEqualStrings("two", files[1].path);
}

test "renderFileList marks the selected row and shows stats" {
    const diff =
        "diff --git a/alpha.zig b/alpha.zig\n@@ -1 +1,2 @@\n keep\n+added\n" ++
        "diff --git a/beta.zig b/beta.zig\n@@ -1,2 +1 @@\n-gone\n keep\n";

    var buf: [MAX_NAV_FILES]DiffFile = undefined;
    const files = parseDiffFiles(diff, &buf);

    var out: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    try renderFileList(&w, files, 1);
    const rendered = out[0..w.end];

    // Second row is selected.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "> beta.zig") != null);
    // First row not selected.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "  alpha.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "+1 -0") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "+0 -1") != null);
}

test "renderFileList handles empty file list" {
    var out: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    try renderFileList(&w, &[_]DiffFile{}, 0);
    try std.testing.expectEqualStrings("no changed files\n", out[0..w.end]);
}
