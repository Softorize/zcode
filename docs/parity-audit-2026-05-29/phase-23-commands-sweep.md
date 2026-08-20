# Phase 23: Per-command presence sweep across all reference commands

## Overview

This phase is a verification sweep, not a single-feature port. Round 1 of the parity audit walked the command surface at a coarse grain and trusted the dispatcher's "command recognized" signal as "command at parity". That signal lies in several places: a handler can be present but unreachable (dead code behind an early removal check), present but implementing a different feature under the same name (namespace collision), or present only as a stub message that misdescribes what the reference does. This phase re-walks the large reference commands one by one and resolves each to a precise verdict: **present-equivalent**, **present-different**, **stub**, **dead-code**, or **missing**, with a fix for every in-scope divergence.

**What:** For each of `/insights`, `/thinkback`, `/stickers`, `/passes`, `/effort`, `/fast`, `/good-claude`, `/btw`, `/grove`, `/desktop`, `/mobile`, `/backfill-sessions`, `/heapdump`, `/perf-issue`, `/ant-trace`, `/color`, `/tag`, `/branch`, `/share`, `/bughunter`, `/autofix-pr`, `/status`, `/doctor`, `/export`, `/resume`, `/rewind`, determine present/stub/missing in zcode and whether the behavior is equivalent. Twelve verified gaps drive the work; the rest are confirmed at parity or confirmed out-of-scope and only documented.

