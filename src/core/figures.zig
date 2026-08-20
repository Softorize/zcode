const std = @import("std");

/// Centralized Unicode glyph catalogue, ported in spirit from
/// claude-code-main/src/constants/figures.ts. The reference tracks
/// ~30 glyphs used across its Ink UI (diamond for status, box
/// drawings for borders, effort level indicators, etc). zcode has
/// the same glyphs scattered throughout src/cli as raw `\xe2\x80\xa2`
/// byte sequences, which makes it hard to spot inconsistencies or
/// swap a glyph set.
///
/// This module collects the most commonly-used ones in one place so
/// callers can write `figures.BLACK_DIAMOND` instead of a raw escape.
/// Each constant is UTF-8 bytes ready to print; the comment shows
/// the actual glyph plus the U+XXXX code point for grep-ability.
///
/// Wire-up of the scattered call sites in repl.zig is a follow-up --
/// shipping the constants first means the follow-up passes can be
/// small, incremental find-and-replace diffs rather than a big
/// coupled refactor.

// ── Status indicators ──────────────────────────────────────────────

/// ◆ U+25C6 BLACK DIAMOND -- used for the mint-green brand mark
/// next to the zcode version in the welcome banner, and as the
/// transcript divider before each assistant block.
pub const BLACK_DIAMOND: []const u8 = "\xe2\x97\x86";

/// ◇ U+25C7 WHITE DIAMOND -- the "pending" twin of BLACK_DIAMOND.
/// Claude Code uses this in the ultrareview status widget for
/// running tasks; zcode doesn't wire it yet but the glyph is
/// catalogued for future use.
pub const WHITE_DIAMOND: []const u8 = "\xe2\x97\x87";

/// ● U+25CF BLACK CIRCLE -- "on" / "filled" indicator.
pub const BLACK_CIRCLE: []const u8 = "\xe2\x97\x8f";

/// ○ U+25CB WHITE CIRCLE -- "off" / "empty" indicator.
pub const WHITE_CIRCLE: []const u8 = "\xe2\x97\x8b";

/// ◐ U+25D0 CIRCLE WITH LEFT HALF BLACK -- medium-state indicator,
/// also used as the "medium" effort glyph in Claude Code's /effort.
pub const HALF_CIRCLE: []const u8 = "\xe2\x97\x90";

/// ◉ U+25C9 FISHEYE -- "max" effort indicator.
pub const FISHEYE: []const u8 = "\xe2\x97\x89";

// ── Inline marks ───────────────────────────────────────────────────

/// • U+2022 BULLET -- list marker used in welcome tips and
/// markdown bullet rendering.
pub const BULLET: []const u8 = "\xe2\x80\xa2";

/// … U+2026 HORIZONTAL ELLIPSIS -- truncation marker used by
/// format.truncatePathMiddle and format.truncatePathStart.
pub const ELLIPSIS: []const u8 = "\xe2\x80\xa6";

/// ✶ U+2736 SIX POINTED BLACK STAR -- "Insight" marker that
/// wraps educational asides in the Explanatory output style
/// (pass 66 ported this to the builtin prompt).
pub const STAR: []const u8 = "\xe2\x9c\xb6";

// ── Arrows ─────────────────────────────────────────────────────────

/// → U+2192 RIGHTWARDS ARROW -- separator between line number
/// and line content in cat-n style Read output (pass 83).
pub const ARROW_RIGHT: []const u8 = "\xe2\x86\x92";

/// ↪ U+21AA LEFTWARDS ARROW WITH HOOK -- "hint" prefix used by
/// the first-run /init nudge in the welcome banner (pass 89).
pub const ARROW_HOOK: []const u8 = "\xe2\x86\xaa";

/// ↑ U+2191 UPWARDS ARROW -- scroll hint and history up marker.
pub const ARROW_UP: []const u8 = "\xe2\x86\x91";

/// ↓ U+2193 DOWNWARDS ARROW -- scroll hint and history down marker.
pub const ARROW_DOWN: []const u8 = "\xe2\x86\x93";

