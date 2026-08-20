const std = @import("std");
const clock = @import("core/clock.zig");
const std_io = @import("core/std_io.zig");
const metrics = @import("core/metrics.zig");
const telemetry_attributes = @import("core/telemetry_attributes.zig");

const types = @import("core/types.zig");
const parse_helpers = @import("core/parse_helpers.zig");
const model_output = @import("core/model_output.zig");
const approval_mod = @import("core/approval.zig");
const permission_decision = @import("core/permission_decision.zig");
const bash_mode_allow = @import("core/bash_mode_allow.zig");
const sandbox_mod = @import("core/sandbox.zig");
const plugins_mod = @import("core/plugins.zig");
const hooks_mod = @import("core/hooks.zig");
const security_mod = @import("core/security.zig");
const agents_mod = @import("core/agents.zig");
const permission_rules_mod = @import("core/permission_rules.zig");
const bash_segment_permission = @import("core/bash_segment_permission.zig");
const destructive_warning = @import("core/destructive_warning.zig");
const path_safety_mod = @import("core/path_safety.zig");
const arg_parse = @import("tools/arg_parse.zig");
const tool_registry = @import("tools/registry.zig");
pub const web_summarize = @import("tools/web_summarize.zig");
pub const ask_question = @import("tools/ask_question.zig");
const agent_tool = @import("tools/agent.zig");
const repl = @import("cli/repl.zig");
const mcp_client = @import("mcp/client.zig");
const browser_bridge_mod = @import("mcp/browser_bridge.zig");

// Re-export ToolTrace and related types from agent_runtime
const agent_runtime = @import("agent_runtime.zig");
pub const ToolTrace = agent_runtime.ToolTrace;
pub const ApprovalPromptFn = agent_runtime.ApprovalPromptFn;
pub const ApprovalHandler = agent_runtime.ApprovalHandler;

// --- Mode instructions ---

pub fn modeInstruction(mode: repl.SessionMode) []const u8 {
    return switch (mode) {
        .execution => "",
        .planning =>
        \\Planning mode is active.
        \\You may use read-only tools (file_read, Read, Glob, Grep, GitDiff, GitLog, git_status, WebFetch, WebSearch, JsonQuery) to inspect the codebase.
        \\Do NOT use mutation tools (file_write, Write, file_edit, Edit, shell, Bash, git_apply, GitCommit, OpenPR, RunTests, TaskRun, NotebookEdit).
        \\
        \\When you are ready to surface the plan for the user's approval, call:
        \\  exit_plan_mode(plan="<full markdown plan>")
        \\The `plan` argument must be the complete plan markdown (Title, Goals, Assumptions, Task checklist using '- [ ]', Risks, Definition of done). The REPL opens the approval overlay only when this tool fires; do NOT emit the plan as plain assistant text.
        \\
        \\Investigate first, then call exit_plan_mode exactly once with the finished plan as the argument.
        ,
        .brainstorm =>
        \\Brainstorm mode is active.
        \\You may use read-only tools (file_read, Read, Glob, Grep, WebFetch, WebSearch, JsonQuery) to inform the discussion.
        \\Do NOT use mutation tools or shell commands (no Write, Edit, Bash, git_apply, GitCommit, etc.).
        \\Have a concise ideation discussion: ask clarifying questions, evaluate alternatives, and propose tradeoffs.
        \\When the user approves an idea, provide a concise summary ready for planning.
        ,
        .review =>
        \\Review mode is active.
        \\You may use read-only tools only.
        \\Do NOT use mutation tools or shell commands that modify the repository.
        \\Review the target like a code reviewer: prioritize correctness issues, regressions, missing tests, risky assumptions, and behavioral changes.
        \\Findings must come first, ordered by severity.
        \\If there are no findings, say that explicitly and mention residual testing gaps.
        ,
    };
}

/// Assemble a ToolTrace safely from unowned name/args plus an already-
/// allocated output buffer that the helper takes ownership of. Each
/// interior `dupe` has its own errdefer so a mid-sequence OOM frees
/// everything allocated so far (including the caller-provided output)
/// and returns the original error. This replaces the struct-literal
/// form `ToolTrace{ .name = try dupe(...), .args = try dupe(...), ... }`
/// which leaked the already-duped fields on later-dupe OOM.
fn buildToolTrace(
    allocator: std.mem.Allocator,
    name: []const u8,
    args: []const u8,
    risk: types.RiskTier,
    approval_state: types.ApprovalState,
    executed: bool,
    duration_ms: i64,
    output: []u8,
) !ToolTrace {
    errdefer allocator.free(output);
    const name_dup = try allocator.dupe(u8, name);
    errdefer allocator.free(name_dup);
    const args_dup = try allocator.dupe(u8, args);
    return ToolTrace{
        .name = name_dup,
        .args = args_dup,
        .risk = risk,
        .approval_state = approval_state,
        .executed = executed,
        .duration_ms = duration_ms,
        .output = output,
    };
}

pub fn effectiveMode(active_agent: ?@import("core/agents.zig").AgentSpec, current: repl.SessionMode) repl.SessionMode {
    const agent = active_agent orelse return current;
    return switch (agent.mode) {
        .inherit => current,
        .execution => .execution,
        .planning => .planning,
        .brainstorm => .brainstorm,
        .review => .review,
    };
}

// --- Read-only tool classification ---
// Canonical source for read-only tool classification.
// Also reflected as is_read_only=true on ToolSchema for metadata.

pub const read_only_tool_names = [_][]const u8{
    "file_read",          "Read",              "read",
    "Glob",               "glob",              "Grep",
    "grep",               "GitDiff",           "git_diff",
    "GitLog",             "git_log",           "git_status",
    "WebFetch",           "web_fetch",         "WebSearch",
    "web_search",         "JsonQuery",         "json_query",
    "AskUserQuestion",    "ask_user_question", "HttpRequest",
    "http_request",       "TaskGet",           "task_get",
    "TaskPoll",           "task_poll",         "TaskOutput",
    "task_output",        "TodoRead",          "todo_read",
    "TodoWrite",          "todo_write",        "ListDir",
    "list_dir",           "Stat",              "stat",
    "Sleep",              "sleep",             "mcp_servers_list",
    "McpServersList",     "mcp_tools_list",    "McpToolsList",
    "mcp_resources_list", "mcp_resource_read", "mcp_resource_templates_list",
    "mcp_prompts_list",   "mcp_prompt_get",    "mcp_notifications",
    "mcp_complete",       "EnterPlanMode",     "ExitPlanMode",
    "enter_plan_mode",    "exit_plan_mode",    "Skill",
    "skill",              "Command",           "command",
};

pub fn isReadOnlyTool(name: []const u8) bool {
    for (&read_only_tool_names) |ro| {
        if (std.mem.eql(u8, name, ro)) return true;
    }
    return false;
}

/// True for tools that only gather more context. These are useful
/// early in a turn, but an execution task that repeatedly uses only
/// these tools is not making user-visible progress.
pub fn isInspectionOnlyTool(name: []const u8) bool {
    return matchesToolName(name, &.{
        "file_read",          "Read",              "read",
        "Glob",               "glob",              "Grep",
        "grep",               "GitDiff",           "git_diff",
        "GitLog",             "git_log",           "git_status",
        "WebFetch",           "web_fetch",         "WebSearch",
        "web_search",         "JsonQuery",         "json_query",
        "HttpRequest",        "http_request",      "TaskGet",
        "task_get",           "TaskPoll",          "task_poll",
        "TaskOutput",         "task_output",       "TodoRead",
        "todo_read",          "ListDir",           "list_dir",
        "Stat",               "stat",              "mcp_servers_list",
        "McpServersList",     "mcp_tools_list",    "McpToolsList",
        "mcp_resources_list", "mcp_resource_read", "mcp_resource_templates_list",
        "mcp_prompts_list",   "mcp_prompt_get",    "mcp_notifications",
        "mcp_complete",
    });
}

/// Check if a tool can be executed in parallel with other tools.
/// Must be read-only AND not a special-cased tool (ask user, todo, agent).
/// MCP tools are excluded because they share a single stdio session pipe.
pub fn isParallelEligible(name: []const u8) bool {
    return isReadOnlyTool(name) and !isAskUserQuestionTool(name) and !isTodoTool(name) and !isAgentRunTool(name) and !isModeControlTool(name) and !isMcpTool(name);
}

fn isMcpTool(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "mcp_") or std.mem.startsWith(u8, name, "Mcp") or std.mem.startsWith(u8, name, "mcp::");
}

pub fn actionToolNamesSummary() []const u8 {
    return "Edit, MultiEdit, Write, Bash, RunTests, git_apply, GitCommit, TaskRun, Move, Copy, Delete, NotebookEdit";
}

pub fn canonicalToolNameForArgs(name: []const u8, args: []const u8) []const u8 {
    if (matchesToolName(name, &.{ "Shell", "shell_command", "RunCommand", "run_command" })) return "Bash";
    if (matchesToolName(name, &.{ "FileRead", "ReadFile", "read_file", "View", "view" })) return "Read";
    if (matchesToolName(name, &.{ "FileWrite", "WriteFile", "write_file", "CreateFile", "create_file" })) return "Write";
    if (matchesToolName(name, &.{ "FileEdit", "EditFile", "edit_file", "Modify", "modify", "PatchFile", "patch_file" })) return "Edit";
    if (matchesToolName(name, &.{ "GitApply", "ApplyPatch", "apply_patch", "Patch", "patch" })) return "git_apply";
    if (matchesToolName(name, &.{ "RunTest", "run_test", "Tests", "tests", "Test", "test" })) return "RunTests";

    if (matchesToolName(name, &.{ "Update", "update" })) {
        if (hasAnyArg(args, &.{ "id", "status", "title", "summary", "output", "owner", "priority", "deps" })) return "TaskUpdate";
        if (hasAnyArg(args, &.{ "find", "replace", "old_string", "new_string", "edits" })) return "Edit";
        if (hasAnyArg(args, &.{"content"})) return "Write";
        if (hasAnyArg(args, &.{ "path", "file_path" })) return "Edit";
    }

    return name;
}

pub fn isConcreteActionTool(name: []const u8, args: []const u8) bool {
    const canonical = canonicalToolNameForArgs(name, args);
    if (isInspectionOnlyTool(canonical)) return false;
    return matchesToolName(canonical, &.{
        "file_write",   "Write",         "write",
        "file_edit",    "Edit",          "edit",
        "MultiEdit",    "multi_edit",    "file_multi_edit",
        "NotebookEdit", "notebook_edit", "git_apply",
        "TaskRun",      "task_run",      "RunTests",
        "run_tests",    "GitCommit",     "git_commit",
        "OpenPR",       "open_pr",       "Move",
        "move",         "Copy",          "copy",
        "Delete",       "delete",        "Bash",
        "bash",         "shell",
    });
}

fn hasAnyArg(args: []const u8, keys: []const []const u8) bool {
    for (keys) |key| {
        if (tool_registry.getArg(args, key) != null) return true;
    }
    return false;
}

pub fn filterReadOnlySchemas(allocator: std.mem.Allocator, schemas: []types.ToolSchema) ![]types.ToolSchema {
    var filtered = std.array_list.Managed(types.ToolSchema).init(allocator);
    // Free every already-duped schema on error. The sibling
    // filterAgentSchemas already had this errdefer; filterReadOnlySchemas
    // was missing it, so a mid-loop OOM leaked every previously appended
    // schema's four strings.
    errdefer {
        for (filtered.items) |schema| {
            allocator.free(schema.name);
            allocator.free(schema.description);
            allocator.free(schema.json_schema);
            if (schema.usage_hint.len > 0) allocator.free(schema.usage_hint);
        }
        filtered.deinit();
    }
    for (schemas) |schema| {
        if (isReadOnlyTool(schema.name)) {
            // Reserve the slot first so the final append is infallible,
            // then stage each dupe with errdefers. Previously the last
            // dupe (dup_hint) had no errdefer, so an `append` OOM after
            // dup_hint succeeded leaked dup_hint.
            try filtered.ensureUnusedCapacity(1);
            const dup_name = try allocator.dupe(u8, schema.name);
            errdefer allocator.free(dup_name);
            const dup_description = try allocator.dupe(u8, schema.description);
            errdefer allocator.free(dup_description);
            const dup_schema = try allocator.dupe(u8, schema.json_schema);
            errdefer allocator.free(dup_schema);
            const dup_hint = try allocator.dupe(u8, schema.usage_hint);
            filtered.appendAssumeCapacity(.{
                .name = dup_name,
                .description = dup_description,
                .json_schema = dup_schema,
                .usage_hint = dup_hint,
            });
        }
    }
    return filtered.toOwnedSlice();
}

/// True when `name` is one of the tools the turn-end memory-extraction fork is
/// allowed to advertise: Read/Grep/Glob (read context), Bash (read-only only,
/// enforced at execution time), and Edit/Write/MultiEdit (path-restricted to
/// the auto-memory dir at execution time). Everything else (WebFetch, AgentRun,
/// MCP, git, ...) is dropped from the schema list entirely.
///
/// Ports the allowlist in createAutoMemCanUseTool
/// (claude-code-main/src/services/extractMemories/extractMemories.ts:171-222).
/// The schema list only *advertises* tools; the path/read-only enforcement
/// happens in executeToolCall via the `auto_mem_only` ToolExecContext flag.
pub fn isAutoMemTool(name: []const u8) bool {
    return matchesToolName(name, &.{
        "Read",            "read",      "file_read",
        "Grep",            "grep",      "Glob",
        "glob",            "Bash",      "bash",
        "shell",           "Edit",      "edit",
        "file_edit",       "Write",     "write",
        "file_write",      "MultiEdit", "multi_edit",
        "file_multi_edit",
    });
}

/// Copy `schemas` keeping only the auto-memory-fork allowlist (see
/// isAutoMemTool). Caller owns the result; the input is freed by the caller as
/// before (same ownership contract as filterReadOnlySchemas / filterGitTool).
pub fn filterAutoMemSchemas(allocator: std.mem.Allocator, schemas: []const types.ToolSchema) ![]types.ToolSchema {
    var filtered = std.array_list.Managed(types.ToolSchema).init(allocator);
    errdefer {
        for (filtered.items) |schema| {
            allocator.free(schema.name);
            allocator.free(schema.description);
            allocator.free(schema.json_schema);
            if (schema.usage_hint.len > 0) allocator.free(schema.usage_hint);
        }
        filtered.deinit();
    }
    for (schemas) |schema| {
        if (!isAutoMemTool(schema.name)) continue;
        try filtered.ensureUnusedCapacity(1);
        const dup_name = try allocator.dupe(u8, schema.name);
        errdefer allocator.free(dup_name);
        const dup_description = try allocator.dupe(u8, schema.description);
        errdefer allocator.free(dup_description);
        const dup_schema = try allocator.dupe(u8, schema.json_schema);
        errdefer allocator.free(dup_schema);
        const dup_hint = try allocator.dupe(u8, schema.usage_hint);
        filtered.appendAssumeCapacity(.{
            .name = dup_name,
            .description = dup_description,
            .json_schema = dup_schema,
            .usage_hint = dup_hint,
            .is_read_only = schema.is_read_only,
        });
    }
    return filtered.toOwnedSlice();
}

/// Git tools that are meaningless in a non-git workspace. Filtered out so a
/// model can't loop on "git status -> not a git repository".
pub fn isGitTool(name: []const u8) bool {
    return matchesToolName(name, &.{
        "git_status", "git_diff",  "git_log", "git_apply",
        "git_commit", "GitStatus", "GitDiff", "GitLog",
        "GitCommit",
    });
}

/// Copy `schemas` minus git tools (for non-git workspaces). Caller owns the
/// result; the input is freed by the caller as before.
pub fn filterGitToolSchemas(allocator: std.mem.Allocator, schemas: []const types.ToolSchema) ![]types.ToolSchema {
    var filtered = std.array_list.Managed(types.ToolSchema).init(allocator);
    errdefer {
        for (filtered.items) |schema| {
            allocator.free(schema.name);
            allocator.free(schema.description);
            allocator.free(schema.json_schema);
            if (schema.usage_hint.len > 0) allocator.free(schema.usage_hint);
        }
        filtered.deinit();
    }
    for (schemas) |schema| {
        if (isGitTool(schema.name)) continue;
        try filtered.ensureUnusedCapacity(1);
        const dup_name = try allocator.dupe(u8, schema.name);
        errdefer allocator.free(dup_name);
        const dup_description = try allocator.dupe(u8, schema.description);
        errdefer allocator.free(dup_description);
        const dup_schema = try allocator.dupe(u8, schema.json_schema);
        errdefer allocator.free(dup_schema);
        const dup_hint = try allocator.dupe(u8, schema.usage_hint);
        filtered.appendAssumeCapacity(.{
            .name = dup_name,
            .description = dup_description,
            .json_schema = dup_schema,
            .usage_hint = dup_hint,
            .is_read_only = schema.is_read_only,
        });
    }
    return filtered.toOwnedSlice();
}

/// WebFetch/WebSearch: research tools that count as forward motion (used to
/// research external APIs), so they are kept even when the stall guard forces
/// action away from local inspection-only tools.
pub fn isWebResearchTool(name: []const u8) bool {
    return matchesToolName(name, &.{ "WebFetch", "web_fetch", "WebSearch", "web_search" });
}

pub fn filterNonInspectionSchemas(allocator: std.mem.Allocator, schemas: []const types.ToolSchema) ![]types.ToolSchema {
    var filtered = std.array_list.Managed(types.ToolSchema).init(allocator);
    errdefer {
        for (filtered.items) |schema| {
            allocator.free(schema.name);
            allocator.free(schema.description);
            allocator.free(schema.json_schema);
            if (schema.usage_hint.len > 0) allocator.free(schema.usage_hint);
        }
        filtered.deinit();
    }

    for (schemas) |schema| {
        // Keep web-research tools available even when forcing action: for a
        // "research an external API" task, WebFetch/WebSearch ARE the action.
        if (isInspectionOnlyTool(schema.name) and !isWebResearchTool(schema.name)) continue;
        try filtered.ensureUnusedCapacity(1);
        const dup_name = try allocator.dupe(u8, schema.name);
        errdefer allocator.free(dup_name);
        const dup_description = try allocator.dupe(u8, schema.description);
        errdefer allocator.free(dup_description);
        const dup_schema = try allocator.dupe(u8, schema.json_schema);
        errdefer allocator.free(dup_schema);
        const dup_hint = try allocator.dupe(u8, schema.usage_hint);
        filtered.appendAssumeCapacity(.{
            .name = dup_name,
            .description = dup_description,
            .json_schema = dup_schema,
            .usage_hint = dup_hint,
        });
    }

    return filtered.toOwnedSlice();
}

pub fn isAskUserQuestionTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "AskUserQuestion") or std.mem.eql(u8, name, "ask_user_question");
}

pub fn isAgentRunTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "AgentRun") or std.mem.eql(u8, name, "agent_run");
}

pub fn isTodoTool(name: []const u8) bool {
    return matchesToolName(name, &.{ "TodoRead", "todo_read", "TodoWrite", "todo_write" });
}

pub fn isModeControlTool(name: []const u8) bool {
    return matchesToolName(name, &.{ "EnterPlanMode", "enter_plan_mode", "ExitPlanMode", "exit_plan_mode" });
}

pub fn filterAgentSchemas(allocator: std.mem.Allocator, schemas: []const types.ToolSchema, agent: *const agents_mod.AgentSpec) ![]types.ToolSchema {
    var out = std.array_list.Managed(types.ToolSchema).init(allocator);
    errdefer {
        for (out.items) |schema| {
            allocator.free(schema.name);
            allocator.free(schema.description);
            allocator.free(schema.json_schema);
            if (schema.usage_hint.len > 0) allocator.free(schema.usage_hint);
        }
        out.deinit();
    }

    for (schemas) |schema| {
        if (!agents_mod.allowsTool(agent, schema.name)) continue;
        // Same leak-safe pattern as filterReadOnlySchemas above: reserve
        // the slot, stage each dupe with errdefer, then infallible append.
        try out.ensureUnusedCapacity(1);
        const dup_name = try allocator.dupe(u8, schema.name);
        errdefer allocator.free(dup_name);
        const dup_description = try allocator.dupe(u8, schema.description);
        errdefer allocator.free(dup_description);
        const dup_schema = try allocator.dupe(u8, schema.json_schema);
        errdefer allocator.free(dup_schema);
        const dup_hint = try allocator.dupe(u8, schema.usage_hint);
        out.appendAssumeCapacity(.{
            .name = dup_name,
            .description = dup_description,
            .json_schema = dup_schema,
            .usage_hint = dup_hint,
        });
    }

    return out.toOwnedSlice();
}

// --- Approval helpers ---

pub fn approvalStateToString(state: types.ApprovalState) []const u8 {
    return switch (state) {
        .auto_approved => "auto_approved",
        .user_approved => "user_approved",
        .session_approved => "session_approved",
        .denied => "denied",
        .blocked => "blocked",
    };
}

fn buildApprovalDescription(out: []u8, name: []const u8, args: []const u8, risk: types.RiskTier) []const u8 {
    var summary_buf: [256]u8 = undefined;
    const summary = summarizeToolCallForProgress(&summary_buf, name, args);
    const base = std.fmt.bufPrint(out, "{s} [{s}]: {s}", .{ name, types.riskTierToString(risk), summary }) catch return name;

    // bash-shell-05: append an advisory note for reversible-but-risky bash
    // commands (git force-push, rm -rf, DROP TABLE, ...). Advisory only -- this
    // does not change risk tier or auto-approval. Best-effort: if the combined
    // text would overflow `out`, keep the base description without the note.
    if (matchesToolName(name, &.{ "shell", "Bash", "bash" })) {
        if (tool_registry.getArg(args, "command")) |command| {
            if (destructive_warning.warning(command)) |note| {
                // `base` aliases the front of `out`; append "\n{note}" after it
                // in place rather than re-running bufPrint over `out` (which
                // would alias src and dst and corrupt the result).
                const needed = base.len + 1 + note.len;
                if (needed <= out.len) {
                    out[base.len] = '\n';
                    @memcpy(out[base.len + 1 .. needed], note);
                    return out[0..needed];
                }
            }
        }
    }

    // Phase 9 Task 3 (tools-03): for a WebFetch against a non-preapproved host,
    // append a suggested `domain:<host>` allow-rule so the user can grant the
    // host once and skip future prompts (mirrors the reference's
    // webFetchToolInputToPermissionRuleContent suggestion). Best-effort: only
    // when there is room in `out`. Preapproved hosts never reach the ask path
    // (policy downgrades them to LOW), so we skip the note for them too.
    if (matchesToolName(name, &.{ "WebFetch", "web_fetch" })) {
        if (tool_registry.getArg(args, "url")) |url| {
            var note_buf: [128]u8 = undefined;
            if (webFetchSuggestionNote(&note_buf, url)) |note| {
                const needed = base.len + 1 + note.len;
                if (needed <= out.len) {
                    out[base.len] = '\n';
                    @memcpy(out[base.len + 1 .. needed], note);
                    return out[0..needed];
                }
            }
        }
    }
    return base;
}

/// Build the "approve once, or add allow rule `domain:<host>`" advisory note for
/// a WebFetch approval prompt. Returns null when the URL has no parseable host
/// or when the host is already preapproved (those never reach the ask path).
/// Writes into `buf` and returns the slice; pure, no allocation, unit-testable.
fn webFetchSuggestionNote(buf: []u8, url: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, url, " \t\"'");
    if (trimmed.len == 0) return null;
    const web_preapproved = @import("core/web_preapproved.zig");
    if (web_preapproved.isPreapprovedUrl(trimmed)) return null;
    const ssrf_guard = @import("core/ssrf_guard.zig");
    const host = ssrf_guard.extractHost(trimmed) orelse return null;
    if (host.len == 0) return null;
    return std.fmt.bufPrint(
        buf,
        "Approve once, or add allow rule domain:{s} to skip future prompts for this host.",
        .{host},
    ) catch null;
}

pub fn stdinApprovalPrompt(message: []const u8) !types.ApprovalResponse {
    const stdout = std_io.stdoutWriter();
    try stdout.print("{s} [y/a/N] ", .{message});

    const stdin = std_io.stdinReader();
    var buf: [64]u8 = undefined;
    var len: usize = 0;

    while (true) {
        const b = stdin.readByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        if (b == '\n' or b == '\r') break;
        if (b == 127 or b == 8) {
            if (len > 0) len -= 1;
            continue;
        }
        if (len < buf.len) {
            buf[len] = b;
            len += 1;
        }
    }

    try stdout.writeByte('\n');
    const trimmed = std.mem.trim(u8, buf[0..len], " \t\r\n");
    if (trimmed.len == 0) return .deny;
    if (trimmed[0] == 'y' or trimmed[0] == 'Y') return .approve;
    if (trimmed[0] == 'a' or trimmed[0] == 'A') return .approve_always;
    return .deny;
}

pub fn stdinApprovalPromptWithCtx(ctx: *anyopaque, message: []const u8) !types.ApprovalResponse {
    _ = ctx;
    return stdinApprovalPrompt(message);
}

// --- Tool execution ---

pub const ToolExecContext = struct {
    allocator: std.mem.Allocator,
    cwd: []const u8,
    cfg: *const @import("core/config.zig").Config,
    policy: *@import("policy/policy.zig").Policy,
    mcp: *mcp_client.Client,
    browser: ?*browser_bridge_mod.BrowserBridge,
    audit: *@import("core/logger.zig").AuditLogger,
    active_agent: ?agents_mod.AgentSpec,
    interactive: bool,
    auto_approve_high: bool,
    plan_approved: bool,
    yolo_mode: bool,
    approval_handler: ?ApprovalHandler,
    ask_user_ctx: ?*anyopaque,
    ask_user_fn: ?agent_runtime.AskUserPromptFn,
    session_approved_tools: *std.StringHashMap(void),
    permission_rules: ?*permission_rules_mod.Store,
    cloud_telemetry_opt_in: bool,
    control_plane_url: []const u8,
    control_plane_token: []const u8,
    /// False when the workspace is not a git repository. Git tools are then
    /// refused at dispatch with a directive message, instead of being run and
    /// failing with a confusing "fatal: not a git repository" that weak models
    /// retry in a loop. Defaults true so non-main call sites are unaffected.
    is_git_repo: bool = true,
    /// Additional workspace roots registered via `/add-dir`. Paths inside any
    /// of these are treated as in-bounds by the sandbox, just like paths
    /// inside `cwd`. The slice is borrowed -- the runtime owns its lifetime
    /// for the session. Defaults empty so non-main call sites are unaffected.
    additional_directories: []const []const u8 = &.{},
    /// Live Claude Code permission mode for this session, threaded from the REPL
    /// (Shift+Tab cycling, Task 3). When set, the gate prefers its reference
    /// spelling over `cfg.approval_mode` so the reference modes
    /// (default/acceptEdits/plan/bypassPermissions/dontAsk) drive decisions at
    /// runtime. When null (the default), the gate uses `cfg.approval_mode`
    /// byte-for-byte so legacy tiered-auto/manual/strict behavior is unchanged.
    permission_mode_override: ?permission_decision.Mode = null,
    /// bash-shell-02: absolute path to the session's shell environment
    /// snapshot, or null. Threaded into the Bash tool request so the model's
    /// shell commands source the user's captured aliases/functions. Borrowed
    /// -- the runtime owns the lifetime. Null at non-main call sites.
    shell_snapshot_path: ?[]const u8 = null,
    /// Phase 9 Task 1: secondary-summarization context for WebFetch's `prompt`
    /// pass. Carries the model-call trampoline + provider/model so the WebFetch
    /// handler can run a small/fast-model summarization. Null at call sites
    /// without model-call plumbing (tests, headless paths); WebFetch then
    /// returns raw stripped content as before. Borrowed -- the runtime owns it.
    web_fetch_ctx: ?web_summarize.SummarizeContext = null,
    /// Phase 10 Task 5 (memory-01): when set, this context belongs to the
    /// turn-end memory-extraction fork. Tool execution is then constrained to
    /// the auto-memory allowlist at dispatch time: Edit/Write/MultiEdit are
    /// denied unless their target path is `auto_mem_dir`-prefixed, and any
    /// non-read-only Bash command is denied. Null at every normal call site so
    /// the main loop is byte-for-byte unaffected. Ports
    /// createAutoMemCanUseTool's runtime gate. The slice is borrowed -- the
    /// extraction caller owns its lifetime for the fork.
    auto_mem_dir: ?[]const u8 = null,
    /// Phase 10 Task 6 (memory-05): when set, this context belongs to the
    /// per-session memory summarizer fork. Tool execution is then constrained to
    /// Read (any path, since Edit needs a prior Read) and Edit on this exact
    /// notes file; every other tool is denied. Null at every normal call site so
    /// the main loop is byte-for-byte unaffected. Ports
    /// createMemoryFileCanUseTool's runtime gate. The slice is borrowed -- the
    /// summarizer caller owns its lifetime for the fork.
    session_mem_file: ?[]const u8 = null,
    /// sdk-headless-05 (can_use_tool relay): when set, the session is
    /// host-driven (input-format stream-json) and tool-permission prompts are
    /// relayed to the SDK host via a `can_use_tool` control_request instead of
    /// the local stdin prompt or non-interactive auto-deny. The handler wraps a
    /// `sdk.structured_io.RelayApprover`. This wins over the REPL
    /// `approval_handler` and the stdin fallback in `effectiveApproval`. Null at
    /// every local (non-host-driven) call site so the gate is unchanged there.
    sdk_relay: ?ApprovalHandler = null,
};

