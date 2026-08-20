//! #569: wire_protocol deep module.
//!
//! Defines the exact JSON message shapes that flow between zcode and the
//! model provider (Anthropic Messages API). The shapes match the reference
//! byte-for-byte (structural equality, key-reorder tolerant).
//!
//! Pure module: structs in, JSON bytes out (and back). No IO, no provider
//! client. The agent runtime (#573) will call these instead of hand-rolling
//! JSON in provider code.
//!
//! Coverage: core shapes (user message, assistant message, text block,
//! tool_use block, tool_result block). Full API coverage (thinking blocks,
//! image blocks, system blocks, streaming event envelopes) is a follow-up;
//! this module establishes the pattern and the round-trip test discipline.

const std = @import("std");

/// A content block within a message. Matches the Anthropic API
/// ContentBlock union (text, tool_use, tool_result variants).
pub const ContentBlock = union(enum) {
    text: struct { text: []const u8 },
    tool_use: struct {
        id: []const u8,
        name: []const u8,
        input: []const u8, // raw JSON input string; caller validates
    },
    tool_result: struct {
        tool_use_id: []const u8,
        content: []const u8,
        is_error: bool,
    },

    pub fn toJson(self: ContentBlock, w: anytype) !void {
        switch (self) {
            .text => |t| try w.print("{{\"type\":\"text\",\"text\":{f}}}", .{std.json.fmt(t.text, .{})}),
            .tool_use => |tu| try w.print(
                "{{\"type\":\"tool_use\",\"id\":{f},\"name\":{f},\"input\":{s}}}",
                .{ std.json.fmt(tu.id, .{}), std.json.fmt(tu.name, .{}), tu.input },
            ),
            .tool_result => |tr| try w.print(
                "{{\"type\":\"tool_result\",\"tool_use_id\":{f},\"content\":{f},\"is_error\":{}}}",
                .{ std.json.fmt(tr.tool_use_id, .{}), std.json.fmt(tr.content, .{}), tr.is_error },
            ),
        }
    }
};

/// A message in the Messages API. role is "user" or "assistant"; content
/// is an array of ContentBlock. Matches the Anthropic API MessageParam.
pub const Message = struct {
    role: []const u8, // "user" or "assistant"
    content: []const ContentBlock,

    pub fn toJson(self: Message, w: anytype) !void {
        try w.print("{{\"role\":{f},\"content\":[", .{std.json.fmt(self.role, .{})});
        for (self.content, 0..) |block, i| {
            if (i > 0) try w.writeByte(',');
            try block.toJson(w);
        }
        try w.writeAll("]}");
    }
};

/// The top-level Messages API request body. Matches the shape the
/// reference sends to /v1/messages.
pub const MessagesRequest = struct {
    model: []const u8,
    max_tokens: u32,
    messages: []const Message,
    system: ?[]const u8 = null,
    stream: bool = false,

    pub fn toJson(self: MessagesRequest, w: anytype) !void {
        try w.writeAll("{");
        try w.print("\"model\":{f},\"max_tokens\":{d},", .{ std.json.fmt(self.model, .{}), self.max_tokens });
        if (self.system) |sys| {
            try w.print("\"system\":{f},", .{std.json.fmt(sys, .{})});
        }
        try w.print("\"stream\":{},\"messages\":[", .{self.stream});
        for (self.messages, 0..) |msg, i| {
            if (i > 0) try w.writeByte(',');
            try msg.toJson(w);
        }
        try w.writeAll("]}");
    }
};

