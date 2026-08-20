//! P2 (PRD #534) structured permission-decision reason taxonomy.
//!
//! Aggregates the factors that drive a permission decision (rule / mode / hook /
//! safetyCheck / sandboxOverride / workingDir / policyBlocked / agentPolicy /
//! other) into one tagged union, plus a `format` that renders the
//! reference-style request message. This replaces scattered ad-hoc reason
//! strings at the decision points so `/permissions explain` and the blocked
//! ToolTrace output speak one vocabulary.
//!
//! Mirrors the reference `createPermissionRequestMessage`
//! (src/utils/permissions/permissions.ts:137-205) which switches on
//! `decisionReason.type`. The reference reason types that depend on features not
//! present in this phase (classifier / subcommandResults / permissionPromptTool /
//! asyncAgent) are intentionally omitted -- see the phase Out-of-scope notes.
//!
//! Pure module: takes a reason and a tool name, returns an owned string. No IO,
//! no runtime singleton. The caller owns the returned slice.

const std = @import("std");
const permission_decision = @import("permission_decision.zig");

/// The set of decision-reason variants zcode surfaces. Each carries the
/// already-resolved data the formatter needs (the formatter does not look rules
/// up or resolve sources -- callers hand it strings, keeping this module pure
/// and free of the rule store's lifetime contract).
pub const Reason = union(enum) {
    /// A persistent permission rule matched. `rule_string` is the rendered
    /// `Tool(content)` form; `source` is the human-readable source label.
    rule: struct { rule_string: []const u8, source: []const u8 },
    /// The active permission mode (default / acceptEdits / plan / ...) drove the
    /// decision.
    mode: permission_decision.Mode,
    /// A hook requested approval / blocked. `reason` is optional extra detail.
    hook: struct { hook_name: []const u8, reason: ?[]const u8 },
    /// The bypass-immune path-safety guard fired. `reason` is the detail string.
    safetyCheck: []const u8,
    /// The tool was asked to run outside the sandbox.
    sandboxOverride,
    /// A working-directory containment check produced the decision; `reason` is
    /// the full message (the reference passes its workingDir reason through).
    workingDir: []const u8,
    /// A policy (egress / sandbox / tier=BLOCKED) hard-blocked the tool.
    policyBlocked: []const u8,
    /// An Agent(agentType) deny rule blocked spawning a sub-agent.
    agentPolicy: []const u8,
    /// Catch-all pass-through reason.
    other: []const u8,
};

/// Reference mode titles (PermissionMode.ts PERMISSION_MODE_CONFIG titles).
/// Used by the `mode` reason so the rendered message matches the reference
/// `permissionModeTitle`.
pub fn modeTitle(mode: permission_decision.Mode) []const u8 {
    return switch (mode) {
        .default => "Default",
        .acceptEdits => "Accept edits",
        .plan => "Plan Mode",
        .bypassPermissions => "Bypass Permissions",
        .dontAsk => "Don't Ask",
    };
}

/// Render the reference-style permission-request message for `reason` and
/// `tool_name`. Caller owns the returned slice. Mirrors
/// `createPermissionRequestMessage` (permissions.ts:137-205).
pub fn format(allocator: std.mem.Allocator, tool_name: []const u8, reason: Reason) ![]u8 {
    return switch (reason) {
        .rule => |r| std.fmt.allocPrint(
            allocator,
            "Permission rule '{s}' from {s} requires approval for this {s} command",
            .{ r.rule_string, r.source, tool_name },
        ),
        .mode => |m| std.fmt.allocPrint(
            allocator,
            "Current permission mode ({s}) requires approval for this {s} command",
            .{ modeTitle(m), tool_name },
        ),
        .hook => |h| if (h.reason) |detail|
            std.fmt.allocPrint(
                allocator,
                "Hook '{s}' blocked this action: {s}",
                .{ h.hook_name, detail },
            )
        else
            std.fmt.allocPrint(
                allocator,
                "Hook '{s}' requires approval for this {s} command",
                .{ h.hook_name, tool_name },
            ),
        // safetyCheck / workingDir / other / agentPolicy / policyBlocked pass
        // their reason string through verbatim, matching the reference's
        // pass-through cases.
        .safetyCheck => |detail| allocator.dupe(u8, detail),
        .workingDir => |detail| allocator.dupe(u8, detail),
        .policyBlocked => |detail| allocator.dupe(u8, detail),
        .agentPolicy => |detail| allocator.dupe(u8, detail),
        .other => |detail| allocator.dupe(u8, detail),
        .sandboxOverride => allocator.dupe(u8, "Run outside of the sandbox"),
    };
}

