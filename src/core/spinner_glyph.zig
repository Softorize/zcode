const std = @import("std");

/// Pure helpers for the animated thinking-spinner leading glyph, ported
/// from claude-code-main/src/components/Spinner/SpinnerGlyph.tsx and
/// Spinner/utils.ts. No IO, no allocation -- the threaded spinner loop in
/// src/cli/repl_spinner.zig calls these to pick the glyph for the current
/// frame and to color it as the turn stalls.
///
/// Reference behavior reproduced here:
///   - getDefaultCharacters(): a 6-glyph "morph" set chosen by platform
///     and TERM. The reference uses `·✢✳✶✻✽` on darwin, swaps `✳`->`*`
///     on non-darwin (the asterisk renders more reliably), and swaps the
///     final `✽`->`*` for `xterm-ghostty` (where `✽` is offset).
///   - SPINNER_FRAMES = [...set, ...reversed(set)] -> 12 frames that
///     breathe outward then back, so the cycle has no visible jump.
///   - interpolateColor(): per-channel rounded linear interpolation.
///   - reducedMotion: a 2000ms cycle (1s lit, 1s dim) on a `●` dot.
///   - stalledIntensity: lerp the glyph color from the theme accent
///     toward error red (171,43,63) as the turn stalls.
pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn eql(self: Rgb, other: Rgb) bool {
        return self.r == other.r and self.g == other.g and self.b == other.b;
    }
};

/// The reference's ERROR_RED -- the stalled color the glyph drifts toward.
/// Matches ui_theme.zig's error_prefix / code_number (171,43,63).
pub const ERROR_RED: Rgb = .{ .r = 171, .g = 43, .b = 63 };

/// The reduced-motion dot (U+25CF BLACK CIRCLE).
pub const REDUCED_MOTION_DOT: []const u8 = "\xe2\x97\x8f";

/// Half of the 2-second reduced-motion cycle, in milliseconds. The dot is
/// lit for the first 1000ms and dim for the next 1000ms.
pub const REDUCED_MOTION_HALF_MS: usize = 1000;

// The morph glyphs, as UTF-8 byte sequences. The comment shows the glyph
// and its code point for grep-ability.
const MIDDLE_DOT: []const u8 = "\xc2\xb7"; //         · U+00B7 MIDDLE DOT
const FOUR_TEARDROP: []const u8 = "\xe2\x9c\xa2"; // ✢ U+2722 FOUR TEARDROP-SPOKED ASTERISK
const EIGHT_SPOKED: []const u8 = "\xe2\x9c\xb3"; //  ✳ U+2733 EIGHT SPOKED ASTERISK
const SIX_POINTED: []const u8 = "\xe2\x9c\xb6"; //   ✶ U+2736 SIX POINTED BLACK STAR
const TEARDROP_ASTERISK: []const u8 = "\xe2\x9c\xbb"; // ✻ U+273B TEARDROP-SPOKED ASTERISK
const HEAVY_TEARDROP: []const u8 = "\xe2\x9c\xbd"; // ✽ U+273D HEAVY TEARDROP-SPOKED PINWHEEL ASTERISK
const ASTERISK: []const u8 = "*"; //                 * U+002A ASTERISK

/// Number of glyphs in a default-character set.
pub const SET_LEN: usize = 6;

/// Total frame count: the 6-glyph set forward then reversed.
pub const FRAME_COUNT: usize = SET_LEN * 2;

/// Select the 6-glyph morph set per the reference rules.
///
/// `term` is the value of $TERM (may be empty); `is_darwin` is whether the
/// host is macOS. Returns a fixed array (no allocation); the slices point
/// at module-level static byte literals, so the result outlives any caller.
pub fn defaultCharacters(term: []const u8, is_darwin: bool) [SET_LEN][]const u8 {
    if (std.mem.eql(u8, term, "xterm-ghostty")) {
        // Ghostty renders ✽ slightly offset, so use * for the last glyph.
        return .{ MIDDLE_DOT, FOUR_TEARDROP, EIGHT_SPOKED, SIX_POINTED, TEARDROP_ASTERISK, ASTERISK };
    }
    if (is_darwin) {
        return .{ MIDDLE_DOT, FOUR_TEARDROP, EIGHT_SPOKED, SIX_POINTED, TEARDROP_ASTERISK, HEAVY_TEARDROP };
    }
    // Non-darwin: ✳ renders unreliably in some terminals, use * instead.
    return .{ MIDDLE_DOT, FOUR_TEARDROP, ASTERISK, SIX_POINTED, TEARDROP_ASTERISK, HEAVY_TEARDROP };
}

