const std = @import("std");
const rt = @import("zcode_runtime");

/// SSRF (Server-Side Request Forgery) guard for outbound HTTP tools.
/// Ported from claude-code-main/src/utils/hooks/ssrfGuard.ts and
/// tightened for zcode's WebFetch tool.
///
/// zcode already restricts outbound fetches to http/https and
/// blocks redirect-hop protocol escapes, but that's only half the
/// defense: an attacker-controlled prompt can still point the
/// model at a legitimate http:// URL whose IP lands in a cloud-
/// metadata range and exfiltrate credentials via the fetch body.
/// The usual suspects:
///
///   AWS IMDSv1/v2        http://169.254.169.254/latest/meta-data/...
///   AWS ECS task role    http://169.254.170.2/v2/credentials/...
///   Google Cloud         http://metadata.google.internal/... (→ 169.254.169.254)
///   Alibaba Cloud        http://100.100.100.200/latest/meta-data/...
///   Kubernetes API       private ranges (10.*, 172.16-31.*, 192.168.*)
///
/// This module defends by:
///
/// 1. `isBlockedIpv4` / `isBlockedIpv6` — byte-level address-in-
///    range checks for literal IP URLs (the easy case; matches
///    the reference's isBlockedV4 / isBlockedV6).
/// 2. `hostnameIsBlocked` — resolves a hostname via getAddressList
///    and returns true when ANY resolved address falls in a
///    blocked range. Catches DNS-name attacks like
///    metadata.google.internal which resolve to 169.254.*.
/// 3. `urlIsBlocked` — all-in-one entry point that extracts the
///    host from an http/https URL and runs whichever of the two
///    checks applies. WebFetch calls this before spawning curl.
///
/// Loopback (127.0.0.0/8, ::1) is INTENTIONALLY ALLOWED: local
/// dev policy servers are a primary WebFetch use case on
/// enterprise machines, and the reference makes the same
/// trade-off for the same reason.
pub const BlockOptions = struct {
    /// Allow RFC1918 IPv4 and IPv6 unique-local addresses while still
    /// blocking cloud metadata, link-local, CGNAT, unspecified, etc.
    /// This is only for explicitly configured local-provider endpoints
    /// such as Ollama running on another machine in the user's LAN.
    allow_private_networks: bool = false,
};

/// True when `a.b.c.d` is inside an RFC1918 private LAN range.
pub fn isPrivateIpv4(octets: [4]u8) bool {
    const a = octets[0];
    const b = octets[1];
    return a == 10 or
        (a == 172 and b >= 16 and b <= 31) or
        (a == 192 and b == 168);
}

/// True when `a.b.c.d` is inside any of the cloud-metadata or
/// private ranges we want to block. Takes the four octets as
/// a u8 array so callers can pass either a parsed IP or four
/// integers directly.
///
/// Blocked IPv4:
///   0.0.0.0/8         "this" network
///   10.0.0.0/8        private
///   100.64.0.0/10     CGNAT -- Alibaba metadata lives here (100.100.100.200)
///   169.254.0.0/16    link-local (AWS IMDS, GCP metadata, ECS task role)
///   172.16.0.0/12     private
///   192.168.0.0/16    private
pub fn isBlockedIpv4(octets: [4]u8) bool {
    return isBlockedIpv4WithOptions(octets, .{});
}

pub fn isBlockedIpv4WithOptions(octets: [4]u8, options: BlockOptions) bool {
    const a = octets[0];
    const b = octets[1];

    // Loopback explicitly allowed.
    if (a == 127) return false;
    if (options.allow_private_networks and isPrivateIpv4(octets)) return false;

    // 0.0.0.0/8
    if (a == 0) return true;
    // 10.0.0.0/8
    if (a == 10) return true;
    // 169.254.0.0/16 -- link-local, cloud metadata
    if (a == 169 and b == 254) return true;
    // 172.16.0.0/12
    if (a == 172 and b >= 16 and b <= 31) return true;
    // 100.64.0.0/10 -- CGNAT / Alibaba Cloud metadata
    if (a == 100 and b >= 64 and b <= 127) return true;
    // 192.168.0.0/16
    if (a == 192 and b == 168) return true;

    return false;
}

