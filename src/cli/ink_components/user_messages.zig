//! #575: Ink component batch 9 - user message components.
//!
//! Minimal ports of reference src/components/messages/User*.tsx.
//! Each renders a user-side message in the conversation transcript.

const std = @import("std");
const ink_render = @import("../../core/ink_render.zig");

pub const UserPromptMessage = struct {
    text: []const u8,
};

pub fn renderUserPrompt(allocator: std.mem.Allocator, msg: UserPromptMessage) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "> {s}", .{msg.text}),
        .style = .{ .bold = true },
    };
}

pub const UserCommandMessage = struct {
    command: []const u8,
};

pub fn renderUserCommand(allocator: std.mem.Allocator, msg: UserCommandMessage) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "/{s}", .{msg.command}),
        .style = .{ .fg = .cyan, .bold = true },
    };
}

pub const UserBashInputMessage = struct {
    command: []const u8,
};

pub fn renderUserBashInput(allocator: std.mem.Allocator, msg: UserBashInputMessage) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "$ {s}", .{msg.command}),
        .style = .{ .fg = .green },
    };
}

pub const UserBashOutputMessage = struct {
    output: []const u8,
    exit_code: u8 = 0,
};

pub fn renderUserBashOutput(allocator: std.mem.Allocator, msg: UserBashOutputMessage) !ink_render.RenderCommand {
    const style = if (msg.exit_code == 0) ink_render.Style{} else ink_render.Style{ .fg = .red };
    return .{
        .node_id = 0,
        .text = try allocator.dupe(u8, msg.output),
        .style = style,
    };
}

pub const UserImageMessage = struct {
    path: []const u8,
};

pub fn renderUserImage(allocator: std.mem.Allocator, msg: UserImageMessage) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "[image: {s}]", .{msg.path}),
        .style = .{ .dim = true },
    };
}

pub const UserMemoryInputMessage = struct {
    memory: []const u8,
};

pub fn renderUserMemoryInput(allocator: std.mem.Allocator, msg: UserMemoryInputMessage) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "# {s}", .{msg.memory}),
        .style = .{ .fg = .magenta, .dim = true },
    };
}

pub const UserPlanMessage = struct {
    plan: []const u8,
};

pub fn renderUserPlan(allocator: std.mem.Allocator, msg: UserPlanMessage) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "[plan] {s}", .{msg.plan}),
        .style = .{ .fg = .blue, .bold = true },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "renderUserPrompt: prefixes with > and bold" {
    const cmd = try renderUserPrompt(testing.allocator, .{ .text = "hello" });
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "> hello") != null);
    try testing.expect(cmd.style.bold);
}

test "renderUserCommand: prefixes with / and cyan" {
    const cmd = try renderUserCommand(testing.allocator, .{ .command = "commit" });
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "/commit") != null);
    try testing.expectEqual(ink_render.Color.cyan, cmd.style.fg.?);
}

test "renderUserBashInput: prefixes with $ and green" {
    const cmd = try renderUserBashInput(testing.allocator, .{ .command = "ls" });
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "$ ls") != null);
    try testing.expectEqual(ink_render.Color.green, cmd.style.fg.?);
}

test "renderUserBashOutput: exit 0 has no color, non-zero is red" {
    const cmd_ok = try renderUserBashOutput(testing.allocator, .{ .output = "done", .exit_code = 0 });
    defer testing.allocator.free(cmd_ok.text);
    try testing.expect(cmd_ok.style.fg == null);
    const cmd_err = try renderUserBashOutput(testing.allocator, .{ .output = "fail", .exit_code = 1 });
    defer testing.allocator.free(cmd_err.text);
    try testing.expectEqual(ink_render.Color.red, cmd_err.style.fg.?);
}

test "renderUserImage: includes path, dim" {
    const cmd = try renderUserImage(testing.allocator, .{ .path = "img.png" });
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "img.png") != null);
    try testing.expect(cmd.style.dim);
}

test "renderUserMemoryInput: # prefix, magenta+dim" {
    const cmd = try renderUserMemoryInput(testing.allocator, .{ .memory = "remember this" });
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "# remember this") != null);
    try testing.expectEqual(ink_render.Color.magenta, cmd.style.fg.?);
}

test "renderUserPlan: [plan] prefix, blue+bold" {
    const cmd = try renderUserPlan(testing.allocator, .{ .plan = "step 1" });
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "[plan] step 1") != null);
    try testing.expectEqual(ink_render.Color.blue, cmd.style.fg.?);
}
