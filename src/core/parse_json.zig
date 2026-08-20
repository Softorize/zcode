const std = @import("std");
const helpers = @import("parse_helpers.zig");
const json_normalize = @import("json_normalize.zig");

const ToolCall = helpers.ToolCall;
const ControlActions = helpers.ControlActions;
const ParsedOutput = helpers.ParsedOutput;

const parseJsonLenient = json_normalize.parseJsonLenient;
const decodeEscapedText = helpers.decodeEscapedText;
const extractFencedJson = helpers.extractFencedJson;
const findMatchingBrace = helpers.findMatchingBrace;
const appendToolCall = helpers.appendToolCall;
const appendToolCallsFromValue = helpers.appendToolCallsFromValue;
const getBool = helpers.getBool;
const startsWithIgnoreCase = helpers.startsWithIgnoreCase;

pub fn parseNativeToolCallsJson(allocator: std.mem.Allocator, json: []const u8) !?[]ToolCall {
    // Bounded parse: this JSON is the `tool_calls` array from a
    // provider response. A hostile / compromised provider (or a
    // misconfigured base_url pointed at attacker-controlled
    // infrastructure -- pass 73's egress chokepoint blocks plaintext
    // exfiltration but not a malicious-but-HTTPS upstream) could
    // ship a 50 MB string literal or deeply-nested arrays designed
    // to exhaust parser memory or stack. parseJsonBounded pins
    // 1 MiB per string/array/object, well past anything legitimate
    // for a tool-call envelope.
    var parsed = helpers.parseJsonBounded(std.json.Value, allocator, json) catch return null;
    defer parsed.deinit();

    if (parsed.value != .array) return null;
    if (parsed.value.array.items.len == 0) return null;

    var out = std.array_list.Managed(ToolCall).init(allocator);
    errdefer {
        for (out.items) |tc| {
            allocator.free(tc.name);
            allocator.free(tc.args);
        }
        out.deinit();
    }

    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const name_val = item.object.get("name") orelse continue;
        if (name_val != .string or name_val.string.len == 0) continue;

        const args_val = item.object.get("args") orelse continue;

        // Native tool call args come as a JSON string (e.g. '{"command":"ls"}').
        // Parse the JSON and convert to key=value format that tool dispatch expects.
        const args_kv = if (args_val == .string) blk: {
            break :blk helpers.parseArgumentsField(allocator, args_val) catch
                try allocator.dupe(u8, args_val.string);
        } else try allocator.dupe(u8, "");
        errdefer allocator.free(args_kv);

        try out.ensureUnusedCapacity(1);
        const dup_name = try allocator.dupe(u8, name_val.string);
        out.appendAssumeCapacity(.{
            .name = dup_name,
            .args = args_kv,
        });
    }

    if (out.items.len == 0) return null;
    return try out.toOwnedSlice();
}

pub fn parseCandidateJson(allocator: std.mem.Allocator, candidate: []const u8, fallback_text: []const u8) !?ParsedOutput {
    var parsed_json = (try parseJsonLenient(allocator, candidate)) orelse return null;
    defer parsed_json.deinit(allocator);

    if (parsed_json.value.value != .object) return null;

    const obj = parsed_json.value.value.object;
    if (!hasProtocolSignalKeys(obj)) {
        if (try extractProviderErrorText(allocator, obj)) |msg| {
            return .{
                .assistant_text = msg,
                .tool_calls = try allocator.alloc(ToolCall, 0),
                .control = .{},
            };
        }
        return null;
    }

    const assistant_text = getAssistantText(allocator, obj) catch try allocator.dupe(u8, fallback_text);
    const tool_calls = parseToolCalls(allocator, obj) catch try allocator.alloc(ToolCall, 0);
    const control = parseControl(obj);

    return .{
        .assistant_text = assistant_text,
        .tool_calls = tool_calls,
        .control = control,
    };
}

pub fn parseBareToolCallPayload(allocator: std.mem.Allocator, text: []const u8) !?ParsedOutput {
    var tool_calls = std.array_list.Managed(ToolCall).init(allocator);
    errdefer {
        for (tool_calls.items) |call| {
            allocator.free(call.name);
            allocator.free(call.args);
        }
        tool_calls.deinit();
    }

    if (!try appendToolCallsFromJsonText(allocator, &tool_calls, text)) {
        return null;
    }

    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const assistant_text = if (looksLikePureToolPayload(trimmed))
        try allocator.dupe(u8, "")
    else
        try decodeEscapedText(allocator, trimmed);

    return .{
        .assistant_text = assistant_text,
        .tool_calls = try tool_calls.toOwnedSlice(),
        .control = .{},
    };
}

