const std = @import("std");
const rt = @import("zcode_runtime");
const std_io = @import("core/std_io.zig");
const display_safe = @import("core/display_safe.zig");

const mcp_client = @import("mcp/client.zig");
const mcp_oauth = @import("mcp/oauth.zig");
const mcp_config = @import("core/mcp_config.zig");
const mcp_policy = @import("core/mcp_policy.zig");

// --- MCP commands ---

/// Validate that `server_name` is registered BEFORE the caller opens a
/// transport or talks to the server. Before this helper, a typo'd
/// server name bubbled up as `error.ServerNotFound` through the agent
/// runtime's generic catch, which surfaced to the user as the
/// confusing `error: ServerNotFound (provider=..., model=...)` line
/// that looked like a provider crash. Each caller translates the
/// returned error into a clean exit via main.zig's switch. Frees its
/// own allocations so the caller stays simple.
pub fn assertMcpServerKnown(
    mcp: *mcp_client.Client,
    server_name: []const u8,
    cmd_name: []const u8,
) !void {
    const servers = try mcp.list();
    defer mcp_client.freeServers(mcp.allocator, servers);
    for (servers) |s| {
        if (std.mem.eql(u8, s.name, server_name)) return;
    }
    try std_io.stderrWriter().print(
        "error: {s}: server '{s}' not found.\n  - Run `zcode mcp list` to see registered servers.\n",
        .{ cmd_name, server_name },
    );
    return error.McpServerNotFound;
}

pub fn cmdMcpList(allocator: std.mem.Allocator, mcp: *mcp_client.Client, writer: anytype) !void {
    const servers = try mcp.list();
    defer mcp_client.freeServers(allocator, servers);

    if (servers.len == 0) {
        try writer.writeAll("no mcp servers\n");
        return;
    }

    for (servers) |server| {
        // A stored server name with an embedded newline (someone
        // hand-edited servers.json with `"name":"line1\nline2"`)
        // used to print as TWO lines, which broke the TSV layout
        // and could fake a second server entry. Escape display-
        // unsafe bytes so the row stays on one line.
        const safe_name = try display_safe.sanitize(allocator, server.name);
        defer allocator.free(safe_name);
        const safe_transport = try display_safe.sanitize(allocator, server.transport);
        defer allocator.free(safe_transport);
        try writer.print("{s}\t{s}\n", .{ safe_name, safe_transport });
    }
}

pub fn cmdMcpTools(allocator: std.mem.Allocator, mcp: *mcp_client.Client, subject: ?[]const u8, writer: anytype) !void {
    const server_name = subject orelse return error.MissingMcpServer;
    try assertMcpServerKnown(mcp, server_name, "mcp tools");
    const tools = try mcp.listTools(server_name);
    defer mcp_client.freeToolInfos(allocator, tools);

    if (tools.len == 0) {
        try writer.print("no MCP tools discovered for {s}\n", .{server_name});
        return;
    }

    for (tools) |tool| {
        // Tool name + description come from a remote MCP server we
        // do NOT trust to omit ANSI escapes / newlines. Sanitize so
        // a malicious server cannot smuggle terminal control bytes
        // into the operator's `mcp tools` output.
        const safe_name = try display_safe.sanitize(allocator, tool.name);
        defer allocator.free(safe_name);
        const safe_desc = try display_safe.sanitize(allocator, tool.description);
        defer allocator.free(safe_desc);
        try writer.print("{s}\t{s}\n", .{ safe_name, safe_desc });
    }
}

pub fn cmdMcpResources(allocator: std.mem.Allocator, mcp: *mcp_client.Client, subject: ?[]const u8, writer: anytype) !void {
    const server_name = subject orelse return error.MissingMcpServer;
    try assertMcpServerKnown(mcp, server_name, "mcp resources");
    const resources = try mcp.listResources(server_name);
    defer mcp_client.freeResourceInfos(allocator, resources);

    if (resources.len == 0) {
        try writer.print("no MCP resources discovered for {s}\n", .{server_name});
        return;
    }

    for (resources) |resource| {
        const safe_uri = try display_safe.sanitize(allocator, resource.uri);
        defer allocator.free(safe_uri);
        const safe_name = try display_safe.sanitize(allocator, resource.name);
        defer allocator.free(safe_name);
        const safe_desc = try display_safe.sanitize(allocator, resource.description);
        defer allocator.free(safe_desc);
        try writer.print("{s}\t{s}\t{s}\n", .{ safe_uri, safe_name, safe_desc });
    }
}

