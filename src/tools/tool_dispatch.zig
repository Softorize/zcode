const std = @import("std");
const types = @import("../core/types.zig");
const clock = @import("../core/clock.zig");
const std_io = @import("../core/std_io.zig");
const rt = @import("zcode_runtime");
const parse_helpers = @import("../core/parse_helpers.zig");
const mcp_client = @import("../mcp/client.zig");
const browser_bridge = @import("../mcp/browser_bridge.zig");
const mcp_name = @import("../core/mcp_name.zig");
const shell_tool = @import("shell.zig");
const file_tool = @import("file.zig");
const git_tool = @import("git.zig");
const ext_tool = @import("extended.zig");
const todo_write = @import("todo_write.zig");
const mcp_auth = @import("mcp_auth.zig");
const repl_tool = @import("repl_tool.zig");
const fs_extra = @import("fs_extra.zig");
const git_extra = @import("git_extra.zig");
const http_tool = @import("http.zig");
const web_summarize = @import("web_summarize.zig");
const config_mod = @import("../core/config.zig");
const config_tool = @import("config_tool.zig");
const structured_output = @import("structured_output.zig");
const json_query = @import("json_query.zig");
const tool_search_score = @import("tool_search_score.zig");
const test_runner = @import("test_runner.zig");
const args = @import("arg_parse.zig");
const http_common = @import("../providers/common.zig");

const getArg = args.getArg;
const parseUsize = args.parseUsize;
const parseBool = args.parseBool;

/// Hard cap on bytes a single Read tool call can pull into memory.
/// Ported from claude-code-main/src/constants/files.ts MAX_OUTPUT_SIZE.
/// The reference uses 256 KiB because that's the practical ceiling
/// for one file read: anything larger either blows the model's
/// context budget (256 KiB of UTF-8 is already ~64k tokens, half
/// of a 128k-context budget) or demands pagination via offset/limit
/// anyway.
///
/// We previously ran with 16 MiB, which was 64x more permissive
/// than the reference and effectively meaningless because no
/// model has a 4M-token context. A prompt asking for
/// `Read(path=huge.log, max_bytes=8000000)` would silently pull
/// 8 MiB into RAM, spend wall-time tokenising, then truncate
/// inside the provider's own budget guard, leaving the user
/// confused about where their context went.
///
/// Callers that genuinely need more can override via env var:
///   ZCODE_FILE_READ_MAX_BYTES        preferred
///   CLAUDE_CODE_FILE_READ_MAX_BYTES  reference-compat alias
///
/// Both are parsed at call time so an env change takes effect
/// without restart. For files larger than the effective cap, the
/// tool schema encourages pagination via offset/limit -- the same
/// escape hatch the reference recommends.
const READ_TOOL_MAX_BYTES_DEFAULT: usize = 256 * 1024;

fn resolveReadMaxBytes() usize {
    const env_names = [_][]const u8{
        "ZCODE_FILE_READ_MAX_BYTES",
        "CLAUDE_CODE_FILE_READ_MAX_BYTES",
    };
    for (env_names) |name| {
        const raw = @import("../core/env.zig").getenv(name) orelse continue;
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) continue;
        const parsed = std.fmt.parseInt(usize, trimmed, 10) catch continue;
        if (parsed == 0) continue;
        return parsed;
    }
    return READ_TOOL_MAX_BYTES_DEFAULT;
}

/// Return an error-as-output blob that the model can read. Tool
/// handlers use this for missing/invalid arguments so the model sees
/// a field name and can self-correct, instead of an opaque
/// `error.MissingToolArg` from the top-level dispatcher.
fn missingArg(allocator: std.mem.Allocator, field: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "error: missing required field '{s}'", .{field});
}

pub const ToolExecutionRequest = struct {
    name: []const u8,
    args: []const u8,
    cwd: []const u8,
    sandbox_profile: []const u8 = "danger-full-access",
    approve_high: bool = false,
    browser: ?*browser_bridge.BrowserBridge = null,
    /// bash-shell-02: absolute path to the session's shell environment
    /// snapshot `.sh` file, or null when no snapshot was created. When set,
    /// the Bash handler sources it before the command so the model's shell
    /// sees the user's aliases/functions. Borrowed -- the runtime owns it.
    shell_snapshot_path: ?[]const u8 = null,
    /// Phase 9 Task 1: secondary-summarization context for WebFetch's `prompt`
    /// pass. When set alongside a non-null `prompt` arg, the WebFetch handler
    /// routes the fetched content through a small/fast model that answers the
    /// prompt. Null at call sites without model-call plumbing -- WebFetch then
    /// returns raw stripped content as before. Borrowed -- the runtime owns it.
    web_fetch_ctx: ?web_summarize.SummarizeContext = null,
    /// Phase 9 Task 8: mutable runtime config pointer for the Config tool. The
    /// Config handler reads from it (read path) or mutates it (write path)
    /// through the same Config.setOwnedString discipline the `/config` REPL path
    /// uses. Null at call sites without config plumbing -- the Config handler
    /// then returns an error blob rather than crashing. Borrowed -- the runtime
    /// owns the lifetime.
    config_ctx: ?*config_mod.Config = null,
    /// Phase 9 Task 11: the active response schema (from `--json <schema>` /
    /// pending_response_schema) used to validate a StructuredOutput call. Null
    /// when no schema is active -- StructuredOutput then accepts any object
    /// (passthrough). Borrowed -- the runtime owns the lifetime.
    response_schema: ?[]const u8 = null,
};

const HandlerFn = *const fn (std.mem.Allocator, ?*mcp_client.Client, ToolExecutionRequest) anyerror![]u8;

const DispatchEntry = struct {
    names: []const []const u8,
    handler: HandlerFn,
};

const dispatch_table = [_]DispatchEntry{
    .{ .names = &.{ "shell", "Bash", "bash" }, .handler = handleShell },
    .{ .names = &.{ "file_read", "Read", "read" }, .handler = handleFileRead },
    .{ .names = &.{ "file_write", "Write", "write" }, .handler = handleFileWrite },
    .{ .names = &.{ "file_edit", "Edit", "edit" }, .handler = handleFileEdit },
    .{ .names = &.{ "MultiEdit", "multi_edit", "file_multi_edit" }, .handler = handleFileMultiEdit },
    .{ .names = &.{"git_status"}, .handler = handleGitStatus },
    .{ .names = &.{ "git_apply", "GitApply" }, .handler = handleGitApply },
    .{ .names = &.{ "Glob", "glob" }, .handler = handleGlob },
    .{ .names = &.{ "Grep", "grep" }, .handler = handleGrep },
    .{ .names = &.{ "WebFetch", "web_fetch" }, .handler = handleWebFetch },
    .{ .names = &.{ "WebSearch", "web_search" }, .handler = handleWebSearch },
    .{ .names = &.{ "NotebookEdit", "notebook_edit" }, .handler = handleNotebookEdit },
    .{ .names = &.{ "Task", "task" }, .handler = handleTask },
    .{ .names = &.{ "TaskCreate", "task_create" }, .handler = handleTaskCreate },
    .{ .names = &.{ "TaskGet", "task_get" }, .handler = handleTaskGet },
    .{ .names = &.{ "TaskUpdate", "task_update" }, .handler = handleTaskUpdate },
    .{ .names = &.{ "TaskList", "task_list" }, .handler = handleTaskList },
    .{ .names = &.{ "TaskStop", "task_stop" }, .handler = handleTaskStop },
    .{ .names = &.{ "TaskOutput", "task_output" }, .handler = handleTaskOutput },
    .{ .names = &.{ "TaskRun", "task_run" }, .handler = handleTaskRun },
    .{ .names = &.{ "TaskPoll", "task_poll" }, .handler = handleTaskPoll },
    .{ .names = &.{ "TaskClaim", "task_claim" }, .handler = handleTaskClaim },
    .{ .names = &.{ "EnterPlanMode", "enter_plan_mode" }, .handler = handleEnterPlanMode },
    .{ .names = &.{ "ExitPlanMode", "exit_plan_mode" }, .handler = handleExitPlanMode },
    .{ .names = &.{ "AskUserQuestion", "ask_user_question" }, .handler = handleAskUserQuestion },
    .{ .names = &.{ "Skill", "skill" }, .handler = handleSkill },
    .{ .names = &.{ "Command", "command" }, .handler = handleCommand },
    .{ .names = &.{ "TeamCreate", "team_create" }, .handler = handleTeamCreate },
    .{ .names = &.{ "TeamDelete", "team_delete" }, .handler = handleTeamDelete },
    .{ .names = &.{ "SendMessage", "send_message" }, .handler = handleSendMessage },
    .{ .names = &.{ "Move", "move" }, .handler = handleMove },
    .{ .names = &.{ "Copy", "copy" }, .handler = handleCopy },
    .{ .names = &.{ "Delete", "delete" }, .handler = handleDelete },
    .{ .names = &.{ "ListDir", "list_dir" }, .handler = handleListDir },
    .{ .names = &.{ "Stat", "stat" }, .handler = handleStat },
    .{ .names = &.{ "RunTests", "run_tests" }, .handler = handleRunTests },
    .{ .names = &.{ "GitCommit", "git_commit" }, .handler = handleGitCommit },
    .{ .names = &.{ "GitDiff", "git_diff" }, .handler = handleGitDiff },
    .{ .names = &.{ "GitLog", "git_log" }, .handler = handleGitLog },
    .{ .names = &.{ "OpenPR", "open_pr" }, .handler = handleOpenPR },
    .{ .names = &.{ "HttpRequest", "http_request" }, .handler = handleHttpRequest },
    .{ .names = &.{ "JsonQuery", "json_query" }, .handler = handleJsonQuery },
    .{ .names = &.{ "AgentRun", "agent_run" }, .handler = handleAgentRun },
    .{ .names = &.{ "Sleep", "sleep" }, .handler = handleSleep },
    .{ .names = &.{ "EnterWorktree", "enter_worktree" }, .handler = handleEnterWorktree },
    .{ .names = &.{ "ExitWorktree", "exit_worktree" }, .handler = handleExitWorktree },
    .{ .names = &.{ "mcp_servers_list", "McpServersList" }, .handler = handleMcpServersList },
    .{ .names = &.{ "mcp_tools_list", "McpToolsList" }, .handler = handleMcpToolsList },
    .{ .names = &.{"mcp_invoke"}, .handler = handleMcpInvoke },
    .{ .names = &.{"mcp_resources_list"}, .handler = handleMcpResourcesList },
    .{ .names = &.{"mcp_resource_templates_list"}, .handler = handleMcpResourceTemplatesList },
    .{ .names = &.{"mcp_resource_read"}, .handler = handleMcpResourceRead },
    .{ .names = &.{"mcp_prompts_list"}, .handler = handleMcpPromptsList },
    .{ .names = &.{"mcp_prompt_get"}, .handler = handleMcpPromptGet },
    .{ .names = &.{"mcp_complete"}, .handler = handleMcpComplete },
    .{ .names = &.{"mcp_subscribe"}, .handler = handleMcpSubscribe },
    .{ .names = &.{"mcp_unsubscribe"}, .handler = handleMcpUnsubscribe },
    .{ .names = &.{"mcp_notifications"}, .handler = handleMcpNotifications },
    .{ .names = &.{"mcp_logging_set_level"}, .handler = handleMcpLoggingSetLevel },
    .{ .names = &.{ "ToolSearch", "tool_search" }, .handler = handleToolSearch },
    .{ .names = &.{ "Brief", "brief" }, .handler = handleBrief },
    .{ .names = &.{ "TodoWrite", "todo_write" }, .handler = handleTodoWrite },
    .{ .names = &.{ "McpAuth", "mcp_auth" }, .handler = handleMcpAuth },
    .{ .names = &.{ "REPL", "repl" }, .handler = handleRepl },
    .{ .names = &.{ "LSP", "lsp" }, .handler = handleLsp },
    .{ .names = &.{ "CronCreate", "cron_create" }, .handler = handleCronCreate },
    .{ .names = &.{ "CronDelete", "cron_delete" }, .handler = handleCronDelete },
    .{ .names = &.{ "CronList", "cron_list" }, .handler = handleCronList },
    .{ .names = &.{ "Config", "config" }, .handler = handleConfigTool },
    .{ .names = &.{ "StructuredOutput", "structured_output" }, .handler = handleStructuredOutput },
};

