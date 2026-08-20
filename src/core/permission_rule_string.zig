//! P2 (PRD #534) permissions-11: reference-compatible parser/serializer for
//! `Tool(content)` permission-rule strings.
//!
//! The reference stores permission rules as opaque `Tool(content)` strings
//! (e.g. `Bash(npm install)`, `Edit`, `Bash(python -c "print\(1\)")`). This
//! module ports that grammar so later tasks can speak the same rule vocabulary
//! while zcode keeps its structured TSV store underneath.
//!
//! Grammar notes (matching the reference permissionRuleParser.ts behavior):
//!  - A bare `Tool` (no parens) is a tool-wide rule (rule_content == null).
//!  - The split point is the FIRST unescaped `(`; the close is the LAST
//!    unescaped `)`. Parens inside the content are escaped with a backslash.
//!  - An unescaped `(` that is not followed by a matching unescaped `)` at the
//!    end of the string, content after the closing paren, an empty content
//!    `Tool()`, or a `*` content `Tool(*)` all collapse to a tool-wide rule.
//!  - The tool name is canonicalized through tool_name_map (legacy aliasing:
//!    e.g. `Task` -> `Agent`). The content is preserved verbatim (after
//!    unescaping).
//!
//! Pure module: only `std` + allocator. No IO, no runtime singleton.

const std = @import("std");
const tool_name_map = @import("tool_name_map.zig");

/// Parsed representation of a `Tool(content)` rule string.
///
/// Ownership: `parse` allocates both fields with the caller-supplied allocator;
/// call `deinit` with the SAME allocator to free them. `rule_content == null`
/// means the rule applies to the whole tool (no content key).
pub const RuleValue = struct {
    tool_name: []const u8,
    rule_content: ?[]const u8,

    pub fn deinit(self: *RuleValue, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_name);
        if (self.rule_content) |c| allocator.free(c);
        self.* = undefined;
    }
};

/// Return the index of the first `target` byte in `s` that is not escaped by an
/// odd run of preceding backslashes, or null. Ports findFirstUnescapedChar:
/// a char is unescaped when the count of consecutive `\` immediately before it
/// is even.
fn findFirstUnescapedChar(s: []const u8, target: u8) ?usize {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != target) continue;
        var backslashes: usize = 0;
        var j = i;
        while (j > 0 and s[j - 1] == '\\') : (j -= 1) backslashes += 1;
        if (backslashes % 2 == 0) return i;
    }
    return null;
}

/// Return the index of the last unescaped `target` byte in `s`, or null. Ports
/// findLastUnescapedChar.
fn findLastUnescapedChar(s: []const u8, target: u8) ?usize {
    if (s.len == 0) return null;
    var i: usize = s.len;
    while (i > 0) {
        i -= 1;
        if (s[i] != target) continue;
        var backslashes: usize = 0;
        var j = i;
        while (j > 0 and s[j - 1] == '\\') : (j -= 1) backslashes += 1;
        if (backslashes % 2 == 0) return i;
    }
    return null;
}

/// Escape rule content for serialization. Order matters and matches the
/// reference escapeRuleContent: backslashes first, THEN parens, so a literal
/// backslash does not double-escape a following paren.
pub fn escape(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (content) |c| {
        switch (c) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '(' => try out.appendSlice(allocator, "\\("),
            ')' => try out.appendSlice(allocator, "\\)"),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Unescape rule content. Order matters and matches the reference
/// unescapeRuleContent: parens first, THEN backslashes. A single backslash
/// scan handles the backslash-parity rule (do NOT use std.mem.replace, which
/// ignores escaping).
pub fn unescape(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            const next = raw[i + 1];
            switch (next) {
                '(', ')', '\\' => {
                    try out.append(allocator, next);
                    i += 1;
                    continue;
                },
                else => {},
            }
        }
        try out.append(allocator, raw[i]);
    }
    return out.toOwnedSlice(allocator);
}

/// Parse a `Tool(content)` rule string into a RuleValue. The returned slices are
/// owned by the caller; free with `RuleValue.deinit`.
pub fn parse(allocator: std.mem.Allocator, rule_string: []const u8) !RuleValue {
    const open = findFirstUnescapedChar(rule_string, '(');

    // No unescaped `(` -> tool-wide rule, whole string is the tool name.
    if (open == null) {
        return .{
            .tool_name = try dupCanonical(allocator, rule_string),
            .rule_content = null,
        };
    }

    const open_idx = open.?;
    const close = findLastUnescapedChar(rule_string, ')');

    // No closing `)`, close before the open, or content after the close ->
    // malformed; treat the whole string as the tool name (tool-wide).
    if (close == null or close.? <= open_idx or close.? != rule_string.len - 1) {
        return .{
            .tool_name = try dupCanonical(allocator, rule_string),
            .rule_content = null,
        };
    }

    const close_idx = close.?;
    const tool_part = rule_string[0..open_idx];

    // Empty tool name (e.g. `(foo)`) -> whole string is the tool name.
    if (tool_part.len == 0) {
        return .{
            .tool_name = try dupCanonical(allocator, rule_string),
            .rule_content = null,
        };
    }

    const raw_content = rule_string[open_idx + 1 .. close_idx];

    // Empty or `*` content collapses to a tool-wide rule.
    if (raw_content.len == 0 or (raw_content.len == 1 and raw_content[0] == '*')) {
        return .{
            .tool_name = try dupCanonical(allocator, tool_part),
            .rule_content = null,
        };
    }

    const tool_name = try dupCanonical(allocator, tool_part);
    errdefer allocator.free(tool_name);
    const content = try unescape(allocator, raw_content);
    return .{
        .tool_name = tool_name,
        .rule_content = content,
    };
}

