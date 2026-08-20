//! Task 10 (swarm-tasks-10): addressable named agents + queued messages.
//!
//! A spawned background agent can be given a team-addressable `name`
//! (distinct from its specialist `agent` type). SendMessage(to=name) then
//! resolves that name to the running agent's `task_id` so the message reaches
//! it. While the agent is running, a message addressed to it is queued here
//! and drained at the agent's next tool-round boundary and injected as a new
//! user turn (the auto-delivery hook lives in agent_runtime.zig). When the
//! agent has finished, the caller resumes it from its transcript instead
//! (resume-from-transcript also lives in agent_runtime.zig).
//!
//! Mirrors the reference (SendMessageTool.ts:800-873):
//!   - agentNameRegistry lookup  -> register / lookup
//!   - queuePendingMessage       -> queuePendingMessage
//!   - drain at round boundary   -> drainPending
//!
//! This module owns only the pure, testable registry + queue mechanics. The
//! resume-from-transcript side effect (re-running a stopped agent with a new
//! prompt) and the per-round drain injection are wired by the runtime, which
//! holds the live transcript/session store and the background-spawn machinery.
//!
//! A process-global instance guarded by a mutex: background spawn threads and
//! the main agent loop both touch the registry/queue, mirroring the
//! `background_threads_lock` discipline already used in agent_runtime.zig.

const std = @import("std");
const rt = @import("zcode_runtime");

/// One queued message awaiting delivery to a named agent. `text` is an owned
/// copy (the SendMessage call that queued it does not outlive the turn), freed
/// when the message is drained or the registry is cleared.
pub const PendingMessage = struct {
    text: []u8,
};

/// Name -> task_id registry plus a per-name FIFO message queue. Construct with
/// `.{}` (or `init`); always pair with `deinit` to free the owned copies.
///
/// All public methods lock the mutex internally, so the registry is safe to
/// share between the spawn threads and the main loop. The exception is
/// `deinit`, which must run after all threads have joined (the runtime joins
/// its background threads in its own `deinit` before tearing the registry
/// down).
pub const Registry = struct {
    mutex: std.Io.Mutex = .init,
    /// name -> task_id. Both key and value are owned copies.
    names: std.StringHashMapUnmanaged([]u8) = .{},
    /// name -> queued messages (FIFO). The key is an owned copy; each message
    /// owns its `text`.
    queues: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(PendingMessage)) = .{},

    pub fn init() Registry {
        return .{};
    }

    /// Bind `name` to `task_id`. A re-register for the same name replaces the
    /// previous task_id (the agent was respawned/resumed under the same name).
    /// Both strings are copied; the caller keeps ownership of its inputs.
    pub fn register(self: *Registry, allocator: std.mem.Allocator, name: []const u8, task_id: []const u8) !void {
        const task_copy = try allocator.dupe(u8, task_id);
        errdefer allocator.free(task_copy);

        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);

        if (self.names.getEntry(name)) |entry| {
            // Reuse the existing key; swap the value.
            allocator.free(entry.value_ptr.*);
            entry.value_ptr.* = task_copy;
            return;
        }

        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        try self.names.put(allocator, name_copy, task_copy);
    }

    /// Resolve a name to its task_id, or null if the name is not registered.
    /// The returned slice is borrowed from the registry; copy it before any
    /// concurrent re-register if the caller needs to hold it past the lock.
    pub fn lookup(self: *Registry, name: []const u8) ?[]const u8 {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        return self.names.get(name);
    }

    /// True if `name` has at least one queued message awaiting delivery.
    pub fn hasPending(self: *Registry, name: []const u8) bool {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        if (self.queues.get(name)) |q| return q.items.len > 0;
        return false;
    }

    /// Append a message to the named agent's FIFO queue. The text is copied; a
    /// new queue (and key copy) is created on first message for a name. It is
    /// fine to queue for a name that is not (yet) in `names`: the resume path
    /// looks the name up separately.
    pub fn queuePendingMessage(self: *Registry, allocator: std.mem.Allocator, name: []const u8, text: []const u8) !void {
        const text_copy = try allocator.dupe(u8, text);
        errdefer allocator.free(text_copy);

        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);

        if (self.queues.getEntry(name)) |entry| {
            try entry.value_ptr.append(allocator, .{ .text = text_copy });
            return;
        }

        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        var q: std.ArrayListUnmanaged(PendingMessage) = .empty;
        errdefer q.deinit(allocator);
        try q.append(allocator, .{ .text = text_copy });
        try self.queues.put(allocator, name_copy, q);
    }

    /// Remove and return every queued message for `name` in FIFO order,
    /// leaving the queue empty. Returns an owned slice of owned text copies;
    /// the caller frees each `text` and the slice via `freePending`. Returns an
    /// empty slice when there is nothing queued.
    pub fn drainPending(self: *Registry, allocator: std.mem.Allocator, name: []const u8) ![][]u8 {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);

        const entry = self.queues.getEntry(name) orelse return allocator.alloc([]u8, 0);
        const q = entry.value_ptr;
        if (q.items.len == 0) return allocator.alloc([]u8, 0);

        var out = try allocator.alloc([]u8, q.items.len);
        errdefer allocator.free(out);
        for (q.items, 0..) |msg, i| {
            out[i] = msg.text; // transfer ownership of the text to the caller
        }
        // The texts are now owned by `out`; clear the queue without freeing them.
        q.clearRetainingCapacity();
        return out;
    }

    /// Free a slice returned by `drainPending`.
    pub fn freePending(allocator: std.mem.Allocator, messages: [][]u8) void {
        for (messages) |m| allocator.free(m);
        allocator.free(messages);
    }

    /// Number of registered names (observability/test aid).
    pub fn nameCount(self: *Registry) usize {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        return self.names.count();
    }

    /// Free every owned key/value and queued message. Must run after all
    /// threads touching the registry have joined.
    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        self.mutex.lock(rt.io) catch {};
        // No unlock: the registry is being torn down.

        var nit = self.names.iterator();
        while (nit.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.names.deinit(allocator);

        var qit = self.queues.iterator();
        while (qit.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |msg| allocator.free(msg.text);
            entry.value_ptr.deinit(allocator);
        }
        self.queues.deinit(allocator);
    }
};

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "register then lookup resolves a name to its task_id" {
    const alloc = testing.allocator;
    var reg: Registry = .{};
    defer reg.deinit(alloc);

    try reg.register(alloc, "worker", "task-5");
    const got = reg.lookup("worker") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("task-5", got);
    try testing.expect(reg.lookup("ghost") == null);
    try testing.expectEqual(@as(usize, 1), reg.nameCount());
}

