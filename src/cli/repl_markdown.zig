const std = @import("std");
const std_io = @import("../core/std_io.zig");
const ui_theme = @import("../core/ui_theme.zig");

pub const ANSI_RESET = "\x1b[0m";
pub const ANSI_BOLD = "\x1b[1m";
pub const ANSI_ITALIC = "\x1b[3m";
pub const ANSI_BOLD_ITALIC = "\x1b[1;3m";
pub const ANSI_DIM = "\x1b[2m";
pub const ANSI_UNDERLINE = "\x1b[4m";
// Brand accent used by the welcome banner, the logo glyph, and any
// other "this is zcode" visual hook. Truecolor so the hue is
// consistent across modern terminals; 256-color emulators approximate
// a nearby tone, which is an acceptable fallback.
pub const ANSI_BRAND_ACCENT = "\x1b[38;2;95;212;160m"; // #5FD4A0 mint
pub const ANSI_BRAND_ACCENT_BOLD = "\x1b[1;38;2;95;212;160m";
pub const ANSI_BRAND_ACCENT_DIM = "\x1b[38;2;58;128;98m"; // darker mint for rules
pub const ANSI_LINK = "\x1b[38;5;75m\x1b[4m"; // Softer blue link
pub const ANSI_PATH = "\x1b[38;5;114m";
pub const ANSI_LIST = "\x1b[38;5;180m"; // Softer gold for list markers
pub const ANSI_CODE_FENCE = "\x1b[38;5;240m";
pub const ANSI_CODE_COMMENT = "\x1b[38;5;244m";
pub const ANSI_CODE_KEYWORD = "\x1b[38;5;176m"; // Softer purple for keywords
pub const ANSI_CODE_STRING = "\x1b[38;5;150m"; // Softer green for strings
pub const ANSI_CODE_NUMBER = "\x1b[38;5;117m";
pub const ANSI_STATUS_BG = "\x1b[48;5;236m\x1b[38;5;252m"; // Dark bg, light fg for status bar
pub const ANSI_ERROR_PREFIX = "\x1b[38;5;203m"; // Soft red for errors
pub const ANSI_PROMPT = "\x1b[38;5;75m\x1b[1m"; // Bold blue prompt
pub const ANSI_HEADING_RULE = "\x1b[38;5;240m"; // Dim rule under H1
pub const ANSI_APPROVE_HL = "\x1b[38;5;114m\x1b[1m"; // Green for selected approve
pub const ANSI_DENY_HL = "\x1b[38;5;203m\x1b[1m"; // Red for selected deny

pub fn themeAnsi(options: anytype, comptime role: ui_theme.Role) []const u8 {
    return ui_theme.ansiForOptions(options, role);
}

pub fn brandAccentAnsi(options: anytype) []const u8 {
    return themeAnsi(options, .brand_accent);
}

pub fn brandAccentBoldAnsi(options: anytype) []const u8 {
    return themeAnsi(options, .brand_accent_bold);
}

pub fn brandAccentDimAnsi(options: anytype) []const u8 {
    return themeAnsi(options, .brand_accent_dim);
}

pub fn linkAnsi(options: anytype) []const u8 {
    return themeAnsi(options, .link);
}

pub fn pathAnsi(options: anytype) []const u8 {
    return themeAnsi(options, .path);
}

pub fn listAnsi(options: anytype) []const u8 {
    return themeAnsi(options, .list);
}

pub fn codeFenceAnsi(options: anytype) []const u8 {
    return themeAnsi(options, .code_fence);
}

pub fn codeCommentAnsi(options: anytype) []const u8 {
    return themeAnsi(options, .code_comment);
}

pub fn codeKeywordAnsi(options: anytype) []const u8 {
    return themeAnsi(options, .code_keyword);
}

pub fn codeStringAnsi(options: anytype) []const u8 {
    return themeAnsi(options, .code_string);
}

pub fn codeNumberAnsi(options: anytype) []const u8 {
    return themeAnsi(options, .code_number);
}

pub fn statusBgAnsi(options: anytype) []const u8 {
    return themeAnsi(options, .status_bg);
}

pub fn errorPrefixAnsi(options: anytype) []const u8 {
    return themeAnsi(options, .error_prefix);
}

pub fn promptAnsi(options: anytype) []const u8 {
    return themeAnsi(options, .prompt);
}

pub fn headingRuleAnsi(options: anytype) []const u8 {
    return themeAnsi(options, .heading_rule);
}

pub fn approveHighlightAnsi(options: anytype) []const u8 {
    return themeAnsi(options, .approve_hl);
}

pub fn denyHighlightAnsi(options: anytype) []const u8 {
    return themeAnsi(options, .deny_hl);
}

pub fn warningAnsi(options: anytype) []const u8 {
    return themeAnsi(options, .warning);
}

pub fn headingAnsi(options: anytype, level: u8) []const u8 {
    return switch (level) {
        1 => themeAnsi(options, .heading1),
        2 => themeAnsi(options, .heading2),
        3 => themeAnsi(options, .heading3),
        else => ANSI_BOLD,
    };
}

// Unicode box-drawing characters for professional borders.
pub const BOX_H = "\xe2\x94\x80"; // horizontal line
pub const BOX_V = "\xe2\x94\x82"; // vertical line
pub const BOX_TL = "\xe2\x95\xad"; // top-left corner
pub const BOX_TR = "\xe2\x95\xae"; // top-right corner
pub const BOX_BL = "\xe2\x95\xb0"; // bottom-left corner
pub const BOX_BR = "\xe2\x95\xaf"; // bottom-right corner
pub const TABLE_MAX_COLUMNS = 12;

pub const CodeLang = enum {
    plain,
    zig,
    go,
    javascript,
    typescript,
    json,
    bash,
    python,
    yaml,
    toml,
};

pub const MAX_PRECOMPUTED_TABLES = 16;

pub const PrecomputedTable = struct {
    start_line: u32 = 0,
    end_line: u32 = 0,
    col_count: u8 = 0,
    widths: [TABLE_MAX_COLUMNS]u16 = [_]u16{0} ** TABLE_MAX_COLUMNS,
};

pub const MarkdownRenderState = struct {
    in_code_block: bool = false,
    code_lang: CodeLang = .plain,
    table_active: bool = false,
    table_col_count: usize = 0,
    table_widths: [TABLE_MAX_COLUMNS]usize = [_]usize{0} ** TABLE_MAX_COLUMNS,

    // Precomputed table layouts for the two-pass writeStyledText path.
    // writeStyledText walks the text once up front to discover every
    // table block and compute column widths from the MAX cell in the
    // entire block. The second pass renders line-by-line using those
    // widths so the header, separator, and data rows all align to the
    // same column layout. Streaming callers (writeStyledLine invoked
    // directly without precomputing) fall back to the original
    // per-row width accumulation because they cannot peek ahead.
    precomputed_tables: [MAX_PRECOMPUTED_TABLES]PrecomputedTable = [_]PrecomputedTable{.{}} ** MAX_PRECOMPUTED_TABLES,
    precomputed_count: u8 = 0,
    current_line_idx: u32 = 0,
};

// Use a generic Options type that accepts any struct with the right fields
// This avoids circular dependencies
pub fn shouldUseColor(options: anytype) bool {
    if (!options.color_enabled) return false;
    // Honour the NO_COLOR informal standard (https://no-color.org).
    // Any non-empty value disables colour, regardless of the
    // --color CLI flag or config, so users relying on NO_COLOR in
    // their shell environment aren't second-guessed.
    if (@import("../core/env.zig").getenv("NO_COLOR")) |v| {
        if (v.len > 0) return false;
    }
    return std.c.isatty(std.Io.File.stdout().handle) != 0;
}

