//! sdk-headless-02: `--output-format text|json|stream-json` selector and the
//! NDJSON serializers behind it.
//!
//! Three formats, matching Claude Code's `--output-format`:
//!   - text        : the existing human-readable rendering (the caller routes
//!                    to the `run` path; this module does not serialize text).
//!   - json        : a single SDK `result` message (one JSON object).
//!   - stream-json : realtime NDJSON of every SDK message - `system:init`
//!                    first, then the final `result` - each on its own line.
//!                    Requires `--verbose`, matching the reference.
//!
//! Reference behavior + file:line:
//!   main.tsx:976   Option('--output-format <format>').choices(['text','json','stream-json'])
//!   cli/print.ts:917  switch(options.outputFormat)
//!   cli/print.ts:787  requires --verbose for stream-json
//!
//! Design choice: the SDK `result`/`system:init` *shapes* live here (rather
//! than borrowing a not-yet-built sdk/messages.zig) so this module is
//! self-contained and unit-testable against a hand-built result struct. When
//! the dedicated message module lands (sdk-headless-07), these serializers can
//! delegate to it; the wire shape is the contract and is pinned by tests here.
//!
//! NDJSON safety: `std.json.fmt` escapes per the JSON spec but emits raw
//! U+2028 / U+2029 (legal JSON, but they break some NDJSON line readers). We
//! run every rendered line through `parse_helpers.appendNdjsonSafe`, which
//! rewrites those two code points to ` ` / ` `. The blessed JSON
//! path therefore always produces NDJSON that a strict line parser accepts.

const std = @import("std");
const std_io = @import("../core/std_io.zig");
const parse_helpers = @import("../core/parse_helpers.zig");

/// The three `--output-format` choices. `stream_json` is spelled with an
/// underscore in Zig but parses from / renders to the hyphenated wire token
/// `stream-json`.
pub const OutputFormat = enum {
    text,
    json,
    stream_json,

    /// Render back to the wire token (hyphenated for stream-json).
    pub fn toString(self: OutputFormat) []const u8 {
        return switch (self) {
            .text => "text",
            .json => "json",
            .stream_json => "stream-json",
        };
    }

    /// Parse a raw `--output-format` value. Accepts `text`, `json`,
    /// `stream-json`. Returns error.UnknownOutputFormat for anything else,
    /// after printing a usage line in the style of args.zig's other format
    /// flags so the caller can fail fast.
    pub fn parse(value: []const u8) error{UnknownOutputFormat}!OutputFormat {
        if (std.mem.eql(u8, value, "text")) return .text;
        if (std.mem.eql(u8, value, "json")) return .json;
        if (std.mem.eql(u8, value, "stream-json")) return .stream_json;
        std_io.stderrWriter().print(
            "error: --output-format: unknown format '{s}'. Valid formats: text, json, stream-json.\n",
            .{value},
        ) catch {};
        return error.UnknownOutputFormat;
    }
};

/// stream-json requires `--verbose`, matching the reference (print.ts:787).
/// Returns error.StreamJsonRequiresVerbose (after a usage line) when the
/// selected format is stream-json but verbose is not set. text/json never
/// require verbose.
pub fn validateVerboseGate(format: OutputFormat, verbose: bool) error{StreamJsonRequiresVerbose}!void {
    if (format == .stream_json and !verbose) {
        std_io.stderrWriter().print(
            "error: --output-format stream-json requires --verbose.\n",
            .{},
        ) catch {};
        return error.StreamJsonRequiresVerbose;
    }
}

/// The result subtypes the SDK `result` message can carry. `success` is the
/// happy path; the `error_*` variants map to the headless limit flags
/// (sdk-headless-14). `subtype` strings match coreSchemas.ts.
pub const ResultSubtype = enum {
    success,
    error_during_execution,
    error_max_turns,
    error_max_budget_usd,
    error_max_structured_output_retries,

    pub fn toString(self: ResultSubtype) []const u8 {
        return switch (self) {
            .success => "success",
            .error_during_execution => "error_during_execution",
            .error_max_turns => "error_max_turns",
            .error_max_budget_usd => "error_max_budget_usd",
            .error_max_structured_output_retries => "error_max_structured_output_retries",
        };
    }

    pub fn isError(self: ResultSubtype) bool {
        return self != .success;
    }
};

