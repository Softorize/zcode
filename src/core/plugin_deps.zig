//! Plugin dependency resolution (plugins-05) - pure functions, no I/O.
//!
//! A direct port of the reference `utils/plugins/dependencyResolver.ts`.
//! Semantics are apt-style: a dependency is a *presence guarantee*, not a
//! module graph. Plugin A depending on plugin B means "B's namespaced
//! components (MCP servers, commands, agents) must be available when A runs."
//!
//! Four entry points:
//!  - `qualifyDependency`        - normalize a bare dep to name@marketplace.
//!  - `resolveDependencyClosure` - install-time DFS walk + cycle detection +
//!                                 cross-marketplace block.
//!  - `verifyAndDemote`          - load-time fixed-point check that demotes
//!                                 plugins with unsatisfied deps (session-local,
//!                                 does NOT write settings).
//!  - `findReverseDependents`    - list enabled plugins that depend on a target
//!                                 (warn on uninstall/disable).
//!
//! Plugin ids are `name@marketplace` strings. Bare names (no `@`) carry no
//! marketplace; locally-installed zcode plugins use the `@local` sentinel (see
//! `plugin_settings.pluginId`). The reference `@inline` sentinel for
//! `--plugin-dir` plugins maps onto our `local` semantics: bare deps from such
//! a plugin are matched by name only.

const std = @import("std");

/// Synthetic marketplace sentinel whose bare deps cannot meaningfully inherit
/// the declaring plugin's marketplace. The reference uses `inline` for
/// `--plugin-dir` plugins (never catalog-resolved), so a bare dep from such a
/// plugin is returned unchanged (matched by name only later).
///
/// zcode's `local` sentinel is NOT synthetic here: locally-installed plugins ARE
/// the catalog (keyed `name@local`), so a bare dep declared by a `@local` plugin
/// must qualify to `dep@local` to match its sibling entries. Treating `local` as
/// synthetic (the way `inline` is) would leave the dep bare and trip the
/// cross-marketplace block against the `@local` root.
const inline_marketplace = "inline";

/// Parse a `name@marketplace` id into its components. Only the first `@` is the
/// separator (a marketplace name must not contain `@`); anything after a second
/// `@` is ignored, matching the reference `parsePluginIdentifier`.
pub const ParsedId = struct {
    name: []const u8,
    marketplace: ?[]const u8,
};

pub fn parseId(id: []const u8) ParsedId {
    const at = std.mem.indexOfScalar(u8, id, '@') orelse return .{ .name = id, .marketplace = null };
    const name = id[0..at];
    const rest = id[at + 1 ..];
    // A trailing bare `@` (e.g. "foo@") yields an empty marketplace; treat it as
    // absent so it behaves like a bare name.
    const second_at = std.mem.indexOfScalar(u8, rest, '@');
    const mkt = if (second_at) |s| rest[0..s] else rest;
    return .{ .name = name, .marketplace = if (mkt.len == 0) null else mkt };
}

fn isSyntheticMarketplace(mkt: []const u8) bool {
    return std.mem.eql(u8, mkt, inline_marketplace);
}

/// Normalize a dependency reference to fully-qualified `name@marketplace` form.
/// A bare name (no `@`) inherits the marketplace of the plugin declaring it -
/// cross-marketplace deps are blocked anyway, so the `@`-suffix is boilerplate
/// in the common case.
///
/// EXCEPTION: a bare dep declared by a plugin in a synthetic marketplace
/// (`inline`/`local`) is returned unchanged, since fabricating `dep@local`
/// would never match a real catalog entry. `verifyAndDemote`/
/// `findReverseDependents` handle these via name-only matching.
///
/// The result is either a slice into `dep` (returned unchanged) or a freshly
/// allocated `dep@mkt` string. Caller owns the result only when it differs from
/// `dep`; to keep ownership simple this always returns an owned dupe.
pub fn qualifyDependency(
    allocator: std.mem.Allocator,
    dep: []const u8,
    declaring_plugin_id: []const u8,
) ![]u8 {
    if (parseId(dep).marketplace != null) return allocator.dupe(u8, dep);
    const mkt = parseId(declaring_plugin_id).marketplace orelse return allocator.dupe(u8, dep);
    if (isSyntheticMarketplace(mkt)) return allocator.dupe(u8, dep);
    return std.fmt.allocPrint(allocator, "{s}@{s}", .{ dep, mkt });
}

