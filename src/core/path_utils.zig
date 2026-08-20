const std = @import("std");
const builtin = @import("builtin");

/// General-purpose path manipulation helpers. Ported from
/// claude-code-main/src/utils/path.ts (expandPath, toRelativePath,
/// containsPathTraversal) plus a zcode-native null-byte guard.
/// Kept separate from src/core/paths.zig which is specifically
/// about the ~/.zcode/ tree layout; this module is about ANY
/// path the caller might hand us.
/// True when `path` contains a NUL byte. The POSIX syscalls treat
/// NUL as the end-of-string terminator, so a caller that forgets
/// this check can create `/tmp/foo\0.txt` and later see `/tmp/foo`
/// written instead -- a classic path-smuggling footgun.
pub fn hasNullByte(path: []const u8) bool {
    return std.mem.indexOfScalar(u8, path, 0) != null;
}

/// True when `path` contains a `..` directory-traversal segment.
/// Matches claude-code-main/src/utils/path.ts containsPathTraversal
/// pattern `/(?:^|[\\/])\.\.(?:[\\/]|$)/` -- the `..` must appear as
/// its own path component, so `foo..bar` and `..hidden` stay
/// allowed. Accepts BOTH forward- and back-slashes as separators
/// so Windows paths are covered without a second pass.
pub fn containsPathTraversal(path: []const u8) bool {
    var it = std.mem.splitAny(u8, path, "/\\");
    while (it.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return true;
    }
    return false;
}

/// True when the basename of `path` starts with a dot (".env",
/// ".git", ".hidden"). Mirrors the POSIX convention the reference
/// uses throughout its file-picker and list renderers.
pub fn isHiddenFile(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    return base.len > 0 and base[0] == '.' and !std.mem.eql(u8, base, ".") and !std.mem.eql(u8, base, "..");
}

/// Expand a possibly-tilde-prefixed path into an absolute path.
/// Returns an owned slice; caller must free.
///
/// Behaviour (ported from utils/path.ts expandPath):
///   - `~`         -> $HOME
///   - `~/foo`     -> $HOME/foo
///   - `/abs/foo`  -> `/abs/foo` (unchanged, normalised)
///   - `rel/foo`   -> base_dir + "/" + "rel/foo"
///
/// Null bytes anywhere in `path` or `base_dir` trigger
/// `error.PathContainsNullByte`. Whitespace-only input returns a
/// dupe of `base_dir` (also matches reference).
///
/// On Linux / macOS the normalisation is a simple path.join; the
/// reference also handles Windows POSIX-style `/c/Users/...`
/// conversion which zcode doesn't support yet because zcode
/// mostly targets POSIX workflows. Windows users still get the
/// tilde + absolute + relative branches to work correctly.
pub fn expandPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    base_dir: []const u8,
) ![]u8 {
    if (hasNullByte(path) or hasNullByte(base_dir)) return error.PathContainsNullByte;

    const trimmed = std.mem.trim(u8, path, " \t\r\n");
    if (trimmed.len == 0) {
        return allocator.dupe(u8, base_dir);
    }

    // Tilde expansion.
    if (std.mem.eql(u8, trimmed, "~")) {
        return getHomeDir(allocator);
    }
    if (std.mem.startsWith(u8, trimmed, "~/")) {
        const home = try getHomeDir(allocator);
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, trimmed[2..] });
    }

    // Absolute path: return a dupe (callers expect an owned slice).
    if (std.fs.path.isAbsolute(trimmed)) {
        return allocator.dupe(u8, trimmed);
    }

    // Relative path: anchor to base_dir.
    return std.fs.path.join(allocator, &.{ base_dir, trimmed });
}

