//! Structured SendMessage protocol (swarm-tasks-09).
//!
//! A SendMessage `message` value is either a plain text string or a JSON object
//! carrying a `type` discriminant. This module is the *pure* parser +
//! validator: it classifies the raw `message` into a tagged union and decides
//! whether the send is allowed, returning a static error string when it is not.
//! All side effects (writing a mailbox record, aborting an in-process teammate,
//! flipping plan mode) live in `tools/team.zig` and the teammate lifecycle; this
//! module never touches the filesystem so it is fully unit-testable.
//!
//! Reference: `tools/SendMessageTool/SendMessageTool.ts`:
//!   - `:46-65`   StructuredMessage discriminated union.
//!   - `:268-432` shutdown handlers (the records that get written).
//!   - `:434-518` plan approval / rejection.
//!   - `:678-715` validation ordering (no broadcast, no cross-team, shutdown_response
//!                only to team-lead, reason required when rejecting a shutdown).
//!
//! The three structured variants mirror the reference union exactly:
//!   shutdown_request        { reason? }
//!   shutdown_response       { request_id, approve, reason? }
//!   plan_approval_response  { request_id, approve, feedback? }

const std = @import("std");

/// The canonical team-lead name. Mirrors `utils/swarm/constants.ts:1`
/// (`TEAM_LEAD_NAME = 'team-lead'`).
pub const TEAM_LEAD_NAME = "team-lead";

/// A classified SendMessage payload. String fields are owned by the allocator
/// passed to `parse`; release them with `deinit`. `.plain` owns no allocation
/// (it borrows the original `message` slice).
pub const SwarmMessage = union(enum) {
    /// Ordinary free-text message. Borrows the caller's slice; no allocation.
    plain: []const u8,

    shutdown_request: ShutdownRequest,
    shutdown_response: ShutdownResponse,
    plan_approval_response: PlanApprovalResponse,

    pub const ShutdownRequest = struct {
        /// Optional human-readable reason. Empty string when omitted.
        reason: []u8,
    };

    pub const ShutdownResponse = struct {
        request_id: []u8,
        approve: bool,
        /// Required (non-empty) when `approve == false`; see `validate`.
        reason: []u8,
    };

    pub const PlanApprovalResponse = struct {
        request_id: []u8,
        approve: bool,
        feedback: []u8,
    };

    /// True for any of the three structured variants (anything that is not
    /// `.plain`). Structured messages are subject to the extra validation rules
    /// in `validate` (no broadcast, no cross-team).
    pub fn isStructured(self: SwarmMessage) bool {
        return self != .plain;
    }

    /// Free any allocations owned by a structured variant. A no-op for `.plain`.
    pub fn deinit(self: SwarmMessage, allocator: std.mem.Allocator) void {
        switch (self) {
            .plain => {},
            .shutdown_request => |m| allocator.free(m.reason),
            .shutdown_response => |m| {
                allocator.free(m.request_id);
                allocator.free(m.reason);
            },
            .plan_approval_response => |m| {
                allocator.free(m.request_id);
                allocator.free(m.feedback);
            },
        }
    }
};

/// Classify a raw `message` value. A value whose first non-space byte is `{` is
/// attempted as a structured JSON object; anything else (and any object whose
/// `type` is missing or unrecognized) is treated as `.plain`.
///
/// On a `.plain` result the returned union borrows `message` directly (no copy),
/// so `message` must outlive the returned value. Structured variants own freshly
/// duped strings; release them with `SwarmMessage.deinit`.
pub fn parse(allocator: std.mem.Allocator, message: []const u8) !SwarmMessage {
    const trimmed = std.mem.trim(u8, message, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') {
        return SwarmMessage{ .plain = message };
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
        // Not valid JSON: treat as opaque plain text.
        return SwarmMessage{ .plain = message };
    };
    defer parsed.deinit();

    if (parsed.value != .object) return SwarmMessage{ .plain = message };
    // CLAUDE.md ObjectMap rule: take the object by pointer, never value-copy it.
    const obj = &parsed.value.object;

    const type_str = jsonGetString(obj, "type") orelse return SwarmMessage{ .plain = message };

    if (std.mem.eql(u8, type_str, "shutdown_request")) {
        const reason = jsonGetString(obj, "reason") orelse "";
        return SwarmMessage{ .shutdown_request = .{
            .reason = try allocator.dupe(u8, reason),
        } };
    }

    if (std.mem.eql(u8, type_str, "shutdown_response")) {
        var resp = SwarmMessage.ShutdownResponse{
            .request_id = try allocator.dupe(u8, jsonGetString(obj, "request_id") orelse ""),
            .approve = jsonGetBool(obj, "approve") orelse false,
            .reason = undefined,
        };
        errdefer allocator.free(resp.request_id);
        resp.reason = try allocator.dupe(u8, jsonGetString(obj, "reason") orelse "");
        return SwarmMessage{ .shutdown_response = resp };
    }

    if (std.mem.eql(u8, type_str, "plan_approval_response")) {
        var resp = SwarmMessage.PlanApprovalResponse{
            .request_id = try allocator.dupe(u8, jsonGetString(obj, "request_id") orelse ""),
            .approve = jsonGetBool(obj, "approve") orelse false,
            .feedback = undefined,
        };
        errdefer allocator.free(resp.request_id);
        resp.feedback = try allocator.dupe(u8, jsonGetString(obj, "feedback") orelse "");
        return SwarmMessage{ .plan_approval_response = resp };
    }

    // Unrecognized `type`: opaque plain text, matching the reference which only
    // routes the three known discriminants and treats everything else as text.
    return SwarmMessage{ .plain = message };
}