/// Resolve the approval-mode string the gate evaluates under: a live permission
/// mode override wins (mapped to its canonical reference spelling), otherwise
/// the persisted config mode. Single source of truth so the gate has one
/// decision site rather than branching its logic.
pub fn effectiveApprovalMode(ctx: ToolExecContext) []const u8 {
    if (ctx.permission_mode_override) |mode| {
        return permission_decision.modeToString(mode);
    }
    return ctx.cfg.approval_mode;
}

/// bash-shell-09: true when the acceptEdits permission mode should auto-allow
/// this invocation without prompting -- the canonical bash tool, the effective
/// mode is acceptEdits, the args carry a `command`, and that command is a
/// fully-filesystem compound per bash_mode_allow. Pure decision (no IO); the
/// gate runs it AFTER the explicit deny/allow rule block so a `deny Bash(...)`
/// rule still wins. A missing/non-string command -> false (passthrough).
fn acceptEditsBashAutoAllows(effective_name: []const u8, mode_str: []const u8, args: []const u8) bool {
    if (!matchesToolName(effective_name, &.{ "shell", "Bash", "bash" })) return false;
    if (permission_decision.modeFromString(mode_str) != .acceptEdits) return false;
    const command = tool_registry.getArg(args, "command") orelse return false;
    return bash_mode_allow.acceptEditsAutoAllows(command);
}

/// tools-13: result of resolving the per-call sandbox profile for a bash tool
/// invocation that may carry the model-facing `dangerouslyDisableSandbox` flag.
pub const SandboxProfileResolution = struct {
    /// The sandbox profile to actually run this call under.
    profile: []const u8,
    /// True when the model asked for full access via the flag but enterprise
    /// policy locked the sandbox, so the flag was ignored. Callers surface this
    /// as a note (the model must know its request did not take effect).
    ignored_by_policy: bool = false,
};

/// Resolve the effective sandbox profile for a bash tool call.
///
/// When the args carry `dangerouslyDisableSandbox: true` and the tool is a bash
/// variant, map the call to the `danger-full-access` profile for this single
/// invocation -- UNLESS the admin has locked the sandbox via managed settings
/// (`policy_locks_sandbox`), in which case the flag is ignored and the base
/// profile stands. A model-supplied flag must never override an admin lockdown.
///
/// Pure decision (no IO). Non-bash tools and a missing/false flag pass the base
/// profile through unchanged.
fn resolveBashSandboxProfile(
    effective_name: []const u8,
    args: []const u8,
    base_profile: []const u8,
    policy_locks_sandbox: bool,
) SandboxProfileResolution {
    if (!matchesToolName(effective_name, &.{ "shell", "Bash", "bash" })) {
        return .{ .profile = base_profile };
    }
    const raw = tool_registry.getArg(args, "dangerouslyDisableSandbox") orelse return .{ .profile = base_profile };
    if (!arg_parse.parseBool(raw)) return .{ .profile = base_profile };
    if (policy_locks_sandbox) {
        // Admin locked the sandbox key; ignore the model's override request.
        return .{ .profile = base_profile, .ignored_by_policy = true };
    }
    return .{ .profile = "danger-full-access" };
}

fn formatPermissionRuleReason(allocator: std.mem.Allocator, prefix: []const u8, matched: permission_rules_mod.Match) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const writer = out.writer();
    const rule = matched.rule;

    try writer.print("{s}: rule #{d} {s} tool={s}", .{
        prefix,
        matched.index + 1,
        rule.action.toString(),
        rule.tool,
    });
    if (rule.args_contains.len > 0) {
        try writer.print(" args_contains=\"{s}\"", .{rule.args_contains});
    } else {
        try writer.writeAll(" args_contains=<any>");
    }
    try writer.writeAll(" scope=");
    switch (rule.scope) {
        .global => try writer.writeAll("global"),
        .workspace => |path| try writer.print("workspace:{s}", .{path}),
    }
    if (rule.source_path.len > 0) {
        if (rule.source_line > 0) {
            try writer.print(" source={s}:{d}", .{ rule.source_path, rule.source_line });
        } else {
            try writer.print(" source={s}", .{rule.source_path});
        }
    }
    return out.toOwnedSlice();
}

const EffectiveApproval = struct { ctx: ?*anyopaque, prompt: ?ApprovalPromptFn };

/// Resolve which approver to use for a tool prompt. Non-interactive runs
/// have none (the gate auto-denies). Interactive runs prefer the
/// front-end's installed `approval_handler`; otherwise they fall back to
/// the built-in stdin approver bound to `stdin_token`. Single source of
/// truth for both the permission-rule prompt and the main approval gate.
fn effectiveApproval(ctx: ToolExecContext, stdin_token: *u8) EffectiveApproval {
    // sdk-headless-05: a host-driven session (input-format stream-json) relays
    // permission prompts to the SDK host via `can_use_tool`. This wins over
    // everything below -- including the `!interactive` short-circuit -- because
    // the relay IS the (non-stdin) interactivity for a headless host-driven
    // run. Without it, a non-interactive run would auto-deny.
    if (ctx.sdk_relay) |relay| return .{ .ctx = relay.ctx, .prompt = relay.prompt };
    if (!ctx.interactive) return .{ .ctx = null, .prompt = null };
    if (ctx.approval_handler) |h| return .{ .ctx = h.ctx, .prompt = h.prompt };
    return .{ .ctx = @ptrCast(stdin_token), .prompt = stdinApprovalPromptWithCtx };
}

/// The interactivity flag the approval gate (`approval.evaluate`) runs under. A
/// host-driven session (sdk-headless-05 `sdk_relay` set) is "interactive" for
/// gate purposes -- the `can_use_tool` relay can produce a decision -- so the
/// gate must not auto-deny it on the `!interactive` short-circuit. Otherwise it
/// is `ctx.interactive` unchanged. Single source of truth so every evaluate
/// call site agrees with `effectiveApproval`.
fn effectiveInteractive(ctx: ToolExecContext) bool {
    return ctx.interactive or ctx.sdk_relay != null;
}

fn promptForPermissionRule(
    ctx: ToolExecContext,
    matched: permission_rules_mod.Match,
    name: []const u8,
    args: []const u8,
    risk: types.RiskTier,
) !approval_mod.Decision {
    var stdin_prompt_token: u8 = 0;
    const approver = effectiveApproval(ctx, &stdin_prompt_token);

    var desc_buf: [512]u8 = undefined;
    const tool_description = buildApprovalDescription(&desc_buf, name, args, risk);
    const rule_reason = try formatPermissionRuleReason(ctx.allocator, "permission rule asks before running tool", matched);
    defer ctx.allocator.free(rule_reason);
    const message = try std.fmt.allocPrint(ctx.allocator, "{s}\n{s}", .{ rule_reason, tool_description });
    defer ctx.allocator.free(message);

    return approval_mod.evaluate(
        "manual",
        risk,
        false,
        effectiveInteractive(ctx),
        false,
        false,
        approver.ctx,
        approver.prompt,
        message,
    );
}

/// Bypass-immune path-safety gate for edit/write tools. Runs BEFORE the
/// yolo/sandbox short-circuit so a dangerous edit (.git/, .bashrc,
/// .claude/settings.json, ...) prompts or blocks even when yolo_mode is
/// set -- the only gate yolo does NOT win, mirroring reference step 1g
/// (permissions.ts:1252-1260, where safetyCheck is surfaced as an `ask`
/// that survives bypass mode).
///
/// Returns a blocked/denied ToolTrace when the path is unsafe and the
/// user does not approve (or cannot, in non-interactive runs). Returns
/// null when the tool is not an edit/write, the path is safe, or the
/// user approves the prompt (the call proceeds normally afterward).
/// Phase 10 Task 5 (memory-01): execution-time enforcement for the turn-end
/// memory-extraction fork. Returns a finished `deny` trace when the requested
/// tool call is outside the auto-memory allowlist, or null when the call may
/// proceed to the normal dispatch path. Only consulted when
/// `ctx.auto_mem_dir != null` (i.e. inside the extraction child). Ports
/// createAutoMemCanUseTool's runtime gate
/// (extractMemories.ts:171-222):
///   - Read/Grep/Glob: always allowed.
///   - Bash: allowed only when the command is non-mutating (read-only).
///   - Edit/Write/MultiEdit: allowed only when file_path/path is under the
///     auto-memory dir.
///   - anything else: denied.
fn autoMemGate(ctx: ToolExecContext, name: []const u8, args: []const u8, start: i64) !?ToolTrace {
    const mem_dir = ctx.auto_mem_dir orelse return null;

    // Read context tools are inherently safe.
    if (matchesToolName(name, &.{ "Read", "read", "file_read", "Grep", "grep", "Glob", "glob" })) {
        return null;
    }

    // Bash: only non-mutating (read-only) commands.
    if (matchesToolName(name, &.{ "Bash", "bash", "shell" })) {
        const bash_security = @import("tools/bash_security.zig");
        const command = arg_parse.getArg(args, "command") orelse args;
        if (!bash_security.isMutatingCommand(command)) return null;
        return try autoMemDenyTrace(
            ctx,
            name,
            args,
            start,
            "auto-memory extraction context: only read-only shell commands are permitted (ls, find, grep, cat, stat, wc, head, tail, and similar). Mutating Bash commands are denied.",
        );
    }

    // Edit/Write/MultiEdit: target must be inside the auto-memory dir.
    if (matchesToolName(name, &.{ "Edit", "edit", "file_edit", "Write", "write", "file_write", "MultiEdit", "multi_edit", "file_multi_edit" })) {
        const path = arg_parse.getArg(args, "file_path") orelse
            arg_parse.getArg(args, "path") orelse
            return try autoMemDenyTrace(ctx, name, args, start, "auto-memory extraction context: write tools require a file_path inside the memory directory.");
        if (pathWithin(mem_dir, path)) return null;
        const reason = try std.fmt.allocPrint(
            ctx.allocator,
            "auto-memory extraction context: '{s}' is outside the memory directory '{s}'. Edit/Write/MultiEdit are only permitted for paths inside the memory directory.",
            .{ path, mem_dir },
        );
        defer ctx.allocator.free(reason);
        return try autoMemDenyTrace(ctx, name, args, start, reason);
    }

    // Everything else (WebFetch, AgentRun, MCP, git, ...) is denied.
    return try autoMemDenyTrace(ctx, name, args, start, "auto-memory extraction context: only Read, Grep, Glob, read-only Bash, and Edit/Write within the memory directory are allowed.");
}

/// Build a finished `deny` trace for an auto-mem-gated tool refusal.
fn autoMemDenyTrace(ctx: ToolExecContext, name: []const u8, args: []const u8, start: i64, reason: []const u8) !ToolTrace {
    const output = try ctx.allocator.dupe(u8, reason);
    const trace = try buildToolTrace(ctx.allocator, name, args, .BLOCKED, .blocked, false, 0, output);
    logToolInvocationRecord(ctx.allocator, ctx.audit, ctx.cloud_telemetry_opt_in, ctx.control_plane_url, ctx.control_plane_token, trace, start, start, 1);
    return trace;
}

/// Phase 10 Task 6 (memory-05): execution-time enforcement for the per-session
/// memory summarizer fork. Returns a finished `deny` trace when the requested
/// tool call is outside the Read+Edit-on-the-notes-file allowlist, or null when
/// the call may proceed to the normal dispatch path. Only consulted when
/// `ctx.session_mem_file != null` (i.e. inside the summarizer child). Ports
/// createMemoryFileCanUseTool (SessionMemory/sessionMemory.ts:460-482):
///   - Read: always allowed (Edit requires a prior Read of the same file).
///   - Edit: allowed only when file_path equals the exact notes file.
///   - anything else: denied.
fn sessionMemGate(ctx: ToolExecContext, name: []const u8, args: []const u8, start: i64) !?ToolTrace {
    const notes = ctx.session_mem_file orelse return null;
    const session_memory = @import("core/session_memory.zig");
    switch (session_memory.gate(notes, name, args)) {
        .allow => return null,
        .deny => {
            const reason = try std.fmt.allocPrint(
                ctx.allocator,
                "session-memory summarizer context: only Read and Edit on '{s}' are allowed; all other tools (and Edits to other paths) are denied.",
                .{notes},
            );
            defer ctx.allocator.free(reason);
            return try autoMemDenyTrace(ctx, name, args, start, reason);
        },
    }
}

/// True when `path` is `base` itself or a descendant of `base`. Tolerant of a
/// trailing separator on `base` (getAutoMemPath's override branches add one;
/// the default leaf does not). Pure string-prefix check matching
/// memory_gate.isAutoMemPath's child semantics, applied here without an
/// allocator so the hot dispatch path stays allocation-free.
fn pathWithin(base: []const u8, path: []const u8) bool {
    const base_trim = std.mem.trimEnd(u8, base, "/\\");
    if (base_trim.len == 0) return false;
    if (std.mem.eql(u8, path, base_trim)) return true;
    if (path.len > base_trim.len and
        std.mem.startsWith(u8, path, base_trim) and
        (path[base_trim.len] == '/' or path[base_trim.len] == '\\'))
    {
        return true;
    }
    return false;
}

fn pathSafetyGate(ctx: ToolExecContext, name: []const u8, args: []const u8, start: i64) !?ToolTrace {
    if (!approval_mod.isEditTool(name)) return null;

    const path = arg_parse.getArg(args, "path") orelse
        arg_parse.getArg(args, "file_path") orelse
        return null;

    const verdict = path_safety_mod.check(path);
    if (verdict.isSafe()) return null;

    const detail = switch (verdict) {
        .safe => unreachable,
        .dangerous_dir => |dir| try std.fmt.allocPrint(ctx.allocator, "'{s}' is inside the sensitive directory '{s}'", .{ path, dir }),
        .dangerous_file => |f| try std.fmt.allocPrint(ctx.allocator, "'{s}' is a sensitive file ({s})", .{ path, f }),
        .suspicious_pattern => try std.fmt.allocPrint(ctx.allocator, "'{s}' contains a suspicious path pattern", .{path}),
    };
    defer ctx.allocator.free(detail);

    // Non-interactive: cannot prompt, so block. yolo does not bypass.
    if (!ctx.interactive) {
        const output = try std.fmt.allocPrint(
            ctx.allocator,
            "edit blocked by path-safety guard: {s}. Editing it is a code-execution/exfiltration vector and requires explicit user approval, which is unavailable in a non-interactive run. This guard is enforced even in bypass/yolo mode.",
            .{detail},
        );
        const trace = try buildToolTrace(ctx.allocator, name, args, .BLOCKED, .blocked, false, 0, output);
        logToolInvocationRecord(ctx.allocator, ctx.audit, ctx.cloud_telemetry_opt_in, ctx.control_plane_url, ctx.control_plane_token, trace, start, start, 1);
        return trace;
    }

    // Interactive: prompt the user even in yolo mode.
    var stdin_prompt_token: u8 = 0;
    const approver = effectiveApproval(ctx, &stdin_prompt_token);
    const message = try std.fmt.allocPrint(
        ctx.allocator,
        "Path-safety check: {s}. Editing it is a code-execution/exfiltration vector. Allow this edit?",
        .{detail},
    );
    defer ctx.allocator.free(message);

    const approval = try approval_mod.evaluate(
        "manual",
        .HIGH,
        true,
        effectiveInteractive(ctx),
        false,
        false, // yolo_mode deliberately false here: this gate is bypass-immune
        approver.ctx,
        approver.prompt,
        message,
    );

    if (!approval.approved) {
        const output = try std.fmt.allocPrint(
            ctx.allocator,
            "edit denied by path-safety guard: {s}. The user did not approve editing this sensitive path.",
            .{detail},
        );
        const trace = try buildToolTrace(ctx.allocator, name, args, .BLOCKED, approval.state, false, 0, output);
        logToolInvocationRecord(ctx.allocator, ctx.audit, ctx.cloud_telemetry_opt_in, ctx.control_plane_url, ctx.control_plane_token, trace, start, start, 1);
        return trace;
    }

    // Approved: fall through to normal execution.
    return null;
}

fn buildToolArgRepairGuidance(allocator: std.mem.Allocator, name: []const u8, args: []const u8) !?[]u8 {
    if (matchesToolName(name, &.{ "file_write", "Write", "write" })) {
        if (!hasAnyArg(args, &.{ "path", "file_path" })) {
            return try allocator.dupe(u8, "tool call rejected before execution: Write requires `path` (or `file_path`) and `content`. Retry with Write(path=..., content=...).");
        }
        if (!hasAnyArg(args, &.{"content"})) {
            return try allocator.dupe(u8, "tool call rejected before execution: Write requires `content`. Use Edit/MultiEdit for targeted replacements, or retry with Write(path=..., content=...).");
        }
    } else if (matchesToolName(name, &.{ "file_edit", "Edit", "edit" })) {
        if (!hasAnyArg(args, &.{ "path", "file_path" })) {
            return try allocator.dupe(u8, "tool call rejected before execution: Edit requires `path` (or `file_path`) plus `find`/`replace` or `old_string`/`new_string`.");
        }
        if (!hasAnyArg(args, &.{ "find", "old_string" })) {
            return try allocator.dupe(u8, "tool call rejected before execution: Edit requires the exact text to replace via `find` or `old_string`. Read the file first if needed, then retry with Edit(path=..., find=..., replace=...).");
        }
    } else if (matchesToolName(name, &.{ "MultiEdit", "multi_edit", "file_multi_edit" })) {
        if (!hasAnyArg(args, &.{ "path", "file_path" })) {
            return try allocator.dupe(u8, "tool call rejected before execution: MultiEdit requires `path` (or `file_path`) and `edits`.");
        }
        if (!hasAnyArg(args, &.{"edits"})) {
            return try allocator.dupe(u8, "tool call rejected before execution: MultiEdit requires `edits`, a JSON array of old_string/new_string objects.");
        }
    } else if (matchesToolName(name, &.{ "shell", "Bash", "bash" })) {
        if (!hasAnyArg(args, &.{"command"}) and std.mem.trim(u8, args, " \t\r\n").len == 0) {
            return try allocator.dupe(u8, "tool call rejected before execution: Bash requires `command`.");
        }
    } else if (matchesToolName(name, &.{"git_apply"})) {
        if (!hasAnyArg(args, &.{"patch"})) {
            return try allocator.dupe(u8, "tool call rejected before execution: git_apply requires `patch` containing a unified diff.");
        }
    }

    return null;
}

/// bash-shell-04: per-segment permission evaluation for compound/piped Bash
/// commands. Runs BEFORE the whole-args `decide` so a denying or asking
/// segment short-circuits the single-rule match (avoids double-prompting).
///
/// Returns a finished `ToolTrace` when the segmented evaluation reaches a
/// verdict that should end the call here (deny -> denied trace; ask the user
/// declined -> denied trace) or that the call may proceed (allow / approved
/// ask -> the executed trace via `runApprovedToolTrace`). Returns null when
/// this command is NOT a compound/piped Bash command, in which case the
/// caller falls through to the normal single-command rule flow.
fn segmentedBashPermission(
    ctx: ToolExecContext,
    name: []const u8,
    args: []const u8,
    risk: types.RiskTier,
    start: i64,
    // hooks-20: the PreToolUse hook already ran upstream in executeToolCall; hand
    // its result to runApprovedToolTrace so the command hook is not run twice.
    pre_hook_done: ?*hooks_mod.HookRunResult,
) !?ToolTrace {
    const rules = ctx.permission_rules orelse return null;
    if (!matchesToolName(name, &.{ "shell", "Bash", "bash" })) return null;
    const command = arg_parse.getArg(args, "command") orelse return null;
    if (!bash_segment_permission.isCompoundOrPiped(command)) return null;

    var verdict = try bash_segment_permission.evaluate(ctx.allocator, rules, ctx.cwd, name, command);
    defer verdict.deinit(ctx.allocator);

    switch (verdict.decision) {
        .allow => {
            return try runApprovedToolTrace(ctx, name, args, risk, .user_approved, start, pre_hook_done);
        },
        .deny => {
            const output = try std.fmt.allocPrint(ctx.allocator, "denied by permission rule: {s}", .{verdict.reason});
            const trace = try buildToolTrace(ctx.allocator, name, args, risk, .denied, false, 0, output);
            logToolInvocationRecord(ctx.allocator, ctx.audit, ctx.cloud_telemetry_opt_in, ctx.control_plane_url, ctx.control_plane_token, trace, start, start, 1);
            return trace;
        },
        .ask => {
            if (ctx.session_approved_tools.contains(name)) {
                return try runApprovedToolTrace(ctx, name, args, risk, .session_approved, start, pre_hook_done);
            }
            const message = try buildSegmentedAskMessage(ctx.allocator, name, args, risk, verdict.reason, verdict.suggestions);
            defer ctx.allocator.free(message);

            var stdin_prompt_token: u8 = 0;
            const approver = effectiveApproval(ctx, &stdin_prompt_token);
            const approval = try approval_mod.evaluate(
                "manual",
                risk,
                false,
                effectiveInteractive(ctx),
                false,
                false,
                approver.ctx,
                approver.prompt,
                message,
            );
            if (approval.state == .session_approved) {
                const key = try ctx.allocator.dupe(u8, name);
                errdefer ctx.allocator.free(key);
                try ctx.session_approved_tools.put(key, {});
            }
            if (!approval.approved) {
                const output = try std.fmt.allocPrint(ctx.allocator, "permission rule requires approval: {s}", .{verdict.reason});
                const trace = try buildToolTrace(ctx.allocator, name, args, risk, approval.state, false, 0, output);
                logToolInvocationRecord(ctx.allocator, ctx.audit, ctx.cloud_telemetry_opt_in, ctx.control_plane_url, ctx.control_plane_token, trace, start, start, 1);
                return trace;
            }
            return try runApprovedToolTrace(ctx, name, args, risk, approval.state, start, pre_hook_done);
        },
    }
}

/// Compose the approval-prompt message for a segmented Bash ask: the
/// per-segment reason plus, when available, the reusable allow-rule prefix
/// suggestions the user can add going forward (the missing half of the
/// permission UX). Owned; caller frees.
fn buildSegmentedAskMessage(
    allocator: std.mem.Allocator,
    name: []const u8,
    args: []const u8,
    risk: types.RiskTier,
    reason: []const u8,
    suggestions: []const []u8,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const writer = out.writer();

    var desc_buf: [512]u8 = undefined;
    const tool_description = buildApprovalDescription(&desc_buf, name, args, risk);
    try writer.print("{s}\n{s}", .{ reason, tool_description });
    if (suggestions.len > 0) {
        try writer.writeAll("\nSuggested allow-rules:");
        for (suggestions) |s| {
            try writer.print(" {s}({s})", .{ name, s });
        }
    }
    return out.toOwnedSlice();
}

