const std = @import("std");
const rt = @import("zcode_runtime");
const clock = @import("../core/clock.zig");
const std_io = @import("../core/std_io.zig");
const rng = @import("../core/rng.zig");
const word_slug = @import("../core/word_slug.zig");
const task = @import("task.zig");
const task_list_id = @import("../core/task_list_id.zig");
const helpers = @import("helpers.zig");
const teammate_mailbox = @import("teammate_mailbox.zig");
const swarm_message = @import("../core/swarm_message.zig");
const teammate = @import("../core/teammate.zig");

const TEAMS_SUBPATH = helpers.TEAMS_SUBPATH;
const MESSAGES_SUBPATH = helpers.MESSAGES_SUBPATH;

/// Bound on the unique-name word-slug retry loop (swarm-tasks-07). The slug
/// space is ~9.7M three-word combinations, so hitting this cap means the teams
/// dir is pathologically full; we surface an error rather than spinning.
const MAX_SLUG_RETRIES = 16;

/// Process-global registry of team names created this session (swarm-tasks-07).
/// Mirrors the reference `sessionCreatedTeams` Set (teamHelpers.ts:560-590): a
/// team created via `teamCreate` is tracked here so the session-end path can
/// auto-clean it (the `.team` file + the per-team task dir) unless the user
/// explicitly `teamDelete`'d it first. Guarded by `registry_mutex` because
/// background teammate threads may create/delete teams concurrently with the
/// main loop running cleanup.
var session_created_teams: ?std.array_list.Managed([]u8) = null;
var registry_mutex: std.Io.Mutex = .init;

fn registryList() *std.array_list.Managed([]u8) {
    if (session_created_teams == null) {
        session_created_teams = std.array_list.Managed([]u8).init(rt.gpa);
    }
    return &session_created_teams.?;
}

/// Record `team_name` (already sanitized) for end-of-session cleanup. Mirrors
/// `registerTeamForSessionCleanup` (teamHelpers.ts:560). Idempotent: a name
/// already present is not added twice. The stored copy is owned by `rt.gpa`.
fn registerTeamForSessionCleanup(team_name: []const u8) !void {
    registry_mutex.lock(rt.io) catch {};
    defer registry_mutex.unlock(rt.io);
    const list = registryList();
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, team_name)) return;
    }
    try list.append(try rt.gpa.dupe(u8, team_name));
}

/// Drop `team_name` from cleanup tracking (e.g. after an explicit `teamDelete`,
/// so shutdown does not try to delete it again). Mirrors
/// `unregisterTeamForSessionCleanup` (teamHelpers.ts:568).
fn unregisterTeamForSessionCleanup(team_name: []const u8) void {
    registry_mutex.lock(rt.io) catch {};
    defer registry_mutex.unlock(rt.io);
    const list = registryList();
    var i: usize = 0;
    while (i < list.items.len) {
        if (std.mem.eql(u8, list.items[i], team_name)) {
            const removed = list.swapRemove(i);
            rt.gpa.free(removed);
            continue;
        }
        i += 1;
    }
}

/// Delete every session-registered team that was not explicitly removed:
/// for each, unlink the `.team` file, its message log, and the per-team task
/// dir, then clear the registry. Mirrors `cleanupSessionTeams` +
/// `cleanupTeamDirectories` (teamHelpers.ts:576-683). Best-effort: a team that
/// fails to delete is skipped, never aborting the rest. Called from the
/// session-end path. Safe to call with an empty registry (no-op).
pub fn cleanupRegisteredTeams(allocator: std.mem.Allocator, cwd: []const u8) void {
    // Snapshot the names under the lock, then release it before doing the
    // (slower) filesystem work so a background thread is not blocked on us.
    var names = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit();
    }
    {
        registry_mutex.lock(rt.io) catch {};
        defer registry_mutex.unlock(rt.io);
        const list = registryList();
        for (list.items) |item| {
            const copy = allocator.dupe(u8, item) catch continue;
            names.append(copy) catch {
                allocator.free(copy);
                continue;
            };
        }
        for (list.items) |item| rt.gpa.free(item);
        list.clearRetainingCapacity();
    }

    for (names.items) |team_name| {
        cleanupTeamDirectories(allocator, cwd, team_name);
    }
}

/// Remove the on-disk artifacts of a single team: the `.team` file, the team
/// message log, and the per-team task list directory. Best-effort; logs at
/// debug on failure but never errors (cleanup must not crash shutdown).
fn cleanupTeamDirectories(allocator: std.mem.Allocator, cwd: []const u8, team_name: []const u8) void {
    if (!helpers.isSafeIdentifier(team_name)) return;

    const team_file = std.fmt.allocPrint(allocator, "{s}.team", .{team_name}) catch return;
    defer allocator.free(team_file);
    if (helpers.workspacePathAlloc(allocator, cwd, TEAMS_SUBPATH)) |teams_dir| {
        defer allocator.free(teams_dir);
        const team_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ teams_dir, team_file }) catch return;
        defer allocator.free(team_path);
        std.Io.Dir.cwd().deleteFile(rt.io, team_path) catch {};
    } else |_| {}

    const msg_file = std.fmt.allocPrint(allocator, "{s}.log", .{team_name}) catch return;
    defer allocator.free(msg_file);
    if (helpers.workspacePathAlloc(allocator, cwd, MESSAGES_SUBPATH)) |msg_dir| {
        defer allocator.free(msg_dir);
        const msg_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ msg_dir, msg_file }) catch return;
        defer allocator.free(msg_path);
        std.Io.Dir.cwd().deleteFile(rt.io, msg_path) catch {};
    } else |_| {}

    // The task list dir is keyed by the sanitized team name; remove the whole
    // tree (mirrors the reference's `rm(tasksDir, { recursive: true })`).
    if (task_list_id.sanitizeAlloc(allocator, team_name)) |list_id| {
        defer allocator.free(list_id);
        if (helpers.tasksSubpathForListAlloc(allocator, list_id)) |rel| {
            defer allocator.free(rel);
            if (helpers.workspacePathAlloc(allocator, cwd, rel)) |dir| {
                defer allocator.free(dir);
                std.Io.Dir.cwd().deleteTree(rt.io, dir) catch {};
            } else |_| {}
        } else |_| {}
    } else |_| {}
}

/// The seeded leader member name (swarm-tasks-06). Mirrors the reference, which
/// records the session leader as "team-lead" so peers can address it and so
/// SendMessage broadcast can skip the sender by name.
pub const LEAD_MEMBER_NAME = "team-lead";

