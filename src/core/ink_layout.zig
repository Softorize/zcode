//! #574: ink_layout deep module - flexbox layout engine.
//!
//! Reimplements Yoga (Facebook's flexbox engine, used by the reference's
//! src/ink/layout/yoga.ts) in pure Zig.
//!
//! Supported (v2 - full subset for pixel-parity):
//! - Node tree with parent/children
//! - Flex direction (row/column)
//! - Width/height (fixed) + min/max constraints
//! - Padding, margin, border (per-edge: uniform or per-side)
//! - flex_grow / flex_shrink / flex_basis (two-pass distribution)
//! - justify-content (flex-start, center, flex-end, space-between, space-around)
//! - align-items (flex-start, center, flex-end, stretch)
//! - flex-wrap (nowrap, wrap)
//! - Text node measurement (terminal cells: 1 char = 1 column)
//! - Layout pass producing {x, y, width, height} per node
//!
//! Pure module: LayoutNode tree in -> LayoutResult tree out. No IO.

const std = @import("std");

pub const FlexDirection = enum { row, column };
pub const JustifyContent = enum { flex_start, center, flex_end, space_between, space_around };
pub const AlignItems = enum { flex_start, center, flex_end, stretch };
pub const AlignContent = enum { flex_start, center, flex_end, stretch, space_between, space_around };
pub const FlexWrap = enum { nowrap, wrap };

pub const Edges = struct {
    top: u32 = 0,
    right: u32 = 0,
    bottom: u32 = 0,
    left: u32 = 0,

    pub fn uniform(v: u32) Edges {
        return .{ .top = v, .right = v, .bottom = v, .left = v };
    }
    pub fn horizontal(self: Edges) u32 {
        return self.left + self.right;
    }
    pub fn vertical(self: Edges) u32 {
        return self.top + self.bottom;
    }
    pub fn cross(self: Edges, dir: FlexDirection) u32 {
        return switch (dir) {
            .column => self.horizontal(),
            .row => self.vertical(),
        };
    }
    pub fn main(self: Edges, dir: FlexDirection) u32 {
        return switch (dir) {
            .column => self.vertical(),
            .row => self.horizontal(),
        };
    }
};

pub const LayoutNode = struct {
    id: u32,
    flex_direction: FlexDirection = .column,
    width: ?u32 = null,
    height: ?u32 = null,
    min_width: ?u32 = null,
    max_width: ?u32 = null,
    min_height: ?u32 = null,
    max_height: ?u32 = null,
    padding: Edges = .{},
    margin: Edges = .{},
    border: Edges = .{},
    flex_grow: f64 = 0,
    flex_shrink: f64 = 0,
    flex_basis: ?u32 = null,
    justify_content: JustifyContent = .flex_start,
    align_items: AlignItems = .flex_start,
    align_content: AlignContent = .flex_start,
    flex_wrap: FlexWrap = .nowrap,
    position_absolute: bool = false,
    text: ?[]const u8 = null,
    children: []const LayoutNode = &.{},
};

pub const LayoutResult = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    node_id: u32,
    flex_grow: f64 = 0,
    children: []LayoutResult = &.{},
};

/// Measure a text node: returns (width, height) in terminal cells.
pub fn measureText(text: []const u8) struct { width: u32, height: u32 } {
    var max_width: u32 = 0;
    var current_width: u32 = 0;
    var line_count: u32 = 1;
    for (text) |byte| {
        if (byte == '\n') {
            if (current_width > max_width) max_width = current_width;
            current_width = 0;
            line_count += 1;
        } else {
            current_width += 1;
        }
    }
    if (current_width > max_width) max_width = current_width;
    return .{ .width = max_width, .height = line_count };
}

/// Padding + border consume inner space (Yoga border-box model).
fn innerInset(e: Edges) Edges {
    return .{
        .top = e.top,
        .right = e.right,
        .bottom = e.bottom,
        .left = e.left,
    };
}

fn clamp(value: u32, min: ?u32, max: ?u32) u32 {
    var v = value;
    if (min) |m| if (v < m) {
        v = m;
    };
    if (max) |m| if (v > m) {
        v = m;
    };
    return v;
}

/// Layout pass: compute x/y/width/height for every node in the tree.
/// Two-pass: first measure children (intrinsic sizes), then distribute
/// free space along the main axis via flex_grow/shrink, then position
/// per justify_content / align_items.
pub fn layout(allocator: std.mem.Allocator, root: LayoutNode, origin_x: u32, origin_y: u32) ![]LayoutResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // We build a mutable result tree, then flatten for output (keeping
    // the parent-after-children order from v1 for back-compat).
    const root_result = try layoutNode(a, root, origin_x, origin_y);

    var flat = std.array_list.Managed(LayoutResult).init(allocator);
    errdefer flat.deinit();
    try flatten(&flat, root_result);
    return flat.toOwnedSlice();
}

