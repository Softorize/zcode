const std = @import("std");
const std_io = @import("std_io.zig");
const clock = @import("clock.zig");
const config_mod = @import("config.zig");
const types = @import("types.zig");
const providers = @import("../providers/mod.zig");

pub const PreprocessorResult = struct {
    intent: []u8,
    relevant_files: [][]u8,
    context_scores: []types.PreprocessorHints.ContextScore,
    focus_directive: []u8,
    tokens_used: usize,

    pub fn deinit(self: *PreprocessorResult, allocator: std.mem.Allocator) void {
        allocator.free(self.intent);
        allocator.free(self.focus_directive);
        for (self.relevant_files) |f| allocator.free(f);
        allocator.free(self.relevant_files);
        for (self.context_scores) |s| allocator.free(s.block_id);
        allocator.free(self.context_scores);
    }
};

pub const Settings = struct {
    enabled: bool,
    provider: []const u8,
    model: []const u8,
    max_output_tokens: usize,
    api_key: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
};

const preprocessor_system_prompt =
    "You are a context preprocessor for a coding agent. Analyze the user's request and available context blocks.\n" ++
    "Return ONLY a JSON object: {\"intent\":\"...\", \"relevant_files\":[], \"context_scores\":[{\"block_id\":\"...\",\"relevance\":0-100}], \"focus_directive\":\"...\"}\n";

pub fn preprocess(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    user_turn: []const u8,
    context_candidates: []const types.ContextBlock,
    history_summary: []const u8,
) ?PreprocessorResult {
    return preprocessWithSettings(
        allocator,
        resolveSettings(
            cfg,
            cfg.preprocessor_enabled,
            cfg.preprocessor_provider,
            cfg.preprocessor_model,
            cfg.preprocessor_max_output_tokens,
            cfg.preprocessor_api_key,
            cfg.preprocessor_base_url,
        ),
        user_turn,
        context_candidates,
        history_summary,
    );
}

pub fn preprocessWithSettings(
    allocator: std.mem.Allocator,
    settings: Settings,
    user_turn: []const u8,
    context_candidates: []const types.ContextBlock,
    history_summary: []const u8,
) ?PreprocessorResult {
    if (!settings.enabled) return null;
    if (settings.provider.len == 0 or settings.model.len == 0) return null;

    // Warn on failure. Previously the preprocessor swallowed every error
    // silently, so a misconfigured preprocessor (wrong provider, bad API
    // key, unreachable model) would produce turns without any
    // preprocessing and no indication to the user why the feature
    // appeared dead. The warning is rate-limited to once per wall-clock
    // minute so a persistently-failing preprocessor doesn't spam the logs.
    return preprocessInner(allocator, settings, user_turn, context_candidates, history_summary) catch |err| {
        if (shouldWarnOnFailure()) {
            std.log.warn(
                "preprocessor ({s}/{s}) failed: {s}; continuing without it",
                .{ settings.provider, settings.model, @errorName(err) },
            );
        }
        return null;
    };
}

var last_warn_ts: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);

/// Return true at most once per 60 seconds so a persistently-failing
/// preprocessor doesn't spam the log on every turn.
fn shouldWarnOnFailure() bool {
    const now = clock.nowSeconds();
    const last = last_warn_ts.load(.monotonic);
    if (now - last < 60) return false;
    last_warn_ts.store(now, .monotonic);
    return true;
}

pub fn resolveSettings(
    cfg: *const config_mod.Config,
    enabled: bool,
    provider: []const u8,
    model: []const u8,
    max_output_tokens: usize,
    explicit_api_key: []const u8,
    explicit_base_url: []const u8,
) Settings {
    var settings = Settings{
        .enabled = enabled,
        .provider = provider,
        .model = model,
        .max_output_tokens = max_output_tokens,
    };

    if (explicit_api_key.len > 0) {
        settings.api_key = explicit_api_key;
    } else if (std.mem.eql(u8, provider, cfg.default_provider) and cfg.provider_api_key.len > 0) {
        settings.api_key = cfg.provider_api_key;
    } else if (cfg.fallback_provider.len > 0 and std.mem.eql(u8, provider, cfg.fallback_provider) and cfg.fallback_provider_api_key.len > 0) {
        settings.api_key = cfg.fallback_provider_api_key;
    }

    if (explicit_base_url.len > 0) {
        settings.base_url = explicit_base_url;
    } else if ((std.mem.eql(u8, provider, "local") or std.mem.eql(u8, provider, "ollama")) and cfg.local_base_url.len > 0) {
        settings.base_url = cfg.local_base_url;
    } else if (std.mem.eql(u8, provider, cfg.default_provider) and cfg.provider_base_url.len > 0) {
        settings.base_url = cfg.provider_base_url;
    } else if (cfg.fallback_provider.len > 0 and std.mem.eql(u8, provider, cfg.fallback_provider) and cfg.fallback_provider_base_url.len > 0) {
        settings.base_url = cfg.fallback_provider_base_url;
    }

    return settings;
}

