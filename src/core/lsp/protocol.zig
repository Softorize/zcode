//! Shared JSON-RPC framing helpers for the persistent LSP subsystem (parity
//! lsp-02). Lifted out of the inline framing code in `tools/lsp.zig` so the
//! persistent server path and the stateless fallback can share one
//! implementation of Content-Length framing.
//!
//! Pure-ish: framing/format helpers allocate via the passed allocator and do
//! no IO of their own. The blocking frame reader takes an `std.Io.File` and
//! `std.Io` so it can be driven by either a background reader thread or a
//! synchronous test.

const std = @import("std");
const std_io = @import("../std_io.zig");
const rt = @import("zcode_runtime");

/// Write a framed JSON-RPC message (Content-Length header + CRLF CRLF + body)
/// to `w`. `w` is any `std.Io.Writer`-style sink (StringBuilder.writer()).
pub fn writeFrame(w: anytype, body: []const u8) !void {
    try w.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try w.writeAll(body);
}

/// Build a framed message into an owned, allocator-backed slice. Convenience
/// for callers that want the bytes to hand to a single `writeStreamingAll`.
pub fn frame(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    try writeFrame(buf.writer(), body);
    return buf.toOwnedSlice();
}

/// The decoded shape of one inbound JSON-RPC message, after framing is
/// stripped. The caller inspects `id`/`method` to decide whether it is a
/// response (id, no method), a server-initiated request (id + method), or a
/// notification (method, no id).
pub const Message = struct {
    /// The numeric request id if present. JSON-RPC ids may be strings too, but
    /// every id we emit is numeric, so we only track numeric ids for matching.
    id: ?i64,
    /// The method name for requests/notifications; null for responses.
    method: ?[]const u8,
    /// True when the message carries a top-level `result` field.
    has_result: bool,
    /// The JSON-RPC error code if the message carries an `error` object, else
    /// null. Surfaced so the retry path (lsp-06) can classify -32801.
    error_code: ?i64,

    pub fn kind(self: Message) Kind {
        if (self.id != null and self.method != null) return .server_request;
        if (self.method != null) return .notification;
        return .response;
    }
};

pub const Kind = enum { response, notification, server_request };

/// JSON-RPC error code a server returns when the document content changed out
/// from under an in-flight request (e.g. rust-analyzer still indexing on the
/// first hover/definition of a large project). Mirrors the reference's
/// `LSP_ERROR_CONTENT_MODIFIED = -32801` (LSPServerInstance.ts:17-28). lsp-06
/// retries the request with backoff when this code is seen.
pub const LSP_ERROR_CONTENT_MODIFIED: i64 = -32801;

/// Max retries for a transient (ContentModified) error before giving up and
/// returning the last response to the caller. Mirrors the reference's
/// `MAX_RETRIES_FOR_TRANSIENT_ERRORS = 3` (LSPServerInstance.ts:17-28).
pub const MAX_RETRIES_FOR_TRANSIENT_ERRORS: u32 = 3;

/// Whether a JSON-RPC `error.code` is a transient error worth retrying. Today
/// only ContentModified (-32801) qualifies; every other code (including success
/// with no error, represented by `null`) is terminal. Pure -- unit-testable
/// without a live server.
pub fn isRetryableErrorCode(code: ?i64) bool {
    const c = code orelse return false;
    return c == LSP_ERROR_CONTENT_MODIFIED;
}

/// Parse a framed-stripped response body and return its JSON-RPC `error.code`
/// if it carries one, else null. Used by the lsp-06 retry loop to classify a
/// `sendRequest` response without re-deriving the full `Message`. Returns null
/// on malformed JSON or a body with no `error` object (the caller treats null
/// as "not retryable", i.e. a success or a terminal failure).
pub fn responseErrorCode(allocator: std.mem.Allocator, body: []const u8) ?i64 {
    const msg = (classify(allocator, body) catch return null) orelse return null;
    if (msg.method) |m| allocator.free(m);
    return msg.error_code;
}

/// Classify a JSON-RPC message body (the unframed JSON object text) into the
/// fields the dispatcher branches on. Parses with an arena owned by the
/// caller's `allocator` slice lifetime: the returned `method` points into a
/// freshly-`dupe`d slice owned by `allocator` (so it outlives any internal
/// arena). Returns null on malformed JSON (caller drops the frame rather than
/// crashing the reader loop).
pub fn classify(allocator: std.mem.Allocator, body: []const u8) !?Message {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const obj = parsed.value.object;

    var id: ?i64 = null;
    if (obj.get("id")) |idv| {
        if (idv == .integer) id = idv.integer;
    }

    var method: ?[]const u8 = null;
    if (obj.get("method")) |mv| {
        if (mv == .string) method = try allocator.dupe(u8, mv.string);
    }

    const has_result = obj.get("result") != null;

    var error_code: ?i64 = null;
    if (obj.get("error")) |ev| {
        if (ev == .object) {
            if (ev.object.get("code")) |cv| {
                if (cv == .integer) error_code = cv.integer;
            }
        }
    }

    return Message{
        .id = id,
        .method = method,
        .has_result = has_result,
        .error_code = error_code,
    };
}

