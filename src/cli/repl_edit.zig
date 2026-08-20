const std = @import("std");
const repl_spinner = @import("repl_spinner.zig");
const repl_markdown = @import("repl_markdown.zig");
const parse_helpers = @import("../core/parse_helpers.zig");
const word_diff = @import("../core/word_diff.zig");
const env = @import("../core/env.zig");

/// Whether diff-content syntax highlighting is enabled, gated by
/// CLAUDE_CODE_SYNTAX_HIGHLIGHT (parity with the reference's
/// StructuredDiff/colorDiff.ts toggle).
///
/// Default-on to preserve zcode's existing behaviour (context and solo
/// +/- diff lines have always been highlighted); the env var is the
/// override. CLAUDE_CODE_SYNTAX_HIGHLIGHT=0/false/no/off turns it OFF;
/// any other value -- including =1/true and unset -- keeps it ON. This
/// is the documented deliberate deviation from the reference, which
/// gates the feature OFF by default; matching their default would be a
/// visible regression for zcode users who already get highlighted diffs.
///
/// Read once per diff block and threaded down to writeDiffCodeLine so
/// the per-line render path never touches the environment.
pub fn syntaxHighlightEnabled() bool {
    return !env.isEnvDefinedFalsy("CLAUDE_CODE_SYNTAX_HIGHLIGHT");
}

const render_options = .{
    .color_enabled = true,
    .highlight_code_blocks = true,
};

const MAX_DIFF_FILES: usize = 3;
const MAX_HUNKS_PER_FILE: usize = 3;
const MAX_LINES_PER_HUNK: usize = 12;
const MAX_TOOL_LINES_PER_SECTION: usize = 5;

const Tone = enum {
    neutral,
    success,
    warning,
    failure,
    diff,
};

const DiffStats = struct {
    added: usize = 0,
    removed: usize = 0,
    hunks: usize = 0,
    new_file: bool = false,
    deleted_file: bool = false,
};

const ToolSections = struct {
    command: ?[]const u8 = null,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    footer: []const u8 = "",
    is_error: bool = false,
};

pub fn formatEditBlock(out: *[8192]u8, path: []const u8, old_text: []const u8, new_text: []const u8, start_line: usize, success: bool) []const u8 {
    var fbs = std.Io.Writer.fixed(out);
    const w = &fbs;

    const cols = repl_spinner.terminalCols();
    var display_path_buf: [256]u8 = undefined;
    const display_path = clipPathForCard(&display_path_buf, path, cols);
    const is_write = old_text.len == 0 and new_text.len == 0;
    const tone: Tone = if (success) .success else .failure;
    const label = if (is_write) "WRITE" else "EDIT";

    writeCardHeader(w, label, display_path, tone) catch return out[0..fbs.end];

    if (!success) {
        writeCardLine(w, "operation failed", .failure) catch return out[0..fbs.end];
        writeCardFooter(w, "fix arguments and retry", .failure) catch return out[0..fbs.end];
        return out[0..fbs.end];
    }

    if (is_write) {
        writeCardLine(w, "new file created", .success) catch return out[0..fbs.end];
        writeCardFooter(w, "written", .success) catch return out[0..fbs.end];
        return out[0..fbs.end];
    }

    const removed = countLogicalLines(old_text);
    const added = countLogicalLines(new_text);

    var summary_buf: [128]u8 = undefined;
    const summary = std.fmt.bufPrint(&summary_buf, "changes +{d} -{d} at line {d}", .{ added, removed, start_line }) catch "changes";
    writeCardLine(w, summary, .neutral) catch return out[0..fbs.end];

    var hunk_buf: [64]u8 = undefined;
    const hunk = std.fmt.bufPrint(&hunk_buf, "@@ -{d},{d} +{d},{d} @@", .{ start_line, removed, start_line, added }) catch "@@";
    writeCardLine(w, hunk, .diff) catch return out[0..fbs.end];

    const lang = detectLangFromPath(path);
    const content_max = diffContentWidth(cols);
    const syntax_on = syntaxHighlightEnabled();

    var shown: usize = 0;
    var old_line = start_line;
    var old_iter = std.mem.splitScalar(u8, old_text, '\n');
    while (old_iter.next()) |line| {
        if (shown >= MAX_LINES_PER_HUNK) break;
        writeDiffCodeLine(w, .remove, old_line, null, line, lang, content_max, syntax_on) catch return out[0..fbs.end];
        old_line += 1;
        shown += 1;
    }

    var new_line = start_line;
    var new_iter = std.mem.splitScalar(u8, new_text, '\n');
    while (new_iter.next()) |line| {
        if (shown >= MAX_LINES_PER_HUNK) break;
        writeDiffCodeLine(w, .add, null, new_line, line, lang, content_max, syntax_on) catch return out[0..fbs.end];
        new_line += 1;
        shown += 1;
    }

    const total = removed + added;
    if (total > shown) {
        var trunc_buf: [80]u8 = undefined;
        const trunc = std.fmt.bufPrint(&trunc_buf, "... {d} more changed lines omitted", .{total - shown}) catch "...";
        writeCardLine(w, trunc, .warning) catch return out[0..fbs.end];
    }

    writeCardFooter(w, "edited successfully", .success) catch return out[0..fbs.end];
    return out[0..fbs.end];
}

pub fn clipPathForDisplay(path: []const u8, max_cols: usize) []const u8 {
    const budget = if (max_cols > 26) max_cols - 26 else 48;
    if (path.len <= budget) return path;
    return path[path.len - budget ..];
}

pub fn formatDiffBlock(out: *[8192]u8, diff_text: []const u8) []const u8 {
    var fbs = std.Io.Writer.fixed(out);
    var w = &fbs;

    const cols = repl_spinner.terminalCols();
    var cursor: usize = 0;
    var rendered_files: usize = 0;
    var omitted_files: usize = 0;
    var found_sections = false;

    while (std.mem.indexOfPos(u8, diff_text, cursor, "diff --git ")) |start| {
        found_sections = true;
        const next = std.mem.indexOfPos(u8, diff_text, start + 1, "\ndiff --git ");
        const section_end = if (next) |idx| idx + 1 else diff_text.len;
        const section = diff_text[start..section_end];
        cursor = section_end;

        if (rendered_files >= MAX_DIFF_FILES) {
            omitted_files += 1;
            continue;
        }

        if (rendered_files > 0) {
            w.writeByte('\n') catch return out[0..fbs.end];
        }

        renderDiffSection(w, section, cols) catch return out[0..fbs.end];
        rendered_files += 1;
    }

    if (!found_sections) {
        renderFallbackDiff(w, diff_text, cols) catch return out[0..fbs.end];
        return out[0..fbs.end];
    }

    if (omitted_files > 0) {
        w.writeByte('\n') catch return out[0..fbs.end];
        var omitted_buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&omitted_buf, "... {d} more file diffs omitted", .{omitted_files}) catch "...";
        writeCardLine(w, line, .warning) catch return out[0..fbs.end];
    }

    return out[0..fbs.end];
}

