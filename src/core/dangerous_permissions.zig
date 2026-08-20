//! P3 (PRD #534) pure dangerous-bash-permission predicate. Mirrors Claude
//! Code's dangerousPatterns.ts + permissionSetup.ts isDangerousBashPermission.
//!
//! An allow rule like `Bash(python:*)` or `Bash(*)` lets the model run
//! arbitrary code via that interpreter, bypassing the auto-mode classifier.
//! This predicate flags such rules so the mode-transition code can strip them
//! when entering a restrictive mode (plan/auto).
//!
//! Pure module: a content string in, a bool out. No allocation, no IO. The
//! reference keys on toolName === BASH_TOOL_NAME; here the caller already knows
//! the rule's tool, so this module takes only the rule content and the caller
//! checks the tool name is the canonical bash tool.

const std = @import("std");

/// Cross-platform code-execution entry points present on both Unix and Windows
/// (dangerousPatterns.ts:18-42). Interpreters, package runners, shells, ssh.
pub const CROSS_PLATFORM_CODE_EXEC = [_][]const u8{
    // Interpreters
    "python",
    "python3",
    "python2",
    "node",
    "deno",
    "tsx",
    "ruby",
    "perl",
    "php",
    "lua",
    // Package runners
    "npx",
    "bunx",
    "npm run",
    "yarn run",
    "pnpm run",
    "bun run",
    // Shells reachable from both (Git Bash / WSL on Windows, native on Unix)
    "bash",
    "sh",
    // Remote arbitrary-command wrapper (native OpenSSH on Win10+)
    "ssh",
};

/// Dangerous bash allow-rule patterns (dangerousPatterns.ts:44-80). The
/// ant-only extras (coo/gh/curl/wget/git/kubectl/aws/gcloud/gsutil/fa run) are
/// gated on USER_TYPE === 'ant' in the reference; zcode has no ant notion, so
/// they are deliberately omitted. If a future enterprise policy wants a broader
/// list, it is an additive change to this array.
pub const DANGEROUS_BASH_PATTERNS = CROSS_PLATFORM_CODE_EXEC ++ [_][]const u8{
    "zsh",
    "fish",
    "eval",
    "exec",
    "env",
    "xargs",
    "sudo",
};

/// True if a single-char ASCII byte is whitespace the reference's String.trim
/// would strip. JS trim strips spaces, tabs, and line terminators; we cover the
/// common ASCII whitespace set.
fn isTrimWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\n\r\x0b\x0c");
}

/// Case-insensitive equality (the reference lowercases both content and
/// pattern before comparing).
fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Case-insensitive startsWith.
fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

/// Whether an allow-rule's bash content is "dangerous" - i.e. would let the
/// model run arbitrary code, bypassing the classifier.
///
/// Reference (permissionSetup.ts:94-147, isDangerousBashPermission):
///   - tool-level allow (empty content or "*") -> dangerous
///   - otherwise the trimmed, lowercased content is matched against each
///     pattern in five shapes:
///       exact          ("python")
///       prefix         ("python:*")
///       wildcard       ("python*")
///       space-wildcard ("python *")
///       flag-wildcard  ("python -...*"  -> startsWith "python -" AND endsWith "*")
///
/// Comparisons are case-insensitive, so "PYTHON:*" matches.
pub fn isDangerousBashContent(content_raw: []const u8) bool {
    const content = trim(content_raw);

    // Tool-level allow (empty content, or "*") - allows ALL commands.
    if (content.len == 0) return true;
    if (std.mem.eql(u8, content, "*")) return true;

    for (DANGEROUS_BASH_PATTERNS) |pattern| {
        // Exact match to the pattern itself (e.g. "python" as a rule).
        if (eqIgnoreCase(content, pattern)) return true;

        // Build the suffixed shapes on a small stack buffer. The longest
        // pattern is "yarn run"/"pnpm run" (8 bytes) + " *" (2) so 16 is ample.
        var buf: [64]u8 = undefined;

        // Prefix syntax: "python:*"
        {
            const shape = std.fmt.bufPrint(&buf, "{s}:*", .{pattern}) catch unreachable;
            if (eqIgnoreCase(content, shape)) return true;
        }
        // Wildcard at end: "python*"
        {
            const shape = std.fmt.bufPrint(&buf, "{s}*", .{pattern}) catch unreachable;
            if (eqIgnoreCase(content, shape)) return true;
        }
        // Wildcard with space: "python *"
        {
            const shape = std.fmt.bufPrint(&buf, "{s} *", .{pattern}) catch unreachable;
            if (eqIgnoreCase(content, shape)) return true;
        }
        // Flag-wildcard: "python -...*" -> startsWith "python -" AND endsWith "*"
        {
            const flag_prefix = std.fmt.bufPrint(&buf, "{s} -", .{pattern}) catch unreachable;
            if (startsWithIgnoreCase(content, flag_prefix) and
                content.len > 0 and content[content.len - 1] == '*')
            {
                return true;
            }
        }
    }

    return false;
}

const testing = std.testing;

test "isDangerousBashContent matches all five rule shapes" {
    // Tool-level allow.
    try testing.expect(isDangerousBashContent(""));
    try testing.expect(isDangerousBashContent("*"));

    // Five shapes for python.
    try testing.expect(isDangerousBashContent("python")); // exact
    try testing.expect(isDangerousBashContent("python:*")); // prefix
    try testing.expect(isDangerousBashContent("python*")); // wildcard
    try testing.expect(isDangerousBashContent("python *")); // space-wildcard
    try testing.expect(isDangerousBashContent("python -c*")); // flag-wildcard

    // Other interpreters / patterns.
    try testing.expect(isDangerousBashContent("node:*"));
    try testing.expect(isDangerousBashContent("sudo:*"));
    try testing.expect(isDangerousBashContent("eval"));

    // Safe content stays false.
    try testing.expect(!isDangerousBashContent("git status"));
    try testing.expect(!isDangerousBashContent("ls"));
    try testing.expect(!isDangerousBashContent("npm test"));
    try testing.expect(!isDangerousBashContent("echo hi"));
}

test "isDangerousBashContent is case-insensitive" {
    try testing.expect(isDangerousBashContent("PYTHON:*"));
    try testing.expect(isDangerousBashContent("Node*"));
    try testing.expect(isDangerousBashContent("SUDO"));
    try testing.expect(isDangerousBashContent("Python -C 'X'*"));
}

test "isDangerousBashContent trims surrounding whitespace" {
    try testing.expect(isDangerousBashContent("  python:*  "));
    try testing.expect(isDangerousBashContent("\t*\t"));
    try testing.expect(isDangerousBashContent("   "));
}

test "DANGEROUS_BASH_PATTERNS extends CROSS_PLATFORM_CODE_EXEC" {
    // The concat must keep all cross-platform entries plus the seven bash extras.
    try testing.expectEqual(CROSS_PLATFORM_CODE_EXEC.len + 7, DANGEROUS_BASH_PATTERNS.len);
    // First entry is the first cross-platform interpreter.
    try testing.expectEqualStrings("python", DANGEROUS_BASH_PATTERNS[0]);
    // Last entry is the final bash-only extra.
    try testing.expectEqualStrings("sudo", DANGEROUS_BASH_PATTERNS[DANGEROUS_BASH_PATTERNS.len - 1]);
    // The ant-only entries are deliberately absent.
    for (DANGEROUS_BASH_PATTERNS) |p| {
        try testing.expect(!std.mem.eql(u8, p, "gh"));
        try testing.expect(!std.mem.eql(u8, p, "curl"));
        try testing.expect(!std.mem.eql(u8, p, "kubectl"));
    }
}
