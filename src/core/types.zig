const std = @import("std");
const common = @import("../providers/common.zig");

pub const StreamChunkCallback = common.StreamChunkCallback;

pub const RiskTier = enum {
    LOW,
    MEDIUM,
    HIGH,
    BLOCKED,
};

pub const ApprovalState = enum {
    auto_approved,
    user_approved,
    session_approved,
    denied,
    blocked,
};

pub const ApprovalResponse = enum {
    approve,
    approve_always,
    deny,
};

/// Slim enum that prompt_helpers consumes to decide which
/// mode-specific system-prompt blocks to append. A thin
/// projection of cli/repl.SessionMode kept in types.zig so the
/// prompt layer doesn't have to import the REPL module.
pub const PromptMode = enum {
    execution,
    planning,
    brainstorm,
    review,
};

pub const ContextSource = enum {
    git_status,
    git_diff,
    repo_map,
    user_file,
    tool_result,
    session_memory,
    instruction,
};

pub const ContextBlock = struct {
    id: []const u8,
    source_type: ContextSource,
    priority: u8,
    token_estimate: usize,
    content: []const u8,
    freshness: i64,
};

pub const BudgetPlan = struct {
    model_ctx_window: usize,
    reserved_output: usize,
    reserved_reasoning: usize,
    input_budget: usize,
    compaction_thresholds: CompactionThresholds,

    pub const CompactionThresholds = struct {
        warn_percent: u8 = 50,
        compact_percent: u8 = 60,
        force_percent: u8 = 80,
    };

    pub fn init(model_ctx_window: usize, reserved_output: usize, reserved_reasoning: usize) BudgetPlan {
        const safe_reserved_output = @min(reserved_output, model_ctx_window);
        const remaining = model_ctx_window - safe_reserved_output;
        const safe_reserved_reasoning = @min(reserved_reasoning, remaining);
        const input_budget = model_ctx_window - safe_reserved_output - safe_reserved_reasoning;
        return .{
            .model_ctx_window = model_ctx_window,
            .reserved_output = safe_reserved_output,
            .reserved_reasoning = safe_reserved_reasoning,
            .input_budget = input_budget,
            .compaction_thresholds = .{},
        };
    }
};

/// Absolute-token buffer thresholds ported from the reference's
/// services/compact/autoCompact.ts. These coexist with
/// BudgetPlan.CompactionThresholds: the percentage bands gate the cheap
/// per-turn rule-based snapshot, while these absolute buffers gate the
/// expensive LLM summary at the compaction boundary and drive the
/// warning UI. See core/autocompact_threshold.zig for the math.
pub const MAX_OUTPUT_TOKENS_FOR_SUMMARY: usize = 20_000;
pub const AUTOCOMPACT_BUFFER_TOKENS: usize = 13_000;
pub const WARNING_THRESHOLD_BUFFER_TOKENS: usize = 20_000;
pub const ERROR_THRESHOLD_BUFFER_TOKENS: usize = 20_000;
pub const MANUAL_COMPACT_BUFFER_TOKENS: usize = 3_000;

/// Snapshot of the token-budget warning tiers for a given usage.
/// Mirrors the object returned by `calculateTokenWarningState`
/// (autoCompact.ts:93-145).
pub const TokenWarningState = struct {
    /// Percent of the active threshold still available, clamped to
    /// [0,100] and rounded to the nearest whole percent. Zero once
    /// usage meets or exceeds the threshold.
    percent_left: u8,
    is_above_warning: bool,
    is_above_error: bool,
    is_above_autocompact: bool,
    is_at_blocking_limit: bool,
};

/// What kicked off a compaction. "auto" is the in-turn auto-compaction control
/// action; "manual" is the explicit `/compact` REPL command. Mirrors the
/// reference's `trigger: 'auto' | 'manual'` carried by
/// `createCompactBoundaryMessage` (services/compact/compact.ts:598-611).
pub const CompactTrigger = enum {
    auto,
    manual,

    pub fn toString(self: CompactTrigger) []const u8 {
        return switch (self) {
            .auto => "auto",
            .manual => "manual",
        };
    }

    pub fn fromString(s: []const u8) ?CompactTrigger {
        if (std.mem.eql(u8, s, "auto")) return .auto;
        if (std.mem.eql(u8, s, "manual")) return .manual;
        return null;
    }
};

