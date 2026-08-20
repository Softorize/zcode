//! remote-server-04 (swarm-tasks phase): reconnecting WS-client transport policy.
//!
//! The direct-connect client (the client half of Task 19's POST /sessions + WS
//! stream server) needs to survive a dropped socket without giving up after a
//! single retry, and it needs to keep the connection warm with a periodic ping.
//! The reference (SessionsWebSocket.ts:17 RECONNECT/PING constants, :234
//! handleClose reconnect/backoff, :301 startPingInterval) encodes three pure
//! decisions:
//!
//!   1. How long to wait before reconnect attempt N (bounded exponential, but in
//!      practice a fixed ~2s base with a small attempt budget).
//!   2. Whether a given close code is reconnectable at all (auth/forbidden close
//!      codes are terminal: retrying with the same bad credentials is pointless).
//!   3. Whether a keepalive ping is due given the last ping time and the 30s
//!      interval.
//!
//! This module is PURE: no allocation, no IO, no clock. It is the policy; the
//! consumer (src/mcp/client.zig's persistent WS path) supplies the wall-clock
//! values and performs the actual sleep / socket write. Keeping it pure makes
//! the policy fully unit-testable and keeps the timing knobs in one place.
//!
//! The delay schedule reuses core/backoff.zig's `delayMs` so the doubling +
//! saturation logic is shared with the HTTP retry path; the WS layer just pins a
//! 2s base and a 5-attempt budget on top of it.

const std = @import("std");
const backoff = @import("backoff.zig");

/// Base delay before the first reconnect attempt, in milliseconds. Mirrors the
/// reference's RECONNECT base (2s).
pub const RECONNECT_BASE_MS: u64 = 2 * 1000;

/// Hard cap on the reconnect delay. The reference uses a short fixed-ish delay
/// for a live interactive session (it is not the long unattended-HTTP backoff),
/// so we cap an order of magnitude above the base rather than at the 5-minute
/// HTTP ceiling. Keeps a few doublings useful while never stalling an
/// interactive reconnect for minutes.
pub const RECONNECT_MAX_DELAY_MS: u64 = 30 * 1000;

/// Maximum number of reconnect attempts before giving up. Mirrors the
/// reference's MAX reconnect attempts (5).
pub const MAX_RECONNECT_ATTEMPTS: u32 = 5;

/// Keepalive ping interval, in milliseconds. Mirrors the reference's PING
/// interval (30s).
pub const PING_INTERVAL_MS: u64 = 30 * 1000;

/// WebSocket close code: authentication failed. The reference treats 4001 as a
/// terminal close - reconnecting with the same (bad) credentials cannot
/// succeed, so we stop.
pub const CLOSE_CODE_AUTH_FAILED: u16 = 4001;

/// WebSocket close code: forbidden. The reference treats 4003 as terminal for
/// the same reason as 4001.
pub const CLOSE_CODE_FORBIDDEN: u16 = 4003;

/// Delay before reconnect `attempt` (1-based: attempt 1 is the first reconnect).
/// Doubles from RECONNECT_BASE_MS per attempt, capped at RECONNECT_MAX_DELAY_MS.
/// Returns 0 for `attempt == 0` (there is no pre-first-attempt delay) and for any
/// `attempt` beyond MAX_RECONNECT_ATTEMPTS (a 0 here is meaningless because
/// `shouldReconnect`/`attemptsRemaining` will have already stopped the loop, but
/// returning 0 rather than a stale max avoids implying a wait that will not
/// happen).
///
/// The doubling is delegated to backoff.delayMs (shared with the HTTP retry
/// path); backoff.delayMs is 0-based, so attempt N here maps to its attempt N-1.
pub fn nextDelay(attempt: u32) u64 {
    if (attempt == 0) return 0;
    if (attempt > MAX_RECONNECT_ATTEMPTS) return 0;
    return backoff.delayMs(attempt - 1, RECONNECT_BASE_MS, RECONNECT_MAX_DELAY_MS);
}

/// Whether the reconnect budget still has room. `attempt` is the number of
/// reconnects already made; true while fewer than MAX_RECONNECT_ATTEMPTS have
/// been spent.
pub fn attemptsRemaining(attempt: u32) bool {
    return attempt < MAX_RECONNECT_ATTEMPTS;
}

/// Whether a socket closed with `close_code` should be reconnected. Auth (4001)
/// and forbidden (4003) closes are terminal; every other code (normal 1000,
/// abnormal 1006, going-away 1001, etc.) is reconnectable subject to the attempt
/// budget enforced separately by `attemptsRemaining`.
pub fn shouldReconnect(close_code: u16) bool {
    return switch (close_code) {
        CLOSE_CODE_AUTH_FAILED, CLOSE_CODE_FORBIDDEN => false,
        else => true,
    };
}

