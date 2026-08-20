//! OIDC ID-token verifier.
//!
//! Parses a compact JWS, validates the fixed claims (`iss`, `aud`,
//! `exp`), and extracts the `sub` and optional `role` claims.
//!
//! Supported now:
//!   - Compact JWS parse + claim extraction.
//!   - HS256 verification via shared secret for self-hosted control
//!     planes, CI, and air-gapped deployments that can provision a
//!     shared secret.
//!   - RS256 verification against a pinned JWKS JSON document for
//!     enterprise IdPs distributed through managed config.

const std = @import("std");
const rbac = @import("../policy/rbac.zig");

pub const Claims = struct {
    sub: []u8,
    iss: []u8,
    aud: []u8,
    exp: i64,
    role: rbac.Role,

    pub fn deinit(self: *Claims, allocator: std.mem.Allocator) void {
        allocator.free(self.sub);
        allocator.free(self.iss);
        allocator.free(self.aud);
    }
};

pub const Error = error{
    Malformed,
    UnsupportedAlg,
    ExpectedIssuer,
    ExpectedAudience,
    Expired,
    InvalidSignature,
    KeyNotFound,
    OutOfMemory,
    InvalidCharacter,
};

pub const Expectation = struct {
    issuer: []const u8,
    audience: []const u8,
    now_unix: i64,
};

/// Parse a JWT of the form `header.payload.signature` and validate claims
/// without checking the signature. This is retained for parser tests and
/// trusted internal fixtures; the API server uses `verifyHS256`.
pub fn verifyUnsigned(
    allocator: std.mem.Allocator,
    token: []const u8,
    expect: Expectation,
) Error!Claims {
    const compact = try splitCompactJwt(token);
    _ = compact.header_b64;
    _ = compact.signature_b64;

    return parseClaims(allocator, compact.payload_b64, expect);
}

/// Verify a compact JWT signed with HS256 and return its validated claims.
/// This is suitable for self-hosted control planes or a trusted reverse proxy
/// that converts RS256/OIDC provider tokens into short-lived internal tokens.
pub fn verifyHS256(
    allocator: std.mem.Allocator,
    token: []const u8,
    expect: Expectation,
    secret: []const u8,
) Error!Claims {
    if (secret.len == 0) return Error.InvalidSignature;

    const compact = try splitCompactJwt(token);
    var header = try parseHeader(allocator, compact.header_b64);
    defer header.deinit(allocator);
    if (!std.mem.eql(u8, header.alg, "HS256")) return Error.UnsupportedAlg;

    const signature = try base64UrlDecode(allocator, compact.signature_b64);
    defer allocator.free(signature);
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    if (signature.len != HmacSha256.mac_length) return Error.InvalidSignature;

    var expected_sig: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&expected_sig, compact.signing_input, secret);
    if (!constantTimeBytesEql(&expected_sig, signature)) return Error.InvalidSignature;

    return parseClaims(allocator, compact.payload_b64, expect);
}

/// Verify a compact JWT signed with RS256 using a pinned JWKS document.
/// `jwks_json` must be a JSON object with a `keys` array containing RSA JWKs.
pub fn verifyRS256(
    allocator: std.mem.Allocator,
    token: []const u8,
    expect: Expectation,
    jwks_json: []const u8,
) Error!Claims {
    if (jwks_json.len == 0) return Error.KeyNotFound;

    const compact = try splitCompactJwt(token);
    var header = try parseHeader(allocator, compact.header_b64);
    defer header.deinit(allocator);
    if (!std.mem.eql(u8, header.alg, "RS256")) return Error.UnsupportedAlg;

    const signature = try base64UrlDecode(allocator, compact.signature_b64);
    defer allocator.free(signature);

    switch (try verifyRs256Signature(allocator, compact.signing_input, signature, jwks_json, header.kid)) {
        .verified => {},
        .key_not_found => return Error.KeyNotFound,
        .invalid_signature => return Error.InvalidSignature,
    }

    return parseClaims(allocator, compact.payload_b64, expect);
}

