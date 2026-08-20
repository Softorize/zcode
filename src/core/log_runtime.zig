//! Runtime log-level + format override for zcode's stderr logs.
//!
//! Zig's std.log is comptime-gated for the smallest default level a
//! call site can use, but the ACTUAL emission decision goes through
//! a user-installable log function. We install one here that honors
//! `--log-level` and `--log-format` set via CliOptions, so operators
//! can switch between human-friendly text and aggregator-friendly
//! JSON at runtime without rebuilding.
//!
//! Level semantics:
//!   - debug: everything, including noisy per-tool traces
//!   - info:  significant lifecycle events (session start, compact)
//!   - warn:  recoverable oddities (default)
//!   - error: hard failures surfaced before propagation
//!
//! Format semantics:
//!   - text (default): `<ts> <level> <scope>: <message>`
//!   - json:           `{"ts":...,"level":"...","scope":"...","msg":"..."}`

const std = @import("std");
const clock = @import("clock.zig");

const Level = enum {
    debug,
    info,
    warn,
    err,

    fn toSeverity(self: Level) u8 {
        return switch (self) {
            .debug => 0,
            .info => 1,
            .warn => 2,
            .err => 3,
        };
    }

    fn fromStdLogLevel(level: std.log.Level) Level {
        return switch (level) {
            .debug => .debug,
            .info => .info,
            .warn => .warn,
            .err => .err,
        };
    }

    fn toString(self: Level) []const u8 {
        return switch (self) {
            .debug => "debug",
            .info => "info",
            .warn => "warn",
            .err => "error",
        };
    }
};

pub const Format = enum { text, json };

var min_level_severity: u8 = Level.warn.toSeverity();
var emit_format: Format = .text;

/// Parse a user-supplied log level. Rejects unknown values explicitly
/// so the operator sees the error at startup rather than silently
/// getting default behavior.
pub fn setLevelFromString(raw: []const u8) !void {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const lvl: Level = if (std.ascii.eqlIgnoreCase(trimmed, "debug"))
        .debug
    else if (std.ascii.eqlIgnoreCase(trimmed, "info"))
        .info
    else if (std.ascii.eqlIgnoreCase(trimmed, "warn") or std.ascii.eqlIgnoreCase(trimmed, "warning"))
        .warn
    else if (std.ascii.eqlIgnoreCase(trimmed, "error") or std.ascii.eqlIgnoreCase(trimmed, "err"))
        .err
    else
        return error.InvalidLogLevel;
    min_level_severity = lvl.toSeverity();
}

pub fn setFormatFromString(raw: []const u8) !void {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "text")) {
        emit_format = .text;
    } else if (std.ascii.eqlIgnoreCase(trimmed, "json")) {
        emit_format = .json;
    } else {
        return error.InvalidLogFormat;
    }
}

/// Drop-in replacement for std.log.defaultLog that honors the
/// runtime level + format. Install via `pub const std_options` in
/// main.zig.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    const rt_level = Level.fromStdLogLevel(level);
    if (rt_level.toSeverity() < min_level_severity) return;

    var stderr_buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&stderr_buf);

    const ts = clock.nowSeconds();
    const scope_str = @tagName(scope);

    switch (emit_format) {
        .text => {
            // Render the message into a side buffer so we can scrub
            // control bytes before they hit the operator's terminal.
            // Without this, an std.log.warn("X failed: {s}", .{msg})
            // where `msg` came from a model response, MCP server
            // error, file path, etc. could carry ESC (0x1B) or
            // bel / DEL bytes and hijack the terminal via ANSI
            // escape sequences. JSON format is safe via std.json.fmt
            // string-escaping; text format had no analog. Tabs and
            // newlines stay legible -- everything else in C0 plus
            // 0x7f gets folded to '?' (no allocations on the hot path).
            var msg_buf: [3072]u8 = undefined;
            var msg_w = std.Io.Writer.fixed(&msg_buf);
            msg_w.print(fmt, args) catch return;
            const msg = msg_w.buffered();
            for (msg) |*b| {
                if (b.* == '\t' or b.* == '\n') continue;
                if (b.* < 0x20 or b.* == 0x7f) b.* = '?';
            }
            w.print("{d} {s} {s}: ", .{ ts, rt_level.toString(), scope_str }) catch return;
            w.writeAll(msg) catch return;
            w.writeByte('\n') catch return;
        },
        .json => {
            // Render the message into a side buffer first so we can
            // embed it as a JSON string field with proper escaping.
            var msg_buf: [3072]u8 = undefined;
            var msg_w = std.Io.Writer.fixed(&msg_buf);
            msg_w.print(fmt, args) catch return;
            const msg = msg_w.buffered();
            w.print("{f}\n", .{std.json.fmt(.{
                .ts = ts,
                .level = rt_level.toString(),
                .scope = scope_str,
                .msg = msg,
            }, .{})}) catch return;
        },
    }

    const out = w.buffered();
    // 0.16: std.posix.write is gone; route via libc (we link libc).
    _ = std.c.write(std.posix.STDERR_FILENO, out.ptr, out.len);
}

// --- Tests ------------------------------------------------------------

const testing = std.testing;

test "setLevelFromString accepts known levels" {
    try setLevelFromString("debug");
    try setLevelFromString("INFO");
    try setLevelFromString("warn");
    try setLevelFromString("error");
    try testing.expectError(error.InvalidLogLevel, setLevelFromString("chatty"));
}

test "setFormatFromString accepts text and json" {
    try setFormatFromString("text");
    try setFormatFromString("JSON");
    try testing.expectError(error.InvalidLogFormat, setFormatFromString("xml"));
}
