//! Why a turn cancel fired. The global cancel signal in `providers/common.zig`
//! pairs the hot-path `cancel_requested: bool` with a parallel reason tag so
//! downstream abort paths can tell a user-typed submit-interrupt apart from a
//! hard Esc-Esc / Ctrl+C interrupt.
//!
//! Reference parity: `query.ts:1044-1050` and `:1499-1505` skip
//! `createUserInterruptionMessage` when `signal.reason === 'interrupt'`;
//! `StreamingToolExecutor.ts:219-229` `getAbortReason` branches the same way.
//! Here `.submit_interrupt` mirrors that `'interrupt'` reason: the queued
//! message becomes the next turn, so the standalone interruption turn is
//! suppressed. `.hard` mirrors a real abort that should record the
//! interruption phrasing.

const std = @import("std");

pub const CancelReason = enum(u8) {
    /// No cancel pending. Baseline value stored on reset.
    none = 0,
    /// Hard interrupt: Esc-Esc or Ctrl+C. Record the interruption message.
    hard = 1,
    /// Submit-interrupt: the user typed and submitted a new message mid-turn.
    /// The queued message provides context, so suppress the standalone
    /// interruption turn (but still record per-tool cancelled outcomes).
    submit_interrupt = 2,

    /// Decode a stored enum tag (e.g. from an atomic u8) into a CancelReason.
    /// Unknown tags fall back to `.hard` so an unrecognized value never
    /// silently suppresses the interruption message.
    pub fn fromTag(tag: u8) CancelReason {
        return switch (tag) {
            @intFromEnum(CancelReason.none) => .none,
            @intFromEnum(CancelReason.submit_interrupt) => .submit_interrupt,
            else => .hard,
        };
    }
};

/// True when the standalone interruption turn should be suppressed because the
/// user-submitted queued message already supplies the next-turn context.
/// Only a submit-interrupt suppresses it; a hard interrupt (and the `.none`
/// baseline) still records the interruption.
pub fn suppressInterruptionMessage(r: CancelReason) bool {
    return r == .submit_interrupt;
}

test "suppressInterruptionMessage only true for submit_interrupt" {
    try std.testing.expect(suppressInterruptionMessage(.submit_interrupt));
    try std.testing.expect(!suppressInterruptionMessage(.hard));
    try std.testing.expect(!suppressInterruptionMessage(.none));
}

test "CancelReason.fromTag round-trips known tags and defaults unknown to hard" {
    try std.testing.expectEqual(CancelReason.none, CancelReason.fromTag(@intFromEnum(CancelReason.none)));
    try std.testing.expectEqual(CancelReason.hard, CancelReason.fromTag(@intFromEnum(CancelReason.hard)));
    try std.testing.expectEqual(CancelReason.submit_interrupt, CancelReason.fromTag(@intFromEnum(CancelReason.submit_interrupt)));
    // Unknown tag falls back to hard so we never accidentally suppress.
    try std.testing.expectEqual(CancelReason.hard, CancelReason.fromTag(99));
}