/// Copy `src` into `dest` with ANSI escape sequences stripped. Tool
/// output, agent turn text, and task notifications pass through the
/// markdown renderer; any CSI / OSC / Fe-Fs escape embedded in that
/// content would otherwise reach the user's terminal unchanged (the
/// markdown renderer adds its own styling on top, but passes the
/// source bytes through via writer.writeAll). Kept local to this
/// module so repl_markdown stays importable from repl_spinner
/// without a circular dependency on any shared util module.
pub fn stripAnsiInto(dest: []u8, src: []const u8) []const u8 {
    var o: usize = 0;
    var i: usize = 0;
    while (i < src.len and o < dest.len) {
        const ch = src[i];
        if (ch == 0x1b) {
            i += ansiSkipLength(src[i..]);
            continue;
        }
        // Keep tab and printable bytes; drop other control bytes. Newlines
        // are handled at the caller: writeStyledLine operates on a single
        // line so its input should not contain newlines.
        if (ch == '\t' or (ch >= 0x20 and ch != 0x7f)) {
            dest[o] = ch;
            o += 1;
        }
        i += 1;
    }
    return dest[0..o];
}

fn ansiSkipLength(text: []const u8) usize {
    if (text.len == 0 or text[0] != 0x1b) return 1;
    if (text.len == 1) return 1;

    const second = text[1];
    if (second == '[') {
        var i: usize = 2;
        while (i < text.len) : (i += 1) {
            const ch = text[i];
            if (ch >= 0x40 and ch <= 0x7e) return i + 1;
        }
        return text.len;
    }
    if (second == ']') {
        var i: usize = 2;
        while (i < text.len) : (i += 1) {
            if (text[i] == 0x07) return i + 1;
            if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '\\') return i + 2;
        }
        return text.len;
    }
    return @min(text.len, @as(usize, 2));
}

pub fn writeStyledText(writer: anytype, text: []const u8, options: anytype) !void {
    var md_state = MarkdownRenderState{};
    // First pass: scan for table blocks and compute max column widths so
    // the second pass can render every row in a table with consistent
    // alignment. Without this, streaming per-row rendering would widen
    // the state's widths as wider data rows arrive but earlier rows
    // (header, separator) had already been emitted with narrower
    // widths, leaving columns visibly misaligned in the final output.
    precomputeTables(text, &md_state);

    var start: usize = 0;
    var line_idx: u32 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            md_state.current_line_idx = line_idx;
            try writeStyledLineWithState(writer, text[start..i], options, &md_state);
            try writer.writeByte('\n');
            start = i + 1;
            line_idx += 1;
        }
    }
    if (start < text.len) {
        md_state.current_line_idx = line_idx;
        try writeStyledLineWithState(writer, text[start..], options, &md_state);
    }
}

/// Walk `text` line by line to identify markdown table blocks and
/// compute the max cell width per column across the entire block.
/// Results are written into `state.precomputed_tables`. Stops adding
/// new tables once `MAX_PRECOMPUTED_TABLES` is reached -- subsequent
/// tables fall back to streaming-width accumulation. In practice
/// assistant responses rarely contain more than a handful of tables,
/// so the cap is generous.
fn precomputeTables(text: []const u8, state: *MarkdownRenderState) void {
    state.precomputed_count = 0;

    var cells: [TABLE_MAX_COLUMNS][]const u8 = undefined;
    var cell_count: usize = 0;

    var in_code_block = false;
    var block_active = false;
    var block_start_line: u32 = 0;
    var block_col_count: usize = 0;
    var block_widths: [TABLE_MAX_COLUMNS]usize = [_]usize{0} ** TABLE_MAX_COLUMNS;

    var line_idx: u32 = 0;
    var start: usize = 0;
    var i: usize = 0;

    const flushBlock = struct {
        fn run(
            s: *MarkdownRenderState,
            end_line: u32,
            start_line: u32,
            col_count: usize,
            widths: *const [TABLE_MAX_COLUMNS]usize,
        ) void {
            if (s.precomputed_count >= MAX_PRECOMPUTED_TABLES) return;
            if (col_count == 0) return;
            var entry = &s.precomputed_tables[s.precomputed_count];
            entry.start_line = start_line;
            entry.end_line = end_line;
            entry.col_count = @intCast(col_count);
            var k: usize = 0;
            while (k < col_count and k < TABLE_MAX_COLUMNS) : (k += 1) {
                // Width padding semantics: clamp cell width to fit in
                // u16. A single cell wider than 65535 chars is not
                // something zcode will render sensibly anyway.
                const w = @min(widths[k], @as(usize, std.math.maxInt(u16)));
                entry.widths[k] = @intCast(w);
            }
            s.precomputed_count += 1;
        }
    }.run;

    while (i <= text.len) : (i += 1) {
        const at_end = i == text.len;
        if (at_end or text[i] == '\n') {
            const line = text[start..i];
            // Track code fences so tables inside code blocks aren't
            // parsed as structural tables.
            if (parseCodeFence(line) != null) {
                if (block_active) {
                    flushBlock(state, line_idx, block_start_line, block_col_count, &block_widths);
                    block_active = false;
                    block_col_count = 0;
                }
                in_code_block = !in_code_block;
            } else if (!in_code_block and parseMarkdownTableRow(line, &cells, &cell_count) and cell_count > 0) {
                if (!block_active or block_col_count != cell_count) {
                    if (block_active) {
                        flushBlock(state, line_idx, block_start_line, block_col_count, &block_widths);
                    }
                    block_active = true;
                    block_start_line = line_idx;
                    block_col_count = cell_count;
                    block_widths = [_]usize{0} ** TABLE_MAX_COLUMNS;
                }
                const is_separator = isMarkdownTableSeparator(cells[0..cell_count]);
                var k: usize = 0;
                while (k < cell_count and k < TABLE_MAX_COLUMNS) : (k += 1) {
                    const w = if (is_separator) @max(@as(usize, 3), cells[k].len) else cells[k].len;
                    if (w > block_widths[k]) block_widths[k] = w;
                }
            } else {
                if (block_active) {
                    flushBlock(state, line_idx, block_start_line, block_col_count, &block_widths);
                    block_active = false;
                    block_col_count = 0;
                }
            }

            line_idx += 1;
            start = i + 1;
            if (at_end) break;
        }
    }

    if (block_active) {
        flushBlock(state, line_idx, block_start_line, block_col_count, &block_widths);
    }
}

/// Return the precomputed widths for `line_idx` if it falls inside a
/// discovered table block. Caller uses the widths directly; lookup is
/// linear but the list is capped at 16 so the cost is negligible.
fn precomputedTableFor(state: *const MarkdownRenderState, line_idx: u32) ?*const PrecomputedTable {
    var i: usize = 0;
    while (i < state.precomputed_count) : (i += 1) {
        const entry = &state.precomputed_tables[i];
        if (line_idx >= entry.start_line and line_idx < entry.end_line) {
            return entry;
        }
    }
    return null;
}

fn writeStyledLineWithState(writer: anytype, line: []const u8, options: anytype, state: *MarkdownRenderState) !void {
    if (isLikelyToolWrapperLine(line)) {
        return;
    }

    if (parseCodeFence(line)) |fence| {
        if (state.table_active) resetTableState(state);
        const entering = !state.in_code_block;
        try writeCodeFenceMarker(writer, fence, entering, options);

        if (!entering) {
            state.in_code_block = false;
            state.code_lang = .plain;
        } else {
            state.in_code_block = true;
            state.code_lang = parseCodeLang(fence);
        }
        return;
    }

    if (state.in_code_block) {
        if (state.table_active) resetTableState(state);
        try writeCodeLine(writer, line, state.code_lang, options);
        return;
    }

    if (looksLikeStandaloneCodeLine(line)) {
        if (state.table_active) resetTableState(state);
        try writeCodeLine(writer, line, detectStandaloneCodeLang(line), options);
        return;
    }

    try writeStyledLine(writer, line, options, state);
}

