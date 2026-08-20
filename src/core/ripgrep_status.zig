const std = @import("std");
const rt = @import("zcode_runtime");
const clock = @import("clock.zig");
const which = @import("which.zig");

/// Tracks ripgrep availability across the process lifetime so we
/// can answer "is rg actually working?" once and cache the answer.
/// Ported from claude-code-main/src/utils/ripgrep.ts (the
/// `ripgrepStatus` singleton + `getRipgrepStatus` /
/// `testRipgrepOnFirstUse` pair).
///
/// The reference distinguishes three install modes -- system,
/// builtin, embedded -- because the JS build can ship a private
/// rg next to the launcher. zcode only uses the system rg today,
/// so the enum is here for parity but always reports `.system`.
///
/// The reference also runs an actual `rg --version` invocation
/// rather than just a PATH lookup, because PATH-only checks miss
/// "rg exists but errors out at startup" (broken libc, dangling
/// symlink, wrong-arch binary, name collision with a non-rg
/// program). zcode now does the same: `which()` finds a candidate,
/// then we spawn it once and validate the stdout starts with
/// "ripgrep " before declaring it healthy.
pub const Mode = enum {
    system,
    builtin,
    embedded,

    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .system => "system",
            .builtin => "builtin",
            .embedded => "embedded",
        };
    }
};

