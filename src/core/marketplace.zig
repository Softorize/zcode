const std = @import("std");
const std_io = @import("std_io.zig");
const rt = @import("zcode_runtime");
const rng = @import("rng.zig");
const paths = @import("paths.zig");
const security = @import("security.zig");
const parse_helpers = @import("parse_helpers.zig");
const display_safe = @import("display_safe.zig");
const egress = @import("egress.zig");
const plugin_deps = @import("plugin_deps.zig");
const plugins = @import("plugins.zig");
const plugin_settings = @import("plugin_settings.zig");
const plugin_policy = @import("plugin_policy.zig");
const plugin_flagging = @import("plugin_flagging.zig");

pub const EntryKind = enum {
    plugin,
    command,
};

pub const EntryScope = enum {
    user,
    workspace,
    remote,
};

pub const Entry = struct {
    name: []u8,
    kind: EntryKind,
    description: []u8,
    source: []u8,
    manifest_path: []u8,
    scope: EntryScope,
    featured: bool,
    source_sha256: ?[]u8 = null,
    package_format: ?[]u8 = null,
    /// Dependency ids declared in the catalog entry's `dependencies` array
    /// (plugins-05). Bare `name` or `name@marketplace` references. Used by
    /// install-time closure resolution. May be empty.
    dependencies: []const []const u8 = &.{},
    /// Catalog `deleted` flag (plugins-09). A marketplace marks an entry deleted
    /// to delist it. When the entry's source opts into `force_remove_deleted`,
    /// delisting detection auto-uninstalls the matching installed plugin.
    deleted: bool = false,
    /// Catalog-advertised version of this entry (plugins-10). When present and
    /// `auto_update` is set, background autoupdate compares this against the
    /// installed plugin's manifest version to decide whether to refresh. May be
    /// absent for catalogs that do not version their entries.
    version: ?[]u8 = null,
    /// Catalog `auto_update` opt-in (plugins-10). Only an entry that explicitly
    /// sets this is eligible for background autoupdate; defaults false so a
    /// catalog must grant zcode permission before it updates the user's plugin.
    auto_update: bool = false,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.source);
        allocator.free(self.manifest_path);
        if (self.source_sha256) |value| allocator.free(value);
        if (self.package_format) |value| allocator.free(value);
        for (self.dependencies) |dep| allocator.free(dep);
        allocator.free(self.dependencies);
        if (self.version) |value| allocator.free(value);
    }
};

pub const SourceEntry = struct {
    name: []u8,
    url: []u8,
    sha256: ?[]u8 = null,
    cache_path: []u8,
    cached: bool,

    pub fn deinit(self: *SourceEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.url);
        if (self.sha256) |value| allocator.free(value);
        allocator.free(self.cache_path);
    }
};

const RegistrySource = struct {
    name: []u8,
    url: []u8,
    sha256: ?[]u8 = null,
    /// Opt-in flag (plugins-09): when true, delisting detection auto-uninstalls
    /// an installed plugin this source marks `deleted` in its refreshed catalog.
    /// Defaults false: a source must explicitly grant zcode permission to remove
    /// the user's plugins on its behalf.
    force_remove_deleted: bool = false,

    fn deinit(self: *RegistrySource, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.url);
        if (self.sha256) |value| allocator.free(value);
    }
};

/// Append a {name, url, sha256} registry source row in a leak-safe way.
/// Previous per-site code did `try out.append(.{ .name = try dupe, .url = try dupe, .sha256 = if ... try dupe else null })`
/// which leaked prior dupes if any later dupe OOMd, and leaked all
/// three if the append itself OOMd.
fn appendRegistrySource(
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed(RegistrySource),
    name: []const u8,
    url: []const u8,
    sha256: ?[]const u8,
    force_remove_deleted: bool,
) !void {
    try out.ensureUnusedCapacity(1);
    const dup_name = try allocator.dupe(u8, name);
    errdefer allocator.free(dup_name);
    const dup_url = try allocator.dupe(u8, url);
    errdefer allocator.free(dup_url);
    const dup_sha: ?[]u8 = if (sha256) |v| try allocator.dupe(u8, v) else null;
    out.appendAssumeCapacity(.{
        .name = dup_name,
        .url = dup_url,
        .sha256 = dup_sha,
        .force_remove_deleted = force_remove_deleted,
    });
}

const SourceResolver = struct {
    base_dir: ?[]u8 = null,
    base_url: ?[]u8 = null,

    fn deinit(self: *SourceResolver, allocator: std.mem.Allocator) void {
        if (self.base_dir) |value| allocator.free(value);
        if (self.base_url) |value| allocator.free(value);
    }
};

pub fn list(allocator: std.mem.Allocator, cwd: []const u8, filter: ?EntryKind) ![]Entry {
    var out = std.array_list.Managed(Entry).init(allocator);
    errdefer freeList(allocator, out.items);

    if (userCatalogPath(allocator)) |path| {
        defer allocator.free(path);
        try appendCatalogEntriesFromPath(allocator, &out, path, .user, filter);
    } else |_| {}

    const workspace_path = try paths.workspacePathAlloc(allocator, cwd, "marketplace.json");
    defer allocator.free(workspace_path);
    try appendCatalogEntriesFromPath(allocator, &out, workspace_path, .workspace, filter);

    const sources = try loadRegistrySources(allocator);
    defer freeRegistrySources(allocator, sources);
    for (sources) |source| {
        const cache_path = try cachePathForSource(allocator, source.name);
        defer allocator.free(cache_path);
        if (!fileExists(cache_path)) continue;

        var resolver = try resolverForCatalogSource(allocator, source.url);
        defer resolver.deinit(allocator);
        try appendCatalogEntriesFromPathWithResolver(
            allocator,
            &out,
            cache_path,
            source.url,
            .remote,
            filter,
            resolver,
        );
    }

    return out.toOwnedSlice();
}

pub fn renderList(allocator: std.mem.Allocator, cwd: []const u8, filter: ?EntryKind) ![]u8 {
    const entries = try list(allocator, cwd, filter);
    defer freeList(allocator, entries);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    if (entries.len == 0) {
        try out.writer().writeAll("marketplace: none\n");
        return out.toOwnedSlice();
    }

    try out.writer().writeAll("marketplace:\n");
    for (entries) |entry| {
        try out.writer().print("- {s} [{s}] ({s}) source={s}{s}{s}\n", .{
            entry.name,
            kindName(entry.kind),
            scopeName(entry.scope),
            entry.source,
            if (entry.featured) " featured=true" else "",
            if (entry.source_sha256 != null) " verified=sha256" else "",
        });
    }
    return out.toOwnedSlice();
}

pub fn renderDetail(allocator: std.mem.Allocator, cwd: []const u8, kind: EntryKind, name: []const u8) ![]u8 {
    var entry = try findEntry(allocator, cwd, kind, name);
    defer entry.deinit(allocator);

    return std.fmt.allocPrint(
        allocator,
        "name: {s}\nkind: {s}\nscope: {s}\nfeatured: {}\nsource: {s}\nsource_sha256: {s}\npackage_format: {s}\ncatalog: {s}\ndescription: {s}\n",
        .{
            entry.name,
            kindName(entry.kind),
            scopeName(entry.scope),
            entry.featured,
            entry.source,
            entry.source_sha256 orelse "<none>",
            entry.package_format orelse "<none>",
            entry.manifest_path,
            entry.description,
        },
    );
}

pub fn install(allocator: std.mem.Allocator, cwd: []const u8, kind: EntryKind, name: []const u8) ![]u8 {
    // Org policy gate (plugins-07): a plugin force-disabled by managed settings
    // (`policySettings.enabledPlugins[id] === false`) cannot be installed at any
    // scope. Checked FIRST, before resolving the catalog entry or any side
    // effect. Commands have no policy concept. zcode catalogs are `@local`, so
    // the policy id is `name@local`.
    if (kind == .plugin) {
        const policy_id = try plugin_settings.pluginId(allocator, name, null);
        defer allocator.free(policy_id);
        if (plugin_policy.isBlockedByPolicy(allocator, policy_id) catch false) {
            return error.PluginBlockedByPolicy;
        }
    }

    var entry = try findEntry(allocator, cwd, kind, name);
    defer entry.deinit(allocator);

    // Trust disclaimer (plugins-06): print the warning to stderr before any
    // install side effect. Plugin-only (commands are static markdown). Emitted at
    // most once per process; never blocks headless/CI installs.
    if (kind == .plugin) emitTrustWarning(allocator, null);

    // Dependency closure (plugins-05): a plugin may declare `dependencies`. We
    // resolve the transitive closure against the catalog and install every
    // not-yet-enabled member before the root. Cross-marketplace deps are
    // blocked, cycles refused, and a missing dep aborts the install. Commands
    // have no dependency concept, so this is plugin-only.
    var dep_count: usize = 0;
    if (kind == .plugin and entry.dependencies.len > 0) {
        dep_count = try installDependencyClosure(allocator, cwd, name);
    }

    const destination = try installEntryFiles(allocator, entry, kind);
    defer allocator.free(destination);

    const suffix = try plugin_deps.formatDependencyCountSuffix(allocator, dep_count);
    defer allocator.free(suffix);

    return std.fmt.allocPrint(allocator, "installed {s} {s} -> {s}{s}", .{ kindName(kind), name, destination, suffix });
}

/// Copy a resolved catalog entry's files into the install root (no dependency
/// resolution). The dependency-closure walk uses this for each member so it does
/// not recurse back into `install` (which would re-resolve and loop). Returns the
/// install destination path; caller owns it.
fn installEntryFiles(allocator: std.mem.Allocator, entry: Entry, kind: EntryKind) ![]u8 {
    return if (isRemoteHttpUrl(entry.source))
        switch (kind) {
            .plugin => installRemotePlugin(allocator, entry),
            .command => installRemoteCommand(allocator, entry),
        }
    else switch (kind) {
        .plugin => installPlugin(allocator, entry),
        .command => installCommand(allocator, entry),
    };
}

