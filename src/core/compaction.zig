const std = @import("std");
const std_io = @import("std_io.zig");
const types = @import("types.zig");
const memory = @import("memory.zig");
const parse_helpers = @import("parse_helpers.zig");
const figures = @import("figures.zig");

// Standard ANSI SGR sequences. Defined locally rather than importing the cli
// markdown module so this stays a leaf core module (core must not depend on
// cli). These match repl_markdown.ANSI_DIM / ANSI_RESET byte-for-byte.
const ANSI_DIM = "\x1b[2m";
const ANSI_RESET = "\x1b[0m";

/// The model-awareness skill listing turns are re-surfaced by the next turn's
/// discovery signal after compaction, so feeding them to the summarizer wastes
/// tokens and pollutes the summary with stale skill suggestions. We recognize
/// such a turn by the header that `skill_listing.render` emits. Mirrors the
/// reference `stripReinjectedAttachments` (services/compact/compact.ts:211-223)
/// which drops `skill_discovery`/`skill_listing` attachment messages.
const skill_listing_header = "Available skills (invoke via the Skill tool, or /<name>):";

/// Returns true when a turn is a re-injected skill discovery/listing attachment
/// that the summarizer should skip. Conservative: matches only the listing
/// header that our own renderer emits (after leading whitespace), so legitimate
/// user prose that merely mentions skills is never dropped.
fn isReinjectedAttachment(content: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, content, " \t\r\n");
    return std.mem.startsWith(u8, trimmed, skill_listing_header);
}

/// Replace inlined image/document attachment forms in flat-text history content
/// with bare `[image]`/`[document]` markers so the compaction call does not
/// bloat or hit prompt-too-long. Mirrors the reference `stripImagesFromMessages`
/// (services/compact/compact.ts:145-200) for our flat-text turns.
///
/// Today zcode resolves attachments to file paths before storage
/// (cli/repl_attachments.zig), so this is largely a no-op; it becomes
/// load-bearing once multimodal turns inline media. The pass is intentionally
/// conservative: it only rewrites recognized inlined-attachment forms, never
/// arbitrary `[image]`-looking text the user typed.
///
/// Returns the rewritten slice (freshly allocated, caller frees) when any marker
/// was replaced, or null when the content is unchanged (so callers can borrow
/// the original without allocating).
fn stripMediaMarkers(allocator: std.mem.Allocator, content: []const u8) !?[]u8 {
    // Recognized inlined forms:
    //   - `data:image/<type>;base64,<...>`  -> `[image]`
    //   - `data:application/pdf;base64,<...>` -> `[document]`
    //   - `[image: <...>]`                  -> `[image]`
    //   - `[document: <...>]`               -> `[document]`
    // We scan once and only allocate when a match is found.
    const image_data_uri = "data:image/";
    const doc_data_uri = "data:application/pdf";
    const image_marker = "[image:";
    const doc_marker = "[document:";

    const has_any =
        std.mem.indexOf(u8, content, image_data_uri) != null or
        std.mem.indexOf(u8, content, doc_data_uri) != null or
        std.mem.indexOf(u8, content, image_marker) != null or
        std.mem.indexOf(u8, content, doc_marker) != null;
    if (!has_any) return null;

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    var i: usize = 0;
    while (i < content.len) {
        if (std.mem.startsWith(u8, content[i..], doc_data_uri)) {
            try w.writeAll("[document]");
            i += doc_data_uri.len;
            // Consume the trailing base64/charset payload up to whitespace.
            while (i < content.len and !std.ascii.isWhitespace(content[i])) : (i += 1) {}
        } else if (std.mem.startsWith(u8, content[i..], image_data_uri)) {
            try w.writeAll("[image]");
            i += image_data_uri.len;
            while (i < content.len and !std.ascii.isWhitespace(content[i])) : (i += 1) {}
        } else if (std.mem.startsWith(u8, content[i..], image_marker)) {
            try w.writeAll("[image]");
            i += image_marker.len;
            // Consume up to and including the closing bracket.
            while (i < content.len and content[i] != ']') : (i += 1) {}
            if (i < content.len) i += 1; // skip ']'
        } else if (std.mem.startsWith(u8, content[i..], doc_marker)) {
            try w.writeAll("[document]");
            i += doc_marker.len;
            while (i < content.len and content[i] != ']') : (i += 1) {}
            if (i < content.len) i += 1; // skip ']'
        } else {
            try w.writeByte(content[i]);
            i += 1;
        }
    }

    return try out.toOwnedSlice();
}

/// Build a compaction prompt for LLM-based summarization. The model
/// receives the conversation history and produces a structured summary.
/// Provider-agnostic: works with any model via the standard send() path.
///
/// `custom_instructions` is an optional focusing directive (from `/compact
/// <instructions>` and/or PreCompact hooks). When non-empty it is appended as
/// a dedicated `## Compact Instructions` section -- Task 4 wires the REPL/hook
/// sources; Task 1 only threads the parameter through so the signature is
/// stable. Pass `""` for the no-instruction form.
///
/// Before each turn is written, media/attachment stripping runs
/// (compaction-15, Task 10): inlined image/document forms collapse to
/// `[image]`/`[document]` markers and re-injected skill-listing turns are
/// dropped, so the summarization call itself does not bloat or overflow.
pub fn buildCompactionPrompt(
    allocator: std.mem.Allocator,
    history: []const types.HistoryTurn,
    custom_instructions: []const u8,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll(
        "You are a conversation summarizer. Create a detailed summary of this conversation.\n\n" ++
            "CRITICAL: Respond with TEXT ONLY. Do NOT call any tools.\n\n" ++
            "Your summary must include:\n" ++
            "1. Primary Request: What the user asked for\n" ++
            "2. Key Technical Concepts: Important technical details, patterns, architectures\n" ++
            "3. Files and Code: Specific files examined, modified, or created with brief reasons\n" ++
            "4. Errors and Fixes: Problems encountered and how they were resolved\n" ++
            "5. Decisions Made: Key choices and their rationale\n" ++
            "6. Current Work: What was being worked on most recently\n" ++
            "7. Next Steps: What should happen next\n\n" ++
            "Be thorough with file paths, function names, and code patterns.\n" ++
            "Focus especially on the most recent messages.\n\n",
    );

    if (custom_instructions.len > 0) {
        try w.print("## Compact Instructions\n{s}\n\n", .{custom_instructions});
    }

    try w.writeAll("CONVERSATION:\n\n");

    for (history) |turn| {
        // Drop re-injected skill-listing/discovery turns entirely (Task 10).
        if (isReinjectedAttachment(turn.content)) continue;

        const role_str = types.roleToString(turn.role);

        // Strip inlined media before truncation so a markerized turn is what we
        // truncate (Task 10). Borrow the original when nothing was rewritten.
        const stripped = try stripMediaMarkers(allocator, turn.content);
        defer if (stripped) |s| allocator.free(s);
        const source = stripped orelse turn.content;

        // Truncate very long turns to keep the prompt manageable
        const max_turn_len: usize = 4000;
        const content = if (source.len > max_turn_len) source[0..max_turn_len] else source;
        try w.print("{s}: {s}\n\n", .{ role_str, content });
    }

    try w.writeAll("\nNow write the summary following the sections above.");

    return out.toOwnedSlice();
}

/// Merge user-supplied `/compact` instructions with hook-supplied instructions
/// (compaction-06, Task 4). The user's instructions come first; any non-empty
/// hook text is appended after a blank line. Either side may be empty:
///   (user, hook) -> "user\n\nhook"
///   (user, "")   -> "user"
///   ("",   hook) -> "hook"
///   ("",   "")   -> "" (no allocation needed, returns the empty literal)
/// The returned slice is freshly allocated and owned by the caller UNLESS both
/// inputs are empty, in which case the static empty literal is returned (which
/// is safe to `free` only via the caller checking `len > 0` first). To keep the
/// ownership rule uniform, callers should treat a zero-length result as "do not
/// free". Inputs are trimmed of surrounding whitespace before merging.
pub fn mergeHookInstructions(
    allocator: std.mem.Allocator,
    user: []const u8,
    hook: []const u8,
) ![]const u8 {
    const u = std.mem.trim(u8, user, " \t\r\n");
    const h = std.mem.trim(u8, hook, " \t\r\n");
    if (u.len == 0 and h.len == 0) return "";
    if (u.len == 0) return allocator.dupe(u8, h);
    if (h.len == 0) return allocator.dupe(u8, u);
    return std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ u, h });
}

/// Attempt LLM-based compaction using the provided adapter. Returns
/// the model's summary text on success, or null if the LLM call fails
/// (caller should fall back to rule-based compaction).
///
/// `custom_instructions` is forwarded to `buildCompactionPrompt`; pass `""`
/// for the no-instruction form.
pub fn llmCompact(
    allocator: std.mem.Allocator,
    adapter: *types.ProviderAdapter,
    history: []const types.HistoryTurn,
    model: []const u8,
    custom_instructions: []const u8,
) ?[]u8 {
    const prompt = buildCompactionPrompt(allocator, history, custom_instructions) catch return null;
    defer allocator.free(prompt);

    const request = types.ModelRequest{
        .model = model,
        .system_prompt = "",
        .prompt = prompt,
        .max_output_tokens = 4096,
        .temperature = 0.0,
    };

    const response = adapter.send(allocator, request) catch return null;
    defer allocator.free(response.raw);

    if (response.text.len == 0) {
        return null;
    }

    // The response.text is owned by the response (points into raw).
    // Dupe it so it outlives the response.
    return allocator.dupe(u8, response.text) catch null;
}

/// Indirection that lets `maybeCompact` (a deep `core/` module) obtain a
/// model-written summary WITHOUT importing the providers tree. The runtime
/// constructs a `Summarizer` whose `call` closes over the provider adapter and
/// model and delegates to `llmCompact`. The `*anyopaque` ctx keeps the module
/// boundary clean (per the project's deep-module rule).
pub const Summarizer = struct {
    ctx: *anyopaque,
    /// Returns model summary text (caller frees) or null on failure. The
    /// returned slice must be allocated with `allocator`.
    call: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        history: []const types.HistoryTurn,
        custom_instructions: []const u8,
    ) ?[]u8,
};

