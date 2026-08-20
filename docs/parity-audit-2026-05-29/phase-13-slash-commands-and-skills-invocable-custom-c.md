# Phase 13: Slash commands and skills: invocable custom commands, frontmatter, namespacing, autocomplete, MCP-prompt commands, output styles

## Overview

**What.** This phase closes the parity gap between zcode's slash-command/skill subsystem and the reference Claude Code registry. Today zcode loads custom commands (`core/commands.zig`), skills (`core/skills.zig`, `core/skill_types.zig`), output styles (`core/output_styles.zig`), and plugins (`core/plugins.zig`), but they are second-class:

- Custom commands and skills are reachable only through wrapper verbs (`/command <name>`, `/skill <name>`), never directly as `/<name>` (commands-01).
- The custom-commands loader is flat (no subdirectory namespacing) and parses no frontmatter beyond the first description line, so `argument-hint`, `allowed-tools`, `model`, named arguments, etc. are silently dropped (commands-02, commands-03).
- Slash autocomplete and `/help` do not surface user/custom/skill/plugin commands, do not show argument hints, and rank by nothing (commands-04, commands-05, commands-06, misc-utils-15).
- `/statusline` does not exist (commands-07).
- MCP prompts are model-invocable but absent from `Skill action=list`, the unified slash registry, and autocomplete (commands-10).
- Output styles cannot suppress the base "Doing tasks" coding section (`keep-coding-instructions`), and there is no plugin-provided style source nor `forceForPlugin` auto-override (styles-onboarding-01, styles-onboarding-02).

**Why.** A custom command file `~/.zcode/commands/deploy.md` is the single most common user-authored extension. In the reference it is a first-class slash command (`/deploy`) with full frontmatter behavior. In zcode it is only `/command deploy` and loses its frontmatter. This is the difference between "we have the feature" and "the feature works the way users expect."

**Important corrections to the survey (verified by reading source).** The survey over-reports two items and under-reports infrastructure that already exists:

1. The autocomplete claim that suggestions are "comma-separated names with no metadata" is **stale**. `src/cli/repl.zig:2887 collectCommandSuggestions` already produces `CommandSuggestion{ source, text, primary, secondary }` where `secondary` is a description, and `DynamicCommandSuggestionCache` (repl.zig:1474) already ingests TSV rows `kind\tcommand\tlabel\tdescription` from `__prompt_suggestion_skills` / `__prompt_suggestion_mcp` callbacks. So skills and MCP prompts **already** appear in autocomplete with descriptions. The real remaining deltas for commands-04/05 are: (a) custom commands (`/command` dir) are not fed into the cache, (b) matching is prefix/substring only, (c) no usage-frequency ranking, (d) no `argument-hint` gray text. This is smaller than the survey implies.

2. The frontmatter parser (`core/frontmatter.zig`) and the skill parser (`core/skill_types.zig`) are complete and reused. The commands-02 gap is **localized** to `core/commands.zig` not using them. Skills already parse everything.

3. `styles-onboarding-01` has an **architectural wrinkle the survey misses**: the base "Doing tasks" section lives in `system_prompt.renderStaticPrefix` (the byte-identical cacheable prefix, `core/system_prompt.zig:82`), while the output style is resolved and appended only in `renderDynamicSystemPolicy` (`core/prompt_helpers.zig:122`). The static prefix is deliberately output-style-independent so the prompt-cache key is stable. Gating `doing_tasks_section` on the active style means the static prefix is no longer style-independent. The plan addresses this directly (Task 9).

**Dependencies.** Phase 1 (core module conventions, `zcode_runtime`, test runner) and Phase 6 (commands/skills/plugins loaders + dispatcher already exist). This phase edits and extends those modules; it does not introduce a new subsystem.

**Effort.** L. Nine tasks, two of which (commands-01 dispatcher fallthrough, styles-onboarding-01 prompt gating) are load-bearing and touch hot paths; the rest are localized to single deep modules.

## Gaps covered

| id | title | severity | size | our current state |
|----|-------|----------|------|-------------------|
| commands-01 | Custom commands not invocable as `/<name>` | high | M | Real. Dispatcher (`repl_commands.zig:2255`) returns null with no fallthrough to commands/skills by name. |
| commands-02 | Custom command files: no frontmatter parsing | medium | M | Partial. `frontmatter.zig` + `skill_types.zig` parse everything; `commands.zig` CommandSpec has only name/scope/path/description and passes `&.{}` arg names. |
| commands-03 | No subdirectory namespacing (`namespace:command`) | low | M | Real. `commands.zig:132 appendCommandsFromRoot` skips dirs, name = fileStem only. Skills also lack colon namespacing. |
| commands-04 | Autocomplete static / excludes custom/plugin; no fuzzy/ranking | medium | L | Partial (over-reported). Skills + MCP already in dynamic cache with descriptions. Missing: custom commands, fuzzy match, usage ranking, plugin commands. |
| commands-05 | No `argument-hint` gray text in typeahead | low | M | Real. `CommandSuggestion.secondary` carries description but no separate arg-hint; `generateProgressiveArgumentHint` exists but unwired. |
| commands-06 | `/help` static; omits custom/skill commands | low | M | Partial. `/help` static (`repl_help.zig`); `/skills`,`/commands`,`/plugins` enumerate separately. |
| commands-07 | `/statusline` command missing | low | S | Real. No dispatcher arm; not in stub/removed lists. |
| commands-10 | MCP prompts as unified slash commands + in Skill list | low | M | Partial. `mcpPromptToSkill` + `tryMcpSkillRun` exist; missing from `Skill action=list` and direct `/<promptname>`. |
| misc-utils-15 | Skill usage tracking 7-day half-life ranking | low | S | Real. Skills sorted alphabetically only; no persistent usageCount/lastUsedAt; ephemeral session tracking unused for ranking. |
| styles-onboarding-01 | `keep-coding-instructions` suppress base coding section | high | M | Real. No field, no parse, `renderStaticPrefix` includes `doing_tasks_section` unconditionally. |
| styles-onboarding-02 | Plugin output styles + `forceForPlugin` auto-override | medium | M | Real. `StyleScope` lacks `plugin`; no `force_for_plugin`; no plugin style loader; no forced-style resolution. |

