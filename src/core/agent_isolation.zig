//! Per-agent worktree / cwd isolation helpers (swarm-tasks-11).
//!
//! When an AgentRun requests `isolation:"worktree"` the spawned sub-agent runs
//! inside a fresh git worktree; when it supplies a `cwd` override it runs in
//! that absolute directory; otherwise it inherits the parent's cwd. The two are
//! mutually exclusive.
//!
//! Reference: claude-code AgentTool.tsx:99-100 (isolation/cwd schema),
//! :583-640 createAgentWorktree / cwdOverridePath, forkSubagent.ts:205-210
//! buildWorktreeNotice.
//!
//! This module holds the *pure* decision and rendering logic (kind
//! classification, mutual-exclusion validation, worktree path construction,
//! the notice string, and worktree create/remove that shells out to git). The
//! runtime wiring in agent_runtime.zig consumes it.

const std = @import("std");
const rt = @import("zcode_runtime");

/// The three isolation modes a spawned agent can run under.
pub const Kind = enum {
    /// Inherit the parent's cwd (no isolation requested).
    none,
    /// Run in a freshly created git worktree.
    worktree,
    /// Run in a caller-supplied absolute directory.
    cwd,
};

pub const Error = error{
    /// `isolation` and `cwd` were both supplied.
    IsolationCwdConflict,
    /// `isolation` was set to a value other than "worktree".
    UnsupportedIsolation,
    /// `cwd` override was not an absolute path.
    CwdNotAbsolute,
};

/// Classify the requested isolation/cwd pair into a single `Kind`, enforcing
/// mutual exclusion and validating the values. Mirrors the reference which
/// rejects supplying both `isolation` and `cwd`.
///
/// - both null -> `.none`
/// - `isolation == "worktree"` (and no cwd) -> `.worktree`
/// - `cwd` set (and no isolation) -> `.cwd` (must be absolute)
/// - any other `isolation` value -> `error.UnsupportedIsolation`
///   (note: "remote" is a cloud mode and is out of scope here)
pub fn classify(isolation: ?[]const u8, cwd_override: ?[]const u8) Error!Kind {
    const iso = trimOptional(isolation);
    const cwd = trimOptional(cwd_override);

    if (iso != null and cwd != null) return Error.IsolationCwdConflict;

    if (iso) |kind| {
        if (std.mem.eql(u8, kind, "worktree")) return .worktree;
        // "none" / "" both mean inherit; everything else (including the cloud
        // "remote" mode, which is out of scope) is unsupported here.
        if (std.mem.eql(u8, kind, "none")) return .none;
        return Error.UnsupportedIsolation;
    }

    if (cwd) |path| {
        if (!std.fs.path.isAbsolute(path)) return Error.CwdNotAbsolute;
        return .cwd;
    }

    return .none;
}

/// Trim whitespace and collapse an empty string to null so callers can treat
/// `isolation=` / `cwd=` (empty) the same as omitting the arg.
fn trimOptional(s: ?[]const u8) ?[]const u8 {
    if (s) |v| {
        const t = std.mem.trim(u8, v, " \t\r\n");
        if (t.len == 0) return null;
        return t;
    }
    return null;
}

/// Build the absolute path for a new per-agent worktree under
/// `<base>/.zcode/worktrees/agent-<suffix>`. The suffix uniquifies the path so
/// parallel spawns do not collide. Caller owns the returned slice.
pub fn worktreePathAlloc(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    suffix: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/.zcode/worktrees/agent-{s}",
        .{ base_dir, suffix },
    );
}

/// Render the "working in worktree" notice prepended to a spawned agent's
/// opening context. Mirrors forkSubagent.ts buildWorktreeNotice. Caller owns
/// the returned slice.
pub fn buildWorktreeNotice(allocator: std.mem.Allocator, worktree_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "You are working in an isolated git worktree at {s}. " ++
            "All file changes you make are scoped to this worktree, not the parent checkout. " ++
            "Use absolute paths under this directory.\n\n",
        .{worktree_path},
    );
}

/// Create a git worktree at `worktree_path` rooted at `repo_cwd`. Best-effort:
/// returns an error string (caller-owned) on failure, or null on success. Uses
/// a one-shot `std.process.run` per CLAUDE.md (no long-lived child to reap).
/// Creates a detached worktree on a new branch named after the worktree dir so
/// concurrent worktrees do not fight over a shared branch.
pub fn createWorktree(
    allocator: std.mem.Allocator,
    repo_cwd: []const u8,
    worktree_path: []const u8,
) !?[]u8 {
    // Ensure the parent directory exists so `git worktree add` does not fail on
    // a missing `.zcode/worktrees` path.
    if (std.fs.path.dirname(worktree_path)) |parent| {
        std.Io.Dir.cwd().createDirPath(rt.io, parent) catch {};
    }

    const result = std.process.run(allocator, rt.io, .{
        .argv = &.{ "git", "worktree", "add", "--detach", worktree_path },
        .cwd = .{ .path = repo_cwd },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch |err| {
        const msg: ?[]u8 = try std.fmt.allocPrint(allocator, "worktree error: {s}", .{@errorName(err)});
        return msg;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term == .exited and result.term.exited == 0) return null;
    const msg: ?[]u8 = try std.fmt.allocPrint(
        allocator,
        "worktree create failed: {s}",
        .{std.mem.trim(u8, result.stderr, " \t\r\n")},
    );
    return msg;
}

/// Remove a previously created worktree. Best-effort cleanup so finished agents
/// do not leak worktrees. Errors are swallowed (the dir may already be gone).
pub fn removeWorktree(
    allocator: std.mem.Allocator,
    repo_cwd: []const u8,
    worktree_path: []const u8,
) void {
    const result = std.process.run(allocator, rt.io, .{
        .argv = &.{ "git", "worktree", "remove", "--force", worktree_path },
        .cwd = .{ .path = repo_cwd },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

const testing = std.testing;

test "classify: neither isolation nor cwd -> none" {
    try testing.expectEqual(Kind.none, try classify(null, null));
}

test "classify: isolation=worktree -> worktree" {
    try testing.expectEqual(Kind.worktree, try classify("worktree", null));
}

test "classify: cwd override (absolute) -> cwd" {
    try testing.expectEqual(Kind.cwd, try classify(null, "/tmp/x"));
}

test "classify: both set -> conflict error" {
    try testing.expectError(Error.IsolationCwdConflict, classify("worktree", "/tmp/x"));
}

test "classify: unsupported isolation value -> error" {
    try testing.expectError(Error.UnsupportedIsolation, classify("remote", null));
}

test "classify: relative cwd override -> error" {
    try testing.expectError(Error.CwdNotAbsolute, classify(null, "relative/dir"));
}

test "classify: empty strings collapse to none" {
    try testing.expectEqual(Kind.none, try classify("", ""));
    try testing.expectEqual(Kind.none, try classify("  ", null));
}

test "worktreePathAlloc builds nested path" {
    const p = try worktreePathAlloc(testing.allocator, "/repo", "abc123");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("/repo/.zcode/worktrees/agent-abc123", p);
}

test "buildWorktreeNotice mentions the path" {
    const notice = try buildWorktreeNotice(testing.allocator, "/repo/.zcode/worktrees/agent-x");
    defer testing.allocator.free(notice);
    try testing.expect(std.mem.indexOf(u8, notice, "/repo/.zcode/worktrees/agent-x") != null);
    try testing.expect(std.mem.indexOf(u8, notice, "isolated git worktree") != null);
}
