//! Token/text-block bounded keep-window compaction (compaction-11)
//! [experimental / deferable].
//!
//! An opt-in ALTERNATIVE to LLM compaction. Instead of summarizing the whole
//! history with a model call, this keeps a recent window of turns bounded by a
//! min/max token budget and a minimum text-block-message count, then uses
//! already-accumulated session memory (the snapshot's `handoff_summary`) as the
//! "summary" for the dropped prefix. This is the positional-history analog of
//! the reference's session-memory compaction
//! (services/compact/sessionMemoryCompact.ts:232-503:
//! `adjustIndexToPreserveAPIInvariants`, `calculateMessagesToKeepIndex`,
//! `createCompactionResultFromSessionMemory`).
//!
//! GATING: this path is experimental and gated behind a default-off config flag
//! (`KeepWindowConfig.enabled`). It must NEVER run on the default compaction
//! path -- callers check `cfg.enabled` first. The module itself is pure math
//! plus a result builder; it neither reads config nor mutates global state.
//!
//! DIVERGENCE FROM THE REFERENCE: zcode history turns are positional and flat
//! text (`types.HistoryTurn`), not UUID-keyed message objects. We therefore
//! preserve tool pairs by positional pairing (an `.assistant` turn immediately
//! followed by one or more `.tool` turns), not by matching tool_use/tool_result
//! IDs, and we use `snapshot.handoff_summary` as the session-memory string
//! rather than a separate session-memory store.

const std = @import("std");
const types = @import("types.zig");

/// Configuration for the bounded keep-window compaction. Mirrors the reference
/// `SessionMemoryCompactConfig` defaults (sessionMemoryCompact.ts:58-60) plus a
/// master `enabled` switch. Default-OFF: callers must opt in explicitly.
pub const KeepWindowConfig = struct {
    /// Master switch. When false the whole path is a no-op; the caller stays on
    /// the default `maybeCompact` LLM/rule-based path. Default off so this
    /// experimental transform cannot regress the default compaction path.
    enabled: bool = false,
    /// Keep at least this many estimated tokens in the recent window.
    min_tokens: usize = DEFAULT_MIN_TOKENS,
    /// Keep at least this many turns that carry text content (non-empty,
    /// non-tool-result bodies). Ensures the window is not just tool noise.
    min_text_block_msgs: usize = DEFAULT_MIN_TEXT_BLOCK_MSGS,
    /// Stop expanding the window once it reaches this many estimated tokens,
    /// even if the minimums are not yet met. Bounds the kept context.
    max_tokens: usize = DEFAULT_MAX_TOKENS,
};

/// Reference defaults (sessionMemoryCompact.ts:58-60).
pub const DEFAULT_MIN_TOKENS: usize = 10_000;
pub const DEFAULT_MIN_TEXT_BLOCK_MSGS: usize = 5;
pub const DEFAULT_MAX_TOKENS: usize = 40_000;

/// True when a turn carries a "text block" for the min-text-block-message
/// count. We treat user and assistant turns with non-empty (after trim) content
/// as text blocks; `.tool` and `.system` turns are tool/meta noise and do not
/// count, mirroring the reference's `hasTextBlocks` intent (it counts messages
/// with actual text blocks, not tool_result-only messages).
fn hasTextBlock(turn: types.HistoryTurn) bool {
    if (turn.role != .user and turn.role != .assistant) return false;
    return std.mem.trim(u8, turn.content, " \t\r\n").len > 0;
}

/// Walk backwards from the tail accumulating tokens and text-block messages
/// until BOTH minimums are met, stopping early if `max_tokens` is reached.
/// Returns the START index of the window to keep verbatim; turns before it are
/// dropped (their content is represented by the session-memory summary).
///
/// Mirrors `calculateMessagesToKeepIndex` (sessionMemoryCompact.ts:324-397) for
/// our positional model. We always start from the tail (there is no
/// `lastSummarizedIndex` pointer in zcode's flat history) and expand backwards.
/// The result is then nudged by `adjustIndexToPreserveInvariants` so it never
/// splits a tool turn from its producing assistant turn.
///
/// Pure function: no allocation, no I/O, deterministic in its inputs.
pub fn calculateKeepIndex(history: []const types.HistoryTurn, cfg: KeepWindowConfig) usize {
    if (history.len == 0) return 0;

    var total_tokens: usize = 0;
    var text_block_count: usize = 0;
    // Start by keeping nothing, then expand backwards from the tail.
    var start_index: usize = history.len;

    var i: usize = history.len;
    while (i > 0) {
        i -= 1;
        const msg_tokens = types.estimateTokens(history[i].content);
        total_tokens += msg_tokens;
        if (hasTextBlock(history[i])) text_block_count += 1;
        start_index = i;

        // Stop once we hit the max cap: the window is full enough.
        if (total_tokens >= cfg.max_tokens) break;

        // Stop once BOTH minimums are satisfied.
        if (total_tokens >= cfg.min_tokens and text_block_count >= cfg.min_text_block_msgs) break;
    }

    return adjustIndexToPreserveInvariants(history, start_index);
}

