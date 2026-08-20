# KAIROS — always-on autonomous background agent

KAIROS is zcode's always-on autonomous agent: a long-lived per-project process that
ticks on its own with no user present, runs an "anything worth doing right now?"
self-check, executes work under a safety policy, and reaches the user proactively.

This document is the agreed design (converged via a grill session). Terms are defined
in `/CONTEXT.md`. Decisions with lasting consequences are recorded as ADRs
(`docs/adr/0007`–`0009`).

## What already exists (reused, not rebuilt)

| Piece | Location |
|---|---|
| Cron store (durable + auto-expiry) | `core/cron.zig`, tools at `tools/tool_dispatch.zig:1094+` |
| Cron polling (REPL-only today) | `cli/repl.zig:5257` (`pollCronDue`) |
| Memory (global + workspace) | `core/memory.zig` |
| autoDream (auto post-turn + `/dream`) | `core/dream.zig`, `agent_runtime.zig:1800` |
| Terminal notifications (TTY only) | `core/notifier.zig` |
| HTTP daemon lifecycle (spawn/PID/state) | `remote_daemon.zig` |
| Session persistence + snapshots | `session/store.zig` |
| Approval gate + `ApprovalHandler` | `agent_runtime.zig` |

## Resolved decisions

1. **Target** — full autonomous daemon agent (not just closing reactive gaps).
2. **Process model** — long-lived *warm* process (prompt-cache reuse across ticks; in-memory cron store + lock).
3. **Host** — dedicated `zcode kairos` process, NOT bolted onto `remote_daemon`. Reuses extracted lifecycle helpers (detached spawn, PID/state file, start/stop/status). No network listener. Crash-restart via launchd/systemd `KeepAlive`. → ADR 0007.
4. **Autonomy** — allowlist-driven via a KAIROS-specific `ApprovalHandler`: read-only tools always allowed + a user-extensible allowlist of mutating actions (run tests, `git status/diff`, fmt) execute unsupervised; everything else becomes a **proposal**, not executed. → ADR 0008.
5. **Task source** — hybrid, grounded in intent: (1) due **cron fires**, (2) curated backlog + previous session `open_tasks`, (3) self-survey → **propose only** (never auto-execute invented work).
6. **Cadence** — baseline interval (default ~30 min, configurable); wake at `min(next cron fire, baseline)`. Cheap local **pre-gate** (due cron? backlog non-empty? working tree changed since last tick?) decides whether to spend a model call. Agent may request a sooner next wake mid-task, floored ~60s.
7. **Output** — durable **brief** file always written (surfaced on next REPL start + `zcode kairos status`); time-sensitive items also fire an **OS-native** notification (osascript / terminal-notifier / notify-send), because the existing TTY notifier cannot reach a detached process. Phone push deferred.
8. **Coexistence** — lock-based presence handoff. A **cron-ownership lock** has one owner: an active REPL owns it (KAIROS dormant: memory/dream only); when no REPL is present KAIROS takes it and acts. KAIROS **yields** (pauses mid-task, releases the lock) the instant a REPL appears — this is the re-mapping of the upstream "15-second blocking guard." Presence = a REPL-maintained heartbeat. → ADR 0009.
9. **Scope** — per-project, cwd-scoped. One KAIROS per opted-in repo, with a per-project lock/brief/backlog. Cron tasks gain a project association (new `cwd` field on `CronEntry`) so a global-store task fires only in its own project.
10. **Guardrails** — daily cap (max model-ticks / token / cost → quiet until reset) + per-tick bound (max tool iterations + max turn wall-clock). Conservative defaults, tunable.
11. **Proposal review** — proposals stored as intent prompts (not stale diffs). REPL surfaces them on start; `/kairos` lists them; `/kairos approve <id>` re-runs the prompt live, re-deriving against current state through the normal interactive approval gate.

**Default OFF.** KAIROS only runs when explicitly started (`zcode kairos start`); runtime opt-in, no build flag needed.

## Phase plan (all phases implemented)

