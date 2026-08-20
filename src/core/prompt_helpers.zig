const std = @import("std");
const std_io = @import("std_io.zig");
const clock = @import("clock.zig");
const types = @import("types.zig");
const config_mod = @import("config.zig");
const output_styles = @import("output_styles.zig");
const policy_mod = @import("../policy/policy.zig");
const tokenizer = @import("tokenizer.zig");
const memory = @import("memory.zig");
const memory_gate = @import("memory_gate.zig");
const memory_prompt = @import("memory_prompt.zig");
const session_date = @import("session_date.zig");
const platform = @import("platform.zig");
const system_prompt = @import("system_prompt.zig");
const rt = @import("zcode_runtime");

// ---------------------------------------------------------------------------
// History helpers
// ---------------------------------------------------------------------------

/// Phase 8 (compaction-16): wrap a compaction summary in a post-compact
/// continuation directive. The wrapper tells the model the session is being
/// continued from a conversation that ran out of context, points it at the
/// transcript for exact details when one is available, and (when
/// `suppress_questions` is set) instructs it to resume the last task directly
/// without re-acknowledging the summary or asking redundant questions.
///
/// Ported from claude-code-main/src/services/compact/prompt.ts:337-374
/// (`getCompactUserSummaryMessage`). The reference's proactive/autonomous-mode
/// variant is intentionally omitted: zcode has no proactive mode (see the
/// out-of-scope notes in the phase plan). The reference uses an em dash in
/// "Resume directly -"; per the project's no-long-dash rule we use a plain
/// space-hyphen-space here.
///
/// Caller owns the returned slice.
pub fn buildContinuationDirective(
    allocator: std.mem.Allocator,
    summary: []const u8,
    transcript_path: ?[]const u8,
    suppress_questions: bool,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    try out.writer().print(
        "This session is being continued from a previous conversation that ran out of context. The summary below covers the earlier portion of the conversation.\n\n{s}",
        .{summary},
    );

    if (transcript_path) |path| {
        try out.writer().print(
            "\n\nIf you need specific details from before compaction (like exact code snippets, error messages, or content you generated), read the full transcript at: {s}",
            .{path},
        );
    }

    if (suppress_questions) {
        try out.writer().writeAll(
            "\nContinue the conversation from where it left off without asking the user any further questions. " ++
                "Resume directly - do not acknowledge the summary, do not recap what was happening, do not preface with \"I'll continue\" or similar. " ++
                "Pick up the last task as if the break never happened.",
        );
    }

    return out.toOwnedSlice();
}

pub fn buildCompactedHistory(
    allocator: std.mem.Allocator,
    history: []const types.HistoryTurn,
    summary: []const u8,
    max_history_turns: usize,
) ![]types.HistoryTurn {
    const tail = history[@max(@as(usize, 0), history.len - @min(history.len, max_history_turns))..];

    const out = try allocator.alloc(types.HistoryTurn, tail.len + 1);
    // Phase 8 (compaction-16): the inserted summary turn now carries the full
    // continuation directive (resume-without-asking) instead of the bare
    // "compacted_summary:" prefix. `suppress_questions=true` is the
    // auto-compaction default; `transcript_path` is null here because the
    // per-turn prompt build does not thread the session transcript path through.
    const directive = try buildContinuationDirective(allocator, summary, null, true);
    out[0] = .{
        .role = .system,
        .content = directive,
        .timestamp = clock.nowSeconds(),
    };

    for (tail, 0..) |turn, idx| {
        out[idx + 1] = .{
            .role = turn.role,
            .content = try allocator.dupe(u8, turn.content),
            .timestamp = turn.timestamp,
        };
    }

    return out;
}

pub fn cloneHistoryTail(allocator: std.mem.Allocator, history: []const types.HistoryTurn, max_history_turns: usize) ![]types.HistoryTurn {
    const tail = history[@max(@as(usize, 0), history.len - @min(history.len, max_history_turns))..];
    const out = try allocator.alloc(types.HistoryTurn, tail.len);
    for (tail, 0..) |turn, idx| {
        out[idx] = .{
            .role = turn.role,
            .content = try allocator.dupe(u8, turn.content),
            .timestamp = turn.timestamp,
        };
    }
    return out;
}

// ---------------------------------------------------------------------------
// Clone helpers
// ---------------------------------------------------------------------------

pub fn cloneToolSchemas(allocator: std.mem.Allocator, tool_schemas: []const types.ToolSchema) ![]types.ToolSchema {
    const out = try allocator.alloc(types.ToolSchema, tool_schemas.len);
    for (tool_schemas, 0..) |tool, idx| {
        out[idx] = .{
            .name = try allocator.dupe(u8, tool.name),
            .description = try allocator.dupe(u8, tool.description),
            .json_schema = try allocator.dupe(u8, tool.json_schema),
            .usage_hint = try allocator.dupe(u8, tool.usage_hint),
        };
    }
    return out;
}

pub fn cloneSnapshot(allocator: std.mem.Allocator, snapshot: *const types.SessionSnapshot) !types.SessionSnapshot {
    return .{
        .facts = try cloneStringList(allocator, snapshot.facts),
        .decisions = try cloneStringList(allocator, snapshot.decisions),
        .open_tasks = try cloneStringList(allocator, snapshot.open_tasks),
        .file_focus = try cloneStringList(allocator, snapshot.file_focus),
        .recent_tool_outcomes = try cloneStringList(allocator, snapshot.recent_tool_outcomes),
        .handoff_summary = try allocator.dupe(u8, snapshot.handoff_summary),
        .pinned_facts = try cloneStringList(allocator, snapshot.pinned_facts),
        .completed_tasks = try cloneStringList(allocator, snapshot.completed_tasks),
        .activated_conditional_skills = try cloneStringList(allocator, snapshot.activated_conditional_skills),
    };
}

pub fn cloneStringList(allocator: std.mem.Allocator, input: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, input.len);
    for (input, 0..) |item, idx| {
        out[idx] = try allocator.dupe(u8, item);
    }
    return out;
}

// ---------------------------------------------------------------------------
// System policy rendering
// ---------------------------------------------------------------------------

pub fn renderSystemPolicy(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    policy: *const policy_mod.Policy,
    cwd: []const u8,
    user_turn: []const u8,
    output_style_name: []const u8,
    session_system_prompt: []const u8,
    preferred_language: []const u8,
    prompt_mode: types.PromptMode,
) ![]u8 {
    _ = cfg;
    _ = policy;
    _ = user_turn;
    _ = session_system_prompt;
    _ = preferred_language;
    _ = prompt_mode;

    // styles-onboarding-01: when a custom output style is active and does NOT
    // set `keep-coding-instructions: true`, the style fully replaces
    // coding-agent behavior, so the base "Doing tasks" section is omitted from
    // the static prefix. The default style and the built-in Explanatory/
    // Learning/Investigative styles keep it (they layer on top). Resolving the
    // flag here makes the static prefix vary by style; the prompt-cache
    // fingerprint hashes these bytes (hashStablePrefix) so it varies in lockstep
    // and never serves a stale prefix across styles. A resolve failure degrades
    // to keeping the base section (the safe default that matches today).
    const keep_coding = output_styles.keepCodingInstructions(allocator, cwd, output_style_name) catch true;
    return system_prompt.renderStaticPrefix(allocator, keep_coding);
}

