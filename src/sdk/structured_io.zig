//! sdk-headless-03: `--input-format stream-json` streaming stdin.
//!
//! Reads `SDKUserMessage` and control-protocol lines from stdin as a
//! newline-delimited JSON stream, enabling multi-turn and live control over a
//! single running process. This is the transport the bidirectional control
//! protocol (sdk-headless-04/05/06) rides on; this task builds only the
//! transport (the bounded read loop + the line dispatcher), leaving the
//! control-request/response handling to callbacks the later tasks plug in.
//!
//! Reference behavior + file:line:
//!   main.tsx:976           Option('--input-format <format>').choices(['text','stream-json'])
//!   cli/structuredIO.ts    read()/processLine() parse the StdinMessage union
//!   controlSchemas.ts:655  StdinMessageSchema =
//!       SDKUserMessage | SDKControlRequest | SDKControlResponse
//!       | keep_alive | update_environment_variables
//!
//! Structural template: api_server.zig:286-331 (the per-line cap / per-stream
//! total cap / readUntilDelimiterOrEofAlloc loop). We reuse the bounded-read
//! discipline, not the JSON-RPC protocol.
//!
//! Concurrency note: zcode is synchronous one-turn today. The dispatcher runs
//! each `user` turn to completion (via the supplied callback) before reading
//! the next stdin line, which is the key behavioral difference from the
//! one-shot `run`/`exec` path that exits after a single turn. Live control
//! subtypes (interrupt etc.) that need to act mid-turn arrive through the
//! control-request callback and are sequenced by the later tasks; this module
//! only routes them.

const std = @import("std");
const std_io = @import("../core/std_io.zig");
const types = @import("../core/types.zig");
const control = @import("control.zig");
const env = @import("../core/env.zig");
const output = @import("output.zig");

/// The two `--input-format` choices. `stream_json` is spelled with an
/// underscore in Zig but parses from / renders to the hyphenated wire token
/// `stream-json` (matching the output.zig OutputFormat convention).
pub const InputFormat = enum {
    text,
    stream_json,

    /// Render back to the wire token (hyphenated for stream-json).
    pub fn toString(self: InputFormat) []const u8 {
        return switch (self) {
            .text => "text",
            .stream_json => "stream-json",
        };
    }

    /// Parse a raw `--input-format` value. Accepts `text`, `stream-json`.
    /// Returns error.UnknownInputFormat for anything else, after printing a
    /// usage line in the style of args.zig's other format flags so the caller
    /// can fail fast.
    pub fn parse(value: []const u8) error{UnknownInputFormat}!InputFormat {
        if (std.mem.eql(u8, value, "text")) return .text;
        if (std.mem.eql(u8, value, "stream-json")) return .stream_json;
        std_io.stderrWriter().print(
            "error: --input-format: unknown format '{s}'. Valid formats: text, stream-json.\n",
            .{value},
        ) catch {};
        return error.UnknownInputFormat;
    }
};

/// The members of the `StdinMessage` union, keyed by the line's `type` field.
/// `unknown` is the fall-through for a well-formed JSON object whose `type` is
/// none of the recognized members (routed to the diverter, not crashed).
pub const StdinMessageKind = enum {
    user,
    control_request,
    control_response,
    keep_alive,
    update_environment_variables,
    unknown,

    pub fn fromTypeString(s: []const u8) StdinMessageKind {
        if (std.mem.eql(u8, s, "user")) return .user;
        if (std.mem.eql(u8, s, "control_request")) return .control_request;
        if (std.mem.eql(u8, s, "control_response")) return .control_response;
        if (std.mem.eql(u8, s, "keep_alive")) return .keep_alive;
        if (std.mem.eql(u8, s, "update_environment_variables")) return .update_environment_variables;
        return .unknown;
    }
};

/// A classified stdin line. `kind` is the union member; `prompt` is the
/// extracted user-turn text (only set for `.user`, borrowing from `arena`).
/// The caller deinits `arena` to free everything the classification borrows.
pub const ClassifiedLine = struct {
    kind: StdinMessageKind,
    prompt: []const u8 = "",
    arena: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *ClassifiedLine) void {
        self.arena.deinit();
    }
};

/// Parse one NDJSON line and classify it. Returns error.MalformedLine for a
/// non-JSON line or a JSON value that is not an object, and
/// error.MissingType when the object lacks a string `type`. The dispatcher
/// converts these into a diverted error envelope rather than crashing.
pub fn classifyLine(allocator: std.mem.Allocator, line: []const u8) !ClassifiedLine {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
        return error.MalformedLine;
    };
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.MalformedLine;

    // Take the object by pointer (CLAUDE.md ObjectMap rule): a value-copy out
    // of the parsed tree desyncs the entries pointer on a later realloc.
    const obj = &parsed.value.object;
    const type_val = obj.get("type") orelse return error.MissingType;
    if (type_val != .string) return error.MissingType;
    const kind = StdinMessageKind.fromTypeString(type_val.string);

    var prompt: []const u8 = "";
    if (kind == .user) prompt = extractUserPrompt(obj);

    return .{ .kind = kind, .prompt = prompt, .arena = parsed };
}

/// Pull the prompt text out of an SDKUserMessage object. The reference shape is
/// `{type:"user", message:{role:"user", content: <string|array>}}`. We accept
/// either a plain string content or an array of content blocks, concatenating
/// the `text` field of each `{type:"text", text:...}` block. Returns an empty
/// slice when no text can be recovered (the dispatcher still enqueues a turn so
/// the caller can decide how to treat an empty prompt). The returned slice
/// borrows from the parsed tree.
fn extractUserPrompt(obj: *const std.json.ObjectMap) []const u8 {
    const message = obj.get("message") orelse return "";
    if (message != .object) return "";
    const content = message.object.get("content") orelse return "";
    switch (content) {
        .string => |s| return s,
        .array => |arr| {
            // Return the first text block's text. Multi-block concatenation is
            // not needed for the transport layer; the turn callback receives a
            // single prompt string. The common SDK case is a single text block.
            for (arr.items) |block| {
                if (block != .object) continue;
                const btype = block.object.get("type") orelse continue;
                if (btype != .string or !std.mem.eql(u8, btype.string, "text")) continue;
                const btext = block.object.get("text") orelse continue;
                if (btext == .string) return btext.string;
            }
            return "";
        },
        else => return "",
    }
}

