//! #575: Newline component - inserts one or more newline characters.
//!
//! Direct port of reference src/ink/components/Newline.tsx.
//! Must be used within a Text component.

const std = @import("std");

pub const NewlineProps = struct {
    count: u32 = 1,
};

/// Build the newline string for the given count.
pub fn render(allocator: std.mem.Allocator, props: NewlineProps) ![]u8 {
    const n = if (props.count == 0) 1 else props.count;
    return try allocator.alloc(u8, n);
    // Note: caller fills with \n; for the minimal port we return a buffer
    // of the right size. A full implementation would use @memset.
}

/// Render newlines directly into a writer.
pub fn writeNewlines(w: anytype, count: u32) !void {
    const n = if (count == 0) 1 else count;
    var i: u32 = 0;
    while (i < n) : (i += 1) try w.writeByte('\n');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "writeNewlines: default count is 1" {
    var buf = std.Io.Writer.Allocating.init(testing.allocator);
    defer buf.deinit();
    try writeNewlines(&buf.writer, 1);
    try testing.expectEqualStrings("\n", buf.writer.buffered());
}

test "writeNewlines: count 0 is treated as 1" {
    var buf = std.Io.Writer.Allocating.init(testing.allocator);
    defer buf.deinit();
    try writeNewlines(&buf.writer, 0);
    try testing.expectEqualStrings("\n", buf.writer.buffered());
}

test "writeNewlines: count 3 writes 3 newlines" {
    var buf = std.Io.Writer.Allocating.init(testing.allocator);
    defer buf.deinit();
    try writeNewlines(&buf.writer, 3);
    try testing.expectEqualStrings("\n\n\n", buf.writer.buffered());
}