pub fn renderDynamicSystemPolicy(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    policy: *const policy_mod.Policy,
    cwd: []const u8,
    user_turn: []const u8,
    output_style_name: []const u8,
    session_system_prompt: []const u8,
    preferred_language: []const u8,
    prompt_mode: types.PromptMode,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    var resolved_style = try output_styles.resolve(allocator, cwd, output_style_name);
    defer resolved_style.deinit(allocator);

    try out.writer().writeAll(system_prompt.SYSTEM_PROMPT_DYNAMIC_BOUNDARY);

    // Deferred-tool advisory: list the names of every builtin tool
    // whose full schema is NOT in this turn's tool registry. The
    // model fetches the schema on demand via ToolSearch. Saves ~half
    // the per-turn tool-schema input tokens without losing access to
    // the long-tail tools (MCP family, Task family, etc.).
    {
        const tool_schemas = @import("../tools/tool_schemas.zig");
        const deferred_names = tool_schemas.renderDeferredToolNamesList(allocator) catch try allocator.dupe(u8, "");
        defer allocator.free(deferred_names);
        if (deferred_names.len > 0) {
            try out.writer().print(
                "\n# Deferred tools\n" ++
                    "These tool names exist but their schemas are NOT loaded this turn. Call ToolSearch with the name (e.g. ToolSearch(query=\"select:TaskCreate\")) to fetch the schema before invoking the tool. List: {s}\n",
                .{deferred_names},
            );
        }
    }

    var os_buf: [192]u8 = undefined;
    try out.writer().print(
        "# Environment\nToday's date is {s}.\ncwd={s}\nplatform={s}\nos_version={s}\nshell={s}\nmodel={s}/{s}\n",
        .{
            session_date.getSessionStartDate(),
            cwd,
            platform.detect().toString(),
            platform.writeOsVersion(&os_buf),
            platform.shellBasename(),
            cfg.default_provider,
            cfg.default_model,
        },
    );

    const detected_vcs = platform.detectVcs(allocator, cwd) catch |err| blk: {
        std.log.debug("prompt: vcs detection failed: {s}", .{@errorName(err)});
        break :blk try allocator.alloc(platform.Vcs, 0);
    };
    defer allocator.free(detected_vcs);
    if (detected_vcs.len > 0) {
        try out.writer().writeAll("vcs=");
        for (detected_vcs, 0..) |vcs, idx| {
            if (idx > 0) try out.writer().writeByte(',');
            try out.writer().writeAll(vcs.toString());
        }
        try out.writer().writeByte('\n');
    }

    try out.writer().print(
        "approval_mode={s}\n" ++
            "sandbox={s}\n" ++
            "allow_network={}\n" ++
            "block_destructive_shell={}\n",
        .{
            cfg.approval_mode,
            cfg.sandbox,
            policy.allow_network,
            policy.block_destructive_shell,
        },
    );

    // Empty-workspace advisory: when the cwd has no source files,
    // tell the model in imperative, high-prominence language. The
    // previous passive note ("workspace_state=empty / ... do NOT
    // run GitStatus") was ignored by kimi-k2.6 -- screenshots 2026-
    // 05-16 13:53 and 2026-05-17 21:20 both show the model running
    // ListDir / GitStatus / Bash ls on an empty workspace, then
    // returning empty content when it realizes there's nothing
    // there. A SYSTEM-REMINDER block with prohibition language and
    // intent-specific routing changes that behavior.
    // PRD #533: the per-prompt "DETECTED INTENT" routing was dropped (it was a
    // zcode-only steering addition with no Claude Code equivalent). The
    // empty-workspace prohibition is kept -- it prevents the model from burning
    // a turn searching a workspace that has no source files.
    if (workspaceIsEffectivelyEmpty(cwd)) {
        try out.writer().writeAll(
            "\n<system-reminder>\n" ++
                "EMPTY-WORKSPACE PROTOCOL ACTIVE.\n" ++
                "The current working directory has no source files (only scratch dirs like wiki/, notes/, .git/, .zcode/, or a README). There is NOTHING to discover with repository-search tools.\n" ++
                "\n" ++
                "FORBIDDEN on this turn (and every turn until source files exist):\n" ++
                "  - GitStatus, GitDiff, GitLog\n" ++
                "  - Grep, Glob, ListDir, Stat, Read on workspace paths\n" ++
                "  - Bash commands like `ls`, `find`, `cat`, `grep`, `tree`\n" ++
                "These tools WILL return nothing on this workspace and waste tokens. Calling them is a hard failure of the protocol.\n" ++
                "\n" ++
                "REQUIRED on this turn -- pick exactly one:\n" ++
                "  (a) BUILD: call Write to create the first project file (manifest + entry point).\n" ++
                "  (b) RESEARCH: call WebFetch / WebSearch for any external API or library named in the user prompt.\n" ++
                "  (c) CLARIFY: call AskUserQuestion ONCE with concrete options if a required design choice is genuinely missing.\n" ++
                "</system-reminder>\n",
        );
    }
    try out.writer().print("output_style={s}\n", .{resolved_style.name});
    if (resolved_style.prompt.len > 0) {
        try out.writer().print("output_style_prompt:\n{s}\n", .{resolved_style.prompt});
    }

    try out.writer().writeAll(
        "\n# Execution continuity\n" ++
            "Every user prompt includes current working context, recent tool outcomes, and conversation history below. Use that context before asking follow-up questions.\n" ++
            "If the user approved a recommendation, said continue, or said implement, do not stop after announcing intent. Call the required Read/Edit/Write/Bash/Todo tools in the same response. Intent without a matching tool call is incomplete execution.\n" ++
            "If you need to mutate files, move from inspection to Edit/Write/MultiEdit as soon as the target and exact change are known. Avoid repeated read-only loops unless the next read answers a specific missing fact.\n" ++
            "Important facts from tool results may be compacted or budgeted away later. Preserve decisions, blockers, file paths, and verification outcomes in your assistant message or task state.\n",
    );

    if (cfg.append_system_prompt.len > 0) {
        try out.writer().print("operator_append_system_prompt:\n{s}\n", .{cfg.append_system_prompt});
    }
    if (session_system_prompt.len > 0) {
        try out.writer().print("session_append_system_prompt:\n{s}\n", .{session_system_prompt});
    }

    const effective_language: []const u8 = if (preferred_language.len > 0)
        preferred_language
    else
        cfg.preferred_language;
    if (effective_language.len > 0) {
        try out.writer().print(
            "\n# Language\nAlways respond in {s}. Use {s} for all explanations, comments, and communications with the user. Technical terms and code identifiers should remain in their original form.\n",
            .{ effective_language, effective_language },
        );
    }

    // Gate the recalled-memory render on the auto-memory gate (memory-10).
    // When auto-memory is disabled (--bare, ZCODE_DISABLE_AUTO_MEMORY, or an
    // explicit auto_memory_enabled=false setting), skip loading and rendering
    // persistent memory so those users do not pay the input-token cost.
    if (memory_gate.isAutoMemoryEnabled(cfg)) {
        // memory-02: emit the four-type taxonomy + save-instruction block once
        // per turn, before the recalled-memory render. This is additive
        // educational text that teaches the model when/how to write memories;
        // the recalled-memory block below is the relevance-selected content.
        // Best-effort: a failure here must not abort the whole prompt build.
        if (memory_gate.getAutoMemPath(allocator, cfg)) |auto_mem_dir| {
            defer allocator.free(auto_mem_dir);
            if (memory_prompt.buildMemoryLines(allocator, auto_mem_dir)) |taxonomy| {
                defer allocator.free(taxonomy);
                try out.writer().print("\n{s}\n", .{taxonomy});
            } else |err| {
                std.log.debug("prompt: memory taxonomy build failed: {s}", .{@errorName(err)});
            }

            // memory-04 + memory-11: always load the per-project MEMORY.md index
            // into the system prompt, enforcing the 200-line / 25000-byte dual
            // cap with a named-cap truncation warning. This is a distinct
            // surface from the recalled per-entry memories below: the index is
            // the curated always-loaded pointer file; the per-entry render is
            // the relevance-selected detail. Best-effort: a read/build failure
            // must not abort the whole prompt build.
            renderMemoryIndex(allocator, &out, auto_mem_dir) catch |err| {
                std.log.debug("prompt: MEMORY.md index render failed: {s}", .{@errorName(err)});
            };
        } else |err| {
            std.log.debug("prompt: auto-mem path resolve failed: {s}", .{@errorName(err)});
        }

        const memories = memory.loadAllWithWorkspace(allocator, cwd) catch |err| blk: {
            std.log.debug("prompt: memory load failed: {s}", .{@errorName(err)});
            break :blk try allocator.alloc(memory.MemoryEntry, 0);
        };
        defer {
            for (memories) |*e| {
                var entry = e.*;
                entry.deinit(allocator);
            }
            allocator.free(memories);
        }
        if (memories.len > 0) {
            // memory-03: the deterministic keyword scorer is the offline/no-network
            // default. The optional Sonnet relevance selector (memory_relevance.zig)
            // layers on top of this at call sites that have a provider handle and
            // network allowed; it is never the only path. Cap raised from 4 to 5 to
            // match the reference's "up to 5" selection size.
            const mem_text = memory.renderRelevantForPrompt(allocator, memories, user_turn, 5) catch "";
            defer if (mem_text.len > 0) allocator.free(mem_text);
            if (mem_text.len > 0) {
                try out.writer().print("\n{s}", .{mem_text});
            }
        }
    }

    if (prompt_mode == .planning) {
        try out.writer().writeAll(
            "\n# Plan mode\n" ++
                "PLAN MODE IS ACTIVE. The user has NOT authorised execution yet. You MUST NOT make any file edits, run mutating shell commands, change configs, create commits, or otherwise alter system state. This supersedes any other instruction. Use read-only tools (Read, Glob, Grep, Bash with read-only commands) to gather information, then produce a concrete plan for the user to review and approve.\n" ++
                "\n" ++
                "Your final assistant message in this turn MUST be a plan in markdown with the following sections, in this exact order:\n" ++
                "\n" ++
                "# Overview\n" ++
                "One paragraph describing what the user asked for and the approach you are proposing.\n" ++
                "\n" ++
                "# Files to touch\n" ++
                "A bulleted list of files you will create, modify, or delete, each with a one-line purpose. Use concrete paths rooted at the workspace; no globs.\n" ++
                "\n" ++
                "# Steps\n" ++
                "A numbered list of concrete execution steps. Each step names a tool (Edit, Write, Bash, RunTests, etc.) and the observable effect. Keep steps minimal -- one purpose per step.\n" ++
                "\n" ++
                "# Verification\n" ++
                "How you will prove the change works after execution: exact commands, tests to run, or diffs/results to inspect. If verification is impossible state why.\n" ++
                "\n" ++
                "# Risks\n" ++
                "Short list of things that could go wrong, plus the mitigation for each. Include irreversible steps and external effects (pushes, deploys, PR creation).\n" ++
                "\n" ++
                "Keep the plan tight -- aim for under 600 words total. Do NOT start executing; the user will review and approve separately. If you need more information before planning, ask ONE concrete question via AskUserQuestion. Do NOT re-plan or restate the plan across turns; produce it once per turn.\n",
        );
    } else if (prompt_mode == .brainstorm) {
        try out.writer().writeAll(
            "\n# Brainstorm mode\n" ++
                "BRAINSTORM MODE is active. The user wants discussion, not execution. Do not use mutating tools. Offer options, trade-offs, and questions. When the user converges on an approach, say so explicitly and zcode will promote the session to planning mode.\n",
        );
    } else if (prompt_mode == .review) {
        try out.writer().writeAll(
            "\n# Review mode\n" ++
                "REVIEW MODE IS ACTIVE. Use read-only tools only. Do NOT edit files, run mutating commands, create commits, or change repository state. Review the target like a code reviewer: prioritize correctness bugs, behavioral regressions, missing tests, security risks, and risky assumptions. Findings must come first, ordered by severity, and grounded in file:line references when available. Keep summaries secondary. If you find no issues, say that explicitly and mention residual test gaps or risk.\n",
        );
    }

    return out.toOwnedSlice();
}

