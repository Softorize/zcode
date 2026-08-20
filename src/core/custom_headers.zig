//! Parser for the `ZCODE_CUSTOM_HEADERS` env var (zcode-namespaced analog of
//! the reference's `ANTHROPIC_CUSTOM_HEADERS`, client.ts:330-389). The value is
//! a newline-separated list of `Name: Value` header lines. Each line is split
//! on the FIRST colon; the name and value are trimmed. Blank lines and lines
//! without a colon are skipped (a malformed env var must never crash startup).
//!
//! Reuses `HeaderPair` from providers/extractors.zig so the same shape flows
//! through the curl header path. The returned slice and each name/value string
//! are heap-allocated copies owned by the caller; free with `free`.

const std = @import("std");
const extractors = @import("../providers/extractors.zig");

pub const HeaderPair = extractors.HeaderPair;

/// Parse a `ZCODE_CUSTOM_HEADERS`-style blob into owned header pairs.
///
/// - Splits on `\n`; `\r` is trimmed so CRLF input is handled.
/// - Each non-blank line is split on the FIRST `:`; everything before is the
///   name, everything after is the value (so values may contain colons, e.g.
///   a URL).
/// - Name and value are trimmed of surrounding whitespace.
/// - Lines with no colon, or an empty name after trimming, are skipped.
///
/// Caller owns the returned slice and every `name`/`value` inside it; free the
/// whole thing with `free`.
pub fn parse(allocator: std.mem.Allocator, raw: []const u8) ![]HeaderPair {
    var pairs: std.ArrayList(HeaderPair) = .empty;
    errdefer freePartial(allocator, &pairs);

    var line_it = std.mem.splitScalar(u8, raw, '\n');
    while (line_it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (name.len == 0) continue;

        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        const value_copy = try allocator.dupe(u8, value);
        errdefer allocator.free(value_copy);
        try pairs.append(allocator, .{ .name = name_copy, .value = value_copy });
    }

    return pairs.toOwnedSlice(allocator);
}

fn freePartial(allocator: std.mem.Allocator, pairs: *std.ArrayList(HeaderPair)) void {
    for (pairs.items) |p| {
        allocator.free(p.name);
        allocator.free(p.value);
    }
    pairs.deinit(allocator);
}

/// Free a slice returned by `parse`. Frees each name/value and the slice.
pub fn free(allocator: std.mem.Allocator, pairs: []const HeaderPair) void {
    for (pairs) |p| {
        allocator.free(p.name);
        allocator.free(p.value);
    }
    allocator.free(pairs);
}

const testing = std.testing;

test "custom_headers: multi-line parses into the right pairs" {
    const raw = "X-Team: platform\nX-Trace: abc123\n";
    const pairs = try parse(testing.allocator, raw);
    defer free(testing.allocator, pairs);

    try testing.expectEqual(@as(usize, 2), pairs.len);
    try testing.expectEqualStrings("X-Team", pairs[0].name);
    try testing.expectEqualStrings("platform", pairs[0].value);
    try testing.expectEqualStrings("X-Trace", pairs[1].name);
    try testing.expectEqualStrings("abc123", pairs[1].value);
}

test "custom_headers: a line with no colon is skipped" {
    const raw = "X-Good: yes\nnocolonhere\nX-Also: ok\n";
    const pairs = try parse(testing.allocator, raw);
    defer free(testing.allocator, pairs);

    try testing.expectEqual(@as(usize, 2), pairs.len);
    try testing.expectEqualStrings("X-Good", pairs[0].name);
    try testing.expectEqualStrings("X-Also", pairs[1].name);
}

test "custom_headers: CRLF input is handled" {
    const raw = "X-One: a\r\nX-Two: b\r\n";
    const pairs = try parse(testing.allocator, raw);
    defer free(testing.allocator, pairs);

    try testing.expectEqual(@as(usize, 2), pairs.len);
    try testing.expectEqualStrings("X-One", pairs[0].name);
    try testing.expectEqualStrings("a", pairs[0].value);
    try testing.expectEqualStrings("X-Two", pairs[1].name);
    try testing.expectEqualStrings("b", pairs[1].value);
}

test "custom_headers: leading and trailing whitespace trimmed" {
    const raw = "   X-Pad   :    padded value    \n";
    const pairs = try parse(testing.allocator, raw);
    defer free(testing.allocator, pairs);

    try testing.expectEqual(@as(usize, 1), pairs.len);
    try testing.expectEqualStrings("X-Pad", pairs[0].name);
    try testing.expectEqualStrings("padded value", pairs[0].value);
}

test "custom_headers: value may contain a colon (split on first only)" {
    const raw = "X-Url: https://example.com/path\n";
    const pairs = try parse(testing.allocator, raw);
    defer free(testing.allocator, pairs);

    try testing.expectEqual(@as(usize, 1), pairs.len);
    try testing.expectEqualStrings("X-Url", pairs[0].name);
    try testing.expectEqualStrings("https://example.com/path", pairs[0].value);
}

test "custom_headers: blank and whitespace-only lines skipped, empty name skipped" {
    const raw = "\n   \nX-Real: v\n: noname\n";
    const pairs = try parse(testing.allocator, raw);
    defer free(testing.allocator, pairs);

    try testing.expectEqual(@as(usize, 1), pairs.len);
    try testing.expectEqualStrings("X-Real", pairs[0].name);
}

test "custom_headers: empty input yields empty slice" {
    const pairs = try parse(testing.allocator, "");
    defer free(testing.allocator, pairs);
    try testing.expectEqual(@as(usize, 0), pairs.len);
}