/// Minimal shape the resolver needs from a marketplace lookup: a plugin's
/// declared dependency ids (possibly bare; `qualifyDependency` normalizes them).
pub const LookupResult = struct {
    dependencies: []const []const u8 = &.{},
};

/// Lookup vtable: resolve a plugin id to its declared deps, or null when the id
/// is not in any known catalog. Tests stub this with an in-memory map; the
/// marketplace wiring backs it with a catalog scan.
pub const Lookup = struct {
    ctx: *const anyopaque,
    lookupFn: *const fn (ctx: *const anyopaque, id: []const u8) ?LookupResult,

    fn call(self: Lookup, id: []const u8) ?LookupResult {
        return self.lookupFn(self.ctx, id);
    }
};

pub const ResolutionKind = enum { ok, cycle, not_found, cross_marketplace };

/// Result of `resolveDependencyClosure`. On `.ok`, `closure` is an owned slice
/// of owned id strings in post-order (deepest dep first, root last). On an
/// error, the relevant id fields are owned slices. Use `deinit` to free.
pub const Resolution = struct {
    kind: ResolutionKind,
    /// .ok: post-order install list (root always last). Owned.
    closure: [][]u8 = &.{},
    /// .cycle: the offending chain (stack + repeated id). Owned.
    chain: [][]u8 = &.{},
    /// .not_found / .cross_marketplace: the offending dependency id. Owned.
    dependency: ?[]u8 = null,
    /// .not_found / .cross_marketplace: the plugin that required it. Owned.
    required_by: ?[]u8 = null,

    pub fn deinit(self: *Resolution, allocator: std.mem.Allocator) void {
        for (self.closure) |s| allocator.free(s);
        allocator.free(self.closure);
        for (self.chain) |s| allocator.free(s);
        allocator.free(self.chain);
        if (self.dependency) |s| allocator.free(s);
        if (self.required_by) |s| allocator.free(s);
    }
};

/// Max DFS depth. The reference recurses; we use an explicit stack but still cap
/// the walk so an adversarial manifest with a pathologically deep (acyclic)
/// chain cannot exhaust memory. A real plugin graph is shallow; 256 is generous.
const max_depth: usize = 256;

const WalkState = struct {
    allocator: std.mem.Allocator,
    root_id: []const u8,
    root_marketplace: ?[]const u8,
    lookup: Lookup,
    already_enabled: *const StringSet,
    allowed_cross: *const StringSet,
    closure: *std.array_list.Managed([]u8),
    visited: *StringSet,
    stack: *std.array_list.Managed([]const u8),
};

/// Walk the transitive dependency closure of `root_id` via DFS.
///
/// The returned `.closure` ALWAYS contains `root_id`, plus every transitive
/// dependency NOT in `already_enabled`. Already-enabled deps are skipped (not
/// recursed into) so a closure never triggers a surprise settings write; the
/// root is never skipped even if already enabled, so re-installing a plugin
/// always re-caches it.
///
/// Cross-marketplace deps are BLOCKED by default (security boundary). The block
/// runs AFTER the already-enabled check (ordering matters: a manually-installed
/// cross-mkt dep is in `already_enabled` and is never reached). Only the ROOT
/// marketplace's allowlist applies for the whole walk (no transitive trust).
///
/// `already_enabled` and `allowed_cross` are caller-owned; this borrows them.
pub fn resolveDependencyClosure(
    allocator: std.mem.Allocator,
    root_id: []const u8,
    lookup: Lookup,
    already_enabled: *const StringSet,
    allowed_cross: *const StringSet,
) !Resolution {
    var closure = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (closure.items) |s| allocator.free(s);
        closure.deinit();
    }

    var visited = StringSet.init(allocator);
    defer visited.deinit();

    var stack = std.array_list.Managed([]const u8).init(allocator);
    defer stack.deinit();

    var state = WalkState{
        .allocator = allocator,
        .root_id = root_id,
        .root_marketplace = parseId(root_id).marketplace,
        .lookup = lookup,
        .already_enabled = already_enabled,
        .allowed_cross = allowed_cross,
        .closure = &closure,
        .visited = &visited,
        .stack = &stack,
    };

    if (try walk(&state, root_id, root_id, 0)) |err_res| {
        // An error result was produced; the partial closure is discarded.
        for (closure.items) |s| allocator.free(s);
        closure.deinit();
        return err_res;
    }

    return .{ .kind = .ok, .closure = try closure.toOwnedSlice() };
}

