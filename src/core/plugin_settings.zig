//! Per-plugin enable/disable state persisted in settings (plugins-01).
//!
//! zcode's "enabled" state for a plugin used to be derived purely from trust:
//! user-scope plugins were always on, workspace-scope plugins were on only when
//! the workspace was trusted. There was no way to turn off a single plugin
//! without uninstalling it. This module adds a persisted `name@marketplace ->
//! bool` map at user and workspace scope, mirroring the reference's per-source
//! `settings.enabledPlugins` (the single source of truth in
//! `utils/plugins/dependencyResolver.ts:275-283` and
//! `plugins/builtinPlugins.ts:71-77`).
//!
//! On-disk format: a dedicated JSON file per scope rather than the TOML
//! `config.toml` (which is flat key=value and cannot hold a nested map):
//!   - user:      <zcode_home>/plugin_settings.json
//!   - workspace: <cwd>/.zcode/plugin_settings.json
//! shaped `{"enabledPlugins": {"foo@local": true, "bar@market": false}}`.
//!
//! Precedence (matches the reference "most specific scope wins"): workspace
//! beats user. A `true` value (or a JSON array, which the reference uses for
//! version-constraint pins) means enabled; `false` means disabled; an absent
//! key falls back to the caller-supplied `trust_default` so un-toggled plugins
//! keep their current behavior.

const std = @import("std");
const rt = @import("zcode_runtime");
const paths = @import("paths.zig");
const clock = @import("clock.zig");
const std_io = @import("std_io.zig");
const parse_helpers = @import("parse_helpers.zig");
const plugins = @import("plugins.zig");

pub const Scope = plugins.PluginScope;

const settings_file_name = "plugin_settings.json";
const enabled_plugins_key = "enabledPlugins";

/// Cap for the on-disk settings file. A real enabledPlugins map is a handful of
/// short keys; 1 MiB is far larger than any legitimate map and guards against a
/// hand-edited monster file. readFileAlloc(.limited) yields error.StreamTooLong
/// when exceeded (0.16 footgun: NOT error.FileTooBig).
const max_settings_bytes: usize = 1 * 1024 * 1024;

/// Resolve the on-disk settings path for the given scope. Caller owns the
/// returned slice.
fn settingsPath(allocator: std.mem.Allocator, cwd: []const u8, scope: Scope) ![]u8 {
    switch (scope) {
        .user => {
            var resolved = try paths.resolve(allocator);
            defer resolved.deinit(allocator);
            return std.fs.path.join(allocator, &.{ resolved.zcode_home, settings_file_name });
        },
        .workspace => return paths.workspacePathAlloc(allocator, cwd, settings_file_name),
    }
}

/// Read the raw `name@marketplace -> bool` value for a single id from one
/// scope's settings file. Returns:
///   - .{ .enabled = true }  when the value is `true` or a JSON array
///     (the reference treats a version-constraint array as enabled too).
///   - .{ .enabled = false } when the value is `false`.
///   - null when the file is absent, malformed, or the key is not present.
const ScopeState = struct { enabled: bool };

fn readScopeState(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    plugin_id: []const u8,
    scope: Scope,
) !?ScopeState {
    const path = try settingsPath(allocator, cwd, scope);
    defer allocator.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(max_settings_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        // A truncated/oversized file is treated as "no opinion" so a corrupt
        // settings file degrades to trust-default behavior instead of crashing
        // `plugins list`.
        error.StreamTooLong => return null,
        else => return err,
    };
    defer allocator.free(bytes);

    var parsed = parse_helpers.parseJsonBounded(std.json.Value, allocator, parse_helpers.stripBom(bytes)) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    const enabled_obj = parsed.value.object.get(enabled_plugins_key) orelse return null;
    if (enabled_obj != .object) return null;

    const entry = enabled_obj.object.get(plugin_id) orelse return null;
    return switch (entry) {
        .bool => |b| .{ .enabled = b },
        // A version-constraint array (or any non-false value) counts as enabled,
        // matching getEnabledPluginIdsForScope at dependencyResolver.ts:275-283.
        .array => .{ .enabled = true },
        else => null,
    };
}

