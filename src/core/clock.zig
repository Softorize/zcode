//! Process-wide clock shim. Hides time access behind an internal API so
//! callers don't have to thread std.Io.Timestamp + the io instance through
//! every layer.
//!
//! On Zig 0.16: backed by std.Io.Timestamp via the rt.io singleton.
//! Each public function has a `*Io` variant that accepts io explicitly;
//! the singleton-backed wrapper delegates to it. New code on the
//! explicit-io path can call the `*Io` variants directly.

const std = @import("std");
const rt = @import("zcode_runtime");

/// Wall-clock seconds since the Unix epoch (explicit io variant).
pub fn nowSecondsIo(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

/// Wall-clock milliseconds since the Unix epoch (explicit io variant).
pub fn nowMillisIo(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

/// Wall-clock nanoseconds since the Unix epoch (explicit io variant).
pub fn nowNanosIo(io: std.Io) i128 {
    return @intCast(std.Io.Timestamp.now(io, .real).toNanoseconds());
}

/// Wall-clock seconds since the Unix epoch.
pub fn nowSeconds() i64 {
    return nowSecondsIo(rt.io);
}

/// Wall-clock milliseconds since the Unix epoch.
pub fn nowMillis() i64 {
    return nowMillisIo(rt.io);
}

/// Wall-clock nanoseconds since the Unix epoch.
pub fn nowNanos() i128 {
    return nowNanosIo(rt.io);
}

/// Monotonic timer. Returns elapsed nanoseconds since start.
/// Backed by std.Io.Timestamp on the monotonic clock.
pub const Timer = struct {
    started_at: std.Io.Timestamp,

    pub fn start() error{TimerUnsupported}!Timer {
        return .{ .started_at = std.Io.Timestamp.now(rt.io, .awake) };
    }

    pub fn read(self: *Timer) u64 {
        const now = std.Io.Timestamp.now(rt.io, .awake);
        return @intCast(self.started_at.durationTo(now).nanoseconds);
    }

    pub fn lap(self: *Timer) u64 {
        const now = std.Io.Timestamp.now(rt.io, .awake);
        const elapsed = self.started_at.durationTo(now).nanoseconds;
        self.started_at = now;
        return @intCast(elapsed);
    }

    pub fn reset(self: *Timer) void {
        self.started_at = std.Io.Timestamp.now(rt.io, .awake);
    }
};

/// Sleep for `nanoseconds`. 0.16 dropped std.Thread.sleep and std.posix.nanosleep
/// is gone too; route via libc nanosleep.
pub fn sleepNanos(nanoseconds: u64) void {
    var req: std.c.timespec = .{
        .sec = @intCast(@divFloor(nanoseconds, std.time.ns_per_s)),
        .nsec = @intCast(@mod(nanoseconds, std.time.ns_per_s)),
    };
    _ = std.c.nanosleep(&req, &req);
}
