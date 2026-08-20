//! #575: Ink component batch 9b - assistant/system message components.
//!
//! Minimal ports of reference src/components/messages/Assistant*.tsx and
//! System*.tsx. Each renders an assistant-side or system-side message.

const std = @import("std");
const ink_render = @import("../../core/ink_render.zig");

pub const AssistantTextMessage = struct {
    text: []const u8,
};

pub fn renderAssistantText(allocator: std.mem.Allocator, msg: AssistantTextMessage) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try allocator.dupe(u8, msg.text),
        .style = .{},
    };
}

pub const AssistantThinkingMessage = struct {
    text: []const u8,
};

pub fn renderAssistantThinking(allocator: std.mem.Allocator, msg: AssistantThinkingMessage) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "{s}", .{msg.text}),
        .style = .{ .dim = true, .italic = true },
    };
}

pub const AssistantRedactedThinkingMessage = struct {};

pub fn renderAssistantRedactedThinking(allocator: std.mem.Allocator, _: AssistantRedactedThinkingMessage) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try allocator.dupe(u8, "[redacted thinking]"),
        .style = .{ .dim = true },
    };
}

pub const AssistantToolUseMessage = struct {
    tool_name: []const u8,
    input_summary: []const u8,
};

pub fn renderAssistantToolUse(allocator: std.mem.Allocator, msg: AssistantToolUseMessage) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "⏺ {s}({s})", .{ msg.tool_name, msg.input_summary }),
        .style = .{ .fg = .yellow },
    };
}

pub const SystemAPIErrorMessage = struct {
    error_message: []const u8,
    delay_ms: ?u32 = null,
};

pub fn renderSystemAPIError(allocator: std.mem.Allocator, msg: SystemAPIErrorMessage) !ink_render.RenderCommand {
    const text = if (msg.delay_ms) |delay|
        try std.fmt.allocPrint(allocator, "API Error: {s} (retrying in {d}ms)", .{ msg.error_message, delay })
    else
        try std.fmt.allocPrint(allocator, "API Error: {s}", .{msg.error_message});
    return .{
        .node_id = 0,
        .text = text,
        .style = .{ .fg = .red, .bold = true },
    };
}

pub const SystemTextMessage = struct {
    text: []const u8,
};

pub fn renderSystemText(allocator: std.mem.Allocator, msg: SystemTextMessage) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "[system] {s}", .{msg.text}),
        .style = .{ .dim = true },
    };
}

pub const RateLimitMessage = struct {
    retry_after_seconds: ?u32 = null,
    message: []const u8,
};

pub fn renderRateLimit(allocator: std.mem.Allocator, msg: RateLimitMessage) !ink_render.RenderCommand {
    const text = if (msg.retry_after_seconds) |secs|
        try std.fmt.allocPrint(allocator, "Rate limited: {s} (retry in {d}s)", .{ msg.message, secs })
    else
        try std.fmt.allocPrint(allocator, "Rate limited: {s}", .{msg.message});
    return .{
        .node_id = 0,
        .text = text,
        .style = .{ .fg = .yellow },
    };
}

pub const CompactBoundaryMessage = struct {
    compacted_turn_count: u32,
};

pub fn renderCompactBoundary(allocator: std.mem.Allocator, msg: CompactBoundaryMessage) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "✻ Conversation compacted ({d} turns)", .{msg.compacted_turn_count}),
        .style = .{ .dim = true, .italic = true },
    };
}

pub const ShutdownMessage = struct {
    reason: []const u8,
};

pub fn renderShutdown(allocator: std.mem.Allocator, msg: ShutdownMessage) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "Shutting down: {s}", .{msg.reason}),
        .style = .{ .fg = .red },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "renderAssistantText: plain text, no style" {
    const cmd = try renderAssistantText(testing.allocator, .{ .text = "hello" });
    defer testing.allocator.free(cmd.text);
    try testing.expectEqualStrings("hello", cmd.text);
    try testing.expect(cmd.style.fg == null);
}

test "renderAssistantThinking: dim + italic" {
    const cmd = try renderAssistantThinking(testing.allocator, .{ .text = "hmm" });
    defer testing.allocator.free(cmd.text);
    try testing.expect(cmd.style.dim);
    try testing.expect(cmd.style.italic);
}

test "renderAssistantRedactedThinking: placeholder, dim" {
    const cmd = try renderAssistantRedactedThinking(testing.allocator, .{});
    defer testing.allocator.free(cmd.text);
    try testing.expectEqualStrings("[redacted thinking]", cmd.text);
    try testing.expect(cmd.style.dim);
}

test "renderAssistantToolUse: tool name + input summary, yellow" {
    const cmd = try renderAssistantToolUse(testing.allocator, .{ .tool_name = "Bash", .input_summary = "ls" });
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "Bash") != null);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "ls") != null);
    try testing.expectEqual(ink_render.Color.yellow, cmd.style.fg.?);
}

test "renderSystemAPIError: includes message + delay when provided" {
    const cmd = try renderSystemAPIError(testing.allocator, .{ .error_message = "overloaded", .delay_ms = 500 });
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "overloaded") != null);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "500ms") != null);
    try testing.expectEqual(ink_render.Color.red, cmd.style.fg.?);
}

test "renderSystemText: [system] prefix, dim" {
    const cmd = try renderSystemText(testing.allocator, .{ .text = "reloaded config" });
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "[system] reloaded config") != null);
    try testing.expect(cmd.style.dim);
}

test "renderRateLimit: includes retry time when provided" {
    const cmd = try renderRateLimit(testing.allocator, .{ .message = "slow down", .retry_after_seconds = 30 });
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "30s") != null);
    try testing.expectEqual(ink_render.Color.yellow, cmd.style.fg.?);
}

test "renderCompactBoundary: includes turn count, dim+italic" {
    const cmd = try renderCompactBoundary(testing.allocator, .{ .compacted_turn_count = 10 });
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "10 turns") != null);
    try testing.expect(cmd.style.dim);
}

test "renderShutdown: includes reason, red" {
    const cmd = try renderShutdown(testing.allocator, .{ .reason = "user exit" });
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "user exit") != null);
    try testing.expectEqual(ink_render.Color.red, cmd.style.fg.?);
}
