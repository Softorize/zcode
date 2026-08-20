//! Phase 11 Task 6 (sessions-06). AI-generated session title: build the
//! title-generation prompt from the first user prompt + conversation summary,
//! and parse the model's one-line title (trim, strip surrounding quotes,
//! collapse whitespace, cap length). Pure module: no network, no allocation in
//! the parser beyond the returned slice. The actual fast-model call lives in
//! agent_runtime (best-effort, off the critical path); this module only owns
//! the deterministic, unit-testable pieces.
//!
//! Reference: utils/sessionStorage.ts:2667 (saveAiGeneratedTitle) and the
//! short-title generation prompt the reference sends to the small/fast model.

const std = @import("std");
const std_io = @import("std_io.zig");

/// System prompt for the title generator. Keep it terse: the fast model just
/// needs to emit a single short, descriptive title line and nothing else.
pub const SYSTEM_PROMPT =
    "You name coding sessions. Given the first user request (and an optional " ++
    "summary), reply with a single short title of 3 to 6 words that captures " ++
    "the task. Reply with ONLY the title, no quotes, no punctuation at the end, " ++
    "no preamble.";

/// Maximum number of characters a stored/displayed title may have. Titles
/// longer than this are truncated by `parseTitle` so they never blow out a
/// `/session list` TSV row or the switcher overlay.
pub const MAX_TITLE_LEN: usize = 60;

/// Build the user-facing title-generation prompt from the first user prompt and
/// the (optional) conversation summary. Caller owns the returned slice. Both
/// inputs are trimmed; an empty summary is simply omitted. The first prompt is
/// capped so a giant first message does not bloat the title call.
pub fn buildPrompt(
    allocator: std.mem.Allocator,
    first_prompt: []const u8,
    summary: []const u8,
) ![]u8 {
    const max_first_prompt_chars: usize = 1000;
    const fp_trimmed = std.mem.trim(u8, first_prompt, " \t\r\n");
    const fp_capped = if (fp_trimmed.len > max_first_prompt_chars)
        fp_trimmed[0..max_first_prompt_chars]
    else
        fp_trimmed;
    const sm_trimmed = std.mem.trim(u8, summary, " \t\r\n");

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("Write a 3-6 word title for this coding session.\n\n");
    try w.writeAll("First user request:\n");
    if (fp_capped.len > 0) {
        try w.writeAll(fp_capped);
    } else {
        try w.writeAll("(none)");
    }
    if (sm_trimmed.len > 0) {
        try w.writeAll("\n\nSummary so far:\n");
        try w.writeAll(sm_trimmed);
    }
    try w.writeAll("\n\nTitle:");

    return out.toOwnedSlice();
}

/// Parse the model's raw response into a clean one-line title. Takes the first
/// non-empty line, trims it, strips a single pair of surrounding ASCII quotes
/// (`"` or `'`), collapses internal whitespace runs to single spaces (which
/// also removes embedded newlines/tabs so the title can never corrupt a TSV
/// row), and truncates to `MAX_TITLE_LEN`. Returns null when the result is
/// empty/whitespace-only. Caller owns the returned slice.
pub fn parseTitle(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
    // First non-empty line only -- chatty models sometimes add a second line.
    var first_line: []const u8 = "";
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len > 0) {
            first_line = t;
            break;
        }
    }
    if (first_line.len == 0) return null;

    // Strip one pair of matching surrounding quotes.
    var inner = first_line;
    if (inner.len >= 2) {
        const a = inner[0];
        const b = inner[inner.len - 1];
        if ((a == '"' and b == '"') or (a == '\'' and b == '\'')) {
            inner = inner[1 .. inner.len - 1];
        }
    }
    inner = std.mem.trim(u8, inner, " \t\r");
    if (inner.len == 0) return null;

    // Collapse internal whitespace runs to a single space. Any control
    // characters (newline, tab, etc.) count as whitespace and are squeezed,
    // so the resulting title is single-line and TSV-safe.
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    var prev_space = false;
    for (inner) |ch| {
        const is_space = ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n' or ch < 0x20;
        if (is_space) {
            if (!prev_space and out.items.len > 0) {
                try out.append(' ');
            }
            prev_space = true;
        } else {
            try out.append(ch);
            prev_space = false;
        }
        if (out.items.len >= MAX_TITLE_LEN) break;
    }

    // Drop a trailing collapsed space, if any.
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
        _ = out.pop();
    }
    if (out.items.len == 0) {
        out.deinit();
        return null;
    }
    return @as(?[]u8, try out.toOwnedSlice());
}

const testing = std.testing;

test "buildPrompt includes first prompt and summary" {
    const p = try buildPrompt(testing.allocator, "Fix the login button", "User reported a 500 on submit.");
    defer testing.allocator.free(p);
    try testing.expect(std.mem.indexOf(u8, p, "Fix the login button") != null);
    try testing.expect(std.mem.indexOf(u8, p, "User reported a 500 on submit.") != null);
    try testing.expect(std.mem.indexOf(u8, p, "Title:") != null);
}

test "buildPrompt omits summary section when empty" {
    const p = try buildPrompt(testing.allocator, "Add a parser", "");
    defer testing.allocator.free(p);
    try testing.expect(std.mem.indexOf(u8, p, "Summary so far:") == null);
    try testing.expect(std.mem.indexOf(u8, p, "Add a parser") != null);
}

test "parseTitle strips surrounding quotes" {
    const t = (try parseTitle(testing.allocator, "\"Fix login bug\"\n")).?;
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("Fix login bug", t);
}

test "parseTitle strips single quotes" {
    const t = (try parseTitle(testing.allocator, "'Refactor auth middleware'")).?;
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("Refactor auth middleware", t);
}

test "parseTitle returns null on empty / whitespace" {
    try testing.expectEqual(@as(?[]u8, null), try parseTitle(testing.allocator, ""));
    try testing.expectEqual(@as(?[]u8, null), try parseTitle(testing.allocator, "   \n\t  \n"));
}

test "parseTitle takes first non-empty line and collapses whitespace" {
    const t = (try parseTitle(testing.allocator, "  Fix\tthe   login\n\nSecond line ignored")).?;
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("Fix the login", t);
}

test "parseTitle truncates to MAX_TITLE_LEN and trims trailing space" {
    var long_buf: [200]u8 = undefined;
    @memset(&long_buf, 'a');
    const t = (try parseTitle(testing.allocator, &long_buf)).?;
    defer testing.allocator.free(t);
    try testing.expect(t.len <= MAX_TITLE_LEN);
    try testing.expect(t.len > 0);
}
