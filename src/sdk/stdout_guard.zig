//! sdk-headless-09: stream-json stdout guard.
//!
//! SDK clients consuming `--output-format stream-json` parse stdout line by
//! line as NDJSON. Any stray write -- a debug print that slipped past review,
//! a library banner, an out-of-band log line -- breaks the client's parser
//! mid-stream with no recovery path.
//!
//! This guard sits in front of stdout for the stream-json dispatch. Bytes are
//! buffered until a newline arrives, then each complete line is JSON-parsed.
//! Lines that parse (and empty lines, tolerated in NDJSON) are forwarded to
//! the real stdout; lines that don't are diverted to stderr tagged with
//! `[stdout-guard]` so they stay visible without corrupting the JSON stream.
//!
//! The blessed JSON path (the Task B serializers) always emits valid NDJSON,
//! so it passes straight through; only out-of-band writes are diverted.
//!
//! Ported from claude-code-main/src/utils/streamJsonStdoutGuard.ts
//! (`STDOUT_GUARD_MARKER`, buffer-to-newline, `JSON.parse` per line, divert
//! non-JSON, flush residual on close). zcode has no `process.stdout.write`
//! monkeypatch hook, so the guard is a thin object the dispatcher writes
//! through rather than a global interception (project footgun: model the
//! guard as a wrapper, not a hook).

const std = @import("std");
const std_io = @import("../core/std_io.zig");
const parse_helpers = @import("../core/parse_helpers.zig");

/// Sentinel written to stderr ahead of any diverted non-JSON line, so log
/// scrapers and tests can grep for guard activity. Matches the reference
/// `STDOUT_GUARD_MARKER`.
pub const marker = "[stdout-guard]";

/// True when `line` is a valid NDJSON payload. Empty lines are tolerated --
/// a trailing newline or a blank separator must not trip the guard, matching
/// the reference `isJsonLine`. Non-empty lines are validated with a bounded
/// JSON parse (the same cap the rest of the project uses) so a hostile stray
/// line cannot blow up memory while being classified.
pub fn isJsonLine(allocator: std.mem.Allocator, line: []const u8) bool {
    if (line.len == 0) return true;
    var parsed = parse_helpers.parseJsonBounded(std.json.Value, allocator, line) catch return false;
    parsed.deinit();
    return true;
}