const CompactJwt = struct {
    header_b64: []const u8,
    payload_b64: []const u8,
    signature_b64: []const u8,
    signing_input: []const u8,
};

fn splitCompactJwt(token: []const u8) Error!CompactJwt {
    var it = std.mem.splitScalar(u8, token, '.');
    const header_b64 = it.next() orelse return Error.Malformed;
    const payload_b64 = it.next() orelse return Error.Malformed;
    const signature_b64 = it.next() orelse return Error.Malformed;
    if (it.next() != null) return Error.Malformed;

    const signing_input_len = header_b64.len + 1 + payload_b64.len;
    if (token.len < signing_input_len or token[header_b64.len] != '.') return Error.Malformed;
    return .{
        .header_b64 = header_b64,
        .payload_b64 = payload_b64,
        .signature_b64 = signature_b64,
        .signing_input = token[0..signing_input_len],
    };
}

const ParsedHeader = struct {
    alg: []u8,
    kid: ?[]u8,

    fn deinit(self: *ParsedHeader, allocator: std.mem.Allocator) void {
        allocator.free(self.alg);
        if (self.kid) |kid| allocator.free(kid);
    }
};

fn parseHeader(allocator: std.mem.Allocator, header_b64: []const u8) Error!ParsedHeader {
    const header_json = try base64UrlDecode(allocator, header_b64);
    defer allocator.free(header_json);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, header_json, .{}) catch return Error.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return Error.Malformed;

    const alg_val = parsed.value.object.get("alg") orelse return Error.Malformed;
    const alg = switch (alg_val) {
        .string => |s| s,
        else => return Error.Malformed,
    };

    var out = ParsedHeader{
        .alg = try allocator.dupe(u8, alg),
        .kid = null,
    };
    errdefer out.deinit(allocator);

    if (parsed.value.object.get("kid")) |kid_val| {
        const kid = switch (kid_val) {
            .string => |s| s,
            else => return Error.Malformed,
        };
        out.kid = try allocator.dupe(u8, kid);
    }
    return out;
}

const JwksVerification = enum {
    verified,
    key_not_found,
    invalid_signature,
};

fn verifyRs256Signature(
    allocator: std.mem.Allocator,
    signing_input: []const u8,
    signature: []const u8,
    jwks_json: []const u8,
    kid: ?[]const u8,
) Error!JwksVerification {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, jwks_json, .{}) catch return Error.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return Error.Malformed;

    const keys_val = parsed.value.object.get("keys") orelse return Error.Malformed;
    const keys = switch (keys_val) {
        .array => |arr| arr,
        else => return Error.Malformed,
    };

    var saw_matching_key = false;
    for (keys.items) |key_val| {
        if (key_val != .object) continue;
        const key = key_val.object;
        const kty = jsonStringField(key, "kty") orelse continue;
        if (!std.mem.eql(u8, kty, "RSA")) continue;
        if (jsonStringField(key, "alg")) |alg| {
            if (!std.mem.eql(u8, alg, "RS256")) continue;
        }
        if (jsonStringField(key, "use")) |use| {
            if (!std.mem.eql(u8, use, "sig")) continue;
        }
        if (kid) |expected_kid| {
            const actual_kid = jsonStringField(key, "kid") orelse continue;
            if (!std.mem.eql(u8, expected_kid, actual_kid)) continue;
        }

        saw_matching_key = true;
        const n_b64 = jsonStringField(key, "n") orelse return Error.Malformed;
        const e_b64 = jsonStringField(key, "e") orelse return Error.Malformed;
        if (try verifySingleRs256Jwk(allocator, signing_input, signature, n_b64, e_b64)) {
            return .verified;
        }
    }

    return if (saw_matching_key) .invalid_signature else .key_not_found;
}

