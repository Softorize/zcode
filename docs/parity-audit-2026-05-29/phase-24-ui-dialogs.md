# Phase 24: UI dialogs and interactive flows

## Overview

**What.** This phase closes the gap between zcode's set of interactive overlays and the Claude Code reference's family of startup gates, return-from-idle nudges, exit flows, feedback surveys, and shared dialog primitives. The reference renders these as React + Ink components funneled through `showSetupScreens()` in `interactiveHelpers.tsx`; zcode renders them as hand-rolled fullscreen overlay loops in `src/cli/repl_overlay.zig` driven from the REPL main loop in `src/cli/repl.zig`. The architectural mismatch is fine - what matters is behavioral parity for the user-facing security gates and UX nudges.

**Why.** The most important items here are *security-transparency* gates, not cosmetics. Three of them (TrustDialog first-run enumeration, BypassPermissionsMode warning, ManagedSettingsSecurity approval) are the human-in-the-loop step the reference enforces before letting the agent run with elevated/automated authority. zcode already has the *decision* infrastructure (trust store, bypass mode, hash-verified managed settings) but skips the *transparency* moment where the user is shown exactly which dangerous capabilities they are about to accept. The remaining items are UX polish (idle nudge, randomized goodbye, local feedback survey) and maintainability/abstraction items (design-system Dialog primitive, SelectMulti, wizard) that are lower priority.

**Dependencies on earlier phases.** This phase builds on already-shipped subsystems and does not block on a specific earlier phase, but it touches:
- The trust subsystem (`src/core/trust.zig`, `src/session_cmds.zig`) - any trust-related phase.
- The permission/approval subsystem (`src/core/approval.zig`, `src/core/permission_decision.zig`) for bypass and auto modes.
- The managed-settings/control-plane subsystem (`src/core/config_parse.zig`, `src/core/control_plane.zig`, `src/core/enterprise_doctor.zig`).
- The overlay framework (`src/cli/repl_overlay.zig`) - all new gates reuse `runApprovalOverlayLoop` / `runAskUserOverlayLoopWithBindings`.
- The memory/instructions loader (`src/core/instructions.zig`, `src/core/memory.zig`) for the CLAUDE.md external-includes gate.

**Effort.** Roughly one L (TrustDialog enumeration), one L (MCP server approval - largely deferable to an MCP parity round), three M (bypass gate, managed-settings gate, idle-return), and several S items. Realistic in-scope build: 2 L + 2 M + 2 S. Total estimated 9-12 working days if done serially; the gates are mostly independent and parallelizable.

## Scope split

| Item | Decision | Reason |
|---|---|---|
| ui-dialogs-01 TrustDialog first-run enumeration | **IN SCOPE** | Real security-transparency gap. The trust *decision* exists but the user never sees the dangerous capabilities (MCP servers, hooks, bash perms, helpers, dangerous env) before accepting. High-value parity. |
| ui-dialogs-02 BypassPermissionsMode warning gate | **IN SCOPE** | Real gap. Bypass mode auto-approves everything with no warning + no persisted skip flag. Strongest of the danger gates. |
| ui-dialogs-04 ManagedSettingsSecurity approval | **IN SCOPE** | Real gap. Managed settings are hash-verified then silently applied; the reference requires explicit accept/exit when dangerous keys are present. |
| ui-dialogs-03 AutoModeOptIn accept-default + copy | **IN SCOPE (S)** | Partial today. Cheap to add the third "make it my default" option, the reviewed copy, the docs link, and `permissions.defaultMode` persistence. |
| ui-dialogs-06 ExitFlow randomized goodbye | **IN SCOPE (S)** | Trivial cosmetic parity (random goodbye). WorktreeExitDialog-on-exit is the meaningful piece and is in scope as a small follow-on. |
| ui-dialogs-05 IdleReturnDialog | **IN SCOPE (M)** | Real gap, low severity. Usage-optimization nudge. Worth doing but ranks below the danger gates. |
| ui-dialogs-13 ClaudeMdExternalIncludesDialog | **IN SCOPE (M, conditional)** | Real gap *only if* our memory loader supports @-imports that can resolve outside the repo. Verify import containment semantics first; if all imports are already contained, downgrade to a documented deviation. |
| ui-dialogs-09 FuzzyPicker preview parity | **IN SCOPE (M, partial)** | Mostly done. Remaining deltas: GlobalSearch threshold 120 -> 140, History search missing side/bottom layout, syntax-highlighted file previews. Cosmetic; verify side-by-side before investing. |
| ui-dialogs-07 FeedbackSurvey (local rating only) | **PARTIAL IN SCOPE (S)** | Local 1-5 rating survey writing to local state is in scope. The cloud transcript-share submission is out of scope (see ui-dialogs-15). |
| ui-dialogs-10 design-system Dialog primitive | **OUT OF SCOPE (document)** | Maintainability/consistency only, no user-visible behavior gap. Worth a shared overlay-chrome helper *if* we add the 3 new gates; track as a refactor follow-up, not a parity requirement. |
| ui-dialogs-11 CustomSelect SelectMulti | **OUT OF SCOPE (document)** | Only needed when MCP/workflow multiselect dialogs are built. `.toggle` plumbing already exists. Defer to MCP parity round. |
| ui-dialogs-12 wizard/ multi-step provider | **OUT OF SCOPE (document)** | No multi-screen setup flow exists in zcode to host it. Build only when a wizard consumer appears. |
| ui-dialogs-14 MCPServerApprovalDialog | **OUT OF SCOPE here (defer to MCP round)** | ElicitationDialog already exists. MCPServerApprovalDialog + .mcp.json discovery/trust state is a substantial MCP-subsystem feature; belongs to the MCP parity phase, flagged here as a real gap. |
| ui-dialogs-08 MemoryUsageIndicator | **OUT OF SCOPE (document)** | Reference renders `null` in external builds, so zcode already matches external behavior. `/heapdump` exists. |
| ui-dialogs-15 TranscriptSharePrompt cloud upload | **OUT OF SCOPE (document)** | First-party phone-home to Anthropic. Local stub (write transcript to a file) is the honest equivalent and pairs with the local survey. |

