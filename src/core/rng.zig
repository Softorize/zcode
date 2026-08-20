//! Process-wide RNG shim. Splits crypto-sensitive (`secureBytes`) from
//! non-sensitive (`bytes`) so the Zig 0.16 migration can route the
//! secure path to `io.randomSecure(io, dst)` and the fast path to
//! `io.random(io, dst)` in one place instead of touching ~54 call sites.
//!
//! On Zig 0.16, both functions delegate through std.Io random entry points.
//! `secureBytes` uses the secure source first and falls back to the standard
//! process random source if the secure source is unavailable.
//!
//! Classification of sites at Stage 0 authoring time:
//!   secureBytes (must be crypto-strong):
//!     - src/session/store.zig   - session encryption key derivation
//!     - src/core/logger.zig     - HMAC keys for audit log integrity
//!     - src/core/keychain.zig   - ChaCha20-Poly1305 nonces, file-store
//!                                 fallback key material
//!     - src/mcp/client.zig      - WebSocket masking key + handshake nonce
//!     - src/mcp/oauth.zig       - OAuth state + PKCE verifier
//!     - src/mcp/websocket.zig   - WebSocket frame masking key
//!     - src/session/bundles.zig - export passphrase salt
//!   bytes (jitter / nonces / PRNG seeds / tests):
//!     - everywhere else
//!
//! Helpers like std.crypto.random.int / intRangeAtMost /
//! uintLessThanBiased are NOT wrapped here. Their migration to 0.16's
//! io.random interface is independent and lower-volume.

const std = @import("std");
const runtime = @import("zcode_runtime");

/// Cryptographically secure random bytes (explicit io variant).
pub fn secureBytesIo(io: std.Io, dst: []u8) void {
    std.Io.randomSecure(io, dst) catch {
        std.Io.random(io, dst);
    };
}

/// Random bytes for non-security uses (explicit io variant).
pub fn bytesIo(io: std.Io, dst: []u8) void {
    std.Io.random(io, dst);
}

/// Cryptographically secure random bytes. Use for keys, nonces,
/// session IDs, OAuth state, anything where predictability is a
/// security boundary.
pub fn secureBytes(dst: []u8) void {
    secureBytesIo(runtime.io, dst);
}

/// Random bytes for non-security uses: jitter, PRNG seeds, test
/// fixtures, anything where biased / cheap RNG is fine.
pub fn bytes(dst: []u8) void {
    bytesIo(runtime.io, dst);
}

/// Allocate a cryptographically-secure random lowercase-hex id of
/// `byte_count` random bytes (so the returned string is `byte_count * 2`
/// hex chars). Used for per-request correlation ids (x-client-request-id)
/// and similar non-guessable handles. Caller owns the returned slice.
pub fn hexId(allocator: std.mem.Allocator, byte_count: usize) ![]u8 {
    const raw = try allocator.alloc(u8, byte_count);
    defer allocator.free(raw);
    secureBytes(raw);
    const out = try allocator.alloc(u8, byte_count * 2);
    const hex = "0123456789abcdef";
    for (raw, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    return out;
}

test "rng: hexId returns non-empty hex and differs across generations" {
    const a = try hexId(std.testing.allocator, 16);
    defer std.testing.allocator.free(a);
    const b = try hexId(std.testing.allocator, 16);
    defer std.testing.allocator.free(b);

    try std.testing.expectEqual(@as(usize, 32), a.len);
    try std.testing.expectEqual(@as(usize, 32), b.len);
    for (a) |c| try std.testing.expect(std.ascii.isHex(c));
    // Two independent 16-byte draws colliding is astronomically unlikely.
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

test "rng: secureBytes fills the buffer" {
    var buf: [32]u8 = @splat(0);
    secureBytes(&buf);
    var any_nonzero = false;
    for (buf) |b| {
        if (b != 0) {
            any_nonzero = true;
            break;
        }
    }
    try std.testing.expect(any_nonzero);
}

test "rng: bytes fills the buffer" {
    var buf: [16]u8 = @splat(0);
    bytes(&buf);
    var any_nonzero = false;
    for (buf) |b| {
        if (b != 0) {
            any_nonzero = true;
            break;
        }
    }
    try std.testing.expect(any_nonzero);
}

/// Random integer of type T using io.random byte source.
pub fn int(comptime T: type) T {
    var buf: [@sizeOf(T)]u8 = undefined;
    bytes(&buf);
    return std.mem.bytesToValue(T, &buf);
}

/// Random integer in [min, max].
pub fn intRangeAtMost(comptime T: type, min: T, max: T) T {
    if (min == max) return min;
    const range = @as(T, max) - @as(T, min) + 1;
    const r = int(T);
    return min + @rem(r, range);
}

/// Random uint < max.
pub fn uintLessThanBiased(comptime T: type, max: T) T {
    if (max == 0) return 0;
    const r = int(T);
    return @rem(r, max);
}
