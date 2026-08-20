const std = @import("std");

// ── Sub-module imports ─────────────────────────────────────────────────
const parse_helpers = @import("parse_helpers.zig");
const json_normalize = @import("json_normalize.zig");
const parse_json = @import("parse_json.zig");
const parse_xml = @import("parse_xml.zig");
const parse_blocks = @import("parse_blocks.zig");

// ── Re-exported public types ───────────────────────────────────────────
pub const ToolCall = parse_helpers.ToolCall;
pub const ControlActions = parse_helpers.ControlActions;
pub const ParsedOutput = parse_helpers.ParsedOutput;

// ── Main dispatcher ────────────────────────────────────────────────────

/// Parse model output, optionally with native tool calls from the API response.
pub fn parseWithNativeToolCalls(allocator: std.mem.Allocator, text: []const u8, native_tool_calls_json: []const u8) !ParsedOutput {
    // If native tool calls are present (from OpenAI function calling API),
    // parse them directly instead of trying to find tool calls in the text.
    if (native_tool_calls_json.len > 0) {
        if (try parse_json.parseNativeToolCallsJson(allocator, native_tool_calls_json)) |tool_calls| {
            return .{
                .assistant_text = if (text.len > 0) try parse_helpers.decodeEscapedText(allocator, text) else try allocator.dupe(u8, ""),
                .tool_calls = tool_calls,
                .control = .{},
            };
        }
    }
    return parse(allocator, text);
}

pub fn parse(allocator: std.mem.Allocator, text: []const u8) !ParsedOutput {
    if (try parse_json.parseCandidateJson(allocator, text, text)) |parsed| {
        return parsed;
    }

    if (parse_helpers.extractFencedJson(allocator, text)) |candidate| {
        defer allocator.free(candidate);
        if (try parse_json.parseCandidateJson(allocator, candidate, text)) |parsed| {
            return parsed;
        }
    }

    if (parse_helpers.extractFirstJsonObject(allocator, text)) |candidate| {
        defer allocator.free(candidate);
        if (try parse_json.parseCandidateJson(allocator, candidate, text)) |parsed| {
            return parsed;
        }
    }

    if (try parse_blocks.parseTaggedToolCallBlocks(allocator, text)) |parsed| {
        return parsed;
    }

    if (try parse_blocks.parseToolCallsEnvelopeBlocks(allocator, text)) |parsed| {
        return parsed;
    }

    if (try parse_blocks.parseParameterToolCallsBlocks(allocator, text)) |parsed| {
        return parsed;
    }

    if (try parse_xml.parseXmlToolCallTags(allocator, text)) |parsed| {
        return parsed;
    }

    if (try parse_json.parseBareToolCallPayload(allocator, text)) |parsed| {
        return parsed;
    }

    return .{
        .assistant_text = try parse_helpers.decodeEscapedText(allocator, text),
        .tool_calls = try allocator.alloc(ToolCall, 0),
        .control = .{},
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "parse plain text fallback" {
    const allocator = testing.allocator;
    var p = try parse(allocator, "hello");
    defer p.deinit(allocator);

    try testing.expectEqualStrings("hello", p.assistant_text);
    try testing.expectEqual(@as(usize, 0), p.tool_calls.len);
}

test "parse structured tool calls" {
    const allocator = testing.allocator;
    const input = "{\"assistant\":\"working\",\"tool_calls\":[{\"name\":\"shell\",\"args\":{\"command\":\"ls\"}}]}";
    var p = try parse(allocator, input);
    defer p.deinit(allocator);

    try testing.expectEqualStrings("working", p.assistant_text);
    try testing.expectEqual(@as(usize, 1), p.tool_calls.len);
    try testing.expectEqualStrings("shell", p.tool_calls[0].name);
    try testing.expectEqualStrings("command=ls", p.tool_calls[0].args);
}

test "parse fenced json with inline tool fields" {
    const allocator = testing.allocator;
    const input =
        "```json\n" ++
        "{\n" ++
        "  \"assistant\": \"I will inspect files.\",\n" ++
        "  \"tool_calls\": [\n" ++
        "    {\"tool\": \"file_read\", \"path\": \"package.json\"},\n" ++
        "    {\"tool\": \"file_read\", \"path\": \"README.md\"}\n" ++
        "  ],\n" ++
        "  \"control\": \"continue\"\n" ++
        "}\n" ++
        "```";

    var p = try parse(allocator, input);
    defer p.deinit(allocator);

    try testing.expectEqualStrings("I will inspect files.", p.assistant_text);
    try testing.expectEqual(@as(usize, 2), p.tool_calls.len);
    try testing.expectEqualStrings("file_read", p.tool_calls[0].name);
    try testing.expectEqualStrings("path=package.json", p.tool_calls[0].args);
    try testing.expect(!p.control.compact);
    try testing.expect(!p.control.resume_requested);
    try testing.expect(!p.control.escalate);
}

test "parse json object embedded in prose" {
    const allocator = testing.allocator;
    const input =
        "Working...\n" ++
        "{\"assistant\":\"done\",\"tool_calls\":[]}\n" ++
        "Thanks.";

    var p = try parse(allocator, input);
    defer p.deinit(allocator);

    try testing.expectEqualStrings("done", p.assistant_text);
    try testing.expectEqual(@as(usize, 0), p.tool_calls.len);
}

test "parse arguments field and control aliases" {
    const allocator = testing.allocator;
    const input =
        "{\"assistant\":\"ok\",\"tool_calls\":[{\"name\":\"file_read\",\"arguments\":\"{\\\"path\\\":\\\"tsconfig.json\\\"}\"}],\"control\":{\"compact\":true,\"resume_requested\":true}}";
    var p = try parse(allocator, input);
    defer p.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), p.tool_calls.len);
    try testing.expectEqualStrings("path=tsconfig.json", p.tool_calls[0].args);
    try testing.expect(p.control.compact);
    try testing.expect(p.control.resume_requested);
    try testing.expect(!p.control.continue_requested);
}

