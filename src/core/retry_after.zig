//! P4 (PRD #534) response-header-aware retry delay. Mirrors Claude Code's
//! `getRetryDelay` / `getRateLimitResetDelayMs`: when the provider tells us how
//! long to wait (via the `retry-after` header or the
//! `anthropic-ratelimit-unified-reset` header), honor that instead of guessing
//! with client-computed exponential/linear backoff.
//!
//! Pure: no allocation, no IO, no wall clock. The caller passes "now" (unix ms,
//! from `core/clock.zig`'s `nowMillis`) so these functions stay unit-testable
//! without sleeping or touching the clock.
//!
//! Reference: withRetry.ts:530-548 (`getRetryDelay`), :814-822
//! (`getRateLimitResetDelayMs`).

const std = @import("std");
const extractors = @import("../providers/extractors.zig");
const backoff = @import("backoff.zig");

pub const HeaderPair = extractors.HeaderPair;

/// `retry-after: <seconds>`. The reference only handles the integer-seconds
/// form (not the HTTP-date form); match that exactly. Returns the delay in
/// milliseconds, or null when the header is absent or not an integer.
pub fn parseRetryAfterMs(headers: []const HeaderPair) ?u64 {
    const raw = extractors.findHeader(headers, "retry-after") orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return null;
    const seconds = std.fmt.parseInt(u64, trimmed, 10) catch return null;
    // Guard the multiply: cap absurd values rather than overflowing.
    if (seconds > std.math.maxInt(u64) / 1000) return null;
    return seconds * 1000;
}

/// `anthropic-ratelimit-unified-reset: <unix-seconds>`. The reference parses it
/// with `Number(...)`, so tolerate a fractional value (e.g. "1717000000.5") by
/// reading the integer part. Returns `reset*1000 - now_unix_ms`, or null when:
///   - the header is absent or unparseable,
///   - the computed delay is <= 0 (reset is in the past / now).
/// A delay far in the future is clamped to `PERSISTENT_RESET_CAP_MS` (6 hr).
pub fn parseRateLimitResetMs(headers: []const HeaderPair, now_unix_ms: i64) ?u64 {
    const raw = extractors.findHeader(headers, "anthropic-ratelimit-unified-reset") orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return null;

    // Float-tolerant: take the integer part before any '.'.
    const int_part = blk: {
        if (std.mem.indexOfScalar(u8, trimmed, '.')) |dot| break :blk trimmed[0..dot];
        break :blk trimmed;
    };
    if (int_part.len == 0) return null;
    const reset_seconds = std.fmt.parseInt(i64, int_part, 10) catch return null;

    // reset is unix *seconds*; convert to ms before subtracting now (which is
    // already ms). Guard the multiply against overflow.
    if (reset_seconds > std.math.maxInt(i64) / 1000) return null;
    const reset_ms = reset_seconds * 1000;
    const delta = reset_ms - now_unix_ms;
    if (delta <= 0) return null;

    const delta_u: u64 = @intCast(delta);
    return @min(delta_u, backoff.PERSISTENT_RESET_CAP_MS);
}

/// Pick the delay to wait before the next retry. Precedence mirrors the
/// reference: the rate-limit reset header wins, then `retry-after`, then the
/// caller's client-computed fallback (e.g. `attempt*300` or exponential
/// backoff). This lets a provider that tells us exactly when to come back
/// override our guess, while preserving the existing behavior when no timing
/// header is present.
pub fn effectiveDelayMs(headers: []const HeaderPair, now_unix_ms: i64, computed_fallback_ms: u64) u64 {
    if (parseRateLimitResetMs(headers, now_unix_ms)) |reset| return reset;
    if (parseRetryAfterMs(headers)) |ra| return ra;
    return computed_fallback_ms;
}

// --- Tests ---

const testing = std.testing;

fn hp(name: []const u8, value: []const u8) HeaderPair {
    return .{ .name = name, .value = value };
}