/// Resolve and install the transitive dependency closure of `root_name`
/// (plugins-05). Catalog entries are keyed by bare name; the resolver works in
/// `name@marketplace` id space, so we snapshot the plugin catalog into a lookup
/// keyed on `name@local` (the id locally-discovered plugins carry) and treat
/// already-enabled plugins as install-skips. Returns the number of dependencies
/// actually installed (the root is excluded from the count).
fn installDependencyClosure(allocator: std.mem.Allocator, cwd: []const u8, root_name: []const u8) !usize {
    var catalog = try DependencyCatalog.build(allocator, cwd);
    defer catalog.deinit();

    const root_id = try plugin_settings.pluginId(allocator, root_name, null);
    defer allocator.free(root_id);

    // Already-enabled set: plugins currently loaded and enabled are skipped (so
    // a dep already present at any scope is not reinstalled), but the root is
    // never skipped by resolveDependencyClosure.
    var already = plugin_deps.StringSet.init(allocator);
    defer already.deinit();
    {
        const loaded = try plugins.list(allocator, cwd);
        defer plugins.freeList(allocator, loaded);
        for (loaded) |p| {
            if (p.enabled) try already.add(p.plugin_id);
        }
    }

    // Cross-marketplace allowlist: zcode catalogs are all keyed `@local`, so the
    // allowlist is empty (no cross-marketplace promotion). The block only fires
    // if a manifest declares a `dep@othermarket`.
    var allowed = plugin_deps.StringSet.init(allocator);
    defer allowed.deinit();

    var res = try plugin_deps.resolveDependencyClosure(allocator, root_id, catalog.lookup(), &already, &allowed);
    defer res.deinit(allocator);

    switch (res.kind) {
        .ok => {},
        .cycle => return error.PluginDependencyCycle,
        .not_found => return error.PluginDependencyNotFound,
        .cross_marketplace => return error.PluginCrossMarketplaceDependency,
    }

    // The closure is post-order: deps first, root last. Install each dep's files
    // directly (skip the root, which the caller installs through the normal
    // path). We install files directly rather than calling back into `install`
    // so the walk does not re-resolve closures (and so the inferred error sets
    // do not form a loop).
    var installed: usize = 0;
    for (res.closure) |id| {
        if (std.mem.eql(u8, id, root_id)) continue;
        const dep_name = plugin_deps.parseId(id).name;
        var dep_entry = findEntry(allocator, cwd, .plugin, dep_name) catch |err| switch (err) {
            error.MarketplaceEntryNotFound => return error.PluginDependencyNotFound,
            else => return err,
        };
        defer dep_entry.deinit(allocator);
        const dep_dest = try installEntryFiles(allocator, dep_entry, .plugin);
        allocator.free(dep_dest);
        installed += 1;
    }
    return installed;
}

/// In-memory snapshot of the plugin catalog, indexed by `name@local` id for the
/// dependency resolver. Owns its rows; `lookup()` returns a borrowed vtable.
const DependencyCatalog = struct {
    allocator: std.mem.Allocator,
    ids: std.array_list.Managed([]u8),
    deps: std.array_list.Managed([]const []const u8),

    fn build(allocator: std.mem.Allocator, cwd: []const u8) !DependencyCatalog {
        var self = DependencyCatalog{
            .allocator = allocator,
            .ids = std.array_list.Managed([]u8).init(allocator),
            .deps = std.array_list.Managed([]const []const u8).init(allocator),
        };
        errdefer self.deinit();

        const entries = try list(allocator, cwd, .plugin);
        defer freeList(allocator, entries);
        for (entries) |entry| {
            const id = try plugin_settings.pluginId(allocator, entry.name, null);
            errdefer allocator.free(id);
            const dup_deps = try dupeStringList(allocator, entry.dependencies);
            try self.ids.append(id);
            try self.deps.append(dup_deps);
        }
        return self;
    }

    fn deinit(self: *DependencyCatalog) void {
        for (self.ids.items) |id| self.allocator.free(id);
        self.ids.deinit();
        for (self.deps.items) |d| {
            for (d) |s| self.allocator.free(s);
            self.allocator.free(d);
        }
        self.deps.deinit();
    }

    fn lookupImpl(ctx: *const anyopaque, id: []const u8) ?plugin_deps.LookupResult {
        const self: *const DependencyCatalog = @ptrCast(@alignCast(ctx));
        for (self.ids.items, 0..) |row_id, i| {
            if (std.mem.eql(u8, row_id, id)) return .{ .dependencies = self.deps.items[i] };
        }
        return null;
    }

    fn lookup(self: *const DependencyCatalog) plugin_deps.Lookup {
        return .{ .ctx = self, .lookupFn = DependencyCatalog.lookupImpl };
    }
};

pub fn update(allocator: std.mem.Allocator, cwd: []const u8, kind: EntryKind, name: []const u8) ![]u8 {
    const removed = uninstall(allocator, kind, name) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (removed) |value| allocator.free(value);
    const installed = try install(allocator, cwd, kind, name);
    defer allocator.free(installed);
    return std.fmt.allocPrint(allocator, "updated {s} {s}", .{ kindName(kind), name });
}

pub fn uninstall(allocator: std.mem.Allocator, kind: EntryKind, name: []const u8) ![]u8 {
    return uninstallInCwd(allocator, ".", kind, name);
}

/// Uninstall worker that knows the `cwd` so it can compute the reverse-dependent
/// warning (plugins-05). `uninstall` keeps its narrow signature for existing
/// call sites by passing `cwd = "."`; callers that already hold a cwd should use
/// this directly so the warning sees the right workspace plugins.
pub fn uninstallInCwd(allocator: std.mem.Allocator, cwd: []const u8, kind: EntryKind, name: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0) return error.MissingToolArg;

    // Reverse-dependent warning (plugins-05): before removing a plugin, list the
    // enabled plugins that declare it as a dependency so the result can warn the
    // user that they will break. Computed pre-removal so the to-be-removed plugin
    // is still in the loaded set (it is excluded from its own dependents). A
    // failure here is non-fatal: the warning is omitted, the uninstall proceeds.
    var rdep_suffix: []u8 = try allocator.dupe(u8, "");
    defer allocator.free(rdep_suffix);
    if (kind == .plugin) {
        if (reverseDependentSuffix(allocator, cwd, trimmed)) |suffix| {
            allocator.free(rdep_suffix);
            rdep_suffix = suffix;
        } else |_| {}
    }

    switch (kind) {
        .plugin => {
            const root = try userPluginsRoot(allocator);
            defer allocator.free(root);
            const destination = try std.fs.path.join(allocator, &.{ root, trimmed });
            defer allocator.free(destination);
            // Detect not-installed up front so callers can surface a
            // clean "no such plugin" error and exit 1 without a Zig
            // trace. deleteTree on a missing target returns
            // FileNotFound on Linux but NotDir on some platforms.
            std.Io.Dir.cwd().access(rt.io, destination, .{}) catch |err| switch (err) {
                error.FileNotFound => return error.EntryNotInstalled,
                else => return err,
            };
            try std.Io.Dir.cwd().deleteTree(rt.io, destination);
        },
        .command => {
            const path = findInstalledCommandPath(allocator, trimmed) catch |err| switch (err) {
                error.FileNotFound => return error.EntryNotInstalled,
                else => return err,
            };
            defer allocator.free(path);
            try std.Io.Dir.cwd().deleteFile(rt.io, path);
        },
    }

    return std.fmt.allocPrint(allocator, "uninstalled {s} {s}{s}", .{ kindName(kind), trimmed, rdep_suffix });
}

/// Compute the " - warning: required by X, Y" suffix for uninstalling the plugin
/// `name`. Returns an empty owned slice when nothing depends on it. The target's
/// id is `name@local` (locally-discovered plugins carry that id).
fn reverseDependentSuffix(allocator: std.mem.Allocator, cwd: []const u8, name: []const u8) ![]u8 {
    const target_id = try plugin_settings.pluginId(allocator, name, null);
    defer allocator.free(target_id);

    const loaded = try plugins.list(allocator, cwd);
    defer plugins.freeList(allocator, loaded);

    var views = try allocator.alloc(plugin_deps.LoadedPlugin, loaded.len);
    defer allocator.free(views);
    for (loaded, 0..) |p, i| {
        views[i] = .{
            .source = p.plugin_id,
            .name = p.name,
            .enabled = p.enabled,
            .dependencies = p.dependencies,
        };
    }

    const rdeps = try plugin_deps.findReverseDependents(allocator, target_id, views);
    defer {
        for (rdeps) |s| allocator.free(s);
        allocator.free(rdeps);
    }
    return plugin_deps.formatReverseDependentsSuffix(allocator, rdeps);
}

pub fn renderSources(allocator: std.mem.Allocator) ![]u8 {
    const sources = try listSources(allocator);
    defer freeSources(allocator, sources);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    if (sources.len == 0) {
        try out.writer().writeAll("marketplace sources: none\n");
        return out.toOwnedSlice();
    }

    try out.writer().writeAll("marketplace sources:\n");
    for (sources) |source| {
        // Source registry is hand-editable JSON; sanitize each
        // field that flows into a TSV-style row.
        const safe_name = try display_safe.sanitize(allocator, source.name);
        defer allocator.free(safe_name);
        const safe_url = try display_safe.sanitize(allocator, source.url);
        defer allocator.free(safe_url);
        const safe_cache = try display_safe.sanitize(allocator, source.cache_path);
        defer allocator.free(safe_cache);
        try out.writer().print("- {s} url={s} cached={} cache={s}{s}\n", .{
            safe_name,
            safe_url,
            source.cached,
            safe_cache,
            if (source.sha256 != null) " verified=sha256" else "",
        });
    }
    return out.toOwnedSlice();
}

pub fn addSource(allocator: std.mem.Allocator, name: []const u8, url: []const u8, sha256: ?[]const u8) ![]u8 {
    const trimmed_name = std.mem.trim(u8, name, " \t\r\n");
    const trimmed_url = std.mem.trim(u8, url, " \t\r\n");
    if (trimmed_name.len == 0 or trimmed_url.len == 0) return error.MissingToolArg;

    if (isRemoteHttpUrl(trimmed_url)) {
        try security.ensureMarketplaceSourceAllowed(allocator, trimmed_url);
        if (sha256 == null) return error.MarketplaceIntegrityRequired;
    }

    const existing = try loadRegistrySources(allocator);
    defer freeRegistrySources(allocator, existing);

    var updated = std.array_list.Managed(RegistrySource).init(allocator);
    defer {
        for (updated.items) |*item| item.deinit(allocator);
        updated.deinit();
    }

    var replaced = false;
    for (existing) |item| {
        if (std.mem.eql(u8, item.name, trimmed_name)) {
            replaced = true;
            // Preserve the source's existing force_remove_deleted opt-in across
            // a url/sha256 update so re-adding does not silently revoke it.
            try appendRegistrySource(allocator, &updated, trimmed_name, trimmed_url, sha256, item.force_remove_deleted);
        } else {
            try appendRegistrySource(allocator, &updated, item.name, item.url, item.sha256, item.force_remove_deleted);
        }
    }

    if (!replaced) {
        try appendRegistrySource(allocator, &updated, trimmed_name, trimmed_url, sha256, false);
    }

    try writeRegistrySources(allocator, updated.items);
    try refreshOneSource(allocator, updated.items[if (replaced) findSourceIndex(updated.items, trimmed_name).? else updated.items.len - 1]);
    return std.fmt.allocPrint(allocator, "marketplace source {s}: {s}", .{ if (replaced) "updated" else "added", trimmed_name });
}

