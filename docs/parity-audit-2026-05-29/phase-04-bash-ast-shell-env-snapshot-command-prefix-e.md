# Phase 4: Bash AST, shell env snapshot, command-prefix extraction, per-segment permission eval, output/sandbox params

## Overview

This phase deepens zcode's bash/shell tooling to close the structural-analysis and
permission-suggestion gaps with the reference Claude Code. The reference parses every bash
command with a tree-sitter grammar to drive quote-context, compound-structure, and
dangerous-pattern analysis, then layers per-segment permission evaluation, command-prefix
extraction (to suggest reusable allow-rules), destructive-command advisories, a sourced shell
environment snapshot, configurable output caps, cwd-reset, a `dangerouslyDisableSandbox`
tool parameter, and a `!`-prefixed bash input fast-path.

zcode already has a solid native baseline: a quote-aware `SegmentIterator` (splits on
`| || && ;` respecting quotes/escapes), process-substitution hard-blocking, banned-command
redirection, destructive-pattern detection that elevates risk, a structured `[shell_result]`
JSON contract, persisted-output spilling, background-task tracking, a persistent `shell_cwd`,
and a glob-aware permission rule store. The work here is to add the missing *structured*
layer on top of that baseline without pulling in a tree-sitter dependency (we build a small
native bash structural analyzer instead) and to wire the analysis through the approval flow.

**What:** Native bash structural analyzer (subshell/command-group/heredoc/operator-node
detection + quote-context spans), shell environment snapshot (source .zshrc/.bashrc, capture
functions/aliases/options + PATH), static command-prefix extraction with LCP collapsing, per-
segment permission evaluation with multi-cd and cd+git guards, destructive-command advisory
notes in the approval dialog, configurable `BASH_MAX_OUTPUT_LENGTH` with line-count
truncation, cwd-reset-outside-project, the `dangerouslyDisableSandbox` model-facing param, and
the `!`-prefix bash input mode with `<bash-input>`/`<bash-stdout>` framing. Shell tab-
completion (compgen/zsh) is included as a lower-priority interactive-UX task.

**Why:** These are the highest-value bash/shell parity gaps. The structural analyzer unblocks
several downstream checks (cd+git bare-repo attack, unsafe-compound ask, find -exec false-
positive avoidance). The command-prefix extraction turns "deny this command" into "allow
`git status` going forward," which is the missing half of zcode's permission UX. The shell
snapshot makes the model's bash commands see the user's aliases/functions, a direct functional
gap users hit today.

**Dependencies:** Phase 2 (permission rule engine deepening / approval flow plumbing). This
phase consumes the rule store (`core/permission_rules.zig`) and the approval path in
`agent_tools.zig` that Phase 2 hardens.

**Effort:** XL (10 tasks; one L analyzer, two L subsystems, several M, two S).

## Gaps covered

| id | title | severity | size | our current state |
|---|---|---|---|---|
| bash-shell-01 | Bash AST parser (quote context, compound structure, dangerous patterns) | medium | L | Partial. Quote-aware `SegmentIterator` + word tokenizer + process-substitution/param-expansion detection. No subshell/command-group/heredoc/operator-node structural detection; no quote-context spans. |
| bash-shell-02 | Shell environment snapshot (functions/options/aliases + PATH) | medium | L | Missing. `/bin/sh -c` deliberately avoids profile sourcing; only `/env set` vars applied. No snapshot mechanism. |
| bash-shell-03 | Command-prefix extraction for permission rule suggestions | medium | L | Missing. Rule store matches as-is; approval flow never suggests a reusable prefix rule. |
| bash-shell-04 | Per-segment compound-command permission eval + multi-cd + cd+git guards | medium | M | Partial. Per-segment *security* checks exist; per-segment *permission* aggregation, multi-cd count, and cd+git guard absent. |
| bash-shell-05 | Destructive-command informational warnings in approval dialog | low | S | Partial. Destructive patterns elevate risk but reason strings are dropped (bool-only `isDestructive`); narrower pattern set; no advisory note in dialog. |
| bash-shell-06 | Shell tab-completion (compgen / zsh) for the input box | low | M | Partial. PATH-scan binary suggestions only; no input-context parsing, compgen, file/variable completion, 1s timeout. |
| bash-shell-08 | NUL-redirect rewrite + stdin-redirect / heredoc-aware quoting | low | M | Missing. No NUL rewrite, no `containsHeredoc`, no auto `< /dev/null` insertion. (NUL rewrite is Windows-only, deferred; heredoc detection + stdin-close are in-scope.) |
| bash-shell-10 | Configurable bash output cap via BASH_MAX_OUTPUT_LENGTH with line-count truncation | low | S | Missing. Hardcoded 256 KiB byte cap; no env knob, no `[N lines truncated]` message, no image data-URI handling. |
| bash-shell-12 | cwd-reset-when-outside-project after a bash command changes directory | low | M | Partial. Persistent `shell_cwd` + `updateShellCwd` exist; no project-boundary detection, no reset, no stderr note. |
| tools-13 | Bash tool: model-facing `dangerouslyDisableSandbox` param | low | M | Partial. Rich structured output present; `dangerouslyDisableSandbox` not a per-call schema param (sandbox set at session level only). |
| misc-utils-13 | Bash input mode (`!` prefix) with synthetic caveat + `<bash-input>`/`<bash-stdout>` framing | medium | M | Partial. `/! <cmd>` slash command exists (local-only); no bare `!` prefix, no synthetic-caveat framing into the transcript. |

> Note on severity downgrades verified during this audit: bash-shell-01's security impact is
> reduced because zcode *hard-blocks* process substitution (`bash_security.zig:260`) rather than
> analyzing it; the analyzer here is primarily to unblock cd+git and unsafe-compound asks, not to
> replace a permissive analysis. bash-shell-07 (PowerShell, Windows-only) and the Windows half of
> bash-shell-08 (NUL rewrite) are out of scope for this phase (see Out-of-scope).

## Implementation tasks

### Task 1: Native bash structural analyzer (bash-shell-01)

**Goal:** Add a native, allocation-light bash structural analyzer that detects subshells,
command groups, heredocs, real operator nodes, and quote-context spans, so downstream
permission checks can ask the right questions without a tree-sitter dependency.

**Reference behavior + file:line:**
- `src/utils/bash/treeSitterAnalysis.ts:296-411` (`extractCompoundStructure`: `hasPipeline`,
  `hasSubshell`, `hasCommandGroup`, `operators`, `segments`).
