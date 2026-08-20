# Phase 20: Skills subsystem depth

## Overview

**What.** This phase closes the depth gaps in zcode's skills subsystem that the Round-1 audit missed or under-covered. The skill *data model* (frontmatter parse, scopes, MCP-prompt mapping), *visibility filter* (`disable-model-invocation`, `user-invocable`, `paths` gating), *awareness listing* (budget-capped per-turn injection), and the *Skill action=run* invocation path all exist and are well-tested. What is missing is the harder enforcement, substitution, gating, and authoring behavior layered on top: refusing to *execute* a `disable-model-invocation` skill (not just hide it), wiring per-skill-name permission rules into the run path, `${CLAUDE_SKILL_DIR}` / `${CLAUDE_SESSION_ID}` substitution plus a base-directory header, sticky conditional-skill activation, a context-window-relative listing budget that never truncates bundled skills, full `model:`/`effort:` override on the inline path (with `inherit` and `[1m]` carry-over), a `skillify` authoring flow, and several small structural fields (`aliases`, `hooks:`, realpath dedup, bundled `files:`).

**Why.** Two of the gaps (skills-01, skills-02) are security/correctness holes: today the model can execute a skill its author explicitly marked off-limits to the model, and a user cannot deny or allow a specific skill by name because the run path hardcodes `risk=.LOW`, `auto_approved` and never consults the permission engine. The medium-severity gaps (skills-03, skills-04, skills-09, skills-10, skills-07) are real behavioral divergences that make user-authored skills resolve wrong paths, lose visibility unexpectedly, get truncated under context pressure, silently ignore their `model:`/`effort:` overrides on the common inline path, and prevent users from capturing a repeatable process as a reusable skill. The low-severity items are structural completeness.

**Dependencies on earlier phases.** Builds on Phase (permissions/policy) work that produced `core/permission_rules.zig` (the `Store.match` engine with deny/allow/ask, glob `argsMatch`, scope support) and the `agent_tools.zig` approval flow - skills-02 wires the Skill run path into that existing engine. Relies on Phase (hooks) infrastructure (`core/hook_event.zig` `ConfigChange`, `core/hook_config.zig`) for skills-11 (skill-scoped hooks) and the deferred skills-05 ConfigChange firing. skills-07 (skillify) depends on the AskUserQuestion tool and Write tool already present. No new cross-phase prerequisites.

**Effort.** In-scope build set is roughly 2 x S + 6 x M + 1 x L. Recommended order: skills-01 (S, security) and skills-10 (M, inline override) first since they are pure additions to the existing run path; then skills-02 (M, permission wiring), skills-03 (M, substitution), skills-09 (M, budget); skills-04 (M) and skills-07 (L) last as the largest behavioral additions. The small structural items (skills-12, skills-13) can ride along with whichever module they touch.

## Scope split

| Gap | Decision | Reason |
|-----|----------|--------|
| skills-01 disable-model-invocation enforcement at run path | IN-SCOPE | Security hole; field already parsed, only the guard is missing. S. |
| skills-02 Skill-tool permission gating (deny/allow/prefix/safe-properties/ask) | IN-SCOPE | Permission engine already exists; only the wiring into the skill run path is missing. M. |
| skills-03 `${CLAUDE_SKILL_DIR}` / `${CLAUDE_SESSION_ID}` + base-dir header | IN-SCOPE | User skills referencing `./scripts` or the vars silently break. M. |
| skills-04 sticky conditional-skill activation + nested `.claude/skills` discovery | IN-SCOPE (split) | (a) sticky activation is in-scope; (b) nested-dir discovery is in-scope but lower priority within the gap. M. |
| skills-07 `skillify` authoring flow | IN-SCOPE | Scope explicitly names "skill improvement survey". Local equivalent (analyze session -> interview -> write SKILL.md). L. |
| skills-09 context-window-relative budget + bundled-never-truncated + env override | IN-SCOPE | Affects which skills the model can discover under pressure. M. |
| skills-10 `model:'inherit'`, effort validation, `[1m]` carry-over, inline-path override | IN-SCOPE | Inline skills silently ignore their `model:`/`effort:` today. M. |
| skills-11 `hooks:` frontmatter on skills | IN-SCOPE (conditional) | In-scope only if zcode supports dynamically-scoped hooks; otherwise document as deferred. M. |
| skills-12 symlink realpath dedup | IN-SCOPE | Small, structural; name-based override is the more important behavior but realpath dedup is cheap. S. |
| skills-13 `aliases` support | IN-SCOPE | Trivial string-list field + findByName check. S. |
| skills-05 file-watcher / hot-reload + ConfigChange firing | OUT-OF-SCOPE (document) | Reload-on-read already achieves the UX; only the ConfigChange-hook firing is a genuine miss, and that belongs to the hooks phase, not skills. Note the local stub. |
| skills-06 legacy `/commands/` dir as skills + namespacing | OUT-OF-SCOPE (document) | zcode deliberately separates skills and commands. Document; the nested `a:b:c` namespace is folded into skills-04 nested-dir discovery instead. |
| skills-08 bundled `files:` extraction + nonce'd root | OUT-OF-SCOPE (document) | None of the 6 bundled skills ship aux files. Document the structural gap; build only the `files:` struct field as a no-op stub if skills-03 base-dir work makes it trivial. |
| skills-15 feature-flagged bundled skills + remote skill search | OUT-OF-SCOPE | Per survey: chrome/computerUse + cloud AKI/GCS backend exclusions. Local renames already cover loop/dream/schedule. A small `is_enabled` gate stub is the only worthwhile local piece. |