pub fn dispatch(
    allocator: std.mem.Allocator,
    mcp: ?*mcp_client.Client,
    req: ToolExecutionRequest,
) ![]u8 {
    for (dispatch_table) |entry| {
        if (matchesName(req.name, entry.names)) {
            return entry.handler(allocator, mcp, req);
        }
    }

    // Canonical `mcp__server__tool` names plus the legacy `mcp::server::tool`
    // form (kept for one release so saved registries / in-flight sessions keep
    // working) both route to the dynamic MCP handler.
    if (std.mem.startsWith(u8, req.name, "mcp__") or std.mem.startsWith(u8, req.name, "mcp::")) {
        return handleMcpDynamic(allocator, mcp, req);
    }

    return std.fmt.allocPrint(allocator, "error: unknown tool '{s}'. Use a known tool name.", .{req.name});
}

const matchesName = parse_helpers.matchesAnyName;

/// Default and max shell-tool timeouts, in seconds, resolved once
/// per call. Env-var precedence matches the reference convention:
///
///   ZCODE_BASH_DEFAULT_TIMEOUT_MS  (preferred)
///   BASH_DEFAULT_TIMEOUT_MS        (Claude-Code-compat)
///
///   ZCODE_BASH_MAX_TIMEOUT_MS      (preferred)
///   BASH_MAX_TIMEOUT_MS            (Claude-Code-compat)
///
/// Values are ms in the env var (matching the reference), converted
/// to seconds here because our shell.zig runs on second-granularity
/// timeouts. Anything below 1000ms rounds up to 1s so a user can't
/// set an effectively-zero timeout via a typo.
///
/// Fallback: 120s default / 600s max -- the same baselines our
/// source previously hardcoded.
const ShellTimeoutBounds = struct {
    default_secs: usize,
    max_secs: usize,
};

fn bashTimeoutBounds() ShellTimeoutBounds {
    const fallback_default_secs: usize = 120;
    const fallback_max_secs: usize = 600;

    const default_ms = firstEnv(&.{ "ZCODE_BASH_DEFAULT_TIMEOUT_MS", "BASH_DEFAULT_TIMEOUT_MS" });
    const max_ms = firstEnv(&.{ "ZCODE_BASH_MAX_TIMEOUT_MS", "BASH_MAX_TIMEOUT_MS" });

    const default_secs = msToSecsOrFallback(default_ms, fallback_default_secs);
    var max_secs = msToSecsOrFallback(max_ms, fallback_max_secs);

    // Max must be >= default so a misconfigured pair (e.g. default
    // set higher than max) doesn't produce a non-monotonic clamp.
    // Matches the reference's Math.max(parsed, getDefaultBashTimeoutMs(env))
    // in getMaxBashTimeoutMs.
    if (max_secs < default_secs) max_secs = default_secs;

    return .{ .default_secs = default_secs, .max_secs = max_secs };
}

fn firstEnv(names: []const []const u8) ?[]const u8 {
    for (names) |name| {
        if (@import("../core/env.zig").getenv(name)) |v| {
            const trimmed = std.mem.trim(u8, v, " \t\r\n");
            if (trimmed.len > 0) return trimmed;
        }
    }
    return null;
}

fn msToSecsOrFallback(ms_raw: ?[]const u8, fallback_secs: usize) usize {
    if (ms_raw) |s| {
        const parsed = std.fmt.parseInt(usize, s, 10) catch return fallback_secs;
        if (parsed == 0) return fallback_secs;
        // Cap at one year of ms so a hostile / typo'd env var like
        // `ZCODE_BASH_MAX_TIMEOUT_MS=99999999999999999999...` (parses
        // up to usize::max on 64-bit) cannot overflow the
        // `parsed + 999` round-up below. Without the cap, ReleaseFast
        // wrapped to 998 (yielding a 1-second timeout, the opposite
        // of what the user asked for), and safe builds panicked.
        const ONE_YEAR_MS: usize = 365 * 24 * 60 * 60 * 1000;
        const safe_ms = if (parsed > ONE_YEAR_MS) ONE_YEAR_MS else parsed;
        // Round up so `500ms` doesn't collapse to 0 seconds.
        return @max(@as(usize, 1), (safe_ms + 999) / 1000);
    }
    return fallback_secs;
}

/// Resolve the Bash tool timeout from the two possible field shapes
/// the model might emit.
///
/// - `timeout_seconds` (our canonical, value in seconds)
/// - `timeout` / `timeout_ms` (reference Claude Code schema, value
///   in MILLISECONDS per src/tools/BashTool/BashTool.tsx)
///
/// Before the unit-aware fix, `timeout: 120000` (meaning 2 minutes
/// in ms) was treated as 120000 SECONDS = 33 hours, then clamped
/// to the 10-min max and executed as a 10-min wait instead of the
/// 2 min the model actually asked for. A 5x overshoot on every
/// such call.
///
/// Precedence: if `timeout_seconds` is set, use it as-is. If only
/// the ms-valued field is set, convert ms to seconds with
/// round-up (so sub-second ms values don't collapse to 0s and
/// disable the timeout entirely). Fall back to
/// `bounds.default_secs` when neither is set.
pub fn resolveShellTimeout(
    timeout_seconds_raw: ?[]const u8,
    timeout_ms_raw: ?[]const u8,
    bounds: ShellTimeoutBounds,
) usize {
    if (timeout_seconds_raw) |s| {
        return @min(parseUsize(s, bounds.default_secs), bounds.max_secs);
    }
    if (timeout_ms_raw) |s| {
        const ms = parseUsize(s, 0);
        if (ms == 0) return bounds.default_secs;
        // Cap before the `+ 999` round-up to defeat usize overflow
        // from a model passing timeout_ms = usize::max in tool args.
        // Same defense pattern as bashTimeoutBounds (see comment
        // there). One year of ms is well past anything legitimate.
        const ONE_YEAR_MS: usize = 365 * 24 * 60 * 60 * 1000;
        const safe_ms = if (ms > ONE_YEAR_MS) ONE_YEAR_MS else ms;
        // Round up so a 500ms value doesn't collapse to 0 seconds,
        // which would disable the timeout entirely and hang on
        // blocking commands.
        const secs = @max(@as(usize, 1), (safe_ms + 999) / 1000);
        return @min(secs, bounds.max_secs);
    }
    return bounds.default_secs;
}

// --- Shell / File / Git core handlers ---

fn handleShell(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const cmd = getArg(req.args, "command") orelse req.args;
    const timeout_bounds = bashTimeoutBounds();
    const timeout = resolveShellTimeout(
        getArg(req.args, "timeout_seconds"),
        getArg(req.args, "timeout_ms") orelse getArg(req.args, "timeout"),
        timeout_bounds,
    );
    // run_in_background is the canonical schema field, but models
    // from several providers consistently emit `background: true`
    // instead -- it's the more natural JSON key name for what the
    // field does. When we silently ignored the synonym, foreground
    // execution of blocking servers (python3 -m http.server,
    // node, etc.) hung for the full timeout, then the model
    // retried with the same args, then the agent flagged it as
    // "stuck repeating the same response" -- a deeply confusing
    // user experience for what is really a field-name mismatch.
    //
    // Accept both names to make the tool forgiving. The canonical
    // name stays `run_in_background` in the schema so trained
    // Claude Code models keep working; the alias rescues the rest.
    const bg_raw = getArg(req.args, "run_in_background") orelse getArg(req.args, "background") orelse "false";
    const bg = parseBool(bg_raw);
    if (bg) {
        const title_owned = backgroundShellTitle(allocator, cmd) catch null;
        defer if (title_owned) |buf| allocator.free(buf);
        const title = title_owned orelse "shell background task";
        const sandboxed_command = try shell_tool.buildBackgroundCommandStringWithSnapshot(allocator, req.cwd, cmd, req.sandbox_profile, req.shell_snapshot_path);
        defer allocator.free(sandboxed_command);
        const raw = try ext_tool.taskRun(allocator, req.cwd, null, title, sandboxed_command, "background shell command", "shell", "normal", "");
        defer allocator.free(raw);
        return renderManagedBackgroundShellStart(allocator, cmd, raw);
    }
    // settings-02: apply the `[env]` config table to the spawned shell when
    // a runtime config is plumbed through. Empty slice (no config) preserves
    // the historical inherit-the-raw-process-env behavior.
    const settings_env: []const config_mod.EnvPair = if (req.config_ctx) |c| c.settings_env.items else &.{};
    return shell_tool.runWithSnapshotAndEnv(allocator, req.cwd, cmd, timeout, req.sandbox_profile, req.shell_snapshot_path, settings_env);
}

fn renderManagedBackgroundShellStart(allocator: std.mem.Allocator, command: []const u8, raw: []const u8) ![]u8 {
    const task_id = fieldValue(raw, "id") orelse "";
    const output_path = fieldValue(raw, "output") orelse "";
    return std.fmt.allocPrint(
        allocator,
        "$ {s}\n[background_task_started=true]\n[background_task_id={s}]\n[background_output={s}]\n[noOutputExpected=true]\n{s}\n",
        .{ command, task_id, output_path, raw },
    );
}

fn fieldValue(text: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, key) and line.len > key.len and line[key.len] == '=') {
            return std.mem.trim(u8, line[key.len + 1 ..], " \t\r\n");
        }
    }
    return null;
}

fn backgroundShellTitle(allocator: std.mem.Allocator, command: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    const excerpt = if (trimmed.len > 72) trimmed[0..72] else trimmed;
    return std.fmt.allocPrint(allocator, "shell: {s}", .{excerpt});
}

fn handleFileRead(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    // `file_path` is the reference schema's field name
    // (claude-code-main/src/tools/FileReadTool). Models trained on
    // that schema silently failed with "missing arg: path" unless
    // we accept both. Same pattern as handleFileEdit from pass #339.
    const path = getArg(req.args, "path") orelse
        getArg(req.args, "file_path") orelse
        return missingArg(allocator, "path");
    const requested = parseUsize(getArg(req.args, "max_bytes"), 64 * 1024);
    const cap = resolveReadMaxBytes();
    const max_bytes = @min(requested, cap);
    const offset = parseUsize(getArg(req.args, "offset"), 0);
    const limit = parseUsize(getArg(req.args, "limit"), 0);
    return file_tool.readRange(allocator, req.cwd, path, max_bytes, offset, limit);
}

