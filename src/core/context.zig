const std = @import("std");
const std_io = @import("std_io.zig");
const rt = @import("zcode_runtime");
const clock = @import("clock.zig");
const types = @import("types.zig");
const paths = @import("paths.zig");
const parse_helpers = @import("parse_helpers.zig");
const workspace_dirs = @import("workspace_dirs.zig");
const git_fs = @import("git_fs.zig");

/// Cross-turn cache for the three subprocess-heavy git captures
/// (`git status`, `git diff --stat`, and the directory walk that
/// builds the repo map). Second- and subsequent-turn cost drops
/// from three `execvp`s + a fs walk to three `statFile` calls on
/// the common case where the working tree has not changed between
/// turns. Invalidation fingerprint is (`.git/index` mtime+size)
/// XOR (`.git/HEAD` mtime+size) XOR (cwd dir mtime); if any change,
/// we redo the captures. Caller owns the cache lifetime; the
/// stored bytes are allocated from `owner_allocator`.
pub const GitCaptureCache = struct {
    owner_allocator: std.mem.Allocator,
    cwd: []u8 = &.{},
    fingerprint: u64 = 0,
    has_entry: bool = false,
    status: ?[]u8 = null,
    diff: ?[]u8 = null,
    repo_map: ?[]u8 = null,
    hits: u64 = 0,
    misses: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) GitCaptureCache {
        return .{ .owner_allocator = allocator };
    }

    pub fn deinit(self: *GitCaptureCache) void {
        self.reset();
    }

    pub fn reset(self: *GitCaptureCache) void {
        if (self.cwd.len > 0) {
            self.owner_allocator.free(self.cwd);
            self.cwd = &.{};
        }
        if (self.status) |s| {
            self.owner_allocator.free(s);
            self.status = null;
        }
        if (self.diff) |s| {
            self.owner_allocator.free(s);
            self.diff = null;
        }
        if (self.repo_map) |s| {
            self.owner_allocator.free(s);
            self.repo_map = null;
        }
        self.fingerprint = 0;
        self.has_entry = false;
    }
};

pub fn gather(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    user_prompt: []const u8,
    snapshot: *const types.SessionSnapshot,
    capture_cache: ?*GitCaptureCache,
) ![]types.ContextBlock {
    var blocks = std.array_list.Managed(types.ContextBlock).init(allocator);
    errdefer freeBlocks(allocator, blocks.items);

    const now = clock.nowSeconds();
    const include_repo_context = shouldIncludeRepoContext(user_prompt);

    if (include_repo_context) {
        const captures = try obtainGitCaptures(allocator, cwd, capture_cache);
        defer captures.deinit(allocator);

        if (captures.status) |status| {
            try appendBlock(allocator, &blocks, "git-status", .git_status, 95, status, now);
        }
        if (captures.diff) |diff| {
            try appendBlock(allocator, &blocks, "git-diff", .git_diff, 92, diff, now);
        }
        if (captures.repo_map) |repo_map| {
            try appendBlock(allocator, &blocks, "repo-map", .repo_map, 85, repo_map, now);
        }
    }

    try addPromptReferencedFiles(allocator, &blocks, cwd, user_prompt, now);
    try addSessionMemory(allocator, &blocks, snapshot, now);
    try addRecentToolOutcomes(allocator, &blocks, snapshot, now);
    try addToolReferencedFiles(allocator, &blocks, cwd, snapshot, now);
    try addWorkspaceDirs(allocator, &blocks, now);

    std.mem.sort(types.ContextBlock, blocks.items, {}, lessThan);
    return blocks.toOwnedSlice();
}

fn appendBlock(
    allocator: std.mem.Allocator,
    blocks: *std.array_list.Managed(types.ContextBlock),
    id: []const u8,
    source: types.ContextSource,
    priority: u8,
    content: []const u8,
    freshness: i64,
) !void {
    // Stage the two dupes so a content-OOM doesn't leak id, and a
    // blocks-append OOM doesn't leak either.
    try blocks.ensureUnusedCapacity(1);
    const dup_id = try allocator.dupe(u8, id);
    errdefer allocator.free(dup_id);
    const dup_content = try allocator.dupe(u8, content);
    blocks.appendAssumeCapacity(.{
        .id = dup_id,
        .source_type = source,
        .priority = priority,
        .token_estimate = types.estimateTokens(content),
        .content = dup_content,
        .freshness = freshness,
    });
}

// Claude Code's context.ts getGitStatus assembles a rich multi-field
// snapshot that the model leans on for branch-aware reasoning (PR vs
// main, whose commits to follow, what's dirty right now). zcode used
// to inject only `git status --short --branch`, which left the model
// guessing about the main branch and recent commits. We now capture
// the same six fields (header, current branch, main branch, git user,
// status, recent commits) and format them to match context.ts line
// 96-103 so prompts read identically between the two tools.
//
// The 2_000-char cap on the short-status output matches
// MAX_STATUS_CHARS in context.ts:21. Recent commits are capped at
// five entries, same as the reference.
const MAX_GIT_STATUS_CHARS: usize = 2_000;

