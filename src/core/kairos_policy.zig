//! KAIROS autonomy policy — the pure decision logic for what the always-on
//! background agent may run with no human present.
//!
//! Per ADR 0008 (`docs/adr/0008-kairos-allowlist-autonomy.md`) KAIROS autonomy
//! is allowlist-driven, the deliberate middle between full autonomy (too high a
//! blast radius unattended) and plan-only (too weak to even run tests):
//!
//!   * read-only tools are ALWAYS allowed (the caller's risk classifier decides
//!     read-only-ness and passes it in as `is_read_only`);
//!   * a small, conservative, user-extensible allowlist of MUTATING-but-safe
//!     actions runs unsupervised;
//!   * everything else becomes a PROPOSAL — recorded, not executed.
//!
//! This module is intentionally pure: no IO, no runtime singleton, no allocation.
//! It is a decision function over plain inputs so it stays trivially testable and
//! the wiring into the KAIROS `ApprovalHandler` / approval gate lives elsewhere.

const std = @import("std");
const testing = std.testing;

/// The verdict for a single tool/action invocation under KAIROS autonomy.
pub const Decision = enum {
    /// Execute unsupervised.
    allow,
    /// Do NOT execute; record as a proposal for the user to approve later.
    propose,
};

/// Default allowlist of mutating tool/action names KAIROS may run unsupervised.
///
/// Conservative by design: only safe, reversible, non-destructive checks — the
/// read-y git subcommands plus the project's test/build/fmt verbs. Notably it
/// does NOT include `Edit`, `Write`, `git commit`, `git push`, or arbitrary
/// `Bash`/shell; those must always become proposals.
///
/// This list is meant to be USER-EXTENSIBLE via config: a deployment can supply
/// its own allowlist to `decide`/`inAllowlist`, so this constant is just the
/// safe baseline shipped out of the box. Getting it wrong (too permissive) is
/// the main risk per ADR 0008, hence the deliberately short default.
///
/// Entries are matched against the tool/action name the caller supplies. For
/// shell-style actions (e.g. a `Bash` call running `git status -s`) the caller
/// is expected to pass the command string; `inAllowlist` matches an entry that
/// is a prefix followed by a space, so `"git status -s"` matches `"git status"`.
pub const DEFAULT_ALLOWLIST = [_][]const u8{
    // Read-y git subcommands (mutating-classified by the caller out of caution,
    // but in practice non-destructive inspection of the working tree/history).
    "git status",
    "git diff",
    "git log",
    "git show",
    "git branch",
    // Project verbs: build, test, and format checks.
    "zig build",
    "zig build test",
    "zig fmt",
};

/// Decide whether KAIROS may run `tool_name` unsupervised.
///
/// `is_read_only` is true when the caller's risk classifier deems the call
/// non-mutating; those are always allowed. Otherwise the tool is allowed only if
/// it (or its action) matches an entry in `allowlist`, else it is a proposal.
pub fn decide(tool_name: []const u8, is_read_only: bool, allowlist: []const []const u8) Decision {
    if (is_read_only) return .allow;
    if (inAllowlist(tool_name, allowlist)) return .allow;
    return .propose;
}

/// True if `name` matches any allowlist entry.
///
/// Matching is case-insensitive. It also matches when `name` starts with an
/// entry followed by a space, so a `"git status --short"` invocation matches the
/// `"git status"` entry. An empty entry never matches.
pub fn inAllowlist(name: []const u8, allowlist: []const []const u8) bool {
    for (allowlist) |entry| {
        if (entry.len == 0) continue;
        if (matches(name, entry)) return true;
    }
    return false;
}

/// `name` matches `entry` if it equals it (case-insensitively) or begins with it
/// (case-insensitively) followed by a space.
fn matches(name: []const u8, entry: []const u8) bool {
    if (name.len < entry.len) return false;
    if (!std.ascii.eqlIgnoreCase(name[0..entry.len], entry)) return false;
    // Exact match.
    if (name.len == entry.len) return true;
    // Prefix-with-space match: the entry must be followed by a space so that
    // "git status" matches "git status -s" but not "git statusfoo".
    return name[entry.len] == ' ';
}

test "decide: read-only is always allowed regardless of allowlist" {
    try testing.expectEqual(Decision.allow, decide("Edit", true, &.{}));
    try testing.expectEqual(Decision.allow, decide("Write", true, &DEFAULT_ALLOWLIST));
    try testing.expectEqual(Decision.allow, decide("anything", true, &.{"git status"}));
}

test "decide: mutating but in allowlist is allowed" {
    try testing.expectEqual(Decision.allow, decide("git status", false, &DEFAULT_ALLOWLIST));
    try testing.expectEqual(Decision.allow, decide("git diff --stat", false, &DEFAULT_ALLOWLIST));
    try testing.expectEqual(Decision.allow, decide("zig build test", false, &DEFAULT_ALLOWLIST));
}

test "decide: mutating and not in allowlist is a proposal" {
    try testing.expectEqual(Decision.propose, decide("Edit", false, &DEFAULT_ALLOWLIST));
    try testing.expectEqual(Decision.propose, decide("git commit", false, &DEFAULT_ALLOWLIST));
    try testing.expectEqual(Decision.propose, decide("git push", false, &DEFAULT_ALLOWLIST));
    try testing.expectEqual(Decision.propose, decide("rm -rf /", false, &DEFAULT_ALLOWLIST));
}

test "inAllowlist: exact case-insensitive match" {
    try testing.expect(inAllowlist("git status", &.{"git status"}));
    try testing.expect(inAllowlist("GIT STATUS", &.{"git status"}));
    try testing.expect(inAllowlist("git status", &.{"GIT STATUS"}));
}

test "inAllowlist: prefix-with-space match" {
    try testing.expect(inAllowlist("git status -s", &.{"git status"}));
    try testing.expect(inAllowlist("GIT STATUS --short", &.{"git status"}));
    // No space between entry and trailing chars must NOT match.
    try testing.expect(!inAllowlist("git statusfoo", &.{"git status"}));
}

test "inAllowlist: non-match and empty allowlist" {
    try testing.expect(!inAllowlist("git commit", &.{"git status"}));
    try testing.expect(!inAllowlist("git status", &.{}));
    // A shorter name than the entry can never match.
    try testing.expect(!inAllowlist("git", &.{"git status"}));
    // Empty entries never match.
    try testing.expect(!inAllowlist("git status", &.{""}));
}

test "inAllowlist: default allowlist excludes destructive actions" {
    try testing.expect(inAllowlist("git status", &DEFAULT_ALLOWLIST));
    try testing.expect(inAllowlist("zig fmt src/", &DEFAULT_ALLOWLIST));
    try testing.expect(!inAllowlist("git commit -m x", &DEFAULT_ALLOWLIST));
    try testing.expect(!inAllowlist("Write", &DEFAULT_ALLOWLIST));
    try testing.expect(!inAllowlist("Bash", &DEFAULT_ALLOWLIST));
}
