# Claude Code Parity Audit - Index

Audit date: 2026-05-29. Reference: `~/Downloads/claude-code-main` (the Claude Code TypeScript source). Subject: `zcode` (this Zig 0.16 reimplementation).

Method: each subsystem was surveyed for reference capabilities, every candidate gap was adversarially verified against our actual Zig code (to defeat the known over-reporting problem), and the confirmed gaps were turned into dependency-ordered phase plans. See `01-EXECUTIVE-SUMMARY.md` for findings and `gaps.json` for the machine-readable data.

Totals: 35 subsystems audited, 453 confirmed gaps (350 in-scope, 103 documented deviations), 10 candidates refuted as already-existing, 30 phase plan documents.

## Read order
1. `01-EXECUTIVE-SUMMARY.md` - findings, scope, recommended sequence.
2. The phase docs below, in dependency order (each doc lists its own dependencies).
3. `gaps.json` - every confirmed gap with reference and our-side file:line evidence.

## Phase documents

### Foundations and safety

| Phase | Title | Effort | Depends on | Gaps |
|---|---|---|---|---|
| [P1](phase-01-foundations-settings-json-layering-tool-name.md) | Foundations: settings.json layering, tool-name normalization, model aliases | L | - | 8 |
| [P2](phase-02-permission-rule-engine-deny-wins-precedence-.md) | Permission rule engine: deny-wins precedence, settings rules, glob/regex matcher, MCP wildcard, path-safety | XL | 1 | 12 |
| [P3](phase-03-permission-modes-plan-auto-mode-integration-.md) | Permission modes, plan/auto mode integration, accept-edits bash auto-allow | M | 2 | 3 |

### Execution core

| Phase | Title | Effort | Depends on | Gaps |
|---|---|---|---|---|
| [P4](phase-04-bash-ast-shell-env-snapshot-command-prefix-e.md) | Bash AST, shell env snapshot, command-prefix extraction, per-segment permission eval, output/sandbox params | XL | 2 | 12 |
| [P5](phase-05-lifecycle-hook-dispatch-fire-all-events-stdo.md) | Lifecycle hook dispatch: fire all events, stdout JSON contract, matchers, timeouts, async, policy gating | XL | 1,2 | 17 |
| [P6](phase-06-mcp-depth-scoped-config-structured-stdio-env.md) | MCP depth: scoped config, structured stdio, env expansion, dynamic headers, content transform, timeouts, reconnect | XL | 1,2 | 12 |
| [P7](phase-07-agent-loop-and-provider-robustness-fallback-.md) | Agent loop and provider robustness: fallback swap, retry/backoff, header honoring, error classification, reactive compaction trigger | XL | 1 | 14 |
| [P8](phase-08-compaction-llm-summarization-wiring-buffer-t.md) | Compaction: LLM summarization wiring, buffer thresholds, hooks, partial/pivot compaction, attachments, boundary metadata | XL | 5,7 | 15 |

### Capabilities

| Phase | Title | Effort | Depends on | Gaps |
|---|---|---|---|---|
| [P9](phase-09-model-facing-tools-depth-webfetch-websearch-.md) | Model-facing tools depth: WebFetch/WebSearch, AskUserQuestion, ToolSearch scoring, StructuredOutput, LSP, per-tool schemas | XL | 1,6,7 | 13 |
| [P10](phase-10-memory-and-instructions-auto-extraction-taxo.md) | Memory and instructions: auto-extraction, taxonomy prompt, relevance selection, MEMORY.md index, conditional rules | XL | 5,7 | 9 |
| [P11](phase-11-sessions-and-state-code-restoring-rewind-fuz.md) | Sessions and state: code-restoring rewind, fuzzy resume, session search, metadata, AI titles, export richness | XL | 7,8 | 9 |
| [P12](phase-12-swarm-tasks-teams-sub-agents-task-graph-owne.md) | Swarm, tasks, teams, sub-agents: task graph, ownership, team binding, messaging, agent frontmatter, isolation, direct-connect server | XL | 5,6,7 | 21 |
| [P13](phase-13-slash-commands-and-skills-invocable-custom-c.md) | Slash commands and skills: invocable custom commands, frontmatter, namespacing, autocomplete, MCP-prompt commands, output styles | L | 1,6 | 11 |
| [P14](phase-14-background-services-and-onboarding-autodream.md) | Background services and onboarding: autoDream hardening, prevent-sleep, notifier hooks, suggestion/magic-docs services, tips, release notes | XL | 5,7,10 | 20 |

### Interface

| Phase | Title | Effort | Depends on | Gaps |
|---|---|---|---|---|
| [P15](phase-15-ui-rendering-and-terminal-layer-word-diff-th.md) | UI rendering and terminal layer: word-diff, thinking blocks, compact boundary, spinner, terminal probes, mouse/keys, color | XL | 8 | 20 |
| [P16](phase-16-vim-mode-keybindings-cost-usage-accounting-t.md) | Vim mode, keybindings, cost/usage accounting, telemetry, git/bootstrap utilities | XL | 1,7 | 38 |

### Round 2 - missed / under-covered subsystems (in-scope work)

| Phase | Title | Effort | Depends on | Gaps |
|---|---|---|---|---|
| [P17](phase-17-plugins.md) | Plugins and marketplace lifecycle | - | 1-16 as noted | 11 in-scope / 1 oos |
| [P18](phase-18-settings.md) | Settings and config depth | - | 1-16 as noted | 8 in-scope / 2 oos |
| [P19](phase-19-lsp.md) | LSP integration and diagnostics injection | - | 1-16 as noted | 11 in-scope / 0 oos |
| [P20](phase-20-skills.md) | Skills subsystem depth | - | 1-16 as noted | 14 in-scope / 1 oos |
| [P21](phase-21-sdk-headless.md) | SDK / headless control protocol and non-interactive output | - | 1-16 as noted | 15 in-scope / 0 oos |
| [P22](phase-22-agent-loop-deep.md) | Agent loop internals (query.ts/QueryEngine.ts depth) | - | 1-16 as noted | 13 in-scope / 2 oos |
| [P23](phase-23-commands-sweep.md) | Per-command presence sweep across all reference commands | - | 1-16 as noted | 9 in-scope / 3 oos |
| [P24](phase-24-ui-dialogs.md) | UI dialogs and interactive flows | - | 1-16 as noted | 13 in-scope / 2 oos |
| [P25](phase-25-ide-integration.md) | IDE integration | - | 1-16 as noted | 11 in-scope / 0 oos |
| [P26](phase-26-daemon-background.md) | Daemon supervisor and detached background sessions | - | 1-16 as noted | 11 in-scope / 3 oos |

### Round 2 - documented deviations (out of scope, recorded for honesty)

| Phase | Title | Effort | Depends on | Gaps |
|---|---|---|---|---|
| [P27](phase-27-runners-byoc.md) | Self-hosted / environment runner entrypoints (BYOC headless) | - | 1-16 as noted | 0 in-scope / 15 oos |
| [P28](phase-28-repl-tool.md) | REPLTool (model-facing code REPL / interpreter) | - | 1-16 as noted | 0 in-scope / 12 oos |
| [P29](phase-29-voice-stt.md) | Voice input and streaming STT (out-of-scope, document) | - | 1-16 as noted | 0 in-scope / 12 oos |
| [P30](phase-30-buddy-companion.md) | Buddy / companion sprite system (out-of-scope, document) | - | 1-16 as noted | 0 in-scope / 12 oos |
