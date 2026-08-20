//! Reasoning-effort level resolution + persistence helpers (commands-sweep-08).
//!
//! Ports the precedence and messaging that claude-code-main/src/utils/effort.ts
//! and src/commands/effort/effort.tsx implement around `effortLevel`:
//!
//!   - getEffortEnvOverride()  reads CLAUDE_CODE_EFFORT_LEVEL; "unset"/"auto"
//!                             means "force no override" (env clears any
//!                             persisted level), a valid level overrides, and
//!                             an unset/invalid env var means "no env opinion".
//!   - resolveAppliedEffort()  env override -> persisted setting -> default,
//!                             with env winning over everything.
//!   - toPersistableEffort()   which levels are written to userSettings vs
//!                             session-only ("auto" is session-only: selecting
//!                             it clears the persisted setting).
//!
//! This module is the pure decision/text layer so the precedence and the
//! "(this session only)" / env-conflict messaging can be unit-tested without a
//! live runtime. The side effects (mutating runtime.reasoning_effort, writing
//! the user config) live in repl_commands.zig and config_parse.zig.
//!
//! zcode has no "ant" subscriber concept, so `max` is treated as a persistable
//! level like low/medium/high (the reference makes `max` session-only for
//! non-ant users; that subscription gate does not exist locally). `auto` is the
//! only session-only level here, mirroring the reference clearing the setting
//! on `/effort auto`.

const std = @import("std");
const env = @import("env.zig");
const types = @import("types.zig");

const ReasoningEffort = types.ReasoningEffort;

/// Environment variable that overrides the reasoning-effort level. Mirrors the
/// reference's CLAUDE_CODE_EFFORT_LEVEL.
pub const ENV_VAR: []const u8 = "CLAUDE_CODE_EFFORT_LEVEL";

/// The outcome of reading CLAUDE_CODE_EFFORT_LEVEL, mirroring the reference's
/// `EffortValue | null | undefined` tri-state from getEffortEnvOverride():
///   - .none    : env var is unset or holds an unrecognised value (undefined).
///                The env has no opinion; fall through to the persisted/default.
///   - .force_auto : env var is "auto"/"unset" (null). The env explicitly says
///                "no override" and clears any persisted level for the session.
///   - .level   : env var is a valid level; it wins over everything.
pub const EnvOverride = union(enum) {
    none,
    force_auto,
    level: ReasoningEffort,
};

/// Read CLAUDE_CODE_EFFORT_LEVEL and classify it. Pure-ish: reads the env via
/// core/env.zig (which consults the in-process override map first, so tests can
/// inject a value with env.setOverride without touching the real environment).
pub fn envOverride() EnvOverride {
    const raw = env.getenv(ENV_VAR) orelse return .none;
    return classifyEnv(raw);
}

/// Pure classification of a raw env-var string. Split out so tests can exercise
/// every branch without going through process env at all.
pub fn classifyEnv(raw: []const u8) EnvOverride {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return .none;
    if (std.ascii.eqlIgnoreCase(trimmed, "auto") or std.ascii.eqlIgnoreCase(trimmed, "unset")) {
        return .force_auto;
    }
    if (ReasoningEffort.fromString(trimmed)) |eff| {
        // fromString maps "auto"/"unset" to .auto, but we already handled those
        // above as force_auto; anything that resolves to .auto here would be a
        // spelling we want to treat as no-override, so guard it.
        if (eff == .auto) return .force_auto;
        return .{ .level = eff };
    }
    return .none;
}

/// Whether a level is persisted to the user settings (vs session-only). low,
/// medium, high, max persist; auto is session-only (selecting it clears the
/// persisted setting). Mirrors toPersistableEffort, minus the ant `max` gate.
pub fn isPersistable(level: ReasoningEffort) bool {
    return switch (level) {
        .auto => false,
        .low, .medium, .high, .max => true,
    };
}

/// Resolve the effort level that should actually be applied, following the full
/// precedence chain env override -> persisted setting -> default. Mirrors
/// resolveAppliedEffort. `persisted` is the level loaded from config (`.auto`
/// when nothing is persisted). The default is `.auto` (let the provider pick).
pub fn resolveApplied(override: EnvOverride, persisted: ReasoningEffort) ReasoningEffort {
    switch (override) {
        .level => |lvl| return lvl,
        .force_auto => return .auto,
        .none => return persisted,
    }
}

/// Convenience: resolve the startup effort from the persisted config string,
/// honoring CLAUDE_CODE_EFFORT_LEVEL. `persisted_str` is cfg.reasoning_effort.
/// An unparseable persisted string is treated as `.auto`.
pub fn resolveStartup(persisted_str: []const u8) ReasoningEffort {
    const persisted = ReasoningEffort.fromString(persisted_str) orelse .auto;
    return resolveApplied(envOverride(), persisted);
}

