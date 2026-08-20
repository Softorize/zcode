//! Task 6 (PRD #534, hooks-02 + hooks-16): execute `prompt` and `agent` hook
//! types by querying an LLM, instead of skipping past them. Both share the same
//! `{ok, reason}` verification contract:
//!
//!   - prompt hook  -> single-shot small/fast-model query (execPromptHook.ts).
//!   - agent  hook  -> a multi-turn agentic verifier in the reference
//!     (execAgentHook.ts). For first parity we run it as the same single-shot
//!     json-schema query; the full multi-turn StructuredOutput loop is a
//!     follow-up (see the phase plan's out-of-scope notes).
//!
//! `$ARGUMENTS` (and the indexed / shorthand forms) in the hook body are
//! substituted with the JSON input payload before the model call, matching
//! `hookHelpers.addArgumentsToPrompt` -> `substituteArguments`.
//!
//! IMPORTANT: prompt/agent hooks call the provider directly. They must NOT route
//! through the normal prompt-submit path, or a UserPromptSubmit hook would
//! recurse into itself (reference comment execPromptHook.ts:41).

const std = @import("std");
const types = @import("types.zig");
const providers = @import("../providers/mod.zig");
const hook_config = @import("hook_config.zig");
const argument_substitution = @import("argument_substitution.zig");
const env = @import("env.zig");

/// Type-specific default timeouts (ms). Task 8 owns full timeout enforcement;
/// these constants are the defaults that task applies, kept here so the prompt
/// path documents its own contract (execPromptHook.ts:55 = 30s,
/// execAgentHook.ts:75 = 60s).
pub const PROMPT_TIMEOUT_MS: u64 = 30_000;
pub const AGENT_TIMEOUT_MS: u64 = 60_000;

/// System prompt for prompt hooks, verbatim from execPromptHook.ts:65-69.
const PROMPT_SYSTEM =
    \\You are evaluating a hook in Claude Code.
    \\
    \\Your response must be a JSON object matching one of the following schemas:
    \\1. If the condition is met, return: {"ok": true}
    \\2. If the condition is not met, return: {"ok": false, "reason": "Reason for why it is not met"}
;

/// System prompt for agent hooks, condensed from execAgentHook.ts. The reference
/// runs a multi-turn agentic verifier; our first-parity single-shot variant asks
/// for the same `{ok, reason}` result directly.
const AGENT_SYSTEM =
    \\You are verifying a stop condition in Claude Code. Your task is to verify that the agent completed the given plan.
    \\
    \\Return your result as a JSON object with:
    \\- ok: true if the condition is met
    \\- ok: false with a reason if the condition is not met
;

/// The json-schema the model output must conform to (`{ok: boolean, reason?:
/// string}`), embedded into the request for providers that support structured
/// output. Mirrors hookHelpers.createStructuredOutputTool / hookResponseSchema.
const OK_REASON_SCHEMA =
    \\{"type":"object","properties":{"ok":{"type":"boolean"},"reason":{"type":"string"}},"required":["ok"],"additionalProperties":false}
;

/// Default model used when the hook def does not pin one. The reference uses
/// `getSmallFastModel()`; we resolve the small/fast model name from env with a
/// safe Haiku fallback so a missing config never crashes the hook.
const DEFAULT_MODEL = "claude-haiku-4-5";

/// Outcome of running a prompt/agent hook. `blocked` means the verifier returned
/// `ok:false` (or, for prompt hooks, the condition was not met) and the caller
/// should treat the event as blocked with `reason`. A parse/model error is a
/// non-blocking error: `ran == true`, `blocked == false`, `error_message` set.
/// All owned slices are duped onto the supplied allocator and freed in deinit.
pub const PromptOutcome = struct {
    ran: bool = false,
    blocked: bool = false,
    /// The `reason` from `{ok:false, reason}` (or a synthesized one). Owned.
    reason: ?[]u8 = null,
    /// Non-blocking error description (JSON parse failure, model error). Owned.
    error_message: ?[]u8 = null,

    pub fn deinit(self: *PromptOutcome, allocator: std.mem.Allocator) void {
        if (self.reason) |v| allocator.free(v);
        if (self.error_message) |v| allocator.free(v);
        self.reason = null;
        self.error_message = null;
    }

    fn nonBlockingError(allocator: std.mem.Allocator, msg: []const u8) PromptOutcome {
        return .{
            .ran = true,
            .blocked = false,
            .error_message = allocator.dupe(u8, msg) catch null,
        };
    }
};