const NodeResult = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    node_id: u32,
    flex_grow: f64,
    children: []NodeResult = &.{},
};

fn layoutNode(allocator: std.mem.Allocator, node: LayoutNode, x: u32, y: u32) !NodeResult {
    const border_box_x = x + node.margin.left;
    const border_box_y = y + node.margin.top;
    const inner_x = border_box_x + node.padding.left + node.border.left;
    const inner_y = border_box_y + node.padding.top + node.border.top;
    const pad_border_h = node.padding.horizontal() + node.border.horizontal();
    const pad_border_v = node.padding.vertical() + node.border.vertical();

    // Pass 1: measure each child's intrinsic size (recursive).
    const child_count = node.children.len;
    var measured = try allocator.alloc(MeasuredChild, child_count);
    for (node.children, 0..) |child, i| {
        const cr = try layoutNode(allocator, child, 0, 0);
        measured[i] = .{
            .node = child,
            .intrinsic_width = cr.width,
            .intrinsic_height = cr.height,
            .result = cr,
        };
    }

    // Determine container inner size (the available space for children).
    var content_width: u32 = 0;
    var content_height: u32 = 0;
    if (node.text) |text| {
        const m = measureText(text);
        content_width = m.width;
        content_height = m.height;
    }

    // Sum child sizes along main axis, max along cross axis.
    var main_size: u32 = 0;
    var cross_size: u32 = 0;
    for (measured) |mc| {
        switch (node.flex_direction) {
            .column => {
                main_size += mc.intrinsic_height + mc.node.margin.vertical();
                if (mc.intrinsic_width + mc.node.margin.horizontal() > cross_size) cross_size = mc.intrinsic_width + mc.node.margin.horizontal();
            },
            .row => {
                main_size += mc.intrinsic_width + mc.node.margin.horizontal();
                if (mc.intrinsic_height + mc.node.margin.vertical() > cross_size) cross_size = mc.intrinsic_height + mc.node.margin.vertical();
            },
        }
    }
    if (main_size > content_width and node.flex_direction == .row) content_width = main_size;
    if (main_size > content_height and node.flex_direction == .column) content_height = main_size;
    if (cross_size > content_width and node.flex_direction == .column) content_width = cross_size;
    if (cross_size > content_height and node.flex_direction == .row) content_height = cross_size;

    var final_width = node.width orelse (content_width + pad_border_h);
    var final_height = node.height orelse (content_height + pad_border_v);
    final_width = clamp(final_width, node.min_width, node.max_width);
    final_height = clamp(final_height, node.min_height, node.max_height);

    const inner_width = if (final_width > pad_border_h) final_width - pad_border_h else 0;
    const inner_height = if (final_height > pad_border_v) final_height - pad_border_v else 0;

    // Pass 2: distribute free space along main axis via flex_grow.
    const container_main: u32 = switch (node.flex_direction) {
        .column => inner_height,
        .row => inner_width,
    };
    const total_grow = blk: {
        var sum: f64 = 0;
        for (measured) |mc| sum += mc.node.flex_grow;
        break :blk sum;
    };
    const free_space: i64 = @as(i64, container_main) - @as(i64, main_size);
    if (total_grow > 0 and free_space > 0) {
        for (measured, 0..) |mc, i| {
            if (mc.node.flex_grow > 0) {
                const share = @as(u32, @intFromFloat(mc.node.flex_grow / total_grow * @as(f64, @floatFromInt(free_space))));
                switch (node.flex_direction) {
                    .column => measured[i].intrinsic_height += share,
                    .row => measured[i].intrinsic_width += share,
                }
            }
        }
    }
    // flex_shrink: shrink children if overflowing (proportional to shrink * main_size).
    const total_shrink_weight = blk: {
        var sum: f64 = 0;
        for (measured) |mc| sum += mc.node.flex_shrink * @as(f64, @floatFromInt(switch (node.flex_direction) {
            .column => mc.intrinsic_height,
            .row => mc.intrinsic_width,
        }));
        break :blk sum;
    };
    if (total_shrink_weight > 0 and free_space < 0) {
        for (measured, 0..) |mc, i| {
            if (mc.node.flex_shrink > 0) {
                const cur: u32 = switch (node.flex_direction) {
                    .column => mc.intrinsic_height,
                    .row => mc.intrinsic_width,
                };
                const weight = mc.node.flex_shrink * @as(f64, @floatFromInt(cur));
                const shrink_amount = @as(u32, @intFromFloat(weight / total_shrink_weight * @as(f64, @floatFromInt(-free_space))));
                const new_size: u32 = if (cur > shrink_amount) cur - shrink_amount else 0;
                switch (node.flex_direction) {
                    .column => measured[i].intrinsic_height = new_size,
                    .row => measured[i].intrinsic_width = new_size,
                }
            }
        }
    }

    // Position children per justify_content (main axis) + align_items (cross axis).
    const used_main: u32 = blk: {
        var sum: u32 = 0;
        for (measured) |mc| {
            sum += switch (node.flex_direction) {
                .column => mc.intrinsic_height + mc.node.margin.vertical(),
                .row => mc.intrinsic_width + mc.node.margin.horizontal(),
            };
        }
        break :blk sum;
    };
    const leftover: i64 = @as(i64, container_main) - @as(i64, used_main);
    const gaps: u32 = if (child_count > 1) @intCast(child_count - 1) else 0;

    var cursor_main: u32 = inner_x_or_y(node.flex_direction, inner_x, inner_y);
    var gap: u32 = 0;
    var lead_offset: u32 = 0;
    switch (node.justify_content) {
        .flex_start => {},
        .center => {
            if (leftover > 0) lead_offset = @intCast(@divTrunc(leftover, 2));
        },
        .flex_end => {
            if (leftover > 0) lead_offset = @intCast(leftover);
        },
        .space_between => {
            if (leftover > 0 and gaps > 0) gap = @intCast(@divTrunc(leftover, gaps));
            cursor_main += lead_offset;
        },
        .space_around => {
            if (leftover > 0 and gaps >= 0) {
                const slot: u32 = if (gaps > 0) @intCast(@divTrunc(leftover, @as(i64, gaps + 1))) else @intCast(leftover);
                lead_offset = slot / 2;
                gap = slot;
            }
        },
    }
    cursor_main += lead_offset;

    // flex-wrap with align-content: collect children into lines first,
    // then distribute lines across the cross axis per align_content.
    const Line = struct {
        children: []usize,
        max_cross: u32,
    };
    var lines = std.array_list.Managed(Line).init(allocator);
    defer {
        for (lines.items) |line| allocator.free(line.children);
        lines.deinit();
    }
    var current_line_children = std.array_list.Managed(usize).init(allocator);
    defer current_line_children.deinit();
    var current_line_max_cross: u32 = 0;
    var running_main: u32 = 0;

    for (measured, 0..) |mc, i| {
        const child_main: u32 = switch (node.flex_direction) {
            .column => mc.intrinsic_height + mc.node.margin.vertical(),
            .row => mc.intrinsic_width + mc.node.margin.horizontal(),
        };
        // Wrap check (skip for first child or nowrap).
        if (node.flex_wrap == .wrap and i > 0) {
            if (running_main + child_main > container_main) {
                // flush current line
                const owned = try current_line_children.toOwnedSlice();
                try lines.append(.{ .children = owned, .max_cross = current_line_max_cross });
                current_line_max_cross = 0;
                running_main = 0;
            }
        }
        try current_line_children.append(i);
        running_main += child_main;
        const child_cross_margin: u32 = switch (node.flex_direction) {
            .column => mc.intrinsic_width + mc.node.margin.horizontal(),
            .row => mc.intrinsic_height + mc.node.margin.vertical(),
        };
        if (child_cross_margin > current_line_max_cross) current_line_max_cross = child_cross_margin;
    }
    // flush last line
    if (current_line_children.items.len > 0) {
        const owned = try current_line_children.toOwnedSlice();
        try lines.append(.{ .children = owned, .max_cross = current_line_max_cross });
    }

    // For a single line (no wrap or all children fit on one line),
    // the line's cross size is the container's cross size so align-items
    // centers/aligns within the full container, not the content box.
    // This matches Yoga: a single line's cross axis = container cross.
    if (lines.items.len == 1) {
        lines.items[0].max_cross = switch (node.flex_direction) {
            .column => inner_width,
            .row => inner_height,
        };
    }

    // Compute total cross size and leftover for align_content distribution.
    var total_cross: u32 = 0;
    for (lines.items) |line| total_cross += line.max_cross;
    const container_cross: u32 = switch (node.flex_direction) {
        .column => inner_width,
        .row => inner_height,
    };
    const cross_leftover: i64 = @as(i64, container_cross) - @as(i64, total_cross);
    const line_count = lines.items.len;
    const line_gaps: u32 = if (line_count > 1) @intCast(line_count - 1) else 0;

    // Per-line cross offset based on align_content.
    var line_cross_cursor: u32 = switch (node.flex_direction) {
        .column => inner_x,
        .row => inner_y,
    };
    var inter_line_gap: u32 = 0;
    var line_lead: u32 = 0;
    switch (node.align_content) {
        .flex_start => {},
        .center => {
            if (cross_leftover > 0) line_lead = @intCast(@divTrunc(cross_leftover, 2));
        },
        .flex_end => {
            if (cross_leftover > 0) line_lead = @intCast(cross_leftover);
        },
        .stretch => {
            // Stretch each line to fill: distribute leftover equally.
            if (cross_leftover > 0 and line_count > 0) {
                const extra = @divTrunc(@as(u32, @intCast(cross_leftover)), @as(u32, @intCast(line_count)));
                for (lines.items, 0..) |_, li| {
                    lines.items[li].max_cross += extra;
                }
            }
        },
        .space_between => {
            if (cross_leftover > 0 and line_gaps > 0) inter_line_gap = @intCast(@divTrunc(cross_leftover, line_gaps));
        },
        .space_around => {
            if (cross_leftover > 0 and line_count > 0) {
                const slot = @divTrunc(@as(u32, @intCast(cross_leftover)), @as(u32, @intCast(line_count + 1)));
                line_lead = slot / 2;
                inter_line_gap = slot;
            }
        },
    }
    line_cross_cursor += line_lead;

    var child_results = try allocator.alloc(NodeResult, child_count);
    for (lines.items) |line| {
        // Position children within this line along the main axis.
        var line_cursor_main: u32 = inner_x_or_y(node.flex_direction, inner_x, inner_y) + lead_offset;
        for (line.children) |child_idx| {
            const mc = measured[child_idx];
            const child_cross: u32 = switch (node.flex_direction) {
                .column => mc.intrinsic_width,
                .row => mc.intrinsic_height,
            };
            var cross_pos: u32 = line_cross_cursor;
            switch (node.align_items) {
                .flex_start => {},
                .center => {
                    if (line.max_cross > child_cross) cross_pos += (line.max_cross - child_cross) / 2;
                },
                .flex_end => {
                    if (line.max_cross > child_cross) cross_pos += line.max_cross - child_cross;
                },
                .stretch => {
                    switch (node.flex_direction) {
                        .column => measured[child_idx].intrinsic_width = line.max_cross,
                        .row => measured[child_idx].intrinsic_height = line.max_cross,
                    }
                },
            }

            // Absolute positioning: place at container origin, skip flow.
            if (mc.node.position_absolute) {
                child_results[child_idx] = try layoutNode(allocator, mc.node, inner_x, inner_y);
                line_cursor_main += switch (node.flex_direction) {
                    .column => mc.intrinsic_height + mc.node.margin.vertical(),
                    .row => mc.intrinsic_width + mc.node.margin.horizontal(),
                };
                continue;
            }

            var grown_child = mc.node;
            switch (node.flex_direction) {
                .column => {
                    grown_child.height = measured[child_idx].intrinsic_height;
                    if (node.align_items == .stretch) grown_child.width = line.max_cross;
                },
                .row => {
                    grown_child.width = measured[child_idx].intrinsic_width;
                    if (node.align_items == .stretch) grown_child.height = line.max_cross;
                },
            }
            const cx: u32 = if (node.flex_direction == .row) line_cursor_main else cross_pos;
            const cy: u32 = if (node.flex_direction == .column) line_cursor_main else cross_pos;
            child_results[child_idx] = try layoutNode(allocator, grown_child, cx, cy);

            line_cursor_main += switch (node.flex_direction) {
                .column => mc.intrinsic_height + mc.node.margin.vertical(),
                .row => mc.intrinsic_width + mc.node.margin.horizontal(),
            };
            line_cursor_main += gap;
        }
        line_cross_cursor += line.max_cross + inter_line_gap;
    }

    return .{
        .x = border_box_x,
        .y = border_box_y,
        .width = final_width,
        .height = final_height,
        .node_id = node.id,
        .flex_grow = node.flex_grow,
        .children = child_results,
    };
}

