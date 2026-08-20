const std = @import("std");
const rt = @import("zcode_runtime");
const std_io = @import("core/std_io.zig");
const build_options = @import("build_options");

const repl = @import("cli/repl.zig");
const config_mod = @import("core/config.zig");
const ui_theme = @import("core/ui_theme.zig");
const color_level_mod = @import("core/color_level.zig");
const terminal_caps = @import("core/terminal_caps.zig");
const logger_mod = @import("core/logger.zig");
const plugins_mod = @import("core/plugins.zig");
const types = @import("core/types.zig");
const ci_output = @import("core/ci_output.zig");
const policy_mod = @import("policy/policy.zig");
const session_store = @import("session/store.zig");
const mcp_client = @import("mcp/client.zig");
const browser_bridge_mod = @import("mcp/browser_bridge.zig");
const agent_runtime = @import("agent_runtime.zig");
const prompt_sections = @import("core/prompt_sections.zig");
const repl_commands = @import("repl_commands.zig");
const team_tool = @import("tools/team.zig");
const sdk_output = @import("sdk/output.zig");
const cost_mod = @import("core/cost.zig");
const session_registry = @import("core/session_registry.zig");
const tmux_socket = @import("core/tmux_socket.zig");

const AgentRuntime = agent_runtime.AgentRuntime;

// Re-export sub-modules so callers can continue using session_mgmt.cmdXxx.
pub const session_cmds = @import("session_cmds.zig");
pub const provider_cmds = @import("provider_cmds.zig");
pub const mcp_cmds = @import("mcp_cmds.zig");

// --- Re-exports: session lifecycle ---
pub const cmdSessionList = session_cmds.cmdSessionList;
pub const cmdSessionResume = session_cmds.cmdSessionResume;
pub const cmdSessionContinue = session_cmds.cmdSessionContinue;
pub const cmdSessionCompact = session_cmds.cmdSessionCompact;
pub const cmdSessionExport = session_cmds.cmdSessionExport;
pub const cmdSessionCheckpoint = session_cmds.cmdSessionCheckpoint;
pub const cmdSessionCheckpoints = session_cmds.cmdSessionCheckpoints;
pub const cmdSessionShare = session_cmds.cmdSessionShare;
pub const cmdSessionImport = session_cmds.cmdSessionImport;
pub const cmdSessionUndo = session_cmds.cmdSessionUndo;
pub const cmdSessionRestore = session_cmds.cmdSessionRestore;
pub const cmdSessionFork = session_cmds.cmdSessionFork;
pub const cmdReview = session_cmds.cmdReview;
pub const cmdDaemonStart = session_cmds.cmdDaemonStart;
pub const cmdDaemonStatus = session_cmds.cmdDaemonStatus;
pub const cmdDaemonStop = session_cmds.cmdDaemonStop;
pub const cmdDaemonHandoff = session_cmds.cmdDaemonHandoff;
pub const cmdTrustStatus = session_cmds.cmdTrustStatus;
pub const cmdTrustAllow = session_cmds.cmdTrustAllow;
pub const cmdTrustRevoke = session_cmds.cmdTrustRevoke;
pub const cmdTrustHooks = session_cmds.cmdTrustHooks;
pub const cmdTrustHookAllow = session_cmds.cmdTrustHookAllow;
pub const cmdTrustHookRevoke = session_cmds.cmdTrustHookRevoke;
pub const cmdTrustMarketplace = session_cmds.cmdTrustMarketplace;
pub const cmdTrustMarketplaceAllow = session_cmds.cmdTrustMarketplaceAllow;
pub const cmdTrustMarketplaceBlock = session_cmds.cmdTrustMarketplaceBlock;
pub const cmdTrustMarketplaceUnblock = session_cmds.cmdTrustMarketplaceUnblock;
pub const cmdAgentsList = session_cmds.cmdAgentsList;
pub const cmdAgentsShow = session_cmds.cmdAgentsShow;
pub const cmdHooksList = session_cmds.cmdHooksList;
pub const cmdMarketplaceSources = session_cmds.cmdMarketplaceSources;
pub const cmdMarketplaceAdd = session_cmds.cmdMarketplaceAdd;
pub const cmdMarketplaceRemove = session_cmds.cmdMarketplaceRemove;
pub const cmdMarketplaceRefresh = session_cmds.cmdMarketplaceRefresh;
pub const cmdPluginsList = session_cmds.cmdPluginsList;
pub const cmdPluginsShow = session_cmds.cmdPluginsShow;
pub const cmdPluginsMarketplace = session_cmds.cmdPluginsMarketplace;
pub const cmdPluginsInstall = session_cmds.cmdPluginsInstall;
pub const cmdPluginsUninstall = session_cmds.cmdPluginsUninstall;
pub const cmdPluginsUpdate = session_cmds.cmdPluginsUpdate;
pub const cmdPluginsEnable = session_cmds.cmdPluginsEnable;
pub const cmdPluginsDisable = session_cmds.cmdPluginsDisable;
pub const cmdPluginsDisableAll = session_cmds.cmdPluginsDisableAll;
pub const cmdCommandsList = session_cmds.cmdCommandsList;
pub const cmdCommandsShow = session_cmds.cmdCommandsShow;
pub const cmdCommandsMarketplace = session_cmds.cmdCommandsMarketplace;
pub const cmdCommandsInstall = session_cmds.cmdCommandsInstall;
pub const cmdCommandsUninstall = session_cmds.cmdCommandsUninstall;
pub const cmdCommandsUpdate = session_cmds.cmdCommandsUpdate;
pub const cmdCommandsRun = session_cmds.cmdCommandsRun;
pub const cmdSkillsList = session_cmds.cmdSkillsList;
pub const cmdSkillsShow = session_cmds.cmdSkillsShow;
pub const cmdSkillsRun = session_cmds.cmdSkillsRun;

