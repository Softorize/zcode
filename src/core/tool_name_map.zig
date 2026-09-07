//! P1 (PRD #534) identifier reconciliation: map zcode's internal / legacy tool
//! identifiers to the reference-exact model-facing tool names verified from
//! claude-code-main `TOOL_NAME` constants. The schema builder advertises the
//! canonical name so the model sees exactly what Claude Code exposes; internal
//! dispatch may still accept the legacy aliases for robustness.
//!
//! Pure module: a name in, a name out. No allocation, no IO.

const std = @import("std");

/// Authoritative set of reference-exact model-facing tool names
/// (claude-code-main TOOL_NAME constants), minus auth/Windows/Ant-only tools.
pub const reference_names = [_][]const u8{
    "Agent",                "AskUserQuestion",     "Bash",
    "CronCreate",           "CronDelete",          "CronList",
    "Edit",                 "EnterPlanMode",       "EnterWorktree",
    "ExitPlanMode",         "ExitWorktree",        "EndConversation",
    "Glob",                 "Grep",                "ListAgents",
    "ListMcpResourcesTool", "LSP",                 "Monitor",
    "MultiEdit",            "NotebookEdit",        "PushNotification",
    "Read",                 "ReadMcpResourceTool", "ReadMcpResourceDirTool",
    "ReportFindings",       "ScheduleWakeup",      "SendMessage",
    "SendUserFile",         "SendUserMessage",     "Skill",
    "Sleep",                "Task",                "TaskCreate",
    "TaskGet",              "TaskList",            "TaskOutput",
    "TaskStop",             "TaskUpdate",          "TeamCreate",
    "TeamDelete",           "TodoWrite",           "ToolSearch",
    "WebFetch",             "WebSearch",           "Write",
};

const Pair = struct { alias: []const u8, canonical: []const u8 };

/// Legacy/internal alias -> reference-exact name. Aliases not listed here are
/// returned unchanged (already canonical, or zcode-only with no reference name).
const aliases = [_]Pair{
    .{ .alias = "file_read", .canonical = "Read" },
    .{ .alias = "read", .canonical = "Read" },
    .{ .alias = "file_write", .canonical = "Write" },
    .{ .alias = "write", .canonical = "Write" },
    .{ .alias = "file_edit", .canonical = "Edit" },
    .{ .alias = "edit", .canonical = "Edit" },
    // tools-06: MultiEdit is its OWN reference tool (cc_tool_order.json lists
    // it as a distinct entry, index 9, next to Edit at index 8), not an Edit
    // alias. The reference's LEGACY_TOOL_NAME_ALIASES table has no MultiEdit
    // entry. Collapsing it onto Edit meant a permission rule `deny:
    // MultiEdit(*)` also silently blocked plain Edit calls.
    .{ .alias = "multi_edit", .canonical = "MultiEdit" },
    .{ .alias = "file_multi_edit", .canonical = "MultiEdit" },
    .{ .alias = "AgentRun", .canonical = "Agent" },
    .{ .alias = "agent_run", .canonical = "Agent" },
    .{ .alias = "shell", .canonical = "Bash" },
    .{ .alias = "bash", .canonical = "Bash" },
    .{ .alias = "glob", .canonical = "Glob" },
    .{ .alias = "grep", .canonical = "Grep" },
    .{ .alias = "web_fetch", .canonical = "WebFetch" },
    .{ .alias = "web_search", .canonical = "WebSearch" },
    .{ .alias = "todo_write", .canonical = "TodoWrite" },
    .{ .alias = "notebook", .canonical = "NotebookEdit" },
    .{ .alias = "notebook_edit", .canonical = "NotebookEdit" },
    .{ .alias = "sleep", .canonical = "Sleep" },
    .{ .alias = "skill", .canonical = "Skill" },
    .{ .alias = "command", .canonical = "Skill" },
    .{ .alias = "enter_plan_mode", .canonical = "EnterPlanMode" },
    .{ .alias = "exit_plan_mode", .canonical = "ExitPlanMode" },
    .{ .alias = "enter_worktree", .canonical = "EnterWorktree" },
    .{ .alias = "exit_worktree", .canonical = "ExitWorktree" },
    .{ .alias = "task_get", .canonical = "TaskGet" },
    .{ .alias = "task_output", .canonical = "TaskOutput" },
    .{ .alias = "ask_user_question", .canonical = "AskUserQuestion" },
    .{ .alias = "mcp_resources_list", .canonical = "ListMcpResourcesTool" },
    .{ .alias = "mcp_resource_read", .canonical = "ReadMcpResourceTool" },
    .{ .alias = "mcp_resource_read_dir", .canonical = "ReadMcpResourceDirTool" },
    .{ .alias = "lsp", .canonical = "LSP" },
    .{ .alias = "tool_search", .canonical = "ToolSearch" },
    .{ .alias = "monitor", .canonical = "Monitor" },
    .{ .alias = "schedule_wakeup", .canonical = "ScheduleWakeup" },
    .{ .alias = "list_agents", .canonical = "ListAgents" },
    .{ .alias = "report_findings", .canonical = "ReportFindings" },
    .{ .alias = "push_notification", .canonical = "PushNotification" },
    .{ .alias = "send_user_file", .canonical = "SendUserFile" },
    .{ .alias = "send_user_message", .canonical = "SendUserMessage" },
    .{ .alias = "end_conversation", .canonical = "EndConversation" },
    // tools-04: "AttachContext" is zcode's own renamed file-attachment tool
    // (previously misnamed "Brief"); it has no reference counterpart of its
    // own, so it is NOT listed here -- only the reference's real "Brief"
    // alias target (SendUserMessage, below) belongs in this table.
    .{ .alias = "attach_context", .canonical = "AttachContext" },
    // Reference LEGACY_TOOL_NAME_ALIASES (cc_strings.txt `var i={...}`), full
    // 12-pair table. Permission rule strings written against these old names
    // must still resolve to the canonical tool (see permission_rule_string.zig
    // parse step; tools-01's verifier notes that today's live rule matcher --
    // permission_rules.zig -- does not yet consult this table, so this is
    // forward-looking correctness for whenever alias-aware rule matching is
    // wired in, not a fix for an active collision).
    .{ .alias = "Task", .canonical = "Agent" },
    .{ .alias = "KillShell", .canonical = "TaskStop" },
    .{ .alias = "KillBash", .canonical = "TaskStop" },
    .{ .alias = "AgentOutputTool", .canonical = "TaskOutput" },
    .{ .alias = "BashOutputTool", .canonical = "TaskOutput" },
    .{ .alias = "AgentOutput", .canonical = "TaskOutput" },
    .{ .alias = "BashOutput", .canonical = "TaskOutput" },
    .{ .alias = "ListPeers", .canonical = "ListAgents" },
    .{ .alias = "Brief", .canonical = "SendUserMessage" },
    .{ .alias = "ListMcpResources", .canonical = "ListMcpResourcesTool" },
    .{ .alias = "ReadMcpResource", .canonical = "ReadMcpResourceTool" },
    .{ .alias = "ReadMcpResourceDir", .canonical = "ReadMcpResourceDirTool" },
};