/// Structured compact-boundary marker (compaction-14). Replaces the bare
/// "Conversation compacted by control action." note with a record carrying the
/// trigger, the pre-compaction token total, the tools discovered before the
/// boundary, and the preserved-segment relink positions. It is serialized to a
/// stable, human-readable single line (see compaction.serializeCompactBoundary)
/// and appended as a `.system` turn so the transcript loader, `/context`
/// telemetry, and `--resume` can parse it back.
///
/// Divergence from the reference: zcode history turns are positional, not
/// UUID-keyed, so the preserved-segment relinks are turn indices (into the
/// surviving tail) rather than message UUIDs.
pub const CompactBoundary = struct {
    trigger: CompactTrigger,
    pre_compact_tokens: usize,
    discovered_tools: []const []const u8 = &.{},
    preserved_head: ?usize = null,
    preserved_anchor: ?usize = null,
    preserved_tail: ?usize = null,
};

pub const InstructionEntry = struct {
    source: []const u8,
    precedence: u8,
    truncated: bool,
    content: []const u8,
    scope_distance: u16 = 0,
    import_depth: u8 = 0,
    order: u32 = 0,
    /// Frontmatter `paths:`/`globs:` patterns this entry was gated on
    /// (with any trailing `/**` stripped). Empty for the common case
    /// of an unconditional instruction file. Owned by the same
    /// allocator that owns `source`/`content`; freed in
    /// instructions.freeEntries. Recorded so a future per-edit
    /// re-evaluation can re-apply the gate, and so tests can assert
    /// what was parsed.
    globs: []const []const u8 = &.{},
};

pub const HistoryRole = enum {
    user,
    assistant,
    system,
    tool,
};

pub const HistoryTurn = struct {
    role: HistoryRole,
    content: []const u8,
    timestamp: i64,
    /// Stable per-turn id (canonical UUID-v4). Persisted in the JSONL so
    /// rewind snapshots (sessions-01) and resume-consistency checks
    /// (sessions-08) can key off a message instead of a fragile array
    /// index. Defaults to "" so the many positional constructors
    /// (compaction, bundles, export, tests) keep compiling unchanged;
    /// only the append + load paths populate it. Legacy JSONL records
    /// written before this field existed load with uuid == "".
    uuid: []const u8 = "",
    /// Optional extended-thinking / reasoning text captured for this
    /// turn (ui-render-04). When present and owned by the live History,
    /// the transcript renders a collapsed `∴ Thinking <ctrl+o to expand>`
    /// line in normal view and the full dim Markdown block in transcript
    /// view. Defaults to null so every positional/literal constructor
    /// (compaction, bundles, export, tests, JSONL load) compiles
    /// unchanged; only the live assistant-append path populates it. Not
    /// persisted to JSONL -- it is a render-only artifact of the live
    /// session, so reload reconstructs turns with thinking == null.
    thinking: ?[]const u8 = null,
};

