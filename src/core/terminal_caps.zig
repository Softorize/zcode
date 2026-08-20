//! Terminal capability probe for `/terminal-setup`.
//!
//! Inspects env vars and TTY state to report on:
//!   - truecolor support (COLORTERM)
//!   - 256-color support (TERM)
//!   - unicode (LANG / LC_ALL)
//!   - hyperlinks (OSC 8 -- inferred from TERM_PROGRAM)
//!   - bell / bracketed paste
//!
//! The reference's `/terminalSetup` runs an interactive wizard that
//! writes iTerm/Terminal.app profiles. zcode's cut is a read-only
//! report: it tells the user what the current terminal supports and
//! how to fix common gaps.

const std = @import("std");
const std_io = @import("std_io.zig");
const xdg = @import("xdg.zig");
const env_mod = @import("env.zig");

const env = xdg.getEnvOptional;

// ── XTVERSION-detected terminal name (populated async at startup) ──
//
// TERM_PROGRAM is not forwarded over SSH by default, so env-based
// detection fails when zcode runs remotely inside a VS Code integrated
// terminal. The XTVERSION probe (CSI > 0 q -> DCS > | name ST) goes
// through the pty: the query reaches the *client* terminal and the reply
// comes back through stdin. `repl_input.TerminalRawMode.enable` fires the
// query; `setXtversionName` is called from the input parser when the reply
// arrives. Readers should treat null as "not yet known" and fall back to
// env-var detection.
//
// The name bytes are copied into a fixed static buffer because the input
// read buffer that produced them is reused on the next read.
var xtversion_name: ?[]const u8 = null;
var xtversion_buf: [128]u8 = undefined;

/// Record the XTVERSION response. Copies the name into a stable static
/// buffer. No-op if already set (defends against a re-probe), matching the
/// reference's `setXtversionName`.
pub fn setXtversionName(name: []const u8) void {
    if (xtversion_name != null) return;
    const n = @min(name.len, xtversion_buf.len);
    @memcpy(xtversion_buf[0..n], name[0..n]);
    xtversion_name = xtversion_buf[0..n];
}

/// Test-only: clear the recorded XTVERSION name so cases do not leak across
/// tests (the production set is one-shot and never cleared).
pub fn resetXtversionNameForTest() void {
    xtversion_name = null;
}

/// True if running in an xterm.js-based terminal (VS Code / Cursor / Windsurf
/// integrated terminals). Combines the fast TERM_PROGRAM env check (not
/// forwarded over SSH) with the async XTVERSION probe result (survives SSH).
/// Mirrors the reference `isXtermJs`.
pub fn isXtermJs() bool {
    if (env_mod.getenv("TERM_PROGRAM")) |tp| {
        if (std.mem.eql(u8, tp, "vscode")) return true;
    }
    if (xtversion_name) |name| {
        return std.mem.startsWith(u8, name, "xterm.js");
    }
    return false;
}

// Terminals known to correctly implement the Kitty keyboard protocol
// (CSI >1u) and/or xterm modifyOtherKeys for ctrl+shift+<letter>
// disambiguation. Mirrors the reference `EXTENDED_KEYS_TERMINALS`.
const EXTENDED_KEYS_TERMINALS = [_][]const u8{
    "iTerm.app",
    "kitty",
    "WezTerm",
    "ghostty",
    "tmux",
    "windows-terminal",
};

/// Pure predicate over a resolved terminal name. Extracted so it is unit
/// testable without env manipulation.
pub fn supportsExtendedKeysFor(name: []const u8) bool {
    for (EXTENDED_KEYS_TERMINALS) |t| {
        if (std.mem.eql(u8, name, t)) return true;
    }
    return false;
}

/// True if this terminal correctly handles extended key reporting (Kitty
/// keyboard protocol + xterm modifyOtherKeys). Resolves the terminal name
/// from env, mirroring the reference's `env.terminal` allowlist check.
pub fn supportsExtendedKeys() bool {
    return supportsExtendedKeysFor(detectTerminalName());
}

