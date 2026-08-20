---
title: REPL -> runtime permission-mode wire
tags: [gotcha, architecture]
created: 2026-05-29
updated: 2026-05-29
sources:
  - src/cli/repl.zig:5203 (REPL local permission_mode + permission_mode_active)
  - src/cli/repl.zig:6116 (.toggle_permission_mode dispatch)
  - src/repl_commands.zig:123 (applyPermissionModeCycle + __set_permission_mode)
  - src/agent_runtime.zig:242 (applyModeTransitionToStore, now pub)
  - src/agent_runtime.zig:667 (transitionPermissionMode)
---

# REPL -> runtime permission-mode wire (P3, PRD #534)

The live Claude Code permission mode (default/acceptEdits/plan/bypassPermissions/dontAsk)
is held in TWO places that must stay in sync:

- REPL local: `var permission_mode` in `cli/repl.zig` (seeded from
  `cfg.approval_mode` via `modeFromString`, only "active" when the config carries
  a reference mode name -- `permission_mode_active`).
- Runtime: `AgentRuntime.permission_mode_override` -- the field the tool gate
  actually reads in `agent_tools.zig` (`ctx.permission_mode_override`).

## The boundary

The REPL never holds an `*AgentRuntime`. It reaches the runtime only through the
opaque `Handler` (`cli/repl.zig` `Handler.command: fn(ctx, allocator, cmd)`),
the same channel as `__yolo_on`/`__yolo_off`/`__consume_requested_mode`. So a
permission-mode cycle is pushed as an internal command string
`"__set_permission_mode <name>"`, dispatched in `repl_commands.replCommandCallback`
(casts ctx -> `*AgentRuntime`).

On that command the runtime does BOTH:
1. sets `permission_mode_override` (so the gate decides under the new mode), and
2. runs `transitionPermissionMode(old, new)` -> `applyModeTransitionToStore`
   (strip dangerous `Bash(*)`/`Bash(python:*)` allow rules on plan ENTRY, restore
   on plan EXIT). Strip/restore is in-memory only (never touches the on-disk
   rules file); a teardown restore in `AgentRuntime.deinit` covers exit-mid-plan.

The dispatch body is factored into `repl_commands.applyPermissionModeCycle`
(operates on the runtime's fields by pointer) so the wire's observable effect is
unit-testable without standing up a full `AgentRuntime`. `applyModeTransitionToStore`
was made `pub` in `agent_runtime.zig` for this.

## Two cycle entry points in the REPL, both call `pushPermissionModeToRuntime`

- `.toggle_permission_mode` dispatch (from the Confirmation-context
  `confirm_cycle_mode` keybinding): cycle local mode, then push.
- Approval overlay Shift+Tab: the overlay mutates the REPL `permission_mode`
  in place via the `ApprovalUiContext.permission_mode` pointer. After
  `handler.call` returns (success AND error paths), if `permission_mode` changed
  vs a pre-turn snapshot, push it.

## Limitation: no mid-overlay re-decide

When the approval overlay is open, the runtime is BLOCKED inside `handler.call`
awaiting the overlay's answer, and the pending tool's decision was already
computed before the overlay opened. So cycling the mode inside the overlay does
NOT re-decide the current pending tool; it makes the NEXT decision use the new
mode. A true mid-overlay re-decide would need the gate to re-enter
`permission_decision.decide` from inside the overlay loop (an architectural
change to the approval bridge). Deliberately deferred; the overlay header still
re-renders the new short label live so the user sees the change.

In-chat Shift+Tab still cycles `SessionMode` (execution/planning/brainstorm/
review) -- a shipped feature deliberately left intact. Only the
Confirmation-context Shift+Tab drives permission modes.
