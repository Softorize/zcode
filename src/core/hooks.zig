const std = @import("std");
const std_io = @import("std_io.zig");
const rt = @import("zcode_runtime");
const paths = @import("paths.zig");
const security = @import("security.zig");
const display_safe = @import("display_safe.zig");
const clock = @import("clock.zig");
const hook_config = @import("hook_config.zig");
const hook_matcher = @import("hook_matcher.zig");
const hook_io = @import("hook_io.zig");
const hook_event = @import("hook_event.zig");
const settings_sources = @import("settings_sources.zig");
const session_env = @import("session_env.zig");
const hook_exec_prompt = @import("hook_exec_prompt.zig");
const hook_exec_http = @import("hook_exec_http.zig");
const async_hook_registry = @import("async_hook_registry.zig");
const hooks_snapshot = @import("hooks_snapshot.zig");
const session_hooks = @import("session_hooks.zig");
const hook_events = @import("hook_events.zig");
const plugin_hooks = @import("plugin_hooks.zig");

/// The live dispatch layer now routes every lifecycle event through the full
/// reference event set (`hook_event.Event`) rather than the old 3-variant enum.
/// Only the 3 tool events have an on-disk `.sh` file form; all other events
/// dispatch purely via settings.json hooks (see `filenameForEvent` / `list`).
pub const HookEvent = hook_event.Event;

/// Task 8 (hooks-08): default command-hook execution timeout (ms). Mirrors the
/// reference `TOOL_HOOK_EXECUTION_TIMEOUT_MS` (utils/hooks.ts:877-879), which is
/// 10 minutes. Applied when a command/file hook does not pin its own `timeout`.
/// The prompt/agent/http defaults live next to their executors
/// (hook_exec_prompt.PROMPT_TIMEOUT_MS / AGENT_TIMEOUT_MS,
/// hook_exec_http.HTTP_TIMEOUT_MS); `computeTimeoutMs` selects per type.
pub const COMMAND_HOOK_TIMEOUT_MS: u64 = 600_000;

/// Resolve the effective execution timeout (ms) for a hook. A non-null
/// `timeout_s` (the parsed `timeout` field, in seconds) always overrides; with
/// none, the per-type default applies: command/file = 10 min, prompt = 30s,
/// agent = 60s, http = 10 min. Pure helper so the per-type defaults are
/// unit-testable without spawning anything.
pub fn computeTimeoutMs(hook_type: hook_config.HookType, timeout_s: ?u32) u64 {
    if (timeout_s) |s| return @as(u64, s) * 1000;
    return switch (hook_type) {
        .command => COMMAND_HOOK_TIMEOUT_MS,
        .prompt => hook_exec_prompt.PROMPT_TIMEOUT_MS,
        .agent => hook_exec_prompt.AGENT_TIMEOUT_MS,
        .http => hook_exec_http.HTTP_TIMEOUT_MS,
    };
}

pub const HookScope = enum {
    user,
    workspace,
    project,
    local,
    policy,
};