pub const ToolSchema = struct {
    name: []const u8,
    description: []const u8,
    json_schema: []const u8,
    usage_hint: []const u8 = "",
    /// Curated 3-10-word capability phrase scored above the description
    /// when ToolSearch ranks deferred tools by a keyword query (see
    /// Tool.ts:373-378 / ToolSearchTool.ts). Distinct from usage_hint
    /// (general invocation guidance shown in the schema): search_hint
    /// is a tight summary purpose-built for the scored keyword search.
    /// Defaults to empty so existing literals compile unchanged.
    search_hint: []const u8 = "",
    is_read_only: bool = false,
    is_destructive: bool = false,
    /// When true, this tool's full schema is NOT emitted to the model
    /// every turn -- only its name is surfaced via a deferred-tools
    /// system reminder. The model fetches the full schema on demand
    /// via ToolSearch. Mirrors Claude Code's `shouldDefer` flag
    /// (~/Downloads/claude-code-main/src/Tool.ts:442). Saves the per-
    /// turn input-token cost of long-tail tools (MCP family, Task
    /// family, Cron, niche specialists) without losing access to them.
    should_defer: bool = false,
    /// Per-tool artifact-persistence threshold in chars/bytes. When a
    /// tool's result exceeds this, the runtime persists it to a session
    /// artifact and keeps only a preview in history. 0 means "use the
    /// global cfg.tool_output_artifact_threshold_bytes". maxInt(usize)
    /// means "never artifact" (e.g. Read, so a Read result is never
    /// turned into an artifact file that would then have to be Read
    /// again). Grep caps tighter than the global default. Mirrors the
    /// reference's per-tool maxResultSizeChars (Tool.ts:457-466;
    /// GrepTool 20k, FileReadTool Infinity).
    max_result_size_chars: usize = 0,
    /// Declarative JSON Schema describing the SHAPE of this tool's
    /// structured result (NOT its input). Advertised so SDK/MCP
    /// consumers know the structured-content shape a tool returns
    /// (e.g. WebFetch -> {bytes, code, result, url}). Mirrors the
    /// reference's per-tool outputSchema (Tool.ts:400;
    /// WebFetchTool.ts:32-46). Empty for tools whose result is plain
    /// text with no stable structured shape. Defaults to empty so
    /// existing literals compile unchanged. Dup'd/freed in
    /// collectSchemas/freeSchemas with the same len>0 symmetry as
    /// usage_hint and search_hint.
    output_schema: []const u8 = "",
};

pub const CacheHint = struct {
    key: []const u8,
    ttl_seconds: u32,
};

pub const PreprocessorHints = struct {
    intent: []const u8,
    focus_directive: []const u8,
    context_scores: []const ContextScore,

    pub const ContextScore = struct {
        block_id: []const u8,
        relevance: u8,
    };
};

/// MCP server instructions attached to a prompt envelope. Populated
/// by the agent runtime from the MCP Client's handshake cache (see
/// pass 121) and surfaced to the model via the mcp-server reminder
/// block so MCP-authored guidance (e.g. "always pass a target to
/// nmap_scan") is visible during every turn.
pub const McpServerInstruction = struct {
    name: []const u8,
    text: []const u8,
};

pub const PromptEnvelope = struct {
    system_policy: []const u8,
    dynamic_policy: []const u8 = "",
    instruction_stack: []InstructionEntry,
    user_turn: []const u8,
    working_context: []const u8 = "",
    tool_schemas: []ToolSchema,
    history: []HistoryTurn,
    context_blocks: []ContextBlock,
    budget_plan: BudgetPlan,
    cache_hints: []CacheHint,
    preprocessor_intent: []const u8 = "",
    focus_directive: []const u8 = "",
    mcp_server_instructions: []const McpServerInstruction = &.{},
    /// Per-turn model-awareness skill listing (empty = none). Rendered as a
    /// <system-reminder name="zcode-skills"> section so the model discovers and
    /// invokes skills. See core/skills.renderModelListing.
    skills_listing: []const u8 = "",
    /// When true, omit the JSON response-contract section: the provider does
    /// native tool-calling, so telling the model to emit JSON is redundant and
    /// off-spec vs Claude Code (PRD #533). Set for native-capable providers.
    suppress_response_contract: bool = false,
};

pub const PromptEnvelopeOwned = struct {
    envelope: PromptEnvelope,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *PromptEnvelopeOwned) void {
        self.arena.deinit();
    }
};

pub const ToolInvocationRecord = struct {
    tool_name: []const u8,
    args_hash: u64,
    risk_tier: RiskTier,
    approval_state: ApprovalState,
    start_ts: i64,
    end_ts: i64,
    exit_status: i32,
};