test "parse payload style tool call format" {
    const allocator = testing.allocator;
    const input =
        "```json\n" ++
        "{\n" ++
        "  \"assistant\": \"working\",\n" ++
        "  \"tool_calls\": [\n" ++
        "    {\"tool\":\"file_read\",\"call_id\":\"r1\",\"payload\":{\"path\":\"build.zig\"}},\n" ++
        "    {\"tool\":\"shell\",\"payload\":{\"command\":\"zig version\"}}\n" ++
        "  ],\n" ++
        "  \"control\": \"continue\"\n" ++
        "}\n" ++
        "```";

    var p = try parse(allocator, input);
    defer p.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), p.tool_calls.len);
    try testing.expectEqualStrings("file_read", p.tool_calls[0].name);
    try testing.expectEqualStrings("path=build.zig", p.tool_calls[0].args);
    try testing.expectEqualStrings("shell", p.tool_calls[1].name);
    try testing.expectEqualStrings("command=zig version", p.tool_calls[1].args);
    try testing.expect(p.control.continue_requested);
}

test "parse control continue in object form" {
    const allocator = testing.allocator;
    const input = "{\"assistant\":\"working\",\"tool_calls\":[],\"control\":{\"continue\":true}}";
    var p = try parse(allocator, input);
    defer p.deinit(allocator);

    try testing.expect(p.control.continue_requested);
}

test "parse non-protocol json falls back to raw text" {
    const allocator = testing.allocator;
    const input = "{\"message\":\"Loading model\"}";
    var p = try parse(allocator, input);
    defer p.deinit(allocator);

    try testing.expectEqualStrings(input, p.assistant_text);
    try testing.expectEqual(@as(usize, 0), p.tool_calls.len);
}

test "parse provider error json extracts message" {
    const allocator = testing.allocator;
    const input = "{\"error\":{\"message\":\"Loading model\",\"type\":\"unavailable_error\",\"code\":503}}";
    var p = try parse(allocator, input);
    defer p.deinit(allocator);

    try testing.expect(std.mem.indexOf(u8, p.assistant_text, "provider error: Loading model") != null);
    try testing.expectEqual(@as(usize, 0), p.tool_calls.len);
}

