const std = @import("std");
const clock = @import("clock.zig");

/// Token-bucket rate limiter. NOT thread-safe: the caller must hold a lock
/// or ensure single-threaded access. Current usage in remote_daemon.zig is
/// single-threaded via the accept loop.
pub const RateLimiter = struct {
    tokens: f64,
    max_tokens: f64,
    refill_rate: f64, // tokens per second
    last_refill_ns: i128,

    pub fn init(max_tokens: f64, refill_rate: f64) RateLimiter {
        return .{
            .tokens = max_tokens,
            .max_tokens = max_tokens,
            .refill_rate = refill_rate,
            .last_refill_ns = clock.nowNanos(),
        };
    }

    pub fn tryAcquire(self: *RateLimiter) bool {
        return self.tryAcquireN(1.0);
    }

    pub fn tryAcquireN(self: *RateLimiter, n: f64) bool {
        self.refill();
        if (self.tokens < n) return false;
        self.tokens -= n;
        return true;
    }

    /// Returns the number of seconds to wait before a token is available,
    /// or 0 if tokens are available now.
    pub fn retryAfterSeconds(self: *RateLimiter) u32 {
        self.refill();
        if (self.tokens >= 1.0) return 0;
        const deficit = 1.0 - self.tokens;
        if (!(self.refill_rate > 0.0)) return 60; // catches <=0, NaN, -Inf
        const seconds = deficit / self.refill_rate;
        // Guard against NaN/Inf and out-of-range floats. @intFromFloat is
        // illegal behavior on NaN and on values outside the target type's
        // range, which matters when refill_rate is configured with tiny
        // or malformed values from untrusted config.
        if (std.math.isNan(seconds) or !std.math.isFinite(seconds)) return 60;
        const ceiling = @ceil(seconds);
        if (ceiling <= 0.0) return 0;
        const max_u32: f64 = @floatFromInt(std.math.maxInt(u32));
        if (ceiling >= max_u32) return std.math.maxInt(u32);
        return @intFromFloat(ceiling);
    }

    fn refill(self: *RateLimiter) void {
        const now = clock.nowNanos();
        const elapsed_ns = now - self.last_refill_ns;
        if (elapsed_ns <= 0) return;
        const elapsed_secs: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        const added = elapsed_secs * self.refill_rate;
        self.tokens = @min(self.max_tokens, self.tokens + added);
        self.last_refill_ns = now;
    }
};

/// Per-key rate limiting using a HashMap of RateLimiters.
/// Keys are duped into the map and freed on eviction/deinit.
pub const RateLimiterMap = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(RateLimiter),
    max_tokens: f64,
    refill_rate: f64,
    max_entries: usize,

    pub fn init(allocator: std.mem.Allocator, max_tokens: f64, refill_rate: f64, max_entries: usize) RateLimiterMap {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(RateLimiter).init(allocator),
            .max_tokens = max_tokens,
            .refill_rate = refill_rate,
            .max_entries = max_entries,
        };
    }

    pub fn deinit(self: *RateLimiterMap) void {
        var it = self.map.keyIterator();
        while (it.next()) |key_ptr| {
            self.allocator.free(key_ptr.*);
        }
        self.map.deinit();
    }

    /// Returns true if the request is allowed, false if rate-limited.
    pub fn tryAcquire(self: *RateLimiterMap, key: []const u8) bool {
        if (self.map.getPtr(key)) |limiter| {
            return limiter.tryAcquire();
        }

        // Evict oldest if at capacity.
        if (self.map.count() >= self.max_entries) {
            self.evictOne();
        }

        const duped = self.allocator.dupe(u8, key) catch return false;
        // Construct a fresh limiter at full capacity, then consume one token
        // for this acquisition. Previously we passed `max_tokens - 1.0` to
        // init, which left `max_tokens` set incorrectly (and would go negative
        // if the map was ever configured with max_tokens < 1.0).
        var limiter = RateLimiter.init(self.max_tokens, self.refill_rate);
        _ = limiter.tryAcquire();
        self.map.put(duped, limiter) catch {
            self.allocator.free(duped);
            return false;
        };
        return true;
    }

    pub fn retryAfterSeconds(self: *RateLimiterMap, key: []const u8) u32 {
        if (self.map.getPtr(key)) |limiter| {
            return limiter.retryAfterSeconds();
        }
        return 0;
    }

    /// Evict the least-recently-active limiter. The previous version
    /// took whichever key happened to come first in HashMap iteration
    /// order, which for std.StringHashMap is hash-derived (effectively
    /// arbitrary). Under a flood from many distinct IPs that policy
    /// could repeatedly evict honest, just-arrived users while the
    /// attacker's rotating IPs got fresh full-token buckets every
    /// time -- a complete bypass of the rate limiter. LRU on
    /// `last_refill_ns` is the right policy: the bucket that has not
    /// been touched the longest is the one most likely to be idle
    /// and least likely to be a legit user mid-session.
    fn evictOne(self: *RateLimiterMap) void {
        var it = self.map.iterator();
        var oldest_key: ?[]const u8 = null;
        var oldest_ts: i128 = std.math.maxInt(i128);
        while (it.next()) |entry| {
            const ts = entry.value_ptr.last_refill_ns;
            if (ts < oldest_ts) {
                oldest_ts = ts;
                oldest_key = entry.key_ptr.*;
            }
        }
        if (oldest_key) |key| {
            _ = self.map.remove(key);
            self.allocator.free(key);
        }
    }
};

