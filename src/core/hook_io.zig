//! P3 (PRD #534) hook JSON contract. Builds the JSON payload Claude Code passes
//! to a hook on stdin and parses the `hookSpecificOutput` a hook may print on
//! stdout. Parsing is tolerant: empty or invalid output yields defaults (hooks
//! are allowed to communicate via exit code only).

const std = @import("std");
const sb = @import("std_io.zig");

pub const PermissionDecision = enum { allow, deny, ask, none };

/// Extracted, normalized view of a hook's stdout JSON. String fields borrow from
/// the owned `Parsed` value (or, for the re-serialized raw fields, from the
/// `Result.owned` storage), so keep `Result` alive while using them.
pub const Output = struct {
    permission_decision: PermissionDecision = .none,
    additional_context: ?[]const u8 = null,
    decision: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    continue_run: ?bool = null,
    suppress_output: ?bool = null,
    // hooks-04: the rest of the stdout sync contract (types/hooks.ts:50-166).
    stop_reason: ?[]const u8 = null,
    system_message: ?[]const u8 = null,
    permission_decision_reason: ?[]const u8 = null,
    // updated_input / updated_mcp_tool_output are objects, so they are
    // re-serialized into `Result.owned` (the parsed value is freed when the
    // caller is done, but these raw slices must outlive that). watch_paths is
    // parsed but treated as a no-op for now (FileChanged watching is deferred).
    updated_input: ?[]const u8 = null,
    updated_mcp_tool_output: ?[]const u8 = null,
    watch_paths: ?[]const u8 = null,
    retry: ?bool = null,
};

pub const Result = struct {
    parsed: ?std.json.Parsed(std.json.Value) = null,
    output: Output = .{},
    // Allocator + re-serialized raw JSON slices (updated_input etc.) that must
    // outlive `parsed`. Owned here and freed in deinit.
    allocator: ?std.mem.Allocator = null,
    owned: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *Result) void {
        if (self.allocator) |a| {
            for (self.owned.items) |slice| a.free(slice);
            self.owned.deinit(a);
        }
        if (self.parsed) |*p| p.deinit();
        self.parsed = null;
    }
};

/// hooks-permissions-09: base fields the reference's shared `Se` zod schema
/// puts on EVERY hook invocation, tool or lifecycle alike -- `session_id`,
/// `transcript_path`, `permission_mode`, `agent_id`, `prompt_id` (the
/// reference also carries `agent_type`/`effort`, not modeled here: zcode has
/// no reference-shaped agent-type/effort-tag to surface at the hook layer
/// yet). An empty string means "the caller had nothing to report" and the
/// field is omitted entirely, not emitted as `""`, so a hook script's
/// `.session_id // empty` idiom sees an absent key rather than a blank one.
pub const HookBaseFields = struct {
    session_id: []const u8 = "",
    transcript_path: []const u8 = "",
    permission_mode: []const u8 = "",
    agent_id: []const u8 = "",
    prompt_id: []const u8 = "",
};

fn writeBaseFields(w: anytype, base: HookBaseFields) !void {
    if (base.session_id.len > 0) try w.print(",\"session_id\":{f}", .{std.json.fmt(base.session_id, .{})});
    if (base.transcript_path.len > 0) try w.print(",\"transcript_path\":{f}", .{std.json.fmt(base.transcript_path, .{})});
    if (base.prompt_id.len > 0) try w.print(",\"prompt_id\":{f}", .{std.json.fmt(base.prompt_id, .{})});
    if (base.permission_mode.len > 0) try w.print(",\"permission_mode\":{f}", .{std.json.fmt(base.permission_mode, .{})});
    if (base.agent_id.len > 0) try w.print(",\"agent_id\":{f}", .{std.json.fmt(base.agent_id, .{})});
}

/// hooks-permissions-09: per-event extensions layered on top of the tool-event
/// base shape. `tool_use_id` is documented on PreToolUse/PostToolUse/
/// PostToolUseFailure/PermissionRequest/PermissionDenied; `duration_ms` on
/// PostToolUse/PostToolUseFailure ("Tool execution time in milliseconds");
/// `reason` on PermissionDenied (and doubles, harmlessly, for any other tool
/// event a caller chooses to attach one to -- extra JSON keys are inert to a
/// hook that does not look for them).
pub const ToolEventExtra = struct {
    tool_use_id: []const u8 = "",
    reason: []const u8 = "",
    duration_ms: ?u64 = null,
};

/// Build the stdin JSON for a tool event. `tool_input_raw` is embedded as a JSON
/// value when it is itself valid JSON, otherwise as a JSON string.
///
/// Backward-compatible 5-arg form: emits only `tool_input` (no `tool_response`,
/// no base/extra fields).
/// Use `buildToolEventPayloadFull` to also embed the PostToolUse response and
/// the reference's base/per-event fields.
pub fn buildToolEventPayload(
    allocator: std.mem.Allocator,
    event_name: []const u8,
    tool_name: []const u8,
    tool_input_raw: []const u8,
    cwd: []const u8,
) ![]u8 {
    return buildToolEventPayloadFull(allocator, event_name, tool_name, tool_input_raw, cwd, null, true, .{}, .{});
}

