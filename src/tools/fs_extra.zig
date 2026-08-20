const std = @import("std");
const std_io = @import("../core/std_io.zig");
const rt = @import("zcode_runtime");
const rng = @import("../core/rng.zig");
const helpers = @import("helpers.zig");
const path_utils = @import("../core/path_utils.zig");
const normalizePath = helpers.normalizePath;

/// IO-bearing removal-safety guard. Resolves the home directory (which
/// needs the runtime env) and delegates to the pure
/// `path_utils.isDangerousRemovalPathPure`. Returns true when removing
/// `resolved_path` would hit a dangerous target (root, a direct child
/// of root, the home dir, a Windows drive root/child, or a `/*` glob).
/// Home-lookup failure falls back to an empty home so the rest of the
/// guard still applies. Ported from isDangerousRemovalPath
/// (pathValidation.ts:331-367).
pub fn isDangerousRemovalPath(allocator: std.mem.Allocator, resolved_path: []const u8) bool {
    const home = path_utils.getHomeDir(allocator) catch "";
    defer if (home.len > 0) allocator.free(home);
    return path_utils.isDangerousRemovalPathPure(resolved_path, home);
}

/// Strip a single pair of surrounding ASCII quotes.
fn stripSurroundingQuotes(path: []const u8) []const u8 {
    var s = path;
    if (s.len >= 1 and (s[0] == '\'' or s[0] == '"')) s = s[1..];
    if (s.len >= 1 and (s[s.len - 1] == '\'' or s[s.len - 1] == '"')) s = s[0 .. s.len - 1];
    return s;
}

/// TOCTOU path-validation guards (permissions-16) for move/copy/delete
/// targets. Runs after quote-strip and `~`/`~/` expansion so a
/// legitimate `~/foo` is not rejected. Rejects UNC, unexpanded tilde
/// variants, and shell-expansion syntax on any operation; rejects glob
/// metacharacters only when `reject_globs` is set (write-class
/// destinations). Returns an owned error message, else null.
fn pathValidationRefusal(
    allocator: std.mem.Allocator,
    label: []const u8,
    path: []const u8,
    reject_globs: bool,
) !?[]u8 {
    const cleaned = stripSurroundingQuotes(path);
    const expanded = try helpers.expandHomeTilde(allocator, cleaned);
    defer allocator.free(expanded);

    if (path_utils.isUncPath(expanded)) {
        return try std.fmt.allocPrint(allocator, "{s} blocked: path '{s}' is a UNC network path (credential-leak vector); requires manual approval.", .{ label, path });
    }
    if (path_utils.hasTildeVariant(expanded)) {
        return try std.fmt.allocPrint(allocator, "{s} blocked: path '{s}' uses a tilde expansion variant (~user, ~+, ~-); requires manual approval.", .{ label, path });
    }
    if (path_utils.hasShellExpansion(expanded)) {
        return try std.fmt.allocPrint(allocator, "{s} blocked: path '{s}' contains shell expansion syntax; requires manual approval.", .{ label, path });
    }
    if (reject_globs and path_utils.hasGlobMeta(expanded)) {
        return try std.fmt.allocPrint(allocator, "{s} blocked: path '{s}' contains glob metacharacters; specify an exact path.", .{ label, path });
    }
    return null;
}

pub fn move(allocator: std.mem.Allocator, cwd: []const u8, from_path: []const u8, to_path: []const u8) ![]u8 {
    // TOCTOU path-validation guards (permissions-16) on both ends.
    // move uses paths literally (no glob expansion), so reject globs on
    // source and destination alike.
    if (try pathValidationRefusal(allocator, "move", from_path, true)) |msg| return msg;
    if (try pathValidationRefusal(allocator, "move", to_path, true)) |msg| return msg;

    const abs_from = try normalizePath(allocator, cwd, from_path);
    defer allocator.free(abs_from);
    const abs_to = try normalizePath(allocator, cwd, to_path);
    defer allocator.free(abs_to);

    if (std.mem.eql(u8, abs_from, abs_to)) {
        return allocator.dupe(u8, "move failed: source and destination are the same path");
    }

    // Refuse to relocate a device file. On permissive systems
    // `move /dev/sda /tmp/x` would dissociate the device entry from
    // /dev, breaking the host's device tree until reboot. /dev/null
    // is the canonical no-op sink and stays legal.
    if (isDeviceFile(abs_from) or isDeviceFile(abs_to)) {
        return allocator.dupe(u8, "move failed: refusing to move a device file (would corrupt the host's /dev entries).");
    }

    const to_dir = std.fs.path.dirname(abs_to) orelse cwd;
    std.Io.Dir.cwd().createDirPath(rt.io, to_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    std.Io.Dir.renameAbsolute(abs_from, abs_to, rt.io) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, "move failed: source not found"),
        else => return err,
    };

    return std.fmt.allocPrint(allocator, "moved {s} -> {s}", .{ from_path, to_path });
}

