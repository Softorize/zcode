const std = @import("std");
const rng = @import("../core/rng.zig");
const clock = @import("../core/clock.zig");

/// Circuit breaker for provider resilience.
/// State transitions: closed -> open (after threshold failures) -> half_open (after cooldown) -> closed (on success).
pub const CircuitBreaker = struct {
    state: State,
    failure_count: u32,
    failure_threshold: u32,
    success_count: u32,
    half_open_max_probes: u32,
    cooldown_ns: i128,
    last_failure_ts: i128,

    pub const State = enum { closed, open, half_open };

    pub fn init(failure_threshold: u32, cooldown_seconds: u32) CircuitBreaker {
        return .{
            .state = .closed,
            .failure_count = 0,
            .failure_threshold = failure_threshold,
            .success_count = 0,
            .half_open_max_probes = 2,
            .cooldown_ns = @as(i128, cooldown_seconds) * 1_000_000_000,
            .last_failure_ts = 0,
        };
    }

    /// Returns true if a request should be allowed through.
    pub fn allowRequest(self: *CircuitBreaker) bool {
        switch (self.state) {
            .closed => return true,
            .open => {
                const now = clock.nowNanos();
                const elapsed = now - self.last_failure_ts;
                // A negative elapsed means the wall clock jumped
                // backwards (NTP step, suspend/resume). If we only
                // tested `elapsed >= cooldown_ns` the breaker would
                // stay stuck open forever until the clock caught back
                // up, blocking all provider traffic for the duration
                // of the skew. Treat backwards movement as "cooldown
                // elapsed" so we recover cleanly.
                if (elapsed < 0 or elapsed >= self.cooldown_ns) {
                    self.state = .half_open;
                    self.success_count = 0;
                    self.last_failure_ts = now;
                    return true;
                }
                return false;
            },
            .half_open => return true,
        }
    }

    /// Record a successful request. Transitions half_open -> closed after enough successes.
    pub fn recordSuccess(self: *CircuitBreaker) void {
        switch (self.state) {
            .closed => {
                self.failure_count = 0;
            },
            .half_open => {
                self.success_count += 1;
                if (self.success_count >= self.half_open_max_probes) {
                    self.state = .closed;
                    self.failure_count = 0;
                    self.success_count = 0;
                }
            },
            .open => {},
        }
    }

    /// Record a failed request. Transitions closed -> open after threshold failures.
    pub fn recordFailure(self: *CircuitBreaker) void {
        self.last_failure_ts = clock.nowNanos();
        switch (self.state) {
            .closed => {
                self.failure_count += 1;
                if (self.failure_count >= self.failure_threshold) {
                    self.state = .open;
                }
            },
            .half_open => {
                self.state = .open;
                self.failure_count = self.failure_threshold;
            },
            .open => {},
        }
    }

    /// Returns the current state for metrics/diagnostics.
    pub fn stateValue(self: *const CircuitBreaker) u8 {
        return switch (self.state) {
            .closed => 0,
            .open => 1,
            .half_open => 2,
        };
    }

    /// Short human-readable label for UIs. Stable strings safe to
    /// embed in status lines ("closed", "open", "half-open"). The
    /// caller renders the leading "cb:" prefix so the label can be
    /// reused in other contexts (metrics, /info).
    pub fn stateLabel(self: *const CircuitBreaker) []const u8 {
        return switch (self.state) {
            .closed => "closed",
            .open => "open",
            .half_open => "half-open",
        };
    }
};

/// Compute exponential backoff delay in milliseconds.
/// Formula: min(base_ms * 2^attempt, max_ms) + random_jitter_in_[0, delay/4).
///
/// Real randomized jitter is essential: without it, concurrent clients that
/// all fail at the same instant (e.g. a provider hiccup) retry in lockstep and
/// hammer the provider at every attempt, defeating the point of backoff.
/// The previous implementation always added exactly `delay / 4`, which had
/// zero de-correlating effect. Jitter is drawn from `std.crypto.random`,
/// which is thread-safe.
pub fn backoffDelayMs(attempt: u32, base_ms: u64, max_ms: u64) u64 {
    const shift: u6 = @intCast(@min(attempt, 20));
    // Saturating shift: if base_ms << shift would overflow u64, treat the
    // result as maxInt(u64) so the subsequent `@min` clamps it to max_ms.
    const shifted_res = @shlWithOverflow(base_ms, shift);
    const shifted: u64 = if (shifted_res[1] == 1) std.math.maxInt(u64) else shifted_res[0];
    const delay = @min(shifted, max_ms);
    const jitter_max = delay / 4;
    const jitter: u64 = if (jitter_max == 0) 0 else rng.uintLessThanBiased(u64, jitter_max);
    return delay + jitter;
}