pub fn appendToolCallsFromJsonText(allocator: std.mem.Allocator, out: *std.array_list.Managed(ToolCall), text: []const u8) !bool {
    if (try appendToolCallsFromJsonCandidate(allocator, out, text)) {
        return true;
    }

    if (extractFencedJson(allocator, text)) |candidate| {
        defer allocator.free(candidate);
        if (try appendToolCallsFromJsonCandidate(allocator, out, candidate)) {
            return true;
        }
    }

    if (try appendToolCallsFromLooseJsonObjects(allocator, out, text)) {
        return true;
    }

    return false;
}

fn appendToolCallsFromJsonCandidate(allocator: std.mem.Allocator, out: *std.array_list.Managed(ToolCall), candidate: []const u8) !bool {
    var parsed = (try parseJsonLenient(allocator, candidate)) orelse return false;
    defer parsed.deinit(allocator);

    const before_count = out.items.len;
    _ = try appendToolCallsFromValue(allocator, out, parsed.value.value);
    return out.items.len > before_count;
}

fn appendToolCallsFromLooseJsonObjects(allocator: std.mem.Allocator, out: *std.array_list.Managed(ToolCall), text: []const u8) !bool {
    var cursor: usize = 0;
    var appended_any = false;

    while (cursor < text.len) {
        const open_rel = std.mem.indexOfScalar(u8, text[cursor..], '{') orelse break;
        const open_idx = cursor + open_rel;
        const close_idx = findMatchingBrace(text, open_idx) orelse {
            cursor = open_idx + 1;
            continue;
        };

        const candidate = std.mem.trim(u8, text[open_idx .. close_idx + 1], " \t\r\n");
        var parsed = (try parseJsonLenient(allocator, candidate)) orelse {
            cursor = open_idx + 1;
            continue;
        };
        defer parsed.deinit(allocator);

        if (parsed.value.value == .object) {
            const before = out.items.len;
            try appendToolCall(allocator, out, parsed.value.value.object);
            if (out.items.len > before) appended_any = true;
        }

        cursor = close_idx + 1;
    }

    return appended_any;
}

pub fn hasProtocolSignalKeys(obj: std.json.ObjectMap) bool {
    return obj.get("assistant") != null or
        obj.get("text") != null or
        obj.get("tool_calls") != null or
        obj.get("control") != null;
}

pub fn extractProviderErrorText(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !?[]u8 {
    const err_val = obj.get("error") orelse return null;
    switch (err_val) {
        .string => |msg| {
            if (msg.len == 0) return null;
            return try std.fmt.allocPrint(allocator, "provider error: {s}", .{msg});
        },
        .object => |err_obj| {
            if (err_obj.get("message")) |message| {
                if (message == .string and message.string.len > 0) {
                    return try std.fmt.allocPrint(allocator, "provider error: {s}", .{message.string});
                }
            }
            if (err_obj.get("type")) |typ| {
                if (typ == .string and typ.string.len > 0) {
                    return try std.fmt.allocPrint(allocator, "provider error: {s}", .{typ.string});
                }
            }
            return null;
        },
        else => return null,
    }
}

fn getAssistantText(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]u8 {
    if (obj.get("assistant")) |v| {
        if (v == .string) return decodeEscapedText(allocator, v.string);
    }
    if (obj.get("text")) |v| {
        if (v == .string) return decodeEscapedText(allocator, v.string);
    }
    return allocator.dupe(u8, "");
}

pub fn parseToolCalls(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]ToolCall {
    const tc = obj.get("tool_calls") orelse return allocator.alloc(ToolCall, 0);

    var out = std.array_list.Managed(ToolCall).init(allocator);
    defer out.deinit();

    if (tc == .array) {
        for (tc.array.items) |item| {
            if (item != .object) continue;
            try appendToolCall(allocator, &out, item.object);
        }
    } else if (tc == .object) {
        try appendToolCall(allocator, &out, tc.object);
    }

    return out.toOwnedSlice();
}

pub fn parseControl(obj: std.json.ObjectMap) ControlActions {
    const control_obj = obj.get("control") orelse return .{};
    if (control_obj == .string) return parseControlString(control_obj.string);
    if (control_obj != .object) return .{};

    return .{
        .compact = getBool(control_obj.object, "compact"),
        .resume_requested = getBool(control_obj.object, "resume") or getBool(control_obj.object, "resume_requested"),
        .escalate = getBool(control_obj.object, "escalate"),
        .continue_requested = getBool(control_obj.object, "continue"),
    };
}

fn parseControlString(control_text: []const u8) ControlActions {
    var actions = ControlActions{};
    var tokens = std.mem.tokenizeAny(u8, control_text, ",;| \t\r\n");
    while (tokens.next()) |token| {
        if (std.ascii.eqlIgnoreCase(token, "compact")) {
            actions.compact = true;
        } else if (std.ascii.eqlIgnoreCase(token, "resume")) {
            actions.resume_requested = true;
        } else if (std.ascii.eqlIgnoreCase(token, "escalate")) {
            actions.escalate = true;
        } else if (std.ascii.eqlIgnoreCase(token, "continue")) {
            actions.continue_requested = true;
        }
    }
    return actions;
}

pub fn looksLikePureToolPayload(trimmed: []const u8) bool {
    if (trimmed.len == 0) return false;
    if (trimmed[0] == '[' or trimmed[0] == '{') return true;
    if (startsWithIgnoreCase(trimmed, "<tool_calls")) return true;
    if (startsWithIgnoreCase(trimmed, "<parameter")) return true;
    if (startsWithIgnoreCase(trimmed, "[tool_call]")) return true;
    return false;
}

const testing = std.testing;
test "hasProtocolSignalKeys detects keys" {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"assistant\":\"hi\"}", .{});
    defer parsed.deinit();
    try testing.expect(hasProtocolSignalKeys(parsed.value.object));
}
test "hasProtocolSignalKeys rejects unrelated object" {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"error\":\"boom\",\"code\":42}", .{});
    defer parsed.deinit();
    try testing.expect(!hasProtocolSignalKeys(parsed.value.object));
}
test "looksLikePureToolPayload identifies payloads" {
    try testing.expect(looksLikePureToolPayload("{\"name\":\"r\"}"));
    try testing.expect(looksLikePureToolPayload("[{\"name\":\"r\"}]"));
    try testing.expect(looksLikePureToolPayload("<tool_calls>"));
    try testing.expect(looksLikePureToolPayload("<TOOL_CALLS>"));
    try testing.expect(looksLikePureToolPayload("[tool_call]Read"));
    try testing.expect(!looksLikePureToolPayload(""));
    try testing.expect(!looksLikePureToolPayload("plain assistant text"));
}

