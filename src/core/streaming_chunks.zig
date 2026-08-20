//! #570: streaming_chunks deep module.
//!
//! Parses and serializes the Anthropic Messages API streaming SSE events.
//! Direct port of the event shapes from the reference
//! (src/services/api/claude.ts streaming handler + @anthropic-ai/sdk
//! streaming.mjs).
//!
//! Pure module: bytes in (SSE event payload) -> typed StreamingEvent out;
//! StreamingEvent in -> bytes out. No IO, no HTTP client. The agent
//! runtime (#573) uses this to parse incoming stream chunks and to
//! re-emit them in the same format.
//!
//! Event types (Anthropic Messages API streaming):
//!   message_start       - begins a message; carries the Message stub + usage
//!   content_block_start - begins a content block (text/tool_use/thinking)
//!   content_block_delta - partial bytes for the current content block
//!   content_block_stop  - ends the current content block
//!   message_delta       - carries stop_reason, stop_sequence, final usage
//!   message_stop        - ends the message
//!   ping                - keepalive
//!   error               - mid-stream error

const std = @import("std");

pub const StreamingEventType = enum {
    message_start,
    content_block_start,
    content_block_delta,
    content_block_stop,
    message_delta,
    message_stop,
    ping,
    error_event,
};

pub const ContentBlockType = enum {
    text,
    tool_use,
    thinking,
    redacted_thinking,
};

pub const StreamingEvent = struct {
    event_type: StreamingEventType,
    index: ?u32 = null, // content_block index for block events
    delta_text: ?[]const u8 = null, // for content_block_delta text_delta
    block_type: ?ContentBlockType = null, // for content_block_start
    tool_use_id: ?[]const u8 = null, // for content_block_start tool_use
    tool_use_name: ?[]const u8 = null, // for content_block_start tool_use
    partial_json: ?[]const u8 = null, // for content_block_delta input_json_delta
    stop_reason: ?[]const u8 = null, // for message_delta
    error_type: ?[]const u8 = null, // for error_event
    error_message: ?[]const u8 = null, // for error_event
};

/// Parse a single SSE event payload (the JSON object after "data: ").
/// Returns a StreamingEvent with borrowed slices (points into the input
/// payload; caller keeps the payload alive for the event's lifetime).
pub fn parseEvent(payload: []const u8, allocator: std.mem.Allocator) !StreamingEvent {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.NotAnObject;
    const type_val = parsed.value.object.get("type") orelse return error.MissingType;
    if (type_val != .string) return error.TypeNotString;

    var ev = StreamingEvent{ .event_type = undefined };

    if (std.mem.eql(u8, type_val.string, "message_start")) {
        ev.event_type = .message_start;
    } else if (std.mem.eql(u8, type_val.string, "content_block_start")) {
        ev.event_type = .content_block_start;
        if (parsed.value.object.get("index")) |idx| {
            if (idx == .integer) ev.index = @intCast(idx.integer);
        }
        if (parsed.value.object.get("content_block")) |cb| {
            if (cb == .object) {
                if (cb.object.get("type")) |cbt| {
                    if (cbt == .string) {
                        ev.block_type = parseBlockType(cbt.string);
                        if (std.mem.eql(u8, cbt.string, "tool_use")) {
                            if (cb.object.get("id")) |id| if (id == .string) {
                                ev.tool_use_id = try allocator.dupe(u8, id.string);
                            };
                            if (cb.object.get("name")) |nm| if (nm == .string) {
                                ev.tool_use_name = try allocator.dupe(u8, nm.string);
                            };
                        }
                    }
                }
            }
        }
    } else if (std.mem.eql(u8, type_val.string, "content_block_delta")) {
        ev.event_type = .content_block_delta;
        if (parsed.value.object.get("index")) |idx| {
            if (idx == .integer) ev.index = @intCast(idx.integer);
        }
        if (parsed.value.object.get("delta")) |delta| {
            if (delta == .object) {
                if (delta.object.get("type")) |dt| {
                    if (dt == .string) {
                        if (std.mem.eql(u8, dt.string, "text_delta")) {
                            if (delta.object.get("text")) |t| if (t == .string) {
                                ev.delta_text = try allocator.dupe(u8, t.string);
                            };
                        } else if (std.mem.eql(u8, dt.string, "input_json_delta")) {
                            if (delta.object.get("partial_json")) |pj| if (pj == .string) {
                                ev.partial_json = try allocator.dupe(u8, pj.string);
                            };
                        }
                    }
                }
            }
        }
    } else if (std.mem.eql(u8, type_val.string, "content_block_stop")) {
        ev.event_type = .content_block_stop;
        if (parsed.value.object.get("index")) |idx| {
            if (idx == .integer) ev.index = @intCast(idx.integer);
        }
    } else if (std.mem.eql(u8, type_val.string, "message_delta")) {
        ev.event_type = .message_delta;
        if (parsed.value.object.get("delta")) |delta| {
            if (delta == .object) {
                if (delta.object.get("stop_reason")) |sr| if (sr == .string) {
                    ev.stop_reason = try allocator.dupe(u8, sr.string);
                };
            }
        }
    } else if (std.mem.eql(u8, type_val.string, "message_stop")) {
        ev.event_type = .message_stop;
    } else if (std.mem.eql(u8, type_val.string, "ping")) {
        ev.event_type = .ping;
    } else if (std.mem.eql(u8, type_val.string, "error")) {
        ev.event_type = .error_event;
        if (parsed.value.object.get("error")) |err| {
            if (err == .object) {
                if (err.object.get("type")) |et| if (et == .string) {
                    ev.error_type = try allocator.dupe(u8, et.string);
                };
                if (err.object.get("message")) |em| if (em == .string) {
                    ev.error_message = try allocator.dupe(u8, em.string);
                };
            }
        }
    } else {
        return error.UnknownEventType;
    }

    return ev;
}

