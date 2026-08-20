const std = @import("std");
const rt = @import("zcode_runtime");
const std_io = @import("std_io.zig");
const clock = @import("clock.zig");

/// Simple Prometheus-compatible metrics collector.
/// Thread-safe: all mutating operations acquire an internal mutex so that
/// concurrent provider/tool/executor threads can update counters without
/// corrupting the StringHashMap backing storage.
pub const Metrics = struct {
    allocator: std.mem.Allocator,
    counters: std.StringHashMap(u64),
    gauges: std.StringHashMap(f64),
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator) Metrics {
        return .{
            .allocator = allocator,
            .counters = std.StringHashMap(u64).init(allocator),
            .gauges = std.StringHashMap(f64).init(allocator),
        };
    }

    pub fn deinit(self: *Metrics) void {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        {
            var it = self.counters.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
            self.counters.deinit();
        }
        {
            var it = self.gauges.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
            self.gauges.deinit();
        }
    }

    pub fn increment(self: *Metrics, name: []const u8) void {
        self.incrementBy(name, 1);
    }

    pub fn incrementBy(self: *Metrics, name: []const u8, n: u64) void {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        if (self.counters.getPtr(name)) |val| {
            val.* += n;
        } else {
            const duped = self.allocator.dupe(u8, name) catch return;
            self.counters.put(duped, n) catch {
                self.allocator.free(duped);
            };
        }
    }

    pub fn setGauge(self: *Metrics, name: []const u8, value: f64) void {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        if (self.gauges.getPtr(name)) |val| {
            val.* = value;
        } else {
            const duped = self.allocator.dupe(u8, name) catch return;
            self.gauges.put(duped, value) catch {
                self.allocator.free(duped);
            };
        }
    }

    pub fn getCounter(self: *Metrics, name: []const u8) u64 {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        return self.counters.get(name) orelse 0;
    }

    pub fn getGauge(self: *Metrics, name: []const u8) f64 {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        return self.gauges.get(name) orelse 0.0;
    }

    /// Render all metrics in Prometheus text exposition format.
    pub fn renderPrometheus(self: *Metrics, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);

        var out = std_io.StringBuilder.init(allocator);
        errdefer out.deinit();
        const w = out.writer();

        try w.writeAll("# zcode metrics\n");

        var c_it = self.counters.iterator();
        while (c_it.next()) |entry| {
            try w.print("{s} {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        var g_it = self.gauges.iterator();
        while (g_it.next()) |entry| {
            try w.print("{s} {d:.6}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        return out.toOwnedSlice();
    }
};

/// Pre-defined metric names for consistency.
pub const Names = struct {
    pub const provider_requests_total = "zcode_provider_requests_total";
    pub const provider_errors_total = "zcode_provider_errors_total";
    pub const provider_latency_ms = "zcode_provider_latency_ms";
    pub const tool_executions_total = "zcode_tool_executions_total";
    pub const circuit_breaker_state = "zcode_circuit_breaker_state";
    pub const rate_limit_rejections = "zcode_rate_limit_rejections_total";
    /// Running total of lines added/removed across Write and Edit tool
    /// calls in this process. Matches Claude Code's
    /// cost-tracker.ts addToTotalLinesChanged counters, which drive the
    /// "Total code changes: X lines added, Y lines removed" display in
    /// /cost output. Process-scoped rather than session-scoped so a
    /// long-running REPL that outlives its session still accumulates.
    pub const lines_added_total = "zcode_lines_added_total";
    pub const lines_removed_total = "zcode_lines_removed_total";
    /// Running total of wall time spent inside provider HTTP calls,
    /// matching claude-code-main/src/bootstrap/state.ts
    /// totalAPIDuration. Feeds the "Total duration (API)" line in
    /// /cost output so users can see how much of their session was
    /// "the model is thinking" vs tool-execution vs idle.
    pub const api_duration_ms_total = "zcode_api_duration_ms_total";
};

/// Add to the per-process lines-added / lines-removed counters. Safe
/// to call from any thread. No-ops silently when the metrics instance
/// is not yet initialised (the once-guard behind globalMetrics makes
/// that a near-impossibility but we still guard the call sites).
pub fn addToTotalLinesChanged(added: u64, removed: u64) void {
    if (added > 0) globalMetrics().incrementBy(Names.lines_added_total, added);
    if (removed > 0) globalMetrics().incrementBy(Names.lines_removed_total, removed);
}

/// Add to the per-process API duration counter (milliseconds). Called
/// from the provider HTTP wrapper on every successful response so
/// /cost can report how much wall-clock time was spent waiting on
/// the model. Safe to call from any thread.
pub fn addToTotalApiDurationMs(ms: u64) void {
    if (ms > 0) globalMetrics().incrementBy(Names.api_duration_ms_total, ms);
}

/// Session start nanosecond timestamp. Captured lazily on first read
/// via std.once so every entry point (CLI, REPL, `run` one-shot)
/// gets the same epoch without having to thread an explicit init.
/// Feeds getSessionWallDurationMs() which /cost uses for the "Total
/// duration (wall)" line. Mirrors bootstrap/state.ts STATE.startTime.
var session_start_ns: i128 = 0;
var session_start_once_done: std.atomic.Value(bool) = .init(false);
fn session_start_onceCall() void {
    if (!session_start_once_done.swap(true, .acq_rel)) initSessionStart();
}

fn initSessionStart() void {
    session_start_ns = clock.nowNanos();
}

/// Milliseconds elapsed since the process started. Memoized via
/// std.once so the "zero point" stays stable regardless of which
/// module calls first.
pub fn getSessionWallDurationMs() u64 {
    session_start_onceCall();
    const now_ns: i128 = clock.nowNanos();
    const delta_ns = now_ns - session_start_ns;
    if (delta_ns <= 0) return 0;
    return @intCast(@divTrunc(delta_ns, std.time.ns_per_ms));
}

/// Count newlines in a slice. A trailing byte that isn't '\n' still
/// counts as its own line (so "a\nb" is 2 lines). Empty string is 0
/// lines so Write'ing an empty file doesn't inflate the counter.
/// Matches the reference's `content.split(/\r?\n/).length` semantics
/// for non-empty content.
pub fn countLines(text: []const u8) u64 {
    if (text.len == 0) return 0;
    var n: u64 = 0;
    for (text) |c| {
        if (c == '\n') n += 1;
    }
    // If the text doesn't end with '\n', the trailing piece is still a
    // line. "foo" -> 1, "foo\n" -> 1, "foo\nbar" -> 2, "foo\nbar\n" -> 2.
    if (text[text.len - 1] != '\n') n += 1;
    return n;
}

/// Global metrics instance backed by a page allocator.
/// Safe to call from anywhere without passing state around. The init is
/// guarded by a once-flag so two threads racing into globalMetrics() cannot
/// both initialize the StringHashMap.
var global_instance: Metrics = undefined;
var global_init_once_done: std.atomic.Value(bool) = .init(false);
fn global_init_onceCall() void {
    if (!global_init_once_done.swap(true, .acq_rel)) initGlobal();
}

fn initGlobal() void {
    global_instance = Metrics.init(std.heap.page_allocator);
}

pub fn globalMetrics() *Metrics {
    global_init_onceCall();
    return &global_instance;
}

/// Build a labeled metric name like "zcode_provider_requests_total{provider=\"openai\",model=\"gpt-4\"}".
pub fn labeledName(allocator: std.mem.Allocator, base: []const u8, labels: []const [2][]const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try out.appendSlice(base);
    if (labels.len > 0) {
        try out.append('{');
        for (labels, 0..) |label, idx| {
            if (idx > 0) try out.append(',');
            try out.writer().print("{s}=\"{s}\"", .{ label[0], label[1] });
        }
        try out.append('}');
    }
    return out.toOwnedSlice();
}

const testing = std.testing;

test "counter increment" {
    var m = Metrics.init(testing.allocator);
    defer m.deinit();

    m.increment("requests");
    m.increment("requests");
    try testing.expect(m.getCounter("requests") == 2);
}

test "gauge set and read" {
    var m = Metrics.init(testing.allocator);
    defer m.deinit();

    m.setGauge("latency", 42.5);
    try testing.expect(m.getGauge("latency") == 42.5);
}

test "render prometheus format" {
    var m = Metrics.init(testing.allocator);
    defer m.deinit();

    m.increment("zcode_requests_total");
    m.setGauge("zcode_latency", 1.5);

    const output = try m.renderPrometheus(testing.allocator);
    defer testing.allocator.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "zcode_requests_total 1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "zcode_latency") != null);
}

test "countLines handles empty, single-line, and multi-line input" {
    try testing.expectEqual(@as(u64, 0), countLines(""));
    try testing.expectEqual(@as(u64, 1), countLines("foo"));
    try testing.expectEqual(@as(u64, 1), countLines("foo\n"));
    try testing.expectEqual(@as(u64, 2), countLines("foo\nbar"));
    try testing.expectEqual(@as(u64, 2), countLines("foo\nbar\n"));
    try testing.expectEqual(@as(u64, 3), countLines("a\nb\nc"));
    try testing.expectEqual(@as(u64, 1), countLines("\n"));
}

test "addToTotalLinesChanged accumulates on the global counter" {
    // The global metrics instance is shared across tests. Snapshot the
    // current values so we don't depend on other tests' ordering.
    const before_added = globalMetrics().getCounter(Names.lines_added_total);
    const before_removed = globalMetrics().getCounter(Names.lines_removed_total);

    addToTotalLinesChanged(5, 3);
    addToTotalLinesChanged(2, 0);

    try testing.expectEqual(before_added + 7, globalMetrics().getCounter(Names.lines_added_total));
    try testing.expectEqual(before_removed + 3, globalMetrics().getCounter(Names.lines_removed_total));
}

test "addToTotalApiDurationMs accumulates and ignores zero" {
    const before = globalMetrics().getCounter(Names.api_duration_ms_total);
    addToTotalApiDurationMs(0); // no-op
    addToTotalApiDurationMs(120);
    addToTotalApiDurationMs(80);
    try testing.expectEqual(before + 200, globalMetrics().getCounter(Names.api_duration_ms_total));
}

test "getSessionWallDurationMs returns a non-negative value" {
    // The session_start_once guard means the first call initialises
    // the epoch and every subsequent call must be >= the first.
    const first = getSessionWallDurationMs();
    const second = getSessionWallDurationMs();
    try testing.expect(second >= first);
}

test "standard tool/circuit/rate-limit counters render once non-zero" {
    var m = Metrics.init(testing.allocator);
    defer m.deinit();

    m.increment(Names.tool_executions_total);
    m.increment(Names.rate_limit_rejections);
    m.setGauge(Names.circuit_breaker_state, 1.0);

    const output = try m.renderPrometheus(testing.allocator);
    defer testing.allocator.free(output);

    try testing.expect(std.mem.indexOf(u8, output, Names.tool_executions_total) != null);
    try testing.expect(std.mem.indexOf(u8, output, Names.rate_limit_rejections) != null);
    try testing.expect(std.mem.indexOf(u8, output, Names.circuit_breaker_state) != null);
}

test "labeled name construction" {
    const name = try labeledName(testing.allocator, "zcode_errors", &.{ .{ "provider", "openai" }, .{ "type", "timeout" } });
    defer testing.allocator.free(name);

    try testing.expectEqualStrings("zcode_errors{provider=\"openai\",type=\"timeout\"}", name);
}