/// Resolve the effective enabled state for a plugin id, consulting the
/// workspace scope first (it wins) and then the user scope, falling back to
/// `trust_default` when neither scope has an opinion.
pub fn effectiveEnabled(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    plugin_id: []const u8,
    scope: Scope,
    trust_default: bool,
) !bool {
    // Workspace overrides user regardless of the plugin's install scope:
    // a workspace policy can disable a user-installed plugin just for this
    // repo, and vice versa. We probe workspace first to honor "most specific
    // scope wins".
    _ = scope;
    if (try readScopeState(allocator, cwd, plugin_id, .workspace)) |st| return st.enabled;
    if (try readScopeState(allocator, cwd, plugin_id, .user)) |st| return st.enabled;
    return trust_default;
}

/// Read-modify-write a single id's boolean in one scope's settings file. The
/// file is created (with the `enabledPlugins` object) if it does not exist, and
/// an existing entry is updated in place (no duplication on re-write). The write
/// is atomic (tmp + rename) so a crash mid-write cannot leave a half-written or
/// empty settings file.
pub fn setEnabled(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    scope: Scope,
    plugin_id: []const u8,
    enabled: bool,
) !void {
    const path = try settingsPath(allocator, cwd, scope);
    defer allocator.free(path);

    try paths.ensureDir(std.fs.path.dirname(path) orelse return error.InvalidPath);

    const existing = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(max_settings_bytes)) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(existing);

    // Parse the existing doc (if any). The parsed arena owns the strings we copy
    // forward, so it is held alive until after the new document is rendered. A
    // missing/malformed/non-object file degrades to a fresh document.
    var parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed) |*p| p.deinit();
    if (existing.len > 0) {
        if (parse_helpers.parseJsonBounded(std.json.Value, allocator, parse_helpers.stripBom(existing))) |p| {
            parsed = p;
        } else |_| {}
    }

    // Build a fresh enabledPlugins map: copy every existing entry forward, then
    // overwrite (or insert) the target id. Rebuilding sidesteps the 0.16
    // ObjectMap pointer-after-parse footgun (a value copy of the parsed map
    // desyncs its `entries` pointer on the next realloc -- CLAUDE.md) by never
    // mutating the parsed map in place. std.json.ObjectMap is unmanaged in 0.16:
    // construct via `.empty`, mutate via `put(allocator, ...)`.
    var enabled_map: std.json.ObjectMap = .empty;
    defer enabled_map.deinit(allocator);

    if (parsed) |p| {
        if (p.value == .object) {
            if (p.value.object.get(enabled_plugins_key)) |ep| {
                if (ep == .object) {
                    var it = ep.object.iterator();
                    while (it.next()) |kv| {
                        if (std.mem.eql(u8, kv.key_ptr.*, plugin_id)) continue;
                        try enabled_map.put(allocator, kv.key_ptr.*, kv.value_ptr.*);
                    }
                }
            }
        }
    }
    try enabled_map.put(allocator, plugin_id, .{ .bool = enabled });

    var root_map: std.json.ObjectMap = .empty;
    defer root_map.deinit(allocator);
    try root_map.put(allocator, enabled_plugins_key, .{ .object = enabled_map });

    // Render the document. Keys/values are slices into the parsed arena (or the
    // caller-owned plugin_id) plus literal bools; Stringify only reads them.
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(std.json.Value{ .object = root_map }, .{ .whitespace = .indent_2 }, out.writer());
    try out.writer().writeByte('\n');

    try writeAtomic(allocator, path, out.items());
}

/// Disable every installed plugin at `scope`. Enumerates plugins via
/// `plugins.list`, sets each to `false`, and returns the count flipped.
pub fn disableAll(allocator: std.mem.Allocator, cwd: []const u8, scope: Scope) !usize {
    const list = try plugins.list(allocator, cwd);
    defer plugins.freeList(allocator, list);

    var count: usize = 0;
    for (list) |plugin| {
        try setEnabled(allocator, cwd, scope, plugin.plugin_id, false);
        count += 1;
    }
    return count;
}

