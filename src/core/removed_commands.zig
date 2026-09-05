//! P9b (PRD #534) exact-match removals. These slash commands existed in zcode
//! but NOT in claude-code-main; under the exact-match policy they are removed
//! from the surface so a Claude Code user sees the same command set. The REPL
//! dispatcher consults `isRemoved` early and treats a removed command as
//! unrecognized (identical to any non-existent command), short-circuiting its
//! now-unreachable handler.
//!
//! This is the single reviewable list the user vetoes from: delete a name here
//! to restore that command. Workflow-critical commands (/commit, /pr,
//! /pr-status) are deliberately NOT listed (kept per the parity decision).
//!
//! Pure: a command in, a bool out. No allocation, no IO.

const std = @import("std");

/// zcode-only commands removed for exact-match parity with Claude Code.
///
/// commands-01/02/03/04 (wp1a-commands-surface): /advisor, /cd,
/// /security-review, /security_review, and /marketplace were previously
/// listed here, but all five ARE real 2.1.261 commands (cc_commands_full.json:
/// advisor, cd, security-review [bundled plugin-skill], and plugin's
/// "marketplace" alias) with full, already-working zcode handlers that this
/// list was wrongly short-circuiting. Restored below the list is the reviewed
/// removal policy for the ones that really do have no reference counterpart.
pub const removed = [_][]const u8{
    "/changelog",
    "/density",
    "/errors",
    "/features",
    "/format",
    "/lang",
    // NOTE: /mode is deliberately NOT removed. It is a substantial, tested
    // feature (execution/planning/brainstorm/review with subcommand
    // autocomplete) handled inline in repl.zig; the code-review surfaced that
    // "removing" it broke its tests and lost real functionality. Vetoed per the
    // reviewable-removal policy. Re-add here only if you truly want it gone
    // (then also drop its inline handler + autocomplete subcommands).
    "/preprocessor",
    "/prompt",
    "/whoami",
    "/todos",
    "/pwd",
};

/// True when the leading command word is a removed command. Matches the leading
/// word only (so "/density 2" is removed too) and is case-insensitive.
pub fn isRemoved(command: []const u8) bool {
    const head = blk: {
        const sp = std.mem.indexOfScalar(u8, command, ' ');
        break :blk if (sp) |i| command[0..i] else command;
    };
    for (removed) |r| {
        if (std.ascii.eqlIgnoreCase(head, r)) return true;
    }
    return false;
}

const testing = std.testing;

test "removed commands are recognized, with and without args" {
    try testing.expect(isRemoved("/whoami"));
    try testing.expect(isRemoved("/density 2"));
}

test "kept and unrelated commands are not removed" {
    try testing.expect(!isRemoved("/commit"));
    try testing.expect(!isRemoved("/pr"));
    try testing.expect(!isRemoved("/pr-status"));
    try testing.expect(!isRemoved("/model"));
    try testing.expect(!isRemoved("/help"));
    // commands-sweep-01: /insights is a real reference command (always-registered
    // type:'prompt' command in claude-code-main). It must NOT be filtered out, so
    // its inline stats/insights handler stays reachable instead of returning
    // "unknown command".
    try testing.expect(!isRemoved("/insights"));
    try testing.expect(!isRemoved("/insights --since 7d"));
}

test "commands-01/02/03/04: real 2.1.261 commands are no longer blocked" {
    // These five were wrongly listed as removed; each is a genuine 2.1.261
    // command (advisor, cd, security-review [bundled plugin-skill],
    // security_review, and plugin's "marketplace" alias) with a working zcode
    // handler that must be reachable again.
    try testing.expect(!isRemoved("/advisor"));
    try testing.expect(!isRemoved("/advisor on"));
    try testing.expect(!isRemoved("/cd"));
    try testing.expect(!isRemoved("/cd /tmp"));
    try testing.expect(!isRemoved("/security-review"));
    try testing.expect(!isRemoved("/SECURITY-REVIEW"));
    try testing.expect(!isRemoved("/security_review"));
    try testing.expect(!isRemoved("/marketplace"));
    try testing.expect(!isRemoved("/marketplace add x y"));
}
