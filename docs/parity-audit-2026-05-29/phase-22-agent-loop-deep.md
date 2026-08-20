# Phase 22: Agent loop internals (query.ts/QueryEngine.ts depth)

## Overview

**What.** This phase deepens the core agentic turn loop in `agent_runtime.zig` so the cancellation, recovery, and continuation semantics match the reference `query.ts`/`QueryEngine.ts` instead of the current "append a plain text turn and break" shortcuts. The reference loop is a coroutine with carefully separated states: it distinguishes a *submit-interrupt* (user typed a new message mid-turn) from a *hard interrupt* (Esc-Esc), synthesizes a `tool_result` for every emitted-but-unrun tool so the model's view stays consistent, escalates the output-token cap before giving up, wires a configured fallback model into the live error path, and fires Stop hooks at turn-end to allow hook-gated continuation. zcode has the building blocks for several of these (helper modules `fallback_model.zig`, `reactive_compaction.zig`, `budget_control.zig`, the `messages.zig` interrupt/reject constants, Stop/SubagentStop hook events) but the call sites in the loop are missing - they are dead code.

**Why.** zcode keeps history as a flat array of role-tagged turns (`agent_history.zig`) rather than strict Anthropic `tool_use`/`tool_result` pairs, so a missing `tool_result` does not hard-400 the next request. But the *consequences* still bite: a turn cancelled mid-batch records emitted-but-unrun tool calls with no outcome, so the model re-attempts or hallucinates results on the next turn; a withheld-then-surfaced max-output-tokens error fails a turn that one 64k retry would have completed; an overloaded primary model fails the turn even though a fallback is configured; and a 413 prompt-too-long fails the turn even though `reactive_compaction.reduce()` exists and could rescue it. These are reliability gaps a CLI user feels directly.

**Dependencies on earlier phases.** This phase assumes the hook subsystem from the hooks phase (PreToolUse/PostToolUse firing in `agent_tools.zig`, the `hook_event.zig`/`hook_config.zig`/`hook_io.zig` contract) is already landed - Phase 22 only adds the Stop/SubagentStop *firing* at turn-end, reusing that plumbing. It assumes the compaction phase (`compaction.zig`, `agent_history.forceCompaction`) is landed - Phase 22 wires `reactive_compaction.reduce()` into the error path, it does not build compaction. It assumes the cancellation/spinner plumbing (`providers/common.zig` `cancel_requested`, `ProgressReporter.is_cancelled`) exists - Phase 22 *extends* the cancel signal with a reason field. No dependency on the SDK/protocol phases; the SDK-stream items here are explicitly out of scope.

**Effort.** Medium-to-large. Seven in-scope build items (one M-S, five M, plus the cancel-reason refactor that several depend on). Roughly 1500-2200 LOC of agent-loop changes plus tests. The highest-value, lowest-risk wins are agent-loop-deep-01 (synthetic tool_result on abort), -03 (fallback wiring - the helper already exists), and -04b (8k->64k escalation). The streaming-specific items (-08 streaming-as-blocks-arrive, -10 tombstoning) are documented deviations because zcode uses whole-response calls, not an incremental streaming parser.

## Scope split

