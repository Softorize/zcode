const std = @import("std");
const clock = @import("../core/clock.zig");
const std_io = @import("../core/std_io.zig");
const types = @import("../core/types.zig");
const common = @import("common.zig");
const tokenizer = @import("../core/tokenizer.zig");
const circuit_breaker = @import("circuit_breaker.zig");
const parse_helpers = @import("../core/parse_helpers.zig");

const AnthropicAdapter = struct {
    api_key: ?[]u8,
    base_url: []u8,
    timeout_ms: u32,
    retry_count: u8,
    cb: circuit_breaker.CircuitBreaker,
};

pub fn create(allocator: std.mem.Allocator, cfg: types.ProviderConfig) !types.ProviderAdapter {
    const adapter = try allocator.create(AnthropicAdapter);
    adapter.* = .{
        .api_key = if (cfg.api_key) |key| try allocator.dupe(u8, key) else null,
        .base_url = if (cfg.base_url) |v| try allocator.dupe(u8, v) else try allocator.dupe(u8, "https://api.anthropic.com"),
        .timeout_ms = cfg.timeout_ms,
        .retry_count = cfg.retry_count,
        .cb = circuit_breaker.CircuitBreaker.init(5, 30),
    };

    return .{
        .name = "anthropic",
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
    const self: *AnthropicAdapter = @ptrCast(@alignCast(ctx));
    if (self.api_key) |key| allocator.free(key);
    allocator.free(self.base_url);
    allocator.destroy(self);
}

/// Build the comma-separated value for the `anthropic-beta` header.
/// Caller owns the returned slice. Returns null when no betas are
/// active (caller must skip the header entirely in that case -- an
/// empty string is rejected by the API). Kept in one place so the 3
/// request-emitting entrypoints (send/stream/streamLive) cannot drift.
fn buildAnthropicBetaValue(allocator: std.mem.Allocator, want_cache: bool, want_thinking: bool) !?[]u8 {
    // PRD #533: ZCODE_ANTHROPIC_BETA is an opt-in passthrough for additional
    // anthropic-beta tokens (comma-separated), e.g. Anthropic's context-
    // management / cache-editing beta for microcompaction cache edits. Default
    // unset -> no change, so an unsupported beta string can't break requests
    // unless the user enables it deliberately.
    const env_mod = @import("../core/env.zig");
    const extra = env_mod.getOwned(allocator, "ZCODE_ANTHROPIC_BETA") catch null;
    defer if (extra) |e| allocator.free(e);
    const extra_trimmed = if (extra) |e| std.mem.trim(u8, e, " \t\r\n") else "";
    const has_extra = extra_trimmed.len > 0;

    if (!want_cache and !want_thinking and !has_extra) return null;
    var buf = std_io.StringBuilder.init(allocator);
    errdefer buf.deinit();
    var wrote = false;
    if (want_cache) {
        try buf.writer().writeAll("prompt-caching-2024-07-31");
        wrote = true;
    }
    if (want_thinking) {
        if (wrote) try buf.writer().writeAll(",");
        try buf.writer().writeAll("interleaved-thinking-2025-05-14");
        wrote = true;
    }
    if (has_extra) {
        if (wrote) try buf.writer().writeAll(",");
        try buf.writer().writeAll(extra_trimmed);
    }
    return try buf.toOwnedSlice();
}

/// Build the per-request correlation / custom headers that ride alongside the
/// fixed auth + version headers. Returns an owned list of `Name: Value` header
/// lines (each string owned by the returned ArrayList's allocator). Caller
/// frees each item then deinits the list (see `freeExtraHeaders`).
///
/// Mirrors the reference's `getCustomHeaders` + per-request `x-client-request-id`
/// + `X-Claude-Code-Session-Id` injection (client.ts:330-389, :101-152),
/// zcode-namespaced:
///   - `X-Zcode-Session-Id: <session_id>` when `request.session_id` is non-empty.
///   - `x-client-request-id: <request_id>` when `request.request_id` is non-empty.
///   - each `request.custom_headers` entry verbatim (already `Name: Value`).
///
/// Pure with respect to IO: it only reads `request` and allocates strings, so it
/// is unit-testable without a live call (assert on the returned list).
fn buildExtraHeaders(allocator: std.mem.Allocator, request: types.ModelRequest) !std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer freeExtraHeaders(allocator, &list);

    if (request.session_id.len > 0) {
        const h = try std.fmt.allocPrint(allocator, "X-Zcode-Session-Id: {s}", .{request.session_id});
        try list.append(allocator, h);
    }
    if (request.request_id.len > 0) {
        const h = try std.fmt.allocPrint(allocator, "x-client-request-id: {s}", .{request.request_id});
        try list.append(allocator, h);
    }
    for (request.custom_headers) |h| {
        const dup = try allocator.dupe(u8, h);
        try list.append(allocator, dup);
    }
    return list;
}

fn freeExtraHeaders(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |h| allocator.free(h);
    list.deinit(allocator);
}

/// Merge the fixed base headers (auth, version, beta, accept) with the
/// per-request extra headers into a single owned slice the curl layer accepts.
/// `base` items are borrowed (caller still owns them); `extras` items are
/// borrowed from the `buildExtraHeaders` list (caller still owns that list).
/// Only the returned slice is owned by the caller here; free it with
/// `allocator.free` (it does NOT own the strings it points at).
fn mergeHeaders(
    allocator: std.mem.Allocator,
    base: []const []const u8,
    extras: []const []const u8,
) ![]const []const u8 {
    var out = try allocator.alloc([]const u8, base.len + extras.len);
    var i: usize = 0;
    for (base) |h| {
        out[i] = h;
        i += 1;
    }
    for (extras) |h| {
        out[i] = h;
        i += 1;
    }
    return out;
}