/// Run a prompt hook against an injected provider adapter. This is the
/// fully-unit-testable core: tests pass a mock adapter so no network is hit.
/// `json_input` is the per-event stdin payload (Task 4); `$ARGUMENTS` in
/// `def.body` is substituted with it before the model call.
pub fn runPromptHookWithAdapter(
    allocator: std.mem.Allocator,
    adapter: *types.ProviderAdapter,
    def: hook_config.HookDef,
    json_input: []const u8,
) !PromptOutcome {
    return runVerifierWithAdapter(allocator, adapter, def, json_input, PROMPT_SYSTEM);
}

/// Run an agent hook against an injected provider adapter. First-parity
/// single-shot variant of the reference multi-turn verifier; same `{ok, reason}`
/// contract, different system prompt.
pub fn runAgentHookWithAdapter(
    allocator: std.mem.Allocator,
    adapter: *types.ProviderAdapter,
    def: hook_config.HookDef,
    json_input: []const u8,
) !PromptOutcome {
    return runVerifierWithAdapter(allocator, adapter, def, json_input, AGENT_SYSTEM);
}

fn runVerifierWithAdapter(
    allocator: std.mem.Allocator,
    adapter: *types.ProviderAdapter,
    def: hook_config.HookDef,
    json_input: []const u8,
    system_prompt: []const u8,
) !PromptOutcome {
    // Substitute $ARGUMENTS (and indexed/shorthand forms) with the JSON input.
    // The reference's addArgumentsToPrompt uses the default append-if-missing
    // behavior, so the JSON input is appended when the body has no placeholder.
    const processed = try argument_substitution.substituteArguments(allocator, def.body, json_input, true, &.{});
    defer allocator.free(processed);

    const model = if (def.model.len > 0) def.model else DEFAULT_MODEL;

    const request = types.ModelRequest{
        .model = model,
        .system_prompt = system_prompt,
        .prompt = processed,
        .max_output_tokens = 1024,
        .temperature = 0.0,
        .response_schema = OK_REASON_SCHEMA,
        .response_schema_name = "hook_response",
    };

    const response = adapter.send(allocator, request) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "prompt hook model error: {s}", .{@errorName(err)});
        defer allocator.free(msg);
        return PromptOutcome.nonBlockingError(allocator, msg);
    };
    defer allocator.free(response.raw);
    defer allocator.free(response.text);

    return mapVerifierResponse(allocator, response.text);
}

/// Parse the `{ok, reason}` verifier response and map it to an outcome:
///   - valid `{ok:true}`           -> ran, not blocked.
///   - valid `{ok:false, reason}`  -> ran, blocked, reason surfaced.
///   - parse / schema failure      -> ran, non-blocking error.
fn mapVerifierResponse(allocator: std.mem.Allocator, text: []const u8) PromptOutcome {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const ok_reason = parseOkReason(allocator, trimmed) catch {
        return PromptOutcome.nonBlockingError(allocator, "JSON validation failed");
    };

    if (ok_reason.ok) {
        return .{ .ran = true, .blocked = false };
    }

    // Condition not met -> blocking with the reason (default if absent).
    const reason = ok_reason.reason orelse allocator.dupe(u8, "condition not met") catch null;
    return .{ .ran = true, .blocked = true, .reason = reason };
}

const OkReason = struct { ok: bool, reason: ?[]u8 };

/// Parse a `{ok: bool, reason?: string}` object. Returns error on anything that
/// is not a JSON object with a boolean `ok`. The `reason` (if present and a
/// string) is duped onto `allocator`.
fn parseOkReason(allocator: std.mem.Allocator, text: []const u8) !OkReason {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.NotAnObject;
    const ok_val = parsed.value.object.get("ok") orelse return error.MissingOk;
    if (ok_val != .bool) return error.OkNotBool;

    var reason: ?[]u8 = null;
    if (parsed.value.object.get("reason")) |rv| {
        if (rv == .string) reason = try allocator.dupe(u8, rv.string);
    }
    return .{ .ok = ok_val.bool, .reason = reason };
}

/// Resolve the provider name for hook execution. Lets a test (or operator) pin
/// the provider via env without threading the full config through the dispatch
/// layer. Falls back to ZCODE_PROVIDER, then to anthropic. Caller owns the slice.
pub fn resolveProvider(allocator: std.mem.Allocator) ![]u8 {
    if (env.getOwned(allocator, "ZCODE_HOOK_PROVIDER")) |v| {
        if (v.len > 0) return v;
        allocator.free(v);
    } else |_| {}
    if (env.getOwned(allocator, "ZCODE_PROVIDER")) |v| {
        if (v.len > 0) return v;
        allocator.free(v);
    } else |_| {}
    return allocator.dupe(u8, "anthropic");
}