/// Read `<auto_mem_dir>/MEMORY.md`, apply the dual line/byte cap
/// (memory_prompt.truncateEntrypoint), and emit a `## MEMORY.md` section into
/// `out`. When the file is absent or empty, emit the "currently empty"
/// fallback so the model knows the index exists and where new memories land.
///
/// memory-04 + memory-11. Best-effort: the caller swallows any error.
fn renderMemoryIndex(
    allocator: std.mem.Allocator,
    out: *std_io.StringBuilder,
    auto_mem_dir: []const u8,
) !void {
    const index_path = try std.fs.path.join(allocator, &.{ auto_mem_dir, memory_prompt.ENTRYPOINT_NAME });
    defer allocator.free(index_path);

    // Read with a generous cap (256KB > the 25KB byte ceiling, so the byte cap
    // can always fire on the read content). On StreamTooLong (file even larger)
    // re-read a bounded window so the index is still loaded-as-truncated rather
    // than dropped entirely.
    const raw: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(rt.io, index_path, allocator, .limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        error.StreamTooLong => blk: {
            // File exceeds 256KB; read just past the byte cap so
            // truncateEntrypoint flags it as byte-truncated.
            break :blk std.Io.Dir.cwd().readFileAlloc(rt.io, index_path, allocator, .limited(memory_prompt.MAX_ENTRYPOINT_BYTES + 1)) catch null;
        },
        else => return err,
    };
    defer if (raw) |r| allocator.free(r);

    const trimmed_len = if (raw) |r| std.mem.trim(u8, r, " \t\r\n").len else 0;
    if (raw == null or trimmed_len == 0) {
        try out.writer().print(
            "\n## {s}\n\nYour {s} is currently empty. When you save new memories, they will appear here.\n",
            .{ memory_prompt.ENTRYPOINT_NAME, memory_prompt.ENTRYPOINT_NAME },
        );
        return;
    }

    const t = try memory_prompt.truncateEntrypoint(allocator, raw.?);
    defer allocator.free(t.content);
    try out.writer().print("\n## {s}\n\n{s}\n", .{ memory_prompt.ENTRYPOINT_NAME, t.content });
}

// ---------------------------------------------------------------------------
// Token estimation
// ---------------------------------------------------------------------------

