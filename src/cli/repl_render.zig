const std = @import("std");
const std_io = @import("../core/std_io.zig");
const repl_spinner = @import("repl_spinner.zig");
const repl_markdown = @import("repl_markdown.zig");
const repl_input = @import("repl_input.zig");
const repl_attachments = @import("repl_attachments.zig");
const repl_help = @import("repl_help.zig");
const repl_footer = @import("repl_footer.zig");
const figures = @import("../core/figures.zig");
const ui_theme = @import("../core/ui_theme.zig");
const sandbox_mod = @import("../core/sandbox.zig");
const terminal_caps = @import("../core/terminal_caps.zig");

const UiTranscript = repl_spinner.UiTranscript;
const TRANSCRIPT_DIVIDER_PREFIX = "[[divider:";
const TRANSCRIPT_DIVIDER_SUFFIX = "]]";
const TRANSCRIPT_ASSISTANT_BLOCK_START = "[[assistant_block:start]]";
const TRANSCRIPT_ASSISTANT_BLOCK_END = "[[assistant_block:end]]";
const PROMPT_PLACEHOLDER = "Type a task or use / for commands";
const FOOTER_SEGMENT_SEPARATOR = " \xe2\x88\x99 ";
const BRIEF_ASSISTANT_BODY_ROWS: usize = 6;

const DividerTone = enum {
    neutral,
    warning,
    failure,
};

const TranscriptDecorState = struct {
    in_assistant_block: bool = false,
    assistant_brief_rows_used: usize = 0,
    assistant_brief_hidden_rows: usize = 0,
};

pub fn formatTranscriptDivider(out: []u8, label: []const u8) []const u8 {
    var pos: usize = 0;
    appendLiteral(out, &pos, TRANSCRIPT_DIVIDER_PREFIX);
    const remaining = if (out.len > pos + TRANSCRIPT_DIVIDER_SUFFIX.len) out.len - pos - TRANSCRIPT_DIVIDER_SUFFIX.len else 0;
    const take = @min(label.len, remaining);
    appendLiteral(out, &pos, label[0..take]);
    appendLiteral(out, &pos, TRANSCRIPT_DIVIDER_SUFFIX);
    return out[0..pos];
}

pub fn transcriptAssistantBlockStartMarker() []const u8 {
    return TRANSCRIPT_ASSISTANT_BLOCK_START;
}

pub fn transcriptAssistantBlockEndMarker() []const u8 {
    return TRANSCRIPT_ASSISTANT_BLOCK_END;
}

fn parseTranscriptDividerLabel(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, TRANSCRIPT_DIVIDER_PREFIX)) return null;
    if (!std.mem.endsWith(u8, line, TRANSCRIPT_DIVIDER_SUFFIX)) return null;
    const start = TRANSCRIPT_DIVIDER_PREFIX.len;
    const end = line.len - TRANSCRIPT_DIVIDER_SUFFIX.len;
    if (end < start) return null;
    return line[start..end];
}

fn isTranscriptAssistantBlockStart(line: []const u8) bool {
    return std.mem.eql(u8, line, TRANSCRIPT_ASSISTANT_BLOCK_START);
}

fn isTranscriptAssistantBlockEnd(line: []const u8) bool {
    return std.mem.eql(u8, line, TRANSCRIPT_ASSISTANT_BLOCK_END);
}

pub fn inputContentRows(input_text: []const u8, cols: usize) usize {
    if (input_text.len == 0) return 1;
    const content_max: usize = if (cols > 4) cols - 4 else 1;
    var content_buf: [16 * 1024]u8 = undefined;
    const content = repl_input.formatInputPreview(">", input_text, &content_buf);
    // Count rows considering both newlines and line wrapping
    var rows: usize = 1;
    var col: usize = 0;
    for (content) |ch| {
        if (ch == '\n') {
            rows += 1;
            col = 0;
        } else {
            col += 1;
            if (col >= content_max) {
                rows += 1;
                col = 0;
            }
        }
    }
    return @min(@max(rows, 1), 3); // 1-3 rows
}

pub fn transcriptWindowRows(total_rows: usize, options: anytype) usize {
    const margin = repl_spinner.boundedBottomMarginRows(total_rows, options.bottom_margin_rows);
    const panel_gap = inputPanelGapRows(total_rows);
    const chrome_gaps = bottomChromeGutterRows(total_rows) * 2;
    const reserved = 7 + chrome_gaps + panel_gap + margin + topContextBarRows(options); // input panel + footer + status + gutters + top bar + margin
    if (total_rows <= reserved) return 1;
    return total_rows - reserved;
}

pub fn inputPanelGapRows(total_rows: usize) usize {
    return if (total_rows >= 10) 1 else 0;
}

pub fn bottomChromeGutterRows(total_rows: usize) usize {
    return if (total_rows >= 14) 1 else 0;
}

fn topContextBarRows(options: anytype) usize {
    if (!@hasField(@TypeOf(options), "show_top_bar")) return 0;
    return if (options.show_top_bar) 1 else 0;
}

pub fn wrappedRowsForLine(line: []const u8, cols: usize) usize {
    const width = @max(@as(usize, 1), cols);
    if (line.len == 0) return 1;
    // Count rows by UTF-8 codepoints so emoji, CJK, and box-drawing
    // characters are not split mid-sequence. Previously this used byte
    // length, which caused any multi-byte line (`\xe2\x94\x82`, `你好`,
    // emoji) to over-report row count and slice halfway through a UTF-8
    // sequence in renderWrappedLineRows below.
    var rows: usize = 0;
    var byte_idx: usize = 0;
    while (byte_idx < line.len) {
        const info = utf8RowBoundary(line, byte_idx, width);
        if (info.end_byte <= byte_idx) break; // safety — malformed tail
        byte_idx = info.end_byte;
        rows += 1;
    }
    return @max(@as(usize, 1), rows);
}

/// Given a byte position and a cell width, return the byte index where
/// `width` terminal cells have been consumed. Malformed UTF-8 advances
/// one byte per step so the walker cannot get stuck. CJK, emoji, and
/// other East Asian wide characters count as two cells; everything else
/// counts as one. This is a conservative approximation of Unicode EAW
/// (Narrow/Halfwide are 1 cell, Fullwide/Wide are 2 cells) covering the
/// ranges that matter in real terminals.
fn utf8RowBoundary(line: []const u8, start_byte: usize, width: usize) struct { end_byte: usize, cells: usize } {
    var byte_idx = start_byte;
    var cells: usize = 0;
    while (byte_idx < line.len and cells < width) {
        const b = line[byte_idx];
        const seq_len: usize = blk: {
            if (b < 0x80) break :blk 1;
            if ((b & 0xE0) == 0xC0) break :blk 2;
            if ((b & 0xF0) == 0xE0) break :blk 3;
            if ((b & 0xF8) == 0xF0) break :blk 4;
            break :blk 1;
        };
        const end_of_seq = @min(byte_idx + seq_len, line.len);

        // Decode the codepoint for width classification. Malformed
        // sequences are charged one cell so we don't loop forever.
        var codepoint: u21 = 0;
        switch (seq_len) {
            1 => codepoint = b,
            2 => if (end_of_seq - byte_idx == 2) {
                codepoint = (@as(u21, b & 0x1F) << 6) | @as(u21, line[byte_idx + 1] & 0x3F);
            },
            3 => if (end_of_seq - byte_idx == 3) {
                codepoint = (@as(u21, b & 0x0F) << 12) |
                    (@as(u21, line[byte_idx + 1] & 0x3F) << 6) |
                    @as(u21, line[byte_idx + 2] & 0x3F);
            },
            4 => if (end_of_seq - byte_idx == 4) {
                codepoint = (@as(u21, b & 0x07) << 18) |
                    (@as(u21, line[byte_idx + 1] & 0x3F) << 12) |
                    (@as(u21, line[byte_idx + 2] & 0x3F) << 6) |
                    @as(u21, line[byte_idx + 3] & 0x3F);
            },
            else => {},
        }

        const cell_cost: usize = if (isWideCodepoint(codepoint)) 2 else 1;
        // Don't start a 2-wide character if only 1 cell is left in the
        // row — that would produce a broken visible cell. Break and let
        // the next row start with this codepoint.
        if (cell_cost > width - cells and cells > 0) break;

        byte_idx = end_of_seq;
        cells += cell_cost;
    }
    return .{ .end_byte = byte_idx, .cells = cells };
}

/// Conservative East Asian Width check. Returns true for codepoints that
/// typical terminals render as two cells: CJK ideographs, Hangul syllables,
/// Hiragana/Katakana, Fullwidth forms, and the common emoji ranges. This
/// is a small hand-rolled table rather than the full Unicode EAW database.
fn isWideCodepoint(cp: u21) bool {
    if (cp < 0x1100) return false;
    return switch (cp) {
        // Hangul Jamo
        0x1100...0x115F => true,
        // CJK Radicals Supplement, Kangxi Radicals, Ideographic Description Characters
        0x2E80...0x303E => true,
        // Hiragana, Katakana, Bopomofo, Hangul Compatibility Jamo, Kanbun, Bopomofo Ext
        0x3041...0x33FF => true,
        // CJK Unified Ideographs Extension A
        0x3400...0x4DBF => true,
        // CJK Unified Ideographs
        0x4E00...0x9FFF => true,
        // Yi Syllables, Yi Radicals
        0xA000...0xA4CF => true,
        // Hangul Syllables
        0xAC00...0xD7A3 => true,
        // CJK Compatibility Ideographs
        0xF900...0xFAFF => true,
        // Vertical Forms, CJK Compatibility Forms, Small Form Variants
        0xFE30...0xFE4F => true,
        // Halfwidth and Fullwidth Forms (the fullwidth range)
        0xFF00...0xFF60 => true,
        0xFFE0...0xFFE6 => true,
        // Emoticons, Miscellaneous Symbols and Pictographs, Transport, Supplemental Symbols
        0x1F300...0x1F64F => true,
        0x1F680...0x1F6FF => true,
        0x1F900...0x1F9FF => true,
        0x1FA70...0x1FAFF => true,
        // CJK Unified Ideographs Extension B–G
        0x20000...0x2FFFD => true,
        0x30000...0x3FFFD => true,
        else => false,
    };
}

/// Return the byte slice representing the `row_idx`-th wrapped row of
/// `line` at the given cell `width`. Returns an empty slice when the
/// row is past the end of the line.
fn utf8RowSlice(line: []const u8, row_idx: usize, width: usize) []const u8 {
    if (line.len == 0) return "";
    var byte_idx: usize = 0;
    var r: usize = 0;
    while (r < row_idx) : (r += 1) {
        if (byte_idx >= line.len) return "";
        const info = utf8RowBoundary(line, byte_idx, width);
        if (info.end_byte <= byte_idx) return "";
        byte_idx = info.end_byte;
    }
    if (byte_idx >= line.len) return "";
    const info = utf8RowBoundary(line, byte_idx, width);
    return line[byte_idx..info.end_byte];
}

fn assistantCardInnerWidth(cols: usize) usize {
    return if (cols > 2) cols - 2 else 1;
}

fn isBriefMode(options: anytype) bool {
    return if (@hasField(@TypeOf(options), "brief_mode")) options.brief_mode else false;
}

fn isCleanDensity(options: anytype) bool {
    return @hasField(@TypeOf(options), "ui_density") and options.ui_density == .clean;
}

/// Whether to wrap the full-screen redraw in DEC 2026 BSU/ESU. The REPL sets
/// `enable_synchronized_output` once from `terminal_caps.isSynchronizedOutputSupported`
/// so this hot render path does not re-read env per frame. Defaults to false
/// when the field is absent (e.g. focused render tests), which keeps the
/// frame starting with the bare clear-screen sequence.
fn synchronizedOutputEnabled(options: anytype) bool {
    return @hasField(@TypeOf(options), "enable_synchronized_output") and options.enable_synchronized_output;
}

fn assistantInnerWidthForOptions(cols: usize, options: anytype) usize {
    return if (isCleanDensity(options)) @max(@as(usize, 1), cols) else assistantCardInnerWidth(cols);
}

fn assistantVisibleRowsForLine(line: []const u8, cols: usize, decor_state: TranscriptDecorState, options: anytype) usize {
    const full_rows = wrappedRowsForLine(line, assistantInnerWidthForOptions(cols, options));
    if (!decor_state.in_assistant_block or !isBriefMode(options)) return full_rows;
    if (decor_state.assistant_brief_rows_used >= BRIEF_ASSISTANT_BODY_ROWS) return 0;
    return @min(full_rows, BRIEF_ASSISTANT_BODY_ROWS - decor_state.assistant_brief_rows_used);
}

fn assistantHiddenRowsForLine(line: []const u8, cols: usize, decor_state: TranscriptDecorState, options: anytype) usize {
    const full_rows = wrappedRowsForLine(line, assistantInnerWidthForOptions(cols, options));
    const visible_rows = assistantVisibleRowsForLine(line, cols, decor_state, options);
    return full_rows - visible_rows;
}

fn visualRowsForTranscriptLineWithState(line: []const u8, cols: usize, decor_state: TranscriptDecorState, options: anytype) usize {
    if (parseTranscriptDividerLabel(line) != null) return 1;
    if (isTranscriptAssistantBlockStart(line)) return if (isCleanDensity(options)) 0 else 1;
    if (isTranscriptAssistantBlockEnd(line)) {
        if (isCleanDensity(options)) {
            return if (isBriefMode(options) and decor_state.assistant_brief_hidden_rows > 0) 1 else 0;
        }
        if (isBriefMode(options) and decor_state.assistant_brief_hidden_rows > 0) return 2;
        return 1;
    }
    if (decor_state.in_assistant_block) return assistantVisibleRowsForLine(line, cols, decor_state, options);
    return wrappedRowsForLine(line, cols);
}

pub fn visualRowsForTranscriptLine(line: []const u8, cols: usize) usize {
    return visualRowsForTranscriptLineWithState(line, cols, .{}, .{});
}

fn advanceTranscriptDecorState(line: []const u8, cols: usize, decor_state: *TranscriptDecorState, options: anytype) void {
    if (isTranscriptAssistantBlockStart(line)) {
        decor_state.in_assistant_block = true;
        decor_state.assistant_brief_rows_used = 0;
        decor_state.assistant_brief_hidden_rows = 0;
        return;
    }
    if (isTranscriptAssistantBlockEnd(line)) {
        decor_state.in_assistant_block = false;
        decor_state.assistant_brief_rows_used = 0;
        decor_state.assistant_brief_hidden_rows = 0;
        return;
    }
    if (decor_state.in_assistant_block and isBriefMode(options)) {
        decor_state.assistant_brief_hidden_rows += assistantHiddenRowsForLine(line, cols, decor_state.*, options);
        decor_state.assistant_brief_rows_used += assistantVisibleRowsForLine(line, cols, decor_state.*, options);
    }
}

fn isTranscriptCardLine(line: []const u8) bool {
    if (line.len == 0) return false;
    return std.mem.startsWith(u8, line, repl_markdown.BOX_TL) or
        std.mem.startsWith(u8, line, repl_markdown.BOX_V) or
        std.mem.startsWith(u8, line, repl_markdown.BOX_BL);
}

fn transcriptSpacingRows(current: []const u8, next: ?[]const u8, line_spacing: usize, decor_state_after_current: TranscriptDecorState, current_line_rows: usize, next_line_rows: ?usize) usize {
    if (line_spacing == 0 or next == null) return 0;
    if (current_line_rows == 0 or (next_line_rows orelse 0) == 0) return 0;
    const next_line = next.?;
    if (parseTranscriptDividerLabel(current) != null or parseTranscriptDividerLabel(next_line) != null) return 0;
    if (isTranscriptAssistantBlockStart(current) or isTranscriptAssistantBlockEnd(current)) return 0;
    if (isTranscriptAssistantBlockStart(next_line) or isTranscriptAssistantBlockEnd(next_line)) return 0;
    if (decor_state_after_current.in_assistant_block) return 0;
    if (isTranscriptCardLine(current) and isTranscriptCardLine(next_line)) return 0;
    return line_spacing;
}

fn dividerToneFromLabel(label: []const u8) DividerTone {
    if (repl_markdown.containsIgnoreCase(label, "error") or repl_markdown.containsIgnoreCase(label, "failed")) {
        return .failure;
    }
    if (repl_markdown.containsIgnoreCase(label, "warning")) {
        return .warning;
    }
    return .neutral;
}

fn dividerToneAnsi(options: anytype, tone: DividerTone) []const u8 {
    return switch (tone) {
        .neutral => "",
        .warning => repl_markdown.warningAnsi(options),
        .failure => repl_markdown.errorPrefixAnsi(options),
    };
}

pub fn transcriptVisualRows(transcript: *const UiTranscript, cols: usize, options: anytype) usize {
    const line_spacing = repl_spinner.boundedLineSpacingRows(if (isBriefMode(options) or isCleanDensity(options)) 0 else options.transcript_line_spacing);
    var total: usize = 0;
    var decor_state: TranscriptDecorState = .{};
    for (transcript.lines.items, 0..) |line, idx| {
        const line_rows = visualRowsForTranscriptLineWithState(line, cols, decor_state, options);
        total += line_rows;
        var next_state = decor_state;
        advanceTranscriptDecorState(line, cols, &next_state, options);
        const next = if (idx + 1 < transcript.lines.items.len) transcript.lines.items[idx + 1] else null;
        const next_line_rows = if (next) |next_line| visualRowsForTranscriptLineWithState(next_line, cols, next_state, options) else null;
        total += transcriptSpacingRows(line, next, line_spacing, next_state, line_rows, next_line_rows);
        decor_state = next_state;
    }
    return total;
}

pub fn maxScrollOffset(transcript: *const UiTranscript, rows: usize, cols: usize, options: anytype) usize {
    const window_rows = transcriptWindowRows(rows, options);
    const total_rows = transcriptVisualRows(transcript, cols, options);
    return if (total_rows > window_rows) total_rows - window_rows else 0;
}

