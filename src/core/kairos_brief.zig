//! KAIROS brief + proposal store — per-project (cwd-scoped) persistence for the
//! background agent.
//!
//!   * Brief: an append-only markdown log of what KAIROS did / found, at
//!     `<projectDir>/brief.md`. Each entry is "## <ts> <heading>\n<body>\n\n".
//!   * Proposals: a JSON array of mutating actions KAIROS wanted to take but is
//!     not allowed to run unsupervised. Stored at `<projectDir>/proposals.json`
//!     as `[{id, created_ts, prompt, reason}, ...]`. The user approves them
//!     later, at which point the stored `prompt` is re-run.
//!
//! Both live under `~/.zcode/kairos/<project-key>/` (see `kairos_lock.projectDir`,
//! which ensures every level exists). Disk-facing functions are best-effort: on
//! any error they degrade quietly (return null / false / skip) rather than panic,
//! mirroring the discipline in `core/cron.zig` and `core/kairos_lock.zig`.
//!
//! Writes go through the tmp-file + atomic-rename idiom copied from
//! `core/cron.zig` so a SIGINT in the truncate->write window can never leave a
//! half-written proposals.json that would drop every queued proposal on the next
//! read.

const std = @import("std");
const rt = @import("zcode_runtime");
const std_io = @import("std_io.zig");
const clock = @import("clock.zig");
const rng = @import("rng.zig");
const kairos_lock = @import("kairos_lock.zig");
const paths = @import("paths.zig");
const json = std.json;

const BRIEF_FILE = "brief.md";
const PROPOSALS_FILE = "proposals.json";

/// Cap on a single read of either store file. The brief can grow over a long
/// session and the proposal list is small, but a 1 MiB ceiling is far past any
/// legitimate size and stops a corrupt/huge file from blowing up the read.
const MAX_FILE_BYTES: usize = 1024 * 1024;

/// A mutating action KAIROS proposed but did not run. The user approves it later,
/// at which point `prompt` is re-enqueued.
pub const Proposal = struct {
    /// 8 hex chars.
    id: []u8,
    /// When the proposal was queued (unix seconds).
    created_ts: i64,
    /// The intent prompt to re-run on approval.
    prompt: []u8,
    /// Why KAIROS proposed it (short).
    reason: []u8,

    pub fn deinit(self: *Proposal, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.prompt);
        allocator.free(self.reason);
    }
};

// ===========================================================================
// Brief (append-only markdown)
// ===========================================================================

/// Append "## <ts> <heading>\n<body>\n\n" to the project brief. Best-effort: any
/// failure is swallowed. Creates the file if absent and writes at end-of-file
/// (no global seek state on Io.File; we stat for the current size and write
/// positionally so concurrent readers stay correct).
pub fn appendBrief(allocator: std.mem.Allocator, cwd: []const u8, heading: []const u8, body: []const u8) void {
    const path = briefPath(allocator, cwd) catch return;
    defer allocator.free(path);

    const file = std.Io.Dir.cwd().createFile(rt.io, path, .{ .truncate = false }) catch return;
    defer file.close(rt.io);
    const offset: u64 = if (file.stat(rt.io)) |st| st.size else |_| 0;

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    out.writer().print("## {d} {s}\n{s}\n\n", .{ clock.nowSeconds(), heading, body }) catch return;
    file.writePositionalAll(rt.io, out.items(), offset) catch {};
}

/// Read the whole brief. Owned result, caller frees. Null if there is no brief
/// (or on any read error).
pub fn readBrief(allocator: std.mem.Allocator, cwd: []const u8) ?[]u8 {
    const path = briefPath(allocator, cwd) catch return null;
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(MAX_FILE_BYTES)) catch null;
}

/// Delete the brief. Best-effort.
pub fn clearBrief(allocator: std.mem.Allocator, cwd: []const u8) void {
    const path = briefPath(allocator, cwd) catch return;
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(rt.io, path) catch {};
}

// ===========================================================================
// Proposals (JSON store)
// ===========================================================================

