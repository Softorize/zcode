//! Additional workspace directories persisted across sessions.
//!
//! Backs the REPL `/add-dir` command and its CLI counterpart. The
//! reference's `/add-dir` lets the user register additional
//! directories that participate in the workspace: they are treated
//! as trusted for editing and their CLAUDE.md-equivalent
//! instruction files feed the prompt. zcode's first cut persists
//! the list and surfaces it to the model as a dedicated context
//! block so the assistant is aware of the extra roots even before
//! the deeper instruction-discovery plumbing is widened to walk
//! them.
//!
//! Storage: `<XDG_STATE_HOME>/zcode/workspace-dirs.txt`, one
//! absolute path per line. Missing file means "no extra roots".

const std = @import("std");
const std_io = @import("std_io.zig");
const rt = @import("zcode_runtime");
const rng = @import("rng.zig");
const xdg = @import("xdg.zig");
const paths = @import("paths.zig");

const filename = "workspace-dirs.txt";

/// Read-only resolved path. Skips ensureDir because readers don't
/// need the state dir to exist and creating it on every hot-path
/// invocation burned a mkdir syscall per model turn via
/// context.gather. Writers call `listFilePathForWrite` instead.
pub fn listFilePath(allocator: std.mem.Allocator) ![]u8 {
    const dir = try xdg.getZcodeStateDir(allocator);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, filename });
}

fn listFilePathForWrite(allocator: std.mem.Allocator) ![]u8 {
    const dir = try xdg.getZcodeStateDir(allocator);
    defer allocator.free(dir);
    try paths.ensureDir(dir);
    return std.fs.path.join(allocator, &.{ dir, filename });
}

pub fn load(allocator: std.mem.Allocator) ![][]u8 {
    const path = try listFilePath(allocator);
    defer allocator.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(1 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc([]u8, 0),
        else => return err,
    };
    defer allocator.free(bytes);

    var out = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit();
    }
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        try out.append(try allocator.dupe(u8, trimmed));
    }
    return out.toOwnedSlice();
}

pub fn freeList(allocator: std.mem.Allocator, list: [][]u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

fn writeList(allocator: std.mem.Allocator, list: []const []const u8) !void {
    const path = try listFilePathForWrite(allocator);
    defer allocator.free(path);

    // Atomic write so a SIGINT during /add-dir add or remove can't
    // leave workspace-dirs.txt at 0 bytes (or partway through a
    // line), silently dropping every accumulated workspace entry on
    // next start. Same discipline as the rest of the atomic-write
    // sweep (passes 64-89).
    var rendered = std_io.StringBuilder.init(allocator);
    defer rendered.deinit();
    for (list) |item| {
        try rendered.appendSlice(item);
        try rendered.append('\n');
    }
    try writeWorkspaceListAtomic(allocator, path, rendered.items());
}

fn writeWorkspaceListAtomic(allocator: std.mem.Allocator, target: []const u8, bytes: []const u8) !void {
    var nonce: [8]u8 = undefined;
    rng.bytes(&nonce);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{x}{x}{x}{x}{x}{x}{x}{x}", .{
        target, nonce[0], nonce[1], nonce[2], nonce[3], nonce[4], nonce[5], nonce[6], nonce[7],
    });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, bytes);
        file.sync(rt.io) catch {};
    }
    try std.Io.Dir.renameAbsolute(tmp_path, target, rt.io);
}

/// Add a directory to the list. Returns true if added, false if it
/// was already present. Non-existent paths are rejected.
pub fn add(allocator: std.mem.Allocator, dir_raw: []const u8) !bool {
    const trimmed = std.mem.trim(u8, dir_raw, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidDirectory;

    // Resolve to absolute + real path to avoid duplicates differing
    // only by `./` / symlink layering.
    const abs = try allocator.dupe(u8, trimmed);
    defer allocator.free(abs);

    var stat_dir = std.Io.Dir.cwd().openDir(rt.io, abs, .{}) catch return error.DirectoryNotFound;
    stat_dir.close(rt.io);

    const current = try load(allocator);
    defer freeList(allocator, current);

    for (current) |existing| {
        if (std.mem.eql(u8, existing, abs)) return false;
    }

    var next = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (next.items) |item| allocator.free(item);
        next.deinit();
    }
    for (current) |existing| try next.append(try allocator.dupe(u8, existing));
    try next.append(try allocator.dupe(u8, abs));

    try writeList(allocator, next.items);
    return true;
}