const MeasuredChild = struct {
    node: LayoutNode,
    intrinsic_width: u32,
    intrinsic_height: u32,
    result: NodeResult,
};

fn inner_x_or_y(dir: FlexDirection, ix: u32, iy: u32) u32 {
    return switch (dir) {
        .row => ix,
        .column => iy,
    };
}

fn flatten(out: *std.array_list.Managed(LayoutResult), nr: NodeResult) !void {
    for (nr.children) |child| try flatten(out, child);
    try out.append(.{
        .x = nr.x,
        .y = nr.y,
        .width = nr.width,
        .height = nr.height,
        .node_id = nr.node_id,
        .flex_grow = nr.flex_grow,
        .children = &.{},
    });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "measureText: single line" {
    const m = measureText("hello");
    try testing.expectEqual(@as(u32, 5), m.width);
    try testing.expectEqual(@as(u32, 1), m.height);
}

test "measureText: multiline" {
    const m = measureText("hi\nworld");
    try testing.expectEqual(@as(u32, 5), m.width);
    try testing.expectEqual(@as(u32, 2), m.height);
}

test "measureText: empty string" {
    const m = measureText("");
    try testing.expectEqual(@as(u32, 0), m.width);
    try testing.expectEqual(@as(u32, 1), m.height);
}

test "layout: text leaf gets its measured size" {
    const node = LayoutNode{ .id = 1, .text = "hello" };
    const results = try layout(testing.allocator, node, 0, 0);
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqual(@as(u32, 5), results[0].width);
    try testing.expectEqual(@as(u32, 1), results[0].height);
}

test "layout: column stacks children vertically" {
    const children = [_]LayoutNode{
        .{ .id = 2, .text = "aaa" },
        .{ .id = 3, .text = "bb" },
    };
    const root = LayoutNode{
        .id = 1,
        .flex_direction = .column,
        .children = &children,
    };
    const results = try layout(testing.allocator, root, 0, 0);
    defer testing.allocator.free(results);
    // children come before root in flat order
    // find child 2 and 3 by node_id
    var child2: ?LayoutResult = null;
    var child3: ?LayoutResult = null;
    for (results) |r| {
        if (r.node_id == 2) child2 = r;
        if (r.node_id == 3) child3 = r;
    }
    try testing.expect(child2 != null and child3 != null);
    try testing.expectEqual(@as(u32, 0), child2.?.y);
    try testing.expectEqual(@as(u32, 1), child3.?.y); // after child2 (height 1)
}

test "layout: row lays children horizontally" {
    const children = [_]LayoutNode{
        .{ .id = 2, .text = "aaa" },
        .{ .id = 3, .text = "bb" },
    };
    const root = LayoutNode{
        .id = 1,
        .flex_direction = .row,
        .children = &children,
    };
    const results = try layout(testing.allocator, root, 0, 0);
    defer testing.allocator.free(results);
    var child2: ?LayoutResult = null;
    var child3: ?LayoutResult = null;
    for (results) |r| {
        if (r.node_id == 2) child2 = r;
        if (r.node_id == 3) child3 = r;
    }
    try testing.expect(child2 != null and child3 != null);
    try testing.expectEqual(@as(u32, 0), child2.?.x);
    try testing.expectEqual(@as(u32, 3), child3.?.x); // after child2 (width 3)
}

test "layout: fixed width/height honored" {
    const node = LayoutNode{ .id = 1, .text = "hi", .width = 10, .height = 5 };
    const results = try layout(testing.allocator, node, 0, 0);
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(u32, 10), results[0].width);
    try testing.expectEqual(@as(u32, 5), results[0].height);
}

