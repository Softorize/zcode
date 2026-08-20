//! Git ref-name and SHA validators.
//!
//! Ports `isSafeRefName` / `isValidGitSha` from the reference
//! `claude-code-main/src/utils/git/gitFilesystem.ts:98-131`. These are the
//! cheap hardening prerequisite for any direct `.git` filesystem reader and
//! for the branch-name -> git-arg paths (`/branch create`, `/branch switch`):
//! a ref name read from `.git/HEAD` or typed by the user can otherwise carry
//! shell metacharacters or path traversal (`..`) into a `git checkout` arg.
//!
//! Both functions are pure -- no allocation, no filesystem, no runtime
//! dependency -- so they are trivially testable and safe to call anywhere.

const std = @import("std");

/// Validate a git ref name is safe to pass as a shell/git argument and to use
/// as a path component. Rejects ref names that could enable command injection
/// (newlines, backticks, `$`, `;`, `|`, `&`, `(`, `)`, `<`, `>`, spaces, tabs,
/// quotes, backslash) and path traversal (`..`).
///
/// Mirrors the reference allowlist: alphanumerics plus `/`, `.`, `_`, `+`,
/// `-`, `@`. Git's forbidden `@{` sequence is blocked because `{` is not in
/// the allowlist.
pub fn isSafeRefName(name: []const u8) bool {
    // Reject empty, leading `-` (looks like a flag), leading `/` (absolute).
    if (name.len == 0) return false;
    if (name[0] == '-' or name[0] == '/') return false;

    // Reject any `..` (path traversal).
    if (std.mem.indexOf(u8, name, "..") != null) return false;

    // Reject single-dot and empty `/`-separated components (`.`, `foo/./bar`,
    // `foo//bar`, `foo/`). Git-check-ref-format rejects these, and `.`
    // normalizes away in path joins so a tampered HEAD of `refs/heads/.`
    // would make us watch the refs/heads directory itself.
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |component| {
        if (component.len == 0) return false;
        if (std.mem.eql(u8, component, ".")) return false;
    }

    // Allowlist-only: alphanumerics, `/`, `.`, `_`, `+`, `-`, `@`. Rejects all
    // shell metacharacters, whitespace, NUL, and non-ASCII.
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '/' or c == '.' or c == '_' or
            c == '+' or c == '-' or c == '@';
        if (!ok) return false;
    }

    return true;
}

/// Validate that a string is a git SHA: 40 hex chars (SHA-1) or 64 hex chars
/// (SHA-256). Git never writes abbreviated SHAs to HEAD or ref files, so only
/// full-length hashes are accepted. Hex digits must be lowercase, matching the
/// reference `^[0-9a-f]{40}$` / `^[0-9a-f]{64}$`.
pub fn isValidGitSha(s: []const u8) bool {
    if (s.len != 40 and s.len != 64) return false;
    for (s) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!ok) return false;
    }
    return true;
}

const testing = std.testing;

test "isSafeRefName accepts normal ref names" {
    try testing.expect(isSafeRefName("feature/foo"));
    try testing.expect(isSafeRefName("main"));
    try testing.expect(isSafeRefName("refs/heads/release-1.2.3"));
    try testing.expect(isSafeRefName("user@host"));
    try testing.expect(isSafeRefName("v1.0.0+build"));
}

test "isSafeRefName rejects leading dash and slash" {
    try testing.expect(!isSafeRefName("-x"));
    try testing.expect(!isSafeRefName("/x"));
}

test "isSafeRefName rejects path traversal and bad components" {
    try testing.expect(!isSafeRefName("a..b"));
    try testing.expect(!isSafeRefName("foo/./bar"));
    try testing.expect(!isSafeRefName("foo//bar"));
    try testing.expect(!isSafeRefName("foo/"));
    try testing.expect(!isSafeRefName("."));
}

test "isSafeRefName rejects shell metacharacters and empty" {
    try testing.expect(!isSafeRefName(""));
    try testing.expect(!isSafeRefName("foo;rm"));
    try testing.expect(!isSafeRefName("foo bar"));
    try testing.expect(!isSafeRefName("foo`bar"));
    try testing.expect(!isSafeRefName("foo$bar"));
    try testing.expect(!isSafeRefName("foo{bar"));
    try testing.expect(!isSafeRefName("foo\nbar"));
}

test "isValidGitSha accepts 40 and 64 lowercase hex" {
    try testing.expect(isValidGitSha("da39a3ee5e6b4b0d3255bfef95601890afd80709"));
    try testing.expect(isValidGitSha("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"));
}

test "isValidGitSha rejects wrong length and non-lowercase-hex" {
    // 39 hex (one short).
    try testing.expect(!isValidGitSha("da39a3ee5e6b4b0d3255bfef95601890afd8070"));
    // Uppercase rejected.
    try testing.expect(!isValidGitSha("DA39A3EE5E6B4B0D3255BFEF95601890AFD80709"));
    // Non-hex char.
    try testing.expect(!isValidGitSha("za39a3ee5e6b4b0d3255bfef95601890afd80709"));
    try testing.expect(!isValidGitSha(""));
    // 41 hex (one long).
    try testing.expect(!isValidGitSha("da39a3ee5e6b4b0d3255bfef95601890afd807091"));
}