pub fn formatToolOutputBlock(out: *[8192]u8, tool_name: []const u8, tool_detail: []const u8, output: []const u8) []const u8 {
    var fbs = std.Io.Writer.fixed(out);
    const w = &fbs;

    const sections = parseToolSections(output);
    const display_name = canonicalToolDisplayName(tool_name);
    var detail_buf: [160]u8 = undefined;
    const detail = if (tool_detail.len > 0) clipMiddleInto(&detail_buf, tool_detail, 96) else "";
    const tone: Tone = if (sections.is_error) .failure else .neutral;

    // Specialized rendering for common tools
    if (std.mem.eql(u8, display_name, "Bash")) {
        return formatBashBlock(out, &fbs, w, detail, &sections, tone);
    }
    if (std.mem.eql(u8, display_name, "Read")) {
        return formatReadBlock(out, &fbs, w, detail, output, tone);
    }
    if (std.mem.eql(u8, display_name, "Glob")) {
        return formatGlobBlock(out, &fbs, w, detail, output, &sections, tone);
    }
    if (std.mem.eql(u8, display_name, "Grep")) {
        return formatGrepBlock(out, &fbs, w, detail, output, &sections, tone);
    }
    if (std.mem.eql(u8, display_name, "Write")) {
        return formatWriteBlock(out, &fbs, w, detail, output, tone);
    }

    // Generic rendering for all other tools
    writeCardHeader(w, display_name, detail, tone) catch return out[0..fbs.end];

    if (sections.command) |command| {
        writeKeyValueLine(w, "command", command, .neutral) catch return out[0..fbs.end];
    }

    if (sections.stdout.len > 0) {
        writeSectionLabel(w, "output", .neutral) catch return out[0..fbs.end];
        writeMultilineSection(w, sections.stdout, .neutral, MAX_TOOL_LINES_PER_SECTION) catch return out[0..fbs.end];
    }

    if (sections.stderr.len > 0) {
        writeSectionLabel(w, "stderr", .failure) catch return out[0..fbs.end];
        writeMultilineSection(w, sections.stderr, .failure, MAX_TOOL_LINES_PER_SECTION) catch return out[0..fbs.end];
    }

    if (sections.stdout.len == 0 and sections.stderr.len == 0 and output.len == 0) {
        writeCardLine(w, "(no output)", .warning) catch return out[0..fbs.end];
    } else if (sections.stdout.len == 0 and sections.stderr.len == 0) {
        writeSectionLabel(w, if (sections.is_error) "message" else "output", tone) catch return out[0..fbs.end];
        writeMultilineSection(w, output, tone, MAX_TOOL_LINES_PER_SECTION) catch return out[0..fbs.end];
    }

    if (sections.footer.len > 0) {
        writeCardFooter(w, sections.footer, if (sections.is_error) .failure else .warning) catch return out[0..fbs.end];
    } else {
        writeCardFooter(w, if (sections.is_error) "tool reported an error" else "completed", tone) catch return out[0..fbs.end];
    }

    return out[0..fbs.end];
}

const MAX_BASH_LINES_SUCCESS: usize = 3;
const MAX_BASH_LINES_ERROR: usize = 5;
const MAX_GLOB_PATHS: usize = 5;
const MAX_GREP_LINES: usize = 3;

fn formatBashBlock(
    out: *[8192]u8,
    fbs: *std.Io.Writer,
    w: anytype,
    detail: []const u8,
    sections: *const ToolSections,
    tone: Tone,
) []const u8 {
    _ = fbs;
    // Extract exit code from footer if present
    var exit_code_buf: [32]u8 = undefined;
    var exit_code_str: []const u8 = "";
    if (sections.footer.len > 0) {
        if (std.mem.indexOf(u8, sections.footer, "exit_code=")) |idx| {
            const after = sections.footer[idx + "exit_code=".len ..];
            const end_pos = std.mem.indexOfAny(u8, after, "] \t\r\n") orelse after.len;
            const code = after[0..end_pos];
            if (!std.mem.eql(u8, code, "0")) {
                exit_code_str = std.fmt.bufPrint(&exit_code_buf, "exit {s}", .{code}) catch "";
            }
        }
    }

    // Build header subtitle. If the command starts with a `# label`
    // first line, use the label as the subtitle -- much more skimmable
    // than a 90-character middle-truncated command. Falls back to the
    // raw (clipped) command otherwise. Ported from claude-code-main's
    // BashTool/commentLabel.ts which uses the same idiom under
    // fullscreen mode.
    var header_buf: [160]u8 = undefined;
    const cmd_display = blk: {
        if (sections.command) |cmd| {
            if (parse_helpers.extractBashCommentLabel(cmd)) |label| {
                break :blk clipMiddleInto(&header_buf, label, 96);
            }
            break :blk clipMiddleInto(&header_buf, cmd, 96);
        }
        if (detail.len > 0) break :blk detail;
        break :blk @as([]const u8, "shell command");
    };

    writeCardHeader(w, "Bash", cmd_display, tone) catch return out[0..0];

    const max_lines = if (sections.is_error) MAX_BASH_LINES_ERROR else MAX_BASH_LINES_SUCCESS;

    if (sections.stdout.len > 0) {
        writeMultilineSection(w, sections.stdout, .neutral, max_lines) catch return out[0..0];
    }

    if (sections.stderr.len > 0) {
        writeSectionLabel(w, "stderr", .failure) catch return out[0..0];
        writeMultilineSection(w, sections.stderr, .failure, max_lines) catch return out[0..0];
    }

    if (sections.stdout.len == 0 and sections.stderr.len == 0) {
        writeCardLine(w, "(no output)", .warning) catch return out[0..0];
    }

    // Footer: show exit code if non-zero, otherwise minimal
    if (exit_code_str.len > 0) {
        writeCardFooter(w, exit_code_str, .failure) catch return out[0..0];
    } else if (sections.is_error) {
        writeCardFooter(w, "failed", .failure) catch return out[0..0];
    } else {
        writeCardFooter(w, "ok", .success) catch return out[0..0];
    }

    return w.buffered();
}

fn formatReadBlock(
    out: *[8192]u8,
    fbs: *std.Io.Writer,
    w: anytype,
    detail: []const u8,
    output: []const u8,
    tone: Tone,
) []const u8 {
    _ = fbs;
    _ = tone;
    // detail is the file path
    const path_display = if (detail.len > 0) detail else "file";

    writeCardHeader(w, "Read", path_display, .neutral) catch return out[0..0];

    if (output.len == 0) {
        writeCardLine(w, "(empty file)", .warning) catch return out[0..0];
    } else {
        // Count lines in output for a summary
        const line_count = countNewlines(output);
        var summary_buf: [80]u8 = undefined;
        const summary = std.fmt.bufPrint(&summary_buf, "read {d} lines ({d} bytes)", .{ line_count, output.len }) catch "read file";
        writeCardLine(w, summary, .neutral) catch return out[0..0];
    }

    writeCardFooter(w, "ok", .success) catch return out[0..0];

    return w.buffered();
}

fn formatGlobBlock(
    out: *[8192]u8,
    fbs: *std.Io.Writer,
    w: anytype,
    detail: []const u8,
    output: []const u8,
    sections: *const ToolSections,
    tone: Tone,
) []const u8 {
    _ = fbs;
    _ = tone;
    // Count matches (each non-empty line is a file path)
    const body = if (sections.stdout.len > 0) sections.stdout else output;
    const match_count = countNonEmptyLines(body);

    // Build header: "Glob (N matches)"
    var header_buf: [80]u8 = undefined;
    const header_suffix = if (match_count == 1)
        std.fmt.bufPrint(&header_buf, "(1 match)", .{}) catch ""
    else
        std.fmt.bufPrint(&header_buf, "({d} matches)", .{match_count}) catch "";

    var title_buf: [120]u8 = undefined;
    const title = if (detail.len > 0 and header_suffix.len > 0)
        std.fmt.bufPrint(&title_buf, "{s} {s}", .{ detail, header_suffix }) catch detail
    else if (header_suffix.len > 0)
        header_suffix
    else
        detail;

    writeCardHeader(w, "Glob", title, .neutral) catch return out[0..0];

    if (match_count == 0) {
        writeCardLine(w, "no matches found", .warning) catch return out[0..0];
    } else {
        // Show first MAX_GLOB_PATHS file paths
        var iter = std.mem.splitScalar(u8, body, '\n');
        var shown: usize = 0;
        while (iter.next()) |line| {
            const trimmed = std.mem.trimEnd(u8, line, "\r \t");
            if (trimmed.len == 0) continue;
            if (shown >= MAX_GLOB_PATHS) break;
            var path_buf: [160]u8 = undefined;
            writeCardLine(w, clipMiddleInto(&path_buf, trimmed, 120), .neutral) catch return out[0..0];
            shown += 1;
        }
        if (match_count > MAX_GLOB_PATHS) {
            var more_buf: [64]u8 = undefined;
            const remaining = match_count - MAX_GLOB_PATHS;
            const word = parse_helpers.plural(remaining, "file", "files");
            const more = std.fmt.bufPrint(&more_buf, "... {d} more {s}", .{ remaining, word }) catch "...";
            writeCardLine(w, more, .warning) catch return out[0..0];
        }
    }

    writeCardFooter(w, "ok", .success) catch return out[0..0];

    return w.buffered();
}

