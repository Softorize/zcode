//! settings.json multi-source loader and precedence chain.
//!
//! This is a deep, single-purpose module: pure source resolution plus a
//! bounded JSON read, with no business logic. It mirrors the reference
//! `utils/settings/constants.ts` (SETTING_SOURCES / PERMISSION_RULE_SOURCES)
//! so that downstream subsystems (permissions, hooks, model governance)
//! all read settings.json from the same five disk sources in the same
//! precedence order.
//!
//! zcode keeps its TOML config stack as the source of truth for
//! zcode-native keys. This module ADDS a parallel settings.json layer so
//! Claude Code config artifacts (.claude/settings.json permissions/hooks/env,
//! availableModels) are honored. TOML and settings.json coexist.
//!
//! Reference: SETTING_SOURCES lists user, project, local, flag, policy for
//! *override* semantics (later wins on scalar merges). PERMISSION_RULE_SOURCES
//! appends cliArg/command/session and is used for *rule collection* (deny
//! beats allow at match time, not by list order). These are kept as two
//! separate enums to match the reference exactly.

const std = @import("std");
const rt = @import("zcode_runtime");
const paths = @import("paths.zig");
const parse_helpers = @import("parse_helpers.zig");
const std_io = @import("std_io.zig");

/// Cap on a single settings.json file. 256 KiB matches the cap used for
/// hook settings.json reads in `core/hooks.zig`. readFileAlloc(.limited(N))
/// yields error.StreamTooLong (NOT error.FileTooBig) when exceeded - we
/// treat that as "too big, ignore" rather than failing the whole load.
const MAX_SETTINGS_BYTES: usize = 256 * 1024;

/// The five disk-backed settings sources, in scalar-override precedence
/// order semantics. See `sourceOrder()` for the override ordering.
pub const Source = enum {
    policy,
    flag,
    user,
    project,
    local,

    /// Lowercase human-readable name matching the reference
    /// `getSettingSourceDisplayNameLowercase` (constants.ts:69-90).
    pub fn displayName(self: Source) []const u8 {
        return switch (self) {
            .policy => "enterprise managed settings",
            .flag => "command line arguments",
            .user => "user settings",
            .project => "shared project settings",
            .local => "project local settings",
        };
    }
};

/// The permission-rule collection sources. Extends `Source` with the
/// runtime-populated cli_arg/command/session sources. Used for *rule
/// collection*, not scalar override. Mirrors PERMISSION_RULE_SOURCES
/// (permissions.ts:109-114). Only the first five are disk-backed; the
/// last three are populated at runtime by later phases (CLI flags, slash
/// commands, in-session approvals).
pub const PermissionRuleSource = enum {
    policy,
    flag,
    user,
    project,
    local,
    cli_arg,
    command,
    session,

    pub fn displayName(self: PermissionRuleSource) []const u8 {
        return switch (self) {
            .policy => "enterprise managed settings",
            .flag => "command line arguments",
            .user => "user settings",
            .project => "shared project settings",
            .local => "project local settings",
            .cli_arg => "CLI argument",
            .command => "command configuration",
            .session => "session",
        };
    }
};

/// Scalar-override order: later sources override earlier ones. Matches the
/// reference SETTING_SOURCES = [user, project, local, flag, policy]
/// (constants.ts:5-22). When merging a scalar, walk this list front to
/// back and let the last source that defines the key win - so policy wins
/// over everything, then flag, then local, project, user.
pub fn sourceOrder() [5]Source {
    return .{ .user, .project, .local, .flag, .policy };
}

/// Resolve the on-disk file path for one settings source. Caller owns the
/// returned slice. Returns null for the `flag` source when no `--settings`
/// path was supplied (the source is then empty).
///
/// - user    -> {zcode_home}/settings.json
/// - project -> {cwd}/.claude/settings.json
/// - local   -> {cwd}/.claude/settings.local.json
/// - policy  -> {zcode_home}/policy/settings.json
/// - flag    -> the explicit --settings path (or null when unset)
pub fn sourcePath(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    source: Source,
    flag_path: ?[]const u8,
) !?[]u8 {
    switch (source) {
        .flag => {
            if (flag_path) |p| return try allocator.dupe(u8, p);
            return null;
        },
        .user => {
            var resolved = try paths.resolve(allocator);
            defer resolved.deinit(allocator);
            return try std.fs.path.join(allocator, &.{ resolved.zcode_home, "settings.json" });
        },
        .policy => {
            var resolved = try paths.resolve(allocator);
            defer resolved.deinit(allocator);
            return try std.fs.path.join(allocator, &.{ resolved.zcode_home, "policy", "settings.json" });
        },
        .project => {
            return try std.fs.path.join(allocator, &.{ cwd, ".claude", "settings.json" });
        },
        .local => {
            return try std.fs.path.join(allocator, &.{ cwd, ".claude", "settings.local.json" });
        },
    }
}

