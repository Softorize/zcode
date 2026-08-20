# Phase 15: UI rendering and terminal layer: word-diff, thinking blocks, compact boundary, spinner, terminal probes, mouse/keys, color

## Overview

**What.** This phase closes the remaining gaps in zcode's UI rendering layer (diff
presentation, thinking artifacts, compact-boundary affordance, spinner glyph) and its
terminal layer (input-stream response parsing, capability probes, mouse/modifier decoding,
and color/level handling). It is split into two clusters that share almost no code:

- **UI rendering cluster (ui-render-01..08, 12):** a `changeRatio` guard before word-diff
  highlighting, a real multi-segment word-token diff (replacing the single-affix middle),
  the `#` memory-capture input mode with CLAUDE.md persistence, a persistent collapsed
  thinking artifact in the transcript with full-block expansion, a styled compact-boundary
  line (glyph + Ctrl+O hint), an env-gated syntax-highlight toggle for diff content, an
  optional interactive multi-file diff navigator, an animated multi-frame spinner glyph with
  reduced-motion and stalled-color interpolation, and a sandbox-violation footer hint.
- **Terminal layer cluster (terminal-01..11):** terminal-response parsing (DA1/DA2/DECRPM/
  DSR/OSC/XTVERSION) routed out of the keypress path, an XTVERSION async terminal-name probe
  for SSH-safe identification, DEC 2026 synchronized-output detection plus BSU/ESU frame
  wrapping, OSC 9;4 taskbar progress reporting, full SGR mouse click/drag/release decoding,
  super/fn/numpad modifier decoding, a runtime tmux truecolor->256 clamp plus xterm.js color
  boost, an RGB->ANSI256 quantizer to back the clamp, more accurate grapheme/emoji width, and
  the Windows conhost cursor-up-yank guard.

**Why.** Several of these are genuine visible-behavior gaps:
- Without `changeRatio` (ui-render-01) and a real token diff (ui-render-02), zcode
  over-highlights near-total rewrites and the unchanged middle of lines with two separated
  edits, producing noisier diffs than the reference.
- The `#` memory mode (ui-render-03) is a first-class reference input affordance that zcode
  cannot do at all; users cannot append durable memory from the prompt line.
- Under default tmux, zcode's truecolor brand-accent / approval-fill escapes can render with
  wrong or missing backgrounds on the outer terminal (terminal-07). This is the single most
  user-visible terminal-layer bug, and the only current mitigation is manually selecting a
  `*-ansi` theme.
- Terminal-response parsing (terminal-01) is the foundation for any query/reply handshake
  (background-color via OSC 11, terminal name via XTVERSION over SSH, mode status via
  DECRPM). zcode's input parser currently has no concept of an inbound response at all.

The rest are lower-severity correctness/cosmetic items (synchronized output, progress bar,
mouse coordinates, fn/numpad keys, conhost guard) included for completeness and so the
terminal layer reaches reference parity.

**Dependencies.**
- **Phase 8 (compaction):** the styled compact-boundary message (ui-render-05) renders at
  the compaction point. Phase 8 lands the structured compact-boundary marker
  (`compaction-14`) and the system note appended at `agent_history.zig:287`. This phase
  styles that boundary (glyph + Ctrl+O hint + dim). If Phase 8's structured marker exists,
  ui-render-05 attaches to it; if only the plain system note exists, ui-render-05 still works
  by special-casing the boundary string at render time. Either way the data source must be
  in place first.

**Effort.** XL. The terminal-response parser (terminal-01) is M but is the spine that
terminal-02 (XTVERSION) and parts of terminal-05/06 hang off. The real word-token diff
(ui-render-02), the persistent thinking artifact (ui-render-04), and the runtime tmux clamp
(terminal-07, with terminal-08 as its backing quantizer) are the largest single items. The
interactive multi-file diff navigator (ui-render-08) is L and explicitly deferable for a CLI.
Everything else is S/M.

**Survey-correction notes.** All gaps were re-verified against the reference
(`/Users/example/Downloads/claude-code-main/src`) and our Zig source. Corrections to the input
survey:
- **ui-render-04 over-states the keybinding gap.** Ctrl+O already exists and toggles the
  transcript (`repl_input.zig:819`, `.toggle_transcript`). The reference's "Ctrl+O to expand
  thinking" IS the transcript toggle (`CompactBoundaryMessage.tsx` uses the same
  `app:toggleTranscript`/`ctrl+o` shortcut). So the missing piece is not a new keybinding; it
  is (a) persisting `reasoning_text` into history instead of freeing it, and (b) rendering it
  as a collapsed `∴ Thinking` line in non-transcript view and a full dim Markdown block in
  transcript view. Scope reduced accordingly.
- **ui-render-05 is small and the glyph already exists.** `figures.TEARDROP_ASTERISK`
  (`figures.zig:140`, the `✻` byte sequence `\xe2\x9c\xbb`) is defined and tested but unused
  in the compaction note. This is a string-format + styling change, not new infra.
- **ui-render-07 is mostly present.** Context lines AND +/- solo lines already get syntax
  highlighting (`repl_edit.zig:830,837`). Only the word-diff *pair* path
  (`writeDiffCodePair`, `repl_edit.zig:851`) deliberately skips it. The true gap is just the
  `CLAUDE_CODE_SYNTAX_HIGHLIGHT` env gate; consistent pair-line highlighting is a design
  choice we will keep skipping (layering intra-line accent on syntax colors is noisy).
- **terminal-06 and terminal-10 are partly present_different design choices.** zcode's
  event-oriented chord->InputEvent parser intentionally avoids a general `ParsedKey`. fn/
  numpad keys are irrelevant for a prompt-line editor. terminal-10's conhost bug cannot
  actually trigger because zcode uses absolute cursor positioning, never cursor-up redraws.
  We implement the *detection* functions for completeness (cheap, pure) but explicitly do not
  rework the parser into a full ParsedKey model.
- **terminal-09 width module is infra-complete but unwired.** `wcwidth.zig` exists with broad
  coverage but is not used by the prompt-line/render layer per its own note. The accuracy
  improvements (regional-indicator pairs, ZWJ-sequence collapse, keycaps) require operating at
  the grapheme-cluster level, which `displayWidth` does not do (it sums per-codepoint). This
  is the real gap.

## Gaps covered

| id | title | severity | size | our current state |
|---|---|---|---|---|
| ui-render-01 | Word-diff change-ratio threshold (0.4) fallback to full-line highlight | low | S | `writeDiffCodePair` (`repl_edit.zig:851-913`) always word-highlights via `commonAffixes`; no `changeRatio` calc, no 0.4 guard, no fall-through to solo add/remove lines |
| ui-render-02 | True word-token diff (multi-segment) vs single-affix middle | low | M | `commonAffixes` finds ONE prefix + ONE suffix (`word_diff.zig:16-27`); `tokenize` exists (`word_diff.zig:54-56`) but is unused by the renderer; lines with two separated edits over-highlight the unchanged middle |
| ui-render-03 | Memory mode (`#` prefix) input + "remembering" message | medium | M | `/memory` subcommands exist (`repl_commands.zig`) but no `#`-prefix input mode, no `<user-memory-input>` wrapping, no auto-append to CLAUDE.md, no Got it./Good to know./Noted. confirmation |
| ui-render-04 | Persistent collapsed thinking indicator (∴ Thinking) + full block | medium | M | `reasoning_text` extracted then freed (`agent_runtime.zig:1169`); `appendThinkingSummary` is a no-op (`repl.zig:806-820`); thinking is spinner-only, never persisted; no `∴ Thinking` transcript line; no full dim Markdown block |
| ui-render-05 | Styled compact-boundary message (✻ + Ctrl+O for history) | low | S | Plain note "Conversation compacted by control action." (`agent_history.zig:287`); `✻` glyph defined but unused (`figures.zig:140`); no Ctrl+O hint; no dim styling |
| ui-render-06 | Animated multi-frame spinner glyph + reduced-motion + stalled color | low | M | Single static `●` (`repl_spinner.zig:507-509`); REDUCE_MOTION suppresses spinner entirely (`repl_spinner.zig:468-484`); stalled state changes label text only, no RGB interpolation toward error red |
| ui-render-07 | Env-gated syntax-theme coloring of diff content | low | S | Context + solo +/- lines highlighted (`repl_edit.zig:830,837`); pair lines deliberately skip it (`repl_edit.zig:848-850`); no `CLAUDE_CODE_SYNTAX_HIGHLIGHT` gate anywhere |
| ui-render-08 | Interactive multi-file diff dialog / file list navigator | low | L | Static stacked cards, capped at 3 files (`repl_edit.zig:116-159`, `MAX_DIFF_FILES=3`); no overlay type for diffs; no per-file selection/navigation |
| ui-render-12 | Sandbox-violation footer hint | low | M | Footer notification infra exists (`repl_footer.zig:22-28`, `repl.zig:1630-1699`, `buildPromptStripItems`); `prompt_notifications` never populated by sandbox events; `core/sandbox.zig` has no violation store |
| terminal-01 | Terminal-response parsing (DA1/DA2/DECRPM/DSR/OSC/XTVERSION) | medium | M | Input parser recognizes keypresses + wheel only (`repl_input.zig:672-850`); `InputEvent` enum is action-only; no response type, no emission path; zero matches for DA1/DA2/DECRPM/XTVERSION/DSR |
| terminal-02 | XTVERSION async terminal-name probe (SSH-safe) | low | M | `enable()` sends Kitty `\x1b[>1u` (`repl_input.zig:37`); detection is env-only (`terminal_caps.zig`); no `CSI >0q` query, no DCS reply parsing, no `isXtermJs`/`supportsExtendedKeys` |
| terminal-03 | DEC 2026 synchronized output detection + BSU/ESU frame wrapping | low | M | Absent. No capability detector, no terminal whitelist, no frame wrapping; only a test-string match for `?2026` in `tools/shell.zig:1140` |
| terminal-04 | OSC 9;4 progress-bar reporting | low | S | OSC 9/99/777 notifications exist (`notifier.zig`); text progress in `ProgressReporter`; no OSC 9;4, no version-gated detection, no `isProgressReportingAvailable` |
| terminal-05 | Mouse click/drag/release (ParsedMouse) - currently wheel-only | low | M | X10 + SGR parse only extract wheel buttons 64/65 (`repl_input.zig:715-763`), discard coordinates/action; `InputEvent` has no click/drag/release variants |
| terminal-06 | Super (Cmd/Win) modifier + fn/numpad decoding | low | M | `kittyModifierFlags` decodes bits 0-3 only (`repl_input.zig:340-349`), no bit-8 super; `csiChord` handles A/B/C/D/H/F/Z only (`repl_input.zig:318-331`); no fn/numpad |
| terminal-07 | tmux truecolor->256 clamp + xterm.js color boost | medium | M | Static palettes only (`ui_theme.zig`); `terminal_caps` reports but never adjusts; no `$TMUX` runtime clamp, no FORCE_COLOR/level handling; truecolor escapes can mis-render under tmux |
| terminal-08 | RGB->ANSI256 quantization (ansi256_from_rgb) | low | S | Absent. Hand-authored 256-color and 16-color palettes; no runtime RGB->256 cube/grey-ramp mapping |
| terminal-09 | stringWidth grapheme/emoji accuracy | low | M | `wcwidth.zig` sums per-codepoint; no regional-indicator pairs, no ZWJ-sequence collapse, no keycap special case, no grapheme-cluster API; unwired from render layer |
| terminal-10 | hasCursorUpViewportYankBug (Windows conhost guard) | low | S | WT_SESSION detected for clear-sequence selection (`format.zig:455,487-498`); no dedicated guard fn; renderer is immune (absolute positioning) but the fn is absent |
| terminal-11 | Spinner glyph set - static vs platform-aware breathing cycle | low | S | Merged with ui-render-06: single static `●` + braille pulse; documented deviation (`repl_spinner.zig:500-509`); no `·✢✳✶✻✽` cycle, no reduced-motion dot, no stalled RGB lerp |

