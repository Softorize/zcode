//! Collect MCP servers contributed by enabled plugins (plugins-03).
//!
//! An enabled plugin can declare an `mcpServers` block in its manifest so it
//! ships a stdio/HTTP MCP server without a separate `mcp add`. The manifest
//! parse (`plugins.zig:parsePluginMcpServers`) already namespaces each server
//! `plugin:<plugin-name>:<server>` and stamps it with `plugin_source`, applies
//! the path-traversal guard for stdio commands, and skips `.mcpb`/DXT bundle
//! entries (unsupported). This module gathers those parsed servers across all
//! enabled plugins so the live MCP client can splice them into the merged
//! server set at the lowest precedence (plugin < user < project < local).
//!
//! The servers are returned session-only: the caller hands them to
//! `mcp_config.mergeScopes` as the `plugin` scope and they are never written
//! into the persisted registry file, so uninstalling/disabling a plugin removes
//! its servers with no registry mutation. Final dedup against user-registered
//! servers (by command/url signature) happens in `mergeScopes` with
//! `dedup_plugins = true`; here we only dedup by the namespaced name across
//! plugins so two plugins claiming the same `plugin:<name>:<server>` id do not
//! both appear.
//!
//! Mirrors `utils/plugins/mcpPluginIntegration.ts:1-90` (the manifest
//! `mcpServers` merge); the `.mcpb` bundle download/extraction in
//! `mcpbHandler.ts` is documented out of scope.

const std = @import("std");
const rt = @import("zcode_runtime");
const std_io = @import("std_io.zig");
const plugins = @import("plugins.zig");
const mcp_config = @import("mcp_config.zig");

/// Gather the namespaced MCP server configs from every enabled plugin. The
/// returned slice is owned by the caller and freed with
/// `mcp_config.freeServerConfigs`. Disabled plugins (per the effective
/// enabled state in `plugins.list`) contribute nothing. On a namespaced-name
/// collision between two plugins, the first-loaded server wins and the later
/// duplicate is dropped (a debug line is emitted when `ZCODE_DEBUG` is set).
pub fn collect(allocator: std.mem.Allocator, cwd: []const u8) ![]mcp_config.ServerConfig {
    const list = try plugins.list(allocator, cwd);
    defer plugins.freeList(allocator, list);

    var out = std.array_list.Managed(mcp_config.ServerConfig).init(allocator);
    errdefer mcp_config.freeServerConfigs(allocator, out.toOwnedSlice() catch &.{});

    for (list) |plugin| {
        if (!plugin.enabled) continue;
        for (plugin.mcp_servers) |*srv| {
            if (containsName(out.items, srv.name)) {
                debugConflict(srv.name);
                continue;
            }
            // Deep-clone: the source servers live on `list`, which is freed when
            // this function returns. The clone is independently owned.
            var cloned = try mcp_config.cloneServerConfig(allocator, srv);
            errdefer cloned.deinit(allocator);
            try out.append(cloned);
        }
    }

    return out.toOwnedSlice();
}

fn containsName(servers: []const mcp_config.ServerConfig, name: []const u8) bool {
    for (servers) |*s| {
        if (std.mem.eql(u8, s.name, name)) return true;
    }
    return false;
}

fn debugConflict(name: []const u8) void {
    const env = @import("env.zig");
    const dbg = env.getOwned(std.heap.page_allocator, "ZCODE_DEBUG") catch return;
    defer std.heap.page_allocator.free(dbg);
    if (dbg.len == 0) return;
    std_io.stderrWriter().print(
        "mcp: plugin server '{s}' skipped (duplicate namespaced name from another plugin)\n",
        .{name},
    ) catch {};
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;
const test_helpers = @import("test_helpers.zig");
const plugin_settings = @import("plugin_settings.zig");

fn findServer(servers: []mcp_config.ServerConfig, name: []const u8) ?*mcp_config.ServerConfig {
    for (servers) |*s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

test "plugin_mcp.collect: enabled plugin server is namespaced and command resolves under root" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".zcode/plugins/demo");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/plugins/demo/plugin.json",
        .data =
        \\{
        \\  "name": "demo",
        \\  "version": "1.0.0",
        \\  "mcpServers": {
        \\    "db": { "transport": "stdio", "command": "./srv.sh" }
        \\  }
        \\}
        ,
    });

    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    // A workspace plugin in an untrusted tmp dir defaults to disabled; toggle it
    // on so collect (which skips disabled plugins) sees it.
    try plugin_settings.setEnabled(allocator, cwd, .workspace, "demo@local", true);

    const servers = try collect(allocator, cwd);
    defer mcp_config.freeServerConfigs(allocator, servers);

    try testing.expectEqual(@as(usize, 1), servers.len);
    const db = findServer(servers, "plugin:demo:db").?;
    try testing.expectEqual(mcp_config.TransportType.stdio, db.type);
    try testing.expectEqualStrings("./srv.sh", db.command.?);
    try testing.expectEqualStrings("demo", db.plugin_source.?);
}

