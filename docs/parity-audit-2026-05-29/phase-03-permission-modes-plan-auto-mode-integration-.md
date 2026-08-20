# Phase 3: Permission modes, plan/auto mode integration, accept-edits bash auto-allow

## Overview

**What.** This phase wires the five Claude Code permission modes
(`default`, `acceptEdits`, `plan`, `bypassPermissions`, `dontAsk`) into the
live interactive loop, makes them reachable the way the reference makes them
reachable (Shift+Tab cycling with a visible mode banner), strips overly-broad
allow rules when entering an auto/plan-class mode, and extends `acceptEdits`
to auto-allow a fixed set of filesystem bash commands the way the reference's
`checkPermissionMode` does.

**Why.** Phase 2 delivered the decision engine: `core/permission_decision.zig`
`decide()` already encodes correct per-mode semantics, and `core/approval.zig`
`evaluate()` already dispatches the reference mode names. The verified gaps are
that the engine is never *driven* by an interactive permission mode. Today
Shift+Tab cycles a completely separate concept (`SessionMode` =
execution/planning/brainstorm/review in `cli/repl.zig:54-59`) and the live
config mode is one of zcode's legacy strings (`tiered-auto`/`manual`/`strict`,
plus the `yolo` flag). The reference modes are dead-reachable from config text
but not from the keyboard, and three behaviors are absent entirely:

- `permissions-06`: `cyclePermissionMode` / `getNextPermissionMode` /
 `transitionPermissionMode`, the `confirm_cycle_mode` dispatch handler, and a
 mode banner.
- `permissions-08`: dangerous-permission stripping on auto/plan entry and
 restoration on exit (`DANGEROUS_BASH_PATTERNS`, strip/restore).
- `bash-shell-09`: `acceptEdits` bash auto-allow for
 `mkdir/touch/rm/rmdir/mv/cp/sed` via compound-command splitting.

**Dependencies.** Phase 2 (the `permission_decision.decide()` engine,
`approval.evaluate()` dispatch on reference mode names, and the
`permission_rules.Store`). This phase consumes all three. No work in this phase
should re-derive decision semantics; it only feeds the engine a live mode and
keeps the rule store honest across mode transitions.

**Effort.** M overall. Task sizes: permissions-06 is M, permissions-08 is M,
bash-shell-09 is S. The new pure modules (`core/permission_mode_cycle.zig`,
`core/dangerous_permissions.zig`, `core/bash_mode_allow.zig`) are small and
fully unit-testable; the cost is the wiring into `cli/repl.zig`,
`agent_tools.zig`, and `agent_runtime.zig`.

## Gaps covered

| id | title | severity | size | our current state |
|---|---|---|---|---|
| permissions-06 | Shift+Tab permission-mode cycling (getNextPermissionMode / cyclePermissionMode) | medium | M | PARTIAL. The 5 modes + `decide()` exist (`core/permission_decision.zig:13-19, 59-89`) and `approval.evaluate()` dispatches reference mode names (`core/approval.zig:49-71`). But Shift+Tab cycles `SessionMode` (execution/planning/brainstorm/review) via `togglePrimaryMode` (`cli/repl.zig:446-453`, dispatched at `cli/repl.zig:6095-6102`), NOT permission modes. No `cyclePermissionMode`/`getNextPermissionMode`/`transitionPermissionMode`. The `confirm_cycle_mode` action is defined (`cli/keybindings.zig:567, 891`) but has zero dispatch handler. The approval overlay (`cli/repl_overlay.zig:403-441`) only offers Approve/Always/Deny/Cancel. |
| permissions-08 | Dangerous-permission stripping when entering auto/plan mode | low | M | ABSENT. `core/permission_rules.zig` has add/remove/match only; no stripping, no `DANGEROUS_BASH_PATTERNS`, no save/restore. `agent_runtime.zig` loads the rule store once and never mutates it on mode change. Planning mode restricts tools by *schema filtering + dispatch blocking* (`agent_runtime.zig:879-881, 906-909, 1744-1753`), which is unrelated to allow-rule stripping. |
| bash-shell-09 | Accept-edits mode auto-allow for filesystem bash commands | low | S | ABSENT at the bash level. `acceptEdits` auto-allows only `isEditTool` names (`core/approval.zig:15-24`, `core/permission_decision.zig:84`). No code extracts a bash base command or splits compound commands. The only `&&` reference in `agent_tools.zig` is in a doc string (`agent_tools.zig:3331`). |

## Implementation tasks

The tasks are ordered so the pure modules land first (independently testable),
then the wiring. Tasks 1, 4, and 6 (the three new pure `core/` modules) have no
shared files and can be implemented in parallel. Tasks 2, 3, 5, 7 are the
wiring and must follow their respective module.

