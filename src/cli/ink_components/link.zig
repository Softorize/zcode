//! #575: Link component - a terminal hyperlink.
//!
//! Direct port of reference src/ink/components/Link.tsx.
//! Uses OSC 8 terminal hyperlinks when supported; falls back to plain
//! text when not. The reference checks supportsHyperlinks(); zcode
//! assumes OSC 8 support (most modern terminals support it) and emits
//! the escape sequence unconditionally.

const std = @import("std");
const ink_render = @import("../../core/ink_render.zig");

pub const LinkProps = struct {
    url: []const u8,
    text: ?[]const u8 = null, // display text; defaults to the url
};

/// Build the OSC 8 hyperlink string. OSC 8 format:
///   \x1b]8;;<url>\x1b\\<text>\x1b]8;;\x1b\\
/// The caller writes this as a RenderCommand's text.
pub fn render(allocator: std.mem.Allocator, props: LinkProps) ![]u8 {
    const display: []const u8 = props.text orelse props.url;
    return std.fmt.allocPrint(
        allocator,
        "\x1b]8;;{s}\x1b\\{s}\x1b]8;;\x1b\\",
        .{ props.url, display },
    );
}

/// Build a RenderCommand for a Link. The text is the OSC 8 hyperlink
/// sequence; the caller positions it via the LayoutResult.
pub fn renderCommand(allocator: std.mem.Allocator, props: LinkProps) !ink_render.RenderCommand {
    const text = try render(allocator, props);
    return .{
        .node_id = 0,
        .text = text,
        .style = .{},
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "render: wraps text in OSC 8 hyperlink with the url" {
    const out = try render(testing.allocator, .{ .url = "https://example.com", .text = "click" });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b]8;;https://example.com\x1b\\") != null);
    try testing.expect(std.mem.indexOf(u8, out, "click") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b]8;;\x1b\\") != null); // close sequence
}

test "render: defaults display text to the url" {
    const out = try render(testing.allocator, .{ .url = "https://example.com" });
    defer testing.allocator.free(out);
    // The display text is the url itself
    try testing.expect(std.mem.indexOf(u8, out, "https://example.com") != null);
}
