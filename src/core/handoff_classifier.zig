//! swarm-tasks-16: handoff safety classifier on sub-agent completion.
//!
//! When a sub-agent finishes and hands control back to the parent, the
//! reference (agentToolUtils.ts:389-481 classifyHandoffIfNeeded) optionally
//! runs a "transcript classifier" over the sub-agent's work and, if the
//! verdict flags a security risk, prepends a SECURITY WARNING to the
//! sub-agent's output so the parent agent reviews it before acting.
//!
//! This module is the PURE decision + rendering core. It answers two
//! questions and nothing else:
//!   1. shouldClassify(gate) -- given the feature gate (env flag) and the
//!      current permission mode, do we even run the classifier?
//!   2. renderWarning(verdict, reason, allocator) -- given a classifier
//!      verdict, what (if any) warning string do we prepend?
//!
//! The actual classification (an LLM / hook call) lives in the caller
//! (agent_runtime.spawnChildAgent). Keeping the decision + rendering here
//! makes the policy fully unit-testable and default-off: an unset gate
//! returns null and the sub-agent output is returned verbatim, so the
//! common path never regresses.
//!
//! Reference parity notes:
//!   - The gate mirrors `feature('TRANSCRIPT_CLASSIFIER')` AND
//!     `toolPermissionContext.mode === 'auto'` (agentToolUtils.ts:404-405).
//!     Both must hold or we skip classification entirely.
//!   - The warning text mirrors the two reference strings verbatim
//!     (agentToolUtils.ts:471, :476), minus any long dashes.
//!   - Prepend format is `${warning}\n\n${output}` (agentToolUtils.ts:618).

const std = @import("std");
const env_mod = @import("env.zig");

/// The env flag that turns the handoff classifier on. Mirrors the
/// reference `feature('TRANSCRIPT_CLASSIFIER')` flag. Default-off: the
/// classifier only runs when this is explicitly truthy.
pub const TRANSCRIPT_CLASSIFIER_ENV = "ZCODE_TRANSCRIPT_CLASSIFIER";

/// Inputs the gate needs to decide whether to classify a handoff.
/// `mode` is the current permission mode name as a string (e.g. "auto",
/// "default", "plan"); the reference only classifies when it is "auto".
pub const Gate = struct {
    /// True when the TRANSCRIPT_CLASSIFIER feature is enabled. Callers
    /// typically pass `isFeatureEnabled()`.
    feature_enabled: bool,
    /// The current permission mode name. Classification only runs when this
    /// is "auto" (case-insensitive), matching the reference.
    permission_mode: []const u8,
};

/// The classifier's verdict for a finished sub-agent's work. The verdict
/// itself is produced by the caller (LLM / hook); this enum is the contract
/// the rendering uses.
pub const Verdict = enum {
    /// Classifier ran and found nothing dangerous. No warning.
    allowed,
    /// Classifier ran and flagged a security risk. Render a SECURITY WARNING
    /// (with the supplied reason).
    blocked,
    /// Classifier could not run (model/hook unavailable). Render a softer
    /// "please verify" note so the parent still scrutinizes the output.
    unavailable,
};

/// Read the feature gate from the process environment. Centralized so the
/// env-var spelling lives in exactly one place.
pub fn isFeatureEnabled() bool {
    return env_mod.isEnvTruthy(TRANSCRIPT_CLASSIFIER_ENV);
}

/// Decide whether to run the handoff classifier at all.
///
/// Reference (agentToolUtils.ts:404-405): classify only when the feature is
/// on AND the tool-permission mode is "auto". Anything else returns false and
/// the sub-agent output is handed back verbatim.
pub fn shouldClassify(gate: Gate) bool {
    if (!gate.feature_enabled) return false;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, gate.permission_mode, " \t\r\n"), "auto");
}

/// Render the warning string for a classifier verdict, or null when no
/// warning is needed (the `allowed` verdict, or when `shouldClassify` would
/// have returned false -- callers gate before calling this, but a defensive
/// `allowed` here keeps the contract total).
///
/// Caller owns the returned slice (when non-null) and must free it.
///
/// Reference strings (agentToolUtils.ts):
///   - blocked     -> ":476" SECURITY WARNING ... Reason: <reason>. Review ...
///   - unavailable -> ":471" Note: the safety classifier was unavailable ...
pub fn renderWarning(allocator: std.mem.Allocator, verdict: Verdict, reason: []const u8) !?[]u8 {
    return switch (verdict) {
        .allowed => null,
        .unavailable => try allocator.dupe(
            u8,
            "Note: The safety classifier was unavailable when reviewing this sub-agent's work. Please carefully verify the sub-agent's actions and output before acting on them.",
        ),
        .blocked => blk: {
            const trimmed = std.mem.trim(u8, reason, " \t\r\n");
            const reason_text = if (trimmed.len == 0) "unspecified" else trimmed;
            break :blk try std.fmt.allocPrint(
                allocator,
                "SECURITY WARNING: This sub-agent performed actions that may violate security policy. Reason: {s}. Review the sub-agent's actions carefully before acting on its output.",
                .{reason_text},
            );
        },
    };
}