## Implementation tasks

Tasks are ordered so shared infrastructure lands first. Task 10 (terminal-response parser) is
the spine for tasks 11 (XTVERSION). Task 17 (RGB->256 quantizer) backs task 16 (tmux clamp).
Within each cluster the tasks are otherwise independent and several are parallelizable.

---

### Task 1 - Word-diff change-ratio threshold (ui-render-01)

**Goal.** Before highlighting an intra-line word-diff pair, compute the change ratio and fall
back to plain solo add/remove lines when it exceeds 0.4.

**Reference behavior.** `generateWordDiffElements` computes
`changeRatio = changedLength / totalLength` over the `diffWordsWithSpace` parts and returns
`null` when `changeRatio > CHANGE_THRESHOLD (0.4)` or when `dim`, so the renderer falls back
to plain full-line add/remove coloring. Ref: `src/components/StructuredDiff/Fallback.tsx:80`
(`CHANGE_THRESHOLD = 0.4`), `:252-258` (the guard).

**Target Zig files.**
- `src/core/word_diff.zig` (edit): add a pure `changeRatio` helper.
- `src/cli/repl_edit.zig` (edit): in `renderDiffSection` (the `.add` arm at `:636-645` that
  calls `writeDiffCodePair`), consult the ratio and fall back to two solo `writeDiffCodeLine`
  calls when it exceeds the threshold.

**Approach.**
1. In `word_diff.zig`, add:
   ```
   pub const CHANGE_THRESHOLD_PERCENT: usize = 40; // 0.4, integer math
   /// changedLength/totalLength using commonAffixes as the proxy for the
   /// changed run. Returns the percentage 0..100 (integer) so callers can
   /// compare against CHANGE_THRESHOLD_PERCENT without floats.
   pub fn changeRatioPercent(old: []const u8, new: []const u8) usize
   ```
   Implementation: `af = commonAffixes(old, new)`; `changed = (old.len - af.prefix - af.suffix) + (new.len - af.prefix - af.suffix)`; `total = old.len + new.len`; if `total == 0` return 0; return `changed * 100 / total`. Note: this uses the affix middle as the changed-length proxy, which is conservative (single contiguous middle). After Task 2 lands the real token diff, update this to sum the changed token lengths so it matches the reference's multi-segment `changedLength`.
2. In `repl_edit.zig`, change the `.add` arm so that when a `pending_remove` exists it first
   computes the ratio over the *clipped* display strings (the same ones `writeDiffCodePair`
   would use - clip first, then ratio, so the proxy matches what gets rendered). If
   `changeRatioPercent(old_display, new_display) > CHANGE_THRESHOLD_PERCENT`, emit the remove
   as a solo `.remove` line and the add as a solo `.add` line (both with syntax highlighting
   via `writeDiffCodeLine`) instead of calling `writeDiffCodePair`. Otherwise keep the pair
   path.
3. Factor the clip-then-decide so the clip happens once (avoid clipping twice).

**Acceptance criteria.**
- New test in `word_diff.zig`: `changeRatioPercent("foo_bar_baz", "foo_quux_baz")` is well
  under 40 (small middle); `changeRatioPercent("abc", "xyz")` is 100; `changeRatioPercent("", "")` is 0.
- New test in `repl_edit.zig` (or a small focused renderer test): a `-`/`+` pair that differs
  in only a few chars renders with the bright `\x1b[41;97m`/`\x1b[42;30m` word spans; a pair
  that differs almost entirely (e.g. `- old line text` / `+ totally different content here`)
  renders as two solo lines with NO `\x1b[41;97m` span.

**Test strategy.** Both run under `tools/test_runner.zig` via `zig build test`. The renderer
test writes into a fixed `[8192]u8`, runs `formatDiffBlock`, and asserts on the presence/
absence of the bright word-span SGR codes.

**Risk / footguns.** Integer division truncates - that is fine for a threshold compare but
keep the `* 100` before the divide. Clip-before-ratio matters: `writeDiffCodePair` clips with
`clipMiddleInto` to `content_max`, so the ratio must be computed on the same clipped bytes or
the decision will diverge from what is shown.

**Size.** S.

---

### Task 2 - True word-token diff (ui-render-02)

**Goal.** Replace the single-affix middle in `writeDiffCodePair` with a real multi-segment
word-token diff so several disjoint changed words on one line are each highlighted while
shared interior words stay plain.

**Reference behavior.** `calculateWordDiffs` uses `diffWordsWithSpace` to produce
add/removed/common segments; the renderer iterates over them highlighting each added/removed
run independently. Ref: `Fallback.tsx:227-234` (`calculateWordDiffs`), `:272-315` (per-part
render loop).

**Target Zig files.**
- `src/core/word_diff.zig` (edit): add a token-level diff producing an ordered list of
  segments `{ tag: common|removed|added, text }` from the `tokenize` iterator that already
  exists.
- `src/cli/repl_edit.zig` (edit): `writeDiffCodePair` consumes the segment list to emit the
  removed line (common + removed segments) and the added line (common + added segments).

**Approach.**
1. In `word_diff.zig`, tokenize both sides into `[]Token` (word/nonword runs), then run a
   standard LCS over the token sequences (compare by `text` equality). Emit segments in order:
   tokens in the LCS are `common`; tokens only in old are `removed`; tokens only in new are
   `added`. Keep it bounded: cap token count (e.g. 256 per side) and fall back to the existing
   `commonAffixes` path above the cap to avoid O(n*m) blowups on pathological lines. Provide:
   ```
   pub const Seg = struct { tag: enum { common, removed, added }, text: []const u8 };
   /// Caller supplies a fixed buffer of Seg; returns the populated slice
   /// or null if the token count exceeds the cap (caller falls back to
   /// commonAffixes). No allocation.
   pub fn wordDiffSegments(old: []const u8, new: []const u8, out: []Seg) ?[]Seg
   ```
   Use a fixed-size buffer for the LCS table sized to the cap (e.g. `[257][257]u16` is ~130KB;
   prefer a smaller cap like 128 -> ~33KB, or a rolling two-row buffer to keep it on the
   stack). A rolling two-row LCS-length pass plus a backtrack is the cleanest no-alloc form.
2. In `writeDiffCodePair`, call `wordDiffSegments`. For the removed line, walk segments and
   emit `common` + `removed` text (skip `added`), wrapping `removed` runs in `\x1b[41;97m`...
   `RESET` then restoring `toneColor(.failure)`. For the added line, emit `common` + `added`
   (skip `removed`), wrapping `added` runs in `\x1b[42;30m`. If `wordDiffSegments` returns
   `null` (over cap), fall back to the current single-affix code.
3. Update `changeRatioPercent` (Task 1) to sum segment lengths so the ratio matches the
   reference's `changedLength` over multiple segments. Keep the affix-based version as the
   over-cap fallback.

**Acceptance criteria.**
- New `word_diff.zig` test: `wordDiffSegments("rename foo to bar", "rename baz to qux", buf)`
  yields `common "rename "`, `removed "foo"`, `common " to "`, `removed "bar"` on the old side
  and the symmetric `baz`/`qux` on the new side - i.e. the unchanged ` to ` in the middle is
  NOT highlighted. (The single-affix version would highlight `foo to bar` vs `baz to qux`
  wholesale.)
