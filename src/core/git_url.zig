const std = @import("std");

/// Git remote URL helpers ported from claude-code-main/src/utils/git.ts
/// `normalizeGitRemoteUrl`. Single source of truth for "given a git
/// remote URL, return canonical bytes" so every caller (PR opener,
/// telemetry, repo-id hashing) sees the same identifier regardless of
/// SSH/HTTPS clone style.
///
/// Three input forms are accepted:
///   - SSH shorthand:  git@host:owner/repo[.git]
///   - HTTPS URL:      https://[user@]host/owner/repo[.git]
///   - SSH URL:        ssh://git@host/owner/repo[.git]
///
/// All three normalize to the same output: lowercase "host/owner/repo"
/// (no scheme, no `.git` suffix). Returns null for unrecognised forms
/// so callers can fall back to a sensible default rather than guessing.
/// Normalize a git remote URL to canonical "host/owner/repo" bytes.
/// Caller owns the returned slice.
pub fn normalize(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (parseSshShorthand(trimmed)) |parts| {
        return try renderHostPath(allocator, parts.host, parts.path);
    }
    if (parseSchemeUrl(trimmed)) |parts| {
        return try renderHostPath(allocator, parts.host, parts.path);
    }
    return null;
}

/// Render the canonical form as an HTTPS URL with scheme. Useful for
/// callers that want to hand the result to `gh` or open it in a
/// browser. Returns null on unrecognised input.
pub fn toHttpsUrl(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
    const canonical = (try normalize(allocator, raw)) orelse return null;
    defer allocator.free(canonical);
    return try std.fmt.allocPrint(allocator, "https://{s}", .{canonical});
}

/// Structured three-way split of a git remote: host, owner, repo
/// name. Complement to `normalize` which returns the three joined
/// by slashes; this version is friendlier when the caller wants to
/// construct a host-specific URL (e.g. a GitHub API endpoint) and
/// needs the three parts independently.
///
/// Ported from claude-code-main/src/utils/detectRepository.ts
/// parseGitRemote, which returns the same three fields under the
/// same constraints (reject SSH aliases via looksLikeRealHostname).
pub const ParsedRepo = struct {
    host: []const u8,
    owner: []const u8,
    repo: []const u8,
};

/// Parse a git remote URL into (host, owner, repo). Returns null
/// when the URL is not in a recognised form or when the host looks
/// like an SSH config alias rather than a real hostname (matches
/// the reference's looksLikeRealHostname filter so GitHub remotes
/// cloned via an `~/.ssh/config` alias like `git@github.com-work`
/// are rejected cleanly instead of producing a garbage host).
///
/// All three fields are lowercased slices into `raw` so the caller
/// doesn't need to free anything. The slices stay valid as long as
/// `raw` is alive -- duplicate them if you need to retain the parts
/// past `raw`'s lifetime.
pub fn parseParts(raw: []const u8) ?ParsedRepo {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;

    var host: []const u8 = "";
    var path: []const u8 = "";

    if (parseSshShorthand(trimmed)) |parts| {
        host = parts.host;
        path = parts.path;
    } else if (parseSchemeUrl(trimmed)) |parts| {
        host = parts.host;
        path = parts.path;
    } else {
        return null;
    }

    if (!looksLikeRealHostname(host)) return null;

    // Strip trailing slash and `.git` suffix from the path.
    var clean_path = std.mem.trimEnd(u8, path, "/");
    if (std.mem.endsWith(u8, clean_path, ".git")) {
        clean_path = clean_path[0 .. clean_path.len - ".git".len];
    }
    // The path must be `owner/repo` (exactly one slash separating
    // the two segments). Nested groups (GitLab subgroups) are not
    // supported by this helper -- use `normalize` for the flat
    // canonical form when you need them.
    const sep = std.mem.indexOfScalar(u8, clean_path, '/') orelse return null;
    const owner = clean_path[0..sep];
    const repo = clean_path[sep + 1 ..];
    if (owner.len == 0 or repo.len == 0) return null;
    // Reject paths with more than one slash so we only return clean
    // owner/repo pairs.
    if (std.mem.indexOfScalar(u8, repo, '/') != null) return null;

    return .{
        .host = host,
        .owner = owner,
        .repo = repo,
    };
}

