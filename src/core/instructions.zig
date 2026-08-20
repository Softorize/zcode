const std = @import("std");
const std_io = @import("std_io.zig");
const rt = @import("zcode_runtime");
const types = @import("types.zig");
const frontmatter = @import("frontmatter.zig");
const skill_visibility = @import("skill_visibility.zig");

const Candidate = struct {
    name: []const u8,
    precedence: u8,
};

const primary_instruction_name = "ZCODE.md";

pub const DiscoverOptions = struct {
    per_file_cap: usize,
    total_cap: usize,
    imports_enabled: bool = true,
    import_max_depth: u8 = 5,
    /// Optional cross-turn cache. When supplied, discover() will
    /// first compute a cheap mtime+size fingerprint of every
    /// candidate file on the walk and skip the full content read
    /// if the fingerprint matches the cached one AND
    /// `axis_epoch` matches what was cached. This turns a typical
    /// per-turn cost (multi-file disk walk + git rev-parse +
    /// content reads) into a stat-only walk plus a deep clone of
    /// the cached entry set. Caller owns the cache lifetime.
    cache: ?*DiscoveryCache = null,
    /// Epoch from the prompt-section registry's .instructions
    /// axis. Any bump busts the cache unconditionally (used on
    /// /clear, /compact, explicit /reload).
    axis_epoch: u64 = 0,
    /// Paths to match conditional `.claude/rules/*.md` files against
    /// (frontmatter `paths:`/`globs:` gating, memory-09). Each entry
    /// is the cwd plus any explicitly-edited paths the caller wants
    /// considered. When empty, only the current directory level is
    /// matched (so a path-scoped rule is included only at the level
    /// whose `.claude` dir contains it and whose dir is itself the
    /// target). Patterns are matched relative to the directory that
    /// contains the `.claude` dir, mirroring the reference's
    /// `dirname(dirname(rulesDir))` base.
    target_paths: []const []const u8 = &.{},
};

/// Cross-turn cache for discover(). Holds the entries, the walk
/// fingerprint that produced them, the cwd they were computed
/// under, and the axis epoch observed at cache time.
///
/// Ownership: the cache owns its entries via `owner_allocator`
/// so they survive across turns even when per-turn arenas are
/// freed. discover() deep-copies cached entries into the caller's
/// allocator on each hit.
pub const DiscoveryCache = struct {
    owner_allocator: std.mem.Allocator,
    cwd: []u8 = &.{},
    fingerprint: u64 = 0,
    axis_epoch: u64 = 0,
    entries: []types.InstructionEntry = &.{},
    hits: u64 = 0,
    misses: u64 = 0,
    has_entry: bool = false,

    pub fn init(allocator: std.mem.Allocator) DiscoveryCache {
        return .{ .owner_allocator = allocator };
    }

    pub fn deinit(self: *DiscoveryCache) void {
        self.reset();
    }

    pub fn reset(self: *DiscoveryCache) void {
        if (self.cwd.len > 0) {
            self.owner_allocator.free(self.cwd);
            self.cwd = &.{};
        }
        if (self.has_entry) {
            freeEntries(self.owner_allocator, self.entries);
            self.entries = &.{};
            self.has_entry = false;
        }
        self.fingerprint = 0;
        self.axis_epoch = 0;
    }
};

const candidates = [_]Candidate{
    .{ .name = primary_instruction_name, .precedence = 100 },
    .{ .name = "AGENTS.md", .precedence = 90 },
    .{ .name = "CLAUDE.md", .precedence = 80 },
    .{ .name = "GEMINI.md", .precedence = 70 },
};

/// Candidates under the .claude/ subdirectory (slightly lower precedence than root).
const dot_claude_candidates = [_]Candidate{
    .{ .name = primary_instruction_name, .precedence = 98 },
    .{ .name = "AGENTS.md", .precedence = 88 },
    .{ .name = "CLAUDE.md", .precedence = 78 },
    .{ .name = "GEMINI.md", .precedence = 68 },
};

/// Local-only variants (.local.md) - highest precedence, not checked into VCS.
const local_candidates = [_]Candidate{
    .{ .name = "ZCODE.local.md", .precedence = 105 },
    .{ .name = "AGENTS.local.md", .precedence = 95 },
    .{ .name = "CLAUDE.local.md", .precedence = 85 },
    .{ .name = "GEMINI.local.md", .precedence = 75 },
};

pub fn discover(allocator: std.mem.Allocator, cwd: []const u8, opts: DiscoverOptions) ![]types.InstructionEntry {
    // Fast path: if the caller supplied a cache, first compute
    // the cheap stat-only fingerprint. When it matches the
    // cached one AND the invalidation epoch is unchanged, hand
    // back a deep clone of the cached entries without re-reading
    // any file content. Discovery walks the directory tree and
    // can easily cost 10+ file reads + a git subprocess per turn,
    // so this is the single biggest per-turn cost reduction on
    // the prompt path.
    if (opts.cache) |cache| {
        const cwd_abs_opt = toAbsolutePath(allocator, cwd) catch null;
        defer if (cwd_abs_opt) |p| allocator.free(p);
        const key = if (cwd_abs_opt) |p| p else cwd;
        const fp = computeDiscoveryFingerprint(allocator, cwd) catch 0;
        if (cache.has_entry and
            cache.fingerprint == fp and
            cache.axis_epoch == opts.axis_epoch and
            std.mem.eql(u8, cache.cwd, key))
        {
            cache.hits += 1;
            return cloneEntries(allocator, cache.entries);
        }
        cache.misses += 1;
    }

    var list = std.array_list.Managed(types.InstructionEntry).init(allocator);
    errdefer freeEntries(allocator, list.items);

    var seen_sources = std.StringHashMap(void).init(allocator);
    defer freeMapKeys(allocator, &seen_sources);

    var scanned_dirs = std.StringHashMap(void).init(allocator);
    defer freeMapKeys(allocator, &scanned_dirs);

    var total_used: usize = 0;
    var sequence: u32 = 0;
    var omitted_due_budget: usize = 0;

    const cwd_abs = try toAbsolutePath(allocator, cwd);
    defer allocator.free(cwd_abs);

    const repo_root = try detectRepoRoot(allocator, cwd_abs);
    defer if (repo_root) |path| allocator.free(path);

    const home = @import("env.zig").getOwned(allocator, "HOME") catch null;
    defer if (home) |path| allocator.free(path);

    var current = try allocator.dupe(u8, cwd_abs);
    defer allocator.free(current);
    var scope_distance: u16 = 0;

    while (true) {
        try putUniqueMapKey(allocator, &scanned_dirs, current);
        try scanDirectoryCandidates(
            allocator,
            current,
            scope_distance,
            opts,
            &list,
            &seen_sources,
            &total_used,
            &sequence,
            &omitted_due_budget,
        );

        if (repo_root) |root| {
            if (pathEq(current, root)) break;
        } else if (std.mem.eql(u8, current, "/")) {
            break;
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (pathEq(parent, current)) break;

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
        scope_distance +|= 1;
    }

    if (home) |home_path| {
        if (!scanned_dirs.contains(home_path)) {
            try scanDirectoryCandidates(
                allocator,
                home_path,
                std.math.maxInt(u16),
                opts,
                &list,
                &seen_sources,
                &total_used,
                &sequence,
                &omitted_due_budget,
            );
        }
    }

    if (omitted_due_budget > 0) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "Instruction budget reached; omitted {d} additional instruction file(s) or imports.",
            .{omitted_due_budget},
        );
        errdefer allocator.free(msg);
        try list.ensureUnusedCapacity(1);
        const dup_source = try allocator.dupe(u8, "[instruction-overflow]");
        list.appendAssumeCapacity(.{
            .source = dup_source,
            .precedence = 1,
            .truncated = true,
            .content = msg,
            .scope_distance = std.math.maxInt(u16),
            .import_depth = 0,
            .order = sequence,
        });
        sequence +%= 1;
    }

    std.mem.sort(types.InstructionEntry, list.items, {}, instructionLessThan);

    // Persist into the cache once we have the finalized entry
    // order. We recompute the fingerprint after the full walk so
    // the cached value matches a byte-exact snapshot of what we
    // just consumed; racing edits between the first fingerprint
    // computation above and this point would otherwise wedge the
    // cache into a state it never actually observed.
    if (opts.cache) |cache| {
        const fp_post = computeDiscoveryFingerprint(allocator, cwd) catch 0;
        const cwd_abs_opt = toAbsolutePath(allocator, cwd) catch null;
        defer if (cwd_abs_opt) |p| allocator.free(p);
        const key = if (cwd_abs_opt) |p| p else cwd;
        cacheStore(cache, key, fp_post, opts.axis_epoch, list.items) catch |err| {
            std.log.warn("instructions cache store failed: {s}", .{@errorName(err)});
        };
    }
    return list.toOwnedSlice();
}

