//! Binary-content persistence for WebFetch.
//!
//! Ports the reference's `isBinaryContentType` + `persistBinaryContent`
//! (claude-code-main/src/tools/WebFetchTool/utils.ts:442-449). When a fetch
//! returns a binary body (PDF, image, archive, ...) we cannot return the bytes
//! to the model as text, so we write them to a session-scoped artifacts dir on
//! disk and append a note with the path. The model can then hand that path to a
//! file-aware tool (Read on a PDF, etc.) rather than choking on binary noise.
//!
//! This mirrors the existing `core/tool_artifacts.zig` directory layout
//! (`<sessions_dir>/<session>.artifacts/`) so all session-scoped artifacts live
//! together; the only difference is we keep the original bytes verbatim and
//! derive the file extension from the MIME type instead of always using `.txt`.

const std = @import("std");
const rng = @import("rng.zig");
const rt = @import("zcode_runtime");
const clock = @import("clock.zig");
const paths = @import("paths.zig");

pub const PersistedBinary = struct {
    path: []u8,
    size: usize,

    pub fn deinit(self: *PersistedBinary, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

/// True when the Content-Type names a binary payload that should be persisted
/// to disk rather than returned inline as text. Matches the reference's
/// `isBinaryContentType`: PDFs, octet-stream, images, audio, video, and common
/// archive types. Comparison is case-insensitive and tolerant of a trailing
/// `; charset=...` (we look only at the bare type/subtype prefix).
pub fn isBinaryContentType(content_type: []const u8) bool {
    const ct = bareContentType(content_type);
    if (ct.len == 0) return false;

    // Whole-type prefixes (any subtype counts as binary).
    const prefixes = [_][]const u8{ "image/", "audio/", "video/" };
    for (prefixes) |p| {
        if (ct.len >= p.len and std.ascii.eqlIgnoreCase(ct[0..p.len], p)) return true;
    }

    // Exact application/* binary types.
    const exact = [_][]const u8{
        "application/pdf",
        "application/octet-stream",
        "application/zip",
        "application/gzip",
        "application/x-gzip",
        "application/x-tar",
        "application/x-7z-compressed",
        "application/x-rar-compressed",
        "application/vnd.ms-excel",
        "application/msword",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/wasm",
        "font/woff",
        "font/woff2",
    };
    for (exact) |e| {
        if (std.ascii.eqlIgnoreCase(ct, e)) return true;
    }
    return false;
}

/// Strip a trailing `; charset=...` (or any `;`-delimited parameter) and
/// surrounding whitespace from a Content-Type, leaving the bare `type/subtype`.
fn bareContentType(content_type: []const u8) []const u8 {
    var ct = std.mem.trim(u8, content_type, " \t\r\n");
    if (std.mem.indexOfScalar(u8, ct, ';')) |semi| {
        ct = std.mem.trim(u8, ct[0..semi], " \t\r\n");
    }
    return ct;
}

/// Map a Content-Type to a sensible file extension (with leading dot). Defaults
/// to `.bin` for anything we do not have a specific mapping for, so persisted
/// files always have an extension.
pub fn extensionForMime(content_type: []const u8) []const u8 {
    const ct = bareContentType(content_type);
    const Pair = struct { mime: []const u8, ext: []const u8 };
    const table = [_]Pair{
        .{ .mime = "application/pdf", .ext = ".pdf" },
        .{ .mime = "application/zip", .ext = ".zip" },
        .{ .mime = "application/gzip", .ext = ".gz" },
        .{ .mime = "application/x-gzip", .ext = ".gz" },
        .{ .mime = "application/x-tar", .ext = ".tar" },
        .{ .mime = "application/x-7z-compressed", .ext = ".7z" },
        .{ .mime = "application/x-rar-compressed", .ext = ".rar" },
        .{ .mime = "application/wasm", .ext = ".wasm" },
        .{ .mime = "image/png", .ext = ".png" },
        .{ .mime = "image/jpeg", .ext = ".jpg" },
        .{ .mime = "image/gif", .ext = ".gif" },
        .{ .mime = "image/webp", .ext = ".webp" },
        .{ .mime = "image/svg+xml", .ext = ".svg" },
        .{ .mime = "audio/mpeg", .ext = ".mp3" },
        .{ .mime = "audio/wav", .ext = ".wav" },
        .{ .mime = "video/mp4", .ext = ".mp4" },
        .{ .mime = "font/woff", .ext = ".woff" },
        .{ .mime = "font/woff2", .ext = ".woff2" },
    };
    for (table) |pair| {
        if (std.ascii.eqlIgnoreCase(ct, pair.mime)) return pair.ext;
    }
    return ".bin";
}

/// Persist raw binary `bytes` to a session-scoped artifacts dir, deriving the
/// file extension from `content_type`. Resolves the real sessions dir under
/// `~/.zcode/sessions`; tests should call `persistBinaryContentInDir` with a
/// `tmpDirPath` to avoid writing into the user's home.
pub fn persistBinaryContent(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    bytes: []const u8,
    content_type: []const u8,
) !PersistedBinary {
    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);
    return persistBinaryContentInDir(allocator, resolved.sessions_dir, session_id, bytes, content_type);
}

pub fn persistBinaryContentInDir(
    allocator: std.mem.Allocator,
    sessions_dir: []const u8,
    session_id: []const u8,
    bytes: []const u8,
    content_type: []const u8,
) !PersistedBinary {
    const safe_session = try sanitizeSegment(allocator, session_id, "session");
    defer allocator.free(safe_session);

    const artifact_dirname = try std.fmt.allocPrint(allocator, "{s}.artifacts", .{safe_session});
    defer allocator.free(artifact_dirname);
    const artifact_dir = try std.fs.path.join(allocator, &.{ sessions_dir, artifact_dirname });
    defer allocator.free(artifact_dir);
    try std.Io.Dir.cwd().createDirPath(rt.io, artifact_dir);

    const ext = extensionForMime(content_type);
    const nonce = rng.int(u32);
    const filename = try std.fmt.allocPrint(allocator, "web_fetch-{d}-{x}{s}", .{ clock.nowSeconds(), nonce, ext });
    defer allocator.free(filename);
    const path = try std.fs.path.join(allocator, &.{ artifact_dir, filename });
    errdefer allocator.free(path);

    try writeFileAtomic(allocator, path, bytes);
    return .{ .path = path, .size = bytes.len };
}

/// Build the note appended to a WebFetch result when the body was binary and
/// persisted to disk. Mirrors the reference shape
/// (claude-code-main/src/tools/WebFetchTool.ts:280-285):
///   `[Binary content (<content_type>, <size> bytes) also saved to <path>]`
/// Pure -- unit-testable without touching the filesystem. Owned; caller frees.
pub fn persistedNote(
    allocator: std.mem.Allocator,
    content_type: []const u8,
    size: usize,
    path: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "\n\n[Binary content ({s}, {d} bytes) also saved to {s}]",
        .{ bareContentType(content_type), size, path },
    );
}

