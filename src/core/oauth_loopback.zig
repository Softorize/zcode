//! Generic OAuth loopback primitives: PKCE, a one-shot 127.0.0.1 callback
//! listener, and the URL/browser plumbing around them.
//!
//! These started life inside `mcp/oauth.zig`, which needed them to log into MCP
//! servers. Provider login (`zcode login`) needs exactly the same pieces to run
//! an authorization-code flow against a model provider, so they live here and
//! both callers share one implementation rather than growing a second copy that
//! drifts.
//!
//! Nothing here knows what is being authorized. Callers supply the
//! authorization URL and decide what to do with the `code` that comes back.

const std = @import("std");
const std_io = @import("std_io.zig");
const rt = @import("zcode_runtime");
const rng = @import("rng.zig");

/// Loopback port the callback listener binds. Fixed rather than ephemeral
/// because OAuth providers require the redirect URI to be registered ahead of
/// time, and a registered URI cannot carry a port chosen at runtime.
pub const default_callback_port: u16 = 8765;

/// How long to wait for the browser round-trip before giving up. Generous: the
/// user may have to log in and clear an MFA prompt first.
pub const default_timeout_seconds: i32 = 120;

pub const Error = error{
    BrowserOpenFailed,
    CallbackTimeout,
    MissingQuery,
    HttpHeaderTooLarge,
    UnsupportedPlatform,
};

// --- PKCE (RFC 7636) ---------------------------------------------------

/// A PKCE verifier/challenge pair. The verifier stays on this machine; only the
/// challenge travels in the authorization URL, so an observer of that URL
/// cannot replay the eventual code.
pub const Pkce = struct {
    verifier: []u8,
    challenge: []u8,

    pub fn deinit(self: *Pkce, allocator: std.mem.Allocator) void {
        allocator.free(self.verifier);
        allocator.free(self.challenge);
    }
};

/// Generate a fresh S256 verifier/challenge pair. 32 random bytes is the
/// midpoint of RFC 7636's 43..128 character range once base64url-encoded.
pub fn generatePkce(allocator: std.mem.Allocator) !Pkce {
    const verifier = try randomUrlToken(allocator, 32);
    errdefer allocator.free(verifier);
    const challenge = try pkceChallenge(allocator, verifier);
    return .{ .verifier = verifier, .challenge = challenge };
}

pub fn pkceChallenge(allocator: std.mem.Allocator, verifier: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    return base64UrlNoPadAlloc(allocator, &digest);
}

pub fn randomUrlToken(allocator: std.mem.Allocator, byte_len: usize) ![]u8 {
    const bytes = try allocator.alloc(u8, byte_len);
    defer allocator.free(bytes);
    rng.secureBytes(bytes);
    return base64UrlNoPadAlloc(allocator, bytes);
}

pub fn base64UrlNoPadAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoded_len = std.base64.url_safe.Encoder.calcSize(bytes.len);
    const buf = try allocator.alloc(u8, encoded_len);
    errdefer allocator.free(buf);
    const written = std.base64.url_safe.Encoder.encode(buf, bytes);
    var unpadded_len = written.len;
    while (unpadded_len > 0 and buf[unpadded_len - 1] == '=') unpadded_len -= 1;
    return allocator.realloc(buf, unpadded_len);
}

// --- URL helpers -------------------------------------------------------

pub fn urlEncodeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    for (input) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try out.append(ch);
        } else {
            try out.writer().print("%{X:0>2}", .{ch});
        }
    }
    return out.toOwnedSlice();
}

pub fn percentDecodeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = std.fmt.charToDigit(input[i + 1], 16) catch {
                try out.append(input[i]);
                continue;
            };
            const lo = std.fmt.charToDigit(input[i + 2], 16) catch {
                try out.append(input[i]);
                continue;
            };
            try out.append(@as(u8, @intCast((hi << 4) | lo)));
            i += 2;
            continue;
        }
        if (input[i] == '+') {
            try out.append(' ');
            continue;
        }
        try out.append(input[i]);
    }

    return out.toOwnedSlice();
}

