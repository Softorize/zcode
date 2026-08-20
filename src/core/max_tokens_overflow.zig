//! P4 (PRD #534) max_tokens / context-overflow auto-adjustment. The direct API
//! can reject a request with a 400 whose body reads:
//!
//!   "input length and `max_tokens` exceed context limit: A + B > C"
//!
//! where A is the input-token count, B the requested max_tokens, and C the
//! model's context limit. Rather than failing the turn, Claude Code lowers
//! `max_tokens` to fit the remaining context and retries once. This module is
//! the pure parser + adjuster; the wiring lives in `agent_history.callWithAdapter`.
//!
//! Mirrors `parseMaxTokensContextOverflowError` (withRetry.ts:550-595) and the
//! adjustment math at withRetry.ts:384-427 (FLOOR_OUTPUT_TOKENS = 3000, a 1000
//! token safety buffer). Note: the reference observes this 400 no longer occurs
//! with the extended-context beta (the API now returns a
//! `model_context_window_exceeded` stop_reason instead); this is a backward-compat
//! safety net, kept minimal. Hand-rolled scanning because Zig std has no regex.

const std = @import("std");

/// Output-token floor: never lower max_tokens below this. Matches the reference's
/// FLOOR_OUTPUT_TOKENS (withRetry.ts:53).
pub const FLOOR_OUTPUT_TOKENS: u64 = 3000;

/// Tokens held back from the available-context computation so the adjusted
/// max_tokens leaves headroom. Matches the reference's safety buffer (1000).
pub const SAFETY_BUFFER_TOKENS: u64 = 1000;

const MARKER = "exceed context limit:";

pub const Overflow = struct {
    /// A: the input-token count the request would consume.
    input: u64,
    /// B: the requested max_tokens.
    max_tokens: u64,
    /// C: the model's total context limit.
    context_limit: u64,
};

/// Find the first run of ASCII digits in `text` starting at `from`, returning
/// the parsed value and the index just past the last digit. Null when no digit
/// run exists before end-of-string. Values that overflow u64 are treated as no
/// match (a hostile / corrupt body should not panic the retry path).
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

/// Parse "... exceed context limit: A + B > C" out of an over-budget 400 body.
/// Returns `{ input: A, max_tokens: B, context_limit: C }` when the shape
/// matches: the literal marker, then three digit runs separated by `+` and `>`.
/// Returns null when the marker is absent or the three numbers do not appear in
/// order. Case-insensitive on the marker (matching the lenient reference guard).
pub fn parseMaxTokensContextOverflow(text: []const u8) ?Overflow {
    const marker_at = indexOfIgnoreCase(text, MARKER) orelse return null;
    var cursor = marker_at + MARKER.len;

    const a = scanDigits(text, cursor) orelse return null;
    // The `+` separator between A and B must appear before the next digit run,
    // otherwise the shape ("A + B > C") does not match and we bail out rather
    // than mis-parsing an unrelated number sequence.
    const plus = std.mem.indexOfScalarPos(u8, text, a.end, '+') orelse return null;
    cursor = plus + 1;

    const b = scanDigits(text, cursor) orelse return null;
    // The `>` separator between B and C.
    const gt = std.mem.indexOfScalarPos(u8, text, b.end, '>') orelse return null;
    cursor = gt + 1;

    const c = scanDigits(text, cursor) orelse return null;

    return .{ .input = a.value, .max_tokens = b.value, .context_limit = c.value };
}

/// Compute the lowered max_tokens that fits the remaining context, or null when
/// recovery is impossible (the input alone leaves less than the output floor).
/// Mirrors withRetry.ts:384-427:
///   available = context_limit - input - SAFETY_BUFFER
///   if available < FLOOR -> cannot recover (return null, caller surfaces error)
///   new max = max(FLOOR, available, thinking_budget + 1)
/// `thinking_budget` is the extended-thinking token budget the request needs
/// preserved; pass 0 when the request has no thinking budget. Saturating math so
/// a hostile body cannot underflow.
pub fn adjustMaxTokens(parsed: Overflow, thinking_budget: u64) ?u64 {
    const reserved = std.math.add(u64, parsed.input, SAFETY_BUFFER_TOKENS) catch return null;
    if (parsed.context_limit <= reserved) return null;
    const available = parsed.context_limit - reserved;
    if (available < FLOOR_OUTPUT_TOKENS) return null;
    const thinking_floor = std.math.add(u64, thinking_budget, 1) catch FLOOR_OUTPUT_TOKENS;
    return @max(FLOOR_OUTPUT_TOKENS, @max(available, thinking_floor));
}

