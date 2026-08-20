# Phase 28: REPLTool (model-facing code REPL / interpreter)

## Overview

**What this subsystem is.** In the reference (Claude Code, TypeScript) the `REPLTool` is a single model-facing tool named `REPL` (`REPL_TOOL_NAME = 'REPL'`) that lets the model author JavaScript which executes inside a sandboxed VM context. From inside that script the model calls the eight "primitive" tools (Read / Write / Edit / Glob / Grep / Bash / NotebookEdit / Agent) as ordinary JS function calls, batching many file/shell operations into one tool round-trip. When REPL mode is on, those eight primitives are *removed* from the model's advertised tool list (`REPL_ONLY_TOOLS`), so the only way to touch the filesystem or shell is to write a REPL script. The inner calls are re-dispatched one-by-one through the normal `canUseTool` permission engine and surfaced as `isVirtual` Read/Grep/Bash messages.

**Why it exists in the reference, and why it is invisible externally.** This is an ANT-ONLY system. `REPLTool` is conditionally `require`d only when the build-time `USER_TYPE === 'ant'` (`tools.ts:16-19`), it is only added to the tool list when `USER_TYPE === 'ant'` *and* `REPLTool` resolved (`tools.ts:232`), and `isReplModeEnabled()` only returns true for the ant CLI entrypoint (`constants.ts:23-30`). Critically, for any non-ant (external) user the REPL tool never appears, and the reference even strips REPL `tool_use`/`tool_result` wrapper pairs from persisted transcripts and promotes the inner `isVirtual` messages to real ones (`sessionStorage.ts` `transformMessagesForExternalTranscript`). The net effect: **an external user's model transcript is byte-for-byte identical whether or not the REPL wrapper ran.** External behavior is plain native tool calls.

**Verdict for zcode.** After reading the reference (`tools/REPLTool/constants.ts`, `primitiveTools.ts`, `tools.ts:16-19,232,312-322`, `permissions.ts:597-615`, `prompts.ts:274-285`, `memdir.ts:372-407`, `collapseReadSearch.ts:148-163`) and confirming zcode's state (zero matches for `REPL_TOOL_NAME` / `REPLTool` / `isReplMode` / `REPL_ONLY` / `USER_TYPE` / `user_type` / `is_ant` across `/Users/example/Projects/zig-code/src`), **all 12 surveyed gaps are out-of-scope.** Every one of them is either the ant-only REPL tool itself, an implementation detail of it, or a display/persistence mechanism whose entire purpose is to make the REPL wrapper *invisible* to external users. There is no external-parity behavior to match here. zcode's unified native tool calls plus its existing Bash sandbox (seatbelt/bwrap) and `concurrent_executor` already deliver the "sandboxed code execution + batching" value for external users by the correct external-facing design.

**Dependencies on earlier phases.** None to build. This phase consumes nothing from phases 1-16 and produces no code. It depends only on documentation conventions established in earlier phases (the "documented deviation" pattern). The closest adjacent already-present surfaces are mode-based tool gating (`agent_tools.zig:217` `filterReadOnlySchemas`, dispatch blocking at `agent_runtime.zig:1744-1754`) and AgentRun permission auto-approval (`agent_runtime.zig:1764` `handleAgentRunTool`), which together cover the *only* fragments of these gaps that have any external analog.

**Effort.** Documentation only. No build tasks. Net engineering size: **XS** (one roadmap section + one wiki note). The per-gap sizes in the survey (S/M/L) describe what it *would* cost if built; none of that work is recommended.

## Scope split