/// ↕ U+2195 UP DOWN ARROW -- combined vertical scroll indicator.
pub const ARROW_UP_DOWN: []const u8 = "\xe2\x86\x95";

// ── Box drawing (used in tool result cards) ────────────────────────

/// ─ U+2500 BOX DRAWINGS LIGHT HORIZONTAL
pub const BOX_H: []const u8 = "\xe2\x94\x80";

/// │ U+2502 BOX DRAWINGS LIGHT VERTICAL
pub const BOX_V: []const u8 = "\xe2\x94\x82";

/// ┌ U+250C BOX DRAWINGS LIGHT DOWN AND RIGHT
pub const BOX_TL: []const u8 = "\xe2\x94\x8c";

/// ┐ U+2510 BOX DRAWINGS LIGHT DOWN AND LEFT
pub const BOX_TR: []const u8 = "\xe2\x94\x90";

/// └ U+2514 BOX DRAWINGS LIGHT UP AND RIGHT
pub const BOX_BL: []const u8 = "\xe2\x94\x94";

/// ┘ U+2518 BOX DRAWINGS LIGHT UP AND LEFT
pub const BOX_BR: []const u8 = "\xe2\x94\x98";

/// ├ U+251C BOX DRAWINGS LIGHT VERTICAL AND RIGHT
pub const BOX_LEFT_T: []const u8 = "\xe2\x94\x9c";

/// ┤ U+2524 BOX DRAWINGS LIGHT VERTICAL AND LEFT
pub const BOX_RIGHT_T: []const u8 = "\xe2\x94\xa4";

// ── Decorative ─────────────────────────────────────────────────────

/// ⚠ U+26A0 WARNING SIGN -- tone marker for warning-class output.
pub const WARNING: []const u8 = "\xe2\x9a\xa0";

/// ⏺ U+23FA BLACK CIRCLE FOR RECORD -- macOS prefers this glyph
/// for "recording" over BLACK_CIRCLE because it vertically
/// centers better in the typical terminal font.
pub const RECORD: []const u8 = "\xe2\x8f\xba";

/// ⚑ U+2691 BLACK FLAG -- issue flag banner. Claude Code uses
/// this in the ultrareview status widget to mark a task that a
/// reviewer flagged for attention.
pub const FLAG: []const u8 = "\xe2\x9a\x91";

/// ※ U+203B REFERENCE MARK (komejirushi) -- "away summary recap"
/// marker the reference uses when it replays notes on return
/// from a context-collapse snapshot. Paired with BLACK_DIAMOND
/// in the transcript divider family.
pub const REFERENCE_MARK: []const u8 = "\xe2\x80\xbb";

// ── Indicators and glyphs for future UI features ───────────────────

/// ∙ U+2219 BULLET OPERATOR -- the narrow-bullet separator used
/// in the reference's status line between badge groups (e.g.
/// "model ∙ provider ∙ branch"). Finer than the regular BULLET
/// so it reads as a separator instead of a list marker.
pub const BULLET_OPERATOR: []const u8 = "\xe2\x88\x99";

/// ✻ U+273B HEAVY TEARDROP-SPOKED ASTERISK -- the "still working"
/// glimmer drawn next to the spinner message while a long-running
/// turn is in flight. Distinct from STAR (U+2736) which marks
/// educational asides in the Explanatory output style.
pub const TEARDROP_ASTERISK: []const u8 = "\xe2\x9c\xbb";

/// ∴ U+2234 THEREFORE -- the collapsed extended-thinking marker the
/// reference paints next to a persisted reasoning block (`∴ Thinking`
/// in AssistantThinkingMessage.tsx). Distinct from TEARDROP_ASTERISK
/// (the live "still working" glimmer): THEREFORE marks reasoning that
/// has already completed and is sitting in the transcript.
pub const THEREFORE: []const u8 = "\xe2\x88\xb4";

/// ↯ U+21AF DOWNWARDS ZIGZAG ARROW -- "fast mode" indicator in
/// the reference. We flip into fast mode via `/fast`; this glyph
/// is the visual shorthand the reference paints next to the
/// model name while it's active.
pub const LIGHTNING_BOLT: []const u8 = "\xe2\x86\xaf";

