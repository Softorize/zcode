const std = @import("std");
const rt = @import("zcode_runtime");
const types = @import("../core/types.zig");
const common = @import("common.zig");
const tokenizer = @import("../core/tokenizer.zig");

const MockAdapter = struct {
    scripted_responses: [][]u8,
    scripted_hash: u64,
};

const ScriptedResponseSet = struct {
    responses: [][]u8,
    hash: u64,
};

const ScriptedState = struct {
    lock: std.Io.Mutex = .init,
    last_hash: u64 = 0,
    next_index: usize = 0,
};

var scripted_state = ScriptedState{};

pub fn create(allocator: std.mem.Allocator, cfg: types.ProviderConfig) !types.ProviderAdapter {
    _ = cfg;
    const adapter = try allocator.create(MockAdapter);
    const scripted = try loadScriptedResponses(allocator);
    adapter.* = .{
        .scripted_responses = scripted.responses,
        .scripted_hash = scripted.hash,
    };

    return .{
        .name = "mock",
        .ctx = adapter,
        .vtable = &vtable,
    };
}

const vtable = types.ProviderAdapter.VTable{
    .deinit = deinit,
    .listModels = listModels,
    .send = send,
    .stream = stream,
    .healthcheck = healthcheck,
};

fn deinit(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const self: *MockAdapter = @ptrCast(@alignCast(ctx));
    for (self.scripted_responses) |response| allocator.free(response);
    allocator.free(self.scripted_responses);
    allocator.destroy(self);
}

fn listModels(ctx: *anyopaque, allocator: std.mem.Allocator) ![]types.ModelInfo {
    _ = ctx;
    const out = try allocator.alloc(types.ModelInfo, 1);
    out[0] = .{ .id = try allocator.dupe(u8, "mock-agent"), .provider = try allocator.dupe(u8, "mock"), .context_window = 32_000 };
    return out;
}

/// headless-sdk-missed-184: `ZCODE_MOCK_THINKING`, when set, becomes this
/// response's `reasoning_text`. Lets a real, CLI-observable end-to-end run
/// exercise the stream-json `thinking` content-block pipeline
/// (sdk/output.zig's `.thinking` block, agent_runtime.zig's
/// `thinkingForFinalText`) -- which, before this, could only be reached by
/// an isolated agent_runtime unit test with a hand-built history, since NO
/// provider adapter (mock included) had any way to inject mock thinking
/// text at all. Absent -> "" (unchanged default behavior for every existing
/// test/run that doesn't set it). Owned when non-empty, matching every
/// `ModelResponse.reasoning_text` producer's ownership contract (callers
/// `allocator.free` it when `.len > 0`).
fn mockReasoningText(allocator: std.mem.Allocator) []const u8 {
    return @import("../core/env.zig").getOwned(allocator, "ZCODE_MOCK_THINKING") catch "";
}

fn send(ctx: *anyopaque, allocator: std.mem.Allocator, request: types.ModelRequest) !types.ModelResponse {
    const self: *MockAdapter = @ptrCast(@alignCast(ctx));

    if (self.scripted_responses.len > 0) {
        const idx = nextScriptedResponseIndex(self.scripted_hash, self.scripted_responses.len);
        const response_text = self.scripted_responses[idx];
        return .{
            .raw = try allocator.dupe(u8, response_text),
            .text = try allocator.dupe(u8, response_text),
            .usage_input_tokens = tokenizer.estimateText("mock", request.model, request.prompt),
            .usage_output_tokens = tokenizer.estimateText("mock", request.model, response_text),
            .reasoning_text = mockReasoningText(allocator),
        };
    }

    if (@import("../core/env.zig").getOwned(allocator, "ZCODE_MOCK_RESPONSE")) |env_response| {
        return .{
            .raw = env_response,
            .text = try allocator.dupe(u8, env_response),
            .usage_input_tokens = tokenizer.estimateText("mock", request.model, request.prompt),
            .usage_output_tokens = tokenizer.estimateText("mock", request.model, env_response),
            .reasoning_text = mockReasoningText(allocator),
        };
    } else |_| {}

    const response_text = if (std.mem.indexOf(u8, request.prompt, "tool=git_status") != null)
        "{\"assistant\":\"Git status collected. No further tools needed.\",\"tool_calls\":[]}"
    else
        "{\"assistant\":\"Collecting git status before final answer.\",\"tool_calls\":[{\"name\":\"git_status\",\"args\":{}}]}";

    return .{
        .raw = try allocator.dupe(u8, response_text),
        .text = try allocator.dupe(u8, response_text),
        .usage_input_tokens = tokenizer.estimateText("mock", request.model, request.prompt),
        .usage_output_tokens = tokenizer.estimateText("mock", request.model, response_text),
        .reasoning_text = mockReasoningText(allocator),
    };
}

