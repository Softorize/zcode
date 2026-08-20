//! availableModels allowlist enforcement gate.
//!
//! Ported from the reference project's `modelAllowlist.ts`
//! (`isModelAllowed`, modelAllowlist.ts:100-170) and the pre-API-call check
//! (`validateModel.ts:31-36`). Gates a user-specified model against the
//! configured `availableModels` allowlist with three matching tiers before any
//! API call is made.
//!
//! Tier order (mirrors the reference exactly):
//!   1. Direct match     - the resolved model id equals an allowlist entry.
//!   2. Family wildcard   - a bare family alias entry (opus/sonnet/haiku) allows
//!      any model in that family, UNLESS the family has been narrowed by a more
//!      specific same-family entry in the same allowlist.
//!   3. Version prefix    - an entry like `opus-4-5` or `claude-opus-4-5` matches
//!      any build (`claude-opus-4-5-20251101`) at a `-` segment boundary. It must
//!      NOT match `opus-4-50` (segment-boundary, not raw startsWith).
//!
//! Bidirectional alias resolution: an input alias (e.g. `opus`) resolves to its
//! concrete id and is checked against the list; a list alias likewise resolves so
//! a concrete input id is matched against a family default.
//!
//! Deviation from the reference (documented in the project wiki): zcode stores
//! `available_models` as a single string. An EMPTY or unset string is treated as
//! "no allowlist" (allow all) to preserve zcode's historical behavior, rather
//! than the reference's `length === 0 -> block all`. An explicitly non-empty
//! allowlist enforces the tiers above.

const std = @import("std");
const model_alias = @import("model_alias.zig");

/// The three model families that participate in wildcard matching.
const FAMILIES = [_][]const u8{ "opus", "sonnet", "haiku" };

/// Parsed, lowercased allowlist entries. Owns its backing memory.
pub const Allowlist = struct {
    /// Lowercased entries (model ids only; any `:context` suffix dropped).
    entries: [][]u8,
    /// True when the source `available_models` string was empty/unset, meaning
    /// no restriction is enforced (allow all). Distinct from a list with zero
    /// usable entries after parsing (which also yields allow-all here, matching
    /// the documented zcode deviation).
    unset: bool,

    pub fn deinit(self: Allowlist, allocator: std.mem.Allocator) void {
        for (self.entries) |e| allocator.free(e);
        allocator.free(self.entries);
    }
};

/// Trim surrounding single/double quotes from a token (mirrors the catalog
/// parser in repl_commands.zig so `available_models` is read the same way).
fn trimQuotes(s: []const u8) []const u8 {
    if (s.len >= 2) {
        const first = s[0];
        const last = s[s.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            return s[1 .. s.len - 1];
        }
    }
    return s;
}

/// Parse the raw `available_models` config string into a lowercased entry list.
///
/// The string is comma-separated, optionally bracketed (`[a, b]`), and each
/// entry may carry a `:context_window` suffix (e.g. `mymodel:8000`) which is
/// dropped for allowlist purposes. An empty/whitespace string yields an `unset`
/// allowlist (allow all). Caller owns the result via `Allowlist.deinit`.
pub fn parse(allocator: std.mem.Allocator, raw_models: []const u8) !Allowlist {
    var body = std.mem.trim(u8, raw_models, " \t\r\n");
    if (body.len == 0) {
        return .{ .entries = try allocator.alloc([]u8, 0), .unset = true };
    }
    if (body.len >= 2 and body[0] == '[' and body[body.len - 1] == ']') {
        body = body[1 .. body.len - 1];
    }

    var list = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (list.items) |e| allocator.free(e);
        list.deinit();
    }

    var parts = std.mem.splitScalar(u8, body, ',');
    while (parts.next()) |part_raw| {
        var token = trimQuotes(std.mem.trim(u8, part_raw, " \t\r\n"));
        if (token.len == 0) continue;

        // Drop a trailing `:context_window` suffix; the allowlist keys on ids.
        if (std.mem.lastIndexOfScalar(u8, token, ':')) |idx| {
            const maybe_id = std.mem.trim(u8, token[0..idx], " \t");
            const maybe_ctx = std.mem.trim(u8, token[idx + 1 ..], " \t");
            // Only treat it as id:context when the right side is all digits, to
            // avoid mangling ids that legitimately contain a colon.
            if (maybe_id.len > 0 and maybe_ctx.len > 0 and isAllDigits(maybe_ctx)) {
                token = maybe_id;
            }
        }

        const lowered = try allocator.alloc(u8, token.len);
        for (token, 0..) |c, i| lowered[i] = std.ascii.toLower(c);
        try list.append(lowered);
    }

    // A non-empty source string that parsed to zero usable entries is treated
    // as unset (allow all) per the documented zcode deviation.
    const unset = list.items.len == 0;
    return .{ .entries = try list.toOwnedSlice(), .unset = unset };
}

