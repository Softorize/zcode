//! Confirmation messages for the `#`-prefix memory-capture input mode.
//!
//! Mirrors the reference's `getSavingMessage()` in
//! `claude-code-main/src/components/messages/UserMemoryInputMessage.tsx:8-10`,
//! which samples one of three short acknowledgements after appending a line to
//! the project instruction file. zcode picks the index from `core/rng.zig`
//! (one byte) per the runtime conventions -- never `std.crypto.random.*`.

const std = @import("std");

pub const SAVING_MESSAGES = [_][]const u8{ "Got it.", "Good to know.", "Noted." };

/// Return one of the three confirmation strings. `pick` is taken modulo the
/// list length so any caller-supplied byte (e.g. a single random byte) maps to
/// a valid entry without bounds-checking at the call site.
pub fn savingMessage(pick: usize) []const u8 {
    return SAVING_MESSAGES[pick % SAVING_MESSAGES.len];
}

const testing = std.testing;

test "savingMessage returns each of the three confirmations" {
    try testing.expectEqualStrings("Got it.", savingMessage(0));
    try testing.expectEqualStrings("Good to know.", savingMessage(1));
    try testing.expectEqualStrings("Noted.", savingMessage(2));
}

test "savingMessage wraps out-of-range picks" {
    // 3 % 3 == 0, 4 % 3 == 1, 255 % 3 == 0
    try testing.expectEqualStrings("Got it.", savingMessage(3));
    try testing.expectEqualStrings("Good to know.", savingMessage(4));
    try testing.expectEqualStrings("Got it.", savingMessage(255));
}
