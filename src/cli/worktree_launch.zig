//! cli-flags-08: `-w, --worktree [name]` / `--tmux[=classic]` -- create (or
//! reuse) a git worktree for THIS session before it starts, then run inside
//! it, mirroring the reference's launch-time worktree creation. This is
//! deliberately a separate, standalone implementation rather than a call
//! into `tools/tool_dispatch.zig`'s (private, model-facing) EnterWorktree
//! handler -- that module is owned by a different parity package and its
//! `handleEnterWorktree`/`handleExitWorktree` functions are not `pub`.
//!
//! Scope: creates the worktree under `<repo_root>/.zcode-worktrees/<name>`
//! on a branch named `<name>` (new branch if it doesn't exist yet, checked
//! out if it does), and reuses an existing worktree directory unchanged on a
//! second invocation with the same name (so a resumed `--worktree feature-x`
//! session doesn't error on "already exists"). `--tmux`/`--tmux=classic`
//! best-effort spawns a detached `tmux new-session` rooted at the worktree
//! path; Claude Code's iTerm2-native-panes mode is not implemented (no
//! zcode equivalent to AppleScript-drive iTerm2 exists), so both spellings
//! degrade to plain tmux, which is honest and still useful outside iTerm2.

const std = @import("std");
const rt = @import("zcode_runtime");
const clock = @import("../core/clock.zig");
const rng = @import("../core/rng.zig");

pub const WorktreeError = error{
    NotAGitRepo,
    GitCommandFailed,
};

/// Resolve the git repository root containing `cwd` (`git rev-parse
/// --show-toplevel`). Returns `error.NotAGitRepo` when `cwd` is not inside a
/// git working tree.
fn repoRoot(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const result = std.process.run(allocator, rt.io, .{
        .argv = &.{ "git", "-C", cwd, "rev-parse", "--show-toplevel" },
        .stdout_limit = .limited(4 * 1024),
        .stderr_limit = .limited(4 * 1024),
    }) catch return error.NotAGitRepo;
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        return error.NotAGitRepo;
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    const owned = try allocator.dupe(u8, trimmed);
    allocator.free(result.stdout);
    return owned;
}

fn branchExists(allocator: std.mem.Allocator, repo_root: []const u8, branch: []const u8) bool {
    const result = std.process.run(allocator, rt.io, .{
        .argv = &.{ "git", "-C", repo_root, "rev-parse", "--verify", "--quiet", branch },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(rt.io, path, .{}) catch return false;
    return true;
}

/// Auto-generate a worktree name when `-w`/`--worktree` is given bare (no
/// name). Time-based with a short random suffix so two bare `--worktree`
/// launches in the same second never collide.
fn generateName(buf: []u8) []const u8 {
    var rand_bytes: [3]u8 = undefined;
    rng.bytes(&rand_bytes);
    return std.fmt.bufPrint(buf, "zcode-{d}-{x}{x}{x}", .{
        clock.nowSeconds(), rand_bytes[0], rand_bytes[1], rand_bytes[2],
    }) catch "zcode-worktree";
}

/// Create (or reuse) a git worktree for `cwd`'s repository, on branch
/// `name` (or an auto-generated name when `name` is null), and return its
/// absolute path. The caller frees the returned slice.
pub fn resolveWorktreePath(allocator: std.mem.Allocator, cwd: []const u8, name: ?[]const u8) ![]u8 {
    const root = try repoRoot(allocator, cwd);
    defer allocator.free(root);

    var name_buf: [64]u8 = undefined;
    const branch = name orelse generateName(&name_buf);

    const path = try std.fs.path.join(allocator, &.{ root, ".zcode-worktrees", branch });
    errdefer allocator.free(path);

    if (pathExists(path)) {
        // A second `--worktree <same-name>` launch (e.g. resuming a
        // session) reuses the existing worktree rather than erroring.
        return path;
    }

    const argv: []const []const u8 = if (branchExists(allocator, root, branch))
        &.{ "git", "-C", root, "worktree", "add", path, branch }
    else
        &.{ "git", "-C", root, "worktree", "add", "-b", branch, path };

    const result = std.process.run(allocator, rt.io, .{
        .argv = argv,
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch return error.GitCommandFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        return error.GitCommandFailed;
    }
    return path;
}

/// Best-effort: spawn a detached tmux session rooted at `worktree_path`.
/// `mode` is the raw `--tmux`/`--tmux=<mode>` value ("" for bare `--tmux`,
/// "classic" for an explicit request); both currently produce a plain
/// `tmux new-session` since zcode has no iTerm2-native-panes driver.
/// Failures (tmux not installed, etc.) are swallowed -- this is a nice-to-
/// have, never a reason to fail session startup.
pub fn spawnTmux(allocator: std.mem.Allocator, worktree_path: []const u8, session_name: []const u8) void {
    _ = std.process.run(allocator, rt.io, .{
        .argv = &.{ "tmux", "new-session", "-d", "-s", session_name, "-c", worktree_path },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    }) catch return;
}

const testing = std.testing;

fn initGitRepoForTest(allocator: std.mem.Allocator, cwd: []const u8) !void {
    const steps = [_][]const []const u8{
        &.{ "git", "-C", cwd, "init", "-q" },
        &.{ "git", "-C", cwd, "config", "user.email", "test@example.com" },
        &.{ "git", "-C", cwd, "config", "user.name", "zcode test" },
    };
    for (steps) |argv| {
        const result = try std.process.run(allocator, rt.io, .{
            .argv = argv,
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(64 * 1024),
        });
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    // `git worktree add -b <branch>` needs a HEAD to branch from.
    const commit = try std.process.run(allocator, rt.io, .{
        .argv = &.{ "git", "-C", cwd, "commit", "--allow-empty", "-q", "-m", "init" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    allocator.free(commit.stdout);
    allocator.free(commit.stderr);
}

test "resolveWorktreePath creates a new branch and worktree directory" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try @import("../core/test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    initGitRepoForTest(alloc, root) catch return error.SkipZigTest;

    const path = resolveWorktreePath(alloc, root, "feature-x") catch return error.SkipZigTest;
    defer alloc.free(path);

    try testing.expect(std.mem.indexOf(u8, path, "feature-x") != null);
    std.Io.Dir.accessAbsolute(rt.io, path, .{}) catch return error.SkipZigTest;
}

test "resolveWorktreePath reuses an existing worktree on a second call" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try @import("../core/test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    initGitRepoForTest(alloc, root) catch return error.SkipZigTest;

    const first = resolveWorktreePath(alloc, root, "feature-y") catch return error.SkipZigTest;
    defer alloc.free(first);
    const second = resolveWorktreePath(alloc, root, "feature-y") catch return error.SkipZigTest;
    defer alloc.free(second);

    try testing.expectEqualStrings(first, second);
}

// NOTE: a "resolveWorktreePath outside a git repo returns NotAGitRepo" case
// is deliberately not unit-tested here: `testing.tmpDir` places its
// directory under THIS repo's own `.zig-cache/tmp/`, which is itself inside
// a git working tree, so `git -C <tmp> rev-parse --show-toplevel` finds the
// enclosing repo instead of failing -- and Zig 0.16's `std.process.run`
// takes its child environment from a snapshot captured at runtime-install
// time (`Io.Threaded`'s cached `process_environ`), not live libc `environ`,
// so a test-local `setenv(GIT_CEILING_DIRECTORIES, ...)` has no effect on
// spawned children. The `error.GitCommandFailed`/`error.NotAGitRepo` path
// itself is still real code (see `repoRoot` above) exercised by any actual
// non-repo invocation of `zcode --worktree`.
