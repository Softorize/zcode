//! P3 (PRD #534) pure permission-mode cycle. Mirrors Claude Code's
//! getNextPermissionMode.ts: Shift+Tab advances default -> acceptEdits -> plan
//! -> default for normal users, with plan -> bypassPermissions only when bypass
//! is available. dontAsk and anything unexpected fall back to default.
//!
//! Pure module: inputs in, a Mode out. No allocation, no IO. Reuses the
//! canonical Mode enum from permission_decision.zig so decide() and the cycle
//! stay in lockstep.

const std = @import("std");
const permission_decision = @import("permission_decision.zig");

pub const Mode = permission_decision.Mode;

/// Return the next permission mode for a Shift+Tab cycle.
///
/// Reference (getNextPermissionMode.ts:34-79):
///   default            -> acceptEdits
///   acceptEdits        -> plan
///   plan               -> bypassPermissions (only if bypass_available) else default
///   bypassPermissions  -> default
///   dontAsk            -> default
///
/// The reference's `canCycleToAuto` / `TRANSCRIPT_CLASSIFIER` gate (which lets
/// Shift+Tab land on `auto` in specific ant-internal configurations) is out of
/// scope for zcode: `auto` is reachable via settings.json `defaultMode`/CLI
/// (hooks-permissions-05) but not via the normal cycle, so it falls back to
/// `default` like `dontAsk` does.
pub fn getNext(current: Mode, bypass_available: bool) Mode {
    return switch (current) {
        .default => .acceptEdits,
        .acceptEdits => .plan,
        .plan => if (bypass_available) .bypassPermissions else .default,
        .bypassPermissions => .default,
        .dontAsk => .default,
        .auto => .default,
    };
}

/// Full mode title (PermissionMode.ts:42-91). Used by the cycle banner.
pub fn label(mode: Mode) []const u8 {
    return switch (mode) {
        .default => "Default",
        .acceptEdits => "Accept edits",
        .plan => "Plan Mode",
        .bypassPermissions => "Bypass Permissions",
        .dontAsk => "Don't Ask",
        .auto => "Auto",
    };
}

/// Short mode title (PermissionMode.ts:42-91). Used by the compact hint banner.
pub fn shortLabel(mode: Mode) []const u8 {
    return switch (mode) {
        .default => "Default",
        .acceptEdits => "Accept",
        .plan => "Plan",
        .bypassPermissions => "Bypass",
        .dontAsk => "DontAsk",
        .auto => "Auto",
    };
}

const testing = std.testing;

test "getNext follows reference cycle order" {
    try testing.expectEqual(Mode.acceptEdits, getNext(.default, false));
    try testing.expectEqual(Mode.plan, getNext(.acceptEdits, false));
    try testing.expectEqual(Mode.default, getNext(.plan, false));
    try testing.expectEqual(Mode.bypassPermissions, getNext(.plan, true));
    try testing.expectEqual(Mode.default, getNext(.bypassPermissions, false));
    try testing.expectEqual(Mode.default, getNext(.bypassPermissions, true));
    try testing.expectEqual(Mode.default, getNext(.dontAsk, false));
}

test "label and shortLabel match reference titles" {
    try testing.expectEqualStrings("Default", label(.default));
    try testing.expectEqualStrings("Accept edits", label(.acceptEdits));
    try testing.expectEqualStrings("Plan Mode", label(.plan));
    try testing.expectEqualStrings("Bypass Permissions", label(.bypassPermissions));
    try testing.expectEqualStrings("Don't Ask", label(.dontAsk));

    try testing.expectEqualStrings("Default", shortLabel(.default));
    try testing.expectEqualStrings("Accept", shortLabel(.acceptEdits));
    try testing.expectEqualStrings("Plan", shortLabel(.plan));
    try testing.expectEqualStrings("Bypass", shortLabel(.bypassPermissions));
    try testing.expectEqualStrings("DontAsk", shortLabel(.dontAsk));
    try testing.expectEqualStrings("Auto", shortLabel(.auto));
}

test "hooks-permissions-05: auto is a stable label and falls back to default on cycle" {
    try testing.expectEqualStrings("Auto", label(.auto));
    // auto is not part of the normal Shift+Tab cycle (no ant-internal
    // classifier gate in zcode); it degrades to default like dontAsk.
    try testing.expectEqual(Mode.default, getNext(.auto, false));
    try testing.expectEqual(Mode.default, getNext(.auto, true));
}
