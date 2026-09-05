//! config-layout-16: settings.json's `statusLine` custom command-driven
//! footer.
//!
//! The reference lets a user configure a shell command in `settings.json`:
//!
//!     { "statusLine": { "type": "command", "command": "your_command_here" } }
//!
//! and re-runs it (event-driven, plus every `refreshInterval` seconds) with a
//! JSON payload describing session/model/workspace state on its stdin,
//! rendering the trimmed stdout as the footer's status line (cc_strings.txt's
//! `F9t`/statusLine executor, and the documented `statusLine:{type,command,
//! padding,refreshInterval}` settings schema entry).
//!
//! This module owns the config-layer half only: reading the `statusLine`
//! object out of the settings.json cascade (`readConfig`) and actually
//! running the configured command with the reference's stdin JSON contract,
//! returning its rendered output (`run`). It deliberately does NOT touch
//! `src/cli/repl_render.zig` -- wiring the returned string into the REPL's
//! footer render loop (event-driven re-runs, `refreshInterval` polling,
//! layout/padding) is wp8's (repl-ux) concern; this module exposes `readConfig`
//! and `run` as the hook wp8 calls.
//!
//! `managed_security.zig` already blocklists `statusLine` as a "dangerous
//! shell setting" for managed/untrusted config sources (arbitrary command
//! execution) -- callers of `run` are expected to gate on the same
//! trust/approval model used for other workspace-provided executable content
//! (hooks) before invoking it; this module does not itself trust-gate.

const std = @import("std");
const rt = @import("zcode_runtime");
const clock = @import("clock.zig");
const std_io = @import("std_io.zig");
const settings_sources = @import("settings_sources.zig");

/// A parsed `statusLine` settings object. Only `type: "command"` is
/// supported (the reference's only documented type).
pub const StatusLineConfig = struct {
    command: []u8,
    /// Padding in spaces the reference applies around the rendered text.
    /// Read through, not applied here -- footer layout is wp8's concern.
    padding: ?i64 = null,
    /// Re-run interval, in seconds. Read through, not scheduled here.
    refresh_interval_s: ?i64 = null,

    pub fn deinit(self: *const StatusLineConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
    }
};

/// Read the `statusLine` object across every settings.json source in
/// `settings_sources.sourceOrder()` precedence (later source wins on a
/// conflict, matching every other JSON scalar bridge in this package).
/// Returns null when no source defines a `{"type":"command","command":...}`
/// shaped `statusLine` object (absent key, wrong type, or missing/empty
/// `command` all degrade to "not configured" rather than an error).
pub fn readConfig(allocator: std.mem.Allocator, cwd: []const u8) !?StatusLineConfig {
    var result: ?StatusLineConfig = null;
    errdefer if (result) |*r| r.deinit(allocator);

    for (settings_sources.sourceOrder()) |source| {
        var parsed = (settings_sources.readSource(allocator, cwd, source, null) catch null) orelse continue;
        defer parsed.deinit();

        const status_line_val = settings_sources.getObject(parsed.value, "statusLine") orelse continue;
        const status_type = settings_sources.getString(status_line_val, "type") orelse continue;
        if (!std.mem.eql(u8, status_type, "command")) continue;
        const command = settings_sources.getString(status_line_val, "command") orelse continue;
        if (command.len == 0) continue;

        const new_command = try allocator.dupe(u8, command);
        if (result) |*old| old.deinit(allocator);
        result = .{
            .command = new_command,
            .padding = settings_sources.getInt(status_line_val, "padding"),
            .refresh_interval_s = settings_sources.getInt(status_line_val, "refreshInterval"),
        };
    }
    return result;
}

const ModelInfo = struct { id: []const u8, display_name: []const u8 };
const WorkspaceInfo = struct { current_dir: []const u8, project_dir: []const u8 };
const OutputStyleInfo = struct { name: []const u8 };

/// The reference's documented statusLine stdin JSON contract: `{
/// hook_event_name, session_id, transcript_path, cwd, model: {id,
/// display_name}, workspace: {current_dir, project_dir}, version,
/// output_style: {name} }`. Every field the caller does not have a value for
/// yet degrades to an empty string ("") rather than being omitted -- a
/// status-line script is expected to tolerate an absent value the same way
/// it tolerates one from the reference during early startup.
pub const StatusLineInputParams = struct {
    session_id: []const u8 = "",
    transcript_path: []const u8 = "",
    cwd: []const u8,
    model_id: []const u8 = "",
    model_display_name: []const u8 = "",
    current_dir: []const u8,
    project_dir: []const u8,
    version: []const u8 = "",
    output_style_name: []const u8 = "default",
};

