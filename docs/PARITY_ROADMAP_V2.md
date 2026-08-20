# zcode Quality Plan

Last updated: 2026-04-26

This is the active product-quality roadmap for zcode. It supersedes
`docs/PARITY_ROADMAP.md`, which is now historical.

The goal is not blind file-for-file parity with the reference project. The
goal is to reach the same level of reliability, product depth, and operator
confidence while preserving zcode's strengths: a small native binary, broad
provider support, low dependency footprint, reproducible releases, and
enterprise-first controls.

## Source-Verified Baseline

Current local comparison:

| Area | zcode | Reference project |
|---|---:|---:|
| Primary source files | 186 Zig files | 1,902 TypeScript/TSX files |
| Source LOC | about 118,109 | about 512,685 |
| Test count markers | about 1,602 Zig `test` blocks | about 2,190 `test/it/describe` markers |
| UI architecture | custom Zig TUI modules | React + Ink component system |
| Release posture | CI, release assets, SBOM, signing, provenance | product package source only in local reference |

Latest local verification in this audit:

- `zig build test` passes.
- `npm run compile` passes for the VS Code extension.
- The active command/tool surface is much larger than older roadmap files
  claimed.
- Several reference commands are disabled stubs or feature-gated. They are
  not automatically quality requirements.

## What zcode Already Has

Source-verified implemented surfaces:

- Multi-provider adapters: Anthropic, OpenAI, OpenAI-compatible, Gemini,
  DeepSeek, Groq, OpenRouter, Azure OpenAI, local/Ollama, and mock.
- Core agent tools: Bash/shell, Read, Write, Edit, MultiEdit, Glob, Grep,
  WebFetch, WebSearch, NotebookEdit, TodoWrite/TodoRead, AskUserQuestion,
  Skill, Command, AgentRun, task tools, team tools, GitDiff/GitLog/GitCommit,
  OpenPR, HttpRequest, JsonQuery, file operations, ToolSearch, Brief, LSP,
  Sleep, worktree tools, and Cron tools.
- MCP: stdio, streamable HTTP, WebSocket, tools, resources, templates,
  prompts, completion, subscriptions, notifications, log level, roots,
  sampling, elicitation, and OAuth/PKCE flows.
- Slash commands: core session, model, styles, skills, agents, hooks,
  plugins, marketplace, trust, review, MCP, policy, cost, usage, doctor,
  feedback, onboarding, rename, add-dir, tag, stats, insights, summary,
  break-cache, login/logout wrappers, IDE/terminal diagnostics, heapdump,
  context visualization, advisor, chrome status, security-review, autofix-pr,
  branch, PR, issue, permissions, export, share, worktree, and more.
- UX: fullscreen transcript, markdown rendering, model picker, output-style
  picker, theme picker, prompt history, global search, quick open, transcript
  viewer, todo overlay, paste/image attachments, Vim-mode foundation,
  custom keybinding support, and triple-Ctrl+C exit protection.
- Engineering baseline: Zig tests, integration tests, CI, gitleaks, SAST,
  dependency pin checks, reproducible build check, release signing, SBOM,
  provenance, VS Code extension packaging, GitHub App helpers, and release
  installers.

## Quality Gaps That Still Matter

These gaps are prioritized by user-visible reliability and product quality,
not by reference file count.

### 1. Permission And Safety Depth

Current state:

- zcode has risk tiers, approval modes, sandbox profiles, hook trust,
  marketplace policy, secret scanning, SSRF checks, and resource limits.
- Shell and path safety are solid for a native CLI baseline.

Remaining gap:

- Persistent allow/deny/ask permission rules with source tracking.
- Rich permission UI and CLI management.
- Stronger shell command classification and explainability.
- PowerShell-specific permission model on Windows.
- Sandbox status returned in tool results.
- Kernel-level isolation roadmap completion: Linux seccomp/Landlock, tighter
  macOS sandbox profile, Windows AppContainer/Job Object.

Acceptance criteria:

- A permission rule store can answer why a tool was allowed or denied,
  including rule source and scope.
- `/permissions` can list, add, remove, and explain effective rules.
- Shell results include `sandboxStatus`, `returnCodeInterpretation`, and
  `noOutputExpected` metadata.
- CI covers destructive-command classification, rule precedence, and
  cross-platform fallback behavior.

### 2. Product UX And Diagnostics

Current state:

- The TUI is capable and broad, but many flows are text-command oriented.

Remaining gap:

- More structured dialogs for permissions, settings, sessions, onboarding,
  rate limits, and diagnostics.
- Session browser/search parity with product-grade resume flows.
- Better user-facing rate-limit and overloaded-provider messages.
- Stronger first-run guidance for provider keys, local models, trust, MCP,
  and editor setup.

Acceptance criteria:

- `/doctor` produces a ranked, actionable report with pass/warn/fail checks.
- First-run onboarding can configure provider, trust, shell integration, and
  editor integration without reading docs.
- Resume/session browsing supports search, labels, timestamps, model/provider,
  and safe cross-directory warnings.
- Rate-limit and provider-overload paths produce specific next steps, not
  generic provider errors.

### 3. Agent And Background Work Maturity

Current state:

- zcode supports custom agents, builtin agents, task tracking, background
  tasks, and verification-before-done.

Remaining gap:

- Durable background/forked agent lifecycle with resumable handles.
- Better worker log isolation and output summarization.
- Stronger permission bridging between lead agent and workers.
- More explicit team/swarm state in UI.

Acceptance criteria:

- Background agents survive main-session context compaction and can be listed,
  resumed, stopped, and inspected.
- Agent output is summarized before entering parent context unless explicitly
  expanded.
- Workers cannot inherit broader permissions than the parent without a visible
  escalation.

### 4. Enterprise Platform Layer

Current state:

- zcode has local/fleet config, audit logs, optional control-plane audit sync,
  policy bundle sync, and fleet docs.

Remaining gap:

- Remote managed settings with checksums, cache, polling, and fail-open
  semantics.
- User settings sync for approved environments.
- Feature gates and kill switches that are explicit, audited, and
  self-hostable.
- Analytics/event queue with a strict no-code/no-path metadata contract.

Acceptance criteria:

- Managed settings can lock critical keys and report effective source.
- Remote fetch failure never bricks the CLI, but emits diagnosable warnings.
- Feature gates are locally inspectable and can be pinned in fleet config.
- Telemetry remains opt-in, redacted, and policy-controlled.

### 5. IDE, Remote, And Cross-Device Integration

Current state:

- zcode ships a JSON-lines API and a VS Code extension with session picking
  and diff apply.
- The remote daemon supports share/handoff flows.

Remaining gap:

- Richer editor bridge protocol beyond JSONL request/response.
- Persistent IDE connection state and permission callbacks.
- JetBrains and terminal-panel parity.
- Remote/direct-connect session semantics with stronger auth and recovery.

Acceptance criteria:

- Editors can stream session events, apply diffs, surface permission prompts,
  and resume sessions without screen scraping.
- Bridge state is visible in `/ide` and `/doctor`.
- Remote session auth is scoped, expiring, and auditable.

### 6. Tool Runtime Polish

Current state:

- Tool count is broad and many reference-compatible aliases are present.

Remaining gap:

- Large tool-output persistence to disk with short model-visible summaries.
- Dynamic tool descriptions based on mode, permissions, and installed MCP.
- More structured shell result contract.
- Browser automation and terminal capture remain thinner than the reference.
- Windows PowerShell support is not first-class.

Acceptance criteria:

- Outputs above a configured threshold are stored under a session artifact
  directory and referenced by ID/path.
- Tool schemas are generated from runtime permissions and context, not just a
  static table.
- PowerShell has a separate parser, risk model, and tests before Windows is
  advertised as fully interactive.

## Recommended Implementation Plan

### Phase 0: Keep The Roadmap Accurate

Status: complete for the 2026-04-26 audit pass.

Deliverables:

- Replace stale parity claims with this source-verified quality plan.
- Keep historical parity docs clearly marked.
- Add new roadmap entries only with source references or explicit assumptions.

Exit criteria:

- No active roadmap marks implemented commands/tools as missing.
- Future contributors can pick the next work item without repeating the
  reference comparison.

### Phase 1: Permission And Shell Result Contract

Why first:

- This raises the reliability floor for every tool and every future UX.
- It is smaller and more testable than a full UI rewrite.

Work items:

1. Add a persistent permission rule store. Done: `src/core/permission_rules.zig`
   stores allow/deny/ask rules with global/workspace scope, latest-match
   precedence, and source tracking.
2. Extend `/permissions` to list, explain, add, and remove rules. Done:
   `/permissions list`, `/permissions add`, `/permissions remove`, and
   `/permissions explain` are wired to the persistent store.
3. Add structured shell metadata: sandbox status, return-code interpretation,
   no-output flag, and output truncation metadata. Done: shell results include
   a `[shell_result]` JSON contract while keeping legacy markers for UI
   compatibility.