/// Serialize a RuleValue back to a `Tool(content)` rule string. Tool-wide rules
/// (rule_content == null) render as just the tool name. The returned slice is
/// owned by the caller.
pub fn toString(allocator: std.mem.Allocator, value: RuleValue) ![]u8 {
    if (value.rule_content == null) {
        return allocator.dupe(u8, value.tool_name);
    }
    const escaped = try escape(allocator, value.rule_content.?);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator, "{s}({s})", .{ value.tool_name, escaped });
}

/// Duplicate `name` after running it through the legacy alias canonicalizer.
fn dupCanonical(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return allocator.dupe(u8, tool_name_map.canonical(name));
}

const testing = std.testing;

test "parse bare tool name is tool-wide" {
    var v = try parse(testing.allocator, "Bash");
    defer v.deinit(testing.allocator);
    try testing.expectEqualStrings("Bash", v.tool_name);
    try testing.expect(v.rule_content == null);
}

test "parse tool with simple content" {
    var v = try parse(testing.allocator, "Bash(npm install)");
    defer v.deinit(testing.allocator);
    try testing.expectEqualStrings("Bash", v.tool_name);
    try testing.expect(v.rule_content != null);
    try testing.expectEqualStrings("npm install", v.rule_content.?);
}

test "parse content with escaped parens unescapes" {
    var v = try parse(testing.allocator, "Bash(python -c \"print\\(1\\)\")");
    defer v.deinit(testing.allocator);
    try testing.expectEqualStrings("Bash", v.tool_name);
    try testing.expect(v.rule_content != null);
    try testing.expectEqualStrings("python -c \"print(1)\"", v.rule_content.?);
}

test "parse empty content is tool-wide" {
    var v = try parse(testing.allocator, "Bash()");
    defer v.deinit(testing.allocator);
    try testing.expectEqualStrings("Bash", v.tool_name);
    try testing.expect(v.rule_content == null);
}

test "parse star content is tool-wide" {
    var v = try parse(testing.allocator, "Bash(*)");
    defer v.deinit(testing.allocator);
    try testing.expectEqualStrings("Bash", v.tool_name);
    try testing.expect(v.rule_content == null);
}

test "parse applies legacy alias to tool name only" {
    var v = try parse(testing.allocator, "Task(Explore)");
    defer v.deinit(testing.allocator);
    try testing.expectEqualStrings("Agent", v.tool_name);
    try testing.expect(v.rule_content != null);
    try testing.expectEqualStrings("Explore", v.rule_content.?);
}

test "parse malformed missing tool name is tool-wide with raw name" {
    var v = try parse(testing.allocator, "(foo)");
    defer v.deinit(testing.allocator);
    try testing.expectEqualStrings("(foo)", v.tool_name);
    try testing.expect(v.rule_content == null);
}

test "parse content after closing paren is tool-wide" {
    var v = try parse(testing.allocator, "Bash(ls) extra");
    defer v.deinit(testing.allocator);
    try testing.expectEqualStrings("Bash(ls) extra", v.tool_name);
    try testing.expect(v.rule_content == null);
}

test "parse unterminated open paren is tool-wide" {
    var v = try parse(testing.allocator, "Bash(ls");
    defer v.deinit(testing.allocator);
    try testing.expectEqualStrings("Bash(ls", v.tool_name);
    try testing.expect(v.rule_content == null);
}

test "toString round-trips bare tool name" {
    var v = try parse(testing.allocator, "Bash");
    defer v.deinit(testing.allocator);
    const s = try toString(testing.allocator, v);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("Bash", s);
}

test "toString round-trips simple content" {
    var v = try parse(testing.allocator, "Bash(npm install)");
    defer v.deinit(testing.allocator);
    const s = try toString(testing.allocator, v);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("Bash(npm install)", s);
}

test "toString round-trips escaped parens" {
    const original = "Bash(python -c \"print\\(1\\)\")";
    var v = try parse(testing.allocator, original);
    defer v.deinit(testing.allocator);
    const s = try toString(testing.allocator, v);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings(original, s);
}

test "toString round-trips tool-wide forms back to bare tool" {
    var v = try parse(testing.allocator, "Bash(*)");
    defer v.deinit(testing.allocator);
    const s = try toString(testing.allocator, v);
    defer testing.allocator.free(s);
    // Tool-wide normalization: Bash(*) and Bash() both serialize to "Bash".
    try testing.expectEqualStrings("Bash", s);
}

test "toString preserves the canonical alias on round-trip" {
    var v = try parse(testing.allocator, "Task(Explore)");
    defer v.deinit(testing.allocator);
    const s = try toString(testing.allocator, v);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("Agent(Explore)", s);
}

test "escape then unescape is identity for backslashes and parens" {
    const raw = "a\\b(c)d\\(e\\)";
    const e = try escape(testing.allocator, raw);
    defer testing.allocator.free(e);
    const u = try unescape(testing.allocator, e);
    defer testing.allocator.free(u);
    try testing.expectEqualStrings(raw, u);
}
