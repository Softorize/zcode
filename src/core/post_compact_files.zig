//! Post-compaction file restoration as context attachments.
//!
//! Port of the reference's `services/compact/compact.ts`
//! `createPostCompactFileAttachments` (compact.ts:1415-1464) and its
//! budgets (compact.ts:122-130). After a compaction wipes the
//! conversation down to a summary, the model loses the actual content
//! of files it had recently read. To preserve working context we
//! re-read up to N most-recently-read files, budgeted by a per-file
//! token cap and a total token budget, and re-inject them as
//! attachments the next prompt build can pick up.
//!
//! Files still present in the preserved tail (passed as
//! `preserved_paths`) are skipped to avoid duplicating content the
//! post-compact history already carries.
//!
//! The recency ordering comes from the read tracker
//! (`tools/file.recentReadPaths`); this module takes the already-sorted
//! path list so it stays a pure, hermetically-testable transform over
//! its inputs and the filesystem (no global tracker state).

const std = @import("std");
const rt = @import("zcode_runtime");
const types = @import("types.zig");
const std_io = @import("std_io.zig");

/// Maximum number of files to restore after a compaction.
/// Reference: POST_COMPACT_MAX_FILES_TO_RESTORE (compact.ts:122-130).
pub const MAX_FILES_TO_RESTORE: usize = 5;

/// Total token budget across all restored files.
/// Reference: POST_COMPACT_TOKEN_BUDGET.
pub const TOKEN_BUDGET: usize = 50_000;

/// Per-file token cap. A larger file is truncated to this many tokens.
/// Reference: POST_COMPACT_MAX_TOKENS_PER_FILE.
pub const MAX_TOKENS_PER_FILE: usize = 5_000;

/// One restored file: its absolute path and the (possibly truncated)
/// content re-read from disk. Both fields are heap-owned by the
/// allocator passed to `restore` and freed by `freeAttachments`.
pub const Attachment = struct {
    path: []const u8,
    content: []const u8,
    /// True when the file was larger than the per-file cap and the
    /// content was truncated to `per_file_cap` tokens.
    truncated: bool,
};

/// Free a slice returned by `restore`.
pub fn freeAttachments(allocator: std.mem.Allocator, attachments: []Attachment) void {
    for (attachments) |a| {
        allocator.free(a.path);
        allocator.free(a.content);
    }
    allocator.free(attachments);
}

/// Re-read up to `max_files` of `paths` (assumed sorted newest-first)
/// and return them as attachments, subject to the per-file and total
/// token budgets. Paths in `preserved_paths` are skipped. Unreadable
/// files are silently skipped. The returned slice and every contained
/// string are owned by `allocator`; free with `freeAttachments`.
///
/// `per_file_cap` and `total_budget` are token budgets; bytes are
/// converted with `types.estimateTokens` (~4 bytes/token). A file
/// whose estimated tokens exceed `per_file_cap` is read but truncated
/// to roughly `per_file_cap * 4` bytes (on a UTF-8 boundary-agnostic
/// byte cut, matching the reference's char-budget behavior).
pub fn restore(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
    preserved_paths: []const []const u8,
    max_files: usize,
    per_file_cap: usize,
    total_budget: usize,
) ![]Attachment {
    var out = std.array_list.Managed(Attachment).init(allocator);
    errdefer {
        for (out.items) |a| {
            allocator.free(a.path);
            allocator.free(a.content);
        }
        out.deinit();
    }

    var used_tokens: usize = 0;
    var taken: usize = 0;

    for (paths) |p| {
        if (taken >= max_files) break;
        if (isPreserved(p, preserved_paths)) continue;

        // Read with a hard byte ceiling so a giant file cannot blow
        // memory: cap at the per-file token budget (in bytes). Per
        // CLAUDE.md, readFileAlloc(.limited(N)) yields StreamTooLong
        // when the file exceeds N -- that is the "truncate to N" case,
        // not a hard error, so we fall back to a bounded read.
        const byte_cap = per_file_cap *| 4;
        var truncated = false;
        const raw: []u8 = std.Io.Dir.cwd().readFileAlloc(rt.io, p, allocator, .limited(byte_cap)) catch |err| switch (err) {
            error.StreamTooLong => blk: {
                // File is larger than the cap. Re-read exactly byte_cap
                // bytes so we still restore the head of the file.
                truncated = true;
                break :blk readTruncated(allocator, p, byte_cap) catch continue;
            },
            else => continue, // unreadable: skip
        };

        // Token accounting against the total budget. If adding this
        // file would exceed the budget, stop (the reference stops at
        // the first over-budget file rather than skipping ahead).
        const file_tokens = types.estimateTokens(raw);
        if (used_tokens + file_tokens > total_budget) {
            allocator.free(raw);
            break;
        }

        const path_dup = allocator.dupe(u8, p) catch {
            allocator.free(raw);
            return error.OutOfMemory;
        };
        out.append(.{ .path = path_dup, .content = raw, .truncated = truncated }) catch {
            allocator.free(path_dup);
            allocator.free(raw);
            return error.OutOfMemory;
        };
        used_tokens += file_tokens;
        taken += 1;
    }

    return out.toOwnedSlice();
}

