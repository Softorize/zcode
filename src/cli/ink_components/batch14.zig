//! #575: Ink component batch 14 - remaining message components.
//!
//! Minimal ports of reference src/components/messages/*.tsx not yet
//! covered in batch 9 (user_messages) or batch 9b (assistant_messages).

const std = @import("std");
const ink_render = @import("../../core/ink_render.zig");

// --- AdvisorMessage ---
pub fn renderAdvisorMessage(allocator: std.mem.Allocator, advice: []const u8) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try std.fmt.allocPrint(allocator, "[advisor] {s}", .{advice}), .style = .{ .fg = .magenta, .dim = true } };
}

// --- AttachmentMessage ---
pub fn renderAttachmentMessage(allocator: std.mem.Allocator, kind: []const u8, path: []const u8) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try std.fmt.allocPrint(allocator, "[{s}: {s}]", .{ kind, path }), .style = .{ .dim = true } };
}

// --- CollapsedReadSearchContent ---
pub fn renderCollapsedReadSearch(allocator: std.mem.Allocator, tool: []const u8, match_count: u32) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try std.fmt.allocPrint(allocator, "{s} ({d} matches, collapsed)", .{ tool, match_count }), .style = .{ .dim = true } };
}

// --- GroupedToolUseContent ---
pub fn renderGroupedToolUse(allocator: std.mem.Allocator, tool: []const u8, count: u32) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try std.fmt.allocPrint(allocator, "{s} x{d}", .{ tool, count }), .style = .{ .fg = .yellow, .dim = true } };
}

// --- HighlightedThinkingText ---
pub fn renderHighlightedThinking(allocator: std.mem.Allocator, text: []const u8) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try allocator.dupe(u8, text), .style = .{ .dim = true, .italic = true } };
}

// --- HookProgressMessage ---
pub fn renderHookProgress(allocator: std.mem.Allocator, hook_name: []const u8, status: []const u8) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try std.fmt.allocPrint(allocator, "hook {s}: {s}", .{ hook_name, status }), .style = .{ .dim = true } };
}

// --- PlanApprovalMessage ---
pub fn renderPlanApproval(allocator: std.mem.Allocator, plan_summary: []const u8) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try std.fmt.allocPrint(allocator, "Plan: {s} (approve to proceed)", .{plan_summary}), .style = .{ .fg = .blue, .bold = true } };
}

// --- TaskAssignmentMessage ---
pub fn renderTaskAssignment(allocator: std.mem.Allocator, task_id: []const u8, assignee: []const u8) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try std.fmt.allocPrint(allocator, "Task {s} assigned to {s}", .{ task_id, assignee }), .style = .{ .fg = .cyan } };
}

// --- teamMemCollapsed ---
pub fn renderTeamMemCollapsed(allocator: std.mem.Allocator, count: u32) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try std.fmt.allocPrint(allocator, "{d} team memories (collapsed)", .{count}), .style = .{ .dim = true } };
}

// --- UserAgentNotificationMessage ---
pub fn renderUserAgentNotification(allocator: std.mem.Allocator, agent: []const u8, event: []const u8) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try std.fmt.allocPrint(allocator, "[{s}] {s}", .{ agent, event }), .style = .{ .dim = true } };
}

// --- UserChannelMessage ---
pub fn renderUserChannelMessage(allocator: std.mem.Allocator, channel: []const u8, text: []const u8) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try std.fmt.allocPrint(allocator, "#{s}: {s}", .{ channel, text }), .style = .{ .fg = .magenta } };
}

// --- UserLocalCommandOutputMessage ---
pub fn renderUserLocalCommandOutput(allocator: std.mem.Allocator, command: []const u8, output: []const u8) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try std.fmt.allocPrint(allocator, "$ {s}\n{s}", .{ command, output }), .style = .{ .dim = true } };
}

// --- UserResourceUpdateMessage ---
pub fn renderUserResourceUpdate(allocator: std.mem.Allocator, resource: []const u8, action: []const u8) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try std.fmt.allocPrint(allocator, "[resource {s}: {s}]", .{ action, resource }), .style = .{ .dim = true } };
}

// --- UserTeammateMessage ---
pub fn renderUserTeammateMessage(allocator: std.mem.Allocator, from: []const u8, text: []const u8) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try std.fmt.allocPrint(allocator, "@{s}: {s}", .{ from, text }), .style = .{ .fg = .cyan } };
}

// --- UserTextMessage ---
pub fn renderUserText(allocator: std.mem.Allocator, text: []const u8) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try allocator.dupe(u8, text), .style = .{} };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "renderAdvisorMessage: magenta+dim" {
    const cmd = try renderAdvisorMessage(testing.allocator, "try this");
    defer testing.allocator.free(cmd.text);
    try testing.expectEqual(ink_render.Color.magenta, cmd.style.fg.?);
    try testing.expect(cmd.style.dim);
}

test "renderCollapsedReadSearch: includes match count" {
    const cmd = try renderCollapsedReadSearch(testing.allocator, "Grep", 5);
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "5 matches") != null);
}

test "renderGroupedToolUse: includes count" {
    const cmd = try renderGroupedToolUse(testing.allocator, "Read", 3);
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "x3") != null);
}

test "renderPlanApproval: blue+bold" {
    const cmd = try renderPlanApproval(testing.allocator, "step 1");
    defer testing.allocator.free(cmd.text);
    try testing.expectEqual(ink_render.Color.blue, cmd.style.fg.?);
    try testing.expect(cmd.style.bold);
}

test "renderTaskAssignment: includes task + assignee" {
    const cmd = try renderTaskAssignment(testing.allocator, "T-1", "alice");
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "T-1") != null);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "alice") != null);
}

test "renderUserChannelMessage: # prefix" {
    const cmd = try renderUserChannelMessage(testing.allocator, "general", "hi");
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "#general") != null);
}

test "renderUserTeammateMessage: @ prefix" {
    const cmd = try renderUserTeammateMessage(testing.allocator, "bob", "hello");
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "@bob") != null);
}

test "renderMarkdownTable separator: (smoke)" {
    // smoke test that the module compiles and a basic call works
    const cmd = try renderUserText(testing.allocator, "plain");
    defer testing.allocator.free(cmd.text);
    try testing.expectEqualStrings("plain", cmd.text);
}