pub fn writeStyledLine(writer: anytype, line_raw: []const u8, options: anytype, state: *MarkdownRenderState) !void {
    // Strip ANSI escape sequences from the input line before any markdown
    // processing so attacker-controlled bytes (tool output, task
    // notifications, agent turn text echoing a malicious file) can never
    // leak a CSI / OSC / Fe-Fs escape to the terminal. The renderer still
    // emits its own styling escapes downstream; only the input content is
    // sanitized. An 8 KiB stack buffer covers normal markdown lines; the
    // streaming buffer is 4 KiB per line and slash-command lines are
    // short, so truncation here would require a pathological single-line
    // payload.
    var line_buf: [8 * 1024]u8 = undefined;
    const line = stripAnsiInto(&line_buf, line_raw);

    if (line.len == 0) {
        try writer.writeAll(line);
        return;
    }

    const use_color = shouldUseColor(options);
    var idx: usize = 0;
    while (idx < line.len and (line[idx] == ' ' or line[idx] == '\t')) : (idx += 1) {}

    if (parseMarkdownHeading(line, idx)) |heading| {
        if (state.table_active) resetTableState(state);
        try writer.writeAll(line[0..idx]);
        if (use_color) {
            try writer.writeAll(headingAnsi(options, heading.level));
        }
        try writeMarkdownInline(writer, line[heading.text_start..], options, true);
        if (use_color) {
            try writer.writeAll(ANSI_RESET);
        }
        return;
    }

    if (parseMarkdownQuote(line, idx)) |quote_start| {
        if (state.table_active) resetTableState(state);
        try writer.writeAll(line[0..idx]);
        if (use_color) {
            // Use a solid vertical bar for blockquotes.
            try writeColored(writer, "\xe2\x94\x83", codeCommentAnsi(options));
        } else {
            try writer.writeByte('>');
        }
        try writer.writeByte(' ');
        if (use_color) try writer.writeAll(ANSI_ITALIC);
        try writeMarkdownInline(writer, line[quote_start..], options, true);
        if (use_color) try writer.writeAll(ANSI_RESET);
        return;
    }

    if (looksLikeHorizontalRule(line[idx..])) {
        if (state.table_active) resetTableState(state);
        try writer.writeAll(line[0..idx]);
        if (use_color) try writer.writeAll(codeFenceAnsi(options));
        const width = @max(@as(usize, 3), @min(@as(usize, 48), line[idx..].len));
        var i_rule: usize = 0;
        while (i_rule < width) : (i_rule += 1) {
            try writer.writeByte('-');
        }
        if (use_color) try writer.writeAll(ANSI_RESET);
        return;
    }

    var table_cells: [TABLE_MAX_COLUMNS][]const u8 = undefined;
    var table_cell_count: usize = 0;
    if (parseMarkdownTableRow(line, &table_cells, &table_cell_count)) {
        if (table_cell_count > 0) {
            // If writeStyledText pre-scanned this table, use its max
            // widths directly so every row lines up with the widest
            // row in the block. Falls back to streaming accumulation
            // when no precomputation is available (live streaming).
            if (precomputedTableFor(state, state.current_line_idx)) |pre| {
                var pre_widths: [TABLE_MAX_COLUMNS]usize = undefined;
                var k: usize = 0;
                while (k < pre.col_count and k < TABLE_MAX_COLUMNS) : (k += 1) {
                    pre_widths[k] = pre.widths[k];
                }
                const active_count = @min(@as(usize, pre.col_count), table_cell_count);
                state.table_active = true;
                state.table_col_count = pre.col_count;
                var copy_idx: usize = 0;
                while (copy_idx < pre.col_count) : (copy_idx += 1) {
                    state.table_widths[copy_idx] = pre_widths[copy_idx];
                }
                if (isMarkdownTableSeparator(table_cells[0..table_cell_count])) {
                    try renderMarkdownTableBorder(writer, pre_widths[0..pre.col_count], options);
                } else {
                    try renderMarkdownTableRow(writer, table_cells[0..active_count], pre_widths[0..pre.col_count], options);
                }
                return;
            }

            if (isMarkdownTableSeparator(table_cells[0..table_cell_count])) {
                if (!state.table_active or state.table_col_count != table_cell_count) {
                    state.table_active = true;
                    state.table_col_count = table_cell_count;
                    var sep_idx: usize = 0;
                    while (sep_idx < table_cell_count and sep_idx < state.table_widths.len) : (sep_idx += 1) {
                        state.table_widths[sep_idx] = @max(@as(usize, 3), table_cells[sep_idx].len);
                    }
                } else {
                    var sep_idx: usize = 0;
                    while (sep_idx < table_cell_count and sep_idx < state.table_widths.len) : (sep_idx += 1) {
                        if (table_cells[sep_idx].len > state.table_widths[sep_idx]) {
                            state.table_widths[sep_idx] = table_cells[sep_idx].len;
                        }
                    }
                }
                try renderMarkdownTableBorder(writer, state.table_widths[0..state.table_col_count], options);
                return;
            }

            if (!state.table_active or state.table_col_count != table_cell_count) {
                state.table_active = true;
                state.table_col_count = table_cell_count;
                var init_idx: usize = 0;
                while (init_idx < table_cell_count and init_idx < state.table_widths.len) : (init_idx += 1) {
                    state.table_widths[init_idx] = table_cells[init_idx].len;
                }
            } else {
                var update_idx: usize = 0;
                while (update_idx < table_cell_count and update_idx < state.table_widths.len) : (update_idx += 1) {
                    if (table_cells[update_idx].len > state.table_widths[update_idx]) {
                        state.table_widths[update_idx] = table_cells[update_idx].len;
                    }
                }
            }

            try renderMarkdownTableRow(writer, table_cells[0..table_cell_count], state.table_widths[0..state.table_col_count], options);
            return;
        }
    }

    if (state.table_active) resetTableState(state);

    if (parseMarkdownListMarker(line)) |list| {
        var indent_idx: usize = 0;
        while (indent_idx < list.normalized_indent) : (indent_idx += 1) {
            try writer.writeByte(' ');
        }

        const marker = line[list.marker_start..list.marker_end];
        if (use_color and options.color_lists) {
            try writeColored(writer, marker, listAnsi(options));
        } else {
            try writer.writeAll(marker);
        }
        try writer.writeByte(' ');

        if (list.body_start < line.len) {
            try writeMarkdownInline(writer, line[list.body_start..], options, true);
        }
        return;
    }

    try writer.writeAll(line[0..idx]);
    try writeMarkdownInline(writer, line[idx..], options, true);
}

pub const InlineStyle = enum {
    bold,
    italic,
    bold_italic,
    code,
    strike,
};

pub const HeadingInfo = struct {
    level: u8,
    text_start: usize,
};

pub const ListMarkerInfo = struct {
    marker_start: usize,
    marker_end: usize,
    body_start: usize,
    normalized_indent: usize,
};

pub fn resetTableState(state: *MarkdownRenderState) void {
    state.table_active = false;
    state.table_col_count = 0;
    state.table_widths = [_]usize{0} ** TABLE_MAX_COLUMNS;
}

pub fn parseMarkdownTableRow(line: []const u8, cells_out: *[TABLE_MAX_COLUMNS][]const u8, count_out: *usize) bool {
    count_out.* = 0;
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '|') == null) return false;
    if (trimmed[0] != '|' and trimmed[trimmed.len - 1] != '|') return false;

    var start: usize = 0;
    var end = trimmed.len;
    if (trimmed[0] == '|') start = 1;
    if (end > start and trimmed[end - 1] == '|') end -= 1;
    if (end <= start) return false;

    const body = trimmed[start..end];
    var seg_start: usize = 0;
    var i: usize = 0;
    while (true) {
        if (i == body.len or body[i] == '|') {
            if (count_out.* >= cells_out.len) return false;
            const cell = std.mem.trim(u8, body[seg_start..i], " \t");
            cells_out[count_out.*] = cell;
            count_out.* += 1;
            if (i == body.len) break;
            seg_start = i + 1;
        }
        i += 1;
    }

    return count_out.* >= 2;
}