/// Resolve a short terminal name from env, covering the cases that map onto
/// the EXTENDED_KEYS_TERMINALS allowlist. This is the focused subset of the
/// reference's `detectTerminal` (the full version has many fallbacks that do
/// not affect the allowlist outcome).
fn detectTerminalName() []const u8 {
    // TERM-based detection runs first so it wins over an inconsistent
    // TERM_PROGRAM, matching the reference ordering.
    if (env_mod.getenv("TERM")) |term| {
        if (std.mem.eql(u8, term, "xterm-ghostty")) return "ghostty";
        if (std.mem.indexOf(u8, term, "kitty") != null) return "kitty";
    }
    if (env_mod.getenv("TERM_PROGRAM")) |tp| {
        if (tp.len != 0) return tp;
    }
    if (env_mod.getenv("TMUX")) |_| return "tmux";
    if (env_mod.getenv("KITTY_WINDOW_ID")) |_| return "kitty";
    if (env_mod.getenv("WT_SESSION")) |_| return "windows-terminal";
    return "";
}

// ── DEC 2026 synchronized output (BSU/ESU) ────────────────────────
//
// When the outer terminal implements DEC private mode 2026, wrapping a
// full-screen redraw in BSU (Begin Synchronized Update, `CSI ?2026h`) and
// ESU (End Synchronized Update, `CSI ?2026l`) makes the whole frame land
// atomically and eliminates visible flicker. Terminals that do not support
// it ignore the sequences harmlessly, but emitting them costs ~16 bytes per
// frame plus parser work, so we only emit when the terminal is known to
// support it. Mirrors the reference `isSynchronizedOutputSupported`
// (terminal.ts:70-118).

/// BSU - Begin Synchronized Update.
pub const BSU = "\x1b[?2026h";
/// ESU - End Synchronized Update.
pub const ESU = "\x1b[?2026l";

var sync_output_supported: ?bool = null;

/// True if the terminal is known to support DEC mode 2026 (synchronized
/// output). Env-only detection mirroring the reference whitelist. Excludes
/// tmux: tmux parses and proxies every byte but does not implement DEC 2026,
/// and it has already broken atomicity by chunking, so BSU/ESU are pointless
/// there. Cached after the first call.
pub fn isSynchronizedOutputSupported() bool {
    if (sync_output_supported) |cached| return cached;
    const result = computeSynchronizedOutputSupported();
    sync_output_supported = result;
    return result;
}

/// Test-only: clear the cached sync-output decision so cases that mutate env
/// vars do not leak the first answer across tests.
pub fn resetSynchronizedOutputCacheForTest() void {
    sync_output_supported = null;
}

fn computeSynchronizedOutputSupported() bool {
    // tmux: skip even when the inner TERM_PROGRAM looks capable.
    if (env_mod.getenv("TMUX")) |_| return false;

    if (env_mod.getenv("TERM_PROGRAM")) |tp| {
        if (std.mem.eql(u8, tp, "iTerm.app") or
            std.mem.eql(u8, tp, "WezTerm") or
            std.mem.eql(u8, tp, "WarpTerminal") or
            std.mem.eql(u8, tp, "ghostty") or
            std.mem.eql(u8, tp, "contour") or
            std.mem.eql(u8, tp, "vscode") or
            std.mem.eql(u8, tp, "alacritty")) return true;
    }

    if (env_mod.getenv("TERM")) |term| {
        // kitty: TERM=xterm-kitty or KITTY_WINDOW_ID.
        if (std.mem.indexOf(u8, term, "kitty") != null) return true;
        // Ghostty may set TERM=xterm-ghostty without TERM_PROGRAM.
        if (std.mem.eql(u8, term, "xterm-ghostty")) return true;
        // foot sets TERM=foot or TERM=foot-extra.
        if (std.mem.startsWith(u8, term, "foot")) return true;
        // Alacritty may set TERM containing 'alacritty'.
        if (std.mem.indexOf(u8, term, "alacritty") != null) return true;
    }

    if (env_mod.getenv("KITTY_WINDOW_ID")) |_| return true;
    // Zed uses the alacritty_terminal crate which supports DEC 2026.
    if (env_mod.getenv("ZED_TERM")) |_| return true;
    // Windows Terminal.
    if (env_mod.getenv("WT_SESSION")) |_| return true;

    // VTE-based terminals (GNOME Terminal, Tilix, etc.) since VTE 0.68 (6800).
    if (env_mod.getenv("VTE_VERSION")) |vte| {
        const version = std.fmt.parseInt(u32, vte, 10) catch return false;
        if (version >= 6800) return true;
    }

    return false;
}

