const std = @import("std");
const clock = @import("../core/clock.zig");
const std_io = @import("../core/std_io.zig");
const types = @import("../core/types.zig");
const common = @import("common.zig");
const tokenizer = @import("../core/tokenizer.zig");
const circuit_breaker = @import("circuit_breaker.zig");

const OpenRouterAdapter = struct {
    api_key: ?[]u8,
    base_url: []u8,
    site_url: []u8,
    timeout_ms: u32,
    retry_count: u8,
    cb: circuit_breaker.CircuitBreaker,
};

pub fn create(allocator: std.mem.Allocator, cfg: types.ProviderConfig) !types.ProviderAdapter {
    const adapter = try allocator.create(OpenRouterAdapter);

    // Read site URL from env for HTTP-Referer header
    const site_url = @import("../core/env.zig").getOwned(allocator, "OPENROUTER_SITE_URL") catch try allocator.dupe(u8, "https://github.com/Softorize/zcode");

    adapter.* = .{
        .api_key = if (cfg.api_key) |key| try allocator.dupe(u8, key) else null,
        .base_url = if (cfg.base_url) |v| try allocator.dupe(u8, v) else try allocator.dupe(u8, "https://openrouter.ai/api"),
        .site_url = site_url,
        .timeout_ms = cfg.timeout_ms,
        .retry_count = cfg.retry_count,
        .cb = circuit_breaker.CircuitBreaker.init(5, 30),
    };

    return .{
        .name = "openrouter",
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
    const self: *OpenRouterAdapter = @ptrCast(@alignCast(ctx));
    if (self.api_key) |key| allocator.free(key);
    allocator.free(self.base_url);
    allocator.free(self.site_url);
    allocator.destroy(self);
}

fn listModels(ctx: *anyopaque, allocator: std.mem.Allocator) ![]types.ModelInfo {
    const self: *OpenRouterAdapter = @ptrCast(@alignCast(ctx));

    if (self.api_key) |key| {
        const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{key});
        defer allocator.free(auth);
        const referer = try std.fmt.allocPrint(allocator, "HTTP-Referer: {s}", .{self.site_url});
        defer allocator.free(referer);

        const endpoint = try std.fmt.allocPrint(allocator, "{s}/v1/models", .{self.base_url});
        defer allocator.free(endpoint);

        const raw = common.callHttp(allocator, .GET, endpoint, &.{ auth, referer }, null, self.timeout_ms) catch {
            return staticModels(allocator);
        };
        {
            defer allocator.free(raw);
            if (parseDiscoveredModels(allocator, raw)) |models| return models else |err| {
                std.log.warn("openrouter: model discovery parse failed ({s}); falling back to built-in list", .{@errorName(err)});
            }
        }
    }

    return staticModels(allocator);
}

fn buildHeaders(allocator: std.mem.Allocator, self: *const OpenRouterAdapter) !struct { auth: []u8, referer: []u8, title: []u8 } {
    const key = self.api_key orelse return error.MissingApiKey;
    const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{key});
    errdefer allocator.free(auth);
    const referer = try std.fmt.allocPrint(allocator, "HTTP-Referer: {s}", .{self.site_url});
    errdefer allocator.free(referer);
    const title = try allocator.dupe(u8, "X-Title: zcode");
    return .{
        .auth = auth,
        .referer = referer,
        .title = title,
    };
}

