//! Converts zcode's internal tool-args mini-format into a JSON object, for
//! embedding in SDK wire messages (`tool_use.input`, `can_use_tool.input`,
//! `result.permission_denials[].tool_input`) that require a real JSON value.
//!
//! `ToolCall`/`ToolTrace.args` is deliberately NEVER JSON internally: when a
//! provider's native tool call carries JSON input, `core/parse_json.zig`
//! (parseNativeToolCallsJson, ~line 50: "Native tool call args come as a JSON
//! string ... Parse the JSON and convert to key=value format that tool
//! dispatch expects") converts it to `key=value;key2=value2` (see
//! `core/parse_helpers.argsToKvText` / `core/arg_parse.getArg`) so tool
//! dispatch has one grammar regardless of provider. Every SDK serialization
//! boundary that needs to hand a tool's input to a host as JSON must convert
//! back -- this module is that one conversion point (found the hard way: an
//! early cut of headless-sdk-01/missed-182 embedded `args` verbatim as if it
//! were already JSON and produced invalid lines like `"input":command=ls`).
//!
//! Best-effort, not a byte-perfect inverse: a value that is itself valid JSON
//! (a nested object/array, a number, true/false/null -- exactly what
//! `argsToKvText`'s non-string branches produce) round-trips structurally;
//! anything else is embedded as a JSON string. Malformed input degrades
//! gracefully (an unparseable segment is skipped) rather than failing the
//! whole line.

const std = @import("std");
const std_io = @import("../core/std_io.zig");

/// True when `bytes` parses as a JSON object -- the rare case where `args` is
/// already JSON (e.g. an empty/placeholder value some path already stores as
/// `"{}"`) rather than the kv mini-format.
fn isJsonObject(allocator: std.mem.Allocator, bytes: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return false;
    defer parsed.deinit();
    return parsed.value == .object;
}

/// Convert zcode's internal tool-args text into a JSON object string. Caller
/// owns the returned slice. Empty/whitespace-only input yields `"{}"`.
pub fn toJsonObject(allocator: std.mem.Allocator, args: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, "{}");
    if (isJsonObject(allocator, trimmed)) return allocator.dupe(u8, trimmed);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();
    try w.writeByte('{');

    var wrote = false;
    var i: usize = 0;
    // Top-level `;`/`,`/`\n`-separated segment scan, mirroring
    // core/arg_parse.getArgDepth's separator/quote/nesting rules exactly so
    // a value containing a comma inside quotes or brackets is not split.
    while (i < trimmed.len) {
        while (i < trimmed.len and (trimmed[i] == ';' or trimmed[i] == ',' or trimmed[i] == '\n' or std.ascii.isWhitespace(trimmed[i]))) : (i += 1) {}
        if (i >= trimmed.len) break;
        const seg_start = i;
        var nesting: usize = 0;
        var in_string = false;
        var quote: u8 = 0;
        while (i < trimmed.len) : (i += 1) {
            const ch = trimmed[i];
            if (in_string) {
                if (ch == '\\' and i + 1 < trimmed.len) {
                    i += 1;
                    continue;
                }
                if (ch == quote) {
                    in_string = false;
                    quote = 0;
                }
                continue;
            }
            switch (ch) {
                '"', '\'' => {
                    in_string = true;
                    quote = ch;
                },
                '[', '{', '(' => nesting += 1,
                ']', '}', ')' => {
                    if (nesting > 0) nesting -= 1;
                },
                ';', ',', '\n' => {
                    if (nesting == 0) break;
                },
                else => {},
            }
        }
        const segment = trimmed[seg_start..i];
        const eq = std.mem.indexOfScalar(u8, segment, '=') orelse continue; // no key=value shape: skip
        const key = segment[0..eq];
        var value = segment[eq + 1 ..];
        // Strip one layer of matching quotes the mini-format may carry.
        if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and value[value.len - 1] == value[0]) {
            value = value[1 .. value.len - 1];
        }

        if (wrote) try w.writeByte(',');
        wrote = true;
        try w.print("{f}:", .{std.json.fmt(key, .{})});
        try writeArgValue(w, allocator, value);
    }
    try w.writeByte('}');
    return out.toOwnedSlice();
}

