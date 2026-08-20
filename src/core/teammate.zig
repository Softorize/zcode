//! Task 13 (swarm-tasks-13): in-process teammate lifecycle.
//!
//! A teammate is an agent the swarm leader runs *in-process* (a background
//! thread) rather than as a detached process. Unlike a fire-and-forget
//! sub-agent, a teammate is addressable and steerable for the life of the
//! session: the leader can inject new user messages into its turn, observe
//! whether it is idle or busy, read a capped window of its recent
//! conversation, and ask it to stop gracefully.
//!
//! This module owns only the pure, testable lifecycle mechanics:
//!   - an idle/active state machine,
//!   - a FIFO pending-message queue (injected by SendMessage, drained by the
//!     run loop at a tool-round boundary),
//!   - a capped conversation transcript (a ring that evicts the oldest entry),
//!   - a `name@team` identity used to stamp `owner`/`from` strings,
//!   - an abort flag set by a shutdown request and observed by the run loop's
//!     should-stop predicate at the next safe (round-boundary) point.
//!
//! Mirrors the reference (InProcessTeammateTask.tsx:1-100):
//!   - requestTeammateShutdown      -> requestShutdown (sets abort)
//!   - appendTeammateMessage        -> appendMessage  (capped transcript)
//!   - injectUserMessageToTeammate  -> injectUserMessage (enqueue)
//!   - isActive / state             -> isActive / state
//!
//! The side effects (running handlePrompt, the actual thread, draining the
//! inbox into a turn, killing child processes) live in agent_runtime.zig,
//! which consumes this struct. The abort flag is checked at a round boundary,
//! never mid-tool, so a stop never leaks a child process (CLAUDE.md: do not
//! wait() after kill).
//!
//! Concurrency. The injecting thread (a SendMessage call) and the consuming
//! run loop both touch the queue and the state, so every public method locks
//! an internal mutex. The abort flag is a separate atomic so the run loop can
//! poll it without taking the lock on every round. `deinit` must run after
//! all threads touching the teammate have joined.

const std = @import("std");
const rt = @import("zcode_runtime");
const CircularBuffer = @import("circular_buffer.zig").CircularBuffer;

/// Default cap on the in-memory transcript window. Older entries are evicted
/// once this many accumulate (mirrors the reference's bounded teammate
/// transcript so a long-running teammate does not grow without bound).
pub const default_transcript_cap: usize = 200;

/// Where a transcript entry came from. `user` entries are messages injected
/// into the teammate (from the leader / SendMessage); `assistant` entries are
/// the teammate's own replies; `system` covers protocol notices.
pub const Role = enum { user, assistant, system };

/// One line of the teammate's conversation. `text` is an owned copy; the ring
/// hands it back on eviction so we can free it.
pub const TranscriptEntry = struct {
    role: Role,
    text: []u8,
};

/// Lifecycle state of the teammate's run loop. `idle` = waiting for work,
/// `active` = currently inside a `handlePrompt` turn.
pub const State = enum { idle, active };