/// Token usage carried in the `result.usage` object.
pub const Usage = struct {
    input_tokens: usize = 0,
    output_tokens: usize = 0,
};

/// The data behind an SDK `result` message. Hand-buildable for tests; the
/// dispatcher fills it from a `TurnResult` + runtime cost/usage/session data.
///
/// `total_cost_usd` is an *estimate* (from core/cost.zig:estimateCost), not a
/// billed figure. `duration_api_ms` may equal `duration_ms` when per-API-call
/// timing is not separately tracked - documented as an approximation rather
/// than fabricated.
pub const Result = struct {
    subtype: ResultSubtype = .success,
    session_id: []const u8 = "",
    /// The assistant's final text. Maps to the `result` field on success.
    result_text: []const u8 = "",
    /// Tool-call rounds. Maps to `num_turns`.
    num_turns: usize = 0,
    total_cost_usd: f64 = 0,
    usage: Usage = .{},
    /// The active model, used as the single `modelUsage` key.
    model: []const u8 = "",
    duration_ms: i64 = 0,
    duration_api_ms: i64 = 0,
    /// Why the turn stopped (e.g. "end_turn", "max_turns"). Empty -> omitted.
    stop_reason: []const u8 = "",
    /// Structured-output payload as raw JSON (from --json-schema), or empty.
    structured_output_json: []const u8 = "",
};

/// One entry in `result.permission_denials`. Mirrors SDKPermissionDenialSchema.
pub const PermissionDenial = struct {
    tool_name: []const u8,
    tool_use_id: []const u8 = "",
    /// Raw JSON of the denied tool input, or empty.
    tool_input_json: []const u8 = "",
};

/// Serialize an SDK `result` message to a single newline-terminated NDJSON
/// line. Caller owns the returned slice. `denials` may be empty.
pub fn serializeResult(
    allocator: std.mem.Allocator,
    result: Result,
    denials: []const PermissionDenial,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"type\":\"result\",\"subtype\":");
    try writeJsonString(w, result.subtype.toString());
    try w.print(",\"is_error\":{}", .{result.subtype.isError()});
    try w.print(",\"num_turns\":{d}", .{result.num_turns});
    try w.print(",\"total_cost_usd\":{d}", .{result.total_cost_usd});
    try w.print(",\"duration_ms\":{d}", .{result.duration_ms});
    try w.print(",\"duration_api_ms\":{d}", .{result.duration_api_ms});

    try w.writeAll(",\"usage\":");
    try w.print("{f}", .{std.json.fmt(.{
        .input_tokens = result.usage.input_tokens,
        .output_tokens = result.usage.output_tokens,
    }, .{})});

    // Single-entry modelUsage keyed by the active model. When the model is
    // unknown we still emit an empty object so the key is always present.
    try w.writeAll(",\"modelUsage\":{");
    if (result.model.len > 0) {
        try writeJsonString(w, result.model);
        try w.writeAll(":");
        try w.print("{f}", .{std.json.fmt(.{
            .input_tokens = result.usage.input_tokens,
            .output_tokens = result.usage.output_tokens,
        }, .{})});
    }
    try w.writeAll("}");

    // permission_denials is always an array (often empty).
    try w.writeAll(",\"permission_denials\":[");
    for (denials, 0..) |d, idx| {
        if (idx != 0) try w.writeAll(",");
        try w.writeAll("{\"tool_name\":");
        try writeJsonString(w, d.tool_name);
        if (d.tool_use_id.len > 0) {
            try w.writeAll(",\"tool_use_id\":");
            try writeJsonString(w, d.tool_use_id);
        }
        if (d.tool_input_json.len > 0) {
            try w.writeAll(",\"tool_use_input\":");
            try w.writeAll(d.tool_input_json);
        }
        try w.writeAll("}");
    }
    try w.writeAll("]");

    if (result.stop_reason.len > 0) {
        try w.writeAll(",\"stop_reason\":");
        try writeJsonString(w, result.stop_reason);
    }

    if (result.structured_output_json.len > 0) {
        try w.writeAll(",\"structured_output\":");
        try w.writeAll(result.structured_output_json);
    }

    // On success carry the assistant text under `result`; on error carry it
    // under `error` (matching SDKResultErrorSchema's free-text field).
    if (result.subtype.isError()) {
        try w.writeAll(",\"error\":");
        try writeJsonString(w, result.result_text);
    } else {
        try w.writeAll(",\"result\":");
        try writeJsonString(w, result.result_text);
    }

    if (result.session_id.len > 0) {
        try w.writeAll(",\"session_id\":");
        try writeJsonString(w, result.session_id);
    }
    try w.writeAll("}");

    try out.append('\n');
    return finalizeNdjson(allocator, out.items());
}

