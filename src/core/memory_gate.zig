//! Auto-memory gating chain + path resolution (memory-10).
//!
//! Single source of truth for "is auto-memory on" and "where does it live".
//! Every other piece of the memory subsystem (taxonomy prompt, MEMORY.md
//! index, turn-end extraction fork, session summarizer) gates on these so the
//! enable/disable decision and the resolved directory are computed in exactly
//! one place.
//!
//! Ported from claude-code-main/src/memdir/paths.ts:
//!   isAutoMemoryEnabled  (:30-55)  -> priority chain below
//!   validateMemoryPath   (:109-150)
//!   getAutoMemPath       (:223-235, override branch only)
//!   isAutoMemPath        (:274-278)
//!
//! Env name policy (matches core/env.zig's dual-name convention mirroring
//! envUtils.ts): zcode-native name is primary, the claude-code alias is
//! accepted for parity. We DO NOT invent new toggles beyond the reference set.

const std = @import("std");
const env = @import("env.zig");
const config = @import("config.zig");
const memory = @import("memory.zig");

/// Whether auto-memory features are enabled. Enabled by default. Priority
/// chain (first defined wins), porting paths.ts:30-55:
///   1. ZCODE_DISABLE_AUTO_MEMORY / CLAUDE_CODE_DISABLE_AUTO_MEMORY env:
///      truthy => OFF, defined-falsy => ON (the explicit env always wins).
///   2. ZCODE_SIMPLE / CLAUDE_CODE_SIMPLE (--bare) truthy => OFF.
///   3. cfg.auto_memory_enabled (settings.json autoMemoryEnabled): if the
///      user explicitly set it, that decision wins over the default.
///   4. Default: ON.
///
/// Note on ordering vs the reference: the env disable flag is checked before
/// SIMPLE and before the setting, exactly as paths.ts does, so a defined-falsy
/// ZCODE_DISABLE_AUTO_MEMORY=0 forces ON even when the setting says false.
pub fn isAutoMemoryEnabled(cfg: *const config.Config) bool {
    // 1. Explicit disable env (with claude alias). Truthy wins => OFF.
    if (envTruthyEither("ZCODE_DISABLE_AUTO_MEMORY", "CLAUDE_CODE_DISABLE_AUTO_MEMORY")) {
        return false;
    }
    // Defined-falsy on the disable flag forces ON regardless of anything below.
    if (envDefinedFalsyEither("ZCODE_DISABLE_AUTO_MEMORY", "CLAUDE_CODE_DISABLE_AUTO_MEMORY")) {
        return true;
    }
    // 2. --bare / SIMPLE => OFF.
    if (envTruthyEither("ZCODE_SIMPLE", "CLAUDE_CODE_SIMPLE")) {
        return false;
    }
    // 3. Explicit setting (tri-state). Only decisive when the user set it.
    if (cfg.auto_memory_enabled) |enabled| {
        return enabled;
    }
    // 4. Default ON.
    return true;
}

