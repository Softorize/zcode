//! Phase 23 Task 06 (commands-sweep-06). `/btw <question>` runs a one-shot
//! "side question" against the model using the current conversation as context,
//! WITHOUT appending the question or the answer to the main transcript. This is
//! the deterministic, unit-testable half: build the side-question prompt from a
//! read-only view of the recent history plus the user's question, and a small
//! answer-trimmer. The actual model call (which must not mutate History or the
//! on-disk session JSONL) lives in agent_runtime.runSideQuestion -- it routes
//! through callModel with this prompt and returns the answer text without ever
//! touching the transcript.
//!
//! Reference: claude-code-main/src/commands/btw + utils/sideQuestion.ts
//! (runForkedAgent reuses the parent prompt-cache while keeping the response
//! out of the main conversation). zcode has a flat history rather than a forked
//! agent, so the isolation is "build context as a one-shot prompt and never
//! append the turn" instead of a forked sub-agent. Documented divergence: no
//! prompt-cache reuse, and the answer is returned as a text block rather than a
//! scrollable modal.

const std = @import("std");
const std_io = @import("std_io.zig");
const types = @import("types.zig");

/// System prompt for the side-question. The model is told it is answering a
/// quick aside that will NOT become part of the running conversation, so it
/// should answer directly and not assume any follow-up.
pub const SYSTEM_PROMPT =
    "You are answering a quick side question from the user. The prior " ++
    "conversation is provided only as background context. Your answer will " ++
    "NOT be added to that conversation -- it is a one-off aside. Answer the " ++
    "side question directly and concisely. Do not ask the user to continue, " ++
    "and do not assume the side question changes the main task.";

/// How many of the most recent history turns to include as background context.
/// Capped so a long session does not bloat the side-question request; the
/// reference reuses the cache-safe parent params, we approximate with a recency
/// window.
pub const MAX_CONTEXT_TURNS: usize = 12;

/// Per-turn content cap (chars) when embedding context, so one giant turn does
/// not dominate the side-question prompt.
pub const MAX_TURN_CHARS: usize = 2000;

/// Build the side-question user prompt: a compact rendering of up to
/// MAX_CONTEXT_TURNS recent turns followed by the user's question. `history` is
/// a read-only view owned by the caller (never retained). `question` is the raw
/// text after `/btw `. Caller owns the returned slice.
pub fn buildPrompt(
    allocator: std.mem.Allocator,
    history: []const types.HistoryTurn,
    question: []const u8,
) ![]u8 {
    const q_trimmed = std.mem.trim(u8, question, " \t\r\n");

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    // Only render the most recent window of turns as background. System turns
    // (mode instructions, reminders) are skipped -- they are scaffolding, not
    // conversation the user would think of as context for an aside.
    const start = if (history.len > MAX_CONTEXT_TURNS) history.len - MAX_CONTEXT_TURNS else 0;
    var wrote_context = false;
    for (history[start..]) |turn| {
        if (turn.role == .system) continue;
        const content = std.mem.trim(u8, turn.content, " \t\r\n");
        if (content.len == 0) continue;
        if (!wrote_context) {
            try w.writeAll("Conversation so far (background only):\n");
            wrote_context = true;
        }
        const capped = if (content.len > MAX_TURN_CHARS) content[0..MAX_TURN_CHARS] else content;
        try w.print("{s}: {s}\n", .{ types.roleToString(turn.role), capped });
    }
    if (wrote_context) try w.writeAll("\n");

    try w.writeAll("Side question (do not add this to the conversation): ");
    if (q_trimmed.len > 0) {
        try w.writeAll(q_trimmed);
    } else {
        try w.writeAll("(none)");
    }
    try w.writeAll("\n");

    return out.toOwnedSlice();
}

/// Trim the model's raw response into a clean answer block: strip surrounding
/// whitespace. Returns null when the response is empty/whitespace-only so the
/// caller can surface a clear "no answer" message instead of a blank block.
/// Caller owns the returned slice.
pub fn parseAnswer(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return @as(?[]u8, try allocator.dupe(u8, trimmed));
}

const testing = std.testing;

test "buildPrompt embeds recent context and the question" {
    const turns = [_]types.HistoryTurn{
        .{ .role = .user, .content = "refactor the parser", .timestamp = 0 },
        .{ .role = .assistant, .content = "done, split into two files", .timestamp = 0 },
    };
    const p = try buildPrompt(testing.allocator, &turns, "what is 2+2");
    defer testing.allocator.free(p);
    try testing.expect(std.mem.indexOf(u8, p, "refactor the parser") != null);
    try testing.expect(std.mem.indexOf(u8, p, "split into two files") != null);
    try testing.expect(std.mem.indexOf(u8, p, "Side question") != null);
    try testing.expect(std.mem.indexOf(u8, p, "what is 2+2") != null);
}

test "buildPrompt with empty history still includes the question" {
    const p = try buildPrompt(testing.allocator, &.{}, "what time is it");
    defer testing.allocator.free(p);
    try testing.expect(std.mem.indexOf(u8, p, "Conversation so far") == null);
    try testing.expect(std.mem.indexOf(u8, p, "what time is it") != null);
}

test "buildPrompt skips system turns from the context window" {
    const turns = [_]types.HistoryTurn{
        .{ .role = .system, .content = "MODE: plan -- do not edit files", .timestamp = 0 },
        .{ .role = .user, .content = "look at main.zig", .timestamp = 0 },
    };
    const p = try buildPrompt(testing.allocator, &turns, "side q");
    defer testing.allocator.free(p);
    try testing.expect(std.mem.indexOf(u8, p, "MODE: plan") == null);
    try testing.expect(std.mem.indexOf(u8, p, "look at main.zig") != null);
}

test "buildPrompt caps the context window to the most recent turns" {
    var many: [MAX_CONTEXT_TURNS + 5]types.HistoryTurn = undefined;
    for (&many, 0..) |*t, i| {
        t.* = .{
            .role = if (i % 2 == 0) .user else .assistant,
            .content = if (i == 0) "OLDEST_MARKER" else "filler turn content",
            .timestamp = 0,
        };
    }
    const p = try buildPrompt(testing.allocator, &many, "q");
    defer testing.allocator.free(p);
    // The oldest turn falls outside the recency window and must be dropped.
    try testing.expect(std.mem.indexOf(u8, p, "OLDEST_MARKER") == null);
}

test "parseAnswer trims surrounding whitespace" {
    const a = (try parseAnswer(testing.allocator, "  4\n")).?;
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("4", a);
}

test "parseAnswer returns null on empty / whitespace" {
    try testing.expectEqual(@as(?[]u8, null), try parseAnswer(testing.allocator, ""));
    try testing.expectEqual(@as(?[]u8, null), try parseAnswer(testing.allocator, "  \n\t "));
}
