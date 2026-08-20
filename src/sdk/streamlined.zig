//! sdk-headless-08: streamlined output transform.
//!
//! "Distillation-resistant" output mode for stream-json. It collapses an
//! assistant turn's tool calls into cumulative category counts ("Searched N
//! patterns, read N files, wrote N files, ran N commands"), keeps text intact,
//! drops thinking/init detail, and resets the running counts whenever text
//! appears. Opt-in via the `CLAUDE_CODE_STREAMLINED_OUTPUT` env var, and only
//! meaningful under `--output-format stream-json`.
//!
//! Reference behavior + file:line:
//!   utils/streamlinedTransform.ts  createStreamlinedTransformer / getToolSummaryText
//!   cli/print.ts:858               isEnvTruthy(process.env.CLAUDE_CODE_STREAMLINED_OUTPUT) gate
//!
//! This module is pure (categorizer + summary + a small stateful transformer
//! over already-decoded assistant messages). It does not own the NDJSON
//! emission; Task B's stream-json dispatch consults `enabled()` and routes
//! assistant messages through a `Transformer` when the env var is set. Keeping
//! it pure makes the categorization and summary phrasing unit-testable against
//! hand-built inputs, matching the reference's pure helpers.
//!
//! Tool-name parity: the reference categorizes against its `TOOL_NAME`
//! constants. zcode tool identifiers may arrive as legacy snake_case aliases,
//! so we normalize through `core/tool_name_map.canonical` before categorizing.
//! The reference uses `startsWith` (prefix) matching; we do too, so MCP-prefixed
//! variants of a base tool still land in the right bucket.

const std = @import("std");
const std_io = @import("../core/std_io.zig");
const tool_name_map = @import("../core/tool_name_map.zig");
const parse_helpers = @import("../core/parse_helpers.zig");
const env = @import("../core/env.zig");

/// Cumulative tool counts within a single assistant turn (reset when text
/// appears). Mirrors the reference `ToolCounts` shape.
pub const ToolCounts = struct {
    searches: usize = 0,
    reads: usize = 0,
    writes: usize = 0,
    commands: usize = 0,
    other: usize = 0,

    pub fn isEmpty(self: ToolCounts) bool {
        return self.searches == 0 and self.reads == 0 and self.writes == 0 and
            self.commands == 0 and self.other == 0;
    }
};

/// The category a tool name falls into for summarization. `other` is the
/// catch-all for tools that do not map to a known reference bucket.
pub const Category = enum { searches, reads, writes, commands, other };

// Reference categories (streamlinedTransform.ts:38-50), expressed with zcode's
// canonical (reference-exact) tool names. The reference matches with
// `startsWith`, so these are prefixes.
const search_tools = [_][]const u8{ "Grep", "Glob", "WebSearch", "LSP" };
const read_tools = [_][]const u8{ "Read", "ListMcpResourcesTool" };
const write_tools = [_][]const u8{ "Write", "Edit", "NotebookEdit" };
// SHELL_TOOL_NAMES is Bash + PowerShell in the reference; plus Tmux and the
// task-stop tool. zcode's canonical name for the kill-shell tool is TaskStop.
const command_tools = [_][]const u8{ "Bash", "PowerShell", "Tmux", "TaskStop" };

/// Categorize a (possibly legacy-aliased) tool name into one of the five
/// buckets. Aliases are normalized to the reference-exact name first, then
/// prefix-matched against each category, matching the reference order
/// (search, read, write, command, other).
pub fn categorize(tool_name: []const u8) Category {
    const name = tool_name_map.canonical(tool_name);
    for (search_tools) |t| {
        if (std.mem.startsWith(u8, name, t)) return .searches;
    }
    for (read_tools) |t| {
        if (std.mem.startsWith(u8, name, t)) return .reads;
    }
    for (write_tools) |t| {
        if (std.mem.startsWith(u8, name, t)) return .writes;
    }
    for (command_tools) |t| {
        if (std.mem.startsWith(u8, name, t)) return .commands;
    }
    return .other;
}

/// Add one tool use of `tool_name` to `counts`.
pub fn accumulate(counts: *ToolCounts, tool_name: []const u8) void {
    switch (categorize(tool_name)) {
        .searches => counts.searches += 1,
        .reads => counts.reads += 1,
        .writes => counts.writes += 1,
        .commands => counts.commands += 1,
        .other => counts.other += 1,
    }
}