/// Extended-thinking-capable models that also support the
/// interleaved-thinking beta (reasoning text streamed between tool
/// calls). Limited to Anthropic's 4.x family per their docs.
fn modelSupportsInterleavedThinking(model: []const u8) bool {
    if (!modelSupportsExtendedThinking(model)) return false;
    // All current 4.x Anthropic models support it. Conservative match:
    // require the "claude-" prefix + a 4-series marker anywhere in name.
    if (!std.mem.startsWith(u8, model, "claude-")) return false;
    return std.mem.indexOf(u8, model, "-4-") != null or std.mem.indexOf(u8, model, "-4.") != null;
}

fn listModels(ctx: *anyopaque, allocator: std.mem.Allocator) ![]types.ModelInfo {
    const self: *AnthropicAdapter = @ptrCast(@alignCast(ctx));

    if (self.api_key) |key| {
        const key_header = try std.fmt.allocPrint(allocator, "x-api-key: {s}", .{key});
        defer allocator.free(key_header);

        const endpoint = try std.fmt.allocPrint(allocator, "{s}/v1/models", .{self.base_url});
        defer allocator.free(endpoint);

        const headers = [_][]const u8{ key_header, "anthropic-version: 2023-06-01" };
        const raw = common.callHttp(allocator, .GET, endpoint, headers[0..], null, self.timeout_ms) catch |err| {
            std.log.warn("anthropic: model discovery failed: {s}", .{@errorName(err)});
            return staticModels(allocator);
        };
        {
            defer allocator.free(raw);
            if (parseDiscoveredModels(allocator, raw)) |models| return models else |err| {
                std.log.warn("anthropic: model discovery parse failed ({s}); falling back to built-in list", .{@errorName(err)});
            }
        }
    }

    return staticModels(allocator);
}