pub fn copy(allocator: std.mem.Allocator, cwd: []const u8, from_path: []const u8, to_path: []const u8, recursive: bool) ![]u8 {
    // TOCTOU path-validation guards (permissions-16). copy uses paths
    // literally (no glob expansion), so reject globs on both ends.
    if (try pathValidationRefusal(allocator, "copy", from_path, true)) |msg| return msg;
    if (try pathValidationRefusal(allocator, "copy", to_path, true)) |msg| return msg;

    const abs_from = try normalizePath(allocator, cwd, from_path);
    defer allocator.free(abs_from);
    const abs_to = try normalizePath(allocator, cwd, to_path);
    defer allocator.free(abs_to);

    if (std.mem.eql(u8, abs_from, abs_to)) {
        return allocator.dupe(u8, "copy failed: source and destination are the same path");
    }

    const stat = std.Io.Dir.cwd().statFile(rt.io, abs_from, .{}) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, "copy failed: source not found"),
        else => return err,
    };

    if (stat.kind == .directory) {
        if (!recursive) {
            return allocator.dupe(u8, "copy failed: source is a directory (set recursive=true)");
        }
        try copyDirRecursive(allocator, abs_from, abs_to);
    } else {
        const to_dir = std.fs.path.dirname(abs_to) orelse cwd;
        std.Io.Dir.cwd().createDirPath(rt.io, to_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        try copyFileContents(abs_from, abs_to);
    }

    return std.fmt.allocPrint(allocator, "copied {s} -> {s}", .{ from_path, to_path });
}

pub fn deletePath(allocator: std.mem.Allocator, cwd: []const u8, target_path: []const u8, recursive: bool) ![]u8 {
    // TOCTOU path-validation guards (permissions-16). delete uses the
    // path literally, so reject UNC / tilde-variant / shell-expansion /
    // glob targets up-front.
    if (try pathValidationRefusal(allocator, "delete", target_path, true)) |msg| return msg;

    const abs = try normalizePath(allocator, cwd, target_path);
    defer allocator.free(abs);

    if (std.mem.eql(u8, abs, cwd) or std.mem.eql(u8, abs, "/")) {
        return allocator.dupe(u8, "delete blocked: refusing to delete workspace root or system root");
    }

    // Broad dangerous-removal guard: the system root, a direct child of
    // root (/usr, /etc, /tmp), the home directory, a Windows drive
    // root/child, or a `/*` glob target. These would wipe a large swath
    // of the host even though they are not the workspace root.
    if (isDangerousRemovalPath(allocator, abs)) {
        return std.fmt.allocPrint(
            allocator,
            "delete blocked: '{s}' resolves to a dangerous removal target (system root, a direct child of root, the home directory, a drive root, or a glob). Removing it requires explicit manual action outside the agent.",
            .{target_path},
        );
    }

    // Refuse to unlink a device file. A model that called
    // delete('/dev/disk0') would otherwise break the host's device
    // tree on systems with permissive /dev permissions, requiring a
    // reboot to restore. /dev/null is allowed (deleting it is still
    // unusual, but it is not a host-breaking operation -- it'll be
    // recreated by udevd / devfs on most platforms).
    if (isDeviceFile(abs) and !std.mem.eql(u8, abs, "/dev/null")) {
        return allocator.dupe(u8, "delete blocked: refusing to unlink a device file (would corrupt the host's /dev entries).");
    }

    if (recursive) {
        std.Io.Dir.cwd().access(rt.io, abs, .{}) catch return allocator.dupe(u8, "delete: target not found");
        try std.Io.Dir.cwd().deleteTree(rt.io, abs);
        return std.fmt.allocPrint(allocator, "deleted {s}", .{target_path});
    }

    std.Io.Dir.cwd().deleteFile(rt.io, abs) catch |err| switch (err) {
        error.IsDir => return allocator.dupe(u8, "delete failed: target is a directory (set recursive=true)"),
        error.FileNotFound => return allocator.dupe(u8, "delete: target not found"),
        else => return err,
    };
    return std.fmt.allocPrint(allocator, "deleted {s}", .{target_path});
}