/// ▶ U+25B6 BLACK RIGHT-POINTING TRIANGLE -- play / resume
/// indicator, used by the reference in the thinkback-play and
/// the cron-trigger "running" rows.
pub const PLAY_ICON: []const u8 = "\xe2\x96\xb6";

/// ⏸ U+23F8 DOUBLE VERTICAL BAR -- pause indicator, the
/// counterpart to PLAY_ICON in the same widgets.
pub const PAUSE_ICON: []const u8 = "\xe2\x8f\xb8";

/// ↻ U+21BB CLOCKWISE OPEN CIRCLE ARROW -- "refresh" /
/// "resource update" marker the reference uses for MCP
/// subscription events in the transcript.
pub const REFRESH_ARROW: []const u8 = "\xe2\x86\xbb";

/// ← U+2190 LEFTWARDS ARROW -- inbound channel message
/// indicator. Not redundant with ARROW_UP / ARROW_DOWN; this is
/// a horizontal marker for "a message arrived from elsewhere".
pub const ARROW_LEFT: []const u8 = "\xe2\x86\x90";

/// ⑂ U+2442 OCR BRANCH BANK IDENTIFICATION -- Unicode has no
/// proper "fork" glyph, so the reference borrows this OCR
/// symbol which reads as a two-pronged fork in most terminal
/// fonts. Used to mark fork directives in the transcript.
pub const FORK_GLYPH: []const u8 = "\xe2\x91\x82";

/// ▎ U+258E LEFT ONE-QUARTER BLOCK -- blockquote line prefix,
/// matching the `▎ quoted text` styling the reference uses in
/// markdown rendering.
pub const BLOCKQUOTE_BAR: []const u8 = "\xe2\x96\x8e";

/// ━ U+2501 BOX DRAWINGS HEAVY HORIZONTAL -- heavy divider bar
/// for section separators that need more visual weight than the
/// default BOX_H (light horizontal).
pub const HEAVY_HORIZONTAL: []const u8 = "\xe2\x94\x81";

const testing = std.testing;

test "every glyph constant is valid UTF-8" {
    const all = [_][]const u8{
        BLACK_DIAMOND,    WHITE_DIAMOND,   BLACK_CIRCLE,      WHITE_CIRCLE,   HALF_CIRCLE,
        FISHEYE,          BULLET,          ELLIPSIS,          STAR,           ARROW_RIGHT,
        ARROW_HOOK,       ARROW_UP,        ARROW_DOWN,        ARROW_UP_DOWN,  BOX_H,
        BOX_V,            BOX_TL,          BOX_TR,            BOX_BL,         BOX_BR,
        BOX_LEFT_T,       BOX_RIGHT_T,     WARNING,           RECORD,         FLAG,
        REFERENCE_MARK,   BULLET_OPERATOR, TEARDROP_ASTERISK, LIGHTNING_BOLT, PLAY_ICON,
        PAUSE_ICON,       REFRESH_ARROW,   ARROW_LEFT,        FORK_GLYPH,     BLOCKQUOTE_BAR,
        HEAVY_HORIZONTAL, THEREFORE,
    };
    for (all) |glyph| {
        try testing.expect(glyph.len > 0);
        try testing.expect(std.unicode.utf8ValidateSlice(glyph));
    }
}

test "common glyphs have the expected byte length" {
    // All of these encode to 3 UTF-8 bytes.
    const three_byte = [_][]const u8{
        BLACK_DIAMOND,  BLACK_CIRCLE,   WHITE_CIRCLE,     HALF_CIRCLE,
        FISHEYE,        BULLET,         ELLIPSIS,         STAR,
        ARROW_RIGHT,    ARROW_HOOK,     ARROW_UP,         ARROW_DOWN,
        BOX_H,          BOX_V,          BOX_TL,           BOX_TR,
        BOX_BL,         BOX_BR,         BOX_LEFT_T,       BOX_RIGHT_T,
        // Newly added in this pass:
        FLAG,           REFERENCE_MARK, BULLET_OPERATOR,  TEARDROP_ASTERISK,
        LIGHTNING_BOLT, PLAY_ICON,      REFRESH_ARROW,    ARROW_LEFT,
        FORK_GLYPH,     BLOCKQUOTE_BAR, HEAVY_HORIZONTAL, THEREFORE,
    };
    for (three_byte) |glyph| try testing.expectEqual(@as(usize, 3), glyph.len);
}