fn formatGrepBlock(
    out: *[8192]u8,
    fbs: *std.Io.Writer,
    w: anytype,
    detail: []const u8,
    output: []const u8,
    sections: *const ToolSections,
    tone: Tone,
) []const u8 {
    _ = fbs;
    _ = tone;
    // Count matches (each non-empty line)
    const body = if (sections.stdout.len > 0) sections.stdout else output;
    const match_count = countNonEmptyLines(body);

    // Build header: "Grep (N matches)"
    var header_buf: [80]u8 = undefined;
    const header_suffix = if (match_count == 1)
        std.fmt.bufPrint(&header_buf, "(1 match)", .{}) catch ""
    else
        std.fmt.bufPrint(&header_buf, "({d} matches)", .{match_count}) catch "";

    var title_buf: [120]u8 = undefined;
    const title = if (detail.len > 0 and header_suffix.len > 0)
        std.fmt.bufPrint(&title_buf, "{s} {s}", .{ detail, header_suffix }) catch detail
    else if (header_suffix.len > 0)
        header_suffix
    else
        detail;

    writeCardHeader(w, "Grep", title, if (sections.is_error) .failure else .neutral) catch return out[0..0];

    if (sections.is_error and sections.stderr.len > 0) {
        writeMultilineSection(w, sections.stderr, .failure, MAX_GREP_LINES) catch return out[0..0];
        writeCardFooter(w, "failed", .failure) catch return out[0..0];
        return w.buffered();
    }

    if (match_count == 0) {
        writeCardLine(w, "no matches found", .warning) catch return out[0..0];
    } else {
        // Show first MAX_GREP_LINES matching lines
        var iter = std.mem.splitScalar(u8, body, '\n');
        var shown: usize = 0;
        while (iter.next()) |line| {
            const trimmed = std.mem.trimEnd(u8, line, "\r \t");
            if (trimmed.len == 0) continue;
            if (shown >= MAX_GREP_LINES) break;
            var line_buf: [160]u8 = undefined;
            writeCardLine(w, clipMiddleInto(&line_buf, trimmed, 120), .neutral) catch return out[0..0];
            shown += 1;
        }
        if (match_count > MAX_GREP_LINES) {
            var more_buf: [64]u8 = undefined;
            const remaining = match_count - MAX_GREP_LINES;
            const word = parse_helpers.plural(remaining, "match", "matches");
            const more = std.fmt.bufPrint(&more_buf, "... {d} more {s}", .{ remaining, word }) catch "...";
            writeCardLine(w, more, .warning) catch return out[0..0];
        }
    }

    writeCardFooter(w, "ok", .success) catch return out[0..0];

    return w.buffered();
}

fn formatWriteBlock(
    out: *[8192]u8,
    fbs: *std.Io.Writer,
    w: anytype,
    detail: []const u8,
    output: []const u8,
    tone: Tone,
) []const u8 {
    _ = fbs;
    _ = tone;
    // detail is the file path
    const path_display = if (detail.len > 0) detail else "file";

    writeCardHeader(w, "Write", path_display, .neutral) catch return out[0..0];

    // Try to extract useful info from output
    var summary_buf: [120]u8 = undefined;
    if (std.mem.indexOf(u8, output, "wrote ")) |_| {
        // Output already contains a "wrote" message, use first line
        const first_line = std.mem.sliceTo(output, '\n');
        const trimmed = std.mem.trim(u8, first_line, " \t\r");
        writeCardLine(w, clipMiddleInto(&summary_buf, trimmed, 100), .neutral) catch return out[0..0];
    } else {
        const summary = std.fmt.bufPrint(&summary_buf, "wrote to {s}", .{path_display}) catch "wrote file";
        writeCardLine(w, summary, .neutral) catch return out[0..0];
    }

    writeCardFooter(w, "ok", .success) catch return out[0..0];

    return w.buffered();
}

fn countNewlines(text: []const u8) usize {
    if (text.len == 0) return 0;
    var count: usize = 1;
    for (text) |ch| {
        if (ch == '\n') count += 1;
    }
    return count;
}

fn countNonEmptyLines(text: []const u8) usize {
    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, "\r \t");
        if (trimmed.len > 0) count += 1;
    }
    return count;
}

pub fn canonicalToolDisplayName(tool_name: []const u8) []const u8 {
    const name_map = .{
        .{ &.{ "shell", "Bash", "bash" }, "Bash" },
        .{ &.{ "file_read", "Read", "read" }, "Read" },
        .{ &.{ "file_write", "Write", "write" }, "Write" },
        .{ &.{ "file_edit", "Edit", "edit" }, "Edit" },
        .{ &.{ "Glob", "glob" }, "Glob" },
        .{ &.{ "Grep", "grep" }, "Grep" },
        .{ &.{ "WebFetch", "web_fetch", "HttpRequest", "http_request" }, "Fetch" },
        .{ &.{ "WebSearch", "web_search" }, "Search" },
        .{ &.{ "Task", "task" }, "Task" },
        .{ &.{ "TaskRun", "task_run" }, "TaskRun" },
        .{ &.{ "TaskPoll", "task_poll", "TaskGet", "task_get" }, "TaskGet" },
        .{ &.{ "GitDiff", "git_diff" }, "GitDiff" },
        .{ &.{"git_status"}, "GitStatus" },
    };

    inline for (name_map) |entry| {
        const candidates = entry[0];
        inline for (candidates) |candidate| {
            if (std.mem.eql(u8, tool_name, candidate)) return entry[1];
        }
    }
    return tool_name;
}

const DiffLineKind = enum {
    add,
    remove,
    context,
};

