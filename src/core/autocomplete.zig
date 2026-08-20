//! P8 (PRD #534) in-REPL autocomplete logic. Pure functions the input loop uses
//! to decide whether the cursor is in a slash-command or @-mention context and
//! to rank candidates (prefix-first, then fuzzy). The dropdown rendering itself
//! is REPL integration; this is the testable core.

const std = @import("std");
const fuzzy = @import("parse_helpers.zig");

pub const Ranked = struct {
    value: []const u8,
    score: i32,
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

/// If `input` is a slash-command being typed (starts with '/', no space yet),
/// return the whole token (incl. '/') to complete; otherwise null.
pub fn slashContext(input: []const u8) ?[]const u8 {
    if (input.len == 0 or input[0] != '/') return null;
    if (std.mem.indexOfAny(u8, input, " \t\n") != null) return null;
    return input;
}

/// If the last whitespace-delimited token starts with '@', return the path
/// prefix after '@' (possibly empty when the user just typed '@'); else null.
pub fn atMentionContext(input: []const u8) ?[]const u8 {
    var start = input.len;
    while (start > 0 and !isSpace(input[start - 1])) start -= 1;
    const token = input[start..];
    if (token.len == 0 or token[0] != '@') return null;
    return token[1..];
}

/// Rank `candidates` for `query`: case-insensitive prefix matches score highest
/// (shorter candidates first), then fuzzy matches, then non-matches dropped. An
/// empty query returns all candidates in original order (score 0). Caller frees.
pub fn rank(allocator: std.mem.Allocator, query: []const u8, candidates: []const []const u8) ![]Ranked {
    var out: std.ArrayList(Ranked) = .empty;
    errdefer out.deinit(allocator);

    if (query.len == 0) {
        for (candidates) |c| try out.append(allocator, .{ .value = c, .score = 0 });
        return out.toOwnedSlice(allocator);
    }

    for (candidates) |c| {
        if (startsWithIgnoreCase(c, query)) {
            // prefix match: big boost, prefer shorter (closer) candidates
            const boost: i32 = 1_000_000 - @as(i32, @intCast(@min(c.len, 100_000)));
            try out.append(allocator, .{ .value = c, .score = boost });
        } else if (fuzzy.fuzzyScore(query, c)) |s| {
            try out.append(allocator, .{ .value = c, .score = s });
        }
    }
    std.mem.sort(Ranked, out.items, {}, struct {
        fn lt(_: void, a: Ranked, b: Ranked) bool {
            return a.score > b.score;
        }
    }.lt);
    return out.toOwnedSlice(allocator);
}

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (prefix.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

const testing = std.testing;

test "slashContext detects an in-progress command" {
    try testing.expectEqualStrings("/mod", slashContext("/mod").?);
    try testing.expect(slashContext("/model arg") == null); // has a space
    try testing.expect(slashContext("hello") == null);
    try testing.expect(slashContext("") == null);
}

test "atMentionContext returns the path prefix of the last token" {
    try testing.expectEqualStrings("src/ma", atMentionContext("look at @src/ma").?);
    try testing.expectEqualStrings("", atMentionContext("see @").?);
    try testing.expect(atMentionContext("no mention here") == null);
    try testing.expect(atMentionContext("email a@b after") == null); // not last token start
}

test "rank: prefix matches beat fuzzy, empty query keeps order" {
    const cands = [_][]const u8{ "/model", "/mcp", "/memory", "/commit" };
    const r = try rank(testing.allocator, "/m", &cands);
    defer testing.allocator.free(r);
    // shortest prefix match ranks first
    try testing.expectEqualStrings("/mcp", r[0].value);
    // /commit only fuzzy-matches, so it must rank below the 3 prefix matches
    for (r, 0..) |row, i| {
        if (std.mem.eql(u8, row.value, "/commit")) try testing.expect(i >= 3);
    }

    const all = try rank(testing.allocator, "", &cands);
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 4), all.len);
    try testing.expectEqualStrings("/model", all[0].value);
}

test "rank: case-insensitive prefix" {
    const cands = [_][]const u8{ "Read", "Write" };
    const r = try rank(testing.allocator, "re", &cands);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("Read", r[0].value);
}