fn sanitizeSegment(allocator: std.mem.Allocator, raw: []const u8, fallback: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    for (raw) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.') {
            try list.append(allocator, ch);
        } else {
            try list.append(allocator, '_');
        }
    }
    if (list.items.len == 0) try list.appendSlice(allocator, fallback);
    return list.toOwnedSlice(allocator);
}

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

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "isBinaryContentType: pdf and octet-stream are binary, html is not" {
    try testing.expect(isBinaryContentType("application/pdf"));
    try testing.expect(isBinaryContentType("application/octet-stream"));
    try testing.expect(isBinaryContentType("image/png"));
    try testing.expect(isBinaryContentType("audio/mpeg"));
    try testing.expect(isBinaryContentType("video/mp4"));
    try testing.expect(isBinaryContentType("application/zip"));
    // Tolerates a trailing charset parameter.
    try testing.expect(isBinaryContentType("application/pdf; charset=binary"));
    // Text types are NOT binary.
    try testing.expect(!isBinaryContentType("text/html"));
    try testing.expect(!isBinaryContentType("text/html; charset=utf-8"));
    try testing.expect(!isBinaryContentType("application/json"));
    try testing.expect(!isBinaryContentType("text/plain"));
    try testing.expect(!isBinaryContentType(""));
}

test "isBinaryContentType: case-insensitive" {
    try testing.expect(isBinaryContentType("APPLICATION/PDF"));
    try testing.expect(isBinaryContentType("Image/JPEG"));
}

test "extensionForMime maps known types and defaults to .bin" {
    try testing.expectEqualStrings(".pdf", extensionForMime("application/pdf"));
    try testing.expectEqualStrings(".pdf", extensionForMime("application/pdf; charset=binary"));
    try testing.expectEqualStrings(".png", extensionForMime("image/png"));
    try testing.expectEqualStrings(".zip", extensionForMime("application/zip"));
    try testing.expectEqualStrings(".bin", extensionForMime("application/x-unknown"));
}

test "persistedNote formats the documented binary-saved note" {
    const note = try persistedNote(testing.allocator, "application/pdf; charset=binary", 4096, "/tmp/sessions/s.artifacts/web_fetch-1-ab.pdf");
    defer testing.allocator.free(note);
    try testing.expect(std.mem.indexOf(u8, note, "[Binary content (application/pdf, 4096 bytes) also saved to /tmp/sessions/s.artifacts/web_fetch-1-ab.pdf]") != null);
    // The note begins with a blank-line separator so it does not glue onto prior text.
    try testing.expect(std.mem.startsWith(u8, note, "\n\n[Binary content"));
}

test "persistBinaryContentInDir writes bytes with mime-derived extension" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const sessions_dir = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    const pdf_bytes = "%PDF-1.4\nfake pdf body\n%%EOF";
    var persisted = try persistBinaryContentInDir(testing.allocator, sessions_dir, "session/1", pdf_bytes, "application/pdf");
    defer persisted.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, persisted.path, "session_1.artifacts") != null);
    try testing.expect(std.mem.endsWith(u8, persisted.path, ".pdf"));
    try testing.expectEqual(@as(usize, pdf_bytes.len), persisted.size);

    const loaded = try std.Io.Dir.cwd().readFileAlloc(rt.io, persisted.path, testing.allocator, .limited(4096));
    defer testing.allocator.free(loaded);
    try testing.expectEqualStrings(pdf_bytes, loaded);
}
