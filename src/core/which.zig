const std = @import("std");
const rt = @import("zcode_runtime");
const builtin = @import("builtin");

/// Native PATH walker. Ported in spirit from claude-code-main/src/
/// utils/which.ts -- reference falls back to shelling out `which` /
/// `where.exe`; zcode walks $PATH directly so /doctor doesn't pay
/// a subprocess spawn per tool and we can probe tool availability
/// without running the tool itself (important for things like
/// `gh --version` that may hit the network for auth checks).
///
/// Returns the absolute path to the first matching executable, or
/// null when the command is not on PATH. Caller owns the returned
/// slice (free with `allocator.free`).
///
/// Contract: we only probe the PATH entries in order and stat each
/// candidate. We do NOT resolve symlinks -- the caller gets whatever
/// the PATH entry points at. We DO check that the candidate is a
/// regular file (not a directory) and, on POSIX, that at least one
/// execute bit is set in st_mode. On Windows we try each PATHEXT
/// extension (.exe .cmd .bat .com) in addition to the bare name.
pub fn which(allocator: std.mem.Allocator, command: []const u8) !?[]u8 {
    if (command.len == 0) return null;
    // An absolute or relative path bypasses the PATH walk: just stat
    // it directly to preserve semantics with /bin/bash-style whiches.
    if (std.mem.indexOfScalar(u8, command, '/') != null or
        (builtin.os.tag == .windows and std.mem.indexOfScalar(u8, command, '\\') != null))
    {
        if (isExecutableFile(command)) {
            return try allocator.dupe(u8, command);
        }
        return null;
    }

    const path_env = @import("env.zig").getenv("PATH") orelse return null;
    const sep: u8 = if (builtin.os.tag == .windows) ';' else ':';

    var it = std.mem.splitScalar(u8, path_env, sep);
    while (it.next()) |raw_dir| {
        const dir = std.mem.trim(u8, raw_dir, " \t");
        if (dir.len == 0) continue;

        if (builtin.os.tag == .windows) {
            // Windows: try the bare name first (for scripts with no
            // extension) then each PATHEXT candidate. Match the
            // reference's fallback ordering.
            if (try tryCandidate(allocator, dir, command)) |p| return p;
            const default_exts = [_][]const u8{ ".exe", ".cmd", ".bat", ".com", ".ps1" };
            const pathext = @import("env.zig").getenv("PATHEXT");
            if (pathext) |ext_env| {
                var ext_it = std.mem.splitScalar(u8, ext_env, ';');
                while (ext_it.next()) |raw_ext| {
                    const ext = std.mem.trim(u8, raw_ext, " \t");
                    if (ext.len == 0) continue;
                    const name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ command, ext });
                    defer allocator.free(name);
                    if (try tryCandidate(allocator, dir, name)) |p| return p;
                }
            } else {
                for (default_exts) |ext| {
                    const name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ command, ext });
                    defer allocator.free(name);
                    if (try tryCandidate(allocator, dir, name)) |p| return p;
                }
            }
        } else {
            if (try tryCandidate(allocator, dir, command)) |p| return p;
        }
    }
    return null;
}

/// Cheap "does this command exist on PATH" probe. Allocates and
/// frees the path internally so callers that only need a boolean
/// don't have to manage the lifetime. Matches the signature that
/// `checkCommand` used to have in repl_commands.zig.
pub fn exists(allocator: std.mem.Allocator, command: []const u8) bool {
    const path = which(allocator, command) catch return false;
    if (path) |p| {
        allocator.free(p);
        return true;
    }
    return false;
}

fn tryCandidate(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) !?[]u8 {
    const candidate = try std.fs.path.join(allocator, &.{ dir, name });
    if (isExecutableFile(candidate)) {
        return candidate;
    }
    allocator.free(candidate);
    return null;
}

fn isExecutableFile(path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(rt.io, path, .{}) catch return false;
    if (st.kind != .file) return false;
    if (builtin.os.tag == .windows) {
        // Windows: if the file exists and is a regular file, PATHEXT
        // extension already vetted the name -- trust it.
        return true;
    }
    // POSIX: at least one execute bit must be set in the permissions.
    const mode = st.permissions.toMode();
    return (mode & 0o111) != 0;
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "which returns null for empty command" {
    try testing.expectEqual(@as(?[]u8, null), try which(testing.allocator, ""));
}

test "which returns null for nonexistent command" {
    const result = try which(testing.allocator, "this-command-definitely-does-not-exist-xyzzy");
    try testing.expectEqual(@as(?[]u8, null), result);
}

test "which finds a known system command on POSIX" {
    if (builtin.os.tag == .windows) return;
    // `sh` is guaranteed on every POSIX system zcode runs on.
    const sh_path = try which(testing.allocator, "sh");
    try testing.expect(sh_path != null);
    defer testing.allocator.free(sh_path.?);
    try testing.expect(sh_path.?.len > 0);
    try testing.expect(std.mem.endsWith(u8, sh_path.?, "/sh"));
}

test "which resolves a direct path to an executable" {
    if (builtin.os.tag == .windows) return;
    // /bin/sh is a reliable POSIX anchor.
    const result = try which(testing.allocator, "/bin/sh");
    try testing.expect(result != null);
    defer testing.allocator.free(result.?);
    try testing.expectEqualStrings("/bin/sh", result.?);
}

test "which returns null for a direct path that does not exist" {
    const result = try which(testing.allocator, "/nonexistent/path/to/nowhere");
    try testing.expectEqual(@as(?[]u8, null), result);
}

test "exists returns true for a known command" {
    if (builtin.os.tag == .windows) return;
    try testing.expect(exists(testing.allocator, "sh"));
}

test "exists returns false for a nonexistent command" {
    try testing.expect(!exists(testing.allocator, "this-command-definitely-does-not-exist-xyzzy"));
}
