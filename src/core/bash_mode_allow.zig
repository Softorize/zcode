//! P3 (PRD #534) pure accept-edits bash auto-allow. Mirrors Claude Code's
//! modeValidation.ts checkPermissionMode: in `acceptEdits` mode a fixed set of
//! filesystem bash commands (mkdir/touch/rm/rmdir/mv/cp/sed) auto-allow without
//! prompting. Compound commands are split on the shell operators &&, ||, ;, and
//! | and every subcommand's base command must be in the allowed set.
//!
//! Deliberate tightening vs the reference: the reference's checkPermissionMode
//! returns per-subcommand passthrough (ANY subcommand can trigger mode
//! behavior). zcode returns a single allow/passthrough decision, so we require
//! ALL subcommands to be filesystem commands. This avoids `mkdir x && curl evil`
//! slipping through: a compound that mixes a filesystem command with anything
//! else falls through to the generic gate (passthrough). This is safer than the
//! reference and matches zcode's safety bias.
//!
//! This module is NOT a full shell parser. Quoted operators (e.g. the literal
//! `&&` inside `echo "a && b"`) are an acknowledged edge that the reference's
//! splitCommand_DEPRECATED also handles imperfectly. We keep the conservative
//! operator splitter and bias to passthrough (ask) on ambiguity.
//!
//! Pure module: a command line + mode in, an allow/passthrough decision out.
//! No allocation, no IO.

const std = @import("std");
const permission_decision = @import("permission_decision.zig");

pub const Mode = permission_decision.Mode;

/// Filesystem commands acceptEdits auto-allows (modeValidation.ts:7-15).
pub const ACCEPT_EDITS_ALLOWED_COMMANDS = [_][]const u8{
    "mkdir", "touch", "rm", "rmdir", "mv", "cp", "sed",
};

/// Maximum number of subcommands we will split a compound command into. A
/// command with more subcommands than this overflows and is treated as "do not
/// auto-allow" (passthrough), biasing to safety rather than truncating.
const MAX_SUBCOMMANDS = 32;

pub const Decision = enum { allow, passthrough };

/// Return the base command of a single (already-split) subcommand: trim
/// surrounding ASCII whitespace, then return the first whitespace-delimited
/// token. Null if the subcommand is empty/whitespace-only.
fn baseCommand(cmd: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, cmd, " \t\r\n");
    if (trimmed.len == 0) return null;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
    return it.next();
}

fn isAllowedBase(base: []const u8) bool {
    for (ACCEPT_EDITS_ALLOWED_COMMANDS) |allowed| {
        if (std.ascii.eqlIgnoreCase(base, allowed)) return true;
    }
    return false;
}

/// Split a command line on the shell operators &&, ||, ;, and | into subslices
/// written into `buf`. Returns the populated slice, or null on overflow (more
/// than buf.len subcommands). `&&` and `||` are handled as two-char operators
/// (two-char lookahead) so they are not mistaken for two single `&`/`|`.
///
/// Not a shell parser: operators inside quotes are still treated as separators
/// (acknowledged edge - callers bias to passthrough on ambiguity).
fn splitCompound(command: []const u8, buf: [][]const u8) ?[][]const u8 {
    var count: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < command.len) {
        const c = command[i];
        var op_len: usize = 0;
        if (c == '&' and i + 1 < command.len and command[i + 1] == '&') {
            op_len = 2;
        } else if (c == '|' and i + 1 < command.len and command[i + 1] == '|') {
            op_len = 2;
        } else if (c == ';' or c == '|') {
            op_len = 1;
        }
        if (op_len != 0) {
            if (count >= buf.len) return null;
            buf[count] = command[start..i];
            count += 1;
            i += op_len;
            start = i;
            continue;
        }
        i += 1;
    }
    if (count >= buf.len) return null;
    buf[count] = command[start..];
    count += 1;
    return buf[0..count];
}