pub fn cmdMcpTemplates(allocator: std.mem.Allocator, mcp: *mcp_client.Client, subject: ?[]const u8, writer: anytype) !void {
    const server_name = subject orelse return error.MissingMcpServer;
    try assertMcpServerKnown(mcp, server_name, "mcp templates");
    const templates = try mcp.listResourceTemplates(server_name);
    defer mcp_client.freeResourceTemplateInfos(allocator, templates);

    if (templates.len == 0) {
        try writer.print("no MCP resource templates discovered for {s}\n", .{server_name});
        return;
    }

    for (templates) |template| {
        const safe_uri = try display_safe.sanitize(allocator, template.uri_template);
        defer allocator.free(safe_uri);
        const safe_name = try display_safe.sanitize(allocator, template.name);
        defer allocator.free(safe_name);
        const safe_desc = try display_safe.sanitize(allocator, template.description);
        defer allocator.free(safe_desc);
        try writer.print("{s}\t{s}\t{s}\n", .{ safe_uri, safe_name, safe_desc });
    }
}

pub fn cmdMcpRead(
    allocator: std.mem.Allocator,
    mcp: *mcp_client.Client,
    subject: ?[]const u8,
    prompt: ?[]const u8,
    writer: anytype,
) !void {
    const server_name = subject orelse return error.MissingMcpServer;
    const uri = prompt orelse return error.MissingToolArg;
    try assertMcpServerKnown(mcp, server_name, "mcp read");
    const contents = try mcp.readResource(server_name, uri);
    defer mcp_client.freeResourceContents(allocator, contents);

    if (contents.len == 0) {
        try writer.print("no MCP resource content returned for {s}\n", .{uri});
        return;
    }

    for (contents, 0..) |content, idx| {
        if (idx > 0) try writer.writeByte('\n');
        try writer.print("uri={s}\tmime={s}\n", .{ content.uri, content.mime_type });
        if (content.text) |text| {
            try writer.print("{s}\n", .{text});
        } else if (content.blob_base64) |blob| {
            try writer.print("<binary {d} bytes base64>\n", .{blob.len});
        } else {
            try writer.writeAll("<empty>\n");
        }
    }
}

pub fn cmdMcpPrompts(allocator: std.mem.Allocator, mcp: *mcp_client.Client, subject: ?[]const u8, writer: anytype) !void {
    const server_name = subject orelse return error.MissingMcpServer;
    try assertMcpServerKnown(mcp, server_name, "mcp prompts");
    const prompts = try mcp.listPrompts(server_name);
    defer mcp_client.freePromptInfos(allocator, prompts);

    if (prompts.len == 0) {
        try writer.print("no MCP prompts discovered for {s}\n", .{server_name});
        return;
    }

    for (prompts) |prompt_info| {
        const safe_name = try display_safe.sanitize(allocator, prompt_info.name);
        defer allocator.free(safe_name);
        const safe_desc = try display_safe.sanitize(allocator, prompt_info.description);
        defer allocator.free(safe_desc);
        try writer.print("{s}\t{s}\n", .{ safe_name, safe_desc });
        for (prompt_info.arguments) |arg| {
            const safe_arg_name = try display_safe.sanitize(allocator, arg.name);
            defer allocator.free(safe_arg_name);
            const safe_arg_desc = try display_safe.sanitize(allocator, arg.description);
            defer allocator.free(safe_arg_desc);
            try writer.print("  - {s}\trequired={}\t{s}\n", .{ safe_arg_name, arg.required, safe_arg_desc });
        }
    }
}

