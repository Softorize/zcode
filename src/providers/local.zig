const std = @import("std");
const rng = @import("../core/rng.zig");
const clock = @import("../core/clock.zig");
const std_io = @import("../core/std_io.zig");
const types = @import("../core/types.zig");
const common = @import("common.zig");
const tokenizer = @import("../core/tokenizer.zig");
const parse_helpers = @import("../core/parse_helpers.zig");
const egress = @import("../core/egress.zig");

const LocalAdapter = struct {
    base_url: []u8,
    timeout_ms: u32,
    retry_count: u8,
};

/// Build the `,"num_ctx":<N>` fragment for the Ollama options object.
/// Returns empty when the caller didn't request a specific window, so
/// Ollama falls through to its own VRAM-based default. Uses a small
/// thread-local-ish static buffer since the fragment is consumed by
/// `std.fmt.print` in the same expression.
threadlocal var num_ctx_buf: [40]u8 = undefined;

// The local provider exists specifically to talk to Ollama / llama.cpp /
// LM Studio on the loopback OR on a LAN host the user explicitly configured.
// allow_private_network_plaintext lets the egress policy permit http:// to
// 192.168.x.x / 10.x / 172.16-31.x without forcing the user to put a TLS
// terminator in front of their LAN Ollama box.
const local_provider_egress_policy: egress.Policy = .{
    .allow_private_network_plaintext = true,
};

fn numCtxFragment(context_window: usize) []const u8 {
    if (context_window == 0) return "";
    return std.fmt.bufPrint(&num_ctx_buf, ",\"num_ctx\":{d}", .{context_window}) catch "";
}

