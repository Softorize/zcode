const std = @import("std");
const rt = @import("zcode_runtime");
const clock = @import("../core/clock.zig");
const repl_spinner_mod = @import("repl_spinner.zig");
const repl_edit_mod = @import("repl_edit.zig");
const repl_markdown = @import("repl_markdown.zig");

const streaming_md_options = .{
    .color_enabled = true,
    .highlight_links = true,
    .highlight_paths = true,
    .highlight_code_blocks = true,
    .color_lists = true,
};

// ── Agent execution glue ──
// Extracted from repl.zig: progress reporter callbacks, approval/ask-user
// UI context wiring, and spinner-to-transcript bridge functions.

pub const SpinnerState = repl_spinner_mod.SpinnerState;
pub const UiTranscript = repl_spinner_mod.UiTranscript;

fn boundedBottomMarginRows(total_rows: usize, requested: usize) usize {
    return repl_spinner_mod.boundedBottomMarginRows(total_rows, requested);
}

fn terminalRows() usize {
    return repl_spinner_mod.terminalRows();
}

fn formatEditBlock(out: *[8192]u8, path: []const u8, old_text: []const u8, new_text: []const u8, start_line: usize, success: bool) []const u8 {
    return repl_edit_mod.formatEditBlock(out, path, old_text, new_text, start_line, success);
}

fn formatToolOutputBlock(out: *[8192]u8, tool_name: []const u8, tool_detail: []const u8, output: []const u8) []const u8 {
    return repl_edit_mod.formatToolOutputBlock(out, tool_name, tool_detail, output);
}

fn formatDiffBlock(out: *[8192]u8, diff_text: []const u8) []const u8 {
    return repl_edit_mod.formatDiffBlock(out, diff_text);
}

// ── Progress reporter callbacks ──

pub fn replProgressUpdate(ctx: *anyopaque, summary: []const u8) void {
    const state: *SpinnerState = @ptrCast(@alignCast(ctx));
    if (std.mem.startsWith(u8, summary, "running tool ")) {
        state.incrementToolCount();
    }
    state.update(summary);
}

pub fn replEmitEditBlock(ctx: *anyopaque, path: []const u8, old_text: []const u8, new_text: []const u8, start_line: usize, success: bool) void {
    const state: *SpinnerState = @ptrCast(@alignCast(ctx));
    var block_buf: [8192]u8 = undefined;
    const block = formatEditBlock(&block_buf, path, old_text, new_text, start_line, success);
    if (block.len == 0) return;

    persistBlockToTranscript(state, block);

    const stdout_handle = std.Io.File.stdout().handle;
    state.write_mutex.lock(rt.io) catch {};
    defer state.write_mutex.unlock(rt.io);

    if (state.use_fullscreen) {
        // thinking_row (= composer_top - 1) must stay outside the
        // scroll region or the live spinner draws get pushed into
        // scrollback as "calling model ... 24.9s / 41.1s / ..." ghosts.
        const composer_top = repl_spinner_mod.composerTopRow(state.bottom_margin);
        const scroll_bottom = if (composer_top > 2) composer_top - 2 else 1;
        var block_lines: usize = 1;
        for (block) |ch| {
            if (ch == '\n') block_lines += 1;
        }
        const content_start = if (composer_top > block_lines + 1) composer_top - block_lines - 1 else 1;
        // Save cursor, scroll content up, position, write, restore
        var seq_buf: [128]u8 = undefined;
        const prefix = std.fmt.bufPrint(&seq_buf, "\x1b7\x1b[1;{d}r\x1b[{d}S\x1b[{d};1H", .{ scroll_bottom, block_lines + 1, content_start }) catch return;
        _ = std.c.write(stdout_handle, (prefix).ptr, (prefix).len);
        _ = std.c.write(stdout_handle, (block).ptr, (block).len);
        const suffix = "\x1b[r\x1b8";
        _ = std.c.write(stdout_handle, (suffix).ptr, (suffix).len);
    } else {
        // Simple mode: clear spinner line, write block, spinner redraws on next tick
        _ = std.c.write(stdout_handle, ("\r\x1b[2K").ptr, ("\r\x1b[2K").len);
        _ = std.c.write(stdout_handle, (block).ptr, (block).len);
        _ = std.c.write(stdout_handle, ("\n").ptr, ("\n").len);
    }
}