test "re-register replaces the task_id for the same name" {
    const alloc = testing.allocator;
    var reg: Registry = .{};
    defer reg.deinit(alloc);

    try reg.register(alloc, "worker", "task-5");
    try reg.register(alloc, "worker", "task-9");
    const got = reg.lookup("worker") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("task-9", got);
    try testing.expectEqual(@as(usize, 1), reg.nameCount());
}

test "queue two messages then drain returns both in order and empties the queue" {
    const alloc = testing.allocator;
    var reg: Registry = .{};
    defer reg.deinit(alloc);

    try testing.expect(!reg.hasPending("worker"));
    try reg.queuePendingMessage(alloc, "worker", "first");
    try reg.queuePendingMessage(alloc, "worker", "second");
    try testing.expect(reg.hasPending("worker"));

    const drained = try reg.drainPending(alloc, "worker");
    defer Registry.freePending(alloc, drained);
    try testing.expectEqual(@as(usize, 2), drained.len);
    try testing.expectEqualStrings("first", drained[0]);
    try testing.expectEqualStrings("second", drained[1]);

    // Queue is empty after draining.
    try testing.expect(!reg.hasPending("worker"));
    const again = try reg.drainPending(alloc, "worker");
    defer Registry.freePending(alloc, again);
    try testing.expectEqual(@as(usize, 0), again.len);
}

test "drainPending for an unknown name returns an empty slice" {
    const alloc = testing.allocator;
    var reg: Registry = .{};
    defer reg.deinit(alloc);

    const drained = try reg.drainPending(alloc, "nobody");
    defer Registry.freePending(alloc, drained);
    try testing.expectEqual(@as(usize, 0), drained.len);
}

test "queues for distinct names stay independent" {
    const alloc = testing.allocator;
    var reg: Registry = .{};
    defer reg.deinit(alloc);

    try reg.queuePendingMessage(alloc, "alice", "a1");
    try reg.queuePendingMessage(alloc, "bob", "b1");
    try reg.queuePendingMessage(alloc, "alice", "a2");

    const da = try reg.drainPending(alloc, "alice");
    defer Registry.freePending(alloc, da);
    try testing.expectEqual(@as(usize, 2), da.len);
    try testing.expectEqualStrings("a1", da[0]);
    try testing.expectEqualStrings("a2", da[1]);

    const db = try reg.drainPending(alloc, "bob");
    defer Registry.freePending(alloc, db);
    try testing.expectEqual(@as(usize, 1), db.len);
    try testing.expectEqualStrings("b1", db[0]);
}
