const std = @import("std");
const std_io = @import("core/std_io.zig");
const rt = @import("zcode_runtime");
const clock = @import("core/clock.zig");
const uuid = @import("core/uuid.zig");
const retry_after = @import("core/retry_after.zig");
const backoff = @import("core/backoff.zig");
const fallback_model = @import("core/fallback_model.zig");
const reactive_compaction = @import("core/reactive_compaction.zig");
const max_tokens_overflow = @import("core/max_tokens_overflow.zig");
const env_mod = @import("core/env.zig");

const types = @import("core/types.zig");
const config_mod = @import("core/config.zig");
const logger_mod = @import("core/logger.zig");
const control_plane = @import("core/control_plane.zig");
const compaction = @import("core/compaction.zig");
const keep_window_compact = @import("core/keep_window_compact.zig");
const tokenizer = @import("core/tokenizer.zig");
const cost_mod = @import("core/cost.zig");
const providers = @import("providers/mod.zig");
const common = @import("providers/common.zig");
const session_store = @import("session/store.zig");
const repl = @import("cli/repl.zig");
const mcp_client = @import("mcp/client.zig");

const agent_runtime = @import("agent_runtime.zig");
const model_allowlist = @import("core/model_allowlist.zig");

// --- Snapshot helpers ---

pub fn allocEmptySnapshot(allocator: std.mem.Allocator) !types.SessionSnapshot {
    // Stage each field into a local with its own errdefer so a mid-sequence
    // OOM unwinds everything allocated so far. Previously a failure in any
    // slot after the first leaked every prior zero-length slice. Matches the
    // same fix that `cloneSnapshot` already uses below.
    const facts = try allocator.alloc([]const u8, 0);
    errdefer allocator.free(facts);
    const decisions = try allocator.alloc([]const u8, 0);
    errdefer allocator.free(decisions);
    const open_tasks = try allocator.alloc([]const u8, 0);
    errdefer allocator.free(open_tasks);
    const file_focus = try allocator.alloc([]const u8, 0);
    errdefer allocator.free(file_focus);
    const recent_tool_outcomes = try allocator.alloc([]const u8, 0);
    errdefer allocator.free(recent_tool_outcomes);
    const handoff_summary = try allocator.dupe(u8, "");
    errdefer allocator.free(handoff_summary);
    const pinned_facts = try allocator.alloc([]const u8, 0);
    errdefer allocator.free(pinned_facts);
    const completed_tasks = try allocator.alloc([]const u8, 0);
    errdefer allocator.free(completed_tasks);
    const activated_conditional_skills = try allocator.alloc([]const u8, 0);
    return .{
        .facts = facts,
        .decisions = decisions,
        .open_tasks = open_tasks,
        .file_focus = file_focus,
        .recent_tool_outcomes = recent_tool_outcomes,
        .handoff_summary = handoff_summary,
        .pinned_facts = pinned_facts,
        .completed_tasks = completed_tasks,
        .activated_conditional_skills = activated_conditional_skills,
    };
}

pub fn cloneSnapshot(allocator: std.mem.Allocator, src: *const types.SessionSnapshot) !types.SessionSnapshot {
    // Stage each field into a local with its own errdefer so a failure
    // partway through unwinds everything allocated so far. Previously a
    // mid-sequence OOM in, say, `decisions` would leak the already-
    // cloned `facts` slice (and every string in it). Compounded across
    // fields, a large snapshot could leak kilobytes per failed clone.
    const facts = try cloneSlice(allocator, src.facts);
    errdefer freeStringSlice(allocator, facts);
    const decisions = try cloneSlice(allocator, src.decisions);
    errdefer freeStringSlice(allocator, decisions);
    const open_tasks = try cloneSlice(allocator, src.open_tasks);
    errdefer freeStringSlice(allocator, open_tasks);
    const file_focus = try cloneSlice(allocator, src.file_focus);
    errdefer freeStringSlice(allocator, file_focus);
    const recent_tool_outcomes = try cloneSlice(allocator, src.recent_tool_outcomes);
    errdefer freeStringSlice(allocator, recent_tool_outcomes);
    const handoff_summary = try allocator.dupe(u8, src.handoff_summary);
    errdefer allocator.free(handoff_summary);
    const pinned_facts = try cloneSlice(allocator, src.pinned_facts);
    errdefer freeStringSlice(allocator, pinned_facts);
    const completed_tasks = try cloneSlice(allocator, src.completed_tasks);
    errdefer freeStringSlice(allocator, completed_tasks);
    const activated_conditional_skills = try cloneSlice(allocator, src.activated_conditional_skills);
    return .{
        .facts = facts,
        .decisions = decisions,
        .open_tasks = open_tasks,
        .file_focus = file_focus,
        .recent_tool_outcomes = recent_tool_outcomes,
        .handoff_summary = handoff_summary,
        .pinned_facts = pinned_facts,
        .completed_tasks = completed_tasks,
        .activated_conditional_skills = activated_conditional_skills,
    };
}

const freeStringSlice = @import("core/parse_helpers.zig").freeStringSlice;

const cloneSlice = @import("core/parse_helpers.zig").cloneStringSlice;

pub fn freeSnapshot(allocator: std.mem.Allocator, snapshot: types.SessionSnapshot) void {
    for (snapshot.facts) |v| allocator.free(v);
    for (snapshot.decisions) |v| allocator.free(v);
    for (snapshot.open_tasks) |v| allocator.free(v);
    for (snapshot.file_focus) |v| allocator.free(v);
    for (snapshot.recent_tool_outcomes) |v| allocator.free(v);
    for (snapshot.pinned_facts) |v| allocator.free(v);
    for (snapshot.completed_tasks) |v| allocator.free(v);
    for (snapshot.activated_conditional_skills) |v| allocator.free(v);

    allocator.free(snapshot.facts);
    allocator.free(snapshot.decisions);
    allocator.free(snapshot.open_tasks);
    allocator.free(snapshot.file_focus);
    allocator.free(snapshot.recent_tool_outcomes);
    allocator.free(snapshot.handoff_summary);
    allocator.free(snapshot.pinned_facts);
    allocator.free(snapshot.completed_tasks);
    allocator.free(snapshot.activated_conditional_skills);
}

// --- History management ---

/// The live conversation history: an ordered list of turns whose `content`
/// strings are owned by this module and freed exactly once. Callers read
/// through `view`/`at`/`len` and mutate only through the methods below, so
/// the in-memory/disk relationship and the content lifecycle live in one
/// place instead of being re-implemented at every call site.
///
/// Persistence model: the session store is append-only JSONL. `append`
/// persists each turn (disk-before-memory); the in-memory-only mutations
/// (`clearInMemory`, `truncateFrom`, `replaceWith`) deliberately leave the
/// on-disk session untouched -- reload reconciles via the snapshot. This
/// matches the documented semantics of /clear, /rewind, and /resume.
pub const History = struct {
    allocator: std.mem.Allocator,
    turns: std.array_list.Managed(types.HistoryTurn),
    store: *session_store.Store,

    pub fn init(allocator: std.mem.Allocator, store: *session_store.Store) History {
        return .{
            .allocator = allocator,
            .turns = std.array_list.Managed(types.HistoryTurn).init(allocator),
            .store = store,
        };
    }

    /// Free every owned slice on a turn. Single freeing path so the
    /// optional `thinking` slice (ui-render-04) cannot be freed in one
    /// destruction site and forgotten in another. Always matched with a
    /// dupe at the corresponding construction site.
    fn freeTurn(self: *History, turn: types.HistoryTurn) void {
        self.allocator.free(turn.content);
        self.allocator.free(@constCast(turn.uuid));
        if (turn.thinking) |t| self.allocator.free(t);
    }

    pub fn deinit(self: *History) void {
        for (self.turns.items) |turn| {
            self.freeTurn(turn);
        }
        self.turns.deinit();
    }

    pub fn len(self: *const History) usize {
        return self.turns.items.len;
    }

    pub fn at(self: *const History, index: usize) types.HistoryTurn {
        return self.turns.items[index];
    }

    /// Read-only view of every turn. The returned slice and its `content`
    /// strings are owned by the History -- callers must not free or retain
    /// them past the next mutation.
    pub fn view(self: *const History) []const types.HistoryTurn {
        return self.turns.items;
    }

    /// Append a turn. All-or-nothing: if the disk-persist step fails we must
    /// not leave the in-memory history with a turn the store doesn't know
    /// about, nor leak the duped content.
    ///
    /// Order:
    ///  1. Reserve capacity so the final commit is infallible
    ///  2. Mint a uuid + dupe the content/uuid, guarded with errdefer
    ///  3. Persist to disk (can fail), sharing the same uuid so the
    ///     in-memory turn and the on-disk record agree
    ///  4. Commit in memory via infallible appendAssumeCapacity
    pub fn append(
        self: *History,
        session_id: []const u8,
        role: types.HistoryRole,
        content: []const u8,
    ) !void {
        try self.turns.ensureUnusedCapacity(1);
        const owned_content = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(owned_content);
        // Mint the turn uuid once and share it with the on-disk record so
        // a reloaded turn carries the same id the live turn had.
        const owned_uuid = try uuid.allocV4(self.allocator);
        errdefer self.allocator.free(owned_uuid);
        try self.store.appendTurn(session_id, role, content, owned_uuid);
        self.turns.appendAssumeCapacity(.{
            .role = role,
            .content = owned_content,
            .timestamp = clock.nowSeconds(),
            .uuid = owned_uuid,
        });
    }

    /// Append a turn carrying optional extended-thinking text
    /// (ui-render-04). Identical to `append` except the `thinking`
    /// slice is duped into the History allocator and owned by the turn
    /// (freed exactly once via `freeTurn`). The thinking text is NOT
    /// persisted to the JSONL store -- it is a live-session render
    /// artifact only, so the on-disk record matches `append`'s shape.
    /// Pass `null` (or empty) to behave exactly like `append`.
    pub fn appendWithThinking(
        self: *History,
        session_id: []const u8,
        role: types.HistoryRole,
        content: []const u8,
        thinking: ?[]const u8,
    ) !void {
        try self.turns.ensureUnusedCapacity(1);
        const owned_content = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(owned_content);
        const owned_uuid = try uuid.allocV4(self.allocator);
        errdefer self.allocator.free(owned_uuid);
        // Dupe thinking only when non-empty; an empty reasoning string
        // is stored as null so the renderer's "has thinking" check is a
        // simple optional test.
        const owned_thinking: ?[]const u8 = if (thinking) |t|
            (if (t.len > 0) try self.allocator.dupe(u8, t) else null)
        else
            null;
        errdefer if (owned_thinking) |t| self.allocator.free(t);
        try self.store.appendTurn(session_id, role, content, owned_uuid);
        self.turns.appendAssumeCapacity(.{
            .role = role,
            .content = owned_content,
            .timestamp = clock.nowSeconds(),
            .uuid = owned_uuid,
            .thinking = owned_thinking,
        });
    }

    /// Drop every in-memory turn, freeing owned content. The on-disk session
    /// JSONL is left untouched -- /clear's documented "start fresh in the
    /// same session slot" semantics.
    pub fn clearInMemory(self: *History) void {
        for (self.turns.items) |turn| {
            self.freeTurn(turn);
        }
        self.turns.clearRetainingCapacity();
    }

    /// Drop in-memory turns from `index` to the end, freeing their content.
    /// No-op when `index >= len`. Disk untouched (append-only by design).
    pub fn truncateFrom(self: *History, index: usize) void {
        if (index >= self.turns.items.len) return;
        var i = index;
        while (i < self.turns.items.len) : (i += 1) {
            self.freeTurn(self.turns.items[i]);
        }
        self.turns.shrinkRetainingCapacity(index);
    }

    /// Replace the entire in-memory history with deep copies of `turns`.
    /// Atomic: every new turn is duped into scratch first (fallible); only
    /// once all copies succeed is the old history freed and swapped in, so an
    /// OOM leaves the existing history intact. Disk untouched.
    pub fn replaceWith(self: *History, turns: []const types.HistoryTurn) !void {
        var scratch = std.array_list.Managed(types.HistoryTurn).init(self.allocator);
        errdefer {
            for (scratch.items) |item| {
                self.freeTurn(item);
            }
            scratch.deinit();
        }
        try scratch.ensureTotalCapacity(turns.len);
        for (turns) |turn| {
            const dup_content = try self.allocator.dupe(u8, turn.content);
            errdefer self.allocator.free(dup_content);
            // Always dup the uuid (even "") so each scratch turn owns its
            // id and the frees below / on deinit stay unconditional.
            const dup_uuid = try self.allocator.dupe(u8, turn.uuid);
            errdefer self.allocator.free(dup_uuid);
            // Preserve any owned thinking text on the source turn so a
            // replace (resume/rewind) does not drop the persisted
            // reasoning. Source turns from JSONL load carry null, so this
            // is usually a no-op.
            const dup_thinking: ?[]const u8 = if (turn.thinking) |t|
                (if (t.len > 0) try self.allocator.dupe(u8, t) else null)
            else
                null;
            scratch.appendAssumeCapacity(.{
                .role = turn.role,
                .content = dup_content,
                .timestamp = turn.timestamp,
                .uuid = dup_uuid,
                .thinking = dup_thinking,
            });
        }
        // Commit: free old, swap in scratch. Infallible from here.
        for (self.turns.items) |turn| {
            self.freeTurn(turn);
        }
        self.turns.deinit();
        self.turns = scratch;
    }
};

pub fn pushRecentOutcome(
    allocator: std.mem.Allocator,
    snapshot: *types.SessionSnapshot,
    outcome: []const u8,
) !void {
    const old = snapshot.recent_tool_outcomes;
    const keep = @min(old.len, @as(usize, 9));
    const start = old.len - keep;

    const out = try allocator.alloc([]const u8, keep + 1);
    var filled: usize = 0;
    errdefer {
        var j: usize = 0;
        while (j < filled) : (j += 1) allocator.free(out[j]);
        allocator.free(out);
    }

    var i: usize = 0;
    while (i < keep) : (i += 1) {
        out[i] = try allocator.dupe(u8, old[start + i]);
        filled = i + 1;
    }
    out[keep] = try allocator.dupe(u8, outcome);
    filled = keep + 1;

    for (old) |v| allocator.free(v);
    allocator.free(old);

    snapshot.recent_tool_outcomes = out;
}

pub fn forceCompaction(
    history: *History,
    snapshot: *types.SessionSnapshot,
    session_id: []const u8,
    model_context_window: usize,
    reserved_output_tokens: usize,
    reserved_reasoning_tokens: usize,
    summarizer: ?compaction.Summarizer,
    custom_instructions: []const u8,
    // Phase 8 (compaction-14): what kicked off this compaction. "auto" is the
    // in-turn auto-compaction control action; "manual" is the explicit
    // `/compact` command. Threaded into the structured boundary marker below.
    trigger: types.CompactTrigger,
) !void {
    const allocator = history.allocator;
    var budget = types.BudgetPlan.init(
        model_context_window,
        reserved_output_tokens,
        reserved_reasoning_tokens,
    );
    budget.compaction_thresholds.compact_percent = 0;

    // Phase 8 (compaction-14): scan the pre-compaction history for discovered
    // (deferred-loaded) tools BEFORE the snapshot swap, so the boundary marker
    // records what tooling the pre-boundary segment used. Mirrors the
    // reference's `preCompactDiscoveredTools` capture (compact.ts:598-611). A
    // scan failure (OOM) degrades to an empty list, not a failed compaction.
    const discovered_tools = compaction.extractDiscoveredToolNames(allocator, history.view()) catch &.{};
    defer compaction.freeDiscoveredTools(allocator, discovered_tools);

    // Task 1 (compaction-01): pass the optional model-summary indirection and
    // any custom instructions down so the explicit compaction path produces a
    // model-written summary, falling back to the rule-based one when null.
    var result = try compaction.maybeCompact(allocator, history.view(), budget, summarizer, custom_instructions);
    defer result.deinit(allocator);

    if (!result.did_compact) return;

    // Clone first, then swap: if cloneSnapshot OOMs after we've
    // already freed `snapshot.*`, we would leave dangling slice
    // headers that the next tool call or deinit dereferences. Same
    // pattern as the /resume fix in repl_commands.zig (pass 4/17).
    const new_snapshot = try cloneSnapshot(allocator, &result.snapshot);
    freeSnapshot(allocator, snapshot.*);
    snapshot.* = new_snapshot;

    // Phase 8 (compaction-14): append a structured compact-boundary marker
    // instead of the bare "Conversation compacted by control action." note. The
    // serialized line is human-readable, prefixed with `compact_boundary`, and
    // carries the trigger, pre-compaction token total, and discovered tools so
    // the transcript loader, `/context` telemetry, and `--resume` can relink it.
    // `history.append` persists it (disk-before-memory) and reload returns it as
    // a `.system` turn whose content starts with the prefix.
    //
    // Divergence: zcode history turns are positional, not UUID-keyed, so the
    // preserved-segment relinks would be turn indices. They stay null here
    // because the full-history compaction path preserves no verbatim segment;
    // the partial/pivot path (Task 12, deferred) is where they become non-null.
    const boundary = types.CompactBoundary{
        .trigger = trigger,
        .pre_compact_tokens = result.pre_compact_tokens,
        .discovered_tools = discovered_tools,
    };
    const marker = compaction.serializeCompactBoundary(allocator, boundary) catch
        try allocator.dupe(u8, "compact_boundary trigger=auto pre_tokens=0 tools= head= anchor= tail=");
    defer allocator.free(marker);
    try history.append(session_id, .system, marker);
}