fn captureGitStatus(allocator: std.mem.Allocator, cwd: []const u8) !?[]u8 {
    const branch = try captureGitBranch(allocator, cwd);
    defer if (branch) |b| allocator.free(b);
    // No branch = not a git repo (or rev-parse failed). Skip the whole
    // block instead of emitting a stub, matching the reference's early
    // `if (!isGit) return null` at context.ts:48.
    if (branch == null) return null;

    const main_branch = try captureGitMainBranch(allocator, cwd);
    defer if (main_branch) |b| allocator.free(b);

    const user_name = try captureGitUserName(allocator, cwd);
    defer if (user_name) |n| allocator.free(n);

    const short_status = try captureGitShortStatus(allocator, cwd);
    defer if (short_status) |s| allocator.free(s);

    const recent_commits = try captureGitRecentCommits(allocator, cwd);
    defer if (recent_commits) |c| allocator.free(c);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("This is the git status at the start of the conversation. Note that this status is a snapshot in time, and will not update during the conversation.\n\n");
    try w.print("Current branch: {s}\n", .{branch.?});
    if (main_branch) |m| {
        try w.print("Main branch (you will usually use this for PRs): {s}\n", .{m});
    }
    if (user_name) |n| {
        try w.print("Git user: {s}\n", .{n});
    }
    try w.writeAll("\nStatus:\n");
    if (short_status) |s| {
        if (s.len == 0) {
            try w.writeAll("(clean)\n");
        } else if (s.len > MAX_GIT_STATUS_CHARS) {
            try w.writeAll(s[0..MAX_GIT_STATUS_CHARS]);
            try w.writeAll("\n... (truncated because it exceeds 2k characters. If you need more information, run \"git status\" using the shell tool)\n");
        } else {
            try w.writeAll(s);
            if (!std.mem.endsWith(u8, s, "\n")) try w.writeByte('\n');
        }
    } else {
        try w.writeAll("(clean)\n");
    }

    if (recent_commits) |c| {
        if (c.len > 0) {
            try w.writeAll("\nRecent commits:\n");
            try w.writeAll(c);
            if (!std.mem.endsWith(u8, c, "\n")) try w.writeByte('\n');
        }
    }

    return @as(?[]u8, try out.toOwnedSlice());
}

fn captureGitBranch(allocator: std.mem.Allocator, cwd: []const u8) !?[]u8 {
    // Fast path: read the branch directly from `.git/HEAD` without spawning
    // git. Returns null on a detached HEAD or any read failure, so we fall
    // back to the subprocess path (which reports "HEAD" when detached and
    // works for edge cases the direct reader does not cover).
    if (git_fs.currentBranch(allocator, cwd)) |branch| return branch;
    return runGitCapture(allocator, &.{ "git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD" }, 256);
}

fn captureGitMainBranch(allocator: std.mem.Allocator, cwd: []const u8) !?[]u8 {
    // symbolic-ref to origin/HEAD is the canonical way to find the
    // remote's default branch; it reads refs/remotes/origin/HEAD which
    // is set by `git clone` and `git remote set-head`. Falls back to
    // scanning for a local main/master when origin/HEAD isn't set
    // (e.g. shallow checkouts, bare local repos).
    if (try runGitCapture(allocator, &.{ "git", "-C", cwd, "symbolic-ref", "refs/remotes/origin/HEAD", "--short" }, 256)) |raw| {
        defer allocator.free(raw);
        // Output looks like "origin/main"; strip the "origin/" prefix
        // so the model sees just "main".
        if (std.mem.startsWith(u8, raw, "origin/")) {
            return try allocator.dupe(u8, raw["origin/".len..]);
        }
        return try allocator.dupe(u8, raw);
    }

    for ([_][]const u8{ "main", "master" }) |candidate| {
        const args = [_][]const u8{ "git", "-C", cwd, "rev-parse", "--verify", "--quiet", candidate };
        const result = std.process.run(allocator, rt.io, .{
            .argv = &args,
            .stdout_limit = .limited(128),
            .stderr_limit = .limited(128),
        }) catch continue;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code == 0) return try allocator.dupe(u8, candidate),
            else => continue,
        }
    }
    return null;
}

fn captureGitUserName(allocator: std.mem.Allocator, cwd: []const u8) !?[]u8 {
    return runGitCapture(allocator, &.{ "git", "-C", cwd, "config", "user.name" }, 256);
}

fn captureGitShortStatus(allocator: std.mem.Allocator, cwd: []const u8) !?[]u8 {
    return runGitCapture(allocator, &.{ "git", "-C", cwd, "--no-optional-locks", "status", "--short" }, 32 * 1024);
}

fn captureGitRecentCommits(allocator: std.mem.Allocator, cwd: []const u8) !?[]u8 {
    return runGitCapture(allocator, &.{ "git", "-C", cwd, "--no-optional-locks", "log", "--oneline", "-n", "5" }, 8 * 1024);
}