pub fn cmdMcpPrompt(
    allocator: std.mem.Allocator,
    mcp: *mcp_client.Client,
    subject: ?[]const u8,
    prompt: ?[]const u8,
    writer: anytype,
) !void {
    const server_name = subject orelse return error.MissingMcpServer;
    const spec = prompt orelse return error.MissingToolArg;
    const parsed = splitHeadTail(spec);
    if (parsed.head.len == 0) return error.MissingToolArg;
    try assertMcpServerKnown(mcp, server_name, "mcp prompt");

    var result = try mcp.getPrompt(server_name, parsed.head, if (parsed.tail.len > 0) parsed.tail else null);
    defer result.deinit(allocator);

    if (result.description.len > 0) {
        try writer.print("{s}\n", .{result.description});
    }
    for (result.messages) |message| {
        try writer.print("{s}:\n{s}\n", .{ message.role, message.content });
    }
}

pub fn cmdMcpComplete(
    allocator: std.mem.Allocator,
    mcp: *mcp_client.Client,
    subject: ?[]const u8,
    prompt: ?[]const u8,
    writer: anytype,
) !void {
    const server_name = subject orelse return error.MissingMcpServer;
    const spec = prompt orelse return error.MissingToolArg;
    const ref_and_rest = splitHeadTail(spec);
    const arg_and_value = splitHeadTail(ref_and_rest.tail);
    if (ref_and_rest.head.len == 0 or arg_and_value.head.len == 0) return error.MissingToolArg;
    try assertMcpServerKnown(mcp, server_name, "mcp complete");

    var result = try mcp.complete(server_name, ref_and_rest.head, arg_and_value.head, if (arg_and_value.tail.len > 0) arg_and_value.tail else null);
    defer result.deinit(allocator);

    if (result.values.len == 0) {
        try writer.print("no MCP completions returned for {s}\n", .{arg_and_value.head});
        return;
    }

    for (result.values) |value| {
        try writer.print("{s}\n", .{value});
    }
    if (result.total) |total| {
        try writer.print("total={d}\thas_more={}\n", .{ total, result.has_more });
    } else {
        try writer.print("has_more={}\n", .{result.has_more});
    }
}

pub fn cmdMcpSubscribe(mcp: *mcp_client.Client, subject: ?[]const u8, prompt: ?[]const u8, writer: anytype) !void {
    const server_name = subject orelse return error.MissingMcpServer;
    const uri = prompt orelse return error.MissingToolArg;
    try assertMcpServerKnown(mcp, server_name, "mcp subscribe");
    try mcp.subscribeResource(server_name, uri);
    try writer.print("subscribed to MCP resource {s}\n", .{uri});
}

pub fn cmdMcpUnsubscribe(mcp: *mcp_client.Client, subject: ?[]const u8, prompt: ?[]const u8, writer: anytype) !void {
    const server_name = subject orelse return error.MissingMcpServer;
    const uri = prompt orelse return error.MissingToolArg;
    try assertMcpServerKnown(mcp, server_name, "mcp unsubscribe");
    try mcp.unsubscribeResource(server_name, uri);
    try writer.print("unsubscribed from MCP resource {s}\n", .{uri});
}

pub fn cmdMcpLogLevel(mcp: *mcp_client.Client, subject: ?[]const u8, prompt: ?[]const u8, writer: anytype) !void {
    const server_name = subject orelse return error.MissingMcpServer;
    const level = prompt orelse return error.MissingToolArg;
    try assertMcpServerKnown(mcp, server_name, "mcp log-level");
    try mcp.setLoggingLevel(server_name, level);
    try writer.print("set MCP log level for {s} to {s}\n", .{ server_name, level });
}