pub fn create(allocator: std.mem.Allocator, cfg: types.ProviderConfig) !types.ProviderAdapter {
    const adapter = try allocator.create(LocalAdapter);
    // Local models (especially large ones like 32B) need longer timeouts
    // for initial VRAM loading and generation. Minimum 10 minutes.
    const local_timeout = @max(cfg.timeout_ms, 600_000);
    adapter.* = .{
        .base_url = if (cfg.base_url) |v| try allocator.dupe(u8, v) else try allocator.dupe(u8, "http://127.0.0.1:11434"),
        .timeout_ms = local_timeout,
        .retry_count = cfg.retry_count,
    };

    return .{
        .name = "local",
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
    const self: *LocalAdapter = @ptrCast(@alignCast(ctx));
    allocator.free(self.base_url);
    allocator.destroy(self);
}

fn listModels(ctx: *anyopaque, allocator: std.mem.Allocator) ![]types.ModelInfo {
    const self: *LocalAdapter = @ptrCast(@alignCast(ctx));

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/api/tags", .{self.base_url});
    defer allocator.free(endpoint);

    const raw = common.callHttpWithPolicy(allocator, .GET, endpoint, &.{}, null, self.timeout_ms, local_provider_egress_policy) catch |err| {
        std.log.warn("local: model discovery failed: {s}", .{@errorName(err)});
        return staticModels(allocator);
    };
    {
        defer allocator.free(raw);
        if (parseDiscoveredModels(allocator, raw)) |models| return models else |err| {
            std.log.warn("local: model discovery parse failed ({s}); falling back to built-in list", .{@errorName(err)});
        }
    }

    return staticModels(allocator);
}

fn send(ctx: *anyopaque, allocator: std.mem.Allocator, request: types.ModelRequest) !types.ModelResponse {
    const self: *LocalAdapter = @ptrCast(@alignCast(ctx));

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/api/chat", .{self.base_url});
    defer allocator.free(endpoint);

    var body_buf = std_io.StringBuilder.init(allocator);
    defer body_buf.deinit();

    // Detect if this is a follow-up round (prompt contains tool results from previous execution).
    // If so, use text-based tool descriptions instead of native function calling, because
    // the prompt engine embeds tool results as text in the user message, which native
    // function calling can't see (it expects structured tool result messages).
    // First round (no tool results in prompt) = native function calling.
    // Subsequent rounds = text-based approach.
    const has_tool_results = std.mem.indexOf(u8, request.prompt, "tool=") != null or
        std.mem.indexOf(u8, request.prompt, "output=") != null or
        std.mem.indexOf(u8, request.prompt, "[tool]") != null;
    const use_native_tools = !has_tool_results and request.tool_schemas.len > 0;

    const system = if (use_native_tools)
        request.system_prompt
    else blk: {
        break :blk buildSystemPromptWithTools(allocator, request.system_prompt, request.tool_schemas) catch request.system_prompt;
    };
    const free_system = !use_native_tools and system.ptr != request.system_prompt.ptr;
    defer if (free_system) allocator.free(system);

    // Build multi-turn messages from structured history when available.
    // For local/Ollama we need to use the modified system prompt (which
    // may include inline tool schemas when native tools aren't used).
    const w = body_buf.writer();
    try w.writeAll("{\"model\":");
    try w.print("{f}", .{std.json.fmt(request.model, .{})});
    try w.writeAll(",\"messages\":");
    // Override system_prompt in the request for the multi-turn builder
    var local_request = request;
    local_request.system_prompt = system;
    try common.writeMultiTurnMessages(w, &local_request);
    try w.writeAll(",\"stream\":false,\"think\":false");
    try w.print(",\"options\":{{\"temperature\":{d:.3},\"num_predict\":{d}{s}}}", .{ request.temperature, request.max_output_tokens, numCtxFragment(request.context_window) });
    try w.writeAll("}");

    // Inject native tools for first-round calls only.
    if (use_native_tools) {
        common.appendToolsAndChoiceToBody(&body_buf, request.tool_schemas, request.tool_choice);
        common.appendResponseSchemaToBody(&body_buf, request.response_schema, request.response_schema_name);
    }

    var retries: u8 = 0;
    while (true) {
        if (retries > 0) try common.checkCancelled();
        const raw = common.callHttpJsonWithPolicy(allocator, endpoint, &.{}, body_buf.items(), self.timeout_ms, local_provider_egress_policy) catch |err| {
            if (!common.shouldRetryHttpError(err) or retries >= self.retry_count) return err;
            // Exponential backoff with jitter: 1s, 2s, 4s + random 0-500ms
            const base_delay_ms: u64 = @as(u64, 1000) << @intCast(@min(retries, 4));
            const jitter_ms: u64 = @as(u64, @intCast(rng.intRangeAtMost(u16, 0, 500)));
            const delay_ms = base_delay_ms + jitter_ms;
            std.log.warn("local: request failed ({s}), retry {d}/{d} after {d}ms", .{ @errorName(err), retries + 1, self.retry_count, delay_ms });
            clock.sleepNanos(delay_ms * std.time.ns_per_ms);
            retries += 1;
            continue;
        };
        // Extract text from content, falling back to thinking field for reasoning models.
        const text = try common.extractFirstTextOrDupeRaw(allocator, raw);
        const final_text = if (text.len == 0) blk: {
            allocator.free(text);
            break :blk extractThinkingField(allocator, raw) catch (allocator.dupe(u8, raw) catch |err| {
                allocator.free(raw);
                return err;
            });
        } else text;

        // Extract native tool_calls from Ollama response (message.tool_calls)
        const native_tool_calls = common.extractNativeToolCalls(allocator, raw);
        const truncated = isOllamaTruncated(allocator, raw);

        if (final_text.len > 0 or native_tool_calls.len > 0 or retries >= self.retry_count) {
            const usage = common.extractTokenUsage(allocator, raw);
            return .{
                .raw = raw,
                .text = final_text,
                .usage_input_tokens = usage.input_tokens orelse (tokenizer.estimateText("local", request.model, request.system_prompt) + tokenizer.estimateText("local", request.model, request.prompt)),
                .usage_output_tokens = usage.output_tokens orelse tokenizer.estimateText("local", request.model, final_text),
                .tool_calls_json = native_tool_calls,
                .truncated = truncated,
            };
        }

        allocator.free(raw);
        allocator.free(final_text);
        if (native_tool_calls.len > 0) allocator.free(native_tool_calls);
        retries += 1;
    }
}

fn stream(ctx: *anyopaque, allocator: std.mem.Allocator, request: types.ModelRequest) ![]const u8 {
    const self: *LocalAdapter = @ptrCast(@alignCast(ctx));

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/api/chat", .{self.base_url});
    defer allocator.free(endpoint);

    var body_buf = std_io.StringBuilder.init(allocator);
    defer body_buf.deinit();

    const system_with_tools = try buildSystemPromptWithTools(allocator, request.system_prompt, request.tool_schemas);
    defer allocator.free(system_with_tools);

    var local_request = request;
    local_request.system_prompt = system_with_tools;
    const w = body_buf.writer();
    try w.writeAll("{\"model\":");
    try w.print("{f}", .{std.json.fmt(request.model, .{})});
    try w.writeAll(",\"messages\":");
    try common.writeMultiTurnMessages(w, &local_request);
    try w.writeAll(",\"stream\":true,\"think\":false");
    try w.print(",\"options\":{{\"temperature\":{d:.3},\"num_predict\":{d}{s}}}", .{ request.temperature, request.max_output_tokens, numCtxFragment(request.context_window) });
    try w.writeAll("}");

    const raw = try common.callHttpJsonWithPolicy(allocator, endpoint, &.{}, body_buf.items(), self.timeout_ms, local_provider_egress_policy);
    defer allocator.free(raw);

    return parseOllamaStreamChunks(allocator, raw);
}

fn streamLive(ctx: *anyopaque, allocator: std.mem.Allocator, request: types.ModelRequest, chunk_cb: ?common.StreamChunkCallback) ![]const u8 {
    const self: *LocalAdapter = @ptrCast(@alignCast(ctx));

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/api/chat", .{self.base_url});
    defer allocator.free(endpoint);

    var body_buf = std_io.StringBuilder.init(allocator);
    defer body_buf.deinit();

    const system_with_tools = try buildSystemPromptWithTools(allocator, request.system_prompt, request.tool_schemas);
    defer allocator.free(system_with_tools);

    var local_request = request;
    local_request.system_prompt = system_with_tools;
    const w = body_buf.writer();
    try w.writeAll("{\"model\":");
    try w.print("{f}", .{std.json.fmt(request.model, .{})});
    try w.writeAll(",\"messages\":");
    try common.writeMultiTurnMessages(w, &local_request);
    try w.writeAll(",\"stream\":true,\"think\":false");
    try w.print(",\"options\":{{\"temperature\":{d:.3},\"num_predict\":{d}{s}}}", .{ request.temperature, request.max_output_tokens, numCtxFragment(request.context_window) });
    try w.writeAll("}");

    // For local providers, we use the streaming HTTP path which handles
    // both OpenAI-style SSE and Ollama JSONL formats via callHttpStreaming.
    // The chunk_cb fires for SSE data: lines. For Ollama JSONL, we'd need
    // separate parsing, but callHttpStreaming handles SSE by default.
    const raw = try common.callHttpStreamingWithPolicy(allocator, endpoint, &.{}, body_buf.items(), self.timeout_ms, chunk_cb, local_provider_egress_policy);
    defer allocator.free(raw);

    return parseOllamaStreamChunks(allocator, raw);
}

/// Core tools for local models -- keeps context small and responses fast.
fn isCoreLocalTool(name: []const u8) bool {
    const core = [_][]const u8{
        "Bash",  "bash",  "shell",
        "Read",  "read",  "file_read",
        "Write", "write", "file_write",
        "Edit",  "edit",  "file_edit",
        "Glob",  "glob",  "Grep",
        "grep",
    };
    for (core) |c| {
        if (std.mem.eql(u8, name, c)) return true;
    }
    return false;
}

/// Build a system prompt with tool descriptions appended as plain text.
/// This avoids native function calling (which requires multi-turn tool-result
/// messages) and instead lets the model use text-based tool calls that the
/// existing parser handles correctly.
fn buildSystemPromptWithTools(allocator: std.mem.Allocator, system_prompt: []const u8, tool_schemas: []const types.ToolSchema) ![]u8 {
    if (tool_schemas.len == 0) {
        return allocator.dupe(u8, system_prompt);
    }

    var buf = std_io.StringBuilder.init(allocator);
    errdefer buf.deinit();

    try buf.appendSlice(system_prompt);
    try buf.appendSlice(
        "\n\n# Available Tools\n\n" ++
            "You MUST use these tools to take action. NEVER tell the user to run commands themselves.\n" ++
            "You ARE the agent with direct access to the machine. Execute commands directly.\n\n" ++
            "Every tool listed below is available right now in this turn.\n" ++
            "Do not ask whether you should proceed with an actionable request. Start using tools.\n" ++
            "Only ask the user a question when a required fact or choice is truly missing.\n\n" ++
            "Do not print commands for the user to run when a tool can run them.\n\n" ++
            "To use a tool, include a tool_calls array in your JSON response:\n\n" ++
            "```json\n{\"tool_calls\": [{\"name\": \"<tool_name>\", \"args\": {<arguments>}}]}\n```\n\n" ++
            "Tools:\n",
    );

    const filter_tools = tool_schemas.len > 20;

    for (tool_schemas) |schema| {
        if (filter_tools and !isCoreLocalTool(schema.name) and !std.mem.startsWith(u8, schema.name, "mcp::")) {
            continue;
        }
        try buf.appendSlice("\n## ");
        try buf.appendSlice(schema.name);
        try buf.appendSlice("\n");
        try buf.appendSlice(schema.description);
        if (schema.usage_hint.len > 0) {
            try buf.appendSlice("\nUsage: ");
            try buf.appendSlice(schema.usage_hint);
        }
        try buf.appendSlice("\nParameters: ");
        try buf.appendSlice(schema.json_schema);
        try buf.appendSlice("\n");
    }

    return buf.toOwnedSlice();
}

fn healthcheck(ctx: *anyopaque, allocator: std.mem.Allocator) !void {
    const self: *LocalAdapter = @ptrCast(@alignCast(ctx));
    _ = self;

    const models = try listModels(ctx, allocator);
    defer freeModelInfos(allocator, models);
}

const freeModelInfos = common.freeModelInfos;

fn parseOllamaStreamChunks(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    // Some "local" endpoints expose OpenAI-style SSE (`data: {...}`) instead of
    // Ollama JSONL chunks. Parse via shared SSE parser in that case.
    if (std.mem.indexOf(u8, raw, "data:") != null) {
        return common.parseSseText(allocator, raw);
    }

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // Bounded parse: a hostile local provider (or a misconfigured
        // OLLAMA_BASE_URL pointed at attacker-controlled HTTPS, where
        // pass 73's chokepoint allows the connection but doesn't
        // validate content) could ship a 50 MB single-line "chunk"
        // designed to exhaust parser memory. parseJsonBounded caps
        // each value at 1 MiB, well past any legitimate streaming
        // chunk.
        var parsed = parse_helpers.parseJsonBounded(std.json.Value, allocator, trimmed) catch continue;
        defer parsed.deinit();

        if (parsed.value != .object) continue;
        if (parsed.value.object.get("message")) |msg| {
            if (msg == .object) {
                var appended = false;
                if (msg.object.get("content")) |content| {
                    if (content == .string and content.string.len > 0) {
                        try out.appendSlice(content.string);
                        appended = true;
                    }
                }
                // Reasoning-mode fallback: if content was empty for
                // this chunk, check thinking / reasoning_content so
                // the reconstructed stream reflects what the model
                // actually produced. Matches extractStreamingTextPiece.
                if (!appended) {
                    if (msg.object.get("thinking")) |t| {
                        if (t == .string and t.string.len > 0) {
                            try out.appendSlice(t.string);
                            appended = true;
                        }
                    }
                }
                if (!appended) {
                    if (msg.object.get("reasoning_content")) |rc| {
                        if (rc == .string and rc.string.len > 0) {
                            try out.appendSlice(rc.string);
                        }
                    }
                }
            }
        }
    }

    if (out.items().len == 0) return allocator.dupe(u8, raw);
    return out.toOwnedSlice();
}