- New renderer test: a line with two separated edits shows two distinct bright spans per side,
  with the shared interior word plain.
- Over-cap input falls back without crashing.

**Test strategy.** `zig build test`. The segment test is pure and deterministic. The renderer
test asserts the count of `\x1b[41;97m` occurrences on the removed line equals the number of
removed runs.

**Risk / footguns.** Watch slice lifetimes: `Seg.text` slices point into the caller's `old`/
`new` buffers, which in `writeDiffCodePair` are the clipped `old_buf`/`new_buf` stack arrays -
they live for the whole function, so this is safe, but do not return segments that outlive
those buffers. Keep the LCS bounded; an unbounded table on huge minified lines would blow the
stack. Match the existing tone-restore pattern exactly (`RESET` then re-emit `toneColor`) so
trailing common text keeps the right color.

**Size.** M.

---

### Task 3 - Memory mode (`#` prefix) input + confirmation (ui-render-03)

**Goal.** Typing `#` as the leading character of a prompt enters memory-capture mode: the rest
of the line is appended to the project `CLAUDE.md`, wrapped semantically, and acknowledged with
a randomized "Got it." / "Good to know." / "Noted." message.

**Reference behavior.** Leading `#` enters memory mode; the entry is wrapped in
`<user-memory-input>`, rendered with a `#` badge on the memory background, persisted to
CLAUDE.md, with a randomized `getSavingMessage()`. Ref:
`src/components/messages/UserMemoryInputMessage.tsx:8-10` (`getSavingMessage` returns one of
`Got it.`/`Good to know.`/`Noted.`), `:44-51` (`#` badge), `PromptInput/inputModes.ts` (mode
chars).

**Target Zig files.**
- `src/core/memory.zig` (edit): add an `appendUserMemory(allocator, line) !void` that locates
  the project `CLAUDE.md` (reuse whatever path resolution `/memory save` already uses) and
  appends the line under a stable section, creating the file if absent.
- `src/cli/repl.zig` (edit): in the submit path (around `repl.zig:7609`, where the prompt is
  sent to `handler.call()`), detect a leading `#` BEFORE dispatch. The existing `!` bash-mode
  detection is the structural precedent - mirror it.
- `src/core/memory_messages.zig` (new core deep module): `pub fn savingMessage(rng_byte) []const u8`
  returning one of the three confirmations, plus a comptime list. Register in `src/main.zig`.

**Approach.**
1. Find the existing `!` bash-prompt-mode detection in `repl.zig` and the `/memory save`
   dispatch in `repl_commands.zig:1300` to reuse path resolution and confirmation rendering.
2. Add a new `memory_messages.zig`:
   ```
   const std = @import("std");
   pub const SAVING_MESSAGES = [_][]const u8{ "Got it.", "Good to know.", "Noted." };
   pub fn savingMessage(pick: usize) []const u8 {
       return SAVING_MESSAGES[pick % SAVING_MESSAGES.len];
   }
   ```
   Pick the index from `core/rng.zig` (`rng.bytes()` one byte) per the runtime conventions - do
   NOT use `std.crypto.random.*`.
3. In `repl.zig` submit handling: if the trimmed prompt starts with `#` and has non-empty
   remainder, route to memory capture: trim the `#`, call `memory.appendUserMemory`, print the
   `#`-badged echo line plus the dim `savingMessage`, and DO NOT send the turn to the model.
   Match the `!` mode's early-return structure.
4. The `<user-memory-input>` wrapping in the reference is for the message-history record. zcode
   does not need to persist the tag to its transcript history for the model (memory is read
   from CLAUDE.md on the next session), so keep the wrapping internal to the echo render only
   if it is even needed; the load-bearing behavior is the CLAUDE.md append + confirmation.

**Acceptance criteria.**
- New `memory_messages.zig` test: `savingMessage(0..2)` returns the three strings; out-of-range
  wraps.
- New `memory.zig` test: `appendUserMemory` on a temp `CLAUDE.md` (use
  `core/test_helpers.tmpDirPath` for a real absolute path - do NOT pass `"."`) appends the line
  and a re-read shows it; appending twice keeps both lines.
- Manual: typing `# always run zig fmt before commit` at the prompt appends that line to the
  project CLAUDE.md, prints a `#`-badged echo + a confirmation, and does not call the model.

**Test strategy.** `zig build test` for the two unit tests. The submit-path routing is harder
to unit test (it is in the interactive REPL); cover it via the manual check in Verification and
a small extracted predicate `fn isMemoryCapture(prompt) bool` that IS unit-tested.

**Risk / footguns.** Use `core/test_helpers.tmpDirPath` for the CLAUDE.md write test - a
relative `"."` is relative to the test process CWD, not the tmp dir (per CLAUDE.md). File
append on 0.16: open with `.{ .mode = .write_only }` and seek to end, or use the append open
flags available in this std; verify the `std.fs` append idiom compiles (the migration notes
warn that several file APIs changed). Do not double-handle `#` if a future config disables
memory mode - gate on a simple "is the first non-space byte `#` and is there a remainder".

**Size.** M.

---

### Task 4 - Persistent collapsed thinking indicator + full block (ui-render-04)

**Goal.** Persist extended-thinking text into the transcript so that, after a turn completes,
non-transcript view shows a dim-italic `∴ Thinking <ctrl+o to expand>` line, and transcript
view shows the full thinking as an indented dim Markdown block.

**Reference behavior.** `AssistantThinkingMessage` renders `∴ Thinking` + `CtrlOToExpand` when
not verbose/transcript, and the full thinking as `<Markdown dimColor>` indented when
verbose/transcript. Ref: `src/components/messages/AssistantThinkingMessage.tsx:44`
(`"∴ Thinking"` + `<CtrlOToExpand/>`), `:69` (full block, `paddingLeft={2}`,
`<Markdown dimColor>`).

**Target Zig files.**
- `src/core/figures.zig` (edit): add `THEREFORE` = `∴` (U+2234, `\xe2\x88\xb4`) if not present.
- `src/agent_history.zig` (edit): stop freeing `reasoning_text` after use
  (`agent_runtime.zig:1169` frees it); instead store it on the turn record so it survives into
  the transcript. Add a `thinking: ?[]const u8` field to the turn type (or reuse an existing
  metadata slot) and own/free it with the turn.
- `src/agent_runtime.zig` (edit): at the point where `parsed.assistant_text` is appended
  (`:1303`), also stash `reasoning_text` onto the turn instead of freeing it at `:1169`.
- `src/cli/repl.zig` (edit): replace the `appendThinkingSummary` no-op (`repl.zig:806-820`) and
  the transcript-render path so that a turn with stored thinking renders the collapsed line in
  normal view and the full dim block in transcript view.

**Approach.**
1. Add the `∴` glyph to `figures.zig` next to `TEARDROP_ASTERISK`, with a test asserting the
   bytes (`\xe2\x88\xb4`).
2. Thread `reasoning_text` ownership: today it is extracted (`agent_history.zig:536`,
   `openai.zig:160`) and freed at `agent_runtime.zig:1169`. Change the turn struct to carry an
   optional owned `thinking` slice; dupe `reasoning_text` into the turn allocator at the append
   site; free it in the turn's deinit. Confirm there is exactly one free path so this does not
   double-free.
3. Render:
   - Normal view: a single dim-italic line `<DIM><ITALIC>∴ Thinking <ctrl+o to expand><RESET>`
     emitted once per turn that has thinking. Use the existing dim/italic SGR constants from
     `repl_markdown.zig`.
   - Transcript view: the full thinking text rendered through the existing markdown renderer
     with a dim wrapper and a 2-space indent, matching the reference's `paddingLeft={2}` +
     `dimColor`.
   The view selector already exists (transcript toggle drives a verbose/transcript flag); wire
   the thinking render to that same flag.
4. Redacted-thinking placeholder: if a provider returns a redacted-thinking marker (no text),
   render a fixed `∴ Thinking (redacted)` dim line. Keep this minimal - it is a placeholder.

**Acceptance criteria.**
- `figures.zig` test for the `∴` bytes.
- A render test: given a turn record with `thinking = "step one\nstep two"`, the normal-view
  renderer output contains `∴ Thinking` and `ctrl+o` (case-insensitive) and does NOT contain
  `step one`; the transcript-view renderer output contains `step one` and `step two` rendered
  through markdown with the dim wrapper.
- No memory leak: a history-lifecycle test that creates and deinits a turn with thinking passes
  under the test runner's allocator (the runner uses a checked allocator).

**Test strategy.** `zig build test`. Extract the two render functions
(`renderThinkingCollapsed(writer, ...)` and `renderThinkingFull(writer, text, ...)`) as small
testable units so they do not require the full REPL.

**Risk / footguns.** The free-then-store change is the risk: `reasoning_text` is currently
freed at `agent_runtime.zig:1169`. Removing that free and instead duping into the turn must be
paired with a free in the turn deinit, or it leaks; freeing in both places double-frees. Search
for every reader of `reasoning_text` before changing ownership. This is a product choice (the
survey flags it `partial`/optional) - keep it behind the existing thinking-summaries toggle
default so users who do not want persisted thinking are unaffected.

**Size.** M.

---

### Task 5 - Styled compact-boundary message (ui-render-05)

**Goal.** Render the compaction boundary as a dim `✻ Conversation compacted (ctrl+o for history)`
line instead of the plain system note.

