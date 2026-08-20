const std = @import("std");
const clock = @import("../core/clock.zig");
const std_io = @import("../core/std_io.zig");
const types = @import("../core/types.zig");
const common = @import("common.zig");
const tokenizer = @import("../core/tokenizer.zig");
const circuit_breaker = @import("circuit_breaker.zig");
const parse_helpers = @import("../core/parse_helpers.zig");
const extractors = @import("extractors.zig");

const OpenAIAdapter = struct {
    api_key: ?[]u8,
    base_url: []u8,
    timeout_ms: u32,
    retry_count: u8,
    cb: circuit_breaker.CircuitBreaker,
};

pub fn create(allocator: std.mem.Allocator, cfg: types.ProviderConfig) !types.ProviderAdapter {
    const adapter = try allocator.create(OpenAIAdapter);
    adapter.* = .{
        .api_key = if (cfg.api_key) |key| try allocator.dupe(u8, key) else null,
        .base_url = if (cfg.base_url) |v| try allocator.dupe(u8, v) else try allocator.dupe(u8, "https://api.openai.com"),
        .timeout_ms = cfg.timeout_ms,
        .retry_count = cfg.retry_count,
        .cb = circuit_breaker.CircuitBreaker.init(5, 30),
    };

    return .{
        .name = "openai",
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
    const self: *OpenAIAdapter = @ptrCast(@alignCast(ctx));
    if (self.api_key) |key| allocator.free(key);
    allocator.free(self.base_url);
    allocator.destroy(self);
}

fn listModels(ctx: *anyopaque, allocator: std.mem.Allocator) ![]types.ModelInfo {
    const self: *OpenAIAdapter = @ptrCast(@alignCast(ctx));

    if (self.api_key) |key| {
        const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{key});
        defer allocator.free(auth);

        const endpoint = try std.fmt.allocPrint(allocator, "{s}/v1/models", .{self.base_url});
        defer allocator.free(endpoint);

        const raw = common.callHttp(allocator, .GET, endpoint, &.{auth}, null, self.timeout_ms) catch |err| {
            std.log.warn("openai: model discovery failed: {s}", .{@errorName(err)});
            return staticModels(allocator);
        };
        {
            defer allocator.free(raw);
            if (parseDiscoveredModels(allocator, raw)) |models| return models else |err| {
                std.log.warn("openai: model discovery parse failed ({s}); falling back to built-in list", .{@errorName(err)});
            }
        }
    }

    return staticModels(allocator);
}

fn send(ctx: *anyopaque, allocator: std.mem.Allocator, request: types.ModelRequest) !types.ModelResponse {
    const self: *OpenAIAdapter = @ptrCast(@alignCast(ctx));

    const key = self.api_key orelse return error.MissingApiKey;
    const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{key});
    defer allocator.free(auth);

    var body_buf = std_io.StringBuilder.init(allocator);
    defer body_buf.deinit();

    const tuning = modelTuning(request.model, request.temperature);
    const w = body_buf.writer();
    try w.writeAll("{\"model\":");
    try w.print("{f}", .{std.json.fmt(request.model, .{})});
    try w.writeAll(",\"messages\":");
    try common.writeMultiTurnMessages(w, &request);
    try w.print(",\"max_tokens\":{d}", .{request.max_output_tokens});
    try w.print(",\"temperature\":{d:.3}", .{tuning.temperature});
    if (tuning.disable_thinking) {
        try w.writeAll(",\"thinking\":{\"type\":\"disabled\"}");
    }
    try w.writeAll("}");

    // If the user has explicitly set /effort, splice the field into the
    // JSON body just before its closing brace. Only OpenAI's o-series and
    // gpt-5 family accept reasoning_effort today, so we only inject when
    // the model name looks like a reasoning model AND the user has
    // explicitly opted in via /effort (default `.auto` leaves the body
    // untouched so non-reasoning models like gpt-4o don't get hit with
    // a field the API will reject).
    try appendReasoningEffortIfNeeded(&body_buf, request);

    // Inject native tools array into request body for function calling
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
            std.log.warn("openai: request failed ({s}), retry {d}/{d}", .{ @errorName(err), retries + 1, self.retry_count });
            retries += 1;
            continue;
        };
        self.cb.recordSuccess();

        // Some openai-compatible endpoints (notably kimi/moonshot)
        // return HTTP 200 with an error envelope when the upstream
        // engine is overloaded:
        //   {"error":{"message":"The engine is currently overloaded,
        //   please try again later"}}
        // Without this guard, extractFirstTextOrDupeRaw would dupe
        // the raw body, see text.len > 0, and exit the retry loop
        // immediately -- the user has to retype every prompt and
        // gets the same error each time. Classify the body before
        // doing any text extraction so we can retry transparently.
        const err_kind = common.classifyErrorBody(allocator, raw);
        if (err_kind == .retryable and retries < self.retry_count) {
            const delay_ms = circuit_breaker.backoffDelayMs(retries, 100, 30_000);
            std.log.warn(
                "openai: provider returned retryable error body, retry {d}/{d} after {d}ms",
                .{ retries + 1, self.retry_count, delay_ms },
            );
            allocator.free(raw);
            clock.sleepNanos(delay_ms * std.time.ns_per_ms);
            retries += 1;
            continue;
        }

        const text = try common.extractFirstTextOrDupeRaw(allocator, raw);

        // Extract native tool_calls from API response (OpenAI function calling)
        const native_tool_calls = common.extractNativeToolCalls(allocator, raw);
        const truncated = common.isResponseTruncated(allocator, raw);
        const reasoning_text = extractors.extractReasoningText(allocator, raw) catch try allocator.dupe(u8, "");

        if (text.len > 0 or native_tool_calls.len > 0 or retries >= self.retry_count) {
            const usage = common.extractTokenUsage(allocator, raw);
            return .{
                .raw = raw,
                .text = text,
                .usage_input_tokens = usage.input_tokens orelse (tokenizer.estimateText("openai", request.model, request.system_prompt) + tokenizer.estimateText("openai", request.model, request.prompt)),
                .usage_output_tokens = usage.output_tokens orelse tokenizer.estimateText("openai", request.model, text),
                .tool_calls_json = native_tool_calls,
                .truncated = truncated,
                .reasoning_text = reasoning_text,
            };
        }

        allocator.free(raw);
        allocator.free(text);
        if (native_tool_calls.len > 0) allocator.free(native_tool_calls);
        allocator.free(reasoning_text);
        retries += 1;
    }
}