pub fn estimateFixedPromptTokens(
    provider: []const u8,
    model: []const u8,
    system_policy: []const u8,
    user_turn: []const u8,
    instruction_stack: []const types.InstructionEntry,
    history: []const types.HistoryTurn,
    tool_schemas: []const types.ToolSchema,
) usize {
    var total = tokenizer.estimateText(provider, model, system_policy) +
        tokenizer.estimateText(provider, model, user_turn);

    for (instruction_stack) |entry| {
        total += tokenizer.estimateText(provider, model, entry.content);
    }
    for (history) |turn| {
        total += tokenizer.estimateText(provider, model, turn.content);
    }
    for (tool_schemas) |tool| {
        total += tokenizer.estimateText(provider, model, tool.name);
        total += tokenizer.estimateText(provider, model, tool.description);
        total += tokenizer.estimateText(provider, model, tool.json_schema);
    }

    return total;
}

pub fn promptMentionsAny(prompt: []const u8, cues: []const []const u8) bool {
    for (cues) |cue| {
        if (containsIgnoreCase(prompt, cue)) return true;
    }
    return false;
}

pub fn shouldEncourageTaskTracking(prompt: []const u8) bool {
    if (prompt.len > 140) return true;
    return promptMentionsAny(prompt, &.{
        "implement",
        "refactor",
        "investigate",
        "configure",
        "set up",
        "setup",
        "migrate",
        "audit",
        "end-to-end",
        "across",
        "multiple",
    });
}

pub const SubagentAssessment = struct {
    /// Matches the number of builtin specialist agents (explore, plan, verify, reviewer).
    const max_recommendations = 4;

    should_encourage: bool,
    recommended: [max_recommendations]?RecommendedAgent,

    pub const RecommendedAgent = struct {
        name: []const u8,
        rationale: []const u8,
    };
};

pub fn assessSubagentNeed(prompt: []const u8) SubagentAssessment {
    var score: u16 = 0;
    var rec_idx: usize = 0;
    var recommended: [SubagentAssessment.max_recommendations]?SubagentAssessment.RecommendedAgent = .{ null, null, null, null };

    // Signal 1: Prompt length as complexity proxy
    if (prompt.len > 400) score += 30 else if (prompt.len > 200) score += 15;

    // Signal 2: Multiple independent targets
    if (promptMentionsAny(prompt, &.{ "and also", "additionally", "separately", "as well as", "both" }))
        score += 25;

    // Signal 3: Explicit parallelism cues
    if (promptMentionsAny(prompt, &.{ "in parallel", "independent", "split up", "concurrently" }))
        score += 40;

    // Signal 4: Cross-cutting investigation
    if (promptMentionsAny(prompt, &.{ "across files", "across modules", "across directories", "multiple subsystems", "investigate deeply", "compare" })) {
        score += 30;
        if (rec_idx < SubagentAssessment.max_recommendations) {
            recommended[rec_idx] = .{ .name = "explore", .rationale = "cross-cutting investigation" };
            rec_idx += 1;
        }
    }

    // Signal 5: Review/audit cues
    if (promptMentionsAny(prompt, &.{ "review", "check for bugs", "audit", "validate" })) {
        if (rec_idx < SubagentAssessment.max_recommendations) {
            recommended[rec_idx] = .{ .name = "reviewer", .rationale = "code quality validation" };
            rec_idx += 1;
        }
    }

    // Signal 6: Planning + execution combined
    if (promptMentionsAny(prompt, &.{ "plan and implement", "design and build", "architect and code" })) {
        score += 20;
        if (rec_idx < SubagentAssessment.max_recommendations) {
            recommended[rec_idx] = .{ .name = "plan", .rationale = "pre-implementation planning" };
            rec_idx += 1;
        }
    }

    // Signal 7: Implementation + verification combined
    if (promptMentionsAny(prompt, &.{ "implement", "fix", "refactor" }) and
        promptMentionsAny(prompt, &.{ "test", "verify", "ensure", "confirm" }))
    {
        if (rec_idx < SubagentAssessment.max_recommendations) {
            recommended[rec_idx] = .{ .name = "verify", .rationale = "post-implementation validation" };
            rec_idx += 1;
        }
    }

    const threshold: u16 = 40;
    return .{
        .should_encourage = score >= threshold,
        .recommended = recommended,
    };
}

pub fn shouldEncourageSubagents(prompt: []const u8) bool {
    return assessSubagentNeed(prompt).should_encourage;
}

pub fn shouldEncourageVerification(prompt: []const u8) bool {
    return promptMentionsAny(prompt, &.{
        "fix",
        "implement",
        "update",
        "change",
        "refactor",
        "configure",
        "set up",
        "setup",
        "repair",
        "debug",
        "add",
        "remove",
    });
}

pub const containsIgnoreCase = @import("parse_helpers.zig").containsIgnoreCase;

/// True when `prompt` reads like a request to BUILD or CREATE a new
/// project from scratch. Drives the empty-workspace system reminder
/// toward path (a): start writing files immediately. Word-boundary
/// matched against a small list of verbs + nouns to avoid false
/// positives on prompts that merely mention building (e.g. "explain
/// how the build system works").
pub fn isBuildOrCreateRequest(prompt: []const u8) bool {
    const verbs = [_][]const u8{
        "create ",      "build ",        "make ",     "scaffold ",
        "bootstrap ",   "set up ",       "set-up ",   "setup ",
        "implement ",   "write ",        "generate ", "spin up ",
        "let's build ", "let's create ",
    };
    const nouns = [_][]const u8{
        " app",     " cli",     " api",     " server", " service", " tool",
        " website", " project", " library", " module", " package", " bot",
        " script",  " agent",   " daemon",  " sdk",
    };
    var has_verb = false;
    for (verbs) |v| if (containsIgnoreCase(prompt, v)) {
        has_verb = true;
        break;
    };
    if (!has_verb) return false;
    for (nouns) |n| if (containsIgnoreCase(prompt, n)) return true;
    return false;
}

/// True when `prompt` references an external API / library / service
/// by name -- a strong cue that the model should reach for WebFetch
/// before scribbling client code. Heuristic: presence of either an
/// explicit API/SDK noun or a known third-party brand. Conservative;
/// false negatives are fine since the empty-workspace block lists
/// (b) as one of three options regardless.
pub fn isResearchRequest(prompt: []const u8) bool {
    const cues = [_][]const u8{
        " api",     " sdk",       " endpoint", " docs",
        " openapi", " graphql",   " rest",
        // Common third-party services users build clients for. Not
        // exhaustive -- this list errs toward common dev requests.
            "partiful",
        "stripe",   "twilio",     "github",    "slack",
        "discord",  "notion",     "linear",    "jira",
        "asana",    "supabase",   "firebase",  "vercel",
        "netlify",  "cloudflare", "anthropic", "openai",
        "moonshot", "gemini",
    };
    for (cues) |c| if (containsIgnoreCase(prompt, c)) return true;
    return false;
}

