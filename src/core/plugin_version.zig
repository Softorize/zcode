//! Plugin version derivation for cache keying (plugins-12, partial).
//!
//! zcode used to stamp every plugin with a single `"0.1.0"` fallback when the
//! manifest carried no `version` field. The reference derives a real version via
//! a priority chain so cache keys differ across versions and update detection
//! works (`utils/plugins/pluginVersioning.ts:36-158`).
//!
//! Priority chain (highest first), mirroring `calculatePluginVersion`:
//!   1. manifest `version` field
//!   2. marketplace-provided version
//!   3. pre-resolved git short SHA (12 chars); for a git-subdir source the
//!      subdir path is hashed in so two plugins at different subdirs of the same
//!      commit get distinct cache keys
//!   4. git short SHA read from the install path's repo HEAD
//!   5. `"unknown"` as the last resort
//!
//! The git-subdir path normalization MUST match the reference byte-for-byte
//! (backslash -> forward slash, strip one leading `./`, strip all trailing `/`,
//! UTF-8 sha256 first 8 hex chars) so cache keys stay consistent with any future
//! official squashfs build.

const std = @import("std");
const rt = @import("zcode_runtime");

const short_sha_len = 12;
const path_hash_hex_len = 8;

/// How the plugin's files arrived. A plain git clone carries its `.git` at the
/// install path; a git-subdir source extracts a monorepo subdirectory (the clone
/// is discarded), so the subdir path is folded into the version to avoid cache
/// collisions between two subdirs of the same commit.
pub const SourceKind = union(enum) {
    /// Local copy, http archive, or any non-git source - no SHA encoding.
    other,
    /// A full git clone; the short SHA alone keys the cache.
    git,
    /// A monorepo subdirectory; the SHA is suffixed with a hash of `path`.
    git_subdir: struct { path: []const u8 },
};

/// Inputs to the version chain. All version-bearing fields are optional so a
/// caller supplies only what it knows; the chain falls through in priority order.
pub const VersionInput = struct {
    /// Plugin id used only for debug logging context (e.g. "demo@local").
    plugin_id: []const u8 = "",
    /// `version` from plugin.json, if present (priority 1).
    manifest_version: ?[]const u8 = null,
    /// Version from a marketplace catalog entry, if present (priority 2).
    provided_version: ?[]const u8 = null,
    /// Pre-resolved full git SHA captured before a clone was discarded
    /// (priority 3). Used with `source` for git-subdir path encoding.
    git_commit_sha: ?[]const u8 = null,
    /// Source kind, used only when `git_commit_sha` is set (git-subdir encoding).
    source: SourceKind = .other,
    /// Path to the installed plugin; the chain reads its repo HEAD (priority 4).
    install_path: ?[]const u8 = null,
};

/// Derive the cache-keying version per the priority chain. Caller owns the
/// returned slice. Never errors on a non-git install path - it falls through to
/// `"unknown"`.
pub fn calculateVersion(allocator: std.mem.Allocator, input: VersionInput) ![]u8 {
    // 1. Explicit manifest version wins. An empty string is treated as absent so
    // a `"version": ""` field does not shadow the rest of the chain.
    if (nonEmpty(input.manifest_version)) |v| return allocator.dupe(u8, v);

    // 2. Marketplace-provided version.
    if (nonEmpty(input.provided_version)) |v| return allocator.dupe(u8, v);

    // 3. Pre-resolved git SHA (caller captured it before discarding the clone).
    if (nonEmpty(input.git_commit_sha)) |full_sha| {
        const short = full_sha[0..@min(short_sha_len, full_sha.len)];
        switch (input.source) {
            .git_subdir => |sd| {
                const norm = normalizeSubdirPath(sd.path);
                var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(norm, &digest, .{});
                // First 8 hex chars = first 4 bytes, lowercase, zero-padded.
                var hex_buf: [path_hash_hex_len]u8 = undefined;
                _ = std.fmt.bufPrint(&hex_buf, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
                    digest[0], digest[1], digest[2], digest[3],
                }) catch unreachable;
                return std.fmt.allocPrint(allocator, "{s}-{s}", .{ short, &hex_buf });
            },
            else => return allocator.dupe(u8, short),
        }
    }

    // 4. Read the git SHA from the install path's repo HEAD.
    if (input.install_path) |path| {
        if (gitCommitSha(allocator, path)) |full_sha| {
            defer allocator.free(full_sha);
            const short = full_sha[0..@min(short_sha_len, full_sha.len)];
            return allocator.dupe(u8, short);
        }
    }

    // 5. Last resort.
    return allocator.dupe(u8, "unknown");
}

