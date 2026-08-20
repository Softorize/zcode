const std = @import("std");
const rt = @import("zcode_runtime");
const std_io = @import("std_io.zig");
const display_safe = @import("display_safe.zig");
const paths = @import("paths.zig");
const helpers = @import("../tools/helpers.zig");
const parse_helpers_mod = @import("parse_helpers.zig");
const mcp_config = @import("mcp_config.zig");

pub const AgentScope = enum {
    builtin,
    user,
    workspace,
    plugin,
};

pub const AgentMode = enum {
    inherit,
    execution,
    planning,
    brainstorm,
    review,
};

pub const AgentSpec = struct {
    name: []u8,
    description: []u8,
    system_prompt: []u8,
    model: []u8,
    mode: AgentMode,
    tools: [][]u8,
    scope: AgentScope,
    source_path: []u8,
    /// MCP servers declared in the agent definition's `mcpServers` block
    /// (mcp-11). Surfaced into the merged MCP config when this agent is
    /// selected. May be empty. Mirrors `extractAgentMcpServers`
    /// (`services/mcp/utils.ts:466-553`).
    mcp_servers: []mcp_config.ServerConfig,
    /// Tools this agent is explicitly forbidden from using. Subtracts from the
    /// `tools` allow-list and overrides a `*`/all wildcard (swarm-tasks-12).
    /// Mirrors `disallowedTools` in `loadAgentsDir.ts:73-99`.
    disallowed_tools: [][]u8,
    /// Skills to preload into the agent's opening context (swarm-tasks-12).
    /// Stored as skill names; application is wired at spawn.
    skills: [][]u8,
    /// Reasoning-effort override (auto/low/medium/high). Empty means inherit.
    /// The reference accepts either a string or an int; we normalize to a
    /// string and parse it via `types.ReasoningEffort.fromString` at apply
    /// time (swarm-tasks-12).
    effort: []u8,
    /// Permission-mode override (e.g. default/acceptEdits/bypassPermissions).
    /// Empty means inherit (swarm-tasks-12).
    permission_mode: []u8,
    /// Max tool rounds for this agent. null means inherit the session default
    /// (swarm-tasks-12).
    max_turns: ?usize,
    /// Memory scope selecting which CLAUDE.md/memory file the agent loads.
    /// Empty means inherit (swarm-tasks-12).
    memory: []u8,
    /// Raw JSON of the agent's `hooks` block, stored opaque to avoid building a
    /// recursive value tree (swarm-tasks-12). Empty when absent; the hook
    /// registration parses this at spawn.
    hooks_json: []u8,

    pub fn deinit(self: *AgentSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.system_prompt);
        allocator.free(self.model);
        for (self.tools) |tool| allocator.free(tool);
        allocator.free(self.tools);
        allocator.free(self.source_path);
        mcp_config.freeServerConfigs(allocator, self.mcp_servers);
        for (self.disallowed_tools) |t| allocator.free(t);
        allocator.free(self.disallowed_tools);
        for (self.skills) |s| allocator.free(s);
        allocator.free(self.skills);
        allocator.free(self.effort);
        allocator.free(self.permission_mode);
        allocator.free(self.memory);
        allocator.free(self.hooks_json);
    }
};

pub fn freeList(allocator: std.mem.Allocator, agents: []AgentSpec) void {
    for (agents) |*agent| agent.deinit(allocator);
    allocator.free(agents);
}

pub fn clone(allocator: std.mem.Allocator, spec: *const AgentSpec) !AgentSpec {
    const tools = try allocator.alloc([]u8, spec.tools.len);
    var tools_filled: usize = 0;
    errdefer {
        for (tools[0..tools_filled]) |t| allocator.free(t);
        allocator.free(tools);
    }
    for (spec.tools, 0..) |tool, idx| {
        tools[idx] = try allocator.dupe(u8, tool);
        tools_filled = idx + 1;
    }

    const name = try allocator.dupe(u8, spec.name);
    errdefer allocator.free(name);
    const description = try allocator.dupe(u8, spec.description);
    errdefer allocator.free(description);
    const system_prompt = try allocator.dupe(u8, spec.system_prompt);
    errdefer allocator.free(system_prompt);
    const model = try allocator.dupe(u8, spec.model);
    errdefer allocator.free(model);
    const source_path = try allocator.dupe(u8, spec.source_path);
    errdefer allocator.free(source_path);
    const mcp_servers = try mcp_config.cloneServerConfigs(allocator, spec.mcp_servers);
    errdefer mcp_config.freeServerConfigs(allocator, mcp_servers);

    const disallowed_tools = try dupeStringSlice(allocator, spec.disallowed_tools);
    errdefer freeStringSlice(allocator, disallowed_tools);
    const skills = try dupeStringSlice(allocator, spec.skills);
    errdefer freeStringSlice(allocator, skills);
    const effort = try allocator.dupe(u8, spec.effort);
    errdefer allocator.free(effort);
    const permission_mode = try allocator.dupe(u8, spec.permission_mode);
    errdefer allocator.free(permission_mode);
    const memory = try allocator.dupe(u8, spec.memory);
    errdefer allocator.free(memory);
    const hooks_json = try allocator.dupe(u8, spec.hooks_json);
    errdefer allocator.free(hooks_json);

    return .{
        .name = name,
        .description = description,
        .system_prompt = system_prompt,
        .model = model,
        .mode = spec.mode,
        .tools = tools,
        .scope = spec.scope,
        .source_path = source_path,
        .mcp_servers = mcp_servers,
        .disallowed_tools = disallowed_tools,
        .skills = skills,
        .effort = effort,
        .permission_mode = permission_mode,
        .max_turns = spec.max_turns,
        .memory = memory,
        .hooks_json = hooks_json,
    };
}

