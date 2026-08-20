const std = @import("std");
const rt = @import("zcode_runtime");
const std_io = @import("std_io.zig");
const display_safe = @import("display_safe.zig");
const paths = @import("paths.zig");
const trust = @import("trust.zig");
const mcp_config = @import("mcp_config.zig");
const plugin_settings = @import("plugin_settings.zig");
const hook_event = @import("hook_event.zig");
const plugin_deps = @import("plugin_deps.zig");
const plugin_policy = @import("plugin_policy.zig");
const plugin_version = @import("plugin_version.zig");
const lsp_config = @import("lsp/config.zig");

pub const PluginScope = enum {
    user,
    workspace,
};

pub const PluginEvent = enum {
    pre_tool_use,
    post_tool_use,
    session_start,
    session_end,
    review_start,
    // Phase 8 (compaction-05): compaction lifecycle events. PreCompact fires
    // before the summarizer runs (carrying the trigger + custom instructions);
    // PostCompact fires after a successful compaction (carrying the summary).
    pre_compact,
    post_compact,
};

pub const PluginCommand = struct {
    name: []u8,
    description: []u8,

    pub fn deinit(self: *PluginCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
    }
};

/// One manifest hook matcher (plugins-02). The reference manifest shape is a
/// `hooks` object keyed by the full PascalCase event name (PreToolUse,
/// SessionStart, ...), each value an array of `{matcher, hooks:[{command}]}`.
/// We flatten that into one of these per (event, matcher, command) triple.
///
/// `event` is the full 26-event `hook_event.Event` (not the legacy 5-event
/// `PluginEvent`), so a plugin can register against any lifecycle event the
/// engine fires. `tool_matcher` is the permission-rule-style matcher ("Bash",
/// "Bash(git *)", "*", or ""); for non-tool events it gates on the event's
/// discriminating field. `command` is the relative entrypoint to run, resolved
/// against the plugin root with the same traversal guard as `resolveEntrypoint`.
/// `plugin_hooks.collect` later stamps these with plugin context.
pub const PluginHookMatcher = struct {
    event: hook_event.Event,
    tool_matcher: []u8,
    command: []u8,

    pub fn deinit(self: *PluginHookMatcher, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_matcher);
        allocator.free(self.command);
    }
};

pub const PluginSpec = struct {
    name: []u8,
    version: []u8,
    description: []u8,
    entrypoint: []u8,
    compatibility: []u8,
    isolation: []u8,
    source_path: []u8,
    root_path: []u8,
    scope: PluginScope,
    /// Canonical `name@marketplace` identity used as the key in the
    /// `enabledPlugins` settings map, dependency resolution, and policy
    /// (plugins-01/05/07). Locally-installed plugins with no remote source use
    /// the `@local` sentinel.
    plugin_id: []u8,
    enabled: bool,
    permissions: []const []const u8,
    events: []PluginEvent,
    commands: []PluginCommand,
    /// MCP servers declared in the plugin manifest's `mcpServers` block
    /// (mcp-11). Each is namespaced `plugin:<plugin-name>:<server>` and stamped
    /// with `plugin_source = <plugin-name>` so the merge layer can dedup them
    /// against manual servers. May be empty.
    mcp_servers: []mcp_config.ServerConfig,
    /// Hook matchers declared in the manifest's `hooks` object (plugins-02),
    /// across the full `hook_event.Event` set. `plugin_hooks.collect` stamps
    /// these with plugin context and the engine (`hooks.zig`) runs the matching
    /// ones for the live event. Separate from `events` (the legacy 5-event
    /// subprocess runner), which is kept for back-compat. May be empty.
    hook_matchers: []PluginHookMatcher,
    /// Dependency ids declared in the manifest's `dependencies` array
    /// (plugins-05). Each is a bare `name` or fully-qualified `name@marketplace`
    /// reference. Used by `plugin_deps` for install-time closure resolution,
    /// load-time demotion, and reverse-dependent warnings. May be empty.
    dependencies: []const []const u8,
    /// LSP server configs declared in the manifest's optional `lspServers` array
    /// (lsp-07, hybrid). `lsp/config.getAllServers` merges these over the
    /// built-in default table (plugin wins on an extension collision). Absent or
    /// malformed -> empty (backward compatible: a manifest with no `lspServers`
    /// is unaffected).
    lsp_servers: []lsp_config.LspServerConfig,

    pub fn deinit(self: *PluginSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.description);
        allocator.free(self.entrypoint);
        allocator.free(self.compatibility);
        allocator.free(self.isolation);
        allocator.free(self.source_path);
        allocator.free(self.root_path);
        allocator.free(self.plugin_id);
        freeStringList(allocator, self.permissions);
        allocator.free(self.events);
        for (self.commands) |*command| command.deinit(allocator);
        allocator.free(self.commands);
        mcp_config.freeServerConfigs(allocator, self.mcp_servers);
        for (self.hook_matchers) |*m| m.deinit(allocator);
        allocator.free(self.hook_matchers);
        freeStringList(allocator, self.dependencies);
        lsp_config.freeServers(allocator, self.lsp_servers);
    }
};