/// Nudge `start_index` so the kept window does not begin in the middle of a
/// tool block. zcode pairs an `.assistant` turn immediately followed by one or
/// more `.tool` turns positionally; cutting between them would orphan the tool
/// results from the assistant turn that produced them. We walk LEFT past any
/// leading `.tool` turns at `start_index` and then include the `.assistant`
/// turn that produced them, so the whole block stays on the kept side. Mirrors
/// the intent of `adjustIndexToPreserveAPIInvariants`
/// (sessionMemoryCompact.ts:232-314) for our positional pairing.
///
/// Guarantees: the returned index never points at a `.tool` turn that is
/// preceded (after walking) by its producing `.assistant` turn outside the
/// window. In other words, `history[returned]` is never a tool turn whose
/// producer sits at `returned - 1` on the dropped side.
///
/// Pure function: no allocation, no I/O.
pub fn adjustIndexToPreserveInvariants(history: []const types.HistoryTurn, start_index: usize) usize {
    if (start_index == 0 or start_index >= history.len) return @min(start_index, history.len);
    // If the window does not start on a tool turn, nothing to do: the boundary
    // already sits before a user/assistant/system turn.
    if (history[start_index].role != .tool) return start_index;

    // Walk left over the contiguous run of tool turns at the boundary.
    var idx = start_index;
    while (idx > 0 and history[idx].role == .tool) idx -= 1;
    // `idx` now points at the first non-tool turn before the tool run (its
    // producing assistant turn, in the well-formed case). Cut BEFORE it so the
    // assistant turn and its tool results stay together on the kept side.
    return idx;
}

/// Build a compaction-style result from accumulated session memory, keeping
/// `history[keep_index..]` verbatim and using `session_memory` as the summary
/// of the dropped prefix. Mirrors `createCompactionResultFromSessionMemory`
/// (sessionMemoryCompact.ts:437-503) for our flat model: zcode's
/// "session memory" is the snapshot `handoff_summary` (or a promoted-memory
/// string), not a separate store.
///
/// Returns a `KeepWindowResult` that owns its `summary` and `kept` slice. The
/// kept turns themselves BORROW their content from `history` (same borrow rule
/// as `compaction.microcompact`), so the result is valid only while `history`
/// outlives it. Free via `result.deinit(allocator)` (frees the summary and the
/// kept backing array, NOT the borrowed turn content).
pub fn createResultFromSessionMemory(
    allocator: std.mem.Allocator,
    history: []const types.HistoryTurn,
    keep_index: usize,
    session_memory: []const u8,
    trigger: types.CompactTrigger,
) !KeepWindowResult {
    const idx = @min(keep_index, history.len);

    var pre_compact_tokens: usize = 0;
    for (history) |turn| pre_compact_tokens += types.estimateTokens(turn.content);

    const summary = try allocator.dupe(u8, session_memory);
    errdefer allocator.free(summary);

    const kept = try allocator.dupe(types.HistoryTurn, history[idx..]);
    errdefer allocator.free(kept);

    return .{
        .summary = summary,
        .kept = kept,
        .boundary = .{
            .trigger = trigger,
            .pre_compact_tokens = pre_compact_tokens,
            // The kept window is history[idx..]; head is the first kept index,
            // tail is the last index. No discovered-tools scan here (the caller
            // can attach them separately if desired).
            .preserved_head = if (idx < history.len) idx else null,
            .preserved_tail = if (history.len > 0) history.len - 1 else null,
            .preserved_anchor = idx,
        },
    };
}

