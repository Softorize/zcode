const std = @import("std");
const testing = std.testing;

const json_normalize = @import("json_normalize.zig");
const parse_helpers = @import("parse_helpers.zig");
const parse_json = @import("parse_json.zig");
const parse_xml = @import("parse_xml.zig");
const parse_blocks = @import("parse_blocks.zig");

// -- JSON normalization fuzzing --

test "fuzz parseJsonLenient" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var fuzz_buf: [4096]u8 = undefined;
            const fuzz_n = smith.slice(&fuzz_buf);
            const input = fuzz_buf[0..fuzz_n];
            var result = json_normalize.parseJsonLenient(testing.allocator, input) catch return;
            if (result) |*r| r.deinit(testing.allocator);
        }
    }.run, .{ .corpus = &.{ "{}", "[]", "{\"key\":\"value\"}", "{'key': 'value'}", "{key: 123}", "" } });
}

test "fuzz normalizeJsLikeJson" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var fuzz_buf: [4096]u8 = undefined;
            const fuzz_n = smith.slice(&fuzz_buf);
            const input = fuzz_buf[0..fuzz_n];
            if (json_normalize.normalizeJsLikeJson(testing.allocator, input) catch null) |result| {
                testing.allocator.free(result);
            }
        }
    }.run, .{ .corpus = &.{ "{a: 1}", "{'b': 'c'}", "{\"d\": \"e\"}", "" } });
}

// -- Parse helpers fuzzing --

test "fuzz extractFirstJsonObject" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var fuzz_buf: [4096]u8 = undefined;
            const fuzz_n = smith.slice(&fuzz_buf);
            const input = fuzz_buf[0..fuzz_n];
            if (parse_helpers.extractFirstJsonObject(testing.allocator, input)) |result| {
                testing.allocator.free(result);
            }
        }
    }.run, .{ .corpus = &.{ "text {\"key\": \"val\"} more", "{}", "no json here", "{unclosed", "" } });
}

test "fuzz extractFencedJson" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var fuzz_buf: [4096]u8 = undefined;
            const fuzz_n = smith.slice(&fuzz_buf);
            const input = fuzz_buf[0..fuzz_n];
            if (parse_helpers.extractFencedJson(testing.allocator, input)) |result| {
                testing.allocator.free(result);
            }
        }
    }.run, .{ .corpus = &.{ "```json\n{}\n```", "```\n[]\n```", "no fence", "```unclosed" } });
}

test "fuzz decodeEscapedText" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var fuzz_buf: [4096]u8 = undefined;
            const fuzz_n = smith.slice(&fuzz_buf);
            const input = fuzz_buf[0..fuzz_n];
            const result = parse_helpers.decodeEscapedText(testing.allocator, input) catch return;
            testing.allocator.free(result);
        }
    }.run, .{ .corpus = &.{ "hello\\nworld", "\\t\\r\\n", "no escapes", "trailing\\", "" } });
}

test "fuzz decodeXmlEntities" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var fuzz_buf: [4096]u8 = undefined;
            const fuzz_n = smith.slice(&fuzz_buf);
            const input = fuzz_buf[0..fuzz_n];
            const result = parse_helpers.decodeXmlEntities(testing.allocator, input) catch return;
            testing.allocator.free(result);
        }
    }.run, .{ .corpus = &.{ "&amp;", "&lt;&gt;", "&quot;test&quot;", "no entities", "&#39;" } });
}

// -- JSON tool call parsing fuzzing --

test "fuzz parseCandidateJson" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var fuzz_buf: [4096]u8 = undefined;
            const fuzz_n = smith.slice(&fuzz_buf);
            const input = fuzz_buf[0..fuzz_n];
            var result = parse_json.parseCandidateJson(testing.allocator, input, "") catch return;
            if (result) |*r| r.deinit(testing.allocator);
        }
    }.run, .{ .corpus = &.{
        "{\"role\":\"assistant\",\"content\":\"hello\"}",
        "{\"tool_calls\":[{\"function\":{\"name\":\"test\",\"arguments\":\"{}\"}}]}",
        "not json",
        "",
    } });
}

// -- XML tool call parsing fuzzing --

test "fuzz parseXmlToolCallTags" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var fuzz_buf: [4096]u8 = undefined;
            const fuzz_n = smith.slice(&fuzz_buf);
            const input = fuzz_buf[0..fuzz_n];
            var result = parse_xml.parseXmlToolCallTags(testing.allocator, input) catch return;
            if (result) |*r| r.deinit(testing.allocator);
        }
    }.run, .{ .corpus = &.{
        "<tool name=\"test\">args</tool>",
        "<tool>no name</tool>",
        "no tags here",
        "<unclosed",
        "",
    } });
}

// -- Block format parsing fuzzing --

test "fuzz parseTaggedToolCallBlocks" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var fuzz_buf: [4096]u8 = undefined;
            const fuzz_n = smith.slice(&fuzz_buf);
            const input = fuzz_buf[0..fuzz_n];
            var result = parse_blocks.parseTaggedToolCallBlocks(testing.allocator, input) catch return;
            if (result) |*r| r.deinit(testing.allocator);
        }
    }.run, .{ .corpus = &.{
        "[tool_call]\nname=test\nargs={}\n[/tool_call]",
        "no blocks",
        "[tool_call]unclosed",
        "",
    } });
}

test "fuzz parseToolCallsEnvelopeBlocks" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var fuzz_buf: [4096]u8 = undefined;
            const fuzz_n = smith.slice(&fuzz_buf);
            const input = fuzz_buf[0..fuzz_n];
            var result = parse_blocks.parseToolCallsEnvelopeBlocks(testing.allocator, input) catch return;
            if (result) |*r| r.deinit(testing.allocator);
        }
    }.run, .{ .corpus = &.{
        "<tool_calls><invoke name=\"test\"><parameter name=\"arg\">val</parameter></invoke></tool_calls>",
        "no envelope",
        "<tool_calls>unclosed",
        "",
    } });
}