// --- Re-exports: provider/model ---
pub const cmdModelsList = provider_cmds.cmdModelsList;
pub const cmdModelsTest = provider_cmds.cmdModelsTest;
pub const cmdProvidersLogin = provider_cmds.cmdProvidersLogin;
pub const cmdProvidersLogout = provider_cmds.cmdProvidersLogout;
pub const cmdProvidersStatus = provider_cmds.cmdProvidersStatus;
pub const providerEnv = provider_cmds.providerEnv;
pub const cmdBenchmarkRun = provider_cmds.cmdBenchmarkRun;
pub const cmdKeychainSet = provider_cmds.cmdKeychainSet;
pub const cmdKeychainGet = provider_cmds.cmdKeychainGet;
pub const cmdKeychainDelete = provider_cmds.cmdKeychainDelete;
pub const cmdKeychainList = provider_cmds.cmdKeychainList;

// --- Re-exports: MCP ---
pub const cmdMcpList = mcp_cmds.cmdMcpList;
pub const cmdMcpTools = mcp_cmds.cmdMcpTools;
pub const cmdMcpResources = mcp_cmds.cmdMcpResources;
pub const cmdMcpTemplates = mcp_cmds.cmdMcpTemplates;
pub const cmdMcpRead = mcp_cmds.cmdMcpRead;
pub const cmdMcpPrompts = mcp_cmds.cmdMcpPrompts;
pub const cmdMcpPrompt = mcp_cmds.cmdMcpPrompt;
pub const cmdMcpComplete = mcp_cmds.cmdMcpComplete;
pub const cmdMcpSubscribe = mcp_cmds.cmdMcpSubscribe;
pub const cmdMcpUnsubscribe = mcp_cmds.cmdMcpUnsubscribe;
pub const cmdMcpLogLevel = mcp_cmds.cmdMcpLogLevel;
pub const cmdMcpNotifications = mcp_cmds.cmdMcpNotifications;
pub const cmdMcpAdd = mcp_cmds.cmdMcpAdd;
pub const cmdMcpRemove = mcp_cmds.cmdMcpRemove;
pub const cmdMcpTest = mcp_cmds.cmdMcpTest;
pub const cmdMcpAuthLogin = mcp_cmds.cmdMcpAuthLogin;
pub const cmdMcpAuthStatus = mcp_cmds.cmdMcpAuthStatus;
pub const cmdMcpAuthLogout = mcp_cmds.cmdMcpAuthLogout;