pub const PluginContext = struct {
    event: PluginEvent,
    cwd: []const u8,
    tool_name: []const u8 = "",
    tool_args: []const u8 = "",
    tool_output: []const u8 = "",
    tool_success: bool = false,
    // Phase 8 (compaction-05): discriminator for compaction-driven events.
    // "auto" or "manual" for PreCompact/PostCompact; "compact" for the
    // SessionStart fired after a compaction (so a session-start hook can tell a
    // post-compact restore from a real startup). Empty for non-compaction events.
    trigger: []const u8 = "",
};

pub const PluginRunResult = struct {
    ran: bool,
    blocked: bool,
    output: []u8,

    pub fn deinit(self: *PluginRunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
    }
};

pub fn eventName(event: PluginEvent) []const u8 {
    return switch (event) {
        .pre_tool_use => "pre-tool-use",
        .post_tool_use => "post-tool-use",
        .session_start => "session-start",
        .session_end => "session-end",
        .review_start => "review-start",
        .pre_compact => "pre-compact",
        .post_compact => "post-compact",
    };
}

pub fn scopeName(scope: PluginScope) []const u8 {
    return switch (scope) {
        .user => "user",
        .workspace => "workspace",
    };
}

pub fn list(allocator: std.mem.Allocator, cwd: []const u8) ![]PluginSpec {
    var trust_status = try trust.status(allocator, cwd);
    defer trust_status.deinit(allocator);

    var out = std.array_list.Managed(PluginSpec).init(allocator);
    errdefer freeList(allocator, out.items);

    if (userPluginsRoot(allocator)) |root| {
        defer allocator.free(root);
        try appendPluginsFromRoot(allocator, &out, root, .user, cwd, true);
    } else |_| {}

    const workspace_root = try paths.workspacePathAlloc(allocator, cwd, "plugins");
    defer allocator.free(workspace_root);
    try appendPluginsFromRoot(allocator, &out, workspace_root, .workspace, cwd, trust_status.trusted);

    // Load-time dependency safety net (plugins-05): demote any enabled plugin
    // whose declared dependencies are not all enabled, iterating to a fixed
    // point. This is session-local - it clears `enabled` in the returned list
    // only and never writes the settings map (matches the reference docstring at
    // dependencyResolver.ts:11). A demotion failure (OOM building the index)
    // degrades to "no demotion" rather than failing `plugins list`.
    try demoteUnsatisfied(allocator, out.items);

    return out.toOwnedSlice();
}

/// Run `plugin_deps.verifyAndDemote` over the loaded set and clear `enabled` on
/// any demoted plugin. The `plugin_id` field (Task 17.1) is the demotion key.
fn demoteUnsatisfied(allocator: std.mem.Allocator, specs: []PluginSpec) !void {
    if (specs.len == 0) return;

    var views = try allocator.alloc(plugin_deps.LoadedPlugin, specs.len);
    defer allocator.free(views);
    for (specs, 0..) |spec, i| {
        views[i] = .{
            .source = spec.plugin_id,
            .name = spec.name,
            .enabled = spec.enabled,
            .dependencies = spec.dependencies,
        };
    }

    var demoted = plugin_deps.verifyAndDemote(allocator, views) catch return;
    defer demoted.deinit();
    if (demoted.count() == 0) return;

    for (specs) |*spec| {
        if (spec.enabled and demoted.contains(spec.plugin_id)) spec.enabled = false;
    }
}

pub fn renderList(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const plugins = try list(allocator, cwd);
    defer freeList(allocator, plugins);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    if (plugins.len == 0) {
        try out.writer().writeAll("plugins: none\n");
        return out.toOwnedSlice();
    }

    try out.writer().writeAll("plugins:\n");
    for (plugins) |plugin| {
        const command_count = plugin.commands.len;
        const status_text = if (plugin.enabled) "enabled" else "disabled";
        // Manifest fields are user-controlled JSON; sanitize so a
        // hand-edited plugin.json with a newline in `name` /
        // `version` can't fake a list row.
        const safe_name = try display_safe.sanitize(allocator, plugin.name);
        defer allocator.free(safe_name);
        const safe_version = try display_safe.sanitize(allocator, plugin.version);
        defer allocator.free(safe_version);
        try out.writer().print(
            "- {s}@{s} ({s}) [{s}] commands={d} events={d} status={s}\n",
            .{ safe_name, safe_version, scopeName(plugin.scope), plugin.source_path, command_count, plugin.events.len, status_text },
        );
    }
    return out.toOwnedSlice();
}

