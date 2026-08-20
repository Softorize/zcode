//! P7 (PRD #534) tips registry. Claude Code surfaces rotating usage tips; zcode
//! had context suggestions but no curated tip registry.
//!
//! Phase 14.12: each tip now carries an id, a per-tip cooldown (in startup
//! sessions), and an optional relevance predicate over a small `TipContext`.
//! `getRelevantTips` filters the registry by relevance AND by the persisted
//! tip history (sessions-since-last-shown >= cooldown), mirroring the
//! reference's `getRelevantTips` (tipRegistry.ts:668-686, tipHistory.ts:3-17).
//!
//! The registry itself stays comptime-static; only the history/state is
//! runtime. The legacy `at`/`pick`/`next` selectors are kept for the on-demand
//! `/tips` command (they operate over the tip text).

const std = @import("std");
const runtime_state = @import("runtime_state.zig");

/// The small set of cheap signals tip relevance predicates may consult. Only
/// signals zcode can populate without extra IO at selection time belong here.
pub const TipContext = struct {
    /// Whether the current workspace is a git repository.
    is_git_repo: bool = false,
    /// Whether the workspace has an instruction file (ZCODE.md / CLAUDE.md).
    has_instruction_file: bool = false,
    /// Whether the editor is in vim mode.
    vim_mode: bool = false,
};

/// A relevance predicate. `null` means "always relevant".
pub const RelevantFn = *const fn (TipContext) bool;

/// A curated tip. `text` is the one-line message; `id` is a stable key for the
/// history store; `cooldown_sessions` is how many startups must elapse before
/// the tip is eligible again; `relevant` gates the tip on the context.
pub const Tip = struct {
    id: []const u8,
    text: []const u8,
    cooldown_sessions: u64 = 3,
    relevant: ?RelevantFn = null,
};

fn relevantIfNoInstructionFile(ctx: TipContext) bool {
    return !ctx.has_instruction_file;
}

/// Curated one-line tips about zcode / Claude Code-parity features. Comptime
/// static. The default cooldown (3 startups) keeps any single tip from
/// repeating back-to-back; most tips are always relevant (`relevant == null`).
pub const registry = [_]Tip{
    .{ .id = "model", .text = "Type /model to switch provider/model, or /model current to see the active one." },
    .{ .id = "effort", .text = "Set thinking depth with /effort <low|medium|high|max>; /effort auto disables extended thinking." },
    .{ .id = "permission-modes", .text = "Permission modes: default, acceptEdits, plan, bypassPermissions, dontAsk - set the approval mode to match how much autonomy you want." },
    .{ .id = "permission-rules", .text = "Add allow/deny/ask rules like Bash(git *) so trusted commands run without prompting." },
    .{ .id = "hooks", .text = "Drop a hook in ~/.zcode/hooks or settings.json (PreToolUse, PostToolUse, ...) to run scripts around tool calls." },
    .{ .id = "skills", .text = "Skills live in .zcode/skills and ~/.zcode/skills; run one with /skill <name> or let the model invoke it." },
    .{ .id = "compact", .text = "/compact summarizes the conversation to free context; it happens automatically as you approach the limit." },
    .{ .id = "rewind", .text = "/rewind restores the conversation to an earlier turn when a direction went wrong." },
    .{ .id = "resume", .text = "Resume past work with /resume; export a transcript with `session export <id> md` for a readable Markdown copy." },
    .{ .id = "mcp", .text = "MCP servers extend zcode with extra tools - manage them with /mcp." },
    .{ .id = "at-mention", .text = "Use @file mentions in your prompt to pull a file into context quickly." },
    .{ .id = "context", .text = "/context shows what is currently loaded into the model's context window." },
    // Surface the instruction-file tip only when the project has none yet.
    .{ .id = "init", .text = "Run /init to generate a ZCODE.md so the agent learns your project conventions.", .cooldown_sessions = 10, .relevant = relevantIfNoInstructionFile },
};

pub fn count() usize {
    return registry.len;
}