fn handleFileWrite(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    // `file_path` is the reference schema's field name
    // (claude-code-main/src/tools/FileWriteTool).
    const path = getArg(req.args, "path") orelse
        getArg(req.args, "file_path") orelse
        return missingArg(allocator, "path");
    const content = getArg(req.args, "content") orelse return missingArg(allocator, "content");
    const append_mode = parseBool(getArg(req.args, "append") orelse "false");
    return file_tool.write(allocator, req.cwd, path, content, append_mode) catch |err| switch (err) {
        error.WriteRequiresPriorRead => std.fmt.allocPrint(
            allocator,
            "write failed: file '{s}' already exists and has not been read yet in this session. Call Read('{s}') first so the tool can verify you're not clobbering external changes. Use append=true to add without reading, or set ZCODE_SKIP_READ_BEFORE_EDIT=1 to bypass this check.",
            .{ path, path },
        ),
        error.WriteStaleMtime => std.fmt.allocPrint(
            allocator,
            "write failed: file '{s}' was modified externally after you Read it. Call Read('{s}') again to observe the current contents before overwriting. Set ZCODE_SKIP_READ_BEFORE_EDIT=1 to bypass this check.",
            .{ path, path },
        ),
        error.WriteTargetIsDirectory => std.fmt.allocPrint(
            allocator,
            "write failed: '{s}' is a directory, not a file. Write operates on a file path -- pick a filename inside it (e.g. '{s}/NOTES.md').",
            .{ path, path },
        ),
        error.WriteContentTooLarge => std.fmt.allocPrint(
            allocator,
            "write failed: content for '{s}' is {d} bytes, exceeding the {d}-byte Write cap. Split the content across multiple Write/Edit calls, or bump ZCODE_FILE_WRITE_MAX_BYTES if you genuinely need to emit a larger file.",
            .{ path, content.len, file_tool.WRITE_MAX_BYTES_DEFAULT },
        ),
        else => err,
    };
}

fn handleFileEdit(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    // `file_path` / `old_string` / `new_string` / `replace_all` are the
    // field names claude-code-main/src/tools/FileEditTool uses. When a
    // model trained on that schema emits those names, we silently drop
    // them and fail with "missing arg: find" unless we treat them as
    // synonyms. Same pattern as Bash `run_in_background` / `background`.
    const path = getArg(req.args, "path") orelse
        getArg(req.args, "file_path") orelse
        return missingArg(allocator, "path");
    const find_text = getArg(req.args, "find") orelse
        getArg(req.args, "old_string") orelse
        return missingArg(allocator, "find");
    const replace_text = getArg(req.args, "replace") orelse
        getArg(req.args, "new_string") orelse
        "";
    const replace_all = parseBool(
        getArg(req.args, "all") orelse
            getArg(req.args, "replace_all") orelse
            "false",
    );
    return file_tool.edit(allocator, req.cwd, path, find_text, replace_text, replace_all);
}

fn handleFileMultiEdit(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    // MultiEdit is the reference's batched-edit tool: apply a list of
    // old_string/new_string pairs to a single file atomically. If any
    // edit fails, the file on disk is untouched. Ports
    // claude-code-main/src/tools/MultiEditTool/MultiEditTool.ts.
    const path = getArg(req.args, "path") orelse
        getArg(req.args, "file_path") orelse
        return missingArg(allocator, "path");
    const edits_json = getArg(req.args, "edits") orelse
        return missingArg(allocator, "edits");
    return file_tool.multiEdit(allocator, req.cwd, path, edits_json);
}

fn handleGitStatus(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    return git_tool.status(allocator, req.cwd);
}

fn handleGitApply(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const patch = getArg(req.args, "patch") orelse return missingArg(allocator, "patch");
    return git_tool.applyPatch(allocator, req.cwd, patch);
}

// --- Extended tool handlers ---

fn handleGlob(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const pattern = getArg(req.args, "pattern") orelse return missingArg(allocator, "pattern");
    const search_path = getArg(req.args, "path") orelse ".";
    const max_results = parseUsize(getArg(req.args, "max_results"), 200);
    return ext_tool.glob(allocator, req.cwd, pattern, search_path, max_results);
}

fn handleGrep(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const pattern = getArg(req.args, "pattern") orelse return missingArg(allocator, "pattern");
    const search_path = getArg(req.args, "path") orelse ".";
    const max_results = parseUsize(getArg(req.args, "max_results"), 200);
    const ignore_case = parseBool(getArg(req.args, "ignore_case") orelse "false");
    const multiline = parseBool(getArg(req.args, "multiline") orelse "false");
    const context_lines = parseUsize(getArg(req.args, "context"), 0);
    // Args ported from claude-code-main/src/tools/GrepTool:
    //   glob        -- rg --glob filter ("*.zig", "*.{ts,tsx}")
    //   type        -- rg --type filter ("zig", "py", "rust")
    //   output_mode -- rg output shape: content (default, lines
    //                  with matches), files_with_matches (-l,
    //                  path list only), count (-c, per-file
    //                  match counts). Huge context-budget lever
    //                  for the model on repo-wide searches.
    const glob = getArg(req.args, "glob") orelse "";
    const type_filter = getArg(req.args, "type") orelse "";
    const output_mode_raw = getArg(req.args, "output_mode") orelse "";
    const output_mode = @import("grep.zig").OutputMode.fromString(output_mode_raw);
    return ext_tool.grep(allocator, req.cwd, pattern, search_path, max_results, ignore_case, multiline, context_lines, glob, type_filter, output_mode);
}

fn handleWebFetch(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const url = getArg(req.args, "url") orelse return missingArg(allocator, "url");
    const max_bytes = parseUsize(getArg(req.args, "max_bytes"), 32 * 1024);
    // Phase 9 Task 1: when the model supplies a `prompt`, the fetched page is
    // summarized by a small/fast model to answer it. Absent a prompt (or absent
    // the model-call plumbing), behavior is unchanged (raw stripped content).
    const prompt = getArg(req.args, "prompt");
    return ext_tool.webFetch(allocator, req.cwd, url, max_bytes, prompt, req.web_fetch_ctx);
}

/// Phase 9 Task 8 (tools-07): model-facing Config tool. Omitting `value` reads a
/// setting (read-only, auto-allowed by the policy classifier); a present `value`
/// writes it (the classifier routes that through the normal approval path). The
/// mutable runtime config arrives via `req.config_ctx`.
fn handleConfigTool(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const setting = getArg(req.args, "setting") orelse return missingArg(allocator, "setting");
    const value = getArg(req.args, "value");
    return config_tool.run(allocator, req.config_ctx, setting, value);
}

/// Phase 9 Task 11 (tools-09): StructuredOutput. The model passes the final
/// structured object as the tool's arguments; we validate the whole args object
/// against the active response schema and, on success, return the canonical
/// structured JSON which the one-shot `--json` path emits as the final output.
/// On a schema mismatch we return the `Output does not match required schema:`
/// message so the model retries. The args JSON IS the candidate object.
fn handleStructuredOutput(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const candidate = std.mem.trim(u8, req.args, " \t\r\n");
    if (candidate.len == 0 or candidate[0] != '{') {
        return std.fmt.allocPrint(
            allocator,
            "Output does not match required schema: root: expected a JSON object as the tool arguments",
            .{},
        );
    }
    return structured_output.run(allocator, req.response_schema, candidate);
}

fn handleWebSearch(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const query = getArg(req.args, "query") orelse getArg(req.args, "q") orelse return missingArg(allocator, "query");
    const max_bytes = parseUsize(getArg(req.args, "max_bytes"), 32 * 1024);

    const allowed = try ext_tool.parseDomainList(allocator, getArg(req.args, "allowed_domains"));
    defer {
        for (allowed) |d| allocator.free(d);
        allocator.free(allowed);
    }
    const blocked = try ext_tool.parseDomainList(allocator, getArg(req.args, "blocked_domains"));
    defer {
        for (blocked) |d| allocator.free(d);
        allocator.free(blocked);
    }

    return ext_tool.webSearch(allocator, req.cwd, query, max_bytes, allowed, blocked);
}

fn handleNotebookEdit(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const notebook_tool = @import("notebook.zig");
    // `notebook_path` is the reference schema's field name
    // (claude-code-main/src/tools/NotebookEditTool).
    const path = getArg(req.args, "path") orelse
        getArg(req.args, "notebook_path") orelse
        getArg(req.args, "file_path") orelse
        return missingArg(allocator, "path");
    // source is optional only for delete-mode; all other modes
    // need content to either append/insert/replace. `new_source`
    // is the reference schema's field name -- we accept both.
    const edit_mode = notebook_tool.EditMode.parse(getArg(req.args, "edit_mode"));
    const source: []const u8 = blk: {
        if (getArg(req.args, "source") orelse
            getArg(req.args, "new_source") orelse
            getArg(req.args, "content")) |s| break :blk s;
        if (edit_mode == .delete) break :blk ""; // unused
        return missingArg(allocator, "source");
    };
    const cell_type = getArg(req.args, "cell_type") orelse "code";
    // `cell_id` is the reference's field name; accept as synonym for
    // `cell_number`. Both are 0-indexed.
    const cell_number = parseUsize(
        getArg(req.args, "cell_number") orelse getArg(req.args, "cell_id"),
        0,
    );
    return notebook_tool.notebookEditAt(allocator, req.cwd, path, source, cell_type, cell_number, edit_mode);
}

// --- Task handlers ---

fn handleTask(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const action = getArg(req.args, "action") orelse "list";
    if (std.mem.eql(u8, action, "create")) return taskCreate(allocator, req);
    if (std.mem.eql(u8, action, "get")) return taskGet(allocator, req);
    if (std.mem.eql(u8, action, "update")) return taskUpdate(allocator, req);
    if (std.mem.eql(u8, action, "stop")) return taskStop(allocator, req);
    if (std.mem.eql(u8, action, "output")) return taskOutput(allocator, req);
    if (std.mem.eql(u8, action, "run")) return taskRun(allocator, req);
    if (std.mem.eql(u8, action, "poll")) return taskPoll(allocator, req);
    if (std.mem.eql(u8, action, "claim")) return taskClaim(allocator, req);
    return ext_tool.taskList(allocator, req.cwd, getArg(req.args, "status"));
}

fn handleTaskCreate(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    return taskCreate(allocator, req);
}

fn handleTaskGet(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    return taskGet(allocator, req);
}

fn handleTaskUpdate(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    return taskUpdate(allocator, req);
}

fn handleTaskList(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    return ext_tool.taskList(allocator, req.cwd, getArg(req.args, "status"));
}

fn handleTaskStop(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    return taskStop(allocator, req);
}

fn handleTaskOutput(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    return taskOutput(allocator, req);
}

fn handleTaskRun(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    return taskRun(allocator, req);
}

fn handleTaskPoll(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    return taskPoll(allocator, req);
}

fn handleTaskClaim(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    return taskClaim(allocator, req);
}

fn taskCreate(allocator: std.mem.Allocator, req: ToolExecutionRequest) ![]u8 {
    const title = getArg(req.args, "title") orelse return missingArg(allocator, "title");
    const summary = getArg(req.args, "summary") orelse "";
    const owner = getArg(req.args, "owner") orelse "";
    const priority = getArg(req.args, "priority") orelse "normal";
    const deps = getArg(req.args, "deps") orelse "";
    const command = getArg(req.args, "command");
    // activeForm is the reference field name (TaskCreateTool.ts:22-31); accept
    // the snake_case form too. metadata is a raw JSON object passed through
    // unchanged for the record to validate + store opaquely (swarm-tasks-03/04).
    const active_form = getArg(req.args, "activeForm") orelse getArg(req.args, "active_form") orelse "";
    const metadata = getArg(req.args, "metadata") orelse "";
    return ext_tool.taskCreateWithOptions(allocator, req.cwd, title, summary, owner, priority, deps, command, active_form, metadata) catch |err| switch (err) {
        error.InvalidTaskMetadata => allocator.dupe(u8, "task create failed: metadata must be a JSON object"),
        else => err,
    };
}

