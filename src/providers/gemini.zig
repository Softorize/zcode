const std = @import("std");
const clock = @import("../core/clock.zig");
const std_io = @import("../core/std_io.zig");
const types = @import("../core/types.zig");
const common = @import("common.zig");
const tokenizer = @import("../core/tokenizer.zig");
const circuit_breaker = @import("circuit_breaker.zig");
const parse_helpers = @import("../core/parse_helpers.zig");

const GeminiAdapter = struct {
    api_key: ?[]u8,
    base_url: []u8,
    timeout_ms: u32,
    retry_count: u8,
    cb: circuit_breaker.CircuitBreaker,
};

pub fn create(allocator: std.mem.Allocator, cfg: types.ProviderConfig) !types.ProviderAdapter {
    const adapter = try allocator.create(GeminiAdapter);
    adapter.* = .{
        .api_key = if (cfg.api_key) |key| try allocator.dupe(u8, key) else null,
        .base_url = if (cfg.base_url) |v| try allocator.dupe(u8, v) else try allocator.dupe(u8, "https://generativelanguage.googleapis.com/v1beta"),
        .timeout_ms = cfg.timeout_ms,
        .retry_count = cfg.retry_count,
        .cb = circuit_breaker.CircuitBreaker.init(5, 30),
    };

    return .{
        .name = "gemini",
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
    const self: *GeminiAdapter = @ptrCast(@alignCast(ctx));
    if (self.api_key) |key| allocator.free(key);
    allocator.free(self.base_url);
    allocator.destroy(self);
}

fn listModels(ctx: *anyopaque, allocator: std.mem.Allocator) ![]types.ModelInfo {
    const self: *GeminiAdapter = @ptrCast(@alignCast(ctx));

    if (self.api_key) |key| {
        const endpoint = try std.fmt.allocPrint(allocator, "{s}/models", .{self.base_url});
        defer allocator.free(endpoint);

        const auth_header = try std.fmt.allocPrint(allocator, "x-goog-api-key: {s}", .{key});
        defer allocator.free(auth_header);
        const headers = [_][]const u8{auth_header};

        const raw = common.callHttp(allocator, .GET, endpoint, &headers, null, self.timeout_ms) catch |err| {
            std.log.warn("gemini: model discovery failed: {s}", .{@errorName(err)});
            return staticModels(allocator);
        };
        {
            defer allocator.free(raw);
            if (parseDiscoveredModels(allocator, raw)) |models| return models else |err| {
                std.log.warn("gemini: model discovery parse failed ({s}); falling back to built-in list", .{@errorName(err)});
            }
        }
    }

    return staticModels(allocator);
}

/// Build the Gemini request body into body_buf.
/// Handles multi-turn history and elevates .system history turns into systemInstruction.
fn buildGeminiBody(body_buf: *std_io.StringBuilder, allocator: std.mem.Allocator, request: types.ModelRequest) !void {
    const w = body_buf.writer();

    // Collect .system history turns and append to base system prompt.
    // These are reprompt directives that must reach Gemini's authoritative
    // systemInstruction field, not be buried in contents.
    var sys_addendum = std_io.StringBuilder.init(allocator);
    defer sys_addendum.deinit();
    for (request.history) |turn| {
        if (turn.role != .system) continue;
        try sys_addendum.writer().writeAll("\n\n");
        try sys_addendum.writer().writeAll(turn.content);
    }

    const effective_system = if (sys_addendum.items().len > 0 and request.system_prompt.len > 0)
        try std.fmt.allocPrint(allocator, "{s}{s}", .{ request.system_prompt, sys_addendum.items() })
    else if (sys_addendum.items().len > 0)
        try allocator.dupe(u8, sys_addendum.items()[2..])
    else
        null;
    defer if (effective_system) |s| allocator.free(s);
    const final_system = effective_system orelse request.system_prompt;

    try w.writeAll("{");

    // Write systemInstruction if present
    if (final_system.len > 0) {
        try w.writeAll("\"systemInstruction\":{\"parts\":[{\"text\":");
        try w.print("{f}", .{std.json.fmt(final_system, .{})});
        try w.writeAll("}]},");
    }

    // Build contents array from history + current user turn
    try w.writeAll("\"contents\":[");
    var content_count: usize = 0;

    if (request.history.len > 0) {
        for (request.history) |turn| {
            // Skip .system turns -- they're elevated into systemInstruction above
            if (turn.role == .system) continue;
            const role: []const u8 = switch (turn.role) {
                .user, .tool => "user",
                .assistant => "model",
                .system => unreachable,
            };
            if (content_count > 0) try w.writeAll(",");
            try w.writeAll("{\"role\":");
            try w.print("{f}", .{std.json.fmt(role, .{})});
            try w.writeAll(",\"parts\":[");
            if (common.hasImageSegment(turn.content)) {
                try common.writeContentWithImagesGemini(w, turn.content);
            } else {
                try w.writeAll("{\"text\":");
                try w.print("{f}", .{std.json.fmt(turn.content, .{})});
                try w.writeAll("}");
            }
            try w.writeAll("]}");
            content_count += 1;
        }

        // Current user turn: extract from prompt (avoids duplicating history)
        const user_turn = extractCurrentUserTurn(request.prompt);
        if (user_turn.len > 0) {
            if (content_count > 0) try w.writeAll(",");
            try w.writeAll("{\"role\":\"user\",\"parts\":[");
            if (common.hasImageSegment(user_turn)) {
                try common.writeContentWithImagesGemini(w, user_turn);
            } else {
                try w.writeAll("{\"text\":");
                try w.print("{f}", .{std.json.fmt(user_turn, .{})});
                try w.writeAll("}");
            }
            try w.writeAll("]}");
        }
    } else {
        // No history: single user message with full prompt
        try w.writeAll("{\"role\":\"user\",\"parts\":[");
        if (common.hasImageSegment(request.prompt)) {
            try common.writeContentWithImagesGemini(w, request.prompt);
        } else {
            try w.writeAll("{\"text\":");
            try w.print("{f}", .{std.json.fmt(request.prompt, .{})});
            try w.writeAll("}");
        }
        try w.writeAll("]}");
    }

    try w.writeAll("]");
    try w.print(",\"generationConfig\":{{\"temperature\":{d:.3},\"maxOutputTokens\":{d}}}", .{ request.temperature, request.max_output_tokens });
    try w.writeAll("}");
}

/// Extract the [USER] section from a zcode flat-text prompt (same logic as common.extractCurrentUserTurn).
fn extractCurrentUserTurn(prompt: []const u8) []const u8 {
    const context_start = std.mem.indexOf(u8, prompt, "[CONTEXT]\n");
    const user_start = std.mem.indexOf(u8, prompt, "[USER]\n");
    if (context_start != null and user_start != null) {
        return prompt[@min(context_start.?, user_start.?)..];
    }
    if (user_start) |us| return prompt[us..];
    return prompt;
}

fn send(ctx: *anyopaque, allocator: std.mem.Allocator, request: types.ModelRequest) !types.ModelResponse {
    const self: *GeminiAdapter = @ptrCast(@alignCast(ctx));

    const key = self.api_key orelse return error.MissingApiKey;

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/models/{s}:generateContent", .{ self.base_url, request.model });
    defer allocator.free(endpoint);

    const auth_header = try std.fmt.allocPrint(allocator, "x-goog-api-key: {s}", .{key});
    defer allocator.free(auth_header);
    const headers = [_][]const u8{auth_header};

    var body_buf = std_io.StringBuilder.init(allocator);
    defer body_buf.deinit();

    try buildGeminiBody(&body_buf, allocator, request);

    var retries: u8 = 0;
    while (true) {
        if (retries > 0) try common.checkCancelled();
        if (!self.cb.allowRequest()) return error.CircuitBreakerOpen;

        const raw = common.callHttpJson(allocator, endpoint, &headers, body_buf.items(), self.timeout_ms) catch |err| {
            self.cb.recordFailure();
            if (!common.shouldRetryHttpError(err) or retries >= self.retry_count) return err;
            const delay_ms = circuit_breaker.backoffDelayMs(retries, 100, 30_000);
            clock.sleepNanos(delay_ms * std.time.ns_per_ms);
            std.log.warn("gemini: request failed ({s}), retry {d}/{d}", .{ @errorName(err), retries + 1, self.retry_count });
            retries += 1;
            continue;
        };
        self.cb.recordSuccess();
        const text = try common.extractFirstTextOrDupeRaw(allocator, raw);

        if (text.len > 0 or retries >= self.retry_count) {
            const usage = common.extractTokenUsage(allocator, raw);
            return .{
                .raw = raw,
                .text = text,
                .usage_input_tokens = usage.input_tokens orelse (tokenizer.estimateText("gemini", request.model, request.system_prompt) + tokenizer.estimateText("gemini", request.model, request.prompt)),
                .usage_output_tokens = usage.output_tokens orelse tokenizer.estimateText("gemini", request.model, text),
            };
        }

        allocator.free(raw);
        allocator.free(text);
        retries += 1;
    }
}

fn stream(ctx: *anyopaque, allocator: std.mem.Allocator, request: types.ModelRequest) ![]const u8 {
    const self: *GeminiAdapter = @ptrCast(@alignCast(ctx));

    const key = self.api_key orelse return error.MissingApiKey;
    const endpoint = try std.fmt.allocPrint(
        allocator,
        "{s}/models/{s}:streamGenerateContent?alt=sse",
        .{ self.base_url, request.model },
    );
    defer allocator.free(endpoint);

    const auth_header = try std.fmt.allocPrint(allocator, "x-goog-api-key: {s}", .{key});
    defer allocator.free(auth_header);
    const headers = [_][]const u8{auth_header};

    var body_buf = std_io.StringBuilder.init(allocator);
    defer body_buf.deinit();

    try buildGeminiBody(&body_buf, allocator, request);

    return common.callHttpJsonStream(allocator, endpoint, &headers, body_buf.items(), self.timeout_ms);
}

fn streamLive(ctx: *anyopaque, allocator: std.mem.Allocator, request: types.ModelRequest, chunk_cb: ?common.StreamChunkCallback) ![]const u8 {
    const self: *GeminiAdapter = @ptrCast(@alignCast(ctx));

    const key = self.api_key orelse return error.MissingApiKey;
    const endpoint = try std.fmt.allocPrint(
        allocator,
        "{s}/models/{s}:streamGenerateContent?alt=sse",
        .{ self.base_url, request.model },
    );
    defer allocator.free(endpoint);

    const auth_header = try std.fmt.allocPrint(allocator, "x-goog-api-key: {s}", .{key});
    defer allocator.free(auth_header);
    const headers = [_][]const u8{auth_header};

    var body_buf = std_io.StringBuilder.init(allocator);
    defer body_buf.deinit();

    try buildGeminiBody(&body_buf, allocator, request);

    return common.callHttpJsonStreamWithCallback(allocator, endpoint, &headers, body_buf.items(), self.timeout_ms, chunk_cb);
}

fn healthcheck(ctx: *anyopaque, allocator: std.mem.Allocator) !void {
    const self: *GeminiAdapter = @ptrCast(@alignCast(ctx));
    if (self.api_key == null) return error.MissingApiKey;
    const models = try listModels(ctx, allocator);
    defer freeModelInfos(allocator, models);
}

const freeModelInfos = common.freeModelInfos;

fn staticModels(allocator: std.mem.Allocator) ![]types.ModelInfo {
    var out = std.array_list.Managed(types.ModelInfo).init(allocator);
    errdefer common.freeAndDeinitModelList(&out, allocator);
    try common.appendModelInfoOwned(allocator, &out, "gemini-2.5-pro", "gemini", 1_000_000);
    try common.appendModelInfoOwned(allocator, &out, "gemini-2.5-flash", "gemini", 1_000_000);
    return out.toOwnedSlice();
}

fn parseDiscoveredModels(allocator: std.mem.Allocator, json: []const u8) ![]types.ModelInfo {
    var parsed = try parse_helpers.parseJsonBounded(std.json.Value, allocator, json);
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidResponse;
    const models = parsed.value.object.get("models") orelse return error.InvalidResponse;
    if (models != .array) return error.InvalidResponse;

    var out = std.array_list.Managed(types.ModelInfo).init(allocator);
    errdefer common.freeAndDeinitModelList(&out, allocator);

    for (models.array.items) |item| {
        if (item != .object) continue;
        const name = item.object.get("name") orelse continue;
        if (name != .string) continue;

        var id = name.string;
        if (std.mem.startsWith(u8, id, "models/")) {
            id = id["models/".len..];
        }
        if (!std.mem.startsWith(u8, id, "gemini-")) continue;

        try common.appendModelInfoOwned(allocator, &out, id, "gemini", 1_000_000);
        if (out.items.len >= 64) break;
    }

    if (out.items.len == 0) return error.NoModels;
    return out.toOwnedSlice();
}

const testing = std.testing;
test "staticModels returns gemini" {
    const alloc = testing.allocator;
    const m = try staticModels(alloc);
    defer common.freeModelInfos(alloc, m);
    try testing.expectEqualStrings("gemini", m[0].provider);
}

test "buildGeminiBody emits inline_data when prompt has zcode-image" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();

    const req = types.ModelRequest{
        .model = "gemini-2.0-flash",
        .prompt = "look at:\n<zcode-image media_type=\"image/jpeg\" ref=\"photo.jpg\">\n/9j/4AAQSkZJRg==\n</zcode-image>\nwhat is it?",
        .max_output_tokens = 128,
    };

    try buildGeminiBody(&buf, testing.allocator, req);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"inline_data\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"mime_type\":\"image/jpeg\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"data\":\"/9j/4AAQSkZJRg==\"") != null);
}
