//! Per-session background summarizer (memory-05).
//!
//! Maintains a per-session markdown "notes" file that distills the running
//! conversation into a stable, section-structured summary. A constrained
//! forked agent (Read + Edit on the one notes file, nothing else) updates the
//! file when token-growth and tool-call thresholds are crossed, plus a manual
//! `/summary`-triggered path that bypasses the thresholds.
//!
//! Ported from claude-code-main/src/services/SessionMemory:
//!   DEFAULT_SESSION_MEMORY_CONFIG        (sessionMemoryUtils.ts:32-36)
//!   hasMet{Init,Update}Threshold         (sessionMemoryUtils.ts:173-189)
//!   shouldExtractMemory                  (sessionMemory.ts:134-181)
//!   getSessionMemoryDir / *Path          (filesystem.ts:261-271)
//!   DEFAULT_SESSION_MEMORY_TEMPLATE      (prompts.ts:11-41)
//!   buildSessionMemoryUpdatePrompt       (prompts.ts:226-247)
//!   createMemoryFileCanUseTool           (sessionMemory.ts:460-482)
//!
//! Synchronous v1: the fork runs inline at turn end (the reference runs it as a
//! background post-sampling hook and drains it at shutdown). Async/post-sampling
//! execution is deferred per the phase's out-of-scope notes.
//!
//! NAMING DISAMBIGUATION: this is NOT the `.session_memory` *context-block* type
//! (types.zig:44 / context.zig:724) which carries a task-state snapshot into the
//! prompt. This module is conversation-notes distillation that lives in its own
//! per-session file under the sessions dir; the two features share only a name.

const std = @import("std");
const rt = @import("zcode_runtime");
const types = @import("types.zig");
const paths = @import("paths.zig");
const std_io = @import("std_io.zig");
const parse_helpers = @import("parse_helpers.zig");
const arg_parse = @import("../tools/arg_parse.zig");

/// Threshold configuration. Ports DEFAULT_SESSION_MEMORY_CONFIG
/// (sessionMemoryUtils.ts:32-36). The reference reads overrides from the
/// `tengu_sm_config` GrowthBook flag; zcode has no GrowthBook so these are
/// fixed defaults (per the phase's out-of-scope notes).
pub const Config = struct {
    /// Minimum context-window tokens before session memory initializes at all.
    minimum_tokens_to_init: usize = 10_000,
    /// Minimum context-window growth (tokens) between updates.
    minimum_tokens_between_update: usize = 5_000,
    /// Tool calls between updates.
    tool_calls_between_updates: u32 = 3,
};

pub const DEFAULT_CONFIG = Config{};

/// Hard cap on the summarizer child's tool rounds. The efficient strategy is
/// Read-then-Edit, so a couple of rounds is plenty; the cap prevents a
/// misbehaving fork from burning the turn budget.
pub const MAX_SESSION_MEMORY_ROUNDS: usize = 4;

/// Notes-file basename: `<session_id>.md`. Lives under
/// `<sessions_dir>/session-memory/`. The reference uses a fixed `summary.md`
/// inside a per-session subdir; zcode keys by session id so a single
/// session-memory dir holds one file per session and the path is stable for a
/// given session id without needing a per-session subdir.
pub const NOTES_SUBDIR = "session-memory";

/// Per-AgentRuntime session-memory state. Lives on the runtime so the
/// token/tool-call cursors survive across turns within one session and reset on
/// /clear. Default-init so both constructors get it for free.
pub const State = struct {
    /// Latched true once the init token threshold has been met at least once.
    initialized: bool = false,
    /// Context-window token count recorded at the last extraction. Update
    /// growth is measured against this.
    tokens_at_last_extraction: usize = 0,
    /// Tool calls observed since the last extraction. Incremented as turns are
    /// appended; reset to 0 when an extraction fires.
    tool_calls_since_last: u32 = 0,

    /// Reset to the initial state. Called from the /clear handler so a cleared
    /// conversation starts a fresh summarization window.
    pub fn reset(self: *State) void {
        self.initialized = false;
        self.tokens_at_last_extraction = 0;
        self.tool_calls_since_last = 0;
    }

    /// Record the context size at extraction and clear the tool-call counter.
    /// Mirrors recordExtractionTokenCount + the implicit tool-call reset.
    pub fn recordExtraction(self: *State, token_count: usize) void {
        self.tokens_at_last_extraction = token_count;
        self.tool_calls_since_last = 0;
    }
};

