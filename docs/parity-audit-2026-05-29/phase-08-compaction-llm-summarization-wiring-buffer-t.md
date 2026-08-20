# Phase 8: Compaction: LLM summarization wiring, buffer thresholds, hooks, partial/pivot compaction, attachments, boundary metadata

## Overview

**What.** This phase brings zcode's compaction subsystem up to the reference project's
fidelity. The single largest item is wiring the existing LLM-summarization helper
(`compaction.llmCompact`) into the actual compaction result that the prompt engine and
history paths consume, so auto-compaction and manual `/compact` both produce a
model-written summary instead of the current keyword-extracted snapshot. Around that core
change we add: the buffer/effective-window threshold model with env overrides; firing of
PreCompact/PostCompact/SessionStart hooks; custom `/compact` summarization instructions;
post-compact file restoration as attachments; a structured compact-boundary marker with
preserved-segment metadata; image/attachment stripping before summarization; a
post-compaction continuation directive that suppresses follow-up questions; a one-turn
compact-warning suppression flag; centralized post-compact cache cleanup; per-tool token
breakdown for `/context`; a time-based microcompaction trigger; native API
context-management edits (clear_tool_uses / clear_thinking); and an experimental
partial/pivot-anchored compaction transform plus a token/text-block bounded keep-window.

**Why.** Today `maybeCompact` (the wired path used by `prompt_engine.zig` and
`agent_history.zig`) only runs `extractSignals`, a keyword matcher. The `llmCompact`
result computed in `forceCompaction` is logged and discarded. The result is a compaction
output that is structurally different and far lower fidelity than the reference's
9-section model summary. User-configured PreCompact/PostCompact hooks are silently inert.
`/compact` cannot take focusing instructions. After a compaction the model has no
recently-read file content and no directive to resume without re-greeting. These gaps
degrade resume UX, context fidelity, and extensibility relative to the reference.

**Dependencies.**
- **Phase 5 (hooks/plugins):** the hook dispatch path (`hook_event.zig`, `hook_config.zig`,
  `hooks.zig`, plugin `runPluginEvent`) must already fire arbitrary configured events; this
  phase reuses that machinery to fire PreCompact/PostCompact/SessionStart during compaction
  (gaps compaction-05, compaction-18).
- **Phase 7 (context / prompt-engine analysis):** the per-category token breakdown
  (`prompt_analysis.zig`, `context_suggestions.zig`) must exist so this phase can extend it
  with per-tool/per-attachment breakdown (gap compaction-12).

**Effort.** XL. The core LLM-summary wiring (compaction-01) and the structured boundary
marker (compaction-14) are L; partial/pivot compaction (compaction-07) and the bounded
keep-window (compaction-11) are L and experimental (deferable); the rest are S/M.

**Survey-correction note.** All gaps in the input JSON were re-verified against the
reference (now at `/Users/example/Downloads/claude-code-main/src/services/compact/`, not the
flat paths the JSON cites) and our Zig source. The verifications confirm every gap. Two
nuances downgrade scope:
- compaction-15 (image stripping): our `HistoryTurn` is flat text (`core/types.zig:102-106`),
  so images are not in the summarizer input today. This becomes meaningful only after
  compaction-01 wires a real model call AND a future phase adds multimodal turns. We keep a
  minimal text-marker stripping pass to match behavior and to future-proof, but it is S and
  low-risk.
- compaction-09 / compaction-11 (native API context edits, session-memory keep-window): both
  are feature-gated/ant-only or experimental in the reference. We implement the
  request-body plumbing for context-management edits behind an env opt-in only, and the
  keep-window as an opt-in alternative. Both are explicitly deferable if time-boxed.

## Gaps covered

| id | title | severity | size | our current state |
|---|---|---|---|---|
| compaction-01 | LLM summary not used by the wired compaction path | high | L | `llmCompact` exists (`compaction.zig:47-74`) and is called in `forceCompaction` (`agent_runtime.zig:2988`) but its result is logged and discarded; `maybeCompact` uses only `extractSignals` keyword matching |
| compaction-03 | Effective-window / buffer autocompact threshold + env overrides | medium | M | Percentage bands of `input_budget` (`types.zig:64-68`, `compaction.zig:142-147`); no buffer model, no env overrides, no blocking limit / percentLeft |
| compaction-05 | PreCompact/PostCompact/SessionStart hooks fired during compaction | medium | M | Event enums exist (`hook_event.zig:19-20`) but no firing site; `forceCompaction` never invokes hooks |
| compaction-06 | Manual `/compact` with custom summarization instructions | medium | S | `/compact` takes no args (`repl_commands.zig:838`); `buildCompactionPrompt` has no custom-instruction slot |
| compaction-07 | Partial / pivot-anchored compaction | low | L | Absent. Only full-history compaction + rewind truncation + message-selector navigation exist |
| compaction-08 | Post-compact file restoration as attachments | medium | M | Absent. `read_tracker` (`tools/file.zig:55`) is edit-gating only; no N-most-recent re-read after compaction |
| compaction-09 | Native API context-management edits (clear_tool_uses / clear_thinking) | low | M | Local microcompact only (`compaction.zig:105-124`); no `ContextManagementConfig`, no request-body field |
| compaction-10 | Time-based (cache-staleness) microcompaction trigger | low | S | Age-based microcompact runs unconditionally every turn (`prompt_engine.zig:102`); no time gate; `HistoryTurn.timestamp` unused in decisions |
| compaction-11 | Token/text-block bounded keep-window (session-memory compaction) | low | L | Absent. Only fixed `max_history_turns` tailing; experimental in reference |
| compaction-12 | Per-tool / per-file token breakdown for `/context` | medium | M | Aggregate tool-result tokens + duplicate reads exist (`prompt_analysis.zig:17-43`); per-tool-name breakdown + attachment/local-command categories absent |
| compaction-14 | Compact-boundary marker with preserved-segment relink metadata | low | M | Plain system note "Conversation compacted by control action." (`agent_history.zig:287`); no structured boundary, trigger, preCompactTokenCount, preserved-segment uuids |
| compaction-15 | Image/document/attachment stripping before summarization | low | S | Absent; `buildCompactionPrompt` only char-truncates (`compaction.zig:34-35`) |
| compaction-16 | Post-compaction continuation prompt (resume without asking) | low | S | Absent; summary inserted as `compacted_summary:` system turn (`prompt_helpers.zig:28-32`) with no continuation directive |
| compaction-17 | Compact-warning suppression after successful compaction | low | S | Absent |
| compaction-18 | Post-compaction cleanup of caches/tracking state | low | S | Manual `/compact` calls `invalidateAll()` (`repl_commands.zig:843`); auto path does not; no central cleanup; PostCompact hook never dispatched |

