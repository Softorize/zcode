//! Pure helper for the max-output-tokens escalation (agent-loop-deep-04).
//!
//! When a model response is cut off because it hit the request's
//! `max_output_tokens` cap (finish_reason "length" / stop_reason
//! "max_tokens"), the reference loop retries the SAME request once at a
//! much larger cap before giving up and falling into the multi-turn
//! resume-nudge recovery. This mirrors `query.ts:1188-1221`
//! (`ESCALATED_MAX_TOKENS = 64k`, guarded so it fires once per turn).
//!
//! This module owns only the cap arithmetic so the decision is unit
//! testable without the loop. The agent runtime holds the loop-local
//! "already escalated this turn" flag and applies the returned cap as a
//! one-shot override on the next request build.

const std = @import("std");

/// Default per-request output cap zcode requests when the operator has
/// not configured a larger `reserved_output_tokens`. The reference uses
/// 8192 as the floor below which an escalation is worthwhile; a request
/// at or below this is a candidate to escalate.
pub const DEFAULT_CAP: u32 = 8192;

/// The escalated cap the single-shot retry requests, matching the
/// reference's `ESCALATED_MAX_TOKENS`.
pub const ESCALATED_CAP: u32 = 65536;

/// Decide the next output-token cap to retry with after a max-output
/// truncation. Returns `ESCALATED_CAP` only when the current request was
/// at or below the default cap AND we have not already escalated this
/// turn; otherwise null (no further escalation -- fall through to the
/// resume-nudge recovery). The `already_escalated` guard is load-bearing:
/// without it a model that keeps hitting even the 64k cap would retry the
/// same request forever.
pub fn nextCap(current_cap: u32, already_escalated: bool) ?u32 {
    if (already_escalated) return null;
    if (current_cap <= DEFAULT_CAP) return ESCALATED_CAP;
    return null;
}

/// Resolve the output-token cap for the next request build: a pending
/// per-turn escalation override wins over the configured default. The
/// loop consumes its override flag separately (it is a one-shot side
/// effect), so this is the pure value-selection half of that logic and
/// is what the loop test asserts against.
pub fn effectiveCap(override_cap: ?u32, configured_cap: u32) u32 {
    return override_cap orelse configured_cap;
}

/// Per-the-reference cap on the resume-nudge recovery loop specifically
/// for the max-output-tokens case. The broader truncation-continuation
/// recovery stays at its own higher cap; this tighter value applies only
/// once the single-shot escalation has been spent. Mirrors
/// `MAX_OUTPUT_TOKENS_RECOVERY_LIMIT` (query.ts:1223).
pub const MAX_OUTPUT_RECOVERY_LIMIT: u8 = 3;

const testing = std.testing;

test "nextCap escalates from default cap when not yet escalated" {
    try testing.expectEqual(@as(?u32, ESCALATED_CAP), nextCap(DEFAULT_CAP, false));
    // A cap below the default is still a candidate (e.g. a small override).
    try testing.expectEqual(@as(?u32, ESCALATED_CAP), nextCap(4096, false));
}

test "nextCap returns null when already at escalated cap" {
    try testing.expectEqual(@as(?u32, null), nextCap(ESCALATED_CAP, false));
    // Anything above the default is past the escalation floor.
    try testing.expectEqual(@as(?u32, null), nextCap(DEFAULT_CAP + 1, false));
}

test "nextCap returns null when already escalated this turn" {
    try testing.expectEqual(@as(?u32, null), nextCap(DEFAULT_CAP, true));
    try testing.expectEqual(@as(?u32, null), nextCap(4096, true));
}

test "MAX_OUTPUT_RECOVERY_LIMIT matches the reference's tightened cap" {
    try testing.expectEqual(@as(u8, 3), MAX_OUTPUT_RECOVERY_LIMIT);
}

test "effectiveCap prefers the escalation override over the configured cap" {
    // No override: the configured cap is used (the steady-state request build).
    try testing.expectEqual(@as(u32, 16384), effectiveCap(null, 16384));
    // Override pending: the escalated cap wins for this single retry. This is the
    // value the loop test would otherwise have to observe on the second request.
    try testing.expectEqual(ESCALATED_CAP, effectiveCap(ESCALATED_CAP, 8192));
    try testing.expectEqual(@as(u32, 12345), effectiveCap(12345, 8192));
}

test "escalation flow: truncated-at-default escalates, then no second escalation" {
    // First truncation at the default cap arms the escalated cap.
    const first = nextCap(DEFAULT_CAP, false) orelse return error.TestExpectedEscalation;
    try testing.expectEqual(ESCALATED_CAP, first);
    // The loop applies it via effectiveCap on the retry build.
    try testing.expectEqual(ESCALATED_CAP, effectiveCap(first, DEFAULT_CAP));
    // A second truncation (now already escalated) does NOT escalate again --
    // it falls through to the tighter resume-nudge recovery instead of looping.
    try testing.expectEqual(@as(?u32, null), nextCap(ESCALATED_CAP, true));
}

test "default config above DEFAULT_CAP never escalates" {
    // zcode's default reserved_output_tokens (16384) is already above the 8k
    // escalation floor, so escalation is a deliberate no-op there: it only
    // fires for providers/configs pinned at-or-below the small default cap.
    try testing.expectEqual(@as(?u32, null), nextCap(16384, false));
}