/// The data behind a `system:init` message emitted at session start.
pub const InitInfo = struct {
    session_id: []const u8 = "",
    model: []const u8 = "",
    permission_mode: []const u8 = "",
    cwd: []const u8 = "",
    claude_code_version: []const u8 = "",
    /// Available tool names.
    tools: []const []const u8 = &.{},
    /// Connected MCP server names.
    mcp_servers: []const []const u8 = &.{},
    /// Available slash-command names.
    slash_commands: []const []const u8 = &.{},
    skills: []const []const u8 = &.{},
    plugins: []const []const u8 = &.{},
};

/// Serialize a `system:init` message to a single newline-terminated NDJSON
/// line. Caller owns the returned slice.
pub fn serializeInit(allocator: std.mem.Allocator, info: InitInfo) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"type\":\"system\",\"subtype\":\"init\"");
    try w.writeAll(",\"model\":");
    try writeJsonString(w, info.model);
    try w.writeAll(",\"permissionMode\":");
    try writeJsonString(w, info.permission_mode);
    try w.writeAll(",\"cwd\":");
    try writeJsonString(w, info.cwd);
    try w.writeAll(",\"claude_code_version\":");
    try writeJsonString(w, info.claude_code_version);

    try writeStringArray(w, "tools", info.tools);
    try writeStringArray(w, "mcp_servers", info.mcp_servers);
    try writeStringArray(w, "slash_commands", info.slash_commands);
    try writeStringArray(w, "skills", info.skills);
    try writeStringArray(w, "plugins", info.plugins);

    if (info.session_id.len > 0) {
        try w.writeAll(",\"session_id\":");
        try writeJsonString(w, info.session_id);
    }
    try w.writeAll("}");

    try out.append('\n');
    return finalizeNdjson(allocator, out.items());
}

/// Serialize an SDK `assistant` message to a single newline-terminated
/// NDJSON line. Matches the reference's assistant event shape:
/// {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"..."}]},
///  "parent_tool_use_id":null,"request_id":"...","session_id":"...","uuid":"..."}
pub fn serializeAssistant(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    text: []const u8,
    request_id: []const u8,
    uuid: []const u8,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"type\":\"assistant\",\"message\":");
    try w.writeAll("{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":");
    try writeJsonString(w, text);
    try w.writeAll("}]}");
    try w.writeAll(",\"parent_tool_use_id\":null");
    try w.writeAll(",\"request_id\":");
    try writeJsonString(w, request_id);
    try w.writeAll(",\"session_id\":");
    try writeJsonString(w, session_id);
    try w.writeAll(",\"uuid\":");
    try writeJsonString(w, uuid);
    try w.writeAll("}");

    try out.append('\n');
    return finalizeNdjson(allocator, out.items());
}

/// stream-json: emit the `system:init` line first, then the final `result`
/// line, writing both through `writer`. (Intermediate assistant/tool messages
/// are emitted by the live dispatcher as they happen; this helper is the
/// envelope-bracketing path used when there is nothing live in between, and
/// the one the unit tests exercise.) `writer` is a `*std.Io.Writer`.
pub fn streamInitAndResult(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    info: InitInfo,
    result: Result,
    denials: []const PermissionDenial,
) !void {
    const init_line = try serializeInit(allocator, info);
    defer allocator.free(init_line);
    try writer.writeAll(init_line);

    const result_line = try serializeResult(allocator, result, denials);
    defer allocator.free(result_line);
    try writer.writeAll(result_line);
}