fn send(ctx: *anyopaque, allocator: std.mem.Allocator, request: types.ModelRequest) !types.ModelResponse {
    const self: *AnthropicAdapter = @ptrCast(@alignCast(ctx));

    const key = self.api_key orelse return error.MissingApiKey;
    const key_header = try std.fmt.allocPrint(allocator, "x-api-key: {s}", .{key});
    defer allocator.free(key_header);

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/v1/messages", .{self.base_url});
    defer allocator.free(endpoint);

    var retries: u8 = 0;
    var try_cache_directive = request.cache_hints.len > 0 and shouldApplyCacheDirectives(request.prompt);
    while (true) {
        if (retries > 0) try common.checkCancelled();
        if (!self.cb.allowRequest()) return error.CircuitBreakerOpen;

        var body_buf = std_io.StringBuilder.init(allocator);
        defer body_buf.deinit();
        try writeRequestBody(body_buf.writer(), allocator, request, try_cache_directive);

        const want_thinking = request.reasoning_effort != .auto and modelSupportsInterleavedThinking(request.model);
        const beta_value = try buildAnthropicBetaValue(allocator, try_cache_directive, want_thinking);
        defer if (beta_value) |v| allocator.free(v);
        const beta_header = if (beta_value) |v| try std.fmt.allocPrint(allocator, "anthropic-beta: {s}", .{v}) else null;
        defer if (beta_header) |h| allocator.free(h);
        const headers_with_beta = if (beta_header) |h|
            [_][]const u8{ key_header, "anthropic-version: 2023-06-01", h }
        else
            [_][]const u8{ key_header, "anthropic-version: 2023-06-01", "" };
        const base_headers: []const []const u8 = if (beta_header != null) headers_with_beta[0..3] else headers_with_beta[0..2];

        var extra_headers = try buildExtraHeaders(allocator, request);
        defer freeExtraHeaders(allocator, &extra_headers);
        const headers = try mergeHeaders(allocator, base_headers, extra_headers.items);
        defer allocator.free(headers);

        const raw = common.callHttpJson(allocator, endpoint, headers, body_buf.items(), self.timeout_ms) catch |err| {
            self.cb.recordFailure();
            if (try_cache_directive and err == error.HttpStatusCode) {
                std.log.warn("anthropic: cache directive unsupported, retrying without cache", .{});
                try_cache_directive = false;
                continue;
            }
            if (!common.shouldRetryHttpError(err) or retries >= self.retry_count) return err;
            const delay_ms = circuit_breaker.backoffDelayMs(retries, 100, 30_000);
            clock.sleepNanos(delay_ms * std.time.ns_per_ms);
            std.log.warn("anthropic: request failed ({s}), retry {d}/{d}", .{ @errorName(err), retries + 1, self.retry_count });
            retries += 1;
            continue;
        };
        self.cb.recordSuccess();
        const text = try common.extractFirstTextOrDupeRaw(allocator, raw);

        // Extract native tool_use blocks from Anthropic's content array.
        // Previously missing -- every other provider called this but
        // Anthropic, so Claude's native function calling was invisible
        // and the raw JSON leaked into the displayed text.
        const native_tool_calls = common.extractNativeToolCalls(allocator, raw);
        const truncated = common.isResponseTruncated(allocator, raw);

        if (text.len > 0 or native_tool_calls.len > 0 or retries >= self.retry_count) {
            const usage = common.extractTokenUsage(allocator, raw);
            return .{
                .raw = raw,
                .text = text,
                .usage_input_tokens = usage.input_tokens orelse (tokenizer.estimateText("anthropic", request.model, request.system_prompt) + tokenizer.estimateText("anthropic", request.model, request.prompt)),
                .usage_output_tokens = usage.output_tokens orelse tokenizer.estimateText("anthropic", request.model, text),
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
    const self: *AnthropicAdapter = @ptrCast(@alignCast(ctx));

    const key = self.api_key orelse return error.MissingApiKey;
    const key_header = try std.fmt.allocPrint(allocator, "x-api-key: {s}", .{key});
    defer allocator.free(key_header);

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/v1/messages", .{self.base_url});
    defer allocator.free(endpoint);

    var body_buf = std_io.StringBuilder.init(allocator);
    defer body_buf.deinit();
    const use_cache = request.cache_hints.len > 0 and shouldApplyCacheDirectives(request.prompt);
    try writeRequestBody(body_buf.writer(), allocator, request, use_cache);
    // Anthropic requires "stream":true in the request body for SSE.
    // Without it the API returns a single JSON blob and parseSseText
    // falls through to raw-JSON extraction, making streaming a no-op.
    try spliceStreamFlag(&body_buf);

    const want_thinking = request.reasoning_effort != .auto and modelSupportsInterleavedThinking(request.model);
    const beta_value = try buildAnthropicBetaValue(allocator, use_cache, want_thinking);
    defer if (beta_value) |v| allocator.free(v);
    const beta_header = if (beta_value) |v| try std.fmt.allocPrint(allocator, "anthropic-beta: {s}", .{v}) else null;
    defer if (beta_header) |h| allocator.free(h);
    const headers_with_beta = if (beta_header) |h|
        [_][]const u8{ key_header, "anthropic-version: 2023-06-01", h, "Accept: text/event-stream" }
    else
        [_][]const u8{ key_header, "anthropic-version: 2023-06-01", "Accept: text/event-stream", "" };
    const base_headers: []const []const u8 = if (beta_header != null) headers_with_beta[0..4] else headers_with_beta[0..3];
    var extra_headers = try buildExtraHeaders(allocator, request);
    defer freeExtraHeaders(allocator, &extra_headers);
    const headers = try mergeHeaders(allocator, base_headers, extra_headers.items);
    defer allocator.free(headers);
    return common.callHttpJsonStream(allocator, endpoint, headers, body_buf.items(), self.timeout_ms);
}

fn streamLive(ctx: *anyopaque, allocator: std.mem.Allocator, request: types.ModelRequest, chunk_cb: ?common.StreamChunkCallback) ![]const u8 {
    const self: *AnthropicAdapter = @ptrCast(@alignCast(ctx));

    const key = self.api_key orelse return error.MissingApiKey;
    const key_header = try std.fmt.allocPrint(allocator, "x-api-key: {s}", .{key});
    defer allocator.free(key_header);

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/v1/messages", .{self.base_url});
    defer allocator.free(endpoint);

    var body_buf = std_io.StringBuilder.init(allocator);
    defer body_buf.deinit();
    const use_cache = request.cache_hints.len > 0 and shouldApplyCacheDirectives(request.prompt);
    try writeRequestBody(body_buf.writer(), allocator, request, use_cache);
    try spliceStreamFlag(&body_buf);

    const want_thinking = request.reasoning_effort != .auto and modelSupportsInterleavedThinking(request.model);
    const beta_value = try buildAnthropicBetaValue(allocator, use_cache, want_thinking);
    defer if (beta_value) |v| allocator.free(v);
    const beta_header = if (beta_value) |v| try std.fmt.allocPrint(allocator, "anthropic-beta: {s}", .{v}) else null;
    defer if (beta_header) |h| allocator.free(h);
    const headers_with_beta = if (beta_header) |h|
        [_][]const u8{ key_header, "anthropic-version: 2023-06-01", h, "Accept: text/event-stream" }
    else
        [_][]const u8{ key_header, "anthropic-version: 2023-06-01", "Accept: text/event-stream", "" };
    const base_headers: []const []const u8 = if (beta_header != null) headers_with_beta[0..4] else headers_with_beta[0..3];
    var extra_headers = try buildExtraHeaders(allocator, request);
    defer freeExtraHeaders(allocator, &extra_headers);
    const headers = try mergeHeaders(allocator, base_headers, extra_headers.items);
    defer allocator.free(headers);
    return common.callHttpJsonStreamWithCallback(allocator, endpoint, headers, body_buf.items(), self.timeout_ms, chunk_cb);
}

/// Append `,"stream":true` before the closing `}` of a JSON request
/// body. Called only on streaming paths so the non-streaming send()
/// keeps the normal JSON response format. The previous implementation
/// tried to splice after the opening `{` via copyBackwards but had a
/// buffer overrun: the destination slice was shorter than the source,
/// corrupting the request body and breaking the tools array.
fn spliceStreamFlag(body: *std_io.StringBuilder) !void {
    if (body.items().len == 0) return;
    if (body.items()[body.items().len - 1] == '}') {
        body.shrinkRetainingCapacity(body.items().len - 1);
        try body.writer().writeAll(",\"stream\":true}");
    }
}

const PromptSplit = struct {
    stable_prefix: []const u8,
    volatile_suffix: []const u8,
};

fn shouldApplyCacheDirectives(prompt: []const u8) bool {
    return prompt.len >= 1_024;
}

fn splitPromptForCache(prompt: []const u8) PromptSplit {
    if (std.mem.indexOf(u8, prompt, "[USER]\n")) |idx| {
        return .{
            .stable_prefix = prompt[0..idx],
            .volatile_suffix = prompt[idx..],
        };
    }

    if (std.mem.indexOf(u8, prompt, "\n[USER]")) |idx2| {
        return .{
            .stable_prefix = prompt[0..idx2],
            .volatile_suffix = prompt[idx2..],
        };
    }

    if (prompt.len < 1_024) {
        return .{
            .stable_prefix = "",
            .volatile_suffix = prompt,
        };
    }

    // Split at 70% — keep the majority as the stable prefix for caching, while
    // the volatile tail (recent user turns) changes between requests.
    const split_at = (prompt.len * 7) / 10;
    return .{
        .stable_prefix = prompt[0..split_at],
        .volatile_suffix = prompt[split_at..],
    };
}

/// True when the model name looks like an Anthropic model that
/// accepts the `thinking: {type: enabled, budget_tokens: N}` field
/// in its request body. Conservative allow-list: any model whose
/// lowercased name contains "opus-4", "sonnet-4", or "3.7-sonnet".
/// Other Claude models (claude-3-opus, claude-3-sonnet, claude-3-
/// haiku, claude-3.5-sonnet) will reject the field with a 400, so
/// we leave them untouched. Mirrors the modelSupportsEffort allow-
/// list in claude-code-main/src/utils/effort.ts for Anthropic-side
/// families.
fn modelSupportsExtendedThinking(model: []const u8) bool {
    var buf: [96]u8 = undefined;
    const take = @min(model.len, buf.len);
    var i: usize = 0;
    while (i < take) : (i += 1) {
        buf[i] = std.ascii.toLower(model[i]);
    }
    const lower = buf[0..take];
    if (std.mem.indexOf(u8, lower, "opus-4") != null) return true;
    if (std.mem.indexOf(u8, lower, "sonnet-4") != null) return true;
    if (std.mem.indexOf(u8, lower, "3.7-sonnet") != null) return true;
    return false;
}

/// Translate a ReasoningEffort level to a concrete Anthropic
/// `budget_tokens` value. Numbers chosen to match Claude Code's
/// effort defaults for opus-4.6 (low: 2048, medium: 8192,
/// high: 16000, max: 32000). `.auto` never reaches here -- the
/// caller checks and bails before calling.
fn budgetForEffort(effort: types.ReasoningEffort) u32 {
    return switch (effort) {
        .auto => 0,
        .low => 2048,
        .medium => 8192,
        .high => 16000,
        .max => 32000,
    };
}

fn writeRequestBody(writer: anytype, allocator: std.mem.Allocator, request: types.ModelRequest, use_cache_directive: bool) !void {
    const split = splitPromptForCache(request.prompt);
    const can_cache = use_cache_directive and split.stable_prefix.len > 0 and split.volatile_suffix.len > 0;

    // Figure out thinking mode before we write temperature -- extended
    // thinking requires temperature=1.0, and if we committed to some
    // other temperature up front we would have to go back and patch it.
    const use_thinking = request.reasoning_effort != .auto and modelSupportsExtendedThinking(request.model);
    const thinking_budget: u32 = if (use_thinking) budgetForEffort(request.reasoning_effort) else 0;

    // Collect .system history turns and elevate them into the Anthropic
    // system field. These are reprompt directives injected by zcode's
    // intent-detection loop. Anthropic's system field is the authoritative
    // instruction source -- they get ignored when buried as flat text in
    // the user message (where they appear as "system: <text>" in [HISTORY]).
    var reprompt_buf = std_io.StringBuilder.init(allocator);
    defer reprompt_buf.deinit();
    for (request.history) |turn| {
        if (turn.role != .system) continue;
        try reprompt_buf.writer().writeAll("\n\n");
        try reprompt_buf.writer().writeAll(turn.content);
    }
    const has_reprompt = reprompt_buf.items().len > 0;

    try writer.writeAll("{\"model\":");
    try writer.print("{f}", .{std.json.fmt(request.model, .{})});
    try writer.print(",\"max_tokens\":{d}", .{request.max_output_tokens});
    // Extended thinking demands temperature=1.0 or the API errors with
    // `temperature must be 1.0 when thinking is enabled`. When thinking
    // is on we force 1.0 regardless of the caller's setting -- the
    // user opted into thinking via /effort, the reasoning budget is
    // the feature they wanted, and the temperature constraint is a
    // hard API rule, not a zcode preference. For non-thinking
    // requests we pass through the caller's value clamped to [0, 1].
    if (use_thinking) {
        try writer.writeAll(",\"temperature\":1.000");
    } else {
        const clamped_temp: f32 = if (request.temperature < 0) 0 else if (request.temperature > 1) 1 else request.temperature;
        try writer.print(",\"temperature\":{d:.3}", .{clamped_temp});
    }
    if (use_thinking) {
        try writer.print(",\"thinking\":{{\"type\":\"enabled\",\"budget_tokens\":{d}}}", .{thinking_budget});
    }
    if (request.system_prompt.len > 0 or has_reprompt) {
        if (can_cache and !has_reprompt) {
            // PRD #533: cache the STATIC system prefix only. Split at the
            // static/dynamic boundary marker so per-turn dynamic content (env,
            // memory, skill listing) doesn't bust the cache -- previously the
            // whole system was one cached block, so any dynamic change missed
            // the cache every turn. Falls back to caching the whole system when
            // the marker is absent.
            const sp_boundary = "__SYSTEM_PROMPT_STATIC_BOUNDARY__";
            if (std.mem.indexOf(u8, request.system_prompt, sp_boundary)) |bidx| {
                const sp_split = bidx + sp_boundary.len;
                try writer.writeAll(",\"system\":[{\"type\":\"text\",\"text\":");
                try writer.print("{f}", .{std.json.fmt(request.system_prompt[0..sp_split], .{})});
                try writer.writeAll(",\"cache_control\":{\"type\":\"ephemeral\"}},{\"type\":\"text\",\"text\":");
                try writer.print("{f}", .{std.json.fmt(request.system_prompt[sp_split..], .{})});
                try writer.writeAll("}]");
            } else {
                try writer.writeAll(",\"system\":[{\"type\":\"text\",\"text\":");
                try writer.print("{f}", .{std.json.fmt(request.system_prompt, .{})});
                try writer.writeAll(",\"cache_control\":{\"type\":\"ephemeral\"}}]");
            }
        } else if (can_cache and has_reprompt) {
            // Two blocks: stable base (cached) + dynamic reprompt (not cached).
            try writer.writeAll(",\"system\":[{\"type\":\"text\",\"text\":");
            try writer.print("{f}", .{std.json.fmt(request.system_prompt, .{})});
            try writer.writeAll(",\"cache_control\":{\"type\":\"ephemeral\"}},{\"type\":\"text\",\"text\":");
            try writer.print("{f}", .{std.json.fmt(reprompt_buf.items()[2..], .{})});
            try writer.writeAll("}]");
        } else {
            // No caching: write base + any reprompt addendum as a plain string.
            try writer.writeAll(",\"system\":");
            if (has_reprompt) {
                const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ request.system_prompt, reprompt_buf.items() });
                defer allocator.free(combined);
                try writer.print("{f}", .{std.json.fmt(combined, .{})});
            } else {
                try writer.print("{f}", .{std.json.fmt(request.system_prompt, .{})});
            }
        }
    }
    try writer.writeAll(",\"messages\":[{\"role\":\"user\",\"content\":[");

    // If the flat prompt carries <zcode-image> blocks (from Read on an
    // image file or a clipboard paste), split them out into Anthropic
    // `{"type":"image",...}` content entries instead of dumping the raw
    // base64 into the text body — the model could not see the image
    // before, and the base64 silently consumed thousands of tokens per
    // paste. Caching is mutually exclusive with image-bearing prompts
    // in this path: cache splitting operates on a single contiguous
    // text buffer, so if images are present we fall through to the
    // plain image/text emission and skip the 2-block cache split.
    if (common.hasImageSegment(request.prompt)) {
        try common.writeContentWithImagesAnthropic(writer, request.prompt);
    } else if (can_cache) {
        try writer.writeAll("{\"type\":\"text\",\"text\":");
        try writer.print("{f}", .{std.json.fmt(split.stable_prefix, .{})});
        try writer.writeAll(",\"cache_control\":{\"type\":\"ephemeral\"}},");

        try writer.writeAll("{\"type\":\"text\",\"text\":");
        try writer.print("{f}", .{std.json.fmt(split.volatile_suffix, .{})});
        try writer.writeAll("}");
    } else {
        try writer.writeAll("{\"type\":\"text\",\"text\":");
        try writer.print("{f}", .{std.json.fmt(request.prompt, .{})});
        try writer.writeAll("}");
    }

    try writer.writeAll("]}]");

    // Emit Anthropic's native `tools` array so the model can produce
    // content[] entries of type tool_use. Previously the Anthropic
    // path had no tool wiring at all -- users on Anthropic fell
    // through to zcode's text-based protocol-fallback even though
    // their selected model supported native function calling. The
    // Anthropic shape is slightly different from OpenAI's: tools are
    // top-level objects with name/description/input_schema, NOT
    // wrapped in {type:function, function:{}}.
    // tool_choice maps to Anthropic's native object form. "auto"/"any"/"none"
    // become {"type":"auto"|"any"|"none"}; a tool name becomes
    // {"type":"tool","name":"<name>"}. Emit only when tool schemas exist --
    // Anthropic rejects tool_choice with no tools.
    if (request.tool_choice) |choice| {
        if (request.tool_schemas.len > 0) {
            try writer.writeAll(",\"tool_choice\":");
            if (std.mem.eql(u8, choice, "auto") or std.mem.eql(u8, choice, "any") or std.mem.eql(u8, choice, "none")) {
                try writer.print("{{\"type\":{f}}}", .{std.json.fmt(choice, .{})});
            } else {
                try writer.writeAll("{\"type\":\"tool\",\"name\":");
                try writer.print("{f}", .{std.json.fmt(choice, .{})});
                try writer.writeAll("}");
            }
        }
    }

    if (request.tool_schemas.len > 0) {
        try writer.writeAll(",\"tools\":[");
        for (request.tool_schemas, 0..) |schema, idx| {
            if (idx > 0) try writer.writeAll(",");
            try writer.writeAll("{\"name\":");
            try writer.print("{f}", .{std.json.fmt(schema.name, .{})});
            try writer.writeAll(",\"description\":");
            try writer.print("{f}", .{std.json.fmt(schema.description, .{})});
            try writer.writeAll(",\"input_schema\":");
            // json_schema is already a JSON object literal (string),
            // so embed it raw rather than quoting it into a string.
            try writer.writeAll(schema.json_schema);
            // Attach cache_control to the LAST tool entry so the entire
            // tools list (typically 5-20KB of JSON schema) is cached
            // across turns. Anthropic caches everything up to and
            // including the block that carries the directive. This
            // adds a 3rd breakpoint alongside the system-prompt and
            // user-content breakpoints already in place; Anthropic
            // allows up to 4 total per request.
            if (use_cache_directive and idx == request.tool_schemas.len - 1) {
                try writer.writeAll(",\"cache_control\":{\"type\":\"ephemeral\"}");
            }
            try writer.writeAll("}");
        }
        try writer.writeAll("]");
    }

    // Native context-management edits (opt-in via env, built by
    // core/context_management.zig). Embedded verbatim as a bare JSON
    // object, same contract as response_schema. Default null -> field
    // omitted, so non-supporting endpoints are never affected. Requires
    // the matching beta token in ZCODE_ANTHROPIC_BETA to take effect
    // server-side; emitting it without the beta is harmless (the server
    // ignores it).
    if (request.context_management) |cm| {
        if (cm.len > 0) {
            try writer.writeAll(",\"context_management\":");
            try writer.writeAll(cm);
        }
    }

    try writer.writeAll("}");
}

fn healthcheck(ctx: *anyopaque, allocator: std.mem.Allocator) !void {
    const self: *AnthropicAdapter = @ptrCast(@alignCast(ctx));
    if (self.api_key == null) return error.MissingApiKey;
    const models = try listModels(ctx, allocator);
    defer freeModelInfos(allocator, models);
}

const freeModelInfos = common.freeModelInfos;

fn staticModels(allocator: std.mem.Allocator) ![]types.ModelInfo {
    var out = std.array_list.Managed(types.ModelInfo).init(allocator);
    errdefer common.freeAndDeinitModelList(&out, allocator);
    try common.appendModelInfoOwned(allocator, &out, "claude-opus-4-6", "anthropic", 200_000);
    try common.appendModelInfoOwned(allocator, &out, "claude-sonnet-4-6", "anthropic", 200_000);
    try common.appendModelInfoOwned(allocator, &out, "claude-sonnet-4-5", "anthropic", 200_000);
    try common.appendModelInfoOwned(allocator, &out, "claude-haiku-4-5", "anthropic", 200_000);
    return out.toOwnedSlice();
}

fn parseDiscoveredModels(allocator: std.mem.Allocator, json: []const u8) ![]types.ModelInfo {
    // Bounded parse: a hostile or compromised provider could ship
    // a giant string literal or deeply-nested array as the /v1/models
    // response. parseJsonBounded pins 1 MiB per JSON value, well past
    // any legitimate model-discovery payload. Same defense as
    // parse_json.zig::parseNativeToolCallsJson (pass 104).
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
        if (!std.mem.startsWith(u8, id.string, "claude-")) continue;

        try common.appendModelInfoOwned(allocator, &out, id.string, "anthropic", 200_000);
        if (out.items.len >= 64) break;
    }

    if (out.items.len == 0) return error.NoModels;
    return out.toOwnedSlice();
}