| Item | id | IN/OUT | Reason |
|---|---|---|---|
| Synthetic tool_result on abort for in-progress/queued tools | agent-loop-deep-01 | IN | High severity. Cancelled turns leave emitted-but-unrun tool calls with no recorded outcome; desyncs the model next turn. `messages.zig` constants already exist but are unused in abort paths. |
| Submit-interrupt vs hard-interrupt distinction | agent-loop-deep-02 | IN | Foundational refactor (cancel signal needs a reason field); -01 and the recovery messages depend on it. The prompt queue already exists; only the reason discrimination is missing. |
| Mid-stream model-switch fallback with history-stripping | agent-loop-deep-03 | IN (adapted) | High severity, but adapt: zcode does whole-response (non-streaming) calls and has no thinking-signature replay, so the "strip signatures / tombstone partials / discard executor" parts are no-ops. The substantive part - wire `fallback_model.pick()` into the error handler and retry - is real, low-risk dead-code-activation. |
| Withheld max_output_tokens: 8k->64k escalate + recovery | agent-loop-deep-04 | IN (the escalation only) | The resume-nudge multi-turn recovery is present (cap 5). The concrete missing piece is the single-shot escalate-the-cap-and-retry. Align the recovery cap to 3 for max-output cases and make escalation fire first. |
| Per-iteration recoverable-error withholding (413 -> reactive compact + retry) | agent-loop-deep-14 | IN (the CLI-relevant transform) | `reactive_compaction.reduce()` exists and is never called. On 413, reduce history and retry instead of failing the turn. The SDK "withhold from stream" framing is out; the recover-instead-of-fail behavior is in. |
| Stop-hook-gated loop continuation at turn-end | agent-loop-deep-12 | IN | Hook config/exec plumbing exists; Stop/SubagentStop events are defined and blocking-capable but never fired. Only the firing + blocking-error continuation is missing. |
| Typed terminal result subtypes (max_turns / max_budget_usd / structured-output-retries) | agent-loop-deep-11 | IN (the underlying limits, not the SDK envelope) | The USD budget cap and structured-output retry cap are CLI-relevant limits genuinely absent. max_turns is present-different (text vs typed). Add the limits and a `terminal_reason` enum on `TurnResult`; the SDK envelope shape is out. |
| Queued-command snapshot/consume mid-turn | agent-loop-deep-05 | OUT | zcode is single-conversation; the agentId-scoped process-global command queue with mid-turn task-notification injection has no analogue. Only matters once background tasks surface into a running turn. |
| SDKUserMessageReplay emission | agent-loop-deep-06 | OUT | First-party SDK/agent-protocol surface feeding cowork/desktop. zcode has no SDK message stream. |
| SDKCompactBoundary typed protocol event | agent-loop-deep-07 | OUT | Compaction itself is present (`compaction_applied` flag); only the SDK boundary-event emission is missing, which overlaps the SDK-protocol scope. |
| Streaming executor: as-blocks-arrive + per-input concurrency + exclusive interleave + ordered-buffer-with-progress | agent-loop-deep-08 | OUT | zcode parallelizes read-only tools (the main win). Streaming-as-blocks-arrive and per-input classification require an incremental streaming parser zcode does not have. |
| Sibling-error cancellation (Bash error aborts siblings) | agent-loop-deep-09 | OUT (mostly) | zcode only parallelizes read-only/inspection tools where independent-failure is correct; Bash is not parallel-eligible. The general abort path is absent but low value. A small local stub (honor cancel in the batch executor) is noted. |
| Streaming-fallback orphan tombstoning + executor discard/recreate | agent-loop-deep-10 | OUT | Artifact of whole-response calls; the orphan/tombstone problem does not arise. |
| Permission-denial tracking for result envelope | agent-loop-deep-15 | OUT | Per-tool denial tracking already exists (`ToolTrace.approval_state`). The aggregated `permission_denials[]` is meaningless without the SDK envelope. |

## Gaps covered

| id | title | severity | size | our current state |
|---|---|---|---|---|
| agent-loop-deep-01 | Synthetic tool_result on abort for in-progress/queued tools | high | M | `agent_runtime.zig:866-868,1176-1178` append plain `"Cancelled by user."`; remaining `parsed.tool_calls` get no per-tool outcome. `messages.zig` `SYNTHETIC_TOOL_RESULT_PLACEHOLDER`/`REJECT_MESSAGE`/`INTERRUPT_MESSAGE_FOR_TOOL_USE` defined but unused in abort paths. |
| agent-loop-deep-02 | Submit-interrupt vs hard-interrupt distinction | medium | M | Single atomic `cancel_requested: bool` (`providers/common.zig:39`); no reason/kind field. All paths emit identical messages. `prompt_queue` exists but the loop never inspects it to detect a submit-interrupt. |
| agent-loop-deep-03 | Mid-stream model-switch fallback w/ history-stripping | high | M | `fallback_model.pick()`/`triggerFromStatus()` defined and unit-tested (`core/fallback_model.zig`), `cfg.fallback_model`/`fallback_provider` exist, providers classify 429/529/503; but no caller. Error handler (`agent_runtime.zig:1129-1165`) logs + breaks. Auto-switch explicitly disabled (`agent_history.zig:363`, `agent_runtime.zig:2893`). |
| agent-loop-deep-04 | Withheld max_output_tokens: 8k->64k escalate + recovery | medium | M | Multi-turn truncation recovery present (cap 5, `agent_runtime.zig:1423-1427,1512-1519`). No 8k->64k single-shot escalation; `request.max_output_tokens` fixed at `cfg.reserved_output_tokens` (`:1115`). No typed max-output-tokens error detection. |
| agent-loop-deep-14 | Per-iteration recoverable-error recovery (413 -> reactive compact) | medium | M | `reactive_compaction.zig` exists (`isOverLimitStatus(413)`, `reduce()`), registered in `main.zig:102`, but never called. 413 maps to generic `error.HttpStatusCode` (`providers/common.zig:745`); errors surface immediately and break. |
| agent-loop-deep-12 | Stop-hook-gated loop continuation at turn-end | medium | M | Stop (`hook_event.zig:49`) and SubagentStop (`:54`) events defined, blocking-capable (`:89`), parsed by `hook_config.zig`. PreToolUse/PostToolUse fire (`agent_tools.zig`). Stop/SubagentStop never fired; no continuation logic. |
| agent-loop-deep-11 | Typed terminal limits: max_turns / max_budget_usd / structured-output-retries | medium | M | `TurnResult` (`agent_runtime.zig:75-89`) has no terminal-reason discriminator. max_turns surfaced as text (`:1969-1975`). `cost.zig` estimates cost but no USD gate. No structured-output retry counter/cap. |

