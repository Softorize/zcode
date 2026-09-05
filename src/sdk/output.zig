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

/// headless-sdk-14: `--forward-subagent-text` is only meaningful with
/// `--print` and `--output-format=stream-json` -- without stream-json there
/// is no NDJSON channel to carry the extra `assistant`/`user` lines on, and
/// without `--print` there is no headless turn to forward from at all.
/// Message text matches the reference's own validation error verbatim
/// (cc_strings.txt: "Error: --forward-subagent-text requires --print and
/// --output-format=stream-json.").
pub fn validateForwardSubagentTextGate(print: bool, format: OutputFormat, forward_subagent_text: bool) error{ForwardSubagentTextRequiresStreamJson}!void {
    if (forward_subagent_text and !(print and format == .stream_json)) {
        std_io.stderrWriter().print(
            "Error: --forward-subagent-text requires --print and --output-format=stream-json.\n",
            .{},
        ) catch {};
        return error.ForwardSubagentTextRequiresStreamJson;
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

/// Token usage carried in the `result.usage` / `result.modelUsage.<model>`
/// object. `cache_creation_input_tokens` / `cache_read_input_tokens` default to
/// 0 when zcode has not separately tracked prompt-cache accounting for the
/// active provider (headless-sdk-09) -- 0 is the reference's own default value
/// for a session that used no caching, not a fabricated number.
pub const Usage = struct {
    input_tokens: usize = 0,
    output_tokens: usize = 0,
    cache_creation_input_tokens: usize = 0,
    cache_read_input_tokens: usize = 0,
};

/// Write the full reference usage-object shape (headless-sdk-09): the two
/// dynamic token counts plus the reference's zero-valued shape-stability
/// fields (`of` in cc_strings.txt) so a strict SDK consumer parsing
/// `result.usage` / `result.modelUsage.<model>` never hits a missing key.
fn writeUsageObject(w: *std.Io.Writer, usage: Usage) !void {
    try w.print("{{\"input_tokens\":{d},\"output_tokens\":{d}", .{ usage.input_tokens, usage.output_tokens });
    try w.print(",\"cache_creation_input_tokens\":{d},\"cache_read_input_tokens\":{d}", .{
        usage.cache_creation_input_tokens,
        usage.cache_read_input_tokens,
    });
    try w.writeAll(",\"output_tokens_details\":{\"thinking_tokens\":0}");
    try w.writeAll(",\"server_tool_use\":{\"web_search_requests\":0,\"web_fetch_requests\":0}");
    try w.writeAll(",\"service_tier\":\"standard\"");
    try w.writeAll(",\"cache_creation\":{\"ephemeral_1h_input_tokens\":0,\"ephemeral_5m_input_tokens\":0}");
    try w.writeAll(",\"inference_geo\":\"\",\"iterations\":[],\"speed\":\"standard\"}");
}

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
    /// A fresh UUIDv4 minted per result line (headless-sdk-05). Every reference
    /// `result` schema variant ends with a non-optional `uuid`; empty is only
    /// the zero-value default for hand-built test fixtures that don't care.
    uuid: []const u8 = "",
    /// Client uuid of the user message that triggered this turn
    /// (submitMessage options.uuid), stamped on the turn's first reply frame
    /// only. Optional in the reference; omitted when empty
    /// (headless-sdk-missed-186).
    user_message_uuid: []const u8 = "",
    /// headless-sdk-missed-184: the real extended-thinking text behind
    /// `result_text` (AgentRuntime.TurnResult.final_thinking), when the
    /// model returned one. Empty -> no `thinking` content block emitted;
    /// never fabricated, only ever the model's own captured reasoning_text.
    final_thinking: []const u8 = "",
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
    try writeUsageObject(w, result.usage);

    // Single-entry modelUsage keyed by the active model. When the model is
    // unknown we still emit an empty object so the key is always present.
    try w.writeAll(",\"modelUsage\":{");
    if (result.model.len > 0) {
        try writeJsonString(w, result.model);
        try w.writeAll(":");
        try writeUsageObject(w, result.usage);
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
            // ez schema: `tool_input`, not `tool_use_input` (headless-sdk-07).
            try w.writeAll(",\"tool_input\":");
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
    if (result.user_message_uuid.len > 0) {
        try w.writeAll(",\"user_message_uuid\":");
        try writeJsonString(w, result.user_message_uuid);
    }
    // Every reference result schema variant ends with a non-optional `uuid`
    // (headless-sdk-05); always emit the key even when the caller left it
    // empty (hand-built test fixtures).
    try w.writeAll(",\"uuid\":");
    try writeJsonString(w, result.uuid);
    try w.writeAll("}");

    try out.append('\n');
    return finalizeNdjson(allocator, out.items());
}

/// One entry in `system:init.mcp_servers` (headless-sdk-10/18). `status` is a
/// free-form string; zcode reports "connected" (a live session exists) or
/// "pending" (configured but not yet connected) -- it does not distinguish a
/// hard connection failure from "not yet attempted" the way the reference's
/// richer per-type mapping does.
pub const McpServerInfo = struct {
    name: []const u8,
    status: []const u8 = "pending",
};

/// One entry in `system:init.plugins` (headless-sdk-10). `path`/`source`/
/// `version` are omitted when empty (all optional in the reference schema
/// except `name`/`path`, which we always emit even when path is unknown).
pub const PluginInfo = struct {
    name: []const u8,
    path: []const u8 = "",
    source: []const u8 = "",
    version: []const u8 = "",
};

/// The data behind a `system:init` message emitted at session start.
pub const InitInfo = struct {
    session_id: []const u8 = "",
    model: []const u8 = "",
    permission_mode: []const u8 = "",
    cwd: []const u8 = "",
    claude_code_version: []const u8 = "",
    /// Available tool names.
    tools: []const []const u8 = &.{},
    /// Connected MCP servers, each carrying its connection status
    /// (headless-sdk-10/18). An object array, not a bare string array.
    mcp_servers: []const McpServerInfo = &.{},
    /// Available slash-command names.
    slash_commands: []const []const u8 = &.{},
    skills: []const []const u8 = &.{},
    /// Installed plugins as {name, path, source?, version?} objects
    /// (headless-sdk-10). An object array, not a bare string array.
    plugins: []const PluginInfo = &.{},
    /// Credential source for the active session (headless-sdk-03). One of the
    /// reference's 9 enum values: ANTHROPIC_API_KEY, apiKeyHelper,
    /// "/login managed key", none, user, project, org, temporary, oauth.
    /// "none" is the safe default (mock provider, no credential in play).
    api_key_source: []const u8 = "none",
    /// The active /output-style name (headless-sdk-03).
    output_style: []const u8 = "default",
    /// SDK-registered agent names visible to this session (headless-sdk-03).
    /// Empty unless the host's `initialize` control_request registered any
    /// (missed-183).
    agents: []const []const u8 = &.{},
    /// A fresh UUIDv4 minted per init line (headless-sdk-03). Non-optional in
    /// the reference; empty is only the zero-value default for hand-built test
    /// fixtures that don't care.
    uuid: []const u8 = "",
    /// Active API betas, if any (headless-sdk-03). zcode does not track
    /// provider beta-header state today, so this is always empty (the key is
    /// still emitted for shape stability -- optional in the reference, so an
    /// empty array is a safe, honest default, never fabricated).
    betas: []const []const u8 = &.{},
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
    try w.writeAll(",\"apiKeySource\":");
    try writeJsonString(w, info.api_key_source);
    try w.writeAll(",\"output_style\":");
    try writeJsonString(w, info.output_style);

    try writeStringArray(w, "tools", info.tools);
    try writeMcpServerArray(w, info.mcp_servers);
    try writeStringArray(w, "slash_commands", info.slash_commands);
    try writeStringArray(w, "skills", info.skills);
    try writePluginArray(w, info.plugins);
    try writeStringArray(w, "agents", info.agents);
    try writeStringArray(w, "betas", info.betas);

    if (info.session_id.len > 0) {
        try w.writeAll(",\"session_id\":");
        try writeJsonString(w, info.session_id);
    }
    // Non-optional in the reference; always emit even when empty (hand-built
    // test fixtures that don't set it).
    try w.writeAll(",\"uuid\":");
    try writeJsonString(w, info.uuid);
    try w.writeAll("}");

    try out.append('\n');
    return finalizeNdjson(allocator, out.items());
}

/// Write `,"mcp_servers":[{"name":...,"status":...},...]`.
fn writeMcpServerArray(w: *std.Io.Writer, servers: []const McpServerInfo) !void {
    try w.writeAll(",\"mcp_servers\":[");
    for (servers, 0..) |s, idx| {
        if (idx != 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try writeJsonString(w, s.name);
        try w.writeAll(",\"status\":");
        try writeJsonString(w, s.status);
        try w.writeAll("}");
    }
    try w.writeAll("]");
}

/// Write `,"plugins":[{"name":...,"path":...[,"source":...][,"version":...]},...]`.
fn writePluginArray(w: *std.Io.Writer, plugins: []const PluginInfo) !void {
    try w.writeAll(",\"plugins\":[");
    for (plugins, 0..) |p, idx| {
        if (idx != 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try writeJsonString(w, p.name);
        try w.writeAll(",\"path\":");
        try writeJsonString(w, p.path);
        if (p.source.len > 0) {
            try w.writeAll(",\"source\":");
            try writeJsonString(w, p.source);
        }
        if (p.version.len > 0) {
            try w.writeAll(",\"version\":");
            try writeJsonString(w, p.version);
        }
        try w.writeAll("}");
    }
    try w.writeAll("]");
}

/// One content block of an `assistant` message's inner `message.content`
/// array (headless-sdk-08/missed-182/missed-184). `text` and `thinking` carry
/// their text verbatim (escaped on write); `tool_use` carries a pre-built
/// `ToolUseBlock`.
pub const ContentBlock = union(enum) {
    text: []const u8,
    thinking: []const u8,
    tool_use: ToolUseBlock,
};

/// A `tool_use` content block: the real dispatched tool name/input, matching
/// the shape a stream-json host uses to observe what the agent is doing
/// mid-turn (missed-182). `input_json` is raw JSON (already a valid object);
/// empty defaults to `{}`.
pub const ToolUseBlock = struct {
    id: []const u8,
    name: []const u8,
    input_json: []const u8 = "{}",
};

/// The data behind an SDK `assistant` message. Mirrors the reference's
/// "Shaped like an Anthropic Messages API Message object" description: `id`,
/// `model`, `content` blocks, `stop_reason`, and `usage` (headless-sdk-08).
///
/// zcode's turn loop is synchronous/batch (see headless.zig's module doc): a
/// tool_use/tool_result pair is emitted for each completed `ToolTrace` once
/// the round it belongs to has run, and `stop_reason`/`usage` are only known
/// (and only carried) on the turn's FINAL assistant message -- matching the
/// reference's own behavior of leaving those fields absent on in-progress
/// messages. This is a deliberate, documented approximation of true
/// mid-turn streaming, not a fabrication: every block still reflects a real
/// completed tool call or the real final text, never a guess.
pub const AssistantMessage = struct {
    session_id: []const u8,
    content: []const ContentBlock,
    /// A fresh UUIDv4 for this NDJSON envelope (headless-sdk-06).
    uuid: []const u8 = "",
    request_id: []const u8 = "",
    /// The active model (headless-sdk-08). Empty -> key omitted (test
    /// fixtures that don't care about this field).
    model: []const u8 = "",
    /// Per-response id (headless-sdk-08). Empty -> key omitted.
    message_id: []const u8 = "",
    /// Why the turn stopped. Empty -> emitted as JSON `null` (in-progress /
    /// per-tool-call events; matches the reference leaving it unset until the
    /// turn concludes).
    stop_reason: []const u8 = "",
    /// Present only on the turn's final assistant message (headless-sdk-08);
    /// null on per-tool-call events emitted mid-turn.
    usage: ?Usage = null,
    parent_tool_use_id: []const u8 = "",
    user_message_uuid: []const u8 = "",
};

/// Serialize an SDK `assistant` message to a single newline-terminated NDJSON
/// line. Matches the reference's assistant event shape (headless-sdk-08):
/// {"type":"assistant","message":{"id":...,"model":...,"role":"assistant",
///  "content":[...],"stop_reason":...,"usage":{...}},
///  "parent_tool_use_id":null,"request_id":"...","session_id":"...","uuid":"..."}
pub fn serializeAssistant(allocator: std.mem.Allocator, msg: AssistantMessage) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"type\":\"assistant\",\"message\":{");
    var wrote_field = false;
    if (msg.message_id.len > 0) {
        try w.writeAll("\"id\":");
        try writeJsonString(w, msg.message_id);
        wrote_field = true;
    }
    if (msg.model.len > 0) {
        if (wrote_field) try w.writeAll(",");
        try w.writeAll("\"model\":");
        try writeJsonString(w, msg.model);
        wrote_field = true;
    }
    if (wrote_field) try w.writeAll(",");
    try w.writeAll("\"role\":\"assistant\",\"content\":[");
    for (msg.content, 0..) |block, idx| {
        if (idx != 0) try w.writeAll(",");
        try writeContentBlock(w, block);
    }
    try w.writeAll("]");
    try w.writeAll(",\"stop_reason\":");
    if (msg.stop_reason.len > 0) {
        try writeJsonString(w, msg.stop_reason);
    } else {
        try w.writeAll("null");
    }
    if (msg.usage) |u| {
        try w.writeAll(",\"usage\":");
        try writeUsageObject(w, u);
    }
    try w.writeAll("}"); // close message

    try w.writeAll(",\"parent_tool_use_id\":");
    if (msg.parent_tool_use_id.len > 0) {
        try writeJsonString(w, msg.parent_tool_use_id);
    } else {
        try w.writeAll("null");
    }
    if (msg.request_id.len > 0) {
        try w.writeAll(",\"request_id\":");
        try writeJsonString(w, msg.request_id);
    }
    try w.writeAll(",\"session_id\":");
    try writeJsonString(w, msg.session_id);
    if (msg.user_message_uuid.len > 0) {
        try w.writeAll(",\"user_message_uuid\":");
        try writeJsonString(w, msg.user_message_uuid);
    }
    try w.writeAll(",\"uuid\":");
    try writeJsonString(w, msg.uuid);
    try w.writeAll("}");

    try out.append('\n');
    return finalizeNdjson(allocator, out.items());
}

fn writeContentBlock(w: *std.Io.Writer, block: ContentBlock) !void {
    switch (block) {
        .text => |text| {
            try w.writeAll("{\"type\":\"text\",\"text\":");
            try writeJsonString(w, text);
            try w.writeAll("}");
        },
        .thinking => |text| {
            try w.writeAll("{\"type\":\"thinking\",\"thinking\":");
            try writeJsonString(w, text);
            try w.writeAll("}");
        },
        .tool_use => |tu| {
            try w.writeAll("{\"type\":\"tool_use\",\"id\":");
            try writeJsonString(w, tu.id);
            try w.writeAll(",\"name\":");
            try writeJsonString(w, tu.name);
            try w.writeAll(",\"input\":");
            try w.writeAll(if (tu.input_json.len > 0) tu.input_json else "{}");
            try w.writeAll("}");
        },
    }
}

/// Serialize an SDK `user` message carrying a `tool_result` content block
/// (missed-182) -- the reply half of a `tool_use`/`tool_result` pair a
/// stream-json host uses to observe a completed tool call mid-turn.
/// `content_text` is the tool's rendered output (escaped on write).
pub fn serializeUserToolResult(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    tool_use_id: []const u8,
    content_text: []const u8,
    is_error: bool,
    uuid: []const u8,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[");
    try w.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
    try writeJsonString(w, tool_use_id);
    try w.writeAll(",\"content\":");
    try writeJsonString(w, content_text);
    try w.print(",\"is_error\":{}", .{is_error});
    try w.writeAll("}]}");
    try w.writeAll(",\"parent_tool_use_id\":null");
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

/// headless-sdk-14 (`--forward-subagent-text`): a subagent's own prompt,
/// forwarded as a `user` NDJSON line tagged with `parent_tool_use_id` set to
/// the spawning Agent tool call's tool_use id. Distinct from
/// `serializeUserReplay` (a top-level accepted-message ack, always
/// `parent_tool_use_id: null`, plain-string content) -- this one is always
/// nested under a parent tool call and uses the array-of-blocks content shape
/// to match `serializeAssistant`'s forwarded counterpart. Caller owns the
/// returned newline-terminated slice.
pub fn serializeForwardedUserText(
    allocator: std.mem.Allocator,
    text: []const u8,
    parent_tool_use_id: []const u8,
    session_id: []const u8,
    uuid: []const u8,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":");
    try writeJsonString(w, text);
    try w.writeAll("}]}");
    try w.writeAll(",\"parent_tool_use_id\":");
    if (parent_tool_use_id.len > 0) {
        try writeJsonString(w, parent_tool_use_id);
    } else {
        try w.writeAll("null");
    }
    if (session_id.len > 0) {
        try w.writeAll(",\"session_id\":");
        try writeJsonString(w, session_id);
    }
    if (uuid.len > 0) {
        try w.writeAll(",\"uuid\":");
        try writeJsonString(w, uuid);
    }
    try w.writeAll("}");

    try out.append('\n');
    return finalizeNdjson(allocator, out.items());
}

/// Serialize a `prompt_suggestion` message (headless-sdk-15): "Predicted next
/// user prompt, emitted after each turn when promptSuggestions is enabled."
/// `suggestion` is the predicted prompt text (escaped on write). Caller owns
/// the returned newline-terminated slice.
///
/// Wire-format only: no zcode call site currently invokes this. Generating a
/// genuine "predicted next prompt" needs either an extra model call (cost/
/// latency the reference presumably accepts but this package has not wired)
/// or a text heuristic good enough not to mislead a host -- neither was
/// judged worth shipping half-built, so this is documented as an unwired but
/// spec-correct building block for whichever call site takes that on.
pub fn serializePromptSuggestion(
    allocator: std.mem.Allocator,
    suggestion: []const u8,
    session_id: []const u8,
    uuid: []const u8,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"type\":\"prompt_suggestion\",\"suggestion\":");
    try writeJsonString(w, suggestion);
    try w.writeAll(",\"session_id\":");
    try writeJsonString(w, session_id);
    try w.writeAll(",\"uuid\":");
    try writeJsonString(w, uuid);
    try w.writeAll("}");

    try out.append('\n');
    return finalizeNdjson(allocator, out.items());
}

/// Serialize a `commands_changed` `system` message (headless-sdk-16):
/// "Fire-and-forget push of the full slash-command list after a mid-session
/// change ... Clients should REPLACE their cached command list with this
/// payload." `commands` is the new full slash-command name list (not a
/// diff). Caller owns the returned newline-terminated slice.
///
/// Wire-format only: no zcode call site currently detects "the slash-command/
/// skill list changed mid-session" as a discrete event (e.g. /reload-skills,
/// or a directory change that surfaces a new `.claude/skills`) -- that
/// detection lives in core/skills.zig and the REPL command layer, outside
/// this package's ownership.
pub fn serializeCommandsChanged(
    allocator: std.mem.Allocator,
    commands: []const []const u8,
    session_id: []const u8,
    uuid: []const u8,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"type\":\"system\",\"subtype\":\"commands_changed\"");
    try writeStringArray(w, "commands", commands);
    try w.writeAll(",\"session_id\":");
    try writeJsonString(w, session_id);
    try w.writeAll(",\"uuid\":");
    try writeJsonString(w, uuid);
    try w.writeAll("}");

    try out.append('\n');
    return finalizeNdjson(allocator, out.items());
}

/// Serialize an `auth_status` message (headless-sdk-missed-185): surfaces
/// CLI auth/login flow progress (e.g. OAuth device-code prompts) to a
/// stream-json host, gated behind the reference's hidden `--enable-auth-status`
/// flag. `output_lines` is the auth flow's captured output (e.g. a device-code
/// URL); `error_message` is optional (empty -> the `error` key is omitted).
/// Caller owns the returned newline-terminated slice.
///
/// Wire-format mostly: `--enable-auth-status` now parses (cli/args.zig,
/// hidden from --help per the reference's `.hideHelp()`) and is stored on
/// `CliOptions.enable_auth_status`, but no call site inside `zcode login`/
/// `zcode mcp auth login` emits stream-json today -- wiring an actual login
/// flow to call this serializer belongs to whichever package owns those
/// command handlers, outside this package's ownership.
pub fn serializeAuthStatus(
    allocator: std.mem.Allocator,
    is_authenticating: bool,
    output_lines: []const []const u8,
    error_message: []const u8,
    session_id: []const u8,
    uuid: []const u8,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"type\":\"auth_status\",\"isAuthenticating\":");
    try w.print("{}", .{is_authenticating});
    try writeStringArray(w, "output", output_lines);
    if (error_message.len > 0) {
        try w.writeAll(",\"error\":");
        try writeJsonString(w, error_message);
    }
    try w.writeAll(",\"session_id\":");
    try writeJsonString(w, session_id);
    try w.writeAll(",\"uuid\":");
    try writeJsonString(w, uuid);
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

test "serializeInit: apiKeySource, output_style, agents, betas, uuid are present (headless-sdk-03)" {
    const allocator = testing.allocator;
    const agents = [_][]const u8{"reviewer"};
    const info = InitInfo{
        .model = "mock-agent",
        .cwd = "/tmp",
        .claude_code_version = "v",
        .api_key_source = "user",
        .output_style = "concise",
        .agents = &agents,
        .uuid = "11111111-1111-4111-8111-111111111111",
    };
    const line = try serializeInit(allocator, info);
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("user", obj.get("apiKeySource").?.string);
    try testing.expectEqualStrings("concise", obj.get("output_style").?.string);
    try testing.expectEqual(@as(usize, 1), obj.get("agents").?.array.items.len);
    try testing.expectEqualStrings("reviewer", obj.get("agents").?.array.items[0].string);
    try testing.expect(obj.get("betas").? == .array);
    try testing.expectEqualStrings("11111111-1111-4111-8111-111111111111", obj.get("uuid").?.string);
}

test "serializeInit: mcp_servers and plugins are object arrays, not bare strings (headless-sdk-10/18)" {
    const allocator = testing.allocator;
    const servers = [_]McpServerInfo{
        .{ .name = "filesystem", .status = "connected" },
        .{ .name = "flaky", .status = "pending" },
    };
    const plugins = [_]PluginInfo{
        .{ .name = "my-plugin", .path = "/plugins/my-plugin", .version = "1.0.0" },
    };
    const info = InitInfo{
        .model = "mock-agent",
        .cwd = "/tmp",
        .claude_code_version = "v",
        .mcp_servers = &servers,
        .plugins = &plugins,
    };
    const line = try serializeInit(allocator, info);
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    const mcp = obj.get("mcp_servers").?.array.items;
    try testing.expectEqual(@as(usize, 2), mcp.len);
    try testing.expectEqualStrings("filesystem", mcp[0].object.get("name").?.string);
    try testing.expectEqualStrings("connected", mcp[0].object.get("status").?.string);
    try testing.expectEqualStrings("flaky", mcp[1].object.get("name").?.string);
    try testing.expectEqualStrings("pending", mcp[1].object.get("status").?.string);

    const plug = obj.get("plugins").?.array.items;
    try testing.expectEqual(@as(usize, 1), plug.len);
    try testing.expectEqualStrings("my-plugin", plug[0].object.get("name").?.string);
    try testing.expectEqualStrings("/plugins/my-plugin", plug[0].object.get("path").?.string);
    try testing.expectEqualStrings("1.0.0", plug[0].object.get("version").?.string);
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

test "headless-sdk-14: serializeForwardedUserText carries parent_tool_use_id and array content" {
    const allocator = testing.allocator;
    const line = try serializeForwardedUserText(allocator, "investigate the bug", "toolu_sess_0", "sess-4", "u-5");
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("user", obj.get("type").?.string);
    try testing.expectEqualStrings("toolu_sess_0", obj.get("parent_tool_use_id").?.string);
    try testing.expectEqualStrings("sess-4", obj.get("session_id").?.string);
    try testing.expectEqualStrings("u-5", obj.get("uuid").?.string);
    const content = obj.get("message").?.object.get("content").?.array.items;
    try testing.expectEqual(@as(usize, 1), content.len);
    try testing.expectEqualStrings("text", content[0].object.get("type").?.string);
    try testing.expectEqualStrings("investigate the bug", content[0].object.get("text").?.string);
}

test "headless-sdk-14: validateForwardSubagentTextGate requires --print and stream-json" {
    // Off entirely -> never gated, regardless of the other flags.
    try validateForwardSubagentTextGate(false, .text, false);
    // On, with both requirements met -> passes.
    try validateForwardSubagentTextGate(true, .stream_json, true);
    // On, missing --print -> rejected.
    try testing.expectError(error.ForwardSubagentTextRequiresStreamJson, validateForwardSubagentTextGate(false, .stream_json, true));
    // On, wrong output format -> rejected.
    try testing.expectError(error.ForwardSubagentTextRequiresStreamJson, validateForwardSubagentTextGate(true, .json, true));
}

// ── headless-sdk-05/missed-186: result uuid / user_message_uuid ────────────

test "serializeResult: carries a required uuid and an optional user_message_uuid" {
    const allocator = testing.allocator;
    const result = Result{
        .subtype = .success,
        .result_text = "ok",
        .uuid = "22222222-2222-4222-8222-222222222222",
        .user_message_uuid = "client-uuid-1",
    };
    const line = try serializeResult(allocator, result, &.{});
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("22222222-2222-4222-8222-222222222222", obj.get("uuid").?.string);
    try testing.expectEqualStrings("client-uuid-1", obj.get("user_message_uuid").?.string);
}

test "serializeResult: omits user_message_uuid when empty" {
    const allocator = testing.allocator;
    const line = try serializeResult(allocator, .{ .subtype = .success }, &.{});
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("user_message_uuid") == null);
    // uuid is still present (possibly empty) since it is non-optional.
    try testing.expect(parsed.value.object.get("uuid") != null);
}

// ── headless-sdk-07: permission_denials use `tool_input`, not `tool_use_input` ──

test "serializeResult: permission_denials entry key is tool_input" {
    const allocator = testing.allocator;
    const denials = [_]PermissionDenial{
        .{ .tool_name = "Bash", .tool_use_id = "tu-1", .tool_input_json = "{\"command\":\"rm -rf /\"}" },
    };
    const line = try serializeResult(allocator, .{ .subtype = .success }, &denials);
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const entry = parsed.value.object.get("permission_denials").?.array.items[0].object;
    try testing.expectEqualStrings("rm -rf /", entry.get("tool_input").?.object.get("command").?.string);
    try testing.expect(entry.get("tool_use_input") == null);
}

// ── headless-sdk-09: usage/modelUsage carry the full reference shape ───────

test "serializeResult: usage and modelUsage carry cache token fields and shape-stability keys" {
    const allocator = testing.allocator;
    const result = Result{
        .subtype = .success,
        .model = "claude-sonnet-4",
        .usage = .{
            .input_tokens = 10,
            .output_tokens = 5,
            .cache_creation_input_tokens = 3,
            .cache_read_input_tokens = 7,
        },
    };
    const line = try serializeResult(allocator, result, &.{});
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const usage = parsed.value.object.get("usage").?.object;
    try testing.expectEqual(@as(i64, 3), usage.get("cache_creation_input_tokens").?.integer);
    try testing.expectEqual(@as(i64, 7), usage.get("cache_read_input_tokens").?.integer);
    try testing.expectEqualStrings("standard", usage.get("service_tier").?.string);
    try testing.expect(usage.get("output_tokens_details").?.object.get("thinking_tokens") != null);

    const model_usage = parsed.value.object.get("modelUsage").?.object.get("claude-sonnet-4").?.object;
    try testing.expectEqual(@as(i64, 3), model_usage.get("cache_creation_input_tokens").?.integer);
    try testing.expectEqual(@as(i64, 7), model_usage.get("cache_read_input_tokens").?.integer);
}

// ── headless-sdk-08/missed-182/missed-184: assistant content blocks ────────

test "serializeAssistant: text-only message carries model, id, stop_reason, usage" {
    const allocator = testing.allocator;
    const line = try serializeAssistant(allocator, .{
        .session_id = "sess-1",
        .content = &.{.{ .text = "all done" }},
        .uuid = "u-1",
        .model = "mock-agent",
        .message_id = "msg-1",
        .stop_reason = "end_turn",
        .usage = .{ .input_tokens = 12, .output_tokens = 4 },
    });
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("assistant", obj.get("type").?.string);
    const message = obj.get("message").?.object;
    try testing.expectEqualStrings("msg-1", message.get("id").?.string);
    try testing.expectEqualStrings("mock-agent", message.get("model").?.string);
    try testing.expectEqualStrings("assistant", message.get("role").?.string);
    try testing.expectEqualStrings("end_turn", message.get("stop_reason").?.string);
    try testing.expectEqual(@as(i64, 12), message.get("usage").?.object.get("input_tokens").?.integer);
    const content = message.get("content").?.array.items;
    try testing.expectEqual(@as(usize, 1), content.len);
    try testing.expectEqualStrings("text", content[0].object.get("type").?.string);
    try testing.expectEqualStrings("all done", content[0].object.get("text").?.string);
}

test "serializeAssistant: in-progress tool_use event omits stop_reason/usage (null stop_reason)" {
    const allocator = testing.allocator;
    const line = try serializeAssistant(allocator, .{
        .session_id = "sess-1",
        .uuid = "u-2",
        .content = &.{.{ .tool_use = .{ .id = "tu-1", .name = "Bash", .input_json = "{\"command\":\"ls\"}" } }},
    });
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const message = parsed.value.object.get("message").?.object;
    try testing.expect(message.get("stop_reason").? == .null);
    try testing.expect(message.get("usage") == null);
    const block = message.get("content").?.array.items[0].object;
    try testing.expectEqualStrings("tool_use", block.get("type").?.string);
    try testing.expectEqualStrings("tu-1", block.get("id").?.string);
    try testing.expectEqualStrings("Bash", block.get("name").?.string);
    try testing.expectEqualStrings("ls", block.get("input").?.object.get("command").?.string);
}

test "serializeAssistant: a thinking block round-trips" {
    const allocator = testing.allocator;
    const line = try serializeAssistant(allocator, .{
        .session_id = "sess-1",
        .uuid = "u-3",
        .content = &.{.{ .thinking = "let me consider..." }},
    });
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const block = parsed.value.object.get("message").?.object.get("content").?.array.items[0].object;
    try testing.expectEqualStrings("thinking", block.get("type").?.string);
    try testing.expectEqualStrings("let me consider...", block.get("thinking").?.string);
}

test "headless-sdk-missed-184: a thinking block precedes the final text block, in the exact order headless.zig builds them" {
    const allocator = testing.allocator;
    // Mirrors the content_buf construction in sdk/headless.zig's two
    // serializeAssistant call sites: a real thinking block (only ever from
    // TurnResult.final_thinking) goes first, the final text always last.
    const line = try serializeAssistant(allocator, .{
        .session_id = "sess-1",
        .uuid = "u-4",
        .model = "mock-agent",
        .stop_reason = "end_turn",
        .usage = .{ .input_tokens = 5, .output_tokens = 7 },
        .content = &.{
            .{ .thinking = "the user asked for X; I recalled it directly" },
            .{ .text = "here is X" },
        },
    });
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const content = parsed.value.object.get("message").?.object.get("content").?.array.items;
    try testing.expectEqual(@as(usize, 2), content.len);
    try testing.expectEqualStrings("thinking", content[0].object.get("type").?.string);
    try testing.expectEqualStrings("the user asked for X; I recalled it directly", content[0].object.get("thinking").?.string);
    try testing.expectEqualStrings("text", content[1].object.get("type").?.string);
    try testing.expectEqualStrings("here is X", content[1].object.get("text").?.string);
}

test "serializeAssistant: parent_tool_use_id null when top-level, string when set" {
    const allocator = testing.allocator;
    const top = try serializeAssistant(allocator, .{
        .session_id = "s",
        .uuid = "u",
        .content = &.{.{ .text = "x" }},
    });
    defer allocator.free(top);
    var p1 = try std.json.parseFromSlice(std.json.Value, allocator, top, .{});
    defer p1.deinit();
    try testing.expect(p1.value.object.get("parent_tool_use_id").? == .null);

    const nested = try serializeAssistant(allocator, .{
        .session_id = "s",
        .uuid = "u",
        .content = &.{.{ .text = "x" }},
        .parent_tool_use_id = "tu-parent",
    });
    defer allocator.free(nested);
    var p2 = try std.json.parseFromSlice(std.json.Value, allocator, nested, .{});
    defer p2.deinit();
    try testing.expectEqualStrings("tu-parent", p2.value.object.get("parent_tool_use_id").?.string);
}

test "serializeUserToolResult: emits a tool_result content block" {
    const allocator = testing.allocator;
    const line = try serializeUserToolResult(allocator, "sess-1", "tu-1", "file written", false, "u-4");
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("user", obj.get("type").?.string);
    try testing.expect(obj.get("parent_tool_use_id").? == .null);
    const block = obj.get("message").?.object.get("content").?.array.items[0].object;
    try testing.expectEqualStrings("tool_result", block.get("type").?.string);
    try testing.expectEqualStrings("tu-1", block.get("tool_use_id").?.string);
    try testing.expectEqualStrings("file written", block.get("content").?.string);
    try testing.expectEqual(false, block.get("is_error").?.bool);
    try testing.expectEqualStrings("sess-1", obj.get("session_id").?.string);
    try testing.expectEqualStrings("u-4", obj.get("uuid").?.string);
}

test "serializeUserToolResult: is_error true for a denied/failed tool call" {
    const allocator = testing.allocator;
    const line = try serializeUserToolResult(allocator, "sess-1", "tu-2", "permission denied", true, "u-5");
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const block = parsed.value.object.get("message").?.object.get("content").?.array.items[0].object;
    try testing.expectEqual(true, block.get("is_error").?.bool);
}

// ── headless-sdk-15/16/missed-185: prompt_suggestion / commands_changed /
//    auth_status wire-format serializers ──────────────────────────────────

test "serializePromptSuggestion: emits the predicted prompt shape" {
    const allocator = testing.allocator;
    const line = try serializePromptSuggestion(allocator, "add a test for the edge case", "sess-1", "u-1");
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("prompt_suggestion", obj.get("type").?.string);
    try testing.expectEqualStrings("add a test for the edge case", obj.get("suggestion").?.string);
    try testing.expectEqualStrings("sess-1", obj.get("session_id").?.string);
    try testing.expectEqualStrings("u-1", obj.get("uuid").?.string);
}

test "serializeCommandsChanged: pushes the full replacement command list" {
    const allocator = testing.allocator;
    const commands = [_][]const u8{ "help", "clear", "compact" };
    const line = try serializeCommandsChanged(allocator, &commands, "sess-2", "u-2");
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("system", obj.get("type").?.string);
    try testing.expectEqualStrings("commands_changed", obj.get("subtype").?.string);
    try testing.expectEqual(@as(usize, 3), obj.get("commands").?.array.items.len);
    try testing.expectEqualStrings("compact", obj.get("commands").?.array.items[2].string);
}

test "serializeAuthStatus: carries isAuthenticating, output lines, and omits error when empty" {
    const allocator = testing.allocator;
    const output_lines = [_][]const u8{"visit https://example.com/device to authorize"};
    const line = try serializeAuthStatus(allocator, true, &output_lines, "", "sess-3", "u-3");
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("auth_status", obj.get("type").?.string);
    try testing.expectEqual(true, obj.get("isAuthenticating").?.bool);
    try testing.expectEqual(@as(usize, 1), obj.get("output").?.array.items.len);
    try testing.expect(obj.get("error") == null);
}

test "serializeAuthStatus: carries an error message when set" {
    const allocator = testing.allocator;
    const line = try serializeAuthStatus(allocator, false, &.{}, "token exchange failed", "sess-4", "u-4");
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("token exchange failed", parsed.value.object.get("error").?.string);
}