/// Per-line cap (1 MiB) keeps a single malformed line bounded; per-stream total
/// cap (10 MiB) caps the whole stream so a hostile producer cannot drive memory
/// use arbitrarily high. Mirrors api_server.zig:297-298.
pub const LINE_CAP: usize = 1024 * 1024;
pub const TOTAL_CAP: usize = 10 * 1024 * 1024;

/// Callbacks the dispatcher invokes per line kind. The transport layer owns the
/// read loop and classification; the turn execution and the control protocol
/// live behind these hooks so the later tasks (sdk-headless-04/05/06/13) plug
/// their handlers in without this module depending on them.
///
/// `ctx` is an opaque pointer threaded to every callback. A null callback means
/// "ignore this kind" (e.g. keep_alive is a no-op until sdk-headless-13 wires a
/// handler; an unhandled control_request is simply skipped here).
pub const Handlers = struct {
    ctx: *anyopaque,
    /// Run one user turn to completion. `prompt` borrows from the line's parse
    /// arena and is only valid for the duration of the call.
    on_user: ?*const fn (ctx: *anyopaque, prompt: []const u8) anyerror!void = null,
    /// Route a control_request line (raw JSON) to the control dispatcher.
    on_control_request: ?*const fn (ctx: *anyopaque, raw: []const u8) anyerror!void = null,
    /// Resolve a pending CLI-originated request from a control_response line.
    on_control_response: ?*const fn (ctx: *anyopaque, raw: []const u8) anyerror!void = null,
    /// keep_alive: no-op by default (sdk-headless-13 may attach a handler).
    on_keep_alive: ?*const fn (ctx: *anyopaque) anyerror!void = null,
    /// update_environment_variables: apply key/values (sdk-headless-13).
    on_update_env: ?*const fn (ctx: *anyopaque, raw: []const u8) anyerror!void = null,
};

/// Drive a streaming-stdin session: read NDJSON lines from `reader`, classify
/// each, and dispatch via `handlers`. Diverts malformed/unrecognized lines to
/// `writer` as a tagged error envelope (NDJSON, newline-terminated) without
/// crashing, then continues. After a `user` turn completes the loop reads the
/// next line rather than exiting (multi-turn).
///
/// `reader` must expose `readUntilDelimiterOrEofAlloc(allocator, '\n', max)`
/// returning `?[]u8` (std_io.StdinReader and the test FixedReader both do), so
/// tests can feed a fixed buffer instead of real stdin. `writer` must expose
/// `writeAll([]const u8)`.
pub fn runDispatchLoop(
    allocator: std.mem.Allocator,
    reader: anytype,
    writer: anytype,
    handlers: Handlers,
) !void {
    var total_bytes: usize = 0;
    while (true) {
        const line_opt = reader.readUntilDelimiterOrEofAlloc(allocator, '\n', LINE_CAP) catch |err| switch (err) {
            error.StreamTooLong => {
                try writer.writeAll("{\"type\":\"error\",\"error\":\"InputLineTooLarge\",\"limit_bytes\":1048576}\n");
                break;
            },
            else => return err,
        };
        defer if (line_opt) |line| allocator.free(line);
        const line = line_opt orelse break;

        total_bytes += line.len + 1; // +1 for the delimiter byte
        if (total_bytes > TOTAL_CAP) {
            try writer.writeAll("{\"type\":\"error\",\"error\":\"InputStreamTooLarge\",\"limit_bytes\":10485760}\n");
            break;
        }

        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue; // skip blank lines

        try dispatchLine(allocator, trimmed, writer, handlers);
    }
}

/// Classify and dispatch a single (already-trimmed, non-empty) line. Malformed
/// or unrecognized lines are diverted to `writer` and the loop continues.
pub fn dispatchLine(
    allocator: std.mem.Allocator,
    trimmed: []const u8,
    writer: anytype,
    handlers: Handlers,
) !void {
    var classified = classifyLine(allocator, trimmed) catch |err| switch (err) {
        error.MalformedLine, error.MissingType => {
            try divertBadLine(writer, @errorName(err));
            return;
        },
    };
    defer classified.deinit();

    switch (classified.kind) {
        .user => {
            if (handlers.on_user) |cb| try cb(handlers.ctx, classified.prompt);
        },
        .control_request => {
            if (handlers.on_control_request) |cb| try cb(handlers.ctx, trimmed);
        },
        .control_response => {
            if (handlers.on_control_response) |cb| try cb(handlers.ctx, trimmed);
        },
        .keep_alive => {
            if (handlers.on_keep_alive) |cb| try cb(handlers.ctx);
        },
        .update_environment_variables => {
            if (handlers.on_update_env) |cb| try cb(handlers.ctx, trimmed);
        },
        .unknown => {
            // A well-formed object with an unrecognized `type`. Divert rather
            // than crash so the producer's NDJSON parser is never broken by a
            // silent drop; the reference logs+ignores unknown stdin messages.
            try divertBadLine(writer, "UnknownStdinMessageType");
        },
    }
}

/// Emit a single NDJSON error envelope for a diverted line. Kept minimal: the
/// reason name only, never echoing the offending bytes (they may be large or
/// contain secrets).
fn divertBadLine(writer: anytype, reason: []const u8) !void {
    try writer.writeAll("{\"type\":\"error\",\"error\":\"MalformedStdinLine\",\"reason\":\"");
    try writer.writeAll(reason);
    try writer.writeAll("\"}\n");
}

// --- sdk-headless-05: can_use_tool permission relay -------------------------
//
// When a tool needs permission and the session is host-driven (input-format
// stream-json), the permission decision is NOT made locally (stdin prompt or
// auto-deny). Instead the CLI emits a `can_use_tool` `control_request` to the
// host carrying the tool name, input, tool_use_id, decision_reason, and any
// permission suggestions, then awaits the host's `control_response` decision
// and maps it to a `types.ApprovalResponse`.
//
// Reference behavior + file:line:
//   controlSchemas.ts:106  SDKControlPermissionRequestSchema
//   structuredIO.ts:533    createCanUseTool() -> Promise.race(hookPromise, sdkPromise)
//   structuredIO.ts:178    resolvedToolUseIds orphan/duplicate dedup
//
// Concurrency model: zcode is synchronous one-turn today (see the control.zig
// note), so the relay does NOT block a fiber. The relay calls the supplied
// `Dispatcher`, which is responsible for writing the request envelope to the
// host AND pumping the stdin stream until the matching `control_response`
// arrives (or a cancel is emitted), returning the resolved decision. The real
// dispatcher (wired by the stream-json session loop) drives the control.zig
// PendingMap state machine; tests supply a stub dispatcher feeding pre-canned
// responses, so every transition is synchronously testable.