---

### Task 1: Pure permission-mode cycle module (`getNextPermissionMode`)

**Goal.** A pure, allocation-free function that returns the next permission
mode for Shift+Tab, mirroring the reference cycle order.

**Reference behavior + file:line.**
`getNextPermissionMode.ts:34-79` - `default -> acceptEdits -> plan -> default`
for normal users; `plan` advances to `bypassPermissions` only when
`isBypassPermissionsModeAvailable`; `bypassPermissions -> default`; `dontAsk`
and any unknown fall back to `default`. The ant-only `auto` branch and the
`canCycleToAuto`/`TRANSCRIPT_CLASSIFIER` gate (`getNextPermissionMode.ts:17-49`)
are out of scope for zcode (auto mode is feature-gated and ant-only) and are
deferred - see Out-of-scope notes.

**Target Zig files.**
- Create `src/core/permission_mode_cycle.zig` (deep `core/` module: pure logic,
 no IO, no allocation).
- Register in `src/main.zig` comptime block (insert
 `_ = @import("core/permission_mode_cycle.zig");` near the existing
 `_ = @import("core/permission_decision.zig");` at `src/main.zig:94`) so the
 custom test runner discovers its tests.

**Approach.**
1. Import `permission_decision.zig` and reuse its `Mode` enum
 (`default/acceptEdits/plan/bypassPermissions/dontAsk`). Do NOT define a
 second mode enum.
2. `pub fn getNext(current: Mode, bypass_available: bool) Mode` implementing the
 reference switch:
 - `.default => .acceptEdits`
 - `.acceptEdits => .plan`
 - `.plan => if (bypass_available) .bypassPermissions else .default`
 - `.bypassPermissions => .default`
 - `.dontAsk => .default`
3. Add `pub fn label(mode: Mode) []const u8` and
 `pub fn shortLabel(mode: Mode) []const u8` returning the reference titles
 from `PermissionMode.ts:42-91` (`"Default"`, `"Accept edits"`/`"Accept"`,
 `"Plan Mode"`/`"Plan"`, `"Bypass Permissions"`/`"Bypass"`,
 `"Don't Ask"`/`"DontAsk"`). The cycle banner uses these.

**Acceptance criteria.**
- Write a test `getNext follows reference cycle order` asserting:
 `getNext(.default, false) == .acceptEdits`, `getNext(.acceptEdits, false) == .plan`,
 `getNext(.plan, false) == .default`, `getNext(.plan, true) == .bypassPermissions`,
 `getNext(.bypassPermissions, false) == .default`,
 `getNext(.bypassPermissions, true) == .default`,
 `getNext(.dontAsk, false) == .default`.
- Write a test `label and shortLabel match reference titles` covering all five
 modes.

**Test strategy.** Unit tests inline in `core/permission_mode_cycle.zig`, run
under `tools/test_runner.zig` via `zig build test`. Pure functions, no fixtures.

**Risk / footguns.** None of the 0.16 IO gotchas apply (no IO, no allocation).
Only footgun: do not introduce a parallel `Mode` enum - import the canonical one
from `permission_decision.zig` to keep `decide()` and the cycle in lockstep.

**Size estimate.** S.

---

### Task 2: Thread a live permission mode through the session and approval gate

**Goal.** Give the REPL a mutable permission-mode state, default it from
`cfg.approval_mode`, and feed it into `approval.evaluate()` so the reference
modes actually drive decisions at runtime.

**Reference behavior + file:line.** `ToolPermissionContext.mode` is the single
live mode the whole permission flow reads (`getNextPermissionMode.ts:38`,
`modeValidation.ts:39`). zcode currently passes `ctx.cfg.approval_mode` (a fixed
string) into `approval_mod.evaluate()` at `agent_tools.zig:681-682`.

**Target Zig files.**
- `src/cli/repl.zig` - add a `permission_mode: permission_decision.Mode` REPL
 state variable alongside the existing `var mode: SessionMode` at
 `cli/repl.zig:5191`. Initialize it from `cfg.approval_mode` via
 `permission_decision.modeFromString` when the config carries a reference mode
 name, else leave it at the engine default (`.default`) so legacy
 `tiered-auto`/`manual`/`strict` users are unaffected.
- `src/agent_runtime.zig` - the `RunContext`/handler that builds the
 `agent_tools` call context already carries `cfg`. Add an optional
 `permission_mode_override: ?permission_decision.Mode` field threaded from the
 REPL into the tool-call context so the gate can prefer it over the config
 string. (Search anchor: the context is assembled near `agent_runtime.zig:384`
 where rules load, and the handler signature at `cli/repl.zig:82`.)