/// A structured per-member record in the team file (swarm-tasks-06). Mirrors
/// the reference `TeamFile.members[]` (TeamCreateTool.ts:157-175) and the
/// TeammateIdentity/SpawnConfig shape (swarm/backends/types.ts:191-225).
/// Every string field is owned by the same allocator that built the
/// `TeamFile`; free via `TeamFile.deinit`.
pub const TeamMember = struct {
    agent_id: []u8,
    name: []u8,
    agent_type: []u8,
    model: []u8,
    joined_ts: i64,
    tmux_pane_id: []u8,
    backend_type: []u8,
    cwd: []u8,
    subscriptions: [][]u8,
};

/// The parsed team file. Owns every nested allocation; free via `deinit`.
pub const TeamFile = struct {
    name: []u8,
    description: []u8,
    created_ts: i64,
    lead_agent_id: []u8,
    lead_session_id: []u8,
    members: []TeamMember,

    pub fn deinit(self: *TeamFile, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.lead_agent_id);
        allocator.free(self.lead_session_id);
        for (self.members) |member| freeMember(allocator, member);
        allocator.free(self.members);
    }

    /// Return a borrowed pointer to the member whose `name` matches
    /// (case-sensitive, mirroring the reference name lookup), or null when no
    /// member matches. The returned pointer is valid for the lifetime of the
    /// `TeamFile`.
    pub fn findMemberByName(self: *const TeamFile, name: []const u8) ?*const TeamMember {
        for (self.members) |*member| {
            if (std.mem.eql(u8, member.name, name)) return member;
        }
        return null;
    }
};

fn freeMember(allocator: std.mem.Allocator, member: TeamMember) void {
    allocator.free(member.agent_id);
    allocator.free(member.name);
    allocator.free(member.agent_type);
    allocator.free(member.model);
    allocator.free(member.tmux_pane_id);
    allocator.free(member.backend_type);
    allocator.free(member.cwd);
    for (member.subscriptions) |sub| allocator.free(sub);
    allocator.free(member.subscriptions);
}

pub fn teamCreate(allocator: std.mem.Allocator, cwd: []const u8, name: []const u8, members: []const u8) ![]u8 {
    const requested = std.mem.trim(u8, name, " \t\r\n");
    if (!helpers.isSafeIdentifier(requested)) {
        return allocator.dupe(u8, "invalid team name: use letters/numbers/._- only");
    }

    // One-team-per-leader (swarm-tasks-07): a leader that already bound a team
    // (via a prior teamCreate in this session) cannot create a second one.
    // Mirrors the reference throw (TeamCreateTool.ts:132-143). The bound name
    // lives in the same process-global as `leader_team_name` (Task 5).
    if (try task_list_id.leaderTeamNameAlloc(allocator)) |existing| {
        defer allocator.free(existing);
        return std.fmt.allocPrint(allocator, "already leading team \"{s}\": a leader can only manage one team at a time. Use TeamDelete to end the current team before creating a new one.", .{existing});
    }

    const teams_dir = try helpers.ensureWorkspaceDirPath(allocator, cwd, TEAMS_SUBPATH);
    defer allocator.free(teams_dir);

    // Unique-name fallback (swarm-tasks-07): if the requested team file already
    // exists, generate a fresh word-slug name instead of erroring. Mirrors
    // `generateUniqueTeamName` (TeamCreateTool.ts:64-72). The loop is bounded
    // so a pathologically full teams dir surfaces an error rather than hanging.
    const team_name = try resolveUniqueTeamName(allocator, teams_dir, requested);
    defer allocator.free(team_name);

    const team_path = try std.fmt.allocPrint(allocator, "{s}/{s}.team", .{ teams_dir, team_name });
    defer allocator.free(team_path);

    // Seed the leader member (swarm-tasks-06): a structured record named
    // "team-lead", running in the workspace cwd, with no subscriptions yet. The
    // optional `members` arg carries a free-text agent_type hint (kept for the
    // dispatch back-compat); empty means an unspecified type.
    const now = clock.nowSeconds();
    const lead_type = std.mem.trim(u8, members, " \t\r\n");
    const lead = TeamMember{
        .agent_id = try allocator.dupe(u8, ""),
        .name = try allocator.dupe(u8, LEAD_MEMBER_NAME),
        .agent_type = try allocator.dupe(u8, lead_type),
        .model = try allocator.dupe(u8, ""),
        .joined_ts = now,
        .tmux_pane_id = try allocator.dupe(u8, ""),
        .backend_type = try allocator.dupe(u8, ""),
        .cwd = try allocator.dupe(u8, cwd),
        .subscriptions = try allocator.alloc([]u8, 0),
    };

    var team_file = TeamFile{
        .name = try allocator.dupe(u8, team_name),
        .description = try allocator.dupe(u8, ""),
        .created_ts = now,
        .lead_agent_id = try allocator.dupe(u8, ""),
        .lead_session_id = try allocator.dupe(u8, ""),
        .members = try allocator.alloc(TeamMember, 1),
    };
    team_file.members[0] = lead;
    defer team_file.deinit(allocator);

    try writeTeamFile(allocator, team_path, &team_file);

    // Team == task list (swarm-tasks-05). Scope this team's tasks to a per-team
    // directory (`state/tasks/<team>`) that renumbers from 1, reset it so a
    // re-created team starts clean (the high-water-mark still prevents id
    // reuse), and bind the leader so its subsequent task ops resolve there.
    const list_id = try task_list_id.sanitizeAlloc(allocator, team_name);
    defer allocator.free(list_id);
    try task.resetTaskList(allocator, cwd, list_id);
    try task_list_id.setLeaderTeamName(allocator, list_id);

    // Track for session-end cleanup (swarm-tasks-07): teams created this session
    // are auto-removed on exit unless explicitly TeamDelete'd. The sanitized
    // list id is what cleanup re-derives the paths from, so register that form.
    registerTeamForSessionCleanup(list_id) catch {};

    return std.fmt.allocPrint(allocator, "team created: {s}", .{team_name});
}

/// Return an owned team name that does not yet collide with an existing
/// `.team` file under `teams_dir`. If `requested` is free, returns a copy of
/// it; otherwise generates word-slug names until a free one is found (bounded
/// by `MAX_SLUG_RETRIES`). Mirrors `generateUniqueTeamName`
/// (TeamCreateTool.ts:64-72). Caller frees.
fn resolveUniqueTeamName(allocator: std.mem.Allocator, teams_dir: []const u8, requested: []const u8) ![]u8 {
    if (!teamFileExists(allocator, teams_dir, requested)) {
        return allocator.dupe(u8, requested);
    }

    var seed_bytes: [8]u8 = undefined;
    rng.bytes(&seed_bytes);
    var prng = std.Random.DefaultPrng.init(std.mem.readInt(u64, &seed_bytes, .little));
    const random = prng.random();

    var retry: usize = 0;
    while (retry < MAX_SLUG_RETRIES) : (retry += 1) {
        const slug = try word_slug.generateSlugAlloc(allocator, random);
        if (!teamFileExists(allocator, teams_dir, slug)) return slug;
        allocator.free(slug);
    }
    return error.TeamNameExhausted;
}

