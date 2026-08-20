//! P4 (PRD #534) retry backoff schedule. Mirrors Claude Code's persistent
//! retry: exponential delay from a base, capped at a max, with a separate cap on
//! consecutive 529 (overloaded) responses. Pure: no allocation, no IO, no clock.

const std = @import("std");

pub const BASE_DELAY_MS: u64 = 500;
pub const MAX_DELAY_MS: u64 = 5 * 60 * 1000; // 5 minutes
pub const MAX_CONSECUTIVE_529: u32 = 3;

/// Upper bound on the computed exponential backoff in persistent/unattended
/// retry mode (Task 7.8). Mirrors the reference's PERSISTENT_MAX_BACKOFF_MS (5
/// min). Aliased to MAX_DELAY_MS since the existing schedule already caps there;
/// named separately so the persistent path reads intent-first.
pub const PERSISTENT_MAX_BACKOFF_MS: u64 = MAX_DELAY_MS; // 5 minutes

/// Upper bound on how long a single rate-limit reset header can ask us to wait.
/// Mirrors the reference's PERSISTENT_RESET_CAP_MS (6 hours): a hostile or buggy
/// `anthropic-ratelimit-unified-reset` value cannot stall a retry indefinitely.
pub const PERSISTENT_RESET_CAP_MS: u64 = 6 * 60 * 60 * 1000; // 6 hours

/// In persistent mode a single wait can be up to PERSISTENT_RESET_CAP_MS (6 hr).
/// Sleeping that long in one call would make ESC unresponsive, so the persistent
/// retry loop chunks the wait into HEARTBEAT_INTERVAL_MS pieces and checks for
/// cancellation between chunks. Mirrors the reference's HEARTBEAT_INTERVAL_MS
/// (30 s). Pure constant; the chunking loop lives at the call site.
pub const HEARTBEAT_INTERVAL_MS: u64 = 30 * 1000; // 30 seconds

/// Delay before retry `attempt` (0-based: attempt 0 is the first retry). Doubles
/// per attempt from `base_ms`, capped at `max_ms`. Deterministic (no jitter) so
/// it is testable; callers may add jitter at the call site.
pub fn delayMs(attempt: u32, base_ms: u64, max_ms: u64) u64 {
    if (attempt >= 63) return max_ms;
    const shifted = std.math.shl(u64, base_ms, attempt);
    // shl saturates poorly on overflow; guard explicitly.
    if (attempt >= 40 or shifted > max_ms or shifted < base_ms) return max_ms;
    return @min(shifted, max_ms);
}

/// Whether to keep retrying given the attempt count and the run of consecutive
/// 529 responses. Stops once `consecutive_529` reaches its cap or `attempt`
/// reaches `max_attempts`.
pub fn shouldRetry(attempt: u32, max_attempts: u32, consecutive_529: u32) bool {
    if (consecutive_529 >= MAX_CONSECUTIVE_529) return false;
    return attempt < max_attempts;
}

const testing = std.testing;

test "delayMs doubles then caps" {
    try testing.expectEqual(@as(u64, 500), delayMs(0, BASE_DELAY_MS, MAX_DELAY_MS));
    try testing.expectEqual(@as(u64, 1000), delayMs(1, BASE_DELAY_MS, MAX_DELAY_MS));
    try testing.expectEqual(@as(u64, 2000), delayMs(2, BASE_DELAY_MS, MAX_DELAY_MS));
    try testing.expectEqual(@as(u64, 4000), delayMs(3, BASE_DELAY_MS, MAX_DELAY_MS));
    // far out, must be capped, never overflow
    try testing.expectEqual(MAX_DELAY_MS, delayMs(50, BASE_DELAY_MS, MAX_DELAY_MS));
    try testing.expectEqual(MAX_DELAY_MS, delayMs(1000, BASE_DELAY_MS, MAX_DELAY_MS));
}

test "shouldRetry honors attempt and 529 caps" {
    try testing.expect(shouldRetry(0, 5, 0));
    try testing.expect(shouldRetry(4, 5, 2));
    try testing.expect(!shouldRetry(5, 5, 0)); // attempts exhausted
    try testing.expect(!shouldRetry(0, 5, MAX_CONSECUTIVE_529)); // 529 cap hit
}

test "delayMs caps at PERSISTENT_MAX_BACKOFF_MS in persistent schedule" {
    // The persistent/unattended retry path (Task 7.8) uses BASE_DELAY_MS doubled
    // per attempt but never exceeding PERSISTENT_MAX_BACKOFF_MS (5 min). Early
    // attempts grow; late attempts saturate at the 5-minute cap.
    try testing.expectEqual(@as(u64, 500), delayMs(0, BASE_DELAY_MS, PERSISTENT_MAX_BACKOFF_MS));
    try testing.expectEqual(@as(u64, 64_000), delayMs(7, BASE_DELAY_MS, PERSISTENT_MAX_BACKOFF_MS));
    // Attempt 10 -> 500 << 10 = 512000 which exceeds the 5-minute (300000) cap.
    try testing.expectEqual(PERSISTENT_MAX_BACKOFF_MS, delayMs(10, BASE_DELAY_MS, PERSISTENT_MAX_BACKOFF_MS));
    try testing.expectEqual(PERSISTENT_MAX_BACKOFF_MS, delayMs(100, BASE_DELAY_MS, PERSISTENT_MAX_BACKOFF_MS));
    // The cap really is 5 minutes.
    try testing.expectEqual(@as(u64, 5 * 60 * 1000), PERSISTENT_MAX_BACKOFF_MS);
}
