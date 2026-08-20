const std = @import("std");
const std_io = @import("std_io.zig");

/// Actionable suggestions for reducing context usage. Ported from
/// claude-code-main/src/utils/contextSuggestions.ts generateContextSuggestions.
///
/// The reference returns five kinds of suggestions driven by shape
/// and breakdown of the current context window. zcode's prompt engine
/// does not yet track per-tool token breakdown or memory-file sizing
/// at runtime, so this first pass ports the three checks we CAN
/// evaluate with data already in `AgentRuntime`:
///
///   1. `checkNearCapacity`        -- context >= warn_percent
///   2. `checkAutoCompactDisabled` -- compaction disabled + mid-range
///   3. `checkMemoryBloat`         -- when size info is available
///
/// Phase 8 (compaction-12) implements the fourth reference check,
/// `checkToolBloat`, which fires when a single tool dominates the
/// history-token budget. It consumes the per-tool breakdown produced by
/// `prompt_analysis.Analysis.per_tool`.
pub const Severity = enum {
    info,
    warning,
};

/// One tool's aggregated token usage, mirroring
/// `prompt_analysis.ToolUsage` but kept here as a flat input so
/// context_suggestions does not import the analysis module. The caller
/// (the `/context` path) translates `ToolUsage` into this shape.
pub const ToolTokens = struct {
    name: []const u8,
    /// Combined request + result tokens for all calls of this tool.
    total_tokens: usize,
};

pub const Suggestion = struct {
    severity: Severity,
    title: []u8,
    detail: []u8,
    savings_tokens: usize = 0,

    pub fn deinit(self: *Suggestion, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.detail);
    }
};

pub const ContextData = struct {
    /// Whole percentage used of the context window (0..100).
    percentage: u8,
    /// Raw context window size (tokens).
    raw_max_tokens: usize,
    /// Input tokens counted against the window on the last turn.
    used_tokens: usize,
    /// Compact threshold in whole percent (zcode default: 60).
    compact_threshold_percent: u8,
    /// Force threshold in whole percent (zcode default: 80).
    force_threshold_percent: u8,
    /// True when auto-compact (maybeCompact) will fire on the next
    /// turn if usage crosses compact_threshold_percent. Always true
    /// on zcode today; exposed as a parameter so a future "disable
    /// autocompact" config flag can flip it off.
    auto_compact_enabled: bool,
    /// Bytes occupied by all memory files loaded into context (or 0
    /// when memory sizing is not available). Used by checkMemoryBloat.
    memory_file_bytes: usize = 0,
    /// Phase 8 (compaction-17): suppress the near-capacity warning for one
    /// turn after a successful compaction. Right after compaction the runtime
    /// has no accurate token count until the next API response, so the stale
    /// pre-compaction percentage would otherwise re-fire the "context is N%
    /// full" warning even though we just freed space. The runtime sets this
    /// true after `forceCompaction`, consumes-and-clears it the next time the
    /// warning would be computed. Mirrors the reference compactWarningStore /
    /// suppressCompactWarning (compactWarningState.ts).
    suppress_near_capacity: bool = false,
    /// Phase 8 (compaction-12): per-tool token breakdown driving
    /// `checkToolBloat`. Empty by default; the `/context` path fills it from
    /// `prompt_analysis.Analysis.per_tool`. The check compares each tool's
    /// total against `history_tokens`.
    tool_breakdown: []const ToolTokens = &.{},
    /// Total history tokens (sum across all turns). Denominator for the
    /// tool-bloat percentage. When 0, `checkToolBloat` is a no-op.
    history_tokens: usize = 0,
};

/// Warn when context is at or past the "force compact" threshold --
/// the user is one turn away from losing older messages whether they
/// asked or not. Matches reference's checkNearCapacity.
const FORCE_COMPACT_BUFFER_PERCENT: u8 = 0;
/// Context % band at which zcode starts nudging the user about
/// autocompact being off. Reference uses 50..80; zcode matches.
const LOW_WATER_PERCENT: u8 = 50;
/// Memory-file bytes threshold before suggesting a prune. zcode
/// currently caps memory at 2 KiB per entry; 5 KiB total is already
/// enough to notice in a long session.
const MEMORY_BLOAT_BYTES: usize = 5 * 1024;
/// A single tool consuming this share of history tokens (or more) is
/// flagged as bloat. The reference uses a tool-specific set of thresholds
/// (contextSuggestions.ts:70-148); zcode uses one conservative cutoff at
/// 30% of history tokens, matching the plan's guidance.
const TOOL_BLOAT_PERCENT: usize = 30;