/// Read and parse one settings source. Returns:
/// - null when the source has no file (missing file, or flag source with
///   no --settings path). A missing file is NOT an error.
/// - a Parsed(std.json.Value) wrapping the parsed JSON object otherwise.
///   An empty/whitespace-only file parses to an empty object.
///
/// The caller owns the returned Parsed and must call `.deinit()` on it.
/// Hostile payloads are bounded via parse_helpers.parseJsonBounded.
/// Oversize files (StreamTooLong) and parse errors degrade to null rather
/// than failing the whole load, mirroring the reference's lenient read.
pub fn readSource(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    source: Source,
    flag_path: ?[]const u8,
) !?std.json.Parsed(std.json.Value) {
    // config-layout-01: the user scope reads BOTH `~/.claude/settings.json`
    // (the reference location) and zcode's own `{zcode_home}/settings.json`,
    // merged with zcode winning on a shared key. Every other scope is a
    // single-file read.
    if (source == .user) return readUserSource(allocator);

    const path = (try sourcePath(allocator, cwd, source, flag_path)) orelse return null;
    defer allocator.free(path);

    return readSettingsFile(allocator, path);
}

/// Shared bounded-JSON-file reader used by every disk-backed source. Missing
/// file, oversize file (StreamTooLong), and parse errors all degrade to null
/// (a lenient read, mirroring the reference) rather than failing the whole
/// settings load.
fn readSettingsFile(allocator: std.mem.Allocator, path: []const u8) !?std.json.Parsed(std.json.Value) {
    const data = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(MAX_SETTINGS_BYTES)) catch |err| switch (err) {
        error.FileNotFound => return null,
        // 256 KiB cap exceeded: treat as empty / ignore rather than fail.
        error.StreamTooLong => return null,
        else => return null,
    };
    defer allocator.free(data);

    const clean = parse_helpers.stripBom(data);
    // Empty / whitespace-only file -> empty object so callers always get a
    // valid object value to read keys from.
    const trimmed = std.mem.trim(u8, clean, " \t\r\n");
    if (trimmed.len == 0) {
        return try parse_helpers.parseJsonBounded(std.json.Value, allocator, "{}");
    }

    return parse_helpers.parseJsonBounded(std.json.Value, allocator, clean) catch return null;
}

/// config-layout-01: user-scope settings resolution. Claude Code's user
/// settings live at `~/.claude/settings.json`; zcode's native equivalent is
/// `{zcode_home}/settings.json` (usually `~/.zcode/settings.json`, or
/// `$XDG_CONFIG_HOME/zcode/settings.json`). Reading both means a machine
/// already configured for Claude Code works with zcode unchanged. When only
/// one file exists, its value is returned unchanged (the common case, and
/// the fast path -- no merge cost). When both exist, the two objects are
/// shallow-merged at the top level with the zcode-native file winning a
/// shared key (repo convention: zcode-specific config wins on conflict).
fn readUserSource(allocator: std.mem.Allocator) !?std.json.Parsed(std.json.Value) {
    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);
    const zcode_path = try std.fs.path.join(allocator, &.{ resolved.zcode_home, "settings.json" });
    defer allocator.free(zcode_path);
    const claude_path = try paths.claudeHomePathAlloc(allocator, "settings.json");
    defer allocator.free(claude_path);

    var zcode_parsed = try readSettingsFile(allocator, zcode_path);
    var claude_parsed = try readSettingsFile(allocator, claude_path);

    if (zcode_parsed == null and claude_parsed == null) return null;
    if (zcode_parsed == null) return claude_parsed;
    if (claude_parsed == null) return zcode_parsed;

    // Both exist: their values still alias into each Parsed's own backing
    // memory at this point, so serialize a merged view to text BEFORE either
    // side is torn down, then reparse into an independent, freshly-owned
    // Parsed. This mirrors the stringify-then-reparse technique already used
    // by `agents.zig`'s `parseAgentMcpServers` to avoid a bespoke deep-clone.
    defer zcode_parsed.?.deinit();
    defer claude_parsed.?.deinit();

    var merged: std.json.ObjectMap = .empty;
    defer merged.deinit(allocator);

    if (claude_parsed.?.value == .object) {
        var it = claude_parsed.?.value.object.iterator();
        while (it.next()) |entry| try merged.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
    }
    // zcode's own keys are inserted last so `ObjectMap.put`'s overwrite
    // semantics let them win a same-key conflict.
    if (zcode_parsed.?.value == .object) {
        var it = zcode_parsed.?.value.object.iterator();
        while (it.next()) |entry| try merged.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
    }

    var body = std_io.StringBuilder.init(allocator);
    defer body.deinit();
    try std.json.Stringify.value(std.json.Value{ .object = merged }, .{}, body.writer());

    return parse_helpers.parseJsonBounded(std.json.Value, allocator, body.items()) catch null;
}

