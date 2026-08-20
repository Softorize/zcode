//! sdk-headless-04: control_request / control_response / control_cancel_request
//! envelope.
//!
//! The bidirectional control protocol the SDK host and the CLI speak over the
//! stream-json transport (sdk-headless-03). Two directions share one envelope
//! family:
//!   - host -> CLI : the host sends `control_request` to drive a running
//!                   session (interrupt, set_model, initialize, ...). The CLI
//!                   replies with a `control_response`.
//!   - CLI -> host : the CLI *originates* a `control_request` back to the host
//!                   (the `can_use_tool` permission relay, `hook_callback`,
//!                   `elicitation`) and awaits the host's `control_response`.
//!
//! This module owns the wire envelope (encode/decode), the subtype tagged
//! union, and the per-`request_id` pending map that correlates a CLI-originated
//! request with its eventual response.
//!
//! Reference behavior + file:line:
//!   controlSchemas.ts:578  SDKControlRequestSchema
//!   controlSchemas.ts:605  SDKControlResponseSchema
//!   controlSchemas.ts:612  SDKControlCancelRequestSchema
//!   controlSchemas.ts:594  ControlErrorResponseSchema (pending_permission_requests)
//!   structuredIO.ts:469    sendRequest (enqueue + pending map + abort -> cancel)
//!   structuredIO.ts:490    cancel rejects immediately without host ack
//!   print.ts:2830          dispatch
//!
//! Concurrency model (see Task D risk note): zcode is synchronous one-turn
//! today and the runtime does not expose cooperative green-thread blocking, so
//! `sendRequest` is NOT modeled as a blocking call. Instead a CLI-originated
//! request is a state object (`PendingRequest`) the stdin dispatcher drives:
//! `sendRequest` writes the envelope and registers the entry as `.pending`;
//! when a matching `control_response` line arrives the dispatcher calls
//! `handleControlResponse`, which flips the entry to `.resolved` (carrying the
//! raw response JSON); on abort `cancel` flips it to `.cancelled` and emits a
//! `control_cancel_request`. The originating caller polls the entry's state.
//! This avoids fighting the runtime and keeps every transition synchronously
//! testable.

const std = @import("std");
const std_io = @import("../core/std_io.zig");
const parse_helpers = @import("../core/parse_helpers.zig");
const rng = @import("../core/rng.zig");

/// The `control_request` subtypes we support. `unsupported` is the
/// fall-through for a well-formed control_request whose `subtype` is none of
/// the recognized members; the dispatcher answers it with an error response
/// rather than crashing.
pub const ControlSubtype = enum {
    interrupt,
    can_use_tool,
    initialize,
    set_permission_mode,
    set_model,
    set_max_thinking_tokens,
    hook_callback,
    elicitation,
    unsupported,

    pub fn toString(self: ControlSubtype) []const u8 {
        return switch (self) {
            .interrupt => "interrupt",
            .can_use_tool => "can_use_tool",
            .initialize => "initialize",
            .set_permission_mode => "set_permission_mode",
            .set_model => "set_model",
            .set_max_thinking_tokens => "set_max_thinking_tokens",
            .hook_callback => "hook_callback",
            .elicitation => "elicitation",
            .unsupported => "unsupported",
        };
    }

    /// Classify a `request.subtype` string. Unknown strings map to
    /// `.unsupported` (the dispatcher returns an error response for those).
    pub fn fromString(s: []const u8) ControlSubtype {
        if (std.mem.eql(u8, s, "interrupt")) return .interrupt;
        if (std.mem.eql(u8, s, "can_use_tool")) return .can_use_tool;
        if (std.mem.eql(u8, s, "initialize")) return .initialize;
        if (std.mem.eql(u8, s, "set_permission_mode")) return .set_permission_mode;
        if (std.mem.eql(u8, s, "set_model")) return .set_model;
        if (std.mem.eql(u8, s, "set_max_thinking_tokens")) return .set_max_thinking_tokens;
        if (std.mem.eql(u8, s, "hook_callback")) return .hook_callback;
        if (std.mem.eql(u8, s, "elicitation")) return .elicitation;
        return .unsupported;
    }
};

/// A decoded inbound `control_request`. The `request_id` and `raw_request`
/// slices borrow from the parse arena held by `DecodedRequest`; copy them out
/// before freeing if they must outlive it.
pub const ControlRequest = struct {
    request_id: []const u8,
    subtype: ControlSubtype,
    /// The raw subtype string as it appeared on the wire (lets the dispatcher
    /// report the exact unknown subtype back in an error response).
    subtype_raw: []const u8,
    /// The raw JSON of the inner `request` object, borrowed from the source
    /// line. Subtype handlers re-parse this for their own fields.
    raw_request: []const u8,
};

/// Holds the parse arena so the borrowed slices on `request` stay valid until
/// `deinit`.
pub const DecodedRequest = struct {
    parsed: std.json.Parsed(std.json.Value),
    request: ControlRequest,

    pub fn deinit(self: *DecodedRequest) void {
        self.parsed.deinit();
    }
};

/// Decode an inbound `control_request` line. Returns:
///   error.InvalidEnvelope - not an object, wrong `type`, or no `request`
///   error.MissingRequestId - the `request_id` field is absent or not a string
///   error.MissingSubtype   - the inner `request.subtype` is absent / non-string
/// The caller must `deinit` the returned `DecodedRequest`.
pub fn decodeRequest(allocator: std.mem.Allocator, line: []const u8) !DecodedRequest {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
        return error.InvalidEnvelope;
    };
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidEnvelope;

    // Take the object by pointer (CLAUDE.md ObjectMap rule): a value copy
    // desyncs the entries pointer on a later realloc.
    const obj = &parsed.value.object;

    const type_val = obj.get("type") orelse return error.InvalidEnvelope;
    if (type_val != .string or !std.mem.eql(u8, type_val.string, "control_request")) {
        return error.InvalidEnvelope;
    }

    const id_val = obj.get("request_id") orelse return error.MissingRequestId;
    if (id_val != .string) return error.MissingRequestId;

    const req_val = obj.get("request") orelse return error.InvalidEnvelope;
    if (req_val != .object) return error.InvalidEnvelope;

    const subtype_val = req_val.object.get("subtype") orelse return error.MissingSubtype;
    if (subtype_val != .string) return error.MissingSubtype;

    const raw_request = scanRawValueSpan(trimmed, obj, "request") orelse "";

    return .{
        .parsed = parsed,
        .request = .{
            .request_id = id_val.string,
            .subtype = ControlSubtype.fromString(subtype_val.string),
            .subtype_raw = subtype_val.string,
            .raw_request = raw_request,
        },
    };
}

/// Encode an outbound `control_request` (CLI -> host or host -> CLI). The inner
/// `request` is supplied as raw JSON (already a valid object) so subtype
/// payloads stay opaque to this layer. The result is a single newline-
/// terminated NDJSON-safe line; the caller owns it.
///
/// `request_json` must be a JSON object string whose first field is the
/// subtype, e.g. `{"subtype":"can_use_tool","tool_name":"Bash",...}`.
pub fn encodeRequest(
    allocator: std.mem.Allocator,
    request_id: []const u8,
    request_json: []const u8,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"type\":\"control_request\",\"request_id\":");
    try writeJsonString(w, request_id);
    try w.writeAll(",\"request\":");
    try w.writeAll(request_json);
    try w.writeAll("}");
    try out.append('\n');
    return finalizeNdjson(allocator, out.items());
}

/// Encode a success `control_response`. `response_json` is the optional inner
/// `response` body as raw JSON (empty -> the `response` key is omitted). The
/// result is a newline-terminated NDJSON-safe line; the caller owns it.
pub fn encodeSuccessResponse(
    allocator: std.mem.Allocator,
    request_id: []const u8,
    response_json: []const u8,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":");
    try writeJsonString(w, request_id);
    if (response_json.len > 0) {
        try w.writeAll(",\"response\":");
        try w.writeAll(response_json);
    }
    try w.writeAll("}}");
    try out.append('\n');
    return finalizeNdjson(allocator, out.items());
}

/// Encode an error `control_response`. Carries `pending_permission_requests`
/// (an array of still-open `can_use_tool` request envelopes, each raw JSON) per
/// ControlErrorResponseSchema; pass an empty slice when there are none - the
/// key is always present so the host shape is stable. The result is a
/// newline-terminated NDJSON-safe line; the caller owns it.
pub fn encodeErrorResponse(
    allocator: std.mem.Allocator,
    request_id: []const u8,
    error_message: []const u8,
    pending_permission_requests: []const []const u8,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"type\":\"control_response\",\"response\":{\"subtype\":\"error\",\"request_id\":");
    try writeJsonString(w, request_id);
    try w.writeAll(",\"error\":");
    try writeJsonString(w, error_message);
    try w.writeAll(",\"pending_permission_requests\":[");
    for (pending_permission_requests, 0..) |req, idx| {
        if (idx != 0) try w.writeAll(",");
        // Each entry is already a valid JSON object; embed verbatim.
        try w.writeAll(req);
    }
    try w.writeAll("]}}");
    try out.append('\n');
    return finalizeNdjson(allocator, out.items());
}

/// Encode a `control_cancel_request`. The result is a newline-terminated
/// NDJSON-safe line; the caller owns it.
pub fn encodeCancelRequest(allocator: std.mem.Allocator, request_id: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"type\":\"control_cancel_request\",\"request_id\":");
    try writeJsonString(w, request_id);
    try w.writeAll("}");
    try out.append('\n');
    return finalizeNdjson(allocator, out.items());
}

/// The lifecycle state of a CLI-originated request. The dispatcher drives the
/// transitions; the originating caller polls `state`.
pub const PendingState = enum {
    /// Sent to the host; awaiting a `control_response`.
    pending,
    /// A matching `control_response` arrived. `response_json` holds its raw
    /// inner `response` body (or "" when the host omitted it).
    resolved,
    /// Aborted locally; a `control_cancel_request` was emitted and we are not
    /// waiting for a host ack (matches structuredIO.ts:490).
    cancelled,
};

/// A single CLI-originated request awaiting (or having received) a host
/// response. Owned by the `PendingMap` and freed when the entry is removed.
pub const PendingRequest = struct {
    state: PendingState = .pending,
    /// Whether the host's `control_response` was a success (vs error). Only
    /// meaningful when `state == .resolved`.
    is_success: bool = false,
    /// The raw inner `response` body JSON from the host's success response, or
    /// the raw `error` string for an error response. Owned by this struct
    /// (duped on resolve), or empty.
    response_json: []const u8 = "",

    fn deinit(self: *PendingRequest, allocator: std.mem.Allocator) void {
        if (self.response_json.len > 0) allocator.free(self.response_json);
        self.response_json = "";
    }
};