pub fn renderDetail(allocator: std.mem.Allocator, cwd: []const u8, name: []const u8) ![]u8 {
    const plugins = try list(allocator, cwd);
    defer freeList(allocator, plugins);

    for (plugins) |plugin| {
        if (!std.mem.eql(u8, plugin.name, name)) continue;

        var out = std_io.StringBuilder.init(allocator);
        errdefer out.deinit();

        try out.writer().print("name: {s}\n", .{plugin.name});
        try out.writer().print("version: {s}\n", .{plugin.version});
        try out.writer().print("scope: {s}\n", .{scopeName(plugin.scope)});
        try out.writer().print("enabled: {}\n", .{plugin.enabled});
        const safe_desc = try display_safe.sanitize(allocator, plugin.description);
        defer allocator.free(safe_desc);
        try out.writer().print("description: {s}\n", .{safe_desc});
        try out.writer().print("compatibility: {s}\n", .{plugin.compatibility});
        try out.writer().print("isolation: {s}\n", .{plugin.isolation});
        try out.writer().print("entrypoint: {s}\n", .{plugin.entrypoint});
        try out.writer().print("manifest: {s}\n", .{plugin.source_path});
        try out.writer().writeAll("permissions:");
        if (plugin.permissions.len == 0) {
            try out.writer().writeAll(" none\n");
        } else {
            for (plugin.permissions) |permission| try out.writer().print(" {s}", .{permission});
            try out.writer().writeByte('\n');
        }
        try out.writer().writeAll("events:");
        if (plugin.events.len == 0) {
            try out.writer().writeAll(" none\n");
        } else {
            for (plugin.events) |event| try out.writer().print(" {s}", .{eventName(event)});
            try out.writer().writeByte('\n');
        }
        try out.writer().writeAll("commands:\n");
        if (plugin.commands.len == 0) {
            try out.writer().writeAll("- none\n");
        } else {
            for (plugin.commands) |command| {
                const safe_cmd_name = try display_safe.sanitize(allocator, command.name);
                defer allocator.free(safe_cmd_name);
                const safe_cmd_desc = try display_safe.sanitize(allocator, command.description);
                defer allocator.free(safe_cmd_desc);
                try out.writer().print("- {s}: {s}\n", .{ safe_cmd_name, safe_cmd_desc });
            }
        }
        return out.toOwnedSlice();
    }

    return error.PluginNotFound;
}

pub fn run(allocator: std.mem.Allocator, ctx: PluginContext) !PluginRunResult {
    const plugins = try list(allocator, ctx.cwd);
    defer freeList(allocator, plugins);

    var last_output = try allocator.dupe(u8, "");
    errdefer allocator.free(last_output);
    var ran = false;

    for (plugins) |plugin| {
        if (!plugin.enabled) continue;
        if (!supportsEvent(&plugin, ctx.event)) continue;
        ran = true;

        var result = try runSingle(allocator, plugin, ctx);
        defer result.deinit(allocator);

        allocator.free(last_output);
        last_output = if (result.output.len > 0)
            try std.fmt.allocPrint(allocator, "[{s}] {s}", .{ plugin.name, result.output })
        else
            try allocator.dupe(u8, "");

        if (result.blocked) {
            return .{
                .ran = true,
                .blocked = true,
                .output = last_output,
            };
        }
    }

    return .{
        .ran = ran,
        .blocked = false,
        .output = last_output,
    };
}

pub fn freeList(allocator: std.mem.Allocator, plugins: []PluginSpec) void {
    for (plugins) |*plugin| plugin.deinit(allocator);
    allocator.free(plugins);
}

fn appendPluginsFromRoot(
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed(PluginSpec),
    root: []const u8,
    scope: PluginScope,
    cwd: []const u8,
    trust_default: bool,
) !void {
    var dir = std.Io.Dir.cwd().openDir(rt.io, root, .{ .iterate = true }) catch return;
    defer dir.close(rt.io);

    var it = dir.iterate();
    while (try it.next(rt.io)) |entry| {
        if (entry.kind != .directory) continue;
        const manifest_path = try std.fs.path.join(allocator, &.{ root, entry.name, "plugin.json" });
        defer allocator.free(manifest_path);
        if (!fileExists(manifest_path)) continue;

        const root_path = try std.fs.path.join(allocator, &.{ root, entry.name });
        defer allocator.free(root_path);

        const plugin = try parseManifestFile(allocator, manifest_path, root_path, scope, cwd, trust_default);
        try out.append(plugin);
    }
}

