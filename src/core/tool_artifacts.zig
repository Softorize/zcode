const std = @import("std");
const rng = @import("rng.zig");
const std_io = @import("std_io.zig");
const rt = @import("zcode_runtime");
const clock = @import("clock.zig");
const paths = @import("paths.zig");

pub const DEFAULT_THRESHOLD_BYTES: usize = 64 * 1024;
pub const HISTORY_PREVIEW_BYTES: usize = 12 * 1024;

pub const Artifact = struct {
    id: []u8,
    path: []u8,
    bytes: usize,

    pub fn deinit(self: *Artifact, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.path);
    }
};

pub fn writeSessionArtifact(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    tool_name: []const u8,
    output: []const u8,
) !Artifact {
    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);
    return writeSessionArtifactInDir(allocator, resolved.sessions_dir, session_id, tool_name, output);
}

pub fn writeSessionArtifactInDir(
    allocator: std.mem.Allocator,
    sessions_dir: []const u8,
    session_id: []const u8,
    tool_name: []const u8,
    output: []const u8,
) !Artifact {
    const safe_session = try sanitizeSegment(allocator, session_id, "session");
    defer allocator.free(safe_session);
    const safe_tool = try sanitizeSegment(allocator, tool_name, "tool");
    defer allocator.free(safe_tool);

    const artifact_dirname = try std.fmt.allocPrint(allocator, "{s}.artifacts", .{safe_session});
    defer allocator.free(artifact_dirname);
    const artifact_dir = try std.fs.path.join(allocator, &.{ sessions_dir, artifact_dirname });
    defer allocator.free(artifact_dir);
    try std.Io.Dir.cwd().createDirPath(rt.io, artifact_dir);

    const nonce = rng.int(u32);
    const id = try std.fmt.allocPrint(allocator, "{s}-{d}-{x}", .{ safe_tool, clock.nowSeconds(), nonce });
    errdefer allocator.free(id);
    const filename = try std.fmt.allocPrint(allocator, "{s}.txt", .{id});
    defer allocator.free(filename);
    const path = try std.fs.path.join(allocator, &.{ artifact_dir, filename });
    errdefer allocator.free(path);

    try writeFileAtomic(allocator, path, output);
    return .{
        .id = id,
        .path = path,
        .bytes = output.len,
    };
}

fn sanitizeSegment(allocator: std.mem.Allocator, raw: []const u8, fallback: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    for (raw) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.') {
            try out.append(ch);
        } else {
            try out.append('_');
        }
    }

    if (out.items().len == 0) try out.appendSlice(fallback);
    return out.toOwnedSlice();
}

fn writeFileAtomic(allocator: std.mem.Allocator, target: []const u8, bytes: []const u8) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{target});
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, bytes);
        file.sync(rt.io) catch {};
    }

    try std.Io.Dir.renameAbsolute(tmp_path, target, rt.io);
}

const testing = std.testing;

test "writeSessionArtifactInDir stores output under session artifact directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const sessions_dir = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var artifact = try writeSessionArtifactInDir(testing.allocator, sessions_dir, "session/1", "Bash", "large output");
    defer artifact.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, artifact.path, "session_1.artifacts") != null);
    try testing.expect(std.mem.indexOf(u8, artifact.id, "Bash-") == 0);
    try testing.expectEqual(@as(usize, "large output".len), artifact.bytes);

    const loaded = try std.Io.Dir.cwd().readFileAlloc(rt.io, artifact.path, testing.allocator, .limited(1024));
    defer testing.allocator.free(loaded);
    try testing.expectEqualStrings("large output", loaded);
}