pub fn listDir(allocator: std.mem.Allocator, cwd: []const u8, target_path: []const u8, recursive: bool, max_entries: usize) ![]u8 {
    const abs = try normalizePath(allocator, cwd, target_path);
    defer allocator.free(abs);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    try out.writer().print("listdir: {s}\n", .{target_path});

    var count: usize = 0;
    try appendDirEntries(allocator, &out, abs, "", recursive, @max(@as(usize, 1), max_entries), &count);
    if (count == 0) {
        try out.writer().writeAll("(empty)\n");
    } else if (count >= max_entries) {
        try out.writer().print("... truncated at {d} entries ...\n", .{max_entries});
    }

    return out.toOwnedSlice();
}

pub fn statPath(allocator: std.mem.Allocator, cwd: []const u8, target_path: []const u8) ![]u8 {
    const abs = try normalizePath(allocator, cwd, target_path);
    defer allocator.free(abs);

    const st = std.Io.Dir.cwd().statFile(rt.io, abs, .{}) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, "stat failed: path not found"),
        else => return err,
    };
    return std.fmt.allocPrint(
        allocator,
        "path={s}\nkind={s}\nsize={d}\nmtime={d}",
        .{ target_path, kindLabel(st.kind), st.size, st.mtime.toNanoseconds() },
    );
}

fn appendDirEntries(
    allocator: std.mem.Allocator,
    out: *std_io.StringBuilder,
    abs_dir: []const u8,
    rel_prefix: []const u8,
    recursive: bool,
    max_entries: usize,
    count: *usize,
) !void {
    if (count.* >= max_entries) return;
    var dir = std.Io.Dir.cwd().openDir(rt.io, abs_dir, .{ .iterate = true }) catch |err| {
        std.log.debug("listdir: failed to open {s}: {s}", .{ abs_dir, @errorName(err) });
        return;
    };
    defer dir.close(rt.io);

    var it = dir.iterate();
    while (try it.next(rt.io)) |entry| {
        if (count.* >= max_entries) return;

        const rel_name = if (rel_prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel_prefix, entry.name });
        defer allocator.free(rel_name);

        try out.writer().print("- {s}\t{s}\n", .{ kindLabel(entry.kind), rel_name });
        count.* += 1;

        if (recursive and entry.kind == .directory) {
            const child_abs = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ abs_dir, entry.name });
            defer allocator.free(child_abs);
            try appendDirEntries(allocator, out, child_abs, rel_name, true, max_entries, count);
        }
    }
}

fn copyDirRecursive(allocator: std.mem.Allocator, src_dir: []const u8, dst_dir: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(rt.io, dst_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var dir = try std.Io.Dir.cwd().openDir(rt.io, src_dir, .{ .iterate = true });
    defer dir.close(rt.io);

    var it = dir.iterate();
    while (try it.next(rt.io)) |entry| {
        const child_src = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src_dir, entry.name });
        defer allocator.free(child_src);
        const child_dst = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dst_dir, entry.name });
        defer allocator.free(child_dst);

        switch (entry.kind) {
            .directory => try copyDirRecursive(allocator, child_src, child_dst),
            .file => try copyFileContents(child_src, child_dst),
            else => {},
        }
    }
}