pub const HookSpec = struct {
    event: HookEvent,
    scope: HookScope,
    path: []u8,

    pub fn deinit(self: *HookSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const HookContext = struct {
    event: HookEvent,
    cwd: []const u8,
    tool_name: []const u8 = "",
    tool_args: []const u8 = "",
    tool_output: []const u8 = "",
    tool_success: bool = false,
    // Non-tool lifecycle discriminating fields (Task 3). Each event uses only
    // the field(s) that apply: SessionStart -> source; UserPromptSubmit ->
    // prompt; Notification -> message/title; PreCompact -> trigger; SessionEnd
    // -> reason. They also drive matcher selection for non-tool events: the
    // first non-empty field below is the value matched against `def.matcher`.
    source: []const u8 = "",
    prompt: []const u8 = "",
    message: []const u8 = "",
    title: []const u8 = "",
    trigger: []const u8 = "",
    reason: []const u8 = "",
    // TaskCreated / TaskCompleted (swarm-tasks-15). The task id and subject are
    // carried so a TaskCreated hook can inspect the freshly-created task and
    // veto it (exit 2 -> block, which deletes the task). They are emitted on the
    // payload as `task_id`/`task_subject`; the matcher tests against the subject.
    task_id: []const u8 = "",
    task_subject: []const u8 = "",
};

/// True for the 3 tool events that have an on-disk `.sh` file form and a
/// `tool_name`/`tool_args` payload. Everything else is a non-tool lifecycle
/// event that dispatches purely via settings.json and matches on a single
/// discriminating field instead of a tool name.
fn isToolEvent(event: HookEvent) bool {
    return switch (event) {
        .pre_tool_use, .post_tool_use, .post_tool_use_failure => true,
        else => false,
    };
}

/// The single field value a non-tool event's `matcher` is tested against
/// (`hook_matcher.matchesField`). SessionStart matches its `source`,
/// UserPromptSubmit its `prompt`, Notification its `message`, PreCompact its
/// `trigger`, SessionEnd its `reason`. Events without a meaningful
/// discriminator return "" (which `matchesField` treats as "match unless the
/// matcher is a concrete value").
fn matchFieldFor(ctx: HookContext) []const u8 {
    return switch (ctx.event) {
        .session_start => ctx.source,
        .user_prompt_submit => ctx.prompt,
        .notification => ctx.message,
        .pre_compact => ctx.trigger,
        .session_end => ctx.reason,
        // TaskCreated / TaskCompleted match against the task subject so a hook
        // can scope itself with a matcher (swarm-tasks-15).
        .task_created, .task_completed => ctx.task_subject,
        else => "",
    };
}

/// Build the per-event stdin payload. Tool events use the tool builder;
/// non-tool events use the lifecycle builder, emitting only their relevant
/// discriminating field(s).
fn buildEventPayload(allocator: std.mem.Allocator, ctx: HookContext) ![]u8 {
    const name = hook_event.canonicalName(ctx.event);
    if (isToolEvent(ctx.event)) {
        // PostToolUse / PostToolUseFailure carry the tool's response on stdin so
        // hooks can inspect it (reference: hooks.ts:3465 `tool_response`). PreToolUse
        // has no response yet, so pass null (no `tool_response` field emitted).
        const response: ?[]const u8 = switch (ctx.event) {
            .post_tool_use, .post_tool_use_failure => ctx.tool_output,
            else => null,
        };
        return hook_io.buildToolEventPayloadFull(allocator, name, ctx.tool_name, ctx.tool_args, ctx.cwd, response, ctx.tool_success);
    }
    var fields: hook_io.LifecycleFields = .{};
    switch (ctx.event) {
        .session_start => fields.source = nonEmptyOrNull(ctx.source),
        .user_prompt_submit => fields.prompt = nonEmptyOrNull(ctx.prompt),
        .notification => {
            fields.message = nonEmptyOrNull(ctx.message);
            fields.title = nonEmptyOrNull(ctx.title);
        },
        .pre_compact => fields.trigger = nonEmptyOrNull(ctx.trigger),
        .session_end => fields.reason = nonEmptyOrNull(ctx.reason),
        .task_created, .task_completed => {
            fields.task_id = nonEmptyOrNull(ctx.task_id);
            fields.task_subject = nonEmptyOrNull(ctx.task_subject);
        },
        else => {},
    }
    return hook_io.buildLifecycleEventPayload(allocator, name, ctx.cwd, fields);
}

fn nonEmptyOrNull(s: []const u8) ?[]const u8 {
    return if (s.len == 0) null else s;
}

/// Permission outcome surfaced from a hook's `hookSpecificOutput.permissionDecision`
/// (hooks-20). `.deny` is the only one the runtime currently blocks on; `.allow`
/// and `.ask` are carried here for the Task 9 permission-engine wiring.
pub const HookPermission = enum { none, allow, deny, ask };

pub const HookRunResult = struct {
    ran: bool,
    blocked: bool,
    output: []u8,
    trust_path: ?[]u8 = null,
    // hooks-04: the full stdout sync contract, surfaced to consumers. All owned
    // slices are duped onto `allocator` and freed in deinit.
    continue_run: ?bool = null,
    suppress_output: bool = false,
    stop_reason: ?[]u8 = null,
    system_message: ?[]u8 = null,
    additional_context: ?[]u8 = null,
    updated_input: ?[]u8 = null,
    permission: HookPermission = .none,
    permission_reason: ?[]u8 = null,
    retry: bool = false,

    pub fn deinit(self: *HookRunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        if (self.trust_path) |value| allocator.free(value);
        if (self.stop_reason) |value| allocator.free(value);
        if (self.system_message) |value| allocator.free(value);
        if (self.additional_context) |value| allocator.free(value);
        if (self.updated_input) |value| allocator.free(value);
        if (self.permission_reason) |value| allocator.free(value);
    }
};

/// Map a parsed `hook_io.PermissionDecision` to the result-facing enum.
fn mapPermission(pd: hook_io.PermissionDecision) HookPermission {
    return switch (pd) {
        .allow => .allow,
        .deny => .deny,
        .ask => .ask,
        .none => .none,
    };
}

/// Dupe an optional borrowed slice onto `allocator`, propagating OOM.
fn dupeOpt(allocator: std.mem.Allocator, s: ?[]const u8) !?[]u8 {
    return if (s) |v| try allocator.dupe(u8, v) else null;
}

pub fn freeList(allocator: std.mem.Allocator, hooks: []HookSpec) void {
    for (hooks) |*hook| hook.deinit(allocator);
    allocator.free(hooks);
}

/// Kebab-case event name used for the `ZCODE_HOOK_EVENT` env var on file
/// hooks. The 3 tool events keep their historical kebab spelling (they have
/// `.sh` file forms); every other event falls back to its canonical
/// PascalCase name (those events have no file form, so the kebab spelling is
/// never read by an on-disk hook).
pub fn eventName(event: HookEvent) []const u8 {
    return switch (event) {
        .pre_tool_use => "pre-tool-use",
        .post_tool_use => "post-tool-use",
        .post_tool_use_failure => "post-tool-use-failure",
        else => hook_event.canonicalName(event),
    };
}

pub fn scopeName(scope: HookScope) []const u8 {
    return switch (scope) {
        .user => "user",
        .workspace => "workspace",
        .project => "project",
        .local => "local",
        .policy => "policy",
    };
}

pub fn list(allocator: std.mem.Allocator, cwd: []const u8) ![]HookSpec {
    var out = std.array_list.Managed(HookSpec).init(allocator);
    errdefer freeList(allocator, out.items);

    inline for ([_]HookEvent{ .pre_tool_use, .post_tool_use, .post_tool_use_failure }) |event| {
        const path = try userHookPath(allocator, event);
        defer allocator.free(path);
        if (pathExists(path)) {
            try out.ensureUnusedCapacity(1);
            const dup_path = try allocator.dupe(u8, path);
            out.appendAssumeCapacity(.{
                .event = event,
                .scope = .user,
                .path = dup_path,
            });
        }

        const workspace_path = try workspaceHookPath(allocator, cwd, event);
        defer allocator.free(workspace_path);
        if (pathExists(workspace_path)) {
            try out.ensureUnusedCapacity(1);
            const dup_workspace_path = try allocator.dupe(u8, workspace_path);
            out.appendAssumeCapacity(.{
                .event = event,
                .scope = .workspace,
                .path = dup_workspace_path,
            });
        }
    }

    return out.toOwnedSlice();
}

pub fn renderList(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const hooks = try list(allocator, cwd);
    defer freeList(allocator, hooks);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    if (hooks.len == 0) {
        try out.writer().writeAll("hooks: none\n");
        return out.toOwnedSlice();
    }

    try out.writer().writeAll("hooks:\n");
    for (hooks) |hook| {
        // Defense-in-depth: hook.path is filesystem-derived; on
        // POSIX a path can legally contain newlines, which would
        // corrupt the single-line list row.
        const safe_path = try display_safe.sanitize(allocator, hook.path);
        defer allocator.free(safe_path);
        try out.writer().print("- {s} ({s}) [{s}]\n", .{ eventName(hook.event), scopeName(hook.scope), safe_path });
    }
    return out.toOwnedSlice();
}

/// Event-agnostic entry point for firing a lifecycle hook (Task 3). Tool events
/// keep the on-disk `.sh` file scan plus the settings.json path; non-tool
/// lifecycle events (SessionStart, UserPromptSubmit, Stop, SessionEnd,
/// PreCompact, PostCompact, Notification, SubagentStart/Stop, ...) have no file
/// form and dispatch purely through settings.json. Callers at lifecycle points
/// build a `HookContext` with the event's discriminating fields and act on the
/// returned result (block / additional context) per the stdout JSON contract.
pub fn runEvent(allocator: std.mem.Allocator, ctx: HookContext) !HookRunResult {
    return run(allocator, ctx);
}

/// Outcome of a `TaskCreated` hook gate (swarm-tasks-15). `blocked` is true when
/// a configured TaskCreated hook returned a blocking error (exit 2 or a
/// `decision:"block"` stdout); `message` is the owned block reason (empty when
/// not blocked). The reference deletes the just-created task on a blocking error
/// and surfaces the hook's message (TaskCreateTool.ts:92-113). The caller owns
/// `message`.
pub const TaskCreatedResult = struct {
    blocked: bool,
    message: []u8,

    pub fn deinit(self: *TaskCreatedResult, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
    }
};

/// Fire the `TaskCreated` lifecycle hook for a freshly-written task and report
/// whether a hook vetoed it. Mirrors the reference `executeTaskCreatedHooks`
/// (TaskCreateTool.ts:92-113): the hook sees the fully-formed task (id +
/// subject), and an exit-2 / `decision:"block"` outcome blocks creation so the
/// caller can delete the task. The TaskCreated event is blocking-capable
/// (`hook_event.isBlockingCapable`), so the existing dispatch already encodes the
/// exit-2 -> block contract; this is a thin task-specific wrapper. With no
/// configured hook the result is `{ blocked = false, message = "" }`.
pub fn runTaskCreatedHook(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    task_id: []const u8,
    task_subject: []const u8,
) !TaskCreatedResult {
    var result = try run(allocator, .{
        .event = .task_created,
        .cwd = cwd,
        .task_id = task_id,
        .task_subject = task_subject,
    });
    defer result.deinit(allocator);

    if (!result.blocked) return .{ .blocked = false, .message = try allocator.dupe(u8, "") };

    // Prefer the structured stop_reason (a prompt/http/command contract reason);
    // otherwise fall back to whatever the hook wrote on stdout.
    const reason = result.stop_reason orelse result.output;
    return .{ .blocked = true, .message = try allocator.dupe(u8, reason) };
}

pub fn run(allocator: std.mem.Allocator, ctx: HookContext) !HookRunResult {
    const hooks = try list(allocator, ctx.cwd);
    defer freeList(allocator, hooks);

    var last_output = try allocator.dupe(u8, "");
    errdefer allocator.free(last_output);
    var ran = false;

    for (hooks) |hook| {
        if (hook.event != ctx.event) continue;
        if (hook.scope == .workspace and !(try security.isHookTrusted(allocator, ctx.cwd, hook.path, scopeName(hook.scope)))) {
            return .{
                .ran = false,
                .blocked = true,
                .output = try security.untrustedHookMessage(allocator, ctx.cwd, hook.path),
                .trust_path = try allocator.dupe(u8, hook.path),
            };
        }
        ran = true;
        var result = try runSingle(allocator, hook.path, ctx);
        defer result.deinit(allocator);

        const next_output = try allocator.dupe(u8, result.output);
        allocator.free(last_output);
        last_output = next_output;

        if (result.blocked) {
            return .{
                .ran = true,
                .blocked = true,
                .output = last_output,
            };
        }
    }

    // plugins-02: fold in enabled-plugin manifest hooks for this event. Plugins
    // are just another hook source merged into the engine (no separate runner);
    // the matchers are re-collected each dispatch, so a disabled/uninstalled
    // plugin drops out immediately. A plugin hook that blocks short-circuits the
    // turn exactly like a file/settings hook. Errors degrade to "no plugin hook
    // ran" so a broken plugin manifest cannot crash the event. The hardened
    // env-map allowlist (no provider API keys) lives in plugin_hooks.runSingle.
    {
        var plugin_res = plugin_hooks.runForEvent(allocator, .{
            .event = ctx.event,
            .cwd = ctx.cwd,
            .tool_name = ctx.tool_name,
            .tool_args = ctx.tool_args,
            .tool_output = ctx.tool_output,
            .tool_success = ctx.tool_success,
            .match_field = matchFieldFor(ctx),
        }) catch plugin_hooks.RunResult{ .ran = false, .blocked = false, .output = try allocator.dupe(u8, "") };
        defer plugin_res.deinit(allocator);
        if (plugin_res.ran) {
            ran = true;
            allocator.free(last_output);
            last_output = try allocator.dupe(u8, plugin_res.output);
            if (plugin_res.blocked) {
                return .{ .ran = true, .blocked = true, .output = last_output };
            }
        }
    }

    // Also run settings.json command hooks via the JSON contract, merged across
    // the user/project/local/policy sources (Task 4). The managed-only and
    // disable-all gates are applied inside runConfiguredFromSources.
    var configured = runConfiguredFromSources(allocator, ctx) catch HookRunResult{ .ran = false, .blocked = false, .output = try allocator.dupe(u8, "") };
    if (configured.ran) {
        // The configured result owns the full stdout-contract surface
        // (stop_reason / system_message / additional_context / updated_input /
        // permission / ...), so hand it back wholesale rather than copying only
        // `.output` (which would drop and leak the extra fields). When the
        // configured run produced no stdout of its own, keep the file-hook
        // `last_output` (the prior behavior) instead of an empty string.
        if (configured.output.len == 0) {
            allocator.free(configured.output);
            configured.output = last_output;
        } else {
            allocator.free(last_output);
        }
        return configured;
    }
    configured.deinit(allocator);

    return .{
        .ran = ran,
        .blocked = false,
        .output = last_output,
    };
}

fn notRanResult(allocator: std.mem.Allocator) HookRunResult {
    return .{ .ran = false, .blocked = false, .output = allocator.dupe(u8, "") catch "" };
}

/// Map a settings source (Task 1) to a hook scope. The user source keeps the
/// historical user-home stance; project/local come from the workspace and are
/// untrusted; policy is enterprise-managed and trusted.
fn scopeForSource(source: settings_sources.Source) HookScope {
    return switch (source) {
        .user => .user,
        .project => .project,
        .local => .local,
        .policy => .policy,
        // The --settings flag is supplied by the operator on the command line,
        // so treat it as a trusted source like the user's own home.
        .flag => .user,
    };
}

/// Run settings.json command hooks for the event via the Claude Code JSON
/// contract (PRD #534 P3), merged across the user/project/local/policy/flag
/// sources (Task 4). The payload is delivered on the hook's stdin through a
/// shell redirect from a temp file (avoids pipe-pump deadlocks).
///
/// Gates (applied before any hook runs), mirroring the reference
/// `getHooksFromAllowedSources` (hooksConfigSnapshot.ts:18-53):
///   - policy `disableAllHooks: true`        -> run nothing.
///   - policy `allowManagedHooksOnly: true`  -> keep only policy-scope hooks.
///   - any non-policy `disableAllHooks: true`-> keep only policy-scope hooks.
///   - else                                  -> run all (merged).
///
/// Trust gating: project/local hooks come from the workspace and are untrusted
/// code, so they go through `security.isHookTrusted` keyed on the settings.json
/// file path. User/flag/policy sources are trusted (own home / operator flag /
/// managed). Errors on any single source degrade to "did not run" for that
/// source - a missing or broken source never crashes startup.
fn runConfiguredFromSources(allocator: std.mem.Allocator, ctx: HookContext) !HookRunResult {
    var resolved = paths.resolve(allocator) catch return notRanResult(allocator);
    defer resolved.deinit(allocator);

    // ── Resolve the policy gate from the startup snapshot (Task 14) ────────
    // The gate (disableAllHooks / allowManagedHooksOnly /
    // strictPluginOnlyCustomization / non-policy disableAllHooks) is captured
    // once at session start so a mid-session settings edit does not change hook
    // behavior until an explicit `/hooks` refresh. `get()` lazily captures on
    // first call. `disable_all` short-circuits every hook; `policy_scope_only`
    // restricts the surviving scopes to the policy (managed) source.
    const gate = hooks_snapshot.get(allocator, ctx.cwd);
    if (gate.disable_all) return notRanResult(allocator);
    const policy_scope_only = gate.policy_scope_only;

    var ran = false;
    var last_output = try allocator.dupe(u8, "");
    errdefer allocator.free(last_output);

    // Task 13 (hooks-19): dedup identical hooks within a source context so a
    // duplicate entry runs only once. The key is `<shell|bash>\0<body>\0<if>`
    // (reference utils/hooks.ts:1735-1756 keys on shell\0command\0if; settings
    // hooks share the empty plugin-root prefix, so the key is just the content).
    // The key strings borrow from the per-source `cfg` defs, so this map must be
    // cleared between sources (a def's backing memory is freed when its `cfg`
    // deinits). Keying on borrowed slices is safe because we only consult the map
    // within a single source's inner loop before its `cfg` is dropped, but we
    // still own the duped key bytes so the map outlives nothing accidentally.
    var dedup = std.StringHashMap(void).init(allocator);
    defer {
        var it = dedup.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        dedup.deinit();
    }

    // ── Iterate every disk source in override order (Task 1) ───────────────
    for (settings_sources.sourceOrder()) |source| {
        const scope = scopeForSource(source);
        if (policy_scope_only and scope != .policy) continue;

        const path = (settings_sources.sourcePath(allocator, ctx.cwd, source, null) catch null) orelse continue;
        defer allocator.free(path);

        const data = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(256 * 1024)) catch continue;
        defer allocator.free(data);

        var cfg = hook_config.parse(allocator, data) catch continue;
        defer cfg.deinit();

        // Trust gate for workspace-derived sources. The settings.json file
        // itself is the trust unit (its command strings are the executed code).
        if (scope == .project or scope == .local) {
            const trusted = security.isHookTrusted(allocator, ctx.cwd, path, scopeName(scope)) catch false;
            if (!trusted) continue;
        }

        for (cfg.defs) |def| {
            // `path` lets a disk-source `once:true` hook self-remove from its
            // settings.json after running. Session hooks (below) pass null.
            if (try processDef(allocator, ctx, def, path, resolved.zcode_home, &dedup, &ran, &last_output)) |early| {
                return early;
            }
        }
    }

    // Task 15 (hooks-13): merge session-scoped / frontmatter / skill hooks. They
    // augment the disk-source hooks for the lifetime of the session (agent/skill
    // frontmatter loaders register them). They share the same dedup map and the
    // same per-def dispatch (matcher / `if` / type / timeout / async / contract).
    // Session hooks have no backing settings file, so `once`-removal is a no-op
    // (path = null). Their strings are owned by the registry arena, so the
    // borrowed-slice contract holds for the duration of this call.
    for (session_hooks.instance.all()) |def| {
        if (try processDef(allocator, ctx, def, null, resolved.zcode_home, &dedup, &ran, &last_output)) |early| {
            return early;
        }
    }

    return .{ .ran = ran, .blocked = false, .output = last_output };
}

/// Process a single hook def for the current event. Returns a non-null
/// `HookRunResult` when this def produced a short-circuiting outcome the caller
/// must return immediately (a block, a contract signal, or a prompt/http
/// additionalContext); returns null when the def was skipped or ran without a
/// short-circuit so the caller should continue to the next def. `ran` and
/// `last_output` are threaded by pointer so the running aggregate state matches
/// the original inline loop exactly.
///
/// `path` is the source settings.json path for disk-source hooks (used by
/// `once`-removal) or null for session-registered hooks (no file to rewrite).
fn processDef(
    allocator: std.mem.Allocator,
    ctx: HookContext,
    def: hook_config.HookDef,
    path: ?[]const u8,
    zcode_home: []const u8,
    dedup: *std.StringHashMap(void),
    ran: *bool,
    last_output: *[]u8,
) !?HookRunResult {
    const engine_event = ctx.event;
    const tool_event = isToolEvent(engine_event);

    if (def.event != engine_event) return null;

    // Task 13 (hooks-19): collapse identical hooks. Two defs with the
    // same shell + body + `if` are duplicates and must run only once.
    // The key is built once and inserted on first sight; a repeat hit
    // skips the def before any matcher/exec work. `dedupSeen` owns the
    // duped key bytes so a later source's freed `cfg` cannot dangle them.
    if (try dedupSeen(allocator, dedup, def)) return null;

    // Tool events match on tool name + serialized input; non-tool
    // lifecycle events match on their single discriminating field.
    if (tool_event) {
        if (!hook_matcher.matchesTool(def.matcher, ctx.tool_name, ctx.tool_args)) return null;
    } else {
        if (!hook_matcher.matchesField(def.matcher, matchFieldFor(ctx))) return null;
    }

    // hooks-05: the `if` permission-rule pre-filter is a second, finer
    // gate applied after `matcher`. For tool events it must match the
    // call (`Tool(content)`); a non-empty `if` on a non-tool event
    // cannot be evaluated, so the hook is skipped
    // (utils/hooks.ts:1835-1840).
    if (tool_event) {
        if (!hook_matcher.matchesIf(def.if_cond, ctx.tool_name, ctx.tool_args)) return null;
    } else if (std.mem.trim(u8, def.if_cond, " \t").len > 0) {
        return null;
    }

    const payload = buildEventPayload(allocator, ctx) catch return null;
    defer allocator.free(payload);

    // Task 13 (hooks-07): a `once:true` hook is removed from its source
    // settings.json after it runs. We are committed to running it now
    // (matcher + `if` + dedup all passed and a payload was built), so
    // self-remove the entry before dispatch. Removing at this point
    // (rather than threading it through every early return below) is
    // equivalent: each `run()` re-reads the file fresh, so the next
    // event will not see the removed entry. The rewrite is conservative
    // (exact-match only) and atomic (temp + rename); a parse/write
    // failure leaves the file untouched and is otherwise a no-op.
    // Session hooks have no backing file (path == null), so `once` is a no-op.
    if (def.once) {
        if (path) |p| removeOnceHook(allocator, p, engine_event, def) catch {};
    }

    // Task 6 (hooks-02): dispatch by hook type. command runs locally;
    // prompt/agent query an LLM with the payload as `$ARGUMENTS`; http
    // is wired in Task 7 (skipped here, so a settings.json http hook is
    // a no-op rather than a crash until that task lands).
    switch (def.hook_type) {
        .command => {},
        .prompt, .agent => {
            ran.* = true;
            var outcome = (if (def.hook_type == .agent)
                hook_exec_prompt.runAgentHook(allocator, def, payload)
            else
                hook_exec_prompt.runPromptHook(allocator, def, payload)) catch return null;
            defer outcome.deinit(allocator);

            // A prompt/agent verifier returning ok:false blocks the event
            // with its reason (reference: outcome 'blocking',
            // preventContinuation, stopReason). A non-blocking error just
            // continues to the next hook.
            if (outcome.blocked) {
                const reason = outcome.reason orelse "";
                allocator.free(last_output.*);
                last_output.* = try allocator.dupe(u8, reason);
                return .{
                    .ran = true,
                    .blocked = true,
                    .output = last_output.*,
                    .stop_reason = try dupeOpt(allocator, reason),
                };
            }
            return null;
        },
        .http => {
            // Task 7 (hooks-15): POST the payload to the hook URL, gated
            // by the allowlist + SSRF guard + env-var header
            // interpolation. SessionStart/Setup http hooks are skipped to
            // avoid the reference deadlock guard (utils/hooks.ts:1850).
            if (engine_event == .session_start or engine_event == .setup) return null;
            ran.* = true;
            const allowlist = hook_exec_http.readAllowlist(allocator, ctx.cwd);
            defer hook_exec_http.freeAllowlist(allowlist, allocator);
            var outcome = hook_exec_http.runHttpHook(allocator, def, payload, allowlist) catch return null;
            defer outcome.deinit(allocator);

            // A response that blocks (decision:block or permission deny)
            // short-circuits the event with its reason; an injected
            // additionalContext (or a non-blocking error) just continues.
            if (outcome.blocked) {
                const reason = outcome.reason orelse "";
                allocator.free(last_output.*);
                last_output.* = try allocator.dupe(u8, reason);
                return .{
                    .ran = true,
                    .blocked = true,
                    .output = last_output.*,
                    .stop_reason = try dupeOpt(allocator, reason),
                };
            }
            if (outcome.additional_context) |ac| {
                allocator.free(last_output.*);
                last_output.* = try allocator.dupe(u8, "");
                return .{
                    .ran = true,
                    .blocked = false,
                    .output = last_output.*,
                    .additional_context = try dupeOpt(allocator, ac),
                };
            }
            return null;
        },
    }

    ran.* = true;

    // Task 16 (hooks-18): show the hook's `statusMessage` in the spinner while it
    // runs. A no-op when the hook sets no message or no spinner is installed.
    hook_events.instance.emitStatus(def.status_message);

    // Task 16 (hooks-14): a stable-ish id correlating this run's started/response
    // pair. The hook "name" is its body (command), matching the reference, which
    // uses the command string as the hookName.
    var id_buf: [24]u8 = undefined;
    const hook_id = std.fmt.bufPrint(&id_buf, "{x}", .{clock.nowNanos()}) catch "hook";

    // Task 12 (hooks-06): a command hook flagged `async` / `asyncRewake`
    // runs in the background. Spawn it, hand the child to the pending
    // registry, and return immediately as ran-but-not-blocked so the turn
    // is never stalled (reference utils/hooks.ts:995). The agent loop
    // later drains finished background hooks via
    // async_hook_registry.checkResponses. A spawn failure degrades to
    // "skip this hook" rather than crashing the turn.
    if (def.is_async or def.async_rewake) {
        spawnAsyncCommand(allocator, def, ctx.cwd, zcode_home, payload, engine_event) catch {};
        return null;
    }

    // Task 16 (hooks-14): broadcast the start of a synchronous command hook so a
    // transcript/SDK consumer can render it. Gated inside the emitter by the
    // always-emit set + the SDK toggle.
    hook_events.instance.emitStarted(engine_event, hook_id, def.body);

    // Task 8: per-hook timeout. `def.timeout_s` (the parsed `timeout`,
    // in seconds) overrides the command default; on expiry the hook is a
    // non-blocking error (continue to the next hook), matching the
    // reference's cancelled/abort outcome.
    const cmd_timeout_ms = computeTimeoutMs(def.hook_type, def.timeout_s);
    const run_res = runCommandWithStdin(allocator, def.body, ctx.cwd, zcode_home, payload, engine_event, cmd_timeout_ms) catch return null;
    defer allocator.free(run_res.stdout);
    if (run_res.timed_out) {
        // Task 16: a timed-out hook reports a `cancelled` response (reference
        // outcome 'cancelled'), so a consumer sees the run end rather than hang.
        hook_events.instance.emitResponse(engine_event, hook_id, def.body, "", "", null, .cancelled);
        return null;
    }

    var parsed = hook_io.parseOutput(allocator, run_res.stdout);
    defer parsed.deinit();

    const text = parsed.output.additional_context orelse parsed.output.reason orelse std.mem.trim(u8, run_res.stdout, " \t\r\n");
    allocator.free(last_output.*);
    last_output.* = try allocator.dupe(u8, text);

    // hooks-04: honor the full sync contract. `decision == "block"`
    // blocks even at exit 0 (the reference treats it independent of exit
    // code); a deny permissionDecision and an exit-2 disposition also
    // block. continue:false / suppressOutput / systemMessage /
    // additionalContext / updatedInput / permission are carried up so
    // the caller can act on them.
    const disp = hook_event.interpretExit(engine_event, run_res.exit_code);
    const decision_block = if (parsed.output.decision) |d| std.ascii.eqlIgnoreCase(d, "block") else false;
    const blocked = disp == .block or parsed.output.permission_decision == .deny or decision_block;

    // Task 16 (hooks-14): broadcast the finished run with the parsed exit code.
    // A blocking outcome is reported as `error`; otherwise `success`. Emitted
    // once here so both the contract-signal early return and the plain
    // fall-through below see a single response event.
    hook_events.instance.emitResponse(engine_event, hook_id, def.body, run_res.stdout, "", run_res.exit_code, if (blocked) .@"error" else .success);

    // A blocking hook short-circuits; a non-blocking hook that carried
    // any contract signal (continue:false, suppressOutput, a permission
    // decision, an injected context/message, updated input, retry)
    // also returns immediately so the caller sees those fields rather
    // than having them overwritten by a later hook's plainer result.
    const has_signal = blocked or
        (parsed.output.continue_run orelse true) == false or
        (parsed.output.suppress_output orelse false) or
        parsed.output.permission_decision != .none or
        parsed.output.additional_context != null or
        parsed.output.system_message != null or
        parsed.output.updated_input != null or
        (parsed.output.retry orelse false);

    if (has_signal) {
        return .{
            .ran = true,
            .blocked = blocked,
            .output = last_output.*,
            .continue_run = parsed.output.continue_run,
            .suppress_output = parsed.output.suppress_output orelse false,
            .stop_reason = try dupeOpt(allocator, parsed.output.stop_reason orelse parsed.output.reason),
            .system_message = try dupeOpt(allocator, parsed.output.system_message),
            .additional_context = try dupeOpt(allocator, parsed.output.additional_context),
            .updated_input = try dupeOpt(allocator, parsed.output.updated_input),
            .permission = mapPermission(parsed.output.permission_decision),
            .permission_reason = try dupeOpt(allocator, parsed.output.permission_decision_reason orelse parsed.output.reason),
            .retry = parsed.output.retry orelse false,
        };
    }

    return null;
}

/// Task 13 (hooks-19): dedup identity check. Returns true when `def` was already
/// seen (a duplicate to skip), false when it is new (and records it). The key is
/// `<shell|bash>\0<body>\0<if>` mirroring the reference's shell\0command\0if
/// (utils/hooks.ts:1735-1756). The key bytes are duped onto `allocator` and
/// owned by `seen`, so they outlive the per-source `cfg` whose def slices they
/// were built from. `shell` defaults to "bash" when unset (the exec-time
/// default), so an explicit `shell:"bash"` and an unset shell dedup together.
fn dedupSeen(allocator: std.mem.Allocator, seen: *std.StringHashMap(void), def: hook_config.HookDef) !bool {
    const shell = if (def.shell.len == 0) "bash" else def.shell;
    const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}\x00{s}", .{ shell, def.body, def.if_cond });
    if (seen.contains(key)) {
        allocator.free(key);
        return true;
    }
    try seen.put(key, {});
    return false;
}