/// Generate the suggestion list for the given context data. The
/// caller owns the returned slice and every Suggestion inside it.
/// Suggestions are sorted warnings-first, then by descending
/// savings_tokens so the most impactful advice shows at the top.
pub fn generate(
    allocator: std.mem.Allocator,
    data: ContextData,
) ![]Suggestion {
    var list = std.array_list.Managed(Suggestion).init(allocator);
    errdefer {
        for (list.items) |*s| s.deinit(allocator);
        list.deinit();
    }

    try checkNearCapacity(allocator, data, &list);
    try checkAutoCompactDisabled(allocator, data, &list);
    try checkMemoryBloat(allocator, data, &list);
    try checkToolBloat(allocator, data, &list);

    std.mem.sort(Suggestion, list.items, {}, lessThan);
    return list.toOwnedSlice();
}

/// Free a slice of suggestions returned by `generate`.
pub fn freeSuggestions(allocator: std.mem.Allocator, suggestions: []Suggestion) void {
    for (suggestions) |*s| s.deinit(allocator);
    allocator.free(suggestions);
}

/// Comparator: warnings before info; within the same severity, higher
/// savings_tokens first.
fn lessThan(_: void, a: Suggestion, b: Suggestion) bool {
    if (a.severity != b.severity) {
        return a.severity == .warning and b.severity == .info;
    }
    return a.savings_tokens > b.savings_tokens;
}

fn checkNearCapacity(
    allocator: std.mem.Allocator,
    data: ContextData,
    out: *std.array_list.Managed(Suggestion),
) !void {
    // Phase 8 (compaction-17): one-turn suppression right after a compaction.
    // The percentage we hold is the stale pre-compaction count, so skip the
    // near-capacity warning entirely when the runtime asked us to.
    if (data.suppress_near_capacity) return;

    const force = data.force_threshold_percent;
    if (data.percentage < force -| FORCE_COMPACT_BUFFER_PERCENT) return;

    const title = try std.fmt.allocPrint(
        allocator,
        "Context is {d}% full",
        .{data.percentage},
    );
    errdefer allocator.free(title);

    const detail: []u8 = if (data.auto_compact_enabled)
        try allocator.dupe(
            u8,
            "Autocompact will trigger soon, which discards older messages. Use /compact now to control what gets kept.",
        )
    else
        try allocator.dupe(
            u8,
            "Autocompact is disabled. Use /compact to free space, or enable autocompact in your config.",
        );
    errdefer allocator.free(detail);

    try out.append(.{
        .severity = .warning,
        .title = title,
        .detail = detail,
        .savings_tokens = 0,
    });
}

fn checkAutoCompactDisabled(
    allocator: std.mem.Allocator,
    data: ContextData,
    out: *std.array_list.Managed(Suggestion),
) !void {
    if (data.auto_compact_enabled) return;
    if (data.percentage < LOW_WATER_PERCENT or
        data.percentage >= data.force_threshold_percent) return;

    const title = try allocator.dupe(u8, "Autocompact is disabled");
    errdefer allocator.free(title);

    const detail = try allocator.dupe(
        u8,
        "Without autocompact, you will hit context limits and lose the conversation. Enable it in your config or use /compact manually.",
    );
    errdefer allocator.free(detail);

    try out.append(.{
        .severity = .info,
        .title = title,
        .detail = detail,
        .savings_tokens = 0,
    });
}

fn checkMemoryBloat(
    allocator: std.mem.Allocator,
    data: ContextData,
    out: *std.array_list.Managed(Suggestion),
) !void {
    if (data.memory_file_bytes < MEMORY_BLOAT_BYTES) return;

    const title = try std.fmt.allocPrint(
        allocator,
        "Memory files using {d} KiB",
        .{data.memory_file_bytes / 1024},
    );
    errdefer allocator.free(title);

    const detail = try allocator.dupe(
        u8,
        "Review and prune stale memory entries with /memory. Large memory files burn context on every turn.",
    );
    errdefer allocator.free(detail);

    // Assume ~30% of memory weight is prunable, mirroring reference.
    const estimated_savings = (data.memory_file_bytes / 4) / 3;

    try out.append(.{
        .severity = .info,
        .title = title,
        .detail = detail,
        .savings_tokens = estimated_savings,
    });
}