fn teamFileExists(allocator: std.mem.Allocator, teams_dir: []const u8, team_name: []const u8) bool {
    const path = std.fmt.allocPrint(allocator, "{s}/{s}.team", .{ teams_dir, team_name }) catch return true;
    defer allocator.free(path);
    if (std.Io.Dir.cwd().access(rt.io, path, .{})) |_| {
        return true;
    } else |_| {
        return false;
    }
}

pub fn teamDelete(allocator: std.mem.Allocator, cwd: []const u8, name: []const u8) ![]u8 {
    const team_name = std.mem.trim(u8, name, " \t\r\n");
    if (!helpers.isSafeIdentifier(team_name)) {
        return allocator.dupe(u8, "invalid team name: use letters/numbers/._- only");
    }

    const team_file = try std.fmt.allocPrint(allocator, "{s}.team", .{team_name});
    defer allocator.free(team_file);
    const team_rel = try std.fs.path.join(allocator, &.{ TEAMS_SUBPATH, team_file });
    defer allocator.free(team_rel);
    const team_path = try helpers.workspacePathAlloc(allocator, cwd, team_rel);
    defer allocator.free(team_path);
    std.Io.Dir.cwd().deleteFile(rt.io, team_path) catch return allocator.dupe(u8, "team not found");

    const msg_file = try std.fmt.allocPrint(allocator, "{s}.log", .{team_name});
    defer allocator.free(msg_file);
    const msg_rel = try std.fs.path.join(allocator, &.{ MESSAGES_SUBPATH, msg_file });
    defer allocator.free(msg_rel);
    const msg_path = try helpers.workspacePathAlloc(allocator, cwd, msg_rel);
    defer allocator.free(msg_path);
    std.Io.Dir.cwd().deleteFile(rt.io, msg_path) catch {};

    // Already cleaned up explicitly: drop from session cleanup so shutdown does
    // not double-delete (swarm-tasks-07), and release the leader binding so the
    // leader can create a new team afterward (mirrors the reference, where
    // TeamDelete ends the current team). The registry/binding key is the
    // sanitized name; re-derive it to match what teamCreate stored.
    const list_id = try task_list_id.sanitizeAlloc(allocator, team_name);
    defer allocator.free(list_id);
    unregisterTeamForSessionCleanup(list_id);
    if (try task_list_id.leaderTeamNameAlloc(allocator)) |bound| {
        defer allocator.free(bound);
        if (std.mem.eql(u8, bound, list_id)) task_list_id.clearLeaderTeamName(allocator);
    }

    return std.fmt.allocPrint(allocator, "team deleted: {s}", .{team_name});
}

/// Read and parse the team file at `path`. JSON documents (begin with `{`)
/// carry the full structured member list; anything else is the legacy
/// `key=value` format (parsed with an empty member list) so old `.team` files
/// still load. Caller frees via `TeamFile.deinit`.
pub fn readTeamFile(allocator: std.mem.Allocator, path: []const u8, fallback_name: []const u8) !TeamFile {
    const data = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(data);
    return parseTeamFileBytes(allocator, data, fallback_name);
}

/// Parse a team file body (used directly by tests and the repl overlay).
pub fn parseTeamFileBytes(allocator: std.mem.Allocator, data: []const u8, fallback_name: []const u8) !TeamFile {
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    if (trimmed.len > 0 and trimmed[0] == '{') {
        return parseJsonTeamFile(allocator, trimmed, fallback_name);
    }
    return parseLegacyTeamFile(allocator, data, fallback_name);
}

fn parseJsonTeamFile(allocator: std.mem.Allocator, data: []const u8, fallback_name: []const u8) !TeamFile {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidTeamFile;
    // CLAUDE.md ObjectMap rule: take the object by pointer; do not value-copy it
    // (a copy desyncs the entries pointer if anything reallocates).
    const obj = &parsed.value.object;

    var team_file = TeamFile{
        .name = try allocator.dupe(u8, fallback_name),
        .description = try allocator.dupe(u8, ""),
        .created_ts = 0,
        .lead_agent_id = try allocator.dupe(u8, ""),
        .lead_session_id = try allocator.dupe(u8, ""),
        .members = try allocator.alloc(TeamMember, 0),
    };
    errdefer team_file.deinit(allocator);

    if (jsonGetString(obj, "name")) |v| try helpers.replaceOwned(allocator, &team_file.name, v);
    if (jsonGetString(obj, "description")) |v| try helpers.replaceOwned(allocator, &team_file.description, v);
    if (jsonGetString(obj, "lead_agent_id")) |v| try helpers.replaceOwned(allocator, &team_file.lead_agent_id, v);
    if (jsonGetString(obj, "lead_session_id")) |v| try helpers.replaceOwned(allocator, &team_file.lead_session_id, v);
    if (jsonGetInt(obj, "created_ts")) |n| team_file.created_ts = n;

    if (obj.get("members")) |members_val| {
        if (members_val == .array) {
            var list = std.array_list.Managed(TeamMember).init(allocator);
            errdefer {
                for (list.items) |member| freeMember(allocator, member);
                list.deinit();
            }
            for (members_val.array.items) |item| {
                if (item != .object) continue;
                const member = try parseMember(allocator, &item.object);
                try list.append(member);
            }
            allocator.free(team_file.members);
            team_file.members = try list.toOwnedSlice();
        }
    }

    return team_file;
}

fn parseMember(allocator: std.mem.Allocator, obj: *const std.json.ObjectMap) !TeamMember {
    var member = TeamMember{
        .agent_id = try allocator.dupe(u8, ""),
        .name = try allocator.dupe(u8, ""),
        .agent_type = try allocator.dupe(u8, ""),
        .model = try allocator.dupe(u8, ""),
        .joined_ts = 0,
        .tmux_pane_id = try allocator.dupe(u8, ""),
        .backend_type = try allocator.dupe(u8, ""),
        .cwd = try allocator.dupe(u8, ""),
        .subscriptions = try allocator.alloc([]u8, 0),
    };
    errdefer freeMember(allocator, member);

    if (jsonGetString(obj, "agent_id")) |v| try helpers.replaceOwned(allocator, &member.agent_id, v);
    if (jsonGetString(obj, "name")) |v| try helpers.replaceOwned(allocator, &member.name, v);
    if (jsonGetString(obj, "agent_type")) |v| try helpers.replaceOwned(allocator, &member.agent_type, v);
    if (jsonGetString(obj, "model")) |v| try helpers.replaceOwned(allocator, &member.model, v);
    if (jsonGetString(obj, "tmux_pane_id")) |v| try helpers.replaceOwned(allocator, &member.tmux_pane_id, v);
    if (jsonGetString(obj, "backend_type")) |v| try helpers.replaceOwned(allocator, &member.backend_type, v);
    if (jsonGetString(obj, "cwd")) |v| try helpers.replaceOwned(allocator, &member.cwd, v);
    if (jsonGetInt(obj, "joined_ts")) |n| member.joined_ts = n;

    if (obj.get("subscriptions")) |subs_val| {
        allocator.free(member.subscriptions);
        member.subscriptions = try jsonStringArray(allocator, subs_val);
    }

    return member;
}

