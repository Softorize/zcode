# Phase 16: Vim mode, keybindings, cost/usage accounting, telemetry, git/bootstrap utilities

## Overview

**What.** This phase closes a wide band of "long-tail" parity gaps that share one
property: they are all local, in-process, no-cloud-dependency features that the
reference (`claude-code-main`) ships and zcode either partially ships or silently
drops. There are five families:

1. **Vim mode (vim-keys-01..10)** -- ten concrete vim-motion / operator gaps in
   `src/cli/repl_vim.zig`: WORD motions (`W`/`B`/`E`), `~` toggle-case, `J` join,
   `Y` yank-line, `>>`/`<<` indent, `gj`/`gk` display-line, operator+`G`/`gg`,
   operator+`h`/`l`/`b`/`j`/`k`, the `cw`->`ce` special-case, and a trivial
   count-cap off-by-magnitude. These are mostly wiring: the predicates and helpers
   (`isBigWordChar`, `moveWordEnd`, `lineRangeForCount`, `moveToLastLine`) already
   exist; the dispatch tables don't reference them.

2. **Keybindings (vim-keys-11/12/13)** -- structured validation warnings
   (parse_error / duplicate / invalid_context / invalid_action) surfaced to the
   user, a macOS-reserved-shortcut table, and (deferred) a hot-reload file watcher.

3. **Cost / usage accounting (cost-limits-01..04, api-providers-06)** -- per-model
   usage breakdown, cache-read/cache-creation token extraction and pricing,
   cross-session cost restore on `/resume`, and an unknown-model inaccuracy
   warning. These build on the Phase-7 `TokenUsage`/`PriceEntry` surface and the
   `extractors.zig` token parser.

4. **Telemetry (analytics-03/04/10)** -- configurable OTEL push exporters
   (`OTEL_EXPORTER_OTLP_*`), wiring the three defined-but-unincremented standard
   counters, and per-attribute INCLUDE/EXCLUDE + cardinality controls.

5. **Git / bootstrap utilities (misc-utils-01..12, 14, 16, 17, 18, 20)** -- a
   direct `.git` filesystem reader, ref-name/SHA hardening, an in-memory
   `.git/config` parser, gitignore helpers, `gh auth` status detection, the
   `claude-cli://` deep-link subsystem (parser, handler, registration, banner,
   terminal preference), plaintext-credentials fallback migration semantics,
   keychain TTL cache + locked-keychain detection, ultraplan keyword auto-routing,
   shell-history ghost-text, generic path completion, negative/keep-going
   classification, and the versioned native installer.

**Why.** Each gap is small in isolation but collectively they are the difference
between "vim mode mostly works" and "vim mode does what a vim user expects", and
between "cost is a rough single-model estimate" and "cost is per-model with cache
discounts the way the reference reports it". The deep-link and installer items are
larger architectural pieces that the survey flags as `present_different` or
deferred; this plan scopes them honestly (core URI routing in, OS registration and
headless terminal launch deferred).

**A note on over-reporting.** The survey has a history of over-reporting. Reading
the actual files confirmed several "missing" claims are accurate (no `~`, `J`, `Y`,
`W`/`B`/`E`, no cache-token fields, no per-model map, no macOS-reserved table, no
push exporters) but downgraded others: the deep-link OS-registration
(misc-utils-08) and protocol-handler entry (misc-utils-07) are genuinely heavy
platform glue and are **deferred**, not built, in this phase. The native installer
(misc-utils-20) is a deliberate architectural divergence (in-place secure update vs
versioned-dir + symlink) and is left as-is with only a documented rationale.

**Dependencies.** Phase 1 (foundational primitives, module registration
conventions, `CurlResponseWithStatus` and response plumbing) and Phase 7 (the
`TokenUsage` struct in `src/providers/extractors.zig` and the `PriceEntry`/cost
surface in `src/core/cost.zig` that the cache-token and per-model work extends).

**Effort.** XL. 33 gaps. The vim family is many-small-tasks (M total). Cost +
cache accounting is M. Telemetry push exporter is L. The git/deep-link/installer
family contains the only genuinely large items (direct `.git` reader, deep-link
subsystem, installer) and several of those are explicitly deferred to keep the
phase shippable.

## Gaps covered

| id | title | severity | size | our current state |
|---|---|---|---|---|
| vim-keys-01 | W/B/E (WORD) motions missing | medium | M | lowercase w/b/e present standalone + as operator motions; `isBigWordChar` exists (repl_vim.zig:907) but only used by text objects. No `moveWORD*` helpers. |
| vim-keys-02 | `~` toggle-case missing | low | S | No `~` case, no `toggleCase` recorded-change variant. Falls through to `clearPending`. |
| vim-keys-03 | `J` join-lines missing | low | S | No `J` case, no join helper, no recorded-change variant. |
| vim-keys-04 | `Y` yank-whole-line missing | low | S | `yy` works via operator path; `Y` synonym absent. |
| vim-keys-05 | `>>`/`<<` indent/dedent missing | low | M | No indent pending state, no `>`/`<` handlers, no indent recorded-change. |
| vim-keys-06 | `gj`/`gk` display-line motions missing | low | S | `g` pending only handles `gg`; j/k standalone use logical-line `moveVertical`. |
| vim-keys-07 | operator+`G`/`gg` (dG/dgg/cG/yG/ygg) missing | medium | M | `handleOperatorKey` accepts only w/e/$/0/^/find/textobj; G/g dropped silently. |
| vim-keys-08 | operator+`h`/`l`/`b`/`j`/`k`/`W`/`B`/`E` missing | medium | M | operator motions limited to w/e/$/0/^. dj/dk/db/dl unsupported. |
| vim-keys-09 | `cw`/`cW` not special-cased to `ce`/`cE` | medium | S | `w` always routes through `wordForwardExclusive` (skips trailing ws) regardless of op. |
| vim-keys-10 | count cap 9999 vs reference 10000 | low | S | `pushCountDigit`/`pushOperatorCountDigit` clamp to 9999 (repl_vim.zig:855/861). |
| vim-keys-11 | keybinding validation warnings not surfaced | medium | M | Reserved-conflict warnings + count exist; no parse_error/duplicate/invalid_context/invalid_action structured warnings. |
| vim-keys-12 | macOS-reserved shortcuts not in reserved table | low | S | NON_REBINDABLE + TERMINAL_RESERVED exist; no MACOS_RESERVED, no platform branch. |
| vim-keys-13 | keybindings.json hot-reload watcher absent | low | L | On-demand load + manual `/reload` only; no fs watcher. **Deferred** (manual reload is an adequate analog). |
| cost-limits-01 | per-model usage breakdown | medium | M | Single-model input+output only; no per-model map, no `formatModelUsage`. |
| cost-limits-02 | cache-read/cache-creation token accounting + cost | low | M | `TokenUsage` has only input/output; no cache fields, no cache pricing tier. |
| cost-limits-03 | cross-session cost restore | medium | M | Append-only cost_log.jsonl exists; `/resume` does not restore accumulated totals. |
| cost-limits-04 | unknown-model cost warning | low | S | `estimateCost` silently returns 0.0 for unknown models; no caveat. |
| api-providers-06 | cache-token usage accounting (tiers, service_tier) | medium | M | Only input/output extracted; cache_control emitted but never read back. |
| analytics-03 | OTEL configurable push exporters | medium | L | Pull-based `/otel` endpoint + render only; no `OTEL_EXPORTER_OTLP_*`, no push loop. |
| analytics-04 | `claude_code.*` standard counters | medium | M | 9 names defined; tool_executions_total / circuit_breaker_state / rate_limit_rejections never wired. |
| analytics-10 | cardinality + privacy INCLUDE toggles | low | S | Binary opt-in + redact-prompt-bodies only; no per-attribute include/exclude. |
| misc-utils-01 | direct `.git` filesystem reader | low | L | All git state via subprocess spawn + stat-fingerprint cache. **Partially deferred** (worktree/packed-refs reader is L). |
| misc-utils-02 | isSafeRefName / isValidGitSha hardening | low | S | Only generic `isSafeIdentifier` (task IDs). No ref/SHA validators. |
| misc-utils-03 | `.git/config` in-memory parser | low | M | Shell out to `git config --get`. No INI parser. |
| misc-utils-04 | gitignore helpers (check-ignore + global append) | low | S | Absent entirely. |
| misc-utils-05 | gh CLI auth status detection | low | S | `hasGhCli` (install only); no 3-state install/auth/none. |
| misc-utils-06 | `claude-cli://` deep-link URI parser | low | M | Absent; percent-decode + unicode-sanitize primitives exist to reuse. |
| misc-utils-07 | `--handle-uri` entry + headless terminal launch | low | L | Absent. **Deferred** (terminal-launch glue is heavy; only the URI-routing core is in-scope). |
| misc-utils-08 | OS protocol-handler registration | low | L | Absent. **Deferred** (out of scope per survey). |
| misc-utils-09 | deep-link provenance banner + FETCH_HEAD staleness | low | S | Absent; FETCH_HEAD-age helper reusable in /doctor. Partial in-scope. |
| misc-utils-10 | terminal preference capture | low | M | TERM_PROGRAM detection exists (ide_detect.zig); no storage/mapping. **Deferred** (only useful with misc-utils-07). |
| misc-utils-11 | plaintext-credentials fallback migration semantics | medium | M | Encrypted file fallback present; no delete-stale-primary on cross-backend migration. |
| misc-utils-12 | keychain TTL cache + locked-keychain detection | low | M | Fallback present; no TTL cache, no exit-36 locked detection, macOS uses argv not stdin. |
| misc-utils-14 | ultraplan keyword auto-routing | low | S | `/ultraplan` explicit command works; no pre-expansion keyword trigger. |
| misc-utils-16 | shell-history ghost-text for `!` bash mode | low | M | Ghost-text for `/` and `@` only; no `!`-prefix path. **Deferred** (depends on a bash-input mode). |
| misc-utils-17 | generic directory/path completion | low | M | `@`-mention context detection only; no `scanDirectory`/`isPathLikeToken`. |
| misc-utils-18 | negative / keep-going prompt classification | low | S | `isShortFollowUp` partial; no explicit `matchesNegativeKeyword`/`matchesKeepGoingKeyword` + telemetry. |
| misc-utils-20 | native installer: versioned dir + symlink + PID locks | low | L | In-place secure update (checksum + cosign). **Deferred** (deliberate divergence; document rationale). |