test "parse TOOL_CALL blocks into executable tool calls" {
    const allocator = testing.allocator;
    const input =
        "[TOOL_CALL]\n" ++
        "{\"tool\":\"Read\",\"args\":{\"path\":\"README.md\"}}\n" ++
        "[/TOOL_CALL]\n" ++
        "[TOOL_CALL]\n" ++
        "{\"tool\":\"Glob\",\"args\":{\"pattern\":\"*.zig\"}}\n" ++
        "[/TOOL_CALL]\n";

    var p = try parse(allocator, input);
    defer p.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), p.tool_calls.len);
    try testing.expectEqualStrings("Read", p.tool_calls[0].name);
    try testing.expectEqualStrings("path=README.md", p.tool_calls[0].args);
    try testing.expectEqualStrings("Glob", p.tool_calls[1].name);
    try testing.expectEqualStrings("pattern=*.zig", p.tool_calls[1].args);
    try testing.expectEqualStrings("", p.assistant_text);
}

test "parse TOOL_CALL blocks preserves assistant text outside blocks" {
    const allocator = testing.allocator;
    const input =
        "I'll inspect docs.\n" ++
        "[TOOL_CALL]\n" ++
        "{\"tool\":\"Read\",\"args\":{\"path\":\"docs/README.md\"}}\n" ++
        "[/TOOL_CALL]\n" ++
        "Working on it.";

    var p = try parse(allocator, input);
    defer p.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), p.tool_calls.len);
    try testing.expect(std.mem.indexOf(u8, p.assistant_text, "I'll inspect docs.") != null);
    try testing.expect(std.mem.indexOf(u8, p.assistant_text, "Working on it.") != null);
}

test "parse TOOL_CALL block with tool_calls wrapper object" {
    const allocator = testing.allocator;
    const input =
        "[TOOL_CALL]\n" ++
        "{\"tool_calls\":[{\"name\":\"Read\",\"args\":{\"path\":\"package.json\"}},{\"name\":\"Read\",\"args\":{\"path\":\"README.md\"}}]}\n" ++
        "[/TOOL_CALL]\n";

    var p = try parse(allocator, input);
    defer p.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), p.tool_calls.len);
    try testing.expectEqualStrings("Read", p.tool_calls[0].name);
    try testing.expectEqualStrings("path=package.json", p.tool_calls[0].args);
    try testing.expectEqualStrings("Read", p.tool_calls[1].name);
    try testing.expectEqualStrings("path=README.md", p.tool_calls[1].args);
}

test "parse TOOL_CALL block with js-style unquoted tool_calls key" {
    const allocator = testing.allocator;
    const input =
        "[TOOL_CALL]\n" ++
        "{tool_calls: [{\"name\":\"Read\",\"args\":{\"path\":\"package.json\"}}, {\"name\":\"Read\",\"args\":{\"path\":\"README.md\"}}, {\"name\":\"Glob\",\"args\":{\"pattern\":\"src/*.ts\",\"max_results\":50}}]}\n" ++
        "[/TOOL_CALL]\n";

    var p = try parse(allocator, input);
    defer p.deinit(allocator);

    try testing.expectEqual(@as(usize, 3), p.tool_calls.len);
    try testing.expectEqualStrings("Read", p.tool_calls[0].name);
    try testing.expectEqualStrings("path=package.json", p.tool_calls[0].args);
    try testing.expectEqualStrings("Read", p.tool_calls[1].name);
    try testing.expectEqualStrings("path=README.md", p.tool_calls[1].args);
    try testing.expectEqualStrings("Glob", p.tool_calls[2].name);
    try testing.expectEqualStrings("pattern=src/*.ts;max_results=50", p.tool_calls[2].args);
}

