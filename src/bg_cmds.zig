//! Detached background-session surface (phase-26 daemon-background-01/09/10).
//!
//! `zcode ps` renders the cross-session live-process registry
//! (`core/session_registry.zig`); `zcode kill <id|pid>` SIGTERMs a registered
//! session and removes its registry file; `zcode logs <id|pid>` dumps a
//! `--bg` session's captured output; and `spawnBackground` re-invokes zcode
//! detached for `--bg`, redirecting the child's stdout/stderr to a per-session
//! log file recorded in the registry.
//!
//! Mirrors the reference `cli/bg.js` (psHandler / killHandler / logsHandler)
//! dispatched from `entrypoints/cli.tsx`. Every registry-sourced string
//! (name, cwd, waiting_for) is sanitized via `core/display_safe.sanitize`
//! before terminal output - a hostile registry file must not smuggle ANSI,
//! matching the `cmdSessionList` / daemon-status hardening.

const std = @import("std");
const rt = @import("zcode_runtime");
const clock = @import("core/clock.zig");
const std_io = @import("core/std_io.zig");
const env = @import("core/env.zig");
const display_safe = @import("core/display_safe.zig");
const format_mod = @import("core/format.zig");
const paths = @import("core/paths.zig");
const registry = @import("core/session_registry.zig");

// ===========================================================================
// ps
// ===========================================================================

/// Render the live-process registry as a TSV-ish table. Sanitizes every
/// untrusted string before printing. Empty -> "no live sessions".
pub fn cmdPs(allocator: std.mem.Allocator, writer: anytype) !void {
    const entries = try registry.list(allocator);
    defer registry.freeEntries(allocator, entries);

    if (entries.len == 0) {
        try writer.writeAll("no live sessions\n");
        return;
    }

    const now_ts: i64 = clock.nowSeconds();
    for (entries) |entry| {
        var rel_buf: [32]u8 = undefined;
        const rel = format_mod.formatRelativeTimeShort(&rel_buf, entry.started_ts, now_ts);

        // Sanitize untrusted registry strings (a hostile registry file could
        // smuggle ANSI/newlines that corrupt the row layout).
        const safe_cwd = try display_safe.sanitize(allocator, entry.cwd);
        defer allocator.free(safe_cwd);

        var name_owned: ?[]u8 = null;
        defer if (name_owned) |n| allocator.free(n);
        const name: []const u8 = if (entry.name) |n| blk: {
            name_owned = try display_safe.sanitize(allocator, n);
            break :blk name_owned.?;
        } else "-";

        try writer.print("pid={d}\tkind={s}\tstatus={s}\tname={s}\tcwd={s}", .{
            entry.pid,
            entry.kind.toString(),
            entry.status.toString(),
            name,
            safe_cwd,
        });

        if (entry.waiting_for) |w| {
            const safe_w = try display_safe.sanitize(allocator, w);
            defer allocator.free(safe_w);
            try writer.print("\twaiting={s}", .{safe_w});
        }

        if (rel.len > 0) {
            try writer.print("\tstarted={s}", .{rel});
        }
        try writer.writeAll("\n");
    }
}

// ===========================================================================
// kill
// ===========================================================================

/// Resolve `subject` (a numeric pid or a session_id) to a registry entry,
/// SIGTERM the pid, and delete the registry file. Prints `killed pid=<n>` on
/// success or `no such session: <subject>` when nothing matches.
pub fn cmdKill(allocator: std.mem.Allocator, subject: []const u8, writer: anytype) !void {
    const pid = (try resolvePid(allocator, subject)) orelse {
        try writer.print("no such session: {s}\n", .{subject});
        return;
    };

    // Raw signal to a foreign pid: there is no Child to wait()/reap, so just
    // SIGTERM and probe with isPidRunning. (Child.kill reaps internally and
    // would assert here - we deliberately do not use it.)
    std.posix.kill(pid, std.posix.SIG.TERM) catch {};

    deleteEntryFile(allocator, pid);
    try writer.print("killed pid={d}\n", .{pid});
}

// ===========================================================================
// logs
// ===========================================================================

/// Maximum bytes of a session log to dump (tail). 64 KiB matches the
/// registry's own read cap and keeps a runaway log from blowing memory.
const LOG_TAIL_MAX: usize = 64 * 1024;