/// Validate a classified message against the recipient `to`. Returns a static
/// error string (no allocation) when the send must be rejected, or null when it
/// is allowed. The ordering mirrors the reference validateInput
/// (SendMessageTool.ts:678-715):
///   1. plain text -> always allowed here (the `summary`-required rule is
///      enforced at the dispatch layer, not in the protocol classifier).
///   2. structured + `to == "*"` -> cannot broadcast.
///   3. structured + cross-team recipient -> handled by the team layer; this
///      pure module cannot see the team roster, so it only enforces the two
///      recipient-shape rules that need no roster:
///        - shutdown_response must be addressed to team-lead.
///        - rejecting a shutdown requires a non-empty reason.
pub fn validate(self: SwarmMessage, to: []const u8) ?[]const u8 {
    const recipient = std.mem.trim(u8, to, " \t\r\n");

    switch (self) {
        .plain => return null,
        .shutdown_request, .plan_approval_response, .shutdown_response => {},
    }

    // Structured messages cannot be broadcast.
    if (std.mem.eql(u8, recipient, "*")) {
        return "structured messages cannot be broadcast (to: \"*\")";
    }

    switch (self) {
        .plain => unreachable,
        .shutdown_request, .plan_approval_response => return null,
        .shutdown_response => |m| {
            if (!std.mem.eql(u8, recipient, TEAM_LEAD_NAME)) {
                return "shutdown_response must be sent to \"team-lead\"";
            }
            if (!m.approve and std.mem.trim(u8, m.reason, " \t\r\n").len == 0) {
                return "reason is required when rejecting a shutdown request";
            }
            return null;
        },
    }
}

fn jsonGetString(obj: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Read a boolean, tolerating the model quoting it as the string "true"/"false"
/// (mirrors the reference `semanticBoolean`, semanticBoolean.ts:22-29).
fn jsonGetBool(obj: *const std.json.ObjectMap, key: []const u8) ?bool {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .bool => |b| b,
        .string => |s| blk: {
            if (std.mem.eql(u8, s, "true")) break :blk true;
            if (std.mem.eql(u8, s, "false")) break :blk false;
            break :blk null;
        },
        else => null,
    };
}

const testing = std.testing;

test "parse classifies shutdown_request with reason" {
    const allocator = testing.allocator;
    const msg = try parse(allocator, "{\"type\":\"shutdown_request\",\"reason\":\"done\"}");
    defer msg.deinit(allocator);
    try testing.expect(msg == .shutdown_request);
    try testing.expectEqualStrings("done", msg.shutdown_request.reason);
}

test "parse classifies shutdown_request without reason as empty" {
    const allocator = testing.allocator;
    const msg = try parse(allocator, "{\"type\":\"shutdown_request\"}");
    defer msg.deinit(allocator);
    try testing.expect(msg == .shutdown_request);
    try testing.expectEqualStrings("", msg.shutdown_request.reason);
}

test "parse classifies shutdown_response fields" {
    const allocator = testing.allocator;
    const msg = try parse(allocator, "{\"type\":\"shutdown_response\",\"request_id\":\"r1\",\"approve\":true}");
    defer msg.deinit(allocator);
    try testing.expect(msg == .shutdown_response);
    try testing.expectEqualStrings("r1", msg.shutdown_response.request_id);
    try testing.expect(msg.shutdown_response.approve);
    try testing.expectEqualStrings("", msg.shutdown_response.reason);
}