fn parseManifestFile(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    root_path: []const u8,
    scope: PluginScope,
    cwd: []const u8,
    trust_default: bool,
) !PluginSpec {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(rt.io, manifest_path, allocator, .limited(256 * 1024));
    defer allocator.free(bytes);

    // BOM-tolerant: a plugin manifest written from PowerShell or
    // notepad ships with \xEF\xBB\xBF, which std.json refuses.
    const parse_helpers_mod = @import("parse_helpers.zig");
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, parse_helpers_mod.stripBom(bytes), .{}) catch |err| switch (err) {
        // A malformed plugin manifest used to leak
        // `error.SyntaxError (provider=..., model=...)` through the
        // agent-runtime envelope on `zcode plugins list`. Name the
        // offending file so the user can fix it without guessing.
        error.SyntaxError, error.UnexpectedToken, error.InvalidCharacter, error.UnexpectedEndOfInput => {
            std_io.stderrWriter().print(
                "error: plugins: invalid JSON in plugin manifest ({s}): {s}\n  - Fix the file's JSON or `zcode plugins uninstall <name>` to remove the broken plugin.\n",
                .{ @errorName(err), manifest_path },
            ) catch {};
            return error.InvalidPluginManifest;
        },
        else => return err,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPluginManifest;
    const obj = parsed.value.object;

    const name = getString(obj, "name") orelse return error.InvalidPluginManifest;
    const description = getString(obj, "description") orelse "";
    const entrypoint = getString(obj, "entrypoint") orelse "plugin.sh";
    const compatibility = getString(obj, "compatibility") orelse "zcode-plugin-api/v1";
    const isolation = getString(obj, "isolation") orelse "subprocess";

    // Canonical `name@marketplace` id. Locally-installed plugins (the only kind
    // discovered by directory walk) carry no remote source, so the `@local`
    // sentinel is used. The persisted enabledPlugins map (plugins-01) keys on
    // this id; an absent entry falls back to `trust_default`.
    const id = try plugin_settings.pluginId(allocator, name, null);
    errdefer allocator.free(id);
    // Org policy (plugins-07) is the strongest authority: a force-disabled
    // plugin (`policySettings.enabledPlugins[id] === false`) is `enabled == false`
    // regardless of the user/workspace `enabledPlugins` map or trust. A policy
    // read failure degrades to "no policy" so a broken admin file cannot brick
    // `plugins list`.
    const effective_enabled = if (plugin_policy.isBlockedByPolicy(allocator, id) catch false)
        false
    else
        try plugin_settings.effectiveEnabled(allocator, cwd, id, scope, trust_default);

    // Version derivation (plugins-12): a manifest `version` wins; absent, fall
    // back to the install dir's git short SHA (so cache keys differ across
    // commits), then `"unknown"`. Replaces the old single `"0.1.0"` fallback.
    const version = try plugin_version.calculateVersion(allocator, .{
        .plugin_id = id,
        .manifest_version = getString(obj, "version"),
        .install_path = root_path,
    });
    errdefer allocator.free(version);

    return .{
        .name = try allocator.dupe(u8, name),
        .version = version,
        .description = try allocator.dupe(u8, description),
        .entrypoint = try allocator.dupe(u8, entrypoint),
        .compatibility = try allocator.dupe(u8, compatibility),
        .isolation = try allocator.dupe(u8, isolation),
        .source_path = try allocator.dupe(u8, manifest_path),
        .root_path = try allocator.dupe(u8, root_path),
        .scope = scope,
        .plugin_id = id,
        .enabled = effective_enabled,
        .permissions = try parseStringArray(allocator, obj.get("permissions")),
        .events = try parseEventArray(allocator, obj.get("events")),
        .commands = try parseCommands(allocator, obj.get("commands")),
        .mcp_servers = try parsePluginMcpServers(allocator, obj.get("mcpServers"), name),
        .hook_matchers = try parseHookMatchers(allocator, obj.get("hooks")),
        .dependencies = try parseStringArray(allocator, obj.get("dependencies")),
        .lsp_servers = try lsp_config.LspServerConfig.parseManifestArray(allocator, obj.get("lspServers")),
    };
}

/// Parse a plugin manifest's `hooks` object (plugins-02) into a flat list of
/// `PluginHookMatcher`. The reference shape is:
///
///   "hooks": { "PreToolUse": [ { "matcher": "Bash",
///       "hooks": [ {"command": "./h.sh"} ] } ], ... }
///
/// keyed by the full PascalCase event name (mapped through
/// `hook_event.fromName`, covering all 26 events). A malformed or missing block
/// yields an empty slice (a broken `hooks` must not break `plugins list`).
/// Entries with no resolvable `command` (or `entrypoint`) are skipped. The
/// `matcher` defaults to "*" (match all) when absent; an unknown event name is
/// skipped.
fn parseHookMatchers(allocator: std.mem.Allocator, value: ?std.json.Value) ![]PluginHookMatcher {
    const v = value orelse return &.{};
    if (v != .object) return &.{};

    var out = std.array_list.Managed(PluginHookMatcher).init(allocator);
    errdefer {
        for (out.items) |*m| m.deinit(allocator);
        out.deinit();
    }

    var it = v.object.iterator();
    while (it.next()) |entry| {
        const event = hook_event.fromName(entry.key_ptr.*) orelse continue;
        const groups = entry.value_ptr.*;
        if (groups != .array) continue;
        for (groups.array.items) |group| {
            if (group != .object) continue;
            const matcher = getString(group.object, "matcher") orelse "*";
            const inner = group.object.get("hooks") orelse continue;
            if (inner != .array) continue;
            for (inner.array.items) |h| {
                if (h != .object) continue;
                // Reference inner hook entries carry a `command` for the plugin
                // subprocess path; accept `entrypoint` as a fallback spelling so a
                // plugin can reuse its top-level entrypoint name.
                const command = getString(h.object, "command") orelse
                    getString(h.object, "entrypoint") orelse continue;
                if (command.len == 0) continue;

                try out.ensureUnusedCapacity(1);
                const dup_matcher = try allocator.dupe(u8, matcher);
                errdefer allocator.free(dup_matcher);
                const dup_command = try allocator.dupe(u8, command);
                out.appendAssumeCapacity(.{
                    .event = event,
                    .tool_matcher = dup_matcher,
                    .command = dup_command,
                });
            }
        }
    }

    return out.toOwnedSlice();
}

