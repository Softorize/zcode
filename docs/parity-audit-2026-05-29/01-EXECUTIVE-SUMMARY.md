# Claude Code Parity Audit - Executive Summary

Date: 2026-05-29  |  Reference: `~/Downloads/claude-code-main` (Claude Code TS source)  |  Subject: `zcode` (Zig 0.16)

## What this is

A detailed feature-parity comparison between the reference Claude Code implementation and this Zig reimplementation, plus a build-ready implementation plan for closing the gap. It was produced by two multi-agent workflow passes:

- For each subsystem, a survey agent enumerated the reference's capabilities and searched our Zig code for each.
- Every candidate gap was then handed to an independent adversarial verifier whose job was to *refute* it - to prove we already have the capability under another name. This directly targets the documented failure mode of the previous gap inventory, which over-reported missing features on 6+ subsystems.
- Confirmed gaps were deduplicated, dependency-ordered, and written up as phase plans with target files, approach, acceptance criteria, and test strategy.

## Headline numbers

- Subsystems audited: 35 (21 in round 1, 14 in round 2)
- Candidate gaps surveyed: 463
- Confirmed gaps: 453 (350 in-scope to build, 103 documented deviations / out of scope)
- Refuted as already-existing: 10 (the verifier caught these before they reached the plan)
- In-scope severity: 36 high, 127 medium, 187 low
- Phase plan documents: 30 (P1-P16 round 1, P17-P30 round 2)

## The verification result, and why round 2 happened

Only 10 of ~463 candidates were refuted. That low false-positive rate means the *named* dimensions were audited accurately. But a completeness critic at the end of round 1 found the real risk was not false positives - it was **coverage**: several large reference subsystems were never made into audit dimensions and so scored zero gaps by construction. Round 2 was launched to close exactly those blind spots. The most important was the SDK / headless control protocol, which had literally zero matching code in our source.

## Biggest-ticket findings (high severity, in-scope)