/// Deep-copy a slice of owned strings. On any failure frees what it allocated.
fn dupeStringSlice(allocator: std.mem.Allocator, src: []const []const u8) ![][]u8 {
    const out = try allocator.alloc([]u8, src.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |s| allocator.free(s);
        allocator.free(out);
    }
    for (src, 0..) |s, idx| {
        out[idx] = try allocator.dupe(u8, s);
        filled = idx + 1;
    }
    return out;
}

fn freeStringSlice(allocator: std.mem.Allocator, slice: [][]u8) void {
    for (slice) |s| allocator.free(s);
    allocator.free(slice);
}

pub fn modeName(mode: AgentMode) []const u8 {
    return switch (mode) {
        .inherit => "inherit",
        .execution => "execution",
        .planning => "planning",
        .brainstorm => "brainstorm",
        .review => "review",
    };
}

pub fn scopeName(scope: AgentScope) []const u8 {
    return switch (scope) {
        .builtin => "builtin",
        .user => "user",
        .workspace => "workspace",
        .plugin => "plugin",
    };
}

pub fn list(allocator: std.mem.Allocator, cwd: []const u8) ![]AgentSpec {
    var out = std.array_list.Managed(AgentSpec).init(allocator);
    errdefer freeList(allocator, out.items);

    try appendBuiltinAgents(allocator, &out);

    const user_dir = try userAgentsDir(allocator);
    defer allocator.free(user_dir);
    try appendFromDir(allocator, &out, user_dir, .user);

    const workspace_dir = try paths.workspacePathAlloc(allocator, cwd, "agents");
    defer allocator.free(workspace_dir);
    try appendFromDir(allocator, &out, workspace_dir, .workspace);

    // Plugin agents: each enabled plugin may ship an agents/ dir under its root
    // (plugins-04). Appended last so a plugin agent overrides a same-named
    // builtin/user/workspace agent via the last-wins `upsert`, mirroring the
    // plugin-skills loader in skills.zig:appendPluginSkills.
    appendPluginAgents(allocator, &out, cwd) catch {};

    std.mem.sort(AgentSpec, out.items, {}, lessThan);
    return out.toOwnedSlice();
}

pub fn findByName(allocator: std.mem.Allocator, cwd: []const u8, raw_name: []const u8) !?AgentSpec {
    const name = std.mem.trim(u8, raw_name, " \t\r\n");
    if (name.len == 0) return null;

    const agents = try list(allocator, cwd);
    defer freeList(allocator, agents);

    for (agents) |agent| {
        if (eqlIgnoreCase(agent.name, name)) {
            return try clone(allocator, &agent);
        }
    }
    return null;
}

pub fn renderList(allocator: std.mem.Allocator, cwd: []const u8, current: ?[]const u8) ![]u8 {
    const agents = try list(allocator, cwd);
    defer freeList(allocator, agents);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    if (current) |name| {
        try out.writer().print("current_agent={s}\n", .{name});
    } else {
        try out.writer().writeAll("current_agent=<none>\n");
    }

    if (agents.len == 0) {
        try out.writer().writeAll("agents: none\n");
        return out.toOwnedSlice();
    }

    try out.writer().writeAll("agents:\n");
    for (agents) |agent| {
        const marker = if (current) |name|
            if (eqlIgnoreCase(name, agent.name)) "*" else "-"
        else
            "-";
        const tools_text = if (allowsAllTools(&agent)) "all" else if (agent.tools.len == 0) "inherit" else "restricted";
        try out.writer().print(
            "{s} {s} ({s}) mode={s} tools={s} [{s}]\n",
            .{ marker, agent.name, scopeName(agent.scope), modeName(agent.mode), tools_text, agent.source_path },
        );
        if (agent.description.len > 0) {
            try out.writer().print("  {s}\n", .{agent.description});
        }
    }

    return out.toOwnedSlice();
}

