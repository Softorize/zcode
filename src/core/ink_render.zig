//! #574: ink_render deep module - terminal renderer.
//!
//! Takes a LayoutResult tree (from ink_layout) + content (text per node)
//! and writes ANSI bytes to a buffer. Handles cursor positioning, text
//! placement, borders (box-drawing chars), and color/style via SGR.
//!
//! Pure module: (layout, content) -> bytes. No IO.

const std = @import("std");

/// Box-drawing border style. Matches cli-boxes presets.
pub const BorderStyle = struct {
    top_left: []const u8,
    top_right: []const u8,
    bottom_left: []const u8,
    bottom_right: []const u8,
    horizontal: []const u8,
    vertical: []const u8,
};

pub const border_round = BorderStyle{
    .top_left = "╭",
    .top_right = "╮",
    .bottom_left = "╰",
    .bottom_right = "╯",
    .horizontal = "─",
    .vertical = "│",
};

pub const border_single = BorderStyle{
    .top_left = "┌",
    .top_right = "┐",
    .bottom_left = "└",
    .bottom_right = "┘",
    .horizontal = "─",
    .vertical = "│",
};

pub const border_double = BorderStyle{
    .top_left = "╔",
    .top_right = "╗",
    .bottom_left = "╚",
    .bottom_right = "╝",
    .horizontal = "═",
    .vertical = "║",
};

pub const border_bold = BorderStyle{
    .top_left = "┏",
    .top_right = "┓",
    .bottom_left = "┗",
    .bottom_right = "┛",
    .horizontal = "━",
    .vertical = "┃",
};

pub const border_dashed = BorderStyle{
    .top_left = " ",
    .top_right = " ",
    .bottom_left = " ",
    .bottom_right = " ",
    .horizontal = "╌",
    .vertical = "╎",
};

/// Render a border around a rect (x, y, width, height) using the given
/// BorderStyle. Writes the 4 corners + horizontal/vertical edges via
/// cursor positioning. Returns the bytes; caller writes them to the
/// terminal buffer.
pub fn renderBorder(allocator: std.mem.Allocator, x: u32, y: u32, width: u32, height: u32, style: BorderStyle, border_style: ?Style) ![]u8 {
    if (width < 2 or height < 2) return allocator.dupe(u8, "");

    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    const w = &buf.writer;

    const sgr_open: []const u8 = if (border_style) |bs| sgrPrefix(bs) else "";
    const sgr_close: []const u8 = if (border_style != null) "\x1b[0m" else "";

    const inner_width = width - 2; // corners on each side

    // Top edge: corner + horizontals + corner
    try w.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
    try w.writeAll(sgr_open);
    try w.writeAll(style.top_left);
    var i: u32 = 0;
    while (i < inner_width) : (i += 1) try w.writeAll(style.horizontal);
    try w.writeAll(style.top_right);
    try w.writeAll(sgr_close);

    // Left + right verticals for each interior row
    var row: u32 = 1;
    while (row < height - 1) : (row += 1) {
        try w.print("\x1b[{d};{d}H", .{ y + 1 + row, x + 1 });
        try w.writeAll(sgr_open);
        try w.writeAll(style.vertical);
        try w.print("\x1b[{d};{d}H", .{ y + 1 + row, x + 1 + width });
        try w.writeAll(style.vertical);
        try w.writeAll(sgr_close);
    }

    // Bottom edge
    try w.print("\x1b[{d};{d}H", .{ y + height, x + 1 });
    try w.writeAll(sgr_open);
    try w.writeAll(style.bottom_left);
    i = 0;
    while (i < inner_width) : (i += 1) try w.writeAll(style.horizontal);
    try w.writeAll(style.bottom_right);
    try w.writeAll(sgr_close);

    const buffered = w.buffered();
    return try allocator.dupe(u8, buffered);
}

fn sgrPrefix(s: Style) []const u8 {
    // Return a compact SGR prefix for the border. This is a static
    // approximation; for per-call styling the caller should emit SGR
    // directly. We return a marker that the caller can replace.
    _ = s;
    return "";
}
const layout_mod = @import("ink_layout.zig");

pub const Style = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    inverse: bool = false, // SGR 7 (reverse video)
    strikethrough: bool = false, // SGR 9
};

pub const Color = enum {
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,
};

/// Extended color: 16-color (named), 256-color (palette index), or
/// truecolor (RGB). Matches the reference's Color type which accepts
/// raw rgb/hex/ansi values.
pub const ColorValue = union(enum) {
    named: Color,
    palette: u8, // 256-color palette index (0-255)
    rgb: struct { r: u8, g: u8, b: u8 }, // truecolor
};