/// Case-insensitive `indexOf` for ASCII needles. Returns the byte index of the
/// first match or null. parse_helpers exposes `containsIgnoreCase` but not a
/// position-returning variant, so we keep a local copy (same as
/// reactive_compaction.zig's `indexOfIgnoreCase`).
fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

const testing = std.testing;

test "parseMaxTokensContextOverflow extracts A, B, C" {
    const parsed = parseMaxTokensContextOverflow(
        "input length and `max_tokens` exceed context limit: 188059 + 20000 > 200000",
    ) orelse return error.TestExpectedSome;
    try testing.expectEqual(@as(u64, 188059), parsed.input);
    try testing.expectEqual(@as(u64, 20000), parsed.max_tokens);
    try testing.expectEqual(@as(u64, 200000), parsed.context_limit);
}

test "parseMaxTokensContextOverflow is case-insensitive on the marker" {
    const parsed = parseMaxTokensContextOverflow(
        "Input length and max_tokens EXCEED CONTEXT LIMIT: 100 + 200 > 1000",
    ) orelse return error.TestExpectedSome;
    try testing.expectEqual(@as(u64, 100), parsed.input);
    try testing.expectEqual(@as(u64, 200), parsed.max_tokens);
    try testing.expectEqual(@as(u64, 1000), parsed.context_limit);
}

test "parseMaxTokensContextOverflow returns null for non-matching bodies" {
    // No marker at all.
    try testing.expect(parseMaxTokensContextOverflow("some unrelated 400 error") == null);
    // Marker present but the A + B > C shape is incomplete (missing `>` + C).
    try testing.expect(parseMaxTokensContextOverflow("exceed context limit: 100 + 200") == null);
    // Marker present but no digits at all.
    try testing.expect(parseMaxTokensContextOverflow("exceed context limit: lots of tokens") == null);
}

test "adjustMaxTokens lowers to the available context with the safety buffer" {
    const parsed = Overflow{ .input = 188059, .max_tokens = 20000, .context_limit = 200000 };
    // available = 200000 - 188059 - 1000 = 10941; > FLOOR, so the new max is 10941.
    const adjusted = adjustMaxTokens(parsed, 0) orelse return error.TestExpectedSome;
    try testing.expectEqual(@as(u64, 10941), adjusted);
}

test "adjustMaxTokens floors at FLOOR_OUTPUT_TOKENS" {
    // available = 100000 - 96000 - 1000 = 3000 == FLOOR -> returns FLOOR.
    const parsed = Overflow{ .input = 96000, .max_tokens = 8000, .context_limit = 100000 };
    const adjusted = adjustMaxTokens(parsed, 0) orelse return error.TestExpectedSome;
    try testing.expectEqual(FLOOR_OUTPUT_TOKENS, adjusted);
}

test "adjustMaxTokens returns null when available is below the floor" {
    // available = 100000 - 98000 - 1000 = 1000 < FLOOR -> cannot recover.
    const parsed = Overflow{ .input = 98000, .max_tokens = 8000, .context_limit = 100000 };
    try testing.expect(adjustMaxTokens(parsed, 0) == null);
    // input alone already exceeds the limit -> null (no underflow).
    const over = Overflow{ .input = 200001, .max_tokens = 1, .context_limit = 200000 };
    try testing.expect(adjustMaxTokens(over, 0) == null);
}

test "adjustMaxTokens respects a thinking budget floor" {
    // available = 50000 - 40000 - 1000 = 9000; thinking_budget 12000 -> new max
    // must be at least thinking_budget + 1 = 12001 so the thinking budget fits.
    const parsed = Overflow{ .input = 40000, .max_tokens = 8000, .context_limit = 50000 };
    const adjusted = adjustMaxTokens(parsed, 12000) orelse return error.TestExpectedSome;
    try testing.expectEqual(@as(u64, 12001), adjusted);
}