/// Build the stdin JSON for a tool event, optionally embedding the tool response.
/// When `tool_response` is non-null (PostToolUse / PostToolUseFailure), it is
/// embedded as `"tool_response"` - as a nested JSON value when it is itself valid
/// JSON, otherwise as a JSON string (same raw-vs-string rule as `tool_input`).
/// For PostToolUseFailure the response doubles as the `"error"` field and
/// `"is_interrupt"`/`"is_timeout"` flags are emitted (`success == false` implies
/// the call failed; interrupt/timeout are not separately tracked here so both
/// default to false).
///
/// `base` (hooks-permissions-09) carries the reference's always-present
/// session_id/transcript_path/permission_mode/agent_id/prompt_id fields; `extra`
/// carries the tool-event-specific tool_use_id/reason/duration_ms. Both are
/// emitted only when non-empty/non-null so a caller with nothing to report
/// (e.g. a test building a bare payload) produces the same JSON shape as before
/// this field set was added.
pub fn buildToolEventPayloadFull(
    allocator: std.mem.Allocator,
    event_name: []const u8,
    tool_name: []const u8,
    tool_input_raw: []const u8,
    cwd: []const u8,
    tool_response: ?[]const u8,
    success: bool,
    base: HookBaseFields,
    extra: ToolEventExtra,
) ![]u8 {
    var builder = sb.StringBuilder.init(allocator);
    defer builder.deinit();
    const w = builder.writer();

    try w.print("{{\"hook_event_name\":{f},\"tool_name\":{f},\"cwd\":{f},\"tool_input\":", .{
        std.json.fmt(event_name, .{}),
        std.json.fmt(tool_name, .{}),
        std.json.fmt(cwd, .{}),
    });
    if (isValidJson(allocator, tool_input_raw)) {
        try w.writeAll(tool_input_raw);
    } else {
        try w.print("{f}", .{std.json.fmt(tool_input_raw, .{})});
    }

    const is_post = std.mem.eql(u8, event_name, "PostToolUse");
    const is_failure = std.mem.eql(u8, event_name, "PostToolUseFailure");
    if (tool_response) |resp| {
        if (is_post or is_failure) {
            try w.writeAll(",\"tool_response\":");
            if (isValidJson(allocator, resp)) {
                try w.writeAll(resp);
            } else {
                try w.print("{f}", .{std.json.fmt(resp, .{})});
            }
        }
        if (is_failure) {
            // PostToolUseFailure mirrors the reference: the tool response text is
            // the `error`, plus boolean interrupt/timeout flags. The runtime only
            // tracks a coarse success bit, so interrupt/timeout default to false.
            try w.print(",\"error\":{f},\"is_interrupt\":false,\"is_timeout\":false", .{std.json.fmt(resp, .{})});
        }
    }
    _ = success;

    try writeBaseFields(w, base);
    if (extra.tool_use_id.len > 0) try w.print(",\"tool_use_id\":{f}", .{std.json.fmt(extra.tool_use_id, .{})});
    if (extra.reason.len > 0) try w.print(",\"reason\":{f}", .{std.json.fmt(extra.reason, .{})});
    if (extra.duration_ms) |d| try w.print(",\"duration_ms\":{d}", .{d});

    try w.writeAll("}");
    return allocator.dupe(u8, builder.items());
}

/// Discriminating + context fields for a non-tool lifecycle event. Only the
/// fields relevant to a given event are emitted by `buildLifecycleEventPayload`;
/// the rest stay null. All strings borrow from the caller.
pub const LifecycleFields = struct {
    source: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    message: ?[]const u8 = null,
    title: ?[]const u8 = null,
    trigger: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    // TaskCreated / TaskCompleted carry the task identity so a hook can inspect
    // the task it is gating (swarm-tasks-15). Emitted as `task_id`/`task_subject`.
    task_id: ?[]const u8 = null,
    task_subject: ?[]const u8 = null,
    // hooks-permissions-10: Notification's required, separate category field
    // (reference `xoe` schema: `{hook_event_name:"Notification", message,
    // title?, notification_type}`). Distinct from the free-text `message` --
    // this is what a `"matcher":"idle"`-style Notification hook actually
    // matches against.
    notification_type: ?[]const u8 = null,
    // hooks-permissions-03: the remaining lifecycle events' discriminating
    // fields, verified against the reference's zod schemas (cc_strings.txt
    // offsets ~13291777-13292436). `source` is shared with SessionStart's
    // field of the same JSON name (ConfigChange's `source` enum --
    // user_settings/project_settings/local_settings/policy_settings/skills --
    // is a different value space, but the same wire key). `file_path` is
    // shared by ConfigChange (optional), InstructionsLoaded, and FileChanged.
    file_path: ?[]const u8 = null,
    // InstructionsLoaded: `memory_type` (User/Project/Local/Managed),
    // `load_reason` (session_start/nested_traversal/path_glob_match/include/
    // compact).
    memory_type: ?[]const u8 = null,
    load_reason: ?[]const u8 = null,
    // CwdChanged: `old_cwd`/`new_cwd`.
    old_cwd: ?[]const u8 = null,
    new_cwd: ?[]const u8 = null,
    // FileChanged: `event` (change/add/unlink). Named `change_event` on the
    // Zig side since `event` collides with nothing but reads oddly as a bare
    // field name next to the struct's own semantics; emitted under the
    // reference's literal `"event"` JSON key.
    change_event: ?[]const u8 = null,
    // TeammateIdle: `teammate_name` (required), `team_name` (reference marks
    // `@deprecated` but still documents it; zcode has a single implicit team
    // per session so this is carried for wire-compat only).
    teammate_name: ?[]const u8 = null,
    team_name: ?[]const u8 = null,
    // WorktreeCreate: `name` (the worktree's logical name, not its path --
    // emitted under the reference's literal `"name"` JSON key, so the Zig
    // field is `worktree_name` to avoid shadowing anything struct-wide).
    worktree_name: ?[]const u8 = null,
    // WorktreeRemove: `worktree_path`.
    worktree_path: ?[]const u8 = null,
    // hooks-permissions-02 (corrected semantics): StopFailure fires INSTEAD
    // OF Stop when the model/API call itself errored ending the turn
    // (reference bundle: "Fires instead of Stop when an API error (rate
    // limit, auth failure, etc.) ended the turn"), not when a Stop hook's own
    // execution fails as originally guessed -- see agent_runtime.zig's
    // `fireStopFailureHook` doc comment for the full correction. `error` is
    // required; `error_details`/`last_assistant_message` are optional.
    // `error` needs `@""`-escaping: it is a Zig keyword as a bare identifier.
    @"error": ?[]const u8 = null,
    error_details: ?[]const u8 = null,
    last_assistant_message: ?[]const u8 = null,
};

