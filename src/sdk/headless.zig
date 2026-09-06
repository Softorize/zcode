//! sdk-headless wiring: the LIVE dispatch that routes `--print`/`--output-format`
//! and `--input-format stream-json` into the SDK serializers and the
//! bidirectional control protocol.
//!
//! The deep modules (sdk/output.zig, sdk/messages.zig, sdk/structured_io.zig,
//! sdk/control.zig, sdk/stdout_guard.zig) were built and unit-tested in earlier
//! Phase-21 tasks but were never wired into the live process: `--print
//! --output-format json|stream-json` still routed to the legacy
//! `runOneShot`/`encodeExecJson` blob. This module is that missing wiring.
//!
//! Three live paths, all gated behind `CliOptions.headless` (set by `--print`,
//! `run`, `exec`, or any SDK transport flag) and keyed off the output/input
//! format:
//!   - output-format json        : run one headless turn, emit a single SDK
//!                                  `result` object (NOT the legacy blob).
//!   - output-format stream-json  : require --verbose; emit `system:init` first,
//!                                  then the `result`, each as an NDJSON line
//!                                  written through the stdout guard.
//!   - input-format stream-json   : drive the run from stdin NDJSON via
//!                                  structured_io.runDispatchLoop; install the
//!                                  can_use_tool relay so each permission
//!                                  decision is relayed to the host as a
//!                                  `control_request` and resolved from the
//!                                  host's `control_response`; route the live
//!                                  control subtypes (interrupt /
//!                                  set_permission_mode / set_model /
//!                                  set_max_thinking_tokens) into the runtime.
//!
//! Concurrency model: zcode is synchronous one-turn. When a tool needs
//! permission the turn loop calls the relay approver on the SAME thread; the
//! relay writes the `can_use_tool` request to the host and BLOCK-READS the next
//! control_response line from stdin to resolve the decision (the turn is paused
//! inside the gate callback, so this is safe and deadlock-free for the single
//! host<->CLI pair). Live-control subtypes that arrive interleaved with the
//! permission exchange are dispatched as they are read.
//!
//! is_test seam: the live entry points take a `reader`/`writer` so the hermetic
//! suite drives them with in-memory pipes; nothing here touches real stdin/
//! stdout until main.zig passes the real std_io reader/writer behind the
//! headless gate.

const std = @import("std");
const rt = @import("zcode_runtime");
const build_options = @import("build_options");

const std_io = @import("../core/std_io.zig");
const types = @import("../core/types.zig");
const cost_mod = @import("../core/cost.zig");
const config_mod = @import("../core/config.zig");
const policy_mod = @import("../policy/policy.zig");
const logger_mod = @import("../core/logger.zig");
const session_store = @import("../session/store.zig");
const mcp_client = @import("../mcp/client.zig");
const browser_bridge_mod = @import("../mcp/browser_bridge.zig");
const prompt_sections = @import("../core/prompt_sections.zig");
const tool_schemas = @import("../tools/tool_schemas.zig");
const uuid_mod = @import("../core/uuid.zig");
const plugins_mod = @import("../core/plugins.zig");
const permission_decision_mod = @import("../core/permission_decision.zig");
const approval_mod = @import("../core/approval.zig");
const env_mod = @import("../core/env.zig");
const args_json = @import("args_json.zig");
const skills_mod = @import("../core/skills.zig");

const agent_runtime = @import("../agent_runtime.zig");
const AgentRuntime = agent_runtime.AgentRuntime;

const output = @import("output.zig");
const messages = @import("messages.zig");
const control = @import("control.zig");
const structured_io = @import("structured_io.zig");
const stdout_guard = @import("stdout_guard.zig");

/// The SDK transport selection resolved from CliOptions. Built by `resolve`
/// from the raw `--output-format` / `--input-format` strings (already parsed
/// into CliOptions) so the dispatcher never re-parses the wire tokens.
pub const Transport = struct {
    output_format: output.OutputFormat,
    input_format: structured_io.InputFormat,
};

/// Resolve the transport from the raw format strings. A null string defaults to
/// `text`. Surfaces output.parse / structured_io.parse usage errors verbatim so
/// the caller can exit non-zero with the already-printed message.
pub fn resolve(output_format: ?[]const u8, input_format: ?[]const u8) !Transport {
    const ofmt = if (output_format) |s| try output.OutputFormat.parse(s) else .text;
    const ifmt = if (input_format) |s| try structured_io.InputFormat.parse(s) else .text;
    return .{ .output_format = ofmt, .input_format = ifmt };
}

/// True when the resolved transport asks for an SDK-shaped path (anything other
/// than plain text output with text input). When false the caller keeps the
/// legacy `run`/`exec` rendering. This is the single switch main.zig uses to
/// decide whether to hand off to this module.
pub fn isSdkShaped(t: Transport) bool {
    return t.output_format != .text or t.input_format != .text;
}

/// The caps + run inputs threaded from the CLI flags, mirroring
/// session_mgmt.HeadlessCaps so this module does not import session_mgmt
/// (which imports half the world). Built by main.zig from CliOptions.
pub const RunCaps = struct {
    max_turns: ?usize = null,
    max_budget_usd: ?f64 = null,
    json_schema: ?[]const u8 = null,
    max_thinking_tokens: ?usize = null,
    /// headless-sdk-02: `--session-id <uuid>` override. When set, the run's
    /// session id is this exact value instead of whatever `store.
    /// createSessionId()` minted, and every SDK message echoes it.
    session_id_override: ?[]const u8 = null,
    /// headless-sdk-02: `--no-session-persistence`. When true, the run's
    /// session file is removed from disk once the turn completes instead of
    /// being left in the sessions directory. This is a best-effort
    /// write-then-remove (the append happens through agent_history.zig,
    /// outside this package's ownership) rather than preventing the write,
    /// but the observable outcome the reference specifies -- no session file
    /// left behind for the run -- is honored.
    no_session_persistence: bool = false,
    /// headless-sdk-14: `--forward-subagent-text`. When true, each completed
    /// Agent/subagent tool call in this turn's stream-json output also emits
    /// the subagent's own (real) prompt as a `user` line and its own (real)
    /// final text as an `assistant` line, both carrying `parent_tool_use_id`
    /// set to that tool call's tool_use id -- see
    /// `maybeForwardSubagentText`. Validated (requires --print and
    /// --output-format=stream-json) by
    /// `sdk_output.validateForwardSubagentTextGate` before a run starts.
    forward_subagent_text: bool = false,
    /// headless-sdk-15: `--prompt-suggestions`. When true, a
    /// `prompt_suggestion` NDJSON line is emitted after each turn's `result`
    /// line in stream-json output -- see `maybeEmitPromptSuggestion`.
    /// Validated (requires --print and --output-format=stream-json) by
    /// `sdk_output.validatePromptSuggestionsGate` before a run starts.
    prompt_suggestions: bool = false,
    /// headless-sdk-missed-185: `--enable-auth-status` (hidden). When true,
    /// a real `auth_status` message is emitted once at session start
    /// (stream-json output only), reflecting the session's ACTUAL resolved
    /// credential source (the same check `system:init.apiKeySource` already
    /// uses) -- see `maybeEmitAuthStatus`. Previously this flag parsed and
    /// the message serializer existed, but no call site anywhere ever
    /// invoked it, so no real invocation could ever produce an `auth_status`
    /// message regardless of the flag.
    enable_auth_status: bool = false,
};

/// Everything a headless turn needs that is not part of the transport: the
/// scaffolding the dispatcher builds an AgentRuntime from. main.zig owns these
/// objects (the same ones it passes to runInteractive / runOneShot).
pub const RunContext = struct {
    allocator: std.mem.Allocator,
    cwd: []const u8,
    /// headless-sdk-missed-183: MUTABLE (not `*const`) on purpose. main.zig
    /// owns exactly one live `Config` value for the whole process and every
    /// reader downstream (prompt_engine.zig, prompt_helpers.zig,
    /// agent_runtime.zig) already borrows a pointer to that SAME storage --
    /// widening this field from `*const` to `*` is what lets an
    /// `initialize` control_request's `systemPrompt`/`appendSystemPrompt`
    /// fields (applierSetSystemPrompt/applierSetAppendSystemPrompt) mutate
    /// `cfg.system_prompt_override`/`cfg.append_system_prompt` -- the EXACT
    /// same fields `--system-prompt`/`--append-system-prompt` already write
    /// -- and have that change take effect on the session's NEXT turn, the
    /// same "late injection" the reference's initialize handshake promises.
    /// Every other reader in this file only ever reads through it, so this
    /// is a pure widening: nothing that used to require `*const` breaks.
    cfg: *config_mod.Config,
    policy: *policy_mod.Policy,
    audit: *logger_mod.AuditLogger,
    store: *session_store.Store,
    mcp: *mcp_client.Client,
    browser: ?*browser_bridge_mod.BrowserBridge,
    auto_approve_high: bool,
    strict: bool,
    yolo_mode: bool,
    initial_agent: ?[]const u8,
    caps: RunCaps,
};

/// One completed tool call from a turn, mapped into the shape the stream-json
/// `tool_use`/`tool_result` events and `result.permission_denials` need
/// (headless-sdk-07/missed-182). Built from `agent_runtime.ToolTrace` right
/// after a turn finishes (before the TurnResult that owns the traces is
/// freed) so the mapped fields outlive it.
///
/// `tool_use_id` is SYNTHESIZED (`toolu_<session>_<round-index>`), not the
/// model's own id: zcode's `core/parse_helpers.ToolCall` does not carry a
/// per-call id from the provider response today, so there is no real id to
/// thread through. This is a documented approximation -- every OTHER field
/// (name, input, output, denied) reflects the real dispatched call.
const ToolEvent = struct {
    tool_use_id: []u8,
    name: []u8,
    input_json: []u8,
    output_text: []u8,
    /// True when the call was never executed because a permission gate denied
    /// or blocked it (ApprovalState.denied / .blocked).
    denied: bool,
    /// True when the tool_result should carry `is_error: true` -- a denial, or
    /// a call the runtime marked as not executed for any other reason.
    is_error: bool,

    fn deinit(self: *ToolEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_use_id);
        allocator.free(self.name);
        allocator.free(self.input_json);
        allocator.free(self.output_text);
    }
};

fn freeToolEvents(allocator: std.mem.Allocator, events: []ToolEvent) void {
    for (events) |*e| e.deinit(allocator);
    allocator.free(events);
}

/// headless-sdk-11 (`rewind_files`): one entry in `StreamSession.
/// known_user_messages` -- see that field's doc comment for why this
/// mapping exists.
const UserMessageRecord = struct {
    message_uuid: []u8,
    history_index: usize,
};

/// Free a slice of owned (duped) strings plus the slice itself. Used for the
/// small string lists an `initialize` control_request registers
/// (missed-183: sdk_agent_names / sdk_mcp_server_names).
fn freeOwnedStrings(allocator: std.mem.Allocator, items: [][]u8) void {
    for (items) |i| allocator.free(i);
    if (items.len > 0) allocator.free(items);
}

/// Map a finished turn's `ToolTrace` list into owned `ToolEvent`s. Caller owns
/// the returned slice (free with `freeToolEvents`).
fn buildToolEvents(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    traces: []const agent_runtime.ToolTrace,
) ![]ToolEvent {
    const out = try allocator.alloc(ToolEvent, traces.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |*e| e.deinit(allocator);
        allocator.free(out);
    }
    for (traces, 0..) |t, idx| {
        const id = try std.fmt.allocPrint(allocator, "toolu_{s}_{d}", .{ session_id, idx });
        errdefer allocator.free(id);
        const name = try allocator.dupe(u8, t.name);
        errdefer allocator.free(name);
        // t.args is zcode's internal `key=value` mini-format, never JSON --
        // args_json converts it to the real JSON object the SDK wire shapes
        // require (see that module's doc comment for why).
        const input_json = try args_json.toJsonObject(allocator, t.args);
        errdefer allocator.free(input_json);
        const output_text = try allocator.dupe(u8, t.output);
        const denied = t.approval_state == .denied or t.approval_state == .blocked;
        out[idx] = .{
            .tool_use_id = id,
            .name = name,
            .input_json = input_json,
            .output_text = output_text,
            .denied = denied,
            .is_error = denied or !t.executed,
        };
        built += 1;
    }
    return out;
}

/// True for the model-facing names the subagent-launcher tool is dispatched
/// under (tools-01: "Agent" is reference-exact; "AgentRun"/"agent_run" are
/// zcode's legacy dispatch-only synonyms -- see agent_tools.isAgentRunTool).
/// headless-sdk-16: the current, sorted, allocator-owned list of skill/
/// command names visible at `cwd` (read-only use of `core/skills.list` --
/// the actual discovery logic is that module's, not duplicated here).
/// Caller frees with `freeOwnedStrings`.
fn snapshotSortedSkillNames(allocator: std.mem.Allocator, cwd: []const u8) ![][]u8 {
    const specs = try skills_mod.list(allocator, cwd);
    defer skills_mod.freeList(allocator, specs);

    const names = try allocator.alloc([]u8, specs.len);
    var filled: usize = 0;
    errdefer {
        for (names[0..filled]) |n| allocator.free(n);
        allocator.free(names);
    }
    for (specs) |s| {
        names[filled] = try allocator.dupe(u8, s.name);
        filled += 1;
    }
    std.mem.sort([]u8, names, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return names;
}

/// Exact-equality check for two sorted name lists (same length, same names in
/// the same order). Used by `maybeEmitCommandsChanged` to decide whether the
/// skill/command list genuinely changed since the last turn.
fn skillNameListsEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

fn isAgentToolName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Agent") or std.mem.eql(u8, name, "AgentRun") or std.mem.eql(u8, name, "agent_run");
}

/// Pull a top-level string field out of a small JSON object, or null when the
/// object doesn't parse, the field is absent, not a string, or empty.
/// Returns an allocator-owned copy; caller frees.
fn extractJsonStringField(allocator: std.mem.Allocator, json_text: []const u8, field: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const val = obj.get(field) orelse return null;
    const s = switch (val) {
        .string => |str| str,
        else => return null,
    };
    if (s.len == 0) return null;
    return try allocator.dupe(u8, s);
}

/// A completed foreground Agent/subagent tool call's own final text, or null
/// when `output_text` isn't shaped like one (a background spawn's "Agent
/// spawned in background..." message, a denied/blocked call, or any other
/// tool's output). `spawnChildAgent` (agent_runtime.zig) always embeds the
/// child's real final text after a "\n---\n" marker in its enriched output
/// -- this recovers exactly that, never a guess. Borrows from `output_text`.
fn extractSubagentFinalText(output_text: []const u8) ?[]const u8 {
    const marker = "\n---\n";
    const idx = std.mem.indexOf(u8, output_text, marker) orelse return null;
    const text = output_text[idx + marker.len ..];
    if (text.len == 0) return null;
    return text;
}

/// headless-sdk-14 (`--forward-subagent-text`): forward a completed Agent/
/// subagent tool call's own REAL prompt (as a `user` line) and REAL final
/// text (as an `assistant` line), both tagged `parent_tool_use_id = ev.
/// tool_use_id` -- in addition to (not instead of) the normal tool_use/
/// tool_result pair the caller already emitted for `ev`. A no-op for every
/// non-Agent tool, and a no-op whenever the expected shape isn't present
/// (background spawn, denied call): nothing here is ever fabricated.
///
/// Honest, documented scope limit: only the subagent's own PROMPT and FINAL
/// text are forwarded -- not its extended-thinking text, and not each of its
/// own intermediate rounds. zcode's turn loop does not carry a subagent's
/// per-round text or reasoning_text back out through its ToolTrace today (the
/// reference's own "thinking blocks" half of this flag is not yet wired).
fn maybeForwardSubagentText(
    allocator: std.mem.Allocator,
    writer: anytype,
    session_id: []const u8,
    forward_enabled: bool,
    ev: ToolEvent,
) !void {
    if (!forward_enabled) return;
    if (!isAgentToolName(ev.name)) return;

    if (try extractJsonStringField(allocator, ev.input_json, "prompt")) |prompt_text| {
        defer allocator.free(prompt_text);
        const u_uuid = try uuid_mod.allocV4(allocator);
        defer allocator.free(u_uuid);
        const line = try output.serializeForwardedUserText(allocator, prompt_text, ev.tool_use_id, session_id, u_uuid);
        defer allocator.free(line);
        try writer.writeAll(line);
    }

    if (extractSubagentFinalText(ev.output_text)) |final_text| {
        const a_uuid = try uuid_mod.allocV4(allocator);
        defer allocator.free(a_uuid);
        const line = try output.serializeAssistant(allocator, .{
            .session_id = session_id,
            .uuid = a_uuid,
            .parent_tool_use_id = ev.tool_use_id,
            .content = &.{.{ .text = final_text }},
        });
        defer allocator.free(line);
        try writer.writeAll(line);
    }
}

/// Build the `result.permission_denials` entries out of a turn's tool events
/// (headless-sdk-07). The returned slice borrows `tool_name`/`tool_use_id`/
/// `tool_input_json` from `events` -- it must not outlive them.
fn buildPermissionDenials(
    allocator: std.mem.Allocator,
    events: []const ToolEvent,
) ![]output.PermissionDenial {
    var out: std.ArrayList(output.PermissionDenial) = .empty;
    errdefer out.deinit(allocator);
    for (events) |e| {
        if (!e.denied) continue;
        try out.append(allocator, .{
            .tool_name = e.name,
            .tool_use_id = e.tool_use_id,
            .tool_input_json = e.input_json,
        });
    }
    return out.toOwnedSlice(allocator);
}