## Implementation tasks

The tasks are ordered to minimize churn. Tasks 2 and 3 extend the data model used by Task 1; Task 1 wires the dispatcher; Tasks 4-6 extend the UI that consumes the model; Tasks 7-8 are independent; Task 9-10 are the output-style pair. **Parallelization note:** Tasks 7 (`/statusline`), 8 (usage ranking), 9 (keep-coding), 10 (plugin styles) are independent of the commands cluster (1-6) and of each other except 9<-10 share `output_styles.zig`. They can be implemented as parallel work items once Tasks 2-3 land.

---

### Task 1 - commands-01: Dispatcher fallthrough resolves `/<name>` against custom commands and skills

**Goal.** Typing `/deploy` runs `~/.zcode/commands/deploy.md`; typing `/<skillname>` runs a user-invocable skill, with no `/command`/`/skill` wrapper needed.

**Reference behavior.** `getCommands(cwd)` merges skill-dir commands and plugin commands into one registry (`src/commands.ts:476-517`); `findCommand(name, commands)` matches by name/alias/derived-name across all of them (`src/commands.ts:688-698`); legacy `/commands/` entries default `user-invocable: true` (`src/skills/loadSkillsDir.ts:562-608`).

**Target Zig files.**
- Edit `src/repl_commands.zig` - add a fallthrough block immediately before the final `return null;` at line 2255 in `replCommandCallback`.
- Read-only deps: `src/core/commands.zig` (`findByName`, `renderRun`, `list`), `src/core/skills.zig` (`findByName`, `renderRun`, `list`).
- No new module; no `src/main.zig` comptime change required (no new file).

**Approach (step by step).**
1. At the start of the fallthrough block, guard: only attempt resolution when `command` starts with `/`, has no space before the first token would not apply (we must support `/deploy arg1 arg2`), and is not one of the reserved wrapper prefixes already handled above.
2. Split `command[1..]` into `leading` (up to first space) and `args` (trimmed remainder). Example: `/deploy src/main.zig` -> name `deploy`, args `src/main.zig`.
3. Resolution order (mirror reference precedence: custom commands, then skills; built-ins already matched above so they win):
   - Try `commands_mod.findByName(allocator, runtime.cwd, leading)`. On success, render via `commands_mod.renderRun(...)` and dispatch through `runtime.handlePromptWithModeAndReporter(prompt, null, .execution)` exactly like the `/command <name>` arm at repl_commands.zig:613-618.
   - Else try `skills_mod.findByName(...)`; if found AND `skill.user_invocable`, render via `skills_mod.renderRun(...)` and dispatch the same way. If found but not user-invocable, return a one-line "skill '<name>' is not user-invocable" message rather than falling through to "unknown command".
4. On `error.CommandNotFound` / null, do nothing and let control reach `return null;` so the existing "unknown command" path in repl.zig:7464-7504 still fires for genuinely unknown commands.
5. Namespaced names (`/frontend:build`) must resolve too - this depends on Task 3 producing colon names from `list()`. Pass `leading` through unchanged; `findByName` does exact match so once Task 3 lands, `frontend:build` matches.

**Acceptance criteria.**
- Write a test in `src/repl_commands.zig` (or a focused test module) that: creates a tmp `.zcode/commands/deploy.md` with body `Deploy {{args}}`, builds a minimal runtime/dispatch harness (follow the existing pattern used by other repl_commands tests, or test the resolution helper directly), and asserts `/deploy staging` resolves and produces a prompt containing `staging`.
- A test asserting an unknown `/zzzznope` still yields `error.CommandNotFound`/null (so the unknown-command UX is preserved).
- A test asserting a non-user-invocable skill returns the "not user-invocable" message, not "unknown command".

**Test strategy.** Unit tests under `tools/test_runner.zig`. Prefer extracting a pure helper `fn resolveCustomOrSkill(allocator, runtime, command) !?[]u8` so it is testable without a full REPL. Use `core/test_helpers.zig` `tmpDirCwd` for the cwd; never pass `"."`.

**Risk / footguns.**
- Ordering: this block MUST be the last resort, after every built-in arm, or it will shadow built-ins that happen to collide with a user file named e.g. `help.md`. Built-ins are matched first by construction (they are above), so this is satisfied as long as the block sits right before `return null;`.
- Do not double-free: `renderRun` returns an owned slice; free it after `handlePromptWithModeAndReporter` consumes it, matching the existing `/command` arm (`defer allocator.free(prompt)` then return the runtime output).
- `findByName` calls `list()` which does disk I/O on every keystroke-independent invocation here (only on submit, so acceptable). Do not call it from the suggestion path without the cache.

**Size estimate.** M.

---

### Task 2 - commands-02: Custom command frontmatter parsing (description / argument-hint / allowed-tools / model / named args / etc.)

**Goal.** A `.zcode/commands/*.md` file with frontmatter binds `description`, `argument-hint`, `allowed-tools`, `model`, `argument` names, `user-invocable`, `disable-model-invocation`, `version`, `context`, `agent`, `paths` - the same set skills already parse.

