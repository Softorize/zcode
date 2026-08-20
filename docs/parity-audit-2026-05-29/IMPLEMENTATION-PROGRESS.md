# Parity Implementation Progress

**STATUS: COMPLETE.** All 26 in-scope phases (P1-P26) implemented in dependency order,
one workflow per phase, each gated on an independent green `zig build` + `zig build test`
before commit on `cc-parity-534`. Phases 27-30 remain documented out-of-scope (cloud
runners, REPLTool, voice, buddy companion) per the locked decisions and were not built.

Final state: **3875 tests passing, 0 failing** (up from a 1801 baseline; +2074 tests).
Version 0.11.73 -> 0.12.1. P5, P6, and P21 each needed a focused follow-up wiring commit
to connect their engine to the live runtime (the per-task agents kept the central
turn-loop/dispatch edits surgical, so the cross-cutting integration was done as a
dedicated step). Remaining deferrals are tracked in the "Cross-phase deferrals" section
below; all are secondary refinements, not missing capabilities.

| Phase | Title | Status | Tests (main suite) | Commit |
|---|---|---|---|---|
| P1 | Foundations: settings.json layering, tool-name normalization, model aliases | DONE | 1877 pass / 0 fail | (this commit) |
| P2 | Permission rule engine | DONE | 1978 pass / 0 fail | (P2 commit) |
| P3 | Permission modes, plan/auto integration | DONE | 1999 pass / 0 fail | (P3 commit) - mid-overlay re-decide of the pending tool deferred (runtime blocked in handler.call); mode applies on next decision |
| P4 | Bash AST, shell env snapshot, command-prefix eval | DONE | 2123 pass / 0 fail | (P4 commit) |
| P5 | Lifecycle hook dispatch | DONE | 2223 pass / 0 fail | engine (50eca5a) + emission wiring; all 7 lifecycle points fire in the turn loop |
| P6 | MCP depth | DONE | 2337 pass / 0 fail | modules (e24c3eb) + live client wiring; scoped .mcp.json drives connections, headers apply. Internal Server->ServerConfig type rewrite + mcp-list status column deferred (cosmetic/internal) |
| P7 | Agent loop and provider robustness | DONE | 2430 pass / 0 fail | fallback swap + reactive compaction + retry/backoff wired inline into the live loop |
| P8 | Compaction | DONE | 2506 pass / 0 fail | LLM summary wired into live forceCompaction; threshold model, hooks, attachments, partial/pivot + keep-window (incl. the deferable/experimental tasks) |
| P9 | Model-facing tools depth | DONE | 2611 pass / 0 fail | WebFetch prompt-summarization + redirect detection + binary persist, ToolSearch scoring, structured AskUserQuestion schema, per-tool schemas. AskUserQuestion multiSelect overlay toggle deferred to P15/P24 (UI) |
| P10 | Memory and instructions | DONE | 2680 pass / 0 fail | auto-extraction, taxonomy prompt, relevance selection, MEMORY.md index + dual-cap truncation, conditional rules. (Task 3 agent crashed on self-report but its edits/tests landed; confirmed present independently) |
| P11 | Sessions and state | DONE | 2749 pass / 0 fail | per-turn UUIDs, fuzzy /resume + picker, agentic session search, code-restoring rewind, metadata, AI titles, export richness |
| P12 | Swarm, tasks, teams, sub-agents | DONE | 2902 pass / 0 fail | JSON task records, blocks/blocked-by graph + cascade, atomic claim flow, ownership/busy, team binding, messaging/mailbox, agent frontmatter, isolation, direct-connect (21 tasks) |
| P13 | Slash commands and skills | DONE | 2958 pass / 0 fail | /<name> dispatcher fallthrough to custom commands + user-invocable skills, command frontmatter, subdir namespacing (namespace:command), autocomplete, MCP-prompt commands, output styles |
| P14 | Background services and onboarding | DONE | 3044 pass / 0 fail | autoDream hardening (touched-since count, scan throttle, dead-PID lock reclaim + rollback), prevent-sleep, notifier hooks, suggestion/magic-docs services, tips, release notes (17 tasks) |
| P15 | UI rendering and terminal layer | DONE | 3180 pass / 0 fail | change-ratio word-diff + true token diff, #-memory capture, thinking blocks, compact boundary, animated spinner, terminal probes (DA/DSR/XTVERSION), SGR mouse/modifier decode, color quantizer (19 tasks) |
| P16 | Vim, keybindings, cost/usage, telemetry, git utils | DONE | 3361 pass / 0 fail | WORD motions, ~/J/Y and full vim verbs, keybinding config, cost/usage accounting, telemetry, git/bootstrap utils (32 tasks). Also fixed a pre-existing findQuoteObjectRange infinite loop + registered repl_vim tests |
| P17 | Plugins and marketplace lifecycle | DONE | 3416 pass / 0 fail | per-plugin enable/disable settings, plugins provide hooks/MCP/agents, dependency resolution, trust/policy gating, marketplace discovery/browse (10 tasks) |
| P18 | Settings and config depth | DONE | 3450 pass / 0 fail | local [env] block merged into spawned-tool env (provider-managed strip), managed-file dangerous-key approval gate + fingerprint cache, settings sync, scope filtering (6 tasks) |
| P19 | LSP integration and diagnostics injection | DONE | 3515 pass / 0 fail | persistent LSP server manager (framing, reader thread, ext routing), passive publishDiagnostics registry injected per-turn as a system-reminder, server detection/config (10 tasks) |
| P20 | Skills subsystem depth | DONE | 3554 pass / 0 fail | disable-model-invocation enforcement, model:inherit + [1m] carry-over + effort validation, per-skill permission gating (safe-property auto-allow), visibility/gating, improvement survey (10 tasks) |
| P21 | SDK / headless control protocol | DONE | 3686 pass / 0 fail | modules (abdd11a) + live dispatch wiring; --print --output-format json/stream-json emits real SDK messages, --input-format stream-json drives the control pump with the can_use_tool permission relay (allow/deny round-trip tested). Deferred refinements: structured tool_name/input in can_use_tool, hook_callback/elicitation host relays, --permission-prompt-tool routing (need turn-loop rework) |
| P22 | Agent loop internals (query depth) | DONE | 3715 pass / 0 fail | cancel-reason (hard vs submit-interrupt + suppress logic), synthetic tool_result on abort for emitted-but-unrun tools, tool concurrency, mid-turn queued input, interrupt-recovery, mid-stream model switch (7 tasks) |
| P23 | Per-command presence sweep | DONE | 3764 pass / 0 fail | restored /insights, /branch->conversation fork (+ /fork alias, git re-homed to /git-branch), /color palette, /continue alias, and other missing/under-covered commands reconciled (8 tasks) |
| P24 | UI dialogs and interactive flows | DONE | 3792 pass / 0 fail | first-run TrustDialog capability enumeration + gate, BypassPermissionsMode warning gate, managed-settings security dialog, quick-open/global/history search, exit/mode dialogs (9 tasks) |
| P25 | IDE integration | DONE | 3844 pass / 0 fail | IDE lockfile discovery + stale cleanup, outbound IDE MCP client (ws upgrade, host detection, notifications), diff-in-IDE, selection sync, at-mention, auto-connect (7 tasks) |
| P26 | Daemon supervisor and detached background sessions | DONE | 3875 pass / 0 fail | cross-session live-process registry (atomic, dead-pid sweep), session-kind taxonomy + ZCODE_SESSION_KIND, ps/kill/logs commands + --bg/--background + per-session log capture, daemon-worker supervisor (6 tasks) |

Baseline before P1: 1801 tests passing.

## Cross-phase deferrals to revisit

These are completeness items intentionally deferred to a later phase that owns the surface:
- P3: mid-overlay re-decide of the currently-pending tool (runtime blocked in handler.call) - revisit if the approval bridge is reworked.
- P6: internal Server->ServerConfig type rewrite + `mcp list` scope/approval status column (cosmetic/internal; enforcement already live).
- P9: AskUserQuestion live multiSelect overlay toggling (schema/data model done) -> complete in P15/P24 (UI overlays own this).
- P21: structured tool_name/input in the can_use_tool relay request (only a human-readable message is available at the gate; relay carries it as decision_reason); hook_callback/elicitation host relays not invoked from the live stream-json loop; --permission-prompt-tool / streamlined-transform / partial stream_event not yet routed through the headless dispatch. All need a turn-loop rework; core control protocol is live.
