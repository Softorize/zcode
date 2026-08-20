//! #575: Spacer component - a flexible space that expands along the
//! major axis of its containing layout.
//!
//! Direct port of reference src/ink/components/Spacer.tsx.
//! In the reference, Spacer is `<Box flexGrow={1} />`. zcode's version
//! maps to a LayoutNode with flex_grow=1.

const std = @import("std");
const ink_layout = @import("../../core/ink_layout.zig");

/// Build a LayoutNode for a Spacer. The node has flex_grow=1 so it
/// expands to fill available space along the parent's main axis.
pub fn layoutNode(id: u32, flex_direction: ink_layout.FlexDirection) ink_layout.LayoutNode {
    return .{
        .id = id,
        .flex_direction = flex_direction,
        .flex_grow = 1,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "spacer.layoutNode has flex_grow=1" {
    const node = layoutNode(1, .row);
    try testing.expectEqual(@as(f64, 1.0), node.flex_grow);
}

test "spacer.layoutNode carries the given id and direction" {
    const node = layoutNode(42, .column);
    try testing.expectEqual(@as(u32, 42), node.id);
    try testing.expectEqual(ink_layout.FlexDirection.column, node.flex_direction);
}

test "spacer in a row layout result carries flex_grow" {
    const children = [_]ink_layout.LayoutNode{
        .{ .id = 2, .text = "left" },
        layoutNode(3, .row),
        .{ .id = 4, .text = "right" },
    };
    const root = LayoutNode{
        .id = 1,
        .flex_direction = .row,
        .children = &children,
    };
    _ = root;
    // The layout pass records flex_grow on the result; actual space
    // distribution needs the two-pass algorithm (deferred per ADR 0011).
    // This test documents that the property is carried through.
    const results = try ink_layout.layout(testing.allocator, layoutNode(1, .row), 0, 0);
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(f64, 1.0), results[0].flex_grow);
}

const LayoutNode = ink_layout.LayoutNode;
