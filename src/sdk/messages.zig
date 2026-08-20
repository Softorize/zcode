//! sdk-headless-07: `system:init` + SDK `result` message builders.
//!
//! The *wire shape* of these two messages already lives in `sdk/output.zig`
//! (it landed with sdk-headless-02, which needed the shape to serialize the
//! `--output-format json|stream-json` path). That module's doc comment calls
//! this one out explicitly: "When the dedicated message module lands
//! (sdk-headless-07), these serializers can delegate to it." So rather than
//! duplicate the serializers, this module:
//!
//!   1. Re-exports the shape types and serializers from `sdk/output.zig` so a
//!      caller can import everything `system:init` / `result` from one place.
//!   2. Adds the genuinely-missing piece: the *builders* that map zcode's live
//!      runtime data into those shapes -- `buildResult` (TurnResult + token
//!      usage + provider/model -> the SDK `result` struct, with
//!      `total_cost_usd` computed from core/cost.zig:estimateCost) and
//!      `buildInit` (session metadata + registries -> the `system:init`
//!      struct).
//!
//! Reference behavior + file:line:
//!   coreSchemas.ts:1457  SDKSystemMessageSchema   (system:init)
//!   coreSchemas.ts:1407  SDKResultSuccessSchema
//!   coreSchemas.ts:1428  SDKResultErrorSchema
//!   coreSchemas.ts:1399  SDKPermissionDenialSchema
//!
//! Approximations (documented, not fabricated -- per project rule on not
//! stating guesses as facts):
//!   - `total_cost_usd` is an *estimate* from core/cost.zig:estimateCost using
//!     the static price table, NOT a billed figure. Unknown models yield 0.
//!   - `duration_api_ms` is the accumulated provider call time from
//!     core/metrics.zig (api_duration_ms_total). When the caller has no
//!     separate API timing it may pass the same value as `duration_ms`; the
//!     builder does not invent a number.

const std = @import("std");
const output = @import("output.zig");
const cost = @import("../core/cost.zig");
const hook_event = @import("../core/hook_event.zig");

// ---------------------------------------------------------------------------
// Shape re-exports. A caller wanting the `system:init` / `result` wire shape
// imports it from here; the canonical definition still lives in output.zig.
// ---------------------------------------------------------------------------

pub const Result = output.Result;
pub const ResultSubtype = output.ResultSubtype;
pub const Usage = output.Usage;
pub const PermissionDenial = output.PermissionDenial;
pub const InitInfo = output.InitInfo;

pub const serializeResult = output.serializeResult;
pub const serializeInit = output.serializeInit;
pub const streamInitAndResult = output.streamInitAndResult;

// sdk-headless-12: partial-message / hook-event / user-replay serializers.
pub const serializeStreamEvent = output.serializeStreamEvent;
pub const serializeHookEventSystem = output.serializeHookEventSystem;
pub const serializeUserReplay = output.serializeUserReplay;

/// sdk-headless-12 (`--include-hook-events`): serialize a hook-lifecycle
/// `system` event from a `core/hook_event.zig` Event, using the reference-exact
/// PascalCase name (e.g. .pre_tool_use -> "PreToolUse"). This is the bridge the
/// stream-json hook-event emitter uses so the wire name always matches the
/// canonical hook-event spelling rather than a re-stringified enum tag. Caller
/// owns the returned newline-terminated slice.
pub fn serializeHookEvent(
    allocator: std.mem.Allocator,
    event: hook_event.Event,
    tool_name: []const u8,
    tool_use_id: []const u8,
    session_id: []const u8,
) ![]u8 {
    return output.serializeHookEventSystem(
        allocator,
        hook_event.canonicalName(event),
        tool_name,
        tool_use_id,
        session_id,
    );
}

// ---------------------------------------------------------------------------
// Builders: map live runtime data into the SDK shapes.
// ---------------------------------------------------------------------------