/// True when `cwd` contains no buildable source files. Detection is
/// source-aware rather than entry-aware: a workspace counts as empty
/// even if it has scratch dirs like wiki/, notes/, docs/, .git/,
/// .zcode/, or a top-level README, because the model still needs to
/// CREATE the actual project from scratch.
///
/// A workspace is "non-empty" iff at least one top-level entry is
/// either:
///   * a known project-manifest filename (package.json, go.mod,
///     Cargo.toml, mix.exs, build.zig, pyproject.toml, ...), or
///   * a file with a recognized source-code extension (.zig, .rs,
///     .go, .py, .ts, .tsx, .js, .jsx, .ex, .exs, .swift, ...), or
///   * a directory that itself contains source files (src/, lib/,
///     app/, internal/, cmd/, pkg/, components/).
///
/// Conservative on errors: any access failure returns `false`, so we
/// never claim "empty" when we cannot prove it.
pub fn workspaceIsEffectivelyEmpty(cwd: []const u8) bool {
    var dir = if (std.fs.path.isAbsolute(cwd))
        std.Io.Dir.openDirAbsolute(rt.io, cwd, .{ .iterate = true }) catch return false
    else
        std.Io.Dir.cwd().openDir(rt.io, cwd, .{ .iterate = true }) catch return false;
    defer dir.close(rt.io);

    // Directory names treated as "scratch": they hold notes/docs/
    // build output, never source the model can use to act. If the
    // top level is ONLY these dirs (plus dotfiles + README), the
    // workspace is empty for build-or-research purposes.
    const scratch_subdirs = [_][]const u8{
        "wiki",    "notes",  "docs", "documentation",
        "scratch", "tmp",    "temp", "build",
        "dist",    "target", "out",  "bin",
    };

    var it = dir.iterate();
    while (it.next(rt.io) catch return false) |entry| {
        // Skip hidden / dotfiles
        if (entry.name.len > 0 and entry.name[0] == '.') continue;

        if (entry.kind == .file) {
            // README is the canonical "blank slate" file -- ignore it.
            if (std.ascii.eqlIgnoreCase(entry.name, "README.md") or
                std.ascii.eqlIgnoreCase(entry.name, "README") or
                std.ascii.eqlIgnoreCase(entry.name, "LICENSE") or
                std.ascii.eqlIgnoreCase(entry.name, "LICENSE.md"))
                continue;
            // Any other file (manifest, source, even scratch .txt
            // data) is a real signal the workspace has content.
            return false;
        }

        if (entry.kind == .directory) {
            // Scratch / build-output dirs do NOT count as source.
            var is_scratch = false;
            for (scratch_subdirs) |s| {
                if (std.mem.eql(u8, entry.name, s)) {
                    is_scratch = true;
                    break;
                }
            }
            if (is_scratch) continue;
            // Any other directory (src/, lib/, the user's own
            // project subdir) is a real signal.
            return false;
        }

        // Symlinks, fifos, etc. -> ignore.
    }
    return true;
}

// ---------------------------------------------------------------------------
// Context scoring and sorting
// ---------------------------------------------------------------------------

pub const ContextSortCtx = struct {
    user_turn: []const u8,
    hints: ?*const types.PreprocessorHints = null,
};

pub fn contextCandidateLessThan(ctx: ContextSortCtx, a: types.ContextBlock, b: types.ContextBlock) bool {
    const a_score = contextScore(ctx.user_turn, a, ctx.hints);
    const b_score = contextScore(ctx.user_turn, b, ctx.hints);
    if (a_score != b_score) return a_score > b_score;
    if (a.priority != b.priority) return a.priority > b.priority;
    if (a.freshness != b.freshness) return a.freshness > b.freshness;
    if (a.token_estimate != b.token_estimate) return a.token_estimate < b.token_estimate;
    return std.mem.lessThan(u8, a.id, b.id);
}

pub fn contextScore(user_turn: []const u8, block: types.ContextBlock, hints: ?*const types.PreprocessorHints) usize {
    var score: usize = @as(usize, block.priority) * 100;
    var terms = std.mem.tokenizeAny(u8, user_turn, " \t\r\n,;:()[]{}");
    while (terms.next()) |term| {
        if (term.len < 3) continue;
        if (std.mem.indexOf(u8, block.id, term) != null or std.mem.indexOf(u8, block.content, term) != null) {
            score += 12;
        }
    }
    if (hints) |h| {
        for (h.context_scores) |cs| {
            if (std.mem.eql(u8, cs.block_id, block.id)) {
                score += @as(usize, cs.relevance) * 15;
                break;
            }
        }
    }
    return score;
}

// ---------------------------------------------------------------------------
// Hashing helpers
// ---------------------------------------------------------------------------

pub fn hashStablePrefix(
    system_policy: []const u8,
    instruction_stack: []const types.InstructionEntry,
    tool_schemas: []const types.ToolSchema,
) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(system_policy);
    hasher.update("\x1e");

    for (instruction_stack) |entry| {
        hasher.update(entry.source);
        hasher.update("\x1f");
        hasher.update(std.mem.asBytes(&entry.precedence));
        hasher.update(std.mem.asBytes(&entry.scope_distance));
        hasher.update(std.mem.asBytes(&entry.import_depth));
        hasher.update(entry.content);
        hasher.update("\x1e");
    }

    for (tool_schemas) |tool| {
        hasher.update(tool.name);
        hasher.update("\x1f");
        hasher.update(tool.description);
        hasher.update("\x1f");
        hasher.update(tool.json_schema);
        hasher.update("\x1e");
    }
    return hasher.final();
}

pub fn hashHistory(history: []const types.HistoryTurn) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (history) |turn| {
        hasher.update(std.mem.asBytes(&turn.role));
        hasher.update(turn.content);
        hasher.update(std.mem.asBytes(&turn.timestamp));
        hasher.update("\x1e");
    }
    return hasher.final();
}

pub fn hashContext(context_blocks: []const types.ContextBlock) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (context_blocks) |block| {
        hasher.update(block.id);
        hasher.update(std.mem.asBytes(&block.priority));
        hasher.update(std.mem.asBytes(&block.token_estimate));
        hasher.update(std.mem.asBytes(&block.freshness));
        hasher.update("\x1e");
    }
    return hasher.final();
}

// ---------------------------------------------------------------------------
// Cache hint building
// ---------------------------------------------------------------------------

pub fn buildCacheHints(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    system_policy: []const u8,
    instruction_stack: []const types.InstructionEntry,
    tool_schemas: []const types.ToolSchema,
    history: []const types.HistoryTurn,
    context_blocks: []const types.ContextBlock,
) ![]types.CacheHint {
    if (!cfg.prompt_cache_hints_enabled) {
        return allocator.alloc(types.CacheHint, 0);
    }

    const prefix_hash = hashStablePrefix(system_policy, instruction_stack, tool_schemas);
    const history_hash = hashHistory(history);
    const context_hash = hashContext(context_blocks);

    // Each allocation gets its own errdefer so any later step failing
    // unwinds everything allocated so far. Previously a failure on
    // `history_key` or `context_key` or the final `alloc(CacheHint)`
    // would leak the earlier format-string keys.
    const prefix_key = try std.fmt.allocPrint(
        allocator,
        "prefix:{s}:{s}:{x}",
        .{ cfg.default_provider, cfg.default_model, prefix_hash },
    );
    errdefer allocator.free(prefix_key);
    const history_key = try std.fmt.allocPrint(allocator, "history:{x}", .{history_hash});
    errdefer allocator.free(history_key);
    const context_key = try std.fmt.allocPrint(allocator, "context:{x}", .{context_hash});
    errdefer allocator.free(context_key);

    const hints = try allocator.alloc(types.CacheHint, 3);
    hints[0] = .{ .key = prefix_key, .ttl_seconds = 3600 };
    hints[1] = .{ .key = history_key, .ttl_seconds = 1200 };
    hints[2] = .{ .key = context_key, .ttl_seconds = 600 };
    return hints;
}

