const std = @import("std");
const std_io = @import("std_io.zig");

/// Ported from claude-code-main/src/utils/claudeCodeHints.ts.
///
/// CLIs and SDKs running under zcode can emit a self-closing
/// `<claude-code-hint />` tag to stderr (merged into stdout by the
/// shell tool). zcode scans shell output for these tags, strips them
/// before the output reaches the model, and surfaces the hint to the
/// user's log so they can act on it (install a plugin, etc).
///
/// The parser is a pure function so it can be tested in isolation and
/// reused anywhere a tool's stdout is about to be shown to the model.
/// We keep the outer tag name `claude-code-hint` verbatim so a single
/// CLI can speak the protocol to both tools without branching.
pub const HintType = enum {
    plugin,

    pub fn fromString(s: []const u8) ?HintType {
        if (std.mem.eql(u8, s, "plugin")) return .plugin;
        return null;
    }

    pub fn toString(self: HintType) []const u8 {
        return switch (self) {
            .plugin => "plugin",
        };
    }
};

/// One parsed hint tag. Strings are owned by the returned ExtractResult.
pub const Hint = struct {
    v: u32,
    hint_type: HintType,
    value: []u8,
    source_command: []u8,

    pub fn deinit(self: *Hint, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
        allocator.free(self.source_command);
    }
};

/// Output of extractHints. `hints` is heap-owned by caller; `stripped`
/// is a new allocation (even when no hints matched, so the caller's
/// free() logic stays uniform).
pub const ExtractResult = struct {
    hints: []Hint,
    stripped: []u8,

    pub fn deinit(self: *ExtractResult, allocator: std.mem.Allocator) void {
        for (self.hints) |*h| h.deinit(allocator);
        allocator.free(self.hints);
        allocator.free(self.stripped);
    }
};

/// Supported spec versions. Must be kept in sync with the reference's
/// SUPPORTED_VERSIONS set at claudeCodeHints.ts:42. Bumping this is a
/// protocol change and requires a compatibility review.
const SUPPORTED_VERSIONS = [_]u32{1};

fn isSupportedVersion(v: u32) bool {
    for (SUPPORTED_VERSIONS) |sv| if (sv == v) return true;
    return false;
}

/// Returns the token before the first whitespace. Used for `sourceCommand`
/// so the user can spot a mismatch between the tool that emitted the hint
/// and the plugin it recommends (e.g. a `curl` output claiming to hint for
/// a `foo-plugin`).
fn firstCommandToken(command: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    const space = std.mem.indexOfAny(u8, trimmed, " \t") orelse return trimmed;
    return trimmed[0..space];
}

/// Scan `output` for hint tags. Returns parsed hints + the output with
/// matching lines removed. Only whole-line tags are recognised -- a tag
/// buried inside a larger line (e.g. a log statement quoting the marker)
/// is left alone. Matches the reference's HINT_TAG_RE multiline anchoring.
pub fn extractHints(
    allocator: std.mem.Allocator,
    output: []const u8,
    command: []const u8,
) !ExtractResult {
    // Fast path: no tag open sequence at all. Still allocate a copy of
    // the output so the caller's free() works uniformly whether or not
    // any hints were found.
    if (std.mem.indexOf(u8, output, "<claude-code-hint") == null) {
        return ExtractResult{
            .hints = try allocator.alloc(Hint, 0),
            .stripped = try allocator.dupe(u8, output),
        };
    }

    const src_tok = firstCommandToken(command);

    var hints = std.array_list.Managed(Hint).init(allocator);
    errdefer {
        for (hints.items) |*h| h.deinit(allocator);
        hints.deinit();
    }

    var stripped = std_io.StringBuilder.init(allocator);
    errdefer stripped.deinit();

    var cursor: usize = 0;
    while (cursor < output.len) {
        // Find the next newline (or use end-of-string as the sentinel).
        const line_end = std.mem.indexOfScalarPos(u8, output, cursor, '\n') orelse output.len;
        const line_with_newline_len = if (line_end < output.len) line_end - cursor + 1 else line_end - cursor;
        const line = output[cursor..line_end];

        if (isHintCandidate(line)) {
            // Candidate line is always dropped -- if it's a valid hint,
            // we record it; if it's invalid (bad version, wrong type),
            // we still drop it so the model doesn't see half-parsed
            // protocol chatter. Matches the reference's regex replace
            // behaviour at claudeCodeHints.ts:84-108.
            if (parseHintLine(allocator, line, src_tok)) |maybe_hint| {
                if (maybe_hint) |hint| try hints.append(hint);
            } else |err| return err;
            cursor += line_with_newline_len;
            continue;
        }

        // Not a hint line at all: copy it verbatim into the stripped buffer.
        try stripped.appendSlice(output[cursor .. cursor + line_with_newline_len]);
        cursor += line_with_newline_len;
    }

    // Collapse runs of 3+ newlines introduced by dropped lines down to
    // a single blank line so the model-visible output doesn't grow
    // vertical whitespace. Matches the reference's `\n{3,}` collapse.
    const collapsed = try collapseBlankLines(allocator, stripped.items());
    stripped.deinit();

    return ExtractResult{
        .hints = try hints.toOwnedSlice(),
        .stripped = collapsed,
    };
}