## Gaps covered

| id | title | severity | size | our current state |
|---|---|---|---|---|
| ui-dialogs-01 | TrustDialog first-run capability enumeration | medium | L | CLI `/trust` commands + user-store trust check exist (`src/core/trust.zig:24`, `src/session_cmds.zig:696-807`); no interactive first-run overlay enumerating dangerous capabilities. |
| ui-dialogs-02 | BypassPermissionsMode warning gate | medium | M | `bypassPermissions` mode auto-approves (`src/core/approval.zig`, `src/core/permission_decision.zig`); no red warning, no `skipDangerousModePermissionPrompt` persistence. |
| ui-dialogs-04 | ManagedSettingsSecurity approval | medium | M | Managed settings hash-verified + silently applied (`src/core/config_parse.zig:48-213`); no dangerous-key extraction, no accept/exit gate. |
| ui-dialogs-03 | AutoModeOptIn accept-default + reviewed copy | low | S | Dialog exists (`src/cli/repl.zig:3782-3845`), persists `ui_auto_mode_opt_in_seen`; missing 3rd option, reviewed copy, docs link, `defaultMode` persistence, startup trigger. |
| ui-dialogs-06 | ExitFlow randomized goodbye + worktree branch | low | S | Static `"bye\n"` at `src/cli/repl.zig:6997`; no random goodbye, no worktree-on-exit prompt. |
| ui-dialogs-05 | IdleReturnDialog | low | M | Passive `"idle: waiting for your input"` hint + OS notification only; no idle tracking, no overlay, no never-ask preference. |
| ui-dialogs-13 | ClaudeMdExternalIncludesDialog | low | M | `@include`/`@import` loaded silently (`src/core/instructions.zig:464-510`); path-escape containment exists, no user approval. |
| ui-dialogs-09 | FuzzyPicker preview-pane parity | low | M | QuickOpen threshold correct; GlobalSearch uses 120 not 140; History search has no side/bottom layout; file previews not syntax-highlighted. |
| ui-dialogs-07 | FeedbackSurvey (local rating) | low | M | `/feedback` is static help text (`src/repl_commands.zig:1364-1377`); no rating UI, no survey state machine. |

## Implementation tasks

### Task 24.1 - TrustDialog first-run capability enumeration (ui-dialogs-01)

**Goal.** On the first interactive session in an untrusted workspace, render an overlay that enumerates every trust-relevant dangerous capability detected in the workspace, warns the user, and on accept persists trust + marks the session trusted - shown once per project.

**Reference behavior.**
- `TrustDialog.tsx:22-130` collects `getMcpConfigsByScope("project")`, `getHooksSources()`, `getBashPermissionSources()`, `getApiKeyHelperSources()`, `getAwsCommandsSources()`, `getGcpCommandsSources()`, `getOtelHeadersHelperSources()`, `getDangerousEnvVarsSources()`, plus `hasSlashCommandBash` / `hasSkillsBash` from `commands`.
- `interactiveHelpers.tsx:131-144`: fast path `if (!checkHasTrustDialogAccepted())` then `showSetupDialog<TrustDialog>`; afterwards `setSessionTrustAccepted(true)`.
- On accept (`TrustDialog.tsx:175-177`): `setSessionTrustAccepted(true)` + `saveCurrentProjectConfig({ hasTrustDialogAccepted: true })`.

**Target Zig files.**
- New deep module `src/core/trust_capabilities.zig` (register in `src/main.zig` comptime block) - pure enumeration: returns a struct listing which capabilities were detected and their source paths. No IO side effects beyond reading config/workspace.
- New overlay loop in `src/cli/repl_overlay.zig`: `runTrustGateOverlayLoop(...)` reusing the approval/ask-user chrome.
- Wiring in `src/cli/repl.zig` near the welcome-banner block (around `:5032-5149`) - before the first prompt is accepted, check trust and run the gate.
- Reuse `src/core/trust.zig` `status()` / `allow()` for the persisted decision.
- Use `@import("zcode_runtime")` for `rt.io` / `rt.gpa` in any module that does IO.

