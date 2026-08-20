//! Absolute-token buffer threshold model for auto-compaction.
//!
//! Port of the reference's `services/compact/autoCompact.ts` math
//! (getEffectiveContextWindowSize / getAutoCompactThreshold /
//! calculateTokenWarningState). Pure threshold arithmetic only -- this
//! module reads no global state except, via small explicit overloads,
//! the three documented env overrides. The pure functions take all
//! overrides as parameters so tests stay hermetic; the `*FromEnv`
//! wrappers read the env vars through the runtime `env` helper.
//!
//! These buffers coexist with `types.BudgetPlan.CompactionThresholds`:
//! the percentage bands gate the cheap per-turn rule-based snapshot,
//! while this buffer model gates the expensive LLM summary at the
//! compaction boundary and drives the warning UI in
//! `context_suggestions.zig`.

const std = @import("std");
const types = @import("types.zig");
const env = @import("env.zig");

/// Reserve this many tokens for the compaction summary output.
/// Based on p99.99 of compact summary output being ~17,387 tokens
/// (autoCompact.ts:28-30).
pub const MAX_OUTPUT_TOKENS_FOR_SUMMARY: usize = types.MAX_OUTPUT_TOKENS_FOR_SUMMARY;
pub const AUTOCOMPACT_BUFFER_TOKENS: usize = types.AUTOCOMPACT_BUFFER_TOKENS;
pub const WARNING_THRESHOLD_BUFFER_TOKENS: usize = types.WARNING_THRESHOLD_BUFFER_TOKENS;
pub const ERROR_THRESHOLD_BUFFER_TOKENS: usize = types.ERROR_THRESHOLD_BUFFER_TOKENS;
pub const MANUAL_COMPACT_BUFFER_TOKENS: usize = types.MANUAL_COMPACT_BUFFER_TOKENS;

/// Env var names (registered in env_registry.zig).
pub const ENV_AUTO_COMPACT_WINDOW = "CLAUDE_CODE_AUTO_COMPACT_WINDOW";
pub const ENV_AUTOCOMPACT_PCT_OVERRIDE = "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE";
pub const ENV_BLOCKING_LIMIT_OVERRIDE = "CLAUDE_CODE_BLOCKING_LIMIT_OVERRIDE";

/// Effective context window = contextWindow - reservedSummary, where the
/// reserved summary budget is min(model max output, MAX_OUTPUT_TOKENS).
/// `env_window_override` clamps the context window down (never up) and is
/// ignored when null, zero, or larger than the real window.
/// Saturating throughout so `window < reserved` returns 0, never
/// underflows usize. Mirrors getEffectiveContextWindowSize
/// (autoCompact.ts:33-49).
pub fn effectiveContextWindow(
    ctx_window: usize,
    max_output_tokens_for_model: usize,
    env_window_override: ?usize,
) usize {
    const reserved = @min(max_output_tokens_for_model, MAX_OUTPUT_TOKENS_FOR_SUMMARY);
    var window = ctx_window;
    if (env_window_override) |parsed| {
        if (parsed > 0) window = @min(window, parsed);
    }
    return window -| reserved;
}

/// Auto-compact threshold = effective - AUTOCOMPACT_BUFFER. A percent
/// override in (0,100] returns min(floor(effective * pct/100), threshold)
/// so the override can only lower (never raise) the trigger point.
/// Mirrors getAutoCompactThreshold (autoCompact.ts:69-91).
pub fn autoCompactThreshold(effective: usize, pct_override: ?f32) usize {
    const threshold = effective -| AUTOCOMPACT_BUFFER_TOKENS;
    if (pct_override) |pct| {
        if (pct > 0 and pct <= 100) {
            const eff_f: f64 = @floatFromInt(effective);
            const pct_threshold: usize = @intFromFloat(@floor(eff_f * (@as(f64, pct) / 100.0)));
            return @min(pct_threshold, threshold);
        }
    }
    return threshold;
}