## Implementation tasks

Tasks are grouped by family. Within the vim family, 16.1-16.5 are independent
single-key additions and can be parallelized; 16.6-16.7 share the operator
dispatch table and must be serialized relative to each other. The cost family
(16.10-16.14) shares `extractors.zig` and `cost.zig` and is serialized.

---

### 16.1 WORD motions (`W`/`B`/`E`) standalone and as operator motions

**Goal.** Add whitespace-delimited WORD motions wired both into the normal-mode
switch and the operator-motion dispatch.

**Reference behavior.** `src/vim/types.ts:135-149` (SIMPLE_MOTIONS includes
`W`/`B`/`E`); `src/vim/motions.ts:50-55` (W/B/E cases); `src/vim/transitions.ts:107-114`
(SIMPLE_MOTIONS.has dispatch). WORD = run of non-whitespace; `W` = next WORD start,
`B` = previous WORD start, `E` = end of current/next WORD.

**Target Zig files.** Edit `src/cli/repl_vim.zig` only.

**Approach.**
1. Add three helpers next to the existing `moveWordForward`/`moveWordBackward`/
   `moveWordEnd`, using the already-present `isBigWordChar` predicate (line 907):
   `moveBigWordForward`, `moveBigWordBackward`, `moveBigWordEnd`. Mirror the
   lowercase implementations but classify with `isBigWordChar` (non-whitespace vs
   whitespace) instead of the word/punct/space tri-state.
2. In `handleNormalKey` switch (lines 231-301) add cases:
   `'W' => cursor.* = moveBigWordForward(input_buf.items(), cursor.*, self.consumeCount())`,
   and the analogous `'B'` and `'E'`.
3. In `handleOperatorKey` (line 484) add `'W'`, `'B'`, `'E'` to the motion case,
   and in `applyRecordedOperatorMotion` (lines 555-565) add the three motions
   computing the operated range (W/E exclusive-forward to next WORD start / WORD
   end+1; B backward to WORD start).

**Acceptance criteria.** Write tests in `repl_vim.zig`:
- `W` on `"foo.bar baz"` (cursor at 0) lands on `b` of `baz` (index 8), not `bar`.
- `dW` on `"foo.bar baz"` (cursor 0) deletes `"foo.bar "` leaving `"baz"`.
- `E` from index 0 lands on the last char of `foo.bar`.
- `dot`-repeat of `dW` works (records `operator{.motion='W'}`).

**Test strategy.** New unit tests under `tools/test_runner.zig`.

**Risk / footguns.** Reuse the existing exclusive/inclusive offset conventions
(`wordForwardExclusive` vs `moveWordEnd`+1). Do not regress the lowercase paths.

**Size.** M.

---

### 16.2 `~` toggle-case command

**Goal.** Toggle case of `count` characters under the cursor, advance, dot-repeat.

**Reference behavior.** `src/vim/operators.ts:222-253` (`executeToggleCase`);
`transitions.ts:125-127`; `types.ts:116` (`RecordedChange.toggleCase`).

**Target Zig files.** Edit `src/cli/repl_vim.zig`.

**Approach.**
1. Add a `toggle_case: usize` variant to the `RecordedChange` union (line 32-72).
2. Add a `toggleCase` method: for `count` ASCII bytes from `cursor`, flip case via
   `std.ascii.toUpper`/`toLower` (only when the byte differs), advance cursor past
   the last toggled byte, set `modified = true`, and record `.toggle_case = count`
   when `record`.
3. Add `'~' => return try self.toggleCase(input_buf, cursor, self.consumeCount(), true)`
   to `handleNormalKey`.
4. Add the `.toggle_case => |count| try self.toggleCase(..., false)` arm to
   `repeatLastChange` (lines 322-341).

**Acceptance criteria.** Test: `~` on `"aB"` (cursor 0) yields `"Ab"` with cursor
at index 1; `2~` toggles both; `.` repeats the last `~`.

**Test strategy.** Unit tests in `repl_vim.zig`.