pub fn cmdMcpNotifications(allocator: std.mem.Allocator, mcp: *mcp_client.Client, subject: ?[]const u8, writer: anytype) !void {
    if (subject) |server_name| {
        // Validate the server is registered before silently printing
        // "no MCP notifications" -- otherwise a typo'd server name
        // looks like a successful query with zero events.
        try assertMcpServerKnown(mcp, server_name, "mcp notifications");
        mcp.flushNotifications(server_name) catch {};
    } else {
        const servers = try mcp.list();
        defer mcp_client.freeServers(allocator, servers);
        for (servers) |server| {
            mcp.flushNotifications(server.name) catch {};
        }
    }

    const notifications = try mcp.takeNotifications(subject);
    defer mcp_client.freeNotificationEvents(allocator, notifications);
    if (notifications.len == 0) {
        try writer.writeAll("no MCP notifications\n");
        return;
    }

    for (notifications) |notification| {
        try writer.print("{s}\t{s}\t{s}\n", .{ notification.server, notification.method, notification.params_json });
    }
}

pub fn cmdMcpAdd(mcp: *mcp_client.Client, subject: ?[]const u8, prompt: ?[]const u8, writer: anytype) !void {
    const name = subject orelse return error.MissingMcpServer;
    const raw = if (prompt) |transport| try std.fmt.allocPrint(mcp.allocator, "{s}={s}", .{ name, transport }) else try mcp.allocator.dupe(u8, name);
    defer mcp.allocator.free(raw);

    const pair = splitNameTransport(raw);

    // Enterprise allow/deny policy (mcp-05). Reject a server blocked by the
    // managed allowlist/denylist BEFORE writing it, mirroring `addMcpConfig`
    // (`config.ts:667-679`). The diagnostic goes to stderr and the command
    // exits non-zero so CI scripts can detect the rejection.
    {
        const cwd = std.process.currentPathAlloc(rt.io, mcp.allocator) catch null;
        defer if (cwd) |c| mcp.allocator.free(c);
        if (cwd) |c| {
            const blocked = checkAddBlocked(mcp.allocator, c, pair.name, pair.transport) catch false;
            if (blocked) {
                try std_io.stderrWriter().print(
                    "error: mcp add: server '{s}' is blocked by enterprise policy.\n  - It is denied or not in the allowed MCP servers list.\n  - Ask an administrator about `allowedMcpServers` / `deniedMcpServers`.\n",
                    .{pair.name},
                );
                return error.McpServerBlockedByPolicy;
            }
        }
    }

    // For local stdio transports (command-line style, not a URL),
    // warn when the first token isn't resolvable on PATH so the user
    // catches typos at registration time rather than at first use
    // ("mcp server failed to start" 30 minutes later). We don't
    // block the add - some workflows register servers before the
    // binary is installed (declarative configs, CI bootstrap).
    if (isLocalStdioTransport(pair.transport)) {
        if (firstCommandToken(pair.transport)) |cmd| {
            if (!commandOnPath(mcp.allocator, cmd)) {
                // Warning goes to stderr, not the primary writer
                // (stdout). Piping `zcode mcp add ... | ...` should
                // never see a "warning:" line mixed into the
                // machine-readable stdout channel.
                std_io.stderrWriter().print(
                    "warning: mcp add: '{s}' is not on PATH right now.\n  - Registered anyway; zcode will attempt to spawn it at first use.\n  - If this is a typo, remove with `zcode mcp remove {s}` and retry.\n",
                    .{ cmd, pair.name },
                ) catch {};
            }
        }
    }

    mcp.add(pair.name, pair.transport) catch |err| switch (err) {
        // Write the diagnostic to stderr and return the error so
        // main.zig can translate to exit 1. Previously the "already
        // exists" line went to stdout and the command exited 0, so
        // CI scripts like `zcode mcp add foo bar || echo fail` could
        // not detect the conflict -- double-registration in an Ansible
        // playbook silently became a no-op.
        error.ServerAlreadyExists => {
            try std_io.stderrWriter().print(
                "error: mcp add: server '{s}' is already registered.\n  - Run `zcode mcp list` to see registered servers.\n  - To replace, run `zcode mcp remove {s}` first.\n",
                .{ pair.name, pair.name },
            );
            return error.ServerAlreadyExists;
        },
        else => return err,
    };
    try writer.print("added mcp server {s}\n", .{pair.name});
}