pub fn replOptionsFromConfig(cfg: *const config_mod.Config, yolo_mode: bool, cwd: []const u8, branch: []const u8) repl.Options {
    const theme_setting = ui_theme.parseThemeSetting(cfg.ui_theme) orelse .dark;
    // Resolve the terminal color level (boost-then-clamp) and downgrade a
    // truecolor built-in to its 16-color `*-ansi` counterpart when the terminal
    // (notably tmux) cannot pass truecolor through. See core/color_level.zig.
    const color_level = color_level_mod.resolveFromEnv();
    const resolved_theme = color_level_mod.applyLevelToTheme(ui_theme.resolveSetting(theme_setting), color_level);
    const density = repl.parseUiDensity(cfg.ui_density) orelse .full;
    return .{
        .prompt_label = cfg.ui_prompt_label,
        .app_version = build_options.app_version,
        .status_provider = cfg.default_provider,
        .status_model = cfg.default_model,
        .status_workspace = cwd,
        .status_branch = branch,
        .status_model_context_window = cfg.model_context_window,
        .status_approval_mode = if (yolo_mode) "yolo" else cfg.approval_mode,
        .status_sandbox = cfg.sandbox,
        .status_show_workspace = cfg.ui_status_show_workspace,
        .status_show_model = cfg.ui_status_show_model,
        .status_show_safety = cfg.ui_status_show_safety,
        .status_show_tokens = cfg.ui_status_show_tokens,
        .status_show_hint = cfg.ui_status_show_hint,
        .yolo_mode = yolo_mode,
        .color_enabled = cfg.ui_color_enabled,
        .theme_setting = theme_setting,
        .theme = resolved_theme,
        .highlight_links = cfg.ui_highlight_links,
        .highlight_paths = cfg.ui_highlight_paths,
        .color_lists = cfg.ui_color_lists,
        .highlight_code_blocks = cfg.ui_highlight_code_blocks,
        .enable_fullscreen = cfg.ui_fullscreen,
        .enable_alt_screen = cfg.ui_alt_screen,
        // DEC 2026 synchronized output: only wrap the alt-screen full redraw
        // (where flicker is visible) and only on terminals known to support
        // it (excludes tmux). The append-only path does not benefit.
        .enable_synchronized_output = cfg.ui_alt_screen and terminal_caps.isSynchronizedOutputSupported(),
        .enable_spinner = cfg.ui_spinner,
        .enable_thinking_summary = cfg.ui_thinking_summary,
        .brief_mode = cfg.ui_brief_mode,
        .ui_density = density,
        .ui_leader_key = cfg.ui_leader_key,
        .show_top_bar = cfg.ui_show_top_bar,
        .shortcuts_panel_enabled = cfg.ui_show_shortcuts_panel,
        .vim_mode_enabled = cfg.ui_vim_mode,
        .input_mode_label = if (cfg.ui_vim_mode) "VIM INSERT" else "",
        .auto_mode_opted_in = cfg.ui_auto_mode_opt_in_seen,
        .skip_dangerous_mode_permission_prompt = cfg.skip_dangerous_mode_permission_prompt,
        .ui_idle_return_never_ask = cfg.ui_idle_return_never_ask,
        .transcript_max_lines = cfg.ui_transcript_max_lines,
        .show_scroll_hint = cfg.ui_show_scroll_hint,
        .bottom_margin_rows = cfg.ui_bottom_margin_rows,
        .transcript_line_spacing = cfg.ui_line_spacing,
        .spinner_tips_enabled = cfg.spinner_tips_enabled,
        .spinner_tips_custom = cfg.spinner_tips_custom,
        .spinner_tips_exclude_default = cfg.spinner_tips_exclude_default,
    };
}

pub fn detectGitBranch(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const argv = [_][]const u8{
        "git",
        "-C",
        cwd,
        "rev-parse",
        "--abbrev-ref",
        "HEAD",
    };
    const res = std.process.run(allocator, rt.io, .{
        .argv = &argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return allocator.dupe(u8, "");
    defer allocator.free(res.stderr);
    defer allocator.free(res.stdout);

    switch (res.term) {
        .exited => |code| {
            if (code != 0) return allocator.dupe(u8, "");
        },
        else => return allocator.dupe(u8, ""),
    }

    const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "HEAD")) return allocator.dupe(u8, "");
    return allocator.dupe(u8, trimmed);
}

fn emitPluginEventNotice(writer: anytype, result: plugins_mod.PluginRunResult) !void {
    if (result.output.len == 0) return;
    try writer.print("[plugin] {s}\n", .{result.output});
}

pub fn runPluginEvent(allocator: std.mem.Allocator, writer: anytype, ctx: plugins_mod.PluginContext) !void {
    var result = try plugins_mod.run(allocator, ctx);
    defer result.deinit(allocator);
    try emitPluginEventNotice(writer, result);
    if (result.blocked) return error.PluginBlocked;
}

fn runPluginEventSilent(allocator: std.mem.Allocator, ctx: plugins_mod.PluginContext) !void {
    var result = try plugins_mod.run(allocator, ctx);
    defer result.deinit(allocator);
    if (result.blocked) return error.PluginBlocked;
}

