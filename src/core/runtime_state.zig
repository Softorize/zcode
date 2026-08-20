//! Persistent runtime-state store -- a small JSON document under the zcode home
//! holding *derived* runtime counters, kept deliberately separate from the
//! user-authored `config.toml`.
//!
//! The reference's "global config" mixes derived counters (numStartups,
//! tipsHistory, lastReleaseNotesSeen) with user settings. zcode keeps them
//! apart: `config.toml` is hand-editable configuration, while this `state.json`
//! is regenerable derived data. Conflating them would let a user's hand edits
//! clobber counters (and vice versa), so they live in separate files.
//!
//! Every public function is best-effort: a missing or corrupt `state.json`
//! loads as a zero-value default rather than erroring. Writes go through a
//! temp-file + rename so a crash mid-write never leaves a torn document; even
//! a fully lost write is harmless because the data is regenerable.
//!
//! Storage layout (single file, one read/write per operation):
//!
//!   {
//!     "num_startups": 7,
//!     "last_release_notes_seen": "0.11.73",
//!     "tips_history": { "<tip_id>": <startup_number_when_last_shown>, ... },
//!     "projects": { "<project-key>": { "seen_count": 2, "completed": false }, ... }
//!   }
//!
//! The per-project onboarding state is keyed by `kairos_lock.projectKey(cwd)`
//! so it shares the encoding the rest of zcode uses for per-project dirs.

const std = @import("std");
const rt = @import("zcode_runtime");
const paths = @import("paths.zig");
const std_io = @import("std_io.zig");
const rng = @import("rng.zig");
const kairos_lock = @import("kairos_lock.zig");

/// Cap on the state-file read. The document is a handful of small fields; this
/// is a sanity bound so a corrupt/huge file can't blow up the read.
const MAX_STATE_BYTES: usize = 4 * 1024 * 1024;

/// Returned by `sessionsSinceTipShown` when a tip has never been shown. A large
/// value so a never-shown tip always satisfies any cooldown comparison.
pub const NEVER_SHOWN: u64 = std.math.maxInt(u64);

/// Per-project onboarding state. `seen_count` counts how many times the
/// onboarding nudge has been rendered; `completed` records that the project has
/// finished onboarding (created its instruction file).
pub const ProjectOnboarding = struct {
    seen_count: u64 = 0,
    completed: bool = false,
};