**Approach.**
1. In `trust_capabilities.zig`, define `pub const DetectedCapabilities = struct { mcp_servers: []const []const u8, hooks: []const []const u8, bash_permission_sources: []const []const u8, has_api_key_helper: bool, aws_commands: bool, gcp_commands: bool, otel_headers_helper: bool, dangerous_env_vars: []const []const u8, slash_command_bash: bool, skills_bash: bool, pub fn deinit(...) ... };` and `pub fn detect(allocator, cwd, config) !DetectedCapabilities`.
2. Implement each detector by reading the same sources zcode already loads: project `.mcp.json` / MCP config (whatever module owns MCP config discovery), hook sources (`src/core/hook_event.zig` config), bash permission rules (config permission lists), `apiKeyHelper`-equivalent config field, AWS/GCP/OTel helper config fields, and the env-var allowlist diff (any configured env var not in a SAFE set is dangerous - mirror `managedEnvConstants.SAFE_ENV_VARS`).
3. Add `pub fn anyDetected(self) bool` so the gate can decide whether to even show the dialog (reference always shows when untrusted, but listing zero capabilities is allowed).
4. In `repl_overlay.zig`, add a multi-line-body approval overlay: title `"Do you trust the files in this folder?"`, body that lists each detected capability one per line (only the names/paths, never secret values - mirror `formatDangerousSettingsList` which lists names only), then a Select with `["No, exit", "Yes, proceed"]`.
5. In `repl.zig`: when the session is interactive (not piped, not `-p`) and `trust.status(cwd).trusted == false`, call `trust_capabilities.detect`, then run the gate. On "Yes", call `trust.allow(cwd, null)` to persist and set an in-memory `session_trust_accepted = true`. On "No", exit cleanly (write nothing / exit code 1, matching reference `gracefulShutdownSync(1)` on decline).
6. Guard the whole block behind a skip-if-trusted fast path so it never re-renders for trusted repos (`checkHasTrustDialogAccepted` equivalent).

**Acceptance criteria.**
- Write a test in `trust_capabilities.zig` that builds a tmp workspace (`core/test_helpers.tmpDirPath`) containing a `.mcp.json` with one server, a hook config, and a dangerous env var, then asserts `detect()` returns exactly those three capabilities with correct source names and `anyDetected() == true`.
- Write a test that a clean workspace returns `anyDetected() == false`.
- Write a test that the dangerous-value redaction holds: the formatted body contains capability *names* but not secret *values*.
- Manual: launch zcode in an untrusted repo with a `.mcp.json`; confirm the gate lists the server and that choosing "Yes" makes `trust.status` return trusted on next launch (no re-prompt).

**Test strategy.** `tools/test_runner.zig` runs the `trust_capabilities.zig` `test` blocks with `rt` installed. Use `tmpDirPath` to get a real absolute workspace path - do NOT pass `"."` or `"repo"`.

**Risk + 0.16 footguns.** Do not pass relative cwd to filesystem walkers. When reading `.mcp.json` with `readFileAlloc(.limited(N))`, handle `error.StreamTooLong` (not `FileTooBig`). The env-var SAFE list must be kept in sync with `managedEnvConstants`; hardcode it as a comptime set in this module and add a comment pointing at the reference. Persisting trust via `trust.allow` writes to `~/.config/zcode/trust/repos.json` - in tests, point `HOME` at a tmp dir or test only the pure detector, not the persistence path.

**Size.** L.

---

### Task 24.2 - BypassPermissionsMode warning gate (ui-dialogs-02)

**Goal.** When the session launches in `bypassPermissions` mode and the user has not previously accepted, render a red warning gate explaining no approvals will be requested, with "No, exit" / "Yes, I accept"; on accept, persist a skip flag so it is never shown again.

**Reference behavior.**
- `BypassPermissionsModeDialog.tsx:12-86`: red `Dialog title="WARNING: Claude Code running in Bypass Permissions mode"`, body copy ("...will not ask for your approval before running potentially dangerous commands... only be used in a sandboxed container/VM..."), docs link `https://code.claude.com/docs/en/security`, Select `[{No, exit -> gracefulShutdownSync(1)}, {Yes, I accept -> updateSettingsForSource(userSettings, { skipDangerousModePermissionPrompt: true }) + onAccept}]`. Esc -> `gracefulShutdownSync(0)`.
- `interactiveHelpers.tsx:218-223`: gate fires when `(permissionMode === 'bypassPermissions' || allowDangerouslySkipPermissions) && !hasSkipDangerousModePermissionPrompt()`.

**Target Zig files.**
- `src/core/config.zig` - add a persisted boolean field `skip_dangerous_mode_permission_prompt: bool = false` (mirror naming convention of `ui_auto_mode_opt_in_seen`).
- `src/core/config_parse.zig` - add parse/persist support (`persistUserConfigField` already exists; add the field to the parser/serializer).
- `src/cli/repl.zig` - add the gate near the same startup region as the trust gate, after trust is established (matching reference ordering: trust first, then bypass).
- Reuse `runApprovalOverlayLoop` / a new red-titled variant in `src/cli/repl_overlay.zig`.

