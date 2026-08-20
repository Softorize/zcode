//! Provider capability predicate for prompt-mechanism parity (PRD #533).
//! Decides whether a provider reliably emits native tool calls. When true,
//! zcode runs a pure-native loop (no JSON response-contract section, stop on
//! end_turn) like Claude Code; when false (local model runtimes), it keeps the
//! JSON contract + text-fallback parser.

const std = @import("std");

/// Cloud providers that reliably return native tool_use / function-call blocks.
const native_cloud = [_][]const u8{
    "anthropic", "openai",   "azure", "azure-openai",
    "gemini",    "deepseek", "groq",  "openrouter",
};

/// True if `provider` reliably emits native tool calls. `local_native_override`
/// opts a local runtime (local/ollama) into native mode for models that do
/// support it. Unknown providers default to false (keep the JSON contract),
/// which is the safe choice and keeps the test/mock provider on the contract path.
pub fn nativeToolsReliable(provider: []const u8, local_native_override: bool) bool {
    for (native_cloud) |c| {
        if (std.ascii.eqlIgnoreCase(provider, c)) return true;
    }
    if (std.ascii.eqlIgnoreCase(provider, "local") or std.ascii.eqlIgnoreCase(provider, "ollama")) {
        return local_native_override;
    }
    return false;
}

const testing = std.testing;

test "cloud providers are native" {
    try testing.expect(nativeToolsReliable("anthropic", false));
    try testing.expect(nativeToolsReliable("OpenAI", false)); // case-insensitive
    try testing.expect(nativeToolsReliable("openrouter", false));
    try testing.expect(nativeToolsReliable("groq", false));
}

test "local/ollama follow the override" {
    try testing.expect(!nativeToolsReliable("local", false));
    try testing.expect(!nativeToolsReliable("ollama", false));
    try testing.expect(nativeToolsReliable("ollama", true));
    try testing.expect(nativeToolsReliable("local", true));
}

test "unknown and mock providers keep the contract (false)" {
    try testing.expect(!nativeToolsReliable("mock", false));
    try testing.expect(!nativeToolsReliable("some-future-thing", true));
}
