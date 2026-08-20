const std = @import("std");
const std_io = @import("std_io.zig");
const rt = @import("zcode_runtime");
const clock = @import("clock.zig");
const memory = @import("memory.zig");
const memory_prompt = @import("memory_prompt.zig");
const memory_gate = @import("memory_gate.zig");
const config = @import("config.zig");
const paths = @import("paths.zig");
const test_helpers = @import("test_helpers.zig");
const arg_parse = @import("../tools/arg_parse.zig");
const parse_helpers = @import("parse_helpers.zig");

/// Default minimum hours between automatic dream consolidation runs. Used when
/// the configurable `auto_dream_min_hours` is unset/0/absurd (see `minHours`).
const MIN_HOURS_BETWEEN_DREAMS: i64 = 24;

/// Default minimum sessions touched since the last consolidation before a dream
/// is triggered. Used when the configurable `auto_dream_min_sessions` is
/// unset/0/absurd (see `minSessions`).
const MIN_SESSIONS_BEFORE_DREAM: usize = 5;

/// Upper sanity bound on the configurable thresholds. A value above this is
/// treated as a fat-finger and clamped to the default, mirroring the
/// reference's defensive validation of the GrowthBook config (config.ts:73-93).
const MAX_REASONABLE_MIN_HOURS: u32 = 24 * 365; // a year
const MAX_REASONABLE_MIN_SESSIONS: u32 = 10_000;

/// Throttle between session-store scans when the time gate is open but the
/// session gate is not. Mirrors the reference's `SESSION_SCAN_INTERVAL_MS`
/// (services/autoDream/autoDream.ts:54-56): 10 minutes in nanoseconds. Stops
/// re-scanning the store on every turn once the 24h time gate has passed but
/// not enough new sessions have accumulated yet (background-svc-02).
const SESSION_SCAN_INTERVAL_NS: i128 = 10 * 60 * @as(i128, std.time.ns_per_s);

/// A consolidation lock older than this is treated as stale (the holder likely
/// crashed without releasing it). Mirrors the reference's `HOLDER_STALE_MS`
/// (services/autoDream/consolidationLock.ts): 60 minutes in seconds
/// (background-svc-03).
const HOLDER_STALE_SECS: i64 = 60 * 60;

/// Maximum lines allowed in MEMORY.md index. Aliased to the shared
/// memory_prompt cap so the dream consolidation guidance and the per-turn
/// index truncation stay in sync (memory-04 / memory-11).
const MAX_MEMORY_INDEX_LINES: usize = memory_prompt.MAX_ENTRYPOINT_LINES;

/// Count sessions touched (mtime newer than the last consolidation) since the
/// last dream, excluding the current session. Pure function over the entry
/// slice -- no IO, fully testable.
///
/// `entries` is any slice whose elements expose `.id: []const u8` and
/// `.updated_ts: i64` (the session store's `SessionEntry`). `last_run_mtime_sec`
/// is the last-consolidation timestamp in seconds, or null when never
/// consolidated -- in which case every non-current entry counts as touched.
/// `current_session_id` is excluded so the in-progress session never inflates
/// the count.
pub fn touchedSinceCount(entries: anytype, last_run_mtime_sec: ?i64, current_session_id: []const u8) usize {
    var count: usize = 0;
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.id, current_session_id)) continue;
        if (last_run_mtime_sec) |since| {
            if (entry.updated_ts <= since) continue;
        }
        count += 1;
    }
    return count;
}

/// Read the last-consolidation marker mtime in seconds. Returns null when the
/// marker is absent (= "never consolidated"), which makes every session count
/// as touched-since. Factored out of `shouldAutoDream`'s stat logic so the
/// touched-since count can be computed against it at the call site.
pub fn lastConsolidatedAtSec(allocator: std.mem.Allocator) ?i64 {
    const marker_path = lastRunMarkerPath(allocator) catch return null;
    defer allocator.free(marker_path);
    return lastConsolidatedAtSecAtPath(marker_path);
}