pub fn isMarkdownTableSeparator(cells: []const []const u8) bool {
    if (cells.len == 0) return false;
    for (cells) |cell| {
        if (!tableCellIsSeparator(cell)) return false;
    }
    return true;
}

fn tableCellIsSeparator(cell: []const u8) bool {
    const trimmed = std.mem.trim(u8, cell, " \t");
    if (trimmed.len == 0) return false;
    var has_dash = false;
    for (trimmed) |ch| {
        switch (ch) {
            '-' => has_dash = true,
            ':' => {},
            else => return false,
        }
    }
    return has_dash;
}

fn renderMarkdownTableBorder(writer: anytype, widths: []const usize, options: anytype) !void {
    const use_color = shouldUseColor(options);
    if (use_color and options.highlight_code_blocks) try writer.writeAll(codeFenceAnsi(options));
    for (widths) |cell_width| {
        try writer.writeAll("\xe2\x94\xbc"); // cross
        var i: usize = 0;
        const dashes = cell_width + 2;
        while (i < dashes) : (i += 1) {
            try writer.writeAll(BOX_H);
        }
    }
    try writer.writeAll("\xe2\x94\xbc"); // cross
    if (use_color and options.highlight_code_blocks) try writer.writeAll(ANSI_RESET);
}

fn renderMarkdownTableRow(writer: anytype, cells: []const []const u8, widths: []const usize, options: anytype) !void {
    const use_color = shouldUseColor(options);
    var i: usize = 0;
    while (i < cells.len and i < widths.len) : (i += 1) {
        if (use_color and options.highlight_code_blocks) {
            try writer.writeAll(codeFenceAnsi(options));
        }
        try writer.writeAll(BOX_V);
        if (use_color and options.highlight_code_blocks) {
            try writer.writeAll(ANSI_RESET);
        }
        try writer.writeByte(' ');

        try writeMarkdownInline(writer, cells[i], options, true);

        var pad: usize = if (widths[i] > cells[i].len) widths[i] - cells[i].len else 0;
        while (pad > 0) : (pad -= 1) {
            try writer.writeByte(' ');
        }
        try writer.writeByte(' ');
    }

    if (use_color and options.highlight_code_blocks) {
        try writer.writeAll(codeFenceAnsi(options));
    }
    try writer.writeAll(BOX_V);
    if (use_color and options.highlight_code_blocks) {
        try writer.writeAll(ANSI_RESET);
    }
}

pub fn parseMarkdownListMarker(line: []const u8) ?ListMarkerInfo {
    var i: usize = 0;
    var indent_cols: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {
        indent_cols += if (line[i] == '\t') 4 else 1;
    }
    if (i >= line.len) return null;

    var marker_end: usize = 0;
    if (line[i] == '-' or line[i] == '*' or line[i] == '+') {
        marker_end = i + 1;
    } else {
        var j = i;
        while (j < line.len and std.ascii.isDigit(line[j])) : (j += 1) {}
        if (j == i or j >= line.len or (line[j] != '.' and line[j] != ')')) return null;
        marker_end = j + 1;
    }

    if (marker_end >= line.len or (line[marker_end] != ' ' and line[marker_end] != '\t')) return null;

    var body_start = marker_end;
    while (body_start < line.len and (line[body_start] == ' ' or line[body_start] == '\t')) : (body_start += 1) {}

    const normalized_indent = if (indent_cols == 0) 0 else @max(@as(usize, 2), @as(usize, @divFloor(indent_cols + 1, 2) * 2));
    return .{
        .marker_start = i,
        .marker_end = marker_end,
        .body_start = body_start,
        .normalized_indent = normalized_indent,
    };
}

pub fn writeMarkdownInline(writer: anytype, text: []const u8, options: anytype, allow_token_highlight: bool) !void {
    if (text.len == 0) return;

    var i: usize = 0;
    var plain_start: usize = 0;
    while (i < text.len) {
        if (text[i] == '\\' and i + 1 < text.len and isMarkdownEscapeTarget(text[i + 1])) {
            try flushInlinePlain(writer, text[plain_start..i], options, allow_token_highlight);
            try writer.writeByte(text[i + 1]);
            i += 2;
            plain_start = i;
            continue;
        }

        if (text[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |end| {
                try flushInlinePlain(writer, text[plain_start..i], options, allow_token_highlight);
                try writeInlineStyleSpan(writer, text[i + 1 .. end], options, .code);
                i = end + 1;
                plain_start = i;
                continue;
            }
        }

        if (i + 3 <= text.len and (std.mem.eql(u8, text[i .. i + 3], "***") or std.mem.eql(u8, text[i .. i + 3], "___"))) {
            const delimiter = text[i .. i + 3];
            if (findClosingDelimiter(text, i + 3, delimiter)) |end| {
                if (end > i + 3) {
                    try flushInlinePlain(writer, text[plain_start..i], options, allow_token_highlight);
                    try writeInlineStyleSpan(writer, text[i + 3 .. end], options, .bold_italic);
                    i = end + 3;
                    plain_start = i;
                    continue;
                }
            }
        }

        if (i + 2 <= text.len and (std.mem.eql(u8, text[i .. i + 2], "**") or std.mem.eql(u8, text[i .. i + 2], "__"))) {
            const delimiter = text[i .. i + 2];
            if (findClosingDelimiter(text, i + 2, delimiter)) |end| {
                if (end > i + 2) {
                    try flushInlinePlain(writer, text[plain_start..i], options, allow_token_highlight);
                    try writeInlineStyleSpan(writer, text[i + 2 .. end], options, .bold);
                    i = end + 2;
                    plain_start = i;
                    continue;
                }
            }
        }

        if (i + 2 <= text.len and std.mem.eql(u8, text[i .. i + 2], "~~")) {
            if (findClosingDelimiter(text, i + 2, "~~")) |end| {
                if (end > i + 2) {
                    try flushInlinePlain(writer, text[plain_start..i], options, allow_token_highlight);
                    try writeInlineStyleSpan(writer, text[i + 2 .. end], options, .strike);
                    i = end + 2;
                    plain_start = i;
                    continue;
                }
            }
        }

        if ((text[i] == '*' or text[i] == '_') and isSingleDelimiterBoundary(text, i)) {
            const delimiter = text[i];
            if (findClosingSingleDelimiter(text, i + 1, delimiter)) |end| {
                if (end > i + 1) {
                    try flushInlinePlain(writer, text[plain_start..i], options, allow_token_highlight);
                    try writeInlineStyleSpan(writer, text[i + 1 .. end], options, .italic);
                    i = end + 1;
                    plain_start = i;
                    continue;
                }
            }
        }

        i += 1;
    }

    try flushInlinePlain(writer, text[plain_start..], options, allow_token_highlight);
}

fn writeInlineStyleSpan(writer: anytype, text: []const u8, options: anytype, style: InlineStyle) !void {
    if (text.len == 0) return;
    const use_color = shouldUseColor(options);

    switch (style) {
        .code => {
            if (use_color and options.highlight_code_blocks) {
                try writeColored(writer, text, codeFenceAnsi(options));
            } else {
                try writer.writeAll(text);
            }
            return;
        },
        .bold => if (use_color) try writer.writeAll(ANSI_BOLD),
        .italic => if (use_color) try writer.writeAll(ANSI_ITALIC),
        .bold_italic => if (use_color) try writer.writeAll(ANSI_BOLD_ITALIC),
        .strike => if (use_color) try writer.writeAll(ANSI_DIM),
    }

    try writer.writeAll(text);

    if (use_color) {
        try writer.writeAll(ANSI_RESET);
    }
}

fn flushInlinePlain(writer: anytype, text: []const u8, options: anytype, allow_token_highlight: bool) !void {
    if (text.len == 0) return;
    if (allow_token_highlight) {
        try writeHighlightedTokens(writer, text, options);
    } else {
        try writer.writeAll(text);
    }
}

pub fn writeCodeFenceMarker(writer: anytype, fence_tag: []const u8, entering: bool, options: anytype) !void {
    const clean_tag = std.mem.trim(u8, fence_tag, " \t");
    const use_color = shouldUseColor(options) and options.highlight_code_blocks;

    if (use_color) try writer.writeAll(codeFenceAnsi(options));

    if (entering) {
        try writer.writeAll("\xe2\x94\x80\xe2\x94\x80 "); // horizontal lines + space
        if (clean_tag.len > 0) {
            if (use_color) try writer.writeAll(ANSI_RESET);
            if (use_color) try writer.writeAll(ANSI_DIM);
            try writer.writeAll(clean_tag);
            if (use_color) try writer.writeAll(ANSI_RESET);
            if (use_color) try writer.writeAll(codeFenceAnsi(options));
        }
        try writer.writeAll(" \xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80"); // horizontal lines
    } else {
        try writer.writeAll("\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80"); // horizontal lines
    }

    if (use_color) try writer.writeAll(ANSI_RESET);
}

pub fn parseMarkdownHeading(line: []const u8, start: usize) ?HeadingInfo {
    if (start >= line.len) return null;
    var i = start;
    var level: u8 = 0;
    while (i < line.len and line[i] == '#' and level < 6) : (i += 1) {
        level += 1;
    }
    if (level == 0) return null;
    if (i >= line.len) return null;
    if (line[i] == ' ') {
        return .{
            .level = level,
            .text_start = i + 1,
        };
    }
    if (line[i] == '#') return null;
    return .{
        .level = level,
        .text_start = i,
    };
}

pub fn parseMarkdownQuote(line: []const u8, start: usize) ?usize {
    if (start >= line.len) return null;
    if (line[start] != '>') return null;

    var i = start;
    while (i < line.len and line[i] == '>') : (i += 1) {}
    if (i < line.len and line[i] == ' ') i += 1;
    return i;
}

pub fn looksLikeHorizontalRule(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len < 3) return false;

    const ch = trimmed[0];
    if (ch != '-' and ch != '*' and ch != '_') return false;
    for (trimmed) |c| {
        if (c != ch) return false;
    }
    return true;
}