/// Parse a plugin manifest's `mcpServers` object into structured
/// `ServerConfig`s (mcp-11). Each server name is namespaced
/// `plugin:<plugin-name>:<server>` and stamped with `plugin_source` set to the
/// plugin name so the merge/dedup layer can attribute it. A malformed or
/// missing block yields an empty slice (no error - a broken `mcpServers` must
/// not break `plugins list`). Mirrors the namespaced plugin-server load at
/// `services/mcp/config.ts:1114-1229`.
fn parsePluginMcpServers(
    allocator: std.mem.Allocator,
    value: ?std.json.Value,
    plugin_name: []const u8,
) ![]mcp_config.ServerConfig {
    const v = value orelse return &.{};
    if (v != .object) return &.{};

    var out = std.array_list.Managed(mcp_config.ServerConfig).init(allocator);
    errdefer {
        for (out.items) |*s| s.deinit(allocator);
        out.deinit();
    }

    var it = v.object.iterator();
    while (it.next()) |entry| {
        const server_name = entry.key_ptr.*;
        if (entry.value_ptr.* != .object) continue;

        // Build a one-server `.mcp.json`-shaped body and reuse the canonical
        // parser so plugin servers go through the same validation as project
        // servers. The plugin scope is tagged `dynamic` (plugin-provided is not
        // one of project/user/local), then re-namespaced + plugin-stamped. The
        // server name and value are emitted via the JSON stringifier so a name
        // containing JSON metacharacters is escaped correctly.
        var body = std_io.StringBuilder.init(allocator);
        defer body.deinit();
        try body.writer().writeAll("{\"mcpServers\":{");
        try std.json.Stringify.value(server_name, .{}, body.writer());
        try body.writer().writeByte(':');
        try std.json.Stringify.value(entry.value_ptr.*, .{}, body.writer());
        try body.writer().writeAll("}}");

        var result = try mcp_config.parseMcpJson(allocator, body.items(), .dynamic, false);
        // The parsed server structs are MOVED out of result.servers one at a
        // time below. `consumed` tracks how many have been moved into `out` so
        // an error mid-loop frees the not-yet-moved tail; deinitErrorsOnly then
        // frees the errors and the (now-consumed) backing slice.
        var consumed: usize = 0;
        errdefer {
            for (result.servers[consumed..]) |*s| s.deinit(allocator);
        }
        defer result.deinitErrorsOnly(allocator);
        for (result.servers) |srv| {
            var stamped = srv;

            // Path-traversal guard (plugins-03). A stdio `command` that is a
            // relative path escaping the plugin root (contains "..") is rejected
            // so a manifest can't point the spawn at a file outside its install
            // dir. Absolute commands and bare names resolved on $PATH (node,
            // python, ...) are allowed; only a relative `..` path is unsafe.
            if (stamped.type == .stdio or stamped.type == .sdk) {
                if (stamped.command) |cmd| {
                    if (!std.fs.path.isAbsolute(cmd) and std.mem.indexOf(u8, cmd, "..") != null) {
                        stamped.deinit(allocator);
                        consumed += 1;
                        continue;
                    }
                }
            }

            // .mcpb / DXT bundle download+extraction is out of scope for this
            // phase (it needs a hosted bundle format + the interactive /plugin
            // config menu). A server entry that points at an .mcpb bundle is
            // skipped with a one-time stderr notice rather than silently
            // ignored, so the operator knows to declare a plain stdio/http entry.
            if (referencesMcpbBundle(&stamped)) {
                noteMcpbUnsupportedOnce(plugin_name);
                stamped.deinit(allocator);
                consumed += 1;
                continue;
            }

            const namespaced = std.fmt.allocPrint(allocator, "plugin:{s}:{s}", .{ plugin_name, server_name }) catch |err| {
                stamped.deinit(allocator);
                consumed += 1;
                return err;
            };
            allocator.free(stamped.name);
            stamped.name = namespaced;
            stamped.plugin_source = allocator.dupe(u8, plugin_name) catch |err| {
                stamped.deinit(allocator);
                consumed += 1;
                return err;
            };
            out.append(stamped) catch |err| {
                stamped.deinit(allocator);
                consumed += 1;
                return err;
            };
            consumed += 1;
        }
    }

    return out.toOwnedSlice();
}

/// Whether a parsed server points at an `.mcpb`/DXT bundle (plugins-03,
/// out-of-scope). True when the stdio `command` or remote `url` ends in `.mcpb`
/// or `.dxt`. Bundle download + extraction is intentionally unsupported; such
/// entries are skipped with a one-time notice.
fn referencesMcpbBundle(srv: *const mcp_config.ServerConfig) bool {
    if (srv.command) |cmd| {
        if (std.mem.endsWith(u8, cmd, ".mcpb") or std.mem.endsWith(u8, cmd, ".dxt")) return true;
    }
    if (srv.url) |url| {
        if (std.mem.endsWith(u8, url, ".mcpb") or std.mem.endsWith(u8, url, ".dxt")) return true;
    }
    return false;
}

