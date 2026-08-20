//! Format a synthetic `tool_result` history turn for a tool that the model
//! emitted but never ran because the turn was aborted (Esc-Esc / Ctrl+C, or a
//! submit-interrupt where the user enqueued a new prompt mid-batch).
//!
//! Reference parity: `query.ts:123-149` `yieldMissingToolResultBlocks` emits an
//! `is_error` tool_result per orphaned `tool_use`; `StreamingToolExecutor.ts:153-205`
//! `createSyntheticErrorMessage` uses the REJECT/INTERRUPT phrasing. zcode keeps a
//! flat role-tagged history (not strict Anthropic tool_use/tool_result pairs), so
//! instead of an `is_error` block we append a `.tool` turn in the SAME text shape
//! the success path uses (`agent_runtime.zig` tool-result append):
//!
//!     tool={name}\nargs={args}\nstate=cancelled\nrisk={risk}\noutput={message}
//!
//! Keeping the format identical to the success path is load-bearing: the transcript
//! renderer and `pushRecentOutcome` both parse this shape, so a divergent format
//! would render wrong or desync recent-outcome tracking. The only differences are
//! `state=cancelled` (a sentinel the success path never emits) and the message body.
//!
//! `message` is chosen by the caller from `core/messages.zig`:
//!   - hard interrupt          -> `messages.INTERRUPT_MESSAGE_FOR_TOOL_USE`
//!   - synthetic/fallback path -> `messages.SYNTHETIC_TOOL_RESULT_PLACEHOLDER`
//!
//! Recording an explicit cancelled outcome (rather than leaving the emitted
//! tool_use silent) stops the model from re-issuing or hallucinating a result for
//! the tool on the next turn.

const std = @import("std");

/// The `state=` sentinel used for an emitted-but-unrun tool. The success path
/// emits `auto_approved` / `approved` / `denied` / `blocked`; `cancelled` is
/// unique to the abort synthesis so the renderer and any outcome scan can tell
/// a cancelled tool apart.
pub const CANCELLED_STATE = "cancelled";

/// Risk tier recorded for a synthetic cancelled turn. The tool never ran, so its
/// real risk tier was never computed; LOW is the neutral default that matches the
/// success-path string for read-only tools and never escalates a warning the user
/// did not actually trigger.
pub const SYNTHETIC_RISK = "LOW";

/// Decide whether the call at `idx` should get a synthetic cancelled result.
/// True when `idx >= start_idx` (calls before the abort point already ran or
/// were already recorded) AND the call is not flagged in `executed_flags` (the
/// `parallel_executed` bitmap, or null when nothing ran in parallel). Pure so
/// the inter-tool skip/start-index rule is testable without the turn loop.
pub fn shouldSynthesize(idx: usize, start_idx: usize, executed_flags: ?[]const bool) bool {
    if (idx < start_idx) return false;
    if (executed_flags) |flags| {
        if (idx < flags.len and flags[idx]) return false;
    }
    return true;
}

/// Build the synthetic cancelled tool-result turn body for one emitted-but-unrun
/// tool. Caller owns the returned slice. `name` and `args` are the model's
/// originally-emitted values; `message` is the cancellation phrasing (see the
/// module doc comment for which `messages.zig` constant to pass).
pub fn formatCancelledToolResult(
    allocator: std.mem.Allocator,
    name: []const u8,
    args: []const u8,
    message: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "tool={s}\nargs={s}\nstate={s}\nrisk={s}\noutput={s}",
        .{ name, args, CANCELLED_STATE, SYNTHETIC_RISK, message },
    );
}

const testing = std.testing;
const messages = @import("messages.zig");

test "formatCancelledToolResult matches the success-path shape with a cancelled state" {
    const body = try formatCancelledToolResult(testing.allocator, "Bash", "{\"command\":\"ls\"}", messages.INTERRUPT_MESSAGE_FOR_TOOL_USE);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(
        "tool=Bash\nargs={\"command\":\"ls\"}\nstate=cancelled\nrisk=LOW\noutput=[Request interrupted by user for tool use]",
        body,
    );
}

test "formatCancelledToolResult carries the synthetic placeholder message" {
    const body = try formatCancelledToolResult(testing.allocator, "Read", "{\"path\":\"a.zig\"}", messages.SYNTHETIC_TOOL_RESULT_PLACEHOLDER);
    defer testing.allocator.free(body);
    // The five named fields are present in order and the placeholder is the output.
    try testing.expect(std.mem.indexOf(u8, body, "tool=Read\n") != null);
    try testing.expect(std.mem.indexOf(u8, body, "args={\"path\":\"a.zig\"}\n") != null);
    try testing.expect(std.mem.indexOf(u8, body, "state=cancelled\n") != null);
    try testing.expect(std.mem.indexOf(u8, body, "risk=LOW\n") != null);
    try testing.expect(std.mem.endsWith(u8, body, messages.SYNTHETIC_TOOL_RESULT_PLACEHOLDER));
}

test "formatCancelledToolResult preserves an empty args object" {
    const body = try formatCancelledToolResult(testing.allocator, "git_status", "{}", messages.INTERRUPT_MESSAGE_FOR_TOOL_USE);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "tool=git_status\nargs={}\n") != null);
}

test "shouldSynthesize skips calls before the abort point" {
    // Two-call batch, aborted while running call index 1: call 0 already ran,
    // call 1 (the abort point) and anything after it must be synthesized.
    try testing.expect(!shouldSynthesize(0, 1, null));
    try testing.expect(shouldSynthesize(1, 1, null));
}

test "shouldSynthesize skips parallel-executed calls" {
    // call 0 ran in the parallel read-only batch, call 1 is the unrun action.
    const flags = [_]bool{ true, false };
    try testing.expect(!shouldSynthesize(0, 0, &flags));
    try testing.expect(shouldSynthesize(1, 0, &flags));
}

test "shouldSynthesize is bounds-safe when flags is shorter than the batch" {
    const flags = [_]bool{true};
    // index 1 is past the flags slice: treat as not-executed, so synthesize.
    try testing.expect(shouldSynthesize(1, 0, &flags));
}

test "shouldSynthesize synthesizes the whole batch when nothing ran" {
    // Post-model abort: no executed flags, start at 0 -> every call qualifies.
    try testing.expect(shouldSynthesize(0, 0, null));
    try testing.expect(shouldSynthesize(3, 0, null));
}