// ---------------------------------------------------------------------------
// sdk-headless-12: partial messages / include-partial / include-hook-events /
// replay-user-messages.
//
// Three optional stream-json message kinds, each flag-gated and only emitted
// under `--output-format stream-json`:
//   - stream_event  : a partial assistant message (token delta) emitted per
//                     streaming chunk when `--include-partial-messages` is set.
//   - system (hook) : a hook-lifecycle system event emitted when a hook fires
//                     and `--include-hook-events` is set.
//   - user (replay) : an accepted SDKUserMessage re-emitted on stdout for ack
//                     when `--replay-user-messages` is set.
//
// Reference behavior + file:line:
//   coreSchemas.ts:1496  SDKPartialAssistantMessageSchema (stream_event)
//   main.tsx:976/988     the three --include-* / --replay-* options
//   cli/print.ts:628     registerHookEventHandler (stream-json + verbose)
//
// Granularity note (per the Task N risk): zcode's streaming adapter may expose
// coarse deltas rather than per-token chunks. `serializeStreamEvent` takes the
// delta text the caller already has and wraps it; it does not synthesize a
// finer granularity than the adapter provides.
// ---------------------------------------------------------------------------

/// One `stream_event` partial-assistant-message line. `delta_text` is the
/// token/chunk text the streaming adapter produced; `parent_tool_use_id` is
/// empty when the chunk is top-level. `uuid` identifies the chunk; pass an
/// empty string to omit it. Caller owns the returned newline-terminated slice.
pub fn serializeStreamEvent(
    allocator: std.mem.Allocator,
    delta_text: []const u8,
    parent_tool_use_id: []const u8,
    uuid: []const u8,
    session_id: []const u8,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    // The `event` carries a content_block_delta with a text_delta, matching the
    // Anthropic streaming event shape the reference forwards verbatim.
    try w.writeAll("{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":");
    try writeJsonString(w, delta_text);
    try w.writeAll("}}");

    // parent_tool_use_id is always present (null when top-level) to match the
    // reference schema; uuid/session_id are omitted when empty.
    try w.writeAll(",\"parent_tool_use_id\":");
    if (parent_tool_use_id.len > 0) {
        try writeJsonString(w, parent_tool_use_id);
    } else {
        try w.writeAll("null");
    }
    if (uuid.len > 0) {
        try w.writeAll(",\"uuid\":");
        try writeJsonString(w, uuid);
    }
    if (session_id.len > 0) {
        try w.writeAll(",\"session_id\":");
        try writeJsonString(w, session_id);
    }
    try w.writeAll("}");

    try out.append('\n');
    return finalizeNdjson(allocator, out.items());
}

/// One hook-lifecycle `system` event line (subtype = the hook event name, e.g.
/// "PreToolUse"). `tool_name` and `tool_use_id` are optional context; pass
/// empty strings to omit them. Caller owns the returned newline-terminated
/// slice.
pub fn serializeHookEventSystem(
    allocator: std.mem.Allocator,
    hook_event_name: []const u8,
    tool_name: []const u8,
    tool_use_id: []const u8,
    session_id: []const u8,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"type\":\"system\",\"subtype\":\"hook_event\",\"hook_event_name\":");
    try writeJsonString(w, hook_event_name);
    if (tool_name.len > 0) {
        try w.writeAll(",\"tool_name\":");
        try writeJsonString(w, tool_name);
    }
    if (tool_use_id.len > 0) {
        try w.writeAll(",\"tool_use_id\":");
        try writeJsonString(w, tool_use_id);
    }
    if (session_id.len > 0) {
        try w.writeAll(",\"session_id\":");
        try writeJsonString(w, session_id);
    }
    try w.writeAll("}");

    try out.append('\n');
    return finalizeNdjson(allocator, out.items());
}

