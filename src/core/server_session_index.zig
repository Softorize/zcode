//! Persisted server session index for the direct-connect server (Phase 12,
//! Task 20 / remote-server-03).
//!
//! The direct-connect server (Task 19) allocates a session per `POST /sessions`
//! and streams it over a WebSocket. So a detached session can survive a daemon
//! restart and be resumed, we persist per-session metadata to a JSON index file
//! (`~/.zcode/daemon/server-sessions.json`). This is separate from the daemon
//! `State` (pid/port/token) that lives next to it.
//!
//! Reference behavior + file:line:
//!   server/types.ts:26  SessionState (starting/running/detached/stopping/stopped)
//!   server/types.ts:33  SessionInfo
//!   server/types.ts:46  SessionIndexEntry (persisted to server-sessions.json)
//!   server/types.ts:13  ServerConfig idleTimeoutMs / maxSessions / workspace
//!
//! Design choice: load/save take an explicit absolute file path so the module
//! is unit-testable against a tmp dir without depending on $HOME resolution.
//! The daemon resolves the real `~/.zcode/daemon/server-sessions.json` path and
//! passes it in. The write is atomic (temp + rename) to survive a crash
//! mid-write, mirroring the task store and the daemon state writer.

const std = @import("std");
const rt = @import("zcode_runtime");
const std_io = @import("std_io.zig");
const rng = @import("rng.zig");

/// Lifecycle state of a server session. Mirrors the reference SessionState
/// union (server/types.ts:26).
pub const SessionState = enum {
    starting,
    running,
    detached,
    stopping,
    stopped,

    pub fn toString(self: SessionState) []const u8 {
        return switch (self) {
            .starting => "starting",
            .running => "running",
            .detached => "detached",
            .stopping => "stopping",
            .stopped => "stopped",
        };
    }

    pub fn fromString(s: []const u8) ?SessionState {
        if (std.mem.eql(u8, s, "starting")) return .starting;
        if (std.mem.eql(u8, s, "running")) return .running;
        if (std.mem.eql(u8, s, "detached")) return .detached;
        if (std.mem.eql(u8, s, "stopping")) return .stopping;
        if (std.mem.eql(u8, s, "stopped")) return .stopped;
        return null;
    }
};

/// One persisted session record. All string fields are owned by the entry (the
/// owning `SessionIndex` frees them in `deinit`). Mirrors the reference
/// SessionIndexEntry (server/types.ts:46).
pub const SessionIndexEntry = struct {
    /// The direct-connect session id (e.g. "dc-abc123").
    session_id: []u8,
    /// The transcript / replay session id this maps to (Phase 5 store). May be
    /// empty when the session has not produced a transcript yet.
    transcript_session_id: []u8,
    /// The working directory the session runs in.
    cwd: []u8,
    /// The permission mode in effect (e.g. "default", "bypassPermissions").
    permission_mode: []u8,
    /// Creation wall-clock time, milliseconds since the epoch.
    created_ts: i64,
    /// Last-activity wall-clock time, milliseconds since the epoch. The idle
    /// sweep compares this against `idle_timeout_ms`.
    last_active_ts: i64,
    state: SessionState,

    fn deinit(self: *SessionIndexEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.transcript_session_id);
        allocator.free(self.cwd);
        allocator.free(self.permission_mode);
    }
};

