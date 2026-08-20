//! Per-session prompt-bar accent color palette (commands-sweep-03).
//!
//! Mirrors the reference `/color` command's palette and reset aliases
//! (Claude Code `src/tools/AgentTool/agentColorManager.ts AGENT_COLORS`
//! and `src/commands/color/color.ts RESET_ALIASES`). This module is
//! pure: it only validates names and renders the palette as text. The
//! actual persistence lives in the session store sidecar (`<id>.color`)
//! and the `/color` REPL handler wires the two together.
//!
//! Note (honest divergence): zcode's prompt-bar renderer uses a single
//! fixed brand accent theme and does not yet accept a per-session accent
//! color, so the chosen color is persisted and reported but the visual
//! accent is not applied. The reference also has a swarm "teammate" guard
//! that has no zcode analogue, so it is intentionally omitted.

const std = @import("std");

/// The fixed accent palette, in the same order as the reference
/// AGENT_COLORS array so the listed palette matches Claude Code.
pub const AGENT_COLORS = [_][]const u8{
    "red",
    "blue",
    "green",
    "yellow",
    "purple",
    "orange",
    "pink",
    "cyan",
};

/// Names that reset the session color back to the default. Mirrors the
/// reference RESET_ALIASES (`default`, `reset`, `none`, `gray`, `grey`).
pub const RESET_ALIASES = [_][]const u8{
    "default",
    "reset",
    "none",
    "gray",
    "grey",
};

/// Case-insensitive equality for ASCII color tokens.
fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// True when `name` is one of the palette colors (case-insensitive).
pub fn isValid(name: []const u8) bool {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    for (AGENT_COLORS) |c| {
        if (eqlIgnoreCase(trimmed, c)) return true;
    }
    return false;
}

/// True when `name` is a reset alias (case-insensitive).
pub fn isReset(name: []const u8) bool {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    for (RESET_ALIASES) |c| {
        if (eqlIgnoreCase(trimmed, c)) return true;
    }
    return false;
}

/// Return the palette color that `name` matches (lower-cased canonical
/// form), or null when it is not a valid palette color. Lets the caller
/// persist a normalized value regardless of input casing.
pub fn canonical(name: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    for (AGENT_COLORS) |c| {
        if (eqlIgnoreCase(trimmed, c)) return c;
    }
    return null;
}

/// Render the palette as a comma-separated list (e.g. "red, blue, ...").
/// Caller owns the returned slice.
pub fn paletteCsv(allocator: std.mem.Allocator) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    for (AGENT_COLORS, 0..) |c, i| {
        if (i != 0) try out.appendSlice(", ");
        try out.appendSlice(c);
    }
    return out.toOwnedSlice();
}

const testing = std.testing;

test "isValid recognizes palette colors case-insensitively" {
    try testing.expect(isValid("blue"));
    try testing.expect(isValid("BLUE"));
    try testing.expect(isValid("  cyan  "));
    try testing.expect(!isValid("blurple"));
    try testing.expect(!isValid(""));
}

test "isReset recognizes reset aliases" {
    try testing.expect(isReset("gray"));
    try testing.expect(isReset("grey"));
    try testing.expect(isReset("default"));
    try testing.expect(isReset("reset"));
    try testing.expect(isReset("none"));
    try testing.expect(!isReset("blue"));
}

test "canonical lowercases the matched palette entry" {
    try testing.expectEqualStrings("green", canonical("GREEN").?);
    try testing.expectEqual(@as(?[]const u8, null), canonical("notacolor"));
}

test "paletteCsv lists every color in order" {
    const csv = try paletteCsv(testing.allocator);
    defer testing.allocator.free(csv);
    try testing.expectEqualStrings("red, blue, green, yellow, purple, orange, pink, cyan", csv);
}