- `src/agent_tools.zig` - at the `approval_mod.evaluate(ctx.cfg.approval_mode, …)`
 call (`agent_tools.zig:681-691`), compute the effective mode string: if a
 `permission_mode_override` is present, pass its reference name
 (`@tagName`-equivalent via a small `permission_decision.modeToString`); else
 keep `ctx.cfg.approval_mode`.

**Approach.**
1. Add `pub fn modeToString(mode: Mode) []const u8` to
 `core/permission_decision.zig` returning the canonical reference spellings
 (`"default"`, `"acceptEdits"`, `"plan"`, `"bypassPermissions"`, `"dontAsk"`)
 so the existing `isReferenceModeName`/`modeFromString` round-trips. Add a
 round-trip unit test there.
2. In `cli/repl.zig`, introduce `var permission_mode` and seed it. Pass it down
 the same handler boundary that already passes `SessionMode mode`
 (`Handler.call` at `cli/repl.zig:82`). The cleanest minimal change is a new
 optional field on the existing options/context struct rather than a new
 positional arg.
3. In `agent_tools.zig`, prefer the override when set. This keeps a single
 decision site; do not branch the gate logic.

**Acceptance criteria.**
- Write a test in `core/permission_decision.zig`:
 `modeToString round-trips through modeFromString` for all five modes, and
 `isReferenceModeName(modeToString(m))` is true for the four reference modes
 and the `default` string maps back to `.default`.
- Write an `agent_tools` (or a focused harness) test asserting that when the
 effective mode is `"acceptEdits"`, a `Write` invocation is auto-approved and a
 `Bash` invocation at MEDIUM is not (this exercises the override path end to
 end through `evaluate`). Reuse the existing `approval.zig` test pattern at
 `core/approval.zig:171-181`.

**Test strategy.** Unit tests under `tools/test_runner.zig`. The `agent_tools`
gate already has surrounding tests; add a minimal one that constructs a context
with the override set. Avoid spinning a real model - call the gate function
directly.

**Risk / footguns.**
- Do NOT widen `isKnownApprovalMode` (`core/config.zig:389-394`) to accept the
 reference names unless you also intend the *persisted* config to carry them.
 The live mode is session state; persisting is a separate concern (see Task 3).
 If you skip widening, ensure the seed in step 2 tolerates an unknown
 `approval_mode` by falling back to `.default`.
- Keep the legacy path intact: when no override is set, `agent_tools.zig` must
 pass `ctx.cfg.approval_mode` byte-for-byte so `tiered-auto`/`manual`/`strict`
 behavior is unchanged.

**Size estimate.** M.

---

### Task 3: Shift+Tab dispatch handler + mode banner (`confirm_cycle_mode` and chat-mode separation)

**Goal.** Make Shift+Tab cycle the *permission* mode with a visible banner, and
make the approval overlay's `confirm_cycle_mode` action functional.

**Reference behavior + file:line.**
- `cyclePermissionMode` (`getNextPermissionMode.ts:88-101`) computes the next
 mode AND prepares the context for it via `transitionPermissionMode`.
- The mode is surfaced as a status symbol/title (`PermissionMode.ts:42-91`).
- Shift+Tab during a confirmation cycles the mode (`confirm_cycle_mode` in our
 `cli/keybindings.zig:567, 891`, mirroring the reference's confirmation
 shortcut).

