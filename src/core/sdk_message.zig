//! SDK message envelope for the direct-connect server (Phase 12, Task 19).
//!
//! The reference's direct-connect transport streams newline-delimited JSON
//! frames over a WebSocket. Each frame is an SDK message with a `type`
//! discriminant. We model the envelope here as a small tagged union with
//! serialize/deserialize so the wire contract is unit-testable independently
//! of the live agent loop (which is integration-tested).
//!
//! Reference behavior + file:line:
//!   directConnectManager.ts:64-67  (newline-delimited JSON per frame)
//!   directConnectManager.ts:125    (sendMessage stream-json -> "user" frame)
//!   directConnectManager.ts:172    (sendInterrupt -> control_request)
//!   server/types.ts:13             (ServerConfig shape, consumed in remote_daemon)
//!
//! Design choice: the variable-shape payloads (assistant content blocks, the
//! control-request input, etc.) are carried as opaque raw-JSON strings rather
//! than a decoded value tree. This mirrors the Task 1 "metadata as raw JSON
//! string" decision and avoids a recursive value-clone helper. Callers that
//! need to inspect a payload parse the raw slice themselves.

const std = @import("std");

/// The wire `type` discriminant for an SDK message frame.
pub const MessageType = enum {
    assistant,
    user,
    result,
    system,
    control_request,
    control_response,

    pub fn toString(self: MessageType) []const u8 {
        return switch (self) {
            .assistant => "assistant",
            .user => "user",
            .result => "result",
            .system => "system",
            .control_request => "control_request",
            .control_response => "control_response",
        };
    }

    pub fn fromString(s: []const u8) ?MessageType {
        if (std.mem.eql(u8, s, "assistant")) return .assistant;
        if (std.mem.eql(u8, s, "user")) return .user;
        if (std.mem.eql(u8, s, "result")) return .result;
        if (std.mem.eql(u8, s, "system")) return .system;
        if (std.mem.eql(u8, s, "control_request")) return .control_request;
        if (std.mem.eql(u8, s, "control_response")) return .control_response;
        return null;
    }
};

/// A decoded SDK message frame. Slices borrow from the parse arena returned by
/// `parse`; copy them out before freeing the arena if they must outlive it.
pub const SdkMessage = struct {
    msg_type: MessageType,
    /// The session this frame belongs to. May be empty when the producer has
    /// not yet allocated one (e.g. an initial control_request).
    session_id: []const u8 = "",
    /// For control_request / control_response correlation. Empty when absent.
    request_id: []const u8 = "",
    /// For control_request: the subtype (e.g. "can_use_tool", "interrupt").
    /// For result: the result subtype (e.g. "success", "error").
    /// For system: the subtype (e.g. "init"). Empty when absent.
    subtype: []const u8 = "",
    /// Raw JSON for the variable payload. For assistant/user this is the
    /// message content; for control_request the request input; for
    /// control_response the response body. Empty -> serialized as omitted.
    payload_json: []const u8 = "",
    /// Free-form text carried by result/system frames. Empty -> omitted.
    text: []const u8 = "",

    /// Serialize to a single JSON object (no trailing newline). The caller
    /// owns the returned slice. The direct-connect transport appends the
    /// newline framing separately.
    pub fn serialize(self: SdkMessage, allocator: std.mem.Allocator) ![]u8 {
        var alloc_writer = std.Io.Writer.Allocating.init(allocator);
        defer alloc_writer.deinit();
        const w = &alloc_writer.writer;

        try w.writeAll("{\"type\":");
        try writeJsonString(w, self.msg_type.toString());

        if (self.session_id.len > 0) {
            try w.writeAll(",\"session_id\":");
            try writeJsonString(w, self.session_id);
        }
        if (self.request_id.len > 0) {
            try w.writeAll(",\"request_id\":");
            try writeJsonString(w, self.request_id);
        }
        if (self.subtype.len > 0) {
            try w.writeAll(",\"subtype\":");
            try writeJsonString(w, self.subtype);
        }
        if (self.text.len > 0) {
            try w.writeAll(",\"text\":");
            try writeJsonString(w, self.text);
        }
        if (self.payload_json.len > 0) {
            // payload_json is already valid JSON; embed it verbatim under the
            // key the reference uses for the variable payload.
            try w.writeAll(",\"message\":");
            try w.writeAll(self.payload_json);
        }
        try w.writeAll("}");
        return allocator.dupe(u8, alloc_writer.writer.buffered());
    }
};

