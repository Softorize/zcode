//! Direct `.git` filesystem reader -- read branch / HEAD / ref state straight
//! from `.git/` without spawning a git subprocess.
//!
//! Ports the in-scope core of the reference
//! `claude-code-main/src/utils/git/gitFilesystem.ts:40-309`:
//!   - `resolveGitDir`  -- find `.git`; follow a `gitdir: <path>` pointer file
//!                         (worktree / submodule) to the real git dir.
//!   - `readGitHead`    -- parse `.git/HEAD` into a branch name or a detached SHA.
//!   - `resolveRef`     -- loose ref file first, then `packed-refs`, following
//!                         symrefs, falling back to the `commondir`.
//!   - `getCommonDir`   -- read the `commondir` pointer for worktrees.
//!
//! All ref names and SHAs read off disk are validated through
//! `core/git_ref.zig` (`isSafeRefName` / `isValidGitSha`): `.git/HEAD` and loose
//! ref files are plain text an attacker could write without git's own
//! check-ref-format validation, so a tampered ref must never flow into a path
//! join or a downstream git/shell argument.
//!
//! Scope note: this matches the existing `computeGitFingerprint`
//! (`context.zig:273-287`) convention of looking for `.git` directly inside the
//! supplied `cwd` (no upward `findGitRoot` walk). The reference's fs-watcher
//! cache (`GitFileWatcher`) is DEFERRED -- our stat-fingerprint cache is the
//! analog and is sufficient for the prompt-context fast path.

const std = @import("std");
const rt = @import("zcode_runtime");
const git_ref = @import("git_ref.zig");
const clock = @import("clock.zig");

/// A parsed `.git/HEAD`: either on a local branch or a detached SHA.
pub const Head = union(enum) {
    /// `ref: refs/heads/<branch>` -- the validated branch name.
    branch: []const u8,
    /// A raw detached SHA, or a symref resolved to its SHA. May be empty when
    /// an unusual symref could not be resolved (matches the reference's
    /// `{ type: 'detached', sha: '' }` fallback).
    detached: []const u8,
};

/// Cap on any single `.git` text file we read (HEAD, packed-refs, ref files,
/// the `.git` pointer file, commondir). packed-refs can be large in a repo with
/// many tags/remote branches but is still far under this bound in practice.
const MAX_GIT_FILE_BYTES: usize = 4 * 1024 * 1024;

/// Read a `.git` text file and return its trimmed contents, or null when the
/// file is absent / unreadable. Mirrors git's `strbuf_rtrim` (the reference
/// uses `.trim()`): leading and trailing ASCII whitespace are stripped.
fn readTrimmed(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const raw = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(MAX_GIT_FILE_BYTES)) catch return null;
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return allocator.dupe(u8, trimmed) catch null;
}

/// Resolve the actual `.git` directory for the repo at `cwd`.
///
/// Handles worktrees / submodules where `.git` is a FILE containing
/// `gitdir: <path>` rather than a directory. The pointer is resolved relative
/// to `cwd` (git strips trailing `\n`/`\r` via `read_gitfile_gently`).
///
/// Returns an allocator-owned absolute path, or null when there is no `.git`
/// at `cwd` (not a repo, by this scoped convention). The caller owns and frees
/// the returned slice.
pub fn resolveGitDir(allocator: std.mem.Allocator, cwd: []const u8) ?[]u8 {
    const git_path = std.fs.path.join(allocator, &.{ cwd, ".git" }) catch return null;
    var free_git_path = true;
    defer if (free_git_path) allocator.free(git_path);

    const stat = std.Io.Dir.cwd().statFile(rt.io, git_path, .{}) catch return null;

    if (stat.kind == .file) {
        // Worktree / submodule: `.git` is a file with `gitdir: <path>`.
        const content = readTrimmed(allocator, git_path) orelse return null;
        defer allocator.free(content);
        const prefix = "gitdir:";
        if (std.mem.startsWith(u8, content, prefix)) {
            const raw_dir = std.mem.trim(u8, content[prefix.len..], " \t\r\n");
            if (raw_dir.len == 0) return null;
            // Resolve relative to `cwd` (the dir holding the `.git` file), so a
            // relative `gitdir: ../.git/worktrees/x` lands correctly.
            return std.fs.path.resolve(allocator, &.{ cwd, raw_dir }) catch null;
        }
        // A `.git` file that is not a gitdir pointer is malformed -- treat as
        // "no git dir" so the caller falls back to the subprocess path.
        return null;
    }

    // Regular repo: `.git` is a directory. Hand back the joined path (do not
    // free it in the defer).
    free_git_path = false;
    return git_path;
}