pub fn isMarkdownEscapeTarget(ch: u8) bool {
    return ch == '\\' or ch == '`' or ch == '*' or ch == '_' or ch == '~' or ch == '[' or ch == ']' or ch == '(' or ch == ')' or ch == '#';
}

pub fn findClosingDelimiter(text: []const u8, start: usize, delimiter: []const u8) ?usize {
    var pos = start;
    while (std.mem.indexOfPos(u8, text, pos, delimiter)) |idx| {
        // Skip matches that are backslash-escaped. Previously `**foo\**bar**`
        // closed at the escaped `\**` and rendered as `foo\` + loose `bar**`.
        // A leading `\` counts as an escape only when itself not escaped, so
        // we walk backwards to count consecutive backslashes and treat the
        // match as escaped iff the count is odd.
        if (isEscapedAt(text, idx)) {
            pos = idx + 1;
            continue;
        }
        if (idx > start) return idx;
        pos = idx + delimiter.len;
    }
    return null;
}

pub fn findClosingSingleDelimiter(text: []const u8, start: usize, delimiter: u8) ?usize {
    var pos = start;
    while (std.mem.indexOfScalarPos(u8, text, pos, delimiter)) |idx| {
        if (isEscapedAt(text, idx)) {
            pos = idx + 1;
            continue;
        }
        if (idx > start and isSingleDelimiterBoundary(text, idx)) return idx;
        pos = idx + 1;
    }
    return null;
}

/// Return true if the byte at `idx` is preceded by an odd number of
/// contiguous backslashes, meaning it is markdown-escaped. Even counts
/// (or zero) mean the character is literal and the closing delimiter
/// should match.
fn isEscapedAt(text: []const u8, idx: usize) bool {
    var backslashes: usize = 0;
    var i = idx;
    while (i > 0 and text[i - 1] == '\\') : (i -= 1) backslashes += 1;
    return (backslashes & 1) == 1;
}

pub fn isSingleDelimiterBoundary(text: []const u8, idx: usize) bool {
    const prev = if (idx == 0) 0 else text[idx - 1];
    const next = if (idx + 1 >= text.len) 0 else text[idx + 1];

    const prev_word = prev != 0 and (std.ascii.isAlphanumeric(prev) or prev == '_');
    const next_word = next != 0 and (std.ascii.isAlphanumeric(next) or next == '_');
    return !(prev_word and next_word);
}

pub fn parseCodeFence(line: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i + 3 > line.len) return null;
    if (!std.mem.startsWith(u8, line[i..], "```")) return null;
    return std.mem.trim(u8, line[i + 3 ..], " \t");
}

pub fn parseCodeLang(tag: []const u8) CodeLang {
    const clean = std.mem.trim(u8, tag, " \t");
    if (clean.len == 0) return .plain;
    if (startsWithIgnoreCase(clean, "zig")) return .zig;
    if (startsWithIgnoreCase(clean, "go")) return .go;
    if (startsWithIgnoreCase(clean, "ts") or startsWithIgnoreCase(clean, "typescript")) return .typescript;
    if (startsWithIgnoreCase(clean, "js") or startsWithIgnoreCase(clean, "javascript")) return .javascript;
    if (startsWithIgnoreCase(clean, "json")) return .json;
    if (startsWithIgnoreCase(clean, "bash") or startsWithIgnoreCase(clean, "sh") or startsWithIgnoreCase(clean, "zsh")) return .bash;
    if (startsWithIgnoreCase(clean, "py") or startsWithIgnoreCase(clean, "python")) return .python;
    if (startsWithIgnoreCase(clean, "yaml") or startsWithIgnoreCase(clean, "yml")) return .yaml;
    if (startsWithIgnoreCase(clean, "toml")) return .toml;
    return .plain;
}

pub fn looksLikeStandaloneCodeLine(line: []const u8) bool {
    var idx: usize = 0;
    while (idx < line.len and (line[idx] == ' ' or line[idx] == '\t')) : (idx += 1) {}
    if (idx >= line.len) return false;

    if (parseCodeFence(line) != null) return false;
    if (parseMarkdownHeading(line, idx) != null) return false;
    if (parseMarkdownQuote(line, idx) != null) return false;
    if (parseMarkdownListMarker(line) != null) return false;
    if (looksLikeHorizontalRule(line[idx..])) return false;

    var table_cells: [TABLE_MAX_COLUMNS][]const u8 = undefined;
    var table_cell_count: usize = 0;
    if (parseMarkdownTableRow(line, &table_cells, &table_cell_count)) return false;

    const text = std.mem.trim(u8, line[idx..], " \t");
    if (text.len < 2) return false;

    if (isLikelyToolWrapperLine(text)) return false;

    var score: usize = 0;
    if (startsWithIgnoreCase(text, "const ") or
        startsWithIgnoreCase(text, "let ") or
        startsWithIgnoreCase(text, "var ") or
        startsWithIgnoreCase(text, "package ") or
        startsWithIgnoreCase(text, "func ") or
        startsWithIgnoreCase(text, "import ") or
        startsWithIgnoreCase(text, "export ") or
        startsWithIgnoreCase(text, "function ") or
        startsWithIgnoreCase(text, "class ") or
        startsWithIgnoreCase(text, "interface ") or
        startsWithIgnoreCase(text, "type ") or
        startsWithIgnoreCase(text, "return ") or
        startsWithIgnoreCase(text, "if (") or
        startsWithIgnoreCase(text, "for (") or
        startsWithIgnoreCase(text, "while (") or
        startsWithIgnoreCase(text, "catch ") or
        startsWithIgnoreCase(text, "throw ") or
        startsWithIgnoreCase(text, "pub fn ") or
        startsWithIgnoreCase(text, "fn "))
    {
        score += 2;
    }

    if (std.mem.indexOf(u8, text, "=>") != null) score += 2;
    if (std.mem.indexOf(u8, text, "::") != null) score += 1;
    if (std.mem.indexOf(u8, text, "//") != null) score += 2;
    if (std.mem.indexOf(u8, text, "/*") != null) score += 2;
    if (std.mem.indexOf(u8, text, " = ") != null) score += 1;
    if (std.mem.indexOfScalar(u8, text, '{') != null or std.mem.indexOfScalar(u8, text, '}') != null) score += 1;
    if (std.mem.indexOfScalar(u8, text, '(') != null and std.mem.indexOfScalar(u8, text, ')') != null) score += 1;

    if (std.mem.endsWith(u8, text, ";") or
        std.mem.endsWith(u8, text, "{") or
        std.mem.endsWith(u8, text, "}") or
        std.mem.endsWith(u8, text, "},") or
        std.mem.endsWith(u8, text, ");"))
    {
        score += 1;
    }

    return score >= 2;
}