/// In-process teammate. Construct with `init`; always pair with `deinit`
/// after every thread touching it has joined.
pub const Teammate = struct {
    allocator: std.mem.Allocator,
    /// Team-addressable name (the registry key, e.g. "worker"). Owned.
    name: []u8,
    /// Team this teammate belongs to (e.g. "alpha"). Owned.
    team: []u8,
    /// idle <-> active, guarded by `mutex`.
    state: State = .idle,
    /// FIFO of injected user messages awaiting the next round drain. Each
    /// entry is an owned text copy.
    pending: std.ArrayListUnmanaged([]u8) = .empty,
    /// Capped conversation window. Entries are owned; eviction frees them.
    transcript: CircularBuffer(TranscriptEntry),
    /// Set by `requestShutdown`; polled by `shouldStop`. Separate atomic so
    /// the run loop can poll without taking `mutex` every round.
    abort: std.atomic.Value(bool) = .init(false),
    mutex: std.Io.Mutex = .init,

    /// Allocate a teammate bound to `name`/`team` with a transcript capped at
    /// `transcript_cap` entries (pass `default_transcript_cap` for the
    /// default). Both name and team are copied.
    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        team: []const u8,
        transcript_cap: usize,
    ) !Teammate {
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        const team_copy = try allocator.dupe(u8, team);
        errdefer allocator.free(team_copy);
        const ring = try CircularBuffer(TranscriptEntry).init(allocator, transcript_cap);
        return .{
            .allocator = allocator,
            .name = name_copy,
            .team = team_copy,
            .transcript = ring,
        };
    }

    /// Free the name, team, every pending message, and every transcript entry.
    /// Must run after all threads touching this teammate have joined.
    pub fn deinit(self: *Teammate) void {
        self.mutex.lock(rt.io) catch {};
        // No unlock: the teammate is being torn down.
        for (self.pending.items) |t| self.allocator.free(t);
        self.pending.deinit(self.allocator);

        // Drain owned transcript entries before freeing the ring storage
        // (the ring does not free items on its own).
        const entries = self.transcript.toArray(self.allocator) catch &[_]TranscriptEntry{};
        for (entries) |e| self.allocator.free(e.text);
        if (entries.len > 0) self.allocator.free(entries);
        self.transcript.deinit();

        self.allocator.free(self.name);
        self.allocator.free(self.team);
    }

    /// Format the teammate identity as `name@team`. Caller owns the result.
    /// Used to stamp `owner`/`from` strings on tasks and messages.
    pub fn identityAlloc(self: *Teammate, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}@{s}", .{ self.name, self.team });
    }

    /// Enqueue an injected user message for delivery at the next round
    /// boundary. The text is copied. Mirrors `injectUserMessageToTeammate`.
    pub fn injectUserMessage(self: *Teammate, text: []const u8) !void {
        const copy = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(copy);
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        try self.pending.append(self.allocator, copy);
    }

    /// True if there is at least one injected message awaiting drain.
    pub fn hasPending(self: *Teammate) bool {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        return self.pending.items.len > 0;
    }

    /// Remove and return every pending message in FIFO order, leaving the
    /// queue empty. Returns an owned slice of owned text copies; free each
    /// element and the slice with `freeDrained`. Returns an empty slice when
    /// nothing is queued. The run loop calls this at a tool-round boundary and
    /// injects the messages as new user turns.
    pub fn drainPending(self: *Teammate, allocator: std.mem.Allocator) ![][]u8 {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        if (self.pending.items.len == 0) return allocator.alloc([]u8, 0);

        const out = try allocator.alloc([]u8, self.pending.items.len);
        errdefer allocator.free(out);
        for (self.pending.items, 0..) |t, i| out[i] = t; // transfer ownership
        // Clear without freeing: the texts are now owned by `out`.
        self.pending.clearRetainingCapacity();
        return out;
    }

    /// Free a slice returned by `drainPending`.
    pub fn freeDrained(allocator: std.mem.Allocator, messages: [][]u8) void {
        for (messages) |m| allocator.free(m);
        allocator.free(messages);
    }

    /// Append a line to the capped transcript. The text is copied; if the
    /// ring is full the oldest entry is evicted and freed here. Mirrors
    /// `appendTeammateMessage`.
    pub fn appendMessage(self: *Teammate, role: Role, text: []const u8) !void {
        const copy = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(copy);
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        if (self.transcript.add(.{ .role = role, .text = copy })) |evicted| {
            self.allocator.free(evicted.text);
        }
    }

    /// Number of entries currently in the transcript window.
    pub fn transcriptLen(self: *Teammate) usize {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        return self.transcript.length();
    }

    /// Snapshot the transcript window oldest-first. Returns owned copies of
    /// each entry's text in a freshly allocated slice; free with
    /// `freeTranscript`. The run loop uses this to seed a resume / summary.
    pub fn snapshotTranscript(self: *Teammate, allocator: std.mem.Allocator) ![]TranscriptEntry {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        const raw = try self.transcript.toArray(allocator);
        errdefer allocator.free(raw);
        // The ring returns shallow copies that alias the owned texts. Deep-copy
        // so the snapshot survives a concurrent eviction.
        var made: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < made) : (i += 1) allocator.free(raw[i].text);
        }
        for (raw, 0..) |e, i| {
            raw[i].text = try allocator.dupe(u8, e.text);
            made = i + 1;
        }
        return raw;
    }

    /// Free a slice returned by `snapshotTranscript`.
    pub fn freeTranscript(allocator: std.mem.Allocator, entries: []TranscriptEntry) void {
        for (entries) |e| allocator.free(e.text);
        allocator.free(entries);
    }

    /// Transition into the active state (the run loop is inside a turn).
    pub fn setActive(self: *Teammate) void {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        self.state = .active;
    }

    /// Transition back to idle (the turn finished, waiting for work).
    pub fn setIdle(self: *Teammate) void {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        self.state = .idle;
    }

    /// Current lifecycle state.
    pub fn currentState(self: *Teammate) State {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        return self.state;
    }

    /// True while the teammate is mid-turn. Mirrors the reference
    /// `TeammateExecutor.isActive`.
    pub fn isActive(self: *Teammate) bool {
        return self.currentState() == .active;
    }

    /// Ask the teammate to stop gracefully. Sets the abort flag; the run loop
    /// observes it at the next round boundary via `shouldStop` and exits
    /// cleanly (no hard mid-tool kill). Mirrors `requestTeammateShutdown`.
    pub fn requestShutdown(self: *Teammate) void {
        self.abort.store(true, .seq_cst);
    }

    /// The run loop's "should I stop now?" predicate. True once a shutdown has
    /// been requested. Polled at round boundaries; lock-free.
    pub fn shouldStop(self: *Teammate) bool {
        return self.abort.load(.seq_cst);
    }
};

