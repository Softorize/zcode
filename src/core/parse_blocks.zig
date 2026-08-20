const std = @import("std");
const std_io = @import("std_io.zig");
const helpers = @import("parse_helpers.zig");
const parse_json = @import("parse_json.zig");
const parse_xml = @import("parse_xml.zig");

const ToolCall = helpers.ToolCall;
const ParsedOutput = helpers.ParsedOutput;

const indexOfIgnoreCase = helpers.indexOfIgnoreCase;
const startsWithIgnoreCase = helpers.startsWithIgnoreCase;
const decodeEscapedText = helpers.decodeEscapedText;
const appendToolCallsFromValue = helpers.appendToolCallsFromValue;

const appendToolCallsFromJsonText = parse_json.appendToolCallsFromJsonText;
const appendToolCallsFromInvokeTags = parse_xml.appendToolCallsFromInvokeTags;

pub fn parseTaggedToolCallBlocks(allocator: std.mem.Allocator, text: []const u8) !?ParsedOutput {
    const open_tag = "[tool_call]";
    const close_tag = "[/tool_call]";

    var tool_calls = std.array_list.Managed(ToolCall).init(allocator);
    errdefer {
        for (tool_calls.items) |call| {
            allocator.free(call.name);
            allocator.free(call.args);
        }
        tool_calls.deinit();
    }

    var assistant_buf = std_io.StringBuilder.init(allocator);
    defer assistant_buf.deinit();

    var cursor: usize = 0;
    var found_any = false;
    while (indexOfIgnoreCase(text[cursor..], open_tag)) |open_rel| {
        const open_idx = cursor + open_rel;
        found_any = true;

        if (open_idx > cursor) {
            try assistant_buf.appendSlice(text[cursor..open_idx]);
        }

        const body_start = open_idx + open_tag.len;
        const close_rel = indexOfIgnoreCase(text[body_start..], close_tag) orelse {
            // Malformed tag block: ignore this parsing mode and keep raw text behavior.
            return null;
        };
        const body_end = body_start + close_rel;
        const body = std.mem.trim(u8, text[body_start..body_end], " \t\r\n");
        if (body.len > 0) {
            try appendTaggedToolCallBody(allocator, &tool_calls, body);
        }

        cursor = body_end + close_tag.len;
    }

    if (!found_any) return null;

    if (cursor < text.len) {
        try assistant_buf.appendSlice(text[cursor..]);
    }

    const assistant_trimmed = std.mem.trim(u8, assistant_buf.items(), " \t\r\n");
    if (tool_calls.items.len == 0 and assistant_trimmed.len == 0) {
        return null;
    }

    return .{
        .assistant_text = try decodeEscapedText(allocator, assistant_trimmed),
        .tool_calls = try tool_calls.toOwnedSlice(),
        .control = .{},
    };
}

fn appendTaggedToolCallBody(allocator: std.mem.Allocator, tool_calls: *std.array_list.Managed(ToolCall), body: []const u8) !void {
    const before = tool_calls.items.len;
    // Bounded parse on the [tool_call]...[/tool_call] body. This
    // text is model-controlled; a hostile model could embed a giant
    // string literal or deeply-nested structure to exhaust memory
    // or blow the parser stack. parseJsonBounded caps each value at
    // 1 MiB, which is well past anything legitimate for a single
    // tool-call envelope.
    var parsed = helpers.parseJsonBounded(std.json.Value, allocator, body) catch {
        _ = try appendToolCallsFromJsonText(allocator, tool_calls, body);
        if (tool_calls.items.len > before) return;
        _ = try appendToolCallsFromInvokeTags(allocator, tool_calls, body);
        return;
    };
    defer parsed.deinit();

    _ = try appendToolCallsFromValue(allocator, tool_calls, parsed.value);
    if (tool_calls.items.len > before) return;
    _ = try appendToolCallsFromJsonText(allocator, tool_calls, body);
    if (tool_calls.items.len > before) return;
    _ = try appendToolCallsFromInvokeTags(allocator, tool_calls, body);
}