/// Queue a new proposal. Loads the existing list, appends, and writes the whole
/// list back atomically. Returns the new id (owned dupe — caller frees).
pub fn addProposal(allocator: std.mem.Allocator, cwd: []const u8, prompt: []const u8, reason: []const u8) ![]const u8 {
    const path = try proposalsPath(allocator, cwd);
    defer allocator.free(path);

    const list = loadProposals(allocator, path);
    defer freeProposals(allocator, list);

    const new_id = try makeId(allocator);
    errdefer allocator.free(new_id);
    const prompt_dup = try allocator.dupe(u8, prompt);
    errdefer allocator.free(prompt_dup);
    const reason_dup = try allocator.dupe(u8, reason);
    errdefer allocator.free(reason_dup);

    // Build the full list (existing + new) so serialize sees one slice.
    var combined = try allocator.alloc(Proposal, list.len + 1);
    defer allocator.free(combined);
    @memcpy(combined[0..list.len], list);
    combined[list.len] = .{
        .id = new_id,
        .created_ts = clock.nowSeconds(),
        .prompt = prompt_dup,
        .reason = reason_dup,
    };

    const bytes = try serializeProposals(allocator, combined);
    defer allocator.free(bytes);
    try writeFileAtomic(allocator, path, bytes);

    // Return an independent dupe so the caller's id outlives our local frees.
    return allocator.dupe(u8, new_id);
}

/// All queued proposals. Owned slice; caller frees each element (`deinit`) and
/// the slice itself. Empty slice when there are none.
pub fn listProposals(allocator: std.mem.Allocator, cwd: []const u8) ![]Proposal {
    const path = try proposalsPath(allocator, cwd);
    defer allocator.free(path);
    return loadProposals(allocator, path);
}

/// Remove the proposal with `id`. Loads, filters it out, writes the remainder
/// atomically. Returns whether anything was removed.
pub fn removeProposal(allocator: std.mem.Allocator, cwd: []const u8, id: []const u8) bool {
    const path = proposalsPath(allocator, cwd) catch return false;
    defer allocator.free(path);

    const list = loadProposals(allocator, path);
    defer freeProposals(allocator, list);

    var kept = std.array_list.Managed(Proposal).init(allocator);
    defer kept.deinit();
    var removed = false;
    for (list) |p| {
        if (std.mem.eql(u8, p.id, id)) {
            removed = true;
        } else {
            kept.append(p) catch return false;
        }
    }
    if (!removed) return false;

    const bytes = serializeProposals(allocator, kept.items) catch return false;
    defer allocator.free(bytes);
    writeFileAtomic(allocator, path, bytes) catch return false;
    return true;
}

/// Number of queued proposals. 0 on any error.
pub fn proposalCount(allocator: std.mem.Allocator, cwd: []const u8) usize {
    const path = proposalsPath(allocator, cwd) catch return 0;
    defer allocator.free(path);
    const list = loadProposals(allocator, path);
    defer freeProposals(allocator, list);
    return list.len;
}

// ===========================================================================
// Goal store (commands-34, /goal) — per-session stop condition
// ===========================================================================
//
// `/goal <condition>` persists a durable "keep working until this is true"
// condition for the CURRENT session, one JSON file per session id under this
// project's KAIROS dir (`<projectDir>/goals/<session_id>.json`). The REPL
// nudges the model with it at the end of every turn (see
// `repl_commands_parity.zig`'s `__goal_nudge` sentinel and its one-line hook
// in `cli/repl.zig`) until the model reports the condition met, the user runs
// `/goal clear`, or `checks` hits `GOAL_MAX_CHECKS` (a safety cap against an
// unbounded auto-continue loop). Same best-effort disk discipline as the
// brief/proposals stores above: any I/O or parse failure degrades to "no
// goal" rather than erroring the caller.

/// Safety cap on the number of automatic end-of-turn nudges a single goal can
/// trigger before it is auto-cleared. Chosen to be generous enough for a real
/// multi-step task while still bounding a runaway loop.
pub const GOAL_MAX_CHECKS: u32 = 25;

const GOALS_SUBDIR = "goals";