## Implementation tasks

> Conventions: new logic goes into `core/` deep modules where it is pure (so it is unit-testable without the loop), and the loop in `agent_runtime.zig` calls them. Register every new `core/*.zig` module in the `comptime { _ = @import(...); }` block in `src/main.zig` (around lines 41-103) so its tests run. All cross-module imports use `@import("zcode_runtime")` for the runtime singleton, never relative paths to it. Tests run under `tools/test_runner.zig`.

---

### Task 22.1 - Cancel signal carries a reason (foundation for -01, -02)

**Goal.** Replace the single `cancel_requested: bool` with a signal that also records *why* the cancel fired - `interrupt` (user submitted a new message mid-turn) vs `hard` (Esc-Esc / Ctrl+C) - so downstream paths can suppress the synthetic interruption message on a submit-interrupt, matching the reference's `signal.reason !== 'interrupt'` checks.

**Reference behavior + file:line.** `query.ts:1044-1050` and `:1499-1505` skip `createUserInterruptionMessage` when `abortController.signal.reason === 'interrupt'`. `StreamingToolExecutor.ts:219-229` `getAbortReason` branches on `reason === 'interrupt'`.

**Target Zig files.** `src/providers/common.zig` (the global cancel signal, lines 39-79), `src/repl.zig` (`ProgressReporter`), `src/repl_spinner.zig` (Esc-Esc / Ctrl+C handler, prompt-queue submit path), `src/core/cancel_reason.zig` (new pure enum + helper).

**Approach.**
1. New `core/cancel_reason.zig`: `pub const CancelReason = enum { none, hard, submit_interrupt };` plus a pure helper `pub fn suppressInterruptionMessage(r: CancelReason) bool { return r == .submit_interrupt; }`. Register in `main.zig` comptime block.
2. In `providers/common.zig`, keep `cancel_requested: std.atomic.Value(bool)` (the hot-path check stays a single atomic load) and add a parallel `cancel_reason: std.atomic.Value(u8)` storing the enum tag. `requestCancel(reason)` stores both; `reset()` clears both to `.none`. Add `pub fn cancelReason() CancelReason`.
3. Esc-Esc / Ctrl+C handler in `repl_spinner.zig` calls `requestCancel(.hard)`. The mid-turn prompt-submit path (where a user types and submits while a turn is in flight) calls `requestCancel(.submit_interrupt)` AND enqueues the prompt (existing `prompt_queue` behavior) so the queued message becomes the next turn's input.
4. Thread `CancelReason` onto `ProgressReporter` via an optional `cancel_reason: ?*const fn (*anyopaque) cancel_reason.CancelReason` getter, defaulting to `.hard` for callers that do not provide it.

**Acceptance criteria.** Write a test in `cancel_reason.zig` that `suppressInterruptionMessage(.submit_interrupt) == true` and `== false` for `.hard`/`.none`. Write a test in `providers/common.zig` that `requestCancel(.submit_interrupt)` then `cancelReason() == .submit_interrupt` and `isCancelRequested() == true`, and `reset()` returns both to baseline.

**Test strategy.** Pure unit tests under the custom runner; no IO needed. The reporter wiring is exercised by Task 22.2's loop test using a stub reporter.

**Risk + 0.16 footguns.** `std.atomic.Value(u8)` for the enum tag - store/load with `.release`/`.acquire` to match the existing bool. Do not widen the hot-path check; keep `isCancelRequested()` reading only the bool.

**Size.** M (small-M; mostly mechanical threading).

---

### Task 22.2 - Synthetic tool_result on abort for in-progress/queued tools (agent-loop-deep-01)

**Goal.** When a turn is aborted after the model emitted `tool_use` blocks, record a structured outcome for every emitted-but-unrun tool instead of leaving it silent. On a hard interrupt, use the reject/interrupt phrasing; on a submit-interrupt, suppress the standalone interruption turn (the queued message provides context) but still record per-tool outcomes so the model does not re-issue them.

**Reference behavior + file:line.** `query.ts:1015-1029` drains `getRemainingResults()` / `yieldMissingToolResultBlocks('Interrupted by user')`. `query.ts:123-149` `yieldMissingToolResultBlocks` emits an `is_error` tool_result per orphaned `tool_use`. `StreamingToolExecutor.ts:153-205` `createSyntheticErrorMessage` (REJECT_MESSAGE for `user_interrupted`).

**Target Zig files.** `src/agent_runtime.zig` (the two abort break sites: `:866-870` round-top check and `:1176-1180` post-model check, plus the inter-tool break at `:1720-1726`), `src/core/messages.zig` (reuse existing constants; no new strings needed), optionally a small helper `synthesizeUnrunToolResults` private to `agent_runtime.zig`.

