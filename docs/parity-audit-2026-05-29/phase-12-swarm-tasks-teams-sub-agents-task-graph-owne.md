# Phase 12: Swarm, tasks, teams, sub-agents: task graph, ownership, team binding, messaging, agent frontmatter, isolation, direct-connect server

## Overview

**What.** This phase builds out zcode's multi-agent coordination substrate so
it matches the reference's swarm model. Today zcode has the right *shapes*
(per-task `.task` files, a `.team` metadata file, an append-only team message
log, fire-and-forget background sub-agents, a static-bundle share daemon) but
none of the *coordination semantics* that make the reference's swarm work:

- A real task dependency graph (`blocks`/`blockedBy`) with claim-time gating.
- Atomic task ownership / claim with conflict and busy detection.
- `activeForm` and arbitrary `metadata` on tasks.
- Team = task-list binding so a swarm's tasks are isolated and renumber from 1,
  plus one-team-per-leader enforcement, unique-name fallback, and session
  cleanup.
- Structured per-member team records (name/type/model/cwd/pane/subscriptions).
- Addressed SendMessage (named teammate inbox + `*` broadcast) and a structured
  message protocol (shutdown request/response, plan approval response).
- An agent name registry with queued-message delivery and resume-from-transcript.
- Per-agent worktree/cwd isolation on spawn, and the AgentRun multi-agent input
  fields (name/team_name/mode/isolation/cwd/description).
- Richer agent frontmatter (mcpServers / hooks / skills-preload / disallowedTools
  / permissionMode / maxTurns / memory).
- An in-process teammate lifecycle (idle/active, pending-message queue, capped
  transcript, abort-on-shutdown).
- A `TaskCreated` blocking-hook gate and SDK-style task termination events.
- A handoff safety classifier and background-agent rolling summaries.
- A coordinator mode (env-gated persona swap + worker-tools context + resume
  reconciliation).
- A direct-connect server (POST /sessions + WebSocket SDK stream) with a
  persisted session index and a reconnecting WS-client driver with ping
  keepalive.

**Why.** The reference's entire teammate coordination model is built on two
primitives we lack: (1) the `blockedBy` graph plus atomic `owner` claim, which
is how multiple teammates avoid double-working and respect ordering; and (2)
addressed, auto-delivered messages, which is how the leader drives teammates
and how teammates report back. Without these, "swarm" in zcode is just parallel
fire-and-forget sub-agents that cannot coordinate, be addressed, be resumed, or
be gracefully shut down. The direct-connect server and coordinator mode are the
two local (non-cloud) operator-facing surfaces the reference exposes for driving
a session remotely and for orchestrating workers.

**Dependencies.** Phases 5, 6, 7.
- Phase 5 (session/transcript persistence) is consumed by remote-server-03
  (server session index) and by swarm-tasks-10/13 (resume-from-transcript).
- Phase 6 (MCP depth, scoped config, structured stdio) is consumed by
  swarm-tasks-12 (per-agent `mcpServers`) and remote-server-02/04 (the WS
  transport and the direct-connect SDK message contract reuse the MCP
  WebSocket framing in `src/mcp/websocket.zig`).
- Phase 7 (agent loop + provider robustness) is the loop the in-process
  teammate lifecycle (swarm-tasks-13) and background summarization
  (swarm-tasks-17) hook into.

**Effort.** XL overall. The cluster splits into roughly four buildable
sub-systems that can proceed largely in parallel after the shared task-store
refactor lands first:

1. **Task store** (swarm-tasks-01/02/03/04, plus the JSON-record migration this
   forces) - must land first; everything else that touches tasks builds on it.
2. **Teams + messaging** (swarm-tasks-05/06/07/08/09/10/13/15) - depends on (1).
3. **Agent spawn surface** (swarm-tasks-11/12/16/17, tools-14) - independent of
   (2) except where SendMessage targets a spawned agent.
4. **Remote/coordinator** (remote-server-01/02/03/04) - independent of
   (1)/(2)/(3) except remote-server-03 reuses the session store.

## Gaps covered

| id | title | severity | size | our current state |
|---|---|---|---|---|
| swarm-tasks-01 | Task dependency graph (blocks/blockedBy) with claim-time blocking | medium | M | PARTIAL. `deps` stored as an inert free-text string (`task.zig:21`); no `blocks`/`blockedBy` arrays, no `blockTask`, no claim-time blocked check, no cascade cleanup on delete. |
| swarm-tasks-02 | Task ownership / claim flow (owner assign + busy check) | medium | M | PARTIAL. `owner` field stored and settable at create (`task.zig:18,159,381`), persisted/restored. No atomic `claimTask`, no conflict rejection, no busy-check variant, no `getAgentStatuses`/`unassignTeammateTasks`; `taskUpdate` cannot modify owner. |
| swarm-tasks-03 | activeForm (present-continuous spinner label) on tasks | low | S | ABSENT on tasks. Exists on TodoWrite (`core/todos.zig:25`) but TaskRecord/TaskSnapshot/schema/dispatch have no `activeForm`. |
| swarm-tasks-04 | Arbitrary task metadata field | low | S | ABSENT. Fixed 17-field record; no `metadata` key-value store, `readTaskRecord` drops unknown keys. |
| swarm-tasks-05 | Team = TaskList correspondence (fresh numbering + leader binding) | medium | M | ABSENT. Tasks resolve to a single global `state/tasks` (`helpers.zig:7`); no per-team task dir, no `getTaskListId`/`setLeaderTeamName`/`resetTaskList`/`ensureTasksDir`, no fresh numbering. |
| swarm-tasks-06 | Structured team membership records | medium | M | PARTIAL. `.team` file stores `members` as one opaque string (`team.zig:27-30`); no per-member struct (agentId/agentType/model/joinedAt/pane/backend/cwd/subscriptions). |
| swarm-tasks-07 | One-team-per-leader + unique name gen + session cleanup | low | M | ABSENT. `teamCreate` hard-errors on existing name (`team.zig:21-23`); no leader binding, no word-slug fallback, no session-end cleanup registration. |
| swarm-tasks-08 | SendMessage named inbox + broadcast + auto-delivery | high | L | PARTIAL. Single team-wide append log (`team.zig:73-96`); no `to`, no per-recipient inbox, no `*` broadcast, no auto-delivery into a turn. |
| swarm-tasks-09 | SendMessage structured protocol (shutdown / plan approval) | medium | L | ABSENT. Plain-text only; no message `type`, no discriminated union, no validation, no shutdown/plan handshake. |
| swarm-tasks-10 | Addressable named agents + auto-resume + queued messages | medium | L | ABSENT. Background agents tracked only by task_id (`agent_runtime.zig:2999+`); no name registry, no `queuePendingMessage`, no resume-from-transcript. |
| swarm-tasks-11 | Agent worktree / cwd isolation on spawn | low | L | ABSENT for spawn. EnterWorktree/ExitWorktree are manual tools (`tool_schemas.zig:323`); AgentRunConfig has no isolation/cwd; spawn passes parent cwd verbatim. |
| swarm-tasks-12 | Rich agent frontmatter (mcpServers/hooks/skills/effort/permissionMode/maxTurns/memory) | medium | L | PARTIAL. AgentSpec has name/description/system_prompt/model/mode/tools (`agents.zig:23-42`); missing mcpServers, hooks, skills-preload, disallowedTools, effort, permissionMode, maxTurns, memory. |
| swarm-tasks-13 | In-process teammate lifecycle (idle/active, plan approval, pending queue, transcript) | medium | L | PARTIAL. One-shot background threads only; no idle/active state, no message injection, no capped transcript, no abort-on-shutdown, no `name@team` identity. |
| swarm-tasks-15 | TaskCreated hooks (blocking gate) + SDK task events | low | M | PARTIAL. `task_created`/`task_completed` events defined + blocking-capable (`hook_event.zig:24,93`) but `toEngineEvent` does not route them (`hooks.zig:194-199`); create has no hook gate; stop emits no SDK event. |
| swarm-tasks-16 | Handoff safety classifier on sub-agent completion | low | M | ABSENT. `spawnChildAgent` output returned verbatim; no `classifyHandoffIfNeeded`, no TRANSCRIPT_CLASSIFIER, no SECURITY WARNING prepend. |
| swarm-tasks-17 | Background-agent summarization (periodic progress summaries) | low | M | ABSENT. Background agents only update status at start/finish; no rolling summary, no forked summary conversation. |
| tools-14 | AgentRun lacks isolation/team_name/name/cwd/mode fields | low | M | PARTIAL. prompt/agent/model/max_rounds/run_in_background present (`agent.zig:9-19`); missing name/team_name/mode/isolation/cwd/description. |
| remote-server-01 | Coordinator mode (env-gated persona + worker-tools context + resume reconcile) | medium | M | ABSENT. Conditional in-prompt orchestration hint exists (`prompt_engine.zig:589-645`); no env gate, no persona swap, no worker-tools block, no resume mode reconciliation. |
| remote-server-02 | Direct-connect server (POST /sessions + WS stdout stream) | medium | L | ABSENT. Daemon serves only static routes (`remote_daemon.zig`); no /sessions, no WS session stream, no permission/interrupt control. |
| remote-server-03 | Server-side session index persisted for resume | low | M | ABSENT. Daemon State has pid/port/token/started_ts only; no per-session metadata, lifecycle, idle timeout, or max-sessions. |
| remote-server-04 | WS-client transport with auto-reconnect/backoff + ping keepalive | low | M | PARTIAL. WS client + RFC 6455 framing + backoff module exist but unwired (`mcp/client.zig:1389,1799-1819`, `core/backoff.zig`); no 30s ping loop, no reconnect driver, no 4001/4003 handling. |