/// headless-sdk-15 (`--prompt-suggestions`): a genuine, deterministic guess at
/// the user's next prompt, derived from what actually happened in the turn
/// that just finished -- never a fixed placeholder repeated regardless of
/// input. This is a text heuristic, not an extra model call (see
/// `output.serializePromptSuggestion`'s doc comment on why a full prediction
/// call was judged not worth shipping half-built): it reads the turn's real
/// tool events and final text, in priority order:
///
///   1. Any tool call failed -> ask to fix the error.
///   2. Any tool call touched a file (Write/Edit/MultiEdit/NotebookEdit,
///      via the same `approval_mod.isEditTool` classifier the permission
///      gate itself uses) -> ask to verify the change.
///   3. Any other tool ran (a read, a shell command, ...) -> ask what's next.
///   4. The assistant's own final text reads as a question (ends in "?")
///      -> answer it in the affirmative.
///   5. Otherwise -> a generic "what's next" fallback.
fn derivePromptSuggestion(result_text: []const u8, tool_events: []const ToolEvent) []const u8 {
    for (tool_events) |ev| {
        if (ev.is_error) return "Can you fix the error from the last command and try again?";
    }
    for (tool_events) |ev| {
        if (approval_mod.isEditTool(ev.name)) return "Can you run the tests to confirm that change works?";
    }
    if (tool_events.len > 0) return "What should we do next?";
    const trimmed = std.mem.trim(u8, result_text, " \t\r\n");
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '?') return "Yes, please go ahead.";
    return "What should we do next?";
}

/// Build the `prompt_suggestion` NDJSON line for the turn that just finished,
/// or `null` when `enabled` is false (the common case -- the flag defaults
/// off). Shared by both the one-shot `runOutput` path and the persistent
/// `StreamSession` path so the heuristic and wire format stay in one place.
/// Caller frees the returned slice.
fn buildPromptSuggestionLine(
    allocator: std.mem.Allocator,
    enabled: bool,
    session_id: []const u8,
    result_text: []const u8,
    tool_events: []const ToolEvent,
) !?[]u8 {
    if (!enabled) return null;
    const suggestion = derivePromptSuggestion(result_text, tool_events);
    const line_uuid = try uuid_mod.allocV4(allocator);
    defer allocator.free(line_uuid);
    return try output.serializePromptSuggestion(allocator, suggestion, session_id, line_uuid);
}

/// The full outcome of one headless turn: the SDK `result` shape plus the
/// per-tool-call events a stream-json caller replays as `tool_use`/
/// `tool_result` message pairs before the final result line.
const TurnOutcome = struct {
    result: output.Result,
    tool_events: []ToolEvent,

    fn deinit(self: *TurnOutcome, allocator: std.mem.Allocator) void {
        freeResult(allocator, &self.result);
        freeToolEvents(allocator, self.tool_events);
    }
};

/// Run exactly one headless turn against a freshly-built runtime and map the
/// outcome to an SDK `result` plus its per-tool-call events. The returned
/// struct is freed with `TurnOutcome.deinit`. `relay` (when non-null) is
/// installed as the runtime's `sdk_relay` so tool-permission decisions are
/// relayed to the host instead of auto-denied; the relay's `pending_*` fields
/// are refreshed before the turn so its `can_use_tool` requests carry context.
///
/// This is the single-turn core shared by all three live paths; the stream-json
/// input loop calls it once per `user` message.
fn runTurn(
    rc: RunContext,
    prompt: []const u8,
    relay: ?agent_runtime.ApprovalHandler,
) !TurnOutcome {
    const allocator = rc.allocator;
    var runtime = try AgentRuntime.init(
        allocator,
        rc.cwd,
        rc.cfg,
        rc.policy,
        rc.audit,
        rc.store,
        rc.mcp,
        rc.browser,
        false,
        rc.auto_approve_high,
        rc.strict,
        rc.yolo_mode,
    );
    defer runtime.deinit();
    prompt_sections.setGlobal(&runtime.prompt_sections_registry);

    // Install the host relay (can_use_tool) ahead of the local gate. With it
    // set, agent_tools.effectiveApproval routes every permission decision to
    // the relay even though the session is non-interactive.
    runtime.sdk_relay = relay;

    // headless-sdk-02: --session-id overrides whatever store.createSessionId()
    // minted, mirroring the exact reassignment pattern the resume path already
    // uses (initFromLoaded, ~line 1007-1009: free the old owned session_id,
    // dupe the new one in).
    if (rc.caps.session_id_override) |sid| {
        allocator.free(runtime.session_id);
        runtime.session_id = try allocator.dupe(u8, sid);
    }

    if (rc.caps.max_turns) |mt| runtime.max_tool_rounds_override = mt;
    if (rc.caps.max_thinking_tokens) |tk| runtime.setReasoningTokens(@intCast(tk));
    if (rc.caps.json_schema) |schema| {
        runtime.pending_response_schema = try allocator.dupe(u8, schema);
    }

    if (rc.initial_agent) |agent_name| {
        const activation = try runtime.activateAgentByNameStrict(agent_name);
        defer allocator.free(activation);
    }

    var result = try runtime.handlePromptDetailed(prompt);
    defer result.deinit(allocator);

    // headless-sdk-07/missed-182: map the completed tool traces BEFORE
    // `result` is freed above, so the ToolEvents own their own copies.
    const tool_events = try buildToolEvents(allocator, runtime.session_id, result.tool_traces);
    errdefer freeToolEvents(allocator, tool_events);

    var subtype: output.ResultSubtype = .success;
    var stop_reason: []const u8 = "end_turn";
    if (rc.caps.max_turns) |mt| {
        if (result.rounds >= mt) {
            subtype = .error_max_turns;
            stop_reason = "max_turns";
        }
    }

    const usage = blk: {
        runtime.token_status_lock.lock(rt.io) catch {};
        defer runtime.token_status_lock.unlock(rt.io);
        break :blk output.Usage{
            .input_tokens = runtime.token_status.total_input_tokens,
            .output_tokens = runtime.token_status.total_output_tokens,
        };
    };

    const est_cost = cost_mod.estimateCost(
        runtime.active_provider,
        runtime.active_model,
        usage.input_tokens,
        usage.output_tokens,
    );
    if (subtype == .success) {
        if (rc.caps.max_budget_usd) |budget| {
            if (est_cost > budget) {
                subtype = .error_max_budget_usd;
                stop_reason = "max_budget_usd";
            }
        }
    }

    if (rc.caps.no_session_persistence) removeSessionFile(rc, runtime.session_id);

    return .{
        .result = .{
            .subtype = subtype,
            .session_id = try allocator.dupe(u8, runtime.session_id),
            .result_text = try allocator.dupe(u8, result.final_text),
            .num_turns = result.rounds,
            .total_cost_usd = est_cost,
            .usage = usage,
            .model = try allocator.dupe(u8, runtime.active_model),
            .stop_reason = stop_reason,
            .structured_output_json = if (rc.caps.json_schema) |s| try allocator.dupe(u8, s) else "",
            .uuid = try uuid_mod.allocV4(allocator),
            .final_thinking = if (result.final_thinking) |t| try allocator.dupe(u8, t) else "",
        },
        .tool_events = tool_events,
    };
}

/// Free the allocator-owned fields of a result returned by runTurn.
pub fn freeResult(allocator: std.mem.Allocator, result: *output.Result) void {
    allocator.free(result.session_id);
    allocator.free(result.result_text);
    allocator.free(result.model);
    if (result.structured_output_json.len > 0) allocator.free(result.structured_output_json);
    if (result.uuid.len > 0) allocator.free(result.uuid);
    if (result.final_thinking.len > 0) allocator.free(result.final_thinking);
}

/// headless-sdk-02 (`--no-session-persistence`): remove the on-disk session
/// file (and its `.origin` sidecar -- see `removeSessionArtifacts`) for
/// `session_id` so the run leaves nothing behind. This is a best-effort
/// write-then-remove -- the actual per-turn append happens deep inside
/// agent_history.zig (outside this package's ownership), so "persistence"
/// cannot be prevented at the source without a larger cross-package change.
/// Deleting the files once the turn is done achieves the reference's
/// observable contract (`--no-session-persistence ... sessions will not be
/// saved to disk and cannot be resumed`) all the same. A missing file
/// (nothing was ever written, e.g. an error before the first append) or any
/// other filesystem error is silently ignored -- this is strictly a
/// best-effort cleanup, never a reason to fail the turn that already ran.
fn removeSessionFile(rc: RunContext, session_id: []const u8) void {
    removeSessionArtifacts(rc.allocator, rc.store, session_id);
}

/// headless-sdk-02: shared implementation of the on-disk cleanup above,
/// exposed as a free function (rather than only the `RunContext`-shaped
/// `removeSessionFile`) so the LEGACY, non-SDK-transport `--print`/`run`/
/// `exec` path in main.zig -- which never builds a `RunContext` -- can honor
/// `--no-session-persistence` too instead of silently ignoring it (the flag
/// used to be a no-op for a plain-text `--print "hi"` with no
/// `--output-format json|stream-json`, since that path never reached
/// `runOutput`/`removeSessionFile` at all).
///
/// Removes both the `<id>.jsonl` transcript AND the `<id>.origin` breadcrumb
/// sidecar (`session/store.zig`'s `sidecarPath` derives the latter by
/// stripping the `.jsonl` suffix off `sessionPath()`'s result and appending
/// `.origin`; that derivation is duplicated here rather than exposing
/// `sidecarPath` itself, since store.zig is owned by wp7 and this needs no
/// new surface there). Leaving the `.origin` sidecar behind after deleting
/// the transcript would still let a picker/resume flow discover the session
/// existed, which defeats "leaves no session file behind".
pub fn removeSessionArtifacts(allocator: std.mem.Allocator, store: *session_store.Store, session_id: []const u8) void {
    const path = store.sessionPath(session_id) catch return;
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(rt.io, path) catch {};

    if (std.mem.endsWith(u8, path, ".jsonl")) {
        const base = path[0 .. path.len - ".jsonl".len];
        const origin_path = std.fmt.allocPrint(allocator, "{s}.origin", .{base}) catch return;
        defer allocator.free(origin_path);
        std.Io.Dir.cwd().deleteFile(rt.io, origin_path) catch {};
    }
}

/// Credential source for `system:init.apiKeySource` (headless-sdk-03), mapped
/// to the reference's 9-value enum. zcode does not track a rich per-provider
/// credential-source taxonomy (managed key / org / temporary / oauth) today,
/// so this is a conservative two-way check: an ANTHROPIC_API_KEY env var (the
/// most common real path) vs "none" (the honest default -- e.g. the mock
/// provider, or any other credential path zcode does not yet distinguish).
fn apiKeySource() []const u8 {
    if (env_mod.getenv("ANTHROPIC_API_KEY")) |v| {
        if (v.len > 0) return "ANTHROPIC_API_KEY";
    }
    return "none";
}

/// headless-sdk-missed-185 (`--enable-auth-status`): emit a real `auth_status`
/// message once at session start (stream-json output only), reflecting the
/// session's ACTUAL resolved credential state (`apiKeySource()` above -- the
/// exact same check `system:init.apiKeySource` uses, never a fabrication).
///
/// Scope, stated honestly: this is NOT the reference's full "live OAuth
/// device-code progress" story (`isAuthenticating` transitioning true->false
/// mid-session) -- zcode's headless `--print` path has no interactive
/// auth-flow concept to report progress FROM in the first place (`zcode
/// login`'s OAuth/API-key flows are a wholly separate, always-interactive
/// subcommand, never combined with `--print`/`--output-format`). What IS
/// real and newly wired: a host that sets `--enable-auth-status` now
/// actually receives a genuine `auth_status` message for every headless run
/// instead of the flag being accepted and then producing no observable
/// message at all, regardless of the flag, forever.
fn maybeEmitAuthStatus(allocator: std.mem.Allocator, enabled: bool, session_id: []const u8, writer: anytype) !void {
    if (!enabled) return;
    const source = apiKeySource();
    const line_text = if (std.mem.eql(u8, source, "none"))
        "no credentials configured (apiKeySource=none)"
    else
        try std.fmt.allocPrint(allocator, "authenticated via {s}", .{source});
    defer if (!std.mem.eql(u8, source, "none")) allocator.free(line_text);

    const line_uuid = try uuid_mod.allocV4(allocator);
    defer allocator.free(line_uuid);
    const line = try output.serializeAuthStatus(allocator, false, &.{line_text}, "", session_id, line_uuid);
    defer allocator.free(line);
    try writer.writeAll(line);
}

/// Scratch storage for everything `buildInitInfo` gathers from live registries
/// (MCP servers, plugins, tool names, a fresh uuid). The returned `InitInfo`
/// borrows from these buffers, so they must outlive it; `deinit` frees
/// everything once the init line has been serialized.
const InitBuf = struct {
    tools: std.ArrayList([]const u8) = .empty,
    mcp_servers: std.ArrayList(output.McpServerInfo) = .empty,
    plugins: std.ArrayList(output.PluginInfo) = .empty,
    server_list: []mcp_client.Server = &.{},
    plugin_specs: []plugins_mod.PluginSpec = &.{},
    uuid: []u8 = &.{},

    fn deinit(self: *InitBuf, allocator: std.mem.Allocator) void {
        self.tools.deinit(allocator);
        self.mcp_servers.deinit(allocator);
        self.plugins.deinit(allocator);
        if (self.server_list.len > 0) mcp_client.freeServers(allocator, self.server_list);
        for (self.plugin_specs) |*p| p.deinit(allocator);
        if (self.plugin_specs.len > 0) allocator.free(self.plugin_specs);
        if (self.uuid.len > 0) allocator.free(self.uuid);
    }
};

/// Build the `system:init` info for a session: the always-loaded tool names,
/// the real MCP server list with live connection status (headless-sdk-10/18),
/// the installed plugin list (headless-sdk-10), the credential source and
/// active output style (headless-sdk-03), and a fresh per-init uuid
/// (headless-sdk-03). The returned InitInfo borrows from `buf` and from the
/// caller's owned strings (model / permission_mode / session_id); both must
/// outlive it. `sdk_agents` carries any agent names an `initialize`
/// control_request registered this session (missed-183); empty otherwise.
/// headless-sdk-18: resolve a configured MCP server's REAL status for
/// system:init / mcp_status -- "connected" (already has a live session, or a
/// fresh connect attempt just succeeded) or "failed" (a fresh attempt just
/// failed). Actively probes (via `listTools`, a real MCP `initialize`
/// handshake) when there is no live session yet, so a healthy server can
/// report "connected" and a genuinely unreachable one "failed" instead of
/// the CLI never having tried anything and reporting "pending" for every
/// server on every run -- "pending" was previously the ONLY value any
/// invocation could ever produce, which defeated the whole point of a
/// status field. Bounded by the client's own connection timeout
/// (`MCP_TIMEOUT`, default 30s) per unconnected server, same cost the
/// reference itself pays to know a server's real status before reporting it.
fn mcpServerStatus(mcp: *mcp_client.Client, allocator: std.mem.Allocator, name: []const u8) []const u8 {
    if (mcp.isConnected(name)) return "connected";
    if (mcp.listTools(name)) |tools| {
        mcp_client.freeToolInfos(allocator, tools);
        return "connected";
    } else |_| {
        return "failed";
    }
}

pub fn buildInitInfo(
    rc: RunContext,
    buf: *InitBuf,
    session_id: []const u8,
    model: []const u8,
    permission_mode: []const u8,
    sdk_agents: []const []const u8,
) !output.InitInfo {
    const allocator = rc.allocator;
    for (tool_schemas.ALWAYS_LOADED_TOOL_NAMES) |name| {
        try buf.tools.append(allocator, name);
    }

    buf.server_list = rc.mcp.list() catch &.{};
    for (buf.server_list) |s| {
        const status = mcpServerStatus(rc.mcp, allocator, s.name);
        try buf.mcp_servers.append(allocator, .{ .name = s.name, .status = status });
    }

    buf.plugin_specs = plugins_mod.list(allocator, rc.cwd) catch &.{};
    for (buf.plugin_specs) |p| {
        try buf.plugins.append(allocator, .{
            .name = p.name,
            .path = p.root_path,
            .source = switch (p.scope) {
                .user => "user",
                .workspace => "project",
            },
            .version = p.version,
        });
    }

    buf.uuid = try uuid_mod.allocV4(allocator);

    return messages.buildInit(.{
        .session_id = session_id,
        .model = model,
        .permission_mode = permission_mode,
        .cwd = rc.cwd,
        .claude_code_version = build_options.app_version,
        .tools = buf.tools.items,
        .mcp_servers = buf.mcp_servers.items,
        .plugins = buf.plugins.items,
        .api_key_source = apiKeySource(),
        .output_style = rc.cfg.output_style,
        .agents = sdk_agents,
        .uuid = buf.uuid,
    });
}