pub fn isPrivateIpv6(bytes: [16]u8) bool {
    // fc00::/7 -- unique local address space.
    return bytes[0] == 0xfc or bytes[0] == 0xfd;
}

/// True when the IPv6 bytes fall in a blocked range. Accepts a
/// 16-byte address. Handles IPv4-mapped IPv6 (::ffff:a.b.c.d) by
/// delegating to isBlockedIpv4 so `::ffff:169.254.169.254` and
/// its hex form `::ffff:a9fe:a9fe` both get caught.
///
/// Blocked IPv6:
///   ::             unspecified
///   fc00::/7       unique local (fc00..fdff)
///   fe80::/10      link-local (fe80..febf)
///   ::ffff:<v4>    IPv4-mapped with blocked v4 target
pub fn isBlockedIpv6(bytes: [16]u8) bool {
    return isBlockedIpv6WithOptions(bytes, .{});
}

pub fn isBlockedIpv6WithOptions(bytes: [16]u8, options: BlockOptions) bool {
    // Loopback (::1) explicitly allowed.
    if (std.mem.eql(u8, &bytes, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 })) return false;

    // :: unspecified.
    if (std.mem.eql(u8, &bytes, &[_]u8{0} ** 16)) return true;

    // IPv4-mapped IPv6: first 10 bytes zero, next 2 bytes 0xff,
    // last 4 bytes are the v4 address.
    const mapped_prefix = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };
    if (std.mem.eql(u8, bytes[0..12], &mapped_prefix)) {
        return isBlockedIpv4WithOptions(.{ bytes[12], bytes[13], bytes[14], bytes[15] }, options);
    }

    // fc00::/7 -- first byte's high 7 bits are 1111110 (0xfc or 0xfd).
    if (isPrivateIpv6(bytes)) return !options.allow_private_networks;

    // fe80::/10 -- first byte 0xfe, second byte top 2 bits 10 (0x80..0xbf).
    if (bytes[0] == 0xfe and bytes[1] >= 0x80 and bytes[1] <= 0xbf) return true;

    return false;
}

/// Classify a parsed std.Io.net.IpAddress. Returns true for any of the
/// blocked v4/v6 ranges above. Used by `hostnameIsBlocked` after
/// DNS resolution and by the unit tests.
pub fn isBlockedAddress(addr: std.Io.net.IpAddress) bool {
    return isBlockedAddressWithOptions(addr, .{});
}

pub fn isBlockedAddressWithOptions(addr: std.Io.net.IpAddress, options: BlockOptions) bool {
    switch (addr) {
        .ip4 => |ip4| return isBlockedIpv4WithOptions(ip4.bytes, options),
        .ip6 => |ip6| return isBlockedIpv6WithOptions(ip6.bytes, options),
    }
}

pub fn isPrivateNetworkAddress(addr: std.Io.net.IpAddress) bool {
    switch (addr) {
        .ip4 => |ip4| return isPrivateIpv4(ip4.bytes),
        .ip6 => |ip6| return isPrivateIpv6(ip6.bytes),
    }
}

/// Resolve `host` via std.Io.net.getAddressList and return true if
/// ANY resolved address falls in a blocked range. On DNS failure
/// the function returns `false` so the existing fetch path still
/// runs -- zcode's curl will then report its own error. We do NOT
/// fail-open on resolvable-but-blocked, because that's the whole
/// point of the guard.
pub fn hostnameIsBlocked(allocator: std.mem.Allocator, host: []const u8) bool {
    return hostnameIsBlockedWithOptions(allocator, host, .{});
}