/// Compute the warning tiers for a given usage. `auto_enabled` selects
/// the active threshold: the auto-compact threshold when auto-compaction
/// is on, else the full effective window (matching the reference's
/// `isAutoCompactEnabled() ? autoCompactThreshold : effective`).
/// `blocking_override`, when > 0, replaces the default blocking limit of
/// `effective - MANUAL_COMPACT_BUFFER`. Mirrors calculateTokenWarningState
/// (autoCompact.ts:93-145).
pub fn warningState(
    token_usage: usize,
    effective: usize,
    auto_threshold: usize,
    auto_enabled: bool,
    blocking_override: ?usize,
) types.TokenWarningState {
    const threshold = if (auto_enabled) auto_threshold else effective;

    // percentLeft = max(0, round((threshold - usage)/threshold*100)).
    var percent_left: u8 = 0;
    if (threshold > 0 and token_usage < threshold) {
        const remaining: f64 = @floatFromInt(threshold - token_usage);
        const thr: f64 = @floatFromInt(threshold);
        const raw = @round((remaining / thr) * 100.0);
        const clamped = std.math.clamp(raw, 0.0, 100.0);
        percent_left = @intFromFloat(clamped);
    }

    const warning_threshold = threshold -| WARNING_THRESHOLD_BUFFER_TOKENS;
    const error_threshold = threshold -| ERROR_THRESHOLD_BUFFER_TOKENS;

    const default_blocking = effective -| MANUAL_COMPACT_BUFFER_TOKENS;
    var blocking_limit = default_blocking;
    if (blocking_override) |ovr| {
        if (ovr > 0) blocking_limit = ovr;
    }

    return .{
        .percent_left = percent_left,
        .is_above_warning = token_usage >= warning_threshold,
        .is_above_error = token_usage >= error_threshold,
        .is_above_autocompact = auto_enabled and token_usage >= auto_threshold,
        .is_at_blocking_limit = token_usage >= blocking_limit,
    };
}

// ── Env-reading wrappers ──────────────────────────────────────────────
//
// Read the three documented overrides through `env.getenv` (borrowing
// libc storage; no allocation, no free needed). Invalid or unset values
// fall back to null so the pure functions use their defaults.

/// Parse `CLAUDE_CODE_AUTO_COMPACT_WINDOW` (positive integer) or null.
pub fn windowOverrideFromEnv() ?usize {
    return parseUsizeEnv(ENV_AUTO_COMPACT_WINDOW);
}

/// Parse `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` (float in (0,100]) or null.
pub fn pctOverrideFromEnv() ?f32 {
    const raw = env.getenv(ENV_AUTOCOMPACT_PCT_OVERRIDE) orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    const parsed = std.fmt.parseFloat(f32, trimmed) catch return null;
    if (!(parsed > 0 and parsed <= 100)) return null;
    return parsed;
}

/// Parse `CLAUDE_CODE_BLOCKING_LIMIT_OVERRIDE` (positive integer) or null.
pub fn blockingOverrideFromEnv() ?usize {
    return parseUsizeEnv(ENV_BLOCKING_LIMIT_OVERRIDE);
}

fn parseUsizeEnv(name: []const u8) ?usize {
    const raw = env.getenv(name) orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    const parsed = std.fmt.parseInt(usize, trimmed, 10) catch return null;
    if (parsed == 0) return null;
    return parsed;
}

const testing = std.testing;

test "effectiveContextWindow reserves min(model output, cap)" {
    // 200k window, model output 64k -> reserve capped at 20k -> 180k.
    try testing.expectEqual(@as(usize, 180_000), effectiveContextWindow(200_000, 64_000, null));
    // Model output below the cap reserves the smaller amount.
    try testing.expectEqual(@as(usize, 195_000), effectiveContextWindow(200_000, 5_000, null));
}

test "effectiveContextWindow env window override clamps down" {
    // CLAUDE_CODE_AUTO_COMPACT_WINDOW=100000 -> 100k - 20k = 80k.
    try testing.expectEqual(@as(usize, 80_000), effectiveContextWindow(200_000, 64_000, 100_000));
    // An override larger than the real window is ignored.
    try testing.expectEqual(@as(usize, 180_000), effectiveContextWindow(200_000, 64_000, 500_000));
}

test "effectiveContextWindow saturates when reserved exceeds window" {
    try testing.expectEqual(@as(usize, 0), effectiveContextWindow(10_000, 64_000, null));
}