fn stream(ctx: *anyopaque, allocator: std.mem.Allocator, request: types.ModelRequest) ![]const u8 {
    const self: *OpenAIAdapter = @ptrCast(@alignCast(ctx));

    const key = self.api_key orelse return error.MissingApiKey;
    const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{key});
    defer allocator.free(auth);

    var body_buf = std_io.StringBuilder.init(allocator);
    defer body_buf.deinit();

    const tuning = modelTuning(request.model, request.temperature);
    const w = body_buf.writer();
    try w.writeAll("{\"model\":");
    try w.print("{f}", .{std.json.fmt(request.model, .{})});
    try w.writeAll(",\"messages\":");
    try common.writeMultiTurnMessages(w, &request);
    try w.print(",\"max_tokens\":{d}", .{request.max_output_tokens});
    try w.print(",\"temperature\":{d:.3}", .{tuning.temperature});
    if (tuning.disable_thinking) {
        try w.writeAll(",\"thinking\":{\"type\":\"disabled\"}");
    }
    try w.writeAll(",\"stream\":true}");

    try appendReasoningEffortIfNeeded(&body_buf, request);
    common.appendToolsAndChoiceToBody(&body_buf, request.tool_schemas, request.tool_choice);
    common.appendResponseSchemaToBody(&body_buf, request.response_schema, request.response_schema_name);

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/v1/chat/completions", .{self.base_url});
    defer allocator.free(endpoint);

    return common.callHttpJsonStream(allocator, endpoint, &.{auth}, body_buf.items(), self.timeout_ms);
}

fn streamLive(ctx: *anyopaque, allocator: std.mem.Allocator, request: types.ModelRequest, chunk_cb: ?common.StreamChunkCallback) ![]const u8 {
    const self: *OpenAIAdapter = @ptrCast(@alignCast(ctx));

    const key = self.api_key orelse return error.MissingApiKey;
    const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{key});
    defer allocator.free(auth);

    var body_buf = std_io.StringBuilder.init(allocator);
    defer body_buf.deinit();

    const tuning = modelTuning(request.model, request.temperature);
    const w = body_buf.writer();
    try w.writeAll("{\"model\":");
    try w.print("{f}", .{std.json.fmt(request.model, .{})});
    try w.writeAll(",\"messages\":");
    try common.writeMultiTurnMessages(w, &request);
    try w.print(",\"max_tokens\":{d}", .{request.max_output_tokens});
    try w.print(",\"temperature\":{d:.3}", .{tuning.temperature});
    if (tuning.disable_thinking) {
        try w.writeAll(",\"thinking\":{\"type\":\"disabled\"}");
    }
    try w.writeAll(",\"stream\":true}");

    try appendReasoningEffortIfNeeded(&body_buf, request);
    common.appendToolsAndChoiceToBody(&body_buf, request.tool_schemas, request.tool_choice);
    common.appendResponseSchemaToBody(&body_buf, request.response_schema, request.response_schema_name);

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/v1/chat/completions", .{self.base_url});
    defer allocator.free(endpoint);

    return common.callHttpJsonStreamWithCallback(allocator, endpoint, &.{auth}, body_buf.items(), self.timeout_ms, chunk_cb);
}