pub const Goal = struct {
    condition: []u8,
    created_ts: i64,
    checks: u32,

    pub fn deinit(self: *Goal, allocator: std.mem.Allocator) void {
        allocator.free(self.condition);
    }
};

fn goalPath(allocator: std.mem.Allocator, cwd: []const u8, session_id: []const u8) ![]u8 {
    const dir = try kairos_lock.projectDir(allocator, cwd);
    defer allocator.free(dir);
    const goals_dir = try std.fs.path.join(allocator, &.{ dir, GOALS_SUBDIR });
    defer allocator.free(goals_dir);
    paths.ensureDir(goals_dir) catch {};

    // Session ids are already filesystem-safe (uuid/hex-ish); sanitize
    // defensively anyway so a hostile/odd session id can never escape the
    // goals dir via a path separator.
    var safe = try allocator.alloc(u8, session_id.len);
    defer allocator.free(safe);
    for (session_id, 0..) |c, i| {
        safe[i] = switch (c) {
            '/', '\\', 0 => '_',
            else => c,
        };
    }
    const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{safe});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ goals_dir, file_name });
}

/// Persist `condition` as the active goal for `session_id`. Overwrites any
/// prior goal (starts the check counter over at 0).
pub fn setGoal(allocator: std.mem.Allocator, cwd: []const u8, session_id: []const u8, condition: []const u8) !void {
    const path = try goalPath(allocator, cwd, session_id);
    defer allocator.free(path);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try out.writer().print("{f}", .{std.json.fmt(.{
        .condition = condition,
        .created_ts = clock.nowSeconds(),
        .checks = @as(u32, 0),
    }, .{})});
    try writeFileAtomic(allocator, path, out.items());
}

/// Read the active goal for `session_id`, or null when there is none (or the
/// file is missing/corrupt). Owned result; free with `Goal.deinit`.
pub fn getGoal(allocator: std.mem.Allocator, cwd: []const u8, session_id: []const u8) ?Goal {
    const path = goalPath(allocator, cwd, session_id) catch return null;
    defer allocator.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(MAX_FILE_BYTES)) catch return null;
    defer allocator.free(bytes);

    var parsed = json.parseFromSlice(json.Value, allocator, bytes, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const obj = parsed.value.object;

    const cond_val = obj.get("condition") orelse return null;
    if (cond_val != .string) return null;
    const condition = allocator.dupe(u8, cond_val.string) catch return null;

    const created_ts: i64 = if (obj.get("created_ts")) |v| switch (v) {
        .integer => |i| i,
        else => 0,
    } else 0;
    const checks: u32 = if (obj.get("checks")) |v| switch (v) {
        .integer => |i| if (i > 0) @intCast(i) else 0,
        else => 0,
    } else 0;

    return .{ .condition = condition, .created_ts = created_ts, .checks = checks };
}

/// Increment the goal's check counter and persist it. Best-effort: swallows
/// any I/O error (a failed bump just means the next nudge re-reads the same
/// count, which is harmless -- it only affects when the safety cap trips).
pub fn bumpGoalChecks(allocator: std.mem.Allocator, cwd: []const u8, session_id: []const u8) void {
    var goal = getGoal(allocator, cwd, session_id) orelse return;
    defer goal.deinit(allocator);

    const path = goalPath(allocator, cwd, session_id) catch return;
    defer allocator.free(path);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    out.writer().print("{f}", .{json.fmt(.{
        .condition = goal.condition,
        .created_ts = goal.created_ts,
        .checks = goal.checks + 1,
    }, .{})}) catch return;
    writeFileAtomic(allocator, path, out.items()) catch {};
}

/// Remove the active goal for `session_id`. Best-effort; a second call (or
/// clearing a session with no goal) is a harmless no-op.
pub fn clearGoal(allocator: std.mem.Allocator, cwd: []const u8, session_id: []const u8) void {
    const path = goalPath(allocator, cwd, session_id) catch return;
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(rt.io, path) catch {};
}

// ===========================================================================
// Private helpers — paths
// ===========================================================================