/// Captures returned by `obtainGitCaptures`. Each field is
/// caller-allocator-owned so the consumer can hand them straight
/// to `appendBlock`. `deinit` frees whichever ones were populated.
const Captures = struct {
    status: ?[]u8 = null,
    diff: ?[]u8 = null,
    repo_map: ?[]u8 = null,

    fn deinit(self: Captures, allocator: std.mem.Allocator) void {
        if (self.status) |s| allocator.free(s);
        if (self.diff) |s| allocator.free(s);
        if (self.repo_map) |s| allocator.free(s);
    }
};

fn dupeOpt(allocator: std.mem.Allocator, maybe: ?[]const u8) !?[]u8 {
    if (maybe) |s| return try allocator.dupe(u8, s);
    return null;
}

/// Compute a cheap (stat-only) fingerprint for the working tree
/// state. Inputs: `.git/index`, `.git/HEAD`, and `cwd` directory
/// mtimes/sizes. Covers the common mutation paths:
///   - staged changes -> index mtime bump
///   - branch switch -> HEAD mtime bump
///   - file add/remove/rename -> cwd dir mtime bump
/// Missing files (not a git repo) contribute zero to the hash;
/// the resulting fingerprint is still stable across repeated
/// calls as long as the "missing" state persists.
fn computeGitFingerprint(allocator: std.mem.Allocator, cwd: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0x67697400); // "git\0"

    const index_path = std.fs.path.join(allocator, &.{ cwd, ".git", "index" }) catch return hasher.final();
    defer allocator.free(index_path);
    hashStatInto(&hasher, index_path, "index");

    const head_path = std.fs.path.join(allocator, &.{ cwd, ".git", "HEAD" }) catch return hasher.final();
    defer allocator.free(head_path);
    hashStatInto(&hasher, head_path, "HEAD");

    hashStatInto(&hasher, cwd, "cwd");

    return hasher.final();
}

fn hashStatInto(hasher: *std.hash.Wyhash, path: []const u8, tag: []const u8) void {
    const stat = std.Io.Dir.cwd().statFile(rt.io, path, .{}) catch return;
    hasher.update(tag);
    var scratch: [24]u8 = undefined;
    std.mem.writeInt(u64, scratch[0..8], @bitCast(stat.size), .little);
    std.mem.writeInt(i128, scratch[8..24], stat.mtime.toNanoseconds(), .little);
    hasher.update(&scratch);
}

/// Run git-status, git-diff-summary, and repo-map captures,
/// hitting `cache` first when supplied. On cache hit the cached
/// bytes are duped into the caller's allocator so the caller can
/// free them alongside any other per-turn strings without
/// touching the pinned cache copy.
fn obtainGitCaptures(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    cache: ?*GitCaptureCache,
) !Captures {
    if (cache) |c| {
        const fp = computeGitFingerprint(allocator, cwd);
        if (c.has_entry and c.fingerprint == fp and std.mem.eql(u8, c.cwd, cwd)) {
            c.hits += 1;
            return .{
                .status = try dupeOpt(allocator, c.status),
                .diff = try dupeOpt(allocator, c.diff),
                .repo_map = try dupeOpt(allocator, c.repo_map),
            };
        }
        c.misses += 1;
    }

    var out = Captures{
        .status = try captureGitStatus(allocator, cwd),
        .diff = try captureGitDiffSummary(allocator, cwd),
        .repo_map = try captureRepoMap(allocator, cwd),
    };
    errdefer out.deinit(allocator);

    if (cache) |c| {
        c.reset();
        const cwd_copy = try c.owner_allocator.dupe(u8, cwd);
        errdefer c.owner_allocator.free(cwd_copy);
        const status_copy = try dupeOpt(c.owner_allocator, out.status);
        errdefer if (status_copy) |s| c.owner_allocator.free(s);
        const diff_copy = try dupeOpt(c.owner_allocator, out.diff);
        errdefer if (diff_copy) |s| c.owner_allocator.free(s);
        const map_copy = try dupeOpt(c.owner_allocator, out.repo_map);
        c.cwd = cwd_copy;
        c.status = status_copy;
        c.diff = diff_copy;
        c.repo_map = map_copy;
        c.fingerprint = computeGitFingerprint(allocator, cwd);
        c.has_entry = true;
    }

    return out;
}

fn runGitCapture(allocator: std.mem.Allocator, argv: []const []const u8, max_bytes: usize) !?[]u8 {
    const result = std.process.run(allocator, rt.io, .{
        .argv = argv,
        .stdout_limit = .limited(max_bytes),
        .stderr_limit = .limited(max_bytes),
    }) catch return null;
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                allocator.free(result.stdout);
                return null;
            }
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

    // Return an owned copy of the trimmed slice so the caller frees
    // exactly what they're using.
    const owned = try allocator.dupe(u8, trimmed);
    allocator.free(result.stdout);
    return owned;
}

