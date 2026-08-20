//! Terminal color-level resolution with the tmux truecolor->256 clamp and the
//! xterm.js (VS Code) truecolor boost.
//!
//! Ports `claude-code-main/src/ink/colorize.ts` (`boostChalkLevelForXtermJs` +
//! `clampChalkLevelForTmux`). zcode's palettes are authored as static escape
//! strings rather than driven through a chalk singleton, so instead of mutating
//! a global "level" we resolve a `ColorLevel` once at startup and use it to pick
//! between a truecolor built-in palette and its `*-ansi` (16-color) counterpart.
//!
//! Why this matters (the load-bearing bug): under default tmux, truecolor SGR
//! (`\x1b[48;2;r;g;bm`) is parsed into tmux's cell buffer but only re-emitted to
//! the outer terminal if that terminal advertises Tc/RGB capability. Default tmux
//! does NOT, so the background sequence is dropped and the outer terminal renders
//! the cell with its default (often black) background. Downgrading to 256-color
//! (`\x1b[48;5;Nm`) passes through tmux cleanly.
//!
//! ORDER IS LOAD-BEARING: boost BEFORE clamp. If tmux runs inside a VS Code
//! terminal, the boost lifts the xterm.js 256-baseline to truecolor and then the
//! tmux clamp re-clamps it back to 256 -- which is exactly what we want, because
//! tmux's passthrough limitation wins. Doing it in the other order would leave a
//! tmux-in-vscode session at truecolor and reintroduce the broken-background bug.
//!
//! `color_level.resolve` is PURE: it takes an explicit `Env` snapshot so the full
//! truth table is testable without mutating process env. `resolveFromEnv` is the
//! thin wrapper that reads the real environment via `core/env.zig`.

const std = @import("std");
const env = @import("env.zig");
const ui_theme = @import("ui_theme.zig");

/// Resolved terminal color capability. Ordered from least to most capable so
/// `@intFromEnum` comparisons (`level > .ansi256`) work for the clamp.
pub const ColorLevel = enum(u3) {
    none = 0,
    ansi16 = 1,
    ansi256 = 2,
    truecolor = 3,
};

/// Snapshot of the color-relevant environment. All fields are the raw env
/// values (null when unset). Passing this in keeps `resolve` pure and the
/// truth table exhaustively testable.
pub const Env = struct {
    no_color: ?[]const u8 = null,
    force_color: ?[]const u8 = null,
    colorterm: ?[]const u8 = null,
    term: ?[]const u8 = null,
    term_program: ?[]const u8 = null,
    tmux: ?[]const u8 = null,
    claude_code_tmux_truecolor: ?[]const u8 = null,
};

fn isSet(value: ?[]const u8) bool {
    const v = value orelse return false;
    return v.len > 0;
}