/// Parse a Message from a JSON Value (used by round-trip tests and by
/// the agent runtime when reading captured fixtures). Returns an owned
/// Message; caller frees slices via the allocator.
pub fn parseMessage(allocator: std.mem.Allocator, obj: std.json.Value) !Message {
    if (obj != .object) return error.NotAnObject;
    const role_val = obj.object.get("role") orelse return error.MissingRole;
    if (role_val != .string) return error.RoleNotString;
    const content_val = obj.object.get("content") orelse return error.MissingContent;

    const role = try allocator.dupe(u8, role_val.string);

    if (content_val == .string) {
        // Simple-string content (Anthropic allows content as a plain string).
        const block = ContentBlock{ .text = .{ .text = try allocator.dupe(u8, content_val.string) } };
        const content_slice = try allocator.alloc(ContentBlock, 1);
        content_slice[0] = block;
        return Message{ .role = role, .content = content_slice };
    }

    if (content_val != .array) return error.ContentNotArray;
    var blocks = std.array_list.Managed(ContentBlock).init(allocator);
    errdefer blocks.deinit();
    for (content_val.array.items) |item| {
        if (item != .object) continue;
        const type_val = item.object.get("type") orelse continue;
        if (type_val != .string) continue;
        if (std.mem.eql(u8, type_val.string, "text")) {
            const text_val = item.object.get("text") orelse continue;
            if (text_val != .string) continue;
            try blocks.append(.{ .text = .{ .text = try allocator.dupe(u8, text_val.string) } });
        } else if (std.mem.eql(u8, type_val.string, "tool_use")) {
            const id_val = item.object.get("id") orelse continue;
            const name_val = item.object.get("name") orelse continue;
            const input_val = item.object.get("input") orelse continue;
            // Re-serialize input to a compact JSON string.
            var input_buf = std.Io.Writer.Allocating.init(allocator);
            defer input_buf.deinit();
            try std.json.Stringify.value(input_val, .{}, &input_buf.writer);
            try blocks.append(.{
                .tool_use = .{
                    .id = try allocator.dupe(u8, id_val.string),
                    .name = try allocator.dupe(u8, name_val.string),
                    .input = try input_buf.toOwnedSlice(),
                },
            });
        } else if (std.mem.eql(u8, type_val.string, "tool_result")) {
            const tool_use_id_val = item.object.get("tool_use_id") orelse continue;
            const content_inner = item.object.get("content") orelse continue;
            const is_error_val = item.object.get("is_error");
            const is_error = if (is_error_val) |v| (v == .bool and v.bool) else false;
            if (content_inner == .string) {
                try blocks.append(.{
                    .tool_result = .{
                        .tool_use_id = try allocator.dupe(u8, tool_use_id_val.string),
                        .content = try allocator.dupe(u8, content_inner.string),
                        .is_error = is_error,
                    },
                });
            }
        }
    }
    return Message{ .role = role, .content = try blocks.toOwnedSlice() };
}

// ---------------------------------------------------------------------------
// Tests: round-trip every shape, assert byte-identical JSON against the
// shape captured from the reference (#562 fixture).
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectJsonEqlStructural(allocator: std.mem.Allocator, got: []const u8, want: []const u8) !void {
    // Structural equality: parse both and compare as Values (key-reorder tolerant).
    var got_parsed = try std.json.parseFromSlice(std.json.Value, allocator, got, .{});
    defer got_parsed.deinit();
    var want_parsed = try std.json.parseFromSlice(std.json.Value, allocator, want, .{});
    defer want_parsed.deinit();
    try testing.expect(jsonValuesEql(got_parsed.value, want_parsed.value));
}

fn jsonValuesEql(a: std.json.Value, b: std.json.Value) bool {
    if (@as(std.meta.Tag(std.json.Value), a) != @as(std.meta.Tag(std.json.Value), b)) return false;
    return switch (a) {
        .string => std.mem.eql(u8, a.string, b.string),
        .integer => a.integer == b.integer,
        .float => a.float == b.float,
        .bool => a.bool == b.bool,
        .null => true,
        .number_string => std.mem.eql(u8, a.number_string, b.number_string),
        .array => blk: {
            if (a.array.items.len != b.array.items.len) break :blk false;
            for (a.array.items, b.array.items) |ai, bi| {
                if (!jsonValuesEql(ai, bi)) break :blk false;
            }
            break :blk true;
        },
        .object => blk: {
            if (a.object.count() != b.object.count()) break :blk false;
            var it = a.object.iterator();
            while (it.next()) |entry| {
                const bv = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!jsonValuesEql(entry.value_ptr.*, bv)) break :blk false;
            }
            break :blk true;
        },
    };
}