pub fn removeSource(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const trimmed_name = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed_name.len == 0) return error.MissingToolArg;

    const existing = try loadRegistrySources(allocator);
    defer freeRegistrySources(allocator, existing);

    var updated = std.array_list.Managed(RegistrySource).init(allocator);
    defer {
        for (updated.items) |*item| item.deinit(allocator);
        updated.deinit();
    }

    var removed = false;
    for (existing) |item| {
        if (std.mem.eql(u8, item.name, trimmed_name)) {
            removed = true;
            continue;
        }
        try appendRegistrySource(allocator, &updated, item.name, item.url, item.sha256, item.force_remove_deleted);
    }

    if (!removed) return error.MarketplaceEntryNotFound;
    try writeRegistrySources(allocator, updated.items);

    const cache_path = try cachePathForSource(allocator, trimmed_name);
    defer allocator.free(cache_path);
    std.Io.Dir.cwd().deleteFile(rt.io, cache_path) catch {};

    return std.fmt.allocPrint(allocator, "removed marketplace source {s}", .{trimmed_name});
}

pub fn refreshSources(allocator: std.mem.Allocator, requested_name: ?[]const u8) ![]u8 {
    const existing = try loadRegistrySources(allocator);
    defer freeRegistrySources(allocator, existing);
    if (existing.len == 0) return allocator.dupe(u8, "marketplace sources: none");

    const target = if (requested_name) |value| std.mem.trim(u8, value, " \t\r\n") else "";
    var refreshed: usize = 0;
    for (existing) |item| {
        if (target.len > 0 and !std.mem.eql(u8, item.name, target)) continue;
        try refreshOneSource(allocator, item);
        refreshed += 1;
    }

    if (refreshed == 0 and target.len > 0) return error.MarketplaceEntryNotFound;

    // Delisting detection (plugins-09): after refreshing, auto-uninstall any
    // user-scope plugin a `force_remove_deleted` source now marks deleted, and
    // record it in the flagged store. Best-effort and non-fatal: a failure here
    // must not turn a successful refresh into an error.
    const removed = detectAndUninstallDelisted(allocator, existing) catch 0;
    if (removed > 0) {
        return std.fmt.allocPrint(allocator, "refreshed marketplace sources: {d} (removed {d} delisted)", .{ refreshed, removed });
    }
    return std.fmt.allocPrint(allocator, "refreshed marketplace sources: {d}", .{refreshed});
}

/// Compare installed user-scope plugins against the refreshed catalogs and
/// auto-uninstall those a `force_remove_deleted` source marks `deleted`
/// (plugins-09). Returns the number of plugins removed. Conservative by design:
///   - Only user-scope plugins (under `userPluginsRoot`) are touched. Workspace
///     plugins are user-managed and never auto-removed (reference parity).
///   - Only sources that explicitly opt into `force_remove_deleted` can trigger
///     removal; a source without the flag leaves the plugin in place.
///   - A plugin already in the flagged store is skipped (no repeat work / no
///     repeat notice).
/// A failure for any one source is logged-and-skipped so one bad catalog does
/// not abort detection for the rest.
fn detectAndUninstallDelisted(allocator: std.mem.Allocator, sources: []const RegistrySource) !usize {
    // Snapshot the names of installed user-scope plugins (directory names under
    // the user plugins root). Cheap and cwd-independent; we match catalog
    // deletions against these by plugin name.
    var installed = try installedUserPluginNames(allocator);
    defer {
        for (installed.items) |n| allocator.free(n);
        installed.deinit();
    }
    if (installed.items.len == 0) return 0;

    var removed: usize = 0;
    for (sources) |source| {
        if (!source.force_remove_deleted) continue;

        // The catalog of deleted plugin names this source advertises.
        var deleted = collectDeletedPluginNames(allocator, source) catch continue;
        defer {
            for (deleted.items) |n| allocator.free(n);
            deleted.deinit();
        }
        if (deleted.items.len == 0) continue;

        for (installed.items) |name| {
            if (!containsString(deleted.items, name)) continue;

            const plugin_id = plugin_settings.pluginId(allocator, name, null) catch continue;
            defer allocator.free(plugin_id);

            // Skip plugins we have already flagged so a repeated refresh does
            // not re-notify (the directory is already gone in that case).
            if (plugin_flagging.isFlagged(allocator, plugin_id) catch false) continue;

            // Uninstall from user scope. A failure is logged-and-skipped: a
            // partial removal must not abort the whole detection pass.
            const msg = uninstall(allocator, .plugin, name) catch continue;
            allocator.free(msg);

            plugin_flagging.addFlagged(allocator, plugin_id) catch {};
            removed += 1;
            std_io.stderrWriter().print(
                "marketplace: removed delisted plugin '{s}' (deleted from source '{s}')\n",
                .{ name, source.name },
            ) catch {};
        }
    }
    return removed;
}

/// Directory names of installed user-scope plugins. Caller owns the list and
/// each string. A missing user plugins root yields an empty list.
fn installedUserPluginNames(allocator: std.mem.Allocator) !std.array_list.Managed([]u8) {
    var out = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (out.items) |n| allocator.free(n);
        out.deinit();
    }

    const root = try userPluginsRoot(allocator);
    defer allocator.free(root);

    var dir = std.Io.Dir.cwd().openDir(rt.io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return out,
        else => return err,
    };
    defer dir.close(rt.io);

    var it = dir.iterate();
    while (try it.next(rt.io)) |entry| {
        if (entry.kind != .directory) continue;
        try out.append(try allocator.dupe(u8, entry.name));
    }
    return out;
}

/// Names of plugin entries marked `deleted:true` in a source's cached catalog.
/// Caller owns the list and each string.
fn collectDeletedPluginNames(allocator: std.mem.Allocator, source: RegistrySource) !std.array_list.Managed([]u8) {
    var out = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (out.items) |n| allocator.free(n);
        out.deinit();
    }

    const cache_path = try cachePathForSource(allocator, source.name);
    defer allocator.free(cache_path);
    if (!fileExists(cache_path)) return out;

    var resolver = try resolverForCatalogSource(allocator, source.url);
    defer resolver.deinit(allocator);

    var entries = std.array_list.Managed(Entry).init(allocator);
    defer {
        for (entries.items) |*e| e.deinit(allocator);
        entries.deinit();
    }
    try appendCatalogEntriesFromPathWithResolver(
        allocator,
        &entries,
        cache_path,
        source.url,
        .remote,
        .plugin,
        resolver,
    );

    for (entries.items) |entry| {
        if (!entry.deleted) continue;
        try out.append(try allocator.dupe(u8, entry.name));
    }
    return out;
}

fn containsString(haystack: []const []u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

pub fn kindName(kind: EntryKind) []const u8 {
    return switch (kind) {
        .plugin => "plugin",
        .command => "command",
    };
}

pub fn scopeName(scope: EntryScope) []const u8 {
    return switch (scope) {
        .user => "user",
        .workspace => "workspace",
        .remote => "remote",
    };
}

// ── plugins-06: trust disclaimer before install/update ──────────────────────

/// Fixed legal disclaimer shown before a plugin install/update completes. Faithful
/// in intent to the reference PluginTrustWarning copy but provider-neutral: it warns
/// that plugins run code locally, can contribute MCP servers, and that zcode does not
/// vet third-party plugin behavior, so the user is responsible for trusting the
/// source. Plain hyphens only - no em/en dashes (CLAUDE.md rule).
pub const TRUST_WARNING_BODY =
    "Plugin trust warning:\n" ++
    "  Make sure you trust this plugin before installing it. Plugins run code\n" ++
    "  on your machine with your permissions and can contribute hooks, agents,\n" ++
    "  and MCP servers to your session. zcode does not control or vet what a\n" ++
    "  third-party plugin or the MCP servers it ships will do. Only install\n" ++
    "  plugins from sources you trust.";

/// Build the trust disclaimer text. When `custom` is non-null and non-empty
/// (for example a policy-supplied org message), it is appended on its own line.
/// Caller owns the returned slice.
pub fn trustWarning(allocator: std.mem.Allocator, custom: ?[]const u8) ![]u8 {
    if (custom) |msg| {
        const trimmed = std.mem.trim(u8, msg, " \t\r\n");
        if (trimmed.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}\n  {s}", .{ TRUST_WARNING_BODY, trimmed });
        }
    }
    return allocator.dupe(u8, TRUST_WARNING_BODY);
}

/// Process-level guard so the disclaimer is printed at most once per run, even
/// across multiple installs/updates in a single session (mirrors the reference
/// showing the warning once interactively). Exposed for tests to assert the
/// install path emitted it.
pub var trust_warning_emitted: bool = false;

/// Number of times the disclaimer was actually written to stderr this process.
/// Driven only by `emitTrustWarning`; exposed so tests can assert "exactly once"
/// without capturing stderr.
pub var trust_warning_emit_count: usize = 0;

/// Print the trust disclaimer to stderr (so it never pollutes stdout JSON),
/// exactly once per process. Called before any install side effect. A write
/// failure is non-fatal: the install must not be blocked by a stderr error
/// (would break headless/CI installs). `custom` is the optional policy message.
fn emitTrustWarning(allocator: std.mem.Allocator, custom: ?[]const u8) void {
    if (trust_warning_emitted) return;
    trust_warning_emitted = true;
    const text = trustWarning(allocator, custom) catch return;
    defer allocator.free(text);
    std_io.stderrWriter().print("{s}\n", .{text}) catch {};
    trust_warning_emit_count += 1;
}

pub fn freeList(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |*entry| entry.deinit(allocator);
    allocator.free(entries);
}

pub fn listSources(allocator: std.mem.Allocator) ![]SourceEntry {
    const registry = try loadRegistrySources(allocator);
    defer freeRegistrySources(allocator, registry);

    var out = std.array_list.Managed(SourceEntry).init(allocator);
    // Full errdefer walks items + frees strings on error. The old
    // `defer out.deinit()` only freed the ArrayList backing.
    errdefer {
        for (out.items) |*entry| entry.deinit(allocator);
        out.deinit();
    }

    for (registry) |item| {
        try out.ensureUnusedCapacity(1);
        const cache_path = try cachePathForSource(allocator, item.name);
        errdefer allocator.free(cache_path);
        const dup_name = try allocator.dupe(u8, item.name);
        errdefer allocator.free(dup_name);
        const dup_url = try allocator.dupe(u8, item.url);
        errdefer allocator.free(dup_url);
        const dup_sha: ?[]u8 = if (item.sha256) |value| try allocator.dupe(u8, value) else null;
        out.appendAssumeCapacity(.{
            .name = dup_name,
            .url = dup_url,
            .sha256 = dup_sha,
            .cache_path = cache_path,
            .cached = fileExists(cache_path),
        });
    }

    return out.toOwnedSlice();
}

pub fn freeSources(allocator: std.mem.Allocator, entries: []SourceEntry) void {
    for (entries) |*entry| entry.deinit(allocator);
    allocator.free(entries);
}