fn stream(ctx: *anyopaque, allocator: std.mem.Allocator, request: types.ModelRequest) ![]const u8 {
    const response = try send(ctx, allocator, request);
    allocator.free(response.raw);
    return response.text;
}

fn healthcheck(ctx: *anyopaque, allocator: std.mem.Allocator) !void {
    const models = try listModels(ctx, allocator);
    defer freeModelInfos(allocator, models);
}

fn loadScriptedResponses(allocator: std.mem.Allocator) !ScriptedResponseSet {
    const env_responses = @import("../core/env.zig").getOwned(allocator, "ZCODE_MOCK_RESPONSES") catch {
        return .{
            .responses = try allocator.alloc([]u8, 0),
            .hash = 0,
        };
    };
    defer allocator.free(env_responses);

    return .{
        .responses = try parseScriptedResponses(allocator, env_responses),
        .hash = std.hash.Wyhash.hash(0, env_responses),
    };
}

fn nextScriptedResponseIndex(script_hash: u64, response_count: usize) usize {
    scripted_state.lock.lock(rt.io) catch {};
    defer scripted_state.lock.unlock(rt.io);

    if (scripted_state.last_hash != script_hash) {
        scripted_state.last_hash = script_hash;
        scripted_state.next_index = 0;
    }

    const idx = @min(scripted_state.next_index, response_count - 1);
    if (scripted_state.next_index + 1 < response_count) {
        scripted_state.next_index += 1;
    }
    return idx;
}

fn parseScriptedResponses(allocator: std.mem.Allocator, json_text: []const u8) ![][]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();

    if (parsed.value != .array) return error.InvalidMockResponses;

    var out = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (out.items) |item| allocator.free(item);
        out.deinit();
    }

    for (parsed.value.array.items) |item| {
        if (item != .string) return error.InvalidMockResponses;
        const duped = try allocator.dupe(u8, item.string);
        out.append(duped) catch |err| {
            allocator.free(duped);
            return err;
        };
    }

    const owned = try out.toOwnedSlice();
    out = .init(allocator);
    return owned;
}

const freeModelInfos = common.freeModelInfos;

const testing = std.testing;
const env = @import("../core/env.zig");

test "mock send proposes a tool call, then answers once the tool result is in the prompt" {
    const alloc = testing.allocator;
    var p = try create(alloc, .{ .name = "mock", .api_key = null, .base_url = null });
    defer p.deinit(alloc);

    // Round 1: nothing about git_status in the prompt yet -- the mock
    // proposes calling it, mirroring a real provider's first tool-use turn.
    const round1 = try p.send(alloc, .{
        .model = "mock-agent",
        .prompt = "please check the repo status",
        .max_output_tokens = 256,
    });
    defer alloc.free(round1.raw);
    defer alloc.free(round1.text);
    try testing.expect(std.mem.indexOf(u8, round1.text, "\"name\":\"git_status\"") != null);
    try testing.expect(round1.usage_input_tokens > 0);
    try testing.expect(round1.usage_output_tokens > 0);

    // Round 2: the agent loop appended the tool result to the prompt --
    // the mock now gives its final answer with no further tool calls.
    const round2 = try p.send(alloc, .{
        .model = "mock-agent",
        .prompt = "please check the repo status\n\ntool=git_status result: clean",
        .max_output_tokens = 256,
    });
    defer alloc.free(round2.raw);
    defer alloc.free(round2.text);
    try testing.expect(std.mem.indexOf(u8, round2.text, "\"tool_calls\":[]") != null);
}

test "mock stream returns the same text send would (REPL interactive_streaming path)" {
    // r3-mock-01: agent_history.callWithAdapterOnce routes every interactive
    // REPL turn through adapter.streamLive (falling back to adapter.stream
    // when a provider has no stream_live, which is the mock provider's
    // case) rather than adapter.send. Before this test existed, only
    // adapter.send was ever exercised for mock -- the REPL's actual code
    // path was untested, which is exactly how the EndOfStream regression
    // (see std_io.zig's streamUntilDelimiter) went unnoticed: the bug was
    // never in the mock provider itself, but nothing proved the interactive
    // path even reached it.
    const alloc = testing.allocator;
    var p = try create(alloc, .{ .name = "mock", .api_key = null, .base_url = null });
    defer p.deinit(alloc);

    const request = types.ModelRequest{
        .model = "mock-agent",
        .prompt = "hello",
        .max_output_tokens = 256,
    };

    const sent = try p.send(alloc, request);
    defer alloc.free(sent.raw);
    defer alloc.free(sent.text);

    const streamed_via_streamLive = try p.streamLive(alloc, request, null);
    defer alloc.free(streamed_via_streamLive);
    try testing.expectEqualStrings(sent.text, streamed_via_streamLive);

    const streamed_direct = try p.stream(alloc, request);
    defer alloc.free(streamed_direct);
    try testing.expectEqualStrings(sent.text, streamed_direct);
}