/// Result of parsing a frame. Holds the parse arena so the borrowed slices on
/// `message` stay valid until `deinit`.
pub const ParsedMessage = struct {
    parsed: std.json.Parsed(std.json.Value),
    message: SdkMessage,

    pub fn deinit(self: *ParsedMessage) void {
        self.parsed.deinit();
    }
};

/// Parse a single newline-delimited JSON frame into an SdkMessage. The caller
/// must `deinit` the returned ParsedMessage; the SdkMessage slices borrow from
/// it. Returns error.InvalidFrame for a non-object or a missing/unknown type.
pub fn parse(allocator: std.mem.Allocator, frame: []const u8) !ParsedMessage {
    const trimmed = std.mem.trim(u8, frame, " \t\r\n");
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidFrame;

    // Take the object by pointer (CLAUDE.md ObjectMap rule): never value-copy
    // the object out, as a later realloc would desync the entries pointer.
    const obj = &parsed.value.object;

    const type_str = getString(obj, "type") orelse return error.InvalidFrame;
    const msg_type = MessageType.fromString(type_str) orelse return error.InvalidFrame;

    var msg = SdkMessage{ .msg_type = msg_type };
    if (getString(obj, "session_id")) |v| msg.session_id = v;
    if (getString(obj, "request_id")) |v| msg.request_id = v;
    if (getString(obj, "subtype")) |v| msg.subtype = v;
    if (getString(obj, "text")) |v| msg.text = v;
    // The variable payload round-trips back out as the raw slice of the
    // original frame so we never rebuild a value tree.
    if (getRawSpan(trimmed, obj, "message")) |span| msg.payload_json = span;

    return .{ .parsed = parsed, .message = msg };
}

fn getString(obj: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

/// Recover the raw JSON span for `key`'s value out of the original `source`
/// buffer. std.json does not expose token offsets, so we re-scan the source
/// for the key and bracket-match its value. This keeps the payload opaque
/// (raw JSON) without cloning a value tree. Returns null if the key is absent
/// or the value cannot be span-matched.
fn getRawSpan(source: []const u8, obj: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key) == null) return null;
    // Find `"key"` followed (after optional whitespace) by ':'.
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, source, search_from, key)) |key_at| {
        search_from = key_at + 1;
        // Require an opening quote immediately before the key text and a
        // closing quote immediately after, so we match the JSON key token and
        // not a substring inside some value.
        if (key_at == 0 or source[key_at - 1] != '"') continue;
        const after_key = key_at + key.len;
        if (after_key >= source.len or source[after_key] != '"') continue;
        var i = after_key + 1;
        while (i < source.len and (source[i] == ' ' or source[i] == '\t')) i += 1;
        if (i >= source.len or source[i] != ':') continue;
        i += 1;
        while (i < source.len and (source[i] == ' ' or source[i] == '\t' or source[i] == '\n' or source[i] == '\r')) i += 1;
        if (i >= source.len) return null;
        return scanValueSpan(source, i);
    }
    return null;
}