fn captureRepoMap(allocator: std.mem.Allocator, cwd: []const u8) !?[]u8 {
    const args = [_][]const u8{ "git", "-C", cwd, "ls-files" };
    const result = std.process.run(allocator, rt.io, .{
        .argv = &args,
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch |err| switch (err) {
        // On very large monorepos `ls-files` can exceed the 256 KiB cap.
        // Rather than dropping the entire repo map block (which silently
        // degrades the prompt's context), emit a truncation stub so the
        // model knows the repo map was omitted rather than assumed empty.
        error.StreamTooLong => return try allocator.dupe(
            u8,
            "(repo map truncated: > 256KB of filenames; use list_dir for specific directories)",
        ),
        else => return null,
    };
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                allocator.free(result.stdout);
                return null;
            }
        },
        else => {
            allocator.free(result.stdout);
            return null;
        },
    }

    // Load .zcodeignore patterns from project root.
    const ignore_patterns = loadIgnorePatterns(allocator, cwd);
    defer {
        for (ignore_patterns) |p| allocator.free(p);
        allocator.free(ignore_patterns);
    }

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (matchesIgnorePatterns(line, ignore_patterns)) continue;
        try out.writer().print("{s}\n", .{line});
        count += 1;
        if (count >= 200) break;
    }

    allocator.free(result.stdout);
    if (out.items().len == 0) return null;
    const owned = try out.toOwnedSlice();
    return owned;
}

fn loadIgnorePatterns(allocator: std.mem.Allocator, cwd: []const u8) [][]u8 {
    const ignore_path = paths.workspaceIgnorePath(allocator, cwd) catch return &.{};
    defer allocator.free(ignore_path);

    const content = std.Io.Dir.cwd().readFileAlloc(rt.io, ignore_path, allocator, .limited(64 * 1024)) catch return allocator.alloc([]u8, 0) catch return &.{};
    defer allocator.free(content);

    var patterns = std.array_list.Managed([]u8).init(allocator);
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;
        patterns.append(allocator.dupe(u8, line) catch continue) catch continue;
    }
    return patterns.toOwnedSlice() catch return &.{};
}

fn matchesIgnorePatterns(path: []const u8, patterns: []const []const u8) bool {
    for (patterns) |pattern| {
        if (matchIgnoreGlob(path, pattern)) return true;
    }
    return false;
}

fn matchIgnoreGlob(path: []const u8, pattern: []const u8) bool {
    // Directory prefix match: "dir/" matches any path starting with "dir/"
    if (pattern.len > 0 and pattern[pattern.len - 1] == '/') {
        return std.mem.startsWith(u8, path, pattern) or blk: {
            // Also match embedded directory: "foo/dir/bar"
            var buf: [1024]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buf);
            const search = std.fmt.allocPrint(fba.allocator(), "/{s}", .{pattern}) catch return false;
            break :blk std.mem.indexOf(u8, path, search) != null;
        };
    }

    // Extension glob: "*.ext" matches any file ending with ".ext"
    if (pattern.len > 2 and pattern[0] == '*' and pattern[1] == '.') {
        const ext = pattern[1..]; // ".ext"
        return std.mem.endsWith(u8, path, ext);
    }

    // Exact basename match: "filename" matches the last component
    if (std.mem.indexOfScalar(u8, pattern, '/') == null) {
        const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx|
            path[idx + 1 ..]
        else
            path;
        return std.mem.eql(u8, basename, pattern);
    }

    // Literal path match
    return std.mem.eql(u8, path, pattern);
}