// ── OSC 9;4 progress-reporting capability ─────────────────────────
//
// OSC 9;4 draws a progress bar on the OS taskbar / terminal tab. Only a
// few terminals implement it: ConEmu (all versions), Ghostty 1.2.0+ and
// iTerm2 3.6.6+. Windows Terminal interprets OSC 9;4 as a *notification*
// rather than a progress indicator, so it is explicitly excluded. Mirrors
// the reference `isProgressReportingAvailable` (terminal.ts:25-64).

/// True if stdout is a TTY and the terminal is known to render OSC 9;4
/// progress bars. The TTY gate keeps progress escapes out of piped output;
/// the env decision is factored into `progressReportingEnvCapable` so it can
/// be unit-tested without a TTY.
pub fn isProgressReportingAvailable() bool {
    if (std.c.isatty(std.Io.File.stdout().handle) == 0) return false;
    return progressReportingEnvCapable();
}

/// Env-only half of the progress-reporting decision (no TTY check). Pure
/// over env vars so tests can drive it directly.
pub fn progressReportingEnvCapable() bool {
    // Windows Terminal treats OSC 9;4 as a notification, not progress.
    if (env_mod.getenv("WT_SESSION")) |_| return false;

    // ConEmu supports OSC 9;4 across all versions.
    if (env_mod.getenv("ConEmuANSI") != null or
        env_mod.getenv("ConEmuPID") != null or
        env_mod.getenv("ConEmuTask") != null) return true;

    const version = env_mod.getenv("TERM_PROGRAM_VERSION") orelse return false;
    const tp = env_mod.getenv("TERM_PROGRAM") orelse return false;

    // Ghostty 1.2.0+ (release notes: ghostty.org/docs/install/release-notes/1-2-0).
    if (std.mem.eql(u8, tp, "ghostty")) return semverGte(version, 1, 2, 0);
    // iTerm2 3.6.6+.
    if (std.mem.eql(u8, tp, "iTerm.app")) return semverGte(version, 3, 6, 6);

    return false;
}

/// Compare a `major.minor.patch` version string against a minimum, returning
/// true when `version_str` is greater-than-or-equal. Leading non-digit bytes
/// are skipped (mirrors the reference `coerce`, which tolerates a prefix);
/// missing components default to 0; trailing pre-release/build suffixes are
/// ignored. There is no semver dependency in zcode, so this is a tiny pure
/// helper.
pub fn semverGte(version_str: []const u8, min_major: u32, min_minor: u32, min_patch: u32) bool {
    var rest = version_str;
    // Skip a leading non-digit prefix (e.g. a "v" or a vendor tag).
    while (rest.len > 0 and !std.ascii.isDigit(rest[0])) rest = rest[1..];

    var parts = [_]u32{ 0, 0, 0 };
    var idx: usize = 0;
    while (idx < 3 and rest.len > 0) : (idx += 1) {
        var n: usize = 0;
        while (n < rest.len and std.ascii.isDigit(rest[n])) n += 1;
        if (n == 0) break;
        parts[idx] = std.fmt.parseInt(u32, rest[0..n], 10) catch return false;
        rest = rest[n..];
        // Advance past a single separator ('.') if present; stop on anything
        // else (e.g. '-rc1' or '+build') so the suffix is ignored.
        if (rest.len > 0 and rest[0] == '.') {
            rest = rest[1..];
        } else {
            break;
        }
    }

    if (parts[0] != min_major) return parts[0] > min_major;
    if (parts[1] != min_minor) return parts[1] > min_minor;
    return parts[2] >= min_patch;
}

