const std = @import("std");

/// Preapproved hostnames for WebFetch, ported from
/// claude-code-main/src/tools/WebFetchTool/preapproved.ts. When the
/// model emits a WebFetch call against one of these hosts, the
/// policy classifier downgrades the risk tier from HIGH to LOW so
/// the call auto-approves without an interactive prompt. This is
/// the difference between a docs-heavy coding session flowing
/// smoothly versus the user having to hit "approve" on every
/// docs.python.org page the model wants to read.
///
/// SECURITY NOTE: this list is ONLY consulted by the WebFetch risk
/// classifier. It does NOT grant arbitrary network access, and it
/// does NOT apply to the sandbox's network-host allowlist. WebFetch
/// is a GET-only tool that returns text; the preapproved classification
/// is purely a UX shortcut for well-known documentation sources.
///
/// Some hosts like huggingface.co and kaggle.com allow file uploads
/// in other contexts, so they're documented in the reference as
/// "preapproved for WebFetch only, NOT for general network rules."
/// We inherit the same semantics.
///
/// Entries can be either bare hostnames ("react.dev") or
/// `host/path-prefix` for path-scoped entries (e.g.
/// "github.com/anthropics" so arbitrary github.com URLs still
/// require approval but github.com/anthropics/* does not).
pub const PREAPPROVED_ENTRIES = [_][]const u8{
    // Anthropic
    "platform.claude.com",
    "code.claude.com",
    "modelcontextprotocol.io",
    "github.com/anthropics",
    "agentskills.io",

    // Top programming languages
    "docs.python.org",
    "en.cppreference.com",
    "docs.oracle.com",
    "learn.microsoft.com",
    "developer.mozilla.org",
    "go.dev",
    "pkg.go.dev",
    "www.php.net",
    "docs.swift.org",
    "kotlinlang.org",
    "ruby-doc.org",
    "doc.rust-lang.org",
    "www.typescriptlang.org",
    "ziglang.org",
    "ziglearn.org",

    // Web & JavaScript frameworks / libraries
    "react.dev",
    "angular.io",
    "vuejs.org",
    "nextjs.org",
    "expressjs.com",
    "nodejs.org",
    "bun.sh",
    "jquery.com",
    "getbootstrap.com",
    "tailwindcss.com",
    "d3js.org",
    "threejs.org",
    "redux.js.org",
    "webpack.js.org",
    "jestjs.io",
    "reactrouter.com",

    // Python frameworks / libraries
    "docs.djangoproject.com",
    "flask.palletsprojects.com",
    "fastapi.tiangolo.com",
    "pandas.pydata.org",
    "numpy.org",
    "www.tensorflow.org",
    "pytorch.org",
    "scikit-learn.org",
    "matplotlib.org",
    "requests.readthedocs.io",
    "jupyter.org",

    // PHP frameworks
    "laravel.com",
    "symfony.com",
    "wordpress.org",

    // Java frameworks / libraries
    "docs.spring.io",
    "hibernate.org",
    "tomcat.apache.org",
    "gradle.org",
    "maven.apache.org",

    // .NET / C#
    "asp.net",
    "dotnet.microsoft.com",
    "nuget.org",
    "blazor.net",

    // Mobile development
    "reactnative.dev",
    "docs.flutter.dev",
    "developer.apple.com",
    "developer.android.com",

    // Data science / ML
    "keras.io",
    "spark.apache.org",
    "huggingface.co",
    "www.kaggle.com",

    // Databases
    "www.mongodb.com",
    "redis.io",
    "www.postgresql.org",
    "dev.mysql.com",
    "www.sqlite.org",
    "graphql.org",
    "prisma.io",

    // Cloud / DevOps
    "docs.aws.amazon.com",
    "cloud.google.com",
    "kubernetes.io",
    "www.docker.com",
    "www.terraform.io",
    "www.ansible.com",
    "vercel.com/docs",
    "docs.netlify.com",
    "devcenter.heroku.com",

    // Testing / monitoring
    "cypress.io",
    "selenium.dev",

    // Game development
    "docs.unity.com",
    "docs.unrealengine.com",

    // Essential tools
    "git-scm.com",
    "nginx.org",
    "httpd.apache.org",
};

