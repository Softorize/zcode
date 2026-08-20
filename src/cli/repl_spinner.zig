const std = @import("std");
const builtin = @import("builtin");
const rt = @import("zcode_runtime");
const clock = @import("../core/clock.zig");
const http_common = @import("../providers/common.zig");
const repl_markdown = @import("repl_markdown.zig");
const spinner_glyph = @import("../core/spinner_glyph.zig");

const SPINNER_FRAME_INTERVAL_NS: u64 = 120 * std.time.ns_per_ms;
const THINKING_INPUT_POLL_INTERVAL_NS: u64 = 8 * std.time.ns_per_ms;

/// Gate the animated morph-glyph cycle. The reference cycles a 6-glyph
/// `·✢✳✶✻✽` set forward then reversed; a prior zcode simplification
/// collapsed the leading glyph to a single static ● because the old
/// breathing cycle "felt like the text was moving". This reintroduces a
/// controlled glyph animation (matching the reference) behind a flag so it
/// can be reverted to the static dot if the same feedback recurs. Default
/// on; set ZCODE_STATIC_SPINNER_GLYPH=1 to fall back to the static ●.
fn animatedGlyphEnabled() bool {
    if (@import("../core/env.zig").getenv("ZCODE_STATIC_SPINNER_GLYPH")) |v| {
        if (v.len > 0) return false;
    }
    return true;
}

/// The morph-glyph set for this terminal, selected once per spinner run
/// from $TERM and the host platform per the reference's
/// getDefaultCharacters().
fn currentGlyphSet() [spinner_glyph.SET_LEN][]const u8 {
    const term = @import("../core/env.zig").getenv("TERM") orelse "";
    const is_darwin = builtin.os.tag == .macos;
    return spinner_glyph.defaultCharacters(term, is_darwin);
}

pub const UiTranscript = struct {
    lines: std.array_list.Managed([]u8),
    max_lines: usize,

    pub fn init(allocator: std.mem.Allocator, max_lines: usize) UiTranscript {
        return .{
            .lines = std.array_list.Managed([]u8).init(allocator),
            .max_lines = max_lines,
        };
    }

    pub fn deinit(self: *UiTranscript, allocator: std.mem.Allocator) void {
        for (self.lines.items) |line| allocator.free(line);
        self.lines.deinit();
    }

    /// Drop every line. Used to clear the welcome screen the first
    /// time the user submits input — that way the conversation
    /// doesn't share screen space with the cheat-sheet banner.
    pub fn clear(self: *UiTranscript, allocator: std.mem.Allocator) void {
        for (self.lines.items) |line| allocator.free(line);
        self.lines.clearRetainingCapacity();
    }

    pub fn appendLine(self: *UiTranscript, allocator: std.mem.Allocator, line: []const u8) !void {
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        // Dynamically size the sanitization buffer to avoid overflow on long lines.
        const buf_len = @max(@as(usize, 2048), trimmed.len + 1);
        const clean_buf = try allocator.alloc(u8, buf_len);
        defer allocator.free(clean_buf);
        const clean = sanitizeText(trimmed, clean_buf);
        const owned = if (clean.len == 0)
            try allocator.dupe(u8, "")
        else
            try allocator.dupe(u8, clean);
        try self.lines.append(owned);
        if (self.max_lines > 0 and self.lines.items.len > self.max_lines) {
            const overflow = self.lines.items.len - self.max_lines;
            var i: usize = 0;
            while (i < overflow) : (i += 1) {
                const dropped = self.lines.orderedRemove(0);
                allocator.free(dropped);
            }
        }
    }

    pub fn appendText(self: *UiTranscript, allocator: std.mem.Allocator, text: []const u8) !void {
        var it = std.mem.splitScalar(u8, text, '\n');
        var added = false;
        while (it.next()) |line| {
            try self.appendLine(allocator, line);
            added = true;
        }
        if (!added) {
            try self.appendLine(allocator, text);
        }
    }
};

/// Callback invoked from the spinner thread when a scroll event
/// arrives during thinking and the main thread has registered a
/// live-redraw handler. `delta` is the signed row delta (positive
/// = user scrolled UP, negative = scrolled DOWN). The handler owns
/// applying the delta to its scroll_offset variable and redrawing
/// the transcript window -- the spinner side just fires the event.
pub const LiveRedrawCallback = *const fn (ctx: *anyopaque, delta: i32) void;