pub fn render(allocator: std.mem.Allocator) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    const term_opt = env(allocator, "TERM");
    defer if (term_opt) |t| allocator.free(t);
    const term = if (term_opt) |t| t else "(unset)";

    const colorterm_opt = env(allocator, "COLORTERM");
    defer if (colorterm_opt) |t| allocator.free(t);
    const colorterm = if (colorterm_opt) |t| t else "";

    const lang_opt = env(allocator, "LANG");
    defer if (lang_opt) |t| allocator.free(t);
    const lang = if (lang_opt) |t| t else "(unset)";

    const tp_opt = env(allocator, "TERM_PROGRAM");
    defer if (tp_opt) |t| allocator.free(t);
    const term_program = if (tp_opt) |t| t else "(none)";

    const is_truecolor = std.ascii.eqlIgnoreCase(colorterm, "truecolor") or
        std.ascii.eqlIgnoreCase(colorterm, "24bit");
    const is_256 = std.mem.indexOf(u8, term, "256color") != null;
    const is_utf8 = std.mem.indexOf(u8, lang, "UTF-8") != null or
        std.mem.indexOf(u8, lang, "utf-8") != null or
        std.mem.indexOf(u8, lang, "UTF8") != null;

    // OSC 8 hyperlink support is not advertised via a capability
    // string -- we match against the short allow-list of terminals
    // known to render it.
    const hyperlinks_ok = std.ascii.eqlIgnoreCase(term_program, "iTerm.app") or
        std.ascii.eqlIgnoreCase(term_program, "WezTerm") or
        std.ascii.eqlIgnoreCase(term_program, "ghostty") or
        std.ascii.eqlIgnoreCase(term_program, "vscode") or
        std.ascii.eqlIgnoreCase(term_program, "WarpTerminal");

    try w.print("TERM            = {s}\n", .{term});
    try w.print("COLORTERM       = {s}\n", .{colorterm});
    try w.print("LANG            = {s}\n", .{lang});
    try w.print("TERM_PROGRAM    = {s}\n", .{term_program});
    try w.writeAll("\n");

    try w.print("truecolor       : {s}\n", .{bool_str(is_truecolor)});
    try w.print("256 colors      : {s}\n", .{bool_str(is_256 or is_truecolor)});
    try w.print("UTF-8 locale    : {s}\n", .{bool_str(is_utf8)});
    try w.print("OSC-8 hyperlinks: {s}\n", .{bool_str(hyperlinks_ok)});

    try w.writeAll("\n");
    if (!is_truecolor) {
        try w.writeAll("hint: set `COLORTERM=truecolor` in your shell rc for 24-bit colors.\n");
    }
    if (!is_utf8) {
        try w.writeAll("hint: set `LANG=en_US.UTF-8` (or your locale + UTF-8) so zcode can render unicode.\n");
    }
    if (!is_256 and !is_truecolor) {
        try w.writeAll("hint: set `TERM=xterm-256color` (tmux users: `tmux-256color`).\n");
    }
    if (!hyperlinks_ok) {
        try w.writeAll("note: file:line links will render as plain text here. `/files` still copies paths.\n");
    }

    return out.toOwnedSlice();
}

fn bool_str(b: bool) []const u8 {
    return if (b) "yes" else "no";
}

// ── Tests ─────────────────────────────────────────────────────────

test "setXtversionName then isXtermJs is true for xterm.js name" {
    resetXtversionNameForTest();
    defer resetXtversionNameForTest();
    setXtversionName("xterm.js(5.5.0)");
    try std.testing.expect(isXtermJs());
}

