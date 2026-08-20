//! ui-dialogs-07 (PARTIAL): local FeedbackSurvey rating store.
//!
//! Ports the *local* half of the reference's FeedbackSurvey.tsx: an
//! interactive 1-5 rating with an optional free-text note. The reference
//! state machine (closed|open|thanks|transcript_prompt|submitting|submitted)
//! plus the cloud transcript-share submission are intentionally NOT ported --
//! zcode is provider-neutral and does not phone home (see the phase doc's
//! ui-dialogs-15 documented deviation). This module owns the persistence
//! side: appending a well-formed JSONL record to a local file. The overlay
//! chrome (the 1-5 Select + thanks screen) lives in
//! src/cli/repl_overlay.zig and the /feedback wiring lives in
//! src/cli/repl.zig.
//!
//! The append path mirrors core/logger.zig's JSONL writer: open-or-create
//! without truncating, then writePositionalAll at end-of-file (0.16 has no
//! seek/streaming-append cursor). std.json.fmt + appendNdjsonSafe keep the
//! line valid ndjson even when a note contains U+2028 / U+2029.

const std = @import("std");
const rt = @import("zcode_runtime");
const std_io = @import("std_io.zig");
const clock = @import("clock.zig");
const paths = @import("paths.zig");
const parse_helpers = @import("parse_helpers.zig");

/// Lowest and highest valid rating. Mirrors the reference's 1-5 scale.
pub const MIN_RATING: u8 = 1;
pub const MAX_RATING: u8 = 5;

/// True when `rating` is within the 1-5 inclusive scale. Pure so the overlay
/// can validate a keypress without touching disk.
pub fn isValidRating(rating: u8) bool {
    return rating >= MIN_RATING and rating <= MAX_RATING;
}

/// Allocator-owned absolute path to the local feedback log
/// (`<zcode_home>/feedback.jsonl`). Caller frees. Strictly local -- never
/// uploaded anywhere.
pub fn defaultFeedbackPath(allocator: std.mem.Allocator) ![]u8 {
    var path_set = try paths.resolve(allocator);
    defer path_set.deinit(allocator);
    return std.fs.path.join(allocator, &.{ path_set.zcode_home, "feedback.jsonl" });
}

/// Append a single feedback record to `path` as one JSONL line. Creates the
/// file (and is a no-op-safe open when it already exists) without truncating,
/// then writes the new line at end-of-file so prior records are preserved.
///
/// `note` may be empty (the note is optional in the survey). `version` is the
/// running zcode version string so a future reader can correlate ratings to
/// releases. The timestamp is `clock.nowMillis()` per project convention --
/// never `std.time.*`.
///
/// Pure-ish: the caller supplies the path, so tests point it at a tmp file.
pub fn appendRating(
    allocator: std.mem.Allocator,
    path: []const u8,
    rating: u8,
    note: []const u8,
    version: []const u8,
) !void {
    const ts = clock.nowMillis();

    // Stage the JSON into a scratch buffer, then run the ndjson-safe
    // post-processor over it before the trailing newline -- matches
    // core/logger.zig so a note containing U+2028/U+2029 cannot split the
    // line for a downstream reader.
    var scratch = std_io.StringBuilder.init(allocator);
    defer scratch.deinit();
    try scratch.writer().print("{f}", .{std.json.fmt(.{
        .ts = ts,
        .rating = rating,
        .note = note,
        .version = version,
    }, .{})});

    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    try parse_helpers.appendNdjsonSafe(&buf, scratch.items());
    try buf.append('\n');

    // Ensure the parent directory exists (first-ever feedback on a fresh
    // install lands before any other ~/.zcode write may have created it).
    if (std.fs.path.dirname(path)) |dir| {
        paths.ensureDir(dir) catch {};
    }

    // open-or-create without truncating, then append at EOF. 0.16 has no
    // streaming-append cursor, so compute the end offset explicitly.
    const file = try std.Io.Dir.cwd().createFile(rt.io, path, .{
        .read = true,
        .truncate = false,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    defer file.close(rt.io);

    const eof = try file.length(rt.io);
    _ = try file.writePositionalAll(rt.io, buf.items(), eof);
}

const testing = std.testing;
const test_helpers = @import("test_helpers.zig");

test "isValidRating accepts 1-5 and rejects out-of-range" {
    try testing.expect(isValidRating(1));
    try testing.expect(isValidRating(3));
    try testing.expect(isValidRating(5));
    try testing.expect(!isValidRating(0));
    try testing.expect(!isValidRating(6));
    try testing.expect(!isValidRating(255));
}

test "appendRating writes a well-formed JSONL line preserving the rating" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(dir_path);

    const path = try std.fs.path.join(alloc, &.{ dir_path, "feedback.jsonl" });
    defer alloc.free(path);

    try appendRating(alloc, path, 4, "loved the trust gate", "9.9.9+test");

    const content = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, alloc, .limited(64 * 1024));
    defer alloc.free(content);

    // Exactly one line, newline-terminated.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, "\n"));
    try testing.expect(std.mem.endsWith(u8, content, "\n"));

    // The line is valid JSON and the rating round-trips as 4.
    const line = std.mem.trim(u8, content, "\n");
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual(@as(i64, 4), obj.get("rating").?.integer);
    try testing.expectEqualStrings("loved the trust gate", obj.get("note").?.string);
    try testing.expectEqualStrings("9.9.9+test", obj.get("version").?.string);
    try testing.expect(obj.get("ts") != null);
}

test "appendRating appends without truncating prior records" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(dir_path);

    const path = try std.fs.path.join(alloc, &.{ dir_path, "feedback.jsonl" });
    defer alloc.free(path);

    try appendRating(alloc, path, 5, "", "9.9.9+test");
    try appendRating(alloc, path, 2, "needs work", "9.9.9+test");

    const content = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, alloc, .limited(64 * 1024));
    defer alloc.free(content);

    // Two records => two newline-terminated lines.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, content, "\n"));

    var it = std.mem.tokenizeScalar(u8, content, '\n');
    const first = it.next().?;
    const second = it.next().?;

    const p1 = try std.json.parseFromSlice(std.json.Value, alloc, first, .{});
    defer p1.deinit();
    try testing.expectEqual(@as(i64, 5), p1.value.object.get("rating").?.integer);

    const p2 = try std.json.parseFromSlice(std.json.Value, alloc, second, .{});
    defer p2.deinit();
    try testing.expectEqual(@as(i64, 2), p2.value.object.get("rating").?.integer);
    try testing.expectEqualStrings("needs work", p2.value.object.get("note").?.string);
}