/// Correlates CLI-originated `control_request`s with their host responses by
/// `request_id`. Keys are owned (duped) and freed on removal. Not thread-safe;
/// the single stdin dispatcher fiber is the only writer.
pub const PendingMap = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(*PendingRequest),

    pub fn init(allocator: std.mem.Allocator) PendingMap {
        return .{ .allocator = allocator, .map = std.StringHashMap(*PendingRequest).init(allocator) };
    }

    pub fn deinit(self: *PendingMap) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.map.deinit();
    }

    /// Register a fresh CLI-originated request and return its generated
    /// `request_id` (caller owns the id slice) plus the pending entry (owned by
    /// the map). The caller is responsible for writing the encoded envelope to
    /// the host; this only tracks the correlation entry. The id is a 16-byte
    /// secure-random hex string (rng.hexId), prefixed so it never collides with
    /// host-originated ids.
    pub fn register(self: *PendingMap) !struct { request_id: []u8, entry: *PendingRequest } {
        const raw = try rng.hexId(self.allocator, 16);
        defer self.allocator.free(raw);
        const id = try std.fmt.allocPrint(self.allocator, "cli-{s}", .{raw});
        errdefer self.allocator.free(id);

        const entry = try self.allocator.create(PendingRequest);
        errdefer self.allocator.destroy(entry);
        entry.* = .{};

        // Dupe the key for ownership; the returned id is a separate copy the
        // caller owns (so it can embed it in the envelope without aliasing the
        // map's key).
        const key = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(key);
        try self.map.put(key, entry);

        return .{ .request_id = id, .entry = entry };
    }

    /// Resolve a matching pending entry from an inbound `control_response`
    /// line. Orphan/duplicate responses (no matching `request_id`, or an entry
    /// already resolved/cancelled) are a no-op (logged via the returned bool,
    /// never a crash). Returns true when an entry transitioned to `.resolved`.
    pub fn handleControlResponse(self: *PendingMap, line: []const u8) !bool {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, trimmed, .{}) catch {
            return false;
        };
        defer parsed.deinit();
        if (parsed.value != .object) return false;

        const obj = &parsed.value.object;
        const type_val = obj.get("type") orelse return false;
        if (type_val != .string or !std.mem.eql(u8, type_val.string, "control_response")) return false;

        const resp_val = obj.get("response") orelse return false;
        if (resp_val != .object) return false;
        const resp_obj = &resp_val.object;

        const id_val = resp_obj.get("request_id") orelse return false;
        if (id_val != .string) return false;

        const entry = self.map.get(id_val.string) orelse return false; // orphan -> no-op
        if (entry.state != .pending) return false; // duplicate -> no-op

        const subtype_val = resp_obj.get("subtype");
        const is_success = if (subtype_val) |sv|
            (sv == .string and std.mem.eql(u8, sv.string, "success"))
        else
            true;

        entry.is_success = is_success;
        entry.state = .resolved;

        // Capture the inner `response` body (success) or `error` string
        // (error) as raw JSON, duped into the entry so it survives the arena.
        if (is_success) {
            if (scanRawValueSpan(trimmed, resp_obj, "response")) |span| {
                entry.response_json = try self.allocator.dupe(u8, span);
            }
        } else {
            if (resp_obj.get("error")) |ev| {
                if (ev == .string) entry.response_json = try self.allocator.dupe(u8, ev.string);
            }
        }
        return true;
    }

    /// Cancel a pending request locally: flip it to `.cancelled` and return its
    /// `request_id` so the caller can emit a `control_cancel_request`. The
    /// cancel resolves immediately without waiting for a host ack (matches
    /// structuredIO.ts:490). Returns null when the id is unknown or not pending.
    pub fn markCancelled(self: *PendingMap, request_id: []const u8) bool {
        const entry = self.map.get(request_id) orelse return false;
        if (entry.state != .pending) return false;
        entry.state = .cancelled;
        return true;
    }

    /// Remove and free a finished entry (resolved or cancelled). Safe to call
    /// for an unknown id (no-op). The caller must have copied out any data it
    /// needs from the entry before removal.
    pub fn release(self: *PendingMap, request_id: []const u8) void {
        if (self.map.fetchRemove(request_id)) |kv| {
            self.allocator.free(kv.key);
            kv.value.deinit(self.allocator);
            self.allocator.destroy(kv.value);
        }
    }

    /// Number of still-tracked entries (any state). Used by tests and by the
    /// error-response builder to enumerate still-open requests.
    pub fn count(self: *const PendingMap) usize {
        return self.map.count();
    }
};

/// Recover the raw JSON span for `key`'s value out of `source`. std.json does
/// not expose token offsets, so we re-scan for the key token and bracket-match
/// its value, keeping the payload opaque (raw JSON) without cloning a value
/// tree. Mirrors core/sdk_message.zig:getRawSpan. Returns null when the key is
/// absent or cannot be span-matched.
fn scanRawValueSpan(source: []const u8, obj: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key) == null) return null;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, source, search_from, key)) |key_at| {
        search_from = key_at + 1;
        if (key_at == 0 or source[key_at - 1] != '"') continue;
        const after_key = key_at + key.len;
        if (after_key >= source.len or source[after_key] != '"') continue;
        var i = after_key + 1;
        while (i < source.len and (source[i] == ' ' or source[i] == '\t')) i += 1;
        if (i >= source.len or source[i] != ':') continue;
        i += 1;
        while (i < source.len and (source[i] == ' ' or source[i] == '\t' or source[i] == '\n' or source[i] == '\r')) i += 1;
        if (i >= source.len) return null;
        return scanValueSpan(source, i);
    }
    return null;
}

