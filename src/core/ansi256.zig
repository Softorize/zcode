//! RGB -> xterm-256 quantization (terminal-08).
//!
//! Ports `ansi256_from_rgb` from
//! `claude-code-main/src/native-ts/color-diff/index.ts:95-120`, which is itself
//! a port of the `ansi_colours` Rust crate. Maps a truecolor (r,g,b) value to the
//! nearest xterm-256 palette index, choosing between the 6x6x6 color cube
//! (indices 16..231) and the 24-step grey ramp (indices 232..255) by squared
//! Euclidean distance.
//!
//! This backs Task 16's tmux truecolor->256 clamp when the runtime-rewrite route
//! is chosen. The built-in themes use the auto-select-ansi-palette route instead
//! (see `core/color_level.zig`), so for those this is a standalone utility; it is
//! only load-bearing for clamping *custom* truecolor themes.
//!
//! Pure: no IO, no allocation. Fully deterministic and table-testable.

const std = @import("std");

/// The six channel levels of the xterm 6x6x6 color cube.
pub const CUBE_LEVELS = [6]u8{ 0, 95, 135, 175, 215, 255 };

/// Quantize a single channel (0..255) to its nearest cube level index (0..5).
/// Mirrors the reference's `q()`: the thresholds are the channel midpoints
/// between adjacent CUBE_LEVELS (48, 115, 155, 195, 235).
fn quantizeChannel(c: u8) u8 {
    if (c < 48) return 0;
    if (c < 115) return 1;
    if (c < 155) return 2;
    if (c < 195) return 3;
    if (c < 235) return 4;
    return 5;
}

/// Squared Euclidean distance between two RGB triples. The max value is
/// 3 * 255^2 = 195075, which fits in u32 with plenty of headroom.
fn distSq(r1: u8, g1: u8, b1: u8, r2: u8, g2: u8, b2: u8) u32 {
    const dr: i32 = @as(i32, r1) - @as(i32, r2);
    const dg: i32 = @as(i32, g1) - @as(i32, g2);
    const db: i32 = @as(i32, b1) - @as(i32, b2);
    return @intCast(dr * dr + dg * dg + db * db);
}

/// Integer round-to-nearest of `num / den` (den > 0, num >= 0).
fn roundDiv(num: u32, den: u32) u32 {
    return (num + den / 2) / den;
}

/// Map an RGB value to the nearest xterm-256 palette index.
///
/// Returns one of:
///   - 16          for near-black,
///   - 16..231     a 6x6x6 cube index, or
///   - 232..255    a grey-ramp index,
/// whichever is perceptually closest (squared-distance) per the reference.
pub fn ansi256FromRgb(r: u8, g: u8, b: u8) u8 {
    const qr = quantizeChannel(r);
    const qg = quantizeChannel(g);
    const qb = quantizeChannel(b);
    const cube_idx: u8 = 16 + 36 * qr + 6 * qg + qb;

    // Average channel value, rounded -- the grey-ramp candidate's basis.
    const grey: u32 = roundDiv(@as(u32, r) + @as(u32, g) + @as(u32, b), 3);

    // Near-black snaps to cube index 16.
    if (grey < 5) return 16;
    // Near-white that is already a pure grey snaps to the cube corner (231),
    // not the ramp top -- the reference snaps 248,248,242 to cube white.
    if (grey > 244 and qr == qg and qg == qb) return cube_idx;

    // Grey-ramp candidate: levels 8..238 in steps of 10, indices 232..255.
    const grey_level_raw: i64 = @divTrunc(@as(i64, @intCast(grey)) - 8 + 5, 10);
    const grey_level: u32 = @intCast(std.math.clamp(grey_level_raw, 0, 23));
    const grey_idx: u8 = @intCast(232 + grey_level);
    const grey_rgb: u8 = @intCast(8 + grey_level * 10);

    const cr = CUBE_LEVELS[qr];
    const cg = CUBE_LEVELS[qg];
    const cb = CUBE_LEVELS[qb];

    const d_cube = distSq(r, g, b, cr, cg, cb);
    const d_grey = distSq(r, g, b, grey_rgb, grey_rgb, grey_rgb);

    return if (d_grey < d_cube) grey_idx else cube_idx;
}

