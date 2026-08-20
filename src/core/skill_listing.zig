//! Awareness listing renderer (deep module for skill parity, PRD
//! Softorize/zcode#532). Turns the model-visible set of skills into a compact,
//! budget-capped listing string injected into the model's context each turn so
//! the model knows which skills exist and roughly when to use them.
//!
//! This module is PURE: no file IO, no rt singleton. Inputs are a slice of
//! `SkillSpec` (assumed already filtered to the model-visible set) plus a
//! character budget; output is an owned string the caller frees.
//!
//! The output is deterministically ordered (case-insensitive by name) so it only
//! changes when the visible set changes -- this keeps the prompt cache warm.

const std = @import("std");
const std_io = @import("std_io.zig");
const skill_types = @import("skill_types.zig");

const SkillSpec = skill_types.SkillSpec;

/// Per-entry summary cap, matching Claude Code's awareness listing.
pub const MAX_ENTRY_CHARS: usize = 250;

/// Minimum per-description budget below which a degraded entry drops its
/// summary entirely (names-only). Mirrors Claude Code's MIN_DESC_LENGTH
/// in prompt.ts formatCommandsWithinBudget (skills-09).
pub const MIN_DESC_LENGTH: usize = 20;

const header = "Available skills (invoke via the Skill tool, or /<name>):";

/// Render a budget-capped, deterministically-ordered skill listing for model
/// awareness. `skills` is assumed already filtered to the model-visible set.
/// Entries are "- <name>: <summary>" where summary is when_to_use (falling back
/// to description), trimmed to MAX_ENTRY_CHARS.
///
/// Budget degradation (skills-09): bundled skills (scope == .builtin) keep
/// their full descriptions and are NEVER dropped or truncated, even under a
/// tight budget. When the full listing exceeds `char_budget`, only the
/// non-bundled ("rest") entries degrade: first their descriptions are trimmed
/// to a per-rest max, and once that max falls below MIN_DESC_LENGTH the rest
/// becomes names-only. If even bundled-full plus rest-names-only overflows,
/// bundled entries are still all emitted (never truncated) and only the rest
/// names are trimmed to as many as fit. Returns "" when skills is empty.
pub fn render(allocator: std.mem.Allocator, skills: []const SkillSpec, char_budget: usize) ![]u8 {
    if (skills.len == 0) return allocator.dupe(u8, "");

    // Deterministic order via a local index permutation -- never mutate input.
    const order = try allocator.alloc(usize, skills.len);
    defer allocator.free(order);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, skills, lessThanByName);

    // 1. Try the full detailed listing (header + "- name: summary" per skill).
    //    When everything fits, the output is identical to the pre-skills-09
    //    behavior (regression guard).
    const detailed = try renderDetailed(allocator, skills, order);
    if (detailed.len <= char_budget) return detailed;
    allocator.free(detailed);

    // Over budget: partition into bundled (preserved full) vs rest (degradable),
    // each keeping the combined sort order.
    var bundled = std.array_list.Managed(usize).init(allocator);
    defer bundled.deinit();
    var rest = std.array_list.Managed(usize).init(allocator);
    defer rest.deinit();
    for (order) |idx| {
        if (skills[idx].scope == .builtin) {
            try bundled.append(idx);
        } else {
            try rest.append(idx);
        }
    }

    // Length the bundled-full block occupies (header + every bundled entry at
    // full 250-capped description). Bundled is never trimmed, so this is a
    // floor on the output length.
    const bundled_block_len = try measureBundledFloor(allocator, skills, bundled.items, rest.items);

    // 2. With bundled fixed at full, compute the remaining budget for the rest
    //    and pick a degradation mode. If there is no remaining budget for full
    //    rest descriptions, fall to names-only; if even per-rest desc budget
    //    drops below MIN_DESC_LENGTH, names-only.
    const remaining: usize = if (char_budget > bundled_block_len) char_budget - bundled_block_len else 0;

    // Try full rest descriptions first (no extra trim beyond MAX_ENTRY_CHARS).
    {
        const full_rest = try renderPartitioned(allocator, skills, bundled.items, rest.items, .full, 0);
        if (full_rest.len <= char_budget) return full_rest;
        allocator.free(full_rest);
    }

    // Compute a per-rest description max from the remaining budget. When it is
    // at least MIN_DESC_LENGTH, trim rest descriptions to that width; otherwise
    // render the rest names-only.
    const per_rest_max = if (rest.items.len > 0) remaining / rest.items.len else 0;
    if (per_rest_max >= MIN_DESC_LENGTH) {
        const trimmed = try renderPartitioned(allocator, skills, bundled.items, rest.items, .trim, per_rest_max);
        if (trimmed.len <= char_budget) return trimmed;
        allocator.free(trimmed);
    }

    // 3. Bundled full + rest names-only. If it fits, return it.
    {
        const names = try renderPartitioned(allocator, skills, bundled.items, rest.items, .none, 0);
        if (names.len <= char_budget) return names;
        allocator.free(names);
    }

    // 4. Last resort: bundled is still fully preserved (never dropped). Trim the
    //    rest names to as many as fit under the budget; if even zero rest names
    //    overflow, emit bundled-only (still never truncated).
    var fit: usize = rest.items.len;
    while (true) {
        const candidate = try renderPartitionedRestCount(allocator, skills, bundled.items, rest.items, fit);
        if (candidate.len <= char_budget or fit == 0) return candidate;
        allocator.free(candidate);
        fit -= 1;
    }
}