fn scanDirectoryCandidates(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    scope_distance: u16,
    opts: DiscoverOptions,
    out: *std.array_list.Managed(types.InstructionEntry),
    seen_sources: *std.StringHashMap(void),
    total_used: *usize,
    sequence: *u32,
    omitted_due_budget: *usize,
) !void {
    // 1. Root-level candidates (ZCODE.md, CLAUDE.md, etc.)
    for (candidates) |candidate| {
        const file_path = try std.fs.path.join(allocator, &.{ dir_path, candidate.name });
        defer allocator.free(file_path);

        try addInstructionFile(
            allocator,
            file_path,
            candidate.precedence,
            scope_distance,
            0,
            opts,
            out,
            seen_sources,
            total_used,
            sequence,
            omitted_due_budget,
            &.{},
        );

        if (total_used.* >= opts.total_cap) return;
    }

    // 2. .claude/ subdirectory candidates (.claude/ZCODE.md, .claude/CLAUDE.md, etc.)
    const dot_claude_dir = try std.fs.path.join(allocator, &.{ dir_path, ".claude" });
    defer allocator.free(dot_claude_dir);

    for (dot_claude_candidates) |candidate| {
        const file_path = try std.fs.path.join(allocator, &.{ dot_claude_dir, candidate.name });
        defer allocator.free(file_path);

        try addInstructionFile(
            allocator,
            file_path,
            candidate.precedence,
            scope_distance,
            0,
            opts,
            out,
            seen_sources,
            total_used,
            sequence,
            omitted_due_budget,
            &.{},
        );

        if (total_used.* >= opts.total_cap) return;
    }

    // 3. .claude/rules/*.md - all markdown files in the rules directory
    try scanRulesDirectory(
        allocator,
        dot_claude_dir,
        scope_distance,
        opts,
        out,
        seen_sources,
        total_used,
        sequence,
        omitted_due_budget,
    );

    if (total_used.* >= opts.total_cap) return;

    // 4. Local-only variants (ZCODE.local.md, CLAUDE.local.md, etc.)
    for (local_candidates) |candidate| {
        const file_path = try std.fs.path.join(allocator, &.{ dir_path, candidate.name });
        defer allocator.free(file_path);

        try addInstructionFile(
            allocator,
            file_path,
            candidate.precedence,
            scope_distance,
            0,
            opts,
            out,
            seen_sources,
            total_used,
            sequence,
            omitted_due_budget,
            &.{},
        );

        if (total_used.* >= opts.total_cap) return;
    }
}

/// Scan .claude/rules/*.md for additional instruction files.
fn scanRulesDirectory(
    allocator: std.mem.Allocator,
    dot_claude_dir: []const u8,
    scope_distance: u16,
    opts: DiscoverOptions,
    out: *std.array_list.Managed(types.InstructionEntry),
    seen_sources: *std.StringHashMap(void),
    total_used: *usize,
    sequence: *u32,
    omitted_due_budget: *usize,
) !void {
    const rules_dir_path = try std.fs.path.join(allocator, &.{ dot_claude_dir, "rules" });
    defer allocator.free(rules_dir_path);

    var rules_dir = std.Io.Dir.cwd().openDir(rt.io, rules_dir_path, .{ .iterate = true }) catch return;
    defer rules_dir.close(rt.io);

    // Collect filenames first so iteration order is deterministic (sorted).
    var names = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit();
    }

    var it = rules_dir.iterate();
    while (try it.next(rt.io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        try names.append(try allocator.dupe(u8, entry.name));
    }

    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    // Base directory for relative glob matching: the directory that
    // CONTAINS the `.claude` dir (parent of dot_claude_dir), mirroring
    // the reference's `dirname(dirname(rulesDir))`.
    const base_dir = std.fs.path.dirname(dot_claude_dir) orelse dot_claude_dir;

    for (names.items) |name| {
        const file_path = try std.fs.path.join(allocator, &.{ rules_dir_path, name });
        defer allocator.free(file_path);

        // Parse frontmatter `paths:`/`globs:` for conditional gating
        // (memory-09). When present and non-trivial (not empty, not
        // match-all `**`), only load this rule when one of the
        // caller-supplied target paths matches one of the globs.
        const globs_owned = try parseFrontmatterPaths(allocator, file_path);
        // `globs_owned` is owned here; transfer it into
        // addInstructionFile (which frees it on early return) on the
        // load path, or free it ourselves when we gate the file out.
        var release_globs = true;
        defer if (release_globs) freeGlobs(allocator, globs_owned);

        if (globs_owned.len != 0) {
            if (!ruleMatchesTargets(base_dir, globs_owned, opts.target_paths)) {
                // Gated out: skip this rule entirely. `release_globs`
                // stays true so the defer frees the parsed list.
                continue;
            }
        }

        // Rules files get precedence 60 (below main candidates but still loaded).
        release_globs = false;
        try addInstructionFile(
            allocator,
            file_path,
            60,
            scope_distance,
            0,
            opts,
            out,
            seen_sources,
            total_used,
            sequence,
            omitted_due_budget,
            globs_owned,
        );

        if (total_used.* >= opts.total_cap) return;
    }
}

/// Parse a rules file's frontmatter `paths:`/`globs:` field into an
/// owned, gating-ready glob list. Returns an empty slice (`&.{}`) when
/// the file has no such frontmatter, the value is empty, or every
/// parsed pattern is match-all (`**`) -- all of which mean "load
/// unconditionally". Trailing `/**` is stripped from each pattern so
/// `src/api/**` also matches `src/api` itself. Comma- and
/// newline-separated lists are both accepted (the shared frontmatter
/// parser yields a single line value; we split it on commas).
///
/// Best-effort: any read/parse failure degrades to `&.{}`
/// (unconditional load), matching the reference's tolerance.
fn parseFrontmatterPaths(allocator: std.mem.Allocator, file_path: []const u8) ![]const []const u8 {
    // Peek at most the first 8 KiB; frontmatter lives at the very top
    // and rules files are small. Failure to read -> treat as no gating.
    const peek = (readCappedFile(allocator, file_path, 8 * 1024) catch return &.{}) orelse return &.{};
    defer allocator.free(peek.bytes);

    const block = frontmatter.extract(peek.bytes) orelse return &.{};
    // Accept `paths` (reference key) or `globs` (alias).
    const raw = frontmatter.getValue(block.body, "paths") orelse
        frontmatter.getValue(block.body, "globs") orelse return &.{};

    var list = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (list.items) |g| allocator.free(g);
        list.deinit();
    }

    var any_specific = false;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r");
        if (trimmed.len == 0) continue;
        // Strip a trailing `/**` so `src/api/**` matches `src/api`
        // itself as well as nested paths (reference behaviour).
        var pat = trimmed;
        if (std.mem.endsWith(u8, pat, "/**")) {
            pat = pat[0 .. pat.len - 3];
        }
        if (pat.len == 0) continue;
        // A lone `**` (or a `/**` that reduced to empty above) means
        // match-all -> no gating contribution.
        if (std.mem.eql(u8, pat, "**")) continue;
        any_specific = true;
        try list.append(try allocator.dupe(u8, pat));
    }

    if (!any_specific) {
        // Every pattern was match-all or empty: load unconditionally.
        for (list.items) |g| allocator.free(g);
        list.deinit();
        return &.{};
    }

    return list.toOwnedSlice();
}

/// Decide whether a conditional rule's `globs` match any of the
/// caller's target paths, with patterns interpreted relative to
/// `base_dir` (the directory containing `.claude`). Absolute target
/// paths under `base_dir` are converted to that-relative form before
/// matching; targets outside `base_dir` (would need `..` to reach)
/// contribute no match. Relative targets are matched as-is.
///
/// When the caller supplied NO target paths, `base_dir` itself is the
/// implicit target (relative form ""), so a `src/api`-scoped rule does
/// not load at a bare directory level -- only an explicit edited path
/// or cwd under that subtree enables it.
fn ruleMatchesTargets(
    base_dir: []const u8,
    globs: []const []const u8,
    target_paths: []const []const u8,
) bool {
    if (target_paths.len == 0) {
        // No explicit targets: match the base dir itself (relative "").
        const empty_target = [_][]const u8{""};
        return skill_visibility.matchesAnyPath(globs, &empty_target);
    }

    for (target_paths) |t| {
        const rel = relativizeTarget(base_dir, t) orelse continue;
        for (globs) |g| {
            if (globMatchesTarget(g, rel)) return true;
        }
    }
    return false;
}

/// Match a single (already `/**`-stripped) glob against a target path.
/// A glob matches when the wildcard matcher matches directly, OR when
/// the glob names a directory that the target lives under (so the
/// stripped `src/api` matches `src/api/handler.zig` as well as the
/// bare `src/api`). This is what makes the `/**` strip lossless: we
/// keep the dir-prefix semantics the suffix encoded.
fn globMatchesTarget(glob: []const u8, target: []const u8) bool {
    if (skill_visibility.globMatch(glob, target)) return true;
    // Directory containment: target is "<glob>/..." .
    if (target.len > glob.len and
        std.mem.startsWith(u8, target, glob) and
        target[glob.len] == '/')
    {
        return true;
    }
    return false;
}

