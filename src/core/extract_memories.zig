//! Turn-end memory extraction forked agent (memory-01).
//!
//! After a complete query loop (the main agent gave a final answer with no
//! pending tool calls), a constrained background agent reads the recent
//! conversation and writes new memories. It is:
//!   - throttled (runs every N eligible turns, default N=1),
//!   - cursor-tracked (each run only considers turns added since the last run),
//!   - mutually exclusive with main-agent writes (when the main agent itself
//!     wrote a memory this range, the fork is skipped and the cursor advances).
//!
//! Ported from claude-code-main/src/services/extractMemories/extractMemories.ts:
//!   countModelVisibleMessagesSince  (:82-110)  -> countModelVisibleTurnsSince
//!   hasMemoryWritesSince            (:121-148) -> hasMemoryWritesSince
//!   createAutoMemCanUseTool         (:171-222) -> agent_tools.autoMemGate
//!   runExtraction throttle          (:377-386) -> ExtractState.throttleAllows
//!   extractWrittenPaths             (:251-269) -> extractWrittenPaths
//! and the prompt builder from prompts.ts buildExtractAutoOnlyPrompt (:50-94).
//!
//! Synchronous v1: like maybeRunDream, the fork runs inline at turn end (the
//! reference runs it in the background and drains at shutdown). Async/coalesced
//! execution is deferred per the phase's out-of-scope notes.
//!
//! Recursion guard: the fork is itself an AgentRuntime. maybeExtract must
//! early-return when depth > 0 or !interactive (exactly as maybeRunDream only
//! fires at depth == 0), so the child never recurses into its own extraction.

const std = @import("std");
const rt = @import("zcode_runtime");
const types = @import("types.zig");
const config = @import("config.zig");
const memory = @import("memory.zig");
const memory_gate = @import("memory_gate.zig");
const memory_prompt = @import("memory_prompt.zig");
const std_io = @import("std_io.zig");
const arg_parse = @import("../tools/arg_parse.zig");
const parse_helpers = @import("parse_helpers.zig");

/// Default throttle: run extraction every eligible turn. The reference reads
/// this from the `tengu_bramble_lintel` GrowthBook flag; zcode has no
/// GrowthBook so it is a fixed default (per the phase's out-of-scope notes).
pub const DEFAULT_THROTTLE_N: u32 = 1;

/// Hard cap on the extraction child's tool rounds. The reference uses
/// maxTurns=5 ("well-behaved extractions complete in 2-4 turns: read -> write;
/// a hard cap prevents verification rabbit-holes from burning turns").
pub const MAX_EXTRACT_ROUNDS: usize = 5;

/// Per-AgentRuntime extraction state. Lives on the runtime so the cursor and
/// throttle counter survive across turns within one session. Reset on /clear
/// (and clamped defensively when /compact shrinks history below the cursor).
pub const ExtractState = struct {
    /// Index into `history` of the first turn NOT yet considered by a previous
    /// successful extraction (the "cursor"). 0 means "consider everything".
    cursor_turn_index: usize = 0,
    /// Eligible turns since the last extraction run. Incremented each eligible
    /// turn-end, reset to 0 when a run fires.
    turns_since_last_extraction: u32 = 0,

    /// Reset to the initial state. Called from the /clear handler so a cleared
    /// conversation starts a fresh extraction window.
    pub fn reset(self: *ExtractState) void {
        self.cursor_turn_index = 0;
        self.turns_since_last_extraction = 0;
    }

    /// Throttle decision, porting runExtraction's gate (extractMemories.ts:
    /// 377-385): increment the counter, then run only when it has reached N.
    /// Returns true when this eligible turn should run an extraction; on a true
    /// result the counter is reset to 0 (the run "consumes" the accumulated
    /// turns). On a false result the counter is left incremented so the next
    /// turn is one step closer.
    pub fn throttleAllows(self: *ExtractState, n: u32) bool {
        const threshold = if (n == 0) 1 else n;
        self.turns_since_last_extraction += 1;
        if (self.turns_since_last_extraction < threshold) return false;
        self.turns_since_last_extraction = 0;
        return true;
    }
};

