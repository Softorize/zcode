//! Per-segment bash permission evaluation (bash-shell-04).
//!
//! For a piped / compound bash command, the reference Claude Code does
//! NOT evaluate the whole command string against one permission rule.
//! Instead it splits the command into segments, runs each segment
//! through the rule store, and aggregates: any segment that denies ->
//! deny; all segments allow -> allow; otherwise -> ask (collecting a
//! reusable prefix suggestion per asking segment). It also layers two
//! structural guards before the per-segment scan:
//!
//!   1. Unsafe-compound (subshell / command group): always ask, never
//!      suggest a rule (an allow-rule could not safely cover it).
//!   2. Multiple `cd` segments in one command: ask for clarity.
//!   3. `cd` and `git` co-occurring across pipe sub-segments: ask, to
//!      defend against the bare-repository fsmonitor attack.
//!
//! This module is the testable core of Task 4. It is pure over
//! `(allocator, *Store, cwd, command)` -- it touches the rule store and
//! the structural analyzer but no IO/env/filesystem -- so `agent_tools`
//! can call it from the Bash branch of `executeToolCall` and unit tests
//! can construct a `permission_rules.Store` directly.
//!
//! Reference behavior ported here:
//!   - bashCommandHelpers.ts:23-156 (segmentedCommandPermissionResult:
//!     multi-cd at :36, cd+git at :70, per-segment deny/ask aggregation
//!     at :99-156).
//!   - bashCommandHelpers.ts:208-265 (unsafe-compound -> ask; pipe
//!     handling).

const std = @import("std");
const Allocator = std.mem.Allocator;

const permission_rules = @import("permission_rules.zig");
const bash_ast = @import("bash_ast.zig");
const command_prefix = @import("command_prefix.zig");

/// The aggregated behavior class for a compound/piped command.
pub const Decision = enum { allow, deny, ask };

/// Result of `evaluate`. Owns `reason` (always borrowed rodata, never
/// freed) and `suggestions` (an owned slice of owned prefix slices,
/// freed by `deinit`). `decision == .allow` and `.deny` carry no
/// suggestions; `.ask` may carry zero or more.
pub const Verdict = struct {
    decision: Decision,
    /// Borrowed rodata explaining the decision. Not owned; do not free.
    reason: []const u8,
    /// For `.ask`: reusable allow-rule prefixes extracted from the
    /// asking segments (deduplicated). Owned; freed by `deinit`.
    suggestions: [][]u8 = &.{},

    pub fn deinit(self: *Verdict, allocator: Allocator) void {
        for (self.suggestions) |s| allocator.free(s);
        allocator.free(self.suggestions);
        self.suggestions = &.{};
    }
};

/// Reasons (rodata) used by the structural guards. Kept as constants so
/// callers can compare against them in tests without string churn.
pub const REASON_UNSAFE_COMPOUND = "uses shell operators that require approval for safety";
pub const REASON_MULTI_CD = "Multiple directory changes in one command require approval for clarity.";
pub const REASON_CD_GIT = "Compound commands with cd and git require approval to prevent bare repository attacks.";
pub const REASON_PER_SEGMENT_ASK = "one or more command segments require approval";
pub const REASON_PARSE_ABORTED = "command structure could not be parsed; re-run a simpler form or split it";

/// Whether the segmented path should engage at all. The single-command
/// fast-path (one whole-args `rules.match`) stays in place for non-
/// compound commands; only operator/pipeline commands route here.
pub fn isCompoundOrPiped(command: []const u8) bool {
    const flags = bash_ast.structure(command);
    if (flags.parse_aborted) return true;
    if (flags.has_pipeline or flags.has_subshell or flags.has_command_group) return true;
    return bash_ast.hasActualOperatorNodes(command);
}