pub fn clampScrollOffset(offset: usize, transcript: *const UiTranscript, rows: usize, cols: usize, options: anytype) usize {
    return @min(offset, maxScrollOffset(transcript, rows, cols, options));
}

pub fn renderWrappedLineRows(
    writer: anytype,
    line: []const u8,
    cols: usize,
    row_from: usize,
    row_to: usize,
    kind: repl_markdown.LineRenderKind,
    state: *repl_markdown.MarkdownRenderState,
    options: anytype,
) !void {
    const width = @max(@as(usize, 1), cols);
    if (row_from >= row_to) return;

    var row_idx = row_from;
    while (row_idx < row_to) : (row_idx += 1) {
        // Slice on UTF-8 codepoint boundaries so box-drawing, CJK, and
        // emoji characters are never cut mid-sequence. The old byte-based
        // slicing emitted invalid UTF-8 fragments into the terminal on
        // every wrap in the assistant transcript.
        const chunk = utf8RowSlice(line, row_idx, width);

        switch (kind) {
            .plain => try repl_markdown.writeStyledLine(writer, chunk, options, state),
            .code => try repl_markdown.writeCodeLine(writer, chunk, state.code_lang, options),
            .auto_code => try repl_markdown.writeCodeLine(writer, chunk, repl_markdown.detectStandaloneCodeLang(line), options),
            .hidden => {},
            .fence => {
                if (row_idx == row_from) {
                    const fence_tag = repl_markdown.parseCodeFence(line) orelse "";
                    const entering = !state.in_code_block;
                    try repl_markdown.writeCodeFenceMarker(writer, fence_tag, entering, options);
                }
            },
        }

        try writer.writeByte('\n');
    }
}

fn renderAssistantWrappedLineRows(
    writer: anytype,
    line: []const u8,
    cols: usize,
    row_from: usize,
    row_to: usize,
    kind: repl_markdown.LineRenderKind,
    state: *repl_markdown.MarkdownRenderState,
    options: anytype,
) !void {
    const use_color = repl_markdown.shouldUseColor(options);
    const width = assistantInnerWidthForOptions(cols, options);
    if (row_from >= row_to) return;

    var row_idx = row_from;
    while (row_idx < row_to) : (row_idx += 1) {
        // Codepoint-safe slice (see renderWrappedLineRows above).
        const chunk = utf8RowSlice(line, row_idx, width);

        if (!isCleanDensity(options)) {
            if (use_color) try writer.writeAll(repl_markdown.ANSI_DIM);
            try writer.writeAll(repl_markdown.BOX_V);
            if (use_color) try writer.writeAll(repl_markdown.ANSI_RESET);
            try writer.writeByte(' ');
        }

        switch (kind) {
            .plain => try repl_markdown.writeStyledLine(writer, chunk, options, state),
            .code => try repl_markdown.writeCodeLine(writer, chunk, state.code_lang, options),
            .auto_code => try repl_markdown.writeCodeLine(writer, chunk, repl_markdown.detectStandaloneCodeLang(line), options),
            .hidden => {},
            .fence => {
                if (row_idx == row_from) {
                    const fence_tag = repl_markdown.parseCodeFence(line) orelse "";
                    const entering = !state.in_code_block;
                    try repl_markdown.writeCodeFenceMarker(writer, fence_tag, entering, options);
                }
            },
        }
        try writer.writeByte('\n');
    }
}

fn writeAssistantCardBorder(writer: anytype, cols: usize, top: bool, options: anytype) !void {
    if (isCleanDensity(options)) return;
    const use_color = repl_markdown.shouldUseColor(options);
    if (cols <= 1) {
        if (use_color) try writer.writeAll(repl_markdown.ANSI_DIM);
        try writer.writeAll(if (top) repl_markdown.BOX_TL else repl_markdown.BOX_BL);
        if (use_color) try writer.writeAll(repl_markdown.ANSI_RESET);
        return;
    }

    if (use_color) try writer.writeAll(repl_markdown.ANSI_DIM);
    try writer.writeAll(if (top) repl_markdown.BOX_TL else repl_markdown.BOX_BL);
    var i: usize = 1;
    while (i + 1 < cols) : (i += 1) {
        try writer.writeAll(repl_markdown.BOX_H);
    }
    try writer.writeAll(if (top) repl_markdown.BOX_TR else repl_markdown.BOX_BR);
    if (use_color) try writer.writeAll(repl_markdown.ANSI_RESET);
}

fn writeAssistantBriefNotice(writer: anytype, cols: usize, hidden_rows: usize, options: anytype) !void {
    const use_color = repl_markdown.shouldUseColor(options);
    const width = assistantInnerWidthForOptions(cols, options);

    if (!isCleanDensity(options)) {
        if (use_color) try writer.writeAll(repl_markdown.ANSI_DIM);
        try writer.writeAll(repl_markdown.BOX_V);
        if (use_color) try writer.writeAll(repl_markdown.ANSI_RESET);
        try writer.writeByte(' ');
    }

    var msg_buf: [160]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &msg_buf,
        "{s} brief view hidden {d} more row{s} \xe2\x88\x99 Ctrl+Shift+B full",
        .{ figures.ELLIPSIS, hidden_rows, if (hidden_rows == 1) "" else "s" },
    ) catch "brief view hidden";
    var clipped_buf: [160]u8 = undefined;
    const clipped = clipEndInto(clipped_buf[0..], msg, width);
    if (use_color) try writer.writeAll(repl_markdown.ANSI_DIM);
    try writer.writeAll(clipped);
    if (use_color) try writer.writeAll(repl_markdown.ANSI_RESET);
}

fn renderAssistantEndRows(writer: anytype, cols: usize, row_from: usize, row_to: usize, decor_state: TranscriptDecorState, options: anytype) !void {
    if (row_from >= row_to) return;

    if (isBriefMode(options) and decor_state.assistant_brief_hidden_rows > 0) {
        if (row_from == 0) {
            try writeAssistantBriefNotice(writer, cols, decor_state.assistant_brief_hidden_rows, options);
            try writer.writeByte('\n');
        }
        if (!isCleanDensity(options) and row_to > 1) {
            try writeAssistantCardBorder(writer, cols, false, options);
            try writer.writeByte('\n');
        }
        return;
    }

    if (isCleanDensity(options)) return;
    try writeAssistantCardBorder(writer, cols, false, options);
    try writer.writeByte('\n');
}

pub fn renderFullScreenWithCursor(
    writer: anytype,
    transcript: *const UiTranscript,
    show_prompt: bool,
    input_text: []const u8,
    input_cursor: usize,
    scroll_offset: usize,
    hint: []const u8,
    mode: anytype,
    options: anytype,
) !void {
    return renderFullScreenWithCursorSelection(writer, transcript, show_prompt, input_text, input_cursor, scroll_offset, hint, 0, mode, options);
}

pub fn renderFullScreenWithCursorSelection(
    writer: anytype,
    transcript: *const UiTranscript,
    show_prompt: bool,
    input_text: []const u8,
    input_cursor: usize,
    scroll_offset: usize,
    hint: []const u8,
    slash_suggestion_selection: usize,
    mode: anytype,
    options: anytype,
) !void {
    return renderFullScreenInternal(writer, transcript, show_prompt, input_text, input_cursor, scroll_offset, hint, slash_suggestion_selection, mode, options);
}

pub fn renderFullScreen(
    writer: anytype,
    transcript: *const UiTranscript,
    show_prompt: bool,
    input_text: []const u8,
    scroll_offset: usize,
    hint: []const u8,
    mode: anytype,
    options: anytype,
) !void {
    return renderFullScreenInternal(writer, transcript, show_prompt, input_text, input_text.len, scroll_offset, hint, 0, mode, options);
}

fn renderFullScreenInternal(
    writer: anytype,
    transcript: *const UiTranscript,
    show_prompt: bool,
    input_text: []const u8,
    input_cursor: usize,
    scroll_offset: usize,
    hint: []const u8,
    slash_suggestion_selection: usize,
    mode: anytype,
    options: anytype,
) !void {
    // DEC 2026: open a synchronized update so the whole frame lands
    // atomically (no flicker) on capable terminals. Closed at the tail.
    const sync_output = synchronizedOutputEnabled(options);
    if (sync_output) try writer.writeAll(terminal_caps.BSU);

    try writer.writeAll("\x1b[2J\x1b[H");

    const rows = repl_spinner.terminalRows();
    const cols = repl_spinner.terminalCols();
    const line_spacing = repl_spinner.boundedLineSpacingRows(if (isBriefMode(options) or isCleanDensity(options)) 0 else options.transcript_line_spacing);
    const margin = repl_spinner.boundedBottomMarginRows(rows, options.bottom_margin_rows);
    const window_rows = transcriptWindowRows(rows, options);
    const show_transcript = shouldShowTranscript(options);
    const total_rows = if (show_transcript) transcriptVisualRows(transcript, cols, options) else 1;
    const max_off = if (show_transcript) maxScrollOffset(transcript, rows, cols, options) else 0;
    const offset = if (show_transcript) clampScrollOffset(scroll_offset, transcript, rows, cols, options) else 0;

    if (topContextBarRows(options) > 0) {
        try renderTopContextBar(writer, options, mode, cols);
        try writer.writeByte('\n');
    }

    const end_row = total_rows - offset;
    var content_rows = window_rows;
    var start_row = if (end_row > content_rows) end_row - content_rows else 0;
    var show_earlier_indicator = show_transcript and start_row > 0 and window_rows > 1;

    if (show_earlier_indicator) {
        content_rows = window_rows - 1;
        start_row = if (end_row > content_rows) end_row - content_rows else 0;
        show_earlier_indicator = start_row > 0;
    }

    if (show_earlier_indicator) {
        try writer.print("... {d} earlier rows above ...\n", .{start_row});
    }

    if (show_transcript) {
        var md_state = repl_markdown.MarkdownRenderState{};
        var decor_state: TranscriptDecorState = .{};
        var row_cursor: usize = 0;
        for (transcript.lines.items, 0..) |line, line_idx| {
            const divider_label = parseTranscriptDividerLabel(line);
            const assistant_start = isTranscriptAssistantBlockStart(line);
            const assistant_end = isTranscriptAssistantBlockEnd(line);
            const line_rows = visualRowsForTranscriptLineWithState(line, cols, decor_state, options);
            const line_start = row_cursor;
            const line_end = row_cursor + line_rows;
            var next_decor_state = decor_state;
            advanceTranscriptDecorState(line, cols, &next_decor_state, options);
            const next = if (line_idx + 1 < transcript.lines.items.len) transcript.lines.items[line_idx + 1] else null;
            const next_line_rows = if (next) |next_line| visualRowsForTranscriptLineWithState(next_line, cols, next_decor_state, options) else null;
            const spacing_rows = transcriptSpacingRows(line, next, line_spacing, next_decor_state, line_rows, next_line_rows);
            const block_end = line_end + spacing_rows;

            if (block_end <= start_row) {
                if (divider_label == null and !assistant_start and !assistant_end) {
                    repl_markdown.advanceMarkdownStateForLine(line, &md_state);
                }
                decor_state = next_decor_state;
                row_cursor = block_end;
                continue;
            }
            if (line_start >= end_row) break;

            if (line_end > start_row and line_start < end_row) {
                const row_from = if (start_row > line_start) start_row - line_start else 0;
                const row_to = if (end_row < line_end) end_row - line_start else line_rows;
                if (divider_label) |label| {
                    if (row_from == 0 and row_to > 0) {
                        try writeTranscriptDivider(writer, label, cols, options);
                        try writer.writeByte('\n');
                    }
                } else if (assistant_start) {
                    if (row_from == 0 and row_to > 0) {
                        try writeAssistantCardBorder(writer, cols, true, options);
                        try writer.writeByte('\n');
                    }
                } else if (assistant_end) {
                    try renderAssistantEndRows(writer, cols, row_from, row_to, decor_state, options);
                } else {
                    const render_kind = repl_markdown.classifyLineRenderKind(line, &md_state);
                    if (decor_state.in_assistant_block) {
                        try renderAssistantWrappedLineRows(writer, line, cols, row_from, row_to, render_kind, &md_state, options);
                    } else {
                        try renderWrappedLineRows(writer, line, cols, row_from, row_to, render_kind, &md_state, options);
                    }
                }
            }

            if (divider_label == null and !assistant_start and !assistant_end) {
                repl_markdown.advanceMarkdownStateForLine(line, &md_state);
            }
            decor_state = next_decor_state;

            if (spacing_rows > 0 and line_end < end_row and block_end > start_row) {
                const blank_start = if (start_row > line_end) start_row else line_end;
                const blank_end = if (end_row < block_end) end_row else block_end;
                var blank_row = blank_start;
                while (blank_row < blank_end) : (blank_row += 1) {
                    try writer.writeByte('\n');
                }
            }

            row_cursor = block_end;
        }
    } else {
        try renderCollapsedTranscriptPlaceholder(writer, transcript, cols, options);
    }

    const actual_input = if (show_prompt) input_text else "";
    const input_rows = inputContentRows(actual_input, cols);
    const chrome_gutter_rows = bottomChromeGutterRows(rows);
    const status_row = if (rows > margin) rows - margin else 1;
    const footer_row = if (status_row > chrome_gutter_rows + 1) status_row - chrome_gutter_rows - 1 else 1;
    const input_bottom_row = if (footer_row > chrome_gutter_rows + 1) footer_row - chrome_gutter_rows - 1 else 1;
    // Reserve rows for multi-line input
    const input_first_row = if (input_bottom_row > input_rows) input_bottom_row - input_rows else 1;
    const input_top_row = if (input_first_row > 1) input_first_row - 1 else 1;

    var clear_row = input_top_row;
    while (clear_row <= rows) : (clear_row += 1) {
        try writer.print("\x1b[{d};1H\x1b[2K", .{clear_row});
    }

    try writer.print("\x1b[{d};1H\x1b[2K", .{input_top_row});
    try renderComposerBorder(writer, cols, true, mode, options);

    if (show_prompt) {
        const shortcut_rows = try renderShortcutsPanelOverlay(writer, cols, input_top_row, options);
        if (shortcut_rows == 0) {
            const strip_rows = try renderPromptStripOverlay(writer, cols, input_top_row, options);
            const overlay_top_row = input_top_row -| strip_rows;
            const rendered_footer_overlay = try renderFooterRowsOverlay(writer, cols, overlay_top_row, options);
            if (!rendered_footer_overlay) {
                const rendered_reference_overlay = try renderReferenceSuggestionOverlay(writer, cols, overlay_top_row, options);
                if (!rendered_reference_overlay) {
                    try renderSlashSuggestionOverlay(writer, actual_input, cols, overlay_top_row, slash_suggestion_selection, options);
                }
            }
        }
    }

    try renderMultiLineInput(writer, options.prompt_label, actual_input, cols, input_first_row, input_rows, show_prompt and actual_input.len == 0, options);

    try writer.print("\x1b[{d};1H\x1b[2K", .{input_bottom_row});
    try renderComposerBorder(writer, cols, false, mode, options);

    try writer.print("\x1b[{d};1H\x1b[2K", .{footer_row});
    try renderPromptFooter(writer, options, mode, cols, actual_input);

    try writer.print("\x1b[{d};1H\x1b[2K", .{status_row});
    try renderStatusLine(writer, options, mode, offset, max_off, hint, cols);

    if (show_prompt) {
        // Place cursor at the input_cursor position within the rendered input
        const cursor_pos = computeMultilineCursorPosition(options.prompt_label, actual_input, input_cursor, cols, input_rows);
        const target_row = input_first_row + cursor_pos.row;
        try writer.print("\x1b[{d};{d}H", .{ target_row, cursor_pos.col });
    }

    // DEC 2026: close the synchronized update so the terminal flushes the
    // assembled frame in one shot.
    if (sync_output) try writer.writeAll(terminal_caps.ESU);
}

fn tryAppendFooterSegment(buf: []u8, pos: *usize, cols: usize, text: []const u8) bool {
    if (text.len == 0) return false;
    const limit = @min(cols, buf.len);
    const sep = if (pos.* > 0) FOOTER_SEGMENT_SEPARATOR else "";
    if (pos.* + sep.len + text.len > limit) return false;
    if (sep.len > 0) appendLiteral(buf, pos, sep);
    appendLiteral(buf, pos, text);
    return true;
}

fn forceAppendFooterSegment(buf: []u8, pos: *usize, cols: usize, text: []const u8) void {
    if (text.len == 0) return;
    const limit = @min(cols, buf.len);
    if (limit <= pos.*) return;
    if (pos.* > 0) {
        if (pos.* + FOOTER_SEGMENT_SEPARATOR.len > limit) return;
        appendLiteral(buf, pos, FOOTER_SEGMENT_SEPARATOR);
    }
    if (limit <= pos.*) return;
    const take = @min(text.len, limit - pos.*);
    appendLiteral(buf, pos, text[0..take]);
}

fn appendBestFooterSegment(buf: []u8, pos: *usize, cols: usize, candidates: []const []const u8, required: bool) void {
    for (candidates) |candidate| {
        if (tryAppendFooterSegment(buf, pos, cols, candidate)) return;
    }
    if (required and candidates.len > 0) {
        forceAppendFooterSegment(buf, pos, cols, candidates[candidates.len - 1]);
    }
}

const FooterSegmentTone = enum {
    accent,
    selected,
    dim,
    plain,
    danger,
};

fn writeFooterSegment(writer: anytype, used_cols: *usize, cols: usize, text: []const u8, tone: FooterSegmentTone, options: anytype) !bool {
    if (text.len == 0) return false;
    const sep = if (used_cols.* > 0) FOOTER_SEGMENT_SEPARATOR else "";
    if (used_cols.* + sep.len + text.len > cols) return false;

    if (sep.len > 0) {
        if (repl_markdown.shouldUseColor(options)) try writer.writeAll(repl_markdown.ANSI_DIM);
        try writer.writeAll(sep);
        if (repl_markdown.shouldUseColor(options)) try writer.writeAll(repl_markdown.ANSI_RESET);
    }

    if (repl_markdown.shouldUseColor(options)) {
        switch (tone) {
            .accent => try writer.writeAll(repl_markdown.promptAnsi(options)),
            .selected => {
                try writer.writeAll(repl_markdown.promptAnsi(options));
                try writer.writeAll(repl_markdown.ANSI_BOLD);
            },
            .dim => try writer.writeAll(repl_markdown.ANSI_DIM),
            .plain => {},
            .danger => {
                try writer.writeAll(repl_markdown.ANSI_BOLD);
                try writer.writeAll(repl_markdown.ANSI_ERROR_PREFIX);
            },
        }
    }
    try writer.writeAll(text);
    if (repl_markdown.shouldUseColor(options) and tone != .plain) {
        try writer.writeAll(repl_markdown.ANSI_RESET);
    }

    used_cols.* += sep.len + text.len;
    return true;
}