test "parse schema wrapper tool call from fenced block" {
    const allocator = testing.allocator;
    const input =
        "```tool_call\n" ++
        "{\n" ++
        "  \"tool\": \"shell\",\n" ++
        "  \"schema\": {\n" ++
        "    \"command\": \"ollama --version\",\n" ++
        "    \"timeout_seconds\": 10\n" ++
        "  }\n" ++
        "}\n" ++
        "```";

    var p = try parse(allocator, input);
    defer p.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), p.tool_calls.len);
    try testing.expectEqualStrings("shell", p.tool_calls[0].name);
    try testing.expectEqualStrings("command=ollama --version;timeout_seconds=10", p.tool_calls[0].args);
    try testing.expect(std.mem.indexOf(u8, p.assistant_text, "\"schema\"") != null);
}

test "parse XML tool call tags into executable tool calls" {
    const allocator = testing.allocator;
    const input =
        "<tool_calls>\n" ++
        "<tool name=\"Read\" path=\"docs/COMPARISON_WITH_OPENCLAW.md\" />\n" ++
        "<tool name=\"GitDiff\" path=\"docs/COMPARISON_WITH_OPENCLAW.md\" />\n" ++
        "</tool_calls>";

    var p = try parse(allocator, input);
    defer p.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), p.tool_calls.len);
    try testing.expectEqualStrings("Read", p.tool_calls[0].name);
    try testing.expectEqualStrings("path=docs/COMPARISON_WITH_OPENCLAW.md", p.tool_calls[0].args);
    try testing.expectEqualStrings("GitDiff", p.tool_calls[1].name);
    try testing.expectEqualStrings("path=docs/COMPARISON_WITH_OPENCLAW.md", p.tool_calls[1].args);
    try testing.expectEqualStrings("", p.assistant_text);
}

test "parse XML tool calls with broken wrapper residue" {
    const allocator = testing.allocator;
    const input =
        "<tool_calls>\n" ++
        "<tool name=\"Read\" path=\"docs/COMPARISON_WITH_OPENCLAW.md\" /></></tool_calls>\n";

    var p = try parse(allocator, input);
    defer p.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), p.tool_calls.len);
    try testing.expectEqualStrings("Read", p.tool_calls[0].name);
    try testing.expectEqualStrings("path=docs/COMPARISON_WITH_OPENCLAW.md", p.tool_calls[0].args);
    try testing.expectEqualStrings("", p.assistant_text);
}

test "parse tool_calls envelope with JSON array payload" {
    const allocator = testing.allocator;
    const input =
        "<tool_calls>\n" ++
        "[\n" ++
        "  {\"name\":\"file_read\",\"args\":{\"path\":\"README.md\"}},\n" ++
        "  {\"name\":\"file_read\",\"args\":{\"path\":\"docs/COMPARISON_WITH_OPENCLAW.md\"}},\n" ++
        "  {\"name\":\"WebSearch\",\"args\":{\"query\":\"OpenClaw AI agent automation open source project\"}}\n" ++
        "]\n" ++
        "</tool_calls>";

    var p = try parse(allocator, input);
    defer p.deinit(allocator);

    try testing.expectEqual(@as(usize, 3), p.tool_calls.len);
    try testing.expectEqualStrings("file_read", p.tool_calls[0].name);
    try testing.expectEqualStrings("path=README.md", p.tool_calls[0].args);
    try testing.expectEqualStrings("file_read", p.tool_calls[1].name);
    try testing.expectEqualStrings("path=docs/COMPARISON_WITH_OPENCLAW.md", p.tool_calls[1].args);
    try testing.expectEqualStrings("WebSearch", p.tool_calls[2].name);
    try testing.expectEqualStrings("query=OpenClaw AI agent automation open source project", p.tool_calls[2].args);
    try testing.expectEqualStrings("", p.assistant_text);
}

