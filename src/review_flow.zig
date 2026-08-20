const std = @import("std");

pub const usage = "usage: /review [working|commit <sha>|branch <base>] or `zcode review [working|commit <sha>|branch <base>]`";

pub fn buildPrompt(allocator: std.mem.Allocator, subject: ?[]const u8) ![]u8 {
    const raw = std.mem.trim(u8, subject orelse "", " \t\r\n");
    if (raw.len == 0 or eqlIgnoreCase(raw, "working") or eqlIgnoreCase(raw, "uncommitted")) {
        return allocator.dupe(
            u8,
            "Review the current uncommitted repository changes.\n" ++
                "Use read-only tools only.\n" ++
                "Prioritize bugs, regressions, missing tests, risky assumptions, and behavior changes.\n" ++
                "Findings must come first, ordered by severity.\n" ++
                "If there are no findings, say that explicitly and mention residual testing gaps.\n" ++
                "Use GitDiff and GitLog as source of truth for changed code.\n",
        );
    }

    if (std.mem.startsWith(u8, raw, "commit ")) {
        const commit = std.mem.trim(u8, raw["commit ".len..], " \t");
        if (commit.len == 0) return error.InvalidReviewTarget;
        return std.fmt.allocPrint(
            allocator,
            "Review commit {s}.\n" ++
                "Use read-only tools only.\n" ++
                "Prioritize bugs, regressions, missing tests, risky assumptions, and behavior changes.\n" ++
                "Findings must come first, ordered by severity.\n" ++
                "Use GitDiff and GitLog as source of truth for changed code.\n",
            .{commit},
        );
    }

    if (std.mem.startsWith(u8, raw, "branch ")) {
        const base = std.mem.trim(u8, raw["branch ".len..], " \t");
        if (base.len == 0) return error.InvalidReviewTarget;
        return std.fmt.allocPrint(
            allocator,
            "Review the current branch against base branch {s}.\n" ++
                "Use read-only tools only.\n" ++
                "Prioritize bugs, regressions, missing tests, risky assumptions, and behavior changes.\n" ++
                "Findings must come first, ordered by severity.\n" ++
                "Use GitDiff and GitLog as source of truth for changed code.\n",
            .{base},
        );
    }

    return error.InvalidReviewTarget;
}

/// Build the prompt used by /security-review. Mirrors Claude Code's
/// security-review command: drops the model into a senior security
/// engineer role and asks it to look at the current branch's changes
/// against origin/HEAD for HIGH-CONFIDENCE vulnerabilities. The
/// reference builds this as a Markdown template with shell
/// substitution (`!git diff`); zcode inlines the git commands so the
/// agent loop runs them as tool calls with its own sandbox policy.
pub fn buildSecurityReviewPrompt(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "You are a senior security engineer conducting a focused security review of the changes on this branch.\n\n" ++
        "First, gather the git context yourself using read-only tools:\n" ++
        "  - `git status` for current working tree state\n" ++
        "  - `git diff --name-only origin/HEAD...` for the files touched on this branch\n" ++
        "  - `git log --no-decorate origin/HEAD...` for the commits on this branch\n" ++
        "  - `git diff origin/HEAD...` for the full diff of this branch vs. origin/HEAD\n\n" ++
        "OBJECTIVE: Perform a security-focused code review to identify HIGH-CONFIDENCE security vulnerabilities with real exploitation potential. This is NOT a general code review -- focus ONLY on security implications newly added by this PR. Do not comment on existing security concerns.\n\n" ++
        "CRITICAL INSTRUCTIONS:\n" ++
        "1. MINIMIZE FALSE POSITIVES: only flag issues where you are >80% confident of actual exploitability.\n" ++
        "2. AVOID NOISE: skip theoretical issues, style concerns, low-impact findings.\n" ++
        "3. FOCUS ON IMPACT: prioritize vulnerabilities that could lead to unauthorized access, data breaches, or system compromise.\n" ++
        "4. EXCLUSIONS: do NOT report the following -- denial of service / resource exhaustion; secrets stored on disk; rate limiting.\n\n" ++
        "SECURITY CATEGORIES:\n" ++
        "  Input validation: SQL/NoSQL/command/XXE/template/path-traversal injection.\n" ++
        "  Auth & authz: authentication bypass, privilege escalation, session flaws, JWT, authz bypass.\n" ++
        "  Crypto & secrets: hardcoded keys, weak crypto, improper key storage, bad randomness, cert bypass.\n" ++
        "  Injection & code exec: deserialization RCE, pickle/YAML, eval, XSS (reflected/stored/DOM).\n" ++
        "  Data exposure: sensitive data logging, PII handling, API data leakage, debug info exposure.\n\n" ++
        "OUTPUT FORMAT: Findings first, ordered by severity (critical > high > medium > low). For each finding, include:\n" ++
        "  - file:line reference from the diff\n" ++
        "  - one-sentence description of the vulnerability\n" ++
        "  - one-sentence exploitation scenario\n" ++
        "  - one-sentence recommended fix\n\n" ++
        "If there are no findings, say so explicitly and mention any categories you could not fully verify (e.g. `could not verify X because the diff does not touch it`).\n");
}

const eqlIgnoreCase = @import("core/parse_helpers.zig").eqlIgnoreCase;

const testing = std.testing;

test "buildPrompt defaults to working review" {
    const prompt = try buildPrompt(testing.allocator, null);
    defer testing.allocator.free(prompt);
    try testing.expect(std.mem.indexOf(u8, prompt, "uncommitted") != null);
}

test "buildPrompt supports commit and branch targets" {
    const commit_prompt = try buildPrompt(testing.allocator, "commit abc123");
    defer testing.allocator.free(commit_prompt);
    try testing.expect(std.mem.indexOf(u8, commit_prompt, "abc123") != null);

    const branch_prompt = try buildPrompt(testing.allocator, "branch main");
    defer testing.allocator.free(branch_prompt);
    try testing.expect(std.mem.indexOf(u8, branch_prompt, "main") != null);
}

test "buildSecurityReviewPrompt covers git context and categories" {
    const prompt = try buildSecurityReviewPrompt(testing.allocator);
    defer testing.allocator.free(prompt);
    try testing.expect(std.mem.indexOf(u8, prompt, "senior security engineer") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "git diff origin/HEAD") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "HIGH-CONFIDENCE") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "SQL/NoSQL/command") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "EXCLUSIONS") != null);
}