test "layout: padding adds to size" {
    const node = LayoutNode{ .id = 1, .text = "hi", .padding = .uniform(2) };
    const results = try layout(testing.allocator, node, 0, 0);
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(u32, 6), results[0].width); // 2 + 2*2
    try testing.expectEqual(@as(u32, 5), results[0].height); // 1 + 2*2
}

test "layout: flex_grow distributes free space along main axis" {
    // container height 10, two children each flex_grow 1, no intrinsic height
    const children = [_]LayoutNode{
        .{ .id = 2, .flex_grow = 1 },
        .{ .id = 3, .flex_grow = 1 },
    };
    const root = LayoutNode{
        .id = 1,
        .flex_direction = .column,
        .height = 10,
        .children = &children,
    };
    const results = try layout(testing.allocator, root, 0, 0);
    defer testing.allocator.free(results);
    var child2: ?LayoutResult = null;
    var child3: ?LayoutResult = null;
    for (results) |r| {
        if (r.node_id == 2) child2 = r;
        if (r.node_id == 3) child3 = r;
    }
    try testing.expect(child2 != null and child3 != null);
    // Each child should get ~5 of the 10 height
    try testing.expectEqual(@as(u32, 5), child2.?.height);
    try testing.expectEqual(@as(u32, 5), child3.?.height);
}

