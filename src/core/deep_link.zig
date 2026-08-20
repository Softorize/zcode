//! claude-cli:// deep-link URI parser and builder (misc-utils-06).
//!
//! Ported from claude-code-main/src/utils/parseDeepLink.ts:84-170.
//!
//! A deep link looks like:
//!
//!   claude-cli://open?q=hello+world&cwd=/abs/path&repo=owner/repo
//!
//! Only the `open` host is recognized. The query string carries up to
//! three values:
//!   q    - a free-text prompt to prefill (percent-decoded, unicode-
//!          sanitized, length-capped, control-char rejected)
//!   cwd  - an absolute working directory to switch into
//!   repo - an `owner/repo` slug to clone/open
//!
//! Sanitization mirrors the reference: percent-decode, strip dangerous
//! unicode (via core/unicode_sanitize.zig), reject ASCII control chars
//! (0x00-0x1F and 0x7F), enforce the length caps, require cwd to be an
//! absolute path, and require repo to match `[\w.-]+/[\w.-]+`.
//!
//! This parser is PURE: it does no filesystem or config access. Repo
//! resolution and the actual `open` action happen at the consumer. The
//! rest of the deep-link subsystem (OS protocol-handler registration and
//! the headless terminal launch -- misc-utils-07/08/10) is deferred; this
//! parser is the in-scope core and is independently useful.

const std = @import("std");
const std_io = @import("std_io.zig");
const unicode_sanitize = @import("unicode_sanitize.zig");

/// Caps mirror the reference (parseDeepLink.ts).
pub const MAX_QUERY_LENGTH: usize = 5000;
pub const MAX_CWD_LENGTH: usize = 4096;

pub const ParseError = error{
    /// The URI did not start with `claude-cli://open`.
    InvalidScheme,
    /// The query value contained an ASCII control character (0x00-0x1F or 0x7F).
    ControlCharacter,
    /// The query (`q`) value exceeded MAX_QUERY_LENGTH after decoding.
    QueryTooLong,
    /// The cwd value exceeded MAX_CWD_LENGTH after decoding.
    CwdTooLong,
    /// The cwd value was not an absolute path.
    CwdNotAbsolute,
    /// The repo value was not an `owner/repo` slug.
    InvalidRepo,
} || std.mem.Allocator.Error;

/// The result of parsing a deep link. All fields are optional and owned
/// by the caller; free each non-null field with the same allocator
/// passed to `parseDeepLink`, or call `deinit`.
pub const DeepLinkAction = struct {
    query: ?[]u8 = null,
    cwd: ?[]u8 = null,
    repo: ?[]u8 = null,

    pub fn deinit(self: *DeepLinkAction, allocator: std.mem.Allocator) void {
        if (self.query) |q| allocator.free(q);
        if (self.cwd) |c| allocator.free(c);
        if (self.repo) |r| allocator.free(r);
        self.* = .{};
    }
};

const SCHEME_HOST = "claude-cli://open";

/// Parse a `claude-cli://open?...` URI. Returns an owned DeepLinkAction.
/// On any validation failure the partially-built action is freed before
/// returning the error, so the caller never has to clean up on error.
pub fn parseDeepLink(allocator: std.mem.Allocator, uri: []const u8) !DeepLinkAction {
    // Require the exact scheme + host. The query string (if any) begins
    // after a `?`. A bare `claude-cli://open` with no query is valid and
    // yields an empty action.
    if (!std.mem.startsWith(u8, uri, SCHEME_HOST)) return error.InvalidScheme;

    const rest = uri[SCHEME_HOST.len..];
    var query_str: []const u8 = "";
    if (rest.len > 0) {
        if (rest[0] == '?') {
            query_str = rest[1..];
        } else if (rest[0] == '/' and rest.len > 1 and rest[1] == '?') {
            // Tolerate `claude-cli://open/?...` (trailing slash on host).
            query_str = rest[2..];
        } else {
            return error.InvalidScheme;
        }
    }

    var action = DeepLinkAction{};
    errdefer action.deinit(allocator);

    var it = std.mem.splitScalar(u8, query_str, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq];
        const raw_value = pair[eq + 1 ..];

        if (std.mem.eql(u8, key, "q")) {
            if (action.query) |old| allocator.free(old);
            action.query = try decodeQueryValue(allocator, raw_value);
        } else if (std.mem.eql(u8, key, "cwd")) {
            if (action.cwd) |old| allocator.free(old);
            action.cwd = try decodeCwdValue(allocator, raw_value);
        } else if (std.mem.eql(u8, key, "repo")) {
            if (action.repo) |old| allocator.free(old);
            action.repo = try decodeRepoValue(allocator, raw_value);
        }
        // Unknown keys are ignored (forward-compatible).
    }

    return action;
}