test "mock send honors ZCODE_MOCK_RESPONSE for a fixed canned reply" {
    env.setOverride("ZCODE_MOCK_RESPONSE", "canned reply for a deterministic test") catch unreachable;
    defer env.clearOverrides();

    const alloc = testing.allocator;
    var p = try create(alloc, .{ .name = "mock", .api_key = null, .base_url = null });
    defer p.deinit(alloc);

    const response = try p.send(alloc, .{
        .model = "mock-agent",
        .prompt = "anything at all",
        .max_output_tokens = 64,
    });
    defer alloc.free(response.raw);
    defer alloc.free(response.text);
    try testing.expectEqualStrings("canned reply for a deterministic test", response.text);
}

test "headless-sdk-missed-184: mock send honors ZCODE_MOCK_THINKING as reasoning_text" {
    env.setOverride("ZCODE_MOCK_RESPONSE", "canned reply for a deterministic test") catch unreachable;
    env.setOverride("ZCODE_MOCK_THINKING", "reasoning through the deterministic test") catch unreachable;
    defer env.clearOverrides();

    const alloc = testing.allocator;
    var p = try create(alloc, .{ .name = "mock", .api_key = null, .base_url = null });
    defer p.deinit(alloc);

    const response = try p.send(alloc, .{
        .model = "mock-agent",
        .prompt = "anything at all",
        .max_output_tokens = 64,
    });
    defer alloc.free(response.raw);
    defer alloc.free(response.text);
    defer if (response.reasoning_text.len > 0) alloc.free(response.reasoning_text);
    try testing.expectEqualStrings("canned reply for a deterministic test", response.text);
    try testing.expectEqualStrings("reasoning through the deterministic test", response.reasoning_text);
}

test "headless-sdk-missed-184: mock send reasoning_text is empty when ZCODE_MOCK_THINKING is unset" {
    env.setOverride("ZCODE_MOCK_RESPONSE", "canned reply, no thinking") catch unreachable;
    defer env.clearOverrides();

    const alloc = testing.allocator;
    var p = try create(alloc, .{ .name = "mock", .api_key = null, .base_url = null });
    defer p.deinit(alloc);

    const response = try p.send(alloc, .{
        .model = "mock-agent",
        .prompt = "anything at all",
        .max_output_tokens = 64,
    });
    defer alloc.free(response.raw);
    defer alloc.free(response.text);
    try testing.expectEqual(@as(usize, 0), response.reasoning_text.len);
}

test "mock send cycles through ZCODE_MOCK_RESPONSES and holds the last entry" {
    // Use content unique to this test so its hash never collides with
    // scripted_state left over from another test in the same binary.
    env.setOverride("ZCODE_MOCK_RESPONSES", "[\"r3-mock-01 first\",\"r3-mock-01 second\"]") catch unreachable;
    defer env.clearOverrides();

    const alloc = testing.allocator;
    // Scripted responses are parsed once in create(), so a fresh adapter
    // starts this script's cycle from index 0 (nextScriptedResponseIndex
    // resets next_index whenever the script's content hash changes).
    var p = try create(alloc, .{ .name = "mock", .api_key = null, .base_url = null });
    defer p.deinit(alloc);

    const request = types.ModelRequest{ .model = "mock-agent", .prompt = "x", .max_output_tokens = 16 };

    const first = try p.send(alloc, request);
    defer alloc.free(first.raw);
    defer alloc.free(first.text);
    try testing.expectEqualStrings("r3-mock-01 first", first.text);

    const second = try p.send(alloc, request);
    defer alloc.free(second.raw);
    defer alloc.free(second.text);
    try testing.expectEqualStrings("r3-mock-01 second", second.text);

    // The script is exhausted -- subsequent calls hold the last entry
    // rather than erroring, so a REPL session that keeps chatting never
    // crashes just because the scripted fixture ran out.
    const third = try p.send(alloc, request);
    defer alloc.free(third.raw);
    defer alloc.free(third.text);
    try testing.expectEqualStrings("r3-mock-01 second", third.text);
}

test "mock listModels" {
    const alloc = testing.allocator;
    const a = try create(alloc, .{ .name = "mock", .api_key = null, .base_url = null });
    var p = a;
    defer p.deinit(alloc);
    const m = try p.listModels(alloc);
    defer freeModelInfos(alloc, m);
    try testing.expectEqualStrings("mock-agent", m[0].id);
}
test "parse scripted responses" {
    const responses = try parseScriptedResponses(testing.allocator, "[\"one\",\"two\"]");
    defer {
        for (responses) |response| testing.allocator.free(response);
        testing.allocator.free(responses);
    }
    try testing.expectEqual(@as(usize, 2), responses.len);
    try testing.expectEqualStrings("one", responses[0]);
    try testing.expectEqualStrings("two", responses[1]);
}
