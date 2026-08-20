# Phase 11: Sessions and state: code-restoring rewind, fuzzy resume, session search, metadata, AI titles, export richness

## Overview

**What.** This phase closes nine verified gaps in zcode's session and state subsystem. The headline feature (sessions-01) unifies the two restore paths that exist today but are disconnected: the interactive rewind picker (conversation-only, in-memory) and the workspace-bundle checkpoint system (code restore, separate command). The reference's `MessageSelector` lets a user pick a prior user message and choose to restore code, conversation, or both, keyed to a per-message UUID, with diff-stat preview. To do that, zcode needs per-turn UUIDs in the JSONL, per-message file-history snapshots, a restore-scope menu in the overlay, and a diff-stat counter. Around that headline sit eight supporting gaps: fuzzy `/resume <arg>` resolution and the interactive picker fallback (sessions-02); LLM-powered agentic session search across metadata and transcript (sessions-03); a documented behavioral deviation on cross-project resume (sessions-04); richer Markdown/text export plus a first-prompt-derived default filename (sessions-05); AI-generated session titles persisted as a distinct record type with user-rename precedence (sessions-06); persisted git-branch / first-prompt / PR-link metadata (sessions-07); a consistency-check and orphan-cleanup pass on resume once rewind writes to disk (sessions-08); and the prompt-history `removeLast` + restore-on-interrupt behavior (sessions-12).

**Why.** zcode already has strong building blocks: an append-only encrypted JSONL store with snapshots, sidecar labels and tags, a workspace-bundle checkpoint/undo system, a fuzzy scorer (`session_search.zig`), a session-switcher overlay, a Markdown exporter, and a global prompt-history file with paste-reference expansion. The problem is that several of these are either dead code (the fuzzy scorer is `_ = @import` only), unwired (export ignores the rich REPL formatting), or deliberately conversation-only (the rewind picker explicitly says "Session snapshot on disk is unchanged"). This phase wires the existing pieces together and adds the missing core data: per-turn UUIDs and per-message file snapshots are the linchpin that unblocks sessions-01 and sessions-08, while sessions-02/03/06/07 mostly need plumbing into the picker and search.