pub fn renderDetail(allocator: std.mem.Allocator, cwd: []const u8, raw_name: []const u8) ![]u8 {
    var agent = (try findByName(allocator, cwd, raw_name)) orelse return allocator.dupe(u8, "agent not found");
    defer agent.deinit(allocator);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    try out.writer().print("name={s}\n", .{agent.name});
    try out.writer().print("scope={s}\n", .{scopeName(agent.scope)});
    try out.writer().print("mode={s}\n", .{modeName(agent.mode)});
    try out.writer().print("model={s}\n", .{if (agent.model.len > 0) agent.model else "<inherit>"});
    try out.writer().print("source={s}\n", .{agent.source_path});
    if (agent.tools.len == 0 or allowsAllTools(&agent)) {
        try out.writer().print("tools={s}\n", .{if (allowsAllTools(&agent)) "all" else "<inherit>"});
    } else {
        try out.writer().writeAll("tools:\n");
        for (agent.tools) |tool| {
            try out.writer().print("- {s}\n", .{tool});
        }
    }
    if (agent.description.len > 0) {
        // Description is free-form text from a user-authored JSON
        // file. A newline / ANSI escape would corrupt the
        // key=value display block on `agents show`. Escape on
        // display so the row stays parseable.
        const safe = try display_safe.sanitize(allocator, agent.description);
        defer allocator.free(safe);
        try out.writer().print("description={s}\n", .{safe});
    }
    try out.writer().writeAll("\nsystem_prompt:\n");
    try out.writer().writeAll(agent.system_prompt);
    if (!std.mem.endsWith(u8, agent.system_prompt, "\n")) try out.writer().writeByte('\n');

    return out.toOwnedSlice();
}

pub fn allowsAllTools(agent: *const AgentSpec) bool {
    if (agent.tools.len == 0) return false;
    for (agent.tools) |tool| {
        if (std.mem.eql(u8, tool, "*") or eqlIgnoreCase(tool, "all")) return true;
    }
    return false;
}

pub fn allowsTool(agent: *const AgentSpec, tool_name: []const u8) bool {
    // A disallow entry overrides everything, including a `*`/all wildcard in
    // `tools` (swarm-tasks-12). Mirrors the reference subtracting
    // `disallowedTools` from the effective allow-set.
    for (agent.disallowed_tools) |tool| {
        if (eqlIgnoreCase(tool, tool_name)) return false;
    }
    if (agent.tools.len == 0 or allowsAllTools(agent)) return true;
    for (agent.tools) |tool| {
        if (eqlIgnoreCase(tool, tool_name)) return true;
    }
    return false;
}