**Target Zig files.**
- `src/cli/repl.zig`:
 - There are TWO `shift+tab` bindings today: `.Chat` -> `.chat_cycle_mode`
 (`cli/keybindings.zig:822`) and `.Confirmation` -> `.confirm_cycle_mode`
 (`cli/keybindings.zig:891`). `.chat_cycle_mode` currently routes to
 `.toggle_mode` (`cli/repl_input.zig:264`), which cycles `SessionMode`.
 DECISION REQUIRED (state it explicitly in the PR, per the "surface
 tradeoffs" rule): zcode's `SessionMode` (execution/planning/brainstorm/
 review) is a real, shipped feature, while the reference uses Shift+Tab for
 permission modes. The minimal, lowest-risk change is to leave the in-chat
 Shift+Tab on `SessionMode` (do not break a shipped behavior) and implement
 the reference permission-mode cycle on the `confirm_cycle_mode` path inside
 the approval overlay, which today does nothing. This satisfies the verified
 gap ("Shift+Tab permission-mode cycling during interactive confirmation is
 entirely absent") without regressing `SessionMode` cycling. If the user
 later wants Shift+Tab in chat to mean permission mode, that is a one-line
 `cli/repl_input.zig:264` remap - note it as a deferred toggle.
 - Add a `.toggle_permission_mode` action result handler. On trigger:
 `permission_mode = permission_mode_cycle.getNext(permission_mode, bypass_available)`,
 then `transitionPermissionMode(old, new)` (Task 5), then set a hint banner
 using `permission_mode_cycle.shortLabel(permission_mode)` exactly like the
 existing `.toggle_mode` banner at `cli/repl.zig:6095-6102`.
 - `bypass_available`: derive from a config flag (reference uses
 `isBypassPermissionsModeAvailable`). zcode's nearest equivalent is the
 `yolo`/dangerous flag surface; gate `bypassPermissions` behind the same
 flag that already enables yolo so a normal session cycles
 `default -> acceptEdits -> plan -> default`.
- `src/cli/repl_overlay.zig`:
 - Extend `runApprovalOverlayLoop` (`cli/repl_overlay.zig:403-441`) to handle a
 `cycle_mode` nav event. Add a `cycle_mode` arm to the `ApprovalChoice` /
 nav-event handling so Shift+Tab inside the overlay returns a sentinel the
 caller maps to "re-evaluate under the next permission mode" (or, simpler,
 have the overlay take a `*permission_decision.Mode` pointer it mutates and
 redraws the prompt header with the new mode label, looping in place).
 - Update `renderApprovalOverlay` (`cli/repl_overlay.zig:443+`) to render the
 active permission-mode short label in the overlay header so the user sees
 the mode change.
- `src/cli/repl_input.zig`:
 - Map `.confirm_cycle_mode` to the new `.toggle_permission_mode` editor action
 (today it falls through to `fallback` because there is no arm in the switch
 at `cli/repl_input.zig:253-298`).

**Approach.**
1. Add `toggle_permission_mode` to the editor-action enum that
 `cli/repl_input.zig` returns, and the `.confirm_cycle_mode => .toggle_permission_mode`
 arm.
2. Implement the dispatch in `cli/repl.zig`'s main loop next to `.toggle_mode`.
3. Make the approval overlay loop redraw with the live mode label and let
 Shift+Tab change it in place, then re-run `permission_decision.decide` for
 the pending tool under the new mode (so cycling to `bypassPermissions`
 immediately approves, cycling to `plan` immediately denies a HIGH tool, etc.).
4. Reuse the existing banner/hint plumbing (`setHint`) so the change is visible
 and consistent with `.toggle_mode`.

**Acceptance criteria.**
- Write a unit test for the dispatch mapping: feeding the `confirm_cycle_mode`
 binding through the `cli/repl_input.zig` resolver returns
 `.toggle_permission_mode` (mirror the style of existing keybinding-resolution
 tests).
- Write a unit test (overlay logic factored into a pure helper) that, given an
 initial mode and N Shift+Tab presses, the resulting mode equals
 `getNext` applied N times. Keep the terminal-draw code out of the tested unit;
 test the state machine, not the ANSI output.
- Manual: in an interactive session, trigger a tool that asks; press Shift+Tab
 inside the overlay; confirm the header shows the new mode short-label and the
 decision flips accordingly (e.g. `bypassPermissions` auto-approves).

**Test strategy.** Pure-state tests under `tools/test_runner.zig` for the
mapping and the cycle state machine; manual TUI verification for the visible
banner and the live re-decision.

**Risk / footguns.**
- Do not break `SessionMode` cycling. The in-chat Shift+Tab stays as-is unless
 the user opts into the remap.
- The approval overlay reads bytes from stdin directly
 (`cli/repl_overlay.zig:380-399, 404`). Shift+Tab arrives as a CSI sequence
 (`ESC [ Z` for back-tab); ensure the overlay's nav reader recognizes back-tab
 and routes it to `cycle_mode`, not to a literal character insert. This mirrors
 the macOS-option-char swallowing concern documented in
 `cli/keybindings.zig:453-484`.
- Keep the overlay's safety default (`selected = 2` = Deny,
 `cli/repl_overlay.zig:405`) - cycling the mode must not change the selected
 button, only the mode the decision is evaluated under.

**Size estimate.** M.

---

### Task 4: Pure dangerous-bash-permission predicate + pattern list

**Goal.** A pure module that decides whether an allow-rule's bash content is
"dangerous" (would let the model run arbitrary code, bypassing the classifier).

**Reference behavior + file:line.**
- `dangerousPatterns.ts:18-80` - `CROSS_PLATFORM_CODE_EXEC` (interpreters,
 package runners, shells, ssh) plus `DANGEROUS_BASH_PATTERNS` (adds
 `zsh`/`fish`/`eval`/`exec`/`env`/`xargs`/`sudo`; the ant-only extras
 `coo`/`gh`/`curl`/`wget`/`git`/`kubectl`/`aws`/`gcloud`/`gsutil` are gated on
 `USER_TYPE === 'ant'` and are out of scope for zcode).
