//! P4 (PRD #534) reactive compaction. When a request is rejected for being too
//! long (HTTP 413 / prompt-too-long), Claude Code aggressively reduces history
//! rather than failing the turn. This module is the pure transform: keep the
//! most recent turns and any system turns, drop older conversational turns.
//! Distinct from microcompaction (which one-lines old tool results); reactive
//! reduction DROPS turns to make the request fit.

const std = @import("std");
const types = @import("types.zig");

/// True when the error warrants reactive reduction (request too large).
pub fn isOverLimitStatus(status: u16) bool {
    return status == 413;
}

/// True when the error body text is an Anthropic "prompt is too long" rejection.
/// The direct API returns this on a 400 (not a 413), and Vertex/Bedrock can
/// return it on a 413 with different casing; we lowercase the search so either
/// form matches. Mirrors `isPromptTooLongMessage` (errors.ts:62-118), which keys
/// off the same substring rather than the HTTP status.
pub fn isPromptTooLongMessage(text: []const u8) bool {
    return containsIgnoreCase(text, "prompt is too long");
}

/// Find the first run of ASCII digits in `text` starting at `from`, returning
/// the parsed value and the index just past the last digit. Null when no digit
/// run exists. Values that overflow u64 are skipped (treated as no match).
fn scanDigits(text: []const u8, from: usize) ?struct { value: u64, end: usize } {
    var i = from;
    while (i < text.len and !std.ascii.isDigit(text[i])) : (i += 1) {}
    if (i >= text.len) return null;
    var value: u64 = 0;
    while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
        value = std.math.mul(u64, value, 10) catch return null;
        value = std.math.add(u64, value, text[i] - '0') catch return null;
    }
    return .{ .value = value, .end = i };
}

/// Parse the token counts out of a "prompt is too long: N tokens > M maximum"
/// rejection. Returns `{ actual, limit }` when the shape matches: the substring
/// "prompt is too long", then a run of digits (actual), then a `>`, then the
/// next run of digits (limit). Returns null when any part of the shape is
/// missing. Lenient like the reference regex (extra words between the numbers
/// are ignored); case-insensitive on the lead substring. Hand-rolled because
/// Zig std has no regex.
pub fn parsePromptTooLongTokenCounts(text: []const u8) ?struct { actual: u64, limit: u64 } {
    const lead = indexOfIgnoreCase(text, "prompt is too long") orelse return null;
    const after_lead = lead + "prompt is too long".len;

    const actual_run = scanDigits(text, after_lead) orelse return null;
    // The limit must come after a `>` separator (matching "N tokens > M").
    const gt = std.mem.indexOfScalarPos(u8, text, actual_run.end, '>') orelse return null;
    const limit_run = scanDigits(text, gt + 1) orelse return null;

    return .{ .actual = actual_run.value, .limit = limit_run.value };
}

/// The number of tokens the prompt exceeds the model limit by, or null when the
/// message does not parse. A non-positive gap (limit >= actual) returns 0.
pub fn promptTooLongGap(text: []const u8) ?u64 {
    const counts = parsePromptTooLongTokenCounts(text) orelse return null;
    if (counts.limit >= counts.actual) return 0;
    return counts.actual - counts.limit;
}

const containsIgnoreCase = @import("parse_helpers.zig").containsIgnoreCase;

