//! Tool-use summary generator (cheap-model ~30-char label).
//!
//! Ported from claude-code-main/src/services/toolUseSummary/
//! toolUseSummaryGenerator.ts. The reference turns a completed batch of tool
//! calls into a single short past-tense label (think git-commit-subject) so an
//! SDK/streaming client can render a one-line progress row that truncates
//! around 30 characters on a phone screen.
//!
//! zcode has no such streaming-client consumer today, so the model call is
//! OPT-IN and the call-site wiring is deliberately deferred (see the phase-14
//! plan, task 14.17, and the out-of-scope notes). What ships here is the small,
//! fully-tested, self-contained core:
//!   - the system prompt (the commit-subject-style instruction),
//!   - `truncateField` (the JS `truncateJson(.., 300)` analog),
//!   - `buildSummaryPrompt` (assembles the user prompt from a tool batch + an
//!     optional intent prefix), and
//!   - `generate`, a best-effort wrapper that runs the cheap model and returns
//!     null on an empty batch or ANY error (summaries are non-critical).
//!
//! The model call reuses the existing cheap-model surface (the preprocessor
//! provider/model in `Settings`) rather than inventing a Haiku-specific path,
//! matching the plan's "reuse it rather than inventing one" note.

const std = @import("std");
const std_io = @import("std_io.zig");
const types = @import("types.zig");
const providers = @import("../providers/mod.zig");
const preprocessor = @import("preprocessor.zig");

/// Reuse the preprocessor's cheap-model settings struct so the summary call
/// rides the exact same provider/model/credentials surface zcode already has
/// for background work. No parallel config struct, no new keys.
pub const Settings = preprocessor.Settings;

/// Per-field truncation limit, matching the reference's `truncateJson(.., 300)`.
pub const MAX_FIELD_CHARS: usize = 300;

/// The intent context prefix is capped to this many characters, matching the
/// reference's `lastAssistantText.slice(0, 200)`.
pub const MAX_INTENT_CHARS: usize = 200;

/// Commit-subject-style instruction. Verbatim port of
/// TOOL_USE_SUMMARY_SYSTEM_PROMPT (no em/en dashes; the source uses none).
pub const SYSTEM_PROMPT =
    "Write a short summary label describing what these tool calls accomplished. " ++
    "It appears as a single-line row in a mobile app and truncates around 30 characters, " ++
    "so think git-commit-subject, not sentence.\n\n" ++
    "Keep the verb in past tense and the most distinctive noun. " ++
    "Drop articles, connectors, and long location context first.\n\n" ++
    "Examples:\n" ++
    "- Searched in auth/\n" ++
    "- Fixed NPE in UserService\n" ++
    "- Created signup endpoint\n" ++
    "- Read config.json\n" ++
    "- Ran failing tests";

/// One completed tool invocation. `input` and `output` are already-stringified
/// representations (zcode's tool traces carry strings, so unlike the reference
/// there is nothing to JSON-serialize here -- the truncation is applied to the
/// strings directly). All slices are borrowed; the struct owns nothing.
pub const ToolInfo = struct {
    name: []const u8,
    input: []const u8,
    output: []const u8,
};

/// Truncate `s` to at most `max` characters, appending "..." when it overflows.
///
/// Mirrors the reference's `truncateJson`: when the string is longer than
/// `max`, keep the first `max - 3` bytes and append "...". When `max < 3`
/// there is no room for the ellipsis, so just hard-cut to `max`. Always
/// returns a freshly allocated slice the caller owns.
pub fn truncateField(allocator: std.mem.Allocator, s: []const u8, max: usize) ![]u8 {
    if (s.len <= max) return allocator.dupe(u8, s);
    if (max < 3) return allocator.dupe(u8, s[0..max]);
    const head = s[0 .. max - 3];
    return std.fmt.allocPrint(allocator, "{s}...", .{head});
}

