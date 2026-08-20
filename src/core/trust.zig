const std = @import("std");
const rt = @import("zcode_runtime");
const clock = @import("clock.zig");
const std_io = @import("std_io.zig");
const display_safe = @import("display_safe.zig");
const paths = @import("paths.zig");

pub const TrustSource = enum {
    none,
    user_store,
    workspace_marker,
};

pub const TrustStatus = struct {
    trusted: bool,
    source: TrustSource,
    root_path: []u8,

    pub fn deinit(self: *TrustStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.root_path);
    }
};

pub fn status(allocator: std.mem.Allocator, cwd: []const u8) !TrustStatus {
    const root = try projectRoot(allocator, cwd);
    errdefer allocator.free(root);

    // NOTE: we deliberately do NOT consult the workspace marker
    // (`<root>/.zcode/trusted`) as a trust oracle here. A file committed
    // into a cloned repository could otherwise flip `trusted=true` on
    // first access, turning repo-clone into auto-trust. The user store
    // (`~/.config/zcode/trust/repos.json`) is the sole authoritative
    // source of trust. The workspace marker is kept writable for
    // downstream tools that may still check it, but it can only confirm
    // a decision the user already made via `zcode trust allow`.
    const entries = try loadEntriesForRoot(allocator, null);
    defer freeEntries(allocator, entries);
    for (entries) |entry| {
        if (pathContains(entry, root)) {
            return .{
                .trusted = true,
                .source = .user_store,
                .root_path = root,
            };
        }
    }

    return .{
        .trusted = false,
        .source = .none,
        .root_path = root,
    };
}

pub fn allow(allocator: std.mem.Allocator, cwd: []const u8, target: ?[]const u8) ![]u8 {
    const root = try targetRoot(allocator, cwd, target);
    defer allocator.free(root);

    const store_path = try userTrustStorePath(allocator);
    defer allocator.free(store_path);

    const entries = try loadEntriesForRoot(allocator, store_path);
    defer freeEntries(allocator, entries);

    var updated = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (updated.items) |entry| allocator.free(entry);
        updated.deinit();
    }

    var already_present = false;
    for (entries) |entry| {
        if (std.mem.eql(u8, entry, root)) {
            already_present = true;
        }
        const duped = try allocator.dupe(u8, entry);
        updated.append(duped) catch |err| {
            allocator.free(duped);
            return err;
        };
    }

    if (!already_present) {
        const duped = try allocator.dupe(u8, root);
        updated.append(duped) catch |err| {
            allocator.free(duped);
            return err;
        };
    }

    try writeEntries(allocator, store_path, updated.items);
    try writeWorkspaceMarker(allocator, root);

    return std.fmt.allocPrint(allocator, "trusted repo: {s}", .{root});
}

pub fn revoke(allocator: std.mem.Allocator, cwd: []const u8, target: ?[]const u8) ![]u8 {
    const root = try targetRoot(allocator, cwd, target);
    defer allocator.free(root);

    const store_path = try userTrustStorePath(allocator);
    defer allocator.free(store_path);

    const entries = try loadEntriesForRoot(allocator, store_path);
    defer freeEntries(allocator, entries);

    var updated = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (updated.items) |entry| allocator.free(entry);
        updated.deinit();
    }

    var removed = false;
    for (entries) |entry| {
        if (std.mem.eql(u8, entry, root)) {
            removed = true;
            continue;
        }
        const duped = try allocator.dupe(u8, entry);
        updated.append(duped) catch |err| {
            allocator.free(duped);
            return err;
        };
    }

    if (!removed) {
        // Nothing was trusted for this root - tell the caller so the
        // CLI can exit 1 for parity with `mcp remove`,
        // `plugins uninstall`, `commands uninstall`,
        // `keychain delete`. Also surfaces a typo (e.g. revoking a
        // path that was never granted) instead of reporting success.
        return error.TrustEntryNotFound;
    }

    try writeEntries(allocator, store_path, updated.items);
    deleteWorkspaceMarker(allocator, root) catch {};

    return std.fmt.allocPrint(allocator, "revoked repo trust: {s}", .{root});
}

pub fn renderStatus(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    var current = try status(allocator, cwd);
    defer current.deinit(allocator);
    // root_path is filesystem-derived. On POSIX with sane filenames
    // it's always printable, but a path containing a literal newline
    // (legal at the filesystem layer) would corrupt the TSV row.
    const safe_root = try display_safe.sanitize(allocator, current.root_path);
    defer allocator.free(safe_root);
    return std.fmt.allocPrint(
        allocator,
        "trust\ttrusted={}\tsource={s}\troot={s}\n",
        .{ current.trusted, sourceName(current.source), safe_root },
    );
}