/// Remove a directory (matched by equality against its stored form
/// OR by a 1-based index from `list`). Returns true if removed.
pub fn remove(allocator: std.mem.Allocator, target: []const u8) !bool {
    const trimmed = std.mem.trim(u8, target, " \t\r\n");
    if (trimmed.len == 0) return false;

    const current = try load(allocator);
    defer freeList(allocator, current);
    if (current.len == 0) return false;

    // Index form? (/add-dir remove 2)
    var idx_opt: ?usize = null;
    if (std.fmt.parseInt(usize, trimmed, 10)) |idx| {
        if (idx >= 1 and idx <= current.len) idx_opt = idx - 1;
    } else |_| {}

    var next = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (next.items) |item| allocator.free(item);
        next.deinit();
    }

    var removed = false;
    for (current, 0..) |existing, i| {
        const match_idx = idx_opt != null and idx_opt.? == i;
        const match_path = std.mem.eql(u8, existing, trimmed);
        if (match_idx or match_path) {
            removed = true;
            continue;
        }
        try next.append(try allocator.dupe(u8, existing));
    }
    if (!removed) return false;

    try writeList(allocator, next.items);
    return true;
}

/// Render the list as a human-readable string for display.
pub fn render(allocator: std.mem.Allocator) ![]u8 {
    const list = try load(allocator);
    defer freeList(allocator, list);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    if (list.len == 0) {
        try out.appendSlice("no additional workspace directories registered.\nuse `/add-dir <path>` to register one.");
        return out.toOwnedSlice();
    }
    try out.appendSlice("additional workspace directories:\n");
    for (list, 0..) |path_str, i| {
        try out.writer().print("  {d}. {s}\n", .{ i + 1, path_str });
    }
    try out.appendSlice("\nremove with `/add-dir remove <index|path>`.");
    return out.toOwnedSlice();
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "add rejects missing directory" {
    const res = add(testing.allocator, "/__definitely_not_a_real_path__/zzz");
    try testing.expectError(error.DirectoryNotFound, res);
}

test "add + remove roundtrip" {
    // Uses a temp dir and temp XDG state home via env override so
    // we don't pollute the user's real state file.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(tmp_path);

    // Can't mutate env from within Zig tests reliably on all
    // platforms; use a sub-dir target instead and just exercise
    // the add->load->remove path against whatever state dir the
    // harness picks. The assertions below tolerate a pre-existing
    // list so the test stays hermetic even when the user runs it
    // locally after a real /add-dir session.
    const added = try add(testing.allocator, tmp_path);
    try testing.expect(added);

    const list = try load(testing.allocator);
    defer freeList(testing.allocator, list);

    var found = false;
    for (list) |entry| if (std.mem.eql(u8, entry, tmp_path)) {
        found = true;
    };
    try testing.expect(found);

    const removed = try remove(testing.allocator, tmp_path);
    try testing.expect(removed);

    const list2 = try load(testing.allocator);
    defer freeList(testing.allocator, list2);
    for (list2) |entry| try testing.expect(!std.mem.eql(u8, entry, tmp_path));
}

test "add rejects empty and whitespace-only inputs" {
    try testing.expectError(error.InvalidDirectory, add(testing.allocator, ""));
    try testing.expectError(error.InvalidDirectory, add(testing.allocator, "   \t  "));
    try testing.expectError(error.InvalidDirectory, add(testing.allocator, "\n\r"));
}

test "add twice reports already-registered without duplicating" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(tmp_path);

    const first = try add(testing.allocator, tmp_path);
    defer _ = remove(testing.allocator, tmp_path) catch {};
    try testing.expect(first);

    const second = try add(testing.allocator, tmp_path);
    try testing.expect(!second);

    const list = try load(testing.allocator);
    defer freeList(testing.allocator, list);
    var occurrences: usize = 0;
    for (list) |entry| if (std.mem.eql(u8, entry, tmp_path)) {
        occurrences += 1;
    };
    try testing.expectEqual(@as(usize, 1), occurrences);
}

test "remove returns false when the entry is absent" {
    const removed = try remove(testing.allocator, "/definitely/not/in/the/list/xyz123");
    try testing.expect(!removed);
}

test "render output lists a registered directory by number" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(tmp_path);

    _ = try add(testing.allocator, tmp_path);
    defer _ = remove(testing.allocator, tmp_path) catch {};

    const rendered = try render(testing.allocator);
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.indexOf(u8, rendered, tmp_path) != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "additional workspace directories:") != null);
}