/// Check whether `url` points to a preapproved host. Caller passes
/// a full URL (with or without scheme); we parse out the hostname
/// and path and match them against the PREAPPROVED_ENTRIES list.
///
/// Returns true when:
///   - The hostname matches a bare entry exactly, OR
///   - The entry is `host/prefix` and the URL's `hostname == host`
///     AND `path == prefix` or `path starts with prefix + '/'` so
///     "/anthropics" doesn't match "/anthropics-evil/malware"
///
/// Scheme is ignored -- http and https both work. Query strings
/// and fragments are stripped before comparison. The matcher is
/// case-insensitive on hostname per DNS semantics, case-sensitive
/// on path per HTTP semantics.
pub fn isPreapprovedUrl(url: []const u8) bool {
    const parsed = parseHostAndPath(url) orelse return false;
    return isPreapprovedHostAndPath(parsed.host, parsed.path);
}

/// Lower-level entry point. Caller already has the hostname and
/// path. Useful for tests and for callers that already parsed the
/// URL for some other reason.
pub fn isPreapprovedHostAndPath(host: []const u8, path: []const u8) bool {
    if (host.len == 0) return false;

    for (PREAPPROVED_ENTRIES) |entry| {
        const slash = std.mem.indexOfScalar(u8, entry, '/');
        if (slash) |idx| {
            // Path-scoped entry: must match host AND path prefix
            // exactly, with a path-segment boundary (either
            // equal or followed by '/').
            const entry_host = entry[0..idx];
            const entry_path = entry[idx..];
            if (!asciiEqlIgnoreCase(host, entry_host)) continue;
            if (std.mem.eql(u8, path, entry_path)) return true;
            if (std.mem.startsWith(u8, path, entry_path)) {
                const rest_start = entry_path.len;
                if (rest_start < path.len and path[rest_start] == '/') return true;
            }
        } else {
            if (asciiEqlIgnoreCase(host, entry)) return true;
        }
    }
    return false;
}

const ParsedUrl = struct {
    host: []const u8,
    path: []const u8,
};

