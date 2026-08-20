//! Model deprecation / retirement warnings.
//!
//! Mirrors the reference's `src/utils/model/deprecation.ts` snapshot:
//! a small static table keyed by case-insensitive model-id substrings, with
//! per-provider retirement dates. When a user selects or lists a deprecated
//! model, `getModelDeprecationWarning` returns a plain-ASCII warning string so
//! the caller can surface it.
//!
//! Pure module: no IO, no allocation. The warning string is a static slice for
//! the (rare) deprecated case and null otherwise, so callers can print it
//! directly without freeing.
//!
//! Provider mapping: the reference keys retirement dates by `firstParty`,
//! `bedrock`, `vertex`, `foundry`. zcode names its first-party Claude provider
//! `"anthropic"`, so we map `"anthropic"` -> the firstParty date. The other
//! three keys are carried for forward-compat if zcode ever grows those
//! providers; today only `"anthropic"` resolves to a non-null date.

const std = @import("std");

/// Per-provider retirement dates. A null field means the model is not
/// deprecated for that provider (so no warning is shown there).
const RetirementDates = struct {
    first_party: ?[]const u8,
    bedrock: ?[]const u8,
    vertex: ?[]const u8,
    foundry: ?[]const u8,
};

const DeprecationEntry = struct {
    /// Case-insensitive substring to match against a model id.
    key: []const u8,
    /// Human-readable model name used in the warning.
    model_name: []const u8,
    retirement_dates: RetirementDates,
};

/// Static deprecation table, seeded from the reference's `DEPRECATED_MODELS`
/// snapshot. The dates rot over time; keep the table small and update it to
/// match the reference. Substring keys are matched case-insensitively.
const DEPRECATED_MODELS = [_]DeprecationEntry{
    .{
        .key = "claude-3-opus",
        .model_name = "Claude 3 Opus",
        .retirement_dates = .{
            .first_party = "January 5, 2026",
            .bedrock = "January 15, 2026",
            .vertex = "January 5, 2026",
            .foundry = "January 5, 2026",
        },
    },
    .{
        .key = "claude-3-7-sonnet",
        .model_name = "Claude 3.7 Sonnet",
        .retirement_dates = .{
            .first_party = "February 19, 2026",
            .bedrock = "April 28, 2026",
            .vertex = "May 11, 2026",
            .foundry = "February 19, 2026",
        },
    },
    .{
        .key = "claude-3-5-haiku",
        .model_name = "Claude 3.5 Haiku",
        .retirement_dates = .{
            .first_party = "February 19, 2026",
            .bedrock = null,
            .vertex = null,
            .foundry = null,
        },
    },
};

/// Resolve a zcode provider string to the reference's provider-keyed
/// retirement date. zcode's first-party Claude provider is `"anthropic"`,
/// which maps to the reference's `firstParty`. Bedrock/vertex/foundry are
/// carried for forward-compat; an unknown provider resolves to firstParty so a
/// deprecated Claude model still warns under the default config.
fn retirementDateForProvider(dates: RetirementDates, provider: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(provider, "bedrock")) return dates.bedrock;
    if (std.ascii.eqlIgnoreCase(provider, "vertex")) return dates.vertex;
    if (std.ascii.eqlIgnoreCase(provider, "foundry")) return dates.foundry;
    // "anthropic" and any other provider map to the first-party date.
    return dates.first_party;
}

/// Case-insensitive substring search (Zig std has no case-insensitive
/// indexOf). Returns true if `needle` appears anywhere in `haystack`.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Look up the deprecation entry whose substring key matches `model_id` and
/// whose provider has a non-null retirement date. Returns the matched entry's
/// model name and the resolved date, or null when the model is not deprecated
/// for that provider.
const DeprecationInfo = struct {
    model_name: []const u8,
    retirement_date: []const u8,
};

fn getDeprecatedModelInfo(model_id: []const u8, provider: []const u8) ?DeprecationInfo {
    for (DEPRECATED_MODELS) |entry| {
        if (!containsIgnoreCase(model_id, entry.key)) continue;
        const date = retirementDateForProvider(entry.retirement_dates, provider) orelse continue;
        return .{ .model_name = entry.model_name, .retirement_date = date };
    }
    return null;
}