/// Re-emit an accepted user message as a `user` NDJSON line (for ack). `text`
/// is the prompt text the dispatcher accepted; it is wrapped in the canonical
/// `{type:"user", message:{role:"user", content:<text>}}` shape. Caller owns
/// the returned newline-terminated slice.
pub fn serializeUserReplay(
    allocator: std.mem.Allocator,
    text: []const u8,
    session_id: []const u8,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":");
    try writeJsonString(w, text);
    try w.writeAll("}");
    if (session_id.len > 0) {
        try w.writeAll(",\"session_id\":");
        try writeJsonString(w, session_id);
    }
    try w.writeAll("}");

    try out.append('\n');
    return finalizeNdjson(allocator, out.items());
}

/// Run a rendered JSON line (already valid JSON + a trailing newline) through
/// the NDJSON-safe pass so U+2028 / U+2029 cannot break a strict line reader,
/// then hand ownership to the caller. `line` is borrowed (the caller's
/// StringBuilder owns it until this returns a fresh slice).
fn finalizeNdjson(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    var safe = std_io.StringBuilder.init(allocator);
    defer safe.deinit();
    try parse_helpers.appendNdjsonSafe(&safe, line);
    return safe.toOwnedSlice();
}

/// Write `,"key":[ "a", "b" ]` for a string array. Always emits the key (an
/// empty array when there are no entries) so the init shape is stable.
fn writeStringArray(w: *std.Io.Writer, key: []const u8, items: []const []const u8) !void {
    try w.writeAll(",");
    try writeJsonString(w, key);
    try w.writeAll(":[");
    for (items, 0..) |item, idx| {
        if (idx != 0) try w.writeAll(",");
        try writeJsonString(w, item);
    }
    try w.writeAll("]");
}

/// Minimal JSON string escaper (quotes, backslash, C0 controls). Mirrors the
/// escaper in core/sdk_message.zig so this module has no cross-dependency on
/// it. U+2028 / U+2029 are handled by the finalizeNdjson pass, not here.
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

const testing = std.testing;

test "OutputFormat parses the three choices and rejects unknown" {
    try testing.expectEqual(OutputFormat.text, try OutputFormat.parse("text"));
    try testing.expectEqual(OutputFormat.json, try OutputFormat.parse("json"));
    try testing.expectEqual(OutputFormat.stream_json, try OutputFormat.parse("stream-json"));
    try testing.expectError(error.UnknownOutputFormat, OutputFormat.parse("yaml"));
    try testing.expectError(error.UnknownOutputFormat, OutputFormat.parse(""));
    // The wire token round-trips (hyphenated for stream-json).
    try testing.expectEqualStrings("stream-json", OutputFormat.stream_json.toString());
}

test "validateVerboseGate: stream-json without --verbose is a usage error" {
    try testing.expectError(
        error.StreamJsonRequiresVerbose,
        validateVerboseGate(.stream_json, false),
    );
    // text / json never require verbose; stream-json with verbose is fine.
    try validateVerboseGate(.text, false);
    try validateVerboseGate(.json, false);
    try validateVerboseGate(.stream_json, true);
}

test "serializeResult: json result has type, subtype=success, num_turns" {
    const allocator = testing.allocator;
    const result = Result{
        .subtype = .success,
        .session_id = "sess-abc",
        .result_text = "all done",
        .num_turns = 3,
        .total_cost_usd = 0.0123,
        .usage = .{ .input_tokens = 120, .output_tokens = 45 },
        .model = "mock-agent",
        .duration_ms = 250,
        .duration_api_ms = 200,
        .stop_reason = "end_turn",
    };
    const line = try serializeResult(allocator, result, &.{});
    defer allocator.free(line);

    // NDJSON line is newline-terminated.
    try testing.expect(line.len > 0 and line[line.len - 1] == '\n');

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try testing.expectEqualStrings("result", obj.get("type").?.string);
    try testing.expectEqualStrings("success", obj.get("subtype").?.string);
    try testing.expect(obj.get("num_turns") != null);
    try testing.expectEqual(@as(i64, 3), obj.get("num_turns").?.integer);
    try testing.expect(obj.get("total_cost_usd") != null);
    try testing.expect(obj.get("usage").?.object.get("input_tokens") != null);
    try testing.expect(obj.get("usage").?.object.get("output_tokens") != null);
    try testing.expect(obj.get("permission_denials") != null);
    try testing.expect(obj.get("permission_denials").? == .array);
    try testing.expectEqualStrings("sess-abc", obj.get("session_id").?.string);
    try testing.expectEqual(false, obj.get("is_error").?.bool);
    try testing.expectEqualStrings("all done", obj.get("result").?.string);
}

