//! Shadowed / unreachable permission-rule detection.
//!
//! A content-keyed allow rule (one with a non-empty `args_contains`, e.g.
//! `allow Bash(ls:*)`) is unreachable when a TOOL-WIDE deny or ask rule exists
//! for the same tool. The tool-wide rule is consulted first in the behavior-class
//! precedence (deny wins, then ask, then allow -- see `permission_rules.decide`),
//! so the narrower allow rule can never be reached.
//!
//! Deny shadowing is more severe than ask shadowing: a tool-wide deny blocks the
//! tool entirely, whereas a tool-wide ask merely prompts. When both a tool-wide
//! deny and a tool-wide ask exist for the same tool, the deny is reported (it
//! wins the precedence). Mirrors the reference `shadowedRuleDetection.ts`
//! (`isAllowRuleShadowedByDenyRule` :160-184, `isAllowRuleShadowedByAskRule`
//! :111-147, `detectUnreachableRules` :193-234).
//!
//! Scope-aware: a shadower only counts when its scope is at least as broad as
//! the allow rule's (a global tool-wide deny shadows a global or workspace allow;
//! a workspace-scoped tool-wide deny only shadows allow rules whose scope it
//! contains). This avoids false positives where a workspace deny would not
//! actually be in effect for a globally-scoped allow rule.
//!
//! Simplifications vs the reference (documented per the phase plan, Task 9):
//!  - The Bash-sandbox-auto-allow exception
//!    (`shadowedRuleDetection.ts:135-144`) is skipped: zcode has no
//!    sandbox-auto-allow setting, so a tool-wide Bash ask rule always shadows.
//!  - Only TOOL-WIDE shadowers are considered (matching the reference, which
//!    also only handles `ruleContent === undefined` shadowers).
//!
//! Pure module: only `std` + the `permission_rules` types. No IO, no runtime
//! singleton, no allocation in `detect` (the caller supplies the result buffer).

const std = @import("std");
const permission_rules = @import("permission_rules.zig");

const Rule = permission_rules.Rule;
const Scope = permission_rules.Scope;

/// The kind of tool-wide rule that makes a content-keyed allow rule unreachable.
pub const ShadowKind = enum { deny, ask };

/// One shadowing finding: the content-keyed allow rule at `shadowed_index` is
/// made unreachable by the tool-wide rule at `shadower_index`. Indices are into
/// the same `rules` slice passed to `detect`.
pub const Shadow = struct {
    shadowed_index: usize,
    shadower_index: usize,
    kind: ShadowKind,
};

/// Return true if `args_contains` denotes a tool-wide rule (matches any args).
/// Mirrors the reference `ruleContent === undefined`.
fn isToolWide(rule: *const Rule) bool {
    return rule.args_contains.len == 0;
}

/// Return true if `shadower_scope` is at least as broad as `allow_scope`, i.e.
/// the shadower is actually in effect everywhere the allow rule is. A global
/// shadower covers everything; a workspace shadower only covers allow rules
/// scoped to a path it contains (or the same path).
fn scopeCovers(shadower_scope: Scope, allow_scope: Scope) bool {
    return switch (shadower_scope) {
        .global => true,
        .workspace => |shadower_root| switch (allow_scope) {
            // A workspace-scoped shadower cannot cover a global allow rule.
            .global => false,
            .workspace => |allow_root| pathWithin(allow_root, shadower_root),
        },
    };
}

/// True if `path` is the same as `root` or lives inside it. Mirrors the
/// containment check in `permission_rules.zig` (private there) so this module
/// stays self-contained.
fn pathWithin(path: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, path, root)) return true;
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (root.len == 0 or path.len <= root.len) return false;
    if (isPathSep(root[root.len - 1])) return true;
    return isPathSep(path[root.len]);
}

fn isPathSep(ch: u8) bool {
    return ch == '/' or ch == '\\';
}

/// Find the index of the first tool-wide rule of `want` action for `tool` whose
/// scope covers `allow_scope`. Returns null when none exists. Forward order
/// matches the reference `.find` over the source-concatenation order.
fn findToolWideShadower(
    rules: []const Rule,
    want: permission_rules.Action,
    tool: []const u8,
    allow_scope: Scope,
) ?usize {
    for (rules, 0..) |*rule, index| {
        if (rule.action != want) continue;
        if (!isToolWide(rule)) continue;
        if (!std.mem.eql(u8, rule.tool, tool)) continue;
        if (!scopeCovers(rule.scope, allow_scope)) continue;
        return index;
    }
    return null;
}