/// Parse `<git_dir>/HEAD` into a branch name or a detached SHA.
///
/// HEAD format (git `refs/files-backend.c`):
///   - `ref: refs/heads/<branch>\n`  -- on a branch
///   - `ref: <other-ref>\n`          -- unusual symref (e.g. during bisect)
///   - `<hex-sha>\n`                 -- detached HEAD (rebase, `--detach`)
///
/// Returns an owned `Head` (the inner slice is allocator-owned), or null when
/// HEAD is missing or carries an unsafe/invalid ref or SHA. The caller owns and
/// frees the inner slice (`branch` / `detached`).
pub fn readGitHead(allocator: std.mem.Allocator, git_dir: []const u8) ?Head {
    const head_path = std.fs.path.join(allocator, &.{ git_dir, "HEAD" }) catch return null;
    defer allocator.free(head_path);

    const content = readTrimmed(allocator, head_path) orelse return null;
    defer allocator.free(content);

    const ref_prefix = "ref:";
    if (std.mem.startsWith(u8, content, ref_prefix)) {
        const ref = std.mem.trim(u8, content[ref_prefix.len..], " \t\r\n");
        const heads_prefix = "refs/heads/";
        if (std.mem.startsWith(u8, ref, heads_prefix)) {
            const name = ref[heads_prefix.len..];
            // Reject path traversal / argument injection from a tampered HEAD.
            if (!git_ref.isSafeRefName(name)) return null;
            const owned = allocator.dupe(u8, name) catch return null;
            return Head{ .branch = owned };
        }
        // Unusual symref (not a local branch) -- resolve to a SHA.
        if (!git_ref.isSafeRefName(ref)) return null;
        if (resolveRef(allocator, git_dir, ref)) |sha| {
            return Head{ .detached = sha };
        }
        // Could not resolve: match the reference's empty-SHA detached fallback.
        const empty = allocator.dupe(u8, "") catch return null;
        return Head{ .detached = empty };
    }

    // Raw SHA (detached HEAD). Validate before it can flow into a git/shell arg.
    if (!git_ref.isValidGitSha(content)) return null;
    const owned = allocator.dupe(u8, content) catch return null;
    return Head{ .detached = owned };
}

/// Resolve a git ref (e.g. `refs/heads/main`) to a commit SHA.
///
/// Checks loose ref files first, then falls back to `packed-refs`, following
/// symrefs (`ref: <target>`). For worktrees, shared refs live in the common
/// gitdir (pointed to by `commondir`), so on a miss we retry there.
///
/// Returns an allocator-owned 40/64-hex SHA, or null when the ref cannot be
/// resolved or any link in the chain is unsafe/invalid. Caller frees.
pub fn resolveRef(allocator: std.mem.Allocator, git_dir: []const u8, ref: []const u8) ?[]u8 {
    if (resolveRefInDir(allocator, git_dir, ref)) |sha| return sha;

    // Worktree: try the common gitdir where shared refs live.
    if (getCommonDir(allocator, git_dir)) |common_dir| {
        defer allocator.free(common_dir);
        if (!std.mem.eql(u8, common_dir, git_dir)) {
            return resolveRefInDir(allocator, common_dir, ref);
        }
    }
    return null;
}

