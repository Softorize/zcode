//! P3 (PRD #534) hook matcher. Claude Code hook matchers use permission-rule
//! syntax for tool events (`Bash(git *)`, bare `Read`, `*`) and a simple field
//! value for non-tool events (e.g. SessionStart source `startup`). Reuses the
//! rule engine's glob so there is one wildcard implementation.
//!
//! Pure: no allocation, no IO.

const std = @import("std");
const pr = @import("permission_rules.zig");
const mini_regex = @import("mini_regex.zig");

/// Match a tool-event matcher against a tool call. Empty or "*" matches all.
/// `Tool(pattern)` matches the tool name (exact or "*") and globs the pattern
/// against the serialized tool input; a bare `Tool` matches the name only.
///
/// A name-only matcher (no `(`) reproduces the reference's `matchesPattern`
/// (`utils/hooks.ts:1346-1381`): if it is `^[A-Za-z0-9_|]+$` it is an exact or
/// pipe-separated exact list compared to the tool name; otherwise it is treated
/// as a regex tested (unanchored) against the tool name. An invalid regex never
/// matches (and never panics), matching the reference's catch-and-ignore path.
pub fn matchesTool(matcher: []const u8, tool_name: []const u8, tool_input: []const u8) bool {
    const m = std.mem.trim(u8, matcher, " \t");
    if (m.len == 0 or std.mem.eql(u8, m, "*")) return true;
    if (std.mem.indexOfScalar(u8, m, '(')) |lp| {
        const tool = std.mem.trim(u8, m[0..lp], " \t");
        var pat = m[lp + 1 ..];
        if (std.mem.lastIndexOfScalar(u8, pat, ')')) |rp| pat = pat[0..rp];
        if (!(std.mem.eql(u8, tool, "*") or std.mem.eql(u8, tool, tool_name))) return false;
        // Unanchored: tool_input is the serialized JSON args, so an anchored
        // glob like `git *` would never match. PRD #534 review fix.
        return pr.globContains(std.mem.trim(u8, pat, " \t"), tool_input);
    }
    if (isExactOrPipeList(m)) return matchesPipeList(m, tool_name);
    // Anything else is a regex tested against the tool name (unanchored).
    return mini_regex.matches(m, tool_name);
}

/// True if `m` is `^[A-Za-z0-9_|]+$`: only word chars and the `|` separator,
/// i.e. a single exact name or a pipe-separated list of exact names. This is
/// the reference's `/^[a-zA-Z0-9_|]+$/` discriminator (`utils/hooks.ts:1360`).
fn isExactOrPipeList(m: []const u8) bool {
    if (m.len == 0) return false;
    for (m) |c| {
        const ok = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '|';
        if (!ok) return false;
    }
    return true;
}

/// Split `m` on `|` and exact-compare each segment to `tool_name`.
fn matchesPipeList(m: []const u8, tool_name: []const u8) bool {
    var it = std.mem.splitScalar(u8, m, '|');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, tool_name)) return true;
    }
    return false;
}

/// Match a non-tool-event matcher against a single field value (e.g. the
/// SessionStart `source`, the Notification `notification_type`). Empty or "*"
/// matches all; otherwise glob the matcher against the value.
pub fn matchesField(matcher: []const u8, value: []const u8) bool {
    const m = std.mem.trim(u8, matcher, " \t");
    if (m.len == 0 or std.mem.eql(u8, m, "*")) return true;
    return pr.globMatch(m, value);
}

/// Per-hook `if` permission-rule pre-filter (`schemas/hooks.ts:19-27`,
/// `utils/hooks.ts:1390/1822-1848`). The `if` parses as a permission rule
/// `Tool(content)`; it matches when the tool name equals the call's tool and
/// the content (a glob) matches the serialized tool input. An empty `if` is no
/// filter (always matches). A bare `Tool` (no parens) matches the name only.
/// This is the same `Tool(pattern)` shape as `matchesTool`'s parens branch.
/// For non-tool events the `if` cannot be evaluated, so callers should skip a
/// hook with a non-empty `if` rather than call this.
pub fn matchesIf(if_cond: []const u8, tool_name: []const u8, tool_input: []const u8) bool {
    const c = std.mem.trim(u8, if_cond, " \t");
    if (c.len == 0) return true;
    if (std.mem.indexOfScalar(u8, c, '(')) |lp| {
        const tool = std.mem.trim(u8, c[0..lp], " \t");
        var pat = c[lp + 1 ..];
        if (std.mem.lastIndexOfScalar(u8, pat, ')')) |rp| pat = pat[0..rp];
        if (!(std.mem.eql(u8, tool, "*") or std.mem.eql(u8, tool, tool_name))) return false;
        const p = std.mem.trim(u8, pat, " \t");
        if (p.len == 0) return true;
        return pr.globContains(p, tool_input);
    }
    // Bare `Tool` with no content matches the tool name only.
    return std.mem.eql(u8, c, "*") or std.mem.eql(u8, c, tool_name);
}