fn findEntry(allocator: std.mem.Allocator, cwd: []const u8, kind: EntryKind, name: []const u8) !Entry {
    const entries = try list(allocator, cwd, kind);
    defer freeList(allocator, entries);
    for (entries) |entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        // Stage every dupe so a later OOM unwinds prior allocations.
        const dup_name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(dup_name);
        const dup_description = try allocator.dupe(u8, entry.description);
        errdefer allocator.free(dup_description);
        const dup_source = try allocator.dupe(u8, entry.source);
        errdefer allocator.free(dup_source);
        const dup_manifest_path = try allocator.dupe(u8, entry.manifest_path);
        errdefer allocator.free(dup_manifest_path);
        const dup_source_sha256: ?[]u8 = if (entry.source_sha256) |value| try allocator.dupe(u8, value) else null;
        errdefer if (dup_source_sha256) |v| allocator.free(v);
        const dup_package_format: ?[]u8 = if (entry.package_format) |value| try allocator.dupe(u8, value) else null;
        errdefer if (dup_package_format) |v| allocator.free(v);
        const dup_dependencies = try dupeStringList(allocator, entry.dependencies);
        errdefer {
            for (dup_dependencies) |dep| allocator.free(dep);
            allocator.free(dup_dependencies);
        }
        const dup_version: ?[]u8 = if (entry.version) |value| try allocator.dupe(u8, value) else null;
        return .{
            .name = dup_name,
            .kind = entry.kind,
            .description = dup_description,
            .source = dup_source,
            .manifest_path = dup_manifest_path,
            .scope = entry.scope,
            .featured = entry.featured,
            .source_sha256 = dup_source_sha256,
            .package_format = dup_package_format,
            .dependencies = dup_dependencies,
            .deleted = entry.deleted,
            .version = dup_version,
            .auto_update = entry.auto_update,
        };
    }
    return error.MarketplaceEntryNotFound;
}

fn appendCatalogEntriesFromPath(
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed(Entry),
    catalog_path: []const u8,
    scope: EntryScope,
    filter: ?EntryKind,
) !void {
    var resolver = SourceResolver{ .base_dir = try allocator.dupe(u8, std.fs.path.dirname(catalog_path) orelse ".") };
    defer resolver.deinit(allocator);
    try appendCatalogEntriesFromPathWithResolver(allocator, out, catalog_path, catalog_path, scope, filter, resolver);
}

fn appendCatalogEntriesFromPathWithResolver(
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed(Entry),
    catalog_path: []const u8,
    manifest_label: []const u8,
    scope: EntryScope,
    filter: ?EntryKind,
    resolver: SourceResolver,
) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, catalog_path, allocator, .limited(512 * 1024)) catch return;
    defer allocator.free(bytes);
    try appendCatalogEntriesFromBytes(allocator, out, bytes, manifest_label, scope, filter, resolver);
}

fn appendCatalogEntriesFromBytes(
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed(Entry),
    bytes: []const u8,
    manifest_label: []const u8,
    scope: EntryScope,
    filter: ?EntryKind,
    resolver: SourceResolver,
) !void {
    var parsed = try parse_helpers.parseJsonBounded(std.json.Value, allocator, bytes);
    defer parsed.deinit();
    if (parsed.value != .array) return;

    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const kind = parseKind(getString(item.object, "kind") orelse continue) orelse continue;
        if (filter) |expected| if (kind != expected) continue;

        const name = getString(item.object, "name") orelse continue;
        const description = getString(item.object, "description") orelse "";
        const raw_source = getString(item.object, "source") orelse continue;

        // Stage every fallible allocation so a mid-row OOM releases all
        // previously-allocated fields. Previously the only protection was
        // `errdefer free(source)`; the other four dupes inside the struct
        // literal had no guard.
        try out.ensureUnusedCapacity(1);
        const source = try resolveSourceValue(allocator, resolver, raw_source);
        errdefer allocator.free(source);
        const dup_name = try allocator.dupe(u8, name);
        errdefer allocator.free(dup_name);
        const dup_description = try allocator.dupe(u8, description);
        errdefer allocator.free(dup_description);
        const dup_manifest = try allocator.dupe(u8, manifest_label);
        errdefer allocator.free(dup_manifest);
        const dup_source_sha256: ?[]u8 = if (getString(item.object, "source_sha256")) |value| try allocator.dupe(u8, value) else null;
        errdefer if (dup_source_sha256) |v| allocator.free(v);
        const dup_package_format: ?[]u8 = if (getString(item.object, "package_format")) |value| try allocator.dupe(u8, value) else null;
        errdefer if (dup_package_format) |v| allocator.free(v);
        const dup_dependencies = try parseStringArray(allocator, item.object.get("dependencies"));
        errdefer {
            for (dup_dependencies) |dep| allocator.free(dep);
            allocator.free(dup_dependencies);
        }
        const dup_version: ?[]u8 = if (getString(item.object, "version")) |value| try allocator.dupe(u8, value) else null;
        out.appendAssumeCapacity(.{
            .name = dup_name,
            .kind = kind,
            .description = dup_description,
            .source = source,
            .manifest_path = dup_manifest,
            .scope = scope,
            .featured = getBool(item.object, "featured") orelse false,
            .source_sha256 = dup_source_sha256,
            .package_format = dup_package_format,
            .dependencies = dup_dependencies,
            .deleted = getBool(item.object, "deleted") orelse false,
            .version = dup_version,
            .auto_update = getBool(item.object, "auto_update") orelse false,
        });
    }
}

fn installPlugin(allocator: std.mem.Allocator, entry: Entry) ![]u8 {
    const root = try userPluginsRoot(allocator);
    defer allocator.free(root);
    return installPluginToRoot(allocator, entry, root);
}

fn installCommand(allocator: std.mem.Allocator, entry: Entry) ![]u8 {
    const root = try userCommandsRoot(allocator);
    defer allocator.free(root);
    return installCommandToRoot(allocator, entry, root);
}

fn installRemotePlugin(allocator: std.mem.Allocator, entry: Entry) ![]u8 {
    if (entry.source_sha256 == null) return error.MarketplaceIntegrityRequired;
    try security.ensureMarketplaceSourceAllowed(allocator, entry.source);

    const tmp_root = try marketplaceTempRoot(allocator);
    defer allocator.free(tmp_root);
    try paths.ensureDir(tmp_root);

    const archive_path = try std.fs.path.join(allocator, &.{ tmp_root, "plugin.tar.gz" });
    defer allocator.free(archive_path);
    defer std.Io.Dir.cwd().deleteFile(rt.io, archive_path) catch {};
    try downloadToPath(allocator, entry.source, archive_path);
    try verifyFileSha256(allocator, archive_path, entry.source_sha256.?);

    const unpack_root = try std.fs.path.join(allocator, &.{ tmp_root, "plugin-unpack" });
    defer allocator.free(unpack_root);
    std.Io.Dir.cwd().deleteTree(rt.io, unpack_root) catch {};
    try paths.ensureDir(unpack_root);
    defer std.Io.Dir.cwd().deleteTree(rt.io, unpack_root) catch {};

    const format = entry.package_format orelse inferPackageFormat(entry.source) orelse return error.UnsupportedMarketplaceSource;
    if (!(std.mem.eql(u8, format, "tar.gz") or std.mem.eql(u8, format, "tgz"))) return error.UnsupportedMarketplaceSource;
    // --no-same-owner: never try to restore uid/gid from the archive.
    // --no-same-permissions: ignore archive modes, use the umask. This stops
    // a malicious package from granting itself execute bits it shouldn't have.
    // -P is intentionally NOT passed so tar rejects absolute-path members.
    try runCommandChecked(allocator, &.{
        "tar",                   "--no-same-owner",
        "--no-same-permissions", "-xzf",
        archive_path,            "-C",
        unpack_root,
    }, 256 * 1024);

    const extract_root = try findPluginExtractRoot(allocator, unpack_root);
    defer allocator.free(extract_root);

    const root = try userPluginsRoot(allocator);
    defer allocator.free(root);
    var temp_entry = Entry{
        .name = try allocator.dupe(u8, entry.name),
        .kind = .plugin,
        .description = try allocator.dupe(u8, entry.description),
        .source = try allocator.dupe(u8, extract_root),
        .manifest_path = try allocator.dupe(u8, entry.manifest_path),
        .scope = entry.scope,
        .featured = entry.featured,
        .source_sha256 = null,
        .package_format = null,
    };
    defer temp_entry.deinit(allocator);
    return installPluginToRoot(allocator, temp_entry, root);
}

fn installRemoteCommand(allocator: std.mem.Allocator, entry: Entry) ![]u8 {
    if (entry.source_sha256 == null) return error.MarketplaceIntegrityRequired;
    try security.ensureMarketplaceSourceAllowed(allocator, entry.source);

    const tmp_root = try marketplaceTempRoot(allocator);
    defer allocator.free(tmp_root);
    try paths.ensureDir(tmp_root);

    const download_name = try std.fmt.allocPrint(allocator, "{s}.md", .{entry.name});
    defer allocator.free(download_name);
    const temp_path = try std.fs.path.join(allocator, &.{ tmp_root, download_name });
    defer allocator.free(temp_path);
    defer std.Io.Dir.cwd().deleteFile(rt.io, temp_path) catch {};

    try downloadToPath(allocator, entry.source, temp_path);
    try verifyFileSha256(allocator, temp_path, entry.source_sha256.?);

    const root = try userCommandsRoot(allocator);
    defer allocator.free(root);
    var temp_entry = Entry{
        .name = try allocator.dupe(u8, entry.name),
        .kind = .command,
        .description = try allocator.dupe(u8, entry.description),
        .source = try allocator.dupe(u8, temp_path),
        .manifest_path = try allocator.dupe(u8, entry.manifest_path),
        .scope = entry.scope,
        .featured = entry.featured,
        .source_sha256 = null,
        .package_format = null,
    };
    defer temp_entry.deinit(allocator);
    return installCommandToRoot(allocator, temp_entry, root);
}

fn installPluginToRoot(allocator: std.mem.Allocator, entry: Entry, root: []const u8) ![]u8 {
    try paths.ensureDir(root);
    const destination = try std.fs.path.join(allocator, &.{ root, entry.name });
    errdefer allocator.free(destination);
    std.Io.Dir.cwd().deleteTree(rt.io, destination) catch {};
    try copyTree(allocator, entry.source, destination);
    return destination;
}

fn installCommandToRoot(allocator: std.mem.Allocator, entry: Entry, root: []const u8) ![]u8 {
    try paths.ensureDir(root);

    const base = if (std.mem.endsWith(u8, entry.source, ".md"))
        std.fs.path.basename(entry.source)
    else
        try std.fmt.allocPrint(allocator, "{s}.md", .{entry.name});
    defer if (!std.mem.endsWith(u8, entry.source, ".md")) allocator.free(base);

    const destination = try std.fs.path.join(allocator, &.{ root, base });
    errdefer allocator.free(destination);
    std.Io.Dir.cwd().deleteFile(rt.io, destination) catch {};
    try copyFile(entry.source, destination);
    return destination;
}