test "PAUSE_ICON is a 3-byte code point" {
    // U+23F8 encodes as E2 8F B8 -- 3 bytes.
    try testing.expectEqual(@as(usize, 3), PAUSE_ICON.len);
    try testing.expectEqualStrings("\xe2\x8f\xb8", PAUSE_ICON);
}

test "new glyphs match their reference byte sequences exactly" {
    // Regression guards so a typo-edit on any one of these
    // produces a diff that fails at test time instead of
    // silently rendering the wrong glyph in the status line.
    try testing.expectEqualStrings("\xe2\x9a\x91", FLAG); // U+2691
    try testing.expectEqualStrings("\xe2\x80\xbb", REFERENCE_MARK); // U+203B
    try testing.expectEqualStrings("\xe2\x88\x99", BULLET_OPERATOR); // U+2219
    try testing.expectEqualStrings("\xe2\x9c\xbb", TEARDROP_ASTERISK); // U+273B
    try testing.expectEqualStrings("\xe2\x86\xaf", LIGHTNING_BOLT); // U+21AF
    try testing.expectEqualStrings("\xe2\x96\xb6", PLAY_ICON); // U+25B6
    try testing.expectEqualStrings("\xe2\x8f\xb8", PAUSE_ICON); // U+23F8
    try testing.expectEqualStrings("\xe2\x86\xbb", REFRESH_ARROW); // U+21BB
    try testing.expectEqualStrings("\xe2\x86\x90", ARROW_LEFT); // U+2190
    try testing.expectEqualStrings("\xe2\x91\x82", FORK_GLYPH); // U+2442
    try testing.expectEqualStrings("\xe2\x96\x8e", BLOCKQUOTE_BAR); // U+258E
    try testing.expectEqualStrings("\xe2\x94\x81", HEAVY_HORIZONTAL); // U+2501
    try testing.expectEqualStrings("\xe2\x88\xb4", THEREFORE); // U+2234
}

test "BULLET_OPERATOR is distinct from BULLET" {
    // BULLET (U+2022) and BULLET_OPERATOR (U+2219) are both valid
    // terminal list markers but convey different things: BULLET is
    // a list item, BULLET_OPERATOR is a horizontal separator.
    // The reference uses them in different contexts and so do we;
    // assert they don't accidentally drift into each other after
    // a find-and-replace refactor.
    try testing.expect(!std.mem.eql(u8, BULLET, BULLET_OPERATOR));
}

test "PLAY_ICON and PAUSE_ICON form a toggle pair" {
    // Sanity check that the two have the same byte length so a
    // status-line widget can swap between them without layout
    // shift. Both are 3-byte code points in the U+23xx/U+25xx
    // range.
    try testing.expectEqual(PLAY_ICON.len, PAUSE_ICON.len);
}

test "BLACK_DIAMOND matches the bytes used in repl.zig" {
    // Regression guard: repl.zig hard-codes "\xe2\x97\x86" in the
    // welcome banner. If a future refactor migrates the banner to
    // use figures.BLACK_DIAMOND and somebody edits this constant
    // to the wrong code point, the banner will break. Assert the
    // exact bytes so the mistake gets caught at test time.
    try testing.expectEqualStrings("\xe2\x97\x86", BLACK_DIAMOND);
}

test "ARROW_RIGHT matches the line-number separator from pass 83" {
    try testing.expectEqualStrings("\xe2\x86\x92", ARROW_RIGHT);
}

test "ELLIPSIS matches the truncation marker from pass 74" {
    try testing.expectEqualStrings("\xe2\x80\xa6", ELLIPSIS);
}

test "BULLET matches the welcome-tip marker" {
    try testing.expectEqualStrings("\xe2\x80\xa2", BULLET);
}