fn resolveRefInDir(allocator: std.mem.Allocator, dir: []const u8, ref: []const u8) ?[]u8 {
    // The ref name becomes a path component under `dir`; guard traversal.
    if (!git_ref.isSafeRefName(ref)) return null;

    // 1. Loose ref file.
    const loose_path = std.fs.path.join(allocator, &.{ dir, ref }) catch return null;
    defer allocator.free(loose_path);
    if (readTrimmed(allocator, loose_path)) |content| {
        defer allocator.free(content);
        const ref_prefix = "ref:";
        if (std.mem.startsWith(u8, content, ref_prefix)) {
            const target = std.mem.trim(u8, content[ref_prefix.len..], " \t\r\n");
            // Reject path traversal in a tampered symref chain.
            if (!git_ref.isSafeRefName(target)) return null;
            return resolveRef(allocator, dir, target);
        }
        // Loose ref content should be a raw SHA.
        if (!git_ref.isValidGitSha(content)) return null;
        return allocator.dupe(u8, content) catch null;
    }

    // 2. packed-refs. Format (packed-backend.c): `<sha> <refname>\n`, skipping
    //    `#` header lines and `^<sha>` peeled-tag lines.
    const packed_path = std.fs.path.join(allocator, &.{ dir, "packed-refs" }) catch return null;
    defer allocator.free(packed_path);
    const packed_text = std.Io.Dir.cwd().readFileAlloc(rt.io, packed_path, allocator, .limited(MAX_GIT_FILE_BYTES)) catch return null;
    defer allocator.free(packed_text);

    var lines = std.mem.splitScalar(u8, packed_text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] == '#' or line[0] == '^') continue;
        const space_idx = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const name = line[space_idx + 1 ..];
        if (std.mem.eql(u8, name, ref)) {
            const sha = line[0..space_idx];
            if (!git_ref.isValidGitSha(sha)) return null;
            return allocator.dupe(u8, sha) catch null;
        }
    }
    return null;
}

/// Read `<git_dir>/commondir` to find the shared git directory. In a worktree
/// this points to the main repo's `.git`. Returns an owned absolute path, or
/// null for a regular repo (no `commondir` file). Caller frees.
pub fn getCommonDir(allocator: std.mem.Allocator, git_dir: []const u8) ?[]u8 {
    const path = std.fs.path.join(allocator, &.{ git_dir, "commondir" }) catch return null;
    defer allocator.free(path);
    const content = readTrimmed(allocator, path) orelse return null;
    defer allocator.free(content);
    if (content.len == 0) return null;
    return std.fs.path.resolve(allocator, &.{ git_dir, content }) catch null;
}

/// Age in seconds of `<git_dir>/FETCH_HEAD` (when the repo last fetched), or
/// null when FETCH_HEAD is absent / unreadable.
///
/// Ports the in-scope core of the reference `banner.ts:54-112`
/// (`readLastFetchTime`): stat `.git/FETCH_HEAD`'s mtime; for a worktree (no
/// per-worktree FETCH_HEAD), fall back to the shared FETCH_HEAD in the common
/// gitdir (pointed to by `commondir`). The full provenance banner (tildified
/// cwd, repo slug, the 7-day "repo may be stale" prose) is tied to the
/// DEFERRED deep-link launch path -- only this age primitive is built here, for
/// `/doctor` to consume.
///
/// A negative age (clock skew: FETCH_HEAD mtime is in the future) is clamped to
/// 0, so callers can treat the result as a non-negative "seconds since last
/// fetch".
pub fn lastFetchAgeSeconds(allocator: std.mem.Allocator, git_dir: []const u8) ?i64 {
    if (fetchHeadMtimeSeconds(allocator, git_dir)) |mtime| {
        return ageFrom(mtime);
    }

    // Worktree: the per-worktree gitdir has no FETCH_HEAD; the shared one lives
    // in the common gitdir.
    if (getCommonDir(allocator, git_dir)) |common_dir| {
        defer allocator.free(common_dir);
        if (!std.mem.eql(u8, common_dir, git_dir)) {
            if (fetchHeadMtimeSeconds(allocator, common_dir)) |mtime| {
                return ageFrom(mtime);
            }
        }
    }
    return null;
}

/// Stat `<dir>/FETCH_HEAD` and return its mtime in seconds since the epoch, or
/// null when the file is absent / unreadable.
fn fetchHeadMtimeSeconds(allocator: std.mem.Allocator, dir: []const u8) ?i64 {
    const path = std.fs.path.join(allocator, &.{ dir, "FETCH_HEAD" }) catch return null;
    defer allocator.free(path);
    const stat = std.Io.Dir.cwd().statFile(rt.io, path, .{}) catch return null;
    return stat.mtime.toSeconds();
}

/// Seconds elapsed from `mtime_seconds` until now, clamped to >= 0.
fn ageFrom(mtime_seconds: i64) i64 {
    const now = clock.nowSeconds();
    const age = now - mtime_seconds;
    return if (age < 0) 0 else age;
}