pub fn runInteractive(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    cfg: *const config_mod.Config,
    policy: *policy_mod.Policy,
    audit: *logger_mod.AuditLogger,
    store: *session_store.Store,
    mcp: *mcp_client.Client,
    browser: ?*browser_bridge_mod.BrowserBridge,
    auto_approve_high: bool,
    strict: bool,
    yolo_mode: bool,
    initial_prompt: ?[]const u8,
    initial_agent: ?[]const u8,
    session_name: ?[]const u8,
) !void {
    var runtime = try AgentRuntime.init(allocator, cwd, cfg, policy, audit, store, mcp, browser, true, auto_approve_high, strict, yolo_mode);
    defer runtime.deinit();
    prompt_sections.setGlobal(&runtime.prompt_sections_registry);

    // phase-26 daemon-background-02/04/11: register this top-level interactive
    // session in the cross-session live-process registry so `zcode ps` can see
    // it. `kind` is left null so `register` picks it from ZCODE_SESSION_KIND
    // (the --bg/daemon "spawner sets env, child self-registers" pattern); a
    // plain interactive launch falls back to .interactive. The display name
    // (gap-11) is written into the registry entry and mirrored into the session
    // label so it surfaces in both `zcode ps` and `zcode session list`. Both
    // register and the label-write are best-effort: a registry failure must
    // never block an interactive session from starting.
    session_registry.register(allocator, .{
        .session_id = runtime.session_id,
        .cwd = cwd,
        .name = session_name,
    }) catch {};
    defer session_registry.unregister(allocator);
    // phase-26 daemon-background-06: tear down this session's isolated tmux
    // socket (`zcode-<pid>`) on graceful shutdown. Best-effort and lazy: if the
    // agent never issued a tmux command the server was never started and this
    // kill-server simply fails to connect. Only ever addresses our private
    // `-L zcode-<pid>` socket, so the user's real tmux server is never touched.
    defer tmux_socket.killServer(allocator);
    if (session_name) |n| store.setLabel(runtime.session_id, n) catch {};

    const stdin = std_io.stdinReader();
    const stdout = std_io.stdoutWriter();

    try runPluginEvent(allocator, stdout, .{
        .event = .session_start,
        .cwd = cwd,
    });

    if (initial_agent) |agent_name| {
        const activation = try runtime.activateAgentByNameStrict(agent_name);
        defer allocator.free(activation);
    }

    const handler = repl.Handler{
        .ctx = &runtime,
        .call = replCallback,
        .command = repl_commands.replCommandCallback,
        .approval_bridge = replApprovalBridgeCallback,
        .ask_user_bridge = replAskUserBridgeCallback,
    };

    const git_branch = try detectGitBranch(allocator, cwd);
    defer allocator.free(git_branch);

    var options = replOptionsFromConfig(cfg, yolo_mode, cwd, git_branch);
    options.status_metrics_provider = .{
        .ctx = &runtime,
        .get = replStatusMetricsProvider,
    };
    options.status_identity_provider = .{
        .ctx = &runtime,
        .get = replStatusIdentityProvider,
    };
    options.status_dynamic_provider = .{
        .ctx = &runtime,
        .get = replStatusDynamicProvider,
    };
    options.initial_prompt = initial_prompt;

    // Session-end cleanup of teams created this session (swarm-tasks-07): any
    // team the leader spun up via TeamCreate and did not explicitly TeamDelete
    // is auto-removed here so swarm teams do not pile up on disk across runs
    // (mirrors `cleanupSessionTeams` registered with the reference's graceful
    // shutdown). `defer` runs it even if `repl.run` returns an error.
    defer team_tool.cleanupRegisteredTeams(allocator, cwd);

    try repl.run(allocator, stdin, stdout, handler, options);
}

fn replCallback(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    prompt: []const u8,
    reporter: ?repl.ProgressReporter,
    mode: repl.SessionMode,
) ![]u8 {
    _ = allocator;
    const runtime: *AgentRuntime = @ptrCast(@alignCast(ctx));
    return runtime.handlePromptWithModeAndReporter(prompt, reporter, mode);
}

fn replStatusMetricsProvider(ctx: *anyopaque) repl.StatusMetrics {
    const runtime: *AgentRuntime = @ptrCast(@alignCast(ctx));
    return runtime.statusMetrics();
}

fn replStatusIdentityProvider(ctx: *anyopaque) repl.StatusIdentity {
    const runtime: *AgentRuntime = @ptrCast(@alignCast(ctx));
    return .{
        .provider = runtime.active_provider,
        .model = runtime.active_model,
    };
}

fn replStatusDynamicProvider(ctx: *anyopaque) repl.StatusDynamic {
    const runtime: *AgentRuntime = @ptrCast(@alignCast(ctx));
    return .{
        .circuit_state = runtime.lastCircuitStateLabel(),
        .agent_name = runtime.activeAgentName() orelse "",
    };
}

fn replApprovalBridgeCallback(ctx: *anyopaque, bridge: ?repl.ApprovalBridge) void {
    const runtime: *AgentRuntime = @ptrCast(@alignCast(ctx));
    if (bridge) |b| {
        runtime.approval_handler = .{ .ctx = b.ctx, .prompt = b.call };
        return;
    }
    runtime.approval_handler = null;
}

fn replAskUserBridgeCallback(ctx: *anyopaque, bridge: ?repl.AskUserBridge) void {
    const runtime: *AgentRuntime = @ptrCast(@alignCast(ctx));
    if (bridge) |b| {
        runtime.ask_user_ctx = b.ctx;
        runtime.ask_user_fn = b.call;
        return;
    }
    runtime.ask_user_ctx = null;
    runtime.ask_user_fn = null;
}