fn findInstalledCommandPath(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const root = try userCommandsRoot(allocator);
    defer allocator.free(root);

    var dir = std.Io.Dir.cwd().openDir(rt.io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer dir.close(rt.io);

    var it = dir.iterate();
    while (try it.next(rt.io)) |entry| {
        if (entry.kind != .file) continue;
        const stem = filenameStem(entry.name);
        if (!std.mem.eql(u8, stem, name)) continue;
        return std.fs.path.join(allocator, &.{ root, entry.name });
    }
    return error.FileNotFound;
}

fn userCatalogPath(allocator: std.mem.Allocator) ![]u8 {
    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);
    return std.fs.path.join(allocator, &.{ resolved.zcode_home, "marketplace.json" });
}

fn userPluginsRoot(allocator: std.mem.Allocator) ![]u8 {
    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);
    return std.fs.path.join(allocator, &.{ resolved.zcode_home, "plugins" });
}

fn userCommandsRoot(allocator: std.mem.Allocator) ![]u8 {
    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);
    return std.fs.path.join(allocator, &.{ resolved.zcode_home, "commands" });
}

fn registryPath(allocator: std.mem.Allocator) ![]u8 {
    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);
    return std.fs.path.join(allocator, &.{ resolved.zcode_home, "marketplace", "sources.json" });
}

fn cacheRoot(allocator: std.mem.Allocator) ![]u8 {
    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);
    return std.fs.path.join(allocator, &.{ resolved.zcode_home, "marketplace", "cache" });
}

fn marketplaceTempRoot(allocator: std.mem.Allocator) ![]u8 {
    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);
    return std.fs.path.join(allocator, &.{ resolved.zcode_home, "marketplace", "tmp" });
}

fn cachePathForSource(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const root = try cacheRoot(allocator);
    defer allocator.free(root);
    const slug = try slugify(allocator, name);
    defer allocator.free(slug);
    const filename = try std.fmt.allocPrint(allocator, "{s}.json", .{slug});
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ root, filename });
}

fn loadRegistrySources(allocator: std.mem.Allocator) ![]RegistrySource {
    const path = try registryPath(allocator);
    defer allocator.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(RegistrySource, 0),
        else => return err,
    };
    defer allocator.free(bytes);

    var parsed = try parse_helpers.parseJsonBounded(std.json.Value, allocator, bytes);
    defer parsed.deinit();
    if (parsed.value != .array) return allocator.alloc(RegistrySource, 0);

    var out = std.array_list.Managed(RegistrySource).init(allocator);
    // Full errdefer walks items + frees every appended row's strings.
    // `defer out.deinit()` would only free the backing storage.
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit();
    }
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const name = getString(item.object, "name") orelse continue;
        const url = getString(item.object, "url") orelse continue;
        const force_remove = getBool(item.object, "force_remove_deleted") orelse false;
        try appendRegistrySource(allocator, &out, name, url, getString(item.object, "sha256"), force_remove);
    }
    return out.toOwnedSlice();
}

fn writeRegistrySources(allocator: std.mem.Allocator, items: []const RegistrySource) !void {
    const path = try registryPath(allocator);
    defer allocator.free(path);

    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try paths.ensureDir(parent);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try out.writer().writeAll("[\n");
    for (items, 0..) |item, idx| {
        if (idx > 0) try out.writer().writeAll(",\n");
        try out.writer().print("  {f}", .{std.json.fmt(.{
            .name = item.name,
            .url = item.url,
            .sha256 = item.sha256,
            .force_remove_deleted = item.force_remove_deleted,
        }, .{})});
    }
    try out.writer().writeAll("\n]\n");

    // Atomic write: a SIGINT in the truncate->writeAll window would
    // zero `sources.json` and silently drop every marketplace source
    // the user has added with `zcode marketplace add ...`. Same
    // discipline as keychain.zig (pass 64), logger.zig (pass 65),
    // control_plane.zig (pass 66), and security.zig (pass 67).
    try writeRegistryFileAtomic(allocator, path, out.items());
}

fn writeRegistryFileAtomic(allocator: std.mem.Allocator, target: []const u8, bytes: []const u8) !void {
    var nonce: [8]u8 = undefined;
    rng.bytes(&nonce);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{x}{x}{x}{x}{x}{x}{x}{x}", .{
        target, nonce[0], nonce[1], nonce[2], nonce[3], nonce[4], nonce[5], nonce[6], nonce[7],
    });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, bytes);
        file.sync(rt.io) catch {};
        file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o600)) catch {};
    }
    try std.Io.Dir.renameAbsolute(tmp_path, target, rt.io);
}

fn freeRegistrySources(allocator: std.mem.Allocator, items: []RegistrySource) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

fn resolverForCatalogSource(allocator: std.mem.Allocator, url: []const u8) !SourceResolver {
    if (isRemoteHttpUrl(url)) {
        return .{ .base_url = try baseUrlForCatalog(allocator, url) };
    }
    if (isFileUrl(url)) {
        const local = try localPathFromFileUrl(allocator, url);
        defer allocator.free(local);
        return .{ .base_dir = try allocator.dupe(u8, std.fs.path.dirname(local) orelse ".") };
    }
    if (std.fs.path.isAbsolute(url)) {
        return .{ .base_dir = try allocator.dupe(u8, std.fs.path.dirname(url) orelse ".") };
    }
    return error.InvalidMarketplaceSource;
}

fn resolveSourceValue(allocator: std.mem.Allocator, resolver: SourceResolver, raw_source: []const u8) ![]u8 {
    if (isRemoteHttpUrl(raw_source)) return allocator.dupe(u8, raw_source);
    if (isFileUrl(raw_source)) return localPathFromFileUrl(allocator, raw_source);
    if (std.fs.path.isAbsolute(raw_source)) return allocator.dupe(u8, raw_source);
    if (resolver.base_url) |base_url| return joinUrl(allocator, base_url, raw_source);
    if (resolver.base_dir) |base_dir| return std.fs.path.join(allocator, &.{ base_dir, raw_source });
    return error.InvalidMarketplaceSource;
}

fn refreshOneSource(allocator: std.mem.Allocator, source: RegistrySource) !void {
    // Every source (remote or file://) passes through the marketplace
    // policy gate so a catalog cannot smuggle a local-path entry that
    // reads arbitrary files. Integrity pinning remains required only
    // for remote URLs -- local files are subject to the same policy
    // plus a realpath check inside localPathFromFileUrl.
    try security.ensureMarketplaceSourceAllowed(allocator, source.url);
    if (isRemoteHttpUrl(source.url)) {
        if (source.sha256 == null) return error.MarketplaceIntegrityRequired;
    }

    const cache_path = try cachePathForSource(allocator, source.name);
    defer allocator.free(cache_path);
    const parent = std.fs.path.dirname(cache_path) orelse return error.InvalidPath;
    try paths.ensureDir(parent);

    try downloadToPath(allocator, source.url, cache_path);
    if (source.sha256) |value| try verifyFileSha256(allocator, cache_path, value);
    const cache_file = try std.Io.Dir.cwd().openFile(rt.io, cache_path, .{ .mode = .read_write });
    defer cache_file.close(rt.io);
    cache_file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o600)) catch {};
}

fn findSourceIndex(items: []const RegistrySource, name: []const u8) ?usize {
    for (items, 0..) |item, idx| {
        if (std.mem.eql(u8, item.name, name)) return idx;
    }
    return null;
}

fn downloadToPath(allocator: std.mem.Allocator, source: []const u8, destination: []const u8) !void {
    if (isRemoteHttpUrl(source)) {
        // Route through the central egress chokepoint. A user-added
        // marketplace source URL goes through curl with no scheme or
        // SSRF check otherwise, which would let
        // `zcode marketplace add evil http://...` fetch a plaintext
        // catalog (no transport integrity even when SHA256 pin is
        // required, since the pin lives in the catalog itself) and
        // would let https://169.254.169.254/... reach cloud metadata
        // through the marketplace path.
        switch (egress.checkUrl(allocator, source, .{})) {
            .allow => {},
            .deny_scheme, .deny_ssrf, .deny_allowlist, .deny_denylist => return error.UrlPolicyDenied,
        }
        // Allow whatever scheme egress.checkUrl just approved
        // (https:// for any host, or http:// for loopback only) but
        // pin redirect targets to https so a 3xx into file:// /
        // gopher:// / dict:// or a plaintext exfiltration host is
        // refused at the curl layer too.
        // Bound the catalog fetch: 60s total is plenty for catalog
        // JSONs, and 10s connect-timeout keeps a hung mirror from
        // blocking the whole `marketplace refresh` invocation.
        const args = [_][]const u8{
            "curl",              "-fsSL",
            "--proto-redir",     "=https",
            "--connect-timeout", "10",
            "--max-time",        "60",
            "-o",                destination,
            source,
        };
        const result = std.process.run(allocator, rt.io, .{
            .argv = &args,
            .stdout_limit = .limited(128 * 1024),
            .stderr_limit = .limited(128 * 1024),
        }) catch return error.CommandFailed;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (!(result.term == .exited and result.term.exited == 0)) return error.CommandFailed;
        return;
    }

    if (isFileUrl(source)) {
        const local = try localPathFromFileUrl(allocator, source);
        defer allocator.free(local);
        return copyFile(local, destination);
    }

    if (std.fs.path.isAbsolute(source)) {
        return copyFile(source, destination);
    }

    return error.InvalidMarketplaceSource;
}

fn verifyFileSha256(allocator: std.mem.Allocator, path: []const u8, expected_hex: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(32 * 1024 * 1024));
    defer allocator.free(bytes);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

    var actual = std_io.StringBuilder.init(allocator);
    defer actual.deinit();
    for (digest) |byte| {
        try actual.writer().print("{x:0>2}", .{byte});
    }

    if (!std.ascii.eqlIgnoreCase(actual.items(), std.mem.trim(u8, expected_hex, " \t\r\n"))) {
        return error.MarketplaceIntegrityMismatch;
    }
}