/// Build the stdin JSON for a non-tool lifecycle event (SessionStart,
/// UserPromptSubmit, Stop, SessionEnd, PreCompact, Notification, ...). Always
/// includes `hook_event_name` and `cwd`; emits only the `fields` that are set,
/// plus the reference's always-present `base` fields (hooks-permissions-09;
/// see `HookBaseFields`), also emitted only when non-empty. String values are
/// JSON-escaped via `std.json.fmt`, matching the tool builder.
///
/// Backward-compatible 4-arg call sites (every pre-existing caller/test) keep
/// compiling unchanged by passing `.{}` for `base` -- see the 4-arg forwarding
/// note is unnecessary here since Zig requires the argument explicitly; test
/// call sites were updated alongside this signature change.
pub fn buildLifecycleEventPayload(
    allocator: std.mem.Allocator,
    event_name: []const u8,
    cwd: []const u8,
    fields: LifecycleFields,
    base: HookBaseFields,
) ![]u8 {
    var builder = sb.StringBuilder.init(allocator);
    defer builder.deinit();
    const w = builder.writer();

    try w.print("{{\"hook_event_name\":{f},\"cwd\":{f}", .{
        std.json.fmt(event_name, .{}),
        std.json.fmt(cwd, .{}),
    });
    if (fields.source) |v| try w.print(",\"source\":{f}", .{std.json.fmt(v, .{})});
    if (fields.prompt) |v| try w.print(",\"prompt\":{f}", .{std.json.fmt(v, .{})});
    if (fields.message) |v| try w.print(",\"message\":{f}", .{std.json.fmt(v, .{})});
    if (fields.title) |v| try w.print(",\"title\":{f}", .{std.json.fmt(v, .{})});
    if (fields.trigger) |v| try w.print(",\"trigger\":{f}", .{std.json.fmt(v, .{})});
    if (fields.reason) |v| try w.print(",\"reason\":{f}", .{std.json.fmt(v, .{})});
    if (fields.task_id) |v| try w.print(",\"task_id\":{f}", .{std.json.fmt(v, .{})});
    if (fields.task_subject) |v| try w.print(",\"task_subject\":{f}", .{std.json.fmt(v, .{})});
    if (fields.notification_type) |v| try w.print(",\"notification_type\":{f}", .{std.json.fmt(v, .{})});
    // hooks-permissions-03 / hooks-permissions-02 (corrected): the remaining
    // lifecycle events' fields (see `LifecycleFields`'s doc comment for the
    // reference schema each maps to).
    if (fields.file_path) |v| try w.print(",\"file_path\":{f}", .{std.json.fmt(v, .{})});
    if (fields.memory_type) |v| try w.print(",\"memory_type\":{f}", .{std.json.fmt(v, .{})});
    if (fields.load_reason) |v| try w.print(",\"load_reason\":{f}", .{std.json.fmt(v, .{})});
    if (fields.old_cwd) |v| try w.print(",\"old_cwd\":{f}", .{std.json.fmt(v, .{})});
    if (fields.new_cwd) |v| try w.print(",\"new_cwd\":{f}", .{std.json.fmt(v, .{})});
    if (fields.change_event) |v| try w.print(",\"event\":{f}", .{std.json.fmt(v, .{})});
    if (fields.teammate_name) |v| try w.print(",\"teammate_name\":{f}", .{std.json.fmt(v, .{})});
    if (fields.team_name) |v| try w.print(",\"team_name\":{f}", .{std.json.fmt(v, .{})});
    if (fields.worktree_name) |v| try w.print(",\"name\":{f}", .{std.json.fmt(v, .{})});
    if (fields.worktree_path) |v| try w.print(",\"worktree_path\":{f}", .{std.json.fmt(v, .{})});
    if (fields.@"error") |v| try w.print(",\"error\":{f}", .{std.json.fmt(v, .{})});
    if (fields.error_details) |v| try w.print(",\"error_details\":{f}", .{std.json.fmt(v, .{})});
    if (fields.last_assistant_message) |v| try w.print(",\"last_assistant_message\":{f}", .{std.json.fmt(v, .{})});
    try writeBaseFields(w, base);
    try w.writeAll("}");
    return allocator.dupe(u8, builder.items());
}

