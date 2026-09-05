const std = @import("std");
const rt = @import("zcode_runtime");

pub const PRIMARY_HOME_DIR = ".zcode";
pub const PRIMARY_WORKSPACE_DIR = ".zcode";
pub const PRIMARY_IGNORE_FILE = ".zcodeignore";

pub const PathSet = struct {
    zcode_home: []u8,
    user_config_path: []u8,
    policy_path: []u8,
    permission_rules_path: []u8,
    sessions_dir: []u8,
    logs_dir: []u8,
    mcp_registry_path: []u8,
    keybindings_path: []u8,

    pub fn deinit(self: *PathSet, allocator: std.mem.Allocator) void {
        allocator.free(self.zcode_home);
        allocator.free(self.user_config_path);
        allocator.free(self.policy_path);
        allocator.free(self.permission_rules_path);
        allocator.free(self.sessions_dir);
        allocator.free(self.logs_dir);
        allocator.free(self.mcp_registry_path);
        allocator.free(self.keybindings_path);
    }
};

pub fn resolve(allocator: std.mem.Allocator) !PathSet {
    const home = @import("env.zig").getOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableMissing => try allocator.dupe(u8, "/tmp"),
        else => return err,
    };
    defer allocator.free(home);

    // Compat-friendly XDG precedence:
    //   1. If ~/.zcode/ already exists, keep using it (don't break
    //      existing installs that have session history there).
    //   2. Else if $XDG_CONFIG_HOME is set, use $XDG_CONFIG_HOME/zcode/.
    //   3. Else fall back to ~/.zcode/ (the legacy default).
    // This mirrors what `gh` and `cargo` do: XDG-friendly for new
    // installs, backwards-compatible for existing ones.
    const legacy_home = try std.fs.path.join(allocator, &.{ home, PRIMARY_HOME_DIR });
    defer allocator.free(legacy_home);

    const zcode_home = blk: {
        const legacy_exists = if (std.Io.Dir.openDirAbsolute(rt.io, legacy_home, .{})) |*d| done: {
            var dir = d.*;
            dir.close(rt.io);
            break :done true;
        } else |_| false;
        if (legacy_exists) break :blk try allocator.dupe(u8, legacy_home);

        if (@import("env.zig").getOwned(allocator, "XDG_CONFIG_HOME")) |xdg| {
            defer allocator.free(xdg);
            if (xdg.len > 0) {
                break :blk try std.fs.path.join(allocator, &.{ xdg, "zcode" });
            }
        } else |_| {}

        break :blk try allocator.dupe(u8, legacy_home);
    };
    errdefer allocator.free(zcode_home);
    const user_config_path = try std.fs.path.join(allocator, &.{ zcode_home, "config.toml" });
    errdefer allocator.free(user_config_path);
    const policy_path = try std.fs.path.join(allocator, &.{ zcode_home, "policy", "policy.toml" });
    errdefer allocator.free(policy_path);
    const permission_rules_path = try std.fs.path.join(allocator, &.{ zcode_home, "permissions", "rules.tsv" });
    errdefer allocator.free(permission_rules_path);
    const sessions_dir = try std.fs.path.join(allocator, &.{ zcode_home, "sessions" });
    errdefer allocator.free(sessions_dir);
    const logs_dir = try std.fs.path.join(allocator, &.{ zcode_home, "logs" });
    errdefer allocator.free(logs_dir);
    const mcp_registry_path = try std.fs.path.join(allocator, &.{ zcode_home, "mcp", "servers.json" });
    errdefer allocator.free(mcp_registry_path);
    const keybindings_path = try std.fs.path.join(allocator, &.{ zcode_home, "keybindings.json" });

    return .{
        .zcode_home = zcode_home,
        .user_config_path = user_config_path,
        .policy_path = policy_path,
        .permission_rules_path = permission_rules_path,
        .sessions_dir = sessions_dir,
        .logs_dir = logs_dir,
        .mcp_registry_path = mcp_registry_path,
        .keybindings_path = keybindings_path,
    };
}

pub fn workspaceConfigPath(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    return workspacePathAlloc(allocator, cwd, "config.toml");
}

pub fn workspacePathAlloc(allocator: std.mem.Allocator, cwd: []const u8, rel_inside_home: []const u8) ![]u8 {
    const home_name = try workspaceDirNameAlloc(allocator, cwd);
    defer allocator.free(home_name);
    return std.fs.path.join(allocator, &.{ cwd, home_name, rel_inside_home });
}

pub fn workspaceRelativePathAlloc(allocator: std.mem.Allocator, cwd: []const u8, rel_inside_home: []const u8) ![]u8 {
    const home_name = try workspaceDirNameAlloc(allocator, cwd);
    defer allocator.free(home_name);
    return std.fs.path.join(allocator, &.{ home_name, rel_inside_home });
}

pub fn workspaceIgnorePath(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ cwd, PRIMARY_IGNORE_FILE });
}