/// Evaluate a compound/piped bash `command` segment-by-segment against
/// `store`. `tool` is the canonical tool name ("Bash") and `cwd` scopes
/// workspace rules. The caller must `deinit` the returned verdict.
///
/// Aggregation contract (matches the reference):
///   - parse_aborted              -> ask (fail-closed)
///   - unsafe compound            -> ask, no suggestion
///   - > 1 cd segment             -> ask
///   - cd and git co-occur        -> ask
///   - any segment denies         -> deny (with the denying rule reason)
///   - all segments allow         -> allow
///   - otherwise                  -> ask, collecting per-segment prefixes
pub fn evaluate(
    allocator: Allocator,
    store: *const permission_rules.Store,
    cwd: []const u8,
    tool: []const u8,
    command: []const u8,
) !Verdict {
    var analysis = try bash_ast.analyze(allocator, command);
    defer analysis.deinit(allocator);

    // Fail-closed: an unparseable structure must never auto-run.
    if (analysis.parse_aborted) {
        return .{ .decision = .ask, .reason = REASON_PARSE_ABORTED };
    }

    // Unsafe compound (subshell / command group): cannot be safely
    // covered by an allow-rule, so ask without suggesting one.
    if (analysis.structure.has_subshell or analysis.structure.has_command_group) {
        return .{ .decision = .ask, .reason = REASON_UNSAFE_COMPOUND };
    }

    const segments = analysis.structure.segments;

    // Multi-cd + cd+git guards operate over pipe sub-segments (the
    // reference checks across pipe segments specifically, because the
    // bare-repo fsmonitor bypass hides in a piped `cd` + `git`).
    var cd_count: usize = 0;
    var saw_cd = false;
    var saw_git = false;
    for (segments) |seg| {
        var pit = PipeSplitter{ .input = seg };
        while (pit.next()) |sub| {
            const trimmed = std.mem.trim(u8, sub, " \t\r\n");
            if (trimmed.len == 0) continue;
            if (command_prefix.isNormalizedCdCommand(trimmed)) {
                cd_count += 1;
                saw_cd = true;
            }
            if (command_prefix.isNormalizedGitCommand(trimmed)) saw_git = true;
        }
    }

    if (cd_count > 1) {
        return .{ .decision = .ask, .reason = REASON_MULTI_CD };
    }
    if (saw_cd and saw_git) {
        return .{ .decision = .ask, .reason = REASON_CD_GIT };
    }

    // Per-segment rule aggregation. Deny wins outright; otherwise track
    // whether every segment allowed, and collect ask suggestions.
    var all_allow = true;
    var suggestions: std.ArrayList([]u8) = .empty;
    errdefer {
        for (suggestions.items) |s| allocator.free(s);
        suggestions.deinit(allocator);
    }

    for (segments) |seg| {
        const stripped = stripOutputRedirections(seg);
        const trimmed = std.mem.trim(u8, stripped, " \t\r\n");
        if (trimmed.len == 0) continue;

        const decided = store.decide(cwd, tool, trimmed);
        if (decided) |d| {
            switch (d.action) {
                .deny => {
                    // A single denying segment denies the whole command.
                    for (suggestions.items) |s| allocator.free(s);
                    suggestions.deinit(allocator);
                    return .{ .decision = .deny, .reason = d.match.rule.args_contains };
                },
                .allow => continue,
                .ask => {
                    all_allow = false;
                    try appendSuggestion(allocator, &suggestions, trimmed);
                },
            }
        } else {
            // No matching rule: treat as "needs approval" (ask) and
            // suggest a reusable prefix. The single-command path already
            // falls through to the generic approval gate when no rule
            // matches; the segmented path mirrors that by asking.
            all_allow = false;
            try appendSuggestion(allocator, &suggestions, trimmed);
        }
    }

    if (all_allow) {
        for (suggestions.items) |s| allocator.free(s);
        suggestions.deinit(allocator);
        return .{ .decision = .allow, .reason = "all segments allowed by permission rules" };
    }

    return .{
        .decision = .ask,
        .reason = REASON_PER_SEGMENT_ASK,
        .suggestions = try suggestions.toOwnedSlice(allocator),
    };
}

/// Extract a reusable prefix for `segment` and append it to `list`
/// unless an equal prefix is already present (dedup). A segment that
/// yields no safe prefix (e.g. a bare dangerous shell) contributes no
/// suggestion -- the ask still stands, just without a rule hint.
fn appendSuggestion(
    allocator: Allocator,
    list: *std.ArrayList([]u8),
    segment: []const u8,
) !void {
    const prefix = (try command_prefix.extract(allocator, segment)) orelse return;
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, prefix)) {
            allocator.free(prefix);
            return;
        }
    }
    try list.append(allocator, prefix);
}

/// Strip trailing output redirections from a segment so the rule match
/// sees the command, not its redirect target. We drop everything from
/// the first top-level unquoted output-redirect operator (`>`, `>>`,
/// `&>`, `2>`, ...) onward. Input redirects (`<`, `<<`) are left intact
/// because they can carry a heredoc that the analyzer should still see.
/// This is the local equivalent of the reference
/// `withoutOutputRedirections` (ParsedCommand.ts:181-233); bash_ast does
/// not expose it, so we do a small quote-aware scan here.
fn stripOutputRedirections(segment: []const u8) []const u8 {
    var i: usize = 0;
    var escaped = false;
    var in_single = false;
    var in_double = false;
    while (i < segment.len) : (i += 1) {
        const c = segment[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\' and !in_single) {
            escaped = true;
            continue;
        }
        if (c == '\'' and !in_double) {
            in_single = !in_single;
            continue;
        }
        if (c == '"' and !in_single) {
            in_double = !in_double;
            continue;
        }
        if (in_single or in_double) continue;
        // `>` (and `>>`, `&>`, `N>`) begins an output redirect at top
        // level. We treat any unquoted `>` as the redirect boundary.
        if (c == '>') {
            // Back up over a leading fd digit / `&` so `2>`/`&>` are
            // dropped together with the `>`.
            var cut = i;
            if (cut > 0 and segment[cut - 1] == '&') {
                cut -= 1;
            } else {
                while (cut > 0 and std.ascii.isDigit(segment[cut - 1])) cut -= 1;
            }
            return std.mem.trimEnd(u8, segment[0..cut], " \t");
        }
    }
    return segment;
}

