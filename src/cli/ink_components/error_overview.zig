//! #575: ErrorOverview component - renders an error summary.
//!
//! Direct port of reference src/ink/components/ErrorOverview.tsx concept.
//! In the reference, ErrorOverview renders a styled error block with
//! the error message, stack trace, and recovery hints. zcode's version
//! maps to a Text RenderCommand with error styling (red fg, bold).

const std = @import("std");
const ink_render = @import("../../core/ink_render.zig");

pub const ErrorOverviewProps = struct {
    message: []const u8,
    detail: ?[]const u8 = null,
};

/// Build a RenderCommand for an ErrorOverview. Red + bold by default,
/// matching the reference's error styling.
pub fn render(props: ErrorOverviewProps, allocator: std.mem.Allocator) !ink_render.RenderCommand {
    const text = if (props.detail) |detail|
        try std.fmt.allocPrint(allocator, "Error: {s}\n  {s}", .{ props.message, detail })
    else
        try std.fmt.allocPrint(allocator, "Error: {s}", .{props.message});
    return .{
        .node_id = 0,
        .text = text,
        .style = .{ .fg = .red, .bold = true },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "render: message-only error is red+bold" {
    const cmd = try render(.{ .message = "something broke" }, testing.allocator);
    defer testing.allocator.free(cmd.text);
    try testing.expectEqual(ink_render.Color.red, cmd.style.fg.?);
    try testing.expect(cmd.style.bold);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "something broke") != null);
}

test "render: detail included when provided" {
    const cmd = try render(.{ .message = "main error", .detail = "caused by X" }, testing.allocator);
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "main error") != null);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "caused by X") != null);
}