/// Resolve `subject` to a registry entry, then dump its captured log (last
/// LOG_TAIL_MAX bytes). Prints a clear message when the session or its log is
/// absent.
pub fn cmdLogs(allocator: std.mem.Allocator, subject: []const u8, writer: anytype) !void {
    const pid = (try resolvePid(allocator, subject)) orelse {
        try writer.print("no such session: {s}\n", .{subject});
        return;
    };

    const entry = (try registry.read(allocator, pid)) orelse {
        try writer.print("no such session: {s}\n", .{subject});
        return;
    };
    defer entry.deinit(allocator);

    const log_path = entry.log_path orelse {
        try writer.print("no log for session {s}\n", .{subject});
        return;
    };

    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, log_path, allocator, .limited(LOG_TAIL_MAX)) catch |err| switch (err) {
        error.FileNotFound => {
            try writer.print("no log for session {s}\n", .{subject});
            return;
        },
        // 0.16: an over-limit read yields StreamTooLong, not FileTooBig. Fall
        // back to a bounded tail so a large log still shows its end.
        error.StreamTooLong => {
            const tail = try readTail(allocator, log_path, LOG_TAIL_MAX);
            defer allocator.free(tail);
            try writer.writeAll(tail);
            return;
        },
        else => return err,
    };
    defer allocator.free(bytes);
    try writer.writeAll(bytes);
}

/// Read the last `max` bytes of a file (for a log too large to slurp whole).
fn readTail(allocator: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(rt.io, path, .{});
    defer file.close(rt.io);
    const st = try file.stat(rt.io);
    const end = st.size;
    const want: u64 = @min(@as(u64, max), end);
    const offset = end - want;
    const buf = try allocator.alloc(u8, @intCast(want));
    errdefer allocator.free(buf);
    const n = try file.readPositionalAll(rt.io, buf, offset);
    return allocator.realloc(buf, n);
}

// ===========================================================================
// --bg spawn
// ===========================================================================

/// Spawn the current run detached for `--bg`. Strips `--bg`/`--background`
/// from the re-invocation argv, redirects the child's stdout/stderr to a
/// per-session log file, sets ZCODE_SESSION_KIND=bg + ZCODE_SESSION_LOG in the
/// child env (so the child self-registers with the right kind + log path),
/// and prints the spawned pid plus `zcode logs`/`zcode kill` hints. The parent
/// returns without entering the REPL.
///
/// `orig_argv` is the process argv (rt.argv); `cwd` is the working dir.
pub fn spawnBackground(allocator: std.mem.Allocator, orig_argv: []const []const u8, cwd: []const u8, writer: anytype) !void {
    // Per-session id for the log filename. argv[0] is the exe path; the child
    // re-discovers its own pid for the registry key, so a timestamp id is
    // enough to keep concurrent --bg launches from colliding on the log file.
    const log_id = clock.nowNanos();

    const log_dir = try logsDir(allocator);
    defer allocator.free(log_dir);
    try paths.ensureDir(log_dir);

    const log_path = try std.fmt.allocPrint(allocator, "{s}/{d}.log", .{ log_dir, log_id });
    defer allocator.free(log_path);

    // Open the log file the child will own. The parent closes its copy right
    // after spawn so the descriptor lifetime belongs to the child.
    const log_file = try std.Io.Dir.cwd().createFile(rt.io, log_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });

    // Build the child env from the parent's, adding the self-registration
    // signals. environ_map REPLACES the child env, so we must clone the parent
    // env (PATH, provider keys, etc.) rather than passing only the extras.
    var env_map = try env.parentEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put("ZCODE_SESSION_KIND", "bg");
    try env_map.put("ZCODE_SESSION_LOG", log_path);

    // Re-invocation argv: same args minus --bg/--background, with argv[0]
    // rewritten to the resolved exe path (orig_argv[0] may be a bare name).
    const exe = try std.process.executablePathAlloc(rt.io, allocator);
    defer allocator.free(exe);

    // gap-11: forward the -n/--name value into the child env as
    // ZCODE_SESSION_NAME so the detached child self-names in the registry
    // (the value also stays in argv, but the env mirror matches the kind/log
    // self-registration pattern). Captured from argv since spawnBackground
    // takes the raw process argv. Supports `-n foo`, `--name foo`, `--name=foo`.
    var session_name: ?[]const u8 = null;
    var child_argv: std.ArrayList([]const u8) = .empty;
    defer child_argv.deinit(allocator);
    try child_argv.append(allocator, exe);
    {
        const tail = orig_argv[@min(1, orig_argv.len)..];
        var ai: usize = 0;
        while (ai < tail.len) : (ai += 1) {
            const a = tail[ai];
            if (std.mem.eql(u8, a, "--bg") or std.mem.eql(u8, a, "--background")) continue;
            if (std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "--name")) {
                if (ai + 1 < tail.len) session_name = tail[ai + 1];
            } else if (std.mem.startsWith(u8, a, "--name=")) {
                session_name = a["--name=".len..];
            }
            try child_argv.append(allocator, a);
        }
    }
    if (session_name) |n| {
        if (n.len > 0) try env_map.put("ZCODE_SESSION_NAME", n);
    }

    const child = std.process.spawn(rt.io, .{
        .argv = child_argv.items,
        .cwd = .{ .path = cwd },
        .environ_map = &env_map,
        .stdin = .ignore,
        .stdout = .{ .file = log_file },
        .stderr = .{ .file = log_file },
    }) catch |err| {
        log_file.close(rt.io);
        return err;
    };
    // The child now owns the log fd; drop the parent's copy.
    log_file.close(rt.io);

    const pid: i32 = @intCast(child.id orelse 0);
    try writer.print(
        "started background session\tpid={d}\n  zcode logs {d}   # view captured output\n  zcode kill {d}   # terminate it\n",
        .{ pid, pid, pid },
    );
}