const testing = std.testing;

test "parseOllamaStreamChunks parses SSE delta content" {
    const raw =
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n" ++
        "data: [DONE]\n";

    const parsed = try parseOllamaStreamChunks(testing.allocator, raw);
    defer testing.allocator.free(parsed);

    try testing.expectEqualStrings("Hello", parsed);
}

test "parseOllamaStreamChunks parses native Ollama JSONL" {
    const raw =
        "{\"message\":{\"content\":\"Hel\"}}\n" ++
        "{\"message\":{\"content\":\"lo\"}}\n";

    const parsed = try parseOllamaStreamChunks(testing.allocator, raw);
    defer testing.allocator.free(parsed);

    try testing.expectEqualStrings("Hello", parsed);
}

/// Check if Ollama truncated the response due to token limit.
/// Ollama uses done_reason:"length" (vs "stop" for normal completion).
fn isOllamaTruncated(allocator: std.mem.Allocator, response_json: []const u8) bool {
    // First check OpenAI-style finish_reason (some Ollama versions).
    if (common.isResponseTruncated(allocator, response_json)) return true;

    // Check Ollama-native done_reason field. Bounded parse so a
    // hostile-but-HTTPS upstream cannot exhaust memory via this
    // metadata-fetch path.
    var parsed = parse_helpers.parseJsonBounded(std.json.Value, allocator, response_json) catch return false;
    defer parsed.deinit();

    if (parsed.value != .object) return false;
    const reason = parsed.value.object.get("done_reason") orelse return false;
    if (reason != .string) return false;
    return std.mem.eql(u8, reason.string, "length");
}