const testing = std.testing;

test "format mode reason contains permission mode and the mode title" {
    const msg = try format(testing.allocator, "Bash", .{ .mode = .plan });
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "permission mode") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "Plan Mode") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "Bash") != null);
}

test "format mode title matches reference titles" {
    try testing.expectEqualStrings("Default", modeTitle(.default));
    try testing.expectEqualStrings("Accept edits", modeTitle(.acceptEdits));
    try testing.expectEqualStrings("Plan Mode", modeTitle(.plan));
    try testing.expectEqualStrings("Bypass Permissions", modeTitle(.bypassPermissions));
    try testing.expectEqualStrings("Don't Ask", modeTitle(.dontAsk));
}

test "format safetyCheck passes the reason through" {
    const msg = try format(testing.allocator, "Edit", .{ .safetyCheck = "sensitive file" });
    defer testing.allocator.free(msg);
    try testing.expectEqualStrings("sensitive file", msg);
}

test "format rule reason contains the rule string and source" {
    const msg = try format(testing.allocator, "Bash", .{ .rule = .{
        .rule_string = "Bash(curl:*)",
        .source = "user settings",
    } });
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "Bash(curl:*)") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "user settings") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "requires approval") != null);
}

test "format hook reason with and without detail" {
    const with = try format(testing.allocator, "Bash", .{ .hook = .{
        .hook_name = "guard",
        .reason = "blocked curl",
    } });
    defer testing.allocator.free(with);
    try testing.expect(std.mem.indexOf(u8, with, "guard") != null);
    try testing.expect(std.mem.indexOf(u8, with, "blocked curl") != null);

    const without = try format(testing.allocator, "Bash", .{ .hook = .{
        .hook_name = "guard",
        .reason = null,
    } });
    defer testing.allocator.free(without);
    try testing.expect(std.mem.indexOf(u8, without, "guard") != null);
    try testing.expect(std.mem.indexOf(u8, without, "requires approval") != null);
}

test "format sandboxOverride is the fixed reference string" {
    const msg = try format(testing.allocator, "Bash", .sandboxOverride);
    defer testing.allocator.free(msg);
    try testing.expectEqualStrings("Run outside of the sandbox", msg);
}

test "format workingDir / policyBlocked / agentPolicy / other pass through" {
    const wd = try format(testing.allocator, "Edit", .{ .workingDir = "outside the workspace" });
    defer testing.allocator.free(wd);
    try testing.expectEqualStrings("outside the workspace", wd);

    const pb = try format(testing.allocator, "WebFetch", .{ .policyBlocked = "egress denied: evil.com" });
    defer testing.allocator.free(pb);
    try testing.expectEqualStrings("egress denied: evil.com", pb);

    const ap = try format(testing.allocator, "Agent", .{ .agentPolicy = "agent type 'Explore' is denied" });
    defer testing.allocator.free(ap);
    try testing.expectEqualStrings("agent type 'Explore' is denied", ap);

    const ot = try format(testing.allocator, "Bash", .{ .other = "some reason" });
    defer testing.allocator.free(ot);
    try testing.expectEqualStrings("some reason", ot);
}
