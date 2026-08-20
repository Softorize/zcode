//! KAIROS coordination primitives — two file-based, per-project (cwd-scoped)
//! locks that let an interactive REPL and the always-on KAIROS background agent
//! coexist without double-firing the shared cron store.
//!
//!   1. Presence heartbeat (`presence`): the interactive REPL refreshes this
//!      each loop. KAIROS reads it to know whether a human is at the keyboard.
//!   2. Cron-ownership lock (`cron.lock`): a single-owner lock deciding who
//!      fires cron at any moment — an active REPL, or KAIROS when no REPL is
//!      present.
//!
//! Both live under `~/.zcode/kairos/<project-key>/`. Every public function is
//! best-effort: on any error it returns false / void without panicking, mirroring
//! the discipline in `core/dream.zig`.
//!
//! The exclusive-create lock idiom and the OS-PID liveness check are copied from
//! `core/dream.zig` so the two locks behave identically (and so stale-lock
//! cleanup actually works against real PIDs, not internal thread ids).

const std = @import("std");
const rt = @import("zcode_runtime");
const clock = @import("clock.zig");
const paths = @import("paths.zig");

/// Who owns (or is asking to own) the cron-ownership lock.
pub const Role = enum { repl, kairos };

/// A presence heartbeat older than this many seconds is treated as stale, i.e.
/// the REPL is considered gone even if it never got to clear its file.
pub const PRESENCE_FRESH_SECS: i64 = 15;

/// Cap on lock/presence file reads. These files are a handful of bytes; this is
/// just a sanity bound so a corrupt/huge file can't blow up the read.
const MAX_FILE_BYTES: usize = 4 * 1024;

const PRESENCE_FILE = "presence";
const CRON_LOCK_FILE = "cron.lock";

// ===========================================================================
// Presence heartbeat
// ===========================================================================

/// Write/refresh the presence heartbeat for `cwd`. Best-effort: any failure is
/// swallowed. Content is "<pid>\n<unix_seconds>".
pub fn heartbeat(allocator: std.mem.Allocator, cwd: []const u8) void {
    const path = presencePath(allocator, cwd) catch return;
    defer allocator.free(path);

    const file = std.Io.Dir.cwd().createFile(rt.io, path, .{ .truncate = true }) catch return;
    defer file.close(rt.io);

    var buf: [48]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{d}\n{d}", .{ getpid(), clock.nowSeconds() }) catch return;
    file.writeStreamingAll(rt.io, body) catch return;
}

/// True if a presence heartbeat exists, its writer PID is alive, and its
/// timestamp is within `PRESENCE_FRESH_SECS` of now. Any error => false.
pub fn isPresent(allocator: std.mem.Allocator, cwd: []const u8) bool {
    const path = presencePath(allocator, cwd) catch return false;
    defer allocator.free(path);

    const content = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(MAX_FILE_BYTES)) catch return false;
    defer allocator.free(content);

    const parsed = parsePresenceBody(content) orelse return false;
    if (!pidAlive(parsed.pid)) return false;
    return isFresh(clock.nowSeconds(), parsed.ts);
}

/// Delete the presence heartbeat (called on REPL exit). Best-effort.
pub fn clearPresence(allocator: std.mem.Allocator, cwd: []const u8) void {
    const path = presencePath(allocator, cwd) catch return;
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(rt.io, path) catch {};
}

// ===========================================================================
// Cron-ownership lock
// ===========================================================================

/// Try to take the cron-ownership lock for `cwd` as `role`. Uses an exclusive
/// create so the kernel enforces single ownership. If the lock is already held
/// but its owner PID is dead, the stale lock is stolen (deleted) and the
/// exclusive create is retried exactly once. Returns true on ownership.
pub fn acquireCronLock(allocator: std.mem.Allocator, cwd: []const u8, role: Role) bool {
    const path = cronLockPath(allocator, cwd) catch return false;
    defer allocator.free(path);

    if (tryCreateLock(path, role)) return true;

    // Exclusive create failed — either the path exists (held) or some other
    // error. Only attempt a steal when the existing owner is provably dead.
    const content = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(MAX_FILE_BYTES)) catch return false;
    defer allocator.free(content);

    const parsed = parseLockBody(content) orelse return false;
    if (pidAlive(parsed.pid)) return false; // live owner, do not steal

    std.Io.Dir.cwd().deleteFile(rt.io, path) catch return false;
    return tryCreateLock(path, role);
}

