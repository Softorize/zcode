const std = @import("std");
const std_io = @import("../core/std_io.zig");
const rt = @import("zcode_runtime");
const clock = @import("../core/clock.zig");
const builtin = @import("builtin");

pub const EditResult = struct {
    text: []u8,
    editor: []u8,

    pub fn deinit(self: *EditResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.editor);
    }
};

pub fn editPromptInExternalEditor(allocator: std.mem.Allocator, initial_text: []const u8) !EditResult {
    const tmp_dir = @import("../core/env.zig").getenv("TMPDIR") orelse "/tmp";
    const editor = pickEditor();

    var path: ?[]u8 = null;
    var attempt: usize = 0;
    while (attempt < 4 and path == null) : (attempt += 1) {
        const candidate = try std.fmt.allocPrint(
            allocator,
            "{s}/zcode-prompt-{d}-{d}-{d}.md",
            .{
                tmp_dir,
                if (builtin.os.tag == .linux) @as(i32, @intCast(std.os.linux.getpid())) else std.c.getpid(),
                clock.nowNanos(),
                attempt,
            },
        );
        errdefer allocator.free(candidate);

        if (std.Io.Dir.cwd().createFile(rt.io, candidate, .{ .exclusive = true, .permissions = std.Io.File.Permissions.fromMode(0o600) })) |file| {
            defer file.close(rt.io);
            try file.writeStreamingAll(rt.io, initial_text);
            path = candidate;
        } else |err| switch (err) {
            error.PathAlreadyExists => allocator.free(candidate),
            else => return err,
        }
    }

    const temp_path = path orelse return error.FileNotFound;
    defer {
        std.Io.Dir.cwd().deleteFile(rt.io, temp_path) catch {};
        allocator.free(temp_path);
    }

    const shell_command = try buildShellCommand(allocator, editor, temp_path);
    defer allocator.free(shell_command);

    const result = try std.process.run(allocator, rt.io, .{
        .argv = &.{ "/bin/sh", "-lc", shell_command },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.ExternalEditorFailed,
        else => return error.ExternalEditorFailed,
    }

    return .{
        .text = try std.Io.Dir.cwd().readFileAlloc(rt.io, temp_path, allocator, .limited(1_048_576)),
        .editor = try allocator.dupe(u8, editor),
    };
}

fn pickEditor() []const u8 {
    if (@import("../core/env.zig").getenv("VISUAL")) |value| {
        if (value.len > 0) return value;
    }
    if (@import("../core/env.zig").getenv("EDITOR")) |value| {
        if (value.len > 0) return value;
    }
    return "vi";
}

fn buildShellCommand(allocator: std.mem.Allocator, editor: []const u8, path: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    try out.appendSlice(editor);
    try out.append(' ');
    try appendSingleQuoted(&out, path);
    return out.toOwnedSlice();
}

fn appendSingleQuoted(out: *std_io.StringBuilder, text: []const u8) !void {
    try out.append('\'');
    for (text) |ch| {
        if (ch == '\'') {
            try out.appendSlice("'\"'\"'");
        } else {
            try out.append(ch);
        }
    }
    try out.append('\'');
}

const testing = std.testing;

test "build shell command quotes prompt path" {
    const allocator = testing.allocator;
    const command = try buildShellCommand(allocator, "vim", "/tmp/has space/it's.md");
    defer allocator.free(command);
    try testing.expectEqualStrings("vim '/tmp/has space/it'\"'\"'s.md'", command);
}
