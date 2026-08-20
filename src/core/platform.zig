const std = @import("std");
const rt = @import("zcode_runtime");
const builtin = @import("builtin");

/// Platform detection ported from claude-code-main/src/utils/platform.ts.
///
/// Distinguishes WSL from regular Linux by reading /proc/version,
/// which is the only reliable signal -- `uname -r` returns "5.10.16
/// .3-microsoft-standard-WSL2" on WSL2 but `os.release()` in Zig
/// returns the same kernel string without parsing. Reading the proc
/// file lets us look for "microsoft" or "WSL" tokens, matching the
/// reference implementation.
pub const Platform = enum {
    macos,
    windows,
    wsl,
    linux,
    unknown,

    /// Stable string id used in /env output and telemetry. Matches
    /// the reference's lowercase tag values exactly so dashboards
    /// reading from both tools see the same names.
    pub fn toString(self: Platform) []const u8 {
        return switch (self) {
            .macos => "macos",
            .windows => "windows",
            .wsl => "wsl",
            .linux => "linux",
            .unknown => "unknown",
        };
    }
};

/// Memoized so /env, /doctor, the clipboard helper, and any future
/// caller all pay the /proc/version read at most once per process.
var cached_platform: ?Platform = null;
var cache_mutex: std.Io.Mutex = .init;

pub fn detect() Platform {
    if (cached_platform) |p| return p;
    cache_mutex.lock(rt.io) catch {};
    defer cache_mutex.unlock(rt.io);
    if (cached_platform) |p| return p;
    const result = computePlatform();
    cached_platform = result;
    return result;
}

/// Drop the memoized value. Intended for tests that want to exercise
/// the WSL detection path without relying on the host's actual
/// /proc/version.
pub fn resetCacheForTesting() void {
    cache_mutex.lock(rt.io) catch {};
    defer cache_mutex.unlock(rt.io);
    cached_platform = null;
}

fn computePlatform() Platform {
    return switch (builtin.os.tag) {
        .macos => .macos,
        .windows => .windows,
        .linux => detectLinuxOrWsl(),
        else => .unknown,
    };
}

fn detectLinuxOrWsl() Platform {
    // /proc/version on a stock kernel looks like:
    //   "Linux version 6.1.0-rpi8-rpi-v8 (debian-kernel@lists.debian.org) (gcc-...) ..."
    // On WSL2 it looks like:
    //   "Linux version 5.15.146.1-microsoft-standard-WSL2 (oe-user@oe-host) (...)"
    // and on WSL1:
    //   "Linux version 4.4.0-19041-Microsoft (Microsoft@Microsoft.com) (...)"
    // So a case-insensitive substring match for "microsoft" or "wsl"
    // is sufficient.
    const file = std.Io.Dir.openFileAbsolute(rt.io, "/proc/version", .{}) catch return .linux;
    defer file.close(rt.io);

    var buf: [4096]u8 = undefined;
    const n = file.readPositionalAll(rt.io, &buf, 0) catch return .linux;
    return classifyProcVersion(buf[0..n]);
}

/// Pure helper exposed for tests so we can feed in synthetic
/// /proc/version contents without a host-specific kernel.
pub fn classifyProcVersion(content: []const u8) Platform {
    if (containsCaseInsensitive(content, "microsoft")) return .wsl;
    if (containsCaseInsensitive(content, "wsl")) return .wsl;
    return .linux;
}

fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matched = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

/// Returns the platform-appropriate clipboard command. macOS uses
/// pbcopy, Windows/WSL use clip.exe (which is available on WSL via
/// interop with the host Win32 binary), Linux falls back to xclip.
/// Returning a fixed string lets callers `std.process.Child.init` it
/// without juggling allocations.
pub fn clipboardCommand() []const u8 {
    return switch (detect()) {
        .macos => "pbcopy",
        .windows, .wsl => "clip.exe",
        .linux => "xclip -selection clipboard",
        .unknown => "xclip -selection clipboard",
    };
}

/// Render an OS version string in the same shape as Claude Code's
/// getUnameSR (constants/prompts.ts:745): `<sysname> <release>` on
/// POSIX, e.g. "Darwin 25.3.0" or "Linux 6.6.4". Writes into the
/// caller-provided buffer so we don't allocate in the hot system-
/// prompt build path. The buffer should be at least 192 bytes to
/// hold the longest plausible utsname field combination.
pub fn writeOsVersion(buf: []u8) []const u8 {
    if (builtin.os.tag == .windows) {
        return std.fmt.bufPrint(buf, "Windows", .{}) catch "Windows";
    }
    const uts = std.posix.uname();
    const sysname = sliceCStr(&uts.sysname);
    const release = sliceCStr(&uts.release);
    return std.fmt.bufPrint(buf, "{s} {s}", .{ sysname, release }) catch sysname;
}