/// Read at most `byte_cap` bytes from the head of the file at `path`.
/// Used when the file exceeds the per-file cap so we still restore its
/// leading content instead of dropping it entirely.
fn readTruncated(allocator: std.mem.Allocator, path: []const u8, byte_cap: usize) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(rt.io, path, .{});
    defer file.close(rt.io);
    const buf = try allocator.alloc(u8, byte_cap);
    errdefer allocator.free(buf);
    var off: usize = 0;
    while (off < byte_cap) {
        const n = file.readStreaming(rt.io, &.{buf[off..]}) catch break;
        if (n == 0) break;
        off += n;
    }
    if (off < byte_cap) {
        // Shrink to what we actually read.
        return allocator.realloc(buf, off);
    }
    return buf;
}

fn isPreserved(path: []const u8, preserved: []const []const u8) bool {
    for (preserved) |pp| {
        if (std.mem.eql(u8, path, pp)) return true;
    }
    return false;
}

/// Render restored attachments as a single block suitable for
/// injection as a system history turn. Returns null when there is
/// nothing to restore. The caller owns the returned string.
pub fn renderBlock(allocator: std.mem.Allocator, attachments: []const Attachment) !?[]u8 {
    if (attachments.len == 0) return null;

    var sb = std_io.StringBuilder.init(allocator);
    errdefer sb.deinit();
    const w = sb.writer();

    try w.writeAll("restored-files: re-reading recently-read files after compaction\n");
    for (attachments) |a| {
        try w.print("\n=== {s}", .{a.path});
        if (a.truncated) try w.writeAll(" (truncated)");
        try w.writeAll(" ===\n");
        try w.writeAll(a.content);
        if (a.content.len == 0 or a.content[a.content.len - 1] != '\n') {
            try w.writeByte('\n');
        }
    }
    return try sb.toOwnedSlice();
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;
const test_helpers = @import("test_helpers.zig");

test "restore returns recently-read files newest-first within budget" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "a.txt", .data = "alpha content\n" });
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "b.txt", .data = "bravo content\n" });
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "c.txt", .data = "charlie content\n" });

    const pa = try test_helpers.tmpDirPath(testing.allocator, &tmp, "a.txt");
    defer testing.allocator.free(pa);
    const pb = try test_helpers.tmpDirPath(testing.allocator, &tmp, "b.txt");
    defer testing.allocator.free(pb);
    const pc = try test_helpers.tmpDirPath(testing.allocator, &tmp, "c.txt");
    defer testing.allocator.free(pc);

    // Caller passes paths already sorted newest-first: c, b, a.
    const paths = [_][]const u8{ pc, pb, pa };
    const attachments = try restore(
        testing.allocator,
        &paths,
        &.{},
        MAX_FILES_TO_RESTORE,
        MAX_TOKENS_PER_FILE,
        TOKEN_BUDGET,
    );
    defer freeAttachments(testing.allocator, attachments);

    try testing.expectEqual(@as(usize, 3), attachments.len);
    try testing.expectEqualStrings(pc, attachments[0].path);
    try testing.expectEqualStrings("charlie content\n", attachments[0].content);
    try testing.expectEqualStrings(pb, attachments[1].path);
    try testing.expectEqualStrings(pa, attachments[2].path);
}