/// Legacy `key=value` team file: only `name`, `members` (opaque), and
/// `created_ts` were stored. The structured member list comes back empty
/// (mirrors the back-compat note in the plan); the opaque `members` string is
/// dropped since the structured form supersedes it. The overlay tolerates zero
/// members.
fn parseLegacyTeamFile(allocator: std.mem.Allocator, data: []const u8, fallback_name: []const u8) !TeamFile {
    var team_file = TeamFile{
        .name = try allocator.dupe(u8, fallback_name),
        .description = try allocator.dupe(u8, ""),
        .created_ts = 0,
        .lead_agent_id = try allocator.dupe(u8, ""),
        .lead_session_id = try allocator.dupe(u8, ""),
        .members = try allocator.alloc(TeamMember, 0),
    };
    errdefer team_file.deinit(allocator);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_idx], " \t");
        const value = std.mem.trim(u8, line[eq_idx + 1 ..], " \t");
        if (std.mem.eql(u8, key, "name")) {
            try helpers.replaceOwned(allocator, &team_file.name, value);
        } else if (std.mem.eql(u8, key, "created_ts")) {
            team_file.created_ts = std.fmt.parseInt(i64, value, 10) catch team_file.created_ts;
        }
    }

    return team_file;
}

/// Append a member to the team file at `path`, then rewrite it atomically.
/// No-op-safe to call with a fresh member; the leader is seeded at create time.
pub fn addMember(allocator: std.mem.Allocator, path: []const u8, fallback_name: []const u8, member: TeamMember) !void {
    var team_file = try readTeamFile(allocator, path, fallback_name);
    defer team_file.deinit(allocator);

    const grown = try allocator.alloc(TeamMember, team_file.members.len + 1);
    @memcpy(grown[0..team_file.members.len], team_file.members);
    grown[team_file.members.len] = member;
    allocator.free(team_file.members);
    team_file.members = grown;

    try writeTeamFile(allocator, path, &team_file);
}

fn writeTeamFile(allocator: std.mem.Allocator, path: []const u8, team_file: *const TeamFile) !void {
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    const w = buf.writer();

    try w.writeAll("{\n  ");
    try writeJsonStringField(w, "name", team_file.name);
    try w.writeAll(",\n  ");
    try writeJsonStringField(w, "description", team_file.description);
    try w.writeAll(",\n  ");
    try w.print("\"created_ts\": {d}", .{team_file.created_ts});
    try w.writeAll(",\n  ");
    try writeJsonStringField(w, "lead_agent_id", team_file.lead_agent_id);
    try w.writeAll(",\n  ");
    try writeJsonStringField(w, "lead_session_id", team_file.lead_session_id);
    try w.writeAll(",\n  \"members\": [");
    for (team_file.members, 0..) |member, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("\n    {\n      ");
        try writeJsonStringField(w, "agent_id", member.agent_id);
        try w.writeAll(",\n      ");
        try writeJsonStringField(w, "name", member.name);
        try w.writeAll(",\n      ");
        try writeJsonStringField(w, "agent_type", member.agent_type);
        try w.writeAll(",\n      ");
        try writeJsonStringField(w, "model", member.model);
        try w.writeAll(",\n      ");
        try w.print("\"joined_ts\": {d}", .{member.joined_ts});
        try w.writeAll(",\n      ");
        try writeJsonStringField(w, "tmux_pane_id", member.tmux_pane_id);
        try w.writeAll(",\n      ");
        try writeJsonStringField(w, "backend_type", member.backend_type);
        try w.writeAll(",\n      ");
        try writeJsonStringField(w, "cwd", member.cwd);
        try w.writeAll(",\n      ");
        try writeJsonStringArrayField(w, "subscriptions", member.subscriptions);
        try w.writeAll("\n    }");
    }
    if (team_file.members.len != 0) try w.writeAll("\n  ");
    try w.writeAll("]\n}\n");

    try writeTeamFileAtomic(allocator, path, buf.items());
}

fn writeTeamFileAtomic(allocator: std.mem.Allocator, target: []const u8, bytes: []const u8) !void {
    var nonce: [8]u8 = undefined;
    @import("../core/rng.zig").bytes(&nonce);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{x}{x}{x}{x}{x}{x}{x}{x}", .{
        target, nonce[0], nonce[1], nonce[2], nonce[3], nonce[4], nonce[5], nonce[6], nonce[7],
    });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, bytes);
        file.sync(rt.io) catch {};
    }
    try std.Io.Dir.renameAbsolute(tmp_path, target, rt.io);
}

fn writeJsonStringField(w: anytype, key: []const u8, value: []const u8) !void {
    try w.print("\"{s}\": ", .{key});
    try std.json.Stringify.value(value, .{}, w);
}

fn writeJsonStringArrayField(w: anytype, key: []const u8, list: []const []u8) !void {
    try w.print("\"{s}\": [", .{key});
    for (list, 0..) |item, idx| {
        if (idx != 0) try w.writeAll(", ");
        try std.json.Stringify.value(item, .{}, w);
    }
    try w.writeByte(']');
}

fn jsonGetString(obj: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn jsonGetInt(obj: *const std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        .string => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t\r\n"), 10) catch null,
        else => null,
    };
}

fn jsonStringArray(allocator: std.mem.Allocator, value: std.json.Value) ![][]u8 {
    if (value != .array) return allocator.alloc([]u8, 0);
    var out = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit();
    }
    for (value.array.items) |item| {
        if (item != .string) continue;
        try out.append(try allocator.dupe(u8, item.string));
    }
    return out.toOwnedSlice();
}

const testing = std.testing;

test "teamCreate rejects invalid names" {
    const result = try teamCreate(testing.allocator, "/tmp", "../escape", "user1");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("invalid team name: use letters/numbers/._- only", result);
}

test "teamDelete rejects invalid names" {
    const result = try teamDelete(testing.allocator, "/tmp", "bad name!");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("invalid team name: use letters/numbers/._- only", result);
}

