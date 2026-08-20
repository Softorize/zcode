//! Task 12 (hooks-06): pending registry for background (`async` / `asyncRewake`)
//! hooks. An async hook is spawned and registered here instead of being awaited
//! inline, so the turn is never blocked on it. The agent loop later polls
//! `checkResponses` at turn boundaries to drain any that have finished, and
//! `finalizeAll` at session end to flush the rest.
//!
//! Mirrors the reference `AsyncHookRegistry` (AsyncHookRegistry.ts:30/113/281):
//!   - registerPendingAsyncHook  -> register
//!   - checkForAsyncHookResponses -> checkResponses
//!   - finalizePendingAsyncHooks  -> finalizeAll
//!
//! `asyncRewake` hooks wake the model on exit code 2 (the reference's rewake
//! contract): a finalized rewake hook that exited 2 surfaces `.rewake == true`
//! with its parsed reason so the caller can inject a continuation.
//!
//! A process-global instance guarded by a mutex, since a background spawn may
//! complete on another thread and `checkResponses` runs on the main loop.

const std = @import("std");
const rt = @import("zcode_runtime");
const clock = @import("clock.zig");
const hook_io = @import("hook_io.zig");
const hook_event = @import("hook_event.zig");

/// One in-flight background hook. `command` and `event_name` are owned copies
/// (the def that spawned it does not outlive the turn), freed when the entry is
/// drained. `child` carries the live OS handle + stdout pipe.
pub const PendingAsyncHook = struct {
    id: u64,
    child: std.process.Child,
    event: hook_event.Event,
    /// async_rewake: this hook wakes the model on exit code 2.
    rewake: bool,
    command: []u8,
    start_ns: i128,
    /// 0 means "no explicit timeout"; the registry leaves enforcement to the
    /// caller's poll cadence and the per-child default.
    timeout_ns: u64,
    response_sent: bool = false,
    /// Bytes read from stdout by `childLikelyDone`'s probe before the child
    /// finished. Prepended by `drainStdout` so a partial read is never lost.
    /// Backed by `global_alloc`; freed alongside `command`.
    prefetched: std.ArrayList(u8) = .empty,
};

/// A finalized background hook's parsed outcome, handed back from
/// `checkResponses` / `finalizeAll`. Owned slices are freed by `deinit`.
pub const AsyncResponse = struct {
    id: u64,
    event: hook_event.Event,
    exit_code: u8,
    /// True when this was an `asyncRewake` hook that exited 2 (wake the model).
    rewake: bool,
    /// `hookSpecificOutput.additionalContext` from the hook's first sync JSON
    /// line, if any. Injected into the next turn by the caller.
    additional_context: ?[]u8 = null,
    /// A reason/stopReason the hook supplied (used for the rewake continuation).
    reason: ?[]u8 = null,

    pub fn deinit(self: *AsyncResponse, allocator: std.mem.Allocator) void {
        if (self.additional_context) |v| allocator.free(v);
        if (self.reason) |v| allocator.free(v);
    }
};

pub fn freeResponses(allocator: std.mem.Allocator, responses: []AsyncResponse) void {
    for (responses) |*r| r.deinit(allocator);
    allocator.free(responses);
}

