//! ui-dialogs-05: IdleReturnDialog decision logic.
//!
//! Ports the gating and action semantics of the reference's
//! IdleReturnDialog.tsx. When a session has been idle past a threshold and
//! the user returns and submits, the REPL offers Continue / Clear-context /
//! Don't-ask-again. This module owns the pure pieces: the idle threshold,
//! the "should we show it" decision, and the action enum. The overlay chrome
//! lives in src/cli/repl_overlay.zig and the wiring (tracking last activity,
//! reading the live token counter, invoking /clear) lives in src/cli/repl.zig.
//!
//! Everything here is pure (no IO) so it is unit-testable under the custom
//! test runner.

const std = @import("std");

/// Default idle threshold in nanoseconds before the return dialog fires.
/// The reference uses a minutes-based threshold; 30 minutes is a sane
/// default that matches the "you've been away" usage-optimization intent
/// without nagging on short coffee breaks. Overridable by the caller so a
/// test or a config knob can pass a smaller value.
pub const IDLE_THRESHOLD_NANOS: u64 = 30 * 60 * std.time.ns_per_s;

/// The action the user picked in the idle-return dialog. Mirrors the
/// reference's `continue | clear | dismiss | never` action union.
pub const IdleAction = enum {
    /// Proceed with the conversation as-is.
    cont,
    /// Clear the conversation context, then process the new input fresh.
    clear,
    /// Persist "never ask again" then proceed.
    never,
    /// Esc/cancel: proceed normally, do not persist anything.
    dismiss,
};

/// Decide whether the idle-return dialog should be shown on the next user
/// submission. Returns true only when the user has been idle at least
/// `threshold_nanos` AND has not asked to never be prompted again. Pure so
/// the gate is unit-testable without driving the TUI.
///
/// `idle_nanos` is the elapsed wall time since the session last went idle
/// (the moment the previous agent turn completed). A non-positive idle span
/// (clock skew, first prompt) never triggers the dialog.
pub fn shouldShowIdleReturn(idle_nanos: i128, threshold_nanos: u64, never_flag: bool) bool {
    if (never_flag) return false;
    if (idle_nanos <= 0) return false;
    return idle_nanos >= @as(i128, threshold_nanos);
}

const testing = std.testing;

test "shouldShowIdleReturn fires only past the threshold" {
    const threshold = IDLE_THRESHOLD_NANOS;
    // Just under the threshold: no dialog.
    try testing.expect(!shouldShowIdleReturn(@as(i128, threshold) - 1, threshold, false));
    // Exactly at the threshold: dialog.
    try testing.expect(shouldShowIdleReturn(@as(i128, threshold), threshold, false));
    // Well past the threshold: dialog.
    try testing.expect(shouldShowIdleReturn(@as(i128, threshold) * 3, threshold, false));
}

test "shouldShowIdleReturn respects the never-ask flag" {
    const threshold = IDLE_THRESHOLD_NANOS;
    // Even when long idle, the never flag suppresses the dialog.
    try testing.expect(!shouldShowIdleReturn(@as(i128, threshold) * 10, threshold, true));
}

test "shouldShowIdleReturn ignores non-positive idle spans" {
    const threshold = IDLE_THRESHOLD_NANOS;
    try testing.expect(!shouldShowIdleReturn(0, threshold, false));
    try testing.expect(!shouldShowIdleReturn(-1_000_000, threshold, false));
}

test "shouldShowIdleReturn honors a custom (small) threshold" {
    // A test/config could pass a 1-second threshold; the helper must use it.
    const small: u64 = std.time.ns_per_s;
    try testing.expect(!shouldShowIdleReturn(@as(i128, small) - 1, small, false));
    try testing.expect(shouldShowIdleReturn(@as(i128, small), small, false));
}