/// Returns a non-ok `Resolution` on the first cycle/not-found/cross-marketplace
/// error, or null when this subtree resolved cleanly (its id appended to the
/// closure in post-order).
fn walk(state: *WalkState, id: []const u8, required_by: []const u8, depth: usize) anyerror!?Resolution {
    if (depth >= max_depth) {
        // Treat an over-deep chain as a cycle-equivalent failure (refuse to
        // install) rather than silently truncating. Report the current stack.
        return try cycleResult(state, id);
    }

    // Skip already-enabled DEPENDENCIES (avoids surprise settings writes), but
    // NEVER skip the root.
    if (!std.mem.eql(u8, id, state.root_id) and state.already_enabled.contains(id)) return null;

    // Security: block auto-install across marketplace boundaries. Runs AFTER the
    // already-enabled check.
    const id_mkt = parseId(id).marketplace;
    if (!marketplaceMatches(id_mkt, state.root_marketplace) and
        !(id_mkt != null and state.allowed_cross.contains(id_mkt.?)))
    {
        return Resolution{
            .kind = .cross_marketplace,
            .dependency = try state.allocator.dupe(u8, id),
            .required_by = try state.allocator.dupe(u8, required_by),
        };
    }

    // Cycle detection: the id is already on the active DFS stack.
    for (state.stack.items) |on_stack| {
        if (std.mem.eql(u8, on_stack, id)) return try cycleResult(state, id);
    }

    if (state.visited.contains(id)) return null;
    try state.visited.add(id);

    const entry = state.lookup.call(id) orelse return Resolution{
        .kind = .not_found,
        .dependency = try state.allocator.dupe(u8, id),
        .required_by = try state.allocator.dupe(u8, required_by),
    };

    try state.stack.append(id);
    for (entry.dependencies) |raw_dep| {
        const dep = try qualifyDependency(state.allocator, raw_dep, id);
        defer state.allocator.free(dep);
        if (try walk(state, dep, id, depth + 1)) |err_res| {
            _ = state.stack.pop();
            return err_res;
        }
    }
    _ = state.stack.pop();

    try state.closure.append(try state.allocator.dupe(u8, id));
    return null;
}

/// Build a `.cycle` Resolution whose chain is the active stack plus the
/// repeated id (matching the reference `[...stack, id]`).
fn cycleResult(state: *WalkState, id: []const u8) !Resolution {
    var chain = std.array_list.Managed([]u8).init(state.allocator);
    errdefer {
        for (chain.items) |s| state.allocator.free(s);
        chain.deinit();
    }
    for (state.stack.items) |on_stack| try chain.append(try state.allocator.dupe(u8, on_stack));
    try chain.append(try state.allocator.dupe(u8, id));
    return .{ .kind = .cycle, .chain = try chain.toOwnedSlice() };
}