fn send(ctx: *anyopaque, allocator: std.mem.Allocator, request: types.ModelRequest) !types.ModelResponse {
    const self: *OpenRouterAdapter = @ptrCast(@alignCast(ctx));

    const headers = try buildHeaders(allocator, self);
    defer allocator.free(headers.auth);
    defer allocator.free(headers.referer);
    defer allocator.free(headers.title);

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

    common.appendToolsAndChoiceToBody(&body_buf, request.tool_schemas, request.tool_choice);
    common.appendResponseSchemaToBody(&body_buf, request.response_schema, request.response_schema_name);

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/v1/chat/completions", .{self.base_url});
    defer allocator.free(endpoint);

    var retries: u8 = 0;
    while (true) {
        if (retries > 0) try common.checkCancelled();
        if (!self.cb.allowRequest()) return error.CircuitBreakerOpen;

        const raw = common.callHttpJson(allocator, endpoint, &.{ headers.auth, headers.referer, headers.title }, body_buf.items(), self.timeout_ms) catch |err| {
            self.cb.recordFailure();
            if (!common.shouldRetryHttpError(err) or retries >= self.retry_count) return err;
            const delay_ms = circuit_breaker.backoffDelayMs(retries, 100, 30_000);
            clock.sleepNanos(delay_ms * std.time.ns_per_ms);
            retries += 1;
            continue;
        };
        self.cb.recordSuccess();

        // Retry on 200+error-body responses (kimi/openai-compatible
        // upstream returns the engine-overloaded envelope this way).
        const err_kind = common.classifyErrorBody(allocator, raw);
        if (err_kind == .retryable and retries < self.retry_count) {
            const delay_ms = circuit_breaker.backoffDelayMs(retries, 100, 30_000);
            std.log.warn("openrouter: provider returned retryable error body, retry {d}/{d} after {d}ms", .{ retries + 1, self.retry_count, delay_ms });
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
                .usage_input_tokens = usage.input_tokens orelse (tokenizer.estimateText("openai", request.model, request.system_prompt) + tokenizer.estimateText("openai", request.model, request.prompt)),
                .usage_output_tokens = usage.output_tokens orelse tokenizer.estimateText("openai", request.model, text),
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
    const self: *OpenRouterAdapter = @ptrCast(@alignCast(ctx));

    const headers = try buildHeaders(allocator, self);
    defer allocator.free(headers.auth);
    defer allocator.free(headers.referer);
    defer allocator.free(headers.title);

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

    return common.callHttpJsonStream(allocator, endpoint, &.{ headers.auth, headers.referer, headers.title }, body_buf.items(), self.timeout_ms);
}

fn streamLive(ctx: *anyopaque, allocator: std.mem.Allocator, request: types.ModelRequest, chunk_cb: ?common.StreamChunkCallback) ![]const u8 {
    const self: *OpenRouterAdapter = @ptrCast(@alignCast(ctx));

    const headers = try buildHeaders(allocator, self);
    defer allocator.free(headers.auth);
    defer allocator.free(headers.referer);
    defer allocator.free(headers.title);

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

    return common.callHttpJsonStreamWithCallback(allocator, endpoint, &.{ headers.auth, headers.referer, headers.title }, body_buf.items(), self.timeout_ms, chunk_cb);
}

fn healthcheck(ctx: *anyopaque, allocator: std.mem.Allocator) !void {
    const self: *OpenRouterAdapter = @ptrCast(@alignCast(ctx));
    if (self.api_key == null) return error.MissingApiKey;
    const models = try listModels(ctx, allocator);
    defer common.freeModelInfos(allocator, models);
}

fn staticModels(allocator: std.mem.Allocator) ![]types.ModelInfo {
    var out = std.array_list.Managed(types.ModelInfo).init(allocator);
    errdefer common.freeAndDeinitModelList(&out, allocator);
    try common.appendModelInfoOwned(allocator, &out, "anthropic/claude-sonnet-4", "openrouter", 200_000);
    try common.appendModelInfoOwned(allocator, &out, "openai/gpt-4.1", "openrouter", 128_000);
    return out.toOwnedSlice();
}

fn parseDiscoveredModels(allocator: std.mem.Allocator, json: []const u8) ![]types.ModelInfo {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
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

        try common.appendModelInfoOwned(allocator, &out, id.string, "openrouter", 128_000);
        if (out.items.len >= 64) break;
    }

    if (out.items.len == 0) return error.NoModels;
    return out.toOwnedSlice();
}

const testing = std.testing;
test "staticModels returns openrouter" {
    const alloc = testing.allocator;
    const m = try staticModels(alloc);
    defer common.freeModelInfos(alloc, m);
    try testing.expectEqualStrings("openrouter", m[0].provider);
}