pub fn hostnameIsBlockedWithOptions(allocator: std.mem.Allocator, host: []const u8, options: BlockOptions) bool {
    _ = allocator;
    // First-resolution coverage only. In 0.16 std.Io.net dropped
    // getAddressList; IpAddress.resolve returns a single address per call.
    // This still blocks the common SSRF cases (DNS rebinding to a single
    // private IP, hostnames that point at 127.0.0.1 / 169.254.169.254,
    // etc.) but no longer enumerates every A/AAAA record. A multi-IP
    // hostname where some addresses are public and some private will
    // pass the check based on whichever resolve() returns first.
    if (std.Io.net.IpAddress.resolve(rt.io, host, 0)) |addr| {
        return isBlockedAddressWithOptions(addr, options);
    } else |_| {}
    return false;
}

pub fn hostnameIsPrivateNetwork(allocator: std.mem.Allocator, host: []const u8) bool {
    _ = allocator;
    if (std.Io.net.IpAddress.parse(host, 0)) |addr| {
        return isPrivateNetworkAddress(addr);
    } else |_| {}
    if (std.Io.net.IpAddress.resolve(rt.io, host, 0)) |addr| {
        return isPrivateNetworkAddress(addr);
    } else |_| {}
    return false;
}

/// All-in-one entry point for WebFetch and friends. Given an
/// http:// or https:// URL, extract the host and decide whether
/// the fetch should be blocked. Returns true for any URL whose
/// host resolves into the SSRF deny-list. Non-http(s) URLs return
/// false because the existing scheme whitelist in webFetch
/// handles them separately (don't double-report).
pub fn urlIsBlocked(allocator: std.mem.Allocator, url: []const u8) bool {
    return urlIsBlockedWithOptions(allocator, url, .{});
}

pub fn urlIsBlockedWithOptions(allocator: std.mem.Allocator, url: []const u8, options: BlockOptions) bool {
    const host = extractHost(url) orelse return false;
    if (host.len == 0) return false;

    // Try parsing the host as an IP literal first (cheap, no DNS).
    if (std.Io.net.IpAddress.parse(host, 0)) |addr| {
        return isBlockedAddressWithOptions(addr, options);
    } else |_| {}

    return hostnameIsBlockedWithOptions(allocator, host, options);
}

/// Extract the host component from an http(s) or ws(s) URL. Accepts
/// either a bracketed IPv6 literal (`[::1]`) or a plain host/IPv4.
/// The result excludes port, path, query, and userinfo.
/// Returns null for anything that isn't clearly http(s)/ws(s) so
/// non-url strings can't accidentally trigger DNS probes.
pub fn extractHost(url: []const u8) ?[]const u8 {
    // Require an http(s) or ws(s) scheme. Case-insensitive so
    // "HTTP://..." still parses like curl would.
    const prefixes = [_][]const u8{ "http://", "https://", "ws://", "wss://" };
    var after: []const u8 = undefined;
    var matched = false;
    for (prefixes) |prefix| {
        if (url.len >= prefix.len and std.ascii.eqlIgnoreCase(url[0..prefix.len], prefix)) {
            after = url[prefix.len..];
            matched = true;
            break;
        }
    }
    if (!matched) return null;

    // Strip userinfo (user:pass@host) if present. The @ can only
    // appear inside the authority section, before the first '/'.
    const authority_end = std.mem.indexOfAny(u8, after, "/?#") orelse after.len;
    var authority = after[0..authority_end];
    if (std.mem.indexOfScalar(u8, authority, '@')) |at| {
        authority = authority[at + 1 ..];
    }
    if (authority.len == 0) return null;

    // Bracketed IPv6 literal: [::1] or [2001:db8::1]:8080
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return null;
        if (close <= 1) return null;
        return authority[1..close];
    }

    // Plain host[:port]
    const colon = std.mem.indexOfScalar(u8, authority, ':');
    if (colon) |c| return authority[0..c];
    return authority;
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "isBlockedIpv4 loopback is allowed" {
    try testing.expect(!isBlockedIpv4(.{ 127, 0, 0, 1 }));
    try testing.expect(!isBlockedIpv4(.{ 127, 255, 255, 254 }));
}

