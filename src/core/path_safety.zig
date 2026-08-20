// Bypass-immune path-safety guard for auto-edits/writes.
//
// Ports the dangerous-directory / dangerous-file / suspicious-pattern
// checks from claude-code-main/src/utils/permissions/filesystem.ts
// (DANGEROUS_FILES / DANGEROUS_DIRECTORIES at 57-79,
// isDangerousFilePathToAutoEdit at 435-488,
// hasSuspiciousWindowsPathPattern at 537-602,
// normalizeCaseForComparison at 90-92).
//
// The reference treats a failed safety check as an "ask" that survives
// bypass/yolo mode (permissions.ts step 1g). zcode mirrors that: the
// caller in agent_tools.zig runs this guard BEFORE the yolo
// short-circuit, so a dangerous edit prompts/blocks even in yolo. The
// file-tool layer (tools/file.zig) also calls check() directly as a
// hard floor for direct callers.
//
// This module is PURE: it takes a path string and returns a verdict.
// No IO, no allocations, no runtime singleton. A thin symlink-resolving
// wrapper lives in the tool layer where IO already lives.

const std = @import("std");

/// Dangerous directories that must not be auto-edited. Matched
/// case-insensitively against every path segment. `.zcode` is added
/// to the reference list since zcode's own config dir is equally
/// sensitive (a code-exec / exfil vector via settings/hooks).
const dangerous_dirs = [_][]const u8{
    ".git",
    ".vscode",
    ".idea",
    ".claude",
    ".zcode",
};

/// Dangerous files that must not be auto-edited. Matched
/// case-insensitively against the final path segment.
/// `.claude.toml` is added for zcode's TOML config variant.
const dangerous_files = [_][]const u8{
    ".gitconfig",
    ".gitmodules",
    ".bashrc",
    ".bash_profile",
    ".zshrc",
    ".zprofile",
    ".profile",
    ".ripgreprc",
    ".mcp.json",
    ".claude.json",
    ".claude.toml",
};

pub const Verdict = union(enum) {
    safe,
    /// The path traverses a dangerous directory; payload is the
    /// matched directory name (borrowed from `dangerous_dirs`).
    dangerous_dir: []const u8,
    /// The final segment is a dangerous file; payload is the matched
    /// file name (borrowed from `dangerous_files`).
    dangerous_file: []const u8,
    /// The path contains a suspicious pattern (trailing dot/space,
    /// DOS device suffix, 8.3 short name, three-dot component, UNC,
    /// long-path prefix). Always requires manual approval.
    suspicious_pattern,

    pub fn isSafe(self: Verdict) bool {
        return self == .safe;
    }
};

/// Returns true when the path contains a suspicious pattern that could
/// bypass string matching through path canonicalization. Ported from
/// hasSuspiciousWindowsPathPattern (filesystem.ts:537-602). Checked on
/// all platforms because NTFS can be mounted on macOS/Linux. We use
/// pattern DETECTION (require approval), not normalization, per the
/// reference rationale.
pub fn hasSuspiciousPattern(path: []const u8) bool {
    if (path.len == 0) return false;

    // 8.3 short names: '~' followed by an ASCII digit (GIT~1, CLAUDE~1).
    {
        var i: usize = 0;
        while (i + 1 < path.len) : (i += 1) {
            if (path[i] == '~' and std.ascii.isDigit(path[i + 1])) return true;
        }
    }

    // Long-path prefixes: \\?\, \\.\, //?/, //./ .
    if (std.mem.startsWith(u8, path, "\\\\?\\") or
        std.mem.startsWith(u8, path, "\\\\.\\") or
        std.mem.startsWith(u8, path, "//?/") or
        std.mem.startsWith(u8, path, "//./"))
    {
        return true;
    }

    // UNC paths (defense-in-depth): leading \\ or // .
    if (std.mem.startsWith(u8, path, "\\\\") or std.mem.startsWith(u8, path, "//")) {
        return true;
    }

    // Trailing dot or space that Windows strips during resolution
    // (.git., .bashrc , settings.json...). A bare "." or ".." is a
    // legitimate path component, so only flag a trailing dot/space when
    // the final segment is not exactly "." or "..".
    {
        const last = path[path.len - 1];
        if (last == '.' or last == ' ') {
            const seg = lastSegment(path);
            if (!std.mem.eql(u8, seg, ".") and !std.mem.eql(u8, seg, "..")) {
                return true;
            }
        }
    }

    // DOS device suffix after a final dot: CON, PRN, AUX, NUL, COM1-9,
    // LPT1-9 (case-insensitive). e.g. settings.json.PRN, .bashrc.AUX.
    if (lastDotSuffix(path)) |suffix| {
        if (isDosDeviceName(suffix)) return true;
    }

    // Three-or-more consecutive dots used as a path component: bounded
    // on both sides by a separator or string end (.../x, x/.../y, /...).
    if (hasThreeDotComponent(path)) return true;

    return false;
}

