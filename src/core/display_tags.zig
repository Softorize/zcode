const std = @import("std");
const std_io = @import("std_io.zig");

/// Strip XML-like `<tag>…</tag>` blocks from text for display in UI
/// titles and previews. Ported from
/// claude-code-main/src/utils/displayTags.ts.
///
/// The upstream reference uses the regex
///
///     /<([a-z][\w-]*)(?:\s[^>]*)?>[\s\S]*?<\/\1>\n?/g
///
/// which matches any XML-like block whose tag name begins with a
/// lowercase letter. The lowercase restriction means user prose
/// containing JSX or HTML ("fix the <Button> layout", "<!DOCTYPE html>")
/// passes through unchanged because those tags start with an uppercase
/// letter or `!`. Unpaired angle brackets ("when x < y") are left alone
/// because they have no matching closing tag.
///
/// This module ports the three public helpers that use that pattern:
///
///   stripDisplayTags -- trim after stripping; fall back to the
///     original text if the result is empty (so previews never
///     collapse to nothing).
///   stripDisplayTagsAllowEmpty -- same, but return empty when all
///     content was tags. Callers use the empty result to detect
///     command-only prompts and fall through to the next fallback.
///   stripIdeContextTags -- strip only `<ide_opened_file>` and
///     `<ide_selection>` blocks. Used by UP-arrow resubmit so lowercase
///     HTML in user prose (`<code>foo</code>`) survives while IDE
///     metadata is dropped.
///
/// All three return an owned slice that the caller must free via
/// `allocator.free`.
pub fn stripDisplayTags(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const raw = try stripBlocks(allocator, text, .any);
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        return try allocator.dupe(u8, text);
    }
    return try allocator.dupe(u8, trimmed);
}

pub fn stripDisplayTagsAllowEmpty(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const raw = try stripBlocks(allocator, text, .any);
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return try allocator.dupe(u8, trimmed);
}

pub fn stripIdeContextTags(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const raw = try stripBlocks(allocator, text, .ide_only);
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return try allocator.dupe(u8, trimmed);
}

const BlockFilter = enum { any, ide_only };

fn stripBlocks(allocator: std.mem.Allocator, text: []const u8, filter: BlockFilter) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    try out.ensureTotalCapacity(text.len);

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '<') {
            try out.append(text[i]);
            i += 1;
            continue;
        }

        // Parse `<lowercase-tag-name>` optionally followed by attributes.
        const tag_start = i + 1;
        if (tag_start >= text.len) {
            try out.append(text[i]);
            i += 1;
            continue;
        }
        const first = text[tag_start];
        if (first < 'a' or first > 'z') {
            try out.append(text[i]);
            i += 1;
            continue;
        }

        var tag_end = tag_start + 1;
        while (tag_end < text.len) : (tag_end += 1) {
            const c = text[tag_end];
            if ((c >= 'a' and c <= 'z') or
                (c >= 'A' and c <= 'Z') or
                (c >= '0' and c <= '9') or
                c == '_' or c == '-') continue;
            break;
        }
        const tag_name = text[tag_start..tag_end];

        if (filter == .ide_only) {
            const allowed = std.mem.eql(u8, tag_name, "ide_opened_file") or
                std.mem.eql(u8, tag_name, "ide_selection");
            if (!allowed) {
                try out.append(text[i]);
                i += 1;
                continue;
            }
        }

        // Match `(\s[^>]*)?>` -- optional whitespace-led attribute
        // list terminated by `>`. This accepts `<tag>`, `<tag foo="bar">`,
        // and `<tag   >` but rejects `<tagno-space-attr>` (no attribute
        // list would begin without whitespace in the reference regex).
        var cursor = tag_end;
        if (cursor < text.len and text[cursor] != '>') {
            if (!std.ascii.isWhitespace(text[cursor])) {
                try out.append(text[i]);
                i += 1;
                continue;
            }
            while (cursor < text.len and text[cursor] != '>') : (cursor += 1) {}
        }
        if (cursor >= text.len or text[cursor] != '>') {
            try out.append(text[i]);
            i += 1;
            continue;
        }
        const body_start = cursor + 1;

        // Non-greedy search for the matching `</tag_name>`.
        var search = body_start;
        var close_end: ?usize = null;
        while (search < text.len) {
            const lt = std.mem.indexOfScalarPos(u8, text, search, '<') orelse break;
            // Need room for `</` + name + `>`
            if (lt + 2 + tag_name.len >= text.len) break;
            if (text[lt + 1] != '/') {
                search = lt + 1;
                continue;
            }
            const candidate = text[lt + 2 .. lt + 2 + tag_name.len];
            if (!std.mem.eql(u8, candidate, tag_name)) {
                search = lt + 1;
                continue;
            }
            const after_name = lt + 2 + tag_name.len;
            if (after_name >= text.len or text[after_name] != '>') {
                search = lt + 1;
                continue;
            }
            close_end = after_name + 1;
            break;
        }

        if (close_end) |end| {
            // Consume optional trailing newline that separated the block
            // from following prose in the source text.
            var skip_end = end;
            if (skip_end < text.len and text[skip_end] == '\n') skip_end += 1;
            i = skip_end;
            continue;
        }

        // Unpaired open tag -- treat the `<` as literal prose and
        // continue scanning. This matches the reference regex behavior
        // (the whole match fails, so the `<` is preserved).
        try out.append(text[i]);
        i += 1;
    }

    return try out.toOwnedSlice();
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "stripDisplayTags removes single tag block" {
    const out = try stripDisplayTags(testing.allocator, "hello <ide_opened_file>x.ts</ide_opened_file> world");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello  world", out);
}