/// Task 13 (hooks-07): remove a `once:true` hook entry from its source
/// settings.json after it runs. Conservative by design: it only removes an inner
/// hook entry that exactly matches `def` (same type + body + matcher + `if`)
/// within the def's own event array, and never rewrites on a parse failure. The
/// rewrite is atomic (temp file + rename) so a crash mid-write cannot truncate
/// the user's settings. A removal that empties a group's `hooks` array leaves the
/// now-empty group in place (harmless: it matches nothing); a removal failure is
/// swallowed by the caller so a read-only settings file degrades to "the hook
/// just runs again next time" rather than crashing the turn.
fn removeOnceHook(allocator: std.mem.Allocator, path: []const u8, event: HookEvent, def: hook_config.HookDef) !void {
    const data = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(256 * 1024)) catch return;
    defer allocator.free(data);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;

    // Mutate through a pointer to the parsed object (CLAUDE.md: take the object
    // by pointer so a realloc inside the map does not desync our view).
    const root_obj = &parsed.value.object;
    const hooks_val = root_obj.getPtr("hooks") orelse return;
    if (hooks_val.* != .object) return;
    const event_arr = hooks_val.object.getPtr(hook_event.canonicalName(event)) orelse return;
    if (event_arr.* != .array) return;

    var removed = false;
    for (event_arr.array.items) |*group| {
        if (group.* != .object) continue;
        const group_matcher = jsonStr(group.object.get("matcher"), "*");
        const inner = group.object.getPtr("hooks") orelse continue;
        if (inner.* != .array) continue;
        var i: usize = 0;
        while (i < inner.array.items.len) {
            if (onceEntryMatches(inner.array.items[i], def, group_matcher)) {
                _ = inner.array.orderedRemove(i);
                removed = true;
                // Only drop the first exact match per `run()` (each event fires
                // the def once); keep scanning other groups is unnecessary.
                break;
            }
            i += 1;
        }
        if (removed) break;
    }
    if (!removed) return;

    const out = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(parsed.value, .{ .whitespace = .indent_2 })});
    defer allocator.free(out);
    try writeSettingsAtomic(allocator, path, out);
}