/// Read the last-consolidation timestamp in seconds for an explicit path.
/// Injection point so the time-gate logic can be exercised against a tmp-dir
/// marker in tests without depending on the real `~/.zcode` layout.
///
/// The timestamp is stored *in the marker body* as a decimal Unix-seconds
/// integer (background-svc-03 body-stored-timestamp design). Storing it in the
/// body rather than the file mtime sidesteps the lack of a portable utimes API
/// in 0.16: `rollbackConsolidation` can rewind the stored value by rewriting
/// the body, which a raw mtime touch could not do without a setTimes syscall.
///
/// Backward compatibility: an old empty-body marker (written before this
/// redesign) has no parseable integer, so we fall back to the file mtime. That
/// keeps an in-place upgrade from spuriously re-firing the dream on first run.
pub fn lastConsolidatedAtSecAtPath(marker_path: []const u8) ?i64 {
    const stat = std.Io.Dir.cwd().statFile(rt.io, marker_path, .{}) catch return null;

    // Read the body and parse the stored integer. The marker is a handful of
    // bytes; cap the read so a corrupt/huge file can't blow up.
    var buf: [64]u8 = undefined;
    const file = std.Io.Dir.cwd().openFile(rt.io, marker_path, .{}) catch {
        // Stat succeeded but open failed: fall back to mtime.
        return @intCast(@divTrunc(stat.mtime.toNanoseconds(), std.time.ns_per_s));
    };
    defer file.close(rt.io);

    const n = file.readStreaming(rt.io, &.{&buf}) catch 0;
    const body = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (body.len > 0) {
        if (std.fmt.parseInt(i64, body, 10)) |secs| {
            return secs;
        } else |_| {}
    }

    // Empty or unparseable body (old-format marker): fall back to file mtime.
    return @intCast(@divTrunc(stat.mtime.toNanoseconds(), std.time.ns_per_s));
}

/// Master enable gate for automatic dream consolidation (background-svc-04).
///
/// Mirrors the reference's `isGateOpen` (services/autoDream/autoDream.ts:95-100),
/// which requires `isAutoMemoryEnabled() && isAutoDreamEnabled()`. zcode has no
/// GrowthBook flag, so the only inputs are the two local settings:
///   - `auto_dream_enabled` (tri-state): false = explicit off-switch; null/true
///     = on (default preserves zcode's prior always-on behaviour).
///   - the auto-memory enable chain (`memory_gate.isAutoMemoryEnabled`), which
///     already folds in the disable env vars and `--bare`.
///
/// The reference also gates on `!getKairosActive() && !getIsRemoteMode()`. zcode
/// has no remote-mode flag, and KAIROS turns run a *non-interactive*
/// `AgentRuntime`, so the existing `self.interactive && self.depth == 0` guard
/// at the call site already excludes KAIROS/remote (KAIROS uses its own
/// disk-skill dream). See `maybeRunDream` for the note.
pub fn isGateOpen(cfg: *const config.Config) bool {
    if (cfg.auto_dream_enabled) |enabled| {
        if (!enabled) return false;
    }
    return memory_gate.isAutoMemoryEnabled(cfg);
}

/// Resolve the configurable minimum-hours threshold with the reference's
/// defensive clamp: 0 or an absurd value falls back to the default
/// (config.ts:73-93).
pub fn minHours(cfg: *const config.Config) i64 {
    const h = cfg.auto_dream_min_hours;
    if (h == 0 or h > MAX_REASONABLE_MIN_HOURS) return MIN_HOURS_BETWEEN_DREAMS;
    return @intCast(h);
}

/// Resolve the configurable minimum-sessions threshold with the same defensive
/// clamp as `minHours`.
pub fn minSessions(cfg: *const config.Config) usize {
    const s = cfg.auto_dream_min_sessions;
    if (s == 0 or s > MAX_REASONABLE_MIN_SESSIONS) return MIN_SESSIONS_BEFORE_DREAM;
    return @intCast(s);
}

/// Time gate: has enough wall-clock time elapsed since the last consolidation?
///
/// Split out of `shouldAutoDream` so the caller can sequence the gates as the
/// reference does: time gate, then a scan throttle, then the session-count gate
/// (background-svc-02). Returns true when the marker is absent (never
/// consolidated) or when at least `minHours(cfg)` have passed.
pub fn shouldTimeGatePass(allocator: std.mem.Allocator, cfg: *const config.Config) bool {
    // The marker is separate from the exclusive-create lock file so that
    // holding the lock during consolidation doesn't interfere with the time
    // gate.
    const mtime_sec = lastConsolidatedAtSec(allocator) orelse {
        // No marker = never consolidated, should dream.
        return true;
    };

    const now = clock.nowSeconds();
    const hours_since = @divTrunc(now - mtime_sec, 3600);

    return hours_since >= minHours(cfg);
}

/// Scan throttle: has enough time passed since the last session-store scan to
/// scan again? Sits between the time gate and the session-count gate so the
/// store is not re-scanned on every turn once the time gate has opened but the
/// session gate has not yet been satisfied (background-svc-02).
///
/// `now_ns` and `last_scan_ns` are nanoseconds from `clock.nowNanos()`. A
/// `last_scan_ns` of 0 (the never-scanned default) always passes.
pub fn scanThrottlePasses(now_ns: i128, last_scan_ns: i128) bool {
    return now_ns - last_scan_ns >= SESSION_SCAN_INTERVAL_NS;
}

