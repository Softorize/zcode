//! MCP blob spill-to-disk (mcp-08, Phase 6 Task 7).
//!
//! When an MCP tool returns a binary resource (audio, an image too large to
//! inline, or any non-image blob), inlining the base64 payload into the model
//! context is wasteful and often impossible. Claude Code's reference spills the
//! decoded bytes to a file on disk and feeds the model a small text block that
//! names the saved path plus the byte size (`persistBlobToTextBlock` /
//! `getBinaryBlobSavedMessage`, client.ts:2598-2627).
//!
//! This module is the disk side of that behaviour. It is deliberately pure
//! over an explicit `dir` argument so tests can spill into a `tmpDir` without
//! touching the real `~/.zcode` tree. `defaultSpillDir` resolves the
//! production location (`<zcode_home>/mcp-blobs`).

const std = @import("std");
const rt = @import("zcode_runtime");
const paths = @import("paths.zig");

/// Result of a successful spill: the absolute path the blob was written to and
/// the number of bytes written. Both are allocator-owned by the caller.
pub const SpillResult = struct {
    filepath: []u8,
    size: usize,

    pub fn deinit(self: *SpillResult, allocator: std.mem.Allocator) void {
        allocator.free(self.filepath);
    }
};

/// Map a MIME type to a reasonable file extension for the spilled blob. Falls
/// back to `bin` so the file is always nameable. Only the common MCP content
/// MIME types are mapped; anything unknown becomes `.bin`.
pub fn extensionForMime(mime_type: []const u8) []const u8 {
    const table = [_]struct { mime: []const u8, ext: []const u8 }{
        .{ .mime = "image/png", .ext = "png" },
        .{ .mime = "image/jpeg", .ext = "jpg" },
        .{ .mime = "image/jpg", .ext = "jpg" },
        .{ .mime = "image/gif", .ext = "gif" },
        .{ .mime = "image/webp", .ext = "webp" },
        .{ .mime = "image/svg+xml", .ext = "svg" },
        .{ .mime = "audio/wav", .ext = "wav" },
        .{ .mime = "audio/x-wav", .ext = "wav" },
        .{ .mime = "audio/mpeg", .ext = "mp3" },
        .{ .mime = "audio/mp3", .ext = "mp3" },
        .{ .mime = "audio/ogg", .ext = "ogg" },
        .{ .mime = "application/pdf", .ext = "pdf" },
        .{ .mime = "application/json", .ext = "json" },
        .{ .mime = "application/zip", .ext = "zip" },
        .{ .mime = "text/plain", .ext = "txt" },
        .{ .mime = "text/csv", .ext = "csv" },
    };
    for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(mime_type, entry.mime)) return entry.ext;
    }
    return "bin";
}

/// Whether a MIME type names an image we can pass through as an inline image
/// block rather than spilling. Mirrors the reference's image-vs-blob branch in
/// `transformResultContent`.
pub fn isImageMime(mime_type: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(mime_type, "image/");
}

/// Build a collision-resistant filename: `<server>-<millis>-<rand>.<ext>`. The
/// server segment is sanitised so a hostile server name cannot escape the
/// spill directory or inject path separators.
fn buildFilename(
    allocator: std.mem.Allocator,
    server_name: []const u8,
    mime_type: []const u8,
) ![]u8 {
    var safe = std.array_list.Managed(u8).init(allocator);
    defer safe.deinit();
    for (server_name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
        try safe.append(if (ok) c else '_');
    }
    if (safe.items.len == 0) try safe.appendSlice("server");

    var rand_bytes: [6]u8 = undefined;
    @import("rng.zig").secureBytes(&rand_bytes);
    const rand_hex = std.fmt.bytesToHex(rand_bytes, .lower);

    const ext = extensionForMime(mime_type);
    const millis = @import("clock.zig").nowMillis();

    return std.fmt.allocPrint(allocator, "{s}-{d}-{s}.{s}", .{ safe.items, millis, &rand_hex, ext });
}

/// Absolute path of the default spill directory (`<zcode_home>/mcp-blobs`).
/// Allocator-owned. Used by the client when no explicit dir is supplied.
pub fn defaultSpillDir(allocator: std.mem.Allocator) ![]u8 {
    var path_set = try paths.resolve(allocator);
    defer path_set.deinit(allocator);
    return std.fs.path.join(allocator, &.{ path_set.zcode_home, "mcp-blobs" });
}