/// The `permissionMode` label for `system:init`/`result` (headless-sdk-04):
/// always one of the reference's 6 values (default/acceptEdits/
/// bypassPermissions/plan/dontAsk/auto), never zcode's own
/// tiered-auto/manual/strict vocabulary. A live `set_permission_mode`
/// override (already a reference-spelled `permission_decision.Mode`) wins;
/// otherwise the static config mode is mapped to its closest reference
/// counterpart by ACTUAL src/core/approval.zig gate behavior in a
/// non-interactive (headless/SDK) run -- the only context this label is ever
/// observed in -- rather than by name similarity:
///
///   - tiered-auto auto-allows LOW and MEDIUM, only asking (or, headless,
///     denying) above that -- the least restrictive of zcode's three modes,
///     so it maps to the reference's own baseline, "default".
///   - strict auto-allows only LOW; MEDIUM/HIGH prompt when interactive and
///     are flatly denied when not (`evaluate()`'s "strict mode requires
///     explicit approval" branch) -- it never runs anything unprompted above
///     LOW, so headlessly it behaves exactly like the reference's "dontAsk"
///     ("deny if not pre-approved, don't prompt"), NOT "bypassPermissions"
///     (the reference's least restrictive mode, which skips checks
///     entirely). Mapping strict -> bypassPermissions was inverted: it told
///     an SDK host gauging session risk that zcode's most locked-down mode
///     was its most permissive one.
///   - manual prompts for literally everything regardless of tier and, when
///     it cannot prompt (headless), denies literally everything including
///     LOW -- strictly MORE restrictive than strict, so it must not collapse
///     onto strict's "dontAsk" (which still auto-allows LOW) or, worse, land
///     on "bypassPermissions". No reference mode models "never auto-allow
///     anything"; "plan" (auto-allow only LOW, deny the rest, never prompt)
///     is the closest available and, thematically, both modes mean "nothing
///     proceeds without explicit approval first".
fn permissionModeLabel(cfg: *const config_mod.Config, live_override: ?permission_decision_mod.Mode) []const u8 {
    if (live_override) |mode| return permission_decision_mod.modeToString(mode);
    if (std.mem.eql(u8, cfg.approval_mode, "manual")) return "plan";
    if (std.mem.eql(u8, cfg.approval_mode, "strict")) return "dontAsk";
    return "default"; // tiered-auto, and any other/unknown legacy spelling.
}

test "headless-sdk-04: permissionModeLabel maps by actual restrictiveness, never inverted" {
    const alloc = testing.allocator;
    var cfg = try config_mod.Config.init(alloc);
    defer cfg.deinit(alloc);

    // tiered-auto: auto-allows LOW+MEDIUM (least restrictive of zcode's 3
    // modes) -> the reference's baseline "default".
    alloc.free(cfg.approval_mode);
    cfg.approval_mode = try alloc.dupe(u8, "tiered-auto");
    try testing.expectEqualStrings("default", permissionModeLabel(&cfg, null));

    // strict: auto-allows only LOW, denies (headless) everything above it --
    // must land on "dontAsk" ("deny if not pre-approved, don't prompt"), NOT
    // "bypassPermissions" (the reference's LEAST restrictive mode). Mapping
    // strict -> bypassPermissions was the exact inversion this test guards.
    alloc.free(cfg.approval_mode);
    cfg.approval_mode = try alloc.dupe(u8, "strict");
    try testing.expectEqualStrings("dontAsk", permissionModeLabel(&cfg, null));
    try testing.expect(!std.mem.eql(u8, permissionModeLabel(&cfg, null), "bypassPermissions"));

    // manual: prompts for literally everything and, headless, denies
    // literally everything (including LOW) -- strictly MORE restrictive than
    // strict, so it must not collapse onto strict's "dontAsk" (which still
    // auto-allows LOW) nor render as "bypassPermissions".
    alloc.free(cfg.approval_mode);
    cfg.approval_mode = try alloc.dupe(u8, "manual");
    const manual_label = permissionModeLabel(&cfg, null);
    try testing.expect(!std.mem.eql(u8, manual_label, "bypassPermissions"));
    try testing.expect(!std.mem.eql(u8, manual_label, "dontAsk"));
    try testing.expectEqualStrings("plan", manual_label);

    // A live `set_permission_mode` override always wins over the static
    // fallback, and now correctly reaches `.auto` too (permission_decision's
    // `auto` variant is no longer folded into `.default`).
    try testing.expectEqualStrings("auto", permissionModeLabel(&cfg, .auto));
    try testing.expectEqualStrings("bypassPermissions", permissionModeLabel(&cfg, .bypassPermissions));
}

// ---------------------------------------------------------------------------
// Path 1+2: output-format json / stream-json (text input).
// ---------------------------------------------------------------------------

/// Run one headless turn and emit the SDK-shaped output to `writer` per the
/// resolved output format:
///   - .json        : a single `result` object line.
///   - .stream_json : a `system:init` line then the `result` line.
/// (.text is never routed here -- the caller keeps the legacy path.)
///
/// `writer` is duck-typed: any value exposing `writeAll([]const u8) !void`
/// (the real std_io stdout writer, a stdout-guard adapter, or an in-memory
/// capture). The caller is responsible for the verbose gate
/// (validateVerboseGate) before calling, and for wrapping `writer` in the
/// stdout guard when the format is stream-json.
pub fn runOutput(
    rc: RunContext,
    format: output.OutputFormat,
    prompt: []const u8,
    writer: anytype,
) !void {
    const allocator = rc.allocator;
    var outcome = try runTurn(rc, prompt, null);
    defer outcome.deinit(allocator);
    const result = &outcome.result;

    const denials = try buildPermissionDenials(allocator, outcome.tool_events);
    defer allocator.free(denials);

    switch (format) {
        .text => unreachable, // text never reaches this module
        .json => {
            const line = try output.serializeResult(allocator, result.*, denials);
            defer allocator.free(line);
            try writer.writeAll(line);
        },
        .stream_json => {
            var buf: InitBuf = .{};
            defer buf.deinit(allocator);
            const info = try buildInitInfo(
                rc,
                &buf,
                result.session_id,
                result.model,
                permissionModeLabel(rc.cfg, null),
                &.{},
            );
            const init_line = try output.serializeInit(allocator, info);
            defer allocator.free(init_line);
            try writer.writeAll(init_line);

            // headless-sdk-missed-185: --enable-auth-status emits a real
            // auth_status line right after init (a no-op when the hidden
            // flag is off, which is the default).
            try maybeEmitAuthStatus(allocator, rc.caps.enable_auth_status, result.session_id, writer);

            // Emit each completed tool call as a tool_use/tool_result pair
            // BEFORE the final text, matching the reference's per-call
            // interleaving (missed-182). zcode's turn loop is synchronous
            // batch (see the module doc), so these are emitted once the turn
            // has finished rather than truly live mid-turn -- but every block
            // reflects a real dispatched call, never a fabrication.
            for (outcome.tool_events) |ev| {
                const tu_uuid = try uuid_mod.allocV4(allocator);
                defer allocator.free(tu_uuid);
                const tool_use_line = try output.serializeAssistant(allocator, .{
                    .session_id = result.session_id,
                    .uuid = tu_uuid,
                    .model = result.model,
                    .content = &.{.{ .tool_use = .{ .id = ev.tool_use_id, .name = ev.name, .input_json = ev.input_json } }},
                });
                defer allocator.free(tool_use_line);
                try writer.writeAll(tool_use_line);

                const tr_uuid = try uuid_mod.allocV4(allocator);
                defer allocator.free(tr_uuid);
                const tool_result_line = try output.serializeUserToolResult(
                    allocator,
                    result.session_id,
                    ev.tool_use_id,
                    ev.output_text,
                    ev.is_error,
                    tr_uuid,
                );
                defer allocator.free(tool_result_line);
                try writer.writeAll(tool_result_line);

                try maybeForwardSubagentText(allocator, writer, result.session_id, rc.caps.forward_subagent_text, ev);
            }

            // The final assistant text message: this is the only assistant
            // event that carries model/stop_reason/usage (headless-sdk-08).
            const msg_uuid = try uuid_mod.allocV4(allocator);
            defer allocator.free(msg_uuid);
            // headless-sdk-missed-184: a real thinking block, when the model
            // returned one, precedes the text block -- matching the
            // reference's Messages API content ordering for extended
            // thinking. Never emitted when final_thinking is empty.
            var content_buf: [2]output.ContentBlock = undefined;
            var content_len: usize = 0;
            if (result.final_thinking.len > 0) {
                content_buf[content_len] = .{ .thinking = result.final_thinking };
                content_len += 1;
            }
            content_buf[content_len] = .{ .text = result.result_text };
            content_len += 1;
            const assistant_line = try output.serializeAssistant(allocator, .{
                .session_id = result.session_id,
                .uuid = msg_uuid,
                .model = result.model,
                .stop_reason = result.stop_reason,
                .usage = result.usage,
                .content = content_buf[0..content_len],
            });
            defer allocator.free(assistant_line);
            try writer.writeAll(assistant_line);

            const result_line = try output.serializeResult(allocator, result.*, denials);
            defer allocator.free(result_line);
            try writer.writeAll(result_line);

            // headless-sdk-15: --prompt-suggestions emits a prompt_suggestion
            // line after the result line for the turn (a no-op when the flag
            // is off, which is the default).
            if (try buildPromptSuggestionLine(allocator, rc.caps.prompt_suggestions, result.session_id, result.result_text, outcome.tool_events)) |suggestion_line| {
                defer allocator.free(suggestion_line);
                try writer.writeAll(suggestion_line);
            }
        },
    }
}

// ---------------------------------------------------------------------------
// Path 3: input-format stream-json (the control pump).
// ---------------------------------------------------------------------------