/// Decide whether the automatic summarizer should fire this turn. Ports
/// shouldExtractMemory (sessionMemory.ts:134-181):
///   1. Must meet the init token threshold once; that latches `initialized`.
///      Below the init threshold while not yet initialized -> false.
///   2. After init, fire when:
///        (token-growth threshold met AND tool-call threshold met), OR
///        (token-growth threshold met AND no tool calls in the last turn).
///      The token-growth threshold is ALWAYS required (the reference comment:
///      even if the tool-call threshold is met, extraction waits for the token
///      threshold to avoid excessive extractions).
///
/// `current_token_count` is the same context-window token count the autocompact
/// path uses, so the two features stay consistent. `tool_calls_since_last` and
/// `had_tool_calls_in_last_turn` come from the runtime's turn bookkeeping.
/// Mutates `state.initialized` (latches it) as a side effect, matching the
/// reference's `markSessionMemoryInitialized()`.
pub fn shouldExtract(
    state: *State,
    cfg: Config,
    current_token_count: usize,
    had_tool_calls_in_last_turn: bool,
) bool {
    if (!state.initialized) {
        if (current_token_count < cfg.minimum_tokens_to_init) return false;
        state.initialized = true;
    }

    const tokens_since = if (current_token_count >= state.tokens_at_last_extraction)
        current_token_count - state.tokens_at_last_extraction
    else
        0;
    const met_token_threshold = tokens_since >= cfg.minimum_tokens_between_update;

    const met_tool_threshold = state.tool_calls_since_last >= cfg.tool_calls_between_updates;

    return (met_token_threshold and met_tool_threshold) or
        (met_token_threshold and !had_tool_calls_in_last_turn);
}

/// True when the most recent assistant turn contains a tool call. Ports
/// hasToolCallsInLastAssistantTurn (messages.ts:341-353): scan backwards for the
/// last assistant turn; in zcode's turn-based history a tool call is recorded as
/// a separate `.tool` turn immediately after the assistant turn that requested
/// it, so "the last assistant turn had tool calls" maps to "the last
/// model-visible turn is a tool turn (or a tool turn follows the last assistant
/// turn with no intervening user turn)".
pub fn hadToolCallsInLastTurn(history: []const types.HistoryTurn) bool {
    // Walk backwards. The first user turn we hit means the conversation moved
    // on to a new exchange; a tool turn before any assistant/user turn means
    // the last assistant action requested tools.
    var i = history.len;
    while (i > 0) {
        i -= 1;
        switch (history[i].role) {
            .tool => return true,
            .assistant => return false,
            .user => return false,
            .system => {}, // skip nudges
        }
    }
    return false;
}

/// Count tool turns in `history`. Used by the runtime to advance
/// `tool_calls_since_last`. A `.tool` turn is one recorded tool invocation.
pub fn countToolTurns(history: []const types.HistoryTurn) u32 {
    var n: u32 = 0;
    for (history) |turn| {
        if (turn.role == .tool) n += 1;
    }
    return n;
}

/// Resolve the per-session notes-file directory:
///   `<sessions_dir>/session-memory`
/// Caller owns the returned slice.
pub fn notesDir(allocator: std.mem.Allocator, sessions_dir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ sessions_dir, NOTES_SUBDIR });
}

/// Resolve the per-session notes-file path:
///   `<sessions_dir>/session-memory/<session_id>.md`
/// Stable for a given (sessions_dir, session_id) pair across calls within a
/// session. Caller owns the returned slice.
pub fn notesPath(
    allocator: std.mem.Allocator,
    sessions_dir: []const u8,
    session_id: []const u8,
) ![]u8 {
    const dir = try notesDir(allocator, sessions_dir);
    defer allocator.free(dir);
    const filename = try std.fmt.allocPrint(allocator, "{s}.md", .{session_id});
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ dir, filename });
}