/// Opt-in bounded keep-window compaction (compaction-11, Task 13)
/// [experimental / deferable]. An ALTERNATIVE to `forceCompaction`'s LLM/rule
/// path: instead of summarizing the whole history with a model call, keep a
/// recent window bounded by min/max tokens and a min text-block-message count,
/// and use the already-accumulated session memory (the snapshot's
/// `handoff_summary`) as the summary for the dropped prefix. The keep boundary
/// is adjusted so it never splits a tool turn from its producing assistant turn.
///
/// GATING: this is gated behind `cfg.enabled` (default OFF). When disabled it is
/// a no-op and the caller stays on the default `forceCompaction` path, so this
/// experimental transform can never regress the default compaction. Returns
/// `true` when a keep-window compaction actually happened, `false` otherwise
/// (disabled, empty history, or the window already covers the whole history).
///
/// On success the in-memory history is replaced with the kept verbatim window
/// and a structured `compact_boundary` marker is persisted (same shape as
/// `forceCompaction`). The session memory used as the summary is left in the
/// snapshot's `handoff_summary`; this path does not run the model.
pub fn forceKeepWindowCompaction(
    history: *History,
    snapshot: *const types.SessionSnapshot,
    session_id: []const u8,
    cfg: keep_window_compact.KeepWindowConfig,
    trigger: types.CompactTrigger,
) !bool {
    if (!cfg.enabled) return false;
    const allocator = history.allocator;

    const turns = history.view();
    if (turns.len == 0) return false;

    const keep_index = keep_window_compact.calculateKeepIndex(turns, cfg);
    // Nothing to drop: the bounded window already spans the whole history, so a
    // keep-window compaction would be a no-op. Leave history untouched.
    if (keep_index == 0) return false;

    // Scan for discovered (deferred-loaded) tools BEFORE the history is rewritten
    // so the boundary marker records the pre-boundary tooling. A scan OOM
    // degrades to an empty list rather than aborting the compaction.
    const discovered_tools = compaction.extractDiscoveredToolNames(allocator, turns) catch &.{};
    defer compaction.freeDiscoveredTools(allocator, discovered_tools);

    // Build the keep-window result. `handoff_summary` is zcode's session-memory
    // string (the accumulated handoff); it stands in for the reference's
    // session-memory store. The kept window borrows content from `turns`, so we
    // must finish using it (the replaceWith below deep-copies) before the next
    // history mutation.
    var result = try keep_window_compact.createResultFromSessionMemory(
        allocator,
        turns,
        keep_index,
        snapshot.handoff_summary,
        trigger,
    );
    defer result.deinit(allocator);

    // Replace the in-memory history with deep copies of the kept window (disk is
    // left untouched, matching the in-memory-only mutation contract).
    try history.replaceWith(result.kept);

    // Persist the structured boundary marker carrying the preserved-segment
    // relink indices (head/anchor/tail) so the transcript loader and `/context`
    // telemetry can recognize and relink the boundary.
    const boundary = types.CompactBoundary{
        .trigger = result.boundary.trigger,
        .pre_compact_tokens = result.boundary.pre_compact_tokens,
        .discovered_tools = discovered_tools,
        .preserved_head = result.boundary.preserved_head,
        .preserved_anchor = result.boundary.preserved_anchor,
        .preserved_tail = result.boundary.preserved_tail,
    };
    const marker = compaction.serializeCompactBoundary(allocator, boundary) catch
        try allocator.dupe(u8, "compact_boundary trigger=auto pre_tokens=0 tools= head= anchor= tail=");
    defer allocator.free(marker);
    try history.append(session_id, .system, marker);
    return true;
}

// --- Token tracking ---

pub fn recordPromptStats(token_status: *agent_runtime.TokenStatus, lock: *std.Io.Mutex, prompt_tokens: usize, cache_hints: usize, budget_input: usize) void {
    lock.lock(rt.io) catch {};
    defer lock.unlock(rt.io);
    token_status.last_prompt_tokens = prompt_tokens;
    token_status.last_cache_hints = cache_hints;
    token_status.last_budget_input = budget_input;
}

pub fn recordResponseUsage(token_status: *agent_runtime.TokenStatus, lock: *std.Io.Mutex, input_tokens: usize, output_tokens: usize) void {
    lock.lock(rt.io) catch {};
    defer lock.unlock(rt.io);
    token_status.last_input_tokens = input_tokens;
    token_status.last_output_tokens = output_tokens;
    token_status.total_input_tokens += input_tokens;
    token_status.total_output_tokens += output_tokens;
}

pub fn statusMetrics(
    token_status: *agent_runtime.TokenStatus,
    lock: *std.Io.Mutex,
    active_provider: []const u8,
    active_model: []const u8,
) repl.StatusMetrics {
    lock.lock(rt.io) catch {};
    defer lock.unlock(rt.io);
    const session_cost_dollars = cost_mod.estimateCost(
        active_provider,
        active_model,
        token_status.total_input_tokens,
        token_status.total_output_tokens,
    );
    return .{
        .last_prompt_tokens = token_status.last_prompt_tokens,
        .last_input_tokens = token_status.last_input_tokens,
        .last_output_tokens = token_status.last_output_tokens,
        .total_input_tokens = token_status.total_input_tokens,
        .total_output_tokens = token_status.total_output_tokens,
        .last_cache_hints = token_status.last_cache_hints,
        .last_budget_input = token_status.last_budget_input,
        .estimated_session_cost_cents = @intFromFloat(@round(session_cost_dollars * 100.0)),
    };
}

// --- Provider / model call ---

pub fn callModel(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    active_provider: []const u8,
    active_model: []const u8,
    interactive: bool,
    current_reporter: ?repl.ProgressReporter,
    request: types.ModelRequest,
    // When non-null and the active model is overloaded MAX_CONSECUTIVE_529 times
    // in a row AND a distinct `fallback_model` is configured, the chosen
    // fallback model name is written here and `error.FallbackTriggered` is
    // surfaced so the caller can announce the swap and retry once. Borrowed from
    // cfg.fallback_model (config-owned, stable for the session): do NOT free it.
    fallback_out: ?*?[]const u8,
    // When non-null and the request succeeded only after at least one reactive
    // history reduction (Task 7.5 / agent-loop-deep-14 413 recovery), this is set
    // to true so the caller can surface `compaction_applied` on the TurnResult.
    // Left untouched (so the caller's `false` default is preserved) when no
    // reduction fired. Borrowed pointer; the value lives on the caller's stack.
    reactive_applied_out: ?*bool,
) !types.ModelResponse {
    // The cancel flag is cleared by the root agent once per user turn in
    // handlePromptDetailedWithModeAndReporter (depth == 0). Do NOT clear
    // it here: callModel runs once per tool round, and clearing between
    // rounds would discard an ESC the user pressed between rounds, and
    // clearing inside a sub-agent (depth > 0) would hide the parent's
    // cancel from the child. If cancel is already set when we enter,
    // surface it immediately so we never start a request the user has
    // already abandoned.
    try common.checkCancelled();

    // Gate the active model against the availableModels allowlist before the
    // first API call. Fail closed with a helpful message (not a panic) when the
    // model is not allowed. An unset/empty allowlist allows everything
    // (documented zcode deviation), so this is a no-op for most users.
    if (!try model_allowlist.isAllowed(allocator, active_model, cfg.available_models)) {
        std.log.err(
            "model '{s}' is not in the availableModels allowlist; refusing API call",
            .{active_model},
        );
        return error.ModelNotAllowed;
    }

    var adapter = try providers.createAdapterWithOverrides(
        allocator,
        active_provider,
        providerAdapterOverrides(cfg, active_provider, false),
    );
    defer adapter.deinit(allocator);

    // Fallback swap is gated and announced, not silent (PRD #534, Phase 7.4).
    // With default config (no `fallback_model` configured) the behavior is
    // unchanged: a failing active model surfaces its error so the user can
    // diagnose and fix it or switch manually. Only when the operator has opted
    // in by configuring a distinct `fallback_model` do MAX_CONSECUTIVE_529
    // consecutive overloads trigger an announced swap (handled by callModel's
    // caller, which reads `fallback_out` and retries once with the new model).
    return callWithAdapter(allocator, cfg, active_provider, active_model, interactive, current_reporter, &adapter, request, fallback_out, reactive_applied_out);
}

fn callWithAdapter(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    active_provider: []const u8,
    active_model: []const u8,
    interactive: bool,
    current_reporter: ?repl.ProgressReporter,
    adapter: *types.ProviderAdapter,
    request: types.ModelRequest,
    fallback_out: ?*?[]const u8,
    reactive_applied_out: ?*bool,
) !types.ModelResponse {
    _ = active_provider;
    var attempt: u8 = 0;
    // Run of consecutive overload (529/503 -> ServerOverloaded) errors. Reset to
    // 0 on any non-overload error class or a success. The reference counts 529s
    // for any model and only swaps when a fallback is configured; zcode has no
    // Opus-specific gate (it supports many providers) so we mirror that loosely:
    // count overloads for any active model, but only swap when `fallback_model`
    // is configured and distinct. Documented divergence (PRD #534, Phase 7.4).
    var consecutive_529: u32 = 0;

    // Reactive compaction state (Task 7.5). On a RequestTooLarge (HTTP 413 or a
    // 400 carrying "prompt is too long: N > M"), reduce the request's history
    // and retry instead of failing the turn. The reduction is request-scoped:
    // we mutate a local copy of the request, not the caller's durable history.
    // The durable history is compacted by the proactive forceCompaction path on
    // the next turn. Cap reactive retries so a model that always 413s cannot
    // loop forever.
    var current_request = request;
    var reactive_retries: u8 = 0;
    const MAX_REACTIVE_RETRIES: u8 = 2;
    // The most recent reduced-history slice we own and must free. `reduce`
    // returns a fresh slice of shallow turn copies; we own the slice (not the
    // turn contents, which borrow from the caller's history), so free only the
    // slice. Tracked here so each new reduction frees the prior one and scope
    // exit frees the last.
    var owned_reduced_history: ?[]types.HistoryTurn = null;
    defer if (owned_reduced_history) |h| allocator.free(h);

    // max_tokens / context-overflow auto-adjust state (Task 7.6). On a
    // MaxTokensOverflow (a 400 "input length and `max_tokens` exceed context
    // limit: A + B > C"), lower `request.max_output_tokens` to fit the remaining
    // context and retry rather than failing. Capped so a model that keeps
    // rejecting cannot loop; one adjustment is normally enough.
    var max_tokens_retries: u8 = 0;
    const MAX_OVERFLOW_RETRIES: u8 = 2;

    // Persistent / unattended retry mode (Task 7.8) counter. Separate from
    // `attempt` so the normal provider_retry_count cap does not gate it; this one
    // only advances while we are looping indefinitely on rate-limit / overload
    // errors with ZCODE_CODE_UNATTENDED_RETRY set. Drives the exponential backoff
    // schedule (backoff.delayMs).
    var persistent_attempt: u32 = 0;

    while (true) {
        const response = callWithAdapterOnce(allocator, cfg, interactive, current_reporter, adapter, current_request) catch |err| {
            // If the user pressed ESC during the call, curl is killed
            // and callWithAdapterOnce returns HttpTransport. Without
            // this check the retry loop would immediately spawn a new
            // curl against the same URL and the cancel would appear
            // to do nothing until the next round boundary. Surface the
            // error so the outer agent loop sees the cancellation and
            // exits cleanly.
            if (current_reporter) |r| {
                if (r.is_cancelled) |is_cancelled_fn| {
                    if (is_cancelled_fn(r.ctx)) return err;
                }
            }

            // Track the run of consecutive overloads. A 529 then a 503 both map
            // to ServerOverloaded and both count toward the run; only a
            // different error class (or a success below) resets the counter.
            if (err == error.ServerOverloaded) {
                consecutive_529 += 1;
            } else {
                consecutive_529 = 0;
            }

            // Config-gated, announced fallback swap on repeated overload. Checked
            // BEFORE the retry-budget gate so the swap fires at exactly
            // MAX_CONSECUTIVE_529 overloads even when the normal retry budget
            // (provider_retry_count) would otherwise stop the loop first. `pick`
            // returns null when no distinct fallback is configured, so default
            // config never swaps and falls through to the normal retry/surface
            // path unchanged.
            if (consecutive_529 >= backoff.MAX_CONSECUTIVE_529) {
                const trig = fallback_model.triggerFromStatus(529);
                if (fallback_model.pick(active_model, cfg.fallback_model, trig)) |fb| {
                    if (fallback_out) |out| {
                        out.* = fb;
                        return error.FallbackTriggered;
                    }
                }
            }

            // Reactive compaction on prompt-too-long / 413 (Task 7.5). When the
            // request is rejected for being over budget, reduce history and retry
            // the same turn rather than failing it. This is intercepted BEFORE
            // the isRetriableProviderError gate because RequestTooLarge is
            // deliberately non-retriable there: retrying the identical oversized
            // request would just burn the budget. We only retry AFTER shrinking.
            if (err == error.RequestTooLarge) {
                // Cap reactive retries so a model that always 413s does not loop.
                if (reactive_retries >= MAX_REACTIVE_RETRIES) return err;

                const prev_len = current_request.history.len;
                // Nothing left to drop (no or minimal history): surface the error
                // rather than spinning on an unshrinkable request.
                if (prev_len == 0) return err;

                // Size the reduction window by the parsed token gap when the body
                // carried "prompt is too long: N > M". A large overflow drops more
                // aggressively; absent/unparseable bodies use a default window.
                const body = common.lastErrorBody();
                const keep_last_n: usize = reactiveKeepWindow(reactive_compaction.promptTooLongGap(body));

                const reduced = reactive_compaction.reduce(allocator, current_request.history, keep_last_n) catch return err;
                // If the reduction could not shrink the history (already at or
                // below the window), retrying would re-send the same request.
                if (reduced.len >= prev_len) {
                    allocator.free(reduced);
                    return err;
                }
                // Swap in the reduced history, freeing any prior reduction slice.
                if (owned_reduced_history) |old| allocator.free(old);
                owned_reduced_history = reduced;
                current_request.history = reduced;

                reactive_retries += 1;
                emitReactiveCompactionProgress(current_reporter, prev_len, reduced.len);
                // Retry immediately with the reduced request; no backoff needed
                // since this is a client-side correction, not a transient fault.
                continue;
            }

            // max_tokens / context-overflow auto-adjust (Task 7.6). The provider
            // rejected the request because input + max_tokens exceed the context
            // limit. Lower max_output_tokens to fit and retry the same turn,
            // rather than failing. Like RequestTooLarge this is intercepted BEFORE
            // the isRetriableProviderError gate (which keeps MaxTokensOverflow
            // non-retriable) so the retry only happens AFTER the correction.
            if (err == error.MaxTokensOverflow) {
                // Cap so a model that keeps over-reporting cannot loop forever.
                if (max_tokens_retries >= MAX_OVERFLOW_RETRIES) return err;

                const parsed = max_tokens_overflow.parseMaxTokensContextOverflow(common.lastErrorBody()) orelse return err;
                // zcode threads no per-request extended-thinking token budget on
                // ModelRequest (reasoning is an enum effort band, not a number),
                // so the thinking-budget floor is 0 here. Documented divergence
                // from the reference's `thinkingBudget + 1` term.
                const adjusted = max_tokens_overflow.adjustMaxTokens(parsed, 0) orelse return err;
                const new_max = std.math.cast(usize, adjusted) orelse return err;
                // If the adjustment would not actually lower the cap, retrying
                // would re-send the identical request; surface the error instead.
                if (new_max >= current_request.max_output_tokens) return err;

                const prev_max = current_request.max_output_tokens;
                current_request.max_output_tokens = new_max;
                max_tokens_retries += 1;
                emitMaxTokensAdjustProgress(current_reporter, prev_max, new_max);
                // Client-side correction, no backoff needed.
                continue;
            }

            // Persistent / unattended retry mode (Task 7.8). When
            // ZCODE_CODE_UNATTENDED_RETRY is set truthy, a rate-limit or overload
            // error is NOT subject to the normal provider_retry_count budget:
            // keep retrying indefinitely (backoff capped at 5 min, single wait
            // capped at 6 hr) so an AFK session rides out a capacity cascade
            // instead of dying. Only RateLimited / ServerOverloaded qualify;
            // every other error still terminates as usual. The fallback-swap gate
            // above (3 consecutive overloads + configured fallback) is checked
            // BEFORE this branch, so a configured fallback still wins over an
            // indefinite wait -- matching the reference precedence. This is a
            // strictly env-gated AFK feature: default behavior is unchanged.
            if (unattendedRetryEnabled() and isPersistentRetriableError(err)) {
                // Separate counter so the normal `attempt` cap is not the gate.
                const headers = common.lastResponseHeaders();
                const computed_ms = backoff.delayMs(persistent_attempt, backoff.BASE_DELAY_MS, backoff.PERSISTENT_MAX_BACKOFF_MS);
                // Prefer a provider-supplied wait (reset / retry-after header);
                // the parsers already clamp the reset header to 6 hr.
                const delay_ms = retry_after.effectiveDelayMs(headers, clock.nowMillis(), computed_ms);
                persistent_attempt +%= 1;
                emitPersistentRetryProgress(current_reporter, persistent_attempt, delay_ms);
                // Chunk the wait so ESC stays responsive; a cancel between chunks
                // surfaces UserCancelled and breaks the loop.
                try chunkedSleep(delay_ms, current_reporter);
                continue;
            }

            if (!isRetriableProviderError(err) or attempt >= cfg.provider_retry_count) {
                return err;
            }

            attempt += 1;
            // Honor a provider-supplied wait when present (the `retry-after`
            // header, or `anthropic-ratelimit-unified-reset`) instead of the
            // client-computed linear backoff. The headers from the error
            // response are stashed by common.callHttp* on the >=400 path and
            // cleared per top-level call by beginNewRequest; absent timing
            // headers fall back to the computed `attempt*300` delay.
            const computed_ms: u64 = @as(u64, attempt) * 300;
            const headers = common.lastResponseHeaders();
            const header_delay = retry_after.effectiveDelayMs(headers, clock.nowMillis(), computed_ms);
            // Clamp the wait in normal (non-persistent) mode so a hostile
            // header cannot stall the turn unboundedly. Persistent mode (above)
            // lifts this cap in the env-gated unattended retry mode.
            const NORMAL_MODE_MAX_DELAY_MS: u64 = 60 * 1000;
            const delay_ms: u64 = @min(header_delay, NORMAL_MODE_MAX_DELAY_MS);
            try chunkedSleep(delay_ms, current_reporter);
            continue;
        };

        // Surface whether this request only succeeded after a reactive history
        // reduction (413 -> reduce -> retry). The caller folds this into the
        // TurnResult's `compaction_applied` so the recovery is visible in the
        // exec/CI JSON, matching the reference's reactive-compact signal.
        if (reactive_retries > 0) {
            if (reactive_applied_out) |out| out.* = true;
        }
        return response;
    }
}

