const std = @import("std");

/// Fixed-capacity ring buffer that auto-evicts the oldest item on
/// overflow. Ports `CircularBuffer<T>` from
/// claude-code-main/src/utils/CircularBuffer.ts.
///
/// Use cases (mirrored from the reference):
///
///   * Last 1000 lines of streaming task output (TaskOutput.ts) so a
///     foreground viewer can show "tail" without keeping the full
///     stdout in memory.
///   * Last 100 errors recorded since process start (utils/log.ts
///     in-memory error log) so /feedback and bug reports can attach
///     a snapshot without re-running the failing command.
///   * Sliding window of WebSocket events for retry/replay
///     (cli/transports/WebSocketTransport.ts).
///
/// Ownership policy is intentionally explicit: this container does
/// NOT free items on its own. Items that hold their own resources
/// (allocated strings, file handles, ...) are the caller's
/// responsibility -- but `add()` returns the evicted item when an
/// overflow happens, so the caller has a clean hook to clean it up
/// without polling. `deinit()` releases the backing array but does
/// NOT touch any items still inside it; callers that need eager
/// cleanup should drain via `toArray()` first.
///
/// This matches the way the reference's TypeScript GC handles
/// eviction (the dropped item just becomes unreachable) while
/// staying explicit about lifetimes in Zig.
///
/// The struct is not thread-safe -- callers that share a buffer
/// across threads must hold an external mutex, exactly like the
/// reference (which assumes single-threaded JS).
pub fn CircularBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: []T,
        head: usize,
        size: usize,
        capacity: usize,
        allocator: std.mem.Allocator,

        /// Allocate a buffer of exactly `capacity` slots. `capacity`
        /// of zero is rejected because every helper would have to
        /// special-case it; pick at least 1.
        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            if (capacity == 0) return error.InvalidCapacity;
            const buf = try allocator.alloc(T, capacity);
            return .{
                .buffer = buf,
                .head = 0,
                .size = 0,
                .capacity = capacity,
                .allocator = allocator,
            };
        }

        /// Free the backing storage. Items still inside the buffer
        /// are NOT touched -- callers that own them (allocated
        /// strings, etc.) must drain via `toArray()` first or track
        /// ownership separately.
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
            self.buffer = &.{};
            self.head = 0;
            self.size = 0;
        }

        /// Push an item to the head. If the buffer was already full,
        /// the oldest item is evicted and returned so the caller can
        /// release any resources it owned. Returns null when no
        /// eviction happened.
        ///
        /// The returned item is the literal value that was stored
        /// (no copy), so for non-trivial T this lets the caller move
        /// ownership cleanly out of the ring.
        pub fn add(self: *Self, item: T) ?T {
            var evicted: ?T = null;
            if (self.size == self.capacity) {
                // Buffer full: the slot at `head` holds the oldest
                // item. Capture it before the overwrite.
                evicted = self.buffer[self.head];
            }
            self.buffer[self.head] = item;
            self.head = (self.head + 1) % self.capacity;
            if (self.size < self.capacity) {
                self.size += 1;
            }
            return evicted;
        }

        /// Push every item in `items` in order. Returns the number
        /// of evictions that happened so callers can sanity-check
        /// against expected overflow. Eviction notifications for
        /// individual items are NOT returned -- callers that need
        /// per-item cleanup must use `add()` in a loop themselves.
        ///
        /// This exists for the common case of "load N events into
        /// an empty buffer" where overflow doesn't matter.
        pub fn addAll(self: *Self, items: []const T) usize {
            var evictions: usize = 0;
            for (items) |item| {
                if (self.add(item) != null) evictions += 1;
            }
            return evictions;
        }

        /// Return the most recent N items in chronological order
        /// (oldest first, newest last). Returns at most `length()`
        /// items; asking for more than that is silently capped.
        ///
        /// The returned slice is owned by `out_allocator` and must
        /// be freed by the caller. The items themselves are shallow
        /// copies of what's in the buffer -- this matches the
        /// reference, which returns shallow copies via `[...arr]`.
        pub fn getRecent(
            self: *const Self,
            out_allocator: std.mem.Allocator,
            count: usize,
        ) ![]T {
            const available = @min(count, self.size);
            const out = try out_allocator.alloc(T, available);
            if (available == 0) return out;

            // Logical index of the oldest item we want = size - available.
            // Translate to a physical index in the ring.
            const start_logical = self.size - available;
            var i: usize = 0;
            while (i < available) : (i += 1) {
                const phys = self.physicalIndex(start_logical + i);
                out[i] = self.buffer[phys];
            }
            return out;
        }

        /// Return every item currently in the buffer in chronological
        /// order (oldest first). Equivalent to `getRecent(length())`
        /// but more discoverable. Caller owns the returned slice.
        pub fn toArray(self: *const Self, out_allocator: std.mem.Allocator) ![]T {
            return self.getRecent(out_allocator, self.size);
        }

        /// Drop every item without freeing the backing storage.
        /// Items are NOT released even if T owns external resources
        /// -- callers must drain via `toArray()` first when that
        /// matters. Capacity is preserved so subsequent adds don't
        /// re-allocate.
        pub fn clear(self: *Self) void {
            self.head = 0;
            self.size = 0;
        }

        /// Number of items currently stored. Reaches `capacity` and
        /// stays there once the ring fills up.
        pub fn length(self: *const Self) usize {
            return self.size;
        }

        /// Translate a logical index (0 = oldest) to the physical
        /// ring position. Out-of-range indices are not validated --
        /// callers must check `length()` first.
        fn physicalIndex(self: *const Self, logical: usize) usize {
            if (self.size < self.capacity) {
                // Buffer hasn't wrapped yet: items live in slots
                // [0, size), so logical == physical.
                return logical;
            }
            // Wrapped: the oldest item lives at `head` (the slot
            // about to be overwritten on the next add). Walk
            // forward from there.
            return (self.head + logical) % self.capacity;
        }
    };
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "CircularBuffer rejects zero capacity" {
    const Buf = CircularBuffer(u32);
    try testing.expectError(error.InvalidCapacity, Buf.init(testing.allocator, 0));
}