pub fn parseToolCallsEnvelopeBlocks(allocator: std.mem.Allocator, text: []const u8) !?ParsedOutput {
    const open_tag = "<tool_calls";
    const close_tag = "</tool_calls>";

    var tool_calls = std.array_list.Managed(ToolCall).init(allocator);
    errdefer {
        for (tool_calls.items) |call| {
            allocator.free(call.name);
            allocator.free(call.args);
        }
        tool_calls.deinit();
    }

    var assistant_buf = std_io.StringBuilder.init(allocator);
    defer assistant_buf.deinit();

    var cursor: usize = 0;
    var found_wrapper = false;
    var found_any_tool = false;

    while (indexOfIgnoreCase(text[cursor..], open_tag)) |open_rel| {
        const open_idx = cursor + open_rel;
        found_wrapper = true;
        if (open_idx > cursor) {
            try assistant_buf.appendSlice(text[cursor..open_idx]);
        }

        const open_end_rel = std.mem.indexOfScalar(u8, text[open_idx..], '>') orelse {
            // Malformed wrapper: preserve as assistant text and stop envelope parsing.
            try assistant_buf.appendSlice(text[open_idx..]);
            cursor = text.len;
            break;
        };
        const body_start = open_idx + open_end_rel + 1;
        const close_rel = indexOfIgnoreCase(text[body_start..], close_tag) orelse {
            // Unterminated wrapper: preserve as assistant text and stop envelope parsing.
            try assistant_buf.appendSlice(text[open_idx..]);
            cursor = text.len;
            break;
        };
        const body_end = body_start + close_rel;
        const body = std.mem.trim(u8, text[body_start..body_end], " \t\r\n");

        var parsed_tools = false;
        if (body.len > 0) {
            if (try appendToolCallsFromJsonText(allocator, &tool_calls, body)) {
                parsed_tools = true;
            } else if (try appendToolCallsFromInvokeTags(allocator, &tool_calls, body)) {
                parsed_tools = true;
            }
        }

        if (parsed_tools) {
            found_any_tool = true;
        } else {
            // Not parseable as tool payload: keep original wrapper block in assistant output.
            try assistant_buf.appendSlice(text[open_idx .. body_end + close_tag.len]);
        }

        cursor = body_end + close_tag.len;
    }

    if (!found_wrapper or !found_any_tool) return null;
    if (cursor < text.len) {
        try assistant_buf.appendSlice(text[cursor..]);
    }

    const assistant_trimmed = std.mem.trim(u8, assistant_buf.items(), " \t\r\n");
    return .{
        .assistant_text = try decodeEscapedText(allocator, assistant_trimmed),
        .tool_calls = try tool_calls.toOwnedSlice(),
        .control = .{},
    };
}

pub fn parseParameterToolCallsBlocks(allocator: std.mem.Allocator, text: []const u8) !?ParsedOutput {
    const open_tag = "<parameter";
    const close_tag = "</parameter>";

    var tool_calls = std.array_list.Managed(ToolCall).init(allocator);
    errdefer {
        for (tool_calls.items) |call| {
            allocator.free(call.name);
            allocator.free(call.args);
        }
        tool_calls.deinit();
    }

    var assistant_buf = std_io.StringBuilder.init(allocator);
    defer assistant_buf.deinit();

    var cursor: usize = 0;
    var found_wrapper = false;
    var found_any_tool = false;

    while (indexOfIgnoreCase(text[cursor..], open_tag)) |open_rel| {
        const open_idx = cursor + open_rel;
        if (open_idx > cursor) {
            try assistant_buf.appendSlice(text[cursor..open_idx]);
        }

        const open_end_rel = std.mem.indexOfScalar(u8, text[open_idx..], '>') orelse {
            try assistant_buf.appendSlice(text[open_idx..]);
            cursor = text.len;
            break;
        };
        const open_end = open_idx + open_end_rel;
        const raw_open = text[open_idx .. open_end + 1];

        if (!parameterTagTargetsToolCalls(raw_open)) {
            try assistant_buf.appendSlice(raw_open);
            cursor = open_end + 1;
            continue;
        }

        found_wrapper = true;
        const body_start = open_end + 1;
        const close_rel = indexOfIgnoreCase(text[body_start..], close_tag) orelse {
            try assistant_buf.appendSlice(text[open_idx..]);
            cursor = text.len;
            break;
        };
        const body_end = body_start + close_rel;
        const body = std.mem.trim(u8, text[body_start..body_end], " \t\r\n");

        var parsed_tools = false;
        if (body.len > 0) {
            if (try appendToolCallsFromJsonText(allocator, &tool_calls, body)) {
                parsed_tools = true;
            } else if (try appendToolCallsFromInvokeTags(allocator, &tool_calls, body)) {
                parsed_tools = true;
            }
        }

        if (parsed_tools) {
            found_any_tool = true;
        } else {
            try assistant_buf.appendSlice(text[open_idx .. body_end + close_tag.len]);
        }

        cursor = body_end + close_tag.len;
    }

    if (!found_wrapper or !found_any_tool) return null;
    if (cursor < text.len) {
        try assistant_buf.appendSlice(text[cursor..]);
    }

    const assistant_trimmed = std.mem.trim(u8, assistant_buf.items(), " \t\r\n");
    return .{
        .assistant_text = try decodeEscapedText(allocator, assistant_trimmed),
        .tool_calls = try tool_calls.toOwnedSlice(),
        .control = .{},
    };
}

