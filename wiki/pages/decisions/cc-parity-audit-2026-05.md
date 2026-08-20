---
title: Claude Code parity audit (2026-05-29) - full gap inventory + 30-phase plan
tags: [decision, parity, audit]
created: 2026-05-29
updated: 2026-05-29
sources:
  - docs/parity-audit-2026-05-29/00-INDEX.md
  - docs/parity-audit-2026-05-29/gaps.json
  - docs/parity-audit-2026-05-29/01-EXECUTIVE-SUMMARY.md
---

# Claude Code parity audit (2026-05-29)

## Summary

A two-pass multi-agent workflow compared `zcode` against the reference Claude Code
TypeScript source (`~/Downloads/claude-code-main`, ~1900 files) subsystem by subsystem.
Output lives in `docs/parity-audit-2026-05-29/`: an index, an executive summary,
`gaps.json` (machine-readable), and 30 phase plan docs (~17.7k lines). Method was
survey -> adversarial verify (refute each candidate against our code) -> dependency-ordered
phase plan.

## Key points

- **35 subsystems audited, 453 confirmed gaps** (350 in-scope, 103 documented deviations),
  only 10 candidates refuted as already-existing, 30 phase docs. In-scope severity: 36 high,
  133 medium, 224 low.
- **The low refutation rate (10/463) is not the headline.** It means the *named* dimensions
  were audited accurately. The real risk this time was dimension SELECTION, not false
  positives - see below.
- **A completeness critic at the end of round 1 caught the blind spots.** Round 1 (21 dims)
  scored several large reference subsystems at zero gaps *by construction* because they were
  never made into audit dimensions. The critic flagged them; round 2 (14 dims) audited exactly
  those.
- **Biggest single finding: the SDK / headless control protocol had ZERO coverage.**
  `--print`, `--output-format stream-json`, and the bidirectional `control_request` /
  `can_use_tool` permission relay (the surface editor and SDK hosts drive) match nothing in
  our source. This is Phase 21 and is the highest-leverage missing capability.
- **Other round-2 catches:** agent-loop internals (tool concurrency, mid-turn queued input,
  interrupt-recovery, mid-stream model swap), a per-command presence sweep across ~100 commands,
  UI dialogs, plugins lifecycle (enable/disable + MCP/agents from plugins), settings depth, LSP
  diagnostics injection, skills depth, IDE integration, daemon/detached sessions.
- **Honest out-of-scope:** Phases 27-30 (self-hosted runners, REPLTool, voice/STT, buddy
  companion) are entirely out of scope per locked decisions and exist only to record that with
  evidence, plus auth / chrome / telemetry / cloud-bridge deviations folded into other phases.

## The over-report lesson held - and got sharper

[[cc-parity-deep-modules]] warned the prior inventory over-reported gaps on 6+ subsystems.
The adversarial verify pass (an independent skeptic per gap, told to refute) kept that in check:
only 10 false positives this time. The sharper lesson: a single-pass survey is blind to
subsystems it never names. Always run a completeness critic that re-reads the reference for
under-covered or unnamed areas, then do a second pass on what it finds.

## Recommended sequence

Dependency order from `00-INDEX.md`: P1 (settings.json layering + tool-name normalization)
unblocks almost everything; P2 (permission rule engine) unblocks hook matchers and plan mode;
P5-P8 are the execution core; P9-P16 capabilities and interface. Round-2 in-scope phases
(P17-P26) each declare which of P1-P16 they ride on. P21 (SDK/headless) and P22 (agent-loop
internals) are the highest-leverage round-2 work.

## Implementation complete (2026-05-31)

All 26 in-scope phases (P1-P26) were implemented and committed on `cc-parity-534`, one
commit per phase (29 commits incl. the P5/P6/P21 follow-up wirings). Test suite went from a
1801 baseline to **3875 passing, 0 failing**; src grew 226 -> 364 `.zig` files; version
0.11.73 -> 0.12.1. Each phase was built by a sequential per-task workflow (one agent per
task, build-green incrementally) then gated by an independent `zig build` + `zig build test`
run before commit. P27-P30 (self-hosted runners, REPLTool, voice/STT, buddy companion)
stayed documented out-of-scope per the locked decisions.

**The recurring failure mode worth remembering:** on P5 (hooks), P6 (MCP), and P21
(SDK/headless), the per-task agents built and unit-tested the engine/modules but each kept
its edits surgical and deferred the cross-cutting wiring into the central turn loop / dispatch
("that's another task's job"). No single task owned the integration, so it fell through. Each
needed a dedicated follow-up agent to connect the engine to the live runtime (fire hooks from
the turn loop; drive MCP connections from scoped config; route `--print` through the SDK
serializers + `can_use_tool` relay). Lesson: when a phase's value depends on a central-loop
call site, schedule the integration as an explicit owned step, and always re-verify the live
path (not just module tests) before calling the phase done. See
[[engine-built-not-wired-in-multi-agent-builds]] (global wiki).

Smaller deferrals are tracked in `docs/parity-audit-2026-05-29/IMPLEMENTATION-PROGRESS.md`
(AskUserQuestion multiSelect overlay; structured tool_name in the SDK can_use_tool relay;
mid-overlay re-decide of the pending tool). All are secondary refinements, not missing features.

## Related
- [[cc-parity-deep-modules]] - PRD #534 phases and the original over-report lesson this audit extends
- [[anthropic-prompt-caching]] - prompt-parity work already shipped (not re-litigated here)
- [[test-discovery]] - every new core module must be registered in src/main.zig or its tests are skipped

## Sources
- docs/parity-audit-2026-05-29/ - the full audit (index, summary, gaps.json, 30 phase docs)