test "parseControl reads every supported boolean key from object form" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"control\":{\"compact\":true,\"resume\":true,\"escalate\":true,\"continue\":true}}",
        .{},
    );
    defer parsed.deinit();
    const ctrl = parseControl(parsed.value.object);
    try testing.expect(ctrl.compact);
    try testing.expect(ctrl.resume_requested);
    try testing.expect(ctrl.escalate);
    try testing.expect(ctrl.continue_requested);
}

test "parseControl accepts resume_requested as an alias of resume" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"control\":{\"resume_requested\":true}}",
        .{},
    );
    defer parsed.deinit();
    const ctrl = parseControl(parsed.value.object);
    try testing.expect(ctrl.resume_requested);
    try testing.expect(!ctrl.compact);
    try testing.expect(!ctrl.escalate);
    try testing.expect(!ctrl.continue_requested);
}

test "parseControl returns empty when control is absent" {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"assistant\":\"hi\"}", .{});
    defer parsed.deinit();
    const ctrl = parseControl(parsed.value.object);
    try testing.expect(!ctrl.compact);
    try testing.expect(!ctrl.resume_requested);
    try testing.expect(!ctrl.escalate);
    try testing.expect(!ctrl.continue_requested);
}

test "parseControl accepts string form with mixed case and delimiters" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"control\":\"Continue, ESCALATE | compact\"}",
        .{},
    );
    defer parsed.deinit();
    const ctrl = parseControl(parsed.value.object);
    try testing.expect(ctrl.continue_requested);
    try testing.expect(ctrl.escalate);
    try testing.expect(ctrl.compact);
    try testing.expect(!ctrl.resume_requested);
}

test "parseControl ignores unrecognised tokens in string form" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"control\":\"continue abort nuke\"}",
        .{},
    );
    defer parsed.deinit();
    const ctrl = parseControl(parsed.value.object);
    try testing.expect(ctrl.continue_requested);
    try testing.expect(!ctrl.compact);
    try testing.expect(!ctrl.escalate);
}

test "parseCandidateJson returns null on non-envelope JSON array" {
    const res = try parseCandidateJson(testing.allocator, "[1,2,3]", "raw");
    try testing.expect(res == null);
}

test "parseCandidateJson returns null on malformed JSON" {
    const res = try parseCandidateJson(testing.allocator, "{not json", "raw");
    try testing.expect(res == null);
}

test "parseNativeToolCallsJson returns null on non-array input" {
    const res = try parseNativeToolCallsJson(testing.allocator, "{\"name\":\"Bash\"}");
    try testing.expect(res == null);
}

test "parseNativeToolCallsJson reads a single-element array" {
    // `args` arrives as a JSON-encoded string, not a raw object --
    // this matches what every provider returns for native
    // function-call payloads.
    const payload = "[{\"name\":\"Bash\",\"args\":\"{\\\"command\\\":\\\"ls\\\"}\"}]";
    const res = try parseNativeToolCallsJson(testing.allocator, payload);
    try testing.expect(res != null);
    defer {
        for (res.?) |c| {
            testing.allocator.free(c.name);
            testing.allocator.free(c.args);
        }
        testing.allocator.free(res.?);
    }
    try testing.expectEqual(@as(usize, 1), res.?.len);
    try testing.expectEqualStrings("Bash", res.?[0].name);
    try testing.expect(std.mem.indexOf(u8, res.?[0].args, "command") != null);
}