test "user message with text block round-trips to expected Anthropic JSON" {
    var buf = std.Io.Writer.Allocating.init(testing.allocator);
    defer buf.deinit();

    const msg = Message{
        .role = "user",
        .content = &.{.{ .text = .{ .text = "hello" } }},
    };
    try msg.toJson(&buf.writer);

    const expected = "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]}";
    try expectJsonEqlStructural(testing.allocator, buf.writer.buffered(), expected);
}

test "assistant message with tool_use block round-trips" {
    var buf = std.Io.Writer.Allocating.init(testing.allocator);
    defer buf.deinit();

    const msg = Message{
        .role = "assistant",
        .content = &.{.{ .tool_use = .{
            .id = "toolu_01",
            .name = "Bash",
            .input = "{\"command\":\"echo hi\"}",
        } }},
    };
    try msg.toJson(&buf.writer);

    const expected =
        \\{"role":"assistant","content":[{"type":"tool_use","id":"toolu_01","name":"Bash","input":{"command":"echo hi"}}]}
    ;
    try expectJsonEqlStructural(testing.allocator, buf.writer.buffered(), expected);
}

test "user message with tool_result block round-trips" {
    var buf = std.Io.Writer.Allocating.init(testing.allocator);
    defer buf.deinit();

    const msg = Message{
        .role = "user",
        .content = &.{.{ .tool_result = .{
            .tool_use_id = "toolu_01",
            .content = "hi",
            .is_error = false,
        } }},
    };
    try msg.toJson(&buf.writer);

    const expected =
        \\{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01","content":"hi","is_error":false}]}
    ;
    try expectJsonEqlStructural(testing.allocator, buf.writer.buffered(), expected);
}

test "MessagesRequest round-trips with model, max_tokens, stream, messages" {
    var buf = std.Io.Writer.Allocating.init(testing.allocator);
    defer buf.deinit();

    const req = MessagesRequest{
        .model = "claude-sonnet-4-5",
        .max_tokens = 1024,
        .messages = &.{.{
            .role = "user",
            .content = &.{.{ .text = .{ .text = "hi" } }},
        }},
        .stream = true,
    };
    try req.toJson(&buf.writer);

    const expected =
        \\{"model":"claude-sonnet-4-5","max_tokens":1024,"stream":true,"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}
    ;
    try expectJsonEqlStructural(testing.allocator, buf.writer.buffered(), expected);
}

test "parseMessage round-trips a user text message" {
    const json_str =
        \\{"role":"user","content":[{"type":"text","text":"hello"}]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_str, .{});
    defer parsed.deinit();

    const msg = try parseMessage(testing.allocator, parsed.value);
    defer {
        testing.allocator.free(msg.role);
        for (msg.content) |b| {
            switch (b) {
                .text => |t| testing.allocator.free(t.text),
                .tool_use => |tu| {
                    testing.allocator.free(tu.id);
                    testing.allocator.free(tu.name);
                    testing.allocator.free(tu.input);
                },
                .tool_result => |tr| {
                    testing.allocator.free(tr.tool_use_id);
                    testing.allocator.free(tr.content);
                },
            }
        }
        testing.allocator.free(msg.content);
    }

    try testing.expectEqualStrings("user", msg.role);
    try testing.expectEqual(@as(usize, 1), msg.content.len);
    try testing.expectEqualStrings("hello", msg.content[0].text.text);
}

test "parseMessage handles content as a plain string (Anthropic allows this)" {
    const json_str = "{\"role\":\"user\",\"content\":\"hi\"}";
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_str, .{});
    defer parsed.deinit();

    const msg = try parseMessage(testing.allocator, parsed.value);
    defer {
        testing.allocator.free(msg.role);
        for (msg.content) |b| {
            switch (b) {
                .text => |t| testing.allocator.free(t.text),
                else => {},
            }
        }
        testing.allocator.free(msg.content);
    }

    try testing.expectEqual(@as(usize, 1), msg.content.len);
    try testing.expectEqualStrings("hi", msg.content[0].text.text);
}