/// Whether a keepalive ping is due. `now_ms` and `last_ping_ms` are wall-clock
/// milliseconds; fires at or after `interval_ms` have elapsed since the last
/// ping. The caller supplies the values so the function stays pure and testable.
pub fn pingDue(now_ms: i64, last_ping_ms: i64, interval_ms: u64) bool {
    if (now_ms <= last_ping_ms) return false;
    const elapsed: u64 = @intCast(now_ms - last_ping_ms);
    return elapsed >= interval_ms;
}

/// Convenience wrapper for the default 30s ping cadence.
pub fn pingDueDefault(now_ms: i64, last_ping_ms: i64) bool {
    return pingDue(now_ms, last_ping_ms, PING_INTERVAL_MS);
}

const testing = std.testing;

test "nextDelay returns ~2s for attempt 1 and doubles, capped" {
    // No delay before the first attempt is even made.
    try testing.expectEqual(@as(u64, 0), nextDelay(0));
    // First reconnect: 2s base.
    try testing.expectEqual(@as(u64, 2000), nextDelay(1));
    // Doubling thereafter: 4s, 8s, 16s.
    try testing.expectEqual(@as(u64, 4000), nextDelay(2));
    try testing.expectEqual(@as(u64, 8000), nextDelay(3));
    try testing.expectEqual(@as(u64, 16000), nextDelay(4));
    // Attempt 5 would be 32s but is capped at RECONNECT_MAX_DELAY_MS (30s).
    try testing.expectEqual(RECONNECT_MAX_DELAY_MS, nextDelay(5));
}

test "nextDelay stops after attempt 5" {
    // Within budget.
    try testing.expect(nextDelay(5) != 0);
    // Beyond the budget the loop should already have stopped; delay is 0.
    try testing.expectEqual(@as(u64, 0), nextDelay(6));
    try testing.expectEqual(@as(u64, 0), nextDelay(100));
}

test "attemptsRemaining honors the 5-attempt budget" {
    try testing.expect(attemptsRemaining(0));
    try testing.expect(attemptsRemaining(4));
    try testing.expect(!attemptsRemaining(5));
    try testing.expect(!attemptsRemaining(6));
}

test "shouldReconnect is false for auth (4001) and forbidden (4003)" {
    try testing.expect(!shouldReconnect(CLOSE_CODE_AUTH_FAILED));
    try testing.expect(!shouldReconnect(CLOSE_CODE_FORBIDDEN));
    try testing.expect(!shouldReconnect(4001));
    try testing.expect(!shouldReconnect(4003));
}

test "shouldReconnect is true for normal and abnormal closes" {
    try testing.expect(shouldReconnect(1000)); // normal closure
    try testing.expect(shouldReconnect(1001)); // going away
    try testing.expect(shouldReconnect(1006)); // abnormal closure (no close frame)
    try testing.expect(shouldReconnect(1011)); // internal error
    try testing.expect(shouldReconnect(4000)); // an app code that is not auth/forbidden
    try testing.expect(shouldReconnect(4002));
}

test "pingDue fires at or after 30s, not before" {
    // Exactly at the interval: due.
    try testing.expect(pingDue(30_000, 0, PING_INTERVAL_MS));
    // Beyond the interval: due.
    try testing.expect(pingDue(45_000, 0, PING_INTERVAL_MS));
    // Just before: not due.
    try testing.expect(!pingDue(29_999, 0, PING_INTERVAL_MS));
    // No time elapsed: not due.
    try testing.expect(!pingDue(0, 0, PING_INTERVAL_MS));
}

test "pingDue with a nonzero last-ping baseline" {
    // Last ping at t=100_000ms; due again at t>=130_000ms.
    try testing.expect(!pingDue(129_999, 100_000, PING_INTERVAL_MS));
    try testing.expect(pingDue(130_000, 100_000, PING_INTERVAL_MS));
    try testing.expect(pingDue(200_000, 100_000, PING_INTERVAL_MS));
}

test "pingDue tolerates a non-monotonic clock (now <= last)" {
    // Should never fire (and never underflow) when the clock goes backward.
    try testing.expect(!pingDue(50, 100, PING_INTERVAL_MS));
    try testing.expect(!pingDue(100, 100, PING_INTERVAL_MS));
}

test "pingDueDefault uses the 30s interval" {
    try testing.expect(pingDueDefault(30_000, 0));
    try testing.expect(!pingDueDefault(29_999, 0));
}