/// A stdout guard that routes complete lines to either `stdout` (valid JSON /
/// empty) or `stderr` (non-JSON, tagged with `marker`).
///
/// `Stdout` and `Stderr` are duck-typed writers: each must expose
/// `writeAll([]const u8) !void`. The real path passes
/// `core/std_io.zig`'s stdout/stderr writers; tests pass `StringBuilder`
/// writers so both fds can be captured.
///
/// Bytes arrive via `write`, which buffers into an internal list until a
/// newline. Each complete line (the bytes before the `\n`, the newline
/// stripped) is classified and forwarded with a single re-appended `\n`,
/// matching the reference `line + '\n'`. A `\r` before the newline stays part
/// of the line, exactly as the reference's `slice(0, newlineIdx)` keeps it.
///
/// Call `flush` (or `deinit`, which flushes) once the stream is done so any
/// partial trailing line without a newline is not dropped silently.
pub fn Guard(comptime Stdout: type, comptime Stderr: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        stdout: Stdout,
        stderr: Stderr,
        buffer: std.array_list.Managed(u8),

        pub fn init(allocator: std.mem.Allocator, stdout: Stdout, stderr: Stderr) Self {
            return .{
                .allocator = allocator,
                .stdout = stdout,
                .stderr = stderr,
                .buffer = std.array_list.Managed(u8).init(allocator),
            };
        }

        /// Flush any residual partial line, then release the buffer.
        pub fn deinit(self: *Self) void {
            self.flush() catch {};
            self.buffer.deinit();
        }

        /// Buffer `bytes`, draining every complete (newline-terminated) line to
        /// the routed destination as it becomes available.
        pub fn write(self: *Self, bytes: []const u8) !void {
            try self.buffer.appendSlice(bytes);
            while (std.mem.indexOfScalar(u8, self.buffer.items, '\n')) |nl| {
                const line = self.buffer.items[0..nl];
                try self.routeLine(line);
                // Drop the consumed line plus its newline from the front.
                const consumed = nl + 1;
                const remaining = self.buffer.items.len - consumed;
                std.mem.copyForwards(u8, self.buffer.items[0..remaining], self.buffer.items[consumed..]);
                self.buffer.shrinkRetainingCapacity(remaining);
            }
        }

        /// Flush a residual partial line left in the buffer (a line that never
        /// got its terminating newline). Routed by the same rule: a JSON
        /// fragment that parses goes to stdout, otherwise it is diverted to
        /// stderr rather than dropped. After flushing, the buffer is empty.
        pub fn flush(self: *Self) !void {
            if (self.buffer.items.len == 0) return;
            const line = self.buffer.items;
            try self.routeLine(line);
            self.buffer.clearRetainingCapacity();
        }

        /// Classify a single line (newline already stripped) and forward it.
        fn routeLine(self: *Self, line: []const u8) !void {
            if (isJsonLine(self.allocator, line)) {
                try self.stdout.writeAll(line);
                try self.stdout.writeAll("\n");
            } else {
                try self.stderr.writeAll(marker);
                try self.stderr.writeAll(" ");
                try self.stderr.writeAll(line);
                try self.stderr.writeAll("\n");
            }
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Test sink: an owned StringBuilder exposing a `writeAll` that appends, so it
/// satisfies the Guard's duck-typed writer contract and lets a test capture
/// everything routed to that fd.
const CaptureWriter = struct {
    sb: *std_io.StringBuilder,
    pub fn writeAll(self: CaptureWriter, bytes: []const u8) !void {
        try self.sb.appendSlice(bytes);
    }
};

test "stdout-guard forwards JSON lines and diverts non-JSON to stderr" {
    const allocator = testing.allocator;

    var out_sb = std_io.StringBuilder.init(allocator);
    defer out_sb.deinit();
    var err_sb = std_io.StringBuilder.init(allocator);
    defer err_sb.deinit();

    var guard = Guard(CaptureWriter, CaptureWriter).init(
        allocator,
        .{ .sb = &out_sb },
        .{ .sb = &err_sb },
    );
    defer guard.deinit();

    // Exactly the reference test input: one JSON line, one plain-text line.
    try guard.write("{\"a\":1}\nplain text\n");

    // The JSON line is forwarded verbatim to stdout with its newline.
    try testing.expectEqualStrings("{\"a\":1}\n", out_sb.items());
    // The plain line is diverted to stderr, tagged with the marker.
    try testing.expectEqualStrings("[stdout-guard] plain text\n", err_sb.items());
}

test "stdout-guard tolerates empty lines and handles split writes" {
    const allocator = testing.allocator;

    var out_sb = std_io.StringBuilder.init(allocator);
    defer out_sb.deinit();
    var err_sb = std_io.StringBuilder.init(allocator);
    defer err_sb.deinit();

    var guard = Guard(CaptureWriter, CaptureWriter).init(
        allocator,
        .{ .sb = &out_sb },
        .{ .sb = &err_sb },
    );
    defer guard.deinit();

    // A JSON object split across two writes, a blank separator line, then a
    // second JSON object. Empty lines are valid NDJSON and pass through.
    try guard.write("{\"first\"");
    try guard.write(":true}\n\n{\"second\":2}\n");

    try testing.expectEqualStrings("{\"first\":true}\n\n{\"second\":2}\n", out_sb.items());
    try testing.expectEqualStrings("", err_sb.items());
}

test "stdout-guard flushes a residual partial line on close" {
    const allocator = testing.allocator;

    var out_sb = std_io.StringBuilder.init(allocator);
    defer out_sb.deinit();
    var err_sb = std_io.StringBuilder.init(allocator);
    defer err_sb.deinit();

    {
        var guard = Guard(CaptureWriter, CaptureWriter).init(
            allocator,
            .{ .sb = &out_sb },
            .{ .sb = &err_sb },
        );
        defer guard.deinit();
        // No trailing newline: a valid JSON fragment and a non-JSON fragment
        // are both held in the buffer until deinit flushes them.
        try guard.write("trailing garbage");
    }

    // The residual non-JSON line was diverted, not dropped.
    try testing.expectEqualStrings("", out_sb.items());
    try testing.expectEqualStrings("[stdout-guard] trailing garbage\n", err_sb.items());
}

test "stdout-guard flushes a residual partial JSON line to stdout" {
    const allocator = testing.allocator;

    var out_sb = std_io.StringBuilder.init(allocator);
    defer out_sb.deinit();
    var err_sb = std_io.StringBuilder.init(allocator);
    defer err_sb.deinit();

    {
        var guard = Guard(CaptureWriter, CaptureWriter).init(
            allocator,
            .{ .sb = &out_sb },
            .{ .sb = &err_sb },
        );
        defer guard.deinit();
        try guard.write("{\"x\":42}");
    }

    try testing.expectEqualStrings("{\"x\":42}\n", out_sb.items());
    try testing.expectEqualStrings("", err_sb.items());
}

test "stdout-guard isJsonLine classifies empty, valid, and invalid lines" {
    const allocator = testing.allocator;
    try testing.expect(isJsonLine(allocator, ""));
    try testing.expect(isJsonLine(allocator, "{\"ok\":true}"));
    try testing.expect(isJsonLine(allocator, "[1,2,3]"));
    try testing.expect(isJsonLine(allocator, "123"));
    try testing.expect(!isJsonLine(allocator, "not json"));
    try testing.expect(!isJsonLine(allocator, "{unterminated"));
}
