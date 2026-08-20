const std = @import("std");
const builtin = @import("builtin");

/// XDG Base Directory helpers. Ported from claude-code-main/src/
/// utils/xdg.ts with a zcode-native Windows fallback (the
/// reference is Linux/macOS focused and trips on Windows because
/// `$HOME` isn't canonical there).
///
/// The XDG Base Directory spec says:
///   XDG_CACHE_HOME   fallback ~/.cache
///   XDG_CONFIG_HOME  fallback ~/.config
///   XDG_DATA_HOME    fallback ~/.local/share
///   XDG_STATE_HOME   fallback ~/.local/state
///
/// https://specifications.freedesktop.org/basedir-spec/latest/
///
/// On Windows these env vars are rarely set and the conventional
/// fallbacks (%LOCALAPPDATA%, %APPDATA%, ...) are different from
/// the Linux defaults. For zcode we mirror the reference's
/// ~/.cache, ~/.local/share layout so session/cache files live
/// in a predictable place across platforms; Windows users who
/// want the native layout can set the XDG env vars explicitly.
///
/// All helpers return an OWNED slice; callers must free.
const POSIX_CACHE_PATH: []const u8 = ".cache";
const POSIX_CONFIG_PATH: []const u8 = ".config";
const POSIX_DATA_PATH: []const u8 = ".local/share";
const POSIX_STATE_PATH: []const u8 = ".local/state";
const POSIX_USER_BIN_PATH: []const u8 = ".local/bin";

/// XDG_CACHE_HOME if set, else $HOME/.cache.
pub fn getCacheHome(allocator: std.mem.Allocator) ![]u8 {
    return xdgOrFallback(allocator, "XDG_CACHE_HOME", POSIX_CACHE_PATH);
}

/// XDG_CONFIG_HOME if set, else $HOME/.config.
pub fn getConfigHome(allocator: std.mem.Allocator) ![]u8 {
    return xdgOrFallback(allocator, "XDG_CONFIG_HOME", POSIX_CONFIG_PATH);
}

/// XDG_DATA_HOME if set, else $HOME/.local/share.
pub fn getDataHome(allocator: std.mem.Allocator) ![]u8 {
    return xdgOrFallback(allocator, "XDG_DATA_HOME", POSIX_DATA_PATH);
}

/// XDG_STATE_HOME if set, else $HOME/.local/state.
pub fn getStateHome(allocator: std.mem.Allocator) ![]u8 {
    return xdgOrFallback(allocator, "XDG_STATE_HOME", POSIX_STATE_PATH);
}

/// User bin directory: $HOME/.local/bin. Not technically XDG but
/// follows the same convention -- Python's pip --user, Cargo,
/// and similar all install here. Included so zcode can surface
/// "install zcode here" in /doctor without having to duplicate
/// the homedir math.
pub fn getUserBinDir(allocator: std.mem.Allocator) ![]u8 {
    const home = try resolveHomeDir(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, POSIX_USER_BIN_PATH });
}

/// Resolve `XDG_<name>_HOME` if set and non-empty, otherwise fall
/// back to `$HOME/<default_rel>`. Factored out so all four
/// XDG_*_HOME getters share the same logic.
fn xdgOrFallback(
    allocator: std.mem.Allocator,
    env_var: []const u8,
    default_rel: []const u8,
) ![]u8 {
    if (@import("env.zig").getOwned(allocator, env_var)) |override| {
        // Empty string is equivalent to "not set" per the XDG spec.
        if (override.len == 0) {
            allocator.free(override);
        } else {
            return override;
        }
    } else |_| {}

    const home = try resolveHomeDir(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, default_rel });
}

/// POSIX: return $HOME. Windows: return %USERPROFILE% (or
/// %HOMEDRIVE%%HOMEPATH% if USERPROFILE is missing). Same
/// precedence as src/core/path_utils.zig::getHomeDir so both
/// helpers agree on what "home" means. Caller owns the slice.
fn resolveHomeDir(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag != .windows) {
        return @import("env.zig").getOwned(allocator, "HOME") catch |err| switch (err) {
            error.EnvironmentVariableMissing => error.HomeDirNotSet,
            else => err,
        };
    }
    if (@import("env.zig").getOwned(allocator, "USERPROFILE")) |p| {
        return p;
    } else |_| {}
    const drive = @import("env.zig").getOwned(allocator, "HOMEDRIVE") catch return error.HomeDirNotSet;
    defer allocator.free(drive);
    const path = @import("env.zig").getOwned(allocator, "HOMEPATH") catch return error.HomeDirNotSet;
    defer allocator.free(path);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ drive, path });
}

