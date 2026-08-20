const std = @import("std");
const std_io = @import("../core/std_io.zig");
const rt = @import("zcode_runtime");
const clock = @import("../core/clock.zig");
const platform_mod = @import("../core/platform.zig");

pub fn pasteClipboardImageToTempFile(allocator: std.mem.Allocator) !?[]u8 {
    const dir = try imagePasteDir(allocator);
    defer allocator.free(dir);

    std.Io.Dir.createDirAbsolute(rt.io, dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const filename = try std.fmt.allocPrint(
        allocator,
        "clipboard-{d}-{d}.png",
        .{ clock.nowSeconds(), clock.nowNanos() },
    );
    defer allocator.free(filename);

    const path = try std.fs.path.join(allocator, &.{ dir, filename });
    errdefer allocator.free(path);

    const saved = switch (platform_mod.detect()) {
        .macos => try saveMacClipboardImage(allocator, path),
        .linux => try saveLinuxClipboardImage(allocator, path),
        else => false,
    };
    if (!saved) {
        std.Io.Dir.deleteFileAbsolute(rt.io, path) catch {};
        allocator.free(path);
        return null;
    }

    const file = std.Io.Dir.openFileAbsolute(rt.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            allocator.free(path);
            return null;
        },
        else => return err,
    };
    defer file.close(rt.io);
    const stat = try file.stat(rt.io);
    if (stat.size == 0) {
        std.Io.Dir.deleteFileAbsolute(rt.io, path) catch {};
        allocator.free(path);
        return null;
    }

    return path;
}

fn imagePasteDir(allocator: std.mem.Allocator) ![]u8 {
    return std.fs.path.join(allocator, &.{ @import("../core/env.zig").getenv("TMPDIR") orelse "/tmp", "zcode-pasted-images" });
}

fn saveMacClipboardImage(allocator: std.mem.Allocator, path: []const u8) !bool {
    const escaped_path = try escapeAppleScriptString(allocator, path);
    defer allocator.free(escaped_path);

    const open_script = try std.fmt.allocPrint(
        allocator,
        "set fp to open for access POSIX file \"{s}\" with write permission",
        .{escaped_path},
    );
    defer allocator.free(open_script);

    const argv = [_][]const u8{
        "osascript",
        "-e",
        "set png_data to (the clipboard as «class PNGf»)",
        "-e",
        open_script,
        "-e",
        "write png_data to fp",
        "-e",
        "close access fp",
    };
    return runCommandOk(allocator, &argv);
}

fn saveLinuxClipboardImage(allocator: std.mem.Allocator, path: []const u8) !bool {
    const command = try std.fmt.allocPrint(
        allocator,
        "xclip -selection clipboard -t image/png -o > {s} 2>/dev/null || wl-paste --type image/png > {s} 2>/dev/null",
        .{ path, path },
    );
    defer allocator.free(command);

    const argv = [_][]const u8{ "sh", "-lc", command };
    return runCommandOk(allocator, &argv);
}

fn runCommandOk(allocator: std.mem.Allocator, argv: []const []const u8) !bool {
    const result = try std.process.run(allocator, rt.io, .{
        .argv = argv,
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn escapeAppleScriptString(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    for (raw) |ch| {
        if (ch == '\\' or ch == '"') try out.append('\\');
        try out.append(ch);
    }

    return out.toOwnedSlice();
}

const testing = std.testing;

test "escapeAppleScriptString escapes quotes and backslashes" {
    const escaped = try escapeAppleScriptString(testing.allocator, "/tmp/a\"b\\c.png");
    defer testing.allocator.free(escaped);

    try testing.expectEqualStrings("/tmp/a\\\"b\\\\c.png", escaped);
}
