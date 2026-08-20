//! Named prompt-section registry.
//!
//! Ports the cornerstone mechanism from the leaked Claude Code
//! source (`src/constants/systemPromptSections.ts` +
//! `src/constants/prompts.ts`): every fragment of the system
//! prompt is a named, independently-rendered section with an
//! explicit cache scope. Static sections memoize until an
//! invalidation event fires; dynamic sections recompute per turn.
//!
//! Why this is the cornerstone: before this module, `prompt_engine`
//! rebuilt the entire system prompt from primitives on every
//! model call -- walking disk for instruction files, shelling out
//! to git for status / diff, re-rendering tool catalogues --
//! regardless of whether anything had actually changed. The
//! registry lets expensive producers run ONCE and stay cached
//! across the whole session until an explicit invalidation event
//! (/clear, /compact, MCP connect, workspace-dirs edit, model
//! switch) bumps the relevant epoch. That matches what the
//! reference does with its `systemPromptSection` / `DANGEROUS_
//! uncachedSystemPromptSection` pair and lets zcode get predictable
//! per-turn latency on top of prompt caching.
//!
//! This file intentionally owns no prompt CONTENT -- it is a pure
//! composition primitive. Callers (prompt_engine, prompt_helpers,
//! etc.) register sections with render functions and this module
//! decides when to reuse vs recompute.

const std = @import("std");

pub const Scope = enum {
    /// Before the `__SYSTEM_PROMPT_STATIC_BOUNDARY__` sentinel.
    /// Cacheable until an invalidation event fires.
    static,
    /// After the boundary. Recomputed every turn. Use this for
    /// sections whose content changes per user-turn (git status,
    /// recent tool outcomes, user prompt-specific hints).
    dynamic,
};

/// Invalidation axes. A section declares which axes it depends on.
/// When any of those axes bumps its epoch, the section's cached
/// render is discarded. The reference calls the manual version of
/// this `DANGEROUS_uncachedSystemPromptSection`; zcode makes the
/// dependency declarative instead of all-or-nothing.
pub const Axis = enum(u8) {
    /// Bump on `/clear`, `/compact`, session switch. Virtually
    /// everything depends on this.
    session = 0,
    /// Bump when the active model or provider changes.
    model = 1,
    /// Bump when a ZCODE.md / CLAUDE.md / AGENTS.md / GEMINI.md
    /// on the precedence walk is edited.
    instructions = 2,
    /// Bump when MCP connects, disconnects, or reloads a server.
    mcp = 3,
    /// Bump when `/add-dir` adds or removes a workspace root.
    workspace_dirs = 4,
    /// Bump when the tool allowlist, agent activation, or effort
    /// changes -- anything that alters the callable tool surface.
    tool_catalog = 5,

    pub const count: comptime_int = 6;
};

pub const Deps = struct {
    axes: std.EnumSet(Axis) = std.EnumSet(Axis).initEmpty(),

    pub fn on(comptime axes: []const Axis) Deps {
        var set = std.EnumSet(Axis).initEmpty();
        inline for (axes) |a| set.insert(a);
        return .{ .axes = set };
    }
};

pub const RenderError = anyerror;

/// A render function is free to use any allocator the registry
/// hands it; the returned slice is owned by the allocator that
/// the registry passes in -- typically the registry's own long-
/// lived arena for static sections so cached bytes survive across
/// turns.
pub const RenderFn = *const fn (ctx: *const anyopaque, allocator: std.mem.Allocator) RenderError![]u8;

pub const Section = struct {
    name: []const u8,
    scope: Scope,
    deps: Deps = .{},
    render: RenderFn,
};

const CacheEntry = struct {
    /// Allocator that owns `bytes`. For static sections this is
    /// the registry's long-lived arena so entries can live across
    /// turns. For dynamic sections we don't cache at all.
    bytes: []u8,
    /// Per-axis epoch the entry was rendered against. If any
    /// entry in `epochs` is below the registry's current epoch
    /// for that axis, the cache is stale.
    epochs: [Axis.count]u64,
};

