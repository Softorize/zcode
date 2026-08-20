//! Org-managed per-plugin policy (plugins-07).
//!
//! An administrator can force-disable (or protect) individual plugins via a
//! managed-settings file, parallel to the reference's `policySettings`:
//!   - `utils/plugins/pluginPolicy.ts:17-20` - `isPluginBlockedByPolicy(id)` is
//!     true when `policySettings.enabledPlugins[id] === false`.
//!   - `utils/plugins/managedPlugins.ts:8-31` - `getManagedPluginNames` returns
//!     the set of `name@marketplace` boolean-keyed names (true OR false).
//!
//! Policy is the strongest authority: it beats both the user and workspace
//! `enabledPlugins` maps (plugins-01) and the install chokepoint. A
//! policy-blocked plugin can never be installed or enabled, and a
//! policy-managed plugin (any boolean entry) cannot be disabled by the user.
//!
//! On-disk format. zcode's managed *config* (`managed.toml`, read by
//! `config_parse.zig:resolveManagedConfigPath`) is flat TOML key=value and
//! cannot hold a nested `enabledPlugins` map. So the plugin policy lives in a
//! dedicated JSON file `policy_plugins.json` placed in the SAME directory as
//! the managed config (the admin-deployed, root-owned location), shaped:
//!   {"enabledPlugins": {"evil@market": false, "blessed@market": true}}
//! Deriving the path from the managed-config path means it inherits the same
//! deployment surface (MDM/Jamf/Ansible) and the same `ZCODE_MANAGED_CONFIG`
//! override used for CI/testing, with no new env var to register.
//!
//! This is a SEPARATE mechanism from `config.zig:managed_locked_keys`
//! (config-key locking). They happen to share a deployment directory but mean
//! different things: locked keys freeze config fields; this blocks plugins.

const std = @import("std");
const rt = @import("zcode_runtime");
const config_parse = @import("config_parse.zig");
const parse_helpers = @import("parse_helpers.zig");

const enabled_plugins_key = "enabledPlugins";
const policy_file_name = "policy_plugins.json";

/// Cap for the policy file. A real policy map is a handful of short keys;
/// 1 MiB is far larger than any legitimate map and guards against a hostile
/// hand-edited file. readFileAlloc(.limited) yields error.StreamTooLong when
/// exceeded (0.16 footgun: NOT error.FileTooBig).
const max_policy_bytes: usize = 1 * 1024 * 1024;

/// Resolve the managed plugin-policy file path: `policy_plugins.json` in the
/// same directory as the managed config. Returns null when no managed-config
/// location is known for this platform (e.g. an unsupported OS with no
/// ZCODE_MANAGED_CONFIG override), in which case there is no policy in effect.
/// Caller owns the returned slice.
fn policyPath(allocator: std.mem.Allocator) !?[]u8 {
    const managed_path = (try config_parse.resolveManagedConfigPath(allocator)) orelse return null;
    defer allocator.free(managed_path);
    const dir = std.fs.path.dirname(managed_path) orelse ".";
    const joined = try std.fs.path.join(allocator, &.{ dir, policy_file_name });
    return joined;
}

/// Read the managed `enabledPlugins` map. Returns the parsed JSON handle (the
/// caller must `deinit` it) or null when no policy file is present/readable or
/// it is malformed. A malformed policy file degrades to "no policy" rather than
/// crashing install/enable - failing closed here would brick every plugin
/// operation on a single typo in the admin file, which is worse than the
/// fail-closed posture managed *config* uses (there the whole config is gated).
const ParsedPolicy = struct {
    parsed: std.json.Parsed(std.json.Value),

    fn enabledMap(self: *const ParsedPolicy) ?std.json.ObjectMap {
        if (self.parsed.value != .object) return null;
        const ep = self.parsed.value.object.get(enabled_plugins_key) orelse return null;
        if (ep != .object) return null;
        return ep.object;
    }

    fn deinit(self: *ParsedPolicy) void {
        self.parsed.deinit();
    }
};

fn readPolicy(allocator: std.mem.Allocator) !?ParsedPolicy {
    const path = (try policyPath(allocator)) orelse return null;
    defer allocator.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(max_policy_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        // Oversized/truncated file: treat as no policy (degrade, do not crash).
        error.StreamTooLong => return null,
        else => return err,
    };
    defer allocator.free(bytes);

    const parsed = parse_helpers.parseJsonBounded(std.json.Value, allocator, parse_helpers.stripBom(bytes)) catch return null;
    return .{ .parsed = parsed };
}

/// True when org policy force-disables `plugin_id` (`enabledPlugins[id] ===
/// false`). Mirrors `isPluginBlockedByPolicy`. An absent entry, a `true`
/// entry, an array entry, or no policy file at all all return false (only an
/// explicit `false` blocks).
pub fn isBlockedByPolicy(allocator: std.mem.Allocator, plugin_id: []const u8) !bool {
    var policy = (try readPolicy(allocator)) orelse return false;
    defer policy.deinit();

    const map = policy.enabledMap() orelse return false;
    const entry = map.get(plugin_id) orelse return false;
    return switch (entry) {
        .bool => |b| b == false,
        else => false,
    };
}

