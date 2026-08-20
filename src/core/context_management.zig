//! Native Anthropic API context-management edits (opt-in / deferable).
//!
//! Port of the reference's `services/compact/apiMicrocompact.ts`
//! (`getAPIContextManagement`). Builds a `context_management` request-body
//! object that asks the Anthropic server to clear old tool results / tool
//! uses / thinking blocks server-side, so the client does not have to
//! locally mutate history. This is feature-gated in the reference
//! (ant-only for tool clearing) and is DEFAULT-OFF here: with no opt-in
//! env set, `buildConfigJson` returns null and the request body is
//! unchanged, so non-supporting Anthropic endpoints are never affected.
//!
//! The returned JSON is a bare object literal (not quoted) suitable for
//! verbatim embedding into the request body, the same contract as
//! `types.ModelRequest.response_schema`. The caller owns the returned
//! slice and must free it.
//!
//! Pure with respect to IO: it only reads the documented env overrides
//! (through small explicit overloads so tests stay hermetic) and
//! allocates a string. No network, no global state beyond env.

const std = @import("std");
const env = @import("env.zig");

/// Default trigger threshold (input tokens) that fires server-side
/// tool clearing. Matches DEFAULT_MAX_INPUT_TOKENS (apiMicrocompact.ts:16).
pub const DEFAULT_MAX_INPUT_TOKENS: usize = 180_000;
/// Default number of input tokens to keep after a clear. Matches
/// DEFAULT_TARGET_INPUT_TOKENS (apiMicrocompact.ts:17).
pub const DEFAULT_TARGET_INPUT_TOKENS: usize = 40_000;

/// Strategy version identifiers, frozen by the API. Bump only when the
/// Anthropic API ships a new dated strategy version.
pub const CLEAR_TOOL_USES_TYPE = "clear_tool_uses_20250919";
pub const CLEAR_THINKING_TYPE = "clear_thinking_20251015";

/// Tools whose RESULTS are safe to clear (read-style tools that can be
/// re-run). Mirrors TOOLS_CLEARABLE_RESULTS (apiMicrocompact.ts:19-26),
/// using zcode's tool names.
const TOOLS_CLEARABLE_RESULTS = [_][]const u8{
    "Bash",
    "Glob",
    "Grep",
    "Read",
    "WebFetch",
    "WebSearch",
};

/// Tools whose USES must be PRESERVED (write-style tools that mutate
/// state, so dropping the tool_use would lose the record of the edit).
/// Mirrors TOOLS_CLEARABLE_USES used as `exclude_tools`
/// (apiMicrocompact.ts:28-32), using zcode's tool names.
const TOOLS_PRESERVED_USES = [_][]const u8{
    "Edit",
    "Write",
    "NotebookEdit",
};

/// Env var names. Registered in env_registry.zig so doctor / --list-env
/// know about them.
pub const ENV_USE_API_CLEAR_TOOL_RESULTS = "USE_API_CLEAR_TOOL_RESULTS";
pub const ENV_USE_API_CLEAR_TOOL_USES = "USE_API_CLEAR_TOOL_USES";
pub const ENV_API_MAX_INPUT_TOKENS = "API_MAX_INPUT_TOKENS";
pub const ENV_API_TARGET_INPUT_TOKENS = "API_TARGET_INPUT_TOKENS";

/// Resolved options for building the config, all passed explicitly so the
/// pure builder never touches env directly (keeps tests hermetic).
pub const Options = struct {
    /// Whether an assistant thinking block is active this request (enables
    /// the clear_thinking strategy). Mirrors `hasThinking`.
    has_thinking: bool = false,
    /// When thinking is redacted there is no model-visible content to keep,
    /// so the clear_thinking strategy is skipped. Mirrors
    /// `isRedactThinkingActive`.
    is_redact_thinking_active: bool = false,
    /// >1h idle / cache miss: keep only the last thinking turn instead of
    /// "all". Mirrors `clearAllThinking`.
    clear_all_thinking: bool = false,
    /// Opt-in: emit a clear_tool_uses strategy that clears READ-tool
    /// results (USE_API_CLEAR_TOOL_RESULTS).
    use_clear_tool_results: bool = false,
    /// Opt-in: emit a clear_tool_uses strategy that excludes WRITE-tool
    /// uses (USE_API_CLEAR_TOOL_USES).
    use_clear_tool_uses: bool = false,
    /// Trigger threshold (input tokens). Null -> DEFAULT_MAX_INPUT_TOKENS.
    max_input_tokens: ?usize = null,
    /// Keep target (input tokens). Null -> DEFAULT_TARGET_INPUT_TOKENS.
    target_input_tokens: ?usize = null,
};