/// Convert an absolute path to a cwd-relative one, falling back
/// to the original when the path sits outside cwd. Mirrors
/// utils/path.ts toRelativePath: "If the relative path would go
/// outside cwd (starts with ..), keep absolute." Caller owns the
/// returned slice.
///
/// The guard against `..` prefixes matters for tool-result
/// display: if the model Reads `/usr/include/stdio.h` while the
/// user's cwd is `/home/user/project`, we don't want to show
/// `../../../usr/include/stdio.h` (which is ugly AND longer than
/// the absolute form). Only pay the shortening cost when the
/// absolute path is genuinely under cwd.
pub fn toRelativePath(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    absolute_path: []const u8,
) ![]u8 {
    if (hasNullByte(cwd) or hasNullByte(absolute_path)) return error.PathContainsNullByte;

    // A relative input is already relative -- preserve it as a
    // stable invariant rather than double-anchoring.
    if (!std.fs.path.isAbsolute(absolute_path)) {
        return allocator.dupe(u8, absolute_path);
    }

    const rel = std.fs.path.relative(allocator, cwd, null, cwd, absolute_path) catch {
        return allocator.dupe(u8, absolute_path);
    };
    // If the computed relative path escapes cwd via `..`, keep
    // the absolute form -- it's shorter and unambiguous.
    if (std.mem.startsWith(u8, rel, "..")) {
        allocator.free(rel);
        return allocator.dupe(u8, absolute_path);
    }
    // Empty rel means the path IS cwd; render as "." so the
    // display is explicit rather than a blank.
    if (rel.len == 0) {
        allocator.free(rel);
        return allocator.dupe(u8, ".");
    }
    return rel;
}

/// True when, AFTER `~`/`~/` expansion, the path still starts with a
/// tilde -- i.e. an unexpanded variant like `~user`, `~+`, `~-`, `~N`.
/// The shell expands these differently (`~root` -> /var/root, `~+` ->
/// $PWD, `~-` -> $OLDPWD), so a validator that resolved them as
/// relative paths (`/cwd/~root/...`) while the shell reads
/// `/var/root/...` opens a TOCTOU gap. Ported from
/// pathValidation.ts:394-411. IMPORTANT: call this on the
/// POST-expansion string -- `expandPath`/`expandHomeTilde` already turn
/// bare `~` and `~/foo` into absolute paths, so only the unhandled
/// variants reach here; passing a raw `~/foo` would false-positive.
pub fn hasTildeVariant(path: []const u8) bool {
    return path.len > 0 and path[0] == '~';
}

/// True when the path contains shell-expansion syntax that the shell
/// would expand at exec time but a validator treats as literal text,
/// creating a TOCTOU gap. Ported from pathValidation.ts:413-436:
///   - `$VAR` / `${VAR}` / `$(cmd)` (Unix env + command substitution)
///   - `%VAR%` (Windows env vars like %TEMP%, %USERPROFILE%)
///   - a leading `=` (Zsh equals expansion, e.g. `=rg` -> /usr/bin/rg)
pub fn hasShellExpansion(path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, path, '$') != null) return true;
    if (std.mem.indexOfScalar(u8, path, '%') != null) return true;
    if (path.len > 0 and path[0] == '=') return true;
    return false;
}

/// True when the path looks like a UNC network path: a leading `\\`
/// or `//`. UNC paths can leak credentials to a remote host, so
/// write/create operations against them require manual approval.
/// Mirrors the leading-separator portion of the reference's
/// containsVulnerableUncPath (readOnlyCommandValidation.ts:1562).
/// We keep this all-platform (the reference scopes it to Windows) so a
/// UNC-shaped path cannot slip through on a non-Windows host that has
/// an SMB mount; this matches zcode's pattern-detection posture in
/// path_safety.zig.
pub fn isUncPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "\\\\") or std.mem.startsWith(u8, path, "//");
}

/// True when the path contains glob metacharacters (`*`, `?`, `[`,
/// `]`, `{`, `}`). Write/create tools use paths literally and do NOT
/// expand globs, so a glob in a write path would only validate the
/// base dir while the literal `*` lands on disk. Reject globs for
/// write/create ONLY -- read tools (Glob/Grep) legitimately glob.
/// Mirrors GLOB_PATTERN_REGEX `[*?[\]{}]` (pathValidation.ts:25).
pub fn hasGlobMeta(path: []const u8) bool {
    for (path) |c| {
        switch (c) {
            '*', '?', '[', ']', '{', '}' => return true,
            else => {},
        }
    }
    return false;
}