/// Degradation mode for the non-bundled ("rest") entries.
const RestMode = enum { full, trim, none };

/// Build the combined listing: bundled entries always full (250-capped), rest
/// entries rendered according to `rest_mode`. Entries are emitted in the
/// already-sorted combined order by merging the two index slices.
fn renderPartitioned(
    allocator: std.mem.Allocator,
    skills: []const SkillSpec,
    bundled: []const usize,
    rest: []const usize,
    rest_mode: RestMode,
    rest_desc_max: usize,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll(header);
    try writeMerged(w, skills, bundled, rest, rest_mode, rest_desc_max, rest.len);
    try w.writeByte('\n');
    return out.toOwnedSlice();
}

/// Like renderPartitioned but emits only the first `rest_count` rest names
/// (bundled always full). Used by the final names-truncation fallback.
fn renderPartitionedRestCount(
    allocator: std.mem.Allocator,
    skills: []const SkillSpec,
    bundled: []const usize,
    rest: []const usize,
    rest_count: usize,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll(header);
    try writeMerged(w, skills, bundled, rest, .none, 0, rest_count);
    try w.writeByte('\n');
    return out.toOwnedSlice();
}

/// Measure the rendered length of the bundled-full block (header + every
/// bundled entry at full description, no rest entries). This is a floor on the
/// final output length since bundled entries are never trimmed or dropped.
fn measureBundledFloor(
    allocator: std.mem.Allocator,
    skills: []const SkillSpec,
    bundled: []const usize,
    rest: []const usize,
) !usize {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();
    try w.writeAll(header);
    try writeMerged(w, skills, bundled, rest, .none, 0, 0);
    try w.writeByte('\n');
    const owned = try out.toOwnedSlice();
    defer allocator.free(owned);
    return owned.len;
}

/// Write the merged, sort-ordered entry lines. `bundled` and `rest` are each
/// in ascending combined-sort order; merging by name keeps the combined order
/// stable. Bundled entries always render their full summary; rest entries
/// render per `rest_mode`, and only the first `rest_count` rest entries are
/// emitted (bundled entries are always all emitted).
fn writeMerged(
    w: *std.Io.Writer,
    skills: []const SkillSpec,
    bundled: []const usize,
    rest: []const usize,
    rest_mode: RestMode,
    rest_desc_max: usize,
    rest_count: usize,
) !void {
    var bi: usize = 0;
    var ri: usize = 0;
    var rest_emitted: usize = 0;
    while (bi < bundled.len or ri < rest.len) {
        // Decide which side has the next entry in combined sort order.
        const take_bundled = if (bi >= bundled.len)
            false
        else if (ri >= rest.len)
            true
        else
            !std.ascii.lessThanIgnoreCase(skills[rest[ri]].name, skills[bundled[bi]].name);

        if (take_bundled) {
            const skill = skills[bundled[bi]];
            try w.print("\n- {s}: ", .{skill.name});
            try writeSummary(w, summaryOf(skill), MAX_ENTRY_CHARS);
            bi += 1;
        } else {
            const skill = skills[rest[ri]];
            if (rest_emitted < rest_count) {
                switch (rest_mode) {
                    .full => {
                        try w.print("\n- {s}: ", .{skill.name});
                        try writeSummary(w, summaryOf(skill), MAX_ENTRY_CHARS);
                    },
                    .trim => {
                        const cap = @min(rest_desc_max, MAX_ENTRY_CHARS);
                        try w.print("\n- {s}: ", .{skill.name});
                        try writeSummary(w, summaryOf(skill), cap);
                    },
                    .none => {
                        try w.print("\n- {s}", .{skill.name});
                    },
                }
                rest_emitted += 1;
            }
            ri += 1;
        }
    }
}