test "teamCreate binds the leader and tasks number from 1 in the team dir" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    // Start from a clean leader binding so resolution is deterministic, and
    // restore it afterward (the binding is process-global).
    task_list_id.clearLeaderTeamName(allocator);
    defer task_list_id.clearLeaderTeamName(allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const created = try teamCreate(allocator, cwd, "alpha", "");
    defer allocator.free(created);
    try testing.expectEqualStrings("team created: alpha", created);

    // The per-team task dir exists.
    const team_tasks_dir = try helpers.workspacePathAlloc(allocator, cwd, "state/tasks/alpha");
    defer allocator.free(team_tasks_dir);
    try std.Io.Dir.cwd().access(rt.io, team_tasks_dir, .{});

    // The leader is now bound to "alpha", so task ops resolve there and the
    // first task numbers from 1.
    const first = try task.taskCreate(allocator, cwd, "First task", "", "");
    defer allocator.free(first);
    try testing.expect(std.mem.indexOf(u8, first, "id=1\n") != null);
}

test "resetTaskList prevents id reuse via the high-water-mark" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    task_list_id.clearLeaderTeamName(allocator);
    defer task_list_id.clearLeaderTeamName(allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    // Bind to a team list and create two tasks (ids 1 and 2).
    try task_list_id.setLeaderTeamName(allocator, "beta");

    const t1 = try task.taskCreate(allocator, cwd, "One", "", "");
    defer allocator.free(t1);
    try testing.expect(std.mem.indexOf(u8, t1, "id=1\n") != null);
    const t2 = try task.taskCreate(allocator, cwd, "Two", "", "");
    defer allocator.free(t2);
    try testing.expect(std.mem.indexOf(u8, t2, "id=2\n") != null);

    // Reset the list (deletes the .task files, records hwm=2).
    try task.resetTaskList(allocator, cwd, "beta");

    // The next create must NOT reuse id 1 or 2 -- it resumes past the hwm.
    const t3 = try task.taskCreate(allocator, cwd, "Three", "", "");
    defer allocator.free(t3);
    try testing.expect(std.mem.indexOf(u8, t3, "id=3\n") != null);
}

test "teamCreate seeds exactly one team-lead member with the workspace cwd" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    task_list_id.clearLeaderTeamName(allocator);
    defer task_list_id.clearLeaderTeamName(allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const created = try teamCreate(allocator, cwd, "gamma", "");
    defer allocator.free(created);

    const team_path = try helpers.workspacePathAlloc(allocator, cwd, "state/teams/gamma.team");
    defer allocator.free(team_path);

    var team_file = try readTeamFile(allocator, team_path, "gamma");
    defer team_file.deinit(allocator);

    try testing.expectEqualStrings("gamma", team_file.name);
    try testing.expectEqual(@as(usize, 1), team_file.members.len);
    try testing.expectEqualStrings("team-lead", team_file.members[0].name);
    try testing.expectEqualStrings(cwd, team_file.members[0].cwd);
    try testing.expectEqual(@as(usize, 0), team_file.members[0].subscriptions.len);
}

test "findMemberByName resolves the seeded lead and returns null for unknown" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    task_list_id.clearLeaderTeamName(allocator);
    defer task_list_id.clearLeaderTeamName(allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const created = try teamCreate(allocator, cwd, "delta", "");
    defer allocator.free(created);

    const team_path = try helpers.workspacePathAlloc(allocator, cwd, "state/teams/delta.team");
    defer allocator.free(team_path);

    var team_file = try readTeamFile(allocator, team_path, "delta");
    defer team_file.deinit(allocator);

    const lead = team_file.findMemberByName("team-lead");
    try testing.expect(lead != null);
    try testing.expectEqualStrings("team-lead", lead.?.name);
    try testing.expect(team_file.findMemberByName("nobody") == null);
}

test "addMember appends a structured member that reads back" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    task_list_id.clearLeaderTeamName(allocator);
    defer task_list_id.clearLeaderTeamName(allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const created = try teamCreate(allocator, cwd, "epsilon", "");
    defer allocator.free(created);

    const team_path = try helpers.workspacePathAlloc(allocator, cwd, "state/teams/epsilon.team");
    defer allocator.free(team_path);

    var subs = try allocator.alloc([]u8, 1);
    subs[0] = try allocator.dupe(u8, "tasks");
    const worker = TeamMember{
        .agent_id = try allocator.dupe(u8, "agent-7"),
        .name = try allocator.dupe(u8, "worker"),
        .agent_type = try allocator.dupe(u8, "coder"),
        .model = try allocator.dupe(u8, "sonnet"),
        .joined_ts = 42,
        .tmux_pane_id = try allocator.dupe(u8, "%3"),
        .backend_type = try allocator.dupe(u8, "in-process"),
        .cwd = try allocator.dupe(u8, cwd),
        .subscriptions = subs,
    };
    try addMember(allocator, team_path, "epsilon", worker);

    var team_file = try readTeamFile(allocator, team_path, "epsilon");
    defer team_file.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), team_file.members.len);

    const found = team_file.findMemberByName("worker").?;
    try testing.expectEqualStrings("agent-7", found.agent_id);
    try testing.expectEqualStrings("coder", found.agent_type);
    try testing.expectEqualStrings("sonnet", found.model);
    try testing.expectEqual(@as(i64, 42), found.joined_ts);
    try testing.expectEqualStrings("%3", found.tmux_pane_id);
    try testing.expectEqualStrings("in-process", found.backend_type);
    try testing.expectEqual(@as(usize, 1), found.subscriptions.len);
    try testing.expectEqualStrings("tasks", found.subscriptions[0]);
}

test "legacy key=value team file still parses with an empty member list" {
    const allocator = testing.allocator;
    const legacy = "name=legacyteam\nmembers=alice,bob\ncreated_ts=1234\n";
    var team_file = try parseTeamFileBytes(allocator, legacy, "fallback");
    defer team_file.deinit(allocator);

    try testing.expectEqualStrings("legacyteam", team_file.name);
    try testing.expectEqual(@as(i64, 1234), team_file.created_ts);
    try testing.expectEqual(@as(usize, 0), team_file.members.len);
}

// Test-only: empty the process-global session-cleanup registry so a test that
// asserts on registry contents is not polluted by names registered by other
// teamCreate tests running earlier in the same process.
fn resetRegistryForTest() void {
    registry_mutex.lock(rt.io) catch {};
    defer registry_mutex.unlock(rt.io);
    const list = registryList();
    for (list.items) |item| rt.gpa.free(item);
    list.clearRetainingCapacity();
}

fn registryContains(team_name: []const u8) bool {
    registry_mutex.lock(rt.io) catch {};
    defer registry_mutex.unlock(rt.io);
    const list = registryList();
    for (list.items) |item| {
        if (std.mem.eql(u8, item, team_name)) return true;
    }
    return false;
}