pub fn detectStandaloneCodeLang(line: []const u8) CodeLang {
    const text = std.mem.trim(u8, line, " \t");
    if (text.len == 0) return .plain;

    if (std.mem.startsWith(u8, text, "#!") or std.mem.startsWith(u8, text, "$ ")) return .bash;

    const json_like = (std.mem.startsWith(u8, text, "{") or std.mem.startsWith(u8, text, "[")) and
        std.mem.indexOfScalar(u8, text, ':') != null and
        std.mem.indexOfScalar(u8, text, '"') != null;
    if (json_like) return .json;

    if (startsWithIgnoreCase(text, "package ") or
        startsWithIgnoreCase(text, "func ") or
        startsWithIgnoreCase(text, "type ") or
        std.mem.indexOf(u8, text, " := ") != null)
    {
        return .go;
    }

    if (std.mem.indexOf(u8, text, "@import") != null or
        startsWithIgnoreCase(text, "pub fn ") or
        startsWithIgnoreCase(text, "fn ") or
        startsWithIgnoreCase(text, "comptime "))
    {
        return .zig;
    }

    if (std.mem.indexOf(u8, text, "interface ") != null or
        std.mem.indexOf(u8, text, ": string") != null or
        std.mem.indexOf(u8, text, ": number") != null or
        std.mem.indexOf(u8, text, ": boolean") != null or
        std.mem.indexOf(u8, text, " as const") != null or
        std.mem.indexOf(u8, text, "=>") != null)
    {
        return .typescript;
    }

    if (startsWithIgnoreCase(text, "import ") or
        startsWithIgnoreCase(text, "export ") or
        startsWithIgnoreCase(text, "const ") or
        startsWithIgnoreCase(text, "let ") or
        startsWithIgnoreCase(text, "var "))
    {
        return .javascript;
    }

    return .plain;
}

pub fn isLikelyToolWrapperLine(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len == 0) return false;
    if (startsWithIgnoreCase(t, "<tool_call")) return true;
    if (startsWithIgnoreCase(t, "</tool_call")) return true;
    if (startsWithIgnoreCase(t, "<tool_calls")) return true;
    if (startsWithIgnoreCase(t, "</tool_calls")) return true;
    if (startsWithIgnoreCase(t, "[tool_call")) return true;
    if (startsWithIgnoreCase(t, "[/tool_call")) return true;
    return false;
}

pub fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    if (prefix.len > text.len) return false;
    var i: usize = 0;
    while (i < prefix.len) : (i += 1) {
        if (std.ascii.toLower(text[i]) != std.ascii.toLower(prefix[i])) return false;
    }
    return true;
}

pub fn writeCodeLine(writer: anytype, line: []const u8, lang: CodeLang, options: anytype) !void {
    if (!shouldUseColor(options) or !options.highlight_code_blocks or line.len == 0) {
        try writer.writeAll(line);
        return;
    }

    var i: usize = 0;
    while (i < line.len) {
        if (commentPrefixLen(line, i, lang)) |prefix_len| {
            try writeColored(writer, line[i..], codeCommentAnsi(options));
            _ = prefix_len;
            return;
        }

        const ch = line[i];
        if (ch == '"' or ch == '\'' or ch == '`') {
            const end = scanStringEnd(line, i + 1, ch);
            try writeColored(writer, line[i..end], codeStringAnsi(options));
            i = end;
            continue;
        }

        if (std.ascii.isDigit(ch)) {
            const end = scanNumberEnd(line, i);
            try writeColored(writer, line[i..end], codeNumberAnsi(options));
            i = end;
            continue;
        }

        if (isIdentStart(ch)) {
            const end = scanIdentEnd(line, i);
            const ident = line[i..end];
            if (isCodeKeyword(lang, ident)) {
                try writeColored(writer, ident, codeKeywordAnsi(options));
            } else {
                try writer.writeAll(ident);
            }
            i = end;
            continue;
        }

        try writer.writeByte(ch);
        i += 1;
    }
}

fn commentPrefixLen(line: []const u8, idx: usize, lang: CodeLang) ?usize {
    if (idx >= line.len) return null;
    if (idx + 1 < line.len and line[idx] == '/' and line[idx + 1] == '/') return 2;

    if ((lang == .bash or lang == .python or lang == .yaml or lang == .toml) and line[idx] == '#') {
        return 1;
    }

    return null;
}

fn scanStringEnd(line: []const u8, start: usize, quote: u8) usize {
    var i = start;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\' and i + 1 < line.len) {
            i += 1;
            continue;
        }
        if (line[i] == quote) {
            return i + 1;
        }
    }
    return line.len;
}

fn scanNumberEnd(line: []const u8, start: usize) usize {
    var i = start;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (!std.ascii.isDigit(ch) and ch != '.' and ch != '_' and ch != 'x' and ch != 'X' and ch != 'a' and ch != 'b' and ch != 'c' and ch != 'd' and ch != 'e' and ch != 'f' and ch != 'A' and ch != 'B' and ch != 'C' and ch != 'D' and ch != 'E' and ch != 'F') {
            break;
        }
    }
    return i;
}

fn isIdentStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isIdentContinue(ch: u8) bool {
    return isIdentStart(ch) or std.ascii.isDigit(ch);
}

fn scanIdentEnd(line: []const u8, start: usize) usize {
    var i = start;
    while (i < line.len and isIdentContinue(line[i])) : (i += 1) {}
    return i;
}

fn isCodeKeyword(lang: CodeLang, ident: []const u8) bool {
    return switch (lang) {
        .zig => inKeywordSet(ident, &[_][]const u8{
            "const", "var",   "fn",       "pub",       "struct",  "enum",   "union",
            "if",    "else",  "switch",   "for",       "while",   "return", "try",
            "catch", "defer", "errdefer", "comptime",  "asm",     "break",  "continue",
            "true",  "false", "null",     "undefined", "anytype",
        }),
        .go => inKeywordSet(ident, &[_][]const u8{
            "package", "import", "func",   "var",   "const",    "type",        "struct", "interface",
            "map",     "chan",   "go",     "defer", "if",       "else",        "switch", "case",
            "for",     "range",  "return", "break", "continue", "fallthrough", "select", "true",
            "false",   "nil",
        }),
        .typescript, .javascript => inKeywordSet(ident, &[_][]const u8{
            "const",     "let",        "var",   "function", "class",  "interface", "type",
            "extends",   "implements", "if",    "else",     "switch", "case",      "for",
            "while",     "return",     "try",   "catch",    "throw",  "new",       "import",
            "from",      "export",     "async", "await",    "true",   "false",     "null",
            "undefined",
        }),
        .json => inKeywordSet(ident, &[_][]const u8{ "true", "false", "null" }),
        .bash => inKeywordSet(ident, &[_][]const u8{
            "if", "then", "else", "fi", "for", "in", "do", "done", "case", "esac", "function",
        }),
        .python => inKeywordSet(ident, &[_][]const u8{
            "def",   "class",  "if",      "elif",   "else", "for", "while", "return",
            "try",   "except", "finally", "import", "from", "as",  "with",  "True",
            "False", "None",   "async",   "await",
        }),
        .yaml, .toml => inKeywordSet(ident, &[_][]const u8{ "true", "false", "null" }),
        .plain => false,
    };
}