pub fn replEmitStreamChunk(ctx: *anyopaque, chunk: []const u8) void {
    const state: *SpinnerState = @ptrCast(@alignCast(ctx));
    if (chunk.len == 0) return;

    state.mutex.lock(rt.io) catch {};
    if (!state.streaming_active) {
        state.streaming_active = true;
    }
    state.stream_token_count += 1;
    state.mutex.unlock(rt.io);

    // Acquire write_mutex for the entire filter+buffer operation. This protects
    // stream_filter (mutated by filterStreamChunk) and stream_md_state (used in
    // flushStreamImpl) from any concurrent reset between turns.
    state.write_mutex.lock(rt.io) catch {};
    defer state.write_mutex.unlock(rt.io);

    // Filter out raw JSON model output, only show assistant text
    var filter_out: [4096]u8 = undefined;
    const filtered = repl_spinner_mod.filterStreamChunk(&state.stream_filter, chunk, &filter_out);
    if (filtered.len == 0) return;

    // Drain filtered into stream_buf in as many passes as needed. If the
    // incoming chunk is larger than the remaining room, flush what we have
    // first and then continue copying. The previous code silently dropped
    // whatever didn't fit after a single @min clamp, producing mid-word
    // truncation on fast providers.
    var drain_offset: usize = 0;
    while (drain_offset < filtered.len) {
        const remaining_room = state.stream_buf.len - state.stream_buf_len;
        if (remaining_room == 0) {
            flushStreamToScreen(state);
            // If nothing could be flushed (no full line yet) we cannot
            // make progress; fall back to a hard flush that emits what we
            // have regardless of newline boundaries so the new bytes have
            // somewhere to land.
            if (state.stream_buf.len - state.stream_buf_len == 0) {
                flushStreamImpl(state, true);
            }
            continue;
        }
        const take = @min(filtered.len - drain_offset, remaining_room);
        @memcpy(
            state.stream_buf[state.stream_buf_len..][0..take],
            filtered[drain_offset..][0..take],
        );
        state.stream_buf_len += take;
        drain_offset += take;
        if (state.stream_buf_len > state.stream_buf.len - 256) {
            flushStreamToScreen(state);
        }
    }

    // Also accumulate filtered text in transcript buffer for scrollback
    const t_remaining = state.stream_transcript_buf.len - state.stream_transcript_len;
    const t_copy = @min(filtered.len, t_remaining);
    if (t_copy > 0) {
        @memcpy(state.stream_transcript_buf[state.stream_transcript_len..][0..t_copy], filtered[0..t_copy]);
        state.stream_transcript_len += t_copy;
    }
}

pub fn flushStreamToScreen(state: *SpinnerState) void {
    // Like Claude Code: only display complete lines (truncate at last \n).
    // Incomplete final line stays in buffer until more tokens arrive.
    flushStreamImpl(state, false);
}