fn summaryOf(skill: SkillSpec) []const u8 {
    return if (skill.when_to_use.len > 0) skill.when_to_use else skill.description;
}

/// Build "header\n- name: summary\n..." over the given sort order, full.
fn renderDetailed(allocator: std.mem.Allocator, skills: []const SkillSpec, order: []const usize) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll(header);
    for (order) |idx| {
        const skill = skills[idx];
        try w.print("\n- {s}: ", .{skill.name});
        try writeSummary(w, summaryOf(skill), MAX_ENTRY_CHARS);
    }
    try w.writeByte('\n');
    return out.toOwnedSlice();
}

/// Write a single-line summary: collapse internal newlines (and the \r that may
/// accompany them) to spaces, and cap at `cap` bytes (byte-boundary slice --
/// summaries are short ASCII-ish frontmatter prose).
fn writeSummary(w: *std.Io.Writer, raw: []const u8, cap: usize) !void {
    const capped = if (raw.len > cap) raw[0..cap] else raw;
    for (capped) |c| {
        const out_c: u8 = switch (c) {
            '\n', '\r' => ' ',
            else => c,
        };
        try w.writeByte(out_c);
    }
}

fn lessThanByName(skills: []const SkillSpec, lhs: usize, rhs: usize) bool {
    return std.ascii.lessThanIgnoreCase(skills[lhs].name, skills[rhs].name);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

/// Build a read-only SkillSpec from string literals for tests. `render` only
/// reads fields and never frees them, so casting away const is safe here.
/// Defaults to builtin scope; use `testSpecScoped` to choose a scope.
fn testSpec(name: []const u8, description: []const u8, when_to_use: []const u8) SkillSpec {
    return testSpecScoped(name, description, when_to_use, .builtin);
}

fn testSpecScoped(name: []const u8, description: []const u8, when_to_use: []const u8, scope: skill_types.SkillScope) SkillSpec {
    return .{
        .name = @constCast(name),
        .description = @constCast(description),
        .when_to_use = @constCast(when_to_use),
        .prompt = @constCast(""),
        .scope = scope,
        .source_path = @constCast(""),
        .allowed_tools = &.{},
        .arg_names = &.{},
        .model = @constCast(""),
        .effort = @constCast(""),
        .context = .inline_skill,
        .agent = @constCast(""),
        .paths = &.{},
        .user_invocable = true,
        .disable_model_invocation = false,
        .version = @constCast(""),
        .aliases = &.{},
        .hooks_json = @constCast(""),
    };
}

test "render is deterministically ordered regardless of input order" {
    const a = testSpec("alpha", "desc a", "");
    const b = testSpec("Bravo", "desc b", "");
    const c = testSpec("charlie", "desc c", "");

    const in1 = [_]SkillSpec{ c, a, b };
    const in2 = [_]SkillSpec{ b, c, a };

    const r1 = try render(testing.allocator, &in1, 10_000);
    defer testing.allocator.free(r1);
    const r2 = try render(testing.allocator, &in2, 10_000);
    defer testing.allocator.free(r2);

    try testing.expectEqualStrings(r1, r2);
    // Case-insensitive ascending: alpha, Bravo, charlie.
    const i_alpha = std.mem.indexOf(u8, r1, "- alpha:").?;
    const i_bravo = std.mem.indexOf(u8, r1, "- Bravo:").?;
    const i_charlie = std.mem.indexOf(u8, r1, "- charlie:").?;
    try testing.expect(i_alpha < i_bravo);
    try testing.expect(i_bravo < i_charlie);
    // Header present.
    try testing.expect(std.mem.startsWith(u8, r1, header));
}

test "summary prefers when_to_use over description" {
    const s = testSpec("committer", "the description", "when changes are staged");
    const in = [_]SkillSpec{s};
    const r = try render(testing.allocator, &in, 10_000);
    defer testing.allocator.free(r);

    try testing.expect(std.mem.indexOf(u8, r, "when changes are staged") != null);
    try testing.expect(std.mem.indexOf(u8, r, "the description") == null);
}

test "summary falls back to description when when_to_use is empty" {
    const s = testSpec("x", "fallback desc", "");
    const in = [_]SkillSpec{s};
    const r = try render(testing.allocator, &in, 10_000);
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "fallback desc") != null);
}