test "isBlockedIpv4 AWS IMDS is blocked" {
    try testing.expect(isBlockedIpv4(.{ 169, 254, 169, 254 }));
    // ECS task role endpoint
    try testing.expect(isBlockedIpv4(.{ 169, 254, 170, 2 }));
}

test "isBlockedIpv4 Alibaba Cloud metadata is blocked" {
    try testing.expect(isBlockedIpv4(.{ 100, 100, 100, 200 }));
    // Boundary of CGNAT range
    try testing.expect(isBlockedIpv4(.{ 100, 64, 0, 0 }));
    try testing.expect(isBlockedIpv4(.{ 100, 127, 255, 255 }));
    // Just outside CGNAT
    try testing.expect(!isBlockedIpv4(.{ 100, 63, 255, 255 }));
    try testing.expect(!isBlockedIpv4(.{ 100, 128, 0, 0 }));
}

test "isBlockedIpv4 private ranges are blocked" {
    try testing.expect(isBlockedIpv4(.{ 10, 0, 0, 1 }));
    try testing.expect(isBlockedIpv4(.{ 172, 16, 0, 1 }));
    try testing.expect(isBlockedIpv4(.{ 172, 31, 255, 254 }));
    try testing.expect(isBlockedIpv4(.{ 192, 168, 1, 1 }));
    // Just outside 172.16/12
    try testing.expect(!isBlockedIpv4(.{ 172, 15, 0, 0 }));
    try testing.expect(!isBlockedIpv4(.{ 172, 32, 0, 0 }));
}

test "isBlockedIpv4 public addresses pass through" {
    try testing.expect(!isBlockedIpv4(.{ 1, 1, 1, 1 }));
    try testing.expect(!isBlockedIpv4(.{ 8, 8, 8, 8 }));
    try testing.expect(!isBlockedIpv4(.{ 140, 82, 121, 4 })); // GitHub
}

test "isBlockedIpv4 0.0.0.0/8 is blocked" {
    try testing.expect(isBlockedIpv4(.{ 0, 0, 0, 0 }));
    try testing.expect(isBlockedIpv4(.{ 0, 255, 255, 255 }));
}

test "isBlockedIpv6 ::1 loopback is allowed" {
    const loopback = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    try testing.expect(!isBlockedIpv6(loopback));
}

test "isBlockedIpv6 unspecified :: is blocked" {
    const unspecified = [_]u8{0} ** 16;
    try testing.expect(isBlockedIpv6(unspecified));
}

test "isBlockedIpv6 fc00::/7 unique-local is blocked" {
    var bytes = [_]u8{0} ** 16;
    bytes[0] = 0xfc;
    try testing.expect(isBlockedIpv6(bytes));
    bytes[0] = 0xfd;
    try testing.expect(isBlockedIpv6(bytes));
    // Just outside
    bytes[0] = 0xfb;
    try testing.expect(!isBlockedIpv6(bytes));
    bytes[0] = 0xfe;
    bytes[1] = 0;
    try testing.expect(!isBlockedIpv6(bytes));
}

test "isBlockedIpv6 fe80::/10 link-local is blocked" {
    var bytes = [_]u8{0} ** 16;
    bytes[0] = 0xfe;
    bytes[1] = 0x80;
    try testing.expect(isBlockedIpv6(bytes));
    bytes[1] = 0xbf;
    try testing.expect(isBlockedIpv6(bytes));
    bytes[1] = 0xc0; // outside /10
    try testing.expect(!isBlockedIpv6(bytes));
}