fn captureGitDiffSummary(allocator: std.mem.Allocator, cwd: []const u8) !?[]u8 {
    const staged_args = [_][]const u8{ "git", "-C", cwd, "diff", "--cached", "--stat", "--summary" };
    const staged_result = std.process.run(allocator, rt.io, .{
        .argv = &staged_args,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| switch (err) {
        // Very large staged diffs exceed the 64 KiB cap. Prefer a truncation
        // stub so the model knows the diff exists rather than silently
        // treating the working tree as clean.
        error.StreamTooLong => return try allocator.dupe(
            u8,
            "(staged diff truncated: > 64KB; use git_diff tool for specific files)",
        ),
        else => return null,
    };
    defer allocator.free(staged_result.stderr);

    switch (staged_result.term) {
        .exited => |code| {
            if (code != 0) {
                allocator.free(staged_result.stdout);
                return null;
            }
        },
        else => {
            allocator.free(staged_result.stdout);
            return null;
        },
    }

    const unstaged_args = [_][]const u8{ "git", "-C", cwd, "diff", "--stat", "--summary" };
    const unstaged_result = std.process.run(allocator, rt.io, .{
        .argv = &unstaged_args,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch {
        allocator.free(staged_result.stdout);
        return null;
    };
    defer allocator.free(unstaged_result.stderr);

    switch (unstaged_result.term) {
        .exited => |code| {
            if (code != 0) {
                allocator.free(staged_result.stdout);
                allocator.free(unstaged_result.stdout);
                return null;
            }
        },
        else => {
            allocator.free(staged_result.stdout);
            allocator.free(unstaged_result.stdout);
            return null;
        },
    }

    if (staged_result.stdout.len == 0 and unstaged_result.stdout.len == 0) {
        allocator.free(staged_result.stdout);
        allocator.free(unstaged_result.stdout);
        return null;
    }

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    if (staged_result.stdout.len > 0) {
        try out.writer().writeAll("staged_diff:\n");
        try out.appendSlice(staged_result.stdout);
        if (!std.mem.endsWith(u8, staged_result.stdout, "\n")) try out.append('\n');
    }

    if (unstaged_result.stdout.len > 0) {
        try out.writer().writeAll("unstaged_diff:\n");
        try out.appendSlice(unstaged_result.stdout);
        if (!std.mem.endsWith(u8, unstaged_result.stdout, "\n")) try out.append('\n');
    }

    allocator.free(staged_result.stdout);
    allocator.free(unstaged_result.stdout);
    const owned = try out.toOwnedSlice();
    return owned;
}

fn addPromptReferencedFiles(
    allocator: std.mem.Allocator,
    blocks: *std.array_list.Managed(types.ContextBlock),
    cwd: []const u8,
    prompt: []const u8,
    now: i64,
) !void {
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen.deinit();
    }

    var words = std.mem.tokenizeAny(u8, prompt, " \t\n\r,;:()[]{}");
    while (words.next()) |word| {
        if (!looksLikePath(word)) continue;
        // Block absolute paths and `..` traversal so a prompt cannot make
        // zcode read `/etc/passwd` or `../../secrets.env` into the model
        // context. See resolveReferencedFile for details.
        const abs = resolveReferencedFile(allocator, cwd, word) catch continue;
        defer allocator.free(abs);

        const key = try allocator.dupe(u8, word);
        if (seen.contains(key)) {
            allocator.free(key);
            continue;
        }

        const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, abs, allocator, .limited(8 * 1024)) catch {
            allocator.free(key);
            continue;
        };

        const block_id = try std.fmt.allocPrint(allocator, "file:{s}", .{word});
        defer allocator.free(block_id);
        const body = try std.fmt.allocPrint(allocator, "# File: {s}\n{s}", .{ word, bytes });

        try appendBlock(allocator, blocks, block_id, .user_file, 90, body, now);

        allocator.free(bytes);
        allocator.free(body);
        try seen.put(key, {});

        if (blocks.items.len > 24) break;
    }
}

/// Resolve a user-supplied path token into an absolute path, but only if it
/// is safely contained inside `cwd`. Rejects absolute paths, `..` traversal,
/// and anything that canonicalizes outside the workspace. Returns an allocated
/// absolute path on success, or an error if the reference should be skipped.
fn resolveReferencedFile(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    if (path.len == 0) return error.InvalidReference;
    if (std.fs.path.isAbsolute(path)) return error.InvalidReference;
    if (std.mem.startsWith(u8, path, "~")) return error.InvalidReference;

    var segments = std.mem.splitAny(u8, path, "/\\");
    while (segments.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return error.InvalidReference;
    }

    const joined = try std.fs.path.join(allocator, &.{ cwd, path });
    // Best-effort symlink resolution to catch a link that would escape cwd.
    // If the file does not exist (realpath errors), we fall back to the
    // joined path; any later open will simply fail with FileNotFound and
    // is still contained by the earlier absolute/`..` checks.
    if (allocator.dupe(u8, joined)) |resolved| {
        allocator.free(joined);
        errdefer allocator.free(resolved);
        const cwd_resolved = allocator.dupe(u8, cwd) catch {
            return resolved;
        };
        defer allocator.free(cwd_resolved);
        if (!std.mem.startsWith(u8, resolved, cwd_resolved)) {
            allocator.free(resolved);
            return error.InvalidReference;
        }
        if (resolved.len > cwd_resolved.len and resolved[cwd_resolved.len] != std.fs.path.sep) {
            allocator.free(resolved);
            return error.InvalidReference;
        }
        return resolved;
    } else |_| {
        return joined;
    }
}

fn addSessionMemory(
    allocator: std.mem.Allocator,
    blocks: *std.array_list.Managed(types.ContextBlock),
    snapshot: *const types.SessionSnapshot,
    now: i64,
) !void {
    if (snapshot.handoff_summary.len == 0 and snapshot.open_tasks.len == 0 and
        snapshot.decisions.len == 0 and snapshot.facts.len == 0 and
        snapshot.pinned_facts.len == 0 and snapshot.completed_tasks.len == 0)
    {
        return;
    }

    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();

    // Pinned facts always come first (highest signal, survive all compactions)
    if (snapshot.pinned_facts.len > 0) {
        try buf.writer().writeAll("pinned_facts (always active):\n");
        for (snapshot.pinned_facts) |item| {
            try buf.writer().print("- {s}\n", .{item});
        }
    }

    try buf.writer().print("handoff_summary: {s}\n", .{snapshot.handoff_summary});

    if (snapshot.facts.len > 0) {
        try buf.writer().writeAll("facts:\n");
        for (snapshot.facts) |item| {
            try buf.writer().print("- {s}\n", .{item});
        }
    }

    if (snapshot.decisions.len > 0) {
        try buf.writer().writeAll("decisions:\n");
        for (snapshot.decisions) |item| {
            try buf.writer().print("- {s}\n", .{item});
        }
    }

    if (snapshot.open_tasks.len > 0) {
        try buf.writer().writeAll("open_tasks:\n");
        for (snapshot.open_tasks) |item| {
            try buf.writer().print("- {s}\n", .{item});
        }
    }

    if (snapshot.completed_tasks.len > 0) {
        try buf.writer().writeAll("recently_completed:\n");
        for (snapshot.completed_tasks) |item| {
            try buf.writer().print("- {s}\n", .{item});
        }
    }

    const owned = try buf.toOwnedSlice();
    defer allocator.free(owned);
    try appendBlock(allocator, blocks, "session-memory", .session_memory, 88, owned, now);
}

fn addWorkspaceDirs(
    allocator: std.mem.Allocator,
    blocks: *std.array_list.Managed(types.ContextBlock),
    now: i64,
) !void {
    // Hot path: called every model turn. The common case is that
    // the user has never run /add-dir, so the sidecar file does
    // not exist. Check that first with a single stat to skip the
    // readFileAlloc + parse path entirely.
    const path = workspace_dirs.listFilePath(allocator) catch return;
    defer allocator.free(path);
    std.Io.Dir.cwd().access(rt.io, path, .{}) catch return;

    const list = workspace_dirs.load(allocator) catch return;
    defer workspace_dirs.freeList(allocator, list);
    if (list.len == 0) return;

    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    try buf.writer().writeAll("The user has registered these additional workspace directories. You may read and edit files under any of them as first-class workspace roots:\n");
    for (list) |p| try buf.writer().print("- {s}\n", .{p});

    const owned = try buf.toOwnedSlice();
    defer allocator.free(owned);
    try appendBlock(allocator, blocks, "workspace-dirs", .session_memory, 80, owned, now);
}

fn addRecentToolOutcomes(
    allocator: std.mem.Allocator,
    blocks: *std.array_list.Managed(types.ContextBlock),
    snapshot: *const types.SessionSnapshot,
    now: i64,
) !void {
    if (snapshot.recent_tool_outcomes.len == 0) return;

    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();

    for (snapshot.recent_tool_outcomes) |item| {
        try buf.writer().print("- {s}\n", .{item});
    }

    const owned = try buf.toOwnedSlice();
    defer allocator.free(owned);
    try appendBlock(allocator, blocks, "recent-tools", .tool_result, 82, owned, now);
}

fn addToolReferencedFiles(
    allocator: std.mem.Allocator,
    blocks: *std.array_list.Managed(types.ContextBlock),
    cwd: []const u8,
    snapshot: *const types.SessionSnapshot,
    now: i64,
) !void {
    if (snapshot.recent_tool_outcomes.len == 0) return;

    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen.deinit();
    }

    var count: usize = 0;
    for (snapshot.recent_tool_outcomes) |item| {
        var start: usize = 0;
        while (std.mem.indexOfPos(u8, item, start, "path=")) |idx| {
            const value_start = idx + "path=".len;
            var value_end = value_start;
            while (value_end < item.len and item[value_end] != '\n' and item[value_end] != ';' and item[value_end] != ' ') : (value_end += 1) {}
            const path = std.mem.trim(u8, item[value_start..value_end], " \t\"'");
            start = value_end;
            if (path.len == 0) continue;
            if (!looksLikePath(path)) continue;
            if (seen.contains(path)) continue;

            // Contain the reference to the workspace. A malicious tool
            // output could otherwise embed a path=/etc/passwd token and
            // have zcode auto-inject the file into the next prompt.
            const abs = resolveReferencedFile(allocator, cwd, path) catch continue;
            defer allocator.free(abs);

            const key = try allocator.dupe(u8, path);
            try seen.put(key, {});

            const line_hint = extractLineHint(item);
            const body = if (line_hint) |line|
                readFileExcerptAroundLine(allocator, abs, path, line, 20) catch blk: {
                    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, abs, allocator, .limited(6 * 1024)) catch continue;
                    defer allocator.free(bytes);
                    break :blk try std.fmt.allocPrint(allocator, "# File (recent tool focus): {s}\n{s}", .{ path, bytes });
                }
            else blk: {
                const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, abs, allocator, .limited(6 * 1024)) catch continue;
                defer allocator.free(bytes);
                break :blk try std.fmt.allocPrint(allocator, "# File (recent tool focus): {s}\n{s}", .{ path, bytes });
            };
            defer allocator.free(body);
            const block_id = try std.fmt.allocPrint(allocator, "tool-file:{s}", .{path});
            defer allocator.free(block_id);
            try appendBlock(allocator, blocks, block_id, .user_file, 86, body, now);

            count += 1;
            if (count >= 8) return;
        }
    }
}