/// Decode + sanitize the `q` value: percent-decode, strip dangerous
/// unicode, reject ASCII control chars, enforce the query length cap.
fn decodeQueryValue(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const decoded = try percentDecodeAlloc(allocator, raw);
    defer allocator.free(decoded);

    const sanitized = try unicode_sanitize.stripDangerousUnicode(allocator, decoded);
    errdefer allocator.free(sanitized);

    if (containsAsciiControl(sanitized)) return error.ControlCharacter;
    if (sanitized.len > MAX_QUERY_LENGTH) return error.QueryTooLong;

    return sanitized;
}

/// Decode + validate the `cwd` value: percent-decode, reject control
/// chars, enforce the cwd length cap, require an absolute path.
fn decodeCwdValue(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const decoded = try percentDecodeAlloc(allocator, raw);
    errdefer allocator.free(decoded);

    if (containsAsciiControl(decoded)) return error.ControlCharacter;
    if (decoded.len > MAX_CWD_LENGTH) return error.CwdTooLong;
    if (!isAbsolutePath(decoded)) return error.CwdNotAbsolute;

    return decoded;
}

/// Decode + validate the `repo` value: percent-decode then require an
/// `owner/repo` slug. (No length cap in the reference for repo.)
fn decodeRepoValue(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const decoded = try percentDecodeAlloc(allocator, raw);
    errdefer allocator.free(decoded);

    if (containsAsciiControl(decoded)) return error.ControlCharacter;
    if (!isRepoSlug(decoded)) return error.InvalidRepo;

    return decoded;
}

/// Build the inverse of `parseDeepLink`: a `claude-cli://open?...` URI
/// from a DeepLinkAction. Only non-null fields are emitted, in a stable
/// order (q, cwd, repo) so build->parse round-trips. Returns an owned
/// slice.
pub fn buildDeepLink(allocator: std.mem.Allocator, action: DeepLinkAction) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    try out.appendSlice(SCHEME_HOST);

    var first = true;
    if (action.query) |q| {
        try out.append(if (first) '?' else '&');
        first = false;
        try out.appendSlice("q=");
        try urlEncode(&out, q);
    }
    if (action.cwd) |c| {
        try out.append(if (first) '?' else '&');
        first = false;
        try out.appendSlice("cwd=");
        try urlEncode(&out, c);
    }
    if (action.repo) |r| {
        try out.append(if (first) '?' else '&');
        first = false;
        try out.appendSlice("repo=");
        try urlEncode(&out, r);
    }

    return out.toOwnedSlice();
}

// ── Primitives ────────────────────────────────────────────────────

/// Percent-decode a URL-encoded value. `+` maps to space (form encoding),
/// `%XX` maps to the byte. A malformed `%` escape is left verbatim. Mirrors
/// the oauth.zig percentDecodeAlloc convention (kept private there).
fn percentDecodeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
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

/// Percent-encode a value into `out`. Unreserved characters (RFC 3986)
/// pass through; everything else becomes `%XX`. A space becomes `%20`
/// (not `+`) so that round-tripped values are unambiguous.
fn urlEncode(out: *std_io.StringBuilder, input: []const u8) !void {
    for (input) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~' or ch == '/') {
            try out.append(ch);
        } else {
            try out.writer().print("%{X:0>2}", .{ch});
        }
    }
}

/// True when the slice contains any ASCII control character: 0x00-0x1F or
/// 0x7F (DEL). Mirrors the reference's control-char rejection.
fn containsAsciiControl(s: []const u8) bool {
    for (s) |b| {
        if (b < 0x20 or b == 0x7F) return true;
    }
    return false;
}