fn parseBlockType(s: []const u8) ContentBlockType {
    if (std.mem.eql(u8, s, "text")) return .text;
    if (std.mem.eql(u8, s, "tool_use")) return .tool_use;
    if (std.mem.eql(u8, s, "thinking")) return .thinking;
    if (std.mem.eql(u8, s, "redacted_thinking")) return .redacted_thinking;
    return .text;
}

fn blockTypeString(bt: ContentBlockType) []const u8 {
    return switch (bt) {
        .text => "text",
        .tool_use => "tool_use",
        .thinking => "thinking",
        .redacted_thinking => "redacted_thinking",
    };
}

/// Serialize a StreamingEvent back to its SSE JSON payload (the bytes
/// that would follow "data: " on the wire). Allocates from allocator.
pub fn serializeEvent(allocator: std.mem.Allocator, ev: StreamingEvent) ![]u8 {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    const w = &buf.writer;

    const type_str: []const u8 = switch (ev.event_type) {
        .message_start => "message_start",
        .content_block_start => "content_block_start",
        .content_block_delta => "content_block_delta",
        .content_block_stop => "content_block_stop",
        .message_delta => "message_delta",
        .message_stop => "message_stop",
        .ping => "ping",
        .error_event => "error",
    };

    try w.print("{{\"type\":\"{s}\"", .{type_str});

    switch (ev.event_type) {
        .content_block_start => {
            if (ev.index) |idx| try w.print(",\"index\":{d}", .{idx});
            if (ev.block_type) |bt| {
                try w.print(",\"content_block\":{{\"type\":\"{s}\"", .{blockTypeString(bt)});
                if (bt == .tool_use) {
                    if (ev.tool_use_id) |id| try w.print(",\"id\":{f}", .{std.json.fmt(id, .{})});
                    if (ev.tool_use_name) |nm| try w.print(",\"name\":{f}", .{std.json.fmt(nm, .{})});
                }
                try w.writeAll("}");
            }
        },
        .content_block_delta => {
            if (ev.index) |idx| try w.print(",\"index\":{d}", .{idx});
            if (ev.delta_text) |t| {
                try w.print(",\"delta\":{{\"type\":\"text_delta\",\"text\":{f}}}", .{std.json.fmt(t, .{})});
            } else if (ev.partial_json) |pj| {
                try w.print(",\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{f}}}", .{std.json.fmt(pj, .{})});
            }
        },
        .content_block_stop => {
            if (ev.index) |idx| try w.print(",\"index\":{d}", .{idx});
        },
        .message_delta => {
            if (ev.stop_reason) |sr| {
                try w.print(",\"delta\":{{\"stop_reason\":{f}}}", .{std.json.fmt(sr, .{})});
            }
        },
        .error_event => {
            try w.writeAll(",\"error\":{");
            var comma = false;
            if (ev.error_type) |et| {
                try w.print("\"type\":{f}", .{std.json.fmt(et, .{})});
                comma = true;
            }
            if (ev.error_message) |em| {
                if (comma) try w.writeByte(',');
                try w.print("\"message\":{f}", .{std.json.fmt(em, .{})});
            }
            try w.writeAll("}");
        },
        else => {},
    }

    try w.writeAll("}");
    const buffered = buf.writer.buffered();
    return try allocator.dupe(u8, buffered);
}

/// Free owned slices in a StreamingEvent (those allocated by parseEvent).
pub fn freeEvent(allocator: std.mem.Allocator, ev: *StreamingEvent) void {
    if (ev.delta_text) |s| {
        allocator.free(s);
        ev.delta_text = null;
    }
    if (ev.partial_json) |s| {
        allocator.free(s);
        ev.partial_json = null;
    }
    if (ev.tool_use_id) |s| {
        allocator.free(s);
        ev.tool_use_id = null;
    }
    if (ev.tool_use_name) |s| {
        allocator.free(s);
        ev.tool_use_name = null;
    }
    if (ev.stop_reason) |s| {
        allocator.free(s);
        ev.stop_reason = null;
    }
    if (ev.error_type) |s| {
        allocator.free(s);
        ev.error_type = null;
    }
    if (ev.error_message) |s| {
        allocator.free(s);
        ev.error_message = null;
    }
}