## Implementation tasks

The ordering constraint: **Task 1 (the task-store JSON migration) must land
before tasks 2-6 and 15**, because they all add fields or behaviors to the task
record and the current line-based `key=value` format cannot represent arrays
(`blocks`/`blockedBy`) or a nested `metadata` object. Tasks 7-14 (teams/messaging)
depend on Task 1. Tasks 15-20 (agent spawn surface) are independent of teams
except SendMessage routing. Tasks 21-26 (remote/coordinator) are independent.

Within each independent sub-system the leaf modules are written first (pure,
unit-testable), then the wiring.

---

### Task 1: Migrate the task record to a JSON document with array + metadata support

**Goal.** Replace the flat `key=value` task file with a JSON document so the
record can carry `blocks: []`, `blockedBy: []`, `active_form`, and a free-form
`metadata` object, and so future fields are additive without reparse churn.

**Reference behavior + file:line.** `src/utils/tasks.ts:76-89` - `TaskSchema`
is a JSON object with `id`, `subject`, `description`, `activeForm?`, `owner?`,
`status`, `blocks: string[]`, `blockedBy: string[]`, `metadata?: Record<string,
unknown>`. Tasks are persisted as `jsonStringify(task, null, 2)`
(`tasks.ts:300`).

**Target Zig files.**
- Edit `src/tools/task.zig`: extend `TaskRecord`/`TaskSnapshot` with
  `blocks: [][]u8`, `blocked_by: [][]u8`, `active_form: []u8`,
  `metadata_json: []u8` (store metadata as a raw JSON object string so we do not
  need a dynamic value tree). Rewrite `writeTaskRecord`/`readTaskRecord` to emit
  and parse JSON via `std.json`, keeping the existing scalar fields. Keep
  `formatTaskRecord` (model-facing text) but add the new fields.
- Keep the atomic write (`writeTaskRecordAtomic`) and the `.task` extension; only
  the file *contents* change to JSON.

**Approach.**
1. Add the four new fields to `TaskRecord.init`/`deinit` and `TaskSnapshot`.
2. In `writeTaskRecord`, build the JSON with `std.json.Stringify` (or an
   `std_io.StringBuilder` writing the object by hand) - id/title/summary/status/
   output/owner/command/priority/active_form as strings, blocks/blocked_by as
   string arrays, metadata as a raw nested object (re-serialize the stored
   `metadata_json` if non-empty, else `{}`), numeric fields as numbers.
3. In `readTaskRecord`, parse with `std.json.parseFromSlice(std.json.Value, ...)`.
   On the **take-the-object-by-pointer** rule (CLAUDE.md): after parse, read via
   `parsed.value.object.get(...)`; do NOT copy the object out. For
   back-compat, if the file does not begin with `{` (legacy `key=value`), fall
   through to the old line parser so existing `.task` files still load.
4. Free `blocks`/`blocked_by` element slices and the arrays in `deinit`.

**Acceptance criteria.**
- Write a test that creates a record with two `blocks` ids, two `blocked_by`
  ids, an `active_form`, and a `metadata_json` of `{"k":"v"}`, writes it, reads
  it back, and asserts every field round-trips.
- Write a test that feeds a legacy `key=value` blob to `readTaskRecord` and
  asserts the scalar fields still parse (and the arrays come back empty).

**Test strategy.** Unit tests in `task.zig` under `tools/test_runner.zig`. The
existing `sortTaskSnapshots` and `taskPathAlloc` tests must still pass.

**Risk / footguns.** ObjectMap pointer desync after parse (CLAUDE.md: take
`&parsed.value.object` by pointer, do not value-copy). `readFileAlloc(.limited(N))`
returns `error.StreamTooLong` not `error.FileTooBig`. Round-trip the metadata as
an opaque JSON string to avoid building a recursive value-clone helper.

**Size.** M.

---

### Task 2: blocks/blockedBy graph wiring + cascade cleanup (swarm-tasks-01)

**Goal.** Wire a dependency edge from both sides, gate claims on incomplete
blockers, and strip a deleted task's id from every other task's edges.

**Reference behavior + file:line.** `tasks.ts:458-486` `blockTask` (updates
`from.blocks` and `to.blockedBy`); `tasks.ts:584-594` claim-time blocked check
(blockers that are not `completed` reject with `reason:'blocked'`,
`blockedByTasks`); `tasks.ts:420-434` cascade cleanup in `deleteTask`.

**Target Zig files.**
- Edit `src/tools/task.zig`: add `pub fn blockTask(allocator, cwd, from_id,
  to_id) ![]u8`, a `taskDelete(allocator, cwd, id)` that performs the cascade,
  and a helper `unresolvedBlockers(allocator, cwd, rec) ![][]u8` used by the
  claim path (Task 3).
- Edit `src/tools/tool_schemas.zig`: add `blocks`/`blocked_by` to the `TaskUpdate`
  schema (line 222) and document in the `TaskCreate` description that deps are
  set via `TaskUpdate`.
- Edit `src/tools/tool_dispatch.zig`: extend `taskUpdate` (line 580) to accept
  `add_blocks`/`add_blocked_by` (comma-separated ids) and call `blockTask`.

**Approach.**
1. `blockTask`: load both records; if `to_id` not in `from.blocks`, append; if
   `from_id` not in `to.blocked_by`, append; write both atomically.
2. Cascade in `taskDelete`: after unlinking the file, iterate `listTaskSnapshots`,
   and for any task whose `blocks`/`blocked_by` contains the deleted id, rewrite
   that task with the id filtered out.
3. Dispatch: parse comma-separated `add_blocks`/`add_blocked_by` and call
   `blockTask` for each pair before writing scalar updates.

**Acceptance criteria.**
- Test: create A and B, `blockTask(A, B)`, assert `A.blocks == [B]` and
  `B.blocked_by == [A]` and that re-calling is idempotent.
- Test: A blocks B; delete A; assert B.blocked_by is now empty.

**Test strategy.** Unit tests in `task.zig` using `tmpDirCwd` for a real
absolute workspace path (CLAUDE.md: never pass `"."`).