/// Cheap syntactic check that `line` looks like a self-closing
/// claude-code-hint tag. Called before parseHintLine so the caller
/// knows whether to drop the line regardless of parse success. A line
/// that passes this check but fails parseHintLine is still dropped --
/// matching the reference's regex-replace behaviour which eats the
/// whole line even when the attrs are malformed.
fn isHintCandidate(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, trimmed, "<claude-code-hint")) return false;
    if (!std.mem.endsWith(u8, trimmed, "/>")) return false;
    // Require whitespace after the tag name so `<claude-code-hintx />`
    // isn't accepted.
    if (trimmed.len <= "<claude-code-hint".len + 2) return false;
    const next = trimmed["<claude-code-hint".len];
    if (next != ' ' and next != '\t' and next != '/') return false;
    return true;
}

/// Parse a single line. Returns null if the line is not a hint tag, a
/// Hint if it is, or propagates allocation errors. Lines that look like
/// hints but fail validation (unknown version/type, empty value) are
/// dropped by the caller via isHintCandidate -- matching the reference's
/// regex-replace that eats whole lines regardless of attr validity.
fn parseHintLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    source_command: []const u8,
) !?Hint {
    const trimmed = std.mem.trim(u8, line, " \t\r");

    // Must start with `<claude-code-hint` (optionally whitespace-trimmed)
    // and end with `/>` to be a self-closing tag.
    const open_marker = "<claude-code-hint";
    if (!std.mem.startsWith(u8, trimmed, open_marker)) return null;
    if (!std.mem.endsWith(u8, trimmed, "/>")) return null;

    // Everything between `<claude-code-hint` and `/>` is the attribute
    // body. We must have at least one whitespace between the tag name
    // and the first attribute, otherwise `<claude-code-hintx />` would
    // match -- reject that.
    const tag_body = trimmed[open_marker.len .. trimmed.len - 2];
    if (tag_body.len == 0) return null;
    if (tag_body[0] != ' ' and tag_body[0] != '\t') return null;
    const attrs_raw = std.mem.trim(u8, tag_body, " \t");

    var v: ?u32 = null;
    var type_str: ?[]const u8 = null;
    var value: ?[]const u8 = null;

    var attr_cursor: usize = 0;
    while (attr_cursor < attrs_raw.len) {
        // Skip whitespace.
        while (attr_cursor < attrs_raw.len and (attrs_raw[attr_cursor] == ' ' or attrs_raw[attr_cursor] == '\t')) {
            attr_cursor += 1;
        }
        if (attr_cursor >= attrs_raw.len) break;

        // Read key up to '='.
        const key_start = attr_cursor;
        while (attr_cursor < attrs_raw.len and attrs_raw[attr_cursor] != '=' and attrs_raw[attr_cursor] != ' ' and attrs_raw[attr_cursor] != '\t') {
            attr_cursor += 1;
        }
        const key = attrs_raw[key_start..attr_cursor];
        if (key.len == 0) break;

        if (attr_cursor >= attrs_raw.len or attrs_raw[attr_cursor] != '=') {
            // Bare attribute without value -- skip it.
            continue;
        }
        attr_cursor += 1; // consume '='

        // Read value: quoted or bareword.
        var val: []const u8 = "";
        if (attr_cursor < attrs_raw.len and attrs_raw[attr_cursor] == '"') {
            attr_cursor += 1;
            const val_start = attr_cursor;
            while (attr_cursor < attrs_raw.len and attrs_raw[attr_cursor] != '"') {
                attr_cursor += 1;
            }
            val = attrs_raw[val_start..attr_cursor];
            if (attr_cursor < attrs_raw.len) attr_cursor += 1; // consume closing quote
        } else {
            const val_start = attr_cursor;
            while (attr_cursor < attrs_raw.len and attrs_raw[attr_cursor] != ' ' and attrs_raw[attr_cursor] != '\t') {
                attr_cursor += 1;
            }
            val = attrs_raw[val_start..attr_cursor];
        }

        if (std.mem.eql(u8, key, "v")) {
            v = std.fmt.parseInt(u32, val, 10) catch null;
        } else if (std.mem.eql(u8, key, "type")) {
            type_str = val;
        } else if (std.mem.eql(u8, key, "value")) {
            value = val;
        }
    }

    // Validate. Reference drops unsupported version/type and empty value.
    const version = v orelse return null;
    if (!isSupportedVersion(version)) return null;

    const type_text = type_str orelse return null;
    const hint_type = HintType.fromString(type_text) orelse return null;

    const val_text = value orelse return null;
    if (val_text.len == 0) return null;

    const value_owned = try allocator.dupe(u8, val_text);
    errdefer allocator.free(value_owned);
    const src_owned = try allocator.dupe(u8, source_command);

    return Hint{
        .v = version,
        .hint_type = hint_type,
        .value = value_owned,
        .source_command = src_owned,
    };
}

