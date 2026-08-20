//! IDE lockfile discovery + stale cleanup (ide-integration-01).
//!
//! Ported from claude-code-main/src/utils/ide.ts. The IDE extension
//! (VS Code / JetBrains) writes a `<port>.lock` JSON file into
//! `~/.claude/ide/` when it starts listening. This module reads those
//! lockfiles, ranks candidates by mtime (newest first), and prunes
//! lockfiles whose owning pid is dead or whose port is unresponsive.
//! Task 02 dials the surviving candidates as MCP endpoints.
//!
//! Reference paths (utils/ide.ts):
//!   :73  LockfileJsonContent schema
//!   :298 getSortedIdeLockfiles - readdir + stat + sort newest-first
//!   :346 readIdeLockfile - parse JSON, fall back to newline workspaces,
//!         derive the port from the FILENAME (`12345.lock` -> 12345)
//!   :462 getIdeLockfilesPaths - base dir = configHome/ide (+ WSL probe)
//!   :522 cleanupStaleIdeLockfiles - the delete matrix
//!
//! NOTE: zcode's own config tree is `~/.zcode/`, but the IDE lockfile
//! dir the *extension* writes is `~/.claude/ide` -- we match the
//! reference path so a real Claude Code extension is discoverable.
//! `ZCODE_IDE_LOCKFILE_DIR` overrides the dir (used by tests).

const std = @import("std");
const builtin = @import("builtin");
const rt = @import("zcode_runtime");
const xdg = @import("xdg.zig");
const platform = @import("platform.zig");

/// Cap on a single lockfile body. The reference lockfiles are a few
/// hundred bytes of JSON; 64 KiB is generous headroom that still
/// bounds a pathological file.
const MAX_LOCKFILE_BYTES: usize = 64 * 1024;

/// TCP connect timeout for the port-liveness probe. The reference
/// uses 500ms (utils/ide.ts:402 checkIdeConnection).
const PORT_PROBE_TIMEOUT_MS: u64 = 500;

pub const Lockfile = struct {
    /// Derived from the filename (`40145.lock` -> 40145), never JSON.
    port: u16,
    /// Owned slices; freed by deinit.
    workspace_folders: [][]u8,
    pid: ?i32,
    ide_name: ?[]u8,
    /// transport == "ws" (else "sse").
    use_websocket: bool,
    running_in_windows: bool,
    auth_token: ?[]u8,
    /// Nanosecond mtime of the lockfile, for newest-first sorting.
    mtime_ns: i128,
    /// Absolute path to the lockfile on disk (owned).
    path: []u8,

    pub fn deinit(self: *Lockfile, allocator: std.mem.Allocator) void {
        for (self.workspace_folders) |wf| allocator.free(wf);
        if (self.workspace_folders.len > 0) allocator.free(self.workspace_folders);
        if (self.ide_name) |n| allocator.free(n);
        if (self.auth_token) |t| allocator.free(t);
        allocator.free(self.path);
    }
};

/// Free a slice of lockfiles returned by `discover`.
pub fn freeList(allocator: std.mem.Allocator, list: []Lockfile) void {
    for (list) |*lf| lf.deinit(allocator);
    if (list.len > 0) allocator.free(list);
}

/// Resolve the IDE lockfile directory. Precedence:
///   1. ZCODE_IDE_LOCKFILE_DIR (test/override hook)
///   2. CLAUDE_CONFIG_DIR/ide
///   3. $HOME/.claude/ide
/// Returns an owned absolute path.
pub fn lockfileDir(allocator: std.mem.Allocator) ![]u8 {
    if (xdg.getEnvOptional(allocator, "ZCODE_IDE_LOCKFILE_DIR")) |override| {
        if (override.len > 0) return override;
        allocator.free(override);
    }
    if (xdg.getEnvOptional(allocator, "CLAUDE_CONFIG_DIR")) |cfg| {
        defer allocator.free(cfg);
        if (cfg.len > 0) return std.fs.path.join(allocator, &.{ cfg, "ide" });
    }
    const home = try resolveHomeDir(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".claude", "ide" });
}

/// $HOME on POSIX, %USERPROFILE% on Windows. Mirrors xdg.zig's private
/// resolveHomeDir (which is not exported) to keep "home" consistent.
fn resolveHomeDir(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag != .windows) {
        return xdg.getEnvOptional(allocator, "HOME") orelse error.HomeDirNotSet;
    }
    if (xdg.getEnvOptional(allocator, "USERPROFILE")) |p| return p;
    return error.HomeDirNotSet;
}

const Candidate = struct {
    path: []u8,
    mtime_ns: i128,
};