/// Release the cron-ownership lock for `cwd`. Best-effort.
pub fn releaseCronLock(allocator: std.mem.Allocator, cwd: []const u8) void {
    const path = cronLockPath(allocator, cwd) catch return;
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(rt.io, path) catch {};
}

/// True if a *live* owner currently holds the cron-ownership lock for `cwd`.
/// A held-but-dead (stale) lock returns false. Any error => false.
pub fn cronLockHeld(allocator: std.mem.Allocator, cwd: []const u8) bool {
    const path = cronLockPath(allocator, cwd) catch return false;
    defer allocator.free(path);

    const content = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(MAX_FILE_BYTES)) catch return false;
    defer allocator.free(content);

    const parsed = parseLockBody(content) orelse return false;
    return pidAlive(parsed.pid);
}

// ===========================================================================
// Private helpers — disk
// ===========================================================================

/// Exclusive-create the lock file and write "<role>\n<pid>\n<unix_seconds>".
/// Returns true only when this call created the file. PathAlreadyExists (held)
/// and any other error return false.
fn tryCreateLock(path: []const u8, role: Role) bool {
    const file = std.Io.Dir.cwd().createFile(rt.io, path, .{
        .truncate = true,
        .exclusive = true,
    }) catch return false;
    defer file.close(rt.io);

    var buf: [64]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{s}\n{d}\n{d}", .{
        @tagName(role),
        getpid(),
        clock.nowSeconds(),
    }) catch return false;
    file.writeStreamingAll(rt.io, body) catch return false;
    return true;
}

/// Derive a filesystem-safe per-project key from an absolute `cwd` by replacing
/// path separators with '-' (e.g. "/Users/example/Projects/zig-code" =>
/// "-Users-Toto-Projects-zig-code"), matching the encoding zcode already uses for
/// the per-project memory dir. Empty cwd falls back to "default". Owned result.
pub fn projectKey(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    if (cwd.len == 0) return allocator.dupe(u8, "default");
    const key = try allocator.dupe(u8, cwd);
    for (key) |*c| {
        switch (c.*) {
            '/', '\\', ':', ' ' => c.* = '-',
            else => {},
        }
    }
    return key;
}

/// Per-project KAIROS dir: `<~/.zcode>/kairos/<project-key>`. Ensures every
/// level exists and returns an owned absolute path. Shared by the other KAIROS
/// modules so they all resolve the same per-project location.
pub fn projectDir(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    var path_set = try paths.resolve(allocator);
    defer path_set.deinit(allocator);

    // dirname(user_config_path) == ~/.zcode (the zcode home).
    const zcode_home = std.fs.path.dirname(path_set.user_config_path) orelse return error.NoZcodeHome;

    const kairos_root = try std.fs.path.join(allocator, &.{ zcode_home, "kairos" });
    defer allocator.free(kairos_root);
    try paths.ensureDir(kairos_root);

    const key = try projectKey(allocator, cwd);
    defer allocator.free(key);

    const dir = try std.fs.path.join(allocator, &.{ kairos_root, key });
    errdefer allocator.free(dir);
    try paths.ensureDir(dir);
    return dir;
}

fn presencePath(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const dir = try projectDir(allocator, cwd);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, PRESENCE_FILE });
}

fn cronLockPath(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const dir = try projectDir(allocator, cwd);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, CRON_LOCK_FILE });
}

// ===========================================================================
// Private helpers — pure (unit-tested without disk)
// ===========================================================================

const LockBody = struct { role: Role, pid: i32, ts: i64 };
const PresenceBody = struct { pid: i32, ts: i64 };

/// Parse a cron-lock file body: "<role>\n<pid>\n<unix_seconds>".
/// Returns null on any malformed input. Trailing whitespace/newlines tolerated.
fn parseLockBody(bytes: []const u8) ?LockBody {
    var it = std.mem.splitScalar(u8, bytes, '\n');
    const role_s = trim(it.next() orelse return null);
    const pid_s = trim(it.next() orelse return null);
    const ts_s = trim(it.next() orelse return null);

    const role: Role = if (std.mem.eql(u8, role_s, "repl"))
        .repl
    else if (std.mem.eql(u8, role_s, "kairos"))
        .kairos
    else
        return null;

    const pid = std.fmt.parseInt(i32, pid_s, 10) catch return null;
    const ts = std.fmt.parseInt(i64, ts_s, 10) catch return null;
    return .{ .role = role, .pid = pid, .ts = ts };
}