/// The state threaded through the stream-json input loop. Owns the per-session
/// runtime knobs the control subtypes mutate, the writer the relay/control
/// responses go out on, and the reader the relay block-reads host responses
/// from. One of these lives for the whole stream-json session.
///
/// `reader`/`writer` are kept as `anytype`-erased function pointers via the
/// concrete types the caller supplies; to stay test-drivable we store them as
/// opaque pointers plus thin call shims. In practice the caller is either
/// main.zig (real std_io) or a test (in-memory pipes).
pub fn StreamSession(comptime Reader: type, comptime Writer: type) type {
    return struct {
        const Self = @This();

        rc: RunContext,
        reader: Reader,
        writer: Writer,
        /// The live runtime for the session. Built once on the first `user`
        /// turn and reused across turns so live-control mutations (set_model,
        /// set_permission_mode, interrupt) persist. Null until the first turn.
        runtime: ?*AgentRuntime = null,
        init_state: structured_io.InitState = .{},
        /// Whether a system:init line has been emitted yet (stream-json output).
        emitted_init: bool = false,
        /// The output format for emitted SDK messages (json or stream-json).
        out_format: output.OutputFormat,
        /// Re-emit accepted user messages (--replay-user-messages).
        replay_user_messages: bool = false,
        /// Scratch buffer holding the most recent turn's final text (duped so it
        /// outlives the TurnResult). Freed on the next turn and on deinit.
        last_text: []u8 = &.{},
        /// headless-sdk-missed-184: scratch buffer holding the most recent
        /// turn's extended-thinking text (duped so it outlives the
        /// TurnResult), or empty when the turn had none. Freed on the next
        /// turn and on deinit, same lifetime discipline as `last_text`.
        last_thinking: []u8 = &.{},
        /// The most recent turn's mapped tool events (headless-sdk-07/
        /// missed-182), owned. Freed on the next turn and on deinit.
        last_tool_events: []ToolEvent = &.{},
        /// A fresh UUIDv4 for the most recent result line, owned. Freed on the
        /// next turn and on deinit (headless-sdk-05/06).
        last_result_uuid: []u8 = &.{},
        /// headless-sdk-01: the structured can_use_tool relay, built alongside
        /// `runtime` in `ensureRuntime`. Carries the REAL tool_name/input the
        /// runtime's single dispatch call site stamps via `setPendingCb`
        /// before the gate ever calls `promptCb`.
        relay_approver: ?structured_io.RelayApprover = null,
        /// SDK-registered agent names from an `initialize` control_request's
        /// `agents` field (missed-183), owned. Surfaced in the init line's
        /// `agents` array; empty until/unless a host registers any.
        sdk_agent_names: [][]u8 = &.{},
        /// SDK-hosted MCP server names from an `initialize` control_request's
        /// `sdkMcpServers` field (missed-183), owned. Not currently surfaced
        /// anywhere (no SDK-hosted-MCP-server concept exists in zcode yet;
        /// see headless-sdk-11) -- stored so registering one is at least
        /// visible/inspectable rather than a silent no-op.
        sdk_mcp_server_names: [][]u8 = &.{},
        /// A structured-output schema override from an `initialize`
        /// control_request's `jsonSchema` field (missed-183), owned. Applied
        /// to `runtime.pending_response_schema` -- immediately if the runtime
        /// already exists, otherwise on the next `ensureRuntime` build.
        sdk_json_schema: ?[]u8 = null,
        /// Whether an `initialize` control_request's `promptSuggestions` field
        /// was set to true (missed-183). Consumed alongside the
        /// `--prompt-suggestions` CLI flag (headless-sdk-15) in `onUser`: a
        /// `prompt_suggestion` line is emitted after each turn's result when
        /// EITHER is set.
        sdk_prompt_suggestions_enabled: bool = false,
        /// headless-sdk-16: the skill/command names observed after the most
        /// recent turn, sorted, owned. Compared against the fresh snapshot
        /// taken after each subsequent turn (`maybeEmitCommandsChanged`) --
        /// a real, working "mid-session change" detector (e.g. the agent
        /// `cd`s into a subdirectory with its own `.claude/skills`, or a
        /// Write/Edit tool call adds a new skill file), not a guess. Empty
        /// (not yet observed) until the first turn completes; the first
        /// observation only seeds the baseline, it never emits (there is no
        /// "previous" list to have changed from).
        known_command_names: [][]u8 = &.{},
        /// True once `known_command_names` reflects a real prior
        /// observation. Distinguishes "haven't looked yet" from "looked,
        /// and there were zero skills" -- both start as an empty slice, but
        /// only the latter should compare-and-emit on the next turn.
        has_command_baseline: bool = false,
        /// headless-sdk-11 (`rewind_files`): maps a client-supplied user
        /// message uuid (the same value `submitMessage options.uuid`/the
        /// inbound `user` line's top-level `uuid` would carry -- missed-186)
        /// to the history index its turn landed at, recorded once per turn
        /// in `onUser` (only when the host actually supplied a uuid; most
        /// zcode-internal turns have none to record). This is what lets a
        /// REAL SDK host's `rewind_files.user_message_id` -- necessarily the
        /// id IT assigned, not any zcode-internal id it was never shown --
        /// resolve to a real point in the conversation. Owned; freed on
        /// deinit.
        known_user_messages: std.ArrayList(UserMessageRecord) = .empty,

        pub fn init(rc: RunContext, reader: Reader, writer: Writer, out_format: output.OutputFormat) Self {
            return .{ .rc = rc, .reader = reader, .writer = writer, .out_format = out_format };
        }

        pub fn deinit(self: *Self) void {
            if (self.last_text.len > 0) {
                self.rc.allocator.free(self.last_text);
                self.last_text = &.{};
            }
            if (self.last_thinking.len > 0) {
                self.rc.allocator.free(self.last_thinking);
                self.last_thinking = &.{};
            }
            if (self.last_result_uuid.len > 0) {
                self.rc.allocator.free(self.last_result_uuid);
                self.last_result_uuid = &.{};
            }
            if (self.last_tool_events.len > 0) {
                freeToolEvents(self.rc.allocator, self.last_tool_events);
                self.last_tool_events = &.{};
            }
            freeOwnedStrings(self.rc.allocator, self.sdk_agent_names);
            self.sdk_agent_names = &.{};
            freeOwnedStrings(self.rc.allocator, self.known_command_names);
            self.known_command_names = &.{};
            freeOwnedStrings(self.rc.allocator, self.sdk_mcp_server_names);
            self.sdk_mcp_server_names = &.{};
            for (self.known_user_messages.items) |rec| self.rc.allocator.free(rec.message_uuid);
            self.known_user_messages.deinit(self.rc.allocator);
            if (self.sdk_json_schema) |s| {
                self.rc.allocator.free(s);
                self.sdk_json_schema = null;
            }
            if (self.relay_approver) |*ra| ra.deinit();
            if (self.runtime) |runtime| {
                // headless-sdk-02: remove the whole session's file at session
                // end (not per-turn -- a multi-turn session keeps writing to
                // the same file across turns).
                if (self.rc.caps.no_session_persistence) removeSessionFile(self.rc, runtime.session_id);
                runtime.deinit();
                self.rc.allocator.destroy(runtime);
                self.runtime = null;
            }
        }

        /// Lazily build the per-session runtime on the first turn and install the
        /// can_use_tool relay (its dispatcher block-reads host responses through
        /// `self`). Returns the live runtime.
        fn ensureRuntime(self: *Self) !*AgentRuntime {
            if (self.runtime) |runtime| return runtime;
            const allocator = self.rc.allocator;
            self.relay_approver = structured_io.RelayApprover.init(allocator, .{
                .ctx = @ptrCast(self),
                .requestFn = dispatchCanUseTool,
            });
            const runtime = try allocator.create(AgentRuntime);
            errdefer allocator.destroy(runtime);
            runtime.* = try AgentRuntime.init(
                allocator,
                self.rc.cwd,
                self.rc.cfg,
                self.rc.policy,
                self.rc.audit,
                self.rc.store,
                self.rc.mcp,
                self.rc.browser,
                false,
                self.rc.auto_approve_high,
                self.rc.strict,
                self.rc.yolo_mode,
            );
            prompt_sections.setGlobal(&runtime.prompt_sections_registry);
            // headless-sdk-02: --session-id overrides whatever
            // store.createSessionId() minted.
            if (self.rc.caps.session_id_override) |sid| {
                allocator.free(runtime.session_id);
                runtime.session_id = try allocator.dupe(u8, sid);
            }
            if (self.rc.caps.max_turns) |mt| runtime.max_tool_rounds_override = mt;
            if (self.rc.caps.max_thinking_tokens) |tk| runtime.setReasoningTokens(@intCast(tk));
            if (self.rc.caps.json_schema) |schema| {
                runtime.pending_response_schema = try allocator.dupe(u8, schema);
            }
            // missed-183: an `initialize` control_request may have set a schema
            // override before this first turn built the runtime; it wins over
            // the CLI-flag default above.
            if (self.sdk_json_schema) |schema| {
                if (runtime.pending_response_schema) |old| allocator.free(old);
                runtime.pending_response_schema = try allocator.dupe(u8, schema);
            }
            // Install the structured relay (headless-sdk-01): the gate calls
            // RelayApprover.promptCb on the same thread during a tool decision;
            // it emits a can_use_tool request (with the REAL tool_name/input
            // stamped by setPendingCb at the runtime's single dispatch call
            // site) and, via `dispatchCanUseTool`, block-reads the host's
            // control_response.
            runtime.sdk_relay = .{
                .ctx = @ptrCast(&self.relay_approver.?),
                .prompt = structured_io.RelayApprover.promptCb,
                .setPending = structured_io.RelayApprover.setPendingCb,
            };
            self.runtime = runtime;
            return runtime;
        }

        /// structured_io.Dispatcher.requestFn: write the can_use_tool envelope
        /// (already carrying the real tool_name/input via RelayApprover) and
        /// block-read control_request/control_response lines until the
        /// matching decision arrives.
        fn dispatchCanUseTool(ctx: *anyopaque, request_json: []const u8) anyerror!structured_io.RelayDecision {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const allocator = self.rc.allocator;

            const req_id = try genRequestId(allocator);
            defer allocator.free(req_id);
            const envelope = try control.encodeRequest(allocator, req_id, request_json);
            defer allocator.free(envelope);
            try self.writeAll(envelope);

            const decision = try self.awaitDecision(req_id);
            return switch (decision) {
                .approve, .approve_always => .allow,
                .deny => .deny,
            };
        }

        /// Block-read host lines until a control_response matching `req_id`
        /// arrives, dispatching any interleaved control_request along the way.
        /// EOF before a decision fails safe to deny.
        fn awaitDecision(self: *Self, req_id: []const u8) !types.ApprovalResponse {
            const allocator = self.rc.allocator;
            while (true) {
                const line_opt = try self.reader.readUntilDelimiterOrEofAlloc(
                    allocator,
                    '\n',
                    structured_io.LINE_CAP,
                );
                const line = line_opt orelse return .deny; // EOF: fail safe
                defer allocator.free(line);
                const trimmed = std.mem.trim(u8, line, " \t\r\n");
                if (trimmed.len == 0) continue;

                // A control_response resolves the decision when the request_id
                // matches; otherwise it is an orphan we skip.
                if (isControlResponse(trimmed)) {
                    if (matchesRequestId(trimmed, req_id)) {
                        return decisionFromResponse(trimmed);
                    }
                    continue;
                }
                // An interleaved control_request (e.g. interrupt mid-decision):
                // dispatch it so the host can steer the paused turn.
                if (isControlRequest(trimmed)) {
                    try self.handleControlRequest(trimmed);
                    continue;
                }
                // Anything else while awaiting a decision is ignored.
            }
        }

        /// Run the stream-json input loop: read NDJSON from `reader`, dispatch
        /// each line, and emit SDK output for each completed `user` turn.
        pub fn run(self: *Self) !void {
            // headless-sdk-12: --await-initialize blocks on the first stdin
            // line, requiring it to be an `initialize` control_request,
            // BEFORE anything else (including the normal dispatch loop) runs.
            if (self.rc.cfg.await_initialize) {
                try self.awaitInitializeFirstLine();
            }
            try structured_io.runDispatchLoop(self.rc.allocator, self.reader, self.writer, .{
                .ctx = @ptrCast(self),
                .on_user = onUser,
                .on_control_request = onControlRequest,
                .on_update_env = onUpdateEnv,
            });
        }

        /// headless-sdk-12: read exactly one line from `self.reader` and
        /// require it to be an `initialize` control_request, applying it via
        /// the same `handleControlRequest` path a normally-arriving
        /// initialize takes (so its side effects -- jsonSchema/
        /// promptSuggestions/agents/sdkMcpServers -- are identical either
        /// way). Errors with reference-equivalent text on EOF / malformed
        /// JSON / a different first message, printed to stderr (matching
        /// every other CLI-level validation failure in this codebase) before
        /// returning `error.AwaitInitializeFailed` so the caller's normal
        /// error propagation aborts the run without ever starting a turn.
        fn awaitInitializeFirstLine(self: *Self) !void {
            const allocator = self.rc.allocator;
            const stderr = std_io.stderrWriter();

            const line_opt = try self.reader.readUntilDelimiterOrEofAlloc(allocator, '\n', structured_io.LINE_CAP);
            const line = line_opt orelse {
                try stderr.writeAll("error: --await-initialize: stdin ended before an initialize request arrived.\n");
                return error.AwaitInitializeFailed;
            };
            defer allocator.free(line);
            const trimmed = std.mem.trim(u8, line, " \t\r\n");

            if (trimmed.len == 0) {
                try stderr.writeAll(
                    "error: --await-initialize requires the initialize control request as the first stdin line, and the first line is a different message.\n",
                );
                return error.AwaitInitializeFailed;
            }

            var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
                try stderr.writeAll(
                    "error: --await-initialize requires the initialize control request as the first stdin line, and the first line is not valid JSON.\n",
                );
                return error.AwaitInitializeFailed;
            };
            defer parsed.deinit();

            const is_initialize = blk: {
                if (parsed.value != .object) break :blk false;
                const type_val = parsed.value.object.get("type") orelse break :blk false;
                if (type_val != .string or !std.mem.eql(u8, type_val.string, "control_request")) break :blk false;
                const req_val = parsed.value.object.get("request") orelse break :blk false;
                if (req_val != .object) break :blk false;
                const subtype_val = req_val.object.get("subtype") orelse break :blk false;
                break :blk subtype_val == .string and std.mem.eql(u8, subtype_val.string, "initialize");
            };
            if (!is_initialize) {
                try stderr.writeAll(
                    "error: --await-initialize requires the initialize control request as the first stdin line, and the first line is a different message.\n",
                );
                return error.AwaitInitializeFailed;
            }

            try self.handleControlRequest(trimmed);
        }

        fn onUser(ctx: *anyopaque, prompt: []const u8, message_uuid: []const u8) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const allocator = self.rc.allocator;

            if (self.replay_user_messages) {
                const line = try output.serializeUserReplay(allocator, prompt, "");
                defer allocator.free(line);
                try self.writeAll(line);
            }

            const runtime = try self.ensureRuntime();

            // Emit system:init once (stream-json output only) before the first
            // result so the host sees the session shape.
            if (self.out_format == .stream_json and !self.emitted_init) {
                var buf: InitBuf = .{};
                defer buf.deinit(allocator);
                const info = try buildInitInfo(
                    self.rc,
                    &buf,
                    runtime.session_id,
                    runtime.active_model,
                    permissionModeLabel(self.rc.cfg, runtime.permission_mode_override),
                    self.sdk_agent_names,
                );
                const init_line = try output.serializeInit(allocator, info);
                defer allocator.free(init_line);
                try self.writeAll(init_line);
                self.emitted_init = true;

                // headless-sdk-missed-185: see the identical comment on the
                // one-shot `runOutput` path.
                try maybeEmitAuthStatus(allocator, self.rc.caps.enable_auth_status, runtime.session_id, self);
            }

            // headless-sdk-11 (`rewind_files`): remember where THIS turn's
            // own user message lands in history, keyed by the uuid the host
            // supplied on it (if any) -- see `known_user_messages`'s doc
            // comment. Captured before the turn runs so the scan below only
            // has to look at what this turn itself appended.
            const history_index_before = runtime.history.len();

            const result = try self.runTurnOnRuntime(runtime, prompt);
            const denials = try buildPermissionDenials(allocator, self.last_tool_events);
            defer allocator.free(denials);

            if (message_uuid.len > 0) {
                for (runtime.history.view()[history_index_before..], history_index_before..) |turn, idx| {
                    if (turn.role == .user) {
                        try self.known_user_messages.append(allocator, .{
                            .message_uuid = try allocator.dupe(u8, message_uuid),
                            .history_index = idx,
                        });
                        break;
                    }
                }
            }

            // Emit each completed tool call as a tool_use/tool_result pair
            // BEFORE the final text (missed-182), matching the reference's
            // per-call interleaving as closely as zcode's synchronous batch
            // turn loop allows (see the module doc): these are emitted once
            // the turn has finished, not truly live mid-turn, but every block
            // reflects a real dispatched call.
            for (self.last_tool_events) |ev| {
                const tu_uuid = try uuid_mod.allocV4(allocator);
                defer allocator.free(tu_uuid);
                const tool_use_line = try output.serializeAssistant(allocator, .{
                    .session_id = result.session_id,
                    .uuid = tu_uuid,
                    .model = result.model,
                    .content = &.{.{ .tool_use = .{ .id = ev.tool_use_id, .name = ev.name, .input_json = ev.input_json } }},
                });
                defer allocator.free(tool_use_line);
                try self.writeAll(tool_use_line);

                const tr_uuid = try uuid_mod.allocV4(allocator);
                defer allocator.free(tr_uuid);
                const tool_result_line = try output.serializeUserToolResult(
                    allocator,
                    result.session_id,
                    ev.tool_use_id,
                    ev.output_text,
                    ev.is_error,
                    tr_uuid,
                );
                defer allocator.free(tool_result_line);
                try self.writeAll(tool_result_line);

                try maybeForwardSubagentText(allocator, self, result.session_id, self.rc.caps.forward_subagent_text, ev);
            }

            // The final assistant text message: the only assistant event that
            // carries model/stop_reason/usage (headless-sdk-08), and (on the
            // turn's first reply frame) the triggering user message's own
            // uuid (missed-186).
            const msg_uuid = try uuid_mod.allocV4(allocator);
            defer allocator.free(msg_uuid);
            // headless-sdk-missed-184: see the one-shot path above -- same
            // "thinking block precedes text, only when real" rule.
            var content_buf: [2]output.ContentBlock = undefined;
            var content_len: usize = 0;
            if (result.final_thinking.len > 0) {
                content_buf[content_len] = .{ .thinking = result.final_thinking };
                content_len += 1;
            }
            content_buf[content_len] = .{ .text = result.result_text };
            content_len += 1;
            const assistant_line = try output.serializeAssistant(allocator, .{
                .session_id = result.session_id,
                .uuid = msg_uuid,
                .model = result.model,
                .stop_reason = result.stop_reason,
                .usage = result.usage,
                .user_message_uuid = message_uuid,
                .content = content_buf[0..content_len],
            });
            defer allocator.free(assistant_line);
            try self.writeAll(assistant_line);

            var result_with_uuid = result;
            result_with_uuid.user_message_uuid = message_uuid;
            const line = try output.serializeResult(allocator, result_with_uuid, denials);
            defer allocator.free(line);
            try self.writeAll(line);

            // headless-sdk-15: --prompt-suggestions (CLI flag) OR a live
            // `initialize.promptSuggestions` toggle (missed-183) emits a
            // prompt_suggestion line after the result line for this turn.
            const suggestions_enabled = self.rc.caps.prompt_suggestions or self.sdk_prompt_suggestions_enabled;
            if (try buildPromptSuggestionLine(allocator, suggestions_enabled, result.session_id, result.result_text, self.last_tool_events)) |suggestion_line| {
                defer allocator.free(suggestion_line);
                try self.writeAll(suggestion_line);
            }

            // headless-sdk-16: check for a real mid-session skill/command-list
            // change (e.g. the turn just ran `cd` into a subdirectory with its
            // own `.claude/skills`, or wrote a new skill file) after the
            // result line, per the reference's own fire-and-forget push.
            self.maybeEmitCommandsChanged(runtime.cwd, result.session_id);
        }

        /// Run one turn on the persistent runtime and map it to an SDK result.
        /// Unlike runTurn (which builds + tears down a runtime), this reuses the
        /// session runtime so live-control mutations persist across turns. The
        /// returned result borrows runtime-owned slices (session_id / model)
        /// plus the session's scratch buffers (result_text / uuid); they are
        /// stable until the next turn, and the caller serializes the result
        /// line before then. `self.last_tool_events` is refreshed too
        /// (headless-sdk-07/missed-182).
        fn runTurnOnRuntime(self: *Self, runtime: *AgentRuntime, prompt: []const u8) !output.Result {
            const allocator = self.rc.allocator;
            var tr = try runtime.handlePromptDetailed(prompt);
            defer tr.deinit(allocator);

            // Map the tool traces BEFORE `tr` frees them.
            const tool_events = try buildToolEvents(allocator, runtime.session_id, tr.tool_traces);
            if (self.last_tool_events.len > 0) freeToolEvents(allocator, self.last_tool_events);
            self.last_tool_events = tool_events;

            var subtype: output.ResultSubtype = .success;
            var stop_reason: []const u8 = "end_turn";
            if (self.rc.caps.max_turns) |mt| {
                if (tr.rounds >= mt) {
                    subtype = .error_max_turns;
                    stop_reason = "max_turns";
                }
            }
            const usage = blk: {
                runtime.token_status_lock.lock(rt.io) catch {};
                defer runtime.token_status_lock.unlock(rt.io);
                break :blk output.Usage{
                    .input_tokens = runtime.token_status.total_input_tokens,
                    .output_tokens = runtime.token_status.total_output_tokens,
                };
            };
            const est_cost = cost_mod.estimateCost(
                runtime.active_provider,
                runtime.active_model,
                usage.input_tokens,
                usage.output_tokens,
            );
            // `tr.final_text` is freed when `tr` deinits at the end of this call,
            // so dupe it into the session scratch buffer (freed on the next turn
            // / on deinit). The returned result borrows it plus the
            // runtime-owned session_id/model, all valid until the caller has
            // serialized the result line.
            if (self.last_text.len > 0) allocator.free(self.last_text);
            self.last_text = try allocator.dupe(u8, tr.final_text);
            // headless-sdk-missed-184: same lifetime discipline as last_text
            // above -- tr.final_thinking is freed when tr deinits.
            if (self.last_thinking.len > 0) allocator.free(self.last_thinking);
            self.last_thinking = if (tr.final_thinking) |t| try allocator.dupe(u8, t) else &.{};
            if (self.last_result_uuid.len > 0) allocator.free(self.last_result_uuid);
            self.last_result_uuid = try uuid_mod.allocV4(allocator);
            return .{
                .subtype = subtype,
                .session_id = runtime.session_id,
                .result_text = self.last_text,
                .num_turns = tr.rounds,
                .total_cost_usd = est_cost,
                .usage = usage,
                .final_thinking = self.last_thinking,
                .model = runtime.active_model,
                .stop_reason = stop_reason,
                .structured_output_json = "",
                .uuid = self.last_result_uuid,
            };
        }

        /// headless-sdk-16: a real, working "mid-session change" detector.
        /// Snapshots the skill/command names visible at `cwd` right now and
        /// compares them against the previous turn's snapshot; on an actual
        /// difference, emits `commands_changed` with the full new list
        /// (never a diff -- matches the reference's "clients should REPLACE
        /// their cached command list" contract) and writes it via `self.
        /// writeAll`. The very first observation only seeds the baseline: a
        /// brand-new session has no "previous" list to have changed from.
        /// Best-effort: any error here is swallowed rather than failing an
        /// otherwise-successful turn.
        fn maybeEmitCommandsChanged(self: *Self, cwd: []const u8, session_id: []const u8) void {
            const allocator = self.rc.allocator;
            const fresh = snapshotSortedSkillNames(allocator, cwd) catch return;

            if (self.has_command_baseline and !skillNameListsEqual(self.known_command_names, fresh)) {
                emit: {
                    const const_view = allocator.alloc([]const u8, fresh.len) catch break :emit;
                    defer allocator.free(const_view);
                    for (fresh, 0..) |n, i| const_view[i] = n;
                    const uuid = uuid_mod.allocV4(allocator) catch break :emit;
                    defer allocator.free(uuid);
                    const line = output.serializeCommandsChanged(allocator, const_view, session_id, uuid) catch break :emit;
                    defer allocator.free(line);
                    self.writeAll(line) catch {};
                }
            }

            freeOwnedStrings(allocator, self.known_command_names);
            self.known_command_names = fresh;
            self.has_command_baseline = true;
        }

        fn onControlRequest(ctx: *anyopaque, raw: []const u8) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            try self.handleControlRequest(raw);
        }

        fn onUpdateEnv(ctx: *anyopaque, raw: []const u8) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            _ = structured_io.applyEnvUpdates(self.rc.allocator, raw, std_io.stderrWriter()) catch {};
        }

        /// Dispatch a host-originated control_request: initialize / the live
        /// control subtypes (interrupt / set_*) / unsupported -> error. The
        /// encoded control_response is written back to the host.
        fn handleControlRequest(self: *Self, raw: []const u8) !void {
            const allocator = self.rc.allocator;
            var decoded = control.decodeRequest(allocator, raw) catch {
                // A malformed control_request envelope: nothing to respond to
                // (no request_id), so drop it.
                return;
            };
            defer decoded.deinit();

            switch (decoded.request.subtype) {
                .initialize => {
                    // missed-183: previously every field was silently dropped
                    // (an empty applier with every callback null). Every
                    // field is now wired to something real: systemPrompt/
                    // appendSystemPrompt REPLACE/append the session's actual
                    // rendered system prompt starting next turn (via
                    // `rc.cfg.system_prompt_override`/`append_system_prompt`
                    // -- the exact fields the CLI's own --system-prompt/
                    // --append-system-prompt flags write); a structured-
                    // output schema override and the promptSuggestions
                    // toggle take full effect; registered agents/
                    // sdkMcpServers are parsed and stored (surfaced in the
                    // init line / inspectable) even though zcode has no live
                    // agent/SDK-MCP registry to fully wire them into yet.
                    const applier: control.InitializeApplier = .{
                        .ctx = @ptrCast(self),
                        .setSystemPromptFn = applierSetSystemPrompt,
                        .setAppendSystemPromptFn = applierSetAppendSystemPrompt,
                        .setJsonSchemaFn = applierSetJsonSchema,
                        .setPromptSuggestionsFn = applierSetPromptSuggestions,
                        .registerAgentsFn = applierRegisterAgents,
                        .registerSdkMcpServersFn = applierRegisterSdkMcpServers,
                    };
                    const resp = try structured_io.dispatchInitialize(
                        allocator,
                        raw,
                        &self.init_state,
                        applier,
                        .{ .pid = currentPid() },
                    );
                    defer allocator.free(resp);
                    try self.writeAll(resp);
                },
                .interrupt, .set_permission_mode, .set_model, .set_max_thinking_tokens => {
                    const runtime = try self.ensureRuntime();
                    const mutator = control.LiveControlMutator{
                        .ctx = @ptrCast(runtime),
                        .interruptFn = liveInterrupt,
                        .setPermissionModeFn = liveSetPermissionMode,
                        .setModelFn = liveSetModel,
                        .setMaxThinkingTokensFn = liveSetMaxThinkingTokens,
                    };
                    const resp = try control.dispatchLiveControl(allocator, decoded.request, mutator);
                    defer allocator.free(resp);
                    try self.writeAll(resp);
                },
                .mcp_status => {
                    // headless-sdk-11: report every configured MCP server's
                    // live connection status, plus (for visibility) any
                    // SDK-hosted server names an `initialize` control_request
                    // registered but zcode cannot actually connect to yet
                    // (missed-183 / headless-sdk-11's `mcp_message` gap).
                    const servers_json = try self.buildMcpServersJson();
                    defer allocator.free(servers_json);
                    const resp = try control.dispatchMcpStatus(allocator, decoded.request.request_id, servers_json);
                    defer allocator.free(resp);
                    try self.writeAll(resp);
                },
                .rewind_files => {
                    const resp = try self.handleRewindFiles(decoded.request.request_id, decoded.request.raw_request);
                    defer allocator.free(resp);
                    try self.writeAll(resp);
                },
                else => {
                    // can_use_tool / hook_callback / elicitation are CLI->host
                    // (we originate them); mcp_message is recognized but not
                    // yet wired (see ControlSubtype.mcp_message's doc
                    // comment); a host sending any of these to us, or a truly
                    // unsupported subtype, gets an error response.
                    const resp = try control.encodeErrorResponse(
                        allocator,
                        decoded.request.request_id,
                        "unsupported inbound control subtype",
                        &.{},
                    );
                    defer allocator.free(resp);
                    try self.writeAll(resp);
                },
            }
        }

        /// headless-sdk-11 (`rewind_files` control_request): "Rewinds file
        /// changes made since a specific user message." Resolves
        /// `user_message_id` to a history index two ways, in order:
        ///
        ///   1. `known_user_messages` -- the id the HOST itself assigned to
        ///      one of its own `user` stream-json lines (submitMessage
        ///      options.uuid / missed-186), the reference's actual intended
        ///      meaning of "a specific user message". This is the path a
        ///      real SDK host uses.
        ///   2. A direct match against `HistoryTurn.uuid`, zcode's own
        ///      internal per-turn id (the same one repl_commands.zig's
        ///      `/rewind` picker keys off) -- a fallback so the id zcode
        ///      itself would show a REPL user (or a test) also works.
        ///
        /// Either way, once resolved, this reuses the exact primitives the
        /// REPL's own code-restoring `/rewind` already calls
        /// (`AgentRuntime.restoreCheckpoint` / `History.truncateFrom`): a
        /// REAL file + conversation restore, not a stub. `dry_run` reports
        /// what would happen without mutating anything.
        ///
        /// Honest, documented scope limit (mirrors
        /// `handleRewindToHistoryIndexWithCode`'s own doc comment in
        /// repl_commands.zig): zcode's checkpoints are not indexed per-turn,
        /// so "rewind to THIS message" is approximated as "restore the most
        /// recent checkpoint, then truncate the conversation to this
        /// message" rather than a message-precise file diff. When no
        /// checkpoint exists at all, the working tree is left untouched and
        /// the response says so -- never a silent partial rewind.
        fn handleRewindFiles(self: *Self, request_id: []const u8, raw_request: []const u8) ![]u8 {
            const allocator = self.rc.allocator;
            const parsed = control.parseRewindFilesRequest(raw_request);
            const user_message_id = parsed.user_message_id orelse {
                return control.encodeErrorResponse(allocator, request_id, "rewind_files missing 'user_message_id'", &.{});
            };

            const runtime = try self.ensureRuntime();
            var target_index: ?usize = null;
            for (self.known_user_messages.items) |rec| {
                if (std.mem.eql(u8, rec.message_uuid, user_message_id) and rec.history_index < runtime.history.len()) {
                    target_index = rec.history_index;
                }
            }
            if (target_index == null) {
                for (runtime.history.view(), 0..) |turn, idx| {
                    if (turn.role == .user and std.mem.eql(u8, turn.uuid, user_message_id)) target_index = idx;
                }
            }
            const idx = target_index orelse {
                const msg = try std.fmt.allocPrint(allocator, "'{s}' is not a user message in this session", .{user_message_id});
                defer allocator.free(msg);
                return control.encodeErrorResponse(allocator, request_id, msg, &.{});
            };

            if (parsed.dry_run) {
                const dropped = runtime.history.len() - idx;
                const message = try std.fmt.allocPrint(
                    allocator,
                    "would rewind {d} history entr{s} and restore the most recent checkpoint (dry run; nothing changed)",
                    .{ dropped, if (dropped == 1) "y" else "ies" },
                );
                defer allocator.free(message);
                const body = try control.buildRewindFilesResponse(allocator, message, true);
                defer allocator.free(body);
                return control.encodeSuccessResponse(allocator, request_id, body);
            }

            const restore_msg = runtime.restoreCheckpoint(null) catch |err| switch (err) {
                error.CheckpointNotFound => {
                    runtime.history.truncateFrom(idx);
                    const message = try std.fmt.allocPrint(
                        allocator,
                        "no checkpoint found to restore code from; rewound the conversation only. Working tree is unchanged.",
                        .{},
                    );
                    defer allocator.free(message);
                    const body = try control.buildRewindFilesResponse(allocator, message, false);
                    defer allocator.free(body);
                    return control.encodeSuccessResponse(allocator, request_id, body);
                },
                else => return err,
            };
            defer allocator.free(restore_msg);

            const message = try std.fmt.allocPrint(
                allocator,
                "Files rewound to state at message {s}. {s}",
                .{ user_message_id, restore_msg },
            );
            defer allocator.free(message);
            const body = try control.buildRewindFilesResponse(allocator, message, false);
            defer allocator.free(body);
            return control.encodeSuccessResponse(allocator, request_id, body);
        }

        /// writeAll shim so the relay/control responses go out through the
        /// session writer regardless of its concrete type.
        fn writeAll(self: *Self, bytes: []const u8) !void {
            try self.writer.writeAll(bytes);
        }

        /// Build the `mcpServers` JSON array for an `mcp_status` response
        /// (headless-sdk-11): every configured server's real name + live
        /// connection status, followed by any SDK-hosted server names an
        /// `initialize` control_request registered (status "pending" -- zcode
        /// has no live connection to an SDK-hosted server; see
        /// `sdk_mcp_server_names`'s doc comment). Caller owns the returned
        /// slice.
        fn buildMcpServersJson(self: *Self) ![]u8 {
            const allocator = self.rc.allocator;
            const servers_result = self.rc.mcp.list() catch null;
            defer if (servers_result) |s| mcp_client.freeServers(allocator, s);
            const servers: []const mcp_client.Server = servers_result orelse &.{};

            var out = std_io.StringBuilder.init(allocator);
            defer out.deinit();
            const w = out.writer();
            try w.writeByte('[');
            var wrote = false;
            for (servers) |s| {
                if (wrote) try w.writeByte(',');
                wrote = true;
                const status = mcpServerStatus(self.rc.mcp, allocator, s.name);
                try w.print("{{\"name\":{f},\"status\":{f}}}", .{ std.json.fmt(s.name, .{}), std.json.fmt(status, .{}) });
            }
            for (self.sdk_mcp_server_names) |name| {
                if (wrote) try w.writeByte(',');
                wrote = true;
                try w.print("{{\"name\":{f},\"status\":\"pending\"}}", .{std.json.fmt(name, .{})});
            }
            try w.writeByte(']');
            return out.toOwnedSlice();
        }

        // --- missed-183: InitializeApplier callbacks ------------------------

        /// `initialize.systemPrompt` -> REPLACES the session's entire
        /// rendered system prompt. Writes `rc.cfg.system_prompt_override`,
        /// the EXACT field `--system-prompt` already writes
        /// (main.zig's applyCliFlagCarrierFields) and the EXACT field
        /// `prompt_engine.build()` already reads fresh on every turn
        /// (`if (env.system_prompt_override.len > 0) return dupe(...)`) --
        /// so this takes effect starting with the session's NEXT turn, no
        /// new prompt-composition plumbing required. This is the real fix
        /// for the previously-100%-unwired half of missed-183: an SDK host's
        /// `initialize.systemPrompt` now genuinely changes the session that
        /// follows, not just a success control_response with zero effect.
        fn applierSetSystemPrompt(ctx: *anyopaque, prompt: []const u8) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            try config_mod.Config.setOwnedString(self.rc.cfg, self.rc.allocator, &self.rc.cfg.system_prompt_override, prompt);
        }

        /// `initialize.appendSystemPrompt` -> appended AFTER the composed
        /// system prompt. Writes `rc.cfg.append_system_prompt`, the EXACT
        /// field `--append-system-prompt` already writes
        /// (core/config_parse.zig) and the EXACT field
        /// core/prompt_helpers.zig's dynamic section renderer already reads
        /// fresh on every turn -- same "late injection, no new plumbing"
        /// story as `applierSetSystemPrompt` above.
        fn applierSetAppendSystemPrompt(ctx: *anyopaque, prompt: []const u8) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            try config_mod.Config.setOwnedString(self.rc.cfg, self.rc.allocator, &self.rc.cfg.append_system_prompt, prompt);
        }

        /// `initialize.jsonSchema` -> the live structured-output schema
        /// override. Applied to the runtime immediately when it already
        /// exists; otherwise staged on `self.sdk_json_schema` for
        /// `ensureRuntime` to apply once the runtime is built.
        fn applierSetJsonSchema(ctx: *anyopaque, schema_json: []const u8) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const allocator = self.rc.allocator;
            const dup = try allocator.dupe(u8, schema_json);
            errdefer allocator.free(dup);
            if (self.sdk_json_schema) |old| allocator.free(old);
            self.sdk_json_schema = dup;
            if (self.runtime) |runtime| {
                const dup2 = try allocator.dupe(u8, schema_json);
                if (runtime.pending_response_schema) |old2| allocator.free(old2);
                runtime.pending_response_schema = dup2;
            }
        }

        /// `initialize.promptSuggestions` -> stores the toggle, consumed by
        /// `onUser`'s per-turn prompt_suggestion emission alongside the
        /// `--prompt-suggestions` CLI flag (headless-sdk-15) -- either
        /// source enables it.
        fn applierSetPromptSuggestions(ctx: *anyopaque, enabled: bool) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.sdk_prompt_suggestions_enabled = enabled;
        }

        /// `initialize.agents` -> parse the JSON object's top-level keys
        /// (agent type names) and store them, surfaced in the init line's
        /// `agents` array. zcode has no live SDK-agent registry to fully
        /// register these into (that lives in core/agents.zig, outside this
        /// package), so this is deliberately scoped to visibility rather than
        /// full functional registration -- still a real improvement over the
        /// previous total silent drop.
        fn applierRegisterAgents(ctx: *anyopaque, agents_json: []const u8) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const allocator = self.rc.allocator;
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, agents_json, .{}) catch return;
            defer parsed.deinit();
            if (parsed.value != .object) return;
            var names: std.ArrayList([]u8) = .empty;
            errdefer {
                for (names.items) |n| allocator.free(n);
                names.deinit(allocator);
            }
            var it = parsed.value.object.iterator();
            while (it.next()) |entry| {
                try names.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
            }
            freeOwnedStrings(allocator, self.sdk_agent_names);
            self.sdk_agent_names = try names.toOwnedSlice(allocator);
        }

        /// `initialize.sdkMcpServers` -> parse the JSON array of server names
        /// and store them. zcode has no "SDK-hosted MCP server" concept
        /// (headless-sdk-11 leaves `mcp_message` unimplemented for the same
        /// reason), so these are stored for visibility only, not connected.
        fn applierRegisterSdkMcpServers(ctx: *anyopaque, servers_json: []const u8) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const allocator = self.rc.allocator;
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, servers_json, .{}) catch return;
            defer parsed.deinit();
            if (parsed.value != .array) return;
            var names: std.ArrayList([]u8) = .empty;
            errdefer {
                for (names.items) |n| allocator.free(n);
                names.deinit(allocator);
            }
            for (parsed.value.array.items) |item| {
                if (item != .string) continue;
                try names.append(allocator, try allocator.dupe(u8, item.string));
            }
            freeOwnedStrings(allocator, self.sdk_mcp_server_names);
            self.sdk_mcp_server_names = try names.toOwnedSlice(allocator);
        }
    };
}