/// hooks-permissions-04: build the stdin JSON for `PostToolBatch`. Unlike
/// every other tool-shaped event, PostToolBatch has no single tool_name/
/// tool_input pair -- its payload is `tool_calls: [{tool_name, tool_input,
/// tool_use_id, tool_response?}, ...]` for the whole batch (reference `Moe`/
/// `Ioe` schemas). `tool_calls_json` is a pre-built, already-valid JSON array
/// literal (the caller assembles each element; this function only embeds it
/// verbatim, matching the tool builder's "raw JSON in, raw JSON out"
/// convention for structured sub-values) -- an empty array `"[]"` is passed
/// when the round had no tool calls (never actually reached by the one real
/// call site, which only fires after at least one call resolved).
pub fn buildPostToolBatchPayload(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    tool_calls_json: []const u8,
    base: HookBaseFields,
) ![]u8 {
    var builder = sb.StringBuilder.init(allocator);
    defer builder.deinit();
    const w = builder.writer();

    try w.print("{{\"hook_event_name\":\"PostToolBatch\",\"cwd\":{f},\"tool_calls\":", .{std.json.fmt(cwd, .{})});
    if (tool_calls_json.len > 0 and isValidJson(allocator, tool_calls_json)) {
        try w.writeAll(tool_calls_json);
    } else {
        try w.writeAll("[]");
    }
    try writeBaseFields(w, base);
    try w.writeAll("}");
    return allocator.dupe(u8, builder.items());
}

/// hooks-permissions-04: made `pub` so `agent_runtime.zig`'s PostToolBatch
/// call site can apply the same "embed as object when it already parses as
/// JSON, else as a JSON string" rule used throughout this file (`tool_input`/
/// `tool_response`) when assembling each `tool_calls[]` element -- rather than
/// duplicating this exact check there.
pub fn isValidJson(allocator: std.mem.Allocator, bytes: []const u8) bool {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return false;
    var p = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return false;
    p.deinit();
    return true;
}

fn objGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn asString(v: ?std.json.Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn asBool(v: ?std.json.Value) ?bool {
    const val = v orelse return null;
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}

/// Re-serialize a JSON value into an owned slice stashed in `result.owned` so it
/// outlives the parsed value. Returns the borrowed slice (or null on OOM).
fn captureRaw(result: *Result, allocator: std.mem.Allocator, v: std.json.Value) ?[]const u8 {
    const out = std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(v, .{})}) catch return null;
    result.owned.append(allocator, out) catch {
        allocator.free(out);
        return null;
    };
    return out;
}

/// Parse a hook's stdout. Empty/whitespace/invalid -> default Result. Reads both
/// the nested `hookSpecificOutput` object and the common top-level fields, and
/// honors the full sync contract (continue/stopReason/systemMessage/decision +
/// hookSpecificOutput.{permissionDecisionReason, updatedInput,
/// updatedMCPToolOutput, additionalContext, watchPaths, retry}).
pub fn parseOutput(allocator: std.mem.Allocator, stdout_bytes: []const u8) Result {
    const trimmed = std.mem.trim(u8, stdout_bytes, " \t\r\n");
    if (trimmed.len == 0) return .{};
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return .{};

    var result: Result = .{ .parsed = parsed, .allocator = allocator };
    var out: Output = .{};
    const root = parsed.value;

    out.decision = asString(objGet(root, "decision"));
    out.reason = asString(objGet(root, "reason"));
    out.continue_run = asBool(objGet(root, "continue"));
    out.suppress_output = asBool(objGet(root, "suppressOutput"));
    out.additional_context = asString(objGet(root, "additionalContext"));
    out.stop_reason = asString(objGet(root, "stopReason"));
    out.system_message = asString(objGet(root, "systemMessage"));

    if (objGet(root, "hookSpecificOutput")) |hso| {
        if (asString(objGet(hso, "additionalContext"))) |ac| out.additional_context = ac;
        if (asString(objGet(hso, "permissionDecision"))) |pd| {
            if (std.ascii.eqlIgnoreCase(pd, "allow")) out.permission_decision = .allow;
            if (std.ascii.eqlIgnoreCase(pd, "deny")) out.permission_decision = .deny;
            if (std.ascii.eqlIgnoreCase(pd, "ask")) out.permission_decision = .ask;
        }
        out.permission_decision_reason = asString(objGet(hso, "permissionDecisionReason"));
        out.retry = asBool(objGet(hso, "retry"));
        // updatedInput / updatedMCPToolOutput are objects; the parsed value is
        // freed before the consumer rewrites tool args, so re-serialize them
        // into owned storage. watchPaths is captured raw but is a no-op here
        // (FileChanged watching is deferred to a follow-up phase).
        if (objGet(hso, "updatedInput")) |v| out.updated_input = captureRaw(&result, allocator, v);
        if (objGet(hso, "updatedMCPToolOutput")) |v| out.updated_mcp_tool_output = captureRaw(&result, allocator, v);
        if (objGet(hso, "watchPaths")) |v| out.watch_paths = captureRaw(&result, allocator, v);
    }

    result.output = out;
    return result;
}

