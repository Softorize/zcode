//! #575: AlternateScreen component - switch to the alternate screen buffer.
//!
//! Direct port of reference src/ink/components/AlternateScreen.tsx concept.
//! Terminals have a primary screen and an alternate screen. The alternate
//! screen is used for full-screen apps (like vim, less) so the primary
//! scrollback is preserved. AlternateScreen emits the escape sequence to
//! enter the alternate screen on mount and exit on unmount.
//!
//! zcode's version provides the escape sequences; the caller emits them
//! at the appropriate lifecycle points.

const std = @import("std");

/// Enter the alternate screen buffer: \x1b[?1049h
pub const ENTER_ALT_SCREEN = "\x1b[?1049h";

/// Exit the alternate screen buffer: \x1b[?1049l
pub const EXIT_ALT_SCREEN = "\x1b[?1049l";

/// Enter alternate screen and switch to cursor-home.
pub fn enterScreen(w: anytype) !void {
    try w.writeAll(ENTER_ALT_SCREEN);
    try w.writeAll("\x1b[H"); // cursor home
}

/// Exit alternate screen.
pub fn exitScreen(w: anytype) !void {
    try w.writeAll(EXIT_ALT_SCREEN);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "ENTER_ALT_SCREEN uses ?1049h" {
    try testing.expectEqualStrings("\x1b[?1049h", ENTER_ALT_SCREEN);
}

test "EXIT_ALT_SCREEN uses ?1049l" {
    try testing.expectEqualStrings("\x1b[?1049l", EXIT_ALT_SCREEN);
}

test "enterScreen writes enter sequence + cursor home" {
    var buf = std.Io.Writer.Allocating.init(testing.allocator);
    defer buf.deinit();
    try enterScreen(&buf.writer);
    try testing.expectEqualStrings("\x1b[?1049h\x1b[H", buf.writer.buffered());
}

test "exitScreen writes exit sequence" {
    var buf = std.Io.Writer.Allocating.init(testing.allocator);
    defer buf.deinit();
    try exitScreen(&buf.writer);
    try testing.expectEqualStrings("\x1b[?1049l", buf.writer.buffered());
}
