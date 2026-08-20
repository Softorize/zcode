//! Background plugin autoupdate (plugins-10, tail).
//!
//! The reference (`utils/plugins/pluginAutoupdate.ts:45-150`) updates plugins
//! that come from an `autoUpdate`-enabled marketplace: it version-compares the
//! installed plugin against the catalog, updates the stale ones in the
//! background, fires a desktop notification, and short-circuits when everything
//! is already up to date.
//!
//! zcode keeps the same shape but a deliberately conservative posture:
//!   - Opt-in only. A catalog entry is eligible for autoupdate ONLY when it
//!     explicitly sets `"auto_update": true`. A source/entry without the flag is
//!     never touched (matches zcode's "the user/source must grant permission"
//!     stance for delisting in plugins-09).
//!   - Version-gated. The catalog must advertise a `version`, the installed
//!     plugin must report one, and both must parse as semver. If either side is
//!     `unknown`/non-semver, we treat it as "do not auto-update" rather than
//!     guessing (a non-semver compare could update in the wrong direction).
//!   - No scheduler here. `checkAndApply` runs only when an explicit caller
//!     invokes it; nothing in this module wires itself into a background loop.
//!     Wiring into the KAIROS self-check loop is a separate, gated opt-in and is
//!     intentionally NOT done here (kairos_policy DEFAULT_ALLOWLIST stays as-is).
//!
//! The update itself reuses `marketplace.update` (uninstall + reinstall), so the
//! refreshed files land through the same path a manual `zcode plugins update`
//! takes. Updated plugin names are returned to the caller AND surfaced via a
//! best-effort `os_notify` desktop notification.

const std = @import("std");
const rt = @import("zcode_runtime");
const marketplace = @import("marketplace.zig");
const plugins = @import("plugins.zig");
const changelog = @import("changelog.zig");
const os_notify = @import("os_notify.zig");

/// Compare two version strings, returning true ONLY when `catalog` is strictly
/// newer than `installed` AND both parse as semver. A version that is empty,
/// `"unknown"`, or otherwise un-parseable yields false: we never auto-update on
/// a comparison we cannot make safely. This is the `alreadyUpToDate`
/// short-circuit and the "treat unknown as do-not-update" guard combined.
fn shouldUpdate(installed: []const u8, catalog: []const u8) bool {
    if (installed.len == 0 or catalog.len == 0) return false;
    // Reject non-semver on either side BEFORE comparing. `changelog.compareVersions`
    // falls back to byte order when a parse fails, which could update in the
    // wrong direction (e.g. "unknown" vs "2.0.0"); we refuse that case outright.
    _ = std.SemanticVersion.parse(installed) catch return false;
    _ = std.SemanticVersion.parse(catalog) catch return false;
    return changelog.compareVersions(installed, catalog) == .lt;
}

/// Find the installed (manifest-reported) version of plugin `name`, or null when
/// it is not currently installed/loaded. Borrowed from the passed-in loaded set.
fn installedVersion(loaded: []const plugins.PluginSpec, name: []const u8) ?[]const u8 {
    for (loaded) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.version;
    }
    return null;
}

/// Check every `auto_update` catalog plugin against its installed copy and
/// update the stale ones. Returns the names of plugins that were updated (caller
/// owns the slice and each string); an empty slice means everything was already
/// up to date (or nothing was eligible). A desktop notification listing the
/// updated names is fired best-effort when any update happened.
///
/// Conservative and idempotent: only `auto_update` entries with a parseable
/// catalog version are considered, only when the installed copy reports an older
/// parseable version. Anything else is skipped. A failure updating one plugin is
/// logged-and-skipped so one bad entry does not abort the rest of the pass.
pub fn checkAndApply(allocator: std.mem.Allocator, cwd: []const u8) ![]const []const u8 {
    var updated = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (updated.items) |item| allocator.free(item);
        updated.deinit();
    }

    // Catalog entries (plugins only). Each may carry `version` + `auto_update`.
    const entries = try marketplace.list(allocator, cwd, .plugin);
    defer marketplace.freeList(allocator, entries);

    // Installed plugins (manifest version is the "currently on disk" version).
    const loaded = try plugins.list(allocator, cwd);
    defer plugins.freeList(allocator, loaded);

    for (entries) |entry| {
        if (!entry.auto_update) continue;
        const catalog_version = entry.version orelse continue;
        const installed = installedVersion(loaded, entry.name) orelse continue;
        if (!shouldUpdate(installed, catalog_version)) continue;

        // Apply the update through the same path as a manual update. A failure is
        // non-fatal: skip this plugin and keep going so one stale-but-broken
        // entry does not block the others.
        const msg = marketplace.update(allocator, cwd, .plugin, entry.name) catch |err| {
            std.log.debug("plugin autoupdate: {s} update failed: {s}", .{ entry.name, @errorName(err) });
            continue;
        };
        allocator.free(msg);
        try updated.append(try allocator.dupe(u8, entry.name));
    }

    const names = try updated.toOwnedSlice();
    if (names.len > 0) notifyUpdated(allocator, names);
    return names;
}

/// Free a slice returned by `checkAndApply`.
pub fn freeUpdated(allocator: std.mem.Allocator, names: []const []const u8) void {
    for (names) |name| allocator.free(name);
    allocator.free(names);
}