/// Task 12 (hooks-06): detect the first-line async sentinel a hook may print to
/// promote itself to background execution. A *synchronous* hook whose first
/// stdout line is `{"async":true,"asyncTimeout":N}` is transferred to the
/// background registry instead of being treated as a finished sync result
/// (reference: utils/hooks.ts:1117-1163). Returns the `asyncTimeout` (ms) when
/// the line declares `async:true`; null otherwise. `asyncTimeout` is optional in
/// the sentinel, so a bare `{"async":true}` returns 0 (use the per-type default
/// upstream). Only the FIRST line is inspected; everything after it is ignored.
pub fn detectAsyncFirstLine(line: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;
    // The sentinel is a flat JSON object. A non-object line is never a sentinel.
    if (trimmed[0] != '{') return null;
    // Bound the work: the sentinel is tiny.
    if (trimmed.len > 512) return null;

    // Require `"async": true`. Scanning the keys directly (rather than running a
    // full JSON parser that needs an allocator) keeps this allocation-free and
    // robust: the sentinel shape is fixed (utils/hooks.ts:1117-1163).
    if (!jsonBoolKeyIsTrue(trimmed, "async")) return null;

    // `asyncTimeout` is optional; absent -> 0 (caller applies the per-type
    // default). When present, read its non-negative integer value.
    return jsonUintKey(trimmed, "asyncTimeout") orelse 0;
}

/// True when `json` contains `"<key>": true` (whitespace-tolerant). A flat-object
/// scan, not a parser; adequate for the fixed async sentinel shape.
fn jsonBoolKeyIsTrue(json: []const u8, key: []const u8) bool {
    const v = jsonValueAfterKey(json, key) orelse return false;
    return std.mem.startsWith(u8, v, "true");
}

/// Parse the non-negative integer value of `"<key>": N` in a flat JSON object,
/// or null when the key is absent / not a non-negative integer.
fn jsonUintKey(json: []const u8, key: []const u8) ?u64 {
    const v = jsonValueAfterKey(json, key) orelse return null;
    var end: usize = 0;
    while (end < v.len and v[end] >= '0' and v[end] <= '9') : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseInt(u64, v[0..end], 10) catch null;
}

/// Return the slice of `json` starting at the value that follows `"<key>":`
/// (skipping the colon and any whitespace), or null when the key is not present.
fn jsonValueAfterKey(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    if (key.len + 2 > needle_buf.len) return null;
    needle_buf[0] = '"';
    @memcpy(needle_buf[1 .. 1 + key.len], key);
    needle_buf[1 + key.len] = '"';
    const needle = needle_buf[0 .. key.len + 2];

    const at = std.mem.indexOf(u8, json, needle) orelse return null;
    var idx = at + needle.len;
    // Skip whitespace, then the colon, then whitespace again.
    while (idx < json.len and (json[idx] == ' ' or json[idx] == '\t')) : (idx += 1) {}
    if (idx >= json.len or json[idx] != ':') return null;
    idx += 1;
    while (idx < json.len and (json[idx] == ' ' or json[idx] == '\t')) : (idx += 1) {}
    if (idx >= json.len) return null;
    return json[idx..];
}

const testing = std.testing;

test "buildToolEventPayload embeds object input as raw json" {
    const p = try buildToolEventPayload(testing.allocator, "PreToolUse", "Bash", "{\"command\":\"ls\"}", "/repo");
    defer testing.allocator.free(p);
    // round-trips as valid JSON with the command nested as an object
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, p, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("Bash", parsed.value.object.get("tool_name").?.string);
    try testing.expectEqualStrings("ls", parsed.value.object.get("tool_input").?.object.get("command").?.string);
}

test "buildToolEventPayload embeds non-json input as a string" {
    const p = try buildToolEventPayload(testing.allocator, "PreToolUse", "Bash", "ls -la", "/repo");
    defer testing.allocator.free(p);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, p, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("ls -la", parsed.value.object.get("tool_input").?.string);
}

test "buildToolEventPayloadFull PostToolUse embeds json tool_response as object" {
    const p = try buildToolEventPayloadFull(
        testing.allocator,
        "PostToolUse",
        "Write",
        "{\"file_path\":\"/a\"}",
        "/repo",
        "{\"success\":true,\"bytes\":42}",
        true,
        .{},
        .{},
    );
    defer testing.allocator.free(p);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, p, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("PostToolUse", parsed.value.object.get("hook_event_name").?.string);
    const resp = parsed.value.object.get("tool_response").?;
    try testing.expectEqual(true, resp.object.get("success").?.bool);
    try testing.expectEqual(@as(i64, 42), resp.object.get("bytes").?.integer);
    // tool_input survives alongside tool_response.
    try testing.expectEqualStrings("/a", parsed.value.object.get("tool_input").?.object.get("file_path").?.string);
}

test "buildToolEventPayloadFull PostToolUse embeds plain-string tool_response as a string" {
    const p = try buildToolEventPayloadFull(
        testing.allocator,
        "PostToolUse",
        "Bash",
        "ls -la",
        "/repo",
        "drwxr-xr-x  total 0",
        true,
        .{},
        .{},
    );
    defer testing.allocator.free(p);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, p, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("drwxr-xr-x  total 0", parsed.value.object.get("tool_response").?.string);
}

test "buildToolEventPayloadFull PostToolUseFailure embeds error and interrupt flags" {
    const p = try buildToolEventPayloadFull(
        testing.allocator,
        "PostToolUseFailure",
        "Bash",
        "false",
        "/repo",
        "command failed",
        false,
        .{},
        .{},
    );
    defer testing.allocator.free(p);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, p, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("PostToolUseFailure", parsed.value.object.get("hook_event_name").?.string);
    try testing.expectEqualStrings("command failed", parsed.value.object.get("tool_response").?.string);
    try testing.expectEqualStrings("command failed", parsed.value.object.get("error").?.string);
    try testing.expectEqual(false, parsed.value.object.get("is_interrupt").?.bool);
    try testing.expectEqual(false, parsed.value.object.get("is_timeout").?.bool);
}