/// Process-global pending registry. A single instance is fine: background hooks
/// are session-scoped and there is one agent loop.
pub const Registry = struct {
    mutex: std.Io.Mutex = .init,
    pending: std.ArrayList(PendingAsyncHook) = .empty,
    next_id: u64 = 1,

    /// Take ownership of a spawned child and track it. `command` and the event
    /// are copied so the caller's def can be freed immediately. Returns the
    /// assigned id (so a caller could correlate, though most callers ignore it).
    /// On OOM the child is killed (we cannot track it, so do not leak the OS
    /// process) and the error is propagated.
    pub fn register(
        self: *Registry,
        allocator: std.mem.Allocator,
        child: std.process.Child,
        event: hook_event.Event,
        rewake: bool,
        command: []const u8,
        timeout_ns: u64,
    ) !u64 {
        const cmd_copy = try allocator.dupe(u8, command);
        errdefer allocator.free(cmd_copy);

        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);

        const id = self.next_id;
        self.next_id += 1;
        try self.pending.append(allocator, .{
            .id = id,
            .child = child,
            .event = event,
            .rewake = rewake,
            .command = cmd_copy,
            .start_ns = clock.nowNanos(),
            .timeout_ns = timeout_ns,
        });
        return id;
    }

    /// Number of hooks still in flight (test/observability aid).
    pub fn count(self: *Registry) usize {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        return self.pending.items.len;
    }

    /// Drain every finished background hook and return their parsed outcomes,
    /// removing them from the registry. A child that has not yet exited is left
    /// in place (its stdout pipe is still open). The acceptance contract: after
    /// the spawned child has terminated, one `checkResponses` call yields its
    /// response and empties the registry.
    ///
    /// "Finished" is detected by draining stdout to EOF: a child closes its
    /// stdout end on exit, so a `readStreaming` returning 0 means the writer is
    /// gone. We only `wait()` (which blocks) once EOF is observed, so a still-
    /// running child does not stall the poll. CLAUDE.md: pipes use
    /// `readStreaming` (pread is ESPIPE on pipes) and offsets are not tracked
    /// here because each `readStreaming` advances the stream.
    pub fn checkResponses(self: *Registry, allocator: std.mem.Allocator) ![]AsyncResponse {
        return self.collect(allocator, false);
    }

    /// Flush every remaining background hook at session end, blocking on each
    /// until it finishes (the session is ending, so a short block is fine).
    /// Same parse/return contract as `checkResponses`; the registry is emptied.
    pub fn finalizeAll(self: *Registry, allocator: std.mem.Allocator) ![]AsyncResponse {
        return self.collect(allocator, true);
    }

    /// Kill and drop any remaining background hooks without parsing their
    /// output. Used on a hard reset; CLAUDE.md: `kill` reaps internally, so do
    /// NOT `wait()` after.
    pub fn clear(self: *Registry, allocator: std.mem.Allocator) void {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        for (self.pending.items) |*p| {
            if (p.child.stdin) |f| {
                f.close(rt.io);
                p.child.stdin = null;
            }
            if (p.child.stdout) |f| {
                f.close(rt.io);
                p.child.stdout = null;
            }
            if (p.child.id != null) p.child.kill(rt.io);
            allocator.free(p.command);
            p.prefetched.deinit(allocator);
        }
        self.pending.clearAndFree(allocator);
    }

    fn collect(self: *Registry, allocator: std.mem.Allocator, block_until_done: bool) ![]AsyncResponse {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);

        var out: std.ArrayList(AsyncResponse) = .empty;
        errdefer {
            for (out.items) |*r| r.deinit(allocator);
            out.deinit(allocator);
        }

        var i: usize = 0;
        while (i < self.pending.items.len) {
            var p = &self.pending.items[i];

            // Drain stdout. On a non-blocking poll, a still-open pipe with no
            // data would otherwise make readStreaming block; we only commit to
            // draining-to-completion when block_until_done is set or the child's
            // writer end has already closed (which `childLikelyDone` detects via
            // a zero-length read).
            if (!block_until_done and !childLikelyDone(allocator, p)) {
                i += 1;
                continue;
            }

            const drained = drainStdout(allocator, p) catch null;
            defer if (drained) |d| allocator.free(d);

            // Reap the child. wait() is safe now: stdout reached EOF, so the
            // process has closed its descriptors / is exiting.
            const term: std.process.Child.Term = if (p.child.id != null)
                (p.child.wait(rt.io) catch std.process.Child.Term{ .unknown = 1 })
            else
                std.process.Child.Term{ .exited = 0 };

            const exit_code: u8 = switch (term) {
                .exited => |c| c,
                else => 1,
            };

            const response = buildResponse(allocator, p, drained, exit_code) catch AsyncResponse{
                .id = p.id,
                .event = p.event,
                .exit_code = exit_code,
                .rewake = p.rewake and exit_code == 2,
            };
            try out.append(allocator, response);

            allocator.free(p.command);
            p.prefetched.deinit(allocator);
            _ = self.pending.orderedRemove(i);
            // Do not advance i: the next item shifted into this slot.
        }

        return out.toOwnedSlice(allocator);
    }

    /// Heuristic for "the child has finished" without a non-blocking waitpid
    /// (the Io abstraction does not expose WNOHANG). We attempt a single
    /// `readStreaming`; a zero-length read means the writer end closed, i.e. the
    /// child exited. Any bytes read are stashed on the entry so the later full
    /// drain does not lose them. This makes `checkResponses` non-blocking for a
    /// child that is still producing output AND still running, at the cost of
    /// one extra read; a child that has exited reads 0 promptly.
    ///
    /// Implementation note: to keep the registry simple and the acceptance
    /// tests deterministic, the partial read is buffered into `prefetched`.
    fn childLikelyDone(allocator: std.mem.Allocator, p: *PendingAsyncHook) bool {
        const out_file = p.child.stdout orelse return true; // no pipe -> reap now
        var buf: [4096]u8 = undefined;
        const n = out_file.readStreaming(rt.io, &.{&buf}) catch return true;
        if (n == 0) {
            // EOF: writer closed -> child is done.
            return true;
        }
        // The child produced data and may still be running. Stash what we read
        // so the full drain picks up from here, and report "not done yet".
        p.prefetched.appendSlice(allocator, buf[0..n]) catch return true;
        return false;
    }
};