test "teamCreate refuses a second team while a leader is already bound" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    task_list_id.clearLeaderTeamName(allocator);
    defer task_list_id.clearLeaderTeamName(allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    // First create binds the leader to "alpha".
    const first = try teamCreate(allocator, cwd, "alpha", "");
    defer allocator.free(first);
    try testing.expectEqualStrings("team created: alpha", first);

    // Second create (any name) must be refused with the already-leading error
    // and must NOT write a beta.team file.
    const second = try teamCreate(allocator, cwd, "beta", "");
    defer allocator.free(second);
    try testing.expect(std.mem.indexOf(u8, second, "already leading team \"alpha\"") != null);

    const beta_path = try helpers.workspacePathAlloc(allocator, cwd, "state/teams/beta.team");
    defer allocator.free(beta_path);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(rt.io, beta_path, .{}));
}

test "teamCreate generates a unique word-slug name when the requested one exists" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    task_list_id.clearLeaderTeamName(allocator);
    defer task_list_id.clearLeaderTeamName(allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    // Create "alpha" once, then clear the leader binding (simulating a fresh
    // session that reuses the same workspace) so the one-team-per-leader gate
    // does not short-circuit the second create.
    const first = try teamCreate(allocator, cwd, "alpha", "");
    defer allocator.free(first);
    try testing.expectEqualStrings("team created: alpha", first);
    task_list_id.clearLeaderTeamName(allocator);

    // Second create with the SAME requested name: alpha.team already exists, so
    // a word-slug name is generated instead of erroring.
    const second = try teamCreate(allocator, cwd, "alpha", "");
    defer allocator.free(second);
    const prefix = "team created: ";
    try testing.expect(std.mem.startsWith(u8, second, prefix));
    const generated = second[prefix.len..];
    // The generated name differs from "alpha" and is a valid identifier.
    try testing.expect(!std.mem.eql(u8, generated, "alpha"));
    try testing.expect(helpers.isSafeIdentifier(generated));

    // Both team files now exist on disk.
    const alpha_path = try helpers.workspacePathAlloc(allocator, cwd, "state/teams/alpha.team");
    defer allocator.free(alpha_path);
    try std.Io.Dir.cwd().access(rt.io, alpha_path, .{});

    const gen_rel = try std.fmt.allocPrint(allocator, "state/teams/{s}.team", .{generated});
    defer allocator.free(gen_rel);
    const gen_path = try helpers.workspacePathAlloc(allocator, cwd, gen_rel);
    defer allocator.free(gen_path);
    try std.Io.Dir.cwd().access(rt.io, gen_path, .{});
}

test "cleanupRegisteredTeams removes the team file and the task dir" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    task_list_id.clearLeaderTeamName(allocator);
    defer task_list_id.clearLeaderTeamName(allocator);
    resetRegistryForTest();
    defer resetRegistryForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const created = try teamCreate(allocator, cwd, "zeta", "");
    defer allocator.free(created);
    try testing.expectEqualStrings("team created: zeta", created);

    // teamCreate registered "zeta" for cleanup and created its task dir.
    try testing.expect(registryContains("zeta"));
    const team_path = try helpers.workspacePathAlloc(allocator, cwd, "state/teams/zeta.team");
    defer allocator.free(team_path);
    try std.Io.Dir.cwd().access(rt.io, team_path, .{});
    const task_dir = try helpers.workspacePathAlloc(allocator, cwd, "state/tasks/zeta");
    defer allocator.free(task_dir);
    try std.Io.Dir.cwd().access(rt.io, task_dir, .{});

    // Cleanup removes the .team file and the per-team task dir, and clears the
    // registry.
    cleanupRegisteredTeams(allocator, cwd);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(rt.io, team_path, .{}));
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(rt.io, task_dir, .{}));
    try testing.expect(!registryContains("zeta"));
}

test "teamDelete unregisters the team and releases the leader binding" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    task_list_id.clearLeaderTeamName(allocator);
    defer task_list_id.clearLeaderTeamName(allocator);
    resetRegistryForTest();
    defer resetRegistryForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const created = try teamCreate(allocator, cwd, "omega", "");
    defer allocator.free(created);
    try testing.expect(registryContains("omega"));
    try testing.expect(task_list_id.hasLeaderTeam());

    const deleted = try teamDelete(allocator, cwd, "omega");
    defer allocator.free(deleted);
    try testing.expectEqualStrings("team deleted: omega", deleted);

    // Explicit delete drops the cleanup registration and frees the leader so a
    // new team can be created.
    try testing.expect(!registryContains("omega"));
    try testing.expect(!task_list_id.hasLeaderTeam());
}

/// Route a SendMessage to a teammate inbox (swarm-tasks-08). `to` selects the
/// recipient:
///   - a bare name -> write a single record to that member's inbox
///     (`state/messages/<team>/<name>.inbox`).
///   - `"*"` -> broadcast to every structured team member except the sender
///     (case-insensitive name compare, mirroring SendMessageTool.ts:222).
///   - empty / null -> back-compat: no directed inbox, only the legacy
///     team-wide log append.
/// The legacy team-wide log (`state/messages/<team>.log`) is always appended
/// for observability (the plan keeps it as a fallback), regardless of routing.
pub fn sendMessage(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    team: []const u8,
    from: []const u8,
    to: []const u8,
    message: []const u8,
    summary: []const u8,
) ![]u8 {
    const team_name = std.mem.trim(u8, team, " \t\r\n");
    if (!helpers.isSafeIdentifier(team_name)) {
        return allocator.dupe(u8, "invalid team name: use letters/numbers/._- only");
    }
    const from_name = std.mem.trim(u8, from, " \t\r\n");
    if (from_name.len == 0 or from_name.len > 128) {
        return allocator.dupe(u8, "invalid sender name");
    }
    const to_name = std.mem.trim(u8, to, " \t\r\n");

    // Classify the message: plain text or a structured protocol object
    // (shutdown_request / shutdown_response / plan_approval_response). The pure
    // parser/validator lives in core/swarm_message.zig (swarm-tasks-09).
    var parsed = try swarm_message.parse(allocator, message);
    defer parsed.deinit(allocator);

    if (parsed.isStructured()) {
        // Structured messages have their own validation + routing (no broadcast,
        // no team-wide log noise, shutdown_response only to team-lead, etc.).
        if (swarm_message.validate(parsed, to_name)) |verr| {
            return allocator.dupe(u8, verr);
        }
        if (to_name.len == 0 or !helpers.isSafeIdentifier(to_name)) {
            return allocator.dupe(u8, "invalid recipient name: use letters/numbers/._- only");
        }
        return deliverStructured(allocator, cwd, team_name, from_name, to_name, parsed, message, summary);
    }

    // Always append the legacy team-wide log for back-compat observability.
    try appendTeamLog(allocator, cwd, team_name, from_name, message);

    if (to_name.len == 0) {
        return std.fmt.allocPrint(allocator, "message sent to {s}", .{team_name});
    }

    if (std.mem.eql(u8, to_name, "*")) {
        return broadcastMessage(allocator, cwd, team_name, from_name, message, summary);
    }

    if (!helpers.isSafeIdentifier(to_name)) {
        return allocator.dupe(u8, "invalid recipient name: use letters/numbers/._- only");
    }
    teammate_mailbox.writeToMailbox(allocator, cwd, team_name, to_name, from_name, message, summary) catch |err| {
        return std.fmt.allocPrint(allocator, "failed to deliver to {s}: {s}", .{ to_name, @errorName(err) });
    };
    return std.fmt.allocPrint(allocator, "message sent to {s}'s inbox", .{to_name});
}

