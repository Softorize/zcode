# Session persistence stays layered across four files

**Status:** accepted

An architecture review suggested collapsing session persistence -- `session/store.zig`,
`session/bundles.zig`, `session_cmds.zig`, `session_mgmt.zig` (~4.4k lines total)
-- into one deep `Session` module, citing a store↔bundles circular dependency.

We keep the four-file split.

## Why

1. **There is no circular dependency.** `store.zig` does not import `bundles.zig`;
   the dependency is one-directional (`bundles` → `store`). That is proper
   layering, not a cycle.
2. **The files own genuinely different layers:**
   - `store.zig` -- low-level persistence primitives: JSONL append-log,
     AES-256-GCM encryption, labels/tags/cleanup, paths, I/O atomicity.
   - `bundles.zig` -- high-level operations built on those primitives:
     checkpoint save/restore, fork, share, import/export, undo.
   - `session_cmds.zig` -- CLI command handlers (`/session …`, `/checkpoint`, …).
   - `session_mgmt.zig` -- front-end orchestration (`runInteractive`,
     `runOneShot`, REPL bridges, re-exports).
3. **`store.zig` is intentionally minimal so many modules can depend on it**
   (`main`, `agent_runtime`, `api_server`, `remote_daemon`, `agent_history`,
   `stats_report`). Merging would force all of them to pull in checkpoint/fork
   workspace-capture concerns they do not use.
4. **Deletion test fails.** A single ~4.4k-line module would mix encryption and
   file I/O with checkpoint/fork semantics and CLI dispatch, harming both
   stability of the primitives and testability.

## Consequence

Future reviews should not re-suggest merging the session modules. The layering
(primitives → operations → CLI → front-end) is load-bearing; build on `store`'s
primitives from `bundles`, not by collapsing the layers.
