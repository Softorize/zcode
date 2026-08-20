# Phase 10: Memory and instructions: auto-extraction, taxonomy prompt, relevance selection, MEMORY.md index, conditional rules

## Overview

**What.** This phase brings zcode's memory and instruction subsystems up to Claude Code parity across nine verified gaps. The headline feature is an automatic turn-end memory extraction agent that mirrors the reference's `extractMemories` (a constrained forked sub-agent that runs after a complete query loop). Around it sit the supporting pieces: a rich four-type taxonomy prompt injected into the system prompt so the main agent self-manages memory; an LLM-based relevance selector (`findRelevantMemories`); a `MEMORY.md` index file that is always loaded into context with dual line/byte truncation caps; a per-session background summarizer (`SessionMemory`); HTML-comment stripping in instruction files; path-scoped (`paths:`/`globs:`) conditional instruction rules; and a `isAutoMemoryEnabled` gating chain with env-var and settings path overrides.

**Why.** Today zcode has a strong *recall* path (load memory files, deterministic keyword ranking, freshness caveats) and a *consolidation* path (`/dream`), but no *write* path that captures new memories from a conversation automatically, and no taxonomy guidance that teaches the model when/how to write. The reference's central auto-memory loop is the missing piece: the main agent writes memories directly (taught by the system-prompt taxonomy block), and a background forked agent catches anything it missed at turn end. The two are mutually exclusive per turn (`hasMemoryWritesSince`). The remaining gaps are context-hygiene (comment stripping), config-parity (gating/overrides), and a path-conditional rules feature that lets a `.claude/rules/*.md` file apply only when editing matching paths.

**Dependencies.** This phase depends on Phase 5 (prompt assembly / system-prompt section infrastructure that this phase extends in `prompt_helpers.zig` and `system_prompt.zig`) and Phase 7 (the constrained sub-agent / forked-agent spawn machinery, of which zcode already has a working instance in `maybeRunDream`). Both are assumed complete: the `maybeRunDream` pattern at `src/agent_runtime.zig:2783-2834` is the concrete template the extraction agent reuses, and the structured-output `appendResponseSchemaToBody` at `src/providers/common.zig:1176` is the template the relevance selector reuses.

**Effort.** XL. Three of the nine gaps are L (memory-01 auto-extraction, memory-05 session summarizer, and the combined memory-04/11 index work), the rest M/S. The work is partitionable: memory-02 (taxonomy prompt), memory-08 (comment stripping), memory-09 (conditional rules), and memory-10 (gating) have no data dependency on the extraction agent and can be built in parallel with it. memory-01, memory-04, and memory-11 share `MEMORY.md` surface and should be serialized in that order.

## Gaps covered

| id | title | severity | size | our current state |
|---|---|---|---|---|
| memory-01 | Automatic turn-end memory extraction (forked agent) | high | L | Absent. `/memory save` (manual) and `/dream` (consolidate existing) exist; no turn-end extraction, cursor, throttle, mutual-exclusion, or constrained extraction agent. |
| memory-02 | Four-type taxonomy + save-instruction prompt in system prompt | medium | M | Partial. Categories recognized for `/memory save`; memories rendered into prompt with freshness caveats. No educational taxonomy block, `when_to_save`/`how_to_use`/`body_structure`, `WHAT_NOT_TO_SAVE`, two-step save protocol, or grep section. |
| memory-03 | LLM relevance selection per query (findRelevantMemories) | medium | M | Partial (present-different). Deterministic keyword-overlap ranking + always-include rules, freshness caveats, cap=4. No Sonnet `sideQuery` selection over frontmatter manifest, no `alreadySurfaced` set, no recently-used-tool exclusion. |
| memory-04 | MEMORY.md index always loaded into system prompt w/ truncation | medium | M | Absent in per-turn path. `MAX_MEMORY_INDEX_LINES=200` used only inside `/dream`; individual memory entries rendered, never a `MEMORY.md` index. No entrypoint injection. |
| memory-05 | SessionMemory background summarizer (per-session notes, thresholds) | medium | L | Absent. `/summary` displays stats inline; `.session_memory` context block carries task state, not summarized notes. No post-sampling hook, per-session notes file, token/tool-call thresholds, or Edit-only constrained fork. |
| memory-08 | HTML-comment stripping in instruction (CLAUDE.md) content | low | S | Absent for instructions. `html_to_text.zig` strips comments but only for WebFetch. Instruction files rendered verbatim; `@import` detection strips fences but not HTML comments. |
| memory-09 | Frontmatter `paths:`/`globs:` conditional instruction rules | low | M | Absent. `.claude/rules/*.md` loaded unconditionally at precedence 60; no frontmatter `paths` parsing or path gating for instructions. Skills have a glob matcher (`skill_visibility.globMatch`) that can be reused. |
| memory-10 | Auto-memory enable/disable gating + path override | low | S | Absent. Memory loaded unconditionally at fixed `~/.zcode/memory`; no `isAutoMemoryEnabled`, env override, settings field, or path validation. |
| memory-11 | MEMORY.md index byte cap (25KB) with named-cap truncation warning | low | S | Absent at runtime. Soft 200-line guidance in `/dream` instruction text; 64KB defensive per-file read cap. No dual-cap truncation, no 25KB ceiling, no named-cap warning. |