// --- live-control mutator adapters (AgentRuntime-backed) --------------------

fn liveInterrupt(ctx: *anyopaque) anyerror!void {
    const runtime: *AgentRuntime = @ptrCast(@alignCast(ctx));
    runtime.requestInterrupt();
}

fn liveSetPermissionMode(ctx: *anyopaque, mode: []const u8) anyerror!void {
    const runtime: *AgentRuntime = @ptrCast(@alignCast(ctx));
    try runtime.setApprovalMode(mode);
}

fn liveSetModel(ctx: *anyopaque, model: []const u8) anyerror!void {
    const runtime: *AgentRuntime = @ptrCast(@alignCast(ctx));
    try runtime.setActiveModel(model);
}

fn liveSetMaxThinkingTokens(ctx: *anyopaque, tokens: ?u64) anyerror!void {
    const runtime: *AgentRuntime = @ptrCast(@alignCast(ctx));
    runtime.setReasoningTokens(tokens);
}

// --- control_response helpers (used by the relay block-read) ----------------

/// Process pid for the initialize response (portable across linux/darwin).
fn currentPid() i64 {
    return switch (@import("builtin").os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        else => @intCast(std.c.getpid()),
    };
}

fn genRequestId(allocator: std.mem.Allocator) ![]u8 {
    const rng = @import("../core/rng.zig");
    const raw = try rng.hexId(allocator, 16);
    defer allocator.free(raw);
    return std.fmt.allocPrint(allocator, "cli-{s}", .{raw});
}

fn isControlResponse(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "\"type\":\"control_response\"") != null;
}

fn isControlRequest(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "\"type\":\"control_request\"") != null;
}

/// True when a control_response line's `response.request_id` equals `req_id`.
/// Uses a parse to be robust against whitespace.
fn matchesRequestId(line: []const u8, req_id: []const u8) bool {
    const gpa = rt.gpa;
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const resp = parsed.value.object.get("response") orelse return false;
    if (resp != .object) return false;
    const id = resp.object.get("request_id") orelse return false;
    if (id != .string) return false;
    return std.mem.eql(u8, id.string, req_id);
}

/// Map a control_response to an ApprovalResponse. The reference can_use_tool
/// response body is `{behavior:"allow"|"deny", ...}` or carries an `allow` flag;
/// we accept either an explicit `behavior`/`decision` of "allow"/"approve" or a
/// success subtype with a truthy allow, defaulting to deny (fail safe).
fn decisionFromResponse(line: []const u8) types.ApprovalResponse {
    const gpa = rt.gpa;
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch return .deny;
    defer parsed.deinit();
    if (parsed.value != .object) return .deny;
    const resp = parsed.value.object.get("response") orelse return .deny;
    if (resp != .object) return .deny;

    // An error subtype is a deny.
    if (resp.object.get("subtype")) |st| {
        if (st == .string and std.mem.eql(u8, st.string, "error")) return .deny;
    }

    // The decision rides in the inner `response` body.
    const body = resp.object.get("response") orelse return .deny;
    if (body != .object) return .deny;
    if (allowFromBody(&body.object)) return .approve;
    return .deny;
}