/// Errors that the persistent / unattended retry mode (Task 7.8) keeps retrying
/// past the normal retry budget. Mirrors the reference, which only loops
/// indefinitely on 429 (RateLimited) and 529/503 (ServerOverloaded); every other
/// error class still terminates the turn. Note RateLimited is normally NON
/// retriable (see isRetriableProviderError) -- persistent mode deliberately
/// overrides that, since an AFK session would rather wait out a rate limit than
/// give up.
fn isPersistentRetriableError(err: anyerror) bool {
    return err == error.RateLimited or err == error.ServerOverloaded;
}

/// Cached read of ZCODE_CODE_UNATTENDED_RETRY (zcode-namespaced analog of the
/// reference's CLAUDE_CODE_UNATTENDED_RETRY). Read once: the env var does not
/// change mid-process, and getenv on the retry path should not re-scan every
/// failure. Truthy vocabulary is the shared core/env.zig one ("1"/"true"/...).
var unattended_retry_checked: bool = false;
var unattended_retry_value: bool = false;

fn unattendedRetryEnabled() bool {
    if (unattended_retry_checked) return unattended_retry_value;
    unattended_retry_checked = true;
    unattended_retry_value = env_mod.isEnvTruthy("ZCODE_CODE_UNATTENDED_RETRY");
    return unattended_retry_value;
}

/// Test-only seam: force the unattended-retry flag without setting a process env
/// var (which the cache would only read once, and which would leak across
/// tests). Production never calls this. Pass null to reset to "re-read env on
/// next call".
fn setUnattendedRetryForTest(value: ?bool) void {
    if (value) |v| {
        unattended_retry_checked = true;
        unattended_retry_value = v;
    } else {
        unattended_retry_checked = false;
        unattended_retry_value = false;
    }
}

/// Sleep `total_ms`, chunked into HEARTBEAT_INTERVAL_MS pieces so the user can
/// cancel (ESC) during a long persistent-mode wait. Between chunks it checks both
/// the global cancel flag (common.checkCancelled) and the reporter's
/// is_cancelled hook, surfacing error.UserCancelled the moment either trips. The
/// actual sleep goes through the injectable `sleep_ms_fn` seam so tests can
/// observe the requested durations without waiting on the wall clock.
fn chunkedSleep(total_ms: u64, reporter: ?repl.ProgressReporter) error{UserCancelled}!void {
    var remaining = total_ms;
    while (remaining > 0) {
        try common.checkCancelled();
        if (reporter) |r| {
            if (r.is_cancelled) |is_cancelled_fn| {
                if (is_cancelled_fn(r.ctx)) return error.UserCancelled;
            }
        }
        const chunk = @min(remaining, backoff.HEARTBEAT_INTERVAL_MS);
        sleep_ms_fn(chunk);
        remaining -= chunk;
    }
    // Final cancellation check after the last chunk so a cancel that arrived
    // during the very last sleep still breaks before we re-issue the request.
    try common.checkCancelled();
}

/// Injectable sleep seam (milliseconds). Production routes to clock.sleepNanos;
/// tests override this to record requested durations and return instantly so the
/// retry loop never actually blocks. Never call clock.sleepNanos directly in the
/// retry path -- go through here so the wait stays observable in tests.
var sleep_ms_fn: *const fn (u64) void = defaultSleepMs;

fn defaultSleepMs(ms: u64) void {
    clock.sleepNanos(ms * std.time.ns_per_ms);
}

/// Best-effort progress line announcing a persistent-mode retry wait so an AFK
/// session's host/TUI sees activity instead of a silent multi-minute stall.
fn emitPersistentRetryProgress(reporter: ?repl.ProgressReporter, attempt: u32, delay_ms: u64) void {
    const r = reporter orelse return;
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "unattended retry #{d}: provider unavailable, waiting {d}s before retrying",
        .{ attempt, delay_ms / 1000 },
    ) catch return;
    r.update(r.ctx, msg);
}

/// Choose how many recent non-system turns to keep when reactively reducing
/// history after a prompt-too-long rejection (Task 7.5). Defaults to a modest
/// window; when the provider reported a large token overflow we drop more
/// aggressively (smaller window) so a single retry has a real chance of fitting.
/// Pure so it is unit-testable without a live provider.
fn reactiveKeepWindow(gap: ?u64) usize {
    const DEFAULT_WINDOW: usize = 8;
    const AGGRESSIVE_WINDOW: usize = 4;
    // A "large" overflow is one where shaving a handful of recent turns is
    // unlikely to be enough; 20k tokens is roughly several long turns.
    const LARGE_GAP_TOKENS: u64 = 20_000;
    if (gap) |g| {
        if (g >= LARGE_GAP_TOKENS) return AGGRESSIVE_WINDOW;
    }
    return DEFAULT_WINDOW;
}

/// Best-effort progress line announcing a reactive history reduction so the
/// host/TUI shows activity instead of a silent stall during the retry. The
/// message is built on a small stack buffer; an overflow simply skips the line.
fn emitReactiveCompactionProgress(reporter: ?repl.ProgressReporter, before: usize, after: usize) void {
    const r = reporter orelse return;
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "request too large; reduced history {d} -> {d} turns and retrying",
        .{ before, after },
    ) catch return;
    r.update(r.ctx, msg);
}

/// Best-effort progress line announcing a max_tokens lowering after a
/// context-overflow rejection (Task 7.6). Mirrors emitReactiveCompactionProgress.
fn emitMaxTokensAdjustProgress(reporter: ?repl.ProgressReporter, before: usize, after: usize) void {
    const r = reporter orelse return;
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "max_tokens exceeded context limit; lowering {d} -> {d} and retrying",
        .{ before, after },
    ) catch return;
    r.update(r.ctx, msg);
}

const ChunkBridge = struct {
    reporter_ctx: *anyopaque,
    emit_fn: *const fn (*anyopaque, []const u8) void,

    fn dispatch(ctx: *anyopaque, chunk: []const u8) void {
        const bridge: *ChunkBridge = @ptrCast(@alignCast(ctx));
        bridge.emit_fn(bridge.reporter_ctx, chunk);
    }
};

var debug_llm_log: ?std.Io.File = null;
var debug_llm_log_checked: bool = false;

/// Open (once) the file named by ZCODE_DEBUG_LLM for appending raw model
/// request/response records. Cached so getenv runs once; zero overhead when
/// unset. Mirrors the ZCODE_DEBUG_INPUT pattern in cli/repl_input.zig.
fn debugLlmFile() ?std.Io.File {
    if (debug_llm_log_checked) return debug_llm_log;
    debug_llm_log_checked = true;
    const path = @import("core/env.zig").getenv("ZCODE_DEBUG_LLM") orelse return null;
    if (path.len == 0) return null;
    debug_llm_log = std.Io.Dir.cwd().createFile(rt.io, path, .{ .truncate = false }) catch return null;
    return debug_llm_log;
}

/// Append one model-call record when ZCODE_DEBUG_LLM is set: provider+model and
/// request fields, then the verbatim response.raw (so Anthropic's stop_reason +
/// content blocks are visible for diagnosing empty completions). Never logs HTTP
/// headers or the API key -- they are not in scope at this layer. Best-effort.
fn debugLlmLog(allocator: std.mem.Allocator, provider: []const u8, request: types.ModelRequest, response: *const types.ModelResponse) void {
    const log = debugLlmFile() orelse return;
    const record = std.fmt.allocPrint(
        allocator,
        "\n===== LLM CALL {s}/{s} effort={s} max_out={d} tool_choice={s} tools={d} sys_len={d} =====\n" ++
            "--- prompt ---\n{s}\n" ++
            "--- response (text_len={d} tools_len={d} truncated={}) raw ---\n{s}\n",
        .{
            provider,                            request.model,
            @tagName(request.reasoning_effort),  request.max_output_tokens,
            request.tool_choice orelse "(none)", request.tool_schemas.len,
            request.system_prompt.len,           request.prompt,
            response.text.len,                   response.tool_calls_json.len,
            response.truncated,                  response.raw,
        },
    ) catch return;
    defer allocator.free(record);
    _ = log.writeStreamingAll(rt.io, record) catch {};
}

fn callWithAdapterOnce(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    interactive: bool,
    current_reporter: ?repl.ProgressReporter,
    adapter: *types.ProviderAdapter,
    request: types.ModelRequest,
) !types.ModelResponse {
    if (!interactive or !cfg.interactive_streaming) {
        const response = try adapter.send(allocator, request);
        debugLlmLog(allocator, adapter.name, request, &response);
        return response;
    }

    // SSE tool_use reassembly is now implemented in parseSseToolCalls,
    // so Anthropic streaming works with native tool calls. No need to
    // fall back to non-streaming send() anymore.

    // Build chunk callback bridging reporter to provider
    var chunk_cb: ?common.StreamChunkCallback = null;
    var bridge: ChunkBridge = undefined;
    if (current_reporter) |r| {
        if (r.emit_stream_chunk) |emit| {
            bridge = .{ .reporter_ctx = r.ctx, .emit_fn = emit };
            chunk_cb = .{ .ctx = @ptrCast(&bridge), .cb = ChunkBridge.dispatch };
        }
    }

    const stream_text = adapter.streamLive(allocator, request, chunk_cb) catch |err| switch (err) {
        error.MissingApiKey => return err,
        // Do NOT silently fall back to a fresh non-streaming request on
        // transport errors. The fallback doubled the latency of every
        // failed streaming attempt: the user saw the first call hang,
        // then (invisibly) a SECOND call hang, with no indication that
        // anything was happening. Better to surface the streaming error
        // immediately so the agent loop can decide whether to retry.
        else => {
            if (current_reporter) |r| {
                if (r.end_stream) |end_fn| end_fn(r.ctx);
            }
            return err;
        },
    };

    // Signal end of streaming to the reporter
    if (current_reporter) |r| {
        if (r.end_stream) |end_fn| end_fn(r.ctx);
    }

    // If streaming completed but returned no visible text, return the
    // empty response rather than silently issuing a second full request
    // via adapter.send(). The silent fallback produced a user-visible
    // "stuck on thinking for minutes" symptom: the spinner would sit on
    // "thinking" while a fresh non-streaming curl ran to completion,
    // with no indication that a second call was even in progress. Real
    // user report was 6 minutes of silence. If the model legitimately
    // produced no content (all thinking tokens, or content that our
    // extractor missed), the agent loop will notice an empty reply and
    // retry via its own visible logic.
    //
    // Detect truncation from TWO signals so auto-continue kicks in:
    //   1. An explicit `"finish_reason":"length"` in the raw SSE body
    //      (some providers emit it, most don't)
    //   2. A text shape that looks like a mid-sentence cut-off (ends
    //      on a bare letter, unclosed code fence, etc). Moonshot Kimi
    //      is the known offender -- user reported a 44-token stream
    //      ending with "and t" with no finish_reason at all.
    // Without this the agent_runtime truncation_continuations branch
    // never fires for streaming responses and the user sees dangling
    // replies that only recover when they manually prompt "continue".
    const stream_truncated = common.isStreamingResponseTruncated(stream_text) or
        common.looksLikeMidSentenceTruncation(stream_text);

    // Extract tool calls from the SSE stream. Both Anthropic's
    // content_block_start/input_json_delta and OpenAI's delta.tool_calls
    // patterns are handled. Previously tool calls in SSE were dropped
    // entirely, making streaming incompatible with native tool use.
    const sse_tool_calls = common.parseSseToolCalls(allocator, stream_text);
    const reasoning_text = @import("providers/extractors.zig").extractReasoningText(allocator, stream_text) catch try allocator.dupe(u8, "");

    const response = types.ModelResponse{
        .raw = try allocator.dupe(u8, stream_text),
        .text = stream_text,
        .usage_input_tokens = tokenizer.estimateText(adapter.name, request.model, request.system_prompt) + tokenizer.estimateText(adapter.name, request.model, request.prompt),
        .usage_output_tokens = tokenizer.estimateText(adapter.name, stream_text, stream_text),
        .tool_calls_json = sse_tool_calls,
        .truncated = stream_truncated,
        .reasoning_text = reasoning_text,
    };
    debugLlmLog(allocator, adapter.name, request, &response);
    return response;
}

/// Number of consecutive overload (529/503) errors that triggers a configured
/// fallback swap. Exposed so callers (agent_runtime) can word the announcement
/// without importing backoff directly. PRD #534, Phase 7.4.
pub fn maxConsecutiveOverloads() u32 {
    return backoff.MAX_CONSECUTIVE_529;
}

pub fn isRetriableProviderError(err: anyerror) bool {
    return switch (err) {
        // ServerOverloaded (529/503) is transient capacity pressure: retry it
        // at the agent level too. It used to map to HttpTransport (retriable
        // here) before the distinct error was introduced; keep that. PRD #534.
        error.HttpTransport, error.HttpStatusCode, error.ServerOverloaded => true,
        // RateLimited propagates immediately to trigger provider fallback
        // instead of wasting minutes retrying a rate-limited endpoint.
        // RequestTooLarge (413 / prompt-too-long) is deliberately NOT retriable
        // through this gate: retrying without first shrinking the request just
        // re-sends the identical oversized payload. Task 7.5 (reactive
        // compaction) intercepts RequestTooLarge in callWithAdapter BEFORE this
        // gate -- it reduces history and retries the reduced request directly,
        // or surfaces the error when nothing more can be dropped. So it never
        // reaches this switch, and leaving it non-retriable here is correct.
        else => false,
    };
}