fn isLocalStdioTransport(transport: []const u8) bool {
    // URL transports are handled by the MCP client over HTTP(S) /
    // WebSocket and don't require a local binary.
    const t = std.mem.trim(u8, transport, " \t\r\n");
    if (t.len == 0) return false;
    if (std.mem.startsWith(u8, t, "http://")) return false;
    if (std.mem.startsWith(u8, t, "https://")) return false;
    if (std.mem.startsWith(u8, t, "ws://")) return false;
    if (std.mem.startsWith(u8, t, "wss://")) return false;
    return true;
}

fn firstCommandToken(transport: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, transport, " \t\r\n");
    if (t.len == 0) return null;
    const end = std.mem.indexOfScalar(u8, t, ' ') orelse t.len;
    return t[0..end];
}

fn commandOnPath(allocator: std.mem.Allocator, cmd: []const u8) bool {
    // Absolute paths: direct access check.
    if (std.fs.path.isAbsolute(cmd)) {
        std.Io.Dir.accessAbsolute(rt.io, cmd, .{ .read = true }) catch return false;
        return true;
    }
    // Otherwise, walk PATH like the shell does. Pure string work -
    // no spawn, no DNS, just file existence checks that settle in
    // microseconds even on a long PATH.
    const path_env = @import("core/env.zig").getOwned(allocator, "PATH") catch return true; // no PATH? assume ok, let spawn fail naturally
    defer allocator.free(path_env);
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = std.fs.path.join(allocator, &.{ dir, cmd }) catch continue;
        defer allocator.free(candidate);
        std.Io.Dir.accessAbsolute(rt.io, candidate, .{ .read = true }) catch continue;
        return true;
    }
    return false;
}

pub fn cmdMcpRemove(mcp: *mcp_client.Client, subject: ?[]const u8, writer: anytype) !void {
    const name = subject orelse return error.MissingMcpServer;
    const removed = try mcp.remove(name);
    if (removed) {
        try writer.print("removed mcp server {s}\n", .{name});
        return;
    }
    // Not-found used to print "mcp server X not found" to stdout
    // and exit 0. That makes `zcode mcp remove X && zcode mcp add X ...`
    // re-add idempotently, but it also means CI scripts can't detect
    // whether the remove actually did anything. Emit the diagnostic
    // to stderr and surface a distinct error tag that main.zig maps
    // to exit 1 - matches `kubectl delete` and `systemctl stop`
    // behavior for absent resources.
    try std_io.stderrWriter().print(
        "error: mcp remove: server '{s}' not found.\n  - Run `zcode mcp list` to see registered servers.\n",
        .{name},
    );
    return error.McpServerNotFound;
}

pub fn cmdMcpTest(allocator: std.mem.Allocator, mcp: *mcp_client.Client, subject: ?[]const u8, writer: anytype) !void {
    const name = subject orelse return error.MissingMcpServer;
    try assertMcpServerKnown(mcp, name, "mcp test");
    const out = try mcp.testServer(name);
    defer allocator.free(out);
    try writer.print("{s}\n", .{out});
}