fn briefPath(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const dir = try kairos_lock.projectDir(allocator, cwd);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, BRIEF_FILE });
}

fn proposalsPath(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const dir = try kairos_lock.projectDir(allocator, cwd);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, PROPOSALS_FILE });
}

// ===========================================================================
// Private helpers — disk
// ===========================================================================

/// Read + parse proposals from `path`. Never fails: a missing/corrupt/malformed
/// file yields an empty slice. Owned slice; free with `freeProposals`.
fn loadProposals(allocator: std.mem.Allocator, path: []const u8) []Proposal {
    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(MAX_FILE_BYTES)) catch
        return allocator.alloc(Proposal, 0) catch &[_]Proposal{};
    defer allocator.free(bytes);
    return parseProposals(allocator, bytes) catch
        (allocator.alloc(Proposal, 0) catch &[_]Proposal{});
}

/// tmp-file + atomic-rename write (copied from cron.zig's writeCronFileAtomic):
/// write to a randomly-suffixed temp file, fsync, then rename over the target so
/// a crash mid-write can never leave a truncated proposals.json.
fn writeFileAtomic(allocator: std.mem.Allocator, target: []const u8, bytes: []const u8) !void {
    var nonce: [8]u8 = undefined;
    rng.bytes(&nonce);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{x}{x}{x}{x}{x}{x}{x}{x}", .{
        target, nonce[0], nonce[1], nonce[2], nonce[3], nonce[4], nonce[5], nonce[6], nonce[7],
    });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{
            .truncate = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, bytes);
        file.sync(rt.io) catch {};
    }
    try std.Io.Dir.renameAbsolute(tmp_path, target, rt.io);
}

// ===========================================================================
// Private helpers — pure (serialize / parse, unit-tested without disk)
// ===========================================================================

/// Generate an 8-hex-char id from 4 random bytes (owned).
fn makeId(allocator: std.mem.Allocator) ![]u8 {
    var rand_buf: [4]u8 = undefined;
    rng.bytes(&rand_buf);
    return std.fmt.allocPrint(allocator, "{x}{x}{x}{x}", .{
        rand_buf[0], rand_buf[1], rand_buf[2], rand_buf[3],
    });
}

fn freeProposals(allocator: std.mem.Allocator, list: []Proposal) void {
    for (list) |*p| p.deinit(allocator);
    allocator.free(list);
}

/// Serialize a proposal list to a JSON array. Strings are JSON-escaped via
/// `std.json.fmt` so quotes / newlines in `prompt` or `reason` round-trip.
fn serializeProposals(allocator: std.mem.Allocator, list: []const Proposal) ![]u8 {
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    const w = buf.writer();

    try w.writeAll("[");
    for (list, 0..) |p, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"id\":");
        try w.print("{f}", .{json.fmt(p.id, .{})});
        try w.print(",\"created_ts\":{d},\"prompt\":", .{p.created_ts});
        try w.print("{f}", .{json.fmt(p.prompt, .{})});
        try w.writeAll(",\"reason\":");
        try w.print("{f}", .{json.fmt(p.reason, .{})});
        try w.writeAll("}");
    }
    try w.writeAll("]");

    return allocator.dupe(u8, buf.items());
}