/// Spill `bytes` to a freshly-named file inside `dir` (which must be an
/// absolute directory path; it is created if missing). Returns the absolute
/// file path and the byte count. The caller owns and frees the returned path.
///
/// `dir` is explicit so tests can target a `tmpDir`. Production callers pass
/// `defaultSpillDir`.
pub fn persistBlobToDir(
    allocator: std.mem.Allocator,
    dir: []const u8,
    bytes: []const u8,
    mime_type: []const u8,
    server_name: []const u8,
) !SpillResult {
    std.Io.Dir.cwd().createDirPath(rt.io, dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const filename = try buildFilename(allocator, server_name, mime_type);
    defer allocator.free(filename);

    const filepath = try std.fs.path.join(allocator, &.{ dir, filename });
    errdefer allocator.free(filepath);

    const file = try std.Io.Dir.cwd().createFile(rt.io, filepath, .{
        .truncate = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    defer file.close(rt.io);
    try file.writeStreamingAll(rt.io, bytes);

    return .{ .filepath = filepath, .size = bytes.len };
}

/// Convenience: spill to the production default spill dir.
pub fn persistBlob(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    mime_type: []const u8,
    server_name: []const u8,
) !SpillResult {
    const dir = try defaultSpillDir(allocator);
    defer allocator.free(dir);
    return persistBlobToDir(allocator, dir, bytes, mime_type, server_name);
}

/// Decode a base64 blob (standard alphabet, with padding) into freshly
/// allocated bytes. Returns `error.InvalidBase64` on malformed input. Caller
/// frees.
pub fn decodeBase64(allocator: std.mem.Allocator, b64: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(b64) catch return error.InvalidBase64;
    const out = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(out);
    decoder.decode(out, b64) catch return error.InvalidBase64;
    return out;
}

/// Format the small text block the model sees in place of the spilled blob.
/// Mirrors `getBinaryBlobSavedMessage`: names the saved path and byte size.
/// Caller frees.
pub fn savedMessage(
    allocator: std.mem.Allocator,
    filepath: []const u8,
    size: usize,
    mime_type: []const u8,
) ![]u8 {
    if (mime_type.len > 0) {
        return std.fmt.allocPrint(
            allocator,
            "[Binary content ({s}, {d} bytes) saved to {s}]",
            .{ mime_type, size, filepath },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "[Binary content ({d} bytes) saved to {s}]",
        .{ size, filepath },
    );
}

const testing = std.testing;
const test_helpers = @import("test_helpers.zig");

test "extensionForMime maps known types and falls back to bin" {
    try testing.expectEqualStrings("png", extensionForMime("image/png"));
    try testing.expectEqualStrings("jpg", extensionForMime("IMAGE/JPEG"));
    try testing.expectEqualStrings("wav", extensionForMime("audio/wav"));
    try testing.expectEqualStrings("bin", extensionForMime("application/x-unknown"));
}

test "isImageMime detects image types" {
    try testing.expect(isImageMime("image/png"));
    try testing.expect(isImageMime("IMAGE/WEBP"));
    try testing.expect(!isImageMime("audio/wav"));
    try testing.expect(!isImageMime(""));
}

test "decodeBase64 round-trips and rejects garbage" {
    const decoded = try decodeBase64(testing.allocator, "aGVsbG8=");
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings("hello", decoded);
    try testing.expectError(error.InvalidBase64, decodeBase64(testing.allocator, "!!!notbase64!!!"));
}

test "persistBlobToDir writes a binary blob and reports path + size" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(dir);

    const payload = [_]u8{ 0x00, 0x01, 0x02, 0xff, 0xfe };
    var result = try persistBlobToDir(testing.allocator, dir, &payload, "image/png", "demo-server");
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, payload.len), result.size);
    // The path is inside the requested spill dir...
    try testing.expect(std.mem.startsWith(u8, result.filepath, dir));
    // ...has the mapped extension...
    try testing.expect(std.mem.endsWith(u8, result.filepath, ".png"));
    // ...and the bytes actually landed on disk.
    const read_back = try std.Io.Dir.cwd().readFileAlloc(rt.io, result.filepath, testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(read_back);
    try testing.expectEqualSlices(u8, &payload, read_back);
}

test "persistBlobToDir sanitises a hostile server name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(dir);

    var result = try persistBlobToDir(testing.allocator, dir, "x", "application/octet-stream", "../../etc/passwd");
    defer result.deinit(testing.allocator);
    // No path-escape: the filename component must not contain a slash beyond
    // the spill dir prefix, so the whole path still lives under `dir`.
    const remainder = result.filepath[dir.len..];
    try testing.expect(std.mem.indexOf(u8, remainder[1..], "/") == null);
    try testing.expect(std.mem.indexOf(u8, remainder, "..") == null);
}

test "savedMessage names the path and byte size" {
    const with_mime = try savedMessage(testing.allocator, "/tmp/mcp-blobs/x.png", 1234, "image/png");
    defer testing.allocator.free(with_mime);
    try testing.expect(std.mem.indexOf(u8, with_mime, "/tmp/mcp-blobs/x.png") != null);
    try testing.expect(std.mem.indexOf(u8, with_mime, "1234") != null);
    try testing.expect(std.mem.indexOf(u8, with_mime, "image/png") != null);

    const no_mime = try savedMessage(testing.allocator, "/tmp/x.bin", 7, "");
    defer testing.allocator.free(no_mime);
    try testing.expect(std.mem.indexOf(u8, no_mime, "/tmp/x.bin") != null);
    try testing.expect(std.mem.indexOf(u8, no_mime, "7 bytes") != null);
}