pub fn cmdMcpAuthLogin(mcp: *mcp_client.Client, subject: ?[]const u8, token: ?[]const u8, writer: anytype) !void {
    const name = subject orelse return error.MissingMcpServer;
    try assertMcpServerKnown(mcp, name, "mcp auth login");
    if (token == null) {
        const transport = try mcp.serverTransport(name);
        defer mcp.allocator.free(transport);
        if (!(std.mem.startsWith(u8, transport, "http://") or std.mem.startsWith(u8, transport, "https://"))) {
            return error.MissingToolArg;
        }

        var outcome = try mcp_oauth.loginForMcpServer(mcp.allocator, transport);
        defer outcome.deinit(mcp.allocator);
        switch (outcome) {
            .success => |result| {
                try mcp.authLoginDetailedWithMetadata(
                    name,
                    result.access_token,
                    "bearer",
                    result.refresh_token,
                    result.expires_ts,
                    "browser-oauth",
                    result.client_id,
                    result.token_endpoint,
                );
                try writer.print("stored MCP OAuth auth for {s}\tcallback={s}\n", .{ name, result.callback_url });
            },
            .provider_error => |failure| {
                try writer.print(
                    "mcp auth failed for {s}\terror={s}\tdescription={s}\tcallback={s}\tauth_url={s}\n",
                    .{
                        name,
                        failure.error_code,
                        failure.description orelse "<none>",
                        failure.callback_url,
                        failure.auth_url,
                    },
                );
                return error.McpOAuthProviderDenied;
            },
        }
        return;
    }

    const value = token.?;
    if (value.len > "oauth:".len and std.mem.startsWith(u8, value, "oauth:")) {
        const spec = std.mem.trim(u8, value["oauth:".len..], " \t");
        var outcome = try mcp_oauth.loginViaBrowser(mcp.allocator, spec);
        defer outcome.deinit(mcp.allocator);
        switch (outcome) {
            .success => |result| {
                try mcp.authLoginDetailed(name, result.access_token, "bearer", result.refresh_token, result.expires_ts, "browser-oauth");
                try writer.print("stored MCP OAuth auth for {s}\tcallback={s}\n", .{ name, result.callback_url });
            },
            .provider_error => |failure| {
                try writer.print(
                    "mcp auth failed for {s}\terror={s}\tdescription={s}\tcallback={s}\tauth_url={s}\n",
                    .{
                        name,
                        failure.error_code,
                        failure.description orelse "<none>",
                        failure.callback_url,
                        failure.auth_url,
                    },
                );
                return error.McpOAuthProviderDenied;
            },
        }
        return;
    }
    try mcp.authLogin(name, value, "bearer");
    try writer.print("stored MCP auth for {s}\n", .{name});
}

pub fn cmdMcpAuthStatus(allocator: std.mem.Allocator, mcp: *mcp_client.Client, subject: ?[]const u8, writer: anytype) !void {
    if (subject) |s| try assertMcpServerKnown(mcp, s, "mcp auth status");
    const statuses = try mcp.authStatus(subject);
    defer mcp_client.freeAuthStatuses(allocator, statuses);

    if (statuses.len == 0) {
        try writer.writeAll("mcp auth: none\n");
        return;
    }

    for (statuses) |entry| {
        // Auth file is hand-editable JSON; sanitize so a hostile
        // entry can't break the TSV row.
        const safe_server = try display_safe.sanitize(allocator, entry.server);
        defer allocator.free(safe_server);
        const safe_scheme = try display_safe.sanitize(allocator, entry.scheme);
        defer allocator.free(safe_scheme);
        const safe_mode = try display_safe.sanitize(allocator, entry.auth_mode);
        defer allocator.free(safe_mode);
        const safe_token = try display_safe.sanitize(allocator, entry.masked_token);
        defer allocator.free(safe_token);
        try writer.print(
            "{s}\tscheme={s}\tauth_mode={s}\trefreshable={}\ttoken={s}\tupdated={d}\texpires={any}\n",
            .{ safe_server, safe_scheme, safe_mode, entry.refreshable, safe_token, entry.updated_ts, entry.expires_ts },
        );
    }
}

pub fn cmdMcpAuthLogout(mcp: *mcp_client.Client, subject: ?[]const u8, writer: anytype) !void {
    const name = subject orelse return error.MissingMcpServer;
    try assertMcpServerKnown(mcp, name, "mcp auth logout");
    const removed = try mcp.authLogout(name);
    if (removed) {
        try writer.print("removed MCP auth for {s}\n", .{name});
    } else {
        try writer.print("no MCP auth stored for {s}\n", .{name});
    }
}

// --- Helpers ---

const NameTransport = struct {
    name: []const u8,
    transport: []const u8,
};

fn splitNameTransport(raw: []const u8) NameTransport {
    if (std.mem.indexOfScalar(u8, raw, '=')) |idx| {
        return .{
            .name = std.mem.trim(u8, raw[0..idx], " \t"),
            .transport = std.mem.trim(u8, raw[idx + 1 ..], " \t"),
        };
    }

    return .{ .name = raw, .transport = "stdio" };
}