fn isAllDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Returns the family name (opus/sonnet/haiku) the model belongs to, or null.
/// A model "belongs to" a family when its (lowercased) name contains the family
/// token as a `-` or boundary-delimited segment, so `claude-opus-4-6` is opus
/// but `opusplan` is not coerced into opus by substring.
fn familyOf(model_lower: []const u8) ?[]const u8 {
    for (FAMILIES) |fam| {
        if (modelBelongsToFamily(model_lower, fam)) return fam;
    }
    return null;
}

/// True if `model_lower` belongs to `family`. Matches the bare alias exactly, or
/// the family token appearing as a hyphen-delimited segment (e.g. `opus` inside
/// `claude-opus-4-6`).
fn modelBelongsToFamily(model_lower: []const u8, family: []const u8) bool {
    if (std.mem.eql(u8, model_lower, family)) return true;
    // Find `family` bounded by `-` on both sides (or string ends).
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, model_lower, i, family)) |pos| {
        const before_ok = pos == 0 or model_lower[pos - 1] == '-';
        const end = pos + family.len;
        const after_ok = end == model_lower.len or model_lower[end] == '-';
        if (before_ok and after_ok) return true;
        i = pos + 1;
    }
    return false;
}

/// True if `entry` is one of the bare family aliases (opus/sonnet/haiku).
fn isModelFamilyAlias(entry: []const u8) bool {
    for (FAMILIES) |fam| {
        if (std.mem.eql(u8, entry, fam)) return true;
    }
    return false;
}

/// True if the allowlist contains a NON-alias entry that belongs to `family`,
/// i.e. the family has been narrowed by a specific build/version entry. When
/// narrowed, the bare family-alias wildcard no longer allows the whole family.
fn familyHasSpecificEntries(entries: [][]u8, family: []const u8) bool {
    for (entries) |e| {
        if (isModelFamilyAlias(e)) continue;
        if (modelBelongsToFamily(e, family)) return true;
    }
    return false;
}

/// Tier 3: version-prefix segment-boundary match. `prefix` matches `model` when
/// every `-`-delimited segment of `prefix` equals the corresponding leading
/// segment of `model`. So `opus-4-5` matches `claude-opus-4-5-20251101` (after
/// the `claude-` lead is accounted for) but NOT `opus-4-50`.
///
/// To tolerate the `claude-` lead, we look for `prefix` starting at a segment
/// boundary inside `model` and require it to END at a segment boundary too.
fn modelMatchesVersionPrefix(model: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0) return false;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, model, i, prefix)) |pos| {
        const before_ok = pos == 0 or model[pos - 1] == '-';
        const end = pos + prefix.len;
        const after_ok = end == model.len or model[end] == '-';
        if (before_ok and after_ok) return true;
        i = pos + 1;
    }
    return false;
}