/// Build the user prompt from a completed tool batch plus an optional intent
/// prefix. Mirrors the reference's `generateToolUseSummary` body:
///
///   {intent_prefix}Tools completed:
///
///   Tool: <name>
///   Input: <input truncated to 300>
///   Output: <output truncated to 300>
///
///   <blank line between tools>
///
///   Label:
///
/// `intent` is the assistant's last-message text (the "user's intent"); when
/// non-empty it is capped to `MAX_INTENT_CHARS` and rendered as a leading
/// context line. Returns a freshly allocated slice the caller owns.
pub fn buildSummaryPrompt(
    allocator: std.mem.Allocator,
    batch: []const ToolInfo,
    intent: []const u8,
) ![]u8 {
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();

    if (intent.len > 0) {
        const capped = if (intent.len > MAX_INTENT_CHARS) intent[0..MAX_INTENT_CHARS] else intent;
        try buf.writer().print(
            "User's intent (from assistant's last message): {s}\n\n",
            .{capped},
        );
    }

    try buf.writer().writeAll("Tools completed:\n\n");

    for (batch, 0..) |tool, i| {
        if (i > 0) try buf.writer().writeAll("\n\n");
        const input_str = try truncateField(allocator, tool.input, MAX_FIELD_CHARS);
        defer allocator.free(input_str);
        const output_str = try truncateField(allocator, tool.output, MAX_FIELD_CHARS);
        defer allocator.free(output_str);
        try buf.writer().print(
            "Tool: {s}\nInput: {s}\nOutput: {s}",
            .{ tool.name, input_str, output_str },
        );
    }

    try buf.writer().writeAll("\n\nLabel:");

    return buf.toOwnedSlice();
}

/// Best-effort summary generation. Runs the cheap model and returns the trimmed
/// label, or null when the batch is empty OR any error occurs (summaries are
/// non-critical, so every failure path is swallowed and surfaces as null --
/// matching the reference's catch-return-null contract).
///
/// `settings` reuses the preprocessor cheap-model surface; when it is disabled
/// or missing a provider/model, this returns null without touching the network.
/// The returned slice (when non-null) is freshly allocated and caller-owned.
pub fn generate(
    allocator: std.mem.Allocator,
    settings: Settings,
    batch: []const ToolInfo,
    intent: []const u8,
) ?[]u8 {
    if (batch.len == 0) return null;
    if (!settings.enabled) return null;
    if (settings.provider.len == 0 or settings.model.len == 0) return null;

    return generateInner(allocator, settings, batch, intent) catch null;
}

fn generateInner(
    allocator: std.mem.Allocator,
    settings: Settings,
    batch: []const ToolInfo,
    intent: []const u8,
) !?[]u8 {
    const prompt_text = try buildSummaryPrompt(allocator, batch, intent);
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
        .system_prompt = SYSTEM_PROMPT,
        .prompt = prompt_text,
        .max_output_tokens = if (settings.max_output_tokens > 0) settings.max_output_tokens else 64,
        .temperature = 0.0,
    };

    const response = try adapter.send(allocator, request);
    defer allocator.free(response.raw);
    defer allocator.free(response.text);

    const trimmed = std.mem.trim(u8, response.text, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

const testing = std.testing;

test "truncateField leaves short strings untouched" {
    const out = try truncateField(testing.allocator, "short", MAX_FIELD_CHARS);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("short", out);
}

test "truncateField caps at max and appends an ellipsis marker" {
    const long = "x" ** 400;
    const out = try truncateField(testing.allocator, long, 300);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 300), out.len);
    try testing.expectEqualStrings("...", out[297..300]);
    // First 297 bytes are the original head.
    try testing.expectEqualStrings("x" ** 297, out[0..297]);
}

test "truncateField exactly at max is not truncated" {
    const exact = "y" ** 300;
    const out = try truncateField(testing.allocator, exact, 300);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 300), out.len);
    // No ellipsis: the boundary case keeps the full string.
    try testing.expect(std.mem.indexOf(u8, out, "...") == null);
}

test "buildSummaryPrompt includes commit-subject instruction context and truncated batch fields" {
    const batch = [_]ToolInfo{
        .{ .name = "Grep", .input = "pattern=foo", .output = "3 matches" },
        .{ .name = "Read", .input = "config.json", .output = "{ ... }" },
    };
    const prompt = try buildSummaryPrompt(testing.allocator, &batch, "");
    defer testing.allocator.free(prompt);

    // The batch fields appear under the reference's labels.
    try testing.expect(std.mem.indexOf(u8, prompt, "Tools completed:") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Tool: Grep") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Input: pattern=foo") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Output: 3 matches") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Tool: Read") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Label:") != null);

    // The system prompt itself carries the commit-subject-style instruction.
    try testing.expect(std.mem.indexOf(u8, SYSTEM_PROMPT, "git-commit-subject") != null);
}