/// Derive the canonical `name@marketplace` id for a plugin. A locally-installed
/// plugin with no remote source uses the `@local` sentinel (matches the
/// reference's inline-marketplace intent). Caller owns the returned slice.
pub fn pluginId(allocator: std.mem.Allocator, name: []const u8, marketplace: ?[]const u8) ![]u8 {
    const mkt = marketplace orelse "local";
    return std.fmt.allocPrint(allocator, "{s}@{s}", .{ name, mkt });
}

fn writeAtomic(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ path, clock.nowNanos() });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, data);
        file.sync(rt.io) catch {};
        file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o600)) catch {};
    }
    try std.Io.Dir.renameAbsolute(tmp_path, path, rt.io);
}

const testing = std.testing;
const test_helpers = @import("test_helpers.zig");

fn writeManifest(tmp: *testing.TmpDir, sub_dir: []const u8, name: []const u8) !void {
    try tmp.dir.createDirPath(rt.io, sub_dir);
    const manifest = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"name\":\"{s}\",\"version\":\"1.0.0\",\"description\":\"d\",\"entrypoint\":\"run.sh\"}}",
        .{name},
    );
    defer testing.allocator.free(manifest);
    const sub_path = try std.fs.path.join(testing.allocator, &.{ sub_dir, "plugin.json" });
    defer testing.allocator.free(sub_path);
    try tmp.dir.writeFile(rt.io, .{ .sub_path = sub_path, .data = manifest });
}

test "setEnabled persists and list reflects disabled" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // User-scope plugin (loads as enabled by default with no trust gate). HOME
    // is the tmp root so userPluginsRoot resolves to <root>/.zcode/plugins; the
    // cwd is a distinct subdir so the plugin is NOT also discovered as a
    // workspace plugin (which would double-count it).
    try writeManifest(&tmp, ".zcode/plugins/demo", "demo");

    const home = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(home);
    const restore = try pinHome(allocator, home);
    defer restore.deinit(allocator);

    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try test_helpers.tmpDirPath(allocator, &tmp, "proj");
    defer allocator.free(cwd);

    // Default: enabled.
    {
        const before = try plugins.list(allocator, cwd);
        defer plugins.freeList(allocator, before);
        try testing.expectEqual(@as(usize, 1), before.len);
        try testing.expect(before[0].enabled);
    }

    try setEnabled(allocator, cwd, .user, "demo@local", false);

    {
        const after = try plugins.list(allocator, cwd);
        defer plugins.freeList(allocator, after);
        try testing.expectEqual(@as(usize, 1), after.len);
        try testing.expectEqualStrings("demo", after[0].name);
        try testing.expect(!after[0].enabled);
    }

    // renderList shows status=disabled.
    {
        const rendered = try plugins.renderList(allocator, cwd);
        defer allocator.free(rendered);
        try testing.expect(std.mem.indexOf(u8, rendered, "status=disabled") != null);
    }
}

test "setEnabled round-trips and keeps exactly one entry" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);
    const restore = try pinHome(allocator, cwd);
    defer restore.deinit(allocator);

    try setEnabled(allocator, cwd, .user, "demo@local", false);
    try setEnabled(allocator, cwd, .user, "demo@local", true);

    // The JSON file must contain exactly one entry under enabledPlugins.
    const path = try settingsPath(allocator, cwd, .user);
    defer allocator.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(max_settings_bytes));
    defer allocator.free(bytes);

    var parsed = try parse_helpers.parseJsonBounded(std.json.Value, allocator, bytes);
    defer parsed.deinit();
    const enabled_obj = parsed.value.object.get(enabled_plugins_key).?;
    try testing.expectEqual(@as(usize, 1), enabled_obj.object.count());
    try testing.expect(enabled_obj.object.get("demo@local").?.bool);
}

test "workspace false overrides user true" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // HOME is the tmp root (user-scope settings land in <root>/.zcode), while
    // the workspace cwd is a distinct subdir (workspace settings land in
    // <root>/proj/.zcode). Keeping them distinct avoids the two scope files
    // colliding on the same path.
    const home = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(home);
    const restore = try pinHome(allocator, home);
    defer restore.deinit(allocator);

    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try test_helpers.tmpDirPath(allocator, &tmp, "proj");
    defer allocator.free(cwd);

    try setEnabled(allocator, cwd, .user, "demo@local", true);
    try setEnabled(allocator, cwd, .workspace, "demo@local", false);

    // trust_default true, but workspace false wins.
    const eff = try effectiveEnabled(allocator, cwd, "demo@local", .user, true);
    try testing.expect(!eff);
}

