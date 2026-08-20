//! OSC 9;4 taskbar/tab progress reporting.
//!
//! Builds the ConEmu-origin OSC 9;4 progress escape sequences that
//! Ghostty 1.2.0+, iTerm2 3.6.6+ and ConEmu render as a progress bar on
//! the OS taskbar / terminal tab. The wire format is:
//!
//!   ESC ] 9 ; 4 ; <state> ; <percent> BEL
//!
//! where <state> is:
//!   0 = remove / clear the progress bar
//!   1 = set progress to <percent> (0..100)
//!   2 = error state (red), optional <percent>
//!   3 = indeterminate (busy, no specific percentage)
//!
//! This is distinct from the OSC 9 desktop notification in `notifier.zig`
//! (which uses the SAME OSC code 9 but no `;4;` progress sub-code) -- do
//! not conflate the two. Capability gating lives in
//! `terminal_caps.isProgressReportingAvailable`; this module only builds
//! the bytes. Callers writeAll the returned slice through a writer.
//!
//! Mirrors the reference `Progress` type and OSC 9;4 emission in
//! `src/ink/terminal.ts:11-64`.

const std = @import("std");

/// State byte used by the OSC 9;4 sequence.
pub const State = enum(u8) {
    remove = 0,
    set = 1,
    err = 2,
    indeterminate = 3,
};

/// Build a `set` (state 1) progress sequence at the given percent (clamped
/// to 0..100) into `buf`. Returns the slice, or an empty slice if `buf` is
/// too small (treat empty as "do nothing").
pub fn set(buf: []u8, percent: u8) []const u8 {
    const p: u8 = @min(percent, 100);
    return std.fmt.bufPrint(buf, "\x1b]9;4;1;{d}\x07", .{p}) catch "";
}

/// Build a `remove` (state 0) sequence that clears the progress bar.
/// The percent field is present but ignored by terminals for state 0;
/// the reference emits the bare state-0 form.
pub fn clear(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "\x1b]9;4;0;\x07", .{}) catch "";
}

/// Build an `indeterminate` (state 3) busy sequence (no specific percent).
pub fn indeterminate(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "\x1b]9;4;3;\x07", .{}) catch "";
}

/// Build an `error` (state 2) sequence at the given percent (clamped).
pub fn errorState(buf: []u8, percent: u8) []const u8 {
    const p: u8 = @min(percent, 100);
    return std.fmt.bufPrint(buf, "\x1b]9;4;2;{d}\x07", .{p}) catch "";
}

// -- Tests ----------------------------------------------------------------

test "set builds OSC 9;4 state-1 with percent" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b]9;4;1;50\x07", set(&buf, 50));
}

test "set clamps percent above 100" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b]9;4;1;100\x07", set(&buf, 200));
}

test "clear builds OSC 9;4 state-0 form" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b]9;4;0;\x07", clear(&buf));
}

test "indeterminate builds OSC 9;4 state-3 form" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b]9;4;3;\x07", indeterminate(&buf));
}

test "errorState builds OSC 9;4 state-2 with percent" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b]9;4;2;0\x07", errorState(&buf, 0));
}

test "set returns empty slice when buffer too small" {
    var buf: [3]u8 = undefined;
    try std.testing.expectEqualStrings("", set(&buf, 50));
}