fn inKeywordSet(ident: []const u8, set: []const []const u8) bool {
    for (set) |keyword| {
        if (std.mem.eql(u8, ident, keyword)) return true;
    }
    return false;
}

fn writeHighlightedTokens(writer: anytype, text: []const u8, options: anytype) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (std.ascii.isWhitespace(text[i])) {
            try writer.writeByte(text[i]);
            i += 1;
            continue;
        }

        const start = i;
        while (i < text.len and !std.ascii.isWhitespace(text[i])) : (i += 1) {}
        try writeStyledToken(writer, text[start..i], options);
    }
}

const TokenCore = struct {
    core_start: usize,
    core_end: usize,
};

fn writeStyledToken(writer: anytype, token: []const u8, options: anytype) !void {
    const use_color = shouldUseColor(options);
    const core = trimTokenCore(token);
    if (core.core_start >= core.core_end) {
        try writer.writeAll(token);
        return;
    }

    const prefix = token[0..core.core_start];
    const body = token[core.core_start..core.core_end];
    const suffix = token[core.core_end..];

    try writer.writeAll(prefix);
    if (use_color and options.highlight_links and looksLikeLink(body)) {
        // Wrap the styled URL in an OSC 8 hyperlink so modern
        // terminals (iTerm2, Kitty, Ghostty, WezTerm, VS Code, Windows
        // Terminal) render it as a clickable link. SGR coloring is
        // applied INSIDE the OSC 8 brackets because some terminals
        // reset colour at OSC 8 boundaries. Falls back to plain
        // coloured text when the terminal can't render hyperlinks.
        const format_mod_local = @import("../core/format.zig");
        try writer.writeAll(linkAnsi(options));
        try format_mod_local.writeHyperlink(writer, body, body);
        try writer.writeAll(ANSI_RESET);
    } else if (use_color and options.highlight_paths and looksLikePath(body)) {
        try writeColored(writer, body, pathAnsi(options));
    } else {
        try writer.writeAll(body);
    }
    try writer.writeAll(suffix);
}

pub fn writeColored(writer: anytype, text: []const u8, color: []const u8) !void {
    try writer.writeAll(color);
    try writer.writeAll(text);
    try writer.writeAll(ANSI_RESET);
}

fn trimTokenCore(token: []const u8) TokenCore {
    var start: usize = 0;
    var end: usize = token.len;

    while (start < end and isLeadingWrapper(token[start])) : (start += 1) {}
    while (end > start and isTrailingWrapper(token[end - 1])) : (end -= 1) {}

    return .{ .core_start = start, .core_end = end };
}

fn isLeadingWrapper(ch: u8) bool {
    return ch == '(' or ch == '[' or ch == '{' or ch == '"' or ch == '\'' or ch == '`' or ch == '<';
}

fn isTrailingWrapper(ch: u8) bool {
    return ch == ')' or ch == ']' or ch == '}' or ch == '"' or ch == '\'' or ch == '`' or ch == '>' or ch == ',' or ch == '.' or ch == ';' or ch == ':' or ch == '!' or ch == '?';
}

pub fn looksLikeLink(token: []const u8) bool {
    if (std.mem.startsWith(u8, token, "http://")) return true;
    if (std.mem.startsWith(u8, token, "https://")) return true;
    if (std.mem.startsWith(u8, token, "www.")) return true;
    return false;
}

pub fn looksLikePath(token: []const u8) bool {
    if (token.len == 0) return false;
    if (looksLikeLink(token)) return false;
    if (std.mem.startsWith(u8, token, "/")) return true;
    if (std.mem.startsWith(u8, token, "./")) return true;
    if (std.mem.startsWith(u8, token, "../")) return true;
    if (std.mem.startsWith(u8, token, "~/")) return true;
    if (std.mem.indexOfScalar(u8, token, '/') != null) return true;
    if (std.mem.indexOfScalar(u8, token, '\\') != null) return true;
    return false;
}

pub const LineRenderKind = enum {
    plain,
    code,
    fence,
    auto_code,
    hidden,
};

pub fn classifyLineRenderKind(line: []const u8, state: *const MarkdownRenderState) LineRenderKind {
    if (isLikelyToolWrapperLine(line)) return .hidden;
    if (parseCodeFence(line) != null) return .fence;
    if (state.in_code_block) return .code;
    if (looksLikeStandaloneCodeLine(line)) return .auto_code;
    return .plain;
}

pub fn advanceMarkdownStateForLine(line: []const u8, state: *MarkdownRenderState) void {
    const fence = parseCodeFence(line) orelse return;
    if (state.in_code_block) {
        state.in_code_block = false;
        state.code_lang = .plain;
    } else {
        state.in_code_block = true;
        state.code_lang = parseCodeLang(fence);
    }
}

pub const containsIgnoreCase = @import("../core/parse_helpers.zig").containsIgnoreCase;

const testing = std.testing;

test "parseCodeFence and parseCodeLang detect zig fences" {
    const fence = parseCodeFence("```zig");
    try testing.expect(fence != null);
    try testing.expect(parseCodeLang(fence.?) == .zig);
}

test "parseCodeLang detects go fences" {
    try testing.expect(parseCodeLang("go") == .go);
}

test "looksLikeStandaloneCodeLine detects common code and skips prose" {
    try testing.expect(looksLikeStandaloneCodeLine("const providerPlan = buildProviderPlan({"));
    try testing.expect(looksLikeStandaloneCodeLine("package config"));
    try testing.expect(looksLikeStandaloneCodeLine("throw new Error(\"No providers\");"));
    try testing.expect(!looksLikeStandaloneCodeLine("What would you like to do?"));
    try testing.expect(!looksLikeStandaloneCodeLine("- Run tests"));
}

test "classifyLineRenderKind marks auto code lines outside fences" {
    var state = MarkdownRenderState{};
    try testing.expectEqual(LineRenderKind.auto_code, classifyLineRenderKind("import { x } from \"./x\";", &state));
    try testing.expectEqual(LineRenderKind.plain, classifyLineRenderKind("General explanation line", &state));
}

test "parseMarkdownHeading accepts heading without separating space" {
    const parsed = parseMarkdownHeading("###Heading", 0);
    try testing.expect(parsed != null);
    try testing.expectEqual(@as(u8, 3), parsed.?.level);
    try testing.expectEqual(@as(usize, 3), parsed.?.text_start);
}

test "parseMarkdownListMarker recognizes ordered items" {
    const parsed = parseMarkdownListMarker("   12. do task");
    try testing.expect(parsed != null);
    try testing.expectEqual(@as(usize, 3), parsed.?.marker_start);
    try testing.expectEqual(@as(usize, 6), parsed.?.marker_end);
    try testing.expectEqual(@as(usize, 4), parsed.?.normalized_indent);
}

