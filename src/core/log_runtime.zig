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
/// cli-flags-14: `-d, --debug [filter]`'s category filter (e.g. "api,hooks"
/// or "!1p,!file"), owned by `setCategoryFilter`. Empty means "no filter --
/// every debug-level line passes" (bare `-d`/`--debug`'s behavior). Only
/// ever affects `.debug`-level lines; info/warn/error are never filtered by
/// category, matching the reference's own "restrict debug output" framing.
var category_filter_owned: ?[]u8 = null;
var category_filter: []const u8 = "";
/// cli-flags-14: `--debug-file <path>` redirect target. Defaults to
/// stderr; `setOutputFile` opens (create/truncate) the given path and
/// switches every subsequent `logFn` write there instead. Best-effort: a
/// write failure once redirected is silently dropped (matching the
/// existing stderr write's `_ = ...` fire-and-forget contract) rather than
/// panicking a running session over a log sink going away.
var output_fd: std.posix.fd_t = std.posix.STDERR_FILENO;

/// Redirect log output to `path` (create/truncate). Implicitly enables
/// debug mode is the CALLER's job (matching the reference's "implicitly
/// enables debug mode" wording for `--debug-file`) -- this function only
/// switches the sink.
pub fn setOutputFile(path: []const u8) !void {
    const rt = @import("zcode_runtime");
    const file = try std.Io.Dir.cwd().createFile(rt.io, path, .{ .truncate = true });
    output_fd = file.handle;
}

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

/// cli-flags-14: install `-d, --debug`'s optional category filter. `raw` is
/// a comma/whitespace-separated list of category names (e.g. "api,hooks"),
/// where a `!`-prefixed entry (e.g. "!1p,!file") EXCLUDES that category
/// instead of including it. An empty/whitespace-only `raw` clears any filter
/// (bare `-d`/`--debug`: every debug line passes). Dupes `raw` onto `rt.gpa`
/// so it outlives the CLI-arg-parsing arena; call at most once per process
/// (a second call frees the first copy, matching `setOutputFile`'s
/// replace-in-place contract).
pub fn setCategoryFilter(raw: []const u8) !void {
    const rt = @import("zcode_runtime");
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const owned = try rt.gpa.dupe(u8, trimmed);
    if (category_filter_owned) |old| rt.gpa.free(old);
    category_filter_owned = owned;
    category_filter = owned;
}

/// Frees the installed category filter (a process-lifetime allocation
/// otherwise reported as a leak by the DebugAllocator at process exit --
/// same class of fix as `core/env.zig`'s override map). `main` calls this
/// via `defer` right alongside that one; tests call it directly to reset
/// state between cases. Safe to call when no filter was ever installed.
pub fn clearCategoryFilter() void {
    const rt = @import("zcode_runtime");
    if (category_filter_owned) |old| rt.gpa.free(old);
    category_filter_owned = null;
    category_filter = "";
}

/// cli-flags-14: does a `.debug`-level line from `scope` pass the currently
/// installed category filter? Pure and directly testable -- `logFn` below is
/// the only real caller, but the actual decision logic lives here so it can
/// be exercised without touching global log state or std.log at all.
///
/// Semantics: an empty filter allows everything (bare `-d`/`--debug`). A
/// filter is split on commas/whitespace into an EXCLUDE set (entries
/// starting with `!`) and an INCLUDE set (everything else). Exclude is
/// checked first and wins outright (a scope in both sets is denied,
/// mirroring the "deny wins" precedent already used for permission rules
/// elsewhere in this codebase); otherwise, a non-empty include set allows
/// only its named scopes, and an empty include set (exclude-only filter,
/// e.g. "!1p,!file") allows everything not excluded.
pub fn debugCategoryAllowed(filter: []const u8, scope: []const u8) bool {
    if (filter.len == 0) return true;

    var has_include = false;
    var it = std.mem.tokenizeAny(u8, filter, ", \t\r\n");
    while (it.next()) |raw_entry| {
        if (raw_entry.len > 0 and raw_entry[0] == '!') {
            const excluded = raw_entry[1..];
            if (excluded.len > 0 and std.ascii.eqlIgnoreCase(excluded, scope)) return false;
        } else {
            has_include = true;
        }
    }
    if (!has_include) return true;

    it = std.mem.tokenizeAny(u8, filter, ", \t\r\n");
    while (it.next()) |raw_entry| {
        if (raw_entry.len == 0 or raw_entry[0] == '!') continue;
        if (std.ascii.eqlIgnoreCase(raw_entry, scope)) return true;
    }
    return false;
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

    const ts = clock.nowSeconds();
    const scope_str = @tagName(scope);

    // cli-flags-14: `-d <filter>`'s category restriction only ever narrows
    // DEBUG-level output (info/warn/error always emit once they clear the
    // level check above) -- see `debugCategoryAllowed`'s doc comment.
    if (rt_level == .debug and !debugCategoryAllowed(category_filter, scope_str)) return;

    var stderr_buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&stderr_buf);

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
    // cli-flags-14: writes to `output_fd`, stderr by default or a
    // `--debug-file` target once `setOutputFile` has redirected it.
    _ = std.c.write(output_fd, out.ptr, out.len);
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

test "cli-flags-14: an empty filter (bare -d/--debug) allows every category" {
    try testing.expect(debugCategoryAllowed("", "api"));
    try testing.expect(debugCategoryAllowed("", "hooks"));
    try testing.expect(debugCategoryAllowed("", "default"));
}

test "cli-flags-14: an include filter (\"api,hooks\") allows only those categories" {
    try testing.expect(debugCategoryAllowed("api,hooks", "api"));
    try testing.expect(debugCategoryAllowed("api,hooks", "hooks"));
    // Case-insensitive, matching the rest of this codebase's category/name matching.
    try testing.expect(debugCategoryAllowed("API,Hooks", "api"));
    try testing.expect(!debugCategoryAllowed("api,hooks", "default"));
    try testing.expect(!debugCategoryAllowed("api,hooks", "file"));
}

test "cli-flags-14: an exclude-only filter (\"!1p,!file\") allows everything except those" {
    try testing.expect(!debugCategoryAllowed("!1p,!file", "1p"));
    try testing.expect(!debugCategoryAllowed("!1p,!file", "file"));
    try testing.expect(debugCategoryAllowed("!1p,!file", "api"));
    try testing.expect(debugCategoryAllowed("!1p,!file", "default"));
}

test "cli-flags-14: exclude wins over include when a category appears in both" {
    // "api,!api" both includes and excludes "api" -- exclude wins.
    try testing.expect(!debugCategoryAllowed("api,!api", "api"));
    // "hooks" is in neither set of "api,!api"; the presence of the include
    // entry "api" means this is include-mode, so an unlisted category is
    // denied just like the plain include-filter test above.
    try testing.expect(!debugCategoryAllowed("api,!api", "hooks"));
}

test "cli-flags-14: setCategoryFilter installs a filter that debugCategoryAllowed then honors" {
    defer clearCategoryFilter();
    try setCategoryFilter("api,hooks");
    try testing.expect(debugCategoryAllowed(category_filter, "api"));
    try testing.expect(!debugCategoryAllowed(category_filter, "default"));

    // Re-setting frees the previous copy and installs the new one cleanly
    // (no leak, no stale data) -- this is what happens if a hosting
    // process re-parses args, or a future caller calls it twice.
    try setCategoryFilter("!file");
    try testing.expect(debugCategoryAllowed(category_filter, "api"));
    try testing.expect(!debugCategoryAllowed(category_filter, "file"));
}