**Approach.**
1. Add a private method `fn appendSyntheticToolResultsForRemaining(self, parsed_tool_calls, executed_flags, start_idx, reason) !void` that, for each tool call not yet executed, appends a `.tool` history turn of the shape the loop already uses (`tool={name}\nargs={args}\nstate=cancelled\nrisk=...\noutput=<message>`) where `<message>` is `messages.INTERRUPT_MESSAGE_FOR_TOOL_USE` (hard) or `messages.SYNTHETIC_TOOL_RESULT_PLACEHOLDER` (fallback path - reused by Task 22.3). This keeps the flat-history format consistent with how successful tool turns are recorded at `:1690`.
2. At the inter-tool cancellation break (`:1720-1726`), before breaking, call the helper for `parsed.tool_calls[call_idx..]` (everything from the current index onward, skipping `parallel_executed[i]`) so queued-and-not-yet-run tools get a cancelled outcome.
3. At the post-model abort check (`:1172-1182`): if `parsed.tool_calls.len > 0`, call the helper for the whole batch (none executed yet at that point) before appending the final turn.
4. Gate the standalone `"Cancelled by user."` / `INTERRUPT_MESSAGE` final turn on `!cancel_reason.suppressInterruptionMessage(reporterCancelReason())` so a submit-interrupt skips it (Task 22.1).

**Acceptance criteria.** Write a loop-level test (a `MockAdapter` returning a response with two `tool_use` calls, plus a stub reporter whose `is_cancelled` returns true after the first tool) that asserts the history after the turn contains a `.tool` turn with `state=cancelled` for the second, unrun call, and that on a `.submit_interrupt` reason no standalone `INTERRUPT_MESSAGE` assistant turn is appended while on `.hard` it is.

**Test strategy.** Use the existing mock provider/adapter pattern in `agent_runtime` tests; assert on `self.history.view()` turn roles/contents. Run under `tools/test_runner.zig` (`RUN:` line confirms no hang).

**Risk + 0.16 footguns.** Memory: each synthetic turn dupes name/args; use the same per-dupe `errdefer` discipline as `:1698-1703` to avoid leaks on OOM. Do not call `Child.wait()` after a killed tool subprocess - `kill(io)` reaps internally (CLAUDE.md gotcha). Keep the format string identical to the success path so transcript rendering and `pushRecentOutcome` stay uniform.

**Size.** M.

---

### Task 22.3 - Fallback model wiring on overload/rate-limit (agent-loop-deep-03)

**Goal.** Activate the dead `fallback_model.zig` helper: when the live model call fails with an overload/rate-limit status and a fallback is configured, switch to it, emit a one-line "Switched to X due to high demand" notice, and retry the same request once. Omit the streaming-only parts (tombstoning partials, stripping thinking signatures, discarding a streaming executor) because zcode uses whole-response calls and has no thinking-signature replay.

**Reference behavior + file:line.** `query.ts:893-951` `FallbackTriggeredError` handler: `currentModel = fallbackModel`, clear assistant/tool state, `stripSignatureBlocks` (ant-only), "Switched to ... due to high demand" system message, `continue`. The streaming/executor-discard parts (`:912-919`, tombstones `:716-718`) are skipped here.

**Target Zig files.** `src/agent_runtime.zig` (error handler at `:1129-1165`), `src/core/fallback_model.zig` (already exists; add a `statusFromProviderError` mapping if needed), `src/providers/common.zig` (already classifies 429/529/503 - reuse). Update the disabling comments at `agent_runtime.zig:2893-2896` and `agent_history.zig:363-364` to reflect the new opt-in behavior.

**Approach.**
1. The error must carry a status. Confirm `callModel` surfaces the HTTP status (providers already classify it at `common.zig:723-726`). If only `error.HttpStatusCode` reaches the handler, thread the last-seen status through the response/error path (a thin `self.last_http_status` set in the provider call wrapper) so the handler can call `fallback_model.triggerFromStatus(status)`.
2. In the `callModel ... catch |err|` block (`:1129`), before the generic `describeProviderError` path: if `!was_cancelled`, compute `trigger = fallback_model.triggerFromStatus(self.last_http_status)` and `pick(self.active_model, self.cfg.fallback_model, trigger)`. If non-null AND we have not already swapped this turn (`fallback_swapped` local guard, fire-once): set `self.active_model`/`self.active_provider` to the fallback, append a `.system` turn `"Switched to {fallback} due to high demand for {original}"`, emit progress, and `continue` the round loop to retry the same request. Otherwise fall through to the existing error-surface-and-break path.
3. Make it opt-in: only swap when `self.cfg.fallback_model.len > 0`. Keep the "never silently switch" guarantee by requiring the user to have explicitly configured a fallback (the config field already exists).