/// The redirect URI this module's listener serves. Callers must send the same
/// string to the provider, since OAuth requires the redirect_uri at the token
/// exchange to match the one used at authorization byte for byte.
pub fn callbackUrlAlloc(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/callback", .{default_callback_port});
}

pub fn openBrowserUrl(allocator: std.mem.Allocator, url: []const u8) !void {
    const argv = switch (@import("builtin").os.tag) {
        .macos => [_][]const u8{ "open", url },
        .linux => [_][]const u8{ "xdg-open", url },
        .windows => [_][]const u8{ "rundll32", "url.dll,FileProtocolHandler", url },
        else => return Error.UnsupportedPlatform,
    };
    const result = try std.process.run(allocator, rt.io, .{
        .argv = &argv,
        .stdout_limit = .limited(8 * 1024),
        .stderr_limit = .limited(8 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!(result.term == .exited and result.term.exited == 0)) return Error.BrowserOpenFailed;
}

// --- Loopback callback listener ----------------------------------------

/// The query string a provider redirected back with, plus the live connection
/// so the caller can decide what the user's browser tab should say.
pub const Callback = struct {
    request: []u8,
    stream: std.Io.net.Stream,
    allocator: std.mem.Allocator,

    /// Raw query string (everything after `?`), or null if the redirect had none.
    pub fn query(self: Callback) ?[]const u8 {
        return requestQuery(self.request);
    }

    /// Look up one query parameter, still percent-encoded.
    pub fn param(self: Callback, key: []const u8) ?[]const u8 {
        const q = self.query() orelse return null;
        return getQueryParam(q, key);
    }

    /// Look up one query parameter and percent-decode it. Caller owns the result.
    pub fn paramDecoded(self: Callback, key: []const u8) !?[]u8 {
        const raw = self.param(key) orelse return null;
        return try percentDecodeAlloc(self.allocator, raw);
    }

    /// Send the closing page the user sees in their browser, then hang up.
    pub fn respond(self: *Callback, body: []const u8) void {
        writeHttpResponse(self.stream, body) catch {};
    }

    pub fn deinit(self: *Callback) void {
        self.stream.close(rt.io);
        self.allocator.free(self.request);
    }
};

/// Bind the loopback callback port, open `auth_url` in the user's browser, and
/// block until the provider redirects back (or `default_timeout_seconds`
/// elapses). The listener is bound BEFORE the browser opens so a fast redirect
/// cannot arrive at a closed port.
pub fn awaitCallback(allocator: std.mem.Allocator, auth_url: []const u8) !Callback {
    const addr: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = default_callback_port } };
    var server = try addr.listen(rt.io, .{ .reuse_address = true });
    defer server.deinit(rt.io);

    try openBrowserUrl(allocator, auth_url);

    const stream = try acceptWithTimeout(&server, default_timeout_seconds * 1000);
    errdefer stream.close(rt.io);

    const request = try readHttpRequest(allocator, stream);
    return .{ .request = request, .stream = stream, .allocator = allocator };
}

pub fn acceptWithTimeout(server: *std.Io.net.Server, timeout_ms: i32) !std.Io.net.Stream {
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = server.socket.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try std.posix.poll(&poll_fds, timeout_ms);
    if (ready <= 0) return Error.CallbackTimeout;
    return server.accept(rt.io);
}

pub fn readHttpRequest(allocator: std.mem.Allocator, stream: std.Io.net.Stream) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    var buf: [1024]u8 = undefined;
    while (true) {
        const n = try std_io.streamRead(stream, &buf);
        if (n == 0) break;
        try out.appendSlice(buf[0..n]);
        if (std.mem.indexOf(u8, out.items(), "\r\n\r\n") != null) break;
        if (out.items().len > 16 * 1024) return Error.HttpHeaderTooLarge;
    }
    return out.toOwnedSlice();
}