**Risk / footguns.** Reference toggles graphemes; we operate on ASCII bytes
(consistent with the rest of `repl_vim.zig`'s byte-cursor model). Note this in a
comment. Non-ASCII bytes pass through unchanged.

**Size.** S.

---

### 16.3 `J` join-lines command

**Goal.** Join the current line with the next `count` lines, trimming leading
whitespace and inserting a single space; record for dot-repeat.

**Reference behavior.** `src/vim/operators.ts:258-289` (`executeJoin`);
`transitions.ts:131-133`; `types.ts:119` (`RecordedChange.join`).

**Target Zig files.** Edit `src/cli/repl_vim.zig`.

**Approach.**
1. Add a `join: usize` variant to `RecordedChange`.
2. Add a `joinLines` method: split `input_buf` on `'\n'`, find the cursor's line
   via existing line helpers, append the next `min(count, remaining)` lines with
   `std.mem.trimLeft(u8, next, " \t")` and a single space separator (skip the space
   when the joined line is empty or already ends with a space, matching the
   reference's `endsWith(' ')` guard), rebuild the buffer, place the cursor at the
   join seam. Use `repl_input` insert/delete primitives rather than hand-rolling.
3. Add `'J'` to `handleNormalKey` and the `.join` arm to `repeatLastChange`.

**Acceptance criteria.** Test: `J` on `"foo\n   bar"` -> `"foo bar"` with cursor at
the space (index 3); `J` on a single line is a no-op; `.` repeats.

**Test strategy.** Unit tests.

**Risk / footguns.** Single-line REPL is the common case (no-op path must be
robust). Watch the trailing-`\n` edge: a buffer ending in `\n` has an implicit
empty last line.

**Size.** S.

---

### 16.4 `Y` yank-whole-line command

**Goal.** `Y` yanks `count` whole lines linewise (synonym for `yy`).

**Reference behavior.** `transitions.ts:143-145` (`Y` -> `executeLineOp('yank',count)`).

**Target Zig files.** Edit `src/cli/repl_vim.zig`.

**Approach.** Add `'Y' => return try self.handleLinewiseOperator(.yank, input_buf,
cursor, self.consumeCount(), false)` to `handleNormalKey`. This reuses the existing
linewise yank path (lines 508-539) that `yy` already uses.

**Acceptance criteria.** Test: after `Y` the register equals the current line + `\n`
and `register_linewise == true`; `2Y` captures two lines.

**Test strategy.** Unit test asserting register contents post-`Y` match post-`yy`.

**Risk / footguns.** None; pure dispatch reuse.

**Size.** S.

---

### 16.5 `>>`/`<<` indent/dedent operators

**Goal.** `>` then `>` indents `count` lines by two spaces; `<` then `<` dedents;
dot-repeatable.

**Reference behavior.** `src/vim/operators.ts:348-392` (`executeIndent` -- two-space
indent; dedent strips up to two leading spaces or one tab); `transitions.ts:122-124,
450-459`; `types.ts:75,117`.

**Target Zig files.** Edit `src/cli/repl_vim.zig`.

**Approach.**
1. Add `indent` and `dedent` to the `Pending` enum (lines 11-18). On `'>'` set
   `pending = .indent` and capture the count; on `'<'` set `pending = .dedent`.
2. In `handleNormalKey`, at the top where pending operators are checked (around line
   221), add a branch: when `pending == .indent and key == '>'` (or
   `.dedent and key == '<'`), apply the indent over `lineRangeForCount`; any other
   key clears pending (matching vim's "doubled key" requirement).
3. Add an `indent: struct { dir: enum { in, out }, count: usize }` variant to
   `RecordedChange` and an `applyIndent` method that, per affected line, prepends
   `"  "` (indent) or strips up to two leading spaces / one leading tab (dedent),
   then places the cursor at the first non-blank of the current line. Record for
   dot-repeat.

**Acceptance criteria.** Test: `>>` on `"foo"` -> `"  foo"`; `<<` on `"    foo"` ->
`"  foo"`; `<<` on `"\tfoo"` -> `"foo"`; `2>>` indents two lines; `.` repeats.

**Test strategy.** Unit tests.

**Risk / footguns.** The doubled-key state machine: `>x` (where x != `>`) must clear
pending without modifying. Match the reference's "remove as much leading whitespace
as possible up to indent length" dedent fallback (operators.ts:370-382).

**Size.** M.

---

### 16.6 `gj`/`gk` display-line motions + operator+`G`/`gg`

**Goal.** Support `gj`/`gk` (treated as logical j/k for our single-buffer REPL) and
operator+`G`/`gg` (dG, dgg, cG, cgg, yG, ygg).

**Reference behavior.** `motions.ts:40-43` (gj/gk); `transitions.ts:385-397`
(fromG j/k), `425-430` (fromOperatorG j/k); `operators.ts:524-556`
(`executeOperatorG`/`executeOperatorGg`); `transitions.ts:233-239,420-436`.

**Target Zig files.** Edit `src/cli/repl_vim.zig`.

**Approach.**
1. In the `pending == .g` handler (lines 212-219), in addition to `'g'`, handle
   `'j'`/`'k'` by calling `moveVertical` (our renderer does not soft-wrap distinctly,
   so display-line == logical-line here; document this divergence -- the keys must
   not be silently dropped).
2. For operator+`g`: when an operator is pending and `'g'` arrives, set a sub-pending
   so the next `'g'` resolves to "operate linewise to first line (or line N with
   count)" using `moveToFirstLine` + `lineRangeForCount` semantics.
3. For operator+`G`: in `handleOperatorKey`, add `'G'` to operate linewise to the
   last line (or line N), reusing `moveToLastLine` (standalone `G` already uses it,
   line 249) to compute the target line and the linewise range between cursor line
   and target line.
4. Record both as recorded-change variants so `.` repeats `dG`/`dgg`.

**Acceptance criteria.** Tests: on a 3-line buffer, `dG` from line 1 deletes all;
`dgg` from line 3 deletes all; `2dG`-style count to line N; `gj` moves down one
logical line; operator+g that is not `gg` clears cleanly.

**Test strategy.** Unit tests in `repl_vim.zig`.

**Risk / footguns.** The operator+`g` two-step (operator pending, then `g`, then `g`)
needs a distinct sub-state so it does not collide with the standalone `pending == .g`
path. Linewise range math must include the trailing/leading newline correctly
(see reference operators.ts:451-464).

**Size.** M.

---

### 16.7 operator+`h`/`l`/`b`/`j`/`k` (and W/B/E from 16.1)

**Goal.** Extend operator motions to the remaining SIMPLE_MOTIONS: `h`, `l`
(charwise), `b` (charwise back), `j`/`k` (linewise down/up).

**Reference behavior.** `transitions.ts:229-231` (SIMPLE_MOTIONS ->
`executeOperatorMotion`); `operators.ts:42-54,451-464` (j/k linewise range).

**Target Zig files.** Edit `src/cli/repl_vim.zig`.

**Approach.**
1. In `handleOperatorKey` (line 484), add `'h'`, `'l'`, `'b'` to the motion case
   list, and `'j'`/`'k'` to a new linewise branch.
2. In `applyRecordedOperatorMotion` (lines 555-565) compute ranges:
   - `h`: `[cursor - count*1, cursor)` charwise (clamp at line start).
   - `l`: `[cursor, cursor + count)` charwise (clamp at line end).
   - `b`: `[moveWordBackward(...), cursor)`.
   - `j`/`k`: linewise -- delete/yank/change `count+1` lines starting at (or above)
     the cursor's line, reusing the linewise range helper from 16.6.

**Acceptance criteria.** Tests: `dj` on a 2-line buffer deletes both lines; `dk`
deletes the current and previous line; `dl` deletes one char; `db` deletes the
previous word; `2dl` deletes two chars.

**Test strategy.** Unit tests; assert linewise (`j`/`k`) vs charwise (`h`/`l`/`b`)
behavior distinctly.

**Risk / footguns.** `j`/`k` MUST be linewise inside operators (dj deletes whole
lines) but charwise as standalone motions -- do not unify them. Land 16.1 first so
`W`/`B`/`E` operator wiring is already present.

**Size.** M.

---

### 16.8 `cw`/`cW` special-case to `ce`/`cE`

**Goal.** `cw`/`cW` changes to the END of the current word (excluding trailing
whitespace), not to the start of the next word.

**Reference behavior.** `operators.ts:441-450`: `if (op === 'change' && (motion ===
'w' || 'W'))` use the word-end range (`nextOffset(wordEnd)`), with count handled by
advancing `count-1` words first.

**Target Zig files.** Edit `src/cli/repl_vim.zig`.

**Approach.** In `applyRecordedOperatorMotion` (line 556), branch the `'w'` (and the
new `'W'` from 16.1) case on `op == .change`: when changing, compute the range as
`[cursor, moveWordEnd(text, cursor, count) + 1)` (the `'e'` path already does this at
lines 557-560) instead of `wordForwardExclusive`. For delete/yank keep
`wordForwardExclusive`.

**Acceptance criteria.** Test: `cw` on `"hello world"` (cursor at `h`) leaves
`" world"` (changes `hello`, preserves the space), entering insert; `dw` on the same
input still consumes the trailing space leaving `"world"`. Same for `cW`/`dW`.

**Test strategy.** Unit test contrasting `cw` vs `dw` on identical input.

**Risk / footguns.** This is the one concrete behavioral divergence the survey
calls out. Keep the `e`-style `+1` inclusive end and clamp to `text.len`.

**Size.** S.

---

### 16.9 Count cap 9999 -> 10000

**Goal.** Match `MAX_VIM_COUNT = 10000`.

**Reference behavior.** `types.ts:182` (`MAX_VIM_COUNT=10000`); `transitions.ts:272,322`
(`Math.min(parseInt, MAX_VIM_COUNT)`).

**Target Zig files.** Edit `src/cli/repl_vim.zig` (lines 855, 861).

**Approach.** Introduce `const MAX_VIM_COUNT: usize = 10000;` and clamp both
`pushCountDigit` and `pushOperatorCountDigit` to it instead of the literal `9999`.

**Acceptance criteria.** Test: typing `10000h` clamps the count to exactly 10000;
`10001h` also clamps to 10000.

**Test strategy.** Unit test reading the consumed count.

**Risk / footguns.** Trivial; ensure the clamp is applied after the multiply-add so
`9999` -> append `9` does not overflow before clamping.

**Size.** S.

---

### 16.10 Cache-token extraction in `extractors.zig` (api-providers-06, cost-limits-02 part 1)

**Goal.** Extend `TokenUsage` to carry cache-read / cache-creation tokens and web
search request counts, and extract them across provider response shapes.

**Reference behavior.** `cost-tracker.ts:268-271` reads `usage.cache_read_input_tokens`,
`usage.cache_creation_input_tokens`, `usage.server_tool_use?.web_search_requests`.
`emptyUsage.ts:8-22` shows the full usage shape.

**Target Zig files.** Edit `src/providers/extractors.zig`.

**Approach.**
1. Add optional fields to `TokenUsage` (lines 5-8): `cache_read_input_tokens:
   ?usize = null`, `cache_creation_input_tokens: ?usize = null`,
   `web_search_requests: ?usize = null`.
2. In the Anthropic branch of `extractTokenUsage` (lines 28-35) pull
   `cache_read_input_tokens` and `cache_creation_input_tokens` from the usage object
   via the existing `getIntField`, and `server_tool_use.web_search_requests` when
   present. Leave OpenAI/Gemini/Ollama branches null (they do not report these).

**Acceptance criteria.** Extend the existing Anthropic test (extractors.zig:847) and
add a new one: a payload with `{"usage":{"input_tokens":77,"output_tokens":12,
"cache_read_input_tokens":40,"cache_creation_input_tokens":8}}` extracts all four;
an OpenAI payload leaves cache fields null.

**Test strategy.** Unit tests in `extractors.zig` (already a registered test module).

**Risk / footguns.** Keep fields optional (null != 0) so providers that omit them do
not falsely report zero-cache. `getIntField` already guards negatives/overflow.

**Size.** S (part of the larger cost-limits-02 / api-providers-06).

---

### 16.11 Cache pricing tier + cache cost in `cost.zig` (cost-limits-02 part 2)

**Goal.** Price cached tokens (cache-read is ~10x cheaper; cache-creation is a small
premium) and accept cache token counts in cost estimation.

**Reference behavior.** `cost-tracker.ts:217-218` surfaces cache columns;
`calculateUSDCost` prices cached tokens at their tier.

**Target Zig files.** Edit `src/core/cost.zig`.

**Approach.**
1. Add `cache_read_per_m: f64` and `cache_write_per_m: f64` to `PriceEntry`
   (lines 9-14). For Anthropic entries set cache-read to `input_per_m * 0.1` and
   cache-write to `input_per_m * 1.25` (Anthropic's published multipliers). For
   providers without published cache pricing, default both to the input rate so the
   estimate degrades gracefully.
2. Add `estimateCostWithCache(provider, model, input, output, cache_read,
   cache_write) f64` that adds the cache token cost; keep the existing
   `estimateCost` as a thin wrapper passing zero cache tokens (no breakage).

**Acceptance criteria.** Test: for `claude-sonnet-4`, 1M cache-read tokens cost
`$0.30` (10% of $3 input); `estimateCostWithCache(..., 0, 0)` equals the old
`estimateCost`.

**Test strategy.** Unit tests in `cost.zig`.

**Risk / footguns.** Do not change the signature of `estimateCost` (many call
sites). The cache multipliers are Anthropic-specific; document them and gate the
discount to the Anthropic provider so OpenAI-compatible models are not mis-priced.

**Size.** S.

---

### 16.12 Per-model usage accumulator + `formatModelUsage` (cost-limits-01)

**Goal.** Accumulate a `ModelUsage` record per model and render a "Usage by model:"
block in `/cost`.

**Reference behavior.** `cost-tracker.ts:181-226` (`formatModelUsage` grouped by
canonical short name), `250-276` (`addToTotalModelUsage`), `266-271` (cache/web
summing).

**Target Zig files.** New module `src/core/model_usage.zig` (deep module, registered
in the `src/main.zig` comptime block per the test-discovery rule). Edit
`src/core/cost.zig` (`renderCostReport`) and `src/agent_runtime.zig` (call the
accumulator on each response).

**Approach.**
1. Create `src/core/model_usage.zig` with a `ModelUsage` struct (input/output/
   cache_read/cache_write/web_search tokens + cost_usd) and a `ModelUsageMap` backed
   by a `std.StringHashMap` keyed by model name, with `add(model, usage, cost)` and
   an iterator. Use `@import("zcode_runtime")` if it needs the runtime allocator;
   otherwise take an allocator parameter (preferred for testability).
2. Wire the accumulator into `agent_runtime.zig` `recordResponseUsage` (line ~3195)
   so each turn updates the per-model map.
3. In `cost.zig` `renderCostReport` (lines 87-153) add a "Usage by model:" section
   iterating the map: `<model>: N input, N output, N cache read, N cache write[, N
   web search] ($cost)`. Reuse `format.formatTokens` and `formatCost`.
4. Register `_ = @import("core/model_usage.zig");` in `src/main.zig`.

**Acceptance criteria.** Test in `model_usage.zig`: two `add` calls for the same
model accumulate; two different models produce two entries; the render contains both
model names and a per-model cost. A `renderCostReport` test asserts the "Usage by
model:" line appears when the map is non-empty.

**Test strategy.** Unit tests under `tools/test_runner.zig`.

**Risk / footguns.** `StringHashMap` keys must be owned (dupe the model name on
insert; free on deinit) -- a borrowed `active_model` slice can dangle. Per the 0.16
gotcha list, do not hold a pointer into the map across an insert that may realloc;
fetch the entry pointer after `getOrPut`.

**Size.** M.

---

### 16.13 Unknown-model cost warning (cost-limits-04)

**Goal.** When a model that produced tokens has no price entry, `/cost` notes the
estimate may be inaccurate instead of silently reporting `$0`.

**Reference behavior.** `cost-tracker.ts:228-234` (`hasUnknownModelCost` appends
" (costs may be inaccurate due to usage of unknown models)").

**Target Zig files.** Edit `src/core/cost.zig`.

**Approach.**
1. Add a `pub fn isKnownModel(provider, model) bool` wrapping `findPriceEntry`.
2. In `renderCostReport`, when `total_output + total_input > 0` and
   `!isKnownModel(provider, model)`, append a `cost_inaccurate=true` line plus the
   human caveat to the report. (Match the existing key=value report style at
   cost.zig:111-150 rather than the reference's prose, since our /cost output is
   key=value.)

**Acceptance criteria.** Test: `renderCostReport` for an unknown model with non-zero
tokens contains the inaccuracy caveat; for a known model it does not.

**Test strategy.** Unit test.

**Risk / footguns.** Only warn when tokens were actually produced (avoid warning on
a fresh session with zero usage).

**Size.** S.

---

### 16.14 Cross-session cost restore (cost-limits-03)

**Goal.** When resuming a session, restore accumulated input/output token totals (and
per-model usage) into the live counters so `/cost` after `/resume` reflects the whole
session, not just the current process.

**Reference behavior.** `cost-tracker.ts:143-175` (`saveCurrentSessionCosts` writes
`lastCost`/`lastSessionId`/`lastModelUsage` etc. to project config), `87-137`
(`getStoredSessionCosts`/`restoreCostStateForSession` keyed on session id);
`costHook.ts:9-21` saves on exit.

**Target Zig files.** Edit `src/agent_runtime.zig` (the `appendSessionCostLog` call
at deinit, lines 490-498, and `initFromSession` at 440-471). Reuse the existing
`~/.zcode/cost_log.jsonl` plus a small per-session sidecar.

**Approach.**
1. On `initFromSession`, when a `session_id` is present, scan the cost log (or a new
   keyed sidecar `~/.zcode/session_cost/<session_id>.json`) for the most recent
   record matching this session id and seed `token_status.total_input_tokens` /
   `total_output_tokens` (and the per-model map from 16.12) from it.
2. On deinit, in addition to the append-only log, write the keyed sidecar with the
   current totals so the next resume can restore them. Keep both writes best-effort
   (swallow errors -- cost logging must never crash the CLI, matching the existing
   `appendSessionCostLog` contract).

**Acceptance criteria.** Test: write a sidecar for session "abc" with totals, then a
fresh `TokenStatus` restored for "abc" reflects those totals; a different session id
restores nothing.

**Test strategy.** Unit test against a `tmpDir` (use `core/test_helpers.zig`
`tmpDirPath` -- do NOT pass `"."` per the CLAUDE.md footgun) overriding the home dir.

**Risk / footguns.** Key strictly on session id so two unrelated sessions do not
cross-contaminate (matches the reference's `lastSessionId` guard). The sidecar
write/read must use absolute paths resolved from HOME.

**Size.** M.

---

### 16.15 Structured keybinding validation warnings (vim-keys-11)

**Goal.** Surface parse_error / duplicate / invalid_context / invalid_action
warnings to the user (e.g. via `/doctor`), not just reserved-conflict warnings.

**Reference behavior.** `validate.ts:130-247` (`validateBlock`), `258-307`
(`checkDuplicateKeysInJson` -- raw-JSON duplicate scan), `312-330`
(`validateUserConfig`), `456-498` (`formatWarning`/`formatWarnings`);
`loadUserBindings.ts:202-213` (warnings attached to the load result).

**Target Zig files.** Edit `src/cli/keybindings.zig`. Surface counts/messages in
`src/cli/repl.zig` (the existing warning-count UI at repl.zig:2827-2843).

**Approach.**
1. Define a `KeybindingWarning` struct (`kind: enum { parse_error, duplicate,
   invalid_context, invalid_action, reserved_conflict }`, `severity`, owned
   `message`, optional key/context) and a list collected during load.
2. In `parseBindingContext`/`parseBindingAction` (lines 774/788) emit
   `invalid_context`/`invalid_action` warnings instead of silently skipping.
3. In `addOrReplaceRuntimeBinding` (lines 1175-1205) emit a `duplicate` warning on
   last-wins instead of silently overwriting.
4. Add a `checkDuplicateKeysInJson`-equivalent that scans the raw JSON text for
   repeated keys within one bindings block (JSON.parse drops earlier duplicates, so
   the parsed map cannot see them).
5. Attach the warning list to `RuntimeLoadReport` (lines 632-636) alongside the
   existing `warning_count`, and render them in `/doctor` / the startup notice.

**Acceptance criteria.** Tests: a binding with an unknown context produces one
`invalid_context` warning; a non-string action produces `invalid_action`; raw JSON
with a repeated key in one block produces `duplicate`; a valid config produces none.

**Test strategy.** Unit tests in `keybindings.zig` feeding crafted JSON strings.

**Risk / footguns.** Own the warning message strings (allocate + free on report
deinit). Keep the raw-JSON duplicate scan tolerant of nested objects (the reference
uses a balanced-brace regex; in Zig do a simple bindings-block bracket walk).

**Size.** M.

---

### 16.16 macOS-reserved shortcuts table (vim-keys-12)

**Goal.** On macOS, warn when a user binds cmd+c/v/x/q/w/tab/space.

**Reference behavior.** `reservedShortcuts.ts:59-67` (`MACOS_RESERVED`), `73-83`
(`getReservedShortcuts` pushes them on macos, all error severity).

**Target Zig files.** Edit `src/cli/keybindings.zig`.

**Approach.**
1. Add a `MACOS_RESERVED` array mirroring `NON_REBINDABLE`/`TERMINAL_RESERVED`
   (lines 259-296) with the seven cmd+* entries, error severity.
2. In `findReservedConflict` (line 393), conditionally include `MACOS_RESERVED` in
   the scanned tables when `builtin.os.tag == .macos` (comptime branch -- no runtime
   platform call needed).

**Acceptance criteria.** Test (gated to macOS or using a comptime-injected platform
flag): binding `cmd+c` returns a reserved conflict on macOS and none on Linux.

**Test strategy.** Unit test in `keybindings.zig`. If the comptime branch makes the
test platform-specific, add a `findReservedConflictForPlatform(platform, key)` inner
helper so the test can exercise both branches deterministically.

**Risk / footguns.** Normalize `cmd`/`command`/`meta` consistently
(`normalizeKeystrokeForComparison` already maps all three to `cmd`).

**Size.** S.

---

### 16.17 Wire the three orphan standard counters (analytics-04)

**Goal.** Increment `tool_executions_total`, set `circuit_breaker_state`, and
increment `rate_limit_rejections` at their real call sites.

**Reference behavior.** `state.ts:955` (8 standard counters all incremented).

**Target Zig files.** Edit `src/agent_tools.zig` (tool execution), the circuit
breaker call site (where `circuit_breaker.zig` `stateValue()` at line 93 is read),
and the provider error path (where `RateLimited` is mapped). Counter names already
defined in `src/core/metrics.zig:111-113`.

**Approach.**
1. In the tool-invocation path (around `logToolInvocationRecord`, agent_tools.zig:869)
   call `metrics.globalMetrics().increment(Names.tool_executions_total)` once per tool
   call (with the tool name as a label via `labeledName`).
2. Where the circuit breaker transitions state, call
   `metrics.globalMetrics().setGauge(Names.circuit_breaker_state,
   @floatFromInt(breaker.stateValue()))`.
3. On a `RateLimited` classification in the provider path, call
   `increment(Names.rate_limit_rejections)`.

**Acceptance criteria.** Test: after a simulated tool call the counter is >= 1; after
a simulated rate-limit the rejection counter increments; the gauge reflects breaker
state. (Where a full integration is impractical, assert the increment helper is
reachable via a direct unit test of the call-site wrapper.)

**Test strategy.** Unit tests at each call-site wrapper; a render assertion that the
counters appear in `/otel` output once non-zero.

**Risk / footguns.** Do not double-count (one increment per tool call, not per
retry). The gauge is a state enum cast to f64 -- keep the enum->value mapping stable.

**Size.** M.

---

### 16.18 Configurable OTEL push exporters (analytics-03)

**Goal.** Read `OTEL_EXPORTER_OTLP_ENDPOINT` / `OTEL_EXPORTER_OTLP_HEADERS` /
`OTEL_EXPORTER_OTLP_PROTOCOL` and periodically push the rendered OTLP JSON to a
remote collector.

**Reference behavior.** `instrumentation.ts:121` (OTEL_* push configuration).

**Target Zig files.** New module `src/core/otel_export.zig` (registered in
`src/main.zig`). Reuse `core/otel.zig` `renderOtlpJson`, the existing curl/HTTP
chokepoint, and `core/egress.zig` for the egress guard. Read env via
`core/env.zig`.

**Approach.**
1. Parse the `OTEL_EXPORTER_OTLP_*` env vars into an `ExporterConfig` (endpoint,
   headers map, protocol -- support `http/json` only initially, the simplest path
   given `renderOtlpJson` already emits OTLP JSON).
2. Add an `exportOnce(config)` that POSTs `renderOtlpJson()` to
   `<endpoint>/v1/metrics` with the configured headers, gated through
   `core/egress.zig` (the endpoint must pass the egress allowlist).
3. Add an opt-in background push loop (only spawned when the endpoint env var is set
   and `cloud_telemetry_opt_in` is true) on a fixed interval (default 60s, override
   via `OTEL_METRIC_EXPORT_INTERVAL`). Use the same background-thread pattern as
   existing schedulers; flush once on shutdown.

**Acceptance criteria.** Tests: config parsing of endpoint + comma-separated headers;
`exportOnce` against a local mock server records a POST with the OTLP body;
push loop disabled when the env var is unset.

**Test strategy.** Unit tests for parsing; an integration test against a loopback
mock HTTP server (pattern used elsewhere in the repo) for `exportOnce`.

**Risk / footguns.** Must be opt-in and egress-guarded (do not push metrics to an
arbitrary remote without `cloud_telemetry_opt_in`). Per the 0.16 gotcha: use
`std.process.spawn`/`run` correctly and never `wait()` after a `kill`. The
background thread must be joinable and flushed on exit so a short one-shot run still
pushes a final batch.

**Size.** L.

---

### 16.19 Per-attribute INCLUDE/EXCLUDE + cardinality controls (analytics-10)

**Goal.** Allow config to drop individual telemetry attributes and limit per-attribute
distinct-value cardinality.

**Reference behavior.** `telemetryAttributes.ts` (INCLUDE toggles).

**Target Zig files.** Edit `src/core/config.zig` (add `telemetry_attribute_allowlist:
?[]const []const u8` and `telemetry_cardinality_limit: ?usize`) and the attribute
emission site `src/agent_tools.zig:869-907` (`logToolInvocationRecord`).

**Approach.**
1. Add the two config fields (default null = current behavior: all attributes, no
   limit).
2. In `logToolInvocationRecord`, when an allowlist is set, emit only attributes whose
   key is in the list; when a cardinality limit is set, track distinct values per
   attribute key and replace overflow values with `"<other>"`.

**Acceptance criteria.** Tests: with an allowlist of `["tool_name"]`, only
`tool_name` is emitted; with cardinality limit 2, the third distinct value of an
attribute becomes `"<other>"`.

**Test strategy.** Unit tests of the filtering helper (extract the filter into a pure
function so it is testable without the full audit-log path).

**Risk / footguns.** Cardinality tracking needs a small per-key value set; bound it
so a hostile high-cardinality stream cannot grow memory unboundedly (the limit IS
the bound). Keep the default behavior unchanged (null fields).

**Size.** S.

---

### 16.20 isSafeRefName / isValidGitSha hardening (misc-utils-02)

**Goal.** Add the two validators so any future direct-`.git` reader (and current
branch-name -> git-arg paths) reject traversal / argument / shell injection.

**Reference behavior.** `gitFilesystem.ts:98-131` (`isSafeRefName`, `isValidGitSha`).

**Target Zig files.** New module `src/core/git_ref.zig` (registered in
`src/main.zig`). Optionally call from the branch-name code paths
(`repl_commands.zig:2106-2114`, `tools/git_extra.zig`).

**Approach.**
1. `isSafeRefName(name) bool`: reject empty, leading `-` or `/`, any `..`, any empty
   or single-dot `/`-separated component, and anything outside `[A-Za-z0-9/._+@-]`.
2. `isValidGitSha(s) bool`: exactly 40 or 64 lowercase hex chars.
3. Guard `/branch create`/`/branch switch` user input through `isSafeRefName` before
   passing to `git checkout` (per CLAUDE.md "Fix what you find").

**Acceptance criteria.** Tests mirroring the reference comments: `feature/foo` ok;
`-x`, `/x`, `a..b`, `foo/./bar`, `foo//bar`, `foo;rm` rejected; 40-hex SHA ok, 39-hex
and uppercase rejected.

**Test strategy.** Unit tests in `git_ref.zig`.

**Risk / footguns.** This is the cheap prerequisite for misc-utils-01. Do it
regardless of whether the direct reader lands.

**Size.** S.

---

### 16.21 `.git/config` in-memory parser (misc-utils-03)

**Goal.** Parse `.git/config` to extract a value under `[section "subsection"] key`
without spawning git.

**Reference behavior.** `gitConfigParser.ts:18-278` (`parseGitConfigValue` --
case-insensitive section/key, case-sensitive quoted subsection with `\\`/`\"`
escapes, inline `#`/`;` comments, quoted values, escape sequences).

**Target Zig files.** New module `src/core/git_config.zig` (registered in
`src/main.zig`).

**Approach.** Implement a small INI-style line scanner: track the current
`[section]` / `[section "subsection"]` header (case-insensitive section, case-
sensitive subsection), parse `key = value` lines (case-insensitive key), strip inline
`#`/`;` comments outside quotes, unescape `\\`/`\"`/`\n`/`\t` in quoted values.
Expose `getValue(text, section, subsection, key) ?[]const u8`.

**Acceptance criteria.** Tests against the formats the reference's `config.c` tests
cover: `[remote "origin"] url = ...` reads back; quoted subsection with escapes;
inline comment stripped; case-insensitive section match.

**Test strategy.** Unit tests in `git_config.zig`.

**Risk / footguns.** Lower priority -- only matters if the direct `.git` reader
(misc-utils-01) lands. Implement it as a standalone parser so it is independently
testable and reusable.

**Size.** M.

---

### 16.22 Direct `.git` filesystem reader (misc-utils-01) -- scoped

**Goal.** Read branch / HEAD / ref state directly from `.git/` without spawning git,
for performance and to support worktree gitdir pointers and packed-refs.

**Reference behavior.** `gitFilesystem.ts:40-309` (`resolveGitDir`, `readGitHead`,
`resolveRef`, `getCommonDir`, `readRawSymref`).

**Target Zig files.** New module `src/core/git_fs.zig` (registered in
`src/main.zig`). Consumes `core/git_ref.zig` (16.20).

**Approach.**
1. `resolveGitDir(cwd)`: find `.git`; if it is a file containing `gitdir: <path>`
   (worktree/submodule), follow the pointer.
2. `readGitHead(gitDir)`: parse `ref: refs/heads/<branch>` (validate via
   `isSafeRefName`) or a detached SHA (validate via `isValidGitSha`).
3. `resolveRef(gitDir, ref)`: loose ref file first, then `packed-refs`, following
   symrefs, falling back to `commondir`.
4. Wire as a fast path in `context.zig` `captureGitBranch`, keeping the
   subprocess path as the fallback when the direct read fails.

**Acceptance criteria.** Tests against a `tmpDir`-initialized git repo
(`core/test_helpers.zig` `tmpDirPath`): branch read matches `git rev-parse
--abbrev-ref HEAD`; a detached HEAD reads the SHA; a packed-ref-only ref resolves.

**Test strategy.** Integration tests creating real repos in a tmp dir.

**Risk / footguns.** L item. The fs-watcher cache (the reference's `GitFileWatcher`)
is **deferred** -- our stat-fingerprint cache (`context.zig:273-287`) is the analog
and is sufficient. Per CLAUDE.md tmpDir footgun: never pass `"."` as cwd. This is a
performance/robustness gap, not a correctness one (subprocess path already works),
so it is the lowest-priority item in the phase and may be split into a follow-up if
phase scope runs long.

**Size.** L.

---

### 16.23 gitignore helpers (misc-utils-04)

**Goal.** `isPathGitignored` (via `git check-ignore`), `getGlobalGitignorePath`
(`~/.config/git/ignore`), `addFileGlobRuleToGitignore` (append `**/<file>`).

**Reference behavior.** `gitignore.ts:23-99`.

**Target Zig files.** New module `src/core/gitignore.zig` (registered in
`src/main.zig`). Reuse `std.process.run` and `core/xdg.zig`/HOME resolution.

**Approach.**
1. `isPathGitignored(cwd, path) bool`: run `git check-ignore <path>`; exit 0 =
   ignored, 1 = not, 128 = not a repo -> false (fail open).
2. `getGlobalGitignorePath(allocator) []u8`: `$HOME/.config/git/ignore`.
3. `addFileGlobRuleToGitignore(filename, cwd)`: if not already ignored, ensure the
   dir exists, read the file, append `\n**/<filename>\n` only if absent; create on
   ENOENT.

**Acceptance criteria.** Tests in a tmp git repo: a tracked-but-then-ignored path
returns true; appending a rule is idempotent (second call does not duplicate the
line).

**Test strategy.** Integration tests against a tmp repo + tmp HOME.

**Risk / footguns.** Per CLAUDE.md: `Child.Cwd` is a union -- pass `.{ .path = cwd }`.
Best-effort: swallow errors (matches the reference's `logError` non-fatal contract).

**Size.** S.

---

### 16.24 gh CLI auth status (misc-utils-05)

**Goal.** Return `not_installed` / `not_authenticated` / `authenticated`.

**Reference behavior.** `ghAuthStatus.ts:17-29`: `which('gh')` then exit code of
`gh auth token` with stdout ignored (token never enters the process), 5s timeout.

**Target Zig files.** Edit `src/tools/git_extra.zig` (alongside the existing
`hasGhCli` at line 215).

**Approach.** Add `pub fn ghAuthStatus(allocator) enum { not_installed,
not_authenticated, authenticated }`: if `which gh` (or `gh --version`) fails ->
not_installed; else run `gh auth token` with `stdout_limit`/`stderr_limit` discarded
-> authenticated on exit 0, else not_authenticated. Surface in `/doctor`
(`repl_commands.zig:2918`).

**Acceptance criteria.** Test: on a machine without gh, returns `not_installed`
(skip-if-present guard). The function compiles and the three-state enum is returned;
a `/doctor` line shows the auth state.

**Test strategy.** Unit test gated on gh presence (skip when absent, matching other
tool-detection tests).

**Risk / footguns.** Use `gh auth token`, NOT `gh auth status` (the latter hits the
network). Never log the token; discard stdout.

**Size.** S.

---

### 16.25 `claude-cli://` deep-link URI parser + builder (misc-utils-06)

**Goal.** Parse `claude-cli://open?q=&cwd=&repo=` with sanitization and caps; build
the inverse.

**Reference behavior.** `parseDeepLink.ts:84-170`: URL-decode, partiallySanitizeUnicode
the query, reject ASCII control chars, `MAX_QUERY_LENGTH=5000`, `MAX_CWD_LENGTH=4096`,
cwd must be absolute, repo must match `owner/repo` slug.

**Target Zig files.** New module `src/core/deep_link.zig` (registered in
`src/main.zig`). Reuse `mcp/oauth.zig` `percentDecodeAlloc` (line 859) and
`core/unicode_sanitize.zig` `stripDangerousUnicode` (line 49).

**Approach.**
1. `parseDeepLink(allocator, uri) !DeepLinkAction` (`{ query: ?[]u8, cwd: ?[]u8, repo:
   ?[]u8 }`): require the `claude-cli://open` scheme/host, split the query string,
   percent-decode each value, sanitize the query via `stripDangerousUnicode`, reject
   ASCII control chars (0x00-0x1F, 0x7F), enforce the two length caps, require cwd to
   be absolute (`/` or `X:\`), and match repo against `^[\w.-]+/[\w.-]+$`.
2. `buildDeepLink(allocator, action) ![]u8`: percent-encode and reassemble.

**Acceptance criteria.** Tests mirroring the reference: `claude-cli://open?q=hello+world`
yields query "hello world"; a control char in q errors; a `q` over 5000 chars errors;
a relative cwd errors; `repo=owner/repo` ok, `repo=../x` errors; round-trip
build->parse is stable.

**Test strategy.** Unit tests in `deep_link.zig`.

**Risk / footguns.** This parser is pure (no fs/config access -- repo resolution
happens at the consumer). The whole deep-link subsystem's OS-registration and
headless launch (misc-utils-07/08/10) are **deferred**; this parser is the in-scope
core and is independently useful.

**Size.** M.

---

### 16.26 FETCH_HEAD staleness helper (misc-utils-09, scoped)

**Goal.** A reusable "repo may be stale" helper that stats `.git/FETCH_HEAD` mtime,
usable in `/doctor` (the full deep-link provenance banner is deferred with the
deep-link launch subsystem).

**Reference behavior.** `banner.ts:54-112` (`readLastFetchTime` stats
`.git/FETCH_HEAD` and the commondir's; banner warns past 7 days).

**Target Zig files.** Edit `src/core/git_fs.zig` (16.22) or a small standalone helper
in `src/context.zig`. Surface in `/doctor` (`repl_commands.zig`).

**Approach.** `lastFetchAgeSeconds(gitDir) ?i64`: stat `.git/FETCH_HEAD` mtime
(falling back to commondir's FETCH_HEAD for worktrees), return age in seconds. In
`/doctor`, when age > 7 days, print a "repo may be stale; CLAUDE.md context could be
outdated" note.

**Acceptance criteria.** Test: a freshly-touched FETCH_HEAD yields a small age; a
missing one yields null.

**Test strategy.** Unit test against a tmp repo.

**Risk / footguns.** The full provenance banner (tildified cwd, repo slug, "scroll to
review" for >1000-char prefill) is tied to the deferred deep-link launch path; only
the FETCH_HEAD-age primitive is built here.

**Size.** S.

---

### 16.27 Credential fallback migration: delete stale primary (misc-utils-11)

**Goal.** When a secret is written to the file fallback, delete any stale OS-keychain
entry so a rotated-away keychain token cannot shadow the fresh file secret (reference
issue #30337).

**Reference behavior.** `fallbackStorage.ts:7-69` (`createFallbackStorage`): on a
successful fallback write, delete the stale primary; on a successful primary write,
delete the secondary.

**Target Zig files.** Edit `src/core/keychain.zig` (`set`/`get`, lines 78-154).

**Approach.**
1. In `set`, after a successful OS-backend write, delete the file-store entry (delete
   secondary on primary success).
2. In `set`, when the OS backend fails and we fall back to `setFile`, ALSO delete the
   OS-keychain entry (delete stale primary on fallback success) so `get` (which
   prefers the OS backend first, line 110) cannot return a stale OS secret.

**Acceptance criteria.** Test: write to OS backend, then force a fallback write of a
new secret; `get` returns the new secret (the stale OS entry was deleted). Test the
symmetric case (primary success deletes secondary).

**Test strategy.** Unit tests using the file fallback path (the only one
deterministically testable in CI). Guard OS-backend assertions behind a presence
check.

**Risk / footguns.** Our encrypted file store is arguably stronger than the
reference's plaintext `.credentials.json`; we keep encryption (do NOT port the
plaintext format). The behavioral fix is purely the delete-stale ordering. Deletes
must be best-effort (ignore "not found").

**Size.** M.

---

### 16.28 Keychain locked detection + stdin hex on macOS (misc-utils-12, scoped)

**Goal.** Detect a locked macOS keychain (exit 36) for clearer error messaging, and
pass the secret to `security` via stdin instead of argv (so process monitors cannot
observe it).

**Reference behavior.** `macOsKeychainStorage.ts:26-231`; `macOsKeychainHelpers.ts`
(`isMacOsKeychainLocked` exit 36). The reference's 30s TTL cache + read dedup is a
render-loop optimization that does not apply to our once-at-startup read model and is
**not** ported.

**Target Zig files.** Edit `src/core/keychain.zig` (`setMacos` line 199, `getMacos`
line 229).

**Approach.**
1. In `setMacos`, pass the secret on stdin (the Linux backend already pipes stdin at
   lines 293-319; mirror that for `security add-generic-password -w` via stdin where
   supported, or hex-encode the payload and use `-X`). Stop passing the secret on
   argv.
2. Map `security` exit code 36 to a distinct `error.KeychainLocked` and surface a
   "unlock your login keychain" hint instead of the generic fetch-failed fallback.

**Acceptance criteria.** Test (macOS-gated): a successful set/get round-trips without
the secret appearing in the argv (assert the argv slice does not contain the secret).
Exit-36 maps to the locked error.

**Test strategy.** Unit tests gated on macOS; assert argv construction.

**Risk / footguns.** The TTL cache / read-dedup is explicitly out of scope (our CLI
reads creds once at startup; the storm scenario does not exist for us). Keep the
existing absolute-keychain-path logic (loginKeychainPath) intact -- it solves a real
-25307 dialog bug.

**Size.** M.

---

### 16.29 Ultraplan keyword auto-routing (misc-utils-14)

**Goal.** When interactive, non-slash input contains the `ultraplan` keyword in the
pre-expansion text, route the turn through `/ultraplan` (rewriting the keyword to
`plan`).

**Reference behavior.** `processUserInput.ts:455-493` (`hasUltraplanKeyword` /
`replaceUltraplanKeyword`), gated on interactive prompt mode and non-slash input.

**Target Zig files.** Edit `src/cli/repl.zig` (between the slash-command check at
~7464 and the handler dispatch at ~7609). The explicit `/ultraplan` handler already
exists at `repl_commands.zig:2037-2064`.

**Approach.** Add `hasUltraplanKeyword(input) bool` (detect a standalone "ultraplan"
token, excluding quoted/path contexts -- match the reference's keyword.ts exclusion
behavior at a basic level: skip when the token is inside backticks or looks like a
path) and `replaceUltraplanKeyword(input) []u8` (replace the first "ultraplan" with
"plan"). When interactive and input is non-slash and the keyword matches, dispatch
through the `/ultraplan` handler with the rewritten text.

**Acceptance criteria.** Tests: `"ultraplan build a dashboard"` routes to the
ultraplan handler with input `"plan build a dashboard"`; `"/ask ultraplan"` (slash
input) does NOT auto-route; a quoted/path occurrence does not trigger.

**Test strategy.** Unit tests of the detection/rewrite helpers (pure functions);
keep routing logic thin.

**Risk / footguns.** Gate strictly on interactive + non-slash so non-interactive /
piped runs are unaffected. Keep the quote/path exclusion conservative to avoid false
positives.

**Size.** S.

---

### 16.30 Negative / keep-going prompt classification (misc-utils-18)

**Goal.** Add explicit `matchesNegativeKeyword` / `matchesKeepGoingKeyword` and log
`is_negative` / `is_keep_going` telemetry, distinct from the existing
`isShortFollowUp` heuristic.

**Reference behavior.** `processTextPrompt.ts:59-64` (the two matchers) +
`userPromptKeywords.ts` keyword lists.

**Target Zig files.** New module `src/core/prompt_keywords.zig` (registered in
`src/main.zig`) or extend `src/agent_history.zig` (where `isShortFollowUp` lives at
line 1396). Telemetry via the existing audit-log path.

**Approach.**
1. `matchesKeepGoingKeyword(input) bool` (continue / keep going / go on / proceed /
   carry on) and `matchesNegativeKeyword(input) bool` (no / stop / cancel / don't /
   nope / nah / nevermind), matching the reference's keyword lists.
2. Emit `is_negative` / `is_keep_going` as attributes on the existing per-prompt
   telemetry record (respecting the analytics-10 allowlist from 16.19).

**Acceptance criteria.** Tests: keyword lists classify representative inputs both
ways; a neutral prompt classifies as neither.

**Test strategy.** Unit tests of the two pure matchers.

**Risk / footguns.** Do not regress the existing `isShortFollowUp` routing
(agent_runtime.zig:737); this adds a parallel telemetry signal, it does not replace
the router.

**Size.** S.

---

### 16.31 Generic directory/path completion (misc-utils-17)

**Goal.** `getPathCompletions` / `isPathLikeToken`: parse a partial path into
dir+prefix, scan the dir (cached), filter by prefix, dirs-first sort.

**Reference behavior.** `directoryCompletion.ts:55-263` (`parsePartialPath`,
`scanDirectory` with 5-min LRU, `getDirectoryCompletions`, `getPathCompletions`,
`isPathLikeToken` detecting `~/`, `/`, `./`, `../`).

**Target Zig files.** New module `src/core/path_completion.zig` (registered in
`src/main.zig`). Reuse `core/autocomplete.zig` `rank` (line 39) for scoring.

**Approach.**
1. `isPathLikeToken(token) bool`: starts with `~/`, `/`, `./`, `../`.
2. `parsePartialPath(token) { dir, prefix }`: split at the last `/`; expand a leading
   `~`.
3. `scanDirectory(allocator, dir) []Entry` with a small time-keyed cache
   (`clock.nowMillis`, 5-min TTL); each entry carries `is_dir`.
4. `getPathCompletions(allocator, token) []Suggestion`: filter scanned entries by
   prefix, sort dirs-first then by `rank`.

**Acceptance criteria.** Tests against a tmp dir: `./` lists its entries dirs-first;
a prefix filters; `isPathLikeToken` accepts `~/`, `./`, `/abs`, rejects `word`.

**Test strategy.** Unit tests against `tmpDirPath` (never `"."`).

**Risk / footguns.** Cache invalidation by TTL only (the reference uses 5-min);
bound the cache size. The REPL dropdown integration beyond `@`-mentions is a separate
UI task -- this delivers the reusable completion engine; the existing `@`-mention
context detection stays as-is.

**Size.** M.

---

### 16.32 Deferred items (documented, not built)

The following are explicitly **deferred** in this phase, with rationale recorded so a
future phase can pick them up without re-litigating scope:

- **vim-keys-13 (keybindings hot-reload watcher).** L. Our on-demand load + manual
  `/reload` (`repl.zig:7447`) is an adequate analog. A real fs watcher
  (kqueue/FSEvents/inotify) with awaitWriteFinish debounce is a sizable infra add for
  low user value.
- **misc-utils-07 (`--handle-uri` + headless terminal launch).** L. The URI-routing
  core lands as the parser (16.25); the terminal-launch + macOS Apple-Event glue is
  heavy platform code.
- **misc-utils-08 (OS protocol-handler registration).** L. Only meaningful once
  16.07 is built. Out of scope per survey.
- **misc-utils-10 (terminal preference capture).** M. Only useful alongside the
  deferred headless launcher.
- **misc-utils-16 (shell-history ghost-text for `!`).** M. Depends on a `!` bash-input
  mode (misc-utils-13, not in this phase) and a persisted input-history store.
- **misc-utils-20 (versioned native installer).** L. Deliberate architectural
  divergence: our in-place updater (`update.zig`) does checksum + Sigstore cosign
  verification + egress-guarded download + version pinning, which is arguably stronger
  on supply-chain than the reference's versioned-dir + symlink + PID-lock model.
  Flagged `present_different`, not a defect.

No code changes; this section is the contract that these are intentional.

---

## Verification

Build and install per CLAUDE.md after the changes land:

```
/Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build -Doptimize=ReleaseFast
rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode
```

(`rm -f` first to avoid the macOS in-place-overwrite code-signature invalidation
that SIGKILLs the next run.)

Run the full test suite under the custom runner:

```
/Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build test
```

All new `test` blocks must pass. New modules
(`core/model_usage.zig`, `core/git_ref.zig`, `core/git_config.zig`, `core/git_fs.zig`,
`core/gitignore.zig`, `core/deep_link.zig`, `core/otel_export.zig`,
`core/prompt_keywords.zig`, `core/path_completion.zig`) MUST be registered in the
`src/main.zig` comptime block or their tests will not be discovered (the
test-discovery rule).

Manual checks:

- **Vim.** With vim mode on, verify in the REPL: `W`/`B`/`E`, `~`, `J`, `Y`, `>>`/`<<`,
  `dG`/`dgg`, `dj`/`dk`, and that `cw` on `hello world` leaves ` world`. Confirm `.`
  repeats each new command.
- **Cost.** Run a turn against an Anthropic model with prompt caching enabled and run
  `/cost`; confirm the "Usage by model" block shows cache read/write columns and that
  an unknown model shows the inaccuracy caveat. Run a session, exit, `/resume` it, and
  confirm `/cost` reflects the prior totals.
- **Keybindings.** Add a binding with an unknown context and a duplicate key to
  `~/.claude/keybindings.json`; run `/doctor` and confirm the structured warnings
  appear. On macOS, bind `cmd+c` and confirm the reserved-conflict warning.
- **Telemetry.** Set `OTEL_EXPORTER_OTLP_ENDPOINT` to a local collector with
  `cloud_telemetry_opt_in=true` and confirm metrics are pushed; confirm
  `tool_executions_total` / `rate_limit_rejections` / `circuit_breaker_state` appear
  in `/otel` after activity.
- **Git utilities.** In a repo, confirm the direct `.git` branch read matches
  `git rev-parse --abbrev-ref HEAD`; confirm `gh auth` status in `/doctor`; confirm a
  `claude-cli://open?q=...` URI parses (unit-level, since the launcher is deferred).

## Out-of-scope / deferred notes

- All items listed in task 16.32 are deferred with rationale.
- The reference's React-render-driven caches (GitFileWatcher, keychain 30s TTL +
  read-dedup) are NOT ported -- they optimize a per-frame render model that zcode's
  read-once-at-startup CLI does not have.
- The plaintext `.credentials.json` format is NOT ported; zcode keeps its encrypted
  ChaCha20-Poly1305 file fallback (stronger). Only the delete-stale-primary migration
  ordering is ported (16.27).
- `gj`/`gk` are treated as logical j/k because our renderer does not soft-wrap
  display lines distinctly; this is documented in code, not a silent drop.
- Cache pricing multipliers (10% read / 1.25x write) are Anthropic-specific and gated
  to that provider; OpenAI-compatible models fall back to the input rate.
- Cost is estimated from token counts (zcode prices locally), not read from a
  server-provided `cost` field -- acceptable per the survey for local providers and
  consistent with the existing `estimateCost` design.