**Approach.**
1. Add `skip_dangerous_mode_permission_prompt` to the config struct + defaults + parse + persist.
2. In `repl.zig`, after the trust gate, if the active permission/approval mode equals bypass (check how `Options` carries the mode - `options.status_approval_mode` or the approval-mode field) AND `!config.skip_dangerous_mode_permission_prompt`, run the gate overlay.
3. Overlay: title `"WARNING: zcode running in Bypass Permissions mode"`, error/red color, body matching the reference copy (rewrite without em/en dashes), Select `["No, exit", "Yes, I accept"]`.
4. On accept: `config_parse.persistUserConfigField(allocator, "skip_dangerous_mode_permission_prompt", "true")` and continue. On decline/Esc: exit cleanly.

**Acceptance criteria.**
- Write a test that round-trips the config field: set `skip_dangerous_mode_permission_prompt = true`, persist, reload, assert it parses back as true.
- Write a test (logic-level, not TUI) for a `shouldShowBypassGate(mode, skip_flag)` pure helper: returns true only when mode==bypass and skip_flag==false.
- Manual: launch with bypass mode configured; confirm the red gate shows; accept; relaunch and confirm it does not re-show.

**Test strategy.** Config round-trip test under `tools/test_runner.zig` (point `HOME`/config dir at a tmp path). The TUI overlay itself is verified manually; the gate *decision* is unit-tested via the pure helper.

**Risk + 0.16 footguns.** Keep the danger copy free of em/en dashes (project rule). Ensure "No, exit" returns a non-zero-but-clean exit consistent with how zcode currently exits the REPL (do not call any reaped child). Make the gate fire before any tool can run.

**Size.** M.

---

### Task 24.3 - ManagedSettingsSecurity approval gate (ui-dialogs-04)

**Goal.** When managed settings (system/control-plane policy) contain dangerous keys, after the existing hash verification, surface the extracted dangerous setting *names* and require "Yes, I trust these settings" / "No, exit" before applying them.

**Reference behavior.**
- `ManagedSettingsSecurityDialog/utils.ts`: `extractDangerousSettings(settings)` collects dangerous shell settings (from `DANGEROUS_SHELL_SETTINGS`), dangerous env vars (any not in `SAFE_ENV_VARS`), and `hasHooks`. `formatDangerousSettingsList` returns **names only, never values**. `hasDangerousSettingsChanged(old, new)` only prompts when dangerous content was added or changed.
- `ManagedSettingsSecurityDialog.tsx:22-144`: lists the dangerous keys, Select accept/exit, Ctrl-C/D exit hints.

**Target Zig files.**
- New deep module `src/core/managed_settings_danger.zig` (register in `src/main.zig`) - pure: `extractDangerous(config_set) -> DangerousSettings`, `formatList(...) -> [][]const u8` (names only), `changedSince(old_hash_or_set, new_set) -> bool`.
- Wiring in `src/core/config_parse.zig` `load()` path (around `:48-213`) to compute the dangerous set after merge but record it for the REPL to gate on (do not block in `config_parse` itself - it is not interactive; return the info up to `repl.zig`).
- Gate overlay in `src/cli/repl_overlay.zig` + trigger in `src/cli/repl.zig` (after trust, before first prompt).
- Reuse `src/core/enterprise_doctor.zig` only as a reference for which keys are sensitive.

**Approach.**
1. Define the dangerous-key set: shell-execution settings (apiKeyHelper / awsAuthRefresh / otelHeadersHelper equivalents), dangerous env vars (env keys not in the SAFE set - reuse the same comptime SAFE set from Task 24.1), and presence of hooks. Mirror `DANGEROUS_SHELL_SETTINGS` + `SAFE_ENV_VARS` semantics.
2. `formatList` returns key names only - never values - and a test enforces this.
3. Implement "changed since last accepted" using a stored acceptance fingerprint (a hash of the formatted dangerous list) persisted in config so the gate only re-fires when the dangerous content actually changes (matching `hasDangerousSettingsChanged`).
4. In `repl.zig`, if there are dangerous managed settings and the fingerprint differs from the last accepted one, run the gate: title `"This workspace has managed settings that can run code or change behavior"`, body = `formatList`, Select `["No, exit zcode", "Yes, I trust these settings"]`. On accept, persist the new fingerprint and continue; on decline, exit.

**Acceptance criteria.**
- Write a test: a managed config set with a hooks block + a non-safe env var produces a dangerous list containing `["hooks", "<ENV_NAME>"]` and `anyDangerous() == true`.
- Write a test: a managed config set with only safe keys produces an empty list / `anyDangerous() == false`.
- Write a test: `formatList` output contains the env var *name* but not its *value*.
- Write a test: `changedSince` returns false when the fingerprint matches and true when a new dangerous key is added.
- Manual: deploy a `managed.toml` with hooks; confirm the gate lists `hooks`; accept; relaunch and confirm no re-prompt; add a dangerous env var and confirm the gate re-fires.

**Test strategy.** Pure-module tests under `tools/test_runner.zig`. Build the managed config set in-memory or from a tmp `managed.toml` via `tmpDirPath`.