// ---------------------------------------------------------------------------
// Context source name mapping
// ---------------------------------------------------------------------------

pub fn contextSourceName(source: types.ContextSource) []const u8 {
    return switch (source) {
        .git_status => "git_status",
        .git_diff => "git_diff",
        .repo_map => "repo_map",
        .user_file => "user_file",
        .tool_result => "tool_result",
        .session_memory => "session_memory",
        .instruction => "instruction",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "contextScore gives higher score to higher priority" {
    const a = types.ContextBlock{
        .id = "high",
        .source_type = .repo_map,
        .priority = 10,
        .token_estimate = 5,
        .content = "hello",
        .freshness = 0,
    };
    const b = types.ContextBlock{
        .id = "low",
        .source_type = .repo_map,
        .priority = 1,
        .token_estimate = 5,
        .content = "world",
        .freshness = 0,
    };
    const sa = contextScore("query", a, null);
    const sb = contextScore("query", b, null);
    try testing.expect(sa > sb);
}

test "hashHistory deterministic" {
    const turns = [_]types.HistoryTurn{
        .{ .role = .user, .content = "hello", .timestamp = 42 },
    };
    const h1 = hashHistory(turns[0..]);
    const h2 = hashHistory(turns[0..]);
    try testing.expectEqual(h1, h2);
}

test "cloneStringList round-trips" {
    const allocator = testing.allocator;
    const input = [_][]const u8{ "alpha", "beta" };
    const cloned = try cloneStringList(allocator, input[0..]);
    defer {
        for (cloned) |s| allocator.free(s);
        allocator.free(cloned);
    }
    try testing.expectEqual(@as(usize, 2), cloned.len);
    try testing.expectEqualStrings("alpha", cloned[0]);
    try testing.expectEqualStrings("beta", cloned[1]);
}

test "contextSourceName returns correct strings" {
    try testing.expectEqualStrings("git_status", contextSourceName(.git_status));
    try testing.expectEqualStrings("repo_map", contextSourceName(.repo_map));
    try testing.expectEqualStrings("instruction", contextSourceName(.instruction));
}

test "renderSystemPolicy keeps dynamic session fields out of static policy" {
    const allocator = testing.allocator;

    var cfg = try config_mod.Config.init(allocator);
    defer cfg.deinit(allocator);

    var policy = try policy_mod.Policy.init(allocator);
    defer policy.deinit();

    const rendered = try renderSystemPolicy(
        allocator,
        &cfg,
        &policy,
        "/tmp/zcode-test",
        "hello",
        "default",
        "",
        "",
        .execution,
    );
    defer allocator.free(rendered);

    // PRD #533: static policy is now the Claude Code verbatim sections.
    try testing.expect(std.mem.indexOf(u8, rendered, "# System") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "# Doing tasks") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "# Executing actions with care") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "# Using your tools") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "# Tone and style") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "use Read instead of cat") != null);
    // The point of this test: per-turn dynamic fields must NOT be in the
    // cacheable static policy.
    try testing.expect(std.mem.indexOf(u8, rendered, "cwd=") == null);
    try testing.expect(std.mem.indexOf(u8, rendered, "approval_mode=") == null);
    try testing.expect(std.mem.indexOf(u8, rendered, "# Language\n") == null);
    try testing.expect(std.mem.indexOf(u8, rendered, "PLAN MODE IS ACTIVE") == null);
}

test "renderSystemPolicy keeps the Doing tasks section for the default style" {
    // styles-onboarding-01 regression guard: the default style must produce the
    // base coding section so the no-style path is byte-stable with today.
    const allocator = testing.allocator;

    var cfg = try config_mod.Config.init(allocator);
    defer cfg.deinit(allocator);
    var policy = try policy_mod.Policy.init(allocator);
    defer policy.deinit();

    const rendered = try renderSystemPolicy(
        allocator,
        &cfg,
        &policy,
        "/tmp/zcode-test",
        "hello",
        "default",
        "",
        "",
        .execution,
    );
    defer allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "# Doing tasks") != null);
}

test "renderSystemPolicy keeps the Doing tasks section for the explanatory builtin" {
    // Explanatory/Learning layer on top of coding behavior, so the base section
    // stays.
    const allocator = testing.allocator;

    var cfg = try config_mod.Config.init(allocator);
    defer cfg.deinit(allocator);
    var policy = try policy_mod.Policy.init(allocator);
    defer policy.deinit();

    const rendered = try renderSystemPolicy(
        allocator,
        &cfg,
        &policy,
        "/tmp/zcode-test",
        "hello",
        "explanatory",
        "",
        "",
        .execution,
    );
    defer allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "# Doing tasks") != null);
}

test "renderSystemPolicy omits the Doing tasks section for a replacing custom style" {
    // styles-onboarding-01: a custom workspace style with no
    // keep-coding-instructions frontmatter fully replaces coding behavior, so
    // the base "Doing tasks" section is dropped from the static prefix. The
    // other shared sections remain.
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(rt.io, "repo/.zcode/output-styles");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "repo/.zcode/output-styles/replacer.md",
        .data = "---\n" ++
            "description: Fully replaces coding behavior\n" ++
            "---\n\n" ++
            "You are now a different kind of assistant.\n",
    });
    const cwd = try @import("test_helpers.zig").tmpDirPath(allocator, &tmp, "repo");
    defer allocator.free(cwd);

    var cfg = try config_mod.Config.init(allocator);
    defer cfg.deinit(allocator);
    var policy = try policy_mod.Policy.init(allocator);
    defer policy.deinit();

    const rendered = try renderSystemPolicy(
        allocator,
        &cfg,
        &policy,
        cwd,
        "hello",
        "replacer",
        "",
        "",
        .execution,
    );
    defer allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "# Doing tasks") == null);
    // The rest of the cacheable prefix is unaffected.
    try testing.expect(std.mem.indexOf(u8, rendered, "# System") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "# Executing actions with care") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "# Tone and style") != null);
}

test "renderDynamicSystemPolicy injects Today's date into the prompt" {
    const allocator = testing.allocator;

    var cfg = try config_mod.Config.init(allocator);
    defer cfg.deinit(allocator);

    var policy = try policy_mod.Policy.init(allocator);
    defer policy.deinit();

    const rendered = try renderDynamicSystemPolicy(
        allocator,
        &cfg,
        &policy,
        "/tmp/zcode-test",
        "hello",
        "default",
        "",
        "",
        .execution,
    );
    defer allocator.free(rendered);

    // The date block lives between the base prose and the approval
    // metadata fields. We only assert the marker text and that SOME
    // ISO-like date follows it -- the specific date depends on the
    // clock and is already covered by session_date tests.
    const marker = "Today's date is ";
    const idx = std.mem.indexOf(u8, rendered, marker) orelse return error.MissingDateMarker;
    const after = rendered[idx + marker.len ..];
    try testing.expect(after.len >= 11);
    try testing.expect(after[4] == '-');
    try testing.expect(after[7] == '-');
    try testing.expect(after[10] == '.');

    // And it should land before the approval_mode field so the
    // environment block stays together.
    const approval_idx = std.mem.indexOf(u8, rendered, "approval_mode=") orelse return error.MissingApproval;
    try testing.expect(idx < approval_idx);
}