/// Read exactly one Content-Length-framed message body from `file`, blocking
/// (via `readStreaming`) until the full body is read. Returns the body bytes
/// (owned by `allocator`, framing stripped). Returns `error.EndOfStream` when
/// the pipe closes (the server exited) so the reader loop can detect a crash.
///
/// 0.16 footgun: pipes are ESPIPE on pread, so this uses `readStreaming`
/// (streaming reads, no offset) rather than `readPositionalAll`.
pub fn readFrame(allocator: std.mem.Allocator, file: std.Io.File, io: std.Io, max_bytes: usize) ![]u8 {
    // Read the header block up to the CRLF CRLF terminator one byte at a time.
    var header = std_io.StringBuilder.init(allocator);
    defer header.deinit();
    var one: [1]u8 = undefined;
    while (true) {
        const h = header.items();
        if (h.len >= 4 and std.mem.eql(u8, h[h.len - 4 ..], "\r\n\r\n")) break;
        if (h.len > 64 * 1024) return error.HeaderTooLarge;
        const n = try file.readStreaming(io, &.{&one});
        if (n == 0) return error.EndOfStream;
        try header.append(one[0]);
    }

    // Parse Content-Length out of the header lines.
    var content_length: ?usize = null;
    var lines = std.mem.splitSequence(u8, header.items(), "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const name = "Content-Length:";
        if (line.len >= name.len and std.ascii.eqlIgnoreCase(line[0..name.len], name)) {
            const v = std.mem.trim(u8, line[name.len..], " \t");
            content_length = std.fmt.parseInt(usize, v, 10) catch return error.InvalidContentLength;
        }
    }

    const len = content_length orelse return error.MissingContentLength;
    if (len > max_bytes) return error.BodyTooLarge;

    const body = try allocator.alloc(u8, len);
    errdefer allocator.free(body);
    var read_total: usize = 0;
    while (read_total < len) {
        const n = try file.readStreaming(io, &.{body[read_total..]});
        if (n == 0) return error.EndOfStream;
        read_total += n;
    }
    return body;
}

// --- Tests ---

const testing = std.testing;

test "writeFrame emits a Content-Length header and body" {
    rt.installForTest();
    const framed = try frame(testing.allocator, "{\"a\":1}");
    defer testing.allocator.free(framed);
    try testing.expect(std.mem.startsWith(u8, framed, "Content-Length: 7\r\n\r\n"));
    try testing.expect(std.mem.endsWith(u8, framed, "{\"a\":1}"));
}

test "classify distinguishes response, notification, server request" {
    rt.installForTest();
    const a = testing.allocator;
    {
        const m = (try classify(a, "{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{}}")).?;
        defer if (m.method) |s| a.free(s);
        try testing.expectEqual(@as(?i64, 5), m.id);
        try testing.expect(m.has_result);
        try testing.expectEqual(protocolKind(.response), protocolKind(m.kind()));
    }
    {
        const m = (try classify(a, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{}}")).?;
        defer if (m.method) |s| a.free(s);
        try testing.expectEqual(@as(?i64, null), m.id);
        try testing.expectEqualStrings("textDocument/publishDiagnostics", m.method.?);
        try testing.expectEqual(protocolKind(.notification), protocolKind(m.kind()));
    }
    {
        const m = (try classify(a, "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"workspace/configuration\",\"params\":{}}")).?;
        defer if (m.method) |s| a.free(s);
        try testing.expectEqual(@as(?i64, 9), m.id);
        try testing.expectEqual(protocolKind(.server_request), protocolKind(m.kind()));
    }
}

test "classify surfaces error code and rejects malformed json" {
    rt.installForTest();
    const a = testing.allocator;
    {
        const m = (try classify(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32801,\"message\":\"busy\"}}")).?;
        defer if (m.method) |s| a.free(s);
        try testing.expectEqual(@as(?i64, -32801), m.error_code);
    }
    {
        const m = try classify(a, "not json at all");
        try testing.expect(m == null);
    }
}

test "isRetryableErrorCode classifies ContentModified as retryable and others not" {
    // -32801 (ContentModified) is the only retryable transient error.
    try testing.expect(isRetryableErrorCode(LSP_ERROR_CONTENT_MODIFIED));
    try testing.expect(isRetryableErrorCode(-32801));
    // A different JSON-RPC error (-32600 InvalidRequest) is terminal.
    try testing.expect(!isRetryableErrorCode(-32600));
    // No error at all (a success response) is not retryable.
    try testing.expect(!isRetryableErrorCode(null));
}

test "responseErrorCode extracts the error code from a response body" {
    rt.installForTest();
    const a = testing.allocator;
    // Body with a -32801 error -> surfaced.
    try testing.expectEqual(
        @as(?i64, -32801),
        responseErrorCode(a, "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32801,\"message\":\"content modified\"}}"),
    );
    // Body with a result and no error -> null.
    try testing.expectEqual(
        @as(?i64, null),
        responseErrorCode(a, "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"ok\":true}}"),
    );
    // Malformed body -> null (treated as not retryable).
    try testing.expectEqual(@as(?i64, null), responseErrorCode(a, "not json"));
}

// Tiny helper so the kind comparisons above read cleanly without leaking the
// enum value type into the test signature.
fn protocolKind(k: Kind) Kind {
    return k;
}