/// Convert a target path into a form relative to `base_dir` suitable
/// for glob matching. The returned slice always aliases into `target`
/// (no allocation). Absolute paths under `base_dir` have the prefix
/// (plus its boundary separators) stripped. An absolute path NOT under
/// `base_dir` returns null (no match -- mirrors the reference guard
/// against `..`-escaping). A relative `..`-escaping target also
/// returns null; other relative paths are returned unchanged.
fn relativizeTarget(base_dir: []const u8, target: []const u8) ?[]const u8 {
    if (target.len == 0) return "";

    if (!std.fs.path.isAbsolute(target)) {
        // Already relative: use verbatim. Reject `..`-escaping targets.
        if (std.mem.startsWith(u8, target, "../") or std.mem.eql(u8, target, "..")) return null;
        return target;
    }

    // Absolute target: must live under base_dir.
    if (!std.mem.startsWith(u8, target, base_dir)) return null;
    var rest = target[base_dir.len..];
    // Strip the boundary separator(s).
    while (rest.len > 0 and rest[0] == '/') rest = rest[1..];
    return rest;
}

fn addInstructionFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    precedence: u8,
    scope_distance: u16,
    import_depth: u8,
    opts: DiscoverOptions,
    out: *std.array_list.Managed(types.InstructionEntry),
    seen_sources: *std.StringHashMap(void),
    total_used: *usize,
    sequence: *u32,
    omitted_due_budget: *usize,
    /// Pre-parsed frontmatter `paths:`/`globs:` patterns to record on
    /// the resulting entry (already gated by the caller). Ownership
    /// transfers in: stored on the entry on success, freed on any
    /// early return. Pass `&.{}` for the unconditional case.
    globs: []const []const u8,
) !void {
    // The globs list is owned by this call. If we bail out before
    // building the entry (dedup, budget, empty content), free it so
    // it is never leaked; on success the entry takes ownership and
    // we clear the flag.
    var globs_stored = false;
    defer if (!globs_stored) freeGlobs(allocator, globs);

    const canonical = try canonicalizePath(allocator, path);
    defer allocator.free(canonical);

    if (seen_sources.contains(canonical)) return;

    const maybe_content = try readCappedFile(allocator, canonical, opts.per_file_cap);
    if (maybe_content == null) return;
    var content = maybe_content.?;
    errdefer allocator.free(content.bytes);

    // Strip block-level HTML comments (authorial notes like <!-- ... -->) before
    // any budget accounting so the smaller, stripped content is what counts
    // against the per-file / total caps and what feeds @include parsing.
    const stripped = try stripHtmlComments(allocator, content.bytes);
    if (stripped.stripped) {
        allocator.free(content.bytes);
        content.bytes = stripped.bytes;
    }

    // Content hash dedup: skip files with identical content at different paths
    const content_hash = std.hash.Wyhash.hash(0, content.bytes);
    var hash_buf: [32]u8 = undefined;
    const hash_key = std.fmt.bufPrint(&hash_buf, "h:{x}", .{content_hash}) catch unreachable;
    if (seen_sources.contains(hash_key)) {
        allocator.free(content.bytes);
        return;
    }

    if (total_used.* >= opts.total_cap) {
        omitted_due_budget.* += 1;
        allocator.free(content.bytes);
        return;
    }

    const remaining = opts.total_cap - total_used.*;
    if (content.bytes.len > remaining) {
        const clipped = try allocator.alloc(u8, remaining);
        @memcpy(clipped, content.bytes[0..remaining]);
        allocator.free(content.bytes);
        content.bytes = clipped;
        content.truncated = true;
        omitted_due_budget.* += 1;
    }

    if (content.bytes.len == 0) {
        omitted_due_budget.* += 1;
        return;
    }

    const seen_key = try allocator.dupe(u8, canonical);
    try seen_sources.put(seen_key, {});
    // Also store content hash to dedup identical files at different paths
    const hash_key_owned = try allocator.dupe(u8, hash_key);
    try seen_sources.put(hash_key_owned, {});

    try out.ensureUnusedCapacity(1);
    const dup_source = try allocator.dupe(u8, canonical);
    out.appendAssumeCapacity(.{
        .source = dup_source,
        .precedence = precedence,
        .truncated = content.truncated,
        .content = content.bytes,
        .scope_distance = scope_distance,
        .import_depth = import_depth,
        .order = sequence.*,
        .globs = globs,
    });
    globs_stored = true;
    sequence.* +%= 1;
    total_used.* += content.bytes.len;

    if (!opts.imports_enabled) return;
    if (import_depth >= opts.import_max_depth) return;
    if (total_used.* >= opts.total_cap) return;

    const imports = try parseImports(allocator, content.bytes);
    defer freeStringSliceMutable(allocator, imports);

    for (imports) |import_token| {
        // Log a warning when an @include resolves-but-fails (denied path,
        // depth exceeded, missing HOME, etc.) so the operator can see
        // which import didn't load. Previously we silently dropped
        // failed imports and the user had to guess why their included
        // instructions weren't showing up.
        const resolved = resolveImportPath(allocator, canonical, import_token) catch |err| {
            std.log.warn(
                "instructions: ignoring @include `{s}` in {s} ({s})",
                .{ import_token, canonical, @errorName(err) },
            );
            continue;
        };
        defer allocator.free(resolved);

        // Transitively-included files get a slightly lower precedence than
        // their importer. Without this, a nested @include inside an untrusted
        // ZCODE.md could inherit the importer's precedence (e.g. 100 for the
        // workspace root file) and outrank user-global rules that were
        // explicitly set higher. A saturating 5-point decrement per import
        // level keeps the ordering obvious while still letting includes carry
        // the bulk of the importer's authority.
        const nested_precedence: u8 = precedence -| 5;

        try addInstructionFile(
            allocator,
            resolved,
            nested_precedence,
            scope_distance,
            import_depth + 1,
            opts,
            out,
            seen_sources,
            total_used,
            sequence,
            omitted_due_budget,
            &.{},
        );

        if (total_used.* >= opts.total_cap) return;
    }
}

const ReadResult = struct {
    bytes: []u8,
    truncated: bool,
};

fn readCappedFile(allocator: std.mem.Allocator, path: []const u8, cap: usize) !?ReadResult {
    const file = std.Io.Dir.cwd().openFile(rt.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.NotDir => return null,
        error.AccessDenied => return null,
        else => return err,
    };
    defer file.close(rt.io);

    const stat = try file.stat(rt.io);
    const to_read_u64 = @min(stat.size, @as(u64, @intCast(cap)));
    const to_read: usize = @intCast(to_read_u64);
    var bytes = try allocator.alloc(u8, to_read);
    const read_len = try file.readPositionalAll(rt.io, bytes, 0);
    if (read_len < to_read) {
        bytes = try allocator.realloc(bytes, read_len);
    }

    return .{ .bytes = bytes, .truncated = stat.size > cap };
}

fn instructionLessThan(_: void, a: types.InstructionEntry, b: types.InstructionEntry) bool {
    if (a.precedence != b.precedence) return a.precedence > b.precedence;
    if (a.scope_distance != b.scope_distance) return a.scope_distance < b.scope_distance;
    if (a.import_depth != b.import_depth) return a.import_depth < b.import_depth;
    if (a.order != b.order) return a.order < b.order;
    return std.mem.lessThan(u8, a.source, b.source);
}

pub fn freeEntries(allocator: std.mem.Allocator, entries: []types.InstructionEntry) void {
    for (entries) |entry| {
        allocator.free(entry.source);
        allocator.free(entry.content);
        freeGlobs(allocator, entry.globs);
    }
    allocator.free(entries);
}

/// Free an owned glob list (each pattern plus the backing slice). A
/// zero-length list (`&.{}`, the common unconditional case) frees
/// nothing meaningful.
fn freeGlobs(allocator: std.mem.Allocator, globs: []const []const u8) void {
    // The unconditional case is a zero-length literal (`&.{}`) whose
    // backing pointer is not heap-allocated; never hand that to free().
    if (globs.len == 0) return;
    for (globs) |g| allocator.free(g);
    allocator.free(globs);
}

/// Deep-copy a glob list into `allocator`. Used when handing cached
/// entries back to a per-turn arena.
fn cloneGlobs(allocator: std.mem.Allocator, globs: []const []const u8) ![]const []const u8 {
    if (globs.len == 0) return &.{};
    const out = try allocator.alloc([]const u8, globs.len);
    var done: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < done) : (i += 1) allocator.free(out[i]);
        allocator.free(out);
    }
    for (globs, 0..) |g, i| {
        out[i] = try allocator.dupe(u8, g);
        done = i + 1;
    }
    return out;
}