pub fn executeToolCall(ctx: ToolExecContext, name: []const u8, args: []const u8) !ToolTrace {
    const start = clock.nowSeconds();
    var stdin_prompt_token: u8 = 0;
    const effective_name = canonicalToolNameForArgs(name, args);

    // Refuse git tools in a non-git workspace at dispatch: weak models call
    // GitStatus from habit even when it isn't advertised, and running it just
    // yields "fatal: not a git repository" which they retry in a loop. Return a
    // directive instead of executing git.
    if (!ctx.is_git_repo and isGitTool(effective_name)) {
        const output = try ctx.allocator.dupe(u8, "git tools are unavailable here: this workspace is not a git repository. Do NOT call GitStatus/GitDiff/GitLog/GitCommit. If you need version control, ask the user to run `git init` first; otherwise proceed without git (e.g. create files with Write).");
        const trace = try buildToolTrace(ctx.allocator, effective_name, args, .LOW, .blocked, false, 0, output);
        logToolInvocationRecord(ctx.allocator, ctx.audit, ctx.cloud_telemetry_opt_in, ctx.control_plane_url, ctx.control_plane_token, trace, start, start, 1);
        return trace;
    }

    if (ctx.active_agent) |agent| {
        if (!agents_mod.allowsTool(&agent, effective_name)) {
            const output = try std.fmt.allocPrint(ctx.allocator, "tool blocked by active agent policy: {s}", .{agent.name});
            const trace = try buildToolTrace(ctx.allocator, effective_name, args, .BLOCKED, .blocked, false, 0, output);
            logToolInvocationRecord(ctx.allocator, ctx.audit, ctx.cloud_telemetry_opt_in, ctx.control_plane_url, ctx.control_plane_token, trace, start, start, 1);
            return trace;
        }
    }

    // Phase 10 Task 5 (memory-01): auto-memory extraction fork allowlist.
    // No-op (returns null) at every normal call site since auto_mem_dir is null
    // there. Inside the extraction child it denies any tool outside the
    // Read/Grep/Glob + read-only-Bash + Edit/Write-within-memory-dir allowlist.
    if (try autoMemGate(ctx, effective_name, args, start)) |trace| {
        return trace;
    }

    // Phase 10 Task 6 (memory-05): session-memory summarizer allowlist.
    // No-op (returns null) at every normal call site since session_mem_file is
    // null there. Inside the summarizer child it denies any tool except Read
    // and Edit on the one notes file.
    if (try sessionMemGate(ctx, effective_name, args, start)) |trace| {
        return trace;
    }

    // Bypass-immune path-safety gate: must run BEFORE the yolo/sandbox
    // short-circuit so a dangerous edit prompts/blocks even in yolo mode.
    if (try pathSafetyGate(ctx, effective_name, args, start)) |trace| {
        return trace;
    }

    const sandbox_decision = sandbox_mod.authorizeToolYoloDirs(ctx.cfg.sandbox, ctx.cwd, ctx.additional_directories, effective_name, args, ctx.yolo_mode);
    if (!sandbox_decision.allowed) {
        // Surface a transient prompt-line footer hint by bumping the recent
        // violation counter the REPL reads each frame (ui-render-12).
        sandbox_mod.recordViolation();
        const output = try ctx.allocator.dupe(u8, sandbox_decision.reason);
        const trace = try buildToolTrace(ctx.allocator, effective_name, args, .BLOCKED, .blocked, false, 0, output);
        logToolInvocationRecord(ctx.allocator, ctx.audit, ctx.cloud_telemetry_opt_in, ctx.control_plane_url, ctx.control_plane_token, trace, start, start, 1);
        return trace;
    }

    const risk = ctx.policy.classifyTool(effective_name, args);
    if (risk == .BLOCKED) {
        const output = try ctx.allocator.dupe(u8, "blocked by policy");
        const trace = try buildToolTrace(ctx.allocator, effective_name, args, risk, .blocked, false, 0, output);
        logToolInvocationRecord(ctx.allocator, ctx.audit, ctx.cloud_telemetry_opt_in, ctx.control_plane_url, ctx.control_plane_token, trace, start, start, 1);
        return trace;
    }

    if (try buildToolArgRepairGuidance(ctx.allocator, effective_name, args)) |output| {
        const trace = try buildToolTrace(ctx.allocator, effective_name, args, risk, .auto_approved, false, 0, output);
        logToolInvocationRecord(ctx.allocator, ctx.audit, ctx.cloud_telemetry_opt_in, ctx.control_plane_url, ctx.control_plane_token, trace, start, start, 1);
        return trace;
    }

    // hooks-20: run the PreToolUse hook ONCE here, before the approval decision,
    // so its `hookSpecificOutput.permissionDecision` can feed the permission
    // engine (reference types/hooks.ts:73-76 -- the decision gates the tool before
    // it runs). The result is handed off to runApprovedToolTrace below so the
    // command hook is never run twice. `pre_hook` is owned here and freed on
    // return.
    //
    //   deny / decision-block -> the hook blocks the tool (existing behavior).
    //   allow                 -> skip the permission UI entirely (auto-approve).
    //   ask                   -> force a prompt even if rules/mode would allow.
    //   updatedInput          -> runApprovedToolTrace rewrites the args.
    //   none                  -> fall through to the normal approval flow.
    var pre_hook = try runHooksWithTrustPrompt(ctx.allocator, ctx.cwd, ctx.ask_user_fn, ctx.ask_user_ctx, .{
        .event = .pre_tool_use,
        .cwd = ctx.cwd,
        .tool_name = effective_name,
        .tool_args = args,
    });
    defer pre_hook.deinit(ctx.allocator);

    switch (preToolHookAction(pre_hook)) {
        .deny => {
            const output = if (pre_hook.output.len > 0)
                try ctx.allocator.dupe(u8, pre_hook.output)
            else if (pre_hook.permission_reason) |r|
                try ctx.allocator.dupe(u8, r)
            else
                try ctx.allocator.dupe(u8, "blocked by pre-tool-use hook");
            const trace = try buildToolTrace(ctx.allocator, effective_name, args, risk, .blocked, false, 0, output);
            logToolInvocationRecord(ctx.allocator, ctx.audit, ctx.cloud_telemetry_opt_in, ctx.control_plane_url, ctx.control_plane_token, trace, start, start, 1);
            return trace;
        },
        .allow => {
            // Auto-approve: bypass every permission gate below and run the tool.
            return runApprovedToolTrace(ctx, effective_name, args, risk, .user_approved, start, &pre_hook);
        },
        .ask => {
            // Force a prompt regardless of what rules/mode would have decided. A
            // non-interactive run cannot prompt, so the tool is blocked.
            var ask_token: u8 = 0;
            const approver = effectiveApproval(ctx, &ask_token);
            var desc_buf: [512]u8 = undefined;
            const tool_description = buildApprovalDescription(&desc_buf, effective_name, args, risk);
            const message = if (pre_hook.permission_reason) |r|
                try std.fmt.allocPrint(ctx.allocator, "pre-tool-use hook asks before running tool: {s}\n{s}", .{ r, tool_description })
            else
                try std.fmt.allocPrint(ctx.allocator, "pre-tool-use hook asks before running tool\n{s}", .{tool_description});
            defer ctx.allocator.free(message);
            const approval = try approval_mod.evaluate(
                "manual",
                risk,
                false,
                effectiveInteractive(ctx),
                false,
                false, // yolo_mode deliberately false: a hook `ask` forces the prompt
                approver.ctx,
                approver.prompt,
                message,
            );
            if (approval.state == .session_approved) {
                const key = try ctx.allocator.dupe(u8, effective_name);
                errdefer ctx.allocator.free(key);
                try ctx.session_approved_tools.put(key, {});
            }
            if (!approval.approved) {
                const output = try ctx.allocator.dupe(u8, approval.reason);
                const trace = try buildToolTrace(ctx.allocator, effective_name, args, risk, approval.state, false, 0, output);
                logToolInvocationRecord(ctx.allocator, ctx.audit, ctx.cloud_telemetry_opt_in, ctx.control_plane_url, ctx.control_plane_token, trace, start, start, 1);
                return trace;
            }
            return runApprovedToolTrace(ctx, effective_name, args, risk, approval.state, start, &pre_hook);
        },
        .none => {}, // fall through to the normal approval flow below
    }

    // bash-shell-04: for compound/piped Bash commands, evaluate each segment
    // through the rule store (deny if any denies, ask if any asks) plus the
    // multi-cd and cd+git bare-repo guards. This MUST run before the whole-args
    // `decide` below so a segment verdict short-circuits the single-rule match
    // and we never double-prompt. Returns null for non-compound commands.
    if (try segmentedBashPermission(ctx, effective_name, args, risk, start, &pre_hook)) |trace| {
        return trace;
    }

    if (ctx.permission_rules) |rules| {
        // Behavior-class precedence (deny-wins, then ask, then allow), not the
        // legacy latest-matching-rule-wins of match(). A deny rule anywhere beats
        // an allow rule anywhere. `decided.match` borrows into rules.items.
        if (rules.decide(ctx.cwd, effective_name, args)) |decided| {
            const matched_rule = decided.match;
            switch (decided.action) {
                .deny => {
                    const output = try formatPermissionRuleReason(ctx.allocator, "denied by permission rule", matched_rule);
                    const trace = try buildToolTrace(ctx.allocator, effective_name, args, risk, .denied, false, 0, output);
                    logToolInvocationRecord(ctx.allocator, ctx.audit, ctx.cloud_telemetry_opt_in, ctx.control_plane_url, ctx.control_plane_token, trace, start, start, 1);
                    return trace;
                },
                .allow => {
                    return runApprovedToolTrace(ctx, effective_name, args, risk, .user_approved, start, &pre_hook);
                },
                .ask => {
                    if (ctx.session_approved_tools.contains(effective_name)) {
                        return runApprovedToolTrace(ctx, effective_name, args, risk, .session_approved, start, &pre_hook);
                    }
                    const approval = try promptForPermissionRule(ctx, matched_rule, effective_name, args, risk);
                    if (approval.state == .session_approved) {
                        const key = try ctx.allocator.dupe(u8, effective_name);
                        errdefer ctx.allocator.free(key);
                        try ctx.session_approved_tools.put(key, {});
                    }
                    if (!approval.approved) {
                        const output = try formatPermissionRuleReason(ctx.allocator, "permission rule requires approval", matched_rule);
                        const trace = try buildToolTrace(ctx.allocator, effective_name, args, risk, approval.state, false, 0, output);
                        logToolInvocationRecord(ctx.allocator, ctx.audit, ctx.cloud_telemetry_opt_in, ctx.control_plane_url, ctx.control_plane_token, trace, start, start, 1);
                        return trace;
                    }
                    return runApprovedToolTrace(ctx, effective_name, args, risk, approval.state, start, &pre_hook);
                },
            }
        }
    }

    // bash-shell-09: acceptEdits mode auto-allows a fixed set of filesystem bash
    // commands (mkdir/touch/rm/rmdir/mv/cp/sed), mirroring the reference's
    // checkPermissionMode (modeValidation.ts:58-71). This runs AFTER the explicit
    // deny/allow rule block above (so a `deny Bash(...)` rule still wins) and only
    // for the canonical bash tool when the effective mode is acceptEdits. A
    // command that is not fully filesystem (e.g. python, or a mixed compound)
    // falls through to the generic gate. The decision is mode-driven (distinct
    // from rule/session allows), recorded as .auto_approved.
    if (acceptEditsBashAutoAllows(effective_name, effectiveApprovalMode(ctx), args)) {
        return runApprovedToolTrace(ctx, effective_name, args, risk, .auto_approved, start, &pre_hook);
    }

    // Check if this tool was already session-approved
    if (ctx.session_approved_tools.contains(effective_name)) {
        return runApprovedToolTrace(ctx, effective_name, args, risk, .session_approved, start, &pre_hook);
    }

    // Build descriptive approval message
    var desc_buf: [512]u8 = undefined;
    const tool_description = buildApprovalDescription(&desc_buf, effective_name, args, risk);

    const approver = effectiveApproval(ctx, &stdin_prompt_token);
    const approval = try approval_mod.evaluate(
        effectiveApprovalMode(ctx),
        risk,
        approval_mod.isEditTool(effective_name),
        effectiveInteractive(ctx),
        ctx.auto_approve_high or ctx.plan_approved,
        ctx.yolo_mode,
        approver.ctx,
        approver.prompt,
        tool_description,
    );

    // Store session-approved tools
    if (approval.state == .session_approved) {
        const key = try ctx.allocator.dupe(u8, effective_name);
        errdefer ctx.allocator.free(key);
        try ctx.session_approved_tools.put(key, {});
    }

    if (!approval.approved) {
        const output = try ctx.allocator.dupe(u8, approval.reason);
        const trace = try buildToolTrace(ctx.allocator, effective_name, args, risk, approval.state, false, 0, output);
        logToolInvocationRecord(ctx.allocator, ctx.audit, ctx.cloud_telemetry_opt_in, ctx.control_plane_url, ctx.control_plane_token, trace, start, start, 1);
        return trace;
    }

    return runApprovedToolTrace(ctx, effective_name, args, risk, approval.state, start, &pre_hook);
}

/// hooks-20: the approval action a PreToolUse hook's stdout JSON dictates.
/// Derived purely from the hook result so it is directly unit-testable:
///   - `.deny`  when the hook blocked (exit 2 / decision:block) OR returned
///     `permissionDecision:"deny"` -- the tool must not run.
///   - `.allow` when `permissionDecision:"allow"` -- skip the permission UI.
///   - `.ask`   when `permissionDecision:"ask"` -- force a prompt.
///   - `.none`  otherwise -- the normal approval flow decides.
/// `.deny` wins over the parsed permission so a blocking hook is never silently
/// auto-approved by a stray `allow`.
pub const PreToolHookAction = enum { none, allow, ask, deny };

pub fn preToolHookAction(result: hooks_mod.HookRunResult) PreToolHookAction {
    if (result.blocked or result.permission == .deny) return .deny;
    return switch (result.permission) {
        .allow => .allow,
        .ask => .ask,
        .deny => .deny,
        .none => .none,
    };
}

fn runHooksWithTrustPrompt(allocator: std.mem.Allocator, cwd: []const u8, ask_user_fn: ?agent_runtime.AskUserPromptFn, ask_user_ctx: ?*anyopaque, hook_ctx: hooks_mod.HookContext) !hooks_mod.HookRunResult {
    var hook_result = try hooks_mod.run(allocator, hook_ctx);
    if (!(hook_result.blocked and hook_result.trust_path != null and ask_user_fn != null and ask_user_ctx != null)) {
        return hook_result;
    }

    const trust_path = hook_result.trust_path.?;
    const question = try std.fmt.allocPrint(
        allocator,
        "Trust workspace hook {s}? The current fingerprint will be saved for future runs.",
        .{trust_path},
    );
    defer allocator.free(question);

    const answer = try ask_user_fn.?(ask_user_ctx.?, allocator, question, &.{ "trust", "block" });
    defer allocator.free(answer);
    if (!std.ascii.eqlIgnoreCase(answer, "trust")) return hook_result;

    const trust_msg = try security_mod.allowHook(allocator, cwd, trust_path);
    allocator.free(trust_msg);
    hook_result.deinit(allocator);
    return hooks_mod.run(allocator, hook_ctx);
}

fn toolExecErrorTrace(
    ctx: ToolExecContext,
    name: []const u8,
    args: []const u8,
    risk: types.RiskTier,
    approval_state: types.ApprovalState,
    start: i64,
    err: anyerror,
) !ToolTrace {
    const end = clock.nowSeconds();
    const output = try std.fmt.allocPrint(ctx.allocator, "tool execution error: {s}", .{@errorName(err)});
    const trace = try buildToolTrace(ctx.allocator, name, args, risk, approval_state, false, (end - start) * 1000, output);
    logToolInvocationRecord(ctx.allocator, ctx.audit, ctx.cloud_telemetry_opt_in, ctx.control_plane_url, ctx.control_plane_token, trace, start, end, 1);
    return trace;
}

fn runApprovedToolTrace(
    ctx: ToolExecContext,
    name: []const u8,
    args: []const u8,
    risk: types.RiskTier,
    approval_state: types.ApprovalState,
    start: i64,
    // hooks-20: when the PreToolUse hook was already run upstream (so its
    // permissionDecision could feed the approval step), the caller hands the
    // result off here so we do NOT re-run the command hook (which would fire its
    // side effects twice). When null we run the hook ourselves as before.
    pre_hook_done: ?*hooks_mod.HookRunResult,
) !ToolTrace {
    var pre_plugin = try plugins_mod.run(ctx.allocator, .{
        .event = .pre_tool_use,
        .cwd = ctx.cwd,
        .tool_name = name,
        .tool_args = args,
    });
    defer pre_plugin.deinit(ctx.allocator);

    if (pre_plugin.blocked) {
        const end = clock.nowSeconds();
        const output = if (pre_plugin.output.len > 0)
            try ctx.allocator.dupe(u8, pre_plugin.output)
        else
            try ctx.allocator.dupe(u8, "blocked by pre-tool-use plugin");
        const trace = try buildToolTrace(ctx.allocator, name, args, risk, .blocked, false, (end - start) * 1000, output);
        logToolInvocationRecord(ctx.allocator, ctx.audit, ctx.cloud_telemetry_opt_in, ctx.control_plane_url, ctx.control_plane_token, trace, start, end, 1);
        return trace;
    }

    // Reuse the upstream-run PreToolUse hook when handed off; otherwise run it
    // here. `owned_pre_hook` only holds a value when we ran it ourselves and is
    // therefore responsible for freeing it; a handed-off result is owned by the
    // caller.
    var owned_pre_hook: ?hooks_mod.HookRunResult = null;
    defer if (owned_pre_hook) |*h| h.deinit(ctx.allocator);
    const pre_hook: *hooks_mod.HookRunResult = if (pre_hook_done) |h| h else blk: {
        owned_pre_hook = try runHooksWithTrustPrompt(ctx.allocator, ctx.cwd, ctx.ask_user_fn, ctx.ask_user_ctx, .{
            .event = .pre_tool_use,
            .cwd = ctx.cwd,
            .tool_name = name,
            .tool_args = args,
        });
        break :blk &owned_pre_hook.?;
    };

    if (pre_hook.blocked) {
        const end = clock.nowSeconds();
        const output = if (pre_hook.output.len > 0)
            try ctx.allocator.dupe(u8, pre_hook.output)
        else
            try ctx.allocator.dupe(u8, "blocked by pre-tool-use hook");
        const trace = try buildToolTrace(ctx.allocator, name, args, risk, .blocked, false, (end - start) * 1000, output);
        logToolInvocationRecord(ctx.allocator, ctx.audit, ctx.cloud_telemetry_opt_in, ctx.control_plane_url, ctx.control_plane_token, trace, start, end, 1);
        return trace;
    }

    // hooks-20: a PreToolUse hook may rewrite the tool arguments via
    // `hookSpecificOutput.updatedInput` (reference types/hooks.ts:73-76). When
    // present, the rewritten JSON replaces `args` for execution and for the
    // recorded trace -- the tool runs with what the hook produced, not what the
    // model proposed. `effective_args` borrows either the original `args` or the
    // hook-owned `updated_input` slice (both outlive this call).
    const effective_args: []const u8 = if (pre_hook.updated_input) |ui| ui else args;

    // tools-13: a model-facing `dangerouslyDisableSandbox: true` on a bash call
    // maps to the danger-full-access profile for this single invocation, unless
    // the admin locked the sandbox key via managed settings -- then the model's
    // override is ignored and a note is recorded below.
    const sandbox_resolution = resolveBashSandboxProfile(
        name,
        effective_args,
        ctx.cfg.sandbox,
        ctx.cfg.isManagedLocked("sandbox"),
    );

    const req = tool_registry.ToolExecutionRequest{
        .name = name,
        .args = effective_args,
        .cwd = ctx.cwd,
        .sandbox_profile = sandbox_resolution.profile,
        .approve_high = true,
        .browser = ctx.browser,
        .shell_snapshot_path = ctx.shell_snapshot_path,
        .web_fetch_ctx = ctx.web_fetch_ctx,
        // Phase 9 Task 8: the Config tool mutates the runtime config through the
        // same @constCast discipline the `/config` REPL path uses. ctx.cfg is a
        // *const Config; the Config handler only writes the tiny allowlisted
        // surface (theme, model, approval_mode, output_style).
        .config_ctx = @constCast(ctx.cfg),
    };
    // Execution-layer gates (empty-workspace, bash_security) then dispatch,
    // run here as the tail of the single gate sequence so the whole path --
    // policy, permission rules, approval, plugins, hooks, execution gates,
    // dispatch -- reads top-to-bottom in one place and classifyTool runs
    // exactly once (upstream in executeToolCall, passed in as `risk`).
    var executed = true;
    const gate_output: []u8 = if (tool_registry.applyExecutionGates(ctx.allocator, req) catch |err|
        return toolExecErrorTrace(ctx, name, effective_args, risk, approval_state, start, err)) |blocked|
    blk: {
        executed = false;
        break :blk blocked;
    } else tool_registry.dispatch(ctx.allocator, if (ctx.cfg.mcp_tool_bridge_enabled) ctx.mcp else null, req) catch |err|
        return toolExecErrorTrace(ctx, name, effective_args, risk, approval_state, start, err);
    defer ctx.allocator.free(gate_output);

    var post_plugin = try plugins_mod.run(ctx.allocator, .{
        .event = .post_tool_use,
        .cwd = ctx.cwd,
        .tool_name = name,
        .tool_args = effective_args,
        .tool_output = gate_output,
        .tool_success = executed,
    });
    defer post_plugin.deinit(ctx.allocator);

    var post_hook = try runHooksWithTrustPrompt(ctx.allocator, ctx.cwd, ctx.ask_user_fn, ctx.ask_user_ctx, .{
        .event = .post_tool_use,
        .cwd = ctx.cwd,
        .tool_name = name,
        .tool_args = effective_args,
        .tool_output = gate_output,
        .tool_success = executed,
    });
    defer post_hook.deinit(ctx.allocator);

    // Ownership handoff pattern: `output` is a heap-allocated buffer we
    // build up here (possibly rewritten by the plugin/hook post passes)
    // and then hand to buildToolTrace, which takes ownership and frees
    // it on any of its own internal errors. The local `handed_off`
    // flag gates our errdefer so it only fires BEFORE the handoff.
    // Previously the errdefer ran unconditionally, so if buildToolTrace
    // hit OOM in one of its internal dupes it would free `output`
    // (via its own errdefer) and then this errdefer would free it a
    // second time when the error propagated -- a hard double-free.
    var output = try ctx.allocator.dupe(u8, gate_output);
    var handed_off = false;
    errdefer if (!handed_off) ctx.allocator.free(output);
    if (post_plugin.output.len > 0) {
        const next = try std.fmt.allocPrint(ctx.allocator, "{s}\n\n[post-tool-use plugin]\n{s}", .{ output, post_plugin.output });
        ctx.allocator.free(output);
        output = next;
    }
    if (post_hook.output.len > 0) {
        const next = try std.fmt.allocPrint(ctx.allocator, "{s}\n\n[post-tool-use hook]\n{s}", .{ output, post_hook.output });
        ctx.allocator.free(output);
        output = next;
    }
    if (sandbox_resolution.ignored_by_policy) {
        // tools-13: tell the model its full-access request was overridden by an
        // admin sandbox lock so it does not assume it ran with full access.
        const next = try std.fmt.allocPrint(ctx.allocator, "{s}\n\n[dangerouslyDisableSandbox ignored: enterprise policy locks the sandbox]", .{output});
        ctx.allocator.free(output);
        output = next;
    }

    const end = clock.nowSeconds();
    handed_off = true;
    const trace = try buildToolTrace(ctx.allocator, name, effective_args, risk, approval_state, executed, (end - start) * 1000, output);
    logToolInvocationRecord(ctx.allocator, ctx.audit, ctx.cloud_telemetry_opt_in, ctx.control_plane_url, ctx.control_plane_token, trace, start, end, if (trace.executed) 0 else 1);
    return trace;
}

pub fn logToolInvocationRecord(allocator: std.mem.Allocator, audit: *@import("core/logger.zig").AuditLogger, cloud_telemetry_opt_in: bool, control_plane_url: []const u8, control_plane_token: []const u8, trace: ToolTrace, start_ts: i64, end_ts: i64, exit_status: i32) void {
    // This function is best-effort: if we cannot build the payload or
    // deliver it, log a warning and return normally. Returning an error
    // here would force every caller to handle the failure and would
    // leak the `trace` struct's owned strings since the trace is
    // already fully constructed by the time we're called. syncAuditDirect
    // already swallows its own errors, so this matches the existing
    // contract for telemetry delivery failures.

    // Count this tool execution exactly once (this function is the single
    // chokepoint every tool-call path funnels through, and it is not on the
    // retry path). Label by tool name so /otel can break the total down per
    // tool. Falls back to the unlabeled counter if the labeled name cannot
    // be built (OOM) so the aggregate total is never lost.
    {
        const m = metrics.globalMetrics();
        if (metrics.labeledName(allocator, metrics.Names.tool_executions_total, &.{.{ "tool", trace.name }})) |labeled| {
            defer allocator.free(labeled);
            m.increment(labeled);
        } else |_| {
            m.increment(metrics.Names.tool_executions_total);
        }
    }

    const record = types.ToolInvocationRecord{
        .tool_name = trace.name,
        .args_hash = std.hash.Wyhash.hash(0, trace.args),
        .risk_tier = trace.risk,
        .approval_state = trace.approval_state,
        .start_ts = start_ts,
        .end_ts = end_ts,
        .exit_status = exit_status,
    };

    // analytics-10: when per-attribute telemetry controls are configured, the
    // string-valued attributes of the record are routed through the allowlist /
    // cardinality filter and the payload is rebuilt from only the surviving
    // attributes. When nothing is configured (the default) the fast fixed-shape
    // path below runs unchanged.
    if (telemetry_attributes.active()) {
        if (buildFilteredToolInvocationPayload(allocator, record, trace)) |payload| {
            defer allocator.free(payload);
            syncAuditDirect(audit, cloud_telemetry_opt_in, allocator, control_plane_url, control_plane_token, "tool_invocation", payload) catch {};
        } else |_| {
            std.log.warn("audit: failed to build filtered tool_invocation payload (OOM)", .{});
        }
        return;
    }

    const payload = std.fmt.allocPrint(
        allocator,
        "{f}",
        .{std.json.fmt(.{
            .tool_name = record.tool_name,
            .args_hash = record.args_hash,
            .risk_tier = types.riskTierToString(record.risk_tier),
            .approval_state = approvalStateToString(record.approval_state),
            .start_ts = record.start_ts,
            .end_ts = record.end_ts,
            .exit_status = record.exit_status,
            .output = trace.output,
        }, .{})},
    ) catch {
        std.log.warn("audit: failed to build tool_invocation payload (OOM)", .{});
        return;
    };
    defer allocator.free(payload);

    syncAuditDirect(audit, cloud_telemetry_opt_in, allocator, control_plane_url, control_plane_token, "tool_invocation", payload) catch {};
}

/// Build a tool_invocation JSON payload after routing the record's string-valued
/// attributes through the active per-attribute telemetry controls (allowlist +
/// cardinality). Only consulted when telemetry_attributes.active() is true. The
/// numeric fields (args_hash / timestamps / exit_status) and the output body are
/// not subject to the per-attribute key allowlist (they are not cardinality
/// risks the reference targets); only the low-cardinality string labels
/// (tool_name, risk_tier, approval_state) are filterable. Caller owns the result.
fn buildFilteredToolInvocationPayload(allocator: std.mem.Allocator, record: types.ToolInvocationRecord, trace: ToolTrace) ![]u8 {
    const attrs = [_]telemetry_attributes.Attribute{
        .{ .key = "tool_name", .value = record.tool_name },
        .{ .key = "risk_tier", .value = types.riskTierToString(record.risk_tier) },
        .{ .key = "approval_state", .value = approvalStateToString(record.approval_state) },
    };

    var filtered: std.ArrayListUnmanaged(telemetry_attributes.Attribute) = .empty;
    defer filtered.deinit(allocator);
    try telemetry_attributes.apply(allocator, &attrs, &filtered);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var w = std.json.Stringify{ .writer = &out.writer };

    try w.beginObject();
    for (filtered.items) |attr| {
        try w.objectField(attr.key);
        try w.write(attr.value);
    }
    // args_hash is a u64 Wyhash; write it as the native u64 so the full
    // unsigned range survives (matches the original fast-path which serialized
    // the u64 directly). Stringify.write handles the integer width.
    try w.objectField("args_hash");
    try w.write(record.args_hash);
    try w.objectField("start_ts");
    try w.write(record.start_ts);
    try w.objectField("end_ts");
    try w.write(record.end_ts);
    try w.objectField("exit_status");
    try w.write(record.exit_status);
    try w.objectField("output");
    try w.write(trace.output);
    try w.endObject();

    return allocator.dupe(u8, out.written());
}

fn syncAuditDirect(audit: *@import("core/logger.zig").AuditLogger, cloud_telemetry_opt_in: bool, allocator: std.mem.Allocator, control_plane_url: []const u8, control_plane_token: []const u8, event: []const u8, payload: []const u8) !void {
    try audit.log(event, payload);
    if (cloud_telemetry_opt_in and control_plane_url.len > 0) {
        const control_plane = @import("core/control_plane.zig");
        control_plane.syncAuditEvent(allocator, control_plane_url, control_plane_token, event, payload) catch |err| {
            std.log.warn("audit sync failed: {s}", .{@errorName(err)});
            // Also record to the in-memory error ring so a future
            // /errors slash command (or bug report attachment) can
            // surface this without requiring the user to be running
            // with --verbose. Failure to record is itself a soft
            // error: never mask the original sync failure with the
            // logging failure.
            const error_log = @import("core/error_log.zig");
            var msg_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "control-plane audit sync failed: {s}", .{@errorName(err)}) catch "control-plane audit sync failed";
            error_log.record(allocator, msg) catch {};
        };
    }
}

pub const AskUserResult = struct {
    trace: ToolTrace,
    answer: []u8,

    pub fn deinitAnswer(self: *AskUserResult, allocator: std.mem.Allocator) void {
        allocator.free(self.answer);
    }
};

pub fn handleAskUserQuestionTool(ctx: ToolExecContext, name: []const u8, args: []const u8) !AskUserResult {
    const start = clock.nowSeconds();

    // New reference shape: 1-4 questions, each with header/options/multiSelect.
    // The parser also wraps the legacy `{question, choices}` payload into a
    // single question, so most calls flow through here. If the parser cannot
    // extract any question (a bare-string payload, or an unrecognized shape),
    // fall back to the legacy single-question path below.
    if (ask_question.parseQuestions(ctx.allocator, args)) |parsed_const| {
        var parsed = parsed_const;
        defer parsed.deinit();
        return askMultiQuestion(ctx, name, args, start, &parsed);
    } else |parse_err| switch (parse_err) {
        error.OutOfMemory => return error.OutOfMemory,
        // TooFewOptions: a question carried < 2 usable options. Return a clear
        // tool-error so the model retries with a valid option set rather than
        // trapping the user with an unselectable question.
        error.TooFewOptions => {
            const end = clock.nowSeconds();
            const output = try ctx.allocator.dupe(u8, "error=each AskUserQuestion question requires at least 2 options; retry with 2-4 options per question");
            const trace = try buildToolTrace(ctx.allocator, name, args, .LOW, .denied, false, (end - start) * 1000, output);
            logToolInvocationRecord(ctx.allocator, ctx.audit, ctx.cloud_telemetry_opt_in, ctx.control_plane_url, ctx.control_plane_token, trace, start, end, 1);
            return .{ .trace = trace, .answer = try ctx.allocator.dupe(u8, "") };
        },
        error.NoQuestions => {}, // fall through to legacy raw-args path
    }

    return askLegacyQuestion(ctx, name, args, start);
}