// ── Lenient accessors ──────────────────────────────────────────────────
//
// These tolerate a missing key or a wrong type (return null), mirroring the
// reference's lenient read. They operate on a parsed std.json.Value that is
// expected to be an object; a non-object value yields null for every key.

/// Read a string-valued key from a parsed object. Returns null on missing
/// key, non-object root, or non-string value. The returned slice borrows
/// from the Parsed handle and is valid until that handle is freed.
pub fn getString(value: std.json.Value, key: []const u8) ?[]const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    const entry = obj.get(key) orelse return null;
    return switch (entry) {
        .string => |s| s,
        else => null,
    };
}

/// Read a bool-valued key from a parsed object. Returns null on missing
/// key, non-object root, or non-bool value.
pub fn getBool(value: std.json.Value, key: []const u8) ?bool {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    const entry = obj.get(key) orelse return null;
    return switch (entry) {
        .bool => |b| b,
        else => null,
    };
}

/// Read an integer-valued key from a parsed object. Returns null on missing
/// key, non-object root, or non-integer value (config-layout-17: e.g.
/// `cleanupPeriodDays`).
pub fn getInt(value: std.json.Value, key: []const u8) ?i64 {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    const entry = obj.get(key) orelse return null;
    return switch (entry) {
        .integer => |n| n,
        else => null,
    };
}

/// Read an array-valued key from a parsed object. Returns null on missing
/// key, non-object root, or non-array value. The returned slice borrows
/// from the Parsed handle and is valid until that handle is freed.
pub fn getArray(value: std.json.Value, key: []const u8) ?[]std.json.Value {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    const entry = obj.get(key) orelse return null;
    return switch (entry) {
        .array => |a| a.items,
        else => null,
    };
}

/// Read an object-valued key from a parsed object (e.g. the `permissions`
/// or `hooks` block). Returns null on missing key, non-object root, or
/// non-object value.
pub fn getObject(value: std.json.Value, key: []const u8) ?std.json.Value {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    const entry = obj.get(key) orelse return null;
    return switch (entry) {
        .object => entry,
        else => null,
    };
}

/// Merge a scalar bool across all five disk sources in `sourceOrder()`
/// precedence (later sources win). Returns null when no source defines the
/// key. This is the primitive that Task 4 (hooks `disableAllHooks`) and
/// Task 2 (`allowManagedPermissionRulesOnly`) build on.
pub fn mergedScalarBool(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    flag_path: ?[]const u8,
    key: []const u8,
) ?bool {
    var result: ?bool = null;
    for (sourceOrder()) |source| {
        var parsed = (readSource(allocator, cwd, source, flag_path) catch null) orelse continue;
        defer parsed.deinit();
        if (getBool(parsed.value, key)) |b| {
            result = b;
        }
    }
    return result;
}

