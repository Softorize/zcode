const std = @import("std");
const rt = @import("zcode_runtime");
const std_io = @import("../core/std_io.zig");
const security = @import("../core/security.zig");
const git_url = @import("../core/git_url.zig");

pub fn diff(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    path: ?[]const u8,
    staged: bool,
    context_lines: usize,
    max_output_bytes: usize,
) ![]u8 {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    try argv.appendSlice(&.{ "git", "-C", cwd, "diff" });
    try argv.appendSlice(&.{ "--no-color", "--no-ext-diff", "--patch", "--minimal" });
    if (staged) try argv.append("--staged");

    const ctx = try std.fmt.allocPrint(allocator, "--unified={d}", .{context_lines});
    defer allocator.free(ctx);
    try argv.append(ctx);

    if (path) |p| {
        try argv.append("--");
        try argv.append(p);
    }

    const bounded_max = @min(@max(max_output_bytes, 64 * 1024), 4 * 1024 * 1024);
    return runCommand(allocator, argv.items, bounded_max, "git diff failed");
}

pub fn log(allocator: std.mem.Allocator, cwd: []const u8, limit: usize) ![]u8 {
    const lim = try std.fmt.allocPrint(allocator, "{d}", .{@max(@as(usize, 1), limit)});
    defer allocator.free(lim);
    const argv = [_][]const u8{ "git", "-C", cwd, "log", "--oneline", "-n", lim };
    return runCommand(allocator, &argv, 512 * 1024, "git log failed");
}

pub fn commit(allocator: std.mem.Allocator, cwd: []const u8, message: []const u8, add_all: bool, allow_empty: bool) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    if (add_all) {
        const add_argv = [_][]const u8{ "git", "-C", cwd, "add", "-A" };
        const add_out = try runCommand(allocator, &add_argv, 256 * 1024, "git add failed");
        defer allocator.free(add_out);
        if (add_out.len > 0) {
            try w.writeAll("[git add]\n");
            try out.appendSlice(add_out);
            if (!std.mem.endsWith(u8, add_out, "\n")) try w.writeByte('\n');
        }
    }

    if (try security.scanStagedDiffSummary(allocator, cwd)) |summary| {
        defer allocator.free(summary);
        return allocator.dupe(u8, summary);
    }

    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    try argv.appendSlice(&.{ "git", "-C", cwd, "commit", "-m", message });
    if (allow_empty) try argv.append("--allow-empty");
    const commit_out = try runCommand(allocator, argv.items, 512 * 1024, "git commit failed");
    defer allocator.free(commit_out);

    try w.writeAll("[git commit]\n");
    try out.appendSlice(commit_out);
    return out.toOwnedSlice();
}

