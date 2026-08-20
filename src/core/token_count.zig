//! #572: token_count deep module.
//!
//! Heuristic client-side token estimation for messages, tool-use blocks,
//! and full conversations.
//!
//! IMPORTANT deviation from reference: the reference (src/services/
//! tokenEstimation.ts) does NOT have a client-side tokenizer. It counts
//! tokens by calling the Anthropic /v1/messages/count_tokens API endpoint,
//! or falling back to a real /v1/messages call with max_tokens:1 and
//! reading usage.input_tokens. The actual tokenization happens server-side.
//!
//! zcode's token_count module is a heuristic estimator (chars-per-token
//! approximation) suitable for context-pressure nudges and budget checks
//! where an exact count is not required. For exact counts, the agent
//! runtime (#573) will call the provider's count_tokens endpoint (the
//! same approach the reference uses, just exposed as an API call rather
//! than a pure function).
//!
//! The heuristic is deliberately conservative: it overestimates slightly
//! so context-pressure warnings fire early rather than late.

const std = @import("std");

/// Conservative chars-per-token ratio. English text averages ~4 chars/token
/// on Claude's tokenizer; we use 3.5 to overestimate slightly.
pub const CHARS_PER_TOKEN: f64 = 3.5;

/// Overhead per message in tokens (role, content envelope, separators).
pub const MESSAGE_OVERHEAD_TOKENS: usize = 4;

/// Overhead per tool-use block (id, name, input envelope).
pub const TOOL_USE_OVERHEAD_TOKENS: usize = 8;

/// Overhead per tool-result block (tool_use_id, content envelope).
pub const TOOL_RESULT_OVERHEAD_TOKENS: usize = 5;

/// Estimate tokens for a plain text string.
pub fn estimateTextTokens(text: []const u8) usize {
    if (text.len == 0) return 0;
    const est = @as(f64, @floatFromInt(text.len)) / CHARS_PER_TOKEN;
    return @intFromFloat(@ceil(est));
}

/// Estimate tokens for a single message (role + content).
/// Takes the same shape as wire_protocol.Message but without importing it
/// (kept pure). Caller passes role and a content-text approximation.
pub fn estimateMessageTokens(role: []const u8, content_text: []const u8) usize {
    return MESSAGE_OVERHEAD_TOKENS + estimateTextTokens(role) + estimateTextTokens(content_text);
}

/// Estimate tokens for a tool-use block (id + name + input JSON).
pub fn estimateToolUseTokens(id: []const u8, name: []const u8, input_json: []const u8) usize {
    return TOOL_USE_OVERHEAD_TOKENS +
        estimateTextTokens(id) + estimateTextTokens(name) + estimateTextTokens(input_json);
}

/// Estimate tokens for a tool-result block (tool_use_id + content).
pub fn estimateToolResultTokens(tool_use_id: []const u8, content: []const u8) usize {
    return TOOL_RESULT_OVERHEAD_TOKENS +
        estimateTextTokens(tool_use_id) + estimateTextTokens(content);
}

/// Estimate tokens for a system prompt string.
pub fn estimateSystemTokens(system: []const u8) usize {
    if (system.len == 0) return 0;
    return estimateTextTokens(system) + MESSAGE_OVERHEAD_TOKENS;
}

/// Estimate total tokens for a request: system + sum of messages.
/// messages_tokens is the pre-summed token count of all messages (caller
/// computes via estimateMessageTokens / estimateToolUseTokens etc.).
pub fn estimateRequestTokens(system: ?[]const u8, messages_tokens: usize) usize {
    var total: usize = messages_tokens;
    if (system) |sys| total += estimateSystemTokens(sys);
    return total;
}

// ---------------------------------------------------------------------------
// Tests: assert the heuristic behaves as expected on representative inputs.
// These are NOT equality tests against the reference's tokenizer (the
// reference has no client-side tokenizer - it calls the API). They verify
// the heuristic is internally consistent and conservative.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "estimateTextTokens: empty string is 0" {
    try testing.expectEqual(@as(usize, 0), estimateTextTokens(""));
}

test "estimateTextTokens: ~4 chars per token ceiling" {
    // "hello" is 5 chars -> 5/3.5 = 1.43 -> ceil = 2 tokens
    try testing.expectEqual(@as(usize, 2), estimateTextTokens("hello"));
    // 35 chars -> 10 tokens exactly
    try testing.expectEqual(@as(usize, 10), estimateTextTokens("12345678901234567890123456789012345"));
}

test "estimateMessageTokens: includes overhead" {
    const tokens = estimateMessageTokens("user", "hello");
    // 4 (overhead) + 2 ("user" is 4 chars -> 2 tokens) + 2 ("hello" -> 2) = 8
    try testing.expectEqual(@as(usize, 8), tokens);
}

test "estimateToolUseTokens: includes overhead" {
    const tokens = estimateToolUseTokens("toolu_01", "Bash", "{\"command\":\"echo hi\"}");
    // 8 (overhead) + 3 ("toolu_01" 8 chars -> 3) + 2 ("Bash" 4 chars -> 2) + 8 (24 chars -> 7 -> 8)
    try testing.expect(tokens >= 15); // conservative lower bound
}

test "estimateToolResultTokens: includes overhead" {
    const tokens = estimateToolResultTokens("toolu_01", "hi");
    // 5 (overhead) + 3 ("toolu_01") + 1 ("hi" 2 chars -> 1) = 9
    try testing.expectEqual(@as(usize, 9), tokens);
}

test "estimateSystemTokens: empty is 0, non-empty includes overhead" {
    try testing.expectEqual(@as(usize, 0), estimateSystemTokens(""));
    const tokens = estimateSystemTokens("You are a helpful assistant.");
    try testing.expect(tokens > MESSAGE_OVERHEAD_TOKENS);
}

test "estimateRequestTokens: sums system + messages" {
    const msg_tokens = estimateMessageTokens("user", "hello");
    const total = estimateRequestTokens("You are helpful.", msg_tokens);
    try testing.expect(total > msg_tokens);
    try testing.expectEqual(@as(usize, 0), estimateRequestTokens(null, 0));
}

test "heuristic is conservative (overestimates vs the 4-chars/token English average)" {
    // A 100-char English text at 4 chars/token = 25 tokens; at 3.5 chars/token = ~29.
    const text = "The quick brown fox jumps over the lazy dog. " ** 2; // 90 chars
    const est = estimateTextTokens(text);
    const four_chars_token = @ceil(@as(f64, @floatFromInt(text.len)) / 4.0);
    try testing.expect(est >= @as(usize, @intFromFloat(four_chars_token)));
}
