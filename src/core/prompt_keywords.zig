//! Negative / keep-going user-prompt classification (parity: misc-utils-18).
//!
//! Two pure, allocation-free matchers that classify a raw user prompt as a
//! "negative" reaction or a "keep going" continuation. They mirror the
//! reference's `matchesNegativeKeyword` / `matchesKeepGoingKeyword`
//! (src/utils/userPromptKeywords.ts) but use the simpler keyword lists called
//! out in the phase plan instead of the reference's profanity regex.
//!
//! These are a parallel telemetry signal: they do NOT replace the
//! `agent_history.isShortFollowUp` router. They exist so the per-prompt
//! diagnostic record can surface `is_negative` / `is_keep_going` the way the
//! reference logs the `tengu_input_prompt` event.
//!
//! Matching is case-insensitive and word-boundary aware (so "snow" does not
//! match "no" and "continued" does not match a whole-word "continue"). A
//! boundary is the start/end of the trimmed string or any non-alphanumeric
//! byte. Operating on ASCII bytes is consistent with the rest of the prompt
//! heuristics in this codebase.

const std = @import("std");

/// Keep-going / continuation phrases. "continue" matches only when it is the
/// entire (trimmed) prompt, matching the reference; the rest match as
/// standalone words anywhere in the input.
const keep_going_words = [_][]const u8{
    "keep going",
    "go on",
    "proceed",
    "carry on",
};

/// Negative reaction words. All matched as standalone words anywhere in the
/// input. "don't" is also covered by its apostrophe-free form "dont".
const negative_words = [_][]const u8{
    "no",
    "stop",
    "cancel",
    "don't",
    "dont",
    "nope",
    "nah",
    "nevermind",
    "never mind",
};

/// Returns true when `byte` is a word character (ASCII letter or digit). Used
/// to compute word boundaries so substring hits inside larger words are
/// rejected.
fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte);
}

/// Returns true when `needle` occurs in `haystack` as a standalone word: the
/// byte before the match (if any) and the byte after the match (if any) must
/// both be non-word bytes. `haystack` is assumed already lowercased.
fn containsWord(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |idx| {
        const before_ok = idx == 0 or !isWordByte(haystack[idx - 1]);
        const after_idx = idx + needle.len;
        const after_ok = after_idx == haystack.len or !isWordByte(haystack[after_idx]);
        if (before_ok and after_ok) return true;
        start = idx + 1;
    }
    return false;
}

/// Lowercase `input` (trimmed of surrounding whitespace) into `buf`. Returns
/// the lowercased trimmed slice, capped at `buf.len` bytes (long prompts are
/// rare for these short-reaction signals; the cap keeps the matchers
/// allocation-free).
fn normalize(input: []const u8, buf: []u8) []const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    const len = @min(trimmed.len, buf.len);
    for (0..len) |i| {
        buf[i] = std.ascii.toLower(trimmed[i]);
    }
    return buf[0..len];
}

/// Returns true when the prompt expresses a "keep going" / continuation
/// intent (continue / keep going / go on / proceed / carry on).
pub fn matchesKeepGoingKeyword(input: []const u8) bool {
    var buf: [256]u8 = undefined;
    const lower = normalize(input, &buf);
    if (lower.len == 0) return false;
    // "continue" only when it is the entire prompt (reference parity).
    if (std.mem.eql(u8, lower, "continue")) return true;
    for (keep_going_words) |word| {
        if (containsWord(lower, word)) return true;
    }
    return false;
}

/// Returns true when the prompt expresses a "negative" reaction
/// (no / stop / cancel / don't / nope / nah / nevermind).
pub fn matchesNegativeKeyword(input: []const u8) bool {
    var buf: [256]u8 = undefined;
    const lower = normalize(input, &buf);
    if (lower.len == 0) return false;
    for (negative_words) |word| {
        if (containsWord(lower, word)) return true;
    }
    return false;
}

const testing = std.testing;

test "matchesKeepGoingKeyword classifies continuation prompts" {
    try testing.expect(matchesKeepGoingKeyword("continue"));
    try testing.expect(matchesKeepGoingKeyword("Continue"));
    try testing.expect(matchesKeepGoingKeyword("  continue  "));
    try testing.expect(matchesKeepGoingKeyword("keep going"));
    try testing.expect(matchesKeepGoingKeyword("ok keep going please"));
    try testing.expect(matchesKeepGoingKeyword("go on"));
    try testing.expect(matchesKeepGoingKeyword("please proceed"));
    try testing.expect(matchesKeepGoingKeyword("carry on with that"));
}

test "matchesKeepGoingKeyword rejects non-continuation prompts" {
    // "continue" only counts as a whole prompt, not as a substring word.
    try testing.expect(!matchesKeepGoingKeyword("please continue the work tomorrow"));
    try testing.expect(!matchesKeepGoingKeyword("continued"));
    try testing.expect(!matchesKeepGoingKeyword("write a function"));
    try testing.expect(!matchesKeepGoingKeyword(""));
    try testing.expect(!matchesKeepGoingKeyword("   "));
}

test "matchesNegativeKeyword classifies negative prompts" {
    try testing.expect(matchesNegativeKeyword("no"));
    try testing.expect(matchesNegativeKeyword("No"));
    try testing.expect(matchesNegativeKeyword("stop"));
    try testing.expect(matchesNegativeKeyword("cancel that"));
    try testing.expect(matchesNegativeKeyword("don't do that"));
    try testing.expect(matchesNegativeKeyword("dont do that"));
    try testing.expect(matchesNegativeKeyword("nope"));
    try testing.expect(matchesNegativeKeyword("nah"));
    try testing.expect(matchesNegativeKeyword("nevermind"));
    try testing.expect(matchesNegativeKeyword("never mind"));
}

test "matchesNegativeKeyword rejects neutral prompts and avoids substring false positives" {
    // word-boundary aware: "snow"/"nostalgia" must not match "no".
    try testing.expect(!matchesNegativeKeyword("snow is falling"));
    try testing.expect(!matchesNegativeKeyword("nostalgia"));
    // "nonstop" should not match "stop" mid-word.
    try testing.expect(!matchesNegativeKeyword("nonstopping"));
    try testing.expect(!matchesNegativeKeyword("write a function"));
    try testing.expect(!matchesNegativeKeyword(""));
}

test "neutral prompt classifies as neither" {
    const neutral = "please add a unit test for the parser";
    try testing.expect(!matchesNegativeKeyword(neutral));
    try testing.expect(!matchesKeepGoingKeyword(neutral));
}
