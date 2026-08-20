const std = @import("std");
const rt = @import("zcode_runtime");
const clock = @import("../core/clock.zig");

pub fn storePastedTextToTempFile(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const tmp_root = @import("../core/env.zig").getenv("TMPDIR") orelse "/tmp";
    const dir_path = try std.fs.path.join(allocator, &.{ tmp_root, "zcode-pasted-text" });
    errdefer allocator.free(dir_path);

    std.Io.Dir.createDirAbsolute(rt.io, dir_path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const ts = clock.nowMillis();
    const file_path = try std.fmt.allocPrint(allocator, "{s}/paste-{d}.txt", .{ dir_path, ts });
    allocator.free(dir_path);
    errdefer allocator.free(file_path);

    var file = try std.Io.Dir.createFileAbsolute(rt.io, file_path, .{ .truncate = true });
    defer file.close(rt.io);
    try file.writeStreamingAll(rt.io, text);
    return file_path;
}

const testing = std.testing;

test "storePastedTextToTempFile writes the pasted text to disk" {
    const path = try storePastedTextToTempFile(testing.allocator, "alpha\nbeta\n");
    defer testing.allocator.free(path);
    defer std.Io.Dir.deleteFileAbsolute(rt.io, path) catch {};

    const data = try std.Io.Dir.openFileAbsolute(rt.io, path, .{});
    defer data.close(rt.io);
    const bytes = try data.readToEndAlloc(testing.allocator, 1024);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("alpha\nbeta\n", bytes);
}