fn extractLineHint(text: []const u8) ?usize {
    const marker = " at line ";
    const idx = std.mem.indexOf(u8, text, marker) orelse return null;
    var start = idx + marker.len;
    while (start < text.len and text[start] == ' ') : (start += 1) {}
    var end = start;
    while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(usize, text[start..end], 10) catch null;
}

fn readFileExcerptAroundLine(
    allocator: std.mem.Allocator,
    abs_path: []const u8,
    display_path: []const u8,
    line: usize,
    radius: usize,
) ![]u8 {
    if (line == 0) return error.InvalidLine;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(rt.io, abs_path, allocator, .limited(512 * 1024));
    defer allocator.free(bytes);

    const start_line = if (line > radius) line - radius else 1;
    const end_line = line + radius;

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    try out.writer().print(
        "# File excerpt (recent edit focus): {s}\nline_window={d}-{d} target_line={d}\n",
        .{ display_path, start_line, end_line, line },
    );

    var current_line: usize = 1;
    var pos: usize = 0;
    while (pos <= bytes.len) {
        const next = std.mem.indexOfScalarPos(u8, bytes, pos, '\n') orelse bytes.len;
        if (current_line >= start_line and current_line <= end_line) {
            const marker: []const u8 = if (current_line == line) ">" else " ";
            try out.writer().print("{s}{d}\t{s}\n", .{ marker, current_line, bytes[pos..next] });
        }
        if (current_line > end_line or next == bytes.len) break;
        pos = next + 1;
        current_line += 1;
    }
    return out.toOwnedSlice();
}