Survey-accuracy note after reading both trees: every "absent" claim above is confirmed. memory-03 is correctly characterized as present-different (zcode's deterministic scorer is real and tested at `src/core/memory.zig:414-444`); this phase adds the LLM selector as an *optional* layer on top, not a replacement, to avoid regressing the offline/no-network path. memory-08's reference uses a markdown lexer; zcode does not have one, so the plan specifies a CommonMark-subset block-comment stripper (HTML-block-level only) rather than a full lexer, matching the reference's *intent* (strip authorial block comments, preserve comments inside fenced/inline code).

## Implementation tasks

The reusable primitives this phase leans on (verified present):
- Sub-agent spawn template: `src/agent_runtime.zig:2783-2834` (`maybeRunDream`) - spawns a child `AgentRuntime` with `depth+1`, `max_tool_rounds_override`, `interactive=false`, runs `handlePrompt`, frees the result. The extraction agent and the session summarizer both clone this shape.
- Tool restriction: `src/agent_tools.zig:217` (`filterReadOnlySchemas`), `:359` (`filterAgentSchemas`), `:308` (`filterNonInspectionSchemas`). The auto-mem allowlist (Read/Grep/Glob + read-only Bash + Edit/Write-within-memory-dir) is a new filter alongside these.
- Structured output: `src/providers/common.zig:1176` (`appendResponseSchemaToBody`) emits `response_format` JSON schema; `src/providers/anthropic.zig:498` handles tool schemas. The relevance selector reuses `appendResponseSchemaToBody`.
- Frontmatter: `src/core/frontmatter.zig` `extract` / `getValue`.
- Glob matching: `src/core/skill_visibility.zig:69` (`globMatch`) and `:48` (`matchesAnyPath`).
- Env helpers: `src/core/env.zig` `isEnvTruthy` / `isEnvDefinedFalsy` / `getenv`.
- Memory dir + atomic write: `src/core/memory.zig:382` (`memoryDirPathPub`), `:299` (`writeMemoryFileAtomic`).
- Memory render wiring point: `src/core/prompt_helpers.zig:263-280` (`renderDynamicSystemPolicy`).

---

### Task 1: Auto-memory gating chain + path resolution (memory-10)

**Goal.** Add `isAutoMemoryEnabled()` and a resolvable, validated auto-memory directory so every other task in this phase can gate on a single source of truth.

**Reference behavior.** `isAutoMemoryEnabled` priority chain: `CLAUDE_CODE_DISABLE_AUTO_MEMORY` env (truthy OFF, defined-falsy ON), `CLAUDE_CODE_SIMPLE` (--bare) OFF, remote-without-storage OFF, `settings.autoMemoryEnabled`, default ON (`src/memdir/paths.ts:30-55`). `getAutoMemPath` honors `CLAUDE_COWORK_MEMORY_PATH_OVERRIDE` env then `settings.autoMemoryDirectory` (trusted sources, `~/` expansion), else computes the project dir (`paths.ts:161-235`). `validateMemoryPath` rejects relative/root/near-root/UNC/null-byte paths (`paths.ts:109-150`). `isAutoMemPath` is the write-allowlist carve-out (`paths.ts:274-278`).

**Target Zig files.**
- Create `src/core/memory_gate.zig` (new deep module). Register in `src/main.zig` comptime block: `_ = @import("core/memory_gate.zig");`.
- Edit `src/core/config.zig`: add `auto_memory_enabled: ?bool = null` and `auto_memory_directory: []u8` fields (follow the `preferred_language` pattern at `config.zig:123`, init to empty / null, free in `deinit` near `config.zig:255-263`).
- Edit `src/cli/args.zig`: add `bare: bool = false` and `no_memory: bool = false` flags to `CliOptions` (struct at `args.zig:110`), parsed like the existing `strict`/`yolo` bool flags; map `--bare`/`--simple` to set an env-equivalent, and `--no-memory` to force-disable.

**Approach.**
1. In `memory_gate.zig`, implement `pub fn isAutoMemoryEnabled(cfg: *const config.Config) bool` following the exact reference priority chain using `env.isEnvTruthy("ZCODE_DISABLE_AUTO_MEMORY")` (and accept the `CLAUDE_CODE_DISABLE_AUTO_MEMORY` alias for parity), `env.isEnvTruthy("ZCODE_SIMPLE")`/`CLAUDE_CODE_SIMPLE`, then `cfg.auto_memory_enabled orelse true`. Keep env names dual (zcode-native primary, claude alias) consistent with how `env.zig` already mirrors `claude-code-main/src/utils/envUtils.ts`.
2. Implement `pub fn validateMemoryPath(allocator, raw: ?[]const u8, expand_tilde: bool) !?[]u8` mirroring `paths.ts:109-150`: reject null/empty; expand `~/` (reject bare `~`, `~/.`, `~/..` remainders); reject non-absolute, length < 3, Windows drive-root `[A-Za-z]:`, `\\` / `//` UNC prefixes, and embedded `\0`. Return normalized path with one trailing separator.
3. Implement `pub fn getAutoMemPath(allocator, cfg) ![]u8`: check `ZCODE_MEMORY_PATH_OVERRIDE`/`CLAUDE_COWORK_MEMORY_PATH_OVERRIDE` env (no tilde expand) -> `cfg.auto_memory_directory` (tilde expand) -> fall back to `memory.memoryDirPathPub(allocator)`. This becomes the single resolver; `memory.zig` keeps `memoryDirPathPub` as the default-path leaf.
4. Implement `pub fn isAutoMemPath(allocator, cfg, abs_path: []const u8) !bool` that normalizes and checks `startsWith(getAutoMemPath())`. Used by Task 2 and Task 5 tool-restriction filters.
5. Wire the gate at the memory render site (`prompt_helpers.zig:263`): wrap the `memory.loadAllWithWorkspace` call in `if (memory_gate.isAutoMemoryEnabled(cfg)) { ... }`.

**Acceptance criteria.**
- Write a test in `memory_gate.zig`: with `ZCODE_DISABLE_AUTO_MEMORY=1` set (via the test's env shim), `isAutoMemoryEnabled` returns false; with `=0` returns true regardless of `cfg.auto_memory_enabled=false`; with env unset and `cfg.auto_memory_enabled=false` returns false; with everything unset returns true.
- Write a test that `validateMemoryPath` rejects `"../foo"`, `"/"`, `"/a"`, `"C:"`, `"\\\\srv\\s"`, `"/ok/\x00bad"` (returns null) and accepts `"/Users/x/.zcode/memory"` (returns it with one trailing `/`).
- Write a test that `getAutoMemPath` honors the env override when set and falls back to the default `~/.zcode/memory` otherwise.

**Test strategy.** All under `tools/test_runner.zig`. Env-dependent tests must read env via `env.getenv` (which the runner can shim) - do NOT call `std.posix.getenv` directly. Use `core/test_helpers.zig` `tmpDirPath` for any path that touches disk; pass absolute paths only (the runner's CWD is not the tmp dir).

**Risk / footguns.** `std.process.Environ.Map.remove` is gone - use `swapRemove` if a test needs to clear an env var. Avoid `getEnvMap`; the runtime singleton exposes the environ. Keep the env name aliases narrow - do not invent new toggles beyond the reference set.

**Size.** S.

---

### Task 2: Four-type taxonomy + save-instruction prompt block (memory-02)

**Goal.** Inject a "You have a persistent, file-based memory system" instructional section into the system prompt that teaches the model the closed four-type taxonomy, when/how to save, what NOT to save, the two-step `MEMORY.md` save protocol, and a grep-based search section.

**Reference behavior.** `buildMemoryLines` (`src/memdir/memdir.ts:199-266`) assembles the section; the type blocks with `<when_to_save>/<how_to_use>/<body_structure>/<examples>` live in `src/memdir/memoryTypes.ts:113-178` (`TYPES_SECTION_INDIVIDUAL`), the `WHAT_NOT_TO_SAVE_SECTION` at `:183-195`, `WHEN_TO_ACCESS_SECTION` at `:216-222`, `TRUSTING_RECALL_SECTION` at `:240-256`, `MEMORY_FRONTMATTER_EXAMPLE` at `:261-271`, and the search section in `buildSearchingPastContextSection` (`memdir.ts:375-407`). `buildMemoryPrompt` (`:272-316`) appends the `MEMORY.md` content (handled by Task 3).

**Target Zig files.**
- Create `src/core/memory_prompt.zig` (new deep module holding the taxonomy text builders). Register in `src/main.zig` comptime block.
- Edit `src/core/prompt_helpers.zig`: call the new builder inside `renderDynamicSystemPolicy` (near `:263-280`), gated on `memory_gate.isAutoMemoryEnabled`.

**Approach.**
1. Port the four type blocks into `memory_prompt.zig` as comptime string constants, preserving the exact taxonomy: `user`, `feedback`, `project`, `reference`. Keep the `<type>/<name>/<description>/<when_to_save>/<how_to_use>/<body_structure>/<examples>` structure. Reword every em/en dash in the reference text to plain hyphens (the reference uses many - this is a hard rule).
2. Port `WHAT_NOT_TO_SAVE_SECTION`, `WHEN_TO_ACCESS_SECTION` (including the "ignore memory" bullet and drift caveat), `TRUSTING_RECALL_SECTION` ("Before recommending from memory"), and `MEMORY_FRONTMATTER_EXAMPLE`.
3. Implement `pub fn buildMemoryLines(allocator, memory_dir: []const u8) ![]u8` returning the full section. Substitute the resolved memory dir (from Task 1 `getAutoMemPath`) into the "system at `<dir>`" line and the search section. Include the two-step save protocol referencing `MEMORY.md`.
4. Implement `buildSearchingPastContextSection` - zcode's tool names are `Grep`/`Bash`; emit `Grep with pattern="..." path="<dir>" glob="*.md"`. Keep it unconditional (the reference gates it on a feature flag; zcode has no GrowthBook, so always include).
5. Wire it into `renderDynamicSystemPolicy` so the taxonomy block is emitted once per turn before the relevant-memory render. Keep zcode's existing `# Relevant Persistent Memory` / `# ABSOLUTE RULES` render (Task 3 extends it) - the taxonomy block is *additive* educational text, the relevant-memory block is the recalled content.

**Reconciliation with zcode's extra categories.** zcode recognizes `rule`/`always` categories the reference lacks (used for `# ABSOLUTE RULES` always-include). Keep them as a zcode extension in `memory.zig` rendering, but the taxonomy *prompt* must teach only the four reference types so the model writes parity-shaped files. Document this divergence inline in `memory_prompt.zig`.

**Acceptance criteria.**
- Write a test: `buildMemoryLines` output contains all four type names, the strings `when_to_save` is conveyed (the literal `<when_to_save>` tag), `## What NOT to save in memory`, `Saving a memory is a two-step process`, `MEMORY.md`, and `## Searching past context`.
- Write a test asserting the output contains NO em dash (` - `) and NO en dash (`-`) byte sequences (the reference text is full of them; the port must scrub).
- Write a test asserting the memory dir path passed in is substituted into the output (not a hardcoded `~/.claude`).

**Test strategy.** Pure-string tests in `memory_prompt.zig` under the custom runner; no disk I/O needed. Add one integration assertion in `prompt_helpers` tests that `renderDynamicSystemPolicy` includes the taxonomy header when the gate is on and omits it when `isAutoMemoryEnabled` is false.

**Risk / footguns.** This is a large block of static text added to every prompt - it costs input tokens every turn. The reference accepts this because the main agent's write path depends on it. Keep it behind the gate so `--bare` users do not pay. Watch the long-dash rule: scan the ported constants before committing.

**Size.** M.

---

### Task 3: MEMORY.md index always-loaded + dual-cap truncation (memory-04 + memory-11)

**Goal.** Load the per-project `MEMORY.md` index into the system prompt every turn, enforcing both a 200-line and a 25000-byte cap with a named-cap truncation warning.

**Reference behavior.** `ENTRYPOINT_NAME='MEMORY.md'`, `MAX_ENTRYPOINT_LINES=200`, `MAX_ENTRYPOINT_BYTES=25000` (`memdir.ts:34-38`). `truncateEntrypointContent` (`:57-103`) trims, line-truncates first (slice to 200 lines, join), then byte-truncates at the last `\n` before 25000, and appends a warning naming exactly which cap fired (bytes-only / lines-only / both) plus "keep index entries to one line under ~200 chars; move detail into topic files." `buildMemoryPrompt` appends the truncated content under a `## MEMORY.md` header, or "currently empty" text when absent (`:295-313`).

**Target Zig files.**
- Edit `src/core/memory_prompt.zig` (from Task 2): add `pub const ENTRYPOINT_NAME = "MEMORY.md"`, `MAX_ENTRYPOINT_LINES = 200`, `MAX_ENTRYPOINT_BYTES = 25000`, and `pub fn truncateEntrypoint(allocator, raw: []const u8) !Truncation` returning `{ content, line_count, byte_count, was_line_truncated, was_byte_truncated }`.
- Edit `src/core/prompt_helpers.zig`: read `<auto_mem_dir>/MEMORY.md` and append it after the taxonomy block.
- Edit `src/core/dream.zig`: replace the local `MAX_MEMORY_INDEX_LINES` const usage with the shared `memory_prompt.MAX_ENTRYPOINT_LINES` to keep dream and per-turn in sync (surgical - only the const reference, do not rewrite the dream prompt).

**Approach.**
1. Implement `truncateEntrypoint`: `trim` the input; count lines and bytes; `was_line_truncated = line_count > 200`; `was_byte_truncated = byte_count > 25000` (computed on the original trimmed bytes, per the reference comment, so long-line indexes trigger the byte warning). If neither fired, return content unchanged. Otherwise slice to 200 lines (split on `\n`, take first 200, rejoin), then if the result still exceeds 25000 bytes find the last `\n` at or before 25000 (`lastIndexOf`) and cut there (fall back to a hard 25000 cut if no newline). Append the named-cap warning. Use a human-readable byte size formatter (port a small `formatFileSize` helper or print `25000 bytes`/`24.4KB`).
2. In `prompt_helpers`, resolve `getAutoMemPath` (Task 1), join `MEMORY.md`, read with the existing 64KB `readFileAlloc(.limited(...))` cap (note: 64KB > 25KB so the byte cap can always fire on read content), pass through `truncateEntrypoint`, and emit `## MEMORY.md\n\n<content>` or the "currently empty" fallback. Gate on `isAutoMemoryEnabled`.
3. Ensure the index is emitted as a distinct surface from the recalled per-entry memories - the index is the curated pointer file (always loaded), the per-entry render (Task 4/`memory.zig`) is the relevance-selected detail.

**Acceptance criteria.**
- Write a test: a 201-line input is line-truncated to 200 lines and the warning names `lines (limit: 200)`.
- Write a test: a single 30000-byte line is byte-truncated and the warning names the byte cap with "index entries are too long".
- Write a test: input over both caps gets the combined-cap warning.
- Write a test: input under both caps is returned trimmed with no warning.
- Write a test: byte truncation cuts at a newline boundary (no mid-line cut) when a newline exists before the cap.

**Test strategy.** Pure-function tests in `memory_prompt.zig`. Add one `prompt_helpers` test using `tmpDirPath` to write a `MEMORY.md` and assert it appears under `## MEMORY.md` in the rendered dynamic policy.

**Risk / footguns.** `readFileAlloc(.limited(N))` returns `error.StreamTooLong` (not `FileTooBig`) when the file exceeds N - catch it and fall back to "treat as truncated" rather than dropping the index. Line splitting: use `std.mem.splitScalar(u8, s, '\n')` and count carefully - the reference uses `split('\n').length` which counts trailing-newline-produced empty segments; match that so line counts agree.

**Size.** M (covers two gaps).

---

### Task 4: LLM relevance selection layer (memory-03)

**Goal.** Add an optional Sonnet-backed relevance selector that scans memory-file frontmatter, formats a manifest, and asks the model to pick up to 5 files - layered on top of (not replacing) the existing deterministic scorer.

**Reference behavior.** `findRelevantMemories` (`src/memdir/findRelevantMemories.ts:39-141`): `scanMemoryFiles` (cap 200, newest-first, excludes `MEMORY.md`, reads first 30 frontmatter lines) -> `formatMemoryManifest` (`[type] filename (ISO-mtime): description`) -> `sideQuery` to default Sonnet with a JSON-schema `{ selected_memories: string[] }`, `SELECT_MEMORIES_SYSTEM_PROMPT`, filtering out reference/API docs for recently-used tools while keeping warnings/gotchas, honoring an `alreadySurfaced` exclusion set (`memoryScan.ts:35-95`).

**Target Zig files.**
- Edit `src/core/memory.zig`: add `pub fn scanMemoryFiles(allocator, dir, max) ![]MemoryHeader` (frontmatter-only headers, newest-first by mtime, cap 200, exclude `MEMORY.md`) and `pub fn formatMemoryManifest(allocator, headers) ![]u8`. The `MemoryEntry` loader already reads name/category/mtime - extract a header-only path that reads only the frontmatter window.
- Create `src/core/memory_relevance.zig` (new module) holding the side-query selector. Register in `src/main.zig` comptime block.
- Edit `src/core/prompt_helpers.zig`: when network is allowed and the gate is on, call the selector; otherwise fall back to the existing `renderRelevantForPrompt` deterministic path.

**Approach.**
1. `scanMemoryFiles`: iterate the memory dir, read up to ~30 lines of each `.md` (skip `MEMORY.md`), parse `description`/`type` from frontmatter via `frontmatter.getValue`, capture mtime via `statFile().mtime.toNanoseconds()`, sort newest-first, cap at 200.
2. `formatMemoryManifest`: one line per file `- [type] filename (ISO-8601 mtime): description` (omit `[type]` when missing, omit `: description` when empty). Reuse a small ISO formatter; if none exists, emit epoch-millis as a fallback rather than blocking on date formatting.
3. `memory_relevance.zig`: build the user message `Query: <q>\n\nAvailable memories:\n<manifest>` plus an optional `\n\nRecently used tools: ...` line, and call the model with the structured-output path. Reuse `providers/common.zig:appendResponseSchemaToBody` with schema `{"type":"object","properties":{"selected_memories":{"type":"array","items":{"type":"string"}}},"required":["selected_memories"],"additionalProperties":false}`. Route through the same side-call mechanism the codebase already uses for non-main-loop model calls (the dream subagent / `agent_history.callModel` path). Parse the JSON, filter to valid filenames, return up to 5 paths + mtimes.
4. Implement the `alreadySurfaced` exclusion (a `StringHashMap` of paths) and the recently-used-tool filter: drop a header whose `type == reference` (or `user`/`project` API-doc shaped) when its filename/description names a recently-used tool, UNLESS the description contains warning/gotcha words. Keep this heuristic small.
5. Wire into `prompt_helpers`: if `policy.allow_network` and the gate is on, attempt the selector; on any error or empty result, fall back to `memory.renderRelevantForPrompt` (the existing deterministic path stays the default for offline/mock providers and keeps current tests green). Raise the deterministic cap from 4 to 5 to match the reference's "up to 5".

**Acceptance criteria.**
- Write a test: `scanMemoryFiles` returns headers newest-first, excludes `MEMORY.md`, and respects the 200 cap.
- Write a test: `formatMemoryManifest` emits `- [feedback] foo.md (<ts>): desc` for a typed/described file and `- bar.md (<ts>)` for a bare one.
- Write a test: the selector falls back to the deterministic renderer when the model call errors (inject a failing mock provider) and never panics.
- Write a test: `alreadySurfaced` filters a path out of the manifest before the model call.

**Test strategy.** Manifest/scan tests are pure + tmpdir-based. The selector test uses the existing mock provider (the repo has a mock provider adapter) to return a canned `{ "selected_memories": [...] }` and an error case. Run under `tools/test_runner.zig`.

**Risk / footguns.** Do NOT make this the only path - the deterministic scorer is tested and works offline; a mandatory network call per prompt would regress latency and break air-gapped use. Keep the side-query best-effort and behind `allow_network`. `appendResponseSchemaToBody` no-ops on malformed buffers - assert the body ends in `}` before calling. Provider support for `response_format` varies; the Anthropic path uses tool-schema-style structured output, so verify the selected provider before requiring strict JSON, and tolerate a plain-text JSON blob.

**Size.** M.

---

### Task 5: Turn-end memory extraction forked agent (memory-01)

**Goal.** After a complete query loop (final assistant response, no tool calls), run a constrained background extraction agent that reads recent conversation and writes new memories - throttled, cursor-tracked, and mutually exclusive with main-agent writes.

**Reference behavior.** `initExtractMemories`/`runExtraction`/`executeExtractMemoriesImpl` (`src/services/extractMemories/extractMemories.ts:296-587`): counts model-visible messages since a cursor (`:82-110`), throttles to every N eligible turns (default 1, `:377-385`), skips when the main agent already wrote to memory files (`hasMemoryWritesSince`, `:121-148`) and advances the cursor past that range, pre-injects the memory manifest (`scanMemoryFiles`/`formatMemoryManifest`), runs with `createAutoMemCanUseTool` (Read/Grep/Glob unrestricted, read-only Bash, Edit/Write only within the auto-mem dir, `:171-222`), caps `maxTurns=5`, advances the cursor only on success, supports coalesced/trailing runs, and emits a "Memory updated" system message. The extraction prompt is `buildExtractAutoOnlyPrompt` (`src/services/extractMemories/prompts.ts:50-94`).

**Target Zig files.**
- Create `src/core/extract_memories.zig` (new deep module): cursor/throttle state struct, the constrained tool filter, the extraction prompt builder, and the public `maybeExtract` entry point. Register in `src/main.zig` comptime block.
- Edit `src/agent_runtime.zig`: add a `ExtractState` field to `AgentRuntime` (cursor index + turns-since-last counter), and call `extract_memories.maybeExtract(...)` at the turn-end site (right next to the existing `maybeRunDream` call at `:1980-1983`), gated on `interactive and depth == 0` and `memory_gate.isAutoMemoryEnabled`.
- Edit `src/agent_tools.zig`: add `pub fn filterAutoMemSchemas(allocator, schemas) ![]ToolSchema` keeping only Read/Grep/Glob/Bash/Edit/Write/MultiEdit (the path/read-only enforcement happens at execution time via the context).

**Approach.**
1. Define the extraction prompt builder porting `buildExtractAutoOnlyPrompt` + the shared `opener`: "You are now acting as the memory extraction subagent. Analyze the most recent ~N messages..." plus the available-tools sentence, the two-turn read-then-write efficiency note, the "only use content from the last ~N messages" constraint, the existing-memory manifest, the `TYPES_SECTION_INDIVIDUAL`/`WHAT_NOT_TO_SAVE`/two-step-save sections (reuse Task 2's `memory_prompt` constants). Substitute the resolved memory dir.
2. Cursor + throttle: store a per-`AgentRuntime` `last_extract_turn` counter and a `turns_since_last_extraction`. On each turn-end, increment; only run when `turns_since_last_extraction >= 1` (the configurable N defaults to 1). Because zcode's history is turn-based (`HistoryTurn`), the "model-visible message count since cursor" maps to "turns appended since the last extraction index" - track a `cursor_turn_index` into `self.history` and count assistant/user turns past it.
3. Mutual exclusion: implement `hasMemoryWritesSince` by scanning the turns since the cursor for any tool-call to Edit/Write/MultiEdit whose `file_path` is `isAutoMemPath`. zcode records tool outcomes in the snapshot/history; if file paths of writes are not currently captured per-turn, add a lightweight `auto_mem_written_this_turn: bool` flag set by the Edit/Write tool dispatch when the target is under the auto-mem dir (set in `agent_tools` execution path). When set, skip the fork and advance the cursor.
4. Spawn the constrained child using the `maybeRunDream` template (`agent_runtime.zig:2802-2827`): `AgentRuntime.init(... interactive=false ...)`, `child.depth = self.depth + 1`, `child.max_tool_rounds_override = 5` (the `maxTurns=5` cap), and restrict its tool schemas via `filterAutoMemSchemas` + an execution-time path guard. The child must NOT recurse into its own extraction (`depth > 0` short-circuits `maybeExtract`).
5. Path enforcement at execution time: in the child's tool-exec context, deny Edit/Write/MultiEdit whose target is not `isAutoMemPath`, and deny non-read-only Bash. Reuse the existing per-tool permission/sandbox decision path (`agent_tools.zig:606-616` area) with an `auto_mem_only: bool` context flag.
6. Pre-inject the manifest from Task 4's `scanMemoryFiles`/`formatMemoryManifest` into the prompt so the child does not waste a turn on `ls`.
7. On success, advance the cursor to the latest turn and emit a "Memory updated" system message listing the written topic files (exclude `MEMORY.md`). On error, leave the cursor untouched so the next turn reconsiders the range. Best-effort: never propagate the extraction error to the main turn result.

**Acceptance criteria.**
- Write a test for `hasMemoryWritesSince`: given a synthetic turn list where one assistant turn wrote to a path under the auto-mem dir, returns true; otherwise false.
- Write a test for the throttle: with N=1 the second eligible turn runs; with a higher N it skips until the count is reached.
- Write a test that the extraction prompt builder substitutes the message count and memory dir and contains the four type names and the "only use content from the last" constraint.
- Write a test that `filterAutoMemSchemas` keeps Read/Grep/Glob/Bash/Edit/Write and drops everything else (e.g. WebFetch, AgentRun).
- Integration: with a mock provider that the child uses to emit a Write to a path inside the tmp auto-mem dir, assert the file is created and a "Memory updated" message is produced; with the same Write targeting a path OUTSIDE the dir, assert it is denied.

**Test strategy.** Unit tests for the pure pieces (prompt builder, throttle, `hasMemoryWritesSince`, filter) run fast under the custom runner. The integration spawn test uses the mock provider and `tmpDirPath` for the auto-mem dir; gate it so it does not require network. Print `RUN:` lines come for free from the runner.

**Risk / footguns.**
- Recursion guard is mandatory: the child is itself an `AgentRuntime`; `maybeExtract` must early-return when `depth > 0` or `!interactive`, exactly as `maybeRunDream` only fires at `depth == 0`.
- Do not call `child.wait()`-style reaping incorrectly. zcode's child is in-process (an `AgentRuntime`, not an OS process), so the `Child.kill`/`wait` 0.16 gotcha does not apply here directly - but if the extraction is ever moved to a spawned process, recall `Child.kill(io)` reaps internally; never `wait()` after.
- Synchronous vs background: the reference runs the fork in the background and drains it before shutdown. zcode's `maybeRunDream` runs synchronously inline at turn end. Follow the synchronous model for v1 (simpler, matches dream) and note background execution as deferred. Synchronous means the extraction adds latency to the final turn - keep `max_tool_rounds_override=5` and the read-then-write two-turn guidance to bound it.
- The cursor must survive across turns within one `AgentRuntime` instance but reset on `/clear` and `/compact` (hook into the same invalidation the instruction cache uses).

**Size.** L.

---

### Task 6: SessionMemory background summarizer (memory-05)

**Goal.** Maintain a per-session markdown notes file via a constrained forked agent that fires on token/tool-call thresholds, with a manual `/summary`-triggered path.

**Reference behavior.** Post-sampling hook gated on auto-compact (`src/services/SessionMemory/sessionMemory.ts:357-375`). `shouldExtractMemory` (`:134-181`) fires when context-token and tool-call thresholds are met: `DEFAULT_SESSION_MEMORY_CONFIG` = init 10000 tokens, 5000 tokens between updates, 3 tool calls between updates (`sessionMemoryUtils.ts:32-36`). Runs only on the main REPL thread, writes via a `canUseTool` restricted to Edit on the exact memory file (`:460-482`), `manuallyExtractSessionMemory` bypasses thresholds for `/summary` (`:387-453`).

**Target Zig files.**
- Create `src/core/session_memory.zig` (new deep module): config constants, threshold checks, the per-session notes file path resolver, the update-prompt builder, and the extraction entry point. Register in `src/main.zig` comptime block.
- Edit `src/agent_runtime.zig`: add session-memory state (tokens-at-last-extraction, initialized flag, tool-calls-since cursor) and call `session_memory.maybeExtract(...)` at the turn-end site alongside Task 5, gated on `interactive and depth == 0` and the auto-compact-enabled config.
- Edit `src/repl_commands.zig`: wire `/summary` (existing handler at `:1805`) to also trigger `session_memory.manualExtract(...)` so it persists notes, in addition to the current inline stats display (surgical - keep the existing display, append the persist call).

**Approach.**
1. Port `DEFAULT_SESSION_MEMORY_CONFIG` (10000 / 5000 / 3). Implement `shouldExtract(token_count, tokens_at_last, initialized, tool_calls_since) bool` matching the reference logic: must meet the init threshold once (latch `initialized`), then fire when (token-growth threshold AND tool-call threshold) OR (token-growth threshold AND no tool calls in the last turn).
2. Session notes path: `<session dir>/session-memory/<session_id>.md` (use the existing session-id + store paths). Create with a template on first write (`loadSessionMemoryTemplate` equivalent - a short markdown skeleton with sections like "## Goal", "## Decisions", "## Open threads").
3. Update-prompt builder: port `buildSessionMemoryUpdatePrompt(current_memory, memory_path)` - instruct the fork to Edit the one file with distilled notes from the conversation, nothing else.
4. Constrained fork: spawn a child `AgentRuntime` (the `maybeRunDream` template) restricted to Edit-on-exact-file only. Implement a tool filter + execution-time guard that denies any tool except `Read`+`Edit` on `memory_path`. The child must Read the file first (Edit requires a prior Read in zcode just as in the reference).
5. Token counting: reuse the existing tokenizer/usage path (`prompt_helpers` imports `tokenizer.zig`; compaction already computes token usage at `compaction.zig:132`). Feed the same context-window token count the compaction path uses so thresholds are consistent.
6. Manual path: `manualExtract` bypasses `shouldExtract` and always runs (used by `/summary`).

**Acceptance criteria.**
- Write a test for `shouldExtract`: below init threshold -> false; at init threshold -> latches and may fire; after init, only fires when token-growth AND (tool-call threshold OR no-tools-last-turn).
- Write a test that the session notes path is session-scoped and stable across calls within a session.
- Write a test that the update prompt names the exact memory path and instructs Edit-only.
- Integration: with a mock provider, `manualExtract` creates/updates the per-session notes file; a tool filter test confirms only Edit-on-the-file is permitted.

**Test strategy.** Threshold/path/prompt tests are pure or tmpdir-based. The fork test uses the mock provider + `tmpDirPath`. Run under `tools/test_runner.zig`.

**Risk / footguns.**
- Naming collision: zcode already has a `.session_memory` *context-block* type (`types.zig:44`, `context.zig:724`) that carries task-state snapshots - that is a DIFFERENT feature. Do not overload it. The new module is conversation-notes distillation feeding compaction; name the module/file clearly and add a header comment disambiguating from the context block.
- This runs on the main thread only (the reference gates `querySource === 'repl_main_thread'`). In zcode terms: `depth == 0` and `interactive`. Enforce it.
- Like Task 5, run synchronously inline for v1; background post-sampling is deferred. Bound the fork to a few tool rounds.
- File creation must be O_EXCL-then-template to avoid clobbering an existing notes file - reuse the atomic-write discipline from `memory.zig:299`.

**Size.** L.

---

### Task 7: HTML-comment stripping in instruction content (memory-08)

**Goal.** Strip block-level HTML comments (`<!-- ... -->`) from instruction (CLAUDE.md / ZCODE.md / rules) content before it enters the prompt, preserving comments inside fenced/inline code and leaving unclosed comments intact.

**Reference behavior.** `stripHtmlComments`/`stripHtmlCommentsFromTokens` (`src/utils/claudemd.ts:292-334`) use the marked lexer to strip block-level comments only; comments inside inline code spans and fenced blocks are preserved; unclosed comments are left in place; sets `contentDiffersFromDisk` so the cached read state is a partial view (`:235-243`).

**Target Zig files.**
- Edit `src/core/instructions.zig`: add `fn stripHtmlComments(allocator, content) !struct{bytes: []u8, stripped: bool}` and call it in `addInstructionFile` after the content is read (`:409-462`) and before the entry is appended (`:452`). Reuse the existing fence-tracking loop logic that `parseImports` already has (`:741-785`).
- Optionally extend `types.InstructionEntry` (`types.zig:85-93`) with `content_differs_from_disk: bool = false` to record that the injected content no longer matches disk (parity with `contentDiffersFromDisk`); only add if a downstream consumer needs it, otherwise skip (YAGNI).

**Approach.**
1. Implement a CommonMark-subset block-comment stripper without a full lexer: walk lines, track fenced-code state exactly like `parseImports` (toggle on ```` ``` ```` / `~~~`), and track inline-code backtick state within a line. A line that, when trimmed, starts with `<!--` and is outside any fence is treated as the start of an HTML block; strip from `<!--` to the matching `-->` (which may span multiple lines). If no `-->` is found before EOF, leave the comment in place (do not swallow the rest of the file). Preserve any residual text on the line after `-->`.
2. Do NOT strip `<!--` that appears inside an inline code span or a fenced block (the reference preserves those). The simplest faithful behavior: only treat a comment as block-level when the trimmed line begins with `<!--` and we are not inside a fence. This matches the reference's "authorial notes on their own lines" intent.
3. Skip the work entirely (fast path) when the content does not contain the substring `<!--` (mirrors the reference's `if (!content.includes('<!--'))`).
4. Apply in `addInstructionFile` before the byte-budget accounting so the stripped (smaller) content is what counts against `total_cap`.

**Acceptance criteria.**
- Write a test: a CLAUDE.md body with a standalone `<!-- author note -->` block has the comment removed from the injected content.
- Write a test: `<!--` inside a fenced ```` ``` ```` block is preserved.
- Write a test: `` `<!-- x -->` `` inside an inline code span on a prose line is preserved (or, per the simplified rule, only block-start comments are stripped - assert the chosen behavior explicitly).
- Write a test: an unclosed `<!--` with no `-->` leaves the rest of the file intact.
- Write a test: content with no `<!--` is returned byte-identical (fast path).

**Test strategy.** Pure-function tests in `instructions.zig` under the custom runner.

**Risk / footguns.** Do not pull in `html_to_text.zig` - it is HTML-to-text for WebFetch and would mangle markdown. The fence-state logic must match `parseImports` so the two passes agree on what is code. Avoid CRLF round-trip issues: operate on the raw bytes and only rewrite the comment spans, leaving line endings untouched (the reference had a specific bug here where lexer round-tripping flipped `contentDiffersFromDisk` on CRLF files - sidestep it by not normalizing).

**Size.** S.

---

### Task 8: Path-scoped conditional instruction rules (memory-09)

**Goal.** Let `.claude/rules/*.md` files declare `paths:`/`globs:` frontmatter; inject such a rule only when the current cwd or an edited path matches one of its globs.

**Reference behavior.** `parseFrontmatterPaths` (`src/utils/claudemd.ts:254-279`) reads `paths` from frontmatter, strips trailing `/**`, treats all-`**` as no gating. `processConditionedMdRules` (`:1354-1397`) loads conditional rule files and filters to those whose globs match the target path (relative to the directory containing `.claude`). `getManagedAndUserConditionalRules`/`getConditionalRulesForCwdLevelDirectory` resolve per directory level (`:1205-1342`).

**Target Zig files.**
- Edit `src/core/types.zig`: add `globs: []const []const u8 = &.{}` to `InstructionEntry` (struct at `:85-93`), and free it in the entry-free path.
- Edit `src/core/instructions.zig`: in `scanRulesDirectory` (`:331-389`) parse frontmatter `paths`/`globs` for each rules file; if present and non-trivial, gate inclusion on a glob match against the current target path; if absent or all-`**`, include unconditionally (current behavior).
- Reuse `src/core/skill_visibility.zig:69` (`globMatch`) and `:48` (`matchesAnyPath`) for the match - do not write a new matcher.

**Approach.**
1. Add a `target_paths: []const []const u8 = &.{}` field to `DiscoverOptions` (`instructions.zig:13-31`) carrying the cwd plus any explicitly-edited paths the caller wants to match against. Default to just the cwd so behavior is stable when callers do not supply edited paths.
2. In `scanRulesDirectory`, before calling `addInstructionFile`, read the file's frontmatter via `frontmatter.extract`/`getValue` for a `paths` (and accept `globs` as an alias) key. Parse it (comma- and/or newline-separated), strip trailing `/**`, drop empties. If the parsed set is empty or all-`**`, load the rule unconditionally (unchanged). Otherwise, only load it when `skill_visibility.matchesAnyPath(globs, opts.target_paths)` is true.
3. Make glob patterns relative to the directory containing `.claude` (parent of the rules dir), matching the reference's `dirname(dirname(rulesDir))` base. Convert absolute target paths to that-relative form before matching; reject `..`-escaping and absolute relatives (return no-match), per the reference guard.
4. Store the parsed globs on the resulting `InstructionEntry.globs` so future per-edit re-evaluation is possible (and so a test can assert what was parsed).

**Acceptance criteria.**
- Write a test: a rules file with `paths: src/api/**` is loaded when `target_paths` contains `src/api/handler.zig` and omitted when it contains only `src/ui/view.zig`.
- Write a test: a rules file with no `paths` frontmatter loads unconditionally (current behavior preserved).
- Write a test: `paths: **` (match-all) loads unconditionally.
- Write a test: the `/**` suffix is stripped (so `src/api/**` matches `src/api` itself and `src/api/x.zig`).

**Test strategy.** Tmpdir-based tests in `instructions.zig`: create `.claude/rules/foo.md` with frontmatter, run `discover` with varying `target_paths`, assert presence/absence. Use `tmpDirPath` for an absolute cwd.

**Risk / footguns.** `globMatch` treats `**` the same as `*` (per its doc comment) - acceptable for this subset, but document that nested-dir semantics are approximate. Keep this surgical: do not change the precedence (60) or the unconditional rules-dir load behavior; only add the gate. Skills already parse `paths` from frontmatter (`skill_types.zig`) - mirror that parsing shape so the two stay consistent.

**Size.** M.

---

## Verification

Build and install per CLAUDE.md (mandatory after every change):

```
/Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build -Doptimize=ReleaseFast
rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode
```

(Use `rm -f` first - overwriting the binary in place invalidates the ad-hoc code signature and the next run is SIGKILLed with exit 137.)

Bump `.version` patch in `build.zig.zon` (the git short-hash is appended automatically by `build.zig`).

Test gate (all new tests run under the custom runner wired in `build.zig`):

```
/Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build test
```

Per-gap proof:
- **memory-01:** Start an interactive session, hold a short conversation where the user states a durable preference ("always use tabs"), end the turn. Confirm a new `.md` appears under the resolved auto-mem dir and a "Memory updated" line is shown. Confirm that when the main agent itself wrote a memory that turn, the fork is skipped (check debug log / no duplicate file).
- **memory-02:** `zcode prompt` (the prompt-inspect path) and grep the dynamic system policy for `## Types of memory`, the four type names, `## What NOT to save in memory`, and `## Searching past context`. Confirm no em/en dashes.
- **memory-03:** With a network-capable provider, issue a query that should match one memory by description; confirm the selected memory is injected. With `--no-network` / mock, confirm the deterministic fallback still injects keyword-matched memories.
- **memory-04 / memory-11:** Place a >200-line and a >25KB `MEMORY.md` in the auto-mem dir; `zcode prompt` and confirm the `## MEMORY.md` section appears truncated with the correctly-named cap warning.
- **memory-05:** Run a long enough session to cross the 10000/5000/3 thresholds (or run `/summary`) and confirm a per-session notes file is created/updated under the session dir.
- **memory-08:** Put a `<!-- secret note -->` block in `CLAUDE.md`; `zcode prompt` and confirm the comment is absent from the injected instructions while a fenced `<!--` is preserved.
- **memory-09:** Add `.claude/rules/api.md` with `paths: src/api/**`; confirm via `zcode prompt` it is injected only when the cwd/target is under `src/api` and omitted otherwise.
- **memory-10:** `ZCODE_DISABLE_AUTO_MEMORY=1 zcode prompt` shows no memory taxonomy/index sections; unset shows them. `--bare` disables. A valid `auto_memory_directory` setting redirects the dir; an invalid one (relative) is rejected and falls back to default.

Manual sanity: `zcode version` runs (proves the signature is valid post-install), and `zcode` starts an interactive session without panicking on the new turn-end hooks.

## Out-of-scope / deferred notes

- **Background / async execution of the extraction and session-memory forks.** The reference runs both as background forked agents and drains them at shutdown (`drainPendingExtraction`, post-sampling hooks). This phase runs them synchronously inline at turn end, matching zcode's existing `maybeRunDream` model. Asynchronous execution, coalesced/trailing-run queuing, and a shutdown drain are deferred to a follow-up once the synchronous behavior is proven correct.
- **Prompt-cache sharing ("perfect fork").** The reference forks share the parent's prompt cache (`createCacheSafeParams`, `runForkedAgent`). zcode's child `AgentRuntime` does not share a prompt-cache prefix today; the extraction child will pay full input cost. Caching parity is a separate, larger effort tied to provider-side cache control and is out of scope here.
- **Team memory (TEAMMEM).** All team-memory branches in the reference (`teamMemPaths`, `buildExtractCombinedPrompt`, combined `MEMORY.md` indexes, sensitive-data guardrails) are feature-gated and out of scope. Only the auto-only (single-directory) variants are ported.
- **Assistant daily-log mode (KAIROS).** `buildAssistantDailyLogPrompt` and `getAutoMemDailyLogPath` (append-only daily logs distilled nightly) are gated behind the assistant feature and not part of this phase. zcode's `kairos.zig` exists but this memory variant is not wired.
- **Analytics / telemetry events.** The reference emits many `tengu_*` GrowthBook/analytics events around these features. zcode has no GrowthBook; the corresponding feature flags (`tengu_passport_quail`, `tengu_bramble_lintel`, `tengu_session_memory`, `tengu_moth_copse`, `tengu_coral_fern`, etc.) become always-on defaults, and the analytics calls are dropped. The throttle N (`tengu_bramble_lintel`) becomes a fixed default of 1, optionally exposed via config if a user need arises (deferred).
- **`contentDiffersFromDisk` / partial-view read-state caching for instructions (memory-08).** The reference threads `rawContent` into a `readFileState` so a later Edit still requires a fresh Read. zcode's instruction pipeline does not feed an Edit read-state cache, so the partial-view bookkeeping is unnecessary; only the stripping itself is ported. If a future feature lets the model Edit a loaded CLAUDE.md, revisit.
- **`reference`-type recently-used-tool exclusion heuristic (memory-03).** Ported in a minimal form (drop reference/API-doc memories naming a recently-used tool unless they contain warning/gotcha words). The reference's richer signal (actual tool-use telemetry) is approximated from the current turn's tool calls; full fidelity is deferred.