test "stripDisplayTags removes multi-line tag block" {
    const text = "before\n<task_notification>\n  line one\n  line two\n</task_notification>\nafter";
    const out = try stripDisplayTags(testing.allocator, text);
    defer testing.allocator.free(out);
    // The closing `</task_notification>\n` is consumed by the `\n?`
    // trailing-newline rule, leaving just one newline between prose.
    try testing.expectEqualStrings("before\nafter", out);
}

test "stripDisplayTags handles adjacent blocks without merging them" {
    const text = "<a>one</a><b>two</b>";
    const out = try stripDisplayTags(testing.allocator, text);
    defer testing.allocator.free(out);
    // Both blocks gone, trimmed result empty -> fall back to original.
    try testing.expectEqualStrings(text, out);
}

test "stripDisplayTags falls back to original when result is empty" {
    const text = "<command-name>foo</command-name>\n";
    const out = try stripDisplayTags(testing.allocator, text);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(text, out);
}

test "stripDisplayTags consumes optional trailing newline" {
    const text = "pre\n<tag>body</tag>\npost";
    const out = try stripDisplayTags(testing.allocator, text);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("pre\npost", out);
}

test "stripDisplayTags preserves uppercase JSX tags" {
    const text = "fix the <Button>click</Button> layout";
    const out = try stripDisplayTags(testing.allocator, text);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(text, out);
}

test "stripDisplayTags preserves DOCTYPE" {
    const text = "<!DOCTYPE html>";
    const out = try stripDisplayTags(testing.allocator, text);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(text, out);
}

test "stripDisplayTags preserves unpaired angle brackets" {
    const text = "when x < y then done";
    const out = try stripDisplayTags(testing.allocator, text);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(text, out);
}

test "stripDisplayTags handles tag with attributes" {
    const text = "keep <meta name=\"kind\" value=\"x\">drop this</meta> prose";
    const out = try stripDisplayTags(testing.allocator, text);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("keep  prose", out);
}

test "stripDisplayTagsAllowEmpty returns empty for command-only prompts" {
    const text = "<command-name>/clear</command-name>\n";
    const out = try stripDisplayTagsAllowEmpty(testing.allocator, text);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
}

test "stripDisplayTagsAllowEmpty keeps prose unchanged" {
    const text = "hello world";
    const out = try stripDisplayTagsAllowEmpty(testing.allocator, text);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello world", out);
}

test "stripIdeContextTags strips only ide tags" {
    const text = "<ide_opened_file>x.ts</ide_opened_file>\nkeep <code>foo</code> plus <task>bar</task>";
    const out = try stripIdeContextTags(testing.allocator, text);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("keep <code>foo</code> plus <task>bar</task>", out);
}

test "stripIdeContextTags leaves other tags alone" {
    const text = "<summary>hi</summary>";
    const out = try stripIdeContextTags(testing.allocator, text);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(text, out);
}

test "stripDisplayTags handles nested tags non-greedily" {
    // Non-greedy: the first `</a>` closes the first `<a>`, so the
    // outer `<a>` block is `<a>1</a>` and the inner `</a>` closes the
    // nested `<a>`. The reference regex is non-greedy, which means
    // the first close tag wins; the trailing `</a>` is left as-is
    // (unpaired close). Match the reference behavior.
    const text = "<a>1<a>2</a>3</a>";
    const out = try stripDisplayTags(testing.allocator, text);
    defer testing.allocator.free(out);
    // After first strip: "3</a>" -- trimmed, not empty.
    try testing.expectEqualStrings("3</a>", out);
}

test "stripDisplayTags ignores tag without closing pair" {
    const text = "plain <lowercase> prose <withclose>x</withclose>";
    const out = try stripDisplayTags(testing.allocator, text);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("plain <lowercase> prose", out);
}

test "stripDisplayTags with digits and underscores in tag name" {
    const text = "<tag_1>hidden</tag_1>visible";
    const out = try stripDisplayTags(testing.allocator, text);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("visible", out);
}