/// Return the glyph for the given frame index over the 12-frame
/// forward-then-reversed sequence. Frames 0..5 walk the set forward;
/// frames 6..11 walk it backward (frame 6 is the turn-around, equal to the
/// last set glyph). The index wraps modulo FRAME_COUNT.
pub fn frameGlyph(frame: usize, set: [SET_LEN][]const u8) []const u8 {
    const idx = frame % FRAME_COUNT;
    if (idx < SET_LEN) {
        return set[idx];
    }
    // Reversed half: idx SET_LEN..FRAME_COUNT-1 maps to set[SET_LEN-1 .. 0].
    const back = FRAME_COUNT - 1 - idx; // idx=6 -> 5, idx=11 -> 0
    return set[back];
}

/// Per-channel rounded linear interpolation from `base` toward `target`.
/// `t_percent` is 0..100 (clamped); 0 returns `base`, 100 returns `target`.
/// Rounds to nearest like the reference's Math.round.
pub fn interpolateRgb(base: Rgb, target: Rgb, t_percent: usize) Rgb {
    const t = @min(t_percent, 100);
    return .{
        .r = lerpChannel(base.r, target.r, t),
        .g = lerpChannel(base.g, target.g, t),
        .b = lerpChannel(base.b, target.b, t),
    };
}

fn lerpChannel(a: u8, b: u8, t_percent: usize) u8 {
    // result = round(a + (b - a) * t/100), done with signed integer math so
    // a downward interpolation (b < a) rounds correctly too.
    const ai: i64 = a;
    const bi: i64 = b;
    const diff = bi - ai;
    const ti: i64 = @intCast(t_percent);
    // Add 50 before dividing by 100 to round to nearest. diff*ti can be
    // negative, so adjust the rounding bias by the sign of the product.
    const scaled = diff * ti;
    const rounded = if (scaled >= 0)
        @divTrunc(scaled + 50, 100)
    else
        @divTrunc(scaled - 50, 100);
    const out = ai + rounded;
    return @intCast(std.math.clamp(out, 0, 255));
}

/// Reduced-motion dim phase: true when the flashing dot should be dim.
/// Matches the reference `Math.floor(time / (CYCLE/2)) % 2 === 1`, i.e. a
/// 2000ms cycle that is lit for the first 1000ms and dim for the next.
pub fn reducedMotionDim(time_ms: usize) bool {
    return (time_ms / REDUCED_MOTION_HALF_MS) % 2 == 1;
}

/// Stalled intensity as a 0..100 percentage given how long the turn has been
/// stalled. The reference ramps from 0 toward 1 over a window; here the ramp
/// runs from `stall_start_ms` to `stall_full_ms` of stall duration. Below the
/// start it is 0 (not stalled); at or above full it is 100.
pub fn stalledIntensityPercent(stall_ms: usize, stall_start_ms: usize, stall_full_ms: usize) usize {
    if (stall_ms <= stall_start_ms) return 0;
    if (stall_full_ms <= stall_start_ms) return 100;
    if (stall_ms >= stall_full_ms) return 100;
    const span = stall_full_ms - stall_start_ms;
    const into = stall_ms - stall_start_ms;
    return (into * 100) / span;
}