/// Format the warning into `buf` and return the written slice, or null when
/// the model is not deprecated for the provider. Caller owns `buf`; nothing is
/// allocated. Uses a plain "warning:" prefix (ASCII, no unicode glyph, no long
/// dashes per project rules). `buf` should be at least 160 bytes; on overflow
/// the warning is silently dropped (returns null) rather than truncated.
pub fn getModelDeprecationWarning(
    buf: []u8,
    model_id: []const u8,
    provider: []const u8,
) ?[]const u8 {
    if (model_id.len == 0) return null;
    const info = getDeprecatedModelInfo(model_id, provider) orelse return null;
    return std.fmt.bufPrint(
        buf,
        "warning: {s} will be retired on {s}. Consider switching to a newer model.",
        .{ info.model_name, info.retirement_date },
    ) catch null;
}

const testing = std.testing;

test "deprecated model + matching provider returns a warning with the date" {
    var buf: [256]u8 = undefined;
    const warning = getModelDeprecationWarning(&buf, "claude-3-opus-20240229", "anthropic");
    try testing.expect(warning != null);
    try testing.expect(std.mem.indexOf(u8, warning.?, "Claude 3 Opus") != null);
    try testing.expect(std.mem.indexOf(u8, warning.?, "January 5, 2026") != null);
    try testing.expect(std.mem.indexOf(u8, warning.?, "warning:") != null);
}

test "case-insensitive substring match on the model id" {
    var buf: [256]u8 = undefined;
    const warning = getModelDeprecationWarning(&buf, "CLAUDE-3-7-SONNET-20250219", "anthropic");
    try testing.expect(warning != null);
    try testing.expect(std.mem.indexOf(u8, warning.?, "Claude 3.7 Sonnet") != null);
    try testing.expect(std.mem.indexOf(u8, warning.?, "February 19, 2026") != null);
}

test "non-deprecated model returns null" {
    var buf: [256]u8 = undefined;
    try testing.expect(getModelDeprecationWarning(&buf, "claude-opus-4-6", "anthropic") == null);
    try testing.expect(getModelDeprecationWarning(&buf, "gpt-4o", "openai") == null);
}

test "deprecated model with a null provider retirement date returns null" {
    // Claude 3.5 Haiku is deprecated for firstParty but has null bedrock/vertex/foundry.
    var buf: [256]u8 = undefined;
    try testing.expect(getModelDeprecationWarning(&buf, "claude-3-5-haiku-20241022", "bedrock") == null);
    try testing.expect(getModelDeprecationWarning(&buf, "claude-3-5-haiku-20241022", "vertex") == null);
    // But firstParty (anthropic) still warns.
    const warning = getModelDeprecationWarning(&buf, "claude-3-5-haiku-20241022", "anthropic");
    try testing.expect(warning != null);
    try testing.expect(std.mem.indexOf(u8, warning.?, "Claude 3.5 Haiku") != null);
}

test "empty model id returns null" {
    var buf: [256]u8 = undefined;
    try testing.expect(getModelDeprecationWarning(&buf, "", "anthropic") == null);
}

test "provider-specific date is selected (bedrock vs firstParty for 3.7 sonnet)" {
    var buf: [256]u8 = undefined;
    const fp = getModelDeprecationWarning(&buf, "claude-3-7-sonnet", "anthropic");
    try testing.expect(fp != null);
    try testing.expect(std.mem.indexOf(u8, fp.?, "February 19, 2026") != null);

    var buf2: [256]u8 = undefined;
    const bedrock = getModelDeprecationWarning(&buf2, "claude-3-7-sonnet", "bedrock");
    try testing.expect(bedrock != null);
    try testing.expect(std.mem.indexOf(u8, bedrock.?, "April 28, 2026") != null);
}

test "unknown provider maps to first-party date" {
    var buf: [256]u8 = undefined;
    const warning = getModelDeprecationWarning(&buf, "claude-3-opus", "some-proxy");
    try testing.expect(warning != null);
    try testing.expect(std.mem.indexOf(u8, warning.?, "January 5, 2026") != null);
}
