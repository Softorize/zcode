//! P3 (PRD #534) hook lifecycle events. Encodes Claude Code's full set of
//! user-configurable hook events, their reference-exact names, which events can
//! block, and the exit-code disposition contract (0 ok / 2 blocking / other
//! user-error). Pure: no allocation, no IO.

const std = @import("std");

pub const Event = enum {
    pre_tool_use,
    post_tool_use,
    post_tool_use_failure,
    permission_request,
    permission_denied,
    session_start,
    session_end,
    user_prompt_submit,
    stop,
    stop_failure,
    pre_compact,
    post_compact,
    subagent_start,
    subagent_stop,
    teammate_idle,
    task_created,
    task_completed,
    setup,
    config_change,
    instructions_loaded,
    cwd_changed,
    file_changed,
    worktree_create,
    worktree_remove,
    notification,
    elicitation,
    elicitation_result,
};

/// Reference-exact PascalCase event name as used in settings.json keys.
pub fn canonicalName(e: Event) []const u8 {
    return switch (e) {
        .pre_tool_use => "PreToolUse",
        .post_tool_use => "PostToolUse",
        .post_tool_use_failure => "PostToolUseFailure",
        .permission_request => "PermissionRequest",
        .permission_denied => "PermissionDenied",
        .session_start => "SessionStart",
        .session_end => "SessionEnd",
        .user_prompt_submit => "UserPromptSubmit",
        .stop => "Stop",
        .stop_failure => "StopFailure",
        .pre_compact => "PreCompact",
        .post_compact => "PostCompact",
        .subagent_start => "SubagentStart",
        .subagent_stop => "SubagentStop",
        .teammate_idle => "TeammateIdle",
        .task_created => "TaskCreated",
        .task_completed => "TaskCompleted",
        .setup => "Setup",
        .config_change => "ConfigChange",
        .instructions_loaded => "InstructionsLoaded",
        .cwd_changed => "CwdChanged",
        .file_changed => "FileChanged",
        .worktree_create => "WorktreeCreate",
        .worktree_remove => "WorktreeRemove",
        .notification => "Notification",
        .elicitation => "Elicitation",
        .elicitation_result => "ElicitationResult",
    };
}

/// Parse a settings.json event key (PascalCase) into an Event. Unknown -> null.
pub fn fromName(name: []const u8) ?Event {
    inline for (std.meta.fields(Event)) |f| {
        const e: Event = @enumFromInt(f.value);
        if (std.mem.eql(u8, name, canonicalName(e))) return e;
    }
    return null;
}

/// True when exit code 2 from this event blocks the operation / continues the
/// turn (the reference's "blocking error" events). Observability-only events
/// (StopFailure, InstructionsLoaded, notifications) ignore exit code 2.
pub fn isBlockingCapable(e: Event) bool {
    return switch (e) {
        .pre_tool_use,
        .post_tool_use,
        .permission_request,
        .user_prompt_submit,
        .stop,
        .pre_compact,
        .subagent_stop,
        .teammate_idle,
        .task_created,
        .task_completed,
        .elicitation,
        .elicitation_result,
        => true,
        else => false,
    };
}

pub const Disposition = enum { ok, block, user_error };

/// Interpret a hook process exit code for an event. 0 -> ok; 2 -> block (only
/// for blocking-capable events); anything else -> user_error (stderr to user,
/// operation continues).
pub fn interpretExit(e: Event, code: u8) Disposition {
    if (code == 0) return .ok;
    if (code == 2 and isBlockingCapable(e)) return .block;
    return .user_error;
}

const testing = std.testing;

test "every event round-trips name <-> enum" {
    inline for (std.meta.fields(Event)) |f| {
        const e: Event = @enumFromInt(f.value);
        try testing.expectEqual(e, fromName(canonicalName(e)).?);
    }
}

test "canonical names match the reference spelling" {
    try testing.expectEqualStrings("PreToolUse", canonicalName(.pre_tool_use));
    try testing.expectEqualStrings("UserPromptSubmit", canonicalName(.user_prompt_submit));
    try testing.expectEqualStrings("PostToolUseFailure", canonicalName(.post_tool_use_failure));
}

test "fromName rejects unknown" {
    try testing.expect(fromName("NotAnEvent") == null);
}

test "exit-code disposition honors blocking capability" {
    try testing.expectEqual(Disposition.ok, interpretExit(.pre_tool_use, 0));
    try testing.expectEqual(Disposition.block, interpretExit(.pre_tool_use, 2));
    // StopFailure is observability-only: exit 2 is not a block
    try testing.expectEqual(Disposition.user_error, interpretExit(.stop_failure, 2));
    try testing.expectEqual(Disposition.user_error, interpretExit(.pre_tool_use, 1));
}