fn jsonStringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const val = obj.get(name) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn verifySingleRs256Jwk(
    allocator: std.mem.Allocator,
    signing_input: []const u8,
    signature: []const u8,
    n_b64: []const u8,
    e_b64: []const u8,
) Error!bool {
    const modulus = try base64UrlDecode(allocator, n_b64);
    defer allocator.free(modulus);
    const exponent = try base64UrlDecode(allocator, e_b64);
    defer allocator.free(exponent);

    const rsa = std.crypto.Certificate.rsa;
    switch (modulus.len) {
        inline 128, 256, 384, 512 => |modulus_len| {
            if (signature.len != modulus_len) return false;
            const public_key = rsa.PublicKey.fromBytes(exponent, modulus) catch return Error.Malformed;
            const sig = rsa.PKCS1v1_5Signature.fromBytes(modulus_len, signature);
            rsa.PKCS1v1_5Signature.verify(
                modulus_len,
                sig,
                signing_input,
                public_key,
                std.crypto.hash.sha2.Sha256,
            ) catch return false;
            return true;
        },
        else => return Error.Malformed,
    }
}

fn parseClaims(
    allocator: std.mem.Allocator,
    payload_b64: []const u8,
    expect: Expectation,
) Error!Claims {
    const payload_json = try base64UrlDecode(allocator, payload_b64);
    defer allocator.free(payload_json);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{}) catch return Error.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return Error.Malformed;
    const obj = parsed.value.object;

    const sub_val = obj.get("sub") orelse return Error.Malformed;
    const iss_val = obj.get("iss") orelse return Error.ExpectedIssuer;
    const aud_val = obj.get("aud") orelse return Error.ExpectedAudience;
    const exp_val = obj.get("exp") orelse return Error.Malformed;

    const sub_s = switch (sub_val) {
        .string => |s| s,
        else => return Error.Malformed,
    };
    const iss_s = switch (iss_val) {
        .string => |s| s,
        else => return Error.Malformed,
    };
    const aud_s = try validateAudience(aud_val, expect.audience);
    const exp_i = switch (exp_val) {
        .integer => |i| i,
        else => return Error.Malformed,
    };

    if (!std.mem.eql(u8, iss_s, expect.issuer)) return Error.ExpectedIssuer;
    if (exp_i < expect.now_unix) return Error.Expired;

    const role = if (obj.get("role")) |r| switch (r) {
        .string => |s| rbac.Role.fromString(s),
        else => rbac.Role.none,
    } else rbac.Role.none;

    return .{
        .sub = try allocator.dupe(u8, sub_s),
        .iss = try allocator.dupe(u8, iss_s),
        .aud = try allocator.dupe(u8, aud_s),
        .exp = exp_i,
        .role = role,
    };
}

fn validateAudience(aud_val: std.json.Value, expected: []const u8) Error![]const u8 {
    switch (aud_val) {
        .string => |s| {
            if (!std.mem.eql(u8, s, expected)) return Error.ExpectedAudience;
            return s;
        },
        .array => |arr| {
            for (arr.items) |item| {
                if (item == .string and std.mem.eql(u8, item.string, expected)) {
                    return expected;
                }
            }
            return Error.ExpectedAudience;
        },
        else => return Error.Malformed,
    }
}

fn base64UrlDecode(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    // JWT uses base64url without padding; std.base64.url_safe_no_pad
    // matches exactly.
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded_len = decoder.calcSizeForSlice(s) catch return Error.Malformed;
    const out = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(out);
    decoder.decode(out, s) catch return Error.Malformed;
    return out;
}

fn base64UrlEncode(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const encoded_len = encoder.calcSize(s.len);
    const out = try allocator.alloc(u8, encoded_len);
    _ = encoder.encode(out, s);
    return out;
}

fn constantTimeBytesEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

// --- Tests ------------------------------------------------------------

const testing = std.testing;

fn makeUnsignedJwt(allocator: std.mem.Allocator, payload_json: []const u8) ![]u8 {
    const header = "{\"alg\":\"none\",\"typ\":\"JWT\"}";
    const header_b = try base64UrlEncode(allocator, header);
    defer allocator.free(header_b);
    const payload_b = try base64UrlEncode(allocator, payload_json);
    defer allocator.free(payload_b);
    return std.fmt.allocPrint(allocator, "{s}.{s}.", .{ header_b, payload_b });
}