**Reference behavior.** `CompactBoundaryMessage.tsx:10`:
`✻ Conversation compacted ({historyShortcut} for history)`, dim, `marginY={1}`. The
`historyShortcut` resolves to `app:toggleTranscript` (ctrl+o).

**Target Zig files.**
- `src/agent_history.zig` (edit): where the compaction note is appended (`:287`), use the
  styled boundary string; or, if Phase 8's structured boundary marker is present, attach the
  display string to it.
- The transcript renderer that prints system messages (wherever `agent_history` system notes
  are formatted): special-case the compaction boundary to render dim with the `✻` glyph and the
  Ctrl+O hint.

**Approach.**
1. Replace the literal `"Conversation compacted by control action."` with a builder that emits
   `<DIM>✻ Conversation compacted (ctrl+o for history)<RESET>` using `figures.TEARDROP_ASTERISK`
   and the dim SGR from `repl_markdown.zig`. Keep the Ctrl+O label aligned to whatever the
   transcript toggle is bound to (it is `ctrl+o` by default per `repl_input.zig:819`).
2. If Phase 8 introduced a structured boundary record, render from that record's fields; if not,
   emit the styled string directly at the append site. Either way the visible output must match.
3. Ensure NO_COLOR / non-tty paths degrade to plain text (the dim SGR is suppressed by the same
   gate the rest of the renderer uses).

**Acceptance criteria.**
- A render test: the compaction-boundary render output contains the `✻` byte sequence
  (`\xe2\x9c\xbb`), the words `Conversation compacted`, and `ctrl+o`.
- With color disabled, the same output contains the text but no SGR escapes.

**Test strategy.** `zig build test` on the extracted boundary-render function.

**Risk / footguns.** Do not hardcode `Ctrl+O` if the transcript toggle is rebindable - read the
bound chord from the keybindings layer if that is cheap; otherwise the default `ctrl+o` is
acceptable and matches the reference's fallback. Keep the glyph as the existing tested constant;
do not paste the raw `✻` character into source (use `figures.TEARDROP_ASTERISK`).

**Size.** S.

---

### Task 6 - Env-gated syntax-highlight toggle for diff content (ui-render-07)