/// True if `command` should be auto-allowed under acceptEdits: every subcommand
/// in the compound has a base command in ACCEPT_EDITS_ALLOWED_COMMANDS. An empty
/// command, an overflowing compound, or any subcommand that is empty or not a
/// filesystem command -> false (do not auto-allow).
pub fn acceptEditsAutoAllows(command: []const u8) bool {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (trimmed.len == 0) return false;

    var buf: [MAX_SUBCOMMANDS][]const u8 = undefined;
    const subs = splitCompound(trimmed, &buf) orelse return false;

    for (subs) |sub| {
        const base = baseCommand(sub) orelse return false;
        if (!isAllowedBase(base)) return false;
    }
    return true;
}

/// Mode entry point mirroring checkPermissionMode (modeValidation.ts:72-109).
/// bypassPermissions and dontAsk are handled in the main flow (always
/// passthrough here). acceptEdits returns .allow when the command is fully a
/// filesystem compound, else .passthrough. All other modes -> .passthrough.
pub fn checkMode(mode: Mode, command: []const u8) Decision {
    return switch (mode) {
        .bypassPermissions, .dontAsk => .passthrough,
        .acceptEdits => if (acceptEditsAutoAllows(command)) .allow else .passthrough,
        .default, .plan => .passthrough,
    };
}

const testing = std.testing;

test "acceptEdits auto-allows filesystem commands" {
    // Single filesystem commands.
    try testing.expect(acceptEditsAutoAllows("mkdir foo"));
    try testing.expect(acceptEditsAutoAllows("rm -rf build"));
    try testing.expect(acceptEditsAutoAllows("touch a b"));
    try testing.expect(acceptEditsAutoAllows("mv a b"));
    try testing.expect(acceptEditsAutoAllows("cp -r a b"));
    try testing.expect(acceptEditsAutoAllows("sed -i s/x/y/ f"));
    // All-filesystem compound.
    try testing.expect(acceptEditsAutoAllows("mkdir a && rm b"));

    // Non-filesystem and mixed compounds, plus empty -> not auto-allowed.
    try testing.expect(!acceptEditsAutoAllows("python x.py"));
    try testing.expect(!acceptEditsAutoAllows("mkdir a && curl evil"));
    try testing.expect(!acceptEditsAutoAllows("git status"));
    try testing.expect(!acceptEditsAutoAllows("echo hi"));
    try testing.expect(!acceptEditsAutoAllows("npm test"));
    try testing.expect(!acceptEditsAutoAllows(""));
}

test "checkMode passthrough for bypass/dontAsk and non-edit base" {
    // bypassPermissions / dontAsk always passthrough (handled in main flow),
    // even for a filesystem command.
    try testing.expectEqual(Decision.passthrough, checkMode(.bypassPermissions, "mkdir foo"));
    try testing.expectEqual(Decision.passthrough, checkMode(.dontAsk, "mkdir foo"));

    // acceptEdits: filesystem command allows, non-filesystem passes through.
    try testing.expectEqual(Decision.allow, checkMode(.acceptEdits, "mkdir foo"));
    try testing.expectEqual(Decision.passthrough, checkMode(.acceptEdits, "python x.py"));

    // default / plan never auto-allow here.
    try testing.expectEqual(Decision.passthrough, checkMode(.default, "mkdir foo"));
    try testing.expectEqual(Decision.passthrough, checkMode(.plan, "mkdir foo"));
}

test "compound splitting handles all operators and overflow" {
    // ;, |, ||, && all separate.
    try testing.expect(acceptEditsAutoAllows("mkdir a ; rm b"));
    try testing.expect(acceptEditsAutoAllows("mkdir a | rm b"));
    try testing.expect(acceptEditsAutoAllows("mkdir a || rm b"));
    try testing.expect(acceptEditsAutoAllows("mkdir a && rm b ; touch c"));

    // A mixed compound with a pipe to a non-filesystem command -> passthrough.
    try testing.expect(!acceptEditsAutoAllows("mkdir a | grep x"));

    // An empty subcommand (trailing operator) -> not auto-allowed.
    try testing.expect(!acceptEditsAutoAllows("mkdir a &&"));
    try testing.expect(!acceptEditsAutoAllows("mkdir a ; ; rm b"));
}

test "case-insensitive base command match" {
    try testing.expect(acceptEditsAutoAllows("MKDIR foo"));
    try testing.expect(acceptEditsAutoAllows("Rm -rf build"));
}