/// Scan `rules` for content-keyed allow rules that are shadowed by a tool-wide
/// deny (severe) or tool-wide ask rule for the same tool, writing findings into
/// `out`. Returns the slice of `out` that was filled. Deny is checked first and
/// wins over ask (one finding per shadowed allow rule, like the reference's
/// `continue`). `out` should be large enough for `rules.len` findings; extra
/// findings beyond `out.len` are dropped (each allow rule yields at most one).
pub fn detect(rules: []const Rule, out: []Shadow) []Shadow {
    var n: usize = 0;
    for (rules, 0..) |*allow_rule, allow_index| {
        if (n >= out.len) break;
        if (allow_rule.action != .allow) continue;
        // Only content-keyed allow rules can be shadowed; a tool-wide allow rule
        // is never reported (matches the reference `ruleContent === undefined`).
        if (isToolWide(allow_rule)) continue;

        // Deny shadowing first (more severe), then ask.
        if (findToolWideShadower(rules, .deny, allow_rule.tool, allow_rule.scope)) |deny_index| {
            out[n] = .{ .shadowed_index = allow_index, .shadower_index = deny_index, .kind = .deny };
            n += 1;
            continue;
        }
        if (findToolWideShadower(rules, .ask, allow_rule.tool, allow_rule.scope)) |ask_index| {
            out[n] = .{ .shadowed_index = allow_index, .shadower_index = ask_index, .kind = .ask };
            n += 1;
        }
    }
    return out[0..n];
}

/// Allocating convenience over `detect`: returns an owned slice the caller frees
/// with `allocator.free`. Useful for the REPL/`/doctor` formatting path.
pub fn detectAlloc(allocator: std.mem.Allocator, rules: []const Rule) ![]Shadow {
    const buf = try allocator.alloc(Shadow, rules.len);
    errdefer allocator.free(buf);
    const filled = detect(rules, buf);
    if (filled.len == buf.len) return buf;
    // Shrink to the filled prefix so the caller's free is exact.
    return allocator.realloc(buf, filled.len);
}

const testing = std.testing;
const Store = permission_rules.Store;

test "shadow_detection: tool-wide deny shadows a content-keyed allow" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.addRule(.allow, .global, "Bash", "ls*", "rules.tsv", 1, "test");
    try store.addRule(.deny, .global, "Bash", "", "rules.tsv", 2, "test");

    const shadows = try detectAlloc(testing.allocator, store.rules.items);
    defer testing.allocator.free(shadows);

    try testing.expectEqual(@as(usize, 1), shadows.len);
    try testing.expectEqual(ShadowKind.deny, shadows[0].kind);
    try testing.expectEqual(@as(usize, 0), shadows[0].shadowed_index);
    try testing.expectEqual(@as(usize, 1), shadows[0].shadower_index);
}

test "shadow_detection: tool-wide ask shadows a content-keyed allow" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.addRule(.allow, .global, "Bash", "ls*", "rules.tsv", 1, "test");
    try store.addRule(.ask, .global, "Bash", "", "rules.tsv", 2, "test");

    const shadows = try detectAlloc(testing.allocator, store.rules.items);
    defer testing.allocator.free(shadows);

    try testing.expectEqual(@as(usize, 1), shadows.len);
    try testing.expectEqual(ShadowKind.ask, shadows[0].kind);
}

test "shadow_detection: tool-wide allow is never reported" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    // A tool-wide allow rule plus a tool-wide deny: the allow is NOT a
    // content-keyed rule, so it is never reported as shadowed.
    try store.addRule(.allow, .global, "Bash", "", "rules.tsv", 1, "test");
    try store.addRule(.deny, .global, "Bash", "", "rules.tsv", 2, "test");

    const shadows = try detectAlloc(testing.allocator, store.rules.items);
    defer testing.allocator.free(shadows);

    try testing.expectEqual(@as(usize, 0), shadows.len);
}