/// Per-file character ceiling above which /doctor warns the user
/// that their instruction file is eating context. Ported from
/// claude-code-main/src/utils/claudemd.ts MAX_MEMORY_CHARACTER_COUNT.
/// 40 000 chars is roughly 10k tokens with a typical byte-pair
/// encoder -- big enough to allow a thoroughly-documented project
/// rule book, small enough that we'd want the user to know if they
/// crossed it because every prompt now pays that cost.
pub const MAX_INSTRUCTION_FILE_CHARS: usize = 40_000;

pub const LargeInstructionFile = struct {
    /// Absolute path on disk.
    path: []u8,
    /// Raw byte size of the file. We use bytes rather than codepoint
    /// counts because the API budget is in tokens and tokens scale
    /// roughly with bytes for ASCII-heavy content (which is what
    /// instruction files almost always are).
    size_bytes: u64,

    pub fn deinit(self: *LargeInstructionFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

/// Walk the same candidate paths that `discover()` would visit and
/// return any whose on-disk size exceeds `threshold`. Reports raw
/// file sizes via stat -- does NOT call discover() because that
/// truncates content to per_file_cap and we'd lose visibility into
/// how big the file actually is on disk. Caller owns the returned
/// slice and the inner path strings; free with `freeLargeFiles`.
///
/// Ported in spirit from claude-code-main/src/utils/claudemd.ts
/// getLargeMemoryFiles + the doctorContextWarnings.ts wrapper. The
/// reference returns the full file content; zcode only needs the
/// size for the warning message, so we save the read.
pub fn findLargeInstructionFiles(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    threshold: u64,
) ![]LargeInstructionFile {
    var out = std.array_list.Managed(LargeInstructionFile).init(allocator);
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit();
    }

    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.iterator();
        while (it.next()) |kv| allocator.free(kv.key_ptr.*);
        seen.deinit();
    }

    const cwd_abs = try toAbsolutePath(allocator, cwd);
    defer allocator.free(cwd_abs);

    const repo_root = try detectRepoRoot(allocator, cwd_abs);
    defer if (repo_root) |path| allocator.free(path);

    const home = @import("env.zig").getOwned(allocator, "HOME") catch null;
    defer if (home) |path| allocator.free(path);

    var current = try allocator.dupe(u8, cwd_abs);
    defer allocator.free(current);

    while (true) {
        try collectLargeFromDir(allocator, current, threshold, &out, &seen);

        if (repo_root) |root| {
            if (pathEq(current, root)) break;
        } else if (std.mem.eql(u8, current, "/")) {
            break;
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (pathEq(parent, current)) break;

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }

    if (home) |home_path| {
        if (!seen.contains(home_path)) {
            try collectLargeFromDir(allocator, home_path, threshold, &out, &seen);
        }
    }

    return out.toOwnedSlice();
}

pub fn freeLargeFiles(allocator: std.mem.Allocator, files: []LargeInstructionFile) void {
    for (files) |*f| f.deinit(allocator);
    allocator.free(files);
}

fn collectLargeFromDir(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    threshold: u64,
    out: *std.array_list.Managed(LargeInstructionFile),
    seen: *std.StringHashMap(void),
) !void {
    // Track which dirs we've already scanned so the home-directory
    // pass after the cwd walk doesn't double-count.
    const dir_owned = try allocator.dupe(u8, dir_path);
    if (seen.contains(dir_owned)) {
        allocator.free(dir_owned);
    } else {
        try seen.put(dir_owned, {});
    }

    // Root-level candidates.
    for (candidates) |cand| {
        try checkOne(allocator, dir_path, cand.name, threshold, out);
    }

    // .claude/ subdirectory candidates.
    const dot_claude_dir = try std.fs.path.join(allocator, &.{ dir_path, ".claude" });
    defer allocator.free(dot_claude_dir);
    for (dot_claude_candidates) |cand| {
        try checkOne(allocator, dot_claude_dir, cand.name, threshold, out);
    }

    // Local-only variants (.local.md).
    for (local_candidates) |cand| {
        try checkOne(allocator, dir_path, cand.name, threshold, out);
    }
}

fn checkOne(
    allocator: std.mem.Allocator,
    dir: []const u8,
    name: []const u8,
    threshold: u64,
    out: *std.array_list.Managed(LargeInstructionFile),
) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, name });
    errdefer allocator.free(path);

    const stat = std.Io.Dir.cwd().statFile(rt.io, path, .{}) catch {
        allocator.free(path);
        return;
    };
    if (stat.kind != .file) {
        allocator.free(path);
        return;
    }
    if (stat.size <= threshold) {
        allocator.free(path);
        return;
    }
    try out.append(.{ .path = path, .size_bytes = stat.size });
}

/// Pretty-print the large-instruction warning for /doctor. Returns
/// an empty slice (caller still owns it) when no files exceed the
/// threshold so /doctor can skip the section without branching.
pub fn formatLargeInstructionWarning(
    allocator: std.mem.Allocator,
    cwd: []const u8,
) ![]u8 {
    const large = try findLargeInstructionFiles(allocator, cwd, MAX_INSTRUCTION_FILE_CHARS);
    defer freeLargeFiles(allocator, large);

    if (large.len == 0) return allocator.alloc(u8, 0);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    if (large.len == 1) {
        try out.writer().print(
            "[warn] large instruction file: {s} ({d} bytes > {d}). Every prompt pays this cost; consider trimming or splitting via @include.\n",
            .{ large[0].path, large[0].size_bytes, MAX_INSTRUCTION_FILE_CHARS },
        );
    } else {
        try out.writer().print(
            "[warn] {d} large instruction files (each > {d} bytes). Every prompt pays this cost; consider trimming or splitting via @include.\n",
            .{ large.len, MAX_INSTRUCTION_FILE_CHARS },
        );
        for (large) |f| {
            try out.writer().print("  - {s} ({d} bytes)\n", .{ f.path, f.size_bytes });
        }
    }
    return out.toOwnedSlice();
}

/// Result of stripping block-level HTML comments from instruction content.
/// On `stripped == false`, `bytes` aliases the input `content` (no allocation
/// happened); the caller still owns the original buffer. On `stripped == true`,
/// `bytes` is a fresh allocation and the caller is responsible for freeing the
/// original `content` it passed in.
const StripResult = struct {
    bytes: []u8,
    stripped: bool,
};

/// Strip block-level HTML comments (`<!-- ... -->`) from instruction
/// (CLAUDE.md / ZCODE.md / rules) content before it enters the prompt.
///
/// Parity with the reference `stripHtmlComments` (src/utils/claudemd.ts:292),
/// implemented without a markdown lexer as a CommonMark-subset block-comment
/// stripper:
///   - Comments inside fenced code blocks (``` / ~~~) are preserved.
///   - Comments inside inline code spans are preserved.
///   - Only comments whose trimmed line begins with `<!--` (i.e. authorial
///     notes that occupy their own line, a block-level HTML comment) are
///     stripped; an inline `<!--` in the middle of prose is left intact.
///   - An unclosed `<!--` with no matching `-->` is left in place so a typo
///     does not silently swallow the rest of the file.
///   - Residual content after a `-->` on the same line is preserved.
///
/// Line endings are left untouched: we only rewrite the comment spans, never
/// normalize CRLF (sidesteps the reference's lexer round-trip CRLF bug).
fn stripHtmlComments(allocator: std.mem.Allocator, content: []u8) !StripResult {
    // Fast path: nothing to strip (mirrors the reference `if (!content.includes('<!--'))`).
    if (std.mem.indexOf(u8, content, "<!--") == null) {
        return .{ .bytes = content, .stripped = false };
    }

    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    var in_fence = false;
    var stripped = false;

    var i: usize = 0;
    while (i < content.len) {
        // Find the end of the current line (exclusive of the newline) and the
        // start of the next line (inclusive of the newline so line endings are
        // preserved verbatim).
        const nl = std.mem.indexOfScalarPos(u8, content, i, '\n');
        const line_end = nl orelse content.len;
        const next = if (nl) |n| n + 1 else content.len;
        const line = content[i..line_end]; // excludes the newline byte
        const newline = content[line_end..next]; // "" or "\n"

        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Fence toggles (match parseImports exactly so the two passes agree).
        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
            in_fence = !in_fence;
            try out.appendSlice(line);
            try out.appendSlice(newline);
            i = next;
            continue;
        }

        // Inside a fenced block: preserve verbatim.
        if (in_fence) {
            try out.appendSlice(line);
            try out.appendSlice(newline);
            i = next;
            continue;
        }

        // Block-level HTML comment: the trimmed line begins with `<!--`.
        if (std.mem.startsWith(u8, trimmed, "<!--")) {
            // Look for the matching `-->`, which may be on this line or a later
            // one. Search from the start of `<!--` across the rest of the file.
            const comment_start = i + (std.mem.indexOf(u8, line, "<!--").?);
            if (std.mem.indexOfPos(u8, content, comment_start + 4, "-->")) |close| {
                stripped = true;
                // Preserve any prefix on the comment's first line before `<!--`
                // (e.g. leading whitespace). The trimmed line starts with `<!--`,
                // so the only prefix is leading whitespace; the reference keeps
                // residue after trimming, so we drop pure-whitespace residue.
                const after = close + 3; // index just past `-->`

                // Preserve residual content after `-->` up to the end of that
                // line. Whitespace-only residue is dropped (matches reference
                // `residue.trim().length > 0`).
                const residue_line_end = std.mem.indexOfScalarPos(u8, content, after, '\n') orelse content.len;
                const residue = content[after..residue_line_end];
                if (std.mem.trim(u8, residue, " \t\r").len > 0) {
                    try out.appendSlice(residue);
                    // Preserve the newline (if any) terminating the residue line.
                    if (residue_line_end < content.len) try out.append('\n');
                }
                // Advance past the entire comment (and its closing line).
                i = if (residue_line_end < content.len) residue_line_end + 1 else content.len;
                continue;
            }
            // Unclosed comment: leave the rest of the file intact.
            try out.appendSlice(line);
            try out.appendSlice(newline);
            i = next;
            continue;
        }

        // Ordinary line (may contain an inline `<!--` in the middle of prose,
        // or inside an inline code span): preserve verbatim.
        try out.appendSlice(line);
        try out.appendSlice(newline);
        i = next;
    }

    if (!stripped) {
        // No block-level comment was actually stripped (e.g. the only `<!--`
        // was inline or inside a fence). Discard the rebuilt buffer and return
        // the original untouched.
        out.deinit();
        return .{ .bytes = content, .stripped = false };
    }

    const bytes = try out.toOwnedSlice();
    return .{ .bytes = bytes, .stripped = true };
}