/// The host's decision for a `can_use_tool` request. The relay maps `.allow`
/// to ApprovalResponse.approve and `.deny`/`.cancel` to ApprovalResponse.deny.
/// (zcode has no separate "approve for the session" host decision today; the
/// host can re-allow each call, so `.allow` maps to the single-shot approve.)
pub const RelayDecision = enum { allow, deny, cancel };

/// A type-erased channel that sends a `can_use_tool` control_request to the
/// host and returns the host's decision. `request_json` is the inner `request`
/// object as raw JSON (already a valid object whose first field is the
/// subtype). The dispatcher owns writing the envelope, correlating the
/// response by request_id, and pumping the stream until it resolves. Returning
/// `error.RelayUnavailable` (or any error) makes the relay deny safely.
pub const Dispatcher = struct {
    ctx: *anyopaque,
    requestFn: *const fn (ctx: *anyopaque, request_json: []const u8) anyerror!RelayDecision,

    fn request(self: Dispatcher, request_json: []const u8) anyerror!RelayDecision {
        return self.requestFn(self.ctx, request_json);
    }
};

/// Bound on the resolved-`tool_use_id` dedup set, mirroring the reference's
/// MAX_RESOLVED_TOOL_USE_IDS. A late/duplicate host response for an id already
/// resolved is ignored. We keep the set bounded so a long-lived session cannot
/// grow it without limit; when full, the oldest id is evicted (ring buffer).
pub const MAX_RESOLVED_TOOL_USE_IDS: usize = 1000;

/// Drives a single `can_use_tool` permission request over the host relay and
/// dedups by `tool_use_id`. One approver lives per host-driven session; its
/// `handler()` slots into the runtime's ApprovalHandler precedence ahead of the
/// stdin prompt (see agent_tools.effectiveApproval).
pub const RelayApprover = struct {
    allocator: std.mem.Allocator,
    dispatcher: Dispatcher,
    /// Ring of already-resolved tool_use_ids (owned, duped). A repeat request
    /// for an id in here is treated as already-decided -> deny (the host
    /// already answered once; a duplicate is a protocol artifact we ignore
    /// rather than re-prompting). Mirrors structuredIO.ts:178 dedup intent.
    resolved_ids: std.ArrayList([]u8) = .empty,
    next_evict: usize = 0,

    /// Fields describing the in-flight request, set by the caller right before
    /// invoking the ApprovalPromptFn (which only receives `message`). The
    /// runtime sets these from the tool gate; tests set them directly. All
    /// borrowed for the duration of the call.
    pending_tool_name: []const u8 = "",
    pending_input_json: []const u8 = "{}",
    pending_tool_use_id: []const u8 = "",
    pending_decision_reason: []const u8 = "",
    /// Raw JSON array of permission suggestions, or "[]" when none. Embedded
    /// verbatim into the request envelope.
    pending_permission_suggestions: []const u8 = "[]",

    pub fn init(allocator: std.mem.Allocator, dispatcher: Dispatcher) RelayApprover {
        return .{ .allocator = allocator, .dispatcher = dispatcher };
    }

    pub fn deinit(self: *RelayApprover) void {
        for (self.resolved_ids.items) |id| self.allocator.free(id);
        self.resolved_ids.deinit(self.allocator);
    }

    /// True when `tool_use_id` has already been resolved this session.
    fn alreadyResolved(self: *const RelayApprover, tool_use_id: []const u8) bool {
        if (tool_use_id.len == 0) return false;
        for (self.resolved_ids.items) |id| {
            if (std.mem.eql(u8, id, tool_use_id)) return true;
        }
        return false;
    }

    /// Record `tool_use_id` as resolved (bounded ring; evicts oldest when full).
    fn markResolved(self: *RelayApprover, tool_use_id: []const u8) !void {
        if (tool_use_id.len == 0) return;
        const dup = try self.allocator.dupe(u8, tool_use_id);
        errdefer self.allocator.free(dup);
        if (self.resolved_ids.items.len < MAX_RESOLVED_TOOL_USE_IDS) {
            try self.resolved_ids.append(self.allocator, dup);
        } else {
            // Ring eviction: free and overwrite the oldest slot.
            const slot = self.next_evict % self.resolved_ids.items.len;
            self.allocator.free(self.resolved_ids.items[slot]);
            self.resolved_ids.items[slot] = dup;
            self.next_evict = slot + 1;
        }
    }

    /// Build the inner `can_use_tool` request object (raw JSON), send it via the
    /// dispatcher, map the host decision to an ApprovalResponse, and dedup by
    /// tool_use_id. A duplicate id (already resolved) is ignored -> deny without
    /// re-prompting the host. Any dispatcher error denies safely.
    pub fn requestPermission(
        self: *RelayApprover,
        tool_name: []const u8,
        input_json: []const u8,
        tool_use_id: []const u8,
        decision_reason: []const u8,
        permission_suggestions: []const u8,
    ) !types.ApprovalResponse {
        // Duplicate/late request for an already-resolved id: ignore (deny).
        if (self.alreadyResolved(tool_use_id)) return .deny;

        const request_json = try buildCanUseToolRequest(
            self.allocator,
            tool_name,
            input_json,
            tool_use_id,
            decision_reason,
            permission_suggestions,
        );
        defer self.allocator.free(request_json);

        const decision = self.dispatcher.request(request_json) catch {
            // The host channel failed; fail safe (deny) and do not record the
            // id (so a retry can still reach the host).
            return .deny;
        };

        // The host answered: record the id so a duplicate response is ignored.
        try self.markResolved(tool_use_id);

        return switch (decision) {
            .allow => .approve,
            .deny, .cancel => .deny,
        };
    }

    /// ApprovalPromptFn adapter so the relay slots into the runtime's
    /// ApprovalHandler (`struct { ctx: *anyopaque, prompt: ApprovalPromptFn }`,
    /// where ApprovalPromptFn == `fn (ctx: *anyopaque, message) -> ApprovalResponse`).
    /// The caller builds the handler as `.{ .ctx = approver.ctxPtr(), .prompt =
    /// RelayApprover.promptCb }`; this avoids importing the heavy agent_runtime
    /// module into the sdk layer (the signature already matches exactly). The
    /// `message` is the gate's human-readable tool description; the structured
    /// fields come from the `pending_*` fields the caller set before this call.
    pub fn promptCb(ctx: *anyopaque, message: []const u8) anyerror!types.ApprovalResponse {
        const self: *RelayApprover = @ptrCast(@alignCast(ctx));
        // Prefer an explicit decision_reason; fall back to the gate message.
        const reason = if (self.pending_decision_reason.len > 0)
            self.pending_decision_reason
        else
            message;
        return self.requestPermission(
            self.pending_tool_name,
            self.pending_input_json,
            self.pending_tool_use_id,
            reason,
            self.pending_permission_suggestions,
        );
    }

    /// Type-erased pointer to this approver, for the ApprovalHandler `ctx` slot.
    pub fn ctxPtr(self: *RelayApprover) *anyopaque {
        return @ptrCast(self);
    }
};