fn renderDiffSection(writer: anytype, section: []const u8, cols: usize) !void {
    const path = extractDiffPath(section) orelse "diff";
    const stats = countDiffStats(section);
    const lang = detectLangFromPath(path);
    var display_path_buf: [256]u8 = undefined;
    const display_path = clipPathForCard(&display_path_buf, path, cols);

    var subtitle_buf: [160]u8 = undefined;
    const subtitle = if (stats.new_file)
        std.fmt.bufPrint(&subtitle_buf, "{s}  new file  +{d} -{d}", .{ display_path, stats.added, stats.removed }) catch display_path
    else if (stats.deleted_file)
        std.fmt.bufPrint(&subtitle_buf, "{s}  deleted  +{d} -{d}", .{ display_path, stats.added, stats.removed }) catch display_path
    else
        std.fmt.bufPrint(&subtitle_buf, "{s}  +{d} -{d}  {d} hunks", .{ display_path, stats.added, stats.removed, stats.hunks }) catch display_path;

    try writeCardHeader(writer, "DIFF", subtitle, .diff);

    var old_line: usize = 0;
    var new_line: usize = 0;
    var in_hunk = false;
    var hunk_lines_shown: usize = 0;
    var hunks_shown: usize = 0;
    var omitted_hunk_lines: usize = 0;
    var omitted_hunks: usize = 0;
    const content_max = diffContentWidth(cols);
    const syntax_on = syntaxHighlightEnabled();

    // One-line look-ahead for the pair detector below: when a `-`
    // line is immediately followed by a `+` line, we render them as
    // a word-diff pair so only the changed substring is highlighted.
    const PendingRemove = struct {
        old_line: usize,
        content: []const u8,
    };
    var pending_remove: ?PendingRemove = null;

    var line_iter = std.mem.splitScalar(u8, section, '\n');
    while (line_iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "diff --git ") or
            std.mem.startsWith(u8, line, "index ") or
            std.mem.startsWith(u8, line, "--- ") or
            std.mem.startsWith(u8, line, "+++ "))
        {
            continue;
        }

        if (std.mem.eql(u8, line, "new file mode") or std.mem.eql(u8, line, "deleted file mode")) continue;
        if (std.mem.startsWith(u8, line, "new file mode ") or std.mem.startsWith(u8, line, "deleted file mode ")) continue;

        if (std.mem.startsWith(u8, line, "@@")) {
            if (in_hunk and omitted_hunk_lines > 0) {
                var omitted_buf: [64]u8 = undefined;
                const omitted = std.fmt.bufPrint(&omitted_buf, "... {d} more lines in this hunk", .{omitted_hunk_lines}) catch "...";
                try writeCardLine(writer, omitted, .warning);
                omitted_hunk_lines = 0;
            }

            if (hunks_shown >= MAX_HUNKS_PER_FILE) {
                omitted_hunks += 1;
                in_hunk = false;
                continue;
            }

            hunks_shown += 1;
            in_hunk = true;
            hunk_lines_shown = 0;
            parseHunkHeader(line, &old_line, &new_line);
            try writeCardLine(writer, line, .diff);
            continue;
        }

        if (!in_hunk) continue;

        const kind = parseDiffLineKind(line) orelse continue;
        if (hunk_lines_shown >= MAX_LINES_PER_HUNK) {
            // Flush any pending remove before omitting.
            if (pending_remove) |pending| {
                try writeDiffCodeLine(writer, .remove, pending.old_line, null, pending.content, lang, content_max, syntax_on);
                hunk_lines_shown += 1;
                pending_remove = null;
            }
            adjustLineCounters(kind, &old_line, &new_line);
            omitted_hunk_lines += 1;
            continue;
        }

        const content = if (line.len > 0) line[1..] else "";

        // Pair adjacent -/+ lines into a word-level highlighted pair
        // when both fit. The look-ahead keeps the pending `-` line in
        // a small local stash; on a matching `+` we call writeDiffPair
        // which uses word_diff.commonAffixes to colour only the
        // differing middle. Any other line flushes the pending remove
        // as a solo diff line.
        switch (kind) {
            .remove => {
                if (pending_remove) |pending| {
                    try writeDiffCodeLine(writer, .remove, pending.old_line, null, pending.content, lang, content_max, syntax_on);
                    hunk_lines_shown += 1;
                }
                pending_remove = .{ .old_line = old_line, .content = content };
            },
            .add => {
                if (pending_remove) |pending| {
                    // Clip once so the change-ratio decision is computed on the
                    // same bytes that get rendered (writeDiffCodePair would clip
                    // to content_max anyway). If too much of the line changed
                    // (ratio over CHANGE_THRESHOLD_PERCENT), highlighting only a
                    // word span is noise -- fall back to two solo lines.
                    var old_buf: [512]u8 = undefined;
                    var new_buf: [512]u8 = undefined;
                    const old_display = clipMiddleInto(&old_buf, pending.content, content_max);
                    const new_display = clipMiddleInto(&new_buf, content, content_max);
                    if (word_diff.changeRatioPercent(old_display, new_display) > word_diff.CHANGE_THRESHOLD_PERCENT) {
                        try writeDiffCodeLine(writer, .remove, pending.old_line, null, pending.content, lang, content_max, syntax_on);
                        try writeDiffCodeLine(writer, .add, null, new_line, content, lang, content_max, syntax_on);
                    } else {
                        try writeDiffCodePair(writer, pending.old_line, new_line, old_display, new_display);
                    }
                    hunk_lines_shown += 2;
                    pending_remove = null;
                } else {
                    try writeDiffCodeLine(writer, .add, null, new_line, content, lang, content_max, syntax_on);
                    hunk_lines_shown += 1;
                }
            },
            .context => {
                if (pending_remove) |pending| {
                    try writeDiffCodeLine(writer, .remove, pending.old_line, null, pending.content, lang, content_max, syntax_on);
                    hunk_lines_shown += 1;
                    pending_remove = null;
                }
                try writeDiffCodeLine(writer, .context, old_line, new_line, content, lang, content_max, syntax_on);
                hunk_lines_shown += 1;
            },
        }
        adjustLineCounters(kind, &old_line, &new_line);
    }

    // Flush a trailing remove that had no add to pair with.
    if (pending_remove) |pending| {
        try writeDiffCodeLine(writer, .remove, pending.old_line, null, pending.content, lang, content_max, syntax_on);
    }

    if (omitted_hunk_lines > 0) {
        var omitted_lines_buf: [64]u8 = undefined;
        const omitted_lines = std.fmt.bufPrint(&omitted_lines_buf, "... {d} more lines in this hunk", .{omitted_hunk_lines}) catch "...";
        try writeCardLine(writer, omitted_lines, .warning);
    }

    if (omitted_hunks > 0) {
        var omitted_hunks_buf: [64]u8 = undefined;
        const omitted = std.fmt.bufPrint(&omitted_hunks_buf, "... {d} more hunks omitted", .{omitted_hunks}) catch "...";
        try writeCardFooter(writer, omitted, .warning);
    } else {
        try writeCardFooter(writer, "patch preview", .diff);
    }
}

fn renderFallbackDiff(writer: anytype, diff_text: []const u8, cols: usize) !void {
    _ = cols;
    try writeCardHeader(writer, "DIFF", "patch preview", .diff);
    var line_iter = std.mem.splitScalar(u8, diff_text, '\n');
    var shown: usize = 0;
    while (line_iter.next()) |line| {
        if (shown >= MAX_LINES_PER_HUNK) break;
        if (line.len == 0) continue;
        const tone: Tone = if (line[0] == '+') .success else if (line[0] == '-') .failure else .neutral;
        var line_buf: [160]u8 = undefined;
        try writeCardLine(writer, clipMiddleInto(&line_buf, line, 140), tone);
        shown += 1;
    }
    try writeCardFooter(writer, "patch preview", .diff);
}

fn countLogicalLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    var count: usize = 1;
    for (text) |ch| {
        if (ch == '\n') count += 1;
    }
    return count;
}

fn countDiffStats(section: []const u8) DiffStats {
    var stats: DiffStats = .{};
    var line_iter = std.mem.splitScalar(u8, section, '\n');
    while (line_iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "@@")) {
            stats.hunks += 1;
        } else if (std.mem.startsWith(u8, line, "+") and !std.mem.startsWith(u8, line, "+++")) {
            stats.added += 1;
        } else if (std.mem.startsWith(u8, line, "-") and !std.mem.startsWith(u8, line, "---")) {
            stats.removed += 1;
        } else if (std.mem.startsWith(u8, line, "new file mode ")) {
            stats.new_file = true;
        } else if (std.mem.startsWith(u8, line, "deleted file mode ")) {
            stats.deleted_file = true;
        }
    }
    return stats;
}

fn extractDiffPath(section: []const u8) ?[]const u8 {
    const first_line = std.mem.sliceTo(section, '\n');
    if (!std.mem.startsWith(u8, first_line, "diff --git ")) return null;

    var it = std.mem.tokenizeScalar(u8, first_line, ' ');
    _ = it.next();
    _ = it.next();
    const a_path = it.next() orelse return null;
    const b_path = it.next() orelse a_path;

    if (std.mem.startsWith(u8, b_path, "b/")) return b_path[2..];
    if (std.mem.startsWith(u8, a_path, "a/")) return a_path[2..];
    return b_path;
}

fn parseDiffLineKind(line: []const u8) ?DiffLineKind {
    if (line.len == 0) return null;
    return switch (line[0]) {
        '+' => if (std.mem.startsWith(u8, line, "+++")) null else .add,
        '-' => if (std.mem.startsWith(u8, line, "---")) null else .remove,
        ' ' => .context,
        else => null,
    };
}

fn adjustLineCounters(kind: DiffLineKind, old_line: *usize, new_line: *usize) void {
    switch (kind) {
        .remove => old_line.* += 1,
        .add => new_line.* += 1,
        .context => {
            old_line.* += 1;
            new_line.* += 1;
        },
    }
}

fn parseHunkHeader(line: []const u8, old_line: *usize, new_line: *usize) void {
    old_line.* = parseHunkStart(line, '-') orelse old_line.*;
    new_line.* = parseHunkStart(line, '+') orelse new_line.*;
}

fn parseHunkStart(line: []const u8, needle: u8) ?usize {
    const idx = std.mem.indexOfScalar(u8, line, needle) orelse return null;
    const start = idx + 1;
    var end = start;
    while (end < line.len and std.ascii.isDigit(line[end])) : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(usize, line[start..end], 10) catch null;
}