pub fn sourceName(source: TrustSource) []const u8 {
    return switch (source) {
        .none => "none",
        .user_store => "user-store",
        .workspace_marker => "workspace-marker",
    };
}

fn targetRoot(allocator: std.mem.Allocator, cwd: []const u8, target: ?[]const u8) ![]u8 {
    if (target) |value| {
        const normalized = try normalizePath(allocator, cwd, value);
        defer allocator.free(normalized);
        return projectRoot(allocator, normalized);
    }
    return projectRoot(allocator, cwd);
}

fn projectRoot(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const git_args = [_][]const u8{
        "git",
        "-C",
        cwd,
        "rev-parse",
        "--show-toplevel",
    };
    const res = std.process.run(allocator, rt.io, .{
        .argv = &git_args,
        .stdout_limit = .limited(8 * 1024),
        .stderr_limit = .limited(8 * 1024),
    }) catch return realpathOrSelf(allocator, cwd);
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    if (res.term == .exited and res.term.exited == 0) {
        const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
        if (trimmed.len > 0) return realpathOrSelf(allocator, trimmed);
    }
    return realpathOrSelf(allocator, cwd);
}

fn realpathOrSelf(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return allocator.dupe(u8, path) catch allocator.dupe(u8, path);
}

fn normalizePath(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.path.join(allocator, &.{ cwd, path });
}

fn userTrustStorePath(allocator: std.mem.Allocator) ![]u8 {
    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);
    return std.fs.path.join(allocator, &.{ resolved.zcode_home, "trust", "repos.json" });
}

fn markerPath(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    const workspace_dir = try paths.workspaceDirNameAlloc(allocator, root);
    defer allocator.free(workspace_dir);
    return std.fs.path.join(allocator, &.{ root, workspace_dir, "trusted" });
}

fn markerExists(allocator: std.mem.Allocator, root: []const u8) !bool {
    const marker = try markerPath(allocator, root);
    defer allocator.free(marker);
    return fileExists(marker);
}

fn writeWorkspaceMarker(allocator: std.mem.Allocator, root: []const u8) !void {
    const marker = try markerPath(allocator, root);
    defer allocator.free(marker);
    const parent = std.fs.path.dirname(marker) orelse root;
    try paths.ensureDir(parent);

    const file = try std.Io.Dir.cwd().createFile(rt.io, marker, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
    defer file.close(rt.io);
    try file.writeStreamingAll(rt.io, "trusted\n");
    file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o600)) catch |err| {
        std.log.warn("trust: chmod failed: {s}", .{@errorName(err)});
    };
}

fn deleteWorkspaceMarker(allocator: std.mem.Allocator, root: []const u8) !void {
    const marker = try markerPath(allocator, root);
    defer allocator.free(marker);
    std.Io.Dir.cwd().deleteFile(rt.io, marker) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn loadEntriesForRoot(allocator: std.mem.Allocator, store_path_or_null: ?[]const u8) ![][]u8 {
    const store_path = if (store_path_or_null) |path|
        path
    else
        try userTrustStorePath(allocator);
    defer if (store_path_or_null == null) allocator.free(store_path);

    // Refuse to follow a symlink at the trust store path. A local attacker
    // who can write into `~/.config/zcode/trust/` could otherwise replace
    // `repos.json` with a link to arbitrary JSON elsewhere on disk. On
    // platforms without a lstat path API this is best-effort; a
    // `readLink` success means the path is a symlink and we drop the
    // read rather than silently dereferencing it.
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.Io.Dir.cwd().readLink(rt.io, store_path, &link_buf)) |_| {
        std.log.warn("trust: refusing symlinked trust store at {s}", .{store_path});
        return allocator.alloc([]u8, 0);
    } else |_| {}

    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, store_path, allocator, .limited(512 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc([]u8, 0),
        else => return err,
    };
    defer allocator.free(bytes);

    // Corrupt trust store used to bubble up `error.SyntaxError`
    // through the agent-runtime envelope, which looked like a
    // provider crash on `zcode trust status`. Before we silently
    // returned an empty list the operator would lose visibility
    // on which workspaces are trusted; we want them to KNOW the
    // file is broken and fix it.
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| switch (err) {
        error.SyntaxError, error.UnexpectedToken, error.InvalidCharacter, error.UnexpectedEndOfInput => {
            std_io.stderrWriter().print(
                "error: trust: trust store is not valid JSON ({s}): {s}\n  - Fix or delete the file; a new empty store will be created on next `trust allow`.\n",
                .{ @errorName(err), store_path },
            ) catch {};
            return error.InvalidTrustStore;
        },
        else => return err,
    };
    defer parsed.deinit();

    if (parsed.value != .array) return allocator.alloc([]u8, 0);

    var out = std.array_list.Managed([]u8).init(allocator);
    defer out.deinit();

    for (parsed.value.array.items) |item| {
        switch (item) {
            .string => |s| try out.append(try allocator.dupe(u8, s)),
            .object => |obj| {
                const path_value = obj.get("path") orelse continue;
                if (path_value != .string) continue;
                try out.append(try allocator.dupe(u8, path_value.string));
            },
            else => {},
        }
    }

    return out.toOwnedSlice();
}