// -- process-global live-teammate registry -----------------------------------
//
// SendMessage runs on the leader's main loop, but the teammate it wants to
// shut down is owned by a background run loop. To reach it without threading a
// runtime pointer through the tools layer, live teammates register themselves
// here by name while their run loop is active and unregister on exit. The team
// tool's `shutdown_response.approve` handler looks the teammate up here and
// flips its abort flag. Guarded by a mutex because the registering thread (the
// teammate's run loop) and the signalling thread (the leader's SendMessage)
// race. Only borrowed pointers are stored; the registry never owns or frees a
// Teammate.

var live_mutex: std.Io.Mutex = .init;
var live: std.StringHashMapUnmanaged(*Teammate) = .{};

/// Register a live teammate under its name so `requestShutdownByName` can reach
/// it. The run loop calls this when it starts and `unregisterLive` when it
/// exits. The key is borrowed from `tm.name` (valid until `tm` is deinited,
/// which the run loop only does after unregistering).
pub fn registerLive(tm: *Teammate) void {
    live_mutex.lock(rt.io) catch {};
    defer live_mutex.unlock(rt.io);
    live.put(rt.gpa, tm.name, tm) catch {};
}

/// Drop a teammate from the live registry (called as the run loop exits,
/// before `deinit`). Idempotent.
pub fn unregisterLive(tm: *Teammate) void {
    live_mutex.lock(rt.io) catch {};
    defer live_mutex.unlock(rt.io);
    _ = live.remove(tm.name);
}