pub fn providerAdapterOverrides(cfg: *const config_mod.Config, provider_name: []const u8, fallback: bool) providers.AdapterOverrides {
    var api_key: ?[]const u8 = null;
    var base_url: ?[]const u8 = null;

    // Local/Ollama always uses local_base_url when set, regardless of default provider.
    if (!fallback and (std.mem.eql(u8, provider_name, "local") or std.mem.eql(u8, provider_name, "ollama")) and cfg.local_base_url.len > 0) {
        base_url = cfg.local_base_url;
    } else if (fallback) {
        api_key = blankToNull(cfg.fallback_provider_api_key);
        base_url = blankToNull(cfg.fallback_provider_base_url);
    } else if (std.mem.eql(u8, provider_name, cfg.default_provider)) {
        api_key = blankToNull(cfg.provider_api_key);
        base_url = blankToNull(cfg.provider_base_url);
    } else if (cfg.fallback_provider.len > 0 and std.mem.eql(u8, provider_name, cfg.fallback_provider)) {
        api_key = blankToNull(cfg.fallback_provider_api_key);
        base_url = blankToNull(cfg.fallback_provider_base_url);
    }

    return .{
        .api_key = api_key,
        .base_url = base_url,
        .timeout_ms = cfg.provider_timeout_ms,
        .retry_count = cfg.provider_retry_count,
    };
}

// --- Audit helper ---

pub fn syncAudit(audit: *logger_mod.AuditLogger, cfg: *const config_mod.Config, allocator: std.mem.Allocator, event: []const u8, payload: []const u8) !void {
    try audit.log(event, payload);
    if (cfg.cloud_telemetry_opt_in and cfg.control_plane_url.len > 0) {
        control_plane.syncAuditEvent(allocator, cfg.control_plane_url, cfg.control_plane_token, event, payload) catch |err| {
            std.log.warn("audit sync failed: {s}", .{@errorName(err)});
        };
    }
}

// --- Progress helpers ---

pub fn emitProgress(reporter: ?repl.ProgressReporter, message: []const u8) void {
    if (reporter) |r| {
        r.update(r.ctx, message);
    }
}

pub fn emitProgressFmt(reporter: ?repl.ProgressReporter, comptime fmt: []const u8, args: anytype) void {
    if (reporter == null) return;
    var buf: [192]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    emitProgress(reporter, msg);
}

// --- Strip echoed tool traces ---

pub fn stripEchoedToolTraces(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    var cursor: usize = 0;
    while (cursor < text.len) {
        const search_start = cursor;
        const tool_marker = findToolTraceStart(text, search_start) orelse {
            try out.appendSlice(text[cursor..]);
            break;
        };

        if (tool_marker > cursor) {
            try out.appendSlice(text[cursor..tool_marker]);
        }

        const block_end = findToolTraceEnd(text, tool_marker);
        cursor = block_end;

        while (cursor < text.len and (text[cursor] == '\n' or text[cursor] == '\r' or text[cursor] == ' ')) {
            cursor += 1;
        }
    }

    const result = std.mem.trim(u8, out.items(), " \t\r\n");
    return allocator.dupe(u8, result);
}

fn findToolTraceStart(text: []const u8, from: usize) ?usize {
    var pos = from;
    while (pos < text.len) {
        const line_start = if (pos == 0 or text[pos - 1] == '\n') pos else blk: {
            const nl = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse return null;
            break :blk nl + 1;
        };
        if (line_start >= text.len) return null;

        const remaining = text[line_start..];
        if (std.mem.startsWith(u8, remaining, "tool=") or
            std.mem.startsWith(u8, remaining, "tool: tool="))
        {
            const nl = std.mem.indexOfScalar(u8, remaining, '\n') orelse return null;
            if (nl + 1 < remaining.len) {
                const next_line = remaining[nl + 1 ..];
                if (std.mem.startsWith(u8, next_line, "args=")) {
                    return line_start;
                }
            }
        }
        const nl = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse return null;
        pos = nl + 1;
    }
    return null;
}

fn findToolTraceEnd(text: []const u8, start: usize) usize {
    const trace_fields = [_][]const u8{ "tool=", "tool: tool=", "args=", "state=", "risk=", "output=" };
    var pos = start;
    while (pos < text.len) {
        const line_start = pos;
        const nl = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
        const line = text[line_start..nl];

        var is_trace_line = false;
        for (trace_fields) |field| {
            if (std.mem.startsWith(u8, line, field)) {
                is_trace_line = true;
                break;
            }
        }

        if (!is_trace_line) {
            return line_start;
        }

        pos = if (nl < text.len) nl + 1 else text.len;
    }
    return text.len;
}

// --- MCP helpers ---

pub fn getJsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

pub fn getJsonInteger(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |n| n,
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
}

pub fn getJsonFloat(obj: std.json.ObjectMap, key: []const u8) ?f32 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |n| @as(f32, @floatFromInt(n)),
        .number_string => |text| std.fmt.parseFloat(f32, text) catch null,
        else => null,
    };
}

pub fn buildSamplingPrompt(allocator: std.mem.Allocator, params: std.json.ObjectMap) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    const include_context = getJsonString(params, "includeContext") orelse "none";
    if (!std.mem.eql(u8, include_context, "none")) {
        try out.writer().print("Context requested by MCP server: {s}\n\n", .{include_context});
    }

    const messages_val = params.get("messages") orelse return allocator.dupe(u8, "");
    if (messages_val != .array) return allocator.dupe(u8, "");

    for (messages_val.array.items, 0..) |message, idx| {
        if (message != .object) continue;
        const role = getJsonString(message.object, "role") orelse "user";
        const content_val = message.object.get("content") orelse continue;
        const content = try flattenSamplingContent(allocator, content_val);
        defer allocator.free(content);
        if (idx > 0) try out.writer().writeAll("\n\n");
        try out.writer().print("[{s}]\n{s}", .{ role, content });
    }

    return out.toOwnedSlice();
}

pub fn flattenSamplingContent(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return switch (value) {
        .string => |text| allocator.dupe(u8, text),
        .array => |items| blk: {
            var out = std_io.StringBuilder.init(allocator);
            defer out.deinit();
            for (items.items, 0..) |item, idx| {
                const part = flattenSamplingContent(allocator, item) catch continue;
                defer allocator.free(part);
                if (idx > 0 and out.items().len > 0) try out.append('\n');
                try out.appendSlice(part);
            }
            break :blk out.toOwnedSlice();
        },
        .object => |obj| blk: {
            const kind = getJsonString(obj, "type") orelse "";
            if (std.mem.eql(u8, kind, "text")) {
                if (getJsonString(obj, "text")) |text| break :blk allocator.dupe(u8, text);
            }
            if (std.mem.eql(u8, kind, "image")) {
                break :blk std.fmt.allocPrint(allocator, "<image:{s}>", .{getJsonString(obj, "mimeType") orelse "application/octet-stream"});
            }
            if (std.mem.eql(u8, kind, "audio")) {
                break :blk std.fmt.allocPrint(allocator, "<audio:{s}>", .{getJsonString(obj, "mimeType") orelse "application/octet-stream"});
            }
            var buf = std_io.StringBuilder.init(allocator);
            defer buf.deinit();
            try buf.writer().print("{f}", .{std.json.fmt(std.json.Value{ .object = obj }, .{})});
            break :blk buf.toOwnedSlice();
        },
        else => allocator.dupe(u8, ""),
    };
}

pub fn mcpBridgeListRoots(cwd: []const u8, allocator: std.mem.Allocator) ![]mcp_client.RootInfo {
    const root_path = allocator.dupe(u8, cwd) catch try allocator.dupe(u8, cwd);
    defer allocator.free(root_path);
    const uri = try pathToFileUriAlloc(allocator, root_path);
    defer allocator.free(uri);
    const roots = try allocator.alloc(mcp_client.RootInfo, 1);
    roots[0] = .{ .uri = try allocator.dupe(u8, uri), .name = try allocator.dupe(u8, "workspace") };
    return roots;
}

pub fn pathToFileUriAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const component: std.Uri.Component = .{ .raw = path };
    const encoded_path = try std.fmt.allocPrint(allocator, "{f}", .{std.fmt.alt(component, .formatPath)});
    defer allocator.free(encoded_path);
    return std.fmt.allocPrint(allocator, "file://{s}", .{encoded_path});
}

pub fn buildElicitationActionJson(allocator: std.mem.Allocator, raw_action: []const u8, maybe_content_json: ?[]const u8) ![]u8 {
    const action = blk: {
        if (std.ascii.eqlIgnoreCase(raw_action, "accept")) break :blk "accept";
        if (std.ascii.eqlIgnoreCase(raw_action, "decline")) break :blk "decline";
        break :blk "cancel";
    };

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try out.writer().writeAll("{\"action\":");
    try out.writer().print("{f}", .{std.json.fmt(action, .{})});
    if (maybe_content_json) |content_json| {
        if (std.mem.eql(u8, action, "accept")) {
            try out.writer().writeAll(",\"content\":");
            try out.writer().writeAll(content_json);
        }
    }
    try out.writer().writeByte('}');
    return out.toOwnedSlice();
}

pub fn buildElicitationQuestion(allocator: std.mem.Allocator, message: []const u8, title: []const u8, description: []const u8, hint: []const u8) ![]u8 {
    if (description.len > 0 and hint.len > 0) {
        return std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}\n{s}", .{ message, title, description, hint });
    }
    if (description.len > 0) {
        return std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}", .{ message, title, description });
    }
    if (hint.len > 0) {
        return std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}", .{ message, title, hint });
    }
    return std.fmt.allocPrint(allocator, "{s}\n{s}", .{ message, title });
}

// --- MCP request handling ---

pub const McpContext = struct {
    allocator: std.mem.Allocator,
    interactive: bool,
    ask_user_fn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, question: []const u8, choices: []const []const u8) anyerror![]u8,
    ask_user_ctx: ?*anyopaque,
    active_model: []const u8,
    reserved_output_tokens: usize,
    callModelFn: *const fn (opaque_self: *anyopaque, request: @import("core/types.zig").ModelRequest) anyerror!@import("core/types.zig").ModelResponse,
    opaque_self: *anyopaque,
    /// URL-mode elicitation tracker (mcp-07). Optional so callers that do not
    /// own a tracker (tests, headless paths) can pass null.
    elicitation_tracker: ?*ElicitationTracker = null,
};

pub fn handleMcpSamplingRequest(ctx: McpContext, params_json: []const u8) ![]u8 {
    const allocator = ctx.allocator;
    const types_mod = @import("core/types.zig");

    if (ctx.interactive and ctx.ask_user_fn != null and ctx.ask_user_ctx != null) {
        const approval = try ctx.ask_user_fn.?(ctx.ask_user_ctx.?, allocator, "Allow connected MCP server to request model sampling?", &.{ "allow", "deny" });
        defer allocator.free(approval);
        if (!std.ascii.eqlIgnoreCase(approval, "allow")) return error.AccessDenied;
    }

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, params_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRequest;

    const system_prompt = getJsonString(parsed.value.object, "systemPrompt") orelse "";
    const requested_max_tokens = getJsonInteger(parsed.value.object, "maxTokens") orelse @as(i64, @intCast(ctx.reserved_output_tokens));
    const max_output_tokens: usize = std.math.cast(usize, @max(@as(i64, 1), requested_max_tokens)) orelse ctx.reserved_output_tokens;
    const temperature = getJsonFloat(parsed.value.object, "temperature") orelse 0.2;
    const prompt = try buildSamplingPrompt(allocator, parsed.value.object);
    defer allocator.free(prompt);

    const request = types_mod.ModelRequest{
        .model = ctx.active_model,
        .system_prompt = system_prompt,
        .prompt = prompt,
        .max_output_tokens = max_output_tokens,
        .temperature = temperature,
        .tool_schemas = &.{},
    };

    const response = try ctx.callModelFn(ctx.opaque_self, request);
    defer allocator.free(response.raw);
    defer allocator.free(response.text);
    defer if (response.tool_calls_json.len > 0) allocator.free(response.tool_calls_json);

    if (ctx.interactive and ctx.ask_user_fn != null and ctx.ask_user_ctx != null) {
        const preview = if (response.text.len > 400) response.text[0..400] else response.text;
        const question = try std.fmt.allocPrint(allocator, "Allow MCP server to receive this sampled response?\n{s}", .{preview});
        defer allocator.free(question);
        const approval = try ctx.ask_user_fn.?(ctx.ask_user_ctx.?, allocator, question, &.{ "allow", "deny" });
        defer allocator.free(approval);
        if (!std.ascii.eqlIgnoreCase(approval, "allow")) return error.AccessDenied;
    }

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try out.writer().writeAll("{\"model\":");
    try out.writer().print("{f}", .{std.json.fmt(ctx.active_model, .{})});
    try out.writer().writeAll(",\"stopReason\":");
    try out.writer().print("{f}", .{std.json.fmt(if (response.truncated) "maxTokens" else "endTurn", .{})});
    try out.writer().writeAll(",\"role\":\"assistant\",\"content\":{\"type\":\"text\",\"text\":");
    try out.writer().print("{f}", .{std.json.fmt(response.text, .{})});
    try out.writer().writeAll("}}");
    return out.toOwnedSlice();
}

pub fn handleMcpElicitationRequest(ctx: McpContext, params_json: []const u8) ![]u8 {
    const allocator = ctx.allocator;
    if (!ctx.interactive or ctx.ask_user_fn == null or ctx.ask_user_ctx == null) return error.AccessDenied;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, params_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRequest;

    const mode = getJsonString(parsed.value.object, "mode") orelse "form";
    const message = getJsonString(parsed.value.object, "message") orelse "This MCP server needs more information.";

    if (std.mem.eql(u8, mode, "url")) {
        const url = getJsonString(parsed.value.object, "url") orelse return error.InvalidRequest;
        // URL elicitations may complete out-of-band via a
        // `notifications/elicitation/complete`. Record the id so the
        // completion handler can match it (mcp-07).
        if (ctx.elicitation_tracker) |tracker| {
            if (getJsonString(parsed.value.object, "elicitationId")) |eid| tracker.note(eid) catch {};
        }
        const question = try std.fmt.allocPrint(allocator, "{s}\nTarget URL: {s}", .{ message, url });
        defer allocator.free(question);
        const answer = try ctx.ask_user_fn.?(ctx.ask_user_ctx.?, allocator, question, &.{ "accept", "decline", "cancel" });
        defer allocator.free(answer);
        return buildElicitationActionJson(allocator, answer, null);
    }

    const schema_val = parsed.value.object.get("requestedSchema") orelse return buildElicitationActionJson(allocator, "accept", "{}");
    if (schema_val != .object) return error.InvalidRequest;
    const content_json = try collectElicitationFormResponse(
        .{ .allocator = allocator, .ask_user_fn = ctx.ask_user_fn.?, .ask_user_ctx = ctx.ask_user_ctx.? },
        message,
        schema_val.object,
    );
    defer allocator.free(content_json);
    return buildElicitationActionJson(allocator, "accept", content_json);
}

// --- Elicitation form handling ---

pub const ElicitationContext = struct {
    allocator: std.mem.Allocator,
    ask_user_fn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, question: []const u8, choices: []const []const u8) anyerror![]u8,
    ask_user_ctx: *anyopaque,
};

pub fn collectElicitationFormResponse(ectx: ElicitationContext, message: []const u8, schema: std.json.ObjectMap) ![]u8 {
    const allocator = ectx.allocator;
    const properties_val = schema.get("properties") orelse return allocator.dupe(u8, "{}");
    if (properties_val != .object) return allocator.dupe(u8, "{}");

    var required_names = std.StringHashMap(void).init(allocator);
    defer required_names.deinit();
    if (schema.get("required")) |required_val| {
        if (required_val == .array) {
            for (required_val.array.items) |item| {
                if (item == .string) try required_names.put(item.string, {});
            }
        }
    }

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try out.writer().writeByte('{');

    var iterator = properties_val.object.iterator();
    var first = true;
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const key = entry.key_ptr.*;
        const property = entry.value_ptr.object;
        const required = required_names.contains(key);
        const encoded = try promptForElicitationField(ectx, message, key, property, required);
        defer if (encoded) |value| allocator.free(value);
        if (encoded == null) continue;
        if (!first) try out.writer().writeByte(',');
        first = false;
        try out.writer().print("{f}", .{std.json.fmt(key, .{})});
        try out.writer().writeByte(':');
        try out.writer().writeAll(encoded.?);
    }

    try out.writer().writeByte('}');
    return out.toOwnedSlice();
}