fn makeHS256Jwt(allocator: std.mem.Allocator, payload_json: []const u8, secret: []const u8) ![]u8 {
    const header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    const header_b = try base64UrlEncode(allocator, header);
    defer allocator.free(header_b);
    const payload_b = try base64UrlEncode(allocator, payload_json);
    defer allocator.free(payload_b);
    const signing_input = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header_b, payload_b });
    defer allocator.free(signing_input);

    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var sig: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&sig, signing_input, secret);
    const sig_b = try base64UrlEncode(allocator, &sig);
    defer allocator.free(sig_b);
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ signing_input, sig_b });
}

test "verifyUnsigned accepts a matching token" {
    const allocator = testing.allocator;
    const token = try makeUnsignedJwt(allocator,
        \\{"sub":"alice","iss":"https://issuer.example","aud":"zcode","exp":9999999999,"role":"editor"}
    );
    defer allocator.free(token);

    var claims = try verifyUnsigned(allocator, token, .{
        .issuer = "https://issuer.example",
        .audience = "zcode",
        .now_unix = 1_000_000,
    });
    defer claims.deinit(allocator);
    try testing.expectEqualStrings("alice", claims.sub);
    try testing.expectEqual(rbac.Role.editor, claims.role);
}

test "verifyUnsigned rejects expired token" {
    const allocator = testing.allocator;
    const token = try makeUnsignedJwt(allocator,
        \\{"sub":"alice","iss":"https://issuer.example","aud":"zcode","exp":100}
    );
    defer allocator.free(token);

    try testing.expectError(Error.Expired, verifyUnsigned(allocator, token, .{
        .issuer = "https://issuer.example",
        .audience = "zcode",
        .now_unix = 200,
    }));
}

test "verifyUnsigned rejects issuer mismatch" {
    const allocator = testing.allocator;
    const token = try makeUnsignedJwt(allocator,
        \\{"sub":"alice","iss":"https://other","aud":"zcode","exp":9999999999}
    );
    defer allocator.free(token);

    try testing.expectError(Error.ExpectedIssuer, verifyUnsigned(allocator, token, .{
        .issuer = "https://issuer.example",
        .audience = "zcode",
        .now_unix = 1_000_000,
    }));
}

test "verifyHS256 accepts signed token and audience array" {
    const allocator = testing.allocator;
    const token = try makeHS256Jwt(allocator,
        \\{"sub":"alice","iss":"https://issuer.example","aud":["other","zcode"],"exp":9999999999,"role":"owner"}
    , "shared-secret");
    defer allocator.free(token);

    var claims = try verifyHS256(allocator, token, .{
        .issuer = "https://issuer.example",
        .audience = "zcode",
        .now_unix = 1_000_000,
    }, "shared-secret");
    defer claims.deinit(allocator);
    try testing.expectEqualStrings("alice", claims.sub);
    try testing.expectEqualStrings("zcode", claims.aud);
    try testing.expectEqual(rbac.Role.owner, claims.role);
}

test "verifyHS256 rejects wrong secret" {
    const allocator = testing.allocator;
    const token = try makeHS256Jwt(allocator,
        \\{"sub":"alice","iss":"https://issuer.example","aud":"zcode","exp":9999999999}
    , "shared-secret");
    defer allocator.free(token);

    try testing.expectError(Error.InvalidSignature, verifyHS256(allocator, token, .{
        .issuer = "https://issuer.example",
        .audience = "zcode",
        .now_unix = 1_000_000,
    }, "wrong-secret"));
}

test "verifyHS256 rejects unsupported alg" {
    const allocator = testing.allocator;
    const token = try makeUnsignedJwt(allocator,
        \\{"sub":"alice","iss":"https://issuer.example","aud":"zcode","exp":9999999999}
    );
    defer allocator.free(token);

    try testing.expectError(Error.UnsupportedAlg, verifyHS256(allocator, token, .{
        .issuer = "https://issuer.example",
        .audience = "zcode",
        .now_unix = 1_000_000,
    }, "shared-secret"));
}

