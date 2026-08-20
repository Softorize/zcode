//! Gitignore helpers ported from claude-code-main/src/utils/gitignore.ts.
//!
//! Three small operations:
//!   - isPathGitignored: ask git whether a path is ignored (subprocess).
//!   - getGlobalGitignorePath: the conventional ~/.config/git/ignore path.
//!   - addFileGlobRuleToGitignore: append a `**/<file>` rule to the global
//!     gitignore, idempotently.
//!
//! All operations are best-effort: per the reference's `logError` non-fatal
//! contract, a git invocation that cannot run (git missing, not a repo, IO
//! failure) is treated as "not ignored" / "could not write" rather than an
//! error that bubbles up to the caller. The CLI must never crash because a
//! gitignore probe failed.

const std = @import("std");
const rt = @import("zcode_runtime");
const xdg = @import("xdg.zig");
const paths = @import("paths.zig");

/// True when `git check-ignore` reports `path` as ignored inside the repo at
/// `cwd`.
///
/// `git check-ignore <path>` exits:
///   0   -> path IS ignored
///   1   -> path is NOT ignored
///   128 -> fatal (not a git repo, bad args, ...)
///
/// Any non-zero exit (including 128) and any failure to spawn git is treated
/// as "not ignored" -- we fail open so a probe never blocks an action.
pub fn isPathGitignored(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) bool {
    const result = std.process.run(allocator, rt.io, .{
        .argv = &.{ "git", "check-ignore", "--quiet", path },
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return result.term == .exited and result.term.exited == 0;
}

/// The conventional global gitignore path: `$HOME/.config/git/ignore`.
/// Mirrors the reference's `getGlobalGitignorePath`. Caller owns the slice.
pub fn getGlobalGitignorePath(allocator: std.mem.Allocator) ![]u8 {
    const config_home = try xdg.getConfigHome(allocator);
    defer allocator.free(config_home);
    return std.fs.path.join(allocator, &.{ config_home, "git", "ignore" });
}

/// Append a `**/<filename>` rule to the global gitignore, idempotently.
///
/// Steps (matching the reference `addFileGlobRuleToGitignore`):
///   1. If `filename` is already ignored at `cwd`, do nothing.
///   2. Ensure the global gitignore's parent dir exists.
///   3. Read the existing file (treat missing as empty), and append
///      `\n**/<filename>\n` only when that exact rule line is not already
///      present.
///
/// Best-effort: returns void and swallows IO errors after logging would be a
/// no-op here (the caller does not care whether the write succeeded -- it is a
/// convenience). The only thing we never want is to duplicate the rule.
pub fn addFileGlobRuleToGitignore(
    allocator: std.mem.Allocator,
    filename: []const u8,
    cwd: []const u8,
) void {
    // 1. Already ignored? Nothing to do.
    if (isPathGitignored(allocator, cwd, filename)) return;

    const rule = std.fmt.allocPrint(allocator, "**/{s}", .{filename}) catch return;
    defer allocator.free(rule);

    const ignore_path = getGlobalGitignorePath(allocator) catch return;
    defer allocator.free(ignore_path);

    // 2. Ensure the parent directory exists.
    if (std.fs.path.dirname(ignore_path)) |dir| {
        paths.ensureDir(dir) catch return;
    }

    // 3. Read existing contents (missing file == empty), and check for the
    //    exact rule on its own line so a second call is a no-op.
    const existing = readFileBestEffort(allocator, ignore_path) catch return;
    defer allocator.free(existing);

    if (ruleAlreadyPresent(existing, rule)) return;

    appendRule(allocator, ignore_path, existing, rule) catch return;
}

/// Read a file, returning an owned empty slice when it does not exist.
/// An oversize gitignore (over 1 MiB) yields error.StreamTooLong per the 0.16
/// readFileAlloc contract; we propagate it so we never partially overwrite a
/// pathological file.
fn readFileBestEffort(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => allocator.alloc(u8, 0),
        else => err,
    };
}

/// True when `rule` already appears as a complete line in `contents`.
/// Splitting on '\n' and comparing trimmed lines avoids a substring false
/// positive (e.g. `**/foo` matching inside `**/foobar`).
fn ruleAlreadyPresent(contents: []const u8, rule: []const u8) bool {
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, trimmed, rule)) return true;
    }
    return false;
}

