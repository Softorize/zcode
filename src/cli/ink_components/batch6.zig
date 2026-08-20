//! #575: Ink component batch 6 - foundational app components.
//!
//! Minimal ports of reference src/components/* components. Each captures
//! the essential data model and rendering intent; full React lifecycle
//! (hooks, paste handlers, declared cursors) is deferred per ADR 0011.

const std = @import("std");
const ink_render = @import("../../core/ink_render.zig");
const ink_layout = @import("../../core/ink_layout.zig");

// --- BaseTextInput ---
// The reference's BaseTextInput handles rendering + basic input for text
// fields. zcode's version carries the input state: value, cursor, placeholder.

pub const BaseTextInputState = struct {
    value: []const u8 = "",
    cursor: u32 = 0,
    placeholder: ?[]const u8 = null,

    pub fn insertChar(self: *BaseTextInputState, allocator: std.mem.Allocator, ch: u8) !void {
        var buf = try allocator.alloc(u8, self.value.len + 1);
        @memcpy(buf[0..self.cursor], self.value[0..self.cursor]);
        buf[self.cursor] = ch;
        @memcpy(buf[self.cursor + 1 ..], self.value[self.cursor..]);
        self.value = buf;
        self.cursor += 1;
    }

    pub fn backspace(self: *BaseTextInputState, allocator: std.mem.Allocator) !void {
        if (self.cursor == 0 or self.value.len == 0) return;
        var buf = try allocator.alloc(u8, self.value.len - 1);
        @memcpy(buf[0 .. self.cursor - 1], self.value[0 .. self.cursor - 1]);
        @memcpy(buf[self.cursor - 1 ..], self.value[self.cursor..]);
        self.value = buf;
        self.cursor -= 1;
    }
};

// --- FastIcon ---
// The reference's FastIcon renders a lightning bolt (cooldown indicator).
pub const FastIconProps = struct {
    cooldown: bool = false,
};

pub fn renderFastIcon(props: FastIconProps) ink_render.RenderCommand {
    // LIGHTNING_BOLT is "⚡" in the reference's figures constants.
    if (props.cooldown) {
        return .{ .node_id = 0, .text = "\xe2\x9a\xa1", .style = .{ .dim = true } };
    }
    return .{ .node_id = 0, .text = "\xe2\x9a\xa1", .style = .{} };
}

// --- FilePathLink ---
// Renders a file path as a clickable link (OSC 8) when supported.
pub const FilePathLinkProps = struct {
    path: []const u8,
    line: ?u32 = null,
};

pub fn renderFilePathLink(allocator: std.mem.Allocator, props: FilePathLinkProps) !ink_render.RenderCommand {
    const display: []const u8 = if (props.line) |line|
        try std.fmt.allocPrint(allocator, "{s}:{d}", .{ props.path, line })
    else
        try allocator.dupe(u8, props.path);
    // OSC 8 link to the file:// URL (terminal-dependent; fallback is the text itself)
    const text = try std.fmt.allocPrint(
        allocator,
        "\x1b]8;;file://{s}\x1b\\{s}\x1b]8;;\x1b\\",
        .{ props.path, display },
    );
    allocator.free(display);
    return .{ .node_id = 0, .text = text, .style = .{ .underline = true } };
}

// --- FullscreenLayout ---
// A full-screen layout wrapper: uses the alternate screen and fills the
// terminal dimensions.
pub const FullscreenLayoutProps = struct {
    id: u32,
    columns: u32,
    rows: u32,
    children: []const ink_layout.LayoutNode = &.{},
};

pub fn fullscreenLayoutNode(props: FullscreenLayoutProps) ink_layout.LayoutNode {
    return .{
        .id = props.id,
        .flex_direction = .column,
        .width = props.columns,
        .height = props.rows,
        .children = props.children,
    };
}

// --- ExitFlow ---
// Renders an exit message. The reference's ExitFlow handles the exit
// transition; zcode's version is a styled text block.
pub fn renderExitFlow(allocator: std.mem.Allocator, message: []const u8) !ink_render.RenderCommand {
    const text = try std.fmt.allocPrint(allocator, "\n{s}\n", .{message});
    return .{ .node_id = 0, .text = text, .style = .{ .dim = true } };
}

// --- Feedback ---
// Renders a feedback prompt. The reference's Feedback collects user
// feedback; zcode's version is a styled prompt.
pub fn renderFeedbackPrompt(allocator: std.mem.Allocator) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try allocator.dupe(u8, "Share your feedback (optional, press Enter to submit, Esc to cancel):"),
        .style = .{ .fg = .cyan },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "BaseTextInputState.insertChar appends and advances cursor" {
    var state = BaseTextInputState{ .value = try testing.allocator.dupe(u8, "hi"), .cursor = 2 };
    defer testing.allocator.free(state.value);
    try state.insertChar(testing.allocator, '!');
    // value is now "hi!" with cursor at 3
    try testing.expectEqualStrings("hi!", state.value);
    try testing.expectEqual(@as(u32, 3), state.cursor);
}

test "BaseTextInputState.backspace removes before cursor" {
    var state = BaseTextInputState{ .value = try testing.allocator.dupe(u8, "hi!"), .cursor = 3 };
    defer testing.allocator.free(state.value);
    try state.backspace(testing.allocator);
    try testing.expectEqualStrings("hi", state.value);
    try testing.expectEqual(@as(u32, 2), state.cursor);
}

test "BaseTextInputState.backspace at cursor 0 is no-op" {
    var state = BaseTextInputState{ .value = try testing.allocator.dupe(u8, "hi"), .cursor = 0 };
    defer testing.allocator.free(state.value);
    try state.backspace(testing.allocator);
    try testing.expectEqualStrings("hi", state.value);
    try testing.expectEqual(@as(u32, 0), state.cursor);
}

test "renderFastIcon: cooldown is dim" {
    const cmd = renderFastIcon(.{ .cooldown = true });
    try testing.expect(cmd.style.dim);
}

test "renderFastIcon: non-cooldown is not dim" {
    const cmd = renderFastIcon(.{});
    try testing.expect(!cmd.style.dim);
}

test "renderFilePathLink: includes the path in the display text" {
    const cmd = try renderFilePathLink(testing.allocator, .{ .path = "src/main.zig", .line = 42 });
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "src/main.zig:42") != null);
    try testing.expect(cmd.style.underline);
}

test "renderFilePathLink: no line shows just the path" {
    const cmd = try renderFilePathLink(testing.allocator, .{ .path = "README.md" });
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "README.md") != null);
}

test "fullscreenLayoutNode: fills terminal dimensions" {
    const node = fullscreenLayoutNode(.{ .id = 1, .columns = 120, .rows = 40 });
    try testing.expectEqual(@as(u32, 120), node.width.?);
    try testing.expectEqual(@as(u32, 40), node.height.?);
}

test "renderExitFlow: wraps message with newlines and dims" {
    const cmd = try renderExitFlow(testing.allocator, "Goodbye!");
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "Goodbye!") != null);
    try testing.expect(cmd.style.dim);
}

test "renderFeedbackPrompt: cyan prompt text" {
    const cmd = try renderFeedbackPrompt(testing.allocator);
    defer testing.allocator.free(cmd.text);
    try testing.expectEqual(ink_render.Color.cyan, cmd.style.fg.?);
}
