//! #575: Spinner component - animated loading indicator.
//!
//! Direct port of the spinner concept from reference Ink components
//! (spinners use a frame sequence cycled on a timer). zcode's version
//! produces the frame for a given tick; the REPL overlay loop drives
//! the tick.

const std = @import("std");

pub const Spinner = struct {
    frames: []const []const u8,
    tick: u32 = 0,

    pub fn current(self: Spinner) []const u8 {
        if (self.frames.len == 0) return "";
        return self.frames[self.tick % self.frames.len];
    }

    pub fn advance(self: *Spinner) void {
        self.tick += 1;
    }
};

/// Default dot spinner (matching the reference's default).
pub const dots = Spinner{
    .frames = &.{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
};

/// Dashes spinner.
pub const dashes = Spinner{
    .frames = &.{ "-", "\\", "|", "/" },
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Spinner.current returns first frame at tick 0" {
    const s = Spinner{ .frames = &.{ "a", "b", "c" } };
    try testing.expectEqualStrings("a", s.current());
}

test "Spinner.current cycles through frames" {
    var s = Spinner{ .frames = &.{ "a", "b", "c" } };
    try testing.expectEqualStrings("a", s.current());
    s.advance();
    try testing.expectEqualStrings("b", s.current());
    s.advance();
    try testing.expectEqualStrings("c", s.current());
    s.advance();
    try testing.expectEqualStrings("a", s.current()); // wraps
}

test "Spinner.current returns empty for no frames" {
    const s = Spinner{ .frames = &.{} };
    try testing.expectEqualStrings("", s.current());
}

test "dots spinner has 10 frames" {
    try testing.expectEqual(@as(usize, 10), dots.frames.len);
}

test "dashes spinner has 4 frames" {
    try testing.expectEqual(@as(usize, 4), dashes.frames.len);
}
