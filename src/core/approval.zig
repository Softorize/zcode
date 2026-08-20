const std = @import("std");
const types = @import("types.zig");
const permission_decision = @import("permission_decision.zig");

pub const Decision = struct {
    approved: bool,
    state: types.ApprovalState,
    reason: []const u8,
};

/// True for the file-mutation tools that `acceptEdits` mode auto-approves.
/// Derived from the tool name, not the risk tier: many MEDIUM-tier tools
/// (Bash, GitCommit, Move, TeamDelete, ...) are NOT edits, so a tier-based
/// heuristic would over-approve them under acceptEdits. PRD #534 review fix.
pub fn isEditTool(name: []const u8) bool {
    const edit_tools = [_][]const u8{
        "Write",      "Edit",      "MultiEdit", "NotebookEdit",
        "file_write", "file_edit", "write",     "edit",
    };
    for (edit_tools) |t| {
        if (std.mem.eql(u8, name, t)) return true;
    }
    return false;
}

pub fn evaluate(
    approval_mode: []const u8,
    tier: types.RiskTier,
    is_edit: bool,
    interactive: bool,
    auto_approve_high: bool,
    yolo_mode: bool,
    prompt_ctx: ?*anyopaque,
    prompt_cb: ?*const fn (ctx: *anyopaque, message: []const u8) anyerror!types.ApprovalResponse,
    tool_description: ?[]const u8,
) !Decision {
    if (tier == .BLOCKED) {
        return .{ .approved = false, .state = .blocked, .reason = "blocked by policy" };
    }

    if (yolo_mode) {
        return .{ .approved = true, .state = .user_approved, .reason = "approved by yolo mode" };
    }

    // Claude Code reference permission modes (PRD #534 P2). Rules and session
    // memory are applied upstream in the tool gate, so here we pass null/false
    // and let the mode + tier + is_edit drive the outcome. is_edit is supplied
    // by the caller from the tool name (see isEditTool), not guessed from tier.
    if (permission_decision.isReferenceModeName(approval_mode)) {
        const mode = permission_decision.modeFromString(approval_mode);
        const outcome = permission_decision.decide(mode, null, tier, is_edit, false);
        switch (outcome) {
            .allow => return .{ .approved = true, .state = .auto_approved, .reason = "approved by permission mode" },
            .deny => return .{ .approved = false, .state = .denied, .reason = "denied by permission mode" },
            .ask => {
                if (auto_approve_high and tier == .HIGH) {
                    return .{ .approved = true, .state = .user_approved, .reason = "auto-approved by flag" };
                }
                if (!interactive or prompt_cb == null or prompt_ctx == null) {
                    return .{ .approved = false, .state = .denied, .reason = "permission mode requires interactive approval" };
                }
                const msg = tool_description orelse "Approve action?";
                const response = try prompt_cb.?(prompt_ctx.?, msg);
                return switch (response) {
                    .approve => .{ .approved = true, .state = .user_approved, .reason = "approved by user" },
                    .approve_always => .{ .approved = true, .state = .session_approved, .reason = "approved always for session" },
                    .deny => .{ .approved = false, .state = .denied, .reason = "denied by user" },
                };
            },
        }
    }

    if (std.mem.eql(u8, approval_mode, "strict")) {
        if (tier == .LOW) {
            return .{ .approved = true, .state = .auto_approved, .reason = "strict low-risk auto-approved" };
        }

        if (auto_approve_high and tier == .HIGH) {
            return .{ .approved = true, .state = .user_approved, .reason = "auto-approved by flag" };
        }

        if (!interactive or prompt_cb == null or prompt_ctx == null) {
            return .{ .approved = false, .state = .denied, .reason = "strict mode requires explicit approval" };
        }

        const msg = tool_description orelse "Approve strict-mode action?";
        const response = try prompt_cb.?(prompt_ctx.?, msg);
        return switch (response) {
            .approve => .{ .approved = true, .state = .user_approved, .reason = "approved by user" },
            .approve_always => .{ .approved = true, .state = .session_approved, .reason = "approved always for session" },
            .deny => .{ .approved = false, .state = .denied, .reason = "denied by user" },
        };
    }

    if (std.mem.eql(u8, approval_mode, "manual")) {
        if (auto_approve_high) {
            return .{ .approved = true, .state = .user_approved, .reason = "auto-approved by flag" };
        }
        if (!interactive or prompt_cb == null or prompt_ctx == null) {
            return .{ .approved = false, .state = .denied, .reason = "manual mode requires interactive approval" };
        }
        const msg = tool_description orelse "Approve tool invocation?";
        const response = try prompt_cb.?(prompt_ctx.?, msg);
        return switch (response) {
            .approve => .{ .approved = true, .state = .user_approved, .reason = "approved by user" },
            .approve_always => .{ .approved = true, .state = .session_approved, .reason = "approved always for session" },
            .deny => .{ .approved = false, .state = .denied, .reason = "denied by user" },
        };
    }

    if (std.mem.eql(u8, approval_mode, "tiered-auto")) {
        if (tier == .LOW or tier == .MEDIUM) {
            return .{ .approved = true, .state = .auto_approved, .reason = "tiered-auto low/medium auto-approved" };
        }

        if (auto_approve_high and tier == .HIGH) {
            return .{ .approved = true, .state = .user_approved, .reason = "auto-approved by flag" };
        }

        if (!interactive or prompt_cb == null or prompt_ctx == null) {
            return .{ .approved = false, .state = .denied, .reason = "high-risk requires interactive approval" };
        }

        const msg = tool_description orelse "Approve high-risk action?";
        const response = try prompt_cb.?(prompt_ctx.?, msg);
        return switch (response) {
            .approve => .{ .approved = true, .state = .user_approved, .reason = "approved by user" },
            .approve_always => .{ .approved = true, .state = .session_approved, .reason = "approved always for session" },
            .deny => .{ .approved = false, .state = .denied, .reason = "denied by user" },
        };
    }

    return .{ .approved = false, .state = .denied, .reason = "unknown approval mode" };
}