**Risk + 0.16 footguns.** This must run only in interactive mode - never block `-p`/CI (the reference never reaches `showSetupScreens` non-interactively). The fingerprint persistence must survive config reload (test the round-trip). Keep the body names-only - leaking a managed secret value into the transcript would be a regression worse than the gap.

**Size.** M.

---

### Task 24.4 - AutoModeOptIn accept-default + reviewed copy (ui-dialogs-03)

**Goal.** Bring the existing AutoMode opt-in to parity: add the third "Yes, and make it my default mode" option, the reviewed description copy, the security docs link, and persist `permissions.defaultMode = auto` on accept-default. Optionally trigger at startup when the mode resolved to auto.

**Reference behavior.**
- `AutoModeOptInDialog.tsx:10` `AUTO_MODE_DESCRIPTION` (legally reviewed copy), `:33-62` three branches: `accept` -> persist `skipAutoPermissionPrompt`; `accept-default` -> persist `skipAutoPermissionPrompt` + `permissions.defaultMode='auto'`; `decline`. `:80-104` option list: accept-default present in external builds (`'external' !== 'ant'`), then accept, then decline labelled "No, exit" vs "No, go back" by `declineExits`.
- `interactiveHelpers.tsx:229-234`: startup gate when `permissionMode === 'auto' && !hasAutoModeOptIn()`.

**Target Zig files.**
- `src/cli/repl.zig:3782-3845` (`runAutoModeDialogUi`) - add third choice and reviewed copy.
- `src/core/config.zig` / `src/core/config_parse.zig` - add a persisted `default_mode` (or reuse the existing default-mode field if one exists) and ensure accept-default writes it.

**Approach.**
1. Add `make_default_choice = "Yes, and make it my default mode"` to the `choices` array (first position, mirroring the reference) when not in yolo/disable context.
2. Replace the terse `question` text with a reviewed-style description string (rewrite the reference copy without em/en dashes) plus a docs-link line in the body.
3. When `make_default` is selected: do the normal enable path AND persist the default mode (`persistUserConfigField(allocator, "default_mode", "auto")` or the existing config key).
4. Keep `ui_auto_mode_opt_in_seen` persistence as-is.
5. (Optional) Add a startup trigger so that if the resolved permission mode is auto and `!ui_auto_mode_opt_in_seen`, the dialog shows once on launch - matching the reference startup gate.

**Acceptance criteria.**
- Write a test that selecting the "make it my default" branch persists both the opt-in-seen flag and `default_mode == "auto"`, verified by reloading config.
- Write a test that selecting plain "enable" persists opt-in-seen but does NOT change `default_mode`.
- Manual: open the auto-mode dialog (`/yolo` or settings), confirm three options, confirm the docs link line is present.

**Test strategy.** Extract a pure helper for "which config writes happen for choice X" and unit-test it under `tools/test_runner.zig`, rather than driving the TUI.

**Risk + 0.16 footguns.** The reference gates `accept-default` on `USER_TYPE !== 'ant'`, which is always true in external builds - so zcode should always include it. Do not reword the copy with long dashes.

**Size.** S.

---

### Task 24.5 - ExitFlow randomized goodbye + worktree-exit branch (ui-dialogs-06)

**Goal.** Replace the static `"bye\n"` with a randomized goodbye, and when the session is inside a managed worktree, offer a worktree-exit prompt before quitting.

**Reference behavior.**
- `ExitFlow.tsx:6-26`: `GOODBYE_MESSAGES = ['Goodbye!','See ya!','Bye!','Catch you later!']`, `getRandomGoodbyeMessage()` via `sample`, then `gracefulShutdown(0,'prompt_input_exit')`.
- `:34-44`: when `showWorktree` is true, render `<WorktreeExitDialog onDone={onExit} onCancel={onCancel} />` first.

**Target Zig files.**
- `src/cli/repl.zig:6991-6999` (the `/exit` / `/quit` handler).
- Reuse `src/core/rng.zig` (`rng.bytes()`) for the random selection - do NOT use `std.crypto.random.*`.
- Worktree detection: reuse whatever module backs the worktree tools (`src/tools/tool_dispatch.zig:840-857` ExitWorktree); detect "are we in a zcode-managed worktree" and, if so, prompt.

**Approach.**
1. Define `const GOODBYE_MESSAGES = [_][]const u8{ "Goodbye!", "See ya!", "Bye!", "Catch you later!" };` in `repl.zig`.
2. Add `fn randomGoodbye() []const u8` that uses `rng.bytes()` to pick an index modulo the array length.
3. Replace `try writer.writeAll("bye\n")` with the chosen goodbye + newline.
4. For the worktree branch: detect whether cwd is inside a zcode-created worktree (check the worktree registry/marker the ExitWorktree tool uses). If so, run a small Select overlay ("Leave worktree as-is" / "Remove this worktree" / "Cancel") before exiting; on "Remove", invoke the existing ExitWorktree logic.

**Acceptance criteria.**
- Write a test that `randomGoodbye()` always returns one of the four strings (loop N times, assert membership).
- Manual: `/exit` prints a varied goodbye line across runs.
- Manual (worktree): inside a zcode worktree, `/exit` first offers the worktree prompt; "Remove" cleans it up; outside a worktree, exit is unchanged.