fn diffContentWidth(cols: usize) usize {
    return if (cols > 28) cols - 28 else 56;
}

fn detectLangFromPath(path: []const u8) repl_markdown.CodeLang {
    if (std.mem.endsWith(u8, path, ".zig")) return .zig;
    if (std.mem.endsWith(u8, path, ".go")) return .go;
    if (std.mem.endsWith(u8, path, ".js")) return .javascript;
    if (std.mem.endsWith(u8, path, ".jsx")) return .javascript;
    if (std.mem.endsWith(u8, path, ".ts")) return .typescript;
    if (std.mem.endsWith(u8, path, ".tsx")) return .typescript;
    if (std.mem.endsWith(u8, path, ".json")) return .json;
    if (std.mem.endsWith(u8, path, ".py")) return .python;
    if (std.mem.endsWith(u8, path, ".sh")) return .bash;
    if (std.mem.endsWith(u8, path, ".bash")) return .bash;
    if (std.mem.endsWith(u8, path, ".yml")) return .yaml;
    if (std.mem.endsWith(u8, path, ".yaml")) return .yaml;
    if (std.mem.endsWith(u8, path, ".toml")) return .toml;
    return .plain;
}

fn writeDiffCodeLine(
    writer: anytype,
    kind: DiffLineKind,
    old_line: ?usize,
    new_line: ?usize,
    content: []const u8,
    lang: repl_markdown.CodeLang,
    content_max: usize,
    syntax_on: bool,
) !void {
    try writer.writeAll(repl_markdown.ANSI_DIM);
    try writer.writeAll(repl_markdown.BOX_V);
    try writer.writeAll(repl_markdown.ANSI_RESET);
    try writer.writeByte(' ');

    try writeLineNumberCell(writer, old_line);
    try writer.writeByte(' ');
    try writeLineNumberCell(writer, new_line);
    try writer.writeByte(' ');

    const sign: u8 = switch (kind) {
        .add => '+',
        .remove => '-',
        .context => ' ',
    };
    try writer.writeAll(toneColor(switch (kind) {
        .add => .success,
        .remove => .failure,
        .context => .neutral,
    }));
    try writer.writeByte(sign);
    try writer.writeByte(' ');
    try writer.writeAll(repl_markdown.ANSI_RESET);

    var display_buf: [512]u8 = undefined;
    const display = clipMiddleInto(&display_buf, content, content_max);
    if (kind == .context) {
        try writeCodeContent(writer, display, lang, syntax_on);
    } else {
        try writer.writeAll(toneColor(switch (kind) {
            .add => .success,
            .remove => .failure,
            .context => .neutral,
        }));
        try writeCodeContent(writer, display, lang, syntax_on);
        try writer.writeAll(repl_markdown.ANSI_RESET);
    }
    try writer.writeByte('\n');
}

/// Emit one line of diff content, applying language syntax highlighting
/// only when `syntax_on`. When off, the raw (already clipped) text is
/// written verbatim so the surrounding tone colour (set by the caller)
/// is the sole colour, matching the reference's
/// CLAUDE_CODE_SYNTAX_HIGHLIGHT=off path.
fn writeCodeContent(writer: anytype, display: []const u8, lang: repl_markdown.CodeLang, syntax_on: bool) !void {
    if (syntax_on) {
        try repl_markdown.writeCodeLine(writer, display, lang, render_options);
    } else {
        try writer.writeAll(display);
    }
}

/// Render a paired -/+ diff line with word-level highlighting.
/// Uses word_diff.wordDiffSegments to compute a real multi-segment
/// token diff so several disjoint changed words on one line are each
/// highlighted while shared interior words stay plain. Falls back to
/// the single-affix word_diff.commonAffixes path when the token count
/// exceeds the cap (e.g. very long / minified lines).
/// The two lines retain their `-`/`+` signs, line numbers, and card
/// borders so the surrounding structure stays readable.
/// Skips language syntax highlighting on purpose -- layering the
/// fzf-style intra-line accent on top of syntax colours is
/// visually noisy and the word-level signal is task-relevant.
/// `old_display`/`new_display` are already clipped to content_max by
/// the caller so the change-ratio decision and the rendered bytes
/// agree.
fn writeDiffCodePair(
    writer: anytype,
    old_line: usize,
    new_line: usize,
    old_display: []const u8,
    new_display: []const u8,
) !void {
    // 2 * cap is enough headroom even when no merging happens: every
    // token becomes at most one segment, and there are at most cap tokens
    // per side.
    var seg_buf: [2 * word_diff.WORD_DIFF_TOKEN_CAP]word_diff.Seg = undefined;
    const maybe_segs = word_diff.wordDiffSegments(old_display, new_display, &seg_buf);

    if (maybe_segs) |segs| {
        try writeDiffCodePairSegments(writer, old_line, new_line, segs);
    } else {
        try writeDiffCodePairAffix(writer, old_line, new_line, old_display, new_display);
    }
}

/// Multi-segment renderer: walk the ordered token-diff segments, emitting
/// the removed line (common + removed runs) and the added line (common +
/// added runs). Each removed run is wrapped in the bright red span and
/// each added run in the bright green span; the tone colour is restored
/// after every span so trailing common text keeps its colour.
fn writeDiffCodePairSegments(
    writer: anytype,
    old_line: usize,
    new_line: usize,
    segs: []const word_diff.Seg,
) !void {
    // Old (removed) line: common + removed segments.
    try writer.writeAll(repl_markdown.ANSI_DIM);
    try writer.writeAll(repl_markdown.BOX_V);
    try writer.writeAll(repl_markdown.ANSI_RESET);
    try writer.writeByte(' ');
    try writeLineNumberCell(writer, old_line);
    try writer.writeByte(' ');
    try writeLineNumberCell(writer, null);
    try writer.writeByte(' ');
    try writer.writeAll(toneColor(.failure));
    try writer.writeByte('-');
    try writer.writeByte(' ');
    for (segs) |seg| {
        switch (seg.tag) {
            .common => try writer.writeAll(seg.text),
            .removed => {
                // Brighter red background, white foreground for the run.
                try writer.writeAll("\x1b[41;97m");
                try writer.writeAll(seg.text);
                try writer.writeAll(repl_markdown.ANSI_RESET);
                try writer.writeAll(toneColor(.failure));
            },
            .added => {},
        }
    }
    try writer.writeAll(repl_markdown.ANSI_RESET);
    try writer.writeByte('\n');

    // New (added) line: common + added segments.
    try writer.writeAll(repl_markdown.ANSI_DIM);
    try writer.writeAll(repl_markdown.BOX_V);
    try writer.writeAll(repl_markdown.ANSI_RESET);
    try writer.writeByte(' ');
    try writeLineNumberCell(writer, null);
    try writer.writeByte(' ');
    try writeLineNumberCell(writer, new_line);
    try writer.writeByte(' ');
    try writer.writeAll(toneColor(.success));
    try writer.writeByte('+');
    try writer.writeByte(' ');
    for (segs) |seg| {
        switch (seg.tag) {
            .common => try writer.writeAll(seg.text),
            .added => {
                try writer.writeAll("\x1b[42;30m");
                try writer.writeAll(seg.text);
                try writer.writeAll(repl_markdown.ANSI_RESET);
                try writer.writeAll(toneColor(.success));
            },
            .removed => {},
        }
    }
    try writer.writeAll(repl_markdown.ANSI_RESET);
    try writer.writeByte('\n');
}