fn writeBestFooterSegment(writer: anytype, used_cols: *usize, cols: usize, candidates: []const []const u8, tone: FooterSegmentTone, options: anytype) !void {
    for (candidates) |candidate| {
        if (try writeFooterSegment(writer, used_cols, cols, candidate, tone, options)) return;
    }
}

fn promptLineCount(input_text: []const u8) usize {
    if (input_text.len == 0) return 0;
    var lines: usize = 1;
    for (input_text) |ch| {
        if (ch == '\n') lines += 1;
    }
    return lines;
}

fn promptCharCount(input_text: []const u8) usize {
    var count: usize = 0;
    for (input_text) |ch| {
        if ((ch & 0xC0) != 0x80) count += 1;
    }
    return count;
}

fn renderDraftMeter(writer: anytype, used_cols: *usize, cols: usize, input_text: []const u8, options: anytype) !void {
    if (input_text.len == 0) return;

    const chars = promptCharCount(input_text);
    const lines = promptLineCount(input_text);
    var full_buf: [96]u8 = undefined;
    var compact_buf: [48]u8 = undefined;
    var min_buf: [24]u8 = undefined;

    const full = if (lines > 1)
        std.fmt.bufPrint(&full_buf, "draft {d} chars / {d} lines", .{ chars, lines }) catch ""
    else
        std.fmt.bufPrint(&full_buf, "draft {d} chars", .{chars}) catch "";
    const compact = if (lines > 1)
        std.fmt.bufPrint(&compact_buf, "draft {d}c/{d}l", .{ chars, lines }) catch ""
    else
        std.fmt.bufPrint(&compact_buf, "draft {d}c", .{chars}) catch "";
    const minimal = std.fmt.bufPrint(&min_buf, "{d}c", .{chars}) catch "";

    const candidates = [_][]const u8{ full, compact, minimal };
    try writeBestFooterSegment(writer, used_cols, cols, &candidates, .dim, options);
}

fn renderPromptFooter(writer: anytype, options: anytype, mode: anytype, cols: usize, input_text: []const u8) !void {
    if (cols == 0) return;

    var used_cols: usize = 0;

    _ = mode;
    _ = try writeFooterSegment(writer, &used_cols, cols, "actions", .accent, options);

    if (@hasField(@TypeOf(options), "input_mode_label")) {
        if (options.input_mode_label.len > 0) {
            _ = try writeFooterSegment(writer, &used_cols, cols, options.input_mode_label, .dim, options);
        }
    }

    try renderDraftMeter(writer, &used_cols, cols, input_text, options);

    if (options.yolo_mode) {
        var yolo_full_buf: [32]u8 = undefined;
        var yolo_short_buf: [20]u8 = undefined;
        const yolo_full = std.fmt.bufPrint(&yolo_full_buf, "{s} auto-approve", .{figures.LIGHTNING_BOLT}) catch "";
        const yolo_short = std.fmt.bufPrint(&yolo_short_buf, "{s} yolo", .{figures.LIGHTNING_BOLT}) catch "";
        _ = try writeFooterSegment(writer, &used_cols, cols, if (yolo_full.len <= cols) yolo_full else if (yolo_short.len <= cols) yolo_short else "yolo", .danger, options);
    }

    if (options.status_show_safety) {
        const safety_tone: FooterSegmentTone = if (sandbox_mod.isDangerProfile(options.status_sandbox)) .danger else .dim;
        if (options.yolo_mode) {
            if (options.status_sandbox.len > 0) {
                _ = try writeFooterSegment(writer, &used_cols, cols, options.status_sandbox, safety_tone, options);
            }
        } else if (options.status_approval_mode.len > 0 and options.status_sandbox.len > 0) {
            var safety_full_buf: [96]u8 = undefined;
            var safety_short_buf: [72]u8 = undefined;
            const safety_full = std.fmt.bufPrint(&safety_full_buf, "{s} / {s}", .{ options.status_approval_mode, options.status_sandbox }) catch "";
            const safety_short = std.fmt.bufPrint(&safety_short_buf, "{s}/{s}", .{ options.status_approval_mode, options.status_sandbox }) catch "";
            const safety = if (safety_full.len <= cols) safety_full else if (safety_short.len <= cols) safety_short else if (options.status_sandbox.len > 0) options.status_sandbox else options.status_approval_mode;
            _ = try writeFooterSegment(writer, &used_cols, cols, safety, safety_tone, options);
        } else if (options.status_sandbox.len > 0 or options.status_approval_mode.len > 0) {
            const safety_single = if (options.status_sandbox.len > 0) options.status_sandbox else options.status_approval_mode;
            _ = try writeFooterSegment(writer, &used_cols, cols, safety_single, safety_tone, options);
        }
    }

    if (@hasField(@TypeOf(options), "footer_tmux_state")) {
        if (options.footer_tmux_state.len > 0) {
            _ = try writeFooterSegment(writer, &used_cols, cols, options.footer_tmux_state, .dim, options);
        }
    }
    if (@hasField(@TypeOf(options), "footer_worktree_state")) {
        if (options.footer_worktree_state.len > 0) {
            _ = try writeFooterSegment(writer, &used_cols, cols, options.footer_worktree_state, .dim, options);
        }
    }
    if (@hasField(@TypeOf(options), "footer_agent_state")) {
        if (options.footer_agent_state.len > 0) {
            _ = try writeFooterSegment(writer, &used_cols, cols, options.footer_agent_state, .dim, options);
        }
    }

    if (!footerRowsContainKind(options, .queue) and !promptStripContainsKind(options, .queue) and @hasField(@TypeOf(options), "queued_prompt_notice")) {
        if (options.queued_prompt_notice.len > 0) {
            _ = try writeFooterSegment(writer, &used_cols, cols, options.queued_prompt_notice, .accent, options);
        }
    }

    if (!footerRowsContainKind(options, .stash) and !promptStripContainsKind(options, .stash) and @hasField(@TypeOf(options), "stashed_prompt_available")) {
        if (options.stashed_prompt_available) {
            _ = try writeFooterSegment(writer, &used_cols, cols, "stash ready", .plain, options);
        }
    }

    // The redundant `? shortcuts`, palette/model/session hints, and
    // Tab Tab density toggle live in the prompt-hint row directly above
    // this footer (see the "Enter submit · Shift+Enter newline ·
    // ? shortcuts · ctrl+x h palette" line). Repeating them in the
    // actions bar made the bottom 3 rows visually dense for no extra
    // information; the prompt-hint row is the canonical place for
    // keyboard hints and the actions bar now sticks to status
    // (auto-approve, safety, queue, stash, etc.).
}

fn footerRowsContainKind(options: anytype, kind: repl_footer.RowKind) bool {
    if (!@hasField(@TypeOf(options), "footer_rows")) return false;
    for (options.footer_rows) |row| {
        if (row.kind == kind) return true;
    }
    return false;
}

fn promptStripContainsKind(options: anytype, kind: repl_footer.StripKind) bool {
    if (!@hasField(@TypeOf(options), "prompt_strip_items")) return false;
    for (options.prompt_strip_items) |item| {
        if (item.kind == kind) return true;
    }
    return false;
}

fn renderShortcutsPanelOverlay(writer: anytype, cols: usize, input_top_row: usize, options: anytype) !usize {
    if (cols == 0 or input_top_row <= 1) return 0;
    if (!@hasField(@TypeOf(options), "shortcuts_panel_visible")) return 0;
    if (!@hasField(@TypeOf(options), "shortcuts_panel_enabled")) return 0;
    if (!options.shortcuts_panel_enabled or !options.shortcuts_panel_visible) return 0;

    const available_rows = input_top_row - 1;
    const used_rows = @min(@as(usize, 4), available_rows);
    if (used_rows < 3) return 0;

    const top_row = input_top_row - used_rows;
    const use_color = repl_markdown.shouldUseColor(options);
    var leader_palette_buf: [48]u8 = undefined;
    var leader_model_buf: [48]u8 = undefined;
    var leader_session_buf: [48]u8 = undefined;
    var leader_search_buf: [48]u8 = undefined;
    var leader_tasks_buf: [48]u8 = undefined;
    var leader_runtime_buf: [48]u8 = undefined;
    const leader_palette = std.fmt.bufPrint(&leader_palette_buf, "{s} h palette", .{options.ui_leader_key}) catch options.ui_leader_key;
    const leader_model = std.fmt.bufPrint(&leader_model_buf, "{s} m model", .{options.ui_leader_key}) catch options.ui_leader_key;
    const leader_session = std.fmt.bufPrint(&leader_session_buf, "{s} s sessions", .{options.ui_leader_key}) catch options.ui_leader_key;
    const leader_search = std.fmt.bufPrint(&leader_search_buf, "{s} g search", .{options.ui_leader_key}) catch options.ui_leader_key;
    const leader_tasks = std.fmt.bufPrint(&leader_tasks_buf, "{s} t tasks", .{options.ui_leader_key}) catch options.ui_leader_key;
    const leader_runtime = std.fmt.bufPrint(&leader_runtime_buf, "{s} a runtime", .{options.ui_leader_key}) catch options.ui_leader_key;

    var row = top_row;
    try writer.print("\x1b[{d};1H\x1b[2K", .{row});
    if (use_color) {
        try writer.writeAll(repl_markdown.promptAnsi(options));
        try writer.writeAll(repl_markdown.ANSI_BOLD);
    }
    var title_buf: [192]u8 = undefined;
    const title = clipEndInto(title_buf[0..], " Shortcuts  •  ? close  •  Enter submit  •  Tab Tab density", cols);
    try writer.writeAll(title);
    if (use_color) try writer.writeAll(repl_markdown.ANSI_RESET);
    row += 1;

    try writer.print("\x1b[{d};1H\x1b[2K", .{row});
    if (use_color) try writer.writeAll(repl_markdown.ANSI_DIM);
    var line_one_buf: [256]u8 = undefined;
    const line_one = std.fmt.bufPrint(&line_one_buf, " {s}  •  {s}  •  {s}", .{ leader_palette, leader_model, leader_session }) catch leader_palette;
    var clipped_one_buf: [256]u8 = undefined;
    try writer.writeAll(clipEndInto(clipped_one_buf[0..], line_one, cols));
    if (use_color) try writer.writeAll(repl_markdown.ANSI_RESET);
    row += 1;

    try writer.print("\x1b[{d};1H\x1b[2K", .{row});
    if (use_color) try writer.writeAll(repl_markdown.ANSI_DIM);
    var line_two_buf: [256]u8 = undefined;
    const line_two = std.fmt.bufPrint(&line_two_buf, " {s}  •  {s}  •  {s}", .{ leader_search, leader_tasks, leader_runtime }) catch leader_search;
    var clipped_two_buf: [256]u8 = undefined;
    try writer.writeAll(clipEndInto(clipped_two_buf[0..], line_two, cols));
    if (use_color) try writer.writeAll(repl_markdown.ANSI_RESET);

    return used_rows;
}

fn renderPromptStripOverlay(writer: anytype, cols: usize, input_top_row: usize, options: anytype) !usize {
    if (cols == 0 or input_top_row <= 1) return 0;
    if (!@hasField(@TypeOf(options), "prompt_strip_items")) return 0;

    const items = options.prompt_strip_items;
    if (items.len == 0) return 0;

    const available_rows = input_top_row - 1;
    var used_rows: usize = 0;
    var start_index: usize = items.len;
    while (start_index > 0) {
        const item = items[start_index - 1];
        const needed_rows: usize = if (std.mem.trim(u8, item.body, " \t\r\n").len > 0) 2 else 1;
        if (used_rows + needed_rows > available_rows) break;
        used_rows += needed_rows;
        start_index -= 1;
    }
    if (used_rows == 0) return 0;

    const use_color = repl_markdown.shouldUseColor(options);
    var row_cursor = input_top_row - used_rows;
    const selection: ?usize = if (@hasField(@TypeOf(options), "prompt_strip_selection"))
        options.prompt_strip_selection
    else
        null;
    var idx = start_index;
    while (idx < items.len) : (idx += 1) {
        const item = items[idx];
        const body = std.mem.trim(u8, item.body, " \t\r\n");
        const selected = selection != null and idx == selection.?;
        const prefix = if (selected) "> " else "  ";
        const body_prefix = if (selected) "   " else "    ";

        try writer.print("\x1b[{d};1H\x1b[2K", .{row_cursor});
        if (use_color) {
            if (selected) {
                try writer.writeAll(repl_markdown.promptAnsi(options));
                try writer.writeAll(repl_markdown.ANSI_BOLD);
            } else {
                switch (item.tone) {
                    .accent => try writer.writeAll(repl_markdown.promptAnsi(options)),
                    .dim => try writer.writeAll(repl_markdown.ANSI_DIM),
                    .plain => {},
                }
                try writer.writeAll(repl_markdown.ANSI_BOLD);
            }
        }
        try writer.writeAll(prefix);
        if (item.tag.len > 0) {
            var tag_buf: [32]u8 = undefined;
            const tag = std.fmt.bufPrint(&tag_buf, "[{s}] ", .{item.tag}) catch "";
            const tag_take = @min(tag.len, cols -| prefix.len);
            try writer.writeAll(tag[0..tag_take]);
        }
        var title_buf: [256]u8 = undefined;
        const title = clipEndInto(title_buf[0..], item.title, cols -| prefix.len);
        try writer.writeAll(title);
        if (use_color) try writer.writeAll(repl_markdown.ANSI_RESET);
        row_cursor += 1;

        if (body.len > 0) {
            try writer.print("\x1b[{d};1H\x1b[2K", .{row_cursor});
            if (use_color) try writer.writeAll(repl_markdown.ANSI_DIM);
            try writer.writeAll(body_prefix);
            var body_buf: [256]u8 = undefined;
            const clipped = clipEndInto(body_buf[0..], body, cols -| body_prefix.len);
            try writer.writeAll(clipped);
            if (use_color) try writer.writeAll(repl_markdown.ANSI_RESET);
            row_cursor += 1;
        }
    }

    return used_rows;
}

fn renderFooterRowsOverlay(writer: anytype, cols: usize, input_top_row: usize, options: anytype) !bool {
    if (cols == 0 or input_top_row <= 1) return false;
    if (!@hasField(@TypeOf(options), "footer_rows")) return false;

    const rows = options.footer_rows;
    if (rows.len == 0) return false;

    const use_color = repl_markdown.shouldUseColor(options);
    const available_rows = input_top_row - 1;
    const row_count = @min(rows.len, available_rows);
    if (row_count == 0) return false;

    const selection: ?usize = if (@hasField(@TypeOf(options), "footer_row_selection"))
        options.footer_row_selection
    else
        null;
    const focus_index: usize = if (selection) |selected|
        @min(selected, rows.len - 1)
    else
        rows.len - 1;

    var first_index: usize = if (rows.len > row_count) rows.len - row_count else 0;
    if (focus_index + 1 > row_count) {
        first_index = focus_index + 1 - row_count;
    }
    if (first_index + row_count > rows.len) {
        first_index = rows.len - row_count;
    }

    const first_row = input_top_row - row_count;
    var idx: usize = 0;
    while (idx < row_count) : (idx += 1) {
        const row_index = first_index + idx;
        const row = rows[row_index];
        const screen_row = first_row + idx;
        const selected = selection != null and row_index == selection.?;
        const prefix = if (selected) "> " else "  ";
        var used: usize = prefix.len;

        try writer.print("\x1b[{d};1H\x1b[2K", .{screen_row});
        if (use_color) {
            if (selected) {
                try writer.writeAll(repl_markdown.promptAnsi(options));
            } else {
                switch (row.tone) {
                    .accent => try writer.writeAll(repl_markdown.promptAnsi(options)),
                    .dim => try writer.writeAll(repl_markdown.ANSI_DIM),
                    .plain => {},
                }
            }
        }
        try writer.writeAll(prefix);
        if (use_color and selected) try writer.writeAll(repl_markdown.ANSI_BOLD);

        if (row.tag.len > 0) {
            var tag_buf: [32]u8 = undefined;
            var tag_clip_buf: [32]u8 = undefined;
            const tag = std.fmt.bufPrint(&tag_buf, "[{s}] ", .{row.tag}) catch "";
            const clipped = clipEndInto(tag_clip_buf[0..], tag, cols -| used);
            try writer.writeAll(clipped);
            used += clipped.len;
        }

        var primary_buf: [256]u8 = undefined;
        const primary = clipEndInto(primary_buf[0..], row.primary, cols -| used);
        try writer.writeAll(primary);
        used += primary.len;

        if (use_color) try writer.writeAll(repl_markdown.ANSI_RESET);

        if (row.secondary.len > 0 and cols > used + 3) {
            var secondary_buf: [192]u8 = undefined;
            const secondary = clipEndInto(secondary_buf[0..], row.secondary, cols - used - 3);
            if (secondary.len > 0) {
                if (use_color) try writer.writeAll(repl_markdown.ANSI_DIM);
                try writer.writeAll(" - ");
                try writer.writeAll(secondary);
                if (use_color) try writer.writeAll(repl_markdown.ANSI_RESET);
            }
        }
    }

    return true;
}

fn shouldShowTranscript(options: anytype) bool {
    return if (@hasField(@TypeOf(options), "show_transcript")) options.show_transcript else true;
}