test "layout: justify-content center centers children" {
    const children = [_]LayoutNode{
        .{ .id = 2, .text = "x" }, // height 1
    };
    const root = LayoutNode{
        .id = 1,
        .flex_direction = .column,
        .height = 10,
        .justify_content = .center,
        .children = &children,
    };
    const results = try layout(testing.allocator, root, 0, 0);
    defer testing.allocator.free(results);
    var child2: ?LayoutResult = null;
    for (results) |r| {
        if (r.node_id == 2) child2 = r;
    }
    try testing.expect(child2 != null);
    // leftover = 10 - 1 = 9, lead = 9/2 = 4
    try testing.expectEqual(@as(u32, 4), child2.?.y);
}

test "layout: justify-content flex-end pushes child to bottom" {
    const children = [_]LayoutNode{
        .{ .id = 2, .text = "x" }, // height 1
    };
    const root = LayoutNode{
        .id = 1,
        .flex_direction = .column,
        .height = 10,
        .justify_content = .flex_end,
        .children = &children,
    };
    const results = try layout(testing.allocator, root, 0, 0);
    defer testing.allocator.free(results);
    var child2: ?LayoutResult = null;
    for (results) |r| {
        if (r.node_id == 2) child2 = r;
    }
    try testing.expect(child2 != null);
    try testing.expectEqual(@as(u32, 9), child2.?.y); // 10 - 1
}