**Risk / footguns.** Idempotency on repeated blockTask. Cascade must tolerate
records that fail to parse (skip, do not abort the whole delete).

**Size.** M.

---

### Task 3: Atomic claim flow with owner conflict + busy check (swarm-tasks-02)

**Goal.** Add `claimTask` that atomically assigns `owner`, refuses if owned by a
different agent, refuses if blocked, plus a busy-check variant and the
`getAgentStatuses` / `unassignTeammateTasks` queries.

**Reference behavior + file:line.** `tasks.ts:541-612` `claimTask` (existence
check, owner-conflict, already-resolved, blocked check, then set owner);
`tasks.ts:618-692` `claimTaskWithBusyCheck` (list-level lock, agent-busy check);
`tasks.ts:763-798` `getAgentStatuses`; `tasks.ts:818-860` `unassignTeammateTasks`.

**Target Zig files.**
- Edit `src/tools/task.zig`: add a `ClaimResult` enum/struct
  (`{ ok, task_not_found, already_claimed, already_resolved, blocked, agent_busy }`
  with optional `blocked_by`/`busy_with` lists), `pub fn claimTask(allocator,
  cwd, id, claimant, check_busy) !ClaimResult`, `pub fn getAgentStatuses`, and
  `pub fn unassignTeammateTasks`.
- Edit `src/tools/tool_dispatch.zig`: route a `TaskClaim` action (or
  `action=claim` on the generic `Task` tool at `tool_schemas.zig:204`) and let
  `taskUpdate` pass `owner` through (currently dropped at line 580-590).
- Edit `src/tools/tool_schemas.zig`: add `owner` to the `TaskUpdate` schema and a
  `TaskClaim` schema (`{id, owner, check_busy?}`).