/// Given an offset at the start of a JSON value, return the slice spanning the
/// full value. Mirrors core/sdk_message.zig:scanValueSpan.
fn scanValueSpan(source: []const u8, start: usize) ?[]const u8 {
    if (start >= source.len) return null;
    const c = source[start];
    switch (c) {
        '{', '[' => {
            const open = c;
            const close: u8 = if (c == '{') '}' else ']';
            var depth: usize = 0;
            var in_string = false;
            var escaped = false;
            var i = start;
            while (i < source.len) : (i += 1) {
                const ch = source[i];
                if (in_string) {
                    if (escaped) {
                        escaped = false;
                    } else if (ch == '\\') {
                        escaped = true;
                    } else if (ch == '"') {
                        in_string = false;
                    }
                    continue;
                }
                if (ch == '"') {
                    in_string = true;
                } else if (ch == open) {
                    depth += 1;
                } else if (ch == close) {
                    depth -= 1;
                    if (depth == 0) return source[start .. i + 1];
                }
            }
            return null;
        },
        '"' => {
            var i = start + 1;
            var escaped = false;
            while (i < source.len) : (i += 1) {
                const ch = source[i];
                if (escaped) {
                    escaped = false;
                } else if (ch == '\\') {
                    escaped = true;
                } else if (ch == '"') {
                    return source[start .. i + 1];
                }
            }
            return null;
        },
        else => {
            var i = start;
            while (i < source.len) : (i += 1) {
                const ch = source[i];
                if (ch == ',' or ch == '}' or ch == ']' or ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') break;
            }
            if (i == start) return null;
            return source[start..i];
        },
    }
}

/// Run a rendered JSON line (valid JSON + trailing newline) through the
/// NDJSON-safe pass so U+2028 / U+2029 cannot break a strict line reader, then
/// hand ownership to the caller. Mirrors sdk/output.zig:finalizeNdjson.
fn finalizeNdjson(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    var safe = std_io.StringBuilder.init(allocator);
    defer safe.deinit();
    try parse_helpers.appendNdjsonSafe(&safe, line);
    return safe.toOwnedSlice();
}

/// Minimal JSON string escaper (quotes, backslash, C0 controls). Mirrors the
/// escaper in sdk/output.zig and core/sdk_message.zig. U+2028 / U+2029 are
/// handled by finalizeNdjson, not here.
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

// --- sdk-headless-06: live-control subtypes --------------------------------
//
// interrupt / set_permission_mode / set_model / set_max_thinking_tokens let a
// host mutate a running session mid-stream. Each arrives as a host-originated
// `control_request` (already decoded by decodeRequest) and is answered with a
// `control_response` carrying the matching `request_id`.
//
// Reference behavior + file:line:
//   controlSchemas.ts:97/124/137/146  the four request schemas
//   print.ts:2831  interrupt   -> abortController.abort()
//   print.ts:2918  set_permission_mode
//   print.ts:2933  set_model
//   print.ts:2945  set_max_thinking_tokens
//   QueryEngine.ts:1158 interrupt(), :1174 setModel()
//
// Design (same rationale as the can_use_tool relay in structured_io.zig): the
// dispatch lives here, but the runtime mutation is behind a small type-erased
// vtable (`LiveControlMutator`) so this module does not import the heavy
// agent_runtime. The real session loop builds a mutator backed by AgentRuntime;
// tests build a stub mutator that records the calls. Each handler returns the
// encoded `control_response` line (caller owns it).

/// A type-erased view of the live-session knobs the four control subtypes turn.
/// The session loop fills these in with AgentRuntime methods; a test fills them
/// with a recording stub. A null function means "this knob is not wired in this
/// session" - the dispatcher then answers the subtype with an error response
/// rather than crashing.
///
/// `interrupt` sets a cooperative abort flag the turn loop checks between
/// rounds (NOT a process-killing signal; the SIGINT path is separate). The
/// other three mutate runtime state for subsequent turns. All return `anyerror`
/// so a failed mutation (e.g. an unknown model) becomes an error response.
pub const LiveControlMutator = struct {
    ctx: *anyopaque,
    /// Set the cooperative abort flag so the running turn stops at its next
    /// safe point. No payload.
    interruptFn: ?*const fn (ctx: *anyopaque) anyerror!void = null,
    /// Switch the live permission mode (reference spellings: default,
    /// acceptEdits, plan, bypassPermissions, dontAsk). `mode` borrows for the
    /// call only.
    setPermissionModeFn: ?*const fn (ctx: *anyopaque, mode: []const u8) anyerror!void = null,
    /// Switch the active model for subsequent turns. `model` borrows for the
    /// call only; the implementation dupes what it keeps.
    setModelFn: ?*const fn (ctx: *anyopaque, model: []const u8) anyerror!void = null,
    /// Set the reserved reasoning-token budget. `null` clears the override
    /// (fall back to config); `0` disables reasoning reservation.
    setMaxThinkingTokensFn: ?*const fn (ctx: *anyopaque, tokens: ?u64) anyerror!void = null,
};

/// Dispatch a decoded live-control `control_request` and return the encoded
/// `control_response` line (NDJSON, newline-terminated; caller owns it).
///
/// Handles `interrupt`, `set_permission_mode`, `set_model`, and
/// `set_max_thinking_tokens`. Any other subtype (including `.unsupported`) gets
/// an error response naming the unsupported subtype - this function is only the
/// live-control slice of the dispatch; the can_use_tool / initialize /
/// hook_callback / elicitation subtypes are owned by their own tasks and routed
/// before this is reached. A missing mutator function or a mutator error also
/// produces an error response (never a crash). The error responses carry an
/// empty `pending_permission_requests` array for shape stability.
pub fn dispatchLiveControl(
    allocator: std.mem.Allocator,
    req: ControlRequest,
    mutator: LiveControlMutator,
) ![]u8 {
    switch (req.subtype) {
        .interrupt => {
            const fnptr = mutator.interruptFn orelse
                return encodeErrorResponse(allocator, req.request_id, "interrupt not supported in this session", &.{});
            fnptr(mutator.ctx) catch |err| {
                return errorResponseFromErr(allocator, req.request_id, err);
            };
            return encodeSuccessResponse(allocator, req.request_id, "");
        },
        .set_permission_mode => {
            const mode = parseStringField(req.raw_request, "mode") orelse
                return encodeErrorResponse(allocator, req.request_id, "set_permission_mode missing 'mode'", &.{});
            const fnptr = mutator.setPermissionModeFn orelse
                return encodeErrorResponse(allocator, req.request_id, "set_permission_mode not supported in this session", &.{});
            fnptr(mutator.ctx, mode) catch |err| {
                return errorResponseFromErr(allocator, req.request_id, err);
            };
            return encodeSuccessResponse(allocator, req.request_id, "");
        },
        .set_model => {
            const model = parseStringField(req.raw_request, "model") orelse
                return encodeErrorResponse(allocator, req.request_id, "set_model missing 'model'", &.{});
            const fnptr = mutator.setModelFn orelse
                return encodeErrorResponse(allocator, req.request_id, "set_model not supported in this session", &.{});
            fnptr(mutator.ctx, model) catch |err| {
                return errorResponseFromErr(allocator, req.request_id, err);
            };
            return encodeSuccessResponse(allocator, req.request_id, "");
        },
        .set_max_thinking_tokens => {
            // `max_thinking_tokens` is an integer; absent or null clears the
            // override. We parse it from the raw inner request as an optional.
            const tokens = parseOptionalU64Field(req.raw_request, "max_thinking_tokens");
            const fnptr = mutator.setMaxThinkingTokensFn orelse
                return encodeErrorResponse(allocator, req.request_id, "set_max_thinking_tokens not supported in this session", &.{});
            fnptr(mutator.ctx, tokens) catch |err| {
                return errorResponseFromErr(allocator, req.request_id, err);
            };
            return encodeSuccessResponse(allocator, req.request_id, "");
        },
        else => {
            const msg = std.fmt.allocPrint(allocator, "unsupported control subtype: {s}", .{req.subtype_raw}) catch
                return encodeErrorResponse(allocator, req.request_id, "unsupported control subtype", &.{});
            defer allocator.free(msg);
            return encodeErrorResponse(allocator, req.request_id, msg, &.{});
        },
    }
}

/// Build an error response from a Zig error value, embedding the error name so
/// the host sees why the mutation failed (e.g. "set_model failed: UnknownModel").
fn errorResponseFromErr(allocator: std.mem.Allocator, request_id: []const u8, err: anyerror) ![]u8 {
    const msg = try std.fmt.allocPrint(allocator, "control mutation failed: {s}", .{@errorName(err)});
    defer allocator.free(msg);
    return encodeErrorResponse(allocator, request_id, msg, &.{});
}

/// Parse a string-valued field out of the raw inner `request` JSON. Returns the
/// borrowed slice (valid as long as `raw` is) or null when absent / non-string.
/// Used by the live-control handlers to pull `mode` / `model` without re-walking
/// a full value tree (we already have the raw span from decodeRequest).
fn parseStringField(raw: []const u8, field: []const u8) ?[]const u8 {
    const span = scanRawValueSpanInLine(raw, field) orelse return null;
    if (span.len < 2 or span[0] != '"' or span[span.len - 1] != '"') return null;
    return span[1 .. span.len - 1];
}

/// Parse an integer field as an optional u64. Returns null when the field is
/// absent, JSON `null`, or not a non-negative integer literal. The reference
/// treats absent and `null` identically (clear the override), so both map to
/// null here.
fn parseOptionalU64Field(raw: []const u8, field: []const u8) ?u64 {
    const span = scanRawValueSpanInLine(raw, field) orelse return null;
    if (std.mem.eql(u8, span, "null")) return null;
    return std.fmt.parseInt(u64, span, 10) catch null;
}

/// Like scanRawValueSpan but works directly on a raw JSON line without a parsed
/// ObjectMap (the live-control handlers only have the raw inner `request`
/// string). Finds the `"field"` key token, skips to its value, and returns the
/// value span. Returns null when the key is not present as an object key.
fn scanRawValueSpanInLine(source: []const u8, key: []const u8) ?[]const u8 {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, source, search_from, key)) |key_at| {
        search_from = key_at + 1;
        if (key_at == 0 or source[key_at - 1] != '"') continue;
        const after_key = key_at + key.len;
        if (after_key >= source.len or source[after_key] != '"') continue;
        var i = after_key + 1;
        while (i < source.len and (source[i] == ' ' or source[i] == '\t')) i += 1;
        if (i >= source.len or source[i] != ':') continue;
        i += 1;
        while (i < source.len and (source[i] == ' ' or source[i] == '\t' or source[i] == '\n' or source[i] == '\r')) i += 1;
        if (i >= source.len) return null;
        return scanValueSpan(source, i);
    }
    return null;
}

// --- sdk-headless-10: initialize handshake + init response ------------------
//
// The host opens an SDK session with a single `initialize` control_request that
// configures the session (systemPrompt / appendSystemPrompt overrides, SDK
// agents, sdkMcpServers, a structured-output jsonSchema, promptSuggestions) and
// expects an init response enumerating what the session can do: the available
// slash commands, agents, models, output styles, the account stub, and the CLI
// pid. A second `initialize` is rejected with "Already initialized".
//
// Reference behavior + file:line:
//   controlSchemas.ts:57   SDKControlInitializeRequestSchema
//   controlSchemas.ts:77   SDKControlInitializeResponseSchema
//   print.ts:2863          initialize dispatch
//   print.ts:4339          handleInitializeRequest (double-init -> error)
//
// Design (same rationale as the LiveControlMutator vtable above): the dispatch
// lives here, but applying the request fields to the live session and gathering
// the response registries are behind a small type-erased view so this module
// does not import the heavy agent_runtime / registry modules. The real session
// loop fills the applier with AgentRuntime methods and the response data from
// the command/agent/model/output-style registries; tests fill both with
// stubs/hand-built data and assert the state mutation + response shape.
//
// Account / fast_mode_state are ant-specific (account login, internal fast
// mode). Per the Task H risk note we emit a minimal `account` object and omit
// `fast_mode_state` rather than fabricating fields.

/// A type-erased view of the session knobs an `initialize` request turns. Each
/// callback is optional: a null function means "this session does not honor
/// that field" and the field is silently skipped (the reference also treats
/// every initialize field as optional). The raw-JSON callbacks
/// (`registerAgents`, `setJsonSchema`) receive the field value verbatim as it
/// appeared on the wire (a valid JSON object); the implementation parses/dupes
/// what it keeps. String callbacks borrow for the call only.
pub const InitializeApplier = struct {
    ctx: *anyopaque,
    /// Override the session system prompt (request `systemPrompt`).
    setSystemPromptFn: ?*const fn (ctx: *anyopaque, prompt: []const u8) anyerror!void = null,
    /// Override / append to the session system prompt (request
    /// `appendSystemPrompt`).
    setAppendSystemPromptFn: ?*const fn (ctx: *anyopaque, prompt: []const u8) anyerror!void = null,
    /// Register SDK-provided agent definitions (request `agents`, raw JSON
    /// object keyed by agent type).
    registerAgentsFn: ?*const fn (ctx: *anyopaque, agents_json: []const u8) anyerror!void = null,
    /// Register SDK MCP server placeholders (request `sdkMcpServers`, raw JSON
    /// array of names).
    registerSdkMcpServersFn: ?*const fn (ctx: *anyopaque, servers_json: []const u8) anyerror!void = null,
    /// Store the structured-output schema (request `jsonSchema`, raw JSON
    /// object).
    setJsonSchemaFn: ?*const fn (ctx: *anyopaque, schema_json: []const u8) anyerror!void = null,
    /// Toggle prompt suggestions (request `promptSuggestions`, bool).
    setPromptSuggestionsFn: ?*const fn (ctx: *anyopaque, enabled: bool) anyerror!void = null,
};

/// One slash command in the init response (`commands` array entry). All slices
/// borrowed from the caller's registries.
pub const CommandInfo = struct {
    name: []const u8,
    description: []const u8 = "",
    argument_hint: []const u8 = "",
};

/// One agent in the init response (`agents` array entry). `model` of "" or the
/// "inherit" sentinel is normalized to omitted (matches print.ts:4465).
pub const AgentInfo = struct {
    name: []const u8,
    description: []const u8 = "",
    model: []const u8 = "",
};

/// The registry data the caller gathers for the init response. `models_json`
/// and `account_json` are passed as raw JSON (an array and an object
/// respectively) so this layer stays agnostic to the model-registry and
/// account shapes; empty defaults keep the response shape stable. All slices
/// are borrowed.
pub const InitResponseData = struct {
    commands: []const CommandInfo = &.{},
    agents: []const AgentInfo = &.{},
    output_style: []const u8 = "default",
    available_output_styles: []const []const u8 = &.{},
    /// Raw JSON array of ModelInfo objects (already valid JSON), or "[]".
    models_json: []const u8 = "[]",
    /// Raw JSON object for the account stub (already valid JSON), or "{}".
    account_json: []const u8 = "{}",
    /// CLI process pid (for tmux socket isolation in the reference). 0 -> the
    /// `pid` key is omitted (the reference marks it optional/internal).
    pid: i64 = 0,
};