const testing = std.testing;

test "writeRequestBody includes cache_control when enabled" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();

    const req = types.ModelRequest{
        .model = "claude-sonnet-4-5",
        .prompt = "[SYSTEM]\npolicy\n\n[USER]\nhello",
        .max_output_tokens = 256,
        .cache_hints = &.{.{ .key = "prefix", .ttl_seconds = 300 }},
    };

    try writeRequestBody(buf.writer(), testing.allocator, req, true);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"cache_control\"") != null);
}

test "writeRequestBody splits system at the static boundary and caches the prefix" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();

    const req = types.ModelRequest{
        .model = "claude-sonnet-4-5",
        .prompt = "[SYSTEM]\nsys\n\n[USER]\nhello",
        .system_prompt = "STATIC PREFIX\n__SYSTEM_PROMPT_STATIC_BOUNDARY__\nDYNAMIC TAIL",
        .max_output_tokens = 256,
        .cache_hints = &.{.{ .key = "prefix", .ttl_seconds = 300 }},
    };

    try writeRequestBody(buf.writer(), testing.allocator, req, true);
    const body = buf.items();
    // Both halves present; the static block's cache_control precedes the
    // dynamic tail (so the dynamic content is outside the cached prefix).
    try testing.expect(std.mem.indexOf(u8, body, "STATIC PREFIX") != null);
    try testing.expect(std.mem.indexOf(u8, body, "DYNAMIC TAIL") != null);
    const cc = std.mem.indexOf(u8, body, "\"cache_control\"") orelse return error.NoCacheControl;
    const dyn = std.mem.indexOf(u8, body, "DYNAMIC TAIL") orelse return error.NoDynamic;
    try testing.expect(cc < dyn);
}

