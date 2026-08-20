//! Denial tracking infrastructure for permission auto-denials (permissions-10).
//! Tracks consecutive denials and total denials so a session that keeps
//! auto-denying tool calls can fall back to interactive prompting once a
//! limit is hit, instead of silently denying forever.
//!
//! Ported verbatim from claude-code-main/src/utils/permissions/denialTracking.ts
//! (DENIAL_LIMITS {maxConsecutive:3, maxTotal:20}, createDenialTrackingState,
//! recordDenial, recordSuccess, shouldFallbackToPrompting).
//!
//! Pure: no allocation, no IO, no runtime singleton. The runtime owns one
//! State per session and mutates it through the methods below.

const std = @import("std");

/// A successful tool run after this many consecutive auto-denials never
/// happened: trip the fallback. Mirrors DENIAL_LIMITS.maxConsecutive.
pub const MAX_CONSECUTIVE: u32 = 3;

/// Across the whole session, this many total auto-denials trips the
/// fallback even if successes kept the consecutive counter low.
/// Mirrors DENIAL_LIMITS.maxTotal.
pub const MAX_TOTAL: u32 = 20;

/// Session-scoped denial counters. Construct with `init()` (or just
/// `.{}` - both fields default to zero).
pub const State = struct {
    /// Auto-denials in a row with no intervening success. Reset by
    /// recordSuccess.
    consecutive_denials: u32 = 0,
    /// Total auto-denials this session. Never reset.
    total_denials: u32 = 0,

    /// Fresh state, equivalent to the reference createDenialTrackingState.
    pub fn init() State {
        return .{ .consecutive_denials = 0, .total_denials = 0 };
    }

    /// Count one auto-denial: bump both counters. Mirrors recordDenial.
    pub fn recordDenial(self: *State) void {
        self.consecutive_denials +|= 1;
        self.total_denials +|= 1;
    }

    /// Count one successful tool run: reset the consecutive run (total is
    /// left intact). Mirrors recordSuccess (no-op when already zero).
    pub fn recordSuccess(self: *State) void {
        self.consecutive_denials = 0;
    }

    /// True once either limit is reached, signalling the caller should
    /// stop auto-denying and prompt the user instead. Mirrors
    /// shouldFallbackToPrompting.
    pub fn shouldFallbackToPrompting(self: State) bool {
        return self.consecutive_denials >= MAX_CONSECUTIVE or
            self.total_denials >= MAX_TOTAL;
    }
};

const testing = std.testing;

test "fresh state does not fall back" {
    const s = State.init();
    try testing.expectEqual(@as(u32, 0), s.consecutive_denials);
    try testing.expectEqual(@as(u32, 0), s.total_denials);
    try testing.expect(!s.shouldFallbackToPrompting());
}

test "three consecutive denials trip the consecutive limit" {
    var s = State.init();
    s.recordDenial();
    try testing.expect(!s.shouldFallbackToPrompting());
    s.recordDenial();
    try testing.expect(!s.shouldFallbackToPrompting());
    s.recordDenial();
    try testing.expect(s.shouldFallbackToPrompting());
    try testing.expectEqual(@as(u32, 3), s.consecutive_denials);
    try testing.expectEqual(@as(u32, 3), s.total_denials);
}

test "recordSuccess resets consecutive but not total" {
    var s = State.init();
    s.recordDenial();
    s.recordDenial();
    try testing.expectEqual(@as(u32, 2), s.consecutive_denials);
    s.recordSuccess();
    try testing.expectEqual(@as(u32, 0), s.consecutive_denials);
    // total preserved across the reset.
    try testing.expectEqual(@as(u32, 2), s.total_denials);
    try testing.expect(!s.shouldFallbackToPrompting());
    // After reset, it takes another full run of three to trip again.
    s.recordDenial();
    s.recordDenial();
    try testing.expect(!s.shouldFallbackToPrompting());
    s.recordDenial();
    try testing.expect(s.shouldFallbackToPrompting());
}

test "twenty total denials trip the total limit even when consecutive never hits three" {
    var s = State.init();
    var i: u32 = 0;
    // Interleave a success after every two denials so the consecutive
    // counter never reaches MAX_CONSECUTIVE; only the total accumulates.
    while (i < 20) : (i += 1) {
        s.recordDenial();
        if (i % 2 == 1) s.recordSuccess();
    }
    try testing.expectEqual(@as(u32, 20), s.total_denials);
    try testing.expect(s.consecutive_denials < MAX_CONSECUTIVE);
    try testing.expect(s.shouldFallbackToPrompting());
}

test "recordSuccess on a zero-consecutive state is a no-op" {
    var s = State.init();
    s.recordSuccess();
    try testing.expectEqual(@as(u32, 0), s.consecutive_denials);
    try testing.expectEqual(@as(u32, 0), s.total_denials);
    try testing.expect(!s.shouldFallbackToPrompting());
}