fn renderCollapsedTranscriptPlaceholder(writer: anytype, transcript: *const UiTranscript, cols: usize, options: anytype) !void {
    if (cols == 0) return;

    var line1_buf: [160]u8 = undefined;
    var line2_buf: [128]u8 = undefined;
    const line1 = std.fmt.bufPrint(
        &line1_buf,
        "transcript hidden · {d} lines in scrollback · Ctrl+O to expand",
        .{transcript.lines.items.len},
    ) catch "transcript hidden · Ctrl+O to expand";
    const line2 = std.fmt.bufPrint(
        &line2_buf,
        "Ctrl+T tasks · Ctrl+P files · Ctrl+Shift+F search",
        .{},
    ) catch "Ctrl+T tasks";

    const use_color = repl_markdown.shouldUseColor(options);
    if (use_color) try writer.writeAll(repl_markdown.ANSI_DIM);
    try writer.writeAll(line1[0..@min(line1.len, cols)]);
    if (use_color) try writer.writeAll(repl_markdown.ANSI_RESET);
    try writer.writeByte('\n');

    if (use_color) try writer.writeAll(repl_markdown.ANSI_DIM);
    try writer.writeAll(line2[0..@min(line2.len, cols)]);
    if (use_color) try writer.writeAll(repl_markdown.ANSI_RESET);
    try writer.writeByte('\n');
}

fn formatSlashSuggestionCommand(command: []const u8, out: []u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, command, " ");
    if (trimmed.len == command.len) {
        const take = @min(trimmed.len, out.len);
        if (take > 0) @memcpy(out[0..take], trimmed[0..take]);
        return out[0..take];
    }

    var pos: usize = 0;
    const take = @min(trimmed.len, out.len);
    if (take > 0) {
        @memcpy(out[0..take], trimmed[0..take]);
        pos = take;
    }
    if (pos + figures.ELLIPSIS.len <= out.len) {
        appendLiteral(out, &pos, figures.ELLIPSIS);
    }
    return out[0..pos];
}

fn renderSlashSuggestionOverlay(writer: anytype, input_text: []const u8, cols: usize, input_top_row: usize, selected_index: usize, options: anytype) !void {
    if (cols == 0 or input_top_row <= 1) return;

    const suggestions = repl_input.collectSlashSuggestions(input_text);
    if (suggestions.total_matches == 0) return;

    const use_color = repl_markdown.shouldUseColor(options);
    const available_rows = input_top_row - 1;
    const row_count = @min(@min(repl_input.MAX_SLASH_SUGGESTIONS, suggestions.total_matches), available_rows);
    if (row_count == 0) return;

    const clamped_selected = @min(selected_index, suggestions.total_matches - 1);
    var first_match_index: usize = 0;
    if (clamped_selected + 1 > row_count) {
        first_match_index = clamped_selected + 1 - row_count;
    }
    if (first_match_index + row_count > suggestions.total_matches) {
        first_match_index = suggestions.total_matches - row_count;
    }
    const first_row = input_top_row - row_count;

    var idx: usize = 0;
    while (idx < row_count) : (idx += 1) {
        const match_index = first_match_index + idx;
        const command_full = repl_input.slashSuggestionAt(input_text, match_index) orelse continue;
        const suggestion_row = first_row + idx;
        const selected = match_index == clamped_selected;
        const prefix = if (selected) "> " else "  ";
        var command_buf: [96]u8 = undefined;
        const command = formatSlashSuggestionCommand(command_full, command_buf[0..]);
        const description = repl_help.descriptionForUsagePrefix(command_full) orelse "";

        try writer.print("\x1b[{d};1H\x1b[2K", .{suggestion_row});
        if (use_color) {
            try writer.writeAll(if (selected) repl_markdown.promptAnsi(options) else repl_markdown.ANSI_DIM);
        }
        try writer.writeAll(prefix);
        try writer.writeAll(command);
        if (use_color) try writer.writeAll(repl_markdown.ANSI_RESET);

        const used = prefix.len + command.len;
        if (description.len > 0 and cols > used + 3) {
            var desc_buf: [192]u8 = undefined;
            const clipped_desc = clipEndInto(desc_buf[0..], description, cols - used - 3);
            if (use_color) try writer.writeAll(repl_markdown.ANSI_DIM);
            try writer.writeAll(" - ");
            try writer.writeAll(clipped_desc);
            if (use_color) try writer.writeAll(repl_markdown.ANSI_RESET);
        }
    }
}

fn renderReferenceSuggestionOverlay(writer: anytype, cols: usize, input_top_row: usize, options: anytype) !bool {
    if (cols == 0 or input_top_row <= 1) return false;
    if (!@hasField(@TypeOf(options), "reference_suggestions")) return false;

    const suggestions = options.reference_suggestions;
    if (suggestions.len == 0) return false;

    const use_color = repl_markdown.shouldUseColor(options);
    const available_rows = input_top_row - 1;
    const row_count = @min(suggestions.len, available_rows);
    if (row_count == 0) return false;

    const selection: usize = if (@hasField(@TypeOf(options), "reference_suggestion_selection"))
        @min(@as(usize, options.reference_suggestion_selection), suggestions.len - 1)
    else
        0;

    var first_match_index: usize = 0;
    if (selection + 1 > row_count) {
        first_match_index = selection + 1 - row_count;
    }
    if (first_match_index + row_count > suggestions.len) {
        first_match_index = suggestions.len - row_count;
    }

    const first_row = input_top_row - row_count;
    var idx: usize = 0;
    while (idx < row_count) : (idx += 1) {
        const match_index = first_match_index + idx;
        const suggestion = suggestions[match_index];
        const suggestion_row = first_row + idx;
        const selected = match_index == selection;
        const prefix = if (selected) "> " else "  ";

        try writer.print("\x1b[{d};1H\x1b[2K", .{suggestion_row});
        if (use_color) {
            try writer.writeAll(if (selected) repl_markdown.promptAnsi(options) else repl_markdown.ANSI_DIM);
            if (selected) try writer.writeAll(repl_markdown.ANSI_BOLD);
        }
        try writer.writeAll(prefix);
        try writer.writeByte('@');

        const used = prefix.len + 1;
        var path_buf: [256]u8 = undefined;
        const clipped_path = clipEndInto(path_buf[0..], suggestion.primary, cols -| used);
        try writer.writeAll(clipped_path);
        if (use_color) try writer.writeAll(repl_markdown.ANSI_RESET);
    }

    return true;
}

const CursorPos = struct {
    row: usize,
    col: usize,
};

fn computeMultilineCursorPosition(prompt_label: []const u8, input_text: []const u8, cursor_byte: usize, cols: usize, num_rows: usize) CursorPos {
    if (cols <= 4) return .{ .row = 0, .col = 1 };
    const content_max = cols - 4;
    var content_buf: [16 * 1024]u8 = undefined;
    const content = repl_input.formatInputPreview(prompt_label, input_text, &content_buf);

    // Cursor maps from byte position in input_text to byte position in content (after prompt label + space)
    const prefix_len = prompt_label.len + 1;
    const cursor_in_content = @min(cursor_byte + prefix_len, content.len);

    // Walk through content counting visual rows up to cursor position
    var row: usize = 0;
    var col: usize = 0;
    var i: usize = 0;
    while (i < cursor_in_content) : (i += 1) {
        if (content[i] == '\n') {
            row += 1;
            col = 0;
        } else {
            col += 1;
            if (col >= content_max) {
                row += 1;
                col = 0;
            }
        }
    }

    // Compute total rows in content for tail-view offset
    var total_rows: usize = 1;
    var tcol: usize = 0;
    for (content) |ch| {
        if (ch == '\n') {
            total_rows += 1;
            tcol = 0;
        } else {
            tcol += 1;
            if (tcol >= content_max) {
                total_rows += 1;
                tcol = 0;
            }
        }
    }
    const skip = if (total_rows > num_rows) total_rows - num_rows else 0;
    const visible_row = if (row >= skip) row - skip else 0;
    return .{ .row = visible_row, .col = 3 + col };
}

fn renderTopContextBar(writer: anytype, options: anytype, mode: anytype, cols: usize) !void {
    if (cols == 0) return;

    const ident_result = if (options.status_identity_provider) |provider|
        provider.get(provider.ctx)
    else
        null;
    const identity_provider = if (ident_result) |r| r.provider else options.status_provider;
    const identity_model = if (ident_result) |r| r.model else options.status_model;
    const use_color = repl_markdown.shouldUseColor(options);
    const density_clean = @hasField(@TypeOf(options), "ui_density") and options.ui_density == .clean;

    var line_buf: [1400]u8 = undefined;
    var pos: usize = 0;

    appendBestStatusSegment(&line_buf, &pos, cols, &[_][]const u8{ "zcode", "zc" }, true);

    var mode_buf: [40]u8 = undefined;
    const mode_text = std.fmt.bufPrint(&mode_buf, "{s} {s}", .{ shortModeLabel(mode), if (density_clean) "clean" else "full" }) catch shortModeLabel(mode);
    const mode_candidates = [_][]const u8{ mode_text, shortModeLabel(mode) };
    appendBestStatusSegment(&line_buf, &pos, cols, &mode_candidates, true);

    if (options.status_workspace.len > 0) {
        const workspace_leaf = std.fs.path.basename(options.status_workspace);
        var workspace_buf: [128]u8 = undefined;
        const workspace = if (options.status_branch.len > 0)
            std.fmt.bufPrint(&workspace_buf, "repo {s}@{s}", .{ workspace_leaf, options.status_branch }) catch workspace_leaf
        else
            std.fmt.bufPrint(&workspace_buf, "repo {s}", .{workspace_leaf}) catch workspace_leaf;
        const workspace_candidates = [_][]const u8{ workspace, workspace_leaf };
        appendBestStatusSegment(&line_buf, &pos, cols, &workspace_candidates, false);
    }

    if (identity_model.len > 0) {
        var model_buf: [144]u8 = undefined;
        const model_full = std.fmt.bufPrint(&model_buf, "model {s}/{s}", .{ identity_provider, identity_model }) catch identity_model;
        var model_short_buf: [64]u8 = undefined;
        const model_short = clipMiddleInto(model_short_buf[0..], model_full, if (density_clean) 28 else 40);
        const model_candidates = [_][]const u8{ model_full, model_short, identity_model };
        appendBestStatusSegment(&line_buf, &pos, cols, &model_candidates, true);
    }

    const dynamic = if (@hasField(@TypeOf(options), "status_dynamic_provider")) options.status_dynamic_provider else null;
    const agent_name: []const u8 = blk: {
        if (dynamic) |provider| break :blk provider.get(provider.ctx).agent_name;
        if (@hasField(@TypeOf(options), "status_agent_name")) break :blk options.status_agent_name;
        break :blk "";
    };
    if (agent_name.len > 0) {
        var agent_buf: [64]u8 = undefined;
        const agent_text = std.fmt.bufPrint(&agent_buf, "@{s}", .{agent_name}) catch agent_name;
        appendBestStatusSegment(&line_buf, &pos, cols, &[_][]const u8{ agent_text, agent_name }, false);
    }

    if (!density_clean and options.status_show_safety) {
        var safety_buf: [96]u8 = undefined;
        const safety = std.fmt.bufPrint(&safety_buf, "safety {s}/{s}", .{ options.status_approval_mode, options.status_sandbox }) catch options.status_sandbox;
        appendBestStatusSegment(&line_buf, &pos, cols, &[_][]const u8{ safety, options.status_sandbox }, false);
    }

    if (!density_clean and options.status_show_tokens) {
        var token_wide_buf: [320]u8 = undefined;
        var token_compact_buf: [192]u8 = undefined;
        var token_min_buf: [96]u8 = undefined;
        const token_variants = buildTokenStatusVariants(options, token_wide_buf[0..], token_compact_buf[0..], token_min_buf[0..]);
        appendBestStatusSegment(&line_buf, &pos, cols, &[_][]const u8{token_variants.minimal}, false);
    }

    if (@hasField(@TypeOf(options), "ui_leader_key") and !density_clean) {
        var leader_buf: [48]u8 = undefined;
        const leader = std.fmt.bufPrint(&leader_buf, "palette {s} h", .{options.ui_leader_key}) catch options.ui_leader_key;
        appendBestStatusSegment(&line_buf, &pos, cols, &[_][]const u8{ leader, options.ui_leader_key }, false);
    }

    const line = line_buf[0..pos];
    if (use_color) try writer.writeAll(repl_markdown.statusBgAnsi(options));
    const take = @min(line.len, cols);
    try writer.writeAll(line[0..take]);
    if (cols > take) {
        var i: usize = 0;
        while (i < cols - take) : (i += 1) try writer.writeByte(' ');
    }
    if (use_color) try writer.writeAll(repl_markdown.ANSI_RESET);
}

pub fn renderStatusLine(writer: anytype, options: anytype, mode: anytype, offset: usize, max_off: usize, hint: []const u8, cols: usize) !void {
    const use_color = repl_markdown.shouldUseColor(options);
    const ident_result = if (options.status_identity_provider) |provider|
        provider.get(provider.ctx)
    else
        null;
    const identity_provider = if (ident_result) |r| r.provider else options.status_provider;
    const identity_model = if (ident_result) |r| r.model else options.status_model;
    const runtime_state = deriveRuntimeState(hint);
    const mode_icon = switch (mode) {
        .execution => "\xe2\x96\xb6", // filled right triangle
        .planning => "\xe2\x97\x86", // filled diamond
        .brainstorm => "\xe2\x9c\xa7", // sparkle
        .review => "\xe2\x9a\xa0", // warning sign
    };

    var status_line_buf: [1400]u8 = undefined;
    var status_pos: usize = 0;

    const runtime_full = switch (runtime_state) {
        .running => "\xe2\x97\x8f running",
        .attention => "\xe2\x97\x8f input-needed",
        .waiting => "\xe2\x97\x8f ready",
    };
    const runtime_short = switch (runtime_state) {
        .running => "\xe2\x97\x8f run",
        .attention => "\xe2\x97\x8f input",
        .waiting => "\xe2\x97\x8f ready",
    };
    const runtime_candidates = [_][]const u8{ runtime_full, runtime_short, "\xe2\x97\x8f" };
    appendBestStatusSegment(&status_line_buf, &status_pos, cols, &runtime_candidates, true);

    var version_raw_wide_buf: [48]u8 = undefined;
    var version_raw_compact_buf: [48]u8 = undefined;
    var version_raw_min_buf: [48]u8 = undefined;
    const version_wide = compactVersionForStatus(options.app_version, cols, &version_raw_wide_buf);
    const version_compact = compactVersionForStatus(options.app_version, 84, &version_raw_compact_buf);
    const version_min = compactVersionForStatus(options.app_version, 64, &version_raw_min_buf);
    var version_full_buf: [80]u8 = undefined;
    var version_short_buf: [64]u8 = undefined;
    var version_min_buf: [56]u8 = undefined;
    const version_full = std.fmt.bufPrint(&version_full_buf, "zcode v{s}", .{version_wide}) catch "";
    const version_short = std.fmt.bufPrint(&version_short_buf, "zc v{s}", .{version_compact}) catch "";
    const version_tight = std.fmt.bufPrint(&version_min_buf, "v{s}", .{version_min}) catch "";
    const version_candidates = [_][]const u8{ version_full, version_short, version_tight };
    appendBestStatusSegment(&status_line_buf, &status_pos, cols, &version_candidates, true);

    var mode_full_buf: [40]u8 = undefined;
    var mode_short_buf: [24]u8 = undefined;
    const mode_full = std.fmt.bufPrint(&mode_full_buf, "{s} {s}", .{ mode_icon, modeLabel(mode) }) catch "";
    const mode_short = std.fmt.bufPrint(&mode_short_buf, "{s} {s}", .{ mode_icon, shortModeLabel(mode) }) catch "";
    const mode_candidates = [_][]const u8{ mode_full, mode_short, mode_icon };
    appendBestStatusSegment(&status_line_buf, &status_pos, cols, &mode_candidates, true);

    if (options.status_show_workspace and options.status_workspace.len > 0) {
        var ws_full_buf: [40]u8 = undefined;
        var ws_mid_buf: [24]u8 = undefined;
        const ws_full = formatWorkspaceForStatus(options.status_workspace, ws_full_buf[0..]);
        const ws_mid = formatWorkspaceForStatus(options.status_workspace, ws_mid_buf[0..]);
        const ws_leaf = std.fs.path.basename(options.status_workspace);

        var workspace_full_buf: [96]u8 = undefined;
        var workspace_compact_buf: [72]u8 = undefined;
        const workspace_full = if (options.status_branch.len > 0)
            std.fmt.bufPrint(&workspace_full_buf, "{s} ({s})", .{ ws_full, options.status_branch }) catch ws_full
        else
            ws_full;
        const workspace_compact = if (options.status_branch.len > 0)
            std.fmt.bufPrint(&workspace_compact_buf, "{s} ({s})", .{ ws_leaf, options.status_branch }) catch ws_leaf
        else
            ws_leaf;
        const workspace_candidates = [_][]const u8{ workspace_full, ws_mid, workspace_compact, ws_leaf };
        appendBestStatusSegment(&status_line_buf, &status_pos, cols, &workspace_candidates, false);
    }

    if (options.status_show_model and identity_model.len > 0) {
        var provider_model_buf: [128]u8 = undefined;
        const provider_model = std.fmt.bufPrint(&provider_model_buf, "{s}/{s}", .{ identity_provider, identity_model }) catch identity_model;
        var provider_model_compact_buf: [56]u8 = undefined;
        var model_compact_buf: [40]u8 = undefined;
        const provider_model_compact = clipMiddleInto(provider_model_compact_buf[0..], provider_model, 36);
        const model_compact = clipMiddleInto(model_compact_buf[0..], identity_model, 28);
        const model_candidates = [_][]const u8{ provider_model, identity_model, provider_model_compact, model_compact };
        appendBestStatusSegment(&status_line_buf, &status_pos, cols, &model_candidates, false);
    }

    if (options.status_show_safety) {
        var safety_full_buf: [120]u8 = undefined;
        var safety_compact_buf: [96]u8 = undefined;
        const safety_full = std.fmt.bufPrint(&safety_full_buf, "{s} \xe2\x80\xa2 {s}", .{ options.status_approval_mode, options.status_sandbox }) catch "";
        const safety_compact = std.fmt.bufPrint(&safety_compact_buf, "{s}/{s}", .{ options.status_approval_mode, options.status_sandbox }) catch "";
        const safety_candidates = [_][]const u8{ safety_full, safety_compact, options.status_sandbox, options.status_approval_mode };
        appendBestStatusSegment(&status_line_buf, &status_pos, cols, &safety_candidates, false);
    }

    if (options.status_show_tokens) {
        var token_wide_buf: [320]u8 = undefined;
        var token_compact_buf: [192]u8 = undefined;
        var token_min_buf: [96]u8 = undefined;
        const token_variants = buildTokenStatusVariants(options, token_wide_buf[0..], token_compact_buf[0..], token_min_buf[0..]);
        const token_candidates = [_][]const u8{ token_variants.wide, token_variants.compact, token_variants.minimal };
        appendBestStatusSegment(&status_line_buf, &status_pos, cols, &token_candidates, false);
    }

    // Resolve the dynamic chips. Prefer a live provider callback
    // when set so values reflect the current turn's state; fall back
    // to the static fields on the options struct so tests and
    // one-shots that know the values at construction time still work.
    const cb_state: []const u8 = blk: {
        if (@hasField(@TypeOf(options), "status_dynamic_provider")) {
            if (options.status_dynamic_provider) |p| break :blk p.get(p.ctx).circuit_state;
        }
        if (@hasField(@TypeOf(options), "status_circuit_state")) break :blk options.status_circuit_state;
        break :blk "";
    };
    const agent_name: []const u8 = blk: {
        if (@hasField(@TypeOf(options), "status_dynamic_provider")) {
            if (options.status_dynamic_provider) |p| break :blk p.get(p.ctx).agent_name;
        }
        if (@hasField(@TypeOf(options), "status_agent_name")) break :blk options.status_agent_name;
        break :blk "";
    };

    if (cb_state.len > 0 and !std.mem.eql(u8, cb_state, "closed")) {
        var cb_full_buf: [32]u8 = undefined;
        var cb_short_buf: [20]u8 = undefined;
        const cb_full = std.fmt.bufPrint(&cb_full_buf, "cb {s}", .{cb_state}) catch cb_state;
        const cb_short = std.fmt.bufPrint(&cb_short_buf, "cb:{s}", .{cb_state}) catch cb_state;
        const cb_candidates = [_][]const u8{ cb_full, cb_short, cb_state };
        appendBestStatusSegment(&status_line_buf, &status_pos, cols, &cb_candidates, false);
    }
    if (agent_name.len > 0) {
        var agent_full_buf: [48]u8 = undefined;
        const agent_full = std.fmt.bufPrint(&agent_full_buf, "@{s}", .{agent_name}) catch agent_name;
        const agent_candidates = [_][]const u8{ agent_full, agent_name };
        appendBestStatusSegment(&status_line_buf, &status_pos, cols, &agent_candidates, false);
    }

    if (options.show_scroll_hint and offset > 0) {
        var scroll_full_buf: [32]u8 = undefined;
        var scroll_short_buf: [20]u8 = undefined;
        const scroll_full = std.fmt.bufPrint(&scroll_full_buf, "\xe2\x86\x95 {d}/{d}", .{ offset, max_off }) catch "";
        const scroll_short = std.fmt.bufPrint(&scroll_short_buf, "\xe2\x86\x95 {d}", .{offset}) catch "";
        const scroll_candidates = [_][]const u8{ scroll_full, scroll_short, "\xe2\x86\x95" };
        appendBestStatusSegment(&status_line_buf, &status_pos, cols, &scroll_candidates, false);
    }

    if (options.status_show_hint and hint.len > 0) {
        var hint_compact_buf: [96]u8 = undefined;
        var hint_min_buf: [56]u8 = undefined;
        const hint_compact = clipEndInto(hint_compact_buf[0..], hint, 72);
        const hint_min = clipEndInto(hint_min_buf[0..], hint, 40);
        const hint_candidates = [_][]const u8{ hint, hint_compact, hint_min };
        appendBestStatusSegment(&status_line_buf, &status_pos, cols, &hint_candidates, false);
    }

    const status = status_line_buf[0..status_pos];

    // Render with inverted background if color is enabled.
    if (use_color) try writer.writeAll(repl_markdown.statusBgAnsi(options));
    const take = @min(status.len, cols);
    try writer.writeAll(status[0..take]);
    if (cols > take) {
        const pad = cols - take;
        var i: usize = 0;
        while (i < pad) : (i += 1) {
            try writer.writeByte(' ');
        }
    }
    if (use_color) try writer.writeAll(repl_markdown.ANSI_RESET);
}