const testing = std.testing;

test "basic rate limiter acquire and exhaust" {
    var limiter = RateLimiter.init(3.0, 1.0);
    try testing.expect(limiter.tryAcquire());
    try testing.expect(limiter.tryAcquire());
    try testing.expect(limiter.tryAcquire());
    try testing.expect(!limiter.tryAcquire());
}

test "rate limiter retryAfterSeconds" {
    var limiter = RateLimiter.init(1.0, 1.0);
    try testing.expect(limiter.tryAcquire());
    const retry = limiter.retryAfterSeconds();
    try testing.expect(retry >= 1);
}

test "rate limiter map per-key isolation" {
    var map = RateLimiterMap.init(testing.allocator, 2.0, 1.0, 100);
    defer map.deinit();

    try testing.expect(map.tryAcquire("ip-a"));
    try testing.expect(map.tryAcquire("ip-a"));
    // ip-a starts with max-1 since first acquire already consumed one.
    // ip-b is independent.
    try testing.expect(map.tryAcquire("ip-b"));
}

test "rate limiter map eviction at capacity" {
    var map = RateLimiterMap.init(testing.allocator, 5.0, 1.0, 2);
    defer map.deinit();

    try testing.expect(map.tryAcquire("ip-1"));
    try testing.expect(map.tryAcquire("ip-2"));
    // Third key triggers eviction of ip-1.
    try testing.expect(map.tryAcquire("ip-3"));
    try testing.expect(map.map.count() <= 2);
}

test "rate limiter map eviction picks least-recently-active key" {
    // Capacity 2: insert ip-A, then ip-B. After waiting a bit we touch
    // ip-A again to refresh its last_refill_ns, then insert ip-C. With
    // an LRU policy ip-B (older last_refill_ns) must be evicted, NOT
    // ip-A which was just used. The previous arbitrary-iteration
    // policy could evict either one and let an attacker rotating IPs
    // bypass the limiter by displacing legitimate active users.
    var map = RateLimiterMap.init(testing.allocator, 5.0, 1.0, 2);
    defer map.deinit();

    try testing.expect(map.tryAcquire("ip-A"));
    // Force a measurable last_refill_ns gap so the LRU comparison is
    // deterministic regardless of clock granularity.
    clock.sleepNanos(2 * std.time.ns_per_ms);
    try testing.expect(map.tryAcquire("ip-B"));
    clock.sleepNanos(2 * std.time.ns_per_ms);
    // Refresh ip-A's last_refill_ns so it becomes more recent than ip-B.
    try testing.expect(map.tryAcquire("ip-A"));
    clock.sleepNanos(2 * std.time.ns_per_ms);
    // Inserting ip-C must evict ip-B (oldest), not ip-A (just touched).
    try testing.expect(map.tryAcquire("ip-C"));
    try testing.expect(map.map.contains("ip-A"));
    try testing.expect(!map.map.contains("ip-B"));
    try testing.expect(map.map.contains("ip-C"));
}
