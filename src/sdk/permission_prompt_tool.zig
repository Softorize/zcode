//! sdk-headless-14 (Task K2): `--permission-prompt-tool <name>` resolution.
//!
//! When a headless run is given `--permission-prompt-tool mcp__server__tool`,
//! a tool that needs permission is NOT relayed to an SDK host (the
//! sdk-headless-05 `can_use_tool` path) nor prompted on stdin. Instead the named
//! MCP tool is invoked with the permission-request payload and its result is
//! mapped to the decision.
//!
//! Reference behavior + file:line:
//!   print.ts:4312  permission-prompt-tool resolution: the configured tool is
//!                  called with `{tool_name, input}` and its result is parsed
//!                  for `{behavior: "allow"|"deny", ...}`.
//!
//! Design: this layer is a thin `Dispatcher` adapter over the SAME
//! `RelayApprover` machinery sdk-headless-05 already built (request building,
//! tool_use_id dedup, fail-safe deny). The host relay and the prompt-tool relay
//! differ ONLY in which `Dispatcher` is plugged into the approver: the host
//! relay writes a `control_request` envelope to stdout and awaits a
//! `control_response`; the prompt-tool relay calls an MCP tool and parses its
//! result. Reusing the approver keeps the gate precedence and dedup identical
//! and avoids a second permission code path.
//!
//! The MCP invoker is supplied as a function pointer (not the heavy
//! mcp/client.zig `Client` directly) so the decision logic stays pure and
//! exhaustively testable under the custom runner with a stub invoker. The CLI
//! wiring point passes an adapter that forwards to `mcp.Client.invoke`.

const std = @import("std");
const std_io = @import("../core/std_io.zig");
const structured_io = @import("structured_io.zig");
const mcp_name = @import("../core/mcp_name.zig");

/// Re-export so callers building the approver/decision do not have to reach into
/// structured_io for the shared decision enum.
pub const RelayDecision = structured_io.RelayDecision;

/// A type-erased MCP tool invoker. `server` and `tool` are the parsed parts of
/// the canonical `mcp__server__tool` name; `payload` is the inner
/// `can_use_tool` request JSON (the same object `RelayApprover` builds, carrying
/// `tool_name`, `input`, `tool_use_id`, `decision_reason`,
/// `permission_suggestions`). The invoker returns the tool's extracted result
/// text (caller-owned, freed by this module) or any error.
pub const Invoker = struct {
    ctx: *anyopaque,
    invokeFn: *const fn (
        ctx: *anyopaque,
        server: []const u8,
        tool: []const u8,
        payload: []const u8,
    ) anyerror![]u8,
};

/// Parse a permission-prompt-tool result into a `RelayDecision`.
///
/// The reference tool returns a JSON object whose `behavior` is `"allow"` or
/// `"deny"`. We read `behavior` (case-sensitive, matching the reference token)
/// and map it. Anything that is not an explicit `allow` -- a `deny`, an
/// unrecognized behavior, a non-object result, or unparseable text -- denies.
/// This is the fail-safe posture: a malformed permission verdict must never be
/// read as an allow.
pub fn parseDecision(allocator: std.mem.Allocator, result_text: []const u8) RelayDecision {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, result_text, .{}) catch {
        return .deny;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return .deny;

    // Take the object by pointer (CLAUDE.md ObjectMap rule): a value-copy out of
    // the parsed tree desyncs the entries pointer on a later realloc.
    const obj = &parsed.value.object;
    const behavior = obj.get("behavior") orelse return .deny;
    if (behavior != .string) return .deny;
    if (std.mem.eql(u8, behavior.string, "allow")) return .allow;
    // Every other behavior (including "deny" and any unknown token) denies.
    return .deny;
}

