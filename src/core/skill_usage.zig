//! Skill / custom-command usage tracking with a 7-day half-life ranking.
//!
//! Persists a small JSON map `{ "<name>": { "count": N, "last_used_ms": T } }`
//! under the zcode home (`~/.zcode/skill-usage.json`). On each invocation a
//! caller records a use (`recordSkill`); the suggestion ranker reads a score
//! (`scoreSkill` / `Snapshot`) that decays with time so frequently and
//! recently used skills float to the top of autocomplete.
//!
//! Mirrors the reference's `skillUsageTracking.ts`:
//!   recordSkillUsage  -> count + timestamp, 60s debounce per name
//!   getSkillUsageScore = count * max(0.5^(daysSinceUse/7), 0.1)
//!
//! Design notes (see Phase 13 Task 8 plan):
//!   - `now_ms` is an explicit parameter on the pure functions so tests are
//!     deterministic; the production wrappers supply `clock.nowMillis()`.
//!   - The storage path is an explicit parameter on the pure functions so
//!     tests can point at a tmp file; the production wrappers resolve
//!     `~/.zcode/skill-usage.json` via `core/paths.zig`.
//!   - Any I/O or parse failure is swallowed (treated as "no data"): usage
//!     ranking is a nicety, never a hard dependency, so it must never fail or
//!     block the caller.

const std = @import("std");
const rt = @import("zcode_runtime");
const json = std.json;

const clock = @import("clock.zig");
const rng = @import("rng.zig");
const paths = @import("paths.zig");
const std_io = @import("std_io.zig");

/// Debounce window: a second `record` for the same name within this many
/// milliseconds is ignored (matches the reference 60s debounce).
pub const debounce_ms: i64 = 60_000;

const ms_per_day: f64 = 86_400_000.0;
const half_life_days: f64 = 7.0;
const decay_floor: f64 = 0.1;

const Entry = struct {
    count: u64,
    last_used_ms: i64,
};

/// Compute the decayed usage score for a single entry at `now_ms`.
///   days  = (now - last_used) / 86_400_000
///   decay = max(0.5^(days / 7), 0.1)
///   score = count * decay
/// A name with no recorded use scores 0 (handled by callers passing count 0).
fn scoreEntry(entry: Entry, now_ms: i64) f64 {
    if (entry.count == 0) return 0;
    // Saturating, clamped to >= 0: a future-dated last_used_ms (hand-edited
    // file) must not yield a negative `days` and thus a decay above 1.0.
    const delta_ms: i64 = if (now_ms > entry.last_used_ms) now_ms - entry.last_used_ms else 0;
    const days: f64 = @as(f64, @floatFromInt(delta_ms)) / ms_per_day;
    const raw_decay = std.math.pow(f64, 0.5, days / half_life_days);
    const decay = @max(raw_decay, decay_floor);
    return @as(f64, @floatFromInt(entry.count)) * decay;
}

/// Read the whole map from `path`. Returns an entry for `name` if present.
/// Never fails: a missing file or malformed JSON yields null.
fn lookup(allocator: std.mem.Allocator, path: []const u8, name: []const u8) ?Entry {
    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(256 * 1024)) catch return null;
    defer allocator.free(bytes);

    var parsed = json.parseFromSlice(json.Value, allocator, bytes, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    const node = parsed.value.object.get(name) orelse return null;
    return entryFromValue(node);
}

/// Parse one `{ "count": N, "last_used_ms": T }` node. Tolerates missing or
/// wrong-typed fields by defaulting them.
fn entryFromValue(node: json.Value) ?Entry {
    if (node != .object) return null;
    const count: u64 = if (node.object.get("count")) |c| switch (c) {
        .integer => |i| if (i > 0) @intCast(i) else 0,
        else => 0,
    } else 0;
    const last_used_ms: i64 = if (node.object.get("last_used_ms")) |t| switch (t) {
        .integer => |i| i,
        else => 0,
    } else 0;
    return .{ .count = count, .last_used_ms = last_used_ms };
}

/// Pure score: read `path`, find `name`, decay against `now_ms`.
/// Unknown name (or no file) -> 0.
pub fn scoreAt(allocator: std.mem.Allocator, path: []const u8, name: []const u8, now_ms: i64) f64 {
    const entry = lookup(allocator, path, name) orelse return 0;
    return scoreEntry(entry, now_ms);
}