**Dependencies.** Depends on Phase 7 (agent-loop / sub-agent spawn machinery, reused for the AI-title generation `sideQuery` in sessions-06) and Phase 8 (compaction LLM summarization wiring; the title generator reuses the `compaction.zig` summarizer-prompt and provider-call pattern, and sessions-07's `summary` field overlaps with `conversation_summary`). Both are assumed complete.

**Effort.** XL. sessions-01 is L (new data model + new file-snapshot module + overlay rework). sessions-04 is documentation-only (the cross-project concept does not apply to zcode's global session model). The remaining gaps are M/S and are largely independent of each other, so they partition cleanly across parallel agents once sessions-01's data-model changes (the per-turn `uuid` field on `HistoryTurn`) land first. Recommended ordering: land the `HistoryTurn.uuid` + JSONL `uuid` field change first (it touches `core/types.zig` and `session/store.zig`, which several tasks read), then fan out sessions-02, sessions-03, sessions-05, sessions-06, sessions-07, sessions-12 in parallel, then sessions-01's snapshot/overlay work, then sessions-08 (which depends on sessions-01 writing to disk).

## Gaps covered

| id | title | severity | size | our current state |
|---|---|---|---|---|
| sessions-01 | Rewind picker does not restore code; no per-message file snapshots | high | L | Partial. Rewind picker truncates in-memory conversation only (`repl_commands.zig:4260`); explicitly leaves disk unchanged. No per-turn UUID (`HistoryTurn` has role/content/timestamp only), no per-message file snapshots, no restore-scope menu, no diff stats. Code restore lives in the separate bundle checkpoint system (`session/bundles.zig:175`). |
| sessions-02 | Resume-by-argument and resume picker do not match by title/fuzzy term | medium | M | Partial. `session_search.zig` fuzzy scorer exists but is dead code. `/resume <arg>` is exact-UUID only (`repl_commands.zig:261`); `/resume` with no arg returns a usage string instead of opening the picker; switcher uses substring `containsFilter` not `fuzzyScore`. |
| sessions-03 | No agentic (LLM-powered) session search across metadata + transcript | low | M | Absent. Only substring filtering on id/label/updated_summary. No `logContainsQuery` (transcript pre-filter), no full-transcript load, no LLM ranking, no session-list prompt. |
| sessions-04 | No cross-project / worktree-aware resume | low | S (doc) | Absent by design. zcode sessions are global (flat `sessions_dir`), not per-project; no `projectPath` is stored, and resuming any session in any cwd already works. Documented as a deviation, with an optional minimal `projectPath` breadcrumb. |
| sessions-05 | Markdown/text export does not render tool calls/results richly | medium | M | Partial. REPL renders tool blocks richly and persists ANSI-stripped formatted text to the transcript, but export reads raw `turn.content` (artifact wrapper / raw text), losing structure. Default filename is the static `session-export.md`, not derived from the first prompt. |
| sessions-06 | No AI-generated / auto session title | low | M | Absent. User labels via `/rename` are the manual equivalent of custom-title (sidecar `.label`). No AI-title generation, no distinct `ai-title` record, no custom-vs-AI precedence, no `getCurrentSessionTitle`. |
| sessions-07 | No git-branch / first-prompt / PR-link metadata stored per session | low | M | Absent. git branch detected at runtime then discarded (`session_mgmt.zig:245`); first prompt passed as REPL option but never persisted; no PR-link mechanism. Tags + `conversation_summary` do exist. |
| sessions-08 | No resume-consistency / conversation-chain orphan handling | low | M | Absent. Snapshot-based reconciliation on resume, not UUID parent-chain. No per-message UUID parentage, no `buildConversationChain`, `checkResumeConsistency`, or `removeTranscriptMessage`. Largely a consequence of the flat model; only matters once rewind writes to disk (sessions-01). |
| sessions-12 | Global prompt history with paste-reference expansion is local-only / partial | low | S | Mostly present. Global `~/.claude/prompt-history.jsonl` (workspace-scoped, deduped), paste-ref format `<@image:N>`/`<@paste:N>` with expansion on recall, all implemented and tested. Missing: `removeLastFromHistory()` and auto-restore-on-interrupt. |

Survey-accuracy notes after reading both trees:

- **sessions-12 is over-reported as a gap.** The corrected status is accurate: everything except `removeLastFromHistory` + restore-on-interrupt already exists and is tested (`src/cli/repl.zig:7971`). This task is genuinely S and is mostly a small append + an interrupt-path hook. Downgraded confirmation: the paste-reference *expansion* the title implies is missing is in fact present (`materializePromptForInput`, `src/cli/repl.zig:1815`).
- **sessions-04 does not directly apply.** zcode's `Store` lists every `.jsonl` in one flat `sessions_dir` (`session/store.zig:341`); there is no per-project tree, so "this conversation is from a different directory" has no analog. The reference's whole mechanism (`crossProjectResume.ts`) exists to bridge per-project log directories. This task is reduced to: (a) a documented behavioral-deviation note, and (b) an optional cheap breadcrumb (persist `cwd` on first turn) so a future picker can *display* origin, without any blocking/clipboard machinery. Marked S and mostly documentation.
- **sessions-01, 02, 03, 05, 06, 07, 08 are confirmed real gaps.** The fuzzy scorer is verifiably dead (`src/main.zig:104` is the only reference). The export verifiably reads `turn.content` (`session_cmds.zig:299`, `repl_commands.zig:2576`). The rewind handler verifiably says "Session snapshot on disk is unchanged" (`repl_commands.zig:4279`).

## Implementation tasks

Reusable primitives this phase leans on (verified present):
- Session store + JSONL append/load: `src/session/store.zig` (`appendTurn` :108, `appendSnapshot` :131, `load` :161, `list` :341, sidecars `setLabel`/`readLabel` :543/:518, `setTags`/`readTags` :438/:411).
- Turn model: `src/core/types.zig:102` (`HistoryTurn`), `:194` (`SessionSnapshot`).
- In-memory history ops: `src/agent_history.zig` (`truncateFrom` :193, `replaceWith` :206, `clearInMemory` :186, `view`/`at`/`len`).
- Workspace capture/restore: `src/session/bundles.zig` (`saveCheckpoint` :130, `undoToCheckpoint` :175, `restoreCheckpointWorkspace` :413, `captureGitWorkspace` :430, `captureFileWorkspace` :493, `WorkspaceFileEntry` :77).
- Fuzzy scorer: `src/core/parse_helpers.zig` (`fuzzyScore`), wrapped by `src/core/session_search.zig` (`search`).
- Rewind picker backend + overlay: `src/repl_commands.zig` (`renderRewindPickerData` :4222, `handleRewindToHistoryIndex` :4260, dispatch :986); `src/cli/repl_overlay.zig` (`runMessageSelectorOverlayLoop` :4249, `runSessionSwitcherOverlayLoop` :3074).
- Session overlay backend: `src/repl_commands.zig:3597` (`renderSessionsOverlayData`).
- Markdown export: `src/core/session_export_md.zig` (`toMarkdown` :20).
- REPL export command: `src/repl_commands.zig:2247` (`/export`), `exportSession` :2564; CLI export `src/session_cmds.zig:282` (`cmdSessionExport`).
- LLM summarizer prompt + provider call: `src/core/compaction.zig:7-16` (summarizer system prompt), `maybeCompact`.
- Sub-agent / sideQuery template (for AI title): the `maybeRunDream` pattern referenced in Phase 10 (`src/agent_runtime.zig`).
- Git branch detection: `src/session_mgmt.zig:158` (`detectGitBranch`).
- Global prompt history: `src/cli/repl_history.zig` (`appendPrompt` :24, `buildSearchItems` :72); paste refs `src/cli/repl_attachments.zig`; recall expansion `src/cli/repl.zig:1815` (`materializePromptForInput`).
- Module registration rule: add every new `core/` module to the `comptime { _ = @import(...) }` block in `src/main.zig:41` so the custom test runner discovers its tests.
- Runtime: import `@import("zcode_runtime")` for `rt.io`/`rt.gpa`; use `core/clock.zig` for time, `core/rng.zig` for the UUID nonce.

---

### Task 11.0: Add per-turn UUID to the turn model and JSONL (foundation for 01/08)

**Goal.** Give every history turn a stable UUID, persisted in the JSONL, so rewind snapshots and consistency checks can key off a message instead of an array index.

**Reference behavior.** Every message has a `uuid` (and a `parentUuid` chain); `MessageSelector` keys restore on `message.uuid`; `fileHistoryRewind(state, messageId)` finds the snapshot `messageId === uuid`. Ref: `components/MessageSelector.tsx:60,77`; `utils/fileHistory.ts:347,367`; `utils/sessionStorage.ts:2069` (`buildConversationChain`).

**Target Zig files.**
- Edit `src/core/types.zig` (`HistoryTurn` at :102): add `uuid: []const u8 = ""` (default empty for backward compat) and optionally `parent_uuid: []const u8 = ""`.
- Edit `src/session/store.zig`: `appendTurn` (:108) emits `uuid`; `load` (:244-257) reads `uuid` (defaulting to "" / a synthesized id for legacy records); `LoadedSession.deinit` (:36) frees the new field.
- Edit `src/agent_history.zig`: `append`/`replaceWith`/`truncateFrom` must dup/free `uuid`. Add a `genUuid` helper (reuse the 128-bit hex nonce pattern from `store.createSessionId` :89, factored into a shared `core/uuid.zig`).
- Create `src/core/uuid.zig`: a tiny deep module `pub fn v4Hex(buf: *[36]u8) void` / `pub fn allocV4(allocator) ![]u8` using `rng.secureBytes`. Register in `src/main.zig:41` comptime block.

**Approach.**
1. Factor the existing 128-bit hex nonce generation out of `store.createSessionId` into `core/uuid.zig` (`allocV4` returns the canonical 8-4-4-4-12 dashed form; keep a raw-hex variant if simpler). Have `createSessionId` call it.
2. Add `uuid: []const u8 = ""` to `HistoryTurn`. Because it defaults to "", all existing constructors keep compiling; only the append path needs to populate it.
3. In `appendTurn`, take an optional `uuid` param (or generate one inside and return it) and add `.uuid = uuid` to the JSON record. The append signature is called from `agent_runtime`; thread a generated UUID so the in-memory turn and the on-disk record share it.
4. In `load`, read `getString(obj, "uuid")` defaulting to "" when absent (legacy files). Dup into the owned turn; free in `LoadedSession.deinit`.
5. In `agent_history`, every place that dups `content` must also dup/free `uuid`. The `truncateFrom`/`replaceWith`/`clearInMemory` loops free `content`; add the `uuid` free next to each.

**Acceptance criteria.**
- Write a test in `store.zig`: append a turn with a known UUID, `load`, assert the loaded turn's `uuid` matches.
- Write a test: load a legacy JSONL line with no `uuid` field; assert `uuid == ""` and no crash.
- Write a test in `agent_history`: `append` two turns, assert distinct non-empty UUIDs; `truncateFrom(1)` then assert no leak (runs under the leak-checking test allocator).

**Test strategy.** New tests in `src/session/store.zig`, `src/agent_history.zig`, `src/core/uuid.zig`, all under `tools/test_runner.zig`. Run `zig build test`.

**Risk / footguns.** `HistoryTurn` is constructed in many places (compaction, bundles, export, tests). The `= ""` default is what keeps those compiling - do not make the field non-defaulted. `LoadedSession.deinit` frees `turn.content`; if `uuid` aliases an empty string literal (legacy ""), do not free it - only free when it was duped. Simplest: always dup (even ""), always free. Watch `bundles.zig:113` and `compaction.zig` deinit loops - they also free `turn.content` and will need the `uuid` free.

**Size estimate.** M.

---

### Task 11.1: Per-message file-history snapshots + code-restoring rewind picker (sessions-01)

**Goal.** Capture a per-message workspace snapshot keyed to the turn UUID, surface a restore-scope menu (code / conversation / both) in the rewind picker, show diff stats, and apply the chosen restore.

**Reference behavior.** `MessageSelector` offers `RestoreOption = 'both' | 'conversation' | 'code'`; `getRestoreOptions(canRestoreCode)` gates the code options on `fileHistoryCanRestore`; selecting applies `onRestoreCode` + `onRestoreMessage`; `fileHistoryGetDiffStats(state, uuid)` previews how many files would change. Ref: `components/MessageSelector.tsx:31,93-105,214-241`; `utils/fileHistory.ts:347` (`fileHistoryRewind`), `:399` (`fileHistoryCanRestore`), `:414` (`fileHistoryGetDiffStats`).

**Target Zig files.**
- Create `src/core/file_history.zig`: a deep module that captures and restores per-message file snapshots. Register in `src/main.zig:41`. Reuse `session/bundles.zig` workspace capture/restore primitives (`captureGitWorkspace` :430, `captureFileWorkspace` :493, `restoreCheckpointWorkspace` :413) rather than reinventing - the file_history module is a thin per-UUID index over bundle-style snapshots.
- Edit `src/session/bundles.zig`: expose the per-snapshot capture/restore as reusable functions taking a destination dir + UUID (today they are private and key on checkpoint id). Add `diffStats(allocator, cwd, snapshot_dir) -> DiffStats` (count of files that differ from the snapshot).
- Edit `src/repl_commands.zig`: extend `renderRewindPickerData` (:4222) to include each item's `uuid`, a `can_restore_code` bool, and diff-stat counts; replace `handleRewindToHistoryIndex` (:4260) with a handler that accepts a `RestoreOption` and applies the chosen scope.
- Edit `src/cli/repl_overlay.zig`: extend `runMessageSelectorOverlayLoop` (:4249) so that after selecting a message it presents a second-level restore-scope menu (both/conversation/code) gated on `can_restore_code`, and returns `(index, option)`.
- Edit `src/agent_runtime.zig`: at turn start (before tools mutate files), call `file_history.snapshot(uuid, cwd)`; on a `code`/`both` restore, call `file_history.restore(uuid, cwd)`.

**Approach.**
1. Snapshot model: store per-message snapshots under the session's bundle area, e.g. `~/.zcode/sessions/<id>.snapshots/<uuid>/` reusing the bundle workspace layout (git mode = staged/unstaged patch + untracked dir; file mode = files dir). The reference tracks only files the agent touched; for a first cut, snapshot the working tree the same way `saveCheckpoint` does (git-diff based in a repo, file-copy fallback otherwise). Gate behind a config flag `file_history_enabled` (default on in a repo, off if the tree is huge - mirror the reference's `fileHistoryEnabled`).
2. Capture timing: snapshot at the *start* of a user turn, keyed to that user message's UUID. This is the state the user can roll back *to*. Store an index file mapping `uuid -> snapshot_dir`.
3. `canRestoreCode(uuid)`: snapshot dir exists for that uuid.
4. `diffStats(uuid)`: count files that differ between the snapshot and the current tree (in git mode, `git diff --name-only` against the recorded HEAD + applying the patch in `--check` dry-run, or simply count entries in the captured patch/untracked set; in file mode, compare hashes). Return `{ files_changed: usize }`.
5. Overlay: after `runMessageSelectorOverlayLoop` returns a selected index, run a small inline menu (reuse `runSessionSwitcherOverlayLoop`'s key loop shape) presenting Restore code+conversation / Restore conversation / Restore code, with the code options omitted when `!can_restore_code`. Show the diff-stat line ("N files would change") for the highlighted message.
6. Apply: conversation restore = existing `truncateFrom(history_index)`. Code restore = `file_history.restore(uuid, cwd)` (apply the snapshot). Both = do both. Update the confirmation message to reflect what was restored (drop the misleading "Session snapshot on disk is unchanged" line when code was restored).

**Acceptance criteria.**
- Write a test in `core/file_history.zig`: in a tmp dir (`test_helpers.tmpDirCwd`), write a file, snapshot under uuid "A", modify the file, `restore("A")`, assert the original content is back.
- Write a test: `canRestoreCode("A")` true after snapshot, `canRestoreCode("B")` false.
- Write a test for `diffStats`: snapshot, change 2 files, assert `files_changed == 2`.
- Write a test in `repl_commands` for the new `renderRewindPickerData` payload: assert each item has `uuid` and `can_restore_code`.
- Manual: in the REPL, edit a file via a turn, open the rewind picker, pick the prior message, choose "Restore code", confirm the file reverts on disk.

**Test strategy.** Unit tests in `core/file_history.zig` and `repl_commands.zig` under `tools/test_runner.zig`. The overlay loop is interactive (stdin) so it is exercised manually plus a backend-payload test.

**Risk / footguns.**
- `Child.kill(io)` reaps internally - do not `wait()` after (CLAUDE.md gotcha) when shelling to git for capture/restore.
- `readFileAlloc(.limited(N))` returns `error.StreamTooLong`, not `FileTooBig` - handle when comparing file contents.
- Do not pass `"."`/`"repo"` as cwd to the file walker in tests - use `tmpDirCwd` (CLAUDE.md gotcha).
- Snapshot dirs grow unbounded; reuse `Store.cleanupOldSessions`-style retention or cap to the last N user turns.
- `std.fs.path.relative` now takes 5 args `(gpa, cwd, environ_map, from, to)` - if you compute relative paths for the snapshot index.
- The overlay second-menu must clear its own rows on cancel (mirror `clearSessionSwitcherOverlay`) or the transcript corrupts.

**Size estimate.** L.

---

### Task 11.2: Fuzzy `/resume <arg>` + interactive picker fallback + switcher uses fuzzyScore (sessions-02)

**Goal.** Resolve `/resume <arg>` as a UUID first, then as a fuzzy label/id search term; open the interactive picker when no arg is given; switch the picker filter from substring to `fuzzyScore`; emit `multipleMatches`/`sessionNotFound` messaging.

**Reference behavior.** `/resume <arg>` resolves arg as a UUID or a fuzzy/custom-title term (`searchSessionsByCustomTitle`), with `sessionNotFound`/`multipleMatches` results; the picker supports fuzzy search; argumentHint is `[conversation id or search term]`. Ref: `commands/resume/resume.tsx:21,23-37,213`; `utils/sessionStorage.ts:3065` (`searchSessionsByCustomTitle`).

**Target Zig files.**
- Edit `src/repl_commands.zig`: `/resume <arg>` path (:256-316) - on `store.load` failure (invalid/not-found), fall back to `session_search.search` over `store.list()` candidates; 0 matches -> not-found message with up-to-3 recent ids; 1 match -> load it; >1 -> list the matches and ask the user to disambiguate. `/resume` with no arg (:318) -> emit the `__sessions_overlay_data` trigger (or directly invoke the switcher) instead of the usage string.
- Edit `src/cli/repl_overlay.zig`: `runSessionSwitcherOverlayLoop` (:3074) - replace the three `containsFilter` calls (:3092-3094) with a `session_search.search` ranking so typing filters by fuzzy score; keep substring as the tie-break/fallback.
- Edit `src/session_cmds.zig`: `cmdSessionResume` (:83) - accept the same fuzzy fallback for the CLI `session resume <arg>` path so CLI and REPL behave identically.
- Edit `src/cli/args.zig` (:562): make the `session resume` arg optional; no-arg opens the picker (or prints the list with a hint) for the CLI.
- Wire `src/core/session_search.zig` from dead `_ = @import` into a live call.

**Approach.**
1. Build `[]session_search.Candidate` from `store.list()` (id + label). Run `search(allocator, candidates, arg)`.
2. Decision tree: exact `store.load(arg)` success -> done (UUID path, preserves current behavior). Else if `search` returns exactly one with score above a small threshold -> resume it. Else if multiple -> print "multiple sessions match '<arg>':" + the top N ids/labels and return without resuming. Else -> the existing not-found message.
3. Switcher: per keystroke, call `search` over the items and render in ranked order; map the selected display index back to the original item index.
4. No-arg REPL `/resume`: return the overlay trigger string the REPL already understands for the session switcher (look at how `__sessions_overlay_data` is dispatched), so `/resume` and the existing switcher entrypoint converge.

**Acceptance criteria.**
- Write a test driving the resume-resolution helper (factor it into a pure function `resolveResumeTarget(candidates, arg) -> enum { exact, single(id), multiple([]id), none }`): assert exact-id, single-fuzzy, multiple, and none cases.
- Write a test that the switcher ranking helper orders a "parser" query with the parser sessions first.
- Manual: `/resume parser` with one matching label resumes it; with two, prints the disambiguation list; `/resume` alone opens the picker.

**Test strategy.** Pure `resolveResumeTarget` + ranking tests in `repl_commands.zig` / `session_search.zig` under `tools/test_runner.zig`.

**Risk / footguns.** `session_search.search` allocates a `[]Ranked` the caller frees. The empty-query case returns all candidates score 0 - guard so the no-arg path opens the picker rather than "resuming the first of everything". Keep the exact-UUID fast path first so a literal id never gets fuzzy-hijacked by a label that happens to contain the same chars.

**Size estimate.** M.

---

### Task 11.3: Agentic (LLM-powered) session search across metadata + transcript (sessions-03)

**Goal.** Add an optional LLM-ranked session search that pre-filters sessions whose metadata or transcript contains the query, loads transcripts for matches, builds a session-list prompt, and asks the fast model for relevant indices.

**Reference behavior.** `agenticSessionSearch` pre-filters via `logContainsQuery` (title/customTitle/tag/branch/summary/firstPrompt/transcript), loads full transcripts, builds a session-list prompt, asks the small/fast model for relevant indices, biased inclusive. Ref: `utils/agenticSessionSearch.ts:15-48` (system prompt), `:113-140` (`logContainsQuery`), `:146-307`; wired at `commands/resume/resume.tsx:189`.

**Target Zig files.**
- Create `src/core/agentic_session_search.zig`: pure pieces (the `logContainsQuery` predicate, the session-list prompt builder, the index parser) plus a thin call that invokes the fast model. Register in `src/main.zig:41`.
- Edit `src/repl_commands.zig` / `src/cli/repl_overlay.zig`: an `onAgenticSearch` entrypoint reachable from the switcher (e.g. a key that toggles "AI search" using the current filter text), feeding ranked indices back into the picker.
- Reuse `src/session/store.zig` `countTurns`/`load` for transcript text and `readTags`/`readLabel` for metadata; reuse the provider-call pattern from `compaction.zig`/Phase 8.

**Approach.**
1. `logContainsQuery(meta, query_lower)`: lowercase substring check over label, tags, branch (from sessions-07), summary (`conversation_summary`), first prompt (from sessions-07), and transcript (lazy, last - load the JSONL and concat user/assistant turn text up to a `MAX_TRANSCRIPT_CHARS` cap).
2. Pre-filter `store.list()` to matching sessions; if fewer than a `MAX_SESSIONS_TO_SEARCH` cap, fill with recent non-matching for context.
3. Build the session-list prompt: `index: title [tag] [branch] - Summary: ... - First message: ... - Transcript: ...`, capped per the reference.
4. Call the fast model with the reference system prompt (inclusive bias). Parse the returned relevant indices.
5. Return the ranked subset to the picker. Make this opt-in (a key in the switcher) and degrade to fuzzy `session_search` when offline / no provider - never block the offline path.

**Acceptance criteria.**
- Write a test for `logContainsQuery`: matches on label, on a tag, on transcript text; misses when none contain the query.
- Write a test for the session-list prompt builder: includes index, title, tag, branch, first message, transcript excerpt; respects the per-session char cap.
- Write a test for the index parser: parse "0, 2, 5" / a JSON array / noisy model output into `[]usize`, ignoring out-of-range indices.

**Test strategy.** Pure-function tests in `core/agentic_session_search.zig` (no network) under `tools/test_runner.zig`. The model call is exercised manually / via the mock provider.

**Risk / footguns.** Transcript loading is expensive (reads + decrypts every matching JSONL) - cap session count and transcript chars hard. The model can return garbage indices; clamp to range and dedupe. This is `low` severity - layer it on top of sessions-02's fuzzy search; do not let it regress the deterministic path.

**Size estimate.** M.

---

### Task 11.4: Cross-project resume deviation note + optional cwd breadcrumb (sessions-04)

**Goal.** Document that zcode's global session model makes cross-project resume a non-gap, and add a cheap optional `cwd` breadcrumb so a future picker can display a session's origin directory.

**Reference behavior.** `checkCrossProjectResume` resumes a same-repo worktree directly, or prints/clipboards `cd <path> && claude --resume <id>` with a "different directory" message; the picker toggles all-projects vs same-repo. Ref: `utils/crossProjectResume.ts:30-75`; `commands/resume/resume.tsx:110,131-135,147-166`.

**Target Zig files.**
- Edit `docs/PARITY_ROADMAP_V2.md` (or the phase-tracking doc): add a short "Behavioral deviation: global sessions vs per-project logs" note explaining why cross-project resume does not apply.
- Optional: edit `src/session/store.zig` `appendSnapshot` (:131) to persist an `origin_cwd` string in the snapshot record, and surface it in `renderSessionsOverlayData` (:3597) display.

**Approach.**
1. Write the deviation note: zcode stores all sessions in a single flat `sessions_dir`; resuming any session in any cwd already works; there is no per-project log directory to bridge, so the reference's cd/clipboard machinery has no analog. This is a deliberate simplification, not a missing feature.
2. Optional breadcrumb: thread `cwd` into `appendSnapshot`, persist as `origin_cwd`; in the switcher, append a dim "(from <dir>)" when the session's `origin_cwd` differs from the current cwd. No blocking, no clipboard, no toggle.

**Acceptance criteria.**
- The deviation note exists and explains the model difference.
- If the breadcrumb is implemented: a test that `appendSnapshot` persists `origin_cwd` and `load` reads it back.

**Test strategy.** Doc change needs no test. Breadcrumb gets a `store.zig` round-trip test under `tools/test_runner.zig`.

**Risk / footguns.** `Child.Cwd` is a union (`.{ .path = "..." }`) if any subprocess uses the origin path. Keep the breadcrumb optional - it is not required to close the gap, which is fundamentally a non-gap.

**Size estimate.** S.

---

### Task 11.5: Rich export rendering + first-prompt-derived default filename (sessions-05)

**Goal.** Make Markdown/text export distinguish tool calls from tool results with structure, and derive the default export filename from the (sanitized) first prompt or a timestamp.

**Reference behavior.** Export renders the whole conversation through the Ink renderer to ANSI then strips ANSI, so tool_use/tool_result blocks and grouping appear as in the UI; default filename derives from the first prompt (sanitized) or a timestamp. Ref: `commands/export/export.tsx:19-48` (filename), `:49-52`; `utils/exportRenderer.tsx:55-97`.

**Target Zig files.**
- Edit `src/core/session_export_md.zig` (`toMarkdown` :20): emit a code-fenced block for `tool` turns and label tool-call vs tool-result by inspecting the artifact-wrapper marker in `turn.content`; preserve fenced code in user/assistant content. Add a `defaultFilename(allocator, first_prompt, ts) -> []u8` helper (sanitize first prompt: lowercase, replace non-`[a-z0-9-]` with `-`, collapse, truncate, `.md`; fall back to `session-YYYYMMDD-HHMMSS.md`).
- Edit `src/repl_commands.zig`: `/export` default filename (:2251) - replace the static `"session-export.md"` with `session_export_md.defaultFilename(...)` using the first user turn. Optionally route `exportSession` (:2564) through `toMarkdown` for consistency.
- Edit `src/session_cmds.zig` `cmdSessionExport` (:282): use the richer `toMarkdown` (already wired) and the first-prompt title.

**Approach.**
1. Tool rendering: zcode's content model is flat strings, but tool turns carry an artifact-wrapper marker (`agent_runtime.zig:2729`). Parse that marker in `toMarkdown` to label the section (`### Tool call: <name>` vs `### Tool result`) and fence the body. Where the marker is absent, fall back to the current `## Tool result` + raw text.
2. First-prompt filename: scan `history` for the first `.user` turn; sanitize to a slug; cap length; append `.md`. Empty history -> timestamp filename via `clock.nowSeconds()` formatted.
3. Keep the change surgical - do not redesign the storage model (that is the deeper fix the survey notes as out of scope). The win here is structure-from-markers + a useful default filename.

**Acceptance criteria.**
- Write a test in `session_export_md.zig`: a history with a tool turn whose content has the artifact marker renders a `### Tool call` / fenced section; a tool turn without the marker falls back to `## Tool result`.
- Write a test for `defaultFilename`: "Fix the login button!" -> `fix-the-login-button.md`; empty -> matches `session-.*\.md`.
- Manual: `/export` with no filename writes a first-prompt-named file.

**Test strategy.** Pure tests in `core/session_export_md.zig` under `tools/test_runner.zig`.

**Risk / footguns.** Sanitization must reject `..`/`/` so the default filename cannot escape the workspace (the existing `/export` path-traversal guard at `repl_commands.zig:2560` still applies - run the derived name through it). Do not emit em/en dashes in the slug (CLAUDE.md). The artifact-wrapper format is internal; if its shape changes the fallback must stay correct, so test both branches.

**Size estimate.** M.

---

### Task 11.6: AI-generated session title with user-rename precedence (sessions-06)

**Goal.** Generate a short AI title from the conversation, persist it as a distinct record so a user `/rename` always wins, surface it in the list/switcher, and expose a "current title" resolver.

**Reference behavior.** `saveAiGeneratedTitle` writes an `ai-title` entry; `saveCustomTitle` writes `custom-title`; read-preference makes a user rename win; `getCurrentSessionTitle` exposes the title; titles feed pickers and search. Ref: `utils/sessionStorage.ts:2667,2617,2739`; `agenticSessionSearch.ts:212`.

**Target Zig files.**
- Edit `src/session/store.zig`: add an `ai-title` sidecar (`<id>.aititle`) alongside the existing `.label` sidecar - `setAiTitle`/`readAiTitle`. Add `currentTitle(id) -> label (user) orelse ai_title orelse id` resolver. (Sidecar mirrors the existing `.label`/`.tags` pattern; avoids changing the JSONL record schema.)
- Create `src/core/session_title.zig`: build the title-generation prompt from the first user prompt + summary; parse the model's one-line title (trim, strip quotes, cap length). Register in `src/main.zig:41`.
- Edit `src/agent_runtime.zig`: after the first assistant turn (or at session end), if no user label exists and no ai-title yet, run the title generator (reuse the Phase 7 sub-agent / fast-model sideQuery path) and `setAiTitle`.
- Edit `src/session_cmds.zig` (`cmdSessionList` :40-80) and `src/repl_commands.zig` (`renderSessionsOverlayData` :3597, `/session list` :243): display `currentTitle(id)` instead of `label orelse id`.

**Approach.**
1. Resolver: user-set `.label` (via `/rename`) always wins; else `.aititle`; else the raw id. Implement once in `store.currentTitle` and call everywhere a title is shown.
2. Generation: a short prompt ("Write a 3-6 word title for this coding session:") over the first user prompt + `conversation_summary`, sent to the fast model. Parse a single line, strip surrounding quotes, cap ~60 chars, reject empty.
3. Trigger: once per session, gated so it never overwrites a user label and never re-runs if an ai-title already exists. Run it off the critical path (best-effort; swallow errors like the existing summarizer).

**Acceptance criteria.**
- Write a test: `setAiTitle` then `readAiTitle` round-trips via the sidecar.
- Write a test for `currentTitle` precedence: label set -> returns label; no label but ai-title set -> returns ai-title; neither -> returns id.
- Write a test for the title parser: `"\"Fix login bug\"\n"` -> `Fix login bug`; empty/whitespace -> error or null.
- Manual: start a session, send one prompt, confirm `/session list` later shows an AI title; `/rename` overrides it.

**Test strategy.** Sidecar round-trip + precedence tests in `store.zig`; parser test in `core/session_title.zig`; both under `tools/test_runner.zig`. Generation call exercised via the mock provider.

**Risk / footguns.** Do not block session startup or the first turn on the network call - run it best-effort and after the response streams. The sidecar approach keeps the JSONL schema stable (no migration). Ensure `currentTitle` frees correctly (it returns a borrowed slice into label/aititle/id - document ownership or always dup). Title must not contain newlines (sanitize) or it corrupts the TSV `/session list` rows (same hazard the existing `display_safe.sanitize` at `session_cmds.zig:64` guards).

**Size estimate.** M.

---

### Task 11.7: Persist git-branch / first-prompt / PR-link session metadata (sessions-07)

**Goal.** Persist the git branch, the first prompt, and PR links per session, and surface them in the picker and search.

**Reference behavior.** Sessions persist `gitBranch`, `firstPrompt`, `summary`, and PR links (`linkSessionToPR` -> `pr-link` entry); these show in pickers and are searchable. `METADATA_TYPE_MARKERS` lists session-scoped entries preserved across compaction. Ref: `utils/sessionStorage.ts:2705` (`linkSessionToPR`), `:3113-3123`; `agenticSessionSearch.ts:121-131`.

**Target Zig files.**
- Edit `src/session/store.zig`: add a `meta` record type (or extend the snapshot record) carrying `git_branch`, `first_prompt`, and a `pr_links: [][]const u8`. A dedicated `appendMeta`/`readMeta` keeps it separate from the conversation turns. Alternatively use sidecars (`<id>.branch`, `<id>.firstprompt`, `<id>.prlinks`) to avoid schema churn - pick the sidecar route for consistency with label/tags/aititle.
- Edit `src/session_mgmt.zig`: the `detectGitBranch` result (:245) is currently discarded - persist it on session create/first-turn. Capture the first user prompt and persist it.
- Edit `src/repl_commands.zig`: a `/pr-link <url>` command (or auto-link after `OpenPR`) that records a PR link.
- Edit `renderSessionsOverlayData` (:3597) and `/session list`: show branch + first-prompt preview; feed branch/first-prompt/pr-links into sessions-03's `logContainsQuery`.

**Approach.**
1. Persist git branch once at session start (the value already exists at `session_mgmt.zig:245`; write it to `<id>.branch`).
2. Persist the first user prompt the first time a user turn is appended (write `<id>.firstprompt`, truncated, only if absent).
3. PR links: append to `<id>.prlinks` (newline-delimited, dedup) on `/pr-link <url>` and optionally after a successful `OpenPR` tool call.
4. Display: switcher and `/session list` show branch + a one-line first-prompt preview; search predicate includes all three.

**Acceptance criteria.**
- Write tests: branch / first-prompt / pr-link sidecar round-trips; pr-link dedup.
- Write a test that the first-prompt sidecar is written only once (second user turn does not overwrite).
- Manual: start a session on a branch, send a prompt, `/session list` shows the branch and prompt preview.

**Test strategy.** Sidecar round-trip + dedup + write-once tests in `store.zig` under `tools/test_runner.zig`.

**Risk / footguns.** Branch detection shells to git - `Child.kill(io)` reaps internally, do not `wait()` after (CLAUDE.md). Sanitize branch/first-prompt before TSV display (newlines). First-prompt write-once needs an existence check, not an unconditional write. Keep sidecars 0o600 like the existing ones (`writeSidecarAtomic` at `store.zig:708`).

**Size estimate.** M.

---

### Task 11.8: Resume-consistency check + orphan cleanup once rewind writes to disk (sessions-08)

**Goal.** Once rewind can affect persisted state (sessions-01), add a UUID-aware consistency check on resume and a way to remove orphaned turns from the append-only JSONL.

**Reference behavior.** `buildConversationChain` reconstructs the parent-UUID chain on resume, tolerating rewind orphan branches; `checkResumeConsistency` compares a checkpoint's recorded `messageCount` against the reconstructed position and logs drift; `removeTranscriptMessage` removes orphaned messages by UUID. Ref: `utils/sessionStorage.ts:2069,2224,3229,1472`.

**Target Zig files.**
- Edit `src/session/store.zig`: add `removeTurnByUuid(id, uuid)` that rewrites the JSONL omitting the matching turn record (atomic temp+rename, like `writeSidecarAtomic` :708). Add `checkResumeConsistency(loaded) -> ConsistencyReport` comparing the count of loaded turns against an expected count recorded in the latest snapshot.
- Edit `src/core/types.zig` (`SessionSnapshot` :194): optionally record `message_count_at_snapshot` so the consistency check has a reference number.
- Edit `src/repl_commands.zig`: when `__rewind_apply` restores conversation (sessions-01), also drop the now-orphaned turns from disk via `removeTurnByUuid` (or mark them) so the next resume does not replay them, and run `checkResumeConsistency` on `/resume`, logging drift.

**Approach.**
1. `removeTurnByUuid`: load the JSONL lines, drop the record whose `uuid` matches (and optionally its descendants if `parent_uuid` is implemented), rewrite atomically.
2. `checkResumeConsistency`: after `load`, compare `history.len` to the snapshot's recorded count; if they diverge beyond a tolerance, `std.log.warn` with the drift (non-fatal - the reference only logs).
3. Wire into sessions-01: when rewind restores conversation to a prior UUID, the truncated-away turns are orphans on disk; either remove them (clean) or rely on the snapshot model. Given zcode's append-only design, the minimal correct behavior is: write a fresh snapshot at the rewind point so the next `load` reconstructs the truncated history, and warn on drift. Full per-message removal is the richer option.

**Acceptance criteria.**
- Write a test: append 3 turns with UUIDs, `removeTurnByUuid` the middle one, reload, assert 2 turns and the right ones survive.
- Write a test for `checkResumeConsistency`: a session whose loaded count matches the snapshot count -> no drift; mismatch -> drift reported.

**Test strategy.** Round-trip + consistency tests in `store.zig` under `tools/test_runner.zig`.

**Risk / footguns.** Rewriting an append-only file races concurrent writers - take the same atomic temp+rename discipline and accept that two zcode processes on one session is already unsupported for rewrites. `readPositionalAll(file, io, buf, 0)` reads byte 0 forever - track offset / use the existing `readFileAlloc` path for the rewrite (CLAUDE.md). Encrypted records: `removeTurnByUuid` must decode each line to read its `uuid`, then re-encrypt the survivors. This task is `low` and only matters after sessions-01 writes to disk - if sessions-01 ships with the snapshot-rewrite approach (not per-message removal), this task can be limited to `checkResumeConsistency` + the drift warning.

**Size estimate.** M.

---

### Task 11.9: Prompt-history removeLast + restore-on-interrupt (sessions-12)

**Goal.** Add `removeLastFromHistory()` and wire it so that interrupting a turn mid-execution pops the just-added prompt back into the input (auto-restore).

**Reference behavior.** `history.ts` maintains a global deduped newest-first prompt history with `addToHistory`/`removeLastFromHistory`; the latter supports auto-restore-on-interrupt. Ref: `history.ts:411` (`addToHistory`), `:453` (`removeLastFromHistory`).

**Target Zig files.**
- Edit `src/cli/repl_history.zig`: add `removeLastForWorkspace(allocator, workspace)` that removes the most recent entry for the given workspace from `~/.claude/prompt-history.jsonl` (atomic rewrite). The append side (`appendPrompt` :24) already exists.
- Edit `src/cli/repl.zig`: on a mid-turn interrupt (Ctrl+C cancels the in-flight prompt), call `removeLastForWorkspace` and repopulate the input buffer with the interrupted prompt so the user can edit/resubmit.

**Approach.**
1. `removeLastForWorkspace`: read the JSONL, find the last entry whose `workspace` matches, rewrite omitting it (atomic temp+rename). Return the removed prompt text so the caller can restore it to the input.
2. Interrupt wiring: locate the REPL's turn-interrupt handler; when a turn is cancelled before completion, call `removeLastForWorkspace` and set the input buffer to the returned prompt (re-expanding paste refs via the existing `materializePromptForInput` at `repl.zig:1815`).

**Acceptance criteria.**
- Write a test in `repl_history.zig`: append 3 prompts for workspace W, `removeLastForWorkspace(W)` returns the 3rd and the file now has 2; entries for other workspaces are untouched.
- Manual: type a prompt, Ctrl+C mid-turn, confirm the prompt reappears in the input.

**Test strategy.** Round-trip test in `cli/repl_history.zig` using a tmp state dir (mirror `appendPromptInStateDir`'s test seam) under `tools/test_runner.zig`.

**Risk / footguns.** The history file is global/cross-project - only remove entries matching the current workspace, or removeLast pops another project's prompt. Atomic rewrite (temp+rename) to avoid a torn file. Restore-on-interrupt must not fire on a *completed* turn (only on cancel before completion) or it will pop good history. This is S - the data layer is a small addition; the interrupt wiring is the only real integration point.

**Size estimate.** S.

---

## Verification

Whole-phase done criteria:

1. **Build + install (per CLAUDE.md).** Bump the patch version in `build.zig.zon`, then:
   ```
   /Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build -Doptimize=ReleaseFast
   rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode
   ```
   (The `rm -f` before `cp` is mandatory - overwriting in place invalidates the ad-hoc code signature and the next run is SIGKILLed.)
2. **Tests.** `zig build test` passes, including every new test block listed per task (run under `tools/test_runner.zig`). Confirm no leaks (the custom runner uses the leak-checking allocator) for the UUID and snapshot paths.
3. **sessions-01 manual.** Edit a file via a REPL turn, open the rewind picker, select the prior message, choose "Restore code"; confirm the file reverts on disk and the confirmation message no longer claims disk is unchanged. Choose "Restore conversation" on another session and confirm only history truncates.
4. **sessions-02 manual.** `/resume <fuzzy-term>` resumes a single match; a two-match term prints a disambiguation list; `/resume` with no arg opens the picker; typing in the switcher ranks by fuzzy score.
5. **sessions-05 manual.** `/export` with no filename writes a first-prompt-named `.md`; the file shows distinct tool-call vs tool-result sections.
6. **sessions-06 manual.** A fresh session gets an AI title visible in `/session list`; `/rename` overrides it permanently.
7. **sessions-07 manual.** `/session list` shows the git branch and a first-prompt preview for a session started on a branch.
8. **sessions-12 manual.** Ctrl+C mid-turn restores the interrupted prompt into the input; the prompt is removed from global history.
9. **Dead-code check.** `src/core/session_search.zig` is now called from a live path (not just `_ = @import` in `src/main.zig`); confirm via grep that `session_search.search` has a non-test caller.
10. **Doc.** The sessions-04 deviation note is present in the roadmap doc.

## Out-of-scope / deferred notes

- **Full structured message storage (deep fix for sessions-05).** zcode's content model is flat `role+content` strings. Matching the reference's render-the-real-UI-to-ANSI export fully would require storing structured tool_use/tool_result blocks. This phase does the cheap, high-value wins (marker-based tool section labeling + first-prompt filename) and defers a structured message model to a future phase.
- **Per-message `parentUuid` chain.** sessions-08 implements a count-based consistency check + UUID removal; a full parent-UUID DAG (`buildConversationChain` with branch reconstruction) is deferred. zcode's append-only + snapshot model does not need the DAG until interactive branch-switching exists.
- **Cross-project resume machinery (sessions-04).** The cd/clipboard/worktree-toggle flow is intentionally not built - it is a non-gap under zcode's global session model. Only the deviation note (and an optional cwd breadcrumb) ship.
- **Agentic search as default (sessions-03).** The LLM search is opt-in and layered on top of the deterministic fuzzy path; it never replaces or blocks the offline path. Caching transcript extracts across searches is deferred.
- **File-history retention/eviction tuning (sessions-01).** Snapshot dirs are capped to the last N user turns (or a size budget); fine-grained "only files the agent touched" tracking (vs whole-tree snapshot) is a follow-up optimization, not required for parity of the restore behavior.
- **Encryption interplay with JSONL rewrite (sessions-08).** `removeTurnByUuid` decode/re-encrypt is implemented, but bulk JSONL compaction (rewrite to shrink the file after many removals) is deferred to the existing `/session compact` path.
