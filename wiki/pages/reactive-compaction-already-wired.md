---
title: 413 reactive compaction: already wired, audit over-reported
tags: [gotcha, decision]
created: 2026-05-31
updated: 2026-05-31
sources:
  - src/agent_history.zig:600
  - src/core/reactive_compaction.zig:86
  - src/agent_runtime.zig:2058
---

# 413 reactive compaction: already wired, audit over-reported

## Summary
Phase 22 Task 22.5 (agent-loop-deep-14) claimed `reactive_compaction.reduce()`
"exists and is never called" and that 413 errors "surface immediately and break".
That is wrong as of 2026-05-31. The 413 -> reduce-history -> retry recovery is
wired end-to-end and unit-tested. It was built earlier as "Task 7.5". The ONLY
genuine gap Task 22.5 closed was surfacing the recovery onto `TurnResult.compaction_applied`.

## How the recovery actually works (verified)

- Providers map a 413 / "prompt is too long" rejection to `error.RequestTooLarge`.
  This error is deliberately NON-retriable in `isRetriableProviderError` (retrying
  the identical oversized request would just burn the budget).
- `agent_history.callWithAdapter` (src/agent_history.zig:600+) intercepts
  `error.RequestTooLarge` BEFORE the retriable-error gate: it sizes a keep-window
  via `reactiveKeepWindow(promptTooLongGap(body))` (aggressive 4-turn window on a
  large >=20k token overflow, else 8), calls `reactive_compaction.reduce(alloc,
  history, keep_last_n)`, swaps the reduced history into a request-scoped local
  copy, and `continue`s to retry. It does NOT mutate the caller's durable history;
  the durable history is compacted by the proactive forceCompaction path next turn.
- Spiral guard: `MAX_REACTIVE_RETRIES = 2`. After the cap (or when the history can
  no longer shrink, or is empty) the error surfaces. Tests:
  "413 then success reduces history and the turn succeeds" and "an adapter that
  always 413s surfaces the error after the cap".

## The borrow-vs-own hazard (handled)

`reactive_compaction.reduce()` returns a fresh slice of SHALLOW turn copies: the
caller owns the slice but the turn `content` slices BORROW from the input history
(see the doc comment at reactive_compaction.zig:86). `callWithAdapter` therefore
frees only the slice, tracks `owned_reduced_history` so each new reduction frees
the prior one, and a scope-exit `defer` frees the last. Freeing the turn contents
would dangle them (they live in the caller's history). Keep this invariant.

## The ONE genuine gap (what Task 22.5 added)

The reactive reduction happened invisibly inside `callWithAdapter`; the success
never surfaced `compaction_applied` to the `TurnResult`, so the recovery was not
visible in the exec/CI JSON. Fix mirrors the existing `fallback_out` out-param
pattern: a new `reactive_applied_out: ?*bool` on `callModel`/`callWithAdapter` is
set true on the success-return when `reactive_retries > 0`. `agent_runtime.callModel`
passes `&self.last_call_reactive_compacted` (reset per call) and the turn loop ORs
it into `compaction_applied_any` (src/agent_runtime.zig:2058), the same accumulator
that proactive `built.compaction_applied` feeds.

## Test-harness gotcha (same as the fallback case)

The agent_runtime turn loop builds its provider adapter internally
(`providers.createAdapterWithOverrides`), so you CANNOT inject a scripted 413 mock
at the agent_runtime level. The recovery is tested at the
`agent_history.callWithAdapter` layer (the adapter is a parameter there) with a
`ReactiveTestAdapter`. The new flag is asserted there too; a clean (no-413) success
leaves it false.

## Related
- [[fallback-swap-already-wired]] - the same "audit over-reported, only one small
  gap was real" pattern for the overload fallback swap (Task 22.3).

## Sources
- src/agent_history.zig:600 - callWithAdapter reactive-compaction interception + spiral guard
- src/core/reactive_compaction.zig:86 - reduce() and the borrow-vs-own doc comment
- src/agent_runtime.zig:2058 - the reactive flag folded into compaction_applied_any
