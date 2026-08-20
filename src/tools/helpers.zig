const std = @import("std");
const std_io = @import("../core/std_io.zig");
const rt = @import("zcode_runtime");
const paths = @import("../core/paths.zig");
const path_utils = @import("../core/path_utils.zig");

pub const TASKS_SUBPATH = "state/tasks";
pub const TASK_RUNS_SUBPATH = "state/task-runs";
pub const TASK_NOTIFICATIONS_SUBPATH = "state/task-notifications.log";
pub const TEAMS_SUBPATH = "state/teams";
pub const MESSAGES_SUBPATH = "state/messages";

/// Workspace-relative tasks subpath for a given task list id
/// (`state/tasks/<list_id>`). The list id must already be sanitized to a safe
/// single path component (see `core/task_list_id.zig`). Caller frees.
/// Mirrors the reference per-list task directory (tasks.ts getTaskPath).
pub fn tasksSubpathForListAlloc(allocator: std.mem.Allocator, list_id: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ TASKS_SUBPATH, list_id });
}

/// Absolute path to a task list's directory under the workspace state dir,
/// creating it if missing. Caller frees.
pub fn tasksDirForList(allocator: std.mem.Allocator, cwd: []const u8, list_id: []const u8) ![]u8 {
    const rel = try tasksSubpathForListAlloc(allocator, list_id);
    defer allocator.free(rel);
    return ensureWorkspaceDirPath(allocator, cwd, rel);
}

pub fn ensureDirPath(allocator: std.mem.Allocator, cwd: []const u8, rel: []const u8) ![]u8 {
    const abs = try std.fs.path.join(allocator, &.{ cwd, rel });
    std.Io.Dir.cwd().createDirPath(rt.io, abs) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return abs;
}

pub fn ensureWorkspaceDirPath(allocator: std.mem.Allocator, cwd: []const u8, subpath: []const u8) ![]u8 {
    const abs = try paths.workspacePathAlloc(allocator, cwd, subpath);
    std.Io.Dir.cwd().createDirPath(rt.io, abs) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return abs;
}

pub fn workspacePathAlloc(allocator: std.mem.Allocator, cwd: []const u8, subpath: []const u8) ![]u8 {
    return paths.workspacePathAlloc(allocator, cwd, subpath);
}

pub fn workspaceRelativePathAlloc(allocator: std.mem.Allocator, cwd: []const u8, subpath: []const u8) ![]u8 {
    return paths.workspaceRelativePathAlloc(allocator, cwd, subpath);
}

pub fn isSafeIdentifier(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 128) return false;
    if (std.mem.eql(u8, trimmed, ".") or std.mem.eql(u8, trimmed, "..")) return false;

    for (trimmed) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.') continue;
        return false;
    }
    return true;
}

pub fn replaceOwned(allocator: std.mem.Allocator, target: *[]u8, value: []const u8) !void {
    const next = try allocator.dupe(u8, value);
    allocator.free(target.*);
    target.* = next;
}

pub fn normalizePath(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    // Tilde expansion. `~` or `~/...` maps to $HOME so ListDir,
    // Copy, Move, stat, and every fs_extra tool that goes through
    // this helper accepts the shell shorthand the user types.
    // Previously only file.zig::normalizePath (used by Read/Write/
    // Edit) expanded tildes, so a user asking "list ~/Projects"
    // via ListDir saw an empty result because the tool was
    // literally looking for a "~" directory inside cwd. Screenshot
    // bug report exposed this.
    const expanded = try expandHomeTilde(allocator, path);
    defer allocator.free(expanded);

    if (std.fs.path.isAbsolute(expanded)) return allocator.dupe(u8, expanded);
    return std.fs.path.join(allocator, &.{ cwd, expanded });
}

/// Expand a leading `~` or `~/` to `$HOME`. Returns an owned copy
/// of `path` (with or without expansion) so the caller can free
/// uniformly. `~alice/...` is passed through unchanged because
/// other-user home lookup needs a password database query that
/// most sandboxes block.
///
/// Exported so Glob/Grep/other tools that do their own path
/// resolution (not going through `normalizePath`) can still pick
/// up the shell-style `~` shorthand.
pub fn expandHomeTilde(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0 or path[0] != '~') return allocator.dupe(u8, path);
    if (path.len > 1 and path[1] != '/') return allocator.dupe(u8, path);

    const home = path_utils.getHomeDir(allocator) catch return allocator.dupe(u8, path);
    defer allocator.free(home);
    if (home.len == 0) return allocator.dupe(u8, path);

    if (path.len == 1) return allocator.dupe(u8, home);
    const rest = std.mem.trimStart(u8, path[1..], "/");
    if (rest.len == 0) return allocator.dupe(u8, home);
    return std.fs.path.join(allocator, &.{ home, rest });
}

pub const resolvePathAlloc = normalizePath;

pub fn escapeTextAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    for (text) |ch| switch (ch) {
        '\\' => try out.appendSlice("\\\\"),
        '\n' => try out.appendSlice("\\n"),
        '\r' => try out.appendSlice("\\r"),
        '\t' => try out.appendSlice("\\t"),
        else => try out.append(ch),
    };
    return out.toOwnedSlice();
}

pub fn unescapeTextAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\' and i + 1 < text.len) {
            const n = text[i + 1];
            switch (n) {
                'n' => try out.append('\n'),
                'r' => try out.append('\r'),
                't' => try out.append('\t'),
                '\\' => try out.append('\\'),
                else => {
                    try out.append('\\');
                    try out.append(n);
                },
            }
            i += 1;
            continue;
        }
        try out.append(text[i]);
    }
    return out.toOwnedSlice();
}

