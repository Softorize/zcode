//! 3P (third-party) model fallback suggestion. Ported from
//! claude-code-main/src/utils/model/validateModel.ts get3PFallbackSuggestion
//! (and the get3PModelFallbackSuggestion analog in services/api/errors.ts).
//!
//! When a user on a NON-first-party provider (OpenRouter, OpenAI-compatible,
//! Bedrock, Vertex, ...) selects a brand-new model id that the third-party host
//! has not stocked yet, the provider returns a 404 / NotFound. The reference
//! turns that dead end into a helpful nudge: "Try '<previous-version>' instead".
//! The mapping is new-model -> immediately-preceding-model:
//!   opus-4-6   -> opus-4-1  (claude-opus-4-1-20250805)
//!   sonnet-4-6 -> sonnet-4-5 (claude-sonnet-4-5-20250929)
//!   sonnet-4-5 -> sonnet-4-0 (claude-sonnet-4-20250514)
//!
//! Pure: inputs in, a static model-id string (or null) out. No allocation, no
//! IO. The returned slice is a static string literal owned by no one -- callers
//! must NOT free it.
//!
//! First-party gate: the reference returns undefined when
//! getAPIProvider() === 'firstParty'. The Anthropic-direct provider always has
//! the newest models, so a 404 there is a genuine typo, not a stock-lag the
//! suggestion would paper over. zcode's first-party provider is "anthropic";
//! every other provider string is treated as third-party. The model-id strings
//! we suggest are the canonical first-party ids zcode already knows from
//! providers/anthropic.zig's static catalog, matching the reference's
//! getModelStrings() values for the relevant keys.

const std = @import("std");

/// The canonical first-party provider name. A 404 here means the model id is
/// wrong, not that a downstream host is lagging -- so no suggestion is offered.
pub const FIRST_PARTY_PROVIDER = "anthropic";

// Suggested successor (really predecessor) model ids. These mirror the
// reference's getModelStrings().opus41 / .sonnet45 / .sonnet40 first-party
// values; zcode's anthropic adapter already advertises these canonical ids.
const OPUS_4_1 = "claude-opus-4-1-20250805";
const SONNET_4_5 = "claude-sonnet-4-5-20250929";
const SONNET_4_0 = "claude-sonnet-4-20250514";

/// Suggest a fallback model id for third-party users when the selected model is
/// unavailable (NotFound / 404). Returns null when:
///   - the provider is first-party ("anthropic"), or
///   - the model id has no known predecessor in the suggestion chain.
///
/// Matching mirrors the reference: a case-insensitive substring test on the
/// model id, accepting both hyphen ("opus-4-6") and underscore ("opus_4_6")
/// spellings. The chain is checked newest-first so a more specific match wins.
pub fn suggest(model: []const u8, provider: []const u8) ?[]const u8 {
    // First-party never lags; no suggestion (matches getAPIProvider() gate).
    if (std.ascii.eqlIgnoreCase(provider, FIRST_PARTY_PROVIDER)) return null;

    if (containsAny(model, &.{ "opus-4-6", "opus_4_6" })) return OPUS_4_1;
    if (containsAny(model, &.{ "sonnet-4-6", "sonnet_4_6" })) return SONNET_4_5;
    if (containsAny(model, &.{ "sonnet-4-5", "sonnet_4_5" })) return SONNET_4_0;
    return null;
}

/// Case-insensitive substring search. std.ascii.indexOfIgnoreCase exists but
/// returns ?usize; we only need a boolean over a small needle set.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (containsIgnoreCase(haystack, n)) return true;
    }
    return false;
}

const testing = std.testing;

test "suggest returns predecessor for third-party opus-4-6" {
    try testing.expectEqualStrings(OPUS_4_1, suggest("claude-opus-4-6", "openrouter").?);
}

test "suggest returns null for first-party provider" {
    try testing.expect(suggest("claude-opus-4-6", "anthropic") == null);
    // Case-insensitive first-party match.
    try testing.expect(suggest("claude-opus-4-6", "Anthropic") == null);
}

test "suggest maps the full chain for third-party providers" {
    try testing.expectEqualStrings(SONNET_4_5, suggest("claude-sonnet-4-6", "openrouter").?);
    try testing.expectEqualStrings(SONNET_4_0, suggest("claude-sonnet-4-5", "openai-compatible").?);
}

test "suggest accepts underscore spelling and mixed case" {
    try testing.expectEqualStrings(OPUS_4_1, suggest("CLAUDE_OPUS_4_6", "openrouter").?);
    try testing.expectEqualStrings(SONNET_4_5, suggest("Claude-Sonnet-4-6", "vertex").?);
}

test "suggest returns null for a model with no known successor" {
    try testing.expect(suggest("claude-3-5-haiku", "openrouter") == null);
    try testing.expect(suggest("gpt-4", "openai") == null);
    try testing.expect(suggest("", "openrouter") == null);
}

test "suggest checks newest-first so opus-4-6 does not fall through to sonnet" {
    // A contrived id containing both substrings: the newer (opus) wins.
    try testing.expectEqualStrings(OPUS_4_1, suggest("opus-4-6-sonnet-4-5", "openrouter").?);
}