/// Given an offset at the start of a JSON value, return the slice spanning the
/// full value (object, array, string, number, literal). Returns null on a
/// malformed span.
fn scanValueSpan(source: []const u8, start: usize) ?[]const u8 {
    if (start >= source.len) return null;
    const c = source[start];
    switch (c) {
        '{', '[' => {
            const open = c;
            const close: u8 = if (c == '{') '}' else ']';
            var depth: usize = 0;
            var in_string = false;
            var escaped = false;
            var i = start;
            while (i < source.len) : (i += 1) {
                const ch = source[i];
                if (in_string) {
                    if (escaped) {
                        escaped = false;
                    } else if (ch == '\\') {
                        escaped = true;
                    } else if (ch == '"') {
                        in_string = false;
                    }
                    continue;
                }
                if (ch == '"') {
                    in_string = true;
                } else if (ch == open) {
                    depth += 1;
                } else if (ch == close) {
                    depth -= 1;
                    if (depth == 0) return source[start .. i + 1];
                }
            }
            return null;
        },
        '"' => {
            var i = start + 1;
            var escaped = false;
            while (i < source.len) : (i += 1) {
                const ch = source[i];
                if (escaped) {
                    escaped = false;
                } else if (ch == '\\') {
                    escaped = true;
                } else if (ch == '"') {
                    return source[start .. i + 1];
                }
            }
            return null;
        },
        else => {
            // Number / true / false / null: read until a structural delimiter.
            var i = start;
            while (i < source.len) : (i += 1) {
                const ch = source[i];
                if (ch == ',' or ch == '}' or ch == ']' or ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') break;
            }
            if (i == start) return null;
            return source[start..i];
        },
    }
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

const testing = std.testing;

test "MessageType round-trips through strings" {
    const all = [_]MessageType{ .assistant, .user, .result, .system, .control_request, .control_response };
    for (all) |t| {
        try testing.expectEqual(t, MessageType.fromString(t.toString()).?);
    }
    try testing.expect(MessageType.fromString("nope") == null);
}

test "assistant frame round-trips with opaque payload" {
    const allocator = testing.allocator;
    const msg = SdkMessage{
        .msg_type = .assistant,
        .session_id = "sess-1",
        .payload_json = "{\"role\":\"assistant\",\"content\":\"hi\"}",
    };
    const bytes = try msg.serialize(allocator);
    defer allocator.free(bytes);

    var parsed = try parse(allocator, bytes);
    defer parsed.deinit();
    try testing.expectEqual(MessageType.assistant, parsed.message.msg_type);
    try testing.expectEqualStrings("sess-1", parsed.message.session_id);
    try testing.expectEqualStrings("{\"role\":\"assistant\",\"content\":\"hi\"}", parsed.message.payload_json);
}

test "result frame round-trips subtype and text" {
    const allocator = testing.allocator;
    const msg = SdkMessage{
        .msg_type = .result,
        .session_id = "sess-2",
        .subtype = "success",
        .text = "all done",
    };
    const bytes = try msg.serialize(allocator);
    defer allocator.free(bytes);

    var parsed = try parse(allocator, bytes);
    defer parsed.deinit();
    try testing.expectEqual(MessageType.result, parsed.message.msg_type);
    try testing.expectEqualStrings("success", parsed.message.subtype);
    try testing.expectEqualStrings("all done", parsed.message.text);
    try testing.expectEqualStrings("sess-2", parsed.message.session_id);
}

test "control_request frame round-trips request_id and opaque input" {
    const allocator = testing.allocator;
    const msg = SdkMessage{
        .msg_type = .control_request,
        .request_id = "req-9",
        .subtype = "can_use_tool",
        .payload_json = "{\"tool\":\"Bash\",\"input\":{\"command\":\"ls\"}}",
    };
    const bytes = try msg.serialize(allocator);
    defer allocator.free(bytes);

    var parsed = try parse(allocator, bytes);
    defer parsed.deinit();
    try testing.expectEqual(MessageType.control_request, parsed.message.msg_type);
    try testing.expectEqualStrings("req-9", parsed.message.request_id);
    try testing.expectEqualStrings("can_use_tool", parsed.message.subtype);
    try testing.expectEqualStrings("{\"tool\":\"Bash\",\"input\":{\"command\":\"ls\"}}", parsed.message.payload_json);
}

test "control_response frame round-trips" {
    const allocator = testing.allocator;
    const msg = SdkMessage{
        .msg_type = .control_response,
        .request_id = "req-9",
        .payload_json = "{\"behavior\":\"allow\"}",
    };
    const bytes = try msg.serialize(allocator);
    defer allocator.free(bytes);

    var parsed = try parse(allocator, bytes);
    defer parsed.deinit();
    try testing.expectEqual(MessageType.control_response, parsed.message.msg_type);
    try testing.expectEqualStrings("req-9", parsed.message.request_id);
    try testing.expectEqualStrings("{\"behavior\":\"allow\"}", parsed.message.payload_json);
}

test "parse rejects non-object and unknown type" {
    const allocator = testing.allocator;
    try testing.expectError(error.InvalidFrame, parse(allocator, "[1,2,3]"));
    try testing.expectError(error.InvalidFrame, parse(allocator, "{\"type\":\"bogus\"}"));
    try testing.expectError(error.InvalidFrame, parse(allocator, "{\"no\":\"type\"}"));
}

test "serialize escapes control characters in text" {
    const allocator = testing.allocator;
    const msg = SdkMessage{ .msg_type = .system, .subtype = "init", .text = "line1\nline2\t\"q\"" };
    const bytes = try msg.serialize(allocator);
    defer allocator.free(bytes);
    // Must remain valid JSON after escaping.
    var parsed = try parse(allocator, bytes);
    defer parsed.deinit();
    try testing.expectEqualStrings("line1\nline2\t\"q\"", parsed.message.text);
}