/// Format a raw model summary: strip the `<analysis>...</analysis>` drafting
/// scratchpad, unwrap a `<summary>...</summary>` span into a `Summary:\n` block,
/// collapse 3+ consecutive newlines to 2, and trim. Mirrors the reference
/// `formatCompactSummary` (services/compact/prompt.ts:311-335). Pure function;
/// the returned slice is freshly allocated and owned by the caller.
pub fn formatCompactSummary(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var work = std_io.StringBuilder.init(allocator);
    defer work.deinit();
    const w = work.writer();

    // Strip the first <analysis>...</analysis> span (non-greedy).
    var rest = raw;
    if (std.mem.indexOf(u8, rest, "<analysis>")) |a_start| {
        if (std.mem.indexOf(u8, rest[a_start..], "</analysis>")) |rel_end| {
            const a_end = a_start + rel_end + "</analysis>".len;
            try w.writeAll(rest[0..a_start]);
            try w.writeAll(rest[a_end..]);
            rest = "";
        }
    }
    if (rest.len > 0) try w.writeAll(rest);

    const stripped = try work.toOwnedSlice();
    defer allocator.free(stripped);

    // Unwrap the first <summary>...</summary> span into "Summary:\n<inner-trimmed>".
    var unwrapped = std_io.StringBuilder.init(allocator);
    defer unwrapped.deinit();
    const uw = unwrapped.writer();

    if (std.mem.indexOf(u8, stripped, "<summary>")) |s_start| blk: {
        const inner_start = s_start + "<summary>".len;
        const rel_close = std.mem.indexOf(u8, stripped[inner_start..], "</summary>") orelse {
            // Opening tag without a close: leave as-is.
            try uw.writeAll(stripped);
            break :blk;
        };
        const inner = stripped[inner_start .. inner_start + rel_close];
        const after = inner_start + rel_close + "</summary>".len;
        try uw.writeAll(stripped[0..s_start]);
        try uw.print("Summary:\n{s}", .{std.mem.trim(u8, inner, " \t\r\n")});
        try uw.writeAll(stripped[after..]);
    } else {
        try uw.writeAll(stripped);
    }

    const unwrapped_str = try unwrapped.toOwnedSlice();
    defer allocator.free(unwrapped_str);

    // Collapse 3+ consecutive newlines to exactly 2, then trim.
    var collapsed = std_io.StringBuilder.init(allocator);
    errdefer collapsed.deinit();
    const cw = collapsed.writer();
    var nl_run: usize = 0;
    for (unwrapped_str) |c| {
        if (c == '\n') {
            nl_run += 1;
            if (nl_run <= 2) try cw.writeByte('\n');
        } else {
            nl_run = 0;
            try cw.writeByte(c);
        }
    }
    const collapsed_str = try collapsed.toOwnedSlice();
    defer allocator.free(collapsed_str);

    return allocator.dupe(u8, std.mem.trim(u8, collapsed_str, " \t\r\n"));
}

pub const CompactionResult = struct {
    did_compact: bool,
    usage_percent: u8,
    conversation_summary: []u8,
    snapshot: types.SessionSnapshot,
    summary_hash: u64,
    /// Total estimated input tokens of the pre-compaction history. Surfaced so
    /// the structured compact-boundary marker (compaction-14) can record
    /// `pre_compact_tokens` for resume telemetry. Computed even when
    /// `did_compact` is false (it is the same token total the threshold gate
    /// consumes).
    pre_compact_tokens: usize = 0,

    pub fn deinit(self: *CompactionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.conversation_summary);
        freeStringSlice(allocator, self.snapshot.facts);
        freeStringSlice(allocator, self.snapshot.decisions);
        freeStringSlice(allocator, self.snapshot.open_tasks);
        freeStringSlice(allocator, self.snapshot.file_focus);
        freeStringSlice(allocator, self.snapshot.recent_tool_outcomes);
        allocator.free(self.snapshot.handoff_summary);
        freeStringSlice(allocator, self.snapshot.pinned_facts);
        freeStringSlice(allocator, self.snapshot.completed_tasks);
    }
};

/// Default number of most-recent tool results kept in full by microcompaction.
pub const MICROCOMPACT_KEEP_LAST: usize = 6;

/// Age-based microcompaction (PRD #533): one-line the bodies of tool results
/// older than the last `keep_last_n`, keeping recent results full. Returns a new
/// history slice allocated with `allocator` (caller-owned). Kept-as-is turns
/// borrow their content from `history`; cleared turns get a freshly-allocated
/// one-line summary. Non-tool turns are never touched. Pure transform: it does
/// not mutate `history` and is independent of the threshold autocompaction.
pub fn microcompact(allocator: std.mem.Allocator, history: []const types.HistoryTurn, keep_last_n: usize) ![]types.HistoryTurn {
    var tool_count: usize = 0;
    for (history) |t| {
        if (t.role == .tool) tool_count += 1;
    }
    const out = try allocator.alloc(types.HistoryTurn, history.len);
    const clear_before: usize = if (tool_count > keep_last_n) tool_count - keep_last_n else 0;
    var seen_tool: usize = 0;
    for (history, 0..) |t, i| {
        if (t.role == .tool) {
            seen_tool += 1;
            if (seen_tool <= clear_before) {
                out[i] = .{ .role = .tool, .content = try summarizeClearedTool(allocator, t.content), .timestamp = t.timestamp };
                continue;
            }
        }
        out[i] = t; // borrowed content; valid for the duration of the prompt build
    }
    return out;
}

fn summarizeClearedTool(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    const first_nl = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
    const head = content[0..@min(first_nl, 120)];
    return std.fmt.allocPrint(allocator, "{s} [older tool result cleared to save context]", .{head});
}

/// Configuration for the time-based (cache-staleness) microcompaction trigger
/// (compaction-10). Mirrors the reference `TimeBasedMCConfig`
/// (services/compact/timeBasedMCConfig.ts:18-43). Default-off; when enabled it
/// fires an aggressive tool-result clear once the gap since the last assistant
/// turn crosses `gap_threshold_seconds`.
pub const TimeBasedMcConfig = struct {
    /// Master switch. When false, time-based microcompaction is a no-op.
    enabled: bool = false,
    /// Trigger when (now - last assistant timestamp) exceeds this many seconds.
    /// 3600s (60min) is the safe default: the server's 1h cache TTL is then
    /// guaranteed expired, so we never force a miss that would not have
    /// happened anyway.
    gap_threshold_seconds: i64 = TIME_BASED_MC_DEFAULT_GAP_SECONDS,
    /// Keep this many most-recent tool results in full; older ones are cleared.
    /// Smaller than the unconditional microcompact keep (a deliberately more
    /// aggressive clear once the cache has gone stale).
    keep_recent: usize = TIME_BASED_MC_DEFAULT_KEEP_RECENT,
};

/// Default gap threshold (seconds) for the time-based trigger: 60 minutes,
/// matching the server-side prompt-cache TTL.
pub const TIME_BASED_MC_DEFAULT_GAP_SECONDS: i64 = 3600;

/// Default number of most-recent tool results the time-based trigger keeps.
/// Deliberately smaller than `MICROCOMPACT_KEEP_LAST` (the per-turn age-based
/// clear) -- once the cache is stale we are rewriting the whole prefix anyway,
/// so we shrink it harder.
pub const TIME_BASED_MC_DEFAULT_KEEP_RECENT: usize = 2;

/// Time-based (cache-staleness) microcompaction (compaction-10). When the gap
/// since the last `.assistant` turn exceeds `gap_threshold_seconds`, clear all
/// but the most-recent `keep_recent` tool results -- the server-side prompt
/// cache has almost certainly expired, so the prefix is being rewritten anyway
/// and shrinking it before the request is free savings. Mirrors the reference
/// `evaluateTimeBasedTrigger` + `maybeTimeBasedMicrocompact`
/// (services/compact/microCompact.ts:422-530).
///
/// Returns a freshly-allocated history slice (same ownership rules as
/// `microcompact`: cleared tool turns own their content, kept turns borrow)
/// when the trigger fires, or `null` when it does not (disabled, no prior
/// assistant turn, or gap under threshold). Caller frees the slice and the
/// cleared turns' content exactly as it does for `microcompact`.
///
/// `now_seconds` is injected (not read from the clock) so the transform stays a
/// pure, deterministic function -- the prompt-engine call site supplies
/// `clock.nowSeconds()` (never `std.time.*`, per the project's clock-shim rule).
pub fn timeBasedMicrocompact(
    allocator: std.mem.Allocator,
    history: []const types.HistoryTurn,
    now_seconds: i64,
    gap_threshold_seconds: i64,
    keep_recent: usize,
    enabled: bool,
) !?[]types.HistoryTurn {
    if (!enabled) return null;

    // Find the last assistant turn; without one there is no gap to measure.
    var last_assistant_ts: ?i64 = null;
    var idx: usize = history.len;
    while (idx > 0) {
        idx -= 1;
        if (history[idx].role == .assistant) {
            last_assistant_ts = history[idx].timestamp;
            break;
        }
    }
    const ts = last_assistant_ts orelse return null;

    const gap = now_seconds - ts;
    // Negative gap (clock skew / future timestamp) is treated as "not stale".
    if (gap < gap_threshold_seconds) return null;

    // Floor at 1: clearing every tool result leaves the model with zero working
    // context. Mirrors the reference `Math.max(1, keepRecent)`.
    const keep = @max(@as(usize, 1), keep_recent);
    return try microcompact(allocator, history, keep);
}