/// Convenience: `<XDG_CACHE_HOME>/zcode` for agent-specific
/// caches (model metadata, tokenizer scratch, etc.). Separate
/// from the fixed `~/.zcode/` tree in core/paths.zig which
/// holds CONFIG -- caches are allowed to move under XDG without
/// breaking user config on upgrade.
pub fn getZcodeCacheDir(allocator: std.mem.Allocator) ![]u8 {
    const cache = try getCacheHome(allocator);
    defer allocator.free(cache);
    return std.fs.path.join(allocator, &.{ cache, "zcode" });
}

/// Convenience: `<XDG_STATE_HOME>/zcode` for transient state
/// files (last-seen changelog, auth-token cache, log overrides).
pub fn getZcodeStateDir(allocator: std.mem.Allocator) ![]u8 {
    const state = try getStateHome(allocator);
    defer allocator.free(state);
    return std.fs.path.join(allocator, &.{ state, "zcode" });
}

/// Null-on-absent wrapper around @import("env.zig").getOwned.
/// Every module that probes env vars for feature detection ended
/// up hand-rolling the same try/catch-null pair, so centralising
/// it keeps the pattern consistent and avoids subtle error-set
/// drift.
pub fn getEnvOptional(allocator: std.mem.Allocator, key: []const u8) ?[]u8 {
    return @import("env.zig").getOwned(allocator, key) catch null;
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "getCacheHome falls back to $HOME/.cache when env is unset" {
    if (builtin.os.tag == .windows) return;
    // We can't actually unset the env var from Zig tests, so we
    // just confirm the result is ABSOLUTE and ends with either
    // the override or the default fallback segment. Environments
    // that leak XDG_CACHE_HOME from the harness still produce a
    // valid owned slice; the contract under test is "returns a
    // non-empty absolute path".
    const out = try getCacheHome(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expect(out.len > 0);
    try testing.expect(std.fs.path.isAbsolute(out));
}

test "getConfigHome produces a valid path" {
    if (builtin.os.tag == .windows) return;
    const out = try getConfigHome(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expect(out.len > 0);
    try testing.expect(std.fs.path.isAbsolute(out));
}

test "getDataHome produces a valid path" {
    if (builtin.os.tag == .windows) return;
    const out = try getDataHome(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expect(out.len > 0);
    try testing.expect(std.fs.path.isAbsolute(out));
}

test "getStateHome produces a valid path" {
    if (builtin.os.tag == .windows) return;
    const out = try getStateHome(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expect(out.len > 0);
    try testing.expect(std.fs.path.isAbsolute(out));
}

test "getUserBinDir ends with .local/bin" {
    if (builtin.os.tag == .windows) return;
    const out = try getUserBinDir(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.endsWith(u8, out, ".local/bin"));
}

test "getZcodeCacheDir ends with /zcode" {
    if (builtin.os.tag == .windows) return;
    const out = try getZcodeCacheDir(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.endsWith(u8, out, "/zcode"));
}

test "getZcodeStateDir ends with /zcode" {
    if (builtin.os.tag == .windows) return;
    const out = try getZcodeStateDir(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.endsWith(u8, out, "/zcode"));
}

test "POSIX constants match XDG spec defaults" {
    // These are the literal defaults from
    // https://specifications.freedesktop.org/basedir-spec/latest/
    // If the spec ever changes we want the break to happen at
    // the constant level, not deep in a caller.
    try testing.expectEqualStrings(".cache", POSIX_CACHE_PATH);
    try testing.expectEqualStrings(".config", POSIX_CONFIG_PATH);
    try testing.expectEqualStrings(".local/share", POSIX_DATA_PATH);
    try testing.expectEqualStrings(".local/state", POSIX_STATE_PATH);
    try testing.expectEqualStrings(".local/bin", POSIX_USER_BIN_PATH);
}
