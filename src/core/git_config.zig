const std = @import("std");

/// Lightweight in-memory parser for `.git/config` files. Ported in spirit from
/// claude-code-main/src/utils/git/gitConfigParser.ts, which was itself verified
/// against git's config.c. The goal is to read a single value under a
/// `[section "subsection"] key` header without spawning `git config --get`.
///
/// Behaviours (matching git's config.c):
///   * Section names: case-insensitive
///   * Subsection names (quoted): case-sensitive, with `\\` and `\"` escapes
///   * Key names: case-insensitive
///   * Values: optional double-quoting, inline `#`/`;` comments outside quotes,
///     backslash escapes (`\n`, `\t`, `\b`, `\"`, `\\`), trailing-whitespace trim
///     of the unquoted tail.
///
/// `getValue` returns the value of the first matching key. Because unescaping a
/// quoted value can transform bytes (e.g. `\n` -> newline), the returned slice is
/// freshly allocated and the caller owns it. Returns null when the section /
/// subsection / key is not found.
pub fn getValue(
    allocator: std.mem.Allocator,
    text: []const u8,
    section: []const u8,
    subsection: ?[]const u8,
    key: []const u8,
) !?[]u8 {
    var in_section = false;
    var line_iter = std.mem.splitScalar(u8, text, '\n');
    while (line_iter.next()) |raw_line| {
        const trimmed = std.mem.trim(u8, raw_line, " \t\r");

        // Skip empty lines and comment-only lines.
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') continue;

        // Section header.
        if (trimmed[0] == '[') {
            in_section = matchesSectionHeader(trimmed, section, subsection);
            continue;
        }

        if (!in_section) continue;

        // Key-value line.
        if (try parseKeyValue(allocator, trimmed, key)) |value| {
            return value;
        }
    }

    return null;
}

/// Parse a `key = value` line. Returns the unescaped value (allocated) when the
/// line's key matches `want_key` case-insensitively, otherwise null. The caller
/// owns the returned slice.
fn parseKeyValue(allocator: std.mem.Allocator, line: []const u8, want_key: []const u8) !?[]u8 {
    var i: usize = 0;
    while (i < line.len and isKeyChar(line[i])) : (i += 1) {}
    if (i == 0) return null;
    const found_key = line[0..i];

    // Skip whitespace before '='.
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

    // Must have '='. A bare boolean key with no value is not relevant here.
    if (i >= line.len or line[i] != '=') return null;
    i += 1; // skip '='

    // Skip whitespace after '='.
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

    if (!std.ascii.eqlIgnoreCase(found_key, want_key)) return null;

    return try parseValue(allocator, line, i);
}

/// Parse a config value starting at byte offset `start`. Handles quoted strings,
/// escape sequences, and inline comments. The result is allocated; caller owns it.
fn parseValue(allocator: std.mem.Allocator, line: []const u8, start: usize) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var in_quote = false;
    var i: usize = start;
    while (i < line.len) {
        const ch = line[i];

        // Inline comments outside quotes end the value.
        if (!in_quote and (ch == '#' or ch == ';')) break;

        if (ch == '"') {
            in_quote = !in_quote;
            i += 1;
            continue;
        }

        if (ch == '\\' and i + 1 < line.len) {
            const next = line[i + 1];
            if (in_quote) {
                // Inside quotes: recognize escape sequences.
                switch (next) {
                    'n' => try result.append(allocator, '\n'),
                    't' => try result.append(allocator, '\t'),
                    'b' => try result.append(allocator, 8), // backspace
                    '"' => try result.append(allocator, '"'),
                    '\\' => try result.append(allocator, '\\'),
                    // Git silently drops the backslash for unknown escapes.
                    else => try result.append(allocator, next),
                }
                i += 2;
                continue;
            }
            // Outside quotes: handle a literal `\\` pair; otherwise fall through
            // and treat the backslash literally.
            if (next == '\\') {
                try result.append(allocator, '\\');
                i += 2;
                continue;
            }
        }

        try result.append(allocator, ch);
        i += 1;
    }

    // Git trims trailing whitespace that is not inside quotes. For single-line
    // values the simplest correct approach is to trim the result when the value
    // did not end inside an open quote.
    if (!in_quote) {
        var end = result.items.len;
        while (end > 0 and (result.items[end - 1] == ' ' or result.items[end - 1] == '\t')) end -= 1;
        result.shrinkRetainingCapacity(end);
    }

    return result.toOwnedSlice(allocator);
}