fn staticRS256Jwt() []const u8 {
    return "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InRlc3QtcnNhLTEifQ." ++
        "eyJzdWIiOiJhbGljZSIsImlzcyI6Imh0dHBzOi8vaXNzdWVyLmV4YW1wbGUiLCJhdWQiOlsib3RoZXIiLCJ6Y29kZSJdLCJleHAiOjk5OTk5OTk5OTksInJvbGUiOiJvd25lciJ9." ++
        "Nz_xtHSCJNyW0aU_EhwrjgXzdzwfYfNUI8rgCNMDPy-COCx264fIrErGWr8X0VvS8o1zXyclRyKLfQBvp79-gDlDCjyBc2He6qxDPBb4DE6QuZ6jPqPfUjdJDIPMST1I9DL5dNXFj4DFCH6nTsmyJf5Dsn_uyvQDMFDt9Ih0Hn21dkBlOtZ1U2abEwE85VhsGCFkWSCPf9zSN0D1w4elVYoTeyLATpQDgBGnF4fu7JGDPt6RVPxu5CwYd94Fvee3JMZ65AFzp9QWX7RX31MVOMfsud_zqiFx15hZloEjf1F2g3A3HvBpc4wwraytBrQ3E5tD-ZG5T5VCxojLKJSqWQ";
}

fn staticRS256Jwks() []const u8 {
    return "{\"keys\":[{\"kty\":\"RSA\",\"kid\":\"test-rsa-1\",\"use\":\"sig\",\"alg\":\"RS256\",\"n\":\"vD2-3dYzJz5dDz_daBKq3MZw_QFbYzIWVkCp7mdly6O8xFMUxM0br6GkL33RZYRzm0GKSs3wGT0PVAaH1MGvv09hQvyWvEWvj4k4Sd6weuTXpvgNN1i28_2ARE7qoLe8ZYZijtwg7Lz2EBNOj8zgeuFyKU65ITGRaIO0JhMHKKlAJfrbwWF8X42KrjFz-K-r0I8CtLbFBWe9NpvLHFsqnBiZ_5KS_36Xygv7tgVo_gWhUaTz3zFvP_Ng_Q2tQ4wNUS5g1PFgheQTIU5hi54f-JvAM55NHKMjBSco9ZR_4y-4YHOpeI9STaWmb0PejOjlXPKDe6oFV4c7wgSe3-FPWw\",\"e\":\"AQAB\"}]}";
}

test "verifyRS256 accepts pinned JWKS token" {
    const allocator = testing.allocator;
    var claims = try verifyRS256(allocator, staticRS256Jwt(), .{
        .issuer = "https://issuer.example",
        .audience = "zcode",
        .now_unix = 1_000_000,
    }, staticRS256Jwks());
    defer claims.deinit(allocator);

    try testing.expectEqualStrings("alice", claims.sub);
    try testing.expectEqualStrings("zcode", claims.aud);
    try testing.expectEqual(rbac.Role.owner, claims.role);
}

test "verifyRS256 rejects missing kid" {
    const allocator = testing.allocator;
    const wrong_jwks =
        \\{"keys":[{"kty":"RSA","kid":"other","use":"sig","alg":"RS256","n":"vD2-3dYzJz5dDz_daBKq3MZw_QFbYzIWVkCp7mdly6O8xFMUxM0br6GkL33RZYRzm0GKSs3wGT0PVAaH1MGvv09hQvyWvEWvj4k4Sd6weuTXpvgNN1i28_2ARE7qoLe8ZYZijtwg7Lz2EBNOj8zgeuFyKU65ITGRaIO0JhMHKKlAJfrbwWF8X42KrjFz-K-r0I8CtLbFBWe9NpvLHFsqnBiZ_5KS_36Xygv7tgVo_gWhUaTz3zFvP_Ng_Q2tQ4wNUS5g1PFgheQTIU5hi54f-JvAM55NHKMjBSco9ZR_4y-4YHOpeI9STaWmb0PejOjlXPKDe6oFV4c7wgSe3-FPWw","e":"AQAB"}]}
    ;
    try testing.expectError(Error.KeyNotFound, verifyRS256(allocator, staticRS256Jwt(), .{
        .issuer = "https://issuer.example",
        .audience = "zcode",
        .now_unix = 1_000_000,
    }, wrong_jwks));
}