/// Normalize a git-subdir path for hashing, byte-for-byte matching the reference
/// (`pluginVersioning.ts:75-78`): backslash -> forward slash, strip one leading
/// `./`, strip all trailing `/`. The returned slice is only valid until the next
/// call (it may point into a module-level scratch buffer when backslash
/// conversion is needed); the sole caller hashes it immediately, so the lifetime
/// is contained. Version derivation is single-threaded, so the shared scratch is
/// safe.
fn normalizeSubdirPath(path: []const u8) []const u8 {
    // Backslash conversion needs a mutable copy; the common case (no backslash)
    // borrows the input directly. The scratch is far larger than any legitimate
    // marketplace.json `path`; an over-long path is truncated (a degenerate input
    // that would never match a real squashfs build anyway).
    var has_backslash = false;
    for (path) |c| {
        if (c == '\\') has_backslash = true;
    }
    var slashed: []const u8 = path;
    if (has_backslash) {
        const scratch = normalize_scratch_buf[0..];
        var len: usize = 0;
        for (path) |c| {
            if (len >= scratch.len) break;
            scratch[len] = if (c == '\\') '/' else c;
            len += 1;
        }
        slashed = scratch[0..len];
    }

    // Strip one leading "./".
    var start: usize = 0;
    if (slashed.len >= 2 and slashed[0] == '.' and slashed[1] == '/') start = 2;

    // Strip all trailing '/'.
    var end: usize = slashed.len;
    while (end > start and slashed[end - 1] == '/') end -= 1;

    return slashed[start..end];
}

/// 4 KiB scratch for backslash normalization. Subdir paths are short; this is far
/// larger than any legitimate marketplace `path`. Module-level (single-threaded
/// version derivation) so the slice stays valid for the inline hash above.
var normalize_scratch_buf: [4096]u8 = undefined;

/// Extract the version component from a versioned cache path, mirroring the
/// reference (`getVersionFromPath`, pluginVersioning.ts:127-147). A versioned
/// path has the shape `.../plugins/cache/<marketplace>/<plugin>/<version>/...`;
/// the version is the 3rd component after the `cache` segment whose predecessor
/// is `plugins`. Returns null for a non-versioned path. The returned slice
/// borrows from `install_path` (no allocation).
pub fn versionFromPath(install_path: []const u8) ?[]const u8 {
    // Split on '/', dropping empty segments (handles leading/trailing/double
    // slashes the same way the reference's `.filter(Boolean)` does).
    var parts: [256][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, install_path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (n >= parts.len) break;
        parts[n] = seg;
        n += 1;
    }

    // Find the `cache` segment whose predecessor is `plugins`.
    var cache_index: ?usize = null;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (std.mem.eql(u8, parts[i], "cache") and i >= 1 and std.mem.eql(u8, parts[i - 1], "plugins")) {
            cache_index = i;
            break;
        }
    }
    const ci = cache_index orelse return null;

    // Versioned path has >= 3 components after cache: marketplace/plugin/version.
    const after = n - (ci + 1);
    if (after >= 3) {
        return parts[ci + 1 + 2];
    }
    return null;
}

/// True when `path` follows the versioned cache structure.
pub fn isVersionedPath(path: []const u8) bool {
    return versionFromPath(path) != null;
}

/// Full git commit SHA at `dir_path`'s repo HEAD, or null if not a git repo.
/// Caller owns the returned slice. Uses a one-shot `std.process.run` per
/// CLAUDE.md (no long-lived child to reap; `Child.init` is gone in 0.16).
fn gitCommitSha(allocator: std.mem.Allocator, dir_path: []const u8) ?[]u8 {
    const argv = [_][]const u8{ "git", "-C", dir_path, "rev-parse", "HEAD" };
    const result = std.process.run(allocator, rt.io, .{
        .argv = &argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return null;
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            allocator.free(result.stdout);
            return null;
        },
        else => {
            allocator.free(result.stdout);
            return null;
        },
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(result.stdout);
        return null;
    }
    const owned = allocator.dupe(u8, trimmed) catch {
        allocator.free(result.stdout);
        return null;
    };
    allocator.free(result.stdout);
    return owned;
}

fn nonEmpty(opt: ?[]const u8) ?[]const u8 {
    const v = opt orelse return null;
    if (v.len == 0) return null;
    return v;
}

const testing = std.testing;

test "calculateVersion: manifest version wins over provided version" {
    const v = try calculateVersion(testing.allocator, .{
        .plugin_id = "demo@local",
        .manifest_version = "2.3.4",
        .provided_version = "9.9.9",
    });
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("2.3.4", v);
}