test "CircularBuffer starts empty" {
    var buf = try CircularBuffer(u32).init(testing.allocator, 4);
    defer buf.deinit();
    try testing.expectEqual(@as(usize, 0), buf.length());

    const empty = try buf.toArray(testing.allocator);
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}

test "CircularBuffer add under capacity returns no eviction" {
    var buf = try CircularBuffer(u32).init(testing.allocator, 4);
    defer buf.deinit();

    try testing.expect(buf.add(1) == null);
    try testing.expect(buf.add(2) == null);
    try testing.expect(buf.add(3) == null);
    try testing.expectEqual(@as(usize, 3), buf.length());

    const all = try buf.toArray(testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, all);
}

test "CircularBuffer add at capacity returns no eviction yet" {
    var buf = try CircularBuffer(u32).init(testing.allocator, 3);
    defer buf.deinit();
    try testing.expect(buf.add(1) == null);
    try testing.expect(buf.add(2) == null);
    try testing.expect(buf.add(3) == null);
    try testing.expectEqual(@as(usize, 3), buf.length());
}

test "CircularBuffer add over capacity evicts oldest" {
    var buf = try CircularBuffer(u32).init(testing.allocator, 3);
    defer buf.deinit();
    _ = buf.add(1);
    _ = buf.add(2);
    _ = buf.add(3);

    // Fourth add evicts the oldest (1).
    try testing.expectEqual(@as(?u32, 1), buf.add(4));
    try testing.expectEqual(@as(?u32, 2), buf.add(5));
    try testing.expectEqual(@as(usize, 3), buf.length());

    const all = try buf.toArray(testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqualSlices(u32, &.{ 3, 4, 5 }, all);
}

test "CircularBuffer addAll counts evictions" {
    var buf = try CircularBuffer(u32).init(testing.allocator, 3);
    defer buf.deinit();
    const evictions = buf.addAll(&.{ 1, 2, 3, 4, 5 });
    try testing.expectEqual(@as(usize, 2), evictions);

    const all = try buf.toArray(testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqualSlices(u32, &.{ 3, 4, 5 }, all);
}

test "CircularBuffer getRecent before wrap" {
    var buf = try CircularBuffer(u32).init(testing.allocator, 5);
    defer buf.deinit();
    _ = buf.addAll(&.{ 10, 20, 30 });

    const last_two = try buf.getRecent(testing.allocator, 2);
    defer testing.allocator.free(last_two);
    try testing.expectEqualSlices(u32, &.{ 20, 30 }, last_two);
}

test "CircularBuffer getRecent after wrap" {
    var buf = try CircularBuffer(u32).init(testing.allocator, 3);
    defer buf.deinit();
    _ = buf.addAll(&.{ 1, 2, 3, 4, 5 });

    // Buffer now holds {3, 4, 5}; ask for the most recent 2.
    const last_two = try buf.getRecent(testing.allocator, 2);
    defer testing.allocator.free(last_two);
    try testing.expectEqualSlices(u32, &.{ 4, 5 }, last_two);
}

test "CircularBuffer getRecent caps at length" {
    var buf = try CircularBuffer(u32).init(testing.allocator, 5);
    defer buf.deinit();
    _ = buf.addAll(&.{ 1, 2 });

    // Asked for 10; only 2 are available. The reference does the
    // same -- silent cap rather than padding or erroring.
    const got = try buf.getRecent(testing.allocator, 10);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, got);
}

test "CircularBuffer getRecent zero returns empty" {
    var buf = try CircularBuffer(u32).init(testing.allocator, 5);
    defer buf.deinit();
    _ = buf.addAll(&.{ 1, 2, 3 });

    const got = try buf.getRecent(testing.allocator, 0);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "CircularBuffer clear preserves capacity but resets length" {
    var buf = try CircularBuffer(u32).init(testing.allocator, 3);
    defer buf.deinit();
    _ = buf.addAll(&.{ 1, 2, 3 });
    try testing.expectEqual(@as(usize, 3), buf.length());

    buf.clear();
    try testing.expectEqual(@as(usize, 0), buf.length());
    // Still works after clear:
    _ = buf.add(99);
    const all = try buf.toArray(testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqualSlices(u32, &.{99}, all);
}

test "CircularBuffer toArray after wrap returns chronological order" {
    var buf = try CircularBuffer(u32).init(testing.allocator, 4);
    defer buf.deinit();
    // Fill, wrap once and a half.
    _ = buf.addAll(&.{ 1, 2, 3, 4, 5, 6 });

    const all = try buf.toArray(testing.allocator);
    defer testing.allocator.free(all);
    // After 6 adds into a 4-slot ring: held = {3,4,5,6} oldest first.
    try testing.expectEqualSlices(u32, &.{ 3, 4, 5, 6 }, all);
}

test "CircularBuffer with strings: caller must free evicted item" {
    // This test demonstrates the ownership contract. The buffer
    // does not free evicted items, but `add()` returns them so
    // the caller can.
    var buf = try CircularBuffer([]const u8).init(testing.allocator, 2);
    defer buf.deinit();

    const a = try testing.allocator.dupe(u8, "alpha");
    const b = try testing.allocator.dupe(u8, "beta");
    const c = try testing.allocator.dupe(u8, "gamma");

    try testing.expect(buf.add(a) == null);
    try testing.expect(buf.add(b) == null);

    // Third add evicts `a` -- caller frees it.
    if (buf.add(c)) |evicted| {
        try testing.expectEqualStrings("alpha", evicted);
        testing.allocator.free(evicted);
    } else {
        return error.ExpectedEviction;
    }

    // Drain the rest before deinit so we don't leak.
    const remaining = try buf.toArray(testing.allocator);
    defer testing.allocator.free(remaining);
    for (remaining) |s| testing.allocator.free(s);
}

test "CircularBuffer 1000-item smoke test like reference TaskOutput" {
    // The reference uses a 1000-line ring for streaming task output;
    // verify the indexing math holds at that scale.
    var buf = try CircularBuffer(u32).init(testing.allocator, 1000);
    defer buf.deinit();

    var i: u32 = 0;
    while (i < 5000) : (i += 1) _ = buf.add(i);

    try testing.expectEqual(@as(usize, 1000), buf.length());

    const recent_5 = try buf.getRecent(testing.allocator, 5);
    defer testing.allocator.free(recent_5);
    try testing.expectEqualSlices(u32, &.{ 4995, 4996, 4997, 4998, 4999 }, recent_5);
}

test "CircularBuffer struct items work the same as primitives" {
    const Event = struct { id: u32, kind: u8 };
    var buf = try CircularBuffer(Event).init(testing.allocator, 3);
    defer buf.deinit();
    _ = buf.add(.{ .id = 1, .kind = 'a' });
    _ = buf.add(.{ .id = 2, .kind = 'b' });
    _ = buf.add(.{ .id = 3, .kind = 'c' });
    _ = buf.add(.{ .id = 4, .kind = 'd' });

    const all = try buf.toArray(testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 3), all.len);
    try testing.expectEqual(@as(u32, 2), all[0].id);
    try testing.expectEqual(@as(u32, 3), all[1].id);
    try testing.expectEqual(@as(u32, 4), all[2].id);
}