pub const SpinnerState = struct {
    mutex: std.Io.Mutex = .init,
    write_mutex: std.Io.Mutex = .init,
    latest: [160]u8 = [_]u8{0} ** 160,
    latest_len: usize = 0,
    started_ns: i128 = 0,
    summary_items: [6][80]u8 = [_][80]u8{[_]u8{0} ** 80} ** 6,
    summary_lens: [6]u8 = [_]u8{0} ** 6,
    summary_count: usize = 0,
    use_fullscreen: bool = false,
    bottom_margin: usize = 0,
    transcript: ?*UiTranscript = null,
    transcript_allocator: ?std.mem.Allocator = null,
    streaming_active: bool = false,
    tool_use_count: usize = 0,
    /// Set to true when the user presses Escape during agent work.
    /// The agent loop checks this between rounds and tool calls.
    cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Count of consecutive Escape presses during agent work.
    escape_press_count: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    /// Timestamp of last Escape press (seconds) for triple-press timeout.
    last_escape_ts: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    stream_buf: [4096]u8 = undefined,
    stream_buf_len: usize = 0,
    stream_last_flush_ns: i128 = 0,
    stream_transcript_buf: [32768]u8 = undefined,
    stream_transcript_len: usize = 0,
    /// Scroll offset adjusted by arrow keys during agent work (for fullscreen)
    scroll_offset_delta: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    stream_token_count: usize = 0,
    /// Queued user input typed during thinking. Protected by mutex.
    queued_input: [4096]u8 = undefined,
    queued_input_len: usize = 0,
    /// Set to true when user submits queued input (Enter during thinking).
    /// Retained as a wake-up signal for the main loop even though the
    /// actual prompts now live in prompt_queue below.
    queued_input_submitted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Multi-slot prompt queue, ported in spirit from claude-code-main/
    /// src/utils/messageQueueManager.ts. When the user presses Enter
    /// while the agent is still working, the current queued_input
    /// buffer is copied into the next free slot and the buffer is
    /// cleared so another prompt can be typed on top. The main loop
    /// drains the queue FIFO between turns via dequeuePromptLocked.
    ///
    /// Fixed-size storage keeps the allocator out of the spinner-thread
    /// hot path. 8 slots @ 4 KB each = 32 KB, plenty for interactive
    /// use. Overflow rejects the new prompt rather than overwriting
    /// earlier entries so typing too fast never silently loses work.
    prompt_queue: [MAX_QUEUED_PROMPTS][QUEUED_PROMPT_CAP]u8 = undefined,
    prompt_queue_lens: [MAX_QUEUED_PROMPTS]usize = [_]usize{0} ** MAX_QUEUED_PROMPTS,
    prompt_queue_count: usize = 0,
    /// Set to true when a scroll event occurs and a re-render is needed
    scroll_render_needed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Current absolute scroll offset for live rendering during thinking
    live_scroll_offset: usize = 0,
    /// Live-redraw callback invoked from the spinner thread when a
    /// scroll event fires during thinking. The main thread wires
    /// this up with a closure over the transcript, options, and the
    /// caller-owned scroll_offset variable -- the spinner thread is
    /// then free to trigger a full transcript re-render without
    /// needing to know how the REPL lays out its buffers. When the
    /// callback is null (e.g. during non-interactive runs or early
    /// startup), the scroll delta is still accumulated but the
    /// re-render is deferred until after the turn completes.
    live_redraw_ctx: ?*anyopaque = null,
    live_redraw_fn: ?LiveRedrawCallback = null,
    /// Last wall-clock ns the live redraw callback fired. Rapid wheel
    /// bursts can produce more events than the terminal can paint.
    /// We still poll input every few milliseconds, but cap actual
    /// redraws at the display-friendly cadence below.
    last_live_redraw_ns: i128 = 0,
    /// Markdown render state for streaming output formatting
    stream_md_state: repl_markdown.MarkdownRenderState = .{},

    /// Hash of the last tool block written to the terminal. Used by
    /// replEmitToolOutput to fold consecutive identical blocks (e.g.
    /// repeated "MCP invoke failed: McpResponseTimeout" cards from a
    /// dead MCP server) into a single "(repeated N more times)" line
    /// instead of bloating the transcript with N copies of the same
    /// error. 0 sentinel = no previous block / cache cleared.
    last_tool_block_hash: u64 = 0,
    /// Number of consecutive duplicate tool blocks that have been
    /// suppressed since the last unique block was emitted. Flushed
    /// just before the next non-duplicate block (or end of turn) so
    /// the user can see how many repeats actually happened.
    last_tool_block_repeats: usize = 0,

    // Stream JSON filter state: filters raw JSON model output to only show assistant text
    stream_filter: StreamFilterState = .{},

    /// Passive "tip on the spinner" line (Phase 14.13). Set once at turn start
    /// by the main thread (via setTip) from the longest-since-shown relevant
    /// tip; rendered on its own row below the spinner status. Empty = no tip.
    /// The main thread is also responsible for recording the tip as shown
    /// exactly once per turn so the spinner thread's frequent re-renders never
    /// double-count it.
    tip_buf: [200]u8 = [_]u8{0} ** 200,
    tip_len: usize = 0,

    pub const StreamFilterState = struct {
        mode: enum { unknown, json, passthrough, skip_json_block } = .unknown,
        phase: enum { scanning, in_value, done } = .scanning,
        // Small lookahead buffer to detect JSON start and find "assistant" key
        peek_buf: [512]u8 = undefined,
        peek_len: usize = 0,
        in_escape: bool = false,
        // For skip_json_block mode: track brace depth and string state
        skip_depth: u8 = 0,
        skip_in_string: bool = false,
        skip_esc: bool = false,
        // Mid-stream re-entry: lets us climb back OUT of passthrough mode
        // when a local model emits prose, then drops a raw tool-call JSON
        // or fenced code block mid-turn. The earlier filter design assumed
        // a turn was either all-prose or all-JSON, which let envelopes
        // like `{"tool_calls":[...]}` leak into the user-visible transcript
        // after an initial non-JSON token (see passcase screenshot 2026-04).
        reentry_active: bool = false,
        reentry_buf: [256]u8 = undefined,
        reentry_len: usize = 0,
        // Last byte we actually emitted in passthrough mode. Tracked so
        // the re-entry heuristic only fires at the start of a fresh line
        // ("\n{" / "\n`"), not on every stray `{` that happens to appear
        // inside prose.
        last_passthrough_byte: u8 = '\n',
    };

    /// Max concurrently-queued prompts in the multi-slot queue.
    /// See prompt_queue above for the storage layout.
    pub const MAX_QUEUED_PROMPTS: usize = 8;
    pub const QUEUED_PROMPT_CAP: usize = 4096;

    /// Push the current queued_input buffer onto the prompt_queue as
    /// a new slot and clear the buffer. Caller MUST hold self.mutex.
    /// Returns true when a slot was claimed, false when the queue is
    /// full or the buffer is empty (in which case the caller should
    /// surface a "queue full" hint to the user).
    pub fn enqueuePromptFromBufferLocked(self: *SpinnerState) bool {
        if (self.queued_input_len == 0) return false;
        if (self.prompt_queue_count >= MAX_QUEUED_PROMPTS) return false;
        const idx = self.prompt_queue_count;
        const take = @min(self.queued_input_len, QUEUED_PROMPT_CAP);
        @memcpy(self.prompt_queue[idx][0..take], self.queued_input[0..take]);
        self.prompt_queue_lens[idx] = take;
        self.prompt_queue_count += 1;
        // Clear the buffer so the user can start typing another prompt
        // on top of the one we just queued.
        self.queued_input_len = 0;
        return true;
    }

    /// Pop the front-of-queue prompt, shift the rest forward, and
    /// return an owned copy of the popped bytes. Returns null when
    /// the queue is empty. Caller owns the returned slice.
    pub fn dequeuePromptOwned(self: *SpinnerState, allocator: std.mem.Allocator) !?[]u8 {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        if (self.prompt_queue_count == 0) return null;
        const first_len = self.prompt_queue_lens[0];
        const out = try allocator.dupe(u8, self.prompt_queue[0][0..first_len]);

        // Shift remaining slots forward by one. Simple memcpy of the
        // active bytes; unused trailing space is left as-is.
        var i: usize = 1;
        while (i < self.prompt_queue_count) : (i += 1) {
            const len = self.prompt_queue_lens[i];
            if (len > 0) {
                @memcpy(self.prompt_queue[i - 1][0..len], self.prompt_queue[i][0..len]);
            }
            self.prompt_queue_lens[i - 1] = len;
        }
        self.prompt_queue_count -= 1;
        self.prompt_queue_lens[self.prompt_queue_count] = 0;
        return out;
    }

    /// Snapshot the current queue depth. Used by the status line
    /// builder to show a "| N queued" indicator.
    pub fn queuedPromptCount(self: *SpinnerState) usize {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        return self.prompt_queue_count;
    }

    /// Clear every queued prompt and the in-flight buffer. Called on
    /// ESC so a cancel drops all pending work, matching the reference
    /// behaviour where cancelling the current turn discards queued
    /// notifications (see clearCommandQueue in messageQueueManager.ts).
    pub fn clearPromptQueueLocked(self: *SpinnerState) void {
        var i: usize = 0;
        while (i < self.prompt_queue_count) : (i += 1) {
            self.prompt_queue_lens[i] = 0;
        }
        self.prompt_queue_count = 0;
        self.queued_input_len = 0;
    }

    pub fn resetStreamFilter(self: *SpinnerState) void {
        self.stream_filter = .{};
    }

    pub fn reset(self: *SpinnerState) void {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        self.latest_len = 0;
        self.summary_count = 0;
        self.tool_use_count = 0;
        self.stream_transcript_len = 0;
        self.stream_token_count = 0;
        self.live_scroll_offset = 0;
        self.queued_input_len = 0;
        // NOTE: prompt_queue is INTENTIONALLY not cleared here.
        // reset() runs at the start of every new turn but the main
        // loop only dequeues ONE prompt per turn -- any remaining
        // slots still belong to the user and must survive across
        // turn boundaries. clearPromptQueueLocked is only called
        // on explicit cancel (ESC) below.
        self.started_ns = clock.nowNanos();
        self.cancel_requested.store(false, .release);
        self.escape_press_count.store(0, .release);
        self.scroll_offset_delta.store(0, .release);
        self.scroll_render_needed.store(false, .release);
        self.last_live_redraw_ns = 0;
        self.queued_input_submitted.store(false, .release);
        self.stream_md_state = repl_markdown.MarkdownRenderState{};
        self.stream_filter = .{};
        self.last_tool_block_hash = 0;
        self.last_tool_block_repeats = 0;
        // Clear the previous turn's spinner tip; the main thread sets a fresh
        // one (if any) right after reset() via setTip.
        self.tip_len = 0;
    }

    pub fn incrementToolCount(self: *SpinnerState) void {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        self.tool_use_count += 1;
    }

    pub fn update(self: *SpinnerState, message: []const u8) void {
        var normalized_buf: [80]u8 = undefined;
        const normalized = normalizeSummary(message, &normalized_buf);
        if (normalized.len == 0) return;

        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);

        self.latest_len = normalized.len;
        @memcpy(self.latest[0..normalized.len], normalized);

        // Dedupe by ACTION PREFIX across all current slots. The action
        // prefix is the text up to the first '|' (or the whole string
        // when there is no pipe). This lets ticks like "calling model X
        // | 9 tools | 47.5s" and "calling model X | 9 tools | 65.2s"
        // overwrite the SAME slot instead of appending a new one each
        // time the timing number changes. Without this, a long turn
        // with many model calls fills the activity timeline with N
        // copies of the same "calling model" line that only differ in
        // the seconds counter, drowning out genuinely new activity.
        const new_prefix = actionPrefix(normalized);
        var found: ?usize = null;
        var scan: usize = 0;
        while (scan < self.summary_count) : (scan += 1) {
            const slot_len: usize = self.summary_lens[scan];
            const slot = self.summary_items[scan][0..slot_len];
            if (std.mem.eql(u8, actionPrefix(slot), new_prefix)) {
                found = scan;
                break;
            }
        }
        if (found) |idx| {
            self.summary_lens[idx] = @intCast(normalized.len);
            @memcpy(self.summary_items[idx][0..normalized.len], normalized);
            return;
        }

        const idx: usize = if (self.summary_count < self.summary_items.len) blk: {
            const slot = self.summary_count;
            self.summary_count += 1;
            break :blk slot;
        } else blk: {
            var i: usize = 1;
            while (i < self.summary_items.len) : (i += 1) {
                const src_len: usize = self.summary_lens[i];
                self.summary_lens[i - 1] = self.summary_lens[i];
                if (src_len > 0) {
                    @memcpy(self.summary_items[i - 1][0..src_len], self.summary_items[i][0..src_len]);
                }
            }
            break :blk self.summary_items.len - 1;
        };

        self.summary_lens[idx] = @intCast(normalized.len);
        @memcpy(self.summary_items[idx][0..normalized.len], normalized);
    }

    pub fn latestText(self: *SpinnerState, out: *[160]u8) []const u8 {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);

        if (self.latest_len == 0) return "working";
        @memcpy(out[0..self.latest_len], self.latest[0..self.latest_len]);
        return out[0..self.latest_len];
    }

    /// Set the passive spinner tip for the current turn (Phase 14.13). Called
    /// once at turn start by the main thread; empty `text` clears the tip.
    /// Sanitized via normalizeSummary's escape-stripping so an LLM-derived
    /// custom tip cannot smuggle control sequences onto the spinner row.
    pub fn setTip(self: *SpinnerState, text: []const u8) void {
        var clean_buf: [80]u8 = undefined;
        const clean = normalizeSummary(text, &clean_buf);
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        const take = @min(clean.len, self.tip_buf.len);
        if (take > 0) @memcpy(self.tip_buf[0..take], clean[0..take]);
        self.tip_len = take;
    }

    /// Copy the current spinner tip into `out`, returning the slice (empty when
    /// no tip is set). Used by the spinner thread to render the tip row.
    pub fn tipText(self: *SpinnerState, out: *[200]u8) []const u8 {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        if (self.tip_len == 0) return "";
        @memcpy(out[0..self.tip_len], self.tip_buf[0..self.tip_len]);
        return out[0..self.tip_len];
    }

    pub fn startedTimestampNs(self: *SpinnerState) i128 {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        return self.started_ns;
    }

    pub fn topicTitle(self: *SpinnerState, out: *[96]u8) []const u8 {
        var latest_buf: [160]u8 = undefined;
        const latest = self.latestText(&latest_buf);
        // Seed the spinner-verb picker with started_ns so the colourful
        // fallback verb stays stable for the whole turn but rotates on
        // the next turn. When there's a structured progress phase
        // ("Running Tools", "Calling Model", etc) the seed is unused.
        return deriveThinkingTopicTitleWithSeed(latest, self.startedTimestampNs(), out);
    }

    pub fn summaryText(self: *SpinnerState, out: *[640]u8) []const u8 {
        var local_items: [6][80]u8 = undefined;
        var local_lens: [6]u8 = [_]u8{0} ** 6;
        var count: usize = 0;

        self.mutex.lock(rt.io) catch {};
        count = self.summary_count;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            local_lens[i] = self.summary_lens[i];
            const len: usize = local_lens[i];
            if (len > 0) {
                @memcpy(local_items[i][0..len], self.summary_items[i][0..len]);
            }
        }
        self.mutex.unlock(rt.io);

        if (count == 0) return "";

        var out_len: usize = 0;
        var idx: usize = 0;
        while (idx < count) : (idx += 1) {
            const len: usize = local_lens[idx];
            if (len > 0 and out_len < out.len) {
                const take = @min(len, out.len - out_len);
                @memcpy(out[out_len .. out_len + take], local_items[idx][0..take]);
                out_len += take;
            }

            if (idx + 1 < count and out_len < out.len) {
                const sep = " -> ";
                const take_sep = @min(sep.len, out.len - out_len);
                @memcpy(out[out_len .. out_len + take_sep], sep[0..take_sep]);
                out_len += take_sep;
            }
        }

        return out[0..out_len];
    }

    pub fn isStreaming(self: *SpinnerState) bool {
        self.mutex.lock(rt.io) catch {};
        defer self.mutex.unlock(rt.io);
        return self.streaming_active;
    }

    pub fn flushStreamBuf(self: *SpinnerState) void {
        const repl_agent = @import("repl_agent.zig");
        repl_agent.flushStreamToScreen(self);
    }
};

pub const ThinkingSpinner = struct {
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    active: bool = false,
    fixed_input_border: bool = false,
    bottom_margin_rows: usize = 0,
    state: ?*SpinnerState = null,

    pub fn start(self: *ThinkingSpinner, state: *SpinnerState, fixed_input_border: bool, bottom_margin_rows: usize, enabled: bool) void {
        self.state = state;
        self.fixed_input_border = fixed_input_border;
        self.bottom_margin_rows = bottom_margin_rows;
        if (!enabled or !canAnimateThinking()) return;
        self.done.store(false, .release);
        self.thread = std.Thread.spawn(.{}, spinnerMain, .{ &self.done, state, fixed_input_border, bottom_margin_rows }) catch return;
        self.active = true;
    }

    pub fn stop(self: *ThinkingSpinner) void {
        if (!self.active) return;
        self.done.store(true, .release);
        if (self.thread) |thread| {
            thread.join();
        }
        self.thread = null;
        self.active = false;
        clearSpinnerLine(self.fixed_input_border, self.bottom_margin_rows);
    }
};

pub fn canAnimateThinking() bool {
    if (std.c.isatty(std.Io.File.stdout().handle) == 0) return false;
    // Reduced-motion preference: terminal-analog of the web
    // `prefers-reduced-motion` query. The reference does NOT suppress the
    // spinner under reduced motion -- it shows a calm 2s-cycle flashing
    // dot. So the thread still runs; the loop renders that flashing dot
    // (see reducedMotionRequested + reducedMotionDim) instead of the morph
    // cycle. A stricter `ZCODE_REDUCE_MOTION=hard` fully suppresses the
    // thread for users who want zero animation, without also disabling
    // token accounting + spinner-gated cancel hints.
    if (@import("../core/env.zig").getenv("ZCODE_REDUCE_MOTION")) |v| {
        if (std.mem.eql(u8, v, "hard")) return false;
    }
    return true;
}

/// True when the user has requested reduced motion via ZCODE_REDUCE_MOTION
/// or the community-standard REDUCE_MOTION env var (any non-empty value).
/// In this state the spinner renders a calm flashing dot rather than the
/// animated morph-glyph cycle, matching the reference's SpinnerGlyph.
pub fn reducedMotionRequested() bool {
    if (@import("../core/env.zig").getenv("ZCODE_REDUCE_MOTION")) |v| {
        if (v.len > 0) return true;
    }
    if (@import("../core/env.zig").getenv("REDUCE_MOTION")) |v| {
        if (v.len > 0) return true;
    }
    return false;
}

pub fn canUseFullScreenUi() bool {
    return std.c.isatty(std.Io.File.stdin().handle) != 0 and std.c.isatty(std.Io.File.stdout().handle) != 0;
}

pub fn boundedBottomMarginRows(total_rows: usize, requested: usize) usize {
    const hard_limit = if (total_rows > 5) total_rows - 5 else 0;
    return @min(requested, hard_limit);
}

pub fn boundedLineSpacingRows(requested: usize) usize {
    return @min(requested, 2);
}