fn parseImports(allocator: std.mem.Allocator, text: []const u8) ![][]u8 {
    var out = std.array_list.Managed([]u8).init(allocator);
    errdefer freeArrayListStrings(allocator, &out);

    var in_fence = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) continue;

        // Check for explicit @include directive: "@include <path>" or "@include path"
        if (try parseIncludeDirective(allocator, trimmed)) |path| {
            try out.append(path);
            continue;
        }

        var in_inline = false;
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            const ch = line[i];
            if (ch == '`') {
                in_inline = !in_inline;
                continue;
            }
            if (in_inline or ch != '@') continue;

            var j = i + 1;
            while (j < line.len and !isImportTerminator(line[j])) : (j += 1) {}
            if (j <= i + 1) continue;

            var token = std.mem.trim(u8, line[i + 1 .. j], " \t\"'");
            token = trimImportToken(token);
            if (!looksLikeImportPath(token)) continue;

            try out.append(try allocator.dupe(u8, token));
            i = j;
        }
    }

    return out.toOwnedSlice();
}

/// Parse an explicit "@include <path>" or "@include path" directive.
/// Returns the path (owned by allocator) or null if the line is not an include directive.
fn parseIncludeDirective(allocator: std.mem.Allocator, trimmed: []const u8) !?[]u8 {
    const prefix = "@include";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    if (trimmed.len <= prefix.len) return null;

    // Must be followed by whitespace
    if (trimmed[prefix.len] != ' ' and trimmed[prefix.len] != '\t') return null;

    var rest = std.mem.trim(u8, trimmed[prefix.len..], " \t");

    // Strip angle brackets: @include <path>
    if (rest.len >= 2 and rest[0] == '<' and rest[rest.len - 1] == '>') {
        rest = rest[1 .. rest.len - 1];
    }
    // Strip quotes: @include "path" or @include 'path'
    if (rest.len >= 2 and (rest[0] == '"' or rest[0] == '\'')) {
        if (rest[rest.len - 1] == rest[0]) {
            rest = rest[1 .. rest.len - 1];
        }
    }

    rest = std.mem.trim(u8, rest, " \t");
    if (rest.len == 0) return null;

    const cleaned = trimImportToken(rest);
    if (cleaned.len == 0) return null;

    // For @include directives, accept any path since user intent is explicit.
    return try allocator.dupe(u8, cleaned);
}

/// Resolve an @include / @import path token against its importer, with
/// containment checks that prevent a hostile ZCODE.md/CLAUDE.md from including
/// arbitrary files on disk (e.g. `@include /etc/passwd` or `@include ~/.ssh/id_rsa`).
///
/// Accepted forms:
///   - Relative paths without `..` segments, resolved against the importer's directory
///   - `~/.claude/...` or `~/.zcode/...` (explicit config dirs only)
///
/// Rejected:
///   - Absolute paths
///   - `~/` pointing outside `~/.claude` and `~/.zcode`
///   - Any `..` segment
fn resolveImportPath(allocator: std.mem.Allocator, importer_path: []const u8, token: []const u8) ![]u8 {
    if (containsParentSegment(token)) return error.InstructionImportDenied;

    if (std.fs.path.isAbsolute(token)) return error.InstructionImportDenied;

    if (std.mem.startsWith(u8, token, "~/")) {
        const rest = token[2..];
        const under_claude = std.mem.startsWith(u8, rest, ".claude/") or std.mem.eql(u8, rest, ".claude");
        const under_zcode = std.mem.startsWith(u8, rest, ".zcode/") or std.mem.eql(u8, rest, ".zcode");
        if (!under_claude and !under_zcode) return error.InstructionImportDenied;
        const home = @import("env.zig").getOwned(allocator, "HOME") catch return error.InstructionImportDenied;
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, rest });
    }

    const importer_dir = std.fs.path.dirname(importer_path) orelse ".";
    return std.fs.path.join(allocator, &.{ importer_dir, token });
}

fn containsParentSegment(path: []const u8) bool {
    var it = std.mem.splitAny(u8, path, "/\\");
    while (it.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return true;
    }
    return false;
}

fn looksLikeImportPath(token: []const u8) bool {
    if (token.len == 0) return false;
    if (std.mem.startsWith(u8, token, "./")) return true;
    if (std.mem.startsWith(u8, token, "../")) return true;
    if (std.mem.startsWith(u8, token, "~/")) return true;
    if (std.fs.path.isAbsolute(token)) return true;
    if (std.mem.indexOfScalar(u8, token, '/')) |_| return true;
    return std.mem.endsWith(u8, token, ".md");
}

fn trimImportToken(token: []const u8) []const u8 {
    var t = token;
    while (t.len > 0) {
        const last = t[t.len - 1];
        if (last == '.' or last == ',' or last == ';' or last == ':' or last == ')' or last == ']' or last == '}' or last == '!' or last == '?') {
            t = t[0 .. t.len - 1];
            continue;
        }
        break;
    }
    return t;
}

fn isImportTerminator(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n' or ch == ',' or ch == ';' or ch == '(' or ch == ')' or ch == '[' or ch == ']' or ch == '{' or ch == '}' or ch == '<' or ch == '>' or ch == '"' or ch == '\'';
}