/// Result of a bounded keep-window compaction. Owns `summary` and the `kept`
/// backing array; the kept turns' `content` is borrowed from the caller's
/// history. Free via `deinit`.
pub const KeepWindowResult = struct {
    /// The session-memory string used as the summary for the dropped prefix.
    /// Owned.
    summary: []u8,
    /// The verbatim recent window kept after compaction. The backing array is
    /// owned; each turn's `content` borrows from the source history.
    kept: []types.HistoryTurn,
    /// Structured boundary marker recording trigger, pre-compaction token total,
    /// and the preserved-segment indices.
    boundary: types.CompactBoundary,

    pub fn deinit(self: *KeepWindowResult, allocator: std.mem.Allocator) void {
        allocator.free(self.summary);
        allocator.free(self.kept);
    }
};

const testing = std.testing;

// Build a turn with a body of `tokens*4` bytes so estimateTokens(content)
// returns roughly `tokens` (estimateTokens = max(1, len/4)).
fn turnOfTokens(role: types.HistoryRole, tokens: usize, buf: []u8) types.HistoryTurn {
    @memset(buf, 'x');
    return .{ .role = role, .content = buf[0 .. tokens * 4], .timestamp = 0 };
}

test "calculateKeepIndex respects min token and text-block minimums" {
    // 10 user turns of ~1000 tokens each (4000 bytes -> 1000 tokens).
    var bodies: [10][4000]u8 = undefined;
    var history: [10]types.HistoryTurn = undefined;
    for (0..10) |i| {
        @memset(&bodies[i], 'x');
        history[i] = .{ .role = .user, .content = &bodies[i], .timestamp = 0 };
    }

    // min_tokens=3000 (needs 3 turns), min_text_block_msgs=5 (needs 5 turns).
    // The text-block minimum dominates, so we keep the last 5 turns: index 5.
    const cfg = KeepWindowConfig{
        .enabled = true,
        .min_tokens = 3_000,
        .min_text_block_msgs = 5,
        .max_tokens = 40_000,
    };
    const idx = calculateKeepIndex(&history, cfg);
    try testing.expectEqual(@as(usize, 5), idx);

    // Tokens kept from index 5 are 5 * 1000 = 5000 >= min_tokens, and 5 text
    // blocks == min_text_block_msgs.
    var kept_tokens: usize = 0;
    var text_blocks: usize = 0;
    for (history[idx..]) |t| {
        kept_tokens += types.estimateTokens(t.content);
        if (hasTextBlock(t)) text_blocks += 1;
    }
    try testing.expect(kept_tokens >= cfg.min_tokens);
    try testing.expect(text_blocks >= cfg.min_text_block_msgs);
}

test "calculateKeepIndex stops at the max-token cap before meeting the minimums" {
    // 10 user turns of ~1000 tokens each.
    var bodies: [10][4000]u8 = undefined;
    var history: [10]types.HistoryTurn = undefined;
    for (0..10) |i| {
        @memset(&bodies[i], 'x');
        history[i] = .{ .role = .user, .content = &bodies[i], .timestamp = 0 };
    }

    // max_tokens=3000 caps the window at 3 turns even though the text-block
    // minimum (5) is not met: index 7 (last 3 turns, 3000 tokens).
    const cfg = KeepWindowConfig{
        .enabled = true,
        .min_tokens = 100_000,
        .min_text_block_msgs = 100,
        .max_tokens = 3_000,
    };
    const idx = calculateKeepIndex(&history, cfg);
    try testing.expectEqual(@as(usize, 7), idx);

    var kept_tokens: usize = 0;
    for (history[idx..]) |t| kept_tokens += types.estimateTokens(t.content);
    try testing.expect(kept_tokens >= cfg.max_tokens);
}

test "calculateKeepIndex keeps the whole history when it is smaller than the minimums" {
    var bodies: [3][4000]u8 = undefined;
    var history: [3]types.HistoryTurn = undefined;
    for (0..3) |i| {
        @memset(&bodies[i], 'x');
        history[i] = .{ .role = .user, .content = &bodies[i], .timestamp = 0 };
    }

    // Minimums far exceed the available history -> keep everything (index 0).
    const cfg = KeepWindowConfig{ .enabled = true, .min_tokens = 50_000, .min_text_block_msgs = 50, .max_tokens = 100_000 };
    try testing.expectEqual(@as(usize, 0), calculateKeepIndex(&history, cfg));
}