/// Pure form of the dangerous-removal-path guard. `home` is the
/// resolved home directory (the IO-bearing wrapper resolves it). True
/// when removing this path is dangerous:
///   - bare `*` or any path ending `/*` (removes a whole directory)
///   - the root `/` (with or without a trailing slash)
///   - a Windows drive root (`C:`, `C:/`) or drive child (`C:/Windows`)
///   - the home directory itself
///   - a direct child of root (`/usr`, `/etc`, `/tmp`)
/// Ported from isDangerousRemovalPath (pathValidation.ts:331-367).
/// Backslash and forward-slash runs are collapsed to a single `/` so a
/// `C:\\Windows` form cannot dodge the drive-child check.
pub fn isDangerousRemovalPathPure(path: []const u8, home: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const forward = collapseSlashes(path, &buf) orelse return false;

    if (std.mem.eql(u8, forward, "*") or std.mem.endsWith(u8, forward, "/*")) {
        return true;
    }

    // Strip a single trailing slash (but keep a bare "/").
    const normalized = if (std.mem.eql(u8, forward, "/"))
        forward
    else if (forward.len > 1 and forward[forward.len - 1] == '/')
        forward[0 .. forward.len - 1]
    else
        forward;

    if (std.mem.eql(u8, normalized, "/")) return true;

    if (isWindowsDriveRoot(normalized)) return true;

    if (home.len > 0) {
        var home_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (collapseSlashes(home, &home_buf)) |home_forward| {
            const home_norm = if (home_forward.len > 1 and home_forward[home_forward.len - 1] == '/')
                home_forward[0 .. home_forward.len - 1]
            else
                home_forward;
            if (std.mem.eql(u8, normalized, home_norm)) return true;
        }
    }

    // Direct child of root: parent dir is exactly "/".
    if (std.fs.path.dirnamePosix(normalized)) |parent| {
        if (std.mem.eql(u8, parent, "/")) return true;
    }

    if (isWindowsDriveChild(normalized)) return true;

    return false;
}

/// Collapse runs of `\\` and `/` into a single `/`, writing into `buf`.
/// Returns the slice on success, or null when the input does not fit.
fn collapseSlashes(path: []const u8, buf: []u8) ?[]const u8 {
    if (path.len > buf.len) return null;
    var n: usize = 0;
    var prev_sep = false;
    for (path) |c| {
        const is_sep = c == '/' or c == '\\';
        if (is_sep) {
            if (prev_sep) continue;
            buf[n] = '/';
            n += 1;
            prev_sep = true;
        } else {
            buf[n] = c;
            n += 1;
            prev_sep = false;
        }
    }
    return buf[0..n];
}

/// Matches a bare Windows drive root: `C:` or `C:/`. Mirrors
/// WINDOWS_DRIVE_ROOT_REGEX `^[A-Za-z]:\/?$` (against slash-collapsed
/// input).
fn isWindowsDriveRoot(path: []const u8) bool {
    if (path.len == 2) {
        return std.ascii.isAlphabetic(path[0]) and path[1] == ':';
    }
    if (path.len == 3) {
        return std.ascii.isAlphabetic(path[0]) and path[1] == ':' and path[2] == '/';
    }
    return false;
}

/// Matches a direct child of a Windows drive root: `C:/Windows`,
/// `D:/Users` (one segment after the drive, no further slash). Mirrors
/// WINDOWS_DRIVE_CHILD_REGEX `^[A-Za-z]:\/[^/]+$` (slash-collapsed).
fn isWindowsDriveChild(path: []const u8) bool {
    if (path.len < 4) return false;
    if (!std.ascii.isAlphabetic(path[0]) or path[1] != ':' or path[2] != '/') return false;
    // Remainder after `X:/` must be non-empty and contain no further '/'.
    const rest = path[3..];
    if (rest.len == 0) return false;
    return std.mem.indexOfScalar(u8, rest, '/') == null;
}

pub fn getHomeDir(allocator: std.mem.Allocator) ![]u8 {
    // On POSIX, HOME is the canonical source.
    if (builtin.os.tag != .windows) {
        return @import("env.zig").getOwned(allocator, "HOME") catch |err| switch (err) {
            error.EnvironmentVariableMissing => error.HomeDirNotSet,
            else => err,
        };
    }
    // On Windows, USERPROFILE (or HOMEDRIVE + HOMEPATH) is the
    // right source. Try USERPROFILE first because it's a single
    // env var that already contains the full path.
    if (@import("env.zig").getOwned(allocator, "USERPROFILE")) |p| {
        return p;
    } else |_| {}
    const drive = @import("env.zig").getOwned(allocator, "HOMEDRIVE") catch return error.HomeDirNotSet;
    defer allocator.free(drive);
    const path = @import("env.zig").getOwned(allocator, "HOMEPATH") catch return error.HomeDirNotSet;
    defer allocator.free(path);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ drive, path });
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "hasNullByte flags embedded NUL" {
    try testing.expect(hasNullByte("/tmp/foo\x00.txt"));
    try testing.expect(!hasNullByte("/tmp/foo.txt"));
    try testing.expect(!hasNullByte(""));
}