test "buildToolEventPayloadFull PreToolUse with null response omits tool_response" {
    const p = try buildToolEventPayloadFull(
        testing.allocator,
        "PreToolUse",
        "Bash",
        "ls",
        "/repo",
        null,
        true,
        .{},
        .{},
    );
    defer testing.allocator.free(p);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, p, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("tool_response") == null);
    try testing.expect(parsed.value.object.get("error") == null);
}

test "buildToolEventPayload 5-arg form still omits tool_response" {
    // Backward-compat: the legacy 5-arg builder never emits a response field,
    // even for PostToolUse.
    const p = try buildToolEventPayload(testing.allocator, "PostToolUse", "Bash", "ls", "/repo");
    defer testing.allocator.free(p);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, p, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("tool_response") == null);
}

test "buildLifecycleEventPayload SessionStart includes source not tool_name" {
    const p = try buildLifecycleEventPayload(testing.allocator, "SessionStart", "/repo", .{ .source = "startup" }, .{});
    defer testing.allocator.free(p);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, p, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("SessionStart", parsed.value.object.get("hook_event_name").?.string);
    try testing.expectEqualStrings("startup", parsed.value.object.get("source").?.string);
    try testing.expectEqualStrings("/repo", parsed.value.object.get("cwd").?.string);
    // Fields not set for this event are absent (no tool_name, no prompt).
    try testing.expect(parsed.value.object.get("tool_name") == null);
    try testing.expect(parsed.value.object.get("prompt") == null);
}

test "hooks-permissions-09: buildToolEventPayloadFull emits base fields and tool_use_id/duration_ms when set" {
    const p = try buildToolEventPayloadFull(
        testing.allocator,
        "PostToolUse",
        "Bash",
        "{\"command\":\"ls\"}",
        "/repo",
        "ok",
        true,
        .{ .session_id = "sess-1", .transcript_path = "/repo/.zcode/sessions/sess-1.jsonl", .permission_mode = "acceptEdits", .agent_id = "agent-2", .prompt_id = "prompt-3" },
        .{ .tool_use_id = "tu-1", .duration_ms = 42 },
    );
    defer testing.allocator.free(p);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, p, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("sess-1", parsed.value.object.get("session_id").?.string);
    try testing.expectEqualStrings("/repo/.zcode/sessions/sess-1.jsonl", parsed.value.object.get("transcript_path").?.string);
    try testing.expectEqualStrings("acceptEdits", parsed.value.object.get("permission_mode").?.string);
    try testing.expectEqualStrings("agent-2", parsed.value.object.get("agent_id").?.string);
    try testing.expectEqualStrings("prompt-3", parsed.value.object.get("prompt_id").?.string);
    try testing.expectEqualStrings("tu-1", parsed.value.object.get("tool_use_id").?.string);
    try testing.expectEqual(@as(i64, 42), parsed.value.object.get("duration_ms").?.integer);
}

test "hooks-permissions-09: empty base/extra fields are omitted, not emitted blank" {
    const p = try buildToolEventPayloadFull(testing.allocator, "PreToolUse", "Bash", "ls", "/repo", null, true, .{}, .{});
    defer testing.allocator.free(p);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, p, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("session_id") == null);
    try testing.expect(parsed.value.object.get("transcript_path") == null);
    try testing.expect(parsed.value.object.get("permission_mode") == null);
    try testing.expect(parsed.value.object.get("agent_id") == null);
    try testing.expect(parsed.value.object.get("prompt_id") == null);
    try testing.expect(parsed.value.object.get("tool_use_id") == null);
    try testing.expect(parsed.value.object.get("reason") == null);
    try testing.expect(parsed.value.object.get("duration_ms") == null);
}

test "hooks-permissions-09: buildLifecycleEventPayload emits base fields alongside lifecycle fields" {
    const p = try buildLifecycleEventPayload(
        testing.allocator,
        "UserPromptSubmit",
        "/repo",
        .{ .prompt = "do the thing" },
        .{ .session_id = "sess-9", .permission_mode = "plan" },
    );
    defer testing.allocator.free(p);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, p, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("do the thing", parsed.value.object.get("prompt").?.string);
    try testing.expectEqualStrings("sess-9", parsed.value.object.get("session_id").?.string);
    try testing.expectEqualStrings("plan", parsed.value.object.get("permission_mode").?.string);
}

test "hooks-permissions-10: buildLifecycleEventPayload emits notification_type" {
    const p = try buildLifecycleEventPayload(
        testing.allocator,
        "Notification",
        "/repo",
        .{ .message = "idle for a while", .notification_type = "idle" },
        .{},
    );
    defer testing.allocator.free(p);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, p, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("idle for a while", parsed.value.object.get("message").?.string);
    try testing.expectEqualStrings("idle", parsed.value.object.get("notification_type").?.string);
}

test "hooks-permissions-04: buildPostToolBatchPayload embeds the tool_calls array and base fields" {
    const p = try buildPostToolBatchPayload(
        testing.allocator,
        "/repo",
        "[{\"tool_name\":\"Read\",\"tool_input\":{\"path\":\"a.txt\"},\"tool_use_id\":\"\"},{\"tool_name\":\"Glob\",\"tool_input\":{\"pattern\":\"*.zig\"},\"tool_use_id\":\"\"}]",
        .{ .session_id = "sess-batch" },
    );
    defer testing.allocator.free(p);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, p, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("PostToolBatch", parsed.value.object.get("hook_event_name").?.string);
    try testing.expectEqualStrings("/repo", parsed.value.object.get("cwd").?.string);
    try testing.expectEqualStrings("sess-batch", parsed.value.object.get("session_id").?.string);
    const calls = parsed.value.object.get("tool_calls").?.array;
    try testing.expectEqual(@as(usize, 2), calls.items.len);
    try testing.expectEqualStrings("Read", calls.items[0].object.get("tool_name").?.string);
    try testing.expectEqualStrings("Glob", calls.items[1].object.get("tool_name").?.string);
}

