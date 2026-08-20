//! Plugins provide hooks to the running session (plugins-02).
//!
//! An enabled plugin's manifest `hooks` object declares matchers across the
//! full `hook_event.Event` set (PreToolUse, SessionStart, ...). This module
//! turns those into context-stamped `PluginMatcher`s and runs the matching ones
//! for a live event through a hardened subprocess, folding plugins into the same
//! engine the settings.json / session hooks use (`hooks.zig`) rather than the
//! bespoke 5-event runner that still lives in `plugins.zig` for back-compat.
//!
//! Reference: `utils/plugins/loadPluginHooks.ts:28-90`
//! (`convertPluginHooksToMatchers` stamps each matcher with
//! pluginRoot/pluginName/pluginId; `loadPluginHooks` merges across enabled
//! plugins). The reference does an atomic `clearRegisteredPluginHooks()` +
//! `registerHookCallbacks()`; the gh-29767 stale-hook bug it guards against does
//! not apply here because zcode re-reads matchers on every dispatch (no
//! persistent registry), which sidesteps the stale-hook problem entirely. This
//! is a deliberate simplification.
//!
//! Security invariant: the plugin hook subprocess gets the same hardened env-map
//! allowlist as `plugins.runSingle` (no provider API keys, no session secrets).
//! Do not forward the full parent environment.

const std = @import("std");
const rt = @import("zcode_runtime");
const plugins = @import("plugins.zig");
const hook_event = @import("hook_event.zig");
const hook_matcher = @import("hook_matcher.zig");
const env = @import("env.zig");

/// A plugin hook matcher stamped with its provenance. The engine matches
/// `event` + `tool_matcher` against the live event, then runs `command`
/// (already resolved + traversal-checked against `plugin_root`). Owned by the
/// allocator passed to `collect`; free with `freeMatchers`.
pub const PluginMatcher = struct {
    event: hook_event.Event,
    tool_matcher: []u8,
    /// Absolute, traversal-checked path to the hook entrypoint under the plugin
    /// root. Resolved via `plugins.resolveEntrypoint` so a `..` escape is
    /// rejected at collect time.
    command: []u8,
    plugin_root: []u8,
    plugin_name: []u8,
    plugin_id: []u8,

    pub fn deinit(self: *PluginMatcher, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_matcher);
        allocator.free(self.command);
        allocator.free(self.plugin_root);
        allocator.free(self.plugin_name);
        allocator.free(self.plugin_id);
    }
};

pub fn freeMatchers(allocator: std.mem.Allocator, matchers: []PluginMatcher) void {
    for (matchers) |*m| m.deinit(allocator);
    allocator.free(matchers);
}

/// Collect context-stamped hook matchers from every *enabled* plugin's manifest
/// `hooks` object, across all events. A disabled plugin contributes nothing. A
/// matcher whose command fails the traversal guard (`..`, absolute path) is
/// skipped (it never appears in the result) rather than aborting the collection.
/// Caller owns the returned slice (free with `freeMatchers`).
pub fn collect(allocator: std.mem.Allocator, cwd: []const u8) ![]PluginMatcher {
    const list = try plugins.list(allocator, cwd);
    defer plugins.freeList(allocator, list);

    var out = std.array_list.Managed(PluginMatcher).init(allocator);
    errdefer freeMatchersList(allocator, &out);

    for (list) |plugin| {
        if (!plugin.enabled) continue;
        for (plugin.hook_matchers) |hm| {
            // Resolve + guard the command against the plugin root. A `..` escape
            // or absolute path is rejected here (skip, do not abort).
            const command = plugins.resolveEntrypoint(allocator, plugin.root_path, hm.command) catch continue;
            errdefer allocator.free(command);

            try out.ensureUnusedCapacity(1);
            const tool_matcher = try allocator.dupe(u8, hm.tool_matcher);
            errdefer allocator.free(tool_matcher);
            const plugin_root = try allocator.dupe(u8, plugin.root_path);
            errdefer allocator.free(plugin_root);
            const plugin_name = try allocator.dupe(u8, plugin.name);
            errdefer allocator.free(plugin_name);
            const plugin_id = try allocator.dupe(u8, plugin.plugin_id);
            out.appendAssumeCapacity(.{
                .event = hm.event,
                .tool_matcher = tool_matcher,
                .command = command,
                .plugin_root = plugin_root,
                .plugin_name = plugin_name,
                .plugin_id = plugin_id,
            });
        }
    }

    return out.toOwnedSlice();
}