test "serializeResult: error subtype sets is_error and carries error text" {
    const allocator = testing.allocator;
    const result = Result{
        .subtype = .error_max_turns,
        .result_text = "turn budget exhausted",
        .num_turns = 1,
    };
    const line = try serializeResult(allocator, result, &.{});
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("error_max_turns", obj.get("subtype").?.string);
    try testing.expectEqual(true, obj.get("is_error").?.bool);
    try testing.expectEqualStrings("turn budget exhausted", obj.get("error").?.string);
    try testing.expect(obj.get("result") == null);
}

test "serializeResult: permission_denials array carries entries" {
    const allocator = testing.allocator;
    const denials = [_]PermissionDenial{
        .{ .tool_name = "Bash", .tool_use_id = "tu-1", .tool_input_json = "{\"command\":\"rm -rf /\"}" },
    };
    const line = try serializeResult(allocator, .{ .subtype = .success }, &denials);
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const arr = parsed.value.object.get("permission_denials").?.array;
    try testing.expectEqual(@as(usize, 1), arr.items.len);
    try testing.expectEqualStrings("Bash", arr.items[0].object.get("tool_name").?.string);
    try testing.expectEqualStrings("tu-1", arr.items[0].object.get("tool_use_id").?.string);
}

test "serializeInit: system init carries tools, model, cwd, version" {
    const allocator = testing.allocator;
    const tools = [_][]const u8{ "Read", "Write", "Bash" };
    const info = InitInfo{
        .session_id = "sess-xyz",
        .model = "mock-agent",
        .permission_mode = "default",
        .cwd = "/tmp/work",
        .claude_code_version = "0.11.73+abc",
        .tools = &tools,
    };
    const line = try serializeInit(allocator, info);
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("system", obj.get("type").?.string);
    try testing.expectEqualStrings("init", obj.get("subtype").?.string);
    try testing.expect(obj.get("tools") != null);
    try testing.expectEqual(@as(usize, 3), obj.get("tools").?.array.items.len);
    try testing.expectEqualStrings("mock-agent", obj.get("model").?.string);
    try testing.expectEqualStrings("/tmp/work", obj.get("cwd").?.string);
    try testing.expectEqualStrings("0.11.73+abc", obj.get("claude_code_version").?.string);
}

test "streamInitAndResult: system:init line first, result line last, each parseable" {
    const allocator = testing.allocator;
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();

    const info = InitInfo{ .model = "mock-agent", .cwd = "/tmp", .claude_code_version = "v" };
    const result = Result{ .subtype = .success, .num_turns = 2, .result_text = "hi", .model = "mock-agent" };
    try streamInitAndResult(allocator, buf.writer(), info, result, &.{});

    // Split into NDJSON lines (trailing newline yields a final empty token).
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, buf.items(), '\n');
    while (it.next()) |raw| {
        if (raw.len == 0) continue;
        try lines.append(allocator, raw);
    }
    try testing.expectEqual(@as(usize, 2), lines.items.len);

    // First line is system:init.
    var first = try std.json.parseFromSlice(std.json.Value, allocator, lines.items[0], .{});
    defer first.deinit();
    try testing.expectEqualStrings("system", first.value.object.get("type").?.string);
    try testing.expectEqualStrings("init", first.value.object.get("subtype").?.string);

    // Last line is the result.
    var last = try std.json.parseFromSlice(std.json.Value, allocator, lines.items[1], .{});
    defer last.deinit();
    try testing.expectEqualStrings("result", last.value.object.get("type").?.string);
    try testing.expectEqualStrings("success", last.value.object.get("subtype").?.string);
    try testing.expectEqual(@as(i64, 2), last.value.object.get("num_turns").?.integer);
}