test "restore skips preserved paths" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "keep.txt", .data = "kept\n" });
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "drop.txt", .data = "dropped\n" });

    const pkeep = try test_helpers.tmpDirPath(testing.allocator, &tmp, "keep.txt");
    defer testing.allocator.free(pkeep);
    const pdrop = try test_helpers.tmpDirPath(testing.allocator, &tmp, "drop.txt");
    defer testing.allocator.free(pdrop);

    const paths = [_][]const u8{ pkeep, pdrop };
    const preserved = [_][]const u8{pkeep};
    const attachments = try restore(
        testing.allocator,
        &paths,
        &preserved,
        MAX_FILES_TO_RESTORE,
        MAX_TOKENS_PER_FILE,
        TOKEN_BUDGET,
    );
    defer freeAttachments(testing.allocator, attachments);

    try testing.expectEqual(@as(usize, 1), attachments.len);
    try testing.expectEqualStrings(pdrop, attachments[0].path);
}

test "restore drops a file that would exceed the total budget" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Two files of ~40 bytes each (~10 tokens). With a tiny total
    // budget of 12 tokens the first fits, the second is dropped.
    const blob = "0123456789" ** 4 ++ "\n"; // 41 bytes -> ~10 tokens
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "first.txt", .data = blob });
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "second.txt", .data = blob });

    const p1 = try test_helpers.tmpDirPath(testing.allocator, &tmp, "first.txt");
    defer testing.allocator.free(p1);
    const p2 = try test_helpers.tmpDirPath(testing.allocator, &tmp, "second.txt");
    defer testing.allocator.free(p2);

    const paths = [_][]const u8{ p1, p2 };
    const attachments = try restore(
        testing.allocator,
        &paths,
        &.{},
        MAX_FILES_TO_RESTORE,
        MAX_TOKENS_PER_FILE,
        12, // total_budget tokens: only the first ~10-token file fits
    );
    defer freeAttachments(testing.allocator, attachments);

    try testing.expectEqual(@as(usize, 1), attachments.len);
    try testing.expectEqualStrings(p1, attachments[0].path);
}

test "restore caps a large file to the per-file budget" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Per-file cap of 5 tokens -> 20 byte ceiling. Write 100 bytes.
    const big = "x" ** 100;
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "big.txt", .data = big });

    const pbig = try test_helpers.tmpDirPath(testing.allocator, &tmp, "big.txt");
    defer testing.allocator.free(pbig);

    const paths = [_][]const u8{pbig};
    const attachments = try restore(
        testing.allocator,
        &paths,
        &.{},
        MAX_FILES_TO_RESTORE,
        5, // per_file_cap tokens -> 20 byte ceiling
        TOKEN_BUDGET,
    );
    defer freeAttachments(testing.allocator, attachments);

    try testing.expectEqual(@as(usize, 1), attachments.len);
    try testing.expect(attachments[0].truncated);
    try testing.expectEqual(@as(usize, 20), attachments[0].content.len);
}

test "restore honors max_files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "one.txt", .data = "1\n" });
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "two.txt", .data = "2\n" });
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "three.txt", .data = "3\n" });

    const p1 = try test_helpers.tmpDirPath(testing.allocator, &tmp, "one.txt");
    defer testing.allocator.free(p1);
    const p2 = try test_helpers.tmpDirPath(testing.allocator, &tmp, "two.txt");
    defer testing.allocator.free(p2);
    const p3 = try test_helpers.tmpDirPath(testing.allocator, &tmp, "three.txt");
    defer testing.allocator.free(p3);

    const paths = [_][]const u8{ p1, p2, p3 };
    const attachments = try restore(
        testing.allocator,
        &paths,
        &.{},
        2, // max_files
        MAX_TOKENS_PER_FILE,
        TOKEN_BUDGET,
    );
    defer freeAttachments(testing.allocator, attachments);

    try testing.expectEqual(@as(usize, 2), attachments.len);
}

test "renderBlock returns null for empty and a block otherwise" {
    const empty = try renderBlock(testing.allocator, &.{});
    try testing.expect(empty == null);

    const att = [_]Attachment{
        .{ .path = "/tmp/x.txt", .content = "hello", .truncated = false },
    };
    const block = (try renderBlock(testing.allocator, &att)).?;
    defer testing.allocator.free(block);
    try testing.expect(std.mem.indexOf(u8, block, "restored-files:") != null);
    try testing.expect(std.mem.indexOf(u8, block, "/tmp/x.txt") != null);
    try testing.expect(std.mem.indexOf(u8, block, "hello") != null);
}