test "writeStyledText strips markdown emphasis markers" {
    var out = std_io.StringBuilder.init(testing.allocator);
    defer out.deinit();

    const options = .{
        .color_enabled = false,
        .highlight_links = false,
        .highlight_paths = false,
        .color_lists = false,
        .highlight_code_blocks = false,
    };
    try writeStyledText(out.writer(), "**bold** *italic* ~~strike~~", options);

    try testing.expect(std.mem.indexOf(u8, out.items(), "**") == null);
    try testing.expect(std.mem.indexOf(u8, out.items(), "*italic*") == null);
    try testing.expect(std.mem.indexOf(u8, out.items(), "~~") == null);
    try testing.expect(std.mem.indexOf(u8, out.items(), "bold") != null);
    try testing.expect(std.mem.indexOf(u8, out.items(), "italic") != null);
    try testing.expect(std.mem.indexOf(u8, out.items(), "strike") != null);
}

test "stripAnsiInto removes CSI SGR and OSC title sequences" {
    var buf: [128]u8 = undefined;
    const input = "plain\x1b[31mred\x1b[0m tail\x1b]0;window\x07end";
    const out = stripAnsiInto(&buf, input);
    try testing.expectEqualStrings("plainred tailend", out);
}

test "writeStyledText strips ANSI escapes from input and does not leak OSC title" {
    var out = std_io.StringBuilder.init(testing.allocator);
    defer out.deinit();

    const options = .{
        .color_enabled = false,
        .highlight_links = false,
        .highlight_paths = false,
        .color_lists = false,
        .highlight_code_blocks = false,
    };
    try writeStyledText(out.writer(), "hello\x1b]0;OWNED\x07 world\x1b[31m!", options);

    // With color disabled the output should contain the plain text and
    // no 0x1b bytes at all.
    try testing.expect(std.mem.indexOf(u8, out.items(), "hello") != null);
    try testing.expect(std.mem.indexOf(u8, out.items(), "world") != null);
    try testing.expect(std.mem.indexOf(u8, out.items(), "\x1b") == null);
    try testing.expect(std.mem.indexOf(u8, out.items(), "OWNED") == null);
}

test "writeStyledText renders markdown table separator as ascii border" {
    var out = std_io.StringBuilder.init(testing.allocator);
    defer out.deinit();

    const options = .{
        .color_enabled = false,
        .highlight_links = false,
        .highlight_paths = false,
        .color_lists = false,
        .highlight_code_blocks = false,
    };
    try writeStyledText(
        out.writer(),
        "| Name | Score |\n| --- | --- |\n| Bob | 10 |",
        options,
    );

    try testing.expect(std.mem.indexOf(u8, out.items(), "\xe2\x94\xbc") != null);
    try testing.expect(std.mem.indexOf(u8, out.items(), "Bob") != null);
    try testing.expect(std.mem.indexOf(u8, out.items(), "10") != null);
}

test "writeStyledText normalizes uneven nested list indentation" {
    var out = std_io.StringBuilder.init(testing.allocator);
    defer out.deinit();

    const options = .{
        .color_enabled = false,
        .highlight_links = false,
        .highlight_paths = false,
        .color_lists = false,
        .highlight_code_blocks = false,
    };
    try writeStyledText(out.writer(), "   - parent\n\t- child", options);

    try testing.expect(std.mem.indexOf(u8, out.items(), "    - parent") != null);
    try testing.expect(std.mem.indexOf(u8, out.items(), "    - child") != null);
}

test "writeStyledText aligns table columns when later rows are wider than header" {
    // Regression: user reported misaligned tool-listing table. The header
    // row was narrower than wide data rows, causing columns to drift.
    // precomputeTables + the two-pass render must now line every row up
    // against the widest cell in each column.
    var out = std_io.StringBuilder.init(testing.allocator);
    defer out.deinit();

    const options = .{
        .color_enabled = false,
        .highlight_links = false,
        .highlight_paths = false,
        .color_lists = false,
        .highlight_code_blocks = false,
    };
    try writeStyledText(
        out.writer(),
        "| Cat | Tool | Desc |\n" ++
            "|-----|------|------|\n" ++
            "| Network Scanning | nmap_scan | Port and service scanning |\n" ++
            "| Network Scanning | gobuster_scan | Directory brute-forcing |\n",
        options,
    );

    // Count the number of vertical bars at each row start to verify alignment.
    var lines = std.mem.splitScalar(u8, out.items(), '\n');
    var bar_line_count: usize = 0;
    var bar_line_widths: [8]usize = undefined;
    while (lines.next()) |l| {
        if (std.mem.indexOf(u8, l, "\xe2\x94\x82")) |_| {
            // Count characters between first and last box-drawing vertical
            // marker on this row as a proxy for row display width. Because
            // they should all be equal after our fix.
            if (bar_line_count < bar_line_widths.len) {
                bar_line_widths[bar_line_count] = l.len;
                bar_line_count += 1;
            }
        }
    }
    try testing.expect(bar_line_count >= 3);
    var max_w: usize = 0;
    var min_w: usize = std.math.maxInt(usize);
    var idx: usize = 0;
    while (idx < bar_line_count) : (idx += 1) {
        if (bar_line_widths[idx] > max_w) max_w = bar_line_widths[idx];
        if (bar_line_widths[idx] < min_w) min_w = bar_line_widths[idx];
    }
    // Every row must be the same visible width -- zero variance between
    // rows means the columns align across header and body.
    try testing.expectEqual(min_w, max_w);
}

test "precomputeTables records widths for a single well-formed table" {
    const text =
        "| A | BB |\n" ++
        "|---|----|\n" ++
        "| xxxxx | y |\n";
    var state = MarkdownRenderState{};
    precomputeTables(text, &state);
    try testing.expectEqual(@as(u8, 1), state.precomputed_count);
    const entry = state.precomputed_tables[0];
    try testing.expectEqual(@as(u32, 0), entry.start_line);
    try testing.expectEqual(@as(u32, 3), entry.end_line);
    try testing.expectEqual(@as(u8, 2), entry.col_count);
    // Column 0: max("A", "---", "xxxxx") -> 5
    // Column 1: max("BB", "----", "y") -> 4
    try testing.expectEqual(@as(u16, 5), entry.widths[0]);
    try testing.expectEqual(@as(u16, 4), entry.widths[1]);
}

test "precomputeTables handles multiple tables separated by prose" {
    // parseMarkdownTableRow requires at least 2 cells, so each test
    // table here uses 2+ columns.
    const text =
        "| A | B |\n|---|---|\n| y | z |\n" ++
        "\n" ++
        "some prose between them\n" ++
        "\n" ++
        "| P | Q | R |\n|---|---|---|\n| 1 | 2 | 3 |\n";
    var state = MarkdownRenderState{};
    precomputeTables(text, &state);
    try testing.expectEqual(@as(u8, 2), state.precomputed_count);
    try testing.expectEqual(@as(u8, 2), state.precomputed_tables[0].col_count);
    try testing.expectEqual(@as(u8, 3), state.precomputed_tables[1].col_count);
}

test "precomputeTables skips tables inside fenced code blocks" {
    const text =
        "```markdown\n" ++
        "| A | B |\n|---|---|\n| 1 | 2 |\n" ++
        "```\n";
    var state = MarkdownRenderState{};
    precomputeTables(text, &state);
    try testing.expectEqual(@as(u8, 0), state.precomputed_count);
}

test "writeStyledText renders code fences without markdown backticks" {
    var out = std_io.StringBuilder.init(testing.allocator);
    defer out.deinit();

    const options = .{
        .color_enabled = false,
        .highlight_links = false,
        .highlight_paths = false,
        .color_lists = false,
        .highlight_code_blocks = false,
    };
    try writeStyledText(out.writer(), "```typescript\nconst x = 1;\n```", options);

    try testing.expect(std.mem.indexOf(u8, out.items(), "```") == null);
    try testing.expect(std.mem.indexOf(u8, out.items(), "typescript") != null);
    try testing.expect(std.mem.indexOf(u8, out.items(), "\xe2\x94\x80") != null);
}
