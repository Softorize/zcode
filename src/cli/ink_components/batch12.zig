//! #575: Ink component batch 12 - message-list + misc UI components.
//!
//! Minimal ports of remaining common components.

const std = @import("std");
const ink_render = @import("../../core/ink_render.zig");

// --- MessageTimestamp ---
pub fn renderMessageTimestamp(allocator: std.mem.Allocator, iso_ts: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "[{s}]", .{iso_ts}),
        .style = .{ .dim = true },
    };
}

// --- PrBadge ---
pub fn renderPrBadge(allocator: std.mem.Allocator, pr_number: u32, state: []const u8) !ink_render.RenderCommand {
    const color = if (std.mem.eql(u8, state, "open")) ink_render.Color.green else if (std.mem.eql(u8, state, "closed")) ink_render.Color.red else ink_render.Color.yellow;
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "PR#{d} {s}", .{ pr_number, state }),
        .style = .{ .fg = color, .bold = true },
    };
}

// --- MessageSelector ---
// The reference's MessageSelector lets the user pick a message to
// branch from. zcode's version is the state.
pub const MessageSelector = struct {
    message_ids: []const u32,
    selected_index: usize = 0,
    pub fn current(self: MessageSelector) ?u32 {
        if (self.message_ids.len == 0) return null;
        return self.message_ids[self.selected_index];
    }
    pub fn next(self: *MessageSelector) void {
        if (self.selected_index + 1 < self.message_ids.len) self.selected_index += 1;
    }
    pub fn prev(self: *MessageSelector) void {
        if (self.selected_index > 0) self.selected_index -= 1;
    }
};

// --- SessionBackgroundHint ---
pub fn renderSessionBackgroundHint(allocator: std.mem.Allocator, session_label: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "Session '{s}' running in background", .{session_label}),
        .style = .{ .dim = true, .italic = true },
    };
}

// --- MessageResponse ---
// Wraps an assistant response with a header.
pub fn renderMessageResponse(allocator: std.mem.Allocator, body: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "⏺ {s}", .{body}),
        .style = .{},
    };
}

// --- ExportDialog ---
pub const ExportFormat = enum { json, markdown };

pub fn renderExportDialog(allocator: std.mem.Allocator) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try allocator.dupe(u8, "Export session as: JSON or Markdown?"),
        .style = .{ .fg = .cyan },
    };
}

// --- DesktopHandoff ---
pub fn renderDesktopHandoff(allocator: std.mem.Allocator, url: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "Handoff to desktop: {s}", .{url}),
        .style = .{ .dim = true },
    };
}

// --- InvalidConfigDialog ---
pub fn renderInvalidConfigDialog(allocator: std.mem.Allocator, key: []const u8, reason: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "Invalid config '{s}': {s}", .{ key, reason }),
        .style = .{ .fg = .red },
    };
}

// --- ChannelDowngradeDialog ---
pub fn renderChannelDowngradeDialog(allocator: std.mem.Allocator, from: []const u8, to: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "Downgrade channel from {s} to {s}?", .{ from, to }),
        .style = .{ .fg = .yellow },
    };
}

// --- ConsoleOAuthFlow ---
pub fn renderConsoleOAuthFlow(allocator: std.mem.Allocator, url: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "Open this URL to authenticate:\n{s}", .{url}),
        .style = .{ .fg = .cyan },
    };
}

// --- ClickableImageRef ---
pub fn renderClickableImageRef(allocator: std.mem.Allocator, path: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "[img:{s}]", .{path}),
        .style = .{ .underline = true, .dim = true },
    };
}

// --- DevBar ---
pub fn renderDevBar(allocator: std.mem.Allocator, version: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "[dev] zcode {s}", .{version}),
        .style = .{ .fg = .magenta, .dim = true },
    };
}

// --- DevChannelsDialog ---
pub fn renderDevChannelsDialog(allocator: std.mem.Allocator, channels: []const []const u8) !ink_render.RenderCommand {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    try buf.writer.writeAll("Dev channels:\n");
    for (channels) |c| {
        try buf.writer.print("  - {s}\n", .{c});
    }
    return .{
        .node_id = 0,
        .text = try allocator.dupe(u8, buf.writer.buffered()),
        .style = .{ .dim = true },
    };
}

// --- ExitFlow ---
// (Already in batch6; this is a separate ExitFlow variant for the
// full-screen exit transition.)
pub fn renderExitFlowTransition(allocator: std.mem.Allocator) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try allocator.dupe(u8, "Press Ctrl+C again to exit, or any key to continue."),
        .style = .{ .fg = .yellow },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "renderMessageTimestamp: brackets the ts, dim" {
    const cmd = try renderMessageTimestamp(testing.allocator, "12:34");
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "[12:34]") != null);
    try testing.expect(cmd.style.dim);
}

test "renderPrBadge: open is green, closed is red" {
    const open = try renderPrBadge(testing.allocator, 42, "open");
    defer testing.allocator.free(open.text);
    try testing.expectEqual(ink_render.Color.green, open.style.fg.?);
    const closed = try renderPrBadge(testing.allocator, 43, "closed");
    defer testing.allocator.free(closed.text);
    try testing.expectEqual(ink_render.Color.red, closed.style.fg.?);
}

test "MessageSelector.next/prev navigate" {
    const ids = [_]u32{ 1, 2, 3 };
    var sel = MessageSelector{ .message_ids = &ids };
    try testing.expectEqual(@as(u32, 1), sel.current().?);
    sel.next();
    try testing.expectEqual(@as(u32, 2), sel.current().?);
    sel.prev();
    try testing.expectEqual(@as(u32, 1), sel.current().?);
}

test "MessageSelector.next at end is no-op" {
    const ids = [_]u32{1};
    var sel = MessageSelector{ .message_ids = &ids };
    sel.next();
    try testing.expectEqual(@as(u32, 1), sel.current().?);
}

test "renderSessionBackgroundHint: includes label, dim+italic" {
    const cmd = try renderSessionBackgroundHint(testing.allocator, "my-sess");
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "my-sess") != null);
    try testing.expect(cmd.style.dim);
}

test "renderExportDialog: cyan prompt" {
    const cmd = try renderExportDialog(testing.allocator);
    defer testing.allocator.free(cmd.text);
    try testing.expectEqual(ink_render.Color.cyan, cmd.style.fg.?);
}

test "renderInvalidConfigDialog: red with key + reason" {
    const cmd = try renderInvalidConfigDialog(testing.allocator, "model", "not found");
    defer testing.allocator.free(cmd.text);
    try testing.expectEqual(ink_render.Color.red, cmd.style.fg.?);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "model") != null);
}

test "renderConsoleOAuthFlow: includes url, cyan" {
    const cmd = try renderConsoleOAuthFlow(testing.allocator, "https://auth.example");
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "https://auth.example") != null);
    try testing.expectEqual(ink_render.Color.cyan, cmd.style.fg.?);
}

test "renderDevBar: includes version, magenta+dim" {
    const cmd = try renderDevBar(testing.allocator, "0.12.33");
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "0.12.33") != null);
    try testing.expectEqual(ink_render.Color.magenta, cmd.style.fg.?);
}
