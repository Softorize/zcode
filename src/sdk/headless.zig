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
};

/// Everything a headless turn needs that is not part of the transport: the
/// scaffolding the dispatcher builds an AgentRuntime from. main.zig owns these
/// objects (the same ones it passes to runInteractive / runOneShot).
pub const RunContext = struct {
    allocator: std.mem.Allocator,
    cwd: []const u8,
    cfg: *const config_mod.Config,
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

/// Run exactly one headless turn against a freshly-built runtime and map the
/// outcome to an SDK `result`. The returned struct's allocator-owned fields
/// (`session_id`, `result_text`, `model`, `structured_output_json`) are freed
/// with `freeResult`. `relay` (when non-null) is installed as the runtime's
/// `sdk_relay` so tool-permission decisions are relayed to the host instead of
/// auto-denied; the relay's `pending_*` fields are refreshed before the turn so
/// its `can_use_tool` requests carry context.
///
/// This is the single-turn core shared by all three live paths; the stream-json
/// input loop calls it once per `user` message.
fn runTurn(
    rc: RunContext,
    prompt: []const u8,
    relay: ?agent_runtime.ApprovalHandler,
) !output.Result {
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

    return .{
        .subtype = subtype,
        .session_id = try allocator.dupe(u8, runtime.session_id),
        .result_text = try allocator.dupe(u8, result.final_text),
        .num_turns = result.rounds,
        .total_cost_usd = est_cost,
        .usage = usage,
        .model = try allocator.dupe(u8, runtime.active_model),
        .stop_reason = stop_reason,
        .structured_output_json = if (rc.caps.json_schema) |s| try allocator.dupe(u8, s) else "",
    };
}

/// Free the allocator-owned fields of a result returned by runTurn.
pub fn freeResult(allocator: std.mem.Allocator, result: *output.Result) void {
    allocator.free(result.session_id);
    allocator.free(result.result_text);
    allocator.free(result.model);
    if (result.structured_output_json.len > 0) allocator.free(result.structured_output_json);
}

/// Build the `system:init` info for a session, gathering the always-loaded tool
/// names and session metadata. The returned InitInfo borrows from the caller's
/// owned strings (cwd / model / permission_mode / session_id) and from the
/// static tool-name table; it must not outlive them. `tools_buf` is filled with
/// borrowed tool-name slices and must stay alive as long as the InitInfo is
/// serialized.
pub fn buildInit(
    session_id: []const u8,
    model: []const u8,
    permission_mode: []const u8,
    cwd: []const u8,
    tools_buf: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
) !output.InitInfo {
    for (tool_schemas.ALWAYS_LOADED_TOOL_NAMES) |name| {
        try tools_buf.append(allocator, name);
    }
    return messages.buildInit(.{
        .session_id = session_id,
        .model = model,
        .permission_mode = permission_mode,
        .cwd = cwd,
        .claude_code_version = build_options.app_version,
        .tools = tools_buf.items,
    });
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
    var result = try runTurn(rc, prompt, null);
    defer freeResult(allocator, &result);

    switch (format) {
        .text => unreachable, // text never reaches this module
        .json => {
            const line = try output.serializeResult(allocator, result, &.{});
            defer allocator.free(line);
            try writer.writeAll(line);
        },
        .stream_json => {
            var tools_buf: std.ArrayList([]const u8) = .empty;
            defer tools_buf.deinit(allocator);
            const info = try buildInit(
                result.session_id,
                result.model,
                permissionModeLabel(rc.cfg),
                rc.cwd,
                &tools_buf,
                allocator,
            );
            const init_line = try output.serializeInit(allocator, info);
            defer allocator.free(init_line);
            try writer.writeAll(init_line);

            // Emit the assistant message event between init and result,
            // matching the reference's stream-json sequence
            // (system:init -> assistant -> result).
            const request_id = try std.fmt.allocPrint(allocator, "req_{s}", .{result.session_id});
            defer allocator.free(request_id);
            const uuid = try std.fmt.allocPrint(allocator, "msg_{s}", .{result.session_id});
            defer allocator.free(uuid);
            const assistant_line = try output.serializeAssistant(
                allocator,
                result.session_id,
                result.result_text,
                request_id,
                uuid,
            );
            defer allocator.free(assistant_line);
            try writer.writeAll(assistant_line);

            const result_line = try output.serializeResult(allocator, result, &.{});
            defer allocator.free(result_line);
            try writer.writeAll(result_line);
        },
    }
}

/// The permission-mode label for the init message: the configured approval mode
/// (the live override is not yet set at session start). Borrows from cfg.
fn permissionModeLabel(cfg: *const config_mod.Config) []const u8 {
    return cfg.approval_mode;
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

        pub fn init(rc: RunContext, reader: Reader, writer: Writer, out_format: output.OutputFormat) Self {
            return .{ .rc = rc, .reader = reader, .writer = writer, .out_format = out_format };
        }

        pub fn deinit(self: *Self) void {
            if (self.last_text.len > 0) {
                self.rc.allocator.free(self.last_text);
                self.last_text = &.{};
            }
            if (self.runtime) |runtime| {
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
            if (self.rc.caps.max_turns) |mt| runtime.max_tool_rounds_override = mt;
            if (self.rc.caps.max_thinking_tokens) |tk| runtime.setReasoningTokens(@intCast(tk));
            if (self.rc.caps.json_schema) |schema| {
                runtime.pending_response_schema = try allocator.dupe(u8, schema);
            }
            // Install the relay: the gate calls relayPromptCb on the same thread
            // during a tool decision; relayPromptCb emits a can_use_tool request
            // and block-reads the host's control_response.
            runtime.sdk_relay = .{ .ctx = @ptrCast(self), .prompt = relayPromptCb };
            self.runtime = runtime;
            return runtime;
        }

        /// ApprovalPromptFn: emit a `can_use_tool` control_request to the host and
        /// block-read control_request/control_response lines until the matching
        /// decision arrives. `message` is the gate's human-readable tool
        /// description; it rides as `decision_reason` so the host has context.
        fn relayPromptCb(ctx: *anyopaque, message: []const u8) anyerror!types.ApprovalResponse {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const allocator = self.rc.allocator;

            // Build the inner can_use_tool request. We do not have the structured
            // tool name/input threaded through the gate (that would require
            // rewriting the turn loop), so the human-readable description rides
            // as decision_reason and tool_name is left to the host to infer; the
            // request still carries a stable shape.
            const request_json = try structured_io.buildCanUseToolRequest(
                allocator,
                "", // tool_name (not threaded through the gate)
                "{}",
                "",
                message,
                "[]",
            );
            defer allocator.free(request_json);

            // Generate a request_id, write the envelope, then block-read host
            // lines until a control_response for this id arrives.
            const req_id = try genRequestId(allocator);
            defer allocator.free(req_id);
            const envelope = try control.encodeRequest(allocator, req_id, request_json);
            defer allocator.free(envelope);
            try self.writeAll(envelope);

            return self.awaitDecision(req_id);
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
            try structured_io.runDispatchLoop(self.rc.allocator, self.reader, self.writer, .{
                .ctx = @ptrCast(self),
                .on_user = onUser,
                .on_control_request = onControlRequest,
                .on_update_env = onUpdateEnv,
            });
        }

        fn onUser(ctx: *anyopaque, prompt: []const u8) anyerror!void {
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
                var tools_buf: std.ArrayList([]const u8) = .empty;
                defer tools_buf.deinit(allocator);
                for (tool_schemas.ALWAYS_LOADED_TOOL_NAMES) |name| {
                    try tools_buf.append(allocator, name);
                }
                const info = messages.buildInit(.{
                    .session_id = runtime.session_id,
                    .model = runtime.active_model,
                    .permission_mode = self.rc.cfg.approval_mode,
                    .cwd = self.rc.cwd,
                    .claude_code_version = build_options.app_version,
                    .tools = tools_buf.items,
                });
                const init_line = try output.serializeInit(allocator, info);
                defer allocator.free(init_line);
                try self.writeAll(init_line);
                self.emitted_init = true;
            }

            const result = try self.runTurnOnRuntime(runtime, prompt);
            // Emit the assistant message event before the result, matching
            // the reference's stream-json sequence (system:init -> assistant -> result).
            const request_id = try std.fmt.allocPrint(self.rc.allocator, "req_{s}", .{result.session_id});
            defer self.rc.allocator.free(request_id);
            const uuid = try std.fmt.allocPrint(self.rc.allocator, "msg_{s}", .{result.session_id});
            defer self.rc.allocator.free(uuid);
            const assistant_line = try output.serializeAssistant(
                self.rc.allocator,
                result.session_id,
                result.result_text,
                request_id,
                uuid,
            );
            defer self.rc.allocator.free(assistant_line);
            try self.writeAll(assistant_line);
            const line = try output.serializeResult(allocator, result, &.{});
            defer allocator.free(line);
            try self.writeAll(line);
        }

        /// Run one turn on the persistent runtime and map it to an SDK result.
        /// Unlike runTurn (which builds + tears down a runtime), this reuses the
        /// session runtime so live-control mutations persist across turns. The
        /// returned result borrows runtime-owned slices (session_id / model);
        /// they are stable for the lifetime of the session, and the caller
        /// serializes the result immediately.
        fn runTurnOnRuntime(self: *Self, runtime: *AgentRuntime, prompt: []const u8) !output.Result {
            const allocator = self.rc.allocator;
            var tr = try runtime.handlePromptDetailed(prompt);
            defer tr.deinit(allocator);

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
            return .{
                .subtype = subtype,
                .session_id = runtime.session_id,
                .result_text = self.last_text,
                .num_turns = tr.rounds,
                .total_cost_usd = est_cost,
                .usage = usage,
                .model = runtime.active_model,
                .stop_reason = stop_reason,
                .structured_output_json = "",
            };
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
                    const resp = try structured_io.dispatchInitialize(
                        allocator,
                        raw,
                        &self.init_state,
                        .{ .ctx = @ptrCast(self) },
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
                else => {
                    // can_use_tool / hook_callback / elicitation are CLI->host
                    // (we originate them); a host sending them to us, or any
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

        /// writeAll shim so the relay/control responses go out through the
        /// session writer regardless of its concrete type.
        fn writeAll(self: *Self, bytes: []const u8) !void {
            try self.writer.writeAll(bytes);
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

    // A `result` line came back for the turn.
    try testing.expect(std.mem.indexOf(u8, host.out.items, "\"type\":\"result\"") != null);
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