/// True for a POSIX absolute path (`/...`) or a Windows drive path
/// (`X:\...` or `X:/...`). Mirrors the reference's `isAbsolute` check.
fn isAbsolutePath(p: []const u8) bool {
    if (p.len == 0) return false;
    if (p[0] == '/') return true;
    // Windows drive: a letter, a colon, then a slash or backslash.
    if (p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and (p[2] == '\\' or p[2] == '/')) {
        return true;
    }
    return false;
}

/// True when `s` matches `^[\w.-]+/[\w.-]+$` -- exactly one `/`, with
/// non-empty `[A-Za-z0-9_.-]` components on each side. Mirrors the
/// reference repo-slug check, with an added guard: a pure-dot component
/// (`.` / `..`) is rejected so `repo=../x` cannot smuggle path traversal.
fn isRepoSlug(s: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, s, '/') orelse return false;
    const owner = s[0..slash];
    const name = s[slash + 1 ..];
    if (owner.len == 0 or name.len == 0) return false;
    // Reject a second slash (one `/` only).
    if (std.mem.indexOfScalar(u8, name, '/') != null) return false;
    return isSlugComponent(owner) and isSlugComponent(name);
}

fn isSlugComponent(c: []const u8) bool {
    var all_dots = true;
    for (c) |ch| {
        const ok = std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.' or ch == '-';
        if (!ok) return false;
        if (ch != '.') all_dots = false;
    }
    // Reject pure-dot components (`.`, `..`, ...) to block path traversal:
    // `repo=../x` must not pass even though the chars are individually legal.
    return !all_dots;
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "parseDeepLink decodes q with plus-space" {
    var action = try parseDeepLink(testing.allocator, "claude-cli://open?q=hello+world");
    defer action.deinit(testing.allocator);
    try testing.expect(action.query != null);
    try testing.expectEqualStrings("hello world", action.query.?);
    try testing.expect(action.cwd == null);
    try testing.expect(action.repo == null);
}

test "parseDeepLink decodes percent-encoded q" {
    var action = try parseDeepLink(testing.allocator, "claude-cli://open?q=a%20b%2Fc");
    defer action.deinit(testing.allocator);
    try testing.expectEqualStrings("a b/c", action.query.?);
}

test "parseDeepLink rejects non-scheme" {
    try testing.expectError(error.InvalidScheme, parseDeepLink(testing.allocator, "https://example.com/open?q=x"));
    try testing.expectError(error.InvalidScheme, parseDeepLink(testing.allocator, "claude-cli://close?q=x"));
}

test "parseDeepLink accepts bare open with no query" {
    var action = try parseDeepLink(testing.allocator, "claude-cli://open");
    defer action.deinit(testing.allocator);
    try testing.expect(action.query == null);
    try testing.expect(action.cwd == null);
    try testing.expect(action.repo == null);
}

test "parseDeepLink rejects ASCII control char in q" {
    // %01 decodes to a control byte.
    try testing.expectError(error.ControlCharacter, parseDeepLink(testing.allocator, "claude-cli://open?q=a%01b"));
}

test "parseDeepLink rejects q over MAX_QUERY_LENGTH" {
    const long = "x" ** (MAX_QUERY_LENGTH + 1);
    const uri = "claude-cli://open?q=" ++ long;
    try testing.expectError(error.QueryTooLong, parseDeepLink(testing.allocator, uri));
}

test "parseDeepLink accepts q at exactly MAX_QUERY_LENGTH" {
    const exact = "x" ** MAX_QUERY_LENGTH;
    const uri = "claude-cli://open?q=" ++ exact;
    var action = try parseDeepLink(testing.allocator, uri);
    defer action.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, MAX_QUERY_LENGTH), action.query.?.len);
}

test "parseDeepLink requires cwd to be absolute" {
    try testing.expectError(error.CwdNotAbsolute, parseDeepLink(testing.allocator, "claude-cli://open?cwd=relative%2Fpath"));
    var action = try parseDeepLink(testing.allocator, "claude-cli://open?cwd=%2Fabs%2Fpath");
    defer action.deinit(testing.allocator);
    try testing.expectEqualStrings("/abs/path", action.cwd.?);
}