/// Deliver an already-validated structured message to a single teammate inbox
/// and trigger any protocol side effect. Mirrors the reference handlers
/// (SendMessageTool.ts:268-518): the raw structured JSON is written as the
/// mailbox record `text` so the receiving teammate can re-parse it. The abort
/// side effect for `shutdown_response.approve` is stubbed here until the
/// in-process teammate lifecycle lands (swarm-tasks-13); see `signalTeammateAbort`.
fn deliverStructured(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    team_name: []const u8,
    from_name: []const u8,
    to_name: []const u8,
    msg: swarm_message.SwarmMessage,
    raw_message: []const u8,
    summary: []const u8,
) ![]u8 {
    teammate_mailbox.writeToMailbox(allocator, cwd, team_name, to_name, from_name, raw_message, summary) catch |err| {
        return std.fmt.allocPrint(allocator, "failed to deliver to {s}: {s}", .{ to_name, @errorName(err) });
    };

    switch (msg) {
        .shutdown_request => return std.fmt.allocPrint(allocator, "shutdown request sent to {s}", .{to_name}),
        .shutdown_response => |r| {
            // An approval addressed to team-lead asks the responding teammate to
            // stop. The actual abort is wired in swarm-tasks-13; for now this is
            // a no-op so the protocol + storage land independently.
            if (r.approve) signalTeammateAbort(from_name);
            return std.fmt.allocPrint(allocator, "shutdown response sent to {s}", .{to_name});
        },
        .plan_approval_response => |r| {
            const verb = if (r.approve) "approved" else "rejected";
            return std.fmt.allocPrint(allocator, "plan {s} for {s}", .{ verb, to_name });
        },
        .plain => unreachable,
    }
}

/// Signal a graceful shutdown to the named in-process teammate
/// (swarm-tasks-13). Looks the teammate up in the process-global live registry
/// and flips its abort flag; the teammate's run loop observes it at the next
/// round boundary via `shouldStop` and exits cleanly. A no-op when no live
/// teammate is registered under that name (e.g. it already finished, or the
/// teammate runs out-of-process).
fn signalTeammateAbort(agent_name: []const u8) void {
    _ = teammate.requestShutdownByName(agent_name);
}

/// Write `message` to every team member's inbox except the sender (matched
/// case-insensitively on name). Mirrors `handleBroadcast`
/// (SendMessageTool.ts:191-266). Returns a summary of who received it.
fn broadcastMessage(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    team_name: []const u8,
    from_name: []const u8,
    message: []const u8,
    summary: []const u8,
) ![]u8 {
    const team_file_path = try teamFilePathAlloc(allocator, cwd, team_name);
    defer allocator.free(team_file_path);

    var team_file = readTeamFile(allocator, team_file_path, team_name) catch {
        return std.fmt.allocPrint(allocator, "team \"{s}\" does not exist", .{team_name});
    };
    defer team_file.deinit(allocator);

    var recipients = std.array_list.Managed([]const u8).init(allocator);
    defer recipients.deinit();
    for (team_file.members) |member| {
        if (member.name.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(member.name, from_name)) continue;
        try recipients.append(member.name);
    }

    if (recipients.items.len == 0) {
        return allocator.dupe(u8, "no teammates to broadcast to (you are the only team member)");
    }

    for (recipients.items) |name| {
        if (!helpers.isSafeIdentifier(name)) continue;
        teammate_mailbox.writeToMailbox(allocator, cwd, team_name, name, from_name, message, summary) catch {};
    }

    var joined = std_io.StringBuilder.init(allocator);
    defer joined.deinit();
    for (recipients.items, 0..) |name, idx| {
        if (idx != 0) try joined.appendSlice(", ");
        try joined.appendSlice(name);
    }
    return std.fmt.allocPrint(allocator, "message broadcast to {d} teammate(s): {s}", .{ recipients.items.len, joined.items() });
}

/// Absolute path to a team's `.team` file. Caller frees.
fn teamFilePathAlloc(allocator: std.mem.Allocator, cwd: []const u8, team_name: []const u8) ![]u8 {
    const team_file = try std.fmt.allocPrint(allocator, "{s}.team", .{team_name});
    defer allocator.free(team_file);
    const team_rel = try std.fs.path.join(allocator, &.{ TEAMS_SUBPATH, team_file });
    defer allocator.free(team_rel);
    return helpers.workspacePathAlloc(allocator, cwd, team_rel);
}

/// Append a line to the legacy team-wide log (`state/messages/<team>.log`).
/// Uses O_APPEND so two concurrent sub-agents sendMessage-ing to the same team
/// cannot interleave halves of each other's records.
fn appendTeamLog(allocator: std.mem.Allocator, cwd: []const u8, team_name: []const u8, from_name: []const u8, message: []const u8) !void {
    const msg_dir = try helpers.ensureWorkspaceDirPath(allocator, cwd, MESSAGES_SUBPATH);
    defer allocator.free(msg_dir);
    const msg_path = try std.fmt.allocPrint(allocator, "{s}/{s}.log", .{ msg_dir, team_name });
    defer allocator.free(msg_path);

    const file = try openAppendFile(msg_path);
    defer file.close(rt.io);
    try std_io.fileWriter(file).print("[{d}] {s}: {s}\n", .{ clock.nowSeconds(), from_name, message });
}

fn openAppendFile(path: []const u8) !std.Io.File {
    if (@import("builtin").os.tag == .windows) {
        const file = try std.Io.Dir.cwd().createFile(rt.io, path, .{ .read = true, .truncate = false });
        errdefer file.close(rt.io);
        // 0.16: no seek; subsequent writes go positional
        return file;
    }
    const flags: std.posix.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
    };
    const fd = try std_io.openFlagsAlloc(rt.gpa, path, flags, 0o600);
    return std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
}

