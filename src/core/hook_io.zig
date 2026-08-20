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

/// Build the stdin JSON for a tool event. `tool_input_raw` is embedded as a JSON
/// value when it is itself valid JSON, otherwise as a JSON string.
///
/// Backward-compatible 5-arg form: emits only `tool_input` (no `tool_response`).
/// Use `buildToolEventPayloadFull` to also embed the PostToolUse response.
pub fn buildToolEventPayload(
    allocator: std.mem.Allocator,
    event_name: []const u8,
    tool_name: []const u8,
    tool_input_raw: []const u8,
    cwd: []const u8,
) ![]u8 {
    return buildToolEventPayloadFull(allocator, event_name, tool_name, tool_input_raw, cwd, null, true);
}

/// Build the stdin JSON for a tool event, optionally embedding the tool response.
/// When `tool_response` is non-null (PostToolUse / PostToolUseFailure), it is
/// embedded as `"tool_response"` - as a nested JSON value when it is itself valid
/// JSON, otherwise as a JSON string (same raw-vs-string rule as `tool_input`).
/// For PostToolUseFailure the response doubles as the `"error"` field and
/// `"is_interrupt"`/`"is_timeout"` flags are emitted (`success == false` implies
/// the call failed; interrupt/timeout are not separately tracked here so both
/// default to false).
pub fn buildToolEventPayloadFull(
    allocator: std.mem.Allocator,
    event_name: []const u8,
    tool_name: []const u8,
    tool_input_raw: []const u8,
    cwd: []const u8,
    tool_response: ?[]const u8,
    success: bool,
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
};

/// Build the stdin JSON for a non-tool lifecycle event (SessionStart,
/// UserPromptSubmit, Stop, SessionEnd, PreCompact, Notification, ...). Always
/// includes `hook_event_name` and `cwd`; emits only the `fields` that are set.
/// String values are JSON-escaped via `std.json.fmt`, matching the tool builder.
pub fn buildLifecycleEventPayload(
    allocator: std.mem.Allocator,
    event_name: []const u8,
    cwd: []const u8,
    fields: LifecycleFields,
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
    try w.writeAll("}");
    return allocator.dupe(u8, builder.items());
}

fn isValidJson(allocator: std.mem.Allocator, bytes: []const u8) bool {
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
    const p = try buildLifecycleEventPayload(testing.allocator, "SessionStart", "/repo", .{ .source = "startup" });
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

test "buildLifecycleEventPayload UserPromptSubmit emits prompt only" {
    const p = try buildLifecycleEventPayload(testing.allocator, "UserPromptSubmit", "/repo", .{ .prompt = "do the thing" });
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

test "detectAsyncFirstLine returns null for a non-async line" {
    try testing.expectEqual(@as(?u64, null), detectAsyncFirstLine("{}"));
    try testing.expectEqual(@as(?u64, null), detectAsyncFirstLine("hello world"));
    try testing.expectEqual(@as(?u64, null), detectAsyncFirstLine(""));
    // async:false is an explicit opt-out, not a sentinel.
    try testing.expectEqual(@as(?u64, null), detectAsyncFirstLine("{\"async\":false}"));
    // A regular contract object that does not declare async is not a sentinel.
    try testing.expectEqual(@as(?u64, null), detectAsyncFirstLine("{\"decision\":\"block\"}"));
}