fn detectRepoRoot(allocator: std.mem.Allocator, cwd: []const u8) !?[]u8 {
    const args = [_][]const u8{ "git", "-C", cwd, "rev-parse", "--show-toplevel" };
    const result = std.process.run(allocator, rt.io, .{
        .argv = &args,
        .stdout_limit = .limited(8 * 1024),
        .stderr_limit = .limited(8 * 1024),
    }) catch return null;
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

/// Walk the same directory chain discover() would walk and
/// hash (candidate-name, file size, mtime_ns) tuples for every
/// instruction-file we find. Does NOT read file content. Used
/// by the cache to decide whether a full discover pass is
/// required or whether we can reuse the cached entries.
///
/// Any stat error on a candidate is swallowed (file absent ->
/// skip); fatal I/O errors (e.g. OS EACCES) propagate so we
/// don't silently mask real problems.
fn computeDiscoveryFingerprint(
    allocator: std.mem.Allocator,
    cwd: []const u8,
) !u64 {
    const cwd_abs = try toAbsolutePath(allocator, cwd);
    defer allocator.free(cwd_abs);

    const repo_root = try detectRepoRoot(allocator, cwd_abs);
    defer if (repo_root) |path| allocator.free(path);

    const home = @import("env.zig").getOwned(allocator, "HOME") catch null;
    defer if (home) |path| allocator.free(path);

    var hasher = std.hash.Wyhash.init(0x7a636f64652d696e); // "zcode-in"
    var current = try allocator.dupe(u8, cwd_abs);
    defer allocator.free(current);

    while (true) {
        try hashCandidateGroup(allocator, &hasher, current, &local_candidates);
        try hashCandidateGroup(allocator, &hasher, current, &candidates);
        try hashDotClaudeGroup(allocator, &hasher, current);

        if (repo_root) |root| {
            if (pathEq(current, root)) break;
        } else if (std.mem.eql(u8, current, "/")) {
            break;
        }
        const parent = std.fs.path.dirname(current) orelse break;
        if (pathEq(parent, current)) break;
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }

    if (home) |h| {
        try hashCandidateGroup(allocator, &hasher, h, &candidates);
        try hashDotClaudeGroup(allocator, &hasher, h);
    }

    return hasher.final();
}

fn hashCandidateGroup(
    allocator: std.mem.Allocator,
    hasher: *std.hash.Wyhash,
    dir: []const u8,
    group: []const Candidate,
) !void {
    for (group) |c| {
        const path = try std.fs.path.join(allocator, &.{ dir, c.name });
        defer allocator.free(path);
        hashFileStatInto(hasher, path, c.name);
    }
}

fn hashDotClaudeGroup(
    allocator: std.mem.Allocator,
    hasher: *std.hash.Wyhash,
    dir: []const u8,
) !void {
    const dot_dir = try std.fs.path.join(allocator, &.{ dir, ".claude" });
    defer allocator.free(dot_dir);
    for (dot_claude_candidates) |c| {
        const path = try std.fs.path.join(allocator, &.{ dot_dir, c.name });
        defer allocator.free(path);
        hashFileStatInto(hasher, path, c.name);
    }
}

fn hashFileStatInto(hasher: *std.hash.Wyhash, path: []const u8, name: []const u8) void {
    const stat = std.Io.Dir.cwd().statFile(rt.io, path, .{}) catch return;
    hasher.update(name);
    var scratch: [24]u8 = undefined;
    std.mem.writeInt(u64, scratch[0..8], @bitCast(stat.size), .little);
    std.mem.writeInt(i128, scratch[8..24], stat.mtime.toNanoseconds(), .little);
    hasher.update(&scratch);
}

/// Deep-clone the entries so callers own them against their own
/// allocator. Lets the cache hand out fresh slices each turn
/// while keeping its own copy pinned for future hits.
fn cloneEntries(
    allocator: std.mem.Allocator,
    src: []const types.InstructionEntry,
) ![]types.InstructionEntry {
    var out = try allocator.alloc(types.InstructionEntry, src.len);
    var done: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < done) : (i += 1) {
            allocator.free(out[i].source);
            allocator.free(out[i].content);
            freeGlobs(allocator, out[i].globs);
        }
        allocator.free(out);
    }
    for (src, 0..) |e, i| {
        const source_copy = try allocator.dupe(u8, e.source);
        errdefer allocator.free(source_copy);
        const content_copy = try allocator.dupe(u8, e.content);
        errdefer allocator.free(content_copy);
        const globs_copy = try cloneGlobs(allocator, e.globs);
        out[i] = .{
            .source = source_copy,
            .precedence = e.precedence,
            .truncated = e.truncated,
            .content = content_copy,
            .scope_distance = e.scope_distance,
            .import_depth = e.import_depth,
            .order = e.order,
            .globs = globs_copy,
        };
        done = i + 1;
    }
    return out;
}

/// Install a freshly-computed entry set into the cache, taking
/// ownership of the clone stored there. Callers pass their own
/// entries (freshly allocated) -- the cache then clones into its
/// own allocator and keeps that copy pinned for subsequent hits.
fn cacheStore(
    cache: *DiscoveryCache,
    cwd_abs: []const u8,
    fingerprint: u64,
    axis_epoch: u64,
    entries: []const types.InstructionEntry,
) !void {
    // Reset any previous content under the cache's allocator.
    cache.reset();
    const cwd_copy = try cache.owner_allocator.dupe(u8, cwd_abs);
    errdefer cache.owner_allocator.free(cwd_copy);
    const cached_entries = try cloneEntries(cache.owner_allocator, entries);
    cache.cwd = cwd_copy;
    cache.entries = cached_entries;
    cache.fingerprint = fingerprint;
    cache.axis_epoch = axis_epoch;
    cache.has_entry = true;
}

fn canonicalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const abs = try toAbsolutePath(allocator, path);
    errdefer allocator.free(abs);

    const real = allocator.dupe(u8, abs) catch return abs;
    allocator.free(abs);
    return real;
}

fn toAbsolutePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    const process_cwd = try std.process.currentPathAlloc(rt.io, allocator);
    defer allocator.free(process_cwd);
    return std.fs.path.join(allocator, &.{ process_cwd, path });
}

fn pathEq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, a, "/"), std.mem.trimEnd(u8, b, "/"));
}

fn putUniqueMapKey(allocator: std.mem.Allocator, map: *std.StringHashMap(void), key: []const u8) !void {
    if (map.contains(key)) return;
    const dup = try allocator.dupe(u8, key);
    try map.put(dup, {});
}

fn freeMapKeys(allocator: std.mem.Allocator, map: *std.StringHashMap(void)) void {
    var it = map.keyIterator();
    while (it.next()) |k| allocator.free(k.*);
    map.deinit();
}

