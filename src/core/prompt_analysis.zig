const std = @import("std");
const std_io = @import("std_io.zig");

const types = @import("types.zig");
const tokenizer = @import("tokenizer.zig");
const prompt_helpers = @import("prompt_helpers.zig");

pub const DuplicateRead = struct {
    path: []u8,
    count: usize,

    pub fn deinit(self: *DuplicateRead, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

/// Per-tool token aggregation across all calls of a single tool name.
/// Mirrors the reference's `toolRequests` / `toolResults` maps keyed by
/// tool name (utils/contextAnalysis.ts:27-80). zcode history turns are
/// flat text, so we split a tool turn into the "request" part (the
/// `tool=`/`args=` header up to the `output=` marker) and the "result"
/// part (everything from `output=` onward). This is best-effort: the
/// request/result split is approximate because args can contain newlines,
/// but the aggregate per-tool total is exact.
pub const ToolUsage = struct {
    name: []u8,
    request_tokens: usize = 0,
    result_tokens: usize = 0,
    calls: usize = 0,

    pub fn totalTokens(self: ToolUsage) usize {
        return self.request_tokens + self.result_tokens;
    }

    pub fn deinit(self: *ToolUsage, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const Analysis = struct {
    full_tokens: usize = 0,
    system_tokens: usize = 0,
    user_packet_tokens: usize = 0,
    working_context_tokens: usize = 0,
    preprocessor_hint_tokens: usize = 0,
    instruction_tokens: usize = 0,
    tool_schema_tokens: usize = 0,
    history_tokens: usize = 0,
    user_history_tokens: usize = 0,
    assistant_history_tokens: usize = 0,
    system_history_tokens: usize = 0,
    tool_result_tokens: usize = 0,
    context_tokens: usize = 0,
    memory_context_tokens: usize = 0,
    git_context_tokens: usize = 0,
    file_context_tokens: usize = 0,
    duplicate_reads: []DuplicateRead = &.{},
    largest_tool_result_name: []u8 = &.{},
    largest_tool_result_tokens: usize = 0,
    /// Per-tool token breakdown, sorted by descending total tokens
    /// (request + result). Caller owns the slice and each ToolUsage.
    per_tool: []ToolUsage = &.{},
    /// Tokens attributed to attachment turns. Best-effort: zcode's
    /// flat-text history does not yet carry structured attachment block
    /// types, so this stays 0 until multimodal/structured turns land.
    /// Documented honestly rather than fabricated (compaction-12).
    attachment_tokens: usize = 0,
    /// Tokens attributed to local-command (slash-command) output turns.
    /// Best-effort, recognized only by a `local-command-stdout` marker
    /// in turn content; otherwise 0.
    local_command_tokens: usize = 0,

    pub fn deinit(self: *Analysis, allocator: std.mem.Allocator) void {
        for (self.duplicate_reads) |*dup| dup.deinit(allocator);
        if (self.duplicate_reads.len > 0) allocator.free(self.duplicate_reads);
        if (self.largest_tool_result_name.len > 0) allocator.free(self.largest_tool_result_name);
        for (self.per_tool) |*tu| tu.deinit(allocator);
        if (self.per_tool.len > 0) allocator.free(self.per_tool);
    }
};

pub const RenderOptions = struct {
    json: bool = false,
    include_prompt_packets: bool = true,
    summary: bool = false,
    preprocessor_skipped: bool = false,
};

pub fn analyze(
    allocator: std.mem.Allocator,
    provider: []const u8,
    model: []const u8,
    env: *const types.PromptEnvelope,
    rendered_system: []const u8,
    rendered_user: []const u8,
    rendered_full: []const u8,
) !Analysis {
    var out = Analysis{
        .full_tokens = tokenizer.estimateText(provider, model, rendered_full),
        .system_tokens = tokenizer.estimateText(provider, model, rendered_system),
        .user_packet_tokens = tokenizer.estimateText(provider, model, rendered_user),
        .working_context_tokens = tokenizer.estimateText(provider, model, env.working_context),
    };
    errdefer out.deinit(allocator);

    if (env.preprocessor_intent.len > 0) {
        out.preprocessor_hint_tokens += tokenizer.estimateText(provider, model, env.preprocessor_intent);
    }
    if (env.focus_directive.len > 0) {
        out.preprocessor_hint_tokens += tokenizer.estimateText(provider, model, env.focus_directive);
    }

    for (env.instruction_stack) |entry| {
        out.instruction_tokens += tokenizer.estimateText(provider, model, entry.content);
    }

    for (env.tool_schemas) |schema| {
        out.tool_schema_tokens += tokenizer.estimateText(provider, model, schema.name);
        out.tool_schema_tokens += tokenizer.estimateText(provider, model, schema.description);
        out.tool_schema_tokens += tokenizer.estimateText(provider, model, schema.usage_hint);
        out.tool_schema_tokens += tokenizer.estimateText(provider, model, schema.json_schema);
    }

    var read_counts = std.StringHashMap(usize).init(allocator);
    defer {
        var it = read_counts.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        read_counts.deinit();
    }

    // Per-tool token aggregation keyed by tool name. Insertion order is not
    // preserved by the hash map, so we sort the final slice by total tokens.
    var tool_usage = std.StringHashMap(ToolUsage).init(allocator);
    defer {
        var it = tool_usage.valueIterator();
        while (it.next()) |tu| tu.deinit(allocator);
        tool_usage.deinit();
    }

    for (env.history) |turn| {
        const tokens = tokenizer.estimateText(provider, model, turn.content);
        out.history_tokens += tokens;
        switch (turn.role) {
            .user => {
                out.user_history_tokens += tokens;
                // Best-effort local-command-output detection. The reference
                // tags slash-command stdout with a `local-command-stdout`
                // marker (contextAnalysis.ts:60-65). zcode does not emit a
                // structured marker today, so this only fires if such a
                // marker is present.
                if (std.mem.indexOf(u8, turn.content, "local-command-stdout") != null) {
                    out.local_command_tokens += tokens;
                }
            },
            .assistant => out.assistant_history_tokens += tokens,
            .system => out.system_history_tokens += tokens,
            .tool => {
                out.tool_result_tokens += tokens;
                const tool_name = extractField(turn.content, "tool=") orelse "tool";
                if (tokens > out.largest_tool_result_tokens) {
                    if (out.largest_tool_result_name.len > 0) allocator.free(out.largest_tool_result_name);
                    out.largest_tool_result_name = try allocator.dupe(u8, tool_name);
                    out.largest_tool_result_tokens = tokens;
                }

                // Split the flat tool turn into a request part (header +
                // args, up to the `output=` marker) and a result part
                // (`output=` onward) so the breakdown distinguishes
                // tool-request vs tool-result tokens. Best-effort.
                const split = splitToolTurn(turn.content);
                const req_tokens = tokenizer.estimateText(provider, model, split.request);
                const res_tokens = tokenizer.estimateText(provider, model, split.result);
                const gop = try tool_usage.getOrPut(tool_name);
                if (!gop.found_existing) {
                    const key = try allocator.dupe(u8, tool_name);
                    gop.value_ptr.* = .{ .name = key };
                }
                gop.value_ptr.request_tokens += req_tokens;
                gop.value_ptr.result_tokens += res_tokens;
                gop.value_ptr.calls += 1;

                if (isReadToolName(tool_name)) {
                    if (extractReadPath(turn.content)) |path| {
                        if (read_counts.getPtr(path)) |count| {
                            count.* += 1;
                        } else {
                            const key = try allocator.dupe(u8, path);
                            errdefer allocator.free(key);
                            try read_counts.put(key, 1);
                        }
                    }
                }
            },
        }
    }

    for (env.context_blocks) |block| {
        const tokens = tokenizer.estimateText(provider, model, block.content);
        out.context_tokens += tokens;
        switch (block.source_type) {
            .session_memory => out.memory_context_tokens += tokens,
            .git_status, .git_diff, .repo_map => out.git_context_tokens += tokens,
            .user_file => out.file_context_tokens += tokens,
            else => {},
        }
    }

    var duplicates = std.array_list.Managed(DuplicateRead).init(allocator);
    errdefer {
        for (duplicates.items) |*dup| dup.deinit(allocator);
        duplicates.deinit();
    }
    var it = read_counts.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* <= 1) continue;
        const path = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(path);
        try duplicates.append(.{ .path = path, .count = entry.value_ptr.* });
    }
    std.mem.sort(DuplicateRead, duplicates.items, {}, duplicateLessThan);
    out.duplicate_reads = try duplicates.toOwnedSlice();

    // Move the per-tool aggregates into an owned, sorted slice. Ownership of
    // each ToolUsage.name transfers out of the map, so we clear the map entry
    // name to avoid the deferred double-free.
    var tools = std.array_list.Managed(ToolUsage).init(allocator);
    errdefer {
        for (tools.items) |*tu| tu.deinit(allocator);
        tools.deinit();
    }
    var tu_it = tool_usage.valueIterator();
    while (tu_it.next()) |tu| {
        try tools.append(tu.*);
        tu.name = &.{}; // ownership transferred; map defer must not free it
    }
    std.mem.sort(ToolUsage, tools.items, {}, toolUsageLessThan);
    out.per_tool = try tools.toOwnedSlice();

    return out;
}

pub fn render(
    allocator: std.mem.Allocator,
    provider: []const u8,
    model: []const u8,
    env: *const types.PromptEnvelope,
    rendered_system: []const u8,
    rendered_user: []const u8,
    rendered_full: []const u8,
    analysis: *const Analysis,
    options: RenderOptions,
) ![]u8 {
    if (options.json) {
        return renderJson(allocator, provider, model, env, rendered_system, rendered_user, rendered_full, analysis, options);
    }
    return renderHuman(allocator, provider, model, env, rendered_system, rendered_user, rendered_full, analysis, options);
}

pub fn redactSecretsAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    var start: usize = 0;
    while (start < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        const line = text[start..nl];
        if (lineContainsSecret(line)) {
            try out.appendSlice("[redacted secret-bearing line]");
        } else {
            try out.appendSlice(line);
        }
        if (nl < text.len) try out.append('\n');
        start = nl + 1;
    }
    return out.toOwnedSlice();
}

fn renderHuman(
    allocator: std.mem.Allocator,
    provider: []const u8,
    model: []const u8,
    env: *const types.PromptEnvelope,
    rendered_system: []const u8,
    rendered_user: []const u8,
    rendered_full: []const u8,
    analysis: *const Analysis,
    options: RenderOptions,
) ![]u8 {
    _ = rendered_full;
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("zcode prompt inspect\n\n");
    try w.print("provider={s}\nmodel={s}\n", .{ provider, model });
    try w.print("summary={}\npreprocessor_skipped={}\n", .{ options.summary, options.preprocessor_skipped });
    try w.print("ctx_window={d}\ninput_budget={d}\nreserved_output={d}\nreserved_reasoning={d}\n", .{
        env.budget_plan.model_ctx_window,
        env.budget_plan.input_budget,
        env.budget_plan.reserved_output,
        env.budget_plan.reserved_reasoning,
    });
    try w.print("cache_hints={d}\ntools={d}\ninstructions={d}\nhistory_turns={d}\ncontext_blocks={d}\n\n", .{
        env.cache_hints.len,
        env.tool_schemas.len,
        env.instruction_stack.len,
        env.history.len,
        env.context_blocks.len,
    });

    try w.writeAll("token breakdown:\n");
    try w.print("  full prompt         ~{d}\n", .{analysis.full_tokens});
    try w.print("  system packet       ~{d}\n", .{analysis.system_tokens});
    try w.print("  user packet         ~{d}\n", .{analysis.user_packet_tokens});
    try w.print("  working context     ~{d}\n", .{analysis.working_context_tokens});
    try w.print("  preprocessor hints  ~{d}\n", .{analysis.preprocessor_hint_tokens});
    try w.print("  instructions        ~{d}\n", .{analysis.instruction_tokens});
    try w.print("  tool schemas        ~{d}\n", .{analysis.tool_schema_tokens});
    try w.print("  history             ~{d} (user~{d}, assistant~{d}, system~{d}, tool~{d})\n", .{
        analysis.history_tokens,
        analysis.user_history_tokens,
        analysis.assistant_history_tokens,
        analysis.system_history_tokens,
        analysis.tool_result_tokens,
    });
    try w.print("  context blocks      ~{d} (git~{d}, files~{d}, memory~{d})\n", .{
        analysis.context_tokens,
        analysis.git_context_tokens,
        analysis.file_context_tokens,
        analysis.memory_context_tokens,
    });
    if (analysis.attachment_tokens > 0 or analysis.local_command_tokens > 0) {
        try w.print("  attachments         ~{d}\n  local commands      ~{d}\n", .{
            analysis.attachment_tokens,
            analysis.local_command_tokens,
        });
    }

    if (!options.summary and analysis.per_tool.len > 0) {
        try w.writeAll("\nby tool:\n");
        for (analysis.per_tool) |tu| {
            try w.print("  {s:<18} ~{d} (request~{d}, result~{d}, calls={d})\n", .{
                tu.name,
                tu.totalTokens(),
                tu.request_tokens,
                tu.result_tokens,
                tu.calls,
            });
        }
    }

    if (!options.summary and env.context_blocks.len > 0) {
        try w.writeAll("\nincluded context blocks:\n");
        for (env.context_blocks) |block| {
            try w.print("  - {s} source={s} priority={d} tokens~{d}\n", .{
                block.id,
                prompt_helpers.contextSourceName(block.source_type),
                block.priority,
                block.token_estimate,
            });
        }
    }

    if (analysis.duplicate_reads.len > 0 or analysis.largest_tool_result_tokens > 0) {
        try w.writeAll("\ncontext warnings:\n");
        if (analysis.duplicate_reads.len > 0) {
            for (analysis.duplicate_reads) |dup| {
                try w.print("  [i] duplicate Read results for {s}: {d} times\n", .{ dup.path, dup.count });
            }
        }
        if (analysis.largest_tool_result_tokens >= 10_000) {
            try w.print("  [i] large tool result: {s} uses ~{d} tokens\n", .{
                analysis.largest_tool_result_name,
                analysis.largest_tool_result_tokens,
            });
        }
        const pct = if (env.budget_plan.input_budget > 0)
            analysis.full_tokens * 100 / env.budget_plan.input_budget
        else
            100;
        if (pct >= env.budget_plan.compaction_thresholds.force_percent) {
            try w.print("  [!] prompt is {d}% of input budget; compact soon\n", .{pct});
        }
    }

    if (options.include_prompt_packets) {
        const redacted_system = try redactSecretsAlloc(allocator, rendered_system);
        defer allocator.free(redacted_system);
        const redacted_user = try redactSecretsAlloc(allocator, rendered_user);
        defer allocator.free(redacted_user);

        try w.writeAll("\n--- system prompt (redacted) ---\n");
        try w.writeAll(redacted_system);
        if (!std.mem.endsWith(u8, redacted_system, "\n")) try w.writeByte('\n');
        try w.writeAll("\n--- user prompt packet (redacted) ---\n");
        try w.writeAll(redacted_user);
        if (!std.mem.endsWith(u8, redacted_user, "\n")) try w.writeByte('\n');
    }

    return out.toOwnedSlice();
}

fn renderJson(
    allocator: std.mem.Allocator,
    provider: []const u8,
    model: []const u8,
    env: *const types.PromptEnvelope,
    rendered_system: []const u8,
    rendered_user: []const u8,
    rendered_full: []const u8,
    analysis: *const Analysis,
    options: RenderOptions,
) ![]u8 {
    _ = rendered_full;
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{");
    try w.writeAll("\"provider\":");
    try writeJsonString(w, provider);
    try w.writeAll(",\"model\":");
    try writeJsonString(w, model);
    try w.print(",\"summary\":{},\"preprocessor_skipped\":{}", .{ options.summary, options.preprocessor_skipped });
    try w.print(",\"ctx_window\":{d},\"input_budget\":{d},\"reserved_output\":{d},\"reserved_reasoning\":{d}", .{
        env.budget_plan.model_ctx_window,
        env.budget_plan.input_budget,
        env.budget_plan.reserved_output,
        env.budget_plan.reserved_reasoning,
    });
    try w.print(",\"cache_hints\":{d},\"tool_count\":{d},\"instruction_count\":{d},\"history_turns\":{d},\"context_block_count\":{d}", .{
        env.cache_hints.len,
        env.tool_schemas.len,
        env.instruction_stack.len,
        env.history.len,
        env.context_blocks.len,
    });
    try w.print(",\"tokens\":{{\"full\":{d},\"system\":{d},\"user_packet\":{d},\"working_context\":{d},\"preprocessor_hints\":{d},\"instructions\":{d},\"tool_schemas\":{d},\"history\":{d},\"tool_results\":{d},\"context\":{d}}}", .{
        analysis.full_tokens,
        analysis.system_tokens,
        analysis.user_packet_tokens,
        analysis.working_context_tokens,
        analysis.preprocessor_hint_tokens,
        analysis.instruction_tokens,
        analysis.tool_schema_tokens,
        analysis.history_tokens,
        analysis.tool_result_tokens,
        analysis.context_tokens,
    });

    try w.writeAll(",\"context_blocks\":[");
    for (env.context_blocks, 0..) |block, idx| {
        if (idx > 0) try w.writeByte(',');
        try w.writeAll("{\"id\":");
        try writeJsonString(w, block.id);
        try w.writeAll(",\"source\":");
        try writeJsonString(w, prompt_helpers.contextSourceName(block.source_type));
        try w.print(",\"priority\":{d},\"tokens\":{d}}}", .{ block.priority, block.token_estimate });
    }
    try w.writeAll("]");

    try w.writeAll(",\"duplicate_reads\":[");
    for (analysis.duplicate_reads, 0..) |dup, idx| {
        if (idx > 0) try w.writeByte(',');
        try w.writeAll("{\"path\":");
        try writeJsonString(w, dup.path);
        try w.print(",\"count\":{d}}}", .{dup.count});
    }
    try w.writeAll("]");

    try w.print(",\"attachment_tokens\":{d},\"local_command_tokens\":{d}", .{
        analysis.attachment_tokens,
        analysis.local_command_tokens,
    });

    try w.writeAll(",\"per_tool\":[");
    for (analysis.per_tool, 0..) |tu, idx| {
        if (idx > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try writeJsonString(w, tu.name);
        try w.print(",\"request_tokens\":{d},\"result_tokens\":{d},\"calls\":{d}}}", .{
            tu.request_tokens,
            tu.result_tokens,
            tu.calls,
        });
    }
    try w.writeAll("]");

    if (options.include_prompt_packets) {
        const redacted_system = try redactSecretsAlloc(allocator, rendered_system);
        defer allocator.free(redacted_system);
        const redacted_user = try redactSecretsAlloc(allocator, rendered_user);
        defer allocator.free(redacted_user);
        try w.writeAll(",\"system_prompt\":");
        try writeJsonString(w, redacted_system);
        try w.writeAll(",\"user_prompt_packet\":");
        try writeJsonString(w, redacted_user);
    }

    try w.writeAll("}\n");
    return out.toOwnedSlice();
}

pub fn writeJsonString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |ch| switch (ch) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => {
            if (ch < 0x20) {
                try writer.print("\\u{x:0>4}", .{ch});
            } else {
                try writer.writeByte(ch);
            }
        },
    };
    try writer.writeByte('"');
}

fn duplicateLessThan(_: void, a: DuplicateRead, b: DuplicateRead) bool {
    if (a.count == b.count) return std.mem.lessThan(u8, a.path, b.path);
    return a.count > b.count;
}

fn toolUsageLessThan(_: void, a: ToolUsage, b: ToolUsage) bool {
    const at = a.totalTokens();
    const bt = b.totalTokens();
    if (at == bt) return std.mem.lessThan(u8, a.name, b.name);
    return at > bt;
}

const ToolTurnSplit = struct {
    request: []const u8,
    result: []const u8,
};

/// Split a flat tool turn into its request half (the `tool=`/`args=` header
/// up to the `output=` marker) and its result half (`output=` onward). When
/// no `\noutput=` marker is present the whole turn is treated as request.
/// Best-effort: args can contain embedded newlines, but the per-tool total
/// (request + result) is unaffected by where the split lands.
fn splitToolTurn(content: []const u8) ToolTurnSplit {
    const marker = "\noutput=";
    if (std.mem.indexOf(u8, content, marker)) |idx| {
        return .{ .request = content[0..idx], .result = content[idx..] };
    }
    if (std.mem.startsWith(u8, content, "output=")) {
        return .{ .request = "", .result = content };
    }
    return .{ .request = content, .result = "" };
}

fn extractField(text: []const u8, field: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, field)) continue;
        return std.mem.trim(u8, line[field.len..], " \t\r");
    }
    return null;
}

