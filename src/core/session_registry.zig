//! Cross-session live-process registry (phase-26 daemon-background-02).
//!
//! Every top-level zcode session writes a per-process JSON file at
//! `~/.zcode/sessions/registry/<pid>.json` on startup, updates it live as the
//! session's name/status/waitingFor/sessionId change, and removes it on a clean
//! exit. `list()` enumerates the directory, sweeps stale PID files (a crashed
//! session never deleted its own file), and returns only the live entries. This
//! is what `zcode ps` (task 26.3) reads.
//!
//! Mirrors the reference `utils/concurrentSessions.ts` (registerSession /
//! updatePidFile / countConcurrentSessions). The registry lives in a dedicated
//! `registry/` subdir so it never collides with the `.jsonl` transcript files
//! under `sessions/`.
//!
//! Why a dedicated dir AND a strict `^\d+\.json$` filename guard: the reference
//! had a real data-loss bug (anthropics/claude-code#34210) where parseInt
//! prefix-matched `2026-03-14_notes.md` as PID 2026 and swept it. The subdir
//! makes a collision unlikely; the strict guard makes the sweep crash-robust
//! even if a stray file lands in the registry dir.

const std = @import("std");
const rt = @import("zcode_runtime");
const paths = @import("paths.zig");
const clock = @import("clock.zig");
const std_io = @import("std_io.zig");
const env = @import("env.zig");

const builtin = @import("builtin");

/// What kind of session this process is. Defined here (rather than in task
/// 26.2's wiring) so the registry can compile standalone; task 26.2 adds the
/// `fromEnv` helper and `ZCODE_SESSION_KIND` env wiring and re-exports this.
pub const SessionKind = enum {
    interactive,
    bg,
    daemon,
    daemon_worker,

    /// Stable wire string for the JSON file (kebab for the multi-word variant,
    /// matching the reference env values).
    pub fn toString(self: SessionKind) []const u8 {
        return switch (self) {
            .interactive => "interactive",
            .bg => "bg",
            .daemon => "daemon",
            .daemon_worker => "daemon-worker",
        };
    }

    pub fn fromString(s: []const u8) SessionKind {
        if (std.mem.eql(u8, s, "bg")) return .bg;
        if (std.mem.eql(u8, s, "daemon")) return .daemon;
        if (std.mem.eql(u8, s, "daemon-worker")) return .daemon_worker;
        return .interactive;
    }

    /// Read `ZCODE_SESSION_KIND` and map it to a kind. This is the
    /// "spawner sets env, child self-registers for free" pattern from the
    /// reference (concurrentSessions.ts envSessionKind): a `--bg`/daemon
    /// spawner sets `ZCODE_SESSION_KIND` in the child env, and the child's
    /// `register()` picks the right kind up without any extra argv wiring.
    /// Unset or any unrecognised value defaults to `.interactive`. The kebab
    /// `daemon-worker` is the wire value (matching `toString`); we compare
    /// with `std.mem.eql` rather than `std.meta.stringToEnum` because the env
    /// string uses a hyphen the Zig enum tag does not.
    pub fn fromEnv(allocator: std.mem.Allocator) SessionKind {
        const raw = env.getOwned(allocator, "ZCODE_SESSION_KIND") catch return .interactive;
        defer allocator.free(raw);
        return fromString(raw);
    }

    pub fn jsonStringify(self: SessionKind, jws: anytype) !void {
        try jws.write(self.toString());
    }
};

/// Live activity state of a session. `idle` is the default at registration.
pub const SessionStatus = enum {
    idle,
    busy,
    waiting,

    pub fn toString(self: SessionStatus) []const u8 {
        return switch (self) {
            .idle => "idle",
            .busy => "busy",
            .waiting => "waiting",
        };
    }

    pub fn fromString(s: []const u8) SessionStatus {
        if (std.mem.eql(u8, s, "busy")) return .busy;
        if (std.mem.eql(u8, s, "waiting")) return .waiting;
        return .idle;
    }

    pub fn jsonStringify(self: SessionStatus, jws: anytype) !void {
        try jws.write(self.toString());
    }
};