test "plugin_mcp.collect: disabled plugin contributes zero servers" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A workspace-scope plugin with no trust is disabled by default; that is
    // the simplest way to exercise the !enabled skip without writing settings.
    try tmp.dir.createDirPath(rt.io, ".zcode/plugins/off");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/plugins/off/plugin.json",
        .data =
        \\{
        \\  "name": "off",
        \\  "version": "1.0.0",
        \\  "mcpServers": { "db": { "command": "./srv.sh" } }
        \\}
        ,
    });

    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    // Confirm the plugin is actually present-but-disabled (workspace, untrusted).
    const list = try plugins.list(allocator, cwd);
    defer plugins.freeList(allocator, list);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expect(!list[0].enabled);

    const servers = try collect(allocator, cwd);
    defer mcp_config.freeServerConfigs(allocator, servers);
    try testing.expectEqual(@as(usize, 0), servers.len);
}

test "plugin_mcp.collect: command escaping the plugin root with .. is rejected" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".zcode/plugins/demo");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/plugins/demo/plugin.json",
        .data =
        \\{
        \\  "name": "demo",
        \\  "version": "1.0.0",
        \\  "mcpServers": {
        \\    "evil": { "transport": "stdio", "command": "../escape.sh" },
        \\    "ok":   { "transport": "stdio", "command": "./srv.sh" }
        \\  }
        \\}
        ,
    });

    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    try plugin_settings.setEnabled(allocator, cwd, .workspace, "demo@local", true);

    const servers = try collect(allocator, cwd);
    defer mcp_config.freeServerConfigs(allocator, servers);

    // The traversal entry is dropped; the safe one survives.
    try testing.expect(findServer(servers, "plugin:demo:evil") == null);
    try testing.expect(findServer(servers, "plugin:demo:ok") != null);
}

test "plugin_mcp.collect: server colliding with a user-registered name does not override it" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Plugin declares a server whose namespaced id is plugin:demo:db. A user
    // server named "db" (different name once namespaced) is merged after the
    // plugin scope, so even the bare-name path keeps the user entry winning.
    try tmp.dir.createDirPath(rt.io, ".zcode/plugins/demo");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/plugins/demo/plugin.json",
        .data =
        \\{
        \\  "name": "demo",
        \\  "version": "1.0.0",
        \\  "mcpServers": { "db": { "command": "./plugin-srv.sh" } }
        \\}
        ,
    });

    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    try plugin_settings.setEnabled(allocator, cwd, .workspace, "demo@local", true);

    // `mergeScopes` MOVES the plugin slice in (and frees it), so it must NOT be
    // freed separately here (that would double-free).
    const plugin_servers = try collect(allocator, cwd);

    // A user-registered server keeps its own (un-namespaced) name and command.
    var user = try mcp_config.parseMcpJson(allocator,
        \\{ "mcpServers": { "db": { "command": "user-srv" } } }
    , .user, false);
    user.errors = &.{};

    var merged = try mcp_config.mergeScopes(allocator, .{
        .plugin = plugin_servers,
        .user = user.servers,
        .dedup_plugins = true,
    });
    defer merged.deinit(allocator);

    // The user "db" is untouched; the plugin server appears under its
    // namespaced id, not as "db".
    const user_db = findServer(merged.servers, "db").?;
    try testing.expectEqualStrings("user-srv", user_db.command.?);
    try testing.expect(findServer(merged.servers, "plugin:demo:db") != null);
}