/// The inputs a `result` message needs from a finished turn. These are the
/// fields the runtime already tracks; gathering them into one struct keeps
/// `buildResult` pure (no dependency on the concrete AgentRuntime type) so it
/// is unit-testable against hand-built inputs.
///
/// All slices are borrowed -- the returned `Result` borrows them too, so it
/// must not outlive its inputs. (No allocation happens here; serialization is
/// the allocating step.)
pub const ResultInputs = struct {
    subtype: ResultSubtype = .success,
    session_id: []const u8 = "",
    /// The assistant's final text (TurnResult.final_text).
    final_text: []const u8 = "",
    /// Tool-call rounds (TurnResult.rounds) -> num_turns.
    rounds: usize = 0,
    /// Active provider + model, used both for the cost estimate and as the
    /// single modelUsage key.
    provider: []const u8 = "",
    model: []const u8 = "",
    /// Session token totals (AgentRuntime.token_status).
    total_input_tokens: usize = 0,
    total_output_tokens: usize = 0,
    /// Wall-clock duration of the turn in milliseconds
    /// (core/metrics.zig:getSessionWallDurationMs deltas).
    duration_ms: i64 = 0,
    /// Accumulated provider call time in milliseconds
    /// (core/metrics.zig api_duration_ms_total). When not separately tracked,
    /// the caller passes the same value as `duration_ms` -- documented as an
    /// approximation, never an invented metric.
    duration_api_ms: i64 = 0,
    /// Why the turn stopped (e.g. "end_turn", "max_turns"). Empty -> omitted.
    stop_reason: []const u8 = "",
    /// Structured-output payload as raw JSON (from --json-schema), or empty.
    structured_output_json: []const u8 = "",
};

/// Build an SDK `result` struct from a finished turn. `total_cost_usd` is
/// computed from core/cost.zig:estimateCost over the session token totals at
/// the active provider/model (an estimate, $0 for unknown models). The
/// returned struct borrows the input slices.
pub fn buildResult(inputs: ResultInputs) Result {
    return .{
        .subtype = inputs.subtype,
        .session_id = inputs.session_id,
        .result_text = inputs.final_text,
        .num_turns = inputs.rounds,
        .total_cost_usd = cost.estimateCost(
            inputs.provider,
            inputs.model,
            inputs.total_input_tokens,
            inputs.total_output_tokens,
        ),
        .usage = .{
            .input_tokens = inputs.total_input_tokens,
            .output_tokens = inputs.total_output_tokens,
        },
        .model = inputs.model,
        .duration_ms = inputs.duration_ms,
        .duration_api_ms = inputs.duration_api_ms,
        .stop_reason = inputs.stop_reason,
        .structured_output_json = inputs.structured_output_json,
    };
}

/// The inputs a `system:init` message needs at session start. All slices are
/// borrowed; the returned `InitInfo` borrows them too. The registries (tools,
/// mcp_servers, slash_commands, skills, plugins) are gathered by the caller
/// from their respective registries -- this builder just assembles them into
/// the SDK shape.
pub const InitInputs = struct {
    session_id: []const u8 = "",
    model: []const u8 = "",
    permission_mode: []const u8 = "",
    cwd: []const u8 = "",
    claude_code_version: []const u8 = "",
    tools: []const []const u8 = &.{},
    mcp_servers: []const []const u8 = &.{},
    slash_commands: []const []const u8 = &.{},
    skills: []const []const u8 = &.{},
    plugins: []const []const u8 = &.{},
};

/// Build a `system:init` struct from session metadata + registries. The
/// returned struct borrows the input slices.
pub fn buildInit(inputs: InitInputs) InitInfo {
    return .{
        .session_id = inputs.session_id,
        .model = inputs.model,
        .permission_mode = inputs.permission_mode,
        .cwd = inputs.cwd,
        .claude_code_version = inputs.claude_code_version,
        .tools = inputs.tools,
        .mcp_servers = inputs.mcp_servers,
        .slash_commands = inputs.slash_commands,
        .skills = inputs.skills,
        .plugins = inputs.plugins,
    };
}

const testing = std.testing;

test "buildResult: maps turn data and estimates cost into the result struct" {
    // gpt-4.1: $2/M input, $8/M output. 100k input + 50k output ->
    // 100000*2/1e6 + 50000*8/1e6 = 0.20 + 0.40 = 0.60.
    const result = buildResult(.{
        .subtype = .success,
        .session_id = "sess-abc",
        .final_text = "all done",
        .rounds = 3,
        .provider = "openai",
        .model = "gpt-4.1",
        .total_input_tokens = 100_000,
        .total_output_tokens = 50_000,
        .duration_ms = 250,
        .duration_api_ms = 200,
        .stop_reason = "end_turn",
    });

    try testing.expectEqual(output.ResultSubtype.success, result.subtype);
    try testing.expectEqual(@as(usize, 3), result.num_turns);
    try testing.expectEqualStrings("all done", result.result_text);
    try testing.expectEqualStrings("gpt-4.1", result.model);
    try testing.expectEqual(@as(usize, 100_000), result.usage.input_tokens);
    try testing.expectEqual(@as(usize, 50_000), result.usage.output_tokens);
    try testing.expectApproxEqAbs(@as(f64, 0.60), result.total_cost_usd, 0.0001);
    try testing.expectEqual(@as(i64, 250), result.duration_ms);
    try testing.expectEqual(@as(i64, 200), result.duration_api_ms);
    try testing.expectEqualStrings("end_turn", result.stop_reason);
}

