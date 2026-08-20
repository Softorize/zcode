//! Per-attribute telemetry INCLUDE/EXCLUDE + cardinality controls
//! (analytics-10).
//!
//! Ports the intent of claude-code-main/src/utils/telemetryAttributes.ts: the
//! reference exposes per-attribute OTEL_METRICS_INCLUDE_* toggles plus implicit
//! cardinality caps so high-cardinality attributes (session ids, versions) can
//! be dropped before metrics/records are exported. We generalize that to two
//! config-driven controls applied at the telemetry-record emission site:
//!
//!   1. An explicit key allowlist. When set, only attributes whose key is in
//!      the list survive; everything else is dropped. (null = emit all keys.)
//!   2. A per-key cardinality limit. The first N distinct values of any single
//!      key pass through verbatim; the (N+1)-th and later distinct values are
//!      collapsed to the literal "<other>". (null = unbounded.) The limit IS
//!      the memory bound on the tracker's per-key value set, so a hostile
//!      high-cardinality stream cannot grow memory without bound.
//!
//! The filter is intentionally pure (no fs / config / global access): the
//! caller passes the allowlist and limit explicitly, so it is testable in
//! isolation without the full audit-log path. The stateful cardinality book-
//! keeping lives in `CardinalityTracker`, which the emission site keeps alive
//! across calls so distinct-value counts accumulate over the session.

const std = @import("std");

pub const OTHER_VALUE = "<other>";

/// A single telemetry attribute key/value pair. Values are borrowed; the
/// filter never takes ownership and never allocates value bytes (it only ever
/// substitutes the static OTHER_VALUE constant).
pub const Attribute = struct {
    key: []const u8,
    value: []const u8,
};

/// Returns true when `key` is permitted by `allowlist`. A null allowlist means
/// "no filtering" (every key is allowed). An empty (non-null) allowlist drops
/// every attribute.
pub fn keyAllowed(allowlist: ?[]const []const u8, key: []const u8) bool {
    const list = allowlist orelse return true;
    for (list) |allowed| {
        if (std.mem.eql(u8, allowed, key)) return true;
    }
    return false;
}

/// Tracks, per attribute key, the set of distinct values already emitted so a
/// cardinality limit can collapse overflow values to OTHER_VALUE. Bounded: each
/// key's value set never grows past the active limit (overflow values are not
/// stored). Owns the key/value copies it stores; free with `deinit`.
pub const CardinalityTracker = struct {
    allocator: std.mem.Allocator,
    /// key -> set of distinct values seen so far (each a StringHashMap used as a set).
    keys: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)) = .{},

    pub fn init(allocator: std.mem.Allocator) CardinalityTracker {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CardinalityTracker) void {
        var it = self.keys.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var vit = entry.value_ptr.iterator();
            while (vit.next()) |ventry| {
                self.allocator.free(ventry.key_ptr.*);
            }
            entry.value_ptr.deinit(self.allocator);
        }
        self.keys.deinit(self.allocator);
    }

    /// Resolve the value to emit for (key, value) under `limit`. A null limit
    /// passes the value through unchanged. Otherwise:
    ///   - if the value was already seen for this key, return it verbatim;
    ///   - if it is new and the key has < limit distinct values, record it and
    ///     return it verbatim;
    ///   - if it is new and the key is already at `limit` distinct values,
    ///     return OTHER_VALUE without recording it (so the set stays bounded).
    /// A limit of 0 collapses every value to OTHER_VALUE.
    pub fn resolveValue(self: *CardinalityTracker, limit: ?usize, key: []const u8, value: []const u8) ![]const u8 {
        const cap = limit orelse return value;

        const gop = try self.keys.getOrPut(self.allocator, key);
        if (!gop.found_existing) {
            // Own the key so it outlives the borrowed caller slice.
            const owned_key = self.allocator.dupe(u8, key) catch |err| {
                _ = self.keys.remove(key);
                return err;
            };
            gop.key_ptr.* = owned_key;
            gop.value_ptr.* = .{};
        }

        const set = gop.value_ptr;
        if (set.contains(value)) return value;
        if (set.count() >= cap) return OTHER_VALUE;

        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        try set.put(self.allocator, owned_value, {});
        return value;
    }
};

