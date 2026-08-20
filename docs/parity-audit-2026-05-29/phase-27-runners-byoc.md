# Phase 27: Self-hosted / environment runner entrypoints (BYOC headless)

## Overview

**What.** This phase covers the reference project's "bring-your-own-compute" (BYOC) headless runner subsystem: the two feature-gated CLI fast-paths `claude environment-runner` (gate `BYOC_ENVIRONMENT_RUNNER`) and `claude self-hosted-runner` (gate `SELF_HOSTED_RUNNER`), and the entire `src/bridge/` machinery they drive. That machinery registers a worker/environment with a cloud `SelfHostedRunnerWorkerService` work-queue API, runs a `register + poll` loop where the poll itself doubles as the environment-liveness heartbeat, leases dispatched work items, spawns one headless `claude --print` SDK child session per work item up to a `max_sessions` capacity, and manages the work ack/stop/deregister/archive lifecycle, JWT token rotation, work-secret decoding, backoff with give-up windows, and a live "X/Y sessions" status display consumed by claude.ai/code.

**Why this is Round 2.** The first audit pass under-covered this subsystem because zcode has superficially adjacent features (a `daemon serve` HTTP listener and a `kairos serve` per-project background agent) that look like "runners" but are structurally unrelated to the BYOC pattern. This phase exists to record, with verified evidence, that the entire subsystem is absent and to make an explicit, documented decision about whether any part of it should be built.

**The locked decision.** The runner subsystem is OUT OF SCOPE for zcode. Every one of the 15 verified gaps depends on an Anthropic-operated cloud backend (the work-queue REST API, the session-ingress proxy, OAuth/Claude.ai login, the GitHub App, GrowthBook flag delivery). zcode has no cloud-agent execution mode and, per prior locked decisions, will not gain one. There is no local server to register against, no work queue to poll, and no session-ingress proxy to keep alive. A "local best-effort stub" of a runner is not buildable in any honest sense: with nothing on the other end of `register` and `poll`, the loop has no semantics. This phase therefore contains **zero in-scope implementation tasks**. Its deliverable is the documented-deviation record plus a precise accounting of which local primitives already exist as building blocks should a local job-runner ever be desired in a future, separately-scoped effort.

**Dependencies on earlier phases (1-16).** None are required, because nothing is being built. For completeness: if a future local runner were ever scoped, it would reuse the headless one-shot execution primitive (`session_mgmt.runOneShot`), the generic backoff helper (`core/backoff.zig`), the worktree tools (`EnterWorktree`/`ExitWorktree`), the duration formatter (`core/format.zig:formatDuration`), the daemon/process-lifecycle patterns (`remote_daemon.zig`, `kairos.zig`), and the OIDC/JWT verification already present (`core/oidc.zig`, `api_server.zig`). All of those are already landed; none is a new dependency.

**Effort.** Build effort for this phase: **zero** (nothing to build). Documentation effort: this plan plus a one-paragraph entry in `docs/PARITY_ROADMAP_V2.md` under "Honest deviations." The survey's per-gap size estimates (S/M/L) are retained below only to convey the magnitude of work that is being deliberately declined, not work that is queued.

## Scope split

| Disposition | Gap ids | Reason |
|---|---|---|
| IN-SCOPE (build) | (none) | Every gap requires the cloud work-queue backend, session-ingress proxy, OAuth/Claude.ai, GitHub App, or GrowthBook delivery - all of which are out of scope by prior locked decision. No gap is buildable as a local-only feature with meaningful semantics. |
| OUT-OF-SCOPE (document) | runners-byoc-01 .. runners-byoc-15 | Cloud-coupled. Documented as honest deviations. See "Documented deviations" for the per-gap rationale and the explicit "no local stub" determination. |

There is intentionally no third "local stub worth doing" column populated with real items. The "Documented deviations" section evaluates a local stub for each gap and records the determination (uniformly: not worth building absent a cloud counterpart, with the one nuance that the underlying execution primitive already exists for gap 05).

## Gaps covered