fn appendFromDir(
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed(AgentSpec),
    root: []const u8,
    scope: AgentScope,
) !void {
    var dir = std.Io.Dir.cwd().openDir(rt.io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        error.NotDir => return,
        error.AccessDenied => return,
        else => return err,
    };
    defer dir.close(rt.io);

    var it = dir.iterate();
    while (try it.next(rt.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const path = try std.fs.path.join(allocator, &.{ root, entry.name });
        defer allocator.free(path);

        const agent = try loadFile(allocator, path, scope);
        try upsert(out, allocator, agent);
    }
}

/// Load agent definitions from every enabled plugin's `agents/` subdirectory
/// (plugins-04). Direct analog of `skills.zig:appendPluginSkills`: iterate the
/// installed plugins, skip the disabled ones, join `<root>/agents`, and reuse
/// the existing `appendFromDir` machinery (which tolerates a missing dir). Each
/// agent loaded here is stamped with the `.plugin` scope so `agents show`
/// reveals it came from a plugin. Failures are swallowed so one broken plugin
/// cannot wedge the whole agents list (mirrors the `catch {}` in skills.zig).
fn appendPluginAgents(
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed(AgentSpec),
    cwd: []const u8,
) !void {
    const plugins_mod = @import("plugins.zig");
    const plugin_list = try plugins_mod.list(allocator, cwd);
    defer plugins_mod.freeList(allocator, plugin_list);
    for (plugin_list) |plugin| {
        if (!plugin.enabled) continue;
        const agents_dir = std.fs.path.join(allocator, &.{ plugin.root_path, "agents" }) catch continue;
        defer allocator.free(agents_dir);
        appendFromDir(allocator, out, agents_dir, .plugin) catch continue;
    }
}

const BuiltinAgentTemplate = struct {
    name: []const u8,
    description: []const u8,
    system_prompt: []const u8,
    model: []const u8 = "",
    mode: AgentMode = .inherit,
    tools: []const []const u8 = &.{},
};

const builtin_agent_templates = [_]BuiltinAgentTemplate{
    .{
        .name = "explore",
        .description = "Read-only codebase investigation. Use for: finding patterns across files, tracing call chains, gathering evidence. Do NOT use for: making changes, running tests, or tasks requiring mutation.",
        .system_prompt =
        \\You are the explore specialist.
        \\Your job is to investigate the codebase efficiently and return grounded findings.
        \\Prefer read-only tools. Do not mutate files or propose speculative answers.
        \\Cite files, functions, and concrete evidence. End with the smallest set of actionable conclusions.
        ,
        .mode = .execution,
        .tools = &.{ "Read", "file_read", "Glob", "Grep", "GitDiff", "GitLog", "git_status", "WebFetch", "WebSearch", "JsonQuery", "TodoRead" },
    },
    .{
        .name = "plan",
        .description = "Planning specialist for design and implementation strategy. Use for: breaking tasks into steps, identifying risks, creating checklists. Do NOT use for: executing code changes or running tests.",
        .system_prompt =
        \\You are the plan specialist.
        \\Break work into a short, concrete checklist with assumptions, risks, and definition of done.
        \\Prefer read-only inspection. Do not perform repository mutations.
        \\If the task is already well-scoped, keep the plan compact and execution-ready.
        ,
        .mode = .planning,
        .tools = &.{ "Read", "file_read", "Glob", "Grep", "GitDiff", "GitLog", "git_status", "TodoRead", "TodoWrite" },
    },
    .{
        .name = "verify",
        .description = "Verification specialist for tests and validation. Use for: running tests, checking build status, confirming changes work. Do NOT use for: exploration or making additional code changes.",
        .system_prompt =
        \\You are the verify specialist.
        \\Your job is to validate work before completion claims.
        \\Prefer tests, diffs, status checks, and build commands. Report concrete pass/fail results or the exact blocker that prevented verification.
        \\Do not make unrelated code changes.
        ,
        .mode = .execution,
        .tools = &.{ "RunTests", "GitDiff", "git_status", "Read", "Grep", "Glob", "Bash", "shell", "TaskPoll", "TaskOutput", "TodoRead", "TodoWrite" },
    },
    .{
        .name = "reviewer",
        .description = "Code review specialist focused on correctness. Use for: reviewing diffs for bugs, regressions, missing tests, security issues. Do NOT use for: making fixes or running tests.",
        .system_prompt =
        \\You are the reviewer specialist.
        \\Review changes like a strict code reviewer.
        \\Prioritize correctness issues, risky assumptions, missing tests, and regressions.
        \\Findings come first, ordered by severity, with file references and concrete reasoning.
        ,
        .mode = .review,
        .tools = &.{ "Read", "file_read", "Glob", "Grep", "GitDiff", "GitLog", "git_status", "TodoRead" },
    },
};

fn appendBuiltinAgents(allocator: std.mem.Allocator, out: *std.array_list.Managed(AgentSpec)) !void {
    for (builtin_agent_templates) |template| {
        try upsert(out, allocator, try buildBuiltinAgent(allocator, template));
    }
}

fn buildBuiltinAgent(allocator: std.mem.Allocator, template: BuiltinAgentTemplate) !AgentSpec {
    // Stage each allocation into a local with its own errdefer so a failure
    // mid-construction frees every successfully-allocated field instead of
    // silently leaking it. Previously an OOM in the trailing `source_path`
    // allocPrint would leak name/description/system_prompt/model/tools.
    const tools = try allocator.alloc([]u8, template.tools.len);
    var tools_filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < tools_filled) : (i += 1) allocator.free(tools[i]);
        allocator.free(tools);
    }
    for (template.tools, 0..) |tool, idx| {
        tools[idx] = try allocator.dupe(u8, tool);
        tools_filled = idx + 1;
    }

    const name = try allocator.dupe(u8, template.name);
    errdefer allocator.free(name);
    const description = try allocator.dupe(u8, template.description);
    errdefer allocator.free(description);
    const system_prompt = try allocator.dupe(u8, template.system_prompt);
    errdefer allocator.free(system_prompt);
    const model = try allocator.dupe(u8, template.model);
    errdefer allocator.free(model);
    const source_path = try std.fmt.allocPrint(allocator, "<builtin:{s}>", .{template.name});

    return .{
        .name = name,
        .description = description,
        .system_prompt = system_prompt,
        .model = model,
        .mode = template.mode,
        .tools = tools,
        .scope = .builtin,
        .source_path = source_path,
        .mcp_servers = &.{},
        .disallowed_tools = &.{},
        .skills = &.{},
        .effort = try allocator.dupe(u8, ""),
        .permission_mode = try allocator.dupe(u8, ""),
        .max_turns = null,
        .memory = try allocator.dupe(u8, ""),
        .hooks_json = try allocator.dupe(u8, ""),
    };
}

fn upsert(out: *std.array_list.Managed(AgentSpec), allocator: std.mem.Allocator, incoming: AgentSpec) !void {
    for (out.items, 0..) |*existing, idx| {
        if (eqlIgnoreCase(existing.name, incoming.name)) {
            existing.deinit(allocator);
            out.items[idx] = incoming;
            return;
        }
    }
    // Take ownership on success; on append failure (OOM) free the
    // incoming spec so the caller's `try upsert(...)` doesn't leak it.
    out.append(incoming) catch |err| {
        var tmp = incoming;
        tmp.deinit(allocator);
        return err;
    };
}