test "shadow_detection: no shadowers yields an empty result" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.addRule(.allow, .global, "Bash", "ls*", "rules.tsv", 1, "test");
    try store.addRule(.allow, .global, "Read", "", "rules.tsv", 2, "test");
    // A content-keyed deny is NOT a tool-wide shadower.
    try store.addRule(.deny, .global, "Bash", "rm*", "rules.tsv", 3, "test");

    const shadows = try detectAlloc(testing.allocator, store.rules.items);
    defer testing.allocator.free(shadows);

    try testing.expectEqual(@as(usize, 0), shadows.len);
}

test "shadow_detection: deny takes precedence over ask when both are tool-wide" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.addRule(.allow, .global, "Bash", "ls*", "rules.tsv", 1, "test");
    try store.addRule(.ask, .global, "Bash", "", "rules.tsv", 2, "test");
    try store.addRule(.deny, .global, "Bash", "", "rules.tsv", 3, "test");

    const shadows = try detectAlloc(testing.allocator, store.rules.items);
    defer testing.allocator.free(shadows);

    // Exactly one finding for the single content-keyed allow, and it reports
    // the deny (more severe) rather than the ask.
    try testing.expectEqual(@as(usize, 1), shadows.len);
    try testing.expectEqual(ShadowKind.deny, shadows[0].kind);
}

test "shadow_detection: shadower must apply to the same tool" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.addRule(.allow, .global, "Bash", "ls*", "rules.tsv", 1, "test");
    // Tool-wide deny on a DIFFERENT tool must not shadow the Bash allow.
    try store.addRule(.deny, .global, "Read", "", "rules.tsv", 2, "test");

    const shadows = try detectAlloc(testing.allocator, store.rules.items);
    defer testing.allocator.free(shadows);

    try testing.expectEqual(@as(usize, 0), shadows.len);
}

test "shadow_detection: workspace deny does not shadow a global allow" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    // A globally-scoped content-keyed allow.
    try store.addRule(.allow, .global, "Bash", "ls*", "rules.tsv", 1, "test");
    // A workspace-scoped tool-wide deny only applies inside /repo, so it does
    // NOT make the global allow unreachable everywhere.
    try store.addRule(.deny, .{ .workspace = "/repo" }, "Bash", "", "rules.tsv", 2, "test");

    const shadows = try detectAlloc(testing.allocator, store.rules.items);
    defer testing.allocator.free(shadows);

    try testing.expectEqual(@as(usize, 0), shadows.len);
}

test "shadow_detection: global deny shadows a workspace-scoped allow" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    // A workspace-scoped content-keyed allow.
    try store.addRule(.allow, .{ .workspace = "/repo" }, "Bash", "ls*", "rules.tsv", 1, "test");
    // A global tool-wide deny is in effect everywhere, including /repo.
    try store.addRule(.deny, .global, "Bash", "", "rules.tsv", 2, "test");

    const shadows = try detectAlloc(testing.allocator, store.rules.items);
    defer testing.allocator.free(shadows);

    try testing.expectEqual(@as(usize, 1), shadows.len);
    try testing.expectEqual(ShadowKind.deny, shadows[0].kind);
}

test "shadow_detection: multiple shadowed allows each reported once" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.addRule(.allow, .global, "Bash", "ls*", "rules.tsv", 1, "test");
    try store.addRule(.allow, .global, "Bash", "git*", "rules.tsv", 2, "test");
    try store.addRule(.deny, .global, "Bash", "", "rules.tsv", 3, "test");

    const shadows = try detectAlloc(testing.allocator, store.rules.items);
    defer testing.allocator.free(shadows);

    try testing.expectEqual(@as(usize, 2), shadows.len);
    try testing.expectEqual(@as(usize, 0), shadows[0].shadowed_index);
    try testing.expectEqual(@as(usize, 1), shadows[1].shadowed_index);
    try testing.expectEqual(ShadowKind.deny, shadows[0].kind);
    try testing.expectEqual(ShadowKind.deny, shadows[1].kind);
}

test "shadow_detection: detect into a caller-supplied buffer matches detectAlloc" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.addRule(.allow, .global, "Bash", "ls*", "rules.tsv", 1, "test");
    try store.addRule(.ask, .global, "Bash", "", "rules.tsv", 2, "test");

    var buf: [8]Shadow = undefined;
    const shadows = detect(store.rules.items, &buf);
    try testing.expectEqual(@as(usize, 1), shadows.len);
    try testing.expectEqual(ShadowKind.ask, shadows[0].kind);
}
