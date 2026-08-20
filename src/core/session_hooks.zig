//! Task 15 (hooks-13): session-scoped / frontmatter / skill hook registration.
//!
//! Settings.json hooks are read from disk every dispatch (see
//! `hooks.runConfiguredFromSources`). This module adds an *ephemeral, in-memory*
//! registry of `HookDef`s that augments those disk hooks for the lifetime of the
//! session: agent/skill frontmatter hooks and any programmatically-registered
//! hook end up here and are merged in at dispatch time alongside the snapshot
//! hooks.
//!
//! Reference: claude-code-main `sessionHooks.ts` (`addSessionHook`),
//! `registerFrontmatterHooks.ts` (agent/skill frontmatter; converts an agent's
//! `Stop` hook to `SubagentStop`), `registerSkillHooks.ts`.
//!
//! Scope of this port:
//!   - Only declarative `command` / `prompt` / `http` / `agent` defs are
//!     supported. Function/callback hooks (JS closures, `addFunctionHook`,
//!     `registerStructuredOutputEnforcement`) cannot be ported to a native binary
//!     (no embedded JS runtime) and are intentionally out of scope.
//!   - The registry is process-global and session-scoped: `clearSession()` /
//!     `resetForTest()` drop everything. Like `rt.io`, mutation is install-once
//!     discipline; tests reset it.
//!
//! Memory: each registered def's strings are duped into a private arena so the
//! stored `HookDef`s do not borrow from the caller's (possibly transient)
//! buffers. The arena is freed wholesale on `clearSession()`.

const std = @import("std");
const rt = @import("zcode_runtime");
const hook_config = @import("hook_config.zig");
const hook_event = @import("hook_event.zig");

pub const HookDef = hook_config.HookDef;

/// Process-global session hook registry. Guarded by a mutex because frontmatter
/// loaders and the dispatch loop may touch it from different call sites.
pub const Registry = struct {
    arena: ?std.heap.ArenaAllocator = null,
    defs: std.ArrayList(HookDef) = .empty,
    mutex: std.Io.Mutex = .init,

    /// Lazily initialize the backing arena from `gpa` on first use.
    fn ensureArena(self: *Registry, gpa: std.mem.Allocator) *std.heap.ArenaAllocator {
        if (self.arena == null) self.arena = std.heap.ArenaAllocator.init(gpa);
        return &self.arena.?;
    }

    /// Register a declarative session hook. The def's strings are deep-copied
    /// into the registry's arena so the caller's buffers may be freed afterward.
    /// `gpa` is the long-lived allocator that backs the arena (use `rt.gpa` in
    /// production, `testing.allocator` in tests).
    pub fn add(self: *Registry, gpa: std.mem.Allocator, def: HookDef) !void {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        const a = self.ensureArena(gpa).allocator();
        const owned = try dupeDef(a, def);
        try self.defs.append(a, owned);
    }

    /// Borrowed view of every registered session hook. The dispatch loop filters
    /// by `def.event` itself (mirroring the disk-source path), so this returns
    /// the full set rather than a per-event allocation. Valid until the next
    /// `clearSession()` / `resetForTest()`.
    pub fn all(self: *Registry) []const HookDef {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        return self.defs.items;
    }

    /// Allocate a filtered copy of the registered hooks for `event`. The outer
    /// slice is owned by `out_allocator` and must be freed by the caller; the
    /// `HookDef` strings still borrow from the registry arena (valid until
    /// `clearSession`). Convenience for callers that prefer a pre-filtered list.
    pub fn list(self: *Registry, out_allocator: std.mem.Allocator, event: hook_event.Event) ![]HookDef {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        var out: std.ArrayList(HookDef) = .empty;
        errdefer out.deinit(out_allocator);
        for (self.defs.items) |d| {
            if (d.event == event) try out.append(out_allocator, d);
        }
        return out.toOwnedSlice(out_allocator);
    }

    /// Current registered-def count -- a restore mark for a bounded-scope batch
    /// (skills-11: a forked skill registers its frontmatter hooks, runs, then
    /// rolls back to this mark so the hooks do not outlive the skill). Taken
    /// under the mutex so it is consistent with concurrent `add`s.
    pub fn markCount(self: *Registry) usize {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        return self.defs.items.len;
    }

    /// Roll the registry back to a `markCount` mark, dropping every def appended
    /// since. The dropped defs' arena strings are not individually freed (the
    /// arena is reclaimed wholesale on `clearSession`); this only shrinks the
    /// dispatched-set so a bounded-scope batch (a forked skill's hooks) stops
    /// firing once the scope ends. A mark past the current length is a no-op.
    pub fn restoreCount(self: *Registry, mark: usize) void {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        if (mark < self.defs.items.len) self.defs.items.len = mark;
    }

    /// Drop every registered session hook and free the arena. Called at session
    /// teardown (and by `resetForTest`).
    pub fn clearSession(self: *Registry) void {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        self.defs = .empty;
        if (self.arena) |*ar| {
            ar.deinit();
            self.arena = null;
        }
    }
};