**Acceptance criteria.** Write a loop test with a `MockAdapter` that returns a 529-classified error on the first call and a normal final response on the second, with `cfg.fallback_model = "haiku"`. Assert: the turn completes successfully, history contains a `.system` "Switched to haiku due to high demand" turn, and the second call used `active_model == "haiku"`. A second test with empty `cfg.fallback_model` asserts the error surfaces and the turn breaks (no swap).

**Test strategy.** Extend the mock-adapter test harness so the mock can return a status-classified error on call N. Assert on `final_text` and `history.view()`. Run under `tools/test_runner.zig`.

**Risk + 0.16 footguns.** Do not double-swap into an infinite retry: the fire-once `fallback_swapped` guard is load-bearing (if the fallback is also overloaded, surface the error). `active_provider`/`active_model` are `[]const u8` - dupe from cfg into runtime-owned storage if cfg outlives differently; check existing ownership of `self.active_model`. This is the lowest-risk item because the pure helper and tests already exist; only the call site is new.

**Size.** M.

---

### Task 22.4 - Max-output-tokens 8k->64k escalation (agent-loop-deep-04)

**Goal.** Before falling back to the multi-turn resume-nudge recovery, detect a max-output-tokens cutoff and, if the request used the default cap, retry the same request once at an escalated cap (mirroring the reference's `ESCALATED_MAX_TOKENS = 64k`). Align the max-output recovery cap to the reference's 3 for this specific case (general truncation recovery stays at 5).

**Reference behavior + file:line.** `query.ts:175-179` `isWithheldMaxOutputTokens`; `:1188-1221` escalate to `ESCALATED_MAX_TOKENS` (fires once, guarded by `maxOutputTokensOverride === undefined`); `:1223-1252` then the `count < MAX_OUTPUT_TOKENS_RECOVERY_LIMIT (3)` resume-nudge loop.

**Target Zig files.** `src/agent_runtime.zig` (the request build at `:1111-1122` and the truncation-recovery branches at `:1423-1427` and `:1512-1519`), `src/core/types.zig` (response - add a typed `max_output_tokens_hit: bool` if the provider can surface it; otherwise reuse `response.truncated` + a finish-reason check), `src/core/max_output_escalation.zig` (new pure helper).

**Approach.**
1. New `core/max_output_escalation.zig`: `pub const DEFAULT_CAP: u32 = 8192; pub const ESCALATED_CAP: u32 = 65536;` plus `pub fn nextCap(current_cap: u32, already_escalated: bool) ?u32` returning `ESCALATED_CAP` only when `current_cap <= DEFAULT_CAP and !already_escalated`, else null. Register in `main.zig`.
2. Add an `output_cap_override: ?u32` field to the runtime (loop-local), defaulting null, that overrides `request.max_output_tokens` at `:1115` when set.
3. When the model response is truncated specifically due to the output-token cap (finish_reason length AND the response came back at-or-near the cap), call `nextCap(effective_cap, self.output_escalated)`. If non-null: set `output_cap_override`, set `self.output_escalated = true`, emit progress, and `continue` to retry the SAME messages at 64k. If null: fall through to the existing resume-nudge loop, but cap *that* loop at 3 attempts for the max-output case (keep the broader truncation cap at 5).

**Acceptance criteria.** Write a test in `max_output_escalation.zig`: `nextCap(8192, false) == 65536`, `nextCap(65536, false) == null` (already at escalated cap), `nextCap(8192, true) == null` (already escalated this turn). Write a loop test: mock returns a length-truncated response when called at the 8k cap and a complete response when the request's `max_output_tokens == 65536`; assert the turn completes and the second request carried the 64k cap.

**Test strategy.** Pure tests for the helper; loop test asserts on the request's `max_output_tokens` captured by the mock adapter. Run under `tools/test_runner.zig`.

**Risk + 0.16 footguns.** The escalation must fire once per turn, not per round - reset `output_escalated` only at turn start. Do not double-apply with the general truncation-continuation branch; the escalation is a *single-shot same-request retry*, the nudge is a *new-turn continuation*. Keep them ordered: escalate first, nudge second.

**Size.** M.

---

### Task 22.5 - 413 reactive-compact-and-retry instead of fail (agent-loop-deep-14)

**Goal.** Wire the existing-but-uncalled `reactive_compaction.reduce()` into the live error path: on a prompt-too-long / 413, reduce history (keep system turns + the last N non-system turns) and retry the request once, instead of surfacing the error and breaking. Only surface the 413 if the reduced retry still fails.

**Reference behavior + file:line.** `query.ts:1085-1118` (`isWithheld413` -> collapse drain / reactive compact, then retry via `continue`); `:1168-1175` surface only after recovery is exhausted, guarded by `hasAttemptedReactiveCompact` to prevent a spiral. zcode's analogue drops the collapse-drain stage (no context-collapse subsystem) and keeps the reactive-reduce stage.

**Target Zig files.** `src/agent_runtime.zig` (error handler `:1129-1165`), `src/core/reactive_compaction.zig` (exists; `reduce()` + `isOverLimitStatus`), `src/agent_history.zig` (a `replaceHistory(reduced)` helper if one does not exist - `truncateFrom` exists but reactive-reduce keeps system turns interleaved, so a full-replace is cleaner).

**Approach.**
1. In the `callModel ... catch` block, after the cancel check and before the generic error surface: if `reactive_compaction.isOverLimitStatus(self.last_http_status)` (or the error maps to prompt-too-long) AND `!self.attempted_reactive_compact`: call `reactive_compaction.reduce(allocator, self.history.view(), KEEP_LAST_N)`, replace the runtime history with the reduced slice (dupe contents into history-owned storage), set `self.attempted_reactive_compact = true`, emit progress `"context too large, compacting and retrying"`, set `compaction_applied = true` on the eventual `TurnResult`, and `continue` to retry.
2. If `attempted_reactive_compact` is already true (the reduced retry still 413'd), fall through to the existing surface-and-break path - do not loop. This is the spiral guard.
3. `KEEP_LAST_N` should track the existing compaction config (reuse `cfg`'s history-window setting if present; otherwise a constant like 8).

**Acceptance criteria.** Write a loop test: mock returns a 413-classified error on the first call (with a long history) and a normal response on the second; assert the turn completes, `TurnResult.compaction_applied == true`, and the history passed to the second call is shorter (system turns preserved). A second test where both calls 413 asserts the error surfaces after exactly one reduce attempt (no spiral).

**Test strategy.** `reduce()` already has pure tests; add the loop-integration test with the mock adapter. Run under `tools/test_runner.zig`.

**Risk + 0.16 footguns.** `reduce()` returns shallow copies that borrow from the input history (`reactive_compaction.zig` comment), so replacing the live history in place needs care: dupe the kept turns' contents into history-owned memory before freeing the old turns, or the borrowed slices dangle. The `ObjectMap`/pointer-desync footgun does not apply here, but the borrow-vs-own distinction is the live hazard - write the test to free and re-run to catch a use-after-free under the leak-checking allocator.

**Size.** M.

---

### Task 22.6 - Stop-hook-gated continuation at turn-end (agent-loop-deep-12)

**Goal.** Fire the Stop hook (SubagentStop for subagents) when the model produces no tool call and the turn would end. If a hook blocks (exit code 2), append its blocking error to history and continue the loop for one more turn; preserve the reactive-compact guard to avoid a hook->retry->error spiral.

**Reference behavior + file:line.** `query.ts:1267-1306` `handleStopHooks`; `preventContinuation` -> `{reason:'stop_hook_prevented'}`; `blockingErrors` appended and loop continues with `hasAttemptedReactiveCompact` preserved (`:1292-1297` explains the spiral). `query/stopHooks.ts` is the hook runner. `hook_event.zig:81-89` already marks Stop/SubagentStop blocking-capable.

**Target Zig files.** `src/agent_runtime.zig` (the natural turn-end break points where `parsed.tool_calls.len == 0` and no recovery fired, e.g. the native-mode `break` near `:1500` and the non-native end), `src/hooks.zig` (file-based hook discovery hardcodes only `.pre_tool_use`/`.post_tool_use`/`.post_tool_use_failure` at `:79` per the survey - extend to discover `.stop`/`.subagent_stop`), `src/agent_tools.zig` (reuse the PreToolUse/PostToolUse firing+blocking pattern from `:759-793`).

**Approach.**
1. Add a private `fn runStopHooks(self, is_subagent) !StopHookOutcome` returning `enum { proceed, prevent_continuation }` plus an optional blocking-error message. It builds the Stop/SubagentStop hook input (the existing `hook_io.zig` contract), runs matching hooks via the existing runner, and interprets exit codes via `hook_event.interpretExit(.stop, code)`.
2. At each genuine turn-end break (after all recovery/nudge branches decline to continue), before breaking: call `runStopHooks`. If `prevent_continuation`, break with a recorded reason. If a blocking error came back AND we have not exceeded a small stop-hook continuation cap (mirror the reference's intent): append the blocking error as a `.system` turn, preserve `attempted_reactive_compact` (do NOT reset it), set a `stop_hook_active` flag so we do not re-fire endlessly, and `continue`.
3. Skip Stop hooks when the last turn is an API error (the reference's death-spiral guard) - if `final_text` already holds an error message, do not fire.

**Acceptance criteria.** Write a loop test with a configured Stop hook script that exits 2 with a stderr blocking message on the first turn-end and exits 0 on the second; assert the loop runs a second turn (the model is called again), the blocking message is in history, and `attempted_reactive_compact` is not reset between the two turns. A second test: a Stop hook that returns `preventContinuation` semantics ends the loop without a further model call.

**Test strategy.** Use a temp-dir hook config (`core/test_helpers.zig` `tmpDirCwd`/`tmpDirPath` - never pass `"."`) pointing at a tiny shell script; run under `tools/test_runner.zig`. Reuse the PreToolUse hook test scaffolding.

**Risk + 0.16 footguns.** The continuation cap is load-bearing: without it a misbehaving Stop hook loops forever. Use `tmpDirPath` for the hook script path, not a relative path (CLAUDE.md test-helper rule). `std.process.run` for the hook (`std.process.Child.init` is gone in 0.16); `Child.kill(io)` reaps internally - no `wait()` after.

**Size.** M.

---

### Task 22.7 - Typed terminal limits: max_turns, USD budget cap, structured-output retry cap (agent-loop-deep-11)

**Goal.** Give `TurnResult` a `terminal_reason` discriminator and enforce the two genuinely-missing limits: a per-turn USD budget cap (stop when estimated spend exceeds a configured ceiling) and a structured-output retry cap (stop after N failed attempts to produce schema-valid output). Keep max_turns but promote it from an untyped text sentinel to the discriminator. The SDK result-envelope shape stays out of scope.

**Reference behavior + file:line.** `QueryEngine.ts:851-873` `error_max_turns`; `:981-1001` `error_max_budget_usd`; `:1024-1047` `error_max_structured_output_retries` (cap `MAX_STRUCTURED_OUTPUT_RETRIES` default 5); `:618-638` success. zcode mirrors the *limits* and a local discriminator, not the SDK message types.

**Target Zig files.** `src/agent_runtime.zig` (`TurnResult` struct `:75-89`; max-turns site `:1969-1975`; the structured-output path that uses `self.pending_response_schema` at `:1121`; cost accounting `:491`), `src/core/cost.zig` (already has `estimateCost`), `src/core/budget_control.zig` (extend or add a USD decide), `src/core/config.zig` (add `max_budget_usd` and `max_structured_output_retries` fields).

**Approach.**
1. Add `pub const TerminalReason = enum { completed, max_turns, max_budget_usd, max_structured_output_retries, aborted };` and a `terminal_reason: TerminalReason = .completed` field on `TurnResult`. Set it at each terminal break (max-rounds break sets `.max_turns`; abort breaks set `.aborted`; normal completion leaves `.completed`).
2. USD cap: add `cfg.max_budget_usd: f64 = 0` (0 = no cap). After each round's `recordResponseUsage`, compute cumulative estimated cost via `cost.estimateCost`; if `cfg.max_budget_usd > 0` and cumulative cost `>= cfg.max_budget_usd`, set `terminal_reason = .max_budget_usd`, append a `.assistant` turn explaining the stop, and break.
3. Structured-output retry cap: add `cfg.max_structured_output_retries: u32 = 5`. When `self.pending_response_schema != null` and the response fails schema validation, increment a loop-local counter and retry; when it reaches the cap, set `terminal_reason = .max_structured_output_retries` and break with an explanatory turn. (If the structured-output validation path does not yet exist, this task adds the counter+cap around the existing schema field and a basic validity check; full structured-output validation is its own phase if absent.)
4. `final_text` continues to carry a human-readable message for each terminal reason (CLI users see text); the enum is the machine-readable discriminator that `ci_output.zig` can serialize alongside `compaction_applied`.

**Acceptance criteria.** Write a `budget_control.zig` test for a `decideUsd(used_usd, cap_usd) -> Decision` (or equivalent) covering below-cap, at-cap, no-cap. Write a loop test: `cfg.max_budget_usd` set low so the second round trips the cap; assert `TurnResult.terminal_reason == .max_budget_usd` and the loop stopped early. Write a loop test for the structured-output cap: a mock that always returns schema-invalid output with `cfg.max_structured_output_retries = 2`; assert exactly 2 retries then `terminal_reason == .max_structured_output_retries`.

**Test strategy.** Pure tests for the USD decision; loop tests via mock adapter asserting on `TurnResult.terminal_reason` and round count. Run under `tools/test_runner.zig`.

**Risk + 0.16 footguns.** `cost.estimateCost` works on token counts - ensure cumulative input+output tokens are tracked across rounds, not per-round, or the cap never trips on long turns. Keep the structured-output cap independent from `max_tool_rounds` so a schema-retry loop does not also burn the rounds budget silently. The `f64` USD comparison is fine for a ceiling check; do not over-engineer with fixed-point.

**Size.** M.

---

## Documented deviations

These are out-of-scope; documented here (and to be recorded in `docs/PARITY_ROADMAP_V2.md`) so future audits do not re-flag them as untracked.

- **agent-loop-deep-05 (queued-command snapshot/consume mid-turn).** zcode is single-conversation; there is no agentId-scoped process-global command queue with a coordinator and in-process subagents each draining their own slice. The reference's mid-turn injection of task-notification attachments into a running turn (`query.ts:1547-1643`) has no analogue because zcode's prompt queue is between-turns FIFO. *Local stub worth doing later:* if/when background `task.zig` execution needs to surface a completed task's result into an in-flight turn, add a between-round drain point that converts ready task notifications into a `.system` history turn. Not needed now.

- **agent-loop-deep-06 (SDKUserMessageReplay) and -07 (SDKCompactBoundary typed event).** Both are first-party SDK/agent-protocol surfaces (`isReplay` acks, `SDKCompactBoundaryMessage`) that feed cowork/desktop. zcode has no SDK message stream; the run command emits cleaned text and the exec command emits JSON tool-traces. Compaction itself *is* present and is already signaled via the `compaction_applied` flag on `TurnResult` and in `ci_output.zig`. *Local stub worth doing later:* a `--output-format stream-json` mode could emit a best-effort local event stream including a compact-boundary marker; this is a separate feature, not core CLI behavior.

- **agent-loop-deep-08 (streaming-as-blocks-arrive executor) and -10 (orphan tombstoning + executor discard).** zcode uses whole-response (non-streaming) model calls and a synchronous `parseWithNativeToolCalls`, so there is no incremental streaming parser, no partial assistant messages, and no orphan/tombstone problem. zcode already parallelizes read-only tools with a 6-thread wave pool (`concurrent_executor.zig`) and fair-share budgeting - the main throughput win. Per-input concurrency classification (`isConcurrencySafe(input)`) and exclusive-access interleave (`canExecuteTool` lock) matter only with a streaming parser. Revisit only if zcode adopts incremental streaming tool execution.

- **agent-loop-deep-09 (sibling-error cancellation).** zcode only parallelizes read-only/inspection tools, where independent failure is the correct semantics; Bash is not parallel-eligible, so the reference's Bash-error-cascade is moot. *Local stub worth doing:* a small, cheap addition to `concurrent_executor.zig` - have `executeToolThread` check `providers/common.isCancelRequested()` at entry and short-circuit to a "cancelled" output so a hard interrupt during a parallel read-only batch stops scheduling new waves promptly. This is a 10-20 line cancellation-honoring stub, not the full AbortController architecture, and pairs naturally with Task 22.1's cancel signal. Worth doing alongside 22.1 if cheap; otherwise defer.

- **agent-loop-deep-15 (aggregated permission_denials in result envelope).** Per-tool denial tracking already exists via `ToolTrace.approval_state == .denied`, aggregated into `TurnResult.tool_traces[]` and serialized by `ci_output.zig`. A separate top-level `{tool_name, tool_use_id, tool_input}[]` array is meaningless without the SDK envelope and would duplicate data already present in the traces. No work needed; the consumer can filter traces by `approval_state`.

## Verification

After implementing each task and before declaring it done:

1. **Build the test binary and run the full suite** under the custom runner:
   `/Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build test`
   Confirm the new `core/cancel_reason.zig`, `core/max_output_escalation.zig` (and any other new modules) appear via the `main.zig` comptime block so their tests execute, and that the `RUN:` lines for the new loop tests print without hanging.

2. **Bump the patch version** in `build.zig.zon` (`.version = "X.Y.Z"`) per the project rule - `build.zig` appends the git short-hash automatically.

3. **Build the release binary and install it** (per CLAUDE.md, `rm -f` first to avoid the macOS ad-hoc-signature SIGKILL footgun):
   ```
   /Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build -Doptimize=ReleaseFast
   rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode
   zcode version
   ```

4. **Manual checks:**
   - **Fallback (22.3):** set `fallback_model` in config to a second model, force an overload (or point the primary at an unreachable endpoint that classifies as overload), and confirm a real turn emits "Switched to ... due to high demand" and completes on the fallback.
   - **Abort synthesis (22.2):** start a turn that emits multiple tool calls, press Esc-Esc mid-batch, then inspect the next turn / `--exec` JSON and confirm the unrun tools have a recorded cancelled outcome and the model does not re-issue them.
   - **Submit-interrupt (22.1/22.2):** type a new prompt while a turn is running; confirm no standalone `[Request interrupted by user]` turn is recorded and the queued prompt becomes the next turn.
   - **413 recovery (22.5):** drive a deliberately oversized context against a provider with a small limit; confirm the turn compacts and retries rather than failing, and `compaction_applied` shows in `--exec` JSON.
   - **Stop hook (22.6):** configure a Stop hook that exits 2 once; confirm the loop runs an extra turn with the blocking message, then completes.
   - **Limits (22.7):** set a tiny `max_budget_usd` and confirm a long turn stops with the budget message and `terminal_reason == .max_budget_usd` in the JSON output.

5. **Wiki checkpoint.** Record in the project wiki the non-obvious findings this phase surfaced: the `reactive_compaction.reduce()` borrow-vs-own hazard (shallow copies borrow from input history), the fire-once guards required for fallback/escalation/reactive-compact to avoid retry spirals, and the decision to keep `final_text` human-readable while adding a machine-readable `terminal_reason` enum rather than a full SDK result envelope.