**Reference behavior.** `parseSkillFrontmatterFields` parses description, allowed-tools, argument-hint, arguments, when_to_use, version, disable-model-invocation, user-invocable, context, agent, shell, effort (`src/skills/loadSkillsDir.ts:181-263`). Legacy `/commands/` entries reuse the same parser with `descriptionFallbackLabel: 'Custom command'` (`loadSkillsDir.ts:593-598`).

**Target Zig files.**
- Edit `src/core/commands.zig` - extend `CommandSpec` (lines 13-24), `appendCommandsFromRoot` (132-161), `findByName` (163-182, clone the new fields), `renderRun` (98-125), `renderDetail` (77-96).
- Reuse `src/core/skill_types.zig` parsing helpers (`parseCommaList`, `parseSpaceList`, `parseBool`, `parseContext`) and `src/core/frontmatter.zig` (`extract`, `getValue`). Prefer importing and calling these rather than re-implementing.

**Approach.**
1. Add fields to `CommandSpec`: `argument_hint: []u8`, `allowed_tools: [][]u8`, `arg_names: [][]u8`, `model: []u8`, `user_invocable: bool`, `disable_model_invocation: bool`, `version: []u8`, `when_to_use: []u8`, `context`, `agent: []u8`, `paths: [][]u8`. Match `SkillSpec` field naming so a future merge into a shared type is cheap. Update `deinit` to free all owned slices/lists (use `skill_types.freeStrList` for the list fields).
2. The cleanest implementation is to **delegate parsing to `skill_types.parse`**: read the file body, call `skill_types.parse(allocator, raw, fileStem, scope_mapped, path)`, then copy the parsed fields into a `CommandSpec`. This avoids duplicating the block-scalar/description-fallback logic. Add a tiny adapter because `CommandScope` (user/workspace) != `SkillScope`; map both to a sentinel skill scope for parsing only.
   - Add `argument_hint` parsing: `frontmatter.getValue(fm, "argument-hint")`. (Skills currently expose `arg_names` but not `argument_hint` as a stored field - add `argument_hint` to the parse path; see Task 5 which needs it. If touching `skill_types.parse`, add the field there too so skills and commands share it.)
3. Replace `readDescription` usage: description now comes from the parsed spec (`descriptionFrom` / first-line fallback), so the bespoke `readDescription` (lines 190-201) can be removed if no other caller uses it (it is file-local). Per the "remove your own orphans" rule, delete it only if it becomes unused.
4. Fix `renderRun` (line 113): pass `command.arg_names` instead of `&.{}` to `arg_sub.substituteArguments(...)` so named `$foo` placeholders bind for custom commands, matching how skills' `renderRun` already works.
5. `renderDetail` (line 91-95): include the new metadata lines (argument-hint, allowed-tools, model, user-invocable) so `/command <name>` detail view matches skill detail.

**Acceptance criteria.**
- Write a test: create `.zcode/commands/review.md` with frontmatter `description`, `argument-hint: <pr-url>`, `allowed-tools: GitDiff, Bash`, `arguments: url mode`, body `Review $url in $mode`. Assert `list()` returns a CommandSpec whose `description`, `argument_hint`, `allowed_tools` (len 2), `arg_names` (len 2) are populated.
- A test that `renderRun("review", "https://x fast")` binds `$url` and `$mode` (named substitution now works because arg_names is threaded).
- Existing `commands.zig` tests (renderRun `{{args}}`, `$ARGUMENTS`, no-placeholder append, empty-args) must still pass unchanged.

**Test strategy.** Unit tests in `core/commands.zig` under the test runner, using `tmpDirCwd`.

**Risk / footguns.**
- `readFileAlloc(.limited(N))` returns `error.StreamTooLong` (not `FileTooBig`) on oversize files - keep the existing 96KB limit and tolerate the error gracefully.
- When delegating to `skill_types.parse`, the returned `prompt` is the frontmatter-stripped body. But `renderRun`/`renderDetail` currently re-read the file and run substitution on the raw body including frontmatter. Decide one source of truth: either store the stripped `prompt` in CommandSpec and substitute on that (preferred - frontmatter should not leak into the model prompt), or keep re-reading. Storing `prompt` is cleaner and matches skills; update `renderRun` to substitute on `command.prompt`.
- Memory: every new field is owned; audit `findByName`'s manual clone (lines 169-179) - switch it to a `clone` helper mirroring `skill_types.clone` to avoid a partial-free bug on error.

**Size estimate.** M.

---

### Task 3 - commands-03: Subdirectory namespacing (`namespace:command`)

**Goal.** `.zcode/commands/frontend/build.md` loads as command `frontend:build`; nested dirs join with `:`. Same for skills.

**Reference behavior.** `buildNamespace` joins relative path segments (below baseDir) with `:`; `getRegularCommandName` = `namespace ? "${namespace}:${base}" : base` (`src/skills/loadSkillsDir.ts:533-552`). Skills use `getSkillCommandName` analogously.

**Target Zig files.**
- Edit `src/core/commands.zig` - make `appendCommandsFromRoot` recurse and compute namespaced names.
- Edit `src/core/skills.zig` `appendFromRoot` (and `skill_listing`/`skill_visibility` if they assume a flat name) - apply the same colon-join.
- Add a small shared helper, e.g. `core/command_namespace.zig` with `fn namespacedName(allocator, base_root, file_path) ![]u8`, register it in `src/main.zig` comptime block (insert `_ = @import("core/command_namespace.zig");` near the other command imports around line 108-110).