const StatusLineHookInput = struct {
    hook_event_name: []const u8 = "Status",
    session_id: []const u8,
    transcript_path: []const u8,
    cwd: []const u8,
    model: ModelInfo,
    workspace: WorkspaceInfo,
    version: []const u8,
    output_style: OutputStyleInfo,
};

/// Build the JSON payload delivered on the status-line command's stdin.
/// Exposed (not just used internally by `run`) so a caller can preview/log
/// the exact payload without actually spawning a process.
pub fn buildStdinPayload(allocator: std.mem.Allocator, params: StatusLineInputParams) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try out.writer().print("{f}", .{std.json.fmt(
        StatusLineHookInput{
            .session_id = params.session_id,
            .transcript_path = params.transcript_path,
            .cwd = params.cwd,
            .model = .{ .id = params.model_id, .display_name = params.model_display_name },
            .workspace = .{ .current_dir = params.current_dir, .project_dir = params.project_dir },
            .version = params.version,
            .output_style = .{ .name = params.output_style_name },
        },
        .{},
    )});
    return out.toOwnedSlice();
}

/// Run the configured status-line command with the reference's stdin JSON
/// contract and return its rendered output (trimmed, blank lines dropped,
/// remaining lines rejoined with `\n` -- mirroring the reference's own
/// `stdout.trim().split("\n").flatMap(line => line.trim() || []).join("\n")`
/// normalization), or null when the command times out, exits non-zero, or
/// produces no non-blank output. `home_dir` is used only to place the
/// stdin-payload temp file (same technique `core/hooks.zig`'s
/// `runCommandWithStdin` uses: a temp file + shell input redirect, avoiding
/// manual pipe plumbing); it is deleted after the command returns.
///
/// Does NOT trust-gate the command -- the caller (wp8, wiring this into the
/// REPL footer) is expected to skip calling `run` at all when the workspace
/// providing `statusLine` is not trusted, the same gate already applied to
/// hook commands from an untrusted `.claude/settings.json`.
pub fn run(
    allocator: std.mem.Allocator,
    cfg: StatusLineConfig,
    cwd: []const u8,
    home_dir: []const u8,
    params: StatusLineInputParams,
    timeout_ms: u64,
) !?[]u8 {
    const payload = try buildStdinPayload(allocator, params);
    defer allocator.free(payload);

    const nonce = clock.nowNanos();
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}/.statusline-input-{x}.json", .{ home_dir, nonce });
    defer allocator.free(tmp_path);
    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, payload);
    }
    defer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    // Single-quote the redirect path (mirrors hooks.zig's runCommandWithStdin):
    // the hex temp filename needs no quoting itself, but `home_dir` may
    // contain spaces.
    const full = try std.fmt.allocPrint(allocator, "{s} < '{s}'", .{ cfg.command, tmp_path });
    defer allocator.free(full);

    const result = std.process.run(allocator, rt.io, .{
        .argv = &.{ "sh", "-c", full },
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
        .timeout = .{ .duration = .{ .raw = .{ .nanoseconds = timeout_ms * std.time.ns_per_ms }, .clock = .awake } },
    }) catch |err| switch (err) {
        error.Timeout => return null,
        else => return err,
    };
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    if (result.term != .exited or result.term.exited != 0) return null;

    return normalizeOutput(allocator, result.stdout);
}

/// Mirror the reference's own status-line output normalization: trim the
/// whole blob, split on newlines, trim + drop each blank line, rejoin the
/// survivors with `\n`. Returns null when nothing survives (matching the
/// reference treating an all-blank/empty result as "no update").
fn normalizeOutput(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
    const trimmed_outer = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed_outer.len == 0) return null;

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    var it = std.mem.splitScalar(u8, trimmed_outer, '\n');
    var wrote_any = false;
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        if (wrote_any) try out.append('\n');
        try out.appendSlice(line);
        wrote_any = true;
    }

    if (!wrote_any) {
        out.deinit();
        return null;
    }
    return try out.toOwnedSlice();
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const test_helpers = @import("test_helpers.zig");

test "readConfig returns null when no source defines statusLine" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const env_mod = @import("env.zig");
    defer env_mod.clearOverrides();
    try env_mod.setOverride("HOME", cwd);
    try env_mod.setOverride("XDG_CONFIG_HOME", "");

    const cfg = try readConfig(testing.allocator, cwd);
    try testing.expect(cfg == null);
}