// ===========================================================================
// Helpers
// ===========================================================================

/// Resolve a `kill`/`logs` subject to a pid. A bare-numeric subject is taken
/// as a pid directly (and must be a live registry entry); otherwise it is
/// matched against registered session_ids. Returns null when nothing matches.
fn resolvePid(allocator: std.mem.Allocator, subject: []const u8) !?i32 {
    if (parsePid(subject)) |pid| {
        // A direct pid only resolves when it is actually a registered session,
        // so `kill 1` cannot SIGTERM an arbitrary unrelated process.
        const entry = (try registry.read(allocator, pid)) orelse return null;
        entry.deinit(allocator);
        return pid;
    }

    const entries = try registry.list(allocator);
    defer registry.freeEntries(allocator, entries);
    for (entries) |entry| {
        if (entry.session_id) |sid| {
            if (std.mem.eql(u8, sid, subject)) return entry.pid;
        }
    }
    return null;
}

fn parsePid(s: []const u8) ?i32 {
    if (s.len == 0) return null;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
    }
    return std.fmt.parseInt(i32, s, 10) catch null;
}

/// Delete a registry file for a known pid (best-effort; ENOENT swallowed).
fn deleteEntryFile(allocator: std.mem.Allocator, pid: i32) void {
    const dir = registry.registryDir(allocator) catch return;
    defer allocator.free(dir);
    const path = std.fmt.allocPrint(allocator, "{s}/{d}.json", .{ dir, pid }) catch return;
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(rt.io, path) catch {};
}