## Gaps covered

| id | title | severity | size | our current state |
|----|-------|----------|------|-------------------|
| skills-01 | disable-model-invocation not enforced at run path | high | S | `skill_visibility.zig:32` hides it from the model listing; `agent_runtime.zig:2090-2122` executes any name with no guard. |
| skills-02 | No Skill-tool permission gating | high | M | `tryExecuteSkillRun` hardcodes `risk=.LOW`/`auto_approved` (2117-2118); permission engine exists in `permission_rules.zig` but skills never consult it. |
| skills-03 | `${CLAUDE_SKILL_DIR}`/`${CLAUDE_SESSION_ID}` + base-dir prefix | medium | M | Zero matches in src; `renderRun` does arg substitution only; `SkillSpec` has no `skill_dir`, `renderRun` has no `session_id` param. |
| skills-04 | conditional skills filtered but not sticky; no nested discovery | medium | M | `file_focus` is sticky (`mergeFileFocus`) and re-gated each turn (`skill_visibility.zig:38`); no per-skill activation set; only cwd-level roots scanned (`skills.zig:31-37`). |
| skills-07 | `skillify` authoring flow | medium | L | 6 bundled skills only; full parse/exec infra present; no session-memory -> interview -> SKILL.md authoring path. |
| skills-09 | 1%-context budget + bundled-never-truncated + env override | medium | M | 250-char per-entry cap present (`skill_listing.zig:20`); budget hardcoded 1500 (`prompt_engine.zig:16`); uniform degradation, no bundled partition, no env override. |
| skills-10 | `model:'inherit'`, effort validation, `[1m]`, inline override | medium | M | Forked path applies model/effort (`agent_runtime.zig:2141-2148`); inline path applies neither; no `inherit` special-case, no effort warning, no `[1m]`. |
| skills-11 | `hooks:` frontmatter on skills | low | M | No `hooks` field in `SkillSpec`; parse() ignores it; no skill-scoped registration. |
| skills-12 | symlink realpath dedup | low | S | `upsert` dedups by case-insensitive name only (`skills.zig:233-247`); no realpath identity tracking. |
| skills-13 | `aliases` support | low | S | No `aliases` field anywhere; `findByName` checks canonical name only. |

## Implementation tasks

### skills-01 - Enforce disable-model-invocation at the Skill run path

**Goal.** When the model invokes `Skill` with `action=run` and `name=<a disable-model-invocation skill>`, refuse to execute it and return an error trace, never the skill body. Only `/name` (the user-typed path) may run such a skill.

**Reference behavior + file:line.** `SkillTool.validateInput` rejects before any render: `claude-code-main/src/tools/SkillTool/SkillTool.ts:412-418` returns `result:false`, `errorCode:4`, message `"Skill <name> cannot be used with Skill tool due to disable-model-invocation"`. The `call` path documents (lines 587-592) that by the time it runs, validateInput has already guaranteed the skill is not `disableModelInvocation`.

**Target Zig files.** `src/agent_runtime.zig` (`tryExecuteSkillRun`, around line 2090-2111). No new module; the data model field `disable_model_invocation` already exists in `skill_types.zig:57`.

**Approach.**
1. In `tryExecuteSkillRun`, immediately after the `spec` is resolved (line 2093, after the `defer spec.deinit`), add a guard: `if (spec.disable_model_invocation) { ... return error trace ... }`.
2. Build a `ToolTrace` with `executed = false`, `approval_state = .denied` (or a new `.blocked` if that reads better against existing enum usage), `risk = .LOW`, and `output` set to the parity message `"Skill <name> cannot be used with the Skill tool due to disable-model-invocation"`. Return it wrapped in the optional so dispatch surfaces it to the model.
3. Do NOT touch the user-typed `/skill` path in `repl_commands.zig` - that path is the legitimate user invocation and must still run the skill. Confirm the REPL path does not route through `tryExecuteSkillRun` (it calls `renderRun`/exec directly).

**Acceptance criteria.** Write a test in `agent_runtime.zig` (or a focused helper test) that: creates a workspace skill with `disable-model-invocation: true`, invokes the dispatch with `{"action":"run","name":"<skill>"}`, and asserts the returned trace has `executed == false` and `output` contains `disable-model-invocation`, and that the skill body string does NOT appear in the output. A second assertion: the same skill invoked via the user `/skill` path still renders the body.

**Test strategy.** Runs under `tools/test_runner.zig`. Use `test_helpers.tmpDirCwd` to get an absolute cwd, write `.zcode/skills/<name>/SKILL.md` with the frontmatter, build a minimal `AgentRuntime` (mirror the existing fork/skill tests). Prefix each test name so `RUN: <name>` shows for hang diagnostics.

**Risk + 0.16 footguns.** Low risk - pure additive guard. Footgun: the `ToolTrace.output` is owned; allocate with the runtime allocator and let the normal trace-free path reclaim it. Do not early-return before `spec.deinit` is registered (the `defer` is on line 2093, so place the guard after it).

**Size.** S.

### skills-10 - model:'inherit', effort validation, [1m] carry-over, inline-path override

