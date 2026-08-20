const std = @import("std");
const clock = @import("../core/clock.zig");
const std_io = @import("../core/std_io.zig");
const types = @import("../core/types.zig");
const common = @import("common.zig");
const tokenizer = @import("../core/tokenizer.zig");
const circuit_breaker = @import("circuit_breaker.zig");
const parse_helpers = @import("../core/parse_helpers.zig");

const GroqAdapter = struct {
    api_key: ?[]u8,
    base_url: []u8,
    timeout_ms: u32,
    retry_count: u8,
    cb: circuit_breaker.CircuitBreaker,
};

pub fn create(allocator: std.mem.Allocator, cfg: types.ProviderConfig) !types.ProviderAdapter {
    const adapter = try allocator.create(GroqAdapter);
    adapter.* = .{
        .api_key = if (cfg.api_key) |key| try allocator.dupe(u8, key) else null,
        .base_url = if (cfg.base_url) |v| try allocator.dupe(u8, v) else try allocator.dupe(u8, "https://api.groq.com/openai"),
        .timeout_ms = cfg.timeout_ms,
        .retry_count = cfg.retry_count,
        .cb = circuit_breaker.CircuitBreaker.init(5, 30),
    };

    return .{
        .name = "groq",
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
    .stream_live = streamLive,
};

fn deinit(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const self: *GroqAdapter = @ptrCast(@alignCast(ctx));
    if (self.api_key) |key| allocator.free(key);
    allocator.free(self.base_url);
    allocator.destroy(self);
}

fn listModels(ctx: *anyopaque, allocator: std.mem.Allocator) ![]types.ModelInfo {
    const self: *GroqAdapter = @ptrCast(@alignCast(ctx));

    if (self.api_key) |key| {
        const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{key});
        defer allocator.free(auth);

        const endpoint = try std.fmt.allocPrint(allocator, "{s}/v1/models", .{self.base_url});
        defer allocator.free(endpoint);

        const raw = common.callHttp(allocator, .GET, endpoint, &.{auth}, null, self.timeout_ms) catch {
            return staticModels(allocator);
        };
        {
            defer allocator.free(raw);
            if (parseDiscoveredModels(allocator, raw)) |models| return models else |err| {
                std.log.warn("groq: model discovery parse failed ({s}); falling back to built-in list", .{@errorName(err)});
            }
        }
    }

    return staticModels(allocator);
}

fn send(ctx: *anyopaque, allocator: std.mem.Allocator, request: types.ModelRequest) !types.ModelResponse {
    const self: *GroqAdapter = @ptrCast(@alignCast(ctx));

    const key = self.api_key orelse return error.MissingApiKey;
    const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{key});
    defer allocator.free(auth);

    var body_buf = std_io.StringBuilder.init(allocator);
    defer body_buf.deinit();

    const w = body_buf.writer();
    try w.writeAll("{\"model\":");
    try w.print("{f}", .{std.json.fmt(request.model, .{})});
    try w.writeAll(",\"messages\":");
    try common.writeMultiTurnMessages(w, &request);
    try w.print(",\"max_tokens\":{d}", .{request.max_output_tokens});
    try w.print(",\"temperature\":{d:.3}", .{request.temperature});
    try w.writeAll("}");

    // Inject native tools array for function calling
    common.appendToolsAndChoiceToBody(&body_buf, request.tool_schemas, request.tool_choice);
    common.appendResponseSchemaToBody(&body_buf, request.response_schema, request.response_schema_name);

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/v1/chat/completions", .{self.base_url});
    defer allocator.free(endpoint);

    var retries: u8 = 0;
    while (true) {
        if (retries > 0) try common.checkCancelled();
        if (!self.cb.allowRequest()) return error.CircuitBreakerOpen;

        const raw = common.callHttpJson(allocator, endpoint, &.{auth}, body_buf.items(), self.timeout_ms) catch |err| {
            self.cb.recordFailure();
            if (!common.shouldRetryHttpError(err) or retries >= self.retry_count) return err;
            const delay_ms = circuit_breaker.backoffDelayMs(retries, 100, 30_000);
            clock.sleepNanos(delay_ms * std.time.ns_per_ms);
            retries += 1;
            continue;
        };
        self.cb.recordSuccess();

        // Retry on 200+error-body responses (engine overloaded etc.)
        const err_kind = common.classifyErrorBody(allocator, raw);
        if (err_kind == .retryable and retries < self.retry_count) {
            const delay_ms = circuit_breaker.backoffDelayMs(retries, 100, 30_000);
            std.log.warn("groq: provider returned retryable error body, retry {d}/{d} after {d}ms", .{ retries + 1, self.retry_count, delay_ms });
            allocator.free(raw);
            clock.sleepNanos(delay_ms * std.time.ns_per_ms);
            retries += 1;
            continue;
        }

        const text = try common.extractFirstTextOrDupeRaw(allocator, raw);
        const native_tool_calls = common.extractNativeToolCalls(allocator, raw);
        const truncated = common.isResponseTruncated(allocator, raw);

        if (text.len > 0 or native_tool_calls.len > 0 or retries >= self.retry_count) {
            const usage = common.extractTokenUsage(allocator, raw);
            return .{
                .raw = raw,
                .text = text,
                .usage_input_tokens = usage.input_tokens orelse (tokenizer.estimateText("groq", request.model, request.system_prompt) + tokenizer.estimateText("groq", request.model, request.prompt)),
                .usage_output_tokens = usage.output_tokens orelse tokenizer.estimateText("groq", request.model, text),
                .tool_calls_json = native_tool_calls,
                .truncated = truncated,
            };
        }

        allocator.free(raw);
        allocator.free(text);
        if (native_tool_calls.len > 0) allocator.free(native_tool_calls);
        retries += 1;
    }
}