fn findPluginExtractRoot(allocator: std.mem.Allocator, unpack_root: []const u8) ![]u8 {
    const direct_manifest = try std.fs.path.join(allocator, &.{ unpack_root, "plugin.json" });
    defer allocator.free(direct_manifest);
    if (fileExists(direct_manifest)) return allocator.dupe(u8, unpack_root);

    var dir = try std.Io.Dir.cwd().openDir(rt.io, unpack_root, .{ .iterate = true });
    defer dir.close(rt.io);

    var it = dir.iterate();
    var child_dir: ?[]u8 = null;
    defer if (child_dir) |value| allocator.free(value);
    while (try it.next(rt.io)) |entry| {
        switch (entry.kind) {
            .directory => {
                if (child_dir != null) return error.InvalidMarketplacePackage;
                child_dir = try allocator.dupe(u8, entry.name);
            },
            .file => return error.InvalidMarketplacePackage,
            // Reject any non-file, non-directory entry (symlinks, FIFOs,
            // block/char devices, sockets). A malicious package could
            // otherwise plant a symlink that later tooling might follow.
            else => return error.InvalidMarketplacePackage,
        }
    }

    const only_child = child_dir orelse return error.InvalidMarketplacePackage;
    const child_root = try std.fs.path.join(allocator, &.{ unpack_root, only_child });
    errdefer allocator.free(child_root);
    const child_manifest = try std.fs.path.join(allocator, &.{ child_root, "plugin.json" });
    defer allocator.free(child_manifest);
    if (!fileExists(child_manifest)) {
        allocator.free(child_root);
        return error.InvalidMarketplacePackage;
    }
    return child_root;
}

fn baseUrlForCatalog(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    const slash = std.mem.lastIndexOfScalar(u8, url, '/') orelse return error.InvalidMarketplaceSource;
    return allocator.dupe(u8, url[0 .. slash + 1]);
}

fn joinUrl(allocator: std.mem.Allocator, base: []const u8, rel: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, rel, "/")) {
        const scheme_end = std.mem.indexOf(u8, base, "://") orelse return error.InvalidMarketplaceSource;
        const host_start = scheme_end + 3;
        const slash = std.mem.indexOfScalarPos(u8, base, host_start, '/') orelse return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, rel });
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ base[0..slash], rel });
    }
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, rel });
}

fn localPathFromFileUrl(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    if (!isFileUrl(url)) return error.InvalidMarketplaceSource;
    const rest = url["file://".len..];

    // Reject traversal patterns in the URL itself. A catalog entry
    // like "file:///opt/blessed/../../etc/passwd" would otherwise
    // survive the policy allow-list (which matches on prefix) while
    // escaping the blessed directory via `..`.
    if (std.mem.indexOf(u8, rest, "/../") != null) return error.InvalidMarketplaceSource;
    if (std.mem.endsWith(u8, rest, "/..")) return error.InvalidMarketplaceSource;
    if (std.mem.startsWith(u8, rest, "../")) return error.InvalidMarketplaceSource;

    return allocator.dupe(u8, rest);
}

fn inferPackageFormat(source: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, source, ".tar.gz")) return "tar.gz";
    if (std.mem.endsWith(u8, source, ".tgz")) return "tgz";
    return null;
}

fn copyTree(allocator: std.mem.Allocator, source: []const u8, destination: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(rt.io, source, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => {
            try copyFile(source, destination);
            return;
        },
        else => return err,
    };
    defer dir.close(rt.io);

    try paths.ensureDir(destination);

    var it = dir.iterate();
    while (try it.next(rt.io)) |entry| {
        const src_path = try std.fs.path.join(allocator, &.{ source, entry.name });
        defer allocator.free(src_path);
        const dst_path = try std.fs.path.join(allocator, &.{ destination, entry.name });
        defer allocator.free(dst_path);

        switch (entry.kind) {
            .directory => try copyTree(allocator, src_path, dst_path),
            .file => try copyFile(src_path, dst_path),
            else => return error.UnsupportedMarketplaceSource,
        }
    }
}

fn copyFile(source: []const u8, destination: []const u8) !void {
    const src_file = try std.Io.Dir.cwd().openFile(rt.io, source, .{});
    defer src_file.close(rt.io);
    const src_stat = try src_file.stat(rt.io);
    const parent = std.fs.path.dirname(destination) orelse return error.InvalidPath;
    try paths.ensureDir(parent);

    // Atomic: write to a sibling .tmp and rename. Marketplace copies
    // plugin/command manifests into ~/.zcode/plugins/<name>/, and a
    // SIGINT mid-copy used to leave a half-populated destination that
    // the next `zcode plugins list` would parse as corrupted. The
    // tmp lives next to the destination so the rename is same-fs and
    // inode-cheap. Attaches a best-effort errdefer to clean up the
    // tmp if writeAll or chmod fails before the rename.
    var tmp_name_buf: [40]u8 = undefined;
    var rand_bytes: [8]u8 = undefined;
    rng.bytes(&rand_bytes);
    const alphabet = "0123456789abcdef";
    var hex: [16]u8 = undefined;
    for (rand_bytes, 0..) |b, i| {
        hex[i * 2] = alphabet[b >> 4];
        hex[i * 2 + 1] = alphabet[b & 0x0f];
    }
    const tmp_suffix = std.fmt.bufPrint(&tmp_name_buf, ".tmp.{s}", .{hex[0..]}) catch return error.InvalidPath;
    // Allocate on the stack because we only ever hold it for the
    // duration of this function.
    var tmp_path_buf: [std.fs.max_path_bytes + 40]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}{s}", .{ destination, tmp_suffix }) catch return error.InvalidPath;

    {
        const dst_file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true });
        defer dst_file.close(rt.io);
        errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

        var buf: [8192]u8 = undefined;
        var offset: u64 = 0;
        while (true) {
            const n = try src_file.readPositionalAll(rt.io, &buf, offset);
            if (n == 0) break;
            try dst_file.writeStreamingAll(rt.io, buf[0..n]);
            offset += n;
            if (n < buf.len) break;
        }
        dst_file.setPermissions(rt.io, src_stat.permissions) catch {};
        dst_file.sync(rt.io) catch {};
    }
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};
    try std.Io.Dir.renameAbsolute(tmp_path, destination, rt.io);
}

fn parseKind(raw: []const u8) ?EntryKind {
    if (std.mem.eql(u8, raw, "plugin")) return .plugin;
    if (std.mem.eql(u8, raw, "command")) return .command;
    return null;
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

/// Parse a JSON array of strings into an owned slice of owned strings. A missing
/// or non-array value yields an empty (still owned) slice. Non-string elements
/// are skipped. Used for the catalog entry's `dependencies` (plugins-05).
fn parseStringArray(allocator: std.mem.Allocator, value: ?std.json.Value) ![]const []const u8 {
    const v = value orelse return allocator.alloc([]const u8, 0);
    if (v != .array) return allocator.alloc([]const u8, 0);

    var out = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit();
    }
    for (v.array.items) |item| {
        if (item != .string) continue;
        try out.append(try allocator.dupe(u8, item.string));
    }
    return out.toOwnedSlice();
}

/// Deep-copy an owned slice of owned strings (used when re-materializing an
/// Entry in `findEntry`). Leak-safe: a mid-copy OOM frees the partial result.
fn dupeStringList(allocator: std.mem.Allocator, items: []const []const u8) ![]const []const u8 {
    var out = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit();
    }
    for (items) |item| try out.append(try allocator.dupe(u8, item));
    return out.toOwnedSlice();
}

fn isRemoteHttpUrl(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "http://") or std.mem.startsWith(u8, value, "https://");
}

fn isFileUrl(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "file://");
}

fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(rt.io, path, .{}) catch return false;
    return true;
}

fn slugify(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch)) {
            try out.append(std.ascii.toLower(ch));
        } else if (out.items().len == 0 or out.items()[out.items().len - 1] == '-') {
            continue;
        } else {
            try out.append('-');
        }
    }
    if (out.items().len == 0) try out.appendSlice("source");
    return out.toOwnedSlice();
}

fn filenameStem(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    return if (std.mem.endsWith(u8, base, ".md")) base[0 .. base.len - ".md".len] else base;
}

fn runCommandChecked(allocator: std.mem.Allocator, argv: []const []const u8, max_output: usize) !void {
    const result = try std.process.run(allocator, rt.io, .{
        .argv = argv,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!(result.term == .exited and result.term.exited == 0)) return error.CommandFailed;
}

const testing = std.testing;

test "localPathFromFileUrl rejects path traversal patterns" {
    const alloc = testing.allocator;

    // Plain file:// URL passes and returns the stripped path.
    const ok = try localPathFromFileUrl(alloc, "file:///opt/marketplace/index.json");
    defer alloc.free(ok);
    try testing.expectEqualStrings("/opt/marketplace/index.json", ok);

    // `..` traversal within the path is rejected.
    try testing.expectError(error.InvalidMarketplaceSource, localPathFromFileUrl(alloc, "file:///opt/blessed/../../etc/passwd"));
    try testing.expectError(error.InvalidMarketplaceSource, localPathFromFileUrl(alloc, "file:///opt/blessed/.."));
    try testing.expectError(error.InvalidMarketplaceSource, localPathFromFileUrl(alloc, "file://../relative"));

    // Non-file URL rejected outright.
    try testing.expectError(error.InvalidMarketplaceSource, localPathFromFileUrl(alloc, "https://example.com"));
}

test "render list and install from workspace marketplace" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".zcode/catalog-src/review-plus");
    try tmp.dir.createDirPath(rt.io, ".zcode/catalog-src/commands");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/marketplace.json",
        .data =
        \\[
        \\  {"name":"review-plus","kind":"plugin","description":"plugin","source":"catalog-src/review-plus","featured":true},
        \\  {"name":"triage","kind":"command","description":"command","source":"catalog-src/commands/triage.md"}
        \\]
        ,
    });
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/catalog-src/review-plus/plugin.json",
        .data = "{\"name\":\"review-plus\",\"version\":\"0.1.0\"}",
    });
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/catalog-src/commands/triage.md",
        .data = "# triage",
    });

    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer allocator.free(cwd);

    const rendered = try renderList(allocator, cwd, null);
    defer allocator.free(rendered);
    try testing.expect(std.mem.indexOf(u8, rendered, "review-plus") != null);
}

