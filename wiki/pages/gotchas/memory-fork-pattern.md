# Memory-subsystem constrained-fork pattern (Phase 10)

How the auto-memory extraction (Task 5, `core/extract_memories.zig`) and the
per-session summarizer (Task 6, `core/session_memory.zig`) forks are built. Read
this before touching either.

## Constrained forks enforce via ToolExecContext, NOT schema filtering

The extraction/summarizer children are in-process `AgentRuntime` instances spawned
with the `maybeRunDream` template (`agent_runtime.zig`): `interactive=false`,
`depth = parent.depth + 1`, a `max_tool_rounds_override` cap, then
`child.handlePrompt(prompt)`.

The tool restriction is applied at **dispatch time** in
`agent_tools.executeToolCall`, gated on a context flag, not by trimming the
advertised schema list in the round loop:

- `ToolExecContext.auto_mem_dir` -> `autoMemGate` (Read/Grep/Glob + read-only
  Bash + Edit/Write within the memory dir).
- `ToolExecContext.session_mem_file` -> `sessionMemGate` (Read any path + Edit on
  the one notes file only; everything else denied).

The flag lives on `AgentRuntime` as `auto_mem_dir_restriction` /
`session_mem_file_restriction` (null on the main runtime) and is threaded into
the context by `buildToolExecContext`. The owned path string lives on the parent
stack for the fork's lifetime; `child.deinit()` runs before the parent frees it.

`filterAutoMemSchemas` exists for parity but the extraction child does not apply
it in the round loop - the execution-time gate is the real enforcement. Edit
needs a prior Read of the same file, so Read is always allowed in the
session-memory gate even though it is not a "write".

## Recursion guard is mandatory

`maybeExtractMemories` / `maybeSessionMemory` only fire when
`interactive and depth == 0`. The child has `interactive=false`, so it never
recurses into its own extraction. Mirror this in any new turn-end fork.

## zcode has no auto-compact toggle

The reference gates the session summarizer on auto-compact being enabled. zcode
always auto-compacts (no config field), so the effective gate is just
`depth == 0 && interactive`. Do not invent a config field for this.

## Token metric must match autocompact

`shouldExtract` thresholds (init 10000, between-update 5000, 3 tool calls) are
compared against a context-window token count computed the SAME way the
compaction path does: `types.estimateTokens` summed over live history
(`AgentRuntime.currentContextTokens`). Keep them consistent or the two features
disagree on when context has grown.

## Naming collision: `.session_memory` is two different things

- `types.HistoryRole`/context-block type `.session_memory` (`context.zig`) =
  a task-state snapshot block injected into the prompt. PRE-EXISTING.
- `core/session_memory.zig` (Task 6) = conversation-notes distillation to a
  per-session markdown file under `<sessions_dir>/session-memory/<id>.md`.

They share only a name. Do not overload one for the other.

## First-write file creation: O_EXCL then template

`ensureNotesFile` creates with `.exclusive = true` (0.16 maps to O_CREAT|O_EXCL,
returns `error.PathAlreadyExists` on collision), writes the template only on a
fresh create, and otherwise reads the existing file - so a prior session's notes
are never clobbered. Reuse this discipline for any "create-with-default-if-absent"
file.