**Approach.**
1. Serialize claim with a per-workspace lock file under the task dir (create a
   `.lock` sentinel; use `O_CREAT|O_EXCL` retry loop with bounded backoff via
   `core/backoff.zig` - mirror the reference's `LOCK_OPTIONS` retry budget).
2. `claimTask` under the lock: read record; if `owner` set and `!= claimant` ->
   `already_claimed`; if status `done`/`completed` -> `already_resolved`; compute
   unresolved blockers -> `blocked`; if `check_busy` and the claimant already
   owns another non-done task -> `agent_busy`; else set `owner = claimant`,
   write, return `ok`.
3. `getAgentStatuses(team)`: read structured members (Task 8), bucket unresolved
   tasks by owner, mark each member idle/busy.
4. `unassignTeammateTasks(team, id, name, reason)`: clear `owner` and reset
   status to `pending`/`open` for every unresolved task owned by id-or-name;
   return a notification string.

**Acceptance criteria.**
- Test: claim by agent-a succeeds; second claim by agent-b returns
  `already_claimed`.
- Test: B blocked by open A -> claim B returns `blocked` with `[A]`.
- Test: agent-a owns open T1; `claimTask(T2, agent-a, check_busy=true)` returns
  `agent_busy` with `[T1]`.
- Test: `unassignTeammateTasks` clears owner and resets status.

**Test strategy.** Unit tests in `task.zig`. Concurrency is hard to unit-test in
Zig deterministically; assert the *single-threaded* state-machine outcomes and
rely on the lock file for cross-process safety (documented, not unit-tested).

**Risk / footguns.** The lock file is the only TOCTOU defense; the reference
uses `proper-lockfile`. Use `O_EXCL` create + retry, and always release (errdefer
unlink). `kill -0` style probes are not needed here. Do not call `wait()` after
any process op (no child involved here).

**Size.** M.

---

### Task 4: activeForm + metadata on TaskCreate (swarm-tasks-03, swarm-tasks-04)

**Goal.** Accept and persist `active_form` (present-continuous label) and
`metadata` (raw JSON object) at create time.

**Reference behavior + file:line.** `TaskCreateTool.ts:22-31` (`activeForm`,
`metadata` input); `tasks.ts:81,86` (schema). `activeForm` falls back to subject
when omitted.

**Target Zig files.**
- Edit `src/tools/task.zig`: extend `taskCreateWithOptions` signature with
  `active_form: []const u8` and `metadata_json: []const u8`.
- Edit `src/tools/tool_dispatch.zig`: in `taskCreate` (line 565) extract
  `activeForm`/`active_form` and `metadata` and pass through.
- Edit `src/tools/tool_schemas.zig`: add `activeForm` and `metadata` to the
  `TaskCreate` JSON schema (line 211).

**Approach.** Fields already exist on the record after Task 1; just thread them
through create and dispatch. Default `active_form` to `title` when empty.
Validate `metadata` is a JSON object (parse, reject non-object) before storing
the raw string.

**Acceptance criteria.**
- Test: create with `active_form="Running tests"` -> read back equal.
- Test: create with empty `active_form` -> stored equals `title`.
- Test: create with `metadata={"pr":42}` -> round-trips; create with
  `metadata=[1,2]` (array) is rejected.

**Test strategy.** Unit tests in `task.zig`.

**Risk / footguns.** Keep metadata opaque (raw JSON string) - do not deep-clone a
value tree.

**Size.** S (rides on Task 1).

---

### Task 5: Team = task-list binding (per-team dir, fresh numbering, leader bind) (swarm-tasks-05)

**Goal.** Scope a team's tasks to a per-team directory that renumbers from 1, and
bind the leader so its task ops resolve to that directory.

**Reference behavior + file:line.** `TeamCreateTool.ts:182-191`
(`resetTaskList`, `ensureTasksDir`, `setLeaderTeamName`); `tasks.ts:147-188`
`resetTaskList` (high-water-mark file, delete `.json` files); `tasks.ts:199-210`
`getTaskListId` (env -> teammate ctx -> team name -> session id).

**Target Zig files.**
- Create `src/core/task_list_id.zig` (deep, pure-ish): resolves the active task
  list id from `ZCODE_TASK_LIST_ID` env -> a process-global leader team name ->
  fallback `"tasklist"`. Holds `var leader_team_name: ?[]const u8` with
  `setLeaderTeamName`/`clearLeaderTeamName` (mirrors `tasks.ts:25-47`). Register
  in `src/main.zig` comptime block.
- Edit `src/tools/helpers.zig`: change `TASKS_SUBPATH` resolution to append the
  sanitized task-list id (`state/tasks/<listid>`); add
  `tasksDirForList(allocator, cwd, list_id)`.
- Edit `src/tools/task.zig`: route all task paths through the resolved list dir
  (`taskPathAlloc`, `taskCreate*`, `taskList`, `listTaskSnapshots`).
- Edit `src/tools/team.zig`: on `teamCreate`, create the per-team task dir,
  reset it (delete `.task` files, bump a `.highwatermark`), and call
  `setLeaderTeamName(sanitized)`.

**Approach.**
1. Add a `.highwatermark` integer file per list dir; the create path reads
   `max(files, hwm) + 1` for numbering (the reference numbers from 1; our ids are
   currently `task-<ts>-<hex>` - switch the *per-list* id to a monotonic integer
   to match `getTaskPath(listId, id)` numbering, keeping the `.task` extension).
2. `resetTaskList`: record the current max into `.highwatermark`, then delete the
   `.task` files.
3. Resolve the list id once per task op from `core/task_list_id.zig`.

**Acceptance criteria.**
- Test: create team "alpha" -> a `state/tasks/alpha` dir exists, task numbering
  starts at 1.
- Test: create task in team "alpha", delete the team's tasks via reset, create
  again -> new id is greater than the deleted one (hwm prevents reuse).
- Test: with no team, the list id resolves to `"tasklist"`.

**Test strategy.** Unit tests in `task.zig`/`team.zig` + `task_list_id.zig` with
`tmpDirCwd`.

**Risk / footguns.** Switching from `task-<ts>-<hex>` ids to monotonic integers
changes the id surface the model sees - keep `taskGet`/`taskPoll` accepting both
forms during transition. `isSafeIdentifier` must still gate the team name used as
a directory component (path-traversal). The process-global `leader_team_name`
needs a mutex if touched from background threads.

**Size.** M.

---

### Task 6: Structured team membership records (swarm-tasks-06)

**Goal.** Persist a structured `members[]` (agentId, name, agentType, model,
joinedAt, tmuxPaneId, backendType, cwd, subscriptions) in the team file, seed the
leader as `team-lead`, and read it back for peer discovery.

**Reference behavior + file:line.** `TeamCreateTool.ts:157-175` (`TeamFile`
members); `swarm/backends/types.ts:191-225` (TeammateIdentity/SpawnConfig). The
reference team file is `config.json` under `getTeamsDir()/<sanitized>/`.

**Target Zig files.**
- Edit `src/tools/team.zig`: change the `.team` file from `key=value` to a JSON
  document `{ name, description?, created_ts, lead_agent_id, lead_session_id,
  members: [ { agent_id, name, agent_type, model, joined_ts, tmux_pane_id,
  backend_type, cwd, subscriptions: [] } ] }`. Add `readTeamFile`/`writeTeamFile`
  and an `addMember`/`findMemberByName` helper.
- Edit `src/repl_commands.zig`: update `parseTeamMetadata` (line 3655) and
  `TeamOverlayItem` (line 3641) to parse the JSON member list and render
  per-member rows instead of one opaque blob.

**Approach.** Seed the leader member at create with `name="team-lead"`,
`agent_type=` the provided type-or-default, `model=` the session model,
`cwd=` the workspace, empty `subscriptions`. Back-compat: if the file does not
parse as JSON, fall through to the legacy `key=value` reader so old `.team`
files still render.

**Acceptance criteria.**
- Test: create a team -> read back -> exactly one member named `team-lead` with
  the workspace cwd.
- Test: `findMemberByName("team-lead")` returns the seeded member; unknown name
  returns null.
- Test: legacy `key=value` team file still parses (members empty list).

**Test strategy.** Unit tests in `team.zig`.

**Risk / footguns.** ObjectMap pointer rule again. Keep `subscriptions` as a
string array. The repl overlay must tolerate zero members.

**Size.** M.

---

### Task 7: One-team-per-leader + unique-name fallback + session cleanup (swarm-tasks-07)

**Goal.** Refuse a second team for the same leader, auto-generate a word-slug
name when the requested one exists, and register the team for end-of-session
cleanup.

**Reference behavior + file:line.** `TeamCreateTool.ts:132-143`
(existing-team throw + `generateUniqueTeamName`); `:64-72` `generateUniqueTeamName`
(falls back to `generateWordSlug`); `:180` `registerTeamForSessionCleanup`.

**Target Zig files.**
- Edit `src/tools/team.zig`: in `teamCreate`, if a leader team is already bound
  (consult `core/task_list_id.zig`), return an error string; if the requested
  team file exists, generate a unique name via `core/word_slug.zig`
  (`generateShortSlugAlloc`, already used for plan names) instead of erroring.
- Edit `src/tools/team.zig` (and a small registry in `core/task_list_id.zig` or a
  new `src/core/team_cleanup.zig`): record created team names in a
  process-global list; expose `cleanupRegisteredTeams(cwd)` called from the
  session-end path.
- Edit the session-end path (where sessions are finalized, e.g. session/store
  cleanup or `repl_session.zig` shutdown) to call `cleanupRegisteredTeams`.

**Approach.** Mirror the reference: leader binding lives in the same global as
`leader_team_name` (Task 5). Unique-name generation loops until a free `.team`
path is found. Cleanup deletes both the `.team` file and the per-team task dir
(unless the user persisted it - match reference behavior: it cleans
session-created teams).

**Acceptance criteria.**
- Test: bind leader to "alpha"; second `teamCreate("beta")` returns the
  already-leading error.
- Test: create "alpha" twice (clear leader between) -> second call returns a
  different, valid word-slug name, both files exist.
- Test: `cleanupRegisteredTeams` removes the `.team` file and the task dir.

**Test strategy.** Unit tests in `team.zig`.

**Risk / footguns.** Word-slug collision loop must bound its retries. Session
cleanup must not delete a team the user explicitly created and wants kept -
match the reference which only auto-cleans session-registered teams.

**Size.** M.

---

### Task 8: Per-teammate inbox + broadcast + SendMessage `to` routing (swarm-tasks-08)

**Goal.** Route SendMessage to a named teammate's inbox file, support `*`
broadcast to all members, and replace the single team-wide log with per-recipient
mailboxes.

**Reference behavior + file:line.** `SendMessageTool.ts:149-189` `handleMessage`
(`writeToMailbox`); `:191-266` `handleBroadcast` (write to every member except
self). The mailbox abstraction is `utils/teammateMailbox.ts`.

**Target Zig files.**
- Create `src/tools/teammate_mailbox.zig` (new tools module): `writeToMailbox(
  allocator, cwd, team, recipient, from, text, summary)` appends a JSON line to
  `state/messages/<team>/<recipient>.inbox`; `readMailbox`/`drainMailbox` read
  and (optionally) truncate. Use `O_APPEND` open like `team.zig:98-112`.
- Edit `src/tools/team.zig`: rewrite `sendMessage` to take `to` and route:
  `*` -> broadcast to every structured member except sender; bare name -> single
  mailbox. Keep a legacy team-wide log append for back-compat observability.
- Edit `src/tools/tool_schemas.zig`: add `to` and `summary` to the `SendMessage`
  schema (line 288); keep `from`/`message`.
- Edit `src/tools/tool_dispatch.zig`: `handleSendMessage` (line 661) extracts
  `to`/`summary` and dispatches to the new routing.

**Approach.** Broadcast reads the structured member list (Task 6), skips the
sender (case-insensitive name compare, mirroring `:222`), and writes each inbox.
Auto-delivery (draining an inbox into a running/idle teammate's turn) is wired in
Task 13; this task lands the storage + addressing.

**Acceptance criteria.**
- Test: `sendMessage(to="bob")` writes `state/messages/<team>/bob.inbox` with one
  record; `readMailbox("bob")` returns it.
- Test: `to="*"` with members alice/bob/team-lead and sender team-lead writes to
  alice and bob only, not team-lead.

**Test strategy.** Unit tests in `teammate_mailbox.zig` + `team.zig`. Register
`teammate_mailbox.zig` in `src/main.zig` comptime block.

**Risk / footguns.** `O_APPEND` to serialize concurrent writers (the existing
`openAppendFile` pattern). Inbox path must be `isSafeIdentifier`-gated on team
and recipient. Use the append open, never seek (CLAUDE.md: 0.16 has no seek).

**Size.** L.

---

### Task 9: Structured message protocol (shutdown / plan approval) (swarm-tasks-09)

**Goal.** Accept a structured (JSON object) message with a `type` discriminant -
`shutdown_request`, `shutdown_response`, `plan_approval_response` - validate per
the reference rules, and write the appropriate mailbox record / trigger.

**Reference behavior + file:line.** `SendMessageTool.ts:46-65` StructuredMessage
union; `:268-432` shutdown handlers; `:434-518` plan approval/rejection; `:694-715`
validation (shutdown_response only to team-lead, reason required on reject, no
broadcast of structured messages).

**Target Zig files.**
- Create `src/core/swarm_message.zig` (deep, pure): parse a `message` value that
  is either a plain string or a JSON object; classify into a tagged union
  `SwarmMessage { plain, shutdown_request, shutdown_response, plan_approval }`;
  validate (`validate(self, to) -> ?[]const u8` returning an error string or
  null). Register in `src/main.zig` comptime block.
- Edit `src/tools/team.zig`: `sendMessage` calls `swarm_message.parse`; for
  structured messages, refuse broadcast, refuse cross-team, write a JSON mailbox
  record; for `shutdown_response.approve` to team-lead, signal the teammate's
  abort (Task 13); for `plan_approval_response`, write the approval record.
- Edit `src/tools/tool_dispatch.zig`: pass the raw `message` through unchanged so
  the parser can see JSON.

**Approach.** Keep the parser pure and fully unit-testable; the *side effects*
(abort, plan-mode flip) live in team.zig and Task 13. Mirror the validation
ordering in `:694-715` exactly.

**Acceptance criteria.**
- Test: parse `{"type":"shutdown_request","reason":"done"}` -> shutdown_request
  with reason.
- Test: `shutdown_response` with `to != "team-lead"` -> validation error string.
- Test: `shutdown_response` reject without reason -> validation error.
- Test: structured message with `to="*"` -> "cannot broadcast" error.
- Test: a plain string message classifies as `.plain`.

**Test strategy.** Unit tests in `swarm_message.zig` (pure) + an integration test
in `team.zig`.

**Risk / footguns.** Depends on Task 8 (mailboxes) and Task 13 (abort) for full
behavior; this task can land the parser + validation + storage even before the
abort wiring exists (the abort call becomes a no-op stub until Task 13).

**Size.** L.

---

### Task 10: Agent name registry + queued messages + resume-from-transcript (swarm-tasks-10)

**Goal.** Register a spawned agent by `name` so SendMessage(`to=name`) reaches it:
queue the message if running, or resume it from its transcript if stopped.

**Reference behavior + file:line.** `SendMessageTool.ts:800-873` (agentNameRegistry
lookup, `queuePendingMessage`, `resumeAgentBackground`); `resumeAgent.ts:42`
`resumeAgentBackground`.

**Target Zig files.**
- Edit `src/agent_runtime.zig`: add an `agent_name_registry`
  (`std.StringHashMap` mapping name -> task_id) guarded by a mutex, populated by
  `spawnBackgroundAgent` when `config.name` is set; add a `pending_messages`
  queue keyed by agent name; add `resumeAgentFromTranscript(name, prompt)` that
  loads the named agent's transcript (Phase 5 session store) and re-runs it in
  the background with `prompt` as the new turn.
- Edit `src/tools/team.zig` `sendMessage`: before team routing, look up `to` in
  the registry; if found and running -> `queuePendingMessage`; if found but
  finished -> resume; else fall through to mailbox routing.
- Edit `src/agent_runtime.zig` tool-round loop: at each tool-round boundary,
  drain pending messages for the current agent's name and inject them as a new
  user turn (the auto-delivery hook).

**Approach.** The registry and queue live on the parent `AgentRuntime` (the
swarm leader). Resume reuses the background-spawn machinery (Task: the
`BackgroundCtx` at `agent_runtime.zig:3024`) but seeds history from the transcript
before running `handlePrompt(prompt)`.

**Acceptance criteria.**
- Test: register name "worker" -> task_id "task-5"; lookup "worker" returns
  "task-5".
- Test: queue two messages for "worker"; drain returns both in order, queue empty
  after.
- Resume-from-transcript is integration-tested manually (needs a live model);
  unit-test the registry + queue mechanics only.

**Test strategy.** Extract the registry + queue into a small testable struct
(e.g. `src/core/agent_registry.zig`, registered in main comptime) and unit-test
it; wire it into `agent_runtime.zig`.

**Risk / footguns.** Thread safety: background threads and the main loop both
touch the registry/queue - guard with the existing
`background_threads_lock`-style mutex. Resume must respect `MAX_DEPTH`
(`agent.zig:6`).

**Size.** L.

---

### Task 11: Per-agent worktree / cwd isolation on spawn (swarm-tasks-11)

**Goal.** Let an AgentRun request `isolation:"worktree"` (create a temp git
worktree and run the agent there) or a `cwd` override (run in an arbitrary
absolute dir), mutually exclusive.

**Reference behavior + file:line.** `AgentTool.tsx:99-100` (isolation/cwd
schema); `:583-640` `createAgentWorktree`/`cwdOverridePath`; `forkSubagent.ts:205-210`
`buildWorktreeNotice`.

**Target Zig files.**
- Edit `src/tools/agent.zig`: add `isolation: ?[]const u8` and `cwd_override:
  ?[]const u8` to `AgentRunConfig` and parse them in `parseArgs` (line 22);
  reject if both set.
- Edit `src/agent_runtime.zig`: in `spawnChildAgent` (line 2378) and
  `spawnBackgroundAgent` (line 2999), when `isolation=="worktree"`, create a
  worktree via the existing EnterWorktree machinery (`tool_dispatch.zig:813`
  handler / the underlying worktree module) and set the child's cwd to it; when
  `cwd_override` is set, validate it is an existing absolute dir and use it;
  otherwise inherit `self.cwd`.
- Edit `src/tools/tool_schemas.zig`: add `isolation` and `cwd` to the `AgentRun`
  schema (line 313).

**Approach.** Reuse the EnterWorktree implementation (the rename of the worktree
tool) so we do not reinvent git worktree creation. Persist the worktree path on
the task record `metadata` (Task 4) so a resumed agent can re-enter it. Append a
"working in worktree <path>" notice to the child's opening context (mirror
`buildWorktreeNotice`).

**Acceptance criteria.**
- Test: parse `isolation=worktree` and `cwd=/abs/path` together -> error.
- Test: parse `cwd=/tmp/x` -> config.cwd_override set.
- Worktree creation is integration-tested (`zig build` + a manual `AgentRun` with
  isolation) since it shells out to git.

**Test strategy.** Unit-test `parseArgs` mutual-exclusion and field extraction;
manual integration test for the git worktree path.

**Risk / footguns.** Worktree cleanup on agent finish (avoid leaking worktrees).
`std.process.run` for git (one-shot) per CLAUDE.md; `Child.Cwd` is a union
(`.{ .path = ... }`). `remote` isolation is cloud - out of scope (see deferred).

**Size.** L.

---

### Task 12: Rich agent frontmatter (swarm-tasks-12)

**Goal.** Extend AgentSpec to carry `mcpServers`, `hooks`, `skills` (preload),
`disallowedTools`, `effort`, `permissionMode`, `maxTurns`, and `memory`, parsed
from the agent JSON and applied at spawn.

**Reference behavior + file:line.** `loadAgentsDir.ts:73-99` `AgentJsonSchema`
(tools/disallowedTools/prompt/model/effort/permissionMode/mcpServers/hooks/
maxTurns/skills/memory/background/isolation); `runAgent.ts:95-218`
`initializeAgentMcpServers`; `:557-646` hooks + skills preload.

**Target Zig files.**
- Edit `src/core/agents.zig`: add fields to `AgentSpec`
  (`disallowed_tools: [][]u8`, `skills: [][]u8`, `mcp_servers: [][]u8` (server
  names, plus an inline-config raw-JSON slot), `effort: []u8`,
  `permission_mode: []u8`, `max_turns: ?usize`, `memory: []u8`), update
  `loadFile` (line 357) to parse them, and `clone`/`deinit`.
- Edit `src/agent_runtime.zig`: at `activateAgentByName`, apply
  `effort`/`permission_mode`/`max_turns` overrides (effort + max_rounds already
  have session-level hooks at `agent_runtime.zig:269-280`), connect per-agent MCP
  servers at start and disconnect at end, register `hooks` as session-scoped
  SubagentStop hooks, and preload `skills` into the opening messages.

**Approach.** Land the *parsing + storage* first (fully unit-testable), then the
*application* hooks one field at a time. `disallowedTools` integrates with the
existing tool gating (`allowsTool` at `agents.zig:200`). `mcpServers` reuses the
Phase 6 MCP connect machinery. `memory` scope selects which CLAUDE.md/memory file
the agent loads.

**Acceptance criteria.**
- Test: an agent JSON with `disallowedTools`, `skills`, `effort`,
  `permissionMode`, `maxTurns`, `memory`, and `mcpServers` parses into a fully
  populated AgentSpec.
- Test: `allowsTool` returns false for a tool listed in `disallowedTools` even
  when `tools` is `*`.

**Test strategy.** Unit tests in `agents.zig` (parse + gating). MCP/hooks/skills
application is integration-tested.

**Risk / footguns.** Keep inline `mcpServers` config as raw JSON strings (do not
build a value tree). `effort` may be a string or an int in the reference - accept
both. Do not break the existing minimal-JSON agent files (all new fields
optional).

**Size.** L.

---

### Task 13: In-process teammate lifecycle (swarm-tasks-13)

**Goal.** Run a teammate in-process with an idle/active state machine, a pending
message queue with injection, a capped conversation transcript, a `name@team`
identity, and abort-on-shutdown.

**Reference behavior + file:line.** `InProcessTeammateTask.tsx:1-100`
(`requestTeammateShutdown`, `appendTeammateMessage`, `injectUserMessageToTeammate`,
`findTeammateTaskByAgentId`); `swarm/backends/types.ts:279-300` TeammateExecutor
(spawn/sendMessage/terminate/kill/isActive).

**Target Zig files.**
- Create `src/core/teammate.zig` (deep): a `Teammate` struct holding
  `{ name, team, state: enum{idle,active}, pending: queue, transcript: capped
  ring, abort: atomic flag }` with `appendMessage`, `injectUserMessage`,
  `requestShutdown` (sets abort), `isActive`. Register in `src/main.zig` comptime.
- Edit `src/agent_runtime.zig`: have `spawnBackgroundAgent` create a `Teammate`
  entry instead of a bare thread; the run loop sets state active during
  `handlePrompt`, drains the pending queue between rounds, appends to the capped
  transcript, and checks the abort flag at round boundaries (graceful stop).
- Edit `src/tools/team.zig`: `shutdown_response.approve` (Task 9) calls
  `requestShutdown` on the matching teammate.

**Approach.** Build the state machine + queue + capped transcript as a standalone
testable struct; the runtime consumes it. `name@team` identity formats the
teammate's `owner`/`from` strings. The abort flag is an `std.atomic.Value(bool)`
checked between tool rounds (no hard kill mid-round).

**Acceptance criteria.**
- Test: new Teammate starts idle; `injectUserMessage` enqueues; `drain` empties;
  state transitions idle->active->idle.
- Test: capped transcript drops oldest beyond the cap.
- Test: `requestShutdown` sets `isActive`-observable abort; the run loop's
  "should-stop" predicate returns true.

**Test strategy.** Unit tests in `teammate.zig` (pure state machine). The full
in-process run is integration-tested.

**Risk / footguns.** Concurrency between the injecting thread (SendMessage) and
the consuming run loop - the queue must be mutex-guarded. Abort must be checked
at a safe point (round boundary), never mid-tool, to avoid leaking child
processes (CLAUDE.md: do not `wait()` after kill).

**Size.** L.

---

### Task 14: TaskCreated blocking-hook gate + SDK task events (swarm-tasks-15)

**Goal.** Run `TaskCreated` hooks on create and delete the task if a hook returns
a blocking error; emit a structured task-termination event on stop.

**Reference behavior + file:line.** `TaskCreateTool.ts:92-113`
(`executeTaskCreatedHooks`, `deleteTask` on blockingError); `stopTask.ts:70-95`
`emitTaskTerminatedSdk` + exit-137 suppression for shell tasks.

**Target Zig files.**
- Edit `src/core/hooks.zig`: extend `toEngineEvent` (line 194) and the public hook
  entry to support `task_created`/`task_completed` (the event enum already exists
  at `hook_event.zig:24`). Add a `runTaskCreatedHook(allocator, cwd, task)` that
  returns a `{ blocked, message }` result using the existing blocking-capable
  disposition (`hook_event.interpretExit` returns `.block` for `task_created`).
- Edit `src/tools/task.zig`: `taskCreateWithOptions` calls the hook after writing;
  on `blocked`, delete the just-created task and return the hook message.
  `taskStop`/`refreshTaskRuntimeState` emit a task-termination notification with a
  structured shape and suppress exit-137 noise for shell-backed tasks.

**Approach.** Reuse the existing hook IO/contract (`hook_io.zig`, `hook_config.zig`).
The create-then-maybe-delete ordering matches the reference (the hook sees the
fully-formed task). Exit-137 suppression: when a shell task's exit file holds 137
(SIGKILL), do not surface a failure notification.

**Acceptance criteria.**
- Test: a configured `TaskCreated` hook that exits 2 -> create returns the block
  message and the `.task` file is absent afterward.
- Test: a `TaskCreated` hook that exits 0 -> task persists.
- Test: stop a task whose exit code is 137 -> no "failed" notification line is
  appended (suppressed), but the task is marked stopped.

**Test strategy.** Unit tests in `task.zig` using a tiny shell hook script written
into the tmp workspace; run under `tools/test_runner.zig`.

**Risk / footguns.** Hook stdin is delivered via temp-file redirect (existing
pattern in `hooks.zig`) to avoid pipe deadlocks. Deleting the task on block must
also run the cascade (Task 2). `interpretExit` already encodes the blocking
contract - do not re-derive it.

**Size.** M.

---

### Task 15: Add multi-agent fields to AgentRun input (tools-14)

**Goal.** Extend the AgentRun tool schema and `AgentRunConfig` with
`name`, `team_name`, `mode`, and `description` (isolation/cwd land in Task 11).

**Reference behavior + file:line.** `AgentTool.tsx:82-105` (baseInputSchema +
multiAgentInputSchema): description (3-5 words), subagent_type, model,
run_in_background, name/team_name/mode/isolation/cwd.

**Target Zig files.**
- Edit `src/tools/agent.zig`: add `name`, `team_name`, `mode`, `description` to
  `AgentRunConfig` and parse them in `parseArgs` (line 22). `name` is the
  team-addressable name distinct from `agent` (the specialist type).
- Edit `src/tools/tool_schemas.zig`: add these properties to the `AgentRun` schema
  (line 313) with descriptions.
- Edit `src/agent_runtime.zig`: pass `name` into the registry (Task 10),
  `team_name` into the teammate binding (Task 13), and `mode` into the child's
  session mode.

**Approach.** Thin pass-through; the heavy lifting is Tasks 10/11/13. Keep
`agent` as the specialist-type field and `name` as the registry key (mirroring
the reference distinction). `mode` maps to the existing `AgentMode`
(`agents.zig:15`).

**Acceptance criteria.**
- Test: `parseArgs("prompt=x,name=worker,team_name=alpha,mode=planning,
  description=fix auth")` populates all fields.
- Test: omitting the new fields leaves them null (back-compat).

**Test strategy.** Unit tests in `agent.zig` `parseArgs`.

**Risk / footguns.** Do not conflate `agent` and `name`. `mode` parsing should
reuse `agents.parseMode` semantics.

**Size.** M (S if Tasks 10/11/13 absorb the wiring).

---

### Task 16: Handoff safety classifier on sub-agent completion (swarm-tasks-16)

**Goal.** When a transcript classifier is enabled and the mode is auto, classify a
completed sub-agent's output and prepend a SECURITY WARNING if flagged.

**Reference behavior + file:line.** `agentToolUtils.ts:389-481`
`classifyHandoffIfNeeded`; `runAsyncAgentLifecycle:607-620`.

**Target Zig files.**
- Create `src/core/handoff_classifier.zig` (deep, pure): given the sub-agent
  output and a "classifier enabled + auto mode" gate, return an optional
  SECURITY-WARNING prefix string. The actual classification is a hook/LLM call;
  the pure module decides *whether* to classify and *how to render* the warning.
  Register in `src/main.zig` comptime.
- Edit `src/agent_runtime.zig`: in `spawnChildAgent` (output assembly near line
  2443), after the existing metadata enrichment, call the classifier gate and
  prepend the warning when flagged.
- Edit `src/core/config.zig`: add a `TRANSCRIPT_CLASSIFIER`-style flag (env or
  config) so the gate can be turned on.

**Approach.** Keep the classifier *decision logic* pure and testable; gate it
behind the config flag + auto/yolo mode so it is off by default (matching the
reference which only runs it for `mode==auto`). The classification verdict itself
can route through the existing post-tool hook or a lightweight LLM check - land
the gate + rendering first.

**Acceptance criteria.**
- Test: gate off -> output returned unchanged.
- Test: gate on + flagged verdict -> output prefixed with the SECURITY WARNING.
- Test: gate on + clean verdict -> output unchanged.

**Test strategy.** Unit tests in `handoff_classifier.zig`.

**Risk / footguns.** This ties into the permissions/auto-mode classifier
subsystem; keep it self-contained and default-off so it does not regress the
common path. Low priority - may be deferred behind the auto-mode work.

**Size.** M.

---

### Task 17: Background-agent rolling summarization (swarm-tasks-17)

**Goal.** Produce periodic progress summaries for a running background agent and
surface them to the parent (via the task record / notification).

**Reference behavior + file:line.** `agentToolUtils.ts:508-595`
`runAsyncAgentLifecycle` (`startAgentSummarization`, `onCacheSafeParams`).

**Target Zig files.**
- Edit `src/agent_runtime.zig` `BackgroundCtx.run` (line 3024): at a cadence
  (every N tool rounds or T seconds), fork a lightweight summary turn over the
  agent's history-so-far and write the summary into the task record's `summary`
  field (or `progress` notification) via `task.taskUpdate`.
- Optionally add a `src/core/summary_cadence.zig` pure helper deciding *when* to
  summarize (round/time thresholds), register in main comptime.

**Approach.** The cadence decision is pure + testable; the summary generation
reuses the agent's own model with a "summarize progress in <=N words" prompt over
the current history snapshot. Write the result to the task `summary` so existing
TaskPoll/TaskOutput surface it.

**Acceptance criteria.**
- Test: `summary_cadence.shouldSummarize(rounds, last_summary_round, elapsed)`
  fires at the threshold and not before.
- Rolling summary content is integration-tested (needs a live model).

**Test strategy.** Unit-test the cadence helper; manual integration for the
summary content.

**Risk / footguns.** Do not block the agent's main work to summarize; the summary
fork must be cheap and best-effort (failures are silent). Each summary turn costs
an API call - keep the cadence conservative.

**Size.** M.

---

### Task 18: Coordinator mode (remote-server-01)

**Goal.** Add an env-gated coordinator mode that swaps in the coordinator system
prompt, injects a worker-tools context block, and reconciles mode on `--resume`.

**Reference behavior + file:line.** `coordinatorMode.ts:36` `isCoordinatorMode`
(reads `CLAUDE_CODE_COORDINATOR_MODE`); `:49` `matchSessionMode` (flip env on
resume + warning); `:80` `getCoordinatorUserContext` (worker tools + scratchpad);
`:111` `getCoordinatorSystemPrompt`.

**Target Zig files.**
- Create `src/core/coordinator_mode.zig` (deep): `isCoordinatorMode()` reads the
  env var; `coordinatorSystemPrompt()` returns the full multi-section persona
  (port the reference text, replacing tool names with zcode's: AgentRun /
  SendMessage / TaskStop); `coordinatorUserContext(worker_tools, scratchpad_dir)`
  builds the worker-tools block; `matchSessionMode(stored)` flips the env and
  returns an optional warning string. Register in `src/main.zig` comptime.
- Edit `src/core/system_prompt.zig` / `core/prompt_helpers.zig`: when
  `isCoordinatorMode()`, swap the base system prompt for the coordinator persona
  and append the worker-tools user context.
- Edit the session resume path (`session_cmds.zig:83-156`) to persist the mode in
  the session record and call `matchSessionMode` on resume, surfacing the warning.

**Approach.** Port the reference prompt verbatim (it is plain text - replace tool
names and strip any em/en dashes per the no-long-dashes rule). The worker-tools
list comes from the async-agent allowed-tools set minus internal worker tools
(mirror `INTERNAL_WORKER_TOOLS` at `coordinatorMode.ts:29-34`).

**Acceptance criteria.**
- Test: with the env var unset, `isCoordinatorMode()` is false and the base prompt
  is used.
- Test: with it set, the coordinator persona string is returned and contains the
  "every message you send is to the user" line.
- Test: `matchSessionMode("coordinator")` when current is normal flips the env and
  returns the "Entered coordinator mode" warning; matching modes return null.

**Test strategy.** Unit tests in `coordinator_mode.zig`.

**Risk / footguns.** Keep the persona text dash-free (CLAUDE.md). The resume
reconciliation must persist the mode in the session record (Phase 5 store) - add a
`coordinator` flag to the session entry.

**Size.** M.

---

### Task 19: Direct-connect server (remote-server-02)

**Goal.** Add a `POST /sessions` endpoint that creates a session and returns
`{session_id, ws_url, work_dir}`, then streams SDK-style messages over a WebSocket
with permission-control and interrupt handling.

**Reference behavior + file:line.** `createDirectConnectSession.ts:26`
(POST /sessions); `directConnectManager.ts:50` (WS connect), `:125`
(sendMessage stream-json), `:172` (sendInterrupt); `server/types.ts:13`
ServerConfig.

**Target Zig files.**
- Edit `src/remote_daemon.zig`: in `handleRequest` (line 312), add a `POST
  /sessions` route that parses `{cwd, dangerously_skip_permissions}`, allocates a
  session id, registers it (Task 20), and returns the JSON contract. Add a WS
  upgrade route `GET /sessions/<id>/stream` using the existing RFC 6455 framing
  (`src/mcp/websocket.zig` supports server mode) that runs an `AgentRuntime` for
  that session and streams newline-delimited SDK messages (assistant/result/
  system), handles inbound `control_request`/`user` frames, and supports
  interrupt.
- Create `src/core/sdk_message.zig` (deep): the SDK message envelope
  (assistant/result/system/control_request/control_response/user) ser/de.
  Register in `src/main.zig` comptime.
- Add a `ServerConfig` struct (port/host/authToken/idleTimeoutMs/maxSessions/
  workspace) in `remote_daemon.zig`.

**Approach.** Reuse the daemon's existing bearer-token auth and the MCP WebSocket
frame primitives (server side). The session runs the normal agent loop but its
stdout is redirected into SDK message frames. Permission requests become
`control_request:can_use_tool` frames; the client replies with
`control_response`. This is a substantial integration; land the route + handshake
+ message envelope first, then the live agent streaming.

**Acceptance criteria.**
- Test: `POST /sessions` with a body -> a 200 JSON response containing
  `session_id`, `ws_url`, `work_dir` (route handler unit-testable with a mock
  request).
- Test: the SDK message envelope round-trips assistant/result/control frames
  (`sdk_message.zig`).
- Live WS streaming is integration-tested with a script connecting to the daemon.

**Test strategy.** Unit-test the route response shape and `sdk_message.zig`;
integration-test the WS stream end-to-end with a small client harness.

**Risk / footguns.** This is the largest task. The WS upgrade + framing reuse must
match the client expectations (newline-delimited JSON per frame, per
`directConnectManager.ts:64-67`). Do not block the daemon's other routes while a
session streams (per-connection worker threads already exist). Bearer-token must
gate `/sessions`.

**Size.** L.

---

### Task 20: Persisted server session index (remote-server-03)

**Goal.** Persist per-session metadata so detached sessions survive a daemon
restart and can be resumed, with a lifecycle, idle timeout, and max-sessions
limit.

**Reference behavior + file:line.** `server/types.ts:26` SessionState
(starting/running/detached/stopping/stopped); `:33` SessionInfo; `:46`
SessionIndexEntry (persisted to `~/.claude/server-sessions.json`); `:13`
ServerConfig idleTimeoutMs/maxSessions/workspace.

**Target Zig files.**
- Create `src/core/server_session_index.zig` (deep): `SessionIndexEntry
  { session_id, transcript_session_id, cwd, permission_mode, created_ts,
  last_active_ts, state }`, `SessionState` enum, and load/save to
  `~/.zcode/daemon/server-sessions.json` (atomic write like the task store).
  Register in `src/main.zig` comptime.
- Edit `src/remote_daemon.zig`: the `/sessions` route (Task 19) creates and
  persists an entry; a periodic sweep marks idle sessions detached/stopped per
  `idleTimeoutMs`; creation refuses beyond `maxSessions`.

**Approach.** Mirror the reference index shape. The index file is separate from
the daemon `State` (pid/port/token). On daemon start, load the index so detached
sessions are resumable.

**Acceptance criteria.**
- Test: write an index with two entries, reload, assert both round-trip with all
  fields.
- Test: state transitions starting->running->detached->stopped are persisted.
- Test: idle-timeout helper flags an entry whose `last_active_ts` is older than
  the timeout.

**Test strategy.** Unit tests in `server_session_index.zig` with a tmp home.

**Risk / footguns.** Depends on Task 19 for the producer side. Atomic write
(temp + rename) to survive a crash mid-write. `maxSessions=0`/`idleTimeoutMs=0`
mean "unlimited"/"never" per the reference.

**Size.** M.

---

### Task 21: Reconnecting WS-client transport with ping keepalive (remote-server-04)

**Goal.** Wrap the existing WS client into a driver that runs a 30s ping
keepalive, auto-reconnects with bounded backoff (2s delay, max 5 attempts), and
handles close codes 4001/4003 specially.

**Reference behavior + file:line.** `SessionsWebSocket.ts:17`
(RECONNECT/PING constants), `:100` (connect + auth header), `:234`
(handleClose reconnect/backoff), `:301` (startPingInterval);
`directConnectManager.ts:50` (connect).

**Target Zig files.**
- Create `src/core/ws_reconnect.zig` (deep, pure-ish): the reconnect policy -
  `nextDelay(attempt)` (2s base, max 5 attempts), `shouldReconnect(close_code)`
  (false for 4001 auth / 4003 forbidden), and a ping-due predicate
  (`pingDue(now, last_ping, 30s)`). Reuses `core/backoff.zig`. Register in
  `src/main.zig` comptime.
- Edit `src/mcp/client.zig`: in the persistent WS path (`rpcWebSocketPersistent`
  at line 1799), drive reconnection through `ws_reconnect` instead of the current
  immediate 2-attempt retry, and start a background ping sender on the 30s
  cadence; respond to server pings already happens at `:2794-2809`.

**Approach.** The policy is a pure module; the client consumes it. The ping
keepalive is a periodic write of a WS ping frame (`websocket.zig` has the
primitives). On close, consult `shouldReconnect(code)` and `nextDelay(attempt)`.

**Acceptance criteria.**
- Test: `nextDelay` returns ~2s for attempt 1 and stops after attempt 5.
- Test: `shouldReconnect(4001)` and `shouldReconnect(4003)` are false; a normal
  close (1000/1006) is true (within attempt budget).
- Test: `pingDue(now, last, 30s)` is true at/after 30s, false before.

**Test strategy.** Unit tests in `ws_reconnect.zig` (pure). Live reconnection is
integration-tested against the Task 19 server.

**Risk / footguns.** Only matters as the client half of Task 19; the framing
already exists. Avoid a tight reconnect loop (honor the delay). A background ping
thread must stop cleanly on disconnect.

**Size.** M.

---

## Verification

After each task: `zig build` and run the targeted tests under the custom runner
(`tools/test_runner.zig`), which prints `RUN: <name>` before each test so a hang
is attributable.

Whole-phase gate:

1. **Build + full tests.**
   `zig build test` (custom runner) must pass with every new test green. Confirm
   the new `core/` modules appear in the `src/main.zig` comptime block so their
   tests are discovered: `task_list_id.zig`, `swarm_message.zig`,
   `agent_registry.zig`, `teammate.zig`, `handoff_classifier.zig`,
   `summary_cadence.zig`, `coordinator_mode.zig`, `sdk_message.zig`,
   `server_session_index.zig`, `ws_reconnect.zig` (and the new tools module
   `teammate_mailbox.zig`).
2. **Release build + install** (per CLAUDE.md):
   `zig build -Doptimize=ReleaseFast` then
   `rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode`
   (rm-first to keep a valid ad-hoc signature - avoids the macOS "Killed: 9"
   footgun). Confirm `zcode version` runs.
3. **Bump version** in `build.zig.zon` (`.version = "X.Y.Z"`); the git short-hash
   is appended automatically.
4. **Manual swarm smoke (interactive REPL):**
   - `TeamCreate name=alpha` -> a `state/tasks/alpha` dir exists and numbering
     starts at 1; a structured `alpha.team` file lists `team-lead`.
   - A second `TeamCreate` from the same leader is refused; a duplicate name
     auto-renames to a word-slug.
   - `TaskCreate` two tasks, `TaskUpdate add_blocked_by` to chain them, then
     attempt to claim the dependent task -> blocked; complete the blocker ->
     claim succeeds.
   - `SendMessage to=worker` queues for a running named agent and resumes a
     finished one; `SendMessage to=*` broadcasts to all members; a
     `shutdown_request` / `shutdown_response` handshake aborts a teammate.
   - `AgentRun name=worker team_name=alpha mode=planning isolation=worktree` spawns
     an isolated, addressable teammate.
5. **Manual remote smoke:**
   - With `CLAUDE_CODE_COORDINATOR_MODE=1`, the session uses the coordinator
     persona and shows the worker-tools context; `--resume` reconciles the mode
     with a warning.
   - `POST /sessions` against the daemon returns `{session_id, ws_url, work_dir}`;
     a WS client connects, streams assistant/result frames, answers a
     `can_use_tool` control request, and reconnects after a forced drop with the
     30s ping keepalive observed; the session entry persists in
     `server-sessions.json` across a daemon restart.

## Out-of-scope / deferred notes

- **Remote (cloud) isolation.** `isolation:"remote"` (ant-only, cloud worker) is
  cloud-dependent and out of scope; only `worktree` and `cwd` land (Task 11).
- **tmux/iTerm2 teammate backends.** The reference supports tmux-pane and
  iTerm2-pane teammate backends (`swarm/backends/*`). zcode targets the
  in-process teammate backend only (Task 13); pane backends are deferred - the
  structured member record (Task 6) keeps `tmux_pane_id`/`backend_type` fields so
  a future pane backend can populate them.
- **UDS / bridge cross-machine messaging.** `SendMessage` to `uds:` / `bridge:`
  targets (`SendMessageTool.ts:586-797`, behind the `UDS_INBOX` feature) is a
  separate cross-machine transport and is deferred; this phase covers in-team
  named/broadcast/structured messaging only.
- **Per-task spinner rendering.** `activeForm` is stored (Task 4) but our TUI may
  not render a per-task spinner; the field is persisted for parity and for any
  future overlay, matching how TodoWrite already carries it.
- **Handoff classifier verdict source.** Task 16 lands the gate + rendering; the
  actual transcript-classification verdict (an LLM/hook call) is wired minimally
  and may be completed alongside the auto/yolo permissions audit.
- **Coordinator scratchpad gate.** The reference gates the scratchpad dir behind a
  Statsig feature (`coordinatorMode.ts:25-27`); zcode exposes it via a plain
  config flag rather than a remote feature gate.
