const std = @import("std");
const std_io = @import("std_io.zig");

/// Convert an HTML body into plain readable text. Rough port of the
/// turndown/cheerio pipeline that `claude-code-main/src/tools/WebFetchTool`
/// uses to keep WebFetch results under the model's context budget.
///
/// The real reference pipeline preserves a lot more structure (lists,
/// headings, tables, code blocks). This pass is the bare minimum that
/// gives us the 80% context win: strip every `<script>` and `<style>`
/// block, drop every tag, decode the handful of HTML entities that
/// show up in practice, and collapse the runaway whitespace that
/// tags leave behind.
///
/// Why we bother:
///   - Raw HTML is ~5-10x larger than its readable text equivalent.
///     A typical docs page is ~80 KiB raw vs ~10 KiB cleaned -- the
///     difference between "takes half the model's context window"
///     and "fits alongside 5 other tool results".
///   - Inline `<style>` blocks confuse models into thinking CSS rules
///     are content. The stripper removes them entirely.
///   - The reference's output is pure text, so models trained on
///     claude-code-main expect it. Returning raw HTML puts our
///     fetch output in a different distribution.
///
/// Non-goals (left for a future pass):
///   - Markdown-ification of lists/headings/tables.
///   - Keeping link URLs as `[text](url)`.
///   - Handling srcdoc iframes, math blocks, or SVG source.
pub fn htmlToText(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    try buf.ensureTotalCapacity(html.len / 2 + 128);

    // Cursor walks the original HTML. We skip past <script>/<style>
    // blocks entirely, treat block-level tags as paragraph breaks,
    // and drop every other tag.
    var i: usize = 0;
    var last_was_space = true; // suppress leading whitespace

    while (i < html.len) {
        const c = html[i];
        if (c == '<') {
            // Comment: <!-- ... -->
            if (startsWithAt(html, i, "<!--")) {
                const end_rel = std.mem.indexOfPos(u8, html, i + 4, "-->") orelse html.len;
                i = @min(end_rel + 3, html.len);
                continue;
            }
            // Doctype / CDATA / declaration: <! ... >
            if (i + 1 < html.len and html[i + 1] == '!') {
                const end_rel = std.mem.indexOfScalarPos(u8, html, i, '>') orelse html.len;
                i = @min(end_rel + 1, html.len);
                continue;
            }
            // Script / style blocks: skip content until closing tag.
            if (startsWithTagCaseInsensitive(html, i, "script")) {
                i = skipUntilCloseTag(html, i, "script");
                // Treat as paragraph break so adjacent content stays
                // separated (no "inline" merging of prev + next).
                try appendParagraphBreak(&buf, &last_was_space);
                continue;
            }
            if (startsWithTagCaseInsensitive(html, i, "style")) {
                i = skipUntilCloseTag(html, i, "style");
                try appendParagraphBreak(&buf, &last_was_space);
                continue;
            }
            if (startsWithTagCaseInsensitive(html, i, "noscript")) {
                i = skipUntilCloseTag(html, i, "noscript");
                try appendParagraphBreak(&buf, &last_was_space);
                continue;
            }

            // Generic tag: determine if it's block-level so we can
            // force a paragraph break on close. The cheap proxy is
            // matching by first-letter casefold.
            const tag_end = std.mem.indexOfScalarPos(u8, html, i + 1, '>') orelse html.len;
            const tag_body = html[i + 1 .. @min(tag_end, html.len)];
            const is_close = tag_body.len > 0 and tag_body[0] == '/';
            const name_start: usize = if (is_close) 1 else 0;
            var name_end: usize = name_start;
            while (name_end < tag_body.len and tag_body[name_end] != ' ' and tag_body[name_end] != '\t' and tag_body[name_end] != '/' and tag_body[name_end] != '>') : (name_end += 1) {}
            const tag_name = tag_body[name_start..name_end];

            if (isBlockTag(tag_name) or isLineBreakTag(tag_name)) {
                try appendParagraphBreak(&buf, &last_was_space);
            }

            // `<li>` opens a paragraph with a bullet prefix so the
            // model can see list structure even though we're not
            // doing full markdown. Same for `<h1>`..`<h6>`.
            if (!is_close) {
                if (std.ascii.eqlIgnoreCase(tag_name, "li")) {
                    try buf.appendSlice("- ");
                    last_was_space = false;
                }
            }

            i = @min(tag_end + 1, html.len);
            continue;
        }

        if (c == '&') {
            // Entity decode. The table covers the common ones; anything
            // else falls through as a literal character.
            if (decodeEntity(html, i)) |decoded| {
                try buf.appendSlice(decoded.text);
                i += decoded.consumed;
                last_was_space = decoded.text.len == 1 and (decoded.text[0] == ' ' or decoded.text[0] == '\n');
                continue;
            }
        }

        // Collapse runs of whitespace to a single space. Newlines in
        // HTML source are just formatting -- the visible whitespace
        // comes from CSS, which we don't interpret.
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            if (!last_was_space) {
                try buf.append(' ');
                last_was_space = true;
            }
            i += 1;
            continue;
        }

        try buf.append(c);
        last_was_space = false;
        i += 1;
    }

    // Final tidy: trim trailing whitespace, collapse any runs of 3+
    // newlines (possible when multiple block closes chained) to 2.
    const raw = buf.items();
    return tidyWhitespace(allocator, raw);
}