test "hooks-permissions-04: buildPostToolBatchPayload falls back to an empty array for invalid input" {
    const p = try buildPostToolBatchPayload(testing.allocator, "/repo", "not valid json", .{});
    defer testing.allocator.free(p);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, p, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.value.object.get("tool_calls").?.array.items.len);
}

test "buildLifecycleEventPayload UserPromptSubmit emits prompt only" {
    const p = try buildLifecycleEventPayload(testing.allocator, "UserPromptSubmit", "/repo", .{ .prompt = "do the thing" }, .{});
    defer testing.allocator.free(p);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, p, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("UserPromptSubmit", parsed.value.object.get("hook_event_name").?.string);
    try testing.expectEqualStrings("do the thing", parsed.value.object.get("prompt").?.string);
    try testing.expect(parsed.value.object.get("source") == null);
}

test "parseOutput tolerates empty and invalid" {
    var r1 = parseOutput(testing.allocator, "");
    defer r1.deinit();
    try testing.expectEqual(PermissionDecision.none, r1.output.permission_decision);

    var r2 = parseOutput(testing.allocator, "not json{");
    defer r2.deinit();
    try testing.expectEqual(PermissionDecision.none, r2.output.permission_decision);
    try testing.expect(r2.output.additional_context == null);
}

test "parseOutput reads hookSpecificOutput permissionDecision and context" {
    const json =
        \\{"hookSpecificOutput":{"permissionDecision":"deny","additionalContext":"blocked by policy"}}
    ;
    var r = parseOutput(testing.allocator, json);
    defer r.deinit();
    try testing.expectEqual(PermissionDecision.deny, r.output.permission_decision);
    try testing.expectEqualStrings("blocked by policy", r.output.additional_context.?);
}

test "parseOutput reads top-level decision/continue" {
    const json =
        \\{"decision":"block","reason":"stop here","continue":false}
    ;
    var r = parseOutput(testing.allocator, json);
    defer r.deinit();
    try testing.expectEqualStrings("block", r.output.decision.?);
    try testing.expectEqualStrings("stop here", r.output.reason.?);
    try testing.expectEqual(@as(?bool, false), r.output.continue_run);
}

test "parseOutput reads stopReason and systemMessage" {
    const json =
        \\{"continue":false,"stopReason":"halt now","systemMessage":"hook says hi","suppressOutput":true}
    ;
    var r = parseOutput(testing.allocator, json);
    defer r.deinit();
    try testing.expectEqual(@as(?bool, false), r.output.continue_run);
    try testing.expectEqualStrings("halt now", r.output.stop_reason.?);
    try testing.expectEqualStrings("hook says hi", r.output.system_message.?);
    try testing.expectEqual(@as(?bool, true), r.output.suppress_output);
}

test "parseOutput reads hookSpecificOutput permissionDecisionReason and retry" {
    const json =
        \\{"hookSpecificOutput":{"permissionDecision":"ask","permissionDecisionReason":"needs review","retry":true}}
    ;
    var r = parseOutput(testing.allocator, json);
    defer r.deinit();
    try testing.expectEqual(PermissionDecision.ask, r.output.permission_decision);
    try testing.expectEqualStrings("needs review", r.output.permission_decision_reason.?);
    try testing.expectEqual(@as(?bool, true), r.output.retry);
}

test "parseOutput re-serializes updatedInput and updatedMCPToolOutput objects" {
    const json =
        \\{"hookSpecificOutput":{"updatedInput":{"command":"ls -la"},"updatedMCPToolOutput":{"ok":true}}}
    ;
    var r = parseOutput(testing.allocator, json);
    defer r.deinit();
    // The re-serialized slices stay valid after parse and round-trip as JSON.
    var ui = try std.json.parseFromSlice(std.json.Value, testing.allocator, r.output.updated_input.?, .{});
    defer ui.deinit();
    try testing.expectEqualStrings("ls -la", ui.value.object.get("command").?.string);
    var mo = try std.json.parseFromSlice(std.json.Value, testing.allocator, r.output.updated_mcp_tool_output.?, .{});
    defer mo.deinit();
    try testing.expectEqual(true, mo.value.object.get("ok").?.bool);
}

test "parseOutput captures watchPaths raw but it stays a no-op slice" {
    const json =
        \\{"hookSpecificOutput":{"watchPaths":["a.txt","b.txt"]}}
    ;
    var r = parseOutput(testing.allocator, json);
    defer r.deinit();
    // watch_paths is captured (deferral) but the runtime does not act on it yet.
    try testing.expect(r.output.watch_paths != null);
    try testing.expect(std.mem.indexOf(u8, r.output.watch_paths.?, "a.txt") != null);
}

test "detectAsyncFirstLine returns asyncTimeout for an async sentinel" {
    try testing.expectEqual(@as(?u64, 5000), detectAsyncFirstLine("{\"async\":true,\"asyncTimeout\":5000}"));
    // A bare async:true (no timeout) returns 0 so the caller applies its default.
    try testing.expectEqual(@as(?u64, 0), detectAsyncFirstLine("{\"async\":true}"));
    // Leading/trailing whitespace is tolerated.
    try testing.expectEqual(@as(?u64, 250), detectAsyncFirstLine("  {\"async\":true,\"asyncTimeout\":250}  \n"));
}