**Test strategy.** Unit-test `randomGoodbye` membership under `tools/test_runner.zig`. The worktree prompt is verified manually since it touches git state.

**Risk + 0.16 footguns.** Use `rng.bytes()` per project convention. The worktree-removal path runs `git worktree remove` - guard against removing a dirty worktree without confirmation. Avoid em/en dashes in the goodbye strings (they are fine as-is).

**Size.** S (goodbye) + small follow-on (worktree branch).

---

### Task 24.6 - IdleReturnDialog (ui-dialogs-05)

**Goal.** After the session has been idle past a threshold, when the user returns and submits, offer Continue / Clear-context-as-new / Don't-ask-again, with a header showing idle duration and conversation token count.

**Reference behavior.**
- `IdleReturnDialog.tsx:7-117`: actions `continue | clear | dismiss | never`; header `"You've been away {formatIdleDuration} and this conversation is {formatTokens} tokens."`; body `"If this is a new task, clearing context will save usage and be faster."`; Select Continue / "Send message as a new conversation" / "Don't ask me again". `formatIdleDuration` buckets `<1m`, `Nm`, `Nh`, `Nh Mm`.

**Target Zig files.**
- `src/cli/repl.zig` main loop - track `last_activity_nanos` (update on each prompt submission and each agent turn completion) using `src/core/clock.zig` (`clock.nowNanos()`), NOT `std.time.*`.
- New overlay loop in `src/cli/repl_overlay.zig`: `runIdleReturnOverlayLoop(...)`.
- `src/core/config.zig` / `src/core/config_parse.zig` - persisted `ui_idle_return_never_ask: bool`.
- Reuse `src/core/format.zig` `formatTokens` (`:70`) and `formatDuration` (`:78`); add `formatIdleDuration` if the bucketing differs.

**Approach.**
1. Record `last_activity_nanos` when the agent finishes a turn (the moment the session goes idle).
2. On the next user submission, if `(now - last_activity) >= IDLE_THRESHOLD` (reference uses a minutes-based threshold; pick a sane default, e.g. 30 minutes, and make it overridable) AND `!config.ui_idle_return_never_ask`, run the overlay before processing the input.
3. Overlay header uses `formatIdleDuration(minutes)` + `formatTokens(total_input_tokens)` (the session token counter already exists in cost/usage tracking - reuse it).
4. On `continue` -> proceed normally. On `clear` -> clear the conversation context (reuse the `/clear` path) then process the new input as a fresh conversation. On `never` -> persist `ui_idle_return_never_ask = true` then proceed. On Esc/dismiss -> proceed normally.

**Acceptance criteria.**
- Write a test for `formatIdleDuration`: `<1m`, `5m`, `1h`, `1h 5m` cases.
- Write a test for a pure `shouldShowIdleReturn(idle_nanos, threshold, never_flag)` helper.
- Write a test that the `never` choice persists `ui_idle_return_never_ask` (config round-trip).
- Manual: idle past threshold, submit, confirm the overlay with correct duration + token count; "clear" starts fresh; "never" suppresses future prompts.

**Test strategy.** Unit-test the formatter and the decision helper under `tools/test_runner.zig`; config round-trip with tmp HOME.

**Risk + 0.16 footguns.** Use `clock.nowNanos()` (project convention), not `std.time.nanoTimestamp`. `Io.Timeout.duration` wraps `Io.Clock.Duration` - if you compute durations through Io rather than raw nanos, account for the `{ .raw, .clock }` fields. The token count must come from the live session counter, not a re-tokenization. Low severity - do not let this block higher-priority gates.

**Size.** M.

---

### Task 24.7 - ClaudeMdExternalIncludesDialog (ui-dialogs-13) - CONDITIONAL

**Goal.** If our memory/instructions loader can resolve `@-includes` to files outside the workspace, prompt the user to approve loading that external memory before injecting it into context.

**Reference behavior.**
- `interactiveHelpers.tsx:164-170`: `if (await shouldShowClaudeMdExternalIncludesWarning())` -> `getExternalClaudeMdIncludes(getMemoryFiles(true))` -> `<ClaudeMdExternalIncludesDialog externalIncludes=... />`.

**Target Zig files.**
- `src/core/instructions.zig:464-510` (`@include` resolution) - already has containment checks at `:832-849`.
- `src/core/memory.zig:85-155`.

**Approach (gated on verification).**
1. **First, verify** whether `resolveImportPath` + the containment checks at `instructions.zig:832-849` already reject every out-of-repo path. The audit says containment "only prevents path escapes" but the loader rejects absolute paths, `..` segments, and home escapes. If containment already makes external includes *impossible*, this gap does not apply to zcode -> downgrade to a documented deviation (zcode is stricter than the reference: it refuses external includes outright rather than prompting).
2. If, and only if, the loader *does* permit some class of external includes (e.g. a configured allowed-dir outside the repo), add: a collector that returns the list of external include paths, and a startup gate (reusing the trust-gate chrome) that lists them and asks approve/decline before they are injected. Persist per-path approval.