pub const SessionSnapshot = struct {
    facts: []const []const u8,
    decisions: []const []const u8,
    open_tasks: []const []const u8,
    file_focus: []const []const u8,
    recent_tool_outcomes: []const []const u8,
    handoff_summary: []const u8,
    pinned_facts: []const []const u8 = &.{},
    completed_tasks: []const []const u8 = &.{},
    /// Number of conversation turns present at the moment this snapshot
    /// was written (sessions-08). On resume, checkResumeConsistency
    /// compares the count of loaded turns against this reference number
    /// and warns on drift (e.g. a rewind dropped turns from memory but
    /// the on-disk JSONL still replays them). 0 means "no count was
    /// recorded" -- legacy snapshots written before this field existed,
    /// or replay snapshots that pass 0 through appendSnapshot; the
    /// consistency check treats 0 as "skip, no reference available".
    message_count_at_snapshot: usize = 0,
    /// Names of conditional (`paths`-gated) skills that have matched a touched
    /// file at some point this session (skills-04 sticky activation). Once a
    /// skill is here it stays visible to the model even after the matching file
    /// leaves `file_focus`. Persisted on the snapshot so activation survives
    /// compaction and resume. Defaults to empty for legacy/replay snapshots.
    activated_conditional_skills: []const []const u8 = &.{},
};

pub const ModelInfo = struct {
    id: []const u8,
    provider: []const u8,
    context_window: usize,
};

pub const ReasoningEffort = enum {
    auto,
    low,
    medium,
    high,
    max,

    pub fn fromString(value: []const u8) ?ReasoningEffort {
        if (std.ascii.eqlIgnoreCase(value, "auto") or std.ascii.eqlIgnoreCase(value, "unset")) return .auto;
        if (std.ascii.eqlIgnoreCase(value, "low")) return .low;
        if (std.ascii.eqlIgnoreCase(value, "medium") or std.ascii.eqlIgnoreCase(value, "med")) return .medium;
        if (std.ascii.eqlIgnoreCase(value, "high")) return .high;
        if (std.ascii.eqlIgnoreCase(value, "max") or std.ascii.eqlIgnoreCase(value, "maximum")) return .max;
        return null;
    }

    pub fn toString(self: ReasoningEffort) []const u8 {
        return switch (self) {
            .auto => "auto",
            .low => "low",
            .medium => "medium",
            .high => "high",
            .max => "max",
        };
    }

    pub fn description(self: ReasoningEffort) []const u8 {
        return switch (self) {
            .auto => "let the provider pick the default for this model",
            .low => "fastest, cheapest; minimal reasoning",
            .medium => "balanced reasoning budget for most tasks",
            .high => "more reasoning, slower, better on hard problems",
            .max => "maximum reasoning (Opus-class models only)",
        };
    }

    /// Unicode circle glyph representing the effort level. Mirrors the
    /// EFFORT_LOW/MEDIUM/HIGH/MAX constants in Claude Code's
    /// src/constants/figures.ts: empty ring for low, half-fill for
    /// medium, full disc for high, bullseye for max. auto gets a
    /// dashed-circle hint so the user can tell it apart from an
    /// explicit choice at a glance.
    pub fn glyph(self: ReasoningEffort) []const u8 {
        return switch (self) {
            .auto => "\xe2\x97\x8c", // ◌ dotted circle
            .low => "\xe2\x97\x8b", // ○ white circle
            .medium => "\xe2\x97\x90", // ◐ left half black
            .high => "\xe2\x97\x8f", // ● black circle
            .max => "\xe2\x97\x89", // ◉ fisheye
        };
    }
};