/// An owned, in-memory copy of the on-disk session index. The daemon loads it
/// on start, mutates it as sessions come and go, and saves it back atomically.
pub const SessionIndex = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(SessionIndexEntry),

    pub fn init(allocator: std.mem.Allocator) SessionIndex {
        return .{ .allocator = allocator, .entries = .empty };
    }

    pub fn deinit(self: *SessionIndex) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    /// Find an entry by session id; returns a mutable pointer (valid until the
    /// next mutation that reallocates the backing list) or null.
    pub fn find(self: *SessionIndex, session_id: []const u8) ?*SessionIndexEntry {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.session_id, session_id)) return entry;
        }
        return null;
    }

    /// Count entries that are not in a terminal (`stopped`) state. Used to
    /// enforce `max_sessions`.
    pub fn activeCount(self: *const SessionIndex) usize {
        var n: usize = 0;
        for (self.entries.items) |entry| {
            if (entry.state != .stopped) n += 1;
        }
        return n;
    }

    /// Insert a new entry or update the matching one in place. All string
    /// inputs are duplicated; the index owns the copies. On update, the new
    /// scalar fields and (non-empty) string fields replace the old ones.
    pub fn upsert(
        self: *SessionIndex,
        session_id: []const u8,
        transcript_session_id: []const u8,
        cwd: []const u8,
        permission_mode: []const u8,
        created_ts: i64,
        last_active_ts: i64,
        state: SessionState,
    ) !void {
        if (self.find(session_id)) |entry| {
            // Replace mutable scalar fields; refresh the strings that change
            // over a session's life (transcript id, permission mode).
            entry.last_active_ts = last_active_ts;
            entry.state = state;
            try replaceOwned(self.allocator, &entry.transcript_session_id, transcript_session_id);
            try replaceOwned(self.allocator, &entry.permission_mode, permission_mode);
            try replaceOwned(self.allocator, &entry.cwd, cwd);
            return;
        }

        const dup_id = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(dup_id);
        const dup_transcript = try self.allocator.dupe(u8, transcript_session_id);
        errdefer self.allocator.free(dup_transcript);
        const dup_cwd = try self.allocator.dupe(u8, cwd);
        errdefer self.allocator.free(dup_cwd);
        const dup_mode = try self.allocator.dupe(u8, permission_mode);
        errdefer self.allocator.free(dup_mode);

        try self.entries.append(self.allocator, .{
            .session_id = dup_id,
            .transcript_session_id = dup_transcript,
            .cwd = dup_cwd,
            .permission_mode = dup_mode,
            .created_ts = created_ts,
            .last_active_ts = last_active_ts,
            .state = state,
        });
    }

    /// Update only the state of an existing entry, refreshing `last_active_ts`
    /// when the new state is a live one. Returns false if no such entry.
    pub fn setState(self: *SessionIndex, session_id: []const u8, state: SessionState, now_ms: i64) bool {
        const entry = self.find(session_id) orelse return false;
        entry.state = state;
        if (state == .running or state == .starting) entry.last_active_ts = now_ms;
        return true;
    }

    /// Serialize the index to its JSON form. The caller owns the returned
    /// slice. Pure (no IO) so the on-disk shape is unit-testable.
    pub fn serialize(self: *const SessionIndex, allocator: std.mem.Allocator) ![]u8 {
        var out = std_io.StringBuilder.init(allocator);
        defer out.deinit();
        const w = out.writer();
        try w.writeAll("{\"sessions\":[");
        for (self.entries.items, 0..) |entry, i| {
            if (i != 0) try w.writeByte(',');
            try w.writeAll("{\"session_id\":");
            try writeJsonString(w, entry.session_id);
            try w.writeAll(",\"transcript_session_id\":");
            try writeJsonString(w, entry.transcript_session_id);
            try w.writeAll(",\"cwd\":");
            try writeJsonString(w, entry.cwd);
            try w.writeAll(",\"permission_mode\":");
            try writeJsonString(w, entry.permission_mode);
            try w.print(",\"created_ts\":{d}", .{entry.created_ts});
            try w.print(",\"last_active_ts\":{d}", .{entry.last_active_ts});
            try w.writeAll(",\"state\":");
            try writeJsonString(w, entry.state.toString());
            try w.writeByte('}');
        }
        try w.writeAll("]}\n");
        return allocator.dupe(u8, out.items());
    }
};

fn replaceOwned(allocator: std.mem.Allocator, slot: *[]u8, new_value: []const u8) !void {
    const dup = try allocator.dupe(u8, new_value);
    allocator.free(slot.*);
    slot.* = dup;
}

