//! Active task-list id resolution (swarm-tasks-05).
//!
//! Mirrors the reference `getTaskListId` (tasks.ts:199-210) and the
//! leader-binding mutators (tasks.ts:25-47). A "task list" is the per-team
//! namespace under which a swarm's tasks live, so a team's tasks are isolated
//! from the global list and can renumber from 1.
//!
//! Resolution order (first non-empty wins):
//!   1. `ZCODE_TASK_LIST_ID` env var (explicit per-process override; the
//!      reference reads a teammate-context env too -- a teammate process is
//!      spawned with this set so its task ops resolve to the leader's list).
//!   2. The process-global `leader_team_name`, set by `teamCreate` via
//!      `setLeaderTeamName`. This is what binds the leader's task ops to the
//!      team's directory.
//!   3. The fallback literal `"tasklist"` (the un-teamed default list).
//!
//! The returned id is always run through `sanitize` so it is safe to use as a
//! single filesystem path component (no traversal, no separators).

const std = @import("std");
const rt = @import("zcode_runtime");
const env = @import("env.zig");

/// Fallback list id when no env override and no bound leader team exist.
/// Matches the reference default ("tasklist") so an un-teamed session keeps a
/// single stable list directory.
pub const DEFAULT_LIST_ID = "tasklist";

/// Env var that pins the active task list id for a process. A spawned teammate
/// inherits this so its task ops resolve to the leader's list.
pub const ENV_TASK_LIST_ID = "ZCODE_TASK_LIST_ID";

/// Process-global leader team binding. `teamCreate` sets this so the leader's
/// subsequent task ops resolve to `state/tasks/<team>`. Guarded by `mutex`
/// because background teammate threads may read it concurrently with the main
/// loop mutating it.
var leader_team_name: ?[]u8 = null;
var mutex: std.Io.Mutex = .init;

/// Bind the leader to `name` (the sanitized team name). Replaces any prior
/// binding. The stored copy is owned by `allocator`; the caller keeps no
/// reference. Idempotent enough -- re-binding to the same name just re-copies.
pub fn setLeaderTeamName(allocator: std.mem.Allocator, name: []const u8) !void {
    const copy = try allocator.dupe(u8, name);
    mutex.lock(rt.io) catch {};
    defer mutex.unlock(rt.io);
    if (leader_team_name) |old| allocator.free(old);
    leader_team_name = copy;
}

/// Clear the leader binding (e.g. on team delete / session end). Frees the
/// stored copy with `allocator`.
pub fn clearLeaderTeamName(allocator: std.mem.Allocator) void {
    mutex.lock(rt.io) catch {};
    defer mutex.unlock(rt.io);
    if (leader_team_name) |old| allocator.free(old);
    leader_team_name = null;
}

/// True when a leader team is currently bound. Used by one-team-per-leader
/// enforcement (swarm-tasks-07).
pub fn hasLeaderTeam() bool {
    mutex.lock(rt.io) catch {};
    defer mutex.unlock(rt.io);
    return leader_team_name != null;
}

/// Return an owned copy of the bound leader team name, or null when unbound.
/// Caller frees.
pub fn leaderTeamNameAlloc(allocator: std.mem.Allocator) !?[]u8 {
    mutex.lock(rt.io) catch {};
    defer mutex.unlock(rt.io);
    const name = leader_team_name orelse return null;
    return try allocator.dupe(u8, name);
}

/// Resolve the active task list id (owned slice the caller frees), already
/// sanitized to a safe single path component. Env override wins, then the
/// bound leader team, then the default.
pub fn resolveAlloc(allocator: std.mem.Allocator) ![]u8 {
    if (env.getenv(ENV_TASK_LIST_ID)) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len > 0) return sanitizeAlloc(allocator, trimmed);
    }
    {
        mutex.lock(rt.io) catch {};
        defer mutex.unlock(rt.io);
        if (leader_team_name) |name| {
            // `name` is already sanitized by `setLeaderTeamName`'s caller, but
            // re-sanitize defensively so a malformed env-less binding can never
            // produce a traversal component.
            return sanitizeAlloc(allocator, name);
        }
    }
    return allocator.dupe(u8, DEFAULT_LIST_ID);
}

/// Sanitize `raw` into a safe single filesystem path component: keep
/// alphanumerics, `-`, `_`, `.`; replace anything else with `-`; collapse a
/// leading/trailing run that would render the component `.`/`..`; fall back to
/// the default when the result is empty. Caller frees.
pub fn sanitizeAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    var buf = try allocator.alloc(u8, @max(trimmed.len, DEFAULT_LIST_ID.len));
    errdefer allocator.free(buf);

    var n: usize = 0;
    for (trimmed) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.') {
            buf[n] = ch;
        } else {
            buf[n] = '-';
        }
        n += 1;
    }

    const slice = buf[0..n];
    // A bare "." or ".." would escape the tasks dir; reject and fall back.
    if (n == 0 or std.mem.eql(u8, slice, ".") or std.mem.eql(u8, slice, "..")) {
        allocator.free(buf);
        return allocator.dupe(u8, DEFAULT_LIST_ID);
    }
    return allocator.realloc(buf, n) catch slice;
}

const testing = std.testing;

test "resolveAlloc falls back to the default list id with no env and no leader" {
    clearLeaderTeamName(testing.allocator);
    const id = try resolveAlloc(testing.allocator);
    defer testing.allocator.free(id);
    try testing.expectEqualStrings(DEFAULT_LIST_ID, id);
}

test "resolveAlloc uses the bound leader team name" {
    try setLeaderTeamName(testing.allocator, "alpha");
    defer clearLeaderTeamName(testing.allocator);

    const id = try resolveAlloc(testing.allocator);
    defer testing.allocator.free(id);
    try testing.expectEqualStrings("alpha", id);
}

test "setLeaderTeamName replaces a prior binding without leaking" {
    try setLeaderTeamName(testing.allocator, "first");
    try setLeaderTeamName(testing.allocator, "second");
    defer clearLeaderTeamName(testing.allocator);

    const id = try resolveAlloc(testing.allocator);
    defer testing.allocator.free(id);
    try testing.expectEqualStrings("second", id);
    try testing.expect(hasLeaderTeam());
}

test "sanitizeAlloc rejects traversal forms and replaces separators" {
    {
        const s = try sanitizeAlloc(testing.allocator, "team/name");
        defer testing.allocator.free(s);
        try testing.expectEqualStrings("team-name", s);
    }
    {
        const s = try sanitizeAlloc(testing.allocator, "..");
        defer testing.allocator.free(s);
        try testing.expectEqualStrings(DEFAULT_LIST_ID, s);
    }
    {
        const s = try sanitizeAlloc(testing.allocator, "");
        defer testing.allocator.free(s);
        try testing.expectEqualStrings(DEFAULT_LIST_ID, s);
    }
    {
        const s = try sanitizeAlloc(testing.allocator, "ok-name_1.2");
        defer testing.allocator.free(s);
        try testing.expectEqualStrings("ok-name_1.2", s);
    }
}