test "writeRequestBody emits Anthropic tool_choice shapes" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();

    const schemas = [_]types.ToolSchema{.{ .name = "search", .description = "x", .json_schema = "{}" }};
    var req = types.ModelRequest{
        .model = "claude-sonnet-4-5",
        .prompt = "[USER]\nhi",
        .max_output_tokens = 128,
        .tool_schemas = &schemas,
        .tool_choice = "any",
    };

    try writeRequestBody(buf.writer(), testing.allocator, req, false);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"tool_choice\":{\"type\":\"any\"}") != null);

    buf.clearRetainingCapacity();
    req.tool_choice = "search";
    try writeRequestBody(buf.writer(), testing.allocator, req, false);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"tool_choice\":{\"type\":\"tool\",\"name\":\"search\"}") != null);

    // No tool_choice field when schemas missing, even if requested.
    buf.clearRetainingCapacity();
    req.tool_schemas = &.{};
    req.tool_choice = "any";
    try writeRequestBody(buf.writer(), testing.allocator, req, false);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"tool_choice\"") == null);
}

test "writeRequestBody caches tools array with cache_control on last tool" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();

    const schemas = [_]types.ToolSchema{
        .{ .name = "read", .description = "read a file", .json_schema = "{}" },
        .{ .name = "edit", .description = "edit a file", .json_schema = "{}" },
    };
    const req = types.ModelRequest{
        .model = "claude-sonnet-4-5",
        .system_prompt = "base-system",
        .prompt = "[SYSTEM]\npolicy\n\n[USER]\nhello",
        .max_output_tokens = 256,
        .tool_schemas = &schemas,
        .cache_hints = &.{.{ .key = "prefix", .ttl_seconds = 300 }},
    };

    try writeRequestBody(buf.writer(), testing.allocator, req, true);

    // With caching: expect system-prompt, user-prefix, last-tool cache_controls.
    var count: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, buf.items(), start, "\"cache_control\"")) |at| {
        count += 1;
        start = at + 1;
    }
    try testing.expect(count >= 3);

    // The last "edit" tool should be the one carrying cache_control, not the first.
    const edit_pos = std.mem.indexOf(u8, buf.items(), "\"name\":\"edit\"") orelse return error.TestUnexpectedResult;
    const edit_cache_after = std.mem.indexOfPos(u8, buf.items(), edit_pos, "\"cache_control\"") orelse return error.TestUnexpectedResult;
    const read_pos = std.mem.indexOf(u8, buf.items(), "\"name\":\"read\"") orelse return error.TestUnexpectedResult;
    try testing.expect(edit_cache_after > edit_pos);
    // Make sure there is no cache_control between the first tool and the second tool.
    const no_cache_between = std.mem.indexOfPos(u8, buf.items(), read_pos, "\"cache_control\"") orelse return error.TestUnexpectedResult;
    try testing.expect(no_cache_between > std.mem.indexOfPos(u8, buf.items(), read_pos, "\"name\":\"edit\"").?);
}