fn flushStreamImpl(state: *SpinnerState, flush_all: bool) void {
    if (state.stream_buf_len == 0) return;
    const stdout_handle = std.Io.File.stdout().handle;
    const buf = state.stream_buf[0..state.stream_buf_len];

    // Find last newline - only flush up to there (line-by-line display)
    const display_end = if (flush_all) state.stream_buf_len else blk: {
        var i: usize = state.stream_buf_len;
        while (i > 0) {
            i -= 1;
            if (buf[i] == '\n') break :blk i + 1;
        }
        break :blk @as(usize, 0); // No complete line yet
    };
    if (display_end == 0) return;

    const content = buf[0..display_end];

    // Render through markdown formatter for styled streaming output. The
    // styled buffer is 4x the stream buffer because ANSI color escapes
    // inflate each byte of source; the previous 8 KiB was too small for a
    // full 4 KiB flush of code-fence / bold / link content and caused
    // silent mid-line truncation once writeStyledLine hit NoSpaceLeft.
    var styled_buf: [16 * 1024]u8 = undefined;
    var styled_stream = std.Io.Writer.fixed(&styled_buf);
    const styled_writer = &styled_stream;
    var newlines: usize = 0;
    const styled_output = blk: {
        const md_options = streaming_md_options;
        var line_start: usize = 0;
        var ci: usize = 0;
        while (ci < content.len) : (ci += 1) {
            if (content[ci] == '\n') {
                const line = content[line_start..ci];
                repl_markdown.advanceMarkdownStateForLine(line, &state.stream_md_state);
                repl_markdown.writeStyledLine(styled_writer, line, md_options, &state.stream_md_state) catch {};
                styled_writer.writeByte('\n') catch {};
                line_start = ci + 1;
                newlines += 1;
            }
        }
        if (line_start < content.len) {
            const line = content[line_start..];
            repl_markdown.advanceMarkdownStateForLine(line, &state.stream_md_state);
            repl_markdown.writeStyledLine(styled_writer, line, md_options, &state.stream_md_state) catch {};
        }
        break :blk styled_buf[0..styled_stream.end];
    };

    if (state.use_fullscreen) {
        // Scroll region ends one row above the thinking line so chat
        // text never overlaps the live spinner or the composer chrome.
        const composer_top = repl_spinner_mod.composerTopRow(state.bottom_margin);
        const scroll_bottom = if (composer_top > 2) composer_top - 2 else 1;
        const content_row = scroll_bottom;

        var seq_buf: [128]u8 = undefined;
        if (newlines > 0) {
            const prefix = std.fmt.bufPrint(&seq_buf, "\x1b7\x1b[1;{d}r\x1b[{d}S\x1b[{d};1H", .{ scroll_bottom, newlines, content_row }) catch return;
            _ = std.c.write(stdout_handle, (prefix).ptr, (prefix).len);
            _ = std.c.write(stdout_handle, (styled_output).ptr, (styled_output).len);
            _ = std.c.write(stdout_handle, ("\x1b[r\x1b8").ptr, ("\x1b[r\x1b8").len);
        } else if (flush_all) {
            const prefix = std.fmt.bufPrint(&seq_buf, "\x1b7\x1b[{d};1H", .{content_row}) catch return;
            _ = std.c.write(stdout_handle, (prefix).ptr, (prefix).len);
            _ = std.c.write(stdout_handle, (styled_output).ptr, (styled_output).len);
            _ = std.c.write(stdout_handle, ("\x1b8").ptr, ("\x1b8").len);
        }
    } else {
        _ = std.c.write(stdout_handle, (styled_output).ptr, (styled_output).len);
    }

    // Keep incomplete line in buffer
    if (display_end < state.stream_buf_len) {
        const remaining = state.stream_buf_len - display_end;
        std.mem.copyForwards(u8, state.stream_buf[0..remaining], state.stream_buf[display_end..state.stream_buf_len]);
        state.stream_buf_len = remaining;
    } else {
        state.stream_buf_len = 0;
    }
    state.stream_last_flush_ns = clock.nowNanos();
}

pub fn replEndStream(ctx: *anyopaque) void {
    const state: *SpinnerState = @ptrCast(@alignCast(ctx));

    // Flush ALL remaining content including incomplete line
    state.write_mutex.lock(rt.io) catch {};
    flushStreamImpl(state, true);
    state.write_mutex.unlock(rt.io);

    // Persist accumulated stream text to transcript for scrollback
    if (state.use_fullscreen and state.stream_transcript_len > 0) {
        if (state.transcript) |t| {
            if (state.transcript_allocator) |alloc| {
                const text = state.stream_transcript_buf[0..state.stream_transcript_len];
                var line_iter = std.mem.splitScalar(u8, text, '\n');
                while (line_iter.next()) |line| {
                    if (line.len > 0) t.appendLine(alloc, line) catch {};
                }
            }
        }
        state.stream_transcript_len = 0;
    }

    state.mutex.lock(rt.io) catch {};
    const was_streaming = state.streaming_active;
    const token_count = state.stream_token_count;
    state.streaming_active = false;
    state.mutex.unlock(rt.io);

    if (was_streaming) {
        const stdout_handle = std.Io.File.stdout().handle;
        _ = std.c.write(stdout_handle, ("\n").ptr, ("\n").len);

        // Show token speed summary
        if (token_count > 0) {
            const now_ns = clock.nowNanos();
            const started_ns = state.startedTimestampNs();
            const elapsed_ms: u64 = if (now_ns > started_ns)
                @intCast(@divTrunc((now_ns - started_ns), std.time.ns_per_ms))
            else
                0;
            if (elapsed_ms > 0) {
                // tokens_per_sec = token_count * 1000 / elapsed_ms
                const tps_x10: u64 = token_count * 10000 / elapsed_ms;
                var summary_buf: [128]u8 = undefined;
                const summary = std.fmt.bufPrint(&summary_buf, "streamed {d} tokens | {d}.{d}s | {d}.{d} tok/s", .{
                    token_count,
                    elapsed_ms / 1000,
                    (elapsed_ms % 1000) / 100,
                    tps_x10 / 10,
                    tps_x10 % 10,
                }) catch "";
                if (summary.len > 0) {
                    state.update(summary);
                }
            }
        }
    }
}