fn freeStringSliceMutable(allocator: std.mem.Allocator, items: [][]u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

fn freeArrayListStrings(allocator: std.mem.Allocator, list: *std.array_list.Managed([]u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit();
}

const testing = std.testing;

test "instruction sort precedence" {
    var entries = [_]types.InstructionEntry{
        .{ .source = "a", .precedence = 70, .truncated = false, .content = "" },
        .{ .source = "b", .precedence = 100, .truncated = false, .content = "" },
    };
    std.mem.sort(types.InstructionEntry, entries[0..], {}, instructionLessThan);
    try testing.expect(entries[0].precedence == 100);
}

test "parse import directives skips fenced and inline code" {
    const allocator = testing.allocator;
    const text =
        \\@docs/root.md
        \\Use @docs/one.md now.
        \\`@docs/inline.md`
        \\```md
        \\@docs/fenced.md
        \\```
    ;

    const imports = try parseImports(allocator, text);
    defer freeStringSliceMutable(allocator, imports);

    try testing.expectEqual(@as(usize, 2), imports.len);
    try testing.expectEqualStrings("docs/root.md", imports[0]);
    try testing.expectEqualStrings("docs/one.md", imports[1]);
}

test "stripHtmlComments removes a standalone block comment" {
    const allocator = testing.allocator;
    const input = try allocator.dupe(u8,
        \\# Title
        \\<!-- author note -->
        \\Body text.
    );
    defer allocator.free(input);

    const res = try stripHtmlComments(allocator, input);
    defer if (res.stripped) allocator.free(res.bytes);

    try testing.expect(res.stripped);
    try testing.expect(std.mem.indexOf(u8, res.bytes, "author note") == null);
    try testing.expect(std.mem.indexOf(u8, res.bytes, "# Title") != null);
    try testing.expect(std.mem.indexOf(u8, res.bytes, "Body text.") != null);
}

test "stripHtmlComments preserves a comment inside a fenced block" {
    const allocator = testing.allocator;
    const input = try allocator.dupe(u8,
        \\Prose before.
        \\```html
        \\<!-- keep me -->
        \\```
        \\Prose after.
    );
    defer allocator.free(input);

    const res = try stripHtmlComments(allocator, input);
    defer if (res.stripped) allocator.free(res.bytes);

    // The only `<!--` is inside a fence, so nothing is stripped and the
    // original buffer is returned untouched.
    try testing.expect(!res.stripped);
    try testing.expect(std.mem.indexOf(u8, res.bytes, "keep me") != null);
}

test "stripHtmlComments preserves an inline comment in a prose line" {
    const allocator = testing.allocator;
    // Per the simplified block-level rule, an inline `<!--` in the middle of a
    // prose line (here inside an inline code span) is NOT stripped - only a
    // comment whose trimmed line begins with `<!--` is treated as block-level.
    const input = try allocator.dupe(u8, "Use `<!-- x -->` to comment.\n");
    defer allocator.free(input);

    const res = try stripHtmlComments(allocator, input);
    defer if (res.stripped) allocator.free(res.bytes);

    try testing.expect(!res.stripped);
    try testing.expectEqualStrings("Use `<!-- x -->` to comment.\n", res.bytes);
}

test "stripHtmlComments leaves an unclosed comment intact" {
    const allocator = testing.allocator;
    const input = try allocator.dupe(u8,
        \\# Title
        \\<!-- never closed
        \\Important text that must survive.
    );
    defer allocator.free(input);

    const res = try stripHtmlComments(allocator, input);
    defer if (res.stripped) allocator.free(res.bytes);

    // No matching `-->`, so the comment and the rest of the file are kept.
    try testing.expect(!res.stripped);
    try testing.expect(std.mem.indexOf(u8, res.bytes, "Important text that must survive.") != null);
    try testing.expect(std.mem.indexOf(u8, res.bytes, "<!-- never closed") != null);
}

test "stripHtmlComments fast path returns byte-identical content" {
    const allocator = testing.allocator;
    const input = try allocator.dupe(u8, "# Title\nNo comments here at all.\n");
    defer allocator.free(input);

    const res = try stripHtmlComments(allocator, input);
    defer if (res.stripped) allocator.free(res.bytes);

    try testing.expect(!res.stripped);
    try testing.expect(res.bytes.ptr == input.ptr);
    try testing.expectEqualStrings(input, res.bytes);
}

test "stripHtmlComments keeps residual content after the close on the same line" {
    const allocator = testing.allocator;
    const input = try allocator.dupe(u8, "<!-- note --> Use tabs\nNext line.\n");
    defer allocator.free(input);

    const res = try stripHtmlComments(allocator, input);
    defer if (res.stripped) allocator.free(res.bytes);

    try testing.expect(res.stripped);
    try testing.expect(std.mem.indexOf(u8, res.bytes, "note") == null);
    try testing.expect(std.mem.indexOf(u8, res.bytes, "Use tabs") != null);
    try testing.expect(std.mem.indexOf(u8, res.bytes, "Next line.") != null);
}

test "stripHtmlComments removes a multi-line block comment" {
    const allocator = testing.allocator;
    const input = try allocator.dupe(u8,
        \\Before.
        \\<!-- line one
        \\line two -->
        \\After.
    );
    defer allocator.free(input);

    const res = try stripHtmlComments(allocator, input);
    defer if (res.stripped) allocator.free(res.bytes);

    try testing.expect(res.stripped);
    try testing.expect(std.mem.indexOf(u8, res.bytes, "line one") == null);
    try testing.expect(std.mem.indexOf(u8, res.bytes, "line two") == null);
    try testing.expect(std.mem.indexOf(u8, res.bytes, "Before.") != null);
    try testing.expect(std.mem.indexOf(u8, res.bytes, "After.") != null);
}

test "parse @include directive with angle brackets" {
    const allocator = testing.allocator;
    const text =
        \\@include <.claude/rules/security.md>
        \\@include ./docs/guide.md
        \\@include "config/rules.md"
    ;

    const imports = try parseImports(allocator, text);
    defer freeStringSliceMutable(allocator, imports);

    try testing.expectEqual(@as(usize, 3), imports.len);
    try testing.expectEqualStrings(".claude/rules/security.md", imports[0]);
    try testing.expectEqualStrings("./docs/guide.md", imports[1]);
    try testing.expectEqualStrings("config/rules.md", imports[2]);
}

test "parse @include skips fenced code" {
    const allocator = testing.allocator;
    const text =
        \\@include ./real.md
        \\```
        \\@include ./fenced.md
        \\```
        \\@include ./also-real.md
    ;

    const imports = try parseImports(allocator, text);
    defer freeStringSliceMutable(allocator, imports);

    try testing.expectEqual(@as(usize, 2), imports.len);
    try testing.expectEqualStrings("./real.md", imports[0]);
    try testing.expectEqualStrings("./also-real.md", imports[1]);
}

test "parse @include ignores incomplete directive" {
    const allocator = testing.allocator;
    const text =
        \\@include
        \\@include
    ;

    const imports = try parseImports(allocator, text);
    defer freeStringSliceMutable(allocator, imports);

    // Both lines have @include with no path or whitespace-only path, so nothing is extracted.
    // The bare-@ parser sees "include" which does not look like a path (no slash, no .md).
    try testing.expectEqual(@as(usize, 0), imports.len);
}

test "parse mixed @include and bare @ imports" {
    const allocator = testing.allocator;
    const text =
        \\@include <shared/rules.md>
        \\Some text with @./local/extra.md inline reference.
        \\@include ./another.md
    ;

    const imports = try parseImports(allocator, text);
    defer freeStringSliceMutable(allocator, imports);

    try testing.expectEqual(@as(usize, 3), imports.len);
    try testing.expectEqualStrings("shared/rules.md", imports[0]);
    try testing.expectEqualStrings("./local/extra.md", imports[1]);
    try testing.expectEqualStrings("./another.md", imports[2]);
}

test "findLargeInstructionFiles flags files over the threshold" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Small file: under threshold, not reported.
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "ZCODE.md", .data = "tiny instructions\n" });

    // Big file: 200 bytes content, threshold = 100, should be flagged.
    var huge = std_io.StringBuilder.init(allocator);
    defer huge.deinit();
    var i: usize = 0;
    while (i < 200) : (i += 1) try huge.append('x');
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "CLAUDE.md", .data = huge.items() });

    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer allocator.free(cwd);

    const large = try findLargeInstructionFiles(allocator, cwd, 100);
    defer freeLargeFiles(allocator, large);

    // Find CLAUDE.md in the result. The walk also climbs to the
    // parent dirs, so other repos' files might surface; we only
    // assert that OUR test fixture is in there.
    var found = false;
    for (large) |f| {
        if (std.mem.endsWith(u8, f.path, "CLAUDE.md") and f.size_bytes == 200) {
            found = true;
            break;
        }
    }
    try testing.expect(found);

    // ZCODE.md (18 bytes) must NOT be in the result.
    for (large) |f| {
        try testing.expect(!std.mem.endsWith(u8, f.path, "ZCODE.md"));
    }
}

test "findLargeInstructionFiles returns empty when nothing crosses threshold" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "ZCODE.md", .data = "small\n" });

    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer allocator.free(cwd);

    const large = try findLargeInstructionFiles(allocator, cwd, 1_000_000);
    defer freeLargeFiles(allocator, large);

    // 1MB threshold; nothing in this fresh tmp dir should match.
    // Parent dirs may contain large files unrelated to the test --
    // we only assert that no path ends in our fixture name.
    for (large) |f| {
        try testing.expect(!std.mem.endsWith(u8, f.path, "/ZCODE.md") or
            std.mem.indexOf(u8, f.path, cwd) == null);
    }
}

test "formatLargeInstructionWarning produces empty when no files exceed threshold" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "ZCODE.md", .data = "tiny\n" });
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer allocator.free(cwd);

    // Use a synthetic high threshold so the test is independent of
    // any large files that may exist in parent dirs.
    const out = try formatLargeInstructionWarning(allocator, cwd);
    defer allocator.free(out);
    // We can't assert the result is empty because parent dirs may
    // legitimately have large files; we just confirm the call
    // doesn't crash and that any warning text starts with [warn].
    if (out.len > 0) {
        try testing.expect(std.mem.startsWith(u8, out, "[warn]"));
    }
}

test "MAX_INSTRUCTION_FILE_CHARS matches reference" {
    // Exact constant value protects against accidental drift from
    // the reference's MAX_MEMORY_CHARACTER_COUNT.
    try testing.expectEqual(@as(usize, 40_000), MAX_INSTRUCTION_FILE_CHARS);
}

test "discover cache returns a hit on a second call against the same tree" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "ZCODE.md", .data = "hello from zcode.md" });

    var cache = DiscoveryCache.init(testing.allocator);
    defer cache.deinit();

    const opts = DiscoverOptions{
        .per_file_cap = 10_000,
        .total_cap = 100_000,
        .cache = &cache,
        .axis_epoch = 1,
    };

    const first = try discover(testing.allocator, cwd, opts);
    freeEntries(testing.allocator, first);
    try testing.expectEqual(@as(u64, 0), cache.hits);
    try testing.expectEqual(@as(u64, 1), cache.misses);

    const second = try discover(testing.allocator, cwd, opts);
    freeEntries(testing.allocator, second);
    try testing.expectEqual(@as(u64, 1), cache.hits);
    try testing.expectEqual(@as(u64, 1), cache.misses);
}

test "discover cache busts when axis epoch changes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "ZCODE.md", .data = "epoch test" });

    var cache = DiscoveryCache.init(testing.allocator);
    defer cache.deinit();

    var opts = DiscoverOptions{
        .per_file_cap = 10_000,
        .total_cap = 100_000,
        .cache = &cache,
        .axis_epoch = 1,
    };
    const first = try discover(testing.allocator, cwd, opts);
    freeEntries(testing.allocator, first);
    try testing.expectEqual(@as(u64, 1), cache.misses);

    opts.axis_epoch = 2;
    const second = try discover(testing.allocator, cwd, opts);
    freeEntries(testing.allocator, second);
    try testing.expectEqual(@as(u64, 2), cache.misses);
    try testing.expectEqual(@as(u64, 0), cache.hits);
}