**Approach.**
1. `command_namespace.zig`: given `root` and the absolute/relative path of the file, compute the path of segments between `root` and the file's parent dir, join them with `:`, and append the file stem (`build`). For `root/frontend/build.md` -> `frontend:build`; for `root/build.md` -> `build`.
2. Convert `appendCommandsFromRoot` to a recursive walker: for `entry.kind == .directory`, recurse into the subdir (carry the same `root` so namespace is computed relative to root, not the immediate parent). For `.file` matching `.md`/`.txt`, compute the namespaced name via the helper.
3. For skills, the unit is a SKILL.md inside a directory; the namespace is the chain of parent dirs below the skills root, joined with `:`, plus the skill dir's basename (mirror `getSkillCommandName`). Apply the helper variant that uses the containing dir name rather than the file stem.
4. Keep recursion depth-bounded (e.g. max 8) to avoid pathological symlink loops; skip symlinked dirs.

**Acceptance criteria.**
- Test: `.zcode/commands/frontend/build.md` -> `list()` contains a command named `frontend:build`; `.zcode/commands/build.md` -> `build`.
- Test: nested `a/b/c.md` -> `a:b:c`.
- Test (integration with Task 1): `/frontend:build` resolves via the dispatcher fallthrough.
- Skill test: `.zcode/skills/frontend/deploy/SKILL.md` -> skill name `frontend:deploy`.

**Test strategy.** Unit tests in `core/commands.zig` and `core/skills.zig`.

**Risk / footguns.**
- `std.Io.Dir` iteration: open subdirs with `.{ .iterate = true }`; close each on defer. Recursion must not hold all dir handles open simultaneously past need.
- Do not pass `"."`/`"repo"` as cwd; resolve real absolute paths via the existing `paths.workspacePathAlloc` and `tmpDirCwd` in tests (per CLAUDE.md test-helpers note).
- Colon in a name must not break the dispatcher tokenizer (Task 1 splits on space, not colon - safe). Verify `frontend:build arg` splits to name `frontend:build`, args `arg`.

**Size estimate.** M.

---

### Task 4 - commands-04: Feed custom + plugin commands into autocomplete, add fuzzy match and a stable ranking hook

**Goal.** Tab/typeahead suggestions include built-in + custom + skill + plugin + MCP commands, matched fuzzily, ranked with a usage-frequency boost.

**Reference behavior.** Suggestions come from the live `getCommands(cwd)` registry, fuzzy-matched, including all sources, filtered by `isHidden`, ranked by `getSkillUsageScore` (`src/utils/suggestions/commandSuggestions.ts:36-49, 300-362, 382-421`).

**Target Zig files.**
- Edit `src/repl_commands.zig` - add `renderPromptSuggestionCommands` (custom `/command` dir) modeled on `renderPromptSuggestionSkills` (4002-4023), and register a `__prompt_suggestion_commands` arm next to the existing arms at 907-923.
- Edit `src/repl_commands.zig` - add `renderPromptSuggestionPlugins` for plugin-provided slash commands (if Phase 6 exposes plugin commands; if plugins only ship skills today, fold them into the skills suggestion and note the deferral).
- Edit `src/cli/repl.zig` - call `dynamic_command_suggestions.appendFromCommand(..., "__prompt_suggestion_commands")` next to lines 5366-5370; improve `matchesCommandQuery` (used at repl.zig:2905) to add subsequence fuzzy matching; apply ranking in `collectCommandSuggestions` (2887) / `CommandSuggestionSet.push`.

**Approach.**
1. New `renderPromptSuggestionCommands`: iterate `commands_mod.list(cwd)`, skip non-user-invocable, emit TSV `command\t/<name>\tcommand:<name>\t<description (+ argument-hint)>`. The `kind` token `command` maps to `.command` source in `appendFromCommand` (repl.zig:1506-1515) by default, so it renders correctly. Suggestion text is `/<name>` so the namespaced `frontend:build` becomes `/frontend:build`.
2. Wire the new callback in repl.zig at the same site as the others (5366-5370) and add an arm in `replCommandCallback`.
3. Fuzzy matching: extend `matchesCommandQuery` to accept a subsequence match (query chars appear in order within the candidate, case-insensitive) in addition to the current prefix/substring. Keep prefix matches ranked above subsequence matches.
4. Ranking: in `collectCommandSuggestions`, after gathering, stable-sort by `(usage_score desc, prefix-match-first, alphabetical)`. The usage score comes from Task 8 (`skill_usage.score(name)`); until Task 8 lands, the score function returns 0 for all and ordering degrades to prefix-first + alphabetical, which is already an improvement over append-order.
5. Filter removed/hidden commands: the existing built-in collector already filters `removed_commands`; ensure the custom/skill rows are not double-emitted (a skill that is also a command file). Dedup by suggestion `text` in `CommandSuggestionSet.push` (it may already; verify and add if missing).

**Acceptance criteria.**
- Test: with a tmp `.zcode/commands/deploy.md`, the suggestion callback `__prompt_suggestion_commands` emits a TSV row whose command is `/deploy` and description matches the file's frontmatter description.
- Test (pure, no REPL): `matchesCommandQuery("dpl", "deploy")` is true (subsequence) and `matchesCommandQuery("dep", "deploy")` is true (prefix); `matchesCommandQuery("xyz", "deploy")` is false.
- Test: given two suggestions with usage scores 5 and 0, `collectCommandSuggestions` orders the score-5 one first.

**Test strategy.** Unit-test the pure `matchesCommandQuery` and the ranking comparator directly (they are the load-bearing logic). The callback emission test uses `tmpDirCwd` + a stub runtime as the existing suggestion tests do (repl.zig:8092+).

**Risk / footguns.**
- The suggestion path runs inside the input loop on each relevant keystroke. `renderPromptSuggestionMcp` already documents "never connect synchronously" (repl_commands.zig:4073). `renderPromptSuggestionCommands` does disk I/O via `commands_mod.list`; the dynamic cache is rebuilt only on submit/refresh (repl.zig:5366 is gated), so per-keystroke cost is the cache lookup, not the disk walk. Keep it that way - do not call `list()` per keystroke.
- Do not break the existing TSV contract (4 tab-separated fields); a description containing a tab/newline corrupts parsing - reuse the first-line-only sanitization already in `renderPromptSuggestionSkills` (4018-4019).