/// Load the index from `path`. Returns an empty index when the file does not
/// exist. The caller owns the returned index and must `deinit` it.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !SessionIndex {
    var index = SessionIndex.init(allocator);
    errdefer index.deinit();

    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return index,
        else => return err,
    };
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return index;
    defer parsed.deinit();
    if (parsed.value != .object) return index;

    // Take the object by pointer (CLAUDE.md ObjectMap rule): never value-copy.
    const obj = &parsed.value.object;
    const sessions = obj.get("sessions") orelse return index;
    if (sessions != .array) return index;

    for (sessions.array.items) |item| {
        if (item != .object) continue;
        const item_obj = &item.object;
        const session_id = getString(item_obj, "session_id") orelse continue;
        const state_str = getString(item_obj, "state") orelse "stopped";
        const state = SessionState.fromString(state_str) orelse .stopped;
        try index.upsert(
            session_id,
            getString(item_obj, "transcript_session_id") orelse "",
            getString(item_obj, "cwd") orelse "",
            getString(item_obj, "permission_mode") orelse "default",
            getInteger(item_obj, "created_ts") orelse 0,
            getInteger(item_obj, "last_active_ts") orelse 0,
            state,
        );
    }
    return index;
}

/// Atomically persist the index to `path` (temp file + rename). Creates the
/// parent directory if missing.
pub fn save(allocator: std.mem.Allocator, path: []const u8, index: *const SessionIndex) !void {
    if (std.fs.path.dirname(path)) |parent| {
        @import("paths.zig").ensureDir(parent) catch {};
    }

    const body = try index.serialize(allocator);
    defer allocator.free(body);

    var nonce: [8]u8 = undefined;
    rng.bytes(&nonce);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{x}{x}{x}{x}{x}{x}{x}{x}", .{
        path, nonce[0], nonce[1], nonce[2], nonce[3], nonce[4], nonce[5], nonce[6], nonce[7],
    });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, body);
        file.sync(rt.io) catch {};
    }
    try std.Io.Dir.renameAbsolute(tmp_path, path, rt.io);
}

/// True when `entry` has been idle past `idle_timeout_ms`. An `idle_timeout_ms`
/// of 0 means "never time out" (matches the reference convention), so this
/// always returns false in that case. Already-stopped entries are not flagged.
pub fn isIdle(entry: SessionIndexEntry, now_ms: i64, idle_timeout_ms: u64) bool {
    if (idle_timeout_ms == 0) return false;
    if (entry.state == .stopped) return false;
    const elapsed = now_ms - entry.last_active_ts;
    if (elapsed < 0) return false;
    return @as(u64, @intCast(elapsed)) >= idle_timeout_ms;
}

/// True when creating one more session would exceed `max_sessions`. A
/// `max_sessions` of 0 means "unlimited" (matches the reference convention).
pub fn atCapacity(index: *const SessionIndex, max_sessions: usize) bool {
    if (max_sessions == 0) return false;
    return index.activeCount() >= max_sessions;
}

fn getString(obj: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getInteger(obj: *const std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

const testing = std.testing;
const test_helpers = @import("test_helpers.zig");

test "SessionState round-trips through strings" {
    const all = [_]SessionState{ .starting, .running, .detached, .stopping, .stopped };
    for (all) |s| {
        try testing.expectEqual(s, SessionState.fromString(s.toString()).?);
    }
    try testing.expect(SessionState.fromString("nope") == null);
}

test "write two entries, reload, all fields round-trip" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(dir);
    const path = try std.fs.path.join(allocator, &.{ dir, "server-sessions.json" });
    defer allocator.free(path);

    var index = SessionIndex.init(allocator);
    defer index.deinit();
    try index.upsert("dc-a", "trans-a", "/work/a", "default", 1000, 1500, .running);
    try index.upsert("dc-b", "trans-b", "/work/b", "bypassPermissions", 2000, 2500, .detached);

    try save(allocator, path, &index);

    var reloaded = try load(allocator, path);
    defer reloaded.deinit();
    try testing.expectEqual(@as(usize, 2), reloaded.entries.items.len);

    const a = reloaded.find("dc-a").?;
    try testing.expectEqualStrings("trans-a", a.transcript_session_id);
    try testing.expectEqualStrings("/work/a", a.cwd);
    try testing.expectEqualStrings("default", a.permission_mode);
    try testing.expectEqual(@as(i64, 1000), a.created_ts);
    try testing.expectEqual(@as(i64, 1500), a.last_active_ts);
    try testing.expectEqual(SessionState.running, a.state);

    const b = reloaded.find("dc-b").?;
    try testing.expectEqualStrings("trans-b", b.transcript_session_id);
    try testing.expectEqualStrings("/work/b", b.cwd);
    try testing.expectEqualStrings("bypassPermissions", b.permission_mode);
    try testing.expectEqual(@as(i64, 2000), b.created_ts);
    try testing.expectEqual(@as(i64, 2500), b.last_active_ts);
    try testing.expectEqual(SessionState.detached, b.state);
}

test "state transitions starting->running->detached->stopped are persisted" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(dir);
    const path = try std.fs.path.join(allocator, &.{ dir, "server-sessions.json" });
    defer allocator.free(path);

    {
        var index = SessionIndex.init(allocator);
        defer index.deinit();
        try index.upsert("dc-x", "", "/w", "default", 10, 10, .starting);
        try save(allocator, path, &index);
    }
    {
        var index = try load(allocator, path);
        defer index.deinit();
        try testing.expectEqual(SessionState.starting, index.find("dc-x").?.state);
        try testing.expect(index.setState("dc-x", .running, 20));
        try save(allocator, path, &index);
    }
    {
        var index = try load(allocator, path);
        defer index.deinit();
        try testing.expectEqual(SessionState.running, index.find("dc-x").?.state);
        try testing.expect(index.setState("dc-x", .detached, 30));
        try save(allocator, path, &index);
    }
    {
        var index = try load(allocator, path);
        defer index.deinit();
        try testing.expectEqual(SessionState.detached, index.find("dc-x").?.state);
        try testing.expect(index.setState("dc-x", .stopped, 40));
        try save(allocator, path, &index);
    }
    {
        var index = try load(allocator, path);
        defer index.deinit();
        try testing.expectEqual(SessionState.stopped, index.find("dc-x").?.state);
    }
}

