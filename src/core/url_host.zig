//! URL host/scheme comparison helpers for WebFetch redirect detection.
//!
//! Ports the hostname rule from the reference `isPermittedRedirect`
//! (claude-code-main/src/tools/WebFetchTool/utils.ts:205-243): a redirect
//! is "permitted" (followed silently) only when it stays on the same host
//! modulo a leading `www.` AND keeps the same scheme. A cross-host hop --
//! or an http -> https (scheme change) hop -- is surfaced to the model
//! with a "REDIRECT DETECTED:" message instead of being followed silently.
//!
//! Host extraction is delegated to `ssrf_guard.extractHost` (already the
//! single host parser in the codebase). This module adds scheme extraction
//! and the same-host-modulo-www comparison on top.

const std = @import("std");
const ssrf_guard = @import("ssrf_guard.zig");

/// Extract the lowercase scheme of an http(s)/ws(s) URL ("http", "https",
/// "ws", "wss"). Returns null for anything without a recognized scheme so a
/// non-url string cannot accidentally compare equal.
pub fn extractScheme(url: []const u8) ?[]const u8 {
    const schemes = [_][]const u8{ "https", "http", "wss", "ws" };
    for (schemes) |s| {
        // Match "<scheme>://" case-insensitively, returning the canonical
        // lowercase form so callers can compare with plain eql.
        if (url.len >= s.len + 3 and
            std.ascii.eqlIgnoreCase(url[0..s.len], s) and
            std.mem.eql(u8, url[s.len .. s.len + 3], "://"))
        {
            return s;
        }
    }
    return null;
}

/// Strip a single leading `www.` (case-insensitive) from a bare host.
fn stripWww(host: []const u8) []const u8 {
    if (host.len > 4 and std.ascii.eqlIgnoreCase(host[0..4], "www.")) {
        return host[4..];
    }
    return host;
}

/// True when two URLs point at the same host (ignoring a leading `www.`,
/// case-insensitively) AND use the same scheme. Used to decide whether a
/// curl redirect stayed "on host" (follow silently) or crossed to a
/// different host/scheme (surface a REDIRECT DETECTED message).
///
/// Returns false if either URL has no parseable host or scheme -- an
/// unparseable effective URL is treated as a host change so we err toward
/// surfacing the redirect rather than hiding it.
pub fn sameHostModuloWww(a: []const u8, b: []const u8) bool {
    const scheme_a = extractScheme(a) orelse return false;
    const scheme_b = extractScheme(b) orelse return false;
    if (!std.mem.eql(u8, scheme_a, scheme_b)) return false;

    const host_a = ssrf_guard.extractHost(a) orelse return false;
    const host_b = ssrf_guard.extractHost(b) orelse return false;

    return std.ascii.eqlIgnoreCase(stripWww(host_a), stripWww(host_b));
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "extractScheme parses http/https/ws/wss case-insensitively" {
    try testing.expectEqualStrings("https", extractScheme("https://example.com/x").?);
    try testing.expectEqualStrings("http", extractScheme("http://example.com").?);
    try testing.expectEqualStrings("https", extractScheme("HTTPS://EXAMPLE.COM").?);
    try testing.expectEqualStrings("ws", extractScheme("ws://localhost:9000").?);
    try testing.expectEqualStrings("wss", extractScheme("wss://x.io").?);
    try testing.expect(extractScheme("ftp://example.com") == null);
    try testing.expect(extractScheme("example.com") == null);
}

test "sameHostModuloWww: example.com == www.example.com" {
    try testing.expect(sameHostModuloWww("https://example.com/a", "https://www.example.com/b"));
    try testing.expect(sameHostModuloWww("https://www.example.com", "https://example.com"));
    // case-insensitive host
    try testing.expect(sameHostModuloWww("https://Example.COM/a", "https://example.com/b"));
}

test "sameHostModuloWww: different hosts are not the same" {
    try testing.expect(!sameHostModuloWww("https://a.com/x", "https://b.com/y"));
    // www-stripping must not over-match: subdomain change is a host change
    try testing.expect(!sameHostModuloWww("https://docs.foo.com", "https://api.foo.com"));
}

test "sameHostModuloWww: scheme mismatch is not the same host" {
    try testing.expect(!sameHostModuloWww("http://example.com", "https://example.com"));
}

test "sameHostModuloWww: unparseable URL is treated as a host change" {
    try testing.expect(!sameHostModuloWww("https://example.com", "not a url"));
    try testing.expect(!sameHostModuloWww("garbage", "https://example.com"));
}