/// Build the user-facing message for `/effort <level>`, mirroring the
/// reference's setEffortValue / unsetEffortLevel messaging (effort.tsx:15-110):
///
///   - When the env override conflicts with the chosen level (env set to a
///     DIFFERENT level, or env pins a level while the user chose auto), report
///     that the env wins this session. The not-persistable case (auto) gets a
///     "session-only (nothing saved)" phrasing; the persistable case gets the
///     "clear it and X takes over" phrasing.
///   - Otherwise report "Set effort level to X[ (this session only)]: desc",
///     where the suffix appears only when the level is not persistable.
///
/// `env_raw` is the literal CLAUDE_CODE_EFFORT_LEVEL value (for the message);
/// pass null when the env is unset. Caller owns the returned slice.
pub fn buildSetMessage(
    allocator: std.mem.Allocator,
    chosen: ReasoningEffort,
    override: EnvOverride,
    env_raw: ?[]const u8,
) ![]u8 {
    const persistable = isPersistable(chosen);

    // Does the env override actually conflict with what the user asked for? The
    // env only "wins" visibly when its effective level differs from `chosen`.
    const conflict = switch (override) {
        .none => false,
        .force_auto => chosen != .auto,
        .level => |lvl| lvl != chosen,
    };

    if (conflict) {
        const raw = env_raw orelse ENV_VAR;
        if (!persistable) {
            return std.fmt.allocPrint(
                allocator,
                "Not applied: {s}={s} overrides effort this session, and {s} is session-only (nothing saved)",
                .{ ENV_VAR, raw, chosen.toString() },
            );
        }
        return std.fmt.allocPrint(
            allocator,
            "{s}={s} overrides this session - clear it and {s} takes over",
            .{ ENV_VAR, raw, chosen.toString() },
        );
    }

    const suffix: []const u8 = if (persistable) "" else " (this session only)";
    return std.fmt.allocPrint(
        allocator,
        "Set effort level to {s}{s}: {s}",
        .{ chosen.toString(), suffix, chosen.description() },
    );
}

const testing = std.testing;

test "buildSetMessage: persistable, no env conflict -> no suffix, no env note" {
    const msg = try buildSetMessage(testing.allocator, .medium, .none, null);
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "Set effort level to medium") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "(this session only)") == null);
    try testing.expect(std.mem.indexOf(u8, msg, ENV_VAR) == null);
}

test "buildSetMessage: auto is session-only -> suffix present" {
    const msg = try buildSetMessage(testing.allocator, .auto, .none, null);
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "(this session only)") != null);
}

test "buildSetMessage: persistable level with conflicting env -> override note" {
    const msg = try buildSetMessage(testing.allocator, .low, .{ .level = .high }, "high");
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, ENV_VAR) != null);
    try testing.expect(std.mem.indexOf(u8, msg, "takes over") != null);
}

test "buildSetMessage: matching env is not a conflict" {
    // env=medium and the user picks medium -> the outcome is the same, so no note.
    const msg = try buildSetMessage(testing.allocator, .medium, .{ .level = .medium }, "medium");
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, ENV_VAR) == null);
    try testing.expect(std.mem.indexOf(u8, msg, "Set effort level to medium") != null);
}

test "buildSetMessage: auto with conflicting pinned env -> session-only note" {
    const msg = try buildSetMessage(testing.allocator, .auto, .{ .level = .high }, "high");
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "session-only") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "Not applied") != null);
}

test "buildSetMessage has no long dashes" {
    const msg = try buildSetMessage(testing.allocator, .low, .{ .level = .high }, "high");
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "\u{2014}") == null);
    try testing.expect(std.mem.indexOf(u8, msg, "\u{2013}") == null);
}

test "classifyEnv: unset / empty / unknown -> none" {
    try testing.expect(classifyEnv("") == .none);
    try testing.expect(classifyEnv("   ") == .none);
    try testing.expect(classifyEnv("bogus") == .none);
}

test "classifyEnv: auto/unset -> force_auto" {
    try testing.expect(classifyEnv("auto") == .force_auto);
    try testing.expect(classifyEnv("AUTO") == .force_auto);
    try testing.expect(classifyEnv(" unset ") == .force_auto);
}

test "classifyEnv: valid levels -> level" {
    try testing.expectEqual(ReasoningEffort.low, classifyEnv("low").level);
    try testing.expectEqual(ReasoningEffort.medium, classifyEnv("MEDIUM").level);
    try testing.expectEqual(ReasoningEffort.high, classifyEnv("high").level);
    try testing.expectEqual(ReasoningEffort.max, classifyEnv("max").level);
}

test "isPersistable: auto is session-only, the rest persist" {
    try testing.expect(!isPersistable(.auto));
    try testing.expect(isPersistable(.low));
    try testing.expect(isPersistable(.medium));
    try testing.expect(isPersistable(.high));
    try testing.expect(isPersistable(.max));
}

test "resolveApplied: env level wins over persisted" {
    try testing.expectEqual(ReasoningEffort.high, resolveApplied(.{ .level = .high }, .low));
}

test "resolveApplied: force_auto wins over persisted" {
    try testing.expectEqual(ReasoningEffort.auto, resolveApplied(.force_auto, .high));
}

test "resolveApplied: no env opinion falls through to persisted" {
    try testing.expectEqual(ReasoningEffort.medium, resolveApplied(.none, .medium));
    try testing.expectEqual(ReasoningEffort.auto, resolveApplied(.none, .auto));
}

test "resolveStartup reads CLAUDE_CODE_EFFORT_LEVEL via the override map" {
    defer env.clearOverrides();

    // No env opinion: persisted wins.
    try testing.expectEqual(ReasoningEffort.medium, resolveStartup("medium"));

    // Env pins high: overrides the persisted low.
    try env.setOverride(ENV_VAR, "high");
    try testing.expectEqual(ReasoningEffort.high, resolveStartup("low"));

    // Env says auto/unset: clears the persisted high.
    try env.setOverride(ENV_VAR, "unset");
    try testing.expectEqual(ReasoningEffort.auto, resolveStartup("high"));
}