test "autoCompactThreshold default subtracts the buffer" {
    // effective 180k -> 180k - 13k = 167k.
    try testing.expectEqual(@as(usize, 167_000), autoCompactThreshold(180_000, null));
}

test "autoCompactThreshold pct override yields min(floor(pct), default)" {
    const effective: usize = 180_000;
    const default_thr = autoCompactThreshold(effective, null); // 167_000
    // 50% of 180k = 90k, which is below default -> use 90k.
    const got = autoCompactThreshold(effective, 50);
    try testing.expectEqual(@as(usize, 90_000), got);
    try testing.expect(got <= default_thr);
    // 99% of 180k = 178,200 > default 167k -> clamp to default.
    try testing.expectEqual(default_thr, autoCompactThreshold(effective, 99));
    // Out-of-range pct (0 or >100) ignored -> default.
    try testing.expectEqual(default_thr, autoCompactThreshold(effective, 0));
    try testing.expectEqual(default_thr, autoCompactThreshold(effective, 150));
}

test "warningState percentLeft is zero at or above threshold" {
    const effective: usize = 180_000;
    const auto_thr = autoCompactThreshold(effective, null); // 167_000
    // Usage equal to threshold -> 0 percent left.
    const at = warningState(auto_thr, effective, auto_thr, true, null);
    try testing.expectEqual(@as(u8, 0), at.percent_left);
    // Usage above threshold -> still 0, never negative.
    const above = warningState(auto_thr + 5_000, effective, auto_thr, true, null);
    try testing.expectEqual(@as(u8, 0), above.percent_left);
    // Zero usage -> 100 percent left.
    const fresh = warningState(0, effective, auto_thr, true, null);
    try testing.expectEqual(@as(u8, 100), fresh.percent_left);
}

test "warningState blocking limit uses effective - manual buffer" {
    const effective: usize = 180_000;
    const auto_thr = autoCompactThreshold(effective, null);
    const blocking_point = effective - MANUAL_COMPACT_BUFFER_TOKENS; // 177_000
    const below = warningState(blocking_point - 1, effective, auto_thr, true, null);
    try testing.expect(!below.is_at_blocking_limit);
    const at = warningState(blocking_point, effective, auto_thr, true, null);
    try testing.expect(at.is_at_blocking_limit);
}

test "warningState blocking override forces the limit" {
    const effective: usize = 180_000;
    const auto_thr = autoCompactThreshold(effective, null);
    // CLAUDE_CODE_BLOCKING_LIMIT_OVERRIDE=50000 -> blocking at 50k.
    const below = warningState(49_999, effective, auto_thr, true, 50_000);
    try testing.expect(!below.is_at_blocking_limit);
    const at = warningState(50_000, effective, auto_thr, true, 50_000);
    try testing.expect(at.is_at_blocking_limit);
}

test "warningState warning and error tiers and auto-disabled threshold" {
    const effective: usize = 180_000;
    const auto_thr = autoCompactThreshold(effective, null); // 167_000

    // Auto-enabled: threshold = auto_thr. warning/error = auto_thr - 20k = 147k.
    const warn_point = auto_thr - WARNING_THRESHOLD_BUFFER_TOKENS; // 147_000
    const below_warn = warningState(warn_point - 1, effective, auto_thr, true, null);
    try testing.expect(!below_warn.is_above_warning);
    try testing.expect(!below_warn.is_above_error);
    const at_warn = warningState(warn_point, effective, auto_thr, true, null);
    try testing.expect(at_warn.is_above_warning);
    try testing.expect(at_warn.is_above_error);
    try testing.expect(!at_warn.is_above_autocompact);

    // is_above_autocompact only when auto-enabled and usage >= auto_thr.
    const at_auto = warningState(auto_thr, effective, auto_thr, true, null);
    try testing.expect(at_auto.is_above_autocompact);

    // Auto-disabled: threshold = effective (180k); is_above_autocompact never set.
    const disabled = warningState(auto_thr, effective, auto_thr, false, null);
    try testing.expect(!disabled.is_above_autocompact);
    // At auto_thr (167k) against the larger effective threshold, more headroom remains.
    try testing.expect(disabled.percent_left > at_auto.percent_left);
}