fn spinnerMain(done: *std.atomic.Value(bool), state: *SpinnerState, fixed_input_border: bool, bottom_margin_rows: usize) void {
    // Leading glyph: by default cycle the platform-aware morph set
    // `·✢✳✶✻✽` forward then reversed (12 frames), matching the
    // reference's SpinnerGlyph. A prior simplification collapsed this to
    // a single static ● because the old breathing dot "felt like the
    // text was moving"; the cycle is now gated behind
    // ZCODE_STATIC_SPINNER_GLYPH=1 so that feedback can be honored
    // without code changes. The static-fallback glyph is the same ●.
    const reduced_motion = reducedMotionRequested();
    const animated_glyph = animatedGlyphEnabled();
    const glyph_set = currentGlyphSet();
    const static_frame: []const u8 = "\xe2\x97\x8f"; // ● U+25CF BLACK CIRCLE

    var frame_idx: usize = 0;
    const started_ns = state.startedTimestampNs();
    while (!done.load(.acquire)) {
        // During streaming, accumulate tokens then flush in readable batches
        if (state.isStreaming()) {
            // Poll for interrupt keys during streaming -- otherwise the user
            // cannot cancel a long streaming response. Scroll events are tracked
            // via scroll_offset_delta and applied after the turn completes.
            pollInputDuringThinking(state);
            // Clear the scroll_render_needed flag without re-rendering -- live
            // re-render during streaming clears the visible streamed text.
            _ = state.scroll_render_needed.swap(false, .acquire);
            sleepWithInputPolling(done, state, SPINNER_FRAME_INTERVAL_NS);
            frame_idx += 1;
            if (frame_idx % 4 == 0) {
                state.write_mutex.lock(rt.io) catch {};
                if (state.stream_buf_len > 0) {
                    state.flushStreamBuf();
                }
                state.write_mutex.unlock(rt.io);
            }
            continue;
        }

        // Clear the scroll_render_needed flag -- scroll is tracked via the
        // offset delta and applied after the turn completes, preserving any
        // content drawn directly to the screen.
        _ = state.scroll_render_needed.swap(false, .acquire);

        const base_glyph: []const u8 = if (reduced_motion)
            spinner_glyph.REDUCED_MOTION_DOT
        else if (animated_glyph)
            spinner_glyph.frameGlyph(frame_idx, glyph_set)
        else
            static_frame;
        var latest_buf: [160]u8 = undefined;
        const latest_raw = state.latestText(&latest_buf);
        // Append scroll indicator when user has scrolled during thinking
        var scroll_hint_buf: [200]u8 = undefined;
        const scroll_delta = state.scroll_offset_delta.load(.acquire);
        var latest = if (scroll_delta != 0) blk: {
            const abs_d: u32 = if (scroll_delta > 0) @intCast(scroll_delta) else @intCast(-scroll_delta);
            break :blk std.fmt.bufPrint(&scroll_hint_buf, "{s} [scrolled {d} rows]", .{ latest_raw, abs_d }) catch latest_raw;
        } else latest_raw;
        // Surface a stuck-indicator label in the non-fullscreen path when
        // the default spinner text has been running for >=5s with no
        // tool activity and no stream yet (matches the fullscreen
        // path in buildThinkingStatusLine).
        const is_default_label = latest_raw.len == 0 or std.mem.eql(u8, latest_raw, "working") or std.mem.eql(u8, latest_raw, "thinking");
        const now_ns = clock.nowNanos();
        const elapsed_ms: u64 = if (now_ns > started_ns)
            @intCast(@divTrunc((now_ns - started_ns), std.time.ns_per_ms))
        else
            0;

        state.mutex.lock(rt.io) catch {};
        const tool_count = state.tool_use_count;
        const queued_count = state.prompt_queue_count;
        const has_queued = state.queued_input_len > 0;

        // Rebind `latest` to a stuck-indicator when appropriate.
        if (is_default_label and tool_count == 0 and elapsed_ms >= 5_000 and scroll_delta == 0) {
            latest = "waiting for model response";
        }
        var queued_preview_buf: [80]u8 = undefined;
        const queued_preview_len = @min(state.queued_input_len, queued_preview_buf.len);
        if (has_queued) @memcpy(queued_preview_buf[0..queued_preview_len], state.queued_input[0..queued_preview_len]);
        // Snapshot the passive spinner tip (Phase 14.13) under the same lock.
        var tip_snap_buf: [200]u8 = undefined;
        const tip_snap_len: usize = state.tip_len;
        if (tip_snap_len > 0) @memcpy(tip_snap_buf[0..tip_snap_len], state.tip_buf[0..tip_snap_len]);
        state.mutex.unlock(rt.io);
        const tip_snap = tip_snap_buf[0..tip_snap_len];

        // Leading-glyph color:
        //   - Reduced motion: a calm flashing dot -- dim for the second half
        //     of each 2s cycle (reducedMotionDim), lit otherwise. No stalled
        //     drift (the reference returns early in this branch).
        //   - Stalled (>=5s waiting on the model, no tool activity): drift
        //     the glyph color from the theme accent toward error red as the
        //     stall deepens (the reference's stalledIntensity). Truecolor SGR.
        //   - Otherwise: the plain glyph.
        const is_stalled = is_default_label and tool_count == 0 and elapsed_ms >= 5_000 and scroll_delta == 0;
        var glyph_color_buf: [48]u8 = undefined;
        const frame: []const u8 = if (reduced_motion) blk: {
            if (spinner_glyph.reducedMotionDim(@intCast(elapsed_ms))) {
                break :blk std.fmt.bufPrint(&glyph_color_buf, "\x1b[2m{s}\x1b[0m", .{base_glyph}) catch base_glyph;
            }
            break :blk base_glyph;
        } else if (is_stalled) blk: {
            const accent: spinner_glyph.Rgb = .{ .r = 87, .g = 105, .b = 247 };
            const intensity = spinner_glyph.stalledIntensityPercent(@intCast(elapsed_ms), 5_000, 15_000);
            const color = spinner_glyph.interpolateRgb(accent, spinner_glyph.ERROR_RED, intensity);
            break :blk std.fmt.bufPrint(&glyph_color_buf, "\x1b[38;2;{d};{d};{d}m{s}\x1b[0m", .{ color.r, color.g, color.b, base_glyph }) catch base_glyph;
        } else base_glyph;

        var line_buf: [1536]u8 = undefined;
        const line = if (fixed_input_border)
            buildFixedSpinnerFrame(&line_buf, frame, latest, frame_idx, elapsed_ms, bottom_margin_rows, tool_count, queued_count) catch return
        else blk: {
            if (tool_count > 0 and queued_count > 0) {
                break :blk std.fmt.bufPrint(&line_buf, "\r{s} {s} \x1b[2m{d} tools | {d} queued | {d}.{d}s\x1b[0m\x1b[K", .{ frame, latest, tool_count, queued_count, elapsed_ms / 1000, (elapsed_ms % 1000) / 100 }) catch return;
            } else if (tool_count > 0) {
                break :blk std.fmt.bufPrint(&line_buf, "\r{s} {s} \x1b[2m{d} tools | {d}.{d}s\x1b[0m\x1b[K", .{ frame, latest, tool_count, elapsed_ms / 1000, (elapsed_ms % 1000) / 100 }) catch return;
            } else if (queued_count > 0) {
                break :blk std.fmt.bufPrint(&line_buf, "\r{s} {s} \x1b[2m{d} queued | {d}.{d}s\x1b[0m\x1b[K", .{ frame, latest, queued_count, elapsed_ms / 1000, (elapsed_ms % 1000) / 100 }) catch return;
            } else if (tip_snap.len > 0) {
                // Quiet path with a tip: append it dim and inline so the
                // single-line carriage-return repaint model stays intact (a
                // separate persistent tip row would fight the \r overwrite).
                break :blk std.fmt.bufPrint(&line_buf, "\r{s} {s} \x1b[2m{d}.{d}s | tip: {s}\x1b[0m\x1b[K", .{ frame, latest, elapsed_ms / 1000, (elapsed_ms % 1000) / 100, tip_snap }) catch return;
            } else {
                break :blk std.fmt.bufPrint(&line_buf, "\r{s} {s} \x1b[2m{d}.{d}s\x1b[0m\x1b[K", .{ frame, latest, elapsed_ms / 1000, (elapsed_ms % 1000) / 100 }) catch return;
            }
        };
        state.write_mutex.lock(rt.io) catch {};
        _ = std.c.write(std.Io.File.stdout().handle, (line).ptr, (line).len);
        // Show queued input text in the input area during thinking
        if (fixed_input_border and has_queued) {
            const rows = terminalRows();
            const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
            const input_row = if (rows > margin + 2) rows - margin - 2 else 1;
            var qbuf: [256]u8 = undefined;
            const qline = std.fmt.bufPrint(&qbuf, "\x1b7\x1b[{d};3H\x1b[36m{s}\x1b[0m\x1b[K\x1b8", .{ input_row, queued_preview_buf[0..queued_preview_len] }) catch "";
            if (qline.len > 0) _ = std.c.write(std.Io.File.stdout().handle, (qline).ptr, (qline).len);
        }
        state.write_mutex.unlock(rt.io);

        frame_idx += 1;

        pollInputDuringThinking(state);

        sleepWithInputPolling(done, state, SPINNER_FRAME_INTERVAL_NS);
    }
}

fn sleepWithInputPolling(done: *std.atomic.Value(bool), state: *SpinnerState, duration_ns: u64) void {
    var slept_ns: u64 = 0;
    while (slept_ns < duration_ns and !done.load(.acquire)) {
        const remaining = duration_ns - slept_ns;
        const step = @min(THINKING_INPUT_POLL_INTERVAL_NS, remaining);
        clock.sleepNanos(step);
        slept_ns += step;
        pollInputDuringThinking(state);
    }
}