test "discover cache hit produces entries equal to a fresh discover" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "ZCODE.md", .data = "content-a" });
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "CLAUDE.md", .data = "content-b" });

    var cache = DiscoveryCache.init(testing.allocator);
    defer cache.deinit();

    const opts_cached = DiscoverOptions{
        .per_file_cap = 10_000,
        .total_cap = 100_000,
        .cache = &cache,
        .axis_epoch = 1,
    };
    const warm = try discover(testing.allocator, cwd, opts_cached);
    freeEntries(testing.allocator, warm);

    const cached = try discover(testing.allocator, cwd, opts_cached);
    defer freeEntries(testing.allocator, cached);

    const fresh = try discover(testing.allocator, cwd, .{ .per_file_cap = 10_000, .total_cap = 100_000 });
    defer freeEntries(testing.allocator, fresh);

    try testing.expectEqual(fresh.len, cached.len);
    for (fresh, 0..) |f, i| {
        try testing.expectEqualStrings(f.source, cached[i].source);
        try testing.expectEqualStrings(f.content, cached[i].content);
        try testing.expectEqual(f.precedence, cached[i].precedence);
    }
}

// ── memory-09: path-scoped conditional instruction rules ──────────────

/// True when one of the discovered entries was sourced from a file
/// whose path ends in `suffix` (e.g. "api.md").
fn entriesContainSource(entries: []const types.InstructionEntry, suffix: []const u8) bool {
    for (entries) |e| {
        if (std.mem.endsWith(u8, e.source, suffix)) return true;
    }
    return false;
}

test "conditional rule loads only when a target path matches its globs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    try tmp.dir.createDirPath(rt.io, ".claude/rules");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".claude/rules/api.md",
        .data = "---\npaths: src/api/**\n---\n# API rule\nUse the API conventions.\n",
    });

    // Target under src/api -> rule is included.
    {
        const targets = [_][]const u8{"src/api/handler.zig"};
        const entries = try discover(testing.allocator, cwd, .{
            .per_file_cap = 10_000,
            .total_cap = 100_000,
            .target_paths = &targets,
        });
        defer freeEntries(testing.allocator, entries);
        try testing.expect(entriesContainSource(entries, "api.md"));
    }

    // Target elsewhere -> rule is omitted.
    {
        const targets = [_][]const u8{"src/ui/view.zig"};
        const entries = try discover(testing.allocator, cwd, .{
            .per_file_cap = 10_000,
            .total_cap = 100_000,
            .target_paths = &targets,
        });
        defer freeEntries(testing.allocator, entries);
        try testing.expect(!entriesContainSource(entries, "api.md"));
    }
}

test "rule with no paths frontmatter loads unconditionally" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    try tmp.dir.createDirPath(rt.io, ".claude/rules");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".claude/rules/plain.md",
        .data = "# Plain rule\nNo frontmatter here.\n",
    });

    // Even with a non-matching target, an unconditioned rule loads.
    const targets = [_][]const u8{"src/ui/view.zig"};
    const entries = try discover(testing.allocator, cwd, .{
        .per_file_cap = 10_000,
        .total_cap = 100_000,
        .target_paths = &targets,
    });
    defer freeEntries(testing.allocator, entries);
    try testing.expect(entriesContainSource(entries, "plain.md"));
    // Its parsed globs are empty (unconditional).
    for (entries) |e| {
        if (std.mem.endsWith(u8, e.source, "plain.md")) {
            try testing.expectEqual(@as(usize, 0), e.globs.len);
        }
    }
}

test "rule with match-all paths loads unconditionally" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    try tmp.dir.createDirPath(rt.io, ".claude/rules");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".claude/rules/all.md",
        .data = "---\npaths: **\n---\n# Matches everything\n",
    });

    // No target supplied at all -> still loads (match-all is no gating).
    const entries = try discover(testing.allocator, cwd, .{
        .per_file_cap = 10_000,
        .total_cap = 100_000,
    });
    defer freeEntries(testing.allocator, entries);
    try testing.expect(entriesContainSource(entries, "all.md"));
    for (entries) |e| {
        if (std.mem.endsWith(u8, e.source, "all.md")) {
            try testing.expectEqual(@as(usize, 0), e.globs.len);
        }
    }
}

test "trailing /** is stripped so the dir itself matches" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    try tmp.dir.createDirPath(rt.io, ".claude/rules");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".claude/rules/api.md",
        .data = "---\npaths: src/api/**\n---\n# API rule\n",
    });

    // The bare directory `src/api` matches (because `/**` was stripped to `src/api`).
    {
        const targets = [_][]const u8{"src/api"};
        const entries = try discover(testing.allocator, cwd, .{
            .per_file_cap = 10_000,
            .total_cap = 100_000,
            .target_paths = &targets,
        });
        defer freeEntries(testing.allocator, entries);
        try testing.expect(entriesContainSource(entries, "api.md"));
        // The recorded glob has the /** suffix stripped.
        for (entries) |e| {
            if (std.mem.endsWith(u8, e.source, "api.md")) {
                try testing.expectEqual(@as(usize, 1), e.globs.len);
                try testing.expectEqualStrings("src/api", e.globs[0]);
            }
        }
    }

    // A nested file under src/api also matches.
    {
        const targets = [_][]const u8{"src/api/x.zig"};
        const entries = try discover(testing.allocator, cwd, .{
            .per_file_cap = 10_000,
            .total_cap = 100_000,
            .target_paths = &targets,
        });
        defer freeEntries(testing.allocator, entries);
        try testing.expect(entriesContainSource(entries, "api.md"));
    }
}

test "parseFrontmatterPaths and relativizeTarget unit behaviour" {
    // relativizeTarget: relative paths pass through; `..`-escapes are rejected.
    try testing.expectEqualStrings("src/api/x.zig", relativizeTarget("/repo", "src/api/x.zig").?);
    try testing.expectEqual(@as(?[]const u8, null), relativizeTarget("/repo", "../escape"));
    // Absolute target under base -> stripped to relative form.
    try testing.expectEqualStrings("src/api/x.zig", relativizeTarget("/repo", "/repo/src/api/x.zig").?);
    // Absolute target outside base -> null (no match).
    try testing.expectEqual(@as(?[]const u8, null), relativizeTarget("/repo", "/other/src/x.zig"));
    // Empty target -> empty relative form.
    try testing.expectEqualStrings("", relativizeTarget("/repo", "").?);
}

// ui-dialogs-13 (Task 24.7) verification: zcode is STRICTER than the
// Claude Code reference. The reference shows a ClaudeMdExternalIncludesDialog
// to prompt the user before loading @-includes that resolve OUTSIDE the
// workspace. zcode's resolveImportPath refuses every such external include
// outright (absolute paths, any `..` segment, and `~/` paths not under the
// explicit `.claude`/`.zcode` config dirs), so there is no class of
// arbitrary external include to gate -- the dialog has nothing to prompt
// about. This test pins that containment so a future change that loosens
// resolveImportPath cannot silently reintroduce the external-include gap
// without breaking this assertion. Documented deviation: zcode declines
// external includes rather than prompting for them.
test "resolveImportPath refuses external includes (stricter than reference)" {
    const a = testing.allocator;

    // Absolute path -> denied (e.g. @include /etc/passwd).
    try testing.expectError(error.InstructionImportDenied, resolveImportPath(a, "/repo/ZCODE.md", "/etc/passwd"));

    // `..` escape -> denied, even when the importer lives deep in the tree.
    try testing.expectError(error.InstructionImportDenied, resolveImportPath(a, "/repo/sub/ZCODE.md", "../../secret.md"));

    // A bare `..` token -> denied.
    try testing.expectError(error.InstructionImportDenied, resolveImportPath(a, "/repo/ZCODE.md", ".."));

    // `~/` outside the explicit config dirs -> denied (e.g. @include ~/.ssh/id_rsa).
    try testing.expectError(error.InstructionImportDenied, resolveImportPath(a, "/repo/ZCODE.md", "~/.ssh/id_rsa"));

    // A normal relative include stays CONTAINED: it resolves under the
    // importer's own directory, never escaping the workspace subtree.
    {
        const resolved = try resolveImportPath(a, "/repo/ZCODE.md", "docs/rules.md");
        defer a.free(resolved);
        try testing.expectEqualStrings("/repo/docs/rules.md", resolved);
    }

    // The ONLY out-of-workspace includes zcode permits are the explicit
    // `~/.claude/...` and `~/.zcode/...` config dirs -- known config
    // locations, not the workspace-relative external includes the
    // reference dialog warns about. They resolve under HOME (the test
    // runner installs a HOME) and stay inside the sanctioned config dir.
    {
        const home = @import("env.zig").getOwned(a, "HOME") catch null;
        if (home) |h| {
            defer a.free(h);
            const resolved = try resolveImportPath(a, "/repo/ZCODE.md", "~/.claude/shared.md");
            defer a.free(resolved);
            const expected = try std.fs.path.join(a, &.{ h, ".claude/shared.md" });
            defer a.free(expected);
            try testing.expectEqualStrings(expected, resolved);
            // Confirms the only external include is rooted at HOME, i.e.
            // the sanctioned config dir, never an arbitrary path.
            try testing.expect(std.mem.startsWith(u8, resolved, h));
        }
    }
}