/// Return true when `host` looks like a real hostname rather than
/// an `~/.ssh/config` alias. Matches the reference's
/// looksLikeRealHostname filter: the last segment (TLD) must be
/// purely alphabetic. `github.com` passes; `github.com-work`
/// (alias pattern) fails because the last segment contains a hyphen.
fn looksLikeRealHostname(host: []const u8) bool {
    if (std.mem.indexOfScalar(u8, host, '.') == null) return false;
    const last_dot = std.mem.lastIndexOfScalar(u8, host, '.') orelse return false;
    const tld = host[last_dot + 1 ..];
    if (tld.len == 0) return false;
    for (tld) |c| {
        if (!std.ascii.isAlphabetic(c)) return false;
    }
    return true;
}

const HostPath = struct {
    host: []const u8,
    path: []const u8,
};

/// Match `git@host:owner/repo[.git]`. Returns null if the colon is
/// missing or the host/path is empty.
fn parseSshShorthand(s: []const u8) ?HostPath {
    if (!std.mem.startsWith(u8, s, "git@")) return null;
    const after_user = s["git@".len..];
    const colon = std.mem.indexOfScalar(u8, after_user, ':') orelse return null;
    const host = after_user[0..colon];
    const path = after_user[colon + 1 ..];
    if (host.len == 0 or path.len == 0) return null;
    // SSH shorthand cannot contain a slash in the host segment -- if
    // we see one, it's actually an https path mistakenly lacking a
    // scheme and the parseSchemeUrl path will not match either.
    if (std.mem.indexOfScalar(u8, host, '/') != null) return null;
    return .{ .host = host, .path = path };
}

/// Match `https://...`, `http://...`, or `ssh://...`. Strips the
/// optional `user@` prefix from the authority before extracting the
/// host. Returns null on missing scheme or empty authority/path.
fn parseSchemeUrl(s: []const u8) ?HostPath {
    var rest: []const u8 = s;
    if (std.mem.startsWith(u8, rest, "https://")) {
        rest = rest["https://".len..];
    } else if (std.mem.startsWith(u8, rest, "http://")) {
        rest = rest["http://".len..];
    } else if (std.mem.startsWith(u8, rest, "ssh://")) {
        rest = rest["ssh://".len..];
    } else {
        return null;
    }

    // Strip optional `user@` from the authority. Anything before the
    // last '@' that comes BEFORE the first '/' is auth.
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const authority = rest[0..slash];
    const path_part = rest[slash + 1 ..];
    if (authority.len == 0 or path_part.len == 0) return null;

    const at = std.mem.lastIndexOfScalar(u8, authority, '@');
    const host = if (at) |idx| authority[idx + 1 ..] else authority;
    if (host.len == 0) return null;

    return .{ .host = host, .path = path_part };
}

fn renderHostPath(allocator: std.mem.Allocator, host: []const u8, raw_path: []const u8) ![]u8 {
    // Strip trailing slashes and a trailing `.git` suffix, matching
    // the reference's regex group `(?:\.git)?$`.
    var path = std.mem.trimEnd(u8, raw_path, "/");
    if (std.mem.endsWith(u8, path, ".git")) {
        path = path[0 .. path.len - ".git".len];
    }

    const out = try allocator.alloc(u8, host.len + 1 + path.len);
    var i: usize = 0;
    for (host) |c| {
        out[i] = std.ascii.toLower(c);
        i += 1;
    }
    out[i] = '/';
    i += 1;
    for (path) |c| {
        out[i] = std.ascii.toLower(c);
        i += 1;
    }
    return out;
}

const testing = std.testing;

test "normalize handles ssh shorthand with .git suffix" {
    const got = (try normalize(testing.allocator, "git@github.com:owner/repo.git")).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("github.com/owner/repo", got);
}

test "normalize handles ssh shorthand without .git suffix" {
    const got = (try normalize(testing.allocator, "git@github.com:owner/repo")).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("github.com/owner/repo", got);
}

test "normalize handles https URL with .git suffix" {
    const got = (try normalize(testing.allocator, "https://github.com/owner/repo.git")).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("github.com/owner/repo", got);
}

test "normalize handles https URL with auth" {
    const got = (try normalize(testing.allocator, "https://user:token@gitlab.example.com/owner/repo.git")).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("gitlab.example.com/owner/repo", got);
}

test "normalize handles ssh URL form" {
    const got = (try normalize(testing.allocator, "ssh://git@github.com/owner/repo.git")).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("github.com/owner/repo", got);
}

test "normalize lowercases host and path" {
    const got = (try normalize(testing.allocator, "git@GitHub.com:Owner/Repo.git")).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("github.com/owner/repo", got);
}