/// Flag tools that dominate the history-token budget. Ported (simplified)
/// from the reference's checkLargeToolResults / getLargeToolSuggestion
/// (contextSuggestions.ts:70-148). For each tool whose total tokens reach
/// TOOL_BLOAT_PERCENT of history tokens we emit one suggestion with a
/// tool-aware remediation hint. Silent when no breakdown is supplied or no
/// tool crosses the threshold.
fn checkToolBloat(
    allocator: std.mem.Allocator,
    data: ContextData,
    out: *std.array_list.Managed(Suggestion),
) !void {
    if (data.history_tokens == 0) return;

    for (data.tool_breakdown) |tool| {
        const percent = tool.total_tokens * 100 / data.history_tokens;
        if (percent < TOOL_BLOAT_PERCENT) continue;

        const title = try std.fmt.allocPrint(
            allocator,
            "{s} results using ~{d} tokens ({d}% of history)",
            .{ tool.name, tool.total_tokens, percent },
        );
        errdefer allocator.free(title);

        const detail = try allocator.dupe(u8, toolBloatHint(tool.name));
        errdefer allocator.free(detail);

        // Mirror the reference savings heuristic: Bash output is highly
        // compressible (~0.5), file/search reads ~0.3, everything else ~0.2.
        const savings = tool.total_tokens * toolSavingsNumerator(tool.name) / 100;

        try out.append(.{
            .severity = if (isBashName(tool.name)) .warning else .info,
            .title = title,
            .detail = detail,
            .savings_tokens = savings,
        });
    }
}

fn isBashName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Bash") or std.mem.eql(u8, name, "bash");
}

fn isReadName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Read") or
        std.mem.eql(u8, name, "read") or
        std.mem.eql(u8, name, "file_read");
}

fn isGrepName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Grep") or std.mem.eql(u8, name, "grep");
}

fn toolBloatHint(name: []const u8) []const u8 {
    if (isBashName(name)) {
        return "Pipe output through head, tail, or grep to reduce result size. Avoid cat on large files; use Read with offset/limit instead.";
    }
    if (isReadName(name)) {
        return "Use offset and limit to read only the sections you need. Avoid re-reading entire files when you only need a few lines.";
    }
    if (isGrepName(name)) {
        return "Add more specific patterns or narrow file types. Consider Glob for file discovery instead of Grep.";
    }
    return "This tool is consuming a significant portion of context. Narrow its scope or summarize its output.";
}

fn toolSavingsNumerator(name: []const u8) usize {
    if (isBashName(name)) return 50;
    if (isReadName(name) or isGrepName(name)) return 30;
    return 20;
}