test "setXtversionName is one-shot (re-probe is a no-op)" {
    resetXtversionNameForTest();
    defer resetXtversionNameForTest();
    setXtversionName("xterm.js(5.5.0)");
    setXtversionName("ghostty 1.2.0");
    try std.testing.expectEqualStrings("xterm.js(5.5.0)", xtversion_name.?);
}

test "non-xterm.js XTVERSION name does not flag isXtermJs (without vscode env)" {
    resetXtversionNameForTest();
    defer resetXtversionNameForTest();
    setXtversionName("ghostty 1.2.0");
    // If the harness leaks TERM_PROGRAM=vscode this would be true; the
    // dominant path under test is the name-prefix check, so only assert it
    // when vscode is not set.
    const tp = env_mod.getenv("TERM_PROGRAM");
    const is_vscode = tp != null and std.mem.eql(u8, tp.?, "vscode");
    if (!is_vscode) try std.testing.expect(!isXtermJs());
}

test "supportsExtendedKeysFor allowlist" {
    try std.testing.expect(supportsExtendedKeysFor("kitty"));
    try std.testing.expect(supportsExtendedKeysFor("ghostty"));
    try std.testing.expect(supportsExtendedKeysFor("iTerm.app"));
    try std.testing.expect(supportsExtendedKeysFor("WezTerm"));
    try std.testing.expect(supportsExtendedKeysFor("tmux"));
    try std.testing.expect(supportsExtendedKeysFor("windows-terminal"));
    try std.testing.expect(!supportsExtendedKeysFor("dumb"));
    try std.testing.expect(!supportsExtendedKeysFor(""));
}

// ── DEC 2026 sync-output tests ─────────────────────────────────────

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const SYNC_ENV_KEYS = [_][*:0]const u8{
    "TMUX", "TERM_PROGRAM", "TERM", "KITTY_WINDOW_ID", "ZED_TERM", "WT_SESSION", "VTE_VERSION",
};

/// Clear every env var that feeds the sync-output decision so a case starts
/// from a known-clean baseline regardless of the harness environment.
fn clearSyncEnv() void {
    for (SYNC_ENV_KEYS) |k| _ = unsetenv(k);
    resetSynchronizedOutputCacheForTest();
}

test "isSynchronizedOutputSupported: TMUX wins even with capable TERM_PROGRAM" {
    clearSyncEnv();
    defer clearSyncEnv();
    _ = setenv("TMUX", "/tmp/tmux-1000/default,1,0", 1);
    _ = setenv("TERM_PROGRAM", "iTerm.app", 1);
    resetSynchronizedOutputCacheForTest();
    try std.testing.expect(!isSynchronizedOutputSupported());
}

test "isSynchronizedOutputSupported: ghostty without TMUX is true" {
    clearSyncEnv();
    defer clearSyncEnv();
    _ = setenv("TERM_PROGRAM", "ghostty", 1);
    resetSynchronizedOutputCacheForTest();
    try std.testing.expect(isSynchronizedOutputSupported());
}

test "isSynchronizedOutputSupported: VTE_VERSION threshold 6800 vs 6799" {
    clearSyncEnv();
    defer clearSyncEnv();

    _ = setenv("VTE_VERSION", "6800", 1);
    resetSynchronizedOutputCacheForTest();
    try std.testing.expect(isSynchronizedOutputSupported());

    _ = unsetenv("VTE_VERSION");
    _ = setenv("VTE_VERSION", "6799", 1);
    resetSynchronizedOutputCacheForTest();
    try std.testing.expect(!isSynchronizedOutputSupported());
}