/// Single-affix fallback renderer used when the token diff exceeds the
/// cap. Wraps only the one contiguous shared-prefix/suffix middle.
fn writeDiffCodePairAffix(
    writer: anytype,
    old_line: usize,
    new_line: usize,
    old_display: []const u8,
    new_display: []const u8,
) !void {
    const af = word_diff.commonAffixes(old_display, new_display);

    // Old (removed) line.
    try writer.writeAll(repl_markdown.ANSI_DIM);
    try writer.writeAll(repl_markdown.BOX_V);
    try writer.writeAll(repl_markdown.ANSI_RESET);
    try writer.writeByte(' ');
    try writeLineNumberCell(writer, old_line);
    try writer.writeByte(' ');
    try writeLineNumberCell(writer, null);
    try writer.writeByte(' ');
    try writer.writeAll(toneColor(.failure));
    try writer.writeByte('-');
    try writer.writeByte(' ');
    try writer.writeAll(old_display[0..af.prefix]);
    const old_middle_end = old_display.len - af.suffix;
    if (old_middle_end > af.prefix) {
        // Brighter red background, white foreground for the changed run.
        try writer.writeAll("\x1b[41;97m");
        try writer.writeAll(old_display[af.prefix..old_middle_end]);
        try writer.writeAll(repl_markdown.ANSI_RESET);
        try writer.writeAll(toneColor(.failure));
    }
    try writer.writeAll(old_display[old_middle_end..]);
    try writer.writeAll(repl_markdown.ANSI_RESET);
    try writer.writeByte('\n');

    // New (added) line.
    try writer.writeAll(repl_markdown.ANSI_DIM);
    try writer.writeAll(repl_markdown.BOX_V);
    try writer.writeAll(repl_markdown.ANSI_RESET);
    try writer.writeByte(' ');
    try writeLineNumberCell(writer, null);
    try writer.writeByte(' ');
    try writeLineNumberCell(writer, new_line);
    try writer.writeByte(' ');
    try writer.writeAll(toneColor(.success));
    try writer.writeByte('+');
    try writer.writeByte(' ');
    try writer.writeAll(new_display[0..af.prefix]);
    const new_middle_end = new_display.len - af.suffix;
    if (new_middle_end > af.prefix) {
        try writer.writeAll("\x1b[42;30m");
        try writer.writeAll(new_display[af.prefix..new_middle_end]);
        try writer.writeAll(repl_markdown.ANSI_RESET);
        try writer.writeAll(toneColor(.success));
    }
    try writer.writeAll(new_display[new_middle_end..]);
    try writer.writeAll(repl_markdown.ANSI_RESET);
    try writer.writeByte('\n');
}

fn writeLineNumberCell(writer: anytype, value: ?usize) !void {
    var buf: [8]u8 = undefined;
    if (value) |num| {
        const line = std.fmt.bufPrint(&buf, "{d: >4}", .{num}) catch "    ";
        try writer.writeAll(repl_markdown.ANSI_DIM);
        try writer.writeAll(line);
        try writer.writeAll(repl_markdown.ANSI_RESET);
        return;
    }
    try writer.writeAll("    ");
}

fn parseToolSections(output: []const u8) ToolSections {
    var sections: ToolSections = .{};
    var body = std.mem.trim(u8, output, " \t\r\n");
    if (body.len == 0) return sections;

    const first_line = std.mem.sliceTo(body, '\n');
    if (std.mem.startsWith(u8, first_line, "$ ")) {
        sections.command = first_line[2..];
        body = std.mem.trimStart(u8, body[first_line.len..], "\r\n");
    }

    var footer_start = body.len;
    var cursor = body.len;
    while (cursor > 0) {
        const line_start = (std.mem.lastIndexOfScalar(u8, body[0..cursor], '\n') orelse 0);
        const actual_start = if (line_start == 0) 0 else line_start + 1;
        const line = std.mem.trim(u8, body[actual_start..cursor], " \t\r");
        if (line.len == 0) {
            if (actual_start == 0) break;
            cursor = actual_start - 1;
            continue;
        }
        if (!isFooterLine(line)) break;
        footer_start = actual_start;
        if (actual_start == 0) break;
        cursor = actual_start - 1;
    }

    if (footer_start < body.len) {
        sections.footer = std.mem.trim(u8, body[footer_start..], " \t\r\n");
        body = std.mem.trimEnd(u8, body[0..footer_start], " \t\r\n");
    }

    if (std.mem.indexOf(u8, body, "\n[stderr]\n")) |idx| {
        sections.stdout = std.mem.trim(u8, body[0..idx], " \t\r\n");
        sections.stderr = std.mem.trim(u8, body[idx + "\n[stderr]\n".len ..], " \t\r\n");
    } else if (std.mem.startsWith(u8, body, "[stderr]\n")) {
        sections.stderr = std.mem.trim(u8, body["[stderr]\n".len..], " \t\r\n");
    } else {
        sections.stdout = body;
    }

    // Default conservative classification: stderr present, non-zero
    // exit code, or output starts with "error"/"failed"/"blocked"/
    // "timeout" all flag as error.
    var is_error = (sections.stderr.len > 0) or
        startsWithAnyIgnoreCase(output, &.{ "error", "failed", "blocked", "timeout" }) or
        (std.mem.indexOf(u8, output, " failed") != null);

    // Pull the actual exit code out of the footer (default to 0 if
    // missing) and run the per-command semantic interpreter so that
    // grep/rg/find/diff/test exit 1 stops being misclassified as a
    // failure. Without this, a successful "no matches" search renders
    // as a red error card and the model is told its tool failed.
    //
    // The semantic override only kicks in when stderr is EMPTY -- a
    // tool that wrote to stderr still flags as error even when its
    // exit code is informational, because the user almost certainly
    // wants to see that warning surfaced in the card UI.
    if (sections.footer.len > 0) {
        if (std.mem.indexOf(u8, sections.footer, "exit_code=")) |idx| {
            const after = sections.footer[idx + "exit_code=".len ..];
            const end_pos = std.mem.indexOfAny(u8, after, "] \t\r\n") orelse after.len;
            const code_str = after[0..end_pos];
            const exit_code = std.fmt.parseInt(i32, code_str, 10) catch 0;
            if (exit_code != 0) {
                is_error = true;
                if (sections.stderr.len == 0) {
                    if (sections.command) |cmd| {
                        const semantic = command_semantics.interpret(cmd, exit_code);
                        if (!semantic.is_error) is_error = false;
                    }
                }
            }
        }
    }

    sections.is_error = is_error;
    return sections;
}

const command_semantics = @import("../core/command_semantics.zig");

fn isFooterLine(line: []const u8) bool {
    if (line.len < 2) return false;
    if (!(line[0] == '[' and line[line.len - 1] == ']')) return false;
    return std.mem.indexOf(u8, line, "exit") != null or
        std.mem.indexOf(u8, line, "timeout") != null or
        std.mem.indexOf(u8, line, "status") != null;
}

fn startsWithAnyIgnoreCase(text: []const u8, needles: []const []const u8) bool {
    const trimmed = std.mem.trimStart(u8, text, " \t\r\n");
    for (needles) |needle| {
        if (repl_markdown.startsWithIgnoreCase(trimmed, needle)) return true;
    }
    return false;
}

/// Tone-colored left-edge accent rail for tool cards. The bar is
/// `▎` (U+258E LEFT ONE QUARTER BLOCK) -- thicker than `│` so the
/// status color reads at a glance, and tinted per-tone so a
/// failure card looks unmistakably different from a success card
/// without having to read the body text.
///
///   neutral -> dim gray  (quiet, no decoration noise)
///   success -> mint green (matches the brand accent from the
///              welcome banner and spinner pulse)
///   warning -> amber
///   failure -> red
///   diff    -> cyan
///
/// Previously every line of every card used the same dim `│`
/// bracket regardless of outcome, which meant a long successful
/// Bash run and a failed one looked identical at a glance and
/// the user had to scan the footer to spot errors.
fn toneRail(tone: Tone) []const u8 {
    return switch (tone) {
        .neutral => "\x1b[2m\xe2\x96\x8e\x1b[0m",
        .success => "\x1b[38;5;114m\xe2\x96\x8e\x1b[0m",
        .warning => "\x1b[38;5;180m\xe2\x96\x8e\x1b[0m",
        .failure => "\x1b[38;5;203m\xe2\x96\x8e\x1b[0m",
        .diff => "\x1b[38;5;81m\xe2\x96\x8e\x1b[0m",
    };
}

