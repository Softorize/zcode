//! JetBrains / Windows-WSL IDE path conversion (ide-integration-07).
//!
//! When zcode runs inside WSL and the connected IDE runs on the Windows
//! host, paths must be translated across the boundary: a WSL path like
//! `/home/me/x.zig` becomes a Windows path `\\wsl$\Ubuntu\home\me\x.zig`
//! before it is sent to the IDE (openDiff, Task 03), and a Windows path
//! coming back from the IDE (workspaceFolders, Task 01) becomes a WSL
//! path like `/mnt/c/Users/me/x.zig`.
//!
//! Reference (claude-code-main/src/utils/idePathConversion.ts):
//!   :25    WindowsToWSLConverter.
//!   :28-56 toLocalPath: if UNC `\\wsl$\<distro>` / `\\wsl.localhost\<distro>`
//!          for a *different* distro, return unchanged; else `wslpath -u`,
//!          falling back to backslash->slash + `^([A-Z]):` -> `/mnt/<lower>`.
//!   :58-73 toIDEPath: `wslpath -w <path>`, fallback returns original.
//!   :79-90 checkWSLDistroMatch: UNC distro equality test.
//!
//! `wslpath` only exists inside WSL; on the macOS / plain-Linux dev box
//! it is absent. Its absence must never propagate as an error -- every
//! shell-out falls back to the pure string transform (or the original
//! path). The pure transform (`manualWindowsToWsl`) is factored out so
//! CI on macOS exercises the logic that actually matters without a
//! `wslpath` dependency.

const std = @import("std");
const rt = @import("zcode_runtime");

/// UNC prefixes that identify a path living on a WSL distro filesystem,
/// e.g. `\\wsl$\Ubuntu\home\me` or `\\wsl.localhost\Debian\root`.
const UNC_PREFIXES = [_][]const u8{ "\\\\wsl$\\", "\\\\wsl.localhost\\" };

/// Pure backslash->slash + drive-letter transform used as the fallback
/// when `wslpath -u` is unavailable or fails. Mirrors the reference's
/// manual branch (idePathConversion.ts:40-55):
///   - every `\` becomes `/`,
///   - a leading `C:` (any A-Z) becomes `/mnt/c` (lower-cased drive).
/// Returns a caller-owned slice.
pub fn manualWindowsToWsl(allocator: std.mem.Allocator, windows_path: []const u8) ![]u8 {
    // Detect a leading drive-letter (`X:`) so it can be rewritten to
    // `/mnt/<lower>`; everything after it just has `\` flipped to `/`.
    const has_drive = windows_path.len >= 2 and
        std.ascii.isAlphabetic(windows_path[0]) and
        windows_path[1] == ':';

    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    var rest: []const u8 = windows_path;
    if (has_drive) {
        try out.appendSlice("/mnt/");
        try out.append(std.ascii.toLower(windows_path[0]));
        rest = windows_path[2..];
    }

    for (rest) |c| {
        try out.append(if (c == '\\') '/' else c);
    }

    return out.toOwnedSlice();
}

/// Parse the distro name out of a `\\wsl$\<distro>\...` or
/// `\\wsl.localhost\<distro>\...` UNC path. Returns null when the path
/// is not a WSL UNC path at all.
fn uncDistro(windows_path: []const u8) ?[]const u8 {
    for (UNC_PREFIXES) |prefix| {
        if (std.mem.startsWith(u8, windows_path, prefix)) {
            const after = windows_path[prefix.len..];
            const end = std.mem.indexOfScalar(u8, after, '\\') orelse after.len;
            return after[0..end];
        }
    }
    return null;
}

/// Returns true when `windows_path` either is not a WSL UNC path at all,
/// or is a UNC path whose distro matches `wsl_distro`. Returns false only
/// when it is a UNC path for a *different* distro. Mirrors
/// checkWSLDistroMatch (idePathConversion.ts:79-90): a path on another
/// distro must be left untouched because `wslpath` cannot translate it.
pub fn checkWslDistroMatch(windows_path: []const u8, wsl_distro: ?[]const u8) bool {
    const distro = uncDistro(windows_path) orelse return true;
    const want = wsl_distro orelse return true;
    return std.ascii.eqlIgnoreCase(distro, want);
}

/// Convert a Windows path coming from the IDE into a WSL-local path.
///   - empty input returns an empty owned slice,
///   - a UNC path on a different distro is returned unchanged (no
///     shell-out attempted),
///   - otherwise try `wslpath -u <path>` and trim its stdout on success,
///   - on any shell-out failure fall back to `manualWindowsToWsl`.
/// Returns a caller-owned slice.
pub fn toLocalPath(
    allocator: std.mem.Allocator,
    wsl_distro: ?[]const u8,
    windows_path: []const u8,
) ![]u8 {
    if (windows_path.len == 0) return allocator.alloc(u8, 0);

    // A path on a different distro cannot be translated; pass it through.
    if (!checkWslDistroMatch(windows_path, wsl_distro)) {
        return allocator.dupe(u8, windows_path);
    }

    if (runWslpath(allocator, "-u", windows_path)) |converted| {
        return converted;
    }

    return manualWindowsToWsl(allocator, windows_path);
}