/// Render a human-readable summary of a suggestion list. Returns an
/// owned slice. Used by `/usage` and `/context` to append warnings
/// under the numeric report.
pub fn renderSuggestionList(
    allocator: std.mem.Allocator,
    suggestions: []const Suggestion,
) ![]u8 {
    if (suggestions.len == 0) {
        return allocator.dupe(u8, "");
    }

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    try out.writer().writeAll("\nSuggestions:\n");
    for (suggestions) |s| {
        const marker: []const u8 = switch (s.severity) {
            .warning => "  [!]",
            .info => "  [i]",
        };
        try out.writer().print("{s} {s}\n", .{ marker, s.title });
        try out.writer().print("      {s}\n", .{s.detail});
    }
    return out.toOwnedSlice();
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "generate returns empty when context is well under capacity" {
    const data = ContextData{
        .percentage = 12,
        .raw_max_tokens = 100_000,
        .used_tokens = 12_000,
        .compact_threshold_percent = 60,
        .force_threshold_percent = 80,
        .auto_compact_enabled = true,
    };
    const list = try generate(testing.allocator, data);
    defer freeSuggestions(testing.allocator, list);
    try testing.expectEqual(@as(usize, 0), list.len);
}

test "generate warns at/above force threshold" {
    const data = ContextData{
        .percentage = 85,
        .raw_max_tokens = 100_000,
        .used_tokens = 85_000,
        .compact_threshold_percent = 60,
        .force_threshold_percent = 80,
        .auto_compact_enabled = true,
    };
    const list = try generate(testing.allocator, data);
    defer freeSuggestions(testing.allocator, list);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqual(Severity.warning, list[0].severity);
    try testing.expect(std.mem.indexOf(u8, list[0].title, "85%") != null);
    try testing.expect(std.mem.indexOf(u8, list[0].detail, "Autocompact will trigger") != null);
}

test "generate warns about disabled autocompact mid-range only" {
    const mid = ContextData{
        .percentage = 60,
        .raw_max_tokens = 100_000,
        .used_tokens = 60_000,
        .compact_threshold_percent = 60,
        .force_threshold_percent = 80,
        .auto_compact_enabled = false,
    };
    const list = try generate(testing.allocator, mid);
    defer freeSuggestions(testing.allocator, list);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqual(Severity.info, list[0].severity);
    try testing.expect(std.mem.indexOf(u8, list[0].title, "Autocompact is disabled") != null);
}

test "generate escalates to warning tone when disabled and near capacity" {
    // When both checks fire, we get a warning (force band) not the
    // disabled-autocompact info. Mid-range disabled-autocompact is
    // suppressed because the force-threshold warning supersedes it.
    const near_capacity = ContextData{
        .percentage = 88,
        .raw_max_tokens = 100_000,
        .used_tokens = 88_000,
        .compact_threshold_percent = 60,
        .force_threshold_percent = 80,
        .auto_compact_enabled = false,
    };
    const list = try generate(testing.allocator, near_capacity);
    defer freeSuggestions(testing.allocator, list);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqual(Severity.warning, list[0].severity);
    try testing.expect(std.mem.indexOf(u8, list[0].detail, "Autocompact is disabled") != null);
}

test "memory bloat check fires at >= 5 KiB" {
    const data = ContextData{
        .percentage = 20,
        .raw_max_tokens = 100_000,
        .used_tokens = 20_000,
        .compact_threshold_percent = 60,
        .force_threshold_percent = 80,
        .auto_compact_enabled = true,
        .memory_file_bytes = 8 * 1024,
    };
    const list = try generate(testing.allocator, data);
    defer freeSuggestions(testing.allocator, list);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqual(Severity.info, list[0].severity);
    try testing.expect(std.mem.indexOf(u8, list[0].title, "Memory files") != null);
}

test "memory bloat check silent under threshold" {
    const data = ContextData{
        .percentage = 20,
        .raw_max_tokens = 100_000,
        .used_tokens = 20_000,
        .compact_threshold_percent = 60,
        .force_threshold_percent = 80,
        .auto_compact_enabled = true,
        .memory_file_bytes = 2 * 1024,
    };
    const list = try generate(testing.allocator, data);
    defer freeSuggestions(testing.allocator, list);
    try testing.expectEqual(@as(usize, 0), list.len);
}

test "suggestions sort warnings before info" {
    // Trigger both a warning (near capacity) and an info (memory bloat)
    // simultaneously. Warning must come first regardless of savings.
    const data = ContextData{
        .percentage = 85,
        .raw_max_tokens = 100_000,
        .used_tokens = 85_000,
        .compact_threshold_percent = 60,
        .force_threshold_percent = 80,
        .auto_compact_enabled = true,
        .memory_file_bytes = 12 * 1024,
    };
    const list = try generate(testing.allocator, data);
    defer freeSuggestions(testing.allocator, list);
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqual(Severity.warning, list[0].severity);
    try testing.expectEqual(Severity.info, list[1].severity);
}

test "renderSuggestionList emits warning and info markers" {
    const data = ContextData{
        .percentage = 85,
        .raw_max_tokens = 100_000,
        .used_tokens = 85_000,
        .compact_threshold_percent = 60,
        .force_threshold_percent = 80,
        .auto_compact_enabled = true,
        .memory_file_bytes = 12 * 1024,
    };
    const list = try generate(testing.allocator, data);
    defer freeSuggestions(testing.allocator, list);
    const rendered = try renderSuggestionList(testing.allocator, list);
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.indexOf(u8, rendered, "[!]") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "[i]") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "Suggestions:") != null);
}

test "renderSuggestionList empty for empty list" {
    const empty: []const Suggestion = &.{};
    const rendered = try renderSuggestionList(testing.allocator, empty);
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings("", rendered);
}