pub fn promptForElicitationField(ectx: ElicitationContext, message: []const u8, key: []const u8, property: std.json.ObjectMap, required: bool) !?[]u8 {
    const allocator = ectx.allocator;
    const title = getJsonString(property, "title") orelse key;
    const description = getJsonString(property, "description") orelse "";
    const schema_type = getJsonString(property, "type") orelse "string";

    if (property.get("enum")) |enum_val| {
        if (enum_val == .array) {
            const choice = try askEnumField(ectx, message, title, description, enum_val.array.items, required);
            defer if (choice) |value| allocator.free(value);
            if (choice == null) return null;
            return @as(?[]u8, try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(choice.?, .{})}));
        }
    }

    if (property.get("oneOf")) |one_of_val| {
        if (one_of_val == .array) {
            const choice = try askOneOfField(ectx, message, title, description, one_of_val.array.items, required);
            defer if (choice) |value| allocator.free(value);
            if (choice == null) return null;
            return @as(?[]u8, choice.?);
        }
    }

    if (std.mem.eql(u8, schema_type, "boolean")) {
        const default_value = if (property.get("default")) |default_val|
            switch (default_val) {
                .bool => |value| value,
                else => false,
            }
        else
            false;
        const question = try buildElicitationQuestion(allocator, message, title, description, if (default_value) "default=true" else "default=false");
        defer allocator.free(question);
        const choices = if (required) &[_][]const u8{ "true", "false" } else &[_][]const u8{ "true", "false", "skip" };
        const answer = try ectx.ask_user_fn(ectx.ask_user_ctx, allocator, question, choices);
        defer allocator.free(answer);
        if (!required and std.ascii.eqlIgnoreCase(answer, "skip")) return null;
        return @as(?[]u8, try allocator.dupe(u8, if (std.ascii.eqlIgnoreCase(answer, "true")) "true" else "false"));
    }

    if (std.mem.eql(u8, schema_type, "integer") or std.mem.eql(u8, schema_type, "number")) {
        const guidance = if (std.mem.eql(u8, schema_type, "integer")) "enter an integer" else "enter a number";
        var attempt: u8 = 0;
        while (attempt < 3) : (attempt += 1) {
            const question = try buildElicitationQuestion(allocator, message, title, description, guidance);
            defer allocator.free(question);
            const answer = try ectx.ask_user_fn(ectx.ask_user_ctx, allocator, question, &.{});
            defer allocator.free(answer);
            const trimmed = std.mem.trim(u8, answer, " \t\r\n");
            if (trimmed.len == 0) {
                if (!required) return null;
                continue;
            }
            if (std.mem.eql(u8, schema_type, "integer")) {
                _ = std.fmt.parseInt(i64, trimmed, 10) catch continue;
            } else {
                _ = std.fmt.parseFloat(f64, trimmed) catch continue;
            }
            return @as(?[]u8, try allocator.dupe(u8, trimmed));
        }
        return error.InvalidArgument;
    }

    if (std.mem.eql(u8, schema_type, "array")) {
        if (property.get("items")) |items_val| {
            if (items_val == .object) {
                // Multiselect: when the array items carry an `enum` (or
                // `anyOf` of consts), every comma-separated answer value must
                // be one of those enum members. The previous implementation
                // computed `choices_json` and then discarded it, accepting any
                // free-text -- this validates each value against the enum and
                // retries up to 3 times, matching the reference checkbox UI's
                // restrict-to-enum semantics (mcp-07).
                const enum_items: []const std.json.Value = if (items_val.object.get("enum")) |enum_values|
                    (if (enum_values == .array) enum_values.array.items else &.{})
                else if (items_val.object.get("anyOf")) |any_of|
                    (if (any_of == .array) any_of.array.items else &.{})
                else
                    &.{};

                var attempt: u8 = 0;
                while (attempt < 3) : (attempt += 1) {
                    const hint = if (enum_items.len > 0) "comma-separated subset of allowed values" else "comma-separated values";
                    const question = try buildElicitationQuestion(allocator, message, title, description, hint);
                    defer allocator.free(question);
                    const answer = try ectx.ask_user_fn(ectx.ask_user_ctx, allocator, question, &.{});
                    defer allocator.free(answer);
                    const trimmed = std.mem.trim(u8, answer, " \t\r\n");
                    if (trimmed.len == 0) {
                        if (required) {
                            if (attempt + 1 < 3) continue;
                            return error.InvalidArgument;
                        }
                        return null;
                    }

                    var arr_out = std_io.StringBuilder.init(allocator);
                    defer arr_out.deinit();
                    try arr_out.writer().writeByte('[');
                    var parts = std.mem.splitScalar(u8, trimmed, ',');
                    var arr_first = true;
                    var invalid = false;
                    while (parts.next()) |part_raw| {
                        const part = std.mem.trim(u8, part_raw, " \t\r\n");
                        if (part.len == 0) continue;
                        if (enum_items.len > 0 and !enumContainsString(enum_items, part)) {
                            invalid = true;
                            break;
                        }
                        if (!arr_first) try arr_out.writer().writeByte(',');
                        arr_first = false;
                        try arr_out.writer().print("{f}", .{std.json.fmt(part, .{})});
                    }
                    if (invalid) continue;
                    try arr_out.writer().writeByte(']');
                    return @as(?[]u8, try arr_out.toOwnedSlice());
                }
                return error.InvalidArgument;
            }
        }
    }

    // Datetime: a string field declaring `format: "date-time"` must parse as
    // ISO-8601; reject and retry up to 3 times. Mirrors the reference's
    // datetime helper (mcp-07).
    if (std.mem.eql(u8, schema_type, "string")) {
        const format = getJsonString(property, "format") orelse "";
        if (std.mem.eql(u8, format, "date-time")) {
            var attempt: u8 = 0;
            while (attempt < 3) : (attempt += 1) {
                const question = try buildElicitationQuestion(allocator, message, title, description, "ISO-8601 date-time, e.g. 2026-05-29T12:00:00Z");
                defer allocator.free(question);
                const answer = try ectx.ask_user_fn(ectx.ask_user_ctx, allocator, question, &.{});
                defer allocator.free(answer);
                const trimmed = std.mem.trim(u8, answer, " \t\r\n");
                if (trimmed.len == 0) {
                    if (!required) return null;
                    continue;
                }
                if (!isIso8601DateTime(trimmed)) continue;
                return @as(?[]u8, try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(trimmed, .{})}));
            }
            return error.InvalidArgument;
        }
    }

    const default_hint = if (property.get("default")) |default_val|
        switch (default_val) {
            .string => |text| text,
            else => "",
        }
    else
        "";
    var attempt: u8 = 0;
    while (attempt < 3) : (attempt += 1) {
        const question = try buildElicitationQuestion(allocator, message, title, description, default_hint);
        defer allocator.free(question);
        const answer = try ectx.ask_user_fn(ectx.ask_user_ctx, allocator, question, &.{});
        defer allocator.free(answer);
        const trimmed = std.mem.trim(u8, answer, " \t\r\n");
        if (trimmed.len == 0) {
            if (default_hint.len > 0) return @as(?[]u8, try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(default_hint, .{})}));
            if (!required) return null;
            continue;
        }
        return @as(?[]u8, try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(trimmed, .{})}));
    }
    return error.InvalidArgument;
}

fn askEnumField(ectx: ElicitationContext, message: []const u8, title: []const u8, description: []const u8, items: []const std.json.Value, required: bool) !?[]u8 {
    const allocator = ectx.allocator;
    var choices = std.array_list.Managed([]const u8).init(allocator);
    defer choices.deinit();
    for (items) |item| {
        if (item == .string) try choices.append(item.string);
    }
    if (!required) try choices.append("skip");
    const question = try buildElicitationQuestion(allocator, message, title, description, "");
    defer allocator.free(question);
    const answer = try ectx.ask_user_fn(ectx.ask_user_ctx, allocator, question, choices.items);
    defer allocator.free(answer);
    if (!required and std.ascii.eqlIgnoreCase(answer, "skip")) return null;
    return @as(?[]u8, try allocator.dupe(u8, answer));
}

fn askOneOfField(ectx: ElicitationContext, message: []const u8, title: []const u8, description: []const u8, items: []const std.json.Value, required: bool) !?[]u8 {
    const allocator = ectx.allocator;
    var labels = std.array_list.Managed([]const u8).init(allocator);
    defer labels.deinit();
    var encoded_values = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (encoded_values.items) |value| allocator.free(value);
        encoded_values.deinit();
    }

    for (items) |item| {
        if (item != .object) continue;
        const label = getJsonString(item.object, "title") orelse getJsonString(item.object, "const") orelse continue;
        try labels.append(label);
        const encoded = if (item.object.get("const")) |const_val|
            try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(const_val, .{})})
        else
            try allocator.dupe(u8, "null");
        try encoded_values.append(encoded);
    }
    if (!required) try labels.append("skip");

    const question = try buildElicitationQuestion(allocator, message, title, description, "");
    defer allocator.free(question);
    const answer = try ectx.ask_user_fn(ectx.ask_user_ctx, allocator, question, labels.items);
    defer allocator.free(answer);
    if (!required and std.ascii.eqlIgnoreCase(answer, "skip")) return null;

    for (labels.items, 0..) |label, idx| {
        if (std.mem.eql(u8, label, answer) and idx < encoded_values.items.len) {
            return @as(?[]u8, try allocator.dupe(u8, encoded_values.items[idx]));
        }
    }
    return error.InvalidArgument;
}

/// True when `items` (a JSON array of enum members) contains a string member
/// byte-equal to `needle`. Non-string members never match.
fn enumContainsString(items: []const std.json.Value, needle: []const u8) bool {
    for (items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, needle)) return true;
    }
    return false;
}

/// Minimal ISO-8601 date-time validator: `YYYY-MM-DDThh:mm:ss` with an
/// optional fractional second (`.sss`) and an optional zone (`Z` or
/// `+hh:mm` / `-hh:mm`). zcode has no full date parser, so this checks shape
/// and field ranges rather than constructing a calendar value. Good enough to
/// reject obvious garbage (`not-a-date`) and accept canonical timestamps like
/// `2026-05-29T12:00:00Z`.
pub fn isIso8601DateTime(value: []const u8) bool {
    // Minimum: 2026-05-29T12:00:00 = 19 chars.
    if (value.len < 19) return false;
    if (!(value[4] == '-' and value[7] == '-')) return false;
    if (!(value[10] == 'T' or value[10] == 't' or value[10] == ' ')) return false;
    if (!(value[13] == ':' and value[16] == ':')) return false;

    const year = parseFixedDigits(value[0..4]) orelse return false;
    const month = parseFixedDigits(value[5..7]) orelse return false;
    const day = parseFixedDigits(value[8..10]) orelse return false;
    const hour = parseFixedDigits(value[11..13]) orelse return false;
    const minute = parseFixedDigits(value[14..16]) orelse return false;
    const second = parseFixedDigits(value[17..19]) orelse return false;
    if (year < 1 or month < 1 or month > 12 or day < 1 or day > 31) return false;
    if (hour > 23 or minute > 59 or second > 60) return false; // 60 allows a leap second

    var idx: usize = 19;
    // Optional fractional seconds: a dot followed by 1+ digits.
    if (idx < value.len and value[idx] == '.') {
        idx += 1;
        const frac_start = idx;
        while (idx < value.len and std.ascii.isDigit(value[idx])) idx += 1;
        if (idx == frac_start) return false; // dot with no digits
    }

    // Optional timezone: end-of-string (naive), 'Z', or +/-hh:mm.
    if (idx == value.len) return true;
    if (value[idx] == 'Z' or value[idx] == 'z') return idx + 1 == value.len;
    if (value[idx] == '+' or value[idx] == '-') {
        // Need exactly "+hh:mm" or "+hhmm".
        const rest = value[idx + 1 ..];
        if (rest.len == 5 and rest[2] == ':') {
            const tz_h = parseFixedDigits(rest[0..2]) orelse return false;
            const tz_m = parseFixedDigits(rest[3..5]) orelse return false;
            return tz_h <= 23 and tz_m <= 59;
        }
        if (rest.len == 4) {
            const tz_h = parseFixedDigits(rest[0..2]) orelse return false;
            const tz_m = parseFixedDigits(rest[2..4]) orelse return false;
            return tz_h <= 23 and tz_m <= 59;
        }
        return false;
    }
    return false;
}

fn parseFixedDigits(slice: []const u8) ?u32 {
    var out: u32 = 0;
    for (slice) |c| {
        if (!std.ascii.isDigit(c)) return null;
        out = out * 10 + (c - '0');
    }
    return out;
}

// --- Elicitation completion notifications (mcp-07) ---

/// Tracks URL-mode elicitations that are awaiting an out-of-band
/// `notifications/elicitation/complete`. zcode's elicitation bridge is
/// synchronous, so this is a thin id-set rather than the reference's full
/// queued-dialog state machine: `note` records an id when a URL elicitation is
/// created, and `markComplete` clears it when the matching completion
/// notification arrives. Unknown ids are ignored without error, matching
/// `elicitationHandler.ts:173-207`.
pub const ElicitationTracker = struct {
    pending: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) ElicitationTracker {
        return .{ .pending = std.StringHashMap(void).init(allocator) };
    }

    pub fn deinit(self: *ElicitationTracker) void {
        var it = self.pending.keyIterator();
        while (it.next()) |key| self.pending.allocator.free(key.*);
        self.pending.deinit();
    }

    /// Record `id` as a pending URL elicitation. Idempotent: a repeated id
    /// does not allocate a second key.
    pub fn note(self: *ElicitationTracker, id: []const u8) !void {
        if (id.len == 0) return;
        if (self.pending.contains(id)) return;
        const key = try self.pending.allocator.dupe(u8, id);
        errdefer self.pending.allocator.free(key);
        try self.pending.put(key, {});
    }

    pub fn isPending(self: *const ElicitationTracker, id: []const u8) bool {
        return self.pending.contains(id);
    }

    /// Mark the elicitation `id` complete. Returns true when `id` matched a
    /// pending elicitation (and was cleared), false when the id was unknown
    /// (ignored without error, per the reference).
    pub fn markComplete(self: *ElicitationTracker, id: []const u8) bool {
        const entry = self.pending.fetchRemove(id) orelse return false;
        self.pending.allocator.free(entry.key);
        return true;
    }
};

/// Extract the `elicitationId` from a `notifications/elicitation/complete`
/// params payload. Returns a slice into `parsed` (the caller owns `parsed`);
/// null when the field is absent or not a string. The reference schema names
/// the field `elicitationId` (elicitationHandler.ts:173-207).
pub fn parseElicitationCompleteId(params: std.json.ObjectMap) ?[]const u8 {
    return getJsonString(params, "elicitationId");
}

// --- Session management ---

const session_bundles = @import("session/bundles.zig");
const agents_mod = @import("core/agents.zig");
const permission_rules_mod = @import("core/permission_rules.zig");

pub fn forkSessionImpl(
    allocator: std.mem.Allocator,
    store: *session_store.Store,
    session_id: *[]u8,
    history: *const History,
    snapshot: *@import("core/types.zig").SessionSnapshot,
    label: ?[]const u8,
) ![]u8 {
    const conversation_summary = blk: {
        var loaded = store.load(session_id.*) catch |err| switch (err) {
            error.FileNotFound => break :blk try allocator.dupe(u8, ""),
            else => return err,
        };
        defer loaded.deinit(allocator);
        break :blk try allocator.dupe(u8, loaded.conversation_summary);
    };
    defer allocator.free(conversation_summary);

    const forked = try session_bundles.forkSessionFromState(
        allocator,
        store,
        session_id.*,
        history.view(),
        snapshot,
        conversation_summary,
        label,
    );
    errdefer allocator.free(forked.session_id);
    defer {
        allocator.free(forked.source_session_id);
        allocator.free(forked.label);
    }

    const message = try std.fmt.allocPrint(
        allocator,
        "forked session {s} -> {s} label={s}",
        .{ forked.source_session_id, forked.session_id, forked.label },
    );

    allocator.free(session_id.*);
    session_id.* = forked.session_id;
    return message;
}