const testing = std.testing;

test "circuit breaker starts closed" {
    var cb = CircuitBreaker.init(3, 30);
    try testing.expect(cb.state == .closed);
    try testing.expect(cb.allowRequest());
}

test "circuit breaker recovers from backwards clock skew" {
    var cb = CircuitBreaker.init(1, 30);
    cb.recordFailure();
    try testing.expect(cb.state == .open);
    // Simulate the wall clock jumping backwards after we opened.
    cb.last_failure_ts = clock.nowNanos() + 60 * std.time.ns_per_s;
    try testing.expect(cb.allowRequest());
    try testing.expect(cb.state == .half_open);
}

test "circuit breaker opens after threshold failures" {
    var cb = CircuitBreaker.init(3, 30);
    cb.recordFailure();
    cb.recordFailure();
    try testing.expect(cb.state == .closed);
    cb.recordFailure();
    try testing.expect(cb.state == .open);
    try testing.expect(!cb.allowRequest());
}

test "circuit breaker success resets failure count" {
    var cb = CircuitBreaker.init(3, 30);
    cb.recordFailure();
    cb.recordFailure();
    cb.recordSuccess();
    try testing.expect(cb.failure_count == 0);
    try testing.expect(cb.state == .closed);
}

test "circuit breaker half_open to closed on successes" {
    var cb = CircuitBreaker.init(3, 0); // 0 second cooldown for test
    cb.recordFailure();
    cb.recordFailure();
    cb.recordFailure();
    try testing.expect(cb.state == .open);
    // After cooldown, should transition to half_open on next request check.
    try testing.expect(cb.allowRequest()); // triggers half_open
    try testing.expect(cb.state == .half_open);
    cb.recordSuccess();
    cb.recordSuccess();
    try testing.expect(cb.state == .closed);
}

test "circuit breaker half_open returns to open on failure" {
    var cb = CircuitBreaker.init(3, 0);
    cb.recordFailure();
    cb.recordFailure();
    cb.recordFailure();
    _ = cb.allowRequest(); // triggers half_open
    try testing.expect(cb.state == .half_open);
    cb.recordFailure();
    try testing.expect(cb.state == .open);
}

test "backoff delay doubles with attempts" {
    // Base delays are 100/200/400; jitter caps at 25/50/100. Min d1 (200) > max d0 (124),
    // and min d2 (400) > max d1 (249), so monotonicity holds despite randomization.
    const d0 = backoffDelayMs(0, 100, 10_000);
    const d1 = backoffDelayMs(1, 100, 10_000);
    const d2 = backoffDelayMs(2, 100, 10_000);
    try testing.expect(d1 > d0);
    try testing.expect(d2 > d1);
}

test "backoff delay caps at max" {
    const d = backoffDelayMs(30, 100, 5_000);
    // Base is clamped to 5000, jitter is in [0, 1250), so result is in [5000, 6250).
    try testing.expect(d >= 5_000);
    try testing.expect(d < 6_250);
}

test "backoff delay jitter is randomized" {
    // Thundering-herd guard: repeated calls at the same attempt must not
    // return identical values. Draw enough samples that a unique-output
    // failure is statistically impossible for a real RNG.
    var seen_unique: usize = 0;
    var last: u64 = backoffDelayMs(3, 100, 30_000);
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const next = backoffDelayMs(3, 100, 30_000);
        if (next != last) seen_unique += 1;
        last = next;
    }
    try testing.expect(seen_unique >= 15);
}

test "state value mapping" {
    var cb = CircuitBreaker.init(1, 0);
    try testing.expect(cb.stateValue() == 0);
    cb.recordFailure();
    try testing.expect(cb.stateValue() == 1);
    _ = cb.allowRequest();
    try testing.expect(cb.stateValue() == 2);
}