- `src/utils/bash/treeSitterAnalysis.ts:421-443` (`hasActualOperatorNodes`: the `find -exec \;`
  false-positive eliminator -- a real `;` operator node vs. a `\;` word argument).
- `src/utils/bash/treeSitterAnalysis.ts:448-489` (`extractDangerousPatterns`: command/process
  substitution, parameter expansion, heredoc, comment).
- `src/utils/bash/treeSitterAnalysis.ts:21-28, 224-290` (`QuoteContext`: `withDoubleQuotes`,
  `fullyUnquoted`, `unquotedKeepQuoteChars` span variants).
- `src/utils/bash/ParsedCommand.ts:181-233` (`getPipeSegments` / `withoutOutputRedirections`).

**Target Zig files:**
- Create `src/core/bash_ast.zig` (new deep module; pure over `(command: []const u8)`, no IO).
  Expose `pub const CompoundStructure`, `pub const DangerousPatterns`, `pub const QuoteContext`,
  `pub const Analysis` and `pub fn analyze(allocator, command) !Analysis`. Also expose a non-
  allocating `pub fn hasActualOperatorNodes(command) bool` and `pub fn structure(command) ...`
  flags that callers can use without owning an allocation when they only need booleans.
- Register in `src/main.zig` comptime block: add `_ = @import("core/bash_ast.zig");` next to the
  other `core/` entries (around line 93-103) per the test-discovery rule.
- Reuse `src/tools/bash_security.zig`'s `SegmentIterator` style for the operator scan, but the
  new module must be self-contained (do not create a cross-import cycle: `bash_security.zig`
  may later import `bash_ast.zig`, never the reverse).

**Approach (step by step):**
1. Write a single forward scan with explicit state: `in_single`, `in_double`, `in_ansi_c`
   (`$'...'`), `escaped`, plus a small depth stack tracking `(` (subshell), `{` command group
   (only when `{` is at a command-word boundary followed by space/newline -- bash requires
   `{ cmd; }`), and `$( ` / backtick (command substitution), `<(`/`>(` (process substitution),
   `${` (parameter expansion). Record byte spans for each quote run.