fn parameterTagTargetsToolCalls(tag: []const u8) bool {
    const t = std.mem.trim(u8, tag, " \t\r\n");
    if (!startsWithIgnoreCase(t, "<parameter")) return false;

    // Parse key=value attributes and accept name="tool_calls" (case-insensitive).
    var attrs = t["<parameter".len..];
    attrs = std.mem.trimStart(u8, attrs, " \t");
    if (attrs.len == 0) return false;
    if (attrs[attrs.len - 1] == '>') attrs = attrs[0 .. attrs.len - 1];
    attrs = std.mem.trimEnd(u8, attrs, " \t");
    if (attrs.len > 0 and attrs[attrs.len - 1] == '/') {
        attrs = std.mem.trimEnd(u8, attrs[0 .. attrs.len - 1], " \t");
    }

    var i: usize = 0;
    while (i < attrs.len) {
        while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) : (i += 1) {}
        if (i >= attrs.len) break;

        const key_start = i;
        while (i < attrs.len and attrs[i] != '=' and !std.ascii.isWhitespace(attrs[i])) : (i += 1) {}
        const key = std.mem.trim(u8, attrs[key_start..i], " \t");
        if (key.len == 0) break;

        while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) : (i += 1) {}
        if (i >= attrs.len or attrs[i] != '=') continue;
        i += 1;
        while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) : (i += 1) {}
        if (i >= attrs.len) break;

        var value_slice: []const u8 = "";
        if (attrs[i] == '"' or attrs[i] == '\'') {
            const quote = attrs[i];
            i += 1;
            const value_start = i;
            while (i < attrs.len and attrs[i] != quote) : (i += 1) {}
            value_slice = attrs[value_start..@min(i, attrs.len)];
            if (i < attrs.len and attrs[i] == quote) i += 1;
        } else {
            const value_start = i;
            while (i < attrs.len and !std.ascii.isWhitespace(attrs[i])) : (i += 1) {}
            value_slice = attrs[value_start..i];
        }

        if (std.ascii.eqlIgnoreCase(key, "name") and std.ascii.eqlIgnoreCase(value_slice, "tool_calls")) {
            return true;
        }
    }

    return false;
}

const testing = std.testing;
test "parseTaggedToolCallBlocks extracts tool" {
    const alloc = testing.allocator;
    var result = (try parseTaggedToolCallBlocks(alloc, "[tool_call]{\"name\":\"read\",\"args\":{\"p\":\"x\"}}[/tool_call]")).?;
    defer result.deinit(alloc);
    try testing.expectEqualStrings("read", result.tool_calls[0].name);
}
test "parseTaggedToolCallBlocks null no tags" {
    try testing.expect((try parseTaggedToolCallBlocks(testing.allocator, "no tags")) == null);
}