fn freeMatchersList(allocator: std.mem.Allocator, out: *std.array_list.Managed(PluginMatcher)) void {
    for (out.items) |*m| m.deinit(allocator);
    out.deinit();
}

/// Minimal context the engine hands us for a live event. Mirrors the subset of
/// `hooks.HookContext` a plugin hook needs (the full struct lives in `hooks.zig`
/// and importing it here would create a cycle, so the caller passes the fields).
pub const RunContext = struct {
    event: hook_event.Event,
    cwd: []const u8,
    tool_name: []const u8 = "",
    tool_args: []const u8 = "",
    tool_output: []const u8 = "",
    tool_success: bool = false,
    /// The single discriminating field a non-tool event matches against
    /// (SessionStart source, UserPromptSubmit prompt, ...). Empty for tool
    /// events (which match on tool_name/tool_args instead).
    match_field: []const u8 = "",
};

pub const RunResult = struct {
    ran: bool,
    blocked: bool,
    output: []u8,

    pub fn deinit(self: *RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
    }
};

/// Run every enabled-plugin hook matcher that matches the live event. Tool
/// events match on tool name + serialized args; non-tool events match on the
/// single discriminating `match_field`. A non-zero exit from a blocking-capable
/// event surfaces as `blocked == true` (honoring `hook_event.interpretExit`, so
/// only exit 2 blocks for blocking-capable events and other non-zero codes are
/// a non-blocking user error). The first block short-circuits. With no matching
/// plugin hook, `ran == false`. Caller owns `output` (free via deinit).
pub fn runForEvent(allocator: std.mem.Allocator, ctx: RunContext) !RunResult {
    const matchers = try collect(allocator, ctx.cwd);
    defer freeMatchers(allocator, matchers);

    var last_output = try allocator.dupe(u8, "");
    errdefer allocator.free(last_output);
    var ran = false;

    const tool_event = isToolEvent(ctx.event);

    for (matchers) |m| {
        if (m.event != ctx.event) continue;
        if (tool_event) {
            if (!hook_matcher.matchesTool(m.tool_matcher, ctx.tool_name, ctx.tool_args)) continue;
        } else {
            if (!hook_matcher.matchesField(m.tool_matcher, ctx.match_field)) continue;
        }

        ran = true;
        var single = try runSingle(allocator, m, ctx);
        defer single.deinit(allocator);

        allocator.free(last_output);
        last_output = if (single.output.len > 0)
            try std.fmt.allocPrint(allocator, "[{s}] {s}", .{ m.plugin_name, single.output })
        else
            try allocator.dupe(u8, "");

        if (single.blocked) {
            return .{ .ran = true, .blocked = true, .output = last_output };
        }
    }

    return .{ .ran = ran, .blocked = false, .output = last_output };
}

/// Tool events carry tool_name/tool_args; everything else is a non-tool
/// lifecycle event matched on a single field. Mirrors `hooks.isToolEvent`.
fn isToolEvent(event: hook_event.Event) bool {
    return switch (event) {
        .pre_tool_use, .post_tool_use, .post_tool_use_failure => true,
        else => false,
    };
}