**Goal.** Inline skills (the common path) apply their `model:` and `effort:` frontmatter to the session for the duration of the skill, matching the forked path. `model: inherit` is treated as "no override". Invalid `effort:` values emit a debug warning instead of silently being ignored. A `model: opus` override on an `opus[1m]` session preserves the `[1m]` suffix.

**Reference behavior + file:line.** `loadSkillsDir.ts:221-235` parses `model:'inherit'` as undefined and runs `parseUserSpecifiedModel`; `effort` via `parseEffortValue` with a debug warning on invalid. `SkillTool.ts:808-821` `resolveSkillModelOverride` carries `[1m]`. `SkillTool.ts` contextModifier (775-838) applies model+effort for inline skills too.

**Target Zig files.** `src/agent_runtime.zig` (`tryExecuteSkillRun` inline branch ~2105-2111, and `runForkedSkill` 2141-2148 for the `inherit`/`[1m]` fixes); possibly a small helper `resolveSkillModelOverride` in `core/skill_types.zig` (pure, unit-testable) for the `[1m]` carry-over and `inherit` normalization.

**Approach.**
1. Add `pub fn resolveModelOverride(allocator, skill_model, session_model) !?[]u8` to `skill_types.zig`: returns `null` when `skill_model` is empty or case-insensitively equals `"inherit"`; otherwise returns `skill_model`, appending `[1m]` when `session_model` ends with `[1m]` and `skill_model` does not already carry a suffix. Unit-test it in isolation.
2. In `runForkedSkill`, replace the raw `spec.model.len > 0` block (2144-2148) with a call to `resolveModelOverride(self.allocator, spec.model, child.active_model)`; only assign when non-null.
3. For the inline path: when `spec.context == .inline_skill` and `spec.model`/`spec.effort` are set, apply the override to the *current* runtime (self) for the duration of the inline skill's effect. Mirror the forked logic: `self.reasoning_effort` from `ReasoningEffort.fromString(spec.effort)` and `self.active_model` from `resolveModelOverride`. Decide and document the lifetime: simplest is "apply for the remainder of the session" (matching that inline skills mutate session state in the reference's contextModifier). If a scoped restore is wanted, snapshot+restore around the inline render - but the reference mutates session state, so prefer the simple apply.
4. Effort validation warning: `ReasoningEffort.fromString` returns null silently (`types.zig:218-225`). When `spec.effort.len > 0` and `fromString` returns null, emit a debug log line (gated by the existing `ZCODE_DEBUG_LLM`/debug mechanism) `"skill <name>: invalid effort value '<v>', ignoring"`.

**Acceptance criteria.** Tests: (a) `resolveModelOverride("opus", "opus[1m]")` returns `"opus[1m]"`; (b) `resolveModelOverride("inherit", "opus")` returns null; (c) `resolveModelOverride("", "opus")` returns null; (d) an inline skill with `model: sonnet`/`effort: high` mutates `self.active_model`/`self.reasoning_effort`; (e) invalid `effort: turbo` leaves effort unchanged (and, if a debug sink is injectable, that the warning was emitted).

**Test strategy.** `tools/test_runner.zig`. Pure `resolveModelOverride` tests live in `skill_types.zig`. The inline-apply test builds an `AgentRuntime` and checks fields after invoking dispatch with a stubbed/short-circuited model call (or assert state right after the override is applied, before the LLM call).

**Risk + 0.16 footguns.** `self.active_model` is owned - free the old before assigning the new (the forked path at 2146 already does `self.allocator.free(child.active_model)`; replicate exactly). Do not double-free when both inline and forked branches run. Footgun: `ReasoningEffort.fromString` is case-insensitive named-band; do not pre-trim differently than it expects.

**Size.** M.

### skills-02 - Wire per-skill permission gating into the run path

**Goal.** Before executing a model-invoked skill, consult the permission engine for a `Skill(<name>)` deny/allow/ask decision with prefix (`<name>:*`) matching; auto-allow skills whose frontmatter uses only safe properties; otherwise fall to an ask prompt with addRules-style suggestions. The user can `deny`/`allow` a specific skill by name.

**Reference behavior + file:line.** `SkillTool.ts:432-578` `checkPermissions`: deny loop with `ruleMatches` (exact + `:*` prefix), allow loop, `skillHasOnlySafeProperties` auto-allow, else `ask` with two `addRules` suggestions (exact + `name:*`). `SkillTool.ts:871-933` `SAFE_SKILL_PROPERTIES` allowlist + `skillHasOnlySafeProperties`.

**Target Zig files.** `src/agent_runtime.zig` (`tryExecuteSkillRun`, replacing the hardcoded `.LOW`/`auto_approved`); `src/core/permission_rules.zig` (the `match`/`toolMatches` engine already supports tool name + `args_contains` glob - reuse it, matching `tool == "Skill"` and the skill name carried in `args_contains`); a new pure helper `skillHasOnlySafeProperties` in `core/skill_types.zig`.