/// File name of a project-scope MCP config (`.mcp.json`). Used by the scoped
/// config loader's parent-directory traversal. Mirrors the reference's
/// `.mcp.json` project file name.
pub const mcpJsonName = ".mcp.json";

/// Absolute path to the enterprise managed MCP config file. When this file
/// exists, enterprise scope takes exclusive control of the MCP server list
/// (`config.ts:1071-1084`). The location mirrors a system-managed-settings
/// path: `/Library/Application Support/zcode` on macOS, `/etc/zcode`
/// elsewhere on POSIX. Returns an allocator-owned absolute path.
pub fn enterpriseMcpPath(allocator: std.mem.Allocator) ![]u8 {
    const builtin = @import("builtin");
    const base = switch (builtin.os.tag) {
        .macos => "/Library/Application Support/zcode",
        else => "/etc/zcode",
    };
    return std.fs.path.join(allocator, &.{ base, "managed-mcp.json" });
}

pub fn workspaceDirNameAlloc(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    _ = cwd;
    return allocator.dupe(u8, PRIMARY_WORKSPACE_DIR);
}

/// Cap on a sanitized per-project session-directory slug before a stable
/// hash suffix is appended (sessions-storage-02), matching Claude Code's own
/// `MAX_SANITIZED_LENGTH` in `sessionStoragePortable.ts`.
pub const MAX_SANITIZED_PROJECT_SLUG_LEN: usize = 200;

/// Derive a filesystem-safe per-project directory slug from an absolute
/// `cwd`, mirroring Claude Code's `sanitizePath`: every byte outside
/// `[a-zA-Z0-9]` becomes `-`, and a slug longer than
/// `MAX_SANITIZED_PROJECT_SLUG_LEN` is truncated with a stable FNV-1a hash
/// suffix (computed over the FULL sanitized string, not just the truncated
/// prefix) so two long paths sharing a 200-char prefix never collide.
/// Empty `cwd` maps to `"unknown"` -- sessions-storage-02's
/// `Store.projectDirForCwd` uses this for sessions with no known origin
/// rather than silently dropping them. Mirrors (in spirit, not literal
/// implementation) the simpler per-project key `core/kairos_lock.projectKey`
/// already uses for the KAIROS lock directory. Caller owns the result.
pub fn projectSlug(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    if (cwd.len == 0) return allocator.dupe(u8, "unknown");

    const sanitized = try allocator.alloc(u8, cwd.len);
    defer allocator.free(sanitized);
    for (cwd, 0..) |c, i| {
        const is_alnum = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
        sanitized[i] = if (is_alnum) c else '-';
    }

    if (sanitized.len <= MAX_SANITIZED_PROJECT_SLUG_LEN) {
        return allocator.dupe(u8, sanitized);
    }

    var hash: u64 = 0xcbf29ce484222325; // FNV-1a offset basis
    for (sanitized) |b| {
        hash ^= b;
        hash *%= 0x100000001b3; // FNV-1a prime
    }
    return std.fmt.allocPrint(allocator, "{s}-{x}", .{ sanitized[0..MAX_SANITIZED_PROJECT_SLUG_LEN], hash });
}

pub fn ensureDir(path: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(rt.io, path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        // 0.16 std.Io.Dir.createDirPath returns NotDir when an existing
        // path component is a symlink, even when the symlink target IS
        // a directory (e.g. /tmp -> private/tmp on macOS). Treat
        // accessible-as-directory as success.
        error.NotDir => {
            var probe = std.Io.Dir.cwd().openDir(rt.io, path, .{}) catch return err;
            probe.close(rt.io);
        },
        else => return err,
    };
}

const testing = std.testing;
test "workspaceDirNameAlloc returns dir" {
    const alloc = testing.allocator;
    const name = try workspaceDirNameAlloc(alloc, "/p");
    defer alloc.free(name);
    try testing.expectEqualStrings(PRIMARY_WORKSPACE_DIR, name);
}

test "projectSlug sanitizes non-alnum bytes and handles empty/long input" {
    const alloc = testing.allocator;

    const empty = try projectSlug(alloc, "");
    defer alloc.free(empty);
    try testing.expectEqualStrings("unknown", empty);

    const simple = try projectSlug(alloc, "/Users/dev/zig-code");
    defer alloc.free(simple);
    try testing.expectEqualStrings("-Users-dev-zig-code", simple);

    // Two different long paths sharing the same 200-char prefix must
    // produce different slugs (via the hash suffix), not collide.
    const prefix = "/Users/dev/" ++ ("x" ** 200);
    const a = try projectSlug(alloc, prefix ++ "/project-a");
    defer alloc.free(a);
    const b = try projectSlug(alloc, prefix ++ "/project-b");
    defer alloc.free(b);
    try testing.expect(!std.mem.eql(u8, a, b));
    try testing.expect(a.len > MAX_SANITIZED_PROJECT_SLUG_LEN);
}