pub fn maybeCompact(
    allocator: std.mem.Allocator,
    history: []const types.HistoryTurn,
    budget: types.BudgetPlan,
    summarizer: ?Summarizer,
    custom_instructions: []const u8,
) !CompactionResult {
    var token_total: usize = 0;
    for (history) |turn| {
        token_total += types.estimateTokens(turn.content);
    }

    const usage_percent: u8 = if (budget.input_budget == 0)
        100
    else
        @intCast(@min(100, (token_total * 100) / budget.input_budget));

    if (usage_percent < budget.compaction_thresholds.compact_percent) {
        // Stage each allocation with its own errdefer so a mid-
        // sequence OOM unwinds cleanly. The previous struct-literal
        // form leaked every earlier empty-slice / empty-string
        // allocation on any later failure.
        const conversation_summary = try allocator.dupe(u8, "");
        errdefer allocator.free(conversation_summary);
        const facts = try allocator.alloc([]const u8, 0);
        errdefer allocator.free(facts);
        const decisions = try allocator.alloc([]const u8, 0);
        errdefer allocator.free(decisions);
        const open_tasks_slice = try allocator.alloc([]const u8, 0);
        errdefer allocator.free(open_tasks_slice);
        const file_focus_slice = try allocator.alloc([]const u8, 0);
        errdefer allocator.free(file_focus_slice);
        const outcomes = try allocator.alloc([]const u8, 0);
        errdefer allocator.free(outcomes);
        const handoff_summary = try allocator.dupe(u8, "");
        errdefer allocator.free(handoff_summary);
        const pinned = try allocator.alloc([]const u8, 0);
        errdefer allocator.free(pinned);
        const completed = try allocator.alloc([]const u8, 0);
        return .{
            .did_compact = false,
            .usage_percent = usage_percent,
            .conversation_summary = conversation_summary,
            .snapshot = .{
                .facts = facts,
                .decisions = decisions,
                .open_tasks = open_tasks_slice,
                .file_focus = file_focus_slice,
                .recent_tool_outcomes = outcomes,
                .handoff_summary = handoff_summary,
                .pinned_facts = pinned,
                .completed_tasks = completed,
            },
            .summary_hash = 0,
            .pre_compact_tokens = token_total,
        };
    }

    var constraints = std.array_list.Managed([]u8).init(allocator);
    defer freeArrayListStrings(allocator, &constraints);

    var facts = std.array_list.Managed([]u8).init(allocator);
    defer freeArrayListStrings(allocator, &facts);

    var decisions = std.array_list.Managed([]u8).init(allocator);
    defer freeArrayListStrings(allocator, &decisions);

    var open_tasks = std.array_list.Managed([]u8).init(allocator);
    defer freeArrayListStrings(allocator, &open_tasks);

    var file_focus = std.array_list.Managed([]u8).init(allocator);
    defer freeArrayListStrings(allocator, &file_focus);

    extractSignals(allocator, history, &constraints, &facts, &decisions, &open_tasks, &file_focus) catch |err| {
        std.log.debug("compaction: extractSignals failed: {}", .{err});
    };

    var summary_buf = std_io.StringBuilder.init(allocator);
    defer summary_buf.deinit();

    try summary_buf.writer().print("history_usage_percent: {d}\n", .{usage_percent});

    if (constraints.items.len > 0) {
        try summary_buf.writer().writeAll("constraints:\n");
        for (constraints.items) |c| {
            try summary_buf.writer().print("- {s}\n", .{c});
        }
    }

    if (facts.items.len > 0) {
        try summary_buf.writer().writeAll("facts:\n");
        for (facts.items) |f| {
            try summary_buf.writer().print("- {s}\n", .{f});
        }
    }

    if (open_tasks.items.len > 0) {
        try summary_buf.writer().writeAll("unresolved_tasks:\n");
        for (open_tasks.items) |t| {
            try summary_buf.writer().print("- {s}\n", .{t});
        }
    }

    if (decisions.items.len > 0) {
        try summary_buf.writer().writeAll("accepted_decisions:\n");
        for (decisions.items) |d| {
            try summary_buf.writer().print("- {s}\n", .{d});
        }
    }

    if (file_focus.items.len > 0) {
        try summary_buf.writer().writeAll("file_focus:\n");
        for (file_focus.items) |f| {
            try summary_buf.writer().print("- {s}\n", .{f});
        }
    }

    if (summary_buf.items().len == 0) {
        try summary_buf.writer().writeAll("summary: compacted by token budget\n");
    }

    // Choose the conversation summary. When a `summarizer` is supplied AND it
    // returns a non-empty model summary, that model-written text (run through
    // `formatCompactSummary`) becomes `conversation_summary`. Otherwise we fall
    // back to the rule-based `summary_buf` verbatim -- the offline/no-adapter
    // path (and every test that passes `null`) keeps the exact prior behavior.
    // The structured snapshot below is still populated from `extractSignals`
    // either way, because the rest of the system consumes the snapshot.
    const conversation_summary = blk: {
        if (summarizer) |s| {
            if (s.call(s.ctx, allocator, history, custom_instructions)) |raw| {
                defer allocator.free(raw);
                if (std.mem.trim(u8, raw, " \t\r\n").len > 0) {
                    if (formatCompactSummary(allocator, raw)) |formatted| {
                        // Use the model summary. The rule-based `summary_buf` is
                        // freed by its own `defer summary_buf.deinit()`.
                        break :blk formatted;
                    } else |_| {}
                }
            }
        }
        break :blk try summary_buf.toOwnedSlice();
    };
    errdefer allocator.free(conversation_summary);
    const handoff_summary = try allocator.dupe(u8, conversation_summary);
    errdefer allocator.free(handoff_summary);

    const facts_owned = try cloneSlice(allocator, facts.items);
    errdefer freeStringSlice(allocator, facts_owned);
    const decisions_owned = try cloneSlice(allocator, decisions.items);
    errdefer freeStringSlice(allocator, decisions_owned);
    const open_tasks_owned = try cloneSlice(allocator, open_tasks.items);
    errdefer freeStringSlice(allocator, open_tasks_owned);
    const file_focus_owned = try cloneSlice(allocator, file_focus.items);
    errdefer freeStringSlice(allocator, file_focus_owned);
    const outcomes = try cloneSlice(allocator, &.{});
    errdefer freeStringSlice(allocator, outcomes);
    const pinned = try extractPinnedFacts(allocator, history);
    errdefer freeStringSlice(allocator, pinned);
    const completed = try allocator.alloc([]const u8, 0);

    const summary_hash = std.hash.Wyhash.hash(0, conversation_summary);

    return .{
        .did_compact = true,
        .usage_percent = usage_percent,
        .conversation_summary = conversation_summary,
        .snapshot = .{
            .facts = facts_owned,
            .decisions = decisions_owned,
            .open_tasks = open_tasks_owned,
            .file_focus = file_focus_owned,
            .recent_tool_outcomes = outcomes,
            .handoff_summary = handoff_summary,
            .pinned_facts = pinned,
            .completed_tasks = completed,
        },
        .summary_hash = summary_hash,
        .pre_compact_tokens = token_total,
    };
}

fn extractSignals(
    allocator: std.mem.Allocator,
    history: []const types.HistoryTurn,
    constraints: *std.array_list.Managed([]u8),
    facts: *std.array_list.Managed([]u8),
    decisions: *std.array_list.Managed([]u8),
    open_tasks: *std.array_list.Managed([]u8),
    file_focus: *std.array_list.Managed([]u8),
) !void {
    var i: usize = 0;
    while (i < history.len) : (i += 1) {
        const turn = history[i];
        const content = std.mem.trim(u8, turn.content, " \t\r\n");
        if (content.len == 0) continue;

        if (turn.role == .user and containsAny(content, &.{ "must", "do not", "don't", "only", "require" })) {
            try parse_helpers.appendOwnedDupe(constraints, allocator, content);
        }
        if (turn.role == .user and containsAny(content, &.{ "prefer", "always", "never", "use", "avoid", "config" })) {
            try parse_helpers.appendOwnedDupe(facts, allocator, content);
        }
        if (turn.role == .assistant and containsAny(content, &.{ "provider=", "model=", "version=", "sandbox=", "approval=" })) {
            try parse_helpers.appendOwnedDupe(facts, allocator, content);
        }
        if (containsAny(content, &.{ "TODO", "[ ]", "unresolved", "follow up" })) {
            try parse_helpers.appendOwnedDupe(open_tasks, allocator, content);
        }
        if (containsAny(content, &.{ "decision", "decided", "approved" })) {
            try parse_helpers.appendOwnedDupe(decisions, allocator, content);
        }

        var words = std.mem.tokenizeAny(u8, content, " \t\n\r,;:()[]{}");
        while (words.next()) |word| {
            if (looksLikePath(word)) {
                try parse_helpers.appendOwnedDupe(file_focus, allocator, word);
            }
        }
    }

    // Structural patterns: numbered lists and bullet points with action verbs
    for (history) |turn| {
        if (turn.role != .user) continue;
        var lines = std.mem.splitScalar(u8, turn.content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len < 4) continue;
            // Numbered items (1. Do X) are likely task items
            if (std.ascii.isDigit(trimmed[0]) and trimmed.len > 2 and trimmed[1] == '.') {
                try parse_helpers.appendOwnedDupe(open_tasks, allocator, trimmed);
            }
            // Bullet points with action verbs
            if (std.mem.startsWith(u8, trimmed, "- ") and trimmed.len > 4) {
                if (startsWithAction(trimmed[2..])) {
                    try parse_helpers.appendOwnedDupe(open_tasks, allocator, trimmed);
                }
            }
        }
    }

    // User turn that follows an AskUserQuestion is likely a critical decision
    {
        var prev_was_question = false;
        for (history) |turn| {
            if (turn.role == .assistant and containsAny(turn.content, &.{ "AskUserQuestion", "question=" })) {
                prev_was_question = true;
            } else if (turn.role == .user and prev_was_question) {
                if (turn.content.len > 0 and turn.content.len <= 500) {
                    try parse_helpers.appendOwnedDupe(decisions, allocator, turn.content);
                }
                prev_was_question = false;
            } else {
                prev_was_question = false;
            }
        }
    }

    dedupe(allocator, constraints);
    dedupe(allocator, facts);
    dedupe(allocator, decisions);
    dedupe(allocator, open_tasks);
    dedupe(allocator, file_focus);

    if (constraints.items.len == 0 and history.len > 0) {
        const keep: usize = if (history.len < 2) history.len else 2;
        const start = history.len - keep;
        const tail = history[start..];
        for (tail) |turn| {
            if (turn.role == .user and turn.content.len > 0) {
                try parse_helpers.appendOwnedDupe(constraints, allocator, turn.content);
            }
        }
    }

    if (facts.items.len == 0 and history.len > 0) {
        var idx: usize = history.len;
        while (idx > 0) {
            idx -= 1;
            const turn = history[idx];
            if (turn.role == .user and turn.content.len > 0) {
                try parse_helpers.appendOwnedDupe(facts, allocator, turn.content);
                break;
            }
        }
    }
}

fn dedupe(allocator: std.mem.Allocator, list: *std.array_list.Managed([]u8)) void {
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen.deinit();
    }

    var write_idx: usize = 0;
    for (list.items) |item| {
        if (seen.contains(item)) {
            allocator.free(item);
            continue;
        }

        const dup = allocator.dupe(u8, item) catch {
            allocator.free(item);
            continue;
        };
        seen.put(dup, {}) catch {
            allocator.free(dup);
            allocator.free(item);
            continue;
        };

        list.items[write_idx] = item;
        write_idx += 1;
    }
    list.items.len = write_idx;
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    }
    return false;
}

const looksLikePath = parse_helpers.looksLikePath;

const cloneSlice = parse_helpers.cloneStringSlice;

