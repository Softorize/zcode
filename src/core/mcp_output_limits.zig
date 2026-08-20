//! P5 (PRD #534) MCP output limits. Claude Code caps MCP tool descriptions and
//! spills oversized tool results to disk so they don't blow up the context. Pure
//! transforms: the truncation logic here; the actual disk spill is wired by the
//! MCP client.

const std = @import("std");

/// Max characters for an MCP tool description advertised to the model.
pub const MAX_DESC_LEN: usize = 2048;
/// Tool results larger than this are spilled to disk rather than inlined.
pub const MAX_RESULT_INLINE: usize = 100 * 1024;

/// Back off `n` to the start of a UTF-8 code point so we never cut mid-rune.
fn utf8SafeLen(bytes: []const u8, n: usize) usize {
    var i = @min(n, bytes.len);
    while (i > 0 and (bytes[i] & 0xC0) == 0x80) i -= 1;
    return i;
}

/// Whether `desc` exceeds the description cap.
pub fn descNeedsTruncate(desc: []const u8) bool {
    return desc.len > MAX_DESC_LEN;
}

/// Truncate `desc` to the cap at a UTF-8 boundary, appending a marker. Returns
/// `desc` unchanged (a dupe) when already within the cap. Caller frees.
pub fn truncateDescription(allocator: std.mem.Allocator, desc: []const u8) ![]u8 {
    if (!descNeedsTruncate(desc)) return allocator.dupe(u8, desc);
    const marker = "... [truncated]";
    const keep = utf8SafeLen(desc, MAX_DESC_LEN - marker.len);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ desc[0..keep], marker });
}

/// Whether a result of `len` bytes should be spilled to disk instead of inlined.
pub fn shouldSpill(len: usize) bool {
    return len > MAX_RESULT_INLINE;
}

const testing = std.testing;

test "short descriptions pass through unchanged" {
    const d = try truncateDescription(testing.allocator, "a short description");
    defer testing.allocator.free(d);
    try testing.expectEqualStrings("a short description", d);
    try testing.expect(!descNeedsTruncate("short"));
}

test "long descriptions are capped with a marker at a safe length" {
    const big = try testing.allocator.alloc(u8, MAX_DESC_LEN + 500);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    try testing.expect(descNeedsTruncate(big));
    const d = try truncateDescription(testing.allocator, big);
    defer testing.allocator.free(d);
    try testing.expect(d.len <= MAX_DESC_LEN);
    try testing.expect(std.mem.endsWith(u8, d, "[truncated]"));
}

test "utf8 truncation does not split a multibyte rune" {
    // Build a string of 2-byte runes that lands the cut mid-rune.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var i: usize = 0;
    while (i < MAX_DESC_LEN + 100) : (i += 1) try buf.appendSlice(testing.allocator, "\xc3\xa9"); // é
    const d = try truncateDescription(testing.allocator, buf.items);
    defer testing.allocator.free(d);
    // The kept prefix (before the ASCII marker) must be valid UTF-8.
    const marker = "... [truncated]";
    try testing.expect(std.unicode.utf8ValidateSlice(d[0 .. d.len - marker.len]));
}

test "shouldSpill threshold" {
    try testing.expect(!shouldSpill(1024));
    try testing.expect(!shouldSpill(MAX_RESULT_INLINE));
    try testing.expect(shouldSpill(MAX_RESULT_INLINE + 1));
}
