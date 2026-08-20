const std = @import("std");
const rt = @import("zcode_runtime");
const builtin = @import("builtin");
const clock = @import("clock.zig");

/// Prevents the macOS system from sleeping while zcode is working on
/// a long-running turn. Ported from the reference's
/// claude-code-main/src/services/preventSleep.ts.
///
/// Two earlier fixes are preserved here: the original zcode code passed
/// literal `"$$"` as caffeinate's `-w <pid>` argument, assuming shell
/// variable expansion. `std.process.spawn` does NOT run a shell, so
/// caffeinate received the two-character literal "$$", failed to parse
/// it as a number, and exited immediately -- sleep prevention was a
/// silent no-op for every caller. We now format the real parent PID
/// into argv, and pass `-t 300` so a SIGKILL'd parent doesn't leave an
/// orphan caffeinate running forever (the `-w <pid>` tie already makes
/// the child die when the parent dies; `-t 300` is a belt-and-braces
/// self-healing timeout).
///
/// background-svc-07 additions (this pass):
///   - A reference count instead of a bare bool, so nested work
///     sections (e.g. a sub-agent turn inside a parent turn) don't
///     prematurely allow sleep when the inner section finishes.
///   - A 4-minute restart thread: caffeinate's `-t 300` lapses after
///     five minutes, so a turn longer than that would silently lose
///     sleep prevention partway through. The restart thread re-arms
///     caffeinate every four minutes while the ref-count is positive,
///     well before the five-minute timeout fires.
///   - `forceStop`, the cleanup-on-exit hook: zeroes the ref-count and
///     tears everything down regardless of nesting depth.
///
/// The module still no-ops on non-macOS platforms for the caffeinate
/// spawn / restart thread (caffeinate is a macOS-only binary), but the
/// ref-count bookkeeping itself is platform-independent.
pub const SleepGuard = struct {
    /// caffeinate timeout in seconds. The process auto-exits after this
    /// duration; the restart thread re-spawns it before then.
    const CAFFEINATE_TIMEOUT_S = 300; // 5 minutes
    /// Restart interval. Four minutes leaves a one-minute buffer before
    /// the five-minute timeout lapses, matching the reference.
    const RESTART_INTERVAL_NS: u64 = 4 * 60 * std.time.ns_per_s;
    /// Granularity of the restart thread's wait loop. Small ticks keep
    /// teardown responsive: forceStop / the final release don't wait out
    /// a full four-minute sleep, they're noticed within one tick.
    const TICK_NS: u64 = 1 * std.time.ns_per_s; // 1s

    /// All mutable fields below are guarded by `mutex`, except `stop_flag`
    /// which is atomic so the restart thread can observe a teardown
    /// without holding the lock across its sleep.
    mutex: std.Io.Mutex = .init,
    ref_count: usize = 0,
    child: ?std.process.Child = null,
    restart_thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Acquire the sleep lock (increment the ref-count). On the 0 -> 1
    /// transition this spawns caffeinate and starts the restart thread.
    /// Safe to call repeatedly; nested calls just bump the count.
    pub fn acquire(self: *SleepGuard) void {
        self.mutex.lockUncancelable(rt.io);
        defer self.mutex.unlock(rt.io);

        self.ref_count += 1;
        if (self.ref_count == 1) {
            // Fresh acquisition: clear any stale stop signal, spawn the
            // child, and start the restart thread.
            self.stop_flag.store(false, .release);
            self.spawnCaffeinateLocked();
            self.startRestartThreadLocked();
        }
    }

    /// Release the sleep lock (decrement the ref-count). On the ... -> 0
    /// transition this stops the restart thread and kills caffeinate.
    /// Safe to call even if `acquire` was never called.
    pub fn release(self: *SleepGuard) void {
        self.mutex.lockUncancelable(rt.io);

        if (self.ref_count > 0) self.ref_count -= 1;
        if (self.ref_count == 0) {
            self.teardownLocked();
        } else {
            self.mutex.unlock(rt.io);
        }
    }

    /// Force-stop sleep prevention regardless of the ref-count. This is
    /// the cleanup-on-exit hook (see the REPL shutdown path).
    pub fn forceStop(self: *SleepGuard) void {
        self.mutex.lockUncancelable(rt.io);
        self.ref_count = 0;
        self.teardownLocked();
    }

    /// Tear down the restart thread and caffeinate child. Caller must
    /// hold `mutex`; this unlocks it before joining the thread (the
    /// thread itself takes the lock when it wakes) to avoid deadlock.
    fn teardownLocked(self: *SleepGuard) void {
        self.stop_flag.store(true, .release);
        const thread = self.restart_thread;
        self.restart_thread = null;
        self.killCaffeinateLocked();
        // Unlock before joining: the restart thread re-acquires the lock
        // on each tick, so holding it here would deadlock the join.
        self.mutex.unlock(rt.io);
        if (thread) |t| t.join();
    }

    /// Spawn caffeinate. Caller must hold `mutex`. No-op off macOS or if
    /// a child is already running.
    fn spawnCaffeinateLocked(self: *SleepGuard) void {
        if (builtin.os.tag != .macos) return;
        if (self.child != null) return;

        // Format the parent PID so `caffeinate -w <pid>` ties the
        // caffeinate lifetime to ours (orphan-safe).
        var pid_buf: [32]u8 = undefined;
        const my_pid = switch (builtin.os.tag) {
            .linux => @as(i32, @intCast(std.os.linux.getpid())),
            else => std.c.getpid(),
        };
        const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{my_pid}) catch return;

        const child = std.process.spawn(rt.io, .{
            .argv = &.{
                "caffeinate", "-i",
                "-w",         pid_str,
                "-t",         std.fmt.comptimePrint("{d}", .{CAFFEINATE_TIMEOUT_S}),
            },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return;
        self.child = child;
    }

    /// Kill caffeinate. Caller must hold `mutex`. Safe if no child.
    fn killCaffeinateLocked(self: *SleepGuard) void {
        if (self.child) |*child| {
            // kill() reaps the child in 0.16; do not call wait() after.
            child.kill(rt.io);
        }
        self.child = null;
    }

    /// Start the restart thread. Caller must hold `mutex`. No-op off
    /// macOS or if a thread is already running.
    fn startRestartThreadLocked(self: *SleepGuard) void {
        if (builtin.os.tag != .macos) return;
        if (self.restart_thread != null) return;
        self.restart_thread = std.Thread.spawn(.{}, restartLoop, .{self}) catch null;
    }

    /// Restart-thread body. Wakes every TICK_NS to check the stop flag,
    /// and every RESTART_INTERVAL_NS re-arms caffeinate while the
    /// ref-count is positive. Exits promptly once `stop_flag` is set.
    fn restartLoop(self: *SleepGuard) void {
        var elapsed_ns: u64 = 0;
        while (!self.stop_flag.load(.acquire)) {
            clock.sleepNanos(TICK_NS);
            if (self.stop_flag.load(.acquire)) break;
            elapsed_ns += TICK_NS;
            if (elapsed_ns < RESTART_INTERVAL_NS) continue;
            elapsed_ns = 0;

            self.mutex.lockUncancelable(rt.io);
            defer self.mutex.unlock(rt.io);
            // Re-check under the lock; a concurrent teardown may have
            // fired between the flag load and acquiring the lock.
            if (self.stop_flag.load(.acquire)) break;
            if (self.ref_count > 0) {
                self.killCaffeinateLocked();
                self.spawnCaffeinateLocked();
            }
        }
    }
};

/// Global sleep guard instance.
var global_guard: SleepGuard = .{};

/// Prevent system sleep during agent execution.
pub fn preventSleep() void {
    global_guard.acquire();
}

/// Allow system sleep again.
pub fn allowSleep() void {
    global_guard.release();
}

/// Cleanup-on-exit hook: force-stop regardless of ref-count.
pub fn forceStopPreventSleep() void {
    global_guard.forceStop();
}

// -- Tests -----------------------------------------------------------

const testing = std.testing;

test "SleepGuard is inert on non-macOS platforms (no child spawned)" {
    if (builtin.os.tag == .macos) return error.SkipZigTest;
    var guard = SleepGuard{};
    guard.acquire();
    // Ref-count bookkeeping is platform-independent, but no caffeinate
    // child is spawned off macOS.
    try testing.expect(guard.child == null);
    try testing.expect(guard.restart_thread == null);
    guard.release();
    try testing.expectEqual(@as(usize, 0), guard.ref_count);
    try testing.expect(guard.child == null);
}

test "SleepGuard double-acquire increments ref-count; single release keeps it held" {
    var guard = SleepGuard{};
    guard.acquire();
    guard.acquire();
    try testing.expectEqual(@as(usize, 2), guard.ref_count);
    guard.release();
    // One outstanding acquisition remains: still held.
    try testing.expectEqual(@as(usize, 1), guard.ref_count);
    if (builtin.os.tag == .macos) {
        // caffeinate should still be running after a single release.
        try testing.expect(guard.child != null);
    }
    guard.release();
    try testing.expectEqual(@as(usize, 0), guard.ref_count);
}

test "SleepGuard two acquires then two releases tears down" {
    var guard = SleepGuard{};
    guard.acquire();
    guard.acquire();
    guard.release();
    guard.release();
    try testing.expectEqual(@as(usize, 0), guard.ref_count);
    try testing.expect(guard.child == null);
    try testing.expect(guard.restart_thread == null);
}

test "SleepGuard release without acquire is safe" {
    var guard = SleepGuard{};
    guard.release();
    try testing.expectEqual(@as(usize, 0), guard.ref_count);
    try testing.expect(guard.child == null);
}

test "SleepGuard acquire/release cycles leave guard idle" {
    var guard = SleepGuard{};
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        guard.acquire();
        guard.release();
    }
    try testing.expectEqual(@as(usize, 0), guard.ref_count);
    try testing.expect(guard.child == null);
}

test "SleepGuard forceStop zeroes ref-count and signals the restart thread to stop" {
    var guard = SleepGuard{};
    guard.acquire();
    guard.acquire();
    guard.acquire();
    try testing.expectEqual(@as(usize, 3), guard.ref_count);
    guard.forceStop();
    // forceStop ignores the outstanding ref-count and tears down.
    try testing.expectEqual(@as(usize, 0), guard.ref_count);
    try testing.expect(guard.child == null);
    try testing.expect(guard.restart_thread == null);
    // The stop flag was set so any restart thread observed teardown.
    try testing.expect(guard.stop_flag.load(.acquire));
}