const testing = std.testing;

test "isEditTool recognizes edit tools only" {
    try testing.expect(isEditTool("Write"));
    try testing.expect(isEditTool("Edit"));
    try testing.expect(isEditTool("NotebookEdit"));
    try testing.expect(!isEditTool("Bash"));
    try testing.expect(!isEditTool("GitCommit"));
    try testing.expect(!isEditTool("Move"));
}

test "tiered auto low approved" {
    const decision = try evaluate("tiered-auto", .LOW, false, false, false, false, null, null, null);
    try testing.expect(decision.approved);
}

test "manual non-interactive denied" {
    const decision = try evaluate("manual", .LOW, false, false, false, false, null, null, null);
    try testing.expect(!decision.approved);
}

test "yolo mode auto-approves non-blocked tiers" {
    const low = try evaluate("strict", .LOW, false, true, false, true, null, null, null);
    const high = try evaluate("strict", .HIGH, false, true, false, true, null, null, null);
    try testing.expect(low.approved);
    try testing.expect(high.approved);
}

test "reference mode bypassPermissions approves non-blocked" {
    const d = try evaluate("bypassPermissions", .HIGH, false, false, false, false, null, null, null);
    try testing.expect(d.approved);
    const blocked = try evaluate("bypassPermissions", .BLOCKED, false, false, false, false, null, null, null);
    try testing.expect(!blocked.approved);
}

test "reference mode acceptEdits auto-approves edits, not non-edit MEDIUM tools" {
    // an edit tool at MEDIUM (is_edit=true) is auto-approved
    const edit = try evaluate("acceptEdits", .MEDIUM, true, false, false, false, null, null, null);
    try testing.expect(edit.approved);
    // a NON-edit MEDIUM tool (e.g. Bash/GitCommit, is_edit=false) is NOT auto-approved
    const nonedit = try evaluate("acceptEdits", .MEDIUM, false, false, false, false, null, null, null);
    try testing.expect(!nonedit.approved);
    // high-risk still denied non-interactive
    const high = try evaluate("acceptEdits", .HIGH, false, false, false, false, null, null, null);
    try testing.expect(!high.approved);
}

test "reference mode plan denies non-read tiers" {
    const low = try evaluate("plan", .LOW, false, false, false, false, null, null, null);
    const med = try evaluate("plan", .MEDIUM, false, false, false, false, null, null, null);
    try testing.expect(low.approved);
    try testing.expect(!med.approved);
}

test "reference mode dontAsk denies high without rules" {
    const high = try evaluate("dontAsk", .HIGH, false, true, false, false, null, null, null);
    try testing.expect(!high.approved);
    const low = try evaluate("dontAsk", .LOW, false, true, false, false, null, null, null);
    try testing.expect(low.approved);
}