## Implementation tasks

The tasks are ordered so dependencies land first. Tasks 1-4 form the critical path
(LLM summary + thresholds + hooks + custom instructions). Tasks 5-10 are independent
enhancements. Tasks 11-13 are experimental / deferable.

---

### Task 1 - Wire the LLM summary into CompactionResult (compaction-01)

**Goal.** Make `maybeCompact` (and therefore `forceCompaction`, `prompt_engine`, and
`agent_history`) actually use a model-written summary, with the rule-based extraction as a
fallback when no adapter is available or the model call fails.

**Reference behavior.** `compactConversation` runs a real model call to produce a thorough
natural-language 9-section summary; that summary is the heart of compaction and is wrapped
into the post-compact user message.
- `services/compact/compact.ts:387-491` (`compactConversation`, the streamCompactSummary
  loop with PTL retry).
- `services/compact/prompt.ts:61-143` (`BASE_COMPACT_PROMPT`, the 9 sections) and
  `:311-335` (`formatCompactSummary` strips `<analysis>` and reformats `<summary>`).

**Target Zig files.**
- Edit `src/core/compaction.zig`: add an optional summarizer to `maybeCompact`; add
  `formatCompactSummary` (strip `<analysis>`, unwrap `<summary>`); thread the LLM summary
  into `CompactionResult.conversation_summary`.
- Edit `src/agent_history.zig`: `forceCompaction` accepts an optional adapter + model and
  passes them to `maybeCompact`.
- Edit `src/agent_runtime.zig`: `AgentRuntime.forceCompaction` builds the adapter and passes
  it down (remove the discard-and-log dead code at `:2988-2994`).
- Edit `src/core/prompt_engine.zig`: pass an optional summarizer into the `maybeCompact`
  call at `:92` (auto-compaction path) - see note on cost below.

**Approach (step by step).**
1. Introduce a `Summarizer` indirection in `compaction.zig` so the deep module does not
   import the providers tree (keeps `core/` a deep module):
   ```zig
   pub const Summarizer = struct {
       ctx: *anyopaque,
       /// Returns model summary text (caller frees) or null on failure.
       call: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator,
                        history: []const types.HistoryTurn,
                        custom_instructions: []const u8) ?[]u8,
   };
   ```
2. Change `maybeCompact` to `maybeCompact(allocator, history, budget, summarizer: ?Summarizer, custom_instructions: []const u8)`.
   When `usage_percent >= compact_percent` and `summarizer != null`, call it. On a non-empty
   result, run it through `formatCompactSummary` and use that as
   `conversation_summary`; still run `extractSignals` to populate the structured snapshot
   (facts/decisions/tasks/file_focus/pinned) because the rest of the system consumes the
   snapshot. When the summarizer is null or returns null, fall back to the current
   keyword-built summary verbatim (no behavior regression for tests / offline mode).
3. Add `pub fn formatCompactSummary(allocator, raw) ![]u8`: delete any `<analysis>...</analysis>`
   span, and if a `<summary>...</summary>` span exists, emit `"Summary:\n" ++ inner.trim()`;
   collapse 3+ newlines to 2; trim. Mirror `prompt.ts:311-335`. Pure function, fully unit
   testable.
4. In `agent_runtime.zig`, replace the dead `if (compaction_mod.llmCompact(...)) |llm_summary|`
   block with constructing a `Summarizer` whose `call` closes over the adapter and model and
   delegates to `compaction.llmCompact` (extend `llmCompact` to accept `custom_instructions`,
   see Task 4). Pass the summarizer (and instructions) through `agent_history.forceCompaction`
   into `maybeCompact`. The adapter lifetime must outlive the `maybeCompact` call - keep the
   existing `defer adapter.deinit` and only deinit after `forceCompaction` returns.
5. Auto-compaction cost note: `prompt_engine.buildPrompt` runs `maybeCompact` on **every**
   prompt build. We must NOT fire a model call on every turn. Pass `null` as the summarizer
   from `prompt_engine.zig` for now (so the auto path keeps the rule-based summary, which is
   the current behavior) and only pass a real summarizer from the explicit
   `forceCompaction` (manual `/compact`) path and a future dedicated auto-compaction trigger
   (Task 2 introduces the threshold check that decides when an auto LLM compaction should
   run, so the model call happens once at the boundary, not per turn). Document this split
   with a comment at the `prompt_engine.zig:92` call site.

**Acceptance criteria.**
- New unit test in `compaction.zig`: a stub `Summarizer` returns
  `"<analysis>scratch</analysis>\n<summary>1. Primary Request: do X</summary>"`; assert
  `maybeCompact` returns `conversation_summary` containing `"Summary:"` and
  `"do X"` and NOT containing `"scratch"` or `"<analysis>"`.
- Unit test: when `summarizer == null` and usage is above threshold, the summary equals the
  current rule-based output (regression guard - reuse the existing
  `"compacts above threshold"` test, extended to assert `did_compact` and a non-zero hash).
- Unit test for `formatCompactSummary` covering: analysis-only stripped, summary unwrap,
  no-tags passthrough, multiple-newline collapse.
- `forceCompaction` integration: with a mock provider adapter (the `mock` provider) wired in,
  `AgentRuntime.forceCompaction` produces a `compacted_summary:` system turn whose body comes
  from the mock model output, verifiable via `history.view()`.

**Test strategy.** Pure-function tests in `compaction.zig` run under
`tools/test_runner.zig`. For the adapter path, use the existing `mock` provider adapter
(grep `providers/mock.zig`) so no network is required; assert the summary text round-trips.

**Risk / footguns.**
- Lifetime: `llmCompact` already dupes `response.text` (`compaction.zig:73`) so the returned
  summary outlives the response; keep that. The `formatCompactSummary` output must be
  separately allocated and the raw freed.
- Do not let the summarizer import cycle through providers in `core/` - the `Summarizer`
  `*anyopaque` indirection prevents a module-path cross (per the project's deep-module rule).
- `adapter.send` can be slow/blocking; only the manual `/compact` path and the explicit
  auto-threshold path should call it. Never from per-turn prompt build.

**Size.** L.

---

### Task 2 - Effective-window / buffer threshold model with env overrides (compaction-03)

**Goal.** Add the reference's absolute-token buffer threshold model (effective window =
contextWindow - reservedSummary; autocompact threshold = effective - AUTOCOMPACT_BUFFER) with
warning/error/blocking tiers, a `percentLeft` computation, and the three env overrides,
layered alongside the existing percentage bands.