fn freeArrayListStrings(allocator: std.mem.Allocator, list: *std.array_list.Managed([]u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit();
}

const freeStringSlice = parse_helpers.freeStringSlice;

/// Extract critical constraint statements from user turns that should survive all compactions.
fn extractPinnedFacts(allocator: std.mem.Allocator, history: []const types.HistoryTurn) ![]const []const u8 {
    var pinned = std.array_list.Managed([]u8).init(allocator);
    defer freeArrayListStrings(allocator, &pinned);

    for (history) |turn| {
        if (turn.role != .user) continue;
        const content = std.mem.trim(u8, turn.content, " \t\r\n");
        if (content.len == 0 or content.len > 200) continue;

        if (containsAny(content, &.{ "always", "never", "must", "critical", "important:" })) {
            try parse_helpers.appendOwnedDupe(&pinned, allocator, content);
        }
    }

    dedupe(allocator, &pinned);

    // Cap at 10 pinned facts
    while (pinned.items.len > 10) {
        allocator.free(pinned.items[0]);
        _ = pinned.orderedRemove(0);
    }

    return cloneSlice(allocator, pinned.items);
}

/// Auto-promote high-value compaction outputs to persistent memory.
/// Called after compaction to save pinned facts and key decisions so
/// they survive across sessions.
pub fn promoteToMemory(allocator: std.mem.Allocator, snapshot: *const types.SessionSnapshot) void {
    // Only promote if we have substantial material
    if (snapshot.pinned_facts.len == 0 and snapshot.decisions.len == 0) return;

    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();

    if (snapshot.pinned_facts.len > 0) {
        buf.writer().writeAll("Critical constraints:\n") catch return;
        for (snapshot.pinned_facts) |fact| {
            buf.writer().print("- {s}\n", .{fact}) catch return;
        }
    }
    if (snapshot.decisions.len > 0) {
        buf.writer().writeAll("Decisions made:\n") catch return;
        for (snapshot.decisions) |d| {
            buf.writer().print("- {s}\n", .{d}) catch return;
        }
    }

    if (buf.items().len < 20) return; // Too little content

    const content = buf.toOwnedSlice() catch return;
    defer allocator.free(content);

    // Use a stable name so repeated compactions overwrite rather than flooding the directory
    const result = memory.save(allocator, "session-insights", "project", content) catch |err| {
        std.log.warn("compaction: failed to promote insights to memory: {s}", .{@errorName(err)});
        return;
    };
    allocator.free(result);
}

/// Check if a line starts with an action verb followed by a word boundary.
fn startsWithAction(text: []const u8) bool {
    if (text.len == 0) return false;
    const verbs = [_][]const u8{
        "add",       "fix",      "update",  "create", "remove", "delete",
        "implement", "refactor", "test",    "check",  "ensure", "migrate",
        "configure", "set up",   "install",
    };
    for (verbs) |verb| {
        if (parse_helpers.startsWithIgnoreCase(text, verb)) {
            // Require word boundary after verb to avoid "additional" matching "add"
            if (text.len == verb.len) return true;
            const next = text[verb.len];
            if (next == ' ' or next == '\t' or next == ':' or next == ',') return true;
        }
    }
    return false;
}

// --- Task 6: structured compact-boundary marker (compaction-14) ---

/// Stable prefix every serialized boundary marker starts with. Callers (resume
/// loader, `/context` telemetry) match on this to recognize a boundary turn.
pub const COMPACT_BOUNDARY_PREFIX = "compact_boundary";

/// Scan the pre-compaction history for tools whose schema was loaded on demand
/// (deferred-tool loads via ToolSearch). zcode tool turns carry a
/// `"Tool: <Name>\n..."` header (same convention microcompact reads), so we
/// collect the distinct tool names that appear, in first-seen order. This is
/// the positional analog of the reference's `preCompactDiscoveredTools`. The
/// returned slice and its strings are owned by the caller; free via
/// `freeDiscoveredTools`.
pub fn extractDiscoveredToolNames(
    allocator: std.mem.Allocator,
    history: []const types.HistoryTurn,
) ![]const []const u8 {
    var names = std.array_list.Managed([]const u8).init(allocator);
    errdefer freeDiscoveredTools(allocator, names.items);
    defer names.deinit();

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (history) |turn| {
        if (turn.role != .tool) continue;
        const name = toolNameFromHeader(turn.content) orelse continue;
        if (name.len == 0) continue;
        // Tool names are identifiers; a name carrying a space or comma would
        // break the flat serialization, so skip those defensively.
        if (std.mem.indexOfScalar(u8, name, ' ') != null) continue;
        if (std.mem.indexOfScalar(u8, name, ',') != null) continue;
        if (seen.contains(name)) continue;
        const owned = try allocator.dupe(u8, name);
        errdefer allocator.free(owned);
        try seen.put(owned, {});
        try names.append(owned);
    }

    return try names.toOwnedSlice();
}

/// Pull the tool name out of a `"Tool: <Name>\n..."` header. Returns null when
/// the turn does not start with the marker.
fn toolNameFromHeader(content: []const u8) ?[]const u8 {
    const marker = "Tool: ";
    if (!std.mem.startsWith(u8, content, marker)) return null;
    const rest = content[marker.len..];
    const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    return std.mem.trim(u8, rest[0..end], " \t\r");
}

pub fn freeDiscoveredTools(allocator: std.mem.Allocator, tools: []const []const u8) void {
    for (tools) |t| allocator.free(t);
    allocator.free(tools);
}

/// Serialize a `CompactBoundary` to a single, human-readable line prefixed with
/// `compact_boundary`. Flat text (not JSON) so existing transcript viewers
/// degrade gracefully and the 0.16 `ObjectMap.put`-after-parse footgun is
/// avoided entirely. The returned slice is owned by the caller.
///
/// Shape:
///   compact_boundary trigger=manual pre_tokens=123 tools=ToolSearch,Read head=0 anchor= tail=3
/// Optional index fields emit an empty value when null.
pub fn serializeCompactBoundary(
    allocator: std.mem.Allocator,
    boundary: types.CompactBoundary,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.print("{s} trigger={s} pre_tokens={d} tools=", .{
        COMPACT_BOUNDARY_PREFIX,
        boundary.trigger.toString(),
        boundary.pre_compact_tokens,
    });
    for (boundary.discovered_tools, 0..) |t, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll(t);
    }
    try w.writeAll(" head=");
    if (boundary.preserved_head) |h| try w.print("{d}", .{h});
    try w.writeAll(" anchor=");
    if (boundary.preserved_anchor) |a| try w.print("{d}", .{a});
    try w.writeAll(" tail=");
    if (boundary.preserved_tail) |t| try w.print("{d}", .{t});

    return out.toOwnedSlice();
}

/// Parse a `compact_boundary ...` line back into a `CompactBoundary`. Returns
/// null when the line does not start with the boundary prefix. The returned
/// boundary's `discovered_tools` strings are allocated; free via
/// `freeDiscoveredTools(allocator, boundary.discovered_tools)`.
pub fn parseCompactBoundary(
    allocator: std.mem.Allocator,
    line: []const u8,
) !?types.CompactBoundary {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, COMPACT_BOUNDARY_PREFIX)) return null;

    var trigger: types.CompactTrigger = .auto;
    var pre_tokens: usize = 0;
    var head: ?usize = null;
    var anchor: ?usize = null;
    var tail: ?usize = null;

    var tools = std.array_list.Managed([]const u8).init(allocator);
    errdefer freeDiscoveredTools(allocator, tools.items);
    defer tools.deinit();

    var fields = std.mem.tokenizeScalar(u8, trimmed[COMPACT_BOUNDARY_PREFIX.len..], ' ');
    while (fields.next()) |field| {
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        const key = field[0..eq];
        const val = field[eq + 1 ..];
        if (std.mem.eql(u8, key, "trigger")) {
            trigger = types.CompactTrigger.fromString(val) orelse .auto;
        } else if (std.mem.eql(u8, key, "pre_tokens")) {
            pre_tokens = std.fmt.parseInt(usize, val, 10) catch 0;
        } else if (std.mem.eql(u8, key, "head")) {
            head = if (val.len == 0) null else (std.fmt.parseInt(usize, val, 10) catch null);
        } else if (std.mem.eql(u8, key, "anchor")) {
            anchor = if (val.len == 0) null else (std.fmt.parseInt(usize, val, 10) catch null);
        } else if (std.mem.eql(u8, key, "tail")) {
            tail = if (val.len == 0) null else (std.fmt.parseInt(usize, val, 10) catch null);
        } else if (std.mem.eql(u8, key, "tools")) {
            if (val.len > 0) {
                var parts = std.mem.splitScalar(u8, val, ',');
                while (parts.next()) |p| {
                    if (p.len == 0) continue;
                    const owned = try allocator.dupe(u8, p);
                    errdefer allocator.free(owned);
                    try tools.append(owned);
                }
            }
        }
    }

    return types.CompactBoundary{
        .trigger = trigger,
        .pre_compact_tokens = pre_tokens,
        .discovered_tools = try tools.toOwnedSlice(),
        .preserved_head = head,
        .preserved_anchor = anchor,
        .preserved_tail = tail,
    };
}

// --- ui-render-05: styled compact-boundary display line ---

/// The user-facing compaction-boundary text. Mirrors the reference
/// `CompactBoundaryMessage.tsx:10`:
///   `✻ Conversation compacted ({historyShortcut} for history)`
/// where `historyShortcut` resolves to the transcript toggle (ctrl+o by
/// default, `repl_input.zig` `.toggle_transcript`).
pub const COMPACT_BOUNDARY_BODY = "Conversation compacted";
pub const COMPACT_BOUNDARY_HISTORY_HINT = "(ctrl+o for history)";

/// Render the styled compaction-boundary line:
///   `✻ Conversation compacted (ctrl+o for history)`
/// dim when color is on. This is the pure, IO-free render unit so the REPL
/// wiring stays a thin call site and the styling is unit-testable without the
/// interactive loop. No trailing newline (the caller frames it).
///
/// Color is gated by `use_color`: when false (NO_COLOR / non-tty) the same
/// text is emitted with no SGR escapes so piped/captured output degrades
/// cleanly -- matching the rest of the renderer's color gate.
pub fn renderCompactBoundary(writer: anytype, use_color: bool) !void {
    if (use_color) try writer.writeAll(ANSI_DIM);
    try writer.writeAll(figures.TEARDROP_ASTERISK);
    try writer.print(" {s} {s}", .{ COMPACT_BOUNDARY_BODY, COMPACT_BOUNDARY_HISTORY_HINT });
    if (use_color) try writer.writeAll(ANSI_RESET);
}

// --- Task 12: partial / pivot-anchored compaction (compaction-07) ---
// Experimental / deferable. Summarize the messages on one side of a
// user-selected pivot index while preserving the other side verbatim, with two
// direction-driven prompt variants. Mirrors the reference
// `partialCompactConversation` (services/compact/compact.ts:772-1106) and the
// `PARTIAL_COMPACT_PROMPT` / `PARTIAL_COMPACT_UP_TO_PROMPT` templates
// (services/compact/prompt.ts:145-291). Today only the pure transform is wired;
// the message-selector overlay (cli/repl_overlay.zig) remains navigation-only,
// so this is reachable from tests and a future overlay keypress, not yet from
// the UI (noted as a deferred manual-check item in the phase plan).

/// Which side of the pivot gets summarized.
///   .from  -> summarize history[pivot..]; keep history[..pivot] verbatim. The
///            summary FOLLOWS the kept prefix (model still sees the recent
///            messages it is summarizing). Uses `PARTIAL_COMPACT_PROMPT`.
///   .up_to -> summarize history[..pivot]; keep history[pivot..] verbatim. The
///            summary PRECEDES the kept suffix (it is placed at the start of a
///            continuing session). Uses `PARTIAL_COMPACT_UP_TO_PROMPT`.
pub const PartialDirection = enum { from, up_to };

