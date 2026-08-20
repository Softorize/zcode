# Fallback model swap: already wired, audit over-reported

Phase 22 Task 22.3 (agent-loop-deep-03) claimed `core/fallback_model.zig`
(`pick`/`triggerFromStatus`) was dead code "with no caller". That is wrong as of
2026-05-31. The swap is wired end-to-end and unit-tested.

## How the swap actually works (verified)

- `agent_history.callWithAdapter` (src/agent_history.zig:600+) runs the per-round
  retry loop. It counts a run of consecutive overloads (`error.ServerOverloaded`,
  which 529/503 map to). When `consecutive_529 >= backoff.MAX_CONSECUTIVE_529`
  (=3) it calls `fallback_model.triggerFromStatus(529)` + `fallback_model.pick(...)`
  and, if a distinct `cfg.fallback_model` is configured, writes the fallback name
  to `fallback_out` and returns `error.FallbackTriggered`.
- `agent_runtime.callModel` (src/agent_runtime.zig:~4775) catches
  `error.FallbackTriggered`, announces the swap, calls `applyModelOverride(fb)`
  (which dupes the fallback name into the runtime-owned `self.active_model` with a
  staged-dupe / errdefer discipline so an OOM never dangles), and retries the same
  request exactly once. A second failure surfaces normally (fire-once guard; no
  retry spiral).
- Comprehensive `FallbackTestAdapter`-driven tests already exist in
  agent_history.zig: 3-consecutive-overloads-triggers-swap, no-fallback-surfaces,
  single-overload-no-swap, interleaved-error-resets-counter, fallback==active-no-swap.

## The ONE genuine gap (what Task 22.3 added)

The reference (`query.ts:893-951`) appends a "Switched to ... due to high demand"
**system message** to the conversation so the transcript and the model see the
mid-turn model change. zcode only emitted a transient reporter `.update()` notice
that never reached history. Fix: `fallback_model.announceSwap(alloc, original, fb)`
(pure, testable) formats `"Switched to {fallback} due to high demand for {original}"`,
and `agent_runtime.callModel` now appends it as a `.system` history turn (capturing
`self.active_model` BEFORE `applyModelOverride` mutates it).

## Divergences from the reference (intentional)

- zcode swaps after 3 *consecutive* overloads, not on the first overload, because
  zcode supports many providers and has no Opus-specific gate. Documented as PRD
  #534 Phase 7.4 in the agent_history.zig comments.
- The streaming-only parts of the reference handler (tombstone partials, strip
  thinking signatures, discard a streaming executor) are no-ops in zcode: it uses
  whole-response (non-streaming) calls.

## Test-harness gotcha

The agent_runtime turn loop builds its provider adapter internally
(`providers.createAdapterWithOverrides`), so you CANNOT inject an overloaded mock
adapter at the agent_runtime level. The overload-gate behavior is tested at the
`agent_history.callWithAdapter` layer (adapter is a parameter there). The new
persisted-`.system`-turn behavior is tested at the runtime level by running the
same `announceSwap` + `.system` append the swap path runs (via SkillGuardHarness).

## Related
- [[reactive-compaction-already-wired]] - the same "audit over-reported, only one
  small gap was real" pattern for the 413 reactive-compaction recovery (Task 22.5).