fn writeTranscriptDivider(writer: anytype, label: []const u8, cols: usize, options: anytype) !void {
    const use_color = repl_markdown.shouldUseColor(options);
    const tone = dividerToneFromLabel(label);

    // Role-specific icons: keep the transcript scannable without
    // repeating the role name in noisy chrome.
    const role_icon = if (repl_markdown.containsIgnoreCase(label, "You"))
        "\xe2\x9d\xaf " // ❯
    else if (repl_markdown.containsIgnoreCase(label, "Assistant"))
        figures.BLACK_DIAMOND ++ " "
    else
        "";

    var label_buf: [80]u8 = undefined;
    const display_label = clipEndInto(label_buf[0..], if (label.len > 0) label else "Section", if (cols > 10) cols - 6 else 4);

    if (isCleanDensity(options)) {
        if (use_color) try writer.writeAll(if (tone == .neutral) repl_markdown.ANSI_DIM else dividerToneAnsi(options, tone));
        if (role_icon.len > 0) {
            try writer.writeAll(role_icon);
        } else {
            try writer.writeAll("\xe2\x80\xa2 ");
        }
        if (use_color) try writer.writeAll(repl_markdown.ANSI_BOLD);
        try writer.writeAll(display_label);
        if (use_color) try writer.writeAll(repl_markdown.ANSI_RESET);
        return;
    }

    const icon_width: usize = if (role_icon.len > 0) 2 else 0; // visible icon + space
    const used_cols: usize = 5 + icon_width + display_label.len;
    const fill_cols: usize = if (cols > used_cols) cols - used_cols else 0;

    if (use_color) try writer.writeAll(if (tone == .neutral) repl_markdown.ANSI_DIM else dividerToneAnsi(options, tone));
    try writer.writeAll(repl_markdown.BOX_TL);
    try writer.writeAll(repl_markdown.BOX_H);
    try writer.writeByte(' ');
    if (use_color) {
        try writer.writeAll(repl_markdown.ANSI_RESET);
        if (tone != .neutral) try writer.writeAll(dividerToneAnsi(options, tone));
    }
    if (role_icon.len > 0) try writer.writeAll(role_icon);
    if (use_color) try writer.writeAll(repl_markdown.ANSI_BOLD);
    try writer.writeAll(display_label);
    if (use_color) {
        try writer.writeAll(repl_markdown.ANSI_RESET);
        try writer.writeAll(if (tone == .neutral) repl_markdown.ANSI_DIM else dividerToneAnsi(options, tone));
    }
    try writer.writeByte(' ');
    var i: usize = 0;
    while (i < fill_cols) : (i += 1) {
        try writer.writeAll(repl_markdown.BOX_H);
    }
    if (use_color) try writer.writeAll(repl_markdown.ANSI_RESET);
}

const STATUS_SEGMENT_SEPARATOR = "  " ++ figures.BULLET_OPERATOR ++ "  ";

const TokenStatusVariants = struct {
    wide: []const u8 = "",
    compact: []const u8 = "",
    minimal: []const u8 = "",
};

fn shortModeLabel(mode: anytype) []const u8 {
    return switch (mode) {
        .execution => "exec",
        .planning => "plan",
        .brainstorm => "ideas",
        .review => "review",
    };
}

/// Distinct hue per composer mode so the active mode is glance-able
/// from the top border. Colors sit in the existing 256-color palette
/// alongside the markdown highlight tones.
fn modeColorAnsi(mode: anytype) []const u8 {
    return switch (mode) {
        .execution => "\x1b[38;5;150m", // soft green   - go
        .planning => "\x1b[38;5;180m", // soft amber   - think
        .brainstorm => "\x1b[38;5;117m", // soft cyan    - explore
        .review => "\x1b[38;5;176m", // soft purple  - audit
    };
}

fn tryAppendStatusSegment(buf: []u8, pos: *usize, cols: usize, text: []const u8) bool {
    if (text.len == 0) return false;
    const limit = @min(cols, buf.len);
    const sep = if (pos.* > 0) STATUS_SEGMENT_SEPARATOR else "";
    if (pos.* + sep.len + text.len > limit) return false;
    if (sep.len > 0) appendLiteral(buf, pos, sep);
    appendLiteral(buf, pos, text);
    return true;
}

fn forceAppendStatusSegment(buf: []u8, pos: *usize, cols: usize, text: []const u8) void {
    if (text.len == 0) return;
    const limit = @min(cols, buf.len);
    if (limit <= pos.*) return;
    if (pos.* > 0) {
        if (pos.* + STATUS_SEGMENT_SEPARATOR.len > limit) return;
        appendLiteral(buf, pos, STATUS_SEGMENT_SEPARATOR);
    }
    if (limit <= pos.*) return;
    const take = @min(text.len, limit - pos.*);
    appendLiteral(buf, pos, text[0..take]);
}

fn appendBestStatusSegment(buf: []u8, pos: *usize, cols: usize, candidates: []const []const u8, required: bool) void {
    for (candidates) |candidate| {
        if (tryAppendStatusSegment(buf, pos, cols, candidate)) return;
    }
    if (required and candidates.len > 0) {
        forceAppendStatusSegment(buf, pos, cols, candidates[candidates.len - 1]);
    }
}

fn clipMiddleInto(out: []u8, text: []const u8, max_len: usize) []const u8 {
    if (out.len == 0 or max_len == 0) return "";
    const safe_max = @min(max_len, out.len);
    if (text.len <= safe_max or safe_max < 4) {
        const take = @min(text.len, safe_max);
        @memcpy(out[0..take], text[0..take]);
        return out[0..take];
    }

    const keep = safe_max - 3;
    const left = keep / 2;
    const right = keep - left;
    @memcpy(out[0..left], text[0..left]);
    @memcpy(out[left .. left + 3], "...");
    @memcpy(out[left + 3 .. left + 3 + right], text[text.len - right ..]);
    return out[0 .. left + 3 + right];
}

fn clipEndInto(out: []u8, text: []const u8, max_len: usize) []const u8 {
    if (out.len == 0 or max_len == 0) return "";
    const safe_max = @min(max_len, out.len);
    if (text.len <= safe_max or safe_max < 4) {
        const take = @min(text.len, safe_max);
        @memcpy(out[0..take], text[0..take]);
        return out[0..take];
    }

    const keep = safe_max - 3;
    @memcpy(out[0..keep], text[0..keep]);
    @memcpy(out[keep .. keep + 3], "...");
    return out[0..safe_max];
}

fn buildTokenStatusVariants(options: anytype, wide_out: []u8, compact_out: []u8, minimal_out: []u8) TokenStatusVariants {
    const provider = options.status_metrics_provider orelse return .{};
    const metrics = provider.get(provider.ctx);

    var prompt_buf: [16]u8 = undefined;
    var in_buf: [16]u8 = undefined;
    var out_buf: [16]u8 = undefined;
    var total_in_buf: [16]u8 = undefined;
    var total_out_buf: [16]u8 = undefined;
    var cost_buf: [16]u8 = undefined;
    var ctx_pct_buf: [12]u8 = undefined;

    const ctx_base = if (metrics.last_budget_input > 0)
        metrics.last_budget_input
    else if (options.status_model_context_window > 0)
        options.status_model_context_window
    else
        0;
    const ctx_pct = if (ctx_base > 0 and metrics.last_prompt_tokens > 0)
        @min(@as(usize, 999), (metrics.last_prompt_tokens * 100) / ctx_base)
    else
        0;
    const ctx_segment = if (ctx_pct > 0)
        std.fmt.bufPrint(&ctx_pct_buf, "ctx {d}%", .{ctx_pct}) catch ""
    else
        "";
    const cost_str = if (metrics.estimated_session_cost_cents > 0)
        formatCostCompact(&cost_buf, metrics.estimated_session_cost_cents)
    else
        "";

    const last_in = formatCountCompact(&in_buf, metrics.last_input_tokens);
    const last_out = formatCountCompact(&out_buf, metrics.last_output_tokens);
    const total_in = formatCountCompact(&total_in_buf, metrics.total_input_tokens);
    const total_out = formatCountCompact(&total_out_buf, metrics.total_output_tokens);
    const prompt = formatCountCompact(&prompt_buf, metrics.last_prompt_tokens);

    const wide = if (cost_str.len > 0)
        if (ctx_segment.len > 0)
            std.fmt.bufPrint(wide_out, "{s}  \xe2\x96\xb2 {s}/{s}  \xe2\x88\x91 {s}/{s}  p~{s}  {s}", .{
                ctx_segment,
                last_in,
                last_out,
                total_in,
                total_out,
                prompt,
                cost_str,
            }) catch ""
        else
            std.fmt.bufPrint(wide_out, "\xe2\x96\xb2 {s}/{s}  \xe2\x88\x91 {s}/{s}  p~{s}  {s}", .{
                last_in,
                last_out,
                total_in,
                total_out,
                prompt,
                cost_str,
            }) catch ""
    else if (ctx_segment.len > 0)
        std.fmt.bufPrint(wide_out, "{s}  \xe2\x96\xb2 {s}/{s}  \xe2\x88\x91 {s}/{s}  p~{s}", .{
            ctx_segment,
            last_in,
            last_out,
            total_in,
            total_out,
            prompt,
        }) catch ""
    else
        std.fmt.bufPrint(wide_out, "\xe2\x96\xb2 {s}/{s}  \xe2\x88\x91 {s}/{s}  p~{s}", .{
            last_in,
            last_out,
            total_in,
            total_out,
            prompt,
        }) catch "";

    const compact = if (cost_str.len > 0)
        if (ctx_segment.len > 0)
            std.fmt.bufPrint(compact_out, "{s}  \xe2\x96\xb2 {s}/{s}  \xe2\x88\x91 {s}/{s}  {s}", .{
                ctx_segment,
                last_in,
                last_out,
                total_in,
                total_out,
                cost_str,
            }) catch ""
        else
            std.fmt.bufPrint(compact_out, "\xe2\x96\xb2 {s}/{s}  \xe2\x88\x91 {s}/{s}  {s}", .{
                last_in,
                last_out,
                total_in,
                total_out,
                cost_str,
            }) catch ""
    else if (ctx_segment.len > 0)
        std.fmt.bufPrint(compact_out, "{s}  \xe2\x88\x91 {s}/{s}", .{
            ctx_segment,
            total_in,
            total_out,
        }) catch ""
    else
        std.fmt.bufPrint(compact_out, "\xe2\x88\x91 {s}/{s}", .{
            total_in,
            total_out,
        }) catch "";

    const minimal = if (cost_str.len > 0)
        std.fmt.bufPrint(minimal_out, "\xe2\x88\x91 {s}/{s} {s}", .{ total_in, total_out, cost_str }) catch ""
    else if (ctx_segment.len > 0)
        std.fmt.bufPrint(minimal_out, "\xe2\x88\x91 {s}/{s} {s}", .{ total_in, total_out, ctx_segment }) catch ""
    else
        std.fmt.bufPrint(minimal_out, "\xe2\x88\x91 {s}/{s}", .{ total_in, total_out }) catch "";

    return .{
        .wide = wide,
        .compact = compact,
        .minimal = minimal,
    };
}

pub fn compactVersionForStatus(version: []const u8, cols: usize, out_raw: []u8) []const u8 {
    var v = version;
    if (cols < 100 and std.mem.endsWith(u8, v, ".dirty")) {
        v = v[0 .. v.len - ".dirty".len];
    }
    if (cols < 84) {
        if (std.mem.indexOfScalar(u8, v, '+')) |plus_idx| {
            const hash_len = v.len - (plus_idx + 1);
            if (hash_len > 8) {
                const keep = plus_idx + 1 + 8;
                v = v[0..keep];
            }
        }
    }
    const take = @min(v.len, out_raw.len);
    if (take > 0) {
        @memcpy(out_raw[0..take], v[0..take]);
    }
    return out_raw[0..take];
}

pub const RuntimeState = enum {
    running,
    waiting,
    attention,
};

pub fn deriveRuntimeState(hint: []const u8) RuntimeState {
    if (hint.len == 0) return .waiting;
    if (std.mem.indexOf(u8, hint, "running:") != null) return .running;
    if (std.mem.indexOf(u8, hint, "input") != null) return .attention;
    if (std.mem.indexOf(u8, hint, "awaiting") != null) return .attention;
    return .waiting;
}

pub fn formatWorkspaceForStatus(path: []const u8, out: []u8) []const u8 {
    if (path.len == 0 or out.len == 0) return "";
    const max_cols = out.len;
    if (path.len <= max_cols) {
        const take = @min(path.len, out.len);
        @memcpy(out[0..take], path[0..take]);
        return out[0..take];
    }

    const lead = "...";
    if (out.len <= lead.len) {
        const take = @min(path.len, out.len);
        @memcpy(out[0..take], path[path.len - take ..]);
        return out[0..take];
    }

    const tail_len = out.len - lead.len;
    @memcpy(out[0..lead.len], lead);
    @memcpy(out[lead.len .. lead.len + tail_len], path[path.len - tail_len ..]);
    return out[0 .. lead.len + tail_len];
}

pub fn formatCountCompact(out: []u8, value: usize) []const u8 {
    if (value < 1_000) {
        return std.fmt.bufPrint(out, "{d}", .{value}) catch "0";
    }
    if (value < 1_000_000) {
        const whole = value / 1_000;
        const tenth = (value % 1_000) / 100;
        return std.fmt.bufPrint(out, "{d}.{d}k", .{ whole, tenth }) catch "0";
    }
    const whole_m = value / 1_000_000;
    const tenth_m = (value % 1_000_000) / 100_000;
    return std.fmt.bufPrint(out, "{d}.{d}m", .{ whole_m, tenth_m }) catch "0";
}