- **Phase 1 — Safe always-on cron** (DONE): `zcode kairos start/stop/status`, warm loop, cron-ownership lock, REPL presence heartbeat, per-project cron tagging. `core/kairos_lock.zig`, `src/kairos.zig`.
- **Phase 2 — Autonomy + safety** (DONE): allowlist `ApprovalHandler` (`core/kairos_policy.zig` + `kairos.zig` handler), daily-cap + per-tick guardrails (per-project `usage.json`), brief + proposals (`core/kairos_brief.zig`), `zcode kairos status` shows proposal count.
- **Phase 3 — Self-check + proposals UX** (DONE): idle "anything worth doing?" self-check with a cheap git-dirty/backlog pre-gate, `/kairos` (list / `approve <id>` / `dismiss <id>` / `clear`), REPL-start welcome row surfacing pending proposals.
- **Phase 4 — Reach + polish** (DONE): OS-native notifications (`core/os_notify.zig`); autoDream on idle comes free because KAIROS turns run through `handlePromptDetailed`, which already triggers `maybeRunDream`; config via env (below).

## Configuration (env)

KAIROS is off by default; it runs only when started with `zcode kairos start`. Tunables:

- `ZCODE_KAIROS_DAILY_CAP` — max model-ticks/day before KAIROS goes quiet until local-day rollover (default 50; `0` = no model work).
- `ZCODE_KAIROS_INTERVAL_SECS` — baseline self-check cadence in seconds (default 1800; `0` disables the self-check, leaving only cron firing).
- `ZCODE_KAIROS_ALLOWLIST` — comma-separated extra allowlist entries appended to the conservative built-in default (e.g. `"npm test,cargo check"`).

Per-project state lives under `~/.zcode/kairos/<project-key>/`: `kairos.state`, `cron.lock`, `presence`, `usage.json`, `brief.md`, `proposals.json`, and an optional user-curated `backlog.md` (its presence is one of the self-check pre-gate signals).

## Scheduling work: `/loop` and CronCreate

- `/loop [interval] <prompt>` (REPL) mirrors Claude Code's loop skill: it parses a
  leading interval token (`5m`, `2h`) or a trailing `every <token>` clause (default
  `10m`), converts it to cron via the same table, schedules a **durable, recurring,
  project-tagged** job, and **fires the prompt once immediately**. Durable so the
  background KAIROS process picks it up too (Claude Code's loop is session-only;
  this is a deliberate divergence so the loop actually feeds KAIROS).
- The `CronCreate`/`CronDelete`/`CronList` tools remain (model-invoked). Jobs are
  now tagged with the creating project's cwd and capped at 50 (Claude Code parity).

## Claude Code parity

Aligned with the observable Claude Code behavior, not a byte-exact reimplementation:

- Matched: `/loop` semantics (parse + interval->cron table + immediate fire),
  per-project cron, 50-job cap, 7-day recurring auto-expiry, recurring/one-shot +
  durable jobs, autoDream gated at 24h + 5 sessions, allowlist autonomy, the
  presence-yield re-mapping of the "15-second blocking guard".
- Not identical: no cron jitter (thundering-herd spread is invisible for a single
  local user); no startup "missed one-shot" confirmation prompt; the daemon uses a
  dedicated process + file lock rather than Claude Code's websocket sessions +
  per-project lock; `/loop` only parses the compact `every 20m` form, not
  `every 5 minutes`; the brief is a durable file rather than a model-callable Brief
  tool.

## Implementation notes

- The approval gate auto-allows read-only tools before invoking any handler, so the KAIROS handler only ever sees mutating tools: allowlisted -> approve, else -> deny and queue one proposal for the turn. The handler receives only the rendered approval message (`"<name> [<risk>]: <summary>"`), so allowlist matching parses the tool name and the summary text (the latter carries shell command strings like `git diff`). A structured approval hook would be cleaner but is a larger refactor.
- Proposals are stored as intent prompts; `/kairos approve <id>` re-runs the prompt live through the normal interactive gate rather than replaying a stale diff.

## Planned file map

New files:
- `core/kairos.zig` — warm tick loop, state, pre-gate, self-pace, guardrail counters (integration core, built sequentially).
- `core/kairos_lock.zig` — cron-ownership lock + presence heartbeat.
- `core/kairos_brief.zig` — brief read/write/format + proposal records.
- `core/os_notify.zig` — OS-native notifications (osascript / terminal-notifier / notify-send).

Shared-file edits (serialized, single owner each):
- `core/cron.zig` — add `cwd` field + per-project filtering.
- `remote_daemon.zig` — extract reusable lifecycle helpers.
- `main.zig` — `kairos` subcommand dispatch.
- `cli/repl.zig` — presence heartbeat + cron-ownership yielding.
- `repl_commands.zig` — `/kairos` command + brief surfacing.
- `agent_runtime.zig` — wire KAIROS `ApprovalHandler`, idle dream.