/// Normalize and validate a candidate auto-memory directory path. Ports
/// paths.ts validateMemoryPath (:109-150). Returns an owned, normalized path
/// with exactly one trailing separator, or null if unset/empty/rejected.
///
/// Rejected (would be dangerous as a write-allowlist root):
///   - relative ("../foo")            -> not absolute
///   - root / near-root ("/", "/a")   -> length < 3 after trailing-sep strip
///   - Windows drive-root ("C:")      -> /^[A-Za-z]:$/
///   - UNC ("\\srv\s", "//srv/s")     -> "\\" or "//" prefix
///   - embedded null byte             -> survives but can truncate in syscalls
///
/// When expand_tilde is true, a leading "~/" (or "~\\") expands against $HOME,
/// but bare "~", "~/", "~/.", "~/.." remainders are rejected (they would point
/// the allowlist at $HOME or an ancestor).
pub fn validateMemoryPath(
    allocator: std.mem.Allocator,
    raw: ?[]const u8,
    expand_tilde: bool,
) !?[]u8 {
    const input = raw orelse return null;
    if (input.len == 0) return null;

    // Reject an embedded null byte up front (mirrors the .includes('\0')
    // check; doing it here also keeps the tilde-expansion below from joining
    // a NUL-bearing remainder).
    if (std.mem.indexOfScalar(u8, input, 0) != null) return null;

    var candidate: []const u8 = input;
    var candidate_owned: ?[]u8 = null;
    defer if (candidate_owned) |c| allocator.free(c);

    if (expand_tilde and (std.mem.startsWith(u8, input, "~/") or std.mem.startsWith(u8, input, "~\\"))) {
        const rest = input[2..];
        // normalize('') == '.', normalize('.') == '.', normalize('foo/..') ==
        // '.', normalize('..') == '..'. Reject any remainder that normalizes
        // to "." or ".." (would expand to $HOME or an ancestor).
        const norm_rest = try normalizePath(allocator, if (rest.len == 0) "." else rest);
        defer allocator.free(norm_rest);
        if (std.mem.eql(u8, norm_rest, ".") or std.mem.eql(u8, norm_rest, "..")) {
            return null;
        }
        const home = env.getenv("HOME") orelse return null;
        if (home.len == 0) return null;
        const joined = try std.fs.path.join(allocator, &.{ home, rest });
        candidate_owned = joined;
        candidate = joined;
    }

    // UNC prefixes ("\\server\share" or "//server/share") are an opaque trust
    // boundary - reject before normalization. The reference checks this AFTER
    // node's normalize(), which on POSIX preserves backslashes; our normalizer
    // treats "\\" as a separator and would otherwise collapse "\\srv\s" into a
    // plausible-looking "/srv/s", so we must catch the prefix on the raw
    // candidate here instead.
    if (std.mem.startsWith(u8, candidate, "\\\\") or std.mem.startsWith(u8, candidate, "//")) {
        return null;
    }

    // normalize() then strip any trailing separators so we re-add exactly one.
    const normalized = try normalizePath(allocator, candidate);
    defer allocator.free(normalized);
    const stripped = std.mem.trimEnd(u8, normalized, "/\\");

    if (!std.fs.path.isAbsolute(stripped) or
        stripped.len < 3 or
        isWindowsDriveRoot(stripped) or
        std.mem.indexOfScalar(u8, stripped, 0) != null)
    {
        return null;
    }

    // Exactly one trailing separator (POSIX '/').
    return try std.fmt.allocPrint(allocator, "{s}/", .{stripped});
}

/// Resolve the auto-memory directory. Single resolver for the whole subsystem.
/// Resolution order (ports the override branch of paths.ts getAutoMemPath):
///   1. ZCODE_MEMORY_PATH_OVERRIDE / CLAUDE_COWORK_MEMORY_PATH_OVERRIDE env
///      (no tilde expansion - callers pass absolute paths).
///   2. cfg.auto_memory_directory (settings.json autoMemoryDirectory, with
///      ~/ expansion).
///   3. Default: memory.memoryDirPathPub (~/.zcode/memory).
///
/// The returned path is owned by the caller. The override branches return a
/// validated path WITH a trailing separator; the default leaf returns the
/// existing memory.zig shape (no trailing separator) so existing callers of
/// memoryDirPathPub keep working unchanged.
pub fn getAutoMemPath(allocator: std.mem.Allocator, cfg: *const config.Config) ![]u8 {
    // 1. Env override (no tilde expansion).
    const override_raw = env.getenv("ZCODE_MEMORY_PATH_OVERRIDE") orelse
        env.getenv("CLAUDE_COWORK_MEMORY_PATH_OVERRIDE");
    if (override_raw) |raw| {
        if (try validateMemoryPath(allocator, raw, false)) |p| return p;
    }

    // 2. Settings directory (tilde expansion).
    if (cfg.auto_memory_directory.len > 0) {
        if (try validateMemoryPath(allocator, cfg.auto_memory_directory, true)) |p| return p;
    }

    // 3. Default leaf.
    return memory.memoryDirPathPub(allocator);
}

/// Whether abs_path is within the resolved auto-memory directory. Ports
/// paths.ts isAutoMemPath (:274-278): normalize both sides, then startsWith.
/// Used by the tool-restriction filters (Task 2 / Task 5) as the write
/// carve-out boundary.
pub fn isAutoMemPath(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    abs_path: []const u8,
) !bool {
    const base = try getAutoMemPath(allocator, cfg);
    defer allocator.free(base);
    const norm_base = try normalizePath(allocator, base);
    defer allocator.free(norm_base);
    const norm_path = try normalizePath(allocator, abs_path);
    defer allocator.free(norm_path);

    // The base may carry a trailing separator from getAutoMemPath's override
    // branches; the default leaf does not. Compare on the separator-stripped
    // base so both shapes behave identically, then require either an exact
    // match or a child path (base + '/').
    const base_trim = std.mem.trimEnd(u8, norm_base, "/\\");
    if (std.mem.eql(u8, norm_path, base_trim)) return true;
    if (norm_path.len > base_trim.len and
        std.mem.startsWith(u8, norm_path, base_trim) and
        (norm_path[base_trim.len] == '/' or norm_path[base_trim.len] == '\\'))
    {
        return true;
    }
    return false;
}