/// Build the inner `can_use_tool` `request` object as raw JSON. Carries the
/// reference fields (tool_name, input, tool_use_id, decision_reason,
/// permission_suggestions). `input_json` and `permission_suggestions` are
/// embedded verbatim (they are already valid JSON); the rest are escaped. The
/// caller owns the returned slice. (No trailing newline: this is the inner
/// `request` body that control.encodeRequest wraps.)
pub fn buildCanUseToolRequest(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    input_json: []const u8,
    tool_use_id: []const u8,
    decision_reason: []const u8,
    permission_suggestions: []const u8,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"subtype\":\"can_use_tool\",\"tool_name\":");
    try writeJsonString(w, tool_name);
    try w.writeAll(",\"input\":");
    // input_json is already a JSON value; default to {} when empty.
    try w.writeAll(if (input_json.len > 0) input_json else "{}");
    if (tool_use_id.len > 0) {
        try w.writeAll(",\"tool_use_id\":");
        try writeJsonString(w, tool_use_id);
    }
    if (decision_reason.len > 0) {
        try w.writeAll(",\"decision_reason\":");
        try writeJsonString(w, decision_reason);
    }
    try w.writeAll(",\"permission_suggestions\":");
    try w.writeAll(if (permission_suggestions.len > 0) permission_suggestions else "[]");
    try w.writeAll("}");
    return out.toOwnedSlice();
}

/// Minimal JSON string escaper (quotes, backslash, C0 controls). Mirrors the
/// escaper in sdk/control.zig. U+2028/U+2029 are handled when control.encode*
/// runs the whole line through appendNdjsonSafe, not here.
fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

// --- sdk-headless-10: one-time initialize handshake -------------------------
//
// The host opens a stream-json session with exactly one `initialize`
// control_request. This tiny state holder enforces that "exactly once":
// `dispatchInitialize` reads the current flag, lets control.dispatchInitialize
// decide success vs the "Already initialized" error, and flips the flag only on
// a success response. A second initialize then naturally takes the
// already-initialized branch. The session loop owns one of these per session;
// the control_request callback routes `initialize` subtypes here.

/// Tracks whether this session has already handled an `initialize` request.
pub const InitState = struct {
    initialized: bool = false,
};

/// Handle an `initialize` control_request line for a session. Decodes the
/// envelope, dispatches through control.dispatchInitialize (which rejects a
/// double-init with "Already initialized"), and on a *success* response flips
/// `state.initialized` so the next initialize is rejected. Returns the encoded
/// `control_response` line (NDJSON, newline-terminated; caller owns it).
///
/// `applier` applies the present request fields to the live session;
/// `response_data` supplies the registry data for the success response. Both are
/// the type-erased views control.zig defines so this transport layer stays free
/// of the heavy runtime/registry modules.
pub fn dispatchInitialize(
    allocator: std.mem.Allocator,
    line: []const u8,
    state: *InitState,
    applier: control.InitializeApplier,
    response_data: control.InitResponseData,
) ![]u8 {
    var decoded = try control.decodeRequest(allocator, line);
    defer decoded.deinit();

    const was_initialized = state.initialized;
    const resp = try control.dispatchInitialize(
        allocator,
        decoded.request,
        was_initialized,
        applier,
        response_data,
    );
    // Flip the one-time flag only when this call actually performed the
    // initialization (i.e. it was not already initialized). On the
    // already-initialized path the flag stays set and the error response stands.
    if (!was_initialized) state.initialized = true;
    return resp;
}

// --- sdk-headless-13: keep_alive / update_environment_variables ------------
//
// Two cheap stdin message types that do not run a turn:
//   keep_alive                   -> silently ignored (WebSocket liveness in the
//                                    reference; a no-op here).
//   update_environment_variables -> apply {key: value, ...} at runtime so the
//                                    running process sees refreshed values
//                                    (auth-token refresh is the reference use,
//                                    e.g. CLAUDE_CODE_SESSION_ACCESS_TOKEN).
//
// Reference behavior + file:line:
//   controlSchemas.ts:621  SDKKeepAliveMessageSchema {type:"keep_alive"}
//   controlSchemas.ts:629  SDKUpdateEnvironmentVariablesMessageSchema
//                          {type:"update_environment_variables", variables:{...}}
//   structuredIO.ts:344    keep_alive -> silently ignored
//   structuredIO.ts:348    apply variables to process.env, log the key NAMES
//                          (never the values, which may be secrets)
//
// zcode reads env via libc getenv, which cannot be mutated portably, so we
// route the updates into core/env.zig's in-process override map (consulted
// ahead of getenv) instead of touching the real environment.