/// Two marketplaces "match" when both are absent or both present and equal. A
/// bare id (no marketplace) matches a bare root; that lets bare-on-bare local
/// graphs resolve without a cross-marketplace block.
fn marketplaceMatches(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// A loaded plugin as seen by the load-time checks. `source` is the canonical
/// `name@marketplace` id; `name` is the bare name; `dependencies` are the raw
/// (possibly bare) declared deps. All slices are borrowed for the call's
/// duration.
pub const LoadedPlugin = struct {
    source: []const u8,
    name: []const u8,
    enabled: bool,
    dependencies: []const []const u8,
};

/// Load-time safety net: for each enabled plugin, verify all declared
/// dependencies are also enabled. Demote any that fail, iterating to a fixed
/// point (demoting A may break B that depends on A). Does NOT mutate the input
/// and does NOT write settings - the caller clears `enabled` session-locally.
///
/// Returns the set of plugin `source` ids to demote. Caller owns the returned
/// `StringSet` (call `deinit`).
pub fn verifyAndDemote(allocator: std.mem.Allocator, plugins: []const LoadedPlugin) !StringSet {
    // enabled: the still-satisfied set, mutated as we demote.
    var enabled = StringSet.init(allocator);
    defer enabled.deinit();
    // enabledByName: multiset of bare names in `enabled`, for matching bare deps
    // declared by synthetic-marketplace plugins. Demoting one of several
    // same-named plugins must not make the name vanish from the index.
    var enabled_by_name = std.StringHashMap(usize).init(allocator);
    defer enabled_by_name.deinit();

    for (plugins) |p| {
        if (!p.enabled) continue;
        try enabled.add(p.source);
        const n = parseId(p.source).name;
        const gop = try enabled_by_name.getOrPut(n);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    var changed = true;
    while (changed) {
        changed = false;
        for (plugins) |p| {
            if (!enabled.contains(p.source)) continue;
            var unsatisfied = false;
            for (p.dependencies) |raw_dep| {
                const dep = try qualifyDependency(allocator, raw_dep, p.source);
                defer allocator.free(dep);
                const is_bare = parseId(dep).marketplace == null;
                const satisfied = if (is_bare)
                    (enabled_by_name.get(dep) orelse 0) > 0
                else
                    enabled.contains(dep);
                if (!satisfied) {
                    unsatisfied = true;
                    break;
                }
            }
            if (unsatisfied) {
                enabled.remove(p.source);
                const pname = parseId(p.source).name;
                if (enabled_by_name.getPtr(pname)) |cnt| {
                    if (cnt.* <= 1) {
                        _ = enabled_by_name.remove(pname);
                    } else {
                        cnt.* -= 1;
                    }
                }
                changed = true;
                break;
            }
        }
    }

    // demoted = plugins that started enabled but are no longer in `enabled`.
    var demoted = StringSet.init(allocator);
    errdefer demoted.deinit();
    for (plugins) |p| {
        if (p.enabled and !enabled.contains(p.source)) try demoted.add(p.source);
    }
    return demoted;
}

/// Find all enabled plugins that declare `plugin_id` as a dependency. Used to
/// warn on uninstall/disable ("required by: X, Y"). Returns the bare *names* of
/// the dependents. Caller owns the returned slice of owned strings.
pub fn findReverseDependents(
    allocator: std.mem.Allocator,
    plugin_id: []const u8,
    plugins: []const LoadedPlugin,
) ![][]u8 {
    const target_name = parseId(plugin_id).name;
    var out = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit();
    }

    for (plugins) |p| {
        if (!p.enabled) continue;
        if (std.mem.eql(u8, p.source, plugin_id)) continue;
        var depends = false;
        for (p.dependencies) |raw_dep| {
            const qualified = try qualifyDependency(allocator, raw_dep, p.source);
            defer allocator.free(qualified);
            const matched = if (parseId(qualified).marketplace != null)
                std.mem.eql(u8, qualified, plugin_id)
            else
                std.mem.eql(u8, qualified, target_name);
            if (matched) {
                depends = true;
                break;
            }
        }
        if (depends) try out.append(try allocator.dupe(u8, p.name));
    }

    return out.toOwnedSlice();
}

/// Format the "(+ N dependencies)" suffix for install success messages. Returns
/// an empty (still owned) slice when `installed_deps` is empty.
pub fn formatDependencyCountSuffix(allocator: std.mem.Allocator, installed_count: usize) ![]u8 {
    if (installed_count == 0) return allocator.dupe(u8, "");
    const noun = if (installed_count == 1) "dependency" else "dependencies";
    return std.fmt.allocPrint(allocator, " (+ {d} {s})", .{ installed_count, noun });
}

/// Format the "- warning: required by X, Y" suffix for uninstall/disable result
/// messages. Plain hyphen (CLAUDE.md: no em/en dashes). Returns an empty owned
/// slice when there are no dependents.
pub fn formatReverseDependentsSuffix(allocator: std.mem.Allocator, rdeps: []const []const u8) ![]u8 {
    if (rdeps.len == 0) return allocator.dupe(u8, "");
    const joined = try std.mem.join(allocator, ", ", rdeps);
    defer allocator.free(joined);
    return std.fmt.allocPrint(allocator, " - warning: required by {s}", .{joined});
}

/// A small owned string set built on StringHashMap. Keys are duped on insert and
/// freed on deinit, so callers can pass transient slices.
pub const StringSet = struct {
    map: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) StringSet {
        return .{ .map = std.StringHashMap(void).init(allocator) };
    }

    pub fn deinit(self: *StringSet) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| self.map.allocator.free(k.*);
        self.map.deinit();
    }

    pub fn add(self: *StringSet, key: []const u8) !void {
        if (self.map.contains(key)) return;
        const owned = try self.map.allocator.dupe(u8, key);
        errdefer self.map.allocator.free(owned);
        try self.map.put(owned, {});
    }

    pub fn contains(self: *const StringSet, key: []const u8) bool {
        return self.map.contains(key);
    }

    pub fn remove(self: *StringSet, key: []const u8) void {
        if (self.map.fetchRemove(key)) |kv| self.map.allocator.free(kv.key);
    }

    pub fn count(self: *const StringSet) usize {
        return self.map.count();
    }
};

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

