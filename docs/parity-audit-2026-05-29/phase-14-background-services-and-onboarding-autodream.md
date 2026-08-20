# Phase 14: Background services and onboarding: autoDream hardening, prevent-sleep, notifier hooks, suggestion/magic-docs services, tips, release notes

## Overview

**What.** This phase hardens the background-service surfaces zcode already
ships, and fills the persistent-state foundations several onboarding/tips
features depend on. It splits cleanly into five clusters:

1. **autoDream hardening** (`background-svc-01..06`). zcode already runs a
   forked memory-consolidation subagent on turn completion behind a 24-hour
   time gate and a 5-session count gate. The reference's gate is sharper: count
   only sessions *touched since the last consolidation* (excluding the current
   one), throttle the directory scan to once per 10 minutes, reclaim dead-PID
   locks, roll back the lock mtime on a failed fork (so the time gate fires
   again rather than resetting as if the dream succeeded), gate the whole thing
   behind an enabled setting, stream live progress into a task surface, and
   stamp the marker optimistically on a manual `/dream`.

2. **prevent-sleep ref-count + restart** (`background-svc-07`). Our
   `SleepGuard` uses a bare bool. The reference keeps a `refCount` (so nested
   work sections don't prematurely allow sleep) and a 4-minute restart interval
   (so `caffeinate -t 300` doesn't lapse partway through a long turn), plus a
   cleanup-on-exit hook.

3. **notifier channel config + notification hook** (`background-svc-08/09`).
   We auto-detect the terminal and emit OSC sequences. We lack a user-settable
   preferred channel (with `iterm2_with_bell`, `terminal_bell`,
   `notifications_disabled` variants and the Apple_Terminal bell probe), and we
   never fire the `Notification` hook event before emitting (the event name
   exists in `hook_event.zig` but the firing machinery does not).

4. **suggestion / speculation / magic-docs / agent-summary / tool-summary
   services** (`background-svc-10..14`). These are all entirely absent
   LLM-driven background services. They depend on a forked-agent-with-shared-
   cache infrastructure and (for two of them) a copy-on-write FS overlay that
   zcode does not have. Most are low-priority and several are gated behind
   internal-only (`USER_TYPE === 'ant'`) or SDK-client surfaces that zcode does
   not expose. This phase scopes them carefully: build the small, useful,
   self-contained ones (`background-svc-14` tool-use summary as an opt-in cheap-
   model call) and **defer** the large speculative/overlay ones with an explicit
   rationale, rather than over-building speculative infrastructure.

5. **tips scheduling + onboarding state + release-notes-on-startup**
   (`styles-onboarding-03..08`). The foundational gap is a persisted
   **startup counter** (`numStartups`) and per-project onboarding state, plus a
   small global "seen state" store. Once that exists, tip cooldowns,
   longest-since-shown spinner scheduling, `spinnerTipsEnabled`/override
   settings, and release-notes-on-startup (with a `lastReleaseNotesSeen` version
   diff) all become small additions. The changelog network-fetch gap
   (`styles-onboarding-08`) is a deliberate architectural deviation (zcode bakes
   the changelog in at build time) and is documented as accepted-as-is, not
   built.

**Why.** Three real correctness bugs hide in this surface:
- A crashed zcode that left `.consolidate-lock` blocks auto-dream **forever**
  (no PID-liveness reclaim) - `background-svc-03`.
- On a failed dream fork we currently `releaseLock`, which **touches the
  last-run marker**, resetting the 24h gate as if the dream succeeded. That is
  the exact opposite of the reference's rollback - `background-svc-03`.
- A turn longer than 5 minutes loses sleep prevention partway through because
  `caffeinate -t 300` lapses with no restart - `background-svc-07`.

The rest are UX/feature gaps: no user off-switch for auto-consolidation, no
forced notification channel, no Notification hook, no passive spinner tips, no
"what's new after upgrade" surface, no graduating onboarding nudge.

**Dependencies.**
- **Phase 5** (lifecycle hook dispatch): required for `background-svc-09`. The
  Notification hook can only fire if the dispatch layer that Phase 5 builds can
  accept arbitrary `hook_event.Event` values (Phase 5 retires the 3-variant
  `HookEvent` enum in `hooks.zig` and routes everything through
  `hook_event.Event`). This phase wires a *call site* for `.notification`; it
  does not rebuild the engine.
- **Phase 7** (agent loop / forked-agent robustness): required for the
  background LLM services. autoDream's progress watcher
  (`background-svc-05`), and the deferred suggestion/speculation/agent-summary
  services, all need the `handlePromptDetailed` enriched-result path and a
  forked-agent helper that the Phase 7 work stabilizes.
- **Phase 10** (memory and instructions): required because autoDream consolidates
  the memory dir; the session-touched-since gate and the manual `/dream`
  optimistic stamp both key on the memory-dir layout Phase 10 owns.

**Effort.** XL. The autoDream and tips/onboarding clusters are the bulk of the
buildable work (each ~M with a new persistent-state module). The notifier and
prevent-sleep tasks are M. The large LLM background services are mostly deferred
with a documented rationale, with one small buildable piece (`background-svc-14`).

**Reference source root.** `/Users/example/Downloads/claude-code-main/src`
**Our source root.** `/Users/example/Projects/zig-code/src`

**Verification notes from the survey (confirmed during this plan's research).**
The survey is accurate on the headline gaps but a few details are worth
correcting so the implementation contract is precise:

- `agent_runtime.zig` lives at `src/agent_runtime.zig`, **not** under `src/core/`.
  `maybeRunDream` is at `agent_runtime.zig:2783-2834`; the notifier emit site is
  at `agent_runtime.zig:2029-2048`; `preventSleep`/`allowSleep` are called at
  `agent_runtime.zig:1126` and `agent_runtime.zig:1987`.
- `core/dream.zig:52-78` (`acquireLock`) **already writes the real OS PID** and
  uses an exclusive create. It does **not** read the PID back for liveness; the
  reclaim/rollback machinery is genuinely missing. The dream.zig header comment
  claiming it "fixed two PID bugs" refers only to writing the correct PID and
  using exclusive-create, not to liveness reclaim.
- The exact PID-liveness + steal pattern we need already exists in
  `core/kairos_lock.zig` (`acquireCronLock` at 85-101, `pidAlive` at 261-267,
  `getpid` at 251-256). The dream lock should mirror it rather than re-invent it.
- `core/prevent_sleep.zig` already passes `-w <pid>` *and* `-t 300`. The `-w
  <pid>` tie means a SIGKILL'd parent is handled (no orphan), so the
  cleanup-registry concern is partly already addressed; the real functional gap
  is the missing 4-minute restart and the missing ref-count.
- `core/notifier.zig` already has `iterm2`/`kitty`/`ghostty`/`bell`/`none`
  channels, `pickChannel`, `emit`, and `buildBytes`. The gaps are the missing
  combined/disabled variants, the config field, the Apple_Terminal probe, and
  the config-driven selection at the call site.
- `core/hook_event.zig` already declares `.notification` (line 33), names it
  `"Notification"` (line 65), and `interpretExit` treats it as observability-only
  (not blocking-capable). `hook_config.zig` already parses Notification hooks via
  `hook_event.fromName`. The only missing piece is a *call site* that fires the
  event - and Phase 5 is what makes the dispatch layer able to accept it.
- `core/changelog.zig` already has `parseChangelog` + `formatRecent` and is wired
  to `/release-notes` via `repl_commands.zig:1695` / `renderReleaseNotes` at
  `repl_commands.zig:4763`. `formatRecent` takes the first N entries with **no
  semver filter** (line 163). `update.zig:729` has a `compareVersions` we can
  reuse for the version diff.
- `core/onboarding.zig` is entirely stateless (recomputed every render). There
  is no persisted per-project state and no `numStartups`. The nudge at
  `repl.zig:4964` never graduates.
- `core/tips.zig` is a pure static selector (`registry`, `at`, `pick`, `next`).
  No metadata struct, no cooldown, no history. `/tips` at
  `repl_commands.zig:710-716` seeds with the clock only.
- There is **no** persistent "global state" store keyed like the reference's
  global config (`numStartups`, `tipsHistory`, `lastReleaseNotesSeen`). zcode's
  `config.toml` is user-editable *configuration*, not derived runtime state.
  Mixing derived counters into it is wrong; this phase introduces a small
  separate `state.json` under the zcode home (see Task 14.10).

## Gaps covered

| id | title | severity | size | our current state |
|---|---|---|---|---|
| background-svc-01 | autoDream session gate counts ALL sessions, not touched-since-last-consolidation | medium | M | Partial: time gate present; count is total sessions, current session not excluded |
| background-svc-02 | autoDream missing 10-min scan throttle between time-gate passes | low | S | Missing: no `SESSION_SCAN_INTERVAL_MS`/`lastSessionScanAt` throttle |
| background-svc-03 | autoDream lock has no stale/dead-PID reclaim or rollback-on-failure | medium | M | Partial: writes real PID + exclusive-create; no liveness reclaim; releaseLock-on-failure resets gate (opposite of rollback) |
| background-svc-04 | autoDream not gated by an enabled setting / feature flag | medium | M | Missing: no `auto_dream_enabled`/`auto_memory_enabled`; thresholds hardcoded; no KAIROS/remote disable |
| background-svc-05 | autoDream has no progress watcher / inline completion message | low | M | Missing: static log only; no per-turn watcher, no transcript "Improved N files" message |
| background-svc-06 | Manual /dream does not stamp lastConsolidatedAt optimistically | low | S | Partial: `defer releaseLock` stamps marker after completion; no optimistic pre-stamp |
| background-svc-07 | preventSleep has no ref-count and no 4-min restart interval | medium | M | Partial: bool guard + `-w pid -t 300`; no ref-count, no restart, no cleanup hook |
| background-svc-08 | notifier has no configurable preferred-channel setting | low | M | Partial: auto-detect channels present; no config field, no `*_with_bell`/`*_disabled`, no Apple_Terminal probe |
| background-svc-09 | Notification hook event defined but never fired | medium | M | Partial: event declared+parsed; no firing call site (depends on Phase 5 dispatch) |
| background-svc-10 | No prompt-suggestion service (predict next typed prompt) | low | L | Mostly missing: only static starter suggestions; no LLM idle predictor. **Deferred** (see scope notes) |
| background-svc-11 | No speculation service (pre-execute predicted prompt in FS overlay) | low | L | Missing entirely; depends on svc-10 + CoW overlay. **Deferred** |
| background-svc-12 | No Magic Docs service (auto-maintain `# MAGIC DOC:` files) | low | L | Missing entirely; reference gates behind `USER_TYPE==='ant'`. **Deferred** |
| background-svc-13 | No per-sub-agent background progress summarizer (AgentSummary) | low | L | Missing entirely; targets multi-agent coordinator UI. **Deferred** |
| background-svc-14 | No tool-use summary generator (cheap-model ~30-char label) | low | M | Missing entirely; reference says "used by the SDK". Build a small opt-in version |
| styles-onboarding-03 | Tip cooldown / relevance gating / history (per-session) | medium | M | Partial: static registry + clock pick; no cooldown/relevance/history |
| styles-onboarding-04 | Tips shown on the working spinner (longest-since-shown scheduler) | low | M | Partial: `/tips` on demand + welcome tip; no spinner integration, no scheduler |
| styles-onboarding-05 | Release-notes-on-startup with lastSeen-version tracking | medium | M | Partial: `/release-notes` on demand; no startup surface, no version diff, no lastSeen |
| styles-onboarding-06 | Startup/session counter + onboarding seen-count cap + completion persistence | medium | M | Missing: stateless onboarding; no `numStartups`; no per-project seen-count/completion |
| styles-onboarding-07 | spinnerTipsEnabled / spinnerTipsOverride settings | low | S | Missing: no config fields, no custom-tip merge |
| styles-onboarding-08 | Changelog network fetch + on-disk cache | low | S | Present-different: zcode bakes changelog at build time. **Accepted as-is** |

---

## Implementation tasks

Build order is foundational-first. **Task 14.10 (persistent state store) is the
keystone** for the tips/onboarding/release-notes cluster and should land before
14.11-14.15. The autoDream cluster (14.1-14.6) is independent and can proceed in
parallel. Notifier/prevent-sleep (14.7-14.9) are independent.

---

### 14.1 autoDream: count only sessions touched since last consolidation, excluding current

**Goal.** Make the session gate measure *new work since the last dream* instead
of total session count.

**Reference behavior.** `services/autoDream/autoDream.ts:153-171` calls
`listSessionsTouchedSince(lastAt)` then filters out the current session before
comparing to `minSessions`. `services/autoDream/consolidationLock.ts:118-124`
implements `listSessionsTouchedSince`: candidates with `c.mtime > sinceMs`.

**Target Zig files.**
- Edit `src/core/dream.zig`: change `shouldAutoDream` to take a *filtered*
  touched-since count (or compute it internally), and add a helper that returns
  the count of sessions whose store mtime is newer than the last-run marker
  mtime, excluding the current session id.
- Edit `src/agent_runtime.zig` (`maybeRunDream`, ~2787): compute the touched-since
  count from `self.store` and pass `self.session_id` so the current session is
  excluded.
- Inspect `src/session/store.zig` (`list` at 341-383) to find the per-session
  mtime field; if `SessionEntry` does not already carry an mtime, add it (the
  store already stats files to list them).

**Approach.**
1. In `dream.zig`, add `pub fn touchedSinceCount(entries, last_run_mtime_sec, current_session_id) usize` that iterates `entries` and counts those with `mtime > last_run_mtime_sec and id != current_session_id`. Pure function over the entry slice - no IO, fully testable.
2. Expose the last-run marker mtime: factor a `pub fn lastConsolidatedAtSec(allocator) ?i64` out of the existing stat logic in `shouldAutoDream` (returns null when the marker is absent = "never", which makes every session count as touched-since).
3. Change `shouldAutoDream` to accept the already-computed touched-since count instead of the raw `session_count`, keeping the time gate logic intact.
4. In `maybeRunDream`, read the marker mtime once, compute the touched-since count, and pass it in.

**Acceptance criteria.**
- Write a test in `dream.zig`: given 3 entries with mtimes `[10, 200, 300]`, `last_run = 100`, `current = "S300"` (mtime 300), `touchedSinceCount` returns `1` (only the mtime-200 entry; the mtime-10 entry is too old, the current session is excluded).
- Write a test: a "never consolidated" marker (null) makes every non-current entry count.
- Existing `shouldAutoDream returns false for low session count` test still passes (adapted to the new signature).

**Test strategy.** Pure-function tests in `dream.zig` under `tools/test_runner.zig`. No tmp-dir needed for `touchedSinceCount`. For `lastConsolidatedAtSec` add a tmp-dir test that creates a marker file and checks the returned second value is close to now.

**Risk / footguns.** Session entry mtime must be in a stable unit. Follow the 0.16 pattern already in `dream.zig:33`: `@divTrunc(stat.mtime.toNanoseconds(), std.time.ns_per_s)`. Do not pass `"."`/`"repo"` as cwd anywhere (CLAUDE.md test-helpers rule). If `store.list()` does not currently carry mtime, prefer adding the field over re-statting (avoid the `readPositionalAll` byte-0 loop footgun by not re-reading files).

**Size.** M.

---

### 14.2 autoDream: 10-minute scan throttle between time-gate passes

**Goal.** Stop re-scanning the session store on every turn when the time gate
passes but the session gate does not.

**Reference behavior.** `services/autoDream/autoDream.ts:54-56` defines
`SESSION_SCAN_INTERVAL_MS = 10 * 60 * 1000`; lines 143-151 bail when
`Date.now() - lastSessionScanAt < SESSION_SCAN_INTERVAL_MS`, after the time gate
but before the session scan. `lastSessionScanAt` is closure-scoped.

**Target Zig files.**
- Edit `src/agent_runtime.zig`: add a field on `AgentRuntime` (e.g.
  `last_dream_scan_ns: i128 = 0`) and check it in `maybeRunDream` after the time
  gate, before the session-touched-since scan.

**Approach.**
1. Add the field default-initialized to 0 in the `AgentRuntime` struct literal/`init`.
2. In `maybeRunDream`, after `shouldAutoDream`'s time gate passes (split the time gate out so the throttle sits between time gate and session scan), compute `now_ns = clock.nowNanos()` and bail if `now_ns - self.last_dream_scan_ns < 10 * 60 * std.time.ns_per_s`. Set `self.last_dream_scan_ns = now_ns` before scanning.
3. Because the throttle sits *between* the time gate and the session scan, restructure `maybeRunDream` to: (a) time gate via `dream.shouldTimeGatePass`, (b) scan throttle, (c) session-touched-since gate, (d) lock.

**Acceptance criteria.**
- Because the throttle is instance-state on a long-lived `AgentRuntime`, add a small unit-testable helper `dream.scanThrottlePasses(now_ns, last_scan_ns) bool` and test that it is false within 10 minutes and true after.
- Manual: with a fresh build, two consecutive turns where the time gate is open but the session gate is closed should scan the store only once (verify via `ZCODE_DEBUG_LLM`-style log or a temporary debug log).

**Test strategy.** Pure-function test for `scanThrottlePasses` in `dream.zig`. The instance-field wiring is covered by the autoDream integration smoke test in 14.6.

**Risk / footguns.** Keep the throttle in nanoseconds via `clock.nowNanos()` (CLAUDE.md: use `clock.*`, not `std.time.*`). The reference's perf concern is a transcript-dir scan; ours is a cheaper `store.list()`, so this is a low-severity hardening, not a hot fix - but the gate must sit before the scan to have any effect.

**Size.** S.

---

### 14.3 autoDream: stale/dead-PID lock reclaim + rollback-on-failure

**Goal.** Fix two real bugs: a crashed process must not block auto-dream forever,
and a failed fork must not reset the 24h gate as if the dream succeeded.

**Reference behavior.** `services/autoDream/consolidationLock.ts:46-84`
(`tryAcquireConsolidationLock`): treats the lock as held only if `mtime <
HOLDER_STALE_MS` (60min) AND `isProcessRunning(pid)`; otherwise reclaims it,
re-reads the PID after writing to resolve a two-reclaimer race, and returns the
*prior* mtime for rollback. Lines 91-108 (`rollbackConsolidationLock`): on a
failed fork, rewind mtime to the prior value (or unlink when prior was 0) and
clear the PID body.

**Target Zig files.**
- Edit `src/core/dream.zig`: rewrite `acquireLock` to mirror
  `core/kairos_lock.zig:acquireCronLock` (read body, `pidAlive`, steal-if-dead,
  re-read after write). Add `pidAlive`/`getpid` (or import the kairos helpers if
  they are exported; if not, duplicate the tiny functions - they are already
  duplicated between kairos and dream by design). Have `acquireLock` return the
  prior marker mtime (an `?i64`) instead of a bare `bool`.
- Add `pub fn rollbackConsolidation(allocator, prior_mtime: ?i64) void` that
  rewinds the marker mtime (or deletes it when prior was null/0).
- Edit `src/agent_runtime.zig` (`maybeRunDream`): on fork-create failure and on
  prompt error, call `rollbackConsolidation(prior)` instead of `releaseLock`. On
  success, call `releaseLock` (which stamps the marker = now).

**Approach.**
1. Mirror kairos's pattern exactly: the dream lock body is the holder PID; the lock mtime is `lastConsolidatedAt`. Read both with one `stat` + one `readFileAlloc`. If mtime is within `HOLDER_STALE_MS` AND `pidAlive(holder)`, return "held" (null prior). Otherwise reclaim: ensure dir, write our PID, re-read, and bail if the re-read PID is not ours (lost the race).
2. `acquireLock` returns `?i64` = prior mtime in seconds (0/absent encoded as a sentinel, e.g. return an `AcquireResult { acquired: bool, prior_mtime_sec: i64 }` to avoid null-vs-0 ambiguity).
3. `rollbackConsolidation`: if `prior_mtime_sec == 0`, delete the marker; else write empty body and set the marker mtime back via the 0.16 `utimes` equivalent. **Check the 0.16 API** for setting mtime: `std.Io.File.updateTimes` / `setTimes` - if no direct API exists, emulate by recreating the marker and accepting "now" is wrong only on the rollback path, OR store the prior mtime in the marker body and have the time gate read the body instead of the file mtime. Prefer the latter (body-stored timestamp) since it is portable and does not depend on a utimes syscall: change `lastConsolidatedAtSec` to read the integer from the marker body, and `releaseLock`/`rollbackConsolidation` to write the integer. This sidesteps the mtime-write API question entirely.
4. Update both call sites in `agent_runtime.zig` (the create-failure path ~2815 and the prompt-error path ~2823) to roll back; the success path keeps `releaseLock`.

**Acceptance criteria.**
- Write a tmp-dir test: write a `.consolidate-lock` with a definitely-dead PID (e.g. a PID we just spawned and reaped, or `999999`) and an old mtime/body timestamp; assert `acquireLock` reclaims it (returns acquired=true).
- Write a tmp-dir test: write a lock with our own live PID and a recent timestamp; assert `acquireLock` returns acquired=false.
- Write a tmp-dir test: acquire, then `rollbackConsolidation(prior)`; assert the marker timestamp equals the prior value (not now), so the time gate would fire again. Acquire with prior=0, rollback, assert the marker is gone.
- Write a test: acquire then `releaseLock`; assert the marker timestamp is ~now.

**Test strategy.** Tmp-dir tests in `dream.zig` using `core/test_helpers.zig:tmpDirCwd`. The memory-dir path resolution must point inside the tmp dir - check whether `memory.memoryDirPathPub` can be redirected for tests (it keys on cwd/git-root); if not, the lock/marker path helpers should accept an injected base dir for testability, mirroring how kairos tests inject `cwd`.

**Risk / footguns.** Reusing `pidAlive` from `kairos_lock.zig`: those helpers are `fn` (file-private). Either export them as `pub` from kairos and import, or duplicate (the codebase already duplicates `getpid` between the two by design - duplication is acceptable here and avoids coupling two unrelated subsystems). Do NOT call `wait()` after any child reaping (0.16 gotcha). The body-stored-timestamp redesign changes the marker format - make `lastConsolidatedAtSec` tolerant of an old empty-body marker (treat unparseable body as "now" so an in-place upgrade does not spuriously re-fire on first run).

**Size.** M.

---

### 14.4 autoDream: gate behind an enabled setting (auto_dream_enabled + auto_memory_enabled)

**Goal.** Give the user an off-switch for auto-consolidation and make the
thresholds configurable, and disable it in KAIROS/remote contexts.

**Reference behavior.** `services/autoDream/autoDream.ts:95-100` (`isGateOpen`):
requires `!getKairosActive() && !getIsRemoteMode() && isAutoMemoryEnabled() &&
isAutoDreamEnabled()`. `config.ts:13-21`: `isAutoDreamEnabled` reads the
`autoDreamEnabled` user setting (overriding a GrowthBook flag). `getConfig`
(73-93) reads `minHours`/`minSessions` from the flag with defensive validation.

**Target Zig files.**
- Edit `src/core/config.zig`: add `auto_dream_enabled: bool` (default `true` to
  match current always-on behavior, but now overridable) and `auto_memory_enabled:
  bool` (default `true`). Add `auto_dream_min_hours: u32` (default 24) and
  `auto_dream_min_sessions: u32` (default 5). Initialize in `Config.init` and free
  appropriately (these are scalars, no free needed).
- Edit `src/core/config_parse.zig` (`applyKeyValue`, ~505-679): add the four
  keys (`auto_dream_enabled`, `auto_memory_enabled`, `auto_dream_min_hours`,
  `auto_dream_min_sessions`) following the existing `parseBool` /
  `parseConfigInt` patterns.
- Edit `src/core/dream.zig`: `shouldAutoDream` (or a new `isGateOpen(cfg)`) reads
  `cfg.auto_dream_enabled && cfg.auto_memory_enabled` and uses the configurable
  thresholds instead of the hardcoded consts. Keep the consts as the *defaults*
  the config initializer uses.
- Edit `src/agent_runtime.zig` (`maybeRunDream`): pass `self.cfg`; add the
  KAIROS-active / remote-mode disable. Inspect how KAIROS-active is detected
  elsewhere (search for `kairos` state in `agent_runtime.zig`/`core`); if a
  remote-mode flag exists on `AgentRuntime`, gate on it, otherwise scope the
  remote-mode check out with a TODO referencing this gap (zcode may not have a
  remote mode surface).

**Approach.**
1. Add config fields + defaults + parser cases (smallest, most mechanical part).
2. Thread `cfg` into the dream gate. `isGateOpen` returns false unless both enabled flags are true.
3. Wire the KAIROS disable: if KAIROS is active for this project (reuse the kairos state accessor), skip auto-dream (the reference comment says "KAIROS mode uses disk-skill dream").
4. Make `min_hours`/`min_sessions` come from cfg with the same defensive clamp the reference uses (treat 0 or absurd values as the default).

**Acceptance criteria.**
- Write a test: `isGateOpen` returns false when `auto_dream_enabled = false`, false when `auto_memory_enabled = false`, true when both true.
- Write a config-parse test: setting `auto_dream_enabled = false` in a config blob round-trips to `cfg.auto_dream_enabled == false`; `auto_dream_min_hours = 12` parses to 12.
- Manual: `/config set auto_dream_enabled false` then a completed turn does not fire auto-dream (verify the lock file is not created).

**Test strategy.** Pure tests for `isGateOpen(cfg)` in `dream.zig`; parser tests in `config_parse.zig` (follow the existing UI-setting parse-test pattern there). Document the four new keys wherever the config-key reference lives (grep for where existing keys are documented, e.g. a `/config` help renderer).

**Risk / footguns.** Do not put these in `feature_kill_switches` - that is the kill-switch mechanism for telemetry/bridge features and the reference treats autoDream as a normal user setting, not a kill switch. Default to `true` so existing behavior is preserved (the survey notes "right now there's no off switch" - we are adding the switch, not changing the default). GrowthBook itself is explicitly out of scope (telemetry/flags); only the local setting is in scope.

**Size.** M.

---

### 14.5 autoDream: progress watcher + inline "Improved N files" completion message

**Goal.** Surface live dream progress and an inline completion summary in the
transcript, instead of a single static log line.

**Reference behavior.** `services/autoDream/autoDream.ts:204-248`: registers a
DreamTask, watches each assistant turn (`makeDreamProgressWatcher`, 281-313)
extracting text + tool-use count + Edit/Write `file_path`s, and on completion
appends a `createMemorySavedMessage(filesTouched)` system message with
`verb: 'Improved'` to the main transcript.

**Target Zig files.**
- Edit `src/agent_runtime.zig` (`maybeRunDream`): switch the child call from
  `handlePrompt` to `handlePromptDetailed` (the enriched path used by subagent
  spawning at ~2368) so we get `tool_traces`. Extract the set of Edit/Write
  `file_path`s from the traces. After completion, append a transcript system
  message "Improved N files: a, b, c" (or "no changes" when empty).
- Reuse whatever "system message append" surface the existing extractMemories /
  "Saved N memories" path uses (grep for `createMemorySavedMessage` analog in
  zig - likely a memory-saved system-message helper in `core/memory.zig` or a
  transcript append in `agent_runtime.zig`). If none exists, append a plain
  system line via the same channel `emitProgress`/transcript uses on completion.

**Approach.**
1. Replace `child.handlePrompt(prompt)` with the detailed variant; free the enriched result correctly (mirror the subagent spawn cleanup at ~2368+).
2. Walk `result.tool_traces`, collect `file_path` args from Edit/Write tool calls into a dedup'd list.
3. Emit periodic progress via the existing `emitProgress(reporter, ...)` channel as turns complete (the simplest faithful version: after the detailed run, emit one "Improved N files" line; a true per-turn streaming watcher requires a callback hook into the child loop which is heavier - see scope note).
4. Append the completion system message to the main transcript so the user sees it after the dream returns.

**Acceptance criteria.**
- Write a test for the file-path extraction helper: given a synthetic `tool_traces` slice containing two Edit calls and one Write call with `file_path`s and one Bash call, the helper returns the three unique file paths and ignores Bash.
- Manual: trigger a dream (lower `auto_dream_min_sessions` to 1 via config, complete a turn) and confirm an "Improved N files" line appears in the transcript.

**Test strategy.** Unit-test the pure extraction helper (`dream.extractTouchedFiles(traces) -> [][]const u8`) in `dream.zig`. The transcript-append wiring is covered by the 14.6 smoke test.

**Risk / footguns.** `handlePromptDetailed` returns owned slices (`tool_traces`, `final_text`) - free them exactly as the subagent path does to avoid leaks (the test runner is leak-sensitive). The true per-turn streaming watcher (the reference's `onMessage`) needs a message callback the child loop does not currently expose; building that is a Phase 7 concern. Scope this task to the post-completion summary + tool-trace extraction; note the streaming watcher as a follow-up rather than building a callback plumbing system here (Simplicity-First).

**Size.** M.

---

### 14.6 Manual /dream: optimistic recordConsolidation stamp

**Goal.** Stamp `lastConsolidatedAt` optimistically when a manual `/dream`
starts, so the auto-dream time gate resets even if the manual run crashes
mid-execution.

**Reference behavior.** `services/autoDream/consolidationLock.ts:126-140`
(`recordConsolidation`): on manual `/dream`, optimistically write the lock file
(stamping `lastConsolidatedAt = now`) at prompt-build time, before the skill
runs.

**Target Zig files.**
- Edit `src/core/dream.zig`: add `pub fn recordConsolidation(allocator) void`
  that stamps the marker (writes "now" as the body timestamp per the 14.3
  body-stored-timestamp design), best-effort.
- Edit `src/repl_commands.zig` (`/dream` handler, 1500-1522): after acquiring the
  lock and before running the prompt, call `recordConsolidation(allocator)`. Keep
  the existing `defer releaseLock` (which re-stamps on completion - that is fine,
  it just refreshes the timestamp).

**Approach.**
1. Implement `recordConsolidation` as a thin marker stamp (ensure dir, write "now").
2. Call it at `/dream` prompt-build time. The semantic difference is: even if `runtime.handlePrompt` errors after the stamp, the marker already reflects "consolidated now", matching the reference's optimistic stance.

**Acceptance criteria.**
- Write a tmp-dir test: call `recordConsolidation`, then `lastConsolidatedAtSec` returns ~now.
- Manual: run `/dream`, Ctrl-C mid-run; confirm the auto-dream time gate is reset (marker timestamp is recent) afterward.

**Test strategy.** Tmp-dir test in `dream.zig`, same injected-base-dir approach as 14.3.

**Risk / footguns.** Low impact; the survey rates this "largely covered" because `releaseLock` already stamps. The only behavioral delta is the crash-mid-run case. Do not double-implement marker stamping - `recordConsolidation` and the success-path `releaseLock` should both go through the same marker-write helper so the format stays consistent with `lastConsolidatedAtSec`.

**Size.** S.

---

### 14.7 preventSleep: ref-count + 4-minute restart interval + cleanup

**Goal.** Maintain continuous sleep prevention across turns longer than 5
minutes, and make nested acquire/release safe.

**Reference behavior.** `services/preventSleep.ts:29` (`refCount`), 36-58
(`startPreventSleep`/`stopPreventSleep` ref-count), 70-92 (`startRestartInterval`,
`RESTART_INTERVAL_MS = 4min`, restart caffeinate before the 5-min `-t` lapses),
113-118 (`registerCleanup`), 64-68 (`forceStopPreventSleep`).

**Target Zig files.**
- Edit `src/core/prevent_sleep.zig`: replace `active: bool` with `ref_count:
  usize`. `acquire` increments; spawn caffeinate + start the restart thread only
  on the 1->... transition (when `ref_count` goes 0 to 1). `release` decrements;
  kill caffeinate + stop the restart thread only on the ...->0 transition. Add
  `forceStop` that zeroes the count and tears down.
- Add a 4-minute restart mechanism. Since zcode has no JS event loop, the
  faithful options are: (a) a dedicated `std.Thread` that sleeps 4 minutes in a
  loop, re-spawning caffeinate while `ref_count > 0`; or (b) a lazy check on each
  `acquire`/turn that re-spawns if the existing caffeinate child has exited.
  Prefer (a) for fidelity, guarded so the thread exits cleanly on `forceStop`.

**Approach.**
1. Change the struct to ref-count. `acquire`: `ref_count += 1; if (ref_count == 1) { spawnCaffeinate(); startRestartThread(); }`. `release`: `if (ref_count > 0) ref_count -= 1; if (ref_count == 0) { stopRestartThread(); killCaffeinate(); }`.
2. Restart thread: spawn a detached `std.Thread` that loops: sleep ~4 min, and if `ref_count > 0` kill+respawn caffeinate. Use an atomic stop flag the thread checks; `forceStop`/`release`-to-0 set it. Sleeping in the thread is fine (the foreground-sleep ban in the harness is about Bash, not in-process threads), but keep the sleep chunked (e.g. 10s ticks) so teardown is responsive.
3. Keep the existing `-w <pid> -t 300` argv (it is a strict improvement over the reference: orphan-safe). The restart thread re-arms `-t 300` before it lapses.
4. `forceStop` is the cleanup hook. Wire it to the existing process-exit cleanup path (grep for where zcode registers atexit/cleanup; if there is a cleanup registry, register `forceStop`, else call it from the REPL shutdown path).

**Acceptance criteria.**
- Adapt the existing tests: "double-acquire is a no-op" becomes "double-acquire increments ref_count to 2 and a single release leaves caffeinate running" (verify via `ref_count == 1` and `child != null`). Add "two acquires then two releases tears down" (`ref_count == 0`, `child == null`).
- Keep "inert on non-macOS" and "release without acquire is safe".
- Add a test that the restart-thread stop flag is honored (start, forceStop, assert the thread is signaled to stop - testable by checking the stop flag, not by waiting 4 minutes).

**Test strategy.** Unit tests in `prevent_sleep.zig` under the test runner. Keep all caffeinate-spawning logic macOS-gated so non-macOS CI exercises only the ref-count bookkeeping (which is platform-independent). Do NOT actually sleep 4 minutes in a test - test the transition logic and the stop flag directly.

**Risk / footguns.** `child.kill(rt.io)` reaps internally - never `wait()` after (0.16 gotcha already noted in the current file). The restart thread must not race `release` to 0: guard caffeinate child access with a mutex or do all spawn/kill on a single owner. Detached threads that outlive the process are the orphan risk the `-w <pid>` flag already mitigates, so even if the thread teardown is imperfect, caffeinate still dies when zcode exits. Threading here is the only genuinely new concurrency in this phase - keep it minimal (one thread, one atomic stop flag, one mutex around the child handle).

**Size.** M.

---

### 14.8 notifier: configurable preferred channel + bell/disabled variants + Apple_Terminal probe

**Goal.** Let users force a notification channel or disable notifications, add
the combined-bell and disabled variants, and special-case Apple_Terminal.

**Reference behavior.** `services/notifier.ts:22-23` reads
`config.preferredNotifChannel`; 40-104 `sendToChannel`/`sendAuto` dispatch across
`auto`, `iterm2`, `iterm2_with_bell`, `kitty`, `ghostty`, `terminal_bell`,
`notifications_disabled`; 110-156 `isAppleTerminalBellDisabled` probes the
Terminal.app profile (osascript current profile name + `defaults export
com.apple.Terminal` + plist parse for `Bell == false`) and only rings the bell
when it is enabled.

**Target Zig files.**
- Edit `src/core/notifier.zig`: add channel variants `iterm2_with_bell` and
  `terminal_bell` (alias for `bell` with explicit naming) and treat
  `notifications_disabled` as `.none`. Add a `pub fn channelFromConfig(name:
  []const u8) Channel` that maps the reference's string values (`auto`,
  `iterm2`, `iterm2_with_bell`, `kitty`, `ghostty`, `terminal_bell`,
  `notifications_disabled`) to the enum, with `auto` resolving via the existing
  `pickChannel()` plus the Apple_Terminal probe. Add `emit`/`buildBytes` cases
  for the combined variant (emit the OSC then a bell).
- Add `fn isAppleTerminalBellDisabled(allocator) bool` that runs the osascript +
  defaults probe via `std.process.run`. Gate it macOS-only and behind
  `TERM_PROGRAM == "Apple_Terminal"`. Parse the plist minimally (find the current
  profile block, check `Bell` boolean) - a full plist parser is overkill; a
  targeted scan for the profile's `<key>Bell</key><false/>` suffices, with a
  conservative default (treat unknown as "bell enabled" so we still notify).
- Edit `src/core/config.zig` + `src/core/config_parse.zig`: add
  `preferred_notif_channel: []u8` (default `"auto"`) and a parser case.
- Edit `src/agent_runtime.zig` (~2029-2047): replace the bare `pickChannel()`
  call with `notifier.channelFromConfig(self.cfg.preferred_notif_channel,
  allocator)` so the user setting is honored. Keep the isatty gate at the call
  site.

**Approach.**
1. Extend the enum + emit/buildBytes for the new variants (mechanical).
2. Add `channelFromConfig`: `"auto"` -> run the existing detection; on `Apple_Terminal` probe the bell and return `.terminal_bell` only if enabled, else `.none` (matches the reference's `no_method_available`). Other explicit values map directly.
3. Add the Apple_Terminal probe (macOS-only, behind the explicit terminal check, with conservative fallbacks on every error - the reference returns false/no-notify on any error).
4. Add the config field + parser + wire the call site.

**Acceptance criteria.**
- Write tests: `channelFromConfig("iterm2_with_bell", ...)` -> `.iterm2_with_bell`; `"notifications_disabled"` -> `.none`; `"kitty"` -> `.kitty`; an unknown value falls back to `auto` behavior (or `.none`, matching the reference's `default: return 'none'` - pick `.none` to be safe and document it).
- Write a test: `buildBytes(.iterm2_with_bell, ...)` produces the OSC-9 sequence followed by a `0x07` bell byte.
- Write a config-parse test: `preferred_notif_channel = terminal_bell` round-trips.
- Manual on macOS Apple Terminal: with bell enabled in the profile, a long turn rings; with bell disabled, it does not (and no broken escape is printed).

**Test strategy.** Pure tests for `channelFromConfig` and `buildBytes`/`emit` for the new variants. The Apple_Terminal probe is hard to unit-test (needs Terminal.app); test only that it returns a conservative default when `TERM_PROGRAM != "Apple_Terminal"` and is macOS-gated. Parser test in `config_parse.zig`.

**Risk / footguns.** `std.process.run` for osascript/defaults: use the 0.16 one-shot `std.process.run(allocator, rt.io, .{...})` (not the removed `Child.init`), capture stdout with `.stdout_limit = .limited(...)`, and free `stdout`/`stderr`. The probe must never throw into the notify path - any error returns "bell enabled / notify" or "no-notify" conservatively, never propagates. Do not pull in a heavy plist dependency; a targeted byte scan of `defaults export` output is sufficient and matches Simplicity-First.

**Size.** M.

---

### 14.9 notifier: fire the Notification hook before emitting

**Goal.** Run a user-configured `Notification` hook on every notification, before
routing to a terminal channel.

**Reference behavior.** `services/notifier.ts:25`: `await
executeNotificationHooks(notif)` runs before `sendToChannel`.

**Target Zig files.**
- Edit `src/agent_runtime.zig` (the notify site ~2029-2048): before emitting the
  escape bytes, fire the `Notification` hook via the Phase 5 dispatch layer.
- Depends on **Phase 5**: that phase retires the 3-variant `HookEvent` in
  `hooks.zig` and routes through `hook_event.Event`, and adds the generic
  dispatch entry point that can fire any event with a context. This task adds the
  *call*.

**Approach.**
1. Build a notification hook context (event = `.notification`, plus the message/title as additional fields the hook payload carries - mirror the reference's `NotificationOptions { message, title, notificationType }`). The payload builder lives in `hook_io.zig`; if it does not yet support a notification payload shape, add a small `buildNotificationPayload(message, title, type)`.
2. Fire the hook via the Phase 5 dispatch function (e.g. `hooks.fireEvent(allocator, .notification, ctx)`), best-effort - a missing/failing hook must not block the notification. `Notification` is observability-only (`hook_event.isBlockingCapable(.notification) == false`), so even an exit-2 does not block.
3. Then proceed to emit the terminal escape (the existing path).

**Acceptance criteria.**
- Write a hook-dispatch test (in `hooks.zig` test suite): a configured `Notification` command hook in a temp `settings.json` runs when `.notification` is fired, and its exit code does not block (the notification still emits).
- Manual: configure a `Notification` hook that touches a sentinel file; trigger a long turn; confirm the sentinel appears.

**Test strategy.** Reuse the Phase 5 hook-execution test harness (temp settings.json + command hook). Assert the hook ran (sentinel/output) and that `.notification` is non-blocking via `interpretExit(.notification, 2) == .user_error` (already covered in `hook_event.zig` tests; add the firing-path coverage here).

**Risk / footguns.** Hard dependency on Phase 5 - do not start this until Phase 5's dispatch layer accepts arbitrary `hook_event.Event`. Firing a hook is process-spawning work on a hot path (turn completion); keep it best-effort and behind the same isatty/long-turn gate as the emit so quiet sessions do not pay the cost. The reference fires the hook even for disabled channels (it runs before `sendToChannel`); decide whether zcode fires when `preferred_notif_channel == notifications_disabled` - the reference does fire it (push-to-phone still works with the terminal channel off), so fire the hook independent of the channel decision.

**Size.** M.

---

### 14.10 Persistent runtime-state store (numStartups, onboarding state, tipsHistory, lastReleaseNotesSeen) [KEYSTONE]

**Goal.** Introduce a small persisted state store - separate from user
`config.toml` - to hold derived runtime counters that several later tasks key on.

**Reference behavior.** The reference's global config holds `numStartups`
(`tipHistory.ts:4`, `tipRegistry.ts:102/330/346`) and `tipsHistory`
(`tipHistory.ts:3-17`). Project config holds `hasCompletedProjectOnboarding` and
`projectOnboardingSeenCount` (`projectOnboardingState.ts:43-83`). `lastReleaseNotesSeen`
lives in global config (`setup.ts:386-393`).

**Target Zig files.**
- Create `src/core/runtime_state.zig` (new deep module). Register it in
  `src/main.zig`'s comptime test-discovery block (`_ = @import("core/runtime_state.zig");`).
- It stores a small JSON document under the zcode home (e.g.
  `<zcode_home>/state.json`), resolved via `paths.resolve(allocator).zcode_home`.
  Fields: `num_startups: u64`, `tips_history: map<tip_id, u64>`,
  `last_release_notes_seen: []const u8` (version string). Per-project onboarding
  state is keyed by the project key (reuse `kairos_lock.projectKey` encoding) -
  either a nested object in the same file or a per-project file under
  `<zcode_home>/state/<project-key>.json`. Prefer a single `state.json` with a
  `projects` map to keep IO to one read/write.
- Public API: `load(allocator) State`, `save(allocator, *State) void` (best-effort),
  `incrementStartups(allocator) u64` (load, ++, save, return new value),
  `getProjectOnboarding(state, project_key) ProjectOnboarding`,
  `setProjectOnboarding(...)`, `recordTipShown(allocator, tip_id)`,
  `sessionsSinceTipShown(state, tip_id) -> u64` (returns a large sentinel when
  never shown), `getLastReleaseNotesSeen` / `setLastReleaseNotesSeen`.

**Approach.**
1. Define the `State` struct and a JSON (de)serializer using `std.json` (zcode already parses JSON for settings; follow `hook_config.zig` parse style). On parse failure or missing file, return a zero-value default state (never crash on a corrupt state file - it is derived data, regenerable).
2. Writes are best-effort and atomic-ish: write to a temp file then rename, or accept truncate-write (state loss is harmless). Use the 0.16 file API (`createFile(.truncate=true)`, `writeStreamingAll`).
3. `incrementStartups` is called once per process start from the REPL boot path (Task 14.16 wiring).
4. Keep the module dependency-light: no config coupling, just `paths` + `rt.io` + `std.json` + `clock`.

**Acceptance criteria.**
- Write tmp-dir tests (inject the base dir for testability, like kairos): `incrementStartups` returns 1 on first call, 2 on second, persisting across `load`.
- `recordTipShown` then `sessionsSinceTipShown` for the same id at startup N vs N+3 returns 3; for an unseen id returns the sentinel.
- `setProjectOnboarding`/`getProjectOnboarding` round-trips `seen_count` and `completed` per project key, isolated between two different project keys.
- A corrupt/empty `state.json` loads as the zero-value default without error.

**Test strategy.** Tmp-dir tests in `runtime_state.zig`. The module must accept an injected base directory (or honor an env override) so tests do not write to the real `~/.zcode`. Mirror how `kairos_lock` tests inject `cwd`.

**Risk / footguns.** This is derived state, NOT configuration - keep it out of `config.toml`/`config.zig` (the survey notes the reference keeps these in "global config", but zcode's `config.toml` is user-authored; conflating them would let a user's hand edits clobber counters and vice versa). Use `std.json` ObjectMap carefully on the 0.16 footgun: after parse, take `&parsed.value.object` by pointer when mutating (a value copy desyncs the entries pointer on realloc - CLAUDE.md gotcha). Keep the file small and the schema forward-compatible (ignore unknown keys).

**Size.** M.

---

### 14.11 Startup counter + onboarding seen-count cap + completion persistence

**Goal.** Persist `numStartups` and per-project onboarding state so the nudge
graduates after 4 views or on completion.

**Reference behavior.** `projectOnboardingState.ts:43-83`:
`isProjectOnboardingComplete`, `maybeMarkProjectOnboardingComplete` (persists
completion), `shouldShowProjectOnboarding` (hides once `seenCount >= 4` or
completed), `incrementProjectOnboardingSeenCount`.

**Target Zig files.**
- Edit `src/core/onboarding.zig`: add stateful helpers layered on
  `runtime_state.zig`: `shouldShowProjectOnboarding(allocator, cwd, runtime) bool`
  (returns false when completed, when `seen_count >= 4`, or when already
  onboarded; else true), `maybeMarkComplete(allocator, cwd, runtime) void`
  (persists `completed = true` when `isProjectOnboarded`), and
  `incrementSeenCount(allocator, cwd) void`.
- Edit the nudge site `src/cli/repl.zig` (~4964): replace the bare
  `needsInstructionFile()` check with `onboarding.shouldShowProjectOnboarding(...)`,
  and call `incrementSeenCount` each time the nudge is shown +
  `maybeMarkComplete` after prompt submit (mirror the reference's REPL.tsx
  per-submit call).

**Approach.**
1. Build the three stateful helpers on top of `runtime_state` keyed by `kairos_lock.projectKey(cwd)`.
2. Keep the existing stateless `isProjectOnboarded`/`buildSnapshot` as the underlying predicate (no behavior change there).
3. Wire the REPL: show the nudge only when `shouldShowProjectOnboarding`; bump the seen-count on show; mark complete on submit when onboarded.

**Acceptance criteria.**
- Write a tmp-dir test: `shouldShowProjectOnboarding` returns true initially (workspace with source, no ZCODE.md), still true after 3 increments, false after the 4th (seen-count cap), and false once `maybeMarkComplete` records completion.
- Write a test: completing onboarding (creating ZCODE.md) then `maybeMarkComplete` flips `completed` so the nudge stays hidden even after a seen-count reset.

**Test strategy.** Tmp-dir tests in `onboarding.zig` using the injected-base-dir `runtime_state`. Use `core/test_helpers.zig:tmpDirCwd` for the workspace and a separate injected state dir.

**Risk / footguns.** Depends on Task 14.10. The seen-count must increment only when the nudge is actually rendered (not on every render pass) to match the reference's `incrementProjectOnboardingSeenCount` semantics; pick a single call site. Do not regress the existing stateless tests.

**Size.** M.

---

### 14.12 Tip cooldown / relevance gating / history

**Goal.** Give each tip a cooldown and relevance predicate, and filter the
registry by both, keyed on the persisted tip history + startup counter.

**Reference behavior.** `tipRegistry.ts:668-686` (`getRelevantTips` filters by
`isRelevant(context)` AND `getSessionsSinceLastShown(id) >= cooldownSessions`);
`tipHistory.ts:3-17` (`recordTipShown`/`getSessionsSinceLastShown` keyed on
`numStartups`).

**Target Zig files.**
- Edit `src/core/tips.zig`: replace (or wrap) the flat `[]const []const u8`
  registry with a `Tip` struct: `{ id: []const u8, text: []const u8,
  cooldown_sessions: u64, relevant: ?fn(TipContext) bool }`. Keep `at`/`pick`/`next`
  for back-compat where used. Add `getRelevantTips(allocator, state, context) ->
  []const Tip` filtering by relevance AND `runtime_state.sessionsSinceTipShown(id)
  >= cooldown_sessions`.
- `TipContext` carries the small set of signals the reference's `isRelevant`
  predicates use that zcode can cheaply supply (e.g. is-git-repo, has-ZCODE.md,
  vim-mode-on). Keep it minimal - only signals we can populate.

**Approach.**
1. Convert the 12 existing strings into `Tip` records with stable `id`s and sensible default cooldowns (the reference uses small integers like 1-10; pick uniform defaults, e.g. cooldown 3, and `relevant = null` = always relevant for the generic tips).
2. Implement `getRelevantTips` as a pure filter over the registry given the loaded `state` and a `TipContext`.
3. History recording goes through `runtime_state.recordTipShown` (Task 14.10).

**Acceptance criteria.**
- Write a test: a tip with `cooldown_sessions = 3` shown at startup 5 is excluded at startup 6/7 and included again at startup 8.
- Write a test: a tip with a `relevant` predicate returning false is excluded regardless of cooldown.
- Write a test: a never-shown tip (sentinel sessions-since) is always included (cooldown satisfied).

**Test strategy.** Pure tests in `tips.zig` driving a synthetic `state` (built in-memory, no IO) and `TipContext`. Keep `getRelevantTips` IO-free (take the loaded state as a parameter) so it is trivially testable.

**Risk / footguns.** Depends on Task 14.10. Keep the registry comptime-static where possible (the `Tip` array can stay comptime; only the history/state is runtime). Do not break the existing `/tips` command - it can switch to `getRelevantTips` + pick, or keep using `pick` for the on-demand case.

**Size.** M.

---

### 14.13 Tips on the working spinner (longest-since-shown scheduler)

**Goal.** Show a relevant tip on the spinner while the agent works, selecting the
tip with the longest sessions-since-shown, and record it as shown.

**Reference behavior.** `tipScheduler.ts:10-58`:
`selectTipWithLongestTimeSinceShown` (sort relevant tips by sessions-since
descending, take first), `getTipToShowOnSpinner` (respects `spinnerTipsEnabled`,
returns the selected tip), `recordShownTip` (records + logs).

**Target Zig files.**
- Edit `src/core/tips.zig`: add `selectLongestSinceShown(tips, state) -> ?Tip`
  and `getTipToShowOnSpinner(allocator, cfg, state, context) -> ?Tip` (returns
  null when `cfg.spinner_tips_enabled == false` or no relevant tips).
- Edit `src/cli/repl_spinner.zig`: render the selected tip alongside the spinner
  text while a turn is in flight; on first render of a turn, call
  `runtime_state.recordTipShown`.

**Approach.**
1. `selectLongestSinceShown`: map relevant tips to `(tip, sessionsSince)`, pick the max sessions-since (the reference's exact behavior). Deterministic given state.
2. `getTipToShowOnSpinner` short-circuits on the disabled flag.
3. Spinner wiring: choose one tip per turn (pick at turn start), render it on the spinner line, record it once. Keep the render integration minimal - one line under/beside the existing spinner text.

**Acceptance criteria.**
- Write a test: given three relevant tips with sessions-since `[2, 9, 4]`, `selectLongestSinceShown` returns the index-1 (sessions-since 9) tip.
- Write a test: `getTipToShowOnSpinner` returns null when `spinner_tips_enabled == false`.
- Manual: start a long turn; a tip appears on the spinner; a subsequent session shows a different (longer-since-shown) tip.

**Test strategy.** Pure tests for `selectLongestSinceShown`/`getTipToShowOnSpinner` in `tips.zig` (synthetic state). The spinner render is verified manually (TUI) and by a smoke check that `recordTipShown` is invoked once per turn.

**Risk / footguns.** Depends on Tasks 14.10 + 14.12 + the `spinner_tips_enabled` config from 14.14. The current spinner UX is `/tips` on demand + a welcome tip; this adds the passive surface. Do not record the tip multiple times within one turn (the spinner re-renders frequently) - record once at turn start.

**Size.** M.

---

### 14.14 spinnerTipsEnabled / spinnerTipsOverride settings

**Goal.** Add settings to disable tips, supply custom tips, and exclude defaults.

**Reference behavior.** `settings/types.ts:664-685` (`spinnerTipsEnabled`,
`spinnerTipsOverride { tips: string[], excludeDefault: boolean }`);
`tipRegistry.ts:655-686` (`getCustomTips` + `excludeDefault`); `tipScheduler.ts:35-37`
(`spinnerTipsEnabled` gate).

**Target Zig files.**
- Edit `src/core/config.zig`: add `spinner_tips_enabled: bool` (default true),
  `spinner_tips_custom: []u8` (newline- or `;`-separated custom tips, default ""),
  `spinner_tips_exclude_default: bool` (default false). Init + free the string
  field.
- Edit `src/core/config_parse.zig`: add the three parser cases.
- Edit `src/core/tips.zig`: `getRelevantTips`/`getTipToShowOnSpinner` accept the
  config; custom tips become cooldown-0 always-relevant `Tip`s parsed from
  `spinner_tips_custom`; when `spinner_tips_exclude_default` is true, the built-in
  registry is suppressed and only custom tips are eligible.

**Approach.**
1. Config fields + parser (mechanical, follows existing UI settings).
2. In `tips.zig`, build the effective tip list: `(exclude_default ? [] : registry) ++ parseCustomTips(cfg.spinner_tips_custom)`, where custom tips get `cooldown_sessions = 0` and `relevant = null`.
3. Parsing custom tips allocates - so the effective-list builder is the one allocating function; keep the pure filter operating on a passed-in slice.

**Acceptance criteria.**
- Write a config-parse test: `spinner_tips_enabled = false`, `spinner_tips_exclude_default = true`, and a custom-tips value round-trip.
- Write a test: with `exclude_default = true` and two custom tips, the effective tip list is exactly the two custom tips.
- Write a test: with `exclude_default = false` and one custom tip, the effective list is registry + 1.

**Test strategy.** Parser tests in `config_parse.zig`; effective-list tests in `tips.zig`.

**Risk / footguns.** The reference uses a JSON array for `spinnerTipsOverride.tips`; zcode's config is key=value TOML-ish, so use a delimited string and document the delimiter. Free the custom-tip slices the builder allocates (test-runner is leak-sensitive). Custom tips being cooldown-0 means they show often by design (matches the reference's "always-relevant cooldown-0" note).

**Size.** S.

---

### 14.15 Release-notes-on-startup with lastSeen-version diff

**Goal.** Auto-surface "what's new" once after an upgrade, filtering to versions
strictly newer than the last-seen version, capped at 5.

**Reference behavior.** `releaseNotes.ts:207-240` (`getRecentReleaseNotes`:
semver-filter to versions `gt` previousVersion, newest-first, cap
`MAX_RELEASE_NOTES_SHOWN = 5`); 287-327 (`checkForReleaseNotes`); `setup.ts:386-393`
(startup call using `lastReleaseNotesSeen`).

**Target Zig files.**
- Edit `src/core/changelog.zig`: add `pub fn recentSince(allocator, entries,
  last_seen_version, current_version, max) -> []const VersionEntry` (or a
  formatted string) that filters `entries` to versions strictly newer than
  `last_seen_version` using `update.compareVersions` (reuse `update.zig:729`),
  newest-first, capped at `max`. Returns empty when `last_seen >= current` (i.e.
  no upgrade or already seen). Add a `checkForReleaseNotes`-equivalent that
  combines the embedded changelog parse + the version diff.
- Edit `src/cli/repl.zig` startup path (~5091/`appendWelcomeBanner` ~5148): after
  the welcome banner, if `runtime_state.getLastReleaseNotesSeen() != current
  version`, render the new-since notes once, then
  `runtime_state.setLastReleaseNotesSeen(current_version)`.
- Use the build-time version string (the `X.Y.Z+<hash>` value `build.zig`
  produces) for `current_version`; strip the `+<hash>` before semver compare
  (the reference `coerce`s the SHA off - mirror that).

**Approach.**
1. Add the version-diff filter to `changelog.zig`, reusing `compareVersions`. The embedded changelog is already parsed by `parseChangelog`; this just filters the result.
2. Wire the startup surface in the REPL: read `last_release_notes_seen` from `runtime_state`, compare to the current base version, render + stamp if newer.
3. Keep the existing `/release-notes` command unchanged (it shows the first N regardless); this is the automatic upgrade surface only.

**Acceptance criteria.**
- Write a test: given parsed entries for `[3.0.0, 2.0.0, 1.0.0]`, `recentSince(last_seen="2.0.0", current="3.0.0", max=5)` returns only `3.0.0`.
- Write a test: `recentSince(last_seen="3.0.0", current="3.0.0", ...)` returns empty (already seen).
- Write a test: a `+<hash>` suffix on either version is stripped before comparison (so `3.0.0+abc` vs `3.0.0` is "already seen").
- Manual: bump the version, rebuild/install, launch; the new notes appear once; relaunch shows nothing.

**Test strategy.** Pure tests in `changelog.zig` (synthetic entries + version strings). Startup-surface wiring covered manually + a smoke test that the stamp is written.

**Risk / footguns.** Depends on Task 14.10 (the `last_release_notes_seen` store). `compareVersions` in `update.zig` is currently used only for update checks - confirm it handles the `X.Y.Z` shape and pre-strip the `+hash`. The first launch after this ships has `last_release_notes_seen == ""` (never seen) - decide whether to show ALL notes (noisy) or none on the very first run; match the reference's "no previous version -> show recent up to cap" but consider stamping silently on the very first launch to avoid a wall of notes for existing users (document the choice).

**Size.** M.

---

### 14.16 Wire numStartups increment into REPL boot

**Goal.** Increment the persisted startup counter once per process so tip
cooldowns and any startup-gated logic advance.

**Reference behavior.** `numStartups` is bumped at startup and read throughout
(`tipHistory.ts:4`, `tipRegistry.ts` relevance gates).

**Target Zig files.**
- Edit `src/cli/repl.zig` boot path (the `run()` entry, ~5091): call
  `runtime_state.incrementStartups(allocator)` exactly once, early, before tips
  or onboarding are evaluated.

**Approach.**
1. One call in the REPL boot. Guard so it only runs for interactive REPL sessions (not for every one-shot subcommand) to match the reference's "startup" semantics - a `zcode version` invocation should not bump the counter.

**Acceptance criteria.**
- Manual: launch the interactive REPL twice; `state.json` `num_startups` is 2.
- A non-interactive one-shot (`zcode --version` or a single piped prompt) does not bump it.

**Test strategy.** Covered by the `incrementStartups` unit test in 14.10; the call-site guard is a manual check.

**Risk / footguns.** Depends on Task 14.10. Place the call where it runs once per interactive session, not per turn. Best-effort (a failed state write must not block boot).

**Size.** S.

---

### 14.17 tool-use summary generator (cheap-model ~30-char label) [scoped-small]

**Goal.** Provide a small, opt-in cheap-model call that turns a completed tool
batch into a single ~30-char past-tense label, for any future progress-client
surface.

**Reference behavior.** `services/toolUseSummary/toolUseSummaryGenerator.ts:15-24`
(git-commit-subject-style system prompt), 45-97 (`generateToolUseSummary` via
`queryHaiku`, `querySource = 'tool_use_summary_generation'`), 102-112
(`truncateJson` to 300 chars per field).

**Target Zig files.**
- Create `src/core/tool_use_summary.zig` (new deep module). Register in
  `src/main.zig` comptime block.
- Pure helpers: `buildSummaryPrompt(allocator, batch, intent_prefix) -> []u8`
  (system + user prompt with each tool name/input/output truncated to 300 chars),
  and `truncateField(s, 300)`. The actual model call is a thin wrapper that, if
  wired, uses the existing cheap-model path (the preprocessor provider/model in
  `cfg` is the natural "cheap model" surface zcode already has - reuse it rather
  than inventing a Haiku-specific path).

**Approach.**
1. Build the prompt construction + truncation as pure, fully-tested functions (this is the bulk of the value and is self-contained).
2. Add a `generate(allocator, ctx, batch, intent) -> ?[]u8` that calls the cheap model best-effort (swallows failures, returns null), reusing the preprocessor model config. Gate it behind an opt-in (default off) since zcode has no SDK/streaming-client consumer today.

**Acceptance criteria.**
- Write tests: `truncateField` caps at 300 chars and appends an ellipsis marker; `buildSummaryPrompt` includes the commit-subject-style instruction and the truncated batch fields.
- The `generate` wrapper returns null on a model error (no panic), verified with the mock provider.

**Test strategy.** Pure tests for the prompt/truncation helpers in `tool_use_summary.zig`. The model-call wrapper is tested against the mock provider returning a canned/error response.

**Risk / footguns.** The reference explicitly says this is "used by the SDK to provide high-level progress updates to clients." zcode has no such client today, so the value is latent. Build only the small self-contained prompt/truncation core + a best-effort wrapper; do NOT build a background job, an SDK surface, or a Haiku-specific provider path (Simplicity-First). If wiring proves to have no consumer, the module still stands as tested infrastructure; mark its call-site wiring as deferred.

**Size.** M (mostly the pure helpers; the model wrapper is thin).

---

## Verification

1. **Build + test (full suite under the custom runner):**
   ```
   /Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build test
   ```
   All new tests (dream touched-since/throttle/lock-reclaim/rollback, prevent_sleep
   ref-count, notifier channel variants, runtime_state persistence, onboarding
   seen-count cap, tips cooldown/scheduler/override, changelog version-diff,
   tool_use_summary helpers) must pass. Confirm `RUN: <name>` lines appear for the
   new tests (the runner prints them) and there are no leaks reported.

2. **Release build + install (per CLAUDE.md, fresh inode to keep the signature
   valid):**
   ```
   /Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build -Doptimize=ReleaseFast
   rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode
   ```
   Bump `.version` in `build.zig.zon` first (patch bump; `build.zig` appends the
   git short-hash automatically).

3. **Manual checks (macOS, interactive REPL):**
   - autoDream off-switch: `/config set auto_dream_enabled false`, complete a
     turn, confirm no `.consolidate-lock` / no marker write.
   - autoDream reclaim: hand-write a stale `.consolidate-lock` with a dead PID +
     old timestamp, lower `auto_dream_min_sessions`, complete a turn, confirm the
     dream fires (lock reclaimed).
   - autoDream rollback: force a fork failure (e.g. point at an unreachable
     provider), complete a turn after the time gate opens, confirm the marker
     timestamp did NOT advance (gate would fire again).
   - prevent-sleep restart: start a >5-minute turn (slow provider / large task),
     confirm with `pmset -g assertions` that an idle-sleep assertion stays
     present past the 5-minute mark (the 4-min restart re-arms it).
   - notifier: `/config set preferred_notif_channel notifications_disabled`,
     long turn -> no bell; set `terminal_bell` -> bell. On Apple Terminal with
     bell disabled in the profile, `auto` -> no bell, no broken escape printed.
   - Notification hook: configure a `Notification` command hook touching a
     sentinel file; long turn -> sentinel appears.
   - tips on spinner: long turn shows a tip; relaunch shows a different
     (longer-since-shown) tip; `/config set spinner_tips_enabled false` -> none.
   - onboarding nudge graduates: in a repo without ZCODE.md, the nudge appears;
     after 4 launches it stops; creating ZCODE.md + submitting a prompt marks it
     complete permanently.
   - release-notes on upgrade: bump version, rebuild/install, launch -> "what's
     new" appears once; relaunch -> nothing.
   - state store: inspect `~/.zcode/state.json` and confirm `num_startups`,
     `tips_history`, `last_release_notes_seen`, and per-project onboarding state
     are populated and survive restarts.

4. **No-regression spot checks:** `/dream`, `/release-notes`, `/tips`,
   `/onboarding` all still work on demand exactly as before.

## Out-of-scope / deferred notes

- **`background-svc-08` GrowthBook flags / analytics events** (`tengu_*`):
  out of scope. zcode does not ship telemetry; only the local
  `preferred_notif_channel` setting and the channel variants are built. The
  `logEvent` calls in the reference have no zcode equivalent.

- **`background-svc-10` prompt-suggestion service** (LLM idle next-prompt
  predictor): **deferred.** It needs a forked-agent-with-shared-cache + tool-deny
  callback + an extensive output filter + idle-trigger infrastructure zcode does
  not have. Our existing `__prompt_suggestion_*` names are an unrelated
  tab-completion collision, not this feature. Large, low-priority. Revisit only
  if an idle-predictor UX is explicitly wanted; it would itself depend on Phase 7
  forked-agent work and a new idle-event source.

- **`background-svc-11` speculation service** (pre-execute the predicted prompt
  in a per-pid copy-on-write FS overlay): **deferred.** Depends on
  `background-svc-10` (the suggestion to speculate on) AND a CoW filesystem
  overlay zcode does not have. The shell sandbox temp dirs are for live shell
  isolation, not precomputation replay. Largest item in this phase; defer until
  both prerequisites exist.

- **`background-svc-12` Magic Docs service**: **deferred.** In the reference this
  is gated behind `USER_TYPE === 'ant'` (internal-only), so external parity does
  not require it. It needs a FileRead listener registry, an idle-turn
  post-sampling hook, and a forked Edit-only agent with `canUseTool` restricted
  to a single path - none of which exist. Note: `FileChanged` is declared in
  `hook_event.zig` but never fired; that is a separate latent gap, not this
  service.

- **`background-svc-13` per-sub-agent AgentSummary** (30s 3-5 word progress
  labels): **deferred.** Targets a multi-sub-agent coordinator UI. Needs a
  forked-agent-with-shared-cache mechanism and an AgentProgress app-state
  surface; `spawnBackgroundAgent` (`agent_runtime.zig:2999-3159`) currently writes
  only initial + final status. Build only if a coordinator UI becomes a goal.

- **`background-svc-14` tool-use summary**: the *call-site wiring* is deferred
  (no SDK/streaming-client consumer exists). Task 14.17 builds and tests the
  self-contained prompt/truncation core + a best-effort model wrapper so the
  infrastructure is ready, but it is not hooked into any live surface.

- **`background-svc-05` true per-turn streaming watcher**: the reference's
  `onMessage` per-turn watcher needs a message callback the child agent loop does
  not expose. Task 14.5 builds the post-completion summary + tool-trace
  extraction (the user-visible value); the live streaming watcher is a Phase 7
  follow-up, not built here.

- **`styles-onboarding-08` changelog network fetch + on-disk cache**:
  **accepted as-is (present-different).** zcode deliberately bakes CHANGELOG.md
  into the binary at build time (`build.zig:85-92`, `core/changelog.zig:4-11`) to
  avoid a network dependency and a binary-relative file lookup. This serves the
  same `/release-notes` purpose. We do NOT build the GitHub raw fetch, the
  `~/.cache/changelog.md` write, the `changelogLastFetched` timestamp, the
  background refresh, or the 500ms fetch-race. The only release-notes work in this
  phase is the version-diff + lastSeen tracking (Task 14.15), which operates on
  the embedded changelog.