test "install helpers copy plugin directories and command files" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, "catalog/review-plus");
    try tmp.dir.createDirPath(rt.io, "user/plugins");
    try tmp.dir.createDirPath(rt.io, "user/commands");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "catalog/review-plus/plugin.json",
        .data = "{\"name\":\"review-plus\",\"version\":\"0.1.0\"}",
    });
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "catalog/review-plus/run.sh",
        .data = "#!/bin/sh\necho hi\n",
    });
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "catalog/triage.md",
        .data = "# triage",
    });

    const plugin_source = try @import("test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "catalog/review-plus");
    defer allocator.free(plugin_source);
    const command_source = try @import("test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "catalog/triage.md");
    defer allocator.free(command_source);
    const plugin_root = try @import("test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "user/plugins");
    defer allocator.free(plugin_root);
    const command_root = try @import("test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "user/commands");
    defer allocator.free(command_root);

    var plugin_entry = Entry{
        .name = try allocator.dupe(u8, "review-plus"),
        .kind = .plugin,
        .description = try allocator.dupe(u8, "plugin"),
        .source = try allocator.dupe(u8, plugin_source),
        .manifest_path = try allocator.dupe(u8, "catalog"),
        .scope = .workspace,
        .featured = false,
    };
    defer plugin_entry.deinit(allocator);

    var command_entry = Entry{
        .name = try allocator.dupe(u8, "triage"),
        .kind = .command,
        .description = try allocator.dupe(u8, "command"),
        .source = try allocator.dupe(u8, command_source),
        .manifest_path = try allocator.dupe(u8, "catalog"),
        .scope = .workspace,
        .featured = false,
    };
    defer command_entry.deinit(allocator);

    const plugin_destination = try installPluginToRoot(allocator, plugin_entry, plugin_root);
    defer allocator.free(plugin_destination);
    const command_destination = try installCommandToRoot(allocator, command_entry, command_root);
    defer allocator.free(command_destination);

    try testing.expect(fileExists(plugin_destination));
    try testing.expect(fileExists(command_destination));
}

test "verifyFileSha256 rejects mismatched digest" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "demo.txt", .data = "hello\n" });
    const path = try @import("test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "demo.txt");
    defer allocator.free(path);

    try testing.expectError(error.MarketplaceIntegrityMismatch, verifyFileSha256(allocator, path, "deadbeef"));
}

// ── plugins-05: dependency-closure install + reverse-dependent uninstall ──

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "Task 17.5: install resolves dependency closure and uninstall warns reverse-dependents" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Pin HOME (clear XDG_CONFIG_HOME) so userPluginsRoot/userCatalogPath
    // resolve into <tmp>/.zcode. The cwd is a distinct subdir so installed
    // user-scope plugins are not double-counted as workspace plugins, and the
    // workspace catalog lives under the cwd's .zcode.
    const home = try @import("test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(home);
    const env = @import("env.zig");
    const prev_home = env.getOwned(allocator, "HOME") catch null;
    defer if (prev_home) |h| allocator.free(h);
    const prev_xdg = env.getOwned(allocator, "XDG_CONFIG_HOME") catch null;
    defer if (prev_xdg) |x| allocator.free(x);
    {
        const home_z = try allocator.dupeZ(u8, home);
        defer allocator.free(home_z);
        _ = setenv("HOME", home_z, 1);
        _ = unsetenv("XDG_CONFIG_HOME");
    }
    defer {
        if (prev_home) |h| {
            const z = allocator.dupeZ(u8, h) catch null;
            if (z) |zz| {
                _ = setenv("HOME", zz, 1);
                allocator.free(zz);
            }
        } else _ = unsetenv("HOME");
        if (prev_xdg) |x| {
            const z = allocator.dupeZ(u8, x) catch null;
            if (z) |zz| {
                _ = setenv("XDG_CONFIG_HOME", zz, 1);
                allocator.free(zz);
            }
        } else _ = unsetenv("XDG_CONFIG_HOME");
    }

    // Workspace catalog lives under <cwd>/.zcode. The catalog declares root-pl
    // depending on dep-pl; both source dirs ship a plugin.json. The plugin
    // manifests carry `dependencies` too so plugins.list (which reads manifests)
    // sees the reverse edge.
    try tmp.dir.createDirPath(rt.io, "proj/.zcode/catalog-src/root-pl");
    try tmp.dir.createDirPath(rt.io, "proj/.zcode/catalog-src/dep-pl");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "proj/.zcode/marketplace.json",
        .data =
        \\[
        \\  {"name":"root-pl","kind":"plugin","description":"root","source":"catalog-src/root-pl","dependencies":["dep-pl"]},
        \\  {"name":"dep-pl","kind":"plugin","description":"dep","source":"catalog-src/dep-pl"}
        \\]
        ,
    });
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "proj/.zcode/catalog-src/root-pl/plugin.json",
        .data = "{\"name\":\"root-pl\",\"version\":\"1.0.0\",\"dependencies\":[\"dep-pl\"]}",
    });
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "proj/.zcode/catalog-src/dep-pl/plugin.json",
        .data = "{\"name\":\"dep-pl\",\"version\":\"1.0.0\"}",
    });

    const cwd = try @import("test_helpers.zig").tmpDirPath(allocator, &tmp, "proj");
    defer allocator.free(cwd);

    // Install the root: the dependency closure pulls dep-pl in, and the result
    // string reports the dependency count suffix.
    const installed = try install(allocator, cwd, .plugin, "root-pl");
    defer allocator.free(installed);
    try testing.expect(std.mem.indexOf(u8, installed, "(+ 1 dependency)") != null);

    // Both plugins are now installed under the user plugins root and load.
    {
        const list_pl = try plugins.list(allocator, cwd);
        defer plugins.freeList(allocator, list_pl);
        var saw_root = false;
        var saw_dep = false;
        for (list_pl) |p| {
            if (std.mem.eql(u8, p.name, "root-pl")) saw_root = true;
            if (std.mem.eql(u8, p.name, "dep-pl")) saw_dep = true;
        }
        try testing.expect(saw_root);
        try testing.expect(saw_dep);
    }

    // Uninstalling dep-pl warns that root-pl depends on it (plain hyphen, no
    // em/en dash per CLAUDE.md).
    const removed = try uninstallInCwd(allocator, cwd, .plugin, "dep-pl");
    defer allocator.free(removed);
    try testing.expect(std.mem.indexOf(u8, removed, "required by root-pl") != null);
    try testing.expect(std.mem.indexOf(u8, removed, " - warning:") != null);
}

// ── plugins-06: trust disclaimer copy + install emit-once ───────────────────

test "Task 17.6: trustWarning contains key phrases and no long dashes" {
    const allocator = testing.allocator;
    const text = try trustWarning(allocator, null);
    defer allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "trust") != null);
    try testing.expect(std.mem.indexOf(u8, text, "MCP") != null);
    try testing.expect(std.mem.indexOf(u8, text, "run code") != null or
        std.mem.indexOf(u8, text, "runs code") != null);
    // No em dash (U+2014) or en dash (U+2013) anywhere in the copy.
    try testing.expect(std.mem.indexOf(u8, text, "\u{2014}") == null);
    try testing.expect(std.mem.indexOf(u8, text, "\u{2013}") == null);
}

test "Task 17.6: trustWarning appends a custom policy message" {
    const allocator = testing.allocator;
    const text = try trustWarning(allocator, "ORG: only approved plugins");
    defer allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "ORG: only approved plugins") != null);
    // The base disclaimer is still present.
    try testing.expect(std.mem.indexOf(u8, text, "Plugin trust warning") != null);

    // An empty/blank custom message is ignored (no trailing blank line junk).
    const blank = try trustWarning(allocator, "   ");
    defer allocator.free(blank);
    try testing.expectEqualStrings(TRUST_WARNING_BODY, blank);
}

test "Task 17.6: install emits the trust warning to stderr exactly once" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Pin HOME (clear XDG_CONFIG_HOME) so the user plugins root resolves into
    // <tmp>/.zcode, same scaffolding as the dependency test above.
    const home = try @import("test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(home);
    const env = @import("env.zig");
    const prev_home = env.getOwned(allocator, "HOME") catch null;
    defer if (prev_home) |h| allocator.free(h);
    const prev_xdg = env.getOwned(allocator, "XDG_CONFIG_HOME") catch null;
    defer if (prev_xdg) |x| allocator.free(x);
    {
        const home_z = try allocator.dupeZ(u8, home);
        defer allocator.free(home_z);
        _ = setenv("HOME", home_z, 1);
        _ = unsetenv("XDG_CONFIG_HOME");
    }
    defer {
        if (prev_home) |h| {
            const z = allocator.dupeZ(u8, h) catch null;
            if (z) |zz| {
                _ = setenv("HOME", zz, 1);
                allocator.free(zz);
            }
        } else _ = unsetenv("HOME");
        if (prev_xdg) |x| {
            const z = allocator.dupeZ(u8, x) catch null;
            if (z) |zz| {
                _ = setenv("XDG_CONFIG_HOME", zz, 1);
                allocator.free(zz);
            }
        } else _ = unsetenv("XDG_CONFIG_HOME");
    }

    // Two installable plugins so we can install twice and prove the disclaimer
    // is emitted at most once per process.
    try tmp.dir.createDirPath(rt.io, "proj/.zcode/catalog-src/one");
    try tmp.dir.createDirPath(rt.io, "proj/.zcode/catalog-src/two");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "proj/.zcode/marketplace.json",
        .data =
        \\[
        \\  {"name":"one","kind":"plugin","description":"first","source":"catalog-src/one"},
        \\  {"name":"two","kind":"plugin","description":"second","source":"catalog-src/two"}
        \\]
        ,
    });
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "proj/.zcode/catalog-src/one/plugin.json",
        .data = "{\"name\":\"one\",\"version\":\"1.0.0\"}",
    });
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "proj/.zcode/catalog-src/two/plugin.json",
        .data = "{\"name\":\"two\",\"version\":\"1.0.0\"}",
    });

    const cwd = try @import("test_helpers.zig").tmpDirPath(allocator, &tmp, "proj");
    defer allocator.free(cwd);

    // Reset the process-level guard so this test is order-independent.
    trust_warning_emitted = false;
    trust_warning_emit_count = 0;

    const first = try install(allocator, cwd, .plugin, "one");
    allocator.free(first);
    try testing.expect(trust_warning_emitted);
    try testing.expectEqual(@as(usize, 1), trust_warning_emit_count);

    // A second install in the same process does not re-emit.
    const second = try install(allocator, cwd, .plugin, "two");
    allocator.free(second);
    try testing.expectEqual(@as(usize, 1), trust_warning_emit_count);
}

// ── plugins-07: managed-settings force-disable ──────────────────────────────