**Goal.** Gate diff-content syntax highlighting behind `CLAUDE_CODE_SYNTAX_HIGHLIGHT` (parity
with the reference's opt-in), keeping the current default behavior.

**Reference behavior.** `StructuredDiff` applies a per-language syntax theme to diff content via
`color-diff-napi`, gated off by `CLAUDE_CODE_SYNTAX_HIGHLIGHT`. Ref:
`src/components/StructuredDiff/colorDiff.ts:1-37`.

**Target Zig files.**
- `src/cli/repl_edit.zig` (edit): the hard-coded `render_options` block (`:7-10`) and
  `writeDiffCodeLine` (`:794-841`) consult an env-derived flag.
- `src/core/env_registry.zig` (edit, if it centralizes known env vars): register
  `CLAUDE_CODE_SYNTAX_HIGHLIGHT`.

**Approach.**
1. Read `CLAUDE_CODE_SYNTAX_HIGHLIGHT` once via `core/env.zig`. Decide the default: the survey
   notes context + solo lines already highlight, so to avoid a behavior regression the default
   should KEEP highlighting on (current behavior). Treat the env var as the reference does - as a
   toggle. The reference gates it OFF by default; reconcile this by making the env var the
   *override* and defaulting to zcode's current on-state, OR match the reference exactly and
   default off. Pick: match current zcode behavior by default (on), and let
   `CLAUDE_CODE_SYNTAX_HIGHLIGHT=0` turn it off, `=1` force on. State this choice in the wiki so
   it is not re-litigated.
2. Thread the flag into `writeDiffCodeLine` so that when off it calls `clipMiddleInto` + plain
   `writeAll` instead of `repl_markdown.writeCodeLine`.
3. Leave `writeDiffCodePair` (word-diff pairs) skipping syntax highlighting regardless - that is
   the kept design choice (`repl_edit.zig:848-850`).

**Acceptance criteria.**
- A render test with the flag forced off: diff context lines contain the raw code text with no
  language-keyword SGR codes; with the flag on, keyword SGR appears.
- `env_registry` lists the new var (if that registry exists and is the convention).

**Test strategy.** `zig build test`. Extract the flag read into a `fn syntaxHighlightEnabled() bool`
that can be tested by setting the env var in the test (or by passing the bool through, which is
cleaner - the render fn takes the bool, the env read is a thin wrapper tested separately).

**Risk / footguns.** Default choice is the only real decision; document it. Reading env in a hot
render path on every line is wasteful - read once and pass the bool down.

**Size.** S.

---

### Task 7 - Interactive multi-file diff navigator (ui-render-08) [DEFERABLE]

**Goal.** An optional fullscreen multi-file diff review overlay: a file list with per-file +/-
stats and selection, and a detail view of the selected file's hunks.

**Reference behavior.** `DiffDialog`/`DiffFileList`/`DiffDetailView`/`StructuredDiffList` give a
fullscreen navigable review. Ref: `src/components/diff/DiffDialog.tsx`, `DiffFileList.tsx`,
`DiffDetailView.tsx`, `src/components/StructuredDiffList.tsx`.

**Target Zig files.**
- `src/cli/repl_overlay.zig` (edit): add a `DiffNavigatorData` overlay type alongside the
  existing 15+ overlay types.
- `src/cli/repl_edit.zig` (reuse): `renderDiffSection` already renders one file's card; reuse it
  for the detail pane.
- A new `src/cli/repl_diff_nav.zig` (new) for the list + selection state machine, or fold into
  the overlay module if it stays small.

**Approach.**
1. Parse the multi-file diff into a list of `{ path, added, removed, section_bytes }` (the
   parsing loop in `formatDiffBlock` at `:126-144` already splits on `diff --git`; reuse it).
2. Overlay state: selected index, scroll offset within the detail pane. Up/Down moves file
   selection; the detail pane re-renders the selected section via `renderDiffSection`.
3. Trigger: a `/diff` command or a keybinding when a tool call produced a multi-file diff. Keep
   the trigger minimal - this is deferable.

**Acceptance criteria.**
- A unit test of the parse-to-file-list step: a two-file diff yields two entries with correct
  paths and stats.
- Manual: invoking the navigator over a 2+ file diff lets the user move between files and see
  each file's hunks.

**Test strategy.** `zig build test` for the parser; the overlay interaction is manual.

**Risk / footguns.** This is L and low value for a CLI per the survey. Strongly consider
deferring to a later phase; if time-boxed, ship only the parse-to-list helper and the static
list render, and skip the interactive selection. Do not let it block the rest of the phase.

**Size.** L.

---

### Task 8 - Animated spinner glyph + reduced-motion + stalled color (ui-render-06 / terminal-11)

**Goal.** Cycle the platform-aware `·✢✳✶✻✽` glyph (forward then reversed) for the spinner's
leading frame, add a reduced-motion 2s flashing-dot fallback, and interpolate the glyph color
from theme accent toward error red as the turn stalls.

**Reference behavior.** `SpinnerGlyph` cycles `SPINNER_FRAMES` (12 frames: `getDefaultCharacters`
forward then reversed), with a Ghostty `*`-for-`✽` substitution and `*`-for-`✳` on non-darwin;
reduced-motion shows a 2s-cycle flashing `●`; `stalledIntensity` RGB-interpolates from theme
color toward `(171,43,63)`. Ref: `Spinner/SpinnerGlyph.tsx:6-9,36-78`, `Spinner/utils.ts:4-24`.

**Target Zig files.**
- `src/cli/repl_spinner.zig` (edit): the `frames` array (`:507-509`), `canAnimateThinking`
  (`:468-484`), the stalled-label path (`:932-938`), and the spinner main loop.
- `src/core/platform.zig` (reuse): platform detection for the glyph-set choice.
- `src/core/ui_theme.zig` (reuse): the error-red `(171,43,63)` already present at `:158,160`.
- A new `src/core/spinner_glyph.zig` (new core deep module) for the pure pieces: glyph-set
  selection, frame indexing, and RGB interpolation. Register in `src/main.zig`.

**Approach.**
1. `spinner_glyph.zig` (pure, no IO):
   - `pub fn defaultCharacters(term, is_darwin) []const []const u8` returning the 6-glyph set per
     the reference rules (`·✢✳✶✻✽` darwin; `·✢*✶✻✽` non-darwin; `·✢✳✶✻*` for `xterm-ghostty`).
   - `pub fn frameGlyph(frame: usize, set) []const u8` over the 12-frame forward-then-reversed
     sequence.
   - `pub fn interpolateRgb(base: Rgb, target: Rgb, t_percent: usize) Rgb` integer lerp.
   - `pub fn reducedMotionDim(time_ms: usize) bool` -> the 2s flashing-dot phase
     (`(time_ms / 1000) % 2 == 1`).
2. Wire into `repl_spinner.zig`:
   - Replace the single-`●` `frames` array with `frameGlyph` over the selected set, advancing the
     frame index each tick (the loop already ticks).
   - `canAnimateThinking`: when reduced motion is requested, instead of suppressing the spinner
     thread entirely, render the `●` with `reducedMotionDim`-driven dim toggling. Keep the
     env-var detection. (This changes reduced motion from "no spinner" to "calm flashing dot",
     matching the reference; preserve the token-accounting/cancel-hint behavior the current
     suppression keeps.)
   - Stalled color: when stalled (the existing >=5s detection), compute
     `interpolateRgb(accent, error_red, intensity)` where intensity ramps with stall duration,
     and emit the leading glyph in that `\x1b[38;2;r;g;bm` color. Fall back to the error-red ANSI
     for non-truecolor palettes (mirror the reference's ANSI fallback).
3. Respect the documented prior decision (`repl_spinner.zig:500-509`) that the *pulse bar* should
   bounce but the status text should not move. The glyph cycle is the leading status glyph - this
   reintroduces a controlled glyph animation, which the survey notes is a design choice. Gate the
   morph cycle behind a small flag (default on) so it can be reverted if it again "feels like the
   text is moving."

**Acceptance criteria.**
- `spinner_glyph.zig` tests: `defaultCharacters` returns the right set for darwin / non-darwin /
  ghostty; `frameGlyph(0)` is `·` and `frameGlyph(6)` (turn-around) is `✽` (darwin), with the
  reverse half mirroring; `interpolateRgb(a,b,0)==a`, `(a,b,100)==b`, midpoint rounds correctly;
  `reducedMotionDim` toggles each 1s.
- A spinner-render test (or extracted line-builder test) showing the stalled state emits a
  truecolor SGR for the glyph that is closer to `(171,43,63)` than the base accent.

**Test strategy.** `zig build test` on the pure module. The threaded spinner loop is not
unit-tested; cover the line-builder by extracting it to take `(frame, stalled_intensity,
reduced_motion, time_ms)` and return the bytes.

**Risk / footguns.** This reverses a deliberate prior simplification - keep it behind a flag and
note the prior user feedback in the wiki. Glyph widths: `✢✳✶✻✽` are width-1 in most terminals but
`wcwidth.zig` must agree, or the status line will shift; verify against Task 16's width work.
Reduced-motion users explicitly want minimal motion - a slow 2s flash is acceptable per the
reference but make sure the env var still fully disables if a stricter `ZCODE_REDUCE_MOTION=hard`
is desired (optional; default to the reference's flashing-dot behavior).

**Size.** M.

---

### Task 9 - Sandbox-violation footer hint (ui-render-12)

**Goal.** Surface a transient footer hint `N sandbox violations (ctrl+o for details)` when sandbox
violations occur, using the existing footer-notification infrastructure.

**Reference behavior.** `SandboxPromptFooterHint` subscribes to a sandbox violation store and shows
a transient `recentViolationCount` hint. Ref:
`src/components/PromptInput/SandboxPromptFooterHint.tsx:7-39`.

**Target Zig files.**
- `src/core/sandbox.zig` (edit): add a lightweight violation counter/store (an atomic counter plus
  a small recent-violation ring is enough; the reference shows a recent count).
- `src/cli/repl.zig` (edit): populate `prompt_notifications` (currently never populated, `:5228`)
  from the sandbox violation count, pushing a `.notification` strip via the existing
  `UiNotificationQueue` (`:1630-1699`) and `buildPromptStripItems` (`:1991-2114`).

**Approach.**
1. In `sandbox.zig`, add `var recent_violations: std.atomic.Value(usize)` and a
   `recordViolation()` called at each enforcement-denial site, plus `takeRecentCount()` /
   `peekRecentCount()`. Keep it minimal - a count is enough for the hint; the "details" are the
   transcript/log the user already has.
2. In the REPL's per-frame footer build (`buildPromptStripItems`), if the recent violation count
   > 0, push a `.notification` strip `"{N} sandbox violations (ctrl+o for details)"`. Use the
   existing dismiss path so it is transient (clears after display or after N ticks, matching how
   other notifications behave).
3. Confirm `core/sandbox.zig` enforcement points exist to hook into (the survey says enforcement
   exists); add `recordViolation()` calls there.

**Acceptance criteria.**
- A `sandbox.zig` test: `recordViolation()` twice then `peekRecentCount()` returns 2;
  `takeRecentCount()` resets.
- A footer-build test: with a stubbed violation count of 3, `buildPromptStripItems` includes a
  `.notification` strip whose text contains `3 sandbox violations`.

**Test strategy.** `zig build test`. The store is pure; the footer build is already a pure
function over inputs, so inject the count.

**Risk / footguns.** Do not spam: dedupe so a burst of violations does not push N strips. The
reference shows a single hint with a count. Keep the counter thread-safe if sandbox enforcement
runs off the main thread (use the atomic).

**Size.** M.

---

### Task 10 - Terminal-response parsing (terminal-01)

**Goal.** Recognize inbound terminal-response escape sequences (DECRPM, DA1, DA2, kitty-flags,
DSR cursor-position, generic OSC, XTVERSION) in the input parser and surface them as a distinct
response type rather than swallowing them as `.none`.

**Reference behavior.** `parseMultipleKeypresses` routes inbound sequences through
`parseTerminalResponse`, recognizing DECRPM (`CSI ?Ps;Pm$y`), DA1 (`CSI ?...c`), DA2 (`CSI >...c`),
kitty flags (`CSI ?flags u`), DSR (`CSI ?row;col R`), OSC replies, and XTVERSION (`DCS >| name ST`).
Ref: `src/ink/parse-keypress.ts:36-65` (regexes), `:122-175` (`parseTerminalResponse`), `:96-111`
(`TerminalResponse` union).

**Target Zig files.**
- `src/core/terminal_response.zig` (new core deep module): a pure parser
  `pub fn parse(seq: []const u8) ?TerminalResponse` plus the `TerminalResponse` union. Register in
  `src/main.zig`.
- `src/cli/repl_input.zig` (edit): in `parseEscapeSequenceCursorInternal`, before falling through
  to `.none`, attempt `terminal_response.parse` on the assembled sequence; if it matches, record it
  (Task 11 consumes XTVERSION) and return `.none` (responses are not user input, so the REPL takes
  no action) - but they must be *consumed*, not mis-parsed as keys.

**Approach.**
1. `terminal_response.zig`, pure, no IO. Mirror the reference union:
   ```
   pub const TerminalResponse = union(enum) {
       decrpm: struct { mode: u32, status: u32 },
       da1: []const u8,      // raw numeric params (slice into input)
       da2: []const u8,
       kitty_keyboard: u32,  // flags
       cursor_position: struct { row: u32, col: u32 },
       osc: struct { code: u32, data: []const u8 },
       xtversion: []const u8, // name
   };
   pub fn parse(seq: []const u8) ?TerminalResponse
   ```
   Match the byte patterns directly (no regex engine): the sequences are
   `CSI ? ... $ y`, `CSI ? ... c`, `CSI > ... c`, `CSI ? <digits> u`, `CSI ? row;col R`,
   `OSC <code> ; <data> (BEL|ST)`, `DCS > | <name> (BEL|ST)`. Distinguish DA1 from a cursor-position
   report by the trailing byte and the presence of the `?` private marker (the reference relies on
   the `?` to disambiguate DSR from modified-F3; preserve that).
2. In `repl_input.zig`, after the sequence bytes are assembled (the `seq[0..len]` buffer around
   `:732-748`), call `terminal_response.parse`. If it returns a value, hand it to a small recorder
   (a module-level `var last_response: ?TerminalResponse` or a callback) and return `.none`. This
   prevents responses from leaking into the prompt or being mis-mapped.
3. Keep the OSC/DCS cases mindful that those sequences may not be CSI-framed the same way; the input
   reader assembles up to a final byte in `0x40..0x7E`, which does not cover OSC/DCS terminators
   (`BEL`/`ST`). Either extend the assembler to read OSC/DCS until `BEL` or `ESC \`, or scope
   terminal-01's parser to the CSI-framed responses (DECRPM/DA1/DA2/kitty/DSR) in this task and
   handle OSC/DCS (XTVERSION) assembly in Task 11 where it is actually consumed. Recommended: parse
   the CSI-framed set here; defer OSC/DCS reader changes to Task 11.

**Acceptance criteria.**
- `terminal_response.zig` tests: `parse("\x1b[?2026;1$y")` -> `decrpm{2026,1}`;
  `parse("\x1b[?1;2c")` -> `da1`; `parse("\x1b[>0;276;0c")` -> `da2`;
  `parse("\x1b[?5u")` -> `kitty_keyboard{5}`; `parse("\x1b[?12;34R")` -> `cursor_position{12,34}`;
  a plain key sequence like `"\x1b[A"` -> `null` (not a response).
- A `repl_input` test (or extracted predicate test) showing a DA1 reply is consumed as `.none` and
  does not insert bytes into the input buffer.

**Test strategy.** `zig build test` on the pure parser. The reader-consumption test can use the
existing input-parser test harness if one exists, or a small extracted "given these bytes, is the
result a response or a key" predicate.

**Risk / footguns.** The DSR-vs-modified-F3 ambiguity is real - only treat `CSI ? row;col R` (with
the `?`) as a cursor report; `CSI row;col R` without `?` is a key. Bounds: the assembler buffer is
`[32]u8`; OSC/DCS payloads (terminal names, color strings) can exceed that. Do not overflow - if a
response payload would exceed the buffer, bail to `.none` cleanly. Slices in the union point into
the caller's buffer; document that they are only valid until the next read.

**Size.** M.

---

### Task 11 - XTVERSION async terminal-name probe (terminal-02)

**Goal.** On raw-mode enable, send the XTVERSION query (`CSI > 0 q`); when the `DCS > | name ST`
reply arrives, record the terminal name so `isXtermJs()` / `supportsExtendedKeys()` work over SSH.

**Reference behavior.** Fires `CSI >0q` on raw-mode enable; the `DCS >| name ST` reply is recorded
via `setXtversionName()`; `isXtermJs()` and `supportsExtendedKeys()` then work over SSH. Ref:
`src/ink/terminal.ts:120-169`, `parse-keypress.ts:55-60` (XTVERSION_RE).

**Target Zig files.**
- `src/core/terminal_caps.zig` (edit): add `setXtversionName(name)`, `isXtermJs()`,
  `supportsExtendedKeys()`, backed by a module-level `var xtversion_name: ?[]const u8`.
- `src/cli/repl_input.zig` (edit): in `TerminalRawMode.enable()` (`:11-41`), after enabling the
  Kitty protocol, also write `\x1b[>0q`. In the input parser, when Task 10's parser yields an
  `xtversion` response, call `terminal_caps.setXtversionName`.
- `src/core/terminal_response.zig` (edit): add the OSC/DCS assembly + XTVERSION parse (the part
  deferred from Task 10).

**Approach.**
1. Extend the input reader to assemble DCS/OSC sequences to their `BEL`/`ST` terminator (only when
   the sequence starts with `\x1bP` or `\x1b]`), with a sane max length, so XTVERSION replies are
   captured intact.
2. Parse `DCS > | name ST` into `xtversion: name`. On match, `setXtversionName(dup(name))`
   (dupe because the input buffer is reused; free on next set / at shutdown). Defend against
   re-probe (no-op if already set), matching the reference.
3. `enable()` sends `\x1b[>0q` once. `isXtermJs()` returns true if `TERM_PROGRAM == vscode`
   (env, fast) OR the recorded name starts with `xterm.js`. `supportsExtendedKeys()` returns true
   for the allowlist (`iTerm.app`, `kitty`, `WezTerm`, `ghostty`, `tmux`, `windows-terminal`)
   resolved from env terminal name, matching the reference's `EXTENDED_KEYS_TERMINALS`.
4. Consider gating the Kitty-protocol enable on `supportsExtendedKeys()` as the reference does
   (the comment at `terminal.ts:148-163` explains some terminals echo unhandled codepoints). This
   is an improvement but is a behavior change - keep it optional and note it.

**Acceptance criteria.**
- `terminal_response.zig` test: `parse("\x1bP>|xterm.js(5.5.0)\x1b\\")` -> `xtversion` with name
  `xterm.js(5.5.0)`; same with `\x07` terminator.
- `terminal_caps.zig` test: `setXtversionName("xterm.js(5.5.0)")` then `isXtermJs()` is true;
  with no name set and `TERM_PROGRAM` unset, `isXtermJs()` is false; `supportsExtendedKeys()` true
  for `kitty`, false for `dumb`.

**Test strategy.** `zig build test`. The query-send is verified manually (it is an IO side effect);
the parse + record + predicate logic is fully unit-tested.

**Risk / footguns.** Depends on Task 10. The DCS reply arrives asynchronously on stdin
interleaved with keypresses - it must be parsed wherever input is read, not only at startup.
Lifetime: dupe the name; the raw input buffer is overwritten on the next read. Do not block waiting
for the reply (the reference treats `undefined` as "not yet known" and falls back to env). 0.16:
use `core/std_io.zig` for any writer; do not hand-roll stdout writers.

**Size.** M.

---

### Task 12 - DEC 2026 synchronized output detection + BSU/ESU wrapping (terminal-03)

**Goal.** Detect DEC-2026-capable terminals and wrap full-screen frame redraws in BSU
(`CSI ?2026h`) / ESU (`CSI ?2026l`) to eliminate flicker, excluding tmux.

**Reference behavior.** `isSynchronizedOutputSupported()` whitelists iTerm/WezTerm/Warp/ghostty/
contour/vscode/alacritty/kitty/foot/Zed/Windows-Terminal/VTE>=6800, excluding tmux; `writeDiffToTerminal`
wraps each frame in BSU/ESU. Ref: `terminal.ts:70-118`, `:190-248`; `termio/dec.ts:37-38`.

**Target Zig files.**
- `src/core/terminal_caps.zig` (edit): add `isSynchronizedOutputSupported()` (env-only, mirroring
  the reference whitelist) and a cached `SYNC_OUTPUT_SUPPORTED`.
- `src/cli/repl_render.zig` (edit): the full-screen redraw path (around `enterAltScreen` `:2389`
  and the frame writer) wraps the frame buffer in BSU/ESU when supported.

**Approach.**
1. `isSynchronizedOutputSupported`: return false if `$TMUX` set; true for the TERM_PROGRAM
   whitelist; true for `TERM` containing `kitty`/`ghostty`/`alacritty`, `KITTY_WINDOW_ID`,
   `TERM` starting `foot`, `ZED_TERM`, `WT_SESSION`, and `VTE_VERSION >= 6800`. Cache once.
2. In the full-screen frame writer, prepend `\x1b[?2026h` and append `\x1b[?2026l` to the single
   buffered write when supported. zcode's non-fullscreen path mostly appends rather than
   diff-rewrites (per the survey), so scope wrapping to the alt-screen full redraw where flicker is
   visible.
3. Add named constants `BSU = "\x1b[?2026h"`, `ESU = "\x1b[?2026l"` next to the other DEC sequences.

**Acceptance criteria.**
- `terminal_caps.zig` test: with `TMUX` set, `isSynchronizedOutputSupported()` is false even if
  `TERM_PROGRAM=iTerm.app`; with `TERM_PROGRAM=ghostty` and no TMUX, true; with `VTE_VERSION=6800`,
  true; `6799`, false.
- A render test: the full-screen frame output starts with `\x1b[?2026h` and ends with `\x1b[?2026l`
  when supported, and has neither when not.

**Test strategy.** `zig build test`. Set env vars in the capability test; assert the frame
wrapper bytes in the render test.

**Risk / footguns.** Only wrap the full-screen redraw - wrapping append-only output is pointless
and the reference skips tmux specifically because it chunks bytes and breaks atomicity. The env
test must restore/clear env vars between cases to avoid cross-test contamination (set then unset).

**Size.** M.

---

### Task 13 - OSC 9;4 progress-bar reporting (terminal-04)

**Goal.** Emit OSC 9;4 progress sequences (taskbar/tab progress) on capable terminals
(ConEmu / Ghostty 1.2.0+ / iTerm2 3.6.6+, excluding Windows Terminal).

**Reference behavior.** `isProgressReportingAvailable()` version-gates ConEmu / Ghostty 1.2.0+ /
iTerm2 3.6.6+ (excluding WT); the app emits OSC 9;4. Ref: `terminal.ts:25-64`.

**Target Zig files.**
- `src/core/terminal_caps.zig` (edit): `isProgressReportingAvailable()` with semver gating.
- `src/core/notifier.zig` (edit) or a small `src/core/progress_osc.zig` (new): build the OSC 9;4
  bytes. Reuse `notifier.zig`'s OSC byte-building convention.
- `src/cli/repl.zig` (edit): the `ProgressReporter` emits OSC 9;4 on start (state running, with
  percentage if known), completion (state 0 = remove), and error.

**Approach.**
1. `isProgressReportingAvailable`: false if not a TTY or `WT_SESSION`; true for `ConEmuANSI`/
   `ConEmuPID`/`ConEmuTask`; for `ghostty` require `TERM_PROGRAM_VERSION >= 1.2.0`; for `iTerm.app`
   require `>= 3.6.6`. Implement a tiny `semverGte(a, b)` comparing major/minor/patch (a small pure
   helper; there is no semver dep).
2. OSC 9;4 format: `\x1b]9;4;<state>;<percent>\x07` where state 0=remove, 1=set(percent), 2=error,
   3=indeterminate. Build via a `bufPrint` mirroring `notifier.buildBytes`.
3. Wire into `ProgressReporter` so a long turn shows OS taskbar progress and clears on completion.

**Acceptance criteria.**
- `terminal_caps.zig` tests: ghostty 1.2.0 -> true, 1.1.9 -> false; iTerm.app 3.6.6 -> true,
  3.6.5 -> false; WT_SESSION set -> false; ConEmuPID set -> true.
- `progress_osc` test: `set(50)` -> `\x1b]9;4;1;50\x07`; `clear()` -> `\x1b]9;4;0;\x07` (or the
  state-0 form); `indeterminate()` -> state 3.

**Test strategy.** `zig build test`. Pure semver + pure byte builders.

**Risk / footguns.** This is distinct from the existing OSC 9 notification in `notifier.zig` -
do not conflate. Cosmetic and low value for a CLI (the survey says so); keep it small. Clear the
progress on every turn end so a crashed turn does not leave a stuck taskbar bar.

**Size.** S.

---

### Task 14 - Mouse click/drag/release coordinates (terminal-05)

**Goal.** Parse SGR mouse clicks/drags/releases (`CSI <btn;col;row M/m`) into a structured event
with button/action/col/row, keeping wheel events as scroll as today.

**Reference behavior.** `parseMouseEvent` emits `ParsedMouse` for SGR clicks/drags/releases with
button/action/col/row; wheel stays as a key. Ref: `parse-keypress.ts:571-609`.

**Target Zig files.**
- `src/cli/repl_input.zig` (edit): the SGR mouse arm (`:750-763`) extracts button/action/col/row
  for non-wheel buttons; add a structured mouse event the REPL can ignore for now but is available.

**Approach.**
1. In the SGR mouse parse, read all three params (`Cb;Cx;Cy`) and the terminator (`M`=press,
   `m`=release). Keep the wheel short-circuit (`button & 0x40`) returning `.mouse_scroll_up/down`.
2. For non-wheel buttons, populate a module-level `var last_mouse: ?MouseEvent` with
   `{ button, action, col, row }` and return `.none` (zcode has no clickable UI yet, so there is no
   `InputEvent` action to fire - the survey notes this only matters if clickable UI is added).
   Define `MouseEvent` so a future clickable-UI feature can consume it without re-parsing.
3. Do the same for the X10 arm (`:715-725`): currently it discards coordinates; extract them into
   `MouseEvent` for non-wheel buttons.

**Acceptance criteria.**
- An extracted-parser test: `parseSgrMouse("<0;10;5M")` -> `{button:0, action:press, col:10, row:5}`;
  `"<0;10;5m"` -> release; `"<64;1;1M"` -> still routed to scroll (returns null mouse / scroll
  event), not a click.

**Test strategy.** `zig build test` on an extracted `parseSgrMouse(payload) ?MouseEvent` so the
coordinate extraction is testable without the full reader.

**Risk / footguns.** Low priority and deliberately scoped - do NOT build hit-testing or clickable
UI; just capture the coordinates so the data is no longer discarded. Keep the wheel behavior
byte-for-byte identical (it is load-bearing for scroll).

**Size.** M.

---

### Task 15 - Super modifier + fn/numpad decoding (terminal-06)

**Goal.** Decode the super (Cmd/Win) modifier (xterm bit 8) and recognize function/numpad keycodes
from kitty CSI-u, surfacing them without reworking the parser into a general ParsedKey.

**Reference behavior.** `decodeModifier` extracts shift/meta/ctrl/super (bit 8 = super);
`keycodeToName` maps fn/numpad keycodes. Ref: `parse-keypress.ts:465-478`, `:487-541`.

**Target Zig files.**
- `src/cli/repl_input.zig` (edit): `ModifierFlags` (`:333-349`) gains a `super` bit;
  `kittyModifierFlags` decodes bit 3 of `(mods-1)` as super (the survey says bits 0-3 are decoded
  but `ModifierFlags` only stores shift/alt/ctrl/cmd - note: `cmd` here IS bit 3, so this may
  already be super under a different name; verify and rename/clarify rather than duplicate).
- A small `fn keycodeName(cp: usize) ?[]const u8` for fn/numpad codepoints (kitty PUA 57399..57415,
  plus 9/13/27/32/127), used only to recognize-and-ignore so these keys do not insert garbage.

**Approach.**
1. Reconcile `cmd` vs `super`: the reference's `super` is xterm bit 8 (`(mods-1) & 8`), which is
   exactly the bit `kittyModifierFlags` already calls `cmd` (`:347`). So zcode already decodes it -
   the gap is naming/clarity and the fn/numpad table, not super itself. Add a doc comment noting
   `cmd == super (bit 8)` and, if any chord string should say `super` vs `cmd`, align it.
2. Add `keycodeName` covering the kitty numpad PUA range and the named keys, returning the logical
   name. In the CSI-u handler, when a fn/numpad keycode arrives that is not already handled, map it
   to a no-op (`.none`) explicitly rather than falling through to byte insertion - this prevents a
   numpad `KP_ENTER` (57414) from being dropped or mis-inserted.
3. Do NOT build a full ParsedKey - this is event-oriented by design (survey confirms). Scope to:
   super naming + fn/numpad recognize-and-ignore (or map KP_ENTER -> submit, KP digits -> their
   ASCII, which is genuinely useful).

**Acceptance criteria.**
- A test: `kittyModifierFlags(9)` (i.e. `mods=9`, `bits=8`) sets the super/cmd bit;
  `keycodeName(57414)` -> `"return"`, `keycodeName(57399)` -> `"0"`, `keycodeName(99)` -> `"c"`.
- A CSI-u handling test: a numpad-enter codepoint maps to `.submit` (if we choose to map it) or is
  cleanly ignored, never inserting a stray byte.

**Test strategy.** `zig build test` on `kittyModifierFlags` and `keycodeName`.

**Risk / footguns.** Mostly a clarity/completeness task per the survey (it is a present_different
design choice). Do not over-build. The biggest real win is mapping numpad digits/enter so they work
on keyboards that report them via kitty PUA; everything else is recognize-and-ignore.

**Size.** M.

---

### Task 16 - tmux truecolor->256 clamp + xterm.js boost (terminal-07)

**Goal.** At startup, under `$TMUX` downgrade truecolor (`38;2`/`48;2`) palette escapes to
256-color (`38;5`/`48;5`); under xterm.js (vscode) at a 256-color baseline, boost to truecolor.
Respect NO_COLOR / FORCE_COLOR.

**Reference behavior.** `clampChalkLevelForTmux()` downgrades to 256 under `$TMUX` (with the
`CLAUDE_CODE_TMUX_TRUECOLOR` escape hatch); `boostChalkLevelForXtermJs()` upgrades vscode level 2
-> 3; gated to respect NO_COLOR/FORCE_COLOR. Ref: `src/ink/colorize.ts:20-62`.

**Target Zig files.**
- `src/core/color_level.zig` (new core deep module): resolve a `ColorLevel { none, ansi16, ansi256, truecolor }`
  from env (NO_COLOR, FORCE_COLOR, COLORTERM, TERM, TERM_PROGRAM, TMUX, CLAUDE_CODE_TMUX_TRUECOLOR),
  applying the boost-then-clamp order. Register in `src/main.zig`.
- `src/core/ui_theme.zig` (edit): a pass that, given a resolved level of `ansi256`, rewrites the
  palette's `38;2;r;g;b` / `48;2;r;g;b` escapes to `38;5;N` / `48;5;N` using Task 17's quantizer.
  OR: select an existing hand-authored `*-ansi` palette when the level is `ansi256`/`ansi16`.

**Approach.**
1. `color_level.zig`, pure given an env-read struct (pass env values in so it is testable):
   - `none` if NO_COLOR set or FORCE_COLOR=0.
   - else start from a base (truecolor if COLORTERM in {truecolor,24bit}, else ansi256 if TERM
     contains 256color, else ansi16).
   - boost: if `TERM_PROGRAM==vscode` and base==ansi256 -> truecolor.
   - clamp: if `TMUX` set and not `CLAUDE_CODE_TMUX_TRUECOLOR` and level>ansi256 -> ansi256.
     (Order matters: boost first so tmux-inside-vscode clamps back to 256, exactly as the reference
     comments.)
2. Apply to palette selection at theme-resolution time (`session_mgmt.zig:114-134` resolves theme
   once - add the level resolution there). Two implementation options:
   - **Simplest, lowest-risk:** when level is `ansi256`/`ansi16`, auto-select the corresponding
     `*-ansi` palette that already exists (the survey says the user currently does this manually).
     This makes tmux "just work" without a runtime rewriter.
   - **Closest to reference:** rewrite truecolor escapes to 256 at runtime via Task 17. More code,
     but works for any theme including custom truecolor ones.
   Recommend the auto-select approach for the dark/light built-ins and Task 17 only if custom
   truecolor themes must also be clamped. Decide and document.

**Acceptance criteria.**
- `color_level.zig` tests covering the truth table: NO_COLOR -> none; FORCE_COLOR=0 -> none;
  COLORTERM=truecolor, no TMUX -> truecolor; same + TMUX -> ansi256; same + TMUX +
  CLAUDE_CODE_TMUX_TRUECOLOR -> truecolor; TERM_PROGRAM=vscode + TERM=xterm-256color (base ansi256)
  -> truecolor; vscode + TERM=xterm-256color + TMUX -> ansi256 (boost then clamp).
- An integration assertion: under a simulated `TMUX` env, the resolved palette contains no `38;2`/
  `48;2` truecolor escapes (either because the ansi palette was selected, or because they were
  rewritten).

**Test strategy.** `zig build test`. Keep `color_level.zig` taking an explicit env struct so the
truth table is exhaustively testable without mutating process env.

**Risk / footguns.** This is the highest-value terminal-layer fix (medium severity, real visible
bug). The boost-then-clamp ORDER is load-bearing - get it wrong and tmux-in-vscode renders broken
backgrounds. `$TMUX` is a pty-lifecycle var set by tmux itself; read it directly (do not pull from
configured env). Do not query `tmux show` (subprocess on startup - the reference explicitly avoids
this). If choosing the auto-select-ansi-palette route, ensure every truecolor built-in has an ansi
counterpart.

**Size.** M.

---

### Task 17 - RGB->ANSI256 quantization (terminal-08)

**Goal.** A pure `ansi256FromRgb(r,g,b) u8` mapping a truecolor value to the nearest xterm 6x6x6
cube index or 24-step grey ramp, to back Task 16's runtime clamp (if that route is chosen).

**Reference behavior.** `ansi256FromRgb` maps RGB to nearest cube or grey index. Ref:
`src/native-ts/color-diff/index.ts:95-120`.

**Target Zig files.**
- `src/core/color_level.zig` (edit, same module as Task 16) or a dedicated `src/core/ansi256.zig`
  (new). Register in `src/main.zig` if new.

**Approach.**
1. Implement the standard mapping:
   - Grey ramp: if `r==g==b`, map to the 24-step grey (indices 232..255) or the cube as appropriate;
     the canonical algorithm computes both the nearest cube color and the nearest grey and picks the
     closer by squared distance.
   - Cube: `ci = CUBE_LEVELS index nearest to each channel` where `CUBE_LEVELS = {0,95,135,175,215,255}`;
     index = `16 + 36*r6 + 6*g6 + b6`.
   - Compare cube-color distance vs grey-color distance, return the closer index.
2. Provide a helper that rewrites an SGR escape `38;2;r;g;b` / `48;2;r;g;b` into `38;5;N` / `48;5;N`
   using this function, for Task 16's runtime-rewrite route.

**Acceptance criteria.**
- Tests: `ansi256FromRgb(0,0,0)` -> 16; `(255,255,255)` -> 231; `(95,212,160)` (brand accent dark)
  -> a plausible cube index; pure greys map into the grey ramp; a known reference value (cross-check
  one or two against the `ansi_colours` crate the reference cites) matches.

**Test strategy.** `zig build test`. Pure function, fully deterministic.

**Risk / footguns.** Only needed if Task 16 takes the runtime-rewrite route; if Task 16 auto-selects
ansi palettes, this becomes a standalone utility (still worth having, low risk). The cube-vs-grey
tie-break is where off-by-one quantization bugs live - test the grey ramp explicitly.

**Size.** S.

---

### Task 18 - Grapheme/emoji width accuracy (terminal-09)

**Goal.** Improve `wcwidth.zig` to handle regional-indicator pairs (flags = width 2), ZWJ emoji
sequences (collapse to one glyph), and keycap sequences, by adding a grapheme-cluster-aware width
pass.

**Reference behavior.** `stringWidthJavaScript` uses emoji-regex + grapheme segmentation:
regional-indicator pairs = 2, incomplete keycaps = 1, ZWJ sequences collapse to one width,
`ambiguousAsWide:false`. Ref: `src/ink/stringWidth.ts:20-203`.

**Target Zig files.**
- `src/core/wcwidth.zig` (edit): add a grapheme-cluster pass to `displayWidth` that recognizes
  regional-indicator pairs, ZWJ joins, and keycap (`digit + VS16 + U+20E3`) sequences. Keep
  `codepointWidth` as-is for the per-codepoint base.

**Approach.**
1. Add a cluster scanner over decoded codepoints:
   - Two consecutive regional indicators (U+1F1E6..U+1F1FF) form one flag -> width 2 (single = 1).
   - A base emoji followed by any run of `{ZWJ + emoji}` collapses to width 2 total (do not sum each
     member). Detect ZWJ (U+200D) and treat the joined sequence as one cluster.
   - Keycap: `digit/`#`/`*`` optionally + VS16 (U+FE0F) + U+20E3 (combining enclosing keycap) ->
     width 2; an incomplete keycap (no U+20E3) stays width 1.
   - Variation selector VS16 after a base may promote a default-narrow symbol to width 2; VS15
     (U+FE0E) keeps narrow. Match the reference where cheap.
2. Keep the existing per-codepoint fallback for everything else. Add a `graphemeWidth(cluster_bytes)`
   helper and have `displayWidth` iterate clusters, not codepoints, for the emoji ranges; non-emoji
   text can stay on the fast per-codepoint path.
3. Wire `displayWidth` into the prompt-line/render width consumers if they currently use byte length
   or a less accurate measure (the survey notes the module is "infra-complete but not yet wired").
   This is the load-bearing part - accuracy improvements are pointless if the render layer does not
   call them.

**Acceptance criteria.**
- New `wcwidth.zig` tests: `displayWidth("🇺🇸")` (two regional indicators) == 2, not 4;
  `displayWidth("🇺")` (single) == 1; `displayWidth("👨\u{200D}👩\u{200D}👧")` (family ZWJ) == 2,
  not 6; `displayWidth("1\u{FE0F}\u{20E3}")` (keycap) == 2; `displayWidth("1\u{FE0F}")` (incomplete)
  == 1; existing tests (CJK, combining marks, plain emoji) still pass.

**Test strategy.** `zig build test`. The cluster logic is pure and table-testable.

**Risk / footguns.** Self-documented approximation today; do not chase full Unicode segmentation -
cover the three cases the reference calls out (regional indicators, ZWJ, keycaps) and stop. Wiring
into the render layer can shift column math everywhere - if any consumer currently compensates for
the old behavior, that compensation must be removed in the same change or columns will double-count.
Keep the fast per-codepoint path for ASCII so prose performance does not regress.

**Size.** M.

---

### Task 19 - Windows conhost cursor-up-yank guard (terminal-10)

**Goal.** Add the `hasCursorUpViewportYankBug()` detection function for completeness, returning true
on win32 or under WT_SESSION.

**Reference behavior.** Returns true on win32 or `WT_SESSION`; the renderer avoids cursor-up
redraws on those terminals. Ref: `terminal.ts:171-179`.

**Target Zig files.**
- `src/core/format.zig` (edit): add `hasCursorUpViewportYankBug()` next to `isModernWindowsTerminal`
  (`:487-498`), reusing the WT_SESSION detection already there.

**Approach.**
1. `pub fn hasCursorUpViewportYankBug() bool` returns true if the build target OS is Windows
   (`@import("builtin").os.tag == .windows`) or `WT_SESSION` is set.
2. Add a doc comment noting that zcode's renderer uses absolute cursor positioning
   (`repl_render.zig:729,2450`) and full-screen redraws, so this bug cannot currently trigger - the
   function exists for parity and as a guard if incremental cursor-up redraws are ever added.

**Acceptance criteria.**
- A test: with `WT_SESSION` set, `hasCursorUpViewportYankBug()` is true; with it unset on a non-
  Windows target, false.

**Test strategy.** `zig build test`. Env-var toggle test.

**Risk / footguns.** Trivial and Windows-specific; zcode runs on macOS/Linux per CLAUDE.md, so this
is purely for parity completeness. Do not add a renderer code path that uses cursor-up just to
exercise the guard.

**Size.** S.

---

## Verification

To prove the phase is complete:

1. **Build and test.**
   ```
   /Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build test
   ```
   All new tests pass under `tools/test_runner.zig`. Every new core module
   (`memory_messages.zig`, `spinner_glyph.zig`, `terminal_response.zig`, `color_level.zig`,
   `ansi256.zig` if separate, `progress_osc.zig` if separate) is registered in the `src/main.zig`
   comptime block so its tests are discovered.

2. **Bump version and install** (per CLAUDE.md):
   ```
   # bump .version patch in build.zig.zon
   /Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build -Doptimize=ReleaseFast
   rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode
   ```
   (rm -f first to avoid the macOS in-place-overwrite signature invalidation footgun.)

3. **Manual UI checks.**
   - Diff with a tiny edit shows tight word-spans; a near-total rewrite shows two solo lines
     (ui-render-01); a line with two separated edits shows two spans with a plain middle
     (ui-render-02).
   - Type `# remember to run zig fmt` - it appends to the project CLAUDE.md, echoes a `#`-badged
     line + a Got it./Good to know./Noted. confirmation, and does NOT call the model (ui-render-03).
   - After a thinking turn, normal view shows `∴ Thinking <ctrl+o to expand>`; press Ctrl+O to enter
     transcript view and see the full dim thinking block (ui-render-04).
   - Trigger a compaction - the boundary renders as dim `✻ Conversation compacted (ctrl+o for history)`
     (ui-render-05).
   - `CLAUDE_CODE_SYNTAX_HIGHLIGHT=0 zcode` removes diff-content syntax colors (ui-render-07).
   - The spinner leading glyph morphs through `·✢✳✶✻✽`; `ZCODE_REDUCE_MOTION=1` shows a slow flashing
     dot; a stalled turn tints the glyph toward red (ui-render-06/terminal-11).

4. **Manual terminal-layer checks.**
   - Run inside tmux: the prompt/approval backgrounds render correctly (no missing/black bg)
     (terminal-07). Confirm with `printf '%s' "$TMUX"` that TMUX is set and the palette is the
     256-color/ansi variant.
   - Over SSH into a VS Code integrated terminal, extended keys still work via the XTVERSION probe
     (terminal-02) - verify `\x1b[>0q` is sent (e.g. via `ZCODE_DEBUG_INPUT`) and a DCS reply is
     consumed without leaking into the prompt (terminal-01).
   - On a DEC-2026 terminal (iTerm/ghostty/kitty), full-screen redraws do not flicker; frames are
     wrapped in `?2026h`/`?2026l` (terminal-03), verifiable with a terminal capture.
   - Flag/family/keycap emoji in prompt text no longer desync the cursor column (terminal-09).

5. **Regression.** `zig build test` green, existing diff/spinner/input tests unchanged in behavior
   except where intentionally updated (Task 8 spinner glyph, Task 18 width).

## Out-of-scope / deferred notes

- **ui-render-08 (interactive multi-file diff navigator):** L and low value for a CLI. Recommend
  deferring the interactive overlay; if any work is done, ship only the parse-to-file-list helper.
- **terminal-06 full ParsedKey model:** explicitly NOT adopting a general ParsedKey struct. zcode's
  chord->InputEvent design is intentional. We only add super-modifier naming clarity and fn/numpad
  recognize-and-ignore (plus optional numpad-digit/enter mapping).
- **terminal-10 renderer rework:** the conhost guard function is added for parity, but no cursor-up
  redraw path is introduced. zcode's absolute-positioning renderer is immune; do not add a vulnerable
  path.
- **ui-render-07 pair-line syntax highlighting:** kept OFF for word-diff pairs by design (layering
  intra-line accent on syntax colors is noisy). Only the env gate is added.
- **terminal-04 OSC 9;4:** cosmetic; ship it but treat as lowest priority.
- **Color-level runtime rewrite (Task 16/17):** if the auto-select-ansi-palette route is chosen for
  the built-in themes, the RGB->256 runtime rewriter (Task 17) becomes a standalone utility only
  needed to also clamp custom truecolor themes; that custom-theme clamp can be deferred.
- **Wiki checkpoint:** record in the project wiki (a) the boost-then-clamp ORDER for color levels and
  why, (b) the decision to re-introduce the spinner glyph morph behind a flag after the prior
  user-feedback removal, (c) the `CLAUDE_CODE_SYNTAX_HIGHLIGHT` default choice, and (d) that
  terminal-response slices point into a reused input buffer and must be duped if retained.