**Reference behavior.**
- `services/compact/autoCompact.ts:30-49` (`getEffectiveContextWindowSize`,
  `MAX_OUTPUT_TOKENS_FOR_SUMMARY=20_000`, `CLAUDE_CODE_AUTO_COMPACT_WINDOW`).
- `:62-91` (`AUTOCOMPACT_BUFFER_TOKENS=13_000`, `WARNING/ERROR=20_000`,
  `MANUAL_COMPACT_BUFFER=3_000`, `getAutoCompactThreshold`, `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`).
- `:93-145` (`calculateTokenWarningState`, `percentLeft`, `isAtBlockingLimit`,
  `CLAUDE_CODE_BLOCKING_LIMIT_OVERRIDE`).

**Target Zig files.**
- Edit `src/core/types.zig`: add constants and a `TokenWarningState` struct near `BudgetPlan`.
- Create `src/core/autocompact_threshold.zig` (new deep module) - pure threshold math; register
  in the `src/main.zig` comptime test-discovery block (after `core/prompt_analysis.zig` at
  line ~85).
- Edit `src/core/env_registry.zig`: register the three env vars
  (`CLAUDE_CODE_AUTO_COMPACT_WINDOW`, `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`,
  `CLAUDE_CODE_BLOCKING_LIMIT_OVERRIDE`) so doctor/validation knows them.

**Approach.**
1. In `autocompact_threshold.zig`:
   ```zig
   pub const MAX_OUTPUT_TOKENS_FOR_SUMMARY: usize = 20_000;
   pub const AUTOCOMPACT_BUFFER_TOKENS: usize = 13_000;
   pub const WARNING_THRESHOLD_BUFFER_TOKENS: usize = 20_000;
   pub const ERROR_THRESHOLD_BUFFER_TOKENS: usize = 20_000;
   pub const MANUAL_COMPACT_BUFFER_TOKENS: usize = 3_000;
   ```
2. `pub fn effectiveContextWindow(ctx_window, max_output_tokens_for_model, env_window_override: ?usize) usize`
   - reserved = `@min(max_output_tokens_for_model, MAX_OUTPUT_TOKENS_FOR_SUMMARY)`; apply the
   `CLAUDE_CODE_AUTO_COMPACT_WINDOW` clamp (`@min(ctx_window, parsed)`); return
   `effective = window - reserved` (saturating).
3. `pub fn autoCompactThreshold(effective, pct_override: ?f32) usize`:
   `threshold = effective - AUTOCOMPACT_BUFFER_TOKENS`; if `pct_override` in (0,100],
   `return @min(@floor(effective * pct/100), threshold)`.
4. `pub fn warningState(token_usage, effective, threshold, auto_enabled, blocking_override: ?usize) TokenWarningState`
   computing `percentLeft = max(0, round((threshold - usage)/threshold*100))`,
   `is_above_warning/error`, `is_above_autocompact`, `is_at_blocking_limit`
   (default blocking = `effective - MANUAL_COMPACT_BUFFER_TOKENS`, overridable).
5. Read env via `@import("zcode_runtime")` -> `env_mod` or the existing env helper used by
   `anthropic.zig:63` (`env_mod.getOwned`). Parse to int/float, ignore invalid.
6. Keep the existing percentage bands in `BudgetPlan.CompactionThresholds` as the
   per-turn cheap gate; use the buffer model for the warning UI (`context_suggestions.zig`)
   and to decide when an explicit auto-compaction (LLM) should fire. Document that the two
   models coexist: percentage bands gate the cheap rule-based snapshot in per-turn builds;
   the buffer model gates the expensive LLM summary at the boundary.

**Acceptance criteria.**
- Unit tests in `autocompact_threshold.zig`: with `ctx_window=200_000`, model max output
  64_000, no env: `effective == 180_000`, `autoCompactThreshold == 167_000`.
- `CLAUDE_CODE_AUTO_COMPACT_WINDOW=100000` clamps effective to `100_000 - 20_000 = 80_000`.
- `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50` yields `min(floor(0.5*effective), effective-13k)`.
- `warningState`: `percentLeft` is 0 when usage >= threshold; `is_at_blocking_limit` true when
  usage >= `effective - 3_000`; `CLAUDE_CODE_BLOCKING_LIMIT_OVERRIDE=50000` forces blocking at
  50_000.

**Test strategy.** Pure functions; table-driven tests under `tools/test_runner.zig`. Set env
vars inside the test via the runtime env map (or pass overrides explicitly to keep tests
hermetic - prefer explicit-arg overloads so tests do not mutate process env).

**Risk / footguns.**
- Saturating subtraction everywhere (`window < reserved` must not underflow `usize`).
- `std.process.getEnvMap` is gone in 0.16; read env through the established
  `env_mod.getOwned` path used in `anthropic.zig` (per CLAUDE.md 0.16 gotchas), and free the
  owned value.

**Size.** M.

---

### Task 3 - Fire PreCompact / PostCompact / SessionStart hooks during compaction (compaction-05, compaction-18)

**Goal.** Fire PreCompact hooks before summarization (and merge their custom instructions and
display message), SessionStart hooks after a successful compaction, and PostCompact hooks with
the summary; centralize a post-compact cache cleanup on BOTH the manual and auto paths.

**Reference behavior.**
- `services/compact/compact.ts:411-424` (`executePreCompactHooks`, `trigger: auto|manual`,
  `customInstructions`, `mergeHookInstructions`).
- `:587-594` (`processSessionStartHooks('compact')` restoring CLAUDE.md).
- `:719-729` (`executePostCompactHooks` receiving `compactSummary`).
- `services/compact/postCompactCleanup.ts:31-77` (`runPostCompactCleanup`).

**Target Zig files.**
- Edit `src/core/plugins.zig`: extend `PluginEvent` (`:13-19`) with `pre_compact` and
  `post_compact` and their `eventName` mapping (`:81-89`).
- Edit `src/session_mgmt.zig`: reuse `runPluginEvent`/`runPluginEventSilent`
  (`:192-199`) to dispatch the new events.
- Edit `src/agent_runtime.zig`: in `AgentRuntime.forceCompaction`, fire PreCompact before the
  summarizer, SessionStart and PostCompact after a successful compaction, and call a new
  centralized cleanup.
- Edit `src/core/hooks.zig` only if PreCompact must run as a settings.json hook (blocking) -
  `hook_event.zig` already marks `pre_compact` blocking-capable (`:90`); add a dispatch helper
  if Phase 5 has not already generalized `hooks.zig` beyond the three tool events at
  `:13-17`.