/// Non-blocking poll of stdin for ESC, Ctrl+C, arrow keys, and typed text
/// while the agent is working. Called from both the idle (spinner) path
/// and the streaming path so interrupts work in all thinking states.
fn pollInputDuringThinking(state: *SpinnerState) void {
    var poll_fds = [1]std.posix.pollfd{.{
        .fd = std.Io.File.stdin().handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&poll_fds, 0) catch 0;
    if (ready == 0) return;

    var byte: [1]u8 = undefined;
    const n = std.posix.read(std.Io.File.stdin().handle, &byte) catch 0;
    if (n == 0) return;
    logSpinnerByte("spinner", byte[0]);

    var is_cancel_key = byte[0] == 0x03; // Ctrl+C (raw)
    const is_escape = byte[0] == 0x1b;
    var is_bare_escape = false;

    if (is_escape) {
        // Check if bare Escape (no CSI follow-up within 30ms)
        var poll2 = [1]std.posix.pollfd{.{
            .fd = std.Io.File.stdin().handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready2 = std.posix.poll(&poll2, 30) catch 0;
        if (ready2 == 0) {
            is_bare_escape = true;
        } else {
            // Read the rest of the escape sequence (arrow keys, mouse, Kitty keys).
            // Read byte-by-byte until we hit a CSI final byte (0x40-0x7E). Some terminals
            // deliver the sequence in multiple chunks, so a single read() can get partial data.
            var seq_buf: [32]u8 = undefined;
            var seq_n: usize = 0;
            var read_guard: usize = 0;
            while (seq_n < seq_buf.len and read_guard < 64) : (read_guard += 1) {
                var rpoll = [1]std.posix.pollfd{.{
                    .fd = std.Io.File.stdin().handle,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                const rready = std.posix.poll(&rpoll, 20) catch 0;
                if (rready == 0) break;
                var rb: [1]u8 = undefined;
                const rn = std.posix.read(std.Io.File.stdin().handle, &rb) catch 0;
                if (rn == 0) break;
                logSpinnerByte("spinner-seq", rb[0]);
                seq_buf[seq_n] = rb[0];
                seq_n += 1;
                if (seq_n >= 2 and rb[0] >= 0x40 and rb[0] <= 0x7E) break;
            }
            // Detect Kitty-encoded Ctrl+C: ESC [ 99 ; 5 u or ESC [ 3 ; 5 u
            if (seq_n >= 4 and seq_buf[0] == '[' and seq_buf[seq_n - 1] == 'u') {
                // Parse codepoint;mods
                var cp: usize = 0;
                var mods: usize = 0;
                var i: usize = 1;
                var in_mods = false;
                while (i < seq_n - 1) : (i += 1) {
                    const c = seq_buf[i];
                    if (c == ';') {
                        in_mods = true;
                        continue;
                    }
                    if (c < '0' or c > '9') break;
                    if (in_mods) {
                        mods = mods * 10 + (c - '0');
                    } else {
                        cp = cp * 10 + (c - '0');
                    }
                }
                const has_ctrl = mods >= 5 and (((mods - 1) & 4) != 0);
                // Ctrl+C via Kitty: cp=99 ('c') or cp=67 ('C') with ctrl, or cp=3 raw
                if ((has_ctrl and (cp == 99 or cp == 67)) or cp == 3) {
                    is_cancel_key = true;
                }
                // Kitty bare Escape: cp=27
                if (cp == 27) {
                    is_bare_escape = true;
                }
            }
            if (seq_n >= 2 and seq_buf[0] == '[') {
                // Scroll step sizes. Matches the reference's
                // src/utils/keyboard.ts: arrow keys move 1 row at a
                // time for fine-grained "smooth" control, Page Up/
                // Down jump 10 rows, mouse wheel is 3 (the OS
                // standard). We were previously using 3 for arrows,
                // which felt coarse and jumpy.
                const ARROW_STEP: i32 = 1;
                const PAGE_STEP: i32 = 10;
                const WHEEL_STEP: i32 = 3;

                var scroll_change: i32 = 0;
                if (seq_buf[1] == 'A') {
                    scroll_change = ARROW_STEP;
                } else if (seq_buf[1] == 'B') {
                    scroll_change = -ARROW_STEP;
                } else if (seq_n >= 3 and seq_buf[1] == '5' and seq_buf[2] == '~') {
                    // Page Up: ESC [ 5 ~
                    scroll_change = PAGE_STEP;
                } else if (seq_n >= 3 and seq_buf[1] == '6' and seq_buf[2] == '~') {
                    // Page Down: ESC [ 6 ~
                    scroll_change = -PAGE_STEP;
                } else if (seq_buf[1] == '<' and seq_n >= 4) {
                    // SGR mouse: ESC [ < Cb ; Cx ; Cy M/m
                    var btn: usize = 0;
                    var i: usize = 2;
                    while (i < seq_n and seq_buf[i] >= '0' and seq_buf[i] <= '9') : (i += 1) {
                        btn = btn * 10 + (seq_buf[i] - '0');
                    }
                    if (btn == 64) scroll_change = WHEEL_STEP;
                    if (btn == 65) scroll_change = -WHEEL_STEP;
                } else if (seq_buf[1] == 'M' and seq_n >= 4) {
                    // X10 mouse: ESC [ M Cb Cx Cy
                    const code: u8 = if (seq_buf[2] >= 32) seq_buf[2] - 32 else seq_buf[2];
                    if ((code & 0x7f) == 64) scroll_change = WHEEL_STEP;
                    if ((code & 0x7f) == 65) scroll_change = -WHEEL_STEP;
                }
                if (scroll_change != 0) {
                    _ = if (scroll_change > 0)
                        state.scroll_offset_delta.fetchAdd(scroll_change, .release)
                    else
                        state.scroll_offset_delta.fetchSub(-scroll_change, .release);
                    state.mutex.lock(rt.io) catch {};
                    if (scroll_change > 0) {
                        state.live_scroll_offset +|= @intCast(scroll_change);
                    } else {
                        state.live_scroll_offset -|= @as(usize, @intCast(-scroll_change));
                    }
                    // Rate-limit the synchronous live redraw callback
                    // to ~60 fps. A fast wheel burst can fire 50+
                    // events/second; firing redraw_fn per event used
                    // to stall the spinner thread against main-thread
                    // work and made zcode appear unresponsive after
                    // a scroll. The cumulative delta is already in
                    // scroll_offset_delta, so coalesced events still
                    // produce the correct final scroll position --
                    // we just skip drawing each intermediate step.
                    const now_ns = clock.nowNanos();
                    const since_last_ns = now_ns - state.last_live_redraw_ns;
                    const allow_redraw = since_last_ns >= 16 * std.time.ns_per_ms;
                    var redraw_ctx: ?*anyopaque = null;
                    var redraw_fn: ?LiveRedrawCallback = null;
                    if (allow_redraw) {
                        state.last_live_redraw_ns = now_ns;
                        redraw_ctx = state.live_redraw_ctx;
                        redraw_fn = state.live_redraw_fn;
                    }
                    state.mutex.unlock(rt.io);
                    state.scroll_render_needed.store(true, .release);
                    if (redraw_ctx != null and redraw_fn != null) {
                        redraw_fn.?(redraw_ctx.?, scroll_change);
                    }
                }
            }
        }
    }

    // If cancel already requested, Ctrl+C forces immediate exit
    if (state.cancel_requested.load(.acquire)) {
        if (is_cancel_key) {
            state.write_mutex.lock(rt.io) catch {};
            _ = std.c.write(std.Io.File.stdout().handle, ("\r\x1b[2K\x1b[31m[force exit]\x1b[0m\n").ptr, ("\r\x1b[2K\x1b[31m[force exit]\x1b[0m\n").len);
            state.write_mutex.unlock(rt.io);
            const stdout_h = std.Io.File.stdout().handle;
            _ = std.c.write(stdout_h, ("\x1b[?1049l").ptr, ("\x1b[?1049l").len);
            _ = std.c.write(stdout_h, ("\x1b[0m\n").ptr, ("\x1b[0m\n").len);
            _ = std.process.run(std.heap.page_allocator, rt.io, .{
                .argv = &.{ "stty", "sane" },
                .stdout_limit = .limited(64),
                .stderr_limit = .limited(64),
            }) catch {};
            std.process.exit(130);
        }
        return;
    }

    if (is_cancel_key or is_bare_escape) {
        const now_s = clock.nowSeconds();
        const last = state.last_escape_ts.load(.acquire);
        if (now_s - last > 3) {
            state.escape_press_count.store(1, .release);
        } else {
            _ = state.escape_press_count.fetchAdd(1, .release);
        }
        state.last_escape_ts.store(now_s, .release);

        const count = state.escape_press_count.load(.acquire);
        if (count >= 2 or is_cancel_key) {
            state.cancel_requested.store(true, .release);
            // Esc-Esc / Ctrl+C is a hard interrupt: record the reason so the
            // agent loop's abort path emits the interruption message (task 22.1).
            http_common.requestCancel(.hard);
            state.write_mutex.lock(rt.io) catch {};
            _ = std.c.write(std.Io.File.stdout().handle, ("\r\x1b[2K\x1b[33m[cancelled - press Ctrl+C to force exit]\x1b[0m\n").ptr, ("\r\x1b[2K\x1b[33m[cancelled - press Ctrl+C to force exit]\x1b[0m\n").len);
            state.write_mutex.unlock(rt.io);
        } else {
            state.write_mutex.lock(rt.io) catch {};
            _ = std.c.write(std.Io.File.stdout().handle, ("\r\x1b[2K\x1b[33m[press Esc or Ctrl+C again to cancel]\x1b[0m").ptr, ("\r\x1b[2K\x1b[33m[press Esc or Ctrl+C again to cancel]\x1b[0m").len);
            state.write_mutex.unlock(rt.io);
        }
        return;
    }

    if (byte[0] == '\r' or byte[0] == '\n') {
        // Enter during thinking: push the typed buffer onto the
        // multi-slot prompt queue and clear the buffer so the user
        // can immediately type ANOTHER queued prompt on top. Ported
        // from claude-code-main's messageQueueManager.ts FIFO model
        // -- stack up as many messages as they want, the agent
        // drains them in order after the current turn completes.
        state.mutex.lock(rt.io) catch {};
        const pushed = state.enqueuePromptFromBufferLocked();
        const depth = state.prompt_queue_count;
        state.mutex.unlock(rt.io);

        if (pushed) {
            state.queued_input_submitted.store(true, .release);
            // Record the submit-interrupt reason (task 22.1). zcode's prompt
            // queue is between-turns FIFO: enqueuing here does NOT kill the
            // in-flight request, so we set the reason tag WITHOUT calling
            // requestCancel (which would kill the curl and change the existing
            // queueing UX). isCancelRequested() stays false and the current
            // turn finishes normally; the reason is only consulted by the
            // abort path if a hard interrupt later sets the bool flag.
            http_common.cancel_reason.store(
                @intFromEnum(http_common.CancelReason.submit_interrupt),
                .release,
            );
            var msg_buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "\r\x1b[2K\x1b[36m[queued: {d} pending]\x1b[0m", .{depth}) catch "\r\x1b[2K\x1b[36m[queued]\x1b[0m";
            state.write_mutex.lock(rt.io) catch {};
            _ = std.c.write(std.Io.File.stdout().handle, (msg).ptr, (msg).len);
            state.write_mutex.unlock(rt.io);
        } else if (state.queued_input_len > 0) {
            // Buffer had content but queue is full -- let the user know
            // their newest prompt was rejected rather than silently dropped.
            state.write_mutex.lock(rt.io) catch {};
            _ = std.c.write(std.Io.File.stdout().handle, ("\r\x1b[2K\x1b[33m[queue full, max 8 pending]\x1b[0m").ptr, ("\r\x1b[2K\x1b[33m[queue full, max 8 pending]\x1b[0m").len);
            state.write_mutex.unlock(rt.io);
        }
    } else if (byte[0] == 0x7f or byte[0] == 0x08) {
        state.mutex.lock(rt.io) catch {};
        if (state.queued_input_len > 0) state.queued_input_len -= 1;
        state.mutex.unlock(rt.io);
    } else if (byte[0] >= 0x20 and byte[0] != 0x7f) {
        state.mutex.lock(rt.io) catch {};
        if (state.queued_input_len < state.queued_input.len) {
            state.queued_input[state.queued_input_len] = byte[0];
            state.queued_input_len += 1;
        }
        state.mutex.unlock(rt.io);
    }
}

pub fn clearSpinnerLine(fixed_input_border: bool, bottom_margin_rows: usize) void {
    if (!fixed_input_border) {
        const clear_seq = "\r\x1b[2K\r";
        _ = std.c.write(std.Io.File.stdout().handle, (clear_seq).ptr, (clear_seq).len);
        return;
    }

    const thinking_row = thinkingRow(bottom_margin_rows);
    var seq_buf: [96]u8 = undefined;
    const clear_seq = std.fmt.bufPrint(&seq_buf, "\x1b7\x1b[{d};1H\x1b[2K\x1b8", .{thinking_row}) catch return;
    _ = std.c.write(std.Io.File.stdout().handle, (clear_seq).ptr, (clear_seq).len);
}

/// Mirror of the renderer's input-box layout math so the spinner can
/// place the "thinking" line one row above the composer's top border
/// instead of landing on the input text row. Assumes the input box is
/// a single text line (true during turns, when the prompt was just
/// submitted); multi-line queued input nudges the thinking line by at
/// most one row and is acceptable.
fn thinkingRow(bottom_margin_rows: usize) usize {
    return composerTopRow(bottom_margin_rows) -| 1;
}

/// Row index of the composer's top border (" ask zcode  exec "). The
/// streaming painter in repl_agent uses this to bound the scroll
/// region so chat text never bleeds into the input box's chrome.
pub fn composerTopRow(bottom_margin_rows: usize) usize {
    const rows = terminalRows();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;
    const chrome_gutter: usize = if (rows >= 14) 1 else 0;
    const footer_row = if (status_row > chrome_gutter + 1) status_row - chrome_gutter - 1 else 1;
    const input_bottom_row = if (footer_row > chrome_gutter + 1) footer_row - chrome_gutter - 1 else 1;
    // input_bottom_row -> input row -> top border == 2 rows up.
    return if (input_bottom_row > 2) input_bottom_row - 2 else 1;
}

fn buildFixedSpinnerFrame(
    out: *[1536]u8,
    frame: []const u8,
    latest: []const u8,
    frame_idx: usize,
    elapsed_ms: u64,
    bottom_margin_rows: usize,
    tool_count: usize,
    queued_count: usize,
) ![]const u8 {
    const cols = terminalCols();
    const thinking_row = thinkingRow(bottom_margin_rows);
    var status_buf: [768]u8 = undefined;
    const status = buildThinkingStatusLine(&status_buf, cols, frame, frame_idx, elapsed_ms, latest, tool_count, queued_count);
    return std.fmt.bufPrint(out, "\x1b7\x1b[{d};1H\x1b[2K{s}\x1b8", .{ thinking_row, status });
}

fn buildThinkingStatusLine(out: []u8, cols: usize, frame: []const u8, frame_idx: usize, elapsed_ms: u64, latest: []const u8, tool_count: usize, queued_count: usize) []const u8 {
    var pulse_buf: [64]u8 = undefined;
    const pulse = buildActivityPulse(&pulse_buf, frame_idx);
    const secs = elapsed_ms / 1000;
    const tenths = (elapsed_ms % 1000) / 100;

    // If no tool has fired and the spinner has been running for more than
    // 5 seconds with the default label, the turn is almost certainly
    // waiting on slow provider prefill (common with large local models
    // + big tool-result context). Surface a clearer message so users
    // can distinguish "the model is computing" from "zcode is stuck".
    const is_default = latest.len == 0 or std.mem.eql(u8, latest, "working");
    const stalled = is_default and tool_count == 0 and secs >= 5;
    const label = if (stalled)
        "waiting for model response"
    else if (is_default)
        "thinking"
    else
        latest;

    // layout: "<frame> <pulse> <label>  <tools> <queued> <timer>"
    const frame_vis: usize = 2;
    const pulse_vis: usize = pulseVisualWidth(pulse);
    const timer_vis: usize = 8;
    const tools_vis: usize = if (tool_count > 0) 12 else 0; // " | N tools"
    const queued_vis: usize = if (queued_count > 0) 14 else 0; // " | N queued"
    const overhead = frame_vis + pulse_vis + timer_vis + tools_vis + queued_vis;
    const max_label_cols = if (cols > overhead + 1) cols - overhead - 1 else 0;

    const truncated_label = if (label.len > max_label_cols) label[0..max_label_cols] else label;

    // Render the status line segment by segment. Fourteen combinations
    // of tool_count + queued_count are possible but all reduce to
    // "start with label + tools?, optional '| N queued', then timer".
    var line_buf: [768]u8 = undefined;
    const full = blk: {
        if (tool_count > 0 and queued_count > 0) {
            break :blk std.fmt.bufPrint(&line_buf, "\x1b[2m{s}\x1b[0m {s} {s} \x1b[2m| {d} tools | {d} queued | {d}.{d}s\x1b[0m", .{ frame, pulse, truncated_label, tool_count, queued_count, secs, tenths }) catch "thinking";
        }
        if (tool_count > 0) {
            break :blk std.fmt.bufPrint(&line_buf, "\x1b[2m{s}\x1b[0m {s} {s} \x1b[2m| {d} tools | {d}.{d}s\x1b[0m", .{ frame, pulse, truncated_label, tool_count, secs, tenths }) catch "thinking";
        }
        if (queued_count > 0) {
            break :blk std.fmt.bufPrint(&line_buf, "\x1b[2m{s}\x1b[0m {s} {s} \x1b[2m| {d} queued | {d}.{d}s\x1b[0m", .{ frame, pulse, truncated_label, queued_count, secs, tenths }) catch "thinking";
        }
        break :blk std.fmt.bufPrint(&line_buf, "\x1b[2m{s}\x1b[0m {s} {s}  \x1b[2m{d}.{d}s\x1b[0m", .{ frame, pulse, truncated_label, secs, tenths }) catch "thinking";
    };
    const draw_cols = if (cols > 1) cols - 1 else cols;
    const max_take = @min(draw_cols, out.len);
    const take = @min(max_take, full.len);
    if (take > 0) {
        @memcpy(out[0..take], full[0..take]);
    }
    return out[0..take];
}

/// Compute the visual (printable) width of a pulse string, skipping ANSI escape sequences.
pub fn pulseVisualWidth(pulse: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < pulse.len) {
        if (pulse[i] == '\x1b') {
            // Skip ESC [ ... m sequence
            i += 1;
            if (i < pulse.len and pulse[i] == '[') {
                i += 1;
                while (i < pulse.len and pulse[i] != 'm') : (i += 1) {}
                if (i < pulse.len) i += 1; // skip 'm'
            }
        } else {
            width += 1;
            i += 1;
        }
    }
    return width;
}

pub fn buildActivityPulse(out: []u8, frame_idx: usize) []const u8 {
    // Single-cell braille spinner. Replaces the 8-cell bouncing-dot
    // pulse which dominated the status line with sideways motion. The
    // braille glyph rotates in place - one point of motion, same
    // monochrome dim treatment as the rest of the status line, so
    // the eye registers "something is happening" without anything
    // crawling across the screen.
    const frames = [_][]const u8{
        "\xe2\xa0\x8b", // ⠋
        "\xe2\xa0\x99", // ⠙
        "\xe2\xa0\xb9", // ⠹
        "\xe2\xa0\xb8", // ⠸
        "\xe2\xa0\xbc", // ⠼
        "\xe2\xa0\xb4", // ⠴
        "\xe2\xa0\xa6", // ⠦
        "\xe2\xa0\xa7", // ⠧
        "\xe2\xa0\x87", // ⠇
        "\xe2\xa0\x8f", // ⠏
    };
    const frame = frames[frame_idx % frames.len];

    var fbs = std.Io.Writer.fixed(out);
    const w = &fbs;
    w.writeAll("\x1b[2m") catch {};
    w.writeAll(frame) catch {};
    w.writeAll("\x1b[0m") catch {};
    return out[0..fbs.end];
}

/// Extract the "action prefix" of a progress message for dedupe.
/// The prefix is everything up to the first '|' separator, trimmed of
/// trailing whitespace. When the message has no pipe, the whole
/// message is the prefix. Used by SpinnerState.update to collapse
/// repeated "calling model X | ... | Nm Ns" ticks into a single slot
/// that updates in place.
pub fn actionPrefix(text: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, text, '|')) |idx| {
        return std.mem.trimEnd(u8, text[0..idx], " \t");
    }
    return text;
}

pub fn normalizeSummary(input: []const u8, out: *[80]u8) []const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return "";

    // Strip ANSI escape sequences so a tool argument or progress
    // message containing a hostile CSI / OSC payload cannot reach the
    // user's terminal unchanged. Progress text is formatted from
    // LLM-controlled tool arguments (paths, commands, URLs) and gets
    // rendered by the spinner thread directly via posix write; without
    // this filter, the same class of escape injection that pass 37
    // closed in the card UI would still be live on the spinner line.
    var o: usize = 0;
    var i: usize = 0;
    while (i < trimmed.len and o < out.len) {
        const ch = trimmed[i];
        if (ch == 0x1b) {
            i += ansiEscapeSkipLength(trimmed[i..]);
            continue;
        }
        if (ch == '\t' or (ch >= 0x20 and ch != 0x7f)) {
            out[o] = ch;
            o += 1;
        }
        i += 1;
    }
    return out[0..o];
}