pub fn replEmitToolOutput(ctx: *anyopaque, tool_name: []const u8, tool_detail: []const u8, output: []const u8) void {
    const state: *SpinnerState = @ptrCast(@alignCast(ctx));
    var block_buf: [8192]u8 = undefined;
    const block = formatToolOutputBlock(&block_buf, tool_name, tool_detail, output);
    if (block.len == 0) return;

    // Dedupe consecutive identical tool blocks. A dead MCP server
    // returning the same "McpResponseTimeout" error N times in a row
    // used to flood the transcript with N near-identical cards;
    // collapse those into a single card followed by a "(repeated N
    // times)" line on the next non-matching block.
    //
    // Hash uses the RAW output + tool name, NOT the formatted block.
    // Two reasons:
    //
    //  1. The formatted block includes ANSI escape sequences, truncation
    //     markers ("... N more lines omitted"), and detail subtitles
    //     that can drift between rendered calls even when the semantic
    //     output is identical. Hashing the raw output bytes avoids
    //     false misses on legitimate duplicates.
    //  2. TodoWrite is the motivating case: the model occasionally
    //     re-submits the same todo list across rounds. Both calls
    //     produce the same textual output, but renderer truncation
    //     differs slightly based on terminal width / detail length,
    //     producing different block hashes. Raw-output hashing catches
    //     these reliably.
    //
    // The tool_name prefix prevents two different tools from
    // accidentally colliding when they happen to emit the same body
    // (e.g. an empty output).
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(tool_name);
    hasher.update("\x1f"); // separator byte
    hasher.update(output);
    const block_hash = hasher.final();
    if (block_hash == state.last_tool_block_hash and state.last_tool_block_hash != 0) {
        state.last_tool_block_repeats += 1;
        return;
    }

    // The new block differs from the cached one. If we suppressed any
    // duplicates of the previous block, surface the count to the user
    // before printing the new block. Persist the marker into the
    // transcript too so /export and /resume preserve the same view.
    var dedupe_marker_buf: [128]u8 = undefined;
    var dedupe_marker_len: usize = 0;
    if (state.last_tool_block_repeats > 0) {
        const marker = std.fmt.bufPrint(
            &dedupe_marker_buf,
            "  (previous tool result repeated {d} more time{s})\n",
            .{
                state.last_tool_block_repeats,
                if (state.last_tool_block_repeats == 1) @as([]const u8, "") else @as([]const u8, "s"),
            },
        ) catch "";
        dedupe_marker_len = marker.len;
        if (marker.len > 0) {
            persistBlockToTranscript(state, marker);
        }
    }
    state.last_tool_block_hash = block_hash;
    state.last_tool_block_repeats = 0;

    persistBlockToTranscript(state, block);

    const stdout_handle = std.Io.File.stdout().handle;
    state.write_mutex.lock(rt.io) catch {};
    defer state.write_mutex.unlock(rt.io);

    if (state.use_fullscreen) {
        // Exclude thinking_row (= composer_top-1) from the scroll
        // region so the spinner's live status line doesn't get
        // shifted into scrollback on every card scroll. See the
        // replEmitEditBlock comment for full rationale.
        const composer_top = repl_spinner_mod.composerTopRow(state.bottom_margin);
        const scroll_bottom = if (composer_top > 2) composer_top - 2 else 1;
        var block_lines: usize = 1;
        for (block) |ch| {
            if (ch == '\n') block_lines += 1;
        }
        const content_start = if (composer_top > block_lines + 1) composer_top - block_lines - 1 else 1;
        var seq_buf: [128]u8 = undefined;
        const prefix = std.fmt.bufPrint(&seq_buf, "\x1b7\x1b[1;{d}r\x1b[{d}S\x1b[{d};1H", .{ scroll_bottom, block_lines + 1, content_start }) catch return;
        _ = std.c.write(stdout_handle, (prefix).ptr, (prefix).len);
        if (dedupe_marker_len > 0) {
            _ = std.c.write(stdout_handle, (dedupe_marker_buf[0..dedupe_marker_len]).ptr, (dedupe_marker_buf[0..dedupe_marker_len]).len);
        }
        _ = std.c.write(stdout_handle, (block).ptr, (block).len);
        const suffix = "\x1b[r\x1b8";
        _ = std.c.write(stdout_handle, (suffix).ptr, (suffix).len);
    } else {
        // Simple mode: clear spinner line, write dedupe marker (if any),
        // then the new block. Spinner redraws on next tick.
        _ = std.c.write(stdout_handle, ("\r\x1b[2K").ptr, ("\r\x1b[2K").len);
        if (dedupe_marker_len > 0) {
            _ = std.c.write(stdout_handle, (dedupe_marker_buf[0..dedupe_marker_len]).ptr, (dedupe_marker_buf[0..dedupe_marker_len]).len);
        }
        _ = std.c.write(stdout_handle, (block).ptr, (block).len);
        _ = std.c.write(stdout_handle, ("\n").ptr, ("\n").len);
    }
}

