const std = @import("std");
const std_io = @import("../core/std_io.zig");
const rt = @import("zcode_runtime");
const clock = @import("../core/clock.zig");
const removed_commands = @import("../core/removed_commands.zig");
const sandbox_mod = @import("../core/sandbox.zig");
const kairos_lock = @import("../core/kairos_lock.zig");
const kairos_brief_mod = @import("../core/kairos_brief.zig");
const types = @import("../core/types.zig");
const permission_decision = @import("../core/permission_decision.zig");
const output_styles_mod = @import("../core/output_styles.zig");
const tool_helpers = @import("../tools/helpers.zig");
const platform_mod = @import("../core/platform.zig");
const clipboard_mod = @import("../core/clipboard.zig");
const ui_theme = @import("../core/ui_theme.zig");
const config_parse = @import("../core/config_parse.zig");
const onboarding_mod = @import("../core/onboarding.zig");
const skill_usage_mod = @import("../core/skill_usage.zig");
const tips_mod = @import("../core/tips.zig");
const runtime_state_mod = @import("../core/runtime_state.zig");
const changelog_mod = @import("../core/changelog.zig");
const cancel_reason_mod = @import("../core/cancel_reason.zig");
const build_options = @import("build_options");

// ── Sub-modules: focused modules split from this file by responsibility ──
// Each sub-module is independently compilable and testable.
// repl.zig remains the entry point that callers import.
pub const repl_spinner_mod = @import("repl_spinner.zig");
pub const repl_input_mod = @import("repl_input.zig");
pub const repl_markdown_mod = @import("repl_markdown.zig");
pub const repl_edit_mod = @import("repl_edit.zig");
pub const repl_render_mod = @import("repl_render.zig");
pub const repl_overlay_mod = @import("repl_overlay.zig");
pub const repl_help_mod = @import("repl_help.zig");
pub const repl_history_mod = @import("repl_history.zig");
pub const repl_global_search_mod = @import("repl_global_search.zig");
pub const repl_image_paste_mod = @import("repl_image_paste.zig");
pub const repl_attachments_mod = @import("repl_attachments.zig");
pub const repl_quick_open_mod = @import("repl_quick_open.zig");
pub const repl_prompt_editor_mod = @import("repl_prompt_editor.zig");
pub const repl_text_paste_mod = @import("repl_text_paste.zig");
pub const repl_interactive_shell_mod = @import("repl_interactive_shell.zig");
pub const bash_input_framing_mod = @import("../core/bash_input_framing.zig");
pub const repl_vim_mod = @import("repl_vim.zig");
pub const keybindings_mod = @import("keybindings.zig");
pub const repl_footer_mod = @import("repl_footer.zig");
const figures = @import("../core/figures.zig");
const thinking_render = @import("../core/thinking_render.zig");
const memory_mod = @import("../core/memory.zig");
const trust_mod = @import("../core/trust.zig");
const trust_capabilities_mod = @import("../core/trust_capabilities.zig");
const feedback_survey_mod = @import("../core/feedback_survey.zig");
const memory_messages_mod = @import("../core/memory_messages.zig");
const rng_mod = @import("../core/rng.zig");
const terminal_caps_mod = @import("../core/terminal_caps.zig");
const progress_osc_mod = @import("../core/progress_osc.zig");
const agent_isolation_mod = @import("../core/agent_isolation.zig");

const MOUSE_WHEEL_SCROLL_ROWS: usize = 3;

/// Goodbye lines shown on `/exit` / `/quit`. Mirrors the reference
/// ExitFlow.tsx GOODBYE_MESSAGES so the farewell varies across runs.
const GOODBYE_MESSAGES = [_][]const u8{ "Goodbye!", "See ya!", "Bye!", "Catch you later!" };

/// Pick a goodbye line at random. Uses the project rng shim (rng.bytes via
/// uintLessThanBiased), not std.crypto.random, per project convention. The
/// selection is non-security-sensitive so the cheap biased path is fine.
fn randomGoodbye() []const u8 {
    const idx = rng_mod.uintLessThanBiased(usize, GOODBYE_MESSAGES.len);
    return GOODBYE_MESSAGES[idx];
}

/// True when `cwd` is inside a zcode-managed git worktree. zcode creates these
/// under `<base>/.zcode/worktrees/agent-<suffix>` (see agent_isolation.zig);
/// we detect membership by looking for that path segment so the exit flow can
/// offer to clean the worktree up, mirroring ExitFlow.tsx's WorktreeExitDialog
/// branch. Pure string check - no IO.
fn inManagedWorktree(cwd: []const u8) bool {
    return std.mem.indexOf(u8, cwd, "/.zcode/worktrees/agent-") != null;
}

pub const ProgressReporter = struct {
    ctx: *anyopaque,
    update: *const fn (ctx: *anyopaque, summary: []const u8) void,
    emit_edit_block: ?*const fn (ctx: *anyopaque, path: []const u8, old_text: []const u8, new_text: []const u8, start_line: usize, success: bool) void = null,
    emit_stream_chunk: ?*const fn (ctx: *anyopaque, chunk: []const u8) void = null,
    end_stream: ?*const fn (ctx: *anyopaque) void = null,
    emit_tool_output: ?*const fn (ctx: *anyopaque, tool_name: []const u8, tool_detail: []const u8, output: []const u8) void = null,
    emit_diff_block: ?*const fn (ctx: *anyopaque, diff_text: []const u8) void = null,
    /// Returns true if the user has requested cancellation (e.g. via Escape key).
    is_cancelled: ?*const fn (ctx: *anyopaque) bool = null,
    /// Returns WHY the current cancel fired (hard Esc-Esc/Ctrl+C vs a
    /// submit-interrupt where the user enqueued a new prompt mid-turn). The
    /// agent loop's abort path reads this to suppress the standalone
    /// interruption turn on a submit-interrupt (task 22.1). Callers that do
    /// not provide it default to `.hard` so the interruption is recorded.
    cancel_reason: ?*const fn (ctx: *anyopaque) cancel_reason_mod.CancelReason = null,

    /// The cancel reason for this turn, defaulting to `.hard` when no getter
    /// is wired. Keeps the abort path agnostic about whether the reporter
    /// exposes a reason (test stubs and headless callers may not).
    pub fn cancelReason(self: ProgressReporter) cancel_reason_mod.CancelReason {
        if (self.cancel_reason) |getter| return getter(self.ctx);
        return .hard;
    }
};

pub const SessionMode = enum {
    execution,
    planning,
    brainstorm,
    review,
};

pub const UiDensity = enum {
    full,
    clean,
};

pub fn parseUiDensity(raw: []const u8) ?UiDensity {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "full")) return .full;
    if (std.mem.eql(u8, trimmed, "clean")) return .clean;
    return null;
}

pub fn formatUiDensity(density: UiDensity) []const u8 {
    return switch (density) {
        .full => "full",
        .clean => "clean",
    };
}

pub const Handler = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, prompt: []const u8, reporter: ?ProgressReporter, mode: SessionMode) anyerror![]u8,
    command: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, command: []const u8) anyerror!?[]u8 = null,
    approval_bridge: ?*const fn (ctx: *anyopaque, bridge: ?ApprovalBridge) void = null,
    ask_user_bridge: ?*const fn (ctx: *anyopaque, bridge: ?AskUserBridge) void = null,
};

pub const ApprovalBridge = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, message: []const u8) anyerror!types.ApprovalResponse,
};

pub const AskUserBridge = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, question: []const u8, choices: []const []const u8) anyerror![]u8,
};

pub const Options = struct {
    prompt_label: []const u8 = ">",
    app_version: []const u8 = "dev",
    status_provider: []const u8 = "unknown",
    status_model: []const u8 = "unknown",
    status_workspace: []const u8 = "",
    status_branch: []const u8 = "",
    status_model_context_window: usize = 0,
    status_approval_mode: []const u8 = "tiered-auto",
    status_sandbox: []const u8 = "workspace-write",
    status_show_workspace: bool = true,
    status_show_model: bool = true,
    status_show_safety: bool = true,
    status_show_tokens: bool = true,
    status_show_hint: bool = true,
    /// Circuit breaker state for the current provider. Hidden when
    /// empty or "closed" to avoid visual noise in the happy path.
    status_circuit_state: []const u8 = "",
    /// Active agent name. Rendered as `@<name>` when non-empty so the
    /// user can see at a glance which sub-agent is handling requests.
    status_agent_name: []const u8 = "",
    yolo_mode: bool = false,
    color_enabled: bool = true,
    theme_setting: ui_theme.ThemeSetting = .dark,
    theme: ui_theme.ThemeName = .dark,
    highlight_links: bool = true,
    highlight_paths: bool = true,
    color_lists: bool = true,
    highlight_code_blocks: bool = true,
    enable_fullscreen: bool = true,
    enable_alt_screen: bool = true,
    /// Wrap each full-screen redraw in DEC 2026 BSU/ESU so the frame lands
    /// atomically (no flicker) on capable terminals. Set once at startup from
    /// terminal_caps.isSynchronizedOutputSupported(); only meaningful on the
    /// alt-screen full-redraw path.
    enable_synchronized_output: bool = false,
    enable_spinner: bool = true,
    enable_thinking_summary: bool = true,
    brief_mode: bool = false,
    ui_density: UiDensity = .full,
    ui_leader_key: []const u8 = "ctrl+x",
    show_top_bar: bool = true,
    shortcuts_panel_enabled: bool = true,
    shortcuts_panel_visible: bool = false,
    vim_mode_enabled: bool = false,
    input_mode_label: []const u8 = "",
    prompt_placeholder: []const u8 = "",
    prompt_suggestion: []const u8 = "",
    inline_ghost_text: []const u8 = "",
    queued_prompt_notice: []const u8 = "",
    prompt_strip_items: []const repl_footer_mod.StripItem = &.{},
    prompt_strip_selection: ?usize = null,
    footer_rows: []const repl_footer_mod.Row = &.{},
    footer_row_selection: ?usize = null,
    attachment_store: ?*const repl_attachments_mod.Store = null,
    reference_suggestions: []const ReferenceSuggestion = &.{},
    reference_suggestion_selection: usize = 0,
    stashed_prompt_available: bool = false,
    auto_mode_opted_in: bool = false,
    /// ui-dialogs-02: the persisted `skip_dangerous_mode_permission_prompt`
    /// flag. When true the BypassPermissionsMode warning gate is suppressed
    /// (the user already accepted it on a prior launch).
    skip_dangerous_mode_permission_prompt: bool = false,
    /// ui-dialogs-05: the persisted `ui_idle_return_never_ask` flag. When true
    /// the return-from-idle nudge is suppressed (the user picked "Don't ask me
    /// again" on a prior session). Consumed by the idle-return gate at the
    /// submit boundary.
    ui_idle_return_never_ask: bool = false,
    footer_tasks_state: []const u8 = "",
    footer_teams_state: []const u8 = "",
    footer_bridge_state: []const u8 = "",
    footer_agent_state: []const u8 = "",
    footer_tmux_state: []const u8 = "",
    footer_worktree_state: []const u8 = "",
    show_transcript: bool = true,
    transcript_max_lines: usize = 20_000,
    show_scroll_hint: bool = true,
    bottom_margin_rows: usize = 2,
    transcript_line_spacing: usize = 1,
    status_metrics_provider: ?StatusMetricsProvider = null,
    status_identity_provider: ?StatusIdentityProvider = null,
    status_dynamic_provider: ?StatusDynamicProvider = null,
    initial_prompt: ?[]const u8 = null,
    keybindings: ?*const keybindings_mod.RuntimeKeybindings = null,
    /// Spinner-tips overrides (styles-onboarding-07). Sourced from cfg by the
    /// Options builder. `spinner_tips_enabled` gates the passive spinner tip;
    /// `spinner_tips_custom` is the user's delimited custom-tip list;
    /// `spinner_tips_exclude_default` suppresses the built-in registry.
    spinner_tips_enabled: bool = true,
    spinner_tips_custom: []const u8 = "",
    spinner_tips_exclude_default: bool = false,
};

pub const StatusMetrics = struct {
    last_prompt_tokens: usize = 0,
    last_input_tokens: usize = 0,
    last_output_tokens: usize = 0,
    total_input_tokens: usize = 0,
    total_output_tokens: usize = 0,
    last_cache_hints: usize = 0,
    last_budget_input: usize = 0,
    estimated_session_cost_cents: usize = 0,
};

pub const StatusMetricsProvider = struct {
    ctx: *anyopaque,
    get: *const fn (ctx: *anyopaque) StatusMetrics,
};

pub const StatusIdentity = struct {
    provider: []const u8 = "unknown",
    model: []const u8 = "unknown",
};

pub const StatusIdentityProvider = struct {
    ctx: *anyopaque,
    get: *const fn (ctx: *anyopaque) StatusIdentity,
};

/// Snapshot of dynamic session chips the status bar may surface.
/// Populated by a callback so the REPL options struct stays static
/// and can be stack-built once at session init. `circuit_state` is
/// the stable label from providers/circuit_breaker.zig; empty slice
/// or "closed" suppresses the chip. `agent_name` is empty when the
/// default agent is active.
pub const StatusDynamic = struct {
    circuit_state: []const u8 = "",
    agent_name: []const u8 = "",
};

pub const StatusDynamicProvider = struct {
    ctx: *anyopaque,
    get: *const fn (ctx: *anyopaque) StatusDynamic,
};

const UiTranscript = repl_spinner_mod.UiTranscript;

// Spinner/progress types and callbacks delegated to sub-modules
const SpinnerState = repl_spinner_mod.SpinnerState;
const ThinkingSpinner = repl_spinner_mod.ThinkingSpinner;

const repl_agent_mod = @import("repl_agent.zig");

const ApprovalUiContext = struct {
    spinner: *ThinkingSpinner,
    spinner_state: *SpinnerState,
    use_fullscreen: bool,
    spinner_enabled: bool,
    bottom_margin_rows: usize,
    // P3 (PRD #534): live permission mode for Shift+Tab cycling inside the
    // approval overlay. Null when no reference mode is active (legacy
    // tiered-auto/manual/strict sessions) so the overlay header is unchanged.
    permission_mode: ?*permission_decision.Mode = null,
    bypass_available: bool = false,
};

const AskUserUiContext = struct {
    spinner: *ThinkingSpinner,
    spinner_state: *SpinnerState,
    use_fullscreen: bool,
    spinner_enabled: bool,
    bottom_margin_rows: usize,
};

fn replApprovalPrompt(ctx: *anyopaque, message: []const u8) !types.ApprovalResponse {
    const ui: *ApprovalUiContext = @ptrCast(@alignCast(ctx));
    const was_active = ui.spinner.active;
    if (was_active) ui.spinner.stop();
    defer if (was_active) ui.spinner.start(ui.spinner_state, ui.use_fullscreen, ui.bottom_margin_rows, ui.spinner_enabled);

    const decision = if (ui.use_fullscreen)
        try repl_overlay_mod.runApprovalOverlayLoopWithMode(message, ui.bottom_margin_rows, ui.permission_mode, ui.bypass_available)
    else
        try repl_overlay_mod.runInlineApprovalPrompt(message);

    return switch (decision) {
        .approve => .approve,
        .approve_always => .approve_always,
        .deny => .deny,
        .cancel => .deny,
    };
}

fn replAskUserPrompt(ctx: *anyopaque, allocator: std.mem.Allocator, question: []const u8, choices: []const []const u8) ![]u8 {
    const ui: *AskUserUiContext = @ptrCast(@alignCast(ctx));
    const was_active = ui.spinner.active;
    if (was_active) ui.spinner.stop();
    defer if (was_active) ui.spinner.start(ui.spinner_state, ui.use_fullscreen, ui.bottom_margin_rows, ui.spinner_enabled);

    if (ui.use_fullscreen) {
        return repl_overlay_mod.runAskUserOverlayLoop(allocator, question, choices, ui.bottom_margin_rows);
    }
    return repl_overlay_mod.runInlineAskUserPrompt(allocator, question, choices);
}

fn canUseFullScreenUi() bool {
    return repl_spinner_mod.canUseFullScreenUi();
}

fn boundedBottomMarginRows(total_rows: usize, requested: usize) usize {
    return repl_spinner_mod.boundedBottomMarginRows(total_rows, requested);
}

fn replProgressUpdate(ctx: *anyopaque, summary: []const u8) void {
    repl_agent_mod.replProgressUpdate(ctx, summary);
}

fn replEmitEditBlock(ctx: *anyopaque, path: []const u8, old_text: []const u8, new_text: []const u8, start_line: usize, success: bool) void {
    repl_agent_mod.replEmitEditBlock(ctx, path, old_text, new_text, start_line, success);
}

fn replEmitStreamChunk(ctx: *anyopaque, chunk: []const u8) void {
    repl_agent_mod.replEmitStreamChunk(ctx, chunk);
}

fn replEndStream(ctx: *anyopaque) void {
    repl_agent_mod.replEndStream(ctx);
}

fn replEmitToolOutput(ctx: *anyopaque, tool_name: []const u8, tool_detail: []const u8, output: []const u8) void {
    repl_agent_mod.replEmitToolOutput(ctx, tool_name, tool_detail, output);
}

fn replEmitDiffBlock(ctx: *anyopaque, diff_text: []const u8) void {
    repl_agent_mod.replEmitDiffBlock(ctx, diff_text);
}

fn replIsCancelled(ctx: *anyopaque) bool {
    return repl_agent_mod.replIsCancelled(ctx);
}

/// Read the global cancel reason set by the spinner's cancel handler
/// (`http_common.requestCancel`). The agent loop's abort path uses this to
/// distinguish a hard interrupt from a submit-interrupt (task 22.1).
fn replCancelReason(ctx: *anyopaque) cancel_reason_mod.CancelReason {
    _ = ctx;
    return @import("../providers/common.zig").cancelReason();
}

/// Context for the live-scroll redraw hook. Stores pointers to the
/// main-thread state the spinner thread needs to re-render the
/// transcript window when a scroll event arrives during thinking.
///
/// Lifetime: owned by the main REPL loop, reused across turns. The
/// spinner thread holds a `*anyopaque` copy via SpinnerState and
/// calls `liveScrollRedraw` below to trigger the redraw.
///
/// The callback renders into a scratch buffer first and then
/// emits the bytes via posix.write, which sidesteps the usual
/// `writer: anytype` plumbing (we can't store an `anytype` writer
/// in a struct). The buffer lives in the main REPL scope so the
/// callback never allocates in the hot path.
const LiveScrollContext = struct {
    transcript: *const UiTranscript,
    scroll_offset: *usize,
    allocator: std.mem.Allocator,
    options: *const Options,
    mode: *SessionMode,
    hint_buf: *[320]u8,
    hint_len: *usize,
    use_fullscreen: bool,
    write_mutex: *std.Io.Mutex,
    spinner_state: *SpinnerState,
    scratch: *std_io.StringBuilder,
};

/// LiveRedrawCallback implementation: apply the scroll delta to the
/// caller's scroll_offset, then redraw the whole transcript via
/// renderFullScreen. We serialize against the spinner's stdout
/// writes with write_mutex so the live redraw and the spinner's
/// status line don't interleave mid-frame.
///
/// NOTE on the "double-apply" fix: previously this function updated
/// `scroll_offset` directly while the spinner's scroll_offset_delta
/// atomic was also accumulating the same delta. When the turn ended,
/// the post-turn code in `run()` re-applied scroll_offset_delta on
/// top of the live-updated scroll_offset, effectively scrolling
/// twice. We now clear scroll_offset_delta to zero at the tail of
/// this function so the post-turn apply is a no-op.
fn liveScrollRedraw(ctx: *anyopaque, delta: i32) void {
    const lsc: *LiveScrollContext = @ptrCast(@alignCast(ctx));
    if (!lsc.use_fullscreen) return;

    // Debug trace (opt-in via ZCODE_DEBUG_SCROLL=1). Dumps to stderr
    // so it doesn't interfere with terminal output on stdout. Used
    // when diagnosing "smooth scroll doesn't work" reports.
    const trace = @import("../core/env.zig").getenv("ZCODE_DEBUG_SCROLL") != null;
    if (trace) {
        var trace_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&trace_buf, "[scroll] delta={d} before_offset={d}\n", .{ delta, lsc.scroll_offset.* }) catch "";
        _ = std.c.write(std.Io.File.stderr().handle, (msg).ptr, (msg).len);
    }

    lsc.write_mutex.lock(rt.io) catch {};
    defer lsc.write_mutex.unlock(rt.io);

    // Apply the delta. Positive = user scrolled UP (see older
    // content); negative = scrolled DOWN. Saturating arithmetic so
    // we can't underflow past zero at the "live" boundary.
    if (delta > 0) {
        lsc.scroll_offset.* +|= @intCast(delta);
    } else if (delta < 0) {
        lsc.scroll_offset.* -|= @as(usize, @intCast(-delta));
    }

    // Clear the spinner's delta so the post-turn apply is a no-op.
    // The caller now owns the offset state entirely.
    lsc.spinner_state.scroll_offset_delta.store(0, .release);

    // Render into a retained buffer so live wheel bursts do not
    // allocate on every frame.
    lsc.scratch.clearRetainingCapacity();
    const adapter = lsc.scratch.writer();
    repl_render_mod.renderFullScreen(
        adapter,
        lsc.transcript,
        false, // show_prompt -- we're mid-turn, no prompt shown
        "",
        lsc.scroll_offset.*,
        lsc.hint_buf.*[0..lsc.hint_len.*],
        lsc.mode.*,
        lsc.options.*,
    ) catch |err| {
        if (trace) {
            var trace_buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&trace_buf, "[scroll] render failed: {s}\n", .{@errorName(err)}) catch "";
            _ = std.c.write(std.Io.File.stderr().handle, (msg).ptr, (msg).len);
        }
        return;
    };

    if (trace) {
        var trace_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&trace_buf, "[scroll] rendered {d} bytes, writing\n", .{lsc.scratch.items().len}) catch "";
        _ = std.c.write(std.Io.File.stderr().handle, (msg).ptr, (msg).len);
    }

    // Full write-all loop: posix.write can return a short write on
    // large buffers, so we must loop until every byte is flushed
    // (or we hit a real error). A silent short-write would leave a
    // half-rendered frame on screen.
    const fd = std.Io.File.stdout().handle;
    var written: usize = 0;
    const data = lsc.scratch.items();
    while (written < data.len) {
        const slice = data[written..];
        const n = std.c.write(fd, slice.ptr, slice.len);
        if (n < 0) {
            if (trace) {
                var trace_buf: [160]u8 = undefined;
                const msg = std.fmt.bufPrint(&trace_buf, "[scroll] write failed\n", .{}) catch "";
                _ = std.c.write(std.Io.File.stderr().handle, msg.ptr, msg.len);
            }
            return;
        }
        const consumed: usize = @intCast(n);
        if (consumed == 0) break;
        written += consumed;
    }
}

fn deriveThinkingTopicTitle(summary: []const u8, out: *[96]u8) []const u8 {
    return repl_spinner_mod.deriveThinkingTopicTitle(summary, out);
}

fn terminalRows() usize {
    return repl_spinner_mod.terminalRows();
}

fn terminalCols() usize {
    return repl_spinner_mod.terminalCols();
}

pub fn modeLabel(mode: SessionMode) []const u8 {
    return switch (mode) {
        .execution => "execution",
        .planning => "planning",
        .brainstorm => "brainstorm",
        .review => "review",
    };
}

fn togglePrimaryMode(mode: SessionMode) SessionMode {
    return switch (mode) {
        .execution => .planning,
        .planning => .brainstorm,
        .brainstorm => .execution,
        .review => .execution,
    };
}

fn parseModeName(text: []const u8) ?SessionMode {
    if (std.mem.eql(u8, text, "execution")) return .execution;
    if (std.mem.eql(u8, text, "planning")) return .planning;
    if (std.mem.eql(u8, text, "brainstorm")) return .brainstorm;
    if (std.mem.eql(u8, text, "review")) return .review;
    return null;
}

/// P3 (PRD #534): push a live permission-mode change from the REPL into the
/// runtime via the Handler command boundary. The runtime updates
/// permission_mode_override (the gate reads it) and runs transitionPermissionMode
/// (strip dangerous Bash allow rules on plan entry, restore on exit). The REPL
/// reaches the runtime only across this opaque callback, mirroring how
/// `__yolo_on`/`__consume_requested_mode` thread other REPL->runtime state.
fn pushPermissionModeToRuntime(handler: Handler, allocator: std.mem.Allocator, mode: permission_decision.Mode) void {
    const cmd_cb = handler.command orelse return;
    var cmd_buf: [64]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "__set_permission_mode {s}", .{permission_decision.modeToString(mode)}) catch return;
    _ = cmd_cb(handler.ctx, allocator, cmd) catch null;
}

fn applyThemeSelection(options: *Options, setting: ui_theme.ThemeSetting) void {
    options.theme_setting = setting;
    options.theme = ui_theme.resolveSetting(setting);
}

fn applyThemeCommandSideEffects(options: *Options, command: []const u8) void {
    if (std.mem.startsWith(u8, command, "/theme syntax ")) {
        const arg = std.mem.trim(u8, command["/theme syntax ".len..], " \t");
        if (std.mem.eql(u8, arg, "on")) {
            options.highlight_code_blocks = true;
        } else if (std.mem.eql(u8, arg, "off")) {
            options.highlight_code_blocks = false;
        }
        return;
    }

    if (std.mem.startsWith(u8, command, "/theme ")) {
        const arg = std.mem.trim(u8, command["/theme ".len..], " \t");
        if (ui_theme.parseThemeSetting(arg)) |setting| {
            applyThemeSelection(options, setting);
        }
    }
}

fn applyBriefCommandSideEffects(options: *Options, command: []const u8) void {
    if (std.mem.eql(u8, command, "/brief")) {
        options.brief_mode = !options.brief_mode;
        return;
    }
    if (!std.mem.startsWith(u8, command, "/brief ")) return;

    const arg = std.mem.trim(u8, command["/brief ".len..], " \t");
    if (std.mem.eql(u8, arg, "on")) {
        options.brief_mode = true;
    } else if (std.mem.eql(u8, arg, "off")) {
        options.brief_mode = false;
    }
}

fn applyVimCommandSideEffects(options: *Options, command: []const u8) void {
    if (std.mem.eql(u8, command, "/vim")) {
        options.vim_mode_enabled = !options.vim_mode_enabled;
    } else if (std.mem.startsWith(u8, command, "/vim ")) {
        const arg = std.mem.trim(u8, command["/vim ".len..], " \t");
        if (std.mem.eql(u8, arg, "on")) {
            options.vim_mode_enabled = true;
        } else if (std.mem.eql(u8, arg, "off")) {
            options.vim_mode_enabled = false;
        }
    }
    options.input_mode_label = if (options.vim_mode_enabled) "VIM INSERT" else "";
}

fn applyUiCommandSideEffects(options: *Options, command: []const u8) void {
    applyThemeCommandSideEffects(options, command);
    applyBriefCommandSideEffects(options, command);
    applyVimCommandSideEffects(options, command);
}

// ── misc-utils-14: ultraplan keyword auto-routing ──
// Reference: claude-clone src/utils/ultraplan/keyword.ts and
// src/utils/processUserInput/processUserInput.ts:455-493. When interactive,
// non-slash input contains a standalone "ultraplan" token (not inside quotes
// or a path-like context), the turn is rewritten ("ultraplan" -> "plan") and
// routed through the existing /ultraplan handler.

const ULTRAPLAN_KEYWORD = "ultraplan";

const UltraplanTrigger = struct {
    start: usize,
    end: usize,
};

fn isKeywordWordByte(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

// Find the first standalone "ultraplan" token that should trigger auto-routing.
// Conservatively skips occurrences that are clearly not a launch directive:
//   - text starting with "/" (slash-command input is handled elsewhere)
//   - inside backticks, double quotes, or square brackets (paste placeholders)
//   - immediately preceded or followed by "/", "\\", or "-" (path/identifier)
//   - followed by "." + word char (file extension like ultraplan.ts)
//   - followed by "?" (a question about the feature, not a directive)
// Matching is case-insensitive and requires a word boundary on both sides so
// "ultraplanner" does not trigger. We operate on ASCII bytes, consistent with
// the rest of repl.zig.
fn findUltraplanTrigger(text: []const u8) ?UltraplanTrigger {
    if (text.len == 0) return null;
    if (text[0] == '/') return null;

    var i: usize = 0;
    while (i + ULTRAPLAN_KEYWORD.len <= text.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(text[i .. i + ULTRAPLAN_KEYWORD.len], ULTRAPLAN_KEYWORD)) continue;

        const start = i;
        const end = i + ULTRAPLAN_KEYWORD.len;

        // Word-boundary check: neither the byte before nor after may be a
        // word character (so "ultraplanner"/"xultraplan" do not match).
        if (start > 0 and isKeywordWordByte(text[start - 1])) continue;
        if (end < text.len and isKeywordWordByte(text[end])) continue;

        // Path / identifier context.
        const before: ?u8 = if (start > 0) text[start - 1] else null;
        const after: ?u8 = if (end < text.len) text[end] else null;
        if (before) |b| {
            if (b == '/' or b == '\\' or b == '-') continue;
        }
        if (after) |a| {
            if (a == '/' or a == '\\' or a == '-' or a == '?') continue;
            // file-extension-like: ultraplan.ts
            if (a == '.' and end + 1 < text.len and isKeywordWordByte(text[end + 1])) continue;
        }

        // Quote / bracket context: skip if the match starts inside a paired
        // backtick, double-quote, or square-bracket region opened before it.
        if (isInsideQuoteOrBracket(text, start)) continue;

        return .{ .start = start, .end = end };
    }
    return null;
}

// Returns true when byte index `pos` falls inside an unbalanced paired region
// (backticks, double quotes, or square brackets) opened earlier in the text.
fn isInsideQuoteOrBracket(text: []const u8, pos: usize) bool {
    var open_backtick = false;
    var open_dquote = false;
    var bracket_depth: usize = 0;
    var i: usize = 0;
    while (i < pos) : (i += 1) {
        const ch = text[i];
        switch (ch) {
            '`' => if (!open_dquote and bracket_depth == 0) {
                open_backtick = !open_backtick;
            },
            '"' => if (!open_backtick and bracket_depth == 0) {
                open_dquote = !open_dquote;
            },
            '[' => if (!open_backtick and !open_dquote) {
                bracket_depth += 1;
            },
            ']' => if (!open_backtick and !open_dquote and bracket_depth > 0) {
                bracket_depth -= 1;
            },
            else => {},
        }
    }
    return open_backtick or open_dquote or bracket_depth > 0;
}

fn hasUltraplanKeyword(text: []const u8) bool {
    return findUltraplanTrigger(text) != null;
}

// Replace the first triggerable "ultraplan" token with "plan", preserving the
// casing of the trailing "plan" suffix the user typed. Returns a freshly
// allocated copy the caller owns. When there is no trigger, returns a dupe of
// the original text (so the caller can free uniformly).
fn replaceUltraplanKeyword(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const trigger = findUltraplanTrigger(text) orelse return allocator.dupe(u8, text);
    // "ultraplan" -> drop the leading "ultra", keep "plan" with the original
    // casing of those 4 bytes (offset 5..9 within the matched token).
    const suffix_start = trigger.start + "ultra".len;
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    try out.writer().writeAll(text[0..trigger.start]);
    try out.writer().writeAll(text[suffix_start..trigger.end]);
    try out.writer().writeAll(text[trigger.end..]);
    return out.toOwnedSlice();
}

const PlanAction = repl_overlay_mod.PlanAction;
const GlobalSearchData = repl_overlay_mod.GlobalSearchData;
const GlobalSearchResult = repl_overlay_mod.GlobalSearchResult;
const HistorySearchData = repl_overlay_mod.HistorySearchData;
const CommandPaletteData = repl_overlay_mod.CommandPaletteData;
const CommandPaletteItem = repl_overlay_mod.CommandPaletteItem;
const RuntimePanelData = repl_overlay_mod.RuntimePanelData;
const ModelPickerData = repl_overlay_mod.ModelPickerData;
const QuickOpenData = repl_overlay_mod.QuickOpenData;
const QuickOpenResult = repl_overlay_mod.QuickOpenResult;
const SessionSwitcherData = repl_overlay_mod.SessionSwitcherData;
const MessageSelectorData = repl_overlay_mod.MessageSelectorData;
const MessageActionsData = repl_overlay_mod.MessageActionsData;
const MessageActionsItem = repl_overlay_mod.MessageActionsItem;
const MessageActionsItemKind = repl_overlay_mod.MessageActionsItemKind;
const MessageActionsResult = repl_overlay_mod.MessageActionsResult;
const StylePickerData = repl_overlay_mod.StylePickerData;
const TodoOverlayData = repl_overlay_mod.TodoOverlayData;
const ThemePickerData = repl_overlay_mod.ThemePickerData;
const ThemePickerResult = repl_overlay_mod.ThemePickerResult;

fn parsePlanAction(text: []const u8) ?PlanAction {
    return repl_overlay_mod.parsePlanAction(text);
}

fn parseModelPickerData(allocator: std.mem.Allocator, payload: []const u8) !ModelPickerData {
    return repl_overlay_mod.parseModelPickerData(allocator, payload);
}

fn parseMessageSelectorData(allocator: std.mem.Allocator, payload: []const u8) !MessageSelectorData {
    return repl_overlay_mod.parseMessageSelectorData(allocator, payload);
}

fn runModelPickerOverlayLoop(data: ModelPickerData, bottom_margin_rows: usize) !?usize {
    return repl_overlay_mod.runModelPickerOverlayLoop(data, bottom_margin_rows, null);
}

fn runModelPickerOverlayLoopWithBindings(data: ModelPickerData, bottom_margin_rows: usize, bindings: ?*const keybindings_mod.RuntimeKeybindings) !?usize {
    return repl_overlay_mod.runModelPickerOverlayLoop(data, bottom_margin_rows, bindings);
}

fn runHistorySearchOverlayLoop(data: HistorySearchData, bottom_margin_rows: usize) !?usize {
    return repl_overlay_mod.runHistorySearchOverlayLoop(data, bottom_margin_rows, null);
}

fn runHistorySearchOverlayLoopWithBindings(data: HistorySearchData, bottom_margin_rows: usize, bindings: ?*const keybindings_mod.RuntimeKeybindings) !?usize {
    return repl_overlay_mod.runHistorySearchOverlayLoop(data, bottom_margin_rows, bindings);
}

fn runCommandPaletteOverlayLoopWithBindings(data: CommandPaletteData, bottom_margin_rows: usize, bindings: ?*const keybindings_mod.RuntimeKeybindings) !?usize {
    return repl_overlay_mod.runCommandPaletteOverlayLoop(data, bottom_margin_rows, bindings);
}

fn runRuntimePanelOverlayLoopWithBindings(data: RuntimePanelData, bottom_margin_rows: usize, bindings: ?*const keybindings_mod.RuntimeKeybindings) !?usize {
    return repl_overlay_mod.runRuntimePanelOverlayLoop(data, bottom_margin_rows, bindings);
}

fn parseSessionSwitcherData(allocator: std.mem.Allocator, payload: []const u8) !SessionSwitcherData {
    return repl_overlay_mod.parseSessionSwitcherData(allocator, payload);
}

fn runSessionSwitcherOverlayLoopWithBindings(data: SessionSwitcherData, bottom_margin_rows: usize, bindings: ?*const keybindings_mod.RuntimeKeybindings) !?usize {
    return repl_overlay_mod.runSessionSwitcherOverlayLoop(data, bottom_margin_rows, bindings);
}

fn runGlobalSearchOverlayLoop(data: GlobalSearchData, bottom_margin_rows: usize) !?GlobalSearchResult {
    return repl_overlay_mod.runGlobalSearchOverlayLoop(data, bottom_margin_rows, null);
}

fn runGlobalSearchOverlayLoopWithBindings(data: GlobalSearchData, bottom_margin_rows: usize, bindings: ?*const keybindings_mod.RuntimeKeybindings) !?GlobalSearchResult {
    return repl_overlay_mod.runGlobalSearchOverlayLoop(data, bottom_margin_rows, bindings);
}

fn runQuickOpenOverlayLoop(data: QuickOpenData, bottom_margin_rows: usize) !?QuickOpenResult {
    return repl_overlay_mod.runQuickOpenOverlayLoop(data, bottom_margin_rows, null);
}

fn runQuickOpenOverlayLoopWithBindings(data: QuickOpenData, bottom_margin_rows: usize, bindings: ?*const keybindings_mod.RuntimeKeybindings) !?QuickOpenResult {
    return repl_overlay_mod.runQuickOpenOverlayLoop(data, bottom_margin_rows, bindings);
}

fn runMessageActionsOverlayLoop(data: MessageActionsData, bottom_margin_rows: usize) !?MessageActionsResult {
    return repl_overlay_mod.runMessageActionsOverlayLoop(data, bottom_margin_rows, null);
}

fn runMessageSelectorOverlayLoop(data: MessageSelectorData, bottom_margin_rows: usize) !?usize {
    return repl_overlay_mod.runMessageSelectorOverlayLoop(data, bottom_margin_rows, null);
}

fn runMessageSelectorOverlayLoopWithBindings(data: MessageSelectorData, bottom_margin_rows: usize, bindings: ?*const keybindings_mod.RuntimeKeybindings) !?usize {
    return repl_overlay_mod.runMessageSelectorOverlayLoop(data, bottom_margin_rows, bindings);
}

fn runMessageActionsOverlayLoopWithBindings(data: MessageActionsData, bottom_margin_rows: usize, bindings: ?*const keybindings_mod.RuntimeKeybindings) !?MessageActionsResult {
    return repl_overlay_mod.runMessageActionsOverlayLoop(data, bottom_margin_rows, bindings);
}

fn runThemePickerOverlayLoop(data: ThemePickerData, bottom_margin_rows: usize) !?ThemePickerResult {
    return repl_overlay_mod.runThemePickerOverlayLoop(data, bottom_margin_rows, null);
}

fn runThemePickerOverlayLoopWithBindings(data: ThemePickerData, bottom_margin_rows: usize, bindings: ?*const keybindings_mod.RuntimeKeybindings) !?ThemePickerResult {
    return repl_overlay_mod.runThemePickerOverlayLoop(data, bottom_margin_rows, bindings);
}

fn runTodoOverlayLoop(data: TodoOverlayData, bottom_margin_rows: usize) !void {
    return repl_overlay_mod.runTodoOverlayLoop(data, bottom_margin_rows);
}

fn runStylePickerOverlayLoop(data: StylePickerData, bottom_margin_rows: usize) !?usize {
    return repl_overlay_mod.runStylePickerOverlayLoop(data, bottom_margin_rows, null);
}

fn runStylePickerOverlayLoopWithBindings(data: StylePickerData, bottom_margin_rows: usize, bindings: ?*const keybindings_mod.RuntimeKeybindings) !?usize {
    return repl_overlay_mod.runStylePickerOverlayLoop(data, bottom_margin_rows, bindings);
}

fn runInlinePlanReviewPrompt(plan_path: []const u8) !PlanAction {
    return repl_overlay_mod.runInlinePlanReviewPrompt(plan_path);
}

fn runPlanReviewOverlayLoop(plan_path: []const u8, bottom_margin_rows: usize) !PlanAction {
    return repl_overlay_mod.runPlanReviewOverlayLoop(plan_path, bottom_margin_rows);
}

fn appendCommandPaletteItem(
    items: *std.array_list.Managed(CommandPaletteItem),
    allocator: std.mem.Allocator,
    id: []const u8,
    title: []const u8,
    detail: []const u8,
    shortcut: []const u8,
    category: []const u8,
    state: []const u8,
) !void {
    const owned_id = try allocator.dupe(u8, id);
    errdefer allocator.free(owned_id);
    const owned_title = try allocator.dupe(u8, title);
    errdefer allocator.free(owned_title);
    const owned_detail = try allocator.dupe(u8, detail);
    errdefer allocator.free(owned_detail);
    const owned_shortcut = try allocator.dupe(u8, shortcut);
    errdefer allocator.free(owned_shortcut);
    const owned_category = try allocator.dupe(u8, category);
    errdefer allocator.free(owned_category);
    const owned_state = try allocator.dupe(u8, state);
    errdefer allocator.free(owned_state);

    try items.append(.{
        .id = owned_id,
        .title = owned_title,
        .detail = owned_detail,
        .shortcut = owned_shortcut,
        .category = owned_category,
        .state = owned_state,
    });
}

fn allocLeaderShortcut(allocator: std.mem.Allocator, leader_key: []const u8, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ leader_key, suffix });
}

fn appendLeaderCommandPaletteItem(
    items: *std.array_list.Managed(CommandPaletteItem),
    allocator: std.mem.Allocator,
    leader_key: []const u8,
    suffix: []const u8,
    id: []const u8,
    title: []const u8,
    detail: []const u8,
    category: []const u8,
    state: []const u8,
) !void {
    const shortcut = try allocLeaderShortcut(allocator, leader_key, suffix);
    defer allocator.free(shortcut);
    try appendCommandPaletteItem(items, allocator, id, title, detail, shortcut, category, state);
}

fn boolState(value: bool) []const u8 {
    return if (value) "on" else "off";
}

fn dynamicAgentName(options: Options) []const u8 {
    if (options.status_dynamic_provider) |provider| {
        return provider.get(provider.ctx).agent_name;
    }
    return options.status_agent_name;
}

fn dynamicCircuitState(options: Options) []const u8 {
    if (options.status_dynamic_provider) |provider| {
        return provider.get(provider.ctx).circuit_state;
    }
    return options.status_circuit_state;
}

fn leaderHintBuf(buf: []u8, leader_key: []const u8, suffix: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s} {s}", .{ leader_key, suffix }) catch leader_key;
}

fn runSlashCommandUi(
    allocator: std.mem.Allocator,
    writer: anytype,
    transcript: *UiTranscript,
    runtime_hint_buf: *[320]u8,
    runtime_hint_len: *usize,
    scroll_offset: usize,
    mode: SessionMode,
    options: Options,
    handler: Handler,
    command: []const u8,
    fallback_text: []const u8,
) !void {
    const cmd_cb = handler.command orelse return;
    const maybe_output = cmd_cb(handler.ctx, allocator, command) catch |err| {
        var err_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&err_buf, "error: {s}", .{@errorName(err)}) catch "error";
        try transcript.appendLine(allocator, msg);
        try renderFullScreen(writer, transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options);
        return;
    };

    if (maybe_output) |output| {
        defer allocator.free(output);
        try transcript.appendText(allocator, output);
    } else {
        try transcript.appendLine(allocator, fallback_text);
    }
    try renderFullScreen(writer, transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options);
}

fn enterAltScreen(writer: anytype) !void {
    return repl_render_mod.enterAltScreen(writer);
}

fn leaveAltScreen(writer: anytype) !void {
    return repl_render_mod.leaveAltScreen(writer);
}

fn appendInputLine(allocator: std.mem.Allocator, transcript: *UiTranscript, prompt_label: []const u8, line: []const u8) !void {
    var buf: [16 * 1024]u8 = undefined;
    const rendered = formatInputPreview(prompt_label, line, &buf);
    try appendTranscriptDivider(allocator, transcript, "You");
    try transcript.appendLine(allocator, rendered);
}

fn appendTranscriptDivider(allocator: std.mem.Allocator, transcript: *UiTranscript, label: []const u8) !void {
    var buf: [96]u8 = undefined;
    const divider = repl_render_mod.formatTranscriptDivider(buf[0..], label);
    if (divider.len == 0) return;
    if (transcript.lines.items.len > 0) {
        const last = transcript.lines.items[transcript.lines.items.len - 1];
        if (std.mem.eql(u8, last, divider)) return;
    }
    try transcript.appendLine(allocator, divider);
}

fn appendTranscriptSectionLine(allocator: std.mem.Allocator, transcript: *UiTranscript, label: []const u8, line: []const u8) !void {
    try appendTranscriptDivider(allocator, transcript, label);
    try transcript.appendLine(allocator, line);
}

fn appendTranscriptSectionText(allocator: std.mem.Allocator, transcript: *UiTranscript, label: []const u8, text: []const u8) !void {
    try appendTranscriptDivider(allocator, transcript, label);
    try transcript.appendText(allocator, text);
}

fn appendAssistantTranscriptOutput(allocator: std.mem.Allocator, transcript: *UiTranscript, text: []const u8) !void {
    // Shared with the one-shot render path in main.zig so both modes
    // apply the same envelope-stripping discipline. Returns an empty
    // slice when the model emitted pure protocol bytes; we drop
    // those turns entirely (tool card above already showed work).
    const assistant_render = @import("../core/assistant_render.zig");
    const cleaned = try assistant_render.cleanAssistantText(allocator, text);
    defer allocator.free(cleaned);
    if (cleaned.len == 0) return;
    const trimmed = std.mem.trimEnd(u8, cleaned, "\r\n");

    try appendTranscriptDivider(allocator, transcript, "Assistant");
    try transcript.appendLine(allocator, repl_render_mod.transcriptAssistantBlockStartMarker());
    try transcript.appendText(allocator, trimmed);
    try transcript.appendLine(allocator, repl_render_mod.transcriptAssistantBlockEndMarker());
}

/// ui-render-04: render the persisted extended-thinking for the just-
/// completed turn into the transcript. Fetches the last assistant turn's
/// thinking via the `__last_thinking` runtime command. In normal view it
/// appends a collapsed `∴ Thinking (ctrl+o to expand)` line; in transcript
/// view it appends the full thinking text indented two spaces. No-op when
/// the turn produced no thinking. Best-effort: a failure to fetch/append
/// the indicator must not abort the turn render, so errors are swallowed.
fn appendThinkingIndicator(
    allocator: std.mem.Allocator,
    transcript: *UiTranscript,
    handler: Handler,
    show_full: bool,
) void {
    const cmd_cb = handler.command orelse return;
    const maybe_thinking = cmd_cb(handler.ctx, allocator, "__last_thinking") catch return;
    const thinking = maybe_thinking orelse return;
    defer allocator.free(thinking);
    if (thinking.len == 0) return;

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    // Color is stripped by the transcript sanitizer regardless; pass
    // use_color=false so we do not waste buffer space on SGR bytes the
    // transcript will discard. The renderer applies its own styling.
    thinking_render.renderThinkingCollapsed(&w, false) catch return;
    transcript.appendText(allocator, w.buffered()) catch return;

    if (show_full) {
        // The full block can be long; render line-by-line straight into
        // the transcript to avoid a fixed-buffer cap on the reasoning text.
        var it = std.mem.splitScalar(u8, thinking, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (trimmed.len == 0) {
                transcript.appendLine(allocator, "") catch return;
                continue;
            }
            var lbuf: [4096]u8 = undefined;
            var lw = std.Io.Writer.fixed(&lbuf);
            lw.writeAll("  ") catch {
                // Line longer than the buffer: append untruncated without
                // the indent rather than dropping it.
                transcript.appendLine(allocator, trimmed) catch return;
                continue;
            };
            lw.writeAll(trimmed) catch {
                transcript.appendLine(allocator, trimmed) catch return;
                continue;
            };
            transcript.appendLine(allocator, lw.buffered()) catch return;
        }
    }
}

/// Cheap "<cwd>/.git exists" probe for the spinner-tip relevance context
/// (Phase 14.13). Best-effort: any error means "not a git repo".
fn isWorkspaceGitRepo(allocator: std.mem.Allocator, cwd: []const u8) bool {
    const git_path = std.fs.path.join(allocator, &.{ cwd, ".git" }) catch return false;
    defer allocator.free(git_path);
    std.Io.Dir.cwd().access(rt.io, git_path, .{}) catch return false;
    return true;
}

fn appendThinkingSummary(allocator: std.mem.Allocator, transcript: *UiTranscript, state: *SpinnerState) !void {
    // User feedback: the per-turn "Activity" block (activity timeline
    // with [context] / [model] / [step] / [response] / [session] /
    // [done] lines) was visual noise on top of the assistant reply --
    // the tool cards already cover the interesting state transitions,
    // and the timeline echoes them in a less-useful format. Suppress
    // the block entirely; users who want the breakdown can still see
    // it during thinking via the live spinner summary. Kept the
    // function symbol and call sites so bringing it back later (e.g.
    // behind a --verbose flag) is a single-line revert.
    _ = allocator;
    _ = transcript;
    _ = state;
    return;
}

const transcript_divider_prefix = "[[divider:";
const transcript_divider_suffix = "]]";

fn parseTranscriptDividerLabelLocal(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, transcript_divider_prefix)) return null;
    if (!std.mem.endsWith(u8, line, transcript_divider_suffix)) return null;
    const start = transcript_divider_prefix.len;
    const end = line.len - transcript_divider_suffix.len;
    if (end < start) return null;
    return line[start..end];
}

fn classifyMessageActionsKind(label: []const u8) MessageActionsItemKind {
    if (containsIgnoreCase(label, "you")) return .user;
    if (containsIgnoreCase(label, "assistant")) return .assistant;
    return .section;
}

fn normalizeMessageActionContent(allocator: std.mem.Allocator, prompt_label: []const u8, kind: MessageActionsItemKind, text: []const u8) ![]u8 {
    if (kind == .user and prompt_label.len > 0) {
        var prefix_buf: [32]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "{s} ", .{prompt_label}) catch prompt_label;
        if (std.mem.startsWith(u8, text, prefix)) {
            return allocator.dupe(u8, text[prefix.len..]);
        }
    }
    return allocator.dupe(u8, text);
}

fn finalizeMessageActionsItem(
    allocator: std.mem.Allocator,
    items: *std.array_list.Managed(MessageActionsItem),
    prompt_label: []const u8,
    last_user_index: *?usize,
    current_label: ?[]const u8,
    current_kind: MessageActionsItemKind,
    content: *std_io.StringBuilder,
) !void {
    const label = current_label orelse return;
    const trimmed = std.mem.trim(u8, content.items(), " \t\r\n");
    defer content.clearRetainingCapacity();
    if (trimmed.len == 0) return;

    const owned_label = try allocator.dupe(u8, label);
    errdefer allocator.free(owned_label);
    const owned_content = try normalizeMessageActionContent(allocator, prompt_label, current_kind, trimmed);
    errdefer allocator.free(owned_content);

    try items.append(.{
        .kind = current_kind,
        .label = owned_label,
        .content = owned_content,
    });
    if (current_kind == .user) {
        last_user_index.* = items.items.len - 1;
    }
}

fn buildMessageActionsData(allocator: std.mem.Allocator, transcript: *const UiTranscript, prompt_label: []const u8) !MessageActionsData {
    var items = std.array_list.Managed(MessageActionsItem).init(allocator);
    errdefer {
        for (items.items) |item| {
            allocator.free(item.label);
            allocator.free(item.content);
        }
        items.deinit();
    }

    var current_label: ?[]const u8 = null;
    var current_kind: MessageActionsItemKind = .section;
    var content = std_io.StringBuilder.init(allocator);
    defer content.deinit();
    var last_user_index: ?usize = null;

    for (transcript.lines.items) |line| {
        if (parseTranscriptDividerLabelLocal(line)) |label| {
            try finalizeMessageActionsItem(allocator, &items, prompt_label, &last_user_index, current_label, current_kind, &content);
            current_label = label;
            current_kind = classifyMessageActionsKind(label);
            continue;
        }
        if (std.mem.eql(u8, line, repl_render_mod.transcriptAssistantBlockStartMarker()) or
            std.mem.eql(u8, line, repl_render_mod.transcriptAssistantBlockEndMarker()))
        {
            continue;
        }
        if (current_label == null) continue;
        if (content.items().len > 0) try content.append('\n');
        try content.appendSlice(line);
    }

    try finalizeMessageActionsItem(allocator, &items, prompt_label, &last_user_index, current_label, current_kind, &content);

    const initial_selection = last_user_index orelse if (items.items.len > 0) items.items.len - 1 else 0;
    return .{
        .allocator = allocator,
        .items = try items.toOwnedSlice(),
        .initial_selection = initial_selection,
    };
}

fn buildTranscriptOverlayText(allocator: std.mem.Allocator, transcript: *const UiTranscript) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    for (transcript.lines.items) |line| {
        if (parseTranscriptDividerLabelLocal(line)) |label| {
            if (out.items().len > 0 and out.items()[out.items().len - 1] != '\n') try out.append('\n');
            try out.writer().print("=== {s} ===\n", .{label});
            continue;
        }
        if (std.mem.eql(u8, line, repl_render_mod.transcriptAssistantBlockStartMarker()) or
            std.mem.eql(u8, line, repl_render_mod.transcriptAssistantBlockEndMarker()))
        {
            continue;
        }
        try out.appendSlice(line);
        try out.append('\n');
    }

    return out.toOwnedSlice();
}

fn renderFriendlyError(out: []u8, err: anyerror, options: Options) []const u8 {
    return repl_render_mod.renderFriendlyError(out, err, options);
}

fn transcriptWindowRows(total_rows: usize, options: Options) usize {
    const margin = boundedBottomMarginRows(total_rows, options.bottom_margin_rows);
    const panel_gap = inputPanelGapRows(total_rows);
    const chrome_gaps = repl_render_mod.bottomChromeGutterRows(total_rows) * 2;
    const reserved = 5 + chrome_gaps + panel_gap + margin; // bottom interaction chrome + footer/status gutters + bottom margin
    if (total_rows <= reserved) return 1;
    return total_rows - reserved;
}

fn inputPanelGapRows(total_rows: usize) usize {
    return if (total_rows >= 10) 1 else 0;
}

fn wrappedRowsForLine(line: []const u8, cols: usize) usize {
    const width = @max(@as(usize, 1), cols);
    if (line.len == 0) return 1;
    return @divFloor(line.len + width - 1, width);
}

fn transcriptVisualRows(transcript: *const UiTranscript, cols: usize, options: Options) usize {
    return repl_render_mod.transcriptVisualRows(transcript, cols, options);
}

fn maxScrollOffset(transcript: *const UiTranscript, rows: usize, cols: usize, options: Options) usize {
    const window_rows = transcriptWindowRows(rows, options);
    const total_rows = transcriptVisualRows(transcript, cols, options);
    return if (total_rows > window_rows) total_rows - window_rows else 0;
}

fn clampScrollOffset(offset: usize, transcript: *const UiTranscript, rows: usize, cols: usize, options: Options) usize {
    return @min(offset, maxScrollOffset(transcript, rows, cols, options));
}

const LineRenderKind = repl_markdown_mod.LineRenderKind;

fn classifyLineRenderKind(line: []const u8, state: *const MarkdownRenderState) LineRenderKind {
    return repl_markdown_mod.classifyLineRenderKind(line, state);
}

fn renderWrappedLineRows(
    writer: anytype,
    line: []const u8,
    cols: usize,
    row_from: usize,
    row_to: usize,
    kind: LineRenderKind,
    state: *MarkdownRenderState,
    options: Options,
) !void {
    return repl_render_mod.renderWrappedLineRows(writer, line, cols, row_from, row_to, kind, state, options);
}

fn renderFullScreen(
    writer: anytype,
    transcript: *const UiTranscript,
    show_prompt: bool,
    input_text: []const u8,
    scroll_offset: usize,
    hint: []const u8,
    mode: SessionMode,
    options: Options,
) !void {
    return repl_render_mod.renderFullScreen(writer, transcript, show_prompt, input_text, scroll_offset, hint, mode, options);
}

fn renderPromptFrame(
    writer: anytype,
    transcript: *const UiTranscript,
    input_text: []const u8,
    input_cursor: usize,
    scroll_offset: usize,
    hint: []const u8,
    slash_suggestion_selection: usize,
    mode: SessionMode,
    options: Options,
) !void {
    return repl_render_mod.renderFullScreenWithCursorSelection(
        writer,
        transcript,
        true,
        input_text,
        input_cursor,
        scroll_offset,
        hint,
        slash_suggestion_selection,
        mode,
        options,
    );
}

// Status formatting functions delegated to repl_render_mod

// Render functions delegated to repl_render_mod
fn formatInputPreview(prompt_label: []const u8, input_text: []const u8, out: []u8) []const u8 {
    return repl_input_mod.formatInputPreview(prompt_label, input_text, out);
}

// ANSI constants and markdown types delegated to repl_markdown_mod
const ANSI_RESET = repl_markdown_mod.ANSI_RESET;
const ANSI_DIM = repl_markdown_mod.ANSI_DIM;
const ANSI_BOLD = repl_markdown_mod.ANSI_BOLD;
const BOX_H = repl_markdown_mod.BOX_H;
const BOX_V = repl_markdown_mod.BOX_V;
const TABLE_MAX_COLUMNS = repl_markdown_mod.TABLE_MAX_COLUMNS;
const TAB_WIDTH: usize = 4;
const CodeLang = repl_markdown_mod.CodeLang;
const MarkdownRenderState = repl_markdown_mod.MarkdownRenderState;

fn shouldUseColor(options: Options) bool {
    return repl_markdown_mod.shouldUseColor(options);
}

fn writeStyledText(writer: anytype, text: []const u8, options: Options) !void {
    return repl_markdown_mod.writeStyledText(writer, text, options);
}

// Markdown rendering functions delegated to repl_markdown_mod (see repl_markdown.zig)
fn parseCodeFence(line: []const u8) ?[]const u8 {
    return repl_markdown_mod.parseCodeFence(line);
}

fn parseCodeLang(tag: []const u8) CodeLang {
    return repl_markdown_mod.parseCodeLang(tag);
}

fn looksLikeStandaloneCodeLine(line: []const u8) bool {
    return repl_markdown_mod.looksLikeStandaloneCodeLine(line);
}

fn parseMarkdownHeading(line: []const u8, start: usize) ?repl_markdown_mod.HeadingInfo {
    return repl_markdown_mod.parseMarkdownHeading(line, start);
}

fn parseMarkdownListMarker(line: []const u8) ?repl_markdown_mod.ListMarkerInfo {
    return repl_markdown_mod.parseMarkdownListMarker(line);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return repl_markdown_mod.containsIgnoreCase(haystack, needle);
}

// Input handling and sanitization functions delegated to repl_input_mod / repl_spinner_mod
const TerminalRawMode = repl_input_mod.TerminalRawMode;
const InputEvent = repl_input_mod.InputEvent;
const MAX_INPUT_BYTES = repl_input_mod.MAX_INPUT_BYTES;
const SlashSuggestions = repl_input_mod.SlashSuggestions;
const MAX_REFERENCE_SUGGESTIONS: usize = 8;

const ReferenceToken = struct {
    start: usize,
    end: usize,
    query: []const u8,
    quoted: bool,
};

const ReferenceSuggestion = struct {
    source: repl_footer_mod.SuggestionSource,
    text: []const u8,
    primary: []const u8,
    secondary: []const u8,
};

const ReferenceSuggestions = struct {
    token: ?ReferenceToken = null,
    matches: [MAX_REFERENCE_SUGGESTIONS]ReferenceSuggestion = undefined,
    scores: [MAX_REFERENCE_SUGGESTIONS]i32 = [_]i32{0} ** MAX_REFERENCE_SUGGESTIONS,
    count: usize = 0,

    fn visible(self: *const ReferenceSuggestions) []const ReferenceSuggestion {
        return self.matches[0..self.count];
    }
};

fn appendInputByte(input_buf: *std_io.StringBuilder, ch: u8) !void {
    return repl_input_mod.appendInputByte(input_buf, ch);
}

fn insertInputBytesAt(input_buf: *std_io.StringBuilder, cursor: *usize, bytes: []const u8) !void {
    return repl_input_mod.insertInputBytesAt(input_buf, cursor, bytes);
}

fn readFullScreenInputEvent(input_buf: *std_io.StringBuilder) !InputEvent {
    return repl_input_mod.readFullScreenInputEvent(input_buf);
}

fn readFullScreenInputEventCursor(input_buf: *std_io.StringBuilder, cursor: *usize) !InputEvent {
    return repl_input_mod.readFullScreenInputEventCursor(input_buf, cursor);
}

fn readFullScreenInputEventCursorWithBindings(
    input_buf: *std_io.StringBuilder,
    cursor: *usize,
    bindings: ?*const keybindings_mod.RuntimeKeybindings,
    prompt_context: ?keybindings_mod.BindingContext,
    attachment_active: bool,
) !InputEvent {
    return repl_input_mod.readFullScreenInputEventCursorWithBindings(
        input_buf,
        cursor,
        bindings,
        prompt_context,
        attachment_active,
    );
}

fn deletePreviousWord(input_buf: *std_io.StringBuilder) void {
    return repl_input_mod.deletePreviousWord(input_buf);
}

fn deletePreviousWordAt(input_buf: *std_io.StringBuilder, cursor: *usize) void {
    if (cursor.* == 0) return;
    var i = cursor.*;
    // Skip whitespace before cursor
    while (i > 0 and std.ascii.isWhitespace(input_buf.items()[i - 1])) : (i -= 1) {}
    if (repl_attachments_mod.tokenBeforeCursor(input_buf.items(), i)) |token| {
        if (token.end == i or (token.start < i and i <= token.end)) {
            const remove_count = cursor.* - token.start;
            var n: usize = 0;
            while (n < remove_count) : (n += 1) {
                _ = input_buf.orderedRemove(token.start);
            }
            cursor.* = token.start;
            return;
        }
    }
    // Skip non-whitespace word chars
    while (i > 0 and !std.ascii.isWhitespace(input_buf.items()[i - 1])) : (i -= 1) {}
    const remove_count = cursor.* - i;
    if (remove_count == 0) return;
    var n: usize = 0;
    while (n < remove_count) : (n += 1) {
        _ = input_buf.orderedRemove(i);
    }
    cursor.* = i;
}

fn wordLeftFrom(text: []const u8, pos: usize) usize {
    var i = @min(pos, text.len);
    if (i == 0) return 0;
    if (repl_attachments_mod.tokenBeforeCursor(text, i)) |token| {
        if (token.end == i or (token.start < i and i <= token.end)) {
            return token.start;
        }
    }
    while (i > 0 and std.ascii.isWhitespace(text[i - 1])) : (i -= 1) {}
    if (repl_attachments_mod.tokenBeforeCursor(text, i)) |token| {
        if (token.end == i or (token.start < i and i <= token.end)) {
            return token.start;
        }
    }
    while (i > 0 and !std.ascii.isWhitespace(text[i - 1])) : (i -= 1) {}
    return i;
}

fn wordRightFrom(text: []const u8, pos: usize) usize {
    var i = @min(pos, text.len);
    if (i < text.len) {
        if (repl_attachments_mod.tokenAt(text, i)) |token| {
            return token.end;
        }
    }
    while (i < text.len and !std.ascii.isWhitespace(text[i])) : (i += 1) {}
    while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {}
    if (i < text.len) {
        if (repl_attachments_mod.tokenAt(text, i)) |token| {
            return token.end;
        }
    }
    return i;
}

fn normalizeAttachmentCursor(text: []const u8, cursor: *usize) void {
    const clamped = @min(cursor.*, text.len);
    cursor.* = clamped;
    if (text.len == 0 or clamped == 0) return;

    if (clamped < text.len) {
        if (repl_attachments_mod.tokenAt(text, clamped)) |token| {
            if (clamped > token.start and clamped < token.end) {
                const left_dist = clamped - token.start;
                const right_dist = token.end - clamped;
                cursor.* = if (left_dist <= right_dist) token.start else token.end;
                return;
            }
        }
    }

    if (repl_attachments_mod.tokenBeforeCursor(text, clamped)) |token| {
        if (clamped > token.start and clamped < token.end) {
            const left_dist = clamped - token.start;
            const right_dist = token.end - clamped;
            cursor.* = if (left_dist <= right_dist) token.start else token.end;
        }
    }
}

fn moveCursorLeftOverAttachment(text: []const u8, cursor: usize) usize {
    const clamped = @min(cursor, text.len);
    if (clamped == 0) return 0;
    if (repl_attachments_mod.tokenBeforeCursor(text, clamped)) |token| {
        if (token.end == clamped or (token.start < clamped and clamped <= token.end)) {
            return token.start;
        }
    }
    return clamped - 1;
}

fn moveCursorRightOverAttachment(text: []const u8, cursor: usize) usize {
    const clamped = @min(cursor, text.len);
    if (clamped >= text.len) return text.len;
    if (repl_attachments_mod.tokenAt(text, clamped)) |token| {
        return token.end;
    }
    return clamped + 1;
}

fn focusedAttachmentToken(text: []const u8, cursor: usize) ?repl_attachments_mod.Token {
    const clamped = @min(cursor, text.len);
    if (clamped < text.len) {
        if (repl_attachments_mod.tokenAt(text, clamped)) |token| {
            if (clamped == token.start) return token;
        }
    }
    return null;
}

fn nextAttachmentCursor(text: []const u8, cursor: usize) usize {
    if (text.len == 0) return 0;
    const current = focusedAttachmentToken(text, cursor);
    var idx: usize = if (current) |token| token.end else @min(cursor, text.len);
    while (idx < text.len) {
        if (repl_attachments_mod.tokenAt(text, idx)) |token| return token.start;
        idx += 1;
    }
    return if (current) |token| token.start else @min(cursor, text.len);
}

fn previousAttachmentCursor(text: []const u8, cursor: usize) usize {
    if (text.len == 0) return 0;
    const current_start = if (focusedAttachmentToken(text, cursor)) |token| token.start else @min(cursor, text.len);
    var idx: usize = 0;
    var previous: ?usize = null;
    while (idx < text.len and idx < current_start) {
        if (repl_attachments_mod.tokenAt(text, idx)) |token| {
            previous = token.start;
            idx = token.end;
            continue;
        }
        idx += 1;
    }
    return previous orelse current_start;
}

fn exitAttachmentCursor(text: []const u8, cursor: usize) usize {
    if (focusedAttachmentToken(text, cursor)) |token| return token.end;
    return @min(cursor, text.len);
}

fn attachmentRemoveRange(text: []const u8, cursor: usize) ?struct { start: usize, end: usize } {
    const token = focusedAttachmentToken(text, cursor) orelse return null;
    var end = token.end;
    if (end < text.len and text[end] == ' ') end += 1;
    return .{ .start = token.start, .end = end };
}

const PromptCursorRowDirection = enum {
    up,
    down,
};

const PromptCursorVisualPos = struct {
    row: usize,
    col: usize,
};

fn promptEditableRowWidth(prompt_label: []const u8, cols: usize, row: usize) usize {
    const content_width = if (cols > 4) cols - 4 else 1;
    if (row == 0) {
        return @max(@as(usize, 1), content_width -| (prompt_label.len + 1));
    }
    return content_width;
}

fn advancePromptVisualCursor(prompt_label: []const u8, cols: usize, row: *usize, col: *usize, ch: u8) void {
    if (ch == '\r') return;
    if (ch == '\n') {
        row.* += 1;
        col.* = 0;
        return;
    }

    col.* += 1;
    const row_width = promptEditableRowWidth(prompt_label, cols, row.*);
    if (col.* >= row_width) {
        row.* += 1;
        col.* = 0;
    }
}

fn promptCursorVisualPos(prompt_label: []const u8, input_text: []const u8, cursor: usize, cols: usize) PromptCursorVisualPos {
    var row: usize = 0;
    var col: usize = 0;
    const clamped = @min(cursor, input_text.len);
    var idx: usize = 0;
    while (idx < clamped) : (idx += 1) {
        advancePromptVisualCursor(prompt_label, cols, &row, &col, input_text[idx]);
    }
    return .{ .row = row, .col = col };
}

fn absDiff(a: usize, b: usize) usize {
    return if (a >= b) a - b else b - a;
}

fn movePromptCursorVertical(prompt_label: []const u8, input_text: []const u8, cursor: *usize, cols: usize, direction: PromptCursorRowDirection) bool {
    const current = promptCursorVisualPos(prompt_label, input_text, cursor.*, cols);
    const target_row = switch (direction) {
        .up => if (current.row == 0) return false else current.row - 1,
        .down => current.row + 1,
    };

    var row: usize = 0;
    var col: usize = 0;
    var idx: usize = 0;
    var found_row = false;
    var best_index: ?usize = null;
    var best_distance: usize = std.math.maxInt(usize);
    var best_col: usize = 0;

    while (true) {
        if (row == target_row) {
            found_row = true;
            const distance = absDiff(col, current.col);
            if (best_index == null or distance < best_distance or (distance == best_distance and col > best_col)) {
                best_index = idx;
                best_distance = distance;
                best_col = col;
            }
        }

        if (idx == input_text.len) break;
        advancePromptVisualCursor(prompt_label, cols, &row, &col, input_text[idx]);
        idx += 1;
    }

    if (!found_row) return false;
    cursor.* = best_index orelse return false;
    return true;
}

const MAX_PROMPT_STARTER_SUGGESTIONS = 2;
const MAX_PROMPT_FOOTER_ROWS = 8;
const MAX_QUEUED_PREVIEW_ROWS = 3;
const QUEUED_PREVIEW_WIDTH = 96;
const MAX_COMMAND_SUGGESTIONS = 8;

const StarterSuggestion = struct {
    text: []const u8,
    tag: []const u8,
    description: []const u8,
};

const StarterSuggestionSet = struct {
    items: [MAX_PROMPT_STARTER_SUGGESTIONS]StarterSuggestion = undefined,
    count: usize = 0,

    fn visible(self: *const @This()) []const StarterSuggestion {
        return self.items[0..self.count];
    }
};

const PromptFooterRows = struct {
    rows: [MAX_PROMPT_FOOTER_ROWS]repl_footer_mod.Row = undefined,
    count: usize = 0,
    selected_index: ?usize = null,

    fn push(self: *@This(), row: repl_footer_mod.Row) void {
        if (self.count >= self.rows.len) return;
        self.rows[self.count] = row;
        self.count += 1;
    }

    fn visible(self: *const @This()) []const repl_footer_mod.Row {
        return self.rows[0..self.count];
    }
};

const CommandSuggestion = struct {
    source: repl_footer_mod.SuggestionSource,
    text: []const u8,
    primary: []const u8,
    secondary: []const u8,
};

const CommandSuggestionSet = struct {
    items: [MAX_COMMAND_SUGGESTIONS]CommandSuggestion = undefined,
    count: usize = 0,

    fn visible(self: *const @This()) []const CommandSuggestion {
        return self.items[0..self.count];
    }

    fn push(self: *@This(), item: CommandSuggestion) void {
        for (self.visible()) |existing| {
            if (std.mem.eql(u8, existing.text, item.text) and std.mem.eql(u8, existing.primary, item.primary)) return;
        }
        if (self.count >= self.items.len) return;
        self.items[self.count] = item;
        self.count += 1;
    }
};

const DynamicCommandSuggestion = struct {
    source: repl_footer_mod.SuggestionSource,
    text: []u8,
    primary: []u8,
    secondary: []u8,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.primary);
        allocator.free(self.secondary);
    }
};

const DynamicCommandSuggestionCache = struct {
    items: std.array_list.Managed(DynamicCommandSuggestion),

    fn init(allocator: std.mem.Allocator) @This() {
        return .{ .items = std.array_list.Managed(DynamicCommandSuggestion).init(allocator) };
    }

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.items.deinit();
    }

    fn clear(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.items.items) |*item| item.deinit(allocator);
        self.items.clearRetainingCapacity();
    }

    fn appendFromCommand(self: *@This(), allocator: std.mem.Allocator, handler: Handler, command: []const u8) void {
        const cmd_cb = handler.command orelse return;
        const maybe_output = cmd_cb(handler.ctx, allocator, command) catch return;
        defer if (maybe_output) |output| allocator.free(output);
        const raw = maybe_output orelse return;

        var lines = std.mem.splitScalar(u8, raw, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r\n");
            if (line.len == 0) continue;
            var parts = std.mem.splitScalar(u8, line, '\t');
            const kind_raw = parts.next() orelse continue;
            const text_raw = parts.next() orelse continue;
            const primary_raw = parts.next() orelse continue;
            const secondary_raw = parts.next() orelse "";
            const source: repl_footer_mod.SuggestionSource = if (std.mem.eql(u8, kind_raw, "agent"))
                .agent
            else if (std.mem.eql(u8, kind_raw, "team"))
                .team
            else if (std.mem.eql(u8, kind_raw, "mcp_resource"))
                .mcp_resource
            else if (std.mem.eql(u8, kind_raw, "mcp_prompt"))
                .mcp_prompt
            else
                .command;

            const text = allocator.dupe(u8, text_raw) catch continue;
            errdefer allocator.free(text);
            const primary = allocator.dupe(u8, primary_raw) catch continue;
            errdefer allocator.free(primary);
            const secondary = allocator.dupe(u8, secondary_raw) catch continue;
            errdefer allocator.free(secondary);

            self.items.append(.{
                .source = source,
                .text = text,
                .primary = primary,
                .secondary = secondary,
            }) catch break;
        }
    }
};

const MAX_PROMPT_STRIP_ITEMS = 14;
const MAX_TASK_STRIP_NOTIFICATIONS = 3;
const MAX_UI_NOTIFICATIONS = 4;
const STRIP_TEXT_WIDTH = 192;

const PromptStripItems = struct {
    items: [MAX_PROMPT_STRIP_ITEMS]repl_footer_mod.StripItem = undefined,
    count: usize = 0,

    fn push(self: *@This(), item: repl_footer_mod.StripItem) void {
        if (self.count >= self.items.len) return;
        self.items[self.count] = item;
        self.count += 1;
    }

    fn visible(self: *const @This()) []const repl_footer_mod.StripItem {
        return self.items[0..self.count];
    }
};

const QueuePreviewSnapshot = struct {
    buffers: [MAX_QUEUED_PREVIEW_ROWS][QUEUED_PREVIEW_WIDTH]u8 = undefined,
    items: [MAX_QUEUED_PREVIEW_ROWS][]const u8 = [_][]const u8{""} ** MAX_QUEUED_PREVIEW_ROWS,
    count: usize = 0,
    overflow_count: usize = 0,
};

const OwnedStringQueue = struct {
    items: std.array_list.Managed([]u8),

    fn init(allocator: std.mem.Allocator) @This() {
        return .{ .items = std.array_list.Managed([]u8).init(allocator) };
    }

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.items.items) |item| allocator.free(item);
        self.items.deinit();
    }

    fn appendOwned(self: *@This(), owned: []u8) !void {
        try self.items.append(owned);
    }

    fn popFirstOwned(self: *@This()) ?[]u8 {
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }

    fn count(self: *const @This()) usize {
        return self.items.items.len;
    }
};

const TaskNotificationStripState = struct {
    title_buffers: [MAX_TASK_STRIP_NOTIFICATIONS][64]u8 = undefined,
    body_buffers: [MAX_TASK_STRIP_NOTIFICATIONS][STRIP_TEXT_WIDTH]u8 = undefined,
    title_items: [MAX_TASK_STRIP_NOTIFICATIONS][]const u8 = [_][]const u8{""} ** MAX_TASK_STRIP_NOTIFICATIONS,
    body_items: [MAX_TASK_STRIP_NOTIFICATIONS][]const u8 = [_][]const u8{""} ** MAX_TASK_STRIP_NOTIFICATIONS,
    count: usize = 0,
    overflow_count: usize = 0,

    fn clear(self: *@This()) void {
        self.* = .{};
    }

    fn append(self: *@This(), status: []const u8, message: []const u8) void {
        if (self.count >= MAX_TASK_STRIP_NOTIFICATIONS) {
            self.overflow_count += 1;
            return;
        }
        const idx = self.count;
        self.title_items[idx] = std.fmt.bufPrint(&self.title_buffers[idx], "task {s}", .{status}) catch "task";
        self.body_items[idx] = clipEndIntoLocal(&self.body_buffers[idx], message, self.body_buffers[idx].len);
        self.count += 1;
    }

    fn dismissAt(self: *@This(), index: usize) bool {
        if (index >= self.count) return false;
        var idx = index;
        while (idx + 1 < self.count) : (idx += 1) {
            self.title_items[idx] = self.title_items[idx + 1];
            self.body_items[idx] = self.body_items[idx + 1];
        }
        self.count -= 1;
        self.title_items[self.count] = "";
        self.body_items[self.count] = "";
        return true;
    }

    fn clearOverflow(self: *@This()) bool {
        if (self.overflow_count == 0) return false;
        self.overflow_count = 0;
        return true;
    }
};

const UiNotificationQueue = struct {
    title_buffers: [MAX_UI_NOTIFICATIONS][64]u8 = undefined,
    body_buffers: [MAX_UI_NOTIFICATIONS][STRIP_TEXT_WIDTH]u8 = undefined,
    tag_buffers: [MAX_UI_NOTIFICATIONS][24]u8 = undefined,
    title_items: [MAX_UI_NOTIFICATIONS][]const u8 = [_][]const u8{""} ** MAX_UI_NOTIFICATIONS,
    body_items: [MAX_UI_NOTIFICATIONS][]const u8 = [_][]const u8{""} ** MAX_UI_NOTIFICATIONS,
    tag_items: [MAX_UI_NOTIFICATIONS][]const u8 = [_][]const u8{""} ** MAX_UI_NOTIFICATIONS,
    tone_items: [MAX_UI_NOTIFICATIONS]repl_footer_mod.NoticeTone = [_]repl_footer_mod.NoticeTone{.plain} ** MAX_UI_NOTIFICATIONS,
    count: usize = 0,

    fn dismissAt(self: *@This(), index: usize) bool {
        if (index >= self.count) return false;
        var idx = index;
        while (idx + 1 < self.count) : (idx += 1) {
            self.title_items[idx] = self.title_items[idx + 1];
            self.body_items[idx] = self.body_items[idx + 1];
            self.tag_items[idx] = self.tag_items[idx + 1];
            self.tone_items[idx] = self.tone_items[idx + 1];
        }
        self.count -= 1;
        self.title_items[self.count] = "";
        self.body_items[self.count] = "";
        self.tag_items[self.count] = "";
        self.tone_items[self.count] = .plain;
        return true;
    }

    fn push(
        self: *@This(),
        title: []const u8,
        body: []const u8,
        tag: []const u8,
        tone: repl_footer_mod.NoticeTone,
    ) void {
        const trimmed_title = std.mem.trim(u8, title, " \t\r\n");
        const trimmed_body = std.mem.trim(u8, body, " \t\r\n");
        const title_source = if (trimmed_title.len > 0) trimmed_title else trimmed_body;
        const body_source = if (trimmed_title.len > 0) trimmed_body else "";
        if (title_source.len == 0) return;

        var duplicate_index: ?usize = null;
        var idx: usize = 0;
        while (idx < self.count) : (idx += 1) {
            if (std.mem.eql(u8, self.title_items[idx], title_source) and
                std.mem.eql(u8, self.body_items[idx], body_source))
            {
                duplicate_index = idx;
                break;
            }
        }
        if (duplicate_index) |existing| {
            _ = self.dismissAt(existing);
        } else if (self.count >= self.title_items.len) {
            _ = self.dismissAt(0);
        }

        if (self.count >= self.title_items.len) return;
        const insert_at = self.count;
        self.count += 1;
        self.title_items[insert_at] = clipEndIntoLocal(&self.title_buffers[insert_at], title_source, self.title_buffers[insert_at].len);
        self.body_items[insert_at] = clipEndIntoLocal(&self.body_buffers[insert_at], body_source, self.body_buffers[insert_at].len);
        const tag_source = std.mem.trim(u8, tag, " \t\r\n");
        self.tag_items[insert_at] = clipEndIntoLocal(
            &self.tag_buffers[insert_at],
            if (tag_source.len > 0) tag_source else "note",
            self.tag_buffers[insert_at].len,
        );
        self.tone_items[insert_at] = tone;
    }
};

const RuntimeStripBanner = struct {
    title_buffer: [64]u8 = undefined,
    body_buffer: [160]u8 = undefined,
    tag_buffer: [24]u8 = undefined,
    title: []const u8 = "",
    body: []const u8 = "",
    tag: []const u8 = "",
    tone: repl_footer_mod.NoticeTone = .dim,
};

fn suggestionRow(tag: []const u8, primary: []const u8, secondary: []const u8, source: repl_footer_mod.SuggestionSource) repl_footer_mod.Row {
    return .{
        .kind = .suggestion,
        .primary = primary,
        .secondary = secondary,
        .tag = if (tag.len > 0) tag else repl_footer_mod.defaultTag(.suggestion, source),
        .source = source,
        .tone = .plain,
        .selectable = true,
    };
}

fn collectStarterSuggestions(
    example_prompt: ?[]const u8,
    history_prompt: ?[]const u8,
    input_text: []const u8,
    submitted_prompt_count: usize,
    selection: *usize,
) StarterSuggestionSet {
    var out = StarterSuggestionSet{};
    if (input_text.len != 0 or submitted_prompt_count > 0) {
        selection.* = 0;
        return out;
    }

    if (example_prompt) |prompt| {
        const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
        if (trimmed.len > 0) {
            out.items[out.count] = .{
                .text = trimmed,
                .tag = "start",
                .description = "workspace starter prompt",
            };
            out.count += 1;
        }
    }

    if (history_prompt) |prompt| {
        const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
        if (trimmed.len > 0) {
            var duplicate = false;
            for (out.visible()) |existing| {
                if (std.mem.eql(u8, existing.text, trimmed)) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate and out.count < out.items.len) {
                out.items[out.count] = .{
                    .text = trimmed,
                    .tag = "recent",
                    .description = "recent workspace prompt",
                };
                out.count += 1;
            }
        }
    }

    if (out.count == 0) {
        selection.* = 0;
    } else if (selection.* >= out.count) {
        selection.* = out.count - 1;
    }
    return out;
}

fn computePromptSuggestion(example_prompt: ?[]const u8, input_text: []const u8, submitted_prompt_count: usize) []const u8 {
    if (input_text.len != 0) return "";
    if (submitted_prompt_count > 0) return "";
    return example_prompt orelse "";
}

fn insertPromptAttachmentToken(
    allocator: std.mem.Allocator,
    input_buf: *std_io.StringBuilder,
    cursor: *usize,
    attachments: *repl_attachments_mod.Store,
    kind: repl_attachments_mod.Kind,
    path: []const u8,
) !void {
    const id = try attachments.add(allocator, kind, path);
    var token_buf: [64]u8 = undefined;
    const token = repl_attachments_mod.buildStructuredToken(token_buf[0..], kind, id);
    var with_space_buf: [80]u8 = undefined;
    const with_space = std.fmt.bufPrint(&with_space_buf, "{s} ", .{token}) catch token;
    try repl_input_mod.insertInputBytesAt(input_buf, cursor, with_space);
}

fn compilePromptForSubmit(
    allocator: std.mem.Allocator,
    input_text: []const u8,
    attachments: *const repl_attachments_mod.Store,
) ![]u8 {
    return repl_attachments_mod.compilePrompt(allocator, input_text, attachments);
}

fn materializePromptForInput(
    allocator: std.mem.Allocator,
    input_text: []const u8,
    attachments: *repl_attachments_mod.Store,
) ![]u8 {
    return repl_attachments_mod.materializePrompt(allocator, input_text, attachments);
}

fn replaceInputFromPromptText(
    allocator: std.mem.Allocator,
    input_buf: *std_io.StringBuilder,
    cursor: *usize,
    attachments: *repl_attachments_mod.Store,
    text: []const u8,
) !void {
    const materialized = try materializePromptForInput(allocator, text, attachments);
    defer allocator.free(materialized);
    try replaceInput(input_buf, materialized);
    cursor.* = input_buf.items().len;
}

fn clipEndIntoLocal(out: []u8, text: []const u8, max_len: usize) []const u8 {
    if (out.len == 0 or max_len == 0) return "";
    const safe_max = @min(max_len, out.len);
    if (text.len <= safe_max or safe_max < 4) {
        const take = @min(text.len, safe_max);
        @memcpy(out[0..take], text[0..take]);
        return out[0..take];
    }

    const keep = safe_max - 3;
    @memcpy(out[0..keep], text[0..keep]);
    @memcpy(out[keep .. keep + 3], "...");
    return out[0..safe_max];
}

fn computeQueuedPromptNotice(out: []u8, queued_prompt: ?[]const u8, restore_to_editor: bool, plan_approved_pending: bool) []const u8 {
    if (out.len == 0) return "";
    if (queued_prompt) |queued| {
        const trimmed = std.mem.trim(u8, queued, " \t\r\n");
        if (trimmed.len == 0) {
            if (plan_approved_pending) return "queued approved plan";
            return if (restore_to_editor) "queued draft ready" else "queued prompt ready";
        }
        const label = if (plan_approved_pending)
            "queued plan: "
        else if (restore_to_editor)
            "queued draft: "
        else
            "queued: ";
        const budget = out.len -| label.len;
        if (budget == 0) return label[0..@min(label.len, out.len)];
        const snippet = clipEndIntoLocal(out[label.len..], trimmed, budget);
        @memcpy(out[0..label.len], label);
        return out[0 .. label.len + snippet.len];
    }
    if (plan_approved_pending) return "approved plan ready";
    return "";
}

fn snapshotQueuedPromptPreview(
    state: *SpinnerState,
    out: *QueuePreviewSnapshot,
) void {
    out.* = .{};
    state.mutex.lock(rt.io) catch {};
    defer state.mutex.unlock(rt.io);

    const count = @min(state.prompt_queue_count, out.items.len);
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        const len = @min(state.prompt_queue_lens[idx], out.buffers[idx].len);
        if (len == 0) continue;
        @memcpy(out.buffers[idx][0..len], state.prompt_queue[idx][0..len]);
        out.items[idx] = out.buffers[idx][0..len];
        out.count += 1;
    }
    if (state.prompt_queue_count > out.count) {
        out.overflow_count = state.prompt_queue_count - out.count;
    }
}

fn snapshotQueuedPromptBacklog(
    queue: *const OwnedStringQueue,
    out: *QueuePreviewSnapshot,
) void {
    out.* = .{};
    const count = @min(queue.items.items.len, out.items.len);
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        const text = std.mem.trim(u8, queue.items.items[idx], " \t\r\n");
        const snippet = clipEndIntoLocal(&out.buffers[idx], text, out.buffers[idx].len);
        out.items[idx] = snippet;
        out.count += 1;
    }
    if (queue.items.items.len > out.count) {
        out.overflow_count = queue.items.items.len - out.count;
    }
}

fn appendTaskNotificationSummary(
    allocator: std.mem.Allocator,
    state: *TaskNotificationStripState,
    raw_line: []const u8,
) void {
    const notification_type = repl_session_mod.parseTaskNotificationField(raw_line, "type") orelse "";
    if (std.mem.eql(u8, notification_type, "idle_notification")) return;
    const status = repl_session_mod.parseTaskNotificationField(raw_line, "status") orelse "updated";
    const message_enc = repl_session_mod.parseTaskNotificationField(raw_line, "message") orelse "";
    const decoded = repl_session_mod.unescapeTaskTextAlloc(allocator, message_enc) catch allocator.dupe(u8, message_enc) catch null;
    defer if (decoded) |text| allocator.free(text);
    const message = if (decoded) |text| text else message_enc;
    var body_buf: [STRIP_TEXT_WIDTH]u8 = undefined;
    const body = if (message.len > 0)
        sanitizeText(message, body_buf[0..])
    else
        "(no details)";
    state.append(status, body);
}

fn pushPromptNotice(
    queue: *UiNotificationQueue,
    title: []const u8,
    body: []const u8,
    tag: []const u8,
    tone: repl_footer_mod.NoticeTone,
) void {
    queue.push(title, body, tag, tone);
}

fn buildRuntimeStripBanner(
    banner: *RuntimeStripBanner,
    tmux_state: []const u8,
    worktree_state: []const u8,
    agent_state: []const u8,
) void {
    banner.* = .{};

    const has_tmux = std.mem.trim(u8, tmux_state, " \t\r\n").len > 0;
    const has_worktree = std.mem.trim(u8, worktree_state, " \t\r\n").len > 0;
    const has_agent = std.mem.trim(u8, agent_state, " \t\r\n").len > 0;
    if (!has_tmux and !has_worktree and !has_agent) return;

    const title_raw = if (has_agent and has_tmux)
        "Agent session"
    else if (has_agent)
        "Active agent"
    else if (has_tmux)
        "Tmux session"
    else
        "Worktree context";
    const tag_raw = if (has_agent and has_tmux)
        "banner"
    else if (has_agent)
        "agent"
    else if (has_tmux)
        "tmux"
    else
        "tree";

    banner.title = copyTrimmedInto(&banner.title_buffer, title_raw);
    banner.tag = copyTrimmedInto(&banner.tag_buffer, tag_raw);
    banner.tone = if (has_agent or has_tmux) .accent else .dim;

    var pos: usize = 0;
    const pieces = [_][]const u8{ agent_state, tmux_state, worktree_state };
    for (pieces) |piece| {
        const trimmed = std.mem.trim(u8, piece, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (pos > 0) {
            const sep = " · ";
            if (pos + sep.len > banner.body_buffer.len) break;
            @memcpy(banner.body_buffer[pos .. pos + sep.len], sep);
            pos += sep.len;
        }
        const take = @min(trimmed.len, banner.body_buffer.len - pos);
        if (take == 0) break;
        @memcpy(banner.body_buffer[pos .. pos + take], trimmed[0..take]);
        pos += take;
        if (take < trimmed.len) break;
    }
    banner.body = banner.body_buffer[0..pos];
}

fn buildPromptStripItems(
    strip: *PromptStripItems,
    queued_prompt: ?[]const u8,
    restore_to_editor: bool,
    plan_approved_pending: bool,
    queue_snapshot: *const QueuePreviewSnapshot,
    task_notifications: *const TaskNotificationStripState,
    stashed_prompt: ?StashedPrompt,
    notifications: *const UiNotificationQueue,
    sandbox_violations: usize,
    runtime_banner: *const RuntimeStripBanner,
) void {
    if (queued_prompt) |queued| {
        const trimmed = std.mem.trim(u8, queued, " \t\r\n");
        strip.push(.{
            .kind = .queue,
            .title = if (plan_approved_pending)
                "Approved plan queued"
            else if (restore_to_editor)
                "Queued draft ready"
            else
                "Queued prompt ready",
            .body = if (trimmed.len > 0) trimmed else if (restore_to_editor) "restores into the composer" else "queued for the next turn",
            .tag = "queued",
            .tone = .accent,
            .focusable = true,
            .dismissable = true,
        });
    } else if (plan_approved_pending) {
        strip.push(.{
            .kind = .queue,
            .title = "Approved plan ready",
            .body = "waiting for the current turn to finish",
            .tag = "queued",
            .tone = .accent,
            .focusable = true,
            .dismissable = true,
        });
    }

    for (queue_snapshot.items[0..queue_snapshot.count]) |queued_preview| {
        if (queued_preview.len == 0) continue;
        strip.push(.{
            .kind = .queue,
            .title = "Queued next",
            .body = queued_preview,
            .tag = "queued",
            .tone = .dim,
            .focusable = true,
            .dismissable = true,
        });
    }
    if (queue_snapshot.overflow_count > 0) {
        var overflow_buf: [48]u8 = undefined;
        const title = std.fmt.bufPrint(&overflow_buf, "+{d} more queued", .{queue_snapshot.overflow_count}) catch "more queued";
        strip.push(.{
            .kind = .queue,
            .title = title,
            .tag = "queued",
            .tone = .dim,
            .focusable = true,
            .dismissable = true,
        });
    }

    for (task_notifications.title_items[0..task_notifications.count], 0..) |title, idx| {
        strip.push(.{
            .kind = .task,
            .title = title,
            .body = task_notifications.body_items[idx],
            .tag = "task",
            .tone = .dim,
            .focusable = true,
            .dismissable = true,
        });
    }
    if (task_notifications.overflow_count > 0) {
        var overflow_buf: [48]u8 = undefined;
        const title = std.fmt.bufPrint(&overflow_buf, "+{d} more task updates", .{task_notifications.overflow_count}) catch "more task updates";
        strip.push(.{
            .kind = .task,
            .title = title,
            .tag = "task",
            .tone = .dim,
            .focusable = true,
            .dismissable = true,
        });
    }

    if (stashed_prompt != null) {
        strip.push(.{
            .kind = .stash,
            .title = "Stashed draft",
            .body = "auto-restores after submit",
            .tag = "stash",
            .tone = .plain,
            .focusable = true,
            .dismissable = true,
        });
    }

    for (notifications.title_items[0..notifications.count], 0..) |title, idx| {
        strip.push(.{
            .kind = .notification,
            .title = title,
            .body = notifications.body_items[idx],
            .tag = notifications.tag_items[idx],
            .tone = notifications.tone_items[idx],
            .focusable = true,
            .dismissable = true,
        });
    }

    // Sandbox-violation footer hint (ui-render-12). A single strip with a
    // count -- not one strip per violation -- mirrors the reference's
    // SandboxPromptFooterHint and avoids spamming the footer on a burst of
    // denials.
    if (sandbox_violations > 0) {
        var sandbox_buf: [64]u8 = undefined;
        const noun = if (sandbox_violations == 1) "violation" else "violations";
        const title = std.fmt.bufPrint(&sandbox_buf, "{d} sandbox {s}", .{ sandbox_violations, noun }) catch "sandbox violations";
        strip.push(.{
            .kind = .notification,
            .title = title,
            .body = "ctrl+o for details",
            .tag = "sandbox",
            .tone = .accent,
            .focusable = true,
            .dismissable = true,
        });
    }

    if (runtime_banner.title.len > 0 or runtime_banner.body.len > 0) {
        strip.push(.{
            .kind = .runtime,
            .title = runtime_banner.title,
            .body = runtime_banner.body,
            .tag = runtime_banner.tag,
            .tone = runtime_banner.tone,
            .focusable = true,
            .dismissable = false,
        });
    }
}

fn isReferenceTokenByte(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or switch (ch) {
        '_', '-', '.', '/', '\\', '~', ':', '[', ']', '(', ')' => true,
        else => false,
    };
}

fn normalizeReferenceQuery(query: []const u8) []const u8 {
    var normalized = query;
    if (std.mem.startsWith(u8, normalized, "./") or std.mem.startsWith(u8, normalized, ".\\")) {
        normalized = normalized[2..];
    } else if (std.mem.startsWith(u8, normalized, "~/") or std.mem.startsWith(u8, normalized, "~\\")) {
        normalized = normalized[2..];
    }
    if (normalized.len > 0 and (normalized[0] == '/' or normalized[0] == '\\')) {
        normalized = normalized[1..];
    }
    return normalized;
}

fn pathNeedsReferenceQuotes(path: []const u8) bool {
    return std.mem.indexOfAny(u8, path, " \t") != null;
}

fn extractReferenceToken(input_text: []const u8, cursor: usize) ?ReferenceToken {
    const clamped_cursor = @min(cursor, input_text.len);
    if (clamped_cursor == 0 and (input_text.len == 0 or input_text[0] != '@')) return null;

    var at_pos_opt: ?usize = null;
    var idx = clamped_cursor;
    while (idx > 0) {
        idx -= 1;
        if (input_text[idx] == '\n' or input_text[idx] == '\r') break;
        if (input_text[idx] == '@' and (idx == 0 or std.ascii.isWhitespace(input_text[idx - 1]))) {
            at_pos_opt = idx;
            break;
        }
    }
    if (at_pos_opt == null and input_text.len > 0 and input_text[0] == '@') at_pos_opt = 0;

    const at_pos = at_pos_opt orelse return null;
    if (at_pos + 1 < input_text.len and input_text[at_pos + 1] == '"') {
        const content_start = at_pos + 2;
        var token_end = content_start;
        var closing_quote: ?usize = null;
        while (token_end < input_text.len) : (token_end += 1) {
            if (input_text[token_end] == '"') {
                closing_quote = token_end;
                break;
            }
            if (input_text[token_end] == '\n' or input_text[token_end] == '\r') break;
        }

        if (closing_quote) |quote_idx| {
            if (clamped_cursor > quote_idx + 1) return null;
            return .{
                .start = at_pos,
                .end = quote_idx + 1,
                .query = normalizeReferenceQuery(input_text[content_start..quote_idx]),
                .quoted = true,
            };
        }

        return .{
            .start = at_pos,
            .end = token_end,
            .query = normalizeReferenceQuery(input_text[content_start..token_end]),
            .quoted = true,
        };
    }

    var token_start = clamped_cursor;
    while (token_start > at_pos + 1 and isReferenceTokenByte(input_text[token_start - 1])) : (token_start -= 1) {}
    if (token_start == 0 or input_text[token_start - 1] != '@') return null;

    var token_end = clamped_cursor;
    while (token_end < input_text.len and isReferenceTokenByte(input_text[token_end])) : (token_end += 1) {}

    return .{
        .start = at_pos,
        .end = token_end,
        .query = normalizeReferenceQuery(input_text[token_start..token_end]),
        .quoted = false,
    };
}

fn pathBasename(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse std.mem.lastIndexOfScalar(u8, path, '\\') orelse return path;
    if (slash + 1 >= path.len) return path;
    return path[slash + 1 ..];
}

fn pathDepth(path: []const u8) usize {
    var depth: usize = 0;
    for (path) |ch| {
        if (ch == '/' or ch == '\\') depth += 1;
    }
    return depth;
}

// These thin aliases used to be local duplicates of parse_helpers'
// versions. Re-exporting keeps call sites compact while collapsing
// the implementation down to one place so future tweaks (e.g. unicode
// case folding) only touch parse_helpers.
const eqlIgnoreCase = @import("../core/parse_helpers.zig").eqlIgnoreCase;
const startsWithIgnoreCase = @import("../core/parse_helpers.zig").startsWithIgnoreCase;
const indexOfIgnoreCase = @import("../core/parse_helpers.zig").indexOfIgnoreCase;

fn subsequenceSpanIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;

    var query_index: usize = 0;
    var first_match: ?usize = null;
    var last_match: usize = 0;

    for (haystack, 0..) |ch, idx| {
        if (std.ascii.toLower(ch) != std.ascii.toLower(needle[query_index])) continue;
        if (first_match == null) first_match = idx;
        last_match = idx;
        query_index += 1;
        if (query_index == needle.len) return last_match - first_match.? + 1;
    }
    return null;
}

fn referenceScore(path: []const u8, query: []const u8) ?i32 {
    const normalized_query = normalizeReferenceQuery(query);
    const length_penalty: i32 = @intCast(@min(path.len, 1024));
    const depth_penalty: i32 = @intCast(@min(pathDepth(path), 32) * 32);
    const basename = pathBasename(path);

    if (normalized_query.len == 0) {
        return 12_000 - depth_penalty - length_penalty;
    }
    if (eqlIgnoreCase(path, normalized_query)) {
        return 50_000 - length_penalty;
    }
    if (eqlIgnoreCase(basename, normalized_query)) {
        return 46_000 - length_penalty;
    }
    if (startsWithIgnoreCase(path, normalized_query)) {
        return 40_000 - length_penalty;
    }
    if (startsWithIgnoreCase(basename, normalized_query)) {
        return 35_000 - length_penalty;
    }
    if (indexOfIgnoreCase(path, normalized_query)) |offset| {
        const offset_penalty: i32 = @intCast(@min(offset, 1024) * 6);
        return 26_000 - offset_penalty - length_penalty;
    }
    if (subsequenceSpanIgnoreCase(path, normalized_query)) |span| {
        const span_penalty: i32 = @intCast(@min(span, 1024) * 4);
        return 18_000 - span_penalty - length_penalty;
    }
    return null;
}

fn referenceMatchBeats(score: i32, text: []const u8, other_score: i32, other_text: []const u8) bool {
    if (score != other_score) return score > other_score;
    if (text.len != other_text.len) return text.len < other_text.len;
    return std.mem.lessThan(u8, text, other_text);
}

fn insertReferenceMatch(out: *ReferenceSuggestions, item: ReferenceSuggestion, score: i32) void {
    if (out.count == MAX_REFERENCE_SUGGESTIONS) {
        const last_index = out.count - 1;
        if (!referenceMatchBeats(score, item.text, out.scores[last_index], out.matches[last_index].text)) return;
    }

    var pos: usize = if (out.count < MAX_REFERENCE_SUGGESTIONS) blk: {
        out.count += 1;
        break :blk out.count - 1;
    } else MAX_REFERENCE_SUGGESTIONS - 1;

    while (pos > 0 and referenceMatchBeats(score, item.text, out.scores[pos - 1], out.matches[pos - 1].text)) : (pos -= 1) {
        out.matches[pos] = out.matches[pos - 1];
        out.scores[pos] = out.scores[pos - 1];
    }

    out.matches[pos] = item;
    out.scores[pos] = score;
}

fn referenceDynamicScore(item: DynamicCommandSuggestion, query: []const u8) ?i32 {
    const normalized_query = normalizeReferenceQuery(query);
    const text = item.text;
    const primary = item.primary;
    const length_penalty: i32 = @intCast(@min(text.len, 1024));

    if (normalized_query.len == 0) {
        return 11_000 - length_penalty;
    }
    if (eqlIgnoreCase(text, normalized_query)) {
        return 48_000 - length_penalty;
    }
    if (eqlIgnoreCase(primary, normalized_query)) {
        return 44_000 - length_penalty;
    }
    if (startsWithIgnoreCase(text, normalized_query)) {
        return 39_000 - length_penalty;
    }
    if (startsWithIgnoreCase(primary, normalized_query)) {
        return 35_000 - length_penalty;
    }
    if (indexOfIgnoreCase(text, normalized_query)) |offset| {
        const offset_penalty: i32 = @intCast(@min(offset, 1024) * 6);
        return 27_000 - offset_penalty - length_penalty;
    }
    if (indexOfIgnoreCase(primary, normalized_query)) |offset| {
        const offset_penalty: i32 = @intCast(@min(offset, 1024) * 6);
        return 24_000 - offset_penalty - length_penalty;
    }
    if (subsequenceSpanIgnoreCase(text, normalized_query)) |span| {
        const span_penalty: i32 = @intCast(@min(span, 1024) * 4);
        return 18_000 - span_penalty - length_penalty;
    }
    if (subsequenceSpanIgnoreCase(primary, normalized_query)) |span| {
        const span_penalty: i32 = @intCast(@min(span, 1024) * 4);
        return 16_000 - span_penalty - length_penalty;
    }
    return null;
}

fn collectReferenceSuggestions(
    items: []const repl_quick_open_mod.Item,
    dynamic_cache: *const DynamicCommandSuggestionCache,
    input_text: []const u8,
    cursor: usize,
) ReferenceSuggestions {
    var out = ReferenceSuggestions{};
    const token = extractReferenceToken(input_text, cursor) orelse return out;
    out.token = token;

    for (items) |item| {
        const score = referenceScore(item.path, token.query) orelse continue;
        insertReferenceMatch(&out, .{
            .source = .reference,
            .text = item.path,
            .primary = item.path,
            .secondary = "workspace file",
        }, score);
    }

    for (dynamic_cache.items.items) |item| {
        const score = referenceDynamicScore(item, token.query) orelse continue;
        insertReferenceMatch(&out, .{
            .source = item.source,
            .text = item.text,
            .primary = item.primary,
            .secondary = item.secondary,
        }, score);
    }

    return out;
}

fn formatReferenceCompletion(
    out: []u8,
    path: []const u8,
    force_quotes: bool,
    complete: bool,
    trailing_space: bool,
) []const u8 {
    if (out.len == 0) return "";

    const use_quotes = force_quotes or pathNeedsReferenceQuotes(path);
    var pos: usize = 0;
    out[pos] = '@';
    pos += 1;

    if (use_quotes and pos < out.len) {
        out[pos] = '"';
        pos += 1;
    }

    const take = @min(path.len, out.len - pos);
    if (take > 0) {
        @memcpy(out[pos .. pos + take], path[0..take]);
        pos += take;
    }

    if (use_quotes and complete and pos < out.len) {
        out[pos] = '"';
        pos += 1;
    }

    if (trailing_space and pos < out.len) {
        out[pos] = ' ';
        pos += 1;
    }

    return out[0..pos];
}

fn replaceInputRange(
    input_buf: *std_io.StringBuilder,
    cursor: *usize,
    start: usize,
    end: usize,
    replacement: []const u8,
) !void {
    const clamped_start = @min(start, input_buf.items().len);
    const clamped_end = @min(@max(end, clamped_start), input_buf.items().len);

    var remove_index = clamped_start;
    while (remove_index < clamped_end) : (remove_index += 1) {
        _ = input_buf.orderedRemove(clamped_start);
    }

    var replacement_cursor = clamped_start;
    try insertInputBytesAt(input_buf, &replacement_cursor, replacement);
    cursor.* = replacement_cursor;
}

fn resetReferenceSuggestionSelection(selection: *usize, touched: *bool) void {
    selection.* = 0;
    touched.* = false;
}

fn syncReferenceSuggestionSelection(suggestions: *const ReferenceSuggestions, selection: *usize, touched: *bool) usize {
    if (suggestions.count == 0) {
        resetReferenceSuggestionSelection(selection, touched);
        return 0;
    }
    if (selection.* >= suggestions.count) {
        selection.* = suggestions.count - 1;
    }
    return suggestions.count;
}

fn acceptSelectedReferenceSuggestion(
    input_buf: *std_io.StringBuilder,
    cursor: *usize,
    suggestions: *const ReferenceSuggestions,
    selection: usize,
) !bool {
    const token = suggestions.token orelse return false;
    const visible = suggestions.visible();
    if (selection >= visible.len) return false;

    var replacement_buf: [1024]u8 = undefined;
    const replacement = formatReferenceCompletion(replacement_buf[0..], visible[selection].text, token.quoted, true, true);
    const current = input_buf.items()[token.start..@min(token.end, input_buf.items().len)];
    if (std.mem.eql(u8, current, replacement)) {
        cursor.* = token.start + replacement.len;
        return false;
    }

    try replaceInputRange(input_buf, cursor, token.start, token.end, replacement);
    return true;
}

fn applyReferenceAutocomplete(
    input_buf: *std_io.StringBuilder,
    cursor: *usize,
    hint_buf: *[320]u8,
    hint_len: *usize,
    suggestions: *const ReferenceSuggestions,
) !bool {
    const token = suggestions.token orelse return false;
    const visible = suggestions.visible();
    if (visible.len == 0) return false;

    if (visible.len == 1) {
        var replacement_buf: [1024]u8 = undefined;
        const replacement = formatReferenceCompletion(replacement_buf[0..], visible[0].text, token.quoted, true, true);
        try replaceInputRange(input_buf, cursor, token.start, token.end, replacement);
        clearHint(hint_len);
        return true;
    }

    var texts: [MAX_REFERENCE_SUGGESTIONS][]const u8 = undefined;
    for (visible, 0..) |item, idx| texts[idx] = item.text;
    const lcp = repl_input_mod.longestCommonPrefix(texts[0..visible.len]);
    if (lcp.len > token.query.len) {
        var replacement_buf: [1024]u8 = undefined;
        const replacement = formatReferenceCompletion(replacement_buf[0..], lcp, token.quoted, false, false);
        try replaceInputRange(input_buf, cursor, token.start, token.end, replacement);
        clearHint(hint_len);
        return true;
    }

    setHint(hint_buf, hint_len, "tab: use up/down to pick a reference");
    return false;
}

fn computeReferenceInlineGhostText(
    out: []u8,
    input_text: []const u8,
    cursor: usize,
    suggestions: *const ReferenceSuggestions,
    selection: usize,
    selection_touched: bool,
) []const u8 {
    const token = suggestions.token orelse return "";
    if (cursor != input_text.len or token.end != input_text.len) return "";

    const visible = suggestions.visible();
    if (visible.len == 0) return "";
    const current = input_text[token.start..token.end];

    var replacement_buf: [1024]u8 = undefined;

    if (selection_touched and selection < visible.len) {
        const replacement = formatReferenceCompletion(replacement_buf[0..], visible[selection].text, token.quoted, true, true);
        if (replacement.len > current.len and std.mem.startsWith(u8, replacement, current)) {
            const take = @min(replacement.len - current.len, out.len);
            @memcpy(out[0..take], replacement[current.len .. current.len + take]);
            return out[0..take];
        }
    }

    if (visible.len == 1) {
        const replacement = formatReferenceCompletion(replacement_buf[0..], visible[0].text, token.quoted, true, true);
        if (replacement.len > current.len and std.mem.startsWith(u8, replacement, current)) {
            const take = @min(replacement.len - current.len, out.len);
            @memcpy(out[0..take], replacement[current.len .. current.len + take]);
            return out[0..take];
        }
        return "";
    }

    var texts: [MAX_REFERENCE_SUGGESTIONS][]const u8 = undefined;
    for (visible, 0..) |item, idx| texts[idx] = item.text;
    const lcp = repl_input_mod.longestCommonPrefix(texts[0..visible.len]);
    const replacement = formatReferenceCompletion(replacement_buf[0..], lcp, token.quoted, false, false);
    if (replacement.len > current.len and std.mem.startsWith(u8, replacement, current)) {
        const take = @min(replacement.len - current.len, out.len);
        @memcpy(out[0..take], replacement[current.len .. current.len + take]);
        return out[0..take];
    }
    return "";
}

fn computeInlineGhostText(
    out: []u8,
    input_text: []const u8,
    cursor: usize,
    slash_selection: usize,
    slash_selection_touched: bool,
    reference_suggestions: *const ReferenceSuggestions,
    reference_selection: usize,
    reference_selection_touched: bool,
) []const u8 {
    const reference_ghost = computeReferenceInlineGhostText(
        out,
        input_text,
        cursor,
        reference_suggestions,
        reference_selection,
        reference_selection_touched,
    );
    if (reference_ghost.len > 0) return reference_ghost;

    if (cursor != input_text.len) return "";
    const suggestions = collectSlashSuggestions(input_text);
    const matches = suggestions.visible();
    if (suggestions.total_matches == 0 or matches.len == 0) return "";

    if (slash_selection_touched) {
        if (slashSuggestionAt(input_text, slash_selection)) |selected| {
            if (selected.len > input_text.len and std.mem.startsWith(u8, selected, input_text)) {
                return selected[input_text.len..];
            }
        }
    }

    if (suggestions.total_matches == 1) {
        const match = matches[0];
        if (match.len > input_text.len and std.mem.startsWith(u8, match, input_text)) {
            return match[input_text.len..];
        }
        return "";
    }

    const lcp = repl_input_mod.longestCommonPrefix(matches);
    if (lcp.len > input_text.len and std.mem.startsWith(u8, lcp, input_text)) {
        return lcp[input_text.len..];
    }
    return "";
}

fn appendQueueFooterRows(
    footer_rows: *PromptFooterRows,
    queued_prompt: ?[]const u8,
    restore_to_editor: bool,
    plan_approved_pending: bool,
    queue_snapshot: *const QueuePreviewSnapshot,
) void {
    if (queued_prompt) |queued| {
        const trimmed = std.mem.trim(u8, queued, " \t\r\n");
        footer_rows.push(.{
            .kind = .queue,
            .primary = if (trimmed.len > 0) trimmed else if (plan_approved_pending) "approved plan queued" else "queued prompt ready",
            .secondary = if (plan_approved_pending)
                "approved plan will run next"
            else if (restore_to_editor)
                "restores into the composer"
            else
                "queued for the next turn",
            .tag = "queued",
            .source = .queue,
            .tone = .accent,
        });
    } else if (plan_approved_pending) {
        footer_rows.push(.{
            .kind = .queue,
            .primary = "approved plan ready",
            .secondary = "waiting for the current turn to finish",
            .tag = "queued",
            .source = .queue,
            .tone = .accent,
        });
    }

    for (queue_snapshot.items[0..queue_snapshot.count]) |queued_preview| {
        const trimmed = std.mem.trim(u8, queued_preview, " \t\r\n");
        footer_rows.push(.{
            .kind = .queue,
            .primary = if (trimmed.len > 0) trimmed else "queued prompt",
            .secondary = "still pending",
            .tag = "queued",
            .source = .queue,
            .tone = .dim,
        });
    }

    if (queue_snapshot.overflow_count > 0) {
        var overflow_buf: [48]u8 = undefined;
        const text = std.fmt.bufPrint(&overflow_buf, "+{d} more queued", .{queue_snapshot.overflow_count}) catch "more queued";
        footer_rows.push(.{
            .kind = .notice,
            .primary = text,
            .secondary = "",
            .tag = "",
            .source = .notice,
            .tone = .dim,
        });
    }
}

fn appendStashFooterRow(footer_rows: *PromptFooterRows, stashed_prompt: ?StashedPrompt) void {
    if (stashed_prompt == null) return;
    footer_rows.push(.{
        .kind = .stash,
        .primary = "Stashed draft ready",
        .secondary = "Ctrl+S restores it into the composer",
        .tag = "stash",
        .source = .notice,
        .tone = .plain,
    });
}

fn appendStarterFooterRows(
    footer_rows: *PromptFooterRows,
    starters: []const StarterSuggestion,
    selection: usize,
) void {
    const start_index = footer_rows.count;
    for (starters) |starter| {
        footer_rows.push(suggestionRow(starter.tag, starter.text, starter.description, if (std.mem.eql(u8, starter.tag, "recent")) .history else .workspace));
    }
    if (starters.len > 0) {
        footer_rows.selected_index = start_index + @min(selection, starters.len - 1);
    }
}

fn appendReferenceFooterRows(
    footer_rows: *PromptFooterRows,
    suggestions: []const ReferenceSuggestion,
    selection: usize,
) void {
    const start_index = footer_rows.count;
    for (suggestions) |suggestion| {
        footer_rows.push(suggestionRow(
            repl_footer_mod.defaultTag(.suggestion, suggestion.source),
            suggestion.primary,
            suggestion.secondary,
            suggestion.source,
        ));
    }
    if (suggestions.len > 0) {
        footer_rows.selected_index = start_index + @min(selection, suggestions.len - 1);
    }
}

fn appendSlashFooterRows(
    footer_rows: *PromptFooterRows,
    suggestions: []const []const u8,
    selection: usize,
) void {
    const start_index = footer_rows.count;
    for (suggestions) |command| {
        footer_rows.push(suggestionRow("cmd", command, repl_help_mod.descriptionForUsagePrefix(command) orelse "", .command));
    }
    if (suggestions.len > 0) {
        footer_rows.selected_index = start_index + @min(selection, suggestions.len - 1);
    }
}

const QueueStripSelection = union(enum) {
    current,
    backlog: usize,
    overflow,
};

const TaskStripSelection = union(enum) {
    item: usize,
    overflow,
};

fn stripItemOrdinalOfKind(items: []const repl_footer_mod.StripItem, selected_idx: usize, kind: repl_footer_mod.StripKind) ?usize {
    if (selected_idx >= items.len or items[selected_idx].kind != kind) return null;
    var ordinal: usize = 0;
    for (items[0..selected_idx]) |item| {
        if (item.kind == kind) ordinal += 1;
    }
    return ordinal;
}

fn queueStripSelection(
    items: []const repl_footer_mod.StripItem,
    selected_idx: usize,
    queued_prompt: ?[]const u8,
    plan_approved_pending: bool,
    queue_snapshot: *const QueuePreviewSnapshot,
) ?QueueStripSelection {
    var ordinal = stripItemOrdinalOfKind(items, selected_idx, .queue) orelse return null;
    if (queued_prompt != null or plan_approved_pending) {
        if (ordinal == 0) return .current;
        ordinal -= 1;
    }
    if (ordinal < queue_snapshot.count) return .{ .backlog = ordinal };
    if (queue_snapshot.overflow_count > 0 and ordinal == queue_snapshot.count) return .overflow;
    return null;
}

fn taskStripSelection(items: []const repl_footer_mod.StripItem, selected_idx: usize, state: *const TaskNotificationStripState) ?TaskStripSelection {
    const ordinal = stripItemOrdinalOfKind(items, selected_idx, .task) orelse return null;
    if (ordinal < state.count) return .{ .item = ordinal };
    if (state.overflow_count > 0 and ordinal == state.count) return .overflow;
    return null;
}

fn notificationStripIndex(items: []const repl_footer_mod.StripItem, selected_idx: usize, notices: *const UiNotificationQueue) ?usize {
    const ordinal = stripItemOrdinalOfKind(items, selected_idx, .notification) orelse return null;
    if (ordinal >= notices.count) return null;
    return ordinal;
}

fn previousPromptStripIndex(items: []const repl_footer_mod.StripItem, current: ?usize) ?usize {
    if (items.len == 0) return null;
    if (current) |idx| {
        if (idx == 0) return null;
        return idx - 1;
    }
    return items.len - 1;
}

fn nextPromptStripIndex(items: []const repl_footer_mod.StripItem, current: ?usize) ?usize {
    if (items.len == 0) return null;
    if (current) |idx| {
        if (idx + 1 >= items.len) return null;
        return idx + 1;
    }
    return 0;
}

fn fetchCompactFooterState(
    allocator: std.mem.Allocator,
    handler: Handler,
    command: []const u8,
    out: []u8,
) []const u8 {
    const cmd_cb = handler.command orelse return "";
    const maybe_output = cmd_cb(handler.ctx, allocator, command) catch return "";
    defer if (maybe_output) |output| allocator.free(output);
    const raw = maybe_output orelse return "";
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or out.len == 0) return "";
    const take = @min(trimmed.len, out.len);
    @memcpy(out[0..take], trimmed[0..take]);
    return out[0..take];
}

fn copyTrimmedInto(out: []u8, raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or out.len == 0) return "";
    const take = @min(trimmed.len, out.len);
    @memcpy(out[0..take], trimmed[0..take]);
    return out[0..take];
}

fn reloadRuntimeKeybindingsUi(
    allocator: std.mem.Allocator,
    transcript: *UiTranscript,
    use_fullscreen: bool,
    writer: anytype,
    scroll_offset: usize,
    mode: SessionMode,
    options: *Options,
    runtime_keybindings: *keybindings_mod.RuntimeKeybindings,
    notifications: *UiNotificationQueue,
    input_hint_buf: *[320]u8,
    input_hint_len: *usize,
) !void {
    runtime_keybindings.deinit(allocator);
    var report = keybindings_mod.loadRuntimeKeybindingsReport(allocator);
    runtime_keybindings.* = report.keybindings;
    options.keybindings = runtime_keybindings;
    // We moved `report.keybindings` into `runtime_keybindings`, so free only
    // the structured validation warnings the report still owns. (Reserved
    // conflicts are already surfaced via report.warning_count / std.log.)
    const validation_warning_count = report.warnings.items.len;
    defer report.warnings.deinit(allocator);

    // Combine reserved-binding warnings with the structured validation
    // warnings (invalid_context / invalid_action / duplicate / parse_error).
    const total_warnings = report.warning_count + validation_warning_count;
    const message = switch (report.status) {
        .loaded_file => if (total_warnings > 0)
            try std.fmt.allocPrint(allocator, "reloaded keybindings ({d} warning{s})", .{ total_warnings, if (total_warnings == 1) "" else "s" })
        else
            try allocator.dupe(u8, "reloaded keybindings"),
        .defaults_missing_file => try allocator.dupe(u8, "no keybindings file found; using defaults"),
        .defaults_parse_error => try allocator.dupe(u8, "keybindings parse failed; using defaults"),
    };
    defer allocator.free(message);
    setHint(input_hint_buf, input_hint_len, message);
    switch (report.status) {
        .loaded_file => pushPromptNotice(
            notifications,
            "Keybindings reloaded",
            if (total_warnings > 0) message else "prompt-side bindings updated",
            "keys",
            if (total_warnings > 0) .plain else .accent,
        ),
        .defaults_missing_file => pushPromptNotice(
            notifications,
            "Keybindings defaults",
            "no keybindings file found; using defaults",
            "keys",
            .plain,
        ),
        .defaults_parse_error => pushPromptNotice(
            notifications,
            "Keybindings fallback",
            "keybindings parse failed; using defaults",
            "keys",
            .plain,
        ),
    }

    if (use_fullscreen) {
        try transcript.appendLine(allocator, message);
        try renderFullScreen(writer, transcript, true, "", scroll_offset, message, mode, options.*);
    } else {
        try writer.print("{s}\n", .{message});
    }
}

fn applySlashAutocomplete(
    input_buf: *std_io.StringBuilder,
    hint_buf: *[320]u8,
    hint_len: *usize,
) !void {
    return repl_input_mod.applySlashAutocomplete(input_buf, hint_buf, hint_len);
}

fn collectSlashSuggestions(input_text: []const u8) SlashSuggestions {
    return repl_input_mod.collectSlashSuggestions(input_text);
}

fn matchesCommandQuery(query: []const u8, candidate: []const u8) bool {
    if (query.len == 0) return true;
    if (startsWithIgnoreCase(candidate, query)) return true;
    if (indexOfIgnoreCase(candidate, query) != null) return true;
    // Subsequence fuzzy match: query chars appear in order within candidate,
    // case-insensitive (e.g. "dpl" matches "deploy"). Ranked below prefix and
    // substring matches by commandMatchRank.
    return subsequenceSpanIgnoreCase(candidate, query) != null;
}

/// Rank a candidate against a query for stable suggestion ordering. Higher is
/// better. Mirrors the precedence the reference uses: exact > prefix >
/// substring > subsequence > no-match. The usage-frequency boost (Task 8,
/// misc-utils-15) is added on top of this by the caller; until that lands the
/// boost is 0 and ordering degrades to prefix-first + alphabetical, already an
/// improvement over append order.
fn commandMatchRank(query: []const u8, candidate: []const u8) i32 {
    if (query.len == 0) return 1;
    if (eqlIgnoreCase(candidate, query)) return 5;
    if (startsWithIgnoreCase(candidate, query)) return 4;
    if (indexOfIgnoreCase(candidate, query) != null) return 3;
    if (subsequenceSpanIgnoreCase(candidate, query) != null) return 2;
    return 0;
}

/// Process-cached usage snapshot for suggestion ranking. The snapshot reads
/// `~/.zcode/skill-usage.json` once and is reused across every comparator call
/// and every keystroke within its TTL, so we never do disk I/O per keystroke
/// (the Task 8 footgun: `score` reads a cached snapshot, never per-comparison
/// disk). Rebuilt lazily when older than `usage_snapshot_ttl_ms`.
var usage_snapshot: ?skill_usage_mod.Snapshot = null;
var usage_snapshot_built_ms: i64 = 0;
const usage_snapshot_ttl_ms: i64 = 5_000;

/// Usage-frequency score hook for suggestion ranking (Task 8, misc-utils-15).
/// Returns `skill_usage.score(name)` from the cached snapshot; 0 for any name
/// with no recorded use (and for the whole map on any load failure).
fn commandUsageScore(name: []const u8) f64 {
    const now = clock.nowMillis();
    const stale = usage_snapshot == null or (now -| usage_snapshot_built_ms) >= usage_snapshot_ttl_ms;
    if (stale) {
        if (usage_snapshot) |*old| old.deinit();
        usage_snapshot = skill_usage_mod.snapshot(rt.gpa);
        usage_snapshot_built_ms = now;
    }
    return usage_snapshot.?.score(name);
}

/// Strip a leading `/` so `/deploy` and `deploy` rank identically against a
/// query and sort alphabetically by their bare name.
fn bareCommandName(text: []const u8) []const u8 {
    if (text.len > 0 and text[0] == '/') return text[1..];
    return text;
}

const CommandRankKey = struct {
    suggestion: CommandSuggestion,
    usage: f64,
    rank: i32,
};

fn commandRankLessThan(_: void, a: CommandRankKey, b: CommandRankKey) bool {
    // 1. Usage-frequency boost (descending). Equal scores fall through.
    if (a.usage != b.usage) return a.usage > b.usage;
    // 2. Match quality (descending): prefix beats substring beats subsequence.
    if (a.rank != b.rank) return a.rank > b.rank;
    // 3. Alphabetical by bare name (ascending) for a stable, deterministic tie-break.
    return std.mem.lessThan(u8, bareCommandName(a.suggestion.text), bareCommandName(b.suggestion.text));
}

const UsageScoreFn = *const fn ([]const u8) f64;

fn collectCommandSuggestions(
    input_text: []const u8,
    dynamic_cache: *const DynamicCommandSuggestionCache,
) CommandSuggestionSet {
    return collectCommandSuggestionsWith(input_text, dynamic_cache, commandUsageScore);
}

/// Core suggestion collection with an injectable usage-score function so the
/// ranking is unit-testable with deterministic scores (production passes
/// commandUsageScore). Gathers matching candidates (built-in + dynamic) into a
/// fixed buffer, stable-sorts by (usage desc, match-rank desc, alphabetical
/// asc), then pushes the best ones into the visible set.
fn collectCommandSuggestionsWith(
    input_text: []const u8,
    dynamic_cache: *const DynamicCommandSuggestionCache,
    usage_score_fn: UsageScoreFn,
) CommandSuggestionSet {
    var out = CommandSuggestionSet{};
    const query = repl_input_mod.slashAutocompleteQuery(input_text) orelse return out;

    // The cap is generous; overflow just drops the lowest-ranked extras, which
    // is acceptable for suggestions.
    const MAX_CANDIDATES = 256;
    var keys: [MAX_CANDIDATES]CommandRankKey = undefined;
    var count: usize = 0;

    const builtin = collectSlashSuggestions(input_text);
    for (builtin.visible()) |command| {
        if (count >= MAX_CANDIDATES) break;
        keys[count] = .{
            .suggestion = .{
                .source = .command,
                .text = command,
                .primary = command,
                .secondary = repl_help_mod.descriptionForUsagePrefix(command) orelse "",
            },
            .usage = usage_score_fn(bareCommandName(command)),
            .rank = commandMatchRank(query, command),
        };
        count += 1;
    }

    for (dynamic_cache.items.items) |item| {
        if (count >= MAX_CANDIDATES) break;
        const rank_text = commandMatchRank(query, item.text);
        const rank_primary = commandMatchRank(query, item.primary);
        const rank = @max(rank_text, rank_primary);
        if (rank == 0) continue;
        keys[count] = .{
            .suggestion = .{
                .source = item.source,
                .text = item.text,
                .primary = item.primary,
                .secondary = item.secondary,
            },
            .usage = usage_score_fn(bareCommandName(item.text)),
            .rank = rank,
        };
        count += 1;
    }

    std.mem.sort(CommandRankKey, keys[0..count], {}, commandRankLessThan);

    for (keys[0..count]) |key| out.push(key.suggestion);

    return out;
}

fn appendCommandFooterRows(
    footer_rows: *PromptFooterRows,
    suggestions: []const CommandSuggestion,
    selection: usize,
) void {
    const start_index = footer_rows.count;
    for (suggestions) |suggestion| {
        footer_rows.push(suggestionRow(
            repl_footer_mod.defaultTag(.suggestion, suggestion.source),
            suggestion.primary,
            suggestion.secondary,
            suggestion.source,
        ));
    }
    if (suggestions.len > 0) {
        footer_rows.selected_index = start_index + @min(selection, suggestions.len - 1);
    }
}

fn syncCommandSuggestionSelection(suggestions: *const CommandSuggestionSet, selection: *usize, touched: *bool) usize {
    if (suggestions.count == 0) {
        resetSlashSuggestionSelection(selection, touched);
        return 0;
    }
    if (selection.* >= suggestions.count) selection.* = suggestions.count - 1;
    return suggestions.count;
}

fn acceptSelectedCommandSuggestion(
    input_buf: *std_io.StringBuilder,
    cursor: *usize,
    suggestions: *const CommandSuggestionSet,
    selection: usize,
) !bool {
    const visible = suggestions.visible();
    if (selection >= visible.len) return false;
    const suggestion = visible[selection];
    if (std.mem.eql(u8, input_buf.items(), suggestion.text)) {
        cursor.* = input_buf.items().len;
        return false;
    }
    try replaceInput(input_buf, suggestion.text);
    cursor.* = input_buf.items().len;
    return true;
}

fn willCommandAutocompleteMutate(input_text: []const u8, suggestions: *const CommandSuggestionSet) bool {
    if (repl_input_mod.slashAutocompleteQuery(input_text) == null) return false;
    const visible = suggestions.visible();
    if (visible.len == 0) return false;
    if (visible.len == 1) return !std.mem.eql(u8, visible[0].text, input_text);

    var texts: [MAX_COMMAND_SUGGESTIONS][]const u8 = undefined;
    for (visible, 0..) |item, idx| texts[idx] = item.text;
    const lcp = repl_input_mod.longestCommonPrefix(texts[0..visible.len]);
    return lcp.len > input_text.len;
}

fn applyCommandAutocomplete(
    input_buf: *std_io.StringBuilder,
    hint_buf: *[320]u8,
    hint_len: *usize,
    suggestions: *const CommandSuggestionSet,
) !void {
    const visible = suggestions.visible();
    if (visible.len == 0) return;
    if (visible.len == 1) {
        try replaceInput(input_buf, visible[0].text);
        clearHint(hint_len);
        return;
    }

    var texts: [MAX_COMMAND_SUGGESTIONS][]const u8 = undefined;
    for (visible, 0..) |item, idx| texts[idx] = item.text;
    const lcp = repl_input_mod.longestCommonPrefix(texts[0..visible.len]);
    if (lcp.len > input_buf.items().len and std.mem.startsWith(u8, lcp, input_buf.items())) {
        try replaceInput(input_buf, lcp);
        clearHint(hint_len);
        return;
    }

    setHint(hint_buf, hint_len, "tab: use up/down to pick a command");
}

fn computeCommandInlineGhostText(
    out: []u8,
    input_text: []const u8,
    cursor: usize,
    suggestions: *const CommandSuggestionSet,
    selection: usize,
    selection_touched: bool,
) []const u8 {
    if (cursor != input_text.len) return "";
    const visible = suggestions.visible();
    if (visible.len == 0) return "";

    if (selection_touched and selection < visible.len) {
        const selected = visible[selection].text;
        if (selected.len > input_text.len and std.mem.startsWith(u8, selected, input_text)) {
            const take = @min(selected.len - input_text.len, out.len);
            @memcpy(out[0..take], selected[input_text.len .. input_text.len + take]);
            return out[0..take];
        }
    }

    if (visible.len == 1) {
        const match = visible[0].text;
        if (match.len > input_text.len and std.mem.startsWith(u8, match, input_text)) {
            const take = @min(match.len - input_text.len, out.len);
            @memcpy(out[0..take], match[input_text.len .. input_text.len + take]);
            return out[0..take];
        }
        return "";
    }

    var texts: [MAX_COMMAND_SUGGESTIONS][]const u8 = undefined;
    for (visible, 0..) |item, idx| texts[idx] = item.text;
    const lcp = repl_input_mod.longestCommonPrefix(texts[0..visible.len]);
    if (lcp.len > input_text.len and std.mem.startsWith(u8, lcp, input_text)) {
        const take = @min(lcp.len - input_text.len, out.len);
        @memcpy(out[0..take], lcp[input_text.len .. input_text.len + take]);
        return out[0..take];
    }
    return "";
}

fn slashSuggestionAt(input_text: []const u8, match_index: usize) ?[]const u8 {
    return repl_input_mod.slashSuggestionAt(input_text, match_index);
}

fn replaceInput(input_buf: *std_io.StringBuilder, text: []const u8) !void {
    return repl_input_mod.replaceInput(input_buf, text);
}

fn resetSlashSuggestionSelection(selection: *usize, touched: *bool) void {
    selection.* = 0;
    touched.* = false;
}

fn syncSlashSuggestionSelection(input_text: []const u8, selection: *usize, touched: *bool) usize {
    const suggestions = collectSlashSuggestions(input_text);
    if (suggestions.total_matches == 0) {
        resetSlashSuggestionSelection(selection, touched);
        return 0;
    }
    if (selection.* >= suggestions.total_matches) {
        selection.* = suggestions.total_matches - 1;
    }
    return suggestions.total_matches;
}

fn acceptSelectedSlashSuggestion(
    input_buf: *std_io.StringBuilder,
    cursor: *usize,
    selection: usize,
) !bool {
    const suggestion = slashSuggestionAt(input_buf.items(), selection) orelse return false;
    if (std.mem.eql(u8, input_buf.items(), suggestion)) {
        cursor.* = input_buf.items().len;
        return false;
    }
    try replaceInput(input_buf, suggestion);
    cursor.* = input_buf.items().len;
    return true;
}

fn willSlashAutocompleteMutate(input_text: []const u8) bool {
    if (repl_input_mod.slashAutocompleteQuery(input_text) == null) return false;

    const suggestions = collectSlashSuggestions(input_text);
    const matches = suggestions.visible();

    if (suggestions.total_matches == 1) return true;
    if (suggestions.total_matches == 0 or matches.len == 0) return false;

    const lcp = repl_input_mod.longestCommonPrefix(matches);
    return lcp.len > input_text.len;
}

fn clearHint(hint_len: *usize) void {
    repl_input_mod.clearHint(hint_len);
}

fn setHint(hint_buf: *[320]u8, hint_len: *usize, msg: []const u8) void {
    repl_input_mod.setHint(hint_buf, hint_len, msg);
}

fn composeStatusHint(out: *[320]u8, runtime_hint: []const u8, input_hint: []const u8) []const u8 {
    return repl_input_mod.composeStatusHint(out, runtime_hint, input_hint);
}

fn defaultInputHint(out: *[128]u8, input_text: []const u8, options: Options) []const u8 {
    if (input_text.len == 0) {
        return std.fmt.bufPrint(out, "?: shortcuts, {s} h: palette, Tab Tab: density", .{options.ui_leader_key}) catch "?: shortcuts";
    }
    return "tab: /help";
}

fn sanitizeText(input: []const u8, out: []u8) []const u8 {
    return repl_spinner_mod.sanitizeText(input, out);
}

fn sanitizePromptText(input: []const u8, out: []u8) []const u8 {
    return repl_spinner_mod.sanitizePromptText(input, out);
}

const PromptHistoryState = struct {
    entries: std.array_list.Managed([]u8),
    browse_index: usize = 0,
    draft: ?[]u8 = null,

    fn init(allocator: std.mem.Allocator) PromptHistoryState {
        return .{
            .entries = std.array_list.Managed([]u8).init(allocator),
        };
    }

    fn deinit(self: *PromptHistoryState, allocator: std.mem.Allocator) void {
        self.resetBrowse(allocator);
        for (self.entries.items) |entry| allocator.free(entry);
        self.entries.deinit();
    }

    fn resetBrowse(self: *PromptHistoryState, allocator: std.mem.Allocator) void {
        if (self.draft) |draft| allocator.free(draft);
        self.draft = null;
        self.browse_index = 0;
    }

    fn append(self: *PromptHistoryState, allocator: std.mem.Allocator, prompt: []const u8) !void {
        if (prompt.len == 0) return;
        try self.entries.append(try allocator.dupe(u8, prompt));
    }

    fn recallPrev(
        self: *PromptHistoryState,
        allocator: std.mem.Allocator,
        input_buf: *std_io.StringBuilder,
        cursor: *usize,
        attachments: *repl_attachments_mod.Store,
    ) !bool {
        if (self.entries.items.len == 0) return false;

        if (self.browse_index == 0) {
            self.resetBrowse(allocator);
            self.draft = try allocator.dupe(u8, input_buf.items());
        }

        if (self.browse_index >= self.entries.items.len) return false;
        self.browse_index += 1;

        const prompt = self.entries.items[self.entries.items.len - self.browse_index];
        try replaceInputFromPromptText(allocator, input_buf, cursor, attachments, prompt);
        return true;
    }

    fn recallNext(
        self: *PromptHistoryState,
        allocator: std.mem.Allocator,
        input_buf: *std_io.StringBuilder,
        cursor: *usize,
        attachments: *repl_attachments_mod.Store,
    ) !bool {
        if (self.browse_index == 0) return false;

        if (self.browse_index == 1) {
            const draft = self.draft orelse "";
            try replaceInput(input_buf, draft);
            cursor.* = input_buf.items().len;
            self.resetBrowse(allocator);
            return true;
        }

        self.browse_index -= 1;
        const prompt = self.entries.items[self.entries.items.len - self.browse_index];
        try replaceInputFromPromptText(allocator, input_buf, cursor, attachments, prompt);
        return true;
    }
};

const StashedPrompt = struct {
    text: []u8,
    cursor: usize,

    fn deinit(self: *StashedPrompt, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

const PROMPT_UNDO_LIMIT: usize = 128;

const PromptUndoEntry = struct {
    text: []u8,
    cursor: usize,

    fn deinit(self: *PromptUndoEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

const PromptUndoState = struct {
    entries: std.array_list.Managed(PromptUndoEntry),

    fn init(allocator: std.mem.Allocator) PromptUndoState {
        return .{
            .entries = std.array_list.Managed(PromptUndoEntry).init(allocator),
        };
    }

    fn deinit(self: *PromptUndoState, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit();
    }

    fn snapshot(self: *PromptUndoState, allocator: std.mem.Allocator, text: []const u8, cursor: usize) !void {
        if (self.entries.items.len > 0) {
            const last = self.entries.items[self.entries.items.len - 1];
            if (last.cursor == cursor and std.mem.eql(u8, last.text, text)) return;
        }

        try self.entries.append(.{
            .text = try allocator.dupe(u8, text),
            .cursor = cursor,
        });

        if (self.entries.items.len > PROMPT_UNDO_LIMIT) {
            var dropped = self.entries.orderedRemove(0);
            dropped.deinit(allocator);
        }
    }

    fn restore(self: *PromptUndoState, allocator: std.mem.Allocator, input_buf: *std_io.StringBuilder, cursor: *usize) !bool {
        if (self.entries.items.len == 0) return false;

        var entry = self.entries.pop() orelse return false;
        defer entry.deinit(allocator);

        try replaceInput(input_buf, entry.text);
        cursor.* = @min(entry.cursor, input_buf.items().len);
        return true;
    }
};

const VimState = repl_vim_mod.State;

fn syncVimUiState(options: *Options, vim_state: *const VimState, input_buf: *const std_io.StringBuilder, cursor: *usize) void {
    options.input_mode_label = vim_state.footerLabel();
    if (vim_state.enabled and vim_state.mode == .normal) {
        if (input_buf.items().len == 0) {
            cursor.* = 0;
        } else if (cursor.* >= input_buf.items().len) {
            cursor.* = input_buf.items().len - 1;
        }
        if (input_buf.items().len > 0) {
            if (repl_attachments_mod.tokenAt(input_buf.items(), cursor.*)) |token| {
                cursor.* = token.start;
            }
        }
    }
}

fn extractInsertedText(before: []const u8, before_cursor: usize, after: []const u8, after_cursor: usize) ?[]const u8 {
    if (after.len < before.len) return null;
    if (after_cursor < before_cursor) return null;

    const inserted_len = after.len - before.len;
    if (after_cursor - before_cursor != inserted_len) return null;
    if (before_cursor > before.len or after_cursor > after.len) return null;
    if (!std.mem.eql(u8, before[0..before_cursor], after[0..before_cursor])) return null;

    const before_suffix = before[before_cursor..];
    const after_suffix = after[after_cursor..];
    if (!std.mem.eql(u8, before_suffix, after_suffix)) return null;
    return after[before_cursor..after_cursor];
}

fn shouldExternalizePastedText(inserted: []const u8) bool {
    if (inserted.len >= 1024) return true;
    var newline_count: usize = 0;
    for (inserted) |ch| {
        if (ch == '\n') newline_count += 1;
        if (newline_count >= 8) return true;
    }
    return false;
}

fn runQuickOpenUi(
    allocator: std.mem.Allocator,
    writer: anytype,
    transcript: *UiTranscript,
    input_buf: *std_io.StringBuilder,
    input_cursor: *usize,
    prompt_history: *PromptHistoryState,
    prompt_undo: *PromptUndoState,
    input_hint_buf: *[320]u8,
    input_hint_len: *usize,
    runtime_hint_buf: *[320]u8,
    runtime_hint_len: *usize,
    scroll_offset: *usize,
    raw_mode: *TerminalRawMode,
    fullscreen_active: *bool,
    mode: SessionMode,
    options: Options,
) !void {
    var quick_open = repl_quick_open_mod.buildData(allocator, options.status_workspace, 8000) catch |err| {
        var err_buf: [128]u8 = undefined;
        const hint = std.fmt.bufPrint(&err_buf, "quick open unavailable: {s}", .{@errorName(err)}) catch "quick open unavailable";
        setHint(input_hint_buf, input_hint_len, hint);
        return;
    };
    defer quick_open.deinit();

    if (quick_open.items.len == 0) {
        setHint(input_hint_buf, input_hint_len, "quick open: no files found in this workspace");
        return;
    }

    setHint(runtime_hint_buf, runtime_hint_len, "quick open: enter open, tab mention, shift+tab path");
    const maybe_result = try runQuickOpenOverlayLoopWithBindings(quick_open, options.bottom_margin_rows, options.keybindings);
    setHint(runtime_hint_buf, runtime_hint_len, "idle: waiting for your input");

    const result = maybe_result orelse return;
    const path = quick_open.items[result.item_index].path;

    switch (result.action) {
        .mention_path, .insert_path => {
            try prompt_undo.snapshot(allocator, input_buf.items(), input_cursor.*);
            var insert_buf: [1024]u8 = undefined;
            const inserted = if (result.action == .mention_path)
                std.fmt.bufPrint(&insert_buf, "@{s} ", .{path}) catch return
            else
                std.fmt.bufPrint(&insert_buf, "{s} ", .{path}) catch return;
            try insertInputBytesAt(input_buf, input_cursor, inserted);
            prompt_history.resetBrowse(allocator);
            clearHint(input_hint_len);
        },
        .open_in_editor => {
            raw_mode.disable();
            if (fullscreen_active.*) {
                try leaveAltScreen(writer);
                fullscreen_active.* = false;
            }

            const message = try repl_quick_open_mod.openInEditor(allocator, options.status_workspace, path);
            defer allocator.free(message);

            if (options.enable_alt_screen) {
                enterAltScreen(writer) catch {};
                fullscreen_active.* = true;
            }
            raw_mode.enable();

            try transcript.appendLine(allocator, message);
            try renderFullScreen(writer, transcript, true, input_buf.items(), scroll_offset.*, runtime_hint_buf[0..runtime_hint_len.*], mode, options);
        },
    }
}

fn runGlobalSearchUi(
    allocator: std.mem.Allocator,
    writer: anytype,
    transcript: *UiTranscript,
    input_buf: *std_io.StringBuilder,
    input_cursor: *usize,
    prompt_history: *PromptHistoryState,
    prompt_undo: *PromptUndoState,
    input_hint_buf: *[320]u8,
    input_hint_len: *usize,
    runtime_hint_buf: *[320]u8,
    runtime_hint_len: *usize,
    scroll_offset: *usize,
    raw_mode: *TerminalRawMode,
    fullscreen_active: *bool,
    mode: SessionMode,
    options: Options,
) !void {
    if (options.status_workspace.len == 0) {
        setHint(input_hint_buf, input_hint_len, "global search: no workspace available");
        return;
    }

    setHint(runtime_hint_buf, runtime_hint_len, "global search: enter open, tab mention, shift+tab path:line");
    const maybe_result = try runGlobalSearchOverlayLoopWithBindings(.{
        .allocator = allocator,
        .workspace = options.status_workspace,
    }, options.bottom_margin_rows, options.keybindings);
    setHint(runtime_hint_buf, runtime_hint_len, "idle: waiting for your input");

    var result = maybe_result orelse return;
    defer result.deinit(allocator);

    switch (result.action) {
        .mention_reference, .insert_reference => {
            try prompt_undo.snapshot(allocator, input_buf.items(), input_cursor.*);
            var insert_buf: [1536]u8 = undefined;
            const inserted = if (result.action == .mention_reference)
                std.fmt.bufPrint(&insert_buf, "@{s}#L{d} ", .{ result.path, result.line }) catch return
            else
                std.fmt.bufPrint(&insert_buf, "{s}:{d} ", .{ result.path, result.line }) catch return;
            try insertInputBytesAt(input_buf, input_cursor, inserted);
            prompt_history.resetBrowse(allocator);
            clearHint(input_hint_len);
        },
        .open_in_editor => {
            raw_mode.disable();
            if (fullscreen_active.*) {
                try leaveAltScreen(writer);
                fullscreen_active.* = false;
            }

            const message = try repl_quick_open_mod.openInEditorAtLine(
                allocator,
                options.status_workspace,
                result.path,
                result.line,
            );
            defer allocator.free(message);

            if (options.enable_alt_screen) {
                enterAltScreen(writer) catch {};
                fullscreen_active.* = true;
            }
            raw_mode.enable();

            try transcript.appendLine(allocator, message);
            try renderFullScreen(writer, transcript, true, input_buf.items(), scroll_offset.*, runtime_hint_buf[0..runtime_hint_len.*], mode, options);
        },
    }
}

fn runMessageActionsUi(
    allocator: std.mem.Allocator,
    writer: anytype,
    transcript: *UiTranscript,
    input_buf: *std_io.StringBuilder,
    input_cursor: *usize,
    prompt_undo: *PromptUndoState,
    input_hint_buf: *[320]u8,
    input_hint_len: *usize,
    runtime_hint_buf: *[320]u8,
    runtime_hint_len: *usize,
    scroll_offset: usize,
    mode: SessionMode,
    options: Options,
) !void {
    var data = try buildMessageActionsData(allocator, transcript, options.prompt_label);
    defer data.deinit();

    if (data.items.len == 0) {
        setHint(input_hint_buf, input_hint_len, "message actions: no messages yet");
        return;
    }

    setHint(runtime_hint_buf, runtime_hint_len, "message actions: enter primary, c copy, esc close");
    const maybe_result = try runMessageActionsOverlayLoopWithBindings(data, options.bottom_margin_rows, options.keybindings);
    setHint(runtime_hint_buf, runtime_hint_len, "idle: waiting for your input");

    if (maybe_result) |result| {
        const item = data.items[result.item_index];
        switch (result.action) {
            .copy => {
                const copy_result = try clipboard_mod.copyText(allocator, item.content);
                defer allocator.free(copy_result);
                setHint(input_hint_buf, input_hint_len, copy_result);
            },
            .primary => switch (item.kind) {
                .user => {
                    try prompt_undo.snapshot(allocator, input_buf.items(), input_cursor.*);
                    if (options.attachment_store) |attachments| {
                        try replaceInputFromPromptText(
                            allocator,
                            input_buf,
                            input_cursor,
                            @constCast(attachments),
                            item.content,
                        );
                    } else {
                        try replaceInput(input_buf, item.content);
                        input_cursor.* = input_buf.items().len;
                    }
                    setHint(input_hint_buf, input_hint_len, "recalled prompt from transcript");
                },
                .assistant, .section => {
                    const copy_result = try clipboard_mod.copyText(allocator, item.content);
                    defer allocator.free(copy_result);
                    setHint(input_hint_buf, input_hint_len, copy_result);
                },
            },
        }
    }

    try repl_render_mod.renderFullScreenWithCursor(
        writer,
        transcript,
        true,
        input_buf.items(),
        input_cursor.*,
        scroll_offset,
        runtime_hint_buf[0..runtime_hint_len.*],
        mode,
        options,
    );
}

fn runRewindSelectorUi(
    allocator: std.mem.Allocator,
    writer: anytype,
    transcript: *UiTranscript,
    input_buf: *std_io.StringBuilder,
    input_cursor: *usize,
    attachments: *repl_attachments_mod.Store,
    prompt_history: *PromptHistoryState,
    prompt_undo: *PromptUndoState,
    input_hint_buf: *[320]u8,
    input_hint_len: *usize,
    runtime_hint_buf: *[320]u8,
    runtime_hint_len: *usize,
    scroll_offset: usize,
    mode: SessionMode,
    options: Options,
    handler: Handler,
) !void {
    const cmd_cb = handler.command orelse {
        try transcript.appendLine(allocator, "/rewind picker unavailable in this mode");
        try renderFullScreen(writer, transcript, true, input_buf.items(), scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options);
        return;
    };

    const maybe_payload = cmd_cb(handler.ctx, allocator, "__rewind_picker_data") catch |err| {
        var err_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&err_buf, "error: {s}", .{@errorName(err)}) catch "error";
        try transcript.appendLine(allocator, msg);
        try renderFullScreen(writer, transcript, true, input_buf.items(), scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options);
        return;
    };
    const picker_payload = maybe_payload orelse {
        setHint(input_hint_buf, input_hint_len, "rewind: no prompt history available");
        return;
    };
    defer allocator.free(picker_payload);

    var data = parseMessageSelectorData(allocator, picker_payload) catch |err| {
        var err_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&err_buf, "rewind picker error: {s}", .{@errorName(err)}) catch "rewind picker error";
        try transcript.appendLine(allocator, msg);
        try renderFullScreen(writer, transcript, true, input_buf.items(), scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options);
        return;
    };
    defer data.deinit();

    if (data.items.len == 0) {
        setHint(input_hint_buf, input_hint_len, "rewind: nothing to rewind yet");
        return;
    }

    setHint(runtime_hint_buf, runtime_hint_len, "rewind: select a previous prompt to restore");
    const maybe_selected = try runMessageSelectorOverlayLoopWithBindings(data, options.bottom_margin_rows, options.keybindings);
    setHint(runtime_hint_buf, runtime_hint_len, "idle: waiting for your input");

    const selected_idx = maybe_selected orelse {
        try renderFullScreen(writer, transcript, true, input_buf.items(), scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options);
        return;
    };

    const selected = data.items[selected_idx];

    // Claude Code's /rewind restores the code and/or conversation. Ask
    // whether to also roll the working tree back; conversation-only is
    // the safe default so a rewind never silently reverts files.
    const restore_code = repl_overlay_mod.runRewindCodeRestoreConfirm() catch false;
    const apply_command = if (restore_code)
        try std.fmt.allocPrint(allocator, "__rewind_apply_code {d}", .{selected.history_index})
    else
        try std.fmt.allocPrint(allocator, "__rewind_apply {d}", .{selected.history_index});
    defer allocator.free(apply_command);

    const maybe_output = cmd_cb(handler.ctx, allocator, apply_command) catch |err| {
        var err_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&err_buf, "error: {s}", .{@errorName(err)}) catch "error";
        try transcript.appendLine(allocator, msg);
        try renderFullScreen(writer, transcript, true, input_buf.items(), scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options);
        return;
    };

    try prompt_undo.snapshot(allocator, input_buf.items(), input_cursor.*);
    try replaceInputFromPromptText(allocator, input_buf, input_cursor, attachments, selected.prompt);
    prompt_history.resetBrowse(allocator);
    setHint(input_hint_buf, input_hint_len, "rewind restored the selected prompt into the editor");

    if (maybe_output) |output| {
        defer allocator.free(output);
        try transcript.appendText(allocator, output);
    } else {
        try transcript.appendLine(allocator, "rewound conversation");
    }

    try renderFullScreen(writer, transcript, true, input_buf.items(), scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options);
}

fn runTodoOverlayUi(
    allocator: std.mem.Allocator,
    input_hint_buf: *[320]u8,
    input_hint_len: *usize,
    runtime_hint_buf: *[320]u8,
    runtime_hint_len: *usize,
    handler: Handler,
    options: Options,
) !void {
    const cmd_cb = handler.command orelse {
        setHint(input_hint_buf, input_hint_len, "tasks overlay unavailable");
        return;
    };

    const maybe_output = cmd_cb(handler.ctx, allocator, "__todos_overlay_data") catch |err| {
        var err_buf: [160]u8 = undefined;
        const hint = std.fmt.bufPrint(&err_buf, "tasks overlay unavailable: {s}", .{@errorName(err)}) catch "tasks overlay unavailable";
        setHint(input_hint_buf, input_hint_len, hint);
        return;
    };
    const text = maybe_output orelse try allocator.dupe(u8, "todos: none");
    defer allocator.free(text);

    setHint(runtime_hint_buf, runtime_hint_len, "tasks: esc or ctrl+t to close");
    try runTodoOverlayLoop(.{ .text = text }, options.bottom_margin_rows);
    setHint(runtime_hint_buf, runtime_hint_len, "idle: waiting for your input");
}

fn runTextOverlayUi(
    allocator: std.mem.Allocator,
    input_hint_buf: *[320]u8,
    input_hint_len: *usize,
    runtime_hint_buf: *[320]u8,
    runtime_hint_len: *usize,
    handler: Handler,
    options: Options,
    internal_command: []const u8,
    title: []const u8,
    close_hint: []const u8,
    empty_text: []const u8,
    unavailable_hint: []const u8,
    binding_context: keybindings_mod.BindingContext,
) !void {
    const cmd_cb = handler.command orelse {
        setHint(input_hint_buf, input_hint_len, unavailable_hint);
        return;
    };

    const maybe_output = cmd_cb(handler.ctx, allocator, internal_command) catch |err| {
        var err_buf: [160]u8 = undefined;
        const hint = std.fmt.bufPrint(&err_buf, "{s}: {s}", .{ unavailable_hint, @errorName(err) }) catch unavailable_hint;
        setHint(input_hint_buf, input_hint_len, hint);
        return;
    };
    const text = maybe_output orelse try allocator.dupe(u8, empty_text);
    defer allocator.free(text);

    setHint(runtime_hint_buf, runtime_hint_len, close_hint);
    const contexts = [_]keybindings_mod.BindingContext{ binding_context, .Select };
    try repl_overlay_mod.runTodoOverlayLoopWithBindings(.{
        .title = title,
        .text = text,
        .empty_text = empty_text,
        .close_hint = "Esc close",
    }, options.bottom_margin_rows, options.keybindings, contexts[0..]);
    setHint(runtime_hint_buf, runtime_hint_len, "idle: waiting for your input");
}

fn runTeamsOverlayUi(
    allocator: std.mem.Allocator,
    input_hint_buf: *[320]u8,
    input_hint_len: *usize,
    runtime_hint_buf: *[320]u8,
    runtime_hint_len: *usize,
    handler: Handler,
    options: Options,
) !void {
    return runTextOverlayUi(
        allocator,
        input_hint_buf,
        input_hint_len,
        runtime_hint_buf,
        runtime_hint_len,
        handler,
        options,
        "__teams_overlay_data",
        "Teams",
        "teams: esc or enter to close",
        "teams: none",
        "teams overlay unavailable",
        .TeamsDialog,
    );
}

fn runBridgeOverlayUi(
    allocator: std.mem.Allocator,
    input_hint_buf: *[320]u8,
    input_hint_len: *usize,
    runtime_hint_buf: *[320]u8,
    runtime_hint_len: *usize,
    handler: Handler,
    options: Options,
) !void {
    return runTextOverlayUi(
        allocator,
        input_hint_buf,
        input_hint_len,
        runtime_hint_buf,
        runtime_hint_len,
        handler,
        options,
        "__bridge_overlay_data",
        "Bridge",
        "bridge: esc or enter to close",
        "bridge: unavailable",
        "bridge overlay unavailable",
        .BridgeDialog,
    );
}

fn runThinkingToggleDialogUi(
    allocator: std.mem.Allocator,
    input_hint_buf: *[320]u8,
    input_hint_len: *usize,
    runtime_hint_buf: *[320]u8,
    runtime_hint_len: *usize,
    options: *Options,
) !void {
    const enabled_choice = "Enable thinking summaries";
    const disabled_choice = "Disable thinking summaries";
    const keep_choice = "Keep current setting";
    const choices = if (options.enable_thinking_summary)
        [_][]const u8{ disabled_choice, keep_choice }
    else
        [_][]const u8{ enabled_choice, keep_choice };

    var question_buf: [192]u8 = undefined;
    const question = std.fmt.bufPrint(
        &question_buf,
        "Thinking summaries are currently {s}. Choose a new setting.",
        .{if (options.enable_thinking_summary) "enabled" else "disabled"},
    ) catch "Choose thinking summary setting.";

    setHint(runtime_hint_buf, runtime_hint_len, "thinking: choose an option");
    const contexts = [_]keybindings_mod.BindingContext{ .ThinkingDialog, .Confirmation, .Select };
    const selected = try repl_overlay_mod.runAskUserOverlayLoopWithBindings(
        allocator,
        question,
        choices[0..],
        options.bottom_margin_rows,
        options.keybindings,
        contexts[0..],
    );
    defer allocator.free(selected);

    if (std.mem.eql(u8, selected, keep_choice)) {
        setHint(input_hint_buf, input_hint_len, "thinking summaries unchanged");
        setHint(runtime_hint_buf, runtime_hint_len, "idle: waiting for your input");
        return;
    }

    const next_enabled = std.mem.eql(u8, selected, enabled_choice);
    options.enable_thinking_summary = next_enabled;
    config_parse.persistUserConfigField(allocator, "ui_thinking_summary", if (next_enabled) "true" else "false") catch |err| {
        std.log.warn("failed to persist thinking summary setting: {s}", .{@errorName(err)});
    };
    setHint(
        input_hint_buf,
        input_hint_len,
        if (next_enabled) "thinking summaries enabled" else "thinking summaries disabled",
    );
    setHint(runtime_hint_buf, runtime_hint_len, "idle: waiting for your input");
}

// ── AutoMode opt-in dialog (ui-dialogs-03) ──

/// Reviewed description shown in the AutoMode opt-in dialog. Mirrors the
/// reference's `AUTO_MODE_DESCRIPTION` legally-reviewed copy, rewritten without
/// em/en dashes per the project style rule.
const AUTO_MODE_DESCRIPTION =
    "Auto mode auto-approves tool use until you turn it off, so zcode can edit " ++
    "files and run commands without stopping to ask. Use it only when you trust " ++
    "the requested work. Disable it any time with /yolo.";

/// Security docs link surfaced as a body line in the AutoMode opt-in dialog,
/// matching the reference's docs-link line.
const AUTO_MODE_DOCS_LINE = "Docs: https://code.claude.com/docs/en/security";

/// The branch the user picked in the AutoMode opt-in dialog. `make_default`
/// mirrors the reference `accept-default`, `enable` mirrors `accept`, `disable`
/// turns auto mode off, and `keep` is the no-op / decline branch.
const AutoModeChoice = enum { make_default, enable, disable, keep };

/// Which persisted config writes a given AutoMode dialog choice triggers.
/// Pure (no IO) so the accept-default persistence behavior can be unit-tested
/// without driving the TUI. Mirrors the reference branches:
///   accept-default -> persist skipAutoPermissionPrompt + permissions.defaultMode='auto'
///   accept         -> persist skipAutoPermissionPrompt
///   decline/keep   -> nothing
const AutoModeConfigWrites = struct {
    /// Persist `ui_auto_mode_opt_in_seen = true` (reference skipAutoPermissionPrompt).
    persist_opt_in_seen: bool,
    /// Persist `default_mode = "auto"` (reference permissions.defaultMode='auto').
    persist_default_auto: bool,
    /// Enable auto mode for the current session.
    enable_session: bool,
};

/// Pure mapping from a dialog choice (and whether the user had already opted in)
/// to the set of config writes that should happen. `already_opted_in` suppresses
/// re-persisting the opt-in-seen flag, matching the original guard.
fn autoModeConfigWrites(choice: AutoModeChoice, already_opted_in: bool) AutoModeConfigWrites {
    return switch (choice) {
        .make_default => .{
            .persist_opt_in_seen = !already_opted_in,
            .persist_default_auto = true,
            .enable_session = true,
        },
        .enable => .{
            .persist_opt_in_seen = !already_opted_in,
            .persist_default_auto = false,
            .enable_session = true,
        },
        .disable, .keep => .{
            .persist_opt_in_seen = false,
            .persist_default_auto = false,
            .enable_session = false,
        },
    };
}

fn runAutoModeDialogUi(
    allocator: std.mem.Allocator,
    input_hint_buf: *[320]u8,
    input_hint_len: *usize,
    runtime_hint_buf: *[320]u8,
    runtime_hint_len: *usize,
    options: *Options,
    handler: Handler,
    original_status_approval_mode: []const u8,
) !void {
    const make_default_choice = "Yes, and make it my default mode";
    const enable_choice = "Enable auto mode";
    const disable_choice = "Disable auto mode";
    const keep_choice = "Keep current mode";
    // The accept-default option leads, mirroring the reference option order
    // (accept-default, then accept, then decline). It is only offered when auto
    // mode is currently off (the enable path).
    const enable_choices = [_][]const u8{ make_default_choice, enable_choice, keep_choice };
    const disable_choices = [_][]const u8{ disable_choice, keep_choice };
    const choices: []const []const u8 = if (options.yolo_mode)
        disable_choices[0..]
    else
        enable_choices[0..];

    // The reviewed description plus a docs-link line form the dialog body. The
    // ask-user overlay renders a single question line, so the description is the
    // question and the docs link is appended after it.
    const question = if (options.yolo_mode)
        "Auto mode is currently enabled. Disable it and return to normal approvals?"
    else
        AUTO_MODE_DESCRIPTION ++ " " ++ AUTO_MODE_DOCS_LINE;

    setHint(runtime_hint_buf, runtime_hint_len, "auto mode: choose an option");
    const contexts = [_]keybindings_mod.BindingContext{ .AutoModeDialog, .Confirmation, .Select };
    const selected = try repl_overlay_mod.runAskUserOverlayLoopWithBindings(
        allocator,
        question,
        choices,
        options.bottom_margin_rows,
        options.keybindings,
        contexts[0..],
    );
    defer allocator.free(selected);

    if (std.mem.eql(u8, selected, keep_choice)) {
        setHint(input_hint_buf, input_hint_len, "auto mode unchanged");
        setHint(runtime_hint_buf, runtime_hint_len, "idle: waiting for your input");
        return;
    }

    const choice: AutoModeChoice = if (std.mem.eql(u8, selected, make_default_choice))
        .make_default
    else if (std.mem.eql(u8, selected, enable_choice))
        .enable
    else if (std.mem.eql(u8, selected, disable_choice))
        .disable
    else
        .keep;

    const writes = autoModeConfigWrites(choice, options.auto_mode_opted_in);

    if (writes.persist_opt_in_seen) {
        options.auto_mode_opted_in = true;
        config_parse.persistUserConfigField(allocator, "ui_auto_mode_opt_in_seen", "true") catch |err| {
            std.log.warn("failed to persist auto mode opt-in setting: {s}", .{@errorName(err)});
        };
    }
    if (writes.persist_default_auto) {
        config_parse.persistUserConfigField(allocator, "default_mode", "auto") catch |err| {
            std.log.warn("failed to persist default mode setting: {s}", .{@errorName(err)});
        };
    }

    const enable = writes.enable_session;
    options.yolo_mode = enable;
    options.status_approval_mode = if (enable) "yolo" else original_status_approval_mode;
    if (handler.command) |cmd_cb| {
        _ = cmd_cb(handler.ctx, allocator, if (enable) "__yolo_on" else "__yolo_off") catch null;
    }

    setHint(
        input_hint_buf,
        input_hint_len,
        if (enable) "auto mode enabled: tools will auto-approve" else "auto mode disabled: normal approvals restored",
    );
    setHint(runtime_hint_buf, runtime_hint_len, "idle: waiting for your input");
}

fn runTasksOverlayUi(
    allocator: std.mem.Allocator,
    input_hint_buf: *[320]u8,
    input_hint_len: *usize,
    runtime_hint_buf: *[320]u8,
    runtime_hint_len: *usize,
    handler: Handler,
    options: Options,
) !void {
    const cmd_cb = handler.command orelse {
        setHint(input_hint_buf, input_hint_len, "tasks overlay unavailable");
        return;
    };

    var selected_index: usize = 0;
    while (true) {
        const maybe_payload = cmd_cb(handler.ctx, allocator, "__tasks_overlay_data") catch |err| {
            var err_buf: [160]u8 = undefined;
            const hint = std.fmt.bufPrint(&err_buf, "tasks overlay unavailable: {s}", .{@errorName(err)}) catch "tasks overlay unavailable";
            setHint(input_hint_buf, input_hint_len, hint);
            return;
        };
        const payload = maybe_payload orelse try allocator.dupe(u8, "{\"initial_selection\":0,\"items\":[]}");
        defer allocator.free(payload);

        var data = repl_overlay_mod.parseBackgroundTasksData(allocator, payload) catch |err| {
            var err_buf: [160]u8 = undefined;
            const hint = std.fmt.bufPrint(&err_buf, "tasks overlay parse failed: {s}", .{@errorName(err)}) catch "tasks overlay parse failed";
            setHint(input_hint_buf, input_hint_len, hint);
            return;
        };
        defer data.deinit();

        if (data.items.len > 0) {
            data.initial_selection = @min(selected_index, data.items.len - 1);
        }

        setHint(runtime_hint_buf, runtime_hint_len, "tasks: enter inspect, x stop, r refresh, esc close");
        const maybe_result = try repl_overlay_mod.runBackgroundTasksOverlayLoop(
            data,
            options.bottom_margin_rows,
            options.keybindings,
        );
        setHint(runtime_hint_buf, runtime_hint_len, "idle: waiting for your input");

        const result = maybe_result orelse return;
        if (data.items.len == 0) {
            if (result.action == .refresh) continue;
            return;
        }

        selected_index = @min(result.item_index, data.items.len - 1);
        switch (result.action) {
            .refresh => continue,
            .view => {
                setHint(runtime_hint_buf, runtime_hint_len, "task detail: / search, n/N jump, ctrl+e expand, q close");
                try repl_overlay_mod.runTranscriptOverlayLoop(.{
                    .allocator = allocator,
                    .text = data.items[selected_index].detail,
                }, options.bottom_margin_rows, options.keybindings);
                setHint(runtime_hint_buf, runtime_hint_len, "idle: waiting for your input");
            },
            .stop => {
                const stop_command = try std.fmt.allocPrint(allocator, "__task_stop {s}", .{data.items[selected_index].id});
                defer allocator.free(stop_command);

                const maybe_output = cmd_cb(handler.ctx, allocator, stop_command) catch |err| {
                    var err_buf: [160]u8 = undefined;
                    const hint = std.fmt.bufPrint(&err_buf, "task stop failed: {s}", .{@errorName(err)}) catch "task stop failed";
                    setHint(input_hint_buf, input_hint_len, hint);
                    continue;
                };
                if (maybe_output) |output| allocator.free(output);

                var hint_buf: [160]u8 = undefined;
                const hint = std.fmt.bufPrint(
                    &hint_buf,
                    "stopped task: {s}",
                    .{data.items[selected_index].id},
                ) catch "stopped task";
                setHint(input_hint_buf, input_hint_len, hint);
            },
        }
    }
}

fn runTranscriptOverlayUi(
    allocator: std.mem.Allocator,
    transcript: *const UiTranscript,
    runtime_hint_buf: *[320]u8,
    runtime_hint_len: *usize,
    options: Options,
) !void {
    const text = try buildTranscriptOverlayText(allocator, transcript);
    defer allocator.free(text);

    setHint(runtime_hint_buf, runtime_hint_len, "transcript: / search, n/N jump, ctrl+e expand, v editor, q close");
    try repl_overlay_mod.runTranscriptOverlayLoop(.{
        .allocator = allocator,
        .text = text,
    }, options.bottom_margin_rows, options.keybindings);
    setHint(runtime_hint_buf, runtime_hint_len, "idle: waiting for your input");
}

fn runExternalEditorUi(
    allocator: std.mem.Allocator,
    writer: anytype,
    transcript: *UiTranscript,
    input_buf: *std_io.StringBuilder,
    input_cursor: *usize,
    attachments: *repl_attachments_mod.Store,
    prompt_history: *PromptHistoryState,
    prompt_undo: *PromptUndoState,
    input_hint_buf: *[320]u8,
    input_hint_len: *usize,
    runtime_hint_buf: *[320]u8,
    runtime_hint_len: *usize,
    scroll_offset: *usize,
    raw_mode: *TerminalRawMode,
    fullscreen_active: *bool,
    mode: SessionMode,
    options: Options,
) !void {
    const editor_initial_text = try compilePromptForSubmit(allocator, input_buf.items(), attachments);
    defer allocator.free(editor_initial_text);

    raw_mode.disable();
    if (fullscreen_active.*) {
        try leaveAltScreen(writer);
        fullscreen_active.* = false;
    }

    const edit_result = repl_prompt_editor_mod.editPromptInExternalEditor(allocator, editor_initial_text) catch |err| {
        if (options.enable_alt_screen) {
            enterAltScreen(writer) catch {};
            fullscreen_active.* = true;
        }
        raw_mode.enable();

        var err_buf: [160]u8 = undefined;
        const hint = std.fmt.bufPrint(&err_buf, "external editor failed: {s}", .{@errorName(err)}) catch "external editor failed";
        setHint(input_hint_buf, input_hint_len, hint);
        try renderFullScreen(writer, transcript, true, input_buf.items(), scroll_offset.*, runtime_hint_buf[0..runtime_hint_len.*], mode, options);
        return;
    };
    defer {
        var result = edit_result;
        result.deinit(allocator);
    }

    if (options.enable_alt_screen) {
        enterAltScreen(writer) catch {};
        fullscreen_active.* = true;
    }
    raw_mode.enable();

    const materialized_text = try materializePromptForInput(allocator, edit_result.text, attachments);
    defer allocator.free(materialized_text);

    if (!std.mem.eql(u8, input_buf.items(), materialized_text) or input_cursor.* != input_buf.items().len) {
        try prompt_undo.snapshot(allocator, input_buf.items(), input_cursor.*);
        try replaceInput(input_buf, materialized_text);
        input_cursor.* = input_buf.items().len;
    }
    prompt_history.resetBrowse(allocator);
    clearHint(runtime_hint_len);

    var hint_buf: [160]u8 = undefined;
    const hint = std.fmt.bufPrint(&hint_buf, "edited in {s}", .{edit_result.editor}) catch "edited in external editor";
    setHint(input_hint_buf, input_hint_len, hint);
    try renderFullScreen(writer, transcript, true, input_buf.items(), scroll_offset.*, runtime_hint_buf[0..runtime_hint_len.*], mode, options);
}

/// misc-utils-13: run a bare-`!`-prefix bash command with the sandbox disabled
/// (full host access, mirroring the reference `dangerouslyDisableSandbox: true`),
/// capturing stdout/stderr so they can be folded into the transcript framing.
///
/// Captured (not attached) on purpose: the `!`-prefix fast-path records the
/// output as synthetic conversation context, so we need the bytes, not a
/// terminal stream. Best-effort and time-bounded; a spawn failure yields the
/// error text as stderr so the framing still records what happened.
const BashInputCapture = struct {
    stdout: []u8,
    stderr: []u8,
    fn deinit(self: BashInputCapture, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn runBashInputCommand(allocator: std.mem.Allocator, cwd: []const u8, command: []const u8) !BashInputCapture {
    const shell_path = @import("../core/env.zig").getenv("SHELL") orelse "/bin/sh";
    const shell_name = std.fs.path.basename(shell_path);
    const shell_flag = if (std.mem.eql(u8, shell_name, "bash") or
        std.mem.eql(u8, shell_name, "zsh") or
        std.mem.eql(u8, shell_name, "sh"))
        "-lc"
    else
        "-c";

    const result = std.process.run(allocator, rt.io, .{
        .argv = &.{ shell_path, shell_flag, command },
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch |err| {
        return .{
            .stdout = try allocator.dupe(u8, ""),
            .stderr = try std.fmt.allocPrint(allocator, "[bash-input error: {s}]", .{@errorName(err)}),
        };
    };
    return .{ .stdout = result.stdout, .stderr = result.stderr };
}

fn runInteractiveShellCommandUi(
    allocator: std.mem.Allocator,
    writer: anytype,
    raw_mode: *TerminalRawMode,
    fullscreen_active: *bool,
    handler: Handler,
    options: Options,
    command: []const u8,
) ![]u8 {
    const cwd = blk: {
        if (handler.command) |cmd_cb| {
            if (try cmd_cb(handler.ctx, allocator, "__shell_cwd")) |value| break :blk value;
        }
        break :blk try allocator.dupe(u8, if (options.status_workspace.len > 0) options.status_workspace else ".");
    };
    defer allocator.free(cwd);

    const had_fullscreen = fullscreen_active.*;
    if (had_fullscreen) {
        raw_mode.disable();
        try leaveAltScreen(writer);
        fullscreen_active.* = false;
    }

    const result = repl_interactive_shell_mod.runAttached(allocator, cwd, command) catch |err| {
        if (had_fullscreen and options.enable_alt_screen) {
            enterAltScreen(writer) catch {};
            fullscreen_active.* = true;
            raw_mode.enable();
        }
        return std.fmt.allocPrint(
            allocator,
            "/! {s}\n[interactive_shell_error={s}]",
            .{ command, @errorName(err) },
        );
    };

    if (had_fullscreen and options.enable_alt_screen) {
        enterAltScreen(writer) catch {};
        fullscreen_active.* = true;
        raw_mode.enable();
    }

    return result;
}

fn runModelPickerUi(
    allocator: std.mem.Allocator,
    writer: anytype,
    transcript: *UiTranscript,
    runtime_hint_buf: *[320]u8,
    runtime_hint_len: *usize,
    scroll_offset: usize,
    mode: SessionMode,
    options: Options,
    handler: Handler,
) !void {
    const cmd_cb = handler.command orelse return;

    const maybe_picker_payload = cmd_cb(handler.ctx, allocator, "__model_picker_data") catch |err| {
        var err_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&err_buf, "error: {s}", .{@errorName(err)}) catch "error";
        try transcript.appendLine(allocator, msg);
        try renderFullScreen(writer, transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options);
        return;
    };

    if (maybe_picker_payload) |picker_payload| {
        defer allocator.free(picker_payload);

        var picker = parseModelPickerData(allocator, picker_payload) catch |err| {
            var err_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&err_buf, "error: {s}", .{@errorName(err)}) catch "error";
            try transcript.appendLine(allocator, msg);
            try renderFullScreen(writer, transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options);
            return;
        };
        defer picker.deinit();

        if (picker.items.len == 0) {
            const maybe_output = cmd_cb(handler.ctx, allocator, "/model list") catch |err| {
                var err_buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&err_buf, "error: {s}", .{@errorName(err)}) catch "error";
                try transcript.appendLine(allocator, msg);
                try renderFullScreen(writer, transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options);
                return;
            };
            if (maybe_output) |output| {
                defer allocator.free(output);
                try transcript.appendText(allocator, output);
            } else {
                try transcript.appendLine(allocator, "no models available");
            }
            try renderFullScreen(writer, transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options);
            return;
        }

        setHint(runtime_hint_buf, runtime_hint_len, "model picker: up/down + enter");
        const maybe_selected = try runModelPickerOverlayLoopWithBindings(picker, options.bottom_margin_rows, options.keybindings);
        setHint(runtime_hint_buf, runtime_hint_len, "idle: waiting for your input");

        if (maybe_selected) |selected_idx| {
            const selected = picker.items[selected_idx];
            const set_command = try std.fmt.allocPrint(allocator, "/model {s}", .{selected.id});
            defer allocator.free(set_command);

            const maybe_output = cmd_cb(handler.ctx, allocator, set_command) catch |err| {
                var err_buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&err_buf, "error: {s}", .{@errorName(err)}) catch "error";
                try transcript.appendLine(allocator, msg);
                try renderFullScreen(writer, transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options);
                return;
            };

            if (maybe_output) |output| {
                defer allocator.free(output);
                try transcript.appendText(allocator, output);
            } else {
                try transcript.appendLine(allocator, "model switched");
            }
        } else {
            try transcript.appendLine(allocator, "model switch canceled");
        }

        try renderFullScreen(writer, transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options);
    }
}

fn runFastToggleUi(
    allocator: std.mem.Allocator,
    writer: anytype,
    transcript: *UiTranscript,
    runtime_hint_buf: *[320]u8,
    runtime_hint_len: *usize,
    scroll_offset: usize,
    mode: SessionMode,
    options: Options,
    handler: Handler,
) !void {
    const cmd_cb = handler.command orelse return;
    const maybe_output = cmd_cb(handler.ctx, allocator, "/fast") catch |err| {
        var err_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&err_buf, "error: {s}", .{@errorName(err)}) catch "error";
        try transcript.appendLine(allocator, msg);
        try renderFullScreen(writer, transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options);
        return;
    };

    if (maybe_output) |output| {
        defer allocator.free(output);
        try transcript.appendText(allocator, output);
    } else {
        try transcript.appendLine(allocator, "fast mode updated");
    }

    try renderFullScreen(writer, transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options);
}

fn runBriefToggleUi(
    allocator: std.mem.Allocator,
    writer: anytype,
    transcript: *UiTranscript,
    runtime_hint_buf: *[320]u8,
    runtime_hint_len: *usize,
    scroll_offset: usize,
    mode: SessionMode,
    options: *Options,
    handler: Handler,
) !void {
    const cmd_cb = handler.command orelse {
        options.brief_mode = !options.brief_mode;
        setHint(runtime_hint_buf, runtime_hint_len, if (options.brief_mode) "brief mode on" else "brief mode off");
        try renderFullScreen(writer, transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options.*);
        return;
    };

    const command = if (options.brief_mode) "/brief off" else "/brief on";
    const maybe_output = cmd_cb(handler.ctx, allocator, command) catch |err| {
        var err_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&err_buf, "error: {s}", .{@errorName(err)}) catch "error";
        try transcript.appendLine(allocator, msg);
        try renderFullScreen(writer, transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options.*);
        return;
    };

    applyBriefCommandSideEffects(options, command);
    setHint(runtime_hint_buf, runtime_hint_len, if (options.brief_mode) "brief mode on" else "brief mode off");

    if (maybe_output) |output| {
        defer allocator.free(output);
        try transcript.appendText(allocator, output);
    } else {
        try transcript.appendLine(allocator, if (options.brief_mode) "brief mode on" else "brief mode off");
    }

    try renderFullScreen(writer, transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options.*);
}

fn runThemePickerUi(
    allocator: std.mem.Allocator,
    writer: anytype,
    transcript: *UiTranscript,
    runtime_hint_buf: *[320]u8,
    runtime_hint_len: *usize,
    scroll_offset: usize,
    mode: SessionMode,
    options: *Options,
    handler: Handler,
) !void {
    const cmd_cb = handler.command orelse return;
    const before_setting = options.theme_setting;
    const before_syntax = options.highlight_code_blocks;

    setHint(runtime_hint_buf, runtime_hint_len, "theme picker: up/down + enter, ctrl+t syntax");
    const maybe_result = try runThemePickerOverlayLoopWithBindings(.{
        .current_setting = before_setting,
        .syntax_highlighting = before_syntax,
    }, options.bottom_margin_rows, options.keybindings);
    setHint(runtime_hint_buf, runtime_hint_len, "idle: waiting for your input");

    if (maybe_result) |result| {
        if (result.setting != before_setting) {
            const set_command = try std.fmt.allocPrint(allocator, "/theme {s}", .{ui_theme.formatThemeSetting(result.setting)});
            defer allocator.free(set_command);
            const maybe_output = cmd_cb(handler.ctx, allocator, set_command) catch |err| {
                var err_buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&err_buf, "error: {s}", .{@errorName(err)}) catch "error";
                try transcript.appendLine(allocator, msg);
                try renderFullScreen(writer, transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options.*);
                return;
            };
            applyThemeSelection(options, result.setting);
            if (maybe_output) |output| {
                defer allocator.free(output);
                try transcript.appendText(allocator, output);
            }
        }

        if (result.syntax_highlighting != before_syntax) {
            const syntax_command = if (result.syntax_highlighting) "/theme syntax on" else "/theme syntax off";
            const maybe_output = cmd_cb(handler.ctx, allocator, syntax_command) catch |err| {
                var err_buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&err_buf, "error: {s}", .{@errorName(err)}) catch "error";
                try transcript.appendLine(allocator, msg);
                try renderFullScreen(writer, transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options.*);
                return;
            };
            options.highlight_code_blocks = result.syntax_highlighting;
            if (maybe_output) |output| {
                defer allocator.free(output);
                try transcript.appendText(allocator, output);
            }
        }

        if (result.setting == before_setting and result.syntax_highlighting == before_syntax) {
            try transcript.appendLine(allocator, "theme unchanged");
        }
    } else {
        try transcript.appendLine(allocator, "theme change canceled");
    }

    try renderFullScreen(writer, transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options.*);
}

fn runStylePickerUi(
    allocator: std.mem.Allocator,
    writer: anytype,
    transcript: *UiTranscript,
    runtime_hint_buf: *[320]u8,
    runtime_hint_len: *usize,
    scroll_offset: usize,
    mode: SessionMode,
    options: Options,
    handler: Handler,
) !void {
    const cmd_cb = handler.command orelse return;
    const maybe_current_style = cmd_cb(handler.ctx, allocator, "__style_current_name") catch |err| {
        var err_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&err_buf, "style picker unavailable: {s}", .{@errorName(err)}) catch "style picker unavailable";
        try transcript.appendLine(allocator, msg);
        try renderFullScreen(writer, transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options);
        return;
    };
    const current_style = maybe_current_style orelse try allocator.dupe(u8, "default");
    defer allocator.free(current_style);

    var picker = StylePickerData{
        .allocator = allocator,
        .current_style = current_style,
        .items = output_styles_mod.list(allocator, options.status_workspace) catch |err| {
            var err_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&err_buf, "style picker unavailable: {s}", .{@errorName(err)}) catch "style picker unavailable";
            try transcript.appendLine(allocator, msg);
            try renderFullScreen(writer, transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options);
            return;
        },
    };
    defer picker.deinit();

    if (picker.items.len == 0) {
        try transcript.appendLine(allocator, "no output styles available");
        try renderFullScreen(writer, transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options);
        return;
    }

    setHint(runtime_hint_buf, runtime_hint_len, "styles: type to filter, enter to select");
    const maybe_selected = try runStylePickerOverlayLoopWithBindings(picker, options.bottom_margin_rows, options.keybindings);
    setHint(runtime_hint_buf, runtime_hint_len, "idle: waiting for your input");

    if (maybe_selected) |selected_idx| {
        const selected_name = picker.items[selected_idx].name;
        if (std.ascii.eqlIgnoreCase(selected_name, current_style)) {
            try transcript.appendLine(allocator, "output style unchanged");
            try renderFullScreen(writer, transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options);
            return;
        }

        const set_command = try std.fmt.allocPrint(allocator, "/style {s}", .{selected_name});
        defer allocator.free(set_command);
        const maybe_output = cmd_cb(handler.ctx, allocator, set_command) catch |err| {
            var err_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&err_buf, "error: {s}", .{@errorName(err)}) catch "error";
            try transcript.appendLine(allocator, msg);
            try renderFullScreen(writer, transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options);
            return;
        };

        if (maybe_output) |output| {
            defer allocator.free(output);
            try transcript.appendText(allocator, output);
        } else {
            try transcript.appendLine(allocator, "output style updated");
        }
        try renderFullScreen(writer, transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options);
    }
}

/// ui-dialogs-07 (PARTIAL): drive the local feedback survey overlay, persist
/// the rating to the local JSONL store, and echo a thanks line into the
/// transcript. Cancelling the rating step records nothing.
fn runFeedbackSurveyUi(
    allocator: std.mem.Allocator,
    writer: anytype,
    transcript: *UiTranscript,
    runtime_hint_buf: *[320]u8,
    runtime_hint_len: *usize,
    scroll_offset: usize,
    mode: SessionMode,
    options: Options,
) !void {
    setHint(runtime_hint_buf, runtime_hint_len, "feedback: pick 1-5, Enter to confirm, Esc to cancel");
    const maybe_result = try repl_overlay_mod.runFeedbackSurveyOverlayLoop(options.bottom_margin_rows);
    setHint(runtime_hint_buf, runtime_hint_len, "idle: waiting for your input");

    if (maybe_result) |result| {
        const path = feedback_survey_mod.defaultFeedbackPath(allocator) catch |err| {
            var err_buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&err_buf, "feedback not saved: {s}", .{@errorName(err)}) catch "feedback not saved";
            try transcript.appendLine(allocator, msg);
            try renderFullScreen(writer, transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options);
            return;
        };
        defer allocator.free(path);

        feedback_survey_mod.appendRating(allocator, path, result.rating, result.note(), build_options.app_version) catch |err| {
            var err_buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&err_buf, "feedback not saved: {s}", .{@errorName(err)}) catch "feedback not saved";
            try transcript.appendLine(allocator, msg);
            try renderFullScreen(writer, transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options);
            return;
        };

        var thanks_buf: [256]u8 = undefined;
        const thanks = std.fmt.bufPrint(&thanks_buf, "Thanks! Recorded a rating of {d}/5. (For bug reports, use /issue or GitHub Issues.)", .{result.rating}) catch "Thanks for the feedback!";
        try transcript.appendLine(allocator, thanks);
    } else {
        try transcript.appendLine(allocator, "feedback survey cancelled");
    }
    try renderFullScreen(writer, transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options);
}

fn buildCommandPaletteData(allocator: std.mem.Allocator, options: Options) !CommandPaletteData {
    var items = std.array_list.Managed(CommandPaletteItem).init(allocator);
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit();
    }

    var model_state_buf: [160]u8 = undefined;
    const model_state = std.fmt.bufPrint(&model_state_buf, "{s}/{s}", .{ options.status_provider, options.status_model }) catch options.status_model;

    const theme_state = @tagName(options.theme);
    const density_state = formatUiDensity(options.ui_density);
    const transcript_state = if (options.show_transcript) "visible" else "hidden";
    const brief_state = boolState(options.brief_mode);
    const thinking_state = boolState(options.enable_thinking_summary);
    const auto_state = boolState(options.yolo_mode);
    const agent_state = dynamicAgentName(options);
    try appendLeaderCommandPaletteItem(&items, allocator, options.ui_leader_key, "h", "help", "Help", "Open the task-first help overview in the transcript", "Session", "");
    try appendLeaderCommandPaletteItem(&items, allocator, options.ui_leader_key, "s", "session_switcher", "Session switcher", "Browse saved sessions and resume one without typing /resume", "Session", "");
    try appendCommandPaletteItem(&items, allocator, "onboarding", "Onboarding", "Show setup status and next-step guidance", "/onboarding", "Session", "");
    try appendCommandPaletteItem(&items, allocator, "doctor", "Doctor", "Run diagnostics for the current zcode environment", "/doctor", "Session", "");
    try appendCommandPaletteItem(&items, allocator, "status", "Status report", "Append the full runtime status to the transcript", "/status", "Session", "");
    try appendCommandPaletteItem(&items, allocator, "transcript_view", "Transcript viewer", "Search, export, and inspect the transcript", "Ctrl+E", "Transcript", "");
    try appendCommandPaletteItem(&items, allocator, "transcript_toggle", "Transcript visibility", "Hide or restore the live transcript viewport", "Ctrl+O", "Transcript", transcript_state);
    try appendCommandPaletteItem(&items, allocator, "brief", "Brief mode", "Collapse assistant chrome for denser transcript viewing", "Ctrl+Shift+B", "Display", brief_state);
    try appendLeaderCommandPaletteItem(&items, allocator, options.ui_leader_key, "b", "density", "UI density", "Toggle between full and clean fullscreen layouts", "Display", density_state);
    try appendLeaderCommandPaletteItem(&items, allocator, options.ui_leader_key, "p", "theme", "Theme picker", "Change theme and syntax-highlighting preferences", "Display", theme_state);
    try appendLeaderCommandPaletteItem(&items, allocator, options.ui_leader_key, "m", "model", "Model picker", "Switch provider/model without leaving the composer", "Models", model_state);
    try appendLeaderCommandPaletteItem(&items, allocator, options.ui_leader_key, "f", "quick_open", "Quick open", "Jump to a file or insert its path into the prompt", "Navigate", "");
    try appendLeaderCommandPaletteItem(&items, allocator, options.ui_leader_key, "g", "global_search", "Workspace search", "Find code with line preview and mention references", "Navigate", "");
    try appendLeaderCommandPaletteItem(&items, allocator, options.ui_leader_key, "t", "tasks", "Tasks", "Open the live task manager / background work overlay", "Runtime", if (options.footer_tasks_state.len > 0) options.footer_tasks_state else "");
    try appendCommandPaletteItem(&items, allocator, "teams", "Teams", "Inspect local team metadata and message activity", "/teams", "Runtime", "");
    try appendCommandPaletteItem(&items, allocator, "bridge", "Bridge", "Inspect MCP/browser bridge status", "/bridge", "Runtime", "");
    try appendCommandPaletteItem(&items, allocator, "thinking", "Thinking summaries", "Enable or disable reasoning-summary output", "Alt+T", "Runtime", thinking_state);
    try appendCommandPaletteItem(&items, allocator, "auto", "Auto mode", "Toggle automatic tool approvals for this session", "/yolo", "Runtime", auto_state);
    try appendLeaderCommandPaletteItem(&items, allocator, options.ui_leader_key, "a", "runtime_panel", "Runtime panel", "Open the runtime control panel with automation, tasks, and model state", "Runtime", if (agent_state.len > 0) agent_state else options.status_approval_mode);

    return .{
        .allocator = allocator,
        .title = "Command Palette",
        .items = try items.toOwnedSlice(),
    };
}

fn buildRuntimePanelData(allocator: std.mem.Allocator, options: Options) !RuntimePanelData {
    var items = std.array_list.Managed(CommandPaletteItem).init(allocator);
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit();
    }

    var model_state_buf: [160]u8 = undefined;
    const model_state = std.fmt.bufPrint(&model_state_buf, "{s}/{s}", .{ options.status_provider, options.status_model }) catch options.status_model;
    const thinking_state = boolState(options.enable_thinking_summary);
    const auto_state = boolState(options.yolo_mode);
    const agent_state = dynamicAgentName(options);
    const circuit_state = dynamicCircuitState(options);

    var status_state_buf: [160]u8 = undefined;
    const status_state = std.fmt.bufPrint(
        &status_state_buf,
        "{s} / {s}{s}{s}",
        .{
            options.status_approval_mode,
            options.status_sandbox,
            if (agent_state.len > 0) "  •  @" else "",
            agent_state,
        },
    ) catch options.status_approval_mode;

    try appendCommandPaletteItem(&items, allocator, "status", "Status report", "Append the full runtime status to the transcript", "/status", "Runtime", status_state);
    try appendLeaderCommandPaletteItem(&items, allocator, options.ui_leader_key, "s", "session_switcher", "Session switcher", "Resume another saved session from the current workspace state", "Runtime", "");
    try appendLeaderCommandPaletteItem(&items, allocator, options.ui_leader_key, "m", "model", "Model picker", "Switch provider/model without leaving the composer", "Models", model_state);
    try appendLeaderCommandPaletteItem(&items, allocator, options.ui_leader_key, "t", "tasks", "Tasks", "Open the live task manager / background work overlay", "Automation", if (options.footer_tasks_state.len > 0) options.footer_tasks_state else "");
    try appendCommandPaletteItem(&items, allocator, "teams", "Teams", "Inspect local team metadata and message activity", "/teams", "Automation", "");
    try appendCommandPaletteItem(&items, allocator, "bridge", "Bridge", "Inspect MCP/browser bridge status", "/bridge", "Automation", "");
    try appendCommandPaletteItem(&items, allocator, "thinking", "Thinking summaries", "Enable or disable reasoning-summary output", "Alt+T", "Automation", thinking_state);
    try appendCommandPaletteItem(&items, allocator, "auto", "Auto mode", "Toggle automatic tool approvals for this session", "/yolo", "Automation", auto_state);
    if (circuit_state.len > 0 and !std.mem.eql(u8, circuit_state, "closed")) {
        try appendCommandPaletteItem(&items, allocator, "status", "Circuit breaker", "Current provider circuit-breaker state", "", "Automation", circuit_state);
    }

    return .{
        .allocator = allocator,
        .title = "Runtime Control Panel",
        .items = try items.toOwnedSlice(),
    };
}

fn runDensityToggleUi(
    allocator: std.mem.Allocator,
    writer: anytype,
    transcript: *UiTranscript,
    runtime_hint_buf: *[320]u8,
    runtime_hint_len: *usize,
    scroll_offset: usize,
    mode: SessionMode,
    options: *Options,
    handler: Handler,
) !void {
    const next_density: UiDensity = if (options.ui_density == .full) .clean else .full;
    options.ui_density = next_density;
    options.shortcuts_panel_visible = false;

    if (handler.command) |cmd_cb| {
        const command = try std.fmt.allocPrint(allocator, "/config set ui_density {s}", .{formatUiDensity(next_density)});
        defer allocator.free(command);
        const maybe_output = cmd_cb(handler.ctx, allocator, command) catch |err| {
            std.log.warn("failed to persist ui_density: {s}", .{@errorName(err)});
            try transcript.appendLine(allocator, if (next_density == .clean) "UI density switched to clean" else "UI density switched to full");
            try renderFullScreen(writer, transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options.*);
            return;
        };
        if (maybe_output) |output| {
            defer allocator.free(output);
            try transcript.appendText(allocator, output);
        } else {
            try transcript.appendLine(allocator, if (next_density == .clean) "UI density switched to clean" else "UI density switched to full");
        }
    } else {
        try transcript.appendLine(allocator, if (next_density == .clean) "UI density switched to clean" else "UI density switched to full");
    }

    try renderFullScreen(writer, transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len.*], mode, options.*);
}

fn runCommandPaletteUi(
    allocator: std.mem.Allocator,
    writer: anytype,
    transcript: *UiTranscript,
    input_buf: *std_io.StringBuilder,
    input_cursor: *usize,
    prompt_history: *PromptHistoryState,
    prompt_undo: *PromptUndoState,
    input_hint_buf: *[320]u8,
    input_hint_len: *usize,
    runtime_hint_buf: *[320]u8,
    runtime_hint_len: *usize,
    scroll_offset: *usize,
    raw_mode: *TerminalRawMode,
    fullscreen_active: *bool,
    mode: SessionMode,
    options: *Options,
    handler: Handler,
    original_status_approval_mode: []const u8,
) !void {
    var palette = try buildCommandPaletteData(allocator, options.*);
    defer palette.deinit();

    if (palette.items.len == 0) {
        setHint(input_hint_buf, input_hint_len, "command palette: no actions available");
        return;
    }

    setHint(runtime_hint_buf, runtime_hint_len, "command palette: type to filter, enter open");
    const maybe_selected = try runCommandPaletteOverlayLoopWithBindings(palette, options.bottom_margin_rows, options.keybindings);
    setHint(runtime_hint_buf, runtime_hint_len, "idle: waiting for your input");

    const selected_idx = maybe_selected orelse return;
    const selected = palette.items[selected_idx].id;

    if (std.mem.eql(u8, selected, "help")) {
        try runSlashCommandUi(allocator, writer, transcript, runtime_hint_buf, runtime_hint_len, scroll_offset.*, mode, options.*, handler, "/help", "help unavailable");
        return;
    }
    if (std.mem.eql(u8, selected, "onboarding")) {
        try runSlashCommandUi(allocator, writer, transcript, runtime_hint_buf, runtime_hint_len, scroll_offset.*, mode, options.*, handler, "/onboarding", "onboarding unavailable");
        return;
    }
    if (std.mem.eql(u8, selected, "doctor")) {
        try runSlashCommandUi(allocator, writer, transcript, runtime_hint_buf, runtime_hint_len, scroll_offset.*, mode, options.*, handler, "/doctor", "doctor unavailable");
        return;
    }
    if (std.mem.eql(u8, selected, "status")) {
        try runSlashCommandUi(allocator, writer, transcript, runtime_hint_buf, runtime_hint_len, scroll_offset.*, mode, options.*, handler, "/status", "status unavailable");
        return;
    }
    if (std.mem.eql(u8, selected, "session_switcher")) {
        try runSessionSwitcherUi(allocator, writer, transcript, runtime_hint_buf, runtime_hint_len, scroll_offset.*, mode, options.*, handler);
        return;
    }
    if (std.mem.eql(u8, selected, "model")) {
        try runModelPickerUi(allocator, writer, transcript, runtime_hint_buf, runtime_hint_len, scroll_offset.*, mode, options.*, handler);
        return;
    }
    if (std.mem.eql(u8, selected, "theme")) {
        try runThemePickerUi(allocator, writer, transcript, runtime_hint_buf, runtime_hint_len, scroll_offset.*, mode, options, handler);
        return;
    }
    if (std.mem.eql(u8, selected, "density")) {
        try runDensityToggleUi(allocator, writer, transcript, runtime_hint_buf, runtime_hint_len, scroll_offset.*, mode, options, handler);
        return;
    }
    if (std.mem.eql(u8, selected, "brief")) {
        try runBriefToggleUi(allocator, writer, transcript, runtime_hint_buf, runtime_hint_len, scroll_offset.*, mode, options, handler);
        return;
    }
    if (std.mem.eql(u8, selected, "transcript_toggle")) {
        options.show_transcript = !options.show_transcript;
        setHint(runtime_hint_buf, runtime_hint_len, if (options.show_transcript) "transcript restored" else "transcript hidden");
        try renderFullScreen(writer, transcript, true, input_buf.items(), scroll_offset.*, runtime_hint_buf[0..runtime_hint_len.*], mode, options.*);
        return;
    }
    if (std.mem.eql(u8, selected, "transcript_view")) {
        try runTranscriptOverlayUi(allocator, transcript, runtime_hint_buf, runtime_hint_len, options.*);
        try renderFullScreen(writer, transcript, true, input_buf.items(), scroll_offset.*, runtime_hint_buf[0..runtime_hint_len.*], mode, options.*);
        return;
    }
    if (std.mem.eql(u8, selected, "quick_open")) {
        try runQuickOpenUi(allocator, writer, transcript, input_buf, input_cursor, prompt_history, prompt_undo, input_hint_buf, input_hint_len, runtime_hint_buf, runtime_hint_len, scroll_offset, raw_mode, fullscreen_active, mode, options.*);
        return;
    }
    if (std.mem.eql(u8, selected, "global_search")) {
        try runGlobalSearchUi(allocator, writer, transcript, input_buf, input_cursor, prompt_history, prompt_undo, input_hint_buf, input_hint_len, runtime_hint_buf, runtime_hint_len, scroll_offset, raw_mode, fullscreen_active, mode, options.*);
        return;
    }
    if (std.mem.eql(u8, selected, "tasks")) {
        try runTasksOverlayUi(allocator, input_hint_buf, input_hint_len, runtime_hint_buf, runtime_hint_len, handler, options.*);
        return;
    }
    if (std.mem.eql(u8, selected, "teams")) {
        try runTeamsOverlayUi(allocator, input_hint_buf, input_hint_len, runtime_hint_buf, runtime_hint_len, handler, options.*);
        return;
    }
    if (std.mem.eql(u8, selected, "bridge")) {
        try runBridgeOverlayUi(allocator, input_hint_buf, input_hint_len, runtime_hint_buf, runtime_hint_len, handler, options.*);
        return;
    }
    if (std.mem.eql(u8, selected, "thinking")) {
        try runThinkingToggleDialogUi(allocator, input_hint_buf, input_hint_len, runtime_hint_buf, runtime_hint_len, options);
        return;
    }
    if (std.mem.eql(u8, selected, "auto")) {
        try runAutoModeDialogUi(allocator, input_hint_buf, input_hint_len, runtime_hint_buf, runtime_hint_len, options, handler, original_status_approval_mode);
        return;
    }
    if (std.mem.eql(u8, selected, "runtime_panel")) {
        try runRuntimePanelUi(
            allocator,
            writer,
            transcript,
            input_buf,
            input_cursor,
            prompt_history,
            prompt_undo,
            input_hint_buf,
            input_hint_len,
            runtime_hint_buf,
            runtime_hint_len,
            scroll_offset,
            raw_mode,
            fullscreen_active,
            mode,
            options,
            handler,
            original_status_approval_mode,
        );
        return;
    }
}

fn runRuntimePanelUi(
    allocator: std.mem.Allocator,
    writer: anytype,
    transcript: *UiTranscript,
    input_buf: *std_io.StringBuilder,
    input_cursor: *usize,
    prompt_history: *PromptHistoryState,
    prompt_undo: *PromptUndoState,
    input_hint_buf: *[320]u8,
    input_hint_len: *usize,
    runtime_hint_buf: *[320]u8,
    runtime_hint_len: *usize,
    scroll_offset: *usize,
    raw_mode: *TerminalRawMode,
    fullscreen_active: *bool,
    mode: SessionMode,
    options: *Options,
    handler: Handler,
    original_status_approval_mode: []const u8,
) !void {
    var panel = try buildRuntimePanelData(allocator, options.*);
    defer panel.deinit();

    if (panel.items.len == 0) {
        setHint(input_hint_buf, input_hint_len, "runtime panel: no actions available");
        return;
    }

    setHint(runtime_hint_buf, runtime_hint_len, "runtime panel: type to filter, enter open");
    const maybe_selected = try runRuntimePanelOverlayLoopWithBindings(panel, options.bottom_margin_rows, options.keybindings);
    setHint(runtime_hint_buf, runtime_hint_len, "idle: waiting for your input");

    const selected_idx = maybe_selected orelse return;
    const selected = panel.items[selected_idx].id;

    if (std.mem.eql(u8, selected, "status")) {
        try runSlashCommandUi(allocator, writer, transcript, runtime_hint_buf, runtime_hint_len, scroll_offset.*, mode, options.*, handler, "/status", "status unavailable");
        return;
    }
    if (std.mem.eql(u8, selected, "session_switcher")) {
        try runSessionSwitcherUi(allocator, writer, transcript, runtime_hint_buf, runtime_hint_len, scroll_offset.*, mode, options.*, handler);
        return;
    }
    if (std.mem.eql(u8, selected, "model")) {
        try runModelPickerUi(allocator, writer, transcript, runtime_hint_buf, runtime_hint_len, scroll_offset.*, mode, options.*, handler);
        return;
    }
    if (std.mem.eql(u8, selected, "tasks")) {
        try runTasksOverlayUi(allocator, input_hint_buf, input_hint_len, runtime_hint_buf, runtime_hint_len, handler, options.*);
        return;
    }
    if (std.mem.eql(u8, selected, "teams")) {
        try runTeamsOverlayUi(allocator, input_hint_buf, input_hint_len, runtime_hint_buf, runtime_hint_len, handler, options.*);
        return;
    }
    if (std.mem.eql(u8, selected, "bridge")) {
        try runBridgeOverlayUi(allocator, input_hint_buf, input_hint_len, runtime_hint_buf, runtime_hint_len, handler, options.*);
        return;
    }
    if (std.mem.eql(u8, selected, "thinking")) {
        try runThinkingToggleDialogUi(allocator, input_hint_buf, input_hint_len, runtime_hint_buf, runtime_hint_len, options);
        return;
    }
    if (std.mem.eql(u8, selected, "auto")) {
        try runAutoModeDialogUi(allocator, input_hint_buf, input_hint_len, runtime_hint_buf, runtime_hint_len, options, handler, original_status_approval_mode);
        return;
    }
    if (std.mem.eql(u8, selected, "quick_open")) {
        try runQuickOpenUi(allocator, writer, transcript, input_buf, input_cursor, prompt_history, prompt_undo, input_hint_buf, input_hint_len, runtime_hint_buf, runtime_hint_len, scroll_offset, raw_mode, fullscreen_active, mode, options.*);
        return;
    }
}

/// Pure dispatch-decision for the bare session-switcher entrypoints. Bare
/// `/resume`, its reference alias `/continue`, and `/sessions` open the
/// interactive picker; any of those forms WITH an argument (e.g. `/resume <id>`)
/// flows to the command handler instead so the existing UUID/fuzzy-resolution
/// path runs. Kept pure (no IO/alloc) so the dispatch decision is testable
/// without a TTY. commands-sweep-04.
fn shouldOpenSessionSwitcher(line: []const u8) bool {
    return std.mem.eql(u8, line, "/resume") or
        std.mem.eql(u8, line, "/continue") or
        std.mem.eql(u8, line, "/sessions");
}

fn runSessionSwitcherUi(
    allocator: std.mem.Allocator,
    writer: anytype,
    transcript: *UiTranscript,
    runtime_hint_buf: *[320]u8,
    runtime_hint_len: *usize,
    scroll_offset: usize,
    mode: SessionMode,
    options: Options,
    handler: Handler,
) !void {
    const cmd_cb = handler.command orelse {
        setHint(runtime_hint_buf, runtime_hint_len, "session switcher unavailable");
        return;
    };

    const maybe_payload = cmd_cb(handler.ctx, allocator, "__sessions_overlay_data") catch |err| {
        var err_buf: [160]u8 = undefined;
        const msg = std.fmt.bufPrint(&err_buf, "session switcher unavailable: {s}", .{@errorName(err)}) catch "session switcher unavailable";
        setHint(runtime_hint_buf, runtime_hint_len, msg);
        return;
    };
    const payload = maybe_payload orelse {
        setHint(runtime_hint_buf, runtime_hint_len, "no saved sessions");
        return;
    };
    defer allocator.free(payload);

    var data = parseSessionSwitcherData(allocator, payload) catch |err| {
        var err_buf: [160]u8 = undefined;
        const msg = std.fmt.bufPrint(&err_buf, "session switcher parse failed: {s}", .{@errorName(err)}) catch "session switcher parse failed";
        setHint(runtime_hint_buf, runtime_hint_len, msg);
        return;
    };
    defer data.deinit();

    if (data.items.len == 0) {
        setHint(runtime_hint_buf, runtime_hint_len, "no saved sessions");
        return;
    }

    setHint(runtime_hint_buf, runtime_hint_len, "session switcher: type to filter, enter resume");
    const maybe_selected = try runSessionSwitcherOverlayLoopWithBindings(data, options.bottom_margin_rows, options.keybindings);
    setHint(runtime_hint_buf, runtime_hint_len, "idle: waiting for your input");

    const selected_idx = maybe_selected orelse return;
    const session_id = data.items[selected_idx].id;
    const resume_command = try std.fmt.allocPrint(allocator, "/resume {s}", .{session_id});
    defer allocator.free(resume_command);
    try runSlashCommandUi(allocator, writer, transcript, runtime_hint_buf, runtime_hint_len, scroll_offset, mode, options, handler, resume_command, "session resume unavailable");
}

// Session/plan/brainstorm helpers delegated to repl_session_mod
const repl_session_mod = @import("repl_session.zig");

fn shouldPromoteBrainstormToPlanning(line: []const u8) bool {
    return repl_session_mod.shouldPromoteBrainstormToPlanning(line);
}

fn shouldAutoPromoteBrainstormOutputToPlanning(output: []const u8) bool {
    return repl_session_mod.shouldAutoPromoteBrainstormOutputToPlanning(output);
}

fn buildBrainstormPromotionPrompt(allocator: std.mem.Allocator, user_confirmation: []const u8) ![]u8 {
    return repl_session_mod.buildBrainstormPromotionPrompt(allocator, user_confirmation);
}

/// True when `text` is one of the agent loop's synthesized stall /
/// error responses (not anything the model wrote). The plan-mode
/// post-turn handler uses this to refuse to wrap a stall message into
/// a plan file and open the approval overlay on it.
fn isAgentStallMessage(text: []const u8) bool {
    const prefixes = [_][]const u8{
        "The model got stuck repeating the same response",
        "Repeated the same tool call twice in a row",
        "The model could not execute the requested work",
        "Execution paused: model kept returning intent text",
        "Stopped after reaching max tool rounds",
        "Model returned an empty response",
        "Model produced internal reasoning but no visible answer",
    };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, text, p)) return true;
    }
    return false;
}

fn normalizePlanMarkdown(allocator: std.mem.Allocator, model_output: []const u8) ![]u8 {
    return repl_session_mod.normalizePlanMarkdown(allocator, model_output);
}

fn savePlanFile(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return repl_session_mod.savePlanFile(allocator, text);
}

fn setOwnedOptional(allocator: std.mem.Allocator, slot: *?[]u8, value: []const u8) !void {
    return repl_session_mod.setOwnedOptional(allocator, slot, value);
}

fn clearOwnedOptional(allocator: std.mem.Allocator, slot: *?[]u8) void {
    repl_session_mod.clearOwnedOptional(allocator, slot);
}

fn buildApprovedPlanExecutionPrompt(allocator: std.mem.Allocator, plan_path: []const u8) ![]u8 {
    return repl_session_mod.buildApprovedPlanExecutionPrompt(allocator, plan_path);
}

fn formatTaskNotificationAlloc(allocator: std.mem.Allocator, raw_line: []const u8) ![]u8 {
    return repl_session_mod.formatTaskNotificationAlloc(allocator, raw_line);
}

fn ingestTaskNotifications(
    allocator: std.mem.Allocator,
    transcript: *UiTranscript,
    use_fullscreen: bool,
    writer: anytype,
    scroll_offset: *usize,
    mode: SessionMode,
    options: Options,
    cursor: *usize,
    strip_state: *TaskNotificationStripState,
) !void {
    const note_path = try tool_helpers.workspacePathAlloc(allocator, ".", tool_helpers.TASK_NOTIFICATIONS_SUBPATH);
    defer allocator.free(note_path);
    const file = std.Io.Dir.cwd().openFile(rt.io, note_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close(rt.io);

    const stat = try file.stat(rt.io);
    const file_size: usize = @intCast(stat.size);
    var start = cursor.*;
    if (start > file_size) start = 0;
    if (start == file_size) return;

    const max_chunk: usize = 128 * 1024;
    if (file_size - start > max_chunk) {
        start = file_size - max_chunk;
    }

    const read_len = file_size - start;
    const data_full = try allocator.alloc(u8, read_len);
    defer allocator.free(data_full);
    var data = data_full;
    if (read_len > 0) {
        const offset: u64 = @intCast(start);
        const n = try file.readPositionalAll(rt.io, data_full, offset);
        if (n < data_full.len) data = data_full[0..n];
    }

    var scan = data;
    if (start > 0) {
        if (std.mem.indexOfScalar(u8, scan, '\n')) |nl| {
            scan = scan[nl + 1 ..];
        } else {
            scan = &.{};
        }
    }

    var line_iter = std.mem.splitScalar(u8, scan, '\n');
    var appended = false;
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        const msg = try formatTaskNotificationAlloc(allocator, trimmed);
        defer allocator.free(msg);
        appendTaskNotificationSummary(allocator, strip_state, trimmed);

        if (use_fullscreen) {
            if (!appended) try appendTranscriptDivider(allocator, transcript, "\xe2\x9a\xa1 Task");
            try transcript.appendLine(allocator, msg);
        } else {
            try writeStyledText(writer, msg, options);
            try writer.writeByte('\n');
        }
        appended = true;
    }
    cursor.* = file_size;

    if (appended and use_fullscreen) {
        scroll_offset.* = 0;
        try renderFullScreen(writer, transcript, true, "", scroll_offset.*, "", mode, options);
    }
}

/// Render the launch dashboard into the fullscreen transcript. It follows
/// modern TUI practice: a compact identity card, explicit context chips,
/// and task-oriented commands instead of a long static help paragraph.
fn appendWelcomeBanner(allocator: std.mem.Allocator, transcript: *UiTranscript, options: Options) !void {
    const color = shouldUseColor(options);
    try transcript.appendLine(allocator, "");

    var model_value_buf: [160]u8 = undefined;
    const model_value = std.fmt.bufPrint(&model_value_buf, "{s}/{s}", .{ options.status_provider, options.status_model }) catch options.status_model;

    const card_top = if (color)
        try std.fmt.allocPrint(allocator, "    {s}╭" ++ ("─" ** 66) ++ "╮{s}", .{ repl_markdown_mod.brandAccentDimAnsi(options), ANSI_RESET })
    else
        try allocator.dupe(u8, "    +" ++ ("-" ** 66) ++ "+");
    defer allocator.free(card_top);
    try transcript.appendLine(allocator, card_top);

    const title = if (color)
        try std.fmt.allocPrint(
            allocator,
            "    {s}│{s}  {s}{s} zcode{s} {s}v{s}{s}  {s}terminal workbench for agentic code{s}",
            .{
                repl_markdown_mod.brandAccentDimAnsi(options),
                ANSI_RESET,
                repl_markdown_mod.brandAccentBoldAnsi(options),
                figures.BLACK_DIAMOND,
                ANSI_RESET,
                ANSI_DIM,
                options.app_version,
                ANSI_RESET,
                ANSI_DIM,
                ANSI_RESET,
            },
        )
    else
        try std.fmt.allocPrint(allocator, "    |  * zcode v{s}  terminal workbench for agentic code", .{options.app_version});
    defer allocator.free(title);
    try transcript.appendLine(allocator, title);

    try appendWelcomeRow(allocator, transcript, color, options, "workspace", options.status_workspace);
    try appendWelcomeRow(allocator, transcript, color, options, "model", model_value);
    try appendWelcomeRow(allocator, transcript, color, options, "safety", options.status_approval_mode);

    // Surface KAIROS proposals queued while the user was away.
    const kairos_pending = kairos_brief_mod.proposalCount(allocator, options.status_workspace);
    if (kairos_pending > 0) {
        const kv = try std.fmt.allocPrint(allocator, "{d} proposal(s) pending -- /kairos to review", .{kairos_pending});
        defer allocator.free(kv);
        try appendWelcomeRow(allocator, transcript, color, options, "kairos", kv);
    }

    const card_bottom = if (color)
        try std.fmt.allocPrint(allocator, "    {s}╰" ++ ("─" ** 66) ++ "╯{s}", .{ repl_markdown_mod.brandAccentDimAnsi(options), ANSI_RESET })
    else
        try allocator.dupe(u8, "    +" ++ ("-" ** 66) ++ "+");
    defer allocator.free(card_bottom);
    try transcript.appendLine(allocator, card_bottom);
    try transcript.appendLine(allocator, "");

    try appendWelcomeSection(allocator, transcript, color, options, "Quick reference");
    try appendWelcomeCommand(allocator, transcript, color, options, "type", "ask a task in plain English, then press Enter");
    try appendWelcomeCommand(allocator, transcript, color, options, "@file", "attach a file as context");
    try appendWelcomeCommand(allocator, transcript, color, options, "/", "browse commands; / + i for /init, / + h for help");
    try appendWelcomeCommand(allocator, transcript, color, options, options.ui_leader_key, "command palette (h), pick model (m), sessions (s)");
    try appendWelcomeCommand(allocator, transcript, color, options, "Esc Esc", "cancel turn  •  Ctrl+C x3 to exit");

    // Contextual example based on the repo's git history: "Try
    // 'refactor src/core/format.zig'". Best-effort -- if git isn't
    // available, the workspace isn't a repo, or every candidate got
    // filtered as non-core, we silently skip the tip. Ported from
    // claude-code-main/src/utils/exampleCommands.ts.
    if (options.status_workspace.len > 0) {
        const example_commands = @import("../core/example_commands.zig");
        if (example_commands.getExamplePrompt(allocator, options.status_workspace) catch null) |prompt| {
            defer allocator.free(prompt);
            var tip_buf: [512]u8 = undefined;
            const tip = std.fmt.bufPrint(&tip_buf, "Try \"{s}\"", .{prompt}) catch "";
            if (tip.len > 0) {
                try appendWelcomeTip(allocator, transcript, color, options, tip);
            }
        }
    }
    // First-run nudge: when the workspace has no ZCODE.md or
    // CLAUDE.md yet, point the user at /init. The hint vanishes as
    // soon as either file exists, so returning users never see it.
    // Ported from claude-code-main's shouldShowProjectOnboarding
    // gate in src/projectOnboardingState.ts: the nudge also graduates
    // after it has been shown 4 times or once onboarding is marked
    // complete, both tracked in the persistent runtime-state store.
    // We bump the per-project seen-count exactly here -- the one site
    // that actually renders the nudge -- so the cap matches the
    // reference's incrementProjectOnboardingSeenCount semantics.
    if (options.status_workspace.len > 0 and onboarding_mod.shouldShowProjectOnboarding(allocator, options.status_workspace)) {
        try appendWelcomeTip(allocator, transcript, color, options, "This workspace has no ZCODE.md -- run /init to create one");
        onboarding_mod.incrementSeenCount(allocator, options.status_workspace);
    }
    try transcript.appendLine(allocator, "");
}

/// Build the "what's new since you last looked" startup surface (Task 14.15 /
/// styles-onboarding-05). Loads the persisted last-seen release-notes version,
/// filters the embedded changelog to versions strictly newer than it (capped at
/// changelog_mod.MAX_RELEASE_NOTES_SHOWN), stamps the current version as seen,
/// and returns the formatted notes as an owned string. Returns null when there
/// is nothing new to show.
///
/// On the very first run after this ships the stored version is empty. Rather
/// than greet every existing user with the full changelog, we stamp silently in
/// that case and surface nothing -- matching the reference's "no previous
/// version, stamp without flooding" stance (releaseNotes.ts setup path).
/// Caller owns the returned slice.
fn buildReleaseNotesOnStartup(allocator: std.mem.Allocator, current_version: []const u8) !?[]u8 {
    if (build_options.changelog.len == 0) return null;

    var state = runtime_state_mod.load(allocator);
    defer state.deinit();

    const last_seen = runtime_state_mod.getLastReleaseNotesSeen(&state);
    const current_base = changelog_mod.stripBuildMetadata(current_version);

    // Nothing new when the current version is already the last-seen one.
    if (last_seen.len > 0) {
        const last_base = changelog_mod.stripBuildMetadata(last_seen);
        if (changelog_mod.compareVersions(last_base, current_base) != .lt) return null;
    }

    // First run (empty last_seen): stamp the current version silently and show
    // nothing, so existing users do not get a wall of notes on upgrade-to-this.
    const first_run = last_seen.len == 0;

    // Always stamp the current version as seen (best-effort) so the surface
    // appears at most once per upgrade.
    runtime_state_mod.setLastReleaseNotesSeen(&state, current_base);
    runtime_state_mod.save(&state);

    if (first_run) return null;

    const entries = changelog_mod.checkForReleaseNotes(allocator, build_options.changelog, last_seen, current_version);
    defer changelog_mod.freeEntries(allocator, entries);
    if (entries.len == 0) return null;

    return try changelog_mod.formatRecent(allocator, entries, changelog_mod.MAX_RELEASE_NOTES_SHOWN);
}

/// Append the startup release-notes surface to the fullscreen transcript.
/// Best-effort: any failure simply skips the surface.
fn appendReleaseNotesOnStartup(allocator: std.mem.Allocator, transcript: *UiTranscript, options: Options) void {
    const notes = (buildReleaseNotesOnStartup(allocator, options.app_version) catch return) orelse return;
    defer allocator.free(notes);
    const color = shouldUseColor(options);

    const header = if (color)
        std.fmt.allocPrint(allocator, "    {s}{s}{s} {s}What's new in v{s}{s}", .{
            repl_markdown_mod.brandAccentAnsi(options),
            figures.BLOCKQUOTE_BAR,
            ANSI_RESET,
            ANSI_BOLD,
            changelog_mod.stripBuildMetadata(options.app_version),
            ANSI_RESET,
        }) catch null
    else
        std.fmt.allocPrint(allocator, "    {s} What's new in v{s}", .{ figures.BLOCKQUOTE_BAR, changelog_mod.stripBuildMetadata(options.app_version) }) catch null;
    if (header) |h| {
        defer allocator.free(h);
        transcript.appendLine(allocator, h) catch {};
    }

    var line_iter = std.mem.splitScalar(u8, notes, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        const indented = std.fmt.allocPrint(allocator, "      {s}", .{line}) catch continue;
        defer allocator.free(indented);
        transcript.appendLine(allocator, indented) catch {};
    }
    transcript.appendLine(allocator, "") catch {};
}

/// Write the startup release-notes surface to the non-fullscreen / piped
/// writer. Best-effort.
fn writeReleaseNotesOnStartup(allocator: std.mem.Allocator, writer: anytype, options: Options) void {
    const notes = (buildReleaseNotesOnStartup(allocator, options.app_version) catch return) orelse return;
    defer allocator.free(notes);
    writer.print("\n  What's new in v{s}:\n", .{changelog_mod.stripBuildMetadata(options.app_version)}) catch return;
    writer.writeAll(notes) catch return;
    writer.writeAll("\n") catch {};
}

fn appendWelcomeSection(allocator: std.mem.Allocator, transcript: *UiTranscript, color: bool, options: Options, title: []const u8) !void {
    const line = if (color)
        try std.fmt.allocPrint(
            allocator,
            "    {s}{s}{s} {s}{s}{s}",
            .{ repl_markdown_mod.brandAccentAnsi(options), figures.BLOCKQUOTE_BAR, ANSI_RESET, ANSI_BOLD, title, ANSI_RESET },
        )
    else
        try std.fmt.allocPrint(allocator, "    {s} {s}", .{ figures.BLOCKQUOTE_BAR, title });
    defer allocator.free(line);
    try transcript.appendLine(allocator, line);
}

fn appendWelcomeCommand(allocator: std.mem.Allocator, transcript: *UiTranscript, color: bool, options: Options, command: []const u8, description: []const u8) !void {
    const line = if (color)
        try std.fmt.allocPrint(
            allocator,
            "      {s}{s: <10}{s}  {s}{s}{s}",
            .{ repl_markdown_mod.brandAccentBoldAnsi(options), command, ANSI_RESET, ANSI_DIM, description, ANSI_RESET },
        )
    else
        try std.fmt.allocPrint(allocator, "      {s: <10}  {s}", .{ command, description });
    defer allocator.free(line);
    try transcript.appendLine(allocator, line);
}

fn appendWelcomeRow(allocator: std.mem.Allocator, transcript: *UiTranscript, color: bool, options: Options, label: []const u8, value: []const u8) !void {
    if (value.len == 0) return;
    const line = if (color)
        try std.fmt.allocPrint(
            allocator,
            "    {s}│{s}   {s}{s: <9}{s}  {s}",
            .{ repl_markdown_mod.brandAccentDimAnsi(options), ANSI_RESET, ANSI_DIM, label, ANSI_RESET, value },
        )
    else
        try std.fmt.allocPrint(allocator, "    |   {s: <9}  {s}", .{ label, value });
    defer allocator.free(line);
    try transcript.appendLine(allocator, line);
}

fn appendWelcomeTip(allocator: std.mem.Allocator, transcript: *UiTranscript, color: bool, options: Options, text: []const u8) !void {
    // Tip text is dimmed so the mint bullet pops visually. The
    // previous rendering put default-color tip text next to a
    // default-color bullet (when color was off) or a mint bullet
    // next to default-color text (when color was on). The mint
    // bullet alone doesn't read as a tip marker -- with the tip
    // text dimmed, the bullet stands out as the scannable anchor
    // and the text sits clearly in secondary-info tone.
    const line = if (color)
        try std.fmt.allocPrint(allocator, "      {s}" ++ figures.BULLET ++ "{s} {s}{s}{s}", .{
            repl_markdown_mod.brandAccentAnsi(options),
            ANSI_RESET,
            ANSI_DIM,
            text,
            ANSI_RESET,
        })
    else
        try std.fmt.allocPrint(allocator, "      " ++ figures.BULLET ++ " {s}", .{text});
    defer allocator.free(line);
    try transcript.appendLine(allocator, line);
}

/// Write a compact welcome header for the non-fullscreen / piped-output
/// path. Same content as the fullscreen banner but collapsed to a single
/// accent line and three info rows so it stays readable when redirected
/// to a log or pager.
fn writeWelcomeHeader(allocator: std.mem.Allocator, writer: anytype, options: Options) !void {
    const color = shouldUseColor(options);
    // Same shouldShowProjectOnboarding gate as the fullscreen banner: the
    // nudge graduates after 4 views or once onboarding is marked complete.
    const needs_instruction_file = options.status_workspace.len > 0 and
        onboarding_mod.shouldShowProjectOnboarding(allocator, options.status_workspace);
    if (needs_instruction_file) {
        onboarding_mod.incrementSeenCount(allocator, options.status_workspace);
    }
    if (color) {
        try writer.print("\n  {s}{s}{s} {s}zcode{s} {s}v{s}{s}  {s}terminal workbench for agentic code tasks{s}\n", .{
            repl_markdown_mod.brandAccentAnsi(options),
            figures.BLACK_DIAMOND,
            ANSI_RESET,
            ANSI_BOLD,
            ANSI_RESET,
            ANSI_DIM,
            options.app_version,
            ANSI_RESET,
            ANSI_DIM,
            ANSI_RESET,
        });
        try writer.print("  {s}workspace{s} {s}\n", .{ ANSI_DIM, ANSI_RESET, options.status_workspace });
        try writer.print("  {s}model    {s} {s}/{s}\n", .{ ANSI_DIM, ANSI_RESET, options.status_provider, options.status_model });
        try writer.print("  {s}safety   {s} {s}\n\n", .{ ANSI_DIM, ANSI_RESET, options.status_approval_mode });
        if (needs_instruction_file) {
            try writer.print(
                "  {s}" ++ figures.ARROW_HOOK ++ "{s} {s}run /init to create ZCODE.md for this workspace (/onboarding shows setup help){s}\n",
                .{ repl_markdown_mod.brandAccentAnsi(options), ANSI_RESET, ANSI_DIM, ANSI_RESET },
            );
        }
        try writer.print("  {s}Enter submit  " ++ figures.BULLET_OPERATOR ++ "  Shift+Enter newline  " ++ figures.BULLET_OPERATOR ++ "  Ctrl+X H palette  " ++ figures.BULLET_OPERATOR ++ "  ? shortcuts{s}\n\n", .{ ANSI_DIM, ANSI_RESET });
    } else {
        try writer.print("\n  * zcode v{s}  terminal workbench for agentic code tasks\n", .{options.app_version});
        try writer.print("  workspace: {s}\n", .{options.status_workspace});
        try writer.print("      model: {s}/{s}\n", .{ options.status_provider, options.status_model });
        try writer.print("     safety: {s}\n\n", .{options.status_approval_mode});
        if (needs_instruction_file) {
            try writer.print("  " ++ figures.ARROW_HOOK ++ " run /init to create ZCODE.md for this workspace (/onboarding shows setup help)\n", .{});
        }
        try writer.print("  Enter submit | Shift+Enter newline | Ctrl+X H palette | ? shortcuts\n\n", .{});
    }
}

/// Install a SIGINT handler that ignores the signal, so Ctrl+C does not
/// kill the process. In fullscreen/raw mode, ISIG is disabled and Ctrl+C
/// sends byte 0x03 which the input loop handles. In non-fullscreen mode,
/// this prevents termination so the line-based reader can handle it.
fn installSigintIgnore() void {
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = struct {
            fn handler(_: std.posix.SIG) callconv(.c) void {}
        }.handler },
        .mask = undefined,
        .flags = 0,
    };
    @memset(std.mem.asBytes(&act.mask), 0);
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

/// Emit an OSC 9;4 indeterminate (busy) progress sequence at the start of a
/// turn on terminals that render it (ConEmu / Ghostty 1.2.0+ / iTerm2 3.6.6+).
/// zcode does not track a turn percentage, so the honest state is
/// indeterminate. No-op (and no escape bytes) when unsupported or piped, so
/// non-capable terminals never see stray OSC noise. Failures to write are
/// swallowed -- a cosmetic taskbar bar must never break the turn.
fn emitTurnProgressStart(writer: anytype) void {
    if (!terminal_caps_mod.isProgressReportingAvailable()) return;
    var buf: [32]u8 = undefined;
    const seq = progress_osc_mod.indeterminate(&buf);
    if (seq.len > 0) writer.writeAll(seq) catch {};
}

/// Clear the OSC 9;4 progress bar at the end of a turn (success or error) so a
/// crashed or finished turn never leaves a stuck taskbar indicator. Same gating
/// and best-effort write semantics as `emitTurnProgressStart`.
fn emitTurnProgressClear(writer: anytype) void {
    if (!terminal_caps_mod.isProgressReportingAvailable()) return;
    var buf: [32]u8 = undefined;
    const seq = progress_osc_mod.clear(&buf);
    if (seq.len > 0) writer.writeAll(seq) catch {};
}

/// First-run trust gate (ui-dialogs-01). When `cwd` is not already trusted,
/// enumerate the dangerous capabilities it would activate and prompt the user.
/// Returns `true` when the user DECLINED (the caller should exit the REPL) and
/// `false` when the workspace is already trusted, the user accepted, or there
/// was nothing to show. On accept, trust is persisted via `trust.allow` so a
/// trusted repo never re-prompts.
fn runTrustGate(allocator: std.mem.Allocator, cwd: []const u8, bottom_margin_rows: usize) !bool {
    // Fast path: a workspace already in the user trust store never re-prompts
    // (the `checkHasTrustDialogAccepted` equivalent).
    var trust_status = trust_mod.status(allocator, cwd) catch return false;
    defer trust_status.deinit(allocator);
    if (trust_status.trusted) return false;

    // Env-var detection is exercised in trust_capabilities tests; the live REPL
    // does not thread the loaded config's settings_env into run(), so the gate
    // enumerates the file-derived capabilities (project MCP servers, hooks,
    // command-helper keys) read directly from the workspace.
    const empty_env = [_]trust_capabilities_mod.EnvVar{};
    var caps = trust_capabilities_mod.detect(allocator, cwd, &empty_env) catch return false;
    defer caps.deinit();

    const body_lines = caps.formatBodyLines(allocator) catch return false;
    defer {
        for (body_lines) |l| allocator.free(l);
        allocator.free(body_lines);
    }

    // Build the borrowed const view the overlay expects.
    var body_view = std.array_list.Managed([]const u8).init(allocator);
    defer body_view.deinit();
    if (body_lines.len == 0) {
        body_view.append("No project MCP servers, hooks, or command helpers detected.") catch {};
    } else {
        for (body_lines) |l| body_view.append(l) catch {};
    }

    const choices = [_][]const u8{ "No, exit", "Yes, proceed" };
    const selected = repl_overlay_mod.runTrustGateOverlayLoop(
        "Do you trust the files in this folder?",
        body_view.items,
        &choices,
        bottom_margin_rows,
    ) catch return true; // a read error on the gate declines (safe default).

    if (selected == 1) {
        // Accepted: persist trust so future launches skip the gate.
        const msg = trust_mod.allow(allocator, cwd, null) catch return false;
        allocator.free(msg);
        return false;
    }
    // Declined ("No, exit" or Esc): tell the caller to exit.
    return true;
}

/// Pure decision for the BypassPermissionsMode warning gate (ui-dialogs-02).
/// Returns true only when the session is in bypass mode AND the user has not
/// already accepted the danger warning (the persisted skip flag is false).
/// Mirrors the reference gate condition:
///   (permissionMode === 'bypassPermissions' || allowDangerouslySkipPermissions)
///   && !hasSkipDangerousModePermissionPrompt()
/// where `bypass_active` collapses both the bypass mode and the
/// dangerously-skip flag into a single "no approvals will be requested" signal.
pub fn shouldShowBypassGate(bypass_active: bool, skip_flag: bool) bool {
    return bypass_active and !skip_flag;
}

/// BypassPermissionsMode warning gate (ui-dialogs-02). When the session is in
/// bypass mode and the user has not previously accepted, render a red warning
/// explaining no approvals will be requested. Returns `true` when the user
/// DECLINED (the caller should exit the REPL) and `false` when the gate should
/// not show, the user accepted, or a read error occurred. On accept, persists
/// `skip_dangerous_mode_permission_prompt = true` so it never re-shows.
fn runBypassGate(allocator: std.mem.Allocator, bottom_margin_rows: usize) !bool {
    const body_lines = [_][]const u8{
        "zcode will NOT ask for your approval before running potentially",
        "dangerous commands. This mode should only be used in a sandboxed",
        "container or VM with no access to the broader internet or sensitive",
        "data such as production credentials.",
        "",
        "Docs: https://code.claude.com/docs/en/security",
    };

    const choices = [_][]const u8{ "No, exit", "Yes, I accept" };
    const selected = repl_overlay_mod.runTrustGateOverlayLoop(
        "WARNING: zcode running in Bypass Permissions mode",
        &body_lines,
        &choices,
        bottom_margin_rows,
    ) catch return true; // a read error on the gate declines (safe default).

    if (selected == 1) {
        // Accepted: persist the skip flag so future launches never re-show.
        config_parse.persistUserConfigField(allocator, "skip_dangerous_mode_permission_prompt", "true") catch |err| {
            // Persistence failure must not block the session; log and proceed.
            std.log.warn("zcode: failed to persist skip_dangerous_mode_permission_prompt: {s}", .{@errorName(err)});
        };
        return false;
    }
    // Declined ("No, exit" or Esc): tell the caller to exit.
    return true;
}

pub fn run(allocator: std.mem.Allocator, _: anytype, writer: anytype, handler: Handler, options_in: Options) !void {
    var options = options_in;
    var runtime_keybindings = keybindings_mod.loadRuntimeKeybindings(allocator);
    defer runtime_keybindings.deinit(allocator);
    try keybindings_mod.installLeaderKeyDefaults(allocator, &runtime_keybindings, options.ui_leader_key);
    options.keybindings = &runtime_keybindings;
    const original_status_approval_mode = options.status_approval_mode;

    // Bump the persisted startup counter once per interactive REPL session
    // (styles-onboarding-06 / Task 14.16). This runs only here, in the
    // interactive `run()` entry, so one-shot subcommands (`zcode version`,
    // a single piped prompt) never reach it and do not advance the counter.
    // It must run early, before tips/onboarding/release-notes are evaluated,
    // since those gate on `num_startups`. Best-effort: a failed state write
    // returns 1 and must never block boot.
    _ = runtime_state_mod.incrementStartups(allocator);

    // Clear the KAIROS presence heartbeat on exit so a background KAIROS process
    // can resume cron ownership promptly instead of waiting out the staleness
    // window. Best-effort. See ADR 0009.
    defer kairos_lock.clearPresence(allocator, options_in.status_workspace);

    // Force-stop the sleep guard on REPL exit (background-svc-07 cleanup
    // hook). The caffeinate `-w <pid>` tie already kills the child when
    // zcode dies, but this also joins the restart thread cleanly on a
    // normal return so it does not outlive the session.
    defer @import("../core/prevent_sleep.zig").forceStopPreventSleep();

    // Small-terminal check: fullscreen + overlays need at least
    // ~60x20 to render without corruption. Below that we silently
    // downgrade to the inline / non-fullscreen UI so the user gets
    // a readable session instead of ANSI noise. The warning goes
    // out via std.log so it's visible under --verbose but doesn't
    // clutter the banner on normal runs.
    const MIN_COLS: usize = 60;
    const MIN_ROWS: usize = 20;
    const cols_now = terminalCols();
    const rows_now = terminalRows();
    if ((cols_now > 0 and cols_now < MIN_COLS) or (rows_now > 0 and rows_now < MIN_ROWS)) {
        std.log.warn("zcode: terminal is {d}x{d}; fullscreen UI needs at least {d}x{d}. Falling back to inline mode.", .{ cols_now, rows_now, MIN_COLS, MIN_ROWS });
        options.enable_fullscreen = false;
        options.enable_alt_screen = false;
        options.enable_synchronized_output = false;
    }

    const use_fullscreen = options.enable_fullscreen and canUseFullScreenUi();
    var fullscreen_active = false;
    var raw_mode = TerminalRawMode{};

    // Ignore SIGINT so Ctrl+C doesn't kill the process.
    // In raw mode, ISIG is disabled so Ctrl+C sends byte 0x03 which we handle.
    // In non-raw mode, this handler prevents SIGINT from terminating the process.
    installSigintIgnore();

    var transcript = UiTranscript.init(allocator, options.transcript_max_lines);
    defer transcript.deinit(allocator);

    // The welcome banner gets cleared the first time the user submits
    // input so the conversation isn't squeezed under the cheat-sheet.
    var welcome_active = false;

    if (use_fullscreen) {
        if (options.enable_alt_screen) {
            // Flip the flag BEFORE attempting enterAltScreen so a partial
            // write failure (e.g. SIGPIPE mid-sequence on a redirected
            // stdout) still triggers leaveAltScreen in the defer below.
            // Previously a short write left the terminal in a mixed state
            // with bracketed paste / mouse tracking / alt buffer partially
            // on, and the outer cleanup never ran.
            fullscreen_active = true;
            enterAltScreen(writer) catch {};
        }
        raw_mode.enable();
        try appendWelcomeBanner(allocator, &transcript, options);
        appendReleaseNotesOnStartup(allocator, &transcript, options);
        welcome_active = true;
        try renderFullScreen(writer, &transcript, true, "", 0, "", .execution, options);
    } else {
        try writeWelcomeHeader(allocator, writer, options);
        writeReleaseNotesOnStartup(allocator, writer, options);
    }
    defer {
        raw_mode.disable();
        if (fullscreen_active) {
            leaveAltScreen(writer) catch {};
        }
    }

    // First-run trust gate (ui-dialogs-01). On the first interactive session in
    // an untrusted workspace, enumerate the dangerous capabilities the workspace
    // would activate (project MCP servers, hooks, command-helper keys) and ask
    // the user to accept trust before any tool can run. Interactive-only:
    // `use_fullscreen` already requires a TTY on both stdin and stdout, so this
    // never fires under `-p` / piped / CI mode (which never reaches the
    // reference's showSetupScreens). The decision is persisted via
    // `trust.allow`, so a trusted repo never re-prompts. Mirrors the trust-first
    // gate ordering in interactiveHelpers.tsx:131-144.
    if (use_fullscreen and options.status_workspace.len > 0) {
        if (try runTrustGate(allocator, options.status_workspace, options.bottom_margin_rows)) {
            // Declined: exit the REPL cleanly. The terminal-cleanup defers above
            // restore the screen; returning here matches the reference's
            // gracefulShutdown on decline (no tool ever runs).
            return;
        }
    }

    // BypassPermissionsMode warning gate (ui-dialogs-02). After trust is
    // established (reference gate ordering: trust first, then bypass), if the
    // session is in bypass mode (either an explicit bypassPermissions approval
    // mode or the --yolo dangerously-skip flag) and the user has not already
    // accepted the warning, render the red danger gate. Interactive-only:
    // `use_fullscreen` requires a TTY, so this never fires under -p / piped /
    // CI mode. The skip flag is persisted on accept so it never re-shows.
    // Mirrors interactiveHelpers.tsx:218-223.
    if (use_fullscreen) {
        const bypass_active =
            permission_decision.modeFromString(original_status_approval_mode) == .bypassPermissions or
            options.yolo_mode;
        if (shouldShowBypassGate(bypass_active, options.skip_dangerous_mode_permission_prompt)) {
            if (try runBypassGate(allocator, options.bottom_margin_rows)) {
                // Declined: exit the REPL cleanly, mirroring the trust gate's
                // decline path (no tool ever runs).
                return;
            }
        }
    }

    var line_buf = std_io.StringBuilder.init(allocator);
    defer line_buf.deinit();
    var input_buf = std_io.StringBuilder.init(allocator);
    defer input_buf.deinit();
    var prompt_history = PromptHistoryState.init(allocator);
    defer prompt_history.deinit(allocator);
    var prompt_undo = PromptUndoState.init(allocator);
    defer prompt_undo.deinit(allocator);
    var vim_state = VimState.init(allocator);
    defer vim_state.deinit();
    var stashed_prompt: ?StashedPrompt = null;
    defer if (stashed_prompt) |*stash| stash.deinit(allocator);
    // Cursor position within input_buf (byte offset, 0..items.len).
    // Insert/delete operations happen at this position.
    var input_cursor: usize = 0;
    var input_hint_buf: [320]u8 = undefined;
    var input_hint_len: usize = 0;
    var slash_suggestion_selection: usize = 0;
    var slash_suggestion_selection_touched = false;
    var reference_suggestion_selection: usize = 0;
    var reference_suggestion_selection_touched = false;
    var starter_suggestion_selection: usize = 0;
    var runtime_hint_buf: [320]u8 = undefined;
    var runtime_hint_len: usize = 0;
    setHint(&runtime_hint_buf, &runtime_hint_len, "idle: waiting for your input");
    vim_state.setEnabled(options.vim_mode_enabled);
    if (options.vim_mode_enabled) {
        try vim_state.beginInsertSession(input_buf.items(), input_cursor);
    }
    var scroll_offset: usize = 0;
    var mode: SessionMode = .execution;
    // P3 (PRD #534): live permission mode for Shift+Tab cycling inside the
    // approval overlay. Seeded from the config's approval_mode only when it
    // carries a reference mode name (acceptEdits/plan/bypassPermissions/dontAsk);
    // legacy tiered-auto/manual/strict sessions keep the overlay inactive so
    // their behavior is byte-for-byte unchanged.
    var permission_mode: permission_decision.Mode = permission_decision.modeFromString(original_status_approval_mode);
    const permission_mode_active: bool = permission_decision.isReferenceModeName(original_status_approval_mode);
    var latest_plan_path: ?[]u8 = null;
    defer if (latest_plan_path) |path| allocator.free(path);
    var queued_prompt: ?[]u8 = null;
    defer if (queued_prompt) |p| allocator.free(p);
    if (options.initial_prompt) |ip| {
        queued_prompt = try allocator.dupe(u8, ip);
    }
    const example_commands = @import("../core/example_commands.zig");
    const cached_example_placeholder: ?[]u8 = if (options.status_workspace.len > 0)
        (example_commands.getExamplePrompt(allocator, options.status_workspace) catch null)
    else
        null;
    defer if (cached_example_placeholder) |prompt| allocator.free(prompt);
    const cached_history_suggestion: ?[]u8 = blk: {
        if (cached_example_placeholder != null or options.status_workspace.len == 0) break :blk null;
        const empty_prompts = [_][]const u8{};
        const items = repl_history_mod.buildSearchItems(allocator, options.status_workspace, empty_prompts[0..], 1) catch break :blk null;
        defer repl_history_mod.freeSearchItems(allocator, items);
        if (items.len == 0) break :blk null;
        const trimmed = std.mem.trim(u8, items[0].prompt, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] == '/') break :blk null;
        break :blk allocator.dupe(u8, trimmed[0..@min(trimmed.len, 160)]) catch null;
    };
    defer if (cached_history_suggestion) |prompt| allocator.free(prompt);
    var file_suggestion_data: ?repl_quick_open_mod.Data = null;
    defer if (file_suggestion_data) |*data| data.deinit();
    var file_suggestion_data_loaded = false;
    var dynamic_command_suggestions = DynamicCommandSuggestionCache.init(allocator);
    defer dynamic_command_suggestions.deinit(allocator);
    var dynamic_reference_suggestions = DynamicCommandSuggestionCache.init(allocator);
    defer dynamic_reference_suggestions.deinit(allocator);
    var prompt_attachments = repl_attachments_mod.Store.init(allocator);
    defer prompt_attachments.deinit(allocator);
    var queued_prompt_backlog = OwnedStringQueue.init(allocator);
    defer queued_prompt_backlog.deinit(allocator);
    var task_strip_notifications = TaskNotificationStripState{};
    var prompt_notifications = UiNotificationQueue{};
    var submitted_prompt_count: usize = 0;
    syncVimUiState(&options, &vim_state, &input_buf, &input_cursor);
    var queued_prompt_restore_to_editor = false;
    var queued_prompt_restored_draft = false;
    var plan_approved_pending: bool = false;
    var interrupt_count: u8 = 0;
    var last_interrupt_ts: i64 = 0;
    var last_kill_background_tasks_ts: i64 = 0;
    // Start cursor at current file size so we only show notifications from this session
    var task_notification_cursor: usize = blk: {
        const task_notifications_path = try tool_helpers.workspacePathAlloc(allocator, ".", tool_helpers.TASK_NOTIFICATIONS_SUBPATH);
        defer allocator.free(task_notifications_path);
        const f = std.Io.Dir.cwd().openFile(rt.io, task_notifications_path, .{}) catch break :blk 0;
        defer f.close(rt.io);
        const stat = f.stat(rt.io) catch break :blk 0;
        break :blk @intCast(stat.size);
    };
    var footer_tasks_state_buf: [32]u8 = undefined;
    var footer_teams_state_buf: [48]u8 = undefined;
    var footer_bridge_state_buf: [48]u8 = undefined;
    var footer_agent_state_buf: [48]u8 = undefined;
    var footer_tmux_state_buf: [48]u8 = undefined;
    var footer_worktree_state_buf: [48]u8 = undefined;
    var footer_state_refresh_at_ms: i64 = 0;
    var prompt_surface_selection: ?usize = null;
    var prompt_frame_current = false;

    while (true) {
        ingestTaskNotifications(
            allocator,
            &transcript,
            use_fullscreen,
            writer,
            &scroll_offset,
            mode,
            options,
            &task_notification_cursor,
            &task_strip_notifications,
        ) catch {};

        // Refresh the KAIROS presence heartbeat so a background KAIROS process
        // for this project stays dormant (and yields cron ownership) while this
        // interactive REPL is alive. See ADR 0009.
        kairos_lock.heartbeat(allocator, options.status_workspace);

        // Poll cron scheduler: if a recurring/one-shot job is due, inject its
        // prompt as if the user typed it. Project-scoped so the REPL only fires
        // this repo's tasks (plus untagged globals).
        if (queued_prompt == null) {
            const tool_dispatch = @import("../tools/tool_dispatch.zig");
            if (tool_dispatch.pollCronDueForCwd(allocator, options.status_workspace)) |cron_prompt| {
                queued_prompt = allocator.dupe(u8, cron_prompt) catch null;
            }
        }
        if (queued_prompt == null and !queued_prompt_restored_draft) {
            if (queued_prompt_backlog.popFirstOwned()) |pending| {
                queued_prompt = pending;
                // Auto-submit: same reasoning as the post-turn drain
                // above. The user enqueued this with an explicit
                // Enter press; the queue exists so they don't have
                // to wait. Forcing a second Enter per item turned
                // the queue into a per-message gate.
                queued_prompt_restore_to_editor = false;
            }
        }

        var owned_line: ?[]u8 = null;
        defer if (owned_line) |line| allocator.free(line);
        var transformed_from_command = false;

        if (queued_prompt) |queued| {
            if (use_fullscreen and queued_prompt_restore_to_editor and !plan_approved_pending) {
                try replaceInputFromPromptText(allocator, &input_buf, &input_cursor, &prompt_attachments, queued);
                allocator.free(queued);
                queued_prompt = null;
                queued_prompt_restore_to_editor = false;
                queued_prompt_restored_draft = true;
                setHint(&input_hint_buf, &input_hint_len, "queued prompt restored to editor");
                pushPromptNotice(&prompt_notifications, "Queue restored", "restored queued prompt into the composer", "queue", .accent);
                syncVimUiState(&options, &vim_state, &input_buf, &input_cursor);
            } else {
                owned_line = queued;
                queued_prompt = null;
                queued_prompt_restore_to_editor = false;
                transformed_from_command = true;
                if (plan_approved_pending) {
                    _ = handler.command.?(handler.ctx, allocator, "__plan_approve_on") catch null;
                }
            }
        } else if (use_fullscreen) {
            while (true) {
                var merged_hint_buf: [320]u8 = undefined;
                var default_input_hint_buf: [128]u8 = undefined;
                const live_input_hint = if (input_hint_len > 0)
                    input_hint_buf[0..input_hint_len]
                else
                    defaultInputHint(&default_input_hint_buf, input_buf.items(), options);
                const merged_hint = composeStatusHint(
                    &merged_hint_buf,
                    runtime_hint_buf[0..runtime_hint_len],
                    live_input_hint,
                );
                normalizeAttachmentCursor(input_buf.items(), &input_cursor);
                if (extractReferenceToken(input_buf.items(), input_cursor) != null and !file_suggestion_data_loaded and options.status_workspace.len > 0) {
                    file_suggestion_data_loaded = true;
                    file_suggestion_data = repl_quick_open_mod.buildData(allocator, options.status_workspace, 8000) catch null;
                }

                const reference_suggestions = collectReferenceSuggestions(
                    if (file_suggestion_data) |data| data.items else &.{},
                    &dynamic_reference_suggestions,
                    input_buf.items(),
                    input_cursor,
                );
                const reference_suggestion_count = syncReferenceSuggestionSelection(
                    &reference_suggestions,
                    &reference_suggestion_selection,
                    &reference_suggestion_selection_touched,
                );
                const starter_suggestions = collectStarterSuggestions(
                    cached_example_placeholder,
                    cached_history_suggestion,
                    input_buf.items(),
                    submitted_prompt_count,
                    &starter_suggestion_selection,
                );
                const now_ms = clock.nowMillis();
                if (now_ms >= footer_state_refresh_at_ms) {
                    footer_state_refresh_at_ms = now_ms + 1000;
                    options.footer_tasks_state = fetchCompactFooterState(allocator, handler, "__tasks_footer_state", footer_tasks_state_buf[0..]);
                    options.footer_teams_state = fetchCompactFooterState(allocator, handler, "__teams_footer_state", footer_teams_state_buf[0..]);
                    options.footer_bridge_state = fetchCompactFooterState(allocator, handler, "__bridge_footer_state", footer_bridge_state_buf[0..]);
                    options.footer_agent_state = fetchCompactFooterState(allocator, handler, "__agent_footer_state", footer_agent_state_buf[0..]);
                    options.footer_tmux_state = fetchCompactFooterState(allocator, handler, "__tmux_footer_state", footer_tmux_state_buf[0..]);
                    options.footer_worktree_state = fetchCompactFooterState(allocator, handler, "__worktree_footer_state", footer_worktree_state_buf[0..]);
                    if (repl_input_mod.slashAutocompleteQuery(input_buf.items()) != null) {
                        dynamic_command_suggestions.clear(allocator);
                        dynamic_command_suggestions.appendFromCommand(allocator, handler, "__prompt_suggestion_agents");
                        dynamic_command_suggestions.appendFromCommand(allocator, handler, "__prompt_suggestion_teams");
                        dynamic_command_suggestions.appendFromCommand(allocator, handler, "__prompt_suggestion_commands");
                        dynamic_command_suggestions.appendFromCommand(allocator, handler, "__prompt_suggestion_skills");
                        dynamic_command_suggestions.appendFromCommand(allocator, handler, "__prompt_suggestion_mcp");
                        dynamic_command_suggestions.appendFromCommand(allocator, handler, "__prompt_suggestion_shell_bins");
                    }
                    if (extractReferenceToken(input_buf.items(), input_cursor) != null) {
                        dynamic_reference_suggestions.clear(allocator);
                        dynamic_reference_suggestions.appendFromCommand(allocator, handler, "__prompt_reference_suggestions");
                    }
                }
                const command_suggestions = collectCommandSuggestions(input_buf.items(), &dynamic_command_suggestions);
                const slash_suggestion_count = syncCommandSuggestionSelection(
                    &command_suggestions,
                    &slash_suggestion_selection,
                    &slash_suggestion_selection_touched,
                );
                var queue_snapshot = QueuePreviewSnapshot{};
                snapshotQueuedPromptBacklog(&queued_prompt_backlog, &queue_snapshot);
                var prompt_strip = PromptStripItems{};
                var footer_rows = PromptFooterRows{};
                var runtime_banner = RuntimeStripBanner{};
                buildRuntimeStripBanner(
                    &runtime_banner,
                    options.footer_tmux_state,
                    options.footer_worktree_state,
                    options.footer_agent_state,
                );
                buildPromptStripItems(
                    &prompt_strip,
                    queued_prompt,
                    queued_prompt_restore_to_editor,
                    plan_approved_pending,
                    &queue_snapshot,
                    &task_strip_notifications,
                    stashed_prompt,
                    &prompt_notifications,
                    sandbox_mod.peekRecentCount(),
                    &runtime_banner,
                );
                if (reference_suggestion_count > 0) {
                    appendReferenceFooterRows(&footer_rows, reference_suggestions.visible(), reference_suggestion_selection);
                } else if (slash_suggestion_count > 0) {
                    appendCommandFooterRows(&footer_rows, command_suggestions.visible(), slash_suggestion_selection);
                } else {
                    appendStarterFooterRows(&footer_rows, starter_suggestions.visible(), starter_suggestion_selection);
                }
                if (prompt_surface_selection) |selected_idx| {
                    if (selected_idx >= prompt_strip.count) {
                        prompt_surface_selection = if (prompt_strip.count > 0) prompt_strip.count - 1 else null;
                    }
                }
                options.attachment_store = &prompt_attachments;
                options.prompt_strip_items = prompt_strip.visible();
                options.prompt_strip_selection = prompt_surface_selection;
                options.footer_rows = footer_rows.visible();
                options.footer_row_selection = footer_rows.selected_index;
                options.reference_suggestions = reference_suggestions.visible();
                options.reference_suggestion_selection = reference_suggestion_selection;
                options.stashed_prompt_available = stashed_prompt != null;
                var queued_notice_buf: [192]u8 = undefined;
                options.queued_prompt_notice = computeQueuedPromptNotice(
                    queued_notice_buf[0..],
                    queued_prompt,
                    queued_prompt_restore_to_editor,
                    plan_approved_pending,
                );
                options.prompt_suggestion = if (starter_suggestions.count > 0)
                    starter_suggestions.items[@min(starter_suggestion_selection, starter_suggestions.count - 1)].text
                else
                    "";
                options.prompt_placeholder = "";
                var inline_ghost_buf: [256]u8 = undefined;
                options.inline_ghost_text = if (reference_suggestion_count > 0)
                    computeReferenceInlineGhostText(
                        inline_ghost_buf[0..],
                        input_buf.items(),
                        input_cursor,
                        &reference_suggestions,
                        reference_suggestion_selection,
                        reference_suggestion_selection_touched,
                    )
                else
                    computeCommandInlineGhostText(
                        inline_ghost_buf[0..],
                        input_buf.items(),
                        input_cursor,
                        &command_suggestions,
                        slash_suggestion_selection,
                        slash_suggestion_selection_touched,
                    );
                if (prompt_frame_current) {
                    prompt_frame_current = false;
                } else {
                    try renderPromptFrame(
                        writer,
                        &transcript,
                        input_buf.items(),
                        input_cursor,
                        scroll_offset,
                        merged_hint,
                        slash_suggestion_selection,
                        mode,
                        options,
                    );
                }

                const input_len_before = input_buf.items().len;
                const input_cursor_before = input_cursor;
                const input_before_owned = try allocator.dupe(u8, input_buf.items());
                defer allocator.free(input_before_owned);
                const attachment_active = focusedAttachmentToken(input_buf.items(), input_cursor) != null and
                    (!vim_state.enabled or vim_state.mode != .normal);
                const prompt_context: ?keybindings_mod.BindingContext = blk: {
                    if (prompt_surface_selection) |selected_idx| {
                        if (selected_idx < options.prompt_strip_items.len) {
                            break :blk switch (options.prompt_strip_items[selected_idx].kind) {
                                .queue => .PromptQueue,
                                .stash => .PromptStash,
                                .task, .notification, .runtime => .PromptNotifications,
                            };
                        }
                    }
                    if (slash_suggestion_count > 0 or reference_suggestion_count > 0 or starter_suggestions.count > 0) {
                        break :blk .PromptSuggestions;
                    }
                    break :blk null;
                };
                const ev = try readFullScreenInputEventCursorWithBindings(
                    &input_buf,
                    &input_cursor,
                    options.keybindings,
                    prompt_context,
                    attachment_active,
                );
                const rows = terminalRows();
                const max_off = maxScrollOffset(&transcript, rows, terminalCols(), options);

                // Defensive: clamp cursor in case a non-cursor-aware code path
                // (paste, autocomplete, etc.) modified input_buf without updating cursor.
                if (input_cursor > input_buf.items().len) input_cursor = input_buf.items().len;
                syncVimUiState(&options, &vim_state, &input_buf, &input_cursor);

                switch (ev) {
                    .none => {
                        if (vim_state.enabled and vim_state.mode == .normal) {
                            if (extractInsertedText(input_before_owned, input_cursor_before, input_buf.items(), input_cursor)) |inserted| {
                                try replaceInput(&input_buf, input_before_owned);
                                input_cursor = input_cursor_before;
                                if (inserted.len == 1) {
                                    const vim_result = try vim_state.handleNormalKey(&input_buf, &input_cursor, inserted[0]);
                                    if (vim_result.modified) {
                                        try prompt_undo.snapshot(allocator, input_before_owned, input_cursor_before);
                                        prompt_history.resetBrowse(allocator);
                                        clearHint(&input_hint_len);
                                    }
                                    if (vim_result.request_undo) {
                                        if (try prompt_undo.restore(allocator, &input_buf, &input_cursor)) {
                                            prompt_history.resetBrowse(allocator);
                                            setHint(&input_hint_buf, &input_hint_len, "edit undone");
                                        } else {
                                            setHint(&input_hint_buf, &input_hint_len, "nothing to undo");
                                        }
                                    } else if (vim_result.enter_insert) {
                                        try vim_state.enterInsert(input_buf.items(), input_cursor);
                                        setHint(&input_hint_buf, &input_hint_len, "vim insert");
                                    }
                                }
                                syncVimUiState(&options, &vim_state, &input_buf, &input_cursor);
                                resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                                interrupt_count = 0;
                                continue;
                            }
                        }
                        if (extractInsertedText(input_before_owned, input_cursor_before, input_buf.items(), input_cursor)) |inserted| {
                            if (options.shortcuts_panel_enabled and input_before_owned.len == 0 and input_cursor_before == 0 and std.mem.eql(u8, inserted, "?")) {
                                try replaceInput(&input_buf, input_before_owned);
                                input_cursor = input_cursor_before;
                                options.shortcuts_panel_visible = !options.shortcuts_panel_visible;
                                setHint(
                                    &input_hint_buf,
                                    &input_hint_len,
                                    if (options.shortcuts_panel_visible)
                                        "shortcuts open: ctrl+x h palette, ctrl+x s sessions, tab tab density"
                                    else
                                        "shortcuts hidden",
                                );
                                resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                                resetReferenceSuggestionSelection(&reference_suggestion_selection, &reference_suggestion_selection_touched);
                                interrupt_count = 0;
                                continue;
                            }
                            if (options.shortcuts_panel_visible and inserted.len > 0) {
                                options.shortcuts_panel_visible = false;
                            }
                            if (shouldExternalizePastedText(inserted)) {
                                const path = repl_text_paste_mod.storePastedTextToTempFile(allocator, inserted) catch |err| {
                                    var err_buf: [160]u8 = undefined;
                                    const msg = std.fmt.bufPrint(&err_buf, "paste store failed: {s}", .{@errorName(err)}) catch "paste store failed";
                                    setHint(&input_hint_buf, &input_hint_len, msg);
                                    pushPromptNotice(&prompt_notifications, "Paste store failed", @errorName(err), "paste", .plain);
                                    resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                                    continue;
                                };
                                defer allocator.free(path);

                                try replaceInput(&input_buf, input_before_owned);
                                input_cursor = input_cursor_before;
                                try prompt_undo.snapshot(allocator, input_before_owned, input_cursor_before);
                                try insertPromptAttachmentToken(
                                    allocator,
                                    &input_buf,
                                    &input_cursor,
                                    &prompt_attachments,
                                    .pasted_text,
                                    path,
                                );
                                prompt_history.resetBrowse(allocator);
                                var hint_buf: [192]u8 = undefined;
                                const hint = std.fmt.bufPrint(
                                    &hint_buf,
                                    "large paste stored as {s}",
                                    .{std.fs.path.basename(path)},
                                ) catch "large paste stored";
                                setHint(&input_hint_buf, &input_hint_len, hint);
                                pushPromptNotice(&prompt_notifications, "Paste stored", std.fs.path.basename(path), "paste", .plain);
                                resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                                interrupt_count = 0;
                                continue;
                            }
                        }
                        if (input_buf.items().len != input_len_before or input_cursor != input_cursor_before) {
                            try prompt_undo.snapshot(allocator, input_before_owned, input_cursor_before);
                            prompt_history.resetBrowse(allocator);
                            prompt_surface_selection = null;
                        }
                        clearHint(&input_hint_len);
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        interrupt_count = 0;
                        continue;
                    },
                    .escape => {
                        if (prompt_surface_selection != null) {
                            prompt_surface_selection = null;
                            clearHint(&input_hint_len);
                            continue;
                        }
                        if (vim_state.enabled) {
                            if (vim_state.mode == .insert) {
                                try vim_state.enterNormal(input_buf.items(), &input_cursor);
                            } else {
                                vim_state.clearPending();
                            }
                            syncVimUiState(&options, &vim_state, &input_buf, &input_cursor);
                            setHint(&input_hint_buf, &input_hint_len, options.input_mode_label);
                        }
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        resetReferenceSuggestionSelection(&reference_suggestion_selection, &reference_suggestion_selection_touched);
                        continue;
                    },
                    .attachment_previous => {
                        const next_cursor = previousAttachmentCursor(input_buf.items(), input_cursor);
                        input_cursor = next_cursor;
                        syncVimUiState(&options, &vim_state, &input_buf, &input_cursor);
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        resetReferenceSuggestionSelection(&reference_suggestion_selection, &reference_suggestion_selection_touched);
                        continue;
                    },
                    .attachment_next => {
                        const next_cursor = nextAttachmentCursor(input_buf.items(), input_cursor);
                        input_cursor = next_cursor;
                        syncVimUiState(&options, &vim_state, &input_buf, &input_cursor);
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        resetReferenceSuggestionSelection(&reference_suggestion_selection, &reference_suggestion_selection_touched);
                        continue;
                    },
                    .attachment_remove => {
                        if (attachmentRemoveRange(input_buf.items(), input_cursor)) |range| {
                            try prompt_undo.snapshot(allocator, input_buf.items(), input_cursor);
                            try replaceInputRange(&input_buf, &input_cursor, range.start, range.end, "");
                            prompt_history.resetBrowse(allocator);
                            clearHint(&input_hint_len);
                        }
                        syncVimUiState(&options, &vim_state, &input_buf, &input_cursor);
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        resetReferenceSuggestionSelection(&reference_suggestion_selection, &reference_suggestion_selection_touched);
                        continue;
                    },
                    .attachment_exit => {
                        input_cursor = exitAttachmentCursor(input_buf.items(), input_cursor);
                        syncVimUiState(&options, &vim_state, &input_buf, &input_cursor);
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        resetReferenceSuggestionSelection(&reference_suggestion_selection, &reference_suggestion_selection_touched);
                        continue;
                    },
                    .prompt_previous => {
                        if (prompt_surface_selection != null) {
                            prompt_surface_selection = previousPromptStripIndex(options.prompt_strip_items, prompt_surface_selection);
                            if (prompt_surface_selection == null) clearHint(&input_hint_len);
                            continue;
                        }
                        if (reference_suggestion_count > 1) {
                            if (reference_suggestion_selection > 0) reference_suggestion_selection -= 1;
                            reference_suggestion_selection_touched = true;
                            clearHint(&input_hint_len);
                            continue;
                        }
                        if (slash_suggestion_count > 1) {
                            if (slash_suggestion_selection > 0) slash_suggestion_selection -= 1;
                            slash_suggestion_selection_touched = true;
                            clearHint(&input_hint_len);
                            continue;
                        }
                        if (input_buf.items().len == 0 and starter_suggestions.count > 1 and starter_suggestion_selection > 0) {
                            starter_suggestion_selection -= 1;
                            clearHint(&input_hint_len);
                            continue;
                        }
                        if (options.prompt_strip_items.len > 0) {
                            prompt_surface_selection = options.prompt_strip_items.len - 1;
                            continue;
                        }
                        continue;
                    },
                    .prompt_next => {
                        if (prompt_surface_selection != null) {
                            prompt_surface_selection = nextPromptStripIndex(options.prompt_strip_items, prompt_surface_selection);
                            continue;
                        }
                        if (reference_suggestion_count > 1) {
                            if (reference_suggestion_selection + 1 < reference_suggestion_count) reference_suggestion_selection += 1;
                            reference_suggestion_selection_touched = true;
                            clearHint(&input_hint_len);
                            continue;
                        }
                        if (slash_suggestion_count > 1) {
                            if (slash_suggestion_selection + 1 < slash_suggestion_count) slash_suggestion_selection += 1;
                            slash_suggestion_selection_touched = true;
                            clearHint(&input_hint_len);
                            continue;
                        }
                        if (input_buf.items().len == 0 and starter_suggestions.count > 1 and starter_suggestion_selection + 1 < starter_suggestions.count) {
                            starter_suggestion_selection += 1;
                            clearHint(&input_hint_len);
                            continue;
                        }
                        if (options.prompt_strip_items.len > 0) {
                            prompt_surface_selection = 0;
                            continue;
                        }
                        continue;
                    },
                    .prompt_exit => {
                        prompt_surface_selection = null;
                        clearHint(&input_hint_len);
                        continue;
                    },
                    .prompt_dismiss => {
                        if (prompt_surface_selection) |selected_idx| {
                            if (selected_idx < options.prompt_strip_items.len) {
                                switch (options.prompt_strip_items[selected_idx].kind) {
                                    .queue => {
                                        if (queueStripSelection(options.prompt_strip_items, selected_idx, queued_prompt, plan_approved_pending, &queue_snapshot)) |target| {
                                            switch (target) {
                                                .current => {
                                                    if (queued_prompt) |queued| {
                                                        allocator.free(queued);
                                                        queued_prompt = null;
                                                        queued_prompt_restore_to_editor = false;
                                                        setHint(&input_hint_buf, &input_hint_len, "queued item dismissed");
                                                        pushPromptNotice(&prompt_notifications, "Queue dismissed", "removed the active queued prompt", "queue", .plain);
                                                    } else if (plan_approved_pending) {
                                                        plan_approved_pending = false;
                                                        _ = handler.command.?(handler.ctx, allocator, "__plan_approve_off") catch null;
                                                        setHint(&input_hint_buf, &input_hint_len, "approved plan queue cleared");
                                                        pushPromptNotice(&prompt_notifications, "Plan queue cleared", "stopped the pending approved plan", "queue", .plain);
                                                    }
                                                },
                                                .backlog => |backlog_idx| {
                                                    if (queued_prompt_backlog.items.items.len > backlog_idx) {
                                                        const pending = queued_prompt_backlog.items.orderedRemove(backlog_idx);
                                                        allocator.free(pending);
                                                        setHint(&input_hint_buf, &input_hint_len, "queued item dismissed");
                                                        pushPromptNotice(&prompt_notifications, "Queue dismissed", "removed a queued draft from the backlog", "queue", .plain);
                                                    }
                                                },
                                                .overflow => {
                                                    while (queued_prompt_backlog.items.items.len > queue_snapshot.count) {
                                                        const last_index = queued_prompt_backlog.items.items.len - 1;
                                                        const pending = queued_prompt_backlog.items.orderedRemove(last_index);
                                                        allocator.free(pending);
                                                        if (queued_prompt_backlog.items.items.len == 0) break;
                                                        if (queued_prompt_backlog.items.items.len <= queue_snapshot.count) break;
                                                    }
                                                    setHint(&input_hint_buf, &input_hint_len, "queued overflow cleared");
                                                    pushPromptNotice(&prompt_notifications, "Queue overflow cleared", "removed queued items beyond the visible list", "queue", .plain);
                                                },
                                            }
                                        }
                                    },
                                    .stash => {
                                        if (stashed_prompt) |*stash| {
                                            stash.deinit(allocator);
                                            stashed_prompt = null;
                                            setHint(&input_hint_buf, &input_hint_len, "stashed draft dropped");
                                            pushPromptNotice(&prompt_notifications, "Stash dropped", "removed the stashed draft", "stash", .plain);
                                        }
                                    },
                                    .task => {
                                        if (taskStripSelection(options.prompt_strip_items, selected_idx, &task_strip_notifications)) |target| {
                                            switch (target) {
                                                .item => |item_idx| {
                                                    _ = task_strip_notifications.dismissAt(item_idx);
                                                    setHint(&input_hint_buf, &input_hint_len, "task update dismissed");
                                                    pushPromptNotice(&prompt_notifications, "Task notice dismissed", "removed the selected task update", "task", .plain);
                                                },
                                                .overflow => {
                                                    _ = task_strip_notifications.clearOverflow();
                                                    setHint(&input_hint_buf, &input_hint_len, "task overflow cleared");
                                                    pushPromptNotice(&prompt_notifications, "Task overflow cleared", "cleared hidden task update summaries", "task", .plain);
                                                },
                                            }
                                        }
                                    },
                                    .notification, .runtime => {
                                        if (options.prompt_strip_items[selected_idx].kind == .notification) {
                                            if (notificationStripIndex(options.prompt_strip_items, selected_idx, &prompt_notifications)) |notice_idx| {
                                                _ = prompt_notifications.dismissAt(notice_idx);
                                                setHint(&input_hint_buf, &input_hint_len, "notice dismissed");
                                            }
                                        } else {
                                            setHint(&input_hint_buf, &input_hint_len, "runtime banner stays pinned");
                                        }
                                    },
                                }
                            }
                        }
                        prompt_surface_selection = null;
                        continue;
                    },
                    .prompt_open => {
                        if (prompt_surface_selection) |selected_idx| {
                            if (selected_idx < options.prompt_strip_items.len) {
                                switch (options.prompt_strip_items[selected_idx].kind) {
                                    .queue => {
                                        if (queueStripSelection(options.prompt_strip_items, selected_idx, queued_prompt, plan_approved_pending, &queue_snapshot)) |target| {
                                            switch (target) {
                                                .current => {
                                                    if (queued_prompt) |queued| {
                                                        try replaceInputFromPromptText(allocator, &input_buf, &input_cursor, &prompt_attachments, queued);
                                                        allocator.free(queued);
                                                        queued_prompt = null;
                                                        queued_prompt_restore_to_editor = false;
                                                        queued_prompt_restored_draft = true;
                                                        setHint(&input_hint_buf, &input_hint_len, "queued prompt restored to editor");
                                                        pushPromptNotice(&prompt_notifications, "Queue restored", "restored the selected queued prompt into the composer", "queue", .accent);
                                                    } else if (plan_approved_pending) {
                                                        setHint(&input_hint_buf, &input_hint_len, "approved plan will run after the current turn");
                                                    }
                                                },
                                                .backlog => |backlog_idx| {
                                                    if (queued_prompt_backlog.items.items.len > backlog_idx) {
                                                        const pending = queued_prompt_backlog.items.orderedRemove(backlog_idx);
                                                        defer allocator.free(pending);
                                                        try replaceInputFromPromptText(allocator, &input_buf, &input_cursor, &prompt_attachments, pending);
                                                        queued_prompt_restored_draft = true;
                                                        setHint(&input_hint_buf, &input_hint_len, "queued prompt restored to editor");
                                                        pushPromptNotice(&prompt_notifications, "Queue restored", "restored the selected backlog draft into the composer", "queue", .accent);
                                                    }
                                                },
                                                .overflow => {
                                                    setHint(&input_hint_buf, &input_hint_len, "queued overflow summarizes hidden backlog items");
                                                },
                                            }
                                            prompt_history.resetBrowse(allocator);
                                            syncVimUiState(&options, &vim_state, &input_buf, &input_cursor);
                                        }
                                    },
                                    .stash => {
                                        if (stashed_prompt) |stash| {
                                            try prompt_undo.snapshot(allocator, input_buf.items(), input_cursor);
                                            defer {
                                                var tmp = stash;
                                                tmp.deinit(allocator);
                                                stashed_prompt = null;
                                            }
                                            try replaceInput(&input_buf, stash.text);
                                            input_cursor = @min(stash.cursor, input_buf.items().len);
                                            setHint(&input_hint_buf, &input_hint_len, "stashed prompt restored");
                                            pushPromptNotice(&prompt_notifications, "Stash restored", "restored the stashed draft into the composer", "stash", .plain);
                                            prompt_history.resetBrowse(allocator);
                                            syncVimUiState(&options, &vim_state, &input_buf, &input_cursor);
                                        }
                                    },
                                    .task => try runTasksOverlayUi(
                                        allocator,
                                        &input_hint_buf,
                                        &input_hint_len,
                                        &runtime_hint_buf,
                                        &runtime_hint_len,
                                        handler,
                                        options,
                                    ),
                                    .notification => {
                                        if (notificationStripIndex(options.prompt_strip_items, selected_idx, &prompt_notifications)) |notice_idx| {
                                            _ = prompt_notifications.dismissAt(notice_idx);
                                            setHint(&input_hint_buf, &input_hint_len, "notice acknowledged");
                                        }
                                    },
                                    .runtime => setHint(&input_hint_buf, &input_hint_len, "runtime banner summarizes tmux, worktree, and active agent state"),
                                }
                            }
                            prompt_surface_selection = null;
                            resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                            resetReferenceSuggestionSelection(&reference_suggestion_selection, &reference_suggestion_selection_touched);
                            continue;
                        }
                        if (input_buf.items().len == 0 and options.prompt_suggestion.len > 0) {
                            owned_line = try allocator.dupe(u8, options.prompt_suggestion);
                            input_buf.clearRetainingCapacity();
                            input_cursor = 0;
                            prompt_history.resetBrowse(allocator);
                            break;
                        }
                        if (reference_suggestion_count > 0) {
                            try prompt_undo.snapshot(allocator, input_buf.items(), input_cursor);
                            if (try acceptSelectedReferenceSuggestion(&input_buf, &input_cursor, &reference_suggestions, reference_suggestion_selection)) {
                                prompt_history.resetBrowse(allocator);
                                clearHint(&input_hint_len);
                            }
                            resetReferenceSuggestionSelection(&reference_suggestion_selection, &reference_suggestion_selection_touched);
                            resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                            continue;
                        }
                        if (slash_suggestion_count > 0) {
                            if (try acceptSelectedCommandSuggestion(&input_buf, &input_cursor, &command_suggestions, slash_suggestion_selection)) {
                                prompt_history.resetBrowse(allocator);
                                clearHint(&input_hint_len);
                            }
                            resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                            continue;
                        }
                        continue;
                    },
                    .backspace => {
                        if (vim_state.enabled and vim_state.mode == .normal) {
                            _ = try vim_state.handleNormalKey(&input_buf, &input_cursor, 'h');
                            syncVimUiState(&options, &vim_state, &input_buf, &input_cursor);
                            resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                            continue;
                        }
                        prompt_surface_selection = null;
                        if (input_cursor > 0 and input_buf.items().len > 0) {
                            try prompt_undo.snapshot(allocator, input_buf.items(), input_cursor);
                            if (repl_attachments_mod.deleteTokenBeforeCursor(input_buf.items(), input_cursor)) |range| {
                                try replaceInputRange(&input_buf, &input_cursor, range.start, range.end, "");
                            } else {
                                _ = input_buf.orderedRemove(input_cursor - 1);
                                input_cursor -= 1;
                            }
                        }
                        prompt_history.resetBrowse(allocator);
                        clearHint(&input_hint_len);
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .clear_line => {
                        prompt_surface_selection = null;
                        if (input_buf.items().len > 0) {
                            try prompt_undo.snapshot(allocator, input_buf.items(), input_cursor);
                        }
                        input_buf.clearRetainingCapacity();
                        input_cursor = 0;
                        prompt_history.resetBrowse(allocator);
                        clearHint(&input_hint_len);
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        queued_prompt_restored_draft = false;
                        interrupt_count = 0;
                        continue;
                    },
                    .delete_prev_word => {
                        prompt_surface_selection = null;
                        if (input_cursor > 0) {
                            try prompt_undo.snapshot(allocator, input_buf.items(), input_cursor);
                        }
                        if (repl_attachments_mod.deleteTokenBeforeCursor(input_buf.items(), input_cursor)) |range| {
                            try replaceInputRange(&input_buf, &input_cursor, range.start, range.end, "");
                        } else {
                            deletePreviousWordAt(&input_buf, &input_cursor);
                        }
                        prompt_history.resetBrowse(allocator);
                        clearHint(&input_hint_len);
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .autocomplete => {
                        if (vim_state.enabled and vim_state.mode == .normal) {
                            resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                            resetReferenceSuggestionSelection(&reference_suggestion_selection, &reference_suggestion_selection_touched);
                            continue;
                        }
                        if (input_buf.items().len == 0 and options.prompt_suggestion.len > 0) {
                            try prompt_undo.snapshot(allocator, input_buf.items(), input_cursor);
                            try replaceInput(&input_buf, options.prompt_suggestion);
                            input_cursor = input_buf.items().len;
                            prompt_history.resetBrowse(allocator);
                            clearHint(&input_hint_len);
                            continue;
                        }
                        if (reference_suggestion_selection_touched and reference_suggestion_count > 0) {
                            try prompt_undo.snapshot(allocator, input_buf.items(), input_cursor);
                            if (try acceptSelectedReferenceSuggestion(&input_buf, &input_cursor, &reference_suggestions, reference_suggestion_selection)) {
                                prompt_history.resetBrowse(allocator);
                                clearHint(&input_hint_len);
                                resetReferenceSuggestionSelection(&reference_suggestion_selection, &reference_suggestion_selection_touched);
                                resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                                continue;
                            }
                        }
                        if (reference_suggestion_count > 0) {
                            try prompt_undo.snapshot(allocator, input_buf.items(), input_cursor);
                            if (try applyReferenceAutocomplete(
                                &input_buf,
                                &input_cursor,
                                &input_hint_buf,
                                &input_hint_len,
                                &reference_suggestions,
                            )) {
                                prompt_history.resetBrowse(allocator);
                                resetReferenceSuggestionSelection(&reference_suggestion_selection, &reference_suggestion_selection_touched);
                                resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                                continue;
                            }
                        }
                        if (slash_suggestion_selection_touched and slash_suggestion_count > 0) {
                            if (slash_suggestion_selection < command_suggestions.visible().len) {
                                const suggestion = command_suggestions.visible()[slash_suggestion_selection];
                                if (!std.mem.eql(u8, input_buf.items(), suggestion.text)) {
                                    try prompt_undo.snapshot(allocator, input_buf.items(), input_cursor);
                                }
                            }
                            if (try acceptSelectedCommandSuggestion(&input_buf, &input_cursor, &command_suggestions, slash_suggestion_selection)) {
                                prompt_history.resetBrowse(allocator);
                                clearHint(&input_hint_len);
                                resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                                continue;
                            }
                        }
                        if (willCommandAutocompleteMutate(input_buf.items(), &command_suggestions)) {
                            try prompt_undo.snapshot(allocator, input_buf.items(), input_cursor);
                        }
                        try applyCommandAutocomplete(&input_buf, &input_hint_buf, &input_hint_len, &command_suggestions);
                        input_cursor = input_buf.items().len;
                        prompt_history.resetBrowse(allocator);
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        resetReferenceSuggestionSelection(&reference_suggestion_selection, &reference_suggestion_selection_touched);
                        continue;
                    },
                    .insert_newline => {
                        prompt_surface_selection = null;
                        try prompt_undo.snapshot(allocator, input_buf.items(), input_cursor);
                        input_buf.insert(input_cursor, '\n') catch continue;
                        input_cursor += 1;
                        prompt_history.resetBrowse(allocator);
                        clearHint(&input_hint_len);
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .cursor_left => {
                        prompt_surface_selection = null;
                        input_cursor = moveCursorLeftOverAttachment(input_buf.items(), input_cursor);
                        syncVimUiState(&options, &vim_state, &input_buf, &input_cursor);
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .cursor_right => {
                        prompt_surface_selection = null;
                        if (input_buf.items().len == 0 and options.prompt_suggestion.len > 0) {
                            try prompt_undo.snapshot(allocator, input_buf.items(), input_cursor);
                            try replaceInput(&input_buf, options.prompt_suggestion);
                            input_cursor = input_buf.items().len;
                            prompt_history.resetBrowse(allocator);
                            clearHint(&input_hint_len);
                            resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                            resetReferenceSuggestionSelection(&reference_suggestion_selection, &reference_suggestion_selection_touched);
                            continue;
                        }
                        if (input_cursor == input_buf.items().len and options.inline_ghost_text.len > 0) {
                            try prompt_undo.snapshot(allocator, input_buf.items(), input_cursor);
                            try insertInputBytesAt(&input_buf, &input_cursor, options.inline_ghost_text);
                            prompt_history.resetBrowse(allocator);
                            clearHint(&input_hint_len);
                            resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                            resetReferenceSuggestionSelection(&reference_suggestion_selection, &reference_suggestion_selection_touched);
                            continue;
                        }
                        input_cursor = moveCursorRightOverAttachment(input_buf.items(), input_cursor);
                        syncVimUiState(&options, &vim_state, &input_buf, &input_cursor);
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        resetReferenceSuggestionSelection(&reference_suggestion_selection, &reference_suggestion_selection_touched);
                        continue;
                    },
                    .cursor_word_left => {
                        prompt_surface_selection = null;
                        input_cursor = wordLeftFrom(input_buf.items(), input_cursor);
                        syncVimUiState(&options, &vim_state, &input_buf, &input_cursor);
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .cursor_word_right => {
                        prompt_surface_selection = null;
                        input_cursor = wordRightFrom(input_buf.items(), input_cursor);
                        syncVimUiState(&options, &vim_state, &input_buf, &input_cursor);
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .cursor_home => {
                        prompt_surface_selection = null;
                        input_cursor = 0;
                        syncVimUiState(&options, &vim_state, &input_buf, &input_cursor);
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .cursor_end => {
                        prompt_surface_selection = null;
                        input_cursor = input_buf.items().len;
                        syncVimUiState(&options, &vim_state, &input_buf, &input_cursor);
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .toggle_mode => {
                        mode = togglePrimaryMode(mode);
                        var hint_buf: [128]u8 = undefined;
                        const hint = std.fmt.bufPrint(&hint_buf, "mode switched to {s}", .{modeLabel(mode)}) catch "mode switched";
                        setHint(&input_hint_buf, &input_hint_len, hint);
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .toggle_permission_mode => {
                        // P3 (PRD #534): cycle the live permission mode and show
                        // the new short label as a banner, mirroring .toggle_mode.
                        // This event is produced by the Confirmation-context
                        // confirm_cycle_mode binding; the primary cycling path is
                        // Shift+Tab inside the approval overlay itself. In-chat
                        // Shift+Tab still cycles SessionMode (deliberately unchanged).
                        const permission_mode_cycle = @import("../core/permission_mode_cycle.zig");
                        permission_mode = permission_mode_cycle.getNext(permission_mode, options.yolo_mode);
                        // Push the new mode into the runtime so the gate decides
                        // under it AND transitionPermissionMode strips/restores
                        // dangerous rules on plan entry/exit (P3, PRD #534).
                        pushPermissionModeToRuntime(handler, allocator, permission_mode);
                        var hint_buf: [128]u8 = undefined;
                        const hint = std.fmt.bufPrint(&hint_buf, "permission mode: {s}", .{permission_mode_cycle.shortLabel(permission_mode)}) catch "permission mode switched";
                        setHint(&input_hint_buf, &input_hint_len, hint);
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .history_search => {
                        const items = repl_history_mod.buildSearchItems(
                            allocator,
                            options.status_workspace,
                            prompt_history.entries.items,
                            200,
                        ) catch |err| {
                            var err_buf: [128]u8 = undefined;
                            const hint = std.fmt.bufPrint(&err_buf, "history search unavailable: {s}", .{@errorName(err)}) catch "history search unavailable";
                            setHint(&input_hint_buf, &input_hint_len, hint);
                            resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                            continue;
                        };
                        var search_data = HistorySearchData{
                            .allocator = allocator,
                            .items = items,
                        };
                        defer search_data.deinit();

                        if (search_data.items.len == 0) {
                            setHint(&input_hint_buf, &input_hint_len, "history search: no previous prompts");
                            resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                            continue;
                        }

                        setHint(&runtime_hint_buf, &runtime_hint_len, "history search: type to filter, ctrl+r for next");
                        const maybe_selected = try runHistorySearchOverlayLoopWithBindings(search_data, options.bottom_margin_rows, options.keybindings);
                        setHint(&runtime_hint_buf, &runtime_hint_len, "idle: waiting for your input");

                        if (maybe_selected) |selected_idx| {
                            try prompt_undo.snapshot(allocator, input_buf.items(), input_cursor);
                            try replaceInputFromPromptText(
                                allocator,
                                &input_buf,
                                &input_cursor,
                                &prompt_attachments,
                                search_data.items[selected_idx].prompt,
                            );
                            prompt_history.resetBrowse(allocator);
                            clearHint(&input_hint_len);
                        }

                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .external_editor => {
                        try runExternalEditorUi(
                            allocator,
                            writer,
                            &transcript,
                            &input_buf,
                            &input_cursor,
                            &prompt_attachments,
                            &prompt_history,
                            &prompt_undo,
                            &input_hint_buf,
                            &input_hint_len,
                            &runtime_hint_buf,
                            &runtime_hint_len,
                            &scroll_offset,
                            &raw_mode,
                            &fullscreen_active,
                            mode,
                            options,
                        );
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .kill_background_tasks => {
                        const cmd_cb = handler.command orelse {
                            setHint(&input_hint_buf, &input_hint_len, "background task control unavailable");
                            resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                            continue;
                        };

                        const maybe_count_output = cmd_cb(handler.ctx, allocator, "__tasks_running_count") catch |err| {
                            var err_buf: [160]u8 = undefined;
                            const hint = std.fmt.bufPrint(&err_buf, "background task query failed: {s}", .{@errorName(err)}) catch "background task query failed";
                            setHint(&input_hint_buf, &input_hint_len, hint);
                            resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                            continue;
                        };
                        const count_output = maybe_count_output orelse try allocator.dupe(u8, "0");
                        defer allocator.free(count_output);

                        const active_count = std.fmt.parseInt(usize, std.mem.trim(u8, count_output, " \t\r\n"), 10) catch 0;
                        if (active_count == 0) {
                            last_kill_background_tasks_ts = 0;
                            setHint(&input_hint_buf, &input_hint_len, "no managed background tasks running");
                            resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                            continue;
                        }

                        const now = clock.nowMillis();
                        if (last_kill_background_tasks_ts != 0 and now - last_kill_background_tasks_ts <= 2000) {
                            last_kill_background_tasks_ts = 0;
                            const maybe_output = cmd_cb(handler.ctx, allocator, "__tasks_stop_all") catch |err| {
                                var err_buf: [160]u8 = undefined;
                                const hint = std.fmt.bufPrint(&err_buf, "background task stop failed: {s}", .{@errorName(err)}) catch "background task stop failed";
                                setHint(&input_hint_buf, &input_hint_len, hint);
                                resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                                continue;
                            };
                            if (maybe_output) |output| {
                                defer allocator.free(output);
                                setHint(&input_hint_buf, &input_hint_len, output);
                            } else {
                                setHint(&input_hint_buf, &input_hint_len, "background tasks stopped");
                            }
                            resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                            continue;
                        }

                        last_kill_background_tasks_ts = now;
                        setHint(&input_hint_buf, &input_hint_len, "press the shortcut again to stop background tasks");
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .quick_open => {
                        try runQuickOpenUi(
                            allocator,
                            writer,
                            &transcript,
                            &input_buf,
                            &input_cursor,
                            &prompt_history,
                            &prompt_undo,
                            &input_hint_buf,
                            &input_hint_len,
                            &runtime_hint_buf,
                            &runtime_hint_len,
                            &scroll_offset,
                            &raw_mode,
                            &fullscreen_active,
                            mode,
                            options,
                        );
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .global_search => {
                        try runGlobalSearchUi(
                            allocator,
                            writer,
                            &transcript,
                            &input_buf,
                            &input_cursor,
                            &prompt_history,
                            &prompt_undo,
                            &input_hint_buf,
                            &input_hint_len,
                            &runtime_hint_buf,
                            &runtime_hint_len,
                            &scroll_offset,
                            &raw_mode,
                            &fullscreen_active,
                            mode,
                            options,
                        );
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .redraw => {
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .command_palette => {
                        options.shortcuts_panel_visible = false;
                        try runCommandPaletteUi(
                            allocator,
                            writer,
                            &transcript,
                            &input_buf,
                            &input_cursor,
                            &prompt_history,
                            &prompt_undo,
                            &input_hint_buf,
                            &input_hint_len,
                            &runtime_hint_buf,
                            &runtime_hint_len,
                            &scroll_offset,
                            &raw_mode,
                            &fullscreen_active,
                            mode,
                            &options,
                            handler,
                            original_status_approval_mode,
                        );
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .session_switcher => {
                        options.shortcuts_panel_visible = false;
                        try runSessionSwitcherUi(
                            allocator,
                            writer,
                            &transcript,
                            &runtime_hint_buf,
                            &runtime_hint_len,
                            scroll_offset,
                            mode,
                            options,
                            handler,
                        );
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .model_picker => {
                        try runModelPickerUi(
                            allocator,
                            writer,
                            &transcript,
                            &runtime_hint_buf,
                            &runtime_hint_len,
                            scroll_offset,
                            mode,
                            options,
                            handler,
                        );
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .theme_picker => {
                        try runThemePickerUi(
                            allocator,
                            writer,
                            &transcript,
                            &runtime_hint_buf,
                            &runtime_hint_len,
                            scroll_offset,
                            mode,
                            &options,
                            handler,
                        );
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .runtime_panel => {
                        options.shortcuts_panel_visible = false;
                        try runRuntimePanelUi(
                            allocator,
                            writer,
                            &transcript,
                            &input_buf,
                            &input_cursor,
                            &prompt_history,
                            &prompt_undo,
                            &input_hint_buf,
                            &input_hint_len,
                            &runtime_hint_buf,
                            &runtime_hint_len,
                            &scroll_offset,
                            &raw_mode,
                            &fullscreen_active,
                            mode,
                            &options,
                            handler,
                            original_status_approval_mode,
                        );
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .density_toggle => {
                        try runDensityToggleUi(
                            allocator,
                            writer,
                            &transcript,
                            &runtime_hint_buf,
                            &runtime_hint_len,
                            scroll_offset,
                            mode,
                            &options,
                            handler,
                        );
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .fast_toggle => {
                        try runFastToggleUi(
                            allocator,
                            writer,
                            &transcript,
                            &runtime_hint_buf,
                            &runtime_hint_len,
                            scroll_offset,
                            mode,
                            options,
                            handler,
                        );
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .thinking_toggle => {
                        try runThinkingToggleDialogUi(
                            allocator,
                            &input_hint_buf,
                            &input_hint_len,
                            &runtime_hint_buf,
                            &runtime_hint_len,
                            &options,
                        );
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .toggle_transcript => {
                        options.show_transcript = !options.show_transcript;
                        setHint(
                            &input_hint_buf,
                            &input_hint_len,
                            if (options.show_transcript) "transcript restored" else "transcript hidden (Ctrl+O to expand)",
                        );
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .toggle_todos => {
                        try runTodoOverlayUi(
                            allocator,
                            &input_hint_buf,
                            &input_hint_len,
                            &runtime_hint_buf,
                            &runtime_hint_len,
                            handler,
                            options,
                        );
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .transcript_view => {
                        try runTranscriptOverlayUi(
                            allocator,
                            &transcript,
                            &runtime_hint_buf,
                            &runtime_hint_len,
                            options,
                        );
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .toggle_brief => {
                        try runBriefToggleUi(
                            allocator,
                            writer,
                            &transcript,
                            &runtime_hint_buf,
                            &runtime_hint_len,
                            scroll_offset,
                            mode,
                            &options,
                            handler,
                        );
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .message_actions => {
                        try runMessageActionsUi(
                            allocator,
                            writer,
                            &transcript,
                            &input_buf,
                            &input_cursor,
                            &prompt_undo,
                            &input_hint_buf,
                            &input_hint_len,
                            &runtime_hint_buf,
                            &runtime_hint_len,
                            scroll_offset,
                            mode,
                            options,
                        );
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .image_paste => {
                        const maybe_path = repl_image_paste_mod.pasteClipboardImageToTempFile(allocator) catch |err| {
                            var err_buf: [160]u8 = undefined;
                            const msg = std.fmt.bufPrint(&err_buf, "image paste failed: {s}", .{@errorName(err)}) catch "image paste failed";
                            setHint(&input_hint_buf, &input_hint_len, msg);
                            pushPromptNotice(&prompt_notifications, "Image paste failed", @errorName(err), "image", .plain);
                            resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                            continue;
                        };

                        if (maybe_path) |path| {
                            defer allocator.free(path);
                            try insertPromptAttachmentToken(
                                allocator,
                                &input_buf,
                                &input_cursor,
                                &prompt_attachments,
                                .image,
                                path,
                            );

                            var hint_buf: [192]u8 = undefined;
                            const hint = std.fmt.bufPrint(
                                &hint_buf,
                                "image pasted: {s}",
                                .{std.fs.path.basename(path)},
                            ) catch "image pasted";
                            setHint(&input_hint_buf, &input_hint_len, hint);
                            pushPromptNotice(&prompt_notifications, "Image pasted", std.fs.path.basename(path), "image", .plain);
                        } else {
                            setHint(&input_hint_buf, &input_hint_len, "no image found in clipboard");
                            pushPromptNotice(&prompt_notifications, "Clipboard image", "no image found in clipboard", "image", .plain);
                        }

                        syncVimUiState(&options, &vim_state, &input_buf, &input_cursor);
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .stash_toggle => {
                        const trimmed = std.mem.trim(u8, input_buf.items(), " \t\r\n");
                        if (trimmed.len == 0) {
                            if (stashed_prompt) |stash| {
                                try prompt_undo.snapshot(allocator, input_buf.items(), input_cursor);
                                defer {
                                    var tmp = stash;
                                    tmp.deinit(allocator);
                                    stashed_prompt = null;
                                }
                                try replaceInput(&input_buf, stash.text);
                                input_cursor = @min(stash.cursor, input_buf.items().len);
                                clearHint(&runtime_hint_len);
                                setHint(&input_hint_buf, &input_hint_len, "stashed prompt restored");
                                pushPromptNotice(&prompt_notifications, "Stash restored", "restored the stashed draft into the composer", "stash", .plain);
                            } else {
                                setHint(&input_hint_buf, &input_hint_len, "no stashed prompt");
                                pushPromptNotice(&prompt_notifications, "Stash empty", "no stashed draft is available", "stash", .plain);
                            }
                        } else {
                            try prompt_undo.snapshot(allocator, input_buf.items(), input_cursor);
                            if (stashed_prompt) |*stash| stash.deinit(allocator);
                            stashed_prompt = .{
                                .text = try allocator.dupe(u8, input_buf.items()),
                                .cursor = input_cursor,
                            };
                            input_buf.clearRetainingCapacity();
                            input_cursor = 0;
                            queued_prompt_restored_draft = false;
                            prompt_history.resetBrowse(allocator);
                            clearHint(&runtime_hint_len);
                            setHint(&input_hint_buf, &input_hint_len, "prompt stashed (Ctrl+S to restore)");
                            pushPromptNotice(&prompt_notifications, "Prompt stashed", "Ctrl+S restores the stashed draft", "stash", .plain);
                        }
                        syncVimUiState(&options, &vim_state, &input_buf, &input_cursor);
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .undo_edit => {
                        if (try prompt_undo.restore(allocator, &input_buf, &input_cursor)) {
                            prompt_history.resetBrowse(allocator);
                            clearHint(&runtime_hint_len);
                            setHint(&input_hint_buf, &input_hint_len, "edit undone");
                        } else {
                            setHint(&input_hint_buf, &input_hint_len, "nothing to undo");
                        }
                        syncVimUiState(&options, &vim_state, &input_buf, &input_cursor);
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .history_prev => {
                        if (vim_state.enabled and vim_state.mode == .normal) {
                            _ = try vim_state.handleNormalKey(&input_buf, &input_cursor, 'k');
                            syncVimUiState(&options, &vim_state, &input_buf, &input_cursor);
                            resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                            continue;
                        }
                        if (reference_suggestion_count > 1) {
                            if (reference_suggestion_selection > 0) {
                                reference_suggestion_selection -= 1;
                            }
                            reference_suggestion_selection_touched = true;
                            clearHint(&input_hint_len);
                            continue;
                        }
                        if (slash_suggestion_count > 1) {
                            if (slash_suggestion_selection > 0) {
                                slash_suggestion_selection -= 1;
                            }
                            slash_suggestion_selection_touched = true;
                            clearHint(&input_hint_len);
                            continue;
                        }
                        if (input_buf.items().len == 0 and starter_suggestions.count > 1 and starter_suggestion_selection > 0) {
                            starter_suggestion_selection -= 1;
                            clearHint(&input_hint_len);
                            continue;
                        }
                        if (input_buf.items().len == 0 and options.prompt_strip_items.len > 0) {
                            prompt_surface_selection = previousPromptStripIndex(options.prompt_strip_items, prompt_surface_selection);
                            if (prompt_surface_selection != null) continue;
                        }
                        if (movePromptCursorVertical(options.prompt_label, input_buf.items(), &input_cursor, terminalCols(), .up)) {
                            syncVimUiState(&options, &vim_state, &input_buf, &input_cursor);
                            resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                            continue;
                        }
                        if (prompt_history.entries.items.len > 0 and prompt_history.browse_index < prompt_history.entries.items.len) {
                            try prompt_undo.snapshot(allocator, input_buf.items(), input_cursor);
                        }
                        if (try prompt_history.recallPrev(allocator, &input_buf, &input_cursor, &prompt_attachments)) {
                            clearHint(&input_hint_len);
                        }
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .history_next => {
                        if (vim_state.enabled and vim_state.mode == .normal) {
                            _ = try vim_state.handleNormalKey(&input_buf, &input_cursor, 'j');
                            syncVimUiState(&options, &vim_state, &input_buf, &input_cursor);
                            resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                            continue;
                        }
                        if (reference_suggestion_count > 1) {
                            if (reference_suggestion_selection + 1 < reference_suggestion_count) {
                                reference_suggestion_selection += 1;
                            }
                            reference_suggestion_selection_touched = true;
                            clearHint(&input_hint_len);
                            continue;
                        }
                        if (slash_suggestion_count > 1) {
                            if (slash_suggestion_selection + 1 < slash_suggestion_count) {
                                slash_suggestion_selection += 1;
                            }
                            slash_suggestion_selection_touched = true;
                            clearHint(&input_hint_len);
                            continue;
                        }
                        if (input_buf.items().len == 0 and starter_suggestions.count > 1 and starter_suggestion_selection + 1 < starter_suggestions.count) {
                            starter_suggestion_selection += 1;
                            clearHint(&input_hint_len);
                            continue;
                        }
                        if (input_buf.items().len == 0 and options.prompt_strip_items.len > 0) {
                            prompt_surface_selection = nextPromptStripIndex(options.prompt_strip_items, prompt_surface_selection);
                            if (prompt_surface_selection != null) continue;
                        }
                        if (movePromptCursorVertical(options.prompt_label, input_buf.items(), &input_cursor, terminalCols(), .down)) {
                            syncVimUiState(&options, &vim_state, &input_buf, &input_cursor);
                            resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                            continue;
                        }
                        if (prompt_history.browse_index > 0) {
                            try prompt_undo.snapshot(allocator, input_buf.items(), input_cursor);
                        }
                        if (try prompt_history.recallNext(allocator, &input_buf, &input_cursor, &prompt_attachments)) {
                            clearHint(&input_hint_len);
                        }
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        continue;
                    },
                    .scroll_up, .mouse_scroll_up => {
                        if (!options.show_transcript) {
                            setHint(&input_hint_buf, &input_hint_len, "transcript hidden (Ctrl+O to expand)");
                            continue;
                        }
                        const old_offset = scroll_offset;
                        const step = if (ev == .mouse_scroll_up) MOUSE_WHEEL_SCROLL_ROWS else 1;
                        scroll_offset = @min(scroll_offset + step, max_off);
                        if (scroll_offset != old_offset) {
                            try renderPromptFrame(writer, &transcript, input_buf.items(), input_cursor, scroll_offset, merged_hint, slash_suggestion_selection, mode, options);
                            prompt_frame_current = true;
                        }
                        continue;
                    },
                    .scroll_down, .mouse_scroll_down => {
                        if (!options.show_transcript) {
                            setHint(&input_hint_buf, &input_hint_len, "transcript hidden (Ctrl+O to expand)");
                            continue;
                        }
                        const old_offset = scroll_offset;
                        const step = if (ev == .mouse_scroll_down) MOUSE_WHEEL_SCROLL_ROWS else 1;
                        scroll_offset = if (scroll_offset > step) scroll_offset - step else 0;
                        if (scroll_offset != old_offset) {
                            try renderPromptFrame(writer, &transcript, input_buf.items(), input_cursor, scroll_offset, merged_hint, slash_suggestion_selection, mode, options);
                            prompt_frame_current = true;
                        }
                        continue;
                    },
                    .page_up => {
                        if (!options.show_transcript) {
                            setHint(&input_hint_buf, &input_hint_len, "transcript hidden (Ctrl+O to expand)");
                            continue;
                        }
                        const jump = transcriptWindowRows(rows, options);
                        const old_offset = scroll_offset;
                        scroll_offset = @min(scroll_offset + jump, max_off);
                        if (scroll_offset != old_offset) {
                            try renderPromptFrame(writer, &transcript, input_buf.items(), input_cursor, scroll_offset, merged_hint, slash_suggestion_selection, mode, options);
                            prompt_frame_current = true;
                        }
                        continue;
                    },
                    .page_down => {
                        if (!options.show_transcript) {
                            setHint(&input_hint_buf, &input_hint_len, "transcript hidden (Ctrl+O to expand)");
                            continue;
                        }
                        const jump = transcriptWindowRows(rows, options);
                        const old_offset = scroll_offset;
                        scroll_offset = if (scroll_offset > jump) scroll_offset - jump else 0;
                        if (scroll_offset != old_offset) {
                            try renderPromptFrame(writer, &transcript, input_buf.items(), input_cursor, scroll_offset, merged_hint, slash_suggestion_selection, mode, options);
                            prompt_frame_current = true;
                        }
                        continue;
                    },
                    .jump_top => {
                        if (!options.show_transcript) {
                            setHint(&input_hint_buf, &input_hint_len, "transcript hidden (Ctrl+O to expand)");
                            continue;
                        }
                        const old_offset = scroll_offset;
                        scroll_offset = max_off;
                        if (scroll_offset != old_offset) {
                            try renderPromptFrame(writer, &transcript, input_buf.items(), input_cursor, scroll_offset, merged_hint, slash_suggestion_selection, mode, options);
                            prompt_frame_current = true;
                        }
                        continue;
                    },
                    .jump_bottom => {
                        if (!options.show_transcript) {
                            setHint(&input_hint_buf, &input_hint_len, "transcript hidden (Ctrl+O to expand)");
                            continue;
                        }
                        const old_offset = scroll_offset;
                        scroll_offset = 0;
                        if (scroll_offset != old_offset) {
                            try renderPromptFrame(writer, &transcript, input_buf.items(), input_cursor, scroll_offset, merged_hint, slash_suggestion_selection, mode, options);
                            prompt_frame_current = true;
                        }
                        continue;
                    },
                    .bound_command => {
                        const command_name = repl_input_mod.takeLastBoundCommand() orelse {
                            resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                            resetReferenceSuggestionSelection(&reference_suggestion_selection, &reference_suggestion_selection_touched);
                            continue;
                        };
                        clearHint(&input_hint_len);
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        resetReferenceSuggestionSelection(&reference_suggestion_selection, &reference_suggestion_selection_touched);
                        interrupt_count = 0;
                        owned_line = try std.fmt.allocPrint(allocator, "/{s}", .{command_name});
                        break;
                    },
                    .submit => {
                        if (reference_suggestion_selection_touched and reference_suggestion_count > 0) {
                            try prompt_undo.snapshot(allocator, input_buf.items(), input_cursor);
                            if (try acceptSelectedReferenceSuggestion(&input_buf, &input_cursor, &reference_suggestions, reference_suggestion_selection)) {
                                prompt_history.resetBrowse(allocator);
                                clearHint(&input_hint_len);
                                resetReferenceSuggestionSelection(&reference_suggestion_selection, &reference_suggestion_selection_touched);
                                resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                                continue;
                            }
                        }
                        if (slash_suggestion_selection_touched and slash_suggestion_count > 0) {
                            if (slash_suggestion_selection < command_suggestions.visible().len) {
                                const suggestion = command_suggestions.visible()[slash_suggestion_selection];
                                if (!std.mem.eql(u8, input_buf.items(), suggestion.text)) {
                                    try prompt_undo.snapshot(allocator, input_buf.items(), input_cursor);
                                }
                            }
                            if (try acceptSelectedCommandSuggestion(&input_buf, &input_cursor, &command_suggestions, slash_suggestion_selection)) {
                                prompt_history.resetBrowse(allocator);
                                clearHint(&input_hint_len);
                                resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                                continue;
                            }
                        }
                        clearHint(&input_hint_len);
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        resetReferenceSuggestionSelection(&reference_suggestion_selection, &reference_suggestion_selection_touched);
                        interrupt_count = 0;
                        // Backslash+Enter inserts newline (works in all terminals)
                        if (input_buf.items().len > 0 and input_buf.items()[input_buf.items().len - 1] == '\\') {
                            try prompt_undo.snapshot(allocator, input_buf.items(), input_cursor);
                            input_buf.items()[input_buf.items().len - 1] = '\n';
                            continue;
                        }
                        const compiled_prompt = try compilePromptForSubmit(allocator, input_buf.items(), &prompt_attachments);
                        defer allocator.free(compiled_prompt);
                        var line_clean_buf: [16 * 1024]u8 = undefined;
                        const line = sanitizePromptText(compiled_prompt, line_clean_buf[0..]);
                        // Exact-match removals (PRD #534 P9b): intercept removed
                        // commands here, BEFORE any inline handler below, so the
                        // removed_commands list is the true single source of
                        // truth (some commands like /mode are handled inline and
                        // would otherwise bypass the dispatcher's removal guard).
                        if (removed_commands.isRemoved(line)) {
                            input_buf.clearRetainingCapacity();
                            input_cursor = 0;
                            prompt_history.resetBrowse(allocator);
                            setHint(&input_hint_buf, &input_hint_len, "unknown command");
                            continue;
                        }
                        if (std.mem.eql(u8, line, "/transcript")) {
                            input_buf.clearRetainingCapacity();
                            input_cursor = 0;
                            prompt_history.resetBrowse(allocator);
                            try runTranscriptOverlayUi(
                                allocator,
                                &transcript,
                                &runtime_hint_buf,
                                &runtime_hint_len,
                                options,
                            );
                            continue;
                        }
                        if (std.mem.eql(u8, line, "/open") or std.mem.eql(u8, line, "/quick-open")) {
                            input_buf.clearRetainingCapacity();
                            input_cursor = 0;
                            prompt_history.resetBrowse(allocator);
                            try runQuickOpenUi(
                                allocator,
                                writer,
                                &transcript,
                                &input_buf,
                                &input_cursor,
                                &prompt_history,
                                &prompt_undo,
                                &input_hint_buf,
                                &input_hint_len,
                                &runtime_hint_buf,
                                &runtime_hint_len,
                                &scroll_offset,
                                &raw_mode,
                                &fullscreen_active,
                                mode,
                                options,
                            );
                            continue;
                        }
                        if (std.mem.eql(u8, line, "/tasks") or std.mem.eql(u8, line, "/bashes")) {
                            input_buf.clearRetainingCapacity();
                            input_cursor = 0;
                            prompt_history.resetBrowse(allocator);
                            try runTasksOverlayUi(
                                allocator,
                                &input_hint_buf,
                                &input_hint_len,
                                &runtime_hint_buf,
                                &runtime_hint_len,
                                handler,
                                options,
                            );
                            continue;
                        }
                        if (std.mem.eql(u8, line, "/teams")) {
                            input_buf.clearRetainingCapacity();
                            input_cursor = 0;
                            prompt_history.resetBrowse(allocator);
                            try runTeamsOverlayUi(
                                allocator,
                                &input_hint_buf,
                                &input_hint_len,
                                &runtime_hint_buf,
                                &runtime_hint_len,
                                handler,
                                options,
                            );
                            continue;
                        }
                        if (std.mem.eql(u8, line, "/bridge")) {
                            input_buf.clearRetainingCapacity();
                            input_cursor = 0;
                            prompt_history.resetBrowse(allocator);
                            try runBridgeOverlayUi(
                                allocator,
                                &input_hint_buf,
                                &input_hint_len,
                                &runtime_hint_buf,
                                &runtime_hint_len,
                                handler,
                                options,
                            );
                            continue;
                        }
                        if (std.mem.eql(u8, line, "/theme")) {
                            input_buf.clearRetainingCapacity();
                            input_cursor = 0;
                            prompt_history.resetBrowse(allocator);
                            try runThemePickerUi(
                                allocator,
                                writer,
                                &transcript,
                                &runtime_hint_buf,
                                &runtime_hint_len,
                                scroll_offset,
                                mode,
                                &options,
                                handler,
                            );
                            continue;
                        }
                        const accepted_prompt_suggestion = options.prompt_suggestion;
                        input_buf.clearRetainingCapacity();
                        input_cursor = 0;
                        prompt_history.resetBrowse(allocator);
                        if (line.len == 0) {
                            if (accepted_prompt_suggestion.len == 0) continue;
                            owned_line = try allocator.dupe(u8, accepted_prompt_suggestion);
                        } else {
                            owned_line = try allocator.dupe(u8, line);
                        }
                        break;
                    },
                    .interrupt => {
                        clearHint(&input_hint_len);
                        resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                        // If there's input text, first Ctrl+C clears it
                        if (input_buf.items().len > 0) {
                            input_buf.clearRetainingCapacity();
                            input_cursor = 0;
                            prompt_history.resetBrowse(allocator);
                            // Still count toward exit
                        }
                        const now = clock.nowSeconds();
                        // Reset counter if more than 3 seconds since last interrupt
                        if (now - last_interrupt_ts > 3) interrupt_count = 0;
                        interrupt_count += 1;
                        last_interrupt_ts = now;

                        if (interrupt_count >= 3) {
                            if (fullscreen_active) {
                                fullscreen_active = false;
                                raw_mode.disable();
                                try leaveAltScreen(writer);
                            }
                            try writer.writeAll("\nexiting\n");
                            return;
                        } else if (interrupt_count == 2) {
                            setHint(&input_hint_buf, &input_hint_len, "Press Ctrl+C once more to exit");
                            continue;
                        } else {
                            setHint(&input_hint_buf, &input_hint_len, "Press Ctrl+C two more times to exit");
                            continue;
                        }
                    },
                }
            }
        } else {
            try writer.print("{s} ", .{options.prompt_label});
            line_buf.clearRetainingCapacity();
            try std_io.streamUntilDelimiter(line_buf.writer(), '\n', 16 * 1024);

            const raw_line = std.mem.trim(u8, line_buf.items(), " \t\r\n");
            var line_clean_buf: [4096]u8 = undefined;
            const line = sanitizeText(raw_line, line_clean_buf[0..]);
            if (line.len == 0) continue;
            owned_line = try allocator.dupe(u8, line);
        }

        var line = owned_line.?;
        var synthetic_prompt: ?[]u8 = null;
        defer if (synthetic_prompt) |p| allocator.free(p);

        if (!transformed_from_command) {
            submitted_prompt_count += 1;
            try prompt_history.append(allocator, line);
            prompt_history.resetBrowse(allocator);
            repl_history_mod.appendPrompt(allocator, options.status_workspace, line);
            task_strip_notifications.clear();
            queued_prompt_restored_draft = false;
            // Mirror the reference's REPL.tsx per-submit call to
            // maybeMarkProjectOnboardingComplete: once the project's
            // instruction file exists, stamp completion so the first-run
            // nudge stays hidden for good. Best-effort + cached (no-op once
            // already marked), so it is cheap to call on every submit.
            if (options.status_workspace.len > 0) {
                onboarding_mod.maybeMarkComplete(allocator, options.status_workspace);
            }
        }

        if (use_fullscreen) {
            setHint(&runtime_hint_buf, &runtime_hint_len, "running: processing turn");
            scroll_offset = 0;
            // First-input handoff: the welcome banner (cheat-sheet,
            // safety row, starter tip) takes ~25 rows. After the
            // user has committed to a prompt we drop it so the
            // conversation owns the screen.
            if (welcome_active) {
                transcript.clear(allocator);
                welcome_active = false;
            }
            if (transformed_from_command and options.yolo_mode and std.mem.startsWith(u8, line, "Execute the approved implementation plan now.")) {
                synthetic_prompt = try std.fmt.allocPrint(allocator, "{s} [yolo] auto-approved plan -> executing", .{options.prompt_label});
                try transcript.appendLine(allocator, synthetic_prompt.?);
            } else {
                try appendInputLine(allocator, &transcript, options.prompt_label, line);
            }
            try renderFullScreen(writer, &transcript, false, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
        }

        if (std.mem.eql(u8, line, "/exit") or std.mem.eql(u8, line, "/quit")) {
            // ExitFlow.tsx WorktreeExitDialog branch: when the session is
            // running inside a zcode-managed worktree, offer to clean it up
            // before quitting. Only interactive (fullscreen) sessions can show
            // the Select overlay; piped/-p sessions skip it. Run the prompt
            // while raw mode is still active so it can read keys.
            const exit_cwd = options.status_workspace;
            if (use_fullscreen and inManagedWorktree(exit_cwd)) {
                const choices = [_][]const u8{ "Leave worktree as-is", "Remove this worktree", "Cancel" };
                const choice = try repl_overlay_mod.runAskUserOverlayLoop(
                    allocator,
                    "You are inside a zcode worktree. Remove it on exit?",
                    &choices,
                    options.bottom_margin_rows,
                );
                defer allocator.free(choice);
                if (std.mem.eql(u8, choice, "Cancel")) {
                    // Stay in the REPL; abandon the exit.
                    resetSlashSuggestionSelection(&slash_suggestion_selection, &slash_suggestion_selection_touched);
                    continue;
                }
                if (std.mem.eql(u8, choice, "Remove this worktree")) {
                    // Best-effort cleanup. removeWorktree shells out to
                    // `git worktree remove --force` from the parent checkout.
                    // The repo root sits at the parent of `.zcode/worktrees`,
                    // so trim cwd back to the segment before `/.zcode/`.
                    const marker = "/.zcode/worktrees/";
                    const repo_cwd = if (std.mem.indexOf(u8, exit_cwd, marker)) |pos|
                        exit_cwd[0..pos]
                    else
                        exit_cwd;
                    agent_isolation_mod.removeWorktree(allocator, repo_cwd, exit_cwd);
                }
            }
            if (use_fullscreen) {
                fullscreen_active = false;
                raw_mode.disable();
                try leaveAltScreen(writer);
            }
            try writer.print("{s}\n", .{randomGoodbye()});
            return;
        }

        if (std.mem.eql(u8, line, "/help") or std.mem.eql(u8, line, "/help overview")) {
            // commands-06: the bare /help overview also enumerates the user's
            // custom commands and skills so they are discoverable without first
            // running /help commands. status_workspace is the workspace root.
            const help_cwd = if (options.status_workspace.len > 0) options.status_workspace else ".";
            if (use_fullscreen) {
                var help_buf = std_io.StringBuilder.init(allocator);
                defer help_buf.deinit();
                try repl_help_mod.writeOverviewScreen(help_buf.writer(), false);
                _ = try repl_help_mod.writeDynamicCommandsSection(help_buf.writer(), allocator, help_cwd, false);
                try appendTranscriptSectionText(allocator, &transcript, "Help", help_buf.items());
                try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
            } else {
                try repl_help_mod.writeOverviewScreen(writer, shouldUseColor(options));
                _ = try repl_help_mod.writeDynamicCommandsSection(writer, allocator, help_cwd, shouldUseColor(options));
            }
            continue;
        }

        if (std.mem.eql(u8, line, "/help keys")) {
            if (use_fullscreen) {
                const help_plain = try repl_help_mod.buildKeysPlaintext(allocator);
                defer allocator.free(help_plain);
                try appendTranscriptSectionText(allocator, &transcript, "Help Keys", help_plain);
                try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
            } else {
                try repl_help_mod.writeKeysScreen(writer, shouldUseColor(options));
            }
            continue;
        }

        if (std.mem.eql(u8, line, "/help commands")) {
            // commands-06: surface the live registry (built-in + custom + skill)
            // by appending the user's workspace/user custom commands and skills.
            // status_workspace is the workspace root (matches runtime.cwd).
            const help_cwd = if (options.status_workspace.len > 0) options.status_workspace else ".";
            if (use_fullscreen) {
                const help_plain = try repl_help_mod.buildPlaintextWithDynamic(allocator, help_cwd);
                defer allocator.free(help_plain);
                try appendTranscriptSectionText(allocator, &transcript, "Help Commands", help_plain);
                try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
            } else {
                try repl_help_mod.writeHelpScreenWithDynamic(writer, allocator, help_cwd, shouldUseColor(options));
            }
            continue;
        }

        if (std.mem.eql(u8, line, "/!") or std.mem.startsWith(u8, line, "/! ")) {
            const shell_command = std.mem.trim(u8, line[2..], " \t");
            if (shell_command.len == 0) {
                if (use_fullscreen) {
                    try transcript.appendLine(allocator, "usage: /! <interactive shell command>");
                    try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
                } else {
                    try writer.writeAll("usage: /! <interactive shell command>\n");
                }
                continue;
            }

            const summary = try runInteractiveShellCommandUi(
                allocator,
                writer,
                &raw_mode,
                &fullscreen_active,
                handler,
                options,
                shell_command,
            );
            defer allocator.free(summary);

            if (use_fullscreen) {
                try appendTranscriptSectionText(allocator, &transcript, "Interactive Shell", summary);
                try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
            } else {
                try writer.print("{s}\n", .{summary});
            }
            continue;
        }

        // misc-utils-13: bare `!<cmd>` bash input fast-path. Runs the command
        // with the sandbox disabled (full access, like the reference's
        // dangerouslyDisableSandbox), prints the captured output, and folds a
        // synthetic <bash-input>/<bash-stdout>/<bash-stderr> block into the
        // transcript so the next model turn sees it as user-originated context.
        // No model query is started for this input (shouldQuery:false). The
        // `/!` slash form above is unaffected -- this is purely additive.
        if (line.len >= 2 and line[0] == '!' and line[1] != '!') {
            const bash_command = std.mem.trim(u8, line[1..], " \t");
            if (bash_command.len == 0) {
                if (use_fullscreen) {
                    try transcript.appendLine(allocator, "usage: !<bash command>");
                    try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
                } else {
                    try writer.writeAll("usage: !<bash command>\n");
                }
                continue;
            }

            const bash_cwd = blk: {
                if (handler.command) |cmd_cb| {
                    if (try cmd_cb(handler.ctx, allocator, "__shell_cwd")) |value| break :blk value;
                }
                break :blk try allocator.dupe(u8, if (options.status_workspace.len > 0) options.status_workspace else ".");
            };
            defer allocator.free(bash_cwd);

            const capture = try runBashInputCommand(allocator, bash_cwd, bash_command);
            defer capture.deinit(allocator);

            const framing = try bash_input_framing_mod.buildBashInputFraming(
                allocator,
                bash_command,
                capture.stdout,
                capture.stderr,
            );
            defer allocator.free(framing);

            if (use_fullscreen) {
                try appendTranscriptSectionText(allocator, &transcript, "Bash Input", framing);
                try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
            } else {
                if (capture.stdout.len > 0) try writer.writeAll(capture.stdout);
                if (capture.stderr.len > 0) try writer.writeAll(capture.stderr);
                try writer.print("{s}\n", .{framing});
            }
            continue;
        }

        // ui-render-03: leading `#` memory-capture mode. The remainder of the
        // line is appended to the project instruction file (ZCODE.md/CLAUDE.md)
        // and acknowledged with a randomized "Got it." / "Good to know." /
        // "Noted." message. No model query is started -- memory is read back
        // from the instruction file on the next session. Mirrors the `!`
        // bash-input fast-path above (early `continue`, no dispatch).
        if (memory_mod.isMemoryCapture(line)) {
            const mem_line = memory_mod.memoryCaptureLine(line);

            memory_mod.appendUserMemory(allocator, options.status_workspace, mem_line) catch |err| {
                const failmsg = try std.fmt.allocPrint(allocator, "could not save memory: {s}", .{@errorName(err)});
                defer allocator.free(failmsg);
                if (use_fullscreen) {
                    try transcript.appendLine(allocator, failmsg);
                    try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
                } else {
                    try writer.print("{s}\n", .{failmsg});
                }
                continue;
            };

            // Randomized confirmation, picked from one rng byte per runtime
            // conventions (never std.crypto.random.*).
            var pick_byte: [1]u8 = undefined;
            rng_mod.bytes(&pick_byte);
            const confirm = memory_messages_mod.savingMessage(pick_byte[0]);

            if (use_fullscreen) {
                // `#`-badged echo + the dim confirmation, wrapped as a section.
                const body = try std.fmt.allocPrint(allocator, "# {s}\n{s}", .{ mem_line, confirm });
                defer allocator.free(body);
                try appendTranscriptSectionText(allocator, &transcript, "Memory", body);
                try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
            } else {
                if (options.color_enabled) {
                    // `#` badge then the captured line, then a dim confirmation.
                    try writer.print("{s}#{s} {s}\n{s}{s}{s}\n", .{
                        ANSI_DIM, ANSI_RESET, mem_line, ANSI_DIM, confirm, ANSI_RESET,
                    });
                } else {
                    try writer.print("# {s}\n{s}\n", .{ mem_line, confirm });
                }
            }
            continue;
        }

        if (std.mem.eql(u8, line, "/mode")) {
            if (use_fullscreen) {
                var mode_buf: [96]u8 = undefined;
                const msg = std.fmt.bufPrint(&mode_buf, "mode={s}", .{modeLabel(mode)}) catch "mode";
                try transcript.appendLine(allocator, msg);
                try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
            } else {
                try writer.print("mode={s}\n", .{modeLabel(mode)});
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "/mode ")) {
            const requested = std.mem.trim(u8, line["/mode ".len..], " \t");
            if (parseModeName(requested)) |parsed| {
                mode = parsed;
                setHint(&runtime_hint_buf, &runtime_hint_len, "idle: waiting for your input");
                if (use_fullscreen) {
                    var mode_buf: [128]u8 = undefined;
                    const msg = std.fmt.bufPrint(&mode_buf, "mode switched to {s}", .{modeLabel(mode)}) catch "mode switched";
                    try transcript.appendLine(allocator, msg);
                    try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
                } else {
                    try writer.print("mode switched to {s}\n", .{modeLabel(mode)});
                }
            } else {
                if (use_fullscreen) {
                    try transcript.appendLine(allocator, "usage: /mode execution|planning|brainstorm|review");
                    try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
                } else {
                    try writer.writeAll("usage: /mode execution|planning|brainstorm|review\n");
                }
            }
            continue;
        }

        if (std.mem.eql(u8, line, "/model") and use_fullscreen and handler.command != null) {
            try runModelPickerUi(
                allocator,
                writer,
                &transcript,
                &runtime_hint_buf,
                &runtime_hint_len,
                scroll_offset,
                mode,
                options,
                handler,
            );
            continue;
        }

        if ((std.mem.eql(u8, line, "/tasks") or std.mem.eql(u8, line, "/bashes")) and use_fullscreen and handler.command != null) {
            try runTasksOverlayUi(
                allocator,
                &input_hint_buf,
                &input_hint_len,
                &runtime_hint_buf,
                &runtime_hint_len,
                handler,
                options,
            );
            continue;
        }

        if (std.mem.eql(u8, line, "/teams") and use_fullscreen and handler.command != null) {
            try runTeamsOverlayUi(
                allocator,
                &input_hint_buf,
                &input_hint_len,
                &runtime_hint_buf,
                &runtime_hint_len,
                handler,
                options,
            );
            continue;
        }

        if (std.mem.eql(u8, line, "/bridge") and use_fullscreen and handler.command != null) {
            try runBridgeOverlayUi(
                allocator,
                &input_hint_buf,
                &input_hint_len,
                &runtime_hint_buf,
                &runtime_hint_len,
                handler,
                options,
            );
            continue;
        }

        // Bare `/resume` (no id/term), its reference alias `/continue`, and
        // `/sessions` open the interactive session picker instead of printing a
        // usage string. `/resume <arg>` / `/continue <arg>` still flow through
        // the command handler for UUID/fuzzy resolution. commands-sweep-04.
        if (shouldOpenSessionSwitcher(line) and use_fullscreen and handler.command != null) {
            try runSessionSwitcherUi(
                allocator,
                writer,
                &transcript,
                &runtime_hint_buf,
                &runtime_hint_len,
                scroll_offset,
                mode,
                options,
                handler,
            );
            continue;
        }

        if ((std.mem.eql(u8, line, "/rewind") or std.mem.eql(u8, line, "/checkpoint")) and use_fullscreen and handler.command != null) {
            try runRewindSelectorUi(
                allocator,
                writer,
                &transcript,
                &input_buf,
                &input_cursor,
                &prompt_attachments,
                &prompt_history,
                &prompt_undo,
                &input_hint_buf,
                &input_hint_len,
                &runtime_hint_buf,
                &runtime_hint_len,
                scroll_offset,
                mode,
                options,
                handler,
            );
            continue;
        }

        if (std.mem.eql(u8, line, "/feedback") and use_fullscreen) {
            try runFeedbackSurveyUi(
                allocator,
                writer,
                &transcript,
                &runtime_hint_buf,
                &runtime_hint_len,
                scroll_offset,
                mode,
                options,
            );
            continue;
        }

        if ((std.mem.eql(u8, line, "/styles") or std.mem.eql(u8, line, "/style")) and use_fullscreen and handler.command != null) {
            try runStylePickerUi(
                allocator,
                writer,
                &transcript,
                &runtime_hint_buf,
                &runtime_hint_len,
                scroll_offset,
                mode,
                options,
                handler,
            );
            continue;
        }

        if (std.mem.eql(u8, line, "/theme") and use_fullscreen and handler.command != null) {
            try runThemePickerUi(
                allocator,
                writer,
                &transcript,
                &runtime_hint_buf,
                &runtime_hint_len,
                scroll_offset,
                mode,
                &options,
                handler,
            );
            continue;
        }

        if (std.mem.eql(u8, line, "/plan")) {
            if (latest_plan_path) |plan_path| {
                setHint(&runtime_hint_buf, &runtime_hint_len, "awaiting plan decision");
                if (use_fullscreen) {
                    var info_buf: [640]u8 = undefined;
                    const info = std.fmt.bufPrint(&info_buf, "latest plan: {s}", .{plan_path}) catch "latest plan";
                    try transcript.appendLine(allocator, info);
                    try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
                } else {
                    try writer.print("latest plan: {s}\n", .{plan_path});
                }

                const action = if (use_fullscreen)
                    try runPlanReviewOverlayLoop(plan_path, options.bottom_margin_rows)
                else
                    try runInlinePlanReviewPrompt(plan_path);

                switch (action) {
                    .approve => {
                        mode = .execution;
                        synthetic_prompt = buildApprovedPlanExecutionPrompt(allocator, latest_plan_path.?) catch |err| switch (err) {
                            error.PlanFileNotFound => {
                                if (use_fullscreen) {
                                    var note_buf: [512]u8 = undefined;
                                    const note = std.fmt.bufPrint(&note_buf, "approved plan file missing: {s} | regenerate in planning mode", .{latest_plan_path.?}) catch "approved plan file missing";
                                    try transcript.appendLine(allocator, note);
                                    try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
                                } else {
                                    try writer.print("approved plan file missing: {s}\nregenerate in planning mode first\n", .{latest_plan_path.?});
                                }
                                continue;
                            },
                            else => return err,
                        };
                        line = synthetic_prompt.?;
                        transformed_from_command = true;
                        plan_approved_pending = true;
                        _ = handler.command.?(handler.ctx, allocator, "__plan_approve_on") catch null;
                        setHint(&runtime_hint_buf, &runtime_hint_len, "running: executing approved plan");

                        if (use_fullscreen) {
                            var msg_buf: [320]u8 = undefined;
                            const msg = std.fmt.bufPrint(&msg_buf, "approved plan: {s} (mode=execution)", .{latest_plan_path.?}) catch "approved plan";
                            try transcript.appendLine(allocator, msg);
                            try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
                        } else {
                            try writer.print("approved plan: {s} (mode=execution)\n", .{latest_plan_path.?});
                        }
                    },
                    .discuss => {
                        mode = .brainstorm;
                        setHint(&runtime_hint_buf, &runtime_hint_len, "idle: waiting for your input");
                        if (use_fullscreen) {
                            try transcript.appendLine(allocator, "continuing discussion: switched to brainstorm mode");
                            try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
                        } else {
                            try writer.writeAll("continuing discussion: switched to brainstorm mode\n");
                        }
                        continue;
                    },
                    .cancel => {
                        clearOwnedOptional(allocator, &latest_plan_path);
                        setHint(&runtime_hint_buf, &runtime_hint_len, "idle: waiting for your input");
                        if (use_fullscreen) {
                            try transcript.appendLine(allocator, "plan approval canceled. latest saved plan reference cleared.");
                            try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
                        } else {
                            try writer.writeAll("plan approval canceled. latest saved plan reference cleared.\n");
                        }
                        continue;
                    },
                }
            } else {
                setHint(&runtime_hint_buf, &runtime_hint_len, "idle: waiting for your input");
                if (use_fullscreen) {
                    try transcript.appendLine(allocator, "no saved plan. switch to planning mode and ask for a plan first.");
                    try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
                } else {
                    try writer.writeAll("no saved plan. switch to planning mode and ask for a plan first.\n");
                }
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "/plan ")) {
            const action_text = std.mem.trim(u8, line["/plan ".len..], " \t");
            const action = parsePlanAction(action_text) orelse {
                if (use_fullscreen) {
                    try transcript.appendLine(allocator, "usage: /plan approve|discuss|cancel");
                    try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
                } else {
                    try writer.writeAll("usage: /plan approve|discuss|cancel\n");
                }
                continue;
            };

            if (action != .cancel and latest_plan_path == null) {
                setHint(&runtime_hint_buf, &runtime_hint_len, "idle: waiting for your input");
                if (use_fullscreen) {
                    try transcript.appendLine(allocator, "no saved plan. switch to planning mode and ask for a plan first.");
                    try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
                } else {
                    try writer.writeAll("no saved plan. switch to planning mode and ask for a plan first.\n");
                }
                continue;
            }

            switch (action) {
                .approve => {
                    mode = .execution;
                    synthetic_prompt = buildApprovedPlanExecutionPrompt(allocator, latest_plan_path.?) catch |err| switch (err) {
                        error.PlanFileNotFound => {
                            if (use_fullscreen) {
                                var note_buf: [512]u8 = undefined;
                                const note = std.fmt.bufPrint(&note_buf, "approved plan file missing: {s} | regenerate in planning mode", .{latest_plan_path.?}) catch "approved plan file missing";
                                try transcript.appendLine(allocator, note);
                                try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
                            } else {
                                try writer.print("approved plan file missing: {s}\nregenerate in planning mode first\n", .{latest_plan_path.?});
                            }
                            continue;
                        },
                        else => return err,
                    };
                    line = synthetic_prompt.?;
                    transformed_from_command = true;
                    setHint(&runtime_hint_buf, &runtime_hint_len, "running: executing approved plan");

                    if (use_fullscreen) {
                        var msg_buf: [320]u8 = undefined;
                        const msg = std.fmt.bufPrint(&msg_buf, "approved plan: {s} (mode=execution)", .{latest_plan_path.?}) catch "approved plan";
                        try transcript.appendLine(allocator, msg);
                        try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
                    } else {
                        try writer.print("approved plan: {s} (mode=execution)\n", .{latest_plan_path.?});
                    }
                },
                .discuss => {
                    mode = .brainstorm;
                    setHint(&runtime_hint_buf, &runtime_hint_len, "idle: waiting for your input");
                    if (use_fullscreen) {
                        try transcript.appendLine(allocator, "continuing discussion: switched to brainstorm mode");
                        try transcript.appendLine(allocator, "share what to change; when you approve, zcode will generate an updated plan.");
                        try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
                    } else {
                        try writer.writeAll("continuing discussion: switched to brainstorm mode\n");
                        try writer.writeAll("share what to change; when you approve, zcode will generate an updated plan.\n");
                    }
                    continue;
                },
                .cancel => {
                    clearOwnedOptional(allocator, &latest_plan_path);
                    setHint(&runtime_hint_buf, &runtime_hint_len, "idle: waiting for your input");
                    if (use_fullscreen) {
                        try transcript.appendLine(allocator, "plan approval canceled. latest saved plan reference cleared.");
                        try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
                    } else {
                        try writer.writeAll("plan approval canceled. latest saved plan reference cleared.\n");
                    }
                    continue;
                },
            }
        }

        if (std.mem.eql(u8, line, "/approve-plan") or std.mem.eql(u8, line, "/approve")) {
            if (latest_plan_path == null) {
                setHint(&runtime_hint_buf, &runtime_hint_len, "idle: waiting for your input");
                if (use_fullscreen) {
                    try transcript.appendLine(allocator, "no plan available to approve. switch to planning mode and generate one first.");
                    try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
                } else {
                    try writer.writeAll("no plan available to approve. switch to planning mode and generate one first.\n");
                }
                continue;
            }

            mode = .execution;
            synthetic_prompt = buildApprovedPlanExecutionPrompt(allocator, latest_plan_path.?) catch |err| switch (err) {
                error.PlanFileNotFound => {
                    if (use_fullscreen) {
                        var note_buf: [512]u8 = undefined;
                        const note = std.fmt.bufPrint(&note_buf, "approved plan file missing: {s} | regenerate in planning mode", .{latest_plan_path.?}) catch "approved plan file missing";
                        try transcript.appendLine(allocator, note);
                        try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
                    } else {
                        try writer.print("approved plan file missing: {s}\nregenerate in planning mode first\n", .{latest_plan_path.?});
                    }
                    continue;
                },
                else => return err,
            };
            line = synthetic_prompt.?;
            transformed_from_command = true;
            plan_approved_pending = true;
            _ = handler.command.?(handler.ctx, allocator, "__plan_approve_on") catch null;
            setHint(&runtime_hint_buf, &runtime_hint_len, "running: executing approved plan");

            if (use_fullscreen) {
                var msg_buf: [320]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "approved plan: {s} (mode=execution)", .{latest_plan_path.?}) catch "approved plan";
                try transcript.appendLine(allocator, msg);
                try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
            } else {
                try writer.print("approved plan: {s} (mode=execution)\n", .{latest_plan_path.?});
            }
        }

        if (std.mem.eql(u8, line, "/yolo")) {
            if (use_fullscreen) {
                try runAutoModeDialogUi(
                    allocator,
                    &input_hint_buf,
                    &input_hint_len,
                    &runtime_hint_buf,
                    &runtime_hint_len,
                    &options,
                    handler,
                    original_status_approval_mode,
                );
                continue;
            }
            options.yolo_mode = !options.yolo_mode;
            options.status_approval_mode = if (options.yolo_mode) "yolo" else original_status_approval_mode;
            if (handler.command) |cmd_cb| {
                _ = cmd_cb(handler.ctx, allocator, if (options.yolo_mode) "__yolo_on" else "__yolo_off") catch null;
            }
            const yolo_msg = if (options.yolo_mode) "yolo mode enabled: all tools auto-approved" else "yolo mode disabled: normal approval flow";
            if (use_fullscreen) {
                try transcript.appendLine(allocator, yolo_msg);
                try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
            } else {
                try writer.print("{s}\n", .{yolo_msg});
            }
            continue;
        }

        if (std.mem.eql(u8, line, "/reload")) {
            try reloadRuntimeKeybindingsUi(
                allocator,
                &transcript,
                use_fullscreen,
                writer,
                scroll_offset,
                mode,
                &options,
                &runtime_keybindings,
                &prompt_notifications,
                &input_hint_buf,
                &input_hint_len,
            );
            continue;
        }

        if (!transformed_from_command and std.mem.startsWith(u8, line, "/")) {
            if (handler.command) |cmd_cb| {
                const maybe_output = cmd_cb(handler.ctx, allocator, line) catch |err| {
                    if (use_fullscreen) {
                        var err_buf: [128]u8 = undefined;
                        const msg = std.fmt.bufPrint(&err_buf, "error: {s}", .{@errorName(err)}) catch "error";
                        try transcript.appendLine(allocator, msg);
                        try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
                    } else {
                        try writer.print("error: {s}\n", .{@errorName(err)});
                    }
                    continue;
                };
                applyUiCommandSideEffects(&options, line);
                vim_state.setEnabled(options.vim_mode_enabled);
                if (options.vim_mode_enabled) {
                    try vim_state.beginInsertSession(input_buf.items(), input_cursor);
                }
                syncVimUiState(&options, &vim_state, &input_buf, &input_cursor);
                if (maybe_output) |output| {
                    defer allocator.free(output);
                    if (use_fullscreen) {
                        try transcript.appendText(allocator, output);
                        try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
                    } else {
                        try writeStyledText(writer, output, options);
                        if (!std.mem.endsWith(u8, output, "\n")) try writer.writeByte('\n');
                    }
                    continue;
                }
            }

            if (use_fullscreen) {
                var msg_buf: [2200]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "unknown command: {s}", .{line}) catch "unknown command";
                try transcript.appendLine(allocator, msg);
                try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
            } else {
                try writer.print("unknown command: {s}\n", .{line});
            }
            continue;
        }

        // misc-utils-14: ultraplan keyword auto-routing. When the interactive,
        // non-slash input contains a standalone "ultraplan" token, rewrite it
        // to "plan" and route through the existing /ultraplan command handler.
        // Reaching here means the input is non-slash (the slash block above
        // continues for slash input); we additionally require an original
        // user-typed line (not a synthetic transformed-from-command prompt) and
        // an available command callback.
        if (!transformed_from_command and handler.command != null and hasUltraplanKeyword(line)) {
            const rewritten = try replaceUltraplanKeyword(allocator, line);
            defer allocator.free(rewritten);
            const trimmed = std.mem.trim(u8, rewritten, " \t");
            const ultraplan_cmd = try std.fmt.allocPrint(allocator, "/ultraplan {s}", .{trimmed});
            defer allocator.free(ultraplan_cmd);
            const cmd_cb = handler.command.?;
            const maybe_output = cmd_cb(handler.ctx, allocator, ultraplan_cmd) catch |err| {
                if (use_fullscreen) {
                    var err_buf: [128]u8 = undefined;
                    const msg = std.fmt.bufPrint(&err_buf, "error: {s}", .{@errorName(err)}) catch "error";
                    try transcript.appendLine(allocator, msg);
                    try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
                } else {
                    try writer.print("error: {s}\n", .{@errorName(err)});
                }
                continue;
            };
            if (maybe_output) |output| {
                defer allocator.free(output);
                if (use_fullscreen) {
                    try transcript.appendText(allocator, output);
                    try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
                } else {
                    try writeStyledText(writer, output, options);
                    if (!std.mem.endsWith(u8, output, "\n")) try writer.writeByte('\n');
                }
            }
            continue;
        }

        if (mode == .brainstorm and shouldPromoteBrainstormToPlanning(line)) {
            mode = .planning;
            synthetic_prompt = try buildBrainstormPromotionPrompt(allocator, line);
            line = synthetic_prompt.?;
            if (use_fullscreen) {
                try transcript.appendLine(allocator, "brainstorm approved -> switched to planning mode and generating plan");
                try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
            } else {
                try writer.writeAll("brainstorm approved -> switched to planning mode and generating plan\n");
            }
        }

        var spinner_state = SpinnerState{};
        spinner_state.use_fullscreen = use_fullscreen;
        spinner_state.bottom_margin = options.bottom_margin_rows;
        spinner_state.transcript = &transcript;
        spinner_state.transcript_allocator = allocator;

        var live_scroll_scratch = std_io.StringBuilder.init(allocator);
        defer live_scroll_scratch.deinit();

        // Wire the live-scroll redraw hook so arrow/PgUp/PgDn/mouse
        // during thinking triggers an immediate re-render of the
        // transcript window. The context holds pointers into the
        // REPL's local state, so lifetime is bound to this loop
        // iteration -- we clear the pointers on defer just below.
        var live_scroll_ctx = LiveScrollContext{
            .transcript = &transcript,
            .scroll_offset = &scroll_offset,
            .allocator = allocator,
            .options = &options,
            .mode = &mode,
            .hint_buf = &runtime_hint_buf,
            .hint_len = &runtime_hint_len,
            .use_fullscreen = use_fullscreen,
            .write_mutex = &spinner_state.write_mutex,
            .spinner_state = &spinner_state,
            .scratch = &live_scroll_scratch,
        };
        spinner_state.live_redraw_ctx = @ptrCast(&live_scroll_ctx);
        spinner_state.live_redraw_fn = liveScrollRedraw;
        defer {
            spinner_state.live_redraw_ctx = null;
            spinner_state.live_redraw_fn = null;
        }

        spinner_state.reset();
        spinner_state.update(switch (mode) {
            .execution => "capturing user request",
            .planning => "planning request",
            .brainstorm => "brainstorm discussion",
            .review => "reviewing changes",
        });

        // Phase 14.13: pick the longest-since-shown relevant tip for this turn
        // and show it passively on the spinner, recording it as shown exactly
        // once per turn (the spinner thread re-renders frequently, so the
        // record must happen here, not in the render loop). Best-effort: any
        // failure simply skips the tip. Task 14.14: honor the user's
        // spinnerTipsOverride (enable flag, custom tips, exclude-default).
        if (options.enable_spinner) {
            var tip_state = runtime_state_mod.load(allocator);
            defer tip_state.deinit();
            const tip_ctx = tips_mod.TipContext{
                .is_git_repo = if (options.status_workspace.len > 0) isWorkspaceGitRepo(allocator, options.status_workspace) else false,
                .has_instruction_file = if (options.status_workspace.len > 0) !onboarding_mod.needsInstructionFile(options.status_workspace) else false,
                .vim_mode = options.vim_mode_enabled,
            };
            if (tips_mod.getTipToShowOnSpinnerWithConfig(
                allocator,
                options.spinner_tips_enabled,
                options.spinner_tips_exclude_default,
                options.spinner_tips_custom,
                &tip_state,
                tip_ctx,
            )) |tip| {
                spinner_state.setTip(tip.text);
                runtime_state_mod.recordTipShown(allocator, tip.id);
            }
        }

        const reporter = ProgressReporter{
            .ctx = &spinner_state,
            .update = replProgressUpdate,
            .emit_edit_block = replEmitEditBlock,
            .emit_stream_chunk = replEmitStreamChunk,
            .end_stream = replEndStream,
            .emit_tool_output = replEmitToolOutput,
            .emit_diff_block = replEmitDiffBlock,
            .is_cancelled = replIsCancelled,
            .cancel_reason = replCancelReason,
        };

        var spinner = ThinkingSpinner{};
        var approval_ui = ApprovalUiContext{
            .spinner = &spinner,
            .spinner_state = &spinner_state,
            .use_fullscreen = use_fullscreen,
            .spinner_enabled = options.enable_spinner,
            .bottom_margin_rows = options.bottom_margin_rows,
            // P3 (PRD #534): expose the live permission mode to the overlay so
            // Shift+Tab cycles it. bypassPermissions is gated behind the same
            // yolo/dangerous flag that already enables auto-approval, so a normal
            // session cycles default -> acceptEdits -> plan -> default.
            .permission_mode = if (permission_mode_active) &permission_mode else null,
            .bypass_available = options.yolo_mode,
        };
        var ask_user_ui = AskUserUiContext{
            .spinner = &spinner,
            .spinner_state = &spinner_state,
            .use_fullscreen = use_fullscreen,
            .spinner_enabled = options.enable_spinner,
            .bottom_margin_rows = options.bottom_margin_rows,
        };
        if (handler.approval_bridge) |bridge_cb| {
            bridge_cb(handler.ctx, .{
                .ctx = &approval_ui,
                .call = replApprovalPrompt,
            });
        }
        if (handler.ask_user_bridge) |bridge_cb| {
            bridge_cb(handler.ctx, .{
                .ctx = &ask_user_ui,
                .call = replAskUserPrompt,
            });
        }
        defer {
            if (handler.approval_bridge) |bridge_cb| bridge_cb(handler.ctx, null);
            if (handler.ask_user_bridge) |bridge_cb| bridge_cb(handler.ctx, null);
        }

        // Reset cancellation state before each prompt
        spinner_state.cancel_requested.store(false, .release);
        spinner_state.escape_press_count.store(0, .release);

        // terminal-04: show OS taskbar/tab progress for the duration of the
        // turn on capable terminals; cleared at every turn-end below.
        emitTurnProgressStart(writer);
        spinner.start(&spinner_state, use_fullscreen, options.bottom_margin_rows, options.enable_spinner);
        // P3 (PRD #534): the approval overlay (inside handler.call) cycles the
        // REPL's permission_mode in place via the ApprovalUiContext pointer.
        // Snapshot it so that after the turn we can push any in-overlay change
        // into the runtime, making the NEXT decision use the new mode (and
        // running transitionPermissionMode for plan strip/restore). A full
        // mid-overlay re-decide is not reachable here: the runtime is blocked
        // inside handler.call awaiting this overlay, so the pending tool's
        // decision was already computed before the overlay opened.
        const permission_mode_before_turn = permission_mode;
        const output = handler.call(handler.ctx, allocator, line, reporter, mode) catch |err| {
            spinner.stop();
            emitTurnProgressClear(writer);
            if (permission_mode_active and permission_mode != permission_mode_before_turn) {
                pushPermissionModeToRuntime(handler, allocator, permission_mode);
            }
            if (plan_approved_pending) {
                _ = handler.command.?(handler.ctx, allocator, "__plan_approve_off") catch null;
                plan_approved_pending = false;
            }
            setHint(&runtime_hint_buf, &runtime_hint_len, "idle: waiting for your input (last turn failed)");
            if (use_fullscreen) {
                if (options.enable_thinking_summary) {
                    try appendThinkingSummary(allocator, &transcript, &spinner_state);
                }
                var err_buf: [512]u8 = undefined;
                const msg = renderFriendlyError(&err_buf, err, options);
                try appendTranscriptSectionLine(allocator, &transcript, "Error", msg);
                try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
            } else {
                if (options.enable_thinking_summary) {
                    var summary_buf: [640]u8 = undefined;
                    const summary = spinner_state.summaryText(&summary_buf);
                    if (summary.len > 0) try writer.print("thinking summary: {s}\n", .{summary});
                }
                var err_buf: [512]u8 = undefined;
                const msg = renderFriendlyError(&err_buf, err, options);
                try writer.print("{s}\n", .{msg});
            }
            continue;
        };
        spinner.stop();
        emitTurnProgressClear(writer);
        // sessions-12: capture whether the user cancelled this turn mid-flight
        // (Esc Esc sets cancel_requested). On cancel we pop the prompt we just
        // logged to global history and restore it to the input so the user can
        // edit/resubmit it -- mirrors the reference removeLastFromHistory +
        // restore-on-interrupt. Snapshot here, before the per-turn reset that
        // happens at the top of the next loop iteration clears the flag.
        const turn_was_cancelled = spinner_state.cancel_requested.load(.acquire);
        // P3 (PRD #534): if the approval overlay cycled the permission mode
        // mid-turn, push it into the runtime now so the next tool decision uses
        // the new mode and transitionPermissionMode strips/restores rules.
        if (permission_mode_active and permission_mode != permission_mode_before_turn) {
            pushPermissionModeToRuntime(handler, allocator, permission_mode);
        }
        // Apply any scroll offset accumulated via arrow keys during thinking
        const scroll_delta = spinner_state.scroll_offset_delta.swap(0, .acquire);
        if (scroll_delta > 0) {
            scroll_offset +|= @intCast(scroll_delta);
        } else if (scroll_delta < 0) {
            scroll_offset -|= @as(usize, @intCast(@abs(scroll_delta)));
        }
        // Dequeue user input typed during thinking. Two paths:
        //
        //  1. Multi-slot prompt queue (pass 149): each Enter press
        //     during thinking pushed the current buffer into the
        //     queue as its own slot. Drain ONE slot per turn into
        //     queued_prompt so the main loop picks it up as the
        //     next user prompt. Remaining slots stay in the queue.
        //  2. Unsubmitted in-flight characters (user was mid-typing
        //     when the turn ended without pressing Enter): preserve
        //     them by prepopulating input_buf so the next prompt
        //     renders with the text they were typing.
        //
        // The `queued_input_submitted` flag is now just a wake-up
        // hint -- the actual prompts live in prompt_queue.
        _ = spinner_state.queued_input_submitted.swap(false, .acquire);
        // FIFO drain: the first slot becomes the next turn's prompt
        // and AUTO-SUBMITS (the user already pressed Enter to enqueue
        // it -- requiring a second Enter to actually run it defeats
        // the purpose of queueing). Subsequent slots wait in the
        // backlog and the per-iteration pull at the top of the loop
        // submits each one in order. Matches claude-code-main's
        // messageQueueManager.ts. Pre-pass-59 the first slot was
        // restored to the editor instead of auto-submitting, so
        // queued messages effectively never ran.
        while (try spinner_state.dequeuePromptOwned(allocator)) |dequeued| {
            if (queued_prompt == null) {
                queued_prompt = dequeued;
                queued_prompt_restore_to_editor = false;
            } else {
                try queued_prompt_backlog.appendOwned(dequeued);
            }
        }
        {
            spinner_state.mutex.lock(rt.io) catch {};
            defer spinner_state.mutex.unlock(rt.io);
            const qlen = spinner_state.queued_input_len;
            if (qlen > 0 and queued_prompt == null) {
                const qtxt = spinner_state.queued_input[0..qlen];
                input_buf.clearRetainingCapacity();
                input_buf.appendSlice(qtxt) catch {};
                input_cursor = input_buf.items().len;
                spinner_state.queued_input_len = 0;
            }
        }
        if (plan_approved_pending) {
            _ = handler.command.?(handler.ctx, allocator, "__plan_approve_off") catch null;
            plan_approved_pending = false;
        }
        // sessions-12: restore-on-interrupt. When the user cancelled this turn
        // and the prompt was a real user prompt (logged to history above, not a
        // synthetic/command transform), pop it back out of the global history
        // and drop it into the input so it can be edited/resubmitted. Guard on
        // an empty input with no queued prompt so we never clobber text the
        // user typed during thinking or a queued/stashed restore.
        if (turn_was_cancelled and !transformed_from_command and queued_prompt == null and queued_prompt_backlog.count() == 0 and input_buf.items().len == 0) {
            if (repl_history_mod.removeLastForWorkspace(allocator, options.status_workspace)) |restored| {
                defer allocator.free(restored);
                if (options.attachment_store) |attachments| {
                    replaceInputFromPromptText(allocator, &input_buf, &input_cursor, @constCast(attachments), restored) catch {
                        replaceInput(&input_buf, restored) catch {};
                        input_cursor = input_buf.items().len;
                    };
                } else {
                    replaceInput(&input_buf, restored) catch {};
                    input_cursor = input_buf.items().len;
                }
                setHint(&input_hint_buf, &input_hint_len, "interrupted prompt restored - edit or resubmit");
                syncVimUiState(&options, &vim_state, &input_buf, &input_cursor);
            }
        }
        if (!transformed_from_command and stashed_prompt != null and queued_prompt == null and queued_prompt_backlog.count() == 0 and input_buf.items().len == 0) {
            var stash = stashed_prompt.?;
            defer stash.deinit(allocator);
            try replaceInput(&input_buf, stash.text);
            input_cursor = @min(stash.cursor, input_buf.items().len);
            stashed_prompt = null;
            setHint(&input_hint_buf, &input_hint_len, "stashed prompt restored after submit");
            pushPromptNotice(&prompt_notifications, "Stash auto-restored", "restored the stashed draft after the previous submit", "stash", .plain);
            syncVimUiState(&options, &vim_state, &input_buf, &input_cursor);
        }
        if (handler.command) |cmd_cb| {
            const maybe_requested_mode = cmd_cb(handler.ctx, allocator, "__consume_requested_mode") catch null;
            if (maybe_requested_mode) |requested_mode| {
                defer allocator.free(requested_mode);
                if (parseModeName(requested_mode)) |parsed| {
                    mode = parsed;
                }
            }
        }
        defer allocator.free(output);

        if (use_fullscreen) {
            if (options.enable_thinking_summary) {
                try appendThinkingSummary(allocator, &transcript, &spinner_state);
                // ui-render-04: persisted extended-thinking indicator.
                // Collapsed in normal view, full dim block in transcript
                // view. Gated behind the same thinking-summary toggle.
                appendThinkingIndicator(allocator, &transcript, handler, options.show_transcript);
            }
            try appendAssistantTranscriptOutput(allocator, &transcript, output);
            setHint(&runtime_hint_buf, &runtime_hint_len, "idle: waiting for your input");
            try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
        } else {
            if (options.enable_thinking_summary) {
                var summary_buf: [640]u8 = undefined;
                const summary = spinner_state.summaryText(&summary_buf);
                if (summary.len > 0) try writer.print("thinking summary: {s}\n", .{summary});
            }
            if (!use_fullscreen) {
                try writer.writeAll("\x1b[2m" ++ figures.BOX_H ++ figures.BOX_H ++ " " ++ figures.BLACK_DIAMOND ++ " Assistant " ++ figures.BOX_H ++ figures.BOX_H ++ "\x1b[0m\n");
            }
            try writeStyledText(writer, output, options);
            if (!std.mem.endsWith(u8, output, "\n")) {
                try writer.writeByte('\n');
            }
        }

        if (mode == .brainstorm and shouldAutoPromoteBrainstormOutputToPlanning(output)) {
            mode = .planning;
            if (use_fullscreen) {
                try transcript.appendLine(allocator, "brainstorm converged -> switched to planning mode and generating approval plan");
            } else {
                try writer.writeAll("brainstorm converged -> switched to planning mode and generating approval plan\n");
            }
        }

        if (mode == .planning) {
            // Skip plan review when the last turn produced no real
            // output: either the model errored out (ConnectionTimeout,
            // rate-limit, etc), returned an empty body, or the agent
            // loop replaced the response with one of its synthetic
            // stall messages. Without this guard zcode wrote the
            // stall text into a plan file and opened the approval
            // overlay on it -- the screenshot bug from session
            // 0.11.21 was exactly this path firing on a "stuck
            // repeating" stall in plan mode.
            const plan_trimmed = std.mem.trim(u8, output, " \t\r\n");
            const plan_is_error = std.mem.startsWith(u8, plan_trimmed, "Model error:");
            const plan_is_empty = plan_trimmed.len == 0;
            const plan_is_stall = isAgentStallMessage(plan_trimmed);
            if (plan_is_error or plan_is_empty or plan_is_stall) {
                if (use_fullscreen) {
                    try transcript.appendLine(
                        allocator,
                        "plan not saved: last turn did not produce a plan (model error, empty response, or agent stall). try again or switch models.",
                    );
                } else {
                    try writer.writeAll("plan not saved: last turn did not produce a plan (model error, empty response, or agent stall). try again or switch models.\n");
                }
                continue;
            }
            const plan_md = try normalizePlanMarkdown(allocator, output);
            defer allocator.free(plan_md);

            const plan_path = try savePlanFile(allocator, plan_md);
            defer allocator.free(plan_path);
            try setOwnedOptional(allocator, &latest_plan_path, plan_path);

            if (use_fullscreen) {
                var msg_buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "plan saved: {s}", .{plan_path}) catch "plan saved";
                try transcript.appendLine(allocator, msg);
            } else {
                if (!options.yolo_mode) {
                    try writer.print("plan saved: {s}\n", .{plan_path});
                }
            }

            {
                const action = if (use_fullscreen)
                    try runPlanReviewOverlayLoop(plan_path, options.bottom_margin_rows)
                else
                    try runInlinePlanReviewPrompt(plan_path);

                switch (action) {
                    .approve => {
                        mode = .execution;
                        const generated = buildApprovedPlanExecutionPrompt(allocator, latest_plan_path.?) catch |err| switch (err) {
                            error.PlanFileNotFound => {
                                setHint(&runtime_hint_buf, &runtime_hint_len, "idle: waiting for your input");
                                if (use_fullscreen) {
                                    var note_buf: [512]u8 = undefined;
                                    const note = std.fmt.bufPrint(&note_buf, "approved plan file missing: {s} | regenerate in planning mode", .{latest_plan_path.?}) catch "approved plan file missing";
                                    try transcript.appendLine(allocator, note);
                                    try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
                                } else {
                                    try writer.print("approved plan file missing: {s}\nregenerate in planning mode first\n", .{latest_plan_path.?});
                                }
                                continue;
                            },
                            else => return err,
                        };
                        if (queued_prompt) |existing| allocator.free(existing);
                        queued_prompt = generated;
                        queued_prompt_restore_to_editor = false;
                        plan_approved_pending = true;
                        setHint(&runtime_hint_buf, &runtime_hint_len, "running: executing approved plan");

                        if (use_fullscreen) {
                            try transcript.appendLine(allocator, "plan approved -> executing now");
                            try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
                        } else {
                            try writer.writeAll("plan approved -> executing now\n");
                        }
                        continue;
                    },
                    .discuss => {
                        mode = .brainstorm;
                        setHint(&runtime_hint_buf, &runtime_hint_len, "idle: waiting for your input");
                        if (use_fullscreen) {
                            try transcript.appendLine(allocator, "plan left unapproved -> switched to brainstorm mode");
                            try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
                        } else {
                            try writer.writeAll("plan left unapproved -> switched to brainstorm mode\n");
                        }
                        continue;
                    },
                    .cancel => {
                        clearOwnedOptional(allocator, &latest_plan_path);
                        setHint(&runtime_hint_buf, &runtime_hint_len, "idle: waiting for your input");
                        if (use_fullscreen) {
                            try transcript.appendLine(allocator, "plan approval canceled. latest saved plan reference cleared.");
                            try renderFullScreen(writer, &transcript, true, "", scroll_offset, runtime_hint_buf[0..runtime_hint_len], mode, options);
                        } else {
                            try writer.writeAll("plan approval canceled. latest saved plan reference cleared.\n");
                        }
                        continue;
                    },
                }
            }
        }
    }
}

const testing = std.testing;

test "autoModeConfigWrites make_default persists opt-in and default mode" {
    // ui-dialogs-03: the accept-default branch must both mark the opt-in as seen
    // and persist default_mode=auto, mirroring the reference accept-default.
    const w = autoModeConfigWrites(.make_default, false);
    try testing.expect(w.persist_opt_in_seen);
    try testing.expect(w.persist_default_auto);
    try testing.expect(w.enable_session);

    // When already opted in, the opt-in flag is not re-persisted but the default
    // mode still is (the user is explicitly making it their default now).
    const w2 = autoModeConfigWrites(.make_default, true);
    try testing.expect(!w2.persist_opt_in_seen);
    try testing.expect(w2.persist_default_auto);
    try testing.expect(w2.enable_session);
}

test "autoModeConfigWrites enable persists opt-in but not default mode" {
    // ui-dialogs-03: plain enable mirrors the reference `accept`: it records the
    // opt-in but must NOT change the persisted default mode.
    const w = autoModeConfigWrites(.enable, false);
    try testing.expect(w.persist_opt_in_seen);
    try testing.expect(!w.persist_default_auto);
    try testing.expect(w.enable_session);

    const w2 = autoModeConfigWrites(.enable, true);
    try testing.expect(!w2.persist_opt_in_seen);
    try testing.expect(!w2.persist_default_auto);
    try testing.expect(w2.enable_session);
}

test "autoModeConfigWrites disable and keep persist nothing" {
    // ui-dialogs-03: the decline / disable branches write no config and leave the
    // session in non-auto mode.
    inline for (.{ AutoModeChoice.disable, AutoModeChoice.keep }) |choice| {
        const w = autoModeConfigWrites(choice, false);
        try testing.expect(!w.persist_opt_in_seen);
        try testing.expect(!w.persist_default_auto);
        try testing.expect(!w.enable_session);
    }
}

test "auto mode dialog copy carries the security docs link" {
    // ui-dialogs-03: the dialog body must surface the reviewed description and
    // the security docs link (manual-check parity), and must contain no em/en
    // dashes per the project style rule.
    const body = AUTO_MODE_DESCRIPTION ++ " " ++ AUTO_MODE_DOCS_LINE;
    try testing.expect(std.mem.indexOf(u8, body, "https://code.claude.com/docs/en/security") != null);
    try testing.expect(std.mem.indexOf(u8, body, "auto-approves") != null);
    // No long dashes (em U+2014 / en U+2013) anywhere in the copy.
    try testing.expect(std.mem.indexOf(u8, body, "\xe2\x80\x94") == null);
    try testing.expect(std.mem.indexOf(u8, body, "\xe2\x80\x93") == null);
}

test "shouldOpenSessionSwitcher only fires on the bare entrypoints" {
    // Bare forms open the interactive picker.
    try testing.expect(shouldOpenSessionSwitcher("/resume"));
    try testing.expect(shouldOpenSessionSwitcher("/continue"));
    try testing.expect(shouldOpenSessionSwitcher("/sessions"));
    // An argument means direct reload via the command handler, not the picker.
    try testing.expect(!shouldOpenSessionSwitcher("/resume abc123"));
    try testing.expect(!shouldOpenSessionSwitcher("/continue abc123"));
    try testing.expect(!shouldOpenSessionSwitcher("/resume list"));
    // Unrelated input never opens the picker.
    try testing.expect(!shouldOpenSessionSwitcher("/model"));
    try testing.expect(!shouldOpenSessionSwitcher("hello"));
}

test "hasUltraplanKeyword detects standalone token and rewrites to plan" {
    try testing.expect(hasUltraplanKeyword("ultraplan build a dashboard"));
    const rewritten = try replaceUltraplanKeyword(testing.allocator, "ultraplan build a dashboard");
    defer testing.allocator.free(rewritten);
    try testing.expectEqualStrings("plan build a dashboard", rewritten);
}

test "ultraplan keyword is case-insensitive and preserves suffix casing" {
    try testing.expect(hasUltraplanKeyword("Please UltraPlan this feature"));
    const rewritten = try replaceUltraplanKeyword(testing.allocator, "Please UltraPlan this feature");
    defer testing.allocator.free(rewritten);
    try testing.expectEqualStrings("Please Plan this feature", rewritten);
}

test "ultraplan keyword does not auto-route slash input" {
    try testing.expect(!hasUltraplanKeyword("/ask ultraplan"));
    // No trigger -> replaceUltraplanKeyword returns the original text unchanged.
    const rewritten = try replaceUltraplanKeyword(testing.allocator, "/ask ultraplan");
    defer testing.allocator.free(rewritten);
    try testing.expectEqualStrings("/ask ultraplan", rewritten);
}

test "ultraplan keyword skips quoted and path-like occurrences" {
    // Inside backticks.
    try testing.expect(!hasUltraplanKeyword("run `ultraplan` here"));
    // Inside double quotes.
    try testing.expect(!hasUltraplanKeyword("the word \"ultraplan\" is fine"));
    // Inside square brackets (paste-placeholder context).
    try testing.expect(!hasUltraplanKeyword("[ultraplan] tag"));
    // Path-like contexts.
    try testing.expect(!hasUltraplanKeyword("src/ultraplan/foo.ts"));
    try testing.expect(!hasUltraplanKeyword("ultraplan.ts is a file"));
    try testing.expect(!hasUltraplanKeyword("--ultraplan-mode"));
    // A question about the feature should not trigger.
    try testing.expect(!hasUltraplanKeyword("ultraplan?"));
    // Not a word boundary.
    try testing.expect(!hasUltraplanKeyword("ultraplanner mode"));
}

test "ultraplan keyword triggers at sentence end and mid-sentence" {
    try testing.expect(hasUltraplanKeyword("let's ultraplan."));
    const rewritten = try replaceUltraplanKeyword(testing.allocator, "let's ultraplan.");
    defer testing.allocator.free(rewritten);
    try testing.expectEqualStrings("let's plan.", rewritten);
}

test "deriveThinkingTopicTitle maps common progress text" {
    var out: [96]u8 = undefined;
    const topic = deriveThinkingTopicTitle("calling model deepseek/deepseek-chat", &out);
    try testing.expectEqualStrings("Calling Model", topic);
}

test "togglePrimaryMode cycles all three modes" {
    try testing.expect(togglePrimaryMode(.execution) == .planning);
    try testing.expect(togglePrimaryMode(.planning) == .brainstorm);
    try testing.expect(togglePrimaryMode(.brainstorm) == .execution);
    try testing.expect(togglePrimaryMode(.review) == .execution);
}

test "transcriptWindowRows accounts for bottom margin" {
    const options = Options{
        .bottom_margin_rows = 2,
    };
    try testing.expectEqual(@as(usize, 20), transcriptWindowRows(30, options));
}

test "composeStatusHint merges runtime and input hints" {
    var out: [320]u8 = undefined;
    const merged = composeStatusHint(&out, "idle: waiting for your input", "tab: /help");
    try testing.expectEqualStrings("idle: waiting for your input | tab: /help", merged);
    const runtime_only = composeStatusHint(&out, "running: processing turn", "");
    try testing.expectEqualStrings("running: processing turn", runtime_only);
}

test "defaultInputHint surfaces palette and shortcuts on an empty prompt" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("?: shortcuts, ctrl+x h: palette, Tab Tab: density", defaultInputHint(&buf, "", .{}));
    try testing.expectEqualStrings("tab: /help", defaultInputHint(&buf, "typed", .{}));
}

test "prompt notification queue keeps newest distinct notices" {
    var notices = UiNotificationQueue{};
    notices.push("First", "alpha", "note", .plain);
    notices.push("Second", "beta", "note", .plain);
    notices.push("Third", "gamma", "note", .plain);
    notices.push("Fourth", "delta", "note", .plain);
    notices.push("Fifth", "epsilon", "note", .plain);

    try testing.expectEqual(@as(usize, MAX_UI_NOTIFICATIONS), notices.count);
    try testing.expectEqualStrings("Second", notices.title_items[0]);
    try testing.expectEqualStrings("Fifth", notices.title_items[3]);

    notices.push("Third", "gamma", "note", .plain);
    try testing.expectEqual(@as(usize, MAX_UI_NOTIFICATIONS), notices.count);
    try testing.expectEqualStrings("Third", notices.title_items[3]);
}

test "buildPromptStripItems includes notices and runtime banner" {
    var strip = PromptStripItems{};
    const queue_snapshot = QueuePreviewSnapshot{};
    const task_notifications = TaskNotificationStripState{};
    var notices = UiNotificationQueue{};
    notices.push("Image pasted", "diagram.png", "image", .plain);
    notices.push("Keybindings reloaded", "prompt-side bindings updated", "keys", .accent);

    var runtime_banner = RuntimeStripBanner{};
    buildRuntimeStripBanner(&runtime_banner, "tmux:main", "worktree:feature/ui", "agent:planner");

    buildPromptStripItems(
        &strip,
        null,
        false,
        false,
        &queue_snapshot,
        &task_notifications,
        null,
        &notices,
        0,
        &runtime_banner,
    );

    try testing.expectEqual(@as(usize, 3), strip.count);
    try testing.expectEqual(repl_footer_mod.StripKind.notification, strip.items[0].kind);
    try testing.expectEqualStrings("Image pasted", strip.items[0].title);
    try testing.expectEqual(repl_footer_mod.StripKind.notification, strip.items[1].kind);
    try testing.expectEqual(repl_footer_mod.StripKind.runtime, strip.items[2].kind);
    try testing.expectEqualStrings("Agent session", strip.items[2].title);
    try testing.expect(std.mem.indexOf(u8, strip.items[2].body, "agent:planner") != null);
    try testing.expect(std.mem.indexOf(u8, strip.items[2].body, "tmux:main") != null);
}

test "buildPromptStripItems shows a sandbox-violation hint with the count" {
    var strip = PromptStripItems{};
    const queue_snapshot = QueuePreviewSnapshot{};
    const task_notifications = TaskNotificationStripState{};
    const notices = UiNotificationQueue{};
    const runtime_banner = RuntimeStripBanner{};

    buildPromptStripItems(
        &strip,
        null,
        false,
        false,
        &queue_snapshot,
        &task_notifications,
        null,
        &notices,
        3,
        &runtime_banner,
    );

    try testing.expectEqual(@as(usize, 1), strip.count);
    try testing.expectEqual(repl_footer_mod.StripKind.notification, strip.items[0].kind);
    try testing.expect(std.mem.indexOf(u8, strip.items[0].title, "3 sandbox violations") != null);
    try testing.expect(std.mem.indexOf(u8, strip.items[0].body, "ctrl+o for details") != null);
}

test "buildPromptStripItems omits the sandbox hint when the count is zero" {
    var strip = PromptStripItems{};
    const queue_snapshot = QueuePreviewSnapshot{};
    const task_notifications = TaskNotificationStripState{};
    const notices = UiNotificationQueue{};
    const runtime_banner = RuntimeStripBanner{};

    buildPromptStripItems(
        &strip,
        null,
        false,
        false,
        &queue_snapshot,
        &task_notifications,
        null,
        &notices,
        0,
        &runtime_banner,
    );

    try testing.expectEqual(@as(usize, 0), strip.count);
}

test "buildPromptStripItems uses singular noun for one sandbox violation" {
    var strip = PromptStripItems{};
    const queue_snapshot = QueuePreviewSnapshot{};
    const task_notifications = TaskNotificationStripState{};
    const notices = UiNotificationQueue{};
    const runtime_banner = RuntimeStripBanner{};

    buildPromptStripItems(
        &strip,
        null,
        false,
        false,
        &queue_snapshot,
        &task_notifications,
        null,
        &notices,
        1,
        &runtime_banner,
    );

    try testing.expectEqual(@as(usize, 1), strip.count);
    try testing.expect(std.mem.indexOf(u8, strip.items[0].title, "1 sandbox violation") != null);
    // Must not pluralize when count == 1.
    try testing.expect(std.mem.indexOf(u8, strip.items[0].title, "violations") == null);
}

test "prompt history recalls previous prompts and restores the draft" {
    var history = PromptHistoryState.init(testing.allocator);
    defer history.deinit(testing.allocator);
    var attachments = repl_attachments_mod.Store.init(testing.allocator);
    defer attachments.deinit(testing.allocator);

    try history.append(testing.allocator, "first prompt");
    try history.append(testing.allocator, "second prompt");

    var input_buf = std_io.StringBuilder.init(testing.allocator);
    defer input_buf.deinit();
    try replaceInput(&input_buf, "draft text");
    var cursor: usize = input_buf.items().len;

    try testing.expect(try history.recallPrev(testing.allocator, &input_buf, &cursor, &attachments));
    try testing.expectEqualStrings("second prompt", input_buf.items());
    try testing.expectEqual(input_buf.items().len, cursor);

    try testing.expect(try history.recallPrev(testing.allocator, &input_buf, &cursor, &attachments));
    try testing.expectEqualStrings("first prompt", input_buf.items());

    try testing.expect(!(try history.recallPrev(testing.allocator, &input_buf, &cursor, &attachments)));
    try testing.expectEqualStrings("first prompt", input_buf.items());

    try testing.expect(try history.recallNext(testing.allocator, &input_buf, &cursor, &attachments));
    try testing.expectEqualStrings("second prompt", input_buf.items());

    try testing.expect(try history.recallNext(testing.allocator, &input_buf, &cursor, &attachments));
    try testing.expectEqualStrings("draft text", input_buf.items());
    try testing.expectEqual(@as(usize, 0), history.browse_index);
    try testing.expect(history.draft == null);
}

test "prompt history recall materializes pasted attachment mentions into structured tokens" {
    var history = PromptHistoryState.init(testing.allocator);
    defer history.deinit(testing.allocator);
    var attachments = repl_attachments_mod.Store.init(testing.allocator);
    defer attachments.deinit(testing.allocator);

    try history.append(testing.allocator, "@\"/tmp/zcode-pasted-images/clip 1.png\"");

    var input_buf = std_io.StringBuilder.init(testing.allocator);
    defer input_buf.deinit();
    var cursor: usize = 0;

    try testing.expect(try history.recallPrev(testing.allocator, &input_buf, &cursor, &attachments));
    try testing.expectEqualStrings("<@image:1>", input_buf.items());
    try testing.expectEqualStrings("/tmp/zcode-pasted-images/clip 1.png", attachments.get(1).?.path);
}

test "movePromptCursorVertical prefers in-prompt vertical movement before history edges" {
    const input = "abc\ndef\nghi";
    var cursor: usize = 5;

    try testing.expect(movePromptCursorVertical(">", input, &cursor, 20, .up));
    try testing.expectEqual(@as(usize, 1), cursor);

    try testing.expect(movePromptCursorVertical(">", input, &cursor, 20, .down));
    try testing.expectEqual(@as(usize, 5), cursor);

    try testing.expect(movePromptCursorVertical(">", input, &cursor, 20, .down));
    try testing.expectEqual(@as(usize, 9), cursor);

    try testing.expect(movePromptCursorVertical(">", input, &cursor, 20, .up));
    try testing.expectEqual(@as(usize, 5), cursor);
}

test "movePromptCursorVertical handles wrapped prompt rows" {
    const input = "abcdef";

    var middle_cursor: usize = 4;
    try testing.expect(movePromptCursorVertical(">", input, &middle_cursor, 8, .up));
    try testing.expectEqual(@as(usize, 1), middle_cursor);

    try testing.expect(movePromptCursorVertical(">", input, &middle_cursor, 8, .down));
    try testing.expectEqual(@as(usize, 3), middle_cursor);

    var top_cursor: usize = 1;
    try testing.expect(!movePromptCursorVertical(">", input, &top_cursor, 8, .up));

    var bottom_cursor: usize = input.len;
    try testing.expect(!movePromptCursorVertical(">", input, &bottom_cursor, 8, .down));
}

test "attachment helper navigation treats chips as focused units" {
    const text = "a <@image:1> b <@paste:2>";
    const first = std.mem.indexOf(u8, text, "<@image:1>").?;
    const second = std.mem.indexOf(u8, text, "<@paste:2>").?;

    try testing.expect(focusedAttachmentToken(text, first) != null);
    try testing.expectEqual(second, nextAttachmentCursor(text, first));
    try testing.expectEqual(first, previousAttachmentCursor(text, second));
    try testing.expectEqual(first + "<@image:1>".len, exitAttachmentCursor(text, first));
    const remove = attachmentRemoveRange(text, first).?;
    try testing.expectEqualStrings("<@image:1> ", text[remove.start..remove.end]);
}

test "computePromptSuggestion only shows on first empty prompt" {
    try testing.expectEqualStrings("explain src/main.zig", computePromptSuggestion("explain src/main.zig", "", 0));
    try testing.expectEqualStrings("", computePromptSuggestion("explain src/main.zig", "typed", 0));
    try testing.expectEqualStrings("", computePromptSuggestion("explain src/main.zig", "", 1));
}

test "collectStarterSuggestions keeps workspace and recent prompts distinct" {
    var selection: usize = 1;
    const starters = collectStarterSuggestions("explain src/main.zig", "summarize latest diff", "", 0, &selection);
    try testing.expectEqual(@as(usize, 2), starters.count);
    try testing.expectEqualStrings("explain src/main.zig", starters.items[0].text);
    try testing.expectEqualStrings("summarize latest diff", starters.items[1].text);
    try testing.expectEqualStrings("start", starters.items[0].tag);
    try testing.expectEqualStrings("recent", starters.items[1].tag);
    try testing.expectEqual(@as(usize, 1), selection);
}

test "appendStarterFooterRows marks the selected starter row" {
    var selection: usize = 1;
    const starters = collectStarterSuggestions("first", "second", "", 0, &selection);
    var footer_rows = PromptFooterRows{};
    appendStarterFooterRows(&footer_rows, starters.visible(), selection);
    try testing.expectEqual(@as(usize, 2), footer_rows.count);
    try testing.expectEqual(@as(?usize, 1), footer_rows.selected_index);
    try testing.expectEqualStrings("first", footer_rows.visible()[0].primary);
    try testing.expectEqualStrings("second", footer_rows.visible()[1].primary);
}

test "extractReferenceToken finds active @file tokens" {
    const token = extractReferenceToken("inspect @src/main.zig now", "inspect @src/ma".len).?;
    try testing.expectEqual(@as(usize, 8), token.start);
    try testing.expectEqual(@as(usize, 21), token.end);
    try testing.expectEqualStrings("src/main.zig", token.query);
    try testing.expect(!token.quoted);
}

test "extractReferenceToken supports quoted @file tokens" {
    const token = extractReferenceToken("inspect @\"my file.zig\"", "inspect @\"my fi".len).?;
    try testing.expectEqual(@as(usize, 8), token.start);
    try testing.expectEqual(@as(usize, 22), token.end);
    try testing.expectEqualStrings("my file.zig", token.query);
    try testing.expect(token.quoted);
}

test "formatReferenceCompletion quotes paths with spaces" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("@src/main.zig ", formatReferenceCompletion(buf[0..], "src/main.zig", false, true, true));
    try testing.expectEqualStrings("@\"docs/My File.md\" ", formatReferenceCompletion(buf[0..], "docs/My File.md", false, true, true));
    try testing.expectEqualStrings("@\"docs/My File", formatReferenceCompletion(buf[0..], "docs/My File", true, false, false));
}

test "collectReferenceSuggestions ranks workspace file matches" {
    const items = [_]repl_quick_open_mod.Item{
        .{ .path = @constCast("README.md") },
        .{ .path = @constCast("src/main.zig") },
        .{ .path = @constCast("src/repl_render.zig") },
    };
    var dynamic = DynamicCommandSuggestionCache.init(testing.allocator);
    defer dynamic.deinit(testing.allocator);

    const suggestions = collectReferenceSuggestions(items[0..], &dynamic, "@re", 3);
    try testing.expectEqual(@as(usize, 2), suggestions.count);
    const visible = suggestions.visible();
    try testing.expectEqualStrings("README.md", visible[0].text);
    try testing.expectEqualStrings("src/repl_render.zig", visible[1].text);
}

test "collectReferenceSuggestions includes dynamic agent and mcp items" {
    const items = [_]repl_quick_open_mod.Item{};
    var dynamic = DynamicCommandSuggestionCache.init(testing.allocator);
    defer dynamic.deinit(testing.allocator);
    try dynamic.items.append(.{
        .source = .agent,
        .text = try testing.allocator.dupe(u8, "agent:planner"),
        .primary = try testing.allocator.dupe(u8, "agent:planner"),
        .secondary = try testing.allocator.dupe(u8, "planning specialist"),
    });
    try dynamic.items.append(.{
        .source = .mcp_resource,
        .text = try testing.allocator.dupe(u8, "mcp:docs:file://guide"),
        .primary = try testing.allocator.dupe(u8, "mcp resource:docs/guide"),
        .secondary = try testing.allocator.dupe(u8, "project guide"),
    });

    const suggestions = collectReferenceSuggestions(items[0..], &dynamic, "@plan", "@plan".len);
    try testing.expectEqual(@as(usize, 1), suggestions.count);
    try testing.expectEqualStrings("agent:planner", suggestions.visible()[0].text);
    try testing.expectEqual(repl_footer_mod.SuggestionSource.agent, suggestions.visible()[0].source);
}

test "matchesCommandQuery: prefix, substring, and subsequence" {
    // Prefix.
    try testing.expect(matchesCommandQuery("dep", "deploy"));
    // Subsequence (chars in order, not contiguous).
    try testing.expect(matchesCommandQuery("dpl", "deploy"));
    // Substring (not a prefix).
    try testing.expect(matchesCommandQuery("plo", "deploy"));
    // Empty query matches anything.
    try testing.expect(matchesCommandQuery("", "deploy"));
    // No match: a char missing or out of order.
    try testing.expect(!matchesCommandQuery("xyz", "deploy"));
    try testing.expect(!matchesCommandQuery("ode", "deploy")); // 'o' before 'd'? no 'd' after -> subsequence fails
}

fn testNoUsage(_: []const u8) f64 {
    return 0;
}

fn testUsageBoostDeploy(name: []const u8) f64 {
    if (std.mem.eql(u8, name, "deploy")) return 5;
    return 0;
}

test "collectCommandSuggestions orders a higher usage score first" {
    var dynamic = DynamicCommandSuggestionCache.init(testing.allocator);
    defer dynamic.deinit(testing.allocator);
    // Two custom commands that both prefix-match "/d": "/deploy" and "/docs".
    // With equal match-rank, usage score breaks the tie; "deploy" has score 5.
    try dynamic.items.append(.{
        .source = .command,
        .text = try testing.allocator.dupe(u8, "/docs"),
        .primary = try testing.allocator.dupe(u8, "command:docs"),
        .secondary = try testing.allocator.dupe(u8, "open docs"),
    });
    try dynamic.items.append(.{
        .source = .command,
        .text = try testing.allocator.dupe(u8, "/deploy"),
        .primary = try testing.allocator.dupe(u8, "command:deploy"),
        .secondary = try testing.allocator.dupe(u8, "deploy app"),
    });

    const ranked = collectCommandSuggestionsWith("/d", &dynamic, testUsageBoostDeploy);
    const visible = ranked.visible();
    try testing.expect(visible.len >= 2);
    try testing.expectEqualStrings("/deploy", visible[0].text);

    // With no usage boost, equal-rank candidates fall back to alphabetical:
    // "deploy" still precedes "docs" by name.
    const flat = collectCommandSuggestionsWith("/d", &dynamic, testNoUsage);
    const flat_visible = flat.visible();
    try testing.expect(flat_visible.len >= 2);
    try testing.expectEqualStrings("/deploy", flat_visible[0].text);
}

test "collectCommandSuggestions ranks a prefix match above a subsequence match" {
    var dynamic = DynamicCommandSuggestionCache.init(testing.allocator);
    defer dynamic.deinit(testing.allocator);
    // "/deploy" prefix-matches "/de"; "/decode" also prefix-matches; "/dxe"
    // would only subsequence-match. Use a query that prefix-hits one and
    // subsequence-hits the other to confirm prefix wins.
    try dynamic.items.append(.{
        .source = .command,
        .text = try testing.allocator.dupe(u8, "/xdeploy"), // subsequence for "dep"
        .primary = try testing.allocator.dupe(u8, "command:xdeploy"),
        .secondary = try testing.allocator.dupe(u8, ""),
    });
    try dynamic.items.append(.{
        .source = .command,
        .text = try testing.allocator.dupe(u8, "/deploy"), // prefix for "/dep"
        .primary = try testing.allocator.dupe(u8, "command:deploy"),
        .secondary = try testing.allocator.dupe(u8, ""),
    });

    const ranked = collectCommandSuggestionsWith("/dep", &dynamic, testNoUsage);
    const visible = ranked.visible();
    try testing.expect(visible.len >= 2);
    // "/deploy" is a substring/prefix hit (higher rank) than the subsequence
    // hit "/xdeploy".
    try testing.expectEqualStrings("/deploy", visible[0].text);
}

test "computeInlineGhostText returns slash and reference completion suffixes" {
    var ghost_buf: [128]u8 = undefined;
    const no_refs = ReferenceSuggestions{};

    try testing.expectEqualStrings("ode", computeInlineGhostText(ghost_buf[0..], "/m", 2, 0, false, &no_refs, 0, false));
    try testing.expectEqualStrings("e", computeInlineGhostText(ghost_buf[0..], "/mod", 4, 0, false, &no_refs, 0, false));

    const suggestions = collectSlashSuggestions("/m");
    try testing.expect(suggestions.total_matches > 1);
    try testing.expectEqualStrings("", computeInlineGhostText(ghost_buf[0..], "/m", 1, 0, false, &no_refs, 0, false));

    const items = [_]repl_quick_open_mod.Item{
        .{ .path = @constCast("src/main.zig") },
    };
    var dynamic = DynamicCommandSuggestionCache.init(testing.allocator);
    defer dynamic.deinit(testing.allocator);
    const reference_suggestions = collectReferenceSuggestions(items[0..], &dynamic, "@src/ma", "@src/ma".len);
    try testing.expectEqualStrings("in.zig ", computeInlineGhostText(ghost_buf[0..], "@src/ma", "@src/ma".len, 0, false, &reference_suggestions, 0, false));
}

test "shouldShowBypassGate fires only in bypass mode with the skip flag unset" {
    // ui-dialogs-02: the gate shows only when bypass is active AND the user has
    // not already accepted (skip flag false). Once accepted, it never re-shows.
    try testing.expect(shouldShowBypassGate(true, false));
    try testing.expect(!shouldShowBypassGate(true, true));
    try testing.expect(!shouldShowBypassGate(false, false));
    try testing.expect(!shouldShowBypassGate(false, true));
}

test "randomGoodbye always returns one of the known goodbye messages" {
    // ui-dialogs-06: the farewell is randomized, so over many draws every
    // result must still be a member of GOODBYE_MESSAGES (no out-of-bounds
    // index, no stray string).
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const g = randomGoodbye();
        var found = false;
        for (GOODBYE_MESSAGES) |msg| {
            if (std.mem.eql(u8, g, msg)) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
}

test "inManagedWorktree detects zcode-managed worktree paths only" {
    // ui-dialogs-06: the worktree-exit branch fires only when cwd is inside a
    // zcode-created worktree (under .zcode/worktrees/agent-<suffix>).
    try testing.expect(inManagedWorktree("/home/u/proj/.zcode/worktrees/agent-abc123"));
    try testing.expect(inManagedWorktree("/home/u/proj/.zcode/worktrees/agent-x/sub/dir"));
    try testing.expect(!inManagedWorktree("/home/u/proj"));
    try testing.expect(!inManagedWorktree("/home/u/proj/.zcode/sessions"));
    try testing.expect(!inManagedWorktree("/home/u/proj/worktrees/agent-x"));
    try testing.expect(!inManagedWorktree(""));
}