**Approach.**
1. Add `pub fn hasOnlySafeProperties(spec: *const SkillSpec) bool` to `skill_types.zig`. The safe set mirrors the reference `SAFE_SKILL_PROPERTIES` (name, description, when-to-use, version, user-invocable, paths). A skill is unsafe if it sets a meaningful value for any non-safe property: non-empty `allowed_tools`, non-empty `agent`, non-empty `model`, non-empty `effort`, `context == .fork`, non-empty `hooks` (once skills-11 lands). New/unreviewed properties default to unsafe. Unit-test both directions.
2. In `tryExecuteSkillRun`, after the disable-model-invocation guard (skills-01) and before render, consult `self.permission_rules` (the same handle `agent_tools` uses). The existing `Store.match(cwd, tool, args)` already glob-matches the args field, but skill-name matching wants the *name*, not the JSON args. Two options - prefer the one that reuses the engine cleanly:
   - Synthesize a match key: call `match(self.cwd, "Skill", spec.name)` so existing rule rows of the form `allow<TAB>scope<TAB>Skill<TAB><name-or-name*><TAB>label` match the skill name via the existing `argsMatch` glob (`name:*` becomes the glob `name*`, or normalize `:*` -> `*` when loading skill rules). Document that `Skill` rules match against the skill name, not the JSON args.