fn loadFile(allocator: std.mem.Allocator, path: []const u8, scope: AgentScope) !AgentSpec {
    const data = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(data);

    // Strip a possible UTF-8 BOM so a config file authored in
    // PowerShell 5.x or notepad parses cleanly. Without this the
    // first byte (0xEF) makes std.json reject the file with a
    // SyntaxError, even though the JSON content is otherwise valid.
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, parse_helpers_mod.stripBom(data), .{}) catch |err| switch (err) {
        // A malformed agent definition used to leak
        // `error.SyntaxError (provider=..., model=...)` through the
        // agent-runtime envelope on `zcode agents list`. Name the
        // offending file and return a distinct error tag so callers
        // can translate to a clean exit.
        error.SyntaxError, error.UnexpectedToken, error.InvalidCharacter, error.UnexpectedEndOfInput => {
            std_io.stderrWriter().print(
                "error: agents: invalid JSON in agent definition ({s}): {s}\n  - Fix the file's JSON or remove it.\n",
                .{ @errorName(err), path },
            ) catch {};
            return error.InvalidAgentDefinition;
        },
        else => return err,
    };
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidAgentDefinition;
    const obj = parsed.value.object;

    const name = getString(obj, "name") orelse return error.InvalidAgentDefinition;
    if (!helpers.isSafeIdentifier(name)) return error.InvalidAgentDefinition;
    const system_prompt = getString(obj, "system_prompt") orelse getString(obj, "prompt") orelse return error.InvalidAgentDefinition;
    if (std.mem.trim(u8, system_prompt, " \t\r\n").len == 0) return error.InvalidAgentDefinition;

    return .{
        .name = try allocator.dupe(u8, name),
        .description = try allocator.dupe(u8, getString(obj, "description") orelse ""),
        .system_prompt = try allocator.dupe(u8, system_prompt),
        .model = try allocator.dupe(u8, getString(obj, "model") orelse ""),
        .mode = parseMode(getString(obj, "mode") orelse ""),
        .tools = try parseTools(allocator, obj.get("tools")),
        .scope = scope,
        .source_path = try allocator.dupe(u8, path),
        .mcp_servers = try parseAgentMcpServers(allocator, obj.get("mcpServers")),
        .disallowed_tools = try parseTools(allocator, obj.get("disallowedTools")),
        .skills = try parseTools(allocator, obj.get("skills")),
        .effort = try parseEffort(allocator, obj.get("effort")),
        .permission_mode = try allocator.dupe(u8, getString(obj, "permissionMode") orelse ""),
        .max_turns = parseMaxTurns(obj.get("maxTurns")),
        .memory = try allocator.dupe(u8, getString(obj, "memory") orelse ""),
        .hooks_json = try parseHooksJson(allocator, obj.get("hooks")),
    };
}

/// Parse the `effort` field, which the reference accepts as either a string
/// ("low"/"medium"/"high") or an integer. Normalize to a string; an integer is
/// stringified verbatim so `types.ReasoningEffort.fromString` can interpret it
/// at apply time. Missing/other types yield empty (inherit).
fn parseEffort(allocator: std.mem.Allocator, value: ?std.json.Value) ![]u8 {
    const v = value orelse return allocator.dupe(u8, "");
    return switch (v) {
        .string => |s| allocator.dupe(u8, s),
        .integer => |n| std.fmt.allocPrint(allocator, "{d}", .{n}),
        else => allocator.dupe(u8, ""),
    };
}

/// Parse the `maxTurns` integer. Non-positive or non-integer yields null
/// (inherit the session default).
fn parseMaxTurns(value: ?std.json.Value) ?usize {
    const v = value orelse return null;
    return switch (v) {
        .integer => |n| if (n > 0) @intCast(n) else null,
        else => null,
    };
}

/// Stash the `hooks` block as an opaque JSON string (object or array) so we do
/// not deep-clone a value tree (swarm-tasks-12 footgun). Missing/other types
/// yield empty.
fn parseHooksJson(allocator: std.mem.Allocator, value: ?std.json.Value) ![]u8 {
    const v = value orelse return allocator.dupe(u8, "");
    switch (v) {
        .object, .array => {},
        else => return allocator.dupe(u8, ""),
    }
    var body = std_io.StringBuilder.init(allocator);
    defer body.deinit();
    try std.json.Stringify.value(v, .{}, body.writer());
    return allocator.dupe(u8, body.items());
}

/// Parse an agent definition's `mcpServers` object into structured
/// `ServerConfig`s (mcp-11). The agent-frontmatter servers are tagged with the
/// `dynamic` scope (they are not project/user/local config-file servers) and
/// run through the same canonical parser as project servers. A missing or
/// malformed block yields an empty slice. Mirrors `extractAgentMcpServers`
/// (`services/mcp/utils.ts:466-553`).
fn parseAgentMcpServers(
    allocator: std.mem.Allocator,
    value: ?std.json.Value,
) ![]mcp_config.ServerConfig {
    const v = value orelse return &.{};
    if (v != .object) return &.{};

    // Re-serialize the `mcpServers` object back into a `.mcp.json`-shaped body
    // and reuse the canonical parser so agent servers get identical validation.
    var body = std_io.StringBuilder.init(allocator);
    defer body.deinit();
    try body.writer().writeAll("{\"mcpServers\":");
    try std.json.Stringify.value(v, .{}, body.writer());
    try body.writer().writeByte('}');

    var result = try mcp_config.parseMcpJson(allocator, body.items(), .dynamic, false);
    // Move the parsed servers out; deinitErrorsOnly frees only errors + backing.
    defer result.deinitErrorsOnly(allocator);
    const out = result.servers;
    result.servers = &.{};
    return out;
}