/// Parse a JSON array of proposals. Tolerant: empty input, "[]", a non-array
/// document, or any malformed record yields an empty slice rather than an error.
/// Owned slice; free with `freeProposals`.
fn parseProposals(allocator: std.mem.Allocator, bytes: []const u8) ![]Proposal {
    var parsed = json.parseFromSlice(json.Value, allocator, bytes, .{}) catch
        return allocator.alloc(Proposal, 0);
    defer parsed.deinit();
    if (parsed.value != .array) return allocator.alloc(Proposal, 0);

    const now = clock.nowSeconds();

    var out = std.array_list.Managed(Proposal).init(allocator);
    errdefer {
        for (out.items) |*p| p.deinit(allocator);
        out.deinit();
    }

    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const id_val = item.object.get("id") orelse continue;
        const prompt_val = item.object.get("prompt") orelse continue;
        const reason_val = item.object.get("reason") orelse continue;
        if (id_val != .string or prompt_val != .string or reason_val != .string) continue;

        // Bound created_ts defensively. A hand-edited or malformed
        // proposals.json could carry created_ts = i64 min/max; downstream
        // arithmetic on it would overflow. Anything outside a +/- 100-year
        // window around `now` is treated as garbage and replaced with `now`
        // so the record loads rather than being dropped on a one-byte typo.
        const raw_ts: i64 = if (item.object.get("created_ts")) |t| switch (t) {
            .integer => |n| @as(i64, n),
            else => now,
        } else now;
        const ONE_HUNDRED_YEARS: i64 = 100 * 365 * 24 * 60 * 60;
        const created_ts = if (raw_ts < now -| ONE_HUNDRED_YEARS or
            raw_ts > now +| ONE_HUNDRED_YEARS) now else raw_ts;

        const id = try allocator.dupe(u8, id_val.string);
        errdefer allocator.free(id);
        const prompt = try allocator.dupe(u8, prompt_val.string);
        errdefer allocator.free(prompt);
        const reason = try allocator.dupe(u8, reason_val.string);
        errdefer allocator.free(reason);

        try out.append(.{
            .id = id,
            .created_ts = created_ts,
            .prompt = prompt,
            .reason = reason,
        });
    }

    return out.toOwnedSlice();
}

// ===========================================================================
// Tests (pure serialize/parse only — no disk IO)
// ===========================================================================

const testing = std.testing;

test "serialize then parse round-trips records" {
    var in = [_]Proposal{
        .{
            .id = try testing.allocator.dupe(u8, "deadbeef"),
            .created_ts = 1700000000,
            .prompt = try testing.allocator.dupe(u8, "rm stale branch"),
            .reason = try testing.allocator.dupe(u8, "merged 3 weeks ago"),
        },
        .{
            .id = try testing.allocator.dupe(u8, "cafef00d"),
            .created_ts = 1700000123,
            .prompt = try testing.allocator.dupe(u8, "bump dep"),
            .reason = try testing.allocator.dupe(u8, "CVE fix available"),
        },
    };
    defer for (&in) |*p| p.deinit(testing.allocator);

    const bytes = try serializeProposals(testing.allocator, &in);
    defer testing.allocator.free(bytes);

    const out = try parseProposals(testing.allocator, bytes);
    defer freeProposals(testing.allocator, out);

    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("deadbeef", out[0].id);
    try testing.expectEqual(@as(i64, 1700000000), out[0].created_ts);
    try testing.expectEqualStrings("rm stale branch", out[0].prompt);
    try testing.expectEqualStrings("merged 3 weeks ago", out[0].reason);
    try testing.expectEqualStrings("cafef00d", out[1].id);
    try testing.expectEqual(@as(i64, 1700000123), out[1].created_ts);
    try testing.expectEqualStrings("bump dep", out[1].prompt);
    try testing.expectEqualStrings("CVE fix available", out[1].reason);
}