/// Check whether a config header line like `[remote "origin"]` matches the given
/// section/subsection. Section matching is case-insensitive; subsection matching
/// is case-sensitive (with `\\` and `\"` escapes inside the quotes).
fn matchesSectionHeader(line: []const u8, want_section: []const u8, want_subsection: ?[]const u8) bool {
    // line starts with '['.
    var i: usize = 1;

    // Read the section name.
    while (i < line.len and line[i] != ']' and line[i] != ' ' and line[i] != '\t' and line[i] != '"') : (i += 1) {}
    const found_section = line[1..i];

    if (!std.ascii.eqlIgnoreCase(found_section, want_section)) return false;

    const subsection = want_subsection orelse {
        // Simple section: must end with ']'.
        return i < line.len and line[i] == ']';
    };

    // Skip whitespace before the subsection quote.
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

    // Must have an opening quote.
    if (i >= line.len or line[i] != '"') return false;
    i += 1; // skip opening quote

    // Read the subsection: case-sensitive, handling \\ and \" escapes. We compare
    // byte-by-byte against want_subsection to avoid allocating here.
    var sub_idx: usize = 0;
    while (i < line.len and line[i] != '"') {
        var byte = line[i];
        var advance: usize = 1;
        if (line[i] == '\\' and i + 1 < line.len) {
            // Git keeps the next char for \\ and \", and drops the backslash for
            // any other escape inside subsections.
            byte = line[i + 1];
            advance = 2;
        }
        if (sub_idx >= subsection.len or subsection[sub_idx] != byte) return false;
        sub_idx += 1;
        i += advance;
    }

    // Must have a closing quote followed by ']'.
    if (i >= line.len or line[i] != '"') return false;
    i += 1; // skip closing quote
    if (i >= line.len or line[i] != ']') return false;

    return sub_idx == subsection.len;
}

fn isKeyChar(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or
        (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or
        ch == '-';
}

const testing = std.testing;

test "getValue reads [remote \"origin\"] url" {
    const cfg =
        \\[core]
        \\  repositoryformatversion = 0
        \\[remote "origin"]
        \\  url = https://github.com/owner/repo.git
        \\  fetch = +refs/heads/*:refs/remotes/origin/*
        \\
    ;
    const v = try getValue(testing.allocator, cfg, "remote", "origin", "url");
    defer if (v) |s| testing.allocator.free(s);
    try testing.expect(v != null);
    try testing.expectEqualStrings("https://github.com/owner/repo.git", v.?);
}

test "getValue case-insensitive section and key" {
    const cfg =
        \\[Core]
        \\  BARE = false
        \\
    ;
    const v2 = try getValue(testing.allocator, cfg, "core", null, "bare");
    defer if (v2) |s| testing.allocator.free(s);
    try testing.expect(v2 != null);
    try testing.expectEqualStrings("false", v2.?);
}

test "getValue quoted subsection with escapes" {
    // Subsection contains an embedded quote and backslash via escapes.
    const cfg =
        \\[remote "a\"b\\c"]
        \\  url = git@example.com:x.git
        \\
    ;
    const v = try getValue(testing.allocator, cfg, "remote", "a\"b\\c", "url");
    defer if (v) |s| testing.allocator.free(s);
    try testing.expect(v != null);
    try testing.expectEqualStrings("git@example.com:x.git", v.?);
}

test "getValue strips inline comment outside quotes" {
    const cfg =
        \\[user]
        \\  name = Jane Doe ; a trailing comment
        \\  email = jane@example.com # hash comment
        \\
    ;
    const name = try getValue(testing.allocator, cfg, "user", null, "name");
    defer if (name) |s| testing.allocator.free(s);
    try testing.expect(name != null);
    try testing.expectEqualStrings("Jane Doe", name.?);

    const email = try getValue(testing.allocator, cfg, "user", null, "email");
    defer if (email) |s| testing.allocator.free(s);
    try testing.expect(email != null);
    try testing.expectEqualStrings("jane@example.com", email.?);
}

test "getValue unescapes quoted value and keeps comment chars inside quotes" {
    const cfg =
        \\[alias]
        \\  what = "value # not a comment\twith tab"
        \\
    ;
    const v = try getValue(testing.allocator, cfg, "alias", null, "what");
    defer if (v) |s| testing.allocator.free(s);
    try testing.expect(v != null);
    try testing.expectEqualStrings("value # not a comment\twith tab", v.?);
}

test "getValue returns null for missing key, subsection, and section" {
    const cfg =
        \\[remote "origin"]
        \\  url = x
        \\
    ;
    const missing_key = try getValue(testing.allocator, cfg, "remote", "origin", "fetch");
    try testing.expect(missing_key == null);

    const missing_sub = try getValue(testing.allocator, cfg, "remote", "upstream", "url");
    try testing.expect(missing_sub == null);

    const missing_section = try getValue(testing.allocator, cfg, "branch", "main", "remote");
    try testing.expect(missing_section == null);
}

test "getValue with null subsection does not match a subsectioned header" {
    const cfg =
        \\[remote "origin"]
        \\  url = x
        \\
    ;
    const v = try getValue(testing.allocator, cfg, "remote", null, "url");
    try testing.expect(v == null);
}
