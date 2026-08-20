//! Persistent extended-thinking render helpers (ui-render-04).
//!
//! The reference (`AssistantThinkingMessage.tsx`) shows a turn's
//! extended-thinking in two states:
//!
//!   * Normal (non-transcript) view: a single dim-italic line
//!     `∴ Thinking <ctrl+o to expand>`. The text itself is hidden; the
//!     `ctrl+o` hint points at the transcript toggle (`app:toggleTranscript`).
//!   * Transcript / verbose view: the full thinking text rendered as an
//!     indented (paddingLeft={2}) dim Markdown block.
//!
//! These two functions are the pure, IO-free render units so the REPL
//! wiring (which decides which one to call based on `show_transcript`)
//! stays a thin call site and the rendering itself is unit-testable
//! without the full interactive loop.
//!
//! Color is gated by `use_color`: when false (NO_COLOR / non-tty) the
//! same text is emitted with no SGR escapes so piped/captured output
//! degrades cleanly.

const std = @import("std");
const figures = @import("figures.zig");

// Standard ANSI SGR sequences. Defined locally rather than importing
// the cli markdown module so this stays a leaf core module (core must
// not depend on cli). These match repl_markdown.ANSI_DIM / ANSI_ITALIC
// / ANSI_RESET byte-for-byte.
const ANSI_DIM = "\x1b[2m";
const ANSI_ITALIC = "\x1b[3m";
const ANSI_DIM_ITALIC = "\x1b[2;3m";
const ANSI_RESET = "\x1b[0m";

/// The collapsed-line label. The `ctrl+o` hint matches the transcript
/// toggle's default binding (`repl_input.zig` `.toggle_transcript`).
pub const COLLAPSED_LABEL = "Thinking";
pub const EXPAND_HINT = "(ctrl+o to expand)";
pub const REDACTED_LABEL = "Thinking (redacted)";

/// Render the collapsed normal-view line:
///   `∴ Thinking (ctrl+o to expand)`
/// dim + italic when color is on. Emits a trailing newline so the
/// caller can append it as its own transcript line.
pub fn renderThinkingCollapsed(writer: anytype, use_color: bool) !void {
    if (use_color) try writer.writeAll(ANSI_DIM_ITALIC);
    try writer.writeAll(figures.THEREFORE);
    try writer.print(" {s} {s}", .{ COLLAPSED_LABEL, EXPAND_HINT });
    if (use_color) try writer.writeAll(ANSI_RESET);
    try writer.writeAll("\n");
}

/// Render the collapsed redacted placeholder line:
///   `∴ Thinking (redacted)`
/// Used when a provider returns a redacted-thinking marker (no text).
pub fn renderThinkingRedacted(writer: anytype, use_color: bool) !void {
    if (use_color) try writer.writeAll(ANSI_DIM_ITALIC);
    try writer.writeAll(figures.THEREFORE);
    try writer.print(" {s}", .{REDACTED_LABEL});
    if (use_color) try writer.writeAll(ANSI_RESET);
    try writer.writeAll("\n");
}

/// Render the full transcript-view block: the thinking text dim and
/// indented two spaces per line, matching the reference's
/// `paddingLeft={2}` + `<Markdown dimColor>`. Empty / blank lines are
/// emitted as a bare newline (no trailing indent whitespace).
///
/// We keep the markdown rendering deliberately light here: the dim
/// wrapper + indent is the load-bearing presentation. The text is
/// emitted verbatim line-by-line (callers that want richer markdown can
/// pre-render); this avoids a core->cli dependency on the full markdown
/// renderer while still satisfying the "full thinking visible, dim,
/// indented" contract.
pub fn renderThinkingFull(writer: anytype, text: []const u8, use_color: bool) !void {
    if (use_color) try writer.writeAll(ANSI_DIM);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0) {
            try writer.writeAll("\n");
            continue;
        }
        try writer.writeAll("  ");
        try writer.writeAll(trimmed);
        try writer.writeAll("\n");
    }
    if (use_color) try writer.writeAll(ANSI_RESET);
}

// ─────────────────────────── tests ───────────────────────────

const testing = std.testing;

fn renderCollapsedToBuf(buf: []u8, use_color: bool) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    try renderThinkingCollapsed(&w, use_color);
    return w.buffered();
}

fn renderFullToBuf(buf: []u8, text: []const u8, use_color: bool) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    try renderThinkingFull(&w, text, use_color);
    return w.buffered();
}

test "renderThinkingCollapsed contains the marker, label and ctrl+o hint" {
    var buf: [256]u8 = undefined;
    const out = try renderCollapsedToBuf(&buf, true);
    // The ∴ glyph bytes.
    try testing.expect(std.mem.indexOf(u8, out, "\xe2\x88\xb4") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Thinking") != null);
    // case-insensitive ctrl+o presence (we emit lowercase).
    try testing.expect(std.mem.indexOf(u8, out, "ctrl+o") != null);
    // Dim + italic SGR present with color on.
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2;3m") != null);
}

test "renderThinkingCollapsed does NOT leak the thinking body" {
    // The collapsed line never shows the underlying reasoning text.
    var buf: [256]u8 = undefined;
    const out = try renderCollapsedToBuf(&buf, true);
    try testing.expect(std.mem.indexOf(u8, out, "step one") == null);
}

test "renderThinkingCollapsed with color off has text but no SGR" {
    var buf: [256]u8 = undefined;
    const out = try renderCollapsedToBuf(&buf, false);
    try testing.expect(std.mem.indexOf(u8, out, "Thinking") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[") == null);
}

test "renderThinkingFull shows the full text, indented and dim" {
    var buf: [256]u8 = undefined;
    const out = try renderFullToBuf(&buf, "step one\nstep two", true);
    try testing.expect(std.mem.indexOf(u8, out, "step one") != null);
    try testing.expect(std.mem.indexOf(u8, out, "step two") != null);
    // 2-space indent on each non-blank line.
    try testing.expect(std.mem.indexOf(u8, out, "  step one") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  step two") != null);
    // Dim wrapper present.
    try testing.expect(std.mem.startsWith(u8, out, "\x1b[2m"));
    try testing.expect(std.mem.endsWith(u8, out, "\x1b[0m"));
}

test "renderThinkingFull with color off has text but no SGR" {
    var buf: [256]u8 = undefined;
    const out = try renderFullToBuf(&buf, "step one\nstep two", false);
    try testing.expect(std.mem.indexOf(u8, out, "step one") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[") == null);
}

test "renderThinkingRedacted shows the redacted placeholder" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try renderThinkingRedacted(&w, true);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\xe2\x88\xb4") != null);
    try testing.expect(std.mem.indexOf(u8, out, "redacted") != null);
}