test "untoggled plugin honors trust_default" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);
    const restore = try pinHome(allocator, cwd);
    defer restore.deinit(allocator);

    // No settings file written at all: a user plugin (trust_default true) is
    // enabled, an untrusted-workspace plugin (trust_default false) is disabled.
    try testing.expect(try effectiveEnabled(allocator, cwd, "user@local", .user, true));
    try testing.expect(!(try effectiveEnabled(allocator, cwd, "wsp@local", .workspace, false)));
}

test "disableAll flips every plugin and enable re-enables one" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeManifest(&tmp, ".zcode/plugins/alpha", "alpha");
    try writeManifest(&tmp, ".zcode/plugins/beta", "beta");

    // HOME is the tmp root (two user-scope plugins under <root>/.zcode/plugins);
    // cwd is a distinct subdir so they are not also counted as workspace
    // plugins.
    const home = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(home);
    const restore = try pinHome(allocator, home);
    defer restore.deinit(allocator);

    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try test_helpers.tmpDirPath(allocator, &tmp, "proj");
    defer allocator.free(cwd);

    const flipped = try disableAll(allocator, cwd, .user);
    try testing.expectEqual(@as(usize, 2), flipped);

    {
        const list = try plugins.list(allocator, cwd);
        defer plugins.freeList(allocator, list);
        for (list) |p| try testing.expect(!p.enabled);
    }

    // Re-enable just one.
    try setEnabled(allocator, cwd, .user, "alpha@local", true);
    {
        const list = try plugins.list(allocator, cwd);
        defer plugins.freeList(allocator, list);
        for (list) |p| {
            if (std.mem.eql(u8, p.name, "alpha")) {
                try testing.expect(p.enabled);
            } else {
                try testing.expect(!p.enabled);
            }
        }
    }
}

test "pluginId derives name@local for local plugins" {
    const allocator = testing.allocator;
    const id = try pluginId(allocator, "demo", null);
    defer allocator.free(id);
    try testing.expectEqualStrings("demo@local", id);

    const id2 = try pluginId(allocator, "demo", "market");
    defer allocator.free(id2);
    try testing.expectEqualStrings("demo@market", id2);
}

// Pin HOME (and clear XDG_CONFIG_HOME) so paths.resolve and userPluginsRoot
// resolve into the tmp tree. Mirrors the HOME-pinning helper in plugins.zig's
// Task 5 test. The zcode_home becomes <home>/.zcode.
const HomeRestore = struct {
    prev_home: ?[]u8,
    prev_xdg: ?[]u8,

    fn deinit(self: HomeRestore, allocator: std.mem.Allocator) void {
        if (self.prev_home) |h| {
            const z = allocator.dupeZ(u8, h) catch null;
            if (z) |zz| {
                _ = setenv("HOME", zz, 1);
                allocator.free(zz);
            }
            allocator.free(h);
        } else _ = unsetenv("HOME");
        if (self.prev_xdg) |x| {
            const z = allocator.dupeZ(u8, x) catch null;
            if (z) |zz| {
                _ = setenv("XDG_CONFIG_HOME", zz, 1);
                allocator.free(zz);
            }
            allocator.free(x);
        } else _ = unsetenv("XDG_CONFIG_HOME");
    }
};

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn pinHome(allocator: std.mem.Allocator, home: []const u8) !HomeRestore {
    const env = @import("env.zig");
    const prev_home = env.getOwned(allocator, "HOME") catch null;
    const prev_xdg = env.getOwned(allocator, "XDG_CONFIG_HOME") catch null;
    const home_z = try allocator.dupeZ(u8, home);
    defer allocator.free(home_z);
    _ = setenv("HOME", home_z, 1);
    _ = unsetenv("XDG_CONFIG_HOME");
    return .{ .prev_home = prev_home, .prev_xdg = prev_xdg };
}
