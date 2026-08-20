const std = @import("std");
const types = @import("../core/types.zig");

/// Maximum number of bytes of fetched content we feed into the secondary
/// summarization model. Ported from claude-code-main/src/tools/WebFetchTool
/// utils.ts:128 (`MAX_MARKDOWN_LENGTH = 100_000`). Content longer than this is
/// truncated with an explicit marker so the model knows the page was clipped.
pub const MAX_MARKDOWN_LENGTH: usize = 100_000;

/// Marker appended when `content` exceeds MAX_MARKDOWN_LENGTH. Matches the
/// reference shape so a model reading the prompt understands the body is
/// incomplete rather than the page simply ending.
const TRUNCATION_MARKER = "\n\n[Content truncated due to length...]";

/// Function-pointer shape for the model call. The dispatch layer owns the
/// real implementation (AgentRuntime.callModelTrampoline) and passes it down,
/// so web_summarize never imports agent_history/agent_runtime directly (avoids
/// an import cycle -- see Phase 9 Task 1 footguns).
pub const CallModelFn = *const fn (opaque_self: *anyopaque, request: types.ModelRequest) anyerror!types.ModelResponse;

/// Everything web_summarize needs to run the secondary pass without reaching
/// into the runtime. Borrowed -- the dispatch layer owns the lifetimes.
pub const SummarizeContext = struct {
    /// Provider name of the active session (e.g. "anthropic", "openai").
    provider: []const u8,
    /// The session's active model. Used as the small-model fallback when the
    /// provider is not Anthropic (so the call still works).
    active_model: []const u8,
    /// Configured small/fast model (cfg.small_fast_model). Used only when the
    /// provider is Anthropic.
    small_fast_model: []const u8,
    /// Token budget for the secondary model's output.
    max_output_tokens: usize,
    /// Opaque runtime pointer threaded into call_model_fn.
    opaque_self: *anyopaque,
    /// The actual model-call trampoline.
    call_model_fn: CallModelFn,
};

/// Resolve which model the secondary pass should use. Anthropic providers use
/// the configured small/fast model; any other provider falls back to the
/// active model (the small model name is Anthropic-specific and would not
/// resolve elsewhere). Pure -- unit-testable.
pub fn resolveSmallModel(provider: []const u8, active_model: []const u8, small_fast_model: []const u8) []const u8 {
    if (small_fast_model.len > 0 and std.ascii.eqlIgnoreCase(provider, "anthropic")) {
        return small_fast_model;
    }
    return active_model;
}