/// Dispatch a decoded `initialize` control_request and return the encoded
/// `control_response` line (NDJSON, newline-terminated; caller owns it).
///
/// When `already_initialized` is true, returns an error response with the
/// message "Already initialized" (matches print.ts:4360), carrying an empty
/// `pending_permission_requests` array for shape stability. Otherwise it applies
/// each present request field through `applier` (skipping any whose callback is
/// null or whose field is absent), then builds the success response from
/// `response_data`. An applier callback error becomes an error response (never a
/// crash). The caller is responsible for flipping its own one-time `initialized`
/// flag (see StructuredIo init state) on a success return.
pub fn dispatchInitialize(
    allocator: std.mem.Allocator,
    req: ControlRequest,
    already_initialized: bool,
    applier: InitializeApplier,
    response_data: InitResponseData,
) ![]u8 {
    if (already_initialized) {
        return encodeErrorResponse(allocator, req.request_id, "Already initialized", &.{});
    }

    // Apply each present field. The reference treats every field as optional;
    // an absent field (no raw span) or an unwired callback is a silent skip.
    applyInitFields(req.raw_request, applier) catch |err| {
        return errorResponseFromErr(allocator, req.request_id, err);
    };

    const response_json = try buildInitResponse(allocator, response_data);
    defer allocator.free(response_json);
    return encodeSuccessResponse(allocator, req.request_id, response_json);
}

/// Apply the present initialize-request fields through the applier. Pure helper
/// split out so a callback error can be mapped to an error response by the
/// caller. Skips absent fields and null callbacks.
fn applyInitFields(raw_request: []const u8, applier: InitializeApplier) !void {
    if (applier.setSystemPromptFn) |f| {
        if (parseStringField(raw_request, "systemPrompt")) |v| try f(applier.ctx, v);
    }
    if (applier.setAppendSystemPromptFn) |f| {
        if (parseStringField(raw_request, "appendSystemPrompt")) |v| try f(applier.ctx, v);
    }
    if (applier.registerAgentsFn) |f| {
        if (scanRawValueSpanInLine(raw_request, "agents")) |v| {
            if (!std.mem.eql(u8, v, "null")) try f(applier.ctx, v);
        }
    }
    if (applier.registerSdkMcpServersFn) |f| {
        if (scanRawValueSpanInLine(raw_request, "sdkMcpServers")) |v| {
            if (!std.mem.eql(u8, v, "null")) try f(applier.ctx, v);
        }
    }
    if (applier.setJsonSchemaFn) |f| {
        if (scanRawValueSpanInLine(raw_request, "jsonSchema")) |v| {
            if (!std.mem.eql(u8, v, "null")) try f(applier.ctx, v);
        }
    }
    if (applier.setPromptSuggestionsFn) |f| {
        if (parseBoolField(raw_request, "promptSuggestions")) |v| try f(applier.ctx, v);
    }
}

/// Build the inner `response` object for a successful initialize, as raw JSON
/// (no trailing newline -- encodeSuccessResponse wraps it). Carries `commands`,
/// `agents`, `output_style`, `available_output_styles`, `models`, `account`, and
/// (when nonzero) `pid`. The caller owns the returned slice.
pub fn buildInitResponse(allocator: std.mem.Allocator, data: InitResponseData) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"commands\":[");
    for (data.commands, 0..) |cmd, idx| {
        if (idx != 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try writeJsonString(w, cmd.name);
        try w.writeAll(",\"description\":");
        try writeJsonString(w, cmd.description);
        try w.writeAll(",\"argumentHint\":");
        try writeJsonString(w, cmd.argument_hint);
        try w.writeAll("}");
    }
    try w.writeAll("],\"agents\":[");
    for (data.agents, 0..) |agent, idx| {
        if (idx != 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try writeJsonString(w, agent.name);
        try w.writeAll(",\"description\":");
        try writeJsonString(w, agent.description);
        // 'inherit' is an internal sentinel; normalize it (and empty) to an
        // omitted model (matches print.ts:4465).
        if (agent.model.len > 0 and !std.mem.eql(u8, agent.model, "inherit")) {
            try w.writeAll(",\"model\":");
            try writeJsonString(w, agent.model);
        }
        try w.writeAll("}");
    }
    try w.writeAll("],\"output_style\":");
    try writeJsonString(w, data.output_style);
    try w.writeAll(",\"available_output_styles\":[");
    for (data.available_output_styles, 0..) |style, idx| {
        if (idx != 0) try w.writeAll(",");
        try writeJsonString(w, style);
    }
    try w.writeAll("],\"models\":");
    try w.writeAll(if (data.models_json.len > 0) data.models_json else "[]");
    try w.writeAll(",\"account\":");
    try w.writeAll(if (data.account_json.len > 0) data.account_json else "{}");
    if (data.pid != 0) {
        try w.print(",\"pid\":{d}", .{data.pid});
    }
    try w.writeAll("}");
    return out.toOwnedSlice();
}

/// Parse a boolean field out of the raw inner `request` JSON. Returns null when
/// absent or not a `true`/`false` literal. Used by the initialize handler for
/// `promptSuggestions`.
fn parseBoolField(raw: []const u8, field: []const u8) ?bool {
    const span = scanRawValueSpanInLine(raw, field) orelse return null;
    if (std.mem.eql(u8, span, "true")) return true;
    if (std.mem.eql(u8, span, "false")) return false;
    return null;
}

// --- sdk-headless-11: hook_callback / elicitation relays --------------------
//
// When the session is host-driven (input-format stream-json) the CLI does not
// run an SDK-registered hook as a local subprocess, nor does it prompt the
// local user for an MCP elicitation. Instead it *originates* a control_request
// back to the host and resolves the local decision from the host's
// control_response:
//   - hook_callback : a hook registered via `initialize` runs on the host. The
//     CLI emits `{subtype:"hook_callback", callback_id, input, tool_use_id}`
//     and maps the host's response (the HookJSONOutput analogue) back to the
//     hook decision.
//   - elicitation : an MCP elicitation is answered by the host. The CLI emits
//     `{subtype:"elicitation", mcp_server_name, message, mode, url,
//     elicitation_id, requested_schema}` and maps the host's
//     `{action: accept|decline|cancel, content?}` response to the same
//     `{"action":...,"content":...}` shape the in-process path produces.
//
// Both relays are NO-OPS on the local code path: they are only constructed and
// invoked by the stream-json session loop, so when no SDK host is driving the
// session the existing local-subprocess hook path (core/hooks.zig) and the
// in-process elicitation path (agent_history.zig handleMcpElicitationRequest)
// run unchanged. That keeps this change surgical: it adds the relay path
// without touching the local paths.
//
// Reference behavior + file:line:
//   controlSchemas.ts:363   SDKHookCallbackRequestSchema
//   controlSchemas.ts:522   elicitation request schema
//   controlSchemas.ts:538   elicitation response schema
//   structuredIO.ts:661     createHookCallback()
//   structuredIO.ts:694     handleElicitation()
//
// Concurrency model (same as the can_use_tool relay in structured_io.zig and
// the control.zig PendingMap note): zcode is synchronous one-turn today and the
// runtime does not expose cooperative green-thread blocking, so the relay does
// NOT block a fiber. The relay calls the supplied `RelayChannel`, which is
// responsible for writing the request envelope to the host AND pumping the
// stdin stream until the matching control_response arrives, returning the
// resolved raw response body. Tests supply a stub channel feeding pre-canned
// responses, so every transition is synchronously testable.

/// A type-erased channel that sends a CLI-originated inner `request` object
/// (raw JSON whose first field is the subtype) to the host and returns the
/// resolved raw `response` body JSON (caller owns the returned slice). Unlike
/// the can_use_tool `Dispatcher` (which collapses the answer to allow/deny),
/// hook_callback and elicitation responses carry arbitrary structured bodies,
/// so the channel returns the raw JSON. A host error response or a transport
/// failure surfaces as an error (the relay then falls back / fails safe).
///
/// The real channel (wired by the stream-json session loop) drives the
/// PendingMap state machine: register an id, write the envelope, pump stdin
/// until the entry resolves, then dupe out `response_json`. Tests supply a stub.
pub const RelayChannel = struct {
    ctx: *anyopaque,
    /// Send the inner request and return the resolved raw `response` body JSON.
    /// `request_json` borrows for the call; the returned slice is owned by the
    /// caller and freed with `allocator`.
    requestFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, request_json: []const u8) anyerror![]u8,

    fn request(self: RelayChannel, allocator: std.mem.Allocator, request_json: []const u8) anyerror![]u8 {
        return self.requestFn(self.ctx, allocator, request_json);
    }
};

/// Build the inner `hook_callback` `request` object as raw JSON. Carries the
/// reference fields (callback_id, input, tool_use_id). `input_json` is embedded
/// verbatim (it is already a valid JSON value - the HookInput); the rest are
/// escaped. `tool_use_id` is omitted when empty. The caller owns the returned
/// slice. (No trailing newline: this is the inner `request` body that
/// encodeRequest wraps.)
pub fn buildHookCallbackRequest(
    allocator: std.mem.Allocator,
    callback_id: []const u8,
    input_json: []const u8,
    tool_use_id: []const u8,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"subtype\":\"hook_callback\",\"callback_id\":");
    try writeJsonString(w, callback_id);
    try w.writeAll(",\"input\":");
    // input_json is already a JSON value; default to {} when empty.
    try w.writeAll(if (input_json.len > 0) input_json else "{}");
    if (tool_use_id.len > 0) {
        try w.writeAll(",\"tool_use_id\":");
        try writeJsonString(w, tool_use_id);
    }
    try w.writeAll("}");
    return out.toOwnedSlice();
}

/// Relay an SDK-registered hook to the host. Emits a `hook_callback`
/// control_request via the channel and returns the host's raw response body
/// JSON (the HookJSONOutput analogue: e.g. `{}`, `{"decision":"block",...}`)
/// for the local hook machinery to interpret. The caller owns the returned
/// slice. A channel error (transport failure / host error response) propagates
/// so the caller can fail safe (the reference treats a failed hook callback as
/// "no decision" - continue).
pub fn relayHookCallback(
    allocator: std.mem.Allocator,
    channel: RelayChannel,
    callback_id: []const u8,
    input_json: []const u8,
    tool_use_id: []const u8,
) ![]u8 {
    const request_json = try buildHookCallbackRequest(allocator, callback_id, input_json, tool_use_id);
    defer allocator.free(request_json);
    return channel.request(allocator, request_json);
}

