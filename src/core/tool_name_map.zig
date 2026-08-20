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
    "Agent",         "AskUserQuestion", "Bash",                 "Brief",
    "CronCreate",    "CronDelete",      "CronList",             "Edit",
    "EnterPlanMode", "EnterWorktree",   "ExitPlanMode",         "ExitWorktree",
    "Glob",          "Grep",            "ListMcpResourcesTool", "LSP",
    "NotebookEdit",  "Read",            "ReadMcpResourceTool",  "SendMessage",
    "Skill",         "Sleep",           "Task",                 "TaskCreate",
    "TaskGet",       "TaskList",        "TaskOutput",           "TaskStop",
    "TaskUpdate",    "TeamCreate",      "TeamDelete",           "TodoWrite",
    "ToolSearch",    "WebFetch",        "WebSearch",            "Write",
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
    .{ .alias = "MultiEdit", .canonical = "Edit" },
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
    .{ .alias = "lsp", .canonical = "LSP" },
    .{ .alias = "tool_search", .canonical = "ToolSearch" },
    // Reference LEGACY_TOOL_NAME_ALIASES: the reference renamed Task -> Agent
    // and KillShell -> TaskStop. Permission rule strings written against the
    // old names must still resolve to the canonical tool, so map them here in
    // the single alias table (see permission_rule_string.zig parse step).
    .{ .alias = "Task", .canonical = "Agent" },
    .{ .alias = "KillShell", .canonical = "TaskStop" },
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

test "MultiEdit collapses onto Edit" {
    try testing.expectEqualStrings("Edit", canonical("MultiEdit"));
}

test "isReferenceExact recognizes the canonical set only" {
    try testing.expect(isReferenceExact("Read"));
    try testing.expect(isReferenceExact("WebFetch"));
    try testing.expect(isReferenceExact("EnterWorktree"));
    try testing.expect(!isReferenceExact("file_read"));
    try testing.expect(!isReferenceExact("git_status"));
    try testing.expect(!isReferenceExact("Nonexistent"));
}