fn stream(ctx: *anyopaque, allocator: std.mem.Allocator, request: types.ModelRequest) ![]const u8 {
    const self: *GroqAdapter = @ptrCast(@alignCast(ctx));

    const key = self.api_key orelse return error.MissingApiKey;
    const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{key});
    defer allocator.free(auth);

    var body_buf = std_io.StringBuilder.init(allocator);
    defer body_buf.deinit();

    const w = body_buf.writer();
    try w.writeAll("{\"model\":");
    try w.print("{f}", .{std.json.fmt(request.model, .{})});
    try w.writeAll(",\"messages\":");
    try common.writeMultiTurnMessages(w, &request);
    try w.print(",\"max_tokens\":{d}", .{request.max_output_tokens});
    try w.print(",\"temperature\":{d:.3}", .{request.temperature});
    try w.writeAll(",\"stream\":true}");

    common.appendToolsAndChoiceToBody(&body_buf, request.tool_schemas, request.tool_choice);
    common.appendResponseSchemaToBody(&body_buf, request.response_schema, request.response_schema_name);

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/v1/chat/completions", .{self.base_url});
    defer allocator.free(endpoint);

    return common.callHttpJsonStream(allocator, endpoint, &.{auth}, body_buf.items(), self.timeout_ms);
}

fn streamLive(ctx: *anyopaque, allocator: std.mem.Allocator, request: types.ModelRequest, chunk_cb: ?common.StreamChunkCallback) ![]const u8 {
    const self: *GroqAdapter = @ptrCast(@alignCast(ctx));

    const key = self.api_key orelse return error.MissingApiKey;
    const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{key});
    defer allocator.free(auth);

    var body_buf = std_io.StringBuilder.init(allocator);
    defer body_buf.deinit();

    const w = body_buf.writer();
    try w.writeAll("{\"model\":");
    try w.print("{f}", .{std.json.fmt(request.model, .{})});
    try w.writeAll(",\"messages\":");
    try common.writeMultiTurnMessages(w, &request);
    try w.print(",\"max_tokens\":{d}", .{request.max_output_tokens});
    try w.print(",\"temperature\":{d:.3}", .{request.temperature});
    try w.writeAll(",\"stream\":true}");

    common.appendToolsAndChoiceToBody(&body_buf, request.tool_schemas, request.tool_choice);
    common.appendResponseSchemaToBody(&body_buf, request.response_schema, request.response_schema_name);

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/v1/chat/completions", .{self.base_url});
    defer allocator.free(endpoint);

    return common.callHttpJsonStreamWithCallback(allocator, endpoint, &.{auth}, body_buf.items(), self.timeout_ms, chunk_cb);
}

fn healthcheck(ctx: *anyopaque, allocator: std.mem.Allocator) !void {
    const self: *GroqAdapter = @ptrCast(@alignCast(ctx));
    if (self.api_key == null) return error.MissingApiKey;
    const models = try listModels(ctx, allocator);
    defer common.freeModelInfos(allocator, models);
}

fn staticModels(allocator: std.mem.Allocator) ![]types.ModelInfo {
    var out = std.array_list.Managed(types.ModelInfo).init(allocator);
    errdefer common.freeAndDeinitModelList(&out, allocator);
    try common.appendModelInfoOwned(allocator, &out, "llama-3.3-70b-versatile", "groq", 128_000);
    try common.appendModelInfoOwned(allocator, &out, "llama-3.1-8b-instant", "groq", 128_000);
    try common.appendModelInfoOwned(allocator, &out, "gemma2-9b-it", "groq", 8_192);
    return out.toOwnedSlice();
}

fn parseDiscoveredModels(allocator: std.mem.Allocator, json: []const u8) ![]types.ModelInfo {
    var parsed = try parse_helpers.parseJsonBounded(std.json.Value, allocator, json);
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidResponse;
    const data = parsed.value.object.get("data") orelse return error.InvalidResponse;
    if (data != .array) return error.InvalidResponse;

    var out = std.array_list.Managed(types.ModelInfo).init(allocator);
    errdefer common.freeAndDeinitModelList(&out, allocator);

    for (data.array.items) |item| {
        if (item != .object) continue;
        const id = item.object.get("id") orelse continue;
        if (id != .string) continue;

        try common.appendModelInfoOwned(allocator, &out, id.string, "groq", 128_000);
        if (out.items.len >= 64) break;
    }

    if (out.items.len == 0) return error.NoModels;
    return out.toOwnedSlice();
}

const testing = std.testing;
test "staticModels returns groq" {
    const alloc = testing.allocator;
    const m = try staticModels(alloc);
    defer common.freeModelInfos(alloc, m);
    try testing.expectEqualStrings("groq", m[0].provider);
}
