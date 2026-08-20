const std = @import("std");
const rt = @import("zcode_runtime");
const clock = @import("clock.zig");
const circular_buffer = @import("circular_buffer.zig");

/// Process-wide rolling in-memory error log. Ports the
/// `inMemoryErrorLog` mechanism from
/// claude-code-main/src/utils/log.ts, which keeps the most recent 100
/// errors so /feedback, bug reports, and the diagnostics screen can
/// attach them without re-running the failing command.
///
/// Why we need this even though the audit log already exists:
///
///   * The audit log is HMAC-signed JSONL on disk. Reading it back
///     requires opening a file, parsing each record, and validating
///     the chain hash -- expensive, and useless when the user just
///     wants "what just went wrong" in their REPL.
///   * The in-memory ring is O(1) read/write, lives entirely in RAM,
///     auto-evicts at capacity, and survives only for the lifetime
///     of the process. That matches the bug-report use case exactly:
///     show the user what their CURRENT session has hit so far.
///
/// API matches the reference's three exported helpers from
/// `utils/log.ts`:
///
///   record           -> addToInMemoryErrorLog
///   recent           -> getInMemoryErrors
///   clear            -> the `inMemoryErrorLog = []` assignment in
///                       the reset path
///
/// Thread safety: a single global mutex guards the ring. Concurrent
/// callers from the streaming response thread, the spinner thread,
/// and the main loop can all `record()` safely. Readers that hold
/// the returned slice get a deep copy, so they never observe
/// mutation mid-iteration.
const Entry = struct {
    /// Wall-clock unix timestamp (seconds) of when the error was
    /// recorded. Stored as i64 to match `clock.nowSeconds()`.
    timestamp: i64,
    /// Heap-owned message bytes. Owned by the ring; freed when the
    /// entry is evicted by overflow, or when the buffer is reset
    /// via `clear()`. Callers must NOT free this.
    message: []u8,
};

const RING_CAPACITY: usize = 100;

const RingType = circular_buffer.CircularBuffer(Entry);

var ring_state: ?RingType = null;
var ring_mutex: std.Io.Mutex = .init;
var ring_allocator: ?std.mem.Allocator = null;

/// Record an error message into the in-memory ring. The message is
/// duped into the global allocator so the caller can free its own
/// buffer immediately after the call. If the ring is full, the
/// oldest entry's heap message is freed before the new one is
/// added -- the ring owns its strings end to end.
///
/// First call lazily initialises the ring with the provided
/// allocator; later calls keep using the SAME allocator (the
/// initial one must outlive the process). If the ring is already
/// initialised with a different allocator, the request is
/// silently dropped to avoid cross-allocator frees on eviction.
pub fn record(allocator: std.mem.Allocator, message: []const u8) !void {
    ring_mutex.lock(rt.io) catch {};
    defer ring_mutex.unlock(rt.io);

    if (ring_state == null) {
        ring_state = try RingType.init(allocator, RING_CAPACITY);
        ring_allocator = allocator;
    } else if (ring_allocator) |existing| {
        if (existing.ptr != allocator.ptr) return; // mismatched, drop
    }

    const owned = try ring_allocator.?.dupe(u8, message);
    errdefer ring_allocator.?.free(owned);

    const entry = Entry{
        .timestamp = clock.nowSeconds(),
        .message = owned,
    };

    if (ring_state.?.add(entry)) |evicted| {
        // The ring evicted an old entry to make room. Free its
        // heap message so we don't leak across process lifetime.
        ring_allocator.?.free(evicted.message);
    }
}

/// Return up to `max` most recent entries (oldest first). The
/// returned slice and every contained `message` are heap-owned by
/// `out_allocator` -- the caller must `freeRecent()` it when
/// finished.
///
/// If the ring is uninitialised (no errors recorded yet), returns
/// an empty slice allocated through `out_allocator` so the caller
/// can free it uniformly.
pub fn recent(out_allocator: std.mem.Allocator, max: usize) ![]Entry {
    ring_mutex.lock(rt.io) catch {};
    defer ring_mutex.unlock(rt.io);

    if (ring_state == null) {
        return try out_allocator.alloc(Entry, 0);
    }

    const raw = try ring_state.?.getRecent(out_allocator, max);
    errdefer out_allocator.free(raw);

    // Deep-copy each message so the returned slice is independent
    // of the ring -- the caller can hold onto it across other
    // `record()` calls without worrying about eviction races.
    var i: usize = 0;
    errdefer {
        var j: usize = 0;
        while (j < i) : (j += 1) out_allocator.free(raw[j].message);
    }
    while (i < raw.len) : (i += 1) {
        const dup = try out_allocator.dupe(u8, raw[i].message);
        raw[i].message = dup;
    }
    return raw;
}

/// Free a slice returned by `recent()`. Releases every owned
/// message and then the slice itself. Safe to call on a slice of
/// length zero.
pub fn freeRecent(out_allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| out_allocator.free(e.message);
    out_allocator.free(entries);
}