fn taskGet(allocator: std.mem.Allocator, req: ToolExecutionRequest) ![]u8 {
    const id = getArg(req.args, "id") orelse return missingArg(allocator, "id");
    return ext_tool.taskGet(allocator, req.cwd, id);
}

fn taskUpdate(allocator: std.mem.Allocator, req: ToolExecutionRequest) ![]u8 {
    const id = getArg(req.args, "id") orelse return missingArg(allocator, "id");

    // Dependency edges (swarm-tasks-01) are set via TaskUpdate. `add_blocks` is a
    // comma-separated list of ids that THIS task blocks; `add_blocked_by` is a
    // comma-separated list of ids that must complete before this task. Apply the
    // edges before the scalar update so the returned record reflects them.
    try applyDependencyEdges(allocator, req.cwd, id, getArg(req.args, "add_blocks"), true);
    try applyDependencyEdges(allocator, req.cwd, id, getArg(req.args, "add_blocked_by"), false);

    return ext_tool.taskUpdate(
        allocator,
        req.cwd,
        id,
        getArg(req.args, "title"),
        getArg(req.args, "summary"),
        getArg(req.args, "status"),
        getArg(req.args, "output"),
        getArg(req.args, "owner"),
    );
}

// Claim a task for an agent (swarm-tasks-02). `owner` is the claiming agent's
// identity; `check_busy=true` additionally refuses the claim when that agent
// already owns another open task. Renders the claim outcome as model-facing
// text mirroring the reference `ClaimTaskResult` reasons.
fn taskClaim(allocator: std.mem.Allocator, req: ToolExecutionRequest) ![]u8 {
    const id = getArg(req.args, "id") orelse return missingArg(allocator, "id");
    const owner = getArg(req.args, "owner") orelse return missingArg(allocator, "owner");
    const check_busy = parseBool(getArg(req.args, "check_busy") orelse "false");

    var result = try ext_tool.claimTask(allocator, req.cwd, id, owner, check_busy);
    defer result.deinit(allocator);

    return switch (result.reason) {
        .ok => std.fmt.allocPrint(allocator, "claimed\nid={s}\nowner={s}", .{ id, owner }),
        .task_not_found => allocator.dupe(u8, "task not found"),
        .already_claimed => std.fmt.allocPrint(allocator, "claim rejected: already claimed by another agent\nid={s}", .{id}),
        .already_resolved => std.fmt.allocPrint(allocator, "claim rejected: task already resolved\nid={s}", .{id}),
        .blocked => blk: {
            const ids = try joinIdList(allocator, result.blocked_by);
            defer allocator.free(ids);
            break :blk std.fmt.allocPrint(allocator, "claim rejected: blocked\nid={s}\nblocked_by={s}", .{ id, ids });
        },
        .agent_busy => blk: {
            const ids = try joinIdList(allocator, result.busy_with);
            defer allocator.free(ids);
            break :blk std.fmt.allocPrint(allocator, "claim rejected: agent busy\nid={s}\nbusy_with={s}", .{ id, ids });
        },
    };
}

// Join an id list into a comma-separated string for model-facing output.
fn joinIdList(allocator: std.mem.Allocator, list: []const []u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    for (list, 0..) |item, idx| {
        if (idx != 0) try out.append(',');
        try out.appendSlice(item);
    }
    return out.toOwnedSlice();
}

// Parse a comma-separated id list and record a dependency edge for each entry.
// When `this_blocks` is true the edge is `blockTask(id, entry)` (this task
// blocks the entry); otherwise it is `blockTask(entry, id)` (this task is
// blocked by the entry).
fn applyDependencyEdges(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    id: []const u8,
    raw: ?[]const u8,
    this_blocks: bool,
) !void {
    const list = raw orelse return;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |part| {
        const other = std.mem.trim(u8, part, " \t\r\n");
        if (other.len == 0) continue;
        const from_id = if (this_blocks) id else other;
        const to_id = if (this_blocks) other else id;
        const res = ext_tool.blockTask(allocator, cwd, from_id, to_id) catch |err| {
            std.log.debug("task: blockTask({s} -> {s}) failed: {}", .{ from_id, to_id, err });
            continue;
        };
        allocator.free(res);
    }
}

fn taskStop(allocator: std.mem.Allocator, req: ToolExecutionRequest) ![]u8 {
    const id = getArg(req.args, "id") orelse return missingArg(allocator, "id");
    return ext_tool.taskStop(allocator, req.cwd, id);
}

fn taskOutput(allocator: std.mem.Allocator, req: ToolExecutionRequest) ![]u8 {
    const id = getArg(req.args, "id") orelse return missingArg(allocator, "id");
    return ext_tool.taskOutput(allocator, req.cwd, id, getArg(req.args, "output"));
}

fn taskRun(allocator: std.mem.Allocator, req: ToolExecutionRequest) ![]u8 {
    const command = getArg(req.args, "command") orelse "";
    const task_id = getArg(req.args, "id");
    if (command.len == 0 and task_id == null) return missingArg(allocator, "command or id");
    const title = getArg(req.args, "title") orelse if (command.len > 0) command else "task";
    const summary = getArg(req.args, "summary") orelse "";
    const owner = getArg(req.args, "owner") orelse "";
    const priority = getArg(req.args, "priority") orelse "normal";
    const deps = getArg(req.args, "deps") orelse "";
    return ext_tool.taskRun(allocator, req.cwd, task_id, title, command, summary, owner, priority, deps);
}

fn taskPoll(allocator: std.mem.Allocator, req: ToolExecutionRequest) ![]u8 {
    const id = getArg(req.args, "id") orelse return missingArg(allocator, "id");
    return ext_tool.taskPoll(allocator, req.cwd, id);
}

// --- Misc tool handlers ---

fn handleEnterPlanMode(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    return ext_tool.enterPlanMode(allocator, req.cwd);
}

fn handleExitPlanMode(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    return ext_tool.exitPlanMode(allocator, req.cwd);
}

fn handleAskUserQuestion(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const question = getArg(req.args, "question") orelse req.args;
    // Accept `options` as an alias for `choices`. The reference
    // Claude Code's AskUserQuestion schema uses `options`; models
    // trained on that schema consistently emit `options` even when
    // our schema says `choices`. This fallback rescues them.
    const choices = getArg(req.args, "choices") orelse getArg(req.args, "options") orelse "";
    return ext_tool.askUserQuestion(allocator, question, choices);
}

fn handleSkill(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const action = getArg(req.args, "action") orelse "list";
    return ext_tool.skillAction(allocator, req.cwd, action, getArg(req.args, "name"), getArg(req.args, "args"));
}

fn handleCommand(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const action = getArg(req.args, "action") orelse "list";
    return ext_tool.commandAction(allocator, req.cwd, action, getArg(req.args, "name"), getArg(req.args, "args"));
}

fn handleTeamCreate(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const name = getArg(req.args, "name") orelse return missingArg(allocator, "name");
    const members = getArg(req.args, "members") orelse "";
    return ext_tool.teamCreate(allocator, req.cwd, name, members);
}

fn handleTeamDelete(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const name = getArg(req.args, "name") orelse return missingArg(allocator, "name");
    return ext_tool.teamDelete(allocator, req.cwd, name);
}

fn handleSendMessage(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const team = getArg(req.args, "team") orelse return missingArg(allocator, "team");
    const from = getArg(req.args, "from") orelse "agent";
    const to = getArg(req.args, "to") orelse "";
    const message = getArg(req.args, "message") orelse return missingArg(allocator, "message");
    const summary = getArg(req.args, "summary") orelse "";
    return ext_tool.sendMessage(allocator, req.cwd, team, from, to, message, summary);
}

// --- Filesystem extra handlers ---

fn handleMove(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const from_path = getArg(req.args, "from") orelse getArg(req.args, "src") orelse return missingArg(allocator, "from");
    const to_path = getArg(req.args, "to") orelse getArg(req.args, "dst") orelse return missingArg(allocator, "to");
    return fs_extra.move(allocator, req.cwd, from_path, to_path);
}

fn handleCopy(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const from_path = getArg(req.args, "from") orelse getArg(req.args, "src") orelse return missingArg(allocator, "from");
    const to_path = getArg(req.args, "to") orelse getArg(req.args, "dst") orelse return missingArg(allocator, "to");
    const recursive = parseBool(getArg(req.args, "recursive") orelse "false");
    return fs_extra.copy(allocator, req.cwd, from_path, to_path, recursive);
}

fn handleDelete(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const path = getArg(req.args, "path") orelse return missingArg(allocator, "path");
    const recursive = parseBool(getArg(req.args, "recursive") orelse "false");
    return fs_extra.deletePath(allocator, req.cwd, path, recursive);
}

fn handleListDir(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const path = getArg(req.args, "path") orelse ".";
    const recursive = parseBool(getArg(req.args, "recursive") orelse "false");
    const max_entries = parseUsize(getArg(req.args, "max_entries"), 300);
    return fs_extra.listDir(allocator, req.cwd, path, recursive, max_entries);
}

fn handleStat(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const path = getArg(req.args, "path") orelse return missingArg(allocator, "path");
    return fs_extra.statPath(allocator, req.cwd, path);
}

// --- Git extra handlers ---

fn handleRunTests(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    return test_runner.runTests(allocator, req.cwd, getArg(req.args, "command"));
}

fn handleGitCommit(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const message = getArg(req.args, "message") orelse return missingArg(allocator, "message");
    const add_all = parseBool(getArg(req.args, "add_all") orelse "false");
    const allow_empty = parseBool(getArg(req.args, "allow_empty") orelse "false");
    return git_extra.commit(allocator, req.cwd, message, add_all, allow_empty);
}

fn handleGitDiff(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const staged = parseBool(getArg(req.args, "staged") orelse "false");
    const ctx = parseUsize(getArg(req.args, "context"), 3);
    const max_bytes = parseUsize(getArg(req.args, "max_bytes"), 2 * 1024 * 1024);
    return git_extra.diff(allocator, req.cwd, getArg(req.args, "path"), staged, ctx, max_bytes);
}

fn handleGitLog(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const limit = parseUsize(getArg(req.args, "limit"), 20);
    return git_extra.log(allocator, req.cwd, limit);
}

fn handleOpenPR(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const create = parseBool(getArg(req.args, "create") orelse "false");
    return git_extra.openPr(
        allocator,
        req.cwd,
        getArg(req.args, "base"),
        getArg(req.args, "title"),
        getArg(req.args, "body"),
        create,
    );
}

// --- HTTP / JSON / Agent handlers ---

fn handleHttpRequest(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const url = getArg(req.args, "url") orelse return missingArg(allocator, "url");
    const method = getArg(req.args, "method") orelse "GET";
    const timeout = parseUsize(getArg(req.args, "timeout_seconds"), 20);
    const max_bytes = parseUsize(getArg(req.args, "max_bytes"), 64 * 1024);
    return http_tool.request(
        allocator,
        req.cwd,
        method,
        url,
        getArg(req.args, "headers"),
        getArg(req.args, "body"),
        timeout,
        max_bytes,
    );
}

fn handleJsonQuery(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const selector = getArg(req.args, "query") orelse return missingArg(allocator, "query");
    return json_query.query(
        allocator,
        req.cwd,
        getArg(req.args, "json"),
        getArg(req.args, "path"),
        selector,
    );
}

fn handleAgentRun(allocator: std.mem.Allocator, _: ?*mcp_client.Client, _: ToolExecutionRequest) ![]u8 {
    // AgentRun is intercepted by agent_runtime.zig (via isAgentRunTool)
    // BEFORE dispatch ever reaches this stub. If some future call site
    // hits the dispatcher directly for "AgentRun", we want a loud failure
    // rather than the silent "__agent_run_pending" sentinel that would
    // leak into the conversation as if it were the tool's real output.
    _ = allocator;
    return error.AgentRunMustBeHandledByRuntime;
}