/// Apply an `update_environment_variables` line: parse the `variables` object,
/// set each key/value in the env override map, and emit one log line naming the
/// applied keys (never their values -- they may be auth tokens). Returns the
/// number of variables applied. A malformed line, a missing/non-object
/// `variables` field, or a non-string value is a no-op for that entry; the line
/// as a whole is tolerated (returns the count actually applied) so a partly bad
/// message cannot crash the read loop.
///
/// `log_writer` must expose `writeAll([]const u8)`. Pass `std_io.stderrWriter()`
/// in production; tests pass a capturing writer so they can assert the log
/// contains key names and NOT values.
pub fn applyEnvUpdates(
    allocator: std.mem.Allocator,
    line: []const u8,
    log_writer: anytype,
) !usize {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
        return 0;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return 0;

    // Take by pointer (CLAUDE.md ObjectMap rule): a value-copy desyncs the
    // entries pointer on a later realloc.
    const obj = &parsed.value.object;
    const vars_val = obj.get("variables") orelse return 0;
    if (vars_val != .object) return 0;
    const vars = &vars_val.object;

    // First pass: apply each string-valued entry. Second pass (below) builds the
    // comma-joined key-name log so the line lists only what was actually set.
    var applied: usize = 0;
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(allocator);

    var it = vars.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (value != .string) continue; // skip non-string values
        try env.setOverride(key, value.string);
        try keys.append(allocator, key);
        applied += 1;
    }

    // Log the applied key NAMES only (no values). Matches structuredIO.ts:358.
    try log_writer.writeAll("[structuredIO] applied update_environment_variables: ");
    for (keys.items, 0..) |k, i| {
        if (i != 0) try log_writer.writeAll(", ");
        try log_writer.writeAll(k);
    }
    try log_writer.writeAll("\n");

    return applied;
}

/// Handler adapter for the dispatch loop's `on_update_env` hook: applies the
/// updates and logs key names to stderr. `ctx` carries the allocator. The
/// session loop installs this as `Handlers.on_update_env`.
pub const EnvUpdateHandler = struct {
    allocator: std.mem.Allocator,

    pub fn onUpdateEnv(ctx: *anyopaque, raw: []const u8) anyerror!void {
        const self: *EnvUpdateHandler = @ptrCast(@alignCast(ctx));
        _ = applyEnvUpdates(self.allocator, raw, std_io.stderrWriter()) catch {};
    }
};

const testing = std.testing;

// A fixed-buffer reader that mirrors the std_io.StdinReader line API so the
// dispatcher can be driven without real stdin.
const FixedReader = struct {
    data: []const u8,
    pos: usize = 0,

    fn readUntilDelimiterOrEofAlloc(self: *FixedReader, allocator: std.mem.Allocator, delim: u8, max: usize) !?[]u8 {
        if (self.pos >= self.data.len) return null;
        const start = self.pos;
        var i = start;
        while (i < self.data.len and self.data[i] != delim) : (i += 1) {}
        const span_len = i - start;
        if (span_len > max) return error.StreamTooLong;
        const out = try allocator.dupe(u8, self.data[start..i]);
        // Advance past the delimiter (if any).
        self.pos = if (i < self.data.len) i + 1 else i;
        return out;
    }
};

// A capturing writer that mirrors the std_io writer API (writeAll only).
const CaptureWriter = struct {
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    fn writeAll(self: CaptureWriter, bytes: []const u8) !void {
        try self.buf.appendSlice(self.allocator, bytes);
    }
};

// A turn recorder used as the handler ctx in tests.
const TurnRecorder = struct {
    allocator: std.mem.Allocator,
    prompts: std.ArrayList([]u8) = .empty,

    fn deinit(self: *TurnRecorder) void {
        for (self.prompts.items) |p| self.allocator.free(p);
        self.prompts.deinit(self.allocator);
    }

    fn onUser(ctx: *anyopaque, prompt: []const u8) anyerror!void {
        const self: *TurnRecorder = @ptrCast(@alignCast(ctx));
        try self.prompts.append(self.allocator, try self.allocator.dupe(u8, prompt));
    }
};

// sdk-headless-12: a handler ctx that, on each accepted user turn, re-emits the
// prompt as a `user` NDJSON line on the dispatcher's writer (the
// --replay-user-messages path). Models how the live dispatcher wires the replay
// when the flag is set.
const ReplayRecorder = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    session_id: []const u8,

    fn onUser(ctx: *anyopaque, prompt: []const u8) anyerror!void {
        const self: *ReplayRecorder = @ptrCast(@alignCast(ctx));
        const line = try output.serializeUserReplay(self.allocator, prompt, self.session_id);
        defer self.allocator.free(line);
        try self.out.appendSlice(self.allocator, line);
    }
};

test "InputFormat parses the two choices and rejects unknown" {
    try testing.expectEqual(InputFormat.text, try InputFormat.parse("text"));
    try testing.expectEqual(InputFormat.stream_json, try InputFormat.parse("stream-json"));
    try testing.expectError(error.UnknownInputFormat, InputFormat.parse("json"));
    try testing.expectError(error.UnknownInputFormat, InputFormat.parse(""));
    try testing.expectEqualStrings("stream-json", InputFormat.stream_json.toString());
    try testing.expectEqualStrings("text", InputFormat.text.toString());
}

test "classifyLine: a user message yields .user with the extracted prompt" {
    const allocator = testing.allocator;
    var classified = try classifyLine(
        allocator,
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hello there\"}}",
    );
    defer classified.deinit();
    try testing.expectEqual(StdinMessageKind.user, classified.kind);
    try testing.expectEqualStrings("hello there", classified.prompt);
}

test "classifyLine: array content blocks extract the text block" {
    const allocator = testing.allocator;
    var classified = try classifyLine(
        allocator,
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"block prompt\"}]}}",
    );
    defer classified.deinit();
    try testing.expectEqual(StdinMessageKind.user, classified.kind);
    try testing.expectEqualStrings("block prompt", classified.prompt);
}

test "classifyLine: control + keep_alive + env kinds classify by type" {
    const allocator = testing.allocator;
    {
        var c = try classifyLine(allocator, "{\"type\":\"control_request\",\"request_id\":\"r1\",\"request\":{\"subtype\":\"interrupt\"}}");
        defer c.deinit();
        try testing.expectEqual(StdinMessageKind.control_request, c.kind);
    }
    {
        var c = try classifyLine(allocator, "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"r1\"}}");
        defer c.deinit();
        try testing.expectEqual(StdinMessageKind.control_response, c.kind);
    }
    {
        var c = try classifyLine(allocator, "{\"type\":\"keep_alive\"}");
        defer c.deinit();
        try testing.expectEqual(StdinMessageKind.keep_alive, c.kind);
    }
    {
        var c = try classifyLine(allocator, "{\"type\":\"update_environment_variables\",\"vars\":{\"X\":\"1\"}}");
        defer c.deinit();
        try testing.expectEqual(StdinMessageKind.update_environment_variables, c.kind);
    }
    {
        var c = try classifyLine(allocator, "{\"type\":\"something_else\"}");
        defer c.deinit();
        try testing.expectEqual(StdinMessageKind.unknown, c.kind);
    }
}

