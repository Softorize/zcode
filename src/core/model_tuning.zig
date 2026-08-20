const std = @import("std");

/// Per-model wire-shape tuning shared across providers. Each provider's
/// `send` / `stream` / `streamLive` path consults `lookup()` and uses
/// the returned profile to override the user's requested values where
/// the upstream API has strict requirements.
///
/// Mirrors Claude Code's per-model behaviour table but expressed as a
/// flat registry so we don't have to scatter `if (model == "X") ...`
/// branches across each provider file. Adding a new model is a single
/// entry in the table at the bottom of this module.
pub const Profile = struct {
    /// Override for `temperature`. `null` means "pass the user's
    /// requested value through unchanged".
    temperature: ?f32 = null,
    /// True when the model expects a `thinking.type = disabled` field
    /// in the request body. Currently honored by the openai-compatible
    /// adapter for Moonshot Kimi.
    disable_thinking: bool = false,
    /// True when the model is known to emit `reasoning_content` chunks
    /// (kimi-k2.6, DeepSeek-R1, Qwen3-thinking, kimi-k2-thinking*). The
    /// agent loop already auto-detects this from the response shape;
    /// this flag lets a provider preemptively size its output budget.
    is_reasoning_model: bool = false,
    /// Suggested floor on max_output_tokens. Reasoning models need
    /// headroom for hidden tokens before content tokens flow.
    min_max_output_tokens: ?usize = null,
};

/// Return the tuning profile for `model_name`. Returns an all-defaults
/// profile (effectively a no-op) when the model is not in the table.
pub fn lookup(model_name: []const u8) Profile {
    // Moonshot Kimi family
    if (std.mem.eql(u8, model_name, "kimi-k2.5")) {
        return .{
            .temperature = 0.6,
            .disable_thinking = true,
        };
    }
    if (std.mem.eql(u8, model_name, "kimi-k2-thinking") or
        std.mem.eql(u8, model_name, "kimi-k2.6") or
        std.mem.eql(u8, model_name, "kimi-k2-thinking-turbo"))
    {
        return .{
            .temperature = 1.0,
            .is_reasoning_model = true,
            .min_max_output_tokens = 16384,
        };
    }
    // OpenAI o-series and gpt-5 family accept a `reasoning_effort`
    // field; their tuning is handled in openai.zig's
    // appendReasoningEffortIfNeeded path. Mark them as reasoning
    // models so providers can size their budgets accordingly.
    if (std.mem.startsWith(u8, model_name, "o1") or
        std.mem.startsWith(u8, model_name, "o3") or
        std.mem.startsWith(u8, model_name, "o4") or
        std.mem.startsWith(u8, model_name, "gpt-5"))
    {
        return .{
            .is_reasoning_model = true,
            .min_max_output_tokens = 8192,
        };
    }
    // DeepSeek-R1 family
    if (std.mem.indexOf(u8, model_name, "deepseek-r1") != null or
        std.mem.indexOf(u8, model_name, "DeepSeek-R1") != null)
    {
        return .{
            .is_reasoning_model = true,
            .min_max_output_tokens = 16384,
        };
    }
    return .{};
}

/// Effective temperature: profile override if present, else the
/// user-requested value. Provider adapters call this once per request
/// build so they don't have to inline the null-check.
pub fn effectiveTemperature(model_name: []const u8, requested: f32) f32 {
    return lookup(model_name).temperature orelse requested;
}

/// Effective max_output_tokens: max(user_requested, profile floor).
/// Reasoning models with a `min_max_output_tokens` floor will get
/// raised to that floor when the user's config underprovisions them.
pub fn effectiveMaxOutputTokens(model_name: []const u8, requested: usize) usize {
    const profile = lookup(model_name);
    if (profile.min_max_output_tokens) |floor| {
        return @max(requested, floor);
    }
    return requested;
}

const testing = std.testing;

test "kimi-k2.6 is pinned to temperature 1.0 and flagged as reasoning" {
    const p = lookup("kimi-k2.6");
    try testing.expectEqual(@as(?f32, 1.0), p.temperature);
    try testing.expect(p.is_reasoning_model);
    try testing.expect(p.min_max_output_tokens != null);
}

test "kimi-k2.5 keeps the older thinking-disabled profile" {
    const p = lookup("kimi-k2.5");
    try testing.expectEqual(@as(?f32, 0.6), p.temperature);
    try testing.expect(p.disable_thinking);
}

test "o3-mini is recognized as a reasoning model" {
    const p = lookup("o3-mini");
    try testing.expect(p.is_reasoning_model);
}

test "unknown model returns all-defaults profile" {
    const p = lookup("gpt-4o");
    try testing.expectEqual(@as(?f32, null), p.temperature);
    try testing.expect(!p.is_reasoning_model);
    try testing.expect(!p.disable_thinking);
    try testing.expectEqual(@as(?usize, null), p.min_max_output_tokens);
}

test "effectiveTemperature passes through when no profile override" {
    try testing.expectEqual(@as(f32, 0.7), effectiveTemperature("gpt-4o", 0.7));
}

test "effectiveTemperature applies kimi-k2.6 pin" {
    try testing.expectEqual(@as(f32, 1.0), effectiveTemperature("kimi-k2.6", 0.2));
}

test "effectiveMaxOutputTokens raises kimi-k2.6 floor" {
    try testing.expectEqual(@as(usize, 16384), effectiveMaxOutputTokens("kimi-k2.6", 4096));
}

test "effectiveMaxOutputTokens leaves higher values untouched" {
    try testing.expectEqual(@as(usize, 32768), effectiveMaxOutputTokens("kimi-k2.6", 32768));
}
