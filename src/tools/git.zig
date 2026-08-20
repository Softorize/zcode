const std = @import("std");
const rng = @import("../core/rng.zig");
const rt = @import("zcode_runtime");

pub fn status(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const argv = [_][]const u8{ "git", "-C", cwd, "status", "--short", "--branch" };
    const result = try std.process.run(allocator, rt.io, .{
        .argv = &argv,
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(128 * 1024),
    });
    defer allocator.free(result.stderr);

    if (result.term == .exited and result.term.exited == 0) {
        return result.stdout;
    }

    const exit_code: u32 = if (result.term == .exited) result.term.exited else 0;
    const msg = try std.fmt.allocPrint(allocator, "git status failed (exit={d}): {s}", .{ exit_code, result.stderr });
    allocator.free(result.stdout);
    return msg;
}

pub fn applyPatch(allocator: std.mem.Allocator, cwd: []const u8, patch_text: []const u8) ![]u8 {
    const nonce = rng.int(u64);
    const tmp_name = try std.fmt.allocPrint(allocator, "{s}/.zcode_tmp_patch-{x}.diff", .{ cwd, nonce });
    defer allocator.free(tmp_name);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_name) catch {};

    // 0o600: patch contents are user code, possibly unmerged work. A
    // shared repo on a multi-user host would otherwise expose it to
    // other local users during the apply window via the default 0o644
    // umask. Sync before git reads it so a crash in the interval does
    // not hand git a truncated patch.
    const patch_file = try std.Io.Dir.cwd().createFile(rt.io, tmp_name, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
    defer patch_file.close(rt.io);
    try patch_file.writeStreamingAll(rt.io, patch_text);
    patch_file.sync(rt.io) catch {};

    const argv = [_][]const u8{ "git", "-C", cwd, "apply", tmp_name };
    const result = try std.process.run(allocator, rt.io, .{
        .argv = &argv,
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(128 * 1024),
    });
    defer allocator.free(result.stderr);

    std.Io.Dir.cwd().deleteFile(rt.io, tmp_name) catch {};

    if (result.term == .exited and result.term.exited == 0) {
        allocator.free(result.stdout);
        return allocator.dupe(u8, "patch applied");
    }

    const exit_code: u32 = if (result.term == .exited) result.term.exited else 0;
    const msg = try std.fmt.allocPrint(allocator, "git apply failed (exit={d}): {s}", .{ exit_code, result.stderr });
    allocator.free(result.stdout);
    return msg;
}

const testing = std.testing;

fn initGitRepoForTest(cwd: []const u8) !void {
    const init = try std.process.run(testing.allocator, rt.io, .{
        .argv = &.{ "git", "-C", cwd, "init" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer testing.allocator.free(init.stdout);
    defer testing.allocator.free(init.stderr);

    const email = try std.process.run(testing.allocator, rt.io, .{
        .argv = &.{ "git", "-C", cwd, "config", "user.email", "test@example.com" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer testing.allocator.free(email.stdout);
    defer testing.allocator.free(email.stderr);

    const name = try std.process.run(testing.allocator, rt.io, .{
        .argv = &.{ "git", "-C", cwd, "config", "user.name", "zcode test" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer testing.allocator.free(name.stdout);
    defer testing.allocator.free(name.stderr);
}

test "applyPatch applies diff and cleans up temp file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "demo.txt", .data = "before\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    try initGitRepoForTest(cwd);

    const patch =
        \\diff --git a/demo.txt b/demo.txt
        \\index 62430da..b08a145 100644
        \\--- a/demo.txt
        \\+++ b/demo.txt
        \\@@ -1 +1 @@
        \\-before
        \\+after
        \\
    ;

    const output = try applyPatch(testing.allocator, cwd, patch);
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("patch applied", output);

    const updated = try tmp.dir.readFileAlloc(rt.io, "demo.txt", testing.allocator, .limited(1024));
    defer testing.allocator.free(updated);
    try testing.expectEqualStrings("after\n", updated);

    var dir = try std.Io.Dir.cwd().openDir(rt.io, cwd, .{ .iterate = true });
    defer dir.close(rt.io);
    var it = dir.iterate();
    while (try it.next(rt.io)) |entry| {
        try testing.expect(!(std.mem.startsWith(u8, entry.name, ".zcode_tmp_patch-") and std.mem.endsWith(u8, entry.name, ".diff")));
    }
}