test "parse tool_calls envelope preserves assistant text outside wrapper" {
    const allocator = testing.allocator;
    const input =
        "Working...\n" ++
        "<tool_calls>\n" ++
        "[{\"name\":\"Read\",\"args\":{\"path\":\"README.md\"}}]\n" ++
        "</tool_calls>\n" ++
        "Still running.";

    var p = try parse(allocator, input);
    defer p.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), p.tool_calls.len);
    try testing.expectEqualStrings("Read", p.tool_calls[0].name);
    try testing.expectEqualStrings("path=README.md", p.tool_calls[0].args);
    try testing.expect(std.mem.indexOf(u8, p.assistant_text, "Working...") != null);
    try testing.expect(std.mem.indexOf(u8, p.assistant_text, "Still running.") != null);
}

test "parse tool_calls envelope with invoke blocks" {
    const allocator = testing.allocator;
    const input =
        "<tool_calls>\n" ++
        "<invoke name=\"Read\">\n" ++
        "<path>src/ai/client.ts</path>\n" ++
        "</invoke>\n" ++
        "<invoke name=\"Read\">\n" ++
        "<path>package.json</path>\n" ++
        "</invoke>\n" ++
        "</tool_calls>";

    var p = try parse(allocator, input);
    defer p.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), p.tool_calls.len);
    try testing.expectEqualStrings("Read", p.tool_calls[0].name);
    try testing.expectEqualStrings("path=src/ai/client.ts", p.tool_calls[0].args);
    try testing.expectEqualStrings("Read", p.tool_calls[1].name);
    try testing.expectEqualStrings("path=package.json", p.tool_calls[1].args);
    try testing.expectEqualStrings("", p.assistant_text);
}

test "parse invoke block with attribute and nested args" {
    const allocator = testing.allocator;
    const input =
        "<tool_calls>\n" ++
        "<invoke name=\"WebSearch\" source=\"web\">\n" ++
        "<query>OpenClaw agent architecture</query>\n" ++
        "</invoke>\n" ++
        "</tool_calls>";

    var p = try parse(allocator, input);
    defer p.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), p.tool_calls.len);
    try testing.expectEqualStrings("WebSearch", p.tool_calls[0].name);
    try testing.expectEqualStrings("source=web;query=OpenClaw agent architecture", p.tool_calls[0].args);
}

test "parse tool_calls envelope with nested arrays" {
    const allocator = testing.allocator;
    const input =
        "<tool_calls>\n" ++
        "[[{\"name\":\"Glob\",\"args\":{\"pattern\":\"src/*.ts\",\"max_results\":30}},{\"name\":\"Read\",\"args\":{\"path\":\"README.md\"}}]]\n" ++
        "</tool_calls>";

    var p = try parse(allocator, input);
    defer p.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), p.tool_calls.len);
    try testing.expectEqualStrings("Glob", p.tool_calls[0].name);
    try testing.expectEqualStrings("pattern=src/*.ts;max_results=30", p.tool_calls[0].args);
    try testing.expectEqualStrings("Read", p.tool_calls[1].name);
    try testing.expectEqualStrings("path=README.md", p.tool_calls[1].args);
}

test "parse tool_calls envelope with loose object recovery" {
    const allocator = testing.allocator;
    const input =
        "<tool_calls>\n" ++
        "not strict json but objects follow:\n" ++
        "{\"name\":\"Read\",\"args\":{\"path\":\"package.json\"}}\n" ++
        "{\"name\":\"Read\",\"args\":{\"path\":\"README.md\"}}\n" ++
        "</tool_calls>";

    var p = try parse(allocator, input);
    defer p.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), p.tool_calls.len);
    try testing.expectEqualStrings("Read", p.tool_calls[0].name);
    try testing.expectEqualStrings("path=package.json", p.tool_calls[0].args);
    try testing.expectEqualStrings("Read", p.tool_calls[1].name);
    try testing.expectEqualStrings("path=README.md", p.tool_calls[1].args);
}