/// Best-effort desktop notification summarizing the autoupdate. Swallows all
/// errors (os_notify is itself best-effort); a missing notifier or a formatting
/// failure must never break the update pass.
fn notifyUpdated(allocator: std.mem.Allocator, names: []const []const u8) void {
    var body = std.array_list.Managed(u8).init(allocator);
    defer body.deinit();
    body.appendSlice("Updated plugins: ") catch return;
    for (names, 0..) |name, i| {
        if (i > 0) body.appendSlice(", ") catch return;
        body.appendSlice(name) catch return;
    }
    os_notify.notify(allocator, "zcode plugins", body.items);
}

const testing = std.testing;
const test_helpers = @import("test_helpers.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Pin HOME (clear XDG_CONFIG_HOME) so userPluginsRoot/userCatalogPath resolve
/// into <home>/.zcode. Mirrors the marketplace.zig delisting test scaffold.
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

test "shouldUpdate: strictly-newer catalog updates, equal/older/unknown do not" {
    try testing.expect(shouldUpdate("1.0.0", "2.0.0"));
    try testing.expect(shouldUpdate("1.2.3", "1.2.4"));
    // Up-to-date short-circuit.
    try testing.expect(!shouldUpdate("2.0.0", "2.0.0"));
    // Downgrade is never an update.
    try testing.expect(!shouldUpdate("2.0.0", "1.0.0"));
    // Non-semver / unknown on either side is refused (do-not-update guard).
    try testing.expect(!shouldUpdate("unknown", "2.0.0"));
    try testing.expect(!shouldUpdate("1.0.0", "unknown"));
    try testing.expect(!shouldUpdate("", "1.0.0"));
    try testing.expect(!shouldUpdate("1.0.0", ""));
}

test "Task 17.10: an auto_update catalog entry at a newer version updates the installed plugin" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(home);
    const restore = try pinHome(allocator, home);
    defer restore.deinit(allocator);

    // The workspace catalog (under <cwd>/.zcode) offers `demo` at v2 with
    // auto_update enabled; the source dir ships a v2 plugin.json.
    try tmp.dir.createDirPath(rt.io, "proj/.zcode/catalog-src/demo");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "proj/.zcode/marketplace.json",
        .data =
        \\[
        \\  {"name":"demo","kind":"plugin","description":"d","source":"catalog-src/demo","version":"2.0.0","auto_update":true}
        \\]
        ,
    });
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "proj/.zcode/catalog-src/demo/plugin.json",
        .data = "{\"name\":\"demo\",\"version\":\"2.0.0\"}",
    });

    // The installed copy under <home>/.zcode/plugins/demo is at v1.
    try tmp.dir.createDirPath(rt.io, ".zcode/plugins/demo");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/plugins/demo/plugin.json",
        .data = "{\"name\":\"demo\",\"version\":\"1.0.0\"}",
    });

    const cwd = try test_helpers.tmpDirPath(allocator, &tmp, "proj");
    defer allocator.free(cwd);

    // First pass: v1 -> v2, demo is updated and returned.
    {
        const names = try checkAndApply(allocator, cwd);
        defer freeUpdated(allocator, names);
        try testing.expectEqual(@as(usize, 1), names.len);
        try testing.expectEqualStrings("demo", names[0]);
    }

    // The installed plugin now reports v2.
    {
        const loaded = try plugins.list(allocator, cwd);
        defer plugins.freeList(allocator, loaded);
        try testing.expectEqualStrings("2.0.0", installedVersion(loaded, "demo").?);
    }

    // Second pass: v2 == v2, the up-to-date short-circuit returns nothing.
    {
        const names = try checkAndApply(allocator, cwd);
        defer freeUpdated(allocator, names);
        try testing.expectEqual(@as(usize, 0), names.len);
    }
}

test "Task 17.10: a non-auto_update source is never touched" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(home);
    const restore = try pinHome(allocator, home);
    defer restore.deinit(allocator);

    // Catalog offers demo at v2 but WITHOUT auto_update.
    try tmp.dir.createDirPath(rt.io, "proj/.zcode/catalog-src/demo");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "proj/.zcode/marketplace.json",
        .data =
        \\[
        \\  {"name":"demo","kind":"plugin","description":"d","source":"catalog-src/demo","version":"2.0.0"}
        \\]
        ,
    });
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "proj/.zcode/catalog-src/demo/plugin.json",
        .data = "{\"name\":\"demo\",\"version\":\"2.0.0\"}",
    });

    // Installed at v1.
    try tmp.dir.createDirPath(rt.io, ".zcode/plugins/demo");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/plugins/demo/plugin.json",
        .data = "{\"name\":\"demo\",\"version\":\"1.0.0\"}",
    });

    const cwd = try test_helpers.tmpDirPath(allocator, &tmp, "proj");
    defer allocator.free(cwd);

    const names = try checkAndApply(allocator, cwd);
    defer freeUpdated(allocator, names);
    try testing.expectEqual(@as(usize, 0), names.len);

    // And the installed plugin is still v1 (untouched).
    const loaded = try plugins.list(allocator, cwd);
    defer plugins.freeList(allocator, loaded);
    try testing.expectEqualStrings("1.0.0", installedVersion(loaded, "demo").?);
}