test "isSynchronizedOutputSupported: kitty / xterm-ghostty / foot via TERM" {
    clearSyncEnv();
    defer clearSyncEnv();

    _ = setenv("TERM", "xterm-kitty", 1);
    resetSynchronizedOutputCacheForTest();
    try std.testing.expect(isSynchronizedOutputSupported());

    _ = setenv("TERM", "xterm-ghostty", 1);
    resetSynchronizedOutputCacheForTest();
    try std.testing.expect(isSynchronizedOutputSupported());

    _ = setenv("TERM", "foot-extra", 1);
    resetSynchronizedOutputCacheForTest();
    try std.testing.expect(isSynchronizedOutputSupported());

    _ = setenv("TERM", "xterm-256color", 1);
    resetSynchronizedOutputCacheForTest();
    try std.testing.expect(!isSynchronizedOutputSupported());
}

// ── OSC 9;4 progress-reporting tests ───────────────────────────────

const PROGRESS_ENV_KEYS = [_][*:0]const u8{
    "WT_SESSION", "ConEmuANSI", "ConEmuPID", "ConEmuTask", "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
};

fn clearProgressEnv() void {
    for (PROGRESS_ENV_KEYS) |k| _ = unsetenv(k);
}

test "progressReportingEnvCapable: ghostty 1.2.0 yes, 1.1.9 no" {
    clearProgressEnv();
    defer clearProgressEnv();
    _ = setenv("TERM_PROGRAM", "ghostty", 1);

    _ = setenv("TERM_PROGRAM_VERSION", "1.2.0", 1);
    try std.testing.expect(progressReportingEnvCapable());

    _ = setenv("TERM_PROGRAM_VERSION", "1.1.9", 1);
    try std.testing.expect(!progressReportingEnvCapable());
}

test "progressReportingEnvCapable: iTerm.app 3.6.6 yes, 3.6.5 no" {
    clearProgressEnv();
    defer clearProgressEnv();
    _ = setenv("TERM_PROGRAM", "iTerm.app", 1);

    _ = setenv("TERM_PROGRAM_VERSION", "3.6.6", 1);
    try std.testing.expect(progressReportingEnvCapable());

    _ = setenv("TERM_PROGRAM_VERSION", "3.6.5", 1);
    try std.testing.expect(!progressReportingEnvCapable());
}

test "progressReportingEnvCapable: WT_SESSION excludes even capable terminals" {
    clearProgressEnv();
    defer clearProgressEnv();
    _ = setenv("WT_SESSION", "abc-123", 1);
    _ = setenv("TERM_PROGRAM", "ghostty", 1);
    _ = setenv("TERM_PROGRAM_VERSION", "1.5.0", 1);
    try std.testing.expect(!progressReportingEnvCapable());
}

test "progressReportingEnvCapable: ConEmuPID set is true (any version)" {
    clearProgressEnv();
    defer clearProgressEnv();
    _ = setenv("ConEmuPID", "4321", 1);
    try std.testing.expect(progressReportingEnvCapable());
}

test "progressReportingEnvCapable: unknown terminal is false" {
    clearProgressEnv();
    defer clearProgressEnv();
    _ = setenv("TERM_PROGRAM", "Apple_Terminal", 1);
    _ = setenv("TERM_PROGRAM_VERSION", "447", 1);
    try std.testing.expect(!progressReportingEnvCapable());
}

test "semverGte: major/minor/patch ordering" {
    try std.testing.expect(semverGte("1.2.0", 1, 2, 0));
    try std.testing.expect(semverGte("1.2.1", 1, 2, 0));
    try std.testing.expect(semverGte("2.0.0", 1, 2, 0));
    try std.testing.expect(!semverGte("1.1.9", 1, 2, 0));
    try std.testing.expect(!semverGte("0.9.9", 1, 2, 0));
    // Tolerates a missing patch component (defaults to 0).
    try std.testing.expect(semverGte("1.2", 1, 2, 0));
    // Ignores a pre-release / build suffix.
    try std.testing.expect(semverGte("3.6.6-beta", 3, 6, 6));
    try std.testing.expect(!semverGte("3.6.5+build", 3, 6, 6));
    // Skips a non-digit prefix.
    try std.testing.expect(semverGte("v1.2.0", 1, 2, 0));
}