const testing = std.testing;

test "matchesTool: empty and star match all" {
    try testing.expect(matchesTool("", "Bash", "anything"));
    try testing.expect(matchesTool("*", "Read", "x"));
}

test "matchesTool: Tool(pattern) globs the input" {
    try testing.expect(matchesTool("Bash(git *)", "Bash", "git status"));
    try testing.expect(!matchesTool("Bash(git *)", "Bash", "npm i"));
    try testing.expect(!matchesTool("Bash(git *)", "Read", "git status"));
    // unanchored: matches inside the serialized JSON tool args
    try testing.expect(matchesTool("Bash(git *)", "Bash", "{\"command\":\"git status\"}"));
    try testing.expect(!matchesTool("Bash(git *)", "Bash", "{\"command\":\"npm i\"}"));
}

test "matchesTool: bare tool matches name only" {
    try testing.expect(matchesTool("Read", "Read", "any.zig"));
    try testing.expect(!matchesTool("Read", "Write", "any.zig"));
}

test "matchesTool: pipe-separated exact list" {
    try testing.expect(matchesTool("Edit|Write", "Write", "x"));
    try testing.expect(matchesTool("Edit|Write", "Edit", "x"));
    try testing.expect(!matchesTool("Edit|Write", "Read", "x"));
    // single exact name still works through the pipe-list path
    try testing.expect(matchesTool("Bash", "Bash", "x"));
    try testing.expect(!matchesTool("Bash", "BashOutput", "x"));
}

test "matchesTool: regex matchers" {
    try testing.expect(matchesTool("^Notebook.*", "NotebookEdit", "x"));
    try testing.expect(matchesTool("^Bash$", "Bash", "x"));
    try testing.expect(!matchesTool("^Bash$", "BashOutput", "x"));
    // unanchored test() semantics: a regex (has a metachar, so not a pipe-list)
    // matches anywhere in the tool name.
    try testing.expect(matchesTool("Edit.*", "MultiEdit", "x"));
    try testing.expect(matchesTool("Edit$", "MultiEdit", "x"));
    // an invalid regex never matches (no panic)
    try testing.expect(!matchesTool("^(", "Bash", "x"));
}

test "matchesField: exact, glob, and wildcard" {
    try testing.expect(matchesField("startup", "startup"));
    try testing.expect(!matchesField("startup", "resume"));
    try testing.expect(matchesField("user_*", "user_settings"));
    try testing.expect(matchesField("", "anything"));
}

test "matchesIf: Tool(content) gates by tool name and input glob" {
    // matching tool + matching content
    try testing.expect(matchesIf("Bash(git *)", "Bash", "git status"));
    // matching tool + non-matching content
    try testing.expect(!matchesIf("Bash(git *)", "Bash", "npm i"));
    // wrong tool name never matches
    try testing.expect(!matchesIf("Bash(git *)", "Read", "git status"));
    // empty `if` is no filter
    try testing.expect(matchesIf("", "Bash", "anything"));
    // unanchored: matches inside the serialized JSON tool args
    try testing.expect(matchesIf("Bash(git *)", "Bash", "{\"command\":\"git status\"}"));
}

test "matchesIf: bare tool and wildcard forms" {
    // bare `Tool` (no parens) matches the name only
    try testing.expect(matchesIf("Read", "Read", "any.zig"));
    try testing.expect(!matchesIf("Read", "Write", "any.zig"));
    // `*` tool wildcard with content gates on content alone
    try testing.expect(matchesIf("*(git *)", "Bash", "git status"));
    try testing.expect(!matchesIf("*(git *)", "Read", "npm i"));
    // empty content matches any input for that tool
    try testing.expect(matchesIf("Bash()", "Bash", "anything"));
    try testing.expect(!matchesIf("Bash()", "Read", "anything"));
}