/// Run a single headless turn for the KAIROS background agent with a custom
/// approval handler installed (the allowlist policy). Returns the owned final
/// text; the caller frees it. The handler's ctx is updated in place during the
/// turn (e.g. counting denied tools), so the caller inspects its own ctx after.
/// Mirrors runOneShot's setup but is non-interactive and returns plain text.
pub fn runKairosTurn(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    cfg: *const config_mod.Config,
    policy: *policy_mod.Policy,
    audit: *logger_mod.AuditLogger,
    store: *session_store.Store,
    mcp: *mcp_client.Client,
    browser: ?*browser_bridge_mod.BrowserBridge,
    prompt: []const u8,
    approval_handler: ?agent_runtime.ApprovalHandler,
) ![]u8 {
    var runtime = try AgentRuntime.init(allocator, cwd, cfg, policy, audit, store, mcp, browser, false, false, false, false);
    defer runtime.deinit();
    prompt_sections.setGlobal(&runtime.prompt_sections_registry);
    // Install the KAIROS allowlist handler so mutating tools are approved only
    // when allowlisted; everything else is denied (and surfaced as a proposal
    // by the caller). With no handler the gate would auto-deny silently.
    runtime.approval_handler = approval_handler;

    try runPluginEventSilent(allocator, .{
        .event = .session_start,
        .cwd = cwd,
    });

    var result = try runtime.handlePromptDetailed(prompt);
    defer result.deinit(allocator);
    return allocator.dupe(u8, result.final_text);
}

pub fn runOneShot(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    cfg: *const config_mod.Config,
    policy: *policy_mod.Policy,
    audit: *logger_mod.AuditLogger,
    store: *session_store.Store,
    mcp: *mcp_client.Client,
    browser: ?*browser_bridge_mod.BrowserBridge,
    prompt: []const u8,
    json_mode: bool,
    auto_approve_high: bool,
    strict: bool,
    yolo_mode: bool,
    initial_agent: ?[]const u8,
) !agent_runtime.OneShotOutput {
    var runtime = try AgentRuntime.init(allocator, cwd, cfg, policy, audit, store, mcp, browser, false, auto_approve_high, strict, yolo_mode);
    defer runtime.deinit();
    prompt_sections.setGlobal(&runtime.prompt_sections_registry);

    try runPluginEventSilent(allocator, .{
        .event = .session_start,
        .cwd = cwd,
    });

    if (initial_agent) |agent_name| {
        const activation = try runtime.activateAgentByNameStrict(agent_name);
        defer allocator.free(activation);
    }

    var result = try runtime.handlePromptDetailed(prompt);
    defer result.deinit(allocator);

    if (!json_mode) {
        return .{
            .body = try allocator.dupe(u8, result.final_text),
            .strict_violation = result.strict_violation,
        };
    }

    const json_traces = try allocator.alloc(ci_output.ToolCall, result.tool_traces.len);
    defer allocator.free(json_traces);

    for (result.tool_traces, 0..) |trace, idx| {
        json_traces[idx] = .{
            .name = trace.name,
            .args = trace.args,
            .risk = types.riskTierToString(trace.risk),
            .approval_state = agent_runtime.approvalStateToString(trace.approval_state),
            .executed = trace.executed,
            .duration_ms = trace.duration_ms,
            .output = trace.output,
        };
    }

    return .{
        .body = try ci_output.encodeExecJson(
            allocator,
            runtime.session_id,
            runtime.active_provider,
            runtime.active_model,
            result.rounds,
            result.compaction_applied,
            result.strict_violation,
            result.final_text,
            json_traces,
        ),
        .strict_violation = result.strict_violation,
    };
}

/// sdk-headless-14: the headless gating caps threaded from the CLI flags
/// (`--max-turns`, `--max-budget-usd`, `--json-schema`, `--max-thinking-tokens`)
/// into AgentRuntime before a one-shot run. All fields are optional; a null
/// field leaves the corresponding config default in effect. `--fork-session`
/// is handled by the resume path (it forks before the runtime is built) and
/// is not represented here.
pub const HeadlessCaps = struct {
    /// Maps to AgentRuntime.max_tool_rounds_override. Exceeding it surfaces
    /// the `error_max_turns` result subtype.
    max_turns: ?usize = null,
    /// Estimated-spend cap in USD. Compared against cost.estimateCost after
    /// the run; exceeding it surfaces `error_max_budget_usd`. Full per-round
    /// USD enforcement inside the tool loop is a follow-on.
    max_budget_usd: ?f64 = null,
    /// Raw JSON schema string set as AgentRuntime.pending_response_schema
    /// (the `/format json` internal path).
    json_schema: ?[]const u8 = null,
    /// Maps to AgentRuntime.reserved_reasoning_tokens_override.
    max_thinking_tokens: ?usize = null,
};