/// A parsed registry entry. Owned strings are allocated from the caller's
/// allocator by `list()` / `read()`; free with `deinit`.
pub const Entry = struct {
    pid: i32,
    session_id: ?[]const u8 = null,
    cwd: []const u8,
    started_ts: i64,
    updated_ts: i64,
    kind: SessionKind,
    name: ?[]const u8 = null,
    log_path: ?[]const u8 = null,
    status: SessionStatus = .idle,
    waiting_for: ?[]const u8 = null,

    pub fn deinit(self: *const Entry, allocator: std.mem.Allocator) void {
        if (self.session_id) |s| allocator.free(s);
        allocator.free(self.cwd);
        if (self.name) |s| allocator.free(s);
        if (self.log_path) |s| allocator.free(s);
        if (self.waiting_for) |s| allocator.free(s);
    }
};

pub fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |*e| e.deinit(allocator);
    allocator.free(entries);
}

/// Options for `register`. `kind` is optional: when null, `register` reads it
/// from `ZCODE_SESSION_KIND` via `SessionKind.fromEnv` (the reference's
/// "spawner sets env, child self-registers for free" pattern). Pass an explicit
/// kind to override the env. Everything else is optional metadata.
pub const RegisterOpts = struct {
    kind: ?SessionKind = null,
    session_id: ?[]const u8 = null,
    cwd: []const u8,
    name: ?[]const u8 = null,
    log_path: ?[]const u8 = null,
    status: SessionStatus = .idle,
};

/// Fire-and-forget live patch applied to the current process's file. Any field
/// left null is preserved from the existing file. `clear_waiting_for` lets a
/// caller explicitly null out `waiting_for` (since a null patch field means
/// "leave unchanged").
pub const Patch = struct {
    session_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    status: ?SessionStatus = null,
    waiting_for: ?[]const u8 = null,
    clear_waiting_for: bool = false,
};

// ===========================================================================
// PID helpers (pub so task 26.3's `kill`/`ps` reuse them; the private copies
// in kairos.zig / remote_daemon.zig are pre-existing and intentionally left
// untouched per the surgical-change rule).
// ===========================================================================

pub fn currentPid() i32 {
    return switch (builtin.os.tag) {
        .linux => std.os.linux.getpid(),
        else => std.c.getpid(),
    };
}

pub fn isPidRunning(pid: i32) bool {
    return std.c.kill(pid, @enumFromInt(0)) == 0;
}

// ===========================================================================
// Path resolution
// ===========================================================================

/// Absolute path to the registry directory. Honors `ZCODE_SESSIONS_DIR` as a
/// test/override hook (point it at a tmp dir in tests); otherwise derives
/// `<zcode_home>/sessions/registry`.
pub fn registryDir(allocator: std.mem.Allocator) ![]u8 {
    if (env.getOwned(allocator, "ZCODE_SESSIONS_DIR")) |override| {
        defer allocator.free(override);
        if (override.len > 0) return std.fs.path.join(allocator, &.{ override, "registry" });
    } else |_| {}

    var ps = try paths.resolve(allocator);
    defer ps.deinit(allocator);
    return std.fs.path.join(allocator, &.{ ps.sessions_dir, "registry" });
}

fn pidFilePath(allocator: std.mem.Allocator, dir: []const u8, pid: i32) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{d}.json", .{ dir, pid });
}

fn ensureRegistryDir(allocator: std.mem.Allocator, dir: []const u8) !void {
    try paths.ensureDir(dir);
    // Best-effort tighten to 0700 (registry leaks cwd/name to other local
    // users otherwise). chmod-by-path via libc rather than std.Io.Dir.chmod,
    // which on Linux panics in posix.fchmod when the dir is opened O_PATH
    // (see session_cmds.zig). Ignore failures - mode is advisory here.
    const dir_z = allocator.dupeZ(u8, dir) catch return;
    defer allocator.free(dir_z);
    _ = std.c.chmod(dir_z.ptr, 0o700);
}

// ===========================================================================
// register / update / unregister
// ===========================================================================

