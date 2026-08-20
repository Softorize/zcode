//! Tiny UUID-v4 helper. zcode keys per-turn history snapshots and
//! consistency checks off a stable random id (Phase 11 sessions-01/08
//! foundation). This factors the 128-bit crypto-RNG hex generation that
//! `session/store.createSessionId` already did inline into one place so
//! both the session-id and the per-turn-uuid paths share it.
//!
//! `v4Hex` writes the canonical 8-4-4-4-12 dashed form (36 chars) into a
//! caller buffer; `allocV4` returns the same string heap-allocated.
//! `rawHex32` writes the undashed 32-hex-char form used by
//! `createSessionId` (which prepends `<timestamp>-`). All three draw from
//! the crypto RNG via `core/rng.secureBytes`, so the ids are collision-free
//! at every realistic scale.

const std = @import("std");
const rng = @import("rng.zig");

/// Hex digit for a 0..15 nibble. Lowercase to match the existing
/// session-id format.
fn hexDigit(nibble: u4) u8 {
    return if (nibble < 10) @as(u8, '0') + nibble else @as(u8, 'a') + (nibble - 10);
}

/// Write `bytes` as lowercase hex into `out` (out.len must be 2*bytes.len).
fn writeHex(bytes: []const u8, out: []u8) void {
    std.debug.assert(out.len == bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[i * 2] = hexDigit(@intCast((b >> 4) & 0x0f));
        out[i * 2 + 1] = hexDigit(@intCast(b & 0x0f));
    }
}

/// Write 32 lowercase hex chars (16 random bytes) into `out`. This is the
/// raw, undashed form `createSessionId` consumes.
pub fn rawHex32(out: *[32]u8) void {
    var nonce: [16]u8 = undefined;
    rng.secureBytes(&nonce);
    writeHex(&nonce, out);
}

/// Write a canonical UUID-v4 string (8-4-4-4-12, 36 chars including the
/// four dashes) into `out`. Version and variant nibbles are set per
/// RFC 4122 so the value is a well-formed v4 uuid.
pub fn v4Hex(out: *[36]u8) void {
    var bytes: [16]u8 = undefined;
    rng.secureBytes(&bytes);
    // Version 4 (random): high nibble of byte 6 = 0b0100.
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    // Variant 1 (RFC 4122): top two bits of byte 8 = 0b10.
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    var hex: [32]u8 = undefined;
    writeHex(&bytes, &hex);

    // 8-4-4-4-12 with dashes at 8,13,18,23.
    @memcpy(out[0..8], hex[0..8]);
    out[8] = '-';
    @memcpy(out[9..13], hex[8..12]);
    out[13] = '-';
    @memcpy(out[14..18], hex[12..16]);
    out[18] = '-';
    @memcpy(out[19..23], hex[16..20]);
    out[23] = '-';
    @memcpy(out[24..36], hex[20..32]);
}

/// Heap-allocate a canonical UUID-v4 string. Caller owns the returned
/// slice and frees it.
pub fn allocV4(allocator: std.mem.Allocator) ![]u8 {
    var buf: [36]u8 = undefined;
    v4Hex(&buf);
    return allocator.dupe(u8, &buf);
}

const testing = std.testing;

test "v4Hex produces a well-formed canonical uuid" {
    var buf: [36]u8 = undefined;
    v4Hex(&buf);
    // Dashes in the canonical positions.
    try testing.expectEqual(@as(u8, '-'), buf[8]);
    try testing.expectEqual(@as(u8, '-'), buf[13]);
    try testing.expectEqual(@as(u8, '-'), buf[18]);
    try testing.expectEqual(@as(u8, '-'), buf[23]);
    // Version nibble is '4'.
    try testing.expectEqual(@as(u8, '4'), buf[14]);
    // Variant nibble is one of 8,9,a,b.
    try testing.expect(buf[19] == '8' or buf[19] == '9' or buf[19] == 'a' or buf[19] == 'b');
    // Every non-dash position is a hex digit.
    for (buf, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue;
        try testing.expect(std.ascii.isHex(c));
    }
}

test "v4Hex draws distinct ids back to back" {
    var a: [36]u8 = undefined;
    var b: [36]u8 = undefined;
    v4Hex(&a);
    v4Hex(&b);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "allocV4 round-trips through the allocator" {
    const id = try allocV4(testing.allocator);
    defer testing.allocator.free(id);
    try testing.expectEqual(@as(usize, 36), id.len);
    try testing.expectEqual(@as(u8, '-'), id[8]);
}

test "rawHex32 writes 32 lowercase hex chars" {
    var buf: [32]u8 = undefined;
    rawHex32(&buf);
    for (buf) |c| {
        try testing.expect(std.ascii.isHex(c));
        try testing.expect(!std.ascii.isUpper(c));
    }
    var buf2: [32]u8 = undefined;
    rawHex32(&buf2);
    try testing.expect(!std.mem.eql(u8, &buf, &buf2));
}