fn writeCardHeader(writer: anytype, label: []const u8, subtitle: []const u8, tone: Tone) !void {
    try writer.writeAll(toneRail(tone));
    try writer.writeByte(' ');
    // Approval indicator: checkmark for success/neutral, X for failure
    switch (tone) {
        .success, .neutral, .diff => {
            try writer.writeAll("\x1b[38;5;114m\xe2\x9c\x93\x1b[0m "); // green checkmark
        },
        .failure => {
            try writer.writeAll("\x1b[38;5;203m\xe2\x9c\x97\x1b[0m "); // red X
        },
        .warning => {
            try writer.writeAll("\x1b[38;5;180m\xe2\x9a\xa0\x1b[0m "); // amber warning
        },
    }
    try writer.writeAll(repl_markdown.ANSI_BOLD);
    try writer.writeAll(toneColor(tone));
    try writer.writeAll(label);
    try writer.writeAll(repl_markdown.ANSI_RESET);
    if (subtitle.len > 0) {
        try writer.writeByte(' ');
        try writer.writeAll(repl_markdown.ANSI_PATH);
        try writer.writeAll(subtitle);
        try writer.writeAll(repl_markdown.ANSI_RESET);
    }
    try writer.writeByte('\n');
}

fn writeCardFooter(writer: anytype, summary: []const u8, tone: Tone) !void {
    try writer.writeAll(toneRail(tone));
    try writer.writeByte(' ');
    try writer.writeAll(repl_markdown.ANSI_DIM);
    try writer.writeAll(toneColor(tone));
    try writer.writeAll(summary);
    try writer.writeAll(repl_markdown.ANSI_RESET);
    try writer.writeByte('\n');
}

fn writeCardLine(writer: anytype, text: []const u8, tone: Tone) !void {
    try writer.writeAll(toneRail(tone));
    try writer.writeByte(' ');
    try writer.writeAll(toneColor(tone));
    try writer.writeAll(text);
    try writer.writeAll(repl_markdown.ANSI_RESET);
    try writer.writeByte('\n');
}

fn writeSectionLabel(writer: anytype, label: []const u8, tone: Tone) !void {
    try writer.writeAll(toneRail(tone));
    try writer.writeByte(' ');
    try writer.writeAll(repl_markdown.ANSI_DIM);
    try writer.writeAll(label);
    try writer.writeAll(repl_markdown.ANSI_RESET);
    try writer.writeByte('\n');
}

fn writeKeyValueLine(writer: anytype, key: []const u8, value: []const u8, tone: Tone) !void {
    try writer.writeAll(toneRail(tone));
    try writer.writeByte(' ');
    try writer.writeAll(repl_markdown.ANSI_DIM);
    try writer.writeAll(key);
    try writer.writeAll(": ");
    try writer.writeAll(repl_markdown.ANSI_RESET);
    try writer.writeAll(toneColor(tone));
    var value_buf: [160]u8 = undefined;
    try writer.writeAll(clipMiddleInto(&value_buf, value, 120));
    try writer.writeAll(repl_markdown.ANSI_RESET);
    try writer.writeByte('\n');
}

fn writeMultilineSection(writer: anytype, text: []const u8, tone: Tone, max_lines: usize) !void {
    var line_iter = std.mem.splitScalar(u8, text, '\n');
    var shown: usize = 0;
    var total: usize = 0;
    var non_empty_seen = false;
    while (line_iter.next()) |_| total += 1;

    line_iter = std.mem.splitScalar(u8, text, '\n');
    while (line_iter.next()) |line| {
        if (shown >= max_lines) break;
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0 and !non_empty_seen) continue;
        non_empty_seen = true;
        try writer.writeAll(toneRail(tone));
        try writer.writeByte(' ');
        try writer.writeAll(toneColor(tone));
        try writer.writeAll("  ");
        var line_buf: [160]u8 = undefined;
        try writer.writeAll(clipMiddleInto(&line_buf, trimmed, 140));
        try writer.writeAll(repl_markdown.ANSI_RESET);
        try writer.writeByte('\n');
        shown += 1;
    }

    if (total > shown) {
        var buf: [64]u8 = undefined;
        const more = std.fmt.bufPrint(&buf, "... {d} more lines omitted", .{total - shown}) catch "...";
        try writeCardLine(writer, more, .warning);
    }
}

fn clipPathForCard(out: []u8, path: []const u8, max_cols: usize) []const u8 {
    const budget = if (max_cols > 26) max_cols - 26 else 48;
    return clipMiddleInto(out, path, budget);
}

fn clipMiddleInto(out: []u8, text: []const u8, max_len: usize) []const u8 {
    if (out.len == 0 or max_len == 0) return "";

    // Strip ANSI escapes and other control bytes on the fly. Tool
    // output (bash stdout, file content, HTTP response bodies) is
    // arbitrary and may contain CSI / OSC sequences that, if written
    // straight to the user's terminal, can set window titles, clear
    // the screen, toggle bracketed paste, or (on some emulators like
    // iTerm2 with OSC 1337) execute remote commands. Tool content
    // rendered in the card UI is untrusted -- sanitize it here at the
    // single chokepoint that every card label, value, and line runs
    // through so the terminal never sees raw escapes.
    var sanitized_buf: [2048]u8 = undefined;
    const clean = sanitizeTextInto(&sanitized_buf, text);

    const safe_max = @min(max_len, out.len);
    if (clean.len <= safe_max or safe_max < 4) {
        const take = @min(clean.len, safe_max);
        @memcpy(out[0..take], clean[0..take]);
        return out[0..take];
    }

    const keep = safe_max - 3;
    const left = keep / 2;
    const right = keep - left;
    @memcpy(out[0..left], clean[0..left]);
    @memcpy(out[left .. left + 3], "...");
    @memcpy(out[left + 3 .. left + 3 + right], clean[clean.len - right ..]);
    return out[0 .. left + 3 + right];
}

/// Copy `text` into `dest` with ANSI escape sequences, OSC strings,
/// and other control bytes removed. Tab and regular printable bytes
/// pass through unchanged. Returns the used slice of `dest`; if
/// `text` is longer than `dest` the tail is dropped (the caller then
/// clips the sanitized result further if needed).
fn sanitizeTextInto(dest: []u8, text: []const u8) []const u8 {
    var o: usize = 0;
    var i: usize = 0;
    while (i < text.len and o < dest.len) {
        const ch = text[i];
        if (ch == 0x1b) {
            i += ansiEscapeByteLength(text[i..]);
            continue;
        }
        if (ch == '\t' or ch >= 0x20 and ch != 0x7f) {
            dest[o] = ch;
            o += 1;
        }
        i += 1;
    }
    return dest[0..o];
}