fn sliceCStr(field: anytype) []const u8 {
    const ptr: [*]const u8 = @ptrCast(field);
    var len: usize = 0;
    while (len < field.len and ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}

/// Return the basename of the user's $SHELL or "unknown" if it isn't
/// set. Used to give the model a hint about which shell syntax the
/// user expects (zsh vs bash vs fish), matching Claude Code's
/// getShellSection in constants/prompts.ts:735.
pub fn shellBasename() []const u8 {
    const shell = @import("env.zig").getenv("SHELL") orelse return "unknown";
    if (std.mem.lastIndexOfScalar(u8, shell, '/')) |idx| {
        return shell[idx + 1 ..];
    }
    return shell;
}

/// Version control systems `detectVcs` knows about, ordered to
/// match claude-code-main/src/utils/platform.ts VCS_MARKERS.
pub const Vcs = enum {
    git,
    mercurial,
    svn,
    perforce,
    tfs,
    jujutsu,
    sapling,

    pub fn toString(self: Vcs) []const u8 {
        return switch (self) {
            .git => "git",
            .mercurial => "mercurial",
            .svn => "svn",
            .perforce => "perforce",
            .tfs => "tfs",
            .jujutsu => "jujutsu",
            .sapling => "sapling",
        };
    }
};

/// Detect the version-control system(s) in use for `dir` by checking
/// for well-known marker files. Ports
/// claude-code-main/src/utils/platform.ts `detectVcs`. The model gets
/// very wrong commands when it assumes git on a repo that's actually
/// using jj or sapling ("jj st" vs "git status"), so surfacing this
/// in the system prompt lets it pick the right tool up front.
///
/// Returns a caller-owned slice of detected VCS values, possibly
/// empty when no markers are found. Multiple can be returned when a
/// repo uses more than one (e.g. jj wrapping git, or a svn-hg bridge).
///
/// Check order matches the reference:
///   .git         -> git
///   .hg          -> mercurial
///   .svn         -> svn
///   .p4config    -> perforce (also triggered by $P4PORT env var)
///   $tf / .tfvc  -> tfs
///   .jj          -> jujutsu
///   .sl          -> sapling
pub fn detectVcs(allocator: std.mem.Allocator, dir: []const u8) ![]Vcs {
    var detected = std.array_list.Managed(Vcs).init(allocator);
    errdefer detected.deinit();

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    // Perforce has no marker file in cwd by convention; the daemon
    // is configured via $P4PORT. Check that first so a cwd inside
    // a Perforce client with an unusual marker layout still detects.
    if (@import("env.zig").getenv("P4PORT")) |_| {
        try detected.append(.perforce);
        try seen.put(Vcs.perforce.toString(), {});
    }

    const markers = [_]struct { name: []const u8, vcs: Vcs }{
        .{ .name = ".git", .vcs = .git },
        .{ .name = ".hg", .vcs = .mercurial },
        .{ .name = ".svn", .vcs = .svn },
        .{ .name = ".p4config", .vcs = .perforce },
        .{ .name = "$tf", .vcs = .tfs },
        .{ .name = ".tfvc", .vcs = .tfs },
        .{ .name = ".jj", .vcs = .jujutsu },
        .{ .name = ".sl", .vcs = .sapling },
    };

    var dir_handle = std.Io.Dir.cwd().openDir(rt.io, dir, .{ .iterate = true }) catch {
        // Directory not readable -- return whatever env-var detection
        // already found (typically empty). Matches the reference's
        // "catch {}" fallback which doesn't throw.
        return detected.toOwnedSlice();
    };
    defer dir_handle.close(rt.io);

    var it = dir_handle.iterate();
    while (it.next(rt.io) catch null) |entry| {
        for (markers) |marker| {
            if (std.mem.eql(u8, entry.name, marker.name)) {
                const key = marker.vcs.toString();
                if (seen.contains(key)) continue;
                try seen.put(key, {});
                try detected.append(marker.vcs);
            }
        }
    }

    return detected.toOwnedSlice();
}

const testing = std.testing;

test "classifyProcVersion detects WSL2 with -microsoft- in kernel" {
    const wsl2 = "Linux version 5.15.146.1-microsoft-standard-WSL2 (oe-user@oe-host) (...)";
    try testing.expectEqual(Platform.wsl, classifyProcVersion(wsl2));
}

test "classifyProcVersion detects WSL1 with Microsoft user" {
    const wsl1 = "Linux version 4.4.0-19041-Microsoft (Microsoft@Microsoft.com) (...)";
    try testing.expectEqual(Platform.wsl, classifyProcVersion(wsl1));
}

test "classifyProcVersion detects WSL token even without microsoft" {
    const wsl_only = "Linux version 5.10 (built for WSL)";
    try testing.expectEqual(Platform.wsl, classifyProcVersion(wsl_only));
}

test "classifyProcVersion treats stock Linux as linux" {
    const stock = "Linux version 6.1.0-rpi8-rpi-v8 (debian-kernel@lists.debian.org) (gcc 12.2.0)";
    try testing.expectEqual(Platform.linux, classifyProcVersion(stock));
}

test "classifyProcVersion is case-insensitive" {
    try testing.expectEqual(Platform.wsl, classifyProcVersion("Linux version 5.10 MICROSOFT"));
    try testing.expectEqual(Platform.wsl, classifyProcVersion("Linux version 5.10 Wsl"));
}

test "Platform.toString produces stable lowercase tags" {
    try testing.expectEqualStrings("macos", Platform.macos.toString());
    try testing.expectEqualStrings("windows", Platform.windows.toString());
    try testing.expectEqualStrings("wsl", Platform.wsl.toString());
    try testing.expectEqualStrings("linux", Platform.linux.toString());
    try testing.expectEqualStrings("unknown", Platform.unknown.toString());
}

test "detect returns a defined platform on the host" {
    // We don't assert which one (CI runs on linux, dev runs on macos)
    // -- just that the cached path resolves to one of the known
    // values without crashing.
    const got = detect();
    try testing.expect(got == .macos or got == .windows or got == .wsl or got == .linux or got == .unknown);
}

test "clipboardCommand returns a non-empty string for every platform" {
    // Validate the lookup table covers all enum variants. Running
    // the function exercises detect()'s memoized branch.
    const cmd = clipboardCommand();
    try testing.expect(cmd.len > 0);
}

test "writeOsVersion returns a non-empty string with sysname prefix" {
    var buf: [192]u8 = undefined;
    const got = writeOsVersion(&buf);
    try testing.expect(got.len > 0);
    // The sysname is always followed by a space (or, on Windows, the
    // string starts with "Windows"). Either way we expect at least
    // 3 bytes of recognisable content.
    if (builtin.os.tag != .windows) {
        try testing.expect(std.mem.indexOfScalar(u8, got, ' ') != null);
    }
}

test "shellBasename strips directory prefix" {
    // We don't depend on the test runner having a particular $SHELL,
    // just exercise the path. If $SHELL is unset the result is
    // "unknown"; if set it has no '/' character.
    const got = shellBasename();
    try testing.expect(std.mem.indexOfScalar(u8, got, '/') == null);
}

test "sliceCStr stops at first NUL" {
    var raw = [_]u8{ 'D', 'a', 'r', 'w', 'i', 'n', 0, 'X', 'X' };
    const got = sliceCStr(&raw);
    try testing.expectEqualStrings("Darwin", got);
}

test "Vcs.toString produces lowercase identifiers" {
    try testing.expectEqualStrings("git", Vcs.git.toString());
    try testing.expectEqualStrings("mercurial", Vcs.mercurial.toString());
    try testing.expectEqualStrings("svn", Vcs.svn.toString());
    try testing.expectEqualStrings("perforce", Vcs.perforce.toString());
    try testing.expectEqualStrings("tfs", Vcs.tfs.toString());
    try testing.expectEqualStrings("jujutsu", Vcs.jujutsu.toString());
    try testing.expectEqualStrings("sapling", Vcs.sapling.toString());
}

test "detectVcs finds a plain git repo" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".git");
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const got = try detectVcs(testing.allocator, cwd);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(Vcs.git, got[0]);
}