/// Case-insensitive `indexOf` for ASCII needles. Returns the byte index of the
/// first match or null. parse_helpers exposes `containsIgnoreCase` but not a
/// position-returning variant, so the parser needs this local helper.
fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// Produce a reduced history: every `system` turn is kept (instructions), plus
/// the last `keep_last_n` non-system turns. Older non-system turns are dropped.
/// Order is preserved. Caller owns the returned slice; turn contents are shared
/// (shallow copies), so it borrows from `history`.
pub fn reduce(allocator: std.mem.Allocator, history: []const types.HistoryTurn, keep_last_n: usize) ![]types.HistoryTurn {
    // Index of the first non-system turn we keep (the tail window start).
    var non_system_total: usize = 0;
    for (history) |t| {
        if (t.role != .system) non_system_total += 1;
    }
    const drop_non_system = if (non_system_total > keep_last_n) non_system_total - keep_last_n else 0;

    var out: std.ArrayList(types.HistoryTurn) = .empty;
    errdefer out.deinit(allocator);

    var seen_non_system: usize = 0;
    for (history) |t| {
        if (t.role == .system) {
            try out.append(allocator, t);
            continue;
        }
        defer seen_non_system += 1;
        if (seen_non_system < drop_non_system) continue; // drop oldest non-system
        try out.append(allocator, t);
    }
    return out.toOwnedSlice(allocator);
}

const testing = std.testing;

fn turn(role: types.HistoryRole, content: []const u8) types.HistoryTurn {
    return .{ .role = role, .content = content, .timestamp = 0 };
}

test "isOverLimitStatus only matches 413" {
    try testing.expect(isOverLimitStatus(413));
    try testing.expect(!isOverLimitStatus(429));
    try testing.expect(!isOverLimitStatus(200));
}

test "reduce keeps system turns and the last N non-system" {
    const history = [_]types.HistoryTurn{
        turn(.system, "sys"),
        turn(.user, "u1"),
        turn(.assistant, "a1"),
        turn(.user, "u2"),
        turn(.assistant, "a2"),
        turn(.user, "u3"),
    };
    const out = try reduce(testing.allocator, &history, 2);
    defer testing.allocator.free(out);
    // system + last 2 non-system (u3 and a2)
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqual(types.HistoryRole.system, out[0].role);
    try testing.expectEqualStrings("a2", out[1].content);
    try testing.expectEqualStrings("u3", out[2].content);
}

test "reduce keeps everything when under the window" {
    const history = [_]types.HistoryTurn{
        turn(.user, "u1"),
        turn(.assistant, "a1"),
    };
    const out = try reduce(testing.allocator, &history, 6);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 2), out.len);
}

test "parsePromptTooLongTokenCounts extracts actual and limit" {
    const parsed = parsePromptTooLongTokenCounts("prompt is too long: 137500 tokens > 135000 maximum") orelse
        return error.TestExpectedSome;
    try testing.expectEqual(@as(u64, 137500), parsed.actual);
    try testing.expectEqual(@as(u64, 135000), parsed.limit);
}

test "parsePromptTooLongTokenCounts is case-insensitive (Vertex casing)" {
    const parsed = parsePromptTooLongTokenCounts("Prompt is too long: 188059 tokens > 200000 maximum") orelse
        return error.TestExpectedSome;
    try testing.expectEqual(@as(u64, 188059), parsed.actual);
    try testing.expectEqual(@as(u64, 200000), parsed.limit);
}

test "parsePromptTooLongTokenCounts returns null for non-PTL text" {
    try testing.expect(parsePromptTooLongTokenCounts("some unrelated 400 error") == null);
    // PTL lead present but no `>` separator -> shape does not match.
    try testing.expect(parsePromptTooLongTokenCounts("prompt is too long: 100 tokens") == null);
}

test "promptTooLongGap computes the overflow" {
    try testing.expectEqual(@as(u64, 2500), promptTooLongGap("prompt is too long: 137500 tokens > 135000 maximum").?);
    // Non-positive gap clamps to 0 rather than underflowing.
    try testing.expectEqual(@as(u64, 0), promptTooLongGap("prompt is too long: 100 tokens > 200 maximum").?);
    try testing.expect(promptTooLongGap("not a ptl error") == null);
}

test "isPromptTooLongMessage matches the lead substring" {
    try testing.expect(isPromptTooLongMessage("error: prompt is too long: 1 > 0"));
    try testing.expect(isPromptTooLongMessage("PROMPT IS TOO LONG"));
    try testing.expect(!isPromptTooLongMessage("rate limit exceeded"));
}
