const std = @import("std");
const std_io = @import("std_io.zig");
const helpers = @import("parse_helpers.zig");

const ToolCall = helpers.ToolCall;
const ParsedOutput = helpers.ParsedOutput;

const indexOfIgnoreCase = helpers.indexOfIgnoreCase;
const startsWithIgnoreCase = helpers.startsWithIgnoreCase;
const eqlIgnoreCase = helpers.eqlIgnoreCase;
const decodeEscapedText = helpers.decodeEscapedText;
const decodeXmlEntities = helpers.decodeXmlEntities;
const stripToolXmlNoise = helpers.stripToolXmlNoise;

pub fn parseXmlToolCallTags(allocator: std.mem.Allocator, text: []const u8) !?ParsedOutput {
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
    var found_any_tool = false;

    while (true) {
        const open_rel = std.mem.indexOfScalar(u8, text[cursor..], '<') orelse {
            try assistant_buf.appendSlice(text[cursor..]);
            break;
        };
        const open_idx = cursor + open_rel;
        if (open_idx > cursor) {
            try assistant_buf.appendSlice(text[cursor..open_idx]);
        }

        const close_rel = std.mem.indexOfScalar(u8, text[open_idx + 1 ..], '>') orelse {
            try assistant_buf.appendSlice(text[open_idx..]);
            break;
        };
        const close_idx = open_idx + 1 + close_rel;
        const tag = text[open_idx .. close_idx + 1];

        if (isToolCallsWrapperTag(tag)) {
            cursor = close_idx + 1;
            continue;
        }

        if (try appendXmlToolCallFromTag(allocator, &tool_calls, tag)) {
            found_any_tool = true;
            cursor = close_idx + 1;
            continue;
        }

        // Preserve non-tool tags as normal assistant text.
        try assistant_buf.appendSlice(tag);
        cursor = close_idx + 1;
    }

    if (!found_any_tool) return null;

    const assistant_clean = stripToolXmlNoise(allocator, assistant_buf.items()) catch assistant_buf.items();
    defer if (assistant_clean.ptr != assistant_buf.items().ptr) allocator.free(assistant_clean);
    const assistant_trimmed = std.mem.trim(u8, assistant_clean, " \t\r\n");

    return .{
        .assistant_text = try decodeEscapedText(allocator, assistant_trimmed),
        .tool_calls = try tool_calls.toOwnedSlice(),
        .control = .{},
    };
}

fn isToolCallsWrapperTag(tag: []const u8) bool {
    const t = std.mem.trim(u8, tag, " \t\r\n");
    if (startsWithIgnoreCase(t, "<tool_calls")) return true;
    if (startsWithIgnoreCase(t, "</tool_calls")) return true;
    if (eqlIgnoreCase(t, "</>")) return true;
    return false;
}