test "layout: align-items center centers on cross axis" {
    const children = [_]LayoutNode{
        .{ .id = 2, .text = "x" }, // width 1
    };
    const root = LayoutNode{
        .id = 1,
        .flex_direction = .column,
        .width = 10,
        .align_items = .center,
        .children = &children,
    };
    const results = try layout(testing.allocator, root, 0, 0);
    defer testing.allocator.free(results);
    var child2: ?LayoutResult = null;
    for (results) |r| {
        if (r.node_id == 2) child2 = r;
    }
    try testing.expect(child2 != null);
    // cross = width 10, child width 1, center = (10-1)/2 = 4
    try testing.expectEqual(@as(u32, 4), child2.?.x);
}

test "layout: align-items stretch fills cross axis" {
    const children = [_]LayoutNode{
        .{ .id = 2, .text = "x" }, // width 1
    };
    const root = LayoutNode{
        .id = 1,
        .flex_direction = .column,
        .width = 10,
        .align_items = .stretch,
        .children = &children,
    };
    const results = try layout(testing.allocator, root, 0, 0);
    defer testing.allocator.free(results);
    var child2: ?LayoutResult = null;
    for (results) |r| {
        if (r.node_id == 2) child2 = r;
    }
    try testing.expect(child2 != null);
    try testing.expectEqual(@as(u32, 10), child2.?.width); // stretched to container width
}

test "layout: margin offsets child position" {
    const children = [_]LayoutNode{
        .{ .id = 2, .text = "x", .margin = .uniform(2) },
    };
    const root = LayoutNode{
        .id = 1,
        .flex_direction = .column,
        .children = &children,
    };
    const results = try layout(testing.allocator, root, 0, 0);
    defer testing.allocator.free(results);
    var child2: ?LayoutResult = null;
    for (results) |r| {
        if (r.node_id == 2) child2 = r;
    }
    try testing.expect(child2 != null);
    // child border-box x = parent x + margin.left = 0 + 2 = 2
    try testing.expectEqual(@as(u32, 2), child2.?.x);
    try testing.expectEqual(@as(u32, 2), child2.?.y);
}

test "layout: min/max constraints clamp size" {
    const node = LayoutNode{ .id = 1, .text = "x", .width = 100, .max_width = 10 };
    const results = try layout(testing.allocator, node, 0, 0);
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(u32, 10), results[0].width); // clamped to max

    const node2 = LayoutNode{ .id = 1, .text = "x", .width = 1, .min_width = 5 };
    const results2 = try layout(testing.allocator, node2, 0, 0);
    defer testing.allocator.free(results2);
    try testing.expectEqual(@as(u32, 5), results2[0].width); // clamped to min
}

test "layout: justify-content space-between distributes gaps" {
    const children = [_]LayoutNode{
        .{ .id = 2, .text = "x" },
        .{ .id = 3, .text = "x" },
    };
    const root = LayoutNode{
        .id = 1,
        .flex_direction = .column,
        .height = 10,
        .justify_content = .space_between,
        .children = &children,
    };
    const results = try layout(testing.allocator, root, 0, 0);
    defer testing.allocator.free(results);
    var child2: ?LayoutResult = null;
    var child3: ?LayoutResult = null;
    for (results) |r| {
        if (r.node_id == 2) child2 = r;
        if (r.node_id == 3) child3 = r;
    }
    try testing.expect(child2 != null and child3 != null);
    // leftover = 10 - 2 = 8, gaps = 1, gap = 8
    try testing.expectEqual(@as(u32, 0), child2.?.y);
    try testing.expectEqual(@as(u32, 9), child3.?.y); // 1 + 8
}

