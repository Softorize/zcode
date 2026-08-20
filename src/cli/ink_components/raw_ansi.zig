//! #575: RawAnsi component - bypass the render tree for pre-rendered ANSI.
//!
//! Direct port of reference src/ink/components/RawAnsi.tsx.
//! Used when an external renderer has already produced ANSI-escaped,
//! width-wrapped output. A normal render would reparse the ANSI into
//! spans and re-emit; RawAnsi hands the joined string straight to
//! output, avoiding that roundtrip.
//!
//! zcode's version emits the joined lines as a single RenderCommand
//! with no style (the ANSI codes are already inline in the text).

const std = @import("std");
const ink_render = @import("../../core/ink_render.zig");

pub const RawAnsiProps = struct {
    lines: []const []const u8, // each line is one terminal row, already wrapped
    width: u32, // column width the producer wrapped to
};

/// Join the lines into a single string (newline-separated) and build a
/// RenderCommand. The caller positions it via a LayoutResult with the
/// given width.
pub fn renderCommand(allocator: std.mem.Allocator, props: RawAnsiProps) !ink_render.RenderCommand {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    for (props.lines, 0..) |line, i| {
        if (i > 0) try buf.writer.writeByte('\n');
        try buf.writer.writeAll(line);
    }
    const text = try allocator.dupe(u8, buf.writer.buffered());
    return .{
        .node_id = 0,
        .text = text,
        .style = .{}, // no style - ANSI codes are inline
    };
}

/// Measure a RawAnsi block: width is the producer-specified width,
/// height is the line count.
pub fn measure(props: RawAnsiProps) struct { width: u32, height: u32 } {
    return .{ .width = props.width, .height = @intCast(props.lines.len) };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "renderCommand: joins lines with newlines" {
    const lines = [_][]const u8{ "line1", "line2", "line3" };
    const cmd = try renderCommand(testing.allocator, .{ .lines = &lines, .width = 5 });
    defer testing.allocator.free(cmd.text);
    try testing.expectEqualStrings("line1\nline2\nline3", cmd.text);
}

test "renderCommand: single line has no leading newline" {
    const lines = [_][]const u8{"only"};
    const cmd = try renderCommand(testing.allocator, .{ .lines = &lines, .width = 4 });
    defer testing.allocator.free(cmd.text);
    try testing.expectEqualStrings("only", cmd.text);
}

test "renderCommand: empty lines array produces empty text" {
    const lines = [_][]const u8{};
    const cmd = try renderCommand(testing.allocator, .{ .lines = &lines, .width = 0 });
    defer testing.allocator.free(cmd.text);
    try testing.expectEqualStrings("", cmd.text);
}

test "measure: width from props, height from line count" {
    const lines = [_][]const u8{ "a", "b", "c", "d" };
    const m = measure(.{ .lines = &lines, .width = 10 });
    try testing.expectEqual(@as(u32, 10), m.width);
    try testing.expectEqual(@as(u32, 4), m.height);
}