/// Check if automatic dream consolidation should run.
///
/// `touched_since_count` is the number of sessions touched since the last
/// consolidation, excluding the current one (see `touchedSinceCount`). Returns
/// true when the enable gate is open AND enough new work has accumulated AND
/// enough time has passed since the last run. Thresholds come from `cfg` with
/// the defensive clamp in `minSessions`/`minHours` (background-svc-04).
pub fn shouldAutoDream(allocator: std.mem.Allocator, cfg: *const config.Config, touched_since_count: usize) bool {
    if (!isGateOpen(cfg)) return false;
    if (touched_since_count < minSessions(cfg)) return false;
    return shouldTimeGatePass(allocator, cfg);
}

/// Outcome of an `acquireLock` attempt. `acquired` says whether this caller now
/// holds the lock; `prior_mtime_sec` carries the last-consolidation timestamp
/// (Unix seconds) that was in effect *before* this acquire, so a failed fork
/// can roll the marker back to it via `rollbackConsolidation`. A value of 0
/// means "no prior marker" (never consolidated) -- rollback then deletes the
/// marker rather than rewinding it.
pub const AcquireResult = struct {
    acquired: bool,
    prior_mtime_sec: i64,
};

/// Try to acquire the consolidation lock. Returns `acquired = true` when this
/// caller now holds the lock.
///
/// Mirrors `core/kairos_lock.zig:acquireCronLock` (background-svc-03):
///   1. The lock body is the holder's OS PID (real `getpid`, not a thread id).
///   2. An exclusive create gives kernel-enforced single ownership; a fresh
///      `PathAlreadyExists` only blocks if the existing holder is provably
///      alive (`pidAlive`) AND its mtime is younger than `HOLDER_STALE_SECS`.
///      Otherwise the stale/dead lock is reclaimed (deleted + recreated).
///   3. After reclaiming, the PID is re-read; if it is not ours we lost a
///      two-reclaimer race and bail (acquired = false).
///
/// The returned `prior_mtime_sec` is the last-consolidation timestamp before
/// this acquire (0 = never), captured for rollback-on-failure.
pub fn acquireLock(allocator: std.mem.Allocator) AcquireResult {
    const lock_path = lockFilePath(allocator) catch return .{ .acquired = false, .prior_mtime_sec = 0 };
    defer allocator.free(lock_path);

    const marker_path = lastRunMarkerPath(allocator) catch return .{ .acquired = false, .prior_mtime_sec = 0 };
    defer allocator.free(marker_path);

    const memory_dir = memory.memoryDirPathPub(allocator) catch return .{ .acquired = false, .prior_mtime_sec = 0 };
    defer allocator.free(memory_dir);
    paths.ensureDir(memory_dir) catch return .{ .acquired = false, .prior_mtime_sec = 0 };

    const prior = lastConsolidatedAtSecAtPath(marker_path) orelse 0;
    const acquired = acquireLockAtPath(allocator, lock_path);
    return .{ .acquired = acquired, .prior_mtime_sec = prior };
}

/// Path-injectable core of `acquireLock` (no marker/dir resolution). Lets the
/// reclaim/steal logic be exercised against a tmp-dir lock file in tests.
pub fn acquireLockAtPath(allocator: std.mem.Allocator, lock_path: []const u8) bool {
    if (tryCreateLock(lock_path)) return true;

    // Exclusive create failed -- either the path exists (held) or another
    // error. Only steal when the existing holder is provably stale or dead.
    const stat = std.Io.Dir.cwd().statFile(rt.io, lock_path, .{}) catch return false;
    const lock_age_sec = clock.nowSeconds() - @as(i64, @intCast(@divTrunc(stat.mtime.toNanoseconds(), std.time.ns_per_s)));

    const content = std.Io.Dir.cwd().readFileAlloc(rt.io, lock_path, allocator, .limited(64)) catch return false;
    defer allocator.free(content);
    const holder = parseLockPid(content);

    // Held by a live holder within the staleness window: do not steal.
    if (lock_age_sec < HOLDER_STALE_SECS) {
        if (holder) |pid| {
            if (pidAlive(pid)) return false;
        }
    }

    // Stale (too old) or dead holder: reclaim.
    std.Io.Dir.cwd().deleteFile(rt.io, lock_path) catch return false;
    if (!tryCreateLock(lock_path)) return false;

    // Re-read the PID to resolve a two-reclaimer race: if the body is no longer
    // ours, another reclaimer won.
    const reread = std.Io.Dir.cwd().readFileAlloc(rt.io, lock_path, allocator, .limited(64)) catch return false;
    defer allocator.free(reread);
    const reread_pid = parseLockPid(reread) orelse return false;
    return reread_pid == getpid();
}