pub fn restoreCheckpointImpl(
    allocator: std.mem.Allocator,
    store: *session_store.Store,
    cwd: []const u8,
    session_id: *[]u8,
    history: *History,
    snapshot: *@import("core/types.zig").SessionSnapshot,
    checkpoint_id: ?[]const u8,
) ![]u8 {
    var restored = try session_bundles.undoToCheckpoint(
        allocator,
        store,
        cwd,
        session_id.*,
        checkpoint_id,
    );
    defer restored.deinit(allocator);

    var loaded = try store.load(restored.session_id);
    defer loaded.deinit(allocator);

    // Same stage-then-commit pattern as /resume in repl_commands.zig:
    // build every new allocation into scratch locals so any OOM
    // during the restore leaves the runtime's snapshot / history /
    // session_id exactly as they were. Previously the function freed
    // history content and snapshot BEFORE cloning the new state,
    // leaving partial state on OOM: new id dangling, history
    // truncated, snapshot freed.

    const new_id = try allocator.dupe(u8, loaded.id);
    errdefer allocator.free(new_id);

    const new_snapshot = try cloneSnapshot(allocator, &loaded.snapshot);
    var snapshot_committed = false;
    errdefer if (!snapshot_committed) freeSnapshot(allocator, new_snapshot);

    // Stage the new history first. replaceWith is fallible but atomic:
    // on OOM the existing history is left intact and the new_id /
    // new_snapshot errdefers above unwind cleanly. The session id and
    // snapshot swaps that follow are infallible.
    try history.replaceWith(loaded.history);

    // ---- Commit: no more fallible operations from here on. ----
    allocator.free(session_id.*);
    session_id.* = new_id;

    freeSnapshot(allocator, snapshot.*);
    snapshot.* = new_snapshot;
    snapshot_committed = true;

    if (restored.backup_checkpoint_id) |backup_id| {
        return std.fmt.allocPrint(
            allocator,
            "restored checkpoint {s} -> session {s} backup={s}",
            .{ restored.checkpoint_id, restored.session_id, backup_id },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "restored checkpoint {s} -> session {s}",
        .{ restored.checkpoint_id, restored.session_id },
    );
}

pub fn activateAgentByNameImpl(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    raw_name: []const u8,
    active_agent: *?agents_mod.AgentSpec,
    active_provider: *[]u8,
    active_model: *[]u8,
    agent_previous_provider: *?[]u8,
    agent_previous_model: *?[]u8,
    permission_rules: ?*const permission_rules_mod.Store,
) ![]u8 {
    const requested = std.mem.trim(u8, raw_name, " \t\r\n");
    if (requested.len == 0) return allocator.dupe(u8, "usage: /agent <name>|none|current");
    if (std.mem.eql(u8, requested, "none") or std.mem.eql(u8, requested, "off") or std.mem.eql(u8, requested, "clear")) {
        return clearActiveAgentImpl(allocator, active_agent, active_provider, active_model, agent_previous_provider, agent_previous_model);
    }

    // Permission gate: a deny rule `Agent(<type>)` blocks the agent from being
    // activated or spawned (permissions-15). Exact-match on the agent type.
    if (permission_rules) |rules| {
        if (rules.isAgentDenied(cwd, requested)) {
            return std.fmt.allocPrint(allocator, "agent type '{s}' is denied by a permission rule", .{requested});
        }
    }

    var agent = (try agents_mod.findByName(allocator, cwd, requested)) orelse {
        return std.fmt.allocPrint(allocator, "agent not found: {s}", .{requested});
    };
    errdefer agent.deinit(allocator);

    clearActiveAgentInternalImpl(allocator, active_agent, active_provider, active_model, agent_previous_provider, agent_previous_model);
    if (agent.model.len > 0) {
        captureCurrentModelForAgentImpl(allocator, active_provider.*, active_model.*, agent_previous_provider, agent_previous_model) catch |err| {
            agent.deinit(allocator);
            return err;
        };
        applyModelTokenImpl(allocator, agent.model, active_provider, active_model) catch |err| {
            agent.deinit(allocator);
            return err;
        };
    }

    const model_display = if (agent.model.len > 0) agent.model else "<inherit>";
    const mode_display = agents_mod.modeName(agent.mode);
    active_agent.* = agent;
    return std.fmt.allocPrint(allocator, "activated agent {s} mode={s} model={s}", .{ active_agent.*.?.name, mode_display, model_display });
}

pub fn clearActiveAgentImpl(
    allocator: std.mem.Allocator,
    active_agent: *?agents_mod.AgentSpec,
    active_provider: *[]u8,
    active_model: *[]u8,
    agent_previous_provider: *?[]u8,
    agent_previous_model: *?[]u8,
) ![]u8 {
    if (active_agent.* == null) return allocator.dupe(u8, "no active agent");
    const name = active_agent.*.?.name;
    const msg = try std.fmt.allocPrint(allocator, "cleared agent {s}", .{name});
    clearActiveAgentInternalImpl(allocator, active_agent, active_provider, active_model, agent_previous_provider, agent_previous_model);
    return msg;
}

pub fn clearActiveAgentInternalImpl(
    allocator: std.mem.Allocator,
    active_agent: *?agents_mod.AgentSpec,
    active_provider: *[]u8,
    active_model: *[]u8,
    agent_previous_provider: *?[]u8,
    agent_previous_model: *?[]u8,
) void {
    if (active_agent.*) |*agent| {
        agent.deinit(allocator);
        active_agent.* = null;
    }

    if (agent_previous_provider.*) |prev| {
        allocator.free(active_provider.*);
        active_provider.* = prev;
        agent_previous_provider.* = null;
    }
    if (agent_previous_model.*) |prev| {
        allocator.free(active_model.*);
        active_model.* = prev;
        agent_previous_model.* = null;
    }
}

fn captureCurrentModelForAgentImpl(
    allocator: std.mem.Allocator,
    active_provider: []const u8,
    active_model: []const u8,
    agent_previous_provider: *?[]u8,
    agent_previous_model: *?[]u8,
) !void {
    if (agent_previous_provider.* == null) {
        agent_previous_provider.* = try allocator.dupe(u8, active_provider);
    }
    if (agent_previous_model.* == null) {
        agent_previous_model.* = try allocator.dupe(u8, active_model);
    }
}

pub fn applyModelTokenImpl(
    allocator: std.mem.Allocator,
    raw: []const u8,
    active_provider: *[]u8,
    active_model: *[]u8,
) !void {
    const token = std.mem.trim(u8, raw, " \t\r\n");
    if (token.len == 0) return;

    if (std.mem.indexOfScalar(u8, token, '/')) |slash_idx| {
        const maybe_provider = std.mem.trim(u8, token[0..slash_idx], " \t");
        const maybe_model = std.mem.trim(u8, token[slash_idx + 1 ..], " \t");
        if (maybe_provider.len > 0 and maybe_model.len > 0 and isKnownProviderName(maybe_provider)) {
            const next_provider = try allocator.dupe(u8, maybe_provider);
            const next_model = try allocator.dupe(u8, maybe_model);
            allocator.free(active_provider.*);
            allocator.free(active_model.*);
            active_provider.* = next_provider;
            active_model.* = next_model;
            return;
        }
    }

    const next_model = try allocator.dupe(u8, token);
    allocator.free(active_model.*);
    active_model.* = next_model;
}

// --- Utility helpers ---

pub fn isShortFollowUp(prompt: []const u8) bool {
    const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 80) return false;
    var lower_buf: [96]u8 = undefined;
    const len = @min(trimmed.len, lower_buf.len);
    for (0..len) |i| {
        lower_buf[i] = std.ascii.toLower(trimmed[i]);
    }
    const lower = lower_buf[0..len];
    if (std.mem.indexOf(u8, lower, "keep going") != null) return true;
    if (std.mem.indexOf(u8, lower, "go on") != null) return true;
    if (looksLikeShortOptionSelection(lower, "first one")) return true;
    if (looksLikeShortOptionSelection(lower, "1st one")) return true;
    if (looksLikeShortOptionSelection(lower, "option 1")) return true;
    if (looksLikeShortOptionSelection(lower, "second one")) return true;
    if (looksLikeShortOptionSelection(lower, "2nd one")) return true;
    if (looksLikeShortOptionSelection(lower, "option 2")) return true;
    const follow_ups = [_][]const u8{
        "yes",      "no",       "y",       "n",
        "ok",       "okay",     "sure",    "continue",
        "approve",  "deny",     "cancel",  "confirm",
        "go ahead", "do it",    "proceed", "accepted",
        "approved", "rejected", "skip",    "done",
        "next",     "stop",     "agree",   "disagree",
        "yep",      "nope",     "yeah",    "nah",
        "right",    "correct",  "1",       "2",
        "3",        "4",        "true",    "false",
    };
    for (follow_ups) |f| {
        if (std.mem.eql(u8, lower, f)) return true;
    }
    return false;
}

fn looksLikeShortOptionSelection(lower: []const u8, marker: []const u8) bool {
    if (std.mem.indexOf(u8, lower, marker) == null) return false;
    if (std.mem.eql(u8, lower, marker)) return true;
    const prefixes = [_][]const u8{
        "yes",
        "y ",
        "ok",
        "okay",
        "sure",
        "do ",
        "do the ",
        "lets do ",
        "let's do ",
        "go with ",
        "choose ",
        "pick ",
        "start ",
        "implement ",
    };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, lower, prefix)) return true;
    }
    return false;
}

pub fn isKnownProviderName(name: []const u8) bool {
    return std.mem.eql(u8, name, "openai") or
        std.mem.eql(u8, name, "openai-compatible") or
        std.mem.eql(u8, name, "deepseek") or
        std.mem.eql(u8, name, "anthropic") or
        std.mem.eql(u8, name, "gemini") or
        std.mem.eql(u8, name, "local") or
        std.mem.eql(u8, name, "groq") or
        std.mem.eql(u8, name, "openrouter") or
        std.mem.eql(u8, name, "azure") or
        std.mem.eql(u8, name, "mock");
}

pub fn blankToNull(value: []const u8) ?[]const u8 {
    if (value.len == 0) return null;
    return value;
}

pub fn displayValueOr(value: []const u8, fallback: []const u8) []const u8 {
    if (value.len == 0) return fallback;
    return value;
}

const testing = std.testing;
test "allocEmptySnapshot zeroed" {
    const alloc = testing.allocator;
    const s = try allocEmptySnapshot(alloc);
    defer freeSnapshot(alloc, s);
    try testing.expectEqual(@as(usize, 0), s.facts.len);
}
test "blankToNull" {
    try testing.expect(blankToNull("") == null);
    try testing.expectEqualStrings("x", blankToNull("x").?);
}
test "displayValueOr" {
    try testing.expectEqualStrings("d", displayValueOr("", "d"));
}
test "isShortFollowUp recognizes option selections and keep-going prompts" {
    try testing.expect(isShortFollowUp("continue"));
    try testing.expect(isShortFollowUp("yes first one"));
    try testing.expect(isShortFollowUp("do the 1st one"));
    try testing.expect(isShortFollowUp("keep going"));
    try testing.expect(!isShortFollowUp("explain the first one in detail because I am confused"));
}

test "activateAgentByNameImpl: a denied agent type is refused without activation" {
    const alloc = testing.allocator;

    var store = permission_rules_mod.Store.init(alloc);
    defer store.deinit();
    try store.addRule(.deny, .global, "Agent", "Explore", "rules.tsv", 1, "test");

    var active_agent: ?agents_mod.AgentSpec = null;
    var active_provider: []u8 = try alloc.dupe(u8, "openai");
    defer alloc.free(active_provider);
    var active_model: []u8 = try alloc.dupe(u8, "gpt-4");
    defer alloc.free(active_model);
    var prev_provider: ?[]u8 = null;
    var prev_model: ?[]u8 = null;
    defer if (prev_provider) |p| alloc.free(p);
    defer if (prev_model) |m| alloc.free(m);

    const msg = try activateAgentByNameImpl(
        alloc,
        "/repo",
        "Explore",
        &active_agent,
        &active_provider,
        &active_model,
        &prev_provider,
        &prev_model,
        &store,
    );
    defer alloc.free(msg);

    // The gate refuses before resolving the agent: a denial message is returned
    // and no agent is activated.
    try testing.expect(std.mem.indexOf(u8, msg, "denied by a permission rule") != null);
    try testing.expect(active_agent == null);
}

// --- Elicitation field-validation tests (mcp-07) ---

/// Test double for `ask_user_fn`: replays a scripted list of answers in order
/// and counts how many times it was called so a test can assert retry
/// behavior. Each returned answer is a fresh dup the caller frees.
const ScriptedAsker = struct {
    answers: []const []const u8,
    idx: usize = 0,
    calls: usize = 0,

    fn ask(ctx: *anyopaque, allocator: std.mem.Allocator, question: []const u8, choices: []const []const u8) anyerror![]u8 {
        _ = question;
        _ = choices;
        const self: *ScriptedAsker = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        const answer = if (self.idx < self.answers.len) self.answers[self.idx] else "";
        self.idx += 1;
        return allocator.dupe(u8, answer);
    }
};

fn parsePropertySchema(allocator: std.mem.Allocator, json_text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
}

test "isIso8601DateTime accepts canonical timestamps and rejects garbage" {
    try testing.expect(isIso8601DateTime("2026-05-29T12:00:00Z"));
    try testing.expect(isIso8601DateTime("2026-05-29T12:00:00"));
    try testing.expect(isIso8601DateTime("2026-05-29T12:00:00.123Z"));
    try testing.expect(isIso8601DateTime("2026-05-29T12:00:00+02:00"));
    try testing.expect(!isIso8601DateTime("not-a-date"));
    try testing.expect(!isIso8601DateTime("2026-05-29"));
    try testing.expect(!isIso8601DateTime("2026/05/29T12:00:00Z"));
    try testing.expect(!isIso8601DateTime("2026-13-29T12:00:00Z")); // month out of range
    try testing.expect(!isIso8601DateTime("2026-05-29T25:00:00Z")); // hour out of range
}

test "promptForElicitationField date-time rejects bad input and accepts ISO-8601" {
    const alloc = testing.allocator;

    var parsed = try parsePropertySchema(alloc, "{\"type\":\"string\",\"format\":\"date-time\"}");
    defer parsed.deinit();

    var asker = ScriptedAsker{ .answers = &.{ "not-a-date", "2026-05-29T12:00:00Z" } };
    const ectx = ElicitationContext{
        .allocator = alloc,
        .ask_user_fn = ScriptedAsker.ask,
        .ask_user_ctx = @ptrCast(&asker),
    };
    const result = try promptForElicitationField(ectx, "pick a time", "when", parsed.value.object, true);
    defer if (result) |r| alloc.free(r);

    try testing.expect(result != null);
    // JSON-encoded string value.
    try testing.expectEqualStrings("\"2026-05-29T12:00:00Z\"", result.?);
    // Rejected the first answer, retried, accepted the second.
    try testing.expectEqual(@as(usize, 2), asker.calls);
}

test "promptForElicitationField multiselect rejects out-of-enum and accepts valid subset" {
    const alloc = testing.allocator;

    var parsed = try parsePropertySchema(alloc, "{\"type\":\"array\",\"items\":{\"enum\":[\"red\",\"green\",\"blue\"]}}");
    defer parsed.deinit();

    var asker = ScriptedAsker{ .answers = &.{ "red, purple", "red, blue" } };
    const ectx = ElicitationContext{
        .allocator = alloc,
        .ask_user_fn = ScriptedAsker.ask,
        .ask_user_ctx = @ptrCast(&asker),
    };
    const result = try promptForElicitationField(ectx, "pick colors", "colors", parsed.value.object, true);
    defer if (result) |r| alloc.free(r);

    try testing.expect(result != null);
    try testing.expectEqualStrings("[\"red\",\"blue\"]", result.?);
    // First answer contained an out-of-enum value -> rejected; retried; accepted.
    try testing.expectEqual(@as(usize, 2), asker.calls);
}

test "ElicitationTracker notes, matches, and ignores unknown ids" {
    const alloc = testing.allocator;
    var tracker = ElicitationTracker.init(alloc);
    defer tracker.deinit();

    try tracker.note("e-1");
    try tracker.note("e-1"); // idempotent
    try testing.expect(tracker.isPending("e-1"));

    // Unknown id ignored without error.
    try testing.expect(!tracker.markComplete("nope"));
    // Known id matches and is cleared.
    try testing.expect(tracker.markComplete("e-1"));
    try testing.expect(!tracker.isPending("e-1"));
    // Double-complete is a no-op false.
    try testing.expect(!tracker.markComplete("e-1"));
}

test "parseElicitationCompleteId extracts elicitationId" {
    const alloc = testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{\"elicitationId\":\"e-7\"}", .{});
    defer parsed.deinit();
    const id = parseElicitationCompleteId(parsed.value.object);
    try testing.expect(id != null);
    try testing.expectEqualStrings("e-7", id.?);

    var parsed2 = try std.json.parseFromSlice(std.json.Value, alloc, "{\"other\":1}", .{});
    defer parsed2.deinit();
    try testing.expect(parseElicitationCompleteId(parsed2.value.object) == null);
}

// --- Fallback-swap (Phase 7.4) callWithAdapter tests ---
//
// A scripted fake adapter whose send() returns a pre-set list of errors (one
// per call) and a success after the script is exhausted. Used to drive
// callWithAdapter through the consecutive-529 -> fallback path without a live
// provider. The non-interactive path in callWithAdapterOnce calls adapter.send
// directly, so no streaming machinery is exercised.
const FallbackTestAdapter = struct {
    script: []const anyerror,
    call_count: usize = 0,

    fn make(self: *FallbackTestAdapter) types.ProviderAdapter {
        return .{ .name = "fake", .ctx = @ptrCast(self), .vtable = &vtable };
    }

    const vtable = types.ProviderAdapter.VTable{
        .deinit = deinitImpl,
        .listModels = listModelsImpl,
        .send = sendImpl,
        .stream = streamImpl,
        .healthcheck = healthcheckImpl,
    };

    fn deinitImpl(_: *anyopaque, _: std.mem.Allocator) void {}

    fn listModelsImpl(_: *anyopaque, _: std.mem.Allocator) anyerror![]types.ModelInfo {
        return &.{};
    }

    fn sendImpl(ctx: *anyopaque, allocator: std.mem.Allocator, _: types.ModelRequest) anyerror!types.ModelResponse {
        const self: *FallbackTestAdapter = @ptrCast(@alignCast(ctx));
        const idx = self.call_count;
        self.call_count += 1;
        if (idx < self.script.len) return self.script[idx];
        return types.ModelResponse{
            .raw = try allocator.dupe(u8, ""),
            .text = try allocator.dupe(u8, "ok"),
            .usage_input_tokens = 0,
            .usage_output_tokens = 0,
        };
    }

    fn streamImpl(_: *anyopaque, allocator: std.mem.Allocator, _: types.ModelRequest) anyerror![]const u8 {
        return allocator.dupe(u8, "");
    }

    fn healthcheckImpl(_: *anyopaque, _: std.mem.Allocator) anyerror!void {}
};