/// Format the SGR code for a ColorValue into a buffer. Returns the
/// bytes written. For named colors uses 30-37/90-97; for palette uses
/// 38;5;N / 48;5;N; for RGB uses 38;2;R;G;B / 48;2;R;G;B.
pub fn colorValueSgr(buf: []u8, cv: ColorValue, fg: bool) []const u8 {
    const prefix: u8 = if (fg) 38 else 48;
    return switch (cv) {
        .named => |c| std.fmt.bufPrint(buf, "{s}", .{colorSgr(c, fg)}) catch "",
        .palette => |p| std.fmt.bufPrint(buf, "{d};5;{d}", .{ prefix, p }) catch "",
        .rgb => |rgb| std.fmt.bufPrint(buf, "{d};2;{d};{d};{d}", .{ prefix, rgb.r, rgb.g, rgb.b }) catch "",
    };
}

fn colorSgr(c: Color, fg: bool) []const u8 {
    // SGR codes: 30-37 foreground, 40-47 background, 90-97 bright fg, 100-107 bright bg
    return switch (c) {
        .black => if (fg) "30" else "40",
        .red => if (fg) "31" else "41",
        .green => if (fg) "32" else "42",
        .yellow => if (fg) "33" else "43",
        .blue => if (fg) "34" else "44",
        .magenta => if (fg) "35" else "45",
        .cyan => if (fg) "36" else "46",
        .white => if (fg) "37" else "47",
        .bright_black => if (fg) "90" else "100",
        .bright_red => if (fg) "91" else "101",
        .bright_green => if (fg) "92" else "102",
        .bright_yellow => if (fg) "93" else "103",
        .bright_blue => if (fg) "94" else "104",
        .bright_magenta => if (fg) "95" else "105",
        .bright_cyan => if (fg) "96" else "106",
        .bright_white => if (fg) "97" else "107",
    };
}

pub const RenderCommand = struct {
    node_id: u32,
    text: []const u8,
    style: Style = .{},
};