/// Absolute path to the per-session log directory. Honors ZCODE_SESSIONS_DIR
/// (the same test/override hook the registry uses) so a test can point both
/// the registry and the logs at one tmp dir.
fn logsDir(allocator: std.mem.Allocator) ![]u8 {
    if (env.getOwned(allocator, "ZCODE_SESSIONS_DIR")) |override| {
        defer allocator.free(override);
        if (override.len > 0) return std.fs.path.join(allocator, &.{ override, "logs" });
    } else |_| {}

    var ps = try paths.resolve(allocator);
    defer ps.deinit(allocator);
    return std.fs.path.join(allocator, &.{ ps.sessions_dir, "logs" });
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;
const test_helpers = @import("core/test_helpers.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn setRegistryRoot(root_z: [*:0]const u8) void {
    _ = setenv("ZCODE_SESSIONS_DIR", root_z, 1);
}

fn clearRegistryRoot() void {
    _ = unsetenv("ZCODE_SESSIONS_DIR");
}

/// Hand-write a registry file for an arbitrary pid (so a test can fabricate a
/// second, live entry without actually spawning a second zcode). Mirrors the
/// JSON shape session_registry.writeEntry emits.
fn writeRawEntry(
    allocator: std.mem.Allocator,
    root: []const u8,
    pid: i32,
    kind: []const u8,
    name: ?[]const u8,
    log_path: ?[]const u8,
) !void {
    const dir = try std.fs.path.join(allocator, &.{ root, "registry" });
    defer allocator.free(dir);
    try paths.ensureDir(dir);

    const path = try std.fmt.allocPrint(allocator, "{s}/{d}.json", .{ dir, pid });
    defer allocator.free(path);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const now = clock.nowSeconds();
    try out.writer().print(
        "{{\"pid\":{d},\"cwd\":\"/work\",\"started_ts\":{d},\"updated_ts\":{d},\"kind\":\"{s}\"",
        .{ pid, now, now, kind },
    );
    // Use std.json.fmt for string values so a hostile name carrying control
    // bytes (e.g. a raw ESC) is properly escaped and stays valid JSON.
    if (name) |n| try out.writer().print(",\"name\":{f}", .{std.json.fmt(n, .{})});
    if (log_path) |lp| try out.writer().print(",\"log_path\":{f}", .{std.json.fmt(lp, .{})});
    try out.writer().writeAll("}\n");

    const file = try std.Io.Dir.cwd().createFile(rt.io, path, .{ .truncate = true });
    defer file.close(rt.io);
    try file.writeStreamingAll(rt.io, out.items());
}

test "cmdPs lists registered pids, the kind column, and sanitizes a hostile name" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);
    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);
    setRegistryRoot(root_z);
    defer clearRegistryRoot();

    // Our own (live) pid, plus a second live entry reusing our own pid value
    // for a different filename is impossible, so fabricate a second live entry
    // by reusing the current pid under a name that carries an ANSI escape.
    const me = registry.currentPid();
    try writeRawEntry(alloc, root, me, "bg", "a\x1b[31mb", null);

    var out = std_io.StringBuilder.init(alloc);
    defer out.deinit();
    try cmdPs(alloc, out.writer());
    const rendered = out.items();

    // The pid and kind column are present.
    var pid_buf: [16]u8 = undefined;
    const pid_str = try std.fmt.bufPrint(&pid_buf, "pid={d}", .{me});
    try testing.expect(std.mem.indexOf(u8, rendered, pid_str) != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "kind=bg") != null);

    // The raw ESC byte must NOT appear (display_safe neutralized it).
    try testing.expect(std.mem.indexOfScalar(u8, rendered, 0x1b) == null);
}

test "cmdPs prints 'no live sessions' on an empty registry" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);
    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);
    setRegistryRoot(root_z);
    defer clearRegistryRoot();

    var out = std_io.StringBuilder.init(alloc);
    defer out.deinit();
    try cmdPs(alloc, out.writer());
    try testing.expectEqualStrings("no live sessions\n", out.items());
}

test "cmdKill SIGTERMs a spawned child and removes its registry file" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);
    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);
    setRegistryRoot(root_z);
    defer clearRegistryRoot();

    // Spawn a long-lived child we can safely kill (sleep). Skip the test if
    // the helper binary is unavailable on this platform.
    var child = std.process.spawn(rt.io, .{
        .argv = &.{ "sleep", "30" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SkipZigTest;
    const pid: i32 = @intCast(child.id orelse return error.SkipZigTest);

    // Fabricate a registry entry for the child pid.
    try writeRawEntry(alloc, root, pid, "bg", "victim", null);

    const dir = try registry.registryDir(alloc);
    defer alloc.free(dir);
    const file_path = try std.fmt.allocPrint(alloc, "{s}/{d}.json", .{ dir, pid });
    defer alloc.free(file_path);
    try testing.expect(fileExists(file_path));

    var pid_str_buf: [16]u8 = undefined;
    const pid_str = try std.fmt.bufPrint(&pid_str_buf, "{d}", .{pid});

    var out = std_io.StringBuilder.init(alloc);
    defer out.deinit();
    try cmdKill(alloc, pid_str, out.writer());

    // The registry file is gone.
    try testing.expect(!fileExists(file_path));
    try testing.expect(std.mem.indexOf(u8, out.items(), "killed pid=") != null);

    // The process is terminated by the SIGTERM cmdKill sent. We reap it here
    // (cmdKill itself never wait()s a foreign pid - there is no Child to reap;
    // the test owns this Child so it must reap to avoid a lingering zombie,
    // and a reaped pid lets isPidRunning observe it as gone). wait() blocks
    // until the already-signaled child exits, so no sleep/poll is needed.
    const term = child.wait(rt.io) catch return error.SkipZigTest;
    switch (term) {
        .signal => |sig| try testing.expectEqual(std.posix.SIG.TERM, sig),
        // A racing exit before the signal landed is acceptable; the point is
        // the child is no longer alive.
        else => {},
    }
    try testing.expect(!registry.isPidRunning(pid));
}

test "cmdKill on an unknown subject prints 'no such session'" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);
    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);
    setRegistryRoot(root_z);
    defer clearRegistryRoot();

    var out = std_io.StringBuilder.init(alloc);
    defer out.deinit();
    try cmdKill(alloc, "999999", out.writer());
    try testing.expect(std.mem.indexOf(u8, out.items(), "no such session") != null);
}