/// True when a raw settings inner-hook entry corresponds to `def`: same type,
/// same body (command/url/prompt), same `if`, and the same group matcher. This
/// is intentionally strict so `once` removal never deletes a sibling hook.
fn onceEntryMatches(entry: std.json.Value, def: hook_config.HookDef, group_matcher: []const u8) bool {
    if (entry != .object) return false;
    const type_str = jsonStr(entry.object.get("type"), "command");
    const want_type = switch (def.hook_type) {
        .command => "command",
        .prompt => "prompt",
        .http => "http",
        .agent => "agent",
    };
    if (!std.mem.eql(u8, type_str, want_type)) return false;
    const body_key = switch (def.hook_type) {
        .command => "command",
        .http => "url",
        .prompt, .agent => "prompt",
    };
    const body_str = jsonStr(entry.object.get(body_key), "");
    if (!std.mem.eql(u8, body_str, def.body)) return false;
    if (!std.mem.eql(u8, jsonStr(entry.object.get("if"), ""), def.if_cond)) return false;
    if (!std.mem.eql(u8, group_matcher, def.matcher)) return false;
    return true;
}

/// Read a string-valued JSON key with a default. Local mirror of
/// hook_config's `str` (which is private to that module).
fn jsonStr(v: ?std.json.Value, default: []const u8) []const u8 {
    const val = v orelse return default;
    return switch (val) {
        .string => |s| s,
        else => default,
    };
}

/// Atomic settings rewrite: write `bytes` to a sibling temp file (0600) and
/// rename it over `path`. A rename is atomic on the same filesystem, so a
/// concurrent reader sees either the old or the new file, never a partial one
/// (Task 13 risk: never overwrite settings.json in place).
fn writeSettingsAtomic(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const nonce = clock.nowNanos();
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{x}", .{ path, nonce });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};
    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, bytes);
        file.sync(rt.io) catch {};
    }
    try std.Io.Dir.renameAbsolute(tmp_path, path, rt.io);
}

const CommandResult = struct { exit_code: u8, stdout: []u8, timed_out: bool = false };

/// Run `sh -c "<command> < <tmp>"` with `payload` written to the temp file so
/// the hook receives it on stdin. Uses the one-shot runner (captures stdout,
/// no manual pipe pumping). Temp file uses a hex-only name so no shell quoting
/// is needed; it is removed afterward.
///
/// Task 8 (hooks-08): `timeout_ms` bounds the wall-clock the hook may take. On
/// expiry `std.process.run` reaps the child internally (CLAUDE.md: do NOT
/// `wait()` after a kill) and returns `error.Timeout`, which we surface as a
/// `timed_out` result (a non-blocking outcome, not a block).
fn runCommandWithStdin(allocator: std.mem.Allocator, command: []const u8, cwd: []const u8, home: []const u8, payload: []const u8, event: HookEvent, timeout_ms: u64) !CommandResult {
    const nonce = clock.nowNanos();
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}/.hook-input-{x}.json", .{ home, nonce });
    defer allocator.free(tmp_path);
    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, payload);
    }
    defer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    // Single-quote the redirect path: the hex filename needs no quoting, but the
    // interpolated home/config prefix can contain spaces (e.g. /Users/First Last)
    // which would otherwise split the redirect target and inject a stray argv.
    // PRD #534 review fix. (A single quote in the home path is not escaped, but
    // that is vanishingly rare and would only fail the hook, not misbehave.)
    const full = try std.fmt.allocPrint(allocator, "{s} < '{s}'", .{ command, tmp_path });
    defer allocator.free(full);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("ZCODE_HOOK_EVENT", eventName(event));

    // CLAUDE_* alias set (PRD #534, hooks-09). Additive alongside ZCODE_*.
    const project_dir = resolveProjectDir(allocator, cwd) catch try allocator.dupe(u8, cwd);
    defer allocator.free(project_dir);
    try env_map.put("CLAUDE_PROJECT_DIR", project_dir);

    // CLAUDE_ENV_FILE export-injection (same contract as runSingle): hook
    // may write `KEY=value` exports; merge them into the session env after.
    var env_file: ?[]u8 = null;
    defer if (env_file) |f| allocator.free(f);
    if (session_env.createEnvFile(allocator, home)) |f| {
        env_file = f;
        env_map.put("CLAUDE_ENV_FILE", f) catch {};
    } else |_| {}

    // Task 8: bound the hook's wall-clock. error.Timeout means the runner
    // already reaped the killed child (no manual wait); surface it as a
    // non-blocking timed_out result so a hung hook cannot stall the agent.
    const result = std.process.run(allocator, rt.io, .{
        .argv = &.{ "sh", "-c", full },
        .cwd = .{ .path = cwd },
        .environ_map = &env_map,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .raw = .{ .nanoseconds = timeout_ms * std.time.ns_per_ms }, .clock = .awake } },
    }) catch |err| switch (err) {
        error.Timeout => {
            if (env_file) |f| {
                _ = session_env.mergeEnvFile(allocator, f) catch 0;
                std.Io.Dir.cwd().deleteFile(rt.io, f) catch {};
            }
            return .{ .exit_code = 1, .stdout = try allocator.dupe(u8, ""), .timed_out = true };
        },
        else => return err,
    };
    defer allocator.free(result.stderr);

    if (env_file) |f| {
        _ = session_env.mergeEnvFile(allocator, f) catch 0;
        std.Io.Dir.cwd().deleteFile(rt.io, f) catch {};
    }

    const code: u8 = if (result.term == .exited) @intCast(result.term.exited & 0xff) else 1;
    return .{ .exit_code = code, .stdout = result.stdout, .timed_out = false };
}

