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
        };
    }

    if (@import("../core/env.zig").getOwned(allocator, "ZCODE_MOCK_RESPONSE")) |env_response| {
        return .{
            .raw = env_response,
            .text = try allocator.dupe(u8, env_response),
            .usage_input_tokens = tokenizer.estimateText("mock", request.model, request.prompt),
            .usage_output_tokens = tokenizer.estimateText("mock", request.model, env_response),
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