const DecodedEntity = struct {
    text: []const u8,
    consumed: usize,
};

fn decodeEntity(html: []const u8, start: usize) ?DecodedEntity {
    // Named entities we actually care about. The real reference
    // handles every HTML5 named entity; this table covers the 99%.
    const Entry = struct { name: []const u8, replacement: []const u8 };
    const named = [_]Entry{
        .{ .name = "&amp;", .replacement = "&" },
        .{ .name = "&lt;", .replacement = "<" },
        .{ .name = "&gt;", .replacement = ">" },
        .{ .name = "&quot;", .replacement = "\"" },
        .{ .name = "&apos;", .replacement = "'" },
        .{ .name = "&nbsp;", .replacement = " " },
        .{ .name = "&copy;", .replacement = "(c)" },
        .{ .name = "&reg;", .replacement = "(R)" },
        .{ .name = "&trade;", .replacement = "(TM)" },
        .{ .name = "&hellip;", .replacement = "..." },
        .{ .name = "&mdash;", .replacement = "--" },
        .{ .name = "&ndash;", .replacement = "-" },
        .{ .name = "&rsquo;", .replacement = "'" },
        .{ .name = "&lsquo;", .replacement = "'" },
        .{ .name = "&rdquo;", .replacement = "\"" },
        .{ .name = "&ldquo;", .replacement = "\"" },
        .{ .name = "&laquo;", .replacement = "<<" },
        .{ .name = "&raquo;", .replacement = ">>" },
        .{ .name = "&middot;", .replacement = "*" },
        .{ .name = "&bull;", .replacement = "*" },
    };
    for (named) |e| {
        if (startsWithAt(html, start, e.name)) {
            return .{ .text = e.replacement, .consumed = e.name.len };
        }
    }

    // Numeric entities: &#NNN; or &#xHH;
    if (start + 2 < html.len and html[start] == '&' and html[start + 1] == '#') {
        const is_hex = html[start + 2] == 'x' or html[start + 2] == 'X';
        const num_start = if (is_hex) start + 3 else start + 2;
        var num_end = num_start;
        while (num_end < html.len and html[num_end] != ';' and (num_end - num_start) < 8) : (num_end += 1) {
            const ch = html[num_end];
            const ok = if (is_hex)
                (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F')
            else
                (ch >= '0' and ch <= '9');
            if (!ok) break;
        }
        if (num_end > num_start and num_end < html.len and html[num_end] == ';') {
            const base: u8 = if (is_hex) 16 else 10;
            const code = std.fmt.parseInt(u21, html[num_start..num_end], base) catch return null;
            // ASCII fast path.
            if (code < 128) {
                return .{ .text = asciiByteFor(code), .consumed = num_end - start + 1 };
            }
            // Non-ASCII numeric entities: for the common printable BMP
            // range, we'd need UTF-8 re-encoding. For now, drop them to
            // a single space so the output stays ASCII-clean. Future
            // pass can do proper UTF-8 encoding.
            return .{ .text = " ", .consumed = num_end - start + 1 };
        }
    }

    return null;
}

/// Static table of single-byte strings for ASCII char codes. Returned
/// slice points into `ascii_table` so it has process-lifetime. Code
/// 0 returns empty to avoid NUL bytes in output.
fn asciiByteFor(code: u21) []const u8 {
    const byte: u8 = @intCast(code);
    if (byte == 0) return "";
    return ascii_table[byte..(byte + 1)];
}

const ascii_table: [128]u8 = blk: {
    var t: [128]u8 = undefined;
    var i: u8 = 0;
    while (i < 128) : (i += 1) t[i] = i;
    break :blk t;
};

fn startsWithAt(haystack: []const u8, pos: usize, needle: []const u8) bool {
    if (pos + needle.len > haystack.len) return false;
    return std.mem.eql(u8, haystack[pos .. pos + needle.len], needle);
}

/// Case-insensitive match against the tag name starting at `pos`. Expects
/// `html[pos] == '<'` and returns true if the tag name that follows
/// case-folds to `name` (optionally followed by whitespace/`>`).
fn startsWithTagCaseInsensitive(html: []const u8, pos: usize, name: []const u8) bool {
    if (pos >= html.len or html[pos] != '<') return false;
    var j: usize = pos + 1;
    if (j < html.len and html[j] == '/') j += 1;
    if (j + name.len > html.len) return false;
    for (name, 0..) |ch, k| {
        if (std.ascii.toLower(html[j + k]) != std.ascii.toLower(ch)) return false;
    }
    // Tag name must end in whitespace, '>', or '/' -- otherwise it's
    // a longer tag (e.g. "scripting").
    const after = j + name.len;
    if (after >= html.len) return true;
    const ch = html[after];
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n' or ch == '>' or ch == '/';
}

fn skipUntilCloseTag(html: []const u8, start: usize, name: []const u8) usize {
    // Find `</name` from `start` onwards. Simple substring match; the
    // real reference does a proper tokenized walk. For 99% of pages
    // this is fine and much faster to port.
    var close_buf: [32]u8 = undefined;
    if (name.len + 2 >= close_buf.len) return html.len;
    close_buf[0] = '<';
    close_buf[1] = '/';
    @memcpy(close_buf[2 .. 2 + name.len], name);
    const needle = close_buf[0 .. 2 + name.len];

    // Case-insensitive search: walk manually.
    var i = start + 1;
    while (i + needle.len <= html.len) : (i += 1) {
        var matched = true;
        for (needle, 0..) |ch, k| {
            if (std.ascii.toLower(html[i + k]) != std.ascii.toLower(ch)) {
                matched = false;
                break;
            }
        }
        if (matched) {
            // Advance past the '>'.
            const gt = std.mem.indexOfScalarPos(u8, html, i, '>') orelse return html.len;
            return gt + 1;
        }
    }
    return html.len;
}

fn appendParagraphBreak(buf: *std_io.StringBuilder, last_was_space: *bool) !void {
    // Ensure the previous char is a newline. If the buffer is empty,
    // no-op so we don't start output with a leading newline.
    if (buf.items().len == 0) return;
    const prev = buf.items()[buf.items().len - 1];
    if (prev == '\n') {
        // Already at start-of-line; add at most one more newline for
        // a paragraph break.
        if (buf.items().len >= 2 and buf.items()[buf.items().len - 2] != '\n') {
            try buf.append('\n');
        }
    } else {
        try buf.append('\n');
    }
    last_was_space.* = true;
}

fn isBlockTag(name: []const u8) bool {
    const blocks = [_][]const u8{
        "p",      "div",        "section",    "article", "header", "footer",
        "nav",    "aside",      "main",       "hr",      "ul",     "ol",
        "li",     "table",      "tr",         "td",      "th",     "thead",
        "tbody",  "tfoot",      "h1",         "h2",      "h3",     "h4",
        "h5",     "h6",         "blockquote", "pre",     "form",   "fieldset",
        "figure", "figcaption", "dl",         "dt",      "dd",
    };
    for (blocks) |b| if (std.ascii.eqlIgnoreCase(name, b)) return true;
    return false;
}

fn isLineBreakTag(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "br");
}