/// Read the rest of the child's stdout to EOF, prepending any bytes already
/// prefetched by `childLikelyDone`. Returns an owned slice (caller frees) or
/// null if there is no stdout pipe. CLAUDE.md: pipes use `readStreaming`.
fn drainStdout(allocator: std.mem.Allocator, p: *PendingAsyncHook) !?[]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    if (p.prefetched.items.len > 0) {
        try buf.appendSlice(allocator, p.prefetched.items);
    }

    if (p.child.stdout) |out_file| {
        var read_buf: [4096]u8 = undefined;
        while (true) {
            const n = out_file.readStreaming(rt.io, &.{&read_buf}) catch break;
            if (n == 0) break;
            try buf.appendSlice(allocator, read_buf[0..n]);
            if (buf.items.len > 256 * 1024) break; // bound runaway output
        }
        out_file.close(rt.io);
        p.child.stdout = null;
    }
    if (p.child.stdin) |in_file| {
        in_file.close(rt.io);
        p.child.stdin = null;
    }

    if (buf.items.len == 0) {
        buf.deinit(allocator);
        return null;
    }
    return try buf.toOwnedSlice(allocator);
}

/// Parse a finished hook's stdout (first sync JSON line) into an AsyncResponse.
fn buildResponse(allocator: std.mem.Allocator, p: *PendingAsyncHook, drained: ?[]const u8, exit_code: u8) !AsyncResponse {
    var response = AsyncResponse{
        .id = p.id,
        .event = p.event,
        .exit_code = exit_code,
        .rewake = p.rewake and exit_code == 2,
    };

    const bytes = drained orelse return response;
    // The first JSON line is the sync contract line; parse it the same way a
    // synchronous hook's stdout is parsed.
    const first_line = firstJsonLine(bytes);
    var parsed = hook_io.parseOutput(allocator, first_line);
    defer parsed.deinit();

    if (parsed.output.additional_context) |ac| {
        response.additional_context = try allocator.dupe(u8, ac);
    }
    const reason = parsed.output.stop_reason orelse parsed.output.reason orelse parsed.output.permission_decision_reason;
    if (reason) |r| {
        response.reason = try allocator.dupe(u8, r);
    }
    return response;
}

/// Return the first non-empty line of `bytes` (the reference reads the first
/// JSON line of an async hook's stdout). Falls back to the whole buffer trimmed.
fn firstJsonLine(bytes: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) return trimmed;
    }
    return std.mem.trim(u8, bytes, " \t\r\n");
}

/// The single process-global registry instance.
pub var instance: Registry = .{};

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "register then checkResponses drains a finished async hook and empties the registry" {
    const alloc = testing.allocator;
    var reg: Registry = .{};
    defer reg.clear(alloc);

    // A fast async hook: print a JSON contract line, then exit 0.
    var child = try std.process.spawn(rt.io, .{
        .argv = &.{ "sh", "-c", "echo '{\"hookSpecificOutput\":{\"additionalContext\":\"ASYNC_CTX\"}}'; exit 0" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    _ = try reg.register(alloc, child, .post_tool_use, false, "echo", 0);
    child = undefined; // ownership moved into the registry

    try testing.expectEqual(@as(usize, 1), reg.count());

    // Give the child a beat to finish, then poll until it is drained.
    var responses: []AsyncResponse = &.{};
    var attempt: usize = 0;
    while (attempt < 200) : (attempt += 1) {
        clock.sleepNanos(10 * std.time.ns_per_ms);
        responses = try reg.checkResponses(alloc);
        if (responses.len > 0) break;
        alloc.free(responses);
        responses = &.{};
    }
    defer freeResponses(alloc, responses);

    try testing.expectEqual(@as(usize, 1), responses.len);
    try testing.expectEqual(@as(usize, 0), reg.count());
    try testing.expect(responses[0].additional_context != null);
    try testing.expectEqualStrings("ASYNC_CTX", responses[0].additional_context.?);
    try testing.expectEqual(@as(u8, 0), responses[0].exit_code);
}

test "finalizeAll flushes a still-pending async hook by blocking on it" {
    const alloc = testing.allocator;
    var reg: Registry = .{};
    defer reg.clear(alloc);

    var child = try std.process.spawn(rt.io, .{
        .argv = &.{ "sh", "-c", "echo '{}'; exit 0" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    _ = try reg.register(alloc, child, .stop, false, "echo", 0);
    child = undefined;

    const responses = try reg.finalizeAll(alloc);
    defer freeResponses(alloc, responses);
    try testing.expectEqual(@as(usize, 1), responses.len);
    try testing.expectEqual(@as(usize, 0), reg.count());
}

test "asyncRewake hook exiting 2 surfaces rewake with its reason" {
    const alloc = testing.allocator;
    var reg: Registry = .{};
    defer reg.clear(alloc);

    var child = try std.process.spawn(rt.io, .{
        .argv = &.{ "sh", "-c", "echo '{\"stopReason\":\"wake up\"}'; exit 2" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    _ = try reg.register(alloc, child, .stop, true, "echo", 0);
    child = undefined;

    const responses = try reg.finalizeAll(alloc);
    defer freeResponses(alloc, responses);
    try testing.expectEqual(@as(usize, 1), responses.len);
    try testing.expect(responses[0].rewake);
    try testing.expectEqual(@as(u8, 2), responses[0].exit_code);
    try testing.expect(responses[0].reason != null);
    try testing.expectEqualStrings("wake up", responses[0].reason.?);
}