/// Emit the `.mcpb`-unsupported notice to stderr at most once per process, so a
/// catalog full of bundle-shipping plugins does not spam the operator. The flag
/// is a process-global one-shot guard (best-effort, not synchronized; plugin
/// parsing is single-threaded).
var mcpb_notice_emitted: bool = false;

fn noteMcpbUnsupportedOnce(plugin_name: []const u8) void {
    if (mcpb_notice_emitted) return;
    mcpb_notice_emitted = true;
    std_io.stderrWriter().print(
        "mcp: plugin '{s}' ships an .mcpb bundle, which is not supported; declare an mcpServers stdio/http entry instead\n",
        .{plugin_name},
    ) catch {};
}

fn parseStringArray(allocator: std.mem.Allocator, value: ?std.json.Value) ![]const []const u8 {
    const v = value orelse return allocator.alloc([]const u8, 0);
    if (v != .array) return allocator.alloc([]const u8, 0);

    var out = std.array_list.Managed([]const u8).init(allocator);
    defer out.deinit();
    for (v.array.items) |item| {
        if (item != .string) continue;
        try out.append(try allocator.dupe(u8, item.string));
    }
    return out.toOwnedSlice();
}

fn parseEventArray(allocator: std.mem.Allocator, value: ?std.json.Value) ![]PluginEvent {
    const v = value orelse return allocator.alloc(PluginEvent, 0);
    if (v != .array) return allocator.alloc(PluginEvent, 0);

    var out = std.array_list.Managed(PluginEvent).init(allocator);
    defer out.deinit();
    for (v.array.items) |item| {
        if (item != .string) continue;
        if (parseEvent(item.string)) |event| try out.append(event);
    }
    return out.toOwnedSlice();
}

fn parseCommands(allocator: std.mem.Allocator, value: ?std.json.Value) ![]PluginCommand {
    const v = value orelse return allocator.alloc(PluginCommand, 0);
    if (v != .array) return allocator.alloc(PluginCommand, 0);

    var out = std.array_list.Managed(PluginCommand).init(allocator);
    errdefer {
        for (out.items) |c| {
            allocator.free(c.name);
            allocator.free(c.description);
        }
        out.deinit();
    }
    for (v.array.items) |item| {
        if (item != .object) continue;
        const name = getString(item.object, "name") orelse continue;
        const description = getString(item.object, "description") orelse "";
        try out.ensureUnusedCapacity(1);
        const dup_name = try allocator.dupe(u8, name);
        errdefer allocator.free(dup_name);
        const dup_description = try allocator.dupe(u8, description);
        out.appendAssumeCapacity(.{
            .name = dup_name,
            .description = dup_description,
        });
    }
    return out.toOwnedSlice();
}

fn runSingle(allocator: std.mem.Allocator, plugin: PluginSpec, ctx: PluginContext) !PluginRunResult {
    const entrypoint = try resolveEntrypoint(allocator, plugin.root_path, plugin.entrypoint);
    defer allocator.free(entrypoint);

    // Build a hardened env map for the plugin child process. Previously
    // we forwarded the entire parent environment via getEnvMap, which
    // leaked every provider API key (ANTHROPIC_API_KEY, OPENAI_API_KEY,
    // GEMINI_API_KEY, ...), the session encryption key, daemon bearer
    // token, and anything else in the operator's shell into untrusted
    // marketplace plugins. The allowlist below covers only the generic
    // shell variables a plugin might need to run; the ZCODE_PLUGIN_*
    // variables are then set explicitly below.
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    const forward_keys = [_][]const u8{
        "PATH", "HOME",   "USER",     "LOGNAME",     "SHELL", "TMPDIR", "TMP", "TEMP",
        "LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES", "TERM",
    };
    for (forward_keys) |key| {
        const value = @import("env.zig").getOwned(allocator, key) catch continue;
        defer allocator.free(value);
        env_map.put(key, value) catch {};
    }

    const permissions = try joinStrings(allocator, plugin.permissions);
    defer allocator.free(permissions);

    // Cap the tool-args payload so a very large LLM-generated argument
    // can't blow past ARG_MAX and make the spawn fail with E2BIG. The
    // caller sees the plugin as "blocked" rather than silently bypassed
    // when that happens, but it's cleaner to truncate up front.
    const tool_args_cap: usize = 16 * 1024;
    const tool_args_slice = if (ctx.tool_args.len > tool_args_cap) ctx.tool_args[0..tool_args_cap] else ctx.tool_args;
    const tool_output_slice = if (ctx.tool_output.len > tool_args_cap) ctx.tool_output[0..tool_args_cap] else ctx.tool_output;

    try env_map.put("ZCODE_PLUGIN_NAME", plugin.name);
    try env_map.put("ZCODE_PLUGIN_VERSION", plugin.version);
    try env_map.put("ZCODE_PLUGIN_SCOPE", scopeName(plugin.scope));
    try env_map.put("ZCODE_PLUGIN_EVENT", eventName(ctx.event));
    try env_map.put("ZCODE_PLUGIN_PERMISSIONS", permissions);
    try env_map.put("ZCODE_CWD", ctx.cwd);
    try env_map.put("ZCODE_TOOL_NAME", ctx.tool_name);
    try env_map.put("ZCODE_TOOL_ARGS", tool_args_slice);
    try env_map.put("ZCODE_TOOL_OUTPUT", tool_output_slice);
    try env_map.put("ZCODE_TOOL_SUCCESS", if (ctx.tool_success) "1" else "0");
    // Phase 8 (compaction-05): expose the compaction trigger ("auto"/"manual",
    // or "compact" for the post-compaction SessionStart) so a hook can branch.
    try env_map.put("ZCODE_TRIGGER", ctx.trigger);

    // CLAUDE_* plugin alias set (PRD #534, hooks-09). Additive alongside
    // ZCODE_PLUGIN_*. CLAUDE_PLUGIN_ROOT is the plugin's install dir;
    // CLAUDE_PLUGIN_DATA is a per-plugin data dir under that root. zcode's
    // PluginSpec has no per-plugin "options" field, so CLAUDE_PLUGIN_OPTION_*
    // has no source to populate from and is omitted (see Task 5 notes).
    const plugin_data = try std.fs.path.join(allocator, &.{ plugin.root_path, "data" });
    defer allocator.free(plugin_data);
    try env_map.put("CLAUDE_PLUGIN_ROOT", plugin.root_path);
    try env_map.put("CLAUDE_PLUGIN_DATA", plugin_data);

    const argv = [_][]const u8{ entrypoint, eventName(ctx.event) };
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
    return .{
        .ran = true,
        .blocked = !(result.term == .exited and result.term.exited == 0),
        .output = output,
    };
}