/// Collect every `*.lock` candidate path (with mtime), sorted
/// newest-first, across the base dir and (on WSL) the Windows-host
/// probes. Caller frees each `.path` and deinits the list.
fn collectAllCandidates(
    allocator: std.mem.Allocator,
    candidates: *std.array_list.Managed(Candidate),
) !void {
    const base = try lockfileDir(allocator);
    defer allocator.free(base);
    try collectCandidates(allocator, candidates, base);

    // On WSL the extension may run on the Windows host, writing its
    // lockfile under /mnt/c/Users/<user>/.claude/ide. Probe those too.
    if (platform.detect() == .wsl) {
        try collectWslCandidates(allocator, candidates);
    }

    // Newest first. The mtime is the dominant signal; the reference
    // sorts purely by mtime descending (utils/ide.ts:298).
    std.mem.sort(Candidate, candidates.items, {}, struct {
        fn lt(_: void, a: Candidate, b: Candidate) bool {
            return a.mtime_ns > b.mtime_ns;
        }
    }.lt);
}

/// Discover all `*.lock` files under the IDE lockfile dir, parse each,
/// and return them sorted newest-first. A missing dir yields an empty
/// slice (not an error). Caller owns the result; free with `freeList`.
pub fn discover(allocator: std.mem.Allocator) ![]Lockfile {
    var candidates = std.array_list.Managed(Candidate).init(allocator);
    defer {
        for (candidates.items) |c| allocator.free(c.path);
        candidates.deinit();
    }
    try collectAllCandidates(allocator, &candidates);

    var out = std.array_list.Managed(Lockfile).init(allocator);
    errdefer freeList(allocator, out.toOwnedSlice() catch &.{});
    for (candidates.items) |c| {
        var lf = (try readOne(allocator, c.path)) orelse continue;
        lf.mtime_ns = c.mtime_ns;
        try out.append(lf);
    }
    return out.toOwnedSlice();
}

/// Add every `*.lock` entry under `dir` to `candidates`, stamped with
/// its mtime. A missing/inaccessible dir is silently skipped.
fn collectCandidates(
    allocator: std.mem.Allocator,
    candidates: *std.array_list.Managed(Candidate),
    dir: []const u8,
) !void {
    var d = std.Io.Dir.cwd().openDir(rt.io, dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        error.NotDir => return,
        error.AccessDenied => return,
        else => return err,
    };
    defer d.close(rt.io);

    var it = d.iterate();
    while (try it.next(rt.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".lock")) continue;

        var mtime_ns: i128 = 0;
        if (d.statFile(rt.io, entry.name, .{})) |st| {
            mtime_ns = st.mtime.toNanoseconds();
        } else |_| {}

        const full = try std.fs.path.join(allocator, &.{ dir, entry.name });
        errdefer allocator.free(full);
        try candidates.append(.{ .path = full, .mtime_ns = mtime_ns });
    }
}

/// WSL: probe `/mnt/c/Users/<user>/.claude/ide` for every real user
/// dir, skipping the well-known non-user accounts. Mirrors
/// getIdeLockfilesPaths (utils/ide.ts:462).
fn collectWslCandidates(
    allocator: std.mem.Allocator,
    candidates: *std.array_list.Managed(Candidate),
) !void {
    const users_root = "/mnt/c/Users";
    var users = std.Io.Dir.cwd().openDir(rt.io, users_root, .{ .iterate = true }) catch return;
    defer users.close(rt.io);

    var it = users.iterate();
    while (try it.next(rt.io)) |entry| {
        if (entry.kind != .directory) continue;
        if (isSkippedWindowsUser(entry.name)) continue;
        const ide_dir = std.fs.path.join(allocator, &.{ users_root, entry.name, ".claude", "ide" }) catch continue;
        defer allocator.free(ide_dir);
        collectCandidates(allocator, candidates, ide_dir) catch continue;
    }
}

/// The reference skips these built-in Windows accounts when probing
/// /mnt/c/Users (utils/ide.ts:462).
fn isSkippedWindowsUser(name: []const u8) bool {
    const skip = [_][]const u8{ "Public", "Default", "Default User", "All Users" };
    for (skip) |s| {
        if (std.ascii.eqlIgnoreCase(name, s)) return true;
    }
    return false;
}