/// Run one plugin hook subprocess with the *same hardened env-map allowlist* as
/// `plugins.runSingle` (security invariant: no provider API keys, no session
/// secrets reach untrusted plugin code). The command is invoked with the
/// kebab-case event name as argv[1] (matching the legacy plugin runner). A
/// non-zero exit blocks only when the event is blocking-capable and the code is
/// 2 (`hook_event.interpretExit`).
fn runSingle(allocator: std.mem.Allocator, m: PluginMatcher, ctx: RunContext) !RunResult {
    // Hardened env map. Identical allowlist to plugins.runSingle: forward only
    // the generic shell variables, then set ZCODE_*/CLAUDE_* explicitly.
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    const forward_keys = [_][]const u8{
        "PATH", "HOME",   "USER",     "LOGNAME",     "SHELL", "TMPDIR", "TMP", "TEMP",
        "LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES", "TERM",
    };
    for (forward_keys) |key| {
        const value = env.getOwned(allocator, key) catch continue;
        defer allocator.free(value);
        env_map.put(key, value) catch {};
    }

    // Cap the tool-args/output payloads (16 KB) exactly as plugins.runSingle, so
    // a very large LLM-generated argument cannot blow past ARG_MAX.
    const tool_args_cap: usize = 16 * 1024;
    const tool_args_slice = if (ctx.tool_args.len > tool_args_cap) ctx.tool_args[0..tool_args_cap] else ctx.tool_args;
    const tool_output_slice = if (ctx.tool_output.len > tool_args_cap) ctx.tool_output[0..tool_args_cap] else ctx.tool_output;

    const event_name = eventName(ctx.event);
    try env_map.put("ZCODE_PLUGIN_NAME", m.plugin_name);
    try env_map.put("ZCODE_PLUGIN_ID", m.plugin_id);
    try env_map.put("ZCODE_PLUGIN_EVENT", event_name);
    try env_map.put("ZCODE_HOOK_EVENT", event_name);
    try env_map.put("ZCODE_CWD", ctx.cwd);
    try env_map.put("ZCODE_TOOL_NAME", ctx.tool_name);
    try env_map.put("ZCODE_TOOL_ARGS", tool_args_slice);
    try env_map.put("ZCODE_TOOL_OUTPUT", tool_output_slice);
    try env_map.put("ZCODE_TOOL_SUCCESS", if (ctx.tool_success) "1" else "0");

    // CLAUDE_* plugin alias set (same contract as plugins.runSingle).
    const plugin_data = try std.fs.path.join(allocator, &.{ m.plugin_root, "data" });
    defer allocator.free(plugin_data);
    try env_map.put("CLAUDE_PLUGIN_ROOT", m.plugin_root);
    try env_map.put("CLAUDE_PLUGIN_DATA", plugin_data);

    const argv = [_][]const u8{ m.command, event_name };
    const result = try std.process.run(allocator, rt.io, .{
        .argv = &argv,
        .cwd = .{ .path = ctx.cwd },
        .environ_map = &env_map,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const output_source = if (std.mem.trim(u8, result.stdout, " \t\r\n").len > 0) result.stdout else result.stderr;
    const output = try allocator.dupe(u8, std.mem.trim(u8, output_source, " \t\r\n"));

    const code: u8 = if (result.term == .exited) @intCast(result.term.exited & 0xff) else 1;
    const disp = hook_event.interpretExit(ctx.event, code);
    return .{ .ran = true, .blocked = disp == .block, .output = output };
}

/// Kebab-case event name passed to the hook process as argv[1] and the
/// ZCODE_HOOK_EVENT env var. The 3 tool events keep their historical kebab
/// spelling (matching the legacy plugin/file-hook runner); every other event
/// uses its canonical PascalCase name (mirrors `hooks.eventName`).
fn eventName(event: hook_event.Event) []const u8 {
    return switch (event) {
        .pre_tool_use => "pre-tool-use",
        .post_tool_use => "post-tool-use",
        .post_tool_use_failure => "post-tool-use-failure",
        else => hook_event.canonicalName(event),
    };
}

const testing = std.testing;
const test_helpers = @import("test_helpers.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Pin HOME (and clear XDG_CONFIG_HOME) for a test so `userPluginsRoot` resolves
/// under the tmp tree, making the test plugin a *user* plugin (enabled by
/// default, no workspace trust gate). Mirrors the HOME-pin in the existing
/// plugins.zig CLAUDE_PLUGIN_ROOT test. Caller restores via `deinit`.
const HomeOverride = struct {
    prev_home: ?[]u8,
    prev_xdg: ?[]u8,
    allocator: std.mem.Allocator,

    fn install(allocator: std.mem.Allocator, home: []const u8) !HomeOverride {
        const prev_home = if (env.getOwned(allocator, "HOME")) |v| v else |_| null;
        const prev_xdg = if (env.getOwned(allocator, "XDG_CONFIG_HOME")) |v| v else |_| null;
        const home_z = try allocator.dupeZ(u8, home);
        defer allocator.free(home_z);
        _ = setenv("HOME", home_z, 1);
        _ = unsetenv("XDG_CONFIG_HOME");
        return .{ .prev_home = prev_home, .prev_xdg = prev_xdg, .allocator = allocator };
    }

    fn deinit(self: *HomeOverride) void {
        if (self.prev_home) |h| {
            const z = self.allocator.dupeZ(u8, h) catch null;
            if (z) |zz| {
                _ = setenv("HOME", zz, 1);
                self.allocator.free(zz);
            }
            self.allocator.free(h);
        } else _ = unsetenv("HOME");
        if (self.prev_xdg) |x| {
            const z = self.allocator.dupeZ(u8, x) catch null;
            if (z) |zz| {
                _ = setenv("XDG_CONFIG_HOME", zz, 1);
                self.allocator.free(zz);
            }
            self.allocator.free(x);
        } else _ = unsetenv("XDG_CONFIG_HOME");
    }
};

/// Write a user-scope plugin into `{HOME}/.zcode/plugins/<name>` with the given
/// manifest and an executable `h.sh` entrypoint.
fn writeUserPlugin(
    tmp: *std.testing.TmpDir,
    name: []const u8,
    manifest: []const u8,
    script: []const u8,
) !void {
    const dir = try std.fmt.allocPrint(testing.allocator, ".zcode/plugins/{s}", .{name});
    defer testing.allocator.free(dir);
    try tmp.dir.createDirPath(rt.io, dir);

    const manifest_path = try std.fmt.allocPrint(testing.allocator, "{s}/plugin.json", .{dir});
    defer testing.allocator.free(manifest_path);
    try tmp.dir.writeFile(rt.io, .{ .sub_path = manifest_path, .data = manifest });

    const script_path = try std.fmt.allocPrint(testing.allocator, "{s}/h.sh", .{dir});
    defer testing.allocator.free(script_path);
    const f = try tmp.dir.createFile(rt.io, script_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o755) });
    defer f.close(rt.io);
    try f.writeStreamingAll(rt.io, script);
}

test "plugins-02: manifest hooks produce one matcher for the event + tool" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(home);
    var home_ov = try HomeOverride.install(alloc, home);
    defer home_ov.deinit();

    try writeUserPlugin(&tmp, "demo",
        \\{
        \\  "name": "demo",
        \\  "version": "1.0.0",
        \\  "hooks": {"PreToolUse": [{"matcher":"Bash","hooks":[{"command":"./h.sh"}]}]}
        \\}
    , "#!/bin/sh\necho HOOK_RAN\n");

    // cwd is a distinct subdir (no workspace plugins there).
    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try test_helpers.tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    const matchers = try collect(alloc, cwd);
    defer freeMatchers(alloc, matchers);

    // Exactly one matcher, for pre_tool_use, with the Bash tool matcher, stamped.
    try testing.expectEqual(@as(usize, 1), matchers.len);
    try testing.expectEqual(hook_event.Event.pre_tool_use, matchers[0].event);
    try testing.expectEqualStrings("Bash", matchers[0].tool_matcher);
    try testing.expectEqualStrings("demo", matchers[0].plugin_name);
    try testing.expectEqualStrings("demo@local", matchers[0].plugin_id);

    // The matcher matches a Bash call and not a Read call.
    try testing.expect(hook_matcher.matchesTool(matchers[0].tool_matcher, "Bash", "git status"));
    try testing.expect(!hook_matcher.matchesTool(matchers[0].tool_matcher, "Read", "x"));
}