fn userPluginsRoot(allocator: std.mem.Allocator) ![]u8 {
    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);
    return std.fs.path.join(allocator, &.{ resolved.zcode_home, "plugins" });
}

pub fn resolveEntrypoint(allocator: std.mem.Allocator, root_path: []const u8, entrypoint: []const u8) ![]u8 {
    // Reject absolute paths and traversal to keep plugins contained.
    if (std.fs.path.isAbsolute(entrypoint) or std.mem.indexOf(u8, entrypoint, "..") != null) {
        return error.InvalidPluginEntrypoint;
    }
    return std.fs.path.join(allocator, &.{ root_path, entrypoint });
}

fn parseEvent(raw: []const u8) ?PluginEvent {
    if (std.mem.eql(u8, raw, "pre-tool-use")) return .pre_tool_use;
    if (std.mem.eql(u8, raw, "post-tool-use")) return .post_tool_use;
    if (std.mem.eql(u8, raw, "session-start")) return .session_start;
    if (std.mem.eql(u8, raw, "session-end")) return .session_end;
    if (std.mem.eql(u8, raw, "review-start")) return .review_start;
    if (std.mem.eql(u8, raw, "pre-compact")) return .pre_compact;
    if (std.mem.eql(u8, raw, "post-compact")) return .post_compact;
    return null;
}

fn supportsEvent(plugin: *const PluginSpec, event: PluginEvent) bool {
    for (plugin.events) |candidate| {
        if (candidate == event) return true;
    }
    return false;
}

fn joinStrings(allocator: std.mem.Allocator, values: []const []const u8) ![]u8 {
    if (values.len == 0) return allocator.dupe(u8, "");
    return std.mem.join(allocator, ",", values);
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(rt.io, path, .{}) catch return false;
    return true;
}

const freeStringList = @import("parse_helpers.zig").freeStringSlice;

const testing = std.testing;

test "parse manifest fields" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".zcode/plugins/demo");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/plugins/demo/plugin.json",
        .data =
        \\{
        \\  "name": "demo",
        \\  "version": "1.2.3",
        \\  "description": "demo plugin",
        \\  "entrypoint": "run.sh",
        \\  "compatibility": "zcode-plugin-api/v1",
        \\  "permissions": ["git", "read"],
        \\  "events": ["pre-tool-use", "review-start"],
        \\  "commands": [{"name":"demo.review","description":"Run demo review"}]
        \\}
        ,
    });

    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer allocator.free(cwd);

    const plugins = try list(allocator, cwd);
    defer freeList(allocator, plugins);

    try testing.expectEqual(@as(usize, 1), plugins.len);
    try testing.expectEqualStrings("demo", plugins[0].name);
    try testing.expectEqualStrings("1.2.3", plugins[0].version);
    try testing.expectEqual(@as(usize, 2), plugins[0].events.len);
    try testing.expectEqual(@as(usize, 1), plugins[0].commands.len);
}