/// Trim leading/trailing whitespace and collapse runs of 3+ newlines
/// to exactly 2. Returns a fresh allocation owned by the caller.
fn tidyWhitespace(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    try out.ensureTotalCapacity(trimmed.len);

    var newline_run: usize = 0;
    for (trimmed) |c| {
        if (c == '\n') {
            newline_run += 1;
            if (newline_run <= 2) try out.append(c);
            continue;
        }
        newline_run = 0;
        try out.append(c);
    }
    return out.toOwnedSlice();
}

// --- Tests ---

const testing = std.testing;

test "htmlToText strips tags and collapses whitespace" {
    const html = "<html><body><h1>Hello</h1><p>World   of\n\n\n  HTML</p></body></html>";
    const out = try htmlToText(testing.allocator, html);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Hello") != null);
    try testing.expect(std.mem.indexOf(u8, out, "World of HTML") != null);
    // Tag characters must not leak through.
    try testing.expect(std.mem.indexOf(u8, out, "<") == null);
    try testing.expect(std.mem.indexOf(u8, out, ">") == null);
}

test "htmlToText drops script and style block content entirely" {
    const html =
        "<html><head>" ++
        "<style>body { color: red; } .foo { display: none; }</style>" ++
        "<script>var x = 1; alert('hi');</script>" ++
        "</head><body>visible text</body></html>";
    const out = try htmlToText(testing.allocator, html);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "visible text") != null);
    try testing.expect(std.mem.indexOf(u8, out, "color: red") == null);
    try testing.expect(std.mem.indexOf(u8, out, "alert") == null);
    try testing.expect(std.mem.indexOf(u8, out, "var x") == null);
}