// --- internal helpers ---

fn envTruthyEither(primary: []const u8, alias: []const u8) bool {
    return env.isEnvTruthy(primary) or env.isEnvTruthy(alias);
}

fn envDefinedFalsyEither(primary: []const u8, alias: []const u8) bool {
    return env.isEnvDefinedFalsy(primary) or env.isEnvDefinedFalsy(alias);
}

fn isWindowsDriveRoot(s: []const u8) bool {
    // /^[A-Za-z]:$/
    return s.len == 2 and std.ascii.isAlphabetic(s[0]) and s[1] == ':';
}

/// Minimal path normalization matching node's normalize() for the cases this
/// module needs: collapse "." and ".." segments and redundant separators,
/// preserving an absolute-vs-relative leading state. Returns an owned slice.
/// This is intentionally small - it is only used for the security checks and
/// for the ~/ remainder test, not as a general-purpose canonicalizer.
fn normalizePath(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const is_abs = input.len > 0 and (input[0] == '/' or input[0] == '\\');
    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(allocator);

    var it = std.mem.tokenizeAny(u8, input, "/\\");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (segments.items.len > 0 and !std.mem.eql(u8, segments.items[segments.items.len - 1], "..")) {
                _ = segments.pop();
            } else if (!is_abs) {
                try segments.append(allocator, "..");
            }
            // For an absolute path, ".." at root is dropped (cannot go above /).
            continue;
        }
        try segments.append(allocator, seg);
    }

    if (segments.items.len == 0) {
        // node: normalize('') -> '.', normalize('/') -> '/'.
        return allocator.dupe(u8, if (is_abs) "/" else ".");
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    if (is_abs) try out.append(allocator, '/');
    for (segments.items, 0..) |seg, i| {
        if (i > 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, seg);
    }
    return out.toOwnedSlice(allocator);
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn clearGateEnv() void {
    _ = unsetenv("ZCODE_DISABLE_AUTO_MEMORY");
    _ = unsetenv("CLAUDE_CODE_DISABLE_AUTO_MEMORY");
    _ = unsetenv("ZCODE_SIMPLE");
    _ = unsetenv("CLAUDE_CODE_SIMPLE");
    _ = unsetenv("ZCODE_MEMORY_PATH_OVERRIDE");
    _ = unsetenv("CLAUDE_COWORK_MEMORY_PATH_OVERRIDE");
}

test "isAutoMemoryEnabled honors the env disable flag over the setting" {
    clearGateEnv();
    defer clearGateEnv();

    var cfg = try config.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    // ZCODE_DISABLE_AUTO_MEMORY=1 => OFF.
    _ = setenv("ZCODE_DISABLE_AUTO_MEMORY", "1", 1);
    try testing.expect(!isAutoMemoryEnabled(&cfg));

    // =0 (defined-falsy) forces ON even when the setting says false.
    _ = setenv("ZCODE_DISABLE_AUTO_MEMORY", "0", 1);
    cfg.auto_memory_enabled = false;
    try testing.expect(isAutoMemoryEnabled(&cfg));

    // Env unset, setting false => OFF.
    _ = unsetenv("ZCODE_DISABLE_AUTO_MEMORY");
    cfg.auto_memory_enabled = false;
    try testing.expect(!isAutoMemoryEnabled(&cfg));

    // Everything unset => default ON.
    cfg.auto_memory_enabled = null;
    try testing.expect(isAutoMemoryEnabled(&cfg));
}

test "isAutoMemoryEnabled: --bare / SIMPLE disables" {
    clearGateEnv();
    defer clearGateEnv();

    var cfg = try config.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    _ = setenv("ZCODE_SIMPLE", "1", 1);
    try testing.expect(!isAutoMemoryEnabled(&cfg));

    // The claude alias works too.
    _ = unsetenv("ZCODE_SIMPLE");
    _ = setenv("CLAUDE_CODE_SIMPLE", "true", 1);
    try testing.expect(!isAutoMemoryEnabled(&cfg));
}

test "validateMemoryPath rejects dangerous paths and accepts a real one" {
    clearGateEnv();
    defer clearGateEnv();
    const a = testing.allocator;

    // Rejections -> null.
    try testing.expect((try validateMemoryPath(a, "../foo", false)) == null);
    try testing.expect((try validateMemoryPath(a, "/", false)) == null);
    try testing.expect((try validateMemoryPath(a, "/a", false)) == null);
    try testing.expect((try validateMemoryPath(a, "C:", false)) == null);
    try testing.expect((try validateMemoryPath(a, "\\\\srv\\s", false)) == null);
    try testing.expect((try validateMemoryPath(a, "/ok/\x00bad", false)) == null);
    try testing.expect((try validateMemoryPath(a, null, false)) == null);
    try testing.expect((try validateMemoryPath(a, "", false)) == null);

    // Acceptance -> normalized with one trailing '/'.
    const ok = (try validateMemoryPath(a, "/Users/x/.zcode/memory", false)).?;
    defer a.free(ok);
    try testing.expectEqualStrings("/Users/x/.zcode/memory/", ok);
}

test "validateMemoryPath rejects bare-tilde remainders, accepts a real tilde path" {
    clearGateEnv();
    defer clearGateEnv();
    const a = testing.allocator;

    // Save/restore HOME so other tests (keychain, workspace_dirs) that resolve
    // paths under $HOME are not poisoned by this test's override. getenv
    // borrows libc static storage, so dupe before mutating.
    const saved_home: ?[]u8 = if (env.getenv("HOME")) |h| try a.dupe(u8, h) else null;
    defer {
        if (saved_home) |h| {
            const h_z = a.dupeZ(u8, h) catch unreachable;
            defer a.free(h_z);
            _ = setenv("HOME", h_z.ptr, 1);
            a.free(h);
        } else {
            _ = unsetenv("HOME");
        }
    }

    _ = setenv("HOME", "/home/tester", 1);

    // Bare/ancestor remainders rejected.
    try testing.expect((try validateMemoryPath(a, "~/", true)) == null);
    try testing.expect((try validateMemoryPath(a, "~/.", true)) == null);
    try testing.expect((try validateMemoryPath(a, "~/..", true)) == null);

    // A real subdir under $HOME expands and is accepted.
    const ok = (try validateMemoryPath(a, "~/.zcode/memory", true)).?;
    defer a.free(ok);
    try testing.expectEqualStrings("/home/tester/.zcode/memory/", ok);
}

test "getAutoMemPath honors env override else falls back to default" {
    clearGateEnv();
    defer clearGateEnv();
    const a = testing.allocator;

    var cfg = try config.Config.init(a);
    defer cfg.deinit(a);

    // Override wins.
    _ = setenv("ZCODE_MEMORY_PATH_OVERRIDE", "/srv/mem/dir", 1);
    const ov = try getAutoMemPath(a, &cfg);
    defer a.free(ov);
    try testing.expectEqualStrings("/srv/mem/dir/", ov);

    // Unset override -> default ~/.zcode/memory leaf (no trailing sep, the
    // memory.zig shape). Just assert it ends with the default segment.
    _ = unsetenv("ZCODE_MEMORY_PATH_OVERRIDE");
    const def = try getAutoMemPath(a, &cfg);
    defer a.free(def);
    try testing.expect(std.mem.endsWith(u8, def, "memory"));
}

test "isAutoMemPath matches the resolved dir and rejects outside paths" {
    clearGateEnv();
    defer clearGateEnv();
    const a = testing.allocator;

    var cfg = try config.Config.init(a);
    defer cfg.deinit(a);

    _ = setenv("ZCODE_MEMORY_PATH_OVERRIDE", "/srv/mem", 1);

    try testing.expect(try isAutoMemPath(a, &cfg, "/srv/mem/foo.md"));
    try testing.expect(try isAutoMemPath(a, &cfg, "/srv/mem")); // exact dir
    // Traversal-bypass attempt normalizes back inside.
    try testing.expect(try isAutoMemPath(a, &cfg, "/srv/mem/sub/../foo.md"));
    // A sibling that merely shares the prefix as a substring is NOT a child.
    try testing.expect(!try isAutoMemPath(a, &cfg, "/srv/membrane/x.md"));
    try testing.expect(!try isAutoMemPath(a, &cfg, "/etc/passwd"));
    // Traversal that escapes is rejected.
    try testing.expect(!try isAutoMemPath(a, &cfg, "/srv/mem/../other/x.md"));
}

test "normalizePath collapses dot and dotdot segments" {
    const a = testing.allocator;
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "/a/b/../c", .out = "/a/c" },
        .{ .in = "/a/./b", .out = "/a/b" },
        .{ .in = "/a//b", .out = "/a/b" },
        .{ .in = "/..", .out = "/" },
        .{ .in = "", .out = "." },
        .{ .in = "foo/..", .out = "." },
        .{ .in = "..", .out = ".." },
    };
    for (cases) |c| {
        const got = try normalizePath(a, c.in);
        defer a.free(got);
        try testing.expectEqualStrings(c.out, got);
    }
}