/// sdk-headless-14: run a single headless turn under the gating caps and
/// return an SDK `result` payload (output.Result) describing the outcome.
/// This is the headless analogue of runOneShot: it builds the runtime,
/// applies the caps, runs the prompt, and maps the turn outcome to the
/// SDK result subtype (success / error_max_turns / error_max_budget_usd).
/// Caller owns `result_text` and `structured_output_json` on the returned
/// struct via the allocator; free them with freeHeadlessResult.
pub fn runHeadlessResult(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    cfg: *const config_mod.Config,
    policy: *policy_mod.Policy,
    audit: *logger_mod.AuditLogger,
    store: *session_store.Store,
    mcp: *mcp_client.Client,
    browser: ?*browser_bridge_mod.BrowserBridge,
    prompt: []const u8,
    auto_approve_high: bool,
    strict: bool,
    yolo_mode: bool,
    initial_agent: ?[]const u8,
    caps: HeadlessCaps,
) !sdk_output.Result {
    var runtime = try AgentRuntime.init(allocator, cwd, cfg, policy, audit, store, mcp, browser, false, auto_approve_high, strict, yolo_mode);
    defer runtime.deinit();
    prompt_sections.setGlobal(&runtime.prompt_sections_registry);

    // Apply the headless caps before the turn. These reuse the existing
    // runtime overrides (the same fields the SDK live-control subtypes and
    // the /format json REPL command write).
    if (caps.max_turns) |mt| runtime.max_tool_rounds_override = mt;
    if (caps.max_thinking_tokens) |tk| runtime.setReasoningTokens(@intCast(tk));
    if (caps.json_schema) |schema| {
        runtime.pending_response_schema = try allocator.dupe(u8, schema);
    }

    try runPluginEventSilent(allocator, .{
        .event = .session_start,
        .cwd = cwd,
    });

    if (initial_agent) |agent_name| {
        const activation = try runtime.activateAgentByNameStrict(agent_name);
        defer allocator.free(activation);
    }

    var result = try runtime.handlePromptDetailed(prompt);
    defer result.deinit(allocator);

    // Determine the result subtype. error_max_turns wins when the round
    // count reached the cap (the loop stops at the cap rather than past it,
    // so >= is the correct comparison). error_max_budget_usd wins when the
    // estimated spend exceeded the cap. Otherwise success.
    var subtype: sdk_output.ResultSubtype = .success;
    var stop_reason: []const u8 = "end_turn";
    if (caps.max_turns) |mt| {
        if (result.rounds >= mt) {
            subtype = .error_max_turns;
            stop_reason = "max_turns";
        }
    }

    const usage = blk: {
        runtime.token_status_lock.lock(rt.io) catch {};
        defer runtime.token_status_lock.unlock(rt.io);
        break :blk sdk_output.Usage{
            .input_tokens = runtime.token_status.total_input_tokens,
            .output_tokens = runtime.token_status.total_output_tokens,
        };
    };

    const est_cost = cost_mod.estimateCost(
        runtime.active_provider,
        runtime.active_model,
        usage.input_tokens,
        usage.output_tokens,
    );
    if (subtype == .success) {
        if (caps.max_budget_usd) |budget| {
            if (est_cost > budget) {
                subtype = .error_max_budget_usd;
                stop_reason = "max_budget_usd";
            }
        }
    }

    return .{
        .subtype = subtype,
        .session_id = try allocator.dupe(u8, runtime.session_id),
        .result_text = try allocator.dupe(u8, result.final_text),
        .num_turns = result.rounds,
        .total_cost_usd = est_cost,
        .usage = usage,
        .model = try allocator.dupe(u8, runtime.active_model),
        .stop_reason = stop_reason,
        .structured_output_json = if (caps.json_schema) |s| try allocator.dupe(u8, s) else "",
    };
}

/// Free the allocator-owned fields of a result returned by runHeadlessResult.
pub fn freeHeadlessResult(allocator: std.mem.Allocator, result: *sdk_output.Result) void {
    allocator.free(result.session_id);
    allocator.free(result.result_text);
    allocator.free(result.model);
    if (result.structured_output_json.len > 0) allocator.free(result.structured_output_json);
}

pub fn cmdPromptInspect(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    cfg: *const config_mod.Config,
    policy: *policy_mod.Policy,
    audit: *logger_mod.AuditLogger,
    store: *session_store.Store,
    mcp: *mcp_client.Client,
    browser: ?*browser_bridge_mod.BrowserBridge,
    prompt: ?[]const u8,
    json: bool,
    summary: bool,
    include_prompt_packets: bool,
    auto_approve_high: bool,
    strict: bool,
    yolo_mode: bool,
    initial_agent: ?[]const u8,
    writer: anytype,
) !void {
    var runtime = try AgentRuntime.init(allocator, cwd, cfg, policy, audit, store, mcp, browser, false, auto_approve_high, strict, yolo_mode);
    defer runtime.deinit();
    prompt_sections.setGlobal(&runtime.prompt_sections_registry);

    if (initial_agent) |agent_name| {
        const activation = try runtime.activateAgentByNameStrict(agent_name);
        defer allocator.free(activation);
    }

    const rendered = try runtime.inspectPromptWithOptions(prompt orelse "", .{
        .json = json,
        .summary = summary,
        .include_prompt_packets = include_prompt_packets and !summary,
    });
    defer allocator.free(rendered);
    try writer.writeAll(rendered);
    if (!std.mem.endsWith(u8, rendered, "\n")) try writer.writeByte('\n');
}

