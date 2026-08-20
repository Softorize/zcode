//! #575: Button component - a clickable/styled text element.
//!
//! Direct port of reference src/ink/components/Button.tsx concept.
//! In Ink, Button renders text with a style and handles focus/click.
//! zcode's version maps to a Text RenderCommand with a "button" style
//! (inverse video to indicate focusability).

const std = @import("std");
const ink_render = @import("../../core/ink_render.zig");

pub const ButtonProps = struct {
    text: []const u8,
    focused: bool = false,
    color: ?ink_render.Color = null,
};

/// Build a RenderCommand for a Button. When focused, the button uses
/// inverse video (swap fg/bg) to indicate focus state, matching the
/// reference's focused-button rendering.
pub fn render(props: ButtonProps) ink_render.RenderCommand {
    if (props.focused) {
        return .{
            .node_id = 0,
            .text = props.text,
            .style = .{
                .fg = props.color,
                .inverse = true,
            },
        };
    }
    return .{
        .node_id = 0,
        .text = props.text,
        .style = .{
            .fg = props.color,
        },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Button.render: unfocused has no inverse" {
    const cmd = render(.{ .text = "OK" });
    try testing.expectEqualStrings("OK", cmd.text);
    try testing.expect(!cmd.style.inverse);
}

test "Button.render: focused uses inverse video" {
    const cmd = render(.{ .text = "OK", .focused = true });
    try testing.expect(cmd.style.inverse);
}

test "Button.render: color passed through" {
    const cmd = render(.{ .text = "OK", .color = .green });
    try testing.expectEqual(ink_render.Color.green, cmd.style.fg.?);
}