/// Build the inner `elicitation` `request` object as raw JSON. Carries the
/// reference fields (mcp_server_name, message, mode, url, elicitation_id,
/// requested_schema). `requested_schema_json` is embedded verbatim (already a
/// valid JSON object); `url` is omitted when empty (only set for url-mode);
/// the rest are escaped. The caller owns the returned slice. (No trailing
/// newline: this is the inner `request` body that encodeRequest wraps.)
pub fn buildElicitationRequest(
    allocator: std.mem.Allocator,
    mcp_server_name: []const u8,
    message: []const u8,
    mode: []const u8,
    url: []const u8,
    elicitation_id: []const u8,
    requested_schema_json: []const u8,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"subtype\":\"elicitation\",\"mcp_server_name\":");
    try writeJsonString(w, mcp_server_name);
    try w.writeAll(",\"message\":");
    try writeJsonString(w, message);
    try w.writeAll(",\"mode\":");
    try writeJsonString(w, if (mode.len > 0) mode else "form");
    if (url.len > 0) {
        try w.writeAll(",\"url\":");
        try writeJsonString(w, url);
    }
    if (elicitation_id.len > 0) {
        try w.writeAll(",\"elicitation_id\":");
        try writeJsonString(w, elicitation_id);
    }
    try w.writeAll(",\"requested_schema\":");
    try w.writeAll(if (requested_schema_json.len > 0) requested_schema_json else "{}");
    try w.writeAll("}");
    return out.toOwnedSlice();
}

/// Relay an MCP elicitation to the host. Emits an `elicitation` control_request
/// via the channel, then maps the host's `{action: accept|decline|cancel,
/// content?}` response into the same `{"action":...,"content":...}` JSON the
/// in-process path produces (agent_history.buildElicitationActionJson), so the
/// MCP caller sees an identical result whether the decision came from the host
/// or the local user. The caller owns the returned slice. A channel error
/// propagates so the caller can fall back to the local prompt / deny.
///
/// The host `action` is normalized: accept / decline survive; anything else
/// (including a missing action) maps to cancel (matches
/// buildElicitationActionJson). `content` is preserved only for accept (matches
/// the in-process shape).
pub fn relayElicitation(
    allocator: std.mem.Allocator,
    channel: RelayChannel,
    mcp_server_name: []const u8,
    message: []const u8,
    mode: []const u8,
    url: []const u8,
    elicitation_id: []const u8,
    requested_schema_json: []const u8,
) ![]u8 {
    const request_json = try buildElicitationRequest(
        allocator,
        mcp_server_name,
        message,
        mode,
        url,
        elicitation_id,
        requested_schema_json,
    );
    defer allocator.free(request_json);

    const response_json = try channel.request(allocator, request_json);
    defer allocator.free(response_json);

    return elicitationActionFromResponse(allocator, response_json);
}

/// Map a host `elicitation` response body (`{action, content?}`) into the
/// canonical `{"action":...,"content":...}` action JSON the in-process
/// elicitation path produces. Pulls `action` and (for accept) the raw `content`
/// span out of the response body. The caller owns the returned slice. An empty
/// or unparseable body maps to a `cancel` action (fail safe).
pub fn elicitationActionFromResponse(allocator: std.mem.Allocator, response_json: []const u8) ![]u8 {
    const raw_action = parseStringField(response_json, "action") orelse "cancel";
    // Normalize to the three canonical actions; unknown -> cancel.
    const action = blk: {
        if (std.ascii.eqlIgnoreCase(raw_action, "accept")) break :blk "accept";
        if (std.ascii.eqlIgnoreCase(raw_action, "decline")) break :blk "decline";
        break :blk "cancel";
    };

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"action\":");
    try writeJsonString(w, action);
    // `content` rides along only for accept (matches the in-process shape).
    if (std.mem.eql(u8, action, "accept")) {
        if (scanRawValueSpanInLine(response_json, "content")) |content_span| {
            if (!std.mem.eql(u8, content_span, "null")) {
                try w.writeAll(",\"content\":");
                try w.writeAll(content_span);
            }
        }
    }
    try w.writeAll("}");
    return out.toOwnedSlice();
}

const testing = std.testing;

test "ControlSubtype round-trips through strings; unknown maps to unsupported" {
    const all = [_]ControlSubtype{
        .interrupt, .can_use_tool,            .initialize,    .set_permission_mode,
        .set_model, .set_max_thinking_tokens, .hook_callback, .elicitation,
    };
    for (all) |s| {
        try testing.expectEqual(s, ControlSubtype.fromString(s.toString()));
    }
    try testing.expectEqual(ControlSubtype.unsupported, ControlSubtype.fromString("nope"));
}

test "decodeRequest: round-trips request_id, subtype, and raw inner request for each supported subtype" {
    const allocator = testing.allocator;
    const cases = [_]struct { line: []const u8, subtype: ControlSubtype }{
        .{ .line = "{\"type\":\"control_request\",\"request_id\":\"r1\",\"request\":{\"subtype\":\"interrupt\"}}", .subtype = .interrupt },
        .{ .line = "{\"type\":\"control_request\",\"request_id\":\"r2\",\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"Bash\",\"input\":{\"command\":\"ls\"}}}", .subtype = .can_use_tool },
        .{ .line = "{\"type\":\"control_request\",\"request_id\":\"r3\",\"request\":{\"subtype\":\"initialize\"}}", .subtype = .initialize },
        .{ .line = "{\"type\":\"control_request\",\"request_id\":\"r4\",\"request\":{\"subtype\":\"set_permission_mode\",\"mode\":\"acceptEdits\"}}", .subtype = .set_permission_mode },
        .{ .line = "{\"type\":\"control_request\",\"request_id\":\"r5\",\"request\":{\"subtype\":\"set_model\",\"model\":\"mock-agent\"}}", .subtype = .set_model },
        .{ .line = "{\"type\":\"control_request\",\"request_id\":\"r6\",\"request\":{\"subtype\":\"set_max_thinking_tokens\",\"max_thinking_tokens\":1024}}", .subtype = .set_max_thinking_tokens },
        .{ .line = "{\"type\":\"control_request\",\"request_id\":\"r7\",\"request\":{\"subtype\":\"hook_callback\",\"callback_id\":\"h1\"}}", .subtype = .hook_callback },
        .{ .line = "{\"type\":\"control_request\",\"request_id\":\"r8\",\"request\":{\"subtype\":\"elicitation\",\"elicitation_id\":\"e1\"}}", .subtype = .elicitation },
    };
    for (cases) |c| {
        var decoded = try decodeRequest(allocator, c.line);
        defer decoded.deinit();
        try testing.expectEqual(c.subtype, decoded.request.subtype);
        // The inner request raw JSON survives and still contains the subtype.
        try testing.expect(std.mem.indexOf(u8, decoded.request.raw_request, "\"subtype\"") != null);
    }
}

test "decodeRequest: unknown subtype decodes as .unsupported with the raw string preserved" {
    const allocator = testing.allocator;
    var decoded = try decodeRequest(
        allocator,
        "{\"type\":\"control_request\",\"request_id\":\"rX\",\"request\":{\"subtype\":\"teleport\"}}",
    );
    defer decoded.deinit();
    try testing.expectEqual(ControlSubtype.unsupported, decoded.request.subtype);
    try testing.expectEqualStrings("teleport", decoded.request.subtype_raw);
    try testing.expectEqualStrings("rX", decoded.request.request_id);
}

test "decodeRequest: rejects bad envelopes" {
    const allocator = testing.allocator;
    try testing.expectError(error.InvalidEnvelope, decodeRequest(allocator, "not json"));
    try testing.expectError(error.InvalidEnvelope, decodeRequest(allocator, "[1,2,3]"));
    try testing.expectError(error.InvalidEnvelope, decodeRequest(allocator, "{\"type\":\"control_response\",\"request_id\":\"r1\",\"request\":{\"subtype\":\"interrupt\"}}"));
    try testing.expectError(error.MissingRequestId, decodeRequest(allocator, "{\"type\":\"control_request\",\"request\":{\"subtype\":\"interrupt\"}}"));
    try testing.expectError(error.MissingSubtype, decodeRequest(allocator, "{\"type\":\"control_request\",\"request_id\":\"r1\",\"request\":{}}"));
}

test "encodeRequest / encodeSuccessResponse / encodeCancelRequest produce parseable NDJSON" {
    const allocator = testing.allocator;

    const req = try encodeRequest(allocator, "cli-1", "{\"subtype\":\"can_use_tool\",\"tool_name\":\"Bash\"}");
    defer allocator.free(req);
    try testing.expect(std.mem.endsWith(u8, req, "\n"));
    {
        var p = try std.json.parseFromSlice(std.json.Value, allocator, std.mem.trimEnd(u8, req, "\n"), .{});
        defer p.deinit();
        try testing.expectEqualStrings("control_request", p.value.object.get("type").?.string);
        try testing.expectEqualStrings("cli-1", p.value.object.get("request_id").?.string);
        try testing.expectEqualStrings("can_use_tool", p.value.object.get("request").?.object.get("subtype").?.string);
    }

    const ok = try encodeSuccessResponse(allocator, "r1", "{\"behavior\":\"allow\"}");
    defer allocator.free(ok);
    {
        var p = try std.json.parseFromSlice(std.json.Value, allocator, std.mem.trimEnd(u8, ok, "\n"), .{});
        defer p.deinit();
        const resp = p.value.object.get("response").?.object;
        try testing.expectEqualStrings("success", resp.get("subtype").?.string);
        try testing.expectEqualStrings("r1", resp.get("request_id").?.string);
        try testing.expectEqualStrings("allow", resp.get("response").?.object.get("behavior").?.string);
    }

    const cancel = try encodeCancelRequest(allocator, "r1");
    defer allocator.free(cancel);
    {
        var p = try std.json.parseFromSlice(std.json.Value, allocator, std.mem.trimEnd(u8, cancel, "\n"), .{});
        defer p.deinit();
        try testing.expectEqualStrings("control_cancel_request", p.value.object.get("type").?.string);
        try testing.expectEqualStrings("r1", p.value.object.get("request_id").?.string);
    }
}

test "encodeErrorResponse: error shape carries a pending_permission_requests array" {
    const allocator = testing.allocator;
    const pending = [_][]const u8{
        "{\"type\":\"control_request\",\"request_id\":\"r9\",\"request\":{\"subtype\":\"can_use_tool\"}}",
    };
    const err_line = try encodeErrorResponse(allocator, "r1", "Already initialized", &pending);
    defer allocator.free(err_line);

    var p = try std.json.parseFromSlice(std.json.Value, allocator, std.mem.trimEnd(u8, err_line, "\n"), .{});
    defer p.deinit();
    const resp = p.value.object.get("response").?.object;
    try testing.expectEqualStrings("error", resp.get("subtype").?.string);
    try testing.expectEqualStrings("r1", resp.get("request_id").?.string);
    try testing.expectEqualStrings("Already initialized", resp.get("error").?.string);
    const arr = resp.get("pending_permission_requests").?.array;
    try testing.expectEqual(@as(usize, 1), arr.items.len);
    try testing.expectEqualStrings("r9", arr.items[0].object.get("request_id").?.string);

    // Empty pending list still emits an array (stable shape).
    const empty = try encodeErrorResponse(allocator, "r2", "boom", &.{});
    defer allocator.free(empty);
    var p2 = try std.json.parseFromSlice(std.json.Value, allocator, std.mem.trimEnd(u8, empty, "\n"), .{});
    defer p2.deinit();
    try testing.expectEqual(@as(usize, 0), p2.value.object.get("response").?.object.get("pending_permission_requests").?.array.items.len);
}

