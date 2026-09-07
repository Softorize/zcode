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
///
/// `auto` (hooks-permissions-05) is the reference's sixth mode: "Use a model
/// classifier to approve/deny permission prompts." zcode has no cloud
/// classifier, so `auto` is a documented approximation -- `decide()` treats it
/// identically to `.default` (ask-on-tier). `classifyAllShell` is the
/// reference's companion knob for routing every Bash call through the
/// classifier regardless of tier; zcode exposes it nowhere (no classifier to
/// route to), so it is intentionally not modeled here.
pub const Mode = enum {
    default,
    acceptEdits,
    plan,
    bypassPermissions,
    dontAsk,
    auto,
};

pub const Outcome = enum { allow, deny, ask };

/// Map a permission-mode string (config / CLI) to a Mode. Accepts the reference
/// spellings and zcode's legacy mode names. `"manual"` is a deliberate,
/// permanent reference alias for `"default"` (reference: `WU="manual";
/// function mf(e){return e==="manual"?"default":e}`) -- not incidental
/// catch-all fallthrough, so a future refactor of the catch-all must keep this
/// mapping (hooks-permissions-13). Unknown -> default.
pub fn modeFromString(s: []const u8) Mode {
    if (std.ascii.eqlIgnoreCase(s, "acceptEdits") or std.ascii.eqlIgnoreCase(s, "accept-edits")) return .acceptEdits;
    if (std.ascii.eqlIgnoreCase(s, "plan")) return .plan;
    if (std.ascii.eqlIgnoreCase(s, "bypassPermissions") or std.ascii.eqlIgnoreCase(s, "bypass")) return .bypassPermissions;
    if (std.ascii.eqlIgnoreCase(s, "dontAsk") or std.ascii.eqlIgnoreCase(s, "dont-ask")) return .dontAsk;
    if (std.ascii.eqlIgnoreCase(s, "auto")) return .auto;
    // "manual" is the reference's documented alias for "default", handled by
    // the catch-all below like any other unrecognized string -- see the
    // isReferenceModeName test asserting it is NOT a reference name in its
    // own right.
    return .default;
}

/// Map a Mode back to its canonical reference spelling. Round-trips through
/// modeFromString and (for the five non-default modes) satisfies
/// isReferenceModeName. The "default" spelling maps back to .default but is NOT
/// a reference mode name, matching isReferenceModeName's deliberate exclusion.
pub fn modeToString(mode: Mode) []const u8 {
    return switch (mode) {
        .default => "default",
        .acceptEdits => "acceptEdits",
        .plan => "plan",
        .bypassPermissions => "bypassPermissions",
        .dontAsk => "dontAsk",
        .auto => "auto",
    };
}

/// True only for the five Claude Code reference mode names (and their hyphen
/// variants). Deliberately excludes "default", the "manual" alias, and zcode's
/// legacy modes (strict/tiered-auto) so callers can dispatch reference modes
/// without hijacking existing behavior.
pub fn isReferenceModeName(s: []const u8) bool {
    return std.ascii.eqlIgnoreCase(s, "acceptEdits") or
        std.ascii.eqlIgnoreCase(s, "accept-edits") or
        std.ascii.eqlIgnoreCase(s, "plan") or
        std.ascii.eqlIgnoreCase(s, "bypassPermissions") or
        std.ascii.eqlIgnoreCase(s, "bypass") or
        std.ascii.eqlIgnoreCase(s, "dontAsk") or
        std.ascii.eqlIgnoreCase(s, "dont-ask") or
        std.ascii.eqlIgnoreCase(s, "auto");
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
        // `auto` has no classifier in zcode (see the Mode doc comment), so it
        // is a documented approximation of `.default`'s ask-on-tier behavior
        // rather than actually classifying anything.
        .default, .auto => tierDefault(tier),
        .bypassPermissions, .dontAsk => unreachable,
    };
}

const testing = std.testing;

test "isReferenceModeName excludes default and legacy modes" {
    try testing.expect(isReferenceModeName("acceptEdits"));
    try testing.expect(isReferenceModeName("plan"));
    try testing.expect(isReferenceModeName("bypassPermissions"));
    try testing.expect(isReferenceModeName("dontAsk"));
    try testing.expect(isReferenceModeName("auto"));
    try testing.expect(!isReferenceModeName("default"));
    try testing.expect(!isReferenceModeName("tiered-auto"));
    try testing.expect(!isReferenceModeName("manual"));
    try testing.expect(!isReferenceModeName("strict"));
}

test "modeToString round-trips through modeFromString" {
    const all = [_]Mode{ .default, .acceptEdits, .plan, .bypassPermissions, .dontAsk, .auto };
    for (all) |m| {
        try testing.expectEqual(m, modeFromString(modeToString(m)));
    }
    // The five reference modes round-trip through isReferenceModeName.
    try testing.expect(isReferenceModeName(modeToString(.acceptEdits)));
    try testing.expect(isReferenceModeName(modeToString(.plan)));
    try testing.expect(isReferenceModeName(modeToString(.bypassPermissions)));
    try testing.expect(isReferenceModeName(modeToString(.dontAsk)));
    try testing.expect(isReferenceModeName(modeToString(.auto)));
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
    try testing.expectEqual(Mode.auto, modeFromString("auto"));
    try testing.expectEqual(Mode.default, modeFromString("whatever"));
}

test "hooks-permissions-05: auto round-trips and settings.json defaultMode:auto is not silently dropped to default" {
    try testing.expectEqual(Mode.auto, modeFromString("auto"));
    try testing.expect(isReferenceModeName("auto"));
    try testing.expectEqualStrings("auto", modeToString(.auto));
    // `auto` behaves as a documented approximation of `.default` (ask-on-tier)
    // since zcode has no classifier -- but it is NOT silently collapsed to
    // .default at the string layer, so a config round-trip preserves it.
    try testing.expectEqual(Outcome.allow, decide(.auto, null, .LOW, false, false));
    try testing.expectEqual(Outcome.ask, decide(.auto, null, .MEDIUM, false, false));
}

test "hooks-permissions-13: manual is a permanent alias for default, not incidental catch-all" {
    // Reference: WU="manual"; function mf(e){return e==="manual"?"default":e}
    try testing.expectEqual(Mode.default, modeFromString("manual"));
    try testing.expect(!isReferenceModeName("manual"));
    // A genuinely unknown string lands in the same bucket (the catch-all is
    // shared), but "manual" specifically is a documented, permanent alias --
    // this test pins that behavior so a future refactor cannot regress it.
    try testing.expectEqual(Mode.default, modeFromString("totally-unknown-mode"));
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