/// Task 12 (hooks-06): spawn a command hook in the background and hand the live
/// child to the pending async registry. The payload is delivered on the child's
/// stdin pipe directly (no temp file, so there is no file-lifetime hazard with
/// an asynchronously-reading child). Returns immediately; the registry later
/// drains the finished child via `checkResponses`. CLAUDE.md: `std.process.spawn`
/// is the long-lived spawner; do not `wait()` here (the registry owns the
/// lifetime). `home` is currently unused (no temp file) but kept for parity with
/// the synchronous path's signature.
fn spawnAsyncCommand(allocator: std.mem.Allocator, def: hook_config.HookDef, cwd: []const u8, home: []const u8, payload: []const u8, event: HookEvent) !void {
    _ = home;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("ZCODE_HOOK_EVENT", eventName(event));

    const project_dir = resolveProjectDir(allocator, cwd) catch try allocator.dupe(u8, cwd);
    defer allocator.free(project_dir);
    try env_map.put("CLAUDE_PROJECT_DIR", project_dir);

    var child = try std.process.spawn(rt.io, .{
        .argv = &.{ "sh", "-c", def.body },
        .cwd = .{ .path = cwd },
        .environ_map = &env_map,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    // Feed the payload to the hook's stdin, then close it so the hook sees EOF.
    if (child.stdin) |stdin_file| {
        stdin_file.writeStreamingAll(rt.io, payload) catch {};
        stdin_file.close(rt.io);
        child.stdin = null;
    }

    const timeout_ms = computeTimeoutMs(def.hook_type, def.timeout_s);
    // On a registry-OOM the child cannot be tracked, so kill it (do not leak the
    // OS process). CLAUDE.md: kill reaps internally, no wait() after.
    _ = async_hook_registry.instance.register(
        allocator,
        child,
        event,
        def.async_rewake,
        def.body,
        timeout_ms * std.time.ns_per_ms,
    ) catch |err| {
        if (child.stdout) |f| {
            f.close(rt.io);
            child.stdout = null;
        }
        if (child.id != null) child.kill(rt.io);
        return err;
    };
}

/// Resolve the stable repo root for $CLAUDE_PROJECT_DIR. Tries
/// `git rev-parse --show-toplevel`; falls back to `cwd` when not a repo
/// or git is unavailable. Caller owns the returned slice.
fn resolveProjectDir(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const args = [_][]const u8{ "git", "-C", cwd, "rev-parse", "--show-toplevel" };
    const res = std.process.run(allocator, rt.io, .{
        .argv = &args,
        .stdout_limit = .limited(8 * 1024),
        .stderr_limit = .limited(8 * 1024),
    }) catch return allocator.dupe(u8, cwd);
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    if (res.term == .exited and res.term.exited == 0) {
        const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
        if (trimmed.len > 0) return allocator.dupe(u8, trimmed);
    }
    return allocator.dupe(u8, cwd);
}

fn runSingle(allocator: std.mem.Allocator, path: []const u8, ctx: HookContext) !HookRunResult {
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    try env_map.put("ZCODE_HOOK_EVENT", eventName(ctx.event));
    try env_map.put("ZCODE_CWD", ctx.cwd);
    try env_map.put("ZCODE_TOOL_NAME", ctx.tool_name);
    try env_map.put("ZCODE_TOOL_ARGS", ctx.tool_args);
    try env_map.put("ZCODE_TOOL_OUTPUT", ctx.tool_output);
    try env_map.put("ZCODE_TOOL_SUCCESS", if (ctx.tool_success) "1" else "0");

    // CLAUDE_* alias set (PRD #534, hooks-09). Additive alongside ZCODE_*.
    // CLAUDE_PROJECT_DIR is the stable repo root; fall back to cwd.
    const project_dir = resolveProjectDir(allocator, ctx.cwd) catch try allocator.dupe(u8, ctx.cwd);
    defer allocator.free(project_dir);
    try env_map.put("CLAUDE_PROJECT_DIR", project_dir);

    // CLAUDE_ENV_FILE export-injection: give the hook a temp file it can
    // write `KEY=value` exports to; after it returns we merge those into
    // the session env applied to later Bash commands. Untrusted hook code
    // writes the file, so session_env.mergeEnvFile parses defensively.
    var resolved = paths.resolve(allocator) catch null;
    defer if (resolved) |*r| r.deinit(allocator);
    var env_file: ?[]u8 = null;
    defer if (env_file) |f| allocator.free(f);
    if (resolved) |r| {
        if (session_env.createEnvFile(allocator, r.zcode_home)) |f| {
            env_file = f;
            env_map.put("CLAUDE_ENV_FILE", f) catch {};
        } else |_| {}
    }

    const argv = [_][]const u8{ "sh", path };
    // Task 8: file hooks carry no per-hook `timeout` config, so they always use
    // the command default. error.Timeout means the runner reaped the killed
    // child (no manual wait); surface it as a non-blocking "ran but did
    // nothing" result so a hung `.sh` hook cannot stall the agent.
    const result = std.process.run(allocator, rt.io, .{
        .argv = &argv,
        .cwd = .{ .path = ctx.cwd },
        .environ_map = &env_map,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .raw = .{ .nanoseconds = COMMAND_HOOK_TIMEOUT_MS * std.time.ns_per_ms }, .clock = .awake } },
    }) catch |err| switch (err) {
        error.Timeout => {
            if (env_file) |f| {
                _ = session_env.mergeEnvFile(allocator, f) catch 0;
                std.Io.Dir.cwd().deleteFile(rt.io, f) catch {};
            }
            return .{
                .ran = true,
                .blocked = false,
                .output = try allocator.dupe(u8, ""),
                .trust_path = null,
            };
        },
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Merge any exports the hook wrote, then clean up the temp file.
    if (env_file) |f| {
        _ = session_env.mergeEnvFile(allocator, f) catch 0;
        std.Io.Dir.cwd().deleteFile(rt.io, f) catch {};
    }

    const output_source = if (std.mem.trim(u8, result.stdout, " \t\r\n").len > 0) result.stdout else result.stderr;
    const output = try allocator.dupe(u8, std.mem.trim(u8, output_source, " \t\r\n"));

    return .{
        .ran = true,
        .blocked = !(result.term == .exited and result.term.exited == 0),
        .output = output,
        .trust_path = null,
    };
}

fn userHookPath(allocator: std.mem.Allocator, event: HookEvent) ![]u8 {
    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);
    return std.fs.path.join(allocator, &.{ resolved.zcode_home, "hooks", filenameForEvent(event) });
}

fn workspaceHookPath(allocator: std.mem.Allocator, cwd: []const u8, event: HookEvent) ![]u8 {
    const rel = try std.fmt.allocPrint(allocator, "hooks/{s}", .{filenameForEvent(event)});
    defer allocator.free(rel);
    return paths.workspacePathAlloc(allocator, cwd, rel);
}

/// File hooks exist only for the 3 tool events; settings.json hooks cover the
/// rest. This is only ever reached from the `list()` inline loop over those 3
/// events, so any other variant is a programmer error.
fn filenameForEvent(event: HookEvent) []const u8 {
    return switch (event) {
        .pre_tool_use => "pre-tool-use.sh",
        .post_tool_use => "post-tool-use.sh",
        .post_tool_use_failure => "post-tool-use-failure.sh",
        else => unreachable,
    };
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(rt.io, path, .{}) catch return false;
    return true;
}

const testing = std.testing;

test "renderList reports none when no hooks exist" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const rendered = try renderList(testing.allocator, cwd);
    defer testing.allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "hooks:") != null);
}

test "Task 2: run() accepts a non-tool lifecycle event with no hooks present" {
    // Proves the dispatch layer is now event-agnostic: a non-tool event
    // (one that has no `.sh` file form) is a valid input to run() and, with no
    // configured hooks, returns ran == false without error.
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();

    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try @import("test_helpers.zig").tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    var result = try run(alloc, .{ .event = .session_start, .cwd = cwd });
    defer result.deinit(alloc);
    try testing.expect(!result.ran);
    try testing.expect(!result.blocked);
}