/// Release the consolidation lock and stamp the last-run timestamp = now.
/// Deletes the exclusive lock file and writes "now" (Unix seconds) into the
/// separate marker file body that the time gate reads.
pub fn releaseLock(allocator: std.mem.Allocator) void {
    const lock_path = lockFilePath(allocator) catch return;
    defer allocator.free(lock_path);
    std.Io.Dir.cwd().deleteFile(rt.io, lock_path) catch {};

    const marker_path = lastRunMarkerPath(allocator) catch return;
    defer allocator.free(marker_path);
    stampMarkerAtPath(marker_path, clock.nowSeconds());
}

/// Roll the last-consolidation marker back to its prior value after a failed
/// dream fork, so the 24h time gate fires again rather than resetting as if
/// the dream had succeeded (background-svc-03). Pass the `prior_mtime_sec` from
/// the `AcquireResult`. A prior of 0 means there was no marker, so the marker
/// is deleted; any other value is written back into the body. Best-effort.
///
/// Callers that roll back should call this *instead of* `releaseLock`: it both
/// removes the lock file (so the lock is not left dangling) and rewinds the
/// marker, whereas `releaseLock` would stamp the marker = now (resetting the
/// gate as if the dream had succeeded).
pub fn rollbackConsolidation(allocator: std.mem.Allocator, prior_mtime_sec: i64) void {
    const lock_path = lockFilePath(allocator) catch return;
    defer allocator.free(lock_path);
    std.Io.Dir.cwd().deleteFile(rt.io, lock_path) catch {};

    const marker_path = lastRunMarkerPath(allocator) catch return;
    defer allocator.free(marker_path);
    rollbackMarkerAtPath(marker_path, prior_mtime_sec);
}

/// Optimistically stamp the last-consolidation marker = now at manual `/dream`
/// start, before the consolidation skill runs (background-svc-06). Mirrors the
/// reference's `recordConsolidation` (services/autoDream/consolidationLock.ts:
/// 126-140), which writes the lock file optimistically at prompt-build time.
///
/// The semantic difference from relying on `releaseLock` alone is the
/// crash-mid-run case: if the manual run errors (or is Ctrl-C'd) after this
/// stamp, the marker already reflects "consolidated now", so the auto-dream
/// time gate is reset rather than firing again immediately. Best-effort.
///
/// Goes through the same `stampMarkerAtPath` helper as the success-path
/// `releaseLock`, so the marker body format stays consistent with
/// `lastConsolidatedAtSec`.
pub fn recordConsolidation(allocator: std.mem.Allocator) void {
    const memory_dir = memory.memoryDirPathPub(allocator) catch return;
    defer allocator.free(memory_dir);
    paths.ensureDir(memory_dir) catch {};

    const marker_path = lastRunMarkerPath(allocator) catch return;
    defer allocator.free(marker_path);
    stampMarkerAtPath(marker_path, clock.nowSeconds());
}

/// Path-injectable core of `rollbackConsolidation` (marker only, no lock).
pub fn rollbackMarkerAtPath(marker_path: []const u8, prior_mtime_sec: i64) void {
    if (prior_mtime_sec == 0) {
        std.Io.Dir.cwd().deleteFile(rt.io, marker_path) catch {};
        return;
    }
    stampMarkerAtPath(marker_path, prior_mtime_sec);
}

/// Write the marker body as a decimal Unix-seconds integer at an explicit
/// path. Best-effort. Public so the now-stamp behaviour can be exercised in
/// tests against a tmp-dir marker.
pub fn stampMarkerAtPath(marker_path: []const u8, secs: i64) void {
    const file = std.Io.Dir.cwd().createFile(rt.io, marker_path, .{ .truncate = true }) catch return;
    defer file.close(rt.io);
    var buf: [24]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{d}", .{secs}) catch return;
    file.writeStreamingAll(rt.io, body) catch {};
}

/// Exclusive-create the lock file and write our OS PID as the body. Returns
/// true only when this call created the file. PathAlreadyExists (held) and any
/// other error return false. Mirrors kairos's `tryCreateLock`.
fn tryCreateLock(lock_path: []const u8) bool {
    const file = std.Io.Dir.cwd().createFile(rt.io, lock_path, .{
        .truncate = true,
        .exclusive = true,
    }) catch return false;
    defer file.close(rt.io);

    var buf: [20]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&buf, "{d}", .{getpid()}) catch return false;
    file.writeStreamingAll(rt.io, pid_str) catch return false;
    return true;
}