/// Lowercase `s` into a freshly allocated buffer. Caller frees.
fn dupLower(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

/// Resolve a model string to its concrete lowercased id (alias + `[1m]`
/// stripped). Caller frees the returned slice.
fn resolveLower(allocator: std.mem.Allocator, model: []const u8) ![]u8 {
    const resolved = try model_alias.resolve(allocator, model);
    defer resolved.deinit(allocator);
    // Strip a trailing [1m] if it survived (custom names carry it verbatim).
    var base = resolved.model;
    if (std.mem.endsWith(u8, base, "[1m]")) base = base[0 .. base.len - "[1m]".len];
    return dupLower(allocator, base);
}

/// Returns true if `model` is permitted by `allowlist`. An unset allowlist
/// allows everything. Otherwise the three tiers are evaluated against every
/// entry, with bidirectional alias resolution.
pub fn isAllowedWith(allocator: std.mem.Allocator, model: []const u8, allowlist: Allowlist) !bool {
    if (allowlist.unset) return true;
    if (allowlist.entries.len == 0) return true; // documented deviation: empty -> allow all

    const model_lower = try resolveLower(allocator, model);
    defer allocator.free(model_lower);

    const model_family = familyOf(model_lower);

    for (allowlist.entries) |entry| {
        // A bare family-alias entry (opus/sonnet/haiku) is handled solely as a
        // wildcard tier and short-circuits all other matching for that entry.
        // Otherwise its concrete resolution (e.g. opus -> claude-opus-4-6) would
        // leak through bidirectional/direct matching and defeat narrowing.
        if (isModelFamilyAlias(entry)) {
            // Tier 2: `opus` allows any opus model UNLESS the family is narrowed
            // by a specific same-family entry in the same allowlist.
            if (model_family) |fam| {
                if (std.mem.eql(u8, fam, entry) and !familyHasSpecificEntries(allowlist.entries, entry)) {
                    return true;
                }
            }
            continue;
        }

        // Tier 1: direct match against the entry as written.
        if (std.mem.eql(u8, entry, model_lower)) return true;

        // Bidirectional alias resolution: resolve the (non-alias) entry too and
        // direct-match. Covers a concrete-id entry vs an alias input and the
        // reverse where the input is concrete and the entry resolves to it.
        const entry_resolved = try resolveLower(allocator, entry);
        defer allocator.free(entry_resolved);
        if (std.mem.eql(u8, entry_resolved, model_lower)) return true;

        // Tier 3: version-prefix segment-boundary match.
        if (modelMatchesVersionPrefix(model_lower, entry)) return true;
    }

    return false;
}

/// Convenience: parse `raw_models` then check. Allocates and frees the parsed
/// allowlist internally.
pub fn isAllowed(allocator: std.mem.Allocator, model: []const u8, raw_models: []const u8) !bool {
    const allowlist = try parse(allocator, raw_models);
    defer allowlist.deinit(allocator);
    return isAllowedWith(allocator, model, allowlist);
}

const testing = std.testing;

test "unset available_models allows any model" {
    try testing.expect(try isAllowed(testing.allocator, "claude-opus-4-6", ""));
    try testing.expect(try isAllowed(testing.allocator, "anything", "   "));
    try testing.expect(try isAllowed(testing.allocator, "MyAzureDeployment", ""));
}

test "family alias opus allows opus model, denies sonnet" {
    try testing.expect(try isAllowed(testing.allocator, "claude-opus-4-6", "opus"));
    try testing.expect(!try isAllowed(testing.allocator, "claude-sonnet-4-6", "opus"));
}

test "family narrowed by specific entry denies the family default" {
    // ["opus","opus-4-5"]: claude-opus-4-6 denied (family narrowed), a
    // claude-opus-4-5-* allowed via the specific version prefix.
    try testing.expect(!try isAllowed(testing.allocator, "claude-opus-4-6", "opus,opus-4-5"));
    try testing.expect(try isAllowed(testing.allocator, "claude-opus-4-5-20251101", "opus,opus-4-5"));
}

test "full id exact match only" {
    try testing.expect(try isAllowed(testing.allocator, "claude-opus-4-6-20251101", "claude-opus-4-6-20251101"));
    try testing.expect(!try isAllowed(testing.allocator, "claude-opus-4-6-20251102", "claude-opus-4-6-20251101"));
}

test "version prefix matches build at segment boundary" {
    try testing.expect(try isAllowed(testing.allocator, "claude-opus-4-6-20251101", "opus-4-6"));
}

test "version prefix does not match across a non-boundary" {
    // opus-4-5 must NOT match opus-4-50.
    try testing.expect(!try isAllowed(testing.allocator, "claude-opus-4-50-20251101", "opus-4-5"));
}

test "bidirectional alias: list has alias, input is concrete id" {
    // Allowlist entry `opus` resolves to claude-opus-4-6 which is the input.
    try testing.expect(try isAllowed(testing.allocator, "claude-opus-4-6", "opus"));
    // Allowlist entry is concrete id, input is the alias.
    try testing.expect(try isAllowed(testing.allocator, "opus", "claude-opus-4-6"));
}

test "input alias denied when not in list" {
    try testing.expect(!try isAllowed(testing.allocator, "sonnet", "opus"));
}

test "parse drops context suffix" {
    const al = try parse(testing.allocator, "kimi-k2.5:8000, kimi-k2-thinking");
    defer al.deinit(testing.allocator);
    try testing.expect(!al.unset);
    try testing.expectEqual(@as(usize, 2), al.entries.len);
    try testing.expectEqualStrings("kimi-k2.5", al.entries[0]);
    try testing.expectEqualStrings("kimi-k2-thinking", al.entries[1]);
}

test "parse handles bracketed list" {
    const al = try parse(testing.allocator, "[opus, sonnet]");
    defer al.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), al.entries.len);
    try testing.expectEqualStrings("opus", al.entries[0]);
    try testing.expectEqualStrings("sonnet", al.entries[1]);
}

test "custom non-family model with explicit allowlist" {
    try testing.expect(try isAllowed(testing.allocator, "kimi-k2.5", "kimi-k2.5,kimi-k2-thinking"));
    try testing.expect(!try isAllowed(testing.allocator, "kimi-k2-other", "kimi-k2.5,kimi-k2-thinking"));
}