/// Pure record: read `path`, increment `name`'s count (debounced against
/// `now_ms`), write the map back. Swallows all I/O / parse errors so the
/// caller is never blocked.
pub fn recordAt(allocator: std.mem.Allocator, path: []const u8, name: []const u8, now_ms: i64) void {
    if (name.len == 0) return;

    // Collect the existing entries (preserving every name except the one we
    // are updating) plus the new/updated entry, then serialize the whole map
    // back. We build the JSON string by hand to avoid the ArrayHashMap
    // construction dance; the schema is a flat `{ name: { count, last_used_ms } }`.
    var others = std.array_list.Managed(NamedEntry).init(allocator);
    defer {
        for (others.items) |o| allocator.free(o.name);
        others.deinit();
    }

    var existing_count: u64 = 0;
    var existing_last_ms: i64 = 0;
    var had_existing = false;

    if (std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(256 * 1024))) |bytes| {
        defer allocator.free(bytes);
        if (json.parseFromSlice(json.Value, allocator, bytes, .{})) |parsed| {
            defer @constCast(&parsed).deinit();
            if (parsed.value == .object) {
                var it = parsed.value.object.iterator();
                while (it.next()) |kv| {
                    const entry = entryFromValue(kv.value_ptr.*) orelse continue;
                    if (std.mem.eql(u8, kv.key_ptr.*, name)) {
                        existing_count = entry.count;
                        existing_last_ms = entry.last_used_ms;
                        had_existing = true;
                        continue;
                    }
                    const dup = allocator.dupe(u8, kv.key_ptr.*) catch continue;
                    others.append(.{ .name = dup, .entry = entry }) catch {
                        allocator.free(dup);
                    };
                }
            }
        } else |_| {}
    } else |_| {}

    // Debounce: a second use within the window keeps count unchanged and
    // skips the write entirely. Only debounce when there was a prior use.
    if (had_existing and existing_count > 0 and now_ms >= existing_last_ms and now_ms - existing_last_ms < debounce_ms) {
        return;
    }

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    writeMap(out.writer(), name, .{ .count = existing_count + 1, .last_used_ms = now_ms }, others.items) catch return;

    writeFileAtomic(allocator, path, out.items()) catch {};
}

const NamedEntry = struct {
    name: []u8,
    entry: Entry,
};

/// Serialize `{ name: entry, ...others }` as a flat JSON object. Names are
/// emitted via the JSON string encoder so embedded quotes/backslashes are safe.
fn writeMap(w: *std.Io.Writer, name: []const u8, entry: Entry, others: []const NamedEntry) !void {
    try w.writeByte('{');
    var first = true;
    for (others) |o| {
        if (!first) try w.writeByte(',');
        first = false;
        try writeMember(w, o.name, o.entry);
    }
    if (!first) try w.writeByte(',');
    try writeMember(w, name, entry);
    try w.writeByte('}');
}

fn writeMember(w: *std.Io.Writer, name: []const u8, entry: Entry) !void {
    try json.Stringify.value(name, .{}, w);
    try w.print(":{{\"count\":{d},\"last_used_ms\":{d}}}", .{ entry.count, entry.last_used_ms });
}

/// A point-in-time snapshot of the usage map, so the suggestion ranker can
/// score many names without re-reading the file per comparison (the plan's
/// footgun: do not do disk I/O per keystroke / per comparator call).
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.StringHashMapUnmanaged(Entry),
    now_ms: i64,

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
    }

    /// Score `name` against the snapshot's captured `now_ms`. Unknown -> 0.
    pub fn score(self: *const Snapshot, name: []const u8) f64 {
        const entry = self.entries.get(name) orelse return 0;
        return scoreEntry(entry, self.now_ms);
    }
};

/// Load a snapshot from `path` at `now_ms`. Never fails: a missing file or
/// malformed JSON yields an empty snapshot (every score 0).
pub fn snapshotAt(parent: std.mem.Allocator, path: []const u8, now_ms: i64) Snapshot {
    var snap: Snapshot = .{
        .arena = std.heap.ArenaAllocator.init(parent),
        .entries = .{},
        .now_ms = now_ms,
    };
    const a = snap.arena.allocator();

    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, a, .limited(256 * 1024)) catch return snap;
    var parsed = json.parseFromSlice(json.Value, a, bytes, .{}) catch return snap;
    defer parsed.deinit();
    if (parsed.value != .object) return snap;

    var it = parsed.value.object.iterator();
    while (it.next()) |kv| {
        const entry = entryFromValue(kv.value_ptr.*) orelse continue;
        const key = a.dupe(u8, kv.key_ptr.*) catch continue;
        snap.entries.put(a, key, entry) catch {};
    }
    return snap;
}

// ---- production wrappers --------------------------------------------------

/// Resolve the absolute path to `~/.zcode/skill-usage.json`. Caller owns the
/// returned slice.
fn storagePath(allocator: std.mem.Allocator) ![]u8 {
    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);
    return std.fs.path.join(allocator, &.{ resolved.zcode_home, "skill-usage.json" });
}

/// Record a skill/command invocation. Production entry point used by the
/// dispatch sites. Swallows all errors.
pub fn recordSkill(allocator: std.mem.Allocator, name: []const u8) void {
    const path = storagePath(allocator) catch return;
    defer allocator.free(path);
    recordAt(allocator, path, name, clock.nowMillis());
}

/// Score a single skill/command by name. Convenience for callers that score
/// one name; the suggestion ranker should prefer `snapshot` to avoid repeated
/// disk reads.
pub fn scoreSkill(allocator: std.mem.Allocator, name: []const u8) f64 {
    const path = storagePath(allocator) catch return 0;
    defer allocator.free(path);
    return scoreAt(allocator, path, name, clock.nowMillis());
}

