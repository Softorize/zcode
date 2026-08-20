const std = @import("std");
const rt = @import("zcode_runtime");
const platform_mod = @import("platform.zig");

/// Copy `content` to the OS clipboard. Caller owns the returned status
/// string (suitable for direct display). Caps at 64 KiB.
///
/// Feeds bytes via the child's stdin pipe so the payload never appears
/// in argv (visible in `ps`) and we don't have to escape shell
/// metacharacters. WSL gets `clip.exe`, Linux gets `xclip`, macOS gets
/// `pbcopy` — platform_mod.clipboardCommand() handles the lookup.
pub fn copyText(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    const clip_len = @min(content.len, 65536);
    const clip_cmd = platform_mod.clipboardCommand();

    // clip_cmd may be split into argv tokens by whitespace (e.g. WSL's
    // "clip.exe", Linux's "xclip -selection clipboard").
    var argv_parts = std.array_list.Managed([]const u8).init(allocator);
    defer argv_parts.deinit();
    var it = std.mem.tokenizeAny(u8, clip_cmd, " ");
    while (it.next()) |t| try argv_parts.append(t);
    if (argv_parts.items.len == 0) return allocator.dupe(u8, "clipboard not available (install pbcopy or xclip)");

    var child = std.process.spawn(rt.io, .{
        .argv = argv_parts.items,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch {
        return allocator.dupe(u8, "clipboard not available (install pbcopy or xclip)");
    };
    if (child.stdin) |stdin_file| {
        stdin_file.writeStreamingAll(rt.io, content[0..clip_len]) catch {};
        stdin_file.close(rt.io);
        child.stdin = null;
    }
    const term = child.wait(rt.io) catch return allocator.dupe(u8, "clipboard command failed");
    if (term == .exited and term.exited == 0) {
        return std.fmt.allocPrint(allocator, "copied {d} chars to clipboard", .{clip_len});
    }
    return allocator.dupe(u8, "clipboard not available (install pbcopy or xclip)");
}