2. `hasActualOperatorNodes`: while scanning at top level (depth 0, not in any quote), set true
   when an unescaped `;`, `&&`, or `||` appears that is NOT immediately preceded by a `\`
   inside a word. Critically, treat `\;` as a word char (the `find -exec \;` case): when the
   `;` is preceded by an odd run of backslashes, do not count it. Add a regression test:
   `find . -name '*.zig' -exec wc -l {} \;` -> `hasActualOperatorNodes == false`,
   `ls; rm x` -> `true`.
3. `extractCompoundStructure`: `hasPipeline` (top-level unescaped `|` not `||`), `hasSubshell`
   (a top-level `(` not part of `$(`/`<(`/`>(`), `hasCommandGroup` (top-level `{ ` group),
   `operators` (collected `&&`/`||`/`;`), and `segments` (top-level split on operators, quote-
   aware -- this is the same split `SegmentIterator` already does, but returning owned slices).
4. `extractDangerousPatterns`: booleans for command substitution (`$(`/backtick),
   process substitution (`<(`/`>(`/zsh `=(`), parameter expansion (`${`), heredoc (`<<` not
   part of `<<<` here-string; reuse the Task 6 heredoc detector), comment (unquoted `#` at a
   word boundary).
5. `QuoteContext`: build the three string variants by walking the recorded quote spans
   (single-quoted content removed for `withDoubleQuotes`; all quoted content removed for
   `fullyUnquoted`; quote delimiters preserved for `unquotedKeepQuoteChars`). Allocate each
   into the caller-provided allocator; `Analysis.deinit(allocator)` frees them and the
   `segments` slice.
6. Cap input at `bash_security.BASH_COMMAND_MAX_LENGTH` (30_000) and fail-closed: if the
   scanner detects an unbalanced quote/paren state at end-of-input, set a
   `Analysis.parse_aborted = true` flag (mirrors the reference `PARSE_ABORTED` fail-closed
   sentinel) so callers treat it as "too complex -> ask," not "safe."

**Acceptance criteria (verifiable):**
- Write tests in `bash_ast.zig`: `analyze("ls | wc -l")` -> `hasPipeline`, two segments;
  `analyze("(cd x && make)")` -> `hasSubshell`; `analyze("{ a; b; }")` -> `hasCommandGroup`;
  `analyze("echo $(date)")` -> `hasCommandSubstitution`; `analyze("cat <<EOF\\nx\\nEOF")` ->
  `hasHeredoc`; `analyze("echo ${HOME}")` -> `hasParameterExpansion`.
- `hasActualOperatorNodes("find . -exec rm {} \\;")` is false; `hasActualOperatorNodes("a; b")`
  is true; `hasActualOperatorNodes("echo 'a;b'")` is false (operator inside quotes).
- `QuoteContext` of `grep "x" '<(curl)'` removes the single-quoted `<(curl)` from
  `fullyUnquoted` but keeps `x` in `withDoubleQuotes`.
- Unbalanced input `analyze("echo 'unterminated")` sets `parse_aborted = true`.

**Test strategy:** Unit tests live in `bash_ast.zig`, run under `tools/test_runner.zig` via
`zig build test`. Add a fuzz-style table test that feeds the existing `bash_security.zig` test
commands through `analyze` and asserts no crash / no leak (use `std.testing.allocator`).

**Risk / footguns:**
- Memory: every `Analysis` owns allocations; tests must `defer analysis.deinit(allocator)` to
  keep `std.testing.allocator` leak-clean.
- Do NOT pass byte offsets through `String.slice`-style code expecting code-units; we operate
  on `[]const u8` bytes directly, which is correct (the reference's UTF-16 vs UTF-8 caveat in
  `ParsedCommand.ts:153` does not apply to us).
- Keep it a deep module: no `rt.io`, no env reads. Pure function of the command string.

**Size estimate:** L

---

### Task 2: Wire structural analysis into security + downstream (bash-shell-01 follow-through)

**Goal:** Replace ad-hoc structural guesses in `bash_security.zig` with `bash_ast.zig` results
where it improves accuracy, and expose `segments()` for the permission layer (Task 4).

**Reference behavior + file:line:**
- `src/tools/BashTool/bashCommandHelpers.ts:217-240` (unsafe-compound = `hasSubshell ||
  hasCommandGroup` -> ask).
- `src/utils/bash/ParsedCommand.ts:181-209` (pipe segments used by the permission layer).

**Target Zig files:**
- `src/tools/bash_security.zig`: add `pub fn segments(allocator, command) ![][]const u8` that
  delegates to `bash_ast.analyze(...).structure.segments` (owned), and `pub fn
  isUnsafeCompound(command) bool` returning `hasSubshell or hasCommandGroup`. Keep the existing
  `SegmentIterator` for the cheap in-module scans (interactive/banned) to avoid allocation on
  the hot path; only the permission layer needs owned segments.
- `src/tools/shell.zig`: no behavioral change required, but add `parse_aborted` handling -- if
  `bash_ast.analyze` reports `parse_aborted`, surface it through the security result as a
  `.medium` risk "command too complex to analyze; requires approval" rather than running
  unanalyzed.

**Approach:**
1. Add `bash_ast` import to `bash_security.zig`.
2. Implement `segments` and `isUnsafeCompound` thin wrappers.
3. In `analyzeCommand`, after the existing checks, add a final guard: if
   `bash_ast.analyze` returns `parse_aborted`, return `.{ .safe = false, .risk_level =
   .medium, .kind = .risky, .reason = "command structure could not be parsed; re-run a simpler form or split it" }`.

**Acceptance criteria:**
- `bash_security.isUnsafeCompound("(rm -rf x)")` is true; `isUnsafeCompound("ls | wc")` is
  false. Test in `bash_security.zig`.
- `bash_security.segments("a && b | c")` returns `["a", "b | c"]` (operator split, pipe stays
  in the segment -- matches the reference where `&&`/`||`/`;` are the segment boundaries and
  pipes are handled separately by `getPipeSegments`). Verify with a test; free the result.

**Test strategy:** New tests in `bash_security.zig` run under `tools/test_runner.zig`.

**Risk / footguns:**
- Avoid an import cycle: `bash_ast.zig` must not import `bash_security.zig`.
- `segments` allocates; document ownership and free in tests.

**Size estimate:** M

---

### Task 3: Static command-prefix extraction (bash-shell-03)

**Goal:** Compute a stable, reusable command prefix from a concrete command (e.g.
`git -C /repo status --short` -> `git status`) so the approval flow can suggest an allow-rule.
Use a native static heuristic (first word + known-subcommand depth), not an LLM extractor and
not the external fig-spec dependency.

**Reference behavior + file:line:**
- `src/utils/shell/specPrefix.ts:88-209` (`buildPrefix`/`calculateDepth`: walk args, skip flags
  and their values, find the first known subcommand, apply `DEPTH_RULES`).
- `src/utils/shell/specPrefix.ts:21-34` (`DEPTH_RULES`: per-command depth overrides, e.g.
  `kubectl: 3`, `docker: 3`, `git push: 2`).
- `src/utils/shell/prefix.ts:28-44` (`DANGEROUS_SHELL_PREFIXES`: never accept bare `sh`, `bash`,
  `zsh`, ..., or bare `git`).
- `src/utils/bash/prefix.ts:135-204` (`getCompoundCommandPrefixesStatic`: per-subcommand
  prefixes collapsed via word-aligned longest common prefix).

**Target Zig files:**
- Create `src/core/command_prefix.zig` (new deep module; pure). Expose
  `pub fn extract(allocator, command) !?[]u8` (single command -> owned prefix or null) and
  `pub fn extractCompound(allocator, command) ![][]u8` (compound -> collapsed prefixes).
- Register in `src/main.zig` comptime block.
- Reuse `core/command_semantics.zig:extractBaseCommand` for the first-word extraction and
  `bash_security.zig`'s shell-word tokenizer concepts (re-implement locally to stay pure; do
  not import `bash_security`).

**Approach:**
1. Define `DANGEROUS_SHELL_PREFIXES` and a small native `KNOWN_SUBCOMMANDS` table for the
   common multi-word CLIs that the reference depends on fig-spec for: `git` (status, log, diff,
   show, fetch, push, pull, commit, add, checkout, branch, ...), `npm`/`pnpm`/`yarn` (run,
   install, ...), `cargo`, `docker` (run, build, ps, ...), `kubectl` (get, describe, ...),
   `zig` (build, test, fmt, ...). Plus a `DEPTH_RULES` map mirroring `specPrefix.ts:21-34`.
2. Tokenize the command into words (quote-aware). Drop leading env-assignments
   (`FOO=bar cmd`) and strip wrapper commands (`sudo`/`time`/`nice`/`env`) -- reuse the
   `commandWordAfterWrappers` logic pattern.
3. `extract`: if the resolved command word is in `DANGEROUS_SHELL_PREFIXES`, return null. Walk
   args: skip flags (and their values per a small "flag takes arg" heuristic: a non-flag
   following a known value-taking flag), find the first arg that matches a known subcommand for
   that command; build `command subcommand` up to the depth from `DEPTH_RULES` (default 2 for
   commands with a known subcommand, else 1 for the bare command). Never return a bare `git`.
   Validate the result is an actual prefix of the trimmed command (reference guard
   `prefix.ts:303`).
4. `extractCompound`: split on operators via `bash_ast.segments` (Task 1), extract a prefix per
   segment, group by first word, collapse each group via word-aligned LCP
   (port `longestCommonPrefix`, `prefix.ts:182-204`).

**Acceptance criteria (write tests, make them pass):**
- `extract("git -C /repo status --short")` -> `"git status"`.
- `extract("git status")` -> `"git status"`; `extract("git")` -> null (bare git rejected).
- `extract("bash -c 'rm -rf /'")` -> null (dangerous shell prefix).
- `extract("npm run test")` -> `"npm run test"` (depth allows run + script? -> port the
  reference's `npm run <script>` behavior: collapse to `npm run`).
- `extractCompound("git fetch && git worktree list")` -> `["git"]` (LCP collapse).
- `extractCompound("npm run test && npm run lint")` -> `["npm run"]`.

**Test strategy:** Unit tests in `command_prefix.zig`, run under `tools/test_runner.zig`. Mirror
the reference's `bash/prefix.test.ts` table cases for git/npm/docker/kubectl.

**Risk / footguns:**
- Keep the subcommand table small and documented; do not try to replicate the entire fig-spec.
  The acceptance bar is "suggests a useful, never-overbroad prefix," not byte-parity.
- Owned-slice ownership: `extractCompound` returns a slice of owned slices; provide a
  `freeCompound(allocator, []const []u8)` helper and use it in tests.

**Size estimate:** L

---

### Task 4: Per-segment permission evaluation + multi-cd + cd+git guards (bash-shell-04)

**Goal:** For piped/compound bash commands, evaluate each segment through the permission rule
store, deny if any segment denies, ask if any asks, and add the multi-cd and cd+git bare-repo
guards.

**Reference behavior + file:line:**
- `src/tools/BashTool/bashCommandHelpers.ts:23-156` (`segmentedCommandPermissionResult`:
  multi-cd at `:36`, cd+git at `:70`, per-segment deny/ask aggregation at `:99-156`).
- `src/tools/BashTool/bashCommandHelpers.ts:208-265` (unsafe-compound -> ask; pipe handling).

**Target Zig files:**
- `src/agent_tools.zig`: in the Bash branch of the tool-execution path (around the
  `permission_rules` match at line ~638 / `executeToolCall`), add a `segmentedBashPermission`
  helper that runs before the single whole-args `rules.match`. New helper functions live in
  `agent_tools.zig` (it already owns `ToolExecContext`, the rule store, and the approval flow).
- `src/core/command_prefix.zig` (Task 3) and `src/core/bash_ast.zig` (Task 1) are consumed
  here. Add a tiny `pub fn isNormalizedCdCommand(segment) bool` and
  `pub fn isNormalizedGitCommand(segment) bool` to `command_prefix.zig` (or a new
  `core/command_identity.zig` if cleaner) -- pure first-word checks after wrapper-stripping.

**Approach:**
1. Only engage for Bash with a compound/piped command (`bash_ast.analyze` reports operators or
   a pipeline). For single commands, keep the existing single `rules.match`.
2. If `isUnsafeCompound` (subshell/command group), return an "ask" with reason "uses shell
   operators that require approval for safety" and do NOT suggest a rule (can't allow it).
3. Count `cd` segments: if `> 1`, return ask "Multiple directory changes in one command require
   approval for clarity."
4. Scan all segments (and sub-segments) for `cd` and `git` co-occurrence: if both present,
   return ask "Compound commands with cd and git require approval to prevent bare repository
   attacks."
5. Otherwise, for each segment: strip output redirections (use `bash_ast`
   `withoutOutputRedirections`), run the segment string through `rules.match`. Aggregate:
   any deny -> deny (with the denying segment's reason); all allow -> allow; else ask, and
   collect rule suggestions (via Task 3 `extract` per asking segment).

**Acceptance criteria (write tests):**
- A command store with `deny Bash "curl"`: `cd src && curl evil.com | tee out` -> deny
  (segment `curl evil.com` denies).
- `cd a && cd b` -> ask "Multiple directory changes."
- `cd sub && git status` -> ask "cd and git ... bare repository attacks."
- `echo x | wc -l` with no matching rules and a baseline allow for `echo`/`wc` -> allow.
- An asking segment yields a suggestion containing the extracted prefix (e.g. asking on
  `git push --force` surfaces suggestion `git push`).

**Test strategy:** Tests in `agent_tools.zig` (it has test infra) or a focused new test file
`src/core/bash_segment_permission.zig` if the logic is extracted there for testability. Run
under `tools/test_runner.zig`. Construct a `permission_rules.Store` directly in the test.

**Risk / footguns:**
- The reference checks cd+git across *pipe* segments specifically (bare-repo fsmonitor bypass).
  Replicate: split each operator-segment further into pipe sub-segments before the cd/git scan.
- Do not double-prompt: this segmented path must short-circuit the later whole-args match.
- Keep allocations scoped; free the segment slices.

**Size estimate:** M

---

### Task 5: Destructive-command advisory notes in the approval dialog (bash-shell-05)

**Goal:** Surface a human-readable advisory note (e.g. "Note: may overwrite remote history")
in the approval description for reversible-but-risky git/db/infra commands, without changing
auto-approval logic.

**Reference behavior + file:line:**
- `src/tools/BashTool/destructiveCommandWarning.ts:12-102` (`DESTRUCTIVE_PATTERNS`,
  `getDestructiveCommandWarning`: git reset --hard, push --force/-f, clean -f, checkout/restore
  ., stash drop/clear, branch -D, --no-verify, commit --amend, rm -rf/-f, DROP/TRUNCATE/DELETE
  FROM, kubectl delete, terraform destroy).

**Target Zig files:**
- Create `src/core/destructive_warning.zig` (new deep module; pure). Expose
  `pub fn warning(command) ?[]const u8` returning a rodata advisory string or null. Port the
  pattern list; use simple substring/word-boundary checks (no regex engine -- match the
  reference's intent with `containsIgnoreCase` + a small word-boundary helper from
  `core/parse_helpers.zig`).
- Register in `src/main.zig` comptime block.
- `src/agent_tools.zig`: in `buildApprovalDescription` (line 406-410), append the advisory
  note when `name` is `Bash`/`shell` and `destructive_warning.warning(command)` is non-null.
  Extract the command from `args` via `tools/arg_parse.zig:getArg(args, "command")`.

**Approach:**
1. Implement `warning` with the curated pattern set. Each entry is `{ needle, note }`. For
   patterns that need a flag near the verb (e.g. `git push ... --force`), check both the verb
   substring and the flag substring co-occur in the same command (good enough; the reference's
   regex is more precise but this matches the advisory intent).
2. In `buildApprovalDescription`, after the existing `"{name} [{risk}]: {summary}"` line,
   conditionally append `"\nNote: ..."`. Keep the existing 256-byte summary buffer in mind --
   widen the output buffer at the call site if needed (the function takes `out: []u8`).

**Acceptance criteria (write tests):**
- `warning("git push --force origin main")` -> note containing "remote history".
- `warning("git reset --hard HEAD~3")` -> note containing "uncommitted changes".
- `warning("kubectl delete pod x")` -> note containing "Kubernetes".
- `warning("ls -la")` -> null.
- Integration: `buildApprovalDescription` for a `Bash` call with `git push --force` includes
  the note; a plain `ls` does not.

**Test strategy:** Unit tests in `destructive_warning.zig`; one integration assertion in
`agent_tools.zig` tests. Run under `tools/test_runner.zig`.

**Risk / footguns:**
- This is advisory only -- it must NOT change risk tier or auto-approval. Do not route it
  through `policy.zig` risk elevation (that path already exists separately).
- No em/en dashes in the note strings (use plain hyphens) per project rules.

**Size estimate:** S

---

### Task 6: Heredoc detection + stdin-close insertion (bash-shell-08, in-scope half)

**Goal:** Add `containsHeredoc` detection (consumed by Task 1's dangerous-pattern check) and
ensure non-interactive bash commands do not hang waiting for stdin by closing stdin (the
general-purpose half of the reference's `shouldAddStdinRedirect`). The Windows NUL-redirect
rewrite is deferred (Out-of-scope).

**Reference behavior + file:line:**
- `src/utils/bash/heredoc.ts:69-71, 731-733` (`HEREDOC_START_PATTERN`, `containsHeredoc`).
- `src/utils/bash/heredoc.ts` (`hasStdinRedirect`/`shouldAddStdinRedirect`: add `< /dev/null`
  only when there's no existing stdin redirect and no heredoc, so `git commit` etc. do not
  block on a TTY).

**Target Zig files:**
- `src/core/bash_ast.zig` (Task 1): add `pub fn containsHeredoc(command) bool` and
  `pub fn hasStdinRedirect(command) bool` (detects an unquoted top-level `<` or `<<`).
- `src/tools/shell.zig`: in `run`, after building the plan and before `std.process.run`, set
  the child's stdin to closed/`/dev/null` when the command has no heredoc and no explicit stdin
  redirect. The current path inherits stdin implicitly via `std.process.run`; set
  `run_opts.stdin = .ignore` (or the 0.16 equivalent) conditionally.

**Approach:**
1. `containsHeredoc`: scan for an unquoted, non-comment `<<` that is not `<<<` (here-string),
   followed by an optional `-` and a delimiter word. Reuse the Task 1 quote/escape scanner.
   This is a detection-only helper -- do NOT port the reference's full heredoc *extraction*
   (placeholder substitution) machinery; that complexity is unnecessary because zcode does not
   split commands for execution, only for analysis.
2. `hasStdinRedirect`: true if a top-level unquoted `<` (single) or `<<` appears.
3. In `shell.zig:run`, compute `close_stdin = !containsHeredoc(command) && !hasStdinRedirect(command)`
   and pass the corresponding `std.process.RunOptions` stdin behavior. Verify the 0.16
   `RunOptions` field name for stdin (`.stdin = .ignore` vs `.close`) by checking the std lib;
   if `std.process.run` does not expose stdin control, document the blocker and fall back to
   prefixing the command with `< /dev/null` for the direct (`/bin/sh -c`) path only (safe
   because we only do it when there is no heredoc/redirect).

**Acceptance criteria (write tests):**
- `containsHeredoc("cat <<EOF\\nhi\\nEOF")` true; `containsHeredoc("echo a <<< b")` false;
  `containsHeredoc("echo '<<EOF'")` false (quoted).
- `hasStdinRedirect("sort < names.txt")` true; `hasStdinRedirect("ls")` false.
- Behavioral: a command like `git commit` (no heredoc/redirect) runs with stdin closed (manual
  verify: it returns instead of hanging). Add a test that asserts the `close_stdin` decision
  boolean for representative commands (unit-test the decision, not the spawn).

**Test strategy:** Unit tests in `bash_ast.zig` for the detectors; a decision-boolean test in
`shell.zig`. Run under `tools/test_runner.zig`.

**Risk / footguns:**
- CLAUDE.md gotcha: `readStreaming(io, ...)` vs pread on pipes -- not directly relevant here,
  but be careful with the 0.16 `std.process.run` stdin option; the API changed. Verify the
  exact field before assuming `.ignore` exists.
- Closing stdin must be conditional: heredocs and explicit `< file` redirects MUST keep their
  stdin. The interactive `/!` path (Task 10) already uses `.inherit` and is unaffected.

**Size estimate:** M

---

### Task 7: Shell environment snapshot (bash-shell-02)

**Goal:** Source the user's `.zshrc`/`.bashrc` once per session, capture functions, aliases,
and shell options into a snapshot `.sh` file under a `shell-snapshots/` directory, and source
that snapshot in every bash command so commands see the user's interactive environment.

**Reference behavior + file:line:**
- `src/utils/bash/ShellSnapshot.ts:413-582` (`createAndSaveSnapshot`: pick config file, run
  `binShell -c -l <script>` with a 10s timeout, write snapshot, register cleanup).
- `src/utils/bash/ShellSnapshot.ts:197-263` (`getUserSnapshotContent`: functions via
  `declare -f`/`typeset -f`, options via `shopt -p`/`setopt`, aliases via `alias`, with
  `unalias -a` + `shopt -s expand_aliases`).
- `src/utils/bash/ShellSnapshot.ts:333-339` (inject resolved `PATH`).

> The ripgrep/bfs/ugrep argv0 shadowing (`ShellSnapshot.ts:35-179`) is bun-internal embedded-
> binary specific and NOT applicable to zcode -- skip it.

**Target Zig files:**
- Create `src/core/shell_snapshot.zig` (new module; uses `rt.io` for file/process IO, so it is
  a thin module, not a pure deep module). Expose `pub fn createForSession(allocator) !?[]u8`
  (returns the snapshot path or null on failure) and `pub fn cleanup(allocator, path) void`.
- Register in `src/main.zig` comptime block.
- `src/agent_runtime.zig`: create the snapshot once at session init (near `shell_cwd` init,
  line ~390), store the optional path on the runtime, and free it on `deinit` (line ~499).
- `src/tools/shell.zig`: when a snapshot path is available, change the direct/sandboxed plans to
  source it: `/bin/sh -c '. <snapshot>; <command>'` (or pass the snapshot path through
  `ToolExecContext`). Keep `-c` (not `-lc`) -- the snapshot replaces login-shell sourcing.

**Approach:**
1. Resolve the user's shell from `$SHELL` (via `core/env.zig`), pick `.zshrc`/`.bashrc`/
   `.profile`. If the config file does not exist, still build a Claude-defaults-only snapshot
   (matches reference fallback).
2. Build the capture script (bash and zsh variants per `getUserSnapshotContent`). Write it to a
   temp file or pass inline. Run `SHELL -c -l <script>` via `std.process.run(allocator, rt.io,
   ...)` with a 10s timeout (`.timeout = .{ .duration = ... }`) and `GIT_EDITOR=true`,
   `CLAUDECODE=1` in the env map.
3. The script writes the snapshot to
   `<config-home>/shell-snapshots/snapshot-<shell>-<ts>-<rand>.sh`. Use `clock.nowMillis()` and
   `rng.bytes()` for the timestamp/random id (per project reuse rules -- do NOT use
   `std.time.*` or `std.crypto.random.*`).
4. On success, return the path; on any failure (timeout, non-zero exit, missing file), return
   null and log a debug note -- zcode must still function without the snapshot.
5. Thread the path into `ToolExecContext` (extend the struct) and into `shell.zig`'s plan
   builders so the command is wrapped with `. <snapshot>;` prefix. The wrap must be quote-safe
   (the snapshot path is our own controlled path; still, shell-quote it).
6. Register cleanup: delete the snapshot file on session deinit.

**Acceptance criteria (write tests + manual):**
- Unit test (`shell_snapshot.zig`, using `test_helpers.tmpDirCwd` for an isolated config home):
  given a fake `.bashrc` defining `alias gs='git status'` and `myfn() { echo hi; }`, the
  generated snapshot file contains an `alias` line for `gs` and a function definition for
  `myfn`, and an `export PATH=...` line.
- Manual: with a real user alias defined in `~/.zshrc`, a Bash tool call to that alias resolves
  (after install per CLAUDE.md). Document the manual check in the PR.
- Snapshot directory is created under the config home; cleanup removes it.

**Test strategy:** Unit test with a tmp config home and a stubbed shell script execution
(prefer `bash` if available on the test machine; gate the live-shell portion behind a
`which bash` check so CI without bash still passes). Run under `tools/test_runner.zig`.

**Risk / footguns:**
- CLAUDE.md 0.16 gotchas: use `std.process.run(allocator, io, opts)` (not the removed
  `Child.init`); `Environ.Map` not `getEnvMap`; `Child.Cwd` is a union `.{ .path = ... }`;
  `Io.Timeout.duration` wraps `Io.Clock.Duration` `{ .raw, .clock }`.
- Do NOT pass `"."` as cwd to the snapshot subprocess; resolve an absolute path.
- The snapshot subprocess sources arbitrary user rc files -- run it WITHOUT the sandbox (it is
  the user's own shell init), but never feed its stdout to the model. Treat capture as best-
  effort and time-bounded.
- Performance: create the snapshot once per session, not per command.

**Size estimate:** L

---

### Task 8: Configurable output cap + line-count truncation (bash-shell-10)

**Goal:** Read `BASH_MAX_OUTPUT_LENGTH` (default 30_000, clamp to 150_000), truncate shell
output by character length, and append a `... [N lines truncated] ...` note with the remaining
line count. Add image data-URI passthrough detection.

**Reference behavior + file:line:**
- `src/utils/shell/outputLimits.ts:3-14` (`getMaxOutputLength`: env read, default 30_000, upper
  150_000).
- `src/tools/BashTool/utils.ts:133-165` (`formatOutput`: char truncate + `[N lines truncated]`).
- `src/tools/BashTool/utils.ts:49-91` (`isImageOutput`/`buildImageToolResult`: data-URI).

**Target Zig files:**
- `src/tools/shell.zig`: replace the hardcoded `max_output_bytes = 256 * 1024` (line 72) and
  the `[output truncated at N bytes]` message (line 123) with an env-driven cap and a line-
  count truncation message. Add a small `fn maxOutputLength() usize` reading
  `BASH_MAX_OUTPUT_LENGTH` via `core/env.zig` (reuse the bounded-int env validation pattern in
  `core/env_validation.zig` if present).
- Image detection: add `fn isImageDataUri(stdout) bool` and, when true, emit a
  `[image_output=true media_type=...]` marker line in the `[shell_result]` contract rather than
  dumping the base64 (the model's tool-result image handling is a larger change; at minimum
  flag it and avoid truncating the base64 mid-payload).

**Approach:**
1. Implement `maxOutputLength()`: parse env, default 30_000, clamp `[1, 150_000]`.
2. Change the stdout/stderr `stdout_limit`/`stderr_limit` to this value (note: the reference
   counts characters; we count bytes -- acceptable, document it).
3. When truncated, replace the byte message with `\n\n... [{remaining} lines truncated] ...`
   where `remaining` = lines in the dropped tail. Count newlines from the truncation offset to
   the end of the captured buffer.
4. Add `output_truncated` (already present) plus a new `truncated_lines` field to the
   `[shell_result]` contract.
5. Image: if `stdout` starts with `data:image/...;base64,`, set a contract flag and skip the
   `[N lines truncated]` math (do not truncate the data URI).

**Acceptance criteria (write tests):**
- `maxOutputLength()` returns 30_000 with no env; 150_000 when env is 999_999 (clamped); a
  custom value when in range. Test by setting the env var in-test (guard non-Windows like the
  existing `setenv` tests in `bash_security.zig`).
- A long synthetic stdout truncates and the output contains `lines truncated`.
- `isImageDataUri("data:image/png;base64,AAAA")` true; `isImageDataUri("hello")` false.

**Test strategy:** Unit tests in `shell.zig` (it already has the output-formatting code). Run
under `tools/test_runner.zig`.

**Risk / footguns:**
- `readFileAlloc(.limited(N))` returns `error.StreamTooLong` (CLAUDE.md gotcha) -- the existing
  `run` already handles `error.StreamTooLong => null`; keep that.
- Do not regress the persisted-output path (32 KiB spill at line 212): the env cap governs the
  model-visible truncation; persistence is a separate threshold. Keep both.
- No em/en dashes in messages.

**Size estimate:** S

---

### Task 9: cwd-reset-when-outside-project (bash-shell-12)

**Goal:** When a bash command `cd`s outside the project's allowed working directories, reset the
persistent `shell_cwd` back to the original project directory and append a "Shell cwd was reset
to ..." note to the tool's stderr output.

**Reference behavior + file:line:**
- `src/tools/BashTool/utils.ts:167-192` (`resetCwdIfOutsideProject`: compare `getCwd()` to
  `getOriginalCwd()`, reset unless `shouldMaintainProjectWorkingDir`).
- `src/tools/BashTool/utils.ts:167-168` (`stdErrAppendShellResetMessage`).

**Target Zig files:**
- `src/agent_runtime.zig`: store `original_cwd` at init (alongside `shell_cwd`, line ~390;
  there is already an `original_auto_approve_high` pattern at line 249). In `updateShellCwd`
  (line 2744), after computing the new cwd, check whether it is within the allowed working
  paths; if not, reset `shell_cwd` to `original_cwd` and set a pending "reset note" flag.
- `src/tools/shell.zig` or the tool-result assembly in `agent_runtime.zig`: when the reset flag
  is set for the just-run command, append `\nShell cwd was reset to <original>` to the stderr
  section of the output.

**Approach:**
1. Add `original_cwd: []u8` to the runtime, dup'd at init, freed at deinit.
2. In `updateShellCwd`, after resolving `new_cwd` and verifying it exists, check
   `pathWithin(new_cwd, original_cwd)` (reuse the `pathWithin` helper concept from
   `permission_rules.zig:286`; consider exposing it `pub`). If outside and no
   "maintain project dir" override (add a `ZCODE_MAINTAIN_PROJECT_CWD` env flag mirroring
   `shouldMaintainProjectWorkingDir`), do NOT update `shell_cwd`; instead keep it at
   `original_cwd` and record a one-shot note.
3. Surface the note: the simplest place is to append it to the Bash tool output after the
   command runs. Thread a `?[]const u8` reset-note from the runtime into the output assembly.

**Acceptance criteria (write tests):**
- After `updateShellCwd` with `cd /tmp` (outside a project rooted at the tmp test dir),
  `shell_cwd` equals `original_cwd` (reset), and a reset note is recorded.
- After `cd <subdir-inside-project>`, `shell_cwd` moves into the subdir and no note is recorded.
- With `ZCODE_MAINTAIN_PROJECT_CWD=1`, every `cd` resets to `original_cwd`.

**Test strategy:** Unit test `updateShellCwd` behavior in `agent_runtime.zig` (construct a
runtime with `test_helpers.tmpDirCwd` as the project root, create a subdir, exercise cd). Run
under `tools/test_runner.zig`.

**Risk / footguns:**
- `updateShellCwd` currently only parses `cd <path>` / `cd <path> &&`. It will not catch cd in
  arbitrary positions; that is acceptable for this task (matches current capability). Do not
  expand cd-parsing scope here -- Task 1's analyzer can improve it in a follow-up.
- The SHELL tool description (`tools/tool_descriptions.zig:14`) claims "working directory
  persists between commands" -- this task makes the persistence honest by bounding it to the
  project. Keep the description accurate.
- Use `test_helpers.tmpDirCwd` (absolute path) -- never `"."` (CLAUDE.md test gotcha).

**Size estimate:** M

---

### Task 10: Bash input mode (`!` prefix) with `<bash-input>`/`<bash-stdout>` framing (misc-utils-13) + `dangerouslyDisableSandbox` param (tools-13)

**Goal:** (a) Add a bare `!`-prefixed REPL input fast-path that runs the command via the Bash
tool with sandbox disabled, streams output, and injects a synthetic
`<bash-input>`/`<bash-stdout>`/`<bash-stderr>` framing into the transcript without querying the
model. (b) Add `dangerouslyDisableSandbox` as a model-facing Bash tool parameter.

**Reference behavior + file:line:**
- `src/utils/processUserInput/processBashCommand.tsx:17-138` (`!`-prefix handling: run BashTool
  with `dangerouslyDisableSandbox`, synthetic caveat, `<bash-input>`/`<bash-stdout>` framing,
  `shouldQuery:false`).
- `src/utils/processUserInput/processUserInput.ts:516-529` (`mode==='bash'` routing).
- `src/tools/BashTool/BashTool.tsx:228-293` (`dangerouslyDisableSandbox` input + outputSchema).

**Target Zig files:**
- `src/cli/repl.zig`: there is already a `/!` slash command (line 7037) that calls
  `runInteractiveShellCommandUi`. Add a bare-`!`-prefix branch in the input dispatch that routes
  `!<cmd>` (without the slash) to the same Bash execution, but instead of only printing,
  append a synthetic transcript entry framed as `<bash-input>...</bash-input>` +
  `<bash-stdout>...</bash-stdout>` + `<bash-stderr>...</bash-stderr>` so the next model turn
  sees the command and its output as context (the reference's synthetic caveat message).
- `src/tools/tool_schemas.zig:139-143`: add `"dangerouslyDisableSandbox":{"type":"boolean"}` to
  the Bash `json_schema` (and the duplicate at line 12 if it is the same Bash entry).
- `src/agent_tools.zig` / `src/agent_runtime.zig`: when the Bash tool args carry
  `dangerouslyDisableSandbox: true`, map it to the `danger-full-access` sandbox profile for
  that single call (the existing `sandbox_profile` plumbing in `shell.zig` already understands
  `danger-full-access`). Gate acceptance on the session not being in a locked-down policy
  (respect enterprise policy: if policy forbids full access, ignore the param and note it).

**Approach:**
1. Schema: extend the Bash `json_schema` string with the boolean param + a description.
2. Param handling: in the Bash dispatch (`agent_runtime.zig` around the shell-call site, or
   `agent_tools.zig` where `sandbox_profile` is chosen), read `dangerouslyDisableSandbox` via
   `arg_parse.getArg`; if true and policy allows, pass `"danger-full-access"` as the profile.
3. `!`-prefix REPL path: detect a line starting with `!` (but not `!!` history if that exists;
   check `repl_input.zig:365` which maps `!` as shift+1 -- ensure the prefix detection is on the
   submitted line, not a keystroke). Strip the `!`, run the command (sandbox disabled, like the
   reference), capture stdout/stderr, and append a synthetic transcript block with the
   `<bash-input>`/`<bash-stdout>`/`<bash-stderr>` tags. Do not start a model query for this
   input (`shouldQuery:false` equivalent -- just record context).

**Acceptance criteria (write tests + manual):**
- Schema test: the Bash tool schema string contains `dangerouslyDisableSandbox`.
- Param test: a Bash call with `dangerouslyDisableSandbox: true` resolves to the
  `danger-full-access` profile (assert via the profile passed into `shell.run`, e.g. a seam
  that returns the chosen profile for a given args string).
- Policy test: when policy forbids full access, the param is ignored and a note is recorded.
- Manual: in the REPL, typing `!echo hi` prints the output and the transcript shows
  `<bash-input>echo hi</bash-input>` + `<bash-stdout>hi</bash-stdout>` (verify after install per
  CLAUDE.md).

**Test strategy:** Schema/param/policy unit tests in `agent_tools.zig`/`tool_schemas.zig`. The
REPL framing is harder to unit-test; add a pure helper `fn buildBashInputFraming(allocator,
input, stdout, stderr) ![]u8` in `repl.zig` (or a small `core/bash_input_framing.zig`) and unit-
test that helper. Run under `tools/test_runner.zig`.

**Risk / footguns:**
- Do not break the existing `/!` slash command -- the bare `!` path is additive.
- `dangerouslyDisableSandbox` is a sharp tool: respect enterprise policy gating. Never let a
  model-supplied flag override an admin lockdown.
- Synthetic transcript injection must be clearly attributed (the reference's "caveat message")
  so the model knows the user ran this, not the agent.

**Size estimate:** M

---

### Task 11 (optional / lower priority): Shell tab-completion (bash-shell-06)

**Goal:** Add input-context-aware shell completion (command vs file vs variable) backed by
`compgen` (bash) / zsh native commands, with a 1s timeout and a 15-suggestion cap, for the
prompt input footer.

**Reference behavior + file:line:**
- `src/utils/bash/shellCompletion.ts:80-137` (`parseInputContext`: command/file/variable).
- `src/utils/bash/shellCompletion.ts:142-179` (`getBashCompletionCommand`/zsh variants:
  `compgen -c/-f/-v`).
- `src/utils/bash/shellCompletion.ts:221-259` (`getShellCompletions`: 1s timeout, 15 cap).

**Target Zig files:**
- `src/repl_commands.zig`: extend the existing `renderPromptSuggestionShellBins`
  (line 3932) into a context-aware completer, or add a sibling
  `renderPromptSuggestionShellCompletions` that parses the input context and shells out to
  `compgen`/zsh with a 1s timeout. Keep the existing PATH-scan as the command-completion
  fallback when the shell is neither bash nor zsh.
- `src/cli/repl.zig:5370`: the existing `__prompt_suggestion_shell_bins` callback hook is the
  integration point.

**Approach:**
1. Parse the input context: variable (`$name`), file (`/`, `~`, `.` prefixes or after the first
   word + space), else command. Reuse a small quote-aware tokenizer.
2. For bash: run `compgen -c/-f/-v <prefix>` via `std.process.run` with a 1s timeout; for zsh:
   the `print -rl ...` equivalents. Cap to 15 results.
3. Fall back to the current PATH-scan for command completion when the shell is unknown.

**Acceptance criteria (write tests + manual):**
- `parseInputContext("$HO", 3)` -> variable, prefix `$HO`; `parseInputContext("ls ./sr", 7)` ->
  file, prefix `./sr`; `parseInputContext("gi", 2)` -> command, prefix `gi`.
- Manual: typing `git ` then a partial filename in the REPL surfaces file completions (verify
  after install).

**Test strategy:** Unit-test the context parser (pure) in `repl_commands.zig`; the live
completion exec is best-effort and gated on `bash`/`zsh` availability. Run under
`tools/test_runner.zig`.

**Risk / footguns:**
- This is interactive UX; keep it strictly best-effort and never block the input loop (1s
  timeout is the upper bound). If it fails, fall back silently to the PATH-scan.
- Lowest priority in the phase -- schedule last; it can ship in a follow-up if time-constrained.

**Size estimate:** M

## Verification

Prove the whole phase is done:

1. **Build (release) and run tests:**
   ```
   /Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build test
   /Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build -Doptimize=ReleaseFast
   ```
   All new tests in `core/bash_ast.zig`, `core/command_prefix.zig`, `core/destructive_warning.zig`,
   `core/shell_snapshot.zig`, and the updated `tools/bash_security.zig`, `tools/shell.zig`,
   `agent_tools.zig`, `agent_runtime.zig` pass under `tools/test_runner.zig`.

2. **Install per CLAUDE.md (fresh inode to preserve the ad-hoc signature):**
   ```
   rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode
   ```
   Also bump `.version` in `build.zig.zon` (patch) before building.

3. **Manual checks (record results in the PR):**
   - Define `alias gs='git status'` in `~/.zshrc`, start zcode, ask the model to run `gs` via
     Bash -> it resolves (Task 7 snapshot).
   - Ask the model to run `git push --force` (or use a throwaway repo) -> the approval dialog
     shows the "Note: may overwrite remote history" advisory (Task 5).
   - Run a compound `cd sub && git status` -> approval is requested with the cd+git bare-repo
     reason (Task 4).
   - In the REPL, type `!echo hello` -> output prints and the transcript shows
     `<bash-input>`/`<bash-stdout>` framing (Task 10).
   - Set `BASH_MAX_OUTPUT_LENGTH=500` and run a command producing >500 chars -> output shows
     `... [N lines truncated] ...` (Task 8).
   - From a project dir, run `cd /tmp` via Bash then another command -> the second runs from the
     project root and the first's output notes "Shell cwd was reset to ..." (Task 9).

4. **Wiki checkpoint:** record the bash structural-analyzer design decision (native scanner over
   tree-sitter dependency) and the snapshot sourcing approach in `wiki/` if present.

## Out-of-scope / deferred notes

- **bash-shell-07 (PowerShell / Windows shell-provider selection):** Windows-only. zcode targets
  macOS/Linux; the bash tool on Windows uses `cmd.exe`. Listed for completeness only; no work in
  this phase.
- **bash-shell-08 Windows NUL-redirect rewrite (`rewriteWindowsNullRedirect`):** Git-Bash-on-
  Windows defense against creating an undeletable Windows-reserved file. Windows-specific;
  deferred. The general-purpose stdin-close half is in Task 6.
- **Tree-sitter native grammar:** We deliberately do NOT add a tree-sitter bash dependency. The
  native `bash_ast.zig` scanner (Task 1) covers the structural questions zcode actually needs
  (subshell/command-group/heredoc/operator-node/quote-context). Full byte-parity with tree-
  sitter's parse tree is a non-goal; the reference itself falls back to regex/shell-quote when
  tree-sitter is unavailable.
- **LLM-driven prefix extraction + fig-spec dependency (bash-shell-03):** We implement the static
  heuristic prefix extractor only (Task 3). The Haiku `createCommandPrefixExtractor` and the
  `@withfig/autocomplete` CommandSpec walk are external/LLM-dependent and out of scope; a small
  native known-subcommand table is the in-scope local equivalent.
- **Full image tool_result blocks (bash-shell-10):** Task 8 detects image data-URI stdout and
  flags it in the structured result + avoids mid-payload truncation, but constructing model-
  facing base64 image tool-result blocks (matplotlib output) is a larger tool-result-shape change
  deferred to a dedicated follow-up.
- **Heredoc extraction/placeholder substitution (bash-shell-08):** Only *detection*
  (`containsHeredoc`) is in scope (Task 6). The reference's full placeholder-substitution
  machinery (`heredoc.ts` extractHeredocs/restoreHeredocs) exists to safely split commands for
  shell-quote; zcode does not split for execution, so that complexity is unnecessary.