test "empty list serializes to [] and round-trips" {
    const bytes = try serializeProposals(testing.allocator, &[_]Proposal{});
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("[]", bytes);

    const out = try parseProposals(testing.allocator, bytes);
    defer freeProposals(testing.allocator, out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "parse tolerates empty / [] / malformed input without crashing" {
    const cases = [_][]const u8{
        "", // empty
        "[]", // empty array
        "not json at all", // garbage
        "{\"id\":\"x\"}", // object, not array
        "[1, 2, 3]", // array of non-objects
        "[{\"id\":\"x\"}]", // missing prompt/reason
        "[{\"id\":123,\"prompt\":\"p\",\"reason\":\"r\"}]", // wrong types
        "[{\"prompt\":\"p\",\"reason\":\"r\"}]", // missing id
    };
    for (cases) |c| {
        const out = try parseProposals(testing.allocator, c);
        defer freeProposals(testing.allocator, out);
        try testing.expectEqual(@as(usize, 0), out.len);
    }
}

test "proposal with quotes and newlines in prompt round-trips" {
    var in = [_]Proposal{
        .{
            .id = try testing.allocator.dupe(u8, "0badf00d"),
            .created_ts = 1700009999,
            .prompt = try testing.allocator.dupe(u8, "run \"the thing\"\nand also: line two\twith a tab"),
            .reason = try testing.allocator.dupe(u8, "has \\ backslash and \"quotes\""),
        },
    };
    defer for (&in) |*p| p.deinit(testing.allocator);

    const bytes = try serializeProposals(testing.allocator, &in);
    defer testing.allocator.free(bytes);

    const out = try parseProposals(testing.allocator, bytes);
    defer freeProposals(testing.allocator, out);

    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("run \"the thing\"\nand also: line two\twith a tab", out[0].prompt);
    try testing.expectEqualStrings("has \\ backslash and \"quotes\"", out[0].reason);
}

test "parse clamps out-of-range created_ts to now" {
    const now = clock.nowSeconds();
    // i64 max created_ts must be treated as garbage and clamped to ~now.
    const doc = "[{\"id\":\"aaaaaaaa\",\"created_ts\":9223372036854775807,\"prompt\":\"p\",\"reason\":\"r\"}]";
    const out = try parseProposals(testing.allocator, doc);
    defer freeProposals(testing.allocator, out);
    try testing.expectEqual(@as(usize, 1), out.len);
    const ONE_HUNDRED_YEARS: i64 = 100 * 365 * 24 * 60 * 60;
    try testing.expect(out[0].created_ts >= now -| ONE_HUNDRED_YEARS);
    try testing.expect(out[0].created_ts <= now +| ONE_HUNDRED_YEARS);
}

// ===========================================================================
// Goal store tests (commands-34)
// ===========================================================================

const test_helpers = @import("test_helpers.zig");
const env = @import("env.zig");

test "getGoal is null before any /goal is set" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(home);
    try env.setOverride("HOME", home);
    defer env.clearOverrides();

    try testing.expect(getGoal(alloc, home, "sess-1") == null);
}

test "setGoal then getGoal round-trips the condition with checks starting at 0" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(home);
    try env.setOverride("HOME", home);
    defer env.clearOverrides();

    try setGoal(alloc, home, "sess-1", "all tests pass");

    var goal = getGoal(alloc, home, "sess-1").?;
    defer goal.deinit(alloc);
    try testing.expectEqualStrings("all tests pass", goal.condition);
    try testing.expectEqual(@as(u32, 0), goal.checks);
}

test "bumpGoalChecks increments the persisted counter" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(home);
    try env.setOverride("HOME", home);
    defer env.clearOverrides();

    try setGoal(alloc, home, "sess-1", "ship the feature");
    bumpGoalChecks(alloc, home, "sess-1");
    bumpGoalChecks(alloc, home, "sess-1");

    var goal = getGoal(alloc, home, "sess-1").?;
    defer goal.deinit(alloc);
    try testing.expectEqual(@as(u32, 2), goal.checks);
    try testing.expectEqualStrings("ship the feature", goal.condition);
}

test "clearGoal removes the goal and is a no-op when called again" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(home);
    try env.setOverride("HOME", home);
    defer env.clearOverrides();

    try setGoal(alloc, home, "sess-1", "condition");
    clearGoal(alloc, home, "sess-1");
    try testing.expect(getGoal(alloc, home, "sess-1") == null);
    clearGoal(alloc, home, "sess-1"); // no-op, must not error/panic
}

test "goals for different sessions in the same project do not collide" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(home);
    try env.setOverride("HOME", home);
    defer env.clearOverrides();

    try setGoal(alloc, home, "sess-a", "goal A");
    try setGoal(alloc, home, "sess-b", "goal B");

    var a = getGoal(alloc, home, "sess-a").?;
    defer a.deinit(alloc);
    var b = getGoal(alloc, home, "sess-b").?;
    defer b.deinit(alloc);
    try testing.expectEqualStrings("goal A", a.condition);
    try testing.expectEqualStrings("goal B", b.condition);
}