/// Minimal URL parser that extracts the hostname and path from a
/// `scheme://host[:port]/path?query#fragment` string. Returns null
/// when the input is not a recognisable URL; returns the path as
/// "/" when the URL has no explicit path.
///
/// This is deliberately narrow: we only consume the fields we
/// need, we don't validate RFC 3986 exhaustively, and we don't
/// decode percent-escapes. Good enough for the preapproved-host
/// check where we just need host + leading path segment.
fn parseHostAndPath(url: []const u8) ?ParsedUrl {
    var rest: []const u8 = url;

    // Strip optional scheme
    if (std.mem.indexOf(u8, rest, "://")) |idx| {
        rest = rest[idx + 3 ..];
    }

    if (rest.len == 0) return null;

    // Authority ends at the first '/', '?', or '#'
    var authority_end: usize = rest.len;
    for (rest, 0..) |ch, idx| {
        if (ch == '/' or ch == '?' or ch == '#') {
            authority_end = idx;
            break;
        }
    }
    var authority = rest[0..authority_end];
    const after_auth = rest[authority_end..];

    // Drop optional userinfo
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at_idx| {
        authority = authority[at_idx + 1 ..];
    }

    // Drop optional port
    var host = authority;
    if (std.mem.lastIndexOfScalar(u8, host, ':')) |colon_idx| {
        host = host[0..colon_idx];
    }

    if (host.len == 0) return null;

    // Path is the segment up to '?' or '#'
    var path: []const u8 = "/";
    if (after_auth.len > 0 and after_auth[0] == '/') {
        var path_end: usize = after_auth.len;
        for (after_auth, 0..) |ch, idx| {
            if (ch == '?' or ch == '#') {
                path_end = idx;
                break;
            }
        }
        path = after_auth[0..path_end];
    }

    return .{ .host = host, .path = path };
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "parseHostAndPath extracts host and path from https URL" {
    const p = parseHostAndPath("https://docs.python.org/3/library/stdtypes.html").?;
    try testing.expectEqualStrings("docs.python.org", p.host);
    try testing.expectEqualStrings("/3/library/stdtypes.html", p.path);
}

test "parseHostAndPath handles http scheme" {
    const p = parseHostAndPath("http://example.com/foo").?;
    try testing.expectEqualStrings("example.com", p.host);
    try testing.expectEqualStrings("/foo", p.path);
}

test "parseHostAndPath handles URL with no path" {
    const p = parseHostAndPath("https://react.dev").?;
    try testing.expectEqualStrings("react.dev", p.host);
    try testing.expectEqualStrings("/", p.path);
}

test "parseHostAndPath strips port" {
    const p = parseHostAndPath("https://example.com:8080/api").?;
    try testing.expectEqualStrings("example.com", p.host);
    try testing.expectEqualStrings("/api", p.path);
}

test "parseHostAndPath strips query and fragment" {
    const p = parseHostAndPath("https://react.dev/learn?tab=hooks#intro").?;
    try testing.expectEqualStrings("react.dev", p.host);
    try testing.expectEqualStrings("/learn", p.path);
}

test "parseHostAndPath strips userinfo" {
    const p = parseHostAndPath("https://user:pass@example.com/foo").?;
    try testing.expectEqualStrings("example.com", p.host);
    try testing.expectEqualStrings("/foo", p.path);
}

test "parseHostAndPath rejects empty string" {
    try testing.expect(parseHostAndPath("") == null);
}

test "isPreapprovedUrl recognises bare hostname entries" {
    try testing.expect(isPreapprovedUrl("https://docs.python.org/3/tutorial/"));
    try testing.expect(isPreapprovedUrl("https://react.dev/learn"));
    try testing.expect(isPreapprovedUrl("https://developer.mozilla.org/en-US/docs/Web/JavaScript"));
    try testing.expect(isPreapprovedUrl("https://www.postgresql.org/docs/current/"));
}

test "isPreapprovedUrl is case-insensitive on hostname" {
    try testing.expect(isPreapprovedUrl("HTTPS://Docs.Python.ORG/3/"));
    try testing.expect(isPreapprovedUrl("https://REACT.DEV/"));
}

test "isPreapprovedUrl rejects random unknown host" {
    try testing.expect(!isPreapprovedUrl("https://evil.example.com/exfil"));
    try testing.expect(!isPreapprovedUrl("https://pastebin.com/raw/abc123"));
}

test "isPreapprovedUrl handles path-scoped github.com/anthropics entry" {
    try testing.expect(isPreapprovedUrl("https://github.com/anthropics/anthropic-sdk-python"));
    try testing.expect(isPreapprovedUrl("https://github.com/anthropics"));
    // Arbitrary github.com URLs must NOT be preapproved
    try testing.expect(!isPreapprovedUrl("https://github.com/other-org/repo"));
    try testing.expect(!isPreapprovedUrl("https://github.com/"));
}

test "isPreapprovedUrl path-scoped entry enforces segment boundary" {
    // /anthropics must not match /anthropics-evil/malware
    try testing.expect(!isPreapprovedUrl("https://github.com/anthropics-evil/malware"));
    try testing.expect(!isPreapprovedUrl("https://github.com/anthropicsX/repo"));
}

test "isPreapprovedUrl works without scheme" {
    try testing.expect(isPreapprovedUrl("docs.python.org/3/"));
    try testing.expect(isPreapprovedUrl("docs.python.org"));
}

test "isPreapprovedUrl includes ziglang.org (zcode-specific addition)" {
    // We extended the reference's list with ziglang.org and ziglearn.org
    // because zcode is a Zig project and its users hit those docs daily.
    try testing.expect(isPreapprovedUrl("https://ziglang.org/documentation/master/"));
    try testing.expect(isPreapprovedUrl("https://ziglearn.org/"));
}

test "isPreapprovedHostAndPath accepts well-known entries" {
    try testing.expect(isPreapprovedHostAndPath("nodejs.org", "/api/fs.html"));
    try testing.expect(isPreapprovedHostAndPath("learn.microsoft.com", "/en-us/azure/"));
    try testing.expect(isPreapprovedHostAndPath("pkg.go.dev", "/fmt"));
}

test "isPreapprovedHostAndPath rejects bare unknown host" {
    try testing.expect(!isPreapprovedHostAndPath("localhost", "/"));
    try testing.expect(!isPreapprovedHostAndPath("", "/"));
}

test "isPreapprovedUrl handles the classic docs-heavy session" {
    // Smoke test matching a real user session: fetching multiple
    // docs pages in sequence should auto-approve every one.
    const urls = [_][]const u8{
        "https://docs.python.org/3/library/asyncio.html",
        "https://react.dev/reference/react/useEffect",
        "https://pkg.go.dev/net/http",
        "https://developer.mozilla.org/en-US/docs/Web/API/fetch",
        "https://www.typescriptlang.org/docs/handbook/2/generics.html",
        "https://kubernetes.io/docs/concepts/workloads/controllers/deployment/",
        "https://docs.aws.amazon.com/lambda/latest/dg/welcome.html",
    };
    for (urls) |url| try testing.expect(isPreapprovedUrl(url));
}