test "writeRequestBody emits Anthropic image blocks when prompt has zcode-image" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();

    const req = types.ModelRequest{
        .model = "claude-sonnet-4-5",
        .prompt = "describe:\n<zcode-image media_type=\"image/png\" ref=\"screenshot.png\">\niVBORw0KGgoAAAANSUhEUgAAAAE=\n</zcode-image>\ngo.",
        .max_output_tokens = 256,
    };

    try writeRequestBody(buf.writer(), testing.allocator, req, false);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"type\":\"image\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"media_type\":\"image/png\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"data\":\"iVBORw0KGgoAAAANSUhEUgAAAAE=\"") != null);
}

test "writeRequestBody omits cache_control when disabled" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();

    const req = types.ModelRequest{
        .model = "claude-sonnet-4-5",
        .prompt = "[USER]\nhello",
        .max_output_tokens = 256,
    };

    try writeRequestBody(buf.writer(), testing.allocator, req, false);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"cache_control\"") == null);
}

test "writeRequestBody includes system field when present" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();

    const req = types.ModelRequest{
        .model = "claude-sonnet-4-5",
        .system_prompt = "runtime policy",
        .prompt = "[USER]\nhello",
        .max_output_tokens = 256,
    };

    try writeRequestBody(buf.writer(), testing.allocator, req, false);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"system\":\"runtime policy\"") != null);
}