- Edit `src/repl_commands.zig:843`: route the manual `/compact` cleanup through the same
  centralized helper.

**Approach.**
1. Add `pre_compact`/`post_compact` to `plugins.PluginEvent` and `eventName`.
2. Add a `compactionCleanup(runtime)` helper on `AgentRuntime` that calls
   `runtime.prompt_sections_registry.invalidateAll()` plus any fingerprint-resettable caches
   we own (`instruction_cache`, `git_capture_cache` - reset their epoch/fingerprint so the
   next build re-discovers). This mirrors `runPostCompactCleanup`; our caches are already
   fingerprint-invalidated (per the gap notes) so this is mostly invalidating the sections
   registry on the auto path too.
3. In `forceCompaction`:
   - Before summarizing: fire PreCompact (plugin event + settings.json hook). Collect any
     stdout the hook emits as `newCustomInstructions` and merge with the user's `/compact`
     instructions (Task 4) via a `mergeHookInstructions(user, hook)` helper (user first,
     hook appended, empty -> null). If a blocking PreCompact hook returns disposition `.block`
     (`hook_event.interpretExit`), skip compaction and surface the message.
   - After a successful compaction: fire SessionStart (`runPluginEvent .session_start` already
     exists; add a `trigger="compact"` discriminator field to `PluginContext` so the hook can
     distinguish), then PostCompact with the summary text in `tool_output` (reuse the existing
     `PluginContext.tool_output` field as the summary carrier, or add a `compact_summary`
     field). Then call `compactionCleanup`.
4. Make the manual `/compact` path and the (future) auto path both go through
   `forceCompaction`, so cleanup and hooks are not duplicated.

**Acceptance criteria.**
- Test: a fake plugin/hook registry records which events fired and in what order;
  `forceCompaction` produces the sequence `pre_compact`, (summarize), `session_start`,
  `post_compact`, `cleanup` with `trigger=manual`. (Auto path test asserts `trigger=auto`.)
- Test: a PreCompact hook emitting `focus on test output` causes that text to appear in the
  summarizer prompt (cross-check with Task 4's custom-instructions plumbing).
- Test: a blocking PreCompact hook (exit 2) prevents the `compacted_summary:` turn from being
  appended.
- Test: after `forceCompaction`, `prompt_sections_registry` reports invalidated (assert via
  whatever epoch/version the registry exposes).

**Test strategy.** Unit tests with an in-memory fake hook runner injected into `AgentRuntime`
(or a seam that records event names). Run under `tools/test_runner.zig`. Do not spawn real
processes in the unit tests; reserve a single end-to-end manual check for the Verification
section.

**Risk / footguns.**
- 0.16: hooks that spawn processes must use `std.process.run`/`spawn(io, opts)` (Child.init is
  gone) and `Child.Cwd` is a union (`.{ .path = ... }`). After `kill`, do NOT call `wait`.
- Ordering matters: PreCompact must run before the model call so merged instructions reach the
  prompt. PostCompact must receive the FINAL formatted summary.
- Subagent-vs-main-thread guard: the reference skips main-thread-only resets when a subagent
  compacts. zcode's compaction is main-thread today; add a comment and a guard hook so a future
  subagent compaction does not clobber shared caches.

**Size.** M.

---

### Task 4 - Custom `/compact` instructions plumbing (compaction-06)

**Goal.** Let `/compact <instructions>` pass focusing directives into the summarizer prompt,
and merge hook-provided instructions.

**Reference behavior.** `compactConversation(customInstructions)` ->
`getCompactPrompt(customInstructions)` appends `\n\nAdditional Instructions:\n{...}`.
- `services/compact/compact.ts:387-443`, `prompt.ts:293-303`, `:133-143` (the prompt documents
  Compact Instructions support).

**Target Zig files.**
- Edit `src/repl_commands.zig:838`: accept `/compact ` prefix (mirror `/brief`, `/density`
  which use `startsWith` at `:847-852`) and pass the trailing text as instructions.
- Edit `src/agent_runtime.zig`: `forceCompaction(instructions: []const u8)`.
- Edit `src/agent_history.zig`: thread `instructions` into `maybeCompact`.
- Edit `src/core/compaction.zig`: `buildCompactionPrompt(allocator, history, custom_instructions)`
  appends an `Additional Instructions:` section when non-empty; `llmCompact` gains the param.

**Approach.**
1. `repl_commands.zig`: change the `/compact` branch to also match `startsWith(command, "/compact ")`
   and extract `command["/compact ".len..]` trimmed as the instruction string; pass to
   `runtime.forceCompaction(instructions)`. Empty string for the no-arg form.
2. `buildCompactionPrompt`: after the existing section list and before the conversation, if
   `custom_instructions.len > 0`, write `"\n## Compact Instructions\n{s}\n"` so it matches the
   reference's documented marker, then continue. Keep the existing 7-section header (it is the
   external-build equivalent of `BASE_COMPACT_PROMPT`).
3. `llmCompact`/`maybeCompact` forward the instructions to `buildCompactionPrompt`.
4. Merge hook instructions (Task 3) before the model call: `merged = mergeHookInstructions(user, hook)`.

**Acceptance criteria.**
- Unit test: `buildCompactionPrompt(alloc, hist, "focus on test output")` output contains
  `Compact Instructions` and `focus on test output`; with `""` it contains neither.
- Unit test for `mergeHookInstructions`: (user,hook) -> `"user\n\nhook"`; (user,"") -> "user";
  ("",hook) -> "hook"; ("","") -> "".
- REPL test: `/compact focus on X` reaches `forceCompaction` with `instructions == "focus on X"`.

**Test strategy.** Pure-function tests in `compaction.zig`; a small dispatch test for the
`/compact ` arg parse in `repl_commands.zig` (or wherever command tests live).

**Risk / footguns.** Trim leading/trailing whitespace from the extracted argument; an empty
argument after the space must behave exactly like the no-arg form.

**Size.** S.

---

### Task 5 - Post-compaction continuation directive + warning suppression (compaction-16, compaction-17)

**Goal.** Wrap the summary with a continuation directive that tells the model to resume the
last task without re-acknowledging the summary or asking questions, and suppress the
compact-capacity warning for one turn after a successful compaction.