/// Return the reference-exact model-facing name for `name`. If `name` is a known
/// legacy alias it is rewritten; otherwise it is returned unchanged.
pub fn canonical(name: []const u8) []const u8 {
    for (aliases) |p| {
        if (std.mem.eql(u8, name, p.alias)) return p.canonical;
    }
    return name;
}

/// True when `name` is exactly one of the reference model-facing tool names.
pub fn isReferenceExact(name: []const u8) bool {
    for (reference_names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

const testing = std.testing;

test "legacy snake_case aliases rewrite to reference-exact PascalCase" {
    try testing.expectEqualStrings("Read", canonical("file_read"));
    try testing.expectEqualStrings("Write", canonical("file_write"));
    try testing.expectEqualStrings("Edit", canonical("file_edit"));
    try testing.expectEqualStrings("Bash", canonical("shell"));
    try testing.expectEqualStrings("WebSearch", canonical("web_search"));
    try testing.expectEqualStrings("NotebookEdit", canonical("notebook"));
    try testing.expectEqualStrings("EnterPlanMode", canonical("enter_plan_mode"));
    try testing.expectEqualStrings("ListMcpResourcesTool", canonical("mcp_resources_list"));
}

test "already-canonical names pass through unchanged" {
    try testing.expectEqualStrings("Read", canonical("Read"));
    try testing.expectEqualStrings("WebSearch", canonical("WebSearch"));
    try testing.expectEqualStrings("Bash", canonical("Bash"));
}

test "zcode-only / workflow tools with no reference name pass through" {
    try testing.expectEqualStrings("GitCommit", canonical("GitCommit"));
    try testing.expectEqualStrings("git_status", canonical("git_status"));
}

test "tools-06: MultiEdit stays distinct from Edit, not collapsed" {
    try testing.expectEqualStrings("MultiEdit", canonical("MultiEdit"));
    try testing.expectEqualStrings("MultiEdit", canonical("multi_edit"));
}

test "tools-01: AgentRun canonicalizes to Agent" {
    try testing.expectEqualStrings("Agent", canonical("AgentRun"));
    try testing.expectEqualStrings("Agent", canonical("agent_run"));
}

test "tools-05: the 7 previously-missing LEGACY_TOOL_NAME_ALIASES pairs resolve" {
    try testing.expectEqualStrings("TaskStop", canonical("KillBash"));
    try testing.expectEqualStrings("TaskOutput", canonical("BashOutput"));
    try testing.expectEqualStrings("TaskOutput", canonical("AgentOutputTool"));
    try testing.expectEqualStrings("TaskOutput", canonical("BashOutputTool"));
    try testing.expectEqualStrings("TaskOutput", canonical("AgentOutput"));
    try testing.expectEqualStrings("ListAgents", canonical("ListPeers"));
    try testing.expectEqualStrings("ReadMcpResourceDirTool", canonical("ReadMcpResourceDir"));
}

test "tools-04: Brief canonicalizes to SendUserMessage, not the file-attachment tool" {
    try testing.expectEqualStrings("SendUserMessage", canonical("Brief"));
    try testing.expectEqualStrings("AttachContext", canonical("attach_context"));
}

test "isReferenceExact recognizes the canonical set only" {
    try testing.expect(isReferenceExact("Read"));
    try testing.expect(isReferenceExact("WebFetch"));
    try testing.expect(isReferenceExact("EnterWorktree"));
    try testing.expect(isReferenceExact("MultiEdit"));
    try testing.expect(isReferenceExact("SendUserMessage"));
    try testing.expect(isReferenceExact("ListAgents"));
    try testing.expect(!isReferenceExact("Brief"));
    try testing.expect(!isReferenceExact("AttachContext"));
    try testing.expect(!isReferenceExact("file_read"));
    try testing.expect(!isReferenceExact("git_status"));
    try testing.expect(!isReferenceExact("Nonexistent"));
}