fn appendXmlToolCallFromTag(allocator: std.mem.Allocator, out: *std.array_list.Managed(ToolCall), tag: []const u8) !bool {
    const t = std.mem.trim(u8, tag, " \t\r\n");
    if (t.len < 6) return false;
    if (!(startsWithIgnoreCase(t, "<tool") and !startsWithIgnoreCase(t, "<tool_"))) return false;
    if (t[1] == '/') return false;

    // Drop the "<tool" prefix and trailing ">" or "/>".
    var attrs = t["<tool".len..];
    attrs = std.mem.trimStart(u8, attrs, " \t");
    if (attrs.len == 0) return false;
    if (attrs[attrs.len - 1] == '>') attrs = attrs[0 .. attrs.len - 1];
    attrs = std.mem.trimEnd(u8, attrs, " \t");
    if (attrs.len > 0 and attrs[attrs.len - 1] == '/') {
        attrs = std.mem.trimEnd(u8, attrs[0 .. attrs.len - 1], " \t");
    }

    var name: ?[]u8 = null;
    errdefer if (name) |n| allocator.free(n);

    var arg_buf = std_io.StringBuilder.init(allocator);
    errdefer arg_buf.deinit();

    var i: usize = 0;
    var wrote_arg = false;
    while (i < attrs.len) {
        while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) : (i += 1) {}
        if (i >= attrs.len) break;

        const key_start = i;
        while (i < attrs.len and attrs[i] != '=' and !std.ascii.isWhitespace(attrs[i])) : (i += 1) {}
        const key = std.mem.trim(u8, attrs[key_start..i], " \t");
        if (key.len == 0) break;

        while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) : (i += 1) {}
        if (i >= attrs.len or attrs[i] != '=') {
            // Skip valueless attribute.
            continue;
        }
        i += 1;
        while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) : (i += 1) {}
        if (i >= attrs.len) break;

        var value_slice: []const u8 = "";
        if (attrs[i] == '"' or attrs[i] == '\'') {
            const quote = attrs[i];
            i += 1;
            const val_start = i;
            while (i < attrs.len and attrs[i] != quote) : (i += 1) {}
            value_slice = attrs[val_start..@min(i, attrs.len)];
            if (i < attrs.len and attrs[i] == quote) i += 1;
        } else {
            const val_start = i;
            while (i < attrs.len and !std.ascii.isWhitespace(attrs[i])) : (i += 1) {}
            value_slice = attrs[val_start..i];
        }

        const value = decodeXmlEntities(allocator, value_slice) catch try allocator.dupe(u8, value_slice);
        defer allocator.free(value);

        if (std.ascii.eqlIgnoreCase(key, "name")) {
            const next_name = try allocator.dupe(u8, value);
            if (name) |existing| allocator.free(existing);
            name = next_name;
        } else {
            if (wrote_arg) try arg_buf.writer().writeByte(';');
            wrote_arg = true;
            try arg_buf.writer().print("{s}={s}", .{ key, value });
        }
    }

    const tool_name = name orelse return false;
    try out.ensureUnusedCapacity(1);
    const args = try arg_buf.toOwnedSlice();
    out.appendAssumeCapacity(.{
        .name = tool_name,
        .args = args,
    });
    return true;
}

pub fn appendToolCallsFromInvokeTags(allocator: std.mem.Allocator, out: *std.array_list.Managed(ToolCall), text: []const u8) !bool {
    var cursor: usize = 0;
    var appended_any = false;

    while (indexOfIgnoreCase(text[cursor..], "<invoke")) |open_rel| {
        const open_idx = cursor + open_rel;
        const open_tag_end_rel = std.mem.indexOfScalar(u8, text[open_idx..], '>') orelse break;
        const open_tag_end = open_idx + open_tag_end_rel;
        const open_tag = text[open_idx .. open_tag_end + 1];

        const body_start = open_tag_end + 1;
        const close_rel = indexOfIgnoreCase(text[body_start..], "</invoke>") orelse break;
        const body_end = body_start + close_rel;
        const body = text[body_start..body_end];

        if (try appendInvokeToolCallFromBlock(allocator, out, open_tag, body)) {
            appended_any = true;
        }

        cursor = body_end + "</invoke>".len;
    }

    return appended_any;
}