/// Read a scalar bool from a single source only. Returns null when the
/// source is missing or does not define the key. Used by callers that need
/// to restrict a read to the policy source (e.g.
/// `allowManagedPermissionRulesOnly` is policy-only).
pub fn sourceScalarBool(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    flag_path: ?[]const u8,
    source: Source,
    key: []const u8,
) ?bool {
    var parsed = (readSource(allocator, cwd, source, flag_path) catch null) orelse return null;
    defer parsed.deinit();
    return getBool(parsed.value, key);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const test_helpers = @import("test_helpers.zig");

test "sourceOrder returns user, project, local, flag, policy" {
    const order = sourceOrder();
    try testing.expectEqual(Source.user, order[0]);
    try testing.expectEqual(Source.project, order[1]);
    try testing.expectEqual(Source.local, order[2]);
    try testing.expectEqual(Source.flag, order[3]);
    try testing.expectEqual(Source.policy, order[4]);
}

test "displayName matches reference strings" {
    try testing.expectEqualStrings("enterprise managed settings", Source.policy.displayName());
    try testing.expectEqualStrings("user settings", Source.user.displayName());
    try testing.expectEqualStrings("shared project settings", Source.project.displayName());
    try testing.expectEqualStrings("project local settings", Source.local.displayName());
    try testing.expectEqualStrings("command line arguments", Source.flag.displayName());

    try testing.expectEqualStrings("CLI argument", PermissionRuleSource.cli_arg.displayName());
    try testing.expectEqualStrings("command configuration", PermissionRuleSource.command.displayName());
    try testing.expectEqualStrings("session", PermissionRuleSource.session.displayName());
}

test "readSource reads project and local settings from a tmp dir" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".claude");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".claude/settings.json",
        .data = "{\"permissions\":{\"allow\":[\"Read\"]}}",
    });
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".claude/settings.local.json",
        .data = "{\"permissions\":{\"allow\":[\"Write\"]}}",
    });

    const cwd = try test_helpers.tmpDirPath(alloc, &tmp, ".");
    defer alloc.free(cwd);

    var project = (try readSource(alloc, cwd, .project, null)).?;
    defer project.deinit();
    const proj_perms = getObject(project.value, "permissions").?;
    const proj_allow = getArray(proj_perms, "allow").?;
    try testing.expectEqual(@as(usize, 1), proj_allow.len);
    try testing.expectEqualStrings("Read", proj_allow[0].string);

    var local = (try readSource(alloc, cwd, .local, null)).?;
    defer local.deinit();
    const local_perms = getObject(local.value, "permissions").?;
    const local_allow = getArray(local_perms, "allow").?;
    try testing.expectEqual(@as(usize, 1), local_allow.len);
    try testing.expectEqualStrings("Write", local_allow[0].string);
}

test "readSource returns null for a missing source file" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try test_helpers.tmpDirPath(alloc, &tmp, ".");
    defer alloc.free(cwd);

    // No .claude/ tree was created, so the project source has no file.
    const project = try readSource(alloc, cwd, .project, null);
    try testing.expect(project == null);

    const local = try readSource(alloc, cwd, .local, null);
    try testing.expect(local == null);
}

test "readSource flag source is null when no flag path supplied" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try test_helpers.tmpDirPath(alloc, &tmp, ".");
    defer alloc.free(cwd);

    const flag = try readSource(alloc, cwd, .flag, null);
    try testing.expect(flag == null);
}

test "readSource reads the explicit flag path" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "custom-settings.json",
        .data = "{\"permissions\":{\"deny\":[\"Bash\"]}}",
    });

    const flag_path = try test_helpers.tmpDirPath(alloc, &tmp, "custom-settings.json");
    defer alloc.free(flag_path);
    const cwd = try test_helpers.tmpDirPath(alloc, &tmp, ".");
    defer alloc.free(cwd);

    var flag = (try readSource(alloc, cwd, .flag, flag_path)).?;
    defer flag.deinit();
    const perms = getObject(flag.value, "permissions").?;
    const deny = getArray(perms, "deny").?;
    try testing.expectEqual(@as(usize, 1), deny.len);
    try testing.expectEqualStrings("Bash", deny[0].string);
}

test "readSource treats empty file as empty object" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".claude");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".claude/settings.json",
        .data = "   \n  ",
    });

    const cwd = try test_helpers.tmpDirPath(alloc, &tmp, ".");
    defer alloc.free(cwd);

    var project = (try readSource(alloc, cwd, .project, null)).?;
    defer project.deinit();
    // Empty object -> no permissions key.
    try testing.expect(getObject(project.value, "permissions") == null);
}