/// Parse the holder PID from a lock body (just a decimal integer, optionally
/// surrounded by whitespace). Returns null on malformed input.
fn parseLockPid(bytes: []const u8) ?i32 {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(i32, trimmed, 10) catch null;
}

/// Real OS PID (mirrors kairos_lock.zig's getpid switch; duplication is
/// intentional -- the two lock subsystems stay decoupled).
fn getpid() i32 {
    return switch (@import("builtin").os.tag) {
        .linux => std.os.linux.getpid(),
        else => std.c.getpid(),
    };
}

/// PID liveness via `kill(pid, 0)`: signal 0 posts nothing but reports whether
/// the process exists. Returns true only on syscall success; any error/nonzero
/// is treated as dead. Mirrors kairos_lock.zig's `pidAlive`.
fn pidAlive(pid: i32) bool {
    const pid_t: std.posix.pid_t = @intCast(pid);
    return switch (@import("builtin").os.tag) {
        .linux => std.os.linux.kill(pid_t, @enumFromInt(0)) == 0,
        else => std.c.kill(pid_t, @enumFromInt(0)) == 0,
    };
}

/// Build the dream consolidation prompt for the subagent.
pub fn buildDreamPrompt(allocator: std.mem.Allocator) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    try out.writer().writeAll(
        "You are the memory consolidation agent. Your job is to organize and clean up " ++
            "the persistent memory files in ~/.zcode/memory/ so they remain useful for future sessions.\n\n" ++
            "Follow this 4-phase process:\n\n" ++
            "## Phase 1: Orient\n" ++
            "- List the memory directory (ls ~/.zcode/memory/)\n" ++
            "- Read the MEMORY.md index if it exists\n" ++
            "- Skim existing topic files to understand current state\n\n" ++
            "## Phase 2: Analyze\n" ++
            "- Identify duplicate or overlapping memories\n" ++
            "- Find memories with relative dates (\"yesterday\", \"last week\") and convert to absolute\n" ++
            "- Spot contradictions between memories\n" ++
            "- Note stale memories that may no longer be accurate\n\n" ++
            "## Phase 3: Consolidate\n" ++
            "- Merge duplicate memories into single coherent files\n" ++
            "- Update memories with absolute dates\n" ++
            "- Delete memories that are clearly outdated or contradicted\n" ++
            "- Keep the most useful, actionable information\n" ++
            "- Each memory file should have YAML frontmatter (name, category) and clear content\n\n" ++
            "## Phase 4: Prune Index\n" ++
            "- Update MEMORY.md to have one line per memory file\n" ++
            "- Keep MEMORY.md under 200 lines\n" ++
            "- Remove pointers to deleted files\n" ++
            "- Shorten verbose entries\n\n" ++
            "Rules:\n" ++
            "- Only modify files in ~/.zcode/memory/\n" ++
            "- Do not create memories about this consolidation task itself\n" ++
            "- Prefer fewer, higher-quality memories over many small ones\n" ++
            "- Categories: user, feedback, project, reference\n" ++
            "- Be conservative: when unsure, keep the memory\n",
    );

    return out.toOwnedSlice();
}

/// Count the number of lines in MEMORY.md index.
pub fn countMemoryIndexLines(allocator: std.mem.Allocator) usize {
    const memory_dir = memory.memoryDirPathPub(allocator) catch return 0;
    defer allocator.free(memory_dir);

    const index_path = std.fs.path.join(allocator, &.{ memory_dir, "MEMORY.md" }) catch return 0;
    defer allocator.free(index_path);

    const content = std.Io.Dir.cwd().readFileAlloc(rt.io, index_path, allocator, .limited(64 * 1024)) catch return 0;
    defer allocator.free(content);

    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |_| count += 1;
    return count;
}

/// True when the trace names a file-editing tool (Edit/Write/MultiEdit, plus
/// their lowercase/underscore aliases). Mirrors the write-tool name set used by
/// extract_memories so the dream progress summary recognizes the same tools.
fn isEditOrWriteTool(name: []const u8) bool {
    return parse_helpers.matchesAnyName(name, &.{
        "Edit",      "edit",       "file_edit",
        "Write",     "write",      "file_write",
        "MultiEdit", "multi_edit", "file_multi_edit",
    });
}