/// Drive the multi-question flow over an already-parsed `Questions`. Prompts the
/// user once per question (one UI overlay per question, reusing the existing
/// flat-choices ask bridge), assembles per-question answers, and joins
/// multi-select selections with ", " per the reference output semantics.
///
/// `result.answer` is the FIRST question's answer for callers that still expect
/// a single string; the full per-question detail is rendered into the trace
/// output so the model sees every answer.
fn askMultiQuestion(ctx: ToolExecContext, name: []const u8, args: []const u8, start: i64, parsed: *ask_question.Questions) !AskUserResult {
    // Auto-approve a single confirmation question -- the model should not ask
    // these, but if it does, do not block the UI. (Only short-circuits when the
    // entire payload is one confirmation question.)
    if (parsed.items.len == 1 and isConfirmationQuestion(parsed.items[0].question)) {
        const end = clock.nowSeconds();
        const auto_answer = try ctx.allocator.dupe(u8, "yes");
        return .{
            .answer = auto_answer,
            .trace = .{
                .name = try ctx.allocator.dupe(u8, name),
                .args = try ctx.allocator.dupe(u8, args),
                .risk = .LOW,
                .approval_state = .auto_approved,
                .executed = true,
                .duration_ms = (end - start) * 1000,
                .output = try std.fmt.allocPrint(ctx.allocator, "question={s}\nanswer=yes (auto-approved: confirmation questions are not needed)", .{parsed.items[0].question}),
            },
        };
    }

    if (!ctx.interactive or ctx.ask_user_fn == null or ctx.ask_user_ctx == null) {
        var sb = std_io.StringBuilder.init(ctx.allocator);
        defer sb.deinit();
        for (parsed.items, 0..) |q, qi| {
            if (qi > 0) try sb.append('\n');
            try sb.writer().print("question={s}\n", .{q.question});
            const labels = try optionLabels(ctx.allocator, q.options);
            defer freeOwnedStringList(ctx.allocator, labels);
            const choice_text = try joinChoices(ctx.allocator, labels);
            defer ctx.allocator.free(choice_text);
            try sb.writer().print("choices={s}", .{choice_text});
        }
        try sb.writer().writeAll("\nerror=interactive user input is unavailable in this context; do not assume an answer");
        const end = clock.nowSeconds();
        const output = try sb.toOwnedSlice();
        const trace = try buildToolTrace(ctx.allocator, name, args, .LOW, .denied, false, (end - start) * 1000, output);
        logToolInvocationRecord(ctx.allocator, ctx.audit, ctx.cloud_telemetry_opt_in, ctx.control_plane_url, ctx.control_plane_token, trace, start, end, 1);
        return .{ .trace = trace, .answer = try ctx.allocator.dupe(u8, "") };
    }

    // Interactive: ask each question in turn, building the trace output and
    // capturing the first answer for the single-string accessor.
    var out_sb = std_io.StringBuilder.init(ctx.allocator);
    defer out_sb.deinit();
    var first_answer: ?[]u8 = null;
    errdefer if (first_answer) |fa| ctx.allocator.free(fa);

    for (parsed.items, 0..) |q, qi| {
        const labels = try optionLabels(ctx.allocator, q.options);
        defer freeOwnedStringList(ctx.allocator, labels);

        const answer = try ctx.ask_user_fn.?(ctx.ask_user_ctx.?, ctx.allocator, q.question, labels);
        defer ctx.allocator.free(answer);

        if (qi == 0) first_answer = try ctx.allocator.dupe(u8, answer);

        if (qi > 0) try out_sb.append('\n');
        try out_sb.writer().print("question={s}\nanswer={s}", .{ q.question, answer });
    }

    const end = clock.nowSeconds();
    const output = try out_sb.toOwnedSlice();
    const trace = try buildToolTrace(ctx.allocator, name, args, .LOW, .auto_approved, true, (end - start) * 1000, output);
    logToolInvocationRecord(ctx.allocator, ctx.audit, ctx.cloud_telemetry_opt_in, ctx.control_plane_url, ctx.control_plane_token, trace, start, end, 0);
    return .{ .trace = trace, .answer = first_answer orelse try ctx.allocator.dupe(u8, "") };
}

/// Legacy fallback for payloads the structured parser cannot read (a bare
/// string, or a shape with neither `questions` nor `question`). Preserves the
/// original single-question behavior over the raw args.
fn askLegacyQuestion(ctx: ToolExecContext, name: []const u8, args: []const u8, start: i64) !AskUserResult {
    const question = tool_registry.getArg(args, "question") orelse args;
    const raw_choices = tool_registry.getArg(args, "choices") orelse tool_registry.getArg(args, "options") orelse "";

    if (isConfirmationQuestion(question)) {
        const end = clock.nowSeconds();
        const auto_answer = try ctx.allocator.dupe(u8, "yes");
        return .{
            .answer = auto_answer,
            .trace = .{
                .name = try ctx.allocator.dupe(u8, name),
                .args = try ctx.allocator.dupe(u8, args),
                .risk = .LOW,
                .approval_state = .auto_approved,
                .executed = true,
                .duration_ms = (end - start) * 1000,
                .output = try std.fmt.allocPrint(ctx.allocator, "question={s}\nchoices={s}\nanswer=yes (auto-approved: confirmation questions are not needed)", .{ question, raw_choices }),
            },
        };
    }

    const choices = try parseChoiceList(ctx.allocator, raw_choices);
    defer freeOwnedStringList(ctx.allocator, choices);

    if (!ctx.interactive or ctx.ask_user_fn == null or ctx.ask_user_ctx == null) {
        const choice_text = try joinChoices(ctx.allocator, choices);
        defer ctx.allocator.free(choice_text);

        const end = clock.nowSeconds();
        const output = try std.fmt.allocPrint(
            ctx.allocator,
            "question={s}\nchoices={s}\nerror=interactive user input is unavailable in this context; do not assume an answer",
            .{ question, choice_text },
        );
        const trace = try buildToolTrace(ctx.allocator, name, args, .LOW, .denied, false, (end - start) * 1000, output);
        logToolInvocationRecord(ctx.allocator, ctx.audit, ctx.cloud_telemetry_opt_in, ctx.control_plane_url, ctx.control_plane_token, trace, start, end, 1);
        return .{
            .trace = trace,
            .answer = try ctx.allocator.dupe(u8, ""),
        };
    }

    const answer = try ctx.ask_user_fn.?(ctx.ask_user_ctx.?, ctx.allocator, question, choices);
    const answer_dup = try ctx.allocator.dupe(u8, answer);
    errdefer ctx.allocator.free(answer_dup);
    defer ctx.allocator.free(answer);

    const choice_text = try joinChoices(ctx.allocator, choices);
    defer ctx.allocator.free(choice_text);

    const output = try std.fmt.allocPrint(
        ctx.allocator,
        "question={s}\nchoices={s}\nanswer={s}",
        .{ question, choice_text, answer },
    );

    const end = clock.nowSeconds();
    const trace = try buildToolTrace(ctx.allocator, name, args, .LOW, .auto_approved, true, (end - start) * 1000, output);

    logToolInvocationRecord(ctx.allocator, ctx.audit, ctx.cloud_telemetry_opt_in, ctx.control_plane_url, ctx.control_plane_token, trace, start, end, 0);
    return .{ .trace = trace, .answer = answer_dup };
}

/// Build a flat list of option labels (owned, free with freeOwnedStringList)
/// from a question's rich options. The existing ask bridge takes flat labels;
/// description/preview are not yet surfaced through the bridge (the UI rendering
/// of headers/descriptions/previews is the manually-verified follow-up).
fn optionLabels(allocator: std.mem.Allocator, options: []const ask_question.Option) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, options.len);
    errdefer allocator.free(out);
    var filled: usize = 0;
    errdefer for (out[0..filled]) |s| allocator.free(s);
    for (options) |opt| {
        out[filled] = try allocator.dupe(u8, opt.label);
        filled += 1;
    }
    return out;
}

// --- Agent run tool ---

pub const SpawnAgentFn = *const fn (opaque_self: *anyopaque, config: agent_tool.AgentRunConfig) anyerror![]u8;

pub fn handleAgentRunTool(allocator: std.mem.Allocator, audit: *@import("core/logger.zig").AuditLogger, cloud_telemetry_opt_in: bool, control_plane_url: []const u8, control_plane_token: []const u8, name: []const u8, args: []const u8, depth: u8, reporter: ?@import("cli/repl.zig").ProgressReporter, spawn_fn: SpawnAgentFn, spawn_ctx: *anyopaque) !ToolTrace {
    const start = clock.nowSeconds();
    const emitProgressLocal = @import("agent_history.zig").emitProgress;

    const config = agent_tool.parseArgs(args) catch {
        const end = clock.nowSeconds();
        return ToolTrace{
            .name = allocator.dupe(u8, name) catch return error.OutOfMemory,
            .args = allocator.dupe(u8, args) catch return error.OutOfMemory,
            .risk = .MEDIUM,
            .approval_state = .auto_approved,
            .executed = false,
            .duration_ms = (end - start) * 1000,
            .output = allocator.dupe(u8, "Error: missing required 'prompt' argument for AgentRun") catch return error.OutOfMemory,
        };
    };

    if (depth >= agent_tool.MAX_DEPTH) {
        const end = clock.nowSeconds();
        return ToolTrace{
            .name = try allocator.dupe(u8, name),
            .args = try allocator.dupe(u8, args),
            .risk = .MEDIUM,
            .approval_state = .auto_approved,
            .executed = true,
            .duration_ms = (end - start) * 1000,
            .output = try allocator.dupe(u8, "Error: maximum sub-agent nesting depth reached. Cannot spawn further sub-agents."),
        };
    }

    emitProgressLocal(reporter, "spawning sub-agent");

    const output = spawn_fn(spawn_ctx, config) catch |first_err| first_blk: {
        // If retry requested and error is retryable, try once more
        if (config.retry_on_failure and isRetryableAgentError(first_err)) {
            emitProgressLocal(reporter, "sub-agent failed, retrying once");
            break :first_blk spawn_fn(spawn_ctx, config) catch |retry_err| {
                const end = clock.nowSeconds();
                const err_msg = try std.fmt.allocPrint(allocator, "Sub-agent failed after retry: {s} (original: {s})", .{ @errorName(retry_err), @errorName(first_err) });
                return try buildToolTrace(allocator, name, args, .MEDIUM, .auto_approved, false, (end - start) * 1000, err_msg);
            };
        }
        // No retry: return error trace with hint to try directly
        const end = clock.nowSeconds();
        const err_msg = try std.fmt.allocPrint(allocator, "Sub-agent error: {s}. Consider performing this task directly.", .{@errorName(first_err)});
        return try buildToolTrace(allocator, name, args, .MEDIUM, .auto_approved, false, (end - start) * 1000, err_msg);
    };

    const end = clock.nowSeconds();
    const trace = try buildToolTrace(allocator, name, args, .MEDIUM, .auto_approved, true, (end - start) * 1000, output);

    logToolInvocationRecord(allocator, audit, cloud_telemetry_opt_in, control_plane_url, control_plane_token, trace, start, end, 0);
    return trace;
}

/// Detect confirmation questions that the model should not be asking.
/// Returns true for "Would you like to proceed?", "Shall I continue?", etc.
fn isConfirmationQuestion(question: []const u8) bool {
    const cues = [_][]const u8{
        "would you like to proceed",
        "would you like me to proceed",
        "would you like me to continue",
        "shall i proceed",
        "shall i continue",
        "do you want me to proceed",
        "do you want me to continue",
        "should i proceed",
        "should i continue",
        "can i proceed",
        "can i continue",
        "ready to proceed",
        "want me to go ahead",
        "like me to go ahead",
        "proceed with these changes",
        "proceed with this",
        "continue with this",
        "go ahead with",
        "approve these changes",
        "confirm these changes",
    };
    for (cues) |cue| {
        if (containsIgnoreCase(question, cue)) return true;
    }
    return false;
}

fn isRetryableAgentError(err: anyerror) bool {
    return err == error.ConnectionRefused or
        err == error.ConnectionResetByPeer or
        err == error.Timeout or
        err == error.BrokenPipe or
        err == error.OutOfMemory;
}

// --- Choice parsing ---

pub fn parseChoiceList(allocator: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return allocator.alloc([]const u8, 0);

    // JSON array path. Accepts three shapes:
    //
    //   1. `["yes", "no"]`            -- plain string array (our old format)
    //   2. `[{"label":"yes"},...]`    -- Claude-Code-compat option objects
    //                                    with label/description/preview/value
    //                                    fields. We extract the first of
    //                                    label/text/value/title/content we
    //                                    find so a model trained on any
    //                                    of the reference's dialects
    //                                    still produces usable choices.
    //   3. Mixed: `[{"label":"yes"}, "no"]`
    //
    // Before this fix, shape 2 would silently drop every option because
    // the parser only kept `.string` values -- a model emitting the
    // reference's structured format would see empty choices and the
    // user would be stuck with no selectable answers.
    if (trimmed[0] == '[') {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return parseChoiceListDelimited(allocator, trimmed);
        defer parsed.deinit();
        if (parsed.value != .array) return parseChoiceListDelimited(allocator, trimmed);

        var out = std.array_list.Managed([]const u8).init(allocator);
        defer out.deinit();
        for (parsed.value.array.items) |item| {
            switch (item) {
                .string => try out.append(try allocator.dupe(u8, item.string)),
                .object => |obj| {
                    const label = extractChoiceLabel(obj) orelse continue;
                    try out.append(try allocator.dupe(u8, label));
                },
                else => {},
            }
        }
        return out.toOwnedSlice();
    }

    // JSON object path. The reference input is
    // `{"question":"...","options":[...],"multiSelect":false}` -- we
    // never see this at the choices parser level because the dispatcher
    // already pulled out `choices`/`options` before getting here, but
    // some providers flatten the whole args object into the choices
    // field when they don't recognise the schema. Accept the fallback
    // by iterating the nested array's items directly (no re-serialize).
    if (trimmed[0] == '{') {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return parseChoiceListDelimited(allocator, trimmed);
        defer parsed.deinit();
        if (parsed.value == .object) {
            const obj = parsed.value.object;
            const nested_keys = [_][]const u8{ "options", "choices", "items", "answers" };
            for (nested_keys) |key| {
                if (obj.get(key)) |nested| {
                    if (nested == .array) {
                        var out = std.array_list.Managed([]const u8).init(allocator);
                        defer out.deinit();
                        for (nested.array.items) |item| {
                            switch (item) {
                                .string => try out.append(try allocator.dupe(u8, item.string)),
                                .object => |o| {
                                    if (extractChoiceLabel(o)) |label| {
                                        try out.append(try allocator.dupe(u8, label));
                                    }
                                },
                                else => {},
                            }
                        }
                        return out.toOwnedSlice();
                    }
                }
            }
        }
    }

    return parseChoiceListDelimited(allocator, trimmed);
}

/// Given a JSON object that represents one option in an
/// AskUserQuestion choice list, return the best user-facing label.
/// Prefers `label` (the reference's canonical name) then falls
/// through to `text` / `value` / `title` / `content` so models
/// trained on adjacent schemas still work. Returns null if none
/// of the keys hold a non-empty string value.
fn extractChoiceLabel(obj: std.json.ObjectMap) ?[]const u8 {
    const keys = [_][]const u8{ "label", "text", "value", "title", "content", "name" };
    for (keys) |key| {
        if (obj.get(key)) |v| {
            if (v == .string and v.string.len > 0) return v.string;
        }
    }
    return null;
}

fn parseChoiceListDelimited(allocator: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    var out = std.array_list.Managed([]const u8).init(allocator);
    defer out.deinit();

    var current = std_io.StringBuilder.init(allocator);
    defer current.deinit();

    var i: usize = 0;
    while (i <= raw.len) : (i += 1) {
        const at_end = i == raw.len;
        const ch: u8 = if (at_end) 0 else raw[i];
        const is_delim = at_end or ch == '|' or ch == ',' or ch == '\n';
        if (!is_delim) {
            try current.append(ch);
            continue;
        }
        const trimmed = std.mem.trim(u8, current.items(), " \t\r\n\"'");
        if (trimmed.len > 0) try out.append(try allocator.dupe(u8, trimmed));
        current.clearRetainingCapacity();
    }

    return out.toOwnedSlice();
}

pub fn freeOwnedStringList(allocator: std.mem.Allocator, list: []const []const u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

pub fn joinChoices(allocator: std.mem.Allocator, choices: []const []const u8) ![]u8 {
    if (choices.len == 0) return allocator.dupe(u8, "");
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    for (choices, 0..) |choice, idx| {
        if (idx > 0) try out.writer().writeAll(" | ");
        try out.appendSlice(choice);
    }
    return out.toOwnedSlice();
}

// --- Tool display / progress helpers ---

pub fn summarizeToolCallForProgress(out: []u8, name: []const u8, args: []const u8) []const u8 {
    const path = tool_registry.getArg(args, "path");
    const command = tool_registry.getArg(args, "command");
    const pattern = tool_registry.getArg(args, "pattern");
    const query = tool_registry.getArg(args, "query") orelse tool_registry.getArg(args, "q");
    const url = tool_registry.getArg(args, "url");
    const id = tool_registry.getArg(args, "id");
    const action = tool_registry.getArg(args, "action");

    if (matchesToolName(name, &.{ "file_read", "Read", "read" })) {
        if (path) |p| return std.fmt.bufPrint(out, "read {s}", .{p}) catch "read file";
        return "read file";
    }
    if (matchesToolName(name, &.{ "file_write", "Write", "write" })) {
        if (path) |p| return std.fmt.bufPrint(out, "write {s}", .{p}) catch "write file";
        return "write file";
    }
    if (matchesToolName(name, &.{ "file_edit", "Edit", "edit" })) {
        if (path) |p| return std.fmt.bufPrint(out, "edit {s}", .{p}) catch "edit file";
        return "edit file";
    }
    if (matchesToolName(name, &.{ "Glob", "glob" })) {
        if (pattern) |pat| return std.fmt.bufPrint(out, "glob {s}", .{pat}) catch "glob search";
        return "glob search";
    }
    if (matchesToolName(name, &.{ "Grep", "grep" })) {
        if (pattern) |pat| return std.fmt.bufPrint(out, "grep {s}", .{pat}) catch "text search";
        return "text search";
    }
    if (matchesToolName(name, &.{ "WebSearch", "web_search" })) {
        if (query) |q| return std.fmt.bufPrint(out, "search {s}", .{clipText(q, 80)}) catch "web search";
        return "web search";
    }
    if (matchesToolName(name, &.{ "WebFetch", "web_fetch", "HttpRequest", "http_request" })) {
        if (url) |u| return std.fmt.bufPrint(out, "fetch {s}", .{clipText(u, 80)}) catch "http request";
        return "http request";
    }
    if (matchesToolName(name, &.{ "GitDiff", "git_diff" })) {
        if (path) |p| return std.fmt.bufPrint(out, "diff {s}", .{p}) catch "git diff";
        return "git diff";
    }
    if (matchesToolName(name, &.{ "Task", "task" })) {
        if (action) |a| return std.fmt.bufPrint(out, "task action={s}", .{a}) catch "task operation";
        return "task operation";
    }
    if (matchesToolName(name, &.{ "TaskRun", "task_run" })) {
        if (command) |cmd| return std.fmt.bufPrint(out, "run {s}", .{clipText(cmd, 80)}) catch "run task";
        if (id) |task_id| return std.fmt.bufPrint(out, "run task {s}", .{task_id}) catch "run task";
        return "run task";
    }
    if (matchesToolName(name, &.{ "TodoRead", "todo_read" })) {
        return "read todo checklist";
    }
    if (matchesToolName(name, &.{ "TodoWrite", "todo_write" })) {
        return "update todo checklist";
    }
    if (matchesToolName(name, &.{ "TaskPoll", "task_poll", "TaskGet", "task_get" })) {
        if (id) |task_id| return std.fmt.bufPrint(out, "task {s}", .{task_id}) catch "task status";
        return "task status";
    }
    if (matchesToolName(name, &.{ "shell", "Bash", "bash" })) {
        // Surface the model's `description` field when present. The
        // reference BashTool schema asks for a 5-10 word summary of
        // what the command does so the user (and the progress line)
        // sees intent alongside the raw shell. Without this, a long
        // pipeline is opaque -- all the user sees in the spinner is
        // the first 80 characters of the command, which is rarely
        // enough to understand what it's doing.
        const description = tool_registry.getArg(args, "description");
        if (description) |d| {
            const trimmed = std.mem.trim(u8, d, " \t\r\n\"'");
            if (trimmed.len > 0) {
                if (command) |cmd| return std.fmt.bufPrint(out, "{s} -- {s}", .{ clipText(trimmed, 60), clipText(cmd, 80) }) catch clipText(trimmed, 80);
                return std.fmt.bufPrint(out, "{s}", .{clipText(trimmed, 120)}) catch clipText(trimmed, 120);
            }
        }
        if (command) |cmd| return std.fmt.bufPrint(out, "{s}", .{clipText(cmd, 80)}) catch "shell command";
        return "shell command";
    }
    if (path) |p| return std.fmt.bufPrint(out, "{s}", .{clipText(p, 80)}) catch "executing";
    return "executing";
}

pub fn extractToolDetail(out: []u8, name: []const u8, args: []const u8) []const u8 {
    if (matchesToolName(name, &.{ "shell", "Bash", "bash" })) {
        if (tool_registry.getArg(args, "command")) |cmd| return clipInto(out, cmd, 120);
    }
    if (matchesToolName(name, &.{ "file_read", "Read", "read" })) {
        if (tool_registry.getArg(args, "path") orelse tool_registry.getArg(args, "file_path")) |p| return clipInto(out, p, 120);
    }
    if (matchesToolName(name, &.{ "Glob", "glob" })) {
        if (tool_registry.getArg(args, "pattern")) |pat| return clipInto(out, pat, 120);
    }
    if (matchesToolName(name, &.{ "Grep", "grep" })) {
        if (tool_registry.getArg(args, "pattern")) |pat| return clipInto(out, pat, 120);
    }
    if (matchesToolName(name, &.{ "WebFetch", "web_fetch", "HttpRequest", "http_request" })) {
        if (tool_registry.getArg(args, "url")) |u| return clipInto(out, u, 120);
    }
    if (matchesToolName(name, &.{ "WebSearch", "web_search" })) {
        if (tool_registry.getArg(args, "query") orelse tool_registry.getArg(args, "q")) |q| return clipInto(out, q, 120);
    }
    return "";
}

pub fn emitEditBlockFromTrace(reporter: repl.ProgressReporter, args: []const u8, output: []const u8) void {
    const emit_fn = reporter.emit_edit_block orelse return;
    const path = tool_registry.getArg(args, "path") orelse tool_registry.getArg(args, "file_path") orelse "unknown";
    const old_text = tool_registry.getArg(args, "find") orelse tool_registry.getArg(args, "old_string") orelse "";
    const new_text = tool_registry.getArg(args, "replace") orelse tool_registry.getArg(args, "new_string") orelse "";
    // Parse start line from output like "edit ok: 1 replacement(s) at line 42"
    var start_line: usize = 1;
    if (std.mem.indexOf(u8, output, "at line ")) |idx| {
        const after = output[idx + 8 ..];
        start_line = std.fmt.parseInt(usize, std.mem.trim(u8, after, " \t\r\n"), 10) catch 1;
    }
    const success = std.mem.startsWith(u8, output, "edit ok");
    emit_fn(reporter.ctx, path, old_text, new_text, start_line, success);
}

pub fn emitWriteBlockFromTrace(reporter: repl.ProgressReporter, args: []const u8, output: []const u8) void {
    if (reporter.emit_tool_output) |emit_tool| {
        const path = tool_registry.getArg(args, "path") orelse tool_registry.getArg(args, "file_path") orelse "unknown";
        emit_tool(reporter.ctx, "Write", path, output);
    }
}

pub fn emitToolTraceToReporter(reporter: repl.ProgressReporter, call_name: []const u8, call_args: []const u8, output: []const u8) void {
    if (matchesToolName(call_name, &.{ "file_edit", "Edit", "edit" })) {
        emitEditBlockFromTrace(reporter, call_args, output);
    } else if (matchesToolName(call_name, &.{ "file_write", "Write", "write" })) {
        emitWriteBlockFromTrace(reporter, call_args, output);
    } else if (matchesToolName(call_name, &.{ "GitDiff", "git_diff" })) {
        if (reporter.emit_diff_block) |emit_diff| {
            emit_diff(reporter.ctx, output);
        } else if (reporter.emit_tool_output) |emit_tool| {
            var detail_buf: [256]u8 = undefined;
            const detail = extractToolDetail(&detail_buf, call_name, call_args);
            emit_tool(reporter.ctx, call_name, detail, output);
        }
    } else if (reporter.emit_tool_output) |emit_tool| {
        var detail_buf: [256]u8 = undefined;
        const detail = extractToolDetail(&detail_buf, call_name, call_args);
        emit_tool(reporter.ctx, call_name, detail, output);
    }
}

/// Budget (in chars) that `summarizeToolOutputForHistory` gives a
/// single tool result before it's head+tail-clipped for history.
/// Matches claude-code-main/src/constants/toolLimits.ts
/// DEFAULT_MAX_RESULT_SIZE_CHARS = 50_000. zcode used to cap at 16 KB,
/// which was aggressive enough that e.g. a `grep -n foo src` on a
/// medium-size repo would lose roughly two-thirds of its matches.
/// Raising to 50 KB matches the reference's default and gives tools
/// like Grep, Glob, and Bash room to actually return their full
/// output without forcing the model to re-run them.
pub const TOOL_OUTPUT_HISTORY_CAP: usize = 50_000;

/// Aggregate budget across ALL parallel tool results within a
/// single user-message batch. Ported from claude-code-main/src/
/// constants/toolLimits.ts MAX_TOOL_RESULTS_PER_MESSAGE_CHARS.
/// The per-tool cap above already protects against one single
/// runaway result, but N parallel tools each returning near the
/// per-tool cap can collectively blow the context budget:
///
///   10 parallel tools × 50 KB each = 500 KB in one turn
///
/// The aggregate cap forces the caller to redistribute the
/// budget when multiple tools return medium-sized outputs.
pub const TOOL_OUTPUT_PER_MESSAGE_CAP: usize = 200_000;

/// Max char length for the tool summary strings shown in compact
/// tool cards (tool headers, /usage display, etc.). Matches
/// constants/toolLimits.ts TOOL_SUMMARY_MAX_LENGTH. Separate from
/// the history cap because headers need to be short regardless
/// of how much raw output is kept for the model.
pub const TOOL_SUMMARY_MAX_LENGTH: usize = 50;

pub fn summarizeToolOutputForHistory(allocator: std.mem.Allocator, output: []const u8) ![]u8 {
    return summarizeToolOutputForHistoryWithCap(allocator, output, TOOL_OUTPUT_HISTORY_CAP);
}

/// Same as `summarizeToolOutputForHistory` but with a caller-
/// specified per-result cap. Used by `budgetParallelToolOutputs`
/// below to shrink a parallel-batch's results when the aggregate
/// budget is blown: the caller computes a fair-share cap and then
/// re-summarises each output under that tighter budget.
pub fn summarizeToolOutputForHistoryWithCap(
    allocator: std.mem.Allocator,
    output: []const u8,
    cap: usize,
) ![]u8 {
    const stripped = try stripTerminalControlSequences(allocator, output);
    defer allocator.free(stripped);

    const compressed = try compressProgressOutput(allocator, stripped);
    defer allocator.free(compressed);

    return clipToolOutputForHistory(allocator, compressed, cap);
}

/// Compute the per-call cap that keeps `count` parallel tool
/// results within `TOOL_OUTPUT_PER_MESSAGE_CAP` total. Returns
/// `TOOL_OUTPUT_HISTORY_CAP` when the fair share would exceed it
/// (i.e. few enough parallel tools that each can have the full
/// per-tool budget) so small batches pay no tax. Returns at
/// least 512 bytes so even a 50-tool batch gets something
/// meaningful back from each tool.
pub fn fairShareToolCap(count: usize) usize {
    if (count == 0) return TOOL_OUTPUT_HISTORY_CAP;
    const share = TOOL_OUTPUT_PER_MESSAGE_CAP / count;
    const uncapped = @min(share, TOOL_OUTPUT_HISTORY_CAP);
    return @max(uncapped, 512);
}

fn stripTerminalControlSequences(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch == 0x1b) {
            i += ansiEscapeLength(text[i..]);
            continue;
        }
        if (ch == '\r' or ch == 0x07) {
            i += 1;
            continue;
        }
        if (ch == 0x08) {
            if (out.items().len > 0) _ = out.pop();
            i += 1;
            continue;
        }
        try out.append(ch);
        i += 1;
    }

    return out.toOwnedSlice();
}

fn ansiEscapeLength(text: []const u8) usize {
    if (text.len == 0 or text[0] != 0x1b) return 0;
    if (text.len == 1) return 1;

    const second = text[1];
    if (second == '[') {
        var i: usize = 2;
        while (i < text.len) : (i += 1) {
            const ch = text[i];
            if (ch >= 0x40 and ch <= 0x7e) return i + 1;
        }
        return text.len;
    }
    if (second == ']') {
        var i: usize = 2;
        while (i < text.len) : (i += 1) {
            if (text[i] == 0x07) return i + 1;
            if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '\\') return i + 2;
        }
        return text.len;
    }

    return @min(text.len, @as(usize, 2));
}