/// Parse a presence file body: "<pid>\n<unix_seconds>".
/// Returns null on any malformed input.
fn parsePresenceBody(bytes: []const u8) ?PresenceBody {
    var it = std.mem.splitScalar(u8, bytes, '\n');
    const pid_s = trim(it.next() orelse return null);
    const ts_s = trim(it.next() orelse return null);

    const pid = std.fmt.parseInt(i32, pid_s, 10) catch return null;
    const ts = std.fmt.parseInt(i64, ts_s, 10) catch return null;
    return .{ .pid = pid, .ts = ts };
}

/// True if a heartbeat written at `ts_written` is still fresh relative to
/// `ts_now` (within PRESENCE_FRESH_SECS). A future-dated timestamp (clock skew)
/// counts as fresh.
fn isFresh(ts_now: i64, ts_written: i64) bool {
    const age = ts_now - ts_written;
    if (age < 0) return true;
    return age <= PRESENCE_FRESH_SECS;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// Real OS PID (mirrors dream.zig's getpid switch).
fn getpid() i32 {
    return switch (@import("builtin").os.tag) {
        .linux => std.os.linux.getpid(),
        else => std.c.getpid(),
    };
}

/// PID liveness via `kill(pid, 0)`: signal 0 posts nothing but tells us whether
/// the process exists. Returns true only when the syscall reports success (0);
/// any error/nonzero is treated as dead, per spec.
fn pidAlive(pid: i32) bool {
    const pid_t: std.posix.pid_t = @intCast(pid);
    return switch (@import("builtin").os.tag) {
        .linux => std.os.linux.kill(pid_t, @enumFromInt(0)) == 0,
        else => std.c.kill(pid_t, @enumFromInt(0)) == 0,
    };
}

// ===========================================================================
// Tests (pure helpers only — no disk IO)
// ===========================================================================

const testing = std.testing;

test "parseLockBody parses role, pid, ts" {
    const got = parseLockBody("repl\n4242\n1700000000") orelse return error.TestExpectedSome;
    try testing.expectEqual(Role.repl, got.role);
    try testing.expectEqual(@as(i32, 4242), got.pid);
    try testing.expectEqual(@as(i64, 1700000000), got.ts);

    const k = parseLockBody("kairos\n7\n10") orelse return error.TestExpectedSome;
    try testing.expectEqual(Role.kairos, k.role);
}

test "parseLockBody tolerates trailing newline/whitespace" {
    const got = parseLockBody("kairos\n99\n12345\n") orelse return error.TestExpectedSome;
    try testing.expectEqual(Role.kairos, got.role);
    try testing.expectEqual(@as(i32, 99), got.pid);
    try testing.expectEqual(@as(i64, 12345), got.ts);
}

test "parseLockBody rejects malformed input" {
    try testing.expect(parseLockBody("") == null);
    try testing.expect(parseLockBody("repl") == null); // missing fields
    try testing.expect(parseLockBody("repl\nabc\n100") == null); // bad pid
    try testing.expect(parseLockBody("bogus\n1\n2") == null); // bad role
    try testing.expect(parseLockBody("repl\n1\nxyz") == null); // bad ts
}

test "parsePresenceBody parses pid and ts" {
    const got = parsePresenceBody("31337\n1699999999") orelse return error.TestExpectedSome;
    try testing.expectEqual(@as(i32, 31337), got.pid);
    try testing.expectEqual(@as(i64, 1699999999), got.ts);
}

test "parsePresenceBody rejects malformed input" {
    try testing.expect(parsePresenceBody("") == null);
    try testing.expect(parsePresenceBody("123") == null); // missing ts
    try testing.expect(parsePresenceBody("abc\n100") == null); // bad pid
}

test "projectKey sanitizes path separators" {
    const k = try projectKey(testing.allocator, "/Users/example/Projects/zig-code");
    defer testing.allocator.free(k);
    try testing.expectEqualStrings("-Users-example-Projects-zig-code", k);

    const d = try projectKey(testing.allocator, "");
    defer testing.allocator.free(d);
    try testing.expectEqualStrings("default", d);
}

test "isFresh respects PRESENCE_FRESH_SECS window" {
    const now: i64 = 1_000_000;
    try testing.expect(isFresh(now, now)); // same instant
    try testing.expect(isFresh(now, now - PRESENCE_FRESH_SECS)); // exactly at edge
    try testing.expect(!isFresh(now, now - PRESENCE_FRESH_SECS - 1)); // just stale
    try testing.expect(isFresh(now, now + 5)); // clock skew (future) counts fresh
}