fn parseTools(allocator: std.mem.Allocator, value: ?std.json.Value) ![][]u8 {
    const v = value orelse return allocator.alloc([]u8, 0);
    if (v != .array) return error.InvalidAgentDefinition;

    const out = try allocator.alloc([]u8, v.array.items.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |item| allocator.free(item);
        allocator.free(out);
    }

    for (v.array.items, 0..) |item, idx| {
        if (item != .string) return error.InvalidAgentDefinition;
        out[idx] = try allocator.dupe(u8, item.string);
        initialized += 1;
    }
    return out;
}

fn parseMode(raw: []const u8) AgentMode {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return .inherit;
    if (eqlIgnoreCase(trimmed, "execution")) return .execution;
    if (eqlIgnoreCase(trimmed, "planning")) return .planning;
    if (eqlIgnoreCase(trimmed, "brainstorm")) return .brainstorm;
    if (eqlIgnoreCase(trimmed, "review")) return .review;
    return .inherit;
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn userAgentsDir(allocator: std.mem.Allocator) ![]u8 {
    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);
    return std.fs.path.join(allocator, &.{ resolved.zcode_home, "agents" });
}

fn lessThan(_: void, a: AgentSpec, b: AgentSpec) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

const eqlIgnoreCase = @import("parse_helpers.zig").eqlIgnoreCase;

const testing = std.testing;

test "loadFile parses agent json" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "reviewer.json",
        .data =
        \\{
        \\  "name": "reviewer",
        \\  "description": "Review changes for bugs",
        \\  "prompt": "Focus on regressions and missing tests.",
        \\  "model": "anthropic/claude-sonnet-4-5",
        \\  "mode": "review",
        \\  "tools": ["GitDiff", "Grep", "Read"]
        \\}
        ,
    });

    const path = try @import("test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "reviewer.json");
    defer testing.allocator.free(path);

    var agent = try loadFile(testing.allocator, path, .workspace);
    defer agent.deinit(testing.allocator);

    try testing.expectEqualStrings("reviewer", agent.name);
    try testing.expectEqualStrings("Review changes for bugs", agent.description);
    try testing.expectEqualStrings("Focus on regressions and missing tests.", agent.system_prompt);
    try testing.expect(agent.mode == .review);
    try testing.expectEqual(@as(usize, 3), agent.tools.len);
}

test "Task 10: agent definition mcpServers surfaces ServerConfigs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "scout.json",
        .data =
        \\{
        \\  "name": "scout",
        \\  "prompt": "investigate",
        \\  "mcpServers": {
        \\    "search": { "command": "node", "args": ["search.js"] },
        \\    "docs": { "type": "http", "url": "https://docs.example.com/mcp" }
        \\  }
        \\}
        ,
    });

    const path = try @import("test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "scout.json");
    defer testing.allocator.free(path);

    var agent = try loadFile(testing.allocator, path, .workspace);
    defer agent.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), agent.mcp_servers.len);

    var saw_search = false;
    var saw_docs = false;
    for (agent.mcp_servers) |s| {
        if (std.mem.eql(u8, s.name, "search")) {
            try testing.expectEqual(mcp_config.TransportType.stdio, s.type);
            try testing.expectEqualStrings("node", s.command.?);
            saw_search = true;
        }
        if (std.mem.eql(u8, s.name, "docs")) {
            try testing.expectEqual(mcp_config.TransportType.http, s.type);
            try testing.expectEqualStrings("https://docs.example.com/mcp", s.url.?);
            saw_docs = true;
        }
    }
    try testing.expect(saw_search and saw_docs);

    // clone must deep-copy the mcp_servers (no double-free / no aliasing).
    var copy = try clone(testing.allocator, &agent);
    defer copy.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), copy.mcp_servers.len);
}

