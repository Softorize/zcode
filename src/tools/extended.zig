const std = @import("std");

// Re-export module: delegates to focused single-responsibility files.
// This preserves the public API so that registry.zig and main.zig
// continue to work without modification.

const glob_mod = @import("glob.zig");
const grep_mod = @import("grep.zig");
const web_mod = @import("web.zig");
const task_mod = @import("task.zig");
const team_mod = @import("team.zig");
const notebook_mod = @import("notebook.zig");
const misc_mod = @import("misc.zig");

// -- Glob / file search --
pub const glob = glob_mod.glob;

// -- Grep / content search --
pub const grep = grep_mod.grep;

// -- Web tools --
pub const webFetch = web_mod.webFetch;
pub const webSearch = web_mod.webSearch;
pub const parseDomainList = web_mod.parseDomainList;

// -- Task management --
pub const taskCreate = task_mod.taskCreate;
pub const taskCreateWithOptions = task_mod.taskCreateWithOptions;
pub const taskGet = task_mod.taskGet;
pub const taskList = task_mod.taskList;
pub const taskUpdate = task_mod.taskUpdate;
pub const taskStop = task_mod.taskStop;
pub const taskOutput = task_mod.taskOutput;
pub const taskRun = task_mod.taskRun;
pub const taskPoll = task_mod.taskPoll;
pub const blockTask = task_mod.blockTask;
pub const taskDelete = task_mod.taskDelete;
pub const unresolvedBlockers = task_mod.unresolvedBlockers;
pub const claimTask = task_mod.claimTask;
pub const ClaimResult = task_mod.ClaimResult;
pub const ClaimReason = task_mod.ClaimReason;
pub const getAgentStatuses = task_mod.getAgentStatuses;
pub const freeAgentStatuses = task_mod.freeAgentStatuses;
pub const unassignTeammateTasks = task_mod.unassignTeammateTasks;

// -- Team management --
pub const teamCreate = team_mod.teamCreate;
pub const teamDelete = team_mod.teamDelete;
pub const sendMessage = team_mod.sendMessage;

// -- Notebook --
pub const notebookEdit = notebook_mod.notebookEdit;

// -- Miscellaneous --
pub const askUserQuestion = misc_mod.askUserQuestion;
pub const skillAction = misc_mod.skillAction;
pub const commandAction = misc_mod.commandAction;
pub const enterPlanMode = misc_mod.enterPlanMode;
pub const exitPlanMode = misc_mod.exitPlanMode;

const testing = std.testing;

test "extended module re-exports are valid" {
    // Verify that all re-exported function pointers are non-null.
    try testing.expect(@TypeOf(glob) != void);
    try testing.expect(@TypeOf(grep) != void);
    try testing.expect(@TypeOf(webFetch) != void);
    try testing.expect(@TypeOf(teamCreate) != void);
    try testing.expect(@TypeOf(notebookEdit) != void);
}

// Pull in tests from sub-modules so `zig build test` continues to run them.
test {
    _ = @import("helpers.zig");
    _ = glob_mod;
    _ = grep_mod;
    _ = web_mod;
    _ = task_mod;
    _ = team_mod;
    _ = notebook_mod;
    _ = misc_mod;
}