/// Process-global instance. Mirrors `async_hook_registry.instance` and the
/// snapshot's process-global; same install-once discipline.
pub var instance: Registry = .{};

/// Deep-copy a `HookDef`'s strings into `a` so the stored def owns its memory.
fn dupeDef(a: std.mem.Allocator, def: HookDef) !HookDef {
    var env_vars: []const []const u8 = &.{};
    if (def.allowed_env_vars.len > 0) {
        const owned = try a.alloc([]const u8, def.allowed_env_vars.len);
        for (def.allowed_env_vars, 0..) |v, i| owned[i] = try a.dupe(u8, v);
        env_vars = owned;
    }
    return .{
        .event = def.event,
        .matcher = try a.dupe(u8, def.matcher),
        .hook_type = def.hook_type,
        .body = try a.dupe(u8, def.body),
        .model = try a.dupe(u8, def.model),
        .timeout_s = def.timeout_s,
        .once = def.once,
        .is_async = def.is_async,
        .if_cond = try a.dupe(u8, def.if_cond),
        .shell = try a.dupe(u8, def.shell),
        .status_message = try a.dupe(u8, def.status_message),
        .async_rewake = def.async_rewake,
        .headers_json = try a.dupe(u8, def.headers_json),
        .allowed_env_vars = env_vars,
    };
}

/// What kind of frontmatter owner is registering hooks. Agents convert a `Stop`
/// hook into `SubagentStop` so a sub-agent's stop does not fire the top-level
/// Stop hooks (reference: registerFrontmatterHooks.ts). Skills register their
/// hooks verbatim.
pub const FrontmatterKind = enum { agent, skill };

/// Remap a frontmatter hook event for its owner. For agents, `Stop` becomes
/// `SubagentStop` (and `StopFailure` would likewise be a sub-agent stop); every
/// other event passes through unchanged. Skills pass everything through.
pub fn remapFrontmatterEvent(kind: FrontmatterKind, event: hook_event.Event) hook_event.Event {
    if (kind == .agent and event == .stop) return .subagent_stop;
    return event;
}

/// Register a batch of agent/skill frontmatter hooks as session hooks. Each def
/// is event-remapped per `kind` (agent `Stop` -> `SubagentStop`) and deep-copied
/// into the registry. The input `defs` slice and its strings may be freed by the
/// caller after this returns.
pub fn registerFrontmatter(gpa: std.mem.Allocator, kind: FrontmatterKind, defs: []const HookDef) !void {
    for (defs) |def| {
        var remapped = def;
        remapped.event = remapFrontmatterEvent(kind, def.event);
        try instance.add(gpa, remapped);
    }
}

/// Drop the process-global registry. Same install-once discipline as `rt.io`;
/// tests reset between cases so a leftover def cannot bleed across tests.
pub fn resetForTest() void {
    instance.clearSession();
}

const testing = std.testing;

test "session_hooks: add then all returns the registered def" {
    instance.clearSession();
    defer instance.clearSession();

    const def: HookDef = .{
        .event = .pre_tool_use,
        .matcher = "*",
        .hook_type = .command,
        .body = "echo SESSION_HOOK",
    };
    try instance.add(testing.allocator, def);

    const all = instance.all();
    try testing.expectEqual(@as(usize, 1), all.len);
    try testing.expectEqual(hook_event.Event.pre_tool_use, all[0].event);
    try testing.expectEqualStrings("echo SESSION_HOOK", all[0].body);
    try testing.expectEqualStrings("*", all[0].matcher);
}

test "session_hooks: stored def owns its strings (caller buffer can change)" {
    instance.clearSession();
    defer instance.clearSession();

    // Register from a mutable buffer, then scribble over it. The stored def must
    // not observe the change (proves the strings were deep-copied).
    var body_buf = [_]u8{ 'h', 'i' };
    const def: HookDef = .{
        .event = .stop,
        .hook_type = .command,
        .body = &body_buf,
    };
    try instance.add(testing.allocator, def);
    body_buf[0] = 'X';

    const all = instance.all();
    try testing.expectEqual(@as(usize, 1), all.len);
    try testing.expectEqualStrings("hi", all[0].body);
}