/// Flip the abort flag on the live teammate named `name`, if one is
/// registered. Returns true when a teammate was found and signalled. Used by
/// the SendMessage `shutdown_response.approve` handler.
pub fn requestShutdownByName(name: []const u8) bool {
    live_mutex.lock(rt.io) catch {};
    defer live_mutex.unlock(rt.io);
    if (live.get(name)) |tm| {
        tm.requestShutdown();
        return true;
    }
    return false;
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

test "new teammate starts idle and reports its name@team identity" {
    const alloc = testing.allocator;
    var tm = try Teammate.init(alloc, "worker", "alpha", default_transcript_cap);
    defer tm.deinit();

    try testing.expectEqual(State.idle, tm.currentState());
    try testing.expect(!tm.isActive());

    const id = try tm.identityAlloc(alloc);
    defer alloc.free(id);
    try testing.expectEqualStrings("worker@alpha", id);
}

test "injectUserMessage enqueues, drain empties, queue independent of order" {
    const alloc = testing.allocator;
    var tm = try Teammate.init(alloc, "worker", "alpha", default_transcript_cap);
    defer tm.deinit();

    try testing.expect(!tm.hasPending());
    try tm.injectUserMessage("first");
    try tm.injectUserMessage("second");
    try testing.expect(tm.hasPending());

    const drained = try tm.drainPending(alloc);
    defer Teammate.freeDrained(alloc, drained);
    try testing.expectEqual(@as(usize, 2), drained.len);
    try testing.expectEqualStrings("first", drained[0]);
    try testing.expectEqualStrings("second", drained[1]);

    // Empty after drain.
    try testing.expect(!tm.hasPending());
    const again = try tm.drainPending(alloc);
    defer Teammate.freeDrained(alloc, again);
    try testing.expectEqual(@as(usize, 0), again.len);
}

test "state transitions idle -> active -> idle" {
    const alloc = testing.allocator;
    var tm = try Teammate.init(alloc, "worker", "alpha", default_transcript_cap);
    defer tm.deinit();

    try testing.expectEqual(State.idle, tm.currentState());
    tm.setActive();
    try testing.expectEqual(State.active, tm.currentState());
    try testing.expect(tm.isActive());
    tm.setIdle();
    try testing.expectEqual(State.idle, tm.currentState());
    try testing.expect(!tm.isActive());
}

test "capped transcript drops oldest beyond the cap" {
    const alloc = testing.allocator;
    // Cap of 3: the 4th and 5th adds evict the two oldest.
    var tm = try Teammate.init(alloc, "worker", "alpha", 3);
    defer tm.deinit();

    try tm.appendMessage(.user, "m1");
    try tm.appendMessage(.assistant, "m2");
    try tm.appendMessage(.user, "m3");
    try testing.expectEqual(@as(usize, 3), tm.transcriptLen());

    try tm.appendMessage(.assistant, "m4");
    try tm.appendMessage(.user, "m5");
    // Still capped at 3.
    try testing.expectEqual(@as(usize, 3), tm.transcriptLen());

    // The surviving window is the three newest, oldest-first.
    const snap = try tm.snapshotTranscript(alloc);
    defer Teammate.freeTranscript(alloc, snap);
    try testing.expectEqual(@as(usize, 3), snap.len);
    try testing.expectEqualStrings("m3", snap[0].text);
    try testing.expectEqualStrings("m4", snap[1].text);
    try testing.expectEqualStrings("m5", snap[2].text);
    try testing.expectEqual(Role.user, snap[0].role);
    try testing.expectEqual(Role.assistant, snap[1].role);
    try testing.expectEqual(Role.user, snap[2].role);
}

test "requestShutdown is observable and the run loop should-stop predicate fires" {
    const alloc = testing.allocator;
    var tm = try Teammate.init(alloc, "worker", "alpha", default_transcript_cap);
    defer tm.deinit();

    try testing.expect(!tm.shouldStop());
    tm.requestShutdown();
    try testing.expect(tm.shouldStop());
    // Idempotent: a second request keeps it set.
    tm.requestShutdown();
    try testing.expect(tm.shouldStop());
}

test "live registry routes requestShutdownByName to the matching teammate" {
    const alloc = testing.allocator;
    var tm = try Teammate.init(alloc, "shutdown-target", "alpha", default_transcript_cap);
    defer tm.deinit();

    registerLive(&tm);
    defer unregisterLive(&tm);

    // An unknown name is not signalled, and the target is untouched.
    try testing.expect(!requestShutdownByName("ghost"));
    try testing.expect(!tm.shouldStop());

    // The registered name flips its abort flag.
    try testing.expect(requestShutdownByName("shutdown-target"));
    try testing.expect(tm.shouldStop());

    // After unregister the name no longer resolves.
    unregisterLive(&tm);
    try testing.expect(!requestShutdownByName("shutdown-target"));
}

test "snapshotTranscript survives a concurrent eviction (deep-copied)" {
    const alloc = testing.allocator;
    var tm = try Teammate.init(alloc, "worker", "alpha", 2);
    defer tm.deinit();

    try tm.appendMessage(.user, "a");
    try tm.appendMessage(.user, "b");
    const snap = try tm.snapshotTranscript(alloc);
    defer Teammate.freeTranscript(alloc, snap);

    // Push more so the snapshotted entries would be evicted in the ring.
    try tm.appendMessage(.user, "c");
    try tm.appendMessage(.user, "d");

    // The snapshot still holds its own copies.
    try testing.expectEqual(@as(usize, 2), snap.len);
    try testing.expectEqualStrings("a", snap[0].text);
    try testing.expectEqualStrings("b", snap[1].text);
}