const looksLikePath = parse_helpers.looksLikePath;

fn shouldIncludeRepoContext(prompt: []const u8) bool {
    if (prompt.len == 0) return true;

    var words = std.mem.tokenizeAny(u8, prompt, " \t\n\r,;:()[]{}");
    while (words.next()) |word| {
        if (looksLikePath(word)) return true;
    }

    const code_cues = [_][]const u8{
        "repo",
        "repository",
        "file",
        "files",
        "src/",
        "test",
        "build",
        "compile",
        "code",
        "function",
        "module",
        "branch",
        "commit",
        "diff",
        "pull request",
        "extension",
    };
    for (code_cues) |cue| {
        if (parse_helpers.containsIgnoreCase(prompt, cue)) return true;
    }

    const external_ops_cues = [_][]const u8{
        "ollama",
        "olama",
        "spark server",
        "ssh",
        "gpu",
        "vram",
        "remote server",
        "cluster",
    };
    for (external_ops_cues) |cue| {
        if (parse_helpers.containsIgnoreCase(prompt, cue)) return false;
    }

    return true;
}

fn lessThan(_: void, a: types.ContextBlock, b: types.ContextBlock) bool {
    if (a.priority == b.priority) {
        return a.freshness > b.freshness;
    }
    return a.priority > b.priority;
}

pub fn freeBlocks(allocator: std.mem.Allocator, blocks: []types.ContextBlock) void {
    for (blocks) |block| {
        allocator.free(block.id);
        allocator.free(block.content);
    }
    allocator.free(blocks);
}

const testing = std.testing;

test "path detector" {
    try testing.expect(looksLikePath("src/main.zig"));
    try testing.expect(looksLikePath("main.rs"));
    try testing.expect(!looksLikePath("hello"));
}

test "repo context stays enabled for code prompts" {
    try testing.expect(shouldIncludeRepoContext("fix the failing zig tests in src/main.zig"));
}

test "repo context is skipped for external ops prompts" {
    try testing.expect(!shouldIncludeRepoContext("configure my local 32 billion parameter with olama on my spark server"));
}

test "extractLineHint parses edit output line numbers" {
    try testing.expectEqual(@as(?usize, 42), extractLineHint("edit ok: 1 replacement(s) in src/main.zig at line 42\n"));
    try testing.expect(extractLineHint("no line here") == null);
}

test "readFileExcerptAroundLine centers target line" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "sample.txt", .data = "one\ntwo\nthree\nfour\nfive\n" });
    const abs = try @import("test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "sample.txt");
    defer testing.allocator.free(abs);
    const excerpt = try readFileExcerptAroundLine(testing.allocator, abs, "sample.txt", 3, 1);
    defer testing.allocator.free(excerpt);
    try testing.expect(std.mem.indexOf(u8, excerpt, "line_window=2-4 target_line=3") != null);
    try testing.expect(std.mem.indexOf(u8, excerpt, ">3\tthree") != null);
    try testing.expect(std.mem.indexOf(u8, excerpt, " 2\ttwo") != null);
}

test "ignore glob extension match" {
    try testing.expect(matchIgnoreGlob("src/foo.log", "*.log"));
    try testing.expect(matchIgnoreGlob("deep/path/bar.tmp", "*.tmp"));
    try testing.expect(!matchIgnoreGlob("src/foo.zig", "*.log"));
}