**Size estimate.** L.

---

### Task 5 - commands-05: `argument-hint` gray text in typeahead

**Goal.** A command/skill with `argument-hint: <pr-url>` shows that hint after the command name while typing.

**Reference behavior.** `createCommandSuggestionItem` appends `(arguments: a, b)` from `argNames` and uses `argumentHint` gray text after the command (`commandSuggestions.ts:264-286`; `argumentHint` field described as "displayed in gray after command", `types/command.ts:188`).

**Target Zig files.**
- Edit `src/repl_commands.zig` `renderPromptSuggestionCommands` (Task 4) and `renderPromptSuggestionSkills` (4002) to emit the argument hint.
- Edit `src/cli/repl.zig` `CommandSuggestion` struct / `DynamicCommandSuggestion` (near 1474) and `appendCommandFooterRows` (2917) / `suggestionRow` to carry and render a third column (the hint), OR fold the hint into the existing `secondary` description with a separating space.
- Optionally use `core/argument_substitution.zig:179 generateProgressiveArgumentHint` to synthesize a hint from `arg_names` when no explicit `argument-hint` frontmatter is present.

**Approach.**
1. Simplest, lowest-risk: append the argument hint to the `secondary` description string emitted in the TSV (e.g. `"<description> [arg1] [arg2]"` or `"<description> (arguments: a, b)"`). This requires no struct change and renders via the existing `secondary` footer column.
2. If a distinct gray styling is wanted, add an `argument_hint: []const u8` field to `CommandSuggestion`/`DynamicCommandSuggestion` and a 5th TSV column; render it dim in `suggestionRow`. This is more invasive - prefer option 1 unless the footer renderer makes a separate dim column trivial.
3. Hint source priority: explicit `argument-hint` frontmatter, else `generateProgressiveArgumentHint(arg_names, &.{})` which yields `[arg1] [arg2]` from named args, else `(arguments: a, b)` from `arg_names`, else nothing.

**Acceptance criteria.**
- Test: a command with `argument-hint: <pr-url>` produces a suggestion whose rendered `secondary` (or hint field) contains `<pr-url>`.
- Test: a command with no `argument-hint` but `arguments: url mode` produces a hint containing `[url]` and `[mode]` (via `generateProgressiveArgumentHint`).

**Test strategy.** Unit tests on the TSV emission (string-contains assertions), reusing the suggestion-callback test harness.

**Risk / footguns.** Keep hints single-line (no tabs/newlines) to preserve the TSV contract. `generateProgressiveArgumentHint` returns `null` when `arg_names` is empty - handle the null.

**Size estimate.** M (S if option 1).

---

### Task 6 - commands-06: `/help` enumerates custom/user/skill/plugin commands

**Goal.** `/help` (and/or `/help commands`) lists user-defined commands and skills alongside built-ins, like the reference live registry.

**Reference behavior.** The help dialog lists ALL commands from the live registry (built-in + custom + plugin + skill), each annotated with source (`src/commands/help/index.ts`; `src/commands.ts:348-351`; `formatDescriptionWithSource` `commands.ts:728-754`).

**Target Zig files.**
- Edit `src/cli/repl_help.zig` `writeHelpScreen` (around line 398) to append a dynamically-enumerated section, OR
- Edit `src/repl_commands.zig` `/help` arm to append `commands_mod.renderList` + `skills_mod.renderList` + `plugins_mod.renderList` output after the static help text.

**Approach.**
1. Lowest-risk: in the `/help` dispatcher arm, after producing the static help text, append a "Custom commands" + "Skills" section by calling the existing `commands_mod.renderList(cwd)` and `skills_mod.renderList(cwd)` (these already exist and produce clean listings). Filter to user-invocable. This keeps `writeHelpScreen` (which is rendered in fullscreen mode) untouched and confines the change to the text-output path.
2. If `/help` must show this in fullscreen too, thread a `cwd` into `writeHelpScreen` and append the dynamic rows there. This is more invasive (the GROUPS array iteration at repl_help.zig:398 is static); prefer the text-path approach and note fullscreen `/help` as a follow-up if the user uses fullscreen help.
3. Annotate each row with its source/scope (already present in `renderList` output: `(user)`, `(workspace)`).

**Acceptance criteria.**
- Test: with a tmp `.zcode/commands/deploy.md`, the `/help` command output contains `deploy`.
- Test: built-in help text (existing assertions) still present.

**Test strategy.** Unit test the `/help` dispatcher output string for a tmp workspace.

**Risk / footguns.** `/help` is high-traffic; keep the disk walk to the submit path (it already is - `/help` runs on submit, not per keystroke). Do not regress the static help content.

**Size estimate.** M (S if reusing `renderList`).

---

### Task 7 - commands-07: `/statusline` command (statusline-setup prompt)

**Goal.** `/statusline [hint]` emits a prompt instructing the model to configure the status line (default: from the shell PS1) and write to settings, mirroring the reference subagent prompt.

**Reference behavior.** `/statusline` is a prompt command; default prompt `"Configure my statusLine from my shell PS1 configuration"`; it asks to create an Agent with subagent_type `statusline-setup`; allowedTools `Agent`, `Read(~/**)`, `Edit(~/.claude/settings.json)`; `disableNonInteractive` (`src/commands/statusline.tsx:4-23`).

**Target Zig files.**
- Edit `src/repl_commands.zig` - add a `/statusline` arm (place near `/issue` at 2211 or another prompt-command arm). Pattern: build a prompt string, dispatch via `runtime.handlePrompt(prompt)`.
- Optionally edit `src/core/command_canonical.zig` if there is a canonical-name table that should list it (verify; the survey says it is absent there).