test "parseDeepLink accepts windows drive cwd" {
    var action = try parseDeepLink(testing.allocator, "claude-cli://open?cwd=C%3A%5Cwork");
    defer action.deinit(testing.allocator);
    try testing.expectEqualStrings("C:\\work", action.cwd.?);
}

test "parseDeepLink rejects cwd over MAX_CWD_LENGTH" {
    const long = "/" ++ ("x" ** MAX_CWD_LENGTH);
    const uri = "claude-cli://open?cwd=" ++ long;
    try testing.expectError(error.CwdTooLong, parseDeepLink(testing.allocator, uri));
}

test "parseDeepLink validates repo slug" {
    var action = try parseDeepLink(testing.allocator, "claude-cli://open?repo=owner%2Frepo");
    defer action.deinit(testing.allocator);
    try testing.expectEqualStrings("owner/repo", action.repo.?);

    try testing.expectError(error.InvalidRepo, parseDeepLink(testing.allocator, "claude-cli://open?repo=..%2Fx"));
    try testing.expectError(error.InvalidRepo, parseDeepLink(testing.allocator, "claude-cli://open?repo=nopath"));
    try testing.expectError(error.InvalidRepo, parseDeepLink(testing.allocator, "claude-cli://open?repo=a%2Fb%2Fc"));
}

test "parseDeepLink rejects repo with disallowed chars" {
    try testing.expectError(error.InvalidRepo, parseDeepLink(testing.allocator, "claude-cli://open?repo=ow%20ner%2Frepo"));
}

test "parseDeepLink parses all three fields" {
    var action = try parseDeepLink(testing.allocator, "claude-cli://open?q=fix+bug&cwd=%2Fhome%2Fme&repo=acme%2Fwidget");
    defer action.deinit(testing.allocator);
    try testing.expectEqualStrings("fix bug", action.query.?);
    try testing.expectEqualStrings("/home/me", action.cwd.?);
    try testing.expectEqualStrings("acme/widget", action.repo.?);
}

test "parseDeepLink tolerates trailing slash on host" {
    var action = try parseDeepLink(testing.allocator, "claude-cli://open/?q=hi");
    defer action.deinit(testing.allocator);
    try testing.expectEqualStrings("hi", action.query.?);
}

test "buildDeepLink round-trips through parseDeepLink" {
    const original = DeepLinkAction{
        .query = @constCast("hello world & more"),
        .cwd = @constCast("/home/me/project"),
        .repo = @constCast("acme/widget"),
    };
    const built = try buildDeepLink(testing.allocator, original);
    defer testing.allocator.free(built);

    var parsed = try parseDeepLink(testing.allocator, built);
    defer parsed.deinit(testing.allocator);

    try testing.expectEqualStrings("hello world & more", parsed.query.?);
    try testing.expectEqualStrings("/home/me/project", parsed.cwd.?);
    try testing.expectEqualStrings("acme/widget", parsed.repo.?);
}

test "buildDeepLink emits only non-null fields" {
    const only_q = DeepLinkAction{ .query = @constCast("x") };
    const built = try buildDeepLink(testing.allocator, only_q);
    defer testing.allocator.free(built);
    try testing.expectEqualStrings("claude-cli://open?q=x", built);

    const empty = DeepLinkAction{};
    const built_empty = try buildDeepLink(testing.allocator, empty);
    defer testing.allocator.free(built_empty);
    try testing.expectEqualStrings("claude-cli://open", built_empty);
}

test "buildDeepLink strips dangerous unicode on reparse" {
    // The builder encodes a zero-width space; parse must strip it so the
    // round-tripped query is clean.
    const zwsp = "a\xe2\x80\x8bb";
    const action = DeepLinkAction{ .query = @constCast(zwsp) };
    const built = try buildDeepLink(testing.allocator, action);
    defer testing.allocator.free(built);

    var parsed = try parseDeepLink(testing.allocator, built);
    defer parsed.deinit(testing.allocator);
    try testing.expectEqualStrings("ab", parsed.query.?);
}