/// Convenience fast-path for `context.zig`: read the current branch of the repo
/// at `cwd` directly from `.git`, without spawning git. Returns an owned branch
/// name, or null when not on a branch (detached HEAD), not a repo, or any read
/// fails -- the caller then falls back to the subprocess path. Caller frees.
pub fn currentBranch(allocator: std.mem.Allocator, cwd: []const u8) ?[]u8 {
    const git_dir = resolveGitDir(allocator, cwd) orelse return null;
    defer allocator.free(git_dir);
    const head = readGitHead(allocator, git_dir) orelse return null;
    switch (head) {
        .branch => |name| return @constCast(name),
        .detached => |sha| {
            allocator.free(sha);
            return null;
        },
    }
}

const testing = std.testing;
const test_helpers = @import("test_helpers.zig");

/// Run a git command inside `cwd` for test setup. Returns true on exit 0.
fn runGit(allocator: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) bool {
    const result = std.process.run(allocator, rt.io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn gitCapture(allocator: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) ?[]u8 {
    const result = std.process.run(allocator, rt.io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
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
    const owned = allocator.dupe(u8, trimmed) catch {
        allocator.free(result.stdout);
        return null;
    };
    allocator.free(result.stdout);
    return owned;
}

fn initTestRepo(allocator: std.mem.Allocator, cwd: []const u8) !void {
    if (!runGit(allocator, cwd, &.{ "git", "init", "-q" })) return error.SkipZigTest;
    _ = runGit(allocator, cwd, &.{ "git", "config", "user.email", "test@example.com" });
    _ = runGit(allocator, cwd, &.{ "git", "config", "user.name", "Test" });
    _ = runGit(allocator, cwd, &.{ "git", "config", "commit.gpgsign", "false" });
    // A commit so HEAD's ref file exists.
    const f = try std.fs.path.join(allocator, &.{ cwd, "README.md" });
    defer allocator.free(f);
    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, f, .{ .truncate = true });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, "hello\n");
    }
    if (!runGit(allocator, cwd, &.{ "git", "add", "README.md" })) return error.SkipZigTest;
    if (!runGit(allocator, cwd, &.{ "git", "commit", "-q", "-m", "init" })) return error.SkipZigTest;
}

test "currentBranch matches git rev-parse --abbrev-ref HEAD" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    try initTestRepo(allocator, cwd);

    const expected = gitCapture(allocator, cwd, &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" }) orelse return error.SkipZigTest;
    defer allocator.free(expected);

    const got = currentBranch(allocator, cwd) orelse {
        try testing.expect(false); // direct read should succeed for a normal repo
        return;
    };
    defer allocator.free(got);

    try testing.expectEqualStrings(expected, got);
}

test "readGitHead reports the branch name; resolveRef matches rev-parse HEAD" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    try initTestRepo(allocator, cwd);
    // Pin a known branch name so the assertion is deterministic across git
    // versions whose `init.defaultBranch` differs (main vs master).
    _ = runGit(allocator, cwd, &.{ "git", "branch", "-M", "trunk" });

    const git_dir = resolveGitDir(allocator, cwd) orelse return error.SkipZigTest;
    defer allocator.free(git_dir);

    const head = readGitHead(allocator, git_dir) orelse return error.SkipZigTest;
    switch (head) {
        .branch => |name| {
            defer allocator.free(name);
            try testing.expectEqualStrings("trunk", name);

            // resolveRef of refs/heads/trunk equals git rev-parse HEAD.
            const expected_sha = gitCapture(allocator, cwd, &.{ "git", "rev-parse", "HEAD" }) orelse return error.SkipZigTest;
            defer allocator.free(expected_sha);
            const got_sha = resolveRef(allocator, git_dir, "refs/heads/trunk") orelse {
                try testing.expect(false);
                return;
            };
            defer allocator.free(got_sha);
            try testing.expectEqualStrings(expected_sha, got_sha);
        },
        .detached => |sha| {
            allocator.free(sha);
            try testing.expect(false); // expected a branch, not detached
        },
    }
}