test "parse tolerates quoted approve boolean (semanticBoolean)" {
    const allocator = testing.allocator;
    const msg = try parse(allocator, "{\"type\":\"shutdown_response\",\"request_id\":\"r1\",\"approve\":\"false\",\"reason\":\"busy\"}");
    defer msg.deinit(allocator);
    try testing.expect(msg == .shutdown_response);
    try testing.expect(!msg.shutdown_response.approve);
    try testing.expectEqualStrings("busy", msg.shutdown_response.reason);
}

test "parse classifies plan_approval_response" {
    const allocator = testing.allocator;
    const msg = try parse(allocator, "{\"type\":\"plan_approval_response\",\"request_id\":\"r2\",\"approve\":true,\"feedback\":\"lgtm\"}");
    defer msg.deinit(allocator);
    try testing.expect(msg == .plan_approval_response);
    try testing.expectEqualStrings("r2", msg.plan_approval_response.request_id);
    try testing.expect(msg.plan_approval_response.approve);
    try testing.expectEqualStrings("lgtm", msg.plan_approval_response.feedback);
}

test "parse treats a plain string as .plain" {
    const allocator = testing.allocator;
    const msg = try parse(allocator, "hello team");
    defer msg.deinit(allocator);
    try testing.expect(msg == .plain);
    try testing.expectEqualStrings("hello team", msg.plain);
}

test "parse treats an unrecognized type as .plain" {
    const allocator = testing.allocator;
    const msg = try parse(allocator, "{\"type\":\"something_else\",\"x\":1}");
    defer msg.deinit(allocator);
    try testing.expect(msg == .plain);
}

test "parse treats invalid JSON as .plain" {
    const allocator = testing.allocator;
    const msg = try parse(allocator, "{not valid json");
    defer msg.deinit(allocator);
    try testing.expect(msg == .plain);
}

test "parse treats a JSON array as .plain" {
    const allocator = testing.allocator;
    const msg = try parse(allocator, "[1,2,3]");
    defer msg.deinit(allocator);
    try testing.expect(msg == .plain);
}

test "validate allows a plain message to any recipient" {
    const allocator = testing.allocator;
    const msg = try parse(allocator, "ping");
    defer msg.deinit(allocator);
    try testing.expect(validate(msg, "bob") == null);
    try testing.expect(validate(msg, "*") == null);
}

test "validate rejects broadcasting a structured message" {
    const allocator = testing.allocator;
    const msg = try parse(allocator, "{\"type\":\"shutdown_request\"}");
    defer msg.deinit(allocator);
    const err = validate(msg, "*") orelse return error.ExpectedError;
    try testing.expectEqualStrings("structured messages cannot be broadcast (to: \"*\")", err);
}

test "validate rejects shutdown_response not addressed to team-lead" {
    const allocator = testing.allocator;
    const msg = try parse(allocator, "{\"type\":\"shutdown_response\",\"request_id\":\"r1\",\"approve\":true}");
    defer msg.deinit(allocator);
    const err = validate(msg, "bob") orelse return error.ExpectedError;
    try testing.expectEqualStrings("shutdown_response must be sent to \"team-lead\"", err);
}

test "validate allows shutdown_response to team-lead" {
    const allocator = testing.allocator;
    const msg = try parse(allocator, "{\"type\":\"shutdown_response\",\"request_id\":\"r1\",\"approve\":true}");
    defer msg.deinit(allocator);
    try testing.expect(validate(msg, "team-lead") == null);
}

test "validate rejects a shutdown rejection with no reason" {
    const allocator = testing.allocator;
    const msg = try parse(allocator, "{\"type\":\"shutdown_response\",\"request_id\":\"r1\",\"approve\":false}");
    defer msg.deinit(allocator);
    const err = validate(msg, "team-lead") orelse return error.ExpectedError;
    try testing.expectEqualStrings("reason is required when rejecting a shutdown request", err);
}

test "validate accepts a shutdown rejection with a reason" {
    const allocator = testing.allocator;
    const msg = try parse(allocator, "{\"type\":\"shutdown_response\",\"request_id\":\"r1\",\"approve\":false,\"reason\":\"still working\"}");
    defer msg.deinit(allocator);
    try testing.expect(validate(msg, "team-lead") == null);
}

test "validate rejects broadcasting a shutdown_response before the team-lead check" {
    const allocator = testing.allocator;
    const msg = try parse(allocator, "{\"type\":\"shutdown_response\",\"request_id\":\"r1\",\"approve\":true}");
    defer msg.deinit(allocator);
    // Broadcast is checked first, so even a shutdown_response to "*" reports the
    // broadcast error rather than the team-lead error.
    const err = validate(msg, "*") orelse return error.ExpectedError;
    try testing.expectEqualStrings("structured messages cannot be broadcast (to: \"*\")", err);
}