/// Return how many bytes of `text` form the ANSI escape sequence
/// beginning at `text[0]` (which must be 0x1b). Mirrors the same
/// CSI / OSC / Fe-Fs handling used by the card sanitizer in
/// repl_edit.zig so a single fix keeps both surfaces in step.
fn ansiEscapeSkipLength(text: []const u8) usize {
    if (text.len == 0 or text[0] != 0x1b) return 1;
    if (text.len == 1) return 1;

    const second = text[1];
    if (second == '[') {
        var i: usize = 2;
        while (i < text.len) : (i += 1) {
            const ch = text[i];
            if (ch >= 0x40 and ch <= 0x7e) return i + 1;
        }
        return text.len;
    }
    if (second == ']') {
        var i: usize = 2;
        while (i < text.len) : (i += 1) {
            if (text[i] == 0x07) return i + 1;
            if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '\\') return i + 2;
        }
        return text.len;
    }
    return @min(text.len, @as(usize, 2));
}

/// Colourful fallback verbs for the spinner header when there's no
/// structured phase label ("Running Tools", "Calling Model", etc) to
/// show. Ported verbatim from Claude Code's
/// src/constants/spinnerVerbs.ts SPINNER_VERBS list. The reference
/// picks one verb per turn and holds it for the duration; zcode does
/// the same by seeding the pick off the turn's started_ns timestamp.
/// Single-call deriveThinkingTopicTitle paths that don't have a seed
/// available still get a deterministic "Thinking" -- the variety is
/// strictly additive.
pub const SPINNER_VERBS = [_][]const u8{
    "Accomplishing",   "Actioning",         "Actualizing",        "Architecting",       "Baking",
    "Beaming",         "Beboppin'",         "Befuddling",         "Billowing",          "Blanching",
    "Bloviating",      "Boogieing",         "Boondoggling",       "Booping",            "Bootstrapping",
    "Brewing",         "Bunning",           "Burrowing",          "Calculating",        "Canoodling",
    "Caramelizing",    "Cascading",         "Catapulting",        "Cerebrating",        "Channeling",
    "Channelling",     "Choreographing",    "Churning",           "Clauding",           "Coalescing",
    "Cogitating",      "Combobulating",     "Composing",          "Computing",          "Concocting",
    "Considering",     "Contemplating",     "Cooking",            "Crafting",           "Creating",
    "Crunching",       "Crystallizing",     "Cultivating",        "Deciphering",        "Deliberating",
    "Determining",     "Dilly-dallying",    "Discombobulating",   "Doing",              "Doodling",
    "Drizzling",       "Ebbing",            "Effecting",          "Elucidating",        "Embellishing",
    "Enchanting",      "Envisioning",       "Evaporating",        "Fermenting",         "Fiddle-faddling",
    "Finagling",       "Flamb\xc3\xa9ing",  "Flibbertigibbeting", "Flowing",            "Flummoxing",
    "Fluttering",      "Forging",           "Forming",            "Frolicking",         "Frosting",
    "Gallivanting",    "Galloping",         "Garnishing",         "Generating",         "Gesticulating",
    "Germinating",     "Gitifying",         "Grooving",           "Gusting",            "Harmonizing",
    "Hashing",         "Hatching",          "Herding",            "Honking",            "Hullaballooing",
    "Hyperspacing",    "Ideating",          "Imagining",          "Improvising",        "Incubating",
    "Inferring",       "Infusing",          "Ionizing",           "Jitterbugging",      "Julienning",
    "Kneading",        "Leavening",         "Levitating",         "Lollygagging",       "Manifesting",
    "Marinating",      "Meandering",        "Metamorphosing",     "Misting",            "Moonwalking",
    "Moseying",        "Mulling",           "Mustering",          "Musing",             "Nebulizing",
    "Nesting",         "Newspapering",      "Noodling",           "Nucleating",         "Orbiting",
    "Orchestrating",   "Osmosing",          "Perambulating",      "Percolating",        "Perusing",
    "Philosophising",  "Photosynthesizing", "Pollinating",        "Pondering",          "Pontificating",
    "Pouncing",        "Precipitating",     "Prestidigitating",   "Processing",         "Proofing",
    "Propagating",     "Puttering",         "Puzzling",           "Quantumizing",       "Razzle-dazzling",
    "Razzmatazzing",   "Recombobulating",   "Reticulating",       "Roosting",           "Ruminating",
    "Saut\xc3\xa9ing", "Scampering",        "Schlepping",         "Scurrying",          "Seasoning",
    "Shenaniganing",   "Shimmying",         "Simmering",          "Skedaddling",        "Sketching",
    "Slithering",      "Smooshing",         "Sock-hopping",       "Spelunking",         "Spinning",
    "Sprouting",       "Stewing",           "Sublimating",        "Swirling",           "Swooping",
    "Symbioting",      "Synthesizing",      "Tempering",          "Thinking",           "Thundering",
    "Tinkering",       "Tomfoolering",      "Topsy-turvying",     "Transfiguring",      "Transmuting",
    "Twisting",        "Undulating",        "Unfurling",          "Unravelling",        "Vibing",
    "Waddling",        "Wandering",         "Warping",            "Whatchamacalliting", "Whirlpooling",
    "Whirring",        "Whisking",          "Wibbling",           "Working",            "Wrangling",
    "Zesting",         "Zigzagging",
};

/// Past-tense verbs used when a turn finishes. Reads naturally as
/// "Worked for 5s" / "Brewed for 12s". Ported verbatim from
/// claude-code-main/src/constants/turnCompletionVerbs.ts. The
/// reference picks one per turn-completion message; we do the same
/// via getTurnCompletionVerb, seeded off the turn's start timestamp.
pub const TURN_COMPLETION_VERBS = [_][]const u8{
    "Baked",  "Brewed",   "Churned",        "Cogitated",
    "Cooked", "Crunched", "Saut\xc3\xa9ed", "Worked",
};

/// Deterministically pick a past-tense completion verb for the given
/// seed. Uses the same hash as getSpinnerVerb so callers can reuse
/// the turn's started_ns timestamp. Seed 0 returns a stable default.
pub fn getTurnCompletionVerb(seed: i128) []const u8 {
    if (TURN_COMPLETION_VERBS.len == 0) return "Worked";
    if (seed == 0) return "Worked";
    var h: u64 = @bitCast(@as(i64, @truncate(seed)));
    h ^= h >> 33;
    h *%= 0xff51afd7ed558ccd;
    h ^= h >> 33;
    h *%= 0xc4ceb9fe1a85ec53;
    h ^= h >> 33;
    return TURN_COMPLETION_VERBS[h % TURN_COMPLETION_VERBS.len];
}

