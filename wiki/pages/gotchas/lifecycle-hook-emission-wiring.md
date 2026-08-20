---
title: Lifecycle hook emission wiring (engine vs call sites)
tags: [gotcha, architecture]
created: 2026-05-29
updated: 2026-05-29
sources:
  - src/core/hooks.zig:291 (runEvent)
  - src/agent_runtime.zig:3474 (fireLifecycleHook + helpers)
  - src/core/hooks_runtime_wire_test.zig (runtime wiring tests)
---

# Lifecycle hook emission wiring (engine vs call sites)

## Summary
The hook subsystem has two clearly separate layers, and they were built in two
separate efforts. The ENGINE (`core/hooks.zig runEvent` + the full stdout JSON
contract, matchers, timeouts, async registry, snapshot/policy gating) was
completed and unit-tested first. The EMISSION call sites -- the code in the live
agent turn loop / session that actually CALLS `runEvent` for the non-tool
lifecycle events -- were a separate, later wiring step. For a while the engine
was fully working and tested yet NO lifecycle hook ever fired in the running app
because nothing called it. If a hooks task looks "already done", check which
layer: a green `hooks_lifecycle_test.zig` proves the engine, not the wiring.

## Key points
- Tool events (`PreToolUse`/`PostToolUse`/`PostToolUseFailure`) were always wired
  -- they fire from `agent_tools.zig` (`runApprovedToolTrace`). The non-tool
  lifecycle events (SessionStart, UserPromptSubmit, Stop, SessionEnd,
  PreCompact/PostCompact, SubagentStart/Stop) fire from `agent_runtime.zig`.
- The runtime call sites are thin: build a `hooks_mod.HookContext`, call
  `runEvent`, act on the `HookRunResult`. They live in
  `AgentRuntime.fireLifecycleHook` and a few named wrappers; the turn loop is NOT
  refactored, just sprinkled with calls.
- SessionStart fires LAZILY on the first turn (`maybeFireSessionStart`), gated by
  a `session_start_fired` bool. Reason: `AgentRuntime.init` returns a value, not
  a `*Self`, so there is no clean `self` to fire from in init. SessionEnd fires
  in `deinit`.
- UserPromptSubmit fires BEFORE the prompt is appended to history; a block
  (exit 2 / decision:block) short-circuits the turn with an early `TurnResult`
  whose `final_text` is the reason. The prompt is never processed.
- Stop fires after the model loop stops. A block is the FORCE-CONTINUE signal:
  the loop re-enters with the reason injected as a system nudge. Bounded to 1
  continuation (`max_stop_hook_continuations`) so a misbehaving Stop hook cannot
  loop forever. Implemented by wrapping the model `while` in a labeled
  `stop_retry: while (true)` outer loop -- bare `break`/`continue` inside the
  inner loop are unaffected (they still bind to the innermost loop).
- `round_budget` (not `max_rounds`) is the live round cap so a Stop continuation
  gets a small extra allowance; the post-loop max-rounds message compares against
  `round_budget` so a continuation that finishes naturally is not mislabeled.
- Sub-agents (`depth > 0`) do NOT fire SessionStart / UserPromptSubmit / Stop --
  they share the parent's session and receive pre-vetted prompts. SubagentStart/
  Stop fire from the PARENT around `spawnChildAgent`.
- Async (`async`/`asyncRewake`) hooks: `drainAsyncHooks` (calls
  `async_hook_registry.checkResponses`) runs at each turn boundary;
  `finalizeAsyncHooks` (`finalizeAll`) runs at session end in deinit.

## The is_test seam (reusable pattern)
Live hook emission must NOT fire under `is_test` or the 2200+ hermetic unit tests
would suddenly spawn `sh` child processes. But the wiring itself needs an
integration test. The pattern:
- A module-level `pub var hooks_test_override: bool = false` plus
  `fn hooksLiveEnabled() { return !is_test or hooks_test_override; }`.
- Every fire/drain method early-returns when `!hooksLiveEnabled()`.
- The integration test sets `hooks_test_override = true` (with a `defer` reset),
  builds a real minimal `AgentRuntime`, writes a hermetic settings.json under a
  tmp HOME, and drives the runtime's own `fireLifecycleHook` /
  `maybeFireSessionStart`, asserting on `runtime.history.view()` and the returned
  `LifecycleOutcome`. See [[hermetic-home-for-settings-sources]].

## Details
- `tmpDirPath` (test_helpers.zig) uses `realPathFile`, which requires the path to
  ALREADY EXIST. Building dep dirs (logs/sessions/mcp) for a test runtime must use
  `std.fs.path.join(root, ...)` against the tmp realpath instead -- each
  dependency's `init()` calls `paths.ensureDir` on its own dir, so they do not
  need to pre-exist. A `tmpDirPath` on a not-yet-created dir fails `FileNotFound`.
- `LifecycleOutcome.reason` is duped onto the runtime allocator inside
  `fireLifecycleHook` (so it outlives the engine's `HookRunResult` deinit). Every
  call site must free it -- on the block path it is usually freed via the nudge's
  `defer`, on the non-block path via `if (outcome.reason) |r| free(r)`.

## Related
- [[hermetic-home-for-settings-sources]] - the HOME-override + settings.json test pattern this reuses
- [[test-discovery]] - the new test file must be registered in src/main.zig comptime block
- [[native-mode-steering-heuristics]] - the Stop-hook continuation lives alongside the native-mode end-turn logic in the same turn loop

## Sources
- src/core/hooks.zig:291 - `runEvent`, the engine entry the runtime calls
- src/agent_runtime.zig:3474 - `fireLifecycleHook` and the lifecycle helpers
- src/core/hooks_runtime_wire_test.zig - proves the runtime fires hooks