fn compressProgressOutput(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    var lines = std.mem.splitScalar(u8, text, '\n');
    var blank_run: usize = 0;
    var progress_count: usize = 0;
    var progress_first: []const u8 = "";
    var progress_last: []const u8 = "";

    while (lines.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, " \t\r");
        if (looksLikeProgressLogLine(trimmed)) {
            if (progress_count == 0) progress_first = trimmed;
            progress_last = trimmed;
            progress_count += 1;
            continue;
        }

        try flushProgressLines(&out, progress_count, progress_first, progress_last);
        progress_count = 0;
        progress_first = "";
        progress_last = "";

        if (std.mem.trim(u8, trimmed, " \t").len == 0) {
            blank_run += 1;
            if (blank_run > 1) continue;
        } else {
            blank_run = 0;
        }

        try out.appendSlice(trimmed);
        try out.append('\n');
    }

    try flushProgressLines(&out, progress_count, progress_first, progress_last);

    while (out.items().len > 0 and out.items()[out.items().len - 1] == '\n') {
        _ = out.pop();
    }

    return out.toOwnedSlice();
}

fn flushProgressLines(
    out: *std_io.StringBuilder,
    progress_count: usize,
    progress_first: []const u8,
    progress_last: []const u8,
) !void {
    if (progress_count == 0) return;

    try out.appendSlice(progress_first);
    try out.append('\n');

    if (progress_count > 2) {
        try out.writer().print("[... {d} progress updates omitted ...]\n", .{progress_count - 2});
    }

    if (progress_count > 1 and !std.mem.eql(u8, progress_last, progress_first)) {
        try out.appendSlice(progress_last);
        try out.append('\n');
    }
}

fn looksLikeProgressLogLine(line: []const u8) bool {
    if (line.len == 0) return false;

    const progress_verbs = [_][]const u8{
        "pulling",
        "downloading",
        "uploading",
        "fetching",
        "installing",
        "resolving",
    };

    var matched_verb = false;
    for (progress_verbs) |verb| {
        if (containsIgnoreCase(line, verb)) {
            matched_verb = true;
            break;
        }
    }
    if (!matched_verb) return false;

    return std.mem.indexOfScalar(u8, line, '%') != null or
        containsIgnoreCase(line, " kb/") or
        containsIgnoreCase(line, " mb/") or
        containsIgnoreCase(line, " gb/") or
        containsIgnoreCase(line, " eta") or
        containsIgnoreCase(line, " manifest");
}

fn clipToolOutputForHistory(allocator: std.mem.Allocator, text: []const u8, max_len: usize) ![]u8 {
    if (text.len <= max_len) return allocator.dupe(u8, text);

    const head_len = @min(max_len / 3, text.len);
    const gap_note = "\n[... output truncated ...]\n";
    const tail_budget = if (max_len > head_len + gap_note.len) max_len - head_len - gap_note.len else 0;
    const tail_len = @min(tail_budget, text.len - head_len);
    const tail_start = text.len - tail_len;

    return std.fmt.allocPrint(
        allocator,
        "{s}{s}{s}",
        .{ text[0..head_len], gap_note, text[tail_start..] },
    );
}

fn clipInto(out: []u8, text: []const u8, max_len: usize) []const u8 {
    const clipped = if (text.len > max_len) text[0..max_len] else text;
    if (clipped.len <= out.len) {
        @memcpy(out[0..clipped.len], clipped);
        return out[0..clipped.len];
    }
    return clipped;
}

pub fn clipText(text: []const u8, max_len: usize) []const u8 {
    if (text.len <= max_len) return text;
    return text[0..max_len];
}

pub const matchesToolName = parse_helpers.matchesAnyName;

// --- Intent detection ---
//
// `toolCallsSignature` was deleted in 0.11.26 along with the signature-
// match stall branch in agent_runtime; the remaining helpers below
// support the "stalled action" reprompt path (text-only response that
// looks like a promise of next action), which is orthogonal to the
// old signature-based loop detector.

pub fn shouldRepromptForToolCalls(
    user_prompt: []const u8,
    assistant_text: []const u8,
    control: model_output.ControlActions,
) bool {
    if (control.continue_requested) return true;
    // A pure conversational greeting reply ("Hello! How can I help you
    // today?") is the correct terminal response to "hi" / "hey" / etc.
    // and must not trigger the tool-call reprompt loop -- the heuristic
    // below would otherwise match "How can I help" as a question cue.
    if (looksLikePureGreetingResponse(assistant_text)) return false;
    if (looksLikeConfirmationSeekingResponse(assistant_text)) return true;
    // Blatant "promise of action" narration ("Let me run X", "I'll
    // check Y", "I will look up Z") is a local-model stall pattern
    // that must be reprompted regardless of how the user phrased the
    // request. It covers short confirmations ("ok", "yes", "go ahead")
    // and conversational phrasings ("lets login") that don't match
    // the imperative-verb cues in looksLikeActionRequest.
    if (looksLikeBlatantActionNarration(assistant_text)) return true;
    if (!looksLikeActionRequest(user_prompt)) return false;
    // When user requested action: reprompt if model declared intent without tool calls
    if (looksLikeIncompleteProgressReport(assistant_text)) return true;
    return looksLikeIntentOnlyResponse(assistant_text) or looksLikeInstructionalCommandResponse(assistant_text);
}

/// True when the assistant's reply is a short promise of action
/// ("Let me run X", "I'll check Y", "I will look up Z") with no
/// actual tool call attached. These patterns are unambiguous: the
/// model is announcing intent and stopping, which is the exact stall
/// we need to break. Short-length gate prevents false positives on
/// substantive answers that happen to contain the opener.
pub fn looksLikeBlatantActionNarration(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    // Cap length: a long response is usually a real answer that
    // happens to mention "I'll" somewhere; only short promise-shaped
    // replies are safe to classify as pure narration.
    if (trimmed.len == 0 or trimmed.len > 400) return false;

    const narration_openers = [_][]const u8{
        "let me ",
        "let's ",
        "lets ",
        "i'll ",
        "i’ll ",
        "i will ",
        "i'm going to ",
        "i’m going to ",
        "i am going to ",
        "going to ",
        "i'll go ahead and ",
        "i’ll go ahead and ",
        "i will go ahead and ",
        "let me go ahead and ",
        "i'll now ",
        "i’ll now ",
        "now let me ",
        "okay, let me ",
        "ok, let me ",
        "sure, let me ",
        "sure! let me ",
        "sure, i'll ",
        "sure, i’ll ",
        "sure, i will ",
        "great, i'll ",
        "great, i’ll ",
        "got it, i'll ",
        "got it, i’ll ",
    };
    for (narration_openers) |opener| {
        if (startsWithIgnoreCase(trimmed, opener)) return true;
    }
    return false;
}

/// True when the assistant reply announces upcoming clarifying
/// questions ("Before diving in, I need to clarify a few things",
/// "I have a few questions before we start") but never actually
/// lists them: the text contains no question mark at all. Live-seen
/// with Claude Sonnet 4-6 on complex build requests -- the model
/// drops the announcement and ends the turn, leaving the user with
/// nothing concrete to answer. We treat this as a stall: nudge the
/// model to either list the questions or skip the clarification
/// and start working.
///
/// A response that DOES contain a "?" is a real question turn and
/// must NOT match -- that is a legitimate end-of-turn state.
pub fn looksLikeQuestionStall(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    // Cap length to avoid matching a long answer that incidentally
    // mentions clarifying. Real stalls are short ("Before diving in,
    // I need to clarify a few things to build this right." is 65 chars).
    if (trimmed.len == 0 or trimmed.len > 500) return false;
    // A real question response carries at least one "?". If the
    // model wrote a question mark, it asked something concrete --
    // not the announce-and-stop pattern this guards against.
    if (std.mem.indexOfScalar(u8, trimmed, '?') != null) return false;

    const stall_cues = [_][]const u8{
        // "Before X, I..." openers (intent without follow-through).
        "before diving in",
        "before we begin",
        "before we start",
        "before i start",
        "before i begin",
        "before i build",
        "before i can build",
        "before building",
        "before getting started",
        "before we get started",
        // "I need to ..." patterns.
        "i need to clarify",
        "i'll need to clarify",
        "i’ll need to clarify",
        "i will need to clarify",
        "i need to ask",
        "i'll need to ask",
        "i’ll need to ask",
        "i need more information",
        "i need more info",
        "i need to understand",
        "i need to make sure",
        "i need clarification",
        // "I need a/some/few details" patterns (rephrasings the model
        // emitted after the first nudge in the 0.11.72 live test).
        "i need a few details",
        "i need some details",
        "i need details",
        "i need more details",
        "i need a few clarifications",
        "i need some clarifications",
        "need a few details before",
        "need details before",
        "few details before",
        // "I have ... questions" patterns.
        "i have a few questions",
        "i have some questions",
        "i have questions",
        "a few questions",
        "a few clarifying questions",
        "a few things to clarify",
        "a few things i need to know",
        // "Let me clarify/ask" patterns.
        "let me clarify",
        "let's clarify",
        "let me ask",
        // Build-intent narration ("to build exactly what you need",
        // "to build this correctly", "to make sure i build" -- all
        // close out the announcement without a question or tool call).
        "to build this correctly",
        "to build exactly what you need",
        "to make sure i build",
        "to build this right",
    };
    for (stall_cues) |cue| {
        if (containsIgnoreCase(trimmed, cue)) return true;
    }
    return false;
}

/// True when the assistant reply is a short, self-contained greeting
/// such as "Hello!", "Hi there! How can I help?", "Hey, what do you
/// want to work on?". A greeting reply is a valid end-of-turn response
/// to a conversational opener; zcode must not try to drag the model
/// into emitting tool_calls for it.
///
/// Scope: short (<=240 chars), starts with a greeting token. Anything
/// longer is almost certainly a substantive answer whose greeting
/// prefix is incidental.
fn looksLikePureGreetingResponse(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 240) return false;

    const greeting_starts = [_][]const u8{
        "hello",
        "hi!",
        "hi,",
        "hi.",
        "hi ",
        "hi\n",
        "hi\t",
        "hey!",
        "hey,",
        "hey.",
        "hey ",
        "hey\n",
        "hey\t",
        "greetings",
        "good morning",
        "good afternoon",
        "good evening",
        "howdy",
        "welcome",
    };
    for (greeting_starts) |g| {
        if (startsWithIgnoreCase(trimmed, g)) return true;
    }
    return false;
}

pub fn shouldAutoContinueAfterToolRound(
    assistant_text: []const u8,
    control: model_output.ControlActions,
) bool {
    if (control.continue_requested) return true;

    const trimmed = std.mem.trim(u8, assistant_text, " \t\r\n");
    if (trimmed.len == 0) return true;
    if (looksLikeConfirmationSeekingResponse(trimmed)) return true;
    return looksLikeIncompleteProgressReport(trimmed);
}

pub fn isMutationBlockedTrace(output: []const u8) bool {
    return containsIgnoreCase(output, "sandbox blocks mutating shell commands") or
        containsIgnoreCase(output, "read-only sandbox blocks mutations") or
        containsIgnoreCase(output, "planning mode. Use read-only tools only");
}

pub fn isTimedProgressTrace(output: []const u8) bool {
    if (!containsIgnoreCase(output, "[timeout=")) return false;
    return looksLikeProgressLogLine(output) or
        containsIgnoreCase(output, "progress updates omitted") or
        containsIgnoreCase(output, "pulling manifest") or
        containsIgnoreCase(output, "downloading") or
        containsIgnoreCase(output, "uploading") or
        containsIgnoreCase(output, "fetching");
}

pub fn shouldAutoContinueAfterTimedProgressRound(
    assistant_text: []const u8,
    control: model_output.ControlActions,
) bool {
    if (control.continue_requested) return true;

    const trimmed = std.mem.trim(u8, assistant_text, " \t\r\n");
    if (trimmed.len == 0) return true;
    if (looksLikeCompletionReport(trimmed)) return false;
    if (looksLikeUnnecessaryTimeoutChoice(trimmed)) return true;
    if (looksLikeConfirmationSeekingResponse(trimmed)) return true;
    if (looksLikeIncompleteProgressReport(trimmed)) return true;
    return false;
}

pub fn shouldAutoContinueAfterBackgroundTaskRound(
    assistant_text: []const u8,
    control: model_output.ControlActions,
) bool {
    if (control.continue_requested) return true;

    const trimmed = std.mem.trim(u8, assistant_text, " \t\r\n");
    if (trimmed.len == 0) return true;
    if (looksLikeCompletionBlocker(trimmed)) return false;
    return true;
}

pub fn isBackgroundTaskTool(name: []const u8, output: []const u8) bool {
    return matchesToolName(name, &.{ "TaskRun", "task_run" }) or
        (matchesToolName(name, &.{ "shell", "Bash", "bash" }) and containsIgnoreCase(output, "[background_task_started=true]"));
}

pub fn isStrictViolationTrace(trace: ToolTrace) bool {
    if (trace.executed) return false;
    if (trace.approval_state == .blocked or trace.approval_state == .denied) return true;
    if (containsIgnoreCase(trace.output, "[interactive_reroute=true]")) return false;
    if (containsIgnoreCase(trace.output, "[redirect_tool=true]")) return false;
    if (containsIgnoreCase(trace.output, "[invalid_input=true]")) return false;
    return false;
}

pub fn isBackgroundTaskFollowupTool(name: []const u8) bool {
    return matchesToolName(name, &.{ "TaskPoll", "task_poll", "TaskGet", "task_get", "TaskOutput", "task_output" });
}

pub fn isVerificationTool(name: []const u8, args: []const u8) bool {
    if (matchesToolName(name, &.{ "RunTests", "run_tests", "GitDiff", "git_diff", "git_status", "TaskPoll", "task_poll", "TaskOutput", "task_output", "TaskGet", "task_get" })) {
        return true;
    }
    if (matchesToolName(name, &.{ "shell", "Bash", "bash" })) {
        const command = tool_registry.getArg(args, "command") orelse args;
        return looksLikeVerificationCommand(command);
    }
    return false;
}

pub fn toolLikelyMutatedWorkspace(name: []const u8, args: []const u8) bool {
    if (matchesToolName(name, &.{ "file_write", "Write", "write", "file_edit", "Edit", "edit", "git_apply", "GitCommit", "git_commit", "OpenPR", "open_pr", "Move", "move", "Copy", "copy", "Delete", "delete", "NotebookEdit", "notebook_edit" })) {
        return true;
    }
    if (matchesToolName(name, &.{ "shell", "Bash", "bash" })) {
        const command = tool_registry.getArg(args, "command") orelse args;
        return looksLikeMutatingCommand(command);
    }
    return false;
}

pub fn toolActionSucceeded(name: []const u8, args: []const u8, output: []const u8) bool {
    const effective = canonicalToolNameForArgs(name, args);
    if (!isConcreteActionTool(effective, args)) return true;

    if (matchesToolName(effective, &.{ "shell", "Bash", "bash", "RunTests", "run_tests" })) {
        return shellLikeOutputSucceeded(output);
    }

    if (matchesToolName(effective, &.{ "file_edit", "Edit", "edit" })) {
        return startsWithIgnoreCase(output, "edit ok:");
    }
    if (matchesToolName(effective, &.{ "MultiEdit", "multi_edit", "file_multi_edit" })) {
        return startsWithIgnoreCase(output, "multi_edit ok:");
    }
    if (matchesToolName(effective, &.{ "file_write", "Write", "write" })) {
        return startsWithIgnoreCase(output, "created ") or
            startsWithIgnoreCase(output, "rewrote ") or
            startsWithIgnoreCase(output, "appended to ");
    }
    if (matchesToolName(effective, &.{"git_apply"})) {
        return startsWithIgnoreCase(output, "patch applied");
    }
    if (matchesToolName(effective, &.{ "Move", "move" })) {
        return startsWithIgnoreCase(output, "moved ");
    }
    if (matchesToolName(effective, &.{ "Copy", "copy" })) {
        return startsWithIgnoreCase(output, "copied ");
    }
    if (matchesToolName(effective, &.{ "Delete", "delete" })) {
        return startsWithIgnoreCase(output, "deleted ");
    }
    if (matchesToolName(effective, &.{ "GitCommit", "git_commit" })) {
        return !outputLooksLikeFailure(output) and containsIgnoreCase(output, "[git commit]");
    }
    if (matchesToolName(effective, &.{ "OpenPR", "open_pr" })) {
        return !outputLooksLikeFailure(output);
    }

    return !outputLooksLikeFailure(output);
}

fn shellLikeOutputSucceeded(output: []const u8) bool {
    if (containsIgnoreCase(output, "[invalid_input=true]") or
        containsIgnoreCase(output, "[interactive_reroute=true]") or
        containsIgnoreCase(output, "[redirect_tool=true]") or
        containsIgnoreCase(output, "\"termination\":\"timeout\"") or
        containsIgnoreCase(output, "\"termination\":\"cancelled\"") or
        containsIgnoreCase(output, "\"termination\":\"nonstandard\"") or
        containsIgnoreCase(output, "\"return_code_interpretation\":\"error\"") or
        containsIgnoreCase(output, "\"return_code_interpretation\":\"timeout\"") or
        containsIgnoreCase(output, "\"return_code_interpretation\":\"cancelled\"") or
        containsIgnoreCase(output, "\"return_code_interpretation\":\"invalid_input\"") or
        containsIgnoreCase(output, "\"return_code_interpretation\":\"not_executed\"") or
        containsIgnoreCase(output, "\"return_code_interpretation\":\"nonstandard_termination\""))
    {
        return false;
    }

    if (containsIgnoreCase(output, "\"return_code_interpretation\":\"success\"") or
        containsIgnoreCase(output, "\"return_code_interpretation\":\"no_matches_found\"") or
        containsIgnoreCase(output, "\"return_code_interpretation\":\"files_differ\"") or
        containsIgnoreCase(output, "\"return_code_interpretation\":\"condition_false\"") or
        containsIgnoreCase(output, "\"return_code_interpretation\":\"partial_success\"") or
        containsIgnoreCase(output, "\"return_code_interpretation\":\"non_error\""))
    {
        return true;
    }

    return !outputLooksLikeFailure(output);
}

fn outputLooksLikeFailure(output: []const u8) bool {
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    if (trimmed.len == 0) return false;

    const prefix_failures = [_][]const u8{
        "error:",
        "edit failed",
        "edit: no match",
        "multi_edit failed",
        "write failed",
        "move failed",
        "copy failed",
        "delete failed",
        "delete blocked",
        "git apply failed",
        "git add failed",
        "git commit failed",
        "gh pr create failed",
        "open_pr unavailable",
        "run_tests failed",
        "tool execution error",
        "tool call rejected",
        "blocked by ",
        "approval required",
    };
    for (prefix_failures) |prefix| {
        if (startsWithIgnoreCase(trimmed, prefix)) return true;
    }

    return containsIgnoreCase(trimmed, "[BLOCKED]") or
        containsIgnoreCase(trimmed, " failed:") or
        containsIgnoreCase(trimmed, " failed\n");
}

pub fn looksLikeVerificationBlockedOrExplained(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return false;
    return containsIgnoreCase(trimmed, "unable to verify") or
        containsIgnoreCase(trimmed, "could not verify") or
        containsIgnoreCase(trimmed, "couldn't verify") or
        containsIgnoreCase(trimmed, "verification blocked") or
        containsIgnoreCase(trimmed, "verification was blocked") or
        containsIgnoreCase(trimmed, "sandbox blocked") or
        containsIgnoreCase(trimmed, "tests could not run") or
        containsIgnoreCase(trimmed, "no tests exist") or
        containsIgnoreCase(trimmed, "no automated tests") or
        containsIgnoreCase(trimmed, "test suite is unavailable") or
        containsIgnoreCase(trimmed, "FINAL_NO_ACTION");
}

pub fn looksLikeNoActionOrBlocker(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return false;
    return containsIgnoreCase(trimmed, "FINAL_NO_ACTION") or
        containsIgnoreCase(trimmed, "no changes needed") or
        containsIgnoreCase(trimmed, "nothing to change") or
        containsIgnoreCase(trimmed, "already up to date") or
        containsIgnoreCase(trimmed, "already implemented") or
        containsIgnoreCase(trimmed, "no action needed") or
        containsIgnoreCase(trimmed, "blocked by") or
        containsIgnoreCase(trimmed, "blocked because") or
        containsIgnoreCase(trimmed, "cannot proceed") or
        containsIgnoreCase(trimmed, "can't proceed") or
        containsIgnoreCase(trimmed, "unable to proceed");
}

pub fn nonExecutionModeToolGuidance(mode: repl.SessionMode) []const u8 {
    return switch (mode) {
        .planning => "Planning mode does not execute tools. Use /plan approve to execute the plan, or switch to /mode execution.",
        .brainstorm => "Brainstorm mode does not execute tools. Switch to /mode planning to draft a plan or /mode execution to run tools.",
        .review => "Review mode uses read-only tools only. Switch to /mode execution to make changes.",
        .execution => "Switch to /mode execution to run tools.",
    };
}

pub fn shouldRequireActionAfterReadOnlyStall(prompt: []const u8) bool {
    const phrase_cues = [_][]const u8{
        "set up",
        "wire up",
        "work on",
        "make changes",
        "make the changes",
    };
    for (phrase_cues) |cue| {
        if (containsIgnoreCase(prompt, cue)) return true;
    }

    const word_cues = [_][]const u8{
        "fix",
        "implement",
        "update",
        "change",
        "configure",
        "set up",
        "setup",
        "install",
        "connect",
        "deploy",
        "provision",
        "wire up",
        "enable",
        "disable",
        "start",
        "restart",
        "launch",
        "refactor",
        "improve",
        "work on",
        "build",
        "add",
        "remove",
        "delete",
        "commit",
        "push",
        "apply",
        "write",
        "edit",
        "create",
    };
    for (word_cues) |cue| {
        if (containsWordCueIgnoreCase(prompt, cue)) return true;
    }
    return false;
}

pub fn looksLikeBareShellCommandPrompt(prompt: []const u8) bool {
    const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 160) return false;
    if (std.mem.indexOfAny(u8, trimmed, "\r\n") != null) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '?') != null) return false;

    if (containsIgnoreCase(trimmed, "please ") or
        containsIgnoreCase(trimmed, "can you ") or
        containsIgnoreCase(trimmed, "could you ") or
        containsIgnoreCase(trimmed, "what ") or
        containsIgnoreCase(trimmed, "explain "))
    {
        return false;
    }

    var first_it = std.mem.tokenizeAny(u8, trimmed, " \t");
    const first = first_it.next() orelse return false;

    const exact_commands = [_][]const u8{
        "ls",     "pwd", "date", "whoami",   "hostname",
        "uptime", "id",  "env",  "printenv", "ps",
        "df",     "du",  "top",  "htop",
    };
    for (exact_commands) |cmd| {
        if (std.ascii.eqlIgnoreCase(first, cmd)) return true;
    }

    if (std.ascii.eqlIgnoreCase(first, "go")) {
        return startsWithIgnoreCase(trimmed, "go test") or
            startsWithIgnoreCase(trimmed, "go run") or
            startsWithIgnoreCase(trimmed, "go build") or
            startsWithIgnoreCase(trimmed, "go env") or
            startsWithIgnoreCase(trimmed, "go list") or
            startsWithIgnoreCase(trimmed, "go mod") or
            startsWithIgnoreCase(trimmed, "go version");
    }

    const prefix_commands = [_][]const u8{
        "git",     "npm",  "pnpm",  "yarn",   "bun",
        "node",    "zig",  "cargo", "pytest", "python",
        "python3", "make", "cmake", "docker", "kubectl",
        "ollama",  "rg",   "grep",  "find",   "cat",
        "tail",    "head", "curl",
    };
    for (prefix_commands) |cmd| {
        if (std.ascii.eqlIgnoreCase(first, cmd)) return true;
    }

    return false;
}

pub fn shouldDirectDispatchBareShellCommandPrompt(prompt: []const u8) bool {
    if (!looksLikeBareShellCommandPrompt(prompt)) return false;

    const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    var first_it = std.mem.tokenizeAny(u8, trimmed, " \t");
    const first = first_it.next() orelse return false;

    const interactive_commands = [_][]const u8{
        "top",
        "htop",
    };
    for (interactive_commands) |cmd| {
        if (std.ascii.eqlIgnoreCase(first, cmd)) return false;
    }
    return true;
}

fn containsWordCueIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    var cursor: usize = 0;
    while (findIgnoreCase(haystack, needle, cursor)) |idx| {
        const before_ok = idx == 0 or isCueBoundary(haystack[idx - 1]);
        const after_idx = idx + needle.len;
        const after_ok = after_idx >= haystack.len or isCueBoundary(haystack[after_idx]);
        if (before_ok and after_ok) return true;
        cursor = idx + 1;
        if (cursor >= haystack.len) break;
    }
    return false;
}

fn isCueBoundary(ch: u8) bool {
    return !std.ascii.isAlphanumeric(ch) and ch != '_';
}

fn looksLikeActionRequest(prompt: []const u8) bool {
    const cues = [_][]const u8{
        // Mutation verbs
        "fix",
        "implement",
        "update",
        "change",
        "configure",
        "set up",
        "setup",
        "install",
        "connect",
        "deploy",
        "provision",
        "wire up",
        "enable",
        "disable",
        "start",
        "restart",
        "launch",
        "refactor",
        "improve",
        "work on",
        "build",
        "add",
        "remove",
        "commit",
        "push",
        // Investigation / inspection verbs. Screenshot bug: a user
        // asking "Find zcode source code on my machine" was not
        // classified as an action request, so the intent-reprompt
        // loop never fired when the model emitted "I'll help you
        // find ..." without any tool_calls. The model stalled on
        // its own "Let me search for it" declaration. These cues
        // cover the read-only inspection verbs that still need a
        // tool call to actually answer.
        "analyze",
        "review",
        "investigate",
        "debug",
        "find",
        "search",
        "locate",
        "look for",
        "look up",
        "show me",
        "show the",
        "list",
        "list the",
        "list all",
        "where is",
        "where's",
        "which file",
        "which files",
        "which dir",
        "inspect",
        "explore",
        "read",
        "grep",
        "check if",
        "check whether",
        "tell me",
        "discover",
        // Interrogative openers that, inside a coding-agent workspace,
        // almost always require a tool call to answer (read a file,
        // grep the tree, git log, etc.). Without these the model was
        // accepted when it replied with pure narration like "Let me
        // explore the project structure to understand what this
        // project is about." and never actually did the exploration.
        "what is",
        "what's",
        "what does",
        "what are",
        "what do",
        "how does",
        "how do",
        "how is",
        "how are",
        "why does",
        "why is",
        "why are",
        "when does",
        "when is",
        "where does",
        "describe",
        "explain",
        "summarize",
    };

    for (cues) |cue| {
        if (containsIgnoreCase(prompt, cue)) return true;
    }
    return false;
}

fn looksLikeCompletionBlocker(text: []const u8) bool {
    return containsIgnoreCase(text, "FINAL_NO_ACTION") or
        containsIgnoreCase(text, "blocked") or
        containsIgnoreCase(text, "sandbox") or
        containsIgnoreCase(text, "failed to start") or
        containsIgnoreCase(text, "could not start");
}