/// Write `existing` back with `\n<rule>\n` appended. We open for writing
/// (creating on absence) and rewrite the whole file: the global gitignore is
/// tiny, so a full rewrite is simpler and safer than a positional append.
fn appendRule(
    allocator: std.mem.Allocator,
    path: []const u8,
    existing: []const u8,
    rule: []const u8,
) !void {
    const combined = try std.fmt.allocPrint(allocator, "{s}\n{s}\n", .{ existing, rule });
    defer allocator.free(combined);
    try std.Io.Dir.cwd().writeFile(rt.io, .{ .sub_path = path, .data = combined });
}

// -- Tests ----------------------------------------------------------------

const testing = std.testing;
const test_helpers = @import("test_helpers.zig");

fn runGit(cwd: []const u8, argv: []const []const u8) !void {
    const result = try std.process.run(testing.allocator, rt.io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    if (!(result.term == .exited and result.term.exited == 0)) return error.GitFailed;
}

test "getGlobalGitignorePath ends with .config/git/ignore" {
    if (@import("builtin").os.tag == .windows) return;
    const out = try getGlobalGitignorePath(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.endsWith(u8, out, "git/ignore"));
    try testing.expect(std.fs.path.isAbsolute(out));
}

test "isPathGitignored reports an ignored path as true and others false" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    runGit(cwd, &.{ "git", "init" }) catch return; // skip if git unavailable

    // A tracked file then ignored via .gitignore.
    try tmp.dir.writeFile(rt.io, .{ .sub_path = ".gitignore", .data = "secret.txt\n" });
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "secret.txt", .data = "shh\n" });
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "keep.txt", .data = "ok\n" });

    try testing.expect(isPathGitignored(testing.allocator, cwd, "secret.txt"));
    try testing.expect(!isPathGitignored(testing.allocator, cwd, "keep.txt"));
}

// Note: a "fails open outside a repo" test is intentionally omitted. The
// custom test runner places `testing.tmpDir` under `.zig-cache/tmp/`, which
// lives INSIDE this project's own git repo (and is itself gitignored), so a
// tmp dir is never "outside a repo" here. The fail-open path (exit 128 ->
// false) is still exercised in production; we just cannot reproduce the
// not-a-repo precondition from a tmp dir in this environment.

test "ruleAlreadyPresent matches whole lines only" {
    try testing.expect(ruleAlreadyPresent("**/foo\n**/bar\n", "**/foo"));
    try testing.expect(ruleAlreadyPresent("  **/foo  \n", "**/foo"));
    // Substring of a longer rule must NOT match.
    try testing.expect(!ruleAlreadyPresent("**/foobar\n", "**/foo"));
    try testing.expect(!ruleAlreadyPresent("", "**/foo"));
}

test "addFileGlobRuleToGitignore writes a rule and is idempotent" {
    if (@import("builtin").os.tag == .windows) return;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    runGit(cwd, &.{ "git", "init" }) catch return; // skip if git unavailable

    // Point the global gitignore at the tmp dir so the test never touches the
    // real ~/.config/git/ignore. setenv is process-wide; we restore on exit.
    const prev_xdg = @import("env.zig").getOwned(allocator, "XDG_CONFIG_HOME") catch null;
    defer if (prev_xdg) |x| allocator.free(x);

    // Force getConfigHome to resolve under the tmp dir via XDG_CONFIG_HOME.
    const fake_config = try std.fs.path.joinZ(allocator, &.{ cwd, "cfg" });
    defer allocator.free(fake_config);
    _ = setenv("XDG_CONFIG_HOME", fake_config.ptr, 1);
    defer {
        if (prev_xdg) |x| {
            const restore = allocator.dupeZ(u8, x) catch null;
            if (restore) |r| {
                _ = setenv("XDG_CONFIG_HOME", r.ptr, 1);
                allocator.free(r);
            }
        } else {
            _ = unsetenv("XDG_CONFIG_HOME");
        }
    }

    addFileGlobRuleToGitignore(allocator, "secret.env", cwd);

    const ignore_path = try getGlobalGitignorePath(allocator);
    defer allocator.free(ignore_path);

    const after_first = try readFileBestEffort(allocator, ignore_path);
    defer allocator.free(after_first);
    try testing.expect(std.mem.indexOf(u8, after_first, "**/secret.env") != null);

    // Second call must not duplicate the rule.
    addFileGlobRuleToGitignore(allocator, "secret.env", cwd);
    const after_second = try readFileBestEffort(allocator, ignore_path);
    defer allocator.free(after_second);

    const count = std.mem.count(u8, after_second, "**/secret.env");
    try testing.expectEqual(@as(usize, 1), count);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