pub fn requestQuery(request: []const u8) ?[]const u8 {
    const first_line_end = std.mem.indexOf(u8, request, "\r\n") orelse request.len;
    const first_line = request[0..first_line_end];
    const first_space = std.mem.indexOfScalar(u8, first_line, ' ') orelse return null;
    const second_space = std.mem.lastIndexOfScalar(u8, first_line, ' ') orelse return null;
    if (second_space <= first_space) return null;
    const target = first_line[first_space + 1 .. second_space];
    const query_idx = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    return target[query_idx + 1 ..];
}

pub fn getQueryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

pub fn writeHttpResponse(stream: std.Io.net.Stream, body: []const u8) !void {
    var header: [256]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&header, "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len});
    try std_io.streamWriteAll(stream, prefix);
    try std_io.streamWriteAll(stream, body);
}

// --- tests -------------------------------------------------------------

const testing = std.testing;

test "PKCE challenge is the base64url-nopad SHA-256 of the verifier" {
    // RFC 7636 appendix B's worked example. Pinning it catches a swap to plain
    // base64 (which would emit '+' / '/' and break the URL) or a stray '='.
    const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
    const challenge = try pkceChallenge(testing.allocator, verifier);
    defer testing.allocator.free(challenge);
    try testing.expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", challenge);
}

test "generatePkce produces a distinct pair each call" {
    var a = try generatePkce(testing.allocator);
    defer a.deinit(testing.allocator);
    var b = try generatePkce(testing.allocator);
    defer b.deinit(testing.allocator);

    try testing.expect(!std.mem.eql(u8, a.verifier, b.verifier));
    try testing.expect(!std.mem.eql(u8, a.challenge, b.challenge));
    // 32 bytes -> 43 base64url chars, inside RFC 7636's 43..128 range.
    try testing.expectEqual(@as(usize, 43), a.verifier.len);
}

test "base64url encoding is unpadded and URL-safe" {
    // 0xFB 0xFF encodes to "+/8=" in standard base64; url_safe must give "-_8"
    // with the padding stripped, or the value corrupts inside a query string.
    const out = try base64UrlNoPadAlloc(testing.allocator, &[_]u8{ 0xFB, 0xFF });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("-_8", out);
}

test "requestQuery extracts the query from a redirect GET" {
    const req = "GET /callback?code=abc123&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
    const q = requestQuery(req) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("code=abc123&state=xyz", q);
    try testing.expectEqualStrings("abc123", getQueryParam(q, "code").?);
    try testing.expectEqualStrings("xyz", getQueryParam(q, "state").?);
    try testing.expect(getQueryParam(q, "absent") == null);
}

test "requestQuery returns null when the redirect carries no query" {
    try testing.expect(requestQuery("GET /callback HTTP/1.1\r\n\r\n") == null);
}

test "percent decoding round-trips a url-encoded value" {
    const original = "a b&c=d/e?f";
    const encoded = try urlEncodeAlloc(testing.allocator, original);
    defer testing.allocator.free(encoded);
    // Every reserved character must have been escaped.
    try testing.expect(std.mem.indexOfScalar(u8, encoded, ' ') == null);
    try testing.expect(std.mem.indexOfScalar(u8, encoded, '&') == null);

    const decoded = try percentDecodeAlloc(testing.allocator, encoded);
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings(original, decoded);
}

test "callback url matches the port the listener binds" {
    // These must not drift apart: OAuth compares the redirect_uri at the token
    // exchange against the one used at authorization, byte for byte.
    const url = try callbackUrlAlloc(testing.allocator);
    defer testing.allocator.free(url);
    var buf: [64]u8 = undefined;
    const expected = try std.fmt.bufPrint(&buf, "http://127.0.0.1:{d}/callback", .{default_callback_port});
    try testing.expectEqualStrings(expected, url);
}