/// A `structured_io.Dispatcher`-compatible source backed by an MCP tool.
/// Plugged into a `RelayApprover` exactly where the host-channel dispatcher
/// would go; the approver then drives request building, dedup, and the
/// fail-safe deny on error.
pub const PromptToolDispatcher = struct {
    allocator: std.mem.Allocator,
    invoker: Invoker,
    /// The canonical `mcp__server__tool` name from `--permission-prompt-tool`.
    tool_name: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        invoker: Invoker,
        tool_name: []const u8,
    ) PromptToolDispatcher {
        return .{ .allocator = allocator, .invoker = invoker, .tool_name = tool_name };
    }

    /// The `Dispatcher.requestFn` body: parse the configured tool name into its
    /// MCP server/tool parts, invoke the tool with `request_json` as the
    /// payload, and map the result to a decision. Returns
    /// `error.RelayUnavailable` on any failure (a non-MCP tool name, an invoke
    /// error) so the approver fail-safe denies rather than treating an error as
    /// an allow.
    fn request(ctx: *anyopaque, request_json: []const u8) anyerror!RelayDecision {
        const self: *PromptToolDispatcher = @ptrCast(@alignCast(ctx));
        const info = mcp_name.mcpInfoFromString(self.tool_name) orelse return error.RelayUnavailable;
        const tool = info.tool orelse return error.RelayUnavailable;
        const result_text = self.invoker.invokeFn(self.invoker.ctx, info.server, tool, request_json) catch {
            return error.RelayUnavailable;
        };
        defer self.allocator.free(result_text);
        return parseDecision(self.allocator, result_text);
    }

    /// Build the `structured_io.Dispatcher` view over this prompt-tool source.
    pub fn dispatcher(self: *PromptToolDispatcher) structured_io.Dispatcher {
        return .{ .ctx = @ptrCast(self), .requestFn = request };
    }
};

const testing = std.testing;

test "parseDecision: an allow verdict yields .allow" {
    try testing.expectEqual(RelayDecision.allow, parseDecision(testing.allocator, "{\"behavior\":\"allow\"}"));
    // Extra fields (updatedInput etc.) do not change the verdict.
    try testing.expectEqual(
        RelayDecision.allow,
        parseDecision(testing.allocator, "{\"behavior\":\"allow\",\"updatedInput\":{\"command\":\"ls\"}}"),
    );
}

test "parseDecision: a deny verdict and any non-allow verdict deny" {
    try testing.expectEqual(RelayDecision.deny, parseDecision(testing.allocator, "{\"behavior\":\"deny\",\"message\":\"nope\"}"));
    // Unknown behavior token -> deny (fail safe).
    try testing.expectEqual(RelayDecision.deny, parseDecision(testing.allocator, "{\"behavior\":\"maybe\"}"));
    // Missing behavior -> deny.
    try testing.expectEqual(RelayDecision.deny, parseDecision(testing.allocator, "{\"other\":1}"));
    // Non-string behavior -> deny.
    try testing.expectEqual(RelayDecision.deny, parseDecision(testing.allocator, "{\"behavior\":true}"));
}

test "parseDecision: malformed or non-object result denies" {
    try testing.expectEqual(RelayDecision.deny, parseDecision(testing.allocator, "not json"));
    try testing.expectEqual(RelayDecision.deny, parseDecision(testing.allocator, "[1,2,3]"));
    try testing.expectEqual(RelayDecision.deny, parseDecision(testing.allocator, "\"allow\""));
}

// A stub invoker that records the parts it was called with and returns a
// pre-canned result text (or forces an error). Stands in for mcp.Client.invoke.
const StubInvoker = struct {
    allocator: std.mem.Allocator,
    result: []const u8 = "{\"behavior\":\"allow\"}",
    fail: bool = false,
    calls: usize = 0,
    last_server: []u8 = "",
    last_tool: []u8 = "",
    last_payload: []u8 = "",

    fn deinit(self: *StubInvoker) void {
        if (self.last_server.len > 0) self.allocator.free(self.last_server);
        if (self.last_tool.len > 0) self.allocator.free(self.last_tool);
        if (self.last_payload.len > 0) self.allocator.free(self.last_payload);
    }

    fn invoke(ctx: *anyopaque, server: []const u8, tool: []const u8, payload: []const u8) anyerror![]u8 {
        const self: *StubInvoker = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.last_server.len > 0) self.allocator.free(self.last_server);
        if (self.last_tool.len > 0) self.allocator.free(self.last_tool);
        if (self.last_payload.len > 0) self.allocator.free(self.last_payload);
        self.last_server = try self.allocator.dupe(u8, server);
        self.last_tool = try self.allocator.dupe(u8, tool);
        self.last_payload = try self.allocator.dupe(u8, payload);
        if (self.fail) return error.McpInvokeFailed;
        // The dispatcher frees the returned slice, so dupe it.
        return self.allocator.dupe(u8, self.result);
    }

    fn invoker(self: *StubInvoker) Invoker {
        return .{ .ctx = @ptrCast(self), .invokeFn = invoke };
    }
};