| Gap id | In-scope to build? | Decision + reason |
|---|---|---|
| repl-tool-01 (REPL tool itself) | NO | ANT-ONLY by design (`USER_TYPE === 'ant'`). External users never see it; reference strips it from external transcripts. Embedding a JS/Lua VM in a Zig binary is large effort with zero external-parity benefit. Document as honest out-of-scope. |
| repl-tool-02 (REPL mode gating + `REPL_ONLY_TOOLS`) | NO | Only meaningful if repl-tool-01 exists. zcode already has equivalent *mode-based* tool hiding (`filterReadOnlySchemas` + dispatch blocking) for planning/review/brainstorm; the env-var REPL mode and `REPL_ONLY_TOOLS` list are moot without the tool. |
| repl-tool-03 (VM primitive wrappers re-dispatch through permissions) | NO | Implementation detail of repl-tool-01; the VM source is not even in the reference dump. Out of scope as a consequence. |
| repl-tool-04 (absorbed-silently UI collapsing of inner virtual messages) | NO | Pure rendering support for the ant-only REPL wrapper. No REPL tool means nothing to collapse. |
| repl-tool-05 (external-transcript REPL stripping) | NO | This is precisely the mechanism that makes REPL invisible externally. It *confirms* there is no external-facing behavior to match. |
| repl-tool-06 (REPL-aware system-prompt guidance suppression) | NO | The non-REPL prompt branch is the external path, and zcode already matches it. The REPL branch only fires for ant. |
| repl-tool-07 (memdir grep-shell-form under REPL mode) | NO | Only the `isReplModeEnabled()` arm of an OR; the `hasEmbeddedSearchTools()` arm still applies normally to zcode's embedded search tools. No external gap. |
| repl-tool-08 (`REPLToolProgress` streaming type) | NO | Progress channel for the ant-only REPL tool. No REPL tool means no REPL progress. |
| repl-tool-09 (REPL exemption in acceptEdits classifier) | NO | REPL half of a two-tool special case (`AGENT_TOOL_NAME`, `REPL_TOOL_NAME`). zcode already handles the Agent half via auto-approval. The REPL half has nothing to gate. |
| repl-tool-10 (sandboxed code-exec primitive) | NO | zcode's Bash sandbox (seatbelt/bwrap) + `concurrent_executor` already deliver the sandboxing-and-batching value via native tool calls. The right external-facing design; no new primitive needed. |
| repl-tool-11 (`getReplPrimitiveTools` display registry) | NO | Display plumbing for the ant-only REPL wrapper. Not needed externally. |
| repl-tool-12 (REPL bridge / remote-control / teleport) | NO | Interactive-REPL-screen remote bridge (distinct from the REPL TOOL); a cloud remote/teleport backend, explicitly out of scope per the locked no-cloud-backend decision. |

There are **no in-scope gaps** in this phase.

## Gaps covered