| id | title | severity | size | our current state |
|---|---|---|---|---|
| runners-byoc-01 | environment-runner / self-hosted-runner CLI entrypoints (BYOC headless mains) | medium | L | MISSING. No `zcode environment-runner` / `self-hosted-runner` commands; `CommandKind` (`src/cli/args.zig:5-108`) has no runner entries; no `BYOC_ENVIRONMENT_RUNNER` / `SELF_HOSTED_RUNNER` gates in `src/core/feature_gates.zig:10-18`. |
| runners-byoc-02 | Register environment/worker with cloud work-queue API | medium | M | MISSING. No `registerBridgeEnvironment` / `registerWorker` analog; no POST to `/v1/environments/bridge` or `{sessionUrl}/worker/register`; daemon binds only `127.0.0.1`. |
| runners-byoc-03 | Poll loop for dispatched work (poll == heartbeat liveness) | medium | L | MISSING. No work-queue polling; no `GET /v1/environments/{id}/work/poll`; no consecutive-empty-poll tracking; no liveness-via-poll TTL. |
| runners-byoc-04 | Per-work-item lease heartbeat with lease-extension | medium | M | MISSING. No `/work/{id}/heartbeat`; no `lease_extended`/`state` parsing. Local `kairos_lock` mtime presence is a different mechanism (no lease, no server). |
| runners-byoc-05 | Spawn one headless `claude --print` SDK session per work item | low | M | PARTIAL primitive only. Headless one-shot exists in-process (`session_mgmt.runOneShot`, reachable via `.run`/`.exec` and `api_server` `run`); no work-item-to-child spawner, no `maxSessions` pool, no NDJSON control loop, no SIGTERM->SIGKILL, no worker_epoch/SDK-url env. |
| runners-byoc-06 | maxSessions capacity gating + capacityWake fast-wake | low | M | MISSING. No `maxSessions`/`atCap`/`capacityWake`. Closest local analog (kairos daily spend cap) is a different abstraction. |
| runners-byoc-07 | Tunable poll-interval config with safety floor (pollConfig) | low | S | PARTIAL (unrelated). kairos has two env-var integer overrides with default fallback; no zod-style schema, no `0-or->=100ms` floor, no capacity-aware variants, no keepalive/reclaim, no remote fetch. |
| runners-byoc-08 | Work ack / stop / deregister / archive lifecycle endpoints | low | M | MISSING. No `/work/{id}/ack`, `/work/{id}/stop`, deregister, or `/v1/sessions/{id}/archive`. Local lifecycle is process-level only (PID/token). |
| runners-byoc-09 | Connection/general backoff with give-up windows on poll failures | low | S | PARTIAL primitive. Generic exponential backoff exists (`core/backoff.zig`, `providers/circuit_breaker.zig`) for provider retries; no dual-band (conn/general) config with give-up windows wired to a poll/register loop. |
| runners-byoc-10 | Work-secret decode + worker_epoch auth + JWT token-refresh scheduler | low | M | MISSING. No `decodeWorkSecret`/`registerWorker`/`worker_epoch`/token-refresh scheduler/`trustedDevice`. Present but unrelated: local daemon bearer auth, inbound OIDC JWT verify, MCP OAuth refresh. |
| runners-byoc-11 | Eligibility preconditions before a remote session | low | M | MISSING. `session.handoff` shares with only file-exists + RBAC checks; no `allow_remote_sessions` policy key, login/remote-env/git-repo/git-remote/GitHub-app gate, or bundle-seed gate. |
| runners-byoc-12 | Idempotent runner resume / session-id reattach | low | S | MISSING. No `reuseEnvironmentId` / backend reattach. Local single-instance PID guard is the nearest analog and already exists. |
| runners-byoc-13 | Multi-session spawn modes (--spawn / --capacity / --create-session-in-dir) with per-session worktrees | low | M | MISSING orchestration; worktree primitive exists. `EnterWorktree`/`ExitWorktree` tools exist; no runner flags, no per-session worktree allocation, no work-item dispatch pool. |
| runners-byoc-14 | Runner status reporting / display (session count, durations) | low | S | PARTIAL primitives. `formatDuration` exists (`core/format.zig:78`); metrics endpoint exists; flat daemon/kairos status strings exist; no session-count/capacity gauge, no periodic refresh, no "X/Y sessions" badge, no connecting->connected state. |
| runners-byoc-15 | Session keepalive + reclaim-stale-work params | low | S | MISSING. No silent `keep_alive` frames, no `reclaim_older_than_ms` poll param, no JWT-expiry recovery. Present but unrelated: per-connection socket timeouts (`SO_RCVTIMEO`/`SO_SNDTIMEO`), WebSocket ping/pong. |

## Implementation tasks

**None.** There are no in-scope gaps in this phase, so there are no implementation tasks. This section is intentionally empty by design, not by omission. The "register + poll" loop, the work-queue REST surface, the session-ingress keepalive, and the multi-session spawner are all defined only in relation to an Anthropic-operated cloud backend that zcode does not and will not talk to. Building any of them locally would produce code with no counterpart to exercise it - a register call with no registry, a poll loop with no dispatcher, a heartbeat with no TTL enforcer - which violates the "no speculative code / minimum code that solves the problem" guideline. The verification step below confirms the build and the absence of accidental runner scaffolding rather than confirming new behavior.

If a future, separately-scoped effort ever wants a **local** job-runner (a different product than BYOC), it should be planned on its own, reusing the primitives enumerated under "Documented deviations -> reusable primitives." That is explicitly out of this phase.