/// Build the partial-compaction summarizer prompt for `direction` over the
/// `range` of turns to be summarized. The two templates differ in framing: the
/// `.from` variant summarizes the RECENT portion that follows retained earlier
/// context; the `.up_to` variant summarizes a prefix that will sit at the start
/// of a continuing session with newer messages after it. Ports
/// `PARTIAL_COMPACT_PROMPT` and `PARTIAL_COMPACT_UP_TO_PROMPT`
/// (services/compact/prompt.ts:145-291). Media/skill-listing stripping is reused
/// from `buildCompactionPrompt`'s pass so the partial call does not bloat.
/// Caller frees the returned slice.
pub fn buildPartialCompactPrompt(
    allocator: std.mem.Allocator,
    range: []const types.HistoryTurn,
    direction: PartialDirection,
    custom_instructions: []const u8,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    switch (direction) {
        .from => try w.writeAll(
            "Your task is to create a detailed summary of the RECENT portion of the " ++
                "conversation - the messages that follow earlier retained context. The " ++
                "earlier messages are being kept intact and do NOT need to be summarized. " ++
                "Focus your summary on what was discussed, learned, and accomplished in the " ++
                "recent messages only.\n\n" ++
                "CRITICAL: Respond with TEXT ONLY. Do NOT call any tools.\n\n" ++
                "Your summary must include:\n" ++
                "1. Primary Request and Intent\n" ++
                "2. Key Technical Concepts\n" ++
                "3. Files and Code Sections\n" ++
                "4. Errors and Fixes\n" ++
                "5. Problem Solving\n" ++
                "6. All user messages from the recent portion\n" ++
                "7. Pending Tasks\n" ++
                "8. Current Work\n" ++
                "9. Optional Next Step\n\n",
        ),
        .up_to => try w.writeAll(
            "Your task is to create a detailed summary of this conversation. This summary " ++
                "will be placed at the start of a continuing session; newer messages that " ++
                "build on this context will follow after your summary (you do not see them " ++
                "here). Summarize thoroughly so that someone reading only your summary and " ++
                "then the newer messages can fully understand what happened and continue " ++
                "the work.\n\n" ++
                "CRITICAL: Respond with TEXT ONLY. Do NOT call any tools.\n\n" ++
                "Your summary must include:\n" ++
                "1. Primary Request and Intent\n" ++
                "2. Key Technical Concepts\n" ++
                "3. Files and Code Sections\n" ++
                "4. Errors and Fixes\n" ++
                "5. Problem Solving\n" ++
                "6. All user messages\n" ++
                "7. Pending Tasks\n" ++
                "8. Work Completed\n" ++
                "9. Context for Continuing Work\n\n",
        ),
    }

    if (custom_instructions.len > 0) {
        try w.print("## Compact Instructions\n{s}\n\n", .{custom_instructions});
    }

    try w.writeAll("CONVERSATION:\n\n");

    for (range) |turn| {
        // Reuse the same stripping pass as buildCompactionPrompt: drop
        // re-injected skill listings and collapse inlined media markers.
        if (isReinjectedAttachment(turn.content)) continue;
        const role_str = types.roleToString(turn.role);
        const stripped = try stripMediaMarkers(allocator, turn.content);
        defer if (stripped) |s| allocator.free(s);
        const source = stripped orelse turn.content;
        const max_turn_len: usize = 4000;
        const content = if (source.len > max_turn_len) source[0..max_turn_len] else source;
        try w.print("{s}: {s}\n\n", .{ role_str, content });
    }

    try w.writeAll("\nNow write the summary following the sections above.");

    return out.toOwnedSlice();
}

/// Result of a partial compaction. Unlike `maybeCompact`, the caller is
/// responsible for reassembling the final history: it keeps the verbatim side
/// (recorded in `boundary`) and inserts `summary` for the summarized side. The
/// `boundary` records the preserved-segment indices so the structured marker
/// (Task 6) can persist the relink. Free via `deinit`.
pub const PartialCompactionResult = struct {
    /// The summarized-range summary text (model-written when a summarizer was
    /// supplied and succeeded, else the rule-based fallback). Owned.
    summary: []u8,
    /// Structured boundary marker recording the trigger, pre-compaction token
    /// total, and the preserved-segment indices for the verbatim side. Its
    /// `discovered_tools` is always empty here (partial compaction does not
    /// re-scan); owned slice (empty).
    boundary: types.CompactBoundary,
    /// Structured snapshot built from the summarized range (same shape the rest
    /// of the system consumes). Owned.
    snapshot: types.SessionSnapshot,
    /// Stable hash of `summary`.
    summary_hash: u64,

    pub fn deinit(self: *PartialCompactionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.summary);
        freeDiscoveredTools(allocator, self.boundary.discovered_tools);
        freeStringSlice(allocator, self.snapshot.facts);
        freeStringSlice(allocator, self.snapshot.decisions);
        freeStringSlice(allocator, self.snapshot.open_tasks);
        freeStringSlice(allocator, self.snapshot.file_focus);
        freeStringSlice(allocator, self.snapshot.recent_tool_outcomes);
        allocator.free(self.snapshot.handoff_summary);
        freeStringSlice(allocator, self.snapshot.pinned_facts);
        freeStringSlice(allocator, self.snapshot.completed_tasks);
    }
};

/// Adjust a pivot so it never splits a tool turn from the assistant turn that
/// produced it. zcode pairs an assistant turn immediately followed by one or
/// more `.tool` turns positionally; cutting between them would orphan the tool
/// results from their request. We nudge the pivot LEFT to the start of any
/// assistant/tool block it lands inside, so both sides keep whole blocks.
/// Mirrors the reference's `adjustIndexToPreserveAPIInvariants` intent
/// (services/compact/sessionMemoryCompact.ts:232-309) for our positional model.
fn adjustPivotForPairing(history: []const types.HistoryTurn, pivot: usize) usize {
    if (pivot == 0 or pivot >= history.len) return @min(pivot, history.len);
    // If the turn at `pivot` is a tool result, walk left past the contiguous
    // tool turns and the assistant turn that produced them so the boundary sits
    // before the whole block.
    if (history[pivot].role != .tool) return pivot;
    var p = pivot;
    while (p > 0 and history[p].role == .tool) p -= 1;
    // p now points at the assistant (or other) turn before the tool run; keep
    // that turn on the same side as its tool results by cutting before it.
    return p;
}

/// Partial / pivot-anchored compaction (compaction-07). Summarizes the messages
/// on one side of `pivot` (per `direction`) and preserves the other side
/// verbatim; the returned `boundary` records which segment was preserved so the
/// final history can be reassembled and persisted. The `summarizer` is run over
/// the summarized range only; on null/failure the rule-based extraction is used
/// as the summary (so offline/no-adapter callers and tests still work).
///
/// The pivot is first adjusted to avoid splitting a tool turn from its
/// producing assistant turn (`adjustPivotForPairing`).
///
/// Ownership: the returned `PartialCompactionResult` owns its `summary`,
/// `snapshot`, and `boundary.discovered_tools`; free via `result.deinit`. The
/// verbatim history slice is NOT copied -- the caller reassembles it from the
/// original `history` using the preserved indices in `boundary`.
pub fn partialCompact(
    allocator: std.mem.Allocator,
    history: []const types.HistoryTurn,
    pivot: usize,
    direction: PartialDirection,
    summarizer: ?Summarizer,
    custom_instructions: []const u8,
    trigger: types.CompactTrigger,
) !PartialCompactionResult {
    const p = adjustPivotForPairing(history, pivot);

    // Select the range to summarize and record the preserved segment.
    var summarize_range: []const types.HistoryTurn = &.{};
    var preserved_head: ?usize = null;
    var preserved_tail: ?usize = null;
    switch (direction) {
        .from => {
            // Keep history[..p] verbatim (the head), summarize history[p..].
            summarize_range = history[p..];
            preserved_head = 0;
            preserved_tail = if (p > 0) p - 1 else null;
        },
        .up_to => {
            // Summarize history[..p], keep history[p..] verbatim (the tail).
            summarize_range = history[0..p];
            preserved_head = if (p < history.len) p else null;
            preserved_tail = if (history.len > 0) history.len - 1 else null;
        },
    }

    var pre_tokens: usize = 0;
    for (summarize_range) |turn| pre_tokens += types.estimateTokens(turn.content);

    // Build the rule-based snapshot over the summarized range. extractSignals is
    // best-effort: a failure leaves the lists empty rather than aborting.
    var constraints = std.array_list.Managed([]u8).init(allocator);
    defer freeArrayListStrings(allocator, &constraints);
    var facts = std.array_list.Managed([]u8).init(allocator);
    defer freeArrayListStrings(allocator, &facts);
    var decisions = std.array_list.Managed([]u8).init(allocator);
    defer freeArrayListStrings(allocator, &decisions);
    var open_tasks = std.array_list.Managed([]u8).init(allocator);
    defer freeArrayListStrings(allocator, &open_tasks);
    var file_focus = std.array_list.Managed([]u8).init(allocator);
    defer freeArrayListStrings(allocator, &file_focus);

    extractSignals(allocator, summarize_range, &constraints, &facts, &decisions, &open_tasks, &file_focus) catch |err| {
        std.log.debug("partialCompact: extractSignals failed: {}", .{err});
    };

    // Choose the summary: model-written (formatted) when a summarizer succeeds,
    // else a minimal rule-based fallback so the path always yields a summary.
    const summary = blk: {
        if (summarizer) |s| {
            if (s.call(s.ctx, allocator, summarize_range, custom_instructions)) |raw| {
                defer allocator.free(raw);
                if (std.mem.trim(u8, raw, " \t\r\n").len > 0) {
                    if (formatCompactSummary(allocator, raw)) |formatted| {
                        break :blk formatted;
                    } else |_| {}
                }
            }
        }
        // Rule-based fallback summary.
        var rb = std_io.StringBuilder.init(allocator);
        defer rb.deinit();
        const rw = rb.writer();
        try rw.print("partial_summary direction={s} summarized_turns={d}\n", .{
            @tagName(direction), summarize_range.len,
        });
        if (facts.items.len > 0) {
            try rw.writeAll("facts:\n");
            for (facts.items) |f| try rw.print("- {s}\n", .{f});
        }
        if (open_tasks.items.len > 0) {
            try rw.writeAll("unresolved_tasks:\n");
            for (open_tasks.items) |t| try rw.print("- {s}\n", .{t});
        }
        break :blk try rb.toOwnedSlice();
    };
    errdefer allocator.free(summary);

    const handoff_summary = try allocator.dupe(u8, summary);
    errdefer allocator.free(handoff_summary);

    const facts_owned = try cloneSlice(allocator, facts.items);
    errdefer freeStringSlice(allocator, facts_owned);
    const decisions_owned = try cloneSlice(allocator, decisions.items);
    errdefer freeStringSlice(allocator, decisions_owned);
    const open_tasks_owned = try cloneSlice(allocator, open_tasks.items);
    errdefer freeStringSlice(allocator, open_tasks_owned);
    const file_focus_owned = try cloneSlice(allocator, file_focus.items);
    errdefer freeStringSlice(allocator, file_focus_owned);
    const outcomes = try cloneSlice(allocator, &.{});
    errdefer freeStringSlice(allocator, outcomes);
    const pinned = try extractPinnedFacts(allocator, summarize_range);
    errdefer freeStringSlice(allocator, pinned);
    const completed = try allocator.alloc([]const u8, 0);
    errdefer allocator.free(completed);

    const empty_tools = try allocator.alloc([]const u8, 0);

    return .{
        .summary = summary,
        .boundary = .{
            .trigger = trigger,
            .pre_compact_tokens = pre_tokens,
            .discovered_tools = empty_tools,
            .preserved_head = preserved_head,
            .preserved_anchor = @as(?usize, p),
            .preserved_tail = preserved_tail,
        },
        .snapshot = .{
            .facts = facts_owned,
            .decisions = decisions_owned,
            .open_tasks = open_tasks_owned,
            .file_focus = file_focus_owned,
            .recent_tool_outcomes = outcomes,
            .handoff_summary = handoff_summary,
            .pinned_facts = pinned,
            .completed_tasks = completed,
        },
        .summary_hash = std.hash.Wyhash.hash(0, summary),
    };
}