/// Count model-visible turns (user/assistant) in `history[cursor..]`. The
/// reference counts user+assistant messages; system and tool turns are not
/// model-visible in the same sense (system turns are nudges, tool turns are
/// results). Ports countModelVisibleMessagesSince (extractMemories.ts:82-110);
/// the cursor here is an index rather than a UUID, and an out-of-range cursor
/// falls back to counting the whole history (matching the reference's
/// "sinceUuid not found -> count all" fallback so extraction is never
/// permanently disabled by a compaction that dropped the cursor turn).
pub fn countModelVisibleTurnsSince(history: []const types.HistoryTurn, cursor: usize) usize {
    const start = if (cursor > history.len) 0 else cursor;
    var n: usize = 0;
    for (history[start..]) |turn| {
        if (turn.role == .user or turn.role == .assistant) n += 1;
    }
    return n;
}

/// Parse a `.tool` history turn's `tool=` and `args=` fields. Turn content is
/// recorded by agent_runtime as "tool={name}\nargs={args}\nstate=...\n...".
/// Returns null when the turn is not a parseable tool record.
const ToolRecord = struct { name: []const u8, args: []const u8 };

fn parseToolTurn(content: []const u8) ?ToolRecord {
    if (!std.mem.startsWith(u8, content, "tool=")) return null;
    const after_tool = content["tool=".len..];
    const name_end = std.mem.indexOfScalar(u8, after_tool, '\n') orelse return null;
    const name = after_tool[0..name_end];

    const args_marker = "\nargs=";
    const args_at = std.mem.indexOf(u8, content, args_marker) orelse return null;
    const after_args = content[args_at + args_marker.len ..];
    // args is everything up to the next "\nstate=" marker (the recorded format
    // always has state after args). Fall back to the rest of the line if the
    // marker is absent.
    const state_marker = "\nstate=";
    const args_end = std.mem.indexOf(u8, after_args, state_marker) orelse
        (std.mem.indexOfScalar(u8, after_args, '\n') orelse after_args.len);
    return .{ .name = name, .args = after_args[0..args_end] };
}

/// True when the tool record names a write tool (Edit/Write/MultiEdit).
fn isWriteToolName(name: []const u8) bool {
    return parse_helpers.matchesAnyName(name, &.{
        "Edit",      "edit",       "file_edit",
        "Write",     "write",      "file_write",
        "MultiEdit", "multi_edit", "file_multi_edit",
    });
}

/// Extract the written file path from a tool record, if it is a write tool with
/// a file_path/path arg. Ports getWrittenFilePath (extractMemories.ts:232-249).
fn writtenPathFromRecord(rec: ToolRecord) ?[]const u8 {
    if (!isWriteToolName(rec.name)) return null;
    return arg_parse.getArg(rec.args, "file_path") orelse arg_parse.getArg(rec.args, "path");
}

/// True when any assistant/tool turn at or after `cursor` records a write tool
/// targeting a path under the auto-memory dir. When true, runExtraction skips
/// the fork (the main agent already wrote memories this range) and advances the
/// cursor. Ports hasMemoryWritesSince (extractMemories.ts:121-148).
///
/// `mem_dir` is the resolved auto-memory directory (from
/// memory_gate.getAutoMemPath); the prefix check matches memory_gate's
/// isAutoMemPath child semantics without re-resolving the dir per turn.
pub fn hasMemoryWritesSince(
    history: []const types.HistoryTurn,
    cursor: usize,
    mem_dir: []const u8,
) bool {
    const start = if (cursor > history.len) 0 else cursor;
    for (history[start..]) |turn| {
        if (turn.role != .tool) continue;
        const rec = parseToolTurn(turn.content) orelse continue;
        const path = writtenPathFromRecord(rec) orelse continue;
        if (pathWithin(mem_dir, path)) return true;
    }
    return false;
}