**Approach.**
1. Add arm: `if (eql("/statusline") or startsWith("/statusline "))`. Extract optional arg; default to `"Configure my status line from my shell PS1 configuration"`.
2. Build the prompt: since zcode does not have a `statusline-setup` subagent type, the local best-effort is a direct instruction prompt: `"Configure the zcode status line. <hint>. Inspect the user's shell PS1 if helpful, then write the status_line configuration to the appropriate settings file (~/.zcode/settings.json or the workspace settings). Do not break existing settings."` Keep the wording free of em/en dashes.
3. Mention the target settings path zcode actually uses (resolve via `paths`), not the reference's `~/.claude/settings.json`.
4. Dispatch with `runtime.handlePrompt(prompt)` and return its output.

**Acceptance criteria.**
- Test: `/statusline` dispatches a prompt (assert the produced prompt string contains "status line" and "settings").
- Test: `/statusline use a minimal git branch indicator` includes the user hint in the prompt.

**Test strategy.** Unit test the dispatcher arm's prompt construction (extract a `fn buildStatuslinePrompt(allocator, hint) ![]u8` for pure testing).

**Risk / footguns.** This is best-effort: zcode renders a fixed status line (`src/cli/repl_render.zig:1477+`). The model writing settings only takes effect if the renderer reads a configurable status-line spec - which it currently does not. Document in Out-of-scope that the prompt is wired but actual customization requires a configurable renderer (defer). Do not claim it "configures the status line"; it asks the model to write settings.

**Size estimate.** S.

---

### Task 8 - misc-utils-15: Skill usage tracking with 7-day half-life ranking

**Goal.** Persist per-skill `usageCount` + `lastUsedAt`, debounced; compute `score = usageCount * max(0.5^(daysSinceUse/7), 0.1)`; feed it into the autocomplete ranking from Task 4.

**Reference behavior.** `recordSkillUsage` records count + timestamp in global config with a 60s debounce; `getSkillUsageScore = usageCount * max(0.5^(daysSinceUse/7), 0.1)` (`src/utils/suggestions/skillUsageTracking.ts:13-55`).

**Target Zig files.**
- Create `src/core/skill_usage.zig` (new deep module) - load/save a small JSON map `{ name: { count, last_used_ms } }` under the zcode home; `record(name)` with 60s debounce; `score(name) f64`.
- Register in `src/main.zig` comptime block (add `_ = @import("core/skill_usage.zig");` near the command imports ~108-110).
- Edit `src/repl_commands.zig` and/or `src/agent_runtime.zig` - call `skill_usage.record(name)` when a skill/command is invoked (the dispatch sites from Task 1 and the `/skill`/`/command` arms).
- Edit `src/cli/repl.zig` ranking comparator (Task 4) to call `skill_usage.score(name)`.

**Approach.**
1. Storage: a JSON file `~/.zcode/skill-usage.json` resolved via `paths.resolve(...).zcode_home`. Parse with the std JSON reader already used elsewhere. On parse failure, treat as empty (never fail the caller).
2. `record(allocator, name)`: read current entry; if `now - last_used_ms < 60_000` for this name, skip the write (debounce); else increment count, set `last_used_ms = clock.nowMillis()`, write back. Use `core/clock.zig nowMillis()` (per CLAUDE.md reuse rule - do not call `std.time.*`).
3. `score(name) f64`: `days = (now - last_used_ms) / 86_400_000.0`; `decay = max(pow(0.5, days/7), 0.1)`; `return count * decay`. Missing entry -> 0.
4. Ranking integration: Task 4's comparator uses `score(name)` to sort suggestions descending. To avoid disk reads per comparison, snapshot the usage map once per suggestion build and pass scores in.

**Acceptance criteria.**
- Test: `record("foo")` twice within 60s increments count by 1 (debounced), not 2.
- Test: `score` of a name used now equals `count * 1.0` (within float epsilon); a name 14 days stale equals `count * 0.25`; a name 70 days stale floors at `count * 0.1`.
- Test: unknown name scores 0.

**Test strategy.** Unit tests in `core/skill_usage.zig` using `tmpDirCwd`/a tmp zcode home and an injectable "now" parameter (pass `now_ms` into `score`/`record` for deterministic tests; the production wrapper supplies `clock.nowMillis()`).

**Risk / footguns.**
- Make `now` injectable for tests - do not read the wall clock inside the scored function or tests become time-dependent.
- File writes from the suggestion path must not happen per keystroke; `record` is called only on invocation (submit), `score` reads a cached snapshot. Keep that separation.
- `pow(0.5, x)` via `std.math.pow(f64, 0.5, x)`.

**Size estimate.** S.

---

### Task 9 - styles-onboarding-01: `keep-coding-instructions` suppresses the base "Doing tasks" section

**Goal.** When a custom output style is active and `keep-coding-instructions` is not true, the system prompt OMITS the base "Doing tasks" coding section, so the style fully replaces coding-agent behavior. Built-in Explanatory/Learning set it true (they layer on top).

**Reference behavior.** `outputStyleConfig === null || keepCodingInstructions === true ? getSimpleDoingTasksSection() : null` (`src/constants/prompts.ts:564-567`); flag parsed from frontmatter accepting bool or `"true"`/`"false"` (`src/outputStyles/loadOutputStylesDir.ts:52-62`); built-ins set true (`src/constants/outputStyles.ts:48,61`).

