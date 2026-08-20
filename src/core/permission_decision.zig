//! P2 (PRD #534) permission decision. Combines the rule-engine result with the
//! active permission mode, the tool's risk tier, whether the call is an edit,
//! and session "always-allow" memory into a final allow/deny/ask outcome -
//! mirroring Claude Code's mode semantics.
//!
//! Pure module: inputs in, an Outcome out. No allocation, no IO.

const std = @import("std");
const types = @import("types.zig");
const rule = @import("permission_rules.zig");

/// Claude Code permission modes.
pub const Mode = enum {
    default,
    acceptEdits,
    plan,
    bypassPermissions,
    dontAsk,
};

pub const Outcome = enum { allow, deny, ask };

/// Map a permission-mode string (config / CLI) to a Mode. Accepts the reference
/// spellings and zcode's legacy mode names. Unknown -> default.
pub fn modeFromString(s: []const u8) Mode {
    if (std.ascii.eqlIgnoreCase(s, "acceptEdits") or std.ascii.eqlIgnoreCase(s, "accept-edits")) return .acceptEdits;
    if (std.ascii.eqlIgnoreCase(s, "plan")) return .plan;
    if (std.ascii.eqlIgnoreCase(s, "bypassPermissions") or std.ascii.eqlIgnoreCase(s, "bypass")) return .bypassPermissions;
    if (std.ascii.eqlIgnoreCase(s, "dontAsk") or std.ascii.eqlIgnoreCase(s, "dont-ask")) return .dontAsk;
    return .default;
}

/// Map a Mode back to its canonical reference spelling. Round-trips through
/// modeFromString and (for the four non-default modes) satisfies
/// isReferenceModeName. The "default" spelling maps back to .default but is NOT
/// a reference mode name, matching isReferenceModeName's deliberate exclusion.
pub fn modeToString(mode: Mode) []const u8 {
    return switch (mode) {
        .default => "default",
        .acceptEdits => "acceptEdits",
        .plan => "plan",
        .bypassPermissions => "bypassPermissions",
        .dontAsk => "dontAsk",
    };
}

/// True only for the four Claude Code reference mode names (and their hyphen
/// variants). Deliberately excludes "default" and zcode's legacy modes
/// (strict/manual/tiered-auto) so callers can dispatch reference modes without
/// hijacking existing behavior.
pub fn isReferenceModeName(s: []const u8) bool {
    return std.ascii.eqlIgnoreCase(s, "acceptEdits") or
        std.ascii.eqlIgnoreCase(s, "accept-edits") or
        std.ascii.eqlIgnoreCase(s, "plan") or
        std.ascii.eqlIgnoreCase(s, "bypassPermissions") or
        std.ascii.eqlIgnoreCase(s, "bypass") or
        std.ascii.eqlIgnoreCase(s, "dontAsk") or
        std.ascii.eqlIgnoreCase(s, "dont-ask");
}

fn tierDefault(tier: types.RiskTier) Outcome {
    return switch (tier) {
        .LOW => .allow,
        .MEDIUM, .HIGH => .ask,
        .BLOCKED => .deny,
    };
}

/// Decide the outcome. Precedence: BLOCKED tier and explicit deny rules always
/// deny; bypass allows everything else; dontAsk never asks (allow on rule/session
/// allow, else deny); otherwise allow-rule/session win, ask-rule asks, and the
/// mode + tier provide the default.
pub fn decide(
    mode: Mode,
    rule_result: ?rule.Action,
    tier: types.RiskTier,
    is_edit: bool,
    session_allowed: bool,
) Outcome {
    if (tier == .BLOCKED) return .deny;
    if (rule_result == .deny) return .deny;

    switch (mode) {
        .bypassPermissions => return .allow,
        .dontAsk => {
            // Like default, but never prompts: a tier that would ask is denied.
            if (rule_result == .allow or session_allowed) return .allow;
            const base = tierDefault(tier);
            return if (base == .ask) .deny else base;
        },
        else => {},
    }

    if (rule_result == .allow or session_allowed) return .allow;
    if (rule_result == .ask) return .ask;

    return switch (mode) {
        .acceptEdits => if (is_edit) .allow else tierDefault(tier),
        .plan => if (tier == .LOW) .allow else .deny,
        .default => tierDefault(tier),
        .bypassPermissions, .dontAsk => unreachable,
    };
}

const testing = std.testing;