/// Resolve the model for a hook: the def's pinned model wins; else ZCODE_HOOK_MODEL,
/// then ZCODE_MODEL, then the small/fast default. Caller owns the slice.
pub fn resolveModel(allocator: std.mem.Allocator, def: hook_config.HookDef) ![]u8 {
    if (def.model.len > 0) return allocator.dupe(u8, def.model);
    if (env.getOwned(allocator, "ZCODE_HOOK_MODEL")) |v| {
        if (v.len > 0) return v;
        allocator.free(v);
    } else |_| {}
    if (env.getOwned(allocator, "ZCODE_MODEL")) |v| {
        if (v.len > 0) return v;
        allocator.free(v);
    } else |_| {}
    return allocator.dupe(u8, DEFAULT_MODEL);
}

/// Convenience entry used by the dispatch layer (hooks.zig): resolve the
/// provider/model from env, create the adapter, run the prompt hook. A model
/// pinned on `def` overrides the resolved default. The created adapter is freed
/// here. On adapter-creation failure the hook is a non-blocking error (the agent
/// continues), matching the reference's non_blocking_error outcome.
pub fn runPromptHook(allocator: std.mem.Allocator, def: hook_config.HookDef, json_input: []const u8) !PromptOutcome {
    return runResolved(allocator, def, json_input, false);
}

pub fn runAgentHook(allocator: std.mem.Allocator, def: hook_config.HookDef, json_input: []const u8) !PromptOutcome {
    return runResolved(allocator, def, json_input, true);
}

fn runResolved(allocator: std.mem.Allocator, def: hook_config.HookDef, json_input: []const u8, is_agent: bool) !PromptOutcome {
    const provider = try resolveProvider(allocator);
    defer allocator.free(provider);
    const model = try resolveModel(allocator, def);
    defer allocator.free(model);

    var adapter = providers.createAdapterWithOverrides(allocator, provider, .{}) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "hook provider unavailable: {s}", .{@errorName(err)});
        defer allocator.free(msg);
        return PromptOutcome.nonBlockingError(allocator, msg);
    };
    defer adapter.deinit(allocator);

    // The resolved model overrides def.model only when def has none; pass a
    // def copy with the resolved model so the executor uses it.
    var def_with_model = def;
    def_with_model.model = model;

    return if (is_agent)
        runAgentHookWithAdapter(allocator, &adapter, def_with_model, json_input)
    else
        runPromptHookWithAdapter(allocator, &adapter, def_with_model, json_input);
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A minimal in-test provider adapter that returns a fixed response and records
/// the last request's prompt + system prompt, so tests can assert on what the
/// model received (e.g. that $ARGUMENTS was substituted).
const RecordingAdapter = struct {
    response: []const u8,
    last_prompt: ?[]u8 = null,
    last_system: ?[]u8 = null,
    allocator: std.mem.Allocator,

    fn deinit(self: *RecordingAdapter) void {
        if (self.last_prompt) |v| self.allocator.free(v);
        if (self.last_system) |v| self.allocator.free(v);
    }

    fn vtSend(ctx: *anyopaque, allocator: std.mem.Allocator, request: types.ModelRequest) anyerror!types.ModelResponse {
        const self: *RecordingAdapter = @ptrCast(@alignCast(ctx));
        if (self.last_prompt) |v| self.allocator.free(v);
        if (self.last_system) |v| self.allocator.free(v);
        self.last_prompt = try self.allocator.dupe(u8, request.prompt);
        self.last_system = try self.allocator.dupe(u8, request.system_prompt);
        return .{
            .raw = try allocator.dupe(u8, self.response),
            .text = try allocator.dupe(u8, self.response),
            .usage_input_tokens = 0,
            .usage_output_tokens = 0,
        };
    }

    fn vtDeinit(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        _ = ctx;
        _ = allocator;
    }
    fn vtListModels(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]types.ModelInfo {
        _ = ctx;
        return allocator.alloc(types.ModelInfo, 0);
    }
    fn vtStream(ctx: *anyopaque, allocator: std.mem.Allocator, request: types.ModelRequest) anyerror![]const u8 {
        const r = try vtSend(ctx, allocator, request);
        allocator.free(r.raw);
        return r.text;
    }
    fn vtHealth(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        _ = ctx;
        _ = allocator;
    }

    const vtable = types.ProviderAdapter.VTable{
        .deinit = vtDeinit,
        .listModels = vtListModels,
        .send = vtSend,
        .stream = vtStream,
        .healthcheck = vtHealth,
    };

    fn adapter(self: *RecordingAdapter) types.ProviderAdapter {
        return .{ .name = "recording", .ctx = self, .vtable = &vtable };
    }
};