/// Build the `context_management` JSON object as a bare object literal, or
/// null when no strategy is active. Caller owns the returned slice.
///
/// Mirrors getAPIContextManagement (apiMicrocompact.ts:64-153): the
/// thinking strategy emits whenever thinking is active and not redacted;
/// the tool-clearing strategies emit only when their opt-in flag is set.
/// `clear_at_least` is `trigger - target` (saturating).
pub fn buildConfigJson(allocator: std.mem.Allocator, opts: Options) !?[]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    var wrote_any = false;
    try w.writeAll("{\"edits\":[");

    // 1. Thinking preservation strategy (generally available).
    if (opts.has_thinking and !opts.is_redact_thinking_active) {
        try w.print("{{\"type\":\"{s}\",\"keep\":", .{CLEAR_THINKING_TYPE});
        if (opts.clear_all_thinking) {
            // Keep only the last thinking turn -- the schema requires
            // value >= 1, and omitting falls back to the model default.
            try w.writeAll("{\"type\":\"thinking_turns\",\"value\":1}");
        } else {
            try w.writeAll("\"all\"");
        }
        try w.writeAll("}");
        wrote_any = true;
    }

    const trigger = opts.max_input_tokens orelse DEFAULT_MAX_INPUT_TOKENS;
    const target = opts.target_input_tokens orelse DEFAULT_TARGET_INPUT_TOKENS;
    const clear_at_least = trigger -| target;

    // 2. Clear READ-tool results.
    if (opts.use_clear_tool_results) {
        if (wrote_any) try w.writeAll(",");
        try writeToolUsesStrategy(w, trigger, clear_at_least, .clear_inputs);
        wrote_any = true;
    }

    // 3. Clear tool uses, excluding WRITE tools.
    if (opts.use_clear_tool_uses) {
        if (wrote_any) try w.writeAll(",");
        try writeToolUsesStrategy(w, trigger, clear_at_least, .exclude_tools);
        wrote_any = true;
    }

    if (!wrote_any) {
        out.deinit();
        return null;
    }

    try w.writeAll("]}");
    var list = out.toArrayList();
    return try list.toOwnedSlice(allocator);
}

const ToolStrategyKind = enum { clear_inputs, exclude_tools };

fn writeToolUsesStrategy(
    w: *std.Io.Writer,
    trigger: usize,
    clear_at_least: usize,
    kind: ToolStrategyKind,
) !void {
    try w.print(
        "{{\"type\":\"{s}\",\"trigger\":{{\"type\":\"input_tokens\",\"value\":{d}}},\"clear_at_least\":{{\"type\":\"input_tokens\",\"value\":{d}}},",
        .{ CLEAR_TOOL_USES_TYPE, trigger, clear_at_least },
    );
    switch (kind) {
        .clear_inputs => {
            try w.writeAll("\"clear_tool_inputs\":");
            try writeJsonStringArray(w, &TOOLS_CLEARABLE_RESULTS);
        },
        .exclude_tools => {
            try w.writeAll("\"exclude_tools\":");
            try writeJsonStringArray(w, &TOOLS_PRESERVED_USES);
        },
    }
    try w.writeAll("}");
}

fn writeJsonStringArray(w: *std.Io.Writer, items: []const []const u8) !void {
    try w.writeAll("[");
    for (items, 0..) |item, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{f}", .{std.json.fmt(item, .{})});
    }
    try w.writeAll("]");
}

// ── Env-reading wrapper ───────────────────────────────────────────────
//
// Reads the four documented opt-in env vars and delegates to the pure
// builder. The tool-clearing strategies stay default-off: if neither
// USE_API_CLEAR_TOOL_RESULTS nor USE_API_CLEAR_TOOL_USES is truthy and no
// thinking is active, this returns null and the request body is unchanged.

/// Build the config from env + the supplied thinking flags. `has_thinking`
/// / `is_redact_thinking_active` / `clear_all_thinking` come from the
/// caller (the request itself), not env. Caller owns the returned slice.
pub fn buildConfigJsonFromEnv(
    allocator: std.mem.Allocator,
    has_thinking: bool,
    is_redact_thinking_active: bool,
    clear_all_thinking: bool,
) !?[]u8 {
    const opts = Options{
        .has_thinking = has_thinking,
        .is_redact_thinking_active = is_redact_thinking_active,
        .clear_all_thinking = clear_all_thinking,
        .use_clear_tool_results = env.isEnvTruthy(ENV_USE_API_CLEAR_TOOL_RESULTS),
        .use_clear_tool_uses = env.isEnvTruthy(ENV_USE_API_CLEAR_TOOL_USES),
        .max_input_tokens = parseUsizeEnv(ENV_API_MAX_INPUT_TOKENS),
        .target_input_tokens = parseUsizeEnv(ENV_API_TARGET_INPUT_TOKENS),
    };
    return buildConfigJson(allocator, opts);
}