/// Rewrite a truecolor SGR escape into its 256-color equivalent, writing into
/// `out` and returning the written slice. Supports the foreground form
/// `38;2;r;g;b` and the background form `48;2;r;g;b`; any other input is copied
/// through unchanged.
///
/// `sgr` is the SGR *body* (the parameters between `\x1b[` and the final `m`),
/// e.g. `"48;2;95;212;160"`. The returned body uses `38;5;N` / `48;5;N`.
/// `out` must be at least 8 bytes (`"48;5;NNN"` is the longest output).
pub fn rewriteTruecolorSgr(sgr: []const u8, out: []u8) []const u8 {
    const fg_prefix = "38;2;";
    const bg_prefix = "48;2;";
    var is_fg = false;
    var rest: []const u8 = undefined;
    if (std.mem.startsWith(u8, sgr, fg_prefix)) {
        is_fg = true;
        rest = sgr[fg_prefix.len..];
    } else if (std.mem.startsWith(u8, sgr, bg_prefix)) {
        is_fg = false;
        rest = sgr[bg_prefix.len..];
    } else {
        // Not a truecolor escape -- pass through.
        const n = @min(sgr.len, out.len);
        @memcpy(out[0..n], sgr[0..n]);
        return out[0..n];
    }

    var it = std.mem.splitScalar(u8, rest, ';');
    const r = std.fmt.parseInt(u8, it.next() orelse return passthrough(sgr, out), 10) catch return passthrough(sgr, out);
    const g = std.fmt.parseInt(u8, it.next() orelse return passthrough(sgr, out), 10) catch return passthrough(sgr, out);
    const b = std.fmt.parseInt(u8, it.next() orelse return passthrough(sgr, out), 10) catch return passthrough(sgr, out);

    const idx = ansi256FromRgb(r, g, b);
    const prefix: []const u8 = if (is_fg) "38;5;" else "48;5;";
    return std.fmt.bufPrint(out, "{s}{d}", .{ prefix, idx }) catch passthrough(sgr, out);
}

fn passthrough(sgr: []const u8, out: []u8) []const u8 {
    const n = @min(sgr.len, out.len);
    @memcpy(out[0..n], sgr[0..n]);
    return out[0..n];
}

// -- Tests ----------------------------------------------------------------

const testing = std.testing;

test "black maps to cube index 16" {
    try testing.expectEqual(@as(u8, 16), ansi256FromRgb(0, 0, 0));
}

test "white maps to cube corner 231 not the grey ramp top" {
    try testing.expectEqual(@as(u8, 231), ansi256FromRgb(255, 255, 255));
}

test "brand accent dark maps to a plausible cube index" {
    // (95,212,160): qr=1, qg=4, qb=3 -> cube 16+36+24+3 = 79. The grey ramp is
    // far from a saturated green, so the cube wins.
    const idx = ansi256FromRgb(95, 212, 160);
    try testing.expectEqual(@as(u8, 79), idx);
    try testing.expect(idx >= 16 and idx <= 231);
}

test "pure mid grey maps into the grey ramp" {
    // (128,128,128): grey=128, greyLevel=round((128-8)/10)=12 -> idx 244,
    // greyRgb=128 -- an exact grey-ramp hit, distance 0, beats the cube.
    const idx = ansi256FromRgb(128, 128, 128);
    try testing.expect(idx >= 232 and idx <= 255);
    try testing.expectEqual(@as(u8, 244), idx);
}

test "near-black grey snaps to 16" {
    // grey=2 < 5 -> always 16.
    try testing.expectEqual(@as(u8, 16), ansi256FromRgb(2, 2, 2));
    try testing.expectEqual(@as(u8, 16), ansi256FromRgb(4, 0, 0));
}

test "grey ramp explicit tie-break: dark grey prefers ramp over cube" {
    // (88,88,88): grey=88, greyLevel=round((88-8)/10)=8 -> idx 240, greyRgb=88
    // (exact). Cube quant for 88 is level 1 (95), so the grey ramp is closer.
    const idx = ansi256FromRgb(88, 88, 88);
    try testing.expectEqual(@as(u8, 240), idx);
}

test "cube levels boundary: 95 quantizes to cube level 1" {
    // A non-grey color whose channels sit exactly on cube levels lands on the
    // cube exactly. (95,135,175) -> qr=1,qg=2,qb=3 -> 16+36+12+3 = 67.
    try testing.expectEqual(@as(u8, 67), ansi256FromRgb(95, 135, 175));
}

test "rewriteTruecolorSgr rewrites background truecolor to 256" {
    var buf: [16]u8 = undefined;
    const out = rewriteTruecolorSgr("48;2;0;0;0", &buf);
    try testing.expectEqualStrings("48;5;16", out);
}

test "rewriteTruecolorSgr rewrites foreground truecolor to 256" {
    var buf: [16]u8 = undefined;
    const out = rewriteTruecolorSgr("38;2;255;255;255", &buf);
    try testing.expectEqualStrings("38;5;231", out);
}

test "rewriteTruecolorSgr passes non-truecolor escapes through unchanged" {
    var buf: [16]u8 = undefined;
    const out = rewriteTruecolorSgr("1", &buf);
    try testing.expectEqualStrings("1", out);
    const out2 = rewriteTruecolorSgr("38;5;42", &buf);
    try testing.expectEqualStrings("38;5;42", out2);
}

test "rewriteTruecolorSgr handles malformed truecolor by passing through" {
    var buf: [16]u8 = undefined;
    // Missing the blue channel -- not parseable, pass through.
    const out = rewriteTruecolorSgr("48;2;10;20", &buf);
    try testing.expectEqualStrings("48;2;10;20", out);
}