fn containsCi(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

/// Compute the base color level from COLORTERM / TERM, before any boost/clamp.
/// Mirrors chalk's supports-color fall-through: truecolor when COLORTERM
/// advertises it, else 256 when TERM mentions 256color, else plain 16-color ANSI.
fn baseLevel(e: Env) ColorLevel {
    if (e.colorterm) |ct| {
        if (containsCi(ct, "truecolor") or containsCi(ct, "24bit")) return .truecolor;
    }
    if (e.term) |t| {
        if (containsCi(t, "256color")) return .ansi256;
    }
    return .ansi16;
}

/// Resolve the effective color level from an explicit env snapshot.
///
/// Steps (order matters -- see the module doc comment):
///   1. NO_COLOR set (any non-empty) OR FORCE_COLOR explicitly "0" -> none.
///   2. base = baseLevel(COLORTERM / TERM).
///   3. boost: TERM_PROGRAM == "vscode" and base == ansi256 -> truecolor.
///   4. clamp: $TMUX set, CLAUDE_CODE_TMUX_TRUECOLOR unset, level > ansi256 ->
///      ansi256.
pub fn resolve(e: Env) ColorLevel {
    // NO_COLOR (https://no-color.org): any non-empty value disables color.
    if (isSet(e.no_color)) return .none;
    // FORCE_COLOR=0 is an explicit "no colors" request, matching the reference
    // gate on chalk.level === 2 (which NO_COLOR / FORCE_COLOR=0 would have
    // already driven to 0). Only the literal "0" disables; other values are a
    // force-on hint we do not need to honor for the clamp logic.
    if (e.force_color) |fc| {
        const trimmed = std.mem.trim(u8, fc, " \t\r\n");
        if (std.mem.eql(u8, trimmed, "0")) return .none;
    }

    var level = baseLevel(e);

    // Boost: xterm.js (VS Code, Cursor, code-server) supports truecolor but
    // containers often omit COLORTERM=truecolor, so the base falls through to
    // ansi256. Lift it. MUST run before the tmux clamp.
    if (e.term_program) |tp| {
        if (std.mem.eql(u8, tp, "vscode") and level == .ansi256) {
            level = .truecolor;
        }
    }

    // Clamp: under tmux (without the CLAUDE_CODE_TMUX_TRUECOLOR escape hatch),
    // downgrade anything above 256-color to 256-color so truecolor SGR passes
    // through tmux's emitter.
    if (isSet(e.tmux) and !isSet(e.claude_code_tmux_truecolor)) {
        if (@intFromEnum(level) > @intFromEnum(ColorLevel.ansi256)) {
            level = .ansi256;
        }
    }

    return level;
}

/// Read the real process environment and resolve the color level. Thin wrapper
/// over `resolve` -- all the logic lives in the pure function.
pub fn resolveFromEnv() ColorLevel {
    return resolve(.{
        .no_color = env.getenv("NO_COLOR"),
        .force_color = env.getenv("FORCE_COLOR"),
        .colorterm = env.getenv("COLORTERM"),
        .term = env.getenv("TERM"),
        .term_program = env.getenv("TERM_PROGRAM"),
        .tmux = env.getenv("TMUX"),
        .claude_code_tmux_truecolor = env.getenv("CLAUDE_CODE_TMUX_TRUECOLOR"),
    });
}

/// Auto-select route: given a configured theme and a resolved color level,
/// return the theme that should actually render. When the level cannot show
/// truecolor (`ansi256` / `ansi16` / `none`), a truecolor built-in is mapped to
/// its hand-authored `*-ansi` (16-color) counterpart so it renders correctly
/// under tmux. When the level is `truecolor`, the theme is returned unchanged.
///
/// Note: the `*-ansi` palettes are 16-color, which is a strict subset of any
/// 256-color or 16-color terminal -- so they are safe for both `ansi256` and
/// `ansi16` without needing a runtime RGB->256 quantizer for the built-ins.
/// (A quantizer is only needed to also clamp custom truecolor themes, which is
/// deferred -- see Task 17.)
pub fn applyLevelToTheme(theme: ui_theme.ThemeName, level: ColorLevel) ui_theme.ThemeName {
    if (level == .truecolor) return theme;
    return switch (theme) {
        .dark, .dark_daltonized => .dark_ansi,
        .light, .light_daltonized => .light_ansi,
        // Already 16-color; nothing to downgrade.
        .dark_ansi => .dark_ansi,
        .light_ansi => .light_ansi,
    };
}

// -- Tests ----------------------------------------------------------------

const testing = std.testing;

test "NO_COLOR forces none regardless of COLORTERM" {
    try testing.expectEqual(ColorLevel.none, resolve(.{
        .no_color = "1",
        .colorterm = "truecolor",
    }));
}

test "FORCE_COLOR=0 forces none" {
    try testing.expectEqual(ColorLevel.none, resolve(.{
        .force_color = "0",
        .colorterm = "truecolor",
    }));
}

test "COLORTERM=truecolor with no tmux resolves truecolor" {
    try testing.expectEqual(ColorLevel.truecolor, resolve(.{
        .colorterm = "truecolor",
    }));
}

test "COLORTERM=24bit also resolves truecolor" {
    try testing.expectEqual(ColorLevel.truecolor, resolve(.{
        .colorterm = "24bit",
    }));
}

test "truecolor clamps to ansi256 under tmux" {
    try testing.expectEqual(ColorLevel.ansi256, resolve(.{
        .colorterm = "truecolor",
        .tmux = "/tmp/tmux-501/default,12345,0",
    }));
}

test "CLAUDE_CODE_TMUX_TRUECOLOR escapes the tmux clamp" {
    try testing.expectEqual(ColorLevel.truecolor, resolve(.{
        .colorterm = "truecolor",
        .tmux = "/tmp/tmux-501/default,12345,0",
        .claude_code_tmux_truecolor = "1",
    }));
}

test "vscode boosts ansi256 baseline to truecolor" {
    try testing.expectEqual(ColorLevel.truecolor, resolve(.{
        .term_program = "vscode",
        .term = "xterm-256color",
    }));
}

test "vscode + tmux: boost then clamp yields ansi256" {
    // Boost lifts the ansi256 baseline to truecolor, then the tmux clamp
    // re-clamps it back to ansi256 -- the order-sensitive case.
    try testing.expectEqual(ColorLevel.ansi256, resolve(.{
        .term_program = "vscode",
        .term = "xterm-256color",
        .tmux = "/tmp/tmux-501/default,12345,0",
    }));
}

test "TERM with 256color and no COLORTERM resolves ansi256" {
    try testing.expectEqual(ColorLevel.ansi256, resolve(.{
        .term = "xterm-256color",
    }));
}

test "bare TERM with neither truecolor nor 256color resolves ansi16" {
    try testing.expectEqual(ColorLevel.ansi16, resolve(.{
        .term = "xterm",
    }));
}

test "empty NO_COLOR does not disable color" {
    // An unset/empty NO_COLOR must NOT force none -- only a non-empty value does.
    try testing.expectEqual(ColorLevel.truecolor, resolve(.{
        .no_color = "",
        .colorterm = "truecolor",
    }));
}

test "applyLevelToTheme downgrades truecolor built-ins to ansi at ansi256" {
    try testing.expectEqual(ui_theme.ThemeName.dark_ansi, applyLevelToTheme(.dark, .ansi256));
    try testing.expectEqual(ui_theme.ThemeName.light_ansi, applyLevelToTheme(.light, .ansi256));
    try testing.expectEqual(ui_theme.ThemeName.dark_ansi, applyLevelToTheme(.dark_daltonized, .ansi256));
    try testing.expectEqual(ui_theme.ThemeName.light_ansi, applyLevelToTheme(.light_daltonized, .ansi256));
}

test "applyLevelToTheme leaves themes unchanged at truecolor" {
    try testing.expectEqual(ui_theme.ThemeName.dark, applyLevelToTheme(.dark, .truecolor));
    try testing.expectEqual(ui_theme.ThemeName.light_daltonized, applyLevelToTheme(.light_daltonized, .truecolor));
}

test "applyLevelToTheme keeps ansi themes ansi at any low level" {
    try testing.expectEqual(ui_theme.ThemeName.dark_ansi, applyLevelToTheme(.dark_ansi, .ansi16));
    try testing.expectEqual(ui_theme.ThemeName.light_ansi, applyLevelToTheme(.light_ansi, .none));
}

test "applyLevelToTheme downgrades at ansi16 too" {
    try testing.expectEqual(ui_theme.ThemeName.dark_ansi, applyLevelToTheme(.dark, .ansi16));
}

test "resolved palette under tmux carries no truecolor escapes" {
    // Integration assertion: under a simulated tmux env, the auto-selected
    // theme's palette must contain no 38;2 / 48;2 truecolor SGR.
    const level = resolve(.{
        .colorterm = "truecolor",
        .tmux = "/tmp/tmux-501/default,12345,0",
    });
    const resolved = applyLevelToTheme(.dark, level);
    // The brand accent is the canary -- it is truecolor in `dark`, 16-color in
    // `dark_ansi`.
    const accent = ui_theme.ansi(resolved, .brand_accent);
    try testing.expect(std.mem.indexOf(u8, accent, "38;2") == null);
    try testing.expect(std.mem.indexOf(u8, accent, "48;2") == null);
    const fill = ui_theme.ansi(resolved, .approval_accept_fill);
    try testing.expect(std.mem.indexOf(u8, fill, "38;2") == null);
    try testing.expect(std.mem.indexOf(u8, fill, "48;2") == null);
}