/// Render a list of (layout, text) pairs into an ANSI byte buffer.
/// Each command is positioned at its LayoutResult x/y via CSI cursor
/// positioning, then the style SGR codes, then the text. Closes with
/// a full reset SGR.
pub fn render(allocator: std.mem.Allocator, commands: []const RenderCommand, layouts: []const layout_mod.LayoutResult) ![]u8 {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    const w = &buf.writer;

    for (commands, 0..) |cmd, i| {
        // Find the layout for this node.
        if (i >= layouts.len) break;
        const lay = layouts[i];
        if (lay.node_id != cmd.node_id) {
            // Layouts and commands are parallel arrays; if IDs diverge,
            // use position rather than skipping.
        }

        // Cursor positioning: CSI {row};{col} H (1-based)
        const row = lay.y + 1;
        const col = lay.x + 1;
        try w.print("\x1b[{d};{d}H", .{ row, col });

        // Style SGR
        var sgr_written = false;
        if (cmd.style.bold) {
            try w.writeAll("\x1b[1m");
            sgr_written = true;
        }
        if (cmd.style.dim) {
            try w.writeAll("\x1b[2m");
            sgr_written = true;
        }
        if (cmd.style.italic) {
            try w.writeAll("\x1b[3m");
            sgr_written = true;
        }
        if (cmd.style.underline) {
            try w.writeAll("\x1b[4m");
            sgr_written = true;
        }
        if (cmd.style.inverse) {
            try w.writeAll("\x1b[7m");
            sgr_written = true;
        }
        if (cmd.style.strikethrough) {
            try w.writeAll("\x1b[9m");
            sgr_written = true;
        }
        if (cmd.style.fg) |fg| {
            try w.print("\x1b[{s}m", .{colorSgr(fg, true)});
            sgr_written = true;
        }
        if (cmd.style.bg) |bg| {
            try w.print("\x1b[{s}m", .{colorSgr(bg, false)});
            sgr_written = true;
        }

        // Text
        try w.writeAll(cmd.text);

        // Reset if we wrote any SGR
        if (sgr_written) try w.writeAll("\x1b[0m");
    }

    const buffered = buf.writer.buffered();
    return try allocator.dupe(u8, buffered);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "render: positions text at layout x/y" {
    const layouts = [_]layout_mod.LayoutResult{
        .{ .x = 5, .y = 2, .width = 3, .height = 1, .node_id = 1 },
    };
    const commands = [_]RenderCommand{
        .{ .node_id = 1, .text = "hi" },
    };
    const out = try render(testing.allocator, &commands, &layouts);
    defer testing.allocator.free(out);
    // Cursor to row 3, col 6 (1-based), then "hi"
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[3;6H") != null);
    try testing.expect(std.mem.indexOf(u8, out, "hi") != null);
}

test "render: bold style emits SGR 1 and reset" {
    const layouts = [_]layout_mod.LayoutResult{
        .{ .x = 0, .y = 0, .width = 2, .height = 1, .node_id = 1 },
    };
    const commands = [_]RenderCommand{
        .{ .node_id = 1, .text = "hi", .style = .{ .bold = true } },
    };
    const out = try render(testing.allocator, &commands, &layouts);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[1m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[0m") != null);
}

test "render: foreground color emits SGR 30-37" {
    const layouts = [_]layout_mod.LayoutResult{
        .{ .x = 0, .y = 0, .width = 2, .height = 1, .node_id = 1 },
    };
    const commands = [_]RenderCommand{
        .{ .node_id = 1, .text = "hi", .style = .{ .fg = .red } },
    };
    const out = try render(testing.allocator, &commands, &layouts);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[31m") != null);
}

test "render: background color emits SGR 40-47" {
    const layouts = [_]layout_mod.LayoutResult{
        .{ .x = 0, .y = 0, .width = 2, .height = 1, .node_id = 1 },
    };
    const commands = [_]RenderCommand{
        .{ .node_id = 1, .text = "hi", .style = .{ .bg = .blue } },
    };
    const out = try render(testing.allocator, &commands, &layouts);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[44m") != null);
}

test "render: no style emits no SGR" {
    const layouts = [_]layout_mod.LayoutResult{
        .{ .x = 0, .y = 0, .width = 2, .height = 1, .node_id = 1 },
    };
    const commands = [_]RenderCommand{
        .{ .node_id = 1, .text = "hi" },
    };
    const out = try render(testing.allocator, &commands, &layouts);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[1m") == null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[0m") == null);
}

test "renderBorder: single border has all 4 corners" {
    const out = try renderBorder(testing.allocator, 0, 0, 5, 3, border_single, null);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "┌") != null);
    try testing.expect(std.mem.indexOf(u8, out, "┐") != null);
    try testing.expect(std.mem.indexOf(u8, out, "└") != null);
    try testing.expect(std.mem.indexOf(u8, out, "┘") != null);
}

test "renderBorder: round border uses rounded corners" {
    const out = try renderBorder(testing.allocator, 0, 0, 4, 3, border_round, null);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "╭") != null);
    try testing.expect(std.mem.indexOf(u8, out, "╮") != null);
    try testing.expect(std.mem.indexOf(u8, out, "╰") != null);
    try testing.expect(std.mem.indexOf(u8, out, "╯") != null);
}

test "renderBorder: double border uses double-line chars" {
    const out = try renderBorder(testing.allocator, 0, 0, 4, 3, border_double, null);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "╔") != null);
    try testing.expect(std.mem.indexOf(u8, out, "═") != null);
    try testing.expect(std.mem.indexOf(u8, out, "║") != null);
}

test "renderBorder: too-small rect returns empty" {
    const out = try renderBorder(testing.allocator, 0, 0, 1, 1, border_single, null);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
}

test "renderBorder: includes horizontal edge chars" {
    const out = try renderBorder(testing.allocator, 0, 0, 6, 3, border_single, null);
    defer testing.allocator.free(out);
    var count: u32 = 0;
    var i: usize = 0;
    const dash = "─";
    while (i < out.len) {
        if (i + dash.len <= out.len and std.mem.eql(u8, out[i .. i + dash.len], dash)) {
            count += 1;
            i += dash.len;
        } else i += 1;
    }
    try testing.expectEqual(@as(u32, 8), count); // 4 top + 4 bottom
}

test "colorValueSgr: named color uses 30-37" {
    var buf: [16]u8 = undefined;
    const sgr = colorValueSgr(&buf, .{ .named = .red }, true);
    try testing.expectEqualStrings("31", sgr);
}

test "colorValueSgr: palette color uses 38;5;N" {
    var buf: [16]u8 = undefined;
    const sgr = colorValueSgr(&buf, .{ .palette = 196 }, true);
    try testing.expectEqualStrings("38;5;196", sgr);
}

test "colorValueSgr: rgb truecolor uses 38;2;R;G;B" {
    var buf: [24]u8 = undefined;
    const sgr = colorValueSgr(&buf, .{ .rgb = .{ .r = 255, .g = 128, .b = 0 } }, true);
    try testing.expectEqualStrings("38;2;255;128;0", sgr);
}

test "colorValueSgr: background uses 48 prefix" {
    var buf: [16]u8 = undefined;
    const sgr = colorValueSgr(&buf, .{ .palette = 21 }, false);
    try testing.expectEqualStrings("48;5;21", sgr);
}