fn setFallbackModel(alloc: std.mem.Allocator, cfg: *config_mod.Config, value: []const u8) !void {
    const dup = try alloc.dupe(u8, value);
    alloc.free(cfg.fallback_model);
    cfg.fallback_model = dup;
}

fn fallbackTestRequest() types.ModelRequest {
    return .{ .model = "opus", .prompt = "hi", .max_output_tokens = 64 };
}

test "callWithAdapter: 3 consecutive overloads with fallback configured triggers swap" {
    const alloc = testing.allocator;
    var cfg = try config_mod.Config.init(alloc);
    defer cfg.deinit(alloc);
    try setFallbackModel(alloc, &cfg, "sonnet");
    // Give the retry budget enough room that the fallback gate (3 overloads),
    // not the retry-count gate, is what fires.
    cfg.provider_retry_count = 5;
    cfg.interactive_streaming = false;

    var fake = FallbackTestAdapter{ .script = &.{ error.ServerOverloaded, error.ServerOverloaded, error.ServerOverloaded } };
    var adapter = fake.make();

    var fb_out: ?[]const u8 = null;
    const result = callWithAdapter(alloc, &cfg, "anthropic", "opus", false, null, &adapter, fallbackTestRequest(), &fb_out, null);
    try testing.expectError(error.FallbackTriggered, result);
    try testing.expect(fb_out != null);
    try testing.expectEqualStrings("sonnet", fb_out.?);
}

test "callWithAdapter: 3 consecutive overloads with NO fallback configured surfaces overload" {
    const alloc = testing.allocator;
    var cfg = try config_mod.Config.init(alloc);
    defer cfg.deinit(alloc);
    // fallback_model stays "" (default). Behavior must be unchanged: surface the
    // overload error after the retry budget is exhausted, never swap.
    cfg.provider_retry_count = 2;
    cfg.interactive_streaming = false;

    var fake = FallbackTestAdapter{ .script = &.{ error.ServerOverloaded, error.ServerOverloaded, error.ServerOverloaded, error.ServerOverloaded } };
    var adapter = fake.make();

    var fb_out: ?[]const u8 = null;
    const result = callWithAdapter(alloc, &cfg, "anthropic", "opus", false, null, &adapter, fallbackTestRequest(), &fb_out, null);
    try testing.expectError(error.ServerOverloaded, result);
    try testing.expect(fb_out == null);
}

test "callWithAdapter: a single overload then success does NOT trigger fallback" {
    const alloc = testing.allocator;
    var cfg = try config_mod.Config.init(alloc);
    defer cfg.deinit(alloc);
    try setFallbackModel(alloc, &cfg, "sonnet");
    cfg.provider_retry_count = 5;
    cfg.interactive_streaming = false;

    var fake = FallbackTestAdapter{ .script = &.{error.ServerOverloaded} };
    var adapter = fake.make();

    var fb_out: ?[]const u8 = null;
    const response = try callWithAdapter(alloc, &cfg, "anthropic", "opus", false, null, &adapter, fallbackTestRequest(), &fb_out, null);
    defer {
        alloc.free(response.raw);
        alloc.free(response.text);
    }
    try testing.expect(fb_out == null);
    try testing.expectEqualStrings("ok", response.text);
}

test "callWithAdapter: interleaved non-overload error resets the consecutive counter" {
    const alloc = testing.allocator;
    var cfg = try config_mod.Config.init(alloc);
    defer cfg.deinit(alloc);
    try setFallbackModel(alloc, &cfg, "sonnet");
    cfg.provider_retry_count = 10;
    cfg.interactive_streaming = false;

    // 529, 529, HttpStatusCode (resets), 529 -> only 1 consecutive at the end,
    // so the fallback (needs 3 in a row) must NOT trigger. After the script the
    // adapter succeeds. HttpStatusCode is agent-retriable, so the loop continues.
    var fake = FallbackTestAdapter{ .script = &.{
        error.ServerOverloaded,
        error.ServerOverloaded,
        error.HttpStatusCode,
        error.ServerOverloaded,
    } };
    var adapter = fake.make();

    var fb_out: ?[]const u8 = null;
    const response = try callWithAdapter(alloc, &cfg, "anthropic", "opus", false, null, &adapter, fallbackTestRequest(), &fb_out, null);
    defer {
        alloc.free(response.raw);
        alloc.free(response.text);
    }
    try testing.expect(fb_out == null);
    try testing.expectEqualStrings("ok", response.text);
}

test "callWithAdapter: fallback identical to active model does not swap" {
    const alloc = testing.allocator;
    var cfg = try config_mod.Config.init(alloc);
    defer cfg.deinit(alloc);
    // fallback == active model: pick() returns null, so no swap; surface overload.
    try setFallbackModel(alloc, &cfg, "opus");
    cfg.provider_retry_count = 2;
    cfg.interactive_streaming = false;

    var fake = FallbackTestAdapter{ .script = &.{ error.ServerOverloaded, error.ServerOverloaded, error.ServerOverloaded, error.ServerOverloaded } };
    var adapter = fake.make();

    var fb_out: ?[]const u8 = null;
    const result = callWithAdapter(alloc, &cfg, "anthropic", "opus", false, null, &adapter, fallbackTestRequest(), &fb_out, null);
    try testing.expectError(error.ServerOverloaded, result);
    try testing.expect(fb_out == null);
}

test "reactiveKeepWindow drops more aggressively on a large overflow" {
    // No gap (unparseable body) -> default window.
    try testing.expectEqual(@as(usize, 8), reactiveKeepWindow(null));
    // Small overflow -> default window.
    try testing.expectEqual(@as(usize, 8), reactiveKeepWindow(2_500));
    // Large overflow -> aggressive (smaller) window.
    try testing.expectEqual(@as(usize, 4), reactiveKeepWindow(50_000));
}

// --- Reactive-compaction (Phase 7.5) callWithAdapter tests ---
//
// A scripted fake adapter that records the history length seen on each call and
// returns a pre-set list of errors (one per call), then succeeds. Used to drive
// callWithAdapter through the RequestTooLarge -> reduce -> retry path without a
// live provider.
const ReactiveTestAdapter = struct {
    script: []const anyerror,
    call_count: usize = 0,
    // history length observed on each send(), up to the buffer size.
    seen_history_lens: [8]usize = [_]usize{0} ** 8,

    fn make(self: *ReactiveTestAdapter) types.ProviderAdapter {
        return .{ .name = "fake", .ctx = @ptrCast(self), .vtable = &vtable };
    }

    const vtable = types.ProviderAdapter.VTable{
        .deinit = deinitImpl,
        .listModels = listModelsImpl,
        .send = sendImpl,
        .stream = streamImpl,
        .healthcheck = healthcheckImpl,
    };

    fn deinitImpl(_: *anyopaque, _: std.mem.Allocator) void {}

    fn listModelsImpl(_: *anyopaque, _: std.mem.Allocator) anyerror![]types.ModelInfo {
        return &.{};
    }

    fn sendImpl(ctx: *anyopaque, allocator: std.mem.Allocator, request: types.ModelRequest) anyerror!types.ModelResponse {
        const self: *ReactiveTestAdapter = @ptrCast(@alignCast(ctx));
        const idx = self.call_count;
        if (idx < self.seen_history_lens.len) self.seen_history_lens[idx] = request.history.len;
        self.call_count += 1;
        if (idx < self.script.len) return self.script[idx];
        return types.ModelResponse{
            .raw = try allocator.dupe(u8, ""),
            .text = try allocator.dupe(u8, "ok"),
            .usage_input_tokens = 0,
            .usage_output_tokens = 0,
        };
    }

    fn streamImpl(_: *anyopaque, allocator: std.mem.Allocator, _: types.ModelRequest) anyerror![]const u8 {
        return allocator.dupe(u8, "");
    }

    fn healthcheckImpl(_: *anyopaque, _: std.mem.Allocator) anyerror!void {}
};

fn reactiveTestHistory() [12]types.HistoryTurn {
    var h: [12]types.HistoryTurn = undefined;
    h[0] = .{ .role = .system, .content = "sys", .timestamp = 0 };
    var i: usize = 1;
    while (i < h.len) : (i += 1) {
        h[i] = .{
            .role = if (i % 2 == 1) .user else .assistant,
            .content = "turn",
            .timestamp = 0,
        };
    }
    return h;
}

test "callWithAdapter: 413 then success reduces history and the turn succeeds" {
    const alloc = testing.allocator;
    var cfg = try config_mod.Config.init(alloc);
    defer cfg.deinit(alloc);
    cfg.interactive_streaming = false;
    common.beginNewRequest();

    const history = reactiveTestHistory();
    const request = types.ModelRequest{
        .model = "opus",
        .prompt = "hi",
        .max_output_tokens = 64,
        .history = &history,
    };

    var fake = ReactiveTestAdapter{ .script = &.{error.RequestTooLarge} };
    var adapter = fake.make();

    var fb_out: ?[]const u8 = null;
    var reactive_out: bool = false;
    const response = try callWithAdapter(alloc, &cfg, "anthropic", "opus", false, null, &adapter, request, &fb_out, &reactive_out);
    defer {
        alloc.free(response.raw);
        alloc.free(response.text);
    }
    try testing.expectEqualStrings("ok", response.text);
    // Two calls: the first (full history) 413s, the second (reduced) succeeds.
    try testing.expectEqual(@as(usize, 2), fake.call_count);
    try testing.expect(fake.seen_history_lens[1] < fake.seen_history_lens[0]);
    // The recovery is surfaced so the caller can mark compaction_applied.
    try testing.expect(reactive_out);
}

test "callWithAdapter: a clean success leaves reactive_applied_out false" {
    const alloc = testing.allocator;
    var cfg = try config_mod.Config.init(alloc);
    defer cfg.deinit(alloc);
    cfg.interactive_streaming = false;
    common.beginNewRequest();

    const history = reactiveTestHistory();
    const request = types.ModelRequest{
        .model = "opus",
        .prompt = "hi",
        .max_output_tokens = 64,
        .history = &history,
    };

    // No scripted errors: the first call succeeds, so no reactive reduction.
    var fake = ReactiveTestAdapter{ .script = &.{} };
    var adapter = fake.make();

    var fb_out: ?[]const u8 = null;
    var reactive_out: bool = false;
    const response = try callWithAdapter(alloc, &cfg, "anthropic", "opus", false, null, &adapter, request, &fb_out, &reactive_out);
    defer {
        alloc.free(response.raw);
        alloc.free(response.text);
    }
    try testing.expectEqual(@as(usize, 1), fake.call_count);
    // No 413 fired, so the flag must remain untouched (false).
    try testing.expect(!reactive_out);
}

test "callWithAdapter: an adapter that always 413s surfaces the error after the cap" {
    const alloc = testing.allocator;
    var cfg = try config_mod.Config.init(alloc);
    defer cfg.deinit(alloc);
    cfg.interactive_streaming = false;
    common.beginNewRequest();

    const history = reactiveTestHistory();
    const request = types.ModelRequest{
        .model = "opus",
        .prompt = "hi",
        .max_output_tokens = 64,
        .history = &history,
    };

    // Always 413: must surface RequestTooLarge after the reactive-retry cap
    // rather than looping forever.
    var fake = ReactiveTestAdapter{ .script = &.{
        error.RequestTooLarge,
        error.RequestTooLarge,
        error.RequestTooLarge,
        error.RequestTooLarge,
        error.RequestTooLarge,
    } };
    var adapter = fake.make();

    var fb_out: ?[]const u8 = null;
    const result = callWithAdapter(alloc, &cfg, "anthropic", "opus", false, null, &adapter, request, &fb_out, null);
    try testing.expectError(error.RequestTooLarge, result);
    // Initial attempt + MAX_REACTIVE_RETRIES (2) reductions = 3 calls, then the
    // cap surfaces the error. The reduction can also stop early once the history
    // can no longer shrink, so allow up to 3.
    try testing.expect(fake.call_count >= 2 and fake.call_count <= 3);
}

// --- max_tokens / context-overflow auto-adjust (Phase 7.6) callWithAdapter tests ---
//
// A scripted fake adapter that records the max_output_tokens seen on each call
// and returns a pre-set list of errors (one per call), then succeeds. Used to
// drive callWithAdapter through the MaxTokensOverflow -> lower max_tokens ->
// retry path without a live provider.
const OverflowTestAdapter = struct {
    script: []const anyerror,
    call_count: usize = 0,
    seen_max_tokens: [8]usize = [_]usize{0} ** 8,

    fn make(self: *OverflowTestAdapter) types.ProviderAdapter {
        return .{ .name = "fake", .ctx = @ptrCast(self), .vtable = &vtable };
    }

    const vtable = types.ProviderAdapter.VTable{
        .deinit = deinitImpl,
        .listModels = listModelsImpl,
        .send = sendImpl,
        .stream = streamImpl,
        .healthcheck = healthcheckImpl,
    };

    fn deinitImpl(_: *anyopaque, _: std.mem.Allocator) void {}

    fn listModelsImpl(_: *anyopaque, _: std.mem.Allocator) anyerror![]types.ModelInfo {
        return &.{};
    }

    fn sendImpl(ctx: *anyopaque, allocator: std.mem.Allocator, request: types.ModelRequest) anyerror!types.ModelResponse {
        const self: *OverflowTestAdapter = @ptrCast(@alignCast(ctx));
        const idx = self.call_count;
        if (idx < self.seen_max_tokens.len) self.seen_max_tokens[idx] = request.max_output_tokens;
        self.call_count += 1;
        if (idx < self.script.len) return self.script[idx];
        return types.ModelResponse{
            .raw = try allocator.dupe(u8, ""),
            .text = try allocator.dupe(u8, "ok"),
            .usage_input_tokens = 0,
            .usage_output_tokens = 0,
        };
    }

    fn streamImpl(_: *anyopaque, allocator: std.mem.Allocator, _: types.ModelRequest) anyerror![]const u8 {
        return allocator.dupe(u8, "");
    }

    fn healthcheckImpl(_: *anyopaque, _: std.mem.Allocator) anyerror!void {}
};

test "callWithAdapter: max_tokens overflow lowers max_output_tokens and retries" {
    const alloc = testing.allocator;
    var cfg = try config_mod.Config.init(alloc);
    defer cfg.deinit(alloc);
    cfg.interactive_streaming = false;
    common.beginNewRequest();
    // beginNewRequest frees the stashed error body, so run it again at scope exit
    // to release the body we set below (testing.allocator checks per-test leaks).
    defer common.beginNewRequest();
    // Stash the overflow body the way a real 400 would: available context is
    // 200000 - 188059 - 1000 = 10941, so the adjusted max_tokens is 10941.
    common.setLastErrorBodyForTest(alloc, "input length and `max_tokens` exceed context limit: 188059 + 20000 > 200000");

    const request = types.ModelRequest{
        .model = "opus",
        .prompt = "hi",
        .max_output_tokens = 20000,
    };

    var fake = OverflowTestAdapter{ .script = &.{error.MaxTokensOverflow} };
    var adapter = fake.make();

    var fb_out: ?[]const u8 = null;
    const response = try callWithAdapter(alloc, &cfg, "anthropic", "opus", false, null, &adapter, request, &fb_out, null);
    defer {
        alloc.free(response.raw);
        alloc.free(response.text);
    }
    try testing.expectEqualStrings("ok", response.text);
    // Two calls: the first (20000) overflows, the second retries with the
    // adjusted, lower max_tokens (10941) and succeeds.
    try testing.expectEqual(@as(usize, 2), fake.call_count);
    try testing.expectEqual(@as(usize, 20000), fake.seen_max_tokens[0]);
    try testing.expectEqual(@as(usize, 10941), fake.seen_max_tokens[1]);
}