pub fn formatCostCompact(out: []u8, cents: usize) []const u8 {
    if (cents == 0) return "";
    if (cents < 100) {
        return std.fmt.bufPrint(out, "${d}.{d:0>2}", .{ cents / 100, cents % 100 }) catch "$0";
    }
    const dollars = cents / 100;
    const remainder = cents % 100;
    return std.fmt.bufPrint(out, "${d}.{d:0>2}", .{ dollars, remainder }) catch "$0";
}

pub fn renderHorizontalBorder(writer: anytype, cols: usize) !void {
    if (cols < 2) {
        try writer.writeAll(repl_markdown.BOX_H);
        return;
    }

    try writer.writeAll(repl_markdown.ANSI_DIM);
    try writer.writeAll(repl_markdown.BOX_H);
    var i: usize = 1;
    while (i + 1 < cols) : (i += 1) {
        try writer.writeAll(repl_markdown.BOX_H);
    }
    try writer.writeAll(repl_markdown.BOX_H);
    try writer.writeAll(repl_markdown.ANSI_RESET);
}

fn renderComposerBorder(writer: anytype, cols: usize, top: bool, mode: anytype, options: anytype) !void {
    if (cols == 0) return;
    if (cols < 4) return renderHorizontalBorder(writer, cols);

    const use_color = repl_markdown.shouldUseColor(options);
    const left = if (top) repl_markdown.BOX_TL else repl_markdown.BOX_BL;
    const right = if (top) repl_markdown.BOX_TR else repl_markdown.BOX_BR;

    var label_buf: [160]u8 = undefined;
    const mode_word = shortModeLabel(mode);
    const label = if (top)
        std.fmt.bufPrint(&label_buf, " ask zcode  {s} ", .{mode_word}) catch " ask zcode "
    else if (@hasField(@TypeOf(options), "ui_leader_key"))
        std.fmt.bufPrint(&label_buf, " Enter submit  Shift+Enter newline  ? shortcuts  {s} h palette ", .{options.ui_leader_key}) catch " Enter submit "
    else
        " Enter submit  Shift+Enter newline  ? shortcuts ";

    const show_label = cols > label.len + 4;
    const label_cols = if (show_label) label.len else 0;
    const fill_cols = cols - 2 - label_cols;
    const label_pad: usize = @min(@as(usize, 2), fill_cols);
    const left_fill = if (!show_label) fill_cols else if (top) label_pad else fill_cols - label_pad;
    const right_fill = fill_cols - left_fill;

    // Width math above used the plain label, so emitting ANSI here
    // doesn't shift the border fill.
    const mode_at: ?usize = if (top and use_color) std.mem.indexOf(u8, label, mode_word) else null;

    if (use_color) try writer.writeAll(if (top) repl_markdown.promptAnsi(options) else repl_markdown.ANSI_DIM);
    try writer.writeAll(left);
    var i: usize = 0;
    while (i < left_fill) : (i += 1) try writer.writeAll(repl_markdown.BOX_H);
    if (show_label) {
        if (use_color) {
            try writer.writeAll(repl_markdown.ANSI_RESET);
            try writer.writeAll(if (top) repl_markdown.promptAnsi(options) else repl_markdown.ANSI_DIM);
        }
        if (mode_at) |at| {
            try writer.writeAll(label[0..at]);
            try writer.writeAll(repl_markdown.ANSI_BOLD);
            try writer.writeAll(modeColorAnsi(mode));
            try writer.writeAll(mode_word);
            try writer.writeAll(repl_markdown.ANSI_RESET);
            try writer.writeAll(repl_markdown.promptAnsi(options));
            try writer.writeAll(label[at + mode_word.len ..]);
        } else {
            try writer.writeAll(label);
        }
        if (use_color) try writer.writeAll(if (top) repl_markdown.promptAnsi(options) else repl_markdown.ANSI_DIM);
    }
    i = 0;
    while (i < right_fill) : (i += 1) try writer.writeAll(repl_markdown.BOX_H);
    try writer.writeAll(right);
    if (use_color) try writer.writeAll(repl_markdown.ANSI_RESET);
}

const InputHighlightKind = enum {
    plain,
    prompt,
    slash,
    mention,
    attachment,
};

const VisibleInputRow = struct {
    chunk: []const u8,
    start_offset: usize,
};

fn inputLineDataStart(content: []const u8, prompt_label_len: usize, idx: usize) usize {
    if (content.len == 0) return 0;
    var start = @min(idx, content.len);
    while (start > 0 and content[start - 1] != '\n') : (start -= 1) {}
    if (start == 0) return @min(prompt_label_len + 1, content.len);
    return start;
}

fn tokenStart(content: []const u8, idx: usize) usize {
    var start = @min(idx, content.len);
    while (start > 0 and content[start - 1] != '\n' and !std.ascii.isWhitespace(content[start - 1])) : (start -= 1) {}
    return start;
}

fn tokenEnd(content: []const u8, idx: usize) usize {
    var end = @min(idx, content.len);
    while (end < content.len and content[end] != '\n' and !std.ascii.isWhitespace(content[end])) : (end += 1) {}
    return end;
}

fn classifyInputHighlightByte(content: []const u8, idx: usize, prompt_label_len: usize) InputHighlightKind {
    if (idx >= content.len) return .plain;
    if (idx < prompt_label_len) return .prompt;

    const start = tokenStart(content, idx);
    const end = tokenEnd(content, start);
    if (repl_attachments.tokenAt(content, idx)) |_| {
        if (idx < end) return .attachment;
    }
    if (end > start + 1 and content[start] == '@' and idx < end) return .mention;

    const line_start = inputLineDataStart(content, prompt_label_len, idx);
    const slash_end = tokenEnd(content, line_start);
    if (slash_end > line_start and line_start < content.len and content[line_start] == '/' and idx >= line_start and idx < slash_end) {
        return .slash;
    }

    return .plain;
}

fn renderAttachmentDisplayChunk(
    writer: anytype,
    content: []const u8,
    start_offset: usize,
    chunk: []const u8,
    options: anytype,
) !void {
    if (chunk.len == 0) return;

    const use_color = repl_markdown.shouldUseColor(options);
    var consumed: usize = 0;
    while (consumed < chunk.len) {
        const absolute_idx = start_offset + consumed;
        const token = repl_attachments.tokenAt(content, absolute_idx) orelse {
            try writer.writeAll(chunk[consumed .. consumed + 1]);
            consumed += 1;
            continue;
        };

        var display_buf: [256]u8 = undefined;
        const ordinal = repl_attachments.ordinalForToken(content, token.start, token.kind);
        const attachment_store = if (@hasField(@TypeOf(options), "attachment_store")) options.attachment_store else null;
        const display = repl_attachments.formatDisplayToken(content[token.start..token.end], token, attachment_store, ordinal, display_buf[0..]);
        const local_start = absolute_idx - token.start;
        const available = @min(chunk.len - consumed, token.end - absolute_idx);
        const local_end = @min(local_start + available, display.len);

        if (use_color) {
            try writer.writeAll(repl_markdown.pathAnsi(options));
            try writer.writeAll(repl_markdown.ANSI_BOLD);
        }
        try writer.writeAll(display[local_start..local_end]);
        if (use_color) try writer.writeAll(repl_markdown.ANSI_RESET);
        consumed += local_end - local_start;
    }
}

fn renderStyledInputChunk(
    writer: anytype,
    content: []const u8,
    start_offset: usize,
    chunk: []const u8,
    prompt_label_len: usize,
    options: anytype,
) !void {
    if (chunk.len == 0) return;
    const use_color = repl_markdown.shouldUseColor(options);

    var i: usize = 0;
    while (i < chunk.len) {
        const kind = classifyInputHighlightByte(content, start_offset + i, prompt_label_len);
        var end = i + 1;
        while (end < chunk.len and classifyInputHighlightByte(content, start_offset + end, prompt_label_len) == kind) : (end += 1) {}

        if (use_color) switch (kind) {
            .prompt => try writer.writeAll(repl_markdown.promptAnsi(options)),
            .slash => {
                try writer.writeAll(repl_markdown.promptAnsi(options));
                try writer.writeAll(repl_markdown.ANSI_BOLD);
            },
            .mention => {
                try writer.writeAll(repl_markdown.pathAnsi(options));
                try writer.writeAll(repl_markdown.ANSI_BOLD);
            },
            .attachment => {},
            .plain => {},
        };
        if (kind == .attachment) {
            try renderAttachmentDisplayChunk(writer, content, start_offset + i, chunk[i..end], options);
        } else {
            try writer.writeAll(chunk[i..end]);
            if (use_color and kind != .plain) try writer.writeAll(repl_markdown.ANSI_RESET);
        }
        i = end;
    }
}

fn renderMultiLineInput(writer: anytype, prompt_label: []const u8, input_text: []const u8, cols: usize, first_row: usize, num_rows: usize, show_placeholder: bool, options: anytype) !void {
    const content_max: usize = if (cols > 4) cols - 4 else 1;
    var content_buf: [16 * 1024]u8 = undefined;
    const content = repl_input.formatInputPreview(prompt_label, input_text, &content_buf);

    // Build visual rows from content: split on newlines and wrap long
    // lines. The previous implementation used a fixed [64]slice buffer
    // and silently dropped any visual row past the 64th, which truncated
    // large pastes in the input panel. Now we do a first pass to count
    // rows, compute skip = total - num_rows, and a second pass to render
    // only the tail. No fixed cap on how much content we accept.

    // --- Pass 1: count visual rows ---
    var visual_count: usize = 0;
    {
        var line_start: usize = 0;
        var i: usize = 0;
        while (i <= content.len) {
            if (i == content.len or content[i] == '\n') {
                const segment = content[line_start..i];
                if (segment.len == 0) {
                    visual_count += 1;
                } else {
                    var seg_pos: usize = 0;
                    while (seg_pos < segment.len) {
                        const end = @min(seg_pos + content_max, segment.len);
                        visual_count += 1;
                        seg_pos = end;
                    }
                }
                line_start = i + 1;
            }
            i += 1;
        }
        if (visual_count == 0) visual_count = 1;
    }

    // Show the last num_rows visual rows (tail view)
    const skip = if (visual_count > num_rows) visual_count - num_rows else 0;

    // --- Pass 2: build only the visible window into a bounded buffer ---
    // The visible window is `num_rows` (typically 3-6), so a small fixed
    // buffer is safe here regardless of input length.
    var visual_rows: [64]VisibleInputRow = undefined;
    const window_cap = @min(num_rows, visual_rows.len);
    var visible_count: usize = 0;
    {
        var row_index: usize = 0;
        var line_start: usize = 0;
        var i: usize = 0;
        while (i <= content.len and visible_count < window_cap) {
            if (i == content.len or content[i] == '\n') {
                const segment = content[line_start..i];
                if (segment.len == 0) {
                    if (row_index >= skip) {
                        visual_rows[visible_count] = .{ .chunk = "", .start_offset = i };
                        visible_count += 1;
                    }
                    row_index += 1;
                } else {
                    var seg_pos: usize = 0;
                    while (seg_pos < segment.len and visible_count < window_cap) {
                        const end = @min(seg_pos + content_max, segment.len);
                        if (row_index >= skip) {
                            visual_rows[visible_count] = .{
                                .chunk = segment[seg_pos..end],
                                .start_offset = line_start + seg_pos,
                            };
                            visible_count += 1;
                        }
                        row_index += 1;
                        seg_pos = end;
                    }
                }
                line_start = i + 1;
            }
            i += 1;
        }
        if (visible_count == 0) {
            visual_rows[0] = .{ .chunk = "", .start_offset = 0 };
            visible_count = 1;
        }
    }

    var row: usize = 0;
    const suggestion_text = if (@hasField(@TypeOf(options), "prompt_suggestion") and options.prompt_suggestion.len > 0)
        options.prompt_suggestion
    else
        "";
    const placeholder_text = if (suggestion_text.len > 0)
        suggestion_text
    else if (@hasField(@TypeOf(options), "prompt_placeholder") and options.prompt_placeholder.len > 0)
        options.prompt_placeholder
    else
        PROMPT_PLACEHOLDER;
    const inline_ghost_text = if (@hasField(@TypeOf(options), "inline_ghost_text") and options.inline_ghost_text.len > 0)
        options.inline_ghost_text
    else
        "";
    while (row < num_rows) : (row += 1) {
        try writer.print("\x1b[{d};1H\x1b[2K", .{first_row + row});
        try writer.writeAll(repl_markdown.ANSI_DIM);
        try writer.writeAll(repl_markdown.BOX_V);
        try writer.writeAll(repl_markdown.ANSI_RESET);
        try writer.writeByte(' ');

        if (row < visible_count) {
            const row_info = visual_rows[row];
            const chunk = row_info.chunk;
            var rendered_len = chunk.len;
            if (row == 0 and skip == 0 and chunk.len >= prompt_label.len) {
                try renderStyledInputChunk(writer, content, row_info.start_offset, chunk, prompt_label.len, options);
                if (show_placeholder and input_text.len == 0) {
                    const room = content_max -| chunk.len;
                    if (room > 0) {
                        var placeholder_buf: [96]u8 = undefined;
                        const placeholder = clipEndInto(placeholder_buf[0..], placeholder_text, room);
                        try writer.writeAll(repl_markdown.ANSI_DIM);
                        try writer.writeAll(placeholder);
                        try writer.writeAll(repl_markdown.ANSI_RESET);
                        rendered_len += placeholder.len;
                    }
                }
            } else if (row == 0 and skip > 0) {
                try writer.writeAll(repl_markdown.ANSI_DIM);
                try writer.writeAll(figures.ELLIPSIS);
                try writer.writeAll(repl_markdown.ANSI_RESET);
                if (chunk.len > 1) try renderStyledInputChunk(writer, content, row_info.start_offset + 1, chunk[1..], prompt_label.len, options);
                rendered_len = chunk.len;
            } else {
                try renderStyledInputChunk(writer, content, row_info.start_offset, chunk, prompt_label.len, options);
                rendered_len = chunk.len;
            }
            if (inline_ghost_text.len > 0 and row + 1 == visible_count and input_text.len > 0) {
                const room = content_max -| rendered_len;
                if (room > 0) {
                    var ghost_buf: [128]u8 = undefined;
                    const ghost = clipEndInto(ghost_buf[0..], inline_ghost_text, room);
                    if (ghost.len > 0) {
                        try writer.writeAll(repl_markdown.ANSI_DIM);
                        try writer.writeAll(ghost);
                        try writer.writeAll(repl_markdown.ANSI_RESET);
                        rendered_len += ghost.len;
                    }
                }
            }
            var pad = content_max -| rendered_len;
            while (pad > 0) : (pad -= 1) try writer.writeByte(' ');
        } else {
            var pad = content_max;
            while (pad > 0) : (pad -= 1) try writer.writeByte(' ');
        }

        try writer.writeByte(' ');
        try writer.writeAll(repl_markdown.ANSI_DIM);
        try writer.writeAll(repl_markdown.BOX_V);
        try writer.writeAll(repl_markdown.ANSI_RESET);
    }
}

fn inputCursorColumnMultiLine(prompt_label: []const u8, input_text: []const u8, cols: usize) usize {
    if (cols <= 4) return 1;
    const content_max = cols - 4;
    var content_buf: [16 * 1024]u8 = undefined;
    const content = repl_input.formatInputPreview(prompt_label, input_text, &content_buf);
    // Find the last line (after last newline) and compute cursor column within it
    var last_line_start: usize = 0;
    for (content, 0..) |ch, idx| {
        if (ch == '\n') last_line_start = idx + 1;
    }
    const last_line_len = content.len - last_line_start;
    const col_in_line = last_line_len % content_max;
    const pos = if (col_in_line == 0 and last_line_len > 0) content_max else col_in_line;
    return 3 + pos;
}

pub fn modeLabel(mode: anytype) []const u8 {
    return switch (mode) {
        .execution => "execution",
        .planning => "planning",
        .brainstorm => "brainstorm",
        .review => "review",
    };
}

pub fn enterAltScreen(writer: anytype) !void {
    // Mouse-mode policy mirrors claude-code-main/src/ink/termio/dec.ts
    // ENABLE_MOUSE_TRACKING: 1000 (button press/release/wheel) +
    // 1002 (drag motion) + 1006 (SGR encoding). The reference
    // additionally enables 1003 (all motion / hover) for hover-style
    // interactions; we omit it -- we don't render hover state and
    // 1003 produces a stream of motion events even when no button
    // is pressed, eating CPU on every cursor move.
    //
    // With these modes on, click+drag goes to the app instead of
    // the OS-level selection. Users select text with the terminal's
    // bypass modifier (Option-drag on macOS / iTerm2 / Ghostty /
    // Terminal.app, Shift-drag on most Linux terminals) -- documented
    // in --help under "TUI tips". Wheel events come through as
    // SGR-mouse btn=64/65 and feed the spinner-thread scroll handler,
    // which is rate-limited to ~60fps to prevent burst stalls.
    //
    // ?2004 enables bracketed paste so multi-line clipboard content
    // arrives as one event.
    try writer.writeAll("\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?1015l\x1b[?1007l\x1b[?2004h\x1b[?1049h\x1b[2J\x1b[H\x1b[?1000h\x1b[?1002h\x1b[?1006h");
}

pub fn leaveAltScreen(writer: anytype) !void {
    try writer.writeAll("\x1b[?1006l\x1b[?1002l\x1b[?1000l\x1b[?2004l\x1b[?1007l\x1b[?1049l");
}