| Phase | Subsystem | Gap |
|---|---|---|
| P1 | Permissions and sandbox | Permission rules read from .claude/settings.json permissions.{allow,deny,ask} arrays + ... |
| P10 | Memory and instructions | Automatic turn-end memory extraction (forked agent) |
| P11 | Sessions and state | Rewind picker does not restore code (only conversation); no file-history snapshots |
| P12 | Swarm, tasks, teams, sub-agents | SendMessage named-teammate inbox delivery + broadcast + auto message delivery |
| P13 | Slash commands | Custom file-based commands are not directly invocable as /<name> |
| P13 | Output styles, tips, onboarding | keep-coding-instructions output-style semantics (suppress base coding section) |
| P17 | Plugins and marketplace lifecycle | Per-plugin enable/disable persisted in settings (enabledPlugins map, scopes) |
| P18 | Settings and config depth | settings 'env' block (inject env vars into sessions/subprocesses) |
| P19 | LSP integration and diagnostics injection | Passive diagnostics injection into agent context |
| P19 | LSP integration and diagnostics injection | Persistent LSP server manager singleton with lifecycle |
| P19 | LSP integration and diagnostics injection | Diagnostic registry: dedup, volume caps, cross-turn tracking |
| P2 | Permissions and sandbox | Rule precedence: deny-always-wins vs latest-matching-rule-wins |
| P2 | Permissions and sandbox | Path-safety guard for dangerous dirs/files (.git, .claude, .ssh, .bashrc, .gitconfig, e... |
| P20 | Skills subsystem depth | disable-model-invocation not enforced at the Skill run path (only hidden from listing) |
| P20 | Skills subsystem depth | No Skill-tool permission gating (deny/allow rules, prefix match, safe-properties auto-a... |
| P21 | SDK / headless control protocol and non-interactive output | No --output-format json|stream-json (only a custom exec --json object) |
| P21 | SDK / headless control protocol and non-interactive output | No --input-format stream-json (no streaming stdin user-message protocol) |
| P21 | SDK / headless control protocol and non-interactive output | No bidirectional control_request/control_response/control_cancel_request envelope protocol |
| P21 | SDK / headless control protocol and non-interactive output | No can_use_tool permission relay over the control protocol |
| P21 | SDK / headless control protocol and non-interactive output | No control_request subtypes for live session control (interrupt, set_permission_mode, s... |
| P22 | Agent loop internals (query.ts/QueryEngine.ts depth) | Synthetic tool_result on abort for in-progress/queued tools |
| P22 | Agent loop internals (query.ts/QueryEngine.ts depth) | Mid-stream model-switch fallback with history-stripping before retry |
| P23 | Per-command presence sweep across all reference commands | /insights is in the removed list, so it returns "unknown command" (its inline handler i... |
| P25 | IDE integration | IDE lockfile discovery (~/.claude/ide/*.lock) + stale cleanup |
| P25 | IDE integration | Outbound MCP client connect to IDE extension (ws / sse + authToken) |
| P25 | IDE integration | Diff-in-IDE (openDiff RPC + SAVED/CLOSED/REJECTED handling) |
| P26 | Daemon supervisor and detached background sessions | Detached background session surface (claude ps|logs|attach|kill, --bg/--background) |
| P26 | Daemon supervisor and detached background sessions | Cross-session live-process registry (~/.claude/sessions/<pid>.json) |
| P5 | Lifecycle hooks | Only 3 hook events fire at runtime (tool events); the other ~25 events parse but never ... |
| P5 | Lifecycle hooks | prompt / http / agent hook types are parsed but never executed |
| P5 | Lifecycle hooks | Stdout JSON contract: most output fields parsed but not acted upon (only deny/block + r... |
| P6 | MCP (Model Context Protocol) | Scoped MCP config (.mcp.json project/local/user/enterprise) vs flat name->transport reg... |
| P6 | MCP (Model Context Protocol) | Structured stdio server config (command/args/env map) + parent-env inheritance |
| P6 | MCP (Model Context Protocol) | MCP tool-result content transformation: image resize/downsample, binary blob spill-to-d... |
| P7 | Compaction and context management | Reactive compaction not wired to over-limit (413 / prompt-too-long) errors |
| P8 | Compaction and context management | LLM-based conversation summarization not used by the auto/manual compaction path |

Structural themes behind these:

- **Configuration substrate.** The reference is built on layered `settings.json` (managed/policy/user/project/local) feeding permissions, hooks, model allowlists, and env. zcode uses a TOML stack and a flat permission file. Phase 1 establishes the JSON layer so every downstream feature lines up.
- **Permission rule engine.** Our allow/deny/ask engine exists, but deny-wins precedence, settings-sourced rules, plan/accept-edits/bypass modes, and the matcher shared with hooks are the large refactor in Phases 2-3.
- **Hooks.** The reference fires ~27 lifecycle events over a JSON stdin/stdout contract with matcher syntax; we have 3-5 events over env vars. Phase 5.
- **SDK / headless control protocol.** `--print`, `--output-format stream-json`, and the bidirectional `control_request`/`can_use_tool` permission relay that editor and SDK hosts depend on. Zero coverage today. Phase 21.
- **Agent-loop internals.** Tool concurrency, mid-turn queued input, interrupt-recovery with synthetic tool_results, and mid-stream model swap with history stripping. Phase 22 (plus fallback-on-overload in Phase 7).

## Scope (locked decisions, honored)

Out of scope and recorded as documented deviations, not built: authentication / OAuth, voice mic+STT, Claude-in-Chrome / computer-use, first-party telemetry phone-home, cloud-only remote/bridge/teleport/runner backends, the Yoga layout engine, and the buddy/companion sprite system. Phases 27-30 (self-hosted runners, REPLTool, voice, buddy) are entirely out of scope and exist only to record that decision honestly with evidence. Renames (`/kairos`<->autoDream, `/loop`<->Cron, etc.) were treated as equivalences, not gaps.

## Recommended sequence

Follow the dependency order in `00-INDEX.md`: Phase 1 (config substrate) and the tool-name normalization unblock almost everything; Phase 2 (permission engine) unblocks hook matchers and plan mode; Phases 5-8 build the execution core; Phases 9-16 add capabilities and interface. The round-2 in-scope phases (17-26) each declare which of phases 1-16 they ride on. The SDK/headless phase (21) and agent-loop-internals phase (22) are the highest-leverage round-2 items.

## How to use this

Each phase doc is an implementation contract: per-task goal, reference file:line, target Zig files, approach, acceptance criteria (test-first), and 0.16 footguns. Treat each gap's premise as a lead to re-verify at implementation time (the survey still over-reports at the margins); the docs already flag where a gap looked partially covered. `gaps.json` holds the raw evidence for scripting or triage.