fn parseUsizeEnv(name: []const u8) ?usize {
    const raw = env.getenv(name) orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    const parsed = std.fmt.parseInt(usize, trimmed, 10) catch return null;
    if (parsed == 0) return null;
    return parsed;
}

const testing = std.testing;

test "buildConfigJson returns null with no strategy active" {
    const got = try buildConfigJson(testing.allocator, .{});
    try testing.expect(got == null);
}

test "buildConfigJson emits clear_tool_uses with trigger and clear_at_least" {
    const got = try buildConfigJson(testing.allocator, .{ .use_clear_tool_results = true });
    try testing.expect(got != null);
    const json = got.?;
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "clear_tool_uses_20250919") != null);
    // Default trigger 180k, target 40k -> clear_at_least 140k.
    try testing.expect(std.mem.indexOf(u8, json, "\"trigger\":{\"type\":\"input_tokens\",\"value\":180000}") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"clear_at_least\":{\"type\":\"input_tokens\",\"value\":140000}") != null);
    // Result clearing carries clear_tool_inputs with the read-tool names.
    try testing.expect(std.mem.indexOf(u8, json, "\"clear_tool_inputs\":") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"Read\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"Bash\"") != null);
}

test "buildConfigJson honours custom trigger and target" {
    const got = try buildConfigJson(testing.allocator, .{
        .use_clear_tool_uses = true,
        .max_input_tokens = 100_000,
        .target_input_tokens = 30_000,
    });
    try testing.expect(got != null);
    const json = got.?;
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"value\":100000") != null);
    // clear_at_least = 100k - 30k = 70k.
    try testing.expect(std.mem.indexOf(u8, json, "\"clear_at_least\":{\"type\":\"input_tokens\",\"value\":70000}") != null);
    // Tool-USE clearing excludes the write tools.
    try testing.expect(std.mem.indexOf(u8, json, "\"exclude_tools\":") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"Write\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"Edit\"") != null);
}

test "buildConfigJson clear_at_least saturates when target exceeds trigger" {
    const got = try buildConfigJson(testing.allocator, .{
        .use_clear_tool_results = true,
        .max_input_tokens = 10_000,
        .target_input_tokens = 40_000,
    });
    try testing.expect(got != null);
    const json = got.?;
    defer testing.allocator.free(json);
    // 10k - 40k saturates to 0, never underflows usize.
    try testing.expect(std.mem.indexOf(u8, json, "\"clear_at_least\":{\"type\":\"input_tokens\",\"value\":0}") != null);
}

test "buildConfigJson emits clear_thinking when thinking active" {
    const got = try buildConfigJson(testing.allocator, .{ .has_thinking = true });
    try testing.expect(got != null);
    const json = got.?;
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "clear_thinking_20251015") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"keep\":\"all\"") != null);
}

test "buildConfigJson keeps last thinking turn when clear_all_thinking set" {
    const got = try buildConfigJson(testing.allocator, .{
        .has_thinking = true,
        .clear_all_thinking = true,
    });
    try testing.expect(got != null);
    const json = got.?;
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"keep\":{\"type\":\"thinking_turns\",\"value\":1}") != null);
}

test "buildConfigJson skips thinking when redacted" {
    const got = try buildConfigJson(testing.allocator, .{
        .has_thinking = true,
        .is_redact_thinking_active = true,
    });
    // Only strategy was thinking, and it is skipped -> null.
    try testing.expect(got == null);
}

test "buildConfigJson combines thinking and tool clearing into one edits array" {
    const got = try buildConfigJson(testing.allocator, .{
        .has_thinking = true,
        .use_clear_tool_results = true,
        .use_clear_tool_uses = true,
    });
    try testing.expect(got != null);
    const json = got.?;
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "clear_thinking_20251015") != null);
    // Two clear_tool_uses strategies (results + uses) plus thinking.
    try testing.expect(std.mem.startsWith(u8, json, "{\"edits\":["));
    try testing.expect(std.mem.endsWith(u8, json, "]}"));
    // The result strategy uses clear_tool_inputs; the uses strategy uses exclude_tools.
    try testing.expect(std.mem.indexOf(u8, json, "\"clear_tool_inputs\":") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"exclude_tools\":") != null);
}

test "buildConfigJsonFromEnv stays default-off with no env and no thinking" {
    const got = try buildConfigJsonFromEnv(testing.allocator, false, false, false);
    try testing.expect(got == null);
}