/// Pick a spinner verb deterministically from a seed (usually the
/// turn's started_ns timestamp). A seed of 0 picks index 0 ("Accomplishing").
/// Deterministic-per-seed means the chosen verb stays stable while the
/// spinner ticks through a single turn; advancing to the next turn
/// (which updates started_ns) rolls a fresh verb.
pub fn getSpinnerVerb(seed: i128) []const u8 {
    if (SPINNER_VERBS.len == 0) return "Thinking";
    // Hash the seed with a simple xor-fold so tiny deltas in started_ns
    // give noticeably different indices. We don't need cryptographic
    // quality -- we just want a stable index that varies between turns.
    var h: u64 = @bitCast(@as(i64, @truncate(seed)));
    h ^= h >> 33;
    h *%= 0xff51afd7ed558ccd;
    h ^= h >> 33;
    h *%= 0xc4ceb9fe1a85ec53;
    h ^= h >> 33;
    return SPINNER_VERBS[h % SPINNER_VERBS.len];
}

pub fn deriveThinkingTopicTitle(summary: []const u8, out: *[96]u8) []const u8 {
    return deriveThinkingTopicTitleWithSeed(summary, 0, out);
}

pub fn deriveThinkingTopicTitleWithSeed(summary: []const u8, seed: i128, out: *[96]u8) []const u8 {
    if (std.mem.indexOf(u8, summary, "capturing user request") != null) return "Understanding Request";
    if (std.mem.indexOf(u8, summary, "planning request") != null) return "Planning";
    if (std.mem.indexOf(u8, summary, "gathering context") != null) return "Gathering Context";
    if (std.mem.indexOf(u8, summary, "executing") != null and std.mem.indexOf(u8, summary, "tool") != null) return "Running Tools";
    if (std.mem.indexOf(u8, summary, "running tool") != null) return "Running Tools";
    if (std.mem.indexOf(u8, summary, "calling model") != null) return "Calling Model";
    if (std.mem.indexOf(u8, summary, "preparing final response") != null) return "Preparing Response";
    if (std.mem.indexOf(u8, summary, "saving session state") != null) return "Saving Session";
    if (std.mem.indexOf(u8, summary, "done") != null) return "Completing Turn";

    var clip = summary;
    if (std.mem.indexOf(u8, summary, "->")) |idx| {
        clip = std.mem.trim(u8, summary[0..idx], " \t");
    }
    if (clip.len == 0) {
        // No structured phase and no latest progress line -- fall back
        // to a Claude-Code-style colourful verb keyed off the turn's
        // started_ns seed. If seed == 0 (older callers), return a
        // stable default so existing tests stay deterministic.
        return if (seed == 0) "Thinking" else getSpinnerVerb(seed);
    }

    const take = @min(clip.len, out.len);
    @memcpy(out[0..take], clip[0..take]);
    return out[0..take];
}

/// Filters streaming chunks to extract only the assistant text from JSON model output.
/// For non-JSON output (plain text), passes through unchanged.
/// For JSON output like {"assistant": "text here", "tool_calls": [...]}, only emits
/// the content of the "assistant" value string with JSON escapes decoded.
fn flushPeekToOut(
    filter: *SpinnerState.StreamFilterState,
    out: *[4096]u8,
    out_len: *usize,
) void {
    // Append the accumulated peek buffer to `out` without stomping the
    // bytes we've already emitted. The earlier code wrote from out[0..]
    // and clobbered prose that had been streamed before a tool-call
    // envelope caused mode to cycle unknown -> passthrough -> skip ->
    // unknown -> passthrough.
    const room = out.len - out_len.*;
    const copy = @min(filter.peek_len, room);
    if (copy > 0) {
        @memcpy(out[out_len.*..][0..copy], filter.peek_buf[0..copy]);
        out_len.* += copy;
        filter.last_passthrough_byte = filter.peek_buf[copy - 1];
    }
    // Reset the peek window so the next unknown->X transition starts
    // from a clean slate instead of reusing stale bytes.
    filter.peek_len = 0;
}

pub fn filterStreamChunk(filter: *SpinnerState.StreamFilterState, chunk: []const u8, out: *[4096]u8) []const u8 {
    var out_len: usize = 0;

    for (chunk) |ch| {
        switch (filter.mode) {
            .unknown => {
                // Accumulate until we can determine if it's JSON or plain text
                if (filter.peek_len < filter.peek_buf.len) {
                    filter.peek_buf[filter.peek_len] = ch;
                    filter.peek_len += 1;
                }
                // Skip leading whitespace when determining mode
                const trimmed = std.mem.trimStart(u8, filter.peek_buf[0..filter.peek_len], " \t\r\n");
                if (trimmed.len == 0) continue;

                if (trimmed[0] == '{') {
                    // Looks like JSON -- check if we have enough to find "assistant"
                    if (std.mem.indexOf(u8, trimmed, "\"assistant\"")) |_| {
                        // Find the value start: skip `"assistant"` then `:` then whitespace then `"`
                        if (findAssistantValueStart(trimmed)) |val_start| {
                            filter.mode = .json;
                            filter.phase = .in_value;
                            filter.in_escape = false;
                            // Process remaining bytes in peek buffer after the value start
                            const remaining = trimmed[val_start..];
                            for (remaining) |vch| {
                                if (extractAssistantChar(filter, vch)) |decoded| {
                                    if (out_len < out.len) {
                                        out[out_len] = decoded;
                                        out_len += 1;
                                    }
                                }
                                if (filter.phase == .done) break;
                            }
                        }
                        // If we found "assistant" but not the value start yet, keep accumulating
                    } else if (looksLikeToolCallJson(trimmed)) {
                        // Function-call JSON like {"type":"function",...} or {"name":"shell",...}
                        // Switch to skip_json_block mode and consume the entire object.
                        filter.mode = .skip_json_block;
                        filter.skip_depth = 0;
                        filter.skip_in_string = false;
                        filter.skip_esc = false;
                        // Process the peek buffer through the skip logic
                        for (filter.peek_buf[0..filter.peek_len]) |sch| {
                            advanceSkipState(filter, sch);
                            if (filter.skip_depth == 0 and filter.mode == .unknown) break;
                        }
                        // If block already closed, fall through to re-evaluate
                    }
                    // Keep accumulating in unknown mode until we find the key+value or overflow
                    if (filter.peek_len >= filter.peek_buf.len and filter.mode == .unknown) {
                        // Buffer full without finding "assistant" value -- treat as passthrough
                        filter.mode = .passthrough;
                        flushPeekToOut(filter, out, &out_len);
                    }
                } else {
                    // Not JSON -- passthrough mode, flush accumulated peek buffer
                    filter.mode = .passthrough;
                    flushPeekToOut(filter, out, &out_len);
                }
            },
            .passthrough => {
                // Mid-stream re-entry into skip_json_block. When the
                // model has been narrating and suddenly emits a tool-
                // call envelope (common with local Qwen/Minimax builds
                // that don't split tool_use from text), we need to
                // swallow the envelope instead of letting it paint the
                // user's transcript.
                if (filter.reentry_active) {
                    if (filter.reentry_len < filter.reentry_buf.len) {
                        filter.reentry_buf[filter.reentry_len] = ch;
                        filter.reentry_len += 1;
                    }

                    const peek = filter.reentry_buf[0..filter.reentry_len];
                    const is_envelope = looksLikeMidStreamEnvelope(peek);
                    const buffer_full = filter.reentry_len >= filter.reentry_buf.len;

                    // Early "looks like prose" commit. Once we have ~16
                    // bytes we can tell apart a tool-call envelope (key
                    // names like "tool_calls", "name", "function",
                    // "assistant" show up in the first handful of
                    // bytes) from a benign snippet that happens to
                    // begin a line with `{` or backtick. Flushing early
                    // in the benign case keeps streaming latency low.
                    var prose_confident = false;
                    if (filter.reentry_len >= 16 and !is_envelope) {
                        const starts_with_backtick = peek.len > 0 and peek[0] == '`';
                        if (starts_with_backtick) {
                            const has_json_opener = std.mem.indexOf(u8, peek, "{") != null or
                                std.mem.indexOf(u8, peek, "[") != null or
                                std.mem.indexOf(u8, peek, "json") != null or
                                std.mem.indexOf(u8, peek, "tool") != null;
                            if (!has_json_opener) prose_confident = true;
                        } else {
                            // Also treat "control" as an envelope hint.
                            // Qwen / minimax local models emit shapes
                            // like `{"tool_calls":[],"control":{"continue":true}}`
                            // when they want to signal "keep going" with
                            // no new tool calls -- the tool_calls array
                            // is empty, so my original probe for "\"tool"
                            // is technically satisfied but the short
                            // empty-array form `"tool_calls":[]` slips
                            // past before it appears in the peek window.
                            // "control" is the disambiguating second key.
                            const has_envelope_hint = std.mem.indexOf(u8, peek, "\"tool") != null or
                                std.mem.indexOf(u8, peek, "\"name") != null or
                                std.mem.indexOf(u8, peek, "\"function") != null or
                                std.mem.indexOf(u8, peek, "\"assistant") != null or
                                std.mem.indexOf(u8, peek, "\"args") != null or
                                std.mem.indexOf(u8, peek, "\"parameters") != null or
                                std.mem.indexOf(u8, peek, "\"control") != null;
                            if (!has_envelope_hint) prose_confident = true;
                        }
                    }

                    const decided = is_envelope or buffer_full or prose_confident;

                    if (decided) {
                        if (is_envelope) {
                            // Fence prefix (backtick + language tag) is
                            // discarded entirely. Locate the first '{'
                            // or '[' and replay only the JSON bytes
                            // through the skip-state machine so the
                            // depth counter lines up with reality.
                            const json_start = firstJsonStart(peek) orelse 0;
                            filter.mode = .skip_json_block;
                            filter.skip_depth = 0;
                            filter.skip_in_string = false;
                            filter.skip_esc = false;
                            for (peek[json_start..]) |pch| {
                                advanceSkipState(filter, pch);
                            }
                        } else {
                            // Not an envelope after all. Flush the
                            // buffered bytes back to the output so the
                            // user sees the original prose verbatim.
                            const room = out.len - out_len;
                            const copy = @min(peek.len, room);
                            @memcpy(out[out_len..][0..copy], peek[0..copy]);
                            out_len += copy;
                            if (peek.len > 0) {
                                filter.last_passthrough_byte = peek[peek.len - 1];
                            }
                        }
                        filter.reentry_active = false;
                        filter.reentry_len = 0;
                    }
                    continue;
                }

                const at_line_start = filter.last_passthrough_byte == '\n';
                if (at_line_start and (ch == '{' or ch == '`')) {
                    filter.reentry_active = true;
                    filter.reentry_buf[0] = ch;
                    filter.reentry_len = 1;
                    continue;
                }

                if (out_len < out.len) {
                    out[out_len] = ch;
                    out_len += 1;
                    filter.last_passthrough_byte = ch;
                }
            },
            .skip_json_block => {
                advanceSkipState(filter, ch);
                // When block closes, reset to unknown so we can detect the next block
                if (filter.skip_depth == 0 and !filter.skip_in_string and filter.mode == .unknown) {
                    // Already reset by advanceSkipState
                }
            },
            .json => {
                switch (filter.phase) {
                    .scanning => {
                        // Still looking for the assistant value -- shouldn't happen
                        // since we transition to json only after finding it
                    },
                    .in_value => {
                        if (extractAssistantChar(filter, ch)) |decoded| {
                            if (out_len < out.len) {
                                out[out_len] = decoded;
                                out_len += 1;
                            }
                        }
                    },
                    .done => {
                        // Ignore everything after assistant value ends
                    },
                }
            },
        }
    }
    return out[0..out_len];
}

/// Find the byte offset where the assistant string value content starts
/// (after `"assistant"`, `:`, optional whitespace, and opening `"`)
pub fn findAssistantValueStart(text: []const u8) ?usize {
    const key = "\"assistant\"";
    const key_pos = std.mem.indexOf(u8, text, key) orelse return null;
    var i = key_pos + key.len;
    // Skip whitespace and colon
    while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\r' or text[i] == '\n' or text[i] == ':')) : (i += 1) {}
    // Expect opening quote
    if (i < text.len and text[i] == '"') {
        return i + 1; // position after the opening quote
    }
    return null;
}