test "detectVcs finds a jujutsu repo (the motivating case)" {
    // Model gives `git status` on a jj repo by default; surfacing
    // jujutsu in the environment section lets it pick `jj st` instead.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".jj");
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const got = try detectVcs(testing.allocator, cwd);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(Vcs.jujutsu, got[0]);
}

test "detectVcs finds a sapling repo" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".sl");
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const got = try detectVcs(testing.allocator, cwd);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(Vcs.sapling, got[0]);
}

test "detectVcs handles multiple VCS markers in the same directory" {
    // A jj-wrapped git repo has both .git and .jj. Both should be
    // reported so the system prompt can flag the unusual setup.
    // Directory iteration order is filesystem-dependent, so the
    // test is order-agnostic: just assert both values are present.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".git");
    try tmp.dir.createDirPath(rt.io, ".jj");
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const got = try detectVcs(testing.allocator, cwd);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 2), got.len);

    var saw_git = false;
    var saw_jj = false;
    for (got) |vcs| {
        if (vcs == .git) saw_git = true;
        if (vcs == .jujutsu) saw_jj = true;
    }
    try testing.expect(saw_git);
    try testing.expect(saw_jj);
}

test "detectVcs returns empty slice for a non-VCS directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "plain.txt", .data = "hello" });
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const got = try detectVcs(testing.allocator, cwd);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "detectVcs gracefully handles a non-existent directory" {
    // openDir on a missing path should return the empty slice
    // via the catch fallback, not propagate an error.
    const got = try detectVcs(testing.allocator, "/nonexistent/path/to/nowhere-xyzzy");
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "detectVcs finds mercurial via .hg" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".hg");
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const got = try detectVcs(testing.allocator, cwd);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(Vcs.mercurial, got[0]);
}