fn healthcheck(ctx: *anyopaque, allocator: std.mem.Allocator) !void {
    const self: *OpenAIAdapter = @ptrCast(@alignCast(ctx));
    if (self.api_key == null) return error.MissingApiKey;
    const models = try listModels(ctx, allocator);
    defer freeModelInfos(allocator, models);
}

const freeModelInfos = common.freeModelInfos;

fn staticModels(allocator: std.mem.Allocator) ![]types.ModelInfo {
    var out = std.array_list.Managed(types.ModelInfo).init(allocator);
    errdefer common.freeAndDeinitModelList(&out, allocator);
    try common.appendModelInfoOwned(allocator, &out, "gpt-4.1", "openai", 128_000);
    try common.appendModelInfoOwned(allocator, &out, "gpt-4.1-mini", "openai", 128_000);
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
        if (!isLikelyChatModel(id.string)) continue;

        try common.appendModelInfoOwned(allocator, &out, id.string, "openai", 128_000);
        if (out.items.len >= 64) break;
    }

    if (out.items.len == 0) return error.NoModels;
    return out.toOwnedSlice();
}

fn isLikelyChatModel(id: []const u8) bool {
    // OpenAI models.
    if (std.mem.startsWith(u8, id, "gpt-")) return true;
    if (std.mem.startsWith(u8, id, "o1") or std.mem.startsWith(u8, id, "o3") or std.mem.startsWith(u8, id, "o4")) return true;
    if (std.mem.startsWith(u8, id, "chatgpt-")) return true;
    // Common open-source model families (for openai-compatible endpoints).
    if (std.mem.startsWith(u8, id, "qwen")) return true;
    if (std.mem.startsWith(u8, id, "Qwen")) return true;
    if (std.mem.startsWith(u8, id, "llama")) return true;
    if (std.mem.startsWith(u8, id, "Llama")) return true;
    if (std.mem.startsWith(u8, id, "mistral")) return true;
    if (std.mem.startsWith(u8, id, "Mistral")) return true;
    if (std.mem.startsWith(u8, id, "deepseek")) return true;
    if (std.mem.startsWith(u8, id, "DeepSeek")) return true;
    if (std.mem.startsWith(u8, id, "gemma")) return true;
    if (std.mem.startsWith(u8, id, "phi")) return true;
    if (std.mem.startsWith(u8, id, "claude")) return true;
    if (std.mem.startsWith(u8, id, "command")) return true;
    if (std.mem.startsWith(u8, id, "yi-")) return true;
    if (std.mem.startsWith(u8, id, "kimi")) return true;
    if (std.mem.startsWith(u8, id, "codestral")) return true;
    // Fallback: accept any model with a slash (org/model format) or colon (ollama format).
    if (std.mem.indexOfScalar(u8, id, '/') != null) return true;
    if (std.mem.indexOfScalar(u8, id, ':') != null) return true;
    return false;
}

const ModelTuning = struct {
    temperature: f32,
    disable_thinking: bool = false,
};

fn modelTuning(model: []const u8, requested: f32) ModelTuning {
    // Per-model overrides live in src/core/model_tuning.zig so every
    // provider (anthropic, gemini, deepseek, groq, ...) can adopt the
    // same registry instead of scattering "if model == X" branches.
    const profile = @import("../core/model_tuning.zig").lookup(model);
    return .{
        .temperature = profile.temperature orelse requested,
        .disable_thinking = profile.disable_thinking,
    };
}

/// Splice a `reasoning_effort` field into an already-serialized JSON
/// body just before its closing brace, when (a) the user has
/// explicitly set /effort and (b) the active model accepts the
/// field. Shared by the non-streaming `send`, the stream-to-buffer
/// `stream`, and the live-streaming `streamLive` paths so all three
/// honor the user's /effort setting -- previously only `send` did,
/// which meant /effort silently did nothing on the default streaming
/// path (pass 43 regression, fixed in pass 48).
fn appendReasoningEffortIfNeeded(body_buf: *std_io.StringBuilder, request: types.ModelRequest) !void {
    if (request.reasoning_effort == .auto) return;
    if (!openaiModelAcceptsReasoningEffort(request.model)) return;
    if (body_buf.items().len == 0 or body_buf.items()[body_buf.items().len - 1] != '}') return;
    body_buf.shrinkRetainingCapacity(body_buf.items().len - 1);
    try body_buf.writer().print(",\"reasoning_effort\":\"{s}\"}}", .{request.reasoning_effort.toString()});
}