test "ignore glob directory match" {
    try testing.expect(matchIgnoreGlob("node_modules/foo.js", "node_modules/"));
    try testing.expect(matchIgnoreGlob("src/node_modules/bar.js", "node_modules/"));
    try testing.expect(!matchIgnoreGlob("src/main.zig", "node_modules/"));
}

test "ignore glob basename match" {
    try testing.expect(matchIgnoreGlob("src/.DS_Store", ".DS_Store"));
    try testing.expect(matchIgnoreGlob(".DS_Store", ".DS_Store"));
    try testing.expect(!matchIgnoreGlob("src/main.zig", ".DS_Store"));
}

test "matches ignore patterns" {
    const patterns = &[_][]const u8{ "*.log", "node_modules/", ".DS_Store" };
    try testing.expect(matchesIgnorePatterns("debug.log", patterns));
    try testing.expect(matchesIgnorePatterns("node_modules/foo.js", patterns));
    try testing.expect(matchesIgnorePatterns(".DS_Store", patterns));
    try testing.expect(!matchesIgnorePatterns("src/main.zig", patterns));
}

test "captureGitStatus emits Claude Code's rich format for a repo" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // Bootstrap a minimal repo: init, configure identity, commit one file,
    // then leave the working tree dirty so the Status section has something
    // to show. Using .process.Child.run keeps the test self-contained and
    // avoids hitting the user's global git config.
    const setup_commands = [_][]const []const u8{
        &.{ "git", "-C", cwd, "init", "--initial-branch=main", "-q" },
        &.{ "git", "-C", cwd, "config", "user.email", "ci@example.test" },
        &.{ "git", "-C", cwd, "config", "user.name", "Zcode CI" },
        &.{ "git", "-C", cwd, "config", "commit.gpgsign", "false" },
    };
    for (setup_commands) |argv| {
        const r = std.process.run(testing.allocator, rt.io, .{
            .argv = argv,
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        }) catch |err| {
            // No git binary in the test env; skip rather than flake.
            if (err == error.FileNotFound) return error.SkipZigTest;
            return err;
        };
        testing.allocator.free(r.stdout);
        testing.allocator.free(r.stderr);
    }

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "first.txt", .data = "hello\n" });
    const add_and_commit = [_][]const []const u8{
        &.{ "git", "-C", cwd, "add", "first.txt" },
        &.{ "git", "-C", cwd, "commit", "-q", "-m", "initial" },
    };
    for (add_and_commit) |argv| {
        const r = try std.process.run(testing.allocator, rt.io, .{
            .argv = argv,
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        });
        testing.allocator.free(r.stdout);
        testing.allocator.free(r.stderr);
    }

    // Dirty the tree so the Status section is non-empty.
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "second.txt", .data = "world\n" });

    const rendered = (try captureGitStatus(testing.allocator, cwd)) orelse
        return error.MissingGitStatus;
    defer testing.allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "This is the git status at the start of the conversation") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "Current branch: main") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "Git user: Zcode CI") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "Status:") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "second.txt") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "Recent commits:") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "initial") != null);
}

// NB: there's no companion "returns null outside a git repo" test --
// zig's testing.tmpDir creates its scratch directory inside the zcode
// source tree, which means git walks up and finds zcode's own .git.
// The behaviour is still correct (captureGitStatus returns null when
// `git rev-parse` fails), but constructing a test environment that
// has no parent git repo is fragile and not worth the CI flake.

test "GitCaptureCache hits on a second gather with unchanged working tree" {
    const cwd_alloc = try testing.allocator.dupe(u8, ".");
    defer testing.allocator.free(cwd_alloc);

    var cache = GitCaptureCache.init(testing.allocator);
    defer cache.deinit();

    const snapshot = types.SessionSnapshot{
        .facts = &.{},
        .decisions = &.{},
        .open_tasks = &.{},
        .file_focus = &.{},
        .recent_tool_outcomes = &.{},
        .handoff_summary = "",
    };

    const first = try gather(testing.allocator, cwd_alloc, "update the git status", &snapshot, &cache);
    freeBlocks(testing.allocator, first);
    try testing.expectEqual(@as(u64, 1), cache.misses);
    try testing.expectEqual(@as(u64, 0), cache.hits);

    const second = try gather(testing.allocator, cwd_alloc, "update the git status", &snapshot, &cache);
    freeBlocks(testing.allocator, second);
    try testing.expectEqual(@as(u64, 1), cache.misses);
    try testing.expectEqual(@as(u64, 1), cache.hits);
}

test "computeGitFingerprint is stable across repeated calls on unchanged state" {
    const cwd_alloc = try testing.allocator.dupe(u8, ".");
    defer testing.allocator.free(cwd_alloc);

    const a = computeGitFingerprint(testing.allocator, cwd_alloc);
    const b = computeGitFingerprint(testing.allocator, cwd_alloc);
    try testing.expectEqual(a, b);
}