/// Build the user prompt fed to the secondary model. Ports
/// `makeSecondaryModelPrompt` from the reference: the fetched page content
/// (truncated to MAX_MARKDOWN_LENGTH) followed by the caller's prompt. Pure and
/// allocation-only so it is unit-testable without a network or model call.
pub fn buildSecondaryPrompt(allocator: std.mem.Allocator, prompt: []const u8, content: []const u8) ![]u8 {
    if (content.len > MAX_MARKDOWN_LENGTH) {
        const head = content[0..MAX_MARKDOWN_LENGTH];
        return std.fmt.allocPrint(
            allocator,
            "Web page content:\n{s}{s}\n\n{s}",
            .{ head, TRUNCATION_MARKER, prompt },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "Web page content:\n{s}\n\n{s}",
        .{ content, prompt },
    );
}

const SYSTEM_PROMPT =
    "You are a focused web-content extraction assistant. You are given the text " ++
    "of a web page and a question or instruction about it. Answer the question " ++
    "using only the page content. Be concise and quote relevant snippets when " ++
    "helpful. If the page does not contain the answer, say so plainly.";

/// Run the secondary-model pass: build the prompt, call the small/fast model,
/// and return its focused answer. On any model error the caller's raw content
/// is returned (prefixed with a one-line note) so WebFetch never hard-fails on
/// a summarization failure. Returns owned memory.
pub fn applyPromptToContent(
    allocator: std.mem.Allocator,
    ctx: SummarizeContext,
    prompt: []const u8,
    content: []const u8,
) ![]u8 {
    const user_prompt = try buildSecondaryPrompt(allocator, prompt, content);
    defer allocator.free(user_prompt);

    const model = resolveSmallModel(ctx.provider, ctx.active_model, ctx.small_fast_model);

    const request = types.ModelRequest{
        .model = model,
        .system_prompt = SYSTEM_PROMPT,
        .prompt = user_prompt,
        .max_output_tokens = ctx.max_output_tokens,
        .temperature = 0.0,
        .tool_schemas = &.{},
    };

    const response = ctx.call_model_fn(ctx.opaque_self, request) catch |err| {
        std.log.warn("web_fetch: secondary summarization failed ({s}); returning raw content", .{@errorName(err)});
        return std.fmt.allocPrint(
            allocator,
            "[web_fetch: summarization unavailable, returning raw content]\n\n{s}",
            .{content},
        );
    };
    defer allocator.free(response.raw);
    defer allocator.free(response.text);
    defer if (response.tool_calls_json.len > 0) allocator.free(response.tool_calls_json);
    defer if (response.reasoning_text.len > 0) allocator.free(response.reasoning_text);

    if (response.text.len == 0) {
        return std.fmt.allocPrint(
            allocator,
            "[web_fetch: summarization returned empty, returning raw content]\n\n{s}",
            .{content},
        );
    }
    return allocator.dupe(u8, response.text);
}

// -- Tests --

const testing = std.testing;

test "buildSecondaryPrompt assembles content then prompt for short content" {
    const out = try buildSecondaryPrompt(testing.allocator, "what is the latest version?", "Release 1.2.3 is out.");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Web page content:\nRelease 1.2.3 is out.") != null);
    try testing.expect(std.mem.indexOf(u8, out, "what is the latest version?") != null);
    // Short content must NOT carry the truncation marker.
    try testing.expect(std.mem.indexOf(u8, out, "[Content truncated due to length...]") == null);
}

test "buildSecondaryPrompt truncates content at MAX_MARKDOWN_LENGTH with marker" {
    const big = try testing.allocator.alloc(u8, MAX_MARKDOWN_LENGTH + 5_000);
    defer testing.allocator.free(big);
    @memset(big, 'a');

    const out = try buildSecondaryPrompt(testing.allocator, "summarize", big);
    defer testing.allocator.free(out);

    // The truncation marker must be present...
    try testing.expect(std.mem.indexOf(u8, out, "[Content truncated due to length...]") != null);
    // ...and the prompt must still be appended after it.
    try testing.expect(std.mem.indexOf(u8, out, "summarize") != null);

    // Exactly MAX_MARKDOWN_LENGTH content bytes survive (no more, no less).
    const header = "Web page content:\n";
    const a_run_start = header.len;
    var a_count: usize = 0;
    var i: usize = a_run_start;
    while (i < out.len and out[i] == 'a') : (i += 1) a_count += 1;
    try testing.expectEqual(MAX_MARKDOWN_LENGTH, a_count);
}

test "resolveSmallModel uses small model for anthropic, active model otherwise" {
    try testing.expectEqualStrings(
        "claude-haiku-4-5",
        resolveSmallModel("anthropic", "claude-opus-4-6", "claude-haiku-4-5"),
    );
    try testing.expectEqualStrings(
        "claude-haiku-4-5",
        resolveSmallModel("Anthropic", "claude-opus-4-6", "claude-haiku-4-5"),
    );
    // Non-anthropic provider falls back to the active model.
    try testing.expectEqualStrings(
        "gpt-4o",
        resolveSmallModel("openai", "gpt-4o", "claude-haiku-4-5"),
    );
    // Empty small model falls back to the active model even for anthropic.
    try testing.expectEqualStrings(
        "claude-opus-4-6",
        resolveSmallModel("anthropic", "claude-opus-4-6", ""),
    );
}