fn allowFromBody(body: *const std.json.ObjectMap) bool {
    if (body.get("behavior")) |b| {
        if (b == .string) {
            if (std.ascii.eqlIgnoreCase(b.string, "allow")) return true;
            if (std.ascii.eqlIgnoreCase(b.string, "approve")) return true;
        }
    }
    if (body.get("decision")) |d| {
        if (d == .string) {
            if (std.ascii.eqlIgnoreCase(d.string, "allow")) return true;
            if (std.ascii.eqlIgnoreCase(d.string, "approve")) return true;
        }
    }
    if (body.get("allow")) |a| {
        if (a == .bool and a.bool) return true;
    }
    return false;
}

const testing = std.testing;

test "resolve: defaults to text/text and parses the formats" {
    const t0 = try resolve(null, null);
    try testing.expectEqual(output.OutputFormat.text, t0.output_format);
    try testing.expectEqual(structured_io.InputFormat.text, t0.input_format);
    try testing.expect(!isSdkShaped(t0));

    const t1 = try resolve("json", null);
    try testing.expectEqual(output.OutputFormat.json, t1.output_format);
    try testing.expect(isSdkShaped(t1));

    const t2 = try resolve("stream-json", "stream-json");
    try testing.expectEqual(output.OutputFormat.stream_json, t2.output_format);
    try testing.expectEqual(structured_io.InputFormat.stream_json, t2.input_format);
    try testing.expect(isSdkShaped(t2));
}

test "decisionFromResponse: allow behavior -> approve, deny / error / missing -> deny" {
    // Allow behavior in the inner response body.
    try testing.expectEqual(
        types.ApprovalResponse.approve,
        decisionFromResponse("{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"r1\",\"response\":{\"behavior\":\"allow\"}}}"),
    );
    // Explicit deny behavior.
    try testing.expectEqual(
        types.ApprovalResponse.deny,
        decisionFromResponse("{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"r1\",\"response\":{\"behavior\":\"deny\"}}}"),
    );
    // An error subtype is a deny.
    try testing.expectEqual(
        types.ApprovalResponse.deny,
        decisionFromResponse("{\"type\":\"control_response\",\"response\":{\"subtype\":\"error\",\"request_id\":\"r1\",\"error\":\"nope\"}}"),
    );
    // A missing body is a deny (fail safe).
    try testing.expectEqual(
        types.ApprovalResponse.deny,
        decisionFromResponse("{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"r1\"}}"),
    );
    // An `allow: true` flag also approves.
    try testing.expectEqual(
        types.ApprovalResponse.approve,
        decisionFromResponse("{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"r1\",\"response\":{\"allow\":true}}}"),
    );
}

test "matchesRequestId: matches the response.request_id only" {
    const line = "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"cli-abc\"}}";
    try testing.expect(matchesRequestId(line, "cli-abc"));
    try testing.expect(!matchesRequestId(line, "cli-xyz"));
}

// --- LIVE integration tests (mock provider, in-memory host pipes) -----------

const config_test = config_mod;
const test_helpers = @import("../core/test_helpers.zig");

/// Minimal mock-provider scaffolding for the live headless tests. Mirrors the
/// HeadlessCapsHarness in session_mgmt.zig: builds config/policy/audit/store/mcp
/// under a tmp root and points config at the deterministic `mock` provider so a
/// turn runs offline.
const LiveHarness = struct {
    cfg: config_mod.Config,
    policy: policy_mod.Policy,
    audit: logger_mod.AuditLogger,
    store: session_store.Store,
    mcp: mcp_client.Client,
    cwd: []u8,
    logs_dir: []u8,
    sessions_dir: []u8,
    registry_path: []u8,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, root: []const u8) !*LiveHarness {
        const self = try allocator.create(LiveHarness);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.cwd = try allocator.dupe(u8, root);
        errdefer allocator.free(self.cwd);
        self.logs_dir = try std.fs.path.join(allocator, &.{ root, "logs" });
        errdefer allocator.free(self.logs_dir);
        self.sessions_dir = try std.fs.path.join(allocator, &.{ root, "sessions" });
        errdefer allocator.free(self.sessions_dir);
        self.registry_path = try std.fs.path.join(allocator, &.{ root, "mcp", "registry.json" });
        errdefer allocator.free(self.registry_path);

        self.cfg = try config_mod.Config.init(allocator);
        errdefer self.cfg.deinit(allocator);
        allocator.free(self.cfg.default_provider);
        self.cfg.default_provider = try allocator.dupe(u8, "mock");
        allocator.free(self.cfg.default_model);
        self.cfg.default_model = try allocator.dupe(u8, "mock-agent");

        self.policy = try policy_mod.Policy.init(allocator);
        errdefer self.policy.deinit();
        self.audit = try logger_mod.AuditLogger.init(allocator, self.logs_dir);
        errdefer self.audit.deinit();
        self.store = try session_store.Store.init(allocator, self.sessions_dir, false);
        errdefer self.store.deinit();
        self.mcp = try mcp_client.Client.init(allocator, self.registry_path);
        errdefer self.mcp.deinit();
        return self;
    }

    fn deinit(self: *LiveHarness) void {
        self.mcp.deinit();
        self.store.deinit();
        self.audit.deinit();
        self.policy.deinit();
        self.cfg.deinit(self.allocator);
        self.allocator.free(self.cwd);
        self.allocator.free(self.logs_dir);
        self.allocator.free(self.sessions_dir);
        self.allocator.free(self.registry_path);
        self.allocator.destroy(self);
    }

    fn runContext(self: *LiveHarness) RunContext {
        return .{
            .allocator = self.allocator,
            .cwd = self.cwd,
            .cfg = &self.cfg,
            .policy = &self.policy,
            .audit = &self.audit,
            .store = &self.store,
            .mcp = &self.mcp,
            .browser = null,
            .auto_approve_high = false,
            .strict = false,
            .yolo_mode = false,
            .initial_agent = null,
            .caps = .{},
        };
    }
};

/// A scripted SDK host that pairs a reader and a writer for the stream-json
/// session. The writer records every line the CLI emits. The reader serves
/// queued user/control lines; when the CLI emits a `can_use_tool`
/// control_request and the reader is asked for the next line, it answers with a
/// matching `control_response` carrying the configured decision -- modeling a
/// real host that reads the request, extracts the request_id, and replies.
const ScriptedHost = struct {
    allocator: std.mem.Allocator,
    /// Lines the host feeds the CLI before/around the turn (e.g. the user msg).
    queued: std.ArrayList([]const u8),
    queued_idx: usize = 0,
    /// Everything the CLI wrote, joined.
    out: std.ArrayList(u8),
    /// The decision the host returns for each can_use_tool request.
    decision: []const u8 = "allow",
    /// How many can_use_tool requests the host answered (for assertions).
    answered: usize = 0,

    fn init(allocator: std.mem.Allocator) ScriptedHost {
        return .{
            .allocator = allocator,
            .queued = .empty,
            .out = .empty,
        };
    }

    fn deinit(self: *ScriptedHost) void {
        self.queued.deinit(self.allocator);
        self.out.deinit(self.allocator);
    }

    fn queue(self: *ScriptedHost, line: []const u8) !void {
        try self.queued.append(self.allocator, line);
    }

    // Reader contract: readUntilDelimiterOrEofAlloc(allocator, '\n', max). The
    // explicit error set includes StreamTooLong so the inferred set matches the
    // dispatch loop's switch (the test reader never actually overflows).
    pub fn readUntilDelimiterOrEofAlloc(self: *ScriptedHost, allocator: std.mem.Allocator, delim: u8, max: usize) (std.mem.Allocator.Error || error{StreamTooLong})!?[]u8 {
        _ = delim;
        _ = max;
        // 1. Serve any still-queued scripted line.
        if (self.queued_idx < self.queued.items.len) {
            const line = self.queued.items[self.queued_idx];
            self.queued_idx += 1;
            return try allocator.dupe(u8, line);
        }
        // 2. If the CLI has emitted an unanswered can_use_tool control_request,
        //    answer it with a matching control_response. We scan our captured
        //    output for the last control_request request_id we have not yet
        //    answered.
        if (try self.pendingCanUseToolResponse(allocator)) |resp| return resp;
        // 3. Nothing left: EOF (ends the dispatch loop / fails a pending relay).
        return null;
    }

    /// Build a control_response for the most recent un-answered can_use_tool
    /// request found in the captured output, or null when there is none.
    fn pendingCanUseToolResponse(self: *ScriptedHost, allocator: std.mem.Allocator) !?[]u8 {
        // Find control_request lines in the output; answer the (answered+1)-th.
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, self.out.items, '\n');
        while (it.next()) |line| {
            if (std.mem.indexOf(u8, line, "\"type\":\"control_request\"") == null) continue;
            if (std.mem.indexOf(u8, line, "\"can_use_tool\"") == null) continue;
            count += 1;
            if (count <= self.answered) continue;
            // This is the next request to answer; extract its request_id.
            const id = extractRequestId(line) orelse continue;
            self.answered += 1;
            return try std.fmt.allocPrint(
                allocator,
                "{{\"type\":\"control_response\",\"response\":{{\"subtype\":\"success\",\"request_id\":\"{s}\",\"response\":{{\"behavior\":\"{s}\"}}}}}}",
                .{ id, self.decision },
            );
        }
        return null;
    }

    // Writer contract: writeAll([]const u8).
    pub fn writeAll(self: *ScriptedHost, bytes: []const u8) !void {
        try self.out.appendSlice(self.allocator, bytes);
    }
};

/// Extract the top-level `request_id` from a control_request line.
fn extractRequestId(line: []const u8) ?[]const u8 {
    const key = "\"request_id\":\"";
    const at = std.mem.indexOf(u8, line, key) orelse return null;
    const start = at + key.len;
    const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse return null;
    return line[start..end];
}

test "extractRequestId pulls the request_id out of a control_request line" {
    const line = "{\"type\":\"control_request\",\"request_id\":\"cli-deadbeef\",\"request\":{\"subtype\":\"can_use_tool\"}}";
    try testing.expectEqualStrings("cli-deadbeef", extractRequestId(line).?);
}

test "headless-sdk-14: isAgentToolName recognizes the reference name and its dispatch-only legacy synonyms" {
    try testing.expect(isAgentToolName("Agent"));
    try testing.expect(isAgentToolName("AgentRun"));
    try testing.expect(isAgentToolName("agent_run"));
    try testing.expect(!isAgentToolName("Task"));
    try testing.expect(!isAgentToolName("Bash"));
}

test "headless-sdk-14: extractJsonStringField pulls a string field or null" {
    const alloc = testing.allocator;
    {
        const got = try extractJsonStringField(alloc, "{\"prompt\":\"investigate the bug\",\"subagent_type\":\"explore\"}", "prompt");
        defer if (got) |g| alloc.free(g);
        try testing.expectEqualStrings("investigate the bug", got.?);
    }
    // Missing field -> null.
    try testing.expect((try extractJsonStringField(alloc, "{\"subagent_type\":\"explore\"}", "prompt")) == null);
    // Not a string -> null (never coerces a non-string into forwarded text).
    try testing.expect((try extractJsonStringField(alloc, "{\"prompt\":5}", "prompt")) == null);
    // Unparseable JSON -> null, not an error.
    try testing.expect((try extractJsonStringField(alloc, "not json", "prompt")) == null);
}

test "headless-sdk-14: extractSubagentFinalText recovers the text after spawnChildAgent's marker, or null" {
    try testing.expectEqualStrings(
        "found the race condition in auth.zig:42",
        extractSubagentFinalText("subagent_rounds=3\n---\nfound the race condition in auth.zig:42").?,
    );
    // A background spawn's status message has no marker -> not forwarded.
    try testing.expect(extractSubagentFinalText("Agent spawned in background.\nbackground_agent_id=task-1") == null);
    // Some other tool's plain output has no marker either.
    try testing.expect(extractSubagentFinalText("edit ok: 1 replacement") == null);
}

/// Test-only ToolEvent builder: dupes each field so it's freed the same way
/// `buildToolEvents` output is (via `ToolEvent.deinit`), rather than fighting
/// `[]u8`-vs-string-literal mutability in every test fixture.
fn testToolEvent(alloc: std.mem.Allocator, tool_use_id: []const u8, name: []const u8, input_json: []const u8, output_text: []const u8) !ToolEvent {
    return .{
        .tool_use_id = try alloc.dupe(u8, tool_use_id),
        .name = try alloc.dupe(u8, name),
        .input_json = try alloc.dupe(u8, input_json),
        .output_text = try alloc.dupe(u8, output_text),
        .denied = false,
        .is_error = false,
    };
}

test "headless-sdk-14: maybeForwardSubagentText emits user+assistant lines tagged with parent_tool_use_id for an Agent call" {
    const alloc = testing.allocator;
    var buf = std_io.StringBuilder.init(alloc);
    defer buf.deinit();
    const Sink = struct {
        sb: *std_io.StringBuilder,
        fn writeAll(self: @This(), bytes: []const u8) !void {
            try self.sb.appendSlice(bytes);
        }
    };

    var ev = try testToolEvent(alloc, "toolu_sess_0", "Agent", "{\"prompt\":\"investigate the auth bug\",\"subagent_type\":\"explore\"}", "subagent_rounds=1\n---\nfound it: race condition in auth.zig:42");
    defer ev.deinit(alloc);
    try maybeForwardSubagentText(alloc, Sink{ .sb = &buf }, "sess-9", true, ev);

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, buf.items(), "\n"), '\n');
    const user_line = lines.next().?;
    const assistant_line = lines.next().?;
    try testing.expect(lines.next() == null);

    var up = try std.json.parseFromSlice(std.json.Value, alloc, user_line, .{});
    defer up.deinit();
    try testing.expectEqualStrings("user", up.value.object.get("type").?.string);
    try testing.expectEqualStrings("toolu_sess_0", up.value.object.get("parent_tool_use_id").?.string);
    try testing.expectEqualStrings("investigate the auth bug", up.value.object.get("message").?.object.get("content").?.array.items[0].object.get("text").?.string);

    var ap = try std.json.parseFromSlice(std.json.Value, alloc, assistant_line, .{});
    defer ap.deinit();
    try testing.expectEqualStrings("assistant", ap.value.object.get("type").?.string);
    try testing.expectEqualStrings("toolu_sess_0", ap.value.object.get("parent_tool_use_id").?.string);
    try testing.expectEqualStrings("found it: race condition in auth.zig:42", ap.value.object.get("message").?.object.get("content").?.array.items[0].object.get("text").?.string);
}

test "headless-sdk-14: maybeForwardSubagentText is a no-op when disabled, for a non-Agent tool, or with no matching shape" {
    const alloc = testing.allocator;
    var buf = std_io.StringBuilder.init(alloc);
    defer buf.deinit();
    const Sink = struct {
        sb: *std_io.StringBuilder,
        fn writeAll(self: @This(), bytes: []const u8) !void {
            try self.sb.appendSlice(bytes);
        }
    };

    var agent_ev = try testToolEvent(alloc, "toolu_1", "Agent", "{\"prompt\":\"x\"}", "subagent_rounds=1\n---\nx done");
    defer agent_ev.deinit(alloc);
    // Flag off -> nothing emitted even for a real Agent call.
    try maybeForwardSubagentText(alloc, Sink{ .sb = &buf }, "sess", false, agent_ev);
    try testing.expectEqual(@as(usize, 0), buf.items().len);

    // A non-Agent tool -> nothing emitted even with the flag on.
    var bash_ev = try testToolEvent(alloc, "toolu_2", "Bash", "{\"command\":\"ls\"}", "file1\nfile2");
    defer bash_ev.deinit(alloc);
    try maybeForwardSubagentText(alloc, Sink{ .sb = &buf }, "sess", true, bash_ev);
    try testing.expectEqual(@as(usize, 0), buf.items().len);

    // A background-spawned Agent call (no "---\n" marker yet, no synchronous
    // final text) -> the prompt is still forwarded, but no fabricated
    // assistant line for text that doesn't exist yet.
    var bg_ev = try testToolEvent(alloc, "toolu_3", "Agent", "{\"prompt\":\"do it in the background\",\"run_in_background\":true}", "Agent spawned in background.\nbackground_agent_id=task-1");
    defer bg_ev.deinit(alloc);
    try maybeForwardSubagentText(alloc, Sink{ .sb = &buf }, "sess", true, bg_ev);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, buf.items(), "\n"), '\n');
    const only_line = lines.next().?;
    try testing.expect(lines.next() == null);
    try testing.expect(std.mem.indexOf(u8, only_line, "\"type\":\"user\"") != null);
}

test "LIVE: --output-format json emits a single parseable SDK result (not the legacy blob)" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var h = try LiveHarness.init(alloc, root);
    defer h.deinit();

    var buf = std_io.StringBuilder.init(alloc);
    defer buf.deinit();
    const Sink = struct {
        sb: *std_io.StringBuilder,
        fn writeAll(self: @This(), bytes: []const u8) !void {
            try self.sb.appendSlice(bytes);
        }
    };

    try runOutput(h.runContext(), .json, "hello", Sink{ .sb = &buf });

    // Exactly one NDJSON line, a parseable result object with type:"result".
    const trimmed = std.mem.trim(u8, buf.items(), " \t\r\n");
    try testing.expect(std.mem.indexOfScalar(u8, trimmed, '\n') == null);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("result", obj.get("type").?.string);
    try testing.expectEqualStrings("success", obj.get("subtype").?.string);
    try testing.expect(obj.get("num_turns") != null);
    try testing.expect(obj.get("session_id") != null);
    try testing.expect(obj.get("usage").?.object.get("input_tokens") != null);
    // It is NOT the legacy encodeExecJson blob (which has no "type" key).
    try testing.expect(obj.get("type") != null);
}

