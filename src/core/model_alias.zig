//! Model alias resolution and the `[1m]` long-context suffix.
//!
//! Ported from the reference project's `aliases.ts` and `model.ts`
//! (`parseUserSpecifiedModel`). Resolves bare aliases
//! (`opus`/`sonnet`/`haiku`/`best`/`opusplan`) and the `[1m]` suffix into
//! concrete model IDs at the point the user specifies a model.
//!
//! Reference behavior:
//! - `MODEL_ALIASES = [sonnet, opus, haiku, best, sonnet[1m], opus[1m],
//!   opusplan]` (aliases.ts:1-14).
//! - `parseUserSpecifiedModel`: trim + lowercase, detect `[1m]` via
//!   `has1mContext`, strip it to get the base, switch on the alias
//!   (`opusplan`->sonnet default, `sonnet`->sonnet default, `haiku`->haiku
//!   default, `opus`->opus default, `best`->opus/best), re-append `[1m]` where
//!   the family supports it; non-alias custom names pass through preserving case
//!   (model.ts:445-506).
//! - `MODEL_FAMILY_ALIASES = [sonnet, opus, haiku]` for allowlist wildcards
//!   (aliases.ts:21-25).
//!
//! Design notes:
//! - The default-model strings are zcode's current defaults (config.zig:137 for
//!   opus; repl_commands.zig:6246/6268 for sonnet/opus fallbacks). This module is
//!   the single owner of those strings so Task 7 (allowlist) and Task 8
//!   (context-window) reuse them rather than re-hardcoding.
//! - `opusplan` resolves to the sonnet base here; the dynamic "use Opus while in
//!   plan mode" swap (getRuntimeMainLoopModel, model.ts:145-167) is deferred.
//! - Case: we lowercase ONLY for alias matching. Custom names (e.g. Azure Foundry
//!   deployment IDs, which are case-sensitive) pass through with original case.

const std = @import("std");
const env = @import("env.zig");

/// The `[1m]` long-context suffix, lowercased for matching.
const ONE_M_SUFFIX = "[1m]";

/// zcode's default concrete model IDs per family. Single owner; do not duplicate.
pub fn getDefaultOpusModel() []const u8 {
    return "claude-opus-4-6";
}

pub fn getDefaultSonnetModel() []const u8 {
    return "claude-sonnet-4-6";
}

pub fn getDefaultHaikuModel() []const u8 {
    return "claude-haiku-4-5";
}

/// The bare aliases the user may type. `best` maps to opus; `opusplan` maps to
/// the sonnet base (plan-mode Opus swap deferred). The `*[1m]` combinations are
/// handled by suffix detection, not as distinct alias tokens.
const Alias = enum { opus, sonnet, haiku, best, opusplan };

/// Family aliases used for allowlist wildcard matching (Task 7 consumes this).
pub const MODEL_FAMILY_ALIASES = [_][]const u8{ "sonnet", "opus", "haiku" };

/// Result of resolving a user-specified model string.
pub const Resolved = struct {
    /// The concrete model ID. Caller owns this slice.
    model: []u8,
    /// True when the resolved model carries the `[1m]` long-context suffix.
    one_m: bool,

    pub fn deinit(self: Resolved, allocator: std.mem.Allocator) void {
        allocator.free(self.model);
    }
};

/// Returns true if `s` ends with the `[1m]` suffix (case-insensitive),
/// ignoring trailing whitespace.
fn endsWithOneM(s: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, s, " \t");
    if (trimmed.len < ONE_M_SUFFIX.len) return false;
    const tail = trimmed[trimmed.len - ONE_M_SUFFIX.len ..];
    return std.ascii.eqlIgnoreCase(tail, ONE_M_SUFFIX);
}

/// Strips a trailing `[1m]` suffix (case-insensitive) and any whitespace around
/// it. Returns the base slice into `s`.
fn stripOneM(s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (trimmed.len < ONE_M_SUFFIX.len) return trimmed;
    const tail = trimmed[trimmed.len - ONE_M_SUFFIX.len ..];
    if (std.ascii.eqlIgnoreCase(tail, ONE_M_SUFFIX)) {
        return std.mem.trimEnd(u8, trimmed[0 .. trimmed.len - ONE_M_SUFFIX.len], " \t");
    }
    return trimmed;
}

/// Matches a lowercased base string against the alias set. Returns null for
/// non-alias (custom) names.
fn aliasFromBase(base_lower: []const u8) ?Alias {
    if (std.mem.eql(u8, base_lower, "opus")) return .opus;
    if (std.mem.eql(u8, base_lower, "sonnet")) return .sonnet;
    if (std.mem.eql(u8, base_lower, "haiku")) return .haiku;
    if (std.mem.eql(u8, base_lower, "best")) return .best;
    if (std.mem.eql(u8, base_lower, "opusplan")) return .opusplan;
    return null;
}

/// Returns the concrete default model ID for an alias, plus whether its family
/// supports the `[1m]` long-context variant. Only the sonnet and opus families
/// carry `[1m]`; haiku has no 1M variant (reference family-support carry rule).
fn aliasDefault(alias: Alias) struct { model: []const u8, supports_1m: bool } {
    return switch (alias) {
        .opus => .{ .model = getDefaultOpusModel(), .supports_1m = true },
        .sonnet => .{ .model = getDefaultSonnetModel(), .supports_1m = true },
        .haiku => .{ .model = getDefaultHaikuModel(), .supports_1m = false },
        .best => .{ .model = getDefaultOpusModel(), .supports_1m = true },
        // Plan-mode Opus swap deferred: resolve the base to sonnet here.
        .opusplan => .{ .model = getDefaultSonnetModel(), .supports_1m = true },
    };
}