test "buildResult: unknown model yields zero estimated cost" {
    const result = buildResult(.{
        .provider = "unknown",
        .model = "nonexistent-model",
        .total_input_tokens = 1000,
        .total_output_tokens = 1000,
    });
    try testing.expectApproxEqAbs(@as(f64, 0.0), result.total_cost_usd, 0.000001);
}

test "buildResult serialized: type=result, subtype=success, all required keys present" {
    const allocator = testing.allocator;
    const result = buildResult(.{
        .subtype = .success,
        .session_id = "sess-xyz",
        .final_text = "ok",
        .rounds = 2,
        .provider = "anthropic",
        .model = "claude-sonnet-4-20250514",
        .total_input_tokens = 100_000,
        .total_output_tokens = 50_000,
    });
    const line = try serializeResult(allocator, result, &.{});
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    // Task G acceptance: type, subtype, num_turns, total_cost_usd,
    // usage.input_tokens, usage.output_tokens, permission_denials (array),
    // session_id.
    try testing.expectEqualStrings("result", obj.get("type").?.string);
    try testing.expectEqualStrings("success", obj.get("subtype").?.string);
    try testing.expect(obj.get("num_turns") != null);
    try testing.expectEqual(@as(i64, 2), obj.get("num_turns").?.integer);
    try testing.expect(obj.get("total_cost_usd") != null);
    try testing.expect(obj.get("usage").?.object.get("input_tokens") != null);
    try testing.expect(obj.get("usage").?.object.get("output_tokens") != null);
    try testing.expect(obj.get("permission_denials") != null);
    try testing.expect(obj.get("permission_denials").? == .array);
    try testing.expectEqualStrings("sess-xyz", obj.get("session_id").?.string);
}

test "buildResult serialized: error subtype produces an error result" {
    const allocator = testing.allocator;
    const result = buildResult(.{
        .subtype = .error_max_turns,
        .final_text = "turn budget exhausted",
        .rounds = 1,
        .provider = "mock",
        .model = "mock-agent",
    });
    const line = try serializeResult(allocator, result, &.{});
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("error_max_turns", obj.get("subtype").?.string);
    try testing.expectEqual(true, obj.get("is_error").?.bool);
}

test "buildInit serialized: type=system, subtype=init, contains tools/model/cwd/version" {
    const allocator = testing.allocator;
    const tools = [_][]const u8{ "Read", "Write", "Bash" };
    const info = buildInit(.{
        .session_id = "sess-init",
        .model = "mock-agent",
        .permission_mode = "default",
        .cwd = "/tmp/work",
        .claude_code_version = "0.11.73+abc",
        .tools = &tools,
    });
    const line = try serializeInit(allocator, info);
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    // Task G acceptance: type=="system", subtype=="init", contains tools,
    // model, cwd, claude_code_version.
    try testing.expectEqualStrings("system", obj.get("type").?.string);
    try testing.expectEqualStrings("init", obj.get("subtype").?.string);
    try testing.expect(obj.get("tools") != null);
    try testing.expectEqual(@as(usize, 3), obj.get("tools").?.array.items.len);
    try testing.expectEqualStrings("mock-agent", obj.get("model").?.string);
    try testing.expectEqualStrings("/tmp/work", obj.get("cwd").?.string);
    try testing.expectEqualStrings("0.11.73+abc", obj.get("claude_code_version").?.string);
}

test "sdk-headless-12: serializeHookEvent maps a HookEvent to its canonical name" {
    const allocator = testing.allocator;
    // A mock hook fires (PreToolUse for a Bash tool call).
    const line = try serializeHookEvent(allocator, .pre_tool_use, "Bash", "tu-1", "sess-h");
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("system", obj.get("type").?.string);
    try testing.expectEqualStrings("hook_event", obj.get("subtype").?.string);
    // Reference-exact PascalCase name, not the enum tag.
    try testing.expectEqualStrings("PreToolUse", obj.get("hook_event_name").?.string);
    try testing.expectEqualStrings("Bash", obj.get("tool_name").?.string);
    try testing.expectEqualStrings("tu-1", obj.get("tool_use_id").?.string);
    try testing.expectEqualStrings("sess-h", obj.get("session_id").?.string);
}