pub const ModelRequest = struct {
    model: []const u8,
    system_prompt: []const u8 = "",
    prompt: []const u8,
    max_output_tokens: usize,
    temperature: f32 = 0.2,
    /// Optional context-window size to pass to the provider. Currently
    /// only the local (Ollama) adapter emits this as `num_ctx`; other
    /// providers fall back to their own defaults. 0 = omit (use the
    /// provider's default).
    context_window: usize = 0,
    cache_hints: []const CacheHint = &.{},
    tool_schemas: []const ToolSchema = &.{},
    /// Optional per-request reasoning effort override. `.auto` lets the
    /// provider adapter fall through to whatever the model's default is
    /// (or omit the field entirely). Anything else is threaded into the
    /// provider-specific request payload -- OpenAI o-series uses
    /// `reasoning_effort`, Anthropic uses extended_thinking budget bands.
    reasoning_effort: ReasoningEffort = .auto,
    /// Structured conversation history. Providers that support native
    /// multi-turn messages (OpenAI, Anthropic, Gemini) can use this to
    /// build proper role-alternating message arrays instead of relying
    /// on the flat text in `prompt`. The `prompt` field still contains
    /// the full conversation for providers that prefer text format.
    /// Empty by default for backwards compatibility.
    history: []const HistoryTurn = &.{},
    /// Optional tool-invocation constraint. When null (the default) the
    /// provider decides whether to call a tool. When non-null:
    ///   - "auto"  -- model may call any tool, may skip (provider default)
    ///   - "any"   -- model MUST call some tool this turn
    ///   - "none"  -- model MUST NOT call a tool this turn
    ///   - "<name>" -- model MUST call the tool named <name>
    /// Each provider adapter maps this to its own shape (OpenAI
    /// `tool_choice`, Anthropic `tool_choice`). Unsupported providers
    /// silently ignore the field.
    tool_choice: ?[]const u8 = null,
    /// Optional JSON schema the response body must conform to. When
    /// non-null, providers that support structured output constrain
    /// generation to valid JSON matching the schema. The string MUST
    /// be a valid JSON object literal (not quoted) -- it is embedded
    /// verbatim into the request body. OpenAI-style providers emit
    /// `response_format: {type:"json_schema", json_schema:{schema:<this>}}`.
    /// Providers without native support silently ignore the field;
    /// callers can still validate the returned JSON themselves.
    response_schema: ?[]const u8 = null,
    /// Optional human-readable name for the response_schema. Only used
    /// by providers that demand one (OpenAI requires a name on the
    /// json_schema object). Defaults to "zcode_response".
    response_schema_name: []const u8 = "zcode_response",
    /// Optional session correlation id. When non-empty, the provider
    /// adapter injects it as `X-Zcode-Session-Id` (zcode-namespaced analog
    /// of the reference's `X-Claude-Code-Session-Id`). Borrowed from the
    /// runtime's `session_id`; the adapter does not own it.
    session_id: []const u8 = "",
    /// Optional per-request correlation id. When non-empty, the provider
    /// adapter injects it as `x-client-request-id` (analog of the
    /// reference's per-request UUID header). Generated fresh per call.
    request_id: []const u8 = "",
    /// Optional caller-supplied custom request headers (from
    /// `ZCODE_CUSTOM_HEADERS`). Each entry is a fully-formed `Name: Value`
    /// header line. The provider adapter appends them to the curl header
    /// array verbatim. Empty by default. Borrowed; the adapter does not own.
    custom_headers: []const []const u8 = &.{},
    /// Optional native Anthropic context-management edits config. When
    /// non-null, the Anthropic adapter embeds it verbatim into the request
    /// body as the `context_management` field so the server clears old
    /// tool results / thinking blocks instead of zcode mutating history
    /// locally. The string MUST be a valid JSON object literal (not
    /// quoted) -- it is embedded verbatim, same contract as
    /// `response_schema` above. Built by `core/context_management.zig`
    /// (opt-in via env). Default null = omit the field entirely.
    /// Providers other than Anthropic ignore it. Borrowed; the adapter
    /// does not own.
    context_management: ?[]const u8 = null,
};

pub const ModelResponse = struct {
    raw: []const u8,
    text: []const u8,
    usage_input_tokens: usize,
    usage_output_tokens: usize,
    /// JSON string of native tool_calls from the API response (OpenAI format).
    /// Empty string if the model returned no native tool calls.
    tool_calls_json: []const u8 = "",
    /// True if the response was truncated due to hitting the max_output_tokens limit
    /// (API returned finish_reason: "length").
    truncated: bool = false,
    /// Concatenated `reasoning_content` chunks/fields from the API
    /// (kimi-k2.6, DeepSeek-R1, Qwen3-thinking). Lets the agent loop
    /// distinguish "model returned literally nothing" (auto-retry safe)
    /// from "model reasoned but produced no content" (don't auto-retry,
    /// surface a clearer message). Owned by the caller; empty = "".
    reasoning_text: []const u8 = "",
};