test "per-entry summary truncated at MAX_ENTRY_CHARS" {
    // 400-char summary; only the first MAX_ENTRY_CHARS bytes should appear.
    const long = "A" ** 400;
    const s = testSpec("big", "d", long);
    const in = [_]SkillSpec{s};
    const r = try render(testing.allocator, &in, 10_000);
    defer testing.allocator.free(r);

    const run_of_a = "A" ** MAX_ENTRY_CHARS;
    try testing.expect(std.mem.indexOf(u8, r, run_of_a) != null);
    const too_many = "A" ** (MAX_ENTRY_CHARS + 1);
    try testing.expect(std.mem.indexOf(u8, r, too_many) == null);
}

test "internal newlines in summary collapse to spaces" {
    const s = testSpec("multi", "d", "line one\nline two\r\nline three");
    const in = [_]SkillSpec{s};
    const r = try render(testing.allocator, &in, 10_000);
    defer testing.allocator.free(r);
    // The summary lives on the single "- multi: ..." line; no stray newline
    // should split it.
    try testing.expect(std.mem.indexOf(u8, r, "line one line two") != null);
    try testing.expect(std.mem.indexOf(u8, r, "line three") != null);
}

test "names-only fallback when budget too small for summaries" {
    // Non-builtin (.user) skills degrade under budget; bundled skills never do
    // (see skills-09 tests below), so use .user here to exercise degradation.
    const a = testSpecScoped("alpha", "a very long description that would blow any tight character budget once rendered", "", .user);
    const b = testSpecScoped("bravo", "another long description that also would not fit inside the small budget here", "", .user);
    const in = [_]SkillSpec{ a, b };

    // Big enough for header + both names, too small for the long summaries.
    const budget = header.len + 32;
    const r = try render(testing.allocator, &in, budget);
    defer testing.allocator.free(r);

    try testing.expect(r.len <= budget);
    try testing.expect(std.mem.indexOf(u8, r, "- alpha") != null);
    try testing.expect(std.mem.indexOf(u8, r, "- bravo") != null);
    // No summary colon-space body after the names.
    try testing.expect(std.mem.indexOf(u8, r, "- alpha:") == null);
}

test "names-only truncated to as many entries as fit; header always present" {
    // Use .user scope so these entries are degradable/droppable; bundled
    // (.builtin) entries are never dropped (covered by skills-09 tests).
    const a = testSpecScoped("alpha", "d", "", .user);
    const b = testSpecScoped("bravo", "d", "", .user);
    const c = testSpecScoped("charlie", "d", "", .user);
    const in = [_]SkillSpec{ a, b, c };

    // Room for the header + exactly one name line ("\n- alpha" = 8 chars).
    const budget = header.len + 8 + 1; // +1 trailing newline slack
    const r = try render(testing.allocator, &in, budget);
    defer testing.allocator.free(r);

    try testing.expect(r.len <= budget);
    try testing.expect(std.mem.startsWith(u8, r, header));
    try testing.expect(std.mem.indexOf(u8, r, "- alpha") != null);
    // bravo / charlie should not all fit.
    try testing.expect(std.mem.indexOf(u8, r, "- charlie") == null);
}

test "empty input returns empty owned string" {
    const in = [_]SkillSpec{};
    const r = try render(testing.allocator, &in, 1000);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("", r);
}