/// Extract a decoded character from inside the assistant JSON string value.
/// Returns null if the character is consumed (escape sequence prefix) or if the string ends.
pub fn extractAssistantChar(filter: *SpinnerState.StreamFilterState, ch: u8) ?u8 {
    if (filter.in_escape) {
        filter.in_escape = false;
        return switch (ch) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            '\\' => '\\',
            '"' => '"',
            '/' => '/',
            else => ch, // unknown escape, pass through
        };
    }
    if (ch == '\\') {
        filter.in_escape = true;
        return null;
    }
    if (ch == '"') {
        // End of assistant value string
        filter.phase = .done;
        return null;
    }
    return ch;
}

/// Heuristic: does the accumulated buffer look like a tool-call JSON object?
/// Matches patterns like {"type":"function",...} or {"name":"shell",...}
fn looksLikeToolCallJson(text: []const u8) bool {
    // Must contain "type":"function" or ("name":".." + "parameters":...)
    if (std.mem.indexOf(u8, text, "\"type\":\"function\"") != null) return true;
    if (std.mem.indexOf(u8, text, "\"type\": \"function\"") != null) return true;
    if (std.mem.indexOf(u8, text, "\"parameters\"") != null and
        std.mem.indexOf(u8, text, "\"name\"") != null) return true;
    if (std.mem.indexOf(u8, text, "\"tool_call\"") != null) return true;
    // Plural form: Qwen / minimax style `{"tool_calls":[{...}]}`. The
    // earlier check only matched `"tool_call"` (without the trailing s)
    // so the plural variant slipped through and reached the user.
    if (std.mem.indexOf(u8, text, "\"tool_calls\"") != null) return true;
    // Empty tool_calls plus a `"control"` continuation object --
    // Qwen emits `{"tool_calls":[],"control":{"continue":true}}`
    // as a "keep going" signal when it wants another round without
    // calling a tool. Treat as protocol bytes; do not surface.
    if (std.mem.indexOf(u8, text, "\"control\"") != null and
        (std.mem.indexOf(u8, text, "\"continue\"") != null or
            std.mem.indexOf(u8, text, "\"tool_calls\"") != null)) return true;
    if (std.mem.indexOf(u8, text, "\"function\":") != null and
        std.mem.indexOf(u8, text, "\"name\"") != null) return true;
    if (std.mem.indexOf(u8, text, "\"name\"") != null and
        std.mem.indexOf(u8, text, "\"args\"") != null) return true;
    return false;
}

/// Sibling heuristic to `looksLikeToolCallJson` but tuned for the
/// mid-stream re-entry path in the passthrough branch. Accepts either
/// a bare JSON object/array at the start of the buffer, or a markdown
/// fence prefix (backtick + optional `json` / `tool_call` tag) that
/// the model uses to wrap the envelope.
fn looksLikeMidStreamEnvelope(peek: []const u8) bool {
    if (peek.len == 0) return false;
    const trimmed = std.mem.trimStart(u8, peek, " \t\r\n");
    if (trimmed.len == 0) return false;

    if (trimmed[0] == '`') {
        // Fence prefix. Commit to skipping when the tag looks like it
        // could introduce a JSON payload (or when a recognizable tool-
        // call signature shows up in the buffered body).
        const after = std.mem.trimStart(u8, trimmed[1..], "`");
        if (std.mem.startsWith(u8, after, "json")) return true;
        if (std.mem.startsWith(u8, after, "tool_call")) return true;
        if (std.mem.startsWith(u8, after, "tool")) return true;
        return looksLikeToolCallJson(peek);
    }

    if (trimmed[0] != '{' and trimmed[0] != '[') return false;
    return looksLikeToolCallJson(peek);
}

/// Return the offset of the first `{` or `[` in `peek`, or null if
/// neither appears. Used to line up the skip-block depth counter with
/// the actual JSON start when a fence prefix precedes the envelope.
fn firstJsonStart(peek: []const u8) ?usize {
    for (peek, 0..) |c, i| {
        if (c == '{' or c == '[') return i;
    }
    return null;
}

/// Advance the skip-block state machine by one character.
/// When the outer object closes, resets mode to .unknown so subsequent
/// text (or another JSON block) can be detected.
fn advanceSkipState(filter: *SpinnerState.StreamFilterState, ch: u8) void {
    if (filter.skip_esc) {
        filter.skip_esc = false;
        return;
    }
    if (filter.skip_in_string) {
        if (ch == '\\') {
            filter.skip_esc = true;
        } else if (ch == '"') {
            filter.skip_in_string = false;
        }
        return;
    }
    switch (ch) {
        '"' => filter.skip_in_string = true,
        '{', '[' => filter.skip_depth +|= 1,
        '}', ']' => {
            if (filter.skip_depth > 0) filter.skip_depth -= 1;
            if (filter.skip_depth == 0) {
                // Block closed -- reset to detect next chunk
                filter.mode = .unknown;
                filter.peek_len = 0;
            }
        },
        else => {},
    }
}

pub fn terminalRows() usize {
    var winsize: std.posix.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };
    const rc = std.posix.system.ioctl(std.Io.File.stdout().handle, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    if (std.posix.errno(rc) == .SUCCESS and winsize.row > 0) {
        return @as(usize, winsize.row);
    }
    return 25;
}

pub fn terminalCols() usize {
    var winsize: std.posix.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };
    const rc = std.posix.system.ioctl(std.Io.File.stdout().handle, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    if (std.posix.errno(rc) == .SUCCESS and winsize.col > 0) {
        return @as(usize, winsize.col);
    }
    return 100;
}

pub const TAB_WIDTH: usize = 4;

pub fn sanitizeText(input: []const u8, out: []u8) []const u8 {
    return sanitizeTextInternal(input, out, false, false);
}

pub fn sanitizePromptText(input: []const u8, out: []u8) []const u8 {
    var tmp: [16 * 1024]u8 = undefined;
    const clean = sanitizeTextInternal(input, tmp[0..], true, true);
    return normalizeFileUriTokens(clean, out);
}

pub fn sanitizeTextInternal(input: []const u8, out: []u8, keep_newlines: bool, trim_edges: bool) []const u8 {
    var o: usize = 0;
    var i: usize = 0;
    while (i < input.len and o < out.len) : (i += 1) {
        const ch = input[i];

        if (ch == 0x1b) {
            if (i + 1 < input.len and input[i + 1] == '[') {
                i += 2;
                while (i < input.len) : (i += 1) {
                    const c = input[i];
                    if (c >= 0x40 and c <= 0x7E) break;
                }
            }
            continue;
        }

        if (keep_newlines and (ch == '\n' or ch == '\r')) {
            if (ch == '\r' and i + 1 < input.len and input[i + 1] == '\n') continue;
            out[o] = '\n';
            o += 1;
            continue;
        }

        if (ch == '\t') {
            var tab_i: usize = 0;
            while (tab_i < TAB_WIDTH and o < out.len) : (tab_i += 1) {
                out[o] = ' ';
                o += 1;
            }
            continue;
        }

        if (ch < 0x20 or ch == 0x7f) {
            continue;
        }

        out[o] = ch;
        o += 1;
    }

    if (trim_edges) return std.mem.trim(u8, out[0..o], " \t\r\n");
    return out[0..o];
}

pub fn normalizeFileUriTokens(input: []const u8, out: []u8) []const u8 {
    var o: usize = 0;
    var i: usize = 0;
    while (i < input.len and o < out.len) {
        if (std.mem.startsWith(u8, input[i..], "file://")) {
            var j = i;
            while (j < input.len and !std.ascii.isWhitespace(input[j])) : (j += 1) {}
            o += decodeFileUri(input[i..j], out[o..]);
            i = j;
            continue;
        }

        out[o] = input[i];
        o += 1;
        i += 1;
    }
    return std.mem.trim(u8, out[0..o], " \t\r\n");
}

pub fn decodeFileUri(uri: []const u8, out: []u8) usize {
    if (!std.mem.startsWith(u8, uri, "file://")) return 0;

    var path = uri["file://".len..];
    if (std.mem.startsWith(u8, path, "localhost/")) {
        path = path["localhost".len..];
    }

    var o: usize = 0;
    var i: usize = 0;
    while (i < path.len and o < out.len) : (i += 1) {
        if (path[i] == '%' and i + 2 < path.len) {
            if (hexNibble(path[i + 1])) |hi| {
                if (hexNibble(path[i + 2])) |lo| {
                    out[o] = @as(u8, @intCast((@as(u16, hi) << 4) | lo));
                    o += 1;
                    i += 2;
                    continue;
                }
            }
        }
        out[o] = if (path[i] == '+') ' ' else path[i];
        o += 1;
    }
    return o;
}

pub fn hexNibble(ch: u8) ?u8 {
    if (ch >= '0' and ch <= '9') return ch - '0';
    if (ch >= 'a' and ch <= 'f') return 10 + (ch - 'a');
    if (ch >= 'A' and ch <= 'F') return 10 + (ch - 'A');
    return null;
}

const testing = std.testing;

test "deriveThinkingTopicTitle maps common progress text" {
    var out: [96]u8 = undefined;
    const topic = deriveThinkingTopicTitle("calling model deepseek/deepseek-chat", &out);
    try testing.expectEqualStrings("Calling Model", topic);
}

test "buildActivityPulse renders a single dim braille glyph" {
    var out: [128]u8 = undefined;
    const pulse = buildActivityPulse(&out, 0);
    try testing.expect(pulse.len > 0);
    // Dim ANSI prefix + a single braille block character + reset.
    try testing.expect(std.mem.startsWith(u8, pulse, "\x1b[2m"));
    try testing.expect(std.mem.endsWith(u8, pulse, "\x1b[0m"));
    // First braille block byte is 0xE2 0xA0 ..; assert at least one.
    try testing.expect(std.mem.indexOf(u8, pulse, "\xe2\xa0") != null);
}

test "buildActivityPulse cycles distinct frames" {
    var b0: [64]u8 = undefined;
    var b1: [64]u8 = undefined;
    const p0 = buildActivityPulse(&b0, 0);
    const p1 = buildActivityPulse(&b1, 1);
    try testing.expect(!std.mem.eql(u8, p0, p1));

    // After a full 10-frame cycle the spinner returns to frame 0.
    var b10: [64]u8 = undefined;
    const p10 = buildActivityPulse(&b10, 10);
    try testing.expectEqualStrings(p0, p10);
}

test "sanitizePromptText keeps multiline content" {
    var out: [128]u8 = undefined;
    const clean = sanitizePromptText("first line\nsecond line", out[0..]);
    try testing.expect(std.mem.indexOf(u8, clean, "\n") != null);
    try testing.expect(std.mem.indexOf(u8, clean, "first line") != null);
    try testing.expect(std.mem.indexOf(u8, clean, "second line") != null);
}

test "sanitizePromptText decodes file uri tokens" {
    var out: [256]u8 = undefined;
    const clean = sanitizePromptText("image file:///Users/example/Pictures/Shot%201.png", out[0..]);
    try testing.expect(std.mem.indexOf(u8, clean, "/Users/example/Pictures/Shot 1.png") != null);
}

test "normalizeSummary strips ANSI CSI and OSC sequences" {
    var out: [80]u8 = undefined;
    const clean = normalizeSummary("read \x1b[31mred\x1b[0m /tmp/file\x1b]0;PWNED\x07", &out);
    try testing.expect(std.mem.indexOf(u8, clean, "\x1b") == null);
    try testing.expect(std.mem.indexOf(u8, clean, "read red /tmp/file") != null);
}

test "normalizeSummary drops lone control bytes but keeps tab" {
    var out: [80]u8 = undefined;
    const clean = normalizeSummary("tool\x01name\tdetail", &out);
    try testing.expectEqualStrings("toolname\tdetail", clean);
}

test "actionPrefix strips trailing pipe-separated numbers and timers" {
    try testing.expectEqualStrings(
        "calling model openai-compatible/kimi-k2.5",
        actionPrefix("calling model openai-compatible/kimi-k2.5 | 9 tools | 47.5s"),
    );
    // No pipe -> whole string
    try testing.expectEqualStrings(
        "running tool mcp_invoke: executing",
        actionPrefix("running tool mcp_invoke: executing"),
    );
    try testing.expectEqualStrings(
        "gathering context (round 4)",
        actionPrefix("gathering context (round 4)"),
    );
}