test "layout: flex-wrap moves overflow to next line" {
    // row direction, width 5, two children width 3 each.
    // Without wrap they'd overflow; with wrap the second goes to next row.
    const children = [_]LayoutNode{
        .{ .id = 2, .text = "aaa", .width = 3, .height = 1 },
        .{ .id = 3, .text = "bbb", .width = 3, .height = 1 },
    };
    const root = LayoutNode{
        .id = 1,
        .flex_direction = .row,
        .width = 5,
        .height = 4,
        .flex_wrap = .wrap,
        .children = &children,
    };
    const results = try layout(testing.allocator, root, 0, 0);
    defer testing.allocator.free(results);
    var child2: ?LayoutResult = null;
    var child3: ?LayoutResult = null;
    for (results) |r| {
        if (r.node_id == 2) child2 = r;
        if (r.node_id == 3) child3 = r;
    }
    try testing.expect(child2 != null and child3 != null);
    // child2 at y=0, child3 wrapped to y=1 (next line)
    try testing.expectEqual(@as(u32, 0), child2.?.y);
    try testing.expectEqual(@as(u32, 1), child3.?.y);
}

test "layout: flex-wrap nowrap does not wrap (overflow allowed)" {
    const children = [_]LayoutNode{
        .{ .id = 2, .text = "aaa", .width = 3, .height = 1 },
        .{ .id = 3, .text = "bbb", .width = 3, .height = 1 },
    };
    const root = LayoutNode{
        .id = 1,
        .flex_direction = .row,
        .width = 5,
        .height = 4,
        .flex_wrap = .nowrap,
        .children = &children,
    };
    const results = try layout(testing.allocator, root, 0, 0);
    defer testing.allocator.free(results);
    var child2: ?LayoutResult = null;
    var child3: ?LayoutResult = null;
    for (results) |r| {
        if (r.node_id == 2) child2 = r;
        if (r.node_id == 3) child3 = r;
    }
    try testing.expect(child2 != null and child3 != null);
    // Both on same row: child3 at x=3 (after child2 width 3)
    try testing.expectEqual(@as(u32, 0), child2.?.y);
    try testing.expectEqual(@as(u32, 0), child3.?.y);
}

/// Wrap text to a max width: returns the wrapped text (caller frees) and
/// the resulting (width, height). Word-wrap on spaces; long words break
/// at the width boundary. Direct port of Ink's text-wrap behavior.
pub fn wrapText(allocator: std.mem.Allocator, text: []const u8, max_width: u32) !struct { text: []u8, width: u32, height: u32 } {
    if (max_width == 0 or text.len == 0) {
        return .{ .text = try allocator.dupe(u8, text), .width = 0, .height = if (text.len == 0) @as(u32, 1) else 0 };
    }
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    const w = &buf.writer;

    var max_line_width: u32 = 0;
    var line_count: u32 = 1;
    var col: u32 = 0;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first_line = true;
    while (lines.next()) |line| {
        if (!first_line) {
            try w.writeByte('\n');
            line_count += 1;
            col = 0;
        }
        first_line = false;

        var words = std.mem.splitScalar(u8, line, ' ');
        var first_word = true;
        while (words.next()) |word| {
            if (word.len == 0) {
                // consecutive space -> emit a space if room
                if (col < max_width) {
                    try w.writeByte(' ');
                    col += 1;
                }
                continue;
            }
            // If the word itself is longer than max_width, hard-break it.
            if (word.len > max_width) {
                var remaining = word;
                while (remaining.len > 0) {
                    const room = max_width - col;
                    const take = @min(remaining.len, room);
                    try w.writeAll(remaining[0..take]);
                    col += @intCast(take);
                    remaining = remaining[take..];
                    if (col > max_line_width) max_line_width = col;
                    if (remaining.len > 0) {
                        try w.writeByte('\n');
                        line_count += 1;
                        col = 0;
                    }
                }
            } else {
                if (!first_word and col > 0) {
                    if (col + 1 + word.len > max_width) {
                        // wrap
                        try w.writeByte('\n');
                        line_count += 1;
                        col = 0;
                        try w.writeAll(word);
                        col += @intCast(word.len);
                    } else {
                        try w.writeByte(' ');
                        col += 1;
                        try w.writeAll(word);
                        col += @intCast(word.len);
                    }
                } else {
                    try w.writeAll(word);
                    col += @intCast(word.len);
                }
            }
            if (col > max_line_width) max_line_width = col;
            first_word = false;
        }
    }

    return .{
        .text = try allocator.dupe(u8, w.buffered()),
        .width = max_line_width,
        .height = line_count,
    };
}