/// Extract the unique set of file paths touched by Edit/Write/MultiEdit tool
/// calls in a turn's tool traces, for the "Improved N files" dream completion
/// message (background-svc-05). Mirrors the reference's
/// `makeDreamProgressWatcher` which pulls Edit/Write `file_path`s out of the
/// assistant turns (services/autoDream/autoDream.ts:281-313).
///
/// `traces` is any slice whose elements expose `.name: []const u8` and
/// `.args: []const u8` (the runtime's `ToolTrace`). Non-edit tools (Bash, Read,
/// Grep, ...) are ignored. Paths are deduplicated preserving first-seen order.
/// The returned slice and every string in it are owned by the caller.
pub fn extractTouchedFiles(allocator: std.mem.Allocator, traces: anytype) ![][]const u8 {
    var out = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit();
    }

    for (traces) |trace| {
        if (!isEditOrWriteTool(trace.name)) continue;
        const path = arg_parse.getArg(trace.args, "file_path") orelse
            arg_parse.getArg(trace.args, "path") orelse continue;
        if (path.len == 0) continue;

        // Deduplicate: a multi-round dream may touch the same file repeatedly.
        var already = false;
        for (out.items) |seen| {
            if (std.mem.eql(u8, seen, path)) {
                already = true;
                break;
            }
        }
        if (already) continue;

        try out.append(try allocator.dupe(u8, path));
    }

    return out.toOwnedSlice();
}

fn lockFilePath(allocator: std.mem.Allocator) ![]u8 {
    const memory_dir = try memory.memoryDirPathPub(allocator);
    defer allocator.free(memory_dir);
    return std.fs.path.join(allocator, &.{ memory_dir, ".consolidate-lock" });
}

fn lastRunMarkerPath(allocator: std.mem.Allocator) ![]u8 {
    const memory_dir = try memory.memoryDirPathPub(allocator);
    defer allocator.free(memory_dir);
    return std.fs.path.join(allocator, &.{ memory_dir, ".consolidate-last-run" });
}

const testing = std.testing;

const TestEntry = struct {
    id: []const u8,
    updated_ts: i64,
};

const TestTrace = struct {
    name: []const u8,
    args: []const u8,
};

test "extractTouchedFiles returns unique edit/write paths and ignores Bash" {
    const traces = [_]TestTrace{
        .{ .name = "Edit", .args = "file_path=a.zig, find=foo, replace=bar" },
        .{ .name = "Edit", .args = "file_path=b.zig, find=x, replace=y" },
        .{ .name = "Write", .args = "path=c.zig, content=hello" },
        .{ .name = "Bash", .args = "command=ls -la" },
    };

    const files = try extractTouchedFiles(testing.allocator, &traces);
    defer {
        for (files) |f| testing.allocator.free(f);
        testing.allocator.free(files);
    }

    // Three unique edited files; the Bash call is ignored.
    try testing.expectEqual(@as(usize, 3), files.len);
    try testing.expectEqualStrings("a.zig", files[0]);
    try testing.expectEqualStrings("b.zig", files[1]);
    try testing.expectEqualStrings("c.zig", files[2]);
}

test "extractTouchedFiles deduplicates repeated paths" {
    const traces = [_]TestTrace{
        .{ .name = "Write", .args = "path=MEMORY.md, content=v1" },
        .{ .name = "Edit", .args = "path=MEMORY.md, find=v1, replace=v2" },
        .{ .name = "Read", .args = "path=other.md" },
    };

    const files = try extractTouchedFiles(testing.allocator, &traces);
    defer {
        for (files) |f| testing.allocator.free(f);
        testing.allocator.free(files);
    }

    // MEMORY.md is touched twice but appears once; Read is ignored.
    try testing.expectEqual(@as(usize, 1), files.len);
    try testing.expectEqualStrings("MEMORY.md", files[0]);
}

test "shouldAutoDream returns false for low session count" {
    var cfg = try config.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);
    // Below the (default) minimum sessions threshold, regardless of the time
    // gate.
    try testing.expect(!shouldAutoDream(testing.allocator, &cfg, 2));
}

test "isGateOpen requires both auto_dream_enabled and auto_memory_enabled" {
    var cfg = try config.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    // Both default to unset (= ON downstream), so the gate is open. (Assumes
    // the auto-memory disable env vars are not set in the test environment,
    // which the custom test runner does not set.)
    cfg.auto_dream_enabled = null;
    cfg.auto_memory_enabled = null;
    try testing.expect(isGateOpen(&cfg));

    // Explicit true on both: still open.
    cfg.auto_dream_enabled = true;
    cfg.auto_memory_enabled = true;
    try testing.expect(isGateOpen(&cfg));

    // Off-switch on auto_dream_enabled closes the gate even with memory on.
    cfg.auto_dream_enabled = false;
    cfg.auto_memory_enabled = true;
    try testing.expect(!isGateOpen(&cfg));

    // Auto-memory disabled closes the gate even with dream explicitly on.
    cfg.auto_dream_enabled = true;
    cfg.auto_memory_enabled = false;
    try testing.expect(!isGateOpen(&cfg));
}

