//! #575: Text component - renders styled text.
//!
//! Direct port of reference src/ink/components/Text.tsx. In Ink, <Text>
//! applies color/weight/style to its string children. zcode's version
//! maps to a RenderCommand with a Style built from the TextProps.

const std = @import("std");
const ink_render = @import("../../core/ink_render.zig");

pub const TextProps = struct {
    text: []const u8,
    color: ?ink_render.Color = null,
    background_color: ?ink_render.Color = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    strikethrough: bool = false,
    inverse: bool = false,
};

/// Build a RenderCommand from TextProps. The caller positions it via
/// the LayoutResult; Text itself is a leaf with no children.
pub fn render(props: TextProps) ink_render.RenderCommand {
    // Compute fg/bg after inverse swap.
    var fg = props.color;
    var bg = props.background_color;
    if (props.inverse) {
        const tmp = fg;
        fg = bg;
        bg = tmp;
    }
    return .{
        .node_id = 0, // caller sets
        .text = props.text,
        .style = .{
            .fg = fg,
            .bg = bg,
            .bold = props.bold,
            .dim = props.dim,
            .italic = props.italic,
            .underline = props.underline,
            .inverse = false, // already handled via swap above
            .strikethrough = props.strikethrough,
        },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Text.render produces a RenderCommand with the text" {
    const cmd = render(.{ .text = "hello" });
    try testing.expectEqualStrings("hello", cmd.text);
}

test "Text.render maps color to style.fg" {
    const cmd = render(.{ .text = "hi", .color = .red });
    try testing.expectEqual(ink_render.Color.red, cmd.style.fg.?);
}

test "Text.render maps bold to style.bold" {
    const cmd = render(.{ .text = "hi", .bold = true });
    try testing.expect(cmd.style.bold);
}

test "Text.render: inverse swaps fg and bg" {
    const cmd = render(.{ .text = "hi", .color = .red, .background_color = .blue, .inverse = true });
    // After swap: fg=blue, bg=red
    try testing.expectEqual(ink_render.Color.blue, cmd.style.fg.?);
    try testing.expectEqual(ink_render.Color.red, cmd.style.bg.?);
}