/// The in-memory state document. Owns all of its allocations through an
/// internal arena; call `deinit` to free everything at once.
pub const State = struct {
    arena: std.heap.ArenaAllocator,
    num_startups: u64 = 0,
    /// tip_id -> the `num_startups` value at the moment the tip was last shown.
    tips_history: std.StringHashMapUnmanaged(u64) = .empty,
    /// Version string of the release notes the user last saw. Empty = never.
    last_release_notes_seen: []const u8 = "",
    /// project-key -> onboarding state.
    projects: std.StringHashMapUnmanaged(ProjectOnboarding) = .empty,

    /// A zero-value state backed by a fresh arena. Used as the default on a
    /// missing/corrupt file.
    pub fn empty(backing: std.mem.Allocator) State {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn deinit(self: *State) void {
        self.arena.deinit();
    }

    fn alloc(self: *State) std.mem.Allocator {
        return self.arena.allocator();
    }
};

// ===========================================================================
// Public API (resolves the real state.json path)
// ===========================================================================

/// Load the state document. On a missing/corrupt file, returns a zero-value
/// default state (never errors -- the data is regenerable). The returned
/// `State` owns its allocations; the caller must `deinit` it.
pub fn load(backing: std.mem.Allocator) State {
    const path = resolveStatePath(backing) catch return State.empty(backing);
    defer backing.free(path);
    return loadAtPath(backing, path);
}

/// Persist `state` to the real state.json path. Best-effort (swallows errors).
pub fn save(state: *State) void {
    const path = resolveStatePath(state.arena.child_allocator) catch return;
    defer state.arena.child_allocator.free(path);
    saveAtPath(state, path) catch {};
}

/// Load, increment `num_startups`, save, and return the new value. Called once
/// per process start. On any failure returns 1 (treat as a fresh start).
pub fn incrementStartups(backing: std.mem.Allocator) u64 {
    const path = resolveStatePath(backing) catch return 1;
    defer backing.free(path);
    return incrementStartupsAtPath(backing, path);
}

/// Record that `tip_id` was shown at the current `num_startups`. Best-effort.
pub fn recordTipShown(backing: std.mem.Allocator, tip_id: []const u8) void {
    const path = resolveStatePath(backing) catch return;
    defer backing.free(path);
    recordTipShownAtPath(backing, path, tip_id);
}

/// Persist per-project onboarding state for `cwd`. Best-effort.
pub fn setProjectOnboarding(backing: std.mem.Allocator, cwd: []const u8, onboarding: ProjectOnboarding) void {
    const path = resolveStatePath(backing) catch return;
    defer backing.free(path);
    const key = kairos_lock.projectKey(backing, cwd) catch return;
    defer backing.free(key);
    setProjectOnboardingAtPath(backing, path, key, onboarding);
}

// ===========================================================================
// In-memory accessors (IO-free, operate on a loaded State)
// ===========================================================================

/// Sessions (startups) elapsed since `tip_id` was last shown. `NEVER_SHOWN`
/// when the tip has never been shown.
pub fn sessionsSinceTipShown(state: *const State, tip_id: []const u8) u64 {
    const shown_at = state.tips_history.get(tip_id) orelse return NEVER_SHOWN;
    if (state.num_startups <= shown_at) return 0;
    return state.num_startups - shown_at;
}

/// Per-project onboarding state for `project_key`, defaulting to the zero value
/// when the project has no recorded state.
pub fn getProjectOnboarding(state: *const State, project_key: []const u8) ProjectOnboarding {
    return state.projects.get(project_key) orelse .{};
}

/// The last-seen release-notes version string, or empty when never seen.
pub fn getLastReleaseNotesSeen(state: *const State) []const u8 {
    return state.last_release_notes_seen;
}

/// Set the last-seen release-notes version on a loaded state (duped into the
/// state's arena so the caller's slice need not outlive the call). Caller is
/// responsible for persisting via `save`.
pub fn setLastReleaseNotesSeen(state: *State, version: []const u8) void {
    const owned = state.alloc().dupe(u8, version) catch return;
    state.last_release_notes_seen = owned;
}

// ===========================================================================
// Path-injected variants (testable without touching the real ~/.zcode)
// ===========================================================================

/// Load the state document from an explicit `path`. Missing/corrupt => default.
pub fn loadAtPath(backing: std.mem.Allocator, path: []const u8) State {
    var state = State.empty(backing);
    const data = std.Io.Dir.cwd().readFileAlloc(rt.io, path, backing, .limited(MAX_STATE_BYTES)) catch return state;
    defer backing.free(data);
    parseInto(&state, data) catch {
        // Reset to a clean default on any parse failure so a partially
        // populated state never leaks through.
        state.deinit();
        return State.empty(backing);
    };
    return state;
}

/// Persist `state` to an explicit `path` via temp-file + rename.
pub fn saveAtPath(state: *State, path: []const u8) !void {
    const backing = state.arena.child_allocator;

    if (std.fs.path.dirname(path)) |dir| {
        paths.ensureDir(dir) catch {};
    }

    var buf = std_io.StringBuilder.init(backing);
    defer buf.deinit();
    try serialize(state, buf.writer());

    const nonce = rng.int(u64);
    const tmp_path = try std.fmt.allocPrint(backing, "{s}.tmp.{x}", .{ path, nonce });
    defer backing.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};
    {
        const flags: std.posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
        const fd = try std_io.openFlagsAlloc(backing, tmp_path, flags, 0o600);
        const tmp = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
        defer tmp.close(rt.io);
        try tmp.writeStreamingAll(rt.io, buf.items());
        tmp.sync(rt.io) catch {};
    }
    try std.Io.Dir.renameAbsolute(tmp_path, path, rt.io);
}

/// `incrementStartups` against an explicit path. Returns the new count, or 1 on
/// any failure (treat as a fresh start).
pub fn incrementStartupsAtPath(backing: std.mem.Allocator, path: []const u8) u64 {
    var state = loadAtPath(backing, path);
    defer state.deinit();
    state.num_startups += 1;
    saveAtPath(&state, path) catch {};
    return state.num_startups;
}

/// `recordTipShown` against an explicit path. Best-effort.
pub fn recordTipShownAtPath(backing: std.mem.Allocator, path: []const u8, tip_id: []const u8) void {
    var state = loadAtPath(backing, path);
    defer state.deinit();
    const owned_id = state.alloc().dupe(u8, tip_id) catch return;
    state.tips_history.put(state.alloc(), owned_id, state.num_startups) catch return;
    saveAtPath(&state, path) catch {};
}

/// `setProjectOnboarding` against an explicit path with a pre-encoded key.
pub fn setProjectOnboardingAtPath(backing: std.mem.Allocator, path: []const u8, project_key: []const u8, onboarding: ProjectOnboarding) void {
    var state = loadAtPath(backing, path);
    defer state.deinit();
    const owned_key = state.alloc().dupe(u8, project_key) catch return;
    state.projects.put(state.alloc(), owned_key, onboarding) catch return;
    saveAtPath(&state, path) catch {};
}