/// Extract text from the thinking/reasoning_content field in Ollama responses.
/// Some models (Qwen3, DeepSeek-R1) put output in thinking instead of content.
fn extractThinkingField(allocator: std.mem.Allocator, response_json: []const u8) ![]u8 {
    var parsed = try parse_helpers.parseJsonBounded(std.json.Value, allocator, response_json);
    defer parsed.deinit();

    if (parsed.value != .object) return allocator.dupe(u8, "");
    const message = parsed.value.object.get("message") orelse return allocator.dupe(u8, "");
    if (message != .object) return allocator.dupe(u8, "");

    // Try thinking field first, then reasoning_content.
    const thinking = message.object.get("thinking") orelse message.object.get("reasoning_content") orelse return allocator.dupe(u8, "");
    if (thinking != .string) return allocator.dupe(u8, "");

    return allocator.dupe(u8, thinking.string);
}

fn staticModels(allocator: std.mem.Allocator) ![]types.ModelInfo {
    var out = std.array_list.Managed(types.ModelInfo).init(allocator);
    errdefer common.freeAndDeinitModelList(&out, allocator);
    try common.appendModelInfoOwned(allocator, &out, "qwen2.5-coder", "local", 32_768);
    try common.appendModelInfoOwned(allocator, &out, "llama3.1", "local", 32_768);
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
        if (name.string.len == 0) continue;

        try common.appendModelInfoOwned(allocator, &out, name.string, "local", 32_768);
        if (out.items.len >= 128) break;
    }

    if (out.items.len == 0) return error.NoModels;
    return out.toOwnedSlice();
}

test "buildSystemPromptWithTools appends tool descriptions" {
    const schemas = [_]types.ToolSchema{.{
        .name = "Bash",
        .description = "Run a shell command",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}}}",
    }};

    const result = try buildSystemPromptWithTools(testing.allocator, "You are helpful.", schemas[0..]);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "You are helpful.") != null);
    try testing.expect(std.mem.indexOf(u8, result, "## Bash") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Run a shell command") != null);
    try testing.expect(std.mem.indexOf(u8, result, "tool_calls") != null);
}

test "buildSystemPromptWithTools returns system prompt unchanged when no tools" {
    const result = try buildSystemPromptWithTools(testing.allocator, "You are helpful.", &.{});
    defer testing.allocator.free(result);

    try testing.expectEqualStrings("You are helpful.", result);
}