test "Task 17.7: install of a policy-blocked plugin returns PluginBlockedByPolicy" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try @import("test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(home);
    const env = @import("env.zig");
    const prev_home = env.getOwned(allocator, "HOME") catch null;
    defer if (prev_home) |h| allocator.free(h);
    const prev_xdg = env.getOwned(allocator, "XDG_CONFIG_HOME") catch null;
    defer if (prev_xdg) |x| allocator.free(x);
    const prev_managed = env.getOwned(allocator, "ZCODE_MANAGED_CONFIG") catch null;
    defer if (prev_managed) |m| allocator.free(m);
    {
        const home_z = try allocator.dupeZ(u8, home);
        defer allocator.free(home_z);
        _ = setenv("HOME", home_z, 1);
        _ = unsetenv("XDG_CONFIG_HOME");
    }
    defer {
        if (prev_home) |h| {
            const z = allocator.dupeZ(u8, h) catch null;
            if (z) |zz| {
                _ = setenv("HOME", zz, 1);
                allocator.free(zz);
            }
        } else _ = unsetenv("HOME");
        if (prev_xdg) |x| {
            const z = allocator.dupeZ(u8, x) catch null;
            if (z) |zz| {
                _ = setenv("XDG_CONFIG_HOME", zz, 1);
                allocator.free(zz);
            }
        } else _ = unsetenv("XDG_CONFIG_HOME");
        if (prev_managed) |m| {
            const z = allocator.dupeZ(u8, m) catch null;
            if (z) |zz| {
                _ = setenv("ZCODE_MANAGED_CONFIG", zz, 1);
                allocator.free(zz);
            }
        } else _ = unsetenv("ZCODE_MANAGED_CONFIG");
    }

    // Managed policy file in <home> blocks evil@local. The managed-config path
    // points into <home> so policy_plugins.json sits beside it.
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "policy_plugins.json",
        .data = "{\"enabledPlugins\":{\"evil@local\":false}}",
    });
    {
        const managed_z = try std.fmt.allocPrintSentinel(allocator, "{s}/managed.toml", .{home}, 0);
        defer allocator.free(managed_z);
        _ = setenv("ZCODE_MANAGED_CONFIG", managed_z.ptr, 1);
    }

    // A catalog offering `evil`. The policy gate must refuse before any file is
    // copied. zcode catalogs are `@local`, so the policy id is `evil@local`.
    try tmp.dir.createDirPath(rt.io, "proj/.zcode/catalog-src/evil");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "proj/.zcode/marketplace.json",
        .data =
        \\[
        \\  {"name":"evil","kind":"plugin","description":"blocked","source":"catalog-src/evil"}
        \\]
        ,
    });
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "proj/.zcode/catalog-src/evil/plugin.json",
        .data = "{\"name\":\"evil\",\"version\":\"1.0.0\"}",
    });

    const cwd = try @import("test_helpers.zig").tmpDirPath(allocator, &tmp, "proj");
    defer allocator.free(cwd);

    try testing.expectError(error.PluginBlockedByPolicy, install(allocator, cwd, .plugin, "evil"));
}

test "Task 17.7: plugins.list shows a policy-blocked plugin disabled even when user enables it" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try @import("test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(home);
    const env = @import("env.zig");
    const prev_home = env.getOwned(allocator, "HOME") catch null;
    defer if (prev_home) |h| allocator.free(h);
    const prev_xdg = env.getOwned(allocator, "XDG_CONFIG_HOME") catch null;
    defer if (prev_xdg) |x| allocator.free(x);
    const prev_managed = env.getOwned(allocator, "ZCODE_MANAGED_CONFIG") catch null;
    defer if (prev_managed) |m| allocator.free(m);
    {
        const home_z = try allocator.dupeZ(u8, home);
        defer allocator.free(home_z);
        _ = setenv("HOME", home_z, 1);
        _ = unsetenv("XDG_CONFIG_HOME");
    }
    defer {
        if (prev_home) |h| {
            const z = allocator.dupeZ(u8, h) catch null;
            if (z) |zz| {
                _ = setenv("HOME", zz, 1);
                allocator.free(zz);
            }
        } else _ = unsetenv("HOME");
        if (prev_xdg) |x| {
            const z = allocator.dupeZ(u8, x) catch null;
            if (z) |zz| {
                _ = setenv("XDG_CONFIG_HOME", zz, 1);
                allocator.free(zz);
            }
        } else _ = unsetenv("XDG_CONFIG_HOME");
        if (prev_managed) |m| {
            const z = allocator.dupeZ(u8, m) catch null;
            if (z) |zz| {
                _ = setenv("ZCODE_MANAGED_CONFIG", zz, 1);
                allocator.free(zz);
            }
        } else _ = unsetenv("ZCODE_MANAGED_CONFIG");
    }

    // A user-scope plugin `evil` installed under <home>/.zcode/plugins/evil.
    try tmp.dir.createDirPath(rt.io, ".zcode/plugins/evil");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/plugins/evil/plugin.json",
        .data = "{\"name\":\"evil\",\"version\":\"1.0.0\",\"entrypoint\":\"run.sh\"}",
    });

    // The user explicitly enables it in their user-scope plugin_settings.json.
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/plugin_settings.json",
        .data = "{\"enabledPlugins\":{\"evil@local\":true}}",
    });

    // But org policy force-disables it.
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "policy_plugins.json",
        .data = "{\"enabledPlugins\":{\"evil@local\":false}}",
    });
    {
        const managed_z = try std.fmt.allocPrintSentinel(allocator, "{s}/managed.toml", .{home}, 0);
        defer allocator.free(managed_z);
        _ = setenv("ZCODE_MANAGED_CONFIG", managed_z.ptr, 1);
    }

    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try @import("test_helpers.zig").tmpDirPath(allocator, &tmp, "proj");
    defer allocator.free(cwd);

    const list_pl = try plugins.list(allocator, cwd);
    defer plugins.freeList(allocator, list_pl);

    var saw = false;
    for (list_pl) |p| {
        if (std.mem.eql(u8, p.name, "evil")) {
            saw = true;
            // Policy beats the user's `true` -> disabled.
            try testing.expect(!p.enabled);
        }
    }
    try testing.expect(saw);
}

// ── plugins-09: delisting detection + auto-uninstall ────────────────────────

/// Pin HOME (clear XDG_CONFIG_HOME) so userPluginsRoot, the source cache, and
/// the flagged store all resolve into <home>/.zcode. Returns a restore closure.
const DelistHomeRestore = struct {
    prev_home: ?[]u8,
    prev_xdg: ?[]u8,

    fn deinit(self: DelistHomeRestore, allocator: std.mem.Allocator) void {
        if (self.prev_home) |h| {
            const z = allocator.dupeZ(u8, h) catch null;
            if (z) |zz| {
                _ = setenv("HOME", zz, 1);
                allocator.free(zz);
            }
            allocator.free(h);
        } else _ = unsetenv("HOME");
        if (self.prev_xdg) |x| {
            const z = allocator.dupeZ(u8, x) catch null;
            if (z) |zz| {
                _ = setenv("XDG_CONFIG_HOME", zz, 1);
                allocator.free(zz);
            }
            allocator.free(x);
        } else _ = unsetenv("XDG_CONFIG_HOME");
    }
};

fn pinDelistHome(allocator: std.mem.Allocator, home: []const u8) !DelistHomeRestore {
    const env = @import("env.zig");
    const prev_home = env.getOwned(allocator, "HOME") catch null;
    const prev_xdg = env.getOwned(allocator, "XDG_CONFIG_HOME") catch null;
    const home_z = try allocator.dupeZ(u8, home);
    defer allocator.free(home_z);
    _ = setenv("HOME", home_z, 1);
    _ = unsetenv("XDG_CONFIG_HOME");
    return .{ .prev_home = prev_home, .prev_xdg = prev_xdg };
}

/// Seed the source cache file at cachePathForSource(name) with a catalog body.
/// Mirrors what refreshOneSource writes, but bypasses the policy gate / network
/// so the detection logic can be exercised in isolation.
fn seedSourceCache(allocator: std.mem.Allocator, name: []const u8, body: []const u8) !void {
    const cache_path = try cachePathForSource(allocator, name);
    defer allocator.free(cache_path);
    try paths.ensureDir(std.fs.path.dirname(cache_path) orelse return error.InvalidPath);
    try std.Io.Dir.cwd().writeFile(rt.io, .{ .sub_path = cache_path, .data = body });
}

test "Task 17.9: delisted plugin under a force_remove_deleted source is uninstalled and flagged" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try @import("test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(home);
    const restore = try pinDelistHome(allocator, home);
    defer restore.deinit(allocator);

    // An installed user-scope plugin under <home>/.zcode/plugins/demo.
    try tmp.dir.createDirPath(rt.io, ".zcode/plugins/demo");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/plugins/demo/plugin.json",
        .data = "{\"name\":\"demo\",\"version\":\"1.0.0\",\"entrypoint\":\"run.sh\"}",
    });

    // The refreshed catalog marks demo deleted. The catalog's `source` field is
    // irrelevant to detection (we only read name + deleted), but must be present.
    try seedSourceCache(allocator, "src",
        \\[
        \\  {"name":"demo","kind":"plugin","description":"x","source":"/tmp/demo","deleted":true}
        \\]
    );

    // The source URL only feeds the catalog resolver's base dir; any valid
    // file:// path works. force_remove_deleted=true grants removal permission.
    const source = RegistrySource{
        .name = try allocator.dupe(u8, "src"),
        .url = try allocator.dupe(u8, "file:///tmp/catalog.json"),
        .sha256 = null,
        .force_remove_deleted = true,
    };
    defer {
        var s = source;
        s.deinit(allocator);
    }

    // Resolve the plugin dir BEFORE removal (realPathFile would fail once it is
    // gone). The parent stays put, so we resolve the parent and join the leaf.
    const plugins_root = try @import("test_helpers.zig").tmpDirPath(allocator, &tmp, ".zcode/plugins");
    defer allocator.free(plugins_root);
    const plugin_dir = try std.fs.path.join(allocator, &.{ plugins_root, "demo" });
    defer allocator.free(plugin_dir);

    const removed = try detectAndUninstallDelisted(allocator, &.{source});
    try testing.expectEqual(@as(usize, 1), removed);

    // The plugin directory is gone.
    try testing.expect(!fileExists(plugin_dir));

    // And it is recorded in the flagged store under its name@local id.
    try testing.expect(try plugin_flagging.isFlagged(allocator, "demo@local"));
}

test "Task 17.9: without force_remove_deleted the delisted plugin is left in place" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try @import("test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(home);
    const restore = try pinDelistHome(allocator, home);
    defer restore.deinit(allocator);

    try tmp.dir.createDirPath(rt.io, ".zcode/plugins/demo");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/plugins/demo/plugin.json",
        .data = "{\"name\":\"demo\",\"version\":\"1.0.0\",\"entrypoint\":\"run.sh\"}",
    });

    try seedSourceCache(allocator, "src",
        \\[
        \\  {"name":"demo","kind":"plugin","description":"x","source":"/tmp/demo","deleted":true}
        \\]
    );

    // Same catalog, but the source did NOT opt into force_remove_deleted.
    const source = RegistrySource{
        .name = try allocator.dupe(u8, "src"),
        .url = try allocator.dupe(u8, "file:///tmp/catalog.json"),
        .sha256 = null,
        .force_remove_deleted = false,
    };
    defer {
        var s = source;
        s.deinit(allocator);
    }

    const removed = try detectAndUninstallDelisted(allocator, &.{source});
    try testing.expectEqual(@as(usize, 0), removed);

    // The plugin directory is untouched and nothing was flagged.
    const plugin_dir = try @import("test_helpers.zig").tmpDirPath(allocator, &tmp, ".zcode/plugins/demo");
    defer allocator.free(plugin_dir);
    try testing.expect(fileExists(plugin_dir));
    try testing.expect(!(try plugin_flagging.isFlagged(allocator, "demo@local")));
}