/// Core safety verdict. Pure: no IO. Splits on both '/' and '\\' so a
/// Windows-style separator cannot smuggle a dangerous segment past a
/// '/'-only split.
pub fn check(path: []const u8) Verdict {
    if (path.len == 0) return .safe;

    if (hasSuspiciousPattern(path)) return .suspicious_pattern;

    // Walk every segment, case-insensitive, against dangerous_dirs.
    // Apply the .claude/worktrees/ structural exception: a `.claude`
    // immediately followed by `worktrees` is where zcode/Claude store
    // git worktrees, not a user config dir; skip that one `.claude`
    // but keep checking other segments (a nested .claude inside the
    // worktree is still blocked).
    var it = SegmentIterator{ .path = path };
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        for (dangerous_dirs) |dir| {
            if (!std.ascii.eqlIgnoreCase(seg, dir)) continue;

            if (std.ascii.eqlIgnoreCase(dir, ".claude")) {
                if (it.peek()) |nxt| {
                    if (std.ascii.eqlIgnoreCase(nxt, "worktrees")) {
                        break; // skip this .claude, keep scanning
                    }
                }
            }
            return .{ .dangerous_dir = dir };
        }
    }

    // Final segment against dangerous_files (case-insensitive).
    const final = lastSegment(path);
    for (dangerous_files) |f| {
        if (std.ascii.eqlIgnoreCase(final, f)) {
            return .{ .dangerous_file = f };
        }
    }

    return .safe;
}

// ── helpers ──────────────────────────────────────────────────────

/// Iterates path segments split on '/' and '\\'. Empty segments
/// (leading slash, doubled separator) are yielded as zero-length and
/// skipped by the caller.
const SegmentIterator = struct {
    path: []const u8,
    idx: usize = 0,

    fn isSep(c: u8) bool {
        return c == '/' or c == '\\';
    }

    fn next(self: *SegmentIterator) ?[]const u8 {
        if (self.idx > self.path.len) return null;
        if (self.idx == self.path.len) {
            self.idx += 1;
            return null;
        }
        const start = self.idx;
        while (self.idx < self.path.len and !isSep(self.path[self.idx])) : (self.idx += 1) {}
        const seg = self.path[start..self.idx];
        // step over the separator
        if (self.idx < self.path.len) self.idx += 1;
        return seg;
    }

    /// Look at the next non-empty segment without consuming. Used for
    /// the .claude/worktrees exception.
    fn peek(self: *SegmentIterator) ?[]const u8 {
        var probe = SegmentIterator{ .path = self.path, .idx = self.idx };
        while (probe.next()) |seg| {
            if (seg.len != 0) return seg;
        }
        return null;
    }
};

/// Final path component (text after the last '/' or '\\').
fn lastSegment(path: []const u8) []const u8 {
    var start: usize = 0;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/' or path[i] == '\\') start = i + 1;
    }
    return path[start..];
}

/// Returns the substring after the last '.' in the final path segment,
/// or null when the final segment has no dot.
fn lastDotSuffix(path: []const u8) ?[]const u8 {
    const seg = lastSegment(path);
    var dot: ?usize = null;
    var i: usize = 0;
    while (i < seg.len) : (i += 1) {
        if (seg[i] == '.') dot = i;
    }
    if (dot) |d| {
        if (d + 1 <= seg.len) return seg[d + 1 ..];
    }
    return null;
}