fn appendInvokeToolCallFromBlock(
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed(ToolCall),
    open_tag: []const u8,
    body: []const u8,
) !bool {
    const t = std.mem.trim(u8, open_tag, " \t\r\n");
    if (!(startsWithIgnoreCase(t, "<invoke") and t.len >= "<invoke>".len)) return false;
    if (t[1] == '/') return false;

    var attrs = t["<invoke".len..];
    attrs = std.mem.trimStart(u8, attrs, " \t");
    if (attrs.len == 0) return false;
    if (attrs[attrs.len - 1] == '>') attrs = attrs[0 .. attrs.len - 1];
    attrs = std.mem.trimEnd(u8, attrs, " \t");
    if (attrs.len > 0 and attrs[attrs.len - 1] == '/') {
        attrs = std.mem.trimEnd(u8, attrs[0 .. attrs.len - 1], " \t");
    }

    var name: ?[]u8 = null;
    errdefer if (name) |n| allocator.free(n);

    var arg_buf = std_io.StringBuilder.init(allocator);
    errdefer arg_buf.deinit();

    var i: usize = 0;
    var wrote_arg = false;
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
            const val_start = i;
            while (i < attrs.len and attrs[i] != quote) : (i += 1) {}
            value_slice = attrs[val_start..@min(i, attrs.len)];
            if (i < attrs.len and attrs[i] == quote) i += 1;
        } else {
            const val_start = i;
            while (i < attrs.len and !std.ascii.isWhitespace(attrs[i])) : (i += 1) {}
            value_slice = attrs[val_start..i];
        }

        const value = decodeXmlEntities(allocator, value_slice) catch try allocator.dupe(u8, value_slice);
        defer allocator.free(value);

        if (std.ascii.eqlIgnoreCase(key, "name") or std.ascii.eqlIgnoreCase(key, "tool")) {
            const next_name = try allocator.dupe(u8, value);
            if (name) |existing| allocator.free(existing);
            name = next_name;
        } else {
            if (wrote_arg) try arg_buf.writer().writeByte(';');
            wrote_arg = true;
            try arg_buf.writer().print("{s}={s}", .{ key, value });
        }
    }

    try appendInvokeBodyArgs(allocator, &arg_buf, &wrote_arg, body);

    const tool_name = name orelse return false;
    try out.ensureUnusedCapacity(1);
    const args = try arg_buf.toOwnedSlice();
    out.appendAssumeCapacity(.{
        .name = tool_name,
        .args = args,
    });
    return true;
}

fn appendInvokeBodyArgs(
    allocator: std.mem.Allocator,
    arg_buf: *std_io.StringBuilder,
    wrote_arg: *bool,
    body: []const u8,
) !void {
    var cursor: usize = 0;
    while (std.mem.indexOfScalar(u8, body[cursor..], '<')) |open_rel| {
        const open_idx = cursor + open_rel;
        if (open_idx + 1 >= body.len) break;
        if (body[open_idx + 1] == '/') {
            cursor = open_idx + 2;
            continue;
        }

        const tag_end_rel = std.mem.indexOfScalar(u8, body[open_idx + 1 ..], '>') orelse break;
        const tag_end = open_idx + 1 + tag_end_rel;
        var tag_spec = body[open_idx + 1 .. tag_end];
        tag_spec = std.mem.trim(u8, tag_spec, " \t\r\n");
        if (tag_spec.len == 0) {
            cursor = tag_end + 1;
            continue;
        }

        const self_closing = tag_spec[tag_spec.len - 1] == '/';
        if (self_closing) {
            cursor = tag_end + 1;
            continue;
        }

        var name_end: usize = 0;
        while (name_end < tag_spec.len and !std.ascii.isWhitespace(tag_spec[name_end]) and tag_spec[name_end] != '/') : (name_end += 1) {}
        if (name_end == 0) {
            cursor = tag_end + 1;
            continue;
        }
        const key = tag_spec[0..name_end];

        const value_start = tag_end + 1;
        const close_tag = try std.fmt.allocPrint(allocator, "</{s}>", .{key});
        defer allocator.free(close_tag);
        const close_rel = indexOfIgnoreCase(body[value_start..], close_tag) orelse {
            cursor = tag_end + 1;
            continue;
        };
        const value_end = value_start + close_rel;
        const raw_value = std.mem.trim(u8, body[value_start..value_end], " \t\r\n");
        const value = decodeXmlEntities(allocator, raw_value) catch try allocator.dupe(u8, raw_value);
        defer allocator.free(value);

        if (wrote_arg.*) try arg_buf.writer().writeByte(';');
        wrote_arg.* = true;
        try arg_buf.writer().print("{s}={s}", .{ key, value });

        cursor = value_end + close_tag.len;
    }
}

const testing = std.testing;
test "parseXmlToolCallTags extracts tool" {
    const alloc = testing.allocator;
    var result = (try parseXmlToolCallTags(alloc, "<tool name=\"read\" path=\"/tmp\">")).?;
    defer result.deinit(alloc);
    try testing.expectEqualStrings("read", result.tool_calls[0].name);
}
test "parseXmlToolCallTags null for text" {
    try testing.expect((try parseXmlToolCallTags(testing.allocator, "plain text")) == null);
}