pub fn renderFriendlyError(out: []u8, err: anyerror, options: anytype) []const u8 {
    const prefix = "\xe2\x9c\x97 "; // cross mark
    return switch (err) {
        error.HttpTransport => std.fmt.bufPrint(
            out,
            "{s}Network error while calling {s}/{s}. Check internet/VPN and provider availability.",
            .{ prefix, options.status_provider, options.status_model },
        ) catch "network transport error",
        error.HttpStatusCode => std.fmt.bufPrint(
            out,
            "{s}HTTP error from {s}/{s}. Check model name and provider status. Run with --verbose (or ZCODE_VERBOSE=1) for details.",
            .{ prefix, options.status_provider, options.status_model },
        ) catch "provider returned HTTP error",
        error.InsufficientBalance => std.fmt.bufPrint(
            out,
            "{s}Insufficient balance for {s}. Top up credits and retry.",
            .{ prefix, options.status_provider },
        ) catch "provider account has insufficient balance",
        error.RateLimited => std.fmt.bufPrint(
            out,
            "{s}Rate limit reached for {s}. Wait briefly and retry.",
            .{ prefix, options.status_provider },
        ) catch "provider rate limit reached",
        error.AuthenticationFailed => std.fmt.bufPrint(
            out,
            "{s}Authentication failed for {s}. Verify API key and base URL.",
            .{ prefix, options.status_provider },
        ) catch "provider authentication failed",
        error.MissingApiKey => std.fmt.bufPrint(
            out,
            "{s}Missing API key for {s}. Configure in ~/.zcode/config.toml or set environment variable.",
            .{ prefix, options.status_provider },
        ) catch "missing API key",
        else => std.fmt.bufPrint(out, "{s}{s}", .{ prefix, @errorName(err) }) catch "error",
    };
}

// Overlay helper functions
pub fn appendLiteral(buf: []u8, pos: *usize, literal: []const u8) void {
    const end = pos.* + literal.len;
    if (end > buf.len) return;
    @memcpy(buf[pos.*..end], literal);
    pos.* = end;
}

pub fn appendRepeatByte(buf: []u8, pos: *usize, unit: []const u8, count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        appendLiteral(buf, pos, unit);
    }
}

pub fn appendCursorTo(buf: []u8, pos: *usize, row: usize) void {
    var tmp: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "\x1b[{d};1H", .{row}) catch return;
    appendLiteral(buf, pos, s);
}

const testing = std.testing;

test "transcriptWindowRows accounts for bottom margin" {
    const options = .{
        .bottom_margin_rows = @as(usize, 2),
        .transcript_line_spacing = @as(usize, 1),
    };
    try testing.expectEqual(@as(usize, 18), transcriptWindowRows(30, options));
}

test "transcriptVisualRows applies configured line spacing" {
    var transcript = UiTranscript.init(testing.allocator, 10);
    defer transcript.deinit(testing.allocator);
    try transcript.appendLine(testing.allocator, "alpha");
    try transcript.appendLine(testing.allocator, "beta");

    const options = .{
        .transcript_line_spacing = @as(usize, 1),
    };
    try testing.expectEqual(@as(usize, 3), transcriptVisualRows(&transcript, 80, options));
}

test "brief mode collapses long assistant blocks in transcript math" {
    var transcript = UiTranscript.init(testing.allocator, 10);
    defer transcript.deinit(testing.allocator);
    try transcript.appendLine(testing.allocator, transcriptAssistantBlockStartMarker());
    try transcript.appendLine(testing.allocator, "first assistant line");
    try transcript.appendLine(testing.allocator, "second assistant line");
    try transcript.appendLine(testing.allocator, "third assistant line");
    try transcript.appendLine(testing.allocator, "fourth assistant line");
    try transcript.appendLine(testing.allocator, "fifth assistant line");
    try transcript.appendLine(testing.allocator, "sixth assistant line");
    try transcript.appendLine(testing.allocator, "seventh assistant line");
    try transcript.appendLine(testing.allocator, "eighth assistant line");
    try transcript.appendLine(testing.allocator, "ninth assistant line");
    try transcript.appendLine(testing.allocator, transcriptAssistantBlockEndMarker());

    const full_rows = transcriptVisualRows(&transcript, 40, .{
        .transcript_line_spacing = @as(usize, 1),
    });
    const brief_rows = transcriptVisualRows(&transcript, 40, .{
        .transcript_line_spacing = @as(usize, 1),
        .brief_mode = true,
    });

    try testing.expect(brief_rows < full_rows);
}

test "renderFullScreen writes to an ArrayList.Managed writer" {
    // Pin the exact path the live-scroll callback takes: build a
    // transcript, render into a std_io.StringBuilder via its
    // .writer(), and assert the buffer is non-empty and contains
    // recognisable content. If this test ever goes red, the live-
    // scroll path is broken at the writer layer and no amount of
    // downstream debugging will save us.
    var transcript = UiTranscript.init(testing.allocator, 10);
    defer transcript.deinit(testing.allocator);
    try transcript.appendLine(testing.allocator, "first line of transcript");
    try transcript.appendLine(testing.allocator, "second line of transcript");
    try transcript.appendLine(testing.allocator, "third line with DISTINCTIVE_MARKER_XYZ");

    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();

    const options = .{
        .prompt_label = @as([]const u8, ">"),
        .app_version = @as([]const u8, "test"),
        .status_provider = @as([]const u8, "test-provider"),
        .status_model = @as([]const u8, "test-model"),
        .status_workspace = @as([]const u8, "/tmp"),
        .status_branch = @as([]const u8, "main"),
        .status_model_context_window = @as(usize, 100_000),
        .status_approval_mode = @as([]const u8, "tiered-auto"),
        .status_sandbox = @as([]const u8, "workspace-write"),
        .status_show_workspace = true,
        .status_show_model = true,
        .status_show_safety = true,
        .status_show_tokens = false,
        .status_show_hint = true,
        .yolo_mode = false,
        .color_enabled = false,
        .highlight_links = false,
        .highlight_paths = false,
        .color_lists = false,
        .highlight_code_blocks = false,
        .enable_fullscreen = true,
        .enable_alt_screen = false,
        .enable_spinner = false,
        .enable_thinking_summary = false,
        .transcript_max_lines = @as(usize, 20_000),
        .show_scroll_hint = true,
        .bottom_margin_rows = @as(usize, 2),
        .transcript_line_spacing = @as(usize, 1),
        .ui_density = @as(enum { full, clean }, .full),
        .show_top_bar = true,
        .status_metrics_provider = null,
        .status_identity_provider = null,
        .initial_prompt = null,
    };

    const TestMode = enum { execution, planning, brainstorm, review };
    try renderFullScreen(
        buf.writer(),
        &transcript,
        false,
        "",
        0,
        "idle",
        TestMode.execution,
        options,
    );

    try testing.expect(buf.items().len > 0);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "DISTINCTIVE_MARKER_XYZ") != null);
    // The clear-screen sequence should appear at the start.
    try testing.expect(std.mem.startsWith(u8, buf.items(), "\x1b[2J"));
    // No sync-output field => frame is NOT wrapped in BSU/ESU.
    try testing.expect(std.mem.indexOf(u8, buf.items(), terminal_caps.BSU) == null);
    try testing.expect(std.mem.indexOf(u8, buf.items(), terminal_caps.ESU) == null);
}

test "renderFullScreen wraps frame in BSU/ESU when synchronized output enabled" {
    var transcript = UiTranscript.init(testing.allocator, 10);
    defer transcript.deinit(testing.allocator);
    try transcript.appendLine(testing.allocator, "first line of transcript");

    const TestMode = enum { execution, planning, brainstorm, review };

    // Same option shape as the writer test above, plus the sync flag. Inline
    // anonymous structs keep status_identity_provider/metrics_provider typed as
    // untyped null so their provider.get branch stays comptime-dead.
    const opts_on = .{
        .prompt_label = @as([]const u8, ">"),
        .app_version = @as([]const u8, "test"),
        .status_provider = @as([]const u8, "test-provider"),
        .status_model = @as([]const u8, "test-model"),
        .status_workspace = @as([]const u8, "/tmp"),
        .status_branch = @as([]const u8, "main"),
        .status_model_context_window = @as(usize, 100_000),
        .status_approval_mode = @as([]const u8, "tiered-auto"),
        .status_sandbox = @as([]const u8, "workspace-write"),
        .status_show_workspace = true,
        .status_show_model = true,
        .status_show_safety = true,
        .status_show_tokens = false,
        .status_show_hint = true,
        .yolo_mode = false,
        .color_enabled = false,
        .highlight_links = false,
        .highlight_paths = false,
        .color_lists = false,
        .highlight_code_blocks = false,
        .enable_fullscreen = true,
        .enable_alt_screen = false,
        .enable_synchronized_output = true,
        .enable_spinner = false,
        .enable_thinking_summary = false,
        .transcript_max_lines = @as(usize, 20_000),
        .show_scroll_hint = true,
        .bottom_margin_rows = @as(usize, 2),
        .transcript_line_spacing = @as(usize, 1),
        .ui_density = @as(enum { full, clean }, .full),
        .show_top_bar = true,
        .status_metrics_provider = null,
        .status_identity_provider = null,
        .initial_prompt = null,
    };
    const opts_off = .{
        .prompt_label = @as([]const u8, ">"),
        .app_version = @as([]const u8, "test"),
        .status_provider = @as([]const u8, "test-provider"),
        .status_model = @as([]const u8, "test-model"),
        .status_workspace = @as([]const u8, "/tmp"),
        .status_branch = @as([]const u8, "main"),
        .status_model_context_window = @as(usize, 100_000),
        .status_approval_mode = @as([]const u8, "tiered-auto"),
        .status_sandbox = @as([]const u8, "workspace-write"),
        .status_show_workspace = true,
        .status_show_model = true,
        .status_show_safety = true,
        .status_show_tokens = false,
        .status_show_hint = true,
        .yolo_mode = false,
        .color_enabled = false,
        .highlight_links = false,
        .highlight_paths = false,
        .color_lists = false,
        .highlight_code_blocks = false,
        .enable_fullscreen = true,
        .enable_alt_screen = false,
        .enable_synchronized_output = false,
        .enable_spinner = false,
        .enable_thinking_summary = false,
        .transcript_max_lines = @as(usize, 20_000),
        .show_scroll_hint = true,
        .bottom_margin_rows = @as(usize, 2),
        .transcript_line_spacing = @as(usize, 1),
        .ui_density = @as(enum { full, clean }, .full),
        .show_top_bar = true,
        .status_metrics_provider = null,
        .status_identity_provider = null,
        .initial_prompt = null,
    };

    // Enabled: frame opens with BSU (before the clear-screen) and closes with ESU.
    {
        var buf = std_io.StringBuilder.init(testing.allocator);
        defer buf.deinit();
        try renderFullScreen(buf.writer(), &transcript, false, "", 0, "idle", TestMode.execution, opts_on);
        try testing.expect(std.mem.startsWith(u8, buf.items(), terminal_caps.BSU));
        try testing.expect(std.mem.endsWith(u8, buf.items(), terminal_caps.ESU));
        // The clear-screen still follows BSU.
        try testing.expect(std.mem.indexOf(u8, buf.items(), "\x1b[2J") != null);
    }

    // Disabled: neither sequence present.
    {
        var buf = std_io.StringBuilder.init(testing.allocator);
        defer buf.deinit();
        try renderFullScreen(buf.writer(), &transcript, false, "", 0, "idle", TestMode.execution, opts_off);
        try testing.expect(std.mem.indexOf(u8, buf.items(), terminal_caps.BSU) == null);
        try testing.expect(std.mem.indexOf(u8, buf.items(), terminal_caps.ESU) == null);
    }
}

test "renderFullScreen shows slash suggestions" {
    var transcript = UiTranscript.init(testing.allocator, 10);
    defer transcript.deinit(testing.allocator);
    try transcript.appendLine(testing.allocator, "transcript row");

    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();

    const options = .{
        .prompt_label = @as([]const u8, ">"),
        .app_version = @as([]const u8, "test"),
        .status_provider = @as([]const u8, "test-provider"),
        .status_model = @as([]const u8, "test-model"),
        .status_workspace = @as([]const u8, "/tmp"),
        .status_branch = @as([]const u8, "main"),
        .status_model_context_window = @as(usize, 100_000),
        .status_approval_mode = @as([]const u8, "tiered-auto"),
        .status_sandbox = @as([]const u8, "workspace-write"),
        .status_show_workspace = true,
        .status_show_model = true,
        .status_show_safety = true,
        .status_show_tokens = false,
        .status_show_hint = true,
        .yolo_mode = false,
        .color_enabled = false,
        .highlight_links = false,
        .highlight_paths = false,
        .color_lists = false,
        .highlight_code_blocks = false,
        .enable_fullscreen = true,
        .enable_alt_screen = false,
        .enable_spinner = false,
        .enable_thinking_summary = false,
        .transcript_max_lines = @as(usize, 20_000),
        .show_scroll_hint = true,
        .bottom_margin_rows = @as(usize, 2),
        .transcript_line_spacing = @as(usize, 1),
        .status_metrics_provider = null,
        .status_identity_provider = null,
        .initial_prompt = null,
    };

    const TestMode = enum { execution, planning, brainstorm, review };
    try renderFullScreen(
        buf.writer(),
        &transcript,
        true,
        "/m",
        0,
        "",
        TestMode.execution,
        options,
    );

    try testing.expect(std.mem.indexOf(u8, buf.items(), "transcript row") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "/mode") != null);
}

test "renderTopContextBar shows session identity and leader hint" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();

    const options = .{
        .status_provider = @as([]const u8, "test-provider"),
        .status_model = @as([]const u8, "test-model"),
        .status_workspace = @as([]const u8, "/tmp/project"),
        .status_branch = @as([]const u8, "main"),
        .status_approval_mode = @as([]const u8, "tiered-auto"),
        .status_sandbox = @as([]const u8, "workspace-write"),
        .status_show_safety = true,
        .status_show_tokens = false,
        .status_identity_provider = null,
        .status_dynamic_provider = null,
        .show_top_bar = true,
        .ui_density = @as(enum { full, clean }, .full),
        .ui_leader_key = @as([]const u8, "ctrl+x"),
        .color_enabled = false,
    };

    const TestMode = enum { execution, planning, brainstorm, review };
    try renderTopContextBar(buf.writer(), options, TestMode.execution, 200);

    try testing.expect(std.mem.indexOf(u8, buf.items(), "zcode") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "exec full") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "repo project@main") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "model test-provider/test-model") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "palette ctrl+x h") != null);
}

test "renderFullScreenWithCursorSelection highlights selected slash suggestion" {
    var transcript = UiTranscript.init(testing.allocator, 10);
    defer transcript.deinit(testing.allocator);

    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();

    const options = .{
        .prompt_label = @as([]const u8, ">"),
        .app_version = @as([]const u8, "test"),
        .status_provider = @as([]const u8, "test-provider"),
        .status_model = @as([]const u8, "test-model"),
        .status_workspace = @as([]const u8, "/tmp"),
        .status_branch = @as([]const u8, "main"),
        .status_model_context_window = @as(usize, 100_000),
        .status_approval_mode = @as([]const u8, "tiered-auto"),
        .status_sandbox = @as([]const u8, "workspace-write"),
        .status_show_workspace = true,
        .status_show_model = true,
        .status_show_safety = true,
        .status_show_tokens = false,
        .status_show_hint = true,
        .yolo_mode = false,
        .color_enabled = false,
        .highlight_links = false,
        .highlight_paths = false,
        .color_lists = false,
        .highlight_code_blocks = false,
        .enable_fullscreen = true,
        .enable_alt_screen = false,
        .enable_spinner = false,
        .enable_thinking_summary = false,
        .transcript_max_lines = @as(usize, 20_000),
        .show_scroll_hint = true,
        .bottom_margin_rows = @as(usize, 2),
        .transcript_line_spacing = @as(usize, 1),
        .status_metrics_provider = null,
        .status_identity_provider = null,
        .initial_prompt = null,
    };

    const TestMode = enum { execution, planning, brainstorm, review };
    try renderFullScreenWithCursorSelection(
        buf.writer(),
        &transcript,
        true,
        "/mode ",
        "/mode ".len,
        0,
        "",
        1,
        TestMode.execution,
        options,
    );

    try testing.expect(std.mem.indexOf(u8, buf.items(), "> /mode planning") != null);
}

test "renderFullScreen shows @file suggestion overlay" {
    var transcript = UiTranscript.init(testing.allocator, 10);
    defer transcript.deinit(testing.allocator);

    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();

    const options = .{
        .prompt_label = @as([]const u8, ">"),
        .app_version = @as([]const u8, "test"),
        .status_provider = @as([]const u8, "test-provider"),
        .status_model = @as([]const u8, "test-model"),
        .status_workspace = @as([]const u8, "/tmp"),
        .status_branch = @as([]const u8, "main"),
        .status_model_context_window = @as(usize, 100_000),
        .status_approval_mode = @as([]const u8, "tiered-auto"),
        .status_sandbox = @as([]const u8, "workspace-write"),
        .status_show_workspace = true,
        .status_show_model = true,
        .status_show_safety = true,
        .status_show_tokens = false,
        .status_show_hint = true,
        .yolo_mode = false,
        .color_enabled = false,
        .highlight_links = false,
        .highlight_paths = false,
        .color_lists = false,
        .highlight_code_blocks = false,
        .enable_fullscreen = true,
        .enable_alt_screen = false,
        .enable_spinner = false,
        .enable_thinking_summary = false,
        .reference_suggestions = &[_]struct {
            primary: []const u8,
        }{
            .{ .primary = "src/main.zig" },
            .{ .primary = "src/repl.zig" },
        },
        .reference_suggestion_selection = @as(usize, 1),
        .transcript_max_lines = @as(usize, 20_000),
        .show_scroll_hint = true,
        .bottom_margin_rows = @as(usize, 2),
        .transcript_line_spacing = @as(usize, 1),
        .status_metrics_provider = null,
        .status_identity_provider = null,
        .initial_prompt = null,
    };

    const TestMode = enum { execution, planning, brainstorm, review };
    try renderFullScreen(
        buf.writer(),
        &transcript,
        true,
        "@sr",
        0,
        "",
        TestMode.execution,
        options,
    );

    try testing.expect(std.mem.indexOf(u8, buf.items(), "@src/main.zig") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "> @src/repl.zig") != null);
}