test "session_hooks: list filters by event" {
    instance.clearSession();
    defer instance.clearSession();

    try instance.add(testing.allocator, .{ .event = .pre_tool_use, .hook_type = .command, .body = "a" });
    try instance.add(testing.allocator, .{ .event = .stop, .hook_type = .command, .body = "b" });
    try instance.add(testing.allocator, .{ .event = .pre_tool_use, .hook_type = .command, .body = "c" });

    const pre = try instance.list(testing.allocator, .pre_tool_use);
    defer testing.allocator.free(pre);
    try testing.expectEqual(@as(usize, 2), pre.len);

    const stop = try instance.list(testing.allocator, .stop);
    defer testing.allocator.free(stop);
    try testing.expectEqual(@as(usize, 1), stop.len);
    try testing.expectEqualStrings("b", stop[0].body);
}

test "session_hooks: clearSession empties the registry" {
    instance.clearSession();
    defer instance.clearSession();

    try instance.add(testing.allocator, .{ .event = .pre_tool_use, .hook_type = .command, .body = "x" });
    try testing.expectEqual(@as(usize, 1), instance.all().len);
    instance.clearSession();
    try testing.expectEqual(@as(usize, 0), instance.all().len);
}

test "session_hooks: agent frontmatter Stop hook registers as SubagentStop" {
    instance.clearSession();
    defer instance.clearSession();

    // An agent frontmatter `Stop` hook must be remapped to `SubagentStop` so it
    // fires on the sub-agent's stop, not the top-level Stop (reference:
    // registerFrontmatterHooks.ts).
    const defs = [_]HookDef{
        .{ .event = .stop, .hook_type = .command, .body = "echo AGENT_STOP" },
        .{ .event = .pre_tool_use, .hook_type = .command, .body = "echo AGENT_PRE" },
    };
    try registerFrontmatter(testing.allocator, .agent, &defs);

    const all = instance.all();
    try testing.expectEqual(@as(usize, 2), all.len);

    // The Stop def became SubagentStop; the PreToolUse def is unchanged.
    var saw_subagent_stop = false;
    var saw_pre = false;
    for (all) |d| {
        if (d.event == .subagent_stop) saw_subagent_stop = true;
        if (d.event == .pre_tool_use) saw_pre = true;
        // No def should still carry the literal Stop event for an agent.
        try testing.expect(d.event != .stop);
    }
    try testing.expect(saw_subagent_stop);
    try testing.expect(saw_pre);
}

test "session_hooks: skill frontmatter Stop hook is NOT remapped" {
    instance.clearSession();
    defer instance.clearSession();

    const defs = [_]HookDef{
        .{ .event = .stop, .hook_type = .command, .body = "echo SKILL_STOP" },
    };
    try registerFrontmatter(testing.allocator, .skill, &defs);

    const all = instance.all();
    try testing.expectEqual(@as(usize, 1), all.len);
    // Skills register verbatim; Stop stays Stop.
    try testing.expectEqual(hook_event.Event.stop, all[0].event);
}

test "session_hooks: markCount + restoreCount bound a scoped batch (skills-11)" {
    instance.clearSession();
    defer instance.clearSession();

    // A pre-existing session hook that must survive a scoped rollback.
    try instance.add(testing.allocator, .{ .event = .pre_tool_use, .hook_type = .command, .body = "base" });
    const mark = instance.markCount();
    try testing.expectEqual(@as(usize, 1), mark);

    // A forked skill registers two hooks for its bounded lifetime.
    try registerFrontmatter(testing.allocator, .skill, &[_]HookDef{
        .{ .event = .pre_tool_use, .hook_type = .command, .body = "skillA" },
        .{ .event = .stop, .hook_type = .command, .body = "skillB" },
    });
    try testing.expectEqual(@as(usize, 3), instance.all().len);

    // Rolling back to the mark drops the skill's hooks but keeps the base hook.
    instance.restoreCount(mark);
    const after = instance.all();
    try testing.expectEqual(@as(usize, 1), after.len);
    try testing.expectEqualStrings("base", after[0].body);

    // A mark past the current length is a no-op (does not grow the list).
    instance.restoreCount(99);
    try testing.expectEqual(@as(usize, 1), instance.all().len);
}

test "remapFrontmatterEvent: agent Stop -> SubagentStop, others passthrough" {
    try testing.expectEqual(hook_event.Event.subagent_stop, remapFrontmatterEvent(.agent, .stop));
    try testing.expectEqual(hook_event.Event.pre_tool_use, remapFrontmatterEvent(.agent, .pre_tool_use));
    try testing.expectEqual(hook_event.Event.stop, remapFrontmatterEvent(.skill, .stop));
}