**Why:** Exact-match parity (PRD #534 P9b) means a Claude Code user must see the same command set behaving the same way. A dead-code handler (`/insights`) means a real reference command silently returns "unknown command". A namespace collision (`/branch` does git, not conversation-fork) means the user gets a surprising and wrong behavior under a familiar name. A misdescribing stub (`/passes` says "compiler-passes view") is a documented deviation that is itself factually wrong. Each of these is a parity defect even though the coarse sweep marked the command "present".

**Dependencies on earlier phases:** Light. This phase reuses primitives that earlier phases already built:
- Phase covering session bundles / checkpoint-restore (`src/session/bundles.zig`, `restoreCheckpointWorkspace`/`restoreGitWorkspace`/`restoreFileWorkspace`) is the backbone for the `/rewind` code-restore task.
- Phase covering the session switcher overlay (`cli/repl_overlay.zig:runSessionSwitcherOverlayLoop`) is reused for the interactive `/resume` task.
- Phase covering `forkSessionImpl` / `forkSessionFromState` is reused for the conversation-fork `/branch` task.
- Phase covering `handlePrompt` / forked-context plumbing in `agent_runtime.zig` is the backbone for `/btw`.
- The removed-commands and stub-commands tables (`src/core/removed_commands.zig`, `src/core/cc_stub_commands.zig`) were introduced by the P9/P9b exact-match phase; this phase corrects two specific entries in them.

**Effort:** Medium overall. The work is many small surgical edits (table corrections, stub-text fixes, env-var wiring) plus three genuine M/L features (interactive `/resume`, conversation-fork `/branch`, code-restore `/rewind`) and two M features (`/btw` side-question, `/color` palette). No new subsystems; everything reuses existing deep modules.

## Scope split

| Gap id | Command | Decision | Reason |
| --- | --- | --- | --- |
| commands-sweep-01 | /insights | IN SCOPE | Real reference command wrongly filtered out; handler already exists, just unreachable. One-line un-removal (minimum), optional LLM-report uplift. |
| commands-sweep-02 | /branch | IN SCOPE | Reference `/branch` forks the conversation; ours does git. Fork primitives already exist (`/session fork`). Re-point the name. |
| commands-sweep-03 | /color | IN SCOPE | Reference sets prompt-bar accent color from a palette + persists; ours is an ANSI on/off toggle. Local-feasible. |
| commands-sweep-04 | /resume | IN SCOPE | Reference opens interactive selector + reloads; ours prints a usage hint. Selector overlay already exists (Ctrl+X S). Wire `/resume` (no args) to it. |
| commands-sweep-05 | /rewind | IN SCOPE | Reference restores code AND conversation; ours restores conversation only. File-restore primitives exist under `/session restore`. |
| commands-sweep-06 | /btw | IN SCOPE | Reference runs a non-interrupting side-question; ours is a static easter-egg string. `handlePrompt` + forked context plumbing exist. |
| commands-sweep-07 | /thinkback | IN SCOPE (doc + name) | Reference `/think-back` is a marketplace Year-in-Review plugin (cloud); ours is a local reasoning-trace viewer. Do NOT port the plugin; document the divergence and note the name `think-back` is not registered. |
| commands-sweep-08 | /effort | IN SCOPE | Core set/show matches; missing persistence + `CLAUDE_CODE_EFFORT_LEVEL` env override + session-only-vs-persisted messaging. |
| commands-sweep-09 | /status | IN SCOPE (partial) | Account section out of scope (auth-gated). Portable deltas: live API-connectivity probe + MCP/tool health rollup. |
| commands-sweep-10 | /passes | OUT OF SCOPE | Anthropic referral/account API (cloud). Local equivalent meaningless. BUT fix the wrong stub text ("compiler-passes view"). |
| commands-sweep-11 | /desktop, /mobile | OUT OF SCOPE | Cloud bridge handoff/pairing. BUT add missing aliases (/app, /ios, /android) for surface parity; `/mobile` QR-of-download-URL half is locally feasible (optional). |
| commands-sweep-12 | /grove | OUT OF SCOPE | Account data-sharing/training-consent via OAuth phone-home. Not even a slash command in the reference. Document only. |

## Gaps covered

| id | title | severity | size | our current state |
| --- | --- | --- | --- | --- |
| commands-sweep-01 | /insights unreachable (dead code behind removal check) | high | S | Handler at `repl_commands.zig:1795-1799` real, but `/insights` listed in `removed_commands.zig:24`, short-circuited at `repl_commands.zig:163`. User sees "unknown command". |
| commands-sweep-02 | /branch does git instead of conversation-fork | medium | M | `repl_commands.zig:2103-2115` runs `git branch/checkout`. Conversation fork only via `/session fork` (`:360-362`). |
| commands-sweep-03 | /color is ANSI toggle, not prompt-bar palette | low | M | `repl_commands.zig:752-756` boolean `ui_color_enabled` toggle. No palette/persistence/teammate guard. |
| commands-sweep-04 | /resume (no args) prints hint, no interactive selector | medium | M | `repl_commands.zig:318-320` static usage string. Interactive selector exists but only via Ctrl+X S (`repl_overlay.zig:3074`). |
| commands-sweep-05 | /rewind restores conversation only, not code | medium | L | `repl_commands.zig:4260-4281` truncates history; "snapshot on disk unchanged". Code-restore exists only under `/session restore`. |
| commands-sweep-06 | /btw is easter-egg stub, not side-question | medium | M | Static string at `cc_stub_commands.zig:14`. No side-question / forked-context / modal. |
| commands-sweep-07 | /thinkback is trace viewer; reference is YIR plugin | low | S | `repl_commands.zig:1699-1706,5645-5708` local trace viewer. No `think-back` name, no plugin. |
| commands-sweep-08 | /effort not persisted, ignores env override | low | S | `repl_commands.zig:4704-4721` in-memory only. `CLAUDE_CODE_EFFORT_LEVEL` never read. |
| commands-sweep-09 | /status text dump misses API-probe + MCP health | low | M | `repl_commands.zig:758-835` rich text dump; no live API ping, no MCP/tool health rollup. |
| commands-sweep-10 | /passes stub text wrong ("compiler-passes view") | low | S | Stub at `cc_stub_commands.zig:27`, factually wrong description. |
| commands-sweep-11 | /desktop, /mobile missing aliases | low | S | Stubs at `cc_stub_commands.zig:21-22`. Aliases /app, /ios, /android absent. |
| commands-sweep-12 | /grove not implemented (not a command) | low | S | Nothing; nearest is `/privacy-settings` stub at `cc_stub_commands.zig:31`. |

## Implementation tasks

These are independent except where noted. Per the parallel-delegation rule they can run as parallel agents: sweep-01, sweep-08, sweep-10, sweep-11 touch the two small tables and effort logic and could be batched; sweep-02, sweep-04, sweep-05 all touch session machinery and `repl.zig` selector wiring so order them carefully or assign to one agent to avoid conflicts; sweep-03 and sweep-06 are isolated new modules.

---

### Task 01 (commands-sweep-01): Restore /insights to the command surface

**Goal:** `/insights` typed in the REPL runs the existing inline stats/insights handler instead of returning "unknown command".

**Reference behavior + file:line:** `/insights` is a core, always-registered `type:'prompt'` command (`/Users/example/Downloads/claude-code-main/src/commands.ts:190-202`, registered in `COMMANDS()` at `:318`; definition `/Users/example/Downloads/claude-code-main/src/commands/insights.ts` `usageReport`, `name:'insights'`, `progressMessage:'analyzing your sessions'`). It runs an LLM analysis (`getDefaultOpusModel`) over the local session corpus and emits a narrative usage report. The reference is NOT a removed/zcode-only command, so listing it in `removed_commands.zig` is a misclassification.

**Target Zig files:**
- `src/core/removed_commands.zig` (delete the `"/insights"` entry at line 24).
- Optionally `src/core/stats_report.zig` (existing `renderInsights` at `:120-191`) - no change needed for the minimum fix.

**Approach (minimum, recommended first):**
1. Delete the line `"/insights",` from the `removed` array in `src/core/removed_commands.zig`.
2. Confirm the inline handler at `repl_commands.zig:1795-1799` (`renderInsights` over the stats corpus) is now reachable: the early `isRemoved` check at `:163` no longer matches, so dispatch falls through to `:1795`.
3. Update the doc comment in `removed_commands.zig` if it enumerates `/insights` as an example.

**Approach (optional uplift to reference semantics):** The reference `/insights` is an LLM prompt over the session corpus, not a local-stats render. zcode's `renderInsights` (14-day per-day activity + tag frequency) is a *different* feature. To match reference semantics, the larger fix is to feed the collected session summaries into `runtime.handlePrompt` with an analysis instruction and stream the model's narrative. This is optional and should be flagged in the plan as a follow-up; the minimum fix (un-removal) is the parity-blocking item.

**Acceptance criteria:**
- Write a test in `src/core/removed_commands.zig` asserting `try testing.expect(!isRemoved("/insights"));` and `!isRemoved("/insights --since 7d")`. Make it pass.
- Manual: in a built REPL, `/insights` returns the stats/insights render, not "unknown command".

**Test strategy (tools/test_runner.zig):** Add the negative-assertion to the existing `removed_commands.zig` test block ("kept and unrelated commands are not removed"). Runs under the custom runner with no IO. Optionally add a `repl_commands` integration test that dispatches `/insights` against a tmp session store (use `core/test_helpers.zig tmpDirPath` for cwd) and asserts the output is non-null and not the unknown-command string.

**Risk + 0.16 footguns:** Minimal. The handler already compiles and is tested for the `/stats` sibling. If adding the integration test, build the runtime against a `testing.TmpDir`-backed store and pass the absolute path from `tmpDirPath` (never `"."`).

**Size:** S.

---

### Task 02 (commands-sweep-02): Re-point /branch to conversation-fork

**Goal:** `/branch [name]` forks the CURRENT CONVERSATION at this point (copies the transcript into a new session id with `forkedFrom` traceability) and the user continues in the fork. Add the `fork` alias.

**Reference behavior + file:line:** `/Users/example/Downloads/claude-code-main/src/commands/branch/index.ts:1-13` (`type:'local-jsx'`, `name:'branch'`, alias `['fork']`, description "Create a branch of the current conversation at this point", `argumentHint:'[name]'`); `branch.ts createFork()` copies the transcript into a new session, sets `forkedFrom`, preserves timestamps/gitBranch. Pure conversation operation - NOT git.

**Decision required (surface what is being changed):** Our current `/branch` (git branch list/create/switch at `repl_commands.zig:2103-2115`) is a useful helper but collides with the reference name. The recommended approach is:
1. Make `/branch [name]` an alias of the existing conversation-fork (`runtime.forkSession`), matching the reference.
2. Move the git helper to a clearly named command (e.g. `/git-branch`) so we do not lose the functionality (per "fix what you find" - do not silently delete it). Confirm `/git-branch` is not a reference command before adding (it is not in the reference command list), so register it as a zcode-only command OR keep it only as the explicit `/branch create|switch` subforms re-homed. Simplest: keep `/branch <bare>` and `/branch <name>` as conversation-fork; keep the git subcommands accessible via `git` tool/`/diff`-style helpers. Flag this tradeoff in the plan so the user can veto.

**Target Zig files:**
- `src/repl_commands.zig` (replace the `/branch` git handlers at `:2103-2115` with conversation-fork dispatch calling `runtime.forkSession`, which already exists at `agent_runtime.zig:559`).
- `src/core/command_canonical.zig` (add `fork -> /branch` alias if aliases are normalized there).
- Reuse `agent_history.zig:forkSessionImpl` (`:1164`) and `session/bundles.zig:forkSessionFromState` (`:228`) via `runtime.forkSession` - no change to those.

**Approach step-by-step:**
1. Replace the three `/branch` blocks at `repl_commands.zig:2103-2115` with: `if (eql("/branch") or startsWith("/branch "))` -> parse optional name -> `runtime.forkSession(name_or_null)` (identical to the `/session fork` block at `:360-362`).
2. Add `fork` as an alias to `/branch` in the canonical/alias layer so `/fork [name]` also works.
3. Re-home the git helper (decision above) so it is not lost.
4. Update `cli/repl_help.zig` and any command-palette entry for `/branch` to describe "fork the conversation".

**Acceptance criteria:**
- Write a test that dispatches `/branch myfork` against a tmp-dir session store and asserts a new session id is created and the transcript is copied (assert `forkedFrom` traceability via the bundle metadata). Make it pass. Model the test on the existing `/session fork` coverage.
- Manual: `/branch` in REPL forks the conversation; `/fork` does the same.

**Test strategy (tools/test_runner.zig):** Reuse the existing fork test fixtures. Build the runtime with `installForTest`, point the store at `tmpDirPath`, dispatch `/branch`, then enumerate sessions and assert the new id + copied transcript.

**Risk + 0.16 footguns:** The fork copies a transcript file - watch `readFileAlloc(.limited(N))` returning `error.StreamTooLong` (not `FileTooBig`) and track read offset across loop iterations (do not re-read byte 0). These are already handled inside `forkSessionImpl`; the new code only calls `runtime.forkSession`, so the risk is low. Namespace risk: ensure no other handler still claims `/branch` after the edit (grep for `"/branch`).

**Size:** M.

---

### Task 03 (commands-sweep-03): /color sets a per-session prompt-bar accent color

**Goal:** `/color <name>` sets the prompt-bar accent color for the session from a fixed palette, persists it, and `default|reset|none|gray|grey` resets it. Invalid input lists the palette. (No teammate concept in zcode, so skip the teammate guard.)

**Reference behavior + file:line:** `/Users/example/Downloads/claude-code-main/src/commands/color/index.ts:1-15` (`type:'local-jsx'`, `name:'color'`, `immediate:true`, `argumentHint:'<color|default>'`); `color.ts:18-70` defines `AGENT_COLORS`, `RESET_ALIASES = ['default','reset','none','gray','grey']`, `saveAgentColor(sessionId, color, transcriptPath)` persistence, palette listing on invalid input, and an `isTeammate()` guard (not applicable here).

**Surface what changes:** Our current `/color` (`repl_commands.zig:752-756`) toggles `ui_color_enabled` on/off. That is a different feature. zcode has no agent-color/swarm-identity concept and the ANSI-toggle is genuinely useful. Recommended: keep the ANSI on/off behavior reachable under a clearer name (e.g. `/color on|off`) and add the palette behavior as `/color <palette-name>`. Confirm whether the prompt bar can carry a per-session accent before committing - if the bar renderer cannot accept a color, this drops to "document the divergence". Flag this dependency in the plan.

**Target Zig files:**
- New deep module `src/core/agent_color.zig` (pure: palette list, name validation, reset-alias check). Register it in the `src/main.zig` comptime block. Import via `@import("zcode_runtime")` only where it needs runtime state.
- `src/repl_commands.zig` (rewrite the `/color` handler at `:752-756` to parse the arg, validate against the palette, persist).
- `src/agent_runtime.zig` (add a `prompt_bar_color: ?[]const u8` session field if the prompt bar can render it).
- Persistence: write the color to the session sidecar (reuse the label-sidecar pattern at `runtime.store.setLabel` / `repl_commands.zig:1718`) so it survives restart.
- `cli/repl.zig` / prompt-bar renderer (apply the accent if the bar supports color).

**Approach step-by-step:**
1. Define `AGENT_COLORS` (mirror the reference palette) and `RESET_ALIASES` in `core/agent_color.zig`; pure functions `isValid(name)`, `isReset(name)`, `paletteCsv(alloc)`.
2. Rewrite `/color` handler: no arg or invalid -> return "Please provide a color. Available colors: <palette>, default"; reset alias -> clear stored color, return "Session color reset to default"; valid -> persist via the sidecar store, set `runtime.prompt_bar_color`, return "Session color set to <name>".
3. If the prompt bar can render color, apply `runtime.prompt_bar_color` when drawing the bar in `cli/repl.zig`.
4. Re-home the old ANSI toggle as `/color on|off` so it is not lost.

**Acceptance criteria:**
- Write a test that `/color blue` persists "blue" to the session sidecar and a subsequent read returns it; `/color reset` clears it; `/color notacolor` returns a message containing the palette CSV. Make it pass.
- Pure-module test: `agent_color.isValid("blue")`, `agent_color.isReset("gray")`, palette CSV contents.

**Test strategy (tools/test_runner.zig):** Pure-module tests need no IO. Persistence test uses a `tmpDirPath` store. Runs under the custom runner.

**Risk + 0.16 footguns:** Low. The main risk is the prompt-bar renderer not supporting per-session accent - if so, persist+report only and document that the visual accent is not yet wired. Keep allocations through `std_io.StringBuilder`. No process/IO footguns.

**Size:** M.

---

### Task 04 (commands-sweep-04): /resume (no args) opens the interactive selector + reloads

**Goal:** Bare `/resume` opens the interactive session selector (the same one bound to Ctrl+X S), and selecting a session reloads it into the live REPL. `/resume <id>` keeps working. Add the `continue` alias.

**Reference behavior + file:line:** `/Users/example/Downloads/claude-code-main/src/commands/resume/index.ts:1-13` (`type:'local-jsx'`, `name:'resume'`, alias `['continue']`, `argumentHint:'[conversation id or search term]'`); `resume.tsx:1-40` opens a `LogSelector`, supports agentic/custom-title search and cross-project resume, and `loadFullLog` reloads the message log.

**Target Zig files:**
- `src/repl_commands.zig` (the `/resume` handler at `:318-320` currently returns a static hint; it cannot itself open a UI overlay because dispatch returns a string. The fix is to make bare `/resume` return a sentinel that `cli/repl.zig` intercepts to launch the overlay - mirror how `/rewind` routes to `runRewindSelectorUi` and `__rewind_apply`).
- `src/cli/repl.zig` (intercept the bare-`/resume` sentinel and call `runSessionSwitcherUi` at `:4691`, which already constructs `/resume <selected_id>` at `:4733/4738`).
- Reuse `cli/repl_overlay.zig:runSessionSwitcherOverlayLoop` (`:3074`) unchanged - it already filters by id/label/updated_summary and handles backspace/char input (`:3091-3137`).

**Approach step-by-step:**
1. Change bare `/resume` (and `/continue` alias) handling so the REPL loop (not the string-returning dispatcher) detects it and invokes `runSessionSwitcherUi`. Follow the exact pattern `/rewind` uses: `cli/repl.zig:3521 runRewindSelectorUi` routes through a `__rewind_apply` sentinel.
2. `/resume <id>` (with arg) keeps the existing direct-reload path (already wired; the switcher itself constructs `/resume <id>` at `repl.zig:4738`).
3. Add `continue` alias in the canonical/alias layer.
4. Update `repl_help.zig` so `/resume` documents the interactive selector (the Ctrl+X S help string at `repl_help.zig:272` already exists; add the `/resume` form).

**Acceptance criteria:**
- Write a test that the bare-`/resume` dispatch produces the selector-launch sentinel (not the static usage string) and that `/resume <id>` still routes to direct reload. Make it pass.
- Manual: typing `/resume` opens the interactive picker; arrow + Enter reloads the chosen session; typing filters the list.

**Test strategy (tools/test_runner.zig):** Unit-test the dispatch decision (sentinel vs direct id) at the string level - no TTY needed. The overlay loop itself is interactive; cover its filter logic with the existing `repl_overlay` tests if present, otherwise add a filter-function test that feeds a fixed session list and a filter string and asserts the matched subset.

**Risk + 0.16 footguns:** Medium. The interactive overlay reads from stdin via `core/std_io.zig`; tests must not invoke the loop directly. Keep the testable seam at the dispatch-decision and the filter function. Ensure the sentinel name does not collide with an existing `__`-prefixed internal command (grep `"__` in `repl_commands.zig`).

**Size:** M.

---

### Task 05 (commands-sweep-05): /rewind restores code AND conversation

**Goal:** `/rewind` (alias `/checkpoint`) offers to restore the CODE and/or conversation to a previous point, rolling back the working tree (git patches + file copies + untracked) in addition to truncating history.

**Reference behavior + file:line:** `/Users/example/Downloads/claude-code-main/src/commands/rewind/index.ts:1-14` (description "Restore the code and/or conversation to a previous point", alias `['checkpoint']`, `type:'local'`); `rewind.ts:1-13` calls `context.openMessageSelector()` and ties into file checkpointing so the working tree is rolled back, not just messages.

**Target Zig files:**
- `src/repl_commands.zig` (`handleRewindToHistoryIndex` at `:4260-4281` and `handleRewind` at `:5617-5643` currently truncate in-memory history only and print "Session snapshot on disk is unchanged").
- Reuse the EXISTING code-restore chain (already used by `/session restore`): `agent_runtime.zig:restoreCheckpoint` (`:565`) -> `agent_history.zig:restoreCheckpointImpl` (`:1208-1270`) -> `session/bundles.zig:undoToCheckpoint` (`:175-206`) -> `restoreCheckpointWorkspace` (`:413-428`) -> `restoreGitWorkspace` (`:522-557`) + `restoreFileWorkspace` (`:559+`).
- `src/cli/repl.zig` (`runRewindSelectorUi` at `:3521+` and the `__rewind_apply` route) to offer a code-and-conversation choice.

**Approach step-by-step:**
1. The genuine gap is that `/rewind` never invokes the workspace-restore chain. To roll code back to a rewind point, a checkpoint must exist at (or be derivable from) that history index. Decision to surface: either (a) require `/rewind` to map a selected history index to the nearest prior checkpoint and call `runtime.restoreCheckpoint`, or (b) auto-snapshot the workspace whenever a checkpoint-eligible turn completes so any rewind target has a corresponding workspace state. Option (a) is far smaller and reuses everything; recommend (a) for this phase and flag (b) as a follow-up.
2. Extend `runRewindSelectorUi` / the `__rewind_apply` sentinel to carry a "restore code too" flag (mirror the reference's code-and/or-conversation choice; default conversation-only to avoid surprising destructive file changes).
3. When the flag is set, after truncating history, resolve the target to a checkpoint id and call `runtime.restoreCheckpoint(id)` (the chain at `bundles.zig:413-557` already restores git + files).
4. Update the "Session snapshot on disk is unchanged" message at `repl_commands.zig:4279` to reflect whether code was restored.

**Acceptance criteria:**
- Write a test: create a checkpoint, modify a tracked file and add an untracked file in a tmp git workspace, run the code-restore path, assert the tracked file is reverted and the untracked file removed (reuse the existing `undoToCheckpoint` / `restoreFileWorkspace` test fixtures). Make it pass.
- Write a test that conversation-only `/rewind` still leaves the workspace untouched (default path).

**Test strategy (tools/test_runner.zig):** Use `core/test_helpers.zig tmpDirPath` to get a real absolute workspace, `git init` it in the test (via `std.process.run` with the tmp path as `.{ .path = ... }` cwd), create a checkpoint, mutate files, restore, assert. The bundles layer already has restore tests to model on.

**Risk + 0.16 footguns:** Highest in this phase (L). Destructive file operations: guard behind explicit choice, default to conversation-only. 0.16 footguns: `std.process.Child.init` is gone (use `std.process.run`/`spawn`); `Child.Cwd` is a union (`.{ .path = "..." }`); after `Child.kill(io)` do NOT call `wait()`. `std.fs.path.relative` now takes 5 args `(gpa, cwd, environ_map, from, to)` if used for patch paths. The restore chain already handles these; new code mostly orchestrates existing calls.

**Size:** L.

---

### Task 06 (commands-sweep-06): /btw runs a non-interrupting side-question

**Goal:** `/btw <question>` runs a one-shot model call using the current conversation context WITHOUT appending the question or answer to the main transcript, and renders the answer (modal in the reference; a returned block is acceptable for zcode).

**Reference behavior + file:line:** `/Users/example/Downloads/claude-code-main/src/commands/btw/index.ts:1-14` (`immediate:true`, `argumentHint:'<question>'`, "Ask a quick side question without interrupting the main conversation"); `btw.tsx` (`runSideQuestion`, `BtwSideQuestion` scrollable modal, `getLastCacheSafeParams`); `/Users/example/Downloads/claude-code-main/src/utils/sideQuestion.ts` uses `runForkedAgent` to reuse parent prompt-cache while keeping the response out of the main conversation.

**Surface what changes:** Our `/btw` is a static easter-egg string at `cc_stub_commands.zig:14`, dispatched at `repl_commands.zig:168`, appended to the transcript at `repl.zig:746`. It must be removed from the stub table and given a real handler.

**Target Zig files:**
- New deep module `src/core/side_question.zig` (build the side-question prompt from current context, call the model, return text). Register in `src/main.zig` comptime block; import runtime via `@import("zcode_runtime")`.
- `src/repl_commands.zig` (add a real `/btw <question>` handler; parse the question, call the side-question path).
- `src/core/cc_stub_commands.zig` (delete the `/btw` easter-egg entry at `:14`).
- `src/agent_runtime.zig` (reuse `handlePrompt`/`handlePromptDetailed` at `:652-679`; add a "do not append to history" variant if none exists - the simplest implementation snapshots history, runs a normal turn, then restores/truncates so nothing persists).

**Approach step-by-step:**
1. Delete `/btw` from `cc_stub_commands.zig` so dispatch falls through to the new handler.
2. Add `/btw <question>` handler: if no question, return usage. Otherwise run the model with current context but isolate the result.
3. Isolation approach (simplest that satisfies "does not interrupt the main transcript"): snapshot the in-memory history length, run a normal `handlePrompt` turn for the question, capture the answer, then truncate history back to the snapshot (the same truncation primitive `/rewind` uses at `repl_commands.zig:4260`). Do NOT persist the side turn to the session jsonl. Verify the truncation does not clobber the disk snapshot (it must not append - mirror the `/clear` in-memory-only semantics).
4. Return the answer text (modal rendering is a TUI nicety; a plain returned block is acceptable parity for zcode's text surface - note the divergence).

**Acceptance criteria:**
- Write a test using a stub/fake provider (the test runner can stub model calls) that `/btw what is 2+2` returns a non-empty answer AND the persisted session history length is unchanged before vs after. Make it pass.
- Write a test that bare `/btw` returns the usage string.

**Test strategy (tools/test_runner.zig):** Use the existing fake-provider test harness if present (grep for how `handlePrompt` is tested). Assert history-length invariance around the call. No real network.

**Risk + 0.16 footguns:** Medium. The isolation-by-truncate approach must not desync the disk transcript - verify against the `/clear` semantics that already keep disk untouched. Avoid the `ObjectMap.put` pointer-desync footgun if building JSON request bodies (take `&parsed.value.object` by pointer). Cache-safety (reusing parent cache) is a nice-to-have, not a parity blocker; document if not implemented.

**Size:** M.

---

### Task 08 (commands-sweep-08): /effort persistence + env override

**Goal:** `/effort low|medium|high|max|auto` persists `effortLevel` across restarts, honors a `CLAUDE_CODE_EFFORT_LEVEL` env override (env wins, with a note), and distinguishes session-only vs persisted in its output. `auto` shows the resolved level.

**Reference behavior + file:line:** `/Users/example/Downloads/claude-code-main/src/commands/effort/effort.tsx:16-83` - `toPersistableEffort`, `updateSettingsForSource('userSettings', { effortLevel })`, `getEffortEnvOverride` reading `process.env.CLAUDE_CODE_EFFORT_LEVEL`, `showCurrentEffort` resolving auto for the model, and the env-conflict message ("CLAUDE_CODE_EFFORT_LEVEL=X overrides this session - clear it and Y takes over"; session-only suffix " (this session only)").

**What is already at parity:** Core set/show of low/medium/high/max/auto with descriptions and the level ladder (`repl_commands.zig:4680-4721`) matches; the effort->thinking-budget RENAMES note is honored. Only persistence + env override + session-vs-persisted messaging are missing.

**Target Zig files:**
- `src/core/config.zig` / `src/core/config_parse.zig` (add an `effort_level` (or reuse `reasoning_effort`) persisted field; write-back on `/effort`).
- `src/repl_commands.zig` (`handleEffortSet` at `:4704-4721`, `renderEffortStatus` at `:4680-4702`).
- Env read via `init.environ_map` threaded through runtime (or `core/env_registry.zig` which already exists at `:1032`).

**Approach step-by-step:**
1. Add `CLAUDE_CODE_EFFORT_LEVEL` to the env-var handling. Resolve precedence: env override > persisted setting > model default. Store the env value once at startup.
2. In `handleEffortSet`: after setting `runtime.reasoning_effort`, persist `effort_level` to the config/settings file (mirror how other config writes happen; `/config` already persists settings). Return "Set effort level to X" with " (this session only)" suffix when not persistable, plus the env-conflict note when `CLAUDE_CODE_EFFORT_LEVEL` differs from the requested level.
3. In `renderEffortStatus`: when env override is active, show it and that it overrides the session value; for `auto`, show the resolved level.
4. On startup, load persisted `effort_level` (unless env overrides).

**Acceptance criteria:**
- Write a test: set `CLAUDE_CODE_EFFORT_LEVEL=high` in the test env, run `/effort low`, assert the returned message contains the override note and that the resolved effort is `high` not `low`. Make it pass.
- Write a test: with no env var, `/effort medium` persists to the settings file; a fresh runtime load reads `medium` back.
- Write a test: `/effort medium` output contains neither " (this session only)" when persistable nor the env note when no conflict.

**Test strategy (tools/test_runner.zig):** Set env via the runtime's environ map (the runner installs `rt`); use `tmpDirPath` for the settings file location so persistence round-trips without touching the real config. Pure precedence logic (env > persisted > default) can be a standalone tested function.

**Risk + 0.16 footguns:** Low. `std.process.getEnvMap` is gone - read from `init.environ_map` / the threaded environ. `Environ.Map.remove` is gone (use `swapRemove`) if mutating. Keep the precedence function pure for testability.

**Size:** S.

---

### Task 09 (commands-sweep-09): /status live API-connectivity probe + MCP/tool health rollup

**Goal:** Append to the existing `/status` text dump a live API-connectivity result and a per-MCP-server/tool health summary. Account info stays out of scope (auth-gated).

**Reference behavior + file:line:** `/Users/example/Downloads/claude-code-main/src/commands/status/index.ts:1-12`; `status.tsx` opens the Settings component on the `Status` tab showing version, model, ACCOUNT, API connectivity, and per-tool statuses (IDE/MCP health).

**What is already at parity:** The text dump (`repl_commands.zig:758-835`) covers provider, model, version, config, sandbox, timeouts, UI settings, token metrics, preprocessor. The comment at `repl_commands.zig:5494` correctly notes we use plain text (no Ink UI). Account is intentionally out of scope.

**Target Zig files:**
- `src/repl_commands.zig` (`/status` handler at `:758-835`; add two sections at the end).
- Reuse existing diagnostics: `/doctor` (`repl_commands.zig:1530`, `:2884`) and `/bridge` already probe some of this; factor a shared probe helper if `/doctor` has one.
- MCP health: reuse the MCP bridge/server registry that `/mcp` reads.

**Approach step-by-step:**
1. Add a live API-connectivity probe: a short, timeout-bounded request to the configured provider base URL (or a cheap models/health endpoint). Report `api_connectivity=ok|fail (<reason>)` and round-trip latency. Reuse `/doctor`'s probe if it has one to avoid duplication.
2. Add an MCP/tool health rollup: iterate configured MCP servers and report connected/failed + tool count per server. Reuse the registry `/mcp` enumerates.
3. Keep account out (document it as auth-gated).

**Acceptance criteria:**
- Write a test that `/status` output contains an `api_connectivity=` line and an `mcp_servers=` (or per-server) section. Use a fake/unreachable provider to assert the `fail` branch renders without panicking. Make it pass.
- Manual: with a reachable provider, `/status` shows `ok` + latency; with MCP servers configured, shows their health.

**Test strategy (tools/test_runner.zig):** Point the provider base URL at an unreachable local address to exercise the timeout/fail path deterministically; assert the line is present and the command returns (does not hang). Bound the probe with `Io.Timeout`.

**Risk + 0.16 footguns:** Medium. Network probe must be timeout-bounded so `/status` never hangs. `Io.Timeout.duration` wraps `Io.Clock.Duration` (`{ .raw, .clock }`). For any subprocess-based probe, use `std.process.run` and the `.{ .path = ... }` cwd union. Do not block the REPL on a slow provider.

**Size:** M.

---

## Documented deviations (out-of-scope)

These are confirmed out-of-scope; the action items are documentation and small honesty fixes, not features.

### /passes (commands-sweep-10) - referral program, cloud
**What:** `/passes` is the Anthropic referral UI (share a free week, earn usage), gated by `checkCachedPassesEligibility`/`getCachedReferrerReward` against Anthropic's referral API (`/Users/example/Downloads/claude-code-main/src/commands/passes/index.ts:1-27`).
**Why out of scope:** Depends on Anthropic's account/referral backend zcode does not run. No meaningful local equivalent.
**Action worth doing (small, honesty fix):** The stub at `src/core/cc_stub_commands.zig:27` is factually WRONG - it says "The compiler-passes view is Anthropic-internal and not applicable to zcode." Replace with an accurate message: `/passes` is Claude Code's referral program (share a free week of Claude Code), which requires Anthropic's account/referral service that zcode does not run. This is a one-line table edit; include it in this phase.

### /desktop, /mobile (commands-sweep-11) - handoff / pairing, cloud bridge
**What:** `/desktop` (alias `/app`, macOS+win64) hands the session off to the Claude Desktop app; `/mobile` (aliases `/ios`, `/android`) shows QR codes to download/pair the Claude mobile app (`/Users/example/Downloads/claude-code-main/src/commands/desktop/index.ts:1-27`, `mobile/index.ts:1-12`).
**Why out of scope:** Session handoff/pairing needs the Anthropic cloud bridge (locked out-of-scope decision: cloud-only remote/bridge backends).
**Actions worth doing:**
- Add the missing aliases for surface parity: `/app` -> `/desktop`, `/ios` and `/android` -> `/mobile`, in `src/core/command_canonical.zig` (or wherever aliases resolve) so the stub message is reachable under all reference names. Small, in this phase.
- HONEST note: `/mobile`'s QR half (render a static App Store / Play Store download URL as a QR code) needs no cloud and IS locally feasible; only the session-pairing half needs the bridge. Optional follow-up, not required for this phase. `/desktop` genuinely needs the desktop app integration.

### /grove (commands-sweep-12) - data-sharing / training-consent, OAuth phone-home
**What:** Grove is the account data-sharing / training-consent ("NEW TERMS") opt-in/opt-out flow driven by Anthropic's account-settings API via OAuth (`/Users/example/Downloads/claude-code-main/src/services/api/grove.ts:1-40`, `components/grove/Grove.tsx:1-14`). It is NOT in the reference `COMMANDS()` registry - there is no `/grove` slash command.
**Why out of scope:** Auth/account + first-party data-sharing-consent phone-home. zcode is local-only with no telemetry, so there is nothing to consent to. The existing `/privacy-settings` stub (`src/core/cc_stub_commands.zig:31`) already states this correctly.
**Action:** Document only. No command to add (it is not a command). No change needed; this entry exists to keep the out-of-scope picture honest.

### /thinkback (commands-sweep-07) - reasoning trace viewer vs YIR plugin (documentation, in this phase)
**What:** Reference `/think-back` (name `think-back`, statsig-gated `tengu_thinkback`) installs/launches the `thinkback` marketplace plugin = "Your 2025 Claude Code Year in Review" (plugin install + skill launch, animation player, video export) (`/Users/example/Downloads/claude-code-main/src/commands/thinkback/index.ts:1-15`, `thinkback.tsx`). Our `/thinkback` (`repl_commands.zig:1699-1706`, `renderThinkback` at `:5645-5708`) is a local reasoning-trace viewer.
**Why not ported:** The reference feature depends on the plugin marketplace + a gimmick yearly-aggregation plugin (cloud/marketplace dependency). zcode's local trace viewer is more useful locally.
**Action worth doing (small):** Document the name/semantics divergence in the wiki. Note that the reference command name is `think-back` (hyphenated) and zcode registers `/thinkback` (no hyphen) with different semantics; if surface-name parity matters, add `think-back` as an alias to our trace viewer so the reference spelling is recognized (it currently is not). Decide with the user whether to add the alias; it is a one-line change.

## Verification

Per the project CLAUDE.md, every change ends with a build + install + manual check.

1. **Version bump:** Bump `.version = "X.Y.Z"` in `build.zig.zon` (patch bump; `build.zig` appends the git short-hash automatically - do not touch `computeVersionString`).

2. **Build (ReleaseFast):**
   ```
   zig build -Doptimize=ReleaseFast
   ```
   Use the pinned toolchain `/Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig` (stock homebrew zig is 0.15.x and will fail).

3. **Run the full test suite (custom runner):**
   ```
   zig build test
   ```
   New tests: `removed_commands` (insights un-removal), `agent_color` (palette/reset/persist), `/branch` fork, `/resume` dispatch sentinel, `/rewind` code-restore + conversation-only, `/btw` history-invariance, `/effort` env-override + persistence round-trip, `/status` api-probe fail-path + MCP rollup. All run under `tools/test_runner.zig` (prints `RUN: <name>`, installs `rt.io`/`rt.gpa`).

4. **Install (avoid the macOS in-place codesign footgun):**
   ```
   rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode
   ```
   The `rm -f` first is mandatory so a fresh inode gets a valid ad-hoc signature (in-place overwrite -> SIGKILL "Killed: 9" on next run).

5. **Manual checks (in a live REPL):**
   - `/insights` -> renders the stats/insights report (NOT "unknown command").
   - `/branch` and `/fork` -> fork the conversation into a new session id.
   - `/color blue` then restart -> color persists; `/color reset` -> back to default; `/color notacolor` -> lists the palette.
   - bare `/resume` -> opens the interactive selector; pick one -> session reloads; type -> filters. `/resume <id>` -> direct reload.
   - `/rewind` -> offers conversation-only by default; the code-and-conversation option reverts tracked + untracked files.
   - `/btw what is 2+2` -> returns an answer; session history length unchanged afterward.
   - `CLAUDE_CODE_EFFORT_LEVEL=high zcode`, then `/effort low` -> message notes the env override and resolves to `high`; restart preserves a persisted `/effort medium`.
   - `/status` -> shows `api_connectivity=` (ok+latency or fail) and an MCP/tool health rollup.
   - `/passes` -> accurate referral-program message (no "compiler-passes view").
   - `/app`, `/ios`, `/android` -> reach the desktop/mobile stub messages.

6. **Wiki checkpoint:** Record in the project wiki the misclassification lessons from this sweep: (a) a present handler can be unreachable behind `removed_commands.isRemoved` (dead-code parity defect class); (b) same-name namespace collisions (`/branch` git-vs-fork, `/color` toggle-vs-palette) are a distinct defect class the coarse sweep misses; (c) stub text can be factually wrong (`/passes`) and is itself a parity defect. Add to the global wiki the transferable note that a "command recognized" signal is not "command at parity" - always resolve to present-equivalent / present-different / stub / dead-code / missing.