/// Kernel-stat device-file check shared across move / copy /
/// deletePath. Returns true when `path` resolves to a character or
/// block device file. Returns false on stat failure (so a missing
/// destination path doesn't trip the gate -- the underlying op
/// surfaces FileNotFound naturally).
fn isDeviceFile(path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(rt.io, path, .{}) catch return false;
    return st.kind == .character_device or st.kind == .block_device;
}

fn copyFileContents(src_path: []const u8, dst_path: []const u8) !void {
    // Refuse device files on either side. The model-callable `copy`
    // tool would otherwise let `copy /dev/zero ./out.bin` hang
    // pulling 4 MiB+ of zeros (capped only by disk), or
    // `copy ./script.sh /dev/sda` write the source over a raw disk
    // device on hosts with permissive /dev permissions. /dev/null is
    // legal as a sink (canonical bit-bucket) and as a source (empty).
    {
        const src_st = std.Io.Dir.cwd().statFile(rt.io, src_path, .{}) catch null;
        if (src_st) |s| {
            if ((s.kind == .character_device or s.kind == .block_device) and
                !std.mem.eql(u8, src_path, "/dev/null"))
            {
                return error.RefusedDeviceCopy;
            }
        }
        const dst_st = std.Io.Dir.cwd().statFile(rt.io, dst_path, .{}) catch null;
        if (dst_st) |s| {
            if ((s.kind == .character_device or s.kind == .block_device) and
                !std.mem.eql(u8, dst_path, "/dev/null"))
            {
                return error.RefusedDeviceCopy;
            }
        }
    }

    var src = try std.Io.Dir.cwd().openFile(rt.io, src_path, .{});
    defer src.close(rt.io);

    // Atomic copy: a SIGINT in the middle of a multi-MB transfer
    // would otherwise leave the destination at the bytes flushed
    // so far -- a torn file from the user's perspective. Stage into
    // a sibling .tmp.<hex-nonce>, fsync, rename. Same discipline as
    // session/bundles.zig::copyFileWithMode (pass 70).
    const allocator = std.heap.page_allocator;
    var nonce: [8]u8 = undefined;
    rng.bytes(&nonce);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{x}{x}{x}{x}{x}{x}{x}{x}", .{
        dst_path, nonce[0], nonce[1], nonce[2], nonce[3], nonce[4], nonce[5], nonce[6], nonce[7],
    });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    {
        var dst = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true });
        defer dst.close(rt.io);
        var buf: [16 * 1024]u8 = undefined;
        var offset: u64 = 0;
        while (true) {
            const n = try src.readPositionalAll(rt.io, &buf, offset);
            if (n == 0) break;
            try dst.writeStreamingAll(rt.io, buf[0..n]);
            offset += n;
            if (n < buf.len) break;
        }
        dst.sync(rt.io) catch {};
    }
    try std.Io.Dir.renameAbsolute(tmp_path, dst_path, rt.io);
}

fn kindLabel(kind: std.Io.File.Kind) []const u8 {
    return switch (kind) {
        .file => "file",
        .directory => "dir",
        .sym_link => "symlink",
        else => "other",
    };
}

const testing = std.testing;

test "kindLabel maps common file kinds" {
    try testing.expectEqualStrings("file", kindLabel(.file));
    try testing.expectEqualStrings("dir", kindLabel(.directory));
}

test "deletePath rejects dangerous removal target /usr" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(cwd);

    const out = try deletePath(alloc, cwd, "/usr", false);
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "dangerous removal target") != null);
}

test "deletePath rejects shell-expansion path" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(cwd);

    const out = try deletePath(alloc, cwd, "$HOME/x", false);
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "shell expansion") != null);
}

test "move rejects glob and UNC paths" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(cwd);

    const glob_out = try move(alloc, cwd, "src/*.txt", "dst/out.txt");
    defer alloc.free(glob_out);
    try testing.expect(std.mem.indexOf(u8, glob_out, "glob") != null);

    const unc_out = try move(alloc, cwd, "a.txt", "//server/share/b.txt");
    defer alloc.free(unc_out);
    try testing.expect(std.mem.indexOf(u8, unc_out, "UNC") != null);
}
