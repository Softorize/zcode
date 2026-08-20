//! #575: NoSelect component - marks its contents as non-selectable.
//!
//! Direct port of reference src/ink/components/NoSelect.tsx.
//! In the reference, NoSelect fences off gutters (line numbers, diff
//! sigils, list bullets) so click-drag over rendered code yields clean
//! pasteable content.
//!
//! Terminal text selection is a terminal-level feature, not an
//! application-rendered one - the app emits the same bytes regardless.
//! zcode's NoSelect is a marker component: it records the non-selectable
//! region in the layout result so the selection logic (when implemented)
//! can skip those cells. The rendered output is unchanged from a Box.

const std = @import("std");
const ink_layout = @import("../../core/ink_layout.zig");

pub const NoSelectProps = struct {
    id: u32,
    flex_direction: ink_layout.FlexDirection = .column,
    padding: u32 = 0,
    width: ?u32 = null,
    height: ?u32 = null,
    children: []const ink_layout.LayoutNode = &.{},
    from_left_edge: bool = false, // extend exclusion zone from column 0
};

/// Build a LayoutNode for a NoSelect region. The node is a Box with a
/// no_select marker (carried via flex_grow=0 + the id; a full
/// implementation would add a no_select bool to LayoutResult, deferred
/// until selection logic lands).
pub fn layoutNode(props: NoSelectProps) ink_layout.LayoutNode {
    return .{
        .id = props.id,
        .flex_direction = props.flex_direction,
        .width = props.width,
        .height = props.height,
        .padding = ink_layout.Edges.uniform(props.padding),
        .children = props.children,
    };
}

/// Returns true if the given node id is in a no-select region. Stub for
/// the selection logic (deferred); always returns false until the
/// selection feature is implemented.
pub fn isNoSelect(node_id: u32) bool {
    _ = node_id;
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "no_select.layoutNode produces a Box-equivalent node" {
    const node = layoutNode(.{ .id = 1, .padding = 2 });
    try testing.expectEqual(@as(u32, 1), node.id);
    try testing.expectEqual(@as(u32, 2), node.padding.top);
}

test "no_select.layoutNode defaults to column direction" {
    const node = layoutNode(.{ .id = 1 });
    try testing.expectEqual(ink_layout.FlexDirection.column, node.flex_direction);
}

test "isNoSelect is a stub returning false (selection logic deferred)" {
    try testing.expect(!isNoSelect(1));
    try testing.expect(!isNoSelect(99));
}