// ===========================================================================
// Private -- path resolution
// ===========================================================================

/// Resolve the real `state.json` path under the zcode home. Public so callers
/// in sibling modules (e.g. `onboarding.zig`) can route their own
/// load/modify/save sequences through the same file the rest of this module
/// uses. Caller owns the returned slice.
pub fn resolveStatePath(allocator: std.mem.Allocator) ![]u8 {
    var path_set = try paths.resolve(allocator);
    defer path_set.deinit(allocator);
    return std.fs.path.join(allocator, &.{ path_set.zcode_home, "state.json" });
}

// ===========================================================================
// Private -- (de)serialization (pure over a byte slice; unit-tested)
// ===========================================================================

/// Parse `data` into `state`, populating its arena-owned maps. Tolerant of
/// missing fields and unknown keys (forward-compatible). A non-object root or a
/// JSON syntax error propagates as an error so `loadAtPath` can fall back to a
/// clean default.
fn parseInto(state: *State, data: []const u8) !void {
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    if (trimmed.len == 0) return; // empty file => zero-value default

    var parsed = try std.json.parseFromSlice(std.json.Value, state.arena.child_allocator, trimmed, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.NotAnObject;
    const root = parsed.value.object;

    if (root.get("num_startups")) |v| {
        if (v == .integer and v.integer >= 0) state.num_startups = @intCast(v.integer);
    }
    if (root.get("last_release_notes_seen")) |v| {
        if (v == .string) state.last_release_notes_seen = try state.alloc().dupe(u8, v.string);
    }
    if (root.get("tips_history")) |v| {
        if (v == .object) {
            var it = v.object.iterator();
            while (it.next()) |entry| {
                const val = entry.value_ptr.*;
                if (val != .integer or val.integer < 0) continue;
                const owned_id = try state.alloc().dupe(u8, entry.key_ptr.*);
                try state.tips_history.put(state.alloc(), owned_id, @intCast(val.integer));
            }
        }
    }
    if (root.get("projects")) |v| {
        if (v == .object) {
            var it = v.object.iterator();
            while (it.next()) |entry| {
                const val = entry.value_ptr.*;
                if (val != .object) continue;
                var ob: ProjectOnboarding = .{};
                if (val.object.get("seen_count")) |sc| {
                    if (sc == .integer and sc.integer >= 0) ob.seen_count = @intCast(sc.integer);
                }
                if (val.object.get("completed")) |c| {
                    if (c == .bool) ob.completed = c.bool;
                }
                const owned_key = try state.alloc().dupe(u8, entry.key_ptr.*);
                try state.projects.put(state.alloc(), owned_key, ob);
            }
        }
    }
}

/// Serialize `state` as a compact JSON object to `w`.
fn serialize(state: *State, w: *std.Io.Writer) !void {
    try w.print("{{\"num_startups\":{d}", .{state.num_startups});

    try w.writeAll(",\"last_release_notes_seen\":");
    try w.print("{f}", .{std.json.fmt(state.last_release_notes_seen, .{})});

    try w.writeAll(",\"tips_history\":{");
    {
        var it = state.tips_history.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) try w.writeByte(',');
            first = false;
            try w.print("{f}:{d}", .{ std.json.fmt(entry.key_ptr.*, .{}), entry.value_ptr.* });
        }
    }
    try w.writeAll("}");

    try w.writeAll(",\"projects\":{");
    {
        var it = state.projects.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) try w.writeByte(',');
            first = false;
            try w.print("{f}:{{\"seen_count\":{d},\"completed\":{}}}", .{
                std.json.fmt(entry.key_ptr.*, .{}),
                entry.value_ptr.*.seen_count,
                entry.value_ptr.*.completed,
            });
        }
    }
    try w.writeAll("}}");
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;
const test_helpers = @import("test_helpers.zig");

test "incrementStartups returns 1 then 2 and persists across load" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(base);
    const path = try std.fs.path.join(testing.allocator, &.{ base, "state.json" });
    defer testing.allocator.free(path);

    try testing.expectEqual(@as(u64, 1), incrementStartupsAtPath(testing.allocator, path));
    try testing.expectEqual(@as(u64, 2), incrementStartupsAtPath(testing.allocator, path));

    var state = loadAtPath(testing.allocator, path);
    defer state.deinit();
    try testing.expectEqual(@as(u64, 2), state.num_startups);
}