test "callWithAdapter: max_tokens overflow with unrecoverable input surfaces the error" {
    const alloc = testing.allocator;
    var cfg = try config_mod.Config.init(alloc);
    defer cfg.deinit(alloc);
    cfg.interactive_streaming = false;
    common.beginNewRequest();
    defer common.beginNewRequest();
    // Input alone leaves less than the 3000 output floor (199000 + 1000 buffer
    // = 200000 == limit -> available 0), so adjustMaxTokens returns null and the
    // error surfaces without retry.
    common.setLastErrorBodyForTest(alloc, "input length and `max_tokens` exceed context limit: 199000 + 20000 > 200000");

    const request = types.ModelRequest{
        .model = "opus",
        .prompt = "hi",
        .max_output_tokens = 20000,
    };

    var fake = OverflowTestAdapter{ .script = &.{
        error.MaxTokensOverflow,
        error.MaxTokensOverflow,
    } };
    var adapter = fake.make();

    var fb_out: ?[]const u8 = null;
    const result = callWithAdapter(alloc, &cfg, "anthropic", "opus", false, null, &adapter, request, &fb_out, null);
    try testing.expectError(error.MaxTokensOverflow, result);
    // Only the first call is made; the unrecoverable adjustment surfaces the
    // error immediately rather than retrying.
    try testing.expectEqual(@as(usize, 1), fake.call_count);
}

// --- Persistent / unattended retry mode (Phase 7.8) tests ---
//
// These exercise the env-gated indefinite-retry path. The sleep is injected via
// the `sleep_ms_fn` seam so the loop never blocks on the wall clock: each test
// records the requested chunk durations and returns instantly. The unattended
// flag is forced via setUnattendedRetryForTest (never via a real env var, which
// the cache would read only once and which would leak across tests).

// Recorded chunk durations for the injected sleep, plus an optional cancel-after
// trigger so the cancel test can break the loop deterministically.
var test_recorded_sleeps: std.ArrayList(u64) = .empty;
var test_cancel_after_chunks: ?usize = null;

fn recordingSleepMs(ms: u64) void {
    // testing.allocator is fine here: appends happen inside a test scope and the
    // list is reset (capacity freed) by resetSleepRecorder in the test's defer.
    test_recorded_sleeps.append(testing.allocator, ms) catch {};
    if (test_cancel_after_chunks) |limit| {
        if (test_recorded_sleeps.items.len >= limit) {
            // Simulate the user pressing ESC mid-wait: the next chunkedSleep
            // cancellation check (common.checkCancelled) will trip.
            common.cancel_requested.store(true, .release);
        }
    }
}

fn installSleepRecorder() void {
    test_recorded_sleeps = .empty;
    test_cancel_after_chunks = null;
    sleep_ms_fn = recordingSleepMs;
}

fn resetSleepRecorder() void {
    test_recorded_sleeps.deinit(testing.allocator);
    test_recorded_sleeps = .empty;
    test_cancel_after_chunks = null;
    sleep_ms_fn = defaultSleepMs;
    setUnattendedRetryForTest(null);
    common.cancel_requested.store(false, .release);
}

test "isPersistentRetriableError: only rate-limit and overload qualify" {
    try testing.expect(isPersistentRetriableError(error.RateLimited));
    try testing.expect(isPersistentRetriableError(error.ServerOverloaded));
    try testing.expect(!isPersistentRetriableError(error.HttpStatusCode));
    try testing.expect(!isPersistentRetriableError(error.RequestTooLarge));
    try testing.expect(!isPersistentRetriableError(error.MaxTokensOverflow));
}

test "unattended flag parses env-truthy vocabulary" {
    // Forced-on / forced-off via the test seam returns deterministically.
    setUnattendedRetryForTest(true);
    try testing.expect(unattendedRetryEnabled());
    setUnattendedRetryForTest(false);
    try testing.expect(!unattendedRetryEnabled());
    // Reset back to "read env on next call" so other tests are not affected.
    setUnattendedRetryForTest(null);
    // The truthy vocabulary itself is the shared core/env.zig one.
    try testing.expect(env_mod.isTruthy("1"));
    try testing.expect(env_mod.isTruthy("true"));
    try testing.expect(!env_mod.isTruthy("0"));
    try testing.expect(!env_mod.isTruthy(null));
}

test "callWithAdapter: persistent mode retries RateLimited past the retry budget" {
    const alloc = testing.allocator;
    var cfg = try config_mod.Config.init(alloc);
    defer cfg.deinit(alloc);
    cfg.interactive_streaming = false;
    // Tiny normal budget: in normal mode RateLimited is non-retriable and the
    // loop would surface it immediately. Persistent mode must override that.
    cfg.provider_retry_count = 2;

    installSleepRecorder();
    defer resetSleepRecorder();
    setUnattendedRetryForTest(true);

    // Five RateLimited responses (well past provider_retry_count) then success.
    var fake = FallbackTestAdapter{ .script = &.{
        error.RateLimited,
        error.RateLimited,
        error.RateLimited,
        error.RateLimited,
        error.RateLimited,
    } };
    var adapter = fake.make();

    var fb_out: ?[]const u8 = null;
    const response = try callWithAdapter(alloc, &cfg, "anthropic", "opus", false, null, &adapter, fallbackTestRequest(), &fb_out, null);
    defer {
        alloc.free(response.raw);
        alloc.free(response.text);
    }
    // The turn ultimately succeeds despite 5 rate-limits, which normal mode
    // (budget 2, RateLimited non-retriable) would never have done.
    try testing.expectEqualStrings("ok", response.text);
    try testing.expectEqual(@as(usize, 6), fake.call_count); // 5 failures + 1 success
    // At least one sleep chunk was recorded (the loop actually waited between
    // retries rather than busy-spinning).
    try testing.expect(test_recorded_sleeps.items.len > 0);
}

test "callWithAdapter: persistent mode keeps retrying ServerOverloaded with no fallback configured" {
    const alloc = testing.allocator;
    var cfg = try config_mod.Config.init(alloc);
    defer cfg.deinit(alloc);
    cfg.interactive_streaming = false;
    cfg.provider_retry_count = 1;
    // fallback_model stays "" so the fallback-swap gate never fires; persistent
    // mode must carry the retries instead of swapping.

    installSleepRecorder();
    defer resetSleepRecorder();
    setUnattendedRetryForTest(true);

    var fake = FallbackTestAdapter{ .script = &.{
        error.ServerOverloaded,
        error.ServerOverloaded,
        error.ServerOverloaded,
        error.ServerOverloaded,
    } };
    var adapter = fake.make();

    var fb_out: ?[]const u8 = null;
    const response = try callWithAdapter(alloc, &cfg, "anthropic", "opus", false, null, &adapter, fallbackTestRequest(), &fb_out, null);
    defer {
        alloc.free(response.raw);
        alloc.free(response.text);
    }
    try testing.expect(fb_out == null); // no swap: none configured
    try testing.expectEqualStrings("ok", response.text);
    try testing.expectEqual(@as(usize, 5), fake.call_count); // 4 failures + 1 success
}

test "callWithAdapter: a cancel between chunks breaks the persistent retry loop" {
    const alloc = testing.allocator;
    var cfg = try config_mod.Config.init(alloc);
    defer cfg.deinit(alloc);
    cfg.interactive_streaming = false;
    cfg.provider_retry_count = 1;

    installSleepRecorder();
    defer resetSleepRecorder();
    setUnattendedRetryForTest(true);
    // After the 1st recorded chunk, the injected sleep sets the global cancel
    // flag; the next chunkedSleep cancellation check must surface UserCancelled.
    test_cancel_after_chunks = 1;

    // An adapter that NEVER succeeds: only the cancel can break the loop.
    var fake = AlwaysRateLimitedAdapter{};
    var adapter = fake.make();

    var fb_out: ?[]const u8 = null;
    const result = callWithAdapter(alloc, &cfg, "anthropic", "opus", false, null, &adapter, fallbackTestRequest(), &fb_out, null);
    try testing.expectError(error.UserCancelled, result);
}

// An adapter that always rate-limits. Used to prove the persistent loop only
// terminates on cancellation, never on its own.
const AlwaysRateLimitedAdapter = struct {
    fn make(self: *AlwaysRateLimitedAdapter) types.ProviderAdapter {
        return .{ .name = "fake", .ctx = @ptrCast(self), .vtable = &vtable };
    }
    const vtable = types.ProviderAdapter.VTable{
        .deinit = deinitImpl,
        .listModels = listModelsImpl,
        .send = sendImpl,
        .stream = streamImpl,
        .healthcheck = healthcheckImpl,
    };
    fn deinitImpl(_: *anyopaque, _: std.mem.Allocator) void {}
    fn listModelsImpl(_: *anyopaque, _: std.mem.Allocator) anyerror![]types.ModelInfo {
        return &.{};
    }
    fn sendImpl(_: *anyopaque, _: std.mem.Allocator, _: types.ModelRequest) anyerror!types.ModelResponse {
        return error.RateLimited;
    }
    fn streamImpl(_: *anyopaque, allocator: std.mem.Allocator, _: types.ModelRequest) anyerror![]const u8 {
        return allocator.dupe(u8, "");
    }
    fn healthcheckImpl(_: *anyopaque, _: std.mem.Allocator) anyerror!void {}
};

// --- Phase 8, Task 6: structured compact-boundary marker (compaction-14) ---

test "forceCompaction appends a structured compact_boundary turn that resume can parse" {
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("core/test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(sessions_dir);

    var store = try session_store.Store.init(alloc, sessions_dir, false);
    defer store.deinit();

    const session_id = "boundary-test";

    var history = History.init(alloc, &store);
    defer history.deinit();

    // A pre-compaction history: a deferred-tool load plus a real tool result,
    // so the boundary marker has a discovered tool to record.
    try history.append(session_id, .user, "we must keep src/main.zig stable");
    try history.append(session_id, .tool, "Tool: ToolSearch\nloaded Read");
    try history.append(session_id, .assistant, "decision accepted");

    var snapshot = try allocEmptySnapshot(alloc);
    defer freeSnapshot(alloc, snapshot);

    // No summarizer: the rule-based fallback path. compact_percent is forced to
    // 0 inside forceCompaction, so this always compacts. Trigger = manual.
    try forceCompaction(&history, &snapshot, session_id, 100, 10, 10, null, "", .manual);

    // The last in-memory turn is the structured boundary system turn.
    const last = history.at(history.len() - 1);
    try testing.expectEqual(types.HistoryRole.system, last.role);
    try testing.expect(std.mem.startsWith(u8, last.content, compaction.COMPACT_BOUNDARY_PREFIX));
    try testing.expect(std.mem.indexOf(u8, last.content, "trigger=manual") != null);
    try testing.expect(std.mem.indexOf(u8, last.content, "ToolSearch") != null);
    // It is NOT the legacy bare note anymore.
    try testing.expect(std.mem.indexOf(u8, last.content, "Conversation compacted by control action.") == null);

    // Resume path: reload the session from disk and confirm the boundary turn
    // round-trips, exposing pre_compact_tokens for telemetry.
    var loaded = try store.load(session_id);
    defer loaded.deinit(alloc);

    var found = false;
    for (loaded.history) |turn| {
        if (turn.role != .system) continue;
        const boundary = (try compaction.parseCompactBoundary(alloc, turn.content)) orelse continue;
        defer compaction.freeDiscoveredTools(alloc, boundary.discovered_tools);
        found = true;
        try testing.expectEqual(types.CompactTrigger.manual, boundary.trigger);
        try testing.expect(boundary.pre_compact_tokens > 0);
        try testing.expectEqual(@as(usize, 1), boundary.discovered_tools.len);
        try testing.expectEqualStrings("ToolSearch", boundary.discovered_tools[0]);
    }
    try testing.expect(found);
}

test "History.append mints distinct non-empty uuids and truncateFrom frees them" {
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("core/test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(sessions_dir);

    var store = try session_store.Store.init(alloc, sessions_dir, false);
    defer store.deinit();

    var history = History.init(alloc, &store);
    // deinit frees any surviving turns; running under the leak-checking
    // test allocator proves the uuid frees pair with the dups.
    defer history.deinit();

    try history.append("uuid-sess", .user, "first");
    try history.append("uuid-sess", .assistant, "second");

    try testing.expectEqual(@as(usize, 2), history.len());
    const a = history.at(0).uuid;
    const b = history.at(1).uuid;
    try testing.expect(a.len > 0);
    try testing.expect(b.len > 0);
    try testing.expect(!std.mem.eql(u8, a, b));

    // truncateFrom must free the dropped turn's uuid (no leak under the
    // test allocator) and leave the surviving turn intact.
    history.truncateFrom(1);
    try testing.expectEqual(@as(usize, 1), history.len());
    try testing.expectEqualStrings("first", history.at(0).content);
    try testing.expect(history.at(0).uuid.len > 0);
}

// commands-sweep-02: `/branch myfork` re-points to a conversation fork via
// runtime.forkSession -> forkSessionImpl. Drive that exact path against a
// tmp-dir store and assert a NEW session id is minted, the transcript is
// copied, and the returned message carries source-traceability (the old git
// `/branch` did none of this).
test "forkSessionImpl (the /branch fork path) mints a new id and copies the transcript" {
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("core/test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(sessions_dir);

    var store = try session_store.Store.init(alloc, sessions_dir, false);
    defer store.deinit();

    // Seed a source session with a small transcript. History.append persists
    // each turn to the source session on disk and tracks it in memory; the fork
    // copies the in-memory view into the new session.
    const source_id = try store.createSessionId();
    defer alloc.free(source_id);

    var history = History.init(alloc, &store);
    defer history.deinit();
    try history.append(source_id, .user, "what is the capital of France");
    try history.append(source_id, .assistant, "Paris");

    var snapshot = try allocEmptySnapshot(alloc);
    defer freeSnapshot(alloc, snapshot);

    // forkSessionImpl mutates session_id.* to the new id (freeing the old) and
    // returns an owned "forked session <src> -> <new> label=<name>" message.
    const source_copy = try alloc.dupe(u8, source_id);
    var active_id: []u8 = source_copy;
    defer alloc.free(active_id);

    const msg = try forkSessionImpl(alloc, &store, &active_id, &history, &snapshot, "myfork");
    defer alloc.free(msg);

    // A genuinely new session id was minted (different from the source).
    try testing.expect(!std.mem.eql(u8, active_id, source_id));

    // Source-traceability: the message names both ids and the requested label.
    try testing.expect(std.mem.indexOf(u8, msg, source_id) != null);
    try testing.expect(std.mem.indexOf(u8, msg, active_id) != null);
    try testing.expect(std.mem.indexOf(u8, msg, "label=myfork") != null);

    // The forked session on disk carries a copy of the source transcript.
    var forked = try store.load(active_id);
    defer forked.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), forked.history.len);
    try testing.expectEqualStrings("what is the capital of France", forked.history[0].content);
    try testing.expectEqualStrings("Paris", forked.history[1].content);

    // The source session is untouched (still present and intact).
    var src_loaded = try store.load(source_id);
    defer src_loaded.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), src_loaded.history.len);
}

test "History.appendWithThinking owns and frees the thinking slice (no leak)" {
    // ui-render-04: a turn carrying extended-thinking text must dupe it
    // into the History allocator and free it exactly once. Running the
    // full lifecycle (append -> truncate -> deinit) under the leak-
    // checking test allocator proves the dupe pairs with the free in
    // freeTurn and there is no double-free.
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("core/test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(sessions_dir);

    var store = try session_store.Store.init(alloc, sessions_dir, false);
    defer store.deinit();

    var history = History.init(alloc, &store);
    defer history.deinit();

    // Turn with thinking text.
    try history.appendWithThinking("think-sess", .assistant, "answer one", "step one\nstep two");
    // Turn with no thinking (null) -- exercises the optional path.
    try history.appendWithThinking("think-sess", .assistant, "answer two", null);
    // Turn with empty-string thinking -- must store null, not a 0-len dupe.
    try history.appendWithThinking("think-sess", .assistant, "answer three", "");

    try testing.expectEqual(@as(usize, 3), history.len());
    try testing.expect(history.at(0).thinking != null);
    try testing.expectEqualStrings("step one\nstep two", history.at(0).thinking.?);
    try testing.expect(history.at(1).thinking == null);
    try testing.expect(history.at(2).thinking == null);

    // truncateFrom must free the dropped turn's thinking slice.
    history.truncateFrom(1);
    try testing.expectEqual(@as(usize, 1), history.len());
    try testing.expect(history.at(0).thinking != null);

    // replaceWith must dupe the surviving thinking slice; the leak
    // checker catches a missed free on either the old or the new copy.
    const replacement = [_]types.HistoryTurn{
        .{ .role = .assistant, .content = "kept", .timestamp = 0, .uuid = "", .thinking = "carried over" },
    };
    try history.replaceWith(&replacement);
    try testing.expectEqual(@as(usize, 1), history.len());
    try testing.expectEqualStrings("carried over", history.at(0).thinking.?);

    // clearInMemory must free the thinking slice too.
    history.clearInMemory();
    try testing.expectEqual(@as(usize, 0), history.len());
}