test "shouldAutoDream is closed when the enable gate is closed" {
    var cfg = try config.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    // Plenty of touched sessions, but the off-switch closes the whole gate.
    cfg.auto_dream_enabled = false;
    try testing.expect(!shouldAutoDream(testing.allocator, &cfg, 100));
}

test "minHours and minSessions resolve config with a defensive clamp" {
    var cfg = try config.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    // Defaults from Config.init.
    try testing.expectEqual(@as(i64, 24), minHours(&cfg));
    try testing.expectEqual(@as(usize, 5), minSessions(&cfg));

    // Explicit, in-range values pass through.
    cfg.auto_dream_min_hours = 12;
    cfg.auto_dream_min_sessions = 3;
    try testing.expectEqual(@as(i64, 12), minHours(&cfg));
    try testing.expectEqual(@as(usize, 3), minSessions(&cfg));

    // Zero falls back to the default.
    cfg.auto_dream_min_hours = 0;
    cfg.auto_dream_min_sessions = 0;
    try testing.expectEqual(@as(i64, 24), minHours(&cfg));
    try testing.expectEqual(@as(usize, 5), minSessions(&cfg));

    // Absurd values are clamped back to the default.
    cfg.auto_dream_min_hours = MAX_REASONABLE_MIN_HOURS + 1;
    cfg.auto_dream_min_sessions = MAX_REASONABLE_MIN_SESSIONS + 1;
    try testing.expectEqual(@as(i64, 24), minHours(&cfg));
    try testing.expectEqual(@as(usize, 5), minSessions(&cfg));
}

test "scanThrottlePasses is false within the interval and true after" {
    const interval = SESSION_SCAN_INTERVAL_NS;
    const last: i128 = 1_000_000_000_000; // arbitrary baseline

    // Just before the interval elapses: throttled.
    try testing.expect(!scanThrottlePasses(last + interval - 1, last));
    // Exactly at the interval: passes.
    try testing.expect(scanThrottlePasses(last + interval, last));
    // Well after: passes.
    try testing.expect(scanThrottlePasses(last + interval + 1, last));
    // Never-scanned default (last_scan_ns == 0) always passes.
    try testing.expect(scanThrottlePasses(interval, 0));
}

test "touchedSinceCount counts newer non-current sessions" {
    const entries = [_]TestEntry{
        .{ .id = "S10", .updated_ts = 10 },
        .{ .id = "S200", .updated_ts = 200 },
        .{ .id = "S300", .updated_ts = 300 },
    };
    // last_run = 100, current = "S300" (mtime 300). Only the mtime-200 entry
    // counts: the mtime-10 entry is too old, the current session is excluded.
    try testing.expectEqual(@as(usize, 1), touchedSinceCount(&entries, 100, "S300"));
}

test "touchedSinceCount with never-consolidated counts all non-current" {
    const entries = [_]TestEntry{
        .{ .id = "S10", .updated_ts = 10 },
        .{ .id = "S200", .updated_ts = 200 },
        .{ .id = "S300", .updated_ts = 300 },
    };
    // null last_run = never consolidated, so every non-current entry counts.
    try testing.expectEqual(@as(usize, 2), touchedSinceCount(&entries, null, "S300"));
}

test "lastConsolidatedAtSecAtPath returns recent value after marker write" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(base);

    const marker_path = try std.fs.path.join(testing.allocator, &.{ base, ".consolidate-last-run" });
    defer testing.allocator.free(marker_path);

    // Absent marker = "never consolidated" = null.
    try testing.expect(lastConsolidatedAtSecAtPath(marker_path) == null);

    const file = try std.Io.Dir.cwd().createFile(rt.io, marker_path, .{ .truncate = true });
    file.close(rt.io);

    const got = lastConsolidatedAtSecAtPath(marker_path) orelse return error.MarkerMissing;
    const now = clock.nowSeconds();
    // The marker was just written, so its mtime should be within a few seconds
    // of now.
    try testing.expect(now - got < 5);
    try testing.expect(now - got >= 0);
}

test "lastConsolidatedAtSecAtPath reads the body-stored timestamp" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(base);

    const marker_path = try std.fs.path.join(testing.allocator, &.{ base, ".consolidate-last-run" });
    defer testing.allocator.free(marker_path);

    // The stored body integer wins over the file mtime.
    stampMarkerAtPath(marker_path, 1_700_000_000);
    try testing.expectEqual(@as(?i64, 1_700_000_000), lastConsolidatedAtSecAtPath(marker_path));
}