fn collapseBlankLines(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    var cursor: usize = 0;
    while (cursor < input.len) {
        const ch = input[cursor];
        if (ch == '\n') {
            // Count consecutive newlines.
            var run: usize = 0;
            while (cursor + run < input.len and input[cursor + run] == '\n') run += 1;
            // A run of 3+ newlines means 2+ blank lines between content.
            // Collapse to exactly 2 newlines (single blank line).
            const emit = if (run >= 3) 2 else run;
            try out.appendNTimes('\n', emit);
            cursor += run;
            continue;
        }
        try out.append(ch);
        cursor += 1;
    }

    return out.toOwnedSlice();
}

const testing = std.testing;

test "no hint tag returns output unchanged and no hints" {
    var result = try extractHints(testing.allocator, "hello world\n", "foo bar");
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.hints.len);
    try testing.expectEqualStrings("hello world\n", result.stripped);
}

test "valid plugin hint is parsed and stripped" {
    const output =
        "running the tool...\n" ++
        "<claude-code-hint v=\"1\" type=\"plugin\" value=\"foo-plugin@official\"/>\n" ++
        "done.\n";
    var result = try extractHints(testing.allocator, output, "foo --bar");
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.hints.len);
    try testing.expectEqual(@as(u32, 1), result.hints[0].v);
    try testing.expectEqual(HintType.plugin, result.hints[0].hint_type);
    try testing.expectEqualStrings("foo-plugin@official", result.hints[0].value);
    try testing.expectEqualStrings("foo", result.hints[0].source_command);
    try testing.expectEqualStrings("running the tool...\ndone.\n", result.stripped);
}

test "bareword attribute value without quotes is accepted" {
    const output = "<claude-code-hint v=1 type=plugin value=bar-plugin@catalog/>\n";
    var result = try extractHints(testing.allocator, output, "bar");
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.hints.len);
    try testing.expectEqualStrings("bar-plugin@catalog", result.hints[0].value);
}

test "unsupported version is dropped and content stripped" {
    const output =
        "<claude-code-hint v=\"999\" type=\"plugin\" value=\"foo\"/>\n" ++
        "after\n";
    var result = try extractHints(testing.allocator, output, "foo");
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.hints.len);
    // The malformed hint line is dropped same as a valid one.
    try testing.expectEqualStrings("after\n", result.stripped);
}

test "unknown type is dropped" {
    const output = "<claude-code-hint v=\"1\" type=\"gibberish\" value=\"foo\"/>\n";
    var result = try extractHints(testing.allocator, output, "foo");
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.hints.len);
}

test "empty value is dropped" {
    const output = "<claude-code-hint v=\"1\" type=\"plugin\" value=\"\"/>\n";
    var result = try extractHints(testing.allocator, output, "foo");
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.hints.len);
}

test "hint tag inside a larger line is not recognised" {
    // A log statement quoting the tag must not be treated as a hint,
    // matching the reference's whole-line anchoring.
    const output = "LOG: found tag <claude-code-hint v=\"1\" type=\"plugin\" value=\"foo\"/> in stdout\n";
    var result = try extractHints(testing.allocator, output, "foo");
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.hints.len);
    try testing.expectEqualStrings(output, result.stripped);
}

test "firstCommandToken handles paths and args" {
    try testing.expectEqualStrings("foo", firstCommandToken("foo"));
    try testing.expectEqualStrings("foo", firstCommandToken("foo bar baz"));
    try testing.expectEqualStrings("/usr/bin/git", firstCommandToken("/usr/bin/git status"));
    try testing.expectEqualStrings("cmd", firstCommandToken("  cmd  with-trim  "));
}

test "multiple hints in one output are all collected" {
    const output =
        "<claude-code-hint v=\"1\" type=\"plugin\" value=\"a\"/>\n" ++
        "middle\n" ++
        "<claude-code-hint v=\"1\" type=\"plugin\" value=\"b\"/>\n";
    var result = try extractHints(testing.allocator, output, "source-cmd");
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.hints.len);
    try testing.expectEqualStrings("a", result.hints[0].value);
    try testing.expectEqualStrings("b", result.hints[1].value);
    try testing.expectEqualStrings("middle\n", result.stripped);
}

test "leading whitespace on hint line is tolerated" {
    const output = "  \t<claude-code-hint v=\"1\" type=\"plugin\" value=\"x\"/>\t \n";
    var result = try extractHints(testing.allocator, output, "cmd");
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.hints.len);
}

test "collapseBlankLines caps runs of newlines at two" {
    const collapsed = try collapseBlankLines(testing.allocator, "a\n\n\n\nb");
    defer testing.allocator.free(collapsed);
    try testing.expectEqualStrings("a\n\nb", collapsed);
}

test "isSupportedVersion recognises v=1" {
    try testing.expect(isSupportedVersion(1));
    try testing.expect(!isSupportedVersion(0));
    try testing.expect(!isSupportedVersion(2));
    try testing.expect(!isSupportedVersion(999));
}