test "LIVE: --session-id overrides the session id and --no-session-persistence removes the session file" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var h = try LiveHarness.init(alloc, root);
    defer h.deinit();

    var buf = std_io.StringBuilder.init(alloc);
    defer buf.deinit();
    const Sink = struct {
        sb: *std_io.StringBuilder,
        fn writeAll(self: @This(), bytes: []const u8) !void {
            try self.sb.appendSlice(bytes);
        }
    };

    var rc = h.runContext();
    rc.caps.session_id_override = "123e4567-e89b-12d3-a456-426614174000";
    rc.caps.no_session_persistence = true;

    try runOutput(rc, .json, "hello", Sink{ .sb = &buf });

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, std.mem.trim(u8, buf.items(), " \t\r\n"), .{});
    defer parsed.deinit();
    // headless-sdk-02: the exact --session-id value is echoed in the result.
    try testing.expectEqualStrings("123e4567-e89b-12d3-a456-426614174000", parsed.value.object.get("session_id").?.string);

    // headless-sdk-02: --no-session-persistence leaves no session file behind
    // for this run, despite the turn having actually run (and persisted, then
    // been removed).
    const path = try h.store.sessionPath("123e4567-e89b-12d3-a456-426614174000");
    defer alloc.free(path);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(rt.io, path, .{}));
}

test "LIVE: without --no-session-persistence, the session file IS left behind" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var h = try LiveHarness.init(alloc, root);
    defer h.deinit();

    var buf = std_io.StringBuilder.init(alloc);
    defer buf.deinit();
    const Sink = struct {
        sb: *std_io.StringBuilder,
        fn writeAll(self: @This(), bytes: []const u8) !void {
            try self.sb.appendSlice(bytes);
        }
    };

    var rc = h.runContext();
    rc.caps.session_id_override = "223e4567-e89b-12d3-a456-426614174000";

    try runOutput(rc, .json, "hello", Sink{ .sb = &buf });

    const path = try h.store.sessionPath("223e4567-e89b-12d3-a456-426614174000");
    defer alloc.free(path);
    _ = try std.Io.Dir.cwd().statFile(rt.io, path, .{});
}

test "LIVE: --output-format stream-json emits system:init first then result" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var h = try LiveHarness.init(alloc, root);
    defer h.deinit();

    var buf = std_io.StringBuilder.init(alloc);
    defer buf.deinit();
    const Sink = struct {
        sb: *std_io.StringBuilder,
        fn writeAll(self: @This(), bytes: []const u8) !void {
            try self.sb.appendSlice(bytes);
        }
    };

    try runOutput(h.runContext(), .stream_json, "hello", Sink{ .sb = &buf });

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    var it = std.mem.splitScalar(u8, buf.items(), '\n');
    while (it.next()) |raw| {
        if (raw.len == 0) continue;
        try lines.append(alloc, raw);
    }
    try testing.expect(lines.items.len >= 2);

    var first = try std.json.parseFromSlice(std.json.Value, alloc, lines.items[0], .{});
    defer first.deinit();
    try testing.expectEqualStrings("system", first.value.object.get("type").?.string);
    try testing.expectEqualStrings("init", first.value.object.get("subtype").?.string);
    // init carries the tool list.
    try testing.expect(first.value.object.get("tools").?.array.items.len > 0);

    var last = try std.json.parseFromSlice(std.json.Value, alloc, lines.items[lines.items.len - 1], .{});
    defer last.deinit();
    try testing.expectEqualStrings("result", last.value.object.get("type").?.string);
}

test "LIVE headless-sdk-missed-185: --enable-auth-status emits a real auth_status message after init" {
    const alloc = testing.allocator;
    const env = @import("../core/env.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    // Deterministic credential state for the assertion below: no
    // ANTHROPIC_API_KEY, so apiKeySource() resolves to "none".
    env.setOverride("ANTHROPIC_API_KEY", "") catch unreachable;
    defer env.clearOverrides();

    var h = try LiveHarness.init(alloc, root);
    defer h.deinit();

    var buf = std_io.StringBuilder.init(alloc);
    defer buf.deinit();
    const Sink = struct {
        sb: *std_io.StringBuilder,
        fn writeAll(self: @This(), bytes: []const u8) !void {
            try self.sb.appendSlice(bytes);
        }
    };

    var rc = h.runContext();
    rc.caps.enable_auth_status = true;
    try runOutput(rc, .stream_json, "hello", Sink{ .sb = &buf });

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    var it = std.mem.splitScalar(u8, buf.items(), '\n');
    while (it.next()) |raw| {
        if (raw.len == 0) continue;
        try lines.append(alloc, raw);
    }
    try testing.expect(lines.items.len >= 3);

    // Line 0 is system:init; line 1 must be the real auth_status message --
    // previously no real invocation, with the flag on or off, could ever
    // produce this message at all.
    var first = try std.json.parseFromSlice(std.json.Value, alloc, lines.items[0], .{});
    defer first.deinit();
    try testing.expectEqualStrings("init", first.value.object.get("subtype").?.string);

    var auth = try std.json.parseFromSlice(std.json.Value, alloc, lines.items[1], .{});
    defer auth.deinit();
    const obj = auth.value.object;
    try testing.expectEqualStrings("auth_status", obj.get("type").?.string);
    try testing.expect(!obj.get("isAuthenticating").?.bool);
    try testing.expect(obj.get("output").?.array.items.len == 1);
    try testing.expect(std.mem.indexOf(u8, obj.get("output").?.array.items[0].string, "none") != null);
    try testing.expect(obj.get("session_id") != null);
    try testing.expect(obj.get("uuid") != null);
}

test "LIVE headless-sdk-missed-185: without --enable-auth-status, no auth_status line is emitted" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var h = try LiveHarness.init(alloc, root);
    defer h.deinit();

    var buf = std_io.StringBuilder.init(alloc);
    defer buf.deinit();
    const Sink = struct {
        sb: *std_io.StringBuilder,
        fn writeAll(self: @This(), bytes: []const u8) !void {
            try self.sb.appendSlice(bytes);
        }
    };

    try runOutput(h.runContext(), .stream_json, "hello", Sink{ .sb = &buf });
    try testing.expect(std.mem.indexOf(u8, buf.items(), "auth_status") == null);
}

test "LIVE headless-sdk-18: a healthy MCP server reports connected and an unreachable one reports failed -- distinct values" {
    // Spawns a real subprocess as a fake MCP server (same fixture pattern as
    // mcp/client.zig's "stdio MCP fixture" test) -- skipped where python3
    // may not be reliably available (CI), same guard that test uses.
    const env = @import("../core/env.zig");
    if (env.getenv("CI") != null) return error.SkipZigTest;
    // A nonexistent-binary "server" only fails once its connect attempt
    // gives up -- bound that to a couple seconds instead of the 30s
    // production default so this test can't blow the suite's time budget.
    try env.setOverride("MCP_TIMEOUT", "2000");
    defer env.clearOverrides();

    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "mock_server.py", .data =
        \\import json, sys
        \\def read_frame():
        \\    header = b""
        \\    while b"\r\n\r\n" not in header:
        \\        c = sys.stdin.buffer.read(1)
        \\        if not c:
        \\            return None
        \\        header += c
        \\    length = 0
        \\    for line in header.decode("utf-8", errors="replace").split("\r\n"):
        \\        if line.lower().startswith("content-length:"):
        \\            length = int(line.split(":",1)[1].strip())
        \\            break
        \\    body = sys.stdin.buffer.read(length)
        \\    return json.loads(body.decode("utf-8"))
        \\def write_frame(obj):
        \\    body = json.dumps(obj).encode("utf-8")
        \\    sys.stdout.buffer.write(f"Content-Length: {len(body)}\r\n\r\n".encode("utf-8"))
        \\    sys.stdout.buffer.write(body)
        \\    sys.stdout.buffer.flush()
        \\while True:
        \\    msg = read_frame()
        \\    if msg is None:
        \\        break
        \\    method = msg.get("method")
        \\    if method == "initialize":
        \\        write_frame({"jsonrpc":"2.0","id":msg.get("id"),"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"mock","version":"0.1"}}})
        \\    elif method == "tools/list":
        \\        write_frame({"jsonrpc":"2.0","id":msg.get("id"),"result":{"tools":[]}})
    });
    const script = try test_helpers.tmpDirPath(alloc, &tmp, "mock_server.py");
    defer alloc.free(script);

    var h = try LiveHarness.init(alloc, root);
    defer h.deinit();

    const healthy_transport = try std.fmt.allocPrint(alloc, "python3 '{s}'", .{script});
    defer alloc.free(healthy_transport);
    try h.mcp.add("healthy", healthy_transport);
    try h.mcp.add("broken", "/no/such/binary-zcode-test-fixture-xyz");

    var buf = std_io.StringBuilder.init(alloc);
    defer buf.deinit();
    const Sink = struct {
        sb: *std_io.StringBuilder,
        fn writeAll(self: @This(), bytes: []const u8) !void {
            try self.sb.appendSlice(bytes);
        }
    };
    try runOutput(h.runContext(), .stream_json, "hello", Sink{ .sb = &buf });

    var it = std.mem.splitScalar(u8, buf.items(), '\n');
    const init_line = it.next().?;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, init_line, .{});
    defer parsed.deinit();
    const servers = parsed.value.object.get("mcp_servers").?.array.items;
    try testing.expectEqual(@as(usize, 2), servers.len);

    var healthy_status: ?[]const u8 = null;
    var broken_status: ?[]const u8 = null;
    for (servers) |s| {
        const name = s.object.get("name").?.string;
        const status = s.object.get("status").?.string;
        if (std.mem.eql(u8, name, "healthy")) healthy_status = status;
        if (std.mem.eql(u8, name, "broken")) broken_status = status;
    }

    // The core acceptance bar: DISTINCT status values for a healthy vs an
    // unreachable server -- previously "pending" was the only value any
    // real invocation could ever produce, for every server, always.
    try testing.expect(!std.mem.eql(u8, healthy_status.?, broken_status.?));
    try testing.expectEqualStrings("connected", healthy_status.?);
    try testing.expectEqualStrings("failed", broken_status.?);
}

test "LIVE headless-sdk-15: --prompt-suggestions emits a prompt_suggestion line after result" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var h = try LiveHarness.init(alloc, root);
    defer h.deinit();

    var buf = std_io.StringBuilder.init(alloc);
    defer buf.deinit();
    const Sink = struct {
        sb: *std_io.StringBuilder,
        fn writeAll(self: @This(), bytes: []const u8) !void {
            try self.sb.appendSlice(bytes);
        }
    };

    var rc = h.runContext();
    rc.caps.prompt_suggestions = true;

    try runOutput(rc, .stream_json, "hello", Sink{ .sb = &buf });

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    var it = std.mem.splitScalar(u8, buf.items(), '\n');
    while (it.next()) |raw| {
        if (raw.len == 0) continue;
        try lines.append(alloc, raw);
    }
    // init, ..., result, prompt_suggestion -- the suggestion line is LAST,
    // strictly after the result line the acceptance test names.
    try testing.expect(lines.items.len >= 3);

    var second_to_last = try std.json.parseFromSlice(std.json.Value, alloc, lines.items[lines.items.len - 2], .{});
    defer second_to_last.deinit();
    try testing.expectEqualStrings("result", second_to_last.value.object.get("type").?.string);

    var last = try std.json.parseFromSlice(std.json.Value, alloc, lines.items[lines.items.len - 1], .{});
    defer last.deinit();
    try testing.expectEqualStrings("prompt_suggestion", last.value.object.get("type").?.string);
    try testing.expect(last.value.object.get("suggestion").?.string.len > 0);
    try testing.expect(last.value.object.get("uuid") != null);
    try testing.expect(last.value.object.get("session_id") != null);
}

test "LIVE headless-sdk-15: without --prompt-suggestions, no prompt_suggestion line is emitted" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var h = try LiveHarness.init(alloc, root);
    defer h.deinit();

    var buf = std_io.StringBuilder.init(alloc);
    defer buf.deinit();
    const Sink = struct {
        sb: *std_io.StringBuilder,
        fn writeAll(self: @This(), bytes: []const u8) !void {
            try self.sb.appendSlice(bytes);
        }
    };

    try runOutput(h.runContext(), .stream_json, "hello", Sink{ .sb = &buf });
    try testing.expect(std.mem.indexOf(u8, buf.items(), "prompt_suggestion") == null);
}

test "headless-sdk-15: derivePromptSuggestion reflects the real turn content" {
    // A failed tool call -> ask to fix it.
    const failed = [_]ToolEvent{.{ .tool_use_id = @constCast("t1"), .name = @constCast("Bash"), .input_json = @constCast("{}"), .output_text = @constCast("boom"), .denied = false, .is_error = true }};
    try testing.expectEqualStrings("Can you fix the error from the last command and try again?", derivePromptSuggestion("done", &failed));

    // A successful edit -> ask to verify.
    const edited = [_]ToolEvent{.{ .tool_use_id = @constCast("t2"), .name = @constCast("Write"), .input_json = @constCast("{}"), .output_text = @constCast("ok"), .denied = false, .is_error = false }};
    try testing.expectEqualStrings("Can you run the tests to confirm that change works?", derivePromptSuggestion("done", &edited));

    // A non-edit, non-error tool call (e.g. a read) -> generic next-step ask.
    const read = [_]ToolEvent{.{ .tool_use_id = @constCast("t3"), .name = @constCast("Read"), .input_json = @constCast("{}"), .output_text = @constCast("contents"), .denied = false, .is_error = false }};
    try testing.expectEqualStrings("What should we do next?", derivePromptSuggestion("done", &read));

    // No tool calls, final text is a question -> affirmative answer.
    try testing.expectEqualStrings("Yes, please go ahead.", derivePromptSuggestion("Should I proceed?", &.{}));

    // No tool calls, no question -> generic fallback.
    try testing.expectEqualStrings("What should we do next?", derivePromptSuggestion("All done.", &.{}));
}

