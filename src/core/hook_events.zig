//! Task 16 (hooks-14, hooks-18): hook-execution event broadcasting + statusMessage.
//!
//! A lightweight emitter that broadcasts `started` / `progress` / `response`
//! events for each hook execution so a REPL/SDK consumer can surface them in the
//! transcript (reference: claude-code-main `utils/hooks/hookEvents.ts`
//! `emitHookStarted` / `emitHookProgress` / `emitHookResponse`). It also carries
//! a separate spinner-update callback used to show a hook's `statusMessage` while
//! it runs (hooks-18; reference threads `statusMessage` into the spinner).
//!
//! Two design simplifications vs the reference, per CLAUDE.md rule 2 (keep it
//! simple):
//!   - A single registerable listener, not a pub/sub bus. The CLI has exactly one
//!     consumer (the REPL/SDK bridge).
//!   - No pending-event ring buffer. The reference buffers up to 100 events
//!     before a handler registers; here the listener is installed at session
//!     start before any hook fires, so an event emitted with no listener is just
//!     dropped (this is observability, the lowest-priority surface).
//!
//! `ALWAYS_EMITTED` mirrors the reference: SessionStart / Setup always emit even
//! when the SDK `includeHookEvents` toggle is off, because they are low-noise
//! lifecycle events that older clients already relied on.
//!
//! Process-global mutable state follows the same install-once discipline as
//! `rt.io`; tests reset it via `resetForTest()`.

const std = @import("std");
const rt = @import("zcode_runtime");
const hook_event = @import("hook_event.zig");

/// Events that always emit regardless of `setAllHookEventsEnabled`, mirroring the
/// reference `ALWAYS_EMITTED_HOOK_EVENTS` (hookEvents.ts:18). These are low-noise
/// lifecycle events kept on for backwards-compatibility.
pub const ALWAYS_EMITTED = [_]hook_event.Event{ .session_start, .setup };

/// The phase of a hook execution being broadcast (reference's `type` discriminant).
pub const Phase = enum { started, progress, response };

/// Final outcome of a hook run, surfaced on the `response` event (reference
/// `HookResponseEvent.outcome`). `success` = exit 0 / non-blocking; `error` =
/// exit non-zero / blocking; `cancelled` = timed out / aborted.
pub const Outcome = enum { success, @"error", cancelled };

/// A single broadcast event. Slices borrow from the caller's stack/buffers for
/// the duration of the listener call only; a listener that needs to retain them
/// must copy. This mirrors the reference's by-value event objects.
pub const Event = struct {
    phase: Phase,
    /// Stable-ish id for correlating a started/response pair within one run.
    hook_id: []const u8,
    /// Human-facing hook name (the command/url/prompt body, truncated by the
    /// caller if desired). Reference `hookName`.
    hook_name: []const u8,
    /// Canonical lifecycle event name (e.g. "PreToolUse"). Reference `hookEvent`.
    hook_event: []const u8,
    /// Hook stdout (response phase only; "" otherwise).
    stdout: []const u8 = "",
    /// Hook stderr (response phase only; "" otherwise).
    stderr: []const u8 = "",
    /// Process exit code, when known (response phase). Null for started/progress.
    exit_code: ?u8 = null,
    /// Outcome classification (response phase only).
    outcome: Outcome = .success,
};

/// A registered execution-event listener. Single listener by design (see header).
pub const Listener = *const fn (Event) void;

/// A registered spinner-update callback for a hook's `statusMessage` (hooks-18).
/// Called with the status line just before the hook runs so the spinner can show
/// what the hook is doing. Separate from `Listener` because it targets the live
/// UI spinner, not the transcript/SDK event stream.
pub const StatusListener = *const fn ([]const u8) void;