test "isBlockedIpv6 v4-mapped forwards to v4 check" {
    // ::ffff:169.254.169.254 -> mapped AWS IMDS -> blocked
    var mapped = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 169, 254, 169, 254 };
    try testing.expect(isBlockedIpv6(mapped));
    // ::ffff:127.0.0.1 -> mapped loopback -> allowed
    mapped[12] = 127;
    mapped[13] = 0;
    mapped[14] = 0;
    mapped[15] = 1;
    try testing.expect(!isBlockedIpv6(mapped));
    // ::ffff:8.8.8.8 -> public -> allowed
    mapped[12] = 8;
    mapped[13] = 8;
    mapped[14] = 8;
    mapped[15] = 8;
    try testing.expect(!isBlockedIpv6(mapped));
}

test "extractHost from http URL" {
    try testing.expectEqualStrings("example.com", extractHost("http://example.com/path?q=1").?);
    try testing.expectEqualStrings("example.com", extractHost("HTTPS://example.com").?);
    try testing.expectEqualStrings("169.254.169.254", extractHost("http://169.254.169.254/latest/meta-data/").?);
}

test "extractHost strips userinfo" {
    try testing.expectEqualStrings("example.com", extractHost("http://user:pass@example.com/").?);
}

test "extractHost strips port" {
    try testing.expectEqualStrings("example.com", extractHost("http://example.com:8080/path").?);
}

test "extractHost handles bracketed IPv6 literals" {
    try testing.expectEqualStrings("::1", extractHost("http://[::1]:8080/").?);
    try testing.expectEqualStrings("2001:db8::1", extractHost("https://[2001:db8::1]/path").?);
}

test "extractHost returns null for non-http URLs" {
    try testing.expect(extractHost("file:///etc/passwd") == null);
    try testing.expect(extractHost("ftp://example.com/") == null);
    try testing.expect(extractHost("gopher://example.com/") == null);
    try testing.expect(extractHost("not a url at all") == null);
}

test "urlIsBlocked flags IP-literal AWS IMDS URL" {
    try testing.expect(urlIsBlocked(testing.allocator, "http://169.254.169.254/latest/meta-data/iam/security-credentials/"));
}

test "urlIsBlocked flags Alibaba metadata URL" {
    try testing.expect(urlIsBlocked(testing.allocator, "http://100.100.100.200/latest/meta-data/"));
}

test "urlIsBlocked flags ECS task role URL" {
    try testing.expect(urlIsBlocked(testing.allocator, "http://169.254.170.2/v2/credentials/role"));
}

test "urlIsBlocked allows loopback dev servers" {
    try testing.expect(!urlIsBlocked(testing.allocator, "http://127.0.0.1:8080/health"));
    try testing.expect(!urlIsBlocked(testing.allocator, "http://[::1]:8080/"));
}

test "urlIsBlocked flags private IP literals" {
    try testing.expect(urlIsBlocked(testing.allocator, "http://10.0.0.1/"));
    try testing.expect(urlIsBlocked(testing.allocator, "http://192.168.1.1/"));
    try testing.expect(urlIsBlocked(testing.allocator, "http://172.16.0.1/"));
}

test "urlIsBlockedWithOptions allows private LAN but not metadata" {
    const options: BlockOptions = .{ .allow_private_networks = true };
    try testing.expect(!urlIsBlockedWithOptions(testing.allocator, "http://10.0.0.1:11434/", options));
    try testing.expect(!urlIsBlockedWithOptions(testing.allocator, "http://172.16.0.1:11434/", options));
    try testing.expect(!urlIsBlockedWithOptions(testing.allocator, "http://192.168.1.124:11434/", options));
    try testing.expect(urlIsBlockedWithOptions(testing.allocator, "http://169.254.169.254/latest/meta-data/", options));
}

test "urlIsBlocked returns false for non-http URLs" {
    // Other schemes are caller's problem -- WebFetch already
    // blocks them via the scheme whitelist. We return false so
    // we don't double-report and confuse the error message.
    try testing.expect(!urlIsBlocked(testing.allocator, "file:///etc/passwd"));
}