fn extractReadPath(text: []const u8) ?[]const u8 {
    const args = extractField(text, "args=") orelse text;
    const marker = "path=";
    const idx = std.mem.indexOf(u8, args, marker) orelse return null;
    var start = idx + marker.len;
    while (start < args.len and (args[start] == '"' or args[start] == '\'' or args[start] == ' ')) : (start += 1) {}
    var end = start;
    while (end < args.len and args[end] != ';' and args[end] != '\n' and args[end] != ' ' and args[end] != '"' and args[end] != '\'') : (end += 1) {}
    if (end <= start) return null;
    return args[start..end];
}

fn isReadToolName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Read") or
        std.mem.eql(u8, name, "read") or
        std.mem.eql(u8, name, "file_read");
}

fn lineContainsSecret(line: []const u8) bool {
    const keywords = [_][]const u8{
        "api_key",
        "apikey",
        "authorization:",
        "bearer ",
        "token=",
        "access_token",
        "refresh_token",
        "password=",
        "secret=",
        "secret_key",
        "private_key",
    };
    for (keywords) |kw| {
        if (containsIgnoreCase(line, kw)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matched = true;
        for (needle, 0..) |n, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(n)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

const testing = std.testing;

test "prompt analysis detects duplicate read paths" {
    var history = [_]types.HistoryTurn{
        .{ .role = .tool, .content = "tool=Read\nargs=path=src/main.zig\noutput=a", .timestamp = 0 },
        .{ .role = .tool, .content = "tool=Read\nargs=path=src/main.zig\noutput=b", .timestamp = 0 },
        .{ .role = .tool, .content = "tool=Read\nargs=path=README.md\noutput=c", .timestamp = 0 },
    };
    const env = types.PromptEnvelope{
        .system_policy = "system",
        .user_turn = "inspect",
        .tool_schemas = &.{},
        .history = &history,
        .context_blocks = &.{},
        .instruction_stack = &.{},
        .budget_plan = types.BudgetPlan.init(100_000, 10_000, 5_000),
        .cache_hints = &.{},
    };
    var analysis = try analyze(testing.allocator, "test", "test", &env, "system", "user", "full");
    defer analysis.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), analysis.duplicate_reads.len);
    try testing.expectEqualStrings("src/main.zig", analysis.duplicate_reads[0].path);
    try testing.expectEqual(@as(usize, 2), analysis.duplicate_reads[0].count);
}

test "prompt analysis aggregates per-tool token breakdown" {
    var history = [_]types.HistoryTurn{
        .{ .role = .tool, .content = "tool=Read\nargs=path=src/main.zig\nstate=auto_approved\nrisk=LOW\noutput=alpha beta gamma", .timestamp = 0 },
        .{ .role = .tool, .content = "tool=Read\nargs=path=src/a.zig\nstate=auto_approved\nrisk=LOW\noutput=delta", .timestamp = 0 },
        .{ .role = .tool, .content = "tool=Read\nargs=path=src/b.zig\nstate=auto_approved\nrisk=LOW\noutput=epsilon", .timestamp = 0 },
        .{ .role = .tool, .content = "tool=Bash\nargs=cmd=ls -la\nstate=auto_approved\nrisk=LOW\noutput=one two three four five", .timestamp = 0 },
    };
    const env = types.PromptEnvelope{
        .system_policy = "system",
        .user_turn = "inspect",
        .tool_schemas = &.{},
        .history = &history,
        .context_blocks = &.{},
        .instruction_stack = &.{},
        .budget_plan = types.BudgetPlan.init(100_000, 10_000, 5_000),
        .cache_hints = &.{},
    };
    var analysis = try analyze(testing.allocator, "test", "test", &env, "system", "user", "full");
    defer analysis.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), analysis.per_tool.len);

    var read_calls: usize = 0;
    var bash_calls: usize = 0;
    for (analysis.per_tool) |tu| {
        if (std.mem.eql(u8, tu.name, "Read")) {
            read_calls = tu.calls;
            // Request and result halves must both contribute and sum to the total.
            try testing.expect(tu.request_tokens > 0);
            try testing.expect(tu.result_tokens > 0);
            try testing.expectEqual(tu.totalTokens(), tu.request_tokens + tu.result_tokens);
        } else if (std.mem.eql(u8, tu.name, "Bash")) {
            bash_calls = tu.calls;
        }
    }
    try testing.expectEqual(@as(usize, 3), read_calls);
    try testing.expectEqual(@as(usize, 1), bash_calls);
}