/// Process-global emitter. Guarded by a mutex because hooks may run (and emit)
/// from background threads (async hooks) while the main loop reads/sets state.
pub const Emitter = struct {
    listener: ?Listener = null,
    status_listener: ?StatusListener = null,
    all_enabled: bool = false,
    mutex: std.Io.Mutex = .init,

    /// Install (or clear, with null) the execution-event listener. Matches the
    /// reference `registerHookEventHandler` minus the pending-event flush (we do
    /// not buffer; see header).
    pub fn setListener(self: *Emitter, listener: ?Listener) void {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        self.listener = listener;
    }

    /// Install (or clear) the spinner status callback (hooks-18).
    pub fn setStatusListener(self: *Emitter, listener: ?StatusListener) void {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        self.status_listener = listener;
    }

    /// Toggle emission of all non-always events (reference
    /// `setAllHookEventsEnabled`, driven by the SDK `includeHookEvents` option /
    /// remote mode). SessionStart / Setup emit regardless of this.
    pub fn setAllEnabled(self: *Emitter, enabled: bool) void {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        self.all_enabled = enabled;
    }

    /// Whether an event for `event` should be delivered: always for the
    /// ALWAYS_EMITTED set, otherwise only when `all_enabled` is set
    /// (reference `shouldEmit`).
    fn shouldEmit(self: *const Emitter, event: hook_event.Event) bool {
        for (ALWAYS_EMITTED) |e| {
            if (e == event) return true;
        }
        return self.all_enabled;
    }

    /// Deliver `ev` to the listener when gating allows. `event` is the lifecycle
    /// event used purely for the always-emit gate; `ev.hook_event` is its string
    /// form for the listener.
    fn dispatch(self: *Emitter, event: hook_event.Event, ev: Event) void {
        self.mutex.lock(rt.io) catch {};
        const listener = self.listener;
        const enabled = self.shouldEmit(event);
        self.mutex.unlock(rt.io);
        if (!enabled) return;
        if (listener) |l| l(ev);
    }

    /// Emit a `started` event for a hook run (reference `emitHookStarted`).
    pub fn emitStarted(self: *Emitter, event: hook_event.Event, hook_id: []const u8, hook_name: []const u8) void {
        self.dispatch(event, .{
            .phase = .started,
            .hook_id = hook_id,
            .hook_name = hook_name,
            .hook_event = hook_event.canonicalName(event),
        });
    }

    /// Emit a `progress` event mid-run (reference `emitHookProgress`). Unused by
    /// the synchronous command path today but provided for the async drain path.
    pub fn emitProgress(self: *Emitter, event: hook_event.Event, hook_id: []const u8, hook_name: []const u8, stdout: []const u8, stderr: []const u8) void {
        self.dispatch(event, .{
            .phase = .progress,
            .hook_id = hook_id,
            .hook_name = hook_name,
            .hook_event = hook_event.canonicalName(event),
            .stdout = stdout,
            .stderr = stderr,
        });
    }

    /// Emit a `response` event when a hook run finishes (reference
    /// `emitHookResponse`), carrying the parsed exit code and outcome.
    pub fn emitResponse(self: *Emitter, event: hook_event.Event, hook_id: []const u8, hook_name: []const u8, stdout: []const u8, stderr: []const u8, exit_code: ?u8, outcome: Outcome) void {
        self.dispatch(event, .{
            .phase = .response,
            .hook_id = hook_id,
            .hook_name = hook_name,
            .hook_event = hook_event.canonicalName(event),
            .stdout = stdout,
            .stderr = stderr,
            .exit_code = exit_code,
            .outcome = outcome,
        });
    }

    /// Push a hook's `statusMessage` to the spinner (hooks-18). A no-op when the
    /// message is empty or no spinner callback is installed. Independent of the
    /// always-emit gate: a status line is a UI affordance, not a broadcast event.
    pub fn emitStatus(self: *Emitter, status_message: []const u8) void {
        if (status_message.len == 0) return;
        self.mutex.lock(rt.io) catch {};
        const cb = self.status_listener;
        self.mutex.unlock(rt.io);
        if (cb) |c| c(status_message);
    }
};

/// Process-global instance. Mirrors `async_hook_registry.instance` /
/// `session_hooks.instance`; same install-once discipline.
pub var instance: Emitter = .{};

/// Drop all listeners and gating so a leftover listener cannot bleed across
/// tests. Same discipline as `rt.io`.
pub fn resetForTest() void {
    instance.setListener(null);
    instance.setStatusListener(null);
    instance.setAllEnabled(false);
}

const testing = std.testing;