/// The set of plugin NAMES (the part before `@`) that org policy manages, i.e.
/// has a boolean entry for (true OR false). Mirrors `getManagedPluginNames`:
/// only `name@marketplace` boolean-keyed ids are protected; legacy array-form
/// or non-`@` keys are ignored. A managed plugin cannot be disabled by the user
/// (a `true` entry protects it; a `false` entry blocks it outright). Returns an
/// empty slice when no policy declares any boolean plugin entry. Caller owns the
/// returned slice and each member.
pub fn managedPluginNames(allocator: std.mem.Allocator) ![]const []const u8 {
    var policy = (try readPolicy(allocator)) orelse return &[_][]const u8{};
    defer policy.deinit();

    const map = policy.enabledMap() orelse return &[_][]const u8{};

    var names = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit();
    }

    var it = map.iterator();
    while (it.next()) |kv| {
        const id = kv.key_ptr.*;
        // Only boolean entries on a `name@marketplace` id are protected
        // (managedPlugins.ts:18). Skip array/legacy forms and bare keys.
        if (kv.value_ptr.* != .bool) continue;
        const at = std.mem.indexOfScalar(u8, id, '@') orelse continue;
        const name = id[0..at];
        if (name.len == 0) continue;
        // Dedupe: the same name across two marketplaces collapses to one.
        var seen = false;
        for (names.items) |existing| {
            if (std.mem.eql(u8, existing, name)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        try names.append(try allocator.dupe(u8, name));
    }

    return names.toOwnedSlice();
}

/// True when the plugin NAME is policy-managed (has any boolean policy entry),
/// so the user must not be allowed to disable it. Convenience over
/// `managedPluginNames` for the disable chokepoint.
pub fn isNameManaged(allocator: std.mem.Allocator, name: []const u8) !bool {
    const names = try managedPluginNames(allocator);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

pub fn freeNames(allocator: std.mem.Allocator, names: []const []const u8) void {
    for (names) |n| allocator.free(n);
    allocator.free(names);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const test_helpers = @import("test_helpers.zig");

const ManagedPin = struct {
    prev: ?[]u8,

    fn set(allocator: std.mem.Allocator, path: []const u8) !ManagedPin {
        const env = @import("env.zig");
        const prev = env.getOwned(allocator, "ZCODE_MANAGED_CONFIG") catch null;
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        _ = setenv("ZCODE_MANAGED_CONFIG", path_z, 1);
        return .{ .prev = prev };
    }

    fn deinit(self: *ManagedPin, allocator: std.mem.Allocator) void {
        if (self.prev) |p| {
            const z = allocator.dupeZ(u8, p) catch null;
            if (z) |zz| {
                _ = setenv("ZCODE_MANAGED_CONFIG", zz, 1);
                allocator.free(zz);
            }
            allocator.free(p);
        } else {
            _ = unsetenv("ZCODE_MANAGED_CONFIG");
        }
    }
};

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Write a managed policy file at `<dir>/policy_plugins.json` with the given
/// raw JSON body, and return the managed-config path (`<dir>/managed.toml`)
/// that ZCODE_MANAGED_CONFIG must point at. Caller owns the returned slice.
fn writePolicyFile(allocator: std.mem.Allocator, dir: []const u8, body: []const u8) ![]u8 {
    const policy_full = try std.fs.path.join(allocator, &.{ dir, policy_file_name });
    defer allocator.free(policy_full);
    try std.Io.Dir.cwd().writeFile(rt.io, .{ .sub_path = policy_full, .data = body });
    return std.fs.path.join(allocator, &.{ dir, "managed.toml" });
}

test "Task 17.7: isBlockedByPolicy true for an explicit false entry" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(dir);

    const managed_path = try writePolicyFile(
        allocator,
        dir,
        "{\"enabledPlugins\":{\"evil@market\":false}}",
    );
    defer allocator.free(managed_path);

    var pin = try ManagedPin.set(allocator, managed_path);
    defer pin.deinit(allocator);

    try testing.expect(try isBlockedByPolicy(allocator, "evil@market"));
    // A different id, a true entry, and an absent file all do NOT block.
    try testing.expect(!try isBlockedByPolicy(allocator, "good@market"));
}

test "Task 17.7: isBlockedByPolicy false for true entry and absent file" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(dir);

    const managed_path = try writePolicyFile(
        allocator,
        dir,
        "{\"enabledPlugins\":{\"blessed@market\":true}}",
    );
    defer allocator.free(managed_path);

    var pin = try ManagedPin.set(allocator, managed_path);
    defer pin.deinit(allocator);

    // A protected (true) plugin is NOT blocked; install is allowed.
    try testing.expect(!try isBlockedByPolicy(allocator, "blessed@market"));
}

test "Task 17.7: managedPluginNames returns names and ignores array-form entries" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(dir);

    // evil@market => boolean (managed). owner/repo array form => ignored.
    // bareKey (no @) => ignored.
    const managed_path = try writePolicyFile(
        allocator,
        dir,
        "{\"enabledPlugins\":{\"evil@market\":false,\"legacy@old\":[\"^1.0.0\"],\"barekey\":true}}",
    );
    defer allocator.free(managed_path);

    var pin = try ManagedPin.set(allocator, managed_path);
    defer pin.deinit(allocator);

    const names = try managedPluginNames(allocator);
    defer freeNames(allocator, names);

    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("evil", names[0]);

    try testing.expect(try isNameManaged(allocator, "evil"));
    try testing.expect(!try isNameManaged(allocator, "legacy"));
}

test "Task 17.7: no policy file means nothing is blocked or managed" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(dir);

    // Point at a managed.toml whose dir has NO policy_plugins.json.
    const managed_path = try std.fs.path.join(allocator, &.{ dir, "managed.toml" });
    defer allocator.free(managed_path);

    var pin = try ManagedPin.set(allocator, managed_path);
    defer pin.deinit(allocator);

    try testing.expect(!try isBlockedByPolicy(allocator, "anything@market"));
    const names = try managedPluginNames(allocator);
    defer freeNames(allocator, names);
    try testing.expectEqual(@as(usize, 0), names.len);
}