fn isDosDeviceName(name: []const u8) bool {
    const fixed = [_][]const u8{ "CON", "PRN", "AUX", "NUL" };
    for (fixed) |d| {
        if (std.ascii.eqlIgnoreCase(name, d)) return true;
    }
    // COM1-9 and LPT1-9.
    if (name.len == 4) {
        if (std.ascii.eqlIgnoreCase(name[0..3], "COM") and name[3] >= '1' and name[3] <= '9') return true;
        if (std.ascii.eqlIgnoreCase(name[0..3], "LPT") and name[3] >= '1' and name[3] <= '9') return true;
    }
    return false;
}

/// True when the path has a run of 3+ consecutive dots bounded on each
/// side by a path separator or the string boundary (a path component
/// of all dots). Mirrors the reference regex /(^|\/|\\)\.{3,}(\/|\\|$)/.
fn hasThreeDotComponent(path: []const u8) bool {
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] != '.') continue;
        // left boundary: start, or preceded by a separator.
        const left_ok = i == 0 or path[i - 1] == '/' or path[i - 1] == '\\';
        if (!left_ok) continue;
        var j = i;
        while (j < path.len and path[j] == '.') : (j += 1) {}
        const run = j - i;
        const right_ok = j == path.len or path[j] == '/' or path[j] == '\\';
        if (run >= 3 and right_ok) return true;
        i = if (j > i) j - 1 else i;
    }
    return false;
}

// ── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "check flags dangerous directory .git" {
    const v = check("src/.git/config");
    try testing.expect(v == .dangerous_dir);
    try testing.expectEqualStrings(".git", v.dangerous_dir);
}

test "check flags dangerous file .bashrc" {
    const v = check("/home/u/.bashrc");
    try testing.expect(v == .dangerous_file);
    try testing.expectEqualStrings(".bashrc", v.dangerous_file);
}

test "check flags .claude directory" {
    const v = check(".claude/settings.json");
    try testing.expect(v == .dangerous_dir);
    try testing.expectEqualStrings(".claude", v.dangerous_dir);
}

test "check allows .claude/worktrees structural exception" {
    const v = check(".claude/worktrees/x/foo.zig");
    try testing.expect(v == .safe);
}

test "check still blocks nested .claude inside a worktree" {
    // A .claude NOT followed by worktrees is still dangerous, even when
    // it appears after a worktrees segment.
    const v = check(".claude/worktrees/x/.claude/settings.json");
    try testing.expect(v == .dangerous_dir);
}

test "check is case-insensitive for directories" {
    const v = check(".CLAUDE/Settings.json");
    try testing.expect(v == .dangerous_dir);
}

test "check flags trailing dot and space" {
    try testing.expect(check(".git.") == .suspicious_pattern);
    try testing.expect(check(".bashrc ") == .suspicious_pattern);
}

test "check flags DOS device suffix" {
    try testing.expect(check("settings.json.PRN") == .suspicious_pattern);
    try testing.expect(check("notes.txt.CON") == .suspicious_pattern);
    try testing.expect(check("out.COM1") == .suspicious_pattern);
}

test "check flags UNC path" {
    try testing.expect(check("\\\\server\\share\\x") == .suspicious_pattern);
    try testing.expect(check("//server/share/x") == .suspicious_pattern);
}

test "check flags 8.3 short names" {
    try testing.expect(check("GIT~1/config") == .suspicious_pattern);
    try testing.expect(check("CLAUDE~1") == .suspicious_pattern);
}

test "check flags three-dot component" {
    try testing.expect(check(".../file.txt") == .suspicious_pattern);
    try testing.expect(check("path/.../file") == .suspicious_pattern);
}

test "check allows ordinary source path" {
    try testing.expect(check("src/main.zig") == .safe);
    try testing.expect(check("/repo/lib/util.zig") == .safe);
}

test "check allows legitimate dot and dotdot components" {
    try testing.expect(check("./src/main.zig") == .safe);
    try testing.expect(check("../sibling/file.zig") == .safe);
}

test "check flags backslash-separated dangerous dir" {
    const v = check("src\\.git\\config");
    try testing.expect(v == .dangerous_dir);
}

test "check flags zcode config dir" {
    const v = check(".zcode/config.toml");
    try testing.expect(v == .dangerous_dir);
}

test "check flags .mcp.json and .claude.json files" {
    try testing.expect(check("project/.mcp.json") == .dangerous_file);
    try testing.expect(check("/home/u/.claude.json") == .dangerous_file);
}

test "empty path is safe" {
    try testing.expect(check("") == .safe);
}