test "renderDynamicSystemPolicy loads MEMORY.md index under its header" {
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Write a small MEMORY.md into the tmp auto-mem dir.
    const index_body = "# Index\n- [foo](foo.md) - the foo memory\n- [bar](bar.md) - the bar memory\n";
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "MEMORY.md", .data = index_body });

    const dir_path = try @import("test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(dir_path);

    var cfg = try config_mod.Config.init(allocator);
    defer cfg.deinit(allocator);
    // Steer getAutoMemPath at the tmp dir via the settings directory field
    // (absolute path, no tilde -> passes validateMemoryPath).
    allocator.free(cfg.auto_memory_directory);
    cfg.auto_memory_directory = try allocator.dupe(u8, dir_path);

    var policy = try policy_mod.Policy.init(allocator);
    defer policy.deinit();

    const rendered = try renderDynamicSystemPolicy(
        allocator,
        &cfg,
        &policy,
        "/tmp/zcode-test",
        "hello",
        "default",
        "",
        "",
        .execution,
    );
    defer allocator.free(rendered);

    // The index section appears under its own header with the file content.
    try testing.expect(std.mem.indexOf(u8, rendered, "## MEMORY.md") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "- [foo](foo.md) - the foo memory") != null);
    // Small index: no truncation warning.
    try testing.expect(std.mem.indexOf(u8, rendered, "> WARNING: MEMORY.md is") == null);
    // Not the empty fallback.
    try testing.expect(std.mem.indexOf(u8, rendered, "is currently empty") == null);
}

test "renderDynamicSystemPolicy emits the empty-index fallback when MEMORY.md is absent" {
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try @import("test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(dir_path);

    var cfg = try config_mod.Config.init(allocator);
    defer cfg.deinit(allocator);
    allocator.free(cfg.auto_memory_directory);
    cfg.auto_memory_directory = try allocator.dupe(u8, dir_path);

    var policy = try policy_mod.Policy.init(allocator);
    defer policy.deinit();

    const rendered = try renderDynamicSystemPolicy(
        allocator,
        &cfg,
        &policy,
        "/tmp/zcode-test",
        "hello",
        "default",
        "",
        "",
        .execution,
    );
    defer allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "## MEMORY.md") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "is currently empty") != null);
}

test "renderDynamicSystemPolicy injects Language section when session override is set" {
    const allocator = testing.allocator;

    var cfg = try config_mod.Config.init(allocator);
    defer cfg.deinit(allocator);

    var policy = try policy_mod.Policy.init(allocator);
    defer policy.deinit();

    // Session override wins over cfg.
    const rendered = try renderDynamicSystemPolicy(
        allocator,
        &cfg,
        &policy,
        "/tmp/zcode-test",
        "hello",
        "default",
        "",
        "Spanish",
        .execution,
    );
    defer allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "# Language\n") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "Always respond in Spanish") != null);
}

test "renderDynamicSystemPolicy falls back to cfg.preferred_language when session override is empty" {
    const allocator = testing.allocator;

    var cfg = try config_mod.Config.init(allocator);
    defer cfg.deinit(allocator);

    // Switch the config default to Japanese.
    allocator.free(cfg.preferred_language);
    cfg.preferred_language = try allocator.dupe(u8, "Japanese");

    var policy = try policy_mod.Policy.init(allocator);
    defer policy.deinit();

    const rendered = try renderDynamicSystemPolicy(
        allocator,
        &cfg,
        &policy,
        "/tmp/zcode-test",
        "hello",
        "default",
        "",
        "", // empty override -> use cfg
        .execution,
    );
    defer allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "Always respond in Japanese") != null);
}

test "renderDynamicSystemPolicy omits Language section when no preference is set" {
    const allocator = testing.allocator;

    var cfg = try config_mod.Config.init(allocator);
    defer cfg.deinit(allocator);

    var policy = try policy_mod.Policy.init(allocator);
    defer policy.deinit();

    const rendered = try renderDynamicSystemPolicy(
        allocator,
        &cfg,
        &policy,
        "/tmp/zcode-test",
        "hello",
        "default",
        "",
        "",
        .execution,
    );
    defer allocator.free(rendered);

    // Neither the heading nor the "Always respond in" block should
    // appear -- zcode defaults to English unless the user opts in.
    try testing.expect(std.mem.indexOf(u8, rendered, "# Language\n") == null);
    try testing.expect(std.mem.indexOf(u8, rendered, "Always respond in") == null);
}

test "renderDynamicSystemPolicy includes the memory taxonomy when the gate is on and omits it when off" {
    const allocator = testing.allocator;

    var policy = try policy_mod.Policy.init(allocator);
    defer policy.deinit();

    // Gate ON (default): the taxonomy header and key markers appear.
    {
        var cfg = try config_mod.Config.init(allocator);
        defer cfg.deinit(allocator);

        const rendered = try renderDynamicSystemPolicy(
            allocator,
            &cfg,
            &policy,
            "/tmp/zcode-test",
            "hello",
            "default",
            "",
            "",
            .execution,
        );
        defer allocator.free(rendered);

        try testing.expect(std.mem.indexOf(u8, rendered, "## Types of memory") != null);
        try testing.expect(std.mem.indexOf(u8, rendered, "Saving a memory is a two-step process") != null);
        try testing.expect(std.mem.indexOf(u8, rendered, "## Searching past context") != null);
    }

    // Gate OFF (auto_memory_enabled = false, env unset): the taxonomy is gone.
    {
        var cfg = try config_mod.Config.init(allocator);
        defer cfg.deinit(allocator);
        cfg.auto_memory_enabled = false;

        const rendered = try renderDynamicSystemPolicy(
            allocator,
            &cfg,
            &policy,
            "/tmp/zcode-test",
            "hello",
            "default",
            "",
            "",
            .execution,
        );
        defer allocator.free(rendered);

        try testing.expect(std.mem.indexOf(u8, rendered, "## Types of memory") == null);
        try testing.expect(std.mem.indexOf(u8, rendered, "Saving a memory is a two-step process") == null);
    }
}

test "renderDynamicSystemPolicy injects planning-mode contract only when mode is planning" {
    const allocator = testing.allocator;
    var cfg = try config_mod.Config.init(allocator);
    defer cfg.deinit(allocator);
    var policy = try policy_mod.Policy.init(allocator);
    defer policy.deinit();

    const exec_rendered = try renderDynamicSystemPolicy(
        allocator,
        &cfg,
        &policy,
        "/tmp/zcode-test",
        "hello",
        "default",
        "",
        "",
        .execution,
    );
    defer allocator.free(exec_rendered);
    try testing.expect(std.mem.indexOf(u8, exec_rendered, "PLAN MODE IS ACTIVE") == null);

    const plan_rendered = try renderDynamicSystemPolicy(
        allocator,
        &cfg,
        &policy,
        "/tmp/zcode-test",
        "plan my refactor",
        "default",
        "",
        "",
        .planning,
    );
    defer allocator.free(plan_rendered);
    // Contract header, the five required plan sections, and the
    // "do not start executing" instruction must all be present.
    try testing.expect(std.mem.indexOf(u8, plan_rendered, "PLAN MODE IS ACTIVE") != null);
    try testing.expect(std.mem.indexOf(u8, plan_rendered, "# Overview") != null);
    try testing.expect(std.mem.indexOf(u8, plan_rendered, "# Files to touch") != null);
    try testing.expect(std.mem.indexOf(u8, plan_rendered, "# Steps") != null);
    try testing.expect(std.mem.indexOf(u8, plan_rendered, "# Verification") != null);
    try testing.expect(std.mem.indexOf(u8, plan_rendered, "# Risks") != null);
    try testing.expect(std.mem.indexOf(u8, plan_rendered, "Do NOT start executing") != null);
}