/// The notes-file skeleton written on first creation. Ports
/// DEFAULT_SESSION_MEMORY_TEMPLATE (prompts.ts:11-41). The italic
/// `_description_` lines are template instructions the fork must preserve.
pub const DEFAULT_TEMPLATE =
    \\# Session Title
    \\_A short and distinctive 5-10 word descriptive title for the session. Super info dense, no filler_
    \\
    \\# Current State
    \\_What is actively being worked on right now? Pending tasks not yet completed. Immediate next steps._
    \\
    \\# Task specification
    \\_What did the user ask to build? Any design decisions or other explanatory context_
    \\
    \\# Files and Functions
    \\_What are the important files? In short, what do they contain and why are they relevant?_
    \\
    \\# Workflow
    \\_What bash commands are usually run and in what order? How to interpret their output if not obvious?_
    \\
    \\# Errors and Corrections
    \\_Errors encountered and how they were fixed. What did the user correct? What approaches failed and should not be tried again?_
    \\
    \\# Codebase and System Documentation
    \\_What are the important system components? How do they work/fit together?_
    \\
    \\# Learnings
    \\_What has worked well? What has not? What to avoid? Do not duplicate items from other sections_
    \\
    \\# Key results
    \\_If the user asked a specific output such as an answer to a question, a table, or other document, repeat the exact result here_
    \\
    \\# Worklog
    \\_Step by step, what was attempted, done? Very terse summary for each step_
    \\
;

/// Ensure the notes file exists, creating it from the template on first use
/// without clobbering an existing file. O_EXCL create then template-write
/// (matching the reference's `flag: 'wx'` create-if-absent discipline), so a
/// concurrent writer or a prior session's notes are never overwritten. Returns
/// the current file contents. Caller owns the returned slice.
pub fn ensureNotesFile(
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    // Make the parent dir.
    if (std.fs.path.dirname(path)) |parent| {
        paths.ensureDir(parent) catch {};
    }

    // Try to create exclusively; on success write the template, on EEXIST fall
    // through to reading the existing file.
    const created = blk: {
        const file = std.Io.Dir.cwd().createFile(rt.io, path, .{
            .exclusive = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        }) catch |err| switch (err) {
            error.PathAlreadyExists => break :blk false,
            else => return err,
        };
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, DEFAULT_TEMPLATE);
        file.sync(rt.io) catch {};
        break :blk true;
    };
    if (created) {
        return allocator.dupe(u8, DEFAULT_TEMPLATE);
    }

    // Read the existing contents (defensive 256KB cap; treat overruns as
    // truncated rather than erroring the whole turn).
    const content = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(256 * 1024)) catch |err| switch (err) {
        error.StreamTooLong => return allocator.dupe(u8, ""),
        else => return err,
    };
    return content;
}