test "hooks-permissions-03: buildLifecycleEventPayload emits CwdChanged old_cwd/new_cwd" {
    const p = try buildLifecycleEventPayload(
        testing.allocator,
        "CwdChanged",
        "/repo/sub",
        .{ .old_cwd = "/repo" },
        .{},
    );
    defer testing.allocator.free(p);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, p, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("/repo", parsed.value.object.get("old_cwd").?.string);
    // The "new" cwd is the event's own top-level `cwd`, not a duplicated field.
    try testing.expectEqualStrings("/repo/sub", parsed.value.object.get("cwd").?.string);
}

test "hooks-permissions-03: buildLifecycleEventPayload emits FileChanged file_path and event kind" {
    const p = try buildLifecycleEventPayload(
        testing.allocator,
        "FileChanged",
        "/repo",
        .{ .file_path = "/repo/a.zig", .change_event = "add" },
        .{},
    );
    defer testing.allocator.free(p);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, p, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("/repo/a.zig", parsed.value.object.get("file_path").?.string);
    try testing.expectEqualStrings("add", parsed.value.object.get("event").?.string);
}

test "hooks-permissions-03: buildLifecycleEventPayload emits InstructionsLoaded fields" {
    const p = try buildLifecycleEventPayload(
        testing.allocator,
        "InstructionsLoaded",
        "/repo",
        .{ .file_path = "/repo/ZCODE.md", .memory_type = "Project", .load_reason = "session_start" },
        .{},
    );
    defer testing.allocator.free(p);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, p, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("/repo/ZCODE.md", parsed.value.object.get("file_path").?.string);
    try testing.expectEqualStrings("Project", parsed.value.object.get("memory_type").?.string);
    try testing.expectEqualStrings("session_start", parsed.value.object.get("load_reason").?.string);
}

test "hooks-permissions-03: buildLifecycleEventPayload emits TeammateIdle teammate_name/team_name" {
    const p = try buildLifecycleEventPayload(
        testing.allocator,
        "TeammateIdle",
        "/repo",
        .{ .teammate_name = "worker", .team_name = "alpha" },
        .{},
    );
    defer testing.allocator.free(p);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, p, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("worker", parsed.value.object.get("teammate_name").?.string);
    try testing.expectEqualStrings("alpha", parsed.value.object.get("team_name").?.string);
}

test "hooks-permissions-03: buildLifecycleEventPayload emits WorktreeCreate name and WorktreeRemove worktree_path" {
    const create = try buildLifecycleEventPayload(testing.allocator, "WorktreeCreate", "/repo", .{ .worktree_name = "feature-x" }, .{});
    defer testing.allocator.free(create);
    var parsed_create = try std.json.parseFromSlice(std.json.Value, testing.allocator, create, .{});
    defer parsed_create.deinit();
    try testing.expectEqualStrings("feature-x", parsed_create.value.object.get("name").?.string);

    const remove = try buildLifecycleEventPayload(testing.allocator, "WorktreeRemove", "/repo", .{ .worktree_path = "/repo/../feature-x" }, .{});
    defer testing.allocator.free(remove);
    var parsed_remove = try std.json.parseFromSlice(std.json.Value, testing.allocator, remove, .{});
    defer parsed_remove.deinit();
    try testing.expectEqualStrings("/repo/../feature-x", parsed_remove.value.object.get("worktree_path").?.string);
}

test "hooks-permissions-03: buildLifecycleEventPayload emits ConfigChange source and optional file_path" {
    const p = try buildLifecycleEventPayload(
        testing.allocator,
        "ConfigChange",
        "/repo",
        .{ .source = "skills" },
        .{},
    );
    defer testing.allocator.free(p);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, p, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("skills", parsed.value.object.get("source").?.string);
    try testing.expect(parsed.value.object.get("file_path") == null);
}

test "hooks-permissions-02 (corrected): buildLifecycleEventPayload emits StopFailure error fields" {
    const p = try buildLifecycleEventPayload(
        testing.allocator,
        "StopFailure",
        "/repo",
        .{ .@"error" = "RateLimited", .error_details = "Rate limited by the API provider.", .last_assistant_message = "Here is the plan..." },
        .{},
    );
    defer testing.allocator.free(p);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, p, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("RateLimited", parsed.value.object.get("error").?.string);
    try testing.expectEqualStrings("Rate limited by the API provider.", parsed.value.object.get("error_details").?.string);
    try testing.expectEqualStrings("Here is the plan...", parsed.value.object.get("last_assistant_message").?.string);
}

test "detectAsyncFirstLine returns null for a non-async line" {
    try testing.expectEqual(@as(?u64, null), detectAsyncFirstLine("{}"));
    try testing.expectEqual(@as(?u64, null), detectAsyncFirstLine("hello world"));
    try testing.expectEqual(@as(?u64, null), detectAsyncFirstLine(""));
    // async:false is an explicit opt-out, not a sentinel.
    try testing.expectEqual(@as(?u64, null), detectAsyncFirstLine("{\"async\":false}"));
    // A regular contract object that does not declare async is not a sentinel.
    try testing.expectEqual(@as(?u64, null), detectAsyncFirstLine("{\"decision\":\"block\"}"));
}