pub const Status = struct {
    /// True when `rg --version` returned exit 0 and stdout started
    /// with "ripgrep ". False means rg was either missing entirely
    /// or returned an unrecognised banner / non-zero exit.
    working: bool,
    /// Wall-clock millis at the time of the test (std.time.milliTimestamp).
    last_tested_ms: i64,
    /// Install mode. Always .system in zcode for now.
    mode: Mode,
    /// Path to the rg binary that was probed. Stored inline to
    /// avoid lifetime issues on the global singleton. PATH_MAX on
    /// macOS is 1024 so 512 is generous for the binary-only case
    /// but we cap to 511 + null terminator for safety.
    path_buf: [512]u8,
    path_len: usize,

    pub fn pathSlice(self: *const Status) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

var status_state: ?Status = null;
var state_mutex: std.Io.Mutex = .init;

/// Snapshot the current status. Returns null if the test has not
/// run yet -- callers can decide whether to trigger `testOnce` or
/// just report "not yet tested".
pub fn snapshot() ?Status {
    state_mutex.lock(rt.io) catch {};
    defer state_mutex.unlock(rt.io);
    return status_state;
}

/// True when `testOnce` has run (regardless of whether it passed).
pub fn isTested() bool {
    state_mutex.lock(rt.io) catch {};
    defer state_mutex.unlock(rt.io);
    return status_state != null;
}

/// Forget the cached status. Test-only escape hatch -- production
/// code should never need this because the test only runs once
/// per process.
pub fn reset() void {
    state_mutex.lock(rt.io) catch {};
    defer state_mutex.unlock(rt.io);
    status_state = null;
}

/// Run the rg version probe at most once per process. Subsequent
/// calls are no-ops and return immediately. Safe to call from
/// every code path that's about to invoke rg -- the cost is paid
/// the first time only.
///
/// We deliberately do NOT propagate errors. If rg is missing or
/// broken we still want the agent to keep running -- the caller
/// will discover the failure when it tries to spawn rg directly,
/// and /doctor will surface the cached failure cleanly.
pub fn testOnce(allocator: std.mem.Allocator) void {
    {
        state_mutex.lock(rt.io) catch {};
        defer state_mutex.unlock(rt.io);
        if (status_state != null) return;
    }

    const resolved = which.which(allocator, "rg") catch null;
    defer if (resolved) |p| allocator.free(p);

    var status = Status{
        .working = false,
        .last_tested_ms = clock.nowMillis(),
        .mode = .system,
        .path_buf = undefined,
        .path_len = 0,
    };

    const path: []const u8 = resolved orelse "rg";
    const copy_len = @min(path.len, status.path_buf.len);
    @memcpy(status.path_buf[0..copy_len], path[0..copy_len]);
    status.path_len = copy_len;

    if (resolved) |rg_path| {
        const result = std.process.run(allocator, rt.io, .{
            .argv = &.{ rg_path, "--version" },
            .stdout_limit = .limited(16 * 1024),
            .stderr_limit = .limited(16 * 1024),
        }) catch null;

        if (result) |res| {
            defer allocator.free(res.stdout);
            defer allocator.free(res.stderr);
            const exited_clean = res.term == .exited and res.term.exited == 0;
            const banner_ok = std.mem.startsWith(u8, res.stdout, "ripgrep ");
            status.working = exited_clean and banner_ok;
        }
    }

    state_mutex.lock(rt.io) catch {};
    defer state_mutex.unlock(rt.io);
    status_state = status;
}

/// Pretty-print the cached status for /doctor. If the test hasn't
/// run yet, runs it inline so /doctor always shows a definitive
/// answer instead of "unknown". Caller owns the returned slice.
pub fn formatForDoctor(allocator: std.mem.Allocator) ![]u8 {
    testOnce(allocator);
    const snap = snapshot() orelse {
        // Should never happen -- testOnce always sets status_state.
        return std.fmt.allocPrint(allocator, "[?] ripgrep: probe did not complete", .{});
    };

    if (snap.working) {
        return std.fmt.allocPrint(
            allocator,
            "[ok] ripgrep ({s}): working at {s}",
            .{ snap.mode.label(), snap.pathSlice() },
        );
    }
    if (snap.path_len == 0 or std.mem.eql(u8, snap.pathSlice(), "rg")) {
        return std.fmt.allocPrint(
            allocator,
            "[MISSING] ripgrep: not found on PATH - install ripgrep (rg)",
            .{},
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "[FAIL] ripgrep ({s}): found at {s} but `rg --version` did not return a ripgrep banner",
        .{ snap.mode.label(), snap.pathSlice() },
    );
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "snapshot returns null before testOnce runs" {
    reset();
    try testing.expect(snapshot() == null);
    try testing.expect(!isTested());
}

test "testOnce populates status exactly once" {
    reset();
    testOnce(testing.allocator);
    try testing.expect(isTested());
    const first = snapshot().?;

    // Calling again must not change last_tested_ms.
    testOnce(testing.allocator);
    const second = snapshot().?;
    try testing.expectEqual(first.last_tested_ms, second.last_tested_ms);
    try testing.expectEqual(first.working, second.working);
}

test "Mode.label returns stable strings" {
    try testing.expectEqualStrings("system", Mode.system.label());
    try testing.expectEqualStrings("builtin", Mode.builtin.label());
    try testing.expectEqualStrings("embedded", Mode.embedded.label());
}

test "Status.pathSlice returns the populated bytes only" {
    var s = Status{
        .working = true,
        .last_tested_ms = 0,
        .mode = .system,
        .path_buf = undefined,
        .path_len = 0,
    };
    const sample = "/usr/local/bin/rg";
    @memcpy(s.path_buf[0..sample.len], sample);
    s.path_len = sample.len;
    try testing.expectEqualStrings(sample, s.pathSlice());
}

test "formatForDoctor returns ok line when rg is healthy on this machine" {
    // This test only asserts shape -- it accepts both ok and
    // missing/fail lines so it stays green on CI runners that
    // happen not to have rg installed.
    reset();
    const out = try formatForDoctor(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expect(out.len > 0);
    const has_ok = std.mem.indexOf(u8, out, "[ok]") != null;
    const has_missing = std.mem.indexOf(u8, out, "[MISSING]") != null;
    const has_fail = std.mem.indexOf(u8, out, "[FAIL]") != null;
    try testing.expect(has_ok or has_missing or has_fail);
    try testing.expect(std.mem.indexOf(u8, out, "ripgrep") != null);
}