/// Parse the user's `spinner_tips_custom` config value into `Tip`s
/// (styles-onboarding-07 / the reference's `spinnerTipsOverride.tips`). The
/// value is delimited on newlines first, then on ';' so a single-line value
/// also works. Each non-empty, trimmed entry becomes an always-relevant,
/// cooldown-0 tip (custom tips always satisfy any cooldown, matching the
/// reference's "always-relevant cooldown-0" custom tips). Ids are
/// "custom-<index>".
///
/// Allocates: both the returned slice AND each tip's `id` are owned by the
/// caller; the `text` points into `raw` (no copy). Free with `freeCustomTips`.
pub fn parseCustomTips(allocator: std.mem.Allocator, raw: []const u8) ![]Tip {
    var out: std.ArrayListUnmanaged(Tip) = .empty;
    errdefer freeCustomTips(allocator, out.items);
    var index: usize = 0;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.splitScalar(u8, line, ';');
        while (parts.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t\r");
            if (trimmed.len == 0) continue;
            const id = try std.fmt.allocPrint(allocator, "custom-{d}", .{index});
            errdefer allocator.free(id);
            try out.append(allocator, .{
                .id = id,
                .text = trimmed,
                .cooldown_sessions = 0,
                .relevant = null,
            });
            index += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Free a slice produced by `parseCustomTips`: each tip's allocated `id`, then
/// the slice itself. The `text` is not freed (it points into the caller's raw
/// config string).
pub fn freeCustomTips(allocator: std.mem.Allocator, tips: []const Tip) void {
    for (tips) |tip| allocator.free(tip.id);
    allocator.free(tips);
}

/// Build the effective spinner-tip list for the given config
/// (styles-onboarding-07). When `exclude_default` is true the built-in registry
/// is suppressed and only the parsed custom tips remain; otherwise the result
/// is the built-in registry followed by the custom tips. The unfiltered list is
/// returned (relevance/cooldown filtering happens in `getRelevantTips`).
///
/// Allocates the returned slice. Custom tips carry allocated ids; free the
/// whole result with `freeEffectiveTips`.
pub fn effectiveTips(
    allocator: std.mem.Allocator,
    exclude_default: bool,
    custom_raw: []const u8,
) ![]Tip {
    const custom = try parseCustomTips(allocator, custom_raw);
    errdefer freeCustomTips(allocator, custom);

    var out: std.ArrayListUnmanaged(Tip) = .empty;
    errdefer out.deinit(allocator);
    if (!exclude_default) {
        try out.appendSlice(allocator, &registry);
    }
    try out.appendSlice(allocator, custom);
    // The custom slice's backing array is no longer needed (its tips were
    // copied into `out`); free the slice but NOT the ids, which `out` now owns.
    allocator.free(custom);
    return out.toOwnedSlice(allocator);
}

/// Free a slice produced by `effectiveTips`. Frees the allocated ids of any
/// custom tips (their ids start with "custom-") and then the slice. Built-in
/// registry tips have comptime-static ids and are not freed.
pub fn freeEffectiveTips(allocator: std.mem.Allocator, tips: []const Tip) void {
    for (tips) |tip| {
        if (std.mem.startsWith(u8, tip.id, "custom-")) allocator.free(tip.id);
    }
    allocator.free(tips);
}

/// Tip text at `index`, wrapping around the registry so any index is valid.
pub fn at(index: usize) []const u8 {
    return registry[index % registry.len].text;
}

/// Deterministic pick from a seed (e.g. a timestamp or session counter).
/// Returns the tip text.
pub fn pick(seed: u64) []const u8 {
    return registry[@intCast(seed % registry.len)].text;
}

/// Next index after `current`, wrapping. Use for rotation across sessions.
pub fn next(current: usize) usize {
    return (current + 1) % registry.len;
}

/// Tips eligible to show given the loaded `state` and `context`. A tip is
/// eligible when its relevance predicate passes (or is null) AND the sessions
/// elapsed since it was last shown is at least its cooldown. A never-shown tip
/// reports `NEVER_SHOWN` sessions-since, which satisfies any cooldown.
///
/// IO-free: takes the already-loaded `state` so it is trivially testable. The
/// returned slice is owned by the caller (free with `allocator.free`); the
/// `Tip` values themselves point into the comptime-static registry.
pub fn getRelevantTips(
    allocator: std.mem.Allocator,
    state: *const runtime_state.State,
    context: TipContext,
) ![]Tip {
    return filterRelevant(allocator, &registry, state, context);
}

/// Pure relevance/cooldown filter over a caller-supplied `tips` slice. A tip is
/// eligible when its relevance predicate passes (or is null) AND the sessions
/// elapsed since it was last shown is at least its cooldown. IO-free: takes the
/// already-loaded `state` and an explicit tip slice so it is trivially testable
/// over both the built-in registry and the effective (registry + custom) list.
///
/// The returned slice is owned by the caller (free with `allocator.free`); the
/// `Tip` values are copied by value from `tips` (their `id`/`text` still point
/// at the original storage).
pub fn filterRelevant(
    allocator: std.mem.Allocator,
    tips: []const Tip,
    state: *const runtime_state.State,
    context: TipContext,
) ![]Tip {
    var out: std.ArrayListUnmanaged(Tip) = .empty;
    errdefer out.deinit(allocator);
    for (tips) |tip| {
        if (tip.relevant) |pred| {
            if (!pred(context)) continue;
        }
        if (runtime_state.sessionsSinceTipShown(state, tip.id) < tip.cooldown_sessions) continue;
        try out.append(allocator, tip);
    }
    return out.toOwnedSlice(allocator);
}

/// Pick the tip with the longest sessions-since-last-shown from `tips`, breaking
/// ties toward the earliest entry (stable). Returns null when `tips` is empty.
/// Mirrors the reference `selectTipWithLongestTimeSinceShown`
/// (tipScheduler.ts:10-58): the candidate list is already relevance/cooldown
/// filtered (see `getRelevantTips`); this just maximizes sessions-since so the
/// least-recently-seen tip surfaces first.
///
/// IO-free: takes the already-loaded `state` so it is trivially testable.
pub fn selectLongestSinceShown(tips: []const Tip, state: *const runtime_state.State) ?Tip {
    if (tips.len == 0) return null;
    var best: Tip = tips[0];
    var best_since: u64 = runtime_state.sessionsSinceTipShown(state, tips[0].id);
    for (tips[1..]) |tip| {
        const since = runtime_state.sessionsSinceTipShown(state, tip.id);
        if (since > best_since) {
            best = tip;
            best_since = since;
        }
    }
    return best;
}

/// The tip to show on the working spinner this turn, or null when spinner tips
/// are disabled or no relevant tip is eligible. Combines relevance/cooldown
/// filtering (`getRelevantTips`) with longest-since-shown selection
/// (`selectLongestSinceShown`), mirroring `getTipToShowOnSpinner`
/// (tipScheduler.ts:31-58).
///
/// `spinner_tips_enabled` is passed explicitly (rather than the whole config)
/// so this function carries no compile dependency on the config surface and
/// stays trivially unit-testable. The caller, not this function, records the
/// returned tip as shown (once per turn) via `runtime_state.recordTipShown`.
pub fn getTipToShowOnSpinner(
    allocator: std.mem.Allocator,
    spinner_tips_enabled: bool,
    state: *const runtime_state.State,
    context: TipContext,
) ?Tip {
    return getTipToShowOnSpinnerWithConfig(allocator, spinner_tips_enabled, false, "", state, context);
}

/// Spinner-tip selection honoring the user's `spinnerTipsOverride`
/// (styles-onboarding-07). Builds the effective tip list
/// (`exclude_default ? [] : registry` ++ parsed custom tips), filters by
/// relevance/cooldown, and selects the longest-since-shown. Returns null when
/// `spinner_tips_enabled` is false or no relevant tip is eligible.
///
/// The returned `Tip` (if any) is safe to outlive this call: its `text` points
/// either into the comptime registry or into the caller-owned `custom_raw`
/// string, and its `id` is normalized to a static literal ("custom" for custom
/// tips, the comptime registry id otherwise) so it never dangles after the
/// internally-allocated effective list is freed.
pub fn getTipToShowOnSpinnerWithConfig(
    allocator: std.mem.Allocator,
    spinner_tips_enabled: bool,
    exclude_default: bool,
    custom_raw: []const u8,
    state: *const runtime_state.State,
    context: TipContext,
) ?Tip {
    if (!spinner_tips_enabled) return null;
    const effective = effectiveTips(allocator, exclude_default, custom_raw) catch return null;
    defer freeEffectiveTips(allocator, effective);
    const relevant = filterRelevant(allocator, effective, state, context) catch return null;
    defer allocator.free(relevant);
    const chosen = selectLongestSinceShown(relevant, state) orelse return null;
    // Normalize a custom tip's allocated id to a static literal so the returned
    // tip stays valid after `effective` is freed. The caller uses `text` to
    // render and `id` to record-as-shown; custom tips are cooldown-0 so a
    // shared "custom" history key is harmless (they are always eligible).
    if (std.mem.startsWith(u8, chosen.id, "custom-")) {
        return .{ .id = "custom", .text = chosen.text, .cooldown_sessions = 0, .relevant = null };
    }
    return chosen;
}

const testing = std.testing;

test "registry is non-empty and indexing wraps" {
    try testing.expect(count() > 0);
    try testing.expectEqualStrings(registry[0].text, at(0));
    try testing.expectEqualStrings(registry[0].text, at(registry.len)); // wraps
    try testing.expectEqualStrings(registry[1].text, at(registry.len + 1));
}

test "pick is deterministic and in range" {
    try testing.expectEqualStrings(pick(0), pick(0));
    try testing.expectEqualStrings(registry[3 % registry.len].text, pick(3));
}

test "next rotates and wraps" {
    try testing.expectEqual(@as(usize, 1), next(0));
    try testing.expectEqual(@as(usize, 0), next(registry.len - 1));
}

test "tip on cooldown is excluded then re-included after cooldown elapses" {
    var state = runtime_state.State.empty(testing.allocator);
    defer state.deinit();
    // The "model" tip uses the default cooldown of 3. Shown at startup 5.
    try state.tips_history.put(state.arena.allocator(), "model", 5);

    // Startup 6: only 1 session since shown (< 3) -> excluded.
    state.num_startups = 6;
    {
        const tips = try getRelevantTips(testing.allocator, &state, .{});
        defer testing.allocator.free(tips);
        try testing.expect(!containsId(tips, "model"));
    }
    // Startup 7: 2 sessions since shown (< 3) -> still excluded.
    state.num_startups = 7;
    {
        const tips = try getRelevantTips(testing.allocator, &state, .{});
        defer testing.allocator.free(tips);
        try testing.expect(!containsId(tips, "model"));
    }
    // Startup 8: 3 sessions since shown (>= 3) -> included again.
    state.num_startups = 8;
    {
        const tips = try getRelevantTips(testing.allocator, &state, .{});
        defer testing.allocator.free(tips);
        try testing.expect(containsId(tips, "model"));
    }
}

test "tip with a false relevance predicate is excluded regardless of cooldown" {
    var state = runtime_state.State.empty(testing.allocator);
    defer state.deinit();
    // The "init" tip is relevant only when there is no instruction file. With
    // an instruction file present it must be excluded even though it has never
    // been shown (cooldown trivially satisfied).
    state.num_startups = 100;

    const with_file = try getRelevantTips(testing.allocator, &state, .{ .has_instruction_file = true });
    defer testing.allocator.free(with_file);
    try testing.expect(!containsId(with_file, "init"));

    const without_file = try getRelevantTips(testing.allocator, &state, .{ .has_instruction_file = false });
    defer testing.allocator.free(without_file);
    try testing.expect(containsId(without_file, "init"));
}

test "never-shown tip is always included (cooldown satisfied)" {
    var state = runtime_state.State.empty(testing.allocator);
    defer state.deinit();
    state.num_startups = 50;
    // No tips recorded -> every always-relevant tip is eligible.
    const tips = try getRelevantTips(testing.allocator, &state, .{});
    defer testing.allocator.free(tips);
    try testing.expect(containsId(tips, "model"));
    try testing.expect(containsId(tips, "compact"));
}

fn containsId(tips: []const Tip, id: []const u8) bool {
    for (tips) |tip| {
        if (std.mem.eql(u8, tip.id, id)) return true;
    }
    return false;
}

test "selectLongestSinceShown picks the tip with the most sessions-since-shown" {
    var state = runtime_state.State.empty(testing.allocator);
    defer state.deinit();
    // num_startups = 20; sessions-since = num_startups - shown_at.
    // Want sessions-since [2, 9, 4] -> shown_at [18, 11, 16].
    state.num_startups = 20;
    const a = state.arena.allocator();
    try state.tips_history.put(a, "a", 18); // since = 2
    try state.tips_history.put(a, "b", 11); // since = 9
    try state.tips_history.put(a, "c", 16); // since = 4

    const tips = [_]Tip{
        .{ .id = "a", .text = "A" },
        .{ .id = "b", .text = "B" },
        .{ .id = "c", .text = "C" },
    };
    const chosen = selectLongestSinceShown(&tips, &state);
    try testing.expect(chosen != null);
    try testing.expectEqualStrings("b", chosen.?.id); // index-1, sessions-since 9
}

test "selectLongestSinceShown returns null for an empty candidate list" {
    var state = runtime_state.State.empty(testing.allocator);
    defer state.deinit();
    state.num_startups = 5;
    const empty: []const Tip = &.{};
    try testing.expect(selectLongestSinceShown(empty, &state) == null);
}

test "getTipToShowOnSpinner returns null when spinner tips are disabled" {
    var state = runtime_state.State.empty(testing.allocator);
    defer state.deinit();
    state.num_startups = 50;
    // Even with eligible tips, the disabled flag short-circuits to null.
    try testing.expect(getTipToShowOnSpinner(testing.allocator, false, &state, .{}) == null);
}

test "getTipToShowOnSpinner returns a tip when enabled and a relevant tip exists" {
    var state = runtime_state.State.empty(testing.allocator);
    defer state.deinit();
    state.num_startups = 50;
    // No tips recorded -> every always-relevant tip is eligible, all with
    // NEVER_SHOWN sessions-since, so the first eligible tip is selected.
    const chosen = getTipToShowOnSpinner(testing.allocator, true, &state, .{});
    try testing.expect(chosen != null);
}

test "parseCustomTips splits on newlines and semicolons, skipping blanks" {
    const tips = try parseCustomTips(testing.allocator, "  one  ;two\n\n; three ;");
    defer freeCustomTips(testing.allocator, tips);
    try testing.expectEqual(@as(usize, 3), tips.len);
    try testing.expectEqualStrings("one", tips[0].text);
    try testing.expectEqualStrings("two", tips[1].text);
    try testing.expectEqualStrings("three", tips[2].text);
    // Custom tips are always-relevant and cooldown-0.
    for (tips) |tip| {
        try testing.expectEqual(@as(u64, 0), tip.cooldown_sessions);
        try testing.expect(tip.relevant == null);
        try testing.expect(std.mem.startsWith(u8, tip.id, "custom-"));
    }
}

test "effectiveTips with exclude_default true yields only the custom tips" {
    const tips = try effectiveTips(testing.allocator, true, "alpha;beta");
    defer freeEffectiveTips(testing.allocator, tips);
    try testing.expectEqual(@as(usize, 2), tips.len);
    try testing.expectEqualStrings("alpha", tips[0].text);
    try testing.expectEqualStrings("beta", tips[1].text);
}

test "effectiveTips with exclude_default false yields registry plus custom tips" {
    const tips = try effectiveTips(testing.allocator, false, "only-custom");
    defer freeEffectiveTips(testing.allocator, tips);
    try testing.expectEqual(registry.len + 1, tips.len);
    // The custom tip is appended after the built-in registry.
    try testing.expectEqualStrings("only-custom", tips[tips.len - 1].text);
}

test "effectiveTips with no custom tips and exclude_default false is just the registry" {
    const tips = try effectiveTips(testing.allocator, false, "");
    defer freeEffectiveTips(testing.allocator, tips);
    try testing.expectEqual(registry.len, tips.len);
}

test "getTipToShowOnSpinnerWithConfig surfaces a custom tip with a stable id" {
    var state = runtime_state.State.empty(testing.allocator);
    defer state.deinit();
    state.num_startups = 1;
    // Exclude defaults so only the single custom tip is eligible; it is
    // always-relevant and cooldown-0, so it is selected.
    const chosen = getTipToShowOnSpinnerWithConfig(testing.allocator, true, true, "my custom tip", &state, .{});
    try testing.expect(chosen != null);
    try testing.expectEqualStrings("my custom tip", chosen.?.text);
    // The returned id is the static "custom" literal (no dangling allocation).
    try testing.expectEqualStrings("custom", chosen.?.id);
}