pub const ProviderConfig = struct {
    name: []const u8,
    api_key: ?[]const u8,
    base_url: ?[]const u8,
    timeout_ms: u32 = 60_000,
    retry_count: u8 = 2,
};

pub const ProviderAdapter = struct {
    name: []const u8,
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void,
        listModels: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]ModelInfo,
        send: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, request: ModelRequest) anyerror!ModelResponse,
        stream: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, request: ModelRequest) anyerror![]const u8,
        healthcheck: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void,
        stream_live: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, request: ModelRequest, chunk_cb: ?StreamChunkCallback) anyerror![]const u8 = null,
    };

    pub fn deinit(self: *ProviderAdapter, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ctx, allocator);
    }

    pub fn listModels(self: *ProviderAdapter, allocator: std.mem.Allocator) ![]ModelInfo {
        return self.vtable.listModels(self.ctx, allocator);
    }

    pub fn send(self: *ProviderAdapter, allocator: std.mem.Allocator, request: ModelRequest) !ModelResponse {
        return self.vtable.send(self.ctx, allocator, request);
    }

    pub fn stream(self: *ProviderAdapter, allocator: std.mem.Allocator, request: ModelRequest) ![]const u8 {
        return self.vtable.stream(self.ctx, allocator, request);
    }

    pub fn healthcheck(self: *ProviderAdapter, allocator: std.mem.Allocator) !void {
        return self.vtable.healthcheck(self.ctx, allocator);
    }

    pub fn streamLive(self: *ProviderAdapter, allocator: std.mem.Allocator, request: ModelRequest, chunk_cb: ?StreamChunkCallback) ![]const u8 {
        if (self.vtable.stream_live) |f| return f(self.ctx, allocator, request, chunk_cb);
        return self.vtable.stream(self.ctx, allocator, request);
    }
};

pub fn estimateTokens(text: []const u8) usize {
    if (text.len == 0) return 0;
    return @max(1, text.len / 4);
}

pub fn riskTierToString(tier: RiskTier) []const u8 {
    return switch (tier) {
        .LOW => "LOW",
        .MEDIUM => "MEDIUM",
        .HIGH => "HIGH",
        .BLOCKED => "BLOCKED",
    };
}

pub fn roleToString(role: HistoryRole) []const u8 {
    return switch (role) {
        .user => "user",
        .assistant => "assistant",
        .system => "system",
        .tool => "tool",
    };
}

const testing = std.testing;
test "BudgetPlan.init computes budget" {
    const plan = BudgetPlan.init(100_000, 10_000, 5_000);
    try testing.expectEqual(@as(usize, 85_000), plan.input_budget);
}
test "estimateTokens basic" {
    try testing.expectEqual(@as(usize, 0), estimateTokens(""));
    try testing.expectEqual(@as(usize, 1), estimateTokens("hi"));
}
test "riskTierToString" {
    try testing.expectEqualStrings("LOW", riskTierToString(.LOW));
}
test "roleToString" {
    try testing.expectEqualStrings("user", roleToString(.user));
}
test "ReasoningEffort.fromString parses canonical names" {
    try testing.expectEqual(@as(?ReasoningEffort, .auto), ReasoningEffort.fromString("auto"));
    try testing.expectEqual(@as(?ReasoningEffort, .auto), ReasoningEffort.fromString("unset"));
    try testing.expectEqual(@as(?ReasoningEffort, .low), ReasoningEffort.fromString("LOW"));
    try testing.expectEqual(@as(?ReasoningEffort, .medium), ReasoningEffort.fromString("medium"));
    try testing.expectEqual(@as(?ReasoningEffort, .medium), ReasoningEffort.fromString("Med"));
    try testing.expectEqual(@as(?ReasoningEffort, .high), ReasoningEffort.fromString("High"));
    try testing.expectEqual(@as(?ReasoningEffort, .max), ReasoningEffort.fromString("MAX"));
    try testing.expectEqual(@as(?ReasoningEffort, null), ReasoningEffort.fromString("bogus"));
}
test "ReasoningEffort.toString round-trips" {
    try testing.expectEqualStrings("low", ReasoningEffort.toString(.low));
    try testing.expectEqualStrings("max", ReasoningEffort.toString(.max));
}