test "calculateVersion: empty manifest version falls through to provided" {
    const v = try calculateVersion(testing.allocator, .{
        .manifest_version = "",
        .provided_version = "1.0.0",
    });
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("1.0.0", v);
}

test "calculateVersion: pre-resolved git SHA yields 12-char short SHA" {
    const v = try calculateVersion(testing.allocator, .{
        .git_commit_sha = "0123456789abcdef0123456789abcdef01234567",
        .source = .git,
    });
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("0123456789ab", v);
}

test "calculateVersion: git-subdir produces <sha>-<8hexpathhash> with documented normalization" {
    // Normalize "./packages/foo/" -> "packages/foo", sha256, first 8 hex chars.
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("packages/foo", &digest, .{});
    var expected_hex: [8]u8 = undefined;
    _ = try std.fmt.bufPrint(&expected_hex, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ digest[0], digest[1], digest[2], digest[3] });
    const expected = try std.fmt.allocPrint(testing.allocator, "0123456789ab-{s}", .{expected_hex});
    defer testing.allocator.free(expected);

    const v = try calculateVersion(testing.allocator, .{
        .git_commit_sha = "0123456789abcdef0123456789abcdef01234567",
        .source = .{ .git_subdir = .{ .path = "./packages/foo/" } },
    });
    defer testing.allocator.free(v);
    try testing.expectEqualStrings(expected, v);
}

test "calculateVersion: git-subdir backslash normalization matches forward-slash form" {
    const back = try calculateVersion(testing.allocator, .{
        .git_commit_sha = "0123456789abcdef0123456789abcdef01234567",
        .source = .{ .git_subdir = .{ .path = "packages\\foo" } },
    });
    defer testing.allocator.free(back);
    const fwd = try calculateVersion(testing.allocator, .{
        .git_commit_sha = "0123456789abcdef0123456789abcdef01234567",
        .source = .{ .git_subdir = .{ .path = "packages/foo" } },
    });
    defer testing.allocator.free(fwd);
    try testing.expectEqualStrings(fwd, back);
}

test "calculateVersion: no version sources yields unknown" {
    const v = try calculateVersion(testing.allocator, .{ .plugin_id = "x@local" });
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("unknown", v);
}

test "calculateVersion: install_path git SHA yields 12-char prefix" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // init a tiny git repo with one commit
    if (!gitRun(testing.allocator, cwd, &.{ "git", "init", "-q" })) return error.SkipZigTest;
    _ = gitRun(testing.allocator, cwd, &.{ "git", "config", "user.email", "t@t" });
    _ = gitRun(testing.allocator, cwd, &.{ "git", "config", "user.name", "t" });
    {
        const f = try std.Io.Dir.cwd().createFile(rt.io, try joinTmp(testing.allocator, cwd, "README"), .{ .truncate = true });
        f.close(rt.io);
    }
    _ = gitRun(testing.allocator, cwd, &.{ "git", "add", "-A" });
    if (!gitRun(testing.allocator, cwd, &.{ "git", "commit", "-q", "-m", "init" })) return error.SkipZigTest;

    const v = try calculateVersion(testing.allocator, .{ .install_path = cwd });
    defer testing.allocator.free(v);
    try testing.expect(!std.mem.eql(u8, v, "unknown"));
    try testing.expectEqual(@as(usize, short_sha_len), v.len);
    for (v) |c| try testing.expect(std.ascii.isHex(c));
}

test "versionFromPath extracts the version segment of a versioned cache path" {
    const got = versionFromPath("/home/u/.zcode/plugins/cache/market/myplugin/1.2.3/");
    try testing.expect(got != null);
    try testing.expectEqualStrings("1.2.3", got.?);
    try testing.expect(isVersionedPath("/home/u/.zcode/plugins/cache/market/myplugin/1.2.3"));
}

test "versionFromPath returns null for a non-versioned path" {
    try testing.expect(versionFromPath("/home/u/.zcode/plugins/myplugin") == null);
    try testing.expect(versionFromPath("/some/random/dir") == null);
    // `cache` present but predecessor is not `plugins`.
    try testing.expect(versionFromPath("/var/cache/market/p/1.0.0") == null);
    try testing.expect(!isVersionedPath("/home/u/.zcode/plugins/myplugin"));
}

fn gitRun(allocator: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) bool {
    const result = std.process.run(allocator, rt.io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return false;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn joinTmp(allocator: std.mem.Allocator, cwd: []const u8, name: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ cwd, name });
}