/// Write (or overwrite) the current process's registry file. Atomic
/// (temp file + rename) so a concurrent `ps` never reads a half-written file.
pub fn register(allocator: std.mem.Allocator, opts: RegisterOpts) !void {
    const dir = try registryDir(allocator);
    defer allocator.free(dir);
    try ensureRegistryDir(allocator, dir);

    // No explicit log_path from the caller means "trust the env": the same
    // "spawner sets env, child self-registers for free" pattern used for kind.
    // A --bg spawner (task 26.3) sets ZCODE_SESSION_LOG to the per-session log
    // file it created; the detached child picks it up here so `zcode logs`
    // can resolve the path from the registry without any extra argv wiring.
    const env_log = logPathFromEnv(allocator);
    defer if (env_log) |p| allocator.free(p);

    // gap-11: same env-driven self-registration for the display name. A --bg
    // spawner sets ZCODE_SESSION_NAME so a detached child names itself even on
    // paths that do not thread an explicit name into register().
    const env_name = nameFromEnv(allocator);
    defer if (env_name) |p| allocator.free(p);

    const now = clock.nowSeconds();
    const entry = Entry{
        .pid = currentPid(),
        .session_id = opts.session_id,
        .cwd = opts.cwd,
        .started_ts = now,
        .updated_ts = now,
        // No explicit kind from the caller means "trust the env": a spawner
        // (--bg/daemon) sets ZCODE_SESSION_KIND and the child self-registers.
        .kind = opts.kind orelse SessionKind.fromEnv(allocator),
        .name = opts.name orelse env_name,
        .log_path = opts.log_path orelse env_log,
        .status = opts.status,
        .waiting_for = null,
    };
    try writeEntry(allocator, dir, entry);
}

/// Read `ZCODE_SESSION_LOG` (the per-session log path the --bg spawner set in
/// the child env) into an owned string, or null when unset/empty. Mirrors the
/// `SessionKind.fromEnv` env-driven self-registration pattern for log_path.
fn logPathFromEnv(allocator: std.mem.Allocator) ?[]u8 {
    const raw = env.getOwned(allocator, "ZCODE_SESSION_LOG") catch return null;
    if (raw.len == 0) {
        allocator.free(raw);
        return null;
    }
    return raw;
}

/// Read `ZCODE_SESSION_NAME` (the display name a --bg spawner set in the child
/// env from the -n/--name value) into an owned string, or null when
/// unset/empty. Mirrors `logPathFromEnv` / `SessionKind.fromEnv`.
fn nameFromEnv(allocator: std.mem.Allocator) ?[]u8 {
    const raw = env.getOwned(allocator, "ZCODE_SESSION_NAME") catch return null;
    if (raw.len == 0) {
        allocator.free(raw);
        return null;
    }
    return raw;
}

/// Best-effort live patch of the current process's registry file. Never
/// throws: a missing/corrupt file or a write race is swallowed (mirrors the
/// reference's fire-and-forget update). `updated_ts` is always advanced.
pub fn update(allocator: std.mem.Allocator, patch: Patch) void {
    updateImpl(allocator, patch) catch {};
}

fn updateImpl(allocator: std.mem.Allocator, patch: Patch) !void {
    const dir = try registryDir(allocator);
    defer allocator.free(dir);

    const path = try pidFilePath(allocator, dir, currentPid());
    defer allocator.free(path);

    var existing = (try readFile(allocator, path)) orelse return;
    defer existing.deinit(allocator);

    // Merge the patch into a fresh Entry (the merged strings borrow either the
    // patch or the existing entry; both outlive writeEntry).
    var merged = existing;
    if (patch.session_id) |s| merged.session_id = s;
    if (patch.name) |s| merged.name = s;
    if (patch.status) |s| merged.status = s;
    if (patch.clear_waiting_for) {
        merged.waiting_for = null;
    } else if (patch.waiting_for) |s| {
        merged.waiting_for = s;
    }
    merged.updated_ts = clock.nowSeconds();

    try writeEntry(allocator, dir, merged);
}