/// Write one arg value: verbatim when it is itself valid JSON (a nested
/// object/array, a number, true/false/null -- exactly what argsToKvText's
/// non-string branches produce), else as an escaped JSON string.
fn writeArgValue(w: *std.Io.Writer, allocator: std.mem.Allocator, value: []const u8) !void {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) {
        try w.writeAll("\"\"");
        return;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
        try w.print("{f}", .{std.json.fmt(trimmed, .{})});
        return;
    };
    defer parsed.deinit();
    switch (parsed.value) {
        .object, .array, .integer, .float, .bool, .null => try w.writeAll(trimmed),
        else => try w.print("{f}", .{std.json.fmt(trimmed, .{})}),
    }
}

const testing = std.testing;

test "toJsonObject: empty input yields {}" {
    const allocator = testing.allocator;
    const out = try toJsonObject(allocator, "");
    defer allocator.free(out);
    try testing.expectEqualStrings("{}", out);
}

test "toJsonObject: already-JSON input passes through verbatim" {
    const allocator = testing.allocator;
    const out = try toJsonObject(allocator, "{\"command\":\"ls\"}");
    defer allocator.free(out);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("ls", parsed.value.object.get("command").?.string);
}

test "toJsonObject: a single kv pair with a spaced string value" {
    const allocator = testing.allocator;
    const out = try toJsonObject(allocator, "command=echo hi");
    defer allocator.free(out);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("echo hi", parsed.value.object.get("command").?.string);
}

test "toJsonObject: multiple kv pairs separated by ; and ," {
    const allocator = testing.allocator;
    const out = try toJsonObject(allocator, "path=/tmp/x.txt;content=hello world");
    defer allocator.free(out);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("/tmp/x.txt", parsed.value.object.get("path").?.string);
    try testing.expectEqualStrings("hello world", parsed.value.object.get("content").?.string);
}

test "toJsonObject: numeric and boolean values round-trip as real JSON types" {
    const allocator = testing.allocator;
    const out = try toJsonObject(allocator, "limit=42;recursive=true");
    defer allocator.free(out);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 42), parsed.value.object.get("limit").?.integer);
    try testing.expectEqual(true, parsed.value.object.get("recursive").?.bool);
}

test "toJsonObject: a nested JSON object value embeds structurally" {
    const allocator = testing.allocator;
    const out = try toJsonObject(allocator, "options={\"a\":1,\"b\":[1,2]}");
    defer allocator.free(out);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    const opts = parsed.value.object.get("options").?.object;
    try testing.expectEqual(@as(i64, 1), opts.get("a").?.integer);
    try testing.expectEqual(@as(usize, 2), opts.get("b").?.array.items.len);
}

test "toJsonObject: a value containing a comma inside brackets is not split" {
    const allocator = testing.allocator;
    const out = try toJsonObject(allocator, "items=[1,2,3];name=x");
    defer allocator.free(out);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 3), parsed.value.object.get("items").?.array.items.len);
    try testing.expectEqualStrings("x", parsed.value.object.get("name").?.string);
}

test "toJsonObject: a quoted value strips one layer of quotes" {
    const allocator = testing.allocator;
    const out = try toJsonObject(allocator, "command=\"echo hi\"");
    defer allocator.free(out);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("echo hi", parsed.value.object.get("command").?.string);
}

test "toJsonObject: an unparseable segment (no '=') is skipped, not fatal" {
    const allocator = testing.allocator;
    const out = try toJsonObject(allocator, "bare_positional;key=value");
    defer allocator.free(out);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("value", parsed.value.object.get("key").?.string);
}
