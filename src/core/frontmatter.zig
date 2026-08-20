const std = @import("std");

/// Minimal markdown frontmatter parser, ported in spirit from
/// claude-code-main/src/utils/frontmatterParser.ts. zcode has at least
/// two ad-hoc parsers (output_styles, memory) that each re-implement
/// the "split on `---\\n`, then walk key: value lines" idiom with
/// slightly different edge-case handling. This module consolidates
/// the core extract/get helpers so every caller gets the same set of
/// behaviours:
///
///   * Works on both `\\n` and `\\r\\n` line endings
///   * Tolerates leading whitespace on the closing `---` fence
///   * Strips trailing CR on values
///   * Strips surrounding single/double quotes
///   * Skips comment lines (`# ...`)
///   * Returns nulls when the frontmatter block is malformed or absent
///
/// Out of scope: YAML list values (`key: [a, b]`) and multi-line block
/// scalars (`key: |`). Callers that need those parse the raw body
/// themselves. The shared parser is deliberately small so it stays
/// usable from any call site without pulling in a full YAML engine.
pub const Block = struct {
    /// Raw bytes of the frontmatter block between the `---` fences,
    /// NOT including the fences themselves or surrounding newlines.
    body: []const u8,
    /// The markdown content after the closing fence, trimmed of
    /// leading `\\r\\n` whitespace but not trailing.
    rest: []const u8,
};

/// Extract the frontmatter block from `raw`. Returns null when the
/// input does not start with a `---` fence or the closing fence is
/// missing. The returned slices alias into `raw` so callers do not
/// need to free them.
pub fn extract(raw: []const u8) ?Block {
    // Opening fence: either "---\n" or "---\r\n", must be at offset 0.
    const nl: usize = blk: {
        if (std.mem.startsWith(u8, raw, "---\n")) break :blk 4;
        if (std.mem.startsWith(u8, raw, "---\r\n")) break :blk 5;
        return null;
    };
    const body_start = nl;

    // Closing fence: "\n---\n" / "\n---\r\n" / "\n---" at EOF. Scan
    // from body_start forward.
    var cursor: usize = body_start;
    while (cursor < raw.len) {
        const line_start = cursor;
        const line_end = std.mem.indexOfScalarPos(u8, raw, cursor, '\n') orelse raw.len;
        const line = std.mem.trimEnd(u8, raw[line_start..line_end], "\r");
        // Accept exactly "---" (no leading space) to match reference.
        if (std.mem.eql(u8, line, "---")) {
            const body_end = if (line_start == 0) 0 else line_start - 1;
            // body_end points at the newline BEFORE the closing fence.
            // Back it up to avoid including a trailing \\r from CRLF.
            var trimmed_end = body_end;
            if (trimmed_end < raw.len and trimmed_end > body_start and raw[trimmed_end] == '\n') {
                // already pointing at \n -- fine
            }
            if (trimmed_end > body_start and raw[trimmed_end - 1] == '\r') trimmed_end -= 1;
            const rest_start = if (line_end + 1 < raw.len) line_end + 1 else raw.len;
            const body_slice = if (trimmed_end > body_start) raw[body_start..trimmed_end] else raw[body_start..body_start];
            return .{
                .body = body_slice,
                .rest = std.mem.trimStart(u8, raw[rest_start..], "\r\n"),
            };
        }
        cursor = line_end + 1;
    }
    return null;
}

/// Look up a frontmatter key's value in the body slice produced by
/// `extract`. Returns null when the key is missing. Whitespace and
/// wrapping `'` or `"` quotes are stripped from the value. Lines that
/// start with `#` are treated as comments and skipped. Key lookups
/// are exact, case-sensitive matches.
pub fn getValue(body: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;
        const sep = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const line_key = std.mem.trim(u8, line[0..sep], " \t");
        if (!std.mem.eql(u8, line_key, key)) continue;
        const raw_value = std.mem.trim(u8, line[sep + 1 ..], " \t");
        return stripWrappingQuotes(raw_value);
    }
    return null;
}

fn stripWrappingQuotes(value: []const u8) []const u8 {
    if (value.len < 2) return value;
    const first = value[0];
    const last = value[value.len - 1];
    if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
        return value[1 .. value.len - 1];
    }
    return value;
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "extract returns body and rest for a well-formed block" {
    const raw = "---\nname: Explanatory\ndescription: Teaching-focused\n---\n# Heading\n\nBody text\n";
    const block = extract(raw).?;
    try testing.expect(std.mem.indexOf(u8, block.body, "name: Explanatory") != null);
    try testing.expect(std.mem.indexOf(u8, block.body, "description: Teaching-focused") != null);
    try testing.expect(std.mem.startsWith(u8, block.rest, "# Heading"));
}

test "extract handles CRLF line endings" {
    const raw = "---\r\nname: Foo\r\n---\r\nbody\r\n";
    const block = extract(raw).?;
    try testing.expect(std.mem.indexOf(u8, block.body, "name: Foo") != null);
    try testing.expectEqualStrings("body\r\n", block.rest);
}

test "extract returns null when the opening fence is missing" {
    const raw = "# Heading\n\nBody\n";
    try testing.expectEqual(@as(?Block, null), extract(raw));
}

test "extract returns null when the closing fence is missing" {
    const raw = "---\nname: Foo\nno closing fence\n";
    try testing.expectEqual(@as(?Block, null), extract(raw));
}

test "extract returns an empty body for an empty frontmatter block" {
    const raw = "---\n---\nbody\n";
    const block = extract(raw).?;
    try testing.expectEqualStrings("", block.body);
    try testing.expectEqualStrings("body\n", block.rest);
}

test "getValue returns the trimmed value for a key" {
    const body = "name: Explanatory\ndescription: Teaching-focused mode\nversion: 1\n";
    try testing.expectEqualStrings("Explanatory", getValue(body, "name").?);
    try testing.expectEqualStrings("Teaching-focused mode", getValue(body, "description").?);
    try testing.expectEqualStrings("1", getValue(body, "version").?);
}

test "getValue strips surrounding double and single quotes" {
    const body =
        \\name: "quoted string"
        \\other: 'single quoted'
        \\both: "not wrapping'
    ;
    try testing.expectEqualStrings("quoted string", getValue(body, "name").?);
    try testing.expectEqualStrings("single quoted", getValue(body, "other").?);
    // Mismatched quotes stay as-is
    try testing.expectEqualStrings("\"not wrapping'", getValue(body, "both").?);
}

test "getValue skips comment lines" {
    const body = "# this is a comment: not a key\nname: real name\n# more: comment\n";
    try testing.expectEqualStrings("real name", getValue(body, "name").?);
    try testing.expectEqual(@as(?[]const u8, null), getValue(body, "this is a comment"));
}

test "getValue returns null for a missing key" {
    const body = "name: Foo\n";
    try testing.expectEqual(@as(?[]const u8, null), getValue(body, "missing"));
}

test "getValue tolerates trailing CR bytes" {
    const body = "name: Foo\r\ndescription: Bar\r\n";
    try testing.expectEqualStrings("Foo", getValue(body, "name").?);
    try testing.expectEqualStrings("Bar", getValue(body, "description").?);
}

test "getValue returns empty string for bare key: (no value)" {
    const body = "name: \ndescription: Foo\n";
    try testing.expectEqualStrings("", getValue(body, "name").?);
    try testing.expectEqualStrings("Foo", getValue(body, "description").?);
}