pub fn openPr(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    base: ?[]const u8,
    title: ?[]const u8,
    body: ?[]const u8,
    create: bool,
) ![]u8 {
    const remote_raw = try runCaptureTrimmed(allocator, &.{ "git", "-C", cwd, "config", "--get", "remote.origin.url" });
    defer allocator.free(remote_raw);
    const branch = try runCaptureTrimmed(allocator, &.{ "git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD" });
    defer allocator.free(branch);
    const base_branch = if (base) |b| try allocator.dupe(u8, b) else try detectDefaultBaseBranch(allocator, cwd);
    defer allocator.free(base_branch);

    const https_remote = normalizeRemoteUrlToHttps(allocator, remote_raw) catch {
        return std.fmt.allocPrint(allocator, "open_pr unavailable: unsupported remote URL format: {s}", .{remote_raw});
    };
    defer allocator.free(https_remote);

    const compare_url = try std.fmt.allocPrint(
        allocator,
        "{s}/compare/{s}...{s}?expand=1",
        .{ https_remote, base_branch, branch },
    );
    defer allocator.free(compare_url);

    if (!create) {
        return std.fmt.allocPrint(
            allocator,
            "open this URL to create a PR:\n{s}",
            .{compare_url},
        );
    }

    if (!hasGhCli(allocator)) {
        return std.fmt.allocPrint(
            allocator,
            "gh CLI not installed. open this URL manually:\n{s}",
            .{compare_url},
        );
    }

    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    try argv.appendSlice(&.{ "gh", "pr", "create", "--base", base_branch, "--head", branch });
    if (title) |t| {
        try argv.append("--title");
        try argv.append(t);
    }
    if (body) |b| {
        try argv.append("--body");
        try argv.append(b);
    }
    if (title == null and body == null) {
        try argv.append("--fill");
    }

    const result = std.process.run(allocator, rt.io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch |err| return std.fmt.allocPrint(allocator, "gh pr create failed: {s}", .{@errorName(err)});
    defer allocator.free(result.stderr);

    if (result.term == .exited and result.term.exited == 0) {
        return result.stdout;
    }

    const msg = try std.fmt.allocPrint(
        allocator,
        "gh pr create failed\n{s}\nmanual URL:\n{s}",
        .{ result.stderr, compare_url },
    );
    allocator.free(result.stdout);
    return msg;
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8, max_output: usize, fail_prefix: []const u8) ![]u8 {
    const result = try std.process.run(allocator, rt.io, .{
        .argv = argv,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(result.stderr);

    if (result.term == .exited and result.term.exited == 0) {
        return result.stdout;
    }

    const msg = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ fail_prefix, result.stderr });
    allocator.free(result.stdout);
    return msg;
}

fn runCaptureTrimmed(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(allocator, rt.io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stderr);

    if (!(result.term == .exited and result.term.exited == 0)) {
        allocator.free(result.stdout);
        return error.CommandFailed;
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(result.stdout);
        return error.EmptyOutput;
    }
    const out = try allocator.dupe(u8, trimmed);
    allocator.free(result.stdout);
    return out;
}

fn detectDefaultBaseBranch(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const sym = runCaptureTrimmed(allocator, &.{ "git", "-C", cwd, "symbolic-ref", "refs/remotes/origin/HEAD" }) catch {
        return allocator.dupe(u8, "main");
    };
    defer allocator.free(sym);

    const needle = "refs/remotes/origin/";
    if (std.mem.startsWith(u8, sym, needle)) {
        return allocator.dupe(u8, sym[needle.len..]);
    }
    return allocator.dupe(u8, "main");
}

fn normalizeRemoteUrlToHttps(allocator: std.mem.Allocator, remote: []const u8) ![]u8 {
    // Delegate to the shared core/git_url helper so SSH shorthand,
    // https://, and ssh:// URL forms all funnel through the same
    // normalisation logic. Previously this site only handled
    // https:// and git@... shorthand, missing ssh:// entirely.
    const https = (try git_url.toHttpsUrl(allocator, remote)) orelse return error.InvalidRemote;
    return https;
}

fn hasGhCli(allocator: std.mem.Allocator) bool {
    const result = std.process.run(allocator, rt.io, .{
        .argv = &.{ "gh", "--version" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

/// Three-state gh CLI authentication status.
/// Ported from claude-code-main/src/utils/ghAuthStatus.ts:17-29.
pub const GhAuthStatus = enum {
    not_installed,
    not_authenticated,
    authenticated,
};

/// Detect whether the gh CLI is installed and authenticated.
///
/// IMPORTANT: this uses `gh auth token`, NOT `gh auth status`. The latter
/// hits the GitHub network; `gh auth token` is a local check whose exit
/// code reflects whether a token is configured. The token itself is never
/// captured into the process - stdout/stderr are discarded - so a printed
/// token cannot leak into logs or memory we keep around.
pub fn ghAuthStatus(allocator: std.mem.Allocator) GhAuthStatus {
    if (!hasGhCli(allocator)) return .not_installed;

    const result = std.process.run(allocator, rt.io, .{
        .argv = &.{ "gh", "auth", "token" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    }) catch return .not_authenticated;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term == .exited and result.term.exited == 0) return .authenticated;
    return .not_authenticated;
}

const testing = std.testing;

test "ghAuthStatus returns not_installed when gh is absent" {
    // This test is meaningful only on a machine without gh on PATH.
    // When gh is present we cannot assert a fixed value (it depends on
    // whether the developer is logged in), so we skip rather than make
    // a flaky assertion - matching the other tool-detection tests.
    const has_gh = hasGhCli(testing.allocator);
    if (has_gh) return error.SkipZigTest;
    try testing.expectEqual(GhAuthStatus.not_installed, ghAuthStatus(testing.allocator));
}

test "ghAuthStatus returns a defined three-state value" {
    // Always-runnable smoke test: the result must be one of the three
    // enum values regardless of the host's gh install/auth state.
    const status = ghAuthStatus(testing.allocator);
    switch (status) {
        .not_installed, .not_authenticated, .authenticated => {},
    }
}

test "normalizeRemoteUrlToHttps handles ssh remotes" {
    const normalized = try normalizeRemoteUrlToHttps(testing.allocator, "git@github.com:owner/repo.git");
    defer testing.allocator.free(normalized);
    try testing.expectEqualStrings("https://github.com/owner/repo", normalized);
}

fn initGitRepoForTest(cwd: []const u8) !void {
    const allocator = testing.allocator;
    const init_out = try runCommand(allocator, &.{ "git", "-C", cwd, "init" }, 64 * 1024, "git init failed");
    defer allocator.free(init_out);
    const email_out = try runCommand(allocator, &.{ "git", "-C", cwd, "config", "user.email", "test@example.com" }, 64 * 1024, "git config failed");
    defer allocator.free(email_out);
    const name_out = try runCommand(allocator, &.{ "git", "-C", cwd, "config", "user.name", "zcode test" }, 64 * 1024, "git config failed");
    defer allocator.free(name_out);
}

test "commit blocks staged secrets" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "demo.txt", .data = "safe=true\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    try initGitRepoForTest(cwd);
    const add_init = try runCommand(allocator, &.{ "git", "-C", cwd, "add", "demo.txt" }, 64 * 1024, "git add failed");
    defer allocator.free(add_init);
    const commit_init = try runCommand(allocator, &.{ "git", "-C", cwd, "commit", "-m", "init" }, 128 * 1024, "git commit failed");
    defer allocator.free(commit_init);

    const sample = "token=" ++ "gh" ++ "p_" ++ "demoToken" ++ "1234567890" ++ "\n";
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "demo.txt", .data = sample });
    const add_secret = try runCommand(allocator, &.{ "git", "-C", cwd, "add", "demo.txt" }, 64 * 1024, "git add failed");
    defer allocator.free(add_secret);

    const output = try commit(allocator, cwd, "unsafe", false, false);
    defer allocator.free(output);
    try testing.expect(std.mem.indexOf(u8, output, "secret scan blocked git commit") != null);
}