3. Map the engine decision: `.deny` -> error trace `"Skill execution blocked by permission rules"` (`executed=false`, `approval_state=.denied`). `.allow` -> proceed, `approval_state=.user_approved`. `.ask` -> if `session_approved_tools` already contains a per-skill key, proceed `.session_approved`; else prompt via the existing `promptForPermissionRule`-style flow with suggestions for exact + prefix, persisting on session-approve.
4. No rule matched: if `hasOnlySafeProperties(spec)` -> auto-allow `.auto_approved` (preserves today's behavior for benign skills, so the 6 bundled skills keep running without prompts). Otherwise fall to ask with suggestions.
5. Keep the existing session-scoped `allowed_tools` auto-allow (2099-2103) - that is a separate concern (tools the skill may use), unchanged.

**Acceptance criteria.** Tests: (a) `hasOnlySafeProperties` true for a name/description-only skill, false when `allowed-tools` or `context: fork` set; (b) a `deny Skill <name>` rule blocks execution (trace `executed=false`, output mentions blocked); (c) an `allow Skill <name>:*` rule allows a skill whose name starts with `<name>`; (d) a benign skill with no matching rule auto-allows; (e) a skill with `allowed-tools` and no rule falls to ask (in non-interactive test, asserts the ask path was taken / denied-by-default).

**Test strategy.** `tools/test_runner.zig`. Pure `hasOnlySafeProperties` tests in `skill_types.zig`. Engine-wiring tests build an `AgentRuntime` with a populated `permission_rules.Store` and assert trace outcomes. Reuse the existing `permission_rules` test patterns for rule rows.

**Risk + 0.16 footguns.** The biggest risk is regressing the current "bundled skills just run" UX - the safe-properties auto-allow (step 4) is what preserves it; verify the 6 bundled skills all pass `hasOnlySafeProperties`. Footgun: `Store.match` iterates rules newest-first (last-wins); ensure deny is still authoritative by checking the matched rule's action rather than assuming order. Do not break the existing `args_contains` semantics for real tool rules - skill-name matching must be scoped to `tool == "Skill"`.

**Size.** M.

### skills-03 - ${CLAUDE_SKILL_DIR} / ${CLAUDE_SESSION_ID} substitution + base-dir header

**Goal.** On invocation, a non-builtin skill's rendered body has `${CLAUDE_SKILL_DIR}` replaced with the skill's own directory and `${CLAUDE_SESSION_ID}` replaced with the session id; disk/bundled-with-baseDir skills get a `Base directory for this skill: <dir>` prefix line so `Read`/`Grep`/bash can reach bundled scripts.

**Reference behavior + file:line.** `loadSkillsDir.ts:345-369`: `baseDir` prepended as `"Base directory for this skill: <dir>\n\n"` when present, then `${CLAUDE_SKILL_DIR}` (forward-slash normalized) and `${CLAUDE_SESSION_ID}` replaced globally; MCP skills skip `${CLAUDE_SKILL_DIR}` and shell injection (371-374).

**Target Zig files.** `src/core/skills.zig` (`renderRun`, 144-184); `src/core/skill_types.zig` (`SkillSpec` - derive skill dir from `source_path` via `std.fs.path.dirname`, no new stored field strictly needed); a small pure substitution helper, ideally folded into `core/argument_substitution.zig` or a new `replaceVar` in `skills.zig`. Thread `session_id` from the call sites (`agent_runtime.zig` `tryExecuteSkillRun`/`runForkedSkill`, REPL `/skill` path).

**Approach.**
1. Add a `session_id: []const u8` parameter to `renderRun` (and propagate to call sites: `agent_runtime.zig:2111`, `2130`, REPL `/skill`). Where a session id is unavailable (one-shot tests), pass `""`.
2. In `renderRun`, for non-builtin skills, compute `skill_dir = std.fs.path.dirname(skill.source_path) orelse ""`. For `.mcp` scope, skip both the base-dir header and `${CLAUDE_SKILL_DIR}` (MCP bodies are remote/untrusted - match reference 371-374); still allow `${CLAUDE_SESSION_ID}`.
3. After arg substitution (line 172), do two global string replacements on the expanded prompt: `${CLAUDE_SKILL_DIR}` -> `skill_dir`, `${CLAUDE_SESSION_ID}` -> `session_id`. Use a small allocating replace (or `std.mem.replace` size-then-fill). Normalize backslashes to `/` is a no-op on macOS/Linux; keep it simple.
4. Prepend `"Base directory for this skill: <skill_dir>\n\n"` to the body for disk (`.user`/`.workspace`/`.plugin`) skills with a non-empty `skill_dir`, before the existing `"Skill: ... Source: ..."` envelope or folded into it (match reference ordering: base-dir line first).
5. Builtin skills (`.builtin`) have no real directory - skip the header and skip `${CLAUDE_SKILL_DIR}` (leave the literal untouched or replace with empty; prefer leaving untouched so it is visibly unresolved rather than silently blanked). `${CLAUDE_SESSION_ID}` may still be substituted.

**Acceptance criteria.** Tests: (a) a workspace skill whose body contains `${CLAUDE_SKILL_DIR}/scripts/run.sh` renders with the absolute skill directory substituted; (b) `${CLAUDE_SESSION_ID}` renders with the passed session id; (c) the rendered output starts with / contains `Base directory for this skill: <dir>` for a disk skill; (d) an MCP-scope skill does NOT get `${CLAUDE_SKILL_DIR}` substituted but DOES get `${CLAUDE_SESSION_ID}`; (e) a builtin skill renders unchanged (no base-dir header).

**Test strategy.** `tools/test_runner.zig`. Write `.zcode/skills/foo/SKILL.md` under a tmp dir, call `renderRun(alloc, cwd, "foo", "", "sess-123")`, assert substitutions. Use `test_helpers.tmpDirCwd` for an absolute cwd so `dirname(source_path)` is a real absolute path.

**Risk + 0.16 footguns.** `std.fs.path.dirname` returns `?[]const u8`; handle null. The existing `renderRun` builtin early-return (156-163) must remain - add the new param but keep builtins on the simple path. Footgun: `std.mem.replace` needs the output buffer pre-sized; use the count-then-alloc idiom or `replaceOwned`. Watch the `errdefer`/ownership on the intermediate expanded buffers (the function already frees `expanded_prompt`).

**Size.** M.

### skills-09 - Context-window-relative listing budget, bundled-never-truncated, env override

**Goal.** The awareness-listing char budget is 1% of the model context window in chars (`tokens * 4 * 0.01`, default 8000), overridable by `SLASH_COMMAND_TOOL_CHAR_BUDGET`. When over budget, bundled (`scope == .builtin`) skills keep full descriptions and only non-bundled entries are trimmed or dropped to names-only.

**Reference behavior + file:line.** `prompt.ts:21-41` `getCharBudget` (`SKILL_BUDGET_CONTEXT_PERCENT=0.01`, `CHARS_PER_TOKEN=4`, `DEFAULT_CHAR_BUDGET=8000`, env override). `prompt.ts:70-171` `formatCommandsWithinBudget`: partition bundled vs rest, bundled preserved, rest trimmed to `maxDescLen` or names-only when `maxDescLen < MIN_DESC_LENGTH` (20). Per-entry cap `MAX_LISTING_DESC_CHARS=250`.

**Target Zig files.** `src/core/prompt_engine.zig` (replace const `SKILL_LISTING_BUDGET = 1500` at line 16 with a computed budget from the model context window + env override); `src/core/skill_listing.zig` (`render` - add bundled-preserving partition logic).

**Approach.**
1. In `prompt_engine.zig`, compute the budget: `getCharBudget(context_window_tokens)` = if env `SLASH_COMMAND_TOOL_CHAR_BUDGET` parses to a positive int use it; else if a context-window token count is available use `floor(tokens * 4 / 100)`; else `8000`. The context window is already known to the prompt builder (model metadata) - thread it in or read from the existing model-config lookup. Replace the hardcoded `1500` at the `renderModelListing` call site (`prompt_engine.zig:164`).
2. In `skill_listing.zig`, refactor `render` to partition by `scope == .builtin` (zcode's bundled) into a preserved set and a degradable rest. Try full detailed listing first (existing step 1). When over budget: always emit bundled entries at full (250-capped) description; compute remaining budget for the rest; if per-rest description budget `< 20` chars, render rest as names-only while keeping bundled full; else trim rest descriptions to the per-rest max. Keep the existing deterministic ordering and the existing names-only-truncation as the final fallback for the rest.
3. Keep `MAX_ENTRY_CHARS = 250` as the per-entry cap (already present, line 20) applied to all entries including bundled.

**Acceptance criteria.** Tests in `skill_listing.zig`: (a) under a tight budget, a `.builtin` skill keeps its full description while a `.user` skill degrades to names-only; (b) `getCharBudget` returns `8000` with no tokens, `tokens*4/100` with tokens, env value when set; (c) when everything fits, output is unchanged from today (regression guard); (d) bundled entries are never dropped even when names-only truncation kicks in for the rest.

**Test strategy.** `tools/test_runner.zig`. `getCharBudget` is pure - test directly (env override via `std.process.Environ` or by injecting the value as a param to keep it testable without touching real env). The partition logic is pure over a `[]SkillSpec` with mixed scopes.

**Risk + 0.16 footguns.** Reading env: prefer threading `init.environ_map` / the config rather than `std.process.getEnvMap` (gone in 0.16 per CLAUDE.md - use `std.process.Environ.Map`). Keep `getCharBudget` taking the env value as a resolved param so the listing module stays PURE (no IO), matching the module's stated invariant. The existing tests assert specific truncation behavior - update them deliberately, do not silently change the names-only fallback shape for the all-bundled case.

**Size.** M.

### skills-04 - Sticky conditional-skill activation + nested .claude/skills discovery

**Goal.** (a) Once a `paths`-gated skill matches a touched file, it becomes *activated* and stays visible for the rest of the session even if that file later leaves `file_focus`. (b) As files in nested directories are touched, skills in their ancestor `.claude/skills` (zcode: `.zcode/skills`) directories are discovered and loaded dynamically.

**Reference behavior + file:line.** `loadSkillsDir.ts:771-803` conditional store; `861-1058` `discoverSkillDirsForPaths` / `addSkillDirectories` / `activateConditionalSkillsForPaths` (gitignore-skipped walk up from touched paths; `activatedConditionalSkillNames` sticky set).

**Target Zig files.** `src/agent_runtime.zig` (add an `activated_conditional_skills: std.StringHashMapUnmanaged(void)` runtime field, populated each turn from the current `file_focus` x skill `paths` match, persisted in the `SessionSnapshot` so it survives compaction); `src/core/skill_visibility.zig` (add an "is this skill already activated" override so an activated skill bypasses the per-turn paths gate); `src/core/skills.zig` (nested-dir discovery from a set of touched paths). Persist via `session/store.zig`.

**Approach.**
1. Activation set: add a runtime field and, each turn before building the listing, for every skill with non-empty `paths`, if `matchesAnyPath(paths, file_focus)` is true, insert the skill name into `activated_conditional_skills`. Persist this set in `SessionSnapshot` (mirror how `file_focus` is persisted at `session/store.zig:131-159`).
2. Visibility override: extend `skill_visibility.isVisible` (or add a sibling `isVisibleWithActivation`) so a skill whose name is in the activated set passes the paths gate unconditionally (still subject to the audience gate). Keep the pure-module invariant: pass the activated-name set in as a parameter, do not let the module read runtime state.
3. Nested discovery (lower priority within this gap): add `discoverSkillDirsForPaths(allocator, touched_files)` to `skills.zig` that, for each touched file, walks up parent directories looking for `.zcode/skills` (and `.claude/skills` for compatibility), skipping gitignored dirs, and appends any skills found (scope `.workspace`). Wire it into `list()` when a touched-file set is available, deduping via the realpath dedup from skills-12. Cap the walk depth and cache per session to avoid re-walking every turn.

**Acceptance criteria.** Tests: (a) a skill with `paths: *.zig` becomes visible after `src/x.zig` is in `file_focus`, and *stays* visible on a subsequent turn where `file_focus` no longer contains a matching file (activation is sticky); (b) the activated set round-trips through `SessionSnapshot` persistence; (c) nested discovery: touching `sub/dir/file.zig` surfaces a skill defined in `sub/.zcode/skills/foo/SKILL.md`.

**Test strategy.** `tools/test_runner.zig`. Activation/visibility tests are pure over the new parameterized predicate. The discovery + persistence tests use `test_helpers.tmpDirCwd` and exercise the snapshot round-trip.

**Risk + 0.16 footguns.** Sticky activation can grow unbounded across a long session - bound it to the set of skills that actually exist, and clear it on `/clear`-equivalent session reset. Nested walk must respect `.gitignore` (reuse the existing ignore matcher rather than re-implementing) and must not escape the workspace root. Footgun: `std.Io.Dir` walking in 0.16 - reuse `appendFromRoot`'s open/iterate pattern (`skills.zig:211-220`) and its `error.FileNotFound`/`NotDir`/`AccessDenied` swallow.

**Size.** M (sub-gap (b) nested discovery is the larger half; ship (a) first).

### skills-07 - skillify: capture the session as a reusable skill

**Goal.** A `skillify`-style flow that analyzes the current session (invoked skills, user messages, tool history), runs a multi-round AskUserQuestion interview (name/description, steps, inline-vs-fork, save location, per-step success criteria), then writes a `SKILL.md` with structured frontmatter to the chosen skills directory.

**Reference behavior + file:line.** `skills/bundled/skillify.ts:1-230` `SKILLIFY_PROMPT` + `registerSkillifySkill`: session-memory + user-messages analysis, multi-round `AskUserQuestion`, structured `SKILL.md` write. (Ant-gated in reference; we ship a local equivalent.)

**Target Zig files.** `src/core/bundled_skills.zig` (add a `skillify` bundled skill whose `prompt_template` is the authoring instruction prompt - this is the lowest-effort, most faithful local equivalent: a prompt-only skill that drives the model through the interview using the existing AskUserQuestion + Write tools); optionally a small `core/skillify.zig` helper for SKILL.md frontmatter assembly if we want deterministic generation. Register the bundled skill (already auto-registered via `appendBuiltinSkills`).

**Approach.**
1. Lowest-effort faithful path: add `skillify` to `bundled_skills.zig` with a `prompt_template` that instructs the model to (i) summarize the repeatable process from the current session, (ii) ask the user, one question at a time via AskUserQuestion, for name/description/when-to-use, the step list, inline-vs-fork, and save location (user `~/.zcode/skills` vs workspace `.zcode/skills`), (iii) assemble a valid `SKILL.md` (frontmatter + body) and Write it to `<chosen>/<name>/SKILL.md`, (iv) confirm by listing the new skill. This reuses every existing capability (AskUserQuestion, Write, the skill loader picks it up on next `list()`).
2. Optional determinism: add `core/skillify.zig` `pub fn renderSkillMd(spec fields) []u8` that produces canonical frontmatter (name, description, when-to-use, allowed-tools, context, paths) so the generated file always parses cleanly with `skill_types.parse`. Unit-test round-trip: `parse(renderSkillMd(x)) == x` for the supported fields.
3. Gate it the way the reference ant-gates it: register `skillify` only when an opt-in is set (config flag or env), so general users do not see it unless they enable authoring. This also seeds the `is_enabled` gate stub called for in skills-15's documented deviation.

**Acceptance criteria.** Tests: (a) if `core/skillify.zig` is built, `parse(renderSkillMd(fields))` round-trips name/description/when-to-use/allowed-tools/context/paths; (b) the `skillify` bundled skill is present in `list()` only when the authoring flag is enabled, absent otherwise; (c) the rendered SKILL.md is valid frontmatter (starts with `---`, parses without degrading to no-frontmatter handling).

**Test strategy.** `tools/test_runner.zig`. The interview itself is model-driven and not unit-tested; test the deterministic pieces (frontmatter render/round-trip, gated registration). Manual verification: run `/skill skillify` in the installed binary and confirm it drives the interview and writes a file.

**Risk + 0.16 footguns.** The prompt-only path has no Zig-side risk; the optional `renderSkillMd` must escape/avoid breaking frontmatter (no stray `---` in description; collapse newlines). Writing into `~/.zcode/skills` must create the directory tree first (`std.Io.Dir.createDirPath`). Keep the gate default-off so we do not surface an authoring tool to every user unprompted.

**Size.** L.

### skills-11 - hooks: frontmatter on skills (conditional)

**Goal.** Skills may declare a `hooks:` frontmatter block; on invocation those hooks are registered for the duration of the skill, then removed.

**Reference behavior + file:line.** `loadSkillsDir.ts:136-153` `parseHooksFromFrontmatter`, `259`, `343`; `bundledSkills.ts:90` bundled hooks.

**Target Zig files.** `src/core/skill_types.zig` (add a parsed `hooks` representation to `SkillSpec`), `src/agent_runtime.zig` (register on invoke / unregister after), `src/core/hook_config.zig` (reuse the existing hook representation).

**Approach (only if zcode supports dynamically-scoped hooks).**
1. First verify: does the hook system support adding hooks at runtime for a bounded scope, or is it settings.json-only? The audit notes hooks are currently global-config. If runtime registration is not supported, DEFER this gap (document it under deviations) - building dynamic-scope hook support is a hooks-phase concern, not skills.
2. If supported: parse the `hooks:` block in `skill_types.parse` into the existing hook config struct; in `tryExecuteSkillRun`, register before render/exec and unregister in a `defer`. Bundled skills carry the same field.

**Acceptance criteria.** If built: a skill with a `PreToolUse` hook in its frontmatter has that hook fire while the skill runs and not after. If deferred: documented under deviations with the specific blocker (no dynamic-scope hook API).

**Test strategy.** `tools/test_runner.zig` - register/unregister lifecycle test if built.

**Risk + 0.16 footguns.** High coupling to the hook subsystem; the YAML hooks block is nested (not flat frontmatter), and `skill_types` currently only parses flat keys - parsing a nested block needs a real (small) YAML sub-parse or a constrained format. This is the main reason it is low-priority and conditional.

**Size.** M.

### skills-12 - Symlink realpath dedup across roots

**Goal.** When the same canonical SKILL.md is reachable via multiple roots (symlink or overlapping parent dirs), load it once (first-wins) and skip the duplicate.

**Reference behavior + file:line.** `loadSkillsDir.ts:107-124` `getFileIdentity`/realpath; `725-769` dedup loop with logged skip.

**Target Zig files.** `src/core/skills.zig` (`upsert`/`appendFromRoot` - add a canonical-path set).

**Approach.** Maintain a `std.StringHashMapUnmanaged(void)` of realpaths during `list()`. In `loadFile`/`appendFromRoot`, resolve the SKILL.md path to its canonical form (`std.Io.Dir.realpath` equivalent in 0.16) and skip if already seen. Keep the existing name-based override (`upsert`) for genuine name collisions across roots - realpath dedup only suppresses same-file duplicates.

**Acceptance criteria.** Test: a skills root containing a symlink to another root's skill dir yields exactly one skill entry, not two; a genuine name collision across roots still applies last-wins override.

**Test strategy.** `tools/test_runner.zig` with `test_helpers.tmpDirCwd`; create a real dir + a symlink to it (skip the test gracefully if the platform/sandbox disallows symlink creation).

**Risk + 0.16 footguns.** realpath in 0.16 - find the correct `std.Io.Dir` API (likely `realpath`/`realpathAlloc`); handle `error.FileNotFound` by falling back to the literal path. Symlink creation in tests may be sandbox-restricted - guard with a `catch return` skip.

**Size.** S.

### skills-13 - aliases support

**Goal.** A skill (bundled or disk) may declare `aliases` (alternate invocation names); `findByName` matches any alias.

**Reference behavior + file:line.** `bundledSkills.ts:18` (`aliases?`), `79` (`aliases: definition.aliases`).

**Target Zig files.** `src/core/skill_types.zig` (`SkillSpec` - add `aliases: [][]u8`, parse `aliases` comma list), `src/core/bundled_skills.zig` (add `aliases` to `BundledSkill`, default empty), `src/core/skills.zig` (`findByName` checks `aliases`).

**Approach.** Add the field (init/clone/deinit/makeBuiltin all updated), parse via the existing `parseCommaList`, and extend `findByName` to also match any alias case-insensitively. Surface aliases in the detail view.

**Acceptance criteria.** Test: a skill with `aliases: cmt, ci` is found by `findByName("ci")`; the canonical name still wins on listing/sort.

**Test strategy.** `tools/test_runner.zig`; parse + findByName tests in the respective modules.

**Risk + 0.16 footguns.** Every `SkillSpec` literal (parse two branches, `makeBuiltin`, `mcpPromptToSkill`, the test `makeSpec`/`testSpec` builders in `skill_visibility.zig` and `skill_listing.zig`) must initialize the new field or the build fails - update all of them. This is the only real footgun: adding a struct field breaks every aggregate initializer.

**Size.** S.

## Documented deviations

- **skills-05 (file-watcher / hot-reload + ConfigChange firing).** zcode re-lists skills from disk on every `list()` call (`skills.zig:22-44`), so hot edits are already visible on the next tool round - the practical UX is achieved without a watcher. The genuine miss is firing `ConfigChange` hooks when a skills dir changes; the `ConfigChange` event is defined (`hook_event.zig:27,59`) and parsed (`hook_config.zig`) but never invoked. That firing belongs to the hooks phase, not skills. **Local stub worth doing:** when skills-11's hook work lands, add a single call site that fires `ConfigChange(query="skills")` after a detected skill-set change, even without a real chokidar-style watcher.
- **skills-06 (legacy /commands/ as skills + namespacing).** zcode deliberately keeps skills and commands as separate subsystems (`skills.zig` vs `commands.zig`); merging legacy commands into the skill set is an intentional divergence. The one genuinely behavioral piece - nested `a:b:c` namespaced skill dirs - is folded into skills-04's nested `.claude/skills` discovery rather than recreating `loadSkillsFromCommandsDir`.
- **skills-08 (bundled `files:` extraction + nonce'd root).** None of zcode's 6 bundled skills ship auxiliary scripts/assets, so the per-process nonce'd 0700 temp-dir extraction is not yet needed. **Local stub worth doing:** add the `files` field to `BundledSkill` as a no-op now (empty by default), and reuse skills-03's base-dir header machinery; defer the actual safe-extraction (O_NOFOLLOW|O_EXCL, traversal validation) until a bundled skill needs aux files.
- **skills-15 (feature-flagged bundled skills + remote skill search).** Out of scope per the cloud/computerUse exclusions: claude-in-chrome (computerUse), scheduleRemoteAgents and the EXPERIMENTAL_SKILL_SEARCH AKI/GCS remote backend are cloud-only. Local renames already cover loop/dream/schedule. **Local stub worth doing:** the per-skill `is_enabled` gating *mechanism* is genuinely absent - add a simple `enabled: fn() bool` (or a config-flag check) to `BundledSkill` registration so zcode can conditionally hide a bundled skill. skills-07's gated `skillify` registration is the first consumer of this stub.

## Verification

1. Build the release binary per CLAUDE.md and reinstall with a fresh inode (avoid the macOS in-place-cp code-signing SIGKILL):
   - `zig build -Doptimize=ReleaseFast`
   - `rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode`
   - Bump `.version` patch in `build.zig.zon` first (build appends the git short-hash automatically).
2. Run the full test suite under the custom runner: `zig build test` - confirm all new `RUN: <name>` tests pass and no existing skill tests regressed.
3. Manual checks against the installed binary:
   - skills-01: drop a `.zcode/skills/secret/SKILL.md` with `disable-model-invocation: true`; confirm a model `Skill action=run name=secret` returns the disable-model-invocation error, while `/skill secret` (user-typed) runs it.
   - skills-02: add a `deny Skill secret` permission rule; confirm the skill is blocked. Add `allow Skill foo:*`; confirm a `foo-bar` skill runs without a prompt. Confirm the 6 bundled skills still run with no prompt (safe-properties auto-allow).
   - skills-03: author a skill whose body contains `Read ${CLAUDE_SKILL_DIR}/notes.md` and `${CLAUDE_SESSION_ID}`; confirm both resolve and the `Base directory for this skill:` header appears.
   - skills-09: confirm `SLASH_COMMAND_TOOL_CHAR_BUDGET=200 zcode ...` shrinks the non-bundled listing while bundled skills keep full descriptions.
   - skills-10: a skill with `model: sonnet`/`effort: high` and `context: inline` changes the session model/effort; `model: inherit` does not; on an `opus[1m]` session a `model: opus` skill keeps `[1m]`.
   - skills-04: touch a `*.zig` file, confirm a `paths: *.zig` skill appears in the model listing and stays after touching a non-matching file next turn.
   - skills-07: `/skill skillify` (with the authoring flag enabled) drives the interview and writes a parseable SKILL.md; the new skill appears in `/skills`.
   - skills-13: a skill with `aliases: ci` is invocable as `/skill ci`.
4. Confirm no em/en dashes in any new code comments, generated SKILL.md templates, or user-facing messages (use plain hyphens).