test "parseRetryAfterMs integer seconds" {
    const headers = [_]HeaderPair{hp("retry-after", "5")};
    try testing.expectEqual(@as(?u64, 5000), parseRetryAfterMs(&headers));
}

test "parseRetryAfterMs non-numeric returns null" {
    const headers = [_]HeaderPair{hp("retry-after", "notanumber")};
    try testing.expectEqual(@as(?u64, null), parseRetryAfterMs(&headers));
}

test "parseRetryAfterMs absent returns null" {
    const headers = [_]HeaderPair{hp("content-type", "application/json")};
    try testing.expectEqual(@as(?u64, null), parseRetryAfterMs(&headers));
}

test "parseRateLimitResetMs future reset gives positive delay" {
    const now: i64 = 1_717_000_000_000; // ms
    // reset 10s in the future (unix seconds form)
    const headers = [_]HeaderPair{hp("anthropic-ratelimit-unified-reset", "1717000010")};
    try testing.expectEqual(@as(?u64, 10_000), parseRateLimitResetMs(&headers, now));
}

test "parseRateLimitResetMs float-tolerant" {
    const now: i64 = 1_717_000_000_000;
    const headers = [_]HeaderPair{hp("anthropic-ratelimit-unified-reset", "1717000010.75")};
    // integer part used -> 10s
    try testing.expectEqual(@as(?u64, 10_000), parseRateLimitResetMs(&headers, now));
}

test "parseRateLimitResetMs past reset returns null" {
    const now: i64 = 1_717_000_000_000;
    const headers = [_]HeaderPair{hp("anthropic-ratelimit-unified-reset", "1716999990")};
    try testing.expectEqual(@as(?u64, null), parseRateLimitResetMs(&headers, now));
}

test "parseRateLimitResetMs equal-to-now returns null" {
    const now: i64 = 1_717_000_000_000;
    const headers = [_]HeaderPair{hp("anthropic-ratelimit-unified-reset", "1717000000")};
    try testing.expectEqual(@as(?u64, null), parseRateLimitResetMs(&headers, now));
}

test "parseRateLimitResetMs far future clamps to 6hr cap" {
    const now: i64 = 1_717_000_000_000;
    // reset ~1 year out -> clamped to PERSISTENT_RESET_CAP_MS
    const headers = [_]HeaderPair{hp("anthropic-ratelimit-unified-reset", "1748536000")};
    try testing.expectEqual(@as(?u64, backoff.PERSISTENT_RESET_CAP_MS), parseRateLimitResetMs(&headers, now));
}

test "effectiveDelayMs prefers header over computed fallback" {
    const now: i64 = 1_717_000_000_000;
    const headers = [_]HeaderPair{hp("retry-after", "7")};
    try testing.expectEqual(@as(u64, 7000), effectiveDelayMs(&headers, now, 300));
}

test "effectiveDelayMs reset header beats retry-after when both present" {
    const now: i64 = 1_717_000_000_000;
    const headers = [_]HeaderPair{
        hp("retry-after", "5"),
        hp("anthropic-ratelimit-unified-reset", "1717000020"), // 20s
    };
    // reset (20000) wins over retry-after (5000) and the fallback (300)
    try testing.expectEqual(@as(u64, 20_000), effectiveDelayMs(&headers, now, 300));
}

test "effectiveDelayMs falls back to computed when no timing headers" {
    const now: i64 = 1_717_000_000_000;
    const headers = [_]HeaderPair{hp("content-type", "application/json")};
    try testing.expectEqual(@as(u64, 900), effectiveDelayMs(&headers, now, 900));
}

test "effectiveDelayMs falls back when reset is in the past but retry-after absent" {
    const now: i64 = 1_717_000_000_000;
    const headers = [_]HeaderPair{hp("anthropic-ratelimit-unified-reset", "1716999990")};
    try testing.expectEqual(@as(u64, 450), effectiveDelayMs(&headers, now, 450));
}