/// Build the human summary string for `counts`, e.g.
/// `"Searched 2 patterns, read 1 file"`. Returns null when every count is
/// zero (the reference returns `undefined`). Caller owns the returned slice.
///
/// Phrasing matches the reference `getToolSummaryText`: a comma-joined list of
/// parts in the fixed order searches, reads, writes, commands, other, with the
/// whole string capitalized at the first character only (matching the
/// reference `capitalize`, which uppercases char[0] and leaves the rest).
pub fn summaryText(allocator: std.mem.Allocator, counts: ToolCounts) !?[]u8 {
    if (counts.isEmpty()) return null;

    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    var first = true;

    if (counts.searches > 0) {
        try appendPart(&buf, &first, "searched ", counts.searches, "pattern", "patterns");
    }
    if (counts.reads > 0) {
        try appendPart(&buf, &first, "read ", counts.reads, "file", "files");
    }
    if (counts.writes > 0) {
        try appendPart(&buf, &first, "wrote ", counts.writes, "file", "files");
    }
    if (counts.commands > 0) {
        try appendPart(&buf, &first, "ran ", counts.commands, "command", "commands");
    }
    if (counts.other > 0) {
        // Reference: `${n} other ${n === 1 ? 'tool' : 'tools'}`.
        if (!first) try buf.appendSlice(", ");
        first = false;
        try buf.writer().print("{d} other {s}", .{
            counts.other,
            parse_helpers.plural(counts.other, "tool", "tools"),
        });
    }

    // Capitalize the first character only (matches reference `capitalize`).
    const view = buf.items();
    if (view.len > 0) {
        const c = view[0];
        if (c >= 'a' and c <= 'z') view[0] = c - 32;
    }

    return try buf.toOwnedSlice();
}

fn appendPart(
    buf: *std_io.StringBuilder,
    first: *bool,
    verb: []const u8,
    n: usize,
    singular: []const u8,
    plural_form: []const u8,
) !void {
    if (!first.*) try buf.appendSlice(", ");
    first.* = false;
    try buf.writer().print("{s}{d} {s}", .{ verb, n, parse_helpers.plural(n, singular, plural_form) });
}

/// The kind of message the transformer produced for an assistant message.
pub const OutputKind = enum {
    /// `streamlined_text`: the assistant message carried text. The running
    /// counts have been reset.
    text,
    /// `streamlined_tool_use_summary`: the assistant message was tool-only and
    /// the cumulative counts have a non-empty summary.
    tool_use_summary,
    /// The assistant message was tool-only but produced no summary (e.g. an
    /// empty tool-only message). The reference drops these (returns null).
    dropped,
};

/// One transformed assistant message. `payload` is the text (for `.text`) or
/// the tool summary (for `.tool_use_summary`); it is null for `.dropped`.
/// Caller owns `payload`.
pub const Output = struct {
    kind: OutputKind,
    payload: ?[]u8 = null,
};

/// A stateful transformer that accumulates tool counts between text messages.
/// Construct with `init`, feed each assistant message (its concatenated text
/// and its tool-use names) through `assistant`, and emit the returned `Output`.
/// Counts reset when a message with non-empty text is encountered, matching
/// `createStreamlinedTransformer`.
pub const Transformer = struct {
    allocator: std.mem.Allocator,
    counts: ToolCounts = .{},

    pub fn init(allocator: std.mem.Allocator) Transformer {
        return .{ .allocator = allocator };
    }

    /// Process one assistant message.
    ///   `text`       the message's concatenated text content (already trimmed
    ///                of surrounding whitespace by the caller; empty means a
    ///                tool-only message).
    ///   `tool_names` the tool_use block names in the message, in order.
    ///
    /// Accumulates the tool uses, then: if text is non-empty, resets the counts
    /// and emits a `.text` output carrying a copy of the text; otherwise emits a
    /// `.tool_use_summary` (or `.dropped` when the summary is empty).
    pub fn assistant(self: *Transformer, text: []const u8, tool_names: []const []const u8) !Output {
        for (tool_names) |n| accumulate(&self.counts, n);

        if (text.len > 0) {
            self.counts = .{};
            const owned = try self.allocator.dupe(u8, text);
            return .{ .kind = .text, .payload = owned };
        }

        const summary = try summaryText(self.allocator, self.counts);
        if (summary) |s| {
            return .{ .kind = .tool_use_summary, .payload = s };
        }
        return .{ .kind = .dropped, .payload = null };
    }
};