/// In-memory lookup stub: a list of (id, deps) rows. Returns null for unknown
/// ids. Used to drive resolveDependencyClosure tests without a real catalog.
const StubCatalog = struct {
    const Row = struct { id: []const u8, deps: []const []const u8 };
    rows: []const Row,

    fn lookup(ctx: *const anyopaque, id: []const u8) ?LookupResult {
        const self: *const StubCatalog = @ptrCast(@alignCast(ctx));
        for (self.rows) |row| {
            if (std.mem.eql(u8, row.id, id)) return .{ .dependencies = row.deps };
        }
        return null;
    }

    fn lookupVtable(self: *const StubCatalog) Lookup {
        return .{ .ctx = self, .lookupFn = StubCatalog.lookup };
    }
};

fn emptySet() StringSet {
    return StringSet.init(testing.allocator);
}

test "parseId splits name@marketplace and bare names" {
    try testing.expectEqualStrings("foo", parseId("foo@bar").name);
    try testing.expectEqualStrings("bar", parseId("foo@bar").marketplace.?);
    try testing.expectEqualStrings("foo", parseId("foo").name);
    try testing.expect(parseId("foo").marketplace == null);
    // Trailing bare @ -> absent marketplace.
    try testing.expect(parseId("foo@").marketplace == null);
    // Only the first @ separates; the second-and-beyond is ignored.
    try testing.expectEqualStrings("mkt", parseId("foo@mkt@extra").marketplace.?);
}

test "qualifyDependency inherits declaring marketplace, leaves inline bare" {
    const a = try qualifyDependency(testing.allocator, "B", "A@epic");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("B@epic", a);

    // Already-qualified dep is returned unchanged.
    const b = try qualifyDependency(testing.allocator, "B@other", "A@epic");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("B@other", b);

    // Bare dep from a @local plugin qualifies to @local (local is the catalog,
    // not a synthetic sentinel for zcode).
    const c = try qualifyDependency(testing.allocator, "B", "A@local");
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("B@local", c);

    // Bare dep from an @inline (--plugin-dir) plugin stays bare: inline is never
    // catalog-resolved.
    const d = try qualifyDependency(testing.allocator, "B", "A@inline");
    defer testing.allocator.free(d);
    try testing.expectEqualStrings("B", d);
}

test "resolveDependencyClosure: A->B->C none enabled => [C, B, A] post-order" {
    const catalog = StubCatalog{ .rows = &.{
        .{ .id = "A@m", .deps = &.{"B"} },
        .{ .id = "B@m", .deps = &.{"C"} },
        .{ .id = "C@m", .deps = &.{} },
    } };
    var enabled = emptySet();
    defer enabled.deinit();
    var allowed = emptySet();
    defer allowed.deinit();

    var res = try resolveDependencyClosure(testing.allocator, "A@m", catalog.lookupVtable(), &enabled, &allowed);
    defer res.deinit(testing.allocator);

    try testing.expectEqual(ResolutionKind.ok, res.kind);
    try testing.expectEqual(@as(usize, 3), res.closure.len);
    try testing.expectEqualStrings("C@m", res.closure[0]);
    try testing.expectEqualStrings("B@m", res.closure[1]);
    try testing.expectEqualStrings("A@m", res.closure[2]);
}