/// Write a truecolor SGR foreground prefix (`\x1b[38;2;r;g;bm`) for `c` into
/// `buf`, returning the written slice. The caller emits the glyph then a
/// reset. `buf` must be at least 20 bytes.
pub fn writeTrueColorSgr(buf: []u8, c: Rgb) []const u8 {
    return std.fmt.bufPrint(buf, "\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b }) catch buf[0..0];
}

const testing = std.testing;

test "defaultCharacters darwin set" {
    const set = defaultCharacters("xterm-256color", true);
    try testing.expectEqualStrings(MIDDLE_DOT, set[0]);
    try testing.expectEqualStrings(FOUR_TEARDROP, set[1]);
    try testing.expectEqualStrings(EIGHT_SPOKED, set[2]);
    try testing.expectEqualStrings(SIX_POINTED, set[3]);
    try testing.expectEqualStrings(TEARDROP_ASTERISK, set[4]);
    try testing.expectEqualStrings(HEAVY_TEARDROP, set[5]);
}

test "defaultCharacters non-darwin swaps third glyph to asterisk" {
    const set = defaultCharacters("xterm-256color", false);
    try testing.expectEqualStrings(ASTERISK, set[2]);
    // The rest match the darwin set.
    try testing.expectEqualStrings(MIDDLE_DOT, set[0]);
    try testing.expectEqualStrings(HEAVY_TEARDROP, set[5]);
}

test "defaultCharacters ghostty swaps last glyph to asterisk" {
    const set = defaultCharacters("xterm-ghostty", true);
    try testing.expectEqualStrings(ASTERISK, set[5]);
    // The third glyph stays the eight-spoked asterisk on ghostty.
    try testing.expectEqualStrings(EIGHT_SPOKED, set[2]);
}

test "frameGlyph walks forward then reverses (darwin)" {
    const set = defaultCharacters("xterm-256color", true);
    try testing.expectEqualStrings(MIDDLE_DOT, frameGlyph(0, set)); // ·
    try testing.expectEqualStrings(HEAVY_TEARDROP, frameGlyph(5, set)); // ✽ last forward
    try testing.expectEqualStrings(HEAVY_TEARDROP, frameGlyph(6, set)); // ✽ turn-around
    try testing.expectEqualStrings(MIDDLE_DOT, frameGlyph(11, set)); // · back to start
    // Wraps modulo FRAME_COUNT.
    try testing.expectEqualStrings(MIDDLE_DOT, frameGlyph(12, set));
    try testing.expectEqualStrings(frameGlyph(1, set), frameGlyph(13, set));
}

test "frameGlyph reverse half mirrors forward half" {
    const set = defaultCharacters("xterm-256color", true);
    // idx 7 mirrors idx 4, idx 8 mirrors idx 3, etc.
    try testing.expectEqualStrings(frameGlyph(4, set), frameGlyph(7, set));
    try testing.expectEqualStrings(frameGlyph(3, set), frameGlyph(8, set));
    try testing.expectEqualStrings(frameGlyph(2, set), frameGlyph(9, set));
    try testing.expectEqualStrings(frameGlyph(1, set), frameGlyph(10, set));
}

test "interpolateRgb endpoints and midpoint" {
    const a: Rgb = .{ .r = 0, .g = 100, .b = 200 };
    const b: Rgb = .{ .r = 100, .g = 200, .b = 0 };
    try testing.expect(interpolateRgb(a, b, 0).eql(a));
    try testing.expect(interpolateRgb(a, b, 100).eql(b));
    // Clamps above 100.
    try testing.expect(interpolateRgb(a, b, 150).eql(b));
    const mid = interpolateRgb(a, b, 50);
    // round(0 + 100*0.5)=50, round(100+100*0.5)=150, round(200-200*0.5)=100
    try testing.expectEqual(@as(u8, 50), mid.r);
    try testing.expectEqual(@as(u8, 150), mid.g);
    try testing.expectEqual(@as(u8, 100), mid.b);
}

test "interpolateRgb rounds to nearest" {
    const a: Rgb = .{ .r = 0, .g = 0, .b = 0 };
    const b: Rgb = .{ .r = 10, .g = 10, .b = 10 };
    // 10 * 0.33 = 3.3 -> rounds to 3
    try testing.expectEqual(@as(u8, 3), interpolateRgb(a, b, 33).r);
    // 10 * 0.35 = 3.5 -> rounds to 4
    try testing.expectEqual(@as(u8, 4), interpolateRgb(a, b, 35).r);
    // Downward interpolation rounds correctly too.
    const down = interpolateRgb(b, a, 35); // 10 - 10*0.35 = 6.5 -> 7 ... but round(-3.5)=-4 from 10 -> 6
    try testing.expectEqual(@as(u8, 6), down.r);
}

test "reducedMotionDim toggles each second" {
    try testing.expect(!reducedMotionDim(0)); // lit
    try testing.expect(!reducedMotionDim(999)); // still lit
    try testing.expect(reducedMotionDim(1000)); // dim
    try testing.expect(reducedMotionDim(1999)); // still dim
    try testing.expect(!reducedMotionDim(2000)); // lit again (cycle restart)
    try testing.expect(reducedMotionDim(3000)); // dim
}

test "stalledIntensityPercent ramps over the stall window" {
    // Not stalled below the start.
    try testing.expectEqual(@as(usize, 0), stalledIntensityPercent(4000, 5000, 15000));
    try testing.expectEqual(@as(usize, 0), stalledIntensityPercent(5000, 5000, 15000));
    // Full at or above the end.
    try testing.expectEqual(@as(usize, 100), stalledIntensityPercent(15000, 5000, 15000));
    try testing.expectEqual(@as(usize, 100), stalledIntensityPercent(99000, 5000, 15000));
    // Midpoint of a 10s ramp.
    try testing.expectEqual(@as(usize, 50), stalledIntensityPercent(10000, 5000, 15000));
}

test "stalled glyph color drifts toward error red" {
    // A blue-ish accent should, when stalled, produce a color closer to
    // ERROR_RED than the base accent is.
    const accent: Rgb = .{ .r = 87, .g = 105, .b = 247 };
    const stalled = interpolateRgb(accent, ERROR_RED, 80);
    // Distance to ERROR_RED (squared, integer) for accent vs stalled.
    const dist = struct {
        fn sq(x: Rgb, y: Rgb) i64 {
            const dr: i64 = @as(i64, x.r) - @as(i64, y.r);
            const dg: i64 = @as(i64, x.g) - @as(i64, y.g);
            const db: i64 = @as(i64, x.b) - @as(i64, y.b);
            return dr * dr + dg * dg + db * db;
        }
    };
    try testing.expect(dist.sq(stalled, ERROR_RED) < dist.sq(accent, ERROR_RED));
}

test "writeTrueColorSgr formats a 38;2 foreground escape" {
    var buf: [24]u8 = undefined;
    const got = writeTrueColorSgr(&buf, ERROR_RED);
    try testing.expectEqualStrings("\x1b[38;2;171;43;63m", got);
}
