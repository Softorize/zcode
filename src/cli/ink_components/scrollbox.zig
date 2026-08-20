//! #575: ScrollBox component - a scrollable viewport.
//!
//! Direct port of reference src/ink/components/ScrollBox.tsx (minimal).
//! The reference's ScrollBox has an imperative handle (scrollTo,
//! scrollBy, scrollToElement, scrollToBottom) and tracks scroll state
//! via React refs. zcode's version captures the scroll state model:
//! a viewport height, a scroll position, and a content height. The
//! REPL overlay loop drives scroll updates; this module is the pure
//! state container.

const std = @import("std");
const ink_layout = @import("../../core/ink_layout.zig");

pub const ScrollBox = struct {
    scroll_top: u32 = 0, // current scroll position (top row of viewport)
    viewport_height: u32, // visible rows
    content_height: u32 = 0, // total content rows (set after layout)
    sticky_scroll: bool = true, // pin to bottom as content grows

    pub fn scrollBy(self: *ScrollBox, delta: i32) void {
        if (delta >= 0) {
            self.scroll_top += @intCast(delta);
        } else {
            const abs: u32 = @intCast(-delta);
            self.scroll_top = if (self.scroll_top > abs) self.scroll_top - abs else 0;
        }
        self.clamp();
    }

    pub fn scrollTo(self: *ScrollBox, y: u32) void {
        self.scroll_top = y;
        self.clamp();
    }

    pub fn scrollToBottom(self: *ScrollBox) void {
        if (self.content_height <= self.viewport_height) {
            self.scroll_top = 0;
        } else {
            self.scroll_top = self.content_height - self.viewport_height;
        }
    }

    pub fn isAtBottom(self: ScrollBox) bool {
        if (self.content_height <= self.viewport_height) return true;
        return self.scroll_top >= self.content_height - self.viewport_height;
    }

    fn clamp(self: *ScrollBox) void {
        if (self.content_height <= self.viewport_height) {
            self.scroll_top = 0;
            return;
        }
        const max_top = self.content_height - self.viewport_height;
        if (self.scroll_top > max_top) self.scroll_top = max_top;
    }
};

pub const ScrollBoxProps = struct {
    id: u32,
    viewport_height: u32,
    width: ?u32 = null,
    padding: u32 = 0,
    children: []const ink_layout.LayoutNode = &.{},
    sticky_scroll: bool = true,
};

/// Build a LayoutNode for a ScrollBox. The node is a Box with the
/// viewport height as its fixed height.
pub fn layoutNode(props: ScrollBoxProps) ink_layout.LayoutNode {
    return .{
        .id = props.id,
        .flex_direction = .column,
        .width = props.width,
        .height = props.viewport_height,
        .padding = ink_layout.Edges.uniform(props.padding),
        .children = props.children,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "ScrollBox.scrollToBottom when content fits viewport" {
    var sb = ScrollBox{ .viewport_height = 10, .content_height = 5 };
    sb.scrollToBottom();
    try testing.expectEqual(@as(u32, 0), sb.scroll_top);
    try testing.expect(sb.isAtBottom());
}

test "ScrollBox.scrollToBottom when content overflows" {
    var sb = ScrollBox{ .viewport_height = 10, .content_height = 25 };
    sb.scrollToBottom();
    try testing.expectEqual(@as(u32, 15), sb.scroll_top); // 25 - 10
    try testing.expect(sb.isAtBottom());
}

test "ScrollBox.scrollBy clamps at top and bottom" {
    var sb = ScrollBox{ .viewport_height = 10, .content_height = 25 };
    sb.scrollBy(-100); // can't go above 0
    try testing.expectEqual(@as(u32, 0), sb.scroll_top);
    sb.scrollBy(100); // can't go past max
    try testing.expectEqual(@as(u32, 15), sb.scroll_top); // clamped to 25-10
}

test "ScrollBox.scrollTo sets position and clamps" {
    var sb = ScrollBox{ .viewport_height = 10, .content_height = 25 };
    sb.scrollTo(5);
    try testing.expectEqual(@as(u32, 5), sb.scroll_top);
    sb.scrollTo(100);
    try testing.expectEqual(@as(u32, 15), sb.scroll_top); // clamped
}

test "ScrollBox.isAtBottom false when scrolled up" {
    var sb = ScrollBox{ .viewport_height = 10, .content_height = 25 };
    sb.scrollTo(5);
    try testing.expect(!sb.isAtBottom());
}