/// Convert a WSL-local path into a Windows path for the IDE.
///   - empty input returns an empty owned slice,
///   - try `wslpath -w <path>` and trim its stdout on success,
///   - on any failure return the original path unchanged (the reference
///     `toIDEPath` fallback at idePathConversion.ts:69-72).
/// Returns a caller-owned slice.
pub fn toIdePath(allocator: std.mem.Allocator, wsl_path: []const u8) ![]u8 {
    if (wsl_path.len == 0) return allocator.alloc(u8, 0);

    if (runWslpath(allocator, "-w", wsl_path)) |converted| {
        return converted;
    }

    return allocator.dupe(u8, wsl_path);
}

/// Run `wslpath <flag> <path>` one-shot (per CLAUDE.md: `std.process.run`,
/// not the removed `Child.init`). Returns the trimmed stdout as a
/// caller-owned slice on a clean exit, or null on any failure (binary
/// absent, non-zero exit, empty output) so callers fall back. `wslpath`
/// is absent on macOS / plain-Linux, so a spawn error is the common case
/// off-WSL and must never surface as an error.
fn runWslpath(allocator: std.mem.Allocator, flag: []const u8, path: []const u8) ?[]u8 {
    const result = std.process.run(allocator, rt.io, .{
        .argv = &.{ "wslpath", flag, path },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) return null;

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return null;

    return allocator.dupe(u8, trimmed) catch null;
}

const testing = std.testing;

test "manualWindowsToWsl rewrites a drive-letter path" {
    const got = try manualWindowsToWsl(testing.allocator, "C:\\Users\\me\\x.zig");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/mnt/c/Users/me/x.zig", got);
}

test "manualWindowsToWsl lower-cases the drive letter" {
    const got = try manualWindowsToWsl(testing.allocator, "D:\\proj\\a.txt");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/mnt/d/proj/a.txt", got);
}

test "manualWindowsToWsl flips backslashes without a drive letter" {
    const got = try manualWindowsToWsl(testing.allocator, "\\some\\unc\\path");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/some/unc/path", got);
}

test "checkWslDistroMatch matches the same distro and rejects a different one" {
    try testing.expect(checkWslDistroMatch("\\\\wsl$\\Ubuntu\\home", "Ubuntu"));
    try testing.expect(!checkWslDistroMatch("\\\\wsl$\\Ubuntu\\home", "Debian"));
}

test "checkWslDistroMatch handles the wsl.localhost UNC form" {
    try testing.expect(checkWslDistroMatch("\\\\wsl.localhost\\Ubuntu\\root", "Ubuntu"));
    try testing.expect(!checkWslDistroMatch("\\\\wsl.localhost\\Ubuntu\\root", "Fedora"));
}

test "checkWslDistroMatch returns true for a non-UNC path" {
    try testing.expect(checkWslDistroMatch("C:\\Users\\me", "Ubuntu"));
    try testing.expect(checkWslDistroMatch("/already/wsl/local", "Ubuntu"));
}

test "checkWslDistroMatch returns true when no distro is supplied" {
    try testing.expect(checkWslDistroMatch("\\\\wsl$\\Ubuntu\\home", null));
}

test "toLocalPath leaves a mismatched-distro UNC path unchanged" {
    // A different distro cannot be translated; no shell-out is attempted
    // and the input is returned verbatim.
    const input = "\\\\wsl$\\Debian\\home\\me\\x.zig";
    const got = try toLocalPath(testing.allocator, "Ubuntu", input);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(input, got);
}

test "toLocalPath falls back to the manual transform when wslpath is absent" {
    // On the macOS dev box `wslpath` does not exist, so runWslpath returns
    // null and toLocalPath uses manualWindowsToWsl. This asserts the
    // fallback wiring, not a live wslpath.
    const got = try toLocalPath(testing.allocator, "Ubuntu", "C:\\Users\\me\\x.zig");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/mnt/c/Users/me/x.zig", got);
}

test "toLocalPath returns an empty owned slice for empty input" {
    const got = try toLocalPath(testing.allocator, "Ubuntu", "");
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "toIdePath returns the original path when wslpath is absent" {
    // Off-WSL, wslpath cannot run, so toIdePath returns the input
    // unchanged (the reference toIDEPath fallback).
    const got = try toIdePath(testing.allocator, "/home/me/x.zig");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/home/me/x.zig", got);
}

test "toIdePath returns an empty owned slice for empty input" {
    const got = try toIdePath(testing.allocator, "");
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);
}