| id | title | severity | size (if built) | zcode current state |
|---|---|---|---|---|
| repl-tool-01 | REPL tool (model-facing JS interpreter) absent | low | L | No model-callable code interpreter. Tool dispatch (`tools/tool_dispatch.zig:90-150`) has no REPL handler; no tool named `REPL` in schemas (`tool_schemas.zig`). Correct: ant-only exclusion. |
| repl-tool-02 | REPL mode gating + `REPL_ONLY_TOOLS` | low | M | Mode-based gating PRESENT (`filterReadOnlySchemas` `agent_tools.zig:217`; dispatch block `agent_runtime.zig:1744-1754`). No env-var REPL mode detection, no `REPL_ONLY_TOOLS` (correctly, since no REPL tool). |
| repl-tool-03 | VM primitive wrappers re-dispatch through permissions | low | L | No VM, no `createToolWrapper`, no per-call inner re-dispatch. Single unified dispatch path through `tool_dispatch.zig`. |
| repl-tool-04 | Absorbed-silently UI collapsing of inner virtual msgs | low | S | No `isVirtual`/`isREPL`/`isAbsorbedSilently` flags; `appendHistoryTurn` treats all tool results identically. Brief-mode collapsing exists for density only. |
| repl-tool-05 | External-transcript REPL stripping on persist/resume | low | S | No REPL wrapper, no `isVirtual` metadata, no ant-vs-external transcript distinction in `store.zig`/`bundles.zig`. |
| repl-tool-06 | REPL-aware system-prompt tool guidance suppression | low | S | Full "prefer dedicated tools over Bash" guidance emitted unconditionally (`system_prompt.zig`); `prompt_helpers.zig:111-119` ignores `prompt_mode` for the static prefix. This is the external (non-REPL) branch, which is correct. |
| repl-tool-07 | memdir grep-shell-form selection under REPL mode | low | S | Memory rendering (`prompt_helpers.zig:263-280`, `memory.zig`) uses grep tool form; no "Searching past context" REPL-mode conditional. |
| repl-tool-08 | `REPLToolProgress` streaming progress type | low | S | No `REPLToolProgress`, no `ToolProgressData` channel. `cli/repl.zig` `ProgressReporter` is terminal UI only, not model-facing tool progress. |
| repl-tool-09 | REPL exemption in acceptEdits permission classifier | low | S | AgentRun auto-approves (`agent_runtime.zig:1764` `handleAgentRunTool`, no `permission_rules.match()`). REPL half has no tool to exempt. |
| repl-tool-10 | Sandboxed code-exec primitive (REPL's underlying value) | low | M | No code interpreter. Sandboxed *shell* exec present (`tools/shell.zig`, `core/sandbox.zig`). NotebookEdit edits cells, does not execute. |
| repl-tool-11 | `getReplPrimitiveTools` display classification registry | low | S | Execution-side filters present (`filterReadOnlySchemas` etc.); no display-side primitive registry, no `isVirtual` classification. |
| repl-tool-12 | REPL bridge / remote-control / teleport | low | L | Local approval/ask bridges present (`ApprovalBridge`/`AskUserBridge` in `cli/repl.zig`, `session_mgmt.zig`); no remote transport. `/teleport` is a documented stub (`core/cc_stub_commands.zig:18`). |

## Implementation tasks

**None.** All 12 gaps are out-of-scope. There is no Zig code, no new module, and no `src/main.zig` comptime registration entry to add for this phase. Proceed directly to the documented-deviations section.

(If a future decision reverses the no-ant-tools stance, the natural seams already exist: schema gating would extend `agent_tools.zig` `filterReadOnlySchemas`/`filterGitToolSchemas` patterns, a new tool would register in `tool_schemas.zig` and dispatch in `tools/tool_dispatch.zig`, and any new module would be wired into the `src/main.zig` comptime test block and imported via `@import("zcode_runtime")` per project conventions. That work is explicitly *not* part of this phase.)

## Documented deviations

All items below are recorded as intentional, documented deviations. The unifying rationale: **the REPL subsystem is an internal Anthropic ("ant") batching-and-training affordance whose entire design goal is to be invisible to external users.** zcode targets external parity, so matching the *external-observable* behavior is achieved by zcode's existing native-tool architecture, and matching the *ant-internal* behavior provides no benefit.

1. **REPL tool itself (repl-tool-01, repl-tool-10).** Out of scope because it is gated on `USER_TYPE === 'ant'` (`tools.ts:16-19,232`) and `isReplModeEnabled()` returns false for any non-ant/non-cli entrypoint (`constants.ts:23-30`). Building a JS/Lua VM sandbox inside a Zig binary is a large effort that yields no external-parity benefit; the external-facing value (sandboxed exec + batching) is already covered by zcode's Bash sandbox (`core/sandbox.zig` seatbelt/bwrap) and concurrent tool execution. **No local stub worthwhile** - a stub `REPL` tool would only confuse external users and the model, since the reference never exposes it to them.

2. **REPL mode gating and `REPL_ONLY_TOOLS` (repl-tool-02).** Out of scope as a dependent of repl-tool-01. zcode's mode-based tool hiding (`filterReadOnlySchemas`, `agent_tools.zig:217`; dispatch blocking, `agent_runtime.zig:1744-1754`) is the *architecturally-correct equivalent for the features external users actually have* (planning/review/brainstorm modes). The env-var triggers (`CLAUDE_CODE_REPL`, `CLAUDE_REPL_MODE`, `USER_TYPE`) and the `REPL_ONLY_TOOLS` set are specific to REPL activation and have nothing to gate without the tool. **No stub.**

3. **VM primitive wrappers and per-call permission re-dispatch (repl-tool-03, repl-tool-09).** Out of scope as implementation details of repl-tool-01; the VM source is not present even in the reference dump. zcode already auto-approves the AgentRun tool (`agent_runtime.zig:1764`), which is the *only* externally-relevant half of the `permissions.ts:597-615` two-tool special case. **No stub.**

4. **UI absorption, virtual-message collapsing, external-transcript stripping, display registry (repl-tool-04, repl-tool-05, repl-tool-11).** Out of scope as pure rendering/persistence plumbing for the ant-only wrapper. repl-tool-05 in particular (`sessionStorage.ts` `transformMessagesForExternalTranscript`) is the strongest evidence that there is *no external behavior to match*: it exists precisely to make external transcripts look like plain native tool calls, which is exactly what zcode already emits via `appendHistoryTurn`. **No stub.**

5. **REPL-aware prompt guidance and memdir grep-shell selection (repl-tool-06, repl-tool-07).** Out of scope because the branch zcode already implements (the full "prefer dedicated tools" guidance in `core/system_prompt.zig`, and the grep-tool memdir form) *is* the external/non-REPL path. The REPL arms (`prompts.ts:274-285`; `memdir.ts:382-385` `isReplModeEnabled()`) only fire for ant. For repl-tool-07 note that the `hasEmbeddedSearchTools()` arm of the OR is the relevant one for any embedded-search build and continues to apply normally. **No stub.**

6. **`REPLToolProgress` streaming type (repl-tool-08).** Out of scope as the progress channel for the ant-only REPL tool. zcode's `cli/repl.zig` `ProgressReporter` is a terminal-UI reporter, not a model-facing tool-progress stream, and that distinction is correct for external use. **No stub.**

7. **REPL bridge / remote-control / teleport (repl-tool-12).** Out of scope. This is the interactive-REPL-*screen* remote bridge (distinct from the REPL *tool*) and is a cloud remote/teleport backend. It falls under zcode's locked no-cloud-backend decision; `/teleport` is already a documented stub (`core/cc_stub_commands.zig:18-22`). The *local* halves (approval bridge, ask-user bridge) are already present. **No additional stub worthwhile.**

## Verification

Because this phase ships no code, verification is limited to confirming the audit conclusions still hold and that the deviations are recorded. No `build.zig.zon` version bump is required for a docs-only roadmap entry (per project convention, version bumps accompany code changes); if this plan is committed alongside any code change, bump the patch number then.

Manual checks (all read-only, all confirm "still out of scope"):

- Confirm zcode exposes no `REPL` tool: `grep -rn "REPL_TOOL_NAME\|REPLTool\|isReplMode\|REPL_ONLY\|getReplPrimitiveTools" /Users/example/Projects/zig-code/src` returns zero matches (verified during this audit).
- Confirm no ant/user-type gating leaked in: `grep -rn "USER_TYPE\|user_type\|is_ant\|isAnt" /Users/example/Projects/zig-code/src` returns only the unrelated `providers/extractors.zig` Anthropic-response detectors (verified).
- Confirm the externally-relevant adjacent surfaces remain intact (these are the real parity points, owned by other phases):
  - Mode-based tool hiding: `filterReadOnlySchemas` at `agent_tools.zig:217` and dispatch blocking at `agent_runtime.zig:1744-1754`.
  - AgentRun auto-approval (the external half of the classifier special-case): `handleAgentRunTool` at `agent_runtime.zig:1764`.
  - Sandboxed shell exec (the external-facing analog of REPL's value): `tools/shell.zig` + `core/sandbox.zig`.

If this plan is committed together with other phases that do touch code, run the standard gate before install:

```
/Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build -Doptimize=ReleaseFast
rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode
```

(Use `rm -f` before `cp` to avoid the macOS in-place-overwrite ad-hoc-signature invalidation footgun noted in CLAUDE.md.) For a docs-only commit, the build/install step is not strictly required, but running `zig build test` to confirm the tree is still green before merge is recommended.

**Wiki checkpoint.** This phase's durable lesson - "the entire REPLTool subsystem is ant-only and engineered to be invisible to external users; external parity is achieved by zcode's native tool calls + Bash sandbox, so all 12 REPL gaps are out-of-scope by design" - belongs in the project wiki under the parity-decisions area so future audit passes do not re-flag these as missing features. Add a one-paragraph note citing `tools.ts:16-19,232`, `constants.ts:23-30`, and `sessionStorage.ts transformMessagesForExternalTranscript` as the canonical evidence that there is no external-observable REPL behavior.