test "writeRequestBody passes caller temperature through" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();
    const req = types.ModelRequest{
        .model = "claude-sonnet-4-5",
        .prompt = "[USER]\nhi",
        .max_output_tokens = 128,
        .temperature = 0.3,
    };
    try writeRequestBody(buf.writer(), testing.allocator, req, false);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"temperature\":0.300") != null);
}

test "writeRequestBody clamps temperature above 1.0 to 1.0" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();
    const req = types.ModelRequest{
        .model = "claude-sonnet-4-5",
        .prompt = "[USER]\nhi",
        .max_output_tokens = 128,
        .temperature = 2.5,
    };
    try writeRequestBody(buf.writer(), testing.allocator, req, false);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"temperature\":1.000") != null);
}

test "writeRequestBody clamps negative temperature to 0.0" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();
    const req = types.ModelRequest{
        .model = "claude-sonnet-4-5",
        .prompt = "[USER]\nhi",
        .max_output_tokens = 128,
        .temperature = -0.5,
    };
    try writeRequestBody(buf.writer(), testing.allocator, req, false);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"temperature\":0.000") != null);
}

test "writeRequestBody emits thinking block on Claude 4 with /effort high" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();
    const req = types.ModelRequest{
        .model = "claude-opus-4-6",
        .prompt = "[USER]\nhi",
        .max_output_tokens = 4096,
        .temperature = 0.3,
        .reasoning_effort = .high,
    };
    try writeRequestBody(buf.writer(), testing.allocator, req, false);
    // High maps to budget 16000.
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":16000}") != null);
    // Thinking forces temperature=1.0 regardless of caller's 0.3.
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"temperature\":1.000") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"temperature\":0.300") == null);
}

test "writeRequestBody leaves thinking off on Claude 3.5 even with /effort max" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();
    const req = types.ModelRequest{
        .model = "claude-3-5-sonnet-latest",
        .prompt = "[USER]\nhi",
        .max_output_tokens = 2048,
        .temperature = 0.5,
        .reasoning_effort = .max,
    };
    try writeRequestBody(buf.writer(), testing.allocator, req, false);
    // Claude 3.5 doesn't accept extended thinking -- skip the splice.
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"thinking\"") == null);
    // Non-thinking path keeps the caller's temperature.
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"temperature\":0.500") != null);
}

test "writeRequestBody leaves thinking off when /effort is auto" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();
    const req = types.ModelRequest{
        .model = "claude-opus-4-6",
        .prompt = "[USER]\nhi",
        .max_output_tokens = 2048,
        .temperature = 0.2,
        .reasoning_effort = .auto,
    };
    try writeRequestBody(buf.writer(), testing.allocator, req, false);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"thinking\"") == null);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"temperature\":0.200") != null);
}

test "modelSupportsExtendedThinking allow-list" {
    try testing.expect(modelSupportsExtendedThinking("claude-opus-4-6"));
    try testing.expect(modelSupportsExtendedThinking("claude-sonnet-4-5"));
    try testing.expect(modelSupportsExtendedThinking("claude-3.7-sonnet"));
    try testing.expect(!modelSupportsExtendedThinking("claude-3-5-sonnet-20240620"));
    try testing.expect(!modelSupportsExtendedThinking("claude-3-haiku"));
    try testing.expect(!modelSupportsExtendedThinking("gpt-4"));
}