/// Test helper: write a lock file with an explicit PID body at `path`.
fn writeLockWithPid(path: []const u8, pid: i32) !void {
    const file = try std.Io.Dir.cwd().createFile(rt.io, path, .{ .truncate = true });
    defer file.close(rt.io);
    var buf: [20]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{d}", .{pid});
    try file.writeStreamingAll(rt.io, body);
}

test "acquireLockAtPath reclaims a lock held by a dead PID" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(base);

    const lock_path = try std.fs.path.join(testing.allocator, &.{ base, ".consolidate-lock" });
    defer testing.allocator.free(lock_path);

    // A PID that is almost certainly not running. The file mtime is recent, so
    // the only reason it can be reclaimed is the dead-PID check.
    try writeLockWithPid(lock_path, 999_999);

    try testing.expect(acquireLockAtPath(testing.allocator, lock_path));

    // After reclaim the lock body should be our own PID.
    const content = try std.Io.Dir.cwd().readFileAlloc(rt.io, lock_path, testing.allocator, .limited(64));
    defer testing.allocator.free(content);
    const holder = parseLockPid(content) orelse return error.NoPid;
    try testing.expectEqual(getpid(), holder);
}

test "acquireLockAtPath refuses a lock held by a live PID" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(base);

    const lock_path = try std.fs.path.join(testing.allocator, &.{ base, ".consolidate-lock" });
    defer testing.allocator.free(lock_path);

    // Our own PID is alive, and the lock mtime is fresh, so the lock is held.
    try writeLockWithPid(lock_path, getpid());

    try testing.expect(!acquireLockAtPath(testing.allocator, lock_path));
}

test "acquireLockAtPath acquires a free path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(base);

    const lock_path = try std.fs.path.join(testing.allocator, &.{ base, ".consolidate-lock" });
    defer testing.allocator.free(lock_path);

    try testing.expect(acquireLockAtPath(testing.allocator, lock_path));
    // A second attempt now sees our own live PID and refuses.
    try testing.expect(!acquireLockAtPath(testing.allocator, lock_path));
}

test "rollbackMarkerAtPath rewinds to the prior timestamp" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(base);

    const marker_path = try std.fs.path.join(testing.allocator, &.{ base, ".consolidate-last-run" });
    defer testing.allocator.free(marker_path);

    // Simulate a successful stamp (= now), then roll back to a prior value so
    // the time gate fires again rather than resetting to now.
    stampMarkerAtPath(marker_path, clock.nowSeconds());
    const prior: i64 = 1_600_000_000;
    rollbackMarkerAtPath(marker_path, prior);
    try testing.expectEqual(@as(?i64, prior), lastConsolidatedAtSecAtPath(marker_path));
}

test "rollbackMarkerAtPath with prior 0 deletes the marker" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(base);

    const marker_path = try std.fs.path.join(testing.allocator, &.{ base, ".consolidate-last-run" });
    defer testing.allocator.free(marker_path);

    // No prior marker (prior == 0): rollback removes the marker entirely.
    stampMarkerAtPath(marker_path, clock.nowSeconds());
    rollbackMarkerAtPath(marker_path, 0);
    try testing.expect(lastConsolidatedAtSecAtPath(marker_path) == null);
}

test "recordConsolidation optimistically stamps the marker = now" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(base);

    const marker_path = try std.fs.path.join(testing.allocator, &.{ base, ".consolidate-last-run" });
    defer testing.allocator.free(marker_path);

    // recordConsolidation resolves the real memory dir, so exercise its exact
    // marker-stamp behaviour against a tmp-dir path instead. It is the same
    // `stampMarkerAtPath(now)` write recordConsolidation performs: after the
    // optimistic stamp the time gate reads back a value ~now, so a crash
    // mid-/dream leaves the auto-dream gate reset rather than firing again.
    try testing.expect(lastConsolidatedAtSecAtPath(marker_path) == null);
    stampMarkerAtPath(marker_path, clock.nowSeconds());
    const got = lastConsolidatedAtSecAtPath(marker_path) orelse return error.MarkerMissing;
    const now = clock.nowSeconds();
    try testing.expect(now - got < 5);
    try testing.expect(now - got >= 0);
}

test "stampMarkerAtPath records a timestamp near now" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(base);

    const marker_path = try std.fs.path.join(testing.allocator, &.{ base, ".consolidate-last-run" });
    defer testing.allocator.free(marker_path);

    // This is the success-path behaviour of releaseLock: stamp the marker = now.
    stampMarkerAtPath(marker_path, clock.nowSeconds());
    const got = lastConsolidatedAtSecAtPath(marker_path) orelse return error.MarkerMissing;
    const now = clock.nowSeconds();
    try testing.expect(now - got < 5);
    try testing.expect(now - got >= 0);
}