**Reference behavior.**
- `prompt.ts:337-374` (`getCompactUserSummaryMessage`, the `suppressFollowUpQuestions`
  branch: "Continue ... without asking the user any further questions. Resume directly - do
  not acknowledge the summary ...", plus a transcript-path pointer and a proactive variant).
- `compactWarningState.ts:1-19` + `microCompact.ts:511` (`suppressCompactWarning`).

**Target Zig files.**
- Edit `src/core/prompt_helpers.zig:18-43` (`buildCompactedHistory`): change the inserted
  system turn body from bare `"compacted_summary:\n{summary}"` to the full continuation
  wrapper.
- Edit `src/agent_runtime.zig`: add a `suppress_compact_warning: bool` field on `AgentRuntime`;
  set it true right after a successful `forceCompaction`; consume-and-clear it the next time
  the warning would be computed.
- Edit `src/core/context_suggestions.zig:107-140` (`checkNearCapacity`): respect a passed-in
  `suppress` flag (skip the near-capacity warning when set).

**Approach.**
1. Add `pub fn buildContinuationDirective(allocator, summary, transcript_path: ?[]const u8, suppress_questions: bool) ![]u8`
   producing:
   - Base: `"This session is being continued from a previous conversation that ran out of context. The summary below covers the earlier portion of the conversation.\n\n{summary}"`.
   - If transcript path: append the read-the-transcript pointer.
   - If `suppress_questions`: append the "Continue ... without asking ... Resume directly - do
     not acknowledge the summary ..." paragraph (port verbatim from `prompt.ts:358-359`).
   - Skip the proactive variant for now (we do not have a proactive mode; note as deferred).
2. `buildCompactedHistory` uses this for the system turn body. Default `suppress_questions=true`
   for auto-compaction, configurable for manual.
3. `suppress_compact_warning`: a plain bool on `AgentRuntime`. Set after compaction; the
   `/context` / suggestion path checks it and, if set, skips the near-capacity warning once and
   clears it (one-turn suppression, matching the reference's "until the next accurate token
   count").

**Acceptance criteria.**
- Unit test: `buildContinuationDirective(..., suppress=true)` output contains
  `"without asking"` and `"Resume directly"` and `"do not acknowledge the summary"`; with
  `suppress=false` it does not.
- Unit test: with a transcript path, the pointer text appears; without, it does not.
- Unit test: `checkNearCapacity` with `suppress=true` returns no suggestion even above
  warn_percent; a second call with the flag cleared returns the suggestion.

**Test strategy.** Pure-function tests under `tools/test_runner.zig`.

**Risk / footguns.** Do not use em or en dashes in the directive text (CLAUDE.md rule) - the
reference uses a long dash in "Resume directly -"; replace with " - " (space-hyphen-space) or a
period. The `buildCompactedHistory` allocation already builds the string via `allocPrint`
(`prompt_helpers.zig:30`); keep ownership identical so existing callers still free it.

**Size.** S (both together).

---

### Task 6 - Structured compact-boundary marker with preserved-segment metadata (compaction-14)

**Goal.** Replace the plain "Conversation compacted by control action." note with a structured
boundary record carrying trigger (auto/manual), pre-compact token count, discovered tools, and
preserved-segment head/anchor/tail markers, persisted in the session store for resume fidelity.

**Reference behavior.**
- `compact.ts:330-367` (`buildPostCompactMessages`, `annotateBoundaryWithPreservedSegment`).
- `:598-611` (`createCompactBoundaryMessage(trigger, preCompactTokenCount, lastUuid)` +
  `preCompactDiscoveredTools`).

**Target Zig files.**
- Edit `src/core/types.zig`: add a `CompactBoundary` struct (trigger enum, pre_compact_tokens,
  discovered_tools `[]const []const u8`, preserved head/anchor/tail ids as turn indices or
  string ids).
- Edit `src/core/compaction.zig`: include the boundary fields in `CompactionResult`
  (`:76-94`).
- Edit `src/agent_history.zig:287`: append a boundary system turn carrying the structured
  marker (serialized compactly) instead of the bare string; populate `pre_compact_tokens` from
  the token total computed in `maybeCompact`.
- Edit `src/session/store.zig` (or wherever `appendTurn`/`appendSnapshot` live): persist the
  boundary metadata so `--resume` can relink.

**Approach.**
1. Define:
   ```zig
   pub const CompactTrigger = enum { auto, manual };
   pub const CompactBoundary = struct {
       trigger: CompactTrigger,
       pre_compact_tokens: usize,
       discovered_tools: []const []const u8 = &.{},
       preserved_head: ?usize = null,   // index into preserved tail
       preserved_anchor: ?usize = null,
       preserved_tail: ?usize = null,
   };
   ```
   Use turn-index relinks since zcode history turns are positional, not UUID-keyed (note the
   divergence from the reference's UUID scheme in a comment).
2. `maybeCompact` already computes `token_total`; surface it as `pre_compact_tokens` in the
   result. `extractDiscoveredToolNames` analog: scan history for ToolSearch/deferred-tool
   loads (or pull from the runtime's loaded-tools set if available - else leave empty).
3. `agent_history.forceCompaction` appends a system turn whose content is a stable serialized
   form (e.g. `"compact_boundary trigger=manual pre_tokens=12345 ..."`) so the transcript loader
   and `/context` telemetry can parse it. Persist via the store.
4. Add a `parseCompactBoundary` to read it back (resume path).

**Acceptance criteria.**
- Unit test: round-trip `serializeCompactBoundary` / `parseCompactBoundary` for
  `{trigger=auto, pre_compact_tokens=42, discovered_tools=["ToolSearch"]}`.
- Test: `forceCompaction` appends a turn whose content `startsWith("compact_boundary")` and
  contains the trigger and token count.
- Test: resume reads the boundary and exposes `pre_compact_tokens` for telemetry.

**Test strategy.** Serialization round-trip + a `forceCompaction` integration test under
`tools/test_runner.zig`.

**Risk / footguns.** `ObjectMap.put` after parse needs the by-pointer pattern
(`&parsed.value.object`) if JSON is used (CLAUDE.md 0.16 gotcha); prefer a flat text marker to
sidestep JSON entirely. Keep the marker human-readable so existing transcript viewers degrade
gracefully.

**Size.** M.

---

### Task 7 - Post-compact file restoration as attachments (compaction-08)

**Goal.** After a successful compaction, re-read up to 5 most-recently-read files (budgeted to
50K total / 5K per file) and re-inject them as context attachments, skipping files still
present in the preserved tail.

**Reference behavior.**
- `compact.ts:122-130` (budgets: `POST_COMPACT_MAX_FILES_TO_RESTORE=5`,
  `POST_COMPACT_TOKEN_BUDGET=50_000`, `POST_COMPACT_MAX_TOKENS_PER_FILE=5_000`).
- `:1415-1464` (`createPostCompactFileAttachments`: sort readFileState by timestamp desc,
  filter excluded + preserved, per-file token cap, total budget cap).
- `:517-545` (capture `readFileState` before clearing).

**Target Zig files.**
- Edit `src/tools/file.zig`: expose a `recentReadPaths(allocator, max) ![][]u8` from
  `read_tracker` (currently only stores mtime keyed by path; add insertion-order or a
  timestamp so we can sort by recency - store `i128` last-read time alongside the mtime, or a
  monotonic counter).
- Create `src/core/post_compact_files.zig` (deep module) implementing the budgeted re-read;
  register in the `src/main.zig` comptime block.
- Edit `src/agent_runtime.zig` `forceCompaction`: after compaction, gather restored files and
  append them to working context (the snapshot's `file_focus` already exists; add the actual
  re-read content as a context block or a synthetic system turn the next prompt build picks up).

**Approach.**
1. Augment `read_tracker` to remember a recency ordinal per path (a monotonically increasing
   counter incremented on each `trackerRecordRead`), keyed alongside the existing mtime. Add
   `recentReadPaths(allocator, max) -> []path` sorted by descending recency.
2. `post_compact_files.zig`: `restore(allocator, io, paths, preserved_paths, max_files, per_file_cap, total_budget) -> []Attachment`
   - For each of the top `max_files` paths not in `preserved_paths`, read the file (limited to
     `per_file_cap` tokens via `readFileAlloc(.limited(N))`), estimate tokens, accept while
     under `total_budget`. Skip unreadable files.
3. Wire into `forceCompaction`: capture recent paths BEFORE any cache clears, restore after the
   summary lands, and inject restored content so the next prompt includes it (simplest: append
   a single system turn `"restored-files:\n..."` or feed into `context.zig` file gathering).

**Acceptance criteria.**
- Unit test (using `core/test_helpers.tmpDirCwd` for a real tmp path): seed `read_tracker` with
  3 files of known sizes; `restore` returns them newest-first, drops a 4th over budget, and
  caps a large file to `per_file_cap`.
- Test: a path present in `preserved_paths` is skipped.
- Integration: after `forceCompaction`, the restored content is visible to the next prompt
  build.

**Test strategy.** Tests under `tools/test_runner.zig`. CRITICAL: pass a real absolute tmp dir
via `core/test_helpers.tmpDirCwd` - never `"."`/`"repo"` (CLAUDE.md reuse-points rule).

**Risk / footguns.**
- `readFileAlloc(.limited(N))` returns `error.StreamTooLong`, not `FileTooBig` (CLAUDE.md
  gotcha) - handle it as "truncate to N", not a hard error.
- File IO must go through `rt.io` (the runtime singleton) per the project's IO threading rule.
- The `read_tracker` uses `std.heap.page_allocator` as its owner (`file.zig:62`); keep recency
  values in the same map to avoid a second allocator's lifetime mismatch.

**Size.** M.

---

### Task 8 - Per-tool / per-file token breakdown for /context (compaction-12)

**Goal.** Extend the context analysis to break tokens down by tool name (aggregated across
calls), tool-request vs tool-result, attachments, and local-command output, surfaced in
`/context`.

**Reference behavior.** `utils/contextAnalysis.ts:27-80` (`analyzeContext` -> `TokenStats`:
`toolRequests`, `toolResults`, `duplicateFileReads`, `attachments`, per-tool aggregation).

**Target Zig files.**
- Edit `src/core/prompt_analysis.zig:17-43` (`Analysis`): add `per_tool` breakdown (a slice of
  `{ name, request_tokens, result_tokens, calls }`), `attachment_tokens`,
  `local_command_tokens`.
- Edit `src/core/prompt_analysis.zig:230-241` (render): print the per-tool table.
- Edit `src/core/context_suggestions.zig:5-19`: the doc-comment flags per-tool bloat as
  deferred; now implement `checkToolBloat` using the new breakdown.

**Approach.**
1. While walking history turns, detect tool turns (role `.tool`) and parse the
   `"Tool: <Name>\n..."` header (matching how `microcompact`/`summarizeClearedTool` already
   read it at `compaction.zig:127`) to attribute tokens to a tool name. Aggregate into a small
   ordered map.
2. Detect attachment-style content and local-command output if they carry a recognizable
   prefix; otherwise leave those categories at 0 with a comment (zcode's flat-text history may
   not distinguish them yet - note this honestly rather than fabricating).
3. Render a `by tool:` section in the `/context` report and add a `checkToolBloat` suggestion
   that fires when one tool dominates (e.g. > 30% of history tokens).

**Acceptance criteria.**
- Unit test: an `Analysis` over a history with 3 `Tool: Read` turns and 1 `Tool: Bash` turn
  reports per-tool aggregates with correct call counts and summed tokens.
- Test: `checkToolBloat` fires when one tool exceeds the threshold and is silent otherwise.
- `/context` output includes the per-tool section (snapshot/string-contains test).

**Test strategy.** Pure-function tests on `Analysis` construction under `tools/test_runner.zig`.

**Risk / footguns.** Do not over-claim categories we cannot measure (attachments /
local-command) - keep them but document that they are best-effort until history turns carry
structured block types.

**Size.** M.

---

### Task 9 - Time-based (cache-staleness) microcompaction trigger (compaction-10)

**Goal.** Gate an aggressive microcompaction on the time gap since the last assistant message
(default 60 min, the server cache TTL), in addition to the existing unconditional age-based
microcompact.

**Reference behavior.** `microCompact.ts:422-444` (`evaluateTimeBasedTrigger`: gap since last
assistant message > `gapThresholdMinutes`); `:446-530` (clear all but last N compactable tool
results); `timeBasedMCConfig.ts:18-43` (defaults).

**Target Zig files.**
- Edit `src/core/compaction.zig`: add `timeBasedMicrocompact(allocator, history, now_seconds, gap_threshold_seconds, keep_recent) ?[]types.HistoryTurn`
  reusing the existing `microcompact` clear mechanism with a smaller `keep_recent`.
- Edit `src/core/prompt_engine.zig:99-102`: before the unconditional microcompact, compute the
  gap from the last assistant turn's `HistoryTurn.timestamp` and, if over threshold, apply the
  more aggressive clear.

**Approach.**
1. Find the last `.assistant` turn; if none, skip. `gap = now - turn.timestamp` (seconds).
2. If `gap >= gap_threshold_seconds` (default 3600), run `microcompact` with a smaller
   `keep_recent` (e.g. 2) and set `suppress_compact_warning` (Task 5). Otherwise fall through
   to the existing keep-6 microcompact.
3. Config: a `time_based_mc_gap_minutes` field (default 60) and `enabled` flag in config;
   `now` from `clock.nowSeconds()` (the project clock shim) - never `std.time.*` (CLAUDE.md
   reuse-points rule).

**Acceptance criteria.**
- Unit test: history with last-assistant timestamp 2 hours old and gap_threshold 60 min clears
  down to `keep_recent`; with a fresh timestamp it does not (returns null / unchanged).
- Test: disabled config -> never triggers.

**Test strategy.** Pure-function test with synthetic `timestamp`s under `tools/test_runner.zig`;
inject `now` as a parameter so the test is deterministic (do not read the real clock in the
pure function).

**Risk / footguns.** `HistoryTurn.timestamp` is `i64` seconds (`types.zig:105`); ensure the
unit matches `clock.nowSeconds()`. Keep the pure transform allocation/borrow semantics identical
to the existing `microcompact` (cleared turns own content, kept turns borrow).

**Size.** S.

---

### Task 10 - Image/document/attachment stripping before summarization (compaction-15)

**Goal.** Before the summarizer prompt is built, replace image/document content with
`[image]`/`[document]` markers and drop reinjected skill-discovery/listing attachments, so the
compaction call itself does not bloat or hit prompt-too-long.

**Reference behavior.** `compact.ts:145-200` (`stripImagesFromMessages`),
`:211-223` (`stripReinjectedAttachments`).

**Target Zig files.**
- Edit `src/core/compaction.zig` `buildCompactionPrompt`: run a stripping pass over each turn's
  content before writing it.

**Approach.**
1. Add `fn stripMediaMarkers(content) []const u8` (or an allocating variant) that, for the
   flat-text history we have today, recognizes any embedded `[image: ...]` / data-URI-ish
   blocks our REPL attachment path may have inlined and replaces them with `[image]`/`[document]`.
2. Drop turns whose content is a recognizable `skill_discovery`/`skill_listing` reinjection
   marker (match the prefix our skills listing uses).
3. Because zcode `HistoryTurn` is plain text and our attachments are resolved to file paths
   before storage (`cli/repl_attachments.zig`), this is largely a no-op today - implement it as
   a thin, well-tested pass and document that it becomes load-bearing once multimodal turns
   exist. Keep it cheap.

**Acceptance criteria.**
- Unit test: a turn containing an inlined image marker yields `[image]` in the built prompt; a
  plain-text turn is unchanged.
- Unit test: a `skill_listing` reinjection turn is omitted from the summarizer prompt.

**Test strategy.** Pure-function tests on `buildCompactionPrompt` output under
`tools/test_runner.zig`.

**Risk / footguns.** Do not strip legitimate `[image]`-looking text the user typed; only strip
recognized inlined-attachment forms. Keep it conservative.

**Size.** S.

---

### Task 11 - Native API context-management edits (compaction-09) [opt-in / deferable]

**Goal.** Build a `ContextManagementConfig` (clear_tool_uses_20250919 / clear_thinking_20251015)
and emit it in the Anthropic request body when explicitly opted in via env, so the server clears
old tool results/thinking without local mutation.

**Reference behavior.** `apiMicrocompact.ts:34-153` (`getAPIContextManagement`, strategy
thresholds, ant-only gating on `clear_tool_uses`, `clear_thinking` general).

**Target Zig files.**
- Create `src/core/context_management.zig` (deep module): build the config struct + JSON
  serialization; register in `src/main.zig` comptime block.
- Edit `src/core/types.zig` `ModelRequest` (`:264-313`): add
  `context_management: ?[]const u8 = null` (a verbatim JSON object, same pattern as
  `response_schema` at `:300-308`).
- Edit `src/providers/anthropic.zig` `writeRequestBody` (`:352`): emit a `context_management`
  field when the request carries one; keep the existing `ZCODE_ANTHROPIC_BETA` header
  passthrough (`:57-86`) for the beta opt-in.

**Approach.**
1. `context_management.zig`: emit `{"edits":[{"type":"clear_thinking_20251015","keep":...},
   {"type":"clear_tool_uses_20250919","trigger":{...},"clear_at_least":{...},...}]}` gated by
   env (`USE_API_CLEAR_TOOL_RESULTS`, `USE_API_CLEAR_TOOL_USES`, `API_MAX_INPUT_TOKENS`,
   `API_TARGET_INPUT_TOKENS`) mirroring the reference defaults (180k trigger, 40k target).
   `clear_tool_uses` only when the ant/internal opt-in env is set; `clear_thinking` available
   generally when thinking is active.
2. Thread the built JSON string into `ModelRequest.context_management` from the agent runtime
   when the relevant betas are enabled.
3. `anthropic.zig` writes it verbatim into the body (reuse the verbatim-JSON embedding pattern
   already used for `response_schema`).

**Acceptance criteria.**
- Unit test: `buildConfig` with `USE_API_CLEAR_TOOL_RESULTS=1` produces a JSON containing
  `clear_tool_uses_20250919` and the right trigger/clear_at_least values; with no env it
  returns null.
- Unit test: `writeRequestBody` includes a `"context_management"` key when the request has one
  and omits it otherwise (string-contains on the built body).

**Test strategy.** Pure-function JSON build tests + a `writeRequestBody` body-contains test
under `tools/test_runner.zig`.

**Risk / footguns.** This is feature-gated/ant-only in the reference; default-off in zcode. Do
not emit the field unless explicitly opted in (avoid breaking non-supporting Anthropic
endpoints). Validate the JSON is a bare object literal (not quoted), same caveat as
`response_schema` (`types.zig:303`).

**Size.** M (deferable).

---

### Task 12 - Partial / pivot-anchored compaction (compaction-07) [experimental / deferable]

**Goal.** Summarize messages before/after a user-selected pivot index, preserving the other
side verbatim, with direction-driven prompt variants ('from' vs 'up_to').

**Reference behavior.** `compact.ts:772-1106` (`partialCompactConversation`);
`prompt.ts:145-291` (`PARTIAL_COMPACT_PROMPT` and `PARTIAL_COMPACT_UP_TO_PROMPT`);
`prompt.ts:274-291` (`getPartialCompactPrompt(direction)`).

**Target Zig files.**
- Edit `src/core/compaction.zig`: add `partialCompact(allocator, history, pivot, direction, summarizer, instructions) !CompactionResult`
  and the two prompt variants (`buildPartialCompactPrompt(direction, ...)`).
- Edit `src/repl_overlay.zig` (message selector, `:4249-4334`): add a key path that invokes
  partial compaction at the selected index.

**Approach.**
1. Define `PartialDirection = enum { from, up_to }`. For `from`: summarize history[pivot..] and
   keep history[..pivot] verbatim; the summary follows the kept prefix. For `up_to`: summarize
   history[..pivot] and keep history[pivot..] verbatim; the summary precedes the kept suffix
   (use the "Context for Continuing Work" prompt variant).
2. Build the appropriate prompt template (port `PARTIAL_COMPACT_PROMPT` /
   `PARTIAL_COMPACT_UP_TO_PROMPT` 9 sections).
3. Produce a `CompactionResult` whose summary covers only the summarized range and whose
   boundary marker (Task 6) records the preserved segment.
4. Wire the message-selector overlay to call it on a keypress, passing the highlighted index as
   the pivot.

**Acceptance criteria.**
- Unit test: `partialCompact(history, pivot=2, .from, stub_summarizer)` keeps the first 2 turns
   verbatim and replaces the rest with a summary turn; `.up_to` does the inverse.
- Test: the boundary marker records the preserved-segment indices.

**Test strategy.** Pure-function tests with a stub summarizer under `tools/test_runner.zig`. The
overlay wiring gets a manual check only.

**Risk / footguns.** Preserve API invariants when slicing: do not split a tool turn from the
assistant turn that produced it (zcode pairs them positionally). Document that the message
selector is otherwise navigation-only today.

**Size.** L (deferable).

---

### Task 13 - Token/text-block bounded keep-window (compaction-11) [experimental / deferable]

**Goal.** Provide an opt-in alternative to LLM compaction: keep a recent window bounded by
min/max tokens and a min text-block-message count, adjusting the boundary so it does not split
tool_use/tool_result pairs, using accumulated session memory as the "summary".

**Reference behavior.** `sessionMemoryCompact.ts:232-503` (`adjustIndexToPreserveAPIInvariants`,
`calculateMessagesToKeepIndex`, `createCompactionResultFromSessionMemory`).

**Target Zig files.**
- Create `src/core/keep_window_compact.zig` (deep module); register in `src/main.zig` comptime
  block.
- Edit `src/agent_history.zig`: an opt-in path that uses it instead of `maybeCompact` when a
  config flag is set.

**Approach.**
1. `calculateKeepIndex(history, min_tokens=10_000, min_text_block_msgs=5, max_tokens=40_000) usize`
   walking from the tail, accumulating tokens until min bounds are met without exceeding max.
2. `adjustIndexToPreserveInvariants(history, idx)`: nudge `idx` so it does not split a paired
   tool turn (zcode positional pairing) or a contiguous assistant/tool block.
3. `createResultFromSessionMemory`: use `snapshot.handoff_summary` / promoted memory
   (`promoteToMemory`, `compaction.zig:477-508`) as the summary; keep `history[idx..]` verbatim.
4. Gate behind a config flag (default off), matching the reference's experimental gating.

**Acceptance criteria.**
- Unit test: `calculateKeepIndex` respects min/max bounds on a synthetic history.
- Unit test: `adjustIndexToPreserveInvariants` never returns an index that splits a tool pair.

**Test strategy.** Pure-function tests under `tools/test_runner.zig`.

**Risk / footguns.** Experimental and low priority; keep entirely behind a default-off flag so
it cannot regress the default compaction path. Reuse existing memory promotion rather than
re-implementing session memory.

**Size.** L (deferable).

---

## Verification

How to prove the whole phase is done:

1. **Build and test (debug):**
   `~/.local/zig/zig-aarch64-macos-0.16.0/zig build test` - all new `compaction.zig`,
   `autocompact_threshold.zig`, `post_compact_files.zig`, `context_management.zig`,
   `prompt_analysis.zig`, and `prompt_helpers.zig` tests pass under `tools/test_runner.zig`
   (watch the `RUN: <name>` lines for hangs).

2. **Release build + install (per CLAUDE.md, exactly):**
   ```
   zig build -Doptimize=ReleaseFast
   rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode
   ```
   (`rm -f` first to avoid the macOS in-place-overwrite ad-hoc-signature SIGKILL footgun.)

3. **Version bump:** bump `.version` patch in `build.zig.zon` (the git hash is appended
   automatically); confirm `zcode version` runs without "Killed: 9".

4. **Manual checks:**
   - With the `mock` provider, run a session long enough to trigger `/compact focus on the
     build errors`; confirm the resulting `compacted_summary:` turn contains a model-style
     summary AND reflects the focus instruction (compaction-01, compaction-06).
   - Configure a PreCompact and a PostCompact hook in `settings.json` that each append a line to
     a temp file; run `/compact`; confirm both fired in order and the PostCompact hook received
     the summary (compaction-05).
   - Run `/context` and confirm the per-tool breakdown section renders (compaction-12).
   - Set `CLAUDE_CODE_AUTO_COMPACT_WINDOW=100000` and confirm the warning UI percentLeft uses
     the buffer model (compaction-03).
   - After a compaction, confirm the next assistant turn resumes the task without re-greeting or
     asking a redundant question (compaction-16), and the capacity warning is suppressed for one
     turn (compaction-17).
   - After a compaction, confirm recently-read files reappear as context (compaction-08).

5. **Regression guard:** confirm offline/no-adapter compaction (no provider configured) still
   produces the rule-based summary (Task 1 fallback) and that the existing
   `"compacts above threshold"` test still passes.

## Out-of-scope / deferred notes

- **Proactive-mode continuation variant** (`prompt.ts:362-367`): zcode has no
  autonomous/proactive mode, so the proactive branch of the continuation directive is omitted
  (Task 5). Revisit if a proactive mode lands.
- **PTL (prompt-too-long) retry loop on the compaction call** (`compact.ts:450-491`,
  `truncateHeadForPTLRetry`): the reference retries the summarizer call by dropping oldest
  API-round groups when the compaction request itself overflows. zcode's reactive compaction
  (`reactive_compaction.zig`) already peels the tail on request overflow; a dedicated
  compaction-call PTL retry is deferred and noted as a follow-up.
- **Forked-agent cache-prefix sharing** (`compact.ts:431-438`,
  `streamCompactSummary` forked-agent path): zcode uses a single one-shot adapter call; the
  forked-agent cache-sharing optimization and its streaming fallback are deferred.
- **Tasks 11-13** (native API context edits, partial/pivot compaction, bounded keep-window) are
  feature-gated/experimental in the reference and are implemented default-off or deferred if the
  phase is time-boxed; they must never regress the default compaction path.
- **tengu_compact telemetry fields** (`compact.ts:650-695`): the rich analytics event is
  out of scope; we only persist the boundary metadata needed for resume fidelity (Task 6).
- **Attachment/local-command token categories** in `/context` (Task 8) are best-effort until
  `HistoryTurn` carries structured block types instead of flat text; documented, not faked.