fn looksLikeIntentOnlyResponse(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (looksLikeCompletionReport(trimmed)) return false;
    if (looksLikeConfirmationSeekingResponse(trimmed)) return true;

    const starters = [_][]const u8{
        "i'll ",
        "i’ll ",
        "i will ",
        "let me ",
        "first, let me",
        "i can start",
        "i'll begin",
        "i’ll begin",
        "i will begin",
        "i'll start",
        "i’ll start",
        "i will start",
        "i'll now ",
        "i’ll now ",
        "i will now ",
        "i'll help ",
        "i’ll help ",
        "i will help ",
        "i can help ",
        "happy to help",
        "sure, let",
        "sure! let",
        "ok, let",
        "okay, let",
        "to do this,",
        "to accomplish this,",
        "to implement this,",
        "to fix this,",
        "to complete this,",
        "here's my plan",
        "here is my plan",
        "my plan is",
        "the approach will be",
        "i'll proceed",
        "i’ll proceed",
        "i will proceed",
        "of course,",
        "of course!",
        "absolutely,",
        "absolutely!",
        "certainly,",
        "certainly!",
        "great, let",
        "great! let",
    };
    for (starters) |starter| {
        if (startsWithIgnoreCase(trimmed, starter)) return true;
    }

    const inline_cues = [_][]const u8{
        "let me start by",
        "i will start by",
        "i'll start by",
        "i’ll start by",
        "i'll begin by",
        "i’ll begin by",
        "i will begin by",
        "let me now ",
        "i'll now ",
        "i’ll now ",
        "i will now ",
        "i am going to ",
        "i'm going to ",
        "i’m going to ",
        "i'll need to ",
        "i’ll need to ",
        "i will need to ",
        "the next step",
        "next, i'll",
        "next, i’ll",
        "next, i will",
        "then i'll",
        "then i’ll",
        "then i will",
        "first, i'll",
        "first, i’ll",
        "first, i will",
        "my approach:",
        "here's what i'll do",
        "here's what i’ll do",
        "here is what i'll do",
        "here is what i’ll do",
        "here's the plan",
        "here is the plan",
        "steps to",
        "to solve this",
        "to address this",
        "let me walk",
        "let me outline",
        "let me explain",
    };
    for (inline_cues) |cue| {
        if (containsIgnoreCase(trimmed, cue)) return true;
    }

    if (containsIgnoreCase(trimmed, "right now") or containsIgnoreCase(trimmed, "next i")) {
        const action_terms = [_][]const u8{
            "fix",
            "implement",
            "write",
            "edit",
            "update",
            "change",
            "refactor",
            "review",
            "investigate",
            "analyze",
            "search",
            "read",
            "run",
            "execute",
            "build",
            "create",
            "add",
            "remove",
        };
        for (action_terms) |term| {
            if (containsIgnoreCase(trimmed, term)) return true;
        }
    }

    return false;
}

/// True when the text has the shape of a delivered deliverable
/// (analysis, plan, summary, code block) rather than a short
/// chat-style ask. Used to gate confirmation-seeking detection
/// so a closing follow-up question at the end of a long analysis
/// doesn't look like mid-task stalling.
fn looksLikeDeliveredContent(trimmed: []const u8) bool {
    // Long responses almost always carry substantive output.
    if (trimmed.len > 400) return true;
    // Bullet / numbered / heading / fenced-code markers at line
    // start are strong "I shipped something" signals. The \n
    // anchor avoids matching dashes mid-sentence.
    if (std.mem.indexOf(u8, trimmed, "\n- ") != null) return true;
    if (std.mem.indexOf(u8, trimmed, "\n* ") != null) return true;
    if (std.mem.indexOf(u8, trimmed, "\n1. ") != null) return true;
    if (std.mem.indexOf(u8, trimmed, "\n## ") != null) return true;
    if (std.mem.indexOf(u8, trimmed, "\n# ") != null) return true;
    if (std.mem.indexOf(u8, trimmed, "```") != null) return true;
    return false;
}

fn looksLikeConfirmationSeekingResponse(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return false;

    // End-of-turn offers ("here's the analysis -- would you like
    // me to go deeper on X?") are semantically different from a
    // mid-task blocker ("should I proceed with the refactor?").
    // When the response clearly delivered substantive content
    // (length, bullets, numbered list, code fence, headings) the
    // closing question is a follow-up menu the USER should answer,
    // not a signal for zcode to auto-continue. Without this gate
    // any Kimi-style analysis that ended with "want me to go
    // deeper?" tripped the loop detector.
    if (looksLikeDeliveredContent(trimmed)) return false;

    const direct_cues = [_][]const u8{
        "would you like me to",
        "do you want me to",
        "should i ",
        "shall i ",
        "may i ",
        "can i go ahead",
        "please confirm",
        "once you confirm",
        "after you confirm",
        "if you'd like, i can",
        "if you would like, i can",
        "let me know if you'd like",
        "let me know if you want me to",
        "tell me if you want me to",
        "if you want me to proceed",
        "if you want me to continue",
    };
    for (direct_cues) |cue| {
        if (containsIgnoreCase(trimmed, cue)) return true;
    }

    if (std.mem.endsWith(u8, trimmed, "?")) {
        // Concrete "may I go ahead with X" cues only. "can i help" was
        // previously in this list but matches the generic greeting
        // closer "How can I help you today?" and sent conversational
        // replies into the tool-call reprompt loop. Similarly, "can i
        // do" was removed because it matches inside "what can i do for
        // you today?" -- the exact fragment every chit-chat reply
        // contains. Real concrete action asks ("should i proceed?")
        // are still caught by the remaining cues.
        const question_cues = [_][]const u8{
            "should i ",
            "shall i ",
            "would you like me to",
            "do you want me to",
            "may i ",
            "can i proceed",
            "can i continue",
            "can i go",
            "can i start",
            "can i run",
            "proceed with",
            "continue with",
            "go ahead with",
        };
        for (question_cues) |cue| {
            if (containsIgnoreCase(trimmed, cue)) return true;
        }
    }

    return false;
}

pub fn looksLikeIncompleteProgressReport(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return false;

    // Strong cues: phrases that unambiguously describe work still
    // pending, not rhetorical flourishes that happen to survive in
    // a completed summary.
    const direct_cues = [_][]const u8{
        "next i'll",
        "next i’ll",
        "next i will",
        "then i'll",
        "then i’ll",
        "then i will",
        "i'll now ",
        "i’ll now ",
        "i will now ",
        "i still need",
        "i still have to",
        "still need to",
        "still have to",
        "left to do",
        "continue with",
        "continue by",
        "before i can finish",
        "before i finish",
        "one more step",
        "another step",
        "not complete",
        "not finished",
        "first, i'll",
        "first, i’ll",
        "first i'll",
        "first i’ll",
        "now i'll",
        "now i’ll",
        "now i will",
        "here's my plan",
        "here is my plan",
        "the plan is",
        "i'm going to",
    };
    for (direct_cues) |cue| {
        if (containsIgnoreCase(trimmed, cue)) return true;
    }

    // Weak cues: forward-looking first-person phrases that ONLY
    // signal pending work when paired with a concrete action verb
    // (run / check / search / read / inspect / investigate / look /
    // explore / analyze / examine / verify / test / edit / write).
    //
    // Without this anchoring, plain phrases like "let me know if",
    // "I'll summarize", "let me explain" -- all common closers in a
    // finished analysis -- triggered the old heuristic and sent
    // zcode into a re-prompt loop after every tool-using turn.
    const weak_starters = [_][]const u8{
        "let me ",
        "let's ",
        "i'll ",
        "i’ll ",
        "i will ",
        "i need to ",
        "now let me ",
    };
    for (weak_starters) |starter| {
        var search_cursor: usize = 0;
        while (findIgnoreCase(trimmed, starter, search_cursor)) |idx| {
            const after_start = idx + starter.len;
            if (startsWithConcreteActionVerb(trimmed[after_start..])) return true;
            search_cursor = idx + 1;
            if (search_cursor >= trimmed.len) break;
        }
    }

    return false;
}

fn findIgnoreCase(hay: []const u8, needle: []const u8, start: usize) ?usize {
    if (start > hay.len) return null;
    if (needle.len == 0) return start;
    if (start + needle.len > hay.len) return null;
    var i: usize = start;
    const last = hay.len - needle.len;
    while (i <= last) : (i += 1) {
        var matches = true;
        for (needle, 0..) |n, j| {
            if (std.ascii.toLower(hay[i + j]) != std.ascii.toLower(n)) {
                matches = false;
                break;
            }
        }
        if (matches) return i;
    }
    return null;
}

