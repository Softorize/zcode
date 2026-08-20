//! #575: Box component - the core container.
//!
//! Direct port of reference src/ink/components/Box.tsx. In Ink, <Box>
//! is the flexbox container (like <div> in HTML). zcode's version maps
//! to a LayoutNode with flex_direction, padding, width, height, and
//! children. The reference Box has many more style props (margin,
//! border, flexGrow, etc.) - those land incrementally per ADR 0011.

const std = @import("std");
const ink_layout = @import("../../core/ink_layout.zig");

pub const BoxProps = struct {
    flex_direction: ink_layout.FlexDirection = .column,
    width: ?u32 = null,
    height: ?u32 = null,
    padding: u32 = 0,
    children: []const ink_layout.LayoutNode = &.{},
    id: u32 = 0,
};

/// Build a LayoutNode from BoxProps. Box is a container; its children
/// are laid out by ink_layout.layout().
pub fn layoutNode(props: BoxProps) ink_layout.LayoutNode {
    return .{
        .id = props.id,
        .flex_direction = props.flex_direction,
        .width = props.width,
        .height = props.height,
        .padding = ink_layout.Edges.uniform(props.padding),
        .children = props.children,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Box.layoutNode defaults to column direction" {
    const node = layoutNode(.{ .id = 1 });
    try testing.expectEqual(ink_layout.FlexDirection.column, node.flex_direction);
}

test "Box.layoutNode passes width/height/padding" {
    const node = layoutNode(.{ .id = 1, .width = 10, .height = 5, .padding = 2 });
    try testing.expectEqual(@as(u32, 10), node.width.?);
    try testing.expectEqual(@as(u32, 5), node.height.?);
    try testing.expectEqual(@as(u32, 2), node.padding.top);
    try testing.expectEqual(@as(u32, 2), node.padding.left);
}

test "Box.layoutNode accepts row direction" {
    const node = layoutNode(.{ .id = 1, .flex_direction = .row });
    try testing.expectEqual(ink_layout.FlexDirection.row, node.flex_direction);
}

test "Box.layoutNode passes children" {
    const children = [_]ink_layout.LayoutNode{
        .{ .id = 2, .text = "child" },
    };
    const node = layoutNode(.{ .id = 1, .children = &children });
    try testing.expectEqual(@as(usize, 1), node.children.len);
}