test "PendingMap: register tracks a pending entry with a unique cli-prefixed id" {
    const allocator = testing.allocator;
    var pm = PendingMap.init(allocator);
    defer pm.deinit();

    const a = try pm.register();
    defer allocator.free(a.request_id);
    const b = try pm.register();
    defer allocator.free(b.request_id);

    try testing.expect(std.mem.startsWith(u8, a.request_id, "cli-"));
    try testing.expect(!std.mem.eql(u8, a.request_id, b.request_id));
    try testing.expectEqual(PendingState.pending, a.entry.state);
    try testing.expectEqual(@as(usize, 2), pm.count());
}

test "PendingMap.handleControlResponse: resolves a matching success entry and captures the response body" {
    const allocator = testing.allocator;
    var pm = PendingMap.init(allocator);
    defer pm.deinit();

    const r = try pm.register();
    defer allocator.free(r.request_id);

    const line = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"control_response\",\"response\":{{\"subtype\":\"success\",\"request_id\":\"{s}\",\"response\":{{\"behavior\":\"allow\"}}}}}}",
        .{r.request_id},
    );
    defer allocator.free(line);

    try testing.expect(try pm.handleControlResponse(line));
    try testing.expectEqual(PendingState.resolved, r.entry.state);
    try testing.expect(r.entry.is_success);
    try testing.expect(std.mem.indexOf(u8, r.entry.response_json, "allow") != null);
}

test "PendingMap.handleControlResponse: an error response captures the error string and is_success=false" {
    const allocator = testing.allocator;
    var pm = PendingMap.init(allocator);
    defer pm.deinit();

    const r = try pm.register();
    defer allocator.free(r.request_id);

    const line = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"control_response\",\"response\":{{\"subtype\":\"error\",\"request_id\":\"{s}\",\"error\":\"denied\"}}}}",
        .{r.request_id},
    );
    defer allocator.free(line);

    try testing.expect(try pm.handleControlResponse(line));
    try testing.expectEqual(PendingState.resolved, r.entry.state);
    try testing.expect(!r.entry.is_success);
    try testing.expectEqualStrings("denied", r.entry.response_json);
}

test "PendingMap.handleControlResponse: an orphan response is a no-op and leaves the map unchanged" {
    const allocator = testing.allocator;
    var pm = PendingMap.init(allocator);
    defer pm.deinit();

    const r = try pm.register();
    defer allocator.free(r.request_id);

    // Response for an id nobody registered.
    const orphan = "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"ghost\"}}";
    try testing.expect(!(try pm.handleControlResponse(orphan)));
    try testing.expectEqual(@as(usize, 1), pm.count());
    try testing.expectEqual(PendingState.pending, r.entry.state);

    // A garbage line is also a no-op (no crash).
    try testing.expect(!(try pm.handleControlResponse("not even json")));
    try testing.expect(!(try pm.handleControlResponse("{\"type\":\"control_response\"}")));
}

test "PendingMap.handleControlResponse: a duplicate response after resolve is ignored" {
    const allocator = testing.allocator;
    var pm = PendingMap.init(allocator);
    defer pm.deinit();

    const r = try pm.register();
    defer allocator.free(r.request_id);

    const line = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"control_response\",\"response\":{{\"subtype\":\"success\",\"request_id\":\"{s}\"}}}}",
        .{r.request_id},
    );
    defer allocator.free(line);

    try testing.expect(try pm.handleControlResponse(line)); // first resolves
    try testing.expect(!(try pm.handleControlResponse(line))); // duplicate ignored
    try testing.expectEqual(PendingState.resolved, r.entry.state);
}

test "PendingMap.markCancelled and release transition and free a pending entry" {
    const allocator = testing.allocator;
    var pm = PendingMap.init(allocator);
    defer pm.deinit();

    const r = try pm.register();
    const id = r.request_id; // keep a copy; release frees the map's key, not this

    try testing.expect(pm.markCancelled(id));
    try testing.expectEqual(PendingState.cancelled, r.entry.state);
    // Cancelling again (no longer pending) is a no-op.
    try testing.expect(!pm.markCancelled(id));
    // Unknown id is a no-op.
    try testing.expect(!pm.markCancelled("nope"));

    pm.release(id);
    try testing.expectEqual(@as(usize, 0), pm.count());
    allocator.free(id);
}

// --- sdk-headless-06 live-control dispatch tests ----------------------------

// A recording stub for the LiveControlMutator vtable: captures which knob was
// turned and with what value, so the dispatch can be exercised without a full
// AgentRuntime.
const MutatorRecorder = struct {
    allocator: std.mem.Allocator,
    interrupted: bool = false,
    mode: ?[]u8 = null,
    model: ?[]u8 = null,
    thinking_set: bool = false,
    thinking: ?u64 = null,
    fail_model: bool = false,

    fn deinit(self: *MutatorRecorder) void {
        if (self.mode) |m| self.allocator.free(m);
        if (self.model) |m| self.allocator.free(m);
    }

    fn onInterrupt(ctx: *anyopaque) anyerror!void {
        const self: *MutatorRecorder = @ptrCast(@alignCast(ctx));
        self.interrupted = true;
    }
    fn onSetMode(ctx: *anyopaque, mode: []const u8) anyerror!void {
        const self: *MutatorRecorder = @ptrCast(@alignCast(ctx));
        if (self.mode) |m| self.allocator.free(m);
        self.mode = try self.allocator.dupe(u8, mode);
    }
    fn onSetModel(ctx: *anyopaque, model: []const u8) anyerror!void {
        const self: *MutatorRecorder = @ptrCast(@alignCast(ctx));
        if (self.fail_model) return error.UnknownModel;
        if (self.model) |m| self.allocator.free(m);
        self.model = try self.allocator.dupe(u8, model);
    }
    fn onSetThinking(ctx: *anyopaque, tokens: ?u64) anyerror!void {
        const self: *MutatorRecorder = @ptrCast(@alignCast(ctx));
        self.thinking_set = true;
        self.thinking = tokens;
    }

    fn mutator(self: *MutatorRecorder) LiveControlMutator {
        return .{
            .ctx = @ptrCast(self),
            .interruptFn = onInterrupt,
            .setPermissionModeFn = onSetMode,
            .setModelFn = onSetModel,
            .setMaxThinkingTokensFn = onSetThinking,
        };
    }
};

// Helper: decode a control_request line and dispatch it through a mutator,
// returning the parsed control_response. Frees the encoded line internally.
fn dispatchLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    mutator: LiveControlMutator,
) !std.json.Parsed(std.json.Value) {
    var decoded = try decodeRequest(allocator, line);
    defer decoded.deinit();
    const resp = try dispatchLiveControl(allocator, decoded.request, mutator);
    defer allocator.free(resp);
    return std.json.parseFromSlice(std.json.Value, allocator, std.mem.trimEnd(u8, resp, "\n"), .{});
}

test "dispatchLiveControl: set_model mutates the model and returns success with the matching request_id" {
    const allocator = testing.allocator;
    var rec = MutatorRecorder{ .allocator = allocator };
    defer rec.deinit();

    var p = try dispatchLine(
        allocator,
        "{\"type\":\"control_request\",\"request_id\":\"rm1\",\"request\":{\"subtype\":\"set_model\",\"model\":\"mock-agent\"}}",
        rec.mutator(),
    );
    defer p.deinit();

    const resp = p.value.object.get("response").?.object;
    try testing.expectEqualStrings("success", resp.get("subtype").?.string);
    try testing.expectEqualStrings("rm1", resp.get("request_id").?.string);
    try testing.expect(rec.model != null);
    try testing.expectEqualStrings("mock-agent", rec.model.?);
}

test "dispatchLiveControl: set_permission_mode mutates the mode and returns success" {
    const allocator = testing.allocator;
    var rec = MutatorRecorder{ .allocator = allocator };
    defer rec.deinit();

    var p = try dispatchLine(
        allocator,
        "{\"type\":\"control_request\",\"request_id\":\"rp1\",\"request\":{\"subtype\":\"set_permission_mode\",\"mode\":\"acceptEdits\"}}",
        rec.mutator(),
    );
    defer p.deinit();

    const resp = p.value.object.get("response").?.object;
    try testing.expectEqualStrings("success", resp.get("subtype").?.string);
    try testing.expectEqualStrings("rp1", resp.get("request_id").?.string);
    try testing.expect(rec.mode != null);
    try testing.expectEqualStrings("acceptEdits", rec.mode.?);
}

test "dispatchLiveControl: interrupt sets the abort flag and returns success" {
    const allocator = testing.allocator;
    var rec = MutatorRecorder{ .allocator = allocator };
    defer rec.deinit();

    var p = try dispatchLine(
        allocator,
        "{\"type\":\"control_request\",\"request_id\":\"ri1\",\"request\":{\"subtype\":\"interrupt\"}}",
        rec.mutator(),
    );
    defer p.deinit();

    try testing.expect(rec.interrupted);
    const resp = p.value.object.get("response").?.object;
    try testing.expectEqualStrings("success", resp.get("subtype").?.string);
    try testing.expectEqualStrings("ri1", resp.get("request_id").?.string);
}

test "dispatchLiveControl: set_max_thinking_tokens parses an integer and a null clear" {
    const allocator = testing.allocator;
    {
        var rec = MutatorRecorder{ .allocator = allocator };
        defer rec.deinit();
        var p = try dispatchLine(
            allocator,
            "{\"type\":\"control_request\",\"request_id\":\"rt1\",\"request\":{\"subtype\":\"set_max_thinking_tokens\",\"max_thinking_tokens\":4096}}",
            rec.mutator(),
        );
        defer p.deinit();
        try testing.expect(rec.thinking_set);
        try testing.expectEqual(@as(?u64, 4096), rec.thinking);
        try testing.expectEqualStrings("success", p.value.object.get("response").?.object.get("subtype").?.string);
    }
    {
        var rec = MutatorRecorder{ .allocator = allocator };
        defer rec.deinit();
        // An explicit null clears the override (maps to null, success).
        var p = try dispatchLine(
            allocator,
            "{\"type\":\"control_request\",\"request_id\":\"rt2\",\"request\":{\"subtype\":\"set_max_thinking_tokens\",\"max_thinking_tokens\":null}}",
            rec.mutator(),
        );
        defer p.deinit();
        try testing.expect(rec.thinking_set);
        try testing.expectEqual(@as(?u64, null), rec.thinking);
    }
    {
        var rec = MutatorRecorder{ .allocator = allocator };
        defer rec.deinit();
        // An absent field also clears (success, null).
        var p = try dispatchLine(
            allocator,
            "{\"type\":\"control_request\",\"request_id\":\"rt3\",\"request\":{\"subtype\":\"set_max_thinking_tokens\"}}",
            rec.mutator(),
        );
        defer p.deinit();
        try testing.expect(rec.thinking_set);
        try testing.expectEqual(@as(?u64, null), rec.thinking);
    }
}