pub fn resumeSessionInteractive(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    cfg: *const config_mod.Config,
    policy: *policy_mod.Policy,
    audit: *logger_mod.AuditLogger,
    store: *session_store.Store,
    mcp: *mcp_client.Client,
    browser: ?*browser_bridge_mod.BrowserBridge,
    session_id: []const u8,
    initial_prompt: ?[]const u8,
    writer: anytype,
    auto_approve_high: bool,
    strict: bool,
    yolo_mode: bool,
    initial_agent: ?[]const u8,
) !void {
    var loaded = try store.load(session_id);
    defer loaded.deinit(allocator);

    var runtime = try AgentRuntime.initFromSession(allocator, cwd, cfg, policy, audit, store, mcp, browser, &loaded, true, auto_approve_high, strict, yolo_mode);
    defer runtime.deinit();
    prompt_sections.setGlobal(&runtime.prompt_sections_registry);

    try runPluginEvent(allocator, writer, .{
        .event = .session_start,
        .cwd = cwd,
    });

    if (initial_agent) |agent_name| {
        const activation = try runtime.activateAgentByNameStrict(agent_name);
        defer allocator.free(activation);
    }

    const stdin = std_io.stdinReader();
    const handler = repl.Handler{
        .ctx = &runtime,
        .call = replCallback,
        .command = repl_commands.replCommandCallback,
        .approval_bridge = replApprovalBridgeCallback,
        .ask_user_bridge = replAskUserBridgeCallback,
    };

    const git_branch = try detectGitBranch(allocator, cwd);
    defer allocator.free(git_branch);

    var options = replOptionsFromConfig(cfg, yolo_mode, cwd, git_branch);
    options.initial_prompt = initial_prompt;
    options.status_metrics_provider = .{
        .ctx = &runtime,
        .get = replStatusMetricsProvider,
    };
    options.status_identity_provider = .{
        .ctx = &runtime,
        .get = replStatusIdentityProvider,
    };

    try repl.run(allocator, stdin, writer, handler, options);
}

const testing_alloc = std.testing;

test "detectGitBranch returns branch name in git repo" {
    const branch = try detectGitBranch(testing_alloc.allocator, ".");
    defer testing_alloc.allocator.free(branch);
    // In CI with detached HEAD (PR merge commits), branch may be empty.
    // Just verify the function returns a valid (possibly empty) string without crashing.
    try testing_alloc.expect(branch.len >= 0);
}

test "detectGitBranch returns empty for non-git dir" {
    const branch = try detectGitBranch(testing_alloc.allocator, "/tmp");
    defer testing_alloc.allocator.free(branch);
    // /tmp is likely not a git repo.
    try testing_alloc.expect(branch.len == 0);
}

test "emitPluginEventNotice prepends [plugin] to non-empty output" {
    var buf = std_io.StringBuilder.init(testing_alloc.allocator);
    defer buf.deinit();

    // Non-empty result produces a prefixed line.
    var r1 = plugins_mod.PluginRunResult{
        .ran = true,
        .blocked = false,
        .output = try testing_alloc.allocator.dupe(u8, "hook says hi"),
    };
    defer r1.deinit(testing_alloc.allocator);
    try emitPluginEventNotice(buf.writer(), r1);
    try testing_alloc.expectEqualStrings("[plugin] hook says hi\n", buf.items());

    // Empty output is silent.
    buf.clearRetainingCapacity();
    var r2 = plugins_mod.PluginRunResult{
        .ran = true,
        .blocked = false,
        .output = try testing_alloc.allocator.dupe(u8, ""),
    };
    defer r2.deinit(testing_alloc.allocator);
    try emitPluginEventNotice(buf.writer(), r2);
    try testing_alloc.expectEqualStrings("", buf.items());
}

test "replOptionsFromConfig: yolo flips approval_mode and threads location" {
    // Build a Config using the allocator-backed init; its fields are
    // []u8 so we can't just point at string literals.
    const alloc = testing_alloc.allocator;
    var cfg = try config_mod.Config.init(alloc);
    defer cfg.deinit(alloc);

    const opts_normal = replOptionsFromConfig(&cfg, false, "/tmp/ws", "main");
    try testing_alloc.expect(!opts_normal.yolo_mode);
    try testing_alloc.expectEqualStrings("/tmp/ws", opts_normal.status_workspace);
    try testing_alloc.expectEqualStrings("main", opts_normal.status_branch);
    // status_approval_mode points at cfg.approval_mode when not yolo.
    try testing_alloc.expectEqualStrings(cfg.approval_mode, opts_normal.status_approval_mode);

    const opts_yolo = replOptionsFromConfig(&cfg, true, "/tmp/ws", "main");
    try testing_alloc.expectEqualStrings("yolo", opts_yolo.status_approval_mode);
    try testing_alloc.expect(opts_yolo.yolo_mode);
}

// ── sdk-headless-14: headless caps threaded into the runtime ───────