test "normalize strips trailing slash" {
    const got = (try normalize(testing.allocator, "https://github.com/owner/repo/")).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("github.com/owner/repo", got);
}

test "normalize handles nested groups (e.g. GitLab subgroups)" {
    const got = (try normalize(testing.allocator, "https://gitlab.com/group/subgroup/repo.git")).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("gitlab.com/group/subgroup/repo", got);
}

test "normalize returns null on unrecognised input" {
    try testing.expectEqual(@as(?[]u8, null), try normalize(testing.allocator, ""));
    try testing.expectEqual(@as(?[]u8, null), try normalize(testing.allocator, "not a url"));
    try testing.expectEqual(@as(?[]u8, null), try normalize(testing.allocator, "ftp://example.com/foo/bar"));
    try testing.expectEqual(@as(?[]u8, null), try normalize(testing.allocator, "git@github.com"));
}

test "toHttpsUrl re-prefixes the canonical form" {
    const got = (try toHttpsUrl(testing.allocator, "git@github.com:owner/repo.git")).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("https://github.com/owner/repo", got);
}

test "toHttpsUrl returns null on unrecognised input" {
    try testing.expectEqual(@as(?[]u8, null), try toHttpsUrl(testing.allocator, "not-a-url"));
}

test "parseParts extracts host / owner / repo from SSH shorthand" {
    const p = parseParts("git@github.com:owner/repo.git").?;
    try testing.expectEqualStrings("github.com", p.host);
    try testing.expectEqualStrings("owner", p.owner);
    try testing.expectEqualStrings("repo", p.repo);
}

test "parseParts handles https URL with and without .git" {
    const p1 = parseParts("https://github.com/octocat/hello-world.git").?;
    try testing.expectEqualStrings("github.com", p1.host);
    try testing.expectEqualStrings("octocat", p1.owner);
    try testing.expectEqualStrings("hello-world", p1.repo);

    const p2 = parseParts("https://github.com/octocat/hello-world").?;
    try testing.expectEqualStrings("hello-world", p2.repo);
}

test "parseParts handles ssh:// URL form" {
    const p = parseParts("ssh://git@github.com/owner/repo.git").?;
    try testing.expectEqualStrings("github.com", p.host);
    try testing.expectEqualStrings("owner", p.owner);
    try testing.expectEqualStrings("repo", p.repo);
}

test "parseParts preserves repo names that contain dots" {
    // Reference explicitly calls out "cc.kurs.web" as a valid repo name.
    const p = parseParts("git@github.com:team/cc.kurs.web.git").?;
    try testing.expectEqualStrings("team", p.owner);
    try testing.expectEqualStrings("cc.kurs.web", p.repo);
}

test "parseParts rejects SSH config aliases like github.com-work" {
    // The alias has a hyphen in the last segment, so looksLikeRealHostname
    // rejects it. Matches reference's looksLikeRealHostname.
    try testing.expectEqual(@as(?ParsedRepo, null), parseParts("git@github.com-work:owner/repo.git"));
}

test "parseParts rejects nested GitLab groups (use normalize for those)" {
    // parseParts only returns a clean owner/repo pair. For nested
    // groups (group/subgroup/repo) callers should use normalize which
    // returns the flat canonical form.
    try testing.expectEqual(@as(?ParsedRepo, null), parseParts("https://gitlab.com/group/subgroup/repo.git"));
}

test "parseParts rejects empty and unrecognised input" {
    try testing.expectEqual(@as(?ParsedRepo, null), parseParts(""));
    try testing.expectEqual(@as(?ParsedRepo, null), parseParts("not a url"));
    try testing.expectEqual(@as(?ParsedRepo, null), parseParts("git@github.com"));
    try testing.expectEqual(@as(?ParsedRepo, null), parseParts("ftp://example.com/foo/bar"));
}

test "looksLikeRealHostname accepts real TLDs and rejects aliases" {
    try testing.expect(looksLikeRealHostname("github.com"));
    try testing.expect(looksLikeRealHostname("gitlab.example.io"));
    try testing.expect(looksLikeRealHostname("bitbucket.org"));
    // SSH config aliases
    try testing.expect(!looksLikeRealHostname("github.com-work"));
    try testing.expect(!looksLikeRealHostname("mybox"));
    try testing.expect(!looksLikeRealHostname(""));
    try testing.expect(!looksLikeRealHostname("."));
}