test "calculateKeepIndex on empty history returns 0" {
    const empty: []const types.HistoryTurn = &.{};
    try testing.expectEqual(@as(usize, 0), calculateKeepIndex(empty, .{ .enabled = true }));
}

test "adjustIndexToPreserveInvariants never splits a tool pair" {
    const history = [_]types.HistoryTurn{
        .{ .role = .user, .content = "do work", .timestamp = 0 },
        .{ .role = .assistant, .content = "running tools", .timestamp = 1 },
        .{ .role = .tool, .content = "Tool: Read\nfile body", .timestamp = 2 },
        .{ .role = .tool, .content = "Tool: Bash\noutput", .timestamp = 3 },
        .{ .role = .assistant, .content = "done", .timestamp = 4 },
    };

    // A boundary landing on the second tool turn (index 3) must move back before
    // the producing assistant turn (index 1) so the whole assistant+tool block
    // stays on the kept side.
    try testing.expectEqual(@as(usize, 1), adjustIndexToPreserveInvariants(&history, 3));
    // A boundary on the first tool turn (index 2) also rewinds to index 1.
    try testing.expectEqual(@as(usize, 1), adjustIndexToPreserveInvariants(&history, 2));
    // A boundary already on a non-tool turn is unchanged.
    try testing.expectEqual(@as(usize, 1), adjustIndexToPreserveInvariants(&history, 1));
    try testing.expectEqual(@as(usize, 4), adjustIndexToPreserveInvariants(&history, 4));
    // Edges: 0 and len are clamped, never split.
    try testing.expectEqual(@as(usize, 0), adjustIndexToPreserveInvariants(&history, 0));
    try testing.expectEqual(@as(usize, history.len), adjustIndexToPreserveInvariants(&history, history.len));

    // INVARIANT: the returned index is never a tool turn whose producer sits
    // immediately before it on the dropped side. Check across all inputs.
    for (0..history.len + 1) |s| {
        const r = adjustIndexToPreserveInvariants(&history, s);
        if (r > 0 and r < history.len and history[r].role == .tool) {
            // If the kept window starts on a tool turn, the turn before it must
            // also be a tool turn (i.e. we are inside an unsplittable run that
            // had no producing assistant turn) -- never a dropped producer.
            try testing.expect(history[r - 1].role == .tool);
        }
    }
}

test "createResultFromSessionMemory keeps the tail verbatim and records the boundary" {
    const allocator = testing.allocator;
    const history = [_]types.HistoryTurn{
        .{ .role = .user, .content = "old prefix turn", .timestamp = 0 },
        .{ .role = .assistant, .content = "old prefix reply", .timestamp = 1 },
        .{ .role = .user, .content = "kept recent turn", .timestamp = 2 },
        .{ .role = .assistant, .content = "kept recent reply", .timestamp = 3 },
    };

    var result = try createResultFromSessionMemory(allocator, &history, 2, "accumulated session memory summary", .manual);
    defer result.deinit(allocator);

    // The summary is the session-memory string.
    try testing.expectEqualStrings("accumulated session memory summary", result.summary);
    // The kept window is history[2..]: two turns, borrowed content.
    try testing.expectEqual(@as(usize, 2), result.kept.len);
    try testing.expectEqualStrings("kept recent turn", result.kept[0].content);
    try testing.expectEqualStrings("kept recent reply", result.kept[1].content);
    // Boundary metadata.
    try testing.expectEqual(types.CompactTrigger.manual, result.boundary.trigger);
    try testing.expectEqual(@as(?usize, 2), result.boundary.preserved_head);
    try testing.expectEqual(@as(?usize, 3), result.boundary.preserved_tail);
    try testing.expectEqual(@as(?usize, 2), result.boundary.preserved_anchor);
    // pre_compact_tokens is the total over the WHOLE history (not just kept).
    try testing.expect(result.boundary.pre_compact_tokens > 0);
}

test "createResultFromSessionMemory with keep_index 0 keeps everything" {
    const allocator = testing.allocator;
    const history = [_]types.HistoryTurn{
        .{ .role = .user, .content = "only turn", .timestamp = 0 },
    };
    var result = try createResultFromSessionMemory(allocator, &history, 0, "memory", .auto);
    defer result.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), result.kept.len);
    try testing.expectEqual(@as(?usize, 0), result.boundary.preserved_head);
}