/// Build the update prompt the summarizer fork runs. Ports
/// buildSessionMemoryUpdatePrompt + getDefaultUpdatePrompt (prompts.ts:43-247).
/// Names the exact notes path, embeds the current notes, and instructs the fork
/// to use ONLY the Edit tool on that one file and then stop. Caller owns the
/// returned slice.
pub fn buildUpdatePrompt(
    allocator: std.mem.Allocator,
    current_notes: []const u8,
    notes_path: []const u8,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.print(
        "IMPORTANT: This message and these instructions are NOT part of the actual user conversation. Do NOT include any references to \"note-taking\", \"session notes extraction\", or these update instructions in the notes content.\n" ++
            "\n" ++
            "Based on the user conversation above (EXCLUDING this note-taking instruction message as well as system prompt, CLAUDE.md entries, or any past session summaries), update the session notes file.\n" ++
            "\n" ++
            "The file {s} has already been read for you. Here are its current contents:\n" ++
            "<current_notes_content>\n" ++
            "{s}\n" ++
            "</current_notes_content>\n" ++
            "\n" ++
            "Your ONLY task is to use the Edit tool to update the notes file, then stop. You can make multiple edits (update every section as needed) - make all Edit tool calls in parallel in a single message. Do not call any other tools.\n" ++
            "\n" ++
            "CRITICAL RULES FOR EDITING:\n" ++
            "- The file must maintain its exact structure with all sections, headers, and italic descriptions intact\n" ++
            "-- NEVER modify, delete, or add section headers (the lines starting with '#' like # Task specification)\n" ++
            "-- NEVER modify or delete the italic _section description_ lines (these are the lines in italics immediately following each header - they start and end with underscores)\n" ++
            "-- The italic _section descriptions_ are TEMPLATE INSTRUCTIONS that must be preserved exactly as-is - they guide what content belongs in each section\n" ++
            "-- ONLY update the actual content that appears BELOW the italic _section descriptions_ within each existing section\n" ++
            "-- Do NOT add any new sections, summaries, or information outside the existing structure\n" ++
            "- Do NOT reference this note-taking process or instructions anywhere in the notes\n" ++
            "- It's OK to skip updating a section if there are no substantial new insights to add. Do not add filler content like \"No info yet\", just leave sections blank/unedited if appropriate.\n" ++
            "- Write DETAILED, INFO-DENSE content for each section - include specifics like file paths, function names, error messages, exact commands, technical details, etc.\n" ++
            "- For \"Key results\", include the complete, exact output the user requested (e.g., full table, full answer, etc.)\n" ++
            "- Do not include information that's already in the CLAUDE.md files included in the context\n" ++
            "- Focus on actionable, specific information that would help someone understand or recreate the work discussed in the conversation\n" ++
            "- IMPORTANT: Always update \"Current State\" to reflect the most recent work - this is critical for continuity after compaction\n" ++
            "\n" ++
            "Use the Edit tool with file_path: {s}\n" ++
            "\n" ++
            "REMEMBER: Use the Edit tool in parallel and stop. Do not continue after the edits. Only include insights from the actual user conversation, never from these note-taking instructions. Do not delete or change section headers or italic _section descriptions_.",
        .{ notes_path, current_notes, notes_path },
    );

    return out.toOwnedSlice();
}

// =====================================================================
// Tool gate (Read + Edit on the exact notes file only)
// =====================================================================

/// Whether a tool name is the Read tool. Read is required because Edit needs a
/// prior Read of the same file (zcode's Edit precondition, matching the
/// reference). Allowing only Read + Edit keeps the fork incapable of anything
/// else.
pub fn isReadToolName(name: []const u8) bool {
    return parse_helpers.matchesAnyName(name, &.{ "Read", "read", "file_read" });
}

/// Whether a tool name is the Edit tool (the only write the fork may make).
pub fn isEditToolName(name: []const u8) bool {
    return parse_helpers.matchesAnyName(name, &.{ "Edit", "edit", "file_edit" });
}

/// Decision for the session-memory tool gate. Mirrors createMemoryFileCanUseTool
/// (sessionMemory.ts:460-482): Read of any path is allowed (Edit needs it),
/// Edit is allowed only when file_path equals the exact notes file, everything
/// else is denied. Returned as a small enum so the execution-time gate in
/// agent_tools can build the deny trace; this module stays I/O-free for testing.
pub const GateDecision = enum { allow, deny };