test "Task 12: rich frontmatter parses into a fully populated AgentSpec" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "rich.json",
        .data =
        \\{
        \\  "name": "rich",
        \\  "prompt": "do the thing",
        \\  "tools": ["*"],
        \\  "disallowedTools": ["Write", "Bash"],
        \\  "skills": ["tdd", "diagnose"],
        \\  "effort": "high",
        \\  "permissionMode": "acceptEdits",
        \\  "maxTurns": 7,
        \\  "memory": "project",
        \\  "mcpServers": {
        \\    "search": { "command": "node", "args": ["s.js"] }
        \\  },
        \\  "hooks": { "SubagentStop": [{ "command": "echo done" }] }
        \\}
        ,
    });

    const path = try @import("test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "rich.json");
    defer testing.allocator.free(path);

    var agent = try loadFile(testing.allocator, path, .workspace);
    defer agent.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), agent.disallowed_tools.len);
    try testing.expectEqualStrings("Write", agent.disallowed_tools[0]);
    try testing.expectEqualStrings("Bash", agent.disallowed_tools[1]);

    try testing.expectEqual(@as(usize, 2), agent.skills.len);
    try testing.expectEqualStrings("tdd", agent.skills[0]);
    try testing.expectEqualStrings("diagnose", agent.skills[1]);

    try testing.expectEqualStrings("high", agent.effort);
    try testing.expectEqualStrings("acceptEdits", agent.permission_mode);
    try testing.expectEqual(@as(?usize, 7), agent.max_turns);
    try testing.expectEqualStrings("project", agent.memory);
    try testing.expectEqual(@as(usize, 1), agent.mcp_servers.len);
    try testing.expect(agent.hooks_json.len > 0);
    try testing.expect(std.mem.indexOf(u8, agent.hooks_json, "SubagentStop") != null);

    // effort accepted as an integer too (reference accepts string or int).
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "inteffort.json",
        .data =
        \\{ "name": "ie", "prompt": "x", "effort": 2, "maxTurns": 0 }
        ,
    });
    const p2 = try @import("test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "inteffort.json");
    defer testing.allocator.free(p2);
    var a2 = try loadFile(testing.allocator, p2, .workspace);
    defer a2.deinit(testing.allocator);
    try testing.expectEqualStrings("2", a2.effort);
    // maxTurns of 0 normalizes to null (inherit).
    try testing.expectEqual(@as(?usize, null), a2.max_turns);

    // Minimal agent files (no new fields) still parse with empty defaults.
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "minimal.json",
        .data =
        \\{ "name": "minimal", "prompt": "x" }
        ,
    });
    const p3 = try @import("test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "minimal.json");
    defer testing.allocator.free(p3);
    var a3 = try loadFile(testing.allocator, p3, .workspace);
    defer a3.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), a3.disallowed_tools.len);
    try testing.expectEqual(@as(usize, 0), a3.skills.len);
    try testing.expectEqualStrings("", a3.effort);
    try testing.expectEqualStrings("", a3.permission_mode);
    try testing.expectEqual(@as(?usize, null), a3.max_turns);
    try testing.expectEqualStrings("", a3.memory);
    try testing.expectEqualStrings("", a3.hooks_json);
}

test "Task 12: disallowedTools overrides a wildcard tools allow-list" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "wild.json",
        .data =
        \\{ "name": "wild", "prompt": "x", "tools": ["*"], "disallowedTools": ["Write"] }
        ,
    });

    const path = try @import("test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "wild.json");
    defer testing.allocator.free(path);

    var agent = try loadFile(testing.allocator, path, .workspace);
    defer agent.deinit(testing.allocator);

    // `*` grants everything except the explicitly disallowed tool.
    try testing.expect(allowsTool(&agent, "Read"));
    try testing.expect(allowsTool(&agent, "GitDiff"));
    try testing.expect(!allowsTool(&agent, "Write"));
    // Case-insensitive disallow match.
    try testing.expect(!allowsTool(&agent, "write"));

    // clone must deep-copy the new fields (no double free / aliasing).
    var copy = try clone(testing.allocator, &agent);
    defer copy.deinit(testing.allocator);
    try testing.expect(!allowsTool(&copy, "Write"));
    try testing.expectEqual(@as(usize, 1), copy.disallowed_tools.len);
}

test "allowsTool honors explicit allow list" {
    var tools = try testing.allocator.alloc([]u8, 2);
    tools[0] = try testing.allocator.dupe(u8, "GitDiff");
    tools[1] = try testing.allocator.dupe(u8, "Read");

    var agent = AgentSpec{
        .name = try testing.allocator.dupe(u8, "reviewer"),
        .description = try testing.allocator.dupe(u8, ""),
        .system_prompt = try testing.allocator.dupe(u8, "prompt"),
        .model = try testing.allocator.dupe(u8, ""),
        .mode = .review,
        .tools = tools,
        .scope = .workspace,
        .source_path = try testing.allocator.dupe(u8, "x"),
        .mcp_servers = &.{},
        .disallowed_tools = &.{},
        .skills = &.{},
        .effort = try testing.allocator.dupe(u8, ""),
        .permission_mode = try testing.allocator.dupe(u8, ""),
        .max_turns = null,
        .memory = try testing.allocator.dupe(u8, ""),
        .hooks_json = try testing.allocator.dupe(u8, ""),
    };
    defer agent.deinit(testing.allocator);

    try testing.expect(allowsTool(&agent, "GitDiff"));
    try testing.expect(!allowsTool(&agent, "Write"));
}

test "findByName resolves builtin agents" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    var agent = (try findByName(testing.allocator, cwd, "explore")) orelse return error.MissingBuiltinAgent;
    defer agent.deinit(testing.allocator);

    try testing.expectEqual(agent.scope, .builtin);
    try testing.expectEqual(agent.mode, .execution);
    try testing.expect(allowsTool(&agent, "Read"));
    try testing.expect(!allowsTool(&agent, "Write"));
}

// ── Task 17.4: plugin-provided agents (plugins-04) ────────────────

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