fn handleSleep(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    // Clamp to [1, 300] so a confused model can't ask for a 1-hour
    // sleep and wedge the turn, and also can't pass 0 (which would
    // return instantly with "slept for 0 seconds" -- pointless).
    const seconds = @min(@max(parseUsize(getArg(req.args, "seconds"), 5), 1), 300);

    // Slice the sleep into 200ms windows and check cancel between
    // slices so ESC / Ctrl+C interrupts immediately instead of
    // forcing the user to wait out the full duration. Previously
    // handleSleep called std.Thread.sleep on the whole interval,
    // which held the agent-loop thread for up to 5 minutes and
    // ignored common.cancel_requested entirely. Matches the
    // pattern passes 31/38 use for the MCP wait path and the
    // shell tool collect loop.
    const slice_ns: u64 = 200 * std.time.ns_per_ms;
    const total_ns: u64 = @as(u64, seconds) * std.time.ns_per_s;
    var elapsed_ns: u64 = 0;
    while (elapsed_ns < total_ns) {
        if (http_common.isCancelRequested()) {
            const elapsed_s = elapsed_ns / std.time.ns_per_s;
            return std.fmt.allocPrint(
                allocator,
                "sleep cancelled after {d}s of {d}s requested",
                .{ elapsed_s, seconds },
            );
        }
        const remaining = total_ns - elapsed_ns;
        const wait_ns = if (remaining < slice_ns) remaining else slice_ns;
        clock.sleepNanos(wait_ns);
        elapsed_ns += wait_ns;
    }

    return std.fmt.allocPrint(allocator, "slept for {d} seconds", .{seconds});
}