/// Return the byte length of the ANSI escape sequence beginning at
/// `text[0]` (which must be 0x1b). Recognises CSI (ESC [...), OSC
/// (ESC ]... BEL or ESC ]... ESC \\), and short two-byte escapes.
/// Returns 1 if `text[0]` is not ESC (defensive).
fn ansiEscapeByteLength(text: []const u8) usize {
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

fn toneColor(tone: Tone) []const u8 {
    return switch (tone) {
        .neutral => "",
        .success => "\x1b[38;5;114m",
        .warning => "\x1b[38;5;180m",
        .failure => repl_markdown.ANSI_ERROR_PREFIX,
        .diff => "\x1b[38;5;81m",
    };
}

const testing = std.testing;

test "extractDiffPath prefers b path" {
    const path = extractDiffPath("diff --git a/src/old.zig b/src/new.zig\n@@ -1 +1 @@\n").?;
    try testing.expectEqualStrings("src/new.zig", path);
}

test "parseToolSections splits command stderr and footer" {
    const sections = parseToolSections(
        "$ rg foo src\nhit\n[stderr]\nwarning\n[exit_code=1]\n",
    );
    try testing.expectEqualStrings("rg foo src", sections.command.?);
    try testing.expectEqualStrings("hit", sections.stdout);
    try testing.expectEqualStrings("warning", sections.stderr);
    try testing.expectEqualStrings("[exit_code=1]", sections.footer);
    try testing.expect(sections.is_error);
}

test "parseToolSections rg exit 1 with no stderr is not an error" {
    // Regression: rg returns exit 1 when there are no matches. zcode
    // used to render this as a red error card. command_semantics now
    // overrides the classification when stderr is empty.
    const sections = parseToolSections(
        "$ rg nonexistent src\n[exit_code=1]\n",
    );
    try testing.expectEqualStrings("rg nonexistent src", sections.command.?);
    try testing.expect(!sections.is_error);
}

test "parseToolSections grep exit 1 with no stderr is not an error" {
    const sections = parseToolSections(
        "$ grep foo *.zig\n[exit_code=1]\n",
    );
    try testing.expect(!sections.is_error);
}

test "parseToolSections diff exit 1 (files differ) is not an error" {
    const sections = parseToolSections(
        "$ diff a.txt b.txt\n< old\n---\n> new\n[exit_code=1]\n",
    );
    try testing.expect(!sections.is_error);
}

test "parseToolSections grep exit 2 IS an error even with no stderr" {
    const sections = parseToolSections(
        "$ grep foo missing.txt\n[exit_code=2]\n",
    );
    try testing.expect(sections.is_error);
}

test "sanitizeTextInto strips CSI colour and OSC title" {
    var buf: [128]u8 = undefined;
    const input = "plain\x1b[31mred\x1b[0m tail\x1b]0;window\x07end";
    const out = sanitizeTextInto(&buf, input);
    try testing.expectEqualStrings("plainred tail" ++ "end", out);
}

test "sanitizeTextInto drops bare ESC and control bytes" {
    var buf: [128]u8 = undefined;
    // ESC followed by a non-[ / non-] byte is a 2-byte Fe/Fs escape;
    // both bytes are dropped. 0x01 is a lone control byte (dropped).
    // Tab is preserved.
    const input = "a\x1bXb\x01c\td";
    const out = sanitizeTextInto(&buf, input);
    try testing.expectEqualStrings("abc\td", out);
}

test "clipMiddleInto sanitizes then clips middle" {
    var buf: [64]u8 = undefined;
    const input = "abcdef\x1b[1;31mHIGHLIGHTED\x1b[0mghijkl";
    const clipped = clipMiddleInto(&buf, input, 10);
    // Sanitized text is "abcdefHIGHLIGHTEDghijkl" (23 chars). Clip to 10 with 3-char ellipsis.
    // Result: "abc" + "..." + "jkl" (left=3, right=4) = "abc...ijkl" (10 chars).
    try testing.expectEqual(@as(usize, 10), clipped.len);
    try testing.expect(std.mem.indexOf(u8, clipped, "\x1b") == null);
    try testing.expect(std.mem.indexOf(u8, clipped, "...") != null);
}

test "formatDiffBlock word-highlights a small-change -/+ pair" {
    var out: [8192]u8 = undefined;
    // A -/+ pair differing in only a few chars: shared prefix/suffix,
    // small middle -> change ratio under 0.4 -> word-diff pair path.
    const diff =
        "diff --git a/x.txt b/x.txt\n" ++
        "@@ -1,1 +1,1 @@\n" ++
        "-the quick brown fox\n" ++
        "+the quick brave fox\n";
    const rendered = formatDiffBlock(&out, diff);
    // Bright remove + add word-span SGR codes are present.
    try testing.expect(std.mem.indexOf(u8, rendered, "\x1b[41;97m") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "\x1b[42;30m") != null);
}

test "formatDiffBlock falls back to solo lines on near-total rewrite" {
    var out: [8192]u8 = undefined;
    // A -/+ pair that differs almost entirely -> change ratio over 0.4
    // -> two solo lines, no bright word-span.
    const diff =
        "diff --git a/x.txt b/x.txt\n" ++
        "@@ -1,1 +1,1 @@\n" ++
        "-old line text\n" ++
        "+totally different content here\n";
    const rendered = formatDiffBlock(&out, diff);
    try testing.expect(std.mem.indexOf(u8, rendered, "\x1b[41;97m") == null);
    try testing.expect(std.mem.indexOf(u8, rendered, "\x1b[42;30m") == null);
}

test "formatDiffBlock highlights two separated edits with the middle plain" {
    var out: [8192]u8 = undefined;
    // Two disjoint changed words ("foo"->"baz", "bar"->"qux") with the
    // shared interior " to " unchanged. A single-affix diff would
    // highlight "foo to bar" vs "baz to qux" wholesale; the token diff
    // emits two distinct bright spans per side and leaves " to " plain.
    const diff =
        "diff --git a/x.txt b/x.txt\n" ++
        "@@ -1,1 +1,1 @@\n" ++
        "-rename foo to bar\n" ++
        "+rename baz to qux\n";
    const rendered = formatDiffBlock(&out, diff);
    // Two bright remove spans (foo, bar) and two bright add spans (baz, qux).
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, rendered, "\x1b[41;97m"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, rendered, "\x1b[42;30m"));
    // The shared interior " to " must appear plain (not inside a span):
    // there is no bright-span opener immediately preceding the literal
    // " to " run on either line.
    try testing.expect(std.mem.indexOf(u8, rendered, "\x1b[41;97m to ") == null);
    try testing.expect(std.mem.indexOf(u8, rendered, "\x1b[42;30m to ") == null);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "syntaxHighlightEnabled defaults on and only a falsy env value turns it off" {
    // Default (unset): highlighting stays on, matching zcode's existing
    // behaviour where context + solo diff lines have always been coloured.
    _ = unsetenv("CLAUDE_CODE_SYNTAX_HIGHLIGHT");
    try testing.expect(syntaxHighlightEnabled());

    // A falsy value (0/false/no/off) is the only thing that turns it off.
    _ = setenv("CLAUDE_CODE_SYNTAX_HIGHLIGHT", "0", 1);
    try testing.expect(!syntaxHighlightEnabled());
    _ = setenv("CLAUDE_CODE_SYNTAX_HIGHLIGHT", "off", 1);
    try testing.expect(!syntaxHighlightEnabled());

    // A truthy value keeps it on.
    _ = setenv("CLAUDE_CODE_SYNTAX_HIGHLIGHT", "1", 1);
    try testing.expect(syntaxHighlightEnabled());

    // An unrecognised value is neither truthy nor falsy -> stays on (default).
    _ = setenv("CLAUDE_CODE_SYNTAX_HIGHLIGHT", "maybe", 1);
    try testing.expect(syntaxHighlightEnabled());

    _ = unsetenv("CLAUDE_CODE_SYNTAX_HIGHLIGHT");
}

test "writeCodeContent with syntax off writes the raw line and no keyword SGR" {
    // When the gate is off, a recognised zig keyword like `const` must
    // NOT pick up the keyword SGR (\x1b[38;5;176m) -- the content is
    // written verbatim and the caller's tone colour is the only colour.
    var buf: [256]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    const line = "const x = 1;";
    try writeCodeContent(&fbs, line, .zig, false);
    const out = buf[0..fbs.end];
    try testing.expectEqualStrings(line, out);
    try testing.expect(std.mem.indexOf(u8, out, repl_markdown.ANSI_CODE_KEYWORD) == null);
}

test "writeDiffCodeLine context line with syntax off emits no keyword SGR" {
    // End-to-end through the diff-line renderer: a context line carrying
    // a zig keyword renders without the keyword highlight when the gate
    // is off. (With the gate on, highlighting still depends on the
    // shouldUseColor isatty check, so the on-path SGR is not asserted
    // here -- it is exercised in the existing render tests on a TTY.)
    var buf: [512]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try writeDiffCodeLine(&fbs, .context, 1, 1, "const x = 1;", .zig, 80, false);
    const out = buf[0..fbs.end];
    try testing.expect(std.mem.indexOf(u8, out, "const x = 1;") != null);
    try testing.expect(std.mem.indexOf(u8, out, repl_markdown.ANSI_CODE_KEYWORD) == null);
}

test "env_registry lists CLAUDE_CODE_SYNTAX_HIGHLIGHT" {
    const env_registry = @import("../core/env_registry.zig");
    var found = false;
    for (env_registry.entries) |e| {
        if (std.mem.eql(u8, e.name, "CLAUDE_CODE_SYNTAX_HIGHLIGHT")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}