test "resolveDependencyClosure: A->B->A cycle reports chain" {
    const catalog = StubCatalog{ .rows = &.{
        .{ .id = "A@m", .deps = &.{"B"} },
        .{ .id = "B@m", .deps = &.{"A"} },
    } };
    var enabled = emptySet();
    defer enabled.deinit();
    var allowed = emptySet();
    defer allowed.deinit();

    var res = try resolveDependencyClosure(testing.allocator, "A@m", catalog.lookupVtable(), &enabled, &allowed);
    defer res.deinit(testing.allocator);

    try testing.expectEqual(ResolutionKind.cycle, res.kind);
    // Chain is [A@m, B@m, A@m]: stack at the point B re-encounters A, plus A.
    try testing.expectEqual(@as(usize, 3), res.chain.len);
    try testing.expectEqualStrings("A@m", res.chain[0]);
    try testing.expectEqualStrings("B@m", res.chain[1]);
    try testing.expectEqualStrings("A@m", res.chain[2]);
}

test "resolveDependencyClosure: cross-marketplace blocked unless allowlisted" {
    const catalog = StubCatalog{ .rows = &.{
        .{ .id = "A@mkt1", .deps = &.{"B@mkt2"} },
        .{ .id = "B@mkt2", .deps = &.{} },
    } };

    // Not allowlisted => cross-marketplace error.
    {
        var enabled = emptySet();
        defer enabled.deinit();
        var allowed = emptySet();
        defer allowed.deinit();
        var res = try resolveDependencyClosure(testing.allocator, "A@mkt1", catalog.lookupVtable(), &enabled, &allowed);
        defer res.deinit(testing.allocator);
        try testing.expectEqual(ResolutionKind.cross_marketplace, res.kind);
        try testing.expectEqualStrings("B@mkt2", res.dependency.?);
        try testing.expectEqualStrings("A@mkt1", res.required_by.?);
    }

    // mkt2 in the root's allowlist => resolves.
    {
        var enabled = emptySet();
        defer enabled.deinit();
        var allowed = emptySet();
        defer allowed.deinit();
        try allowed.add("mkt2");
        var res = try resolveDependencyClosure(testing.allocator, "A@mkt1", catalog.lookupVtable(), &enabled, &allowed);
        defer res.deinit(testing.allocator);
        try testing.expectEqual(ResolutionKind.ok, res.kind);
        try testing.expectEqual(@as(usize, 2), res.closure.len);
        try testing.expectEqualStrings("B@mkt2", res.closure[0]);
        try testing.expectEqualStrings("A@mkt1", res.closure[1]);
    }
}

test "resolveDependencyClosure: already-enabled dep skipped, root never skipped" {
    const catalog = StubCatalog{ .rows = &.{
        .{ .id = "A@m", .deps = &.{"B"} },
        .{ .id = "B@m", .deps = &.{} },
    } };
    var enabled = emptySet();
    defer enabled.deinit();
    // Both A and B already enabled. B (a dep) is skipped; A (the root) is not.
    try enabled.add("A@m");
    try enabled.add("B@m");
    var allowed = emptySet();
    defer allowed.deinit();

    var res = try resolveDependencyClosure(testing.allocator, "A@m", catalog.lookupVtable(), &enabled, &allowed);
    defer res.deinit(testing.allocator);

    try testing.expectEqual(ResolutionKind.ok, res.kind);
    try testing.expectEqual(@as(usize, 1), res.closure.len);
    try testing.expectEqualStrings("A@m", res.closure[0]);
}