**Target Zig files.**
- Edit `src/core/output_styles.zig` - add `keep_coding_instructions: bool` to `OutputStyle` (12-25) and `ParsedStyleSource` (294-298); parse it in `parseStyleSource` (300-316); set it `true` for the built-in `explanatory` and `learning` entries and for `default` (default style = base instructions kept); custom styles default to `false`.
- Edit the system-prompt composition. **This is the architectural decision:** the base `doing_tasks_section` currently lives in `system_prompt.renderStaticPrefix` (`core/system_prompt.zig:82-102`), which is intentionally output-style-independent and cacheable. Two viable approaches:
  - (A) Move the conditional into the **static prefix** by giving `renderStaticPrefix` a parameter `keep_coding: bool` and threading the resolved style's flag from `prompt_helpers.renderSystemPolicy` (`core/prompt_helpers.zig:100-120`, currently ignores `output_style_name`). This makes the static prefix vary by style, so the prompt-cache fingerprint must include the flag.
  - (B) Keep `renderStaticPrefix` as-is for the default case, but when a style suppresses the base section, render a **variant prefix** that omits `doing_tasks_section`. Same caching consequence.
- Edit `src/core/prompt_engine.zig` (~118) - the system-policy fingerprint/cache key must incorporate the keep-coding flag so two different styles do not share a cache entry.

**Approach.**
1. Add and parse the flag (accept `true/false`, `"true"/"false"`, `yes/no`, `1/0` - reuse `skill_types.parseBool` semantics or `frontmatter` + a local bool parse).
2. In `renderSystemPolicy` (prompt_helpers.zig:100), stop ignoring `output_style_name`: resolve the style (`output_styles.resolve(allocator, cwd, output_style_name)`), read `keep_coding_instructions`. Compute `keep = (style is default/builtin-default) or style.keep_coding_instructions`. Pass `keep` to a new `system_prompt.renderStaticPrefix(allocator, keep)` that includes `doing_tasks_section` only when `keep` is true.
3. Default behavior must be unchanged: when no style or the `default` style is active, `keep == true` -> section included -> byte-identical to today. Add a test asserting this.
4. Update the prompt cache key (prompt_engine.zig) to include `keep` (or the resolved style name) so the cache does not serve a stale prefix.

**Acceptance criteria.**
- Test: `renderStaticPrefix(alloc, true)` contains `# Doing tasks`; `renderStaticPrefix(alloc, false)` does not, but still contains `# System`, `# Tone and style`, etc.
- Test: a custom workspace style with no `keep-coding-instructions` frontmatter -> `keep == false` -> base section omitted.
- Test: `explanatory` / `learning` built-ins -> `keep == true` -> base section present (they layer).
- Test: default style -> base section present (no regression). Verify the existing `renderStaticPrefix` tests (system_prompt.zig:106-147) still pass with the default path.

**Test strategy.** Unit tests in `core/system_prompt.zig`, `core/output_styles.zig`, and `core/prompt_helpers.zig` (the policy composition).

**Risk / footguns.**
- **Caching is the trap.** `renderStaticPrefix` is documented as "byte-identical across modes/providers/turns" (system_prompt.zig:78-81). Making it style-dependent breaks that invariant. The fix is correct only if the cache key now includes the style/flag. Audit every caller of `renderStaticPrefix` (3 files per earlier grep: system_prompt, prompt_engine, prompt_helpers) and every prompt-cache fingerprint site. Do not silently serve the wrong prefix from cache.
- The output style prompt is still appended in `renderDynamicSystemPolicy` (prompt_helpers.zig:232-235) - that path is unchanged; only the base coding section in the static prefix is gated.
- This is `severity: high` - it is the load-bearing semantic of output styles. Verify by reading the produced full prompt in an integration test, not just the prefix in isolation.

**Size estimate.** M.

---

### Task 10 - styles-onboarding-02: Plugin output styles + `forceForPlugin` auto-override

**Goal.** Plugin-provided output styles merge into the style set at plugin priority (between built-in and user); a plugin style with `force-for-plugin: true` is auto-selected regardless of the user's configured `output_style` (warn if more than one forces).

**Reference behavior.** `getAllOutputStyles` merges `loadPluginOutputStyles` at priority built-in < plugin < user < project (`src/constants/outputStyles.ts:137-175`); `getOutputStyleConfig` returns the first forced plugin style, warning on multiple (`outputStyles.ts:181-204`).

**Target Zig files.**
- Edit `src/core/output_styles.zig` - add `plugin` to `StyleScope` (6-10) and `scopeName` (341-347); add `force_for_plugin: bool` to `OutputStyle` and `ParsedStyleSource`; parse `force-for-plugin` in `parseStyleSource`; add a plugin loader and merge it in `list()` (164-182) at plugin priority (after builtins, before user); add `forcedPluginStyle(cwd) !?OutputStyle` and have `resolve` consult it first.
- Read-only dep: `src/core/plugins.zig` (`PluginSpec`, enabled-plugin enumeration, plugin root paths).

**Approach.**
1. Plugin style discovery: for each enabled plugin (via `plugins.zig`), look for an `output-styles/` dir under the plugin root and load `*.md` with `appendFromDir(..., .plugin)`. Insert these into the merged list at plugin priority. The existing `upsert` (262-276) handles dedup by name with last-writer-wins; ensure user/workspace are appended AFTER plugin so they override (current order: builtin, user, workspace - insert plugin between builtin and user).
2. Parse `force-for-plugin` (bool/`"true"`).
3. `forcedPluginStyle(cwd)`: scan the merged list for `scope == .plugin and force_for_plugin`; return the first; if more than one, log a warning (use `std.log.warn`) listing the names. Return null if none.
4. `resolve(allocator, cwd, raw_name)` (142-147): before honoring `raw_name`, check `forcedPluginStyle`; if present, return it (auto-override). Else fall through to existing behavior.