- `permissionSetup.ts:94-147` - `isDangerousBashPermission`: tool-level allow
 (empty content or `*`) is dangerous; otherwise match the rule content against
 each pattern in five shapes: exact (`python`), prefix (`python:*`), wildcard
 (`python*`), space-wildcard (`python *`), and flag-wildcard
 (`python -…*`).

**Target Zig files.**
- Create `src/core/dangerous_permissions.zig` (pure `core/` module).
- Register in `src/main.zig` comptime block (next to the other `core/`
 permission imports around `src/main.zig:94`).

**Approach.**
1. `pub const CROSS_PLATFORM_CODE_EXEC = [_][]const u8{ … };` and
 `pub const DANGEROUS_BASH_PATTERNS = CROSS_PLATFORM_CODE_EXEC ++
 [_][]const u8{ "zsh", "fish", "eval", "exec", "env", "xargs", "sudo" };`
 (comptime concat). Omit the ant-only entries (zcode has no `USER_TYPE=ant`
 notion); note this in a comment.
2. `pub fn isDangerousBashContent(content: []const u8) bool` implementing the
 five-shape matcher. Lowercase comparison (the reference lowercases content).
 Empty or `"*"` -> true.
3. The reference predicate keys on `toolName === BASH_TOOL_NAME`. In zcode the
 caller already knows the rule's tool, so this module takes only the content
 and the caller checks the tool name is the bash tool
 (`agent_tools.zig`/`tool_name_map.zig` know the canonical bash tool name).

**Acceptance criteria.**
- Write a test `isDangerousBashContent matches all five rule shapes` asserting
 true for `""`, `"*"`, `"python"`, `"python:*"`, `"python*"`, `"python *"`,
 `"python -c*"`, `"node:*"`, `"sudo:*"`, `"eval"`, and false for safe content
 like `"git status"`, `"ls"`, `"npm test"`, `"echo hi"`.
- Edge: `"PYTHON:*"` (uppercase) must match (case-insensitive).

**Test strategy.** Inline unit tests under `tools/test_runner.zig`. Pure, no IO.

**Risk / footguns.** Comptime array concatenation: use `++` on two
`[_][]const u8` literals at comptime, not a runtime append. No 0.16 IO gotchas
apply (pure module).

**Size estimate.** S.

---

### Task 5: Strip / restore dangerous allow rules on plan/auto mode entry/exit (`transitionPermissionMode`)

**Goal.** When entering a restrictive mode (`plan`, and `auto` if/when added),
stash and remove any active allow rules whose bash content is dangerous, so a
broad `Bash(*)` / `Bash(python:*)` rule cannot bypass the mode. Restore them on
exit.

**Reference behavior + file:line.**
- `permissionSetup.ts:472-503` - `removeDangerousPermissions` groups dangerous
 rules by source and removes them from the in-memory context.
- `permissionSetup.ts:510-553` - `stripDangerousPermissionsForAutoMode` collects
 the dangerous rules, logs them, stashes their string forms in
 `strippedDangerousRules`, and returns the cleaned context.
- `permissionSetup.ts:561-579` - `restoreDangerousPermissions` re-adds the
 stashed rules and clears the stash, so a second exit is a no-op.
- `cyclePermissionMode` calls `transitionPermissionMode(old, new, ctx)`
 (`getNextPermissionMode.ts:95-99`) which performs strip-on-enter /
 restore-on-exit.

**Target Zig files.**
- `src/core/permission_rules.zig` - add three methods on `Store`:
 - `pub fn stripDangerous(self: *Store, allocator) ![]Rule` - remove every
 `allow` rule whose tool is the bash tool and whose `args_contains` content
 `dangerous_permissions.isDangerousBashContent` flags, returning the removed
 rules (owned by caller) as the stash. Reuse `removeAt` /`orderedRemove`
 semantics (`core/permission_rules.zig:172-176`).
 - `pub fn restoreStashed(self: *Store, stash: []Rule) !void` - re-append the
 stashed rules (transfer ownership back into the store) and free the stash
 slice.
 - Keep these pure-in-memory (no file save) to mirror the reference, which
 mutates the in-memory context only by default.
- `src/agent_runtime.zig` or `src/cli/repl.zig` - implement
 `transitionPermissionMode(old, new)` orchestration where the live mode is
 changed (Task 3 dispatch site). On `old != plan && new == plan` -> call
 `stripDangerous` and hold the stash in session state; on
 `old == plan && new != plan` -> `restoreStashed`. Store the stash on the same
 struct that owns the rule `Store`.

**Approach.**
1. Add the two `Store` methods above plus a small `StashList` type (an owned
 `[]Rule`) for the caller to hold.