/// Process-wide registry handle. agent_runtime owns the registry
/// instance and calls setGlobal on init; prompt_helpers and
/// prompt_engine read via global() and fall back to inline
/// rendering when null (tests, CLI helpers that don't spin up a
/// full runtime). Using a module-scoped singleton avoids
/// threading the pointer through half the codebase, and mirrors
/// how the reference's `sectionRegistry` is a singleton in
/// systemPromptSections.ts.
var global_registry: ?*Registry = null;

pub fn setGlobal(r: ?*Registry) void {
    global_registry = r;
}

pub fn global() ?*Registry {
    return global_registry;
}

pub const Registry = struct {
    allocator: std.mem.Allocator,
    /// Arena that owns all cached render outputs. Reset on
    /// invalidateAll() / clearCache(); individual static-section
    /// invalidations drop their CacheEntry but can't reclaim the
    /// bytes until the next reset. That's fine -- the common
    /// invalidation event (/clear) resets wholesale.
    arena: std.heap.ArenaAllocator,
    sections: std.array_list.Managed(Section),
    cache: std.StringHashMap(CacheEntry),
    epochs: [Axis.count]u64 = [_]u64{1} ** Axis.count,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .sections = std.array_list.Managed(Section).init(allocator),
            .cache = std.StringHashMap(CacheEntry).init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        self.sections.deinit();
        self.cache.deinit();
        self.arena.deinit();
    }

    pub fn register(self: *Registry, section: Section) !void {
        try self.sections.append(section);
    }

    /// Bump the epoch for `axis`. Next `render()` call will
    /// recompute any section that depends on this axis.
    pub fn invalidate(self: *Registry, axis: Axis) void {
        self.epochs[@intFromEnum(axis)] +%= 1;
    }

    /// Full reset: bump every axis, drop the cache map, reset
    /// the arena. Use on `/clear` / `/compact` / session switch.
    pub fn invalidateAll(self: *Registry) void {
        inline for (0..Axis.count) |i| self.epochs[i] +%= 1;
        self.cache.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }

    fn isStale(self: *const Registry, entry: CacheEntry, deps: Deps) bool {
        var i: usize = 0;
        while (i < Axis.count) : (i += 1) {
            const axis: Axis = @enumFromInt(i);
            if (!deps.axes.contains(axis)) continue;
            if (entry.epochs[i] != self.epochs[i]) return true;
        }
        return false;
    }

    fn snapshotEpochs(self: *const Registry) [Axis.count]u64 {
        return self.epochs;
    }

    /// Render a single section. For static sections with matching
    /// epochs this is a hashmap hit returning cached bytes; for
    /// stale or dynamic sections it calls the render fn.
    ///
    /// `out_allocator` decides ownership of the returned slice.
    /// Callers needing a copy outside the registry's arena should
    /// pass their own allocator -- the registry will still cache
    /// the rendered bytes in its arena and dupe into the caller's
    /// allocator.
    pub fn renderSection(
        self: *Registry,
        name: []const u8,
        ctx: *const anyopaque,
        out_allocator: std.mem.Allocator,
    ) ![]u8 {
        const section = self.find(name) orelse return error.SectionNotRegistered;

        if (section.scope == .static) {
            if (self.cache.get(name)) |entry| {
                if (!self.isStale(entry, section.deps)) {
                    return out_allocator.dupe(u8, entry.bytes);
                }
            }
            const bytes = try section.render(ctx, self.arena.allocator());
            try self.cache.put(name, .{ .bytes = bytes, .epochs = self.snapshotEpochs() });
            return out_allocator.dupe(u8, bytes);
        }

        // Dynamic: never cache. Caller-owned allocation.
        return section.render(ctx, out_allocator);
    }

    fn find(self: *const Registry, name: []const u8) ?Section {
        for (self.sections.items) |s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    /// Diagnostic: how many sections are currently cached. Handy
    /// for /heapdump and tests.
    pub fn cacheSize(self: *const Registry) usize {
        return self.cache.count();
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

const TestCtx = struct { counter: *usize };

fn testRenderStatic(ctx: *const anyopaque, allocator: std.mem.Allocator) ![]u8 {
    const c: *const TestCtx = @ptrCast(@alignCast(ctx));
    c.counter.* += 1;
    return allocator.dupe(u8, "static-output");
}

fn testRenderDynamic(ctx: *const anyopaque, allocator: std.mem.Allocator) ![]u8 {
    const c: *const TestCtx = @ptrCast(@alignCast(ctx));
    c.counter.* += 1;
    return std.fmt.allocPrint(allocator, "dynamic-{d}", .{c.counter.*});
}

test "static section memoizes across renders" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    try reg.register(.{
        .name = "env",
        .scope = .static,
        .deps = Deps.on(&.{.session}),
        .render = &testRenderStatic,
    });

    var counter: usize = 0;
    const ctx = TestCtx{ .counter = &counter };

    for (0..5) |_| {
        const b = try reg.renderSection("env", &ctx, testing.allocator);
        defer testing.allocator.free(b);
        try testing.expectEqualStrings("static-output", b);
    }
    try testing.expectEqual(@as(usize, 1), counter);
}

test "invalidate axis forces recompute" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    try reg.register(.{
        .name = "env",
        .scope = .static,
        .deps = Deps.on(&.{.session}),
        .render = &testRenderStatic,
    });

    var counter: usize = 0;
    const ctx = TestCtx{ .counter = &counter };

    const a = try reg.renderSection("env", &ctx, testing.allocator);
    testing.allocator.free(a);
    reg.invalidate(.session);
    const b = try reg.renderSection("env", &ctx, testing.allocator);
    testing.allocator.free(b);
    try testing.expectEqual(@as(usize, 2), counter);
}