fn handleEnterWorktree(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const path = getArg(req.args, "path") orelse return missingArg(allocator, "path");
    const branch = getArg(req.args, "branch");
    var argv_buf = std.array_list.Managed([]const u8).init(allocator);
    defer argv_buf.deinit();
    try argv_buf.append("git");
    try argv_buf.append("worktree");
    try argv_buf.append("add");
    try argv_buf.append(path);
    if (branch) |b| try argv_buf.append(b);

    const result = std.process.run(allocator, rt.io, .{
        .argv = argv_buf.items,
        .cwd = .{ .path = req.cwd },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch |err| {
        return std.fmt.allocPrint(allocator, "worktree error: {s}", .{@errorName(err)});
    };
    defer allocator.free(result.stderr);
    if (result.term == .exited and result.term.exited == 0) {
        return result.stdout;
    }
    defer allocator.free(result.stdout);
    return std.fmt.allocPrint(allocator, "worktree failed: {s}", .{std.mem.trim(u8, result.stderr, " \t\r\n")});
}

fn handleExitWorktree(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const path = getArg(req.args, "path") orelse return missingArg(allocator, "path");
    const result = std.process.run(allocator, rt.io, .{
        .argv = &.{ "git", "worktree", "remove", path },
        .cwd = .{ .path = req.cwd },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch |err| {
        return std.fmt.allocPrint(allocator, "worktree remove error: {s}", .{@errorName(err)});
    };
    defer allocator.free(result.stderr);
    if (result.term == .exited and result.term.exited == 0) {
        defer allocator.free(result.stdout);
        return std.fmt.allocPrint(allocator, "worktree removed: {s}", .{path});
    }
    defer allocator.free(result.stdout);
    return std.fmt.allocPrint(allocator, "worktree remove failed: {s}", .{std.mem.trim(u8, result.stderr, " \t\r\n")});
}

// --- MCP handlers ---

fn handleMcpServersList(allocator: std.mem.Allocator, mcp: ?*mcp_client.Client, _: ToolExecutionRequest) ![]u8 {
    if (mcp == null) return allocator.dupe(u8, "MCP client unavailable");

    const servers = mcp.?.list() catch |err| {
        const error_hints = @import("../core/error_hints.zig");
        return error_hints.formatUiError(allocator, "Failed to list MCP servers", err);
    };
    defer mcp_client.freeServers(allocator, servers);

    if (servers.len == 0) {
        return allocator.dupe(u8, "No MCP servers configured.\nAdd one with: /mcp add <name> <transport>");
    }

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    try out.writer().print("Configured MCP servers ({d}):\n\n", .{servers.len});
    for (servers, 0..) |server, i| {
        try out.writer().print("{d}. {s}\n   transport: {s}\n", .{ i + 1, server.name, server.transport });
    }
    try out.writer().writeAll("\nUse mcp_tools_list server=<name> to see available tools, then mcp_invoke to call them.");

    return out.toOwnedSlice();
}

fn handleMcpToolsList(allocator: std.mem.Allocator, mcp: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const server = getArg(req.args, "server") orelse return missingArg(allocator, "server");
    if (mcp == null) return allocator.dupe(u8, "MCP client unavailable");

    const tools = mcp.?.listTools(server) catch |err| {
        const error_hints = @import("../core/error_hints.zig");
        const prefix = try std.fmt.allocPrint(allocator, "Failed to list tools for {s}", .{server});
        defer allocator.free(prefix);
        return error_hints.formatUiError(allocator, prefix, err);
    };
    defer mcp_client.freeToolInfos(allocator, tools);

    if (tools.len == 0) {
        return std.fmt.allocPrint(allocator, "No tools found on server {s}.", .{server});
    }

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    try out.writer().print("Tools on {s} ({d} total):\n\n", .{ server, tools.len });
    for (tools, 0..) |tool, i| {
        try out.writer().print("{d}. {s}\n", .{ i + 1, tool.name });
        if (tool.description.len > 0) {
            try out.writer().print("   {s}\n", .{tool.description});
        }
        if (tool.input_schema.len > 0 and !std.mem.eql(u8, tool.input_schema, "{}")) {
            const schema_len = @min(tool.input_schema.len, 200);
            try out.writer().print("   schema: {s}\n", .{tool.input_schema[0..schema_len]});
        }
    }
    try out.writer().writeAll("\nCall with: mcp_invoke server=<name> tool=<tool_name> payload=<json>");

    return out.toOwnedSlice();
}

fn handleMcpInvoke(allocator: std.mem.Allocator, mcp: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const server = getArg(req.args, "server") orelse return missingArg(allocator, "server");
    const tool = getArg(req.args, "tool") orelse return missingArg(allocator, "tool");
    const payload = getArg(req.args, "payload") orelse "";
    if (mcp == null) return allocator.dupe(u8, "MCP client unavailable");
    return mcp.?.invoke(server, tool, payload);
}

fn handleMcpResourcesList(allocator: std.mem.Allocator, mcp: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const server = getArg(req.args, "server") orelse return missingArg(allocator, "server");
    if (mcp == null) return allocator.dupe(u8, "MCP client unavailable");

    const resources = try mcp.?.listResources(server);
    defer mcp_client.freeResourceInfos(allocator, resources);
    return renderResourceList(allocator, resources);
}

fn handleMcpResourceTemplatesList(allocator: std.mem.Allocator, mcp: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const server = getArg(req.args, "server") orelse return missingArg(allocator, "server");
    if (mcp == null) return allocator.dupe(u8, "MCP client unavailable");

    const templates = try mcp.?.listResourceTemplates(server);
    defer mcp_client.freeResourceTemplateInfos(allocator, templates);
    return renderResourceTemplateList(allocator, templates);
}

fn handleMcpResourceRead(allocator: std.mem.Allocator, mcp: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const server = getArg(req.args, "server") orelse return missingArg(allocator, "server");
    const uri = getArg(req.args, "uri") orelse return missingArg(allocator, "uri");
    if (mcp == null) return allocator.dupe(u8, "MCP client unavailable");

    const contents = try mcp.?.readResource(server, uri);
    defer mcp_client.freeResourceContents(allocator, contents);
    return renderResourceContents(allocator, contents);
}

fn handleMcpPromptsList(allocator: std.mem.Allocator, mcp: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const server = getArg(req.args, "server") orelse return missingArg(allocator, "server");
    if (mcp == null) return allocator.dupe(u8, "MCP client unavailable");

    const prompts = try mcp.?.listPrompts(server);
    defer mcp_client.freePromptInfos(allocator, prompts);
    return renderPromptList(allocator, prompts);
}

fn handleMcpPromptGet(allocator: std.mem.Allocator, mcp: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const server = getArg(req.args, "server") orelse return missingArg(allocator, "server");
    const prompt_name = getArg(req.args, "prompt") orelse return missingArg(allocator, "prompt");
    const arguments_json = getArg(req.args, "arguments_json");
    if (mcp == null) return allocator.dupe(u8, "MCP client unavailable");

    var prompt = try mcp.?.getPrompt(server, prompt_name, arguments_json);
    defer prompt.deinit(allocator);
    return renderPromptResult(allocator, &prompt);
}

fn handleMcpComplete(allocator: std.mem.Allocator, mcp: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const server = getArg(req.args, "server") orelse return missingArg(allocator, "server");
    const ref_json = getArg(req.args, "ref_json") orelse return missingArg(allocator, "ref_json");
    const argument = getArg(req.args, "argument") orelse return missingArg(allocator, "argument");
    const value = getArg(req.args, "value");
    if (mcp == null) return allocator.dupe(u8, "MCP client unavailable");

    var result = try mcp.?.complete(server, ref_json, argument, value);
    defer result.deinit(allocator);
    return renderCompletionResult(allocator, &result);
}

fn handleMcpSubscribe(allocator: std.mem.Allocator, mcp: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const server = getArg(req.args, "server") orelse return missingArg(allocator, "server");
    const uri = getArg(req.args, "uri") orelse return missingArg(allocator, "uri");
    if (mcp == null) return allocator.dupe(u8, "MCP client unavailable");
    try mcp.?.subscribeResource(server, uri);
    return std.fmt.allocPrint(allocator, "subscribed {s}", .{uri});
}

fn handleMcpUnsubscribe(allocator: std.mem.Allocator, mcp: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const server = getArg(req.args, "server") orelse return missingArg(allocator, "server");
    const uri = getArg(req.args, "uri") orelse return missingArg(allocator, "uri");
    if (mcp == null) return allocator.dupe(u8, "MCP client unavailable");
    try mcp.?.unsubscribeResource(server, uri);
    return std.fmt.allocPrint(allocator, "unsubscribed {s}", .{uri});
}

fn handleMcpNotifications(allocator: std.mem.Allocator, mcp: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const server = getArg(req.args, "server");
    if (mcp == null) return allocator.dupe(u8, "MCP client unavailable");
    if (server) |server_name| {
        mcp.?.flushNotifications(server_name) catch {};
    }
    const notifications = try mcp.?.takeNotifications(server);
    defer mcp_client.freeNotificationEvents(allocator, notifications);
    return renderNotificationList(allocator, notifications);
}

fn handleMcpLoggingSetLevel(allocator: std.mem.Allocator, mcp: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const server = getArg(req.args, "server") orelse return missingArg(allocator, "server");
    const level = getArg(req.args, "level") orelse return missingArg(allocator, "level");
    if (mcp == null) return allocator.dupe(u8, "MCP client unavailable");
    try mcp.?.setLoggingLevel(server, level);
    return std.fmt.allocPrint(allocator, "logging level set to {s}", .{level});
}

fn handleMcpDynamic(allocator: std.mem.Allocator, mcp: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const parsed = parseMcpToolName(req.name) orelse return error.InvalidMcpToolName;
    const payload = getArg(req.args, "payload") orelse req.args;

    // Route chrome tools through the browser bridge
    if (std.mem.eql(u8, parsed.server, "chrome")) {
        if (req.browser) |bridge| {
            return bridge.invoke(parsed.tool, payload);
        }
        return allocator.dupe(u8, "Chrome bridge not available. Set browser_bridge_enabled = true in config.");
    }

    if (mcp == null) return allocator.dupe(u8, "MCP client unavailable");
    return mcp.?.invoke(parsed.server, parsed.tool, payload);
}

const ParsedMcpToolName = struct {
    server: []const u8,
    tool: []const u8,
};

fn parseMcpToolName(name: []const u8) ?ParsedMcpToolName {
    // Canonical `mcp__server__tool` form first.
    if (mcp_name.mcpInfoFromString(name)) |info| {
        const tool = info.tool orelse return null;
        return .{ .server = info.server, .tool = tool };
    }

    // Legacy `mcp::server::tool` fallback, retained for one release so
    // persisted registries and in-flight sessions keep dispatching.
    if (!std.mem.startsWith(u8, name, "mcp::")) return null;
    const rest = name["mcp::".len..];
    const sep = std.mem.indexOf(u8, rest, "::") orelse return null;
    const server = rest[0..sep];
    const tool = rest[sep + 2 ..];
    if (server.len == 0 or tool.len == 0) return null;
    return .{ .server = server, .tool = tool };
}

// --- LSP handler ---

const lsp_tool = @import("lsp.zig");

fn handleLsp(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    return lsp_tool.handleLsp(allocator, req);
}

// --- CronSchedule handlers ---

const cron = @import("../core/cron.zig");

/// Global session-only cron store. Initialized on first use.
var global_cron_store: ?*cron.CronStore = null;

pub fn deinitCronStore() void {
    const store = global_cron_store orelse return;
    store.deinit();
    store.allocator.destroy(store);
    global_cron_store = null;
}

fn getCronStore(allocator: std.mem.Allocator) !*cron.CronStore {
    if (global_cron_store) |store| return store;
    const store = try allocator.create(cron.CronStore);
    store.* = cron.CronStore.init(allocator);
    // Load persisted durable entries from disk
    store.loadDurable();
    global_cron_store = store;
    return store;
}

/// Public accessor for the agent runtime to poll for due cron entries.
pub fn pollCronDue(allocator: std.mem.Allocator) ?[]const u8 {
    const store = getCronStore(allocator) catch return null;
    return store.pollDue();
}

/// Project-scoped poll: only fires due entries tagged for `cwd` (or untagged
/// global entries). Used by the REPL so it doesn't fire another project's tasks
/// now that cron is per-project (see KAIROS scope decision in docs/KAIROS.md).
pub fn pollCronDueForCwd(allocator: std.mem.Allocator, cwd: []const u8) ?[]const u8 {
    const store = getCronStore(allocator) catch return null;
    return store.pollDueForCwd(cwd);
}

/// Max scheduled jobs, matching Claude Code's CronCreate cap.
pub const MAX_CRON_JOBS: usize = 50;

/// Schedule a cron task tagged to `cwd` (per-project, so a KAIROS instance only
/// fires its own repo's tasks). Persists to disk when durable. Returns the
/// borrowed job id. Shared by the CronCreate tool and the /loop command.
pub fn scheduleCron(
    allocator: std.mem.Allocator,
    schedule: []const u8,
    prompt: []const u8,
    recurring: bool,
    durable: bool,
    cwd: []const u8,
) ![]const u8 {
    const store = try getCronStore(allocator);
    if (store.list().len >= MAX_CRON_JOBS) return error.TooManyCronJobs;
    const id = try store.addWithCwd(schedule, prompt, recurring, cwd);
    if (durable) {
        for (store.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.id, id)) {
                entry.durable = true;
                break;
            }
        }
        store.saveDurable();
    }
    return id;
}

fn handleCronCreate(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const schedule = getArg(req.args, "cron") orelse getArg(req.args, "schedule") orelse return missingArg(allocator, "cron");
    const prompt = getArg(req.args, "prompt") orelse return missingArg(allocator, "prompt");
    const recurring = if (getArg(req.args, "recurring")) |v| !std.mem.eql(u8, v, "false") else true;
    const durable = if (getArg(req.args, "durable")) |v| std.mem.eql(u8, v, "true") else false;

    const id = scheduleCron(allocator, schedule, prompt, recurring, durable, req.cwd) catch |err| switch (err) {
        error.TooManyCronJobs => return std.fmt.allocPrint(allocator, "Too many scheduled jobs (max {d}). Cancel one with CronDelete first.", .{MAX_CRON_JOBS}),
        else => return err,
    };

    var desc_buf: [64]u8 = undefined;
    const desc = cron.describeSchedule(schedule, &desc_buf);

    return std.fmt.allocPrint(
        allocator,
        "Scheduled {s} job {s} ({s}). {s}{s}Cancel with CronDelete.",
        .{
            if (recurring) "recurring" else "one-shot",
            id,
            desc,
            if (durable) "Durable (survives restarts). " else "Session-only. ",
            if (recurring) "Auto-expires after 7 days. " else "",
        },
    );
}

fn handleCronDelete(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const id = getArg(req.args, "id") orelse return missingArg(allocator, "id");
    const store = try getCronStore(allocator);
    if (store.remove(id)) {
        return std.fmt.allocPrint(allocator, "Cancelled job {s}.", .{id});
    }
    return std.fmt.allocPrint(allocator, "Job not found: {s}", .{id});
}

fn handleCronList(allocator: std.mem.Allocator, _: ?*mcp_client.Client, _: ToolExecutionRequest) ![]u8 {
    const store = try getCronStore(allocator);
    const entries = store.list();
    if (entries.len == 0) {
        return allocator.dupe(u8, "No scheduled jobs.");
    }

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.print("{d} scheduled job(s):\n", .{entries.len});
    for (entries) |entry| {
        var desc_buf: [64]u8 = undefined;
        const desc = cron.describeSchedule(entry.schedule, &desc_buf);
        try w.print("  {s}  {s}  {s}  \"{s}\"\n", .{
            entry.id,
            desc,
            if (entry.recurring) "recurring" else "one-shot",
            if (entry.prompt.len > 60) entry.prompt[0..60] else entry.prompt,
        });
    }
    return out.toOwnedSlice();
}

// --- ToolSearch handler ---

const tool_schemas = @import("tool_schemas.zig");

fn handleToolSearch(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const query = getArg(req.args, "query") orelse return missingArg(allocator, "query");
    const max_results = parseUsize(getArg(req.args, "max_results"), 5);

    // "select:Read,Edit,Grep" -- exact name lookup
    if (std.mem.startsWith(u8, query, "select:")) {
        const names_csv = query["select:".len..];
        var out = std_io.StringBuilder.init(allocator);
        errdefer out.deinit();
        const w = out.writer();
        try w.writeAll("<functions>\n");
        var found: usize = 0;
        var it = std.mem.splitScalar(u8, names_csv, ',');
        while (it.next()) |raw_name| {
            const name = std.mem.trim(u8, raw_name, " \t");
            if (name.len == 0) continue;
            for (tool_schemas.builtin_schemas) |schema| {
                if (std.ascii.eqlIgnoreCase(schema.name, name)) {
                    try w.print("<function>{{\"name\":\"{s}\",\"description\":\"{s}\",\"parameters\":{s}}}</function>\n", .{
                        schema.name, schema.description, schema.json_schema,
                    });
                    found += 1;
                    break;
                }
            }
        }
        try w.writeAll("</functions>\n");
        if (found == 0) {
            out.deinit();
            return std.fmt.allocPrint(allocator, "No tools matched the query: {s}", .{query});
        }
        return out.toOwnedSlice();
    }

    // Scored keyword search. Ported from
    // claude-code-main/src/tools/ToolSearchTool/ToolSearchTool.ts:186-302:
    // exact-name fast path, mcp__ prefix fast path, then a +required-aware
    // scored ranking over name parts / search_hint / description. Replaces the
    // old plain containsIgnoreCase substring match.
    return scoredKeywordSearch(allocator, query, max_results);
}

/// Returns the rendered `<functions>` block for the top-`max_results` tools
/// matching `query`, or a "No tools matched" message. All work happens inside
/// a per-search arena so the parsed name parts and lowercased buffers do not
/// leak.
fn scoredKeywordSearch(allocator: std.mem.Allocator, query: []const u8, max_results: usize) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const query_lower = try parse_helpers_toLower(arena, std.mem.trim(u8, query, " \t\r\n"));

    // Fast path: query equals a tool name exactly (case-insensitive). Handles
    // models that pass a bare tool name instead of the select: prefix.
    for (tool_schemas.builtin_schemas) |schema| {
        if (parse_helpers.eqlIgnoreCase(schema.name, query_lower)) {
            var single = [_][]const u8{schema.name};
            return renderSchemasByName(allocator, single[0..]);
        }
    }

    // Fast path: query looks like an mcp__server prefix -> prefix-match names.
    if (std.mem.startsWith(u8, query_lower, "mcp__") and query_lower.len > 5) {
        var prefix_names: std.ArrayList([]const u8) = .empty;
        defer prefix_names.deinit(arena);
        for (tool_schemas.builtin_schemas) |schema| {
            if (prefix_names.items.len >= max_results) break;
            if (parse_helpers.startsWithIgnoreCase(schema.name, query_lower)) {
                try prefix_names.append(arena, schema.name);
            }
        }
        if (prefix_names.items.len > 0) {
            return renderSchemasByName(allocator, prefix_names.items);
        }
    }

    const terms = try tool_search_score.partitionTerms(arena, query_lower);
    // arena owns the term slices; no explicit deinit needed.

    const Scored = struct { schema: types.ToolSchema, score: i32 };
    var scored: std.ArrayList(Scored) = .empty;
    defer scored.deinit(arena);

    for (tool_schemas.builtin_schemas) |schema| {
        const parsed = try tool_search_score.parseToolName(arena, schema.name);
        const desc_lower = try parse_helpers_toLower(arena, schema.description);
        const hint_lower = try parse_helpers_toLower(arena, schema.search_hint);

        // Pre-filter: every +required term must match name/desc/hint.
        if (terms.required.len > 0 and
            !tool_search_score.matchesAllRequired(parsed, desc_lower, hint_lower, terms.required))
        {
            continue;
        }

        const s = tool_search_score.scoreTool(parsed, desc_lower, hint_lower, terms.scoring);
        if (s <= 0) continue;
        try scored.append(arena, .{ .schema = schema, .score = s });
    }

    // Sort by score descending (stable: ties keep table order).
    std.mem.sort(Scored, scored.items, {}, struct {
        fn lessThan(_: void, a: Scored, b: Scored) bool {
            return a.score > b.score;
        }
    }.lessThan);

    if (scored.items.len == 0) {
        return std.fmt.allocPrint(allocator, "No tools matched the query: {s}", .{query});
    }

    const limit = @min(max_results, scored.items.len);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(arena);
    for (scored.items[0..limit]) |item| {
        try names.append(arena, item.schema.name);
    }
    return renderSchemasByName(allocator, names.items);
}

/// Render the `<functions>` JSON block for the given tool names, in order.
/// Names not found in `builtin_schemas` are skipped.
fn renderSchemasByName(allocator: std.mem.Allocator, names: []const []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("<functions>\n");
    for (names) |name| {
        for (tool_schemas.builtin_schemas) |schema| {
            if (std.mem.eql(u8, schema.name, name)) {
                try w.print("<function>{{\"name\":\"{s}\",\"description\":\"{s}\",\"parameters\":{s}}}</function>\n", .{
                    schema.name, schema.description, schema.json_schema,
                });
                break;
            }
        }
    }
    try w.writeAll("</functions>\n");
    return out.toOwnedSlice();
}

/// Lowercase `s` into a freshly arena-allocated buffer (small local helper to
/// keep scoring inputs case-folded).
fn parse_helpers_toLower(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try arena.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

// --- TodoWrite handler (#568) ---
// V1 todo API compatibility shim. Maps todos[] onto V2 task operations.

fn handleTodoWrite(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    return todo_write.execute(allocator, req.cwd, req.args);
}

// --- McpAuth handler (#568) ---
// Starts the MCP server OAuth flow and returns the auth URL.

fn handleMcpAuth(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    return mcp_auth.execute(allocator, req.args);
}

// --- REPL handler (#568) ---
// Batch primitive tool calls. Minimal port - summarizes the call list;
// full dispatch wiring is deferred (needs runtime ToolExecContext).

fn handleRepl(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    return repl_tool.execute(allocator, req.args);
}

// --- Brief handler ---

fn handleBrief(allocator: std.mem.Allocator, _: ?*mcp_client.Client, req: ToolExecutionRequest) ![]u8 {
    const path = getArg(req.args, "path") orelse return missingArg(allocator, "path");
    const label = getArg(req.args, "label") orelse path;
    const max_bytes = parseUsize(getArg(req.args, "max_bytes"), 65_536);

    const helpers = @import("helpers.zig");
    const abs = try helpers.normalizePath(allocator, req.cwd, path);
    defer allocator.free(abs);

    const content = std.Io.Dir.cwd().readFileAlloc(rt.io, abs, allocator, .limited(max_bytes)) catch |err| switch (err) {
        error.FileNotFound => return std.fmt.allocPrint(allocator, "error: file not found: {s}", .{path}),
        error.FileTooBig => return std.fmt.allocPrint(allocator, "error: file exceeds max_bytes ({d}). Use a smaller max_bytes or Read with offset/limit.", .{max_bytes}),
        error.IsDir => return std.fmt.allocPrint(allocator, "error: '{s}' is a directory, not a file.", .{path}),
        error.AccessDenied => return std.fmt.allocPrint(allocator, "error: access denied: {s}", .{path}),
        else => return std.fmt.allocPrint(allocator, "error reading '{s}': {s}", .{ path, @errorName(err) }),
    };
    defer allocator.free(content);

    return std.fmt.allocPrint(
        allocator,
        "<brief label=\"{s}\" path=\"{s}\" bytes=\"{d}\">\n{s}\n</brief>",
        .{ label, path, content.len, content },
    );
}

const testing = std.testing;

test "parse mcp tool name" {
    const parsed = parseMcpToolName("mcp::demo::echo").?;
    try testing.expectEqualStrings("demo", parsed.server);
    try testing.expectEqualStrings("echo", parsed.tool);
    try testing.expect(parseMcpToolName("mcp::broken") == null);
}

test "parse canonical mcp__ tool name" {
    const parsed = parseMcpToolName("mcp__chrome__navigate").?;
    try testing.expectEqualStrings("chrome", parsed.server);
    try testing.expectEqualStrings("navigate", parsed.tool);
    // server-only canonical name has no tool to dispatch -> rejected.
    try testing.expect(parseMcpToolName("mcp__chrome") == null);
    try testing.expect(parseMcpToolName("Write") == null);
}

test "canonical mcp__chrome name routes to browser bridge" {
    const parsed = parseMcpToolName("mcp__chrome__navigate").?;
    try testing.expectEqualStrings("chrome", parsed.server);
    // dispatch routes any "mcp__..." (and legacy "mcp::...") name to the dynamic
    // MCP handler; with no browser bridge it reports the bridge is unavailable
    // rather than treating the name as an unknown tool.
    const out = try dispatch(testing.allocator, null, .{ .name = "mcp__chrome__navigate", .args = "{}", .cwd = "", .browser = null });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Chrome bridge not available") != null);
}

test "legacy mcp:: chrome name still routes to browser bridge" {
    const out = try dispatch(testing.allocator, null, .{ .name = "mcp::chrome::navigate", .args = "{}", .cwd = "", .browser = null });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Chrome bridge not available") != null);
}

test "msToSecsOrFallback converts milliseconds to seconds rounded up" {
    try testing.expectEqual(@as(usize, 120), msToSecsOrFallback("120000", 9999));
    try testing.expectEqual(@as(usize, 600), msToSecsOrFallback("600000", 9999));
    // 1500 ms -> 2 s (round up so "1.5 s" doesn't collapse to 1 s).
    try testing.expectEqual(@as(usize, 2), msToSecsOrFallback("1500", 9999));
    // Sub-second values must round to at least 1 s.
    try testing.expectEqual(@as(usize, 1), msToSecsOrFallback("500", 9999));
    try testing.expectEqual(@as(usize, 1), msToSecsOrFallback("1", 9999));
}

// The dispatch-level ToolSearch tests pass args as the object BODY (no outer
// braces) to match how getArg consumes args in this codebase (see the
// arg_parse tests; the runtime feeds handlers the unwrapped argument body).

test "ToolSearch select: CSV still returns both tools" {
    const out = try dispatch(testing.allocator, null, .{
        .name = "ToolSearch",
        .args = "\"query\":\"select:Read,Edit\"",
        .cwd = "",
        .browser = null,
    });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"name\":\"Read\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"name\":\"Edit\"") != null);
}