/// True when streamlined output is opted in via the env var. The caller is
/// expected to also require `--output-format stream-json` before transforming
/// (matching the reference gate at print.ts:858).
pub fn enabled() bool {
    return env.isEnvTruthy("CLAUDE_CODE_STREAMLINED_OUTPUT");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "categorize maps zcode tool names to the right buckets" {
    try testing.expectEqual(Category.searches, categorize("Grep"));
    try testing.expectEqual(Category.searches, categorize("Glob"));
    try testing.expectEqual(Category.searches, categorize("WebSearch"));
    try testing.expectEqual(Category.searches, categorize("LSP"));
    try testing.expectEqual(Category.reads, categorize("Read"));
    try testing.expectEqual(Category.reads, categorize("ListMcpResourcesTool"));
    try testing.expectEqual(Category.writes, categorize("Write"));
    try testing.expectEqual(Category.writes, categorize("Edit"));
    try testing.expectEqual(Category.writes, categorize("NotebookEdit"));
    try testing.expectEqual(Category.commands, categorize("Bash"));
    try testing.expectEqual(Category.commands, categorize("Tmux"));
    try testing.expectEqual(Category.commands, categorize("TaskStop"));
    try testing.expectEqual(Category.other, categorize("Agent"));
    try testing.expectEqual(Category.other, categorize("TodoWrite"));
}

test "categorize normalizes legacy aliases before bucketing" {
    // snake_case aliases route through tool_name_map.canonical.
    try testing.expectEqual(Category.reads, categorize("file_read"));
    try testing.expectEqual(Category.writes, categorize("file_write"));
    try testing.expectEqual(Category.writes, categorize("MultiEdit"));
    try testing.expectEqual(Category.commands, categorize("shell"));
    try testing.expectEqual(Category.searches, categorize("web_search"));
    // KillShell aliases to TaskStop -> command bucket.
    try testing.expectEqual(Category.commands, categorize("KillShell"));
}

test "categorize prefix-matches MCP-style variants" {
    try testing.expectEqual(Category.searches, categorize("GrepTool"));
    try testing.expectEqual(Category.commands, categorize("BashOutput"));
}

test "summaryText phrasing matches reference (Searched 2 patterns, read 1 file)" {
    const s = try summaryText(testing.allocator, .{ .searches = 2, .reads = 1 });
    defer if (s) |v| testing.allocator.free(v);
    try testing.expect(s != null);
    try testing.expectEqualStrings("Searched 2 patterns, read 1 file", s.?);
}

test "summaryText pluralizes and orders all buckets" {
    const s = try summaryText(testing.allocator, .{
        .searches = 1,
        .reads = 3,
        .writes = 1,
        .commands = 2,
        .other = 1,
    });
    defer if (s) |v| testing.allocator.free(v);
    try testing.expectEqualStrings(
        "Searched 1 pattern, read 3 files, wrote 1 file, ran 2 commands, 1 other tool",
        s.?,
    );
}

test "summaryText returns null for empty counts" {
    const s = try summaryText(testing.allocator, .{});
    try testing.expect(s == null);
}

test "transformer collapses tool calls into one summary and keeps text" {
    var t = Transformer.init(testing.allocator);

    // Three tool-only assistant messages accumulate across the turn.
    const o1 = try t.assistant("", &.{"Grep"});
    defer if (o1.payload) |p| testing.allocator.free(p);
    try testing.expectEqual(OutputKind.tool_use_summary, o1.kind);
    try testing.expectEqualStrings("Searched 1 pattern", o1.payload.?);

    const o2 = try t.assistant("", &.{"Read"});
    defer if (o2.payload) |p| testing.allocator.free(p);
    try testing.expectEqual(OutputKind.tool_use_summary, o2.kind);
    try testing.expectEqualStrings("Searched 1 pattern, read 1 file", o2.payload.?);

    const o3 = try t.assistant("", &.{"Write"});
    defer if (o3.payload) |p| testing.allocator.free(p);
    try testing.expectEqual(OutputKind.tool_use_summary, o3.kind);
    try testing.expectEqualStrings("Searched 1 pattern, read 1 file, wrote 1 file", o3.payload.?);

    // An intervening text message is preserved verbatim and resets counts.
    const ot = try t.assistant("All done.", &.{});
    defer if (ot.payload) |p| testing.allocator.free(p);
    try testing.expectEqual(OutputKind.text, ot.kind);
    try testing.expectEqualStrings("All done.", ot.payload.?);

    // After text, a fresh tool-only message starts counting from zero.
    const o4 = try t.assistant("", &.{ "Bash", "Bash" });
    defer if (o4.payload) |p| testing.allocator.free(p);
    try testing.expectEqual(OutputKind.tool_use_summary, o4.kind);
    try testing.expectEqualStrings("Ran 2 commands", o4.payload.?);
}

test "transformer drops a tool-only message with no tool uses" {
    var t = Transformer.init(testing.allocator);
    const o = try t.assistant("", &.{});
    try testing.expectEqual(OutputKind.dropped, o.kind);
    try testing.expect(o.payload == null);
}