/// Read and parse a single lockfile at `path`. Returns null when the
/// port cannot be derived from the filename or the file is unreadable
/// (so cleanupStale can treat null as "unlink"). On JSON parse failure
/// the body is treated as newline-separated workspace folders (the
/// older lockfile format, utils/ide.ts:346).
///
/// `mtime_ns` is left 0; `discover` stamps it from the dir scan.
pub fn readOne(allocator: std.mem.Allocator, path: []const u8) !?Lockfile {
    const port = portFromPath(path) orelse return null;

    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(MAX_LOCKFILE_BYTES)) catch |err| switch (err) {
        error.FileNotFound => return null,
        // 0.16: oversize file is StreamTooLong, not FileTooBig.
        error.StreamTooLong => return null,
        else => return err,
    };
    defer allocator.free(bytes);

    const path_owned = try allocator.dupe(u8, path);
    errdefer allocator.free(path_owned);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        // Older format: newline-separated workspace folder paths.
        const folders = try parseNewlineWorkspaces(allocator, bytes);
        return Lockfile{
            .port = port,
            .workspace_folders = folders,
            .pid = null,
            .ide_name = null,
            .use_websocket = false,
            .running_in_windows = false,
            .auth_token = null,
            .mtime_ns = 0,
            .path = path_owned,
        };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        // Valid JSON but not an object: nothing useful to extract.
        return Lockfile{
            .port = port,
            .workspace_folders = &.{},
            .pid = null,
            .ide_name = null,
            .use_websocket = false,
            .running_in_windows = false,
            .auth_token = null,
            .mtime_ns = 0,
            .path = path_owned,
        };
    }
    const obj = parsed.value.object;

    const folders = try parseWorkspaceFolders(allocator, obj);
    errdefer {
        for (folders) |f| allocator.free(f);
        if (folders.len > 0) allocator.free(folders);
    }

    const ide_name = try dupOptionalString(allocator, obj, "ideName");
    errdefer if (ide_name) |n| allocator.free(n);
    const auth_token = try dupOptionalString(allocator, obj, "authToken");
    errdefer if (auth_token) |t| allocator.free(t);

    return Lockfile{
        .port = port,
        .workspace_folders = folders,
        .pid = parseOptionalI32(obj, "pid"),
        .ide_name = ide_name,
        .use_websocket = parseUseWebsocket(obj),
        .running_in_windows = parseOptionalBool(obj, "runningInWindows"),
        .auth_token = auth_token,
        .mtime_ns = 0,
        .path = path_owned,
    };
}

/// Discover, then apply the reference delete matrix (utils/ide.ts:522):
///   - unreadable lockfile (readOne -> null)      -> unlink
///   - pid present and not running:
///       non-WSL                                  -> delete
///       WSL: also require port not responding    -> delete
///   - no pid: delete only if port not responding
pub fn cleanupStale(allocator: std.mem.Allocator) !void {
    const is_wsl = platform.detect() == .wsl;

    var candidates = std.array_list.Managed(Candidate).init(allocator);
    defer {
        for (candidates.items) |c| allocator.free(c.path);
        candidates.deinit();
    }
    try collectAllCandidates(allocator, &candidates);

    for (candidates.items) |c| {
        // Unreadable / unparseable lockfile -> unlink (utils/ide.ts:522).
        var lf = (try readOne(allocator, c.path)) orelse {
            std.Io.Dir.cwd().deleteFile(rt.io, c.path) catch {};
            continue;
        };
        defer lf.deinit(allocator);

        const should_delete = blk: {
            if (lf.pid) |pid| {
                if (pidAlive(pid)) break :blk false;
                // pid is dead.
                if (is_wsl) break :blk !portResponds(lf.port);
                break :blk true;
            }
            // No pid: delete only if the port is dead too.
            break :blk !portResponds(lf.port);
        };
        if (should_delete) {
            std.Io.Dir.cwd().deleteFile(rt.io, c.path) catch {};
        }
    }
}

// ── parsing helpers ─────────────────────────────────────────────────

/// Derive the port from the basename with `.lock` stripped. Returns
/// null if the stem is not a valid u16.
fn portFromPath(path: []const u8) ?u16 {
    const base = std.fs.path.basename(path);
    if (!std.mem.endsWith(u8, base, ".lock")) return null;
    const stem = base[0 .. base.len - ".lock".len];
    return std.fmt.parseInt(u16, stem, 10) catch null;
}

/// Older format fallback: each non-empty line is a workspace folder.
fn parseNewlineWorkspaces(allocator: std.mem.Allocator, body: []const u8) ![][]u8 {
    var list = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (list.items) |f| allocator.free(f);
        list.deinit();
    }
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        try list.append(try allocator.dupe(u8, line));
    }
    return list.toOwnedSlice();
}

