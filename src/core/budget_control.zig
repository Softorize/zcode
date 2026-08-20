//! P4 (PRD #534) token/task budget control. Decides whether an agentic loop
//! should proceed, nudge the model that it is near the limit, or stop - mirroring
//! Claude Code's token-budget auto-continuation. Pure: no allocation, no IO.

const std = @import("std");

pub const Decision = enum { proceed, nudge, stop };

/// Fraction of the budget at which to nudge the model toward wrapping up.
pub const NUDGE_THRESHOLD: f64 = 0.9;

/// Decide based on tokens used vs the budget and how many auto-continuations
/// have already happened. Stop when the budget is exhausted or continuations are
/// spent; nudge at >= 90%; otherwise proceed. A zero/absent budget always
/// proceeds (no budget configured).
pub fn decide(used: u64, budget: u64, continuations: u32, max_continuations: u32) Decision {
    if (budget == 0) return .proceed;
    if (continuations >= max_continuations) return .stop;
    if (used >= budget) return .stop;
    const frac = @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(budget));
    if (frac >= NUDGE_THRESHOLD) return .nudge;
    return .proceed;
}

/// Phase 22 (agent-loop-deep-11): per-turn USD budget ceiling. Decide whether
/// an agentic turn should stop because the cumulative estimated spend has
/// reached a configured dollar cap. A zero/absent cap (cap_usd <= 0) always
/// proceeds (no cap configured), matching the reference's `maxBudgetUsd`
/// being optional (QueryEngine.ts:981-1001). The `f64` comparison is a simple
/// ceiling check; no nudge stage is defined for the dollar cap (the reference
/// stops hard at the budget) so this returns only .proceed or .stop.
pub fn decideUsd(used_usd: f64, cap_usd: f64) Decision {
    if (cap_usd <= 0) return .proceed;
    if (used_usd >= cap_usd) return .stop;
    return .proceed;
}

const testing = std.testing;

test "no budget always proceeds" {
    try testing.expectEqual(Decision.proceed, decide(1_000_000, 0, 0, 10));
}

test "proceeds below the nudge threshold" {
    try testing.expectEqual(Decision.proceed, decide(500, 1000, 0, 10));
    try testing.expectEqual(Decision.proceed, decide(899, 1000, 0, 10));
}

test "nudges at or above 90 percent" {
    try testing.expectEqual(Decision.nudge, decide(900, 1000, 0, 10));
    try testing.expectEqual(Decision.nudge, decide(950, 1000, 0, 10));
}

test "stops when exhausted or continuations spent" {
    try testing.expectEqual(Decision.stop, decide(1000, 1000, 0, 10));
    try testing.expectEqual(Decision.stop, decide(1200, 1000, 0, 10));
    try testing.expectEqual(Decision.stop, decide(100, 1000, 10, 10));
}

test "decideUsd: no cap always proceeds" {
    try testing.expectEqual(Decision.proceed, decideUsd(100.0, 0));
    try testing.expectEqual(Decision.proceed, decideUsd(0.0, 0));
    // A negative cap is treated as no cap (defensive).
    try testing.expectEqual(Decision.proceed, decideUsd(5.0, -1.0));
}

test "decideUsd: proceeds below the cap" {
    try testing.expectEqual(Decision.proceed, decideUsd(0.49, 0.50));
    try testing.expectEqual(Decision.proceed, decideUsd(0.0, 0.50));
}

test "decideUsd: stops at or above the cap" {
    try testing.expectEqual(Decision.stop, decideUsd(0.50, 0.50));
    try testing.expectEqual(Decision.stop, decideUsd(1.00, 0.50));
}
