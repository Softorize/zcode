//! hooks-permissions-06: execute `mcp_tool` hook types -- a hook action that
//! invokes an already-configured MCP server's tool, rather than running a
//! shell command / prompt / HTTP POST. Mirrors `hook_exec_http.zig`'s shape
//! (an `Outcome` struct, a non-blocking-error degrade path) for the other
//! network-backed hook type.
//!
//! Scope note: zcode's live MCP client registry (the connected server
//! sessions that could actually invoke a tool) is owned by
//! `mcp/client.zig` / `agent_runtime.zig`, well above the hooks dispatch
//! layer, and wiring a live handle through `hooks.HookContext` end-to-end is
//! out of this package's scope (agent_runtime.zig ownership here is
//! "hook emission points only"). Rather than fabricate a fake call or drop
//! the hook type entirely, this module is invocation-ready: `runMcpToolHook`
//! takes an optional `Invoker` callback a future call site can wire to the
//! real registry. With none supplied (today's only wiring in
//! `hooks.processDef`), the hook is reported as "ran" (so `once`/dedup
//! semantics behave normally) with a clear non-blocking error explaining
//! that no bridge is connected, instead of the entry silently vanishing the
//! way an unparsed `mcp_tool` hook used to (hook_config.zig's
//! `orelse continue`).

const std = @import("std");
const hook_config = @import("hook_config.zig");

/// Outcome of running an `mcp_tool` hook. Mirrors `hook_exec_http.HttpOutcome`:
/// `blocked` means the tool's result carried a blocking stdout-contract
/// signal; a transport/bridge error is a non-blocking error (`ran == true`,
/// `blocked == false`, `error_message` set). All owned slices are duped onto
/// the supplied allocator and freed in `deinit`.
pub const McpToolOutcome = struct {
    ran: bool = false,
    blocked: bool = false,
    reason: ?[]u8 = null,
    additional_context: ?[]u8 = null,
    error_message: ?[]u8 = null,

    pub fn deinit(self: *McpToolOutcome, allocator: std.mem.Allocator) void {
        if (self.reason) |v| allocator.free(v);
        if (self.additional_context) |v| allocator.free(v);
        if (self.error_message) |v| allocator.free(v);
        self.reason = null;
        self.additional_context = null;
        self.error_message = null;
    }
};

/// One flat `path -> value` pair available to `interpolate`, sourced from the
/// hook's own stdin payload fields (e.g. `tool_input.command`, `tool_name`).
pub const Field = struct { path: []const u8, value: []const u8 };

/// Result an `Invoker` reports back for one tool call. `output` is owned by
/// the caller of `Invoker` (duped onto the allocator passed to it).
pub const InvokeResult = struct {
    output: []u8,
    is_error: bool = false,
};

/// Signature for a live MCP-tool invoker: call `tool` on `server` with the
/// (already-interpolated) JSON `input_json`, honoring `timeout_ms`. `ctx`
/// carries whatever handle the caller needs (the live client registry); this
/// module never constructs one itself -- see the header scope note.
pub const Invoker = *const fn (
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    server: []const u8,
    tool: []const u8,
    input_json: []const u8,
    timeout_ms: u64,
) anyerror!InvokeResult;