test "idle-timeout helper flags stale entries and respects unlimited" {
    const allocator = testing.allocator;
    var index = SessionIndex.init(allocator);
    defer index.deinit();
    try index.upsert("dc-old", "", "/w", "default", 0, 1000, .running);
    const entry = index.find("dc-old").?.*;

    // now=11000, idle window=5000ms -> elapsed 10000 >= 5000 -> idle.
    try testing.expect(isIdle(entry, 11000, 5000));
    // now=4000 -> elapsed 3000 < 5000 -> not idle.
    try testing.expect(!isIdle(entry, 4000, 5000));
    // idle_timeout_ms=0 means never time out.
    try testing.expect(!isIdle(entry, 1_000_000, 0));

    // A stopped entry is never flagged idle.
    try testing.expect(index.setState("dc-old", .stopped, 1000));
    const stopped = index.find("dc-old").?.*;
    try testing.expect(!isIdle(stopped, 1_000_000, 5000));
}

test "max-sessions capacity honors unlimited and ignores stopped" {
    const allocator = testing.allocator;
    var index = SessionIndex.init(allocator);
    defer index.deinit();
    try index.upsert("dc-1", "", "/w", "default", 0, 0, .running);
    try index.upsert("dc-2", "", "/w", "default", 0, 0, .detached);

    try testing.expect(!atCapacity(&index, 0)); // unlimited
    try testing.expect(atCapacity(&index, 2)); // two active -> at cap
    try testing.expect(!atCapacity(&index, 3)); // room for one more

    // A stopped session does not count toward the active total.
    try testing.expect(index.setState("dc-2", .stopped, 0));
    try testing.expect(!atCapacity(&index, 2)); // one active < 2
    try testing.expectEqual(@as(usize, 1), index.activeCount());
}

test "upsert updates an existing entry in place" {
    const allocator = testing.allocator;
    var index = SessionIndex.init(allocator);
    defer index.deinit();
    try index.upsert("dc-u", "", "/old", "default", 100, 100, .starting);
    try index.upsert("dc-u", "trans-u", "/new", "bypassPermissions", 100, 250, .running);

    try testing.expectEqual(@as(usize, 1), index.entries.items.len);
    const e = index.find("dc-u").?;
    try testing.expectEqualStrings("trans-u", e.transcript_session_id);
    try testing.expectEqualStrings("/new", e.cwd);
    try testing.expectEqualStrings("bypassPermissions", e.permission_mode);
    try testing.expectEqual(@as(i64, 250), e.last_active_ts);
    try testing.expectEqual(SessionState.running, e.state);
}