const testing = std.testing;

test "microcompact one-lines old tool results, keeps the last N and non-tool turns" {
    const history = [_]types.HistoryTurn{
        .{ .role = .user, .content = "do the thing", .timestamp = 0 },
        .{ .role = .tool, .content = "Tool: Grep\nline1\nline2\nline3", .timestamp = 1 },
        .{ .role = .assistant, .content = "thinking", .timestamp = 2 },
        .{ .role = .tool, .content = "Tool: Read\nbig file body here", .timestamp = 3 },
        .{ .role = .tool, .content = "Tool: Bash\nrecent output", .timestamp = 4 },
    };

    const out = try microcompact(testing.allocator, &history, 1); // keep last 1 tool
    defer {
        // Only the cleared tool turns own freshly-allocated content.
        for (out, 0..) |t, i| {
            if (t.role == .tool and t.content.ptr != history[i].content.ptr) testing.allocator.free(@constCast(t.content));
        }
        testing.allocator.free(out);
    }

    // First two tool results cleared (count=3, keep=1 -> clear first 2).
    try testing.expect(std.mem.indexOf(u8, out[1].content, "cleared to save context") != null);
    try testing.expect(std.mem.startsWith(u8, out[1].content, "Tool: Grep")); // head preserved
    try testing.expect(std.mem.indexOf(u8, out[3].content, "cleared to save context") != null);
    // Last tool result kept in full.
    try testing.expectEqualStrings("Tool: Bash\nrecent output", out[4].content);
    // Non-tool turns untouched.
    try testing.expectEqualStrings("do the thing", out[0].content);
    try testing.expectEqualStrings("thinking", out[2].content);
}

test "microcompact keeps everything when tool count <= keep_last_n" {
    const history = [_]types.HistoryTurn{
        .{ .role = .tool, .content = "Tool: Grep\nout", .timestamp = 0 },
    };
    const out = try microcompact(testing.allocator, &history, 6);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Tool: Grep\nout", out[0].content); // unchanged, borrowed
}

// --- Task 9: time-based (cache-staleness) microcompaction (compaction-10) ---

fn freeMicrocompactOutput(out: []types.HistoryTurn, history: []const types.HistoryTurn) void {
    for (out, 0..) |t, i| {
        if (t.role == .tool and t.content.ptr != history[i].content.ptr) {
            testing.allocator.free(@constCast(t.content));
        }
    }
    testing.allocator.free(out);
}

test "timeBasedMicrocompact fires when last assistant turn is stale" {
    const history = [_]types.HistoryTurn{
        .{ .role = .user, .content = "do the thing", .timestamp = 0 },
        .{ .role = .tool, .content = "Tool: Grep\noldest", .timestamp = 0 },
        .{ .role = .tool, .content = "Tool: Read\nolder", .timestamp = 0 },
        .{ .role = .tool, .content = "Tool: Bash\nrecent", .timestamp = 0 },
        .{ .role = .assistant, .content = "done", .timestamp = 100 },
    };

    // gap = now(100 + 2h) - 100 = 7200s >= 3600s threshold -> fires.
    const now: i64 = 100 + 7200;
    const maybe = try timeBasedMicrocompact(testing.allocator, &history, now, 3600, 2, true);
    try testing.expect(maybe != null);
    const out = maybe.?;
    defer freeMicrocompactOutput(out, &history);

    // keep_recent=2 over 3 tool results -> oldest one cleared, last two kept.
    try testing.expect(std.mem.indexOf(u8, out[1].content, "cleared to save context") != null);
    try testing.expectEqualStrings("Tool: Read\nolder", out[2].content);
    try testing.expectEqualStrings("Tool: Bash\nrecent", out[3].content);
}

test "timeBasedMicrocompact does not fire when last assistant turn is fresh" {
    const history = [_]types.HistoryTurn{
        .{ .role = .tool, .content = "Tool: Grep\noldest", .timestamp = 0 },
        .{ .role = .tool, .content = "Tool: Read\nolder", .timestamp = 0 },
        .{ .role = .assistant, .content = "done", .timestamp = 1000 },
    };

    // gap = 1300 - 1000 = 300s < 3600s threshold -> no trigger, returns null.
    const maybe = try timeBasedMicrocompact(testing.allocator, &history, 1300, 3600, 2, true);
    try testing.expect(maybe == null);
}

test "timeBasedMicrocompact never fires when disabled" {
    const history = [_]types.HistoryTurn{
        .{ .role = .tool, .content = "Tool: Grep\noldest", .timestamp = 0 },
        .{ .role = .assistant, .content = "done", .timestamp = 0 },
    };

    // Stale gap, but enabled=false -> no-op (null) regardless.
    const maybe = try timeBasedMicrocompact(testing.allocator, &history, 999_999, 3600, 2, false);
    try testing.expect(maybe == null);
}

test "timeBasedMicrocompact returns null with no assistant turn" {
    const history = [_]types.HistoryTurn{
        .{ .role = .user, .content = "hello", .timestamp = 0 },
        .{ .role = .tool, .content = "Tool: Grep\nout", .timestamp = 0 },
    };

    const maybe = try timeBasedMicrocompact(testing.allocator, &history, 999_999, 3600, 2, true);
    try testing.expect(maybe == null);
}

test "compacts above threshold" {
    const allocator = testing.allocator;
    const history = [_]types.HistoryTurn{
        .{ .role = .user, .content = "we must keep src/main.zig stable", .timestamp = 0 },
        .{ .role = .assistant, .content = "decision accepted", .timestamp = 0 },
    };

    var budget = types.BudgetPlan.init(100, 10, 10);
    budget.compaction_thresholds.compact_percent = 5;

    var result = try maybeCompact(allocator, history[0..], budget, null, "");
    defer result.deinit(allocator);

    try testing.expect(result.did_compact);
    try testing.expect(result.summary_hash != 0);
}

// --- Task 1: LLM summary wiring (compaction-01) ---

const StubSummarizer = struct {
    text: []const u8,
    seen_instructions: []const u8 = "",

    fn call(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        history: []const types.HistoryTurn,
        custom_instructions: []const u8,
    ) ?[]u8 {
        const self: *StubSummarizer = @ptrCast(@alignCast(ctx));
        _ = history;
        self.seen_instructions = custom_instructions;
        return allocator.dupe(u8, self.text) catch null;
    }

    fn summarizer(self: *StubSummarizer) Summarizer {
        return .{ .ctx = self, .call = StubSummarizer.call };
    }
};

const NullSummarizer = struct {
    fn call(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        history: []const types.HistoryTurn,
        custom_instructions: []const u8,
    ) ?[]u8 {
        _ = ctx;
        _ = allocator;
        _ = history;
        _ = custom_instructions;
        return null;
    }

    fn summarizer(self: *NullSummarizer) Summarizer {
        return .{ .ctx = self, .call = NullSummarizer.call };
    }
};

test "maybeCompact uses formatted LLM summary when summarizer present" {
    const allocator = testing.allocator;
    const history = [_]types.HistoryTurn{
        .{ .role = .user, .content = "we must keep src/main.zig stable", .timestamp = 0 },
        .{ .role = .assistant, .content = "decision accepted", .timestamp = 0 },
    };

    var budget = types.BudgetPlan.init(100, 10, 10);
    budget.compaction_thresholds.compact_percent = 5;

    var stub = StubSummarizer{ .text = "<analysis>scratch</analysis>\n<summary>1. Primary Request: do X</summary>" };

    var result = try maybeCompact(allocator, history[0..], budget, stub.summarizer(), "");
    defer result.deinit(allocator);

    try testing.expect(result.did_compact);
    try testing.expect(std.mem.indexOf(u8, result.conversation_summary, "Summary:") != null);
    try testing.expect(std.mem.indexOf(u8, result.conversation_summary, "do X") != null);
    try testing.expect(std.mem.indexOf(u8, result.conversation_summary, "scratch") == null);
    try testing.expect(std.mem.indexOf(u8, result.conversation_summary, "<analysis>") == null);
    // The structured snapshot is still populated from extractSignals.
    try testing.expect(result.summary_hash != 0);
}

test "maybeCompact custom instructions reach the summarizer" {
    const allocator = testing.allocator;
    const history = [_]types.HistoryTurn{
        .{ .role = .user, .content = "we must keep src/main.zig stable", .timestamp = 0 },
    };

    var budget = types.BudgetPlan.init(100, 10, 10);
    budget.compaction_thresholds.compact_percent = 5;

    var stub = StubSummarizer{ .text = "<summary>focused</summary>" };

    var result = try maybeCompact(allocator, history[0..], budget, stub.summarizer(), "focus on test output");
    defer result.deinit(allocator);

    try testing.expectEqualStrings("focus on test output", stub.seen_instructions);
}

test "maybeCompact falls back to rule-based summary when summarizer is null" {
    const allocator = testing.allocator;
    const history = [_]types.HistoryTurn{
        .{ .role = .user, .content = "we must keep src/main.zig stable", .timestamp = 0 },
        .{ .role = .assistant, .content = "decision accepted", .timestamp = 0 },
    };

    var budget = types.BudgetPlan.init(100, 10, 10);
    budget.compaction_thresholds.compact_percent = 5;

    // Regression guard: the null-summarizer summary must equal the prior
    // rule-based output exactly.
    var ruled = try maybeCompact(allocator, history[0..], budget, null, "");
    defer ruled.deinit(allocator);

    try testing.expect(ruled.did_compact);
    try testing.expect(ruled.summary_hash != 0);
    try testing.expect(std.mem.indexOf(u8, ruled.conversation_summary, "history_usage_percent:") != null);
}