/// Interpolate `${path}` placeholders in an mcp_tool hook's `input` JSON
/// template using the flat fields parsed out of the hook's own stdin payload
/// (mirrors the http hook's `${VAR}` env interpolation, but sourced from the
/// hook payload instead of the process environment). A `${path}` with no
/// match in `fields` resolves to "" rather than being left literal -- the
/// same undefined-reference behavior `hook_exec_http.interpolateEnvVars`
/// uses. A bare `$` or an unterminated `${` is copied through literally.
/// Caller owns the returned slice.
pub fn interpolate(allocator: std.mem.Allocator, template: []const u8, fields: []const Field) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '$' and i + 1 < template.len and template[i + 1] == '{') {
            const close = std.mem.indexOfScalarPos(u8, template, i + 2, '}') orelse {
                try out.append(allocator, template[i]);
                i += 1;
                continue;
            };
            const path = template[i + 2 .. close];
            const value = lookup(fields, path) orelse "";
            try out.appendSlice(allocator, value);
            i = close + 1;
            continue;
        }
        try out.append(allocator, template[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn lookup(fields: []const Field, path: []const u8) ?[]const u8 {
    for (fields) |f| {
        if (std.mem.eql(u8, f.path, path)) return f.value;
    }
    return null;
}

/// Run an `mcp_tool` hook. `def.mcp_input_json` (when set) is interpolated
/// against `fields` before being handed to `invoker`. With `invoker == null`
/// (no live registry wired -- today's only real call site), this degrades to
/// a documented non-blocking no-op rather than silently doing nothing.
pub fn runMcpToolHook(
    allocator: std.mem.Allocator,
    def: hook_config.HookDef,
    fields: []const Field,
    timeout_ms: u64,
    invoker: ?Invoker,
    invoker_ctx: ?*anyopaque,
) !McpToolOutcome {
    if (def.mcp_server.len == 0 or def.mcp_tool.len == 0) {
        return .{ .ran = true, .error_message = try allocator.dupe(u8, "mcp_tool hook is missing its \"server\"/\"tool\" fields") };
    }

    const input_json = if (def.mcp_input_json.len > 0)
        try interpolate(allocator, def.mcp_input_json, fields)
    else
        try allocator.dupe(u8, "{}");
    defer allocator.free(input_json);

    const inv = invoker orelse {
        return .{
            .ran = true,
            .error_message = try std.fmt.allocPrint(
                allocator,
                "mcp_tool hook {s}/{s} did not run: no MCP tool bridge is connected in this build",
                .{ def.mcp_server, def.mcp_tool },
            ),
        };
    };

    const result = inv(invoker_ctx.?, allocator, def.mcp_server, def.mcp_tool, input_json, timeout_ms) catch |err| {
        return .{
            .ran = true,
            .error_message = try std.fmt.allocPrint(
                allocator,
                "mcp_tool hook {s}/{s} failed: {s}",
                .{ def.mcp_server, def.mcp_tool, @errorName(err) },
            ),
        };
    };
    defer allocator.free(result.output);

    const hook_io = @import("hook_io.zig");
    if (result.is_error) {
        return .{ .ran = true, .error_message = try allocator.dupe(u8, result.output) };
    }
    var parsed = hook_io.parseOutput(allocator, result.output);
    defer parsed.deinit();

    const decision_block = if (parsed.output.decision) |d| std.ascii.eqlIgnoreCase(d, "block") else false;
    const denied = parsed.output.permission_decision == .deny;
    if (decision_block or denied) {
        const reason = parsed.output.reason orelse result.output;
        return .{ .ran = true, .blocked = true, .reason = try allocator.dupe(u8, reason) };
    }
    if (parsed.output.additional_context) |ac| {
        return .{ .ran = true, .additional_context = try allocator.dupe(u8, ac) };
    }
    return .{ .ran = true };
}

const testing = std.testing;

test "interpolate substitutes known paths and blanks unknown ones" {
    const fields = [_]Field{
        .{ .path = "tool_input.command", .value = "git status" },
        .{ .path = "tool_name", .value = "Bash" },
    };
    const out = try interpolate(testing.allocator, "{\"q\":\"${tool_input.command}\",\"who\":\"${tool_name}\",\"x\":\"${missing}\"}", &fields);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"q\":\"git status\",\"who\":\"Bash\",\"x\":\"\"}", out);
}

test "interpolate passes through text with no placeholders and tolerates a bare dollar sign" {
    const out = try interpolate(testing.allocator, "plain $ text", &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("plain $ text", out);
}

test "runMcpToolHook with no invoker reports a clear non-blocking error" {
    const def = hook_config.HookDef{
        .event = .pre_tool_use,
        .hook_type = .mcp_tool,
        .mcp_server = "github",
        .mcp_tool = "search_issues",
    };
    var outcome = try runMcpToolHook(testing.allocator, def, &.{}, 5000, null, null);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.ran);
    try testing.expect(!outcome.blocked);
    try testing.expect(outcome.error_message != null);
    try testing.expect(std.mem.indexOf(u8, outcome.error_message.?, "github") != null);
    try testing.expect(std.mem.indexOf(u8, outcome.error_message.?, "search_issues") != null);
}

test "runMcpToolHook rejects a def missing server/tool" {
    const def = hook_config.HookDef{ .event = .pre_tool_use, .hook_type = .mcp_tool };
    var outcome = try runMcpToolHook(testing.allocator, def, &.{}, 5000, null, null);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.ran);
    try testing.expect(!outcome.blocked);
    try testing.expect(outcome.error_message != null);
}

const FakeInvoker = struct {
    var last_server_buf: [64]u8 = undefined;
    var last_server_len: usize = 0;
    var last_input_buf: [256]u8 = undefined;
    var last_input_len: usize = 0;
    var response: []const u8 = "{}";
    var is_error: bool = false;

    fn call(ctx: *anyopaque, allocator: std.mem.Allocator, server: []const u8, tool: []const u8, input_json: []const u8, timeout_ms: u64) anyerror!InvokeResult {
        _ = ctx;
        _ = tool;
        _ = timeout_ms;
        last_server_len = @min(server.len, last_server_buf.len);
        @memcpy(last_server_buf[0..last_server_len], server[0..last_server_len]);
        last_input_len = @min(input_json.len, last_input_buf.len);
        @memcpy(last_input_buf[0..last_input_len], input_json[0..last_input_len]);
        return .{ .output = try allocator.dupe(u8, response), .is_error = is_error };
    }
};

test "runMcpToolHook calls the invoker with interpolated input and maps a deny to blocked" {
    FakeInvoker.response = "{\"hookSpecificOutput\":{\"permissionDecision\":\"deny\"}}";
    FakeInvoker.is_error = false;
    const fields = [_]Field{.{ .path = "tool_input.command", .value = "rm -rf /" }};
    const def = hook_config.HookDef{
        .event = .pre_tool_use,
        .hook_type = .mcp_tool,
        .mcp_server = "policy",
        .mcp_tool = "check",
        .mcp_input_json = "{\"cmd\":\"${tool_input.command}\"}",
    };
    var dummy: u8 = 0;
    var outcome = try runMcpToolHook(testing.allocator, def, &fields, 5000, FakeInvoker.call, @ptrCast(&dummy));
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.ran);
    try testing.expect(outcome.blocked);
    try testing.expectEqualStrings("policy", FakeInvoker.last_server_buf[0..FakeInvoker.last_server_len]);
    try testing.expect(std.mem.indexOf(u8, FakeInvoker.last_input_buf[0..FakeInvoker.last_input_len], "rm -rf /") != null);
}