/// True when the named server (with the given legacy transport string) is
/// blocked by the enterprise allow/deny policy resolved from settings.json
/// under `cwd`. Returns false (allowed) when no policy restricts it.
///
/// The transport is mapped to a structured `ServerConfig` via the legacy
/// importer (URL -> remote, else stdio with `command = transport`). NOTE: the
/// legacy importer keeps the whole shell string in `command` and does not
/// tokenize args, so a `serverCommand` array policy entry only matches when its
/// single element equals the full transport string; name- and URL-based policy
/// entries match precisely. Exposed for testing with an explicit `cwd`.
pub fn checkAddBlocked(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    name: []const u8,
    transport: []const u8,
) !bool {
    var policy = try mcp_policy.loadPolicy(allocator, cwd);
    defer policy.deinit(allocator);
    // No restrictions at all -> never blocked (fast path).
    if (policy.allowed == null and policy.denied == null) return false;

    var cfg = try mcp_config.legacyServerToConfig(allocator, name, transport, .user);
    defer cfg.deinit(allocator);

    return !(try mcp_policy.isMcpServerAllowedByPolicy(allocator, &policy, &cfg));
}

const HeadTail = struct {
    head: []const u8,
    tail: []const u8,
};

fn splitHeadTail(raw: []const u8) HeadTail {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return .{ .head = "", .tail = "" };
    if (std.mem.indexOfAny(u8, trimmed, " \t")) |idx| {
        return .{
            .head = std.mem.trim(u8, trimmed[0..idx], " \t"),
            .tail = std.mem.trim(u8, trimmed[idx + 1 ..], " \t"),
        };
    }
    return .{ .head = trimmed, .tail = "" };
}

const testing = std.testing;

test "splitNameTransport parses name=transport" {
    const result = splitNameTransport("myserver=http://localhost:3000");
    try testing.expectEqualStrings("myserver", result.name);
    try testing.expectEqualStrings("http://localhost:3000", result.transport);
}

test "splitNameTransport defaults to stdio" {
    const result = splitNameTransport("myserver");
    try testing.expectEqualStrings("myserver", result.name);
    try testing.expectEqualStrings("stdio", result.transport);
}

test "splitHeadTail splits on first space" {
    const result = splitHeadTail("myserver some arg text");
    try testing.expectEqualStrings("myserver", result.head);
    try testing.expectEqualStrings("some arg text", result.tail);
}

test "splitHeadTail handles single word" {
    const result = splitHeadTail("myserver");
    try testing.expectEqualStrings("myserver", result.head);
    try testing.expectEqualStrings("", result.tail);
}

test "splitHeadTail handles empty" {
    const result = splitHeadTail("");
    try testing.expectEqualStrings("", result.head);
    try testing.expectEqualStrings("", result.tail);
}

test "checkAddBlocked: denied server is blocked, others are not" {
    const allocator = testing.allocator;
    const test_helpers = @import("core/test_helpers.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A project-scope allowlist naming both servers plus a denylist naming
    // "bad". The denylist always merges from all sources and wins over the
    // allowlist, so "bad" is blocked while "good" (name-allowed) is permitted.
    // Naming both in the allowlist keeps the test deterministic regardless of
    // any allowlist in the machine's real user settings.
    try tmp.dir.createDirPath(rt.io, ".claude");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".claude/settings.json",
        .data =
        \\{
        \\  "allowedMcpServers": [ { "serverName": "good" }, { "serverName": "bad" } ],
        \\  "deniedMcpServers": [ { "serverName": "bad" } ]
        \\}
        ,
    });

    const cwd = try test_helpers.tmpDirPath(allocator, &tmp, ".");
    defer allocator.free(cwd);

    try testing.expect(try checkAddBlocked(allocator, cwd, "bad", "node server.js"));
    // "good" is name-allowed and not denied.
    try testing.expect(!(try checkAddBlocked(allocator, cwd, "good", "node server.js")));
}