4. Add large-output persistence under session artifacts. Done: outputs above
   `tool_output_artifact_threshold_bytes` are stored under per-session
   artifact directories and replaced in model-visible history with summaries.
5. Expand tests around precedence, destructive shell detection, and sandbox
   status rendering.

### Phase 2: Diagnostics And Onboarding

Why second:

- Once permissions are explainable, users need product-quality ways to see and
  fix configuration problems.

Work items:

1. Upgrade `/doctor` into a ranked diagnostic suite. Done: `/doctor` now
   starts with ranked PASS/WARN/FAIL checks and actionable remediation before
   the detailed probe output.
2. Upgrade onboarding to guide provider, trust, sandbox, editor, and MCP setup.
3. Add rate-limit and overload-specific recovery messages.
4. Add session browser/search polish.

### Phase 3: Managed Settings And Feature Gates

Why third:

- Enterprise rollouts need central policy and controlled experiments after the
  local permission model is trustworthy.

Work items:

1. Add remote managed settings fetch/cache with checksum validation. Done:
   startup can fetch `GET /v1/settings/managed`, verify SHA-256, write the
   managed TOML/cache metadata atomically, and merge it in the current run.
2. Add locked-key semantics and effective-source reporting.
3. Add self-hostable feature gates and kill switches. Done:
   `feature_kill_switches` can force known gates off after config merge, and
   `/features` explains effective local gate state.
4. Add opt-in redacted event queue for operational metrics.

### Phase 4: Agent And Remote Depth

Why fourth:

- Agent swarms and remote sessions are high-value but only safe after the
  permission and managed-settings foundations are in place.

Work items:

1. Add durable background agent handles. Done: background `AgentRun` now
   creates a persistent task id, records status/output through the task store,
   applies requested agent/model settings in the background path, and can be
   inspected with `/tasks`, TaskPoll, or TaskOutput.
2. Add agent output summarization and artifact isolation.
3. Add permission bridging for worker agents.
4. Extend IDE bridge from request/response to event streams and permission
   callbacks. Partially done: the JSONL API now advertises notification
   envelopes, emits `request.completed` events after request handling, and the
   VS Code extension consumes server-side event notifications without
   confusing them with request responses.

## Active Backlog

Use this as the next concrete execution queue:

1. `editor-permission-callbacks`: surface permission prompts through editor
   integrations instead of only terminal/UI paths.
2. `windows-platform-hardening`: DPAPI keychain, PowerShell tool, and Windows
   process sandboxing before claiming full Windows interactive parity.

## Non-Goals

- Do not copy disabled reference stubs just to increase command count.
- Do not add hosted-only dependencies that break offline/self-hosted use.
- Do not weaken zcode's release posture or low-dependency native build.
- Do not advertise Windows interactive parity until shell, keychain, and
  sandbox behavior are actually implemented and tested on Windows.

## Behavioral Deviations

These are places where zcode intentionally behaves differently from the
reference because a different underlying model makes the reference's
mechanism unnecessary, not because a feature is missing.

### Global sessions vs per-project logs (sessions-04)

The reference stores conversation logs in a per-project directory tree and
ships a "cross-project resume" flow (`utils/crossProjectResume.ts`) to bridge
those trees: `checkCrossProjectResume` either resumes a same-repo worktree
directly or prints/clipboards a `cd <path> && claude --resume <id>` hint with a
"this conversation is from a different directory" message, and the picker
exposes an all-projects vs same-repo toggle.

zcode stores every session as a flat `.jsonl` in a single `sessions_dir`
(see `src/session/store.zig` `list`), with no per-project subtree. Resuming any
session from any working directory already works unconditionally, so there is
no per-project log directory to bridge and the reference's entire
cd/clipboard/worktree-toggle mechanism has no analog here. This is a deliberate
simplification, not a missing feature: cross-project resume is a non-gap under
zcode's global session model.

The only thing the global model loses is a visual hint of where a session
originated. To recover that without any blocking/clipboard machinery, zcode
records an optional `origin_cwd` breadcrumb on the session snapshot record
(`appendSnapshot` accepts the working directory; `load` reads it back into
`LoadedSession.origin_cwd`). A picker may append a dim "(from <dir>)" suffix
when a session's `origin_cwd` differs from the current cwd. The breadcrumb is
purely informational - it never blocks a resume, prompts a `cd`, or toggles
between project scopes.