## Documented deviations

All 15 gaps are honest deviations. zcode has no cloud-agent execution mode; this is by design, not oversight. Below, each gap is recorded with what it is, why it is out of scope, and an explicit determination on whether a local stub is worth doing (uniformly: no, with one nuance for gap 05).

**Reference anchors (verified this pass).**
- Entrypoints: `entrypoints/cli.tsx:226` (`BYOC_ENVIRONMENT_RUNNER` fast-path importing `../environment-runner/main.js`) and `entrypoints/cli.tsx:239` (`SELF_HOSTED_RUNNER` fast-path importing `../self-hosted-runner/main.js`; comment "register + poll; poll IS heartbeat"). The runner mains delegate into `src/bridge/`.
- Register: `bridge/bridgeApi.ts:142` `registerBridgeEnvironment` POSTs `/v1/environments/bridge` with `machine_name`, `directory`, `branch`, `git_repo_url`, `max_sessions`, `metadata.worker_type`, and idempotent `environment_id` reuse (`:170-177`). `bridge/workSecret.ts:97` `registerWorker` POSTs `{sessionUrl}/worker/register` and returns `worker_epoch`.
- Poll: `bridge/bridgeApi.ts:199` `pollForWork` GETs `/v1/environments/{id}/work/poll` with optional `reclaim_older_than_ms`, tracks `consecutiveEmptyPolls`.
- Work secret: `bridge/workSecret.ts:6` `decodeWorkSecret` (base64url v1 -> `session_ingress_token` + `api_base_url`), `:42` `buildSdkUrl`.
- Poll config: `bridge/pollConfigDefaults.ts` `DEFAULT_POLL_CONFIG` (not-at-capacity 2000ms, at-capacity 600000ms, `reclaim_older_than_ms` 5000, `session_keepalive_interval_v2_ms` 120000).
- Backoff: `bridge/bridgeMain.ts:59` `BackoffConfig` / `:71` `DEFAULT_BACKOFF` (conn 2s/120s/600s, general 500ms/30s/600s).
- Capacity wake: `bridge/capacityWake.ts` `createCapacityWake` (two-signal merged abort + `wake()`).

**Per-gap determination.**

- **runners-byoc-01 (entrypoints).** Out of scope: the fast-paths are thin wrappers around the cloud runner mains. No local stub: a `zcode environment-runner` command that prints "not supported" adds command surface with zero behavior. Better to have no command at all. Honest deviation: zcode has no cloud-agent execution mode.
- **runners-byoc-02 (register environment/worker).** Out of scope: requires the cloud work-queue DB and OAuth. No local stub: nothing to register into.
- **runners-byoc-03 (poll == heartbeat loop).** Out of scope: the core runner behavior, with no local analog. No local stub: a poll loop against nothing is a no-op.
- **runners-byoc-04 (per-work-item lease heartbeat).** Out of scope: requires the server's 300s lease TTL. No local stub. The local `kairos_lock` mtime presence heartbeat is rename-adjacent but genuinely different (no lease, no server) and is already counted under kairos, not here.
- **runners-byoc-05 (spawn `claude --print` per work item).** Out of scope as a runner feature. Nuance: the execution primitive (`session_mgmt.runOneShot`, plus `std.process.spawn` usage in `kairos.zig`/`remote_daemon.zig`) already exists and would be the building block of any future local job-runner. What is absent is the cloud orchestration around it (work-item-to-child mapping, `maxSessions` pool, NDJSON control loop, SIGTERM->SIGKILL grace, worker_epoch/SDK-url env). No stub now: building the pool without a dispatcher to fill it has no purpose.
- **runners-byoc-06 (maxSessions + capacityWake).** Out of scope: only meaningful with a remote dispatcher feeding work. No local stub.
- **runners-byoc-07 (tunable pollConfig with safety floor).** Out of scope: tied to the cloud work queue and GrowthBook delivery, both excluded. The reject-bad-config-and-fall-back validation discipline is a transferable idea, but there is no poll loop to govern, so porting it here would be premature. (kairos already does simple env-var override with default fallback for its own, unrelated, cadence knobs.)
- **runners-byoc-08 (ack/stop/deregister/archive lifecycle).** Out of scope: cloud work-queue lifecycle endpoints. No local stub.
- **runners-byoc-09 (dual-band backoff with give-up windows).** Out of scope as a runner feature. The backoff primitive exists (`core/backoff.zig`) and is reusable; the runner-specific conn/general dual-band give-up policy is absent and only relevant with a cloud poll/register loop. No stub now.
- **runners-byoc-10 (work-secret decode + worker_epoch + JWT refresh + trustedDevice).** Out of scope: auth/OAuth + cloud ingress, explicitly excluded. The runner's auth model is entirely absent by design. Present-but-unrelated: local daemon bearer auth, inbound OIDC JWT verify, MCP OAuth refresh.
- **runners-byoc-11 (remote-session eligibility preconditions).** Out of scope: every precondition (Claude.ai login, remote env, GitHub App, token-sync) is cloud-coupled. The local in-git-repo check exists in spirit via git tooling, but the gate as a whole is cloud-coupled. No stub: there is no remote session to gate.
- **runners-byoc-12 (idempotent resume / reattach).** Out of scope: cloud environment identity. The local single-instance PID guard (`remote_daemon.zig`, `kairos.zig`) is the nearest analog and already exists.
- **runners-byoc-13 (multi-session spawn modes + per-session worktrees).** Out of scope as runner orchestration. The worktree primitive (`EnterWorktree`/`ExitWorktree`) exists locally and is counted as the `/worktree` parity item, not as a gap here. No stub: per-session worktree allocation needs a session pool, which needs a dispatcher.
- **runners-byoc-14 (runner status display: "X/Y sessions").** Out of scope: the status is consumed by claude.ai/code, a cloud surface. Local primitives exist (`formatDuration`, metrics endpoint, flat status strings) and are adequate for the local daemons zcode actually has. No stub: there is no session pool to count.
- **runners-byoc-15 (session keepalive + reclaim params).** Out of scope: both behaviors exist purely to survive the cloud session-ingress proxy GC and JWT rotation. No local equivalent is meaningful. Present-but-unrelated: socket-level `SO_RCVTIMEO`/`SO_SNDTIMEO` slowloris defense and WebSocket ping/pong.