test "containsPathTraversal catches .. segments" {
    try testing.expect(containsPathTraversal("../foo"));
    try testing.expect(containsPathTraversal("foo/../bar"));
    try testing.expect(containsPathTraversal("foo/.."));
    try testing.expect(containsPathTraversal(".."));
    try testing.expect(containsPathTraversal("a\\..\\b"));
}

test "containsPathTraversal allows dot-prefixed filenames" {
    // `..hidden` has two leading dots but is NOT a traversal.
    try testing.expect(!containsPathTraversal("..hidden"));
    try testing.expect(!containsPathTraversal("foo..bar"));
    try testing.expect(!containsPathTraversal("foo.bar"));
    try testing.expect(!containsPathTraversal("."));
    try testing.expect(!containsPathTraversal(".env"));
    try testing.expect(!containsPathTraversal("/usr/local/bin/foo"));
}

test "isHiddenFile recognises dotfiles" {
    try testing.expect(isHiddenFile(".env"));
    try testing.expect(isHiddenFile(".git"));
    try testing.expect(isHiddenFile("/home/user/.bashrc"));
    try testing.expect(!isHiddenFile("env.sample"));
    try testing.expect(!isHiddenFile("/tmp/README.md"));
    try testing.expect(!isHiddenFile("."));
    try testing.expect(!isHiddenFile(".."));
}

test "expandPath rejects null bytes" {
    const alloc = testing.allocator;
    try testing.expectError(error.PathContainsNullByte, expandPath(alloc, "/tmp/foo\x00.txt", "/cwd"));
    try testing.expectError(error.PathContainsNullByte, expandPath(alloc, "foo.txt", "/cwd\x00"));
}

test "expandPath returns base_dir on whitespace-only input" {
    const alloc = testing.allocator;
    const out = try expandPath(alloc, "   ", "/base");
    defer alloc.free(out);
    try testing.expectEqualStrings("/base", out);
}

test "expandPath duplicates absolute paths" {
    const alloc = testing.allocator;
    const out = try expandPath(alloc, "/absolute/path", "/ignored");
    defer alloc.free(out);
    try testing.expectEqualStrings("/absolute/path", out);
}

test "expandPath joins relative paths with base_dir" {
    const alloc = testing.allocator;
    const out = try expandPath(alloc, "subdir/file.txt", "/base");
    defer alloc.free(out);
    try testing.expectEqualStrings("/base/subdir/file.txt", out);
}

test "expandPath resolves bare ~ to HOME" {
    if (builtin.os.tag == .windows) return;
    const alloc = testing.allocator;
    const home = @import("env.zig").getOwned(alloc, "HOME") catch return;
    defer alloc.free(home);
    const out = try expandPath(alloc, "~", "/ignored");
    defer alloc.free(out);
    try testing.expectEqualStrings(home, out);
}

test "expandPath resolves ~/rel to HOME/rel" {
    if (builtin.os.tag == .windows) return;
    const alloc = testing.allocator;
    const home = @import("env.zig").getOwned(alloc, "HOME") catch return;
    defer alloc.free(home);
    const expected = try std.fs.path.join(alloc, &.{ home, "Documents" });
    defer alloc.free(expected);
    const out = try expandPath(alloc, "~/Documents", "/ignored");
    defer alloc.free(out);
    try testing.expectEqualStrings(expected, out);
}

test "expandPath trims surrounding whitespace" {
    const alloc = testing.allocator;
    const out = try expandPath(alloc, "  rel/path  ", "/base");
    defer alloc.free(out);
    try testing.expectEqualStrings("/base/rel/path", out);
}

test "toRelativePath strips cwd prefix" {
    const alloc = testing.allocator;
    const out = try toRelativePath(alloc, "/home/user/project", "/home/user/project/src/main.zig");
    defer alloc.free(out);
    try testing.expectEqualStrings("src/main.zig", out);
}

test "toRelativePath returns absolute form when path escapes cwd" {
    const alloc = testing.allocator;
    const out = try toRelativePath(alloc, "/home/user/project", "/usr/include/stdio.h");
    defer alloc.free(out);
    try testing.expectEqualStrings("/usr/include/stdio.h", out);
}