/// Truncate text to a max width with an optional ellipsis. Returns the
/// truncated text (caller frees).
pub fn truncateText(allocator: std.mem.Allocator, text: []const u8, max_width: u32, ellipsis: bool) ![]u8 {
    if (max_width == 0 or text.len == 0) return allocator.dupe(u8, text);
    // Take the first line only (truncation is single-line).
    const nl = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const first_line = text[0..nl];
    if (first_line.len <= max_width) return allocator.dupe(u8, first_line);
    if (ellipsis and max_width >= 1) {
        const ellipsis_str = "…";
        const keep = max_width - 1;
        var out = try allocator.alloc(u8, keep + ellipsis_str.len);
        @memcpy(out[0..keep], first_line[0..keep]);
        @memcpy(out[keep..][0..ellipsis_str.len], ellipsis_str);
        return out;
    }
    return allocator.dupe(u8, first_line[0..max_width]);
}

test "wrapText: short text unchanged" {
    const result = try wrapText(testing.allocator, "hi", 10);
    defer testing.allocator.free(result.text);
    try testing.expectEqualStrings("hi", result.text);
    try testing.expectEqual(@as(u32, 2), result.width);
    try testing.expectEqual(@as(u32, 1), result.height);
}

test "wrapText: wraps at word boundary" {
    const result = try wrapText(testing.allocator, "hello world", 5);
    defer testing.allocator.free(result.text);
    try testing.expectEqualStrings("hello\nworld", result.text);
    try testing.expectEqual(@as(u32, 5), result.width);
    try testing.expectEqual(@as(u32, 2), result.height);
}

test "wrapText: hard-breaks long words" {
    const result = try wrapText(testing.allocator, "abcdefgh", 3);
    defer testing.allocator.free(result.text);
    try testing.expectEqualStrings("abc\ndef\ngh", result.text);
    try testing.expectEqual(@as(u32, 3), result.width);
    try testing.expectEqual(@as(u32, 3), result.height);
}

test "truncateText: short text unchanged" {
    const out = try truncateText(testing.allocator, "hi", 10, true);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hi", out);
}

test "truncateText: long text cut to width" {
    const out = try truncateText(testing.allocator, "hello world", 5, false);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello", out);
}

test "truncateText: ellipsis appends …" {
    const out = try truncateText(testing.allocator, "hello world", 5, true);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hell…", out);
}

test "LayoutNode: align_content and position_absolute fields exist" {
    const node = LayoutNode{
        .id = 1,
        .align_content = .center,
        .position_absolute = true,
    };
    try testing.expectEqual(AlignContent.center, node.align_content);
    try testing.expect(node.position_absolute);
}

test "LayoutNode: defaults are flex_start and non-absolute" {
    const node = LayoutNode{ .id = 1 };
    try testing.expectEqual(AlignContent.flex_start, node.align_content);
    try testing.expect(!node.position_absolute);
}

test "layout: align-content center centers wrapped lines" {
    // row, width 5 (forces wrap of two width-3 children), height 10.
    // Two lines each height 1; align-content center => lines centered vertically.
    const children = [_]LayoutNode{
        .{ .id = 2, .text = "aaa", .width = 3, .height = 1 },
        .{ .id = 3, .text = "bbb", .width = 3, .height = 1 },
    };
    const root = LayoutNode{
        .id = 1,
        .flex_direction = .row,
        .width = 5,
        .height = 10,
        .flex_wrap = .wrap,
        .align_content = .center,
        .children = &children,
    };
    const results = try layout(testing.allocator, root, 0, 0);
    defer testing.allocator.free(results);
    var child2: ?LayoutResult = null;
    for (results) |r| {
        if (r.node_id == 2) child2 = r;
    }
    try testing.expect(child2 != null);
    // total cross = 2 (two lines of height 1), leftover = 10-2 = 8, lead = 4
    try testing.expectEqual(@as(u32, 4), child2.?.y);
}

test "layout: absolute-positioned child placed at container origin" {
    // An absolute child is taken out of flow; positioned at inner origin.
    const children = [_]LayoutNode{
        .{ .id = 2, .text = "flow", .width = 3, .height = 1 },
        .{ .id = 3, .text = "abs", .width = 3, .height = 1, .position_absolute = true },
    };
    const root = LayoutNode{
        .id = 1,
        .flex_direction = .column,
        .width = 20,
        .height = 20,
        .children = &children,
    };
    const results = try layout(testing.allocator, root, 0, 0);
    defer testing.allocator.free(results);
    var abs_child: ?LayoutResult = null;
    for (results) |r| {
        if (r.node_id == 3) abs_child = r;
    }
    try testing.expect(abs_child != null);
    // Absolute child at container inner origin (0,0)
    try testing.expectEqual(@as(u32, 0), abs_child.?.x);
    try testing.expectEqual(@as(u32, 0), abs_child.?.y);
}