const types = @import("../core/types.zig");

test "PromptToolDispatcher: a permission request invokes the named MCP tool and maps allow" {
    const allocator = testing.allocator;
    var stub = StubInvoker{ .allocator = allocator, .result = "{\"behavior\":\"allow\"}" };
    defer stub.deinit();

    var ppt = PromptToolDispatcher.init(allocator, stub.invoker(), "mcp__authz__check");

    // Drive it through the full RelayApprover, exactly as the gate does. The
    // approver builds the can_use_tool request, hands it to our dispatcher
    // (which calls the MCP tool), and maps the verdict to an ApprovalResponse.
    var approver = structured_io.RelayApprover.init(allocator, ppt.dispatcher());
    defer approver.deinit();

    const resp = try approver.requestPermission(
        "Bash",
        "{\"command\":\"ls\"}",
        "tool-1",
        "MEDIUM tier",
        "[]",
    );
    try testing.expectEqual(types.ApprovalResponse.approve, resp);

    // The named tool was invoked once with the parsed server/tool parts and the
    // can_use_tool request payload.
    try testing.expectEqual(@as(usize, 1), stub.calls);
    try testing.expectEqualStrings("authz", stub.last_server);
    try testing.expectEqualStrings("check", stub.last_tool);
    try testing.expect(std.mem.indexOf(u8, stub.last_payload, "\"subtype\":\"can_use_tool\"") != null);
    try testing.expect(std.mem.indexOf(u8, stub.last_payload, "\"tool_name\":\"Bash\"") != null);
}

test "PromptToolDispatcher: a deny verdict from the tool denies the permission" {
    const allocator = testing.allocator;
    var stub = StubInvoker{ .allocator = allocator, .result = "{\"behavior\":\"deny\",\"message\":\"blocked\"}" };
    defer stub.deinit();

    var ppt = PromptToolDispatcher.init(allocator, stub.invoker(), "mcp__authz__check");
    var approver = structured_io.RelayApprover.init(allocator, ppt.dispatcher());
    defer approver.deinit();

    const resp = try approver.requestPermission("Bash", "{}", "tool-2", "", "[]");
    try testing.expectEqual(types.ApprovalResponse.deny, resp);
    try testing.expectEqual(@as(usize, 1), stub.calls);
}

test "PromptToolDispatcher: an invoke error fails safe to deny" {
    const allocator = testing.allocator;
    var stub = StubInvoker{ .allocator = allocator, .fail = true };
    defer stub.deinit();

    var ppt = PromptToolDispatcher.init(allocator, stub.invoker(), "mcp__authz__check");
    var approver = structured_io.RelayApprover.init(allocator, ppt.dispatcher());
    defer approver.deinit();

    const resp = try approver.requestPermission("Bash", "{}", "tool-3", "", "[]");
    try testing.expectEqual(types.ApprovalResponse.deny, resp);
    try testing.expectEqual(@as(usize, 1), stub.calls);

    // The id was NOT recorded on a failed dispatch, so a RETRY for the same id
    // still reaches the tool (RelayApprover fail-safe contract): a second
    // request invokes the tool again rather than being silently deduped.
    stub.fail = false;
    stub.result = "{\"behavior\":\"allow\"}";
    const retry = try approver.requestPermission("Bash", "{}", "tool-3", "", "[]");
    try testing.expectEqual(types.ApprovalResponse.approve, retry);
    try testing.expectEqual(@as(usize, 2), stub.calls);
}

test "PromptToolDispatcher: a non-MCP tool name fails safe to deny without invoking" {
    const allocator = testing.allocator;
    var stub = StubInvoker{ .allocator = allocator };
    defer stub.deinit();

    // A bare (non-canonical) tool name does not parse as mcp__server__tool, so
    // the dispatcher denies without ever calling the invoker.
    var ppt = PromptToolDispatcher.init(allocator, stub.invoker(), "not-an-mcp-name");
    var approver = structured_io.RelayApprover.init(allocator, ppt.dispatcher());
    defer approver.deinit();

    const resp = try approver.requestPermission("Bash", "{}", "tool-4", "", "[]");
    try testing.expectEqual(types.ApprovalResponse.deny, resp);
    try testing.expectEqual(@as(usize, 0), stub.calls);
}