test "LIVE: stream-json input drives a turn and emits a can_use_tool control_request; allow lets the tool run" {
    const alloc = testing.allocator;
    const env = @import("../core/env.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    // Force the mock to emit a `shell` tool call (always-loaded, needs
    // permission) regardless of whether the tmp cwd is a git repo, so the
    // permission gate reliably fires and reaches the relay. Capped at 2 turns
    // so the repeating tool call does not loop forever.
    try env.setOverride(
        "ZCODE_MOCK_RESPONSE",
        "{\"assistant\":\"running a command\",\"tool_calls\":[{\"name\":\"shell\",\"args\":{\"command\":\"echo hi\"}}]}",
    );
    defer env.clearOverrides();

    var h = try LiveHarness.init(alloc, root);
    defer h.deinit();
    // Force `manual` approval so a MEDIUM-risk shell call is NOT auto-approved
    // by the default tiered-auto tier logic -- it must reach the relay.
    alloc.free(h.cfg.approval_mode);
    h.cfg.approval_mode = try alloc.dupe(u8, "manual");

    var host = ScriptedHost.init(alloc);
    defer host.deinit();
    host.decision = "allow";
    try host.queue("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"run echo hi\"}}");

    var rc = h.runContext();
    rc.caps.max_turns = 2;
    const Session = StreamSession(*ScriptedHost, *ScriptedHost);
    var session = Session.init(rc, &host, &host, .json);
    defer session.deinit();
    try session.run();

    // The CLI emitted a can_use_tool control_request and the host answered it.
    try testing.expect(std.mem.indexOf(u8, host.out.items, "\"subtype\":\"can_use_tool\"") != null);
    try testing.expect(host.answered >= 1);

    // headless-sdk-01: the can_use_tool request carries the REAL dispatched
    // tool name/input, never the old hardcoded "\"tool_name\":\"\",\"input\":{}".
    try testing.expect(std.mem.indexOf(u8, host.out.items, "\"tool_name\":\"\"") == null);
    try testing.expect(std.mem.indexOf(u8, host.out.items, "\"command\":\"echo hi\"") != null);

    // A `result` line came back for the turn.
    try testing.expect(std.mem.indexOf(u8, host.out.items, "\"type\":\"result\"") != null);

    // headless-sdk-07: the tool call was allowed (not denied), so this turn's
    // permission_denials is empty.
    if (std.mem.indexOf(u8, host.out.items, "\"type\":\"result\"")) |at| {
        const rest = host.out.items[at..];
        const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        try testing.expect(std.mem.indexOf(u8, rest[0..line_end], "\"permission_denials\":[]") != null);
    }
}

test "LIVE: a deny control_response drives the gate to block the tool" {
    const alloc = testing.allocator;
    const env = @import("../core/env.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    try env.setOverride(
        "ZCODE_MOCK_RESPONSE",
        "{\"assistant\":\"running a command\",\"tool_calls\":[{\"name\":\"shell\",\"args\":{\"command\":\"echo hi\"}}]}",
    );
    defer env.clearOverrides();

    var h = try LiveHarness.init(alloc, root);
    defer h.deinit();
    alloc.free(h.cfg.approval_mode);
    h.cfg.approval_mode = try alloc.dupe(u8, "manual");

    var host = ScriptedHost.init(alloc);
    defer host.deinit();
    host.decision = "deny"; // the host denies the permission
    try host.queue("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"run echo hi\"}}");

    var rc = h.runContext();
    rc.caps.max_turns = 2;
    const Session = StreamSession(*ScriptedHost, *ScriptedHost);
    var session = Session.init(rc, &host, &host, .json);
    defer session.deinit();
    try session.run();

    // The relay emitted the can_use_tool request and the host answered (deny);
    // the gate honored the deny so the tool did not execute. A `result` line
    // still comes back (the turn completes after the denial).
    try testing.expect(std.mem.indexOf(u8, host.out.items, "\"subtype\":\"can_use_tool\"") != null);
    try testing.expect(host.answered >= 1);
    try testing.expect(std.mem.indexOf(u8, host.out.items, "\"type\":\"result\"") != null);

    // headless-sdk-07: the denied call surfaces in permission_denials with
    // the real tool_name and `tool_input` (not the old `tool_use_input` key).
    try testing.expect(std.mem.indexOf(u8, host.out.items, "\"permission_denials\":[{") != null);
    try testing.expect(std.mem.indexOf(u8, host.out.items, "\"tool_input\":{\"command\":\"echo hi\"}") != null);
    try testing.expect(std.mem.indexOf(u8, host.out.items, "\"tool_use_input\"") == null);
}

test "LIVE: headless-sdk-16 -- commands_changed fires only after a real mid-session skill-list change" {
    const alloc = testing.allocator;
    const env = @import("../core/env.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    // Two plain no-tool-call turns -- the point is the skill list, not the
    // model's own text.
    try env.setOverride("ZCODE_MOCK_RESPONSE", "{\"assistant\":\"ok\",\"tool_calls\":[]}");
    defer env.clearOverrides();

    var h = try LiveHarness.init(alloc, root);
    defer h.deinit();

    var host = ScriptedHost.init(alloc);
    defer host.deinit();
    try host.queue("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"turn one\"}}");

    const rc = h.runContext();
    const Session = StreamSession(*ScriptedHost, *ScriptedHost);
    var session = Session.init(rc, &host, &host, .json);
    defer session.deinit();
    try session.run();

    // Turn 1 only seeds the baseline (nothing to have changed from yet).
    try testing.expect(std.mem.indexOf(u8, host.out.items, "commands_changed") == null);
    const out_len_after_turn_one = host.out.items.len;

    // Simulate a tool call having added a new skill mid-session (the
    // reference's own cited example: "skills discovered dynamically as the
    // agent works in a subdirectory") -- write it directly rather than
    // scripting a Write tool call, since the mechanism under test is the
    // POST-TURN detection, not the write itself.
    var cwd_dir = try std.Io.Dir.cwd().openDir(rt.io, root, .{});
    defer cwd_dir.close(rt.io);
    try cwd_dir.createDirPath(rt.io, ".zcode/skills/discovered-skill");
    try cwd_dir.writeFile(rt.io, .{
        .sub_path = ".zcode/skills/discovered-skill/SKILL.md",
        .data = "---\nname: discovered-skill\ndescription: found mid-session\n---\nBody.\n",
    });

    try host.queue("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"turn two\"}}");
    try session.run();

    const turn_two_output = host.out.items[out_len_after_turn_one..];
    try testing.expect(std.mem.indexOf(u8, turn_two_output, "\"type\":\"system\",\"subtype\":\"commands_changed\"") != null);
    try testing.expect(std.mem.indexOf(u8, turn_two_output, "discovered-skill") != null);
}

test "headless-sdk-12: --await-initialize errors instead of starting a turn when the first line is a plain user message" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var h = try LiveHarness.init(alloc, root);
    defer h.deinit();
    h.cfg.await_initialize = true;

    var host = ScriptedHost.init(alloc);
    defer host.deinit();
    try host.queue("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"turn one\"}}");

    const rc = h.runContext();
    const Session = StreamSession(*ScriptedHost, *ScriptedHost);
    var session = Session.init(rc, &host, &host, .json);
    defer session.deinit();

    try testing.expectError(error.AwaitInitializeFailed, session.run());
    // The turn never ran: no `result` (or anything else) was ever written.
    try testing.expectEqualStrings("", host.out.items);
}

test "headless-sdk-12: --await-initialize errors on EOF before any line arrives" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var h = try LiveHarness.init(alloc, root);
    defer h.deinit();
    h.cfg.await_initialize = true;

    var host = ScriptedHost.init(alloc);
    defer host.deinit();
    // No queued lines at all -> immediate EOF.

    const rc = h.runContext();
    const Session = StreamSession(*ScriptedHost, *ScriptedHost);
    var session = Session.init(rc, &host, &host, .json);
    defer session.deinit();

    try testing.expectError(error.AwaitInitializeFailed, session.run());
}

test "headless-sdk-12: --await-initialize errors on a malformed-JSON first line" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var h = try LiveHarness.init(alloc, root);
    defer h.deinit();
    h.cfg.await_initialize = true;

    var host = ScriptedHost.init(alloc);
    defer host.deinit();
    try host.queue("{not json");

    const rc = h.runContext();
    const Session = StreamSession(*ScriptedHost, *ScriptedHost);
    var session = Session.init(rc, &host, &host, .json);
    defer session.deinit();

    try testing.expectError(error.AwaitInitializeFailed, session.run());
}

test "headless-sdk-12: --await-initialize accepts a genuine initialize control_request as the first line, then proceeds normally" {
    const alloc = testing.allocator;
    const env = @import("../core/env.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    try env.setOverride("ZCODE_MOCK_RESPONSE", "{\"assistant\":\"ok\",\"tool_calls\":[]}");
    defer env.clearOverrides();

    var h = try LiveHarness.init(alloc, root);
    defer h.deinit();
    h.cfg.await_initialize = true;

    var host = ScriptedHost.init(alloc);
    defer host.deinit();
    try host.queue("{\"type\":\"control_request\",\"request_id\":\"init-1\",\"request\":{\"subtype\":\"initialize\"}}");
    try host.queue("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"turn one\"}}");

    const rc = h.runContext();
    const Session = StreamSession(*ScriptedHost, *ScriptedHost);
    var session = Session.init(rc, &host, &host, .json);
    defer session.deinit();

    try session.run();

    // The initialize control_request got its own control_response...
    try testing.expect(std.mem.indexOf(u8, host.out.items, "\"request_id\":\"init-1\"") != null);
    // ...and the turn that followed actually ran (a result line was emitted).
    try testing.expect(std.mem.indexOf(u8, host.out.items, "\"type\":\"result\"") != null);
}

test "LIVE headless-sdk-missed-183: initialize.systemPrompt/appendSystemPrompt genuinely mutate the live session (not a silent drop)" {
    const alloc = testing.allocator;
    const env = @import("../core/env.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    try env.setOverride("ZCODE_MOCK_RESPONSE", "{\"assistant\":\"ok\",\"tool_calls\":[]}");
    defer env.clearOverrides();

    var h = try LiveHarness.init(alloc, root);
    defer h.deinit();
    // Before: the fields an SDK host's initialize is supposed to override
    // start empty (this fixture's default Config never sets them).
    try testing.expectEqualStrings("", h.cfg.system_prompt_override);
    try testing.expectEqualStrings("", h.cfg.append_system_prompt);

    var host = ScriptedHost.init(alloc);
    defer host.deinit();
    try host.queue(
        "{\"type\":\"control_request\",\"request_id\":\"init-1\",\"request\":{\"subtype\":\"initialize\"," ++
            "\"systemPrompt\":\"You are a terse bot.\",\"appendSystemPrompt\":\"Always answer in one word.\"}}",
    );
    try host.queue("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"turn one\"}}");

    const rc = h.runContext();
    const Session = StreamSession(*ScriptedHost, *ScriptedHost);
    var session = Session.init(rc, &host, &host, .json);
    defer session.deinit();
    try session.run();

    // The control_response for `initialize` succeeded...
    try testing.expect(std.mem.indexOf(u8, host.out.items, "\"request_id\":\"init-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, host.out.items, "\"subtype\":\"success\"") != null);
    // ...and, unlike before this fix, the LIVE Config this session's turns
    // actually read from (prompt_engine.build() / prompt_helpers.zig, both
    // proven elsewhere to consume these exact fields on every turn) now
    // carries the host's real values -- not silently dropped.
    try testing.expectEqualStrings("You are a terse bot.", h.cfg.system_prompt_override);
    try testing.expectEqualStrings("Always answer in one word.", h.cfg.append_system_prompt);
    // And the turn that followed still ran to completion.
    try testing.expect(std.mem.indexOf(u8, host.out.items, "\"type\":\"result\"") != null);
}

test "LIVE: stream-json control_request set_model mutates the live runtime and replies success" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var h = try LiveHarness.init(alloc, root);
    defer h.deinit();

    var host = ScriptedHost.init(alloc);
    defer host.deinit();
    // A user turn (to build the runtime), then a set_model control_request.
    try host.queue("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}");
    host.decision = "deny"; // deny the mock's tool so the turn ends quickly
    try host.queue("{\"type\":\"control_request\",\"request_id\":\"r-model\",\"request\":{\"subtype\":\"set_model\",\"model\":\"swapped-model\"}}");

    const Session = StreamSession(*ScriptedHost, *ScriptedHost);
    var session = Session.init(h.runContext(), &host, &host, .json);
    defer session.deinit();
    try session.run();

    // The set_model produced a success control_response for r-model.
    try testing.expect(std.mem.indexOf(u8, host.out.items, "\"request_id\":\"r-model\"") != null);
    try testing.expect(std.mem.indexOf(u8, host.out.items, "\"subtype\":\"success\"") != null);
    // The live runtime's active model was swapped.
    try testing.expect(session.runtime != null);
    try testing.expectEqualStrings("swapped-model", session.runtime.?.active_model);
}

test "LIVE: a user message's top-level uuid is echoed as user_message_uuid (missed-186)" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var h = try LiveHarness.init(alloc, root);
    defer h.deinit();

    var host = ScriptedHost.init(alloc);
    defer host.deinit();
    try host.queue("{\"type\":\"user\",\"uuid\":\"client-side-uuid-1\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}");

    const Session = StreamSession(*ScriptedHost, *ScriptedHost);
    var session = Session.init(h.runContext(), &host, &host, .json);
    defer session.deinit();
    try session.run();

    try testing.expect(std.mem.indexOf(u8, host.out.items, "\"user_message_uuid\":\"client-side-uuid-1\"") != null);
}

test "LIVE: stream-json control_request mcp_status replies success with an mcpServers array (headless-sdk-11)" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var h = try LiveHarness.init(alloc, root);
    defer h.deinit();

    var host = ScriptedHost.init(alloc);
    defer host.deinit();
    try host.queue("{\"type\":\"control_request\",\"request_id\":\"r-mcp\",\"request\":{\"subtype\":\"mcp_status\"}}");

    const Session = StreamSession(*ScriptedHost, *ScriptedHost);
    var session = Session.init(h.runContext(), &host, &host, .json);
    defer session.deinit();
    try session.run();

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, std.mem.trimEnd(u8, host.out.items, "\n"), .{});
    defer parsed.deinit();
    const resp = parsed.value.object.get("response").?.object;
    try testing.expectEqualStrings("success", resp.get("subtype").?.string);
    try testing.expectEqualStrings("r-mcp", resp.get("request_id").?.string);
    // No configured MCP servers in this fixture -> an empty array, not an
    // "unsupported subtype" error (the previous behavior).
    try testing.expectEqual(@as(usize, 0), resp.get("response").?.object.get("mcpServers").?.array.items.len);
}

test "LIVE headless-sdk-11: rewind_files with an unknown user_message_id errors, naming it" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var h = try LiveHarness.init(alloc, root);
    defer h.deinit();

    var host = ScriptedHost.init(alloc);
    defer host.deinit();
    try host.queue("{\"type\":\"control_request\",\"request_id\":\"r-rw\",\"request\":{\"subtype\":\"rewind_files\",\"user_message_id\":\"no-such-id\"}}");

    const Session = StreamSession(*ScriptedHost, *ScriptedHost);
    var session = Session.init(h.runContext(), &host, &host, .json);
    defer session.deinit();
    try session.run();

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, std.mem.trimEnd(u8, host.out.items, "\n"), .{});
    defer parsed.deinit();
    const resp = parsed.value.object.get("response").?.object;
    try testing.expectEqualStrings("error", resp.get("subtype").?.string);
    try testing.expect(std.mem.indexOf(u8, resp.get("error").?.string, "no-such-id") != null);
}

test "LIVE headless-sdk-11: rewind_files missing user_message_id errors" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var h = try LiveHarness.init(alloc, root);
    defer h.deinit();

    var host = ScriptedHost.init(alloc);
    defer host.deinit();
    try host.queue("{\"type\":\"control_request\",\"request_id\":\"r-rw2\",\"request\":{\"subtype\":\"rewind_files\"}}");

    const Session = StreamSession(*ScriptedHost, *ScriptedHost);
    var session = Session.init(h.runContext(), &host, &host, .json);
    defer session.deinit();
    try session.run();

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, std.mem.trimEnd(u8, host.out.items, "\n"), .{});
    defer parsed.deinit();
    const resp = parsed.value.object.get("response").?.object;
    try testing.expectEqualStrings("error", resp.get("subtype").?.string);
    try testing.expect(std.mem.indexOf(u8, resp.get("error").?.string, "user_message_id") != null);
}

test "LIVE headless-sdk-11: rewind_files dry_run reports without mutating history" {
    const alloc = testing.allocator;
    const env = @import("../core/env.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    try env.setOverride("ZCODE_MOCK_RESPONSE", "{\"assistant\":\"ok\",\"tool_calls\":[]}");
    defer env.clearOverrides();

    var h = try LiveHarness.init(alloc, root);
    defer h.deinit();

    var host = ScriptedHost.init(alloc);
    defer host.deinit();
    // A real turn, tagged with a client-supplied uuid (the reference's
    // actual `user_message_id` semantics -- missed-186), then a dry-run
    // rewind_files naming it.
    try host.queue("{\"type\":\"user\",\"uuid\":\"client-uuid-dry\",\"message\":{\"role\":\"user\",\"content\":\"turn one\"}}");
    try host.queue("{\"type\":\"control_request\",\"request_id\":\"r-rw3\",\"request\":{\"subtype\":\"rewind_files\",\"user_message_id\":\"client-uuid-dry\",\"dry_run\":true}}");

    const Session = StreamSession(*ScriptedHost, *ScriptedHost);
    var session = Session.init(h.runContext(), &host, &host, .json);
    defer session.deinit();
    try session.run();

    const history_len_after = session.runtime.?.history.len();
    try testing.expect(history_len_after > 0);

    // Find the rewind_files control_response specifically (the output also
    // carries the turn's own assistant/result lines).
    var it = std.mem.splitScalar(u8, host.out.items, '\n');
    var found = false;
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.indexOf(u8, line, "\"request_id\":\"r-rw3\"") == null) continue;
        found = true;
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
        defer parsed.deinit();
        const resp = parsed.value.object.get("response").?.object;
        try testing.expectEqualStrings("success", resp.get("subtype").?.string);
        try testing.expect(resp.get("response").?.object.get("dry_run").?.bool);
        try testing.expect(std.mem.indexOf(u8, resp.get("response").?.object.get("message").?.string, "dry run") != null);
    }
    try testing.expect(found);
    // dry_run must never mutate: history is exactly as the turn left it.
    try testing.expectEqual(history_len_after, session.runtime.?.history.len());
}

test "LIVE headless-sdk-11: rewind_files with no checkpoint falls back to a real conversation-only truncation" {
    const alloc = testing.allocator;
    const env = @import("../core/env.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    try env.setOverride("ZCODE_MOCK_RESPONSE", "{\"assistant\":\"ok\",\"tool_calls\":[]}");
    defer env.clearOverrides();

    var h = try LiveHarness.init(alloc, root);
    defer h.deinit();

    var host = ScriptedHost.init(alloc);
    defer host.deinit();
    try host.queue("{\"type\":\"user\",\"uuid\":\"client-uuid-real\",\"message\":{\"role\":\"user\",\"content\":\"turn one\"}}");
    try host.queue("{\"type\":\"control_request\",\"request_id\":\"r-rw4\",\"request\":{\"subtype\":\"rewind_files\",\"user_message_id\":\"client-uuid-real\"}}");

    const Session = StreamSession(*ScriptedHost, *ScriptedHost);
    var session = Session.init(h.runContext(), &host, &host, .json);
    defer session.deinit();
    try session.run();

    // No checkpoint exists in this fixture (nothing ever created one), so
    // the REAL fallback path ran: the conversation was actually truncated
    // back to (and including) the user's own turn -- a genuine mutation,
    // not a canned response. Confirmed by re-checking the live runtime's
    // history length is now zero (the user turn itself, at index 0, was the
    // rewind target and got dropped along with everything after it).
    try testing.expectEqual(@as(usize, 0), session.runtime.?.history.len());

    var it = std.mem.splitScalar(u8, host.out.items, '\n');
    var found = false;
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.indexOf(u8, line, "\"request_id\":\"r-rw4\"") == null) continue;
        found = true;
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
        defer parsed.deinit();
        const resp = parsed.value.object.get("response").?.object;
        try testing.expectEqualStrings("success", resp.get("subtype").?.string);
        try testing.expect(!resp.get("response").?.object.get("dry_run").?.bool);
        try testing.expect(std.mem.indexOf(u8, resp.get("response").?.object.get("message").?.string, "no checkpoint found") != null);
    }
    try testing.expect(found);
}