test "prompt hook: ok:false blocks with the reason" {
    const alloc = testing.allocator;
    var rec = RecordingAdapter{ .response = "{\"ok\":false,\"reason\":\"missing tests\"}", .allocator = alloc };
    defer rec.deinit();
    var ad = rec.adapter();

    const def = hook_config.HookDef{ .event = .pre_tool_use, .hook_type = .prompt, .body = "verify tests exist" };
    var outcome = try runPromptHookWithAdapter(alloc, &ad, def, "{\"hook_event_name\":\"PreToolUse\"}");
    defer outcome.deinit(alloc);

    try testing.expect(outcome.ran);
    try testing.expect(outcome.blocked);
    try testing.expectEqualStrings("missing tests", outcome.reason.?);
}

test "prompt hook: ok:true does not block" {
    const alloc = testing.allocator;
    var rec = RecordingAdapter{ .response = "{\"ok\":true}", .allocator = alloc };
    defer rec.deinit();
    var ad = rec.adapter();

    const def = hook_config.HookDef{ .event = .pre_tool_use, .hook_type = .prompt, .body = "verify" };
    var outcome = try runPromptHookWithAdapter(alloc, &ad, def, "{}");
    defer outcome.deinit(alloc);

    try testing.expect(outcome.ran);
    try testing.expect(!outcome.blocked);
    try testing.expect(outcome.reason == null);
}

test "prompt hook: $ARGUMENTS is substituted into the prompt before the model call" {
    const alloc = testing.allocator;
    var rec = RecordingAdapter{ .response = "{\"ok\":true}", .allocator = alloc };
    defer rec.deinit();
    var ad = rec.adapter();

    const json_input = "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"hi\"}";
    const def = hook_config.HookDef{ .event = .user_prompt_submit, .hook_type = .prompt, .body = "Check this: $ARGUMENTS" };
    var outcome = try runPromptHookWithAdapter(alloc, &ad, def, json_input);
    defer outcome.deinit(alloc);

    // The mock recorded the prompt actually sent: $ARGUMENTS must be gone and the
    // full JSON input must be present in its place.
    const sent = rec.last_prompt.?;
    try testing.expect(std.mem.indexOf(u8, sent, "$ARGUMENTS") == null);
    try testing.expect(std.mem.indexOf(u8, sent, json_input) != null);
}

test "prompt hook: non-JSON model output is a non-blocking error" {
    const alloc = testing.allocator;
    var rec = RecordingAdapter{ .response = "not json at all", .allocator = alloc };
    defer rec.deinit();
    var ad = rec.adapter();

    const def = hook_config.HookDef{ .event = .pre_tool_use, .hook_type = .prompt, .body = "verify" };
    var outcome = try runPromptHookWithAdapter(alloc, &ad, def, "{}");
    defer outcome.deinit(alloc);

    try testing.expect(outcome.ran);
    try testing.expect(!outcome.blocked);
    try testing.expect(outcome.error_message != null);
}

test "agent hook: ok:true returns a non-blocking success" {
    const alloc = testing.allocator;
    var rec = RecordingAdapter{ .response = "{\"ok\":true}", .allocator = alloc };
    defer rec.deinit();
    var ad = rec.adapter();

    const def = hook_config.HookDef{ .event = .stop, .hook_type = .agent, .body = "verify the plan was completed" };
    var outcome = try runAgentHookWithAdapter(alloc, &ad, def, "{}");
    defer outcome.deinit(alloc);

    try testing.expect(outcome.ran);
    try testing.expect(!outcome.blocked);
    // The agent system prompt (not the prompt-hook one) was used.
    try testing.expect(std.mem.indexOf(u8, rec.last_system.?, "verifying a stop condition") != null);
}

test "agent hook: ok:false blocks with the reason" {
    const alloc = testing.allocator;
    var rec = RecordingAdapter{ .response = "{\"ok\":false,\"reason\":\"plan incomplete\"}", .allocator = alloc };
    defer rec.deinit();
    var ad = rec.adapter();

    const def = hook_config.HookDef{ .event = .stop, .hook_type = .agent, .body = "verify" };
    var outcome = try runAgentHookWithAdapter(alloc, &ad, def, "{}");
    defer outcome.deinit(alloc);

    try testing.expect(outcome.ran);
    try testing.expect(outcome.blocked);
    try testing.expectEqualStrings("plan incomplete", outcome.reason.?);
}

test "resolveModel: def.model wins over env and default" {
    const alloc = testing.allocator;
    const def = hook_config.HookDef{ .event = .pre_tool_use, .hook_type = .prompt, .body = "x", .model = "claude-opus-4" };
    const m = try resolveModel(alloc, def);
    defer alloc.free(m);
    try testing.expectEqualStrings("claude-opus-4", m);
}