test "near-capacity warning suppressed for one turn after compaction" {
    // compaction-17: with suppress_near_capacity set, the near-capacity
    // warning does not fire even though percentage is above the force band.
    // Clearing the flag restores the warning.
    const base = ContextData{
        .percentage = 90,
        .raw_max_tokens = 100_000,
        .used_tokens = 90_000,
        .compact_threshold_percent = 60,
        .force_threshold_percent = 80,
        .auto_compact_enabled = true,
        .suppress_near_capacity = true,
    };

    // Suppressed: no warning despite being well over the force threshold.
    const suppressed = try generate(testing.allocator, base);
    defer freeSuggestions(testing.allocator, suppressed);
    try testing.expectEqual(@as(usize, 0), suppressed.len);

    // Flag cleared: the warning re-appears.
    var data = base;
    data.suppress_near_capacity = false;
    const restored = try generate(testing.allocator, data);
    defer freeSuggestions(testing.allocator, restored);
    try testing.expectEqual(@as(usize, 1), restored.len);
    try testing.expectEqual(Severity.warning, restored[0].severity);
}

test "tool bloat check fires when one tool dominates history tokens" {
    // compaction-12: Bash at 60% of history tokens crosses the 30% cutoff.
    const tools = [_]ToolTokens{
        .{ .name = "Bash", .total_tokens = 6_000 },
        .{ .name = "Read", .total_tokens = 1_000 },
    };
    const data = ContextData{
        .percentage = 20,
        .raw_max_tokens = 100_000,
        .used_tokens = 20_000,
        .compact_threshold_percent = 60,
        .force_threshold_percent = 80,
        .auto_compact_enabled = true,
        .tool_breakdown = &tools,
        .history_tokens = 10_000,
    };
    const list = try generate(testing.allocator, data);
    defer freeSuggestions(testing.allocator, list);
    try testing.expectEqual(@as(usize, 1), list.len);
    // Bash is the warning-tier tool.
    try testing.expectEqual(Severity.warning, list[0].severity);
    try testing.expect(std.mem.indexOf(u8, list[0].title, "Bash") != null);
    try testing.expect(std.mem.indexOf(u8, list[0].title, "60%") != null);
    // Bash savings heuristic is 50%.
    try testing.expectEqual(@as(usize, 3_000), list[0].savings_tokens);
}

test "tool bloat check silent when no tool crosses threshold" {
    const tools = [_]ToolTokens{
        .{ .name = "Bash", .total_tokens = 2_000 },
        .{ .name = "Read", .total_tokens = 2_500 },
    };
    const data = ContextData{
        .percentage = 20,
        .raw_max_tokens = 100_000,
        .used_tokens = 20_000,
        .compact_threshold_percent = 60,
        .force_threshold_percent = 80,
        .auto_compact_enabled = true,
        .tool_breakdown = &tools,
        .history_tokens = 10_000,
    };
    const list = try generate(testing.allocator, data);
    defer freeSuggestions(testing.allocator, list);
    try testing.expectEqual(@as(usize, 0), list.len);
}

test "tool bloat check silent with no breakdown" {
    const data = ContextData{
        .percentage = 20,
        .raw_max_tokens = 100_000,
        .used_tokens = 20_000,
        .compact_threshold_percent = 60,
        .force_threshold_percent = 80,
        .auto_compact_enabled = true,
        .history_tokens = 10_000,
    };
    const list = try generate(testing.allocator, data);
    defer freeSuggestions(testing.allocator, list);
    try testing.expectEqual(@as(usize, 0), list.len);
}

test "tool bloat read tool reports info severity and 30% savings" {
    const tools = [_]ToolTokens{
        .{ .name = "Read", .total_tokens = 5_000 },
    };
    const data = ContextData{
        .percentage = 20,
        .raw_max_tokens = 100_000,
        .used_tokens = 20_000,
        .compact_threshold_percent = 60,
        .force_threshold_percent = 80,
        .auto_compact_enabled = true,
        .tool_breakdown = &tools,
        .history_tokens = 10_000,
    };
    const list = try generate(testing.allocator, data);
    defer freeSuggestions(testing.allocator, list);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqual(Severity.info, list[0].severity);
    try testing.expectEqual(@as(usize, 1_500), list[0].savings_tokens);
}