test "parse parameter wrapper for tool_calls payload" {
    const allocator = testing.allocator;
    const input = "<parameter name=\"tool_calls\">[{\"name\":\"GitDiff\",\"args\":{\"context\":3}}]</parameter>";

    var p = try parse(allocator, input);
    defer p.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), p.tool_calls.len);
    try testing.expectEqualStrings("GitDiff", p.tool_calls[0].name);
    try testing.expectEqualStrings("context=3", p.tool_calls[0].args);
    try testing.expectEqualStrings("", p.assistant_text);
}

test "parse parameter wrapper preserves assistant text outside block" {
    const allocator = testing.allocator;
    const input =
        "Working...\n" ++
        "<parameter name=\"tool_calls\">[{\"name\":\"Read\",\"args\":{\"path\":\"README.md\"}}]</parameter>\n" ++
        "Still running.";

    var p = try parse(allocator, input);
    defer p.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), p.tool_calls.len);
    try testing.expectEqualStrings("Read", p.tool_calls[0].name);
    try testing.expectEqualStrings("path=README.md", p.tool_calls[0].args);
    try testing.expect(std.mem.indexOf(u8, p.assistant_text, "Working...") != null);
    try testing.expect(std.mem.indexOf(u8, p.assistant_text, "Still running.") != null);
}

test "parse js-style bare array tool calls with single quotes" {
    const allocator = testing.allocator;
    const input =
        "[\n" ++
        "  {\n" ++
        "    tool: 'Read',\n" ++
        "    args: {\n" ++
        "      path: 'src/ai/client.ts'\n" ++
        "    }\n" ++
        "  },\n" ++
        "  {\n" ++
        "    tool: 'Read',\n" ++
        "    args: {\n" ++
        "      path: 'package.json'\n" ++
        "    }\n" ++
        "  }\n" ++
        "]";

    var p = try parse(allocator, input);
    defer p.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), p.tool_calls.len);
    try testing.expectEqualStrings("Read", p.tool_calls[0].name);
    try testing.expectEqualStrings("path=src/ai/client.ts", p.tool_calls[0].args);
    try testing.expectEqualStrings("Read", p.tool_calls[1].name);
    try testing.expectEqualStrings("path=package.json", p.tool_calls[1].args);
    try testing.expectEqualStrings("", p.assistant_text);
}

test "parse TOOL_CALL block with js-style single-quoted keys and args" {
    const allocator = testing.allocator;
    const input =
        "[TOOL_CALL]\n" ++
        "{tool: 'Read', args: {path: 'src/ai/client.ts'}}\n" ++
        "[/TOOL_CALL]\n";

    var p = try parse(allocator, input);
    defer p.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), p.tool_calls.len);
    try testing.expectEqualStrings("Read", p.tool_calls[0].name);
    try testing.expectEqualStrings("path=src/ai/client.ts", p.tool_calls[0].args);
    try testing.expectEqualStrings("", p.assistant_text);
}

test "parse tool args preserves array payload values" {
    const allocator = testing.allocator;
    const input =
        "{\"assistant\":\"\",\"tool_calls\":[{\"name\":\"AskUserQuestion\",\"args\":{\"question\":\"Continue?\",\"choices\":[\"Approve\",\"Discuss\",\"Cancel\"]}}]}";

    var p = try parse(allocator, input);
    defer p.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), p.tool_calls.len);
    try testing.expectEqualStrings("AskUserQuestion", p.tool_calls[0].name);
    try testing.expect(std.mem.indexOf(u8, p.tool_calls[0].args, "question=Continue?") != null);
    try testing.expect(std.mem.indexOf(u8, p.tool_calls[0].args, "choices=[\"Approve\",\"Discuss\",\"Cancel\"]") != null);
}

test "parse parameter wrapper with single-quoted name attribute" {
    const allocator = testing.allocator;
    const input = "<parameter name='tool_calls'>[{\"name\":\"TaskPoll\",\"args\":{\"id\":\"task-1\"}}]</parameter>";

    var p = try parse(allocator, input);
    defer p.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), p.tool_calls.len);
    try testing.expectEqualStrings("TaskPoll", p.tool_calls[0].name);
    try testing.expectEqualStrings("id=task-1", p.tool_calls[0].args);
}