/// Pull the `workspaceFolders` string array. Missing/non-array yields
/// an empty (non-allocated) slice.
fn parseWorkspaceFolders(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![][]u8 {
    const v = obj.get("workspaceFolders") orelse return &.{};
    if (v != .array) return &.{};
    var list = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (list.items) |f| allocator.free(f);
        list.deinit();
    }
    for (v.array.items) |item| {
        const s = switch (item) {
            .string => |str| str,
            else => continue,
        };
        try list.append(try allocator.dupe(u8, s));
    }
    return list.toOwnedSlice();
}

fn dupOptionalString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) !?[]u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        else => null,
    };
}

fn parseOptionalI32(obj: std.json.ObjectMap, key: []const u8) ?i32 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| std.math.cast(i32, i),
        .float => |f| std.math.cast(i32, @as(i64, @intFromFloat(f))),
        else => null,
    };
}

fn parseOptionalBool(obj: std.json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

/// transport == "ws" -> websocket; anything else (including "sse" or
/// absent) -> false.
fn parseUseWebsocket(obj: std.json.ObjectMap) bool {
    const v = obj.get("transport") orelse return false;
    return switch (v) {
        .string => |s| std.mem.eql(u8, s, "ws"),
        else => false,
    };
}

// ── liveness helpers ────────────────────────────────────────────────

/// Real OS PID (mirrors dream.zig / kairos_lock.zig getpid switch).
fn getpid() i32 {
    return switch (builtin.os.tag) {
        .linux => std.os.linux.getpid(),
        else => std.c.getpid(),
    };
}

/// PID liveness via `kill(pid, 0)`: signal 0 posts nothing but probes
/// existence. Success -> alive. EPERM -> alive (process exists, owned
/// by someone else). ESRCH / any other error -> dead. Mirrors the
/// reference's process-running check.
fn pidAlive(pid: i32) bool {
    const pid_t: std.posix.pid_t = @intCast(pid);
    std.posix.kill(pid_t, @enumFromInt(0)) catch |err| switch (err) {
        error.PermissionDenied => return true,
        else => return false,
    };
    return true;
}

/// 500ms TCP connect probe to 127.0.0.1:port. A successful connect
/// means the IDE is still listening. Any error (refused, timeout)
/// means dead. Best-effort -- never throws.
fn portResponds(port: u16) bool {
    if (port == 0) return false;
    const addr: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } };
    const stream = std.Io.net.IpAddress.connect(&addr, rt.io, .{
        .mode = .stream,
        .timeout = .{ .duration = .{
            .raw = .{ .nanoseconds = PORT_PROBE_TIMEOUT_MS * std.time.ns_per_ms },
            .clock = .awake,
        } },
    }) catch return false;
    stream.close(rt.io);
    return true;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;
const test_helpers = @import("test_helpers.zig");
const env = @import("env.zig");

/// Point the lockfile dir at the test's tmp dir via env.zig's in-process
/// override layer (env.getenv consults setOverride before libc, so
/// getEnvOptional -> lockfileDir sees it). Cleaner than libc setenv and
/// matches how the rest of the codebase shadows env in tests.
fn setLockfileDirEnv(dir: []const u8) !void {
    try env.setOverride("ZCODE_IDE_LOCKFILE_DIR", dir);
}
fn unsetLockfileDirEnv() void {
    env.clearOverrides();
}

fn writeLockfile(tmp: *std.testing.TmpDir, name: []const u8, body: []const u8) !void {
    try tmp.dir.writeFile(rt.io, .{ .sub_path = name, .data = body });
}

test "discover parses a ws lockfile with current pid" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(dir_path);
    try setLockfileDirEnv(dir_path);
    defer unsetLockfileDirEnv();

    const pid = getpid();
    const body = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"transport\":\"ws\",\"pid\":{d},\"ideName\":\"VS Code\",\"workspaceFolders\":[\"/a\"],\"authToken\":\"t\"}}",
        .{pid},
    );
    defer testing.allocator.free(body);
    try writeLockfile(&tmp, "40145.lock", body);

    const list = try discover(testing.allocator);
    defer freeList(testing.allocator, list);

    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqual(@as(u16, 40145), list[0].port);
    try testing.expect(list[0].use_websocket);
    try testing.expect(list[0].auth_token != null);
    try testing.expectEqualStrings("t", list[0].auth_token.?);
    try testing.expect(list[0].pid != null);
    try testing.expectEqual(pid, list[0].pid.?);
    try testing.expectEqual(@as(usize, 1), list[0].workspace_folders.len);
    try testing.expectEqualStrings("/a", list[0].workspace_folders[0]);
    try testing.expect(list[0].ide_name != null);
    try testing.expectEqualStrings("VS Code", list[0].ide_name.?);
}