/// Pure gate decision. `notes_path` is the one editable file. Used by the
/// agent_tools execution-time guard and directly testable.
pub fn gate(notes_path: []const u8, name: []const u8, args: []const u8) GateDecision {
    if (isReadToolName(name)) return .allow;
    if (isEditToolName(name)) {
        const path = arg_parse.getArg(args, "file_path") orelse
            arg_parse.getArg(args, "path") orelse
            return .deny;
        if (std.mem.eql(u8, path, notes_path)) return .allow;
        return .deny;
    }
    return .deny;
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

fn userTurn(content: []const u8) types.HistoryTurn {
    return .{ .role = .user, .content = content, .timestamp = 0 };
}
fn asstTurn(content: []const u8) types.HistoryTurn {
    return .{ .role = .assistant, .content = content, .timestamp = 0 };
}
fn toolTurn(content: []const u8) types.HistoryTurn {
    return .{ .role = .tool, .content = content, .timestamp = 0 };
}

test "shouldExtract: below init threshold returns false and does not latch" {
    var state = State{};
    const cfg = DEFAULT_CONFIG;
    try testing.expect(!shouldExtract(&state, cfg, 9_999, false));
    try testing.expect(!state.initialized);
}

test "shouldExtract: meeting init threshold latches initialized" {
    var state = State{};
    const cfg = DEFAULT_CONFIG;
    // At exactly the init threshold, initialized latches. tokens_at_last is 0,
    // so growth = 10000 >= 5000 (token threshold met); no tool calls in last
    // turn -> fires.
    try testing.expect(shouldExtract(&state, cfg, 10_000, false));
    try testing.expect(state.initialized);
}

test "shouldExtract: after init requires token growth AND (tool-call OR no-tools-last-turn)" {
    var state = State{ .initialized = true, .tokens_at_last_extraction = 10_000 };
    const cfg = DEFAULT_CONFIG;

    // Token growth below the between-update threshold -> never fires, even with
    // many tool calls and no tools in the last turn.
    state.tool_calls_since_last = 10;
    try testing.expect(!shouldExtract(&state, cfg, 14_000, false)); // growth 4000 < 5000

    // Token growth met, tool-call threshold met -> fires.
    state.tool_calls_since_last = 3;
    try testing.expect(shouldExtract(&state, cfg, 15_000, true)); // growth 5000, tools>=3

    // Token growth met, tool-call threshold NOT met, but no tools in last turn
    // -> fires (natural-break case).
    state.tool_calls_since_last = 0;
    try testing.expect(shouldExtract(&state, cfg, 15_000, false));

    // Token growth met, tool-call threshold NOT met, AND tools were in the last
    // turn -> does NOT fire (avoid orphaning an in-flight tool round).
    state.tool_calls_since_last = 1;
    try testing.expect(!shouldExtract(&state, cfg, 15_000, true));
}

test "State.recordExtraction updates token cursor and clears tool-call count" {
    var state = State{ .initialized = true, .tokens_at_last_extraction = 10_000, .tool_calls_since_last = 5 };
    state.recordExtraction(20_000);
    try testing.expectEqual(@as(usize, 20_000), state.tokens_at_last_extraction);
    try testing.expectEqual(@as(u32, 0), state.tool_calls_since_last);
}

test "State.reset clears initialization, token cursor, and tool count" {
    var state = State{ .initialized = true, .tokens_at_last_extraction = 9, .tool_calls_since_last = 4 };
    state.reset();
    try testing.expect(!state.initialized);
    try testing.expectEqual(@as(usize, 0), state.tokens_at_last_extraction);
    try testing.expectEqual(@as(u32, 0), state.tool_calls_since_last);
}

test "hadToolCallsInLastTurn: tool turn after assistant counts as tools in last turn" {
    const history = [_]types.HistoryTurn{
        userTurn("do something"),
        asstTurn("calling a tool"),
        toolTurn("tool=Read\nargs=...\nstate=auto_approved\nrisk=LOW\noutput=x"),
    };
    try testing.expect(hadToolCallsInLastTurn(&history));
}

test "hadToolCallsInLastTurn: plain assistant final answer has no tools" {
    const history = [_]types.HistoryTurn{
        userTurn("what is 2+2"),
        asstTurn("4"),
    };
    try testing.expect(!hadToolCallsInLastTurn(&history));
}

test "countToolTurns counts only tool turns" {
    const history = [_]types.HistoryTurn{
        userTurn("a"),
        asstTurn("b"),
        toolTurn("tool=Read\nargs=...\nstate=ok\noutput=x"),
        toolTurn("tool=Grep\nargs=...\nstate=ok\noutput=y"),
        asstTurn("done"),
    };
    try testing.expectEqual(@as(u32, 2), countToolTurns(&history));
}

test "notesPath is session-scoped and stable across calls" {
    const a = testing.allocator;
    const sessions_dir = "/home/u/.zcode/sessions";
    const p1 = try notesPath(a, sessions_dir, "1700000000-abcdef");
    defer a.free(p1);
    const p2 = try notesPath(a, sessions_dir, "1700000000-abcdef");
    defer a.free(p2);
    try testing.expectEqualStrings(p1, p2);
    try testing.expect(std.mem.indexOf(u8, p1, "session-memory") != null);
    try testing.expect(std.mem.endsWith(u8, p1, "1700000000-abcdef.md"));
    // Distinct session ids produce distinct paths.
    const p3 = try notesPath(a, sessions_dir, "1700000001-feedca");
    defer a.free(p3);
    try testing.expect(!std.mem.eql(u8, p1, p3));
}

test "buildUpdatePrompt names the exact notes path and instructs Edit-only" {
    const a = testing.allocator;
    const path = "/home/u/.zcode/sessions/session-memory/sid.md";
    const prompt = try buildUpdatePrompt(a, "# Session Title\n_x_\n", path);
    defer a.free(prompt);

    // The exact path appears (in the "has already been read" line and the
    // "Use the Edit tool with file_path:" line).
    try testing.expect(std.mem.indexOf(u8, prompt, path) != null);
    // Edit-only instruction.
    try testing.expect(std.mem.indexOf(u8, prompt, "Your ONLY task is to use the Edit tool") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Do not call any other tools.") != null);
    // The current notes are embedded.
    try testing.expect(std.mem.indexOf(u8, prompt, "# Session Title") != null);
    // No em or en dashes.
    try testing.expect(std.mem.indexOf(u8, prompt, "\xE2\x80\x94") == null);
    try testing.expect(std.mem.indexOf(u8, prompt, "\xE2\x80\x93") == null);
}

test "gate allows Read of any path and Edit only on the notes file" {
    const notes = "/home/u/.zcode/sessions/session-memory/sid.md";
    // Read anywhere is allowed (Edit needs a prior Read).
    try testing.expectEqual(GateDecision.allow, gate(notes, "Read", "file_path=\"/etc/passwd\""));
    // Edit on the exact notes file is allowed.
    try testing.expectEqual(GateDecision.allow, gate(notes, "Edit", "file_path=\"/home/u/.zcode/sessions/session-memory/sid.md\", old_string=\"a\", new_string=\"b\""));
    // Edit on any other file is denied.
    try testing.expectEqual(GateDecision.deny, gate(notes, "Edit", "file_path=\"/home/u/project/main.zig\""));
    // Edit with no file_path is denied.
    try testing.expectEqual(GateDecision.deny, gate(notes, "Edit", "old_string=\"a\""));
    // Any other tool is denied.
    try testing.expectEqual(GateDecision.deny, gate(notes, "Write", "file_path=\"/home/u/.zcode/sessions/session-memory/sid.md\""));
    try testing.expectEqual(GateDecision.deny, gate(notes, "Bash", "command=\"ls\""));
    try testing.expectEqual(GateDecision.deny, gate(notes, "WebFetch", "url=\"http://x\""));
}

test "ensureNotesFile creates from template then returns existing on second call" {
    const a = testing.allocator;
    const th = @import("test_helpers.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try th.tmpDirCwd(a, &tmp);
    defer a.free(dir);

    const path = try std.fs.path.join(a, &.{ dir, "session-memory", "sid.md" });
    defer a.free(path);

    const first = try ensureNotesFile(a, path);
    defer a.free(first);
    try testing.expectEqualStrings(DEFAULT_TEMPLATE, first);

    // Mutate the file on disk so a second call must return the on-disk content
    // (proving it does not clobber).
    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, path, .{ .truncate = true });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, "# Session Title\n_edited_\n");
    }
    const second = try ensureNotesFile(a, path);
    defer a.free(second);
    try testing.expectEqualStrings("# Session Title\n_edited_\n", second);
}