fn preprocessInner(
    allocator: std.mem.Allocator,
    settings: Settings,
    user_turn: []const u8,
    context_candidates: []const types.ContextBlock,
    history_summary: []const u8,
) !PreprocessorResult {
    const prompt_text = try buildPreprocessorPrompt(allocator, user_turn, context_candidates, history_summary);
    defer allocator.free(prompt_text);

    var adapter = try providers.createAdapterWithOverrides(
        allocator,
        settings.provider,
        .{
            .api_key = settings.api_key,
            .base_url = settings.base_url,
            .timeout_ms = 15_000,
            .retry_count = 1,
        },
    );
    defer adapter.deinit(allocator);

    const request = types.ModelRequest{
        .model = settings.model,
        .system_prompt = preprocessor_system_prompt,
        .prompt = prompt_text,
        .max_output_tokens = settings.max_output_tokens,
        .temperature = 0.0,
    };

    const response = try adapter.send(allocator, request);
    defer allocator.free(response.raw);
    defer allocator.free(response.text);

    var result = try parsePreprocessorResponse(allocator, response.text);
    result.tokens_used = response.usage_input_tokens + response.usage_output_tokens;
    return result;
}

pub fn buildPreprocessorPrompt(
    allocator: std.mem.Allocator,
    user_turn: []const u8,
    candidates: []const types.ContextBlock,
    history_summary: []const u8,
) ![]u8 {
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();

    // Wrap user-controlled content in delimited blocks so a crafted user
    // turn containing literal "Available context blocks:" or "History
    // context:" cannot forge fake entries that the preprocessor then
    // relevance-scores. The fence is neutralized in the body via a
    // zero-width space if it happens to appear.
    const user_fence = "<<<ZCODE_USER_TURN_1f3c7b4d>>>";
    try buf.writer().print("User request:\n{s}\n", .{user_fence});
    try writeEscapedFenced(buf.writer(), user_turn, user_fence);
    try buf.writer().print("\n{s}\n", .{user_fence});

    if (history_summary.len > 0) {
        const history_fence = "<<<ZCODE_HISTORY_9e4a2f17>>>";
        try buf.writer().print("History context:\n{s}\n", .{history_fence});
        try writeEscapedFenced(buf.writer(), history_summary, history_fence);
        try buf.writer().print("\n{s}\n", .{history_fence});
    }

    try buf.writer().writeAll("Available context blocks:\n");
    for (candidates) |block| {
        try buf.writer().print("- id={s} source={s} tokens~{d}\n", .{
            block.id,
            contextSourceName(block.source_type),
            block.token_estimate,
        });
    }

    return buf.toOwnedSlice();
}

/// Write `text` to `writer`, neutralizing any occurrence of `fence` so that
/// untrusted content cannot close the surrounding fenced block. Matches get
/// a zero-width space inserted after the first character, which breaks the
/// literal match while leaving the text visually intact.
fn writeEscapedFenced(writer: anytype, text: []const u8, fence: []const u8) !void {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, text, cursor, fence)) |at| {
        try writer.writeAll(text[cursor..at]);
        try writer.writeAll(fence[0..1]);
        try writer.writeAll("\u{200B}");
        try writer.writeAll(fence[1..]);
        cursor = at + fence.len;
    }
    try writer.writeAll(text[cursor..]);
}