test "cmdLogs reads back a session's captured log" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);
    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);
    setRegistryRoot(root_z);
    defer clearRegistryRoot();

    // Write a log file and a registry entry (our own live pid) pointing at it.
    const log_dir = try logsDir(alloc);
    defer alloc.free(log_dir);
    try paths.ensureDir(log_dir);
    const log_path = try std.fmt.allocPrint(alloc, "{s}/test.log", .{log_dir});
    defer alloc.free(log_path);
    {
        const f = try std.Io.Dir.cwd().createFile(rt.io, log_path, .{ .truncate = true });
        defer f.close(rt.io);
        try f.writeStreamingAll(rt.io, "hello from the bg session\n");
    }

    const me = registry.currentPid();
    try writeRawEntry(alloc, root, me, "bg", "logged", log_path);

    var pid_buf: [16]u8 = undefined;
    const pid_str = try std.fmt.bufPrint(&pid_buf, "{d}", .{me});

    var out = std_io.StringBuilder.init(alloc);
    defer out.deinit();
    try cmdLogs(alloc, pid_str, out.writer());
    try testing.expectEqualStrings("hello from the bg session\n", out.items());
}

test "cmdLogs reports no log when the entry has no log_path" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);
    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);
    setRegistryRoot(root_z);
    defer clearRegistryRoot();

    const me = registry.currentPid();
    try writeRawEntry(alloc, root, me, "interactive", "nolog", null);

    var pid_buf: [16]u8 = undefined;
    const pid_str = try std.fmt.bufPrint(&pid_buf, "{d}", .{me});

    var out = std_io.StringBuilder.init(alloc);
    defer out.deinit();
    try cmdLogs(alloc, pid_str, out.writer());
    try testing.expect(std.mem.indexOf(u8, out.items(), "no log for session") != null);
}

test "register picks up ZCODE_SESSION_LOG from env (the --bg self-register path)" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);
    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);
    setRegistryRoot(root_z);
    defer clearRegistryRoot();
    defer env.clearOverrides();

    try env.setOverride("ZCODE_SESSION_LOG", "/tmp/zcode-bg.log");
    try registry.register(alloc, .{ .kind = .bg, .cwd = "/work" });
    defer registry.unregister(alloc);

    const entry = (try registry.read(alloc, registry.currentPid())).?;
    defer entry.deinit(alloc);
    try testing.expectEqualStrings("/tmp/zcode-bg.log", entry.log_path.?);
}

// phase-26 daemon-background-11: -n / --name shows up in ps and is picked up
// from ZCODE_SESSION_NAME on the --bg self-register path.

test "cmdPs shows the session name from a registered entry" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);
    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);
    setRegistryRoot(root_z);
    defer clearRegistryRoot();

    // A live entry (our own pid) named "build-x" must surface in ps.
    const me = registry.currentPid();
    try writeRawEntry(alloc, root, me, "interactive", "build-x", null);

    var out = std_io.StringBuilder.init(alloc);
    defer out.deinit();
    try cmdPs(alloc, out.writer());
    try testing.expect(std.mem.indexOf(u8, out.items(), "name=build-x") != null);
}

test "register picks up ZCODE_SESSION_NAME from env (the --bg self-register path)" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);
    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);
    setRegistryRoot(root_z);
    defer clearRegistryRoot();
    defer env.clearOverrides();

    try env.setOverride("ZCODE_SESSION_NAME", "build-x");
    // No explicit .name -> register falls back to ZCODE_SESSION_NAME.
    try registry.register(alloc, .{ .kind = .bg, .cwd = "/work" });
    defer registry.unregister(alloc);

    const entry = (try registry.read(alloc, registry.currentPid())).?;
    defer entry.deinit(alloc);
    try testing.expectEqualStrings("build-x", entry.name.?);
}

fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(rt.io, path, .{}) catch return false;
    return true;
}