pub fn replIsCancelled(ctx: *anyopaque) bool {
    const state: *SpinnerState = @ptrCast(@alignCast(ctx));
    return state.cancel_requested.load(.acquire);
}

pub fn replEmitDiffBlock(ctx: *anyopaque, diff_text: []const u8) void {
    const state: *SpinnerState = @ptrCast(@alignCast(ctx));
    var block_buf: [8192]u8 = undefined;
    const block = formatDiffBlock(&block_buf, diff_text);
    if (block.len == 0) return;

    persistBlockToTranscript(state, block);

    const stdout_handle = std.Io.File.stdout().handle;
    state.write_mutex.lock(rt.io) catch {};
    defer state.write_mutex.unlock(rt.io);

    if (state.use_fullscreen) {
        // Exclude thinking_row from the scroll region so the live
        // spinner line never shifts into scrollback as a ghost
        // duplicate. See replEmitEditBlock for the full rationale.
        const composer_top = repl_spinner_mod.composerTopRow(state.bottom_margin);
        const scroll_bottom = if (composer_top > 2) composer_top - 2 else 1;
        var block_lines: usize = 1;
        for (block) |ch| {
            if (ch == '\n') block_lines += 1;
        }
        const content_start = if (composer_top > block_lines + 1) composer_top - block_lines - 1 else 1;
        var seq_buf: [128]u8 = undefined;
        const prefix = std.fmt.bufPrint(&seq_buf, "\x1b7\x1b[1;{d}r\x1b[{d}S\x1b[{d};1H", .{ scroll_bottom, block_lines + 1, content_start }) catch return;
        _ = std.c.write(stdout_handle, (prefix).ptr, (prefix).len);
        _ = std.c.write(stdout_handle, (block).ptr, (block).len);
        const suffix = "\x1b[r\x1b8";
        _ = std.c.write(stdout_handle, (suffix).ptr, (suffix).len);
    } else {
        _ = std.c.write(stdout_handle, ("\r\x1b[2K").ptr, ("\r\x1b[2K").len);
        _ = std.c.write(stdout_handle, (block).ptr, (block).len);
        _ = std.c.write(stdout_handle, ("\n").ptr, ("\n").len);
    }
}

// ── Tests ──

const testing = std.testing;

// -- Shared helpers --

fn persistBlockToTranscript(state: *SpinnerState, block: []const u8) void {
    if (!state.use_fullscreen) return;
    const t = state.transcript orelse return;
    const alloc = state.transcript_allocator orelse return;
    var line_iter = std.mem.splitScalar(u8, block, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        var clean_buf: [512]u8 = undefined;
        const clean = stripAnsiStackBuf(line, &clean_buf);
        t.appendLine(alloc, clean) catch {};
    }
}

fn stripAnsiStackBuf(text: []const u8, out: *[512]u8) []const u8 {
    var pos: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '[') {
            // Skip CSI sequence: ESC [ ... final_byte
            i += 2;
            while (i < text.len and text[i] >= 0x20 and text[i] <= 0x3f) : (i += 1) {}
            if (i < text.len) i += 1; // skip final byte
        } else {
            if (pos < out.len) {
                out[pos] = text[i];
                pos += 1;
            }
            i += 1;
        }
    }
    return out[0..pos];
}

test "repl_agent progress callbacks are reachable" {
    // Compile-time reachability test
    try testing.expect(@TypeOf(replProgressUpdate) == @TypeOf(replProgressUpdate));
    try testing.expect(@TypeOf(replEmitEditBlock) == @TypeOf(replEmitEditBlock));
    try testing.expect(@TypeOf(replEmitStreamChunk) == @TypeOf(replEmitStreamChunk));
    try testing.expect(@TypeOf(replEndStream) == @TypeOf(replEndStream));
    try testing.expect(@TypeOf(replEmitToolOutput) == @TypeOf(replEmitToolOutput));
    try testing.expect(@TypeOf(replEmitDiffBlock) == @TypeOf(replEmitDiffBlock));
}