/// Number of entries currently in the ring (capped at
/// `RING_CAPACITY`). Useful for status displays.
pub fn count() usize {
    ring_mutex.lock(rt.io) catch {};
    defer ring_mutex.unlock(rt.io);
    if (ring_state == null) return 0;
    return ring_state.?.length();
}

/// Drop every recorded entry and free its message. The ring stays
/// initialised so subsequent `record()` calls don't reallocate.
/// Mirrors the reference's `inMemoryErrorLog = []` reset path.
pub fn clear() void {
    ring_mutex.lock(rt.io) catch {};
    defer ring_mutex.unlock(rt.io);
    if (ring_state == null) return;
    // Capture the allocator into a local before any mutation so the
    // deferred free below can't see a null after `clear`/`reset`
    // race partners run.
    const alloc = ring_allocator.?;
    const all = ring_state.?.toArray(alloc) catch return;
    defer alloc.free(all);
    for (all) |e| alloc.free(e.message);
    ring_state.?.clear();
}

/// Test-only helper to fully tear down the ring between tests so
/// the global state doesn't leak across test cases. Outside tests
/// the ring lives for the entire process lifetime.
pub fn resetForTesting() void {
    ring_mutex.lock(rt.io) catch {};
    defer ring_mutex.unlock(rt.io);
    if (ring_state == null) return;
    // Capture the allocator into a local FIRST. Without this, the
    // deferred free below would dereference `ring_allocator` after
    // we've nulled it out, panicking with "attempt to use null
    // value".
    const alloc = ring_allocator.?;
    const all = ring_state.?.toArray(alloc) catch return;
    defer alloc.free(all);
    for (all) |e| alloc.free(e.message);
    ring_state.?.deinit();
    ring_state = null;
    ring_allocator = null;
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "error_log: starts empty" {
    resetForTesting();
    defer resetForTesting();
    try testing.expectEqual(@as(usize, 0), count());

    const got = try recent(testing.allocator, 10);
    defer freeRecent(testing.allocator, got);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "error_log: records and reads back a single error" {
    resetForTesting();
    defer resetForTesting();

    try record(testing.allocator, "boom: provider timeout");
    try testing.expectEqual(@as(usize, 1), count());

    const got = try recent(testing.allocator, 10);
    defer freeRecent(testing.allocator, got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("boom: provider timeout", got[0].message);
    try testing.expect(got[0].timestamp > 0);
}

test "error_log: respects capacity and evicts oldest" {
    resetForTesting();
    defer resetForTesting();

    // Record RING_CAPACITY + 5 entries; the first 5 should be evicted.
    var i: usize = 0;
    while (i < RING_CAPACITY + 5) : (i += 1) {
        var buf: [32]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "err-{d}", .{i});
        try record(testing.allocator, msg);
    }

    try testing.expectEqual(RING_CAPACITY, count());

    // After 105 inserts into a 100-slot ring, the held entries are
    // err-5..err-104. Asking for the most recent 5 returns
    // err-100..err-104 in chronological order (oldest first).
    const got = try recent(testing.allocator, 5);
    defer freeRecent(testing.allocator, got);
    try testing.expectEqual(@as(usize, 5), got.len);
    try testing.expectEqualStrings("err-100", got[0].message);
    try testing.expectEqualStrings("err-101", got[1].message);
    try testing.expectEqualStrings("err-104", got[4].message);
}

test "error_log: clear empties the ring without freeing capacity" {
    resetForTesting();
    defer resetForTesting();

    try record(testing.allocator, "first");
    try record(testing.allocator, "second");
    try testing.expectEqual(@as(usize, 2), count());

    clear();
    try testing.expectEqual(@as(usize, 0), count());

    // Still works after clear:
    try record(testing.allocator, "after-clear");
    try testing.expectEqual(@as(usize, 1), count());

    const got = try recent(testing.allocator, 5);
    defer freeRecent(testing.allocator, got);
    try testing.expectEqualStrings("after-clear", got[0].message);
}

test "error_log: recent caps at length" {
    resetForTesting();
    defer resetForTesting();

    try record(testing.allocator, "only");
    const got = try recent(testing.allocator, 50);
    defer freeRecent(testing.allocator, got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("only", got[0].message);
}

test "error_log: deep copies messages so reader is isolated from writer" {
    resetForTesting();
    defer resetForTesting();

    try record(testing.allocator, "first");
    const snapshot = try recent(testing.allocator, 10);
    defer freeRecent(testing.allocator, snapshot);

    // Add a second error after taking the snapshot.
    try record(testing.allocator, "second");

    // Snapshot must still show only the first error.
    try testing.expectEqual(@as(usize, 1), snapshot.len);
    try testing.expectEqualStrings("first", snapshot[0].message);
}

test "error_log: handles repeated record/clear cycles without leaking" {
    resetForTesting();
    defer resetForTesting();

    var cycle: usize = 0;
    while (cycle < 10) : (cycle += 1) {
        var i: usize = 0;
        while (i < 50) : (i += 1) {
            try record(testing.allocator, "cycle entry");
        }
        clear();
        try testing.expectEqual(@as(usize, 0), count());
    }
}