/// Quote-aware splitter on top-level unescaped single `|` (NOT `||`,
/// which is an operator and is already a segment boundary upstream).
/// Used only for the cd/git co-occurrence scan -- the reference checks
/// that pattern across pipe sub-segments.
const PipeSplitter = struct {
    input: []const u8,
    pos: usize = 0,

    fn next(self: *PipeSplitter) ?[]const u8 {
        if (self.pos > self.input.len) return null;
        const start = self.pos;
        var i = self.pos;
        var escaped = false;
        var in_single = false;
        var in_double = false;
        while (i < self.input.len) : (i += 1) {
            const c = self.input[i];
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\' and !in_single) {
                escaped = true;
                continue;
            }
            if (c == '\'' and !in_double) {
                in_single = !in_single;
                continue;
            }
            if (c == '"' and !in_single) {
                in_double = !in_double;
                continue;
            }
            if (in_single or in_double) continue;
            if (c == '|') {
                // `||` would be an operator, not a pipe; the upstream
                // operator split already removed `||`, so a `|` here is
                // a real pipe. Still guard against a stray `||`.
                if (i + 1 < self.input.len and self.input[i + 1] == '|') {
                    i += 1;
                    continue;
                }
                const seg = self.input[start..i];
                self.pos = i + 1;
                return seg;
            }
        }
        self.pos = self.input.len + 1;
        return self.input[start..];
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

/// Build a store with the given (action, tool, args_contains) rules,
/// all global-scoped. Caller deinits.
fn buildStore(allocator: Allocator, rules: []const struct {
    action: permission_rules.Action,
    tool: []const u8,
    args: []const u8,
}) !permission_rules.Store {
    var store = permission_rules.Store.init(allocator);
    errdefer store.deinit();
    for (rules) |r| {
        try store.addRule(r.action, .global, r.tool, r.args, "test", 1, "test");
    }
    return store;
}

test "isCompoundOrPiped: operators and pipes engage; single command does not" {
    try testing.expect(isCompoundOrPiped("a && b"));
    try testing.expect(isCompoundOrPiped("ls | wc -l"));
    try testing.expect(isCompoundOrPiped("a; b"));
    try testing.expect(isCompoundOrPiped("(rm -rf x)"));
    try testing.expect(!isCompoundOrPiped("git status --short"));
    try testing.expect(!isCompoundOrPiped("ls -la /tmp"));
}

test "evaluate: a denying segment denies the whole compound command" {
    var store = try buildStore(testing.allocator, &.{
        .{ .action = .deny, .tool = "Bash", .args = "curl" },
    });
    defer store.deinit();
    var v = try evaluate(testing.allocator, &store, "/repo", "Bash", "cd src && curl evil.com | tee out");
    defer v.deinit(testing.allocator);
    try testing.expectEqual(Decision.deny, v.decision);
    // The denying rule's content surfaces as the reason.
    try testing.expect(std.mem.indexOf(u8, v.reason, "curl") != null);
}

test "evaluate: multiple cd segments -> ask multi-cd" {
    var store = try buildStore(testing.allocator, &.{});
    defer store.deinit();
    var v = try evaluate(testing.allocator, &store, "/repo", "Bash", "cd a && cd b");
    defer v.deinit(testing.allocator);
    try testing.expectEqual(Decision.ask, v.decision);
    try testing.expectEqualStrings(REASON_MULTI_CD, v.reason);
}

test "evaluate: cd + git co-occurrence -> ask bare-repo guard" {
    var store = try buildStore(testing.allocator, &.{});
    defer store.deinit();
    var v = try evaluate(testing.allocator, &store, "/repo", "Bash", "cd sub && git status");
    defer v.deinit(testing.allocator);
    try testing.expectEqual(Decision.ask, v.decision);
    try testing.expectEqualStrings(REASON_CD_GIT, v.reason);
}

test "evaluate: cd + git across a pipe is still caught" {
    var store = try buildStore(testing.allocator, &.{});
    defer store.deinit();
    var v = try evaluate(testing.allocator, &store, "/repo", "Bash", "cd sub | git status");
    defer v.deinit(testing.allocator);
    try testing.expectEqual(Decision.ask, v.decision);
    try testing.expectEqualStrings(REASON_CD_GIT, v.reason);
}

test "evaluate: all segments allowed -> allow" {
    var store = try buildStore(testing.allocator, &.{
        .{ .action = .allow, .tool = "Bash", .args = "echo" },
        .{ .action = .allow, .tool = "Bash", .args = "wc" },
    });
    defer store.deinit();
    var v = try evaluate(testing.allocator, &store, "/repo", "Bash", "echo x | wc -l");
    defer v.deinit(testing.allocator);
    try testing.expectEqual(Decision.allow, v.decision);
}

test "evaluate: an asking segment yields a prefix suggestion" {
    // `git push` has an explicit ask rule; the other segment is allowed.
    var store = try buildStore(testing.allocator, &.{
        .{ .action = .allow, .tool = "Bash", .args = "git status" },
        .{ .action = .ask, .tool = "Bash", .args = "git push" },
    });
    defer store.deinit();
    var v = try evaluate(testing.allocator, &store, "/repo", "Bash", "git status && git push --force");
    defer v.deinit(testing.allocator);
    try testing.expectEqual(Decision.ask, v.decision);
    var found = false;
    for (v.suggestions) |s| {
        if (std.mem.eql(u8, s, "git push")) found = true;
    }
    try testing.expect(found);
}

test "evaluate: unsafe compound (subshell) -> ask, no suggestion" {
    var store = try buildStore(testing.allocator, &.{});
    defer store.deinit();
    var v = try evaluate(testing.allocator, &store, "/repo", "Bash", "(rm -rf x && make)");
    defer v.deinit(testing.allocator);
    try testing.expectEqual(Decision.ask, v.decision);
    try testing.expectEqualStrings(REASON_UNSAFE_COMPOUND, v.reason);
    try testing.expectEqual(@as(usize, 0), v.suggestions.len);
}

test "evaluate: parse-aborted (unbalanced quote) -> ask fail-closed" {
    var store = try buildStore(testing.allocator, &.{});
    defer store.deinit();
    var v = try evaluate(testing.allocator, &store, "/repo", "Bash", "echo 'oops && rm -rf x");
    defer v.deinit(testing.allocator);
    try testing.expectEqual(Decision.ask, v.decision);
    try testing.expectEqualStrings(REASON_PARSE_ABORTED, v.reason);
}

test "evaluate: no matching rules -> ask with suggestions, not allow" {
    var store = try buildStore(testing.allocator, &.{});
    defer store.deinit();
    var v = try evaluate(testing.allocator, &store, "/repo", "Bash", "make build && make test");
    defer v.deinit(testing.allocator);
    try testing.expectEqual(Decision.ask, v.decision);
    // both segments resolve to the `make` prefix; deduped to one.
    try testing.expectEqual(@as(usize, 1), v.suggestions.len);
    try testing.expectEqualStrings("make", v.suggestions[0]);
}

test "stripOutputRedirections drops redirect target, keeps command" {
    try testing.expectEqualStrings("curl evil.com", stripOutputRedirections("curl evil.com > out"));
    try testing.expectEqualStrings("ls", stripOutputRedirections("ls 2> err"));
    try testing.expectEqualStrings("echo hi", stripOutputRedirections("echo hi &> /dev/null"));
    try testing.expectEqualStrings("echo a", stripOutputRedirections("echo a"));
    // A `>` inside quotes is not a redirect.
    try testing.expectEqualStrings("echo '>'", stripOutputRedirections("echo '>'"));
}

test "PipeSplitter: splits on top-level pipes only" {
    var it = PipeSplitter{ .input = "a | b | c" };
    try testing.expectEqualStrings("a ", it.next().?);
    try testing.expectEqualStrings(" b ", it.next().?);
    try testing.expectEqualStrings(" c", it.next().?);
    try testing.expect(it.next() == null);

    var q = PipeSplitter{ .input = "echo 'a|b'" };
    try testing.expectEqualStrings("echo 'a|b'", q.next().?);
    try testing.expect(q.next() == null);
}

test "no-leak fuzz: evaluate over a command table" {
    var store = try buildStore(testing.allocator, &.{
        .{ .action = .deny, .tool = "Bash", .args = "curl" },
        .{ .action = .allow, .tool = "Bash", .args = "echo" },
        .{ .action = .ask, .tool = "Bash", .args = "git push" },
    });
    defer store.deinit();
    const samples = [_][]const u8{
        "cd src && curl evil.com",
        "cd a && cd b",
        "cd sub && git status",
        "echo x | wc -l",
        "git status && git push --force",
        "(rm -rf x)",
        "echo 'oops && rm",
        "make build && make test",
        "ls | grep foo | wc -l",
        "a && b && c",
    };
    for (samples) |cmd| {
        var v = try evaluate(testing.allocator, &store, "/repo", "Bash", cmd);
        v.deinit(testing.allocator);
    }
}