test "classifyLine: malformed JSON and missing type are errors" {
    const allocator = testing.allocator;
    try testing.expectError(error.MalformedLine, classifyLine(allocator, "not json at all"));
    try testing.expectError(error.MalformedLine, classifyLine(allocator, "[1,2,3]"));
    try testing.expectError(error.MissingType, classifyLine(allocator, "{\"no_type\":true}"));
}

test "runDispatchLoop: one user message enqueues a single turn" {
    const allocator = testing.allocator;
    var recorder = TurnRecorder{ .allocator = allocator };
    defer recorder.deinit();

    var reader = FixedReader{ .data = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"do the thing\"}}\n" };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const writer = CaptureWriter{ .buf = &out, .allocator = allocator };

    try runDispatchLoop(allocator, &reader, writer, .{
        .ctx = &recorder,
        .on_user = TurnRecorder.onUser,
    });

    try testing.expectEqual(@as(usize, 1), recorder.prompts.items.len);
    try testing.expectEqualStrings("do the thing", recorder.prompts.items[0]);
    // No diversion happened.
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "runDispatchLoop: a malformed line is diverted without crashing the loop" {
    const allocator = testing.allocator;
    var recorder = TurnRecorder{ .allocator = allocator };
    defer recorder.deinit();

    // A malformed line between two good user messages: the loop must divert the
    // bad line and still run both turns.
    var reader = FixedReader{ .data = "{\"type\":\"user\",\"message\":{\"content\":\"first\"}}\n" ++
        "this is not json\n" ++
        "{\"type\":\"user\",\"message\":{\"content\":\"second\"}}\n" };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const writer = CaptureWriter{ .buf = &out, .allocator = allocator };

    try runDispatchLoop(allocator, &reader, writer, .{
        .ctx = &recorder,
        .on_user = TurnRecorder.onUser,
    });

    try testing.expectEqual(@as(usize, 2), recorder.prompts.items.len);
    try testing.expectEqualStrings("first", recorder.prompts.items[0]);
    try testing.expectEqualStrings("second", recorder.prompts.items[1]);
    // The bad line produced a diverted error envelope.
    try testing.expect(std.mem.indexOf(u8, out.items, "MalformedStdinLine") != null);
}

test "runDispatchLoop: two user messages run both turns in order (multi-turn)" {
    const allocator = testing.allocator;
    var recorder = TurnRecorder{ .allocator = allocator };
    defer recorder.deinit();

    var reader = FixedReader{ .data = "{\"type\":\"user\",\"message\":{\"content\":\"turn one\"}}\n" ++
        "{\"type\":\"user\",\"message\":{\"content\":\"turn two\"}}\n" };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const writer = CaptureWriter{ .buf = &out, .allocator = allocator };

    try runDispatchLoop(allocator, &reader, writer, .{
        .ctx = &recorder,
        .on_user = TurnRecorder.onUser,
    });

    try testing.expectEqual(@as(usize, 2), recorder.prompts.items.len);
    try testing.expectEqualStrings("turn one", recorder.prompts.items[0]);
    try testing.expectEqualStrings("turn two", recorder.prompts.items[1]);
}

test "sdk-headless-12: --replay-user-messages re-emits an accepted user message on stdout" {
    const allocator = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var replayer = ReplayRecorder{ .allocator = allocator, .out = &out, .session_id = "sess-r" };

    var reader = FixedReader{ .data = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"do the thing\"}}\n" };
    const writer = CaptureWriter{ .buf = &out, .allocator = allocator };

    try runDispatchLoop(allocator, &reader, writer, .{
        .ctx = &replayer,
        .on_user = ReplayRecorder.onUser,
    });

    // The accepted user message is re-emitted as a parseable `user` NDJSON line.
    try testing.expect(out.items.len > 0 and out.items[out.items.len - 1] == '\n');
    const trimmed = std.mem.trim(u8, out.items, " \t\r\n");
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("user", obj.get("type").?.string);
    try testing.expectEqualStrings(
        "do the thing",
        obj.get("message").?.object.get("content").?.string,
    );
    try testing.expectEqualStrings("sess-r", obj.get("session_id").?.string);
}

test "runDispatchLoop: keep_alive is consumed as a no-op and control_request routes" {
    const allocator = testing.allocator;

    const Router = struct {
        control_requests: usize = 0,
        fn onControl(ctx: *anyopaque, raw: []const u8) anyerror!void {
            _ = raw;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.control_requests += 1;
        }
    };
    var router = Router{};

    var reader = FixedReader{ .data = "{\"type\":\"keep_alive\"}\n" ++
        "{\"type\":\"control_request\",\"request_id\":\"r1\",\"request\":{\"subtype\":\"interrupt\"}}\n" };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const writer = CaptureWriter{ .buf = &out, .allocator = allocator };

    try runDispatchLoop(allocator, &reader, writer, .{
        .ctx = &router,
        .on_control_request = Router.onControl,
    });

    // keep_alive with no handler is silently consumed; the control_request is
    // routed to the handler. Neither diverts.
    try testing.expectEqual(@as(usize, 1), router.control_requests);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

// --- sdk-headless-05 relay tests --------------------------------------------

// A stub dispatcher that records the last request it saw and returns a
// pre-canned decision (or a forced error). Stands in for the real host channel.
const StubDispatcher = struct {
    allocator: std.mem.Allocator,
    decision: RelayDecision = .allow,
    fail: bool = false,
    calls: usize = 0,
    last_request: []u8 = "",

    fn deinit(self: *StubDispatcher) void {
        if (self.last_request.len > 0) self.allocator.free(self.last_request);
    }

    fn request(ctx: *anyopaque, request_json: []const u8) anyerror!RelayDecision {
        const self: *StubDispatcher = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.last_request.len > 0) self.allocator.free(self.last_request);
        self.last_request = try self.allocator.dupe(u8, request_json);
        if (self.fail) return error.RelayUnavailable;
        return self.decision;
    }

    fn dispatcher(self: *StubDispatcher) Dispatcher {
        return .{ .ctx = @ptrCast(self), .requestFn = request };
    }
};

test "buildCanUseToolRequest carries the reference fields as parseable JSON" {
    const allocator = testing.allocator;
    const req = try buildCanUseToolRequest(
        allocator,
        "Bash",
        "{\"command\":\"ls\"}",
        "tool-1",
        "MEDIUM tier; manual mode",
        "[{\"type\":\"addRule\"}]",
    );
    defer allocator.free(req);

    var p = try std.json.parseFromSlice(std.json.Value, allocator, req, .{});
    defer p.deinit();
    const obj = p.value.object;
    try testing.expectEqualStrings("can_use_tool", obj.get("subtype").?.string);
    try testing.expectEqualStrings("Bash", obj.get("tool_name").?.string);
    try testing.expectEqualStrings("ls", obj.get("input").?.object.get("command").?.string);
    try testing.expectEqualStrings("tool-1", obj.get("tool_use_id").?.string);
    try testing.expectEqualStrings("MEDIUM tier; manual mode", obj.get("decision_reason").?.string);
    try testing.expectEqual(@as(usize, 1), obj.get("permission_suggestions").?.array.items.len);
}

test "buildCanUseToolRequest defaults empty input to {} and omits empty optionals" {
    const allocator = testing.allocator;
    const req = try buildCanUseToolRequest(allocator, "Read", "", "", "", "");
    defer allocator.free(req);

    var p = try std.json.parseFromSlice(std.json.Value, allocator, req, .{});
    defer p.deinit();
    const obj = p.value.object;
    try testing.expectEqual(std.json.Value.object, std.meta.activeTag(obj.get("input").?));
    try testing.expectEqual(@as(usize, 0), obj.get("input").?.object.count());
    try testing.expect(obj.get("tool_use_id") == null);
    try testing.expect(obj.get("decision_reason") == null);
    // permission_suggestions is always present (stable shape), default [].
    try testing.expectEqual(@as(usize, 0), obj.get("permission_suggestions").?.array.items.len);
}

test "RelayApprover: an allow control_response yields ApprovalResponse.approve" {
    const allocator = testing.allocator;
    var stub = StubDispatcher{ .allocator = allocator, .decision = .allow };
    defer stub.deinit();
    var approver = RelayApprover.init(allocator, stub.dispatcher());
    defer approver.deinit();

    const resp = try approver.requestPermission("Bash", "{\"command\":\"ls\"}", "tool-1", "manual mode", "[]");
    try testing.expectEqual(types.ApprovalResponse.approve, resp);
    try testing.expectEqual(@as(usize, 1), stub.calls);
    // The request the dispatcher saw carries the can_use_tool subtype + tool.
    try testing.expect(std.mem.indexOf(u8, stub.last_request, "\"subtype\":\"can_use_tool\"") != null);
    try testing.expect(std.mem.indexOf(u8, stub.last_request, "\"tool_name\":\"Bash\"") != null);
}

test "RelayApprover: a deny control_response yields ApprovalResponse.deny" {
    const allocator = testing.allocator;
    var stub = StubDispatcher{ .allocator = allocator, .decision = .deny };
    defer stub.deinit();
    var approver = RelayApprover.init(allocator, stub.dispatcher());
    defer approver.deinit();

    const resp = try approver.requestPermission("Bash", "{}", "tool-2", "", "[]");
    try testing.expectEqual(types.ApprovalResponse.deny, resp);
}

test "RelayApprover: a duplicate tool_use_id is ignored (not re-sent to the host)" {
    const allocator = testing.allocator;
    var stub = StubDispatcher{ .allocator = allocator, .decision = .allow };
    defer stub.deinit();
    var approver = RelayApprover.init(allocator, stub.dispatcher());
    defer approver.deinit();

    // First request reaches the host and is allowed.
    const first = try approver.requestPermission("Bash", "{}", "tool-dup", "", "[]");
    try testing.expectEqual(types.ApprovalResponse.approve, first);
    try testing.expectEqual(@as(usize, 1), stub.calls);

    // A second request for the SAME tool_use_id is a duplicate: ignored
    // (deny) WITHOUT a second dispatcher call.
    const second = try approver.requestPermission("Bash", "{}", "tool-dup", "", "[]");
    try testing.expectEqual(types.ApprovalResponse.deny, second);
    try testing.expectEqual(@as(usize, 1), stub.calls); // unchanged
}

test "RelayApprover: a dispatcher error fails safe to deny and does not record the id" {
    const allocator = testing.allocator;
    var stub = StubDispatcher{ .allocator = allocator, .fail = true };
    defer stub.deinit();
    var approver = RelayApprover.init(allocator, stub.dispatcher());
    defer approver.deinit();

    const resp = try approver.requestPermission("Bash", "{}", "tool-err", "", "[]");
    try testing.expectEqual(types.ApprovalResponse.deny, resp);
    // The id was NOT recorded, so a retry can still reach the host.
    try testing.expect(!approver.alreadyResolved("tool-err"));
}

test "RelayApprover.promptCb maps through the pending_* fields (ApprovalHandler path)" {
    const allocator = testing.allocator;
    var stub = StubDispatcher{ .allocator = allocator, .decision = .allow };
    defer stub.deinit();
    var approver = RelayApprover.init(allocator, stub.dispatcher());
    defer approver.deinit();

    approver.pending_tool_name = "Write";
    approver.pending_input_json = "{\"path\":\"/tmp/x\"}";
    approver.pending_tool_use_id = "tool-h1";
    approver.pending_decision_reason = "HIGH tier";

    // Drive it exactly as the gate does: through the ApprovalPromptFn signature.
    const resp = try RelayApprover.promptCb(approver.ctxPtr(), "Approve Write [HIGH]?");
    try testing.expectEqual(types.ApprovalResponse.approve, resp);
    try testing.expect(std.mem.indexOf(u8, stub.last_request, "\"tool_name\":\"Write\"") != null);
    try testing.expect(std.mem.indexOf(u8, stub.last_request, "\"decision_reason\":\"HIGH tier\"") != null);
}

// --- sdk-headless-10 one-time initialize tests ------------------------------

test "InitState.dispatchInitialize: first call succeeds and flips the flag; second is rejected" {
    const allocator = testing.allocator;
    var state = InitState{};

    const empty: control.InitializeApplier = .{ .ctx = undefined };
    const resp_data: control.InitResponseData = .{};

    const line1 = "{\"type\":\"control_request\",\"request_id\":\"i1\",\"request\":{\"subtype\":\"initialize\"}}";
    const out1 = try dispatchInitialize(allocator, line1, &state, empty, resp_data);
    defer allocator.free(out1);
    try testing.expect(state.initialized);
    {
        var p = try std.json.parseFromSlice(std.json.Value, allocator, std.mem.trimEnd(u8, out1, "\n"), .{});
        defer p.deinit();
        try testing.expectEqualStrings("success", p.value.object.get("response").?.object.get("subtype").?.string);
    }

    // A second initialize on the same state takes the already-initialized path.
    const line2 = "{\"type\":\"control_request\",\"request_id\":\"i2\",\"request\":{\"subtype\":\"initialize\"}}";
    const out2 = try dispatchInitialize(allocator, line2, &state, empty, resp_data);
    defer allocator.free(out2);
    try testing.expect(state.initialized); // still set
    {
        var p = try std.json.parseFromSlice(std.json.Value, allocator, std.mem.trimEnd(u8, out2, "\n"), .{});
        defer p.deinit();
        const resp = p.value.object.get("response").?.object;
        try testing.expectEqualStrings("error", resp.get("subtype").?.string);
        try testing.expectEqualStrings("Already initialized", resp.get("error").?.string);
        try testing.expectEqualStrings("i2", resp.get("request_id").?.string);
    }
}

// --- sdk-headless-13 keep_alive / update_environment_variables tests ---------

test "applyEnvUpdates: updates the override map and logs key names not values" {
    const allocator = testing.allocator;
    defer env.clearOverrides();

    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(allocator);
    const log_writer = CaptureWriter{ .buf = &log, .allocator = allocator };

    const line =
        "{\"type\":\"update_environment_variables\",\"variables\":" ++
        "{\"CLAUDE_CODE_SESSION_ACCESS_TOKEN\":\"super-secret-token\"," ++
        "\"ZCODE_SDK_TEST_VAR\":\"hello\"}}";

    const applied = try applyEnvUpdates(allocator, line, log_writer);
    try testing.expectEqual(@as(usize, 2), applied);

    // A subsequent env lookup returns the freshly applied value (the running
    // process sees it, not just child subprocesses).
    try testing.expectEqualStrings("super-secret-token", env.getenv("CLAUDE_CODE_SESSION_ACCESS_TOKEN").?);
    try testing.expectEqualStrings("hello", env.getenv("ZCODE_SDK_TEST_VAR").?);

    // The log line names the applied keys but NEVER the secret values.
    try testing.expect(std.mem.indexOf(u8, log.items, "CLAUDE_CODE_SESSION_ACCESS_TOKEN") != null);
    try testing.expect(std.mem.indexOf(u8, log.items, "ZCODE_SDK_TEST_VAR") != null);
    try testing.expect(std.mem.indexOf(u8, log.items, "super-secret-token") == null);
    try testing.expect(std.mem.indexOf(u8, log.items, "hello") == null);
}

test "applyEnvUpdates: a refreshed value replaces the prior override" {
    const allocator = testing.allocator;
    defer env.clearOverrides();

    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(allocator);
    const log_writer = CaptureWriter{ .buf = &log, .allocator = allocator };

    _ = try applyEnvUpdates(allocator, "{\"type\":\"update_environment_variables\",\"variables\":{\"TOK\":\"v1\"}}", log_writer);
    try testing.expectEqualStrings("v1", env.getenv("TOK").?);
    _ = try applyEnvUpdates(allocator, "{\"type\":\"update_environment_variables\",\"variables\":{\"TOK\":\"v2\"}}", log_writer);
    try testing.expectEqualStrings("v2", env.getenv("TOK").?);
}

test "applyEnvUpdates: missing or non-object variables field is a tolerated no-op" {
    const allocator = testing.allocator;
    defer env.clearOverrides();

    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(allocator);
    const log_writer = CaptureWriter{ .buf = &log, .allocator = allocator };

    // No variables field.
    try testing.expectEqual(@as(usize, 0), try applyEnvUpdates(allocator, "{\"type\":\"update_environment_variables\"}", log_writer));
    // Non-object variables.
    try testing.expectEqual(@as(usize, 0), try applyEnvUpdates(allocator, "{\"type\":\"update_environment_variables\",\"variables\":42}", log_writer));
    // A non-string value entry is skipped, but a sibling string value still applies.
    try testing.expectEqual(@as(usize, 1), try applyEnvUpdates(allocator, "{\"type\":\"update_environment_variables\",\"variables\":{\"A\":1,\"B\":\"ok\"}}", log_writer));
    try testing.expectEqualStrings("ok", env.getenv("B").?);
}

test "runDispatchLoop: a keep_alive line is consumed without effect and applies no env change" {
    const allocator = testing.allocator;
    defer env.clearOverrides();

    // keep_alive must not touch the override map; pick a name nothing else sets.
    try testing.expect(env.getenv("ZCODE_KEEP_ALIVE_SENTINEL") == null);

    var reader = FixedReader{ .data = "{\"type\":\"keep_alive\"}\n" };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const writer = CaptureWriter{ .buf = &out, .allocator = allocator };

    var dummy: u8 = 0;
    try runDispatchLoop(allocator, &reader, writer, .{ .ctx = &dummy });

    // No diversion, no env change.
    try testing.expectEqual(@as(usize, 0), out.items.len);
    try testing.expect(env.getenv("ZCODE_KEEP_ALIVE_SENTINEL") == null);
}

test "runDispatchLoop: update_environment_variables routes through the handler" {
    const allocator = testing.allocator;
    defer env.clearOverrides();

    var handler = EnvUpdateHandler{ .allocator = allocator };

    var reader = FixedReader{ .data = "{\"type\":\"update_environment_variables\",\"variables\":{\"ZCODE_LOOP_ENV\":\"applied\"}}\n" };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const writer = CaptureWriter{ .buf = &out, .allocator = allocator };

    try runDispatchLoop(allocator, &reader, writer, .{
        .ctx = &handler,
        .on_update_env = EnvUpdateHandler.onUpdateEnv,
    });

    // The dispatch loop routed the line through the env handler; the value is live.
    try testing.expectEqualStrings("applied", env.getenv("ZCODE_LOOP_ENV").?);
    // The handler logs to stderr (not the dispatch writer), so no diversion here.
    try testing.expectEqual(@as(usize, 0), out.items.len);
}