/// Resolve a user-specified model string into a concrete model ID.
///
/// - Trims and detects the `[1m]` suffix.
/// - If the base (lowercased) is a known alias, returns the family default,
///   re-appending `[1m]` only when the family supports it (sonnet/opus).
/// - Otherwise returns the ORIGINAL input (case preserved); the `[1m]` suffix is
///   carried through verbatim on custom names so downstream context-window
///   detection still sees it.
///
/// Caller owns `Resolved.model`.
pub fn resolve(allocator: std.mem.Allocator, input: []const u8) !Resolved {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");

    const has_1m = endsWithOneM(trimmed);
    const base = stripOneM(trimmed);

    // Lowercase a copy of the base ONLY for alias matching.
    var base_lower = try allocator.alloc(u8, base.len);
    defer allocator.free(base_lower);
    for (base, 0..) |c, i| base_lower[i] = std.ascii.toLower(c);

    if (aliasFromBase(base_lower)) |alias| {
        const def = aliasDefault(alias);
        const carry_1m = has_1m and def.supports_1m;
        const model = if (carry_1m)
            try std.fmt.allocPrint(allocator, "{s}[1m]", .{def.model})
        else
            try allocator.dupe(u8, def.model);
        return .{ .model = model, .one_m = carry_1m };
    }

    // Non-alias custom name: return original (case-preserved). Carry [1m] as-is.
    return .{ .model = try allocator.dupe(u8, trimmed), .one_m = has_1m };
}

/// Returns true if the model string carries an active `[1m]` long-context
/// suffix. Honors the `CLAUDE_CODE_DISABLE_1M_CONTEXT` env switch: when truthy,
/// the suffix is ignored. (Used by Task 8 context-window resolution.)
pub fn has1mContext(model: []const u8) bool {
    if (env.isEnvTruthy("CLAUDE_CODE_DISABLE_1M_CONTEXT")) return false;
    return endsWithOneM(model);
}

/// Returns true if the model family supports the 1M context window. Mirrors the
/// reference `modelSupports1M`: canonical name contains `claude-sonnet-4` or
/// `opus-4-6`. Update when new families gain 1M support.
pub fn modelSupports1M(model: []const u8) bool {
    return std.mem.indexOf(u8, model, "claude-sonnet-4") != null or
        std.mem.indexOf(u8, model, "opus-4-6") != null;
}

const testing = std.testing;

test "resolve opus -> default opus, one_m false" {
    const r = try resolve(testing.allocator, "opus");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("claude-opus-4-6", r.model);
    try testing.expect(!r.one_m);
}

test "resolve sonnet[1m] -> sonnet default with [1m], one_m true" {
    const r = try resolve(testing.allocator, "sonnet[1m]");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("claude-sonnet-4-6[1m]", r.model);
    try testing.expect(r.one_m);
}

test "resolve haiku[1m] -> haiku base, one_m false (haiku has no 1M)" {
    const r = try resolve(testing.allocator, "haiku[1m]");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("claude-haiku-4-5", r.model);
    try testing.expect(!r.one_m);
}

test "resolve best -> opus default" {
    const r = try resolve(testing.allocator, "best");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("claude-opus-4-6", r.model);
    try testing.expect(!r.one_m);
}

test "resolve opusplan -> sonnet default" {
    const r = try resolve(testing.allocator, "opusplan");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("claude-sonnet-4-6", r.model);
    try testing.expect(!r.one_m);
}

test "resolve full id passes through unchanged" {
    const r = try resolve(testing.allocator, "claude-opus-4-6");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("claude-opus-4-6", r.model);
    try testing.expect(!r.one_m);
}

test "resolve custom name preserves case" {
    const r = try resolve(testing.allocator, "MyAzureDeployment");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("MyAzureDeployment", r.model);
    try testing.expect(!r.one_m);
}

test "resolve alias is case-insensitive" {
    const r = try resolve(testing.allocator, "OPUS");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("claude-opus-4-6", r.model);
}

test "resolve uppercase suffix [1M] detected on alias" {
    const r = try resolve(testing.allocator, "Sonnet[1M]");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("claude-sonnet-4-6[1m]", r.model);
    try testing.expect(r.one_m);
}

test "resolve custom name with [1m] carries suffix verbatim" {
    const r = try resolve(testing.allocator, "claude-sonnet-4-6[1m]");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("claude-sonnet-4-6[1m]", r.model);
    try testing.expect(r.one_m);
}

test "resolve trims surrounding whitespace" {
    const r = try resolve(testing.allocator, "  opus  ");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("claude-opus-4-6", r.model);
}

test "has1mContext true for [1m] suffix" {
    try testing.expect(has1mContext("claude-sonnet-4-6[1m]"));
    try testing.expect(!has1mContext("claude-sonnet-4-6"));
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "has1mContext honors CLAUDE_CODE_DISABLE_1M_CONTEXT" {
    _ = setenv("CLAUDE_CODE_DISABLE_1M_CONTEXT", "1", 1);
    defer _ = unsetenv("CLAUDE_CODE_DISABLE_1M_CONTEXT");
    // Even with the [1m] suffix present, the disable switch forces false.
    try testing.expect(!has1mContext("claude-sonnet-4-6[1m]"));
}

test "modelSupports1M matches sonnet-4 and opus-4-6" {
    try testing.expect(modelSupports1M("claude-sonnet-4-6"));
    try testing.expect(modelSupports1M("claude-opus-4-6"));
    try testing.expect(!modelSupports1M("claude-haiku-4-5"));
}