test "buildSummaryPrompt truncates an oversized field to 300 chars plus ellipsis" {
    const big = "z" ** 500;
    const batch = [_]ToolInfo{
        .{ .name = "Bash", .input = big, .output = "ok" },
    };
    const prompt = try buildSummaryPrompt(testing.allocator, &batch, "");
    defer testing.allocator.free(prompt);

    // The 500-char input must not appear verbatim; the truncated head + "..."
    // does. The full 500-z run is absent because it was capped to 300.
    try testing.expect(std.mem.indexOf(u8, prompt, big) == null);
    const head = "z" ** 297 ++ "...";
    try testing.expect(std.mem.indexOf(u8, prompt, head) != null);
}

test "buildSummaryPrompt renders and caps the intent prefix" {
    const long_intent = "i" ** 250;
    const batch = [_]ToolInfo{
        .{ .name = "Read", .input = "a", .output = "b" },
    };
    const prompt = try buildSummaryPrompt(testing.allocator, &batch, long_intent);
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "User's intent (from assistant's last message):") != null);
    // Intent capped to 200 chars: the full 250-i run is absent, a 200-i run present.
    try testing.expect(std.mem.indexOf(u8, prompt, long_intent) == null);
    try testing.expect(std.mem.indexOf(u8, prompt, "i" ** 200) != null);
}

test "buildSummaryPrompt omits the intent line when intent is empty" {
    const batch = [_]ToolInfo{
        .{ .name = "Read", .input = "a", .output = "b" },
    };
    const prompt = try buildSummaryPrompt(testing.allocator, &batch, "");
    defer testing.allocator.free(prompt);
    try testing.expect(std.mem.indexOf(u8, prompt, "User's intent") == null);
}

test "generate returns null on an empty batch" {
    const settings = Settings{
        .enabled = true,
        .provider = "mock",
        .model = "mock-agent",
        .max_output_tokens = 64,
    };
    const out = generate(testing.allocator, settings, &.{}, "");
    try testing.expect(out == null);
}

test "generate returns null when disabled or unconfigured" {
    const batch = [_]ToolInfo{
        .{ .name = "Read", .input = "a", .output = "b" },
    };
    // Disabled.
    try testing.expect(generate(testing.allocator, .{
        .enabled = false,
        .provider = "mock",
        .model = "mock-agent",
        .max_output_tokens = 64,
    }, &batch, "") == null);
    // Missing provider.
    try testing.expect(generate(testing.allocator, .{
        .enabled = true,
        .provider = "",
        .model = "mock-agent",
        .max_output_tokens = 64,
    }, &batch, "") == null);
    // Missing model.
    try testing.expect(generate(testing.allocator, .{
        .enabled = true,
        .provider = "mock",
        .model = "",
        .max_output_tokens = 64,
    }, &batch, "") == null);
}

test "generate returns null on an unknown provider (no panic)" {
    const batch = [_]ToolInfo{
        .{ .name = "Read", .input = "a", .output = "b" },
    };
    // An unknown provider makes createAdapterWithOverrides fail; generate must
    // swallow the error and return null rather than propagate it.
    const out = generate(testing.allocator, .{
        .enabled = true,
        .provider = "definitely-not-a-real-provider",
        .model = "x",
        .max_output_tokens = 64,
    }, &batch, "");
    try testing.expect(out == null);
}

test "generate returns the trimmed label from the mock provider" {
    const batch = [_]ToolInfo{
        .{ .name = "Grep", .input = "pattern=foo", .output = "3 matches" },
    };
    const out = generate(testing.allocator, .{
        .enabled = true,
        .provider = "mock",
        .model = "mock-agent",
        .max_output_tokens = 64,
    }, &batch, "");
    // The mock returns a non-empty canned response; generate yields a trimmed,
    // owned, non-empty label (the exact text is the mock's default JSON blob).
    try testing.expect(out != null);
    if (out) |label| {
        defer testing.allocator.free(label);
        try testing.expect(label.len > 0);
        // Trimmed: no leading/trailing whitespace.
        try testing.expect(label[0] != ' ' and label[0] != '\n');
    }
}