test "invalidating an unused axis does not bust the cache" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    try reg.register(.{
        .name = "env",
        .scope = .static,
        .deps = Deps.on(&.{.session}),
        .render = &testRenderStatic,
    });

    var counter: usize = 0;
    const ctx = TestCtx{ .counter = &counter };
    const a = try reg.renderSection("env", &ctx, testing.allocator);
    testing.allocator.free(a);
    reg.invalidate(.mcp); // different axis
    const b = try reg.renderSection("env", &ctx, testing.allocator);
    testing.allocator.free(b);
    try testing.expectEqual(@as(usize, 1), counter);
}

test "dynamic sections bypass the cache" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    try reg.register(.{
        .name = "git-status",
        .scope = .dynamic,
        .render = &testRenderDynamic,
    });

    var counter: usize = 0;
    const ctx = TestCtx{ .counter = &counter };

    const a = try reg.renderSection("git-status", &ctx, testing.allocator);
    defer testing.allocator.free(a);
    const b = try reg.renderSection("git-status", &ctx, testing.allocator);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("dynamic-1", a);
    try testing.expectEqualStrings("dynamic-2", b);
    try testing.expectEqual(@as(usize, 2), counter);
    try testing.expectEqual(@as(usize, 0), reg.cacheSize());
}

test "invalidateAll resets arena and cache count" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    try reg.register(.{
        .name = "env",
        .scope = .static,
        .deps = Deps.on(&.{.session}),
        .render = &testRenderStatic,
    });

    var counter: usize = 0;
    const ctx = TestCtx{ .counter = &counter };
    const a = try reg.renderSection("env", &ctx, testing.allocator);
    testing.allocator.free(a);
    try testing.expectEqual(@as(usize, 1), reg.cacheSize());

    reg.invalidateAll();
    try testing.expectEqual(@as(usize, 0), reg.cacheSize());

    const b = try reg.renderSection("env", &ctx, testing.allocator);
    testing.allocator.free(b);
    try testing.expectEqual(@as(usize, 2), counter);
}

test "unknown section returns SectionNotRegistered" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var counter: usize = 0;
    const ctx = TestCtx{ .counter = &counter };
    try testing.expectError(error.SectionNotRegistered, reg.renderSection("nope", &ctx, testing.allocator));
}