**Acceptance criteria.**
- Write a test that confirms current containment behavior: an `@include` of an absolute path / `../` escape / home path is rejected by the loader (documents the stricter-than-reference stance).
- Only if external includes are possible: write a test that the collector returns exactly the external paths, and that decline prevents injection.

**Test strategy.** `tools/test_runner.zig` with a tmp workspace containing a ZCODE.md that `@include`s an out-of-tree path; assert rejection or gating.

**Risk + 0.16 footguns.** Likely outcome: zcode is already stricter (refuses external includes), so this becomes a documented deviation rather than a build. Confirm before writing UI. `readFileAlloc(.limited(N))` -> `error.StreamTooLong`.

**Size.** M (or downgraded to documentation after verification).

---

### Task 24.8 - FuzzyPicker preview-pane parity (ui-dialogs-09) - PARTIAL

**Goal.** Close the three remaining cosmetic deltas in the shared picker preview: GlobalSearch side/bottom threshold, History search side/bottom layout, and syntax-highlighted file previews.

**Reference behavior.**
- QuickOpen previewOnRight at `columns>=120`; GlobalSearch at `columns>=140`; History at `columns>=100`.
- File previews render via `HighlightedCode` (syntax highlighting) + `highlightMatch` + `truncatePathMiddle`; stale-preview dim `loading...` overlay; `visibleCount = rows - 14`.

**Target Zig files.**
- `src/cli/repl_overlay.zig`: GlobalSearch layout (`:5426`, `:5474-5477`) change threshold 120 -> 140; History search (`:3993-4007`) add side/bottom switching; file-preview rendering to call the existing syntax highlighter (the theme picker already syntax-highlights at `:3500+`).
- `src/cli/repl_global_search.zig` (`PREVIEW_CONTEXT_LINES`).

**Approach.**
1. **Verify side-by-side first** (the audit explicitly warns the survey may over-report). Run zcode and the reference in matching terminal widths and confirm the deltas are real before changing thresholds.
2. Change the GlobalSearch threshold constant to 140.
3. Add side/bottom layout to History search mirroring the QuickOpen logic, threshold 100.
4. Route file-content preview lines through the existing syntax-highlight helper used by the theme picker, reusing the language detection already present.

**Acceptance criteria.**
- Write a test for the layout-decision helper(s): `previewOnRight(cols)` returns the correct side/bottom decision at the QuickOpen(120)/GlobalSearch(140)/History(100) thresholds.
- Manual: at 130 columns, GlobalSearch preview is on the bottom (not right); at 150 it is on the right. History search switches layout by width.
- Manual: a `.zig`/`.ts` file preview shows syntax highlighting.

**Test strategy.** Extract pure `previewOnRight(kind, cols)` helpers and unit-test the thresholds under `tools/test_runner.zig`.

**Risk + 0.16 footguns.** Lowest-value item here - verify the deltas are real before investing. Syntax-highlighting previews can be slow on large files; keep the existing stale/loading dim behavior.

**Size.** M.

---

### Task 24.9 - FeedbackSurvey local rating (ui-dialogs-07) - PARTIAL

**Goal.** Turn the static `/feedback` stub into an interactive local 1-5 rating survey that writes to local state (no cloud submission).

**Reference behavior.**
- `FeedbackSurvey.tsx`: state machine `closed|open|thanks|transcript_prompt|submitting|submitted`; 1-5 digit input via `useDebouncedDigitInput`; thanks screen. (Transcript share is out of scope - see ui-dialogs-15.)

**Target Zig files.**
- `src/repl_commands.zig:1364-1377` (`/feedback`) - replace static help with a launcher for the survey overlay.
- New overlay loop in `src/cli/repl_overlay.zig`: `runFeedbackSurveyOverlayLoop(...)` - a 1-5 Select + a thanks screen.
- Local persistence: append the rating + optional note to a local file under the zcode state dir (e.g. `~/.zcode/feedback.jsonl`), reusing `src/core/clock.zig` for the timestamp.

**Approach.**
1. Overlay: prompt "How would you rate zcode? (1-5)", a Select of `1 2 3 4 5`, then an optional free-text note line, then a "Thanks!" screen.
2. On submit, append a JSONL record `{ ts, rating, note, version }` to the local feedback file. Keep the existing GitHub-issues pointer text as a footer.
3. No network calls.

**Acceptance criteria.**
- Write a test that submitting a rating appends a well-formed JSONL line to a tmp feedback path and that the rating value is preserved.
- Manual: `/feedback` opens the rating overlay; selecting 4 + a note writes a record; the thanks screen shows.

**Test strategy.** Unit-test the "record a rating" function (pure-ish, writes to a path you pass in) under `tools/test_runner.zig` with `tmpDirPath`.

**Risk + 0.16 footguns.** Keep it strictly local - no phone-home. `File ObjectMap.put` footgun does not apply (append, not parse-then-mutate). Use `clock.nowMillis()` for the timestamp.

**Size.** S-M.

## Documented deviations

These are intentional deviations from the reference. Each is recorded so future audits do not re-flag them as regressions.