fn writeEntries(allocator: std.mem.Allocator, store_path: []const u8, entries: []const []u8) !void {
    const parent = std.fs.path.dirname(store_path) orelse return error.InvalidPath;
    try paths.ensureDir(parent);

    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    try buf.appendSlice("[\n");
    for (entries, 0..) |entry, idx| {
        if (idx > 0) try buf.appendSlice(",\n");
        try buf.writer().print("  {f}", .{std.json.fmt(.{
            .path = entry,
            .updated_ts = clock.nowSeconds(),
        }, .{})});
    }
    try buf.appendSlice("\n]\n");

    // Atomic write: stage into a sibling .tmp, fsync, rename over the
    // target. This prevents a crash mid-write from leaving the trust
    // store truncated (losing all trusted roots), and it mitigates a
    // symlink-replacement race because the tmp file is opened fresh.
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ store_path, clock.nowNanos() });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, buf.items());
        file.sync(rt.io) catch {};
        file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o600)) catch |err| {
            std.log.warn("trust: chmod failed: {s}", .{@errorName(err)});
        };
    }
    try std.Io.Dir.renameAbsolute(tmp_path, store_path, rt.io);
}

fn pathContains(parent: []const u8, child: []const u8) bool {
    if (std.mem.eql(u8, parent, child)) return true;
    if (child.len <= parent.len) return false;
    if (!std.mem.startsWith(u8, child, parent)) return false;
    return child[parent.len] == std.fs.path.sep;
}

fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(rt.io, path, .{}) catch return false;
    return true;
}

fn freeEntries(allocator: std.mem.Allocator, entries: [][]u8) void {
    for (entries) |entry| allocator.free(entry);
    allocator.free(entries);
}

const testing = std.testing;

test "pathContains handles exact and descendant paths" {
    try testing.expect(pathContains("/repo", "/repo"));
    try testing.expect(pathContains("/repo", "/repo/src"));
    try testing.expect(!pathContains("/repo", "/repo-other"));
}

test "renderStatus reports current repo trust" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const rendered = try renderStatus(testing.allocator, cwd);
    defer testing.allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "trust\ttrusted=") != null);
}

test "pathContains rejects sibling directories with matching prefixes" {
    try testing.expect(!pathContains("/repo", "/repository"));
    try testing.expect(!pathContains("/a/b", "/a/bc"));
    try testing.expect(!pathContains("/a/b", "/a"));
}

test "pathContains requires a path separator at the boundary" {
    // Inputs are expected to be canonical (no trailing slash) --
    // callers always pass realpath outputs. This test locks that
    // contract: /repo matches /repo/src (sep at boundary) but not
    // /repo-other (letter) and not /repository (letter).
    try testing.expect(pathContains("/repo", "/repo/src"));
    try testing.expect(!pathContains("/repo", "/repo-other"));
    try testing.expect(!pathContains("/repo", "/repository"));
}

test "sourceName maps every TrustSource variant" {
    try testing.expectEqualStrings("none", sourceName(.none));
    try testing.expectEqualStrings("user-store", sourceName(.user_store));
    try testing.expectEqualStrings("workspace-marker", sourceName(.workspace_marker));
}

test "normalizePath leaves absolute paths untouched" {
    const abs = try normalizePath(testing.allocator, "/anywhere", "/etc/hosts");
    defer testing.allocator.free(abs);
    try testing.expectEqualStrings("/etc/hosts", abs);
}

test "normalizePath joins relative paths to cwd" {
    const joined = try normalizePath(testing.allocator, "/home/u/work", "sub/dir");
    defer testing.allocator.free(joined);
    try testing.expectEqualStrings("/home/u/work/sub/dir", joined);
}

test "markerExists returns false for a fresh directory with no marker" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    try testing.expect(!try markerExists(testing.allocator, cwd));
}

test "writeWorkspaceMarker + markerExists + deleteWorkspaceMarker round-trip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    try testing.expect(!try markerExists(testing.allocator, cwd));
    try writeWorkspaceMarker(testing.allocator, cwd);
    try testing.expect(try markerExists(testing.allocator, cwd));

    try deleteWorkspaceMarker(testing.allocator, cwd);
    try testing.expect(!try markerExists(testing.allocator, cwd));

    // Deleting a non-existent marker is idempotent, not an error.
    try deleteWorkspaceMarker(testing.allocator, cwd);
}
