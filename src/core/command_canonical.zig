//! P1 (PRD #534) identifier reconciliation: map zcode slash-command spellings
//! to the reference-exact user-facing command names (claude-code-main
//! src/commands/* directory names). Lets users coming from Claude Code type the
//! reference spelling and have it resolve to whatever form zcode's dispatcher
//! already matches, and lets help/listing advertise the reference name.
//!
//! Pure module: a command token in, a command token out. No allocation, no IO.
//! Operates on the leading command word only (callers split off arguments).

const std = @import("std");

const Pair = struct { spelling: []const u8, canonical: []const u8 };

/// zcode spelling -> reference-exact command name. Both directions of the
/// reconciliation live here so `toCanonical` (advertise/normalize to reference)
/// is the single source of truth. Commands without a reference counterpart are
/// returned unchanged.
const map = [_]Pair{
    .{ .spelling = "/ctx-viz", .canonical = "/ctx_viz" },
    .{ .spelling = "/ctxviz", .canonical = "/ctx_viz" },
    .{ .spelling = "/style", .canonical = "/output-style" },
    .{ .spelling = "/styles", .canonical = "/output-style" },
    .{ .spelling = "/reload_plugins", .canonical = "/reload-plugins" },
    .{ .spelling = "/reload", .canonical = "/reload-plugins" },
    .{ .spelling = "/autofix_pr", .canonical = "/autofix-pr" },
    .{ .spelling = "/terminal-setup", .canonical = "/terminalSetup" },
    .{ .spelling = "/terminal_setup", .canonical = "/terminalSetup" },
    .{ .spelling = "/terminalsetup", .canonical = "/terminalSetup" },
    .{ .spelling = "/pr-comments", .canonical = "/pr_comments" },
    .{ .spelling = "/releasenotes", .canonical = "/release-notes" },
};

/// Reference-only spellings that zcode's dispatcher does NOT already have an arm
/// for, mapped to an existing accepted form. Keeps the dispatcher untouched
/// while letting Claude Code users type the reference name. (All other
/// reference spellings already have a matching dispatch arm.)
const dispatch_fallback = [_]Pair{
    .{ .spelling = "/output-style", .canonical = "/style" },
    .{ .spelling = "/terminalSetup", .canonical = "/terminal-setup" },
    // commands-sweep-02: reference `/branch` carries alias `['fork']`. zcode's
    // dispatcher matches `/branch`, so resolve the reference `/fork` spelling to it.
    .{ .spelling = "/fork", .canonical = "/branch" },
    // commands-sweep-04: reference `/resume` carries alias `['continue']`. zcode's
    // dispatcher matches `/resume`, so resolve the reference `/continue` spelling
    // to it (handles `/continue <id>` and `/continue list`; the bare-`/continue`
    // interactive-selector path is wired separately at the REPL line level).
    .{ .spelling = "/continue", .canonical = "/resume" },
};

/// Return the reference-exact command name for `cmd` (leading word, incl. the
/// leading '/'). Case-insensitive on the ASCII letters. Unknown commands pass
/// through unchanged. Used for help/listing so we advertise the reference name.
pub fn toCanonical(cmd: []const u8) []const u8 {
    for (map) |p| {
        if (std.ascii.eqlIgnoreCase(cmd, p.spelling)) return p.canonical;
    }
    return cmd;
}

/// Return a spelling the existing dispatcher matches for `cmd`. Only rewrites
/// reference-only spellings that lack a dispatch arm; everything else (including
/// zcode's own spellings) passes through unchanged. Used by the REPL callback so
/// typing the reference name resolves without editing every dispatch arm.
pub fn toDispatch(cmd: []const u8) []const u8 {
    for (dispatch_fallback) |p| {
        if (std.ascii.eqlIgnoreCase(cmd, p.spelling)) return p.canonical;
    }
    return cmd;
}

const testing = std.testing;

test "hyphen/underscore/spelling variants reconcile to the reference name" {
    try testing.expectEqualStrings("/ctx_viz", toCanonical("/ctx-viz"));
    try testing.expectEqualStrings("/ctx_viz", toCanonical("/ctxviz"));
    try testing.expectEqualStrings("/output-style", toCanonical("/style"));
    try testing.expectEqualStrings("/output-style", toCanonical("/styles"));
    try testing.expectEqualStrings("/reload-plugins", toCanonical("/reload_plugins"));
    try testing.expectEqualStrings("/autofix-pr", toCanonical("/autofix_pr"));
    try testing.expectEqualStrings("/terminalSetup", toCanonical("/terminal-setup"));
    try testing.expectEqualStrings("/pr_comments", toCanonical("/pr-comments"));
    try testing.expectEqualStrings("/release-notes", toCanonical("/releasenotes"));
}

test "case-insensitive match" {
    try testing.expectEqualStrings("/ctx_viz", toCanonical("/CTX-VIZ"));
}

test "already-canonical and unknown commands pass through" {
    try testing.expectEqualStrings("/ctx_viz", toCanonical("/ctx_viz"));
    try testing.expectEqualStrings("/model", toCanonical("/model"));
    try testing.expectEqualStrings("/commit", toCanonical("/commit"));
}

test "toDispatch resolves reference-only spellings to an accepted form" {
    try testing.expectEqualStrings("/style", toDispatch("/output-style"));
    try testing.expectEqualStrings("/terminal-setup", toDispatch("/terminalSetup"));
}

test "toDispatch leaves already-accepted spellings unchanged" {
    try testing.expectEqualStrings("/style", toDispatch("/style"));
    try testing.expectEqualStrings("/ctx_viz", toDispatch("/ctx_viz"));
    try testing.expectEqualStrings("/model", toDispatch("/model"));
}

test "toDispatch resolves the reference /fork alias to /branch" {
    try testing.expectEqualStrings("/branch", toDispatch("/fork"));
    try testing.expectEqualStrings("/branch", toDispatch("/FORK"));
    // /branch itself is the accepted form and passes through unchanged.
    try testing.expectEqualStrings("/branch", toDispatch("/branch"));
}

test "toDispatch resolves the reference /continue alias to /resume" {
    try testing.expectEqualStrings("/resume", toDispatch("/continue"));
    try testing.expectEqualStrings("/resume", toDispatch("/CONTINUE"));
    // /resume itself is the accepted form and passes through unchanged.
    try testing.expectEqualStrings("/resume", toDispatch("/resume"));
}