/// True when the model name looks like a reasoning-capable OpenAI model
/// that accepts a `reasoning_effort` field in the chat completions body.
/// Conservative allow-list: o1, o3, o4-mini, gpt-5 family. Other models
/// (gpt-4o, gpt-4.1, gpt-3.5) will reject the field with a 400, so we
/// leave them untouched. Matches Claude Code's modelSupportsEffort logic
/// (src/utils/effort.ts) applied to OpenAI's model naming conventions.
fn openaiModelAcceptsReasoningEffort(model: []const u8) bool {
    var buf: [64]u8 = undefined;
    const take = @min(model.len, buf.len);
    var i: usize = 0;
    while (i < take) : (i += 1) {
        buf[i] = std.ascii.toLower(model[i]);
    }
    const lower = buf[0..take];
    if (std.mem.startsWith(u8, lower, "o1")) return true;
    if (std.mem.startsWith(u8, lower, "o3")) return true;
    if (std.mem.startsWith(u8, lower, "o4")) return true;
    if (std.mem.startsWith(u8, lower, "gpt-5")) return true;
    if (std.mem.indexOf(u8, lower, "reason") != null) return true;
    return false;
}

const testing = std.testing;
test "isLikelyChatModel accepts gpt" {
    try testing.expect(isLikelyChatModel("gpt-4.1"));
}
test "isLikelyChatModel rejects embedding" {
    try testing.expect(!isLikelyChatModel("text-embedding-3-large"));
}
test "modelTuning kimi disables thinking" {
    const t = modelTuning("kimi-k2.5", 0.2);
    try testing.expect(t.disable_thinking);
}
test "modelTuning passthrough" {
    const t = modelTuning("gpt-4.1", 0.7);
    try testing.expectEqual(@as(f32, 0.7), t.temperature);
}
test "openaiModelAcceptsReasoningEffort accepts o-series and gpt-5" {
    try testing.expect(openaiModelAcceptsReasoningEffort("o1-preview"));
    try testing.expect(openaiModelAcceptsReasoningEffort("o3-mini"));
    try testing.expect(openaiModelAcceptsReasoningEffort("o4-mini"));
    try testing.expect(openaiModelAcceptsReasoningEffort("gpt-5"));
    try testing.expect(!openaiModelAcceptsReasoningEffort("gpt-4o"));
    try testing.expect(!openaiModelAcceptsReasoningEffort("gpt-4.1"));
}

test "appendReasoningEffortIfNeeded splices field for o-series" {
    var body = std_io.StringBuilder.init(testing.allocator);
    defer body.deinit();
    try body.appendSlice("{\"model\":\"o3-mini\",\"temperature\":0.2}");
    const req = types.ModelRequest{
        .model = "o3-mini",
        .prompt = "",
        .max_output_tokens = 1024,
        .reasoning_effort = .high,
    };
    try appendReasoningEffortIfNeeded(&body, req);
    try testing.expect(std.mem.indexOf(u8, body.items(), "\"reasoning_effort\":\"high\"") != null);
    try testing.expectEqual(@as(u8, '}'), body.items()[body.items().len - 1]);
}

test "appendReasoningEffortIfNeeded leaves gpt-4o body untouched" {
    var body = std_io.StringBuilder.init(testing.allocator);
    defer body.deinit();
    const original = "{\"model\":\"gpt-4o\",\"temperature\":0.2}";
    try body.appendSlice(original);
    const req = types.ModelRequest{
        .model = "gpt-4o",
        .prompt = "",
        .max_output_tokens = 1024,
        .reasoning_effort = .high,
    };
    try appendReasoningEffortIfNeeded(&body, req);
    try testing.expectEqualStrings(original, body.items());
}

test "appendReasoningEffortIfNeeded no-op when effort is auto" {
    var body = std_io.StringBuilder.init(testing.allocator);
    defer body.deinit();
    const original = "{\"model\":\"o3-mini\",\"temperature\":0.2}";
    try body.appendSlice(original);
    const req = types.ModelRequest{
        .model = "o3-mini",
        .prompt = "",
        .max_output_tokens = 1024,
        .reasoning_effort = .auto,
    };
    try appendReasoningEffortIfNeeded(&body, req);
    try testing.expectEqualStrings(original, body.items());
}