test "serializeResult: U+2028 in text is escaped so the line stays NDJSON-safe" {
    const allocator = testing.allocator;
    // result_text contains a raw U+2028 line separator (E2 80 A8).
    const result = Result{ .subtype = .success, .result_text = "a\u{2028}b" };
    const line = try serializeResult(allocator, result, &.{});
    defer allocator.free(line);

    // The raw 3-byte sequence must not survive (it is rewritten to  ).
    try testing.expect(std.mem.indexOf(u8, line, "\u{2028}") == null);
    try testing.expect(std.mem.indexOf(u8, line, "\\u2028") != null);

    // And the line still parses as JSON.
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("result", parsed.value.object.get("type").?.string);
}

// ── sdk-headless-12: stream_event / hook system / user replay serializers ──

test "serializeStreamEvent: emits a stream_event with a text_delta" {
    const allocator = testing.allocator;
    const line = try serializeStreamEvent(allocator, "hel", "", "u-1", "sess-1");
    defer allocator.free(line);

    try testing.expect(line.len > 0 and line[line.len - 1] == '\n');

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("stream_event", obj.get("type").?.string);
    const event = obj.get("event").?.object;
    try testing.expectEqualStrings("content_block_delta", event.get("type").?.string);
    const delta = event.get("delta").?.object;
    try testing.expectEqualStrings("text_delta", delta.get("type").?.string);
    try testing.expectEqualStrings("hel", delta.get("text").?.string);
    // top-level chunk -> parent_tool_use_id is JSON null
    try testing.expect(obj.get("parent_tool_use_id").? == .null);
    try testing.expectEqualStrings("u-1", obj.get("uuid").?.string);
    try testing.expectEqualStrings("sess-1", obj.get("session_id").?.string);
}

test "serializeStreamEvent: nested chunk carries parent_tool_use_id" {
    const allocator = testing.allocator;
    const line = try serializeStreamEvent(allocator, "x", "tu-9", "", "");
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("tu-9", obj.get("parent_tool_use_id").?.string);
    // uuid / session_id omitted when empty
    try testing.expect(obj.get("uuid") == null);
    try testing.expect(obj.get("session_id") == null);
}

test "serializeHookEventSystem: emits a hook_event system message" {
    const allocator = testing.allocator;
    const line = try serializeHookEventSystem(allocator, "PreToolUse", "Bash", "tu-2", "sess-2");
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("system", obj.get("type").?.string);
    try testing.expectEqualStrings("hook_event", obj.get("subtype").?.string);
    try testing.expectEqualStrings("PreToolUse", obj.get("hook_event_name").?.string);
    try testing.expectEqualStrings("Bash", obj.get("tool_name").?.string);
    try testing.expectEqualStrings("tu-2", obj.get("tool_use_id").?.string);
    try testing.expectEqualStrings("sess-2", obj.get("session_id").?.string);
}

test "serializeHookEventSystem: omits optional context when empty" {
    const allocator = testing.allocator;
    const line = try serializeHookEventSystem(allocator, "Stop", "", "", "");
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("Stop", obj.get("hook_event_name").?.string);
    try testing.expect(obj.get("tool_name") == null);
    try testing.expect(obj.get("tool_use_id") == null);
    try testing.expect(obj.get("session_id") == null);
}

test "serializeUserReplay: re-emits a user message in the canonical shape" {
    const allocator = testing.allocator;
    const line = try serializeUserReplay(allocator, "do the thing", "sess-3");
    defer allocator.free(line);

    try testing.expect(line.len > 0 and line[line.len - 1] == '\n');

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("user", obj.get("type").?.string);
    const message = obj.get("message").?.object;
    try testing.expectEqualStrings("user", message.get("role").?.string);
    try testing.expectEqualStrings("do the thing", message.get("content").?.string);
    try testing.expectEqualStrings("sess-3", obj.get("session_id").?.string);
}