test "toRelativePath returns '.' when path IS cwd" {
    const alloc = testing.allocator;
    const out = try toRelativePath(alloc, "/home/user/project", "/home/user/project");
    defer alloc.free(out);
    try testing.expectEqualStrings(".", out);
}

test "toRelativePath passes through already-relative input" {
    const alloc = testing.allocator;
    const out = try toRelativePath(alloc, "/home/user/project", "src/main.zig");
    defer alloc.free(out);
    try testing.expectEqualStrings("src/main.zig", out);
}

test "toRelativePath rejects null bytes in either argument" {
    const alloc = testing.allocator;
    try testing.expectError(error.PathContainsNullByte, toRelativePath(alloc, "/cwd\x00", "/cwd/foo"));
    try testing.expectError(error.PathContainsNullByte, toRelativePath(alloc, "/cwd", "/cwd/foo\x00"));
}

test "hasTildeVariant flags unexpanded tilde variants" {
    try testing.expect(hasTildeVariant("~root/.ssh/id_rsa"));
    try testing.expect(hasTildeVariant("~+/x"));
    try testing.expect(hasTildeVariant("~-/x"));
    try testing.expect(hasTildeVariant("~1/x"));
    // A bare "~/x" only reaches this check if NOT expanded; document
    // that callers must expand first. The helper itself reports true
    // on any leading tilde, so the post-expansion contract is what
    // makes this safe -- after expansion "~/x" becomes "$HOME/x".
    try testing.expect(hasTildeVariant("~/x"));
    try testing.expect(!hasTildeVariant("/home/u/x"));
    try testing.expect(!hasTildeVariant("rel/path"));
    try testing.expect(!hasTildeVariant(""));
}

test "hasShellExpansion flags $/%/leading-= syntax" {
    try testing.expect(hasShellExpansion("$HOME/x"));
    try testing.expect(hasShellExpansion("${VAR}/x"));
    try testing.expect(hasShellExpansion("$(cmd)"));
    try testing.expect(hasShellExpansion("%TEMP%\\x"));
    try testing.expect(hasShellExpansion("=rg"));
    try testing.expect(!hasShellExpansion("/plain/path"));
    try testing.expect(!hasShellExpansion("rel/file=value")); // '=' not leading
}

test "isUncPath flags leading double-separator" {
    try testing.expect(isUncPath("\\\\server\\share"));
    try testing.expect(isUncPath("//server/share"));
    try testing.expect(!isUncPath("/server/share"));
    try testing.expect(!isUncPath("C:/Windows"));
    try testing.expect(!isUncPath(""));
}

test "hasGlobMeta flags glob metacharacters" {
    try testing.expect(hasGlobMeta("/dir/*.txt"));
    try testing.expect(hasGlobMeta("/dir/file?.txt"));
    try testing.expect(hasGlobMeta("/dir/[abc].txt"));
    try testing.expect(hasGlobMeta("/dir/{a,b}.txt"));
    try testing.expect(!hasGlobMeta("/dir/file.txt"));
    try testing.expect(!hasGlobMeta(""));
}

test "isDangerousRemovalPathPure flags dangerous targets" {
    const home = "/home/user";
    try testing.expect(isDangerousRemovalPathPure("*", home));
    try testing.expect(isDangerousRemovalPathPure("/dir/*", home));
    try testing.expect(isDangerousRemovalPathPure("/", home));
    try testing.expect(isDangerousRemovalPathPure("/usr", home));
    try testing.expect(isDangerousRemovalPathPure("/etc", home));
    try testing.expect(isDangerousRemovalPathPure("/tmp/", home)); // trailing slash stripped
    try testing.expect(isDangerousRemovalPathPure(home, home));
    try testing.expect(isDangerousRemovalPathPure("/home/user/", home)); // home with trailing slash
    // Windows drive root and child.
    try testing.expect(isDangerousRemovalPathPure("C:", home));
    try testing.expect(isDangerousRemovalPathPure("C:\\", home));
    try testing.expect(isDangerousRemovalPathPure("C:\\Windows", home));
}

test "isDangerousRemovalPathPure allows safe nested targets" {
    const home = "/home/user";
    try testing.expect(!isDangerousRemovalPathPure("/repo/build", home));
    try testing.expect(!isDangerousRemovalPathPure("/usr/local/bin", home));
    try testing.expect(!isDangerousRemovalPathPure("/home/user/project", home));
    try testing.expect(!isDangerousRemovalPathPure("relative/dir", home));
}