- **ui-dialogs-10 design-system Dialog primitive.** zcode hand-rolls each overlay's chrome (`renderApprovalOverlay`, `renderAskUserOverlay`, etc.) rather than sharing a `Dialog` primitive with theme-keyed color, a `Byline` input guide, and unified Ctrl-C/D pending state. This is a maintainability/consistency gap, not a behavior gap - every overlay works today. **Recommended local follow-up:** if Tasks 24.1-24.3 land three new gates, factor a shared `overlayChrome(title, color, body_lines, options, hints)` helper in `repl_overlay.zig` to avoid copy-pasting border/title/hint logic across the bypass/managed/trust gates. Do this as a refactor *after* the gates work, not before.

- **ui-dialogs-11 CustomSelect SelectMulti.** No multi-select primitive; all pickers return a single `?usize`. The `.toggle` `PickerEvent` is already plumbed (defined at `repl_overlay.zig:1231`, currently a no-op in every loop), so adding a multi-select loop is incremental. **Out of scope until** an MCP-server-multiselect or workflow-multiselect dialog is actually built; tie this to the MCP parity round.

- **ui-dialogs-12 wizard/ multi-step provider.** No back-navigable multi-step flow exists in zcode (onboarding is a static checklist in `core/onboarding.zig`; all overlays are single-screen). The reference's wizard consumers are install/onboarding flows. **Out of scope until** a genuine multi-screen setup flow is needed; building the abstraction with no consumer would violate the simplicity rule.

- **ui-dialogs-14 MCPServerApprovalDialog.** ElicitationDialog already exists and is functional (`agent_history.zig:902-1149`). The missing piece is gating newly-discovered `.mcp.json` servers before first connection, plus the server trust/enable/disable state machine. This is a substantial MCP-subsystem feature. **Deferred to the MCP parity phase** - flagged here as a real gap so it is not lost, but it belongs with the rest of the `.mcp.json` discovery/trust work, not in this UI-dialogs phase.

- **ui-dialogs-08 MemoryUsageIndicator / /heapdump.** The reference component renders `null` in all external (non-ant) builds, so zcode already matches external behavior by *not* showing a polling indicator. `/heapdump` exists on demand (`repl_commands.zig:1847-1849`, `core/heap_diag.zig`). **Out of scope as a parity requirement.** Optional nice-to-have: a best-effort single-line "high memory usage" warning when RSS crosses a threshold, but not required.

- **ui-dialogs-15 TranscriptSharePrompt cloud upload.** A first-party upload of the full conversation transcript to Anthropic. **Out of scope** - zcode is provider-neutral and should not phone home to one vendor. **Local stub worth doing** (pairs with Task 24.9): a `/feedback --attach` or survey option that writes the current transcript to a local file (reusing the existing `shareSession`/bundle path that writes to `~/.zcode/shares/`) the user can manually attach to a GitHub issue. Honest local equivalent, no telemetry.

## Verification

After each in-scope task, and once at the end of the phase:

1. **Bump version.** Edit `.version = "X.Y.Z"` in `build.zig.zon` (patch bump per change). `build.zig` appends the git short-hash automatically - do not edit `computeVersionString`.

2. **Build release + install** (per CLAUDE.md, including the macOS code-signature footgun):
   ```
   zig build -Doptimize=ReleaseFast
   rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode
   ```
   The `rm -f` is mandatory - overwriting in place invalidates the ad-hoc signature and the next run is SIGKILLed (exit 137) with no output.

3. **Run the test suite:** `zig build test` (custom runner `tools/test_runner.zig` installs `rt.io`/`rt.gpa` and prints `RUN: <name>` before each test). Confirm all new `test` blocks pass.

4. **Manual checks (per task):**
   - Trust gate (24.1): launch in an untrusted repo with a `.mcp.json` + hook + dangerous env var; confirm the gate enumerates exactly those, "Yes" persists trust, relaunch does not re-prompt; verify no secret *values* appear in the body.
   - Bypass gate (24.2): launch in bypass mode; confirm the red warning; accept; relaunch does not re-prompt.
   - Managed settings gate (24.3): deploy a `managed.toml` with hooks + a non-safe env var; confirm the gate lists `hooks` + the env name (not value); accept; relaunch silent; add a key and confirm re-fire.
   - AutoMode (24.4): three options present, docs-link line present, "make default" persists `default_mode=auto`.
   - Exit (24.5): `/exit` prints a varied goodbye; inside a worktree it offers the worktree-exit prompt.
   - Idle (24.6): idle past threshold, submit, confirm overlay with correct duration + token count; "never" suppresses.
   - Feedback (24.9): `/feedback` opens the rating overlay; a submitted rating lands in the local feedback file.

5. **Regression sweep:** confirm `-p` / piped / CI mode never renders any of the new gates (they must be interactive-only, matching the reference which never reaches `showSetupScreens` non-interactively).

6. **Wiki checkpoint:** record the gate ordering decision (trust -> bypass -> managed -> auto, mirroring `interactiveHelpers.tsx`), the names-only redaction rule for the danger gates, and the "zcode refuses external CLAUDE.md includes rather than prompting" deviation (if 24.7 confirms the stricter stance) in `wiki/`.