/// Collect the unique auto-memory paths written across the child's history.
/// Ports extractWrittenPaths (extractMemories.ts:251-269) plus the auto-mem
/// filter. Caller owns the returned slice and each contained string.
pub fn extractWrittenPaths(
    allocator: std.mem.Allocator,
    history: []const types.HistoryTurn,
    cursor: usize,
    mem_dir: []const u8,
) ![][]u8 {
    var out = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit();
    }
    const start = if (cursor > history.len) 0 else cursor;
    for (history[start..]) |turn| {
        if (turn.role != .tool) continue;
        const rec = parseToolTurn(turn.content) orelse continue;
        const path = writtenPathFromRecord(rec) orelse continue;
        if (!pathWithin(mem_dir, path)) continue;
        // Dedup.
        var seen = false;
        for (out.items) |p| {
            if (std.mem.eql(u8, p, path)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        try out.append(try allocator.dupe(u8, path));
    }
    return out.toOwnedSlice();
}

/// True when `path` is `base` itself or a descendant of `base`. Tolerant of a
/// trailing separator on `base`. Pure-string mirror of memory_gate.isAutoMemPath
/// child semantics; kept allocation-free for the per-turn scan.
fn pathWithin(base: []const u8, path: []const u8) bool {
    const base_trim = std.mem.trimEnd(u8, base, "/\\");
    if (base_trim.len == 0) return false;
    if (std.mem.eql(u8, path, base_trim)) return true;
    if (path.len > base_trim.len and
        std.mem.startsWith(u8, path, base_trim) and
        (path[base_trim.len] == '/' or path[base_trim.len] == '\\'))
    {
        return true;
    }
    return false;
}

/// Build the extraction prompt for auto-only memory. Ports
/// buildExtractAutoOnlyPrompt + the shared opener (prompts.ts:29-94). Reuses
/// the exact taxonomy text constants the system prompt teaches so the forked
/// write path produces parity-shaped files. `new_message_count` is the count of
/// recent model-visible turns the fork should analyze; `existing_memories` is
/// the pre-scanned manifest (may be empty); `memory_dir` is the resolved
/// auto-memory directory. Caller owns the returned slice.
pub fn buildExtractAutoOnlyPrompt(
    allocator: std.mem.Allocator,
    new_message_count: usize,
    existing_memories: []const u8,
    memory_dir: []const u8,
) ![]u8 {
    _ = memory_dir; // The opener references "memory directory" generically; the
    // tool gate enforces the concrete dir. Kept in the signature for parity and
    // so a future variant can substitute it without a call-site change.

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    // --- opener (prompts.ts:29-44) ---
    try w.print(
        "You are now acting as the memory extraction subagent. Analyze the most recent ~{d} messages above and use them to update your persistent memory systems.\n" ++
            "\n" ++
            "Available tools: Read, Grep, Glob, read-only Bash (ls/find/cat/stat/wc/head/tail and similar), and Edit/Write for paths inside the memory directory only. Bash rm is not permitted. All other tools - MCP, Agent, write-capable Bash, etc - will be denied.\n" ++
            "\n" ++
            "You have a limited turn budget. Edit requires a prior Read of the same file, so the efficient strategy is: turn 1 - issue all Read calls in parallel for every file you might update; turn 2 - issue all Write/Edit calls in parallel. Do not interleave reads and writes across multiple turns.\n" ++
            "\n" ++
            "You MUST only use content from the last ~{d} messages to update your persistent memories. Do not waste any turns attempting to investigate or verify that content further - no grepping source files, no reading code to confirm a pattern exists, no git commands.",
        .{ new_message_count, new_message_count },
    );

    // Existing-memory manifest (opener's `manifest` branch, prompts.ts:30-33).
    if (existing_memories.len > 0) {
        try w.print(
            "\n\n## Existing memory files\n\n{s}\n\nCheck this list before writing - update an existing file rather than creating a duplicate.",
            .{existing_memories},
        );
    }

    try w.writeAll(
        "\n\nIf the user explicitly asks you to remember something, save it immediately as whichever type fits best. If they ask you to forget something, find and remove the relevant entry.\n\n",
    );

    // --- four-type taxonomy + what-not-to-save (reused from memory_prompt) ---
    try w.writeAll(memory_prompt.TYPES_SECTION_INDIVIDUAL);
    try w.writeAll(memory_prompt.WHAT_NOT_TO_SAVE_SECTION);
    try w.writeAll("\n");

    // --- two-step save protocol (prompts.ts howToSave, skipIndex=false) ---
    try w.print(
        "## How to save memories\n" ++
            "\n" ++
            "Saving a memory is a two-step process:\n" ++
            "\n" ++
            "**Step 1** - write the memory to its own file (e.g., `user_role.md`, `feedback_testing.md`) using this frontmatter format:\n" ++
            "\n" ++
            memory_prompt.MEMORY_FRONTMATTER_EXAMPLE ++ "\n" ++
            "\n" ++
            "**Step 2** - add a pointer to that file in `" ++ memory_prompt.ENTRYPOINT_NAME ++ "`. `" ++ memory_prompt.ENTRYPOINT_NAME ++ "` is an index, not a memory - each entry should be one line, under ~150 characters: `- [Title](file.md) - one-line hook`. It has no frontmatter. Never write memory content directly into `" ++ memory_prompt.ENTRYPOINT_NAME ++ "`.\n" ++
            "\n" ++
            "- `" ++ memory_prompt.ENTRYPOINT_NAME ++ "` is always loaded into your system prompt - lines after {d} will be truncated, so keep the index concise\n" ++
            "- Organize memory semantically by topic, not chronologically\n" ++
            "- Update or remove memories that turn out to be wrong or outdated\n" ++
            "- Do not write duplicate memories. First check if there is an existing memory you can update before writing a new one.\n",
        .{memory_prompt.MAX_ENTRYPOINT_LINES},
    );

    return out.toOwnedSlice();
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

fn toolTurn(content: []const u8) types.HistoryTurn {
    return .{ .role = .tool, .content = content, .timestamp = 0 };
}
fn userTurn(content: []const u8) types.HistoryTurn {
    return .{ .role = .user, .content = content, .timestamp = 0 };
}
fn asstTurn(content: []const u8) types.HistoryTurn {
    return .{ .role = .assistant, .content = content, .timestamp = 0 };
}

test "hasMemoryWritesSince detects a write under the auto-mem dir" {
    const mem_dir = "/home/u/.zcode/memory";
    const history = [_]types.HistoryTurn{
        userTurn("remember I prefer tabs"),
        asstTurn("saving that now"),
        // A Write to a file inside the memory dir.
        toolTurn("tool=Write\nargs=file_path=\"/home/u/.zcode/memory/user_prefs.md\", content=\"...\"\nstate=auto_approved\nrisk=LOW\noutput=ok"),
    };
    try testing.expect(hasMemoryWritesSince(&history, 0, mem_dir));
}

test "hasMemoryWritesSince false when the write is outside the dir" {
    const mem_dir = "/home/u/.zcode/memory";
    const history = [_]types.HistoryTurn{
        userTurn("edit the source"),
        toolTurn("tool=Write\nargs=file_path=\"/home/u/project/src/main.zig\", content=\"...\"\nstate=auto_approved\nrisk=LOW\noutput=ok"),
        // A Read inside the dir is not a write.
        toolTurn("tool=Read\nargs=file_path=\"/home/u/.zcode/memory/MEMORY.md\"\nstate=auto_approved\nrisk=LOW\noutput=..."),
    };
    try testing.expect(!hasMemoryWritesSince(&history, 0, mem_dir));
}

test "hasMemoryWritesSince respects the cursor" {
    const mem_dir = "/home/u/.zcode/memory";
    const history = [_]types.HistoryTurn{
        // This write is BEFORE the cursor -> ignored.
        toolTurn("tool=Write\nargs=file_path=\"/home/u/.zcode/memory/old.md\", content=\"x\"\nstate=auto_approved\nrisk=LOW\noutput=ok"),
        userTurn("new turn"),
        asstTurn("ok"),
    };
    // Cursor at index 1: the pre-cursor write is not counted.
    try testing.expect(!hasMemoryWritesSince(&history, 1, mem_dir));
    // Cursor at 0: it is counted.
    try testing.expect(hasMemoryWritesSince(&history, 0, mem_dir));
}

test "throttle: N=1 fires every eligible turn" {
    var state = ExtractState{};
    try testing.expect(state.throttleAllows(1)); // turn 1 fires
    try testing.expect(state.throttleAllows(1)); // turn 2 fires
}

test "throttle: higher N skips until the count is reached" {
    var state = ExtractState{};
    try testing.expect(!state.throttleAllows(3)); // 1 < 3
    try testing.expect(!state.throttleAllows(3)); // 2 < 3
    try testing.expect(state.throttleAllows(3)); //  3 == 3 -> fires, resets
    try testing.expect(!state.throttleAllows(3)); // back to 1 < 3
}

test "throttle: N=0 is treated as 1 (never divides by zero / always fires)" {
    var state = ExtractState{};
    try testing.expect(state.throttleAllows(0));
    try testing.expect(state.throttleAllows(0));
}

test "ExtractState.reset clears the cursor and counter" {
    var state = ExtractState{ .cursor_turn_index = 7, .turns_since_last_extraction = 2 };
    state.reset();
    try testing.expectEqual(@as(usize, 0), state.cursor_turn_index);
    try testing.expectEqual(@as(u32, 0), state.turns_since_last_extraction);
}

test "countModelVisibleTurnsSince counts only user/assistant turns past the cursor" {
    const history = [_]types.HistoryTurn{
        userTurn("a"),
        asstTurn("b"),
        toolTurn("tool=Read\nargs=...\nstate=auto_approved\nrisk=LOW\noutput=x"),
        .{ .role = .system, .content = "nudge", .timestamp = 0 },
        userTurn("c"),
    };
    // From cursor 0: user a, asst b, user c = 3 (tool + system excluded).
    try testing.expectEqual(@as(usize, 3), countModelVisibleTurnsSince(&history, 0));
    // From cursor 3: only user c = 1.
    try testing.expectEqual(@as(usize, 1), countModelVisibleTurnsSince(&history, 3));
    // Out-of-range cursor falls back to counting all.
    try testing.expectEqual(@as(usize, 3), countModelVisibleTurnsSince(&history, 99));
}

test "extractWrittenPaths dedups auto-mem writes and excludes outside paths" {
    const a = testing.allocator;
    const mem_dir = "/home/u/.zcode/memory";
    const history = [_]types.HistoryTurn{
        toolTurn("tool=Write\nargs=file_path=\"/home/u/.zcode/memory/a.md\", content=\"x\"\nstate=auto_approved\nrisk=LOW\noutput=ok"),
        toolTurn("tool=Edit\nargs=file_path=\"/home/u/.zcode/memory/a.md\", old_string=\"x\", new_string=\"y\"\nstate=auto_approved\nrisk=LOW\noutput=ok"),
        toolTurn("tool=Write\nargs=file_path=\"/home/u/project/main.zig\", content=\"x\"\nstate=auto_approved\nrisk=LOW\noutput=ok"),
        toolTurn("tool=Write\nargs=file_path=\"/home/u/.zcode/memory/b.md\", content=\"x\"\nstate=auto_approved\nrisk=LOW\noutput=ok"),
    };
    const paths = try extractWrittenPaths(a, &history, 0, mem_dir);
    defer {
        for (paths) |p| a.free(p);
        a.free(paths);
    }
    // a.md (deduped across Write+Edit) and b.md; the project write is excluded.
    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expectEqualStrings("/home/u/.zcode/memory/a.md", paths[0]);
    try testing.expectEqualStrings("/home/u/.zcode/memory/b.md", paths[1]);
}

test "buildExtractAutoOnlyPrompt substitutes count and contains the taxonomy" {
    const a = testing.allocator;
    const manifest = "- [feedback] foo.md (2026-05-30T00:00:00Z): a hook\n";
    const prompt = try buildExtractAutoOnlyPrompt(a, 8, manifest, "/home/u/.zcode/memory");
    defer a.free(prompt);

    // Message-count substitution (appears twice in the opener).
    try testing.expect(std.mem.indexOf(u8, prompt, "most recent ~8 messages") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "last ~8 messages") != null);
    // The "only use content from the last" constraint.
    try testing.expect(std.mem.indexOf(u8, prompt, "only use content from the last") != null);
    // Four reference type names.
    try testing.expect(std.mem.indexOf(u8, prompt, "<name>user</name>") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "<name>feedback</name>") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "<name>project</name>") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "<name>reference</name>") != null);
    // The pre-injected manifest.
    try testing.expect(std.mem.indexOf(u8, prompt, "## Existing memory files") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "foo.md") != null);
    // Two-step save protocol.
    try testing.expect(std.mem.indexOf(u8, prompt, "Saving a memory is a two-step process") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "MEMORY.md") != null);
}

test "buildExtractAutoOnlyPrompt omits the manifest section when empty" {
    const a = testing.allocator;
    const prompt = try buildExtractAutoOnlyPrompt(a, 3, "", "/home/u/.zcode/memory");
    defer a.free(prompt);
    try testing.expect(std.mem.indexOf(u8, prompt, "## Existing memory files") == null);
}

test "extraction prompt contains no em or en dashes" {
    const a = testing.allocator;
    const prompt = try buildExtractAutoOnlyPrompt(a, 5, "- [user] x.md (ts): y\n", "/home/u/.zcode/memory");
    defer a.free(prompt);
    // U+2014 EM DASH and U+2013 EN DASH as UTF-8 byte sequences.
    try testing.expect(std.mem.indexOf(u8, prompt, "\xE2\x80\x94") == null);
    try testing.expect(std.mem.indexOf(u8, prompt, "\xE2\x80\x93") == null);
}