// Pin HOME (and clear XDG_CONFIG_HOME) so paths.resolve / userPluginsRoot
// resolve into the tmp tree, making a tmp user-scope plugin loadable. Mirrors
// the HOME-pinning helper in plugins.zig / plugin_settings.zig tests. The
// zcode_home becomes <home>/.zcode.
const PluginAgentsHomeRestore = struct {
    prev_home: ?[]u8,
    prev_xdg: ?[]u8,

    fn deinit(self: PluginAgentsHomeRestore, allocator: std.mem.Allocator) void {
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

fn pinPluginAgentsHome(allocator: std.mem.Allocator, home: []const u8) !PluginAgentsHomeRestore {
    const env = @import("env.zig");
    const prev_home = env.getOwned(allocator, "HOME") catch null;
    const prev_xdg = env.getOwned(allocator, "XDG_CONFIG_HOME") catch null;
    const home_z = try allocator.dupeZ(u8, home);
    defer allocator.free(home_z);
    _ = setenv("HOME", home_z, 1);
    _ = unsetenv("XDG_CONFIG_HOME");
    return .{ .prev_home = prev_home, .prev_xdg = prev_xdg };
}

fn agentInList(agents: []AgentSpec, name: []const u8) ?*AgentSpec {
    for (agents) |*a| {
        if (eqlIgnoreCase(a.name, name)) return a;
    }
    return null;
}

test "Task 17.4: enabled plugin agents/ dir surfaces with plugin scope" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A user-scope plugin (loaded enabled by default, no trust gate) shipping
    // agents/reviewer.json. HOME is the tmp root so userPluginsRoot resolves to
    // <root>/.zcode/plugins; cwd is a distinct subdir so the plugin is NOT also
    // discovered as a workspace plugin.
    try tmp.dir.createDirPath(rt.io, ".zcode/plugins/pluga/agents");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/plugins/pluga/plugin.json",
        .data =
        \\{ "name": "pluga", "version": "1.0.0", "description": "d", "entrypoint": "run.sh" }
        ,
    });
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/plugins/pluga/agents/reviewer.json",
        .data =
        \\{ "name": "reviewer_plug", "prompt": "review from a plugin", "mode": "review" }
        ,
    });

    const home = try @import("test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(home);
    const restore = try pinPluginAgentsHome(allocator, home);
    defer restore.deinit(allocator);

    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try @import("test_helpers.zig").tmpDirPath(allocator, &tmp, "proj");
    defer allocator.free(cwd);

    const agents = try list(allocator, cwd);
    defer freeList(allocator, agents);

    const found = agentInList(agents, "reviewer_plug") orelse return error.MissingPluginAgent;
    try testing.expectEqual(AgentScope.plugin, found.scope);
    try testing.expectEqual(AgentMode.review, found.mode);
}

test "Task 17.4: disabled plugin agents are absent from list" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A workspace-scope plugin in an untrusted tmp loads disabled by default
    // (trust_default = false), so its agents must not appear. The plugin ships
    // an agents/ dir to prove it is the disabled gate, not a missing dir, that
    // suppresses it.
    try tmp.dir.createDirPath(rt.io, ".zcode/plugins/plugb/agents");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/plugins/plugb/plugin.json",
        .data =
        \\{ "name": "plugb", "version": "1.0.0", "description": "d", "entrypoint": "run.sh" }
        ,
    });
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/plugins/plugb/agents/ghost.json",
        .data =
        \\{ "name": "ghost_agent", "prompt": "should not appear" }
        ,
    });

    const cwd = try @import("test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    // Sanity: the plugin is present but disabled.
    {
        const plugins_mod = @import("plugins.zig");
        const plist = try plugins_mod.list(allocator, cwd);
        defer plugins_mod.freeList(allocator, plist);
        try testing.expectEqual(@as(usize, 1), plist.len);
        try testing.expect(!plist[0].enabled);
    }

    const agents = try list(allocator, cwd);
    defer freeList(allocator, agents);

    try testing.expect(agentInList(agents, "ghost_agent") == null);
}

test "Task 17.4: plugin agent colliding with a builtin does not crash and the plugin wins" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // An enabled user-scope plugin ships agents/reviewer.json named "reviewer",
    // which collides with the builtin "reviewer". Plugin agents are appended
    // last, so the last-wins upsert means the plugin definition wins (scope
    // becomes .plugin). The list must not crash or duplicate the name.
    try tmp.dir.createDirPath(rt.io, ".zcode/plugins/plugc/agents");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/plugins/plugc/plugin.json",
        .data =
        \\{ "name": "plugc", "version": "1.0.0", "description": "d", "entrypoint": "run.sh" }
        ,
    });
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/plugins/plugc/agents/reviewer.json",
        .data =
        \\{ "name": "reviewer", "prompt": "plugin-provided reviewer override", "mode": "review" }
        ,
    });

    const home = try @import("test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(home);
    const restore = try pinPluginAgentsHome(allocator, home);
    defer restore.deinit(allocator);

    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try @import("test_helpers.zig").tmpDirPath(allocator, &tmp, "proj");
    defer allocator.free(cwd);

    const agents = try list(allocator, cwd);
    defer freeList(allocator, agents);

    // Exactly one "reviewer" entry (no duplication on collision).
    var count: usize = 0;
    for (agents) |a| {
        if (eqlIgnoreCase(a.name, "reviewer")) count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);

    const found = agentInList(agents, "reviewer") orelse return error.MissingReviewer;
    try testing.expectEqual(AgentScope.plugin, found.scope);
    try testing.expectEqualStrings("plugin-provided reviewer override", found.system_prompt);
}