/// Load a usage snapshot for the suggestion ranker. Empty on any failure.
pub fn snapshot(parent: std.mem.Allocator) Snapshot {
    const path = storagePath(parent) catch {
        return .{
            .arena = std.heap.ArenaAllocator.init(parent),
            .entries = .{},
            .now_ms = clock.nowMillis(),
        };
    };
    defer parent.free(path);
    return snapshotAt(parent, path, clock.nowMillis());
}

// ---- atomic write ---------------------------------------------------------

fn writeFileAtomic(allocator: std.mem.Allocator, target: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(target)) |dir| {
        paths.ensureDir(dir) catch {};
    }

    var nonce: [8]u8 = undefined;
    rng.bytes(&nonce);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{x}{x}{x}{x}{x}{x}{x}{x}", .{
        target, nonce[0], nonce[1], nonce[2], nonce[3], nonce[4], nonce[5], nonce[6], nonce[7],
    });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, bytes);
        file.sync(rt.io) catch {};
    }
    try std.Io.Dir.renameAbsolute(tmp_path, target, rt.io);
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;
const test_helpers = @import("test_helpers.zig");

test "record increments count and score of a name used now equals count" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(alloc, &.{ try test_helpers.tmpDirCwd(alloc, &tmp), "skill-usage.json" });
    defer alloc.free(path);

    const now: i64 = 1_000_000_000_000;
    recordAt(alloc, path, "foo", now);

    // Used "now" -> decay 1.0 -> score == count == 1.
    try testing.expectApproxEqAbs(@as(f64, 1.0), scoreAt(alloc, path, "foo", now), 1e-9);
}

test "record debounces a second use within 60s" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(cwd);
    const path = try std.fs.path.join(alloc, &.{ cwd, "skill-usage.json" });
    defer alloc.free(path);

    const now: i64 = 1_000_000_000_000;
    recordAt(alloc, path, "foo", now);
    // 30s later: within the 60s window -> debounced, count stays 1. Score at
    // the original timestamp (decay 1.0) to read the raw count cleanly.
    recordAt(alloc, path, "foo", now + 30_000);
    try testing.expectApproxEqAbs(@as(f64, 1.0), scoreAt(alloc, path, "foo", now), 1e-9);

    // 61s after the first record: outside the window -> count becomes 2.
    recordAt(alloc, path, "foo", now + 61_000);
    try testing.expectApproxEqAbs(@as(f64, 2.0), scoreAt(alloc, path, "foo", now + 61_000), 1e-9);
}

test "score decays with a 7-day half-life and floors at 0.1" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(cwd);
    const path = try std.fs.path.join(alloc, &.{ cwd, "skill-usage.json" });
    defer alloc.free(path);

    const now: i64 = 1_000_000_000_000;
    recordAt(alloc, path, "foo", now);

    const day_ms: i64 = 86_400_000;
    // 14 days stale: 0.5^(14/7) = 0.25 -> count(1) * 0.25 = 0.25.
    try testing.expectApproxEqAbs(@as(f64, 0.25), scoreAt(alloc, path, "foo", now + 14 * day_ms), 1e-9);
    // 70 days stale: 0.5^10 = ~0.00098 floored to 0.1 -> count(1) * 0.1 = 0.1.
    try testing.expectApproxEqAbs(@as(f64, 0.1), scoreAt(alloc, path, "foo", now + 70 * day_ms), 1e-9);
}

test "unknown name scores zero" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(cwd);
    const path = try std.fs.path.join(alloc, &.{ cwd, "skill-usage.json" });
    defer alloc.free(path);

    const now: i64 = 1_000_000_000_000;
    // No file at all -> 0.
    try testing.expectEqual(@as(f64, 0), scoreAt(alloc, path, "nope", now));

    recordAt(alloc, path, "foo", now);
    // File exists but the queried name is absent -> 0.
    try testing.expectEqual(@as(f64, 0), scoreAt(alloc, path, "nope", now));
}

test "snapshot scores many names from one read" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(cwd);
    const path = try std.fs.path.join(alloc, &.{ cwd, "skill-usage.json" });
    defer alloc.free(path);

    const now: i64 = 1_000_000_000_000;
    recordAt(alloc, path, "foo", now);
    // Outside debounce so each recorded again increments.
    recordAt(alloc, path, "foo", now + debounce_ms);
    recordAt(alloc, path, "bar", now);

    var snap = snapshotAt(alloc, path, now + debounce_ms);
    defer snap.deinit();
    // foo used twice, second use at now+debounce -> count 2, decay ~1.0.
    try testing.expectApproxEqAbs(@as(f64, 2.0), snap.score("foo"), 1e-3);
    // bar used once at `now`, 60s stale -> decay ~1.0 still.
    try testing.expectApproxEqAbs(@as(f64, 1.0), snap.score("bar"), 1e-3);
    try testing.expectEqual(@as(f64, 0), snap.score("missing"));
}