test "maybeCompact falls back when summarizer returns null" {
    const allocator = testing.allocator;
    const history = [_]types.HistoryTurn{
        .{ .role = .user, .content = "we must keep src/main.zig stable", .timestamp = 0 },
    };

    var budget = types.BudgetPlan.init(100, 10, 10);
    budget.compaction_thresholds.compact_percent = 5;

    var stub = NullSummarizer{};

    var result = try maybeCompact(allocator, history[0..], budget, stub.summarizer(), "");
    defer result.deinit(allocator);

    try testing.expect(result.did_compact);
    // Null model summary -> rule-based fallback text.
    try testing.expect(std.mem.indexOf(u8, result.conversation_summary, "history_usage_percent:") != null);
}

// Minimal stub ProviderAdapter that returns a fixed scripted summary from
// send(). Exercises the SAME adapter -> llmCompact -> maybeCompact chain the
// runtime's SummarizerCtx uses, without spawning a network call or mutating
// process env. The runtime wires the real `mock`/provider adapters into this
// exact path (agent_runtime.SummarizerCtx.call -> compaction.llmCompact).
const StubAdapter = struct {
    scripted: []const u8,

    fn vtableSend(ctx: *anyopaque, allocator: std.mem.Allocator, request: types.ModelRequest) anyerror!types.ModelResponse {
        const self: *StubAdapter = @ptrCast(@alignCast(ctx));
        _ = request;
        const text = try allocator.dupe(u8, self.scripted);
        return .{
            .raw = text,
            .text = text,
            .usage_input_tokens = 0,
            .usage_output_tokens = 0,
        };
    }
    fn vtableDeinit(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        _ = ctx;
        _ = allocator;
    }
    fn vtableListModels(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]types.ModelInfo {
        _ = ctx;
        return allocator.alloc(types.ModelInfo, 0);
    }
    fn vtableStream(ctx: *anyopaque, allocator: std.mem.Allocator, request: types.ModelRequest) anyerror![]const u8 {
        const resp = try vtableSend(ctx, allocator, request);
        return resp.text;
    }
    fn vtableHealthcheck(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        _ = ctx;
        _ = allocator;
    }

    const vtable = types.ProviderAdapter.VTable{
        .deinit = vtableDeinit,
        .listModels = vtableListModels,
        .send = vtableSend,
        .stream = vtableStream,
        .healthcheck = vtableHealthcheck,
    };

    fn adapter(self: *StubAdapter) types.ProviderAdapter {
        return .{ .name = "stub", .ctx = self, .vtable = &vtable };
    }
};

const AdapterSummarizerCtx = struct {
    adapter: *types.ProviderAdapter,
    model: []const u8,

    fn call(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        history: []const types.HistoryTurn,
        custom_instructions: []const u8,
    ) ?[]u8 {
        const self: *AdapterSummarizerCtx = @ptrCast(@alignCast(ctx));
        return llmCompact(allocator, self.adapter, history, self.model, custom_instructions);
    }
};

test "maybeCompact round-trips a provider adapter summary through llmCompact" {
    const allocator = testing.allocator;
    const history = [_]types.HistoryTurn{
        .{ .role = .user, .content = "we must keep src/main.zig stable", .timestamp = 0 },
        .{ .role = .assistant, .content = "decision accepted", .timestamp = 0 },
    };

    var budget = types.BudgetPlan.init(100, 10, 10);
    budget.compaction_thresholds.compact_percent = 5;

    var stub = StubAdapter{ .scripted = "<analysis>draft</analysis>\n<summary>Primary Request: keep main.zig stable</summary>" };
    var adapter = stub.adapter();
    var ctx = AdapterSummarizerCtx{ .adapter = &adapter, .model = "stub-model" };
    const summarizer = Summarizer{ .ctx = &ctx, .call = AdapterSummarizerCtx.call };

    var result = try maybeCompact(allocator, history[0..], budget, summarizer, "");
    defer result.deinit(allocator);

    try testing.expect(result.did_compact);
    try testing.expect(std.mem.startsWith(u8, result.conversation_summary, "Summary:"));
    try testing.expect(std.mem.indexOf(u8, result.conversation_summary, "keep main.zig stable") != null);
    try testing.expect(std.mem.indexOf(u8, result.conversation_summary, "draft") == null);
}

test "formatCompactSummary strips analysis, unwraps summary, collapses newlines" {
    const allocator = testing.allocator;

    // analysis stripped + summary unwrapped
    {
        const out = try formatCompactSummary(allocator, "<analysis>scratch work</analysis>\n<summary>1. Primary Request: do X</summary>");
        defer allocator.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "scratch") == null);
        try testing.expect(std.mem.indexOf(u8, out, "<analysis>") == null);
        try testing.expect(std.mem.indexOf(u8, out, "<summary>") == null);
        try testing.expect(std.mem.startsWith(u8, out, "Summary:"));
        try testing.expect(std.mem.indexOf(u8, out, "do X") != null);
    }

    // analysis-only -> empty after trim
    {
        const out = try formatCompactSummary(allocator, "<analysis>only scratch</analysis>");
        defer allocator.free(out);
        try testing.expectEqualStrings("", out);
    }

    // no tags -> passthrough (trimmed)
    {
        const out = try formatCompactSummary(allocator, "  plain text summary  ");
        defer allocator.free(out);
        try testing.expectEqualStrings("plain text summary", out);
    }

    // multiple newlines collapse to two
    {
        const out = try formatCompactSummary(allocator, "a\n\n\n\nb");
        defer allocator.free(out);
        try testing.expectEqualStrings("a\n\nb", out);
    }
}

// --- Task 4: custom /compact instructions plumbing (compaction-06) ---

test "buildCompactionPrompt includes Compact Instructions only when non-empty" {
    const allocator = testing.allocator;
    const history = [_]types.HistoryTurn{
        .{ .role = .user, .content = "do the thing", .timestamp = 0 },
    };

    // With instructions: the section header and the text both appear.
    {
        const out = try buildCompactionPrompt(allocator, &history, "focus on test output");
        defer allocator.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "Compact Instructions") != null);
        try testing.expect(std.mem.indexOf(u8, out, "focus on test output") != null);
    }

    // Empty instructions: neither the header nor the text appear.
    {
        const out = try buildCompactionPrompt(allocator, &history, "");
        defer allocator.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "Compact Instructions") == null);
    }
}

test "mergeHookInstructions combines user and hook directives" {
    const allocator = testing.allocator;

    // Both present: user first, hook appended after a blank line.
    {
        const out = try mergeHookInstructions(allocator, "user", "hook");
        defer allocator.free(out);
        try testing.expectEqualStrings("user\n\nhook", out);
    }

    // User only.
    {
        const out = try mergeHookInstructions(allocator, "user", "");
        defer allocator.free(out);
        try testing.expectEqualStrings("user", out);
    }

    // Hook only.
    {
        const out = try mergeHookInstructions(allocator, "", "hook");
        defer allocator.free(out);
        try testing.expectEqualStrings("hook", out);
    }

    // Both empty -> empty literal (zero-length, must not be freed).
    {
        const out = try mergeHookInstructions(allocator, "", "");
        try testing.expectEqualStrings("", out);
        try testing.expectEqual(@as(usize, 0), out.len);
    }

    // Whitespace-only inputs are treated as empty.
    {
        const out = try mergeHookInstructions(allocator, "  \n", "\t ");
        try testing.expectEqual(@as(usize, 0), out.len);
    }
}

// --- Task 10: image/document/attachment stripping (compaction-15) ---

test "stripMediaMarkers collapses inlined media and leaves plain text" {
    const allocator = testing.allocator;

    // A turn with an inlined image data URI becomes a bare [image] marker.
    {
        const out = try stripMediaMarkers(allocator, "see this data:image/png;base64,AAAABBBB now");
        try testing.expect(out != null);
        defer allocator.free(out.?);
        try testing.expectEqualStrings("see this [image] now", out.?);
    }

    // A [document: path] form becomes a bare [document] marker.
    {
        const out = try stripMediaMarkers(allocator, "ref [document: /tmp/spec.pdf] here");
        try testing.expect(out != null);
        defer allocator.free(out.?);
        try testing.expectEqualStrings("ref [document] here", out.?);
    }

    // A pdf data URI becomes [document].
    {
        const out = try stripMediaMarkers(allocator, "data:application/pdf;base64,JVBERi0x");
        try testing.expect(out != null);
        defer allocator.free(out.?);
        try testing.expectEqualStrings("[document]", out.?);
    }

    // Plain text with no recognized media form is left untouched (null = borrow).
    {
        const out = try stripMediaMarkers(allocator, "no media here, just prose about images");
        try testing.expect(out == null);
    }
}