**Reusable primitives already in zcode (for any future, separately-scoped local job-runner - not built here).**
- Headless one-shot execution: `src/session_mgmt.zig` `runOneShot` (reachable via `.run`/`.exec` in `src/main.zig` and via `api_server` `run`).
- Child-process spawning with env: `std.process.spawn(rt.io, ...)` usage in `src/kairos.zig` and `src/remote_daemon.zig`.
- Generic exponential backoff: `src/core/backoff.zig` (`delayMs`, `shouldRetry`).
- Worktree isolation: `EnterWorktree` / `ExitWorktree` tools (`tool_dispatch.zig`, `tool_schemas.zig`).
- Duration formatting: `src/core/format.zig:78` `formatDuration`.
- Process-lifecycle / single-instance guard: `src/remote_daemon.zig`, `src/kairos.zig`.
- Inbound JWT verification: `src/core/oidc.zig`, `src/api_server.zig`.

## Verification

Because this phase builds nothing, verification confirms (a) the tree still builds and installs cleanly, and (b) no accidental runner scaffolding was introduced.

1. **Build and install** (per CLAUDE.md; bump the patch number in `build.zig.zon` only if any tracked file is actually changed - for a docs-only phase the doc lives outside the source tree, so no version bump is required):
   ```
   /Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build -Doptimize=ReleaseFast
   rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode
   ```
   macOS footgun reminder: `rm -f` the destination first so the fresh inode keeps a valid ad-hoc code signature (in-place overwrite can SIGKILL the next run with "Killed: 9").

2. **Confirm the subsystem is absent (negative checks).** All of the following should return no matches in `/Users/example/Projects/zig-code/src`:
   ```
   grep -rn "environment-runner\|self-hosted-runner\|BYOC_ENVIRONMENT_RUNNER\|SELF_HOSTED_RUNNER" src
   grep -rn "registerWorker\|worker_epoch\|pollForWork\|reuseEnvironmentId\|max_sessions\|capacityWake\|reclaim_older" src
   grep -rn "decodeWorkSecret\|session_ingress_token\|/work/poll\|/work/.*/heartbeat\|environments/bridge" src
   ```

3. **Confirm no runner commands leaked into the CLI surface.** `CommandKind` in `src/cli/args.zig` should still list only the existing 108 subcommands with no runner entries:
   ```
   zcode help
   ```
   should not advertise `environment-runner` or `self-hosted-runner`.

4. **Confirm the documented deviation is recorded.** A short "Honest deviations: no cloud-agent / BYOC runner mode" entry should be present in `docs/PARITY_ROADMAP_V2.md` (or wherever the roadmap tracks honest deviations), citing this phase. Manual check: open the roadmap and confirm the paragraph exists and matches the determination above.

5. **Regression sanity.** `zig build test` should pass unchanged (no new tests are added, since no behavior changed):
   ```
   /Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build test
   ```

There are no positive behavioral checks for this phase because no behavior was added. The success criterion is: the build is green, the runner subsystem remains verifiably absent, and the deviation is documented so a future reader does not mistake the absence for an oversight.