test "writeRequestBody emits native tools array in Anthropic format" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();
    const schemas = [_]types.ToolSchema{
        .{
            .name = "Read",
            .description = "Read a file",
            .json_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}",
        },
    };
    const req = types.ModelRequest{
        .model = "claude-sonnet-4-5",
        .prompt = "[USER]\nhi",
        .max_output_tokens = 256,
        .tool_schemas = &schemas,
    };
    try writeRequestBody(buf.writer(), testing.allocator, req, false);
    // Top-level tools array in Anthropic shape -- no type:function wrapper.
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"tools\":[{\"name\":\"Read\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"input_schema\":{\"type\":\"object\"") != null);
    // Should NOT contain OpenAI-style function wrapper.
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"type\":\"function\"") == null);
}

test "writeRequestBody omits tools array when no schemas" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();
    const req = types.ModelRequest{
        .model = "claude-sonnet-4-5",
        .prompt = "[USER]\nhi",
        .max_output_tokens = 256,
    };
    try writeRequestBody(buf.writer(), testing.allocator, req, false);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"tools\"") == null);
}

test "writeRequestBody emits context_management when request carries one" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();
    const req = types.ModelRequest{
        .model = "claude-sonnet-4-5",
        .prompt = "[USER]\nhi",
        .max_output_tokens = 256,
        .context_management = "{\"edits\":[{\"type\":\"clear_thinking_20251015\",\"keep\":\"all\"}]}",
    };
    try writeRequestBody(buf.writer(), testing.allocator, req, false);
    // The field is embedded verbatim as a bare object (not quoted).
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"context_management\":{\"edits\":[") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "clear_thinking_20251015") != null);
}

test "writeRequestBody omits context_management when none and when empty" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();
    // No field set.
    var req = types.ModelRequest{
        .model = "claude-sonnet-4-5",
        .prompt = "[USER]\nhi",
        .max_output_tokens = 256,
    };
    try writeRequestBody(buf.writer(), testing.allocator, req, false);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "context_management") == null);

    // Empty string also omits.
    buf.clearRetainingCapacity();
    req.context_management = "";
    try writeRequestBody(buf.writer(), testing.allocator, req, false);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "context_management") == null);
}

test "writeRequestBody elevates system history turns into system field" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();
    const history = [_]types.HistoryTurn{
        .{ .role = .user, .content = "implement X", .timestamp = 0 },
        .{ .role = .assistant, .content = "I'll implement X...", .timestamp = 0 },
        .{ .role = .system, .content = "Action required: use tool_calls now.", .timestamp = 0 },
    };
    const req = types.ModelRequest{
        .model = "claude-sonnet-4-5",
        .system_prompt = "base policy",
        .prompt = "[USER]\nimplement X",
        .max_output_tokens = 256,
        .history = &history,
    };
    try writeRequestBody(buf.writer(), testing.allocator, req, false);
    // System field must contain both base policy and the reprompt instruction.
    try testing.expect(std.mem.indexOf(u8, buf.items(), "base policy") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "Action required: use tool_calls now.") != null);
}

fn headerListContains(headers: []const []const u8, needle: []const u8) bool {
    for (headers) |h| {
        if (std.mem.indexOf(u8, h, needle) != null) return true;
    }
    return false;
}

test "buildExtraHeaders injects session-id header when session_id set" {
    const req = types.ModelRequest{
        .model = "claude-sonnet-4-5",
        .prompt = "hi",
        .max_output_tokens = 64,
        .session_id = "sess-abc-123",
    };
    var extras = try buildExtraHeaders(testing.allocator, req);
    defer freeExtraHeaders(testing.allocator, &extras);

    try testing.expect(headerListContains(extras.items, "X-Zcode-Session-Id: sess-abc-123"));
}

test "buildExtraHeaders injects request-id and custom headers; omits absent ones" {
    const custom = [_][]const u8{ "X-Team: platform", "X-Trace: t-9" };
    const req = types.ModelRequest{
        .model = "claude-sonnet-4-5",
        .prompt = "hi",
        .max_output_tokens = 64,
        .request_id = "req-xyz",
        .custom_headers = &custom,
        // session_id intentionally left empty -- must NOT appear.
    };
    var extras = try buildExtraHeaders(testing.allocator, req);
    defer freeExtraHeaders(testing.allocator, &extras);

    try testing.expect(headerListContains(extras.items, "x-client-request-id: req-xyz"));
    try testing.expect(headerListContains(extras.items, "X-Team: platform"));
    try testing.expect(headerListContains(extras.items, "X-Trace: t-9"));
    try testing.expect(!headerListContains(extras.items, "X-Zcode-Session-Id"));
}

test "buildExtraHeaders empty when nothing set" {
    const req = types.ModelRequest{
        .model = "claude-sonnet-4-5",
        .prompt = "hi",
        .max_output_tokens = 64,
    };
    var extras = try buildExtraHeaders(testing.allocator, req);
    defer freeExtraHeaders(testing.allocator, &extras);
    try testing.expectEqual(@as(usize, 0), extras.items.len);
}

test "mergeHeaders appends extras after base preserving order" {
    const base = [_][]const u8{ "x-api-key: k", "anthropic-version: 2023-06-01" };
    const extras = [_][]const u8{ "X-Zcode-Session-Id: s", "x-client-request-id: r" };
    const merged = try mergeHeaders(testing.allocator, &base, &extras);
    defer testing.allocator.free(merged);

    try testing.expectEqual(@as(usize, 4), merged.len);
    try testing.expectEqualStrings("x-api-key: k", merged[0]);
    try testing.expectEqualStrings("anthropic-version: 2023-06-01", merged[1]);
    try testing.expectEqualStrings("X-Zcode-Session-Id: s", merged[2]);
    try testing.expectEqualStrings("x-client-request-id: r", merged[3]);
}