// ── Task 4: project/local/policy settings.json hook merge tests ──────────
//
// These tests point HOME at a tmp dir so the user/policy settings sources and
// the hook-trust store resolve into a hermetic tree we fully control. The
// project source lives under a distinct cwd subdir. paths.resolve prefers an
// existing {HOME}/.zcode, so creating that dir pins zcode_home to the tmp tree.

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Override HOME (and clear XDG_CONFIG_HOME) for the duration of a test so the
/// user/policy settings sources resolve under `home`. Caller restores via the
/// returned restorer's deinit. Creates `{home}/.zcode` so paths.resolve pins
/// zcode_home to it.
const HomeOverride = struct {
    prev_home: ?[]u8,
    prev_xdg: ?[]u8,
    allocator: std.mem.Allocator,

    fn install(allocator: std.mem.Allocator, home: []const u8) !HomeOverride {
        const prev_home = if (@import("env.zig").getOwned(allocator, "HOME")) |v| v else |_| null;
        const prev_xdg = if (@import("env.zig").getOwned(allocator, "XDG_CONFIG_HOME")) |v| v else |_| null;

        const home_z = try allocator.dupeZ(u8, home);
        defer allocator.free(home_z);
        _ = setenv("HOME", home_z, 1);
        _ = unsetenv("XDG_CONFIG_HOME");

        // Pin zcode_home to {home}/.zcode by making it exist.
        const zcode_home = try std.fs.path.join(allocator, &.{ home, ".zcode" });
        defer allocator.free(zcode_home);
        try paths.ensureDir(zcode_home);

        return .{ .prev_home = prev_home, .prev_xdg = prev_xdg, .allocator = allocator };
    }

    fn deinit(self: *HomeOverride) void {
        if (self.prev_home) |h| {
            const z = self.allocator.dupeZ(u8, h) catch return;
            defer self.allocator.free(z);
            _ = setenv("HOME", z, 1);
            self.allocator.free(h);
        } else {
            _ = unsetenv("HOME");
        }
        if (self.prev_xdg) |x| {
            const z = self.allocator.dupeZ(u8, x) catch return;
            defer self.allocator.free(z);
            _ = setenv("XDG_CONFIG_HOME", z, 1);
            self.allocator.free(x);
        } else {
            _ = unsetenv("XDG_CONFIG_HOME");
        }
    }
};

fn writeFileMakingDirs(dir: std.Io.Dir, sub_path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| {
        dir.createDirPath(rt.io, parent) catch {};
    }
    try dir.writeFile(rt.io, .{ .sub_path = sub_path, .data = data });
}

test "Task 4: project settings.json command hook runs when trusted" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();

    // Project lives in a distinct cwd subdir (not the zcode_home tree).
    try tmp.dir.createDirPath(rt.io, "proj/.claude");
    const cwd = try @import("test_helpers.zig").tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    const settings =
        \\{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"echo CLAUDEHOOK_PROJECT_RAN"}]}]}}
    ;
    const settings_path = try std.fs.path.join(alloc, &.{ cwd, ".claude", "settings.json" });
    defer alloc.free(settings_path);
    try writeFileMakingDirs(tmp.dir, "proj/.claude/settings.json", settings);

    // Trust the project settings.json (the trust unit for project/local hooks).
    const msg = try security.allowHook(alloc, cwd, settings_path);
    alloc.free(msg);

    var result = try run(alloc, .{ .event = .pre_tool_use, .cwd = cwd, .tool_name = "Read", .tool_args = "x" });
    defer result.deinit(alloc);
    try testing.expect(result.ran);
    try testing.expect(!result.blocked);
    try testing.expect(std.mem.indexOf(u8, result.output, "CLAUDEHOOK_PROJECT_RAN") != null);
}

test "Task 4: project settings.json hook is skipped when untrusted" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();

    try tmp.dir.createDirPath(rt.io, "proj/.claude");
    const cwd = try @import("test_helpers.zig").tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    const settings =
        \\{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"echo SHOULD_NOT_RUN"}]}]}}
    ;
    try writeFileMakingDirs(tmp.dir, "proj/.claude/settings.json", settings);

    // No allowHook call -> untrusted -> the project hook must not run.
    var result = try run(alloc, .{ .event = .pre_tool_use, .cwd = cwd, .tool_name = "Read", .tool_args = "x" });
    defer result.deinit(alloc);
    try testing.expect(!result.ran);
    try testing.expect(std.mem.indexOf(u8, result.output, "SHOULD_NOT_RUN") == null);
}

test "Task 4: policy disableAllHooks runs nothing" {
    const alloc = testing.allocator;
    hooks_snapshot.resetForTest();
    defer hooks_snapshot.resetForTest();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();

    try tmp.dir.createDirPath(rt.io, "proj/.claude");
    const cwd = try @import("test_helpers.zig").tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    // Trusted project hook that would otherwise run.
    const proj_settings =
        \\{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"echo PROJECT_HOOK"}]}]}}
    ;
    const proj_path = try std.fs.path.join(alloc, &.{ cwd, ".claude", "settings.json" });
    defer alloc.free(proj_path);
    try writeFileMakingDirs(tmp.dir, "proj/.claude/settings.json", proj_settings);
    const msg = try security.allowHook(alloc, cwd, proj_path);
    alloc.free(msg);

    // Policy disables all hooks (it lives under {HOME}/.zcode/policy).
    try writeFileMakingDirs(tmp.dir, ".zcode/policy/settings.json",
        \\{"disableAllHooks":true,"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"echo POLICY_HOOK"}]}]}}
    );

    var result = try run(alloc, .{ .event = .pre_tool_use, .cwd = cwd, .tool_name = "Read", .tool_args = "x" });
    defer result.deinit(alloc);
    try testing.expect(!result.ran);
    try testing.expect(std.mem.indexOf(u8, result.output, "PROJECT_HOOK") == null);
    try testing.expect(std.mem.indexOf(u8, result.output, "POLICY_HOOK") == null);
}

test "Task 4: policy allowManagedHooksOnly keeps only the policy hook" {
    const alloc = testing.allocator;
    hooks_snapshot.resetForTest();
    defer hooks_snapshot.resetForTest();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();

    try tmp.dir.createDirPath(rt.io, "proj/.claude");
    const cwd = try @import("test_helpers.zig").tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    // Trusted project hook -- should be suppressed by managed-only.
    const proj_settings =
        \\{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"echo PROJECT_HOOK_MANAGED"}]}]}}
    ;
    const proj_path = try std.fs.path.join(alloc, &.{ cwd, ".claude", "settings.json" });
    defer alloc.free(proj_path);
    try writeFileMakingDirs(tmp.dir, "proj/.claude/settings.json", proj_settings);
    const msg = try security.allowHook(alloc, cwd, proj_path);
    alloc.free(msg);

    // Policy: managed-only plus its own hook.
    try writeFileMakingDirs(tmp.dir, ".zcode/policy/settings.json",
        \\{"allowManagedHooksOnly":true,"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"echo POLICY_HOOK_KEPT"}]}]}}
    );

    var result = try run(alloc, .{ .event = .pre_tool_use, .cwd = cwd, .tool_name = "Read", .tool_args = "x" });
    defer result.deinit(alloc);
    try testing.expect(result.ran);
    try testing.expect(std.mem.indexOf(u8, result.output, "POLICY_HOOK_KEPT") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "PROJECT_HOOK_MANAGED") == null);
}

test "Task 14: policy strictPluginOnlyCustomization keeps only the policy hook" {
    const alloc = testing.allocator;
    hooks_snapshot.resetForTest();
    defer hooks_snapshot.resetForTest();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();

    try tmp.dir.createDirPath(rt.io, "proj/.claude");
    const cwd = try @import("test_helpers.zig").tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    // Trusted project hook -- should be suppressed by strict-plugin-only.
    const proj_settings =
        \\{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"echo PROJECT_HOOK_STRICT"}]}]}}
    ;
    const proj_path = try std.fs.path.join(alloc, &.{ cwd, ".claude", "settings.json" });
    defer alloc.free(proj_path);
    try writeFileMakingDirs(tmp.dir, "proj/.claude/settings.json", proj_settings);
    const msg = try security.allowHook(alloc, cwd, proj_path);
    alloc.free(msg);

    // Policy: strict-plugin-only customization plus its own (managed) hook.
    try writeFileMakingDirs(tmp.dir, ".zcode/policy/settings.json",
        \\{"strictPluginOnlyCustomization":true,"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"echo POLICY_HOOK_STRICT_KEPT"}]}]}}
    );

    var result = try run(alloc, .{ .event = .pre_tool_use, .cwd = cwd, .tool_name = "Read", .tool_args = "x" });
    defer result.deinit(alloc);
    try testing.expect(result.ran);
    try testing.expect(std.mem.indexOf(u8, result.output, "POLICY_HOOK_STRICT_KEPT") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "PROJECT_HOOK_STRICT") == null);
}

test "Task 14: snapshot freezes the gate until refresh" {
    const alloc = testing.allocator;
    hooks_snapshot.resetForTest();
    defer hooks_snapshot.resetForTest();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();

    try tmp.dir.createDirPath(rt.io, "proj/.claude");
    const cwd = try @import("test_helpers.zig").tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    // User-scope hook (no trust gate) that runs under an open gate.
    try writeFileMakingDirs(tmp.dir, ".zcode/settings.json",
        \\{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"echo SNAPSHOT_HOOK_RAN"}]}]}}
    );

    // First run captures an open gate; the hook runs.
    {
        var result = try run(alloc, .{ .event = .pre_tool_use, .cwd = cwd, .tool_name = "Read", .tool_args = "x" });
        defer result.deinit(alloc);
        try testing.expect(std.mem.indexOf(u8, result.output, "SNAPSHOT_HOOK_RAN") != null);
    }

    // Mid-session edit: policy now disables all hooks. The frozen snapshot must
    // ignore this until an explicit refresh, so the hook keeps running.
    try writeFileMakingDirs(tmp.dir, ".zcode/policy/settings.json",
        \\{"disableAllHooks":true}
    );
    {
        var result = try run(alloc, .{ .event = .pre_tool_use, .cwd = cwd, .tool_name = "Read", .tool_args = "x" });
        defer result.deinit(alloc);
        try testing.expect(std.mem.indexOf(u8, result.output, "SNAPSHOT_HOOK_RAN") != null);
    }

    // After an explicit refresh, the gate picks up the edit and disables hooks.
    _ = hooks_snapshot.refresh(alloc, cwd);
    {
        var result = try run(alloc, .{ .event = .pre_tool_use, .cwd = cwd, .tool_name = "Read", .tool_args = "x" });
        defer result.deinit(alloc);
        try testing.expect(!result.ran);
        try testing.expect(std.mem.indexOf(u8, result.output, "SNAPSHOT_HOOK_RAN") == null);
    }
}

test "Task 4: user-scope settings.json hook still runs (no trust gate)" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();

    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try @import("test_helpers.zig").tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    // User settings live at {HOME}/.zcode/settings.json and need no trust gate.
    try writeFileMakingDirs(tmp.dir, ".zcode/settings.json",
        \\{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"echo USER_HOOK_RAN"}]}]}}
    );

    var result = try run(alloc, .{ .event = .pre_tool_use, .cwd = cwd, .tool_name = "Read", .tool_args = "x" });
    defer result.deinit(alloc);
    try testing.expect(result.ran);
    try testing.expect(std.mem.indexOf(u8, result.output, "USER_HOOK_RAN") != null);
}