**Acceptance criteria.**
- Test: a plugin `output-styles/foo.md` appears in `list()` with `scope == .plugin`.
- Test: a user style and a plugin style with the same name -> user wins (priority).
- Test: a plugin style with `force-for-plugin: true` -> `resolve(cwd, "default")` returns the forced plugin style (override), and `forcedPluginStyle` returns it.
- Test: two forced plugin styles -> `forcedPluginStyle` returns the first deterministically (sorted by name) and the second is not silently swapped in.

**Test strategy.** Unit tests in `core/output_styles.zig` using a tmp workspace with a fake enabled-plugin dir layout. Match how `plugins.zig` resolves plugin roots so the test mirrors production discovery.

**Risk / footguns.**
- Priority order is exact and load-bearing: builtin < plugin < user < project(workspace). The current `list()` appends builtin, user, workspace; insert plugin immediately after builtin. Verify `upsert` last-writer-wins still yields the right winner given the new order.
- `resolve` auto-override changes behavior for ALL users who have a forcing plugin enabled, even if they set a different style. Match the reference exactly (forced wins) and surface the warning so it is discoverable. Do not auto-override on non-plugin scopes.
- Determinism: sort plugin styles by name before picking "the first forced" so the choice is stable across runs.

**Size estimate.** M.

---

## Verification

1. **Build (debug + release).**
   - `/Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build` (debug, runs the custom test runner under `tools/test_runner.zig`).
   - `/Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build test` to run all unit tests, including the new ones in `core/commands.zig`, `core/skills.zig`, `core/skill_types.zig`, `core/output_styles.zig`, `core/system_prompt.zig`, `core/skill_usage.zig`, `core/command_namespace.zig`, `core/prompt_helpers.zig`, and the repl suggestion tests in `src/cli/repl.zig`.
   - Confirm every new module is referenced in the `src/main.zig` comptime block (test discovery rule): `core/skill_usage.zig`, `core/command_namespace.zig`.

2. **Release build + install (per CLAUDE.md, mandatory after every change).**
   ```
   /Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build -Doptimize=ReleaseFast
   rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode
   ```
   (Use `rm -f` first to avoid the macOS in-place-overwrite code-signature invalidation that SIGKILLs the next run.)

3. **Version bump.** Bump `.version` patch in `build.zig.zon`; the git short-hash is appended automatically by `build.zig`.

4. **Manual checks (in `zcode` REPL).**
   - Create `~/.zcode/commands/deploy.md` with frontmatter (`description`, `argument-hint: <env>`, `arguments: env`) and body `Deploy to $env`. Type `/dep` -> suggestion shows `/deploy` with description + hint. Run `/deploy staging` -> the model receives a prompt containing `staging` (commands-01, 02, 04, 05).
   - Create `~/.zcode/commands/frontend/build.md`; type `/frontend:build` -> resolves (commands-03).
   - Run `/help` -> output lists `deploy` and `frontend:build` under custom commands (commands-06).
   - Run `/statusline use a git branch indicator` -> a configuration prompt is dispatched (commands-07).
   - With an MCP server exposing a prompt, `Skill action=list` includes the MCP prompt; type the prompt name as a slash command and confirm it resolves (commands-10).
   - Invoke a skill a few times; confirm it floats up the suggestion list (misc-utils-15).
   - Create `~/.zcode/output-styles/replacer.md` (no `keep-coding-instructions`); activate it; inspect the system prompt (e.g. via the debug prompt dump) and confirm `# Doing tasks` is absent. Activate `explanatory` and confirm `# Doing tasks` is present (styles-onboarding-01).
   - Enable a plugin shipping an `output-styles/` style with `force-for-plugin: true`; confirm it is auto-selected regardless of the configured style (styles-onboarding-02).

5. **Regression guard.** Run the full test suite and confirm the existing `renderStaticPrefix` byte-identical/cacheability tests pass on the default path (no style or `default`), and the existing `commands.zig` substitution tests pass unchanged.

## Out-of-scope / deferred notes

- **Full Fuse-grade fuzzy ranking.** Task 4 implements subsequence + prefix matching with a usage-score boost, not the reference's full Fuse.js scoring (token weights, threshold tuning). The simpler ranker is sufficient for parity in practice; a richer scorer is deferred.
- **`/statusline` actually customizing the rendered status line.** Task 7 wires the prompt and lets the model write settings, but `src/cli/repl_render.zig` renders a fixed status line and does not yet read a configurable status-line spec. Making the renderer honor a user/settings-defined status-line template is a separate renderer change, deferred.
- **`statusline-setup` subagent type.** The reference spawns a named subagent; zcode uses a direct instruction prompt instead. Adding a first-class `statusline-setup` agent type is deferred (low value vs. the direct prompt).
- **Skill frontmatter `hooks` and `shell` fields.** The reference `parseSkillFrontmatterFields` also parses `hooks` and `shell`. Those belong to the hooks/shell subsystems (covered elsewhere) and are out of scope here; this phase parses the command/skill metadata fields that drive invocation, description, allowlist, model, and arguments.
- **Plugin-provided slash commands (non-skill).** If Phase 6's plugin model only ships skills (not standalone command files), Task 4's `renderPromptSuggestionPlugins` folds plugin skills into the skills suggestion and a dedicated plugin-command source is deferred until plugins expose command files.
- **`disable-model-invocation` end-to-end enforcement.** Task 2 parses the field into the CommandSpec; ensuring the Skill tool's `action=list`/`action=run` honors it for commands (not just skills) is partially covered by commands-10's listing work but full enforcement across the model-invocation path is tracked with the Skill-tool parity items, not duplicated here.
- **Output-style cache-key audit beyond the static prefix.** Task 9 updates the prompt-cache key for the keep-coding flag. A broader audit of every prompt-cache fingerprint site for style-dependence is recommended but scoped to that task's caller list (system_prompt, prompt_engine, prompt_helpers).