test "isReferenceModeName excludes default and legacy modes" {
    try testing.expect(isReferenceModeName("acceptEdits"));
    try testing.expect(isReferenceModeName("plan"));
    try testing.expect(isReferenceModeName("bypassPermissions"));
    try testing.expect(isReferenceModeName("dontAsk"));
    try testing.expect(!isReferenceModeName("default"));
    try testing.expect(!isReferenceModeName("tiered-auto"));
    try testing.expect(!isReferenceModeName("manual"));
    try testing.expect(!isReferenceModeName("strict"));
}

test "modeToString round-trips through modeFromString" {
    const all = [_]Mode{ .default, .acceptEdits, .plan, .bypassPermissions, .dontAsk };
    for (all) |m| {
        try testing.expectEqual(m, modeFromString(modeToString(m)));
    }
    // The four reference modes round-trip through isReferenceModeName.
    try testing.expect(isReferenceModeName(modeToString(.acceptEdits)));
    try testing.expect(isReferenceModeName(modeToString(.plan)));
    try testing.expect(isReferenceModeName(modeToString(.bypassPermissions)));
    try testing.expect(isReferenceModeName(modeToString(.dontAsk)));
    // "default" is intentionally NOT a reference mode name, but still maps back.
    try testing.expect(!isReferenceModeName(modeToString(.default)));
    try testing.expectEqual(Mode.default, modeFromString(modeToString(.default)));
}

test "modeFromString accepts reference and legacy spellings" {
    try testing.expectEqual(Mode.acceptEdits, modeFromString("acceptEdits"));
    try testing.expectEqual(Mode.acceptEdits, modeFromString("accept-edits"));
    try testing.expectEqual(Mode.bypassPermissions, modeFromString("bypass"));
    try testing.expectEqual(Mode.dontAsk, modeFromString("dontAsk"));
    try testing.expectEqual(Mode.plan, modeFromString("plan"));
    try testing.expectEqual(Mode.default, modeFromString("whatever"));
}

test "BLOCKED tier always denies regardless of mode or rules" {
    try testing.expectEqual(Outcome.deny, decide(.bypassPermissions, .allow, .BLOCKED, false, true));
}

test "deny rule wins over everything except is overridden by nothing" {
    try testing.expectEqual(Outcome.deny, decide(.bypassPermissions, .deny, .LOW, false, true));
    try testing.expectEqual(Outcome.deny, decide(.default, .deny, .LOW, true, true));
}

test "bypass allows non-blocked, non-denied calls" {
    try testing.expectEqual(Outcome.allow, decide(.bypassPermissions, null, .HIGH, false, false));
}

test "dontAsk never asks: low auto-allows, prompting tiers deny" {
    try testing.expectEqual(Outcome.allow, decide(.dontAsk, .allow, .HIGH, false, false));
    try testing.expectEqual(Outcome.allow, decide(.dontAsk, null, .LOW, false, true));
    try testing.expectEqual(Outcome.allow, decide(.dontAsk, null, .LOW, false, false));
    try testing.expectEqual(Outcome.deny, decide(.dontAsk, null, .MEDIUM, false, false));
    try testing.expectEqual(Outcome.deny, decide(.dontAsk, null, .HIGH, false, false));
}

test "allow rule and session memory short-circuit to allow" {
    try testing.expectEqual(Outcome.allow, decide(.default, .allow, .HIGH, false, false));
    try testing.expectEqual(Outcome.allow, decide(.default, null, .HIGH, false, true));
}

test "ask rule asks when no allow/deny" {
    try testing.expectEqual(Outcome.ask, decide(.default, .ask, .LOW, false, false));
}

test "acceptEdits allows edits, defers non-edits to tier" {
    try testing.expectEqual(Outcome.allow, decide(.acceptEdits, null, .MEDIUM, true, false));
    try testing.expectEqual(Outcome.ask, decide(.acceptEdits, null, .HIGH, false, false));
    try testing.expectEqual(Outcome.allow, decide(.acceptEdits, null, .LOW, false, false));
}

test "plan mode allows only read-only (LOW) tiers" {
    try testing.expectEqual(Outcome.allow, decide(.plan, null, .LOW, false, false));
    try testing.expectEqual(Outcome.deny, decide(.plan, null, .MEDIUM, false, false));
    try testing.expectEqual(Outcome.deny, decide(.plan, null, .HIGH, true, false));
}

test "default mode tier mapping" {
    try testing.expectEqual(Outcome.allow, decide(.default, null, .LOW, false, false));
    try testing.expectEqual(Outcome.ask, decide(.default, null, .MEDIUM, false, false));
    try testing.expectEqual(Outcome.ask, decide(.default, null, .HIGH, false, false));
}