test "ToolSearch keyword fetch web ranks WebFetch first" {
    const out = try dispatch(testing.allocator, null, .{
        .name = "ToolSearch",
        .args = "\"query\":\"fetch web\"",
        .cwd = "",
        .browser = null,
    });
    defer testing.allocator.free(out);
    // WebFetch should appear and be the first function block emitted.
    const wf = std.mem.indexOf(u8, out, "\"name\":\"WebFetch\"");
    try testing.expect(wf != null);
    // No other function block should come before WebFetch's.
    const first_fn = std.mem.indexOf(u8, out, "<function>").?;
    try testing.expect(wf.? < first_fn + 200); // WebFetch is in the first block
}

test "ToolSearch +required pre-filters to matching tools" {
    // "+web" requires "web" in name/desc/hint; "fetch" ranks the rest.
    const out = try dispatch(testing.allocator, null, .{
        .name = "ToolSearch",
        .args = "\"query\":\"+web fetch\",\"max_results\":10",
        .cwd = "",
        .browser = null,
    });
    defer testing.allocator.free(out);
    // WebFetch and WebSearch carry "web"; results must include WebFetch and
    // must NOT include an unrelated tool like Read.
    try testing.expect(std.mem.indexOf(u8, out, "\"name\":\"WebFetch\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"name\":\"Read\"") == null);
}

test "ToolSearch bare tool name fast-path returns that tool" {
    const out = try dispatch(testing.allocator, null, .{
        .name = "ToolSearch",
        .args = "\"query\":\"WebFetch\"",
        .cwd = "",
        .browser = null,
    });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"name\":\"WebFetch\"") != null);
}

test "ToolSearch no match returns plain message" {
    const out = try dispatch(testing.allocator, null, .{
        .name = "ToolSearch",
        .args = "\"query\":\"zzqqxx nonexistentkeyword\"",
        .cwd = "",
        .browser = null,
    });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "No tools matched") != null);
}

test "msToSecsOrFallback returns fallback for invalid or zero values" {
    try testing.expectEqual(@as(usize, 300), msToSecsOrFallback("abc", 300));
    try testing.expectEqual(@as(usize, 300), msToSecsOrFallback("", 300));
    try testing.expectEqual(@as(usize, 300), msToSecsOrFallback("0", 300));
    try testing.expectEqual(@as(usize, 300), msToSecsOrFallback(null, 300));
    try testing.expectEqual(@as(usize, 300), msToSecsOrFallback("-100", 300));
}

test "bashTimeoutBounds falls back to hardcoded 120/600 when env is unset" {
    // Relies on the host not having ZCODE_BASH_* or BASH_* set. Our
    // test runner doesn't set them; if a future CI setup does,
    // switch to a manual bounds-computation test that threads the
    // env map explicitly.
    const bounds = bashTimeoutBounds();
    try testing.expect(bounds.default_secs > 0);
    try testing.expect(bounds.max_secs >= bounds.default_secs);
    // Unless the host has overridden, we expect the canonical defaults.
    if (@import("../core/env.zig").getenv("ZCODE_BASH_DEFAULT_TIMEOUT_MS") == null and
        @import("../core/env.zig").getenv("BASH_DEFAULT_TIMEOUT_MS") == null)
    {
        try testing.expectEqual(@as(usize, 120), bounds.default_secs);
    }
    if (@import("../core/env.zig").getenv("ZCODE_BASH_MAX_TIMEOUT_MS") == null and
        @import("../core/env.zig").getenv("BASH_MAX_TIMEOUT_MS") == null)
    {
        try testing.expectEqual(@as(usize, 600), bounds.max_secs);
    }
}

test "resolveShellTimeout uses timeout_seconds as-is" {
    const bounds = ShellTimeoutBounds{ .default_secs = 120, .max_secs = 600 };
    try testing.expectEqual(@as(usize, 60), resolveShellTimeout("60", null, bounds));
    try testing.expectEqual(@as(usize, 300), resolveShellTimeout("300", null, bounds));
    // Above the cap -> clamp to max.
    try testing.expectEqual(@as(usize, 600), resolveShellTimeout("10000", null, bounds));
}

test "resolveShellTimeout converts ms to seconds for the reference schema's `timeout` field" {
    const bounds = ShellTimeoutBounds{ .default_secs = 120, .max_secs = 600 };
    // The motivating bug: reference schema value 120000 ms = 2 minutes.
    // Old code treated this as 120000 seconds and clamped to 600s,
    // overshooting by 5x. New code divides by 1000 -> 120s.
    try testing.expectEqual(@as(usize, 120), resolveShellTimeout(null, "120000", bounds));
    // 300 seconds worth of ms.
    try testing.expectEqual(@as(usize, 300), resolveShellTimeout(null, "300000", bounds));
    // Above ms-cap should clamp to seconds-cap.
    try testing.expectEqual(@as(usize, 600), resolveShellTimeout(null, "999999999", bounds));
}

test "resolveShellTimeout ms round-up prevents sub-second collapse" {
    const bounds = ShellTimeoutBounds{ .default_secs = 120, .max_secs = 600 };
    // 500 ms -> 1 second (round up, not floor to 0)
    try testing.expectEqual(@as(usize, 1), resolveShellTimeout(null, "500", bounds));
    // 1500 ms -> 2 seconds
    try testing.expectEqual(@as(usize, 2), resolveShellTimeout(null, "1500", bounds));
    // 1 ms -> 1 second
    try testing.expectEqual(@as(usize, 1), resolveShellTimeout(null, "1", bounds));
}

test "resolveShellTimeout prefers timeout_seconds when both fields are set" {
    const bounds = ShellTimeoutBounds{ .default_secs = 120, .max_secs = 600 };
    // If the model sends both, the canonical seconds field wins.
    // (A real model would never do this, but be explicit about
    // precedence in case of future ambiguity.)
    try testing.expectEqual(@as(usize, 60), resolveShellTimeout("60", "999000", bounds));
}