pub fn limitLinesAlloc(allocator: std.mem.Allocator, input: []const u8, max_lines: usize) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    var it = std.mem.splitScalar(u8, input, '\n');
    var count: usize = 0;
    while (it.next()) |line| {
        if (count >= max_lines) break;
        try out.appendSlice(line);
        try out.append('\n');
        count += 1;
    }
    return out.toOwnedSlice();
}

pub fn urlEncodeAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    for (text) |ch| {
        if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try out.append(ch);
        } else if (ch == ' ') {
            try out.append('+');
        } else {
            var hex: [2]u8 = undefined;
            _ = std.fmt.bufPrint(&hex, "{X:0>2}", .{ch}) catch unreachable;
            try out.append('%');
            try out.appendSlice(&hex);
        }
    }
    return out.toOwnedSlice();
}

pub fn findMatchingBracket(text: []const u8, open_idx: usize, open_ch: u8, close_ch: u8) ?usize {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    var i = open_idx;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_string) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '"') in_string = false;
            continue;
        }
        if (ch == '"') {
            in_string = true;
            continue;
        }
        if (ch == open_ch) {
            depth += 1;
        } else if (ch == close_ch) {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

pub fn jsonEscapeAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    for (text) |ch| switch (ch) {
        '"' => try out.appendSlice("\\\""),
        '\\' => try out.appendSlice("\\\\"),
        '\n' => try out.appendSlice("\\n"),
        '\r' => try out.appendSlice("\\r"),
        '\t' => try out.appendSlice("\\t"),
        else => try out.append(ch),
    };
    return out.toOwnedSlice();
}

pub fn shellQuoteAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    try out.append('\'');
    for (text) |ch| {
        if (ch == '\'') {
            try out.appendSlice("'\"'\"'");
        } else {
            try out.append(ch);
        }
    }
    try out.append('\'');
    return out.toOwnedSlice();
}

pub fn readFileTailAlloc(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8, max_bytes: usize) ![]u8 {
    const abs = try resolvePathAlloc(allocator, cwd, path);
    defer allocator.free(abs);

    const file = try std.Io.Dir.cwd().openFile(rt.io, abs, .{});
    defer file.close(rt.io);

    const stat = try file.stat(rt.io);
    const size: usize = @intCast(stat.size);
    const take = @min(size, max_bytes);
    if (take == 0) return allocator.dupe(u8, "");

    const offset: u64 = @intCast(size - take);
    var out = try allocator.alloc(u8, take);
    errdefer allocator.free(out);
    const n = try file.readPositionalAll(rt.io, out, offset);
    if (n == out.len) return out;

    const clipped = try allocator.alloc(u8, n);
    @memcpy(clipped, out[0..n]);
    allocator.free(out);
    return clipped;
}

const testing = std.testing;

test "escape/unescape roundtrip" {
    const src = "hello\nworld\\x";
    const escaped = try escapeTextAlloc(testing.allocator, src);
    defer testing.allocator.free(escaped);
    const restored = try unescapeTextAlloc(testing.allocator, escaped);
    defer testing.allocator.free(restored);
    try testing.expectEqualStrings(src, restored);
}

test "findMatchingBracket finds closing array" {
    const txt = "{\"cells\":[{\"a\":1},{\"b\":2}],\"x\":1}";
    const open = std.mem.indexOfScalar(u8, txt, '[').?;
    const close = findMatchingBracket(txt, open, '[', ']').?;
    try testing.expectEqual(@as(u8, ']'), txt[close]);
}

test "isSafeIdentifier allows basic ids and rejects traversal forms" {
    try testing.expect(isSafeIdentifier("task-123_abc"));
    try testing.expect(!isSafeIdentifier("../escape"));
    try testing.expect(!isSafeIdentifier("team/name"));
    try testing.expect(!isSafeIdentifier(""));
}

test "normalizePath expands leading tilde to HOME" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return;
    const home = @import("../core/env.zig").getenv("HOME") orelse return error.SkipZigTest;
    if (home.len == 0) return error.SkipZigTest;

    // Bare tilde.
    {
        const got = try normalizePath(testing.allocator, "/some/cwd", "~");
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(home, got);
    }

    // Tilde-slash prefix.
    {
        const got = try normalizePath(testing.allocator, "/some/cwd", "~/notes.md");
        defer testing.allocator.free(got);
        const expected = try std.fs.path.join(testing.allocator, &.{ home, "notes.md" });
        defer testing.allocator.free(expected);
        try testing.expectEqualStrings(expected, got);
    }

    // Nested tilde-slash path (the specific case from the screenshot
    // bug: user asks ListDir for `~/Projects`).
    {
        const got = try normalizePath(testing.allocator, "/some/cwd", "~/Projects");
        defer testing.allocator.free(got);
        const expected = try std.fs.path.join(testing.allocator, &.{ home, "Projects" });
        defer testing.allocator.free(expected);
        try testing.expectEqualStrings(expected, got);
    }
}

test "normalizePath leaves non-tilde paths unchanged" {
    // Absolute stays absolute.
    {
        const got = try normalizePath(testing.allocator, "/some/cwd", "/abs/path");
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("/abs/path", got);
    }
    // Relative joins with cwd.
    {
        const got = try normalizePath(testing.allocator, "/some/cwd", "rel/path");
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("/some/cwd/rel/path", got);
    }
    // `~alice/...` (other-user home) passes through unchanged and
    // joins against cwd like any other relative path.
    {
        const got = try normalizePath(testing.allocator, "/some/cwd", "~alice/file.txt");
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("/some/cwd/~alice/file.txt", got);
    }
}