/// Prepend a (non-null) warning to a sub-agent's output, mirroring the
/// reference `${warning}\n\n${output}` join (agentToolUtils.ts:618).
///
/// Returns a freshly allocated combined string; caller owns it. `warning`
/// and `output` are copied, so the caller may free them afterwards.
pub fn prependWarning(allocator: std.mem.Allocator, warning: []const u8, output: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ warning, output });
}

const testing = std.testing;

test "shouldClassify: gate off returns false regardless of mode" {
    try testing.expect(!shouldClassify(.{ .feature_enabled = false, .permission_mode = "auto" }));
    try testing.expect(!shouldClassify(.{ .feature_enabled = false, .permission_mode = "default" }));
}

test "shouldClassify: gate on but non-auto mode returns false" {
    try testing.expect(!shouldClassify(.{ .feature_enabled = true, .permission_mode = "default" }));
    try testing.expect(!shouldClassify(.{ .feature_enabled = true, .permission_mode = "plan" }));
    try testing.expect(!shouldClassify(.{ .feature_enabled = true, .permission_mode = "acceptEdits" }));
}

test "shouldClassify: gate on and auto mode returns true (case/whitespace insensitive)" {
    try testing.expect(shouldClassify(.{ .feature_enabled = true, .permission_mode = "auto" }));
    try testing.expect(shouldClassify(.{ .feature_enabled = true, .permission_mode = "AUTO" }));
    try testing.expect(shouldClassify(.{ .feature_enabled = true, .permission_mode = "  auto  " }));
}

test "renderWarning: allowed verdict yields no warning" {
    const w = try renderWarning(testing.allocator, .allowed, "");
    try testing.expect(w == null);
}

test "renderWarning: blocked verdict prefixes SECURITY WARNING with reason" {
    const w = (try renderWarning(testing.allocator, .blocked, "wrote to /etc/passwd")).?;
    defer testing.allocator.free(w);
    try testing.expect(std.mem.startsWith(u8, w, "SECURITY WARNING:"));
    try testing.expect(std.mem.indexOf(u8, w, "wrote to /etc/passwd") != null);
}

test "renderWarning: blocked verdict with empty reason falls back to unspecified" {
    const w = (try renderWarning(testing.allocator, .blocked, "   ")).?;
    defer testing.allocator.free(w);
    try testing.expect(std.mem.indexOf(u8, w, "Reason: unspecified") != null);
}

test "renderWarning: unavailable verdict yields the soft verify note" {
    const w = (try renderWarning(testing.allocator, .unavailable, "ignored")).?;
    defer testing.allocator.free(w);
    try testing.expect(std.mem.startsWith(u8, w, "Note: The safety classifier was unavailable"));
}

test "prependWarning joins warning and output with a blank line" {
    const combined = try prependWarning(testing.allocator, "SECURITY WARNING: x", "the original output");
    defer testing.allocator.free(combined);
    try testing.expectEqualStrings("SECURITY WARNING: x\n\nthe original output", combined);
}

// End-to-end of the pure policy: gate-off path returns output unchanged
// (caller would never even build a warning), gate-on flagged path produces a
// prefixed string, gate-on clean path leaves output unchanged. This mirrors
// the three acceptance-criteria cases at the policy level.

test "end-to-end policy: gate off -> output unchanged" {
    const output = "sub-agent result";
    const gate = Gate{ .feature_enabled = false, .permission_mode = "auto" };
    if (shouldClassify(gate)) {
        // Not reached.
        const w = try renderWarning(testing.allocator, .blocked, "x");
        if (w) |ww| testing.allocator.free(ww);
        try testing.expect(false);
    }
    // Output is returned verbatim by the caller.
    try testing.expectEqualStrings("sub-agent result", output);
}

test "end-to-end policy: gate on + flagged -> prefixed output" {
    const output = "sub-agent result";
    const gate = Gate{ .feature_enabled = true, .permission_mode = "auto" };
    try testing.expect(shouldClassify(gate));
    const w = (try renderWarning(testing.allocator, .blocked, "deleted a key file")).?;
    defer testing.allocator.free(w);
    const combined = try prependWarning(testing.allocator, w, output);
    defer testing.allocator.free(combined);
    try testing.expect(std.mem.startsWith(u8, combined, "SECURITY WARNING:"));
    try testing.expect(std.mem.endsWith(u8, combined, "sub-agent result"));
}

test "end-to-end policy: gate on + clean -> output unchanged" {
    const output = "sub-agent result";
    const gate = Gate{ .feature_enabled = true, .permission_mode = "auto" };
    try testing.expect(shouldClassify(gate));
    const w = try renderWarning(testing.allocator, .allowed, "");
    try testing.expect(w == null);
    // No warning: caller returns output verbatim.
    try testing.expectEqualStrings("sub-agent result", output);
}