test "recordTipShown then sessionsSinceTipShown returns elapsed startups" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(base);
    const path = try std.fs.path.join(testing.allocator, &.{ base, "state.json" });
    defer testing.allocator.free(path);

    // Advance to startup N=5, record a tip there.
    for (0..5) |_| _ = incrementStartupsAtPath(testing.allocator, path);
    recordTipShownAtPath(testing.allocator, path, "tip-a");

    // Advance to N+3 = 8.
    for (0..3) |_| _ = incrementStartupsAtPath(testing.allocator, path);

    var state = loadAtPath(testing.allocator, path);
    defer state.deinit();
    try testing.expectEqual(@as(u64, 8), state.num_startups);
    try testing.expectEqual(@as(u64, 3), sessionsSinceTipShown(&state, "tip-a"));
}

test "sessionsSinceTipShown returns NEVER_SHOWN for an unseen tip" {
    var state = State.empty(testing.allocator);
    defer state.deinit();
    state.num_startups = 100;
    try testing.expectEqual(NEVER_SHOWN, sessionsSinceTipShown(&state, "never"));
}

test "setProjectOnboarding/getProjectOnboarding round-trips per project key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(base);
    const path = try std.fs.path.join(testing.allocator, &.{ base, "state.json" });
    defer testing.allocator.free(path);

    setProjectOnboardingAtPath(testing.allocator, path, "proj-a", .{ .seen_count = 3, .completed = true });
    setProjectOnboardingAtPath(testing.allocator, path, "proj-b", .{ .seen_count = 1, .completed = false });

    var state = loadAtPath(testing.allocator, path);
    defer state.deinit();

    const a = getProjectOnboarding(&state, "proj-a");
    try testing.expectEqual(@as(u64, 3), a.seen_count);
    try testing.expectEqual(true, a.completed);

    const b = getProjectOnboarding(&state, "proj-b");
    try testing.expectEqual(@as(u64, 1), b.seen_count);
    try testing.expectEqual(false, b.completed);

    // Isolation: an unknown key returns the zero value.
    const c = getProjectOnboarding(&state, "proj-unknown");
    try testing.expectEqual(@as(u64, 0), c.seen_count);
    try testing.expectEqual(false, c.completed);
}

test "corrupt state.json loads as zero-value default without error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(base);
    const path = try std.fs.path.join(testing.allocator, &.{ base, "state.json" });
    defer testing.allocator.free(path);

    const file = try std.Io.Dir.cwd().createFile(rt.io, path, .{ .truncate = true });
    try file.writeStreamingAll(rt.io, "{ this is not valid json ]]");
    file.close(rt.io);

    var state = loadAtPath(testing.allocator, path);
    defer state.deinit();
    try testing.expectEqual(@as(u64, 0), state.num_startups);
    try testing.expectEqualStrings("", state.last_release_notes_seen);
    try testing.expectEqual(@as(usize, 0), state.tips_history.count());
    try testing.expectEqual(@as(usize, 0), state.projects.count());
}

test "empty/missing state.json loads as zero-value default" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(base);
    const path = try std.fs.path.join(testing.allocator, &.{ base, "missing-state.json" });
    defer testing.allocator.free(path);

    var state = loadAtPath(testing.allocator, path);
    defer state.deinit();
    try testing.expectEqual(@as(u64, 0), state.num_startups);
}

test "last_release_notes_seen round-trips through save/load" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(base);
    const path = try std.fs.path.join(testing.allocator, &.{ base, "state.json" });
    defer testing.allocator.free(path);

    {
        var state = State.empty(testing.allocator);
        defer state.deinit();
        setLastReleaseNotesSeen(&state, "0.11.73");
        try saveAtPath(&state, path);
    }

    var reloaded = loadAtPath(testing.allocator, path);
    defer reloaded.deinit();
    try testing.expectEqualStrings("0.11.73", getLastReleaseNotesSeen(&reloaded));
}

test "unknown top-level keys are ignored (forward-compatible)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(base);
    const path = try std.fs.path.join(testing.allocator, &.{ base, "state.json" });
    defer testing.allocator.free(path);

    const file = try std.Io.Dir.cwd().createFile(rt.io, path, .{ .truncate = true });
    try file.writeStreamingAll(rt.io, "{\"num_startups\":9,\"future_field\":{\"x\":1},\"last_release_notes_seen\":\"1.2.3\"}");
    file.close(rt.io);

    var state = loadAtPath(testing.allocator, path);
    defer state.deinit();
    try testing.expectEqual(@as(u64, 9), state.num_startups);
    try testing.expectEqualStrings("1.2.3", getLastReleaseNotesSeen(&state));
}