test "dispatchLiveControl: a missing required field yields an error response" {
    const allocator = testing.allocator;
    var rec = MutatorRecorder{ .allocator = allocator };
    defer rec.deinit();

    var p = try dispatchLine(
        allocator,
        "{\"type\":\"control_request\",\"request_id\":\"re1\",\"request\":{\"subtype\":\"set_model\"}}",
        rec.mutator(),
    );
    defer p.deinit();

    const resp = p.value.object.get("response").?.object;
    try testing.expectEqualStrings("error", resp.get("subtype").?.string);
    try testing.expectEqualStrings("re1", resp.get("request_id").?.string);
    try testing.expect(std.mem.indexOf(u8, resp.get("error").?.string, "missing") != null);
    // Error responses always carry the array for shape stability.
    try testing.expectEqual(@as(usize, 0), resp.get("pending_permission_requests").?.array.items.len);
    // The model was NOT mutated.
    try testing.expect(rec.model == null);
}

test "dispatchLiveControl: a mutator error becomes an error response" {
    const allocator = testing.allocator;
    var rec = MutatorRecorder{ .allocator = allocator, .fail_model = true };
    defer rec.deinit();

    var p = try dispatchLine(
        allocator,
        "{\"type\":\"control_request\",\"request_id\":\"re2\",\"request\":{\"subtype\":\"set_model\",\"model\":\"bogus\"}}",
        rec.mutator(),
    );
    defer p.deinit();

    const resp = p.value.object.get("response").?.object;
    try testing.expectEqualStrings("error", resp.get("subtype").?.string);
    try testing.expect(std.mem.indexOf(u8, resp.get("error").?.string, "UnknownModel") != null);
}

test "dispatchLiveControl: an unwired knob yields a 'not supported' error response" {
    const allocator = testing.allocator;
    // A mutator with no functions wired: every subtype answers error.
    const empty: LiveControlMutator = .{ .ctx = undefined };

    var p = try dispatchLine(
        allocator,
        "{\"type\":\"control_request\",\"request_id\":\"re3\",\"request\":{\"subtype\":\"interrupt\"}}",
        empty,
    );
    defer p.deinit();

    const resp = p.value.object.get("response").?.object;
    try testing.expectEqualStrings("error", resp.get("subtype").?.string);
    try testing.expect(std.mem.indexOf(u8, resp.get("error").?.string, "not supported") != null);
}

test "dispatchLiveControl: a non-live subtype (can_use_tool) is reported unsupported here" {
    const allocator = testing.allocator;
    var rec = MutatorRecorder{ .allocator = allocator };
    defer rec.deinit();

    var p = try dispatchLine(
        allocator,
        "{\"type\":\"control_request\",\"request_id\":\"re4\",\"request\":{\"subtype\":\"can_use_tool\"}}",
        rec.mutator(),
    );
    defer p.deinit();

    const resp = p.value.object.get("response").?.object;
    try testing.expectEqualStrings("error", resp.get("subtype").?.string);
    try testing.expect(std.mem.indexOf(u8, resp.get("error").?.string, "unsupported control subtype") != null);
}

// --- sdk-headless-10 initialize dispatch tests ------------------------------

// A recording stub for the InitializeApplier vtable: captures which request
// fields were applied so the dispatch can be exercised without a runtime.
const InitRecorder = struct {
    allocator: std.mem.Allocator,
    system_prompt: ?[]u8 = null,
    append_system_prompt: ?[]u8 = null,
    agents_json: ?[]u8 = null,
    mcp_servers_json: ?[]u8 = null,
    json_schema: ?[]u8 = null,
    prompt_suggestions_set: bool = false,
    prompt_suggestions: bool = false,

    fn deinit(self: *InitRecorder) void {
        if (self.system_prompt) |v| self.allocator.free(v);
        if (self.append_system_prompt) |v| self.allocator.free(v);
        if (self.agents_json) |v| self.allocator.free(v);
        if (self.mcp_servers_json) |v| self.allocator.free(v);
        if (self.json_schema) |v| self.allocator.free(v);
    }

    fn onSystemPrompt(ctx: *anyopaque, prompt: []const u8) anyerror!void {
        const self: *InitRecorder = @ptrCast(@alignCast(ctx));
        if (self.system_prompt) |v| self.allocator.free(v);
        self.system_prompt = try self.allocator.dupe(u8, prompt);
    }
    fn onAppendSystemPrompt(ctx: *anyopaque, prompt: []const u8) anyerror!void {
        const self: *InitRecorder = @ptrCast(@alignCast(ctx));
        if (self.append_system_prompt) |v| self.allocator.free(v);
        self.append_system_prompt = try self.allocator.dupe(u8, prompt);
    }
    fn onAgents(ctx: *anyopaque, agents_json: []const u8) anyerror!void {
        const self: *InitRecorder = @ptrCast(@alignCast(ctx));
        if (self.agents_json) |v| self.allocator.free(v);
        self.agents_json = try self.allocator.dupe(u8, agents_json);
    }
    fn onSdkMcp(ctx: *anyopaque, servers_json: []const u8) anyerror!void {
        const self: *InitRecorder = @ptrCast(@alignCast(ctx));
        if (self.mcp_servers_json) |v| self.allocator.free(v);
        self.mcp_servers_json = try self.allocator.dupe(u8, servers_json);
    }
    fn onJsonSchema(ctx: *anyopaque, schema_json: []const u8) anyerror!void {
        const self: *InitRecorder = @ptrCast(@alignCast(ctx));
        if (self.json_schema) |v| self.allocator.free(v);
        self.json_schema = try self.allocator.dupe(u8, schema_json);
    }
    fn onPromptSuggestions(ctx: *anyopaque, enabled: bool) anyerror!void {
        const self: *InitRecorder = @ptrCast(@alignCast(ctx));
        self.prompt_suggestions_set = true;
        self.prompt_suggestions = enabled;
    }

    fn applier(self: *InitRecorder) InitializeApplier {
        return .{
            .ctx = @ptrCast(self),
            .setSystemPromptFn = onSystemPrompt,
            .setAppendSystemPromptFn = onAppendSystemPrompt,
            .registerAgentsFn = onAgents,
            .registerSdkMcpServersFn = onSdkMcp,
            .setJsonSchemaFn = onJsonSchema,
            .setPromptSuggestionsFn = onPromptSuggestions,
        };
    }
};

// A small canned response-data fixture used by the dispatch tests.
fn sampleResponseData() InitResponseData {
    const Static = struct {
        const commands = [_]CommandInfo{
            .{ .name = "help", .description = "Show help", .argument_hint = "" },
            .{ .name = "model", .description = "Switch model", .argument_hint = "<name>" },
        };
        const agents = [_]AgentInfo{
            .{ .name = "reviewer", .description = "Reviews code", .model = "mock-agent" },
            .{ .name = "inheritor", .description = "Inherits", .model = "inherit" },
        };
        const styles = [_][]const u8{ "default", "concise" };
    };
    return .{
        .commands = &Static.commands,
        .agents = &Static.agents,
        .output_style = "default",
        .available_output_styles = &Static.styles,
        .models_json = "[{\"model\":\"mock-agent\",\"displayName\":\"Mock\"}]",
        .account_json = "{\"apiProvider\":\"firstParty\"}",
        .pid = 4242,
    };
}

test "dispatchInitialize: applies appendSystemPrompt and returns success with commands/agents/models" {
    const allocator = testing.allocator;
    var rec = InitRecorder{ .allocator = allocator };
    defer rec.deinit();

    var decoded = try decodeRequest(
        allocator,
        "{\"type\":\"control_request\",\"request_id\":\"init-1\",\"request\":{\"subtype\":\"initialize\",\"appendSystemPrompt\":\"be terse\",\"jsonSchema\":{\"type\":\"object\"},\"agents\":{\"x\":{}},\"promptSuggestions\":true}}",
    );
    defer decoded.deinit();

    const line = try dispatchInitialize(allocator, decoded.request, false, rec.applier(), sampleResponseData());
    defer allocator.free(line);

    // The append-system-prompt was applied to the runtime.
    try testing.expect(rec.append_system_prompt != null);
    try testing.expectEqualStrings("be terse", rec.append_system_prompt.?);
    // The json schema + agents + prompt-suggestions were applied too.
    try testing.expect(rec.json_schema != null);
    try testing.expect(rec.agents_json != null);
    try testing.expect(rec.prompt_suggestions_set);
    try testing.expect(rec.prompt_suggestions);

    var p = try std.json.parseFromSlice(std.json.Value, allocator, std.mem.trimEnd(u8, line, "\n"), .{});
    defer p.deinit();
    const resp = p.value.object.get("response").?.object;
    try testing.expectEqualStrings("success", resp.get("subtype").?.string);
    try testing.expectEqualStrings("init-1", resp.get("request_id").?.string);

    const body = resp.get("response").?.object;
    // commands / agents / models arrays present.
    try testing.expectEqual(@as(usize, 2), body.get("commands").?.array.items.len);
    try testing.expectEqualStrings("help", body.get("commands").?.array.items[0].object.get("name").?.string);
    try testing.expectEqual(@as(usize, 2), body.get("agents").?.array.items.len);
    try testing.expectEqual(@as(usize, 1), body.get("models").?.array.items.len);
    try testing.expectEqualStrings("default", body.get("output_style").?.string);
    try testing.expectEqual(@as(usize, 2), body.get("available_output_styles").?.array.items.len);
    try testing.expectEqual(@as(i64, 4242), body.get("pid").?.integer);
    // The 'inherit' agent model is normalized to omitted.
    try testing.expect(body.get("agents").?.array.items[1].object.get("model") == null);
    // The non-inherit agent keeps its model.
    try testing.expectEqualStrings("mock-agent", body.get("agents").?.array.items[0].object.get("model").?.string);
}

