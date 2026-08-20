//! Utilities for safely rendering attacker-controllable strings to
//! the operator's terminal. The common pattern: a piece of state
//! (env var value, MCP server name from disk, plugin display text)
//! lives in a file or env var that an attacker may have written
//! AND eventually flows through `try writer.print("{s}", .{...})`
//! into the user's stdout/stderr. If we don't escape C0 control
//! bytes and DEL, the value can:
//!
//!   - corrupt TSV / column-aligned output (a stored newline
//!     inserts a phantom row),
//!   - smuggle a secondary line into JSONL log sinks when the
//!     value lands in an std.log.warn format string,
//!   - or worse, emit ANSI escapes that move the cursor, hide
//!     text, or fake a prompt -- a classic terminal-injection
//!     attack vector.
//!
//! The rule is the same across passes 50/51/52: anything below
//! 0x20 and 0x7f gets rewritten to \xHH. UTF-8 high-bit bytes
//! pass through unchanged so locale-correct paths and prose
//! survive intact.

const std = @import("std");

/// Allocate a copy of `value` with C0 control bytes and DEL
/// rewritten as `\xHH`. Caller owns the returned slice.
pub fn sanitize(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    const w = &buf.writer;
    for (value) |b| {
        if (b < 0x20 or b == 0x7f) {
            try w.print("\\x{x:0>2}", .{b});
        } else {
            try w.writeByte(b);
        }
    }
    var list = buf.toArrayList();
    return list.toOwnedSlice(allocator);
}

/// Returns true if `value` contains any byte that `sanitize` would
/// rewrite. Cheap pre-check for callers that want to short-circuit
/// the allocation when the input is already clean.
pub fn hasControlByte(value: []const u8) bool {
    for (value) |b| {
        if (b < 0x20 or b == 0x7f) return true;
    }
    return false;
}

const testing = std.testing;

test "sanitize escapes newline, ESC, NUL, DEL" {
    const alloc = testing.allocator;

    const out1 = try sanitize(alloc, "evil\nhack");
    defer alloc.free(out1);
    try testing.expectEqualStrings("evil\\x0ahack", out1);

    const out2 = try sanitize(alloc, "red\x1b[31m");
    defer alloc.free(out2);
    try testing.expectEqualStrings("red\\x1b[31m", out2);

    const out3 = try sanitize(alloc, "a\x00b");
    defer alloc.free(out3);
    try testing.expectEqualStrings("a\\x00b", out3);

    const out4 = try sanitize(alloc, "a\x7fb");
    defer alloc.free(out4);
    try testing.expectEqualStrings("a\\x7fb", out4);
}

test "sanitize preserves UTF-8 high-bit bytes" {
    const alloc = testing.allocator;
    const out = try sanitize(alloc, "caf\xc3\xa9");
    defer alloc.free(out);
    try testing.expectEqualStrings("caf\xc3\xa9", out);
}

test "hasControlByte short-circuit" {
    try testing.expect(hasControlByte("a\nb"));
    try testing.expect(hasControlByte("a\x1bb"));
    try testing.expect(hasControlByte("a\x7fb"));
    try testing.expect(!hasControlByte("plain ascii"));
    try testing.expect(!hasControlByte("caf\xc3\xa9"));
    try testing.expect(!hasControlByte(""));
}