test "renderDynamicSystemPolicy injects review-mode contract only when mode is review" {
    const allocator = testing.allocator;
    var cfg = try config_mod.Config.init(allocator);
    defer cfg.deinit(allocator);
    var policy = try policy_mod.Policy.init(allocator);
    defer policy.deinit();

    const exec_rendered = try renderDynamicSystemPolicy(
        allocator,
        &cfg,
        &policy,
        "/tmp/zcode-test",
        "review this diff",
        "default",
        "",
        "",
        .execution,
    );
    defer allocator.free(exec_rendered);
    try testing.expect(std.mem.indexOf(u8, exec_rendered, "REVIEW MODE IS ACTIVE") == null);

    const review_rendered = try renderDynamicSystemPolicy(
        allocator,
        &cfg,
        &policy,
        "/tmp/zcode-test",
        "review this diff",
        "default",
        "",
        "",
        .review,
    );
    defer allocator.free(review_rendered);
    try testing.expect(std.mem.indexOf(u8, review_rendered, "REVIEW MODE IS ACTIVE") != null);
    try testing.expect(std.mem.indexOf(u8, review_rendered, "Use read-only tools only") != null);
    try testing.expect(std.mem.indexOf(u8, review_rendered, "Findings must come first") != null);
    try testing.expect(std.mem.indexOf(u8, review_rendered, "file:line") != null);
}

test "workspaceIsEffectivelyEmpty treats a fresh dir as empty" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(path);
    try testing.expect(workspaceIsEffectivelyEmpty(path));
}

test "workspaceIsEffectivelyEmpty ignores dotfiles and README" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(rt.io, ".git");
    try tmp.dir.createDirPath(rt.io, ".zcode");
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "README.md", .data = "# Empty project" });
    const path = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(path);
    try testing.expect(workspaceIsEffectivelyEmpty(path));
}

test "workspaceIsEffectivelyEmpty ignores scratch dirs like wiki and notes" {
    // Regression: screenshot 2026-05-17 21:20 showed a workspace
    // containing just `wiki/` + `.zcode/` defeating the old
    // entry-based check. The source-aware detector ignores wiki/.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(rt.io, "wiki");
    try tmp.dir.createDirPath(rt.io, "notes");
    try tmp.dir.createDirPath(rt.io, "docs");
    try tmp.dir.createDirPath(rt.io, ".zcode");
    const path = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(path);
    try testing.expect(workspaceIsEffectivelyEmpty(path));
}

test "workspaceIsEffectivelyEmpty returns false when source files exist" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "main.zig", .data = "// hi" });
    const path = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(path);
    try testing.expect(!workspaceIsEffectivelyEmpty(path));
}

test "workspaceIsEffectivelyEmpty returns false on a manifest-only project" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "package.json", .data = "{}" });
    const path = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(path);
    try testing.expect(!workspaceIsEffectivelyEmpty(path));
}

test "workspaceIsEffectivelyEmpty returns false on a src/-bearing project" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(rt.io, "src");
    const path = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(path);
    try testing.expect(!workspaceIsEffectivelyEmpty(path));
}

test "isBuildOrCreateRequest fires on common build verbs+nouns" {
    try testing.expect(isBuildOrCreateRequest("create a cli app for partiful events"));
    try testing.expect(isBuildOrCreateRequest("build an api server in go"));
    try testing.expect(isBuildOrCreateRequest("scaffold a new react project"));
    try testing.expect(isBuildOrCreateRequest("let's build a website"));
}

test "isBuildOrCreateRequest does not match unrelated prompts" {
    try testing.expect(!isBuildOrCreateRequest("explain how the build system works"));
    try testing.expect(!isBuildOrCreateRequest("what time is it"));
    try testing.expect(!isBuildOrCreateRequest("read the README"));
}

test "isResearchRequest catches well-known third-party services" {
    try testing.expect(isResearchRequest("how does the partiful api work"));
    try testing.expect(isResearchRequest("integrate with stripe sdk"));
    try testing.expect(isResearchRequest("use the openai endpoint"));
}

test "buildContinuationDirective with suppress includes resume-without-asking directive" {
    const allocator = testing.allocator;
    const out = try buildContinuationDirective(allocator, "Summary:\n1. did X", null, true);
    defer allocator.free(out);

    // Base wrapper is always present.
    try testing.expect(std.mem.indexOf(u8, out, "ran out of context") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Summary:\n1. did X") != null);
    // The suppress branch contributes the resume directive.
    try testing.expect(std.mem.indexOf(u8, out, "without asking") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Resume directly") != null);
    try testing.expect(std.mem.indexOf(u8, out, "do not acknowledge the summary") != null);
    // No long dashes leaked in (project rule).
    try testing.expect(std.mem.indexOf(u8, out, "\u{2014}") == null);
    try testing.expect(std.mem.indexOf(u8, out, "\u{2013}") == null);
}

test "buildContinuationDirective without suppress omits the resume directive" {
    const allocator = testing.allocator;
    const out = try buildContinuationDirective(allocator, "Summary:\n1. did X", null, false);
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "ran out of context") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Summary:\n1. did X") != null);
    try testing.expect(std.mem.indexOf(u8, out, "without asking") == null);
    try testing.expect(std.mem.indexOf(u8, out, "Resume directly") == null);
    try testing.expect(std.mem.indexOf(u8, out, "do not acknowledge the summary") == null);
}

test "buildContinuationDirective includes transcript pointer only when path supplied" {
    const allocator = testing.allocator;

    const with_path = try buildContinuationDirective(allocator, "S", "/tmp/transcript.jsonl", true);
    defer allocator.free(with_path);
    try testing.expect(std.mem.indexOf(u8, with_path, "read the full transcript at: /tmp/transcript.jsonl") != null);

    const without_path = try buildContinuationDirective(allocator, "S", null, true);
    defer allocator.free(without_path);
    try testing.expect(std.mem.indexOf(u8, without_path, "read the full transcript at") == null);
}

test "buildCompactedHistory wraps the summary in the continuation directive" {
    const allocator = testing.allocator;
    const history = [_]types.HistoryTurn{
        .{ .role = .user, .content = "do the thing", .timestamp = 1 },
        .{ .role = .assistant, .content = "did the thing", .timestamp = 2 },
    };
    const out = try buildCompactedHistory(allocator, history[0..], "Summary:\n1. did X", 8);
    defer {
        for (out) |turn| allocator.free(turn.content);
        allocator.free(out);
    }
    try testing.expectEqual(types.HistoryRole.system, out[0].role);
    // The summary turn is now a continuation directive, not the bare prefix.
    try testing.expect(std.mem.indexOf(u8, out[0].content, "ran out of context") != null);
    try testing.expect(std.mem.indexOf(u8, out[0].content, "Resume directly") != null);
    try testing.expect(std.mem.indexOf(u8, out[0].content, "Summary:\n1. did X") != null);
    // The tail is preserved verbatim after the directive.
    try testing.expectEqualStrings("do the thing", out[1].content);
    try testing.expectEqualStrings("did the thing", out[2].content);
}