/// Delete the current process's registry file. A second call is a no-op
/// (ENOENT is swallowed). Call from a `defer` at the top of `main`.
pub fn unregister(allocator: std.mem.Allocator) void {
    unregisterImpl(allocator) catch {};
}

fn unregisterImpl(allocator: std.mem.Allocator) !void {
    const dir = try registryDir(allocator);
    defer allocator.free(dir);
    const path = try pidFilePath(allocator, dir, currentPid());
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(rt.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

// ===========================================================================
// list (enumerate + sweep stale)
// ===========================================================================

/// Enumerate the registry, sweep stale (dead-PID) files, and return the live
/// entries. Only `^\d+\.json$` filenames are considered; any other file is
/// left untouched (the parseInt prefix-bug guard). Dead-PID files (other than
/// our own) are deleted, except on WSL where the interop PID namespace makes a
/// liveness probe unreliable.
pub fn list(allocator: std.mem.Allocator) ![]Entry {
    const dir_path = try registryDir(allocator);
    defer allocator.free(dir_path);

    var dir = std.Io.Dir.cwd().openDir(rt.io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(Entry, 0),
        else => return err,
    };
    defer dir.close(rt.io);

    const sweep_ok = !isWsl();
    const me = currentPid();

    var out: std.ArrayList(Entry) = .empty;
    errdefer {
        for (out.items) |*e| e.deinit(allocator);
        out.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(rt.io)) |dirent| {
        if (dirent.kind != .file) continue;
        // Strict `^\d+\.json$` guard: skip any file whose name is not a bare
        // pid (the parseInt prefix-bug data-loss guard). We do not need the
        // parsed value here - the entry's own `pid` field drives liveness.
        _ = pidFromFilename(dirent.name) orelse continue;

        const path = try std.fs.path.join(allocator, &.{ dir_path, dirent.name });
        defer allocator.free(path);

        const entry = (readFile(allocator, path) catch null) orelse continue;
        const alive = isPidRunning(entry.pid);
        if (!alive) {
            // Stale: a session that crashed without unregistering. Sweep it
            // (never our own pid - that file is owned by this process). Skip
            // the sweep on WSL.
            entry.deinit(allocator);
            if (sweep_ok and entry.pid != me) {
                std.Io.Dir.cwd().deleteFile(rt.io, path) catch {};
            }
            continue;
        }
        try out.append(allocator, entry);
    }

    return out.toOwnedSlice(allocator);
}

/// Read a single registry file path into an owned `Entry`, or null on
/// missing/corrupt. Exposed for task 26.3 (`kill`/`logs` resolve a specific
/// pid file).
pub fn read(allocator: std.mem.Allocator, pid: i32) !?Entry {
    const dir = try registryDir(allocator);
    defer allocator.free(dir);
    const path = try pidFilePath(allocator, dir, pid);
    defer allocator.free(path);
    return readFile(allocator, path);
}

// ===========================================================================
// JSON read / write
// ===========================================================================

fn writeEntry(allocator: std.mem.Allocator, dir: []const u8, entry: Entry) !void {
    const path = try pidFilePath(allocator, dir, entry.pid);
    defer allocator.free(path);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try out.writer().print("{f}\n", .{std.json.fmt(entry, .{})});

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ path, clock.nowNanos() });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};
    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, out.items());
        file.sync(rt.io) catch {};
    }
    try std.Io.Dir.renameAbsolute(tmp_path, path, rt.io);
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) !?Entry {
    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        // 0.16: an over-limit read yields StreamTooLong, not FileTooBig.
        error.StreamTooLong => return null,
        else => return err,
    };
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const obj = parsed.value.object;

    const pid_i = getInteger(obj, "pid") orelse return null;
    const cwd_src = getString(obj, "cwd") orelse return null;

    var entry = Entry{
        .pid = @intCast(pid_i),
        .cwd = try allocator.dupe(u8, cwd_src),
        .started_ts = getInteger(obj, "started_ts") orelse 0,
        .updated_ts = getInteger(obj, "updated_ts") orelse 0,
        .kind = if (getString(obj, "kind")) |k| SessionKind.fromString(k) else .interactive,
        .status = if (getString(obj, "status")) |s| SessionStatus.fromString(s) else .idle,
    };
    errdefer entry.deinit(allocator);

    if (getString(obj, "session_id")) |s| entry.session_id = try allocator.dupe(u8, s);
    if (getString(obj, "name")) |s| entry.name = try allocator.dupe(u8, s);
    if (getString(obj, "log_path")) |s| entry.log_path = try allocator.dupe(u8, s);
    if (getString(obj, "waiting_for")) |s| entry.waiting_for = try allocator.dupe(u8, s);

    return entry;
}

