//! Agentic-loop continuation decision for prompt-mechanism parity (PRD #533).
//! Pure logic, extracted from the turn loop so termination is unit-tested.
//!
//! Native mode mirrors Claude Code: continue while the model emits tool calls,
//! stop the moment it returns a turn with no tool call (end_turn). Non-native
//! (local/JSON-contract) mode follows the explicit `control.continue` flag.
//! Note: genuine recovery (truncation/length continuation, error retry) is
//! handled separately by the caller BEFORE this decision -- it is not a nudge.

const std = @import("std");

pub const Decision = enum { cont, stop };

/// Decide whether the loop should run another model turn.
/// - has_tool_calls: the model emitted at least one tool call this turn.
/// - control_continue: the JSON-contract `control.continue` flag (non-native only).
pub fn decideContinuation(native_mode: bool, has_tool_calls: bool, control_continue: bool) Decision {
    if (has_tool_calls) return .cont;
    if (native_mode) return .stop; // text + no tool call == end_turn (Claude Code)
    return if (control_continue) .cont else .stop;
}

const testing = std.testing;

test "tool calls always continue (both modes)" {
    try testing.expectEqual(Decision.cont, decideContinuation(true, true, false));
    try testing.expectEqual(Decision.cont, decideContinuation(false, true, false));
}

test "native mode stops on no tool calls regardless of continue flag" {
    try testing.expectEqual(Decision.stop, decideContinuation(true, false, false));
    try testing.expectEqual(Decision.stop, decideContinuation(true, false, true));
}

test "non-native follows the continue flag" {
    try testing.expectEqual(Decision.cont, decideContinuation(false, false, true));
    try testing.expectEqual(Decision.stop, decideContinuation(false, false, false));
}
