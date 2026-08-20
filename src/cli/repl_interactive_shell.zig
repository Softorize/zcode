const std = @import("std");
const rt = @import("zcode_runtime");

pub fn runAttached(allocator: std.mem.Allocator, cwd: []const u8, command: []const u8) ![]u8 {
    const shell_path = @import("../core/env.zig").getenv("SHELL") orelse "/bin/sh";
    const shell_name = std.fs.path.basename(shell_path);
    const shell_flag = if (std.mem.eql(u8, shell_name, "bash") or
        std.mem.eql(u8, shell_name, "zsh") or
        std.mem.eql(u8, shell_name, "sh"))
        "-lc"
    else
        "-c";

    var child = try std.process.spawn(rt.io, .{
        .argv = &.{ shell_path, shell_flag, command },
        .cwd = .{ .path = cwd },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(rt.io);
    return switch (term) {
        .exited => |code| std.fmt.allocPrint(
            allocator,
            "/! {s}\n[interactive_shell cwd={s}]\n[exit_code={d}]",
            .{ command, cwd, code },
        ),
        .signal => |sig| std.fmt.allocPrint(
            allocator,
            "/! {s}\n[interactive_shell cwd={s}]\n[signal={d}]",
            .{ command, cwd, @intFromEnum(sig) },
        ),
        else => std.fmt.allocPrint(
            allocator,
            "/! {s}\n[interactive_shell cwd={s}]\n[exit=nonstandard]",
            .{ command, cwd },
        ),
    };
}