test "resolveDependencyClosure: missing dep => not-found" {
    const catalog = StubCatalog{ .rows = &.{
        .{ .id = "A@m", .deps = &.{"Z"} },
    } };
    var enabled = emptySet();
    defer enabled.deinit();
    var allowed = emptySet();
    defer allowed.deinit();

    var res = try resolveDependencyClosure(testing.allocator, "A@m", catalog.lookupVtable(), &enabled, &allowed);
    defer res.deinit(testing.allocator);

    try testing.expectEqual(ResolutionKind.not_found, res.kind);
    try testing.expectEqualStrings("Z@m", res.dependency.?);
    try testing.expectEqualStrings("A@m", res.required_by.?);
}

test "verifyAndDemote: A whose dep B is disabled is demoted; cascades to C-on-A" {
    // A depends on B (disabled) => A demoted. C depends on A => C cascades off.
    const plugins = [_]LoadedPlugin{
        .{ .source = "A@m", .name = "A", .enabled = true, .dependencies = &.{"B"} },
        .{ .source = "B@m", .name = "B", .enabled = false, .dependencies = &.{} },
        .{ .source = "C@m", .name = "C", .enabled = true, .dependencies = &.{"A"} },
    };
    var demoted = try verifyAndDemote(testing.allocator, &plugins);
    defer demoted.deinit();

    try testing.expectEqual(@as(usize, 2), demoted.count());
    try testing.expect(demoted.contains("A@m"));
    try testing.expect(demoted.contains("C@m"));
    try testing.expect(!demoted.contains("B@m"));
}

test "verifyAndDemote: all deps satisfied => nothing demoted" {
    const plugins = [_]LoadedPlugin{
        .{ .source = "A@m", .name = "A", .enabled = true, .dependencies = &.{"B"} },
        .{ .source = "B@m", .name = "B", .enabled = true, .dependencies = &.{} },
    };
    var demoted = try verifyAndDemote(testing.allocator, &plugins);
    defer demoted.deinit();
    try testing.expectEqual(@as(usize, 0), demoted.count());
}

test "findReverseDependents: uninstalling B returns [A]" {
    const plugins = [_]LoadedPlugin{
        .{ .source = "A@m", .name = "A", .enabled = true, .dependencies = &.{"B"} },
        .{ .source = "B@m", .name = "B", .enabled = true, .dependencies = &.{} },
        .{ .source = "C@m", .name = "C", .enabled = true, .dependencies = &.{} },
    };
    const rdeps = try findReverseDependents(testing.allocator, "B@m", &plugins);
    defer {
        for (rdeps) |s| testing.allocator.free(s);
        testing.allocator.free(rdeps);
    }
    try testing.expectEqual(@as(usize, 1), rdeps.len);
    try testing.expectEqualStrings("A", rdeps[0]);
}

test "findReverseDependents: disabled dependents are ignored" {
    const plugins = [_]LoadedPlugin{
        .{ .source = "A@m", .name = "A", .enabled = false, .dependencies = &.{"B"} },
        .{ .source = "B@m", .name = "B", .enabled = true, .dependencies = &.{} },
    };
    const rdeps = try findReverseDependents(testing.allocator, "B@m", &plugins);
    defer {
        for (rdeps) |s| testing.allocator.free(s);
        testing.allocator.free(rdeps);
    }
    try testing.expectEqual(@as(usize, 0), rdeps.len);
}

test "formatDependencyCountSuffix and formatReverseDependentsSuffix copy" {
    const none = try formatDependencyCountSuffix(testing.allocator, 0);
    defer testing.allocator.free(none);
    try testing.expectEqualStrings("", none);

    const one = try formatDependencyCountSuffix(testing.allocator, 1);
    defer testing.allocator.free(one);
    try testing.expectEqualStrings(" (+ 1 dependency)", one);

    const many = try formatDependencyCountSuffix(testing.allocator, 3);
    defer testing.allocator.free(many);
    try testing.expectEqualStrings(" (+ 3 dependencies)", many);

    const rdeps = [_][]const u8{ "A", "B" };
    const suffix = try formatReverseDependentsSuffix(testing.allocator, &rdeps);
    defer testing.allocator.free(suffix);
    try testing.expectEqualStrings(" - warning: required by A, B", suffix);
    // No em/en dashes (CLAUDE.md).
    try testing.expect(std.mem.indexOf(u8, suffix, "\u{2014}") == null);
    try testing.expect(std.mem.indexOf(u8, suffix, "\u{2013}") == null);
}