// Test plumbing: the listener signature is a bare fn pointer (no closure), so a
// test captures into module-global scratch state, asserts on it, then resets.
const Capture = struct {
    var started_count: usize = 0;
    var response_count: usize = 0;
    var progress_count: usize = 0;
    var last_exit: ?u8 = null;
    var last_event_name_buf: [64]u8 = undefined;
    var last_event_name_len: usize = 0;
    var status_count: usize = 0;
    var last_status_buf: [80]u8 = undefined;
    var last_status_len: usize = 0;

    fn reset() void {
        started_count = 0;
        response_count = 0;
        progress_count = 0;
        last_exit = null;
        last_event_name_len = 0;
        status_count = 0;
        last_status_len = 0;
    }

    fn onEvent(ev: Event) void {
        switch (ev.phase) {
            .started => started_count += 1,
            .response => {
                response_count += 1;
                last_exit = ev.exit_code;
            },
            .progress => progress_count += 1,
        }
        const n = @min(ev.hook_event.len, last_event_name_buf.len);
        @memcpy(last_event_name_buf[0..n], ev.hook_event[0..n]);
        last_event_name_len = n;
    }

    fn onStatus(msg: []const u8) void {
        status_count += 1;
        const n = @min(msg.len, last_status_buf.len);
        @memcpy(last_status_buf[0..n], msg[0..n]);
        last_status_len = n;
    }

    fn lastEventName() []const u8 {
        return last_event_name_buf[0..last_event_name_len];
    }

    fn lastStatus() []const u8 {
        return last_status_buf[0..last_status_len];
    }
};

test "hook_events: listener receives one started and one response with exit code" {
    Capture.reset();
    resetForTest();
    defer resetForTest();

    // SessionStart is in ALWAYS_EMITTED, so it surfaces without enabling all.
    instance.setListener(Capture.onEvent);
    instance.emitStarted(.session_start, "id-1", "echo hi");
    instance.emitResponse(.session_start, "id-1", "echo hi", "hi\n", "", 0, .success);

    try testing.expectEqual(@as(usize, 1), Capture.started_count);
    try testing.expectEqual(@as(usize, 1), Capture.response_count);
    try testing.expectEqual(@as(?u8, 0), Capture.last_exit);
    try testing.expectEqualStrings("SessionStart", Capture.lastEventName());
}

test "hook_events: non-always event is gated until setAllEnabled" {
    Capture.reset();
    resetForTest();
    defer resetForTest();

    instance.setListener(Capture.onEvent);

    // PreToolUse is NOT in ALWAYS_EMITTED, so with all disabled it is dropped.
    instance.emitStarted(.pre_tool_use, "id-2", "lint");
    try testing.expectEqual(@as(usize, 0), Capture.started_count);

    // After enabling, it surfaces.
    instance.setAllEnabled(true);
    instance.emitStarted(.pre_tool_use, "id-2", "lint");
    try testing.expectEqual(@as(usize, 1), Capture.started_count);
    try testing.expectEqualStrings("PreToolUse", Capture.lastEventName());
}

test "hook_events: SessionStart emits even when SDK toggle is off" {
    Capture.reset();
    resetForTest();
    defer resetForTest();

    instance.setListener(Capture.onEvent);
    // all_enabled stays false; SessionStart must still surface.
    instance.emitStarted(.session_start, "id-3", "boot");
    instance.emitResponse(.session_start, "id-3", "boot", "", "", 0, .success);
    try testing.expectEqual(@as(usize, 1), Capture.started_count);
    try testing.expectEqual(@as(usize, 1), Capture.response_count);
}

test "hook_events: statusMessage invokes the spinner callback" {
    Capture.reset();
    resetForTest();
    defer resetForTest();

    instance.setStatusListener(Capture.onStatus);
    instance.emitStatus("linting");
    try testing.expectEqual(@as(usize, 1), Capture.status_count);
    try testing.expectEqualStrings("linting", Capture.lastStatus());

    // An empty status is a no-op (no spinner churn for hooks without a message).
    instance.emitStatus("");
    try testing.expectEqual(@as(usize, 1), Capture.status_count);
}

test "hook_events: no listener means events are silently dropped" {
    Capture.reset();
    resetForTest();
    defer resetForTest();

    // No listener installed: emitting must not panic and must not record.
    instance.emitStarted(.session_start, "id", "x");
    instance.emitStatus("ignored");
    try testing.expectEqual(@as(usize, 0), Capture.started_count);
    try testing.expectEqual(@as(usize, 0), Capture.status_count);
}

test "hook_events: progress event surfaces when enabled" {
    Capture.reset();
    resetForTest();
    defer resetForTest();

    instance.setListener(Capture.onEvent);
    instance.setAllEnabled(true);
    instance.emitProgress(.post_tool_use, "id-4", "drain", "partial", "");
    try testing.expectEqual(@as(usize, 1), Capture.progress_count);
}
