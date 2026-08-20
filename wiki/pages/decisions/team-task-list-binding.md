# Decision: Team == task list (per-team task dir + leader binding)

Phase 12, swarm-tasks-05. A team's tasks are scoped to a per-team directory so
they are isolated and renumber from 1.

## How it resolves

`core/task_list_id.zig` resolves the active task list id, first non-empty wins:
1. `ZCODE_TASK_LIST_ID` env var (a spawned teammate inherits this so its task
   ops resolve to the leader's list).
2. A process-global `leader_team_name` set by `teamCreate` via
   `setLeaderTeamName` (mutex-guarded; `std.Io.Mutex`).
3. The literal `"tasklist"` default (un-teamed sessions).

The resolved id is sanitized to a single safe path component, then task files
live under `state/tasks/<listid>/` (was `state/tasks/`). Every task op in
`tools/task.zig` routes through `tasksRelAlloc` -> `helpers.tasksSubpathForListAlloc`.

## Numbering + reset

Per-list ids switched from `task-<ts>-<hex>` to monotonic integers ("1", "2",
...). The next number is `max(existing .task stems that parse as ints,
.highwatermark) + 1`. `resetTaskList` records the current max into a
`.highwatermark` file then deletes the `.task` files, so a re-created team
starts clean but never recycles a previously used id.

`taskPathAlloc` still accepts ANY safe identifier, so legacy `task-<ts>-<hex>`
ids and the new integer ids both load (back-compat during transition). The
numeric scan ignores non-integer stems.

## Why opaque/global

The leader binding is a single process-global (mirrors the reference's
module-level `leaderTeamName`). It needs the mutex because background teammate
threads read it while the main loop may rebind it. `teamCreate` is the only
writer today; one-team-per-leader enforcement and session cleanup are later
tasks (swarm-tasks-07) that build on `hasLeaderTeam` / `clearLeaderTeamName`.

## Test footgun

The leader binding is process-global and Zig tests share the process. Tests
that set it MUST `defer clearLeaderTeamName`, and tests asserting the default
must `clearLeaderTeamName` first. Each test still uses its own tmpDir cwd, so
the only cross-test hazard is a stale binding, not stale files.