2. In the mode-transition orchestration (the new dispatch from Task 3), branch:
 entering `plan` strips and stashes; leaving `plan` restores. (Auto mode is
 deferred; structure the branch so adding `auto` later is a one-line addition,
 matching the reference's shared `stripDangerousPermissionsForAutoMode`.)
3. Log each stripped rule at debug level (reference logs via `logForDebugging`,
 `permissionSetup.ts:537-539`); zcode uses `std.log` / its debug channel.

**Acceptance criteria.**
- Write a test in `core/permission_rules.zig`:
 `stripDangerous removes dangerous allow rules and restoreStashed reinstates
 them`. Seed a store with `allow Bash(python:*)`, `allow Bash(*)`,
 `allow Read`, `deny Bash(rm -rf)`. After `stripDangerous`: the two dangerous
 allow rules are gone, `allow Read` and the deny rule remain, and the returned
 stash has length 2. After `restoreStashed`: the store matches its original
 rule set (assert via `match` outcomes for `python -c 'x'`, `rm -rf /`,
 and a `Read`).
- Edge: a second `restoreStashed` with an empty stash is a no-op (mirror the
 reference's "clears the stash so a second exit is a no-op",
 `permissionSetup.ts:564-565`).

**Test strategy.** Unit tests under `tools/test_runner.zig` using the existing
`Store` test scaffolding (`core/permission_rules.zig:321-389`). No file IO
needed; operate entirely in memory.

**Risk / footguns.**
- Memory ownership: `Rule.deinit` frees its owned slices
 (`core/permission_rules.zig:59-65`). When you move a `Rule` out of the store
 into the stash, do NOT deinit it; transfer ownership. `orderedRemove` returns
 the value without freeing, so capture it before any free. On `restoreStashed`,
 append the moved value back (do not re-dupe).
- Do not persist to disk by default. The reference strips the in-memory context
 only; persisting would clobber the user's `Bash(*)` rule permanently across
 sessions. Restoration must happen on mode exit AND on session teardown if the
 session ends while in `plan` (add a defer in the REPL that restores any held
 stash so a crash/exit does not lose the user's rules - "Fix What You Find").
- The args matcher treats `args_contains` as glob-or-substring
 (`core/permission_rules.zig:230-233`); the dangerous-content check operates on
 the raw `args_contains` string, not on serialized tool args, so pass the rule
 field directly.

**Size estimate.** M.

---

### Task 6: Pure accept-edits bash auto-allow (`checkPermissionMode` equivalent)

**Goal.** A pure module that, given a bash command line and the active mode,
returns whether `acceptEdits` mode should auto-allow it by splitting compound
commands and checking each subcommand's base command against the fixed
filesystem set.

**Reference behavior + file:line.**
- `modeValidation.ts:7-15` - `ACCEPT_EDITS_ALLOWED_COMMANDS =
 [mkdir, touch, rm, rmdir, mv, cp, sed]`.
- `modeValidation.ts:23-56` - `validateCommandForMode`: trim, take the first
 whitespace-split token as base command; in `acceptEdits` if the base is a
 filesystem command -> allow.
- `modeValidation.ts:72-109` - `checkPermissionMode`: passthrough for
 `bypassPermissions`/`dontAsk` (handled in the main flow); otherwise split the
 command into subcommands and if ANY subcommand triggers mode-specific
 behavior, return it.

**Target Zig files.**
- Create `src/core/bash_mode_allow.zig` (pure `core/` module).
- Register in `src/main.zig` comptime block (near `src/main.zig:94`).

**Approach.**
1. `pub const ACCEPT_EDITS_ALLOWED_COMMANDS = [_][]const u8{ "mkdir", "touch",
 "rm", "rmdir", "mv", "cp", "sed" };`
2. `fn baseCommand(cmd: []const u8) ?[]const u8` - trim, return the first token
 split on ASCII whitespace; null if empty.
3. `fn splitCompound(command, buf) [][]const u8` - split on the shell operators
 `&&`, `||`, `;`, and `|` (the reference's `splitCommand_DEPRECATED` is a
 heuristic compound splitter; a conservative split on these operators is the
 minimal faithful subset). No allocation: write subslices into a small fixed
 array (cap at e.g. 32 subcommands; if exceeded, return "do not auto-allow").
4. `pub fn acceptEditsAutoAllows(command: []const u8) bool` - split into
 subcommands; auto-allow ONLY if every subcommand's base command is in the
 allowed set. (Stricter than the reference's "any subcommand triggers" because
 zcode returns a single allow/deny rather than per-subcommand passthrough;
 requiring all-filesystem avoids `mkdir x && curl evil` slipping through. State
 this deliberate tightening in the PR - it is safer than the reference and
 matches the "Simplicity First" + safety bias.)
5. `pub fn checkMode(mode: permission_decision.Mode, command: []const u8) enum
 { allow, passthrough }` - passthrough for `bypassPermissions`/`dontAsk`;
 for `acceptEdits` return `allow` when `acceptEditsAutoAllows`; else
 `passthrough`.

**Acceptance criteria.**
- Write a test `acceptEdits auto-allows filesystem commands`: true for `mkdir foo`,
 `rm -rf build`, `touch a b`, `mv a b`, `cp -r a b`, `sed -i s/x/y/ f`,
 `mkdir a && rm b` (all-filesystem compound); false for `python x.py`,
 `mkdir a && curl evil`, `git status`, `echo hi`, `npm test`, `""`.
- Write a test `checkMode passthrough for bypass/dontAsk and non-edit base`
 asserting `bypassPermissions`/`dontAsk` always return `.passthrough`, and a
 non-filesystem command under `acceptEdits` returns `.passthrough`.

**Test strategy.** Inline unit tests under `tools/test_runner.zig`. Pure, no IO.

**Risk / footguns.**
- The compound splitter must treat `&&` and `||` as two-char operators, not two
 single `&`/`|`. Scan with a two-char lookahead. Keep it allocation-free with a
 fixed subcommand cap (return "no auto-allow" on overflow rather than
 truncating, to stay safe).
- This module must not try to be a full shell parser. Quoted operators
 (`echo "a && b"`) are an acknowledged edge the reference's
 `splitCommand_DEPRECATED` also handles imperfectly - keep the conservative
 splitter and bias to `passthrough` (ask) on ambiguity. Note this limitation in
 a comment.

**Size estimate.** S.

---

### Task 7: Wire accept-edits bash auto-allow into the tool gate

**Goal.** Consult `bash_mode_allow.checkMode` for `Bash` invocations before the
generic `approval.evaluate()` so `acceptEdits` mode auto-allows the filesystem
commands.

**Reference behavior + file:line.** `checkPermissionMode` is the bash tool's
mode entry point, consulted ahead of the generic permission flow
(`modeValidation.ts:58-71`).

**Target Zig files.**
- `src/agent_tools.zig` - in the tool gate, before the generic
 `approval_mod.evaluate(...)` call (`agent_tools.zig:680-691`) and after the
 explicit deny/allow rule checks (`agent_tools.zig:637-668`), add: if the
 effective tool is the canonical Bash tool AND the effective mode is
 `acceptEdits`, extract the bash `command` field from `args` and call
 `bash_mode_allow.acceptEditsAutoAllows`. If true -> `runApprovedToolTrace(…,
 .auto_approved, …)` with reason "auto-allowed by acceptEdits mode". If false ->
 fall through to the existing generic gate (so it still asks/denies).

**Approach.**
1. Reuse the existing bash-command extraction. The gate already serializes/parses
 tool args; pull the `command` string from the Bash tool input (there is
 existing arg parsing around `agent_tools.zig:631` `buildToolArgRepairGuidance`
 and the bash tool input shape). Extract minimally - a JSON `command` field.
2. Place the check ONLY on the bash tool path and ONLY when the effective mode
 (from Task 2 override or config) is `acceptEdits`. Explicit deny rules must
 still win - keep this check strictly after the rule-deny branch.
3. Reason string and audit trace must distinguish this from rule/session allows
 (use a distinct reason, mirroring the reference's `decisionReason.type:
 'mode'`).

**Acceptance criteria.**
- Write a gate-level test: with effective mode `acceptEdits`, a Bash invocation
 of `{"command":"mkdir build"}` is auto-approved (`state == .auto_approved`),
 while `{"command":"python x.py"}` is NOT auto-approved by the mode (falls to
 the generic gate and, non-interactive, is denied at MEDIUM). Mirror the
 context-construction style of the existing `agent_tools` tests.
- A deny rule `deny Bash(mkdir*)` must still deny `mkdir build` even in
 `acceptEdits` (deny precedence), proving ordering. Reuse
 `core/permission_rules.zig` rule seeding.

**Test strategy.** Gate-level unit tests under `tools/test_runner.zig` calling
the gate function directly with a constructed context; no live model.

**Risk / footguns.**
- Ordering: explicit deny rules (`agent_tools.zig:639-645`) MUST be evaluated
 before the acceptEdits bash auto-allow, or a `deny Bash(rm:*)` would be
 bypassed. Put the new check after the rule block and after session-approved.
- Only apply to the canonical bash tool name. Use `core/tool_name_map.zig` /
 the existing `effective_name` (already computed at `agent_tools.zig:637+`),
 not a hardcoded `"Bash"`, so aliases (`bash`/`shell`) are covered.
- `readFileAlloc`/JSON parse footguns do not apply (args are already in memory);
 just guard against a missing/non-string `command` field -> treat as
 `passthrough`.

**Size estimate.** S.

---

## Verification

Prove the phase is done with the following, in order:

1. **Unit tests pass.** Run the full suite under the custom runner:
 ```
 zig build test
 ```
 New tests required (all must pass): the cycle-order and label tests
 (Task 1), the `modeToString` round-trip and override-gate tests (Task 2),
 the `confirm_cycle_mode` mapping + cycle-state-machine tests (Task 3), the
 five-shape dangerous-content tests (Task 4), the strip/restore store tests
 (Task 5), the accept-edits compound-splitter tests (Task 6), and the
 gate-level acceptEdits-bash tests (Task 7).

2. **Release build + install** (per CLAUDE.md, fresh inode to preserve the
 ad-hoc signature):
 ```
 zig build -Doptimize=ReleaseFast
 rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode
 ```
 Bump `.version` patch in `build.zig.zon` for this change.

3. **Manual TUI checks** (interactive session):
 - Start a session, trigger a tool that prompts (e.g. a HIGH-tier tool under
 `default`). Press Shift+Tab inside the approval overlay; confirm the header
 shows the next mode's short label (`Accept` -> `Plan` -> back to `Default`,
 and `Bypass` only when the dangerous/yolo flag is set).
 - In `acceptEdits` mode, ask the model to run `mkdir`/`rm`/`mv` -> confirm it
 runs without a prompt; ask it to run `python -c …` -> confirm it still
 prompts/denies.
 - Enter `plan` mode with a `Bash(*)` allow rule active in
 `~/.zcode` rules; confirm a `python` bash call is no longer auto-allowed
 while in plan (rule stripped); exit plan; confirm the rule is active again
 (rule restored). Verify with `/permissions` listing before and after.
 - Confirm in-chat Shift+Tab still cycles `SessionMode`
 (execution/planning/brainstorm/review) - no regression.

4. **No legacy regression.** With `approval_mode = "tiered-auto"` (the default,
 `core/config.zig:149`) and no permission-mode override, tool decisions are
 byte-for-byte identical to pre-phase behavior (the gate passes
 `ctx.cfg.approval_mode` unchanged).

## Out-of-scope / deferred notes

- **Ant-only `auto` mode and `TRANSCRIPT_CLASSIFIER`.** The reference's
 `auto` mode, `canCycleToAuto`, `isAutoModeGateEnabled`, and the
 `USER_TYPE === 'ant'` cycle branch (`getNextPermissionMode.ts:17-49, 41-49`)
 are feature-gated and ant-only. Task 1 omits the `auto` arm and Task 5
 structures the strip/restore branch so `auto` is a one-line add when/if the
 gate lands. The verified gap notes auto mode is "feature-gated" and "lower
 priority"; this is a deliberate deferral, not an oversight.
- **Ant-only dangerous patterns.** `coo`, `gh`, `gh api`, `curl`, `wget`,
 `git`, `kubectl`, `aws`, `gcloud`, `gsutil`, `fa run`
 (`dangerousPatterns.ts:58-79`) are gated on `USER_TYPE === 'ant'`. zcode has
 no ant notion, so Task 4 omits them. If a future enterprise policy wants a
 broader list, it is an additive change to `DANGEROUS_BASH_PATTERNS`.
- **PowerShell dangerous patterns.** `isDangerousPowerShellPermission`
 (`permissionSetup.ts:157-188+`) is Windows-specific; zcode targets a macOS/
 Unix-first binary and has no PowerShell tool. Deferred.
- **Persisting reference mode names to config.** Task 2 keeps the reference
 permission mode as live session state and does NOT widen
 `isKnownApprovalMode` (`core/config.zig:389-394`) to persist them. Making
 `acceptEdits`/`plan`/`bypassPermissions` first-class persisted config values
 (so `approval_mode = "plan"` survives restart) is a separate, additive change.
- **Remapping in-chat Shift+Tab to permission modes.** Task 3 deliberately keeps
 in-chat Shift+Tab on `SessionMode` and implements the reference permission
 cycle on the approval-overlay `confirm_cycle_mode` path to avoid regressing a
 shipped feature. If the user prefers the reference's exact in-chat binding,
 it is a one-line remap at `cli/repl_input.zig:264` - flagged as a future
 toggle, not done here.
- **Full shell parsing for compound commands.** Task 6 uses a conservative
 operator splitter (`&&`/`||`/`;`/`|`) and biases to passthrough on ambiguity
 (quoted operators, subshells). A complete shell grammar is out of scope and
 unnecessary for the fixed seven-command filesystem allowlist.