test "prompt analysis per-tool sorted by descending total tokens" {
    // The Read turn carries a much larger output than the Bash turn, so it
    // must sort first regardless of insertion order.
    var history = [_]types.HistoryTurn{
        .{ .role = .tool, .content = "tool=Bash\nargs=cmd=echo hi\nstate=auto_approved\nrisk=LOW\noutput=hi", .timestamp = 0 },
        .{ .role = .tool, .content = "tool=Read\nargs=path=src/big.zig\nstate=auto_approved\nrisk=LOW\noutput=lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod", .timestamp = 0 },
    };
    const env = types.PromptEnvelope{
        .system_policy = "system",
        .user_turn = "inspect",
        .tool_schemas = &.{},
        .history = &history,
        .context_blocks = &.{},
        .instruction_stack = &.{},
        .budget_plan = types.BudgetPlan.init(100_000, 10_000, 5_000),
        .cache_hints = &.{},
    };
    var analysis = try analyze(testing.allocator, "test", "test", &env, "system", "user", "full");
    defer analysis.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), analysis.per_tool.len);
    try testing.expectEqualStrings("Read", analysis.per_tool[0].name);
    try testing.expect(analysis.per_tool[0].totalTokens() >= analysis.per_tool[1].totalTokens());
}

test "prompt analysis renders by-tool section" {
    var history = [_]types.HistoryTurn{
        .{ .role = .tool, .content = "tool=Read\nargs=path=src/main.zig\nstate=auto_approved\nrisk=LOW\noutput=alpha", .timestamp = 0 },
        .{ .role = .tool, .content = "tool=Bash\nargs=cmd=ls\nstate=auto_approved\nrisk=LOW\noutput=files", .timestamp = 0 },
    };
    const env = types.PromptEnvelope{
        .system_policy = "system",
        .user_turn = "inspect",
        .tool_schemas = &.{},
        .history = &history,
        .context_blocks = &.{},
        .instruction_stack = &.{},
        .budget_plan = types.BudgetPlan.init(100_000, 10_000, 5_000),
        .cache_hints = &.{},
    };
    var analysis = try analyze(testing.allocator, "test", "test", &env, "system", "user", "full");
    defer analysis.deinit(testing.allocator);

    const out = try render(testing.allocator, "test", "test", &env, "system", "user", "full", &analysis, .{
        .include_prompt_packets = false,
    });
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "by tool:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Read") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Bash") != null);
    try testing.expect(std.mem.indexOf(u8, out, "calls=") != null);
}