test "Task 11: `if` pre-filter skips non-matching tool calls" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();

    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try @import("test_helpers.zig").tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    // A PreToolUse command hook gated by `if: "Bash(git *)"`. The `matcher` is
    // "*" so the `if` is the only discriminator.
    try writeFileMakingDirs(tmp.dir, ".zcode/settings.json",
        \\{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"echo IF_HOOK_RAN","if":"Bash(git *)"}]}]}}
    );

    // A Read call does NOT satisfy the `if` -> the hook must be skipped.
    {
        var result = try run(alloc, .{ .event = .pre_tool_use, .cwd = cwd, .tool_name = "Read", .tool_args = "any.zig" });
        defer result.deinit(alloc);
        try testing.expect(!result.ran);
        try testing.expect(std.mem.indexOf(u8, result.output, "IF_HOOK_RAN") == null);
    }

    // A Bash(git ...) call satisfies the `if` -> the hook runs.
    {
        var result = try run(alloc, .{ .event = .pre_tool_use, .cwd = cwd, .tool_name = "Bash", .tool_args = "git status" });
        defer result.deinit(alloc);
        try testing.expect(result.ran);
        try testing.expect(std.mem.indexOf(u8, result.output, "IF_HOOK_RAN") != null);
    }

    // A non-matching Bash call (wrong content) is also skipped.
    {
        var result = try run(alloc, .{ .event = .pre_tool_use, .cwd = cwd, .tool_name = "Bash", .tool_args = "npm i" });
        defer result.deinit(alloc);
        try testing.expect(!result.ran);
    }
}

test "Task 11: non-tool event hook with non-empty `if` is skipped" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();

    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try @import("test_helpers.zig").tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    // A SessionStart command hook with a non-empty `if` cannot be evaluated for a
    // non-tool event (no tool name/input), so it is skipped (utils/hooks.ts:1835).
    try writeFileMakingDirs(tmp.dir, ".zcode/settings.json",
        \\{"hooks":{"SessionStart":[{"matcher":"*","hooks":[{"type":"command","command":"echo NONTOOL_IF_HOOK","if":"Bash(git *)"}]}]}}
    );

    var result = try run(alloc, .{ .event = .session_start, .cwd = cwd, .source = "startup" });
    defer result.deinit(alloc);
    try testing.expect(!result.ran);
    try testing.expect(std.mem.indexOf(u8, result.output, "NONTOOL_IF_HOOK") == null);
}

// ── Task 12: async hooks run in the background, never blocking the turn ──

test "Task 12: an async:true command hook does not block runEvent" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();

    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try @import("test_helpers.zig").tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    // A user-scope async PreToolUse hook that sleeps 3s before exiting. If it ran
    // synchronously, runEvent would take ~3s; async, it must return promptly.
    try writeFileMakingDirs(tmp.dir, ".zcode/settings.json",
        \\{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"sleep 3; echo {}","async":true}]}]}}
    );

    const start_ms = clock.nowMillis();
    var result = try runEvent(alloc, .{ .event = .pre_tool_use, .cwd = cwd, .tool_name = "Read", .tool_args = "x" });
    defer result.deinit(alloc);
    const elapsed_ms = clock.nowMillis() - start_ms;

    // The hook was dispatched (ran) but did not block: runEvent returned well
    // before the child's 3s sleep would finish.
    try testing.expect(result.ran);
    try testing.expect(!result.blocked);
    try testing.expect(elapsed_ms < 2000);

    // Clean up the still-running background child so it does not outlive the test.
    async_hook_registry.instance.clear(alloc);
}

// ── Task 5: CLAUDE_* hook env vars + CLAUDE_ENV_FILE ──────────────

test "Task 5: command hook sees CLAUDE_PROJECT_DIR resolved to the repo root" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();

    // Make `proj` its own git repo so rev-parse --show-toplevel is
    // deterministic and equals the proj dir (rather than the enclosing
    // zig-code repo that the tmp tree happens to live under).
    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try @import("test_helpers.zig").tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);
    {
        const init_res = std.process.run(alloc, rt.io, .{
            .argv = &.{ "git", "-C", cwd, "init" },
            .stdout_limit = .limited(8 * 1024),
            .stderr_limit = .limited(8 * 1024),
        }) catch null;
        if (init_res) |r| {
            alloc.free(r.stdout);
            alloc.free(r.stderr);
        }
    }

    // User-scope hook (no trust gate) that echoes the project dir.
    try writeFileMakingDirs(tmp.dir, ".zcode/settings.json",
        \\{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"echo PROJECTDIR=$CLAUDE_PROJECT_DIR"}]}]}}
    );

    var result = try run(alloc, .{ .event = .pre_tool_use, .cwd = cwd, .tool_name = "Read", .tool_args = "x" });
    defer result.deinit(alloc);
    try testing.expect(result.ran);
    // CLAUDE_PROJECT_DIR is the repo top-level (proj). Both the git output
    // and our tmpDirPath go through realpath, so the strings match.
    const expect_line = try std.fmt.allocPrint(alloc, "PROJECTDIR={s}", .{cwd});
    defer alloc.free(expect_line);
    try testing.expect(std.mem.indexOf(u8, result.output, expect_line) != null);
}

test "Task 5: CLAUDE_ENV_FILE exports written by a hook reach the session env" {
    const alloc = testing.allocator;
    session_env.resetForTesting(alloc);
    defer session_env.resetForTesting(alloc);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();

    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try @import("test_helpers.zig").tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    // User-scope SessionStart-equivalent hook writes an export to the env file.
    try writeFileMakingDirs(tmp.dir, ".zcode/settings.json",
        \\{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"echo HOOK_EXPORTED=yes > \"$CLAUDE_ENV_FILE\""}]}]}}
    );

    var result = try run(alloc, .{ .event = .pre_tool_use, .cwd = cwd, .tool_name = "Read", .tool_args = "x" });
    defer result.deinit(alloc);
    try testing.expect(result.ran);

    // The export is now applied to a subsequent Bash command's env.
    var bash_env = std.process.Environ.Map.init(alloc);
    defer bash_env.deinit();
    try session_env.applyToEnvMap(&bash_env);
    try testing.expectEqualStrings("yes", bash_env.get("HOOK_EXPORTED").?);
}

// ── hooks-04: act on the full stdout JSON contract ───────────────────────

/// Shared scaffolding for the stdout-contract tests: a user-scope settings.json
/// with a single PreToolUse command hook whose stdout is `echo`ed verbatim.
fn runContractHook(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir, settings_json: []const u8) !HookRunResult {
    const cwd = try @import("test_helpers.zig").tmpDirPath(alloc, tmp, "proj");
    defer alloc.free(cwd);
    try writeFileMakingDirs(tmp.dir, ".zcode/settings.json", settings_json);
    return run(alloc, .{ .event = .pre_tool_use, .cwd = cwd, .tool_name = "Read", .tool_args = "x" });
}

test "hooks-04: decision block at exit 0 blocks with the reason" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);
    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();
    try tmp.dir.createDirPath(rt.io, "proj");

    // The hook exits 0 but prints decision:block; the reference treats
    // decision:block as blocking independent of exit code.
    var result = try runContractHook(alloc, &tmp,
        \\{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"echo '{\"decision\":\"block\",\"reason\":\"nope\"}'; exit 0"}]}]}}
    );
    defer result.deinit(alloc);
    try testing.expect(result.ran);
    try testing.expect(result.blocked);
    try testing.expectEqualStrings("nope", result.stop_reason.?);
}

test "hooks-04: continue false with stopReason is surfaced" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);
    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();
    try tmp.dir.createDirPath(rt.io, "proj");

    var result = try runContractHook(alloc, &tmp,
        \\{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"echo '{\"continue\":false,\"stopReason\":\"halt\"}'"}]}]}}
    );
    defer result.deinit(alloc);
    try testing.expect(result.ran);
    try testing.expectEqual(@as(?bool, false), result.continue_run);
    try testing.expectEqualStrings("halt", result.stop_reason.?);
}

test "hooks-04: additionalContext is carried into the result" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);
    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();
    try tmp.dir.createDirPath(rt.io, "proj");

    var result = try runContractHook(alloc, &tmp,
        \\{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"echo '{\"hookSpecificOutput\":{\"additionalContext\":\"NOTE\"}}'"}]}]}}
    );
    defer result.deinit(alloc);
    try testing.expect(result.ran);
    try testing.expect(!result.blocked);
    try testing.expectEqualStrings("NOTE", result.additional_context.?);
}

test "hooks-04: systemMessage and suppressOutput are surfaced" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);
    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();
    try tmp.dir.createDirPath(rt.io, "proj");

    var result = try runContractHook(alloc, &tmp,
        \\{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"echo '{\"systemMessage\":\"heads up\",\"suppressOutput\":true}'"}]}]}}
    );
    defer result.deinit(alloc);
    try testing.expect(result.ran);
    try testing.expect(result.suppress_output);
    try testing.expectEqualStrings("heads up", result.system_message.?);
}

test "hooks-04: permissionDecision allow is mapped without blocking" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);
    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();
    try tmp.dir.createDirPath(rt.io, "proj");

    var result = try runContractHook(alloc, &tmp,
        \\{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"echo '{\"hookSpecificOutput\":{\"permissionDecision\":\"allow\",\"permissionDecisionReason\":\"trusted\"}}'"}]}]}}
    );
    defer result.deinit(alloc);
    try testing.expect(result.ran);
    try testing.expect(!result.blocked);
    try testing.expectEqual(HookPermission.allow, result.permission);
    try testing.expectEqualStrings("trusted", result.permission_reason.?);
}

// ── Task 8 (hooks-08): per-hook timeout enforcement ──────────────────────

