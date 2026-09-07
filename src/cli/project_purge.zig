//! cli-flags-31: `zcode project purge [path]` -- delete zcode's workspace
//! state for a project (the `.zcode/` directory under `path`, default the
//! current working directory), mirroring the reference's `project purge
//! [path]` ("Delete all Claude Code state for a project (transcripts,
//! tasks, file history, config entry)").
//!
//! Scope note: zcode's session transcripts/history live in the per-USER
//! `~/.zcode/sessions/` store (session/store.zig), not under the project's
//! own `.zcode/` directory, and are not tagged by project path in a way
//! this package owns the schema for. This command purges the
//! project-local `.zcode/` directory (workspace config.toml, workspace
//! permission rules, and anything else a plugin/skill has written there);
//! purging matching entries from the global session store is left to
//! whichever package owns `session/store.zig`.

const std = @import("std");
const rt = @import("zcode_runtime");
const std_io = @import("../core/std_io.zig");

/// List every regular file under `dot_zcode_dir` (recursively), relative to
/// it, for `--dry-run` reporting. Returns an empty list when the directory
/// does not exist. Caller frees each string and the outer slice.
fn listFiles(allocator: std.mem.Allocator, dot_zcode_dir: []const u8) ![][]u8 {
    var out: std.array_list.Managed([]u8) = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit();
    }

    var dir = std.Io.Dir.cwd().openDir(rt.io, dot_zcode_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return out.toOwnedSlice(),
        else => return err,
    };
    defer dir.close(rt.io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(rt.io)) |entry| {
        if (entry.kind != .file) continue;
        try out.append(try allocator.dupe(u8, entry.path));
    }
    return out.toOwnedSlice();
}

/// Run `project purge`. `target_path` is the optional `[path]` positional
/// (null = current working directory). `dry_run` lists what would be
/// deleted without touching anything; otherwise deletion proceeds only when
/// `assume_yes` is set (mirroring the reference's confirmation prompt,
/// which zcode's non-interactive CLI cannot render, so `--yes`/`-y` is
/// required instead of an interactive y/n).
pub fn run(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    target_path: ?[]const u8,
    dry_run: bool,
    assume_yes: bool,
    writer: anytype,
) !void {
    const path = target_path orelse cwd;
    const dot_zcode = try std.fs.path.join(allocator, &.{ path, ".zcode" });
    defer allocator.free(dot_zcode);

    const files = try listFiles(allocator, dot_zcode);
    defer {
        for (files) |f| allocator.free(f);
        allocator.free(files);
    }

    if (files.len == 0) {
        try writer.print("no zcode project state found at {s}\n", .{dot_zcode});
        return;
    }

    if (dry_run) {
        try writer.print("would delete {s}/ ({d} file(s)):\n", .{ dot_zcode, files.len });
        for (files) |f| try writer.print("  {s}/{s}\n", .{ dot_zcode, f });
        return;
    }

    if (!assume_yes) {
        try writer.print(
            "{s}/ contains {d} file(s). Re-run with --yes (or -y) to delete, or --dry-run to list them.\n",
            .{ dot_zcode, files.len },
        );
        return;
    }

    try std.Io.Dir.cwd().deleteTree(rt.io, dot_zcode);
    try writer.print("removed {s}/ ({d} file(s))\n", .{ dot_zcode, files.len });
}

const testing = std.testing;
const test_helpers = @import("../core/test_helpers.zig");

test "run --dry-run lists files without deleting anything" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    const dot_zcode = try std.fs.path.join(alloc, &.{ root, ".zcode" });
    defer alloc.free(dot_zcode);
    try std.Io.Dir.cwd().createDirPath(rt.io, dot_zcode);
    {
        const p = try std.fs.path.join(alloc, &.{ dot_zcode, "config.toml" });
        defer alloc.free(p);
        const f = try std.Io.Dir.cwd().createFile(rt.io, p, .{ .truncate = true });
        f.close(rt.io);
    }

    var out = std_io.StringBuilder.init(alloc);
    defer out.deinit();
    try run(alloc, root, null, true, false, out.writer());

    try testing.expect(std.mem.indexOf(u8, out.items(), "would delete") != null);
    try testing.expect(std.mem.indexOf(u8, out.items(), "config.toml") != null);

    // Nothing was actually deleted.
    try std.Io.Dir.cwd().access(rt.io, dot_zcode, .{});
}

test "run without --yes refuses to delete and explains why" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    const dot_zcode = try std.fs.path.join(alloc, &.{ root, ".zcode" });
    defer alloc.free(dot_zcode);
    try std.Io.Dir.cwd().createDirPath(rt.io, dot_zcode);
    {
        const p = try std.fs.path.join(alloc, &.{ dot_zcode, "config.toml" });
        defer alloc.free(p);
        const f = try std.Io.Dir.cwd().createFile(rt.io, p, .{ .truncate = true });
        f.close(rt.io);
    }

    var out = std_io.StringBuilder.init(alloc);
    defer out.deinit();
    try run(alloc, root, null, false, false, out.writer());

    try testing.expect(std.mem.indexOf(u8, out.items(), "--yes") != null);
    try std.Io.Dir.cwd().access(rt.io, dot_zcode, .{});
}

test "run --yes deletes the project's .zcode directory" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    const dot_zcode = try std.fs.path.join(alloc, &.{ root, ".zcode" });
    defer alloc.free(dot_zcode);
    try std.Io.Dir.cwd().createDirPath(rt.io, dot_zcode);
    {
        const p = try std.fs.path.join(alloc, &.{ dot_zcode, "config.toml" });
        defer alloc.free(p);
        const f = try std.Io.Dir.cwd().createFile(rt.io, p, .{ .truncate = true });
        f.close(rt.io);
    }

    var out = std_io.StringBuilder.init(alloc);
    defer out.deinit();
    try run(alloc, root, null, false, true, out.writer());

    try testing.expect(std.mem.indexOf(u8, out.items(), "removed") != null);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(rt.io, dot_zcode, .{}));
}

test "run on a project with no .zcode state reports that plainly" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var out = std_io.StringBuilder.init(alloc);
    defer out.deinit();
    try run(alloc, root, null, false, true, out.writer());

    try testing.expect(std.mem.indexOf(u8, out.items(), "no zcode project state found") != null);
}