/// Apply the allowlist + cardinality controls to `attrs`, appending surviving
/// (key, possibly-substituted-value) pairs to `out`. Pure with respect to the
/// inputs aside from advancing `tracker`'s distinct-value bookkeeping. The
/// caller owns `out` and its backing storage; values appended are either the
/// caller's borrowed slices or the static OTHER_VALUE, so nothing needs freeing
/// beyond the list itself.
pub fn filter(
    allocator: std.mem.Allocator,
    attrs: []const Attribute,
    allowlist: ?[]const []const u8,
    cardinality_limit: ?usize,
    tracker: *CardinalityTracker,
    out: *std.ArrayListUnmanaged(Attribute),
) !void {
    for (attrs) |attr| {
        if (!keyAllowed(allowlist, attr.key)) continue;
        const value = try tracker.resolveValue(cardinality_limit, attr.key, attr.value);
        try out.append(allocator, .{ .key = attr.key, .value = value });
    }
}

// ---------------------------------------------------------------------------
// Process-global active controls
// ---------------------------------------------------------------------------
//
// The telemetry-record emission site (agent_tools.logToolInvocationRecord) is a
// chokepoint reached from ~28 call sites that do not carry the Config. Rather
// than thread two new parameters through every one of them, the config loader
// installs the resolved controls here once at startup via `configure`, and the
// emission site reads them through `shouldFilter` / `apply`. The default is
// no-op (null allowlist, null limit, no tracker) so behaviour is unchanged
// unless a user opts in. This mirrors how the egress allowlist is resolved once
// and consulted at the network chokepoint rather than passed everywhere.

var g_allowlist: ?[]const []const u8 = null;
var g_cardinality_limit: ?usize = null;
var g_tracker: ?CardinalityTracker = null;

/// Install the active controls (call once at startup from the config loader).
/// `allowlist` must outlive the process or until the next `configure` call; the
/// holder borrows it. Resets the cardinality tracker so distinct-value counts
/// start fresh.
pub fn configure(allocator: std.mem.Allocator, allowlist: ?[]const []const u8, cardinality_limit: ?usize) void {
    if (g_tracker) |*t| t.deinit();
    g_allowlist = allowlist;
    g_cardinality_limit = cardinality_limit;
    g_tracker = if (allowlist != null or cardinality_limit != null)
        CardinalityTracker.init(allocator)
    else
        null;
}

/// Release the global tracker (call at shutdown). Safe to call when unset.
pub fn reset() void {
    if (g_tracker) |*t| t.deinit();
    g_tracker = null;
    g_allowlist = null;
    g_cardinality_limit = null;
}

/// True when at least one control is active, so the emission site can keep its
/// fast unfiltered path when nothing is configured.
pub fn active() bool {
    return g_allowlist != null or g_cardinality_limit != null;
}