test "renderFullScreen shows empty-input placeholder" {
    var transcript = UiTranscript.init(testing.allocator, 10);
    defer transcript.deinit(testing.allocator);

    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();

    const options = .{
        .prompt_label = @as([]const u8, ">"),
        .app_version = @as([]const u8, "test"),
        .status_provider = @as([]const u8, "test-provider"),
        .status_model = @as([]const u8, "test-model"),
        .status_workspace = @as([]const u8, "/tmp"),
        .status_branch = @as([]const u8, "main"),
        .status_model_context_window = @as(usize, 100_000),
        .status_approval_mode = @as([]const u8, "tiered-auto"),
        .status_sandbox = @as([]const u8, "workspace-write"),
        .status_show_workspace = true,
        .status_show_model = true,
        .status_show_safety = true,
        .status_show_tokens = false,
        .status_show_hint = true,
        .yolo_mode = false,
        .color_enabled = false,
        .highlight_links = false,
        .highlight_paths = false,
        .color_lists = false,
        .highlight_code_blocks = false,
        .enable_fullscreen = true,
        .enable_alt_screen = false,
        .enable_spinner = false,
        .enable_thinking_summary = false,
        .transcript_max_lines = @as(usize, 20_000),
        .show_scroll_hint = true,
        .bottom_margin_rows = @as(usize, 2),
        .transcript_line_spacing = @as(usize, 1),
        .status_metrics_provider = null,
        .status_identity_provider = null,
        .initial_prompt = null,
    };

    const TestMode = enum { execution, planning, brainstorm, review };
    try renderFullScreen(
        buf.writer(),
        &transcript,
        true,
        "",
        0,
        "",
        TestMode.execution,
        options,
    );

    try testing.expect(std.mem.indexOf(u8, buf.items(), PROMPT_PLACEHOLDER) != null);
}

test "renderFullScreen prefers dynamic prompt placeholder when provided" {
    var transcript = UiTranscript.init(testing.allocator, 10);
    defer transcript.deinit(testing.allocator);

    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();

    const options = .{
        .prompt_label = @as([]const u8, ">"),
        .app_version = @as([]const u8, "test"),
        .status_provider = @as([]const u8, "test-provider"),
        .status_model = @as([]const u8, "test-model"),
        .status_workspace = @as([]const u8, "/tmp"),
        .status_branch = @as([]const u8, "main"),
        .status_model_context_window = @as(usize, 100_000),
        .status_approval_mode = @as([]const u8, "tiered-auto"),
        .status_sandbox = @as([]const u8, "workspace-write"),
        .status_show_workspace = true,
        .status_show_model = true,
        .status_show_safety = true,
        .status_show_tokens = false,
        .status_show_hint = true,
        .yolo_mode = false,
        .color_enabled = false,
        .highlight_links = false,
        .highlight_paths = false,
        .color_lists = false,
        .highlight_code_blocks = false,
        .enable_fullscreen = true,
        .enable_alt_screen = false,
        .enable_spinner = false,
        .enable_thinking_summary = false,
        .prompt_placeholder = @as([]const u8, "explain src/main.zig"),
        .transcript_max_lines = @as(usize, 20_000),
        .show_scroll_hint = true,
        .bottom_margin_rows = @as(usize, 2),
        .transcript_line_spacing = @as(usize, 1),
        .status_metrics_provider = null,
        .status_identity_provider = null,
        .initial_prompt = null,
    };

    const TestMode = enum { execution, planning, brainstorm, review };
    try renderFullScreen(
        buf.writer(),
        &transcript,
        true,
        "",
        0,
        "",
        TestMode.execution,
        options,
    );

    try testing.expect(std.mem.indexOf(u8, buf.items(), "explain src/main.zig") != null);
}

test "renderFullScreen prefers prompt suggestion over fallback placeholder" {
    var transcript = UiTranscript.init(testing.allocator, 10);
    defer transcript.deinit(testing.allocator);

    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();

    const options = .{
        .prompt_label = @as([]const u8, ">"),
        .app_version = @as([]const u8, "test"),
        .status_provider = @as([]const u8, "test-provider"),
        .status_model = @as([]const u8, "test-model"),
        .status_workspace = @as([]const u8, "/tmp"),
        .status_branch = @as([]const u8, "main"),
        .status_model_context_window = @as(usize, 100_000),
        .status_approval_mode = @as([]const u8, "tiered-auto"),
        .status_sandbox = @as([]const u8, "workspace-write"),
        .status_show_workspace = true,
        .status_show_model = true,
        .status_show_safety = true,
        .status_show_tokens = false,
        .status_show_hint = true,
        .yolo_mode = false,
        .color_enabled = false,
        .highlight_links = false,
        .highlight_paths = false,
        .color_lists = false,
        .highlight_code_blocks = false,
        .enable_fullscreen = true,
        .enable_alt_screen = false,
        .enable_spinner = false,
        .enable_thinking_summary = false,
        .prompt_placeholder = @as([]const u8, "fallback"),
        .prompt_suggestion = @as([]const u8, "suggested prompt"),
        .transcript_max_lines = @as(usize, 20_000),
        .show_scroll_hint = true,
        .bottom_margin_rows = @as(usize, 2),
        .transcript_line_spacing = @as(usize, 1),
        .status_metrics_provider = null,
        .status_identity_provider = null,
        .initial_prompt = null,
    };

    const TestMode = enum { execution, planning, brainstorm, review };
    try renderFullScreen(
        buf.writer(),
        &transcript,
        true,
        "",
        0,
        "",
        TestMode.execution,
        options,
    );

    try testing.expect(std.mem.indexOf(u8, buf.items(), "suggested prompt") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "fallback") == null);
}

test "renderFullScreen shows inline ghost text suffix" {
    var transcript = UiTranscript.init(testing.allocator, 10);
    defer transcript.deinit(testing.allocator);

    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();

    const options = .{
        .prompt_label = @as([]const u8, ">"),
        .app_version = @as([]const u8, "test"),
        .status_provider = @as([]const u8, "test-provider"),
        .status_model = @as([]const u8, "test-model"),
        .status_workspace = @as([]const u8, "/tmp"),
        .status_branch = @as([]const u8, "main"),
        .status_model_context_window = @as(usize, 100_000),
        .status_approval_mode = @as([]const u8, "tiered-auto"),
        .status_sandbox = @as([]const u8, "workspace-write"),
        .status_show_workspace = true,
        .status_show_model = true,
        .status_show_safety = true,
        .status_show_tokens = false,
        .status_show_hint = true,
        .yolo_mode = false,
        .color_enabled = false,
        .highlight_links = false,
        .highlight_paths = false,
        .color_lists = false,
        .highlight_code_blocks = false,
        .enable_fullscreen = true,
        .enable_alt_screen = false,
        .enable_spinner = false,
        .enable_thinking_summary = false,
        .inline_ghost_text = @as([]const u8, "odel"),
        .transcript_max_lines = @as(usize, 20_000),
        .show_scroll_hint = true,
        .bottom_margin_rows = @as(usize, 2),
        .transcript_line_spacing = @as(usize, 1),
        .status_metrics_provider = null,
        .status_identity_provider = null,
        .initial_prompt = null,
    };

    const TestMode = enum { execution, planning, brainstorm, review };
    try renderFullScreen(
        buf.writer(),
        &transcript,
        true,
        "/m",
        0,
        "",
        TestMode.execution,
        options,
    );

    try testing.expect(std.mem.indexOf(u8, buf.items(), "odel") != null);
}

test "renderFullScreen footer shows queued and stashed notices" {
    var transcript = UiTranscript.init(testing.allocator, 10);
    defer transcript.deinit(testing.allocator);

    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();

    const options = .{
        .prompt_label = @as([]const u8, ">"),
        .app_version = @as([]const u8, "test"),
        .status_provider = @as([]const u8, "test-provider"),
        .status_model = @as([]const u8, "test-model"),
        .status_workspace = @as([]const u8, "/tmp"),
        .status_branch = @as([]const u8, "main"),
        .status_model_context_window = @as(usize, 100_000),
        .status_approval_mode = @as([]const u8, "tiered-auto"),
        .status_sandbox = @as([]const u8, "workspace-write"),
        .status_show_workspace = true,
        .status_show_model = true,
        .status_show_safety = true,
        .status_show_tokens = false,
        .status_show_hint = true,
        .yolo_mode = false,
        .color_enabled = false,
        .highlight_links = false,
        .highlight_paths = false,
        .color_lists = false,
        .highlight_code_blocks = false,
        .enable_fullscreen = true,
        .enable_alt_screen = false,
        .enable_spinner = false,
        .enable_thinking_summary = false,
        .queued_prompt_notice = @as([]const u8, "queued: summarize latest diff"),
        .stashed_prompt_available = true,
        .transcript_max_lines = @as(usize, 20_000),
        .show_scroll_hint = true,
        .bottom_margin_rows = @as(usize, 2),
        .transcript_line_spacing = @as(usize, 1),
        .status_metrics_provider = null,
        .status_identity_provider = null,
        .initial_prompt = null,
    };

    const TestMode = enum { execution, planning, brainstorm, review };
    try renderFullScreen(
        buf.writer(),
        &transcript,
        true,
        "",
        0,
        "",
        TestMode.execution,
        options,
    );

    try testing.expect(std.mem.indexOf(u8, buf.items(), "queued: summarize latest diff") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "stash ready") != null);
}

test "renderFullScreen footer rows overlay shows structured suggestions and notices" {
    var transcript = UiTranscript.init(testing.allocator, 10);
    defer transcript.deinit(testing.allocator);

    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();

    const rows = [_]repl_footer.Row{
        .{
            .kind = .stash,
            .primary = "Stashed draft ready",
            .secondary = "Ctrl+S restores it into the composer",
            .tag = "stash",
            .source = .notice,
            .tone = .plain,
        },
        .{
            .kind = .suggestion,
            .primary = "summarize latest diff",
            .secondary = "recent workspace prompt",
            .tag = "recent",
            .source = .history,
            .tone = .plain,
            .selectable = true,
        },
    };

    const options = .{
        .prompt_label = @as([]const u8, ">"),
        .app_version = @as([]const u8, "test"),
        .status_provider = @as([]const u8, "test-provider"),
        .status_model = @as([]const u8, "test-model"),
        .status_workspace = @as([]const u8, "/tmp"),
        .status_branch = @as([]const u8, "main"),
        .status_model_context_window = @as(usize, 100_000),
        .status_approval_mode = @as([]const u8, "tiered-auto"),
        .status_sandbox = @as([]const u8, "workspace-write"),
        .status_show_workspace = true,
        .status_show_model = true,
        .status_show_safety = true,
        .status_show_tokens = false,
        .status_show_hint = true,
        .yolo_mode = false,
        .color_enabled = false,
        .highlight_links = false,
        .highlight_paths = false,
        .color_lists = false,
        .highlight_code_blocks = false,
        .enable_fullscreen = true,
        .enable_alt_screen = false,
        .enable_spinner = false,
        .enable_thinking_summary = false,
        .footer_rows = rows[0..],
        .footer_row_selection = @as(?usize, 1),
        .transcript_max_lines = @as(usize, 20_000),
        .show_scroll_hint = true,
        .bottom_margin_rows = @as(usize, 2),
        .transcript_line_spacing = @as(usize, 1),
        .status_metrics_provider = null,
        .status_identity_provider = null,
        .initial_prompt = null,
    };

    const TestMode = enum { execution, planning, brainstorm, review };
    try renderFullScreen(
        buf.writer(),
        &transcript,
        true,
        "",
        0,
        "",
        TestMode.execution,
        options,
    );

    try testing.expect(std.mem.indexOf(u8, buf.items(), "Stashed draft ready") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "summarize latest diff") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "[recent]") != null);
}

test "renderPromptFooter shows compact shortcuts in the redesigned footer" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();

    const options = .{
        .yolo_mode = false,
        .status_approval_mode = @as([]const u8, "tiered-auto"),
        .status_sandbox = @as([]const u8, "workspace-write"),
        .status_show_safety = false,
        .status_show_workspace = false,
        .status_show_model = false,
        .status_show_tokens = false,
        .status_show_hint = false,
        .color_enabled = false,
        .enable_thinking_summary = false,
        .ui_density = @as(enum { full, clean }, .full),
        .ui_leader_key = @as([]const u8, "ctrl+x"),
        .shortcuts_panel_enabled = true,
        .theme = ui_theme.ThemeName.dark,
    };

    const TestMode = enum { execution, planning, brainstorm, review };
    try renderPromptFooter(buf.writer(), options, TestMode.execution, 160, "make a tui change\nverify narrow width");

    try testing.expect(std.mem.indexOf(u8, buf.items(), "actions") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "draft") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "2 lines") != null);
    // Keyboard hints (? shortcuts, ctrl+x h palette, Tab Tab clean UI) moved
    // to the prompt-hint row above this footer to reduce visual density on
    // the bottom bar. They are exercised by the prompt-hint test.
    try testing.expect(std.mem.indexOf(u8, buf.items(), "? shortcuts") == null);
}

test "classifyInputHighlightByte marks slash commands and @references" {
    var preview_buf: [256]u8 = undefined;
    const content = repl_input.formatInputPreview(">", "/model @src/main.zig", &preview_buf);

    const slash_idx = std.mem.indexOf(u8, content, "/model").?;
    try testing.expect(classifyInputHighlightByte(content, slash_idx, 1) == .slash);
    try testing.expect(classifyInputHighlightByte(content, slash_idx + 3, 1) == .slash);

    const mention_idx = std.mem.indexOf(u8, content, "@src/main.zig").?;
    try testing.expect(classifyInputHighlightByte(content, mention_idx, 1) == .mention);
    try testing.expect(classifyInputHighlightByte(content, mention_idx + 4, 1) == .mention);
}

test "classifyInputHighlightByte leaves ordinary prompt text plain" {
    var preview_buf: [256]u8 = undefined;
    const content = repl_input.formatInputPreview(">", "explain src/main.zig", &preview_buf);
    const text_idx = std.mem.indexOf(u8, content, "explain").?;
    try testing.expect(classifyInputHighlightByte(content, text_idx, 1) == .plain);
}

test "renderFullScreen brief mode shows collapse notice for assistant block" {
    var transcript = UiTranscript.init(testing.allocator, 10);
    defer transcript.deinit(testing.allocator);
    try transcript.appendLine(testing.allocator, transcriptAssistantBlockStartMarker());
    try transcript.appendLine(testing.allocator, "alpha");
    try transcript.appendLine(testing.allocator, "beta");
    try transcript.appendLine(testing.allocator, "gamma");
    try transcript.appendLine(testing.allocator, "delta");
    try transcript.appendLine(testing.allocator, "epsilon");
    try transcript.appendLine(testing.allocator, "zeta");
    try transcript.appendLine(testing.allocator, "eta");
    try transcript.appendLine(testing.allocator, transcriptAssistantBlockEndMarker());

    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();

    const options = .{
        .prompt_label = @as([]const u8, ">"),
        .app_version = @as([]const u8, "test"),
        .status_provider = @as([]const u8, "test-provider"),
        .status_model = @as([]const u8, "test-model"),
        .status_workspace = @as([]const u8, "/tmp"),
        .status_branch = @as([]const u8, "main"),
        .status_model_context_window = @as(usize, 100_000),
        .status_approval_mode = @as([]const u8, "tiered-auto"),
        .status_sandbox = @as([]const u8, "workspace-write"),
        .status_show_workspace = true,
        .status_show_model = true,
        .status_show_safety = true,
        .status_show_tokens = false,
        .status_show_hint = true,
        .yolo_mode = false,
        .color_enabled = false,
        .highlight_links = false,
        .highlight_paths = false,
        .color_lists = false,
        .highlight_code_blocks = false,
        .enable_fullscreen = true,
        .enable_alt_screen = false,
        .enable_spinner = false,
        .enable_thinking_summary = false,
        .brief_mode = true,
        .transcript_max_lines = @as(usize, 20_000),
        .show_scroll_hint = true,
        .bottom_margin_rows = @as(usize, 2),
        .transcript_line_spacing = @as(usize, 1),
        .status_metrics_provider = null,
        .status_identity_provider = null,
        .initial_prompt = null,
    };

    const TestMode = enum { execution, planning, brainstorm, review };
    try renderFullScreen(
        buf.writer(),
        &transcript,
        true,
        "",
        0,
        "",
        TestMode.execution,
        options,
    );

    try testing.expect(std.mem.indexOf(u8, buf.items(), "brief view hidden") != null);
}

test "visualRowsForTranscriptLine keeps divider to one row" {
    var divider_buf: [64]u8 = undefined;
    const divider = formatTranscriptDivider(divider_buf[0..], "Assistant");
    try testing.expectEqual(@as(usize, 1), visualRowsForTranscriptLine(divider, 8));
}

test "assistant transcript block suppresses inner spacing" {
    var transcript = UiTranscript.init(testing.allocator, 10);
    defer transcript.deinit(testing.allocator);
    try transcript.appendLine(testing.allocator, transcriptAssistantBlockStartMarker());
    try transcript.appendLine(testing.allocator, "alpha");
    try transcript.appendLine(testing.allocator, "beta");
    try transcript.appendLine(testing.allocator, transcriptAssistantBlockEndMarker());

    const options = .{
        .transcript_line_spacing = @as(usize, 1),
    };
    try testing.expectEqual(@as(usize, 4), transcriptVisualRows(&transcript, 80, options));
}

test "assistant transcript block wraps to inner width" {
    var transcript = UiTranscript.init(testing.allocator, 10);
    defer transcript.deinit(testing.allocator);
    try transcript.appendLine(testing.allocator, transcriptAssistantBlockStartMarker());
    try transcript.appendLine(testing.allocator, "abcdef");
    try transcript.appendLine(testing.allocator, transcriptAssistantBlockEndMarker());

    const options = .{
        .transcript_line_spacing = @as(usize, 0),
    };
    try testing.expectEqual(@as(usize, 5), transcriptVisualRows(&transcript, 4, options));
}