pub fn parsePreprocessorResponse(allocator: std.mem.Allocator, text: []const u8) !PreprocessorResult {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");

    const json_start = std.mem.indexOf(u8, trimmed, "{") orelse return neutralResult(allocator);
    const json_end = std.mem.lastIndexOf(u8, trimmed, "}") orelse return neutralResult(allocator);
    if (json_end <= json_start) return neutralResult(allocator);

    const json_slice = trimmed[json_start .. json_end + 1];

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_slice, .{}) catch return neutralResult(allocator);
    defer parsed.deinit();

    if (parsed.value != .object) return neutralResult(allocator);
    const obj = &parsed.value.object;

    // Each allocation below gets its own errdefer so an OOM in any later
    // step frees everything allocated so far. Previously a failure between
    // `intent` and the final toOwnedSlice would leak intent, focus_directive,
    // and every already-duped string inside relevant_files / context_scores.
    const intent = if (obj.get("intent")) |v| switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        else => try allocator.dupe(u8, ""),
    } else try allocator.dupe(u8, "");
    errdefer allocator.free(intent);

    const focus_directive = if (obj.get("focus_directive")) |v| switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        else => try allocator.dupe(u8, ""),
    } else try allocator.dupe(u8, "");
    errdefer allocator.free(focus_directive);

    var relevant_files = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (relevant_files.items) |item| allocator.free(item);
        relevant_files.deinit();
    }
    if (obj.get("relevant_files")) |rf_val| {
        switch (rf_val) {
            .array => |arr| {
                for (arr.items) |item| {
                    switch (item) {
                        .string => |s| {
                            const duped = try allocator.dupe(u8, s);
                            errdefer allocator.free(duped);
                            try relevant_files.append(duped);
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    var context_scores = std.array_list.Managed(types.PreprocessorHints.ContextScore).init(allocator);
    errdefer {
        for (context_scores.items) |score| allocator.free(score.block_id);
        context_scores.deinit();
    }
    if (obj.get("context_scores")) |cs_val| {
        switch (cs_val) {
            .array => |arr| {
                for (arr.items) |item| {
                    switch (item) {
                        .object => |score_obj| {
                            const block_id = if (score_obj.get("block_id")) |bid| switch (bid) {
                                .string => |s| s,
                                else => continue,
                            } else continue;

                            const relevance: u8 = if (score_obj.get("relevance")) |rel| switch (rel) {
                                .integer => |i| @intCast(@min(100, @max(0, i))),
                                .float => |f| @intFromFloat(@min(100.0, @max(0.0, f))),
                                else => continue,
                            } else continue;

                            const duped_block_id = try allocator.dupe(u8, block_id);
                            errdefer allocator.free(duped_block_id);
                            try context_scores.append(.{
                                .block_id = duped_block_id,
                                .relevance = relevance,
                            });
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    const files_slice = try relevant_files.toOwnedSlice();
    errdefer {
        for (files_slice) |f| allocator.free(f);
        allocator.free(files_slice);
    }
    const scores_slice = try context_scores.toOwnedSlice();

    return .{
        .intent = intent,
        .relevant_files = files_slice,
        .context_scores = scores_slice,
        .focus_directive = focus_directive,
        .tokens_used = 0,
    };
}

fn neutralResult(allocator: std.mem.Allocator) !PreprocessorResult {
    return .{
        .intent = try allocator.dupe(u8, ""),
        .relevant_files = try allocator.alloc([]u8, 0),
        .context_scores = try allocator.alloc(types.PreprocessorHints.ContextScore, 0),
        .focus_directive = try allocator.dupe(u8, ""),
        .tokens_used = 0,
    };
}

pub fn toHints(allocator: std.mem.Allocator, result: *const PreprocessorResult) !types.PreprocessorHints {
    const scores = try allocator.alloc(types.PreprocessorHints.ContextScore, result.context_scores.len);
    for (result.context_scores, 0..) |s, i| {
        scores[i] = .{
            .block_id = try allocator.dupe(u8, s.block_id),
            .relevance = s.relevance,
        };
    }
    return .{
        .intent = try allocator.dupe(u8, result.intent),
        .focus_directive = try allocator.dupe(u8, result.focus_directive),
        .context_scores = scores,
    };
}

fn contextSourceName(source: types.ContextSource) []const u8 {
    return switch (source) {
        .git_status => "git_status",
        .git_diff => "git_diff",
        .repo_map => "repo_map",
        .user_file => "user_file",
        .tool_result => "tool_result",
        .session_memory => "session_memory",
        .instruction => "instruction",
    };
}

const testing = std.testing;

test "buildPreprocessorPrompt includes block summaries" {
    const blocks = [_]types.ContextBlock{
        .{
            .id = "git-status",
            .source_type = .git_status,
            .priority = 95,
            .token_estimate = 50,
            .content = "## main",
            .freshness = 100,
        },
        .{
            .id = "repo-map",
            .source_type = .repo_map,
            .priority = 85,
            .token_estimate = 200,
            .content = "src/main.zig\nsrc/lib.zig",
            .freshness = 100,
        },
    };

    const prompt = try buildPreprocessorPrompt(
        testing.allocator,
        "fix the bug in main.zig",
        blocks[0..],
        "previous work on feature X",
    );
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "fix the bug in main.zig") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "git-status") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "repo-map") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "previous work on feature X") != null);
}

test "parsePreprocessorResponse extracts all fields from valid JSON" {
    const json =
        \\{"intent":"bug fix","relevant_files":["src/main.zig"],"context_scores":[{"block_id":"git-status","relevance":90},{"block_id":"repo-map","relevance":30}],"focus_directive":"Focus on error handling in main.zig"}
    ;

    var result = try parsePreprocessorResponse(testing.allocator, json);
    defer result.deinit(testing.allocator);

    try testing.expectEqualStrings("bug fix", result.intent);
    try testing.expectEqualStrings("Focus on error handling in main.zig", result.focus_directive);
    try testing.expectEqual(@as(usize, 1), result.relevant_files.len);
    try testing.expectEqualStrings("src/main.zig", result.relevant_files[0]);
    try testing.expectEqual(@as(usize, 2), result.context_scores.len);
    try testing.expectEqualStrings("git-status", result.context_scores[0].block_id);
    try testing.expectEqual(@as(u8, 90), result.context_scores[0].relevance);
    try testing.expectEqualStrings("repo-map", result.context_scores[1].block_id);
    try testing.expectEqual(@as(u8, 30), result.context_scores[1].relevance);
}

test "parsePreprocessorResponse returns neutral defaults for malformed JSON" {
    var result = try parsePreprocessorResponse(testing.allocator, "not json at all");
    defer result.deinit(testing.allocator);

    try testing.expectEqualStrings("", result.intent);
    try testing.expectEqualStrings("", result.focus_directive);
    try testing.expectEqual(@as(usize, 0), result.relevant_files.len);
    try testing.expectEqual(@as(usize, 0), result.context_scores.len);
}

test "preprocess returns null when disabled" {
    const allocator = testing.allocator;
    var cfg = try config_mod.Config.init(allocator);
    defer cfg.deinit(allocator);

    const result = preprocess(allocator, &cfg, "hello", &.{}, "");
    try testing.expect(result == null);
}

test "resolveSettings prefers explicit preprocessor credentials and base url" {
    const allocator = testing.allocator;
    var cfg = try config_mod.Config.init(allocator);
    defer cfg.deinit(allocator);

    allocator.free(cfg.default_provider);
    cfg.default_provider = try allocator.dupe(u8, "openai");
    allocator.free(cfg.provider_api_key);
    cfg.provider_api_key = try allocator.dupe(u8, "sk-default");
    allocator.free(cfg.provider_base_url);
    cfg.provider_base_url = try allocator.dupe(u8, "https://default.example.test/v1");

    const resolved = resolveSettings(
        &cfg,
        true,
        "openai",
        "gpt-4.1-mini",
        320,
        "sk-preprocessor",
        "https://pre.example.test/v1",
    );

    try testing.expect(resolved.enabled);
    try testing.expectEqualStrings("openai", resolved.provider);
    try testing.expectEqualStrings("gpt-4.1-mini", resolved.model);
    try testing.expectEqualStrings("sk-preprocessor", resolved.api_key.?);
    try testing.expectEqualStrings("https://pre.example.test/v1", resolved.base_url.?);
    try testing.expectEqual(@as(usize, 320), resolved.max_output_tokens);
}

test "resolveSettings falls back to configured provider credentials" {
    const allocator = testing.allocator;
    var cfg = try config_mod.Config.init(allocator);
    defer cfg.deinit(allocator);

    allocator.free(cfg.default_provider);
    cfg.default_provider = try allocator.dupe(u8, "openai");
    allocator.free(cfg.provider_api_key);
    cfg.provider_api_key = try allocator.dupe(u8, "sk-default");
    allocator.free(cfg.provider_base_url);
    cfg.provider_base_url = try allocator.dupe(u8, "https://default.example.test/v1");

    const resolved = resolveSettings(
        &cfg,
        true,
        "openai",
        "gpt-4.1-mini",
        300,
        "",
        "",
    );

    try testing.expectEqualStrings("sk-default", resolved.api_key.?);
    try testing.expectEqualStrings("https://default.example.test/v1", resolved.base_url.?);
}

test "resolveSettings uses local base url for local preprocessor" {
    const allocator = testing.allocator;
    var cfg = try config_mod.Config.init(allocator);
    defer cfg.deinit(allocator);

    allocator.free(cfg.local_base_url);
    cfg.local_base_url = try allocator.dupe(u8, "http://127.0.0.1:22434");

    const resolved = resolveSettings(
        &cfg,
        true,
        "local",
        "qwen2.5-coder",
        300,
        "",
        "",
    );

    try testing.expect(resolved.api_key == null);
    try testing.expectEqualStrings("http://127.0.0.1:22434", resolved.base_url.?);
}