test "lenient accessors tolerate wrong types and missing keys" {
    const alloc = testing.allocator;
    var parsed = try parse_helpers.parseJsonBounded(
        std.json.Value,
        alloc,
        "{\"s\":\"hi\",\"b\":true,\"a\":[1,2],\"n\":5}",
    );
    defer parsed.deinit();

    try testing.expectEqualStrings("hi", getString(parsed.value, "s").?);
    try testing.expectEqual(true, getBool(parsed.value, "b").?);
    try testing.expectEqual(@as(usize, 2), getArray(parsed.value, "a").?.len);
    try testing.expectEqual(@as(i64, 5), getInt(parsed.value, "n").?);

    // Wrong type -> null.
    try testing.expect(getString(parsed.value, "b") == null);
    try testing.expect(getBool(parsed.value, "s") == null);
    try testing.expect(getArray(parsed.value, "n") == null);
    try testing.expect(getInt(parsed.value, "s") == null);
    // Missing key -> null.
    try testing.expect(getString(parsed.value, "missing") == null);
}

// config-layout-01: user-scope settings.json falls back to
// `~/.claude/settings.json`, with zcode's own `~/.zcode/settings.json`
// winning on a shared key. Both tests override HOME (and blank
// XDG_CONFIG_HOME so no stray real value redirects zcode_home away from
// HOME) so `paths.resolve()` -- which readUserSource calls internally --
// resolves against the tmp dir instead of the real machine's HOME.
const env_mod = @import("env.zig");

test "config-layout-01: user source falls back to ~/.claude/settings.json when ~/.zcode has none" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    defer env_mod.clearOverrides();
    try env_mod.setOverride("HOME", root);
    try env_mod.setOverride("XDG_CONFIG_HOME", "");

    try tmp.dir.createDirPath(rt.io, ".claude");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".claude/settings.json",
        .data = "{\"permissions\":{\"allow\":[\"Read\"]}}",
    });

    // No ~/.zcode/settings.json exists at all.
    var user = (try readSource(alloc, root, .user, null)).?;
    defer user.deinit();
    const perms = getObject(user.value, "permissions").?;
    const allow = getArray(perms, "allow").?;
    try testing.expectEqual(@as(usize, 1), allow.len);
    try testing.expectEqualStrings("Read", allow[0].string);
}

test "config-layout-01: when both ~/.claude and ~/.zcode settings.json define a key, ~/.zcode wins" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    defer env_mod.clearOverrides();
    try env_mod.setOverride("HOME", root);
    try env_mod.setOverride("XDG_CONFIG_HOME", "");

    try tmp.dir.createDirPath(rt.io, ".claude");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".claude/settings.json",
        .data = "{\"permissions\":{\"allow\":[\"Read\"]},\"theme\":\"claude-theme\"}",
    });
    try tmp.dir.createDirPath(rt.io, ".zcode");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/settings.json",
        .data = "{\"permissions\":{\"allow\":[\"Write\"]}}",
    });

    var user = (try readSource(alloc, root, .user, null)).?;
    defer user.deinit();

    // Conflicting key ("permissions"): the zcode-native file wins.
    const perms = getObject(user.value, "permissions").?;
    const allow = getArray(perms, "allow").?;
    try testing.expectEqual(@as(usize, 1), allow.len);
    try testing.expectEqualStrings("Write", allow[0].string);

    // Key only ~/.claude/settings.json defines survives the merge.
    try testing.expectEqualStrings("claude-theme", getString(user.value, "theme").?);
}

test "mergedScalarBool lets later sources win" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // project sets key=false, local sets key=true. local is later in
    // sourceOrder() so it must win.
    try tmp.dir.createDirPath(rt.io, ".claude");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".claude/settings.json",
        .data = "{\"disableAllHooks\":false}",
    });
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".claude/settings.local.json",
        .data = "{\"disableAllHooks\":true}",
    });

    const cwd = try test_helpers.tmpDirPath(alloc, &tmp, ".");
    defer alloc.free(cwd);

    const merged = mergedScalarBool(alloc, cwd, null, "disableAllHooks");
    try testing.expectEqual(@as(?bool, true), merged);

    // A key no source defines -> null.
    const absent = mergedScalarBool(alloc, cwd, null, "neverDefined");
    try testing.expect(absent == null);
}