fn freshMember(allocator: std.mem.Allocator, name: []const u8, cwd: []const u8) !TeamMember {
    return TeamMember{
        .agent_id = try allocator.dupe(u8, ""),
        .name = try allocator.dupe(u8, name),
        .agent_type = try allocator.dupe(u8, ""),
        .model = try allocator.dupe(u8, ""),
        .joined_ts = 0,
        .tmux_pane_id = try allocator.dupe(u8, ""),
        .backend_type = try allocator.dupe(u8, ""),
        .cwd = try allocator.dupe(u8, cwd),
        .subscriptions = try allocator.alloc([]u8, 0),
    };
}

test "sendMessage to a named teammate writes a single inbox record" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    task_list_id.clearLeaderTeamName(allocator);
    defer task_list_id.clearLeaderTeamName(allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const created = try teamCreate(allocator, cwd, "alpha", "");
    defer allocator.free(created);

    const result = try sendMessage(allocator, cwd, "alpha", "team-lead", "bob", "do the thing", "task");
    defer allocator.free(result);
    try testing.expectEqualStrings("message sent to bob's inbox", result);

    const inbox = try teammate_mailbox.readMailbox(allocator, cwd, "alpha", "bob");
    defer teammate_mailbox.freeMessages(allocator, inbox);
    try testing.expectEqual(@as(usize, 1), inbox.len);
    try testing.expectEqualStrings("team-lead", inbox[0].from);
    try testing.expectEqualStrings("do the thing", inbox[0].text);
    try testing.expectEqualStrings("task", inbox[0].summary);
}

test "sendMessage broadcast writes to every member except the sender" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    task_list_id.clearLeaderTeamName(allocator);
    defer task_list_id.clearLeaderTeamName(allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const created = try teamCreate(allocator, cwd, "alpha", "");
    defer allocator.free(created);

    // The team seeds "team-lead"; add alice and bob so the team has three members.
    const team_path = try helpers.workspacePathAlloc(allocator, cwd, "state/teams/alpha.team");
    defer allocator.free(team_path);
    try addMember(allocator, team_path, "alpha", try freshMember(allocator, "alice", cwd));
    try addMember(allocator, team_path, "alpha", try freshMember(allocator, "bob", cwd));

    // Broadcast from team-lead: alice and bob receive it, team-lead does not.
    const result = try sendMessage(allocator, cwd, "alpha", "team-lead", "*", "stand up", "sync");
    defer allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "broadcast to 2 teammate(s)") != null);

    const alice_inbox = try teammate_mailbox.readMailbox(allocator, cwd, "alpha", "alice");
    defer teammate_mailbox.freeMessages(allocator, alice_inbox);
    try testing.expectEqual(@as(usize, 1), alice_inbox.len);
    try testing.expectEqualStrings("stand up", alice_inbox[0].text);

    const bob_inbox = try teammate_mailbox.readMailbox(allocator, cwd, "alpha", "bob");
    defer teammate_mailbox.freeMessages(allocator, bob_inbox);
    try testing.expectEqual(@as(usize, 1), bob_inbox.len);

    // team-lead (the sender) gets no inbox.
    const lead_inbox = try teammate_mailbox.readMailbox(allocator, cwd, "alpha", "team-lead");
    defer teammate_mailbox.freeMessages(allocator, lead_inbox);
    try testing.expectEqual(@as(usize, 0), lead_inbox.len);
}

test "sendMessage with no recipient only appends the legacy team log" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    task_list_id.clearLeaderTeamName(allocator);
    defer task_list_id.clearLeaderTeamName(allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const created = try teamCreate(allocator, cwd, "alpha", "");
    defer allocator.free(created);

    const result = try sendMessage(allocator, cwd, "alpha", "team-lead", "", "no direct route", "");
    defer allocator.free(result);
    try testing.expectEqualStrings("message sent to alpha", result);

    // The legacy team log was written.
    const log_path = try helpers.workspacePathAlloc(allocator, cwd, "state/messages/alpha.log");
    defer allocator.free(log_path);
    try std.Io.Dir.cwd().access(rt.io, log_path, .{});
}

test "sendMessage delivers a structured shutdown_request to a teammate inbox" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    task_list_id.clearLeaderTeamName(allocator);
    defer task_list_id.clearLeaderTeamName(allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const created = try teamCreate(allocator, cwd, "alpha", "");
    defer allocator.free(created);

    const payload = "{\"type\":\"shutdown_request\",\"reason\":\"wrap up\"}";
    const result = try sendMessage(allocator, cwd, "alpha", "team-lead", "bob", payload, "");
    defer allocator.free(result);
    try testing.expectEqualStrings("shutdown request sent to bob", result);

    // The raw structured JSON is written to bob's inbox so he can re-parse it.
    const inbox = try teammate_mailbox.readMailbox(allocator, cwd, "alpha", "bob");
    defer teammate_mailbox.freeMessages(allocator, inbox);
    try testing.expectEqual(@as(usize, 1), inbox.len);
    try testing.expectEqualStrings(payload, inbox[0].text);

    // Structured messages do NOT add a team-wide log line (only plain text does).
    const log_path = try helpers.workspacePathAlloc(allocator, cwd, "state/messages/alpha.log");
    defer allocator.free(log_path);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(rt.io, log_path, .{}));
}

test "sendMessage rejects a structured shutdown_response not addressed to team-lead" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    task_list_id.clearLeaderTeamName(allocator);
    defer task_list_id.clearLeaderTeamName(allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const created = try teamCreate(allocator, cwd, "alpha", "");
    defer allocator.free(created);

    const payload = "{\"type\":\"shutdown_response\",\"request_id\":\"r1\",\"approve\":true}";
    const result = try sendMessage(allocator, cwd, "alpha", "bob", "alice", payload, "");
    defer allocator.free(result);
    try testing.expectEqualStrings("shutdown_response must be sent to \"team-lead\"", result);

    // Nothing was delivered to alice.
    const inbox = try teammate_mailbox.readMailbox(allocator, cwd, "alpha", "alice");
    defer teammate_mailbox.freeMessages(allocator, inbox);
    try testing.expectEqual(@as(usize, 0), inbox.len);
}

test "sendMessage refuses to broadcast a structured message" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    task_list_id.clearLeaderTeamName(allocator);
    defer task_list_id.clearLeaderTeamName(allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const created = try teamCreate(allocator, cwd, "alpha", "");
    defer allocator.free(created);

    const payload = "{\"type\":\"shutdown_request\",\"reason\":\"stop\"}";
    const result = try sendMessage(allocator, cwd, "alpha", "team-lead", "*", payload, "");
    defer allocator.free(result);
    try testing.expectEqualStrings("structured messages cannot be broadcast (to: \"*\")", result);
}