test "resolveShellTimeout falls back to default when no field is set" {
    const bounds = ShellTimeoutBounds{ .default_secs = 120, .max_secs = 600 };
    try testing.expectEqual(@as(usize, 120), resolveShellTimeout(null, null, bounds));
    // Empty strings fall back via parseUsize's default behaviour.
    try testing.expectEqual(@as(usize, 120), resolveShellTimeout(null, "0", bounds));
}

test "resolveShellTimeout respects the env-configured bounds" {
    // Operator-set bounds: 5 min default, 30 min max.
    const bounds = ShellTimeoutBounds{ .default_secs = 300, .max_secs = 1800 };
    try testing.expectEqual(@as(usize, 300), resolveShellTimeout(null, null, bounds));
    try testing.expectEqual(@as(usize, 900), resolveShellTimeout("900", null, bounds));
    try testing.expectEqual(@as(usize, 1800), resolveShellTimeout("9999", null, bounds));
    // Reference ms value in the extended bounds: 900000 ms = 15 min = 900 s
    try testing.expectEqual(@as(usize, 900), resolveShellTimeout(null, "900000", bounds));
}

test "resolveReadMaxBytes falls back to 256 KiB when env is unset" {
    // Relies on the host not having either env var set. CI doesn't
    // set them; if a future runner does, this test becomes a noop.
    if (@import("../core/env.zig").getenv("ZCODE_FILE_READ_MAX_BYTES") != null) return;
    if (@import("../core/env.zig").getenv("CLAUDE_CODE_FILE_READ_MAX_BYTES") != null) return;
    try testing.expectEqual(READ_TOOL_MAX_BYTES_DEFAULT, resolveReadMaxBytes());
    // Sanity check that the default is 256 KiB, matching the
    // reference's MAX_OUTPUT_SIZE.
    try testing.expectEqual(@as(usize, 256 * 1024), READ_TOOL_MAX_BYTES_DEFAULT);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "resolveReadMaxBytes honors ZCODE_FILE_READ_MAX_BYTES" {
    if (@import("builtin").os.tag == .windows) return;

    _ = setenv("ZCODE_FILE_READ_MAX_BYTES", "524288", 1);
    defer _ = unsetenv("ZCODE_FILE_READ_MAX_BYTES");
    try testing.expectEqual(@as(usize, 524288), resolveReadMaxBytes());
}

test "resolveReadMaxBytes also accepts CLAUDE_CODE_FILE_READ_MAX_BYTES alias" {
    if (@import("builtin").os.tag == .windows) return;
    if (@import("../core/env.zig").getenv("ZCODE_FILE_READ_MAX_BYTES") != null) return;

    _ = setenv("CLAUDE_CODE_FILE_READ_MAX_BYTES", "1048576", 1);
    defer _ = unsetenv("CLAUDE_CODE_FILE_READ_MAX_BYTES");
    try testing.expectEqual(@as(usize, 1048576), resolveReadMaxBytes());
}

test "resolveReadMaxBytes falls back on invalid / zero values" {
    if (@import("builtin").os.tag == .windows) return;
    if (@import("../core/env.zig").getenv("CLAUDE_CODE_FILE_READ_MAX_BYTES") != null) return;

    // Non-numeric -> fallback
    _ = setenv("ZCODE_FILE_READ_MAX_BYTES", "huge", 1);
    try testing.expectEqual(READ_TOOL_MAX_BYTES_DEFAULT, resolveReadMaxBytes());

    // Zero -> fallback (would otherwise disable reads entirely)
    _ = setenv("ZCODE_FILE_READ_MAX_BYTES", "0", 1);
    try testing.expectEqual(READ_TOOL_MAX_BYTES_DEFAULT, resolveReadMaxBytes());

    // Empty string -> fallback
    _ = setenv("ZCODE_FILE_READ_MAX_BYTES", "", 1);
    try testing.expectEqual(READ_TOOL_MAX_BYTES_DEFAULT, resolveReadMaxBytes());

    _ = unsetenv("ZCODE_FILE_READ_MAX_BYTES");
}

test "resolveReadMaxBytes ZCODE variant wins over CLAUDE_CODE variant" {
    if (@import("builtin").os.tag == .windows) return;

    _ = setenv("ZCODE_FILE_READ_MAX_BYTES", "111111", 1);
    _ = setenv("CLAUDE_CODE_FILE_READ_MAX_BYTES", "999999", 1);
    defer _ = unsetenv("ZCODE_FILE_READ_MAX_BYTES");
    defer _ = unsetenv("CLAUDE_CODE_FILE_READ_MAX_BYTES");
    try testing.expectEqual(@as(usize, 111111), resolveReadMaxBytes());
}

test "handleFileRead accepts reference-schema file_path synonym" {
    // Models trained on claude-code-main emit `file_path` instead of
    // `path`. Without the synonym, handleFileRead fails with
    // "missing required field 'path'" and the model retries in a loop.
    if (@import("builtin").os.tag == .windows) return;

    file_tool.resetReadTrackerForTesting();
    defer file_tool.resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "demo.txt", .data = "hello from demo\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const req = ToolExecutionRequest{
        .name = "Read",
        .args = "file_path=demo.txt",
        .cwd = cwd,
    };
    const result = try handleFileRead(testing.allocator, null, req);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "missing required field") == null);
    try testing.expect(std.mem.indexOf(u8, result, "hello from demo") != null);
}

test "handleFileWrite accepts reference-schema file_path synonym" {
    if (@import("builtin").os.tag == .windows) return;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const req = ToolExecutionRequest{
        .name = "Write",
        .args = "file_path=out.txt,content=body-bytes",
        .cwd = cwd,
    };
    const result = try handleFileWrite(testing.allocator, null, req);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "missing required field") == null);
    // Write returns an informative success message now: "created out.txt (N lines, M bytes)"
    try testing.expect(std.mem.indexOf(u8, result, "created out.txt") != null);

    // Verify the file exists with the expected body.
    const abs = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "out.txt");
    defer testing.allocator.free(abs);
    const on_disk = try std.Io.Dir.cwd().readFileAlloc(rt.io, abs, testing.allocator, .limited(1024));
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings("body-bytes", on_disk);
}

test "handleFileEdit accepts reference-schema synonyms file_path/old_string/new_string/replace_all" {
    // Models trained on claude-code-main emit `file_path`, `old_string`,
    // `new_string`, `replace_all` instead of zcode's shorter `path`,
    // `find`, `replace`, `all`. Without synonym support, the handler
    // fails with "missing arg: find" and the model retries in a loop.
    // This test pins the synonym wiring so future refactors keep it.
    if (@import("builtin").os.tag == .windows) return;

    file_tool.resetReadTrackerForTesting();
    defer file_tool.resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "demo.txt", .data = "alpha\nbeta\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // Mark demo.txt as read so the read-before-edit gate passes.
    const abs = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "demo.txt");
    defer testing.allocator.free(abs);
    file_tool.trackerRecordRead(testing.allocator, abs);

    const req = ToolExecutionRequest{
        .name = "Edit",
        .args = "file_path=demo.txt,old_string=beta,new_string=BETA,replace_all=false",
        .cwd = cwd,
    };
    const result = try handleFileEdit(testing.allocator, null, req);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "missing required field") == null);
    try testing.expect(std.mem.indexOf(u8, result, "edit ok") != null);

    const on_disk = try std.Io.Dir.cwd().readFileAlloc(rt.io, abs, testing.allocator, .limited(4 * 1024));
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings("alpha\nBETA\n", on_disk);
}

fn renderResourceList(allocator: std.mem.Allocator, resources: []const mcp_client.ResourceInfo) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    if (resources.len == 0) {
        try out.writer().writeAll("No MCP resources found.\n");
        return out.toOwnedSlice();
    }

    try out.writer().print("Resources ({d}):\n\n", .{resources.len});
    for (resources, 0..) |resource, i| {
        try out.writer().print("{d}. {s}\n", .{ i + 1, resource.name });
        if (resource.uri.len > 0) try out.writer().print("   uri: {s}\n", .{resource.uri});
        if (resource.description.len > 0) try out.writer().print("   {s}\n", .{resource.description});
    }
    return out.toOwnedSlice();
}

fn renderResourceContents(allocator: std.mem.Allocator, contents: []const mcp_client.ResourceContent) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    if (contents.len == 0) {
        try out.writer().writeAll("no MCP resource content\n");
        return out.toOwnedSlice();
    }

    for (contents, 0..) |content, idx| {
        if (idx > 0) try out.writer().writeByte('\n');
        try out.writer().print("uri={s}\tmime={s}\n", .{ content.uri, content.mime_type });
        if (content.text) |text| {
            try out.writer().print("{s}\n", .{text});
        } else if (content.blob_base64) |blob| {
            try out.writer().print("<binary {d} bytes base64>\n", .{blob.len});
        } else {
            try out.writer().writeAll("<empty>\n");
        }
    }
    return out.toOwnedSlice();
}

fn renderResourceTemplateList(allocator: std.mem.Allocator, templates: []const mcp_client.ResourceTemplateInfo) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    if (templates.len == 0) {
        try out.writer().writeAll("No MCP resource templates found.\n");
        return out.toOwnedSlice();
    }

    try out.writer().print("Resource templates ({d}):\n\n", .{templates.len});
    for (templates, 0..) |template, i| {
        try out.writer().print("{d}. {s}\n", .{ i + 1, template.name });
        if (template.uri_template.len > 0) try out.writer().print("   template: {s}\n", .{template.uri_template});
        if (template.description.len > 0) try out.writer().print("   {s}\n", .{template.description});
    }
    return out.toOwnedSlice();
}

fn renderPromptList(allocator: std.mem.Allocator, prompts: []const mcp_client.PromptInfo) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    if (prompts.len == 0) {
        try out.writer().writeAll("No MCP prompts found.\n");
        return out.toOwnedSlice();
    }

    try out.writer().print("Prompts ({d}):\n\n", .{prompts.len});
    for (prompts, 0..) |prompt, i| {
        try out.writer().print("{d}. {s}\n", .{ i + 1, prompt.name });
        if (prompt.description.len > 0) try out.writer().print("   {s}\n", .{prompt.description});
        for (prompt.arguments) |arg| {
            const req = if (arg.required) " (required)" else "";
            try out.writer().print("   - {s}{s}: {s}\n", .{ arg.name, req, arg.description });
        }
    }
    return out.toOwnedSlice();
}

fn renderPromptResult(allocator: std.mem.Allocator, prompt: *const mcp_client.PromptResult) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    if (prompt.description.len > 0) {
        try out.writer().print("{s}\n", .{prompt.description});
    }
    for (prompt.messages) |message| {
        try out.writer().print("{s}:\n{s}\n", .{ message.role, message.content });
    }
    return out.toOwnedSlice();
}

fn renderCompletionResult(allocator: std.mem.Allocator, result: *const mcp_client.CompletionResult) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    if (result.values.len == 0) {
        try out.writer().writeAll("no MCP completions\n");
        return out.toOwnedSlice();
    }

    for (result.values) |value| {
        try out.writer().print("{s}\n", .{value});
    }
    if (result.total) |total| {
        try out.writer().print("total={d}\thas_more={}\n", .{ total, result.has_more });
    } else {
        try out.writer().print("has_more={}\n", .{result.has_more});
    }
    return out.toOwnedSlice();
}

fn renderNotificationList(allocator: std.mem.Allocator, notifications: []const mcp_client.NotificationEvent) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    if (notifications.len == 0) {
        try out.writer().writeAll("no MCP notifications\n");
        return out.toOwnedSlice();
    }

    for (notifications) |notification| {
        try out.writer().print("{s}\t{s}\t{s}\n", .{ notification.server, notification.method, notification.params_json });
    }
    return out.toOwnedSlice();
}