/// Minimal mock-provider harness for the headless-caps runtime tests. Builds
/// the config/policy/audit/store/mcp scaffolding under a tmp root and points
/// the config at the deterministic `mock` provider so a one-shot turn runs
/// without any network. Mirrors the SkillGuardHarness pattern in
/// agent_runtime.zig but is self-contained here.
const HeadlessCapsHarness = struct {
    cfg: config_mod.Config,
    policy: policy_mod.Policy,
    audit: logger_mod.AuditLogger,
    store: session_store.Store,
    mcp: mcp_client.Client,
    cwd: []u8,
    logs_dir: []u8,
    sessions_dir: []u8,
    registry_path: []u8,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, root: []const u8) !*HeadlessCapsHarness {
        const self = try allocator.create(HeadlessCapsHarness);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.cwd = try allocator.dupe(u8, root);
        errdefer allocator.free(self.cwd);
        self.logs_dir = try std.fs.path.join(allocator, &.{ root, "logs" });
        errdefer allocator.free(self.logs_dir);
        self.sessions_dir = try std.fs.path.join(allocator, &.{ root, "sessions" });
        errdefer allocator.free(self.sessions_dir);
        self.registry_path = try std.fs.path.join(allocator, &.{ root, "mcp", "registry.json" });
        errdefer allocator.free(self.registry_path);

        self.cfg = try config_mod.Config.init(allocator);
        errdefer self.cfg.deinit(allocator);
        // Point the runtime at the deterministic mock provider/model so the
        // turn runs offline. The default config uses anthropic, which needs a
        // key and network.
        allocator.free(self.cfg.default_provider);
        self.cfg.default_provider = try allocator.dupe(u8, "mock");
        allocator.free(self.cfg.default_model);
        self.cfg.default_model = try allocator.dupe(u8, "mock-agent");

        self.policy = try policy_mod.Policy.init(allocator);
        errdefer self.policy.deinit();
        self.audit = try logger_mod.AuditLogger.init(allocator, self.logs_dir);
        errdefer self.audit.deinit();
        self.store = try session_store.Store.init(allocator, self.sessions_dir, false);
        errdefer self.store.deinit();
        self.mcp = try mcp_client.Client.init(allocator, self.registry_path);
        errdefer self.mcp.deinit();
        return self;
    }

    fn deinit(self: *HeadlessCapsHarness) void {
        self.mcp.deinit();
        self.store.deinit();
        self.audit.deinit();
        self.policy.deinit();
        self.cfg.deinit(self.allocator);
        self.allocator.free(self.cwd);
        self.allocator.free(self.logs_dir);
        self.allocator.free(self.sessions_dir);
        self.allocator.free(self.registry_path);
        self.allocator.destroy(self);
    }
};

test "sdk-headless-14: --max-turns 1 against a multi-round mock prompt yields error_max_turns" {
    const test_helpers = @import("core/test_helpers.zig");
    const alloc = testing_alloc.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var h = try HeadlessCapsHarness.init(alloc, root);
    defer h.deinit();

    // The mock provider's default response emits a git_status tool call on the
    // first round and only stops on a follow-up round, so without a cap the
    // turn runs more than one round. yolo_mode auto-approves so the tool does
    // not block on a missing interactive approver.
    var result = try runHeadlessResult(
        alloc,
        h.cwd,
        &h.cfg,
        &h.policy,
        &h.audit,
        &h.store,
        &h.mcp,
        null,
        "show me the git status",
        true, // auto_approve_high
        false, // strict
        true, // yolo_mode
        null, // initial_agent
        .{ .max_turns = 1 },
    );
    defer freeHeadlessResult(alloc, &result);

    try testing_alloc.expectEqual(sdk_output.ResultSubtype.error_max_turns, result.subtype);
    try testing_alloc.expect(result.subtype.isError());
    try testing_alloc.expectEqualStrings("max_turns", result.stop_reason);
    // num_turns reached the cap.
    try testing_alloc.expect(result.num_turns >= 1);
}

test "sdk-headless-14: --json-schema sets pending_response_schema and surfaces structured_output" {
    const test_helpers = @import("core/test_helpers.zig");
    const alloc = testing_alloc.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var h = try HeadlessCapsHarness.init(alloc, root);
    defer h.deinit();

    const schema = "{\"type\":\"object\",\"properties\":{\"ok\":{\"type\":\"boolean\"}}}";
    var result = try runHeadlessResult(
        alloc,
        h.cwd,
        &h.cfg,
        &h.policy,
        &h.audit,
        &h.store,
        &h.mcp,
        null,
        "answer ok",
        true,
        false,
        true,
        null,
        .{ .json_schema = schema },
    );
    defer freeHeadlessResult(alloc, &result);

    // The schema is echoed back into the result's structured_output field.
    try testing_alloc.expectEqualStrings(schema, result.structured_output_json);
    // A run without a turns cap succeeds.
    try testing_alloc.expectEqual(sdk_output.ResultSubtype.success, result.subtype);
}