fn startsWithConcreteActionVerb(rest: []const u8) bool {
    const action_verbs = [_][]const u8{
        "run ",
        "check ",
        "search ",
        "look ",
        "look into ",
        "read ",
        "inspect ",
        "investigate ",
        "explore ",
        "analyze ",
        "analyse ",
        "examine ",
        "verify ",
        "validate ",
        "test ",
        "edit ",
        "write ",
        "modify ",
        "update ",
        "refactor ",
        "fix ",
        "apply ",
        "create ",
        "add ",
        "remove ",
        "delete ",
        "call ",
        "invoke ",
        "execute ",
        "start ",
        "start by ",
        "get started ",
        "take a look ",
        "take a closer look ",
        "build ",
        "compile ",
        "grep ",
        "glob ",
        "find ",
        "install ",
        "start ",
        "spawn ",
        "kick off ",
        "fetch ",
        "download ",
        "upload ",
        "push ",
        "pull ",
        "commit ",
        "dispatch ",
        "open ",
        "probe ",
        "continue ",
    };
    for (action_verbs) |verb| {
        if (rest.len < verb.len) continue;
        var matches = true;
        for (verb, 0..) |v, j| {
            if (std.ascii.toLower(rest[j]) != std.ascii.toLower(v)) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

fn looksLikeUnnecessaryTimeoutChoice(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return false;

    const timeout_cues = [_][]const u8{
        "increase the timeout",
        "increase timeout",
        "try again",
        "retry the download",
        "resume the process",
        "resume the download",
        "check the status of the download",
        "check the status",
        "download is only at",
        "download is at",
        "timed out after",
    };
    var matched_timeout_cue = false;
    for (timeout_cues) |cue| {
        if (containsIgnoreCase(trimmed, cue)) {
            matched_timeout_cue = true;
            break;
        }
    }
    if (!matched_timeout_cue) return false;

    if (containsIgnoreCase(trimmed, "would you like to") or
        containsIgnoreCase(trimmed, "do you want to") or
        containsIgnoreCase(trimmed, "should i ") or
        containsIgnoreCase(trimmed, "or check the status"))
    {
        return true;
    }

    return false;
}

fn looksLikeInstructionalCommandResponse(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (looksLikeCompletionReport(trimmed)) return false;

    const direct_cues = [_][]const u8{
        "you can run",
        "run this command",
        "run the following",
        "execute the following",
        "use this command",
        "replace this with",
        "on your server",
        "on the spark server",
        "ssh user@",
        "ssh ",
        "```bash",
        "```sh",
        "$ ",
    };
    for (direct_cues) |cue| {
        if (containsIgnoreCase(trimmed, cue)) return true;
    }

    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    while (lines.next()) |line| {
        const l = std.mem.trim(u8, line, " \t\r");
        if (l.len == 0) continue;
        if (std.mem.startsWith(u8, l, "ssh ") or
            std.mem.startsWith(u8, l, "ollama ") or
            std.mem.startsWith(u8, l, "curl ") or
            std.mem.startsWith(u8, l, "export ") or
            std.mem.startsWith(u8, l, "sudo ") or
            std.mem.startsWith(u8, l, "docker ") or
            std.mem.startsWith(u8, l, "systemctl "))
        {
            return true;
        }
    }

    return false;
}

fn looksLikeCompletionReport(text: []const u8) bool {
    const cues = [_][]const u8{
        "here's what i changed",
        "what i changed",
        "changes made",
        "i updated",
        "i've updated",
        "i implemented",
        "i've implemented",
        "i configured",
        "i've configured",
        "configuration complete",
        "setup complete",
        "set up complete",
        "install complete",
        "installation complete",
        "successfully configured",
        "successfully installed",
        "successfully connected",
        "successfully deployed",
        "verified the setup",
        "verified the model is running",
        "verified it is running",
        "completed the task",
        "finished the task",
        "task is complete",
        "work is complete",
        "ran tests",
        "tests passed",
        "diff",
        "```diff",
        "committed",
        "pushed",
    };
    for (cues) |cue| {
        if (containsIgnoreCase(text, cue)) return true;
    }
    return false;
}

fn looksLikeVerificationCommand(command: []const u8) bool {
    return containsIgnoreCase(command, "test") or
        containsIgnoreCase(command, "check") or
        containsIgnoreCase(command, "lint") or
        containsIgnoreCase(command, "fmt --check") or
        containsIgnoreCase(command, "build") or
        containsIgnoreCase(command, "git diff") or
        containsIgnoreCase(command, "git status") or
        containsIgnoreCase(command, "git log") or
        containsIgnoreCase(command, "status") or
        containsIgnoreCase(command, "health") or
        containsIgnoreCase(command, "--version") or
        containsIgnoreCase(command, "version") or
        containsIgnoreCase(command, "show ") or
        containsIgnoreCase(command, " list") or
        startsWithIgnoreCase(command, "list ") or
        containsIgnoreCase(command, " ps") or
        startsWithIgnoreCase(command, "ps ");
}

fn looksLikeMutatingCommand(command: []const u8) bool {
    const lowered = std.mem.trim(u8, command, " \t\r\n");
    if (looksLikeVerificationCommand(lowered)) return false;
    return containsIgnoreCase(lowered, "git apply") or
        containsIgnoreCase(lowered, "git add") or
        containsIgnoreCase(lowered, "git commit") or
        containsIgnoreCase(lowered, "git push") or
        containsIgnoreCase(lowered, "mv ") or
        containsIgnoreCase(lowered, "cp ") or
        containsIgnoreCase(lowered, "rm ") or
        containsIgnoreCase(lowered, "sed -i") or
        containsIgnoreCase(lowered, "tee ") or
        containsIgnoreCase(lowered, "cat >") or
        containsIgnoreCase(lowered, "printf ") and containsIgnoreCase(lowered, " >") or
        containsIgnoreCase(lowered, "touch ") or
        containsIgnoreCase(lowered, "mkdir ") or
        containsIgnoreCase(lowered, "chmod ") or
        containsIgnoreCase(lowered, "chown ") or
        containsIgnoreCase(lowered, "install ") or
        containsIgnoreCase(lowered, "npm install") or
        containsIgnoreCase(lowered, "pnpm install") or
        containsIgnoreCase(lowered, "yarn add") or
        containsIgnoreCase(lowered, "pip install") or
        containsIgnoreCase(lowered, "uv pip install") or
        containsIgnoreCase(lowered, "cargo add") or
        containsIgnoreCase(lowered, "go get") or
        containsIgnoreCase(lowered, "curl -fsSL") or
        containsIgnoreCase(lowered, "| sh") or
        containsIgnoreCase(lowered, "systemctl start") or
        containsIgnoreCase(lowered, "systemctl restart") or
        containsIgnoreCase(lowered, "docker run") or
        containsIgnoreCase(lowered, "kubectl apply");
}

const startsWithIgnoreCase = parse_helpers.startsWithIgnoreCase;
const containsIgnoreCase = parse_helpers.containsIgnoreCase;

// --- Tests ---

const testing = std.testing;

test "isGitTool recognizes git tools (for non-git workspace filtering)" {
    try testing.expect(isGitTool("git_status"));
    try testing.expect(isGitTool("GitDiff"));
    try testing.expect(isGitTool("GitCommit"));
    try testing.expect(isGitTool("git_apply"));
    try testing.expect(!isGitTool("Read"));
    try testing.expect(!isGitTool("Bash"));
    try testing.expect(!isGitTool("WebFetch"));
}

test "isWebResearchTool recognizes only web tools" {
    try testing.expect(isWebResearchTool("WebFetch"));
    try testing.expect(isWebResearchTool("web_search"));
    try testing.expect(!isWebResearchTool("Read"));
    try testing.expect(!isWebResearchTool("git_status"));
}

test "dangerouslyDisableSandbox true maps to danger-full-access" {
    const res = resolveBashSandboxProfile(
        "Bash",
        "command=\"rm -rf build\",dangerouslyDisableSandbox=true",
        "workspace-write",
        false, // policy does not lock the sandbox
    );
    try testing.expectEqualStrings("danger-full-access", res.profile);
    try testing.expect(!res.ignored_by_policy);
}

test "dangerouslyDisableSandbox absent or false leaves base profile" {
    const absent = resolveBashSandboxProfile("Bash", "command=ls", "workspace-write", false);
    try testing.expectEqualStrings("workspace-write", absent.profile);
    try testing.expect(!absent.ignored_by_policy);

    const explicit_false = resolveBashSandboxProfile(
        "Bash",
        "command=ls,dangerouslyDisableSandbox=false",
        "read-only",
        false,
    );
    try testing.expectEqualStrings("read-only", explicit_false.profile);
}

test "dangerouslyDisableSandbox ignored when policy locks the sandbox" {
    const res = resolveBashSandboxProfile(
        "Bash",
        "command=ls,dangerouslyDisableSandbox=true",
        "workspace-write",
        true, // admin locked the sandbox key
    );
    try testing.expectEqualStrings("workspace-write", res.profile);
    try testing.expect(res.ignored_by_policy);
}

test "dangerouslyDisableSandbox ignored for non-bash tools" {
    const res = resolveBashSandboxProfile(
        "Read",
        "path=x,dangerouslyDisableSandbox=true",
        "workspace-write",
        false,
    );
    try testing.expectEqualStrings("workspace-write", res.profile);
    try testing.expect(!res.ignored_by_policy);
}

test "buildApprovalDescription appends destructive advisory note for Bash" {
    var buf: [512]u8 = undefined;
    const desc = buildApprovalDescription(
        &buf,
        "Bash",
        "command=\"git push --force origin main\"",
        .HIGH,
    );
    // base description still present
    try testing.expect(parse_helpers.containsIgnoreCase(desc, "Bash"));
    // advisory note appended
    try testing.expect(parse_helpers.containsIgnoreCase(desc, "Note:"));
    try testing.expect(parse_helpers.containsIgnoreCase(desc, "remote history"));
}

test "buildApprovalDescription omits note for benign Bash command" {
    var buf: [512]u8 = undefined;
    const desc = buildApprovalDescription(
        &buf,
        "Bash",
        "command=\"ls -la\"",
        .LOW,
    );
    try testing.expect(parse_helpers.containsIgnoreCase(desc, "Bash"));
    try testing.expect(!parse_helpers.containsIgnoreCase(desc, "Note:"));
}

test "buildApprovalDescription does not add note for non-Bash tools" {
    var buf: [512]u8 = undefined;
    // A non-Bash tool whose args happen to contain a destructive-looking
    // command must NOT get the advisory (it is bash-only).
    const desc = buildApprovalDescription(
        &buf,
        "Read",
        "command=\"git push --force\"",
        .LOW,
    );
    try testing.expect(!parse_helpers.containsIgnoreCase(desc, "Note:"));
}

test "buildApprovalDescription appends domain allow-rule suggestion for non-preapproved WebFetch" {
    var buf: [512]u8 = undefined;
    const desc = buildApprovalDescription(
        &buf,
        "WebFetch",
        "url=\"https://blog.example.com/post\"",
        .HIGH,
    );
    // base description still present
    try testing.expect(parse_helpers.containsIgnoreCase(desc, "WebFetch"));
    // domain allow-rule suggestion appended for the URL's host
    try testing.expect(parse_helpers.containsIgnoreCase(desc, "domain:blog.example.com"));
}

test "webFetchSuggestionNote: non-preapproved host yields a domain suggestion" {
    var buf: [128]u8 = undefined;
    const note = webFetchSuggestionNote(&buf, "https://docs.foo.com/x") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, note, "domain:docs.foo.com") != null);
}

test "webFetchSuggestionNote: preapproved host yields no suggestion" {
    var buf: [128]u8 = undefined;
    // docs.python.org is preapproved -> never reaches the ask path -> no note.
    try testing.expect(webFetchSuggestionNote(&buf, "https://docs.python.org/3/") == null);
}

test "webFetchSuggestionNote: unparseable URL yields no suggestion" {
    var buf: [128]u8 = undefined;
    try testing.expect(webFetchSuggestionNote(&buf, "not a url") == null);
}

test "filterGitToolSchemas drops git tools, keeps the rest" {
    const schemas = [_]types.ToolSchema{
        .{ .name = "Read", .description = "d", .json_schema = "{}" },
        .{ .name = "git_status", .description = "d", .json_schema = "{}" },
        .{ .name = "Write", .description = "d", .json_schema = "{}" },
        .{ .name = "GitCommit", .description = "d", .json_schema = "{}" },
    };
    const out = try filterGitToolSchemas(testing.allocator, &schemas);
    defer {
        for (out) |s| {
            testing.allocator.free(s.name);
            testing.allocator.free(s.description);
            testing.allocator.free(s.json_schema);
            if (s.usage_hint.len > 0) testing.allocator.free(s.usage_hint);
        }
        testing.allocator.free(out);
    }
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("Read", out[0].name);
    try testing.expectEqualStrings("Write", out[1].name);
}

test "filterNonInspectionSchemas keeps web research tools but drops local inspection" {
    const schemas = [_]types.ToolSchema{
        .{ .name = "Read", .description = "d", .json_schema = "{}" },
        .{ .name = "WebFetch", .description = "d", .json_schema = "{}" },
        .{ .name = "Write", .description = "d", .json_schema = "{}" },
        .{ .name = "Grep", .description = "d", .json_schema = "{}" },
    };
    const out = try filterNonInspectionSchemas(testing.allocator, &schemas);
    defer {
        for (out) |s| {
            testing.allocator.free(s.name);
            testing.allocator.free(s.description);
            testing.allocator.free(s.json_schema);
            if (s.usage_hint.len > 0) testing.allocator.free(s.usage_hint);
        }
        testing.allocator.free(out);
    }
    // Read and Grep dropped (local inspection); WebFetch kept (research) + Write kept (action)
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("WebFetch", out[0].name);
    try testing.expectEqualStrings("Write", out[1].name);
}

test "filterAutoMemSchemas keeps the auto-mem allowlist and drops everything else" {
    const schemas = [_]types.ToolSchema{
        .{ .name = "Read", .description = "d", .json_schema = "{}" },
        .{ .name = "Grep", .description = "d", .json_schema = "{}" },
        .{ .name = "Glob", .description = "d", .json_schema = "{}" },
        .{ .name = "Bash", .description = "d", .json_schema = "{}" },
        .{ .name = "Edit", .description = "d", .json_schema = "{}" },
        .{ .name = "Write", .description = "d", .json_schema = "{}" },
        .{ .name = "WebFetch", .description = "d", .json_schema = "{}" },
        .{ .name = "AgentRun", .description = "d", .json_schema = "{}" },
        .{ .name = "GitCommit", .description = "d", .json_schema = "{}" },
    };
    const out = try filterAutoMemSchemas(testing.allocator, &schemas);
    defer {
        for (out) |s| {
            testing.allocator.free(s.name);
            testing.allocator.free(s.description);
            testing.allocator.free(s.json_schema);
            if (s.usage_hint.len > 0) testing.allocator.free(s.usage_hint);
        }
        testing.allocator.free(out);
    }
    // Read/Grep/Glob/Bash/Edit/Write kept; WebFetch/AgentRun/GitCommit dropped.
    try testing.expectEqual(@as(usize, 6), out.len);
    try testing.expectEqualStrings("Read", out[0].name);
    try testing.expectEqualStrings("Grep", out[1].name);
    try testing.expectEqualStrings("Glob", out[2].name);
    try testing.expectEqualStrings("Bash", out[3].name);
    try testing.expectEqualStrings("Edit", out[4].name);
    try testing.expectEqualStrings("Write", out[5].name);
}

test "pathWithin matches dir, child, and rejects siblings/outside" {
    try testing.expect(pathWithin("/m/mem", "/m/mem"));
    try testing.expect(pathWithin("/m/mem/", "/m/mem")); // trailing-sep tolerant
    try testing.expect(pathWithin("/m/mem", "/m/mem/a.md"));
    try testing.expect(!pathWithin("/m/mem", "/m/membrane/a.md")); // prefix-share sibling
    try testing.expect(!pathWithin("/m/mem", "/etc/passwd"));
    try testing.expect(!pathWithin("", "/m/mem/a.md"));
}

test "reprompt for tool calls on explicit continue control" {
    try testing.expect(shouldRepromptForToolCalls(
        "anything",
        "done",
        .{ .continue_requested = true },
    ));
}

test "reprompt for action request with intent-only assistant text" {
    try testing.expect(shouldRepromptForToolCalls(
        "lets work on those improvements, fix them now",
        "I'll begin by implementing security improvements.",
        .{},
    ));
}

test "reprompt for delayed intent phrase without tool calls" {
    try testing.expect(shouldRepromptForToolCalls(
        "complete the implementation now",
        "I understand your frustration. Let me now write the complete implementation right now.",
        .{},
    ));
}

test "reprompt for curly apostrophe intent without tool calls" {
    try testing.expect(shouldRepromptForToolCalls(
        "fix the scroll issue",
        "Sure, I’ll take a look at the relevant code first.",
        .{},
    ));
}

test "reprompt for Find-class investigation request (screenshot bug)" {
    // Screenshot report: user said "Find zcode source code on my
    // machine" and the model replied "I'll help you find the
    // zcode source code on your machine. Let me search for it."
    // without emitting any tool_calls. The reprompt never fired
    // because "find" was not in looksLikeActionRequest's cue list.
    // Pin the fix.
    try testing.expect(shouldRepromptForToolCalls(
        "Find zcode source code on my machine",
        "I'll help you find the zcode source code on your machine. Let me search for it.",
        .{},
    ));
}

test "reprompt for search/list/show/locate/where inspection requests" {
    // All the read-only inspection verbs that still need a tool
    // call to actually answer.
    const cases = [_]struct { prompt: []const u8, reply: []const u8 }{
        .{ .prompt = "search for the login handler", .reply = "Let me search for it." },
        .{ .prompt = "list all zig files", .reply = "I'll list them for you." },
        .{ .prompt = "show me the main config", .reply = "Let me show you the config." },
        .{ .prompt = "locate the error handler", .reply = "I can help locate that." },
        .{ .prompt = "where is the test suite?", .reply = "Let me check." },
        .{ .prompt = "which files import this module?", .reply = "I'll find out." },
        .{ .prompt = "investigate the crash", .reply = "I'll look into it." },
    };
    for (cases) |c| {
        try testing.expect(shouldRepromptForToolCalls(c.prompt, c.reply, .{}));
    }
}

test "parseChoiceList handles plain string array" {
    const out = try parseChoiceList(testing.allocator, "[\"yes\",\"no\",\"maybe\"]");
    defer freeOwnedStringList(testing.allocator, out);
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqualStrings("yes", out[0]);
    try testing.expectEqualStrings("no", out[1]);
    try testing.expectEqualStrings("maybe", out[2]);
}

test "parseChoiceList handles comma-delimited fallback" {
    const out = try parseChoiceList(testing.allocator, "yes, no, maybe");
    defer freeOwnedStringList(testing.allocator, out);
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqualStrings("yes", out[0]);
    try testing.expectEqualStrings("no", out[1]);
    try testing.expectEqualStrings("maybe", out[2]);
}

test "parseChoiceList handles reference-style option objects with label" {
    const input =
        "[{\"label\":\"Approve\",\"description\":\"ship it\"}," ++
        "{\"label\":\"Deny\",\"description\":\"do not ship\"}]";
    const out = try parseChoiceList(testing.allocator, input);
    defer freeOwnedStringList(testing.allocator, out);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("Approve", out[0]);
    try testing.expectEqualStrings("Deny", out[1]);
}

test "parseChoiceList falls back to text/value/title for option objects" {
    // Different schemas use different label field names. Verify we
    // handle each fallback in the priority order label > text > value > title > content > name.
    const input =
        "[{\"text\":\"first\"},{\"value\":\"second\"},{\"title\":\"third\"},{\"content\":\"fourth\"},{\"name\":\"fifth\"}]";
    const out = try parseChoiceList(testing.allocator, input);
    defer freeOwnedStringList(testing.allocator, out);
    try testing.expectEqual(@as(usize, 5), out.len);
    try testing.expectEqualStrings("first", out[0]);
    try testing.expectEqualStrings("second", out[1]);
    try testing.expectEqualStrings("third", out[2]);
    try testing.expectEqualStrings("fourth", out[3]);
    try testing.expectEqualStrings("fifth", out[4]);
}

test "parseChoiceList handles mixed string and object items" {
    const input = "[{\"label\":\"yes\"},\"no\",{\"label\":\"maybe\"}]";
    const out = try parseChoiceList(testing.allocator, input);
    defer freeOwnedStringList(testing.allocator, out);
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqualStrings("yes", out[0]);
    try testing.expectEqualStrings("no", out[1]);
    try testing.expectEqualStrings("maybe", out[2]);
}

test "parseChoiceList skips object items with no recognisable label key" {
    const input = "[{\"label\":\"keep\"},{\"unknown_key\":\"drop\"},{\"label\":\"keep2\"}]";
    const out = try parseChoiceList(testing.allocator, input);
    defer freeOwnedStringList(testing.allocator, out);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("keep", out[0]);
    try testing.expectEqualStrings("keep2", out[1]);
}

test "parseChoiceList recovers from a nested options object wrapper" {
    // Some providers flatten the full args object into the choices
    // field when they don't recognise the schema. Verify we extract
    // the options array from the nested wrapper.
    const input = "{\"options\":[\"a\",\"b\"],\"multiSelect\":false}";
    const out = try parseChoiceList(testing.allocator, input);
    defer freeOwnedStringList(testing.allocator, out);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("a", out[0]);
    try testing.expectEqualStrings("b", out[1]);
}

test "parseChoiceList returns empty for empty input" {
    const out = try parseChoiceList(testing.allocator, "");
    defer freeOwnedStringList(testing.allocator, out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "reprompt when assistant narrates intent in response to a what/how question" {
    // In a coding-agent workspace, "what is the architecture?" requires
    // reading files / running tools to answer; accepting pure narration
    // as the final answer lets the model stall with "Let me explore..."
    // and never actually explore.
    try testing.expect(shouldRepromptForToolCalls(
        "what is the architecture?",
        "I'll explain the architecture now.",
        .{},
    ));
}

test "no reprompt when assistant reports completed changes" {
    try testing.expect(!shouldRepromptForToolCalls(
        "implement the feature now",
        "Implemented the feature and ran tests. Here's what I changed and the diff summary.",
        .{},
    ));
}

test "reprompt for configure request when assistant asks to proceed" {
    try testing.expect(shouldRepromptForToolCalls(
        "configure my local 32 billion parameter with ollama on my spark server",
        "I can configure that for you. Shall I proceed?",
        .{},
    ));
}

test "reprompt for confirmation seeking response even without explicit action cue" {
    try testing.expect(shouldRepromptForToolCalls(
        "please help with this",
        "Would you like me to go ahead and make the changes?",
        .{},
    ));
}

test "no reprompt on greeting reply to conversational opener" {
    // Regression: "hi" -> "Hello! How can I help you today?" was triggering
    // the tool-call reprompt loop because "can I help" matched a question
    // cue. A pure greeting is a valid terminal response; the loop must end.
    try testing.expect(!shouldRepromptForToolCalls(
        "hi",
        "Hello! How can I help you today?",
        .{},
    ));
    try testing.expect(!shouldRepromptForToolCalls(
        "hello",
        "Hi there! What can I help you with?",
        .{},
    ));
    try testing.expect(!shouldRepromptForToolCalls(
        "hey",
        "Hey! Ready when you are.",
        .{},
    ));
    try testing.expect(!shouldRepromptForToolCalls(
        "good morning",
        "Good morning! How can I help today?",
        .{},
    ));
}

test "no reprompt on 'how are you' social prompt with 'what can I do' reply" {
    // Regression: pass-146 user report. User typed "hi how are you ??"
    // and the model replied "I'm doing well, thanks for asking! Ready
    // to help you with whatever you need. What can I do for you
    // today?". zcode's confirmation-seeking heuristic matched the
    // "can i do" fragment inside "what can i do for you" and sent the
    // reply into the action-reprompt loop, eventually surfacing
    // "The model could not execute the requested work...". Fix in
    // two parts: the looksLikeActionRequest gate now runs BEFORE the
    // confirmation-seeking check (so non-action prompts short-circuit),
    // and "can i do" was removed from the question_cues list (too
    // broad for its intended purpose).
    try testing.expect(!shouldRepromptForToolCalls(
        "hi how are you ??",
        "I'm doing well, thanks for asking! Ready to help you with whatever you need. What can I do for you today?",
        .{},
    ));
    try testing.expect(!shouldRepromptForToolCalls(
        "how are you doing today",
        "Doing great! What can I do for you?",
        .{},
    ));
    try testing.expect(!shouldRepromptForToolCalls(
        "tell me a joke",
        "Why did the chicken cross the road? To get to the other side!",
        .{},
    ));
}

test "reprompt still fires on real action requests with confirmation-seeking reply" {
    // Action request ("fix the bug") + assistant reply asking "should
    // I proceed?" -> SHOULD reprompt. Reordering the checks must not
    // break the primary purpose of the heuristic.
    try testing.expect(shouldRepromptForToolCalls(
        "fix the broken test",
        "I can fix the broken test. Should I proceed with the refactor?",
        .{},
    ));
    try testing.expect(shouldRepromptForToolCalls(
        "implement the new feature",
        "I'll implement that. Would you like me to start?",
        .{},
    ));
}

test "looksLikePureGreetingResponse matches common openers and rejects long prose" {
    try testing.expect(looksLikePureGreetingResponse("Hello!"));
    try testing.expect(looksLikePureGreetingResponse("Hi there! How can I help you today?"));
    try testing.expect(looksLikePureGreetingResponse("Hey! What do you want to work on?"));
    try testing.expect(looksLikePureGreetingResponse("Good afternoon -- ready to go."));

    // Not a greeting: substantive answer that happens to mention hello
    try testing.expect(!looksLikePureGreetingResponse("The function logs 'hello' when called."));
    // Not a greeting: short but not a greeting opener
    try testing.expect(!looksLikePureGreetingResponse("Done."));
    // Not a greeting: too long to be purely conversational
    const long_prefix = "Hello! " ++ "This is a substantial answer " ** 20;
    try testing.expect(!looksLikePureGreetingResponse(long_prefix));
}

test "looksLikeQuestionStall flags announce-and-stop clarification preambles" {
    // The exact live-seen Sonnet 4-6 stall (zcode --yolo session, 0.11.71).
    try testing.expect(looksLikeQuestionStall(
        "Before diving in, I need to clarify a few things to build this right.",
    ));
    try testing.expect(looksLikeQuestionStall("Before we begin, I need to understand the deployment target."));
    try testing.expect(looksLikeQuestionStall("I have a few questions before I start."));
    try testing.expect(looksLikeQuestionStall("Let me clarify a couple of things first."));
    try testing.expect(looksLikeQuestionStall("I need more information before proceeding."));
}

test "looksLikeQuestionStall flags rephrased variations from the 0.11.72 live loop" {
    // All four responses Sonnet 4-6 generated in the 0.11.72 live test
    // when our first nudge fired -- it just kept rephrasing the same
    // announcement. The heuristic must catch every variation or the
    // nudge silently lets the rephrased one through.
    try testing.expect(looksLikeQuestionStall(
        "Before I start building, I need to clarify a few things to make sure I build exactly what you need.",
    ));
    try testing.expect(looksLikeQuestionStall("I need to clarify a few things before building this."));
    try testing.expect(looksLikeQuestionStall("I need a few details before I can build this correctly."));
}

test "looksLikeQuestionStall ignores responses that actually contain a question" {
    // A real clarifying-question response is a valid end of turn -- the
    // user has something concrete to answer. Must not match.
    try testing.expect(!looksLikeQuestionStall(
        "Before diving in, a few quick questions:\n1. Which city should be the default?\n2. What's the Partiful login flow you use?",
    ));
    try testing.expect(!looksLikeQuestionStall("I have a few questions: what city? what date range?"));
    // Empty / unrelated text: not a stall.
    try testing.expect(!looksLikeQuestionStall(""));
    try testing.expect(!looksLikeQuestionStall("Done -- created src/main.zig with the auth scaffold."));
    // Long substantive answer that mentions clarification incidentally: not a stall.
    const long = "Here is the architecture overview. " ++ ("Each module is independent. " ** 30);
    try testing.expect(!looksLikeQuestionStall(long));
}

test "auto continue after tool round when response is empty" {
    try testing.expect(shouldAutoContinueAfterToolRound("", .{}));
}

test "detect sandbox mutation block traces" {
    try testing.expect(isMutationBlockedTrace("read-only sandbox blocks mutating shell commands"));
    try testing.expect(isMutationBlockedTrace("tool=bash\noutput=read-only sandbox blocks mutations"));
    try testing.expect(!isMutationBlockedTrace("tool execution error: FileNotFound"));
}

test "detect timed progress traces" {
    try testing.expect(isTimedProgressTrace("pulling manifest\n[... 12 progress updates omitted ...]\n[timeout=60s]"));
    try testing.expect(isTimedProgressTrace("downloading package 42%\n[timeout=30s]"));
    try testing.expect(!isTimedProgressTrace("tool execution error: permission denied"));
}

test "reprompt for action request when assistant gives shell commands for user to run" {
    try testing.expect(shouldRepromptForToolCalls(
        "configure my local 32 billion parameter with olama on my spark server",
        "```bash\nssh user@spark-server \"ollama --version\"\n```",
        .{},
    ));
}

test "reprompt for long instructional setup answer" {
    try testing.expect(shouldRepromptForToolCalls(
        "configure my local 32 billion parameter with olama on my spark server",
        "To configure a local 32 billion parameter model using Ollama on your Spark server, follow these steps.\n\n```bash\ncurl -fsSL https://ollama.com/install.sh | sh\n```\n\nThen run:\n\n```bash\nsystemctl start ollama\n```",
        .{},
    ));
}

test "auto continue after tool round when assistant asks for confirmation" {
    try testing.expect(shouldAutoContinueAfterToolRound("If you'd like, I can continue from here.", .{}));
}

test "auto continue after timed progress round when assistant asks about timeout choice" {
    try testing.expect(shouldAutoContinueAfterTimedProgressRound(
        "The download timed out after 60 seconds. Would you like to increase the timeout and try again, or check the status of the download?",
        .{},
    ));
}

test "do not auto continue after timed progress round when assistant provides concrete blocker summary" {
    try testing.expect(!shouldAutoContinueAfterTimedProgressRound(
        "The download timed out and cannot continue in the current sandbox because mutating shell commands are blocked.",
        .{},
    ));
}

test "do not auto continue after tool round when response is a concrete completion report" {
    try testing.expect(!shouldAutoContinueAfterToolRound(
        "Configured Ollama, restarted the service, and verified the model is running.",
        .{},
    ));
}

test "do not auto continue after tool round for a final analytical answer" {
    try testing.expect(!shouldAutoContinueAfterToolRound(
        "The root cause is a missing provider override in the local adapter path.",
        .{},
    ));
}

test "summarizeToolCallForProgress surfaces Bash description field" {
    // The reference BashTool schema asks the model for a 5-10 word
    // `description` so the user sees intent alongside the raw shell.
    // This test pins that we actually read and render that field.
    var buf: [512]u8 = undefined;
    const summary = summarizeToolCallForProgress(
        &buf,
        "Bash",
        "command=\"cd /repo && ./script.sh\",description=\"Run the release script\"",
    );
    try testing.expect(std.mem.indexOf(u8, summary, "Run the release script") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "./script.sh") != null);
    // Description should come first so the progress line shows
    // intent, then the raw command for detail.
    const desc_idx = std.mem.indexOf(u8, summary, "Run the release script").?;
    const cmd_idx = std.mem.indexOf(u8, summary, "./script.sh").?;
    try testing.expect(desc_idx < cmd_idx);
}

test "summarizeToolCallForProgress falls back to command when description is missing" {
    var buf: [512]u8 = undefined;
    const summary = summarizeToolCallForProgress(
        &buf,
        "Bash",
        "command=\"git status\"",
    );
    try testing.expect(std.mem.indexOf(u8, summary, "git status") != null);
}

test "summarizeToolCallForProgress falls back to command when description is blank" {
    var buf: [512]u8 = undefined;
    const summary = summarizeToolCallForProgress(
        &buf,
        "Bash",
        "command=\"git status\",description=\"   \"",
    );
    try testing.expect(std.mem.indexOf(u8, summary, "git status") != null);
    // Blank description must not leak quotes or whitespace.
    try testing.expect(std.mem.indexOf(u8, summary, "--") == null);
}

test "summarize tool output strips ansi and compresses progress noise" {
    const summarized = try summarizeToolOutputForHistory(
        testing.allocator,
        "$ ollama pull qwen3:32b\n\x1b[1Gpulling manifest\x1b[K\npulling abc:   1% 100 MB/39 GB\npulling abc:   2% 200 MB/39 GB\npulling abc:   3% 300 MB/39 GB\n[timeout=120s]\n",
    );
    defer testing.allocator.free(summarized);

    try testing.expect(std.mem.indexOfScalar(u8, summarized, 0x1b) == null);
    try testing.expect(std.mem.indexOf(u8, summarized, "progress updates omitted") != null);
    try testing.expect(std.mem.indexOf(u8, summarized, "[timeout=120s]") != null);
}

test "fairShareToolCap keeps full per-tool budget for small batches" {
    // 1 or 2 tools: fair share is huge, so we use the full per-tool cap.
    try testing.expectEqual(TOOL_OUTPUT_HISTORY_CAP, fairShareToolCap(1));
    try testing.expectEqual(TOOL_OUTPUT_HISTORY_CAP, fairShareToolCap(2));
    try testing.expectEqual(TOOL_OUTPUT_HISTORY_CAP, fairShareToolCap(4));
}

test "fairShareToolCap shrinks cap proportionally for large batches" {
    // 5 tools: share = 200_000/5 = 40_000, under the per-tool cap.
    try testing.expectEqual(@as(usize, 40_000), fairShareToolCap(5));
    // 10 tools: share = 200_000/10 = 20_000.
    try testing.expectEqual(@as(usize, 20_000), fairShareToolCap(10));
    // 20 tools: share = 200_000/20 = 10_000.
    try testing.expectEqual(@as(usize, 10_000), fairShareToolCap(20));
}

test "fairShareToolCap enforces a 512-byte floor on giant batches" {
    // 1000 tools: naive share would be 200, below the floor.
    try testing.expect(fairShareToolCap(1000) >= 512);
    try testing.expect(fairShareToolCap(10_000) >= 512);
}

test "fairShareToolCap zero tools returns full per-tool budget" {
    try testing.expectEqual(TOOL_OUTPUT_HISTORY_CAP, fairShareToolCap(0));
}

test "summarizeToolOutputForHistoryWithCap honours a tight cap" {
    const long_input = "a" ** 10_000;
    const summarized = try summarizeToolOutputForHistoryWithCap(testing.allocator, long_input, 1_000);
    defer testing.allocator.free(summarized);

    // The clip helper adds a "[... output truncated ...]" marker so
    // the length won't be exactly 1_000, but it should be close to
    // the cap and substantially smaller than 10_000.
    try testing.expect(summarized.len < 2_000);
    try testing.expect(summarized.len > 0);
    try testing.expect(std.mem.indexOf(u8, summarized, "output truncated") != null);
}

test "summarizeToolOutputForHistoryWithCap passes short input through" {
    const short_input = "just a few bytes";
    const summarized = try summarizeToolOutputForHistoryWithCap(testing.allocator, short_input, 1_000);
    defer testing.allocator.free(summarized);
    try testing.expectEqualStrings(short_input, summarized);
}

test "non-execution mode guidance strings are explicit" {
    try testing.expect(std.mem.indexOf(u8, nonExecutionModeToolGuidance(.planning), "/mode execution") != null);
    try testing.expect(std.mem.indexOf(u8, nonExecutionModeToolGuidance(.brainstorm), "/mode planning") != null);
}

test "inspection-only tool classification separates reads from actions" {
    try testing.expect(isInspectionOnlyTool("Read"));
    try testing.expect(isInspectionOnlyTool("Grep"));
    try testing.expect(isInspectionOnlyTool("ListDir"));
    try testing.expect(!isInspectionOnlyTool("Write"));
    try testing.expect(!isInspectionOnlyTool("Edit"));
    try testing.expect(!isInspectionOnlyTool("Bash"));
    try testing.expect(!isInspectionOnlyTool("RunTests"));
}

test "tool name canonicalization repairs common model aliases" {
    try testing.expectEqualStrings("Edit", canonicalToolNameForArgs("FileEdit", "path=src/main.zig,old_string=a,new_string=b"));
    try testing.expectEqualStrings("Write", canonicalToolNameForArgs("WriteFile", "path=README.md,content=hi"));
    try testing.expectEqualStrings("Read", canonicalToolNameForArgs("View", "file_path=src/main.zig"));
    try testing.expectEqualStrings("git_apply", canonicalToolNameForArgs("GitApply", "patch=diff"));
    try testing.expectEqualStrings("TaskUpdate", canonicalToolNameForArgs("Update", "id=task-1,status=completed"));
    try testing.expectEqualStrings("Edit", canonicalToolNameForArgs("Update", "path=src/main.zig,old_string=a,new_string=b"));
    try testing.expectEqualStrings("Write", canonicalToolNameForArgs("Update", "path=README.md,content=body"));
}

test "concrete action tool classification recognizes edit write and execution tools" {
    try testing.expect(isConcreteActionTool("Edit", "path=src/main.zig,find=a,replace=b"));
    try testing.expect(isConcreteActionTool("FileEdit", "path=src/main.zig,old_string=a,new_string=b"));
    try testing.expect(isConcreteActionTool("Write", "path=README.md,content=hi"));
    try testing.expect(isConcreteActionTool("GitApply", "patch=diff"));
    try testing.expect(isConcreteActionTool("Bash", "command=\"zig build test\""));
    try testing.expect(!isConcreteActionTool("TaskPoll", "id=task-1"));
    try testing.expect(!isConcreteActionTool("TaskOutput", "id=task-1"));
    try testing.expect(!isConcreteActionTool("Read", "path=src/main.zig"));
    try testing.expect(!isConcreteActionTool("Grep", "pattern=foo"));
}

test "tool arg repair guidance catches malformed edit and write calls before execution" {
    const edit_msg = (try buildToolArgRepairGuidance(testing.allocator, "Edit", "path=src/main.zig")) orelse return error.ExpectedEditGuidance;
    defer testing.allocator.free(edit_msg);
    try testing.expect(std.mem.indexOf(u8, edit_msg, "find") != null);

    const write_msg = (try buildToolArgRepairGuidance(testing.allocator, "Write", "path=README.md")) orelse return error.ExpectedWriteGuidance;
    defer testing.allocator.free(write_msg);
    try testing.expect(std.mem.indexOf(u8, write_msg, "content") != null);

    try testing.expect((try buildToolArgRepairGuidance(testing.allocator, "Edit", "path=src/main.zig,old_string=a,new_string=b")) == null);
}

test "action success classification rejects failed write tools" {
    try testing.expect(toolActionSucceeded("Edit", "path=src/main.zig,old_string=a,new_string=b", "edit ok: 1 replacement(s) in src/main.zig at line 10"));
    try testing.expect(!toolActionSucceeded("Edit", "path=src/main.zig,old_string=a,new_string=b", "edit: no match"));
    try testing.expect(!toolActionSucceeded("MultiEdit", "path=src/main.zig,edits=[]", "multi_edit failed: `edits` array is empty -- pass at least one edit"));
    try testing.expect(toolActionSucceeded("Write", "path=README.md,content=hi", "rewrote README.md (3 lines, was 2; 12 bytes)"));
    try testing.expect(!toolActionSucceeded("Write", "path=README.md,content=hi", "write failed: file 'README.md' already exists and has not been read yet in this session."));
}

test "action success classification uses shell result contract" {
    try testing.expect(toolActionSucceeded(
        "Bash",
        "command=\"git status\"",
        "$ git status\n[exit_code=0]\n[shell_result] {\"return_code_interpretation\":\"success\"}\n",
    ));
    try testing.expect(!toolActionSucceeded(
        "Bash",
        "command=\"sed -i '' s/a/b/ missing.txt\"",
        "$ sed -i '' s/a/b/ missing.txt\n[exit_code=1]\n[shell_result] {\"return_code_interpretation\":\"error\"}\n",
    ));
    try testing.expect(toolActionSucceeded(
        "Bash",
        "command=\"grep needle missing.txt\"",
        "$ grep needle missing.txt\n[exit_code=1]\n[shell_result] {\"return_code_interpretation\":\"no_matches_found\"}\n",
    ));
}

test "no-action blocker detection allows explicit terminal blockers only" {
    try testing.expect(looksLikeNoActionOrBlocker("FINAL_NO_ACTION: package-lock.json is not present in this project."));
    try testing.expect(looksLikeNoActionOrBlocker("No changes needed; the dependency is already removed."));
    try testing.expect(!looksLikeNoActionOrBlocker("Confirmed crypto-js is unused. Now let me update package-lock.json to match."));
}

test "read-only stall action requirement only fires for execution tasks" {
    try testing.expect(shouldRequireActionAfterReadOnlyStall("implement the login fix"));
    try testing.expect(shouldRequireActionAfterReadOnlyStall("update the TUI and run tests"));
    try testing.expect(shouldRequireActionAfterReadOnlyStall("create a new provider adapter"));
    try testing.expect(shouldRequireActionAfterReadOnlyStall("make changes to the parser"));
    try testing.expect(!shouldRequireActionAfterReadOnlyStall("explain the project structure"));
    try testing.expect(!shouldRequireActionAfterReadOnlyStall("explain the startup flow"));
    try testing.expect(!shouldRequireActionAfterReadOnlyStall("find every TODO in the repo"));
}

test "bare shell prompt classifier catches terse commands only" {
    try testing.expect(looksLikeBareShellCommandPrompt("ls"));
    try testing.expect(looksLikeBareShellCommandPrompt("git status --short"));
    try testing.expect(looksLikeBareShellCommandPrompt("zig build test"));
    try testing.expect(looksLikeBareShellCommandPrompt("npm test"));
    try testing.expect(looksLikeBareShellCommandPrompt("go test ./..."));
    try testing.expect(!looksLikeBareShellCommandPrompt("go on"));
    try testing.expect(!looksLikeBareShellCommandPrompt("what does git status mean?"));
    try testing.expect(!looksLikeBareShellCommandPrompt("please run npm test"));
}

test "direct bare shell dispatch skips interactive commands" {
    try testing.expect(shouldDirectDispatchBareShellCommandPrompt("pwd"));
    try testing.expect(shouldDirectDispatchBareShellCommandPrompt("git status --short"));
    try testing.expect(!shouldDirectDispatchBareShellCommandPrompt("top"));
    try testing.expect(!shouldDirectDispatchBareShellCommandPrompt("htop"));
    try testing.expect(!shouldDirectDispatchBareShellCommandPrompt("please run npm test"));
}

test "parse choice list from JSON array" {
    const choices = try parseChoiceList(testing.allocator, "[\"Approve\",\"Discuss\",\"Cancel\"]");
    defer freeOwnedStringList(testing.allocator, choices);
    try testing.expectEqual(@as(usize, 3), choices.len);
    try testing.expectEqualStrings("Approve", choices[0]);
    try testing.expectEqualStrings("Cancel", choices[2]);
}

test "parse choice list from delimited text" {
    const choices = try parseChoiceList(testing.allocator, "approve | discuss | cancel");
    defer freeOwnedStringList(testing.allocator, choices);
    try testing.expectEqual(@as(usize, 3), choices.len);
    try testing.expectEqualStrings("discuss", choices[1]);
}

test "looksLikeIncompleteProgressReport does not flag completed analyses" {
    // These are phrases that appear in FINISHED analyses and must
    // not trigger auto-continue. Previously the bare "let me " /
    // "I'll " cues made each of them loop after a tool round.
    const completed_closers = [_][]const u8{
        "Here is the analysis. Let me know if you want more detail on any subsystem.",
        "The project uses Zig 0.16.0. I'll summarize: core/, providers/, cli/.",
        "This is zcode. I'll note that the prompt-section registry is the key primitive.",
        "Done. Let me explain what I changed: two files, one new module.",
        "The build passed. I need to flag one concern about the cache.",
        "Let's review the findings together.",
    };
    for (completed_closers) |text| {
        try std.testing.expect(!looksLikeIncompleteProgressReport(text));
    }
}

test "looksLikeConfirmationSeekingResponse skips end-of-turn offers after a delivered analysis" {
    // The exact shape from the Kimi loop report: model produced a
    // bulleted analysis + closing follow-up offer. Must NOT fire.
    const long_analysis =
        \\Based on my analysis of your zcode project, here are the key improvement opportunities:
        \\
        \\- **Prompt registry**: landed in 0.10.326, now covers instruction and git caches.
        \\- **Sandbox coverage**: 170 files written, 30 untouched.
        \\- **Test coverage**: five thin modules filled, 31 new tests.
        \\
        \\Would you like me to focus on any specific area, such as writing tests for the uncovered files or refactoring the status panel?
    ;
    try std.testing.expect(!looksLikeConfirmationSeekingResponse(long_analysis));
}

test "looksLikeConfirmationSeekingResponse still fires on short mid-task blockers" {
    // Short, no bullets, no code -- genuine "can I start this work?"
    // These MUST still auto-continue.
    try std.testing.expect(looksLikeConfirmationSeekingResponse("Should I go ahead and rewrite the parser?"));
    try std.testing.expect(looksLikeConfirmationSeekingResponse("Would you like me to proceed?"));
    try std.testing.expect(looksLikeConfirmationSeekingResponse("Do you want me to continue?"));
}

test "looksLikeConfirmationSeekingResponse skips offers inside a code-bearing response" {
    const with_code =
        \\Here's the fix:
        \\
        \\```zig
        \\pub fn foo() void {}
        \\```
        \\
        \\Would you like me to run the tests now?
    ;
    try std.testing.expect(!looksLikeConfirmationSeekingResponse(with_code));
}

test "looksLikeIncompleteProgressReport still flags genuine in-flight work" {
    // These phrases genuinely indicate the model is mid-task and
    // must auto-continue. The weak-starter branch requires a
    // concrete action verb after "let me" / "i'll" / "i need to".
    const in_flight = [_][]const u8{
        "Let me run the tests now.",
        "I'll check the config file.",
        "I need to read the source before answering.",
        "Next I'll grep for the handler.",
        "Now let me inspect the build output.",
        "I still need to verify the cache entries.",
        "First I'll apply the patch, then re-run the suite.",
    };
    for (in_flight) |text| {
        try std.testing.expect(looksLikeIncompleteProgressReport(text));
    }
}

test "permission rule gate: deny-first-then-allow yields a denied trace" {
    // Focused unit test on the deny branch of executeToolCall's rule gate.
    // Standing up a full ToolExecContext (mcp client, audit logger, policy,
    // browser bridge) is heavy and brittle, so this mirrors exactly what the
    // gate does for a matched rule: pick the action via Store.decide() (the new
    // deny-wins precedence) and, for .deny, build a .denied ToolTrace via
    // formatPermissionRuleReason + buildToolTrace. Locks that a deny rule
    // defined BEFORE a tool-wide allow rule produces a denied trace - the load-
    // bearing permissions-01 regression (legacy match() would have returned the
    // allow here).
    var store = permission_rules_mod.Store.init(testing.allocator);
    defer store.deinit();
    try store.addRule(.deny, .global, "Bash", "curl*", "rules.tsv", 1, "test");
    try store.addRule(.allow, .global, "Bash", "*", "rules.tsv", 2, "test");

    const args = "{\"command\":\"curl evil.com\"}";
    const decided = store.decide("/repo", "Bash", args).?;
    try testing.expectEqual(permission_rules_mod.Action.deny, decided.action);

    const output = try formatPermissionRuleReason(testing.allocator, "denied by permission rule", decided.match);
    var trace = try buildToolTrace(testing.allocator, "Bash", args, .MEDIUM, .denied, false, 0, output);
    defer trace.deinit(testing.allocator);

    try testing.expectEqual(types.ApprovalState.denied, trace.approval_state);
    try testing.expect(!trace.executed);
    try testing.expect(std.mem.indexOf(u8, trace.output, "denied by permission rule") != null);
}

test "path-safety gate blocks Edit to .bashrc even in yolo + non-interactive (bypass-immune)" {
    const test_helpers = @import("core/test_helpers.zig");
    const logger_mod = @import("core/logger.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_dir = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(log_dir);

    var audit = try logger_mod.AuditLogger.init(testing.allocator, log_dir);
    defer audit.deinit();

    var session_tools = std.StringHashMap(void).init(testing.allocator);
    defer session_tools.deinit();

    // cfg/policy/mcp/browser are never dereferenced on the bypass-immune
    // non-interactive block path, so leave them undefined.
    const ctx = ToolExecContext{
        .allocator = testing.allocator,
        .cwd = log_dir,
        .cfg = undefined,
        .policy = undefined,
        .mcp = undefined,
        .browser = null,
        .audit = &audit,
        .active_agent = null,
        .interactive = false,
        .auto_approve_high = false,
        .plan_approved = false,
        .yolo_mode = true, // yolo must NOT bypass the path-safety guard
        .approval_handler = null,
        .ask_user_ctx = null,
        .ask_user_fn = null,
        .session_approved_tools = &session_tools,
        .permission_rules = null,
        .cloud_telemetry_opt_in = false,
        .control_plane_url = "",
        .control_plane_token = "",
        .is_git_repo = false,
    };

    const maybe = try pathSafetyGate(ctx, "Edit", "path=/home/u/.bashrc;find=x;replace=y", clock.nowSeconds());
    try testing.expect(maybe != null);
    var trace = maybe.?;
    defer trace.deinit(testing.allocator);

    try testing.expectEqual(types.ApprovalState.blocked, trace.approval_state);
    try testing.expect(!trace.executed);
    try testing.expect(std.mem.indexOf(u8, trace.output, "path-safety guard") != null);

    // A safe path returns null (gate does not interfere).
    const safe = try pathSafetyGate(ctx, "Edit", "path=/home/u/src/main.zig;find=x;replace=y", clock.nowSeconds());
    try testing.expect(safe == null);

    // A non-edit tool is never gated regardless of path.
    const non_edit = try pathSafetyGate(ctx, "Bash", "command=cat /home/u/.bashrc", clock.nowSeconds());
    try testing.expect(non_edit == null);
}

test "permission_mode_override drives the gate through evaluate (acceptEdits)" {
    // Task 2 (permissions-06): a live permission-mode override wins over the
    // persisted config string, and the resolved mode drives approval.evaluate
    // exactly as the gate does. cfg.approval_mode is set to a LEGACY mode
    // ("manual") to prove the override -- not the config -- is what flows in.
    const config_mod = @import("core/config.zig");
    var cfg = try config_mod.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);
    testing.allocator.free(cfg.approval_mode);
    cfg.approval_mode = try testing.allocator.dupe(u8, "manual");

    var session_tools = std.StringHashMap(void).init(testing.allocator);
    defer session_tools.deinit();

    // Only cfg / session_approved_tools / permission_mode_override are read by
    // effectiveApprovalMode and the test below; the rest stay undefined.
    const ctx = ToolExecContext{
        .allocator = testing.allocator,
        .cwd = "/repo",
        .cfg = &cfg,
        .policy = undefined,
        .mcp = undefined,
        .browser = null,
        .audit = undefined,
        .active_agent = null,
        .interactive = false,
        .auto_approve_high = false,
        .plan_approved = false,
        .yolo_mode = false,
        .approval_handler = null,
        .ask_user_ctx = null,
        .ask_user_fn = null,
        .session_approved_tools = &session_tools,
        .permission_rules = null,
        .cloud_telemetry_opt_in = false,
        .control_plane_url = "",
        .control_plane_token = "",
        .permission_mode_override = .acceptEdits,
    };

    // The override wins over the legacy config string.
    try testing.expectEqualStrings("acceptEdits", effectiveApprovalMode(ctx));

    // Drive evaluate exactly as the gate does. A Write (edit tool) at MEDIUM is
    // auto-approved under acceptEdits; a Bash (non-edit) at MEDIUM is not.
    const write_dec = try approval_mod.evaluate(
        effectiveApprovalMode(ctx),
        .MEDIUM,
        approval_mod.isEditTool("Write"),
        ctx.interactive,
        ctx.auto_approve_high or ctx.plan_approved,
        ctx.yolo_mode,
        null,
        null,
        null,
    );
    try testing.expect(write_dec.approved);
    try testing.expectEqual(types.ApprovalState.auto_approved, write_dec.state);

    const bash_dec = try approval_mod.evaluate(
        effectiveApprovalMode(ctx),
        .MEDIUM,
        approval_mod.isEditTool("Bash"),
        ctx.interactive,
        ctx.auto_approve_high or ctx.plan_approved,
        ctx.yolo_mode,
        null,
        null,
        null,
    );
    try testing.expect(!bash_dec.approved);
}

test "no permission_mode_override falls back to cfg.approval_mode byte-for-byte" {
    // No-regression: when the override is absent the gate must pass the config
    // string unchanged so legacy tiered-auto/manual/strict behavior is intact.
    const config_mod = @import("core/config.zig");
    var cfg = try config_mod.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);
    testing.allocator.free(cfg.approval_mode);
    cfg.approval_mode = try testing.allocator.dupe(u8, "tiered-auto");

    var session_tools = std.StringHashMap(void).init(testing.allocator);
    defer session_tools.deinit();

    const ctx = ToolExecContext{
        .allocator = testing.allocator,
        .cwd = "/repo",
        .cfg = &cfg,
        .policy = undefined,
        .mcp = undefined,
        .browser = null,
        .audit = undefined,
        .active_agent = null,
        .interactive = false,
        .auto_approve_high = false,
        .plan_approved = false,
        .yolo_mode = false,
        .approval_handler = null,
        .ask_user_ctx = null,
        .ask_user_fn = null,
        .session_approved_tools = &session_tools,
        .permission_rules = null,
        .cloud_telemetry_opt_in = false,
        .control_plane_url = "",
        .control_plane_token = "",
        // permission_mode_override left at its null default.
    };

    try testing.expectEqualStrings("tiered-auto", effectiveApprovalMode(ctx));
    try testing.expect(ctx.cfg.approval_mode.ptr == effectiveApprovalMode(ctx).ptr);
}

test "effectiveApproval prefers the SDK relay when host-driven, else falls back" {
    // sdk-headless-05: when `sdk_relay` is set the gate routes permission to the
    // relay (even non-interactive); without it the existing precedence holds
    // (non-interactive -> none; interactive -> REPL handler or stdin).
    var session_tools = std.StringHashMap(void).init(testing.allocator);
    defer session_tools.deinit();

    // A trivial relay marker + prompt; we only assert pointer identity here.
    const Relay = struct {
        var sentinel: u8 = 0;
        fn prompt(c: *anyopaque, message: []const u8) anyerror!types.ApprovalResponse {
            _ = c;
            _ = message;
            return .approve;
        }
    };
    const relay_handler = ApprovalHandler{ .ctx = @ptrCast(&Relay.sentinel), .prompt = Relay.prompt };

    // Base context: non-interactive, no relay -> no approver (auto-deny path).
    var base = ToolExecContext{
        .allocator = testing.allocator,
        .cwd = "/repo",
        .cfg = undefined,
        .policy = undefined,
        .mcp = undefined,
        .browser = null,
        .audit = undefined,
        .active_agent = null,
        .interactive = false,
        .auto_approve_high = false,
        .plan_approved = false,
        .yolo_mode = false,
        .approval_handler = null,
        .ask_user_ctx = null,
        .ask_user_fn = null,
        .session_approved_tools = &session_tools,
        .permission_rules = null,
        .cloud_telemetry_opt_in = false,
        .control_plane_url = "",
        .control_plane_token = "",
    };

    var tok: u8 = 0;

    // 1. Non-interactive, no relay: no approver, and not "interactive" for the gate.
    {
        const a = effectiveApproval(base, &tok);
        try testing.expect(a.prompt == null);
        try testing.expect(!effectiveInteractive(base));
    }

    // 2. Host-driven (relay set), still non-interactive: relay wins and the gate
    //    treats the session as interactive.
    base.sdk_relay = relay_handler;
    {
        const a = effectiveApproval(base, &tok);
        try testing.expect(a.prompt == Relay.prompt);
        try testing.expectEqual(@as(*anyopaque, @ptrCast(&Relay.sentinel)), a.ctx.?);
        try testing.expect(effectiveInteractive(base));
    }

    // 3. No relay, interactive, no REPL handler: stdin fallback.
    base.sdk_relay = null;
    base.interactive = true;
    {
        const a = effectiveApproval(base, &tok);
        try testing.expect(a.prompt == stdinApprovalPromptWithCtx);
    }
}

test "acceptEdits bash auto-allow gate: filesystem command allows, non-filesystem passes through" {
    // bash-shell-09: the gate's acceptEdits bash auto-allow decision. Under
    // effective mode acceptEdits, a fully-filesystem command (mkdir build) is
    // auto-allowed by the mode -- the gate returns it directly as .auto_approved
    // without prompting. A non-filesystem command (python x.py) is NOT auto-
    // allowed; it falls through to the generic gate (which, non-interactive at
    // MEDIUM, denies). We test the gate's decision helper directly so there is no
    // filesystem side effect from actually dispatching the command.
    //
    // zcode serializes tool args to key=value / "key":"value" text before the
    // gate (parse_helpers.parseToolArgs), not raw JSON with outer braces, so the
    // args here use that on-the-wire shape. getArg parses both forms.
    const fs_args = "command=mkdir build";
    const fs_args_json = "\"command\":\"mkdir build\"";
    const py_args = "command=python x.py";

    // Canonical bash tool + acceptEdits + filesystem command -> auto-allow.
    try testing.expect(acceptEditsBashAutoAllows("Bash", "acceptEdits", fs_args));
    try testing.expect(acceptEditsBashAutoAllows("Bash", "acceptEdits", fs_args_json));
    // Tool-name aliases are covered (effective_name may be the raw name).
    try testing.expect(acceptEditsBashAutoAllows("bash", "acceptEdits", fs_args));
    try testing.expect(acceptEditsBashAutoAllows("shell", "acceptEdits", fs_args));

    // Non-filesystem command -> passthrough (the gate does not short-circuit).
    try testing.expect(!acceptEditsBashAutoAllows("Bash", "acceptEdits", py_args));

    // Only acceptEdits triggers the auto-allow; default/plan/tiered-auto do not.
    try testing.expect(!acceptEditsBashAutoAllows("Bash", "default", fs_args));
    try testing.expect(!acceptEditsBashAutoAllows("Bash", "plan", fs_args));
    try testing.expect(!acceptEditsBashAutoAllows("Bash", "tiered-auto", fs_args));

    // Non-bash tools never use this path even under acceptEdits.
    try testing.expect(!acceptEditsBashAutoAllows("Write", "acceptEdits", fs_args));

    // A missing command field -> passthrough (no auto-allow).
    try testing.expect(!acceptEditsBashAutoAllows("Bash", "acceptEdits", "path=foo"));
}

test "acceptEdits bash auto-allow gate: deny rule precedes the mode auto-allow" {
    // bash-shell-09 ordering: an explicit `deny Bash(mkdir*)` rule must still
    // deny `mkdir build` even in acceptEdits mode. The gate runs the rule block
    // (which returns .deny and short-circuits) BEFORE the acceptEdits bash check,
    // so deny precedence holds structurally. We prove it two ways: (1) the rule
    // store's decide() returns .deny for the command, and (2) absent the rule the
    // mode helper WOULD have auto-allowed it -- so the deny rule is what wins.
    const permission_rules = @import("core/permission_rules.zig");
    var store = permission_rules.Store.init(testing.allocator);
    defer store.deinit();

    try store.addRule(.deny, .global, "Bash", "mkdir*", "rules.tsv", 1, "test");

    const fs_args = "command=mkdir build";

    // The rule block (which runs first in executeToolCall) returns deny. The
    // store's args matcher floats `mkdir*` against the serialized args text.
    const decided = store.decide("/repo", "Bash", fs_args).?;
    try testing.expectEqual(permission_rules.Action.deny, decided.action);

    // Absent the rule, acceptEdits would auto-allow -- confirming the deny rule,
    // evaluated earlier in the gate, is what overrides it.
    try testing.expect(acceptEditsBashAutoAllows("Bash", "acceptEdits", fs_args));
}

// --- hooks-20 (Task 9): PreToolUse permissionDecision allow/ask + updatedInput ---

test "preToolHookAction maps permissionDecision and blocked to an approval action" {
    // Pure decision mapping (no IO): the load-bearing translation from a hook
    // result into the approval branch executeToolCall takes.
    const mk = struct {
        fn r(blocked: bool, perm: hooks_mod.HookPermission) hooks_mod.HookRunResult {
            return .{ .ran = true, .blocked = blocked, .output = "", .permission = perm };
        }
    };

    // permissionDecision drives allow / ask / deny.
    try testing.expectEqual(PreToolHookAction.allow, preToolHookAction(mk.r(false, .allow)));
    try testing.expectEqual(PreToolHookAction.ask, preToolHookAction(mk.r(false, .ask)));
    try testing.expectEqual(PreToolHookAction.deny, preToolHookAction(mk.r(false, .deny)));
    // No decision -> the normal approval flow decides.
    try testing.expectEqual(PreToolHookAction.none, preToolHookAction(mk.r(false, .none)));
    // A blocking hook (exit 2 / decision:block) denies regardless of permission.
    try testing.expectEqual(PreToolHookAction.deny, preToolHookAction(mk.r(true, .none)));
    // deny wins over a stray allow so a blocking hook is never auto-approved.
    try testing.expectEqual(PreToolHookAction.deny, preToolHookAction(mk.r(true, .allow)));
}

const PreToolHookTestEnv = struct {
    prev_home: ?[]u8,
    prev_xdg: ?[]u8,
    allocator: std.mem.Allocator,

    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;

    fn install(allocator: std.mem.Allocator, home: []const u8) !PreToolHookTestEnv {
        const env_mod = @import("core/env.zig");
        const paths_mod = @import("core/paths.zig");
        const prev_home = if (env_mod.getOwned(allocator, "HOME")) |v| v else |_| null;
        const prev_xdg = if (env_mod.getOwned(allocator, "XDG_CONFIG_HOME")) |v| v else |_| null;

        const home_z = try allocator.dupeZ(u8, home);
        defer allocator.free(home_z);
        _ = setenv("HOME", home_z, 1);
        _ = unsetenv("XDG_CONFIG_HOME");

        const zcode_home = try std.fs.path.join(allocator, &.{ home, ".zcode" });
        defer allocator.free(zcode_home);
        try paths_mod.ensureDir(zcode_home);
        return .{ .prev_home = prev_home, .prev_xdg = prev_xdg, .allocator = allocator };
    }

    fn deinit(self: *PreToolHookTestEnv) void {
        if (self.prev_home) |h| {
            const z = self.allocator.dupeZ(u8, h) catch return;
            defer self.allocator.free(z);
            _ = setenv("HOME", z, 1);
            self.allocator.free(h);
        } else _ = unsetenv("HOME");
        if (self.prev_xdg) |x| {
            const z = self.allocator.dupeZ(u8, x) catch return;
            defer self.allocator.free(z);
            _ = setenv("XDG_CONFIG_HOME", z, 1);
            self.allocator.free(x);
        } else _ = unsetenv("XDG_CONFIG_HOME");
    }
};

/// Recording approval handler: counts how many times the front-end was asked to
/// approve a tool, and always answers `approve`. Lets the tests assert WHETHER a
/// prompt happened (the observable difference between hook allow / ask / none).
const RecordingApprover = struct {
    asked: usize = 0,

    fn prompt(ctx: *anyopaque, message: []const u8) anyerror!types.ApprovalResponse {
        _ = message;
        const self: *RecordingApprover = @ptrCast(@alignCast(ctx));
        self.asked += 1;
        return .approve;
    }

    fn handler(self: *RecordingApprover) ApprovalHandler {
        return .{ .ctx = @ptrCast(self), .prompt = RecordingApprover.prompt };
    }
};

/// Stand up a hermetic ToolExecContext + a user-scope settings.json PreToolUse
/// hook, run `executeToolCall` against a Read of a temp file, and return the
/// resulting trace plus how many times the approver was asked. Single helper so
/// the four decision branches (allow / ask / deny / updatedInput) share setup.
fn runPreToolHookCase(
    allocator: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    approval_mode: []const u8,
    hook_command: []const u8,
    tool_name: []const u8,
    tool_args: []const u8,
    approver: *RecordingApprover,
) !ToolTrace {
    const config_mod = @import("core/config.zig");
    const policy_mod = @import("policy/policy.zig");
    const logger_mod = @import("core/logger.zig");
    const test_helpers = @import("core/test_helpers.zig");

    const cwd = try test_helpers.tmpDirCwd(allocator, tmp);
    defer allocator.free(cwd);

    // User-scope settings.json (HOME/.zcode) needs no trust gate.
    const settings = try std.fmt.allocPrint(
        allocator,
        "{{\"hooks\":{{\"PreToolUse\":[{{\"matcher\":\"*\",\"hooks\":[{{\"type\":\"command\",\"command\":\"{s}\"}}]}}]}}}}",
        .{hook_command},
    );
    defer allocator.free(settings);
    const rt = @import("zcode_runtime");
    tmp.dir.createDirPath(rt.io, ".zcode") catch {};
    try tmp.dir.writeFile(rt.io, .{ .sub_path = ".zcode/settings.json", .data = settings });

    var cfg = try config_mod.Config.init(allocator);
    defer cfg.deinit(allocator);
    allocator.free(cfg.approval_mode);
    cfg.approval_mode = try allocator.dupe(u8, approval_mode);
    cfg.mcp_tool_bridge_enabled = false; // ctx.mcp stays undefined and unused
    allocator.free(cfg.sandbox);
    cfg.sandbox = try allocator.dupe(u8, "danger-full-access"); // no sandbox blocking in tests

    var policy = try policy_mod.Policy.init(allocator);
    defer policy.deinit();

    var audit = try logger_mod.AuditLogger.init(allocator, cwd);
    defer audit.deinit();

    var session_tools = std.StringHashMap(void).init(allocator);
    defer session_tools.deinit();

    const ctx = ToolExecContext{
        .allocator = allocator,
        .cwd = cwd,
        .cfg = &cfg,
        .policy = &policy,
        .mcp = undefined,
        .browser = null,
        .audit = &audit,
        .active_agent = null,
        .interactive = true,
        .auto_approve_high = false,
        .plan_approved = false,
        .yolo_mode = false,
        .approval_handler = approver.handler(),
        .ask_user_ctx = null,
        .ask_user_fn = null,
        .session_approved_tools = &session_tools,
        .permission_rules = null,
        .cloud_telemetry_opt_in = false,
        .control_plane_url = "",
        .control_plane_token = "",
        .is_git_repo = false,
    };

    return executeToolCall(ctx, tool_name, tool_args);
}

test "hooks-20: PreToolUse allow auto-approves without asking the user" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const test_helpers = @import("core/test_helpers.zig");
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);
    var env_ov = try PreToolHookTestEnv.install(alloc, root);
    defer env_ov.deinit();

    // A target file to Read so dispatch produces a real executed trace.
    const rt = @import("zcode_runtime");
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "target.txt", .data = "hello" });
    const path = try test_helpers.tmpDirPath(alloc, &tmp, "target.txt");
    defer alloc.free(path);
    const args = try std.fmt.allocPrint(alloc, "path={s}", .{path});
    defer alloc.free(args);

    var approver = RecordingApprover{};
    // manual mode would normally prompt for every tool; the hook's allow skips it.
    var trace = try runPreToolHookCase(alloc, &tmp, "manual", "echo '{\\\"hookSpecificOutput\\\":{\\\"permissionDecision\\\":\\\"allow\\\"}}'", "Read", args, &approver);
    defer trace.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), approver.asked); // never prompted
    try testing.expect(trace.executed);
    try testing.expectEqual(types.ApprovalState.user_approved, trace.approval_state);
}