test "hooks-08: computeTimeoutMs applies type defaults and the timeout override" {
    // No timeout_s -> per-type default (command/http = 10 min, prompt = 30s,
    // agent = 60s).
    try testing.expectEqual(@as(u64, COMMAND_HOOK_TIMEOUT_MS), computeTimeoutMs(.command, null));
    try testing.expectEqual(@as(u64, hook_exec_prompt.PROMPT_TIMEOUT_MS), computeTimeoutMs(.prompt, null));
    try testing.expectEqual(@as(u64, hook_exec_prompt.AGENT_TIMEOUT_MS), computeTimeoutMs(.agent, null));
    try testing.expectEqual(@as(u64, hook_exec_http.HTTP_TIMEOUT_MS), computeTimeoutMs(.http, null));

    // A non-null timeout_s (seconds) always overrides, for every type.
    try testing.expectEqual(@as(u64, 5_000), computeTimeoutMs(.command, 5));
    try testing.expectEqual(@as(u64, 2_000), computeTimeoutMs(.prompt, 2));
    try testing.expectEqual(@as(u64, 0), computeTimeoutMs(.http, 0));
}

test "hooks-08: a command hook with timeout_s=1 times out without blocking" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);
    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();
    try tmp.dir.createDirPath(rt.io, "proj");

    // The hook sleeps 5s but pins timeout=1, so it must be killed at ~1s and
    // surface as a non-blocking timeout (not a block). We measure wall-clock to
    // prove the kill happened well before the 5s sleep would finish.
    const start = clock.nowMillis();
    var result = try runContractHook(alloc, &tmp,
        \\{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"sleep 5","timeout":1}]}]}}
    );
    defer result.deinit(alloc);
    const elapsed_ms = clock.nowMillis() - start;

    try testing.expect(result.ran);
    // A timed-out hook is a non-blocking error: the agent continues.
    try testing.expect(!result.blocked);
    // Killed near the 1s budget, far short of the 5s sleep. Generous upper
    // bound (4s) absorbs CI scheduler jitter while still proving the timeout
    // fired rather than waiting out the full sleep.
    try testing.expect(elapsed_ms < 4_000);
}

// ── Task 13 (hooks-19 / hooks-07): dedup + `once` self-removal ────────────

test "hooks-19: two identical command hooks run only once" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);
    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();
    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try @import("test_helpers.zig").tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    // A side-effect file the hook appends one line to per execution. Two
    // byte-for-byte identical command entries share the same shell+body+if key,
    // so the dedup map collapses them: the file must end up with a single line.
    const marker = try std.fs.path.join(alloc, &.{ cwd, "dedup-count.txt" });
    defer alloc.free(marker);
    const settings = try std.fmt.allocPrint(alloc,
        \\{{"hooks":{{"PreToolUse":[{{"matcher":"*","hooks":[{{"type":"command","command":"echo x >> '{s}'"}},{{"type":"command","command":"echo x >> '{s}'"}}]}}]}}}}
    , .{ marker, marker });
    defer alloc.free(settings);
    try writeFileMakingDirs(tmp.dir, ".zcode/settings.json", settings);

    var result = try runEvent(alloc, .{ .event = .pre_tool_use, .cwd = cwd, .tool_name = "Read", .tool_args = "x" });
    defer result.deinit(alloc);
    try testing.expect(result.ran);

    const count_data = try std.Io.Dir.cwd().readFileAlloc(rt.io, marker, alloc, .limited(4096));
    defer alloc.free(count_data);
    var lines: usize = 0;
    var it = std.mem.tokenizeScalar(u8, count_data, '\n');
    while (it.next()) |_| lines += 1;
    try testing.expectEqual(@as(usize, 1), lines);
}

test "hooks-07: a once:true hook is removed from settings.json after it runs" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);
    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();
    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try @import("test_helpers.zig").tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    // A user-scope settings.json with two command hooks: one `once:true` (which
    // must self-remove after running) and one normal hook (which must survive).
    try writeFileMakingDirs(tmp.dir, ".zcode/settings.json",
        \\{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"echo ONCE_HOOK","once":true},{"type":"command","command":"echo KEEP_HOOK"}]}]}}
    );

    var result = try runEvent(alloc, .{ .event = .pre_tool_use, .cwd = cwd, .tool_name = "Read", .tool_args = "x" });
    defer result.deinit(alloc);
    try testing.expect(result.ran);

    // Re-read the rewritten settings.json: the once entry is gone, the other
    // remains, and the file is still valid JSON.
    const settings_path = try std.fs.path.join(alloc, &.{ root, ".zcode", "settings.json" });
    defer alloc.free(settings_path);
    const rewritten = try std.Io.Dir.cwd().readFileAlloc(rt.io, settings_path, alloc, .limited(16 * 1024));
    defer alloc.free(rewritten);

    try testing.expect(std.mem.indexOf(u8, rewritten, "echo ONCE_HOOK") == null);
    try testing.expect(std.mem.indexOf(u8, rewritten, "echo KEEP_HOOK") != null);

    // The surviving file still parses into exactly one PreToolUse command def.
    var p = try hook_config.parse(alloc, rewritten);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.defs.len);
    try testing.expectEqualStrings("echo KEEP_HOOK", p.defs[0].body);
}

// ── Task 15 (hooks-13): session-scoped hooks dispatch alongside settings ──

test "Task 15: a session-registered command hook runs via runEvent" {
    const alloc = testing.allocator;
    session_hooks.instance.clearSession();
    defer session_hooks.instance.clearSession();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();

    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try @import("test_helpers.zig").tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    // No settings.json hooks: the only hook for this event is the in-memory one.
    try session_hooks.instance.add(alloc, .{
        .event = .pre_tool_use,
        .matcher = "*",
        .hook_type = .command,
        .body = "echo SESSION_PRE_RAN",
    });

    var result = try runEvent(alloc, .{ .event = .pre_tool_use, .cwd = cwd, .tool_name = "Read", .tool_args = "x" });
    defer result.deinit(alloc);
    try testing.expect(result.ran);
    try testing.expect(!result.blocked);
    try testing.expect(std.mem.indexOf(u8, result.output, "SESSION_PRE_RAN") != null);
}

test "Task 15: session hooks run alongside settings.json hooks" {
    const alloc = testing.allocator;
    session_hooks.instance.clearSession();
    defer session_hooks.instance.clearSession();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();

    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try @import("test_helpers.zig").tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    // A user-scope settings hook that appends to a side-effect file, plus a
    // session hook that appends a different marker to the same file. Both must
    // run; the file content then proves both fired in one dispatch.
    const sink = try std.fs.path.join(alloc, &.{ cwd, "sink.txt" });
    defer alloc.free(sink);

    const settings = try std.fmt.allocPrint(alloc,
        \\{{"hooks":{{"PreToolUse":[{{"matcher":"*","hooks":[{{"type":"command","command":"echo SETTINGS_MARK >> '{s}'"}}]}}]}}}}
    , .{sink});
    defer alloc.free(settings);
    try writeFileMakingDirs(tmp.dir, ".zcode/settings.json", settings);

    const session_cmd = try std.fmt.allocPrint(alloc, "echo SESSION_MARK >> '{s}'", .{sink});
    defer alloc.free(session_cmd);
    try session_hooks.instance.add(alloc, .{
        .event = .pre_tool_use,
        .matcher = "*",
        .hook_type = .command,
        .body = session_cmd,
    });

    var result = try runEvent(alloc, .{ .event = .pre_tool_use, .cwd = cwd, .tool_name = "Read", .tool_args = "x" });
    defer result.deinit(alloc);
    try testing.expect(result.ran);

    const contents = try std.Io.Dir.cwd().readFileAlloc(rt.io, sink, alloc, .limited(4 * 1024));
    defer alloc.free(contents);
    try testing.expect(std.mem.indexOf(u8, contents, "SETTINGS_MARK") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "SESSION_MARK") != null);
}

// ── Task 16: hook-execution event broadcasting + statusMessage ───────────
//
// A real SessionStart command hook (driven through runEvent) must surface one
// `started` and one `response` execution event to a registered listener, with
// the parsed exit code, and must push its `statusMessage` to the spinner
// callback. SessionStart is in the ALWAYS_EMITTED set, so this also proves the
// event surfaces with the SDK toggle off (the listener-level gate is unit-tested
// in hook_events.zig). The listener is a bare fn pointer, so the test captures
// into module-global scratch state.
const EventCapture = struct {
    var started: usize = 0;
    var response: usize = 0;
    var last_exit: ?u8 = null;
    var status: usize = 0;
    var status_buf: [80]u8 = undefined;
    var status_len: usize = 0;

    fn reset() void {
        started = 0;
        response = 0;
        last_exit = null;
        status = 0;
        status_len = 0;
    }

    fn onEvent(ev: hook_events.Event) void {
        switch (ev.phase) {
            .started => started += 1,
            .response => {
                response += 1;
                last_exit = ev.exit_code;
            },
            .progress => {},
        }
    }

    fn onStatus(msg: []const u8) void {
        status += 1;
        const n = @min(msg.len, status_buf.len);
        @memcpy(status_buf[0..n], msg[0..n]);
        status_len = n;
    }

    fn lastStatus() []const u8 {
        return status_buf[0..status_len];
    }
};

test "Task 16: command hook broadcasts started + response and statusMessage" {
    const alloc = testing.allocator;
    EventCapture.reset();
    hook_events.resetForTest();
    defer hook_events.resetForTest();
    session_hooks.instance.clearSession();
    defer session_hooks.instance.clearSession();
    hooks_snapshot.resetForTest();
    defer hooks_snapshot.resetForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try @import("test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();

    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try @import("test_helpers.zig").tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    // A user-scope SessionStart command hook (exit 0) carrying a statusMessage.
    // SessionStart is always-emitted, so no SDK toggle is needed.
    const settings =
        \\{"hooks":{"SessionStart":[{"matcher":"*","hooks":[{"type":"command","command":"echo HELLO","statusMessage":"booting"}]}]}}
    ;
    try writeFileMakingDirs(tmp.dir, ".zcode/settings.json", settings);

    hook_events.instance.setListener(EventCapture.onEvent);
    hook_events.instance.setStatusListener(EventCapture.onStatus);

    var result = try runEvent(alloc, .{ .event = .session_start, .cwd = cwd, .source = "startup" });
    defer result.deinit(alloc);
    try testing.expect(result.ran);

    // Exactly one started + one response pair, with the parsed exit code (0).
    try testing.expectEqual(@as(usize, 1), EventCapture.started);
    try testing.expectEqual(@as(usize, 1), EventCapture.response);
    try testing.expectEqual(@as(?u8, 0), EventCapture.last_exit);

    // The hook's statusMessage reached the spinner callback.
    try testing.expectEqual(@as(usize, 1), EventCapture.status);
    try testing.expectEqualStrings("booting", EventCapture.lastStatus());
}