test "dispatchInitialize: a second initialize returns an 'Already initialized' error" {
    const allocator = testing.allocator;
    var rec = InitRecorder{ .allocator = allocator };
    defer rec.deinit();

    var decoded = try decodeRequest(
        allocator,
        "{\"type\":\"control_request\",\"request_id\":\"init-2\",\"request\":{\"subtype\":\"initialize\"}}",
    );
    defer decoded.deinit();

    // already_initialized = true -> error response, no field application.
    const line = try dispatchInitialize(allocator, decoded.request, true, rec.applier(), sampleResponseData());
    defer allocator.free(line);

    var p = try std.json.parseFromSlice(std.json.Value, allocator, std.mem.trimEnd(u8, line, "\n"), .{});
    defer p.deinit();
    const resp = p.value.object.get("response").?.object;
    try testing.expectEqualStrings("error", resp.get("subtype").?.string);
    try testing.expectEqualStrings("init-2", resp.get("request_id").?.string);
    try testing.expectEqualStrings("Already initialized", resp.get("error").?.string);
    // Error responses carry the pending array for shape stability.
    try testing.expectEqual(@as(usize, 0), resp.get("pending_permission_requests").?.array.items.len);
    // No field application happened on the already-initialized path.
    try testing.expect(rec.append_system_prompt == null);
}

test "buildInitResponse: emits a stable shape and omits pid when zero" {
    const allocator = testing.allocator;
    // Minimal data: empty registries, pid 0 -> pid omitted.
    const body = try buildInitResponse(allocator, .{});
    defer allocator.free(body);

    var p = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer p.deinit();
    const obj = p.value.object;
    try testing.expectEqual(@as(usize, 0), obj.get("commands").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), obj.get("agents").?.array.items.len);
    try testing.expectEqualStrings("default", obj.get("output_style").?.string);
    try testing.expectEqual(@as(usize, 0), obj.get("available_output_styles").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), obj.get("models").?.array.items.len);
    try testing.expect(obj.get("account") != null);
    try testing.expect(obj.get("pid") == null);
}

test "dispatchInitialize: an unwired applier still succeeds (every field optional)" {
    const allocator = testing.allocator;
    // No callbacks wired: present fields are silently skipped, response is still
    // a success (matches the reference treating every initialize field optional).
    const empty: InitializeApplier = .{ .ctx = undefined };

    var decoded = try decodeRequest(
        allocator,
        "{\"type\":\"control_request\",\"request_id\":\"init-3\",\"request\":{\"subtype\":\"initialize\",\"appendSystemPrompt\":\"x\"}}",
    );
    defer decoded.deinit();

    const line = try dispatchInitialize(allocator, decoded.request, false, empty, .{});
    defer allocator.free(line);

    var p = try std.json.parseFromSlice(std.json.Value, allocator, std.mem.trimEnd(u8, line, "\n"), .{});
    defer p.deinit();
    try testing.expectEqualStrings("success", p.value.object.get("response").?.object.get("subtype").?.string);
}

// --- sdk-headless-11 hook_callback / elicitation relay tests ----------------

// A stub RelayChannel that records the last inner-request JSON it saw and
// returns a pre-canned raw response body, so the relays can be exercised
// without a real host or stdin stream. `fail` makes the channel error
// (transport / host-error analogue) so fail-safe paths are testable.
const StubChannel = struct {
    allocator: std.mem.Allocator,
    response_body: []const u8 = "{}",
    fail: bool = false,
    last_request: []u8 = "",

    fn deinit(self: *StubChannel) void {
        if (self.last_request.len > 0) self.allocator.free(self.last_request);
    }

    fn requestFn(ctx: *anyopaque, allocator: std.mem.Allocator, request_json: []const u8) anyerror![]u8 {
        const self: *StubChannel = @ptrCast(@alignCast(ctx));
        if (self.last_request.len > 0) self.allocator.free(self.last_request);
        self.last_request = try self.allocator.dupe(u8, request_json);
        if (self.fail) return error.RelayUnavailable;
        return allocator.dupe(u8, self.response_body);
    }

    fn channel(self: *StubChannel) RelayChannel {
        return .{ .ctx = @ptrCast(self), .requestFn = requestFn };
    }
};

test "buildHookCallbackRequest carries callback_id, input, tool_use_id as parseable JSON" {
    const allocator = testing.allocator;
    const req = try buildHookCallbackRequest(
        allocator,
        "cb-7",
        "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\"}",
        "toolu_42",
    );
    defer allocator.free(req);

    var p = try std.json.parseFromSlice(std.json.Value, allocator, req, .{});
    defer p.deinit();
    const obj = p.value.object;
    try testing.expectEqualStrings("hook_callback", obj.get("subtype").?.string);
    try testing.expectEqualStrings("cb-7", obj.get("callback_id").?.string);
    try testing.expectEqualStrings("toolu_42", obj.get("tool_use_id").?.string);
    // The input survives verbatim as a nested object.
    try testing.expectEqualStrings("Bash", obj.get("input").?.object.get("tool_name").?.string);
}

test "buildHookCallbackRequest defaults empty input to {} and omits an empty tool_use_id" {
    const allocator = testing.allocator;
    const req = try buildHookCallbackRequest(allocator, "cb-1", "", "");
    defer allocator.free(req);

    var p = try std.json.parseFromSlice(std.json.Value, allocator, req, .{});
    defer p.deinit();
    const obj = p.value.object;
    try testing.expectEqual(@as(usize, 0), obj.get("input").?.object.count());
    try testing.expect(obj.get("tool_use_id") == null);
}

test "relayHookCallback: a registered SDK hook emits a hook_callback request and resolves from the host response" {
    const allocator = testing.allocator;
    // Host answers with a HookJSONOutput analogue: a block decision.
    var stub = StubChannel{
        .allocator = allocator,
        .response_body = "{\"decision\":\"block\",\"reason\":\"policy\"}",
    };
    defer stub.deinit();

    const decision = try relayHookCallback(
        allocator,
        stub.channel(),
        "cb-9",
        "{\"hook_event_name\":\"PreToolUse\"}",
        "toolu_1",
    );
    defer allocator.free(decision);

    // The CLI emitted a hook_callback request naming the callback.
    try testing.expect(std.mem.indexOf(u8, stub.last_request, "\"subtype\":\"hook_callback\"") != null);
    try testing.expect(std.mem.indexOf(u8, stub.last_request, "\"callback_id\":\"cb-9\"") != null);

    // The host's response body is returned verbatim for the hook machinery.
    var p = try std.json.parseFromSlice(std.json.Value, allocator, decision, .{});
    defer p.deinit();
    try testing.expectEqualStrings("block", p.value.object.get("decision").?.string);
    try testing.expectEqualStrings("policy", p.value.object.get("reason").?.string);
}

test "relayHookCallback: a channel failure propagates so the caller can fail safe" {
    const allocator = testing.allocator;
    var stub = StubChannel{ .allocator = allocator, .fail = true };
    defer stub.deinit();

    try testing.expectError(error.RelayUnavailable, relayHookCallback(
        allocator,
        stub.channel(),
        "cb-2",
        "{}",
        "",
    ));
    // The request was still emitted before the channel reported failure.
    try testing.expect(std.mem.indexOf(u8, stub.last_request, "\"subtype\":\"hook_callback\"") != null);
}

test "buildElicitationRequest carries the reference fields and omits url when empty" {
    const allocator = testing.allocator;
    const req = try buildElicitationRequest(
        allocator,
        "weather-server",
        "Need your city",
        "form",
        "",
        "elic-3",
        "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}}}",
    );
    defer allocator.free(req);

    var p = try std.json.parseFromSlice(std.json.Value, allocator, req, .{});
    defer p.deinit();
    const obj = p.value.object;
    try testing.expectEqualStrings("elicitation", obj.get("subtype").?.string);
    try testing.expectEqualStrings("weather-server", obj.get("mcp_server_name").?.string);
    try testing.expectEqualStrings("Need your city", obj.get("message").?.string);
    try testing.expectEqualStrings("form", obj.get("mode").?.string);
    try testing.expectEqualStrings("elic-3", obj.get("elicitation_id").?.string);
    try testing.expect(obj.get("url") == null);
    try testing.expectEqualStrings("object", obj.get("requested_schema").?.object.get("type").?.string);
}

test "relayElicitation: a host-driven elicitation emits a request and maps an accept response to the in-process action shape" {
    const allocator = testing.allocator;
    // Host accepts and returns form content.
    var stub = StubChannel{
        .allocator = allocator,
        .response_body = "{\"action\":\"accept\",\"content\":{\"city\":\"Paris\"}}",
    };
    defer stub.deinit();

    const result = try relayElicitation(
        allocator,
        stub.channel(),
        "weather-server",
        "Need your city",
        "form",
        "",
        "elic-4",
        "{\"type\":\"object\"}",
    );
    defer allocator.free(result);

    // The CLI emitted an elicitation request naming the server.
    try testing.expect(std.mem.indexOf(u8, stub.last_request, "\"subtype\":\"elicitation\"") != null);
    try testing.expect(std.mem.indexOf(u8, stub.last_request, "\"mcp_server_name\":\"weather-server\"") != null);

    // The mapped result matches what the in-process path produces:
    // {"action":"accept","content":{...}}.
    var p = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer p.deinit();
    try testing.expectEqualStrings("accept", p.value.object.get("action").?.string);
    try testing.expectEqualStrings("Paris", p.value.object.get("content").?.object.get("city").?.string);
}

test "relayElicitation: a decline response drops content; an unknown action maps to cancel" {
    const allocator = testing.allocator;
    {
        var stub = StubChannel{
            .allocator = allocator,
            // A decline that (wrongly) carries content: content is dropped.
            .response_body = "{\"action\":\"decline\",\"content\":{\"city\":\"Paris\"}}",
        };
        defer stub.deinit();
        const result = try relayElicitation(allocator, stub.channel(), "s", "m", "form", "", "e1", "{}");
        defer allocator.free(result);
        var p = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
        defer p.deinit();
        try testing.expectEqualStrings("decline", p.value.object.get("action").?.string);
        try testing.expect(p.value.object.get("content") == null);
    }
    {
        // An unrecognized action (or a missing one) maps to cancel.
        var stub = StubChannel{ .allocator = allocator, .response_body = "{\"action\":\"teleport\"}" };
        defer stub.deinit();
        const result = try relayElicitation(allocator, stub.channel(), "s", "m", "form", "", "e2", "{}");
        defer allocator.free(result);
        var p = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
        defer p.deinit();
        try testing.expectEqualStrings("cancel", p.value.object.get("action").?.string);
    }
}

test "elicitationActionFromResponse: an empty / unparseable body fails safe to cancel" {
    const allocator = testing.allocator;
    const a = try elicitationActionFromResponse(allocator, "");
    defer allocator.free(a);
    try testing.expectEqualStrings("{\"action\":\"cancel\"}", a);
}