test "SpinnerState.update dedupes progressive timing ticks into a single slot" {
    var state = SpinnerState{};
    // Three "calling model" ticks with different timings should collapse
    // into a single slot holding the latest text.
    state.update("calling model openai-compatible/kimi-k2.5 | 9 tools | 47.5s");
    state.update("calling model openai-compatible/kimi-k2.5 | 9 tools | 65.2s");
    state.update("calling model openai-compatible/kimi-k2.5 | 9 tools | 88.1s");
    try testing.expectEqual(@as(usize, 1), state.summary_count);
    // The stored text should be the most recent one.
    const stored_len: usize = state.summary_lens[0];
    const stored = state.summary_items[0][0..stored_len];
    try testing.expect(std.mem.indexOf(u8, stored, "88.1s") != null);
}

test "SpinnerState.update keeps distinct actions as separate slots" {
    var state = SpinnerState{};
    state.update("gathering context (round 1)");
    state.update("calling model openai-compatible/kimi-k2.5 | 9 tools | 4.0s");
    state.update("saving state");
    try testing.expectEqual(@as(usize, 3), state.summary_count);
}

test "SpinnerState.update merges interleaved progressive updates" {
    var state = SpinnerState{};
    state.update("gathering context (round 1)");
    state.update("calling model openai-compatible/kimi-k2.5 | 9 tools | 4.0s");
    state.update("calling model openai-compatible/kimi-k2.5 | 9 tools | 12.5s");
    state.update("saving state");
    state.update("calling model openai-compatible/kimi-k2.5 | 9 tools | 33.8s");
    // The three "calling model" ticks collapse into ONE slot (updated in place).
    // Slots should end up: gathering context, calling model (at 33.8s), saving state.
    try testing.expectEqual(@as(usize, 3), state.summary_count);
    const calling_len: usize = state.summary_lens[1];
    const calling = state.summary_items[1][0..calling_len];
    try testing.expect(std.mem.indexOf(u8, calling, "33.8s") != null);
}

test "SPINNER_VERBS contains colourful fallbacks" {
    try testing.expect(SPINNER_VERBS.len > 100);
    // Spot-check a few entries to catch accidental truncation.
    var has_thinking = false;
    var has_actioning = false;
    var has_perambulating = false;
    for (SPINNER_VERBS) |v| {
        if (std.mem.eql(u8, v, "Thinking")) has_thinking = true;
        if (std.mem.eql(u8, v, "Actioning")) has_actioning = true;
        if (std.mem.eql(u8, v, "Perambulating")) has_perambulating = true;
    }
    try testing.expect(has_thinking);
    try testing.expect(has_actioning);
    try testing.expect(has_perambulating);
}

test "getSpinnerVerb is deterministic per seed and varies between seeds" {
    const a1 = getSpinnerVerb(12345);
    const a2 = getSpinnerVerb(12345);
    try testing.expectEqualStrings(a1, a2);

    // Different seeds should usually produce different verbs. Try a
    // few and assert at least one differs.
    var differs = false;
    var seed: i128 = 1;
    while (seed < 10) : (seed += 1) {
        if (!std.mem.eql(u8, getSpinnerVerb(seed), a1)) {
            differs = true;
            break;
        }
    }
    try testing.expect(differs);
}

test "deriveThinkingTopicTitleWithSeed uses colourful verb for empty summary" {
    var out: [96]u8 = undefined;
    const verb = deriveThinkingTopicTitleWithSeed("", 42, &out);
    // Should not be the structural default "Thinking" fallback path
    // when a non-zero seed is supplied.
    try testing.expect(verb.len > 0);
    // Should be one of the SPINNER_VERBS.
    var found = false;
    for (SPINNER_VERBS) |v| {
        if (std.mem.eql(u8, v, verb)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "getTurnCompletionVerb is deterministic and in the completion list" {
    const seed: i128 = 98765;
    const a = getTurnCompletionVerb(seed);
    const b = getTurnCompletionVerb(seed);
    try testing.expectEqualStrings(a, b);
    var found = false;
    for (TURN_COMPLETION_VERBS) |v| {
        if (std.mem.eql(u8, v, a)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "getTurnCompletionVerb zero seed returns stable Worked" {
    try testing.expectEqualStrings("Worked", getTurnCompletionVerb(0));
}

test "prompt queue enqueues the buffered input as a new slot" {
    var state: SpinnerState = .{};
    // Simulate the user typing "first prompt" during thinking.
    const first = "first prompt";
    @memcpy(state.queued_input[0..first.len], first);
    state.queued_input_len = first.len;
    state.mutex.lock(rt.io) catch {};
    const pushed = state.enqueuePromptFromBufferLocked();
    state.mutex.unlock(rt.io);
    try testing.expect(pushed);
    try testing.expectEqual(@as(usize, 1), state.queuedPromptCount());
    // Buffer is cleared so the user can start typing another prompt.
    try testing.expectEqual(@as(usize, 0), state.queued_input_len);
}

test "prompt queue supports multiple FIFO slots" {
    var state: SpinnerState = .{};
    const prompts = [_][]const u8{ "first", "second", "third" };
    for (prompts) |p| {
        @memcpy(state.queued_input[0..p.len], p);
        state.queued_input_len = p.len;
        state.mutex.lock(rt.io) catch {};
        const pushed = state.enqueuePromptFromBufferLocked();
        state.mutex.unlock(rt.io);
        try testing.expect(pushed);
    }
    try testing.expectEqual(@as(usize, 3), state.queuedPromptCount());

    // Dequeue FIFO order.
    const a = (try state.dequeuePromptOwned(testing.allocator)).?;
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("first", a);

    const b = (try state.dequeuePromptOwned(testing.allocator)).?;
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("second", b);

    const c = (try state.dequeuePromptOwned(testing.allocator)).?;
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("third", c);

    // Queue is drained.
    try testing.expect((try state.dequeuePromptOwned(testing.allocator)) == null);
    try testing.expectEqual(@as(usize, 0), state.queuedPromptCount());
}

test "prompt queue enqueue returns false when buffer is empty" {
    var state: SpinnerState = .{};
    state.mutex.lock(rt.io) catch {};
    const pushed = state.enqueuePromptFromBufferLocked();
    state.mutex.unlock(rt.io);
    try testing.expect(!pushed);
    try testing.expectEqual(@as(usize, 0), state.queuedPromptCount());
}

test "prompt queue enqueue returns false when queue is full" {
    var state: SpinnerState = .{};
    // Fill every slot.
    var i: usize = 0;
    while (i < SpinnerState.MAX_QUEUED_PROMPTS) : (i += 1) {
        const body = "filler";
        @memcpy(state.queued_input[0..body.len], body);
        state.queued_input_len = body.len;
        state.mutex.lock(rt.io) catch {};
        const ok = state.enqueuePromptFromBufferLocked();
        state.mutex.unlock(rt.io);
        try testing.expect(ok);
    }
    try testing.expectEqual(SpinnerState.MAX_QUEUED_PROMPTS, state.queuedPromptCount());

    // One more should be rejected.
    const extra = "overflow";
    @memcpy(state.queued_input[0..extra.len], extra);
    state.queued_input_len = extra.len;
    state.mutex.lock(rt.io) catch {};
    const overflow = state.enqueuePromptFromBufferLocked();
    state.mutex.unlock(rt.io);
    try testing.expect(!overflow);
    // Buffer is NOT cleared on rejection so the caller can surface the
    // overflow warning without losing what the user typed.
    try testing.expectEqual(extra.len, state.queued_input_len);
}

test "filterStreamChunk strips tool_calls envelope dropped after prose" {
    var state = SpinnerState.StreamFilterState{};
    var out: [4096]u8 = undefined;

    const prose = "I see that nmcli is missing. Let me try another approach.\n";
    const fenced_envelope =
        "`json\n" ++
        "{\"tool_calls\":[{\"name\":\"mcp_invoke\",\"args\":{\"server\":\"kali-tools\"}}]}\n";
    const tail = "Done.\n";

    // Feed everything through a single chunk first.
    const chunk = prose ++ fenced_envelope ++ tail;
    const got = filterStreamChunk(&state, chunk, &out);
    try testing.expect(std.mem.indexOf(u8, got, "tool_calls") == null);
    try testing.expect(std.mem.indexOf(u8, got, "mcp_invoke") == null);
    try testing.expect(std.mem.indexOf(u8, got, "I see that nmcli is missing.") != null);
    try testing.expect(std.mem.indexOf(u8, got, "Done.") != null);
}

test "filterStreamChunk survives byte-at-a-time delivery of envelope" {
    var state = SpinnerState.StreamFilterState{};
    var collected: [4096]u8 = undefined;
    var collected_len: usize = 0;

    const chunk =
        "hello\n" ++
        "{\"tool_calls\":[{\"name\":\"run\"}]}\n" ++
        "world\n";

    for (chunk) |byte| {
        var buf: [4096]u8 = undefined;
        const got = filterStreamChunk(&state, &[_]u8{byte}, &buf);
        if (got.len > 0) {
            @memcpy(collected[collected_len..][0..got.len], got);
            collected_len += got.len;
        }
    }

    const visible = collected[0..collected_len];
    try testing.expect(std.mem.indexOf(u8, visible, "tool_calls") == null);
    try testing.expect(std.mem.indexOf(u8, visible, "hello") != null);
    try testing.expect(std.mem.indexOf(u8, visible, "world") != null);
}

test "filterStreamChunk strips Qwen 'control':{'continue':true} continuation shape" {
    var state = SpinnerState.StreamFilterState{};
    var out: [4096]u8 = undefined;

    // Qwen / minimax local models emit this shape as a "keep going"
    // signal when they want another round without emitting a tool
    // call. The tool_calls array is empty so it's easy to miss in a
    // 16-byte peek window; `"control":{"continue":true}` is the
    // disambiguating marker.
    const chunk =
        "Analyzing the available WiFi networks.\n" ++
        "{\"tool_calls\":[],\"control\":{\"continue\":true}}\n" ++
        "Done.\n";
    const got = filterStreamChunk(&state, chunk, &out);
    try testing.expect(std.mem.indexOf(u8, got, "tool_calls") == null);
    try testing.expect(std.mem.indexOf(u8, got, "control") == null);
    try testing.expect(std.mem.indexOf(u8, got, "continue") == null);
    try testing.expect(std.mem.indexOf(u8, got, "Analyzing") != null);
    try testing.expect(std.mem.indexOf(u8, got, "Done.") != null);
}

test "filterStreamChunk leaves benign line-start braces alone" {
    var state = SpinnerState.StreamFilterState{};
    var out: [4096]u8 = undefined;

    // Python snippet with a line that starts with `{` but isn't an envelope.
    const chunk = "Example:\n{ \"normal\": \"data\" }\nDone.\n";
    const got = filterStreamChunk(&state, chunk, &out);
    try testing.expect(std.mem.indexOf(u8, got, "normal") != null);
    try testing.expect(std.mem.indexOf(u8, got, "Done.") != null);
}

test "clearPromptQueueLocked drops everything" {
    var state: SpinnerState = .{};
    const p = "item";
    @memcpy(state.queued_input[0..p.len], p);
    state.queued_input_len = p.len;
    state.mutex.lock(rt.io) catch {};
    _ = state.enqueuePromptFromBufferLocked();
    state.mutex.unlock(rt.io);
    try testing.expectEqual(@as(usize, 1), state.queuedPromptCount());

    state.mutex.lock(rt.io) catch {};
    state.clearPromptQueueLocked();
    state.mutex.unlock(rt.io);
    try testing.expectEqual(@as(usize, 0), state.queuedPromptCount());
}

var debug_log_spinner: ?std.Io.File = null;
var debug_log_spinner_checked: bool = false;

fn logSpinnerByte(tag: []const u8, byte: u8) void {
    if (!debug_log_spinner_checked) {
        debug_log_spinner_checked = true;
        const path = @import("../core/env.zig").getenv("ZCODE_DEBUG_INPUT") orelse return;
        if (path.len == 0) return;
        const f = std.Io.Dir.cwd().createFile(rt.io, path, .{ .truncate = false }) catch return;
        // 0.16: no seek; writes go positional
        debug_log_spinner = f;
    }
    const log = debug_log_spinner orelse return;
    var buf: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[{s}] 0x{x:0>2} ({d})\n", .{ tag, byte, byte }) catch return;
    _ = log.writeStreamingAll(rt.io, line) catch {};
}