/// Apply the process-global controls to `attrs` using the shared tracker.
/// No-op (copies all attrs through) when nothing is configured.
pub fn apply(allocator: std.mem.Allocator, attrs: []const Attribute, out: *std.ArrayListUnmanaged(Attribute)) !void {
    if (g_tracker) |*t| {
        try filter(allocator, attrs, g_allowlist, g_cardinality_limit, t, out);
    } else {
        try out.appendSlice(allocator, attrs);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "keyAllowed: null allowlist permits everything" {
    try testing.expect(keyAllowed(null, "tool_name"));
    try testing.expect(keyAllowed(null, "anything"));
}

test "keyAllowed: explicit allowlist only permits listed keys" {
    const allow = [_][]const u8{"tool_name"};
    try testing.expect(keyAllowed(&allow, "tool_name"));
    try testing.expect(!keyAllowed(&allow, "args_hash"));
}

test "keyAllowed: empty non-null allowlist drops everything" {
    const allow = [_][]const u8{};
    try testing.expect(!keyAllowed(&allow, "tool_name"));
}

test "filter: allowlist of [tool_name] emits only tool_name" {
    const alloc = testing.allocator;
    var tracker = CardinalityTracker.init(alloc);
    defer tracker.deinit();

    const attrs = [_]Attribute{
        .{ .key = "tool_name", .value = "Read" },
        .{ .key = "args_hash", .value = "123" },
        .{ .key = "risk_tier", .value = "LOW" },
    };
    const allow = [_][]const u8{"tool_name"};

    var out: std.ArrayListUnmanaged(Attribute) = .empty;
    defer out.deinit(alloc);
    try filter(alloc, &attrs, &allow, null, &tracker, &out);

    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("tool_name", out.items[0].key);
    try testing.expectEqualStrings("Read", out.items[0].value);
}

test "filter: null allowlist keeps all attributes" {
    const alloc = testing.allocator;
    var tracker = CardinalityTracker.init(alloc);
    defer tracker.deinit();

    const attrs = [_]Attribute{
        .{ .key = "tool_name", .value = "Read" },
        .{ .key = "args_hash", .value = "123" },
    };

    var out: std.ArrayListUnmanaged(Attribute) = .empty;
    defer out.deinit(alloc);
    try filter(alloc, &attrs, null, null, &tracker, &out);

    try testing.expectEqual(@as(usize, 2), out.items.len);
}

test "filter: cardinality limit 2 collapses the third distinct value to <other>" {
    const alloc = testing.allocator;
    var tracker = CardinalityTracker.init(alloc);
    defer tracker.deinit();

    // Three calls each carrying a distinct value of the same key. With a limit
    // of 2, the first two distinct values pass through and the third becomes
    // "<other>".
    const a = [_]Attribute{.{ .key = "tool_name", .value = "Read" }};
    const b = [_]Attribute{.{ .key = "tool_name", .value = "Write" }};
    const c = [_]Attribute{.{ .key = "tool_name", .value = "Bash" }};

    var out: std.ArrayListUnmanaged(Attribute) = .empty;
    defer out.deinit(alloc);

    try filter(alloc, &a, null, 2, &tracker, &out);
    try filter(alloc, &b, null, 2, &tracker, &out);
    try filter(alloc, &c, null, 2, &tracker, &out);

    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqualStrings("Read", out.items[0].value);
    try testing.expectEqualStrings("Write", out.items[1].value);
    try testing.expectEqualStrings(OTHER_VALUE, out.items[2].value);
}

test "filter: a repeated value within the limit always passes through verbatim" {
    const alloc = testing.allocator;
    var tracker = CardinalityTracker.init(alloc);
    defer tracker.deinit();

    const a = [_]Attribute{.{ .key = "tool_name", .value = "Read" }};
    const b = [_]Attribute{.{ .key = "tool_name", .value = "Write" }};

    var out: std.ArrayListUnmanaged(Attribute) = .empty;
    defer out.deinit(alloc);

    // Read, Write, Read again, Write again -- only two distinct values, all
    // under a limit of 2, so every value survives verbatim.
    try filter(alloc, &a, null, 2, &tracker, &out);
    try filter(alloc, &b, null, 2, &tracker, &out);
    try filter(alloc, &a, null, 2, &tracker, &out);
    try filter(alloc, &b, null, 2, &tracker, &out);

    try testing.expectEqual(@as(usize, 4), out.items.len);
    try testing.expectEqualStrings("Read", out.items[2].value);
    try testing.expectEqualStrings("Write", out.items[3].value);
}

test "resolveValue: null limit always returns the value unchanged" {
    const alloc = testing.allocator;
    var tracker = CardinalityTracker.init(alloc);
    defer tracker.deinit();
    const v = try tracker.resolveValue(null, "k", "v");
    try testing.expectEqualStrings("v", v);
}

test "resolveValue: limit 0 collapses every value to <other>" {
    const alloc = testing.allocator;
    var tracker = CardinalityTracker.init(alloc);
    defer tracker.deinit();
    const v = try tracker.resolveValue(0, "k", "v");
    try testing.expectEqualStrings(OTHER_VALUE, v);
}

test "filter: cardinality tracked independently per key" {
    const alloc = testing.allocator;
    var tracker = CardinalityTracker.init(alloc);
    defer tracker.deinit();

    var out: std.ArrayListUnmanaged(Attribute) = .empty;
    defer out.deinit(alloc);

    // Two keys, each gets its own distinct-value budget of 1. The second value
    // of each key overflows independently.
    const r1 = [_]Attribute{ .{ .key = "a", .value = "1" }, .{ .key = "b", .value = "x" } };
    const r2 = [_]Attribute{ .{ .key = "a", .value = "2" }, .{ .key = "b", .value = "y" } };

    try filter(alloc, &r1, null, 1, &tracker, &out);
    try filter(alloc, &r2, null, 1, &tracker, &out);

    try testing.expectEqual(@as(usize, 4), out.items.len);
    try testing.expectEqualStrings("1", out.items[0].value);
    try testing.expectEqualStrings("x", out.items[1].value);
    try testing.expectEqualStrings(OTHER_VALUE, out.items[2].value);
    try testing.expectEqualStrings(OTHER_VALUE, out.items[3].value);
}