test "prompt analysis detects local-command output tokens" {
    var history = [_]types.HistoryTurn{
        .{ .role = .user, .content = "local-command-stdout: build succeeded", .timestamp = 0 },
        .{ .role = .user, .content = "plain user message", .timestamp = 0 },
    };
    const env = types.PromptEnvelope{
        .system_policy = "system",
        .user_turn = "inspect",
        .tool_schemas = &.{},
        .history = &history,
        .context_blocks = &.{},
        .instruction_stack = &.{},
        .budget_plan = types.BudgetPlan.init(100_000, 10_000, 5_000),
        .cache_hints = &.{},
    };
    var analysis = try analyze(testing.allocator, "test", "test", &env, "system", "user", "full");
    defer analysis.deinit(testing.allocator);

    const expected = tokenizer.estimateText("test", "test", history[0].content);
    try testing.expectEqual(expected, analysis.local_command_tokens);
}

test "prompt analysis reports preprocessor hint tokens" {
    const env = types.PromptEnvelope{
        .system_policy = "system",
        .user_turn = "inspect",
        .working_context = "round=1",
        .tool_schemas = &.{},
        .history = &.{},
        .context_blocks = &.{},
        .instruction_stack = &.{},
        .budget_plan = types.BudgetPlan.init(100_000, 10_000, 5_000),
        .cache_hints = &.{},
        .preprocessor_intent = "code review",
        .focus_directive = "Focus on prompting flow.",
    };

    var analysis = try analyze(testing.allocator, "test", "test", &env, "system", "user", "full");
    defer analysis.deinit(testing.allocator);

    const expected =
        tokenizer.estimateText("test", "test", env.preprocessor_intent) +
        tokenizer.estimateText("test", "test", env.focus_directive);
    try testing.expectEqual(expected, analysis.preprocessor_hint_tokens);
}

test "redaction removes secret-bearing lines" {
    const input = "normal\napi_key=abc123\nAuthorization: Bearer secret\nok\n";
    const out = try redactSecretsAlloc(testing.allocator, input);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "abc123") == null);
    try testing.expect(std.mem.indexOf(u8, out, "Bearer secret") == null);
    try testing.expect(std.mem.indexOf(u8, out, "normal") != null);
}

test "json string escapes controls" {
    var out = std_io.StringBuilder.init(testing.allocator);
    defer out.deinit();
    try writeJsonString(out.writer(), "a\"b\\c\n");
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\n\"", out.items());
}