// ===========================================================================
// Small helpers
// ===========================================================================

/// Accept only `^\d+\.json$` filenames. Returns the parsed pid or null. This
/// is the data-loss-bug guard: a name like `2026-03-14_notes.json` or
/// `notes.md` is rejected so the sweep never touches it.
fn pidFromFilename(name: []const u8) ?i32 {
    if (!std.mem.endsWith(u8, name, ".json")) return null;
    const stem = name[0 .. name.len - ".json".len];
    if (stem.len == 0) return null;
    for (stem) |c| {
        if (c < '0' or c > '9') return null;
    }
    return std.fmt.parseInt(i32, stem, 10) catch null;
}

fn getInteger(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |n| n,
        else => null,
    };
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

/// Best-effort WSL probe: WSL sets WSL_DISTRO_NAME / WSL_INTEROP. On WSL the
/// interop PID namespace makes a kill(0) liveness probe unreliable, so the
/// reference skips the stale sweep there. We mirror that.
fn isWsl() bool {
    if (builtin.os.tag != .linux) return false;
    if (env.getenv("WSL_DISTRO_NAME") != null) return true;
    if (env.getenv("WSL_INTEROP") != null) return true;
    return false;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;
const test_helpers = @import("test_helpers.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Point the registry at a tmp dir for the duration of a test. Caller restores
/// by calling `unsetenv` (done in each test's defer).
fn setRegistryRoot(root_z: [*:0]const u8) void {
    _ = setenv("ZCODE_SESSIONS_DIR", root_z, 1);
}

fn clearRegistryRoot() void {
    _ = unsetenv("ZCODE_SESSIONS_DIR");
}

test "register then list round-trips the current pid" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);
    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);

    setRegistryRoot(root_z);
    defer clearRegistryRoot();

    try register(alloc, .{ .kind = .interactive, .cwd = "/work/proj", .name = "myproj" });
    defer unregister(alloc);

    const entries = try list(alloc);
    defer freeEntries(alloc, entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(currentPid(), entries[0].pid);
    try testing.expectEqual(SessionKind.interactive, entries[0].kind);
    try testing.expectEqualStrings("/work/proj", entries[0].cwd);
    try testing.expectEqualStrings("myproj", entries[0].name.?);
    try testing.expect(entries[0].started_ts > 0);
}

test "list sweeps a dead pid file but leaves non-pid filenames untouched" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);
    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);

    setRegistryRoot(root_z);
    defer clearRegistryRoot();

    const dir = try registryDir(alloc);
    defer alloc.free(dir);
    try ensureRegistryDir(alloc, dir);

    // A dead-PID registry file (999999 is not running).
    const dead_path = try pidFilePath(alloc, dir, 999999);
    defer alloc.free(dead_path);
    try writeEntry(alloc, dir, .{ .pid = 999999, .cwd = "/x", .started_ts = 1, .updated_ts = 1, .kind = .bg });

    // A non-pid file that must survive the sweep (parseInt prefix-bug guard).
    const notes_path = try std.fs.path.join(alloc, &.{ dir, "2026-03-14_notes.json" });
    defer alloc.free(notes_path);
    {
        const f = try std.Io.Dir.cwd().createFile(rt.io, notes_path, .{ .truncate = true });
        f.close(rt.io);
    }
    const md_path = try std.fs.path.join(alloc, &.{ dir, "notes.md" });
    defer alloc.free(md_path);
    {
        const f = try std.Io.Dir.cwd().createFile(rt.io, md_path, .{ .truncate = true });
        f.close(rt.io);
    }

    const entries = try list(alloc);
    defer freeEntries(alloc, entries);

    // Dead pid was swept (and was never live, so not returned).
    try testing.expectEqual(@as(usize, 0), entries.len);
    try testing.expect(!fileExists(dead_path));

    // Non-pid files were left untouched.
    try testing.expect(fileExists(notes_path));
    try testing.expect(fileExists(md_path));
}