test "readConfig parses a project .claude/settings.json command statusLine" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const env_mod = @import("env.zig");
    defer env_mod.clearOverrides();
    try env_mod.setOverride("HOME", cwd);
    try env_mod.setOverride("XDG_CONFIG_HOME", "");

    try tmp.dir.createDirPath(rt.io, ".claude");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".claude/settings.json",
        .data = "{\"statusLine\":{\"type\":\"command\",\"command\":\"echo hi\",\"padding\":2,\"refreshInterval\":5}}",
    });

    var cfg = (try readConfig(testing.allocator, cwd)).?;
    defer cfg.deinit(testing.allocator);

    try testing.expectEqualStrings("echo hi", cfg.command);
    try testing.expectEqual(@as(?i64, 2), cfg.padding);
    try testing.expectEqual(@as(?i64, 5), cfg.refresh_interval_s);
}

test "readConfig ignores a non-command type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const env_mod = @import("env.zig");
    defer env_mod.clearOverrides();
    try env_mod.setOverride("HOME", cwd);
    try env_mod.setOverride("XDG_CONFIG_HOME", "");

    try tmp.dir.createDirPath(rt.io, ".claude");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".claude/settings.json",
        .data = "{\"statusLine\":{\"type\":\"script\",\"command\":\"echo hi\"}}",
    });

    const cfg = try readConfig(testing.allocator, cwd);
    try testing.expect(cfg == null);
}

test "buildStdinPayload emits the reference's documented statusLine JSON contract" {
    const payload = try buildStdinPayload(testing.allocator, .{
        .session_id = "sess-1",
        .cwd = "/work",
        .model_id = "claude-sonnet-4-6",
        .model_display_name = "Sonnet",
        .current_dir = "/work/sub",
        .project_dir = "/work",
        .version = "0.12.50",
    });
    defer testing.allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try testing.expectEqualStrings("Status", obj.get("hook_event_name").?.string);
    try testing.expectEqualStrings("sess-1", obj.get("session_id").?.string);
    try testing.expectEqualStrings("/work", obj.get("cwd").?.string);
    try testing.expectEqualStrings("claude-sonnet-4-6", obj.get("model").?.object.get("id").?.string);
    try testing.expectEqualStrings("Sonnet", obj.get("model").?.object.get("display_name").?.string);
    try testing.expectEqualStrings("/work/sub", obj.get("workspace").?.object.get("current_dir").?.string);
    try testing.expectEqualStrings("/work", obj.get("workspace").?.object.get("project_dir").?.string);
    try testing.expectEqualStrings("0.12.50", obj.get("version").?.string);
    try testing.expectEqualStrings("default", obj.get("output_style").?.object.get("name").?.string);
}

test "run executes the configured command and returns its trimmed stdout" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(dir);

    var cfg = StatusLineConfig{ .command = try testing.allocator.dupe(u8, "echo '  hello status  '") };
    defer cfg.deinit(testing.allocator);

    const out = try run(testing.allocator, cfg, dir, dir, .{
        .cwd = dir,
        .current_dir = dir,
        .project_dir = dir,
    }, 5000);
    defer if (out) |o| testing.allocator.free(o);

    try testing.expectEqualStrings("hello status", out.?);
}

test "run drops blank lines and rejoins survivors with a single newline" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(dir);

    var cfg = StatusLineConfig{ .command = try testing.allocator.dupe(u8, "printf 'line one\\n\\nline two\\n'") };
    defer cfg.deinit(testing.allocator);

    const out = try run(testing.allocator, cfg, dir, dir, .{
        .cwd = dir,
        .current_dir = dir,
        .project_dir = dir,
    }, 5000);
    defer if (out) |o| testing.allocator.free(o);

    try testing.expectEqualStrings("line one\nline two", out.?);
}

test "run returns null on a non-zero exit" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(dir);

    var cfg = StatusLineConfig{ .command = try testing.allocator.dupe(u8, "exit 1") };
    defer cfg.deinit(testing.allocator);

    const out = try run(testing.allocator, cfg, dir, dir, .{
        .cwd = dir,
        .current_dir = dir,
        .project_dir = dir,
    }, 5000);
    try testing.expect(out == null);
}

test "run delivers the stdin JSON payload to the command" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(dir);

    // `cat` echoes stdin back to stdout unchanged: proves the payload really
    // reaches the command's stdin (not just argv/env).
    var cfg = StatusLineConfig{ .command = try testing.allocator.dupe(u8, "cat | grep -o '\"session_id\":\"[^\"]*\"'") };
    defer cfg.deinit(testing.allocator);

    const out = try run(testing.allocator, cfg, dir, dir, .{
        .session_id = "the-session-id",
        .cwd = dir,
        .current_dir = dir,
        .project_dir = dir,
    }, 5000);
    defer if (out) |o| testing.allocator.free(o);

    try testing.expectEqualStrings("\"session_id\":\"the-session-id\"", out.?);
}