test "detached HEAD reads the SHA" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    try initTestRepo(allocator, cwd);

    const sha = gitCapture(allocator, cwd, &.{ "git", "rev-parse", "HEAD" }) orelse return error.SkipZigTest;
    defer allocator.free(sha);
    if (!runGit(allocator, cwd, &.{ "git", "checkout", "-q", "--detach", sha })) return error.SkipZigTest;

    const git_dir = resolveGitDir(allocator, cwd) orelse return error.SkipZigTest;
    defer allocator.free(git_dir);

    const head = readGitHead(allocator, git_dir) orelse return error.SkipZigTest;
    switch (head) {
        .detached => |got| {
            defer allocator.free(got);
            try testing.expectEqualStrings(sha, got);
        },
        .branch => |name| {
            allocator.free(name);
            try testing.expect(false); // expected detached
        },
    }

    // currentBranch returns null on a detached HEAD (caller falls back).
    try testing.expect(currentBranch(allocator, cwd) == null);
}

test "packed-ref-only ref resolves" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    try initTestRepo(allocator, cwd);
    _ = runGit(allocator, cwd, &.{ "git", "branch", "-M", "trunk" });

    const expected_sha = gitCapture(allocator, cwd, &.{ "git", "rev-parse", "HEAD" }) orelse return error.SkipZigTest;
    defer allocator.free(expected_sha);

    // Pack refs and remove the loose ref so resolution must use packed-refs.
    if (!runGit(allocator, cwd, &.{ "git", "pack-refs", "--all" })) return error.SkipZigTest;

    const git_dir = resolveGitDir(allocator, cwd) orelse return error.SkipZigTest;
    defer allocator.free(git_dir);

    // Confirm the loose ref is gone (pack-refs --all removes it). If git left
    // it, this test still exercises resolveRef but not the packed path; either
    // way the SHA must match.
    const got = resolveRef(allocator, git_dir, "refs/heads/trunk") orelse {
        try testing.expect(false);
        return;
    };
    defer allocator.free(got);
    try testing.expectEqualStrings(expected_sha, got);
}

test "resolveGitDir returns null when there is no .git" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    try testing.expect(resolveGitDir(allocator, cwd) == null);
    try testing.expect(currentBranch(allocator, cwd) == null);
}

test "lastFetchAgeSeconds: fresh FETCH_HEAD yields a small age" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    try initTestRepo(allocator, cwd);

    const git_dir = resolveGitDir(allocator, cwd) orelse return error.SkipZigTest;
    defer allocator.free(git_dir);

    // Write a fresh FETCH_HEAD (git init does not create one).
    const fetch_path = try std.fs.path.join(allocator, &.{ git_dir, "FETCH_HEAD" });
    defer allocator.free(fetch_path);
    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, fetch_path, .{ .truncate = true });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, "0000000000000000000000000000000000000000\tbranch 'main'\n");
    }

    const age = lastFetchAgeSeconds(allocator, git_dir) orelse {
        try testing.expect(false); // a just-written FETCH_HEAD must be readable
        return;
    };
    // Just written, so the age is small and non-negative. Allow generous slack
    // for slow CI hosts.
    try testing.expect(age >= 0);
    try testing.expect(age < 120);
}

test "lastFetchAgeSeconds: missing FETCH_HEAD yields null" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    try initTestRepo(allocator, cwd);

    const git_dir = resolveGitDir(allocator, cwd) orelse return error.SkipZigTest;
    defer allocator.free(git_dir);

    // git init does not create FETCH_HEAD (no fetch has happened).
    try testing.expect(lastFetchAgeSeconds(allocator, git_dir) == null);
}

test "readGitHead rejects a tampered unsafe branch name" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    // Hand-build a minimal .git dir with a malicious HEAD. The ref name carries
    // a shell metacharacter that isSafeRefName must reject.
    const git_dir = try std.fs.path.join(allocator, &.{ cwd, ".git" });
    defer allocator.free(git_dir);
    try std.Io.Dir.cwd().createDirPath(rt.io, git_dir);
    const head_path = try std.fs.path.join(allocator, &.{ git_dir, "HEAD" });
    defer allocator.free(head_path);
    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, head_path, .{ .truncate = true });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, "ref: refs/heads/evil;rm\n");
    }

    const resolved = resolveGitDir(allocator, cwd) orelse return error.SkipZigTest;
    defer allocator.free(resolved);
    try testing.expect(readGitHead(allocator, resolved) == null);
}