test "hooks-20: PreToolUse ask forces a prompt even when the mode would auto-allow" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const test_helpers = @import("core/test_helpers.zig");
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);
    var env_ov = try PreToolHookTestEnv.install(alloc, root);
    defer env_ov.deinit();

    const rt = @import("zcode_runtime");
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "target.txt", .data = "hi" });
    const path = try test_helpers.tmpDirPath(alloc, &tmp, "target.txt");
    defer alloc.free(path);
    const args = try std.fmt.allocPrint(alloc, "path={s}", .{path});
    defer alloc.free(args);

    var approver = RecordingApprover{};
    // tiered-auto auto-approves a LOW Read WITHOUT asking; the hook's ask forces
    // the prompt anyway (the approver answers approve, so it still runs).
    var trace = try runPreToolHookCase(alloc, &tmp, "tiered-auto", "echo '{\\\"hookSpecificOutput\\\":{\\\"permissionDecision\\\":\\\"ask\\\"}}'", "Read", args, &approver);
    defer trace.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), approver.asked); // forced exactly one prompt
    try testing.expect(trace.executed);
}

test "hooks-20: PreToolUse none under tiered-auto auto-approves without a prompt" {
    // Baseline so the `ask` test's assertion is meaningful: with no hook decision
    // a LOW Read under tiered-auto runs without ever asking the approver.
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const test_helpers = @import("core/test_helpers.zig");
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);
    var env_ov = try PreToolHookTestEnv.install(alloc, root);
    defer env_ov.deinit();

    const rt = @import("zcode_runtime");
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "target.txt", .data = "hi" });
    const path = try test_helpers.tmpDirPath(alloc, &tmp, "target.txt");
    defer alloc.free(path);
    const args = try std.fmt.allocPrint(alloc, "path={s}", .{path});
    defer alloc.free(args);

    var approver = RecordingApprover{};
    var trace = try runPreToolHookCase(alloc, &tmp, "tiered-auto", "echo hook-ran", "Read", args, &approver);
    defer trace.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), approver.asked);
    try testing.expect(trace.executed);
}

test "hooks-20: PreToolUse deny blocks the tool without asking the user" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const test_helpers = @import("core/test_helpers.zig");
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);
    var env_ov = try PreToolHookTestEnv.install(alloc, root);
    defer env_ov.deinit();

    const rt = @import("zcode_runtime");
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "target.txt", .data = "secret" });
    const path = try test_helpers.tmpDirPath(alloc, &tmp, "target.txt");
    defer alloc.free(path);
    const args = try std.fmt.allocPrint(alloc, "path={s}", .{path});
    defer alloc.free(args);

    var approver = RecordingApprover{};
    var trace = try runPreToolHookCase(alloc, &tmp, "tiered-auto", "echo '{\\\"hookSpecificOutput\\\":{\\\"permissionDecision\\\":\\\"deny\\\",\\\"permissionDecisionReason\\\":\\\"blocked by policy\\\"}}'", "Read", args, &approver);
    defer trace.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), approver.asked);
    try testing.expect(!trace.executed);
    try testing.expectEqual(types.ApprovalState.blocked, trace.approval_state);
}

test "hooks-20: PreToolUse updatedInput rewrites the tool args before execution" {
    // The hook rewrites `path` to a different file; the trace must record the
    // rewritten args (and the Read must reflect the rewritten target).
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const test_helpers = @import("core/test_helpers.zig");
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);
    var env_ov = try PreToolHookTestEnv.install(alloc, root);
    defer env_ov.deinit();

    const rt = @import("zcode_runtime");
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "rewritten.txt", .data = "REWRITTEN_CONTENT" });
    const rewritten_path = try test_helpers.tmpDirPath(alloc, &tmp, "rewritten.txt");
    defer alloc.free(rewritten_path);

    // The hook emits updatedInput pointing at rewritten.txt regardless of the
    // model's original (nonexistent) path. The JSON is `\"`-escaped because it is
    // embedded into the settings.json `"command"` string value (same shape as the
    // allow/ask/deny cases above); the shell's echo strips the backslashes.
    const hook_cmd = try std.fmt.allocPrint(
        alloc,
        "echo '{{\\\"hookSpecificOutput\\\":{{\\\"updatedInput\\\":{{\\\"path\\\":\\\"{s}\\\"}}}}}}'",
        .{rewritten_path},
    );
    defer alloc.free(hook_cmd);

    var approver = RecordingApprover{};
    var trace = try runPreToolHookCase(alloc, &tmp, "tiered-auto", hook_cmd, "Read", "path=/nonexistent/original.txt", &approver);
    defer trace.deinit(alloc);

    // The executed trace records the rewritten args, not the model's.
    try testing.expect(std.mem.indexOf(u8, trace.args, "rewritten.txt") != null);
    try testing.expect(std.mem.indexOf(u8, trace.args, "original.txt") == null);
}

test "logToolInvocationRecord increments the tool_executions_total counter" {
    const alloc = testing.allocator;
    const test_helpers = @import("core/test_helpers.zig");
    const logger_mod = @import("core/logger.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const logs_dir = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(logs_dir);

    var audit = try logger_mod.AuditLogger.init(alloc, logs_dir);
    defer audit.deinit();

    const m = metrics.globalMetrics();
    const labeled = try metrics.labeledName(alloc, metrics.Names.tool_executions_total, &.{.{ "tool", "Read" }});
    defer alloc.free(labeled);
    const before = m.getCounter(labeled);

    // Build a minimal trace owned by the allocator; logToolInvocationRecord
    // borrows it (does not take ownership), so we free it ourselves.
    var trace = ToolTrace{
        .name = try alloc.dupe(u8, "Read"),
        .args = try alloc.dupe(u8, "path=/tmp/x"),
        .risk = .LOW,
        .approval_state = .auto_approved,
        .executed = true,
        .duration_ms = 0,
        .output = try alloc.dupe(u8, "ok"),
    };
    defer trace.deinit(alloc);

    logToolInvocationRecord(alloc, &audit, false, "", "", trace, 0, 0, 0);

    try testing.expectEqual(before + 1, m.getCounter(labeled));
}

test "analytics-10: telemetry attribute allowlist drops non-allowlisted string fields from the payload" {
    const alloc = testing.allocator;

    // Allowlist only tool_name: risk_tier / approval_state must NOT appear,
    // while the non-attribute numeric fields and output are always present.
    const allow = [_][]const u8{"tool_name"};
    telemetry_attributes.configure(alloc, &allow, null);
    defer telemetry_attributes.reset();

    const record = types.ToolInvocationRecord{
        .tool_name = "Read",
        .args_hash = 18446744073709551615, // u64 max: must survive (no i64 overflow)
        .risk_tier = .LOW,
        .approval_state = .auto_approved,
        .start_ts = 100,
        .end_ts = 200,
        .exit_status = 0,
    };
    var trace = ToolTrace{
        .name = try alloc.dupe(u8, "Read"),
        .args = try alloc.dupe(u8, "path=/tmp/x"),
        .risk = .LOW,
        .approval_state = .auto_approved,
        .executed = true,
        .duration_ms = 0,
        .output = try alloc.dupe(u8, "ok"),
    };
    defer trace.deinit(alloc);

    const payload = try buildFilteredToolInvocationPayload(alloc, record, trace);
    defer alloc.free(payload);

    try testing.expect(std.mem.indexOf(u8, payload, "\"tool_name\"") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "\"risk_tier\"") == null);
    try testing.expect(std.mem.indexOf(u8, payload, "\"approval_state\"") == null);
    // Non-attribute fields always present; u64-max hash survives intact.
    try testing.expect(std.mem.indexOf(u8, payload, "\"args_hash\":18446744073709551615") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "\"exit_status\":0") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "\"output\":\"ok\"") != null);
}

test "analytics-10: cardinality limit collapses the overflow value to <other> in the payload" {
    const alloc = testing.allocator;

    // No allowlist (keep all keys) but a cardinality limit of 1 on every key:
    // the second distinct tool_name value collapses to "<other>".
    telemetry_attributes.configure(alloc, null, 1);
    defer telemetry_attributes.reset();

    const base = types.ToolInvocationRecord{
        .tool_name = "Read",
        .args_hash = 7,
        .risk_tier = .LOW,
        .approval_state = .auto_approved,
        .start_ts = 0,
        .end_ts = 0,
        .exit_status = 0,
    };
    var trace = ToolTrace{
        .name = try alloc.dupe(u8, "Read"),
        .args = try alloc.dupe(u8, ""),
        .risk = .LOW,
        .approval_state = .auto_approved,
        .executed = true,
        .duration_ms = 0,
        .output = try alloc.dupe(u8, ""),
    };
    defer trace.deinit(alloc);

    const first = try buildFilteredToolInvocationPayload(alloc, base, trace);
    defer alloc.free(first);
    try testing.expect(std.mem.indexOf(u8, first, "\"tool_name\":\"Read\"") != null);

    var second_record = base;
    second_record.tool_name = "Write";
    const second = try buildFilteredToolInvocationPayload(alloc, second_record, trace);
    defer alloc.free(second);
    // "Write" is the 2nd distinct tool_name value -> collapsed to "<other>".
    try testing.expect(std.mem.indexOf(u8, second, "\"tool_name\":\"<other>\"") != null);
    try testing.expect(std.mem.indexOf(u8, second, "\"tool_name\":\"Write\"") == null);
}