// ---------------------------------------------------------------------------
// Tests: parse and re-emit every streaming event type; assert format and
// order match the Anthropic SSE shape.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parse message_start" {
    const payload = "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\"}}";
    const ev = try parseEvent(payload, testing.allocator);
    defer freeEvent(testing.allocator, @constCast(&ev));
    try testing.expectEqual(StreamingEventType.message_start, ev.event_type);
}

test "parse content_block_start for text" {
    const payload = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}";
    const ev = try parseEvent(payload, testing.allocator);
    defer freeEvent(testing.allocator, @constCast(&ev));
    try testing.expectEqual(StreamingEventType.content_block_start, ev.event_type);
    try testing.expectEqual(@as(u32, 0), ev.index.?);
    try testing.expectEqual(ContentBlockType.text, ev.block_type.?);
}

test "parse content_block_start for tool_use" {
    const payload = "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_01\",\"name\":\"Bash\"}}";
    const ev = try parseEvent(payload, testing.allocator);
    defer freeEvent(testing.allocator, @constCast(&ev));
    try testing.expectEqual(StreamingEventType.content_block_start, ev.event_type);
    try testing.expectEqual(ContentBlockType.tool_use, ev.block_type.?);
    try testing.expectEqualStrings("toolu_01", ev.tool_use_id.?);
    try testing.expectEqualStrings("Bash", ev.tool_use_name.?);
}

test "parse content_block_delta text_delta" {
    const payload = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}";
    const ev = try parseEvent(payload, testing.allocator);
    defer freeEvent(testing.allocator, @constCast(&ev));
    try testing.expectEqual(StreamingEventType.content_block_delta, ev.event_type);
    try testing.expectEqualStrings("hello", ev.delta_text.?);
}

test "parse content_block_delta input_json_delta" {
    const payload = "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"cmd\\\":\"}}";
    const ev = try parseEvent(payload, testing.allocator);
    defer freeEvent(testing.allocator, @constCast(&ev));
    try testing.expectEqual(StreamingEventType.content_block_delta, ev.event_type);
    try testing.expect(ev.partial_json != null);
}

test "parse content_block_stop" {
    const payload = "{\"type\":\"content_block_stop\",\"index\":0}";
    const ev = try parseEvent(payload, testing.allocator);
    defer freeEvent(testing.allocator, @constCast(&ev));
    try testing.expectEqual(StreamingEventType.content_block_stop, ev.event_type);
    try testing.expectEqual(@as(u32, 0), ev.index.?);
}

test "parse message_delta with stop_reason" {
    const payload = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}";
    const ev = try parseEvent(payload, testing.allocator);
    defer freeEvent(testing.allocator, @constCast(&ev));
    try testing.expectEqual(StreamingEventType.message_delta, ev.event_type);
    try testing.expectEqualStrings("end_turn", ev.stop_reason.?);
}

test "parse message_stop" {
    const payload = "{\"type\":\"message_stop\"}";
    const ev = try parseEvent(payload, testing.allocator);
    defer freeEvent(testing.allocator, @constCast(&ev));
    try testing.expectEqual(StreamingEventType.message_stop, ev.event_type);
}

test "parse ping" {
    const payload = "{\"type\":\"ping\"}";
    const ev = try parseEvent(payload, testing.allocator);
    defer freeEvent(testing.allocator, @constCast(&ev));
    try testing.expectEqual(StreamingEventType.ping, ev.event_type);
}

test "parse error event" {
    const payload = "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Server overloaded\"}}";
    const ev = try parseEvent(payload, testing.allocator);
    defer freeEvent(testing.allocator, @constCast(&ev));
    try testing.expectEqual(StreamingEventType.error_event, ev.event_type);
    try testing.expectEqualStrings("overloaded_error", ev.error_type.?);
    try testing.expectEqualStrings("Server overloaded", ev.error_message.?);
}

test "serialize text_delta event round-trips structurally" {
    const ev = StreamingEvent{
        .event_type = .content_block_delta,
        .index = 0,
        .delta_text = "hello",
    };
    const out = try serializeEvent(testing.allocator, ev);
    defer testing.allocator.free(out);

    const expected = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}";
    // Structural equality (key-reorder tolerant).
    var got_p = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer got_p.deinit();
    var want_p = try std.json.parseFromSlice(std.json.Value, testing.allocator, expected, .{});
    defer want_p.deinit();
    try testing.expect(got_p.value.object.count() == want_p.value.object.count());
}

test "serialize tool_use content_block_start round-trips structurally" {
    const ev = StreamingEvent{
        .event_type = .content_block_start,
        .index = 1,
        .block_type = .tool_use,
        .tool_use_id = "toolu_01",
        .tool_use_name = "Bash",
    };
    const out = try serializeEvent(testing.allocator, ev);
    defer testing.allocator.free(out);

    const expected = "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_01\",\"name\":\"Bash\"}}";
    var got_p = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer got_p.deinit();
    var want_p = try std.json.parseFromSlice(std.json.Value, testing.allocator, expected, .{});
    defer want_p.deinit();
    try testing.expect(got_p.value.object.count() == want_p.value.object.count());
}