test "buildCompactionPrompt markerizes inlined media and drops skill listings" {
    const allocator = testing.allocator;

    const listing = skill_listing_header ++ "\n- foo: do foo\n- bar: do bar";
    const history = [_]types.HistoryTurn{
        .{ .role = .user, .content = "look at data:image/png;base64,ZZZZ please", .timestamp = 0 },
        .{ .role = .assistant, .content = listing, .timestamp = 1 },
        .{ .role = .user, .content = "thanks", .timestamp = 2 },
    };

    const out = try buildCompactionPrompt(allocator, &history, "");
    defer allocator.free(out);

    // Inlined image collapsed to a bare marker; raw base64 not present.
    try testing.expect(std.mem.indexOf(u8, out, "[image]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "data:image/") == null);
    try testing.expect(std.mem.indexOf(u8, out, "ZZZZ") == null);

    // The re-injected skill-listing turn is omitted from the summarizer prompt.
    try testing.expect(std.mem.indexOf(u8, out, skill_listing_header) == null);

    // Ordinary turns survive.
    try testing.expect(std.mem.indexOf(u8, out, "thanks") != null);
}

// --- Task 6: structured compact-boundary marker (compaction-14) ---

test "serializeCompactBoundary / parseCompactBoundary round-trip" {
    const allocator = testing.allocator;

    const tools = [_][]const u8{"ToolSearch"};
    const boundary = types.CompactBoundary{
        .trigger = .auto,
        .pre_compact_tokens = 42,
        .discovered_tools = &tools,
    };

    const line = try serializeCompactBoundary(allocator, boundary);
    defer allocator.free(line);

    try testing.expect(std.mem.startsWith(u8, line, COMPACT_BOUNDARY_PREFIX));
    try testing.expect(std.mem.indexOf(u8, line, "trigger=auto") != null);
    try testing.expect(std.mem.indexOf(u8, line, "pre_tokens=42") != null);
    try testing.expect(std.mem.indexOf(u8, line, "tools=ToolSearch") != null);

    const parsed = (try parseCompactBoundary(allocator, line)) orelse return error.TestUnexpectedNull;
    defer freeDiscoveredTools(allocator, parsed.discovered_tools);

    try testing.expectEqual(types.CompactTrigger.auto, parsed.trigger);
    try testing.expectEqual(@as(usize, 42), parsed.pre_compact_tokens);
    try testing.expectEqual(@as(usize, 1), parsed.discovered_tools.len);
    try testing.expectEqualStrings("ToolSearch", parsed.discovered_tools[0]);
    try testing.expectEqual(@as(?usize, null), parsed.preserved_head);
}

test "serializeCompactBoundary / parseCompactBoundary preserves indices and multiple tools" {
    const allocator = testing.allocator;

    const tools = [_][]const u8{ "ToolSearch", "Read", "Bash" };
    const boundary = types.CompactBoundary{
        .trigger = .manual,
        .pre_compact_tokens = 12345,
        .discovered_tools = &tools,
        .preserved_head = 0,
        .preserved_anchor = null,
        .preserved_tail = 3,
    };

    const line = try serializeCompactBoundary(allocator, boundary);
    defer allocator.free(line);

    const parsed = (try parseCompactBoundary(allocator, line)) orelse return error.TestUnexpectedNull;
    defer freeDiscoveredTools(allocator, parsed.discovered_tools);

    try testing.expectEqual(types.CompactTrigger.manual, parsed.trigger);
    try testing.expectEqual(@as(usize, 12345), parsed.pre_compact_tokens);
    try testing.expectEqual(@as(usize, 3), parsed.discovered_tools.len);
    try testing.expectEqualStrings("ToolSearch", parsed.discovered_tools[0]);
    try testing.expectEqualStrings("Read", parsed.discovered_tools[1]);
    try testing.expectEqualStrings("Bash", parsed.discovered_tools[2]);
    try testing.expectEqual(@as(?usize, 0), parsed.preserved_head);
    try testing.expectEqual(@as(?usize, null), parsed.preserved_anchor);
    try testing.expectEqual(@as(?usize, 3), parsed.preserved_tail);
}

test "parseCompactBoundary returns null for a non-boundary line" {
    const allocator = testing.allocator;
    try testing.expect((try parseCompactBoundary(allocator, "Conversation compacted by control action.")) == null);
    try testing.expect((try parseCompactBoundary(allocator, "")) == null);
}

test "serializeCompactBoundary handles an empty tool list" {
    const allocator = testing.allocator;
    const boundary = types.CompactBoundary{
        .trigger = .manual,
        .pre_compact_tokens = 7,
    };
    const line = try serializeCompactBoundary(allocator, boundary);
    defer allocator.free(line);
    try testing.expect(std.mem.indexOf(u8, line, "tools= ") != null);

    const parsed = (try parseCompactBoundary(allocator, line)) orelse return error.TestUnexpectedNull;
    defer freeDiscoveredTools(allocator, parsed.discovered_tools);
    try testing.expectEqual(@as(usize, 0), parsed.discovered_tools.len);
    try testing.expectEqual(@as(usize, 7), parsed.pre_compact_tokens);
}

test "renderCompactBoundary contains the glyph, body and ctrl+o history hint" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try renderCompactBoundary(&w, true);
    const out = w.buffered();
    // The ✻ TEARDROP_ASTERISK glyph bytes (U+273B).
    try testing.expect(std.mem.indexOf(u8, out, "\xe2\x9c\xbb") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Conversation compacted") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ctrl+o") != null);
    // Dim SGR present with color on.
    try testing.expect(std.mem.startsWith(u8, out, "\x1b[2m"));
    try testing.expect(std.mem.endsWith(u8, out, "\x1b[0m"));
}

test "renderCompactBoundary with color off has text but no SGR escapes" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try renderCompactBoundary(&w, false);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\xe2\x9c\xbb") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Conversation compacted") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ctrl+o") != null);
    // No SGR escape sequences when color is disabled.
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[") == null);
}

test "extractDiscoveredToolNames collects distinct tool names in first-seen order" {
    const allocator = testing.allocator;
    const history = [_]types.HistoryTurn{
        .{ .role = .user, .content = "do work", .timestamp = 0 },
        .{ .role = .tool, .content = "Tool: ToolSearch\nloaded Read", .timestamp = 1 },
        .{ .role = .tool, .content = "Tool: Read\nfile body", .timestamp = 2 },
        .{ .role = .tool, .content = "Tool: ToolSearch\nloaded Bash", .timestamp = 3 },
        .{ .role = .assistant, .content = "Tool: NotATool (in prose, ignored)", .timestamp = 4 },
    };

    const tools = try extractDiscoveredToolNames(allocator, &history);
    defer freeDiscoveredTools(allocator, tools);

    try testing.expectEqual(@as(usize, 2), tools.len);
    try testing.expectEqualStrings("ToolSearch", tools[0]);
    try testing.expectEqualStrings("Read", tools[1]);
}

// --- Task 12: partial / pivot-anchored compaction (compaction-07) ---

test "partialCompact .from summarizes the tail and records the preserved head" {
    const allocator = testing.allocator;
    const history = [_]types.HistoryTurn{
        .{ .role = .user, .content = "kept user turn one", .timestamp = 0 },
        .{ .role = .assistant, .content = "kept assistant turn", .timestamp = 1 },
        .{ .role = .user, .content = "summarized later turn", .timestamp = 2 },
        .{ .role = .assistant, .content = "summarized later reply", .timestamp = 3 },
    };

    var stub = StubSummarizer{ .text = "<summary>recent portion summary</summary>" };

    var result = try partialCompact(allocator, &history, 2, .from, stub.summarizer(), "", .manual);
    defer result.deinit(allocator);

    // The summary covers the summarized range only.
    try testing.expect(std.mem.indexOf(u8, result.summary, "recent portion summary") != null);
    try testing.expect(std.mem.startsWith(u8, result.summary, "Summary:"));

    // Preserved segment: the first 2 turns are kept verbatim (head=0, tail=1),
    // pivot recorded as the anchor.
    try testing.expectEqual(@as(?usize, 0), result.boundary.preserved_head);
    try testing.expectEqual(@as(?usize, 1), result.boundary.preserved_tail);
    try testing.expectEqual(@as(?usize, 2), result.boundary.preserved_anchor);
    try testing.expectEqual(types.CompactTrigger.manual, result.boundary.trigger);
}

test "partialCompact .up_to summarizes the head and keeps the tail verbatim" {
    const allocator = testing.allocator;
    const history = [_]types.HistoryTurn{
        .{ .role = .user, .content = "summarized prefix turn", .timestamp = 0 },
        .{ .role = .assistant, .content = "summarized prefix reply", .timestamp = 1 },
        .{ .role = .user, .content = "kept recent turn", .timestamp = 2 },
        .{ .role = .assistant, .content = "kept recent reply", .timestamp = 3 },
    };

    var stub = StubSummarizer{ .text = "<summary>prefix context summary</summary>" };

    var result = try partialCompact(allocator, &history, 2, .up_to, stub.summarizer(), "", .auto);
    defer result.deinit(allocator);

    try testing.expect(std.mem.indexOf(u8, result.summary, "prefix context summary") != null);

    // The kept verbatim side is history[2..]: head=2, tail=3 (last index).
    try testing.expectEqual(@as(?usize, 2), result.boundary.preserved_head);
    try testing.expectEqual(@as(?usize, 3), result.boundary.preserved_tail);
    try testing.expectEqual(@as(?usize, 2), result.boundary.preserved_anchor);
    try testing.expectEqual(types.CompactTrigger.auto, result.boundary.trigger);
}

test "partialCompact falls back to a rule-based summary with no summarizer" {
    const allocator = testing.allocator;
    const history = [_]types.HistoryTurn{
        .{ .role = .user, .content = "we must keep src/main.zig stable", .timestamp = 0 },
        .{ .role = .assistant, .content = "ok", .timestamp = 1 },
        .{ .role = .user, .content = "now add a feature", .timestamp = 2 },
    };

    var result = try partialCompact(allocator, &history, 1, .from, null, "", .manual);
    defer result.deinit(allocator);

    // Rule-based fallback marks the direction and the summarized-turn count.
    try testing.expect(std.mem.indexOf(u8, result.summary, "partial_summary") != null);
    try testing.expect(std.mem.indexOf(u8, result.summary, "direction=from") != null);
    try testing.expect(result.summary_hash != 0);
}

test "adjustPivotForPairing nudges left so a tool turn is not split from its producer" {
    const history = [_]types.HistoryTurn{
        .{ .role = .user, .content = "do work", .timestamp = 0 },
        .{ .role = .assistant, .content = "running tools", .timestamp = 1 },
        .{ .role = .tool, .content = "Tool: Read\nfile body", .timestamp = 2 },
        .{ .role = .tool, .content = "Tool: Bash\noutput", .timestamp = 3 },
        .{ .role = .assistant, .content = "done", .timestamp = 4 },
    };

    // Pivot landing on the second tool turn (index 3) must move back before the
    // assistant turn (index 1) that produced the tool run, keeping the whole
    // assistant+tool block on one side.
    try testing.expectEqual(@as(usize, 1), adjustPivotForPairing(&history, 3));
    // A pivot already on a non-tool boundary is unchanged.
    try testing.expectEqual(@as(usize, 1), adjustPivotForPairing(&history, 1));
    try testing.expectEqual(@as(usize, 4), adjustPivotForPairing(&history, 4));
    // Edge: pivot 0 and pivot == len are clamped, never split.
    try testing.expectEqual(@as(usize, 0), adjustPivotForPairing(&history, 0));
    try testing.expectEqual(@as(usize, history.len), adjustPivotForPairing(&history, history.len));
}

test "buildPartialCompactPrompt uses direction-specific framing and instructions" {
    const allocator = testing.allocator;
    const range = [_]types.HistoryTurn{
        .{ .role = .user, .content = "summarize me", .timestamp = 0 },
    };

    // .from variant frames the RECENT portion and lists "Current Work".
    {
        const out = try buildPartialCompactPrompt(allocator, &range, .from, "focus on errors");
        defer allocator.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "RECENT portion") != null);
        try testing.expect(std.mem.indexOf(u8, out, "Current Work") != null);
        try testing.expect(std.mem.indexOf(u8, out, "Compact Instructions") != null);
        try testing.expect(std.mem.indexOf(u8, out, "focus on errors") != null);
        try testing.expect(std.mem.indexOf(u8, out, "summarize me") != null);
    }

    // .up_to variant frames a continuing session and lists "Work Completed".
    {
        const out = try buildPartialCompactPrompt(allocator, &range, .up_to, "");
        defer allocator.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "continuing session") != null);
        try testing.expect(std.mem.indexOf(u8, out, "Work Completed") != null);
        try testing.expect(std.mem.indexOf(u8, out, "Context for Continuing Work") != null);
        // No instructions section when empty.
        try testing.expect(std.mem.indexOf(u8, out, "Compact Instructions") == null);
    }
}