test "htmlToText handles case-mixed script tags" {
    const html = "<SCRIPT>bad</SCRIPT>good<Script>also bad</Script>good2";
    const out = try htmlToText(testing.allocator, html);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "good") != null);
    try testing.expect(std.mem.indexOf(u8, out, "bad") == null);
}

test "htmlToText decodes common HTML entities" {
    const html = "<p>Ben &amp; Jerry&#39;s &lt;test&gt; &quot;demo&quot; &mdash; 50&#x25; off</p>";
    const out = try htmlToText(testing.allocator, html);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Ben & Jerry's") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<test>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"demo\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "-- 50%") != null);
    // Raw entity markers must not leak.
    try testing.expect(std.mem.indexOf(u8, out, "&amp;") == null);
    try testing.expect(std.mem.indexOf(u8, out, "&#39;") == null);
}

test "htmlToText strips HTML comments" {
    const html = "before<!-- secret comment --><p>after</p>";
    const out = try htmlToText(testing.allocator, html);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "secret comment") == null);
    try testing.expect(std.mem.indexOf(u8, out, "before") != null);
    try testing.expect(std.mem.indexOf(u8, out, "after") != null);
}

test "htmlToText renders list items with bullet prefixes" {
    const html = "<ul><li>one</li><li>two</li><li>three</li></ul>";
    const out = try htmlToText(testing.allocator, html);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "- one") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- two") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- three") != null);
}

test "htmlToText collapses paragraph breaks to at most two newlines" {
    const html = "<p>a</p><p></p><p></p><p></p><p>b</p>";
    const out = try htmlToText(testing.allocator, html);
    defer testing.allocator.free(out);
    // The string must not contain three consecutive newlines.
    try testing.expect(std.mem.indexOf(u8, out, "\n\n\n") == null);
}

test "htmlToText handles br tags as line breaks" {
    const html = "line one<br>line two<br/>line three";
    const out = try htmlToText(testing.allocator, html);
    defer testing.allocator.free(out);
    // Each line should appear on its own line.
    try testing.expect(std.mem.indexOf(u8, out, "line one") != null);
    try testing.expect(std.mem.indexOf(u8, out, "line two") != null);
    try testing.expect(std.mem.indexOf(u8, out, "line three") != null);
    // There should be at least one newline between "one" and "two".
    const one_idx = std.mem.indexOf(u8, out, "line one").?;
    const two_idx = std.mem.indexOf(u8, out, "line two").?;
    try testing.expect(std.mem.indexOfScalarPos(u8, out, one_idx, '\n').? < two_idx);
}

test "htmlToText passes plain text through unchanged except for whitespace collapse" {
    const html = "just some   plain\n\ntext no tags";
    const out = try htmlToText(testing.allocator, html);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "just some plain") != null);
    try testing.expect(std.mem.indexOf(u8, out, "text no tags") != null);
}

test "htmlToText is substantially smaller than raw HTML for real-world pages" {
    // Realistic docs page: heavy on tags, light on content.
    const html =
        "<!DOCTYPE html><html><head>" ++
        "<meta charset=\"utf-8\"><title>Docs</title>" ++
        "<style>body{font-family:sans-serif;}.nav{display:flex;}.nav a{padding:8px;}</style>" ++
        "<script>window.analytics = function(){};</script>" ++
        "</head><body>" ++
        "<nav class=\"nav\"><a href=\"/home\">Home</a><a href=\"/docs\">Docs</a></nav>" ++
        "<h1>API Reference</h1>" ++
        "<p>This page describes the public API.</p>" ++
        "<h2>Functions</h2>" ++
        "<ul><li>doSomething()</li><li>doSomethingElse()</li></ul>" ++
        "</body></html>";
    const out = try htmlToText(testing.allocator, html);
    defer testing.allocator.free(out);
    // The cleaned output should be meaningfully smaller than the raw
    // HTML, and should still contain the actual content.
    try testing.expect(out.len < html.len / 2);
    try testing.expect(std.mem.indexOf(u8, out, "API Reference") != null);
    try testing.expect(std.mem.indexOf(u8, out, "doSomething()") != null);
    try testing.expect(std.mem.indexOf(u8, out, "window.analytics") == null);
    try testing.expect(std.mem.indexOf(u8, out, "font-family") == null);
}