test "discover sorts lockfiles newest-first by mtime" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(dir_path);
    try setLockfileDirEnv(dir_path);
    defer unsetLockfileDirEnv();

    // Write the "older" file first, then ensure the newer file has a
    // strictly larger mtime by explicitly bumping it forward.
    try writeLockfile(&tmp, "11111.lock", "{\"transport\":\"ws\"}");
    try writeLockfile(&tmp, "22222.lock", "{\"transport\":\"ws\"}");

    // Force a known mtime ordering: 22222 newer than 11111, so the
    // test does not depend on filesystem timestamp resolution between
    // two writes that may land in the same millisecond.
    const now = std.Io.Clock.Timestamp.now(rt.io, .real).raw.toNanoseconds();
    const one_sec: i96 = std.time.ns_per_s;
    try setMtime(&tmp, "11111.lock", now - one_sec);
    try setMtime(&tmp, "22222.lock", now);

    const list = try discover(testing.allocator);
    defer freeList(testing.allocator, list);

    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqual(@as(u16, 22222), list[0].port);
    try testing.expectEqual(@as(u16, 11111), list[1].port);
}

/// Set the modification time of a file inside the tmp dir to an
/// absolute nanosecond value.
fn setMtime(tmp: *std.testing.TmpDir, name: []const u8, mtime_ns: i96) !void {
    var f = try tmp.dir.openFile(rt.io, name, .{ .mode = .read_write });
    defer f.close(rt.io);
    try f.setTimestamps(rt.io, .{
        .access_timestamp = .now,
        .modify_timestamp = .{ .new = .{ .nanoseconds = mtime_ns } },
    });
}

test "cleanupStale deletes dead-pid lockfile, keeps live-pid one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(dir_path);
    try setLockfileDirEnv(dir_path);
    defer unsetLockfileDirEnv();

    // Dead pid: 2147480000 is well above any live pid and not running.
    // Port must be a valid u16 (filename stem) so the lockfile parses
    // and reaches the dead-pid branch of the delete matrix.
    try writeLockfile(&tmp, "59999.lock", "{\"pid\":2147480000}");

    const live = getpid();
    const live_body = try std.fmt.allocPrint(testing.allocator, "{{\"pid\":{d}}}", .{live});
    defer testing.allocator.free(live_body);
    try writeLockfile(&tmp, "40146.lock", live_body);

    try cleanupStale(testing.allocator);

    // Dead-pid lockfile gone.
    try testing.expectError(error.FileNotFound, tmp.dir.access(rt.io, "59999.lock", .{}));
    // Live-pid lockfile survives.
    try tmp.dir.access(rt.io, "40146.lock", .{});
}

test "cleanupStale unlinks a lockfile with an unparseable port stem" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(dir_path);
    try setLockfileDirEnv(dir_path);
    defer unsetLockfileDirEnv();

    // "notaport.lock" -> readOne returns null -> unlink (utils/ide.ts:522).
    try writeLockfile(&tmp, "notaport.lock", "{\"transport\":\"ws\"}");

    try cleanupStale(testing.allocator);

    try testing.expectError(error.FileNotFound, tmp.dir.access(rt.io, "notaport.lock", .{}));
}

test "readOne falls back to newline workspace folders, port from filename" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(dir_path);
    try setLockfileDirEnv(dir_path);
    defer unsetLockfileDirEnv();

    try writeLockfile(&tmp, "55555.lock", "/ws/one\n/ws/two");

    const full = try std.fs.path.join(testing.allocator, &.{ dir_path, "55555.lock" });
    defer testing.allocator.free(full);

    var lf = (try readOne(testing.allocator, full)).?;
    defer lf.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 55555), lf.port);
    try testing.expectEqual(@as(usize, 2), lf.workspace_folders.len);
    try testing.expectEqualStrings("/ws/one", lf.workspace_folders[0]);
    try testing.expectEqualStrings("/ws/two", lf.workspace_folders[1]);
    try testing.expectEqual(@as(?i32, null), lf.pid);
    try testing.expect(!lf.use_websocket);
}

test "portFromPath derives port and rejects non-numeric stems" {
    try testing.expectEqual(@as(?u16, 40145), portFromPath("/x/40145.lock"));
    try testing.expectEqual(@as(?u16, null), portFromPath("/x/notaport.lock"));
    try testing.expectEqual(@as(?u16, null), portFromPath("/x/40145.txt"));
}

test "isSkippedWindowsUser matches the reserved accounts case-insensitively" {
    try testing.expect(isSkippedWindowsUser("Public"));
    try testing.expect(isSkippedWindowsUser("default user"));
    try testing.expect(!isSkippedWindowsUser("alice"));
}