test "skills-09 bundled skill keeps full description while user skill degrades" {
    const long_desc = "B" ** 120;
    const bundled = testSpecScoped("bundled", long_desc, "", .builtin);
    const user = testSpecScoped("userskill", "U" ** 120, "", .user);
    const in = [_]SkillSpec{ bundled, user };

    // Budget big enough for the full bundled entry + the user name, but far too
    // small for the user's full description.
    const budget = header.len + 12 + long_desc.len + 64;
    const r = try render(testing.allocator, &in, budget);
    defer testing.allocator.free(r);

    try testing.expect(r.len <= budget);
    // Bundled keeps its full 120-char description.
    try testing.expect(std.mem.indexOf(u8, r, long_desc) != null);
    try testing.expect(std.mem.indexOf(u8, r, "- bundled: ") != null);
    // User skill present by name but degraded to names-only (no colon body).
    try testing.expect(std.mem.indexOf(u8, r, "- userskill") != null);
    try testing.expect(std.mem.indexOf(u8, r, "- userskill: ") == null);
}

test "skills-09 everything fits is unchanged full detailed listing" {
    const bundled = testSpecScoped("bundled", "bundled desc", "", .builtin);
    const user = testSpecScoped("userskill", "user desc", "", .user);
    const in = [_]SkillSpec{ bundled, user };

    const r = try render(testing.allocator, &in, 10_000);
    defer testing.allocator.free(r);

    // Both skills keep full "- name: desc" form, sorted (bundled < userskill).
    try testing.expect(std.mem.indexOf(u8, r, "- bundled: bundled desc") != null);
    try testing.expect(std.mem.indexOf(u8, r, "- userskill: user desc") != null);
    const i_bundled = std.mem.indexOf(u8, r, "- bundled:").?;
    const i_user = std.mem.indexOf(u8, r, "- userskill:").?;
    try testing.expect(i_bundled < i_user);
}

test "skills-09 bundled entries never dropped even under names-only truncation" {
    // Several user skills plus two bundled. Budget is so tight that not all
    // user names fit, forcing names-only truncation of the rest -- but BOTH
    // bundled skills must still appear at full description.
    const b1 = testSpecScoped("aaa-bundled", "kept full one", "", .builtin);
    const b2 = testSpecScoped("zzz-bundled", "kept full two", "", .builtin);
    const us1 = testSpecScoped("mmm-user1", "u1 desc", "", .user);
    const us2 = testSpecScoped("mmm-user2", "u2 desc", "", .user);
    const us3 = testSpecScoped("mmm-user3", "u3 desc", "", .user);
    const in = [_]SkillSpec{ b1, us1, us2, us3, b2 };

    // Just enough for the bundled-full block plus a little slack for one or two
    // user names, not all three.
    const budget = header.len + ("\n- aaa-bundled: kept full one".len) + ("\n- zzz-bundled: kept full two".len) + ("\n- mmm-user1".len) + 2;
    const r = try render(testing.allocator, &in, budget);
    defer testing.allocator.free(r);

    try testing.expect(r.len <= budget);
    // Both bundled skills present at full description.
    try testing.expect(std.mem.indexOf(u8, r, "- aaa-bundled: kept full one") != null);
    try testing.expect(std.mem.indexOf(u8, r, "- zzz-bundled: kept full two") != null);
    // Not all user skills fit -- at least the last one is dropped.
    try testing.expect(std.mem.indexOf(u8, r, "- mmm-user3") == null);
}

test "skills-09 all-bundled set is never degraded under tight budget" {
    // When every visible skill is bundled, the budget cannot force degradation:
    // bundled skills keep full descriptions even if the result overflows.
    const b1 = testSpecScoped("alpha", "A" ** 100, "", .builtin);
    const b2 = testSpecScoped("bravo", "B" ** 100, "", .builtin);
    const in = [_]SkillSpec{ b1, b2 };

    // Budget far smaller than the full listing.
    const r = try render(testing.allocator, &in, 40);
    defer testing.allocator.free(r);

    // Both full descriptions preserved despite the tiny budget.
    try testing.expect(std.mem.indexOf(u8, r, "A" ** 100) != null);
    try testing.expect(std.mem.indexOf(u8, r, "B" ** 100) != null);
}