test "Task 10: plugin manifest mcpServers -> namespaced ServerConfigs with plugin_source" {
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
        \\  "description": "demo plugin",
        \\  "entrypoint": "run.sh",
        \\  "mcpServers": {
        \\    "fs": { "command": "node", "args": ["server.js"] },
        \\    "api": { "type": "http", "url": "https://api.example.com/mcp" }
        \\  }
        \\}
        ,
    });

    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer allocator.free(cwd);

    const plugins = try list(allocator, cwd);
    defer freeList(allocator, plugins);

    try testing.expectEqual(@as(usize, 1), plugins.len);
    const p = plugins[0];
    try testing.expectEqual(@as(usize, 2), p.mcp_servers.len);

    // Servers are namespaced plugin:<plugin>:<server> and stamped with source.
    const fs = mcp_config_find(p.mcp_servers, "plugin:demo:fs").?;
    try testing.expectEqual(mcp_config.TransportType.stdio, fs.type);
    try testing.expectEqualStrings("node", fs.command.?);
    try testing.expectEqualStrings("demo", fs.plugin_source.?);

    const api = mcp_config_find(p.mcp_servers, "plugin:demo:api").?;
    try testing.expectEqual(mcp_config.TransportType.http, api.type);
    try testing.expectEqualStrings("https://api.example.com/mcp", api.url.?);
    try testing.expectEqualStrings("demo", api.plugin_source.?);
}

fn mcp_config_find(servers: []mcp_config.ServerConfig, name: []const u8) ?*mcp_config.ServerConfig {
    for (servers) |*s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

test "Task 3: compaction plugin events name + parse round-trip" {
    // pre_compact / post_compact map to the hyphenated names and parse back.
    try testing.expectEqualStrings("pre-compact", eventName(.pre_compact));
    try testing.expectEqualStrings("post-compact", eventName(.post_compact));
    try testing.expectEqual(@as(?PluginEvent, .pre_compact), parseEvent("pre-compact"));
    try testing.expectEqual(@as(?PluginEvent, .post_compact), parseEvent("post-compact"));
}

test "renderList reports none when no plugins exist" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const rendered = try renderList(testing.allocator, cwd);
    defer testing.allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "plugins:") != null);
}

// ── Task 5: CLAUDE_PLUGIN_ROOT env var ────────────────────────────

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "Task 5: plugin hook sees CLAUDE_PLUGIN_ROOT set to its install dir" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(home);

    // Pin HOME so userPluginsRoot resolves into the tmp tree. User plugins
    // load as enabled with no trust gate, so we can run one directly.
    const prev_home = @import("env.zig").getOwned(alloc, "HOME") catch null;
    defer if (prev_home) |h| alloc.free(h);
    const prev_xdg = @import("env.zig").getOwned(alloc, "XDG_CONFIG_HOME") catch null;
    defer if (prev_xdg) |x| alloc.free(x);
    {
        const home_z = try alloc.dupeZ(u8, home);
        defer alloc.free(home_z);
        _ = setenv("HOME", home_z, 1);
        _ = unsetenv("XDG_CONFIG_HOME");
    }
    defer {
        if (prev_home) |h| {
            const z = alloc.dupeZ(u8, h) catch null;
            if (z) |zz| {
                _ = setenv("HOME", zz, 1);
                alloc.free(zz);
            }
        } else _ = unsetenv("HOME");
        if (prev_xdg) |x| {
            const z = alloc.dupeZ(u8, x) catch null;
            if (z) |zz| {
                _ = setenv("XDG_CONFIG_HOME", zz, 1);
                alloc.free(zz);
            }
        } else _ = unsetenv("XDG_CONFIG_HOME");
    }
    // Pin zcode_home to {home}/.zcode by making it exist (paths.resolve rule).
    try tmp.dir.createDirPath(rt.io, ".zcode/plugins/envprobe");

    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/plugins/envprobe/plugin.json",
        .data =
        \\{
        \\  "name": "envprobe",
        \\  "version": "1.0.0",
        \\  "description": "probes CLAUDE_PLUGIN_ROOT",
        \\  "entrypoint": "run.sh",
        \\  "compatibility": "zcode-plugin-api/v1",
        \\  "events": ["pre-tool-use"]
        \\}
        ,
    });
    {
        // The entrypoint is executed directly, so it needs the exec bit.
        const script = try tmp.dir.createFile(rt.io, ".zcode/plugins/envprobe/run.sh", .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o755) });
        defer script.close(rt.io);
        try script.writeStreamingAll(rt.io, "#!/bin/sh\necho ROOT=$CLAUDE_PLUGIN_ROOT\n");
    }

    // cwd is a distinct subdir (no workspace plugins there).
    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try @import("test_helpers.zig").tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    const expected_root = try @import("test_helpers.zig").tmpDirPath(alloc, &tmp, ".zcode/plugins/envprobe");
    defer alloc.free(expected_root);

    var result = try run(alloc, .{ .event = .pre_tool_use, .cwd = cwd, .tool_name = "Read", .tool_args = "x" });
    defer result.deinit(alloc);
    try testing.expect(result.ran);
    const expect_line = try std.fmt.allocPrint(alloc, "ROOT={s}", .{expected_root});
    defer alloc.free(expect_line);
    try testing.expect(std.mem.indexOf(u8, result.output, expect_line) != null);
}