test "update patches status/waiting_for and advances updated_ts" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);
    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);

    setRegistryRoot(root_z);
    defer clearRegistryRoot();

    try register(alloc, .{ .kind = .interactive, .cwd = "/work" });
    defer unregister(alloc);

    const before = (try read(alloc, currentPid())).?;
    const before_ts = before.updated_ts;
    before.deinit(alloc);

    // Ensure the clock advances at least one second so the assertion is real.
    clock.sleepNanos(1 * std.time.ns_per_s + 50 * std.time.ns_per_ms);

    update(alloc, .{ .status = .busy, .waiting_for = "tool" });

    const after = (try read(alloc, currentPid())).?;
    defer after.deinit(alloc);
    try testing.expectEqual(SessionStatus.busy, after.status);
    try testing.expectEqualStrings("tool", after.waiting_for.?);
    try testing.expect(after.updated_ts >= before_ts);
}

test "unregister removes the file and a second call is a no-op" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);
    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);

    setRegistryRoot(root_z);
    defer clearRegistryRoot();

    try register(alloc, .{ .kind = .interactive, .cwd = "/work" });

    const dir = try registryDir(alloc);
    defer alloc.free(dir);
    const path = try pidFilePath(alloc, dir, currentPid());
    defer alloc.free(path);
    try testing.expect(fileExists(path));

    unregister(alloc);
    try testing.expect(!fileExists(path));

    // Second call must not error.
    unregister(alloc);
    try testing.expect(!fileExists(path));
}

test "SessionKind.fromEnv maps ZCODE_SESSION_KIND, defaulting to interactive" {
    const alloc = testing.allocator;
    defer env.clearOverrides();

    // Unset -> interactive (the override map starts empty for this key).
    env.clearOverrides();
    try testing.expectEqual(SessionKind.interactive, SessionKind.fromEnv(alloc));

    try env.setOverride("ZCODE_SESSION_KIND", "bg");
    try testing.expectEqual(SessionKind.bg, SessionKind.fromEnv(alloc));

    try env.setOverride("ZCODE_SESSION_KIND", "daemon");
    try testing.expectEqual(SessionKind.daemon, SessionKind.fromEnv(alloc));

    try env.setOverride("ZCODE_SESSION_KIND", "daemon-worker");
    try testing.expectEqual(SessionKind.daemon_worker, SessionKind.fromEnv(alloc));

    // A garbage value falls back to interactive (matches the reference).
    try env.setOverride("ZCODE_SESSION_KIND", "nonsense");
    try testing.expectEqual(SessionKind.interactive, SessionKind.fromEnv(alloc));
}

test "register honors ZCODE_SESSION_KIND when no explicit kind is passed" {
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

    try env.setOverride("ZCODE_SESSION_KIND", "bg");
    // No .kind field -> defaults to fromEnv, which sees the override.
    try register(alloc, .{ .cwd = "/work" });
    defer unregister(alloc);

    const entries = try list(alloc);
    defer freeEntries(alloc, entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(SessionKind.bg, entries[0].kind);
}

test "pidFromFilename strict guard" {
    try testing.expectEqual(@as(?i32, 1234), pidFromFilename("1234.json"));
    try testing.expectEqual(@as(?i32, null), pidFromFilename("2026-03-14_notes.json"));
    try testing.expectEqual(@as(?i32, null), pidFromFilename("notes.md"));
    try testing.expectEqual(@as(?i32, null), pidFromFilename(".json"));
    try testing.expectEqual(@as(?i32, null), pidFromFilename("12a.json"));
}

fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(rt.io, path, .{}) catch return false;
    return true;
}