test "plugins-02: a disabled plugin contributes zero matchers" {
    const alloc = testing.allocator;
    const plugin_settings = @import("plugin_settings.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(home);
    var home_ov = try HomeOverride.install(alloc, home);
    defer home_ov.deinit();

    try writeUserPlugin(&tmp, "demo",
        \\{
        \\  "name": "demo",
        \\  "version": "1.0.0",
        \\  "hooks": {"PreToolUse": [{"matcher":"*","hooks":[{"command":"./h.sh"}]}]}
        \\}
    , "#!/bin/sh\necho HOOK_RAN\n");

    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try test_helpers.tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    // Sanity: enabled by default it produces a matcher.
    {
        const m = try collect(alloc, cwd);
        defer freeMatchers(alloc, m);
        try testing.expectEqual(@as(usize, 1), m.len);
    }

    // Disable the plugin at user scope: collect must skip it.
    try plugin_settings.setEnabled(alloc, cwd, .user, "demo@local", false);

    const matchers = try collect(alloc, cwd);
    defer freeMatchers(alloc, matchers);
    try testing.expectEqual(@as(usize, 0), matchers.len);
}

test "plugins-02: plugin hook subprocess gets the hardened env map (no ANTHROPIC_API_KEY)" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(home);
    var home_ov = try HomeOverride.install(alloc, home);
    defer home_ov.deinit();

    // The entrypoint prints the API key env or MISSING. The hardened allowlist
    // must not forward it, so the hook must observe MISSING.
    try writeUserPlugin(&tmp, "envprobe",
        \\{
        \\  "name": "envprobe",
        \\  "version": "1.0.0",
        \\  "hooks": {"PreToolUse": [{"matcher":"*","hooks":[{"command":"./h.sh"}]}]}
        \\}
    , "#!/bin/sh\necho KEY=${ANTHROPIC_API_KEY:-MISSING}\n");

    // Set the key in the parent env for the duration of the test.
    _ = setenv("ANTHROPIC_API_KEY", "sk-secret-should-not-leak", 1);
    defer _ = unsetenv("ANTHROPIC_API_KEY");

    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try test_helpers.tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    var result = try runForEvent(alloc, .{ .event = .pre_tool_use, .cwd = cwd, .tool_name = "Read", .tool_args = "x" });
    defer result.deinit(alloc);
    try testing.expect(result.ran);
    try testing.expect(std.mem.indexOf(u8, result.output, "KEY=MISSING") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "sk-secret-should-not-leak") == null);
}

test "plugins-02: a non-zero exit from a PreToolUse plugin hook blocks" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(home);
    var home_ov = try HomeOverride.install(alloc, home);
    defer home_ov.deinit();

    // Exit 2 (the blocking code) from a blocking-capable event (PreToolUse).
    try writeUserPlugin(&tmp, "blocker",
        \\{
        \\  "name": "blocker",
        \\  "version": "1.0.0",
        \\  "hooks": {"PreToolUse": [{"matcher":"*","hooks":[{"command":"./h.sh"}]}]}
        \\}
    , "#!/bin/sh\necho DENY\nexit 2\n");

    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try test_helpers.tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    var result = try runForEvent(alloc, .{ .event = .pre_tool_use, .cwd = cwd, .tool_name = "Read", .tool_args = "x" });
    defer result.deinit(alloc);
    try testing.expect(result.ran);
    try testing.expect(result.blocked);
    try testing.expect(std.mem.indexOf(u8, result.output, "DENY") != null);
}
