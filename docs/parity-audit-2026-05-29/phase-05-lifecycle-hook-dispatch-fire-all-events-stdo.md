# Phase 5: Lifecycle hook dispatch: fire all events, stdout JSON contract, matchers, timeouts, async, policy gating

## Overview

**What.** Today zcode parses the full Claude Code hook configuration (all 27
events, all four hook types, matcher/timeout/once/async fields) but only ever
*executes* command-type hooks for three tool events (`PreToolUse`,
`PostToolUse`, `PostToolUseFailure`). This phase turns the parsed-but-inert
configuration into a working hook engine:

1. Fire the other ~24 lifecycle events at their real lifecycle points
   (SessionStart, UserPromptSubmit, Stop, PreCompact/PostCompact, SessionEnd,
   Notification, SubagentStart/Stop, etc.).
2. Execute the `prompt`, `http`, and `agent` hook types (not just `command`).
3. Honor the full stdout JSON contract (continue/suppressOutput/systemMessage,
   decision approve/block, permissionDecision allow/deny/ask + reason,
   updatedInput, additionalContext injection).
4. Add the missing matcher syntaxes (regex + pipe-separated exact lists), the
   per-hook `if` permission-rule pre-filter, per-hook timeouts, async/background
   execution with a pending registry, `once` self-removal, dedup, policy gating
   (disableAllHooks / allowManagedHooksOnly / strictPluginOnlyCustomization),
   a startup snapshot, the PostToolUse `tool_response` stdin field, session/
   frontmatter/skill hook registration, and hook-execution event broadcasting.

**Why.** The most user-visible hooks in the product (SessionStart injecting
context, UserPromptSubmit rewriting/gating a prompt, Stop forcing continuation,
PreCompact warnings) currently never run. A user who copies a working
`settings.json` from Claude Code sees their non-tool hooks silently ignored.
This is a high-severity correctness gap (two `high`, several `medium`).

**Dependencies.**
- **Phase 1** (settings/config model, paths, multi-scope settings merge):
  required so hooks can be read from user/project/local scopes and so policy
  settings (`policySettings`) exist to gate on. The snapshot and policy gating
  tasks consume Phase 1's merged-settings surface.
- **Phase 2** (permission engine / approval flow): required so
  `permissionDecision: allow/ask` and the PreToolUse auto-approve path can feed
  the permission engine, and so the `if` pre-filter can reuse permission-rule
  parsing.

**Effort.** XL. This is the single largest hook-subsystem phase: it spans a new
dispatch layer, three new hook-type executors (one needing an HTTP client + SSRF
guard, two needing an LLM call), an async background model, and wiring into the
agent loop at ~10 lifecycle points.

**Reference source root.** `/Users/example/Downloads/claude-code-main/src`
**Our source root.** `/Users/example/Projects/zig-code/src`

**Verification note from the survey.** The survey over-reports in places.
Confirmed during this plan's research:
- `hook_event.zig` already declares all 27 events with reference-exact
  PascalCase names, round-trip `fromName`, blocking-capability, and exit-code
  disposition. The "enum limited to 3 events" claim in hooks-01 refers to the
  *live* `HookEvent` enum in `hooks.zig:13-17`, not `hook_event.Event`. The plan
  below retires the small enum and routes everything through
  `hook_event.Event`.
- `hook_io.zig` already parses `continue`, `suppressOutput`, `decision`,
  `reason`, `additionalContext`, and `permissionDecision` (allow/deny/ask). The
  gap is purely that the *runtime* ignores all of them except `deny`. So
  hooks-04 / hooks-20 are mostly wiring, not parsing.
- `argument_substitution.zig` already implements `$ARGUMENTS`, `$ARGUMENTS[N]`,
  `$0`/`$1`, and named args (hooks-16 is "apply it", not "build it").
- `ssrf_guard.zig` and `egress.zig` already implement private/link-local/CGNAT/
  metadata blocking and a URL egress policy. hooks-15 reuses them.
- `providers/common.zig` already has a curl-based HTTP client with egress policy
  (`callHttpWithPolicy`). The http hook executor reuses it.

## Gaps covered

| id | title | severity | size | our current state |
|---|---|---|---|---|
| hooks-01 | Only 3 hook events fire; ~24 others parse but never execute | high | L | `hook_event.zig` has all events + names + disposition; `hooks.zig` only dispatches the 3 tool events; no lifecycle call sites for the rest |
| hooks-02 | prompt / http / agent hook types parsed but never executed | high | L | `hook_config.zig` parses all four types; `hooks.zig:233` `continue`s on non-command; no executor for prompt/http/agent |
| hooks-04 | stdout JSON contract mostly parsed but not acted upon | high | M | `hook_io.zig` parses 6 fields; runtime only converts deny/exit-2 to a block; continue/suppress/systemMessage/updatedInput/additionalContext-inject not wired |
| hooks-20 | permissionDecision allow/ask not honored (only deny blocks) | medium | M | allow/deny/ask parse; only `.deny` acted on; no auto-approve, no force-ask |
| hooks-05 | no `if` permission-rule pre-filter on hooks | medium | S | `HookDef` has no `if` field; only `matcher` filters |
| hooks-11 | matcher: no regex + no pipe-separated exact lists | medium | M | `hook_matcher.zig` does glob + `Tool(pattern)`; no regex engine, no `\|` alternation |
| hooks-08 | no per-hook timeout enforcement | medium | M | `timeout_s` parsed; never passed to `std.process.run` |
| hooks-10 | PostToolUse stdin omits the tool response (`tool_response`) | medium | S | `buildToolEventPayload` has no response param; `.sh` env path passes `ZCODE_TOOL_OUTPUT` |
| hooks-06 | no async / asyncRewake background execution or pending registry | medium | L | `is_async` parsed, ignored; all hooks run synchronously |
| hooks-07 | no `once` self-removal | low | S | `once` parsed; run loop never removes |
| hooks-12 | no policy gating + no startup snapshot | low | M | no disableAllHooks/allowManagedHooksOnly/strictPluginOnly; reads hooks live each call |
| hooks-13 | no session-scoped / frontmatter / skill hook registration | low | L | only file `.sh` + settings command hooks; no in-memory registry |
| hooks-14 | no hook-execution event broadcasting (started/progress/response) | low | M | `run()` returns one result struct; no emit functions |
| hooks-15 | HTTP hook SSRF guard + URL allowlist + env-var header interpolation | low | M | `ssrf_guard.zig`/`egress.zig` exist but not wired to hooks; http hook not executed |
| hooks-16 | no `$ARGUMENTS`/indexed substitution into prompt/agent hook bodies | low | S | `argument_substitution.substituteArguments` exists; not applied because prompt/agent never run |
| hooks-18 | no per-hook statusMessage in spinner | low | S | `HookDef` lacks `status_message`; not parsed; no spinner integration |
| hooks-19 | no hook dedup by command+shell+if within source context | low | S | run loop iterates all defs; no dedup map |

## Implementation tasks

Order matters: tasks 1-4 build the dispatch foundation that the rest plug into.
Where a task has no data dependency on an earlier one, it can be parallelized,
but most tasks below touch `hooks.zig` / `hook_config.zig` and so should land in
the listed order to avoid merge churn.

---

### Task 1 - Extend HookDef + parser for `if`, `shell`, `statusMessage`, `headers`, `allowedEnvVars`, `asyncRewake`

**Goal.** Make the config model carry every field the dispatch/exec/dedup tasks
need, so later tasks read them instead of re-parsing.

**Reference behavior + file:line.**
`schemas/hooks.ts:32-163` defines the four hook schemas with `if`
(`IfConditionSchema`, `:19-27`), `shell` (`:36`), `statusMessage`
(`:47/87/118/155`), `once` (`:51`), `async`/`asyncRewake` (`:55/59`), http
`headers`/`allowedEnvVars` (`:106/112`), and `model` (prompt `:81`, agent
`:149`).

**Target Zig files.**
- Edit `src/core/hook_config.zig` (extend `HookDef`, extend `parse`).
- No new module; `hook_config.zig` is already registered in `main.zig:98`.

**Approach.**
1. Add fields to `HookDef` (after the existing ones, all with safe defaults so
   existing tests keep compiling):
   - `if_cond: []const u8 = ""` (the permission-rule `if`),
   - `shell: []const u8 = ""` (`"bash"` default applied at exec time, not here),
   - `status_message: []const u8 = ""`,
   - `async_rewake: bool = false`,
   - `headers_json: []const u8 = ""` (raw JSON object slice for http headers;
     borrow from the parsed value like `body`),
   - `allowed_env_vars: []const []const u8 = &.{}` (owned slice of borrowed
     strings; free in `Parsed.deinit`).
2. In `parse`, read the new keys. `if` is `str(h.object.get("if"), "")`.
   `shell` is `str(h.object.get("shell"), "")`. `statusMessage` ->
   `status_message`. `asyncRewake` -> `async_rewake` (and treat
   `async_rewake == true` as implying `is_async == true`, matching the schema
   comment at `schemas/hooks.ts:63`).
3. For http: capture the `headers` object as a raw slice. Since
   `std.json.Value` does not preserve source spans, re-serialize the headers
   object back to JSON with `std.json.Stringify`/`std.json.fmt` into an
   allocation owned by `Parsed` (add a `headers_storage: std.ArrayList([]u8)`
   to `Parsed` freed in `deinit`). Capture `allowedEnvVars` as a slice of the
   string array elements (skip non-string entries).
4. Update `Parsed.deinit` to free any new owned allocations.

**Acceptance criteria.**
- New test in `hook_config.zig`: parse a settings blob containing a command
  hook with `if`, `shell:"bash"`, `statusMessage`, `async`, `asyncRewake`; a
  prompt hook with `model`; an http hook with `url`, `headers`,
  `allowedEnvVars`. Assert each field round-trips into `HookDef`.
- Existing `hook_config.zig` tests still pass unchanged.

**Test strategy.** `zig build test` (custom runner `tools/test_runner.zig`),
which prints `RUN: <name>` per test. Add the asserts to `hook_config.zig`'s
existing test block.

**Risk / footguns.**
- "File ObjectMap.put after parse: take `&parsed.value.object` by pointer"
  (CLAUDE.md) does not apply here (we only read), but the borrowed-slice
  contract does: `if_cond`, `shell`, `headers_json` storage must live as long as
  `Parsed`. Document on `HookDef` that strings borrow from `Parsed`.
- Re-serializing `headers` is the only allocation in the parser; on error use
  `errdefer` so a malformed entry doesn't leak.

**Size.** S.

---

### Task 2 - Replace the live 3-event `HookEvent` enum with `hook_event.Event` end to end

**Goal.** Make the dispatch layer event-agnostic so adding lifecycle call sites
(Task 3) is a one-line `runEvent(.session_start, ctx)` call rather than a new
enum variant.

**Reference behavior + file:line.** The reference has one `HookEvent` union
(`agentSdkTypes` `HOOK_EVENTS`) used everywhere; per-event exec functions are
thin wrappers over a shared runner (`utils/hooks.ts:3003`
`executeHooksOutsideREPL`, and the per-event `execute*Hooks` at
`:3570/:3594/:3961/:4034/:4097/:4214/...`).

**Target Zig files.**
- Edit `src/core/hooks.zig` (remove `HookEvent`/`toEngineEvent`/`eventName`'s
  3-event switch; use `hook_event.Event` + `hook_event.canonicalName`).
- Edit `src/agent_tools.zig` (call sites at `:777`, `:829` pass
  `hook_event.Event` values instead of the local enum).
- `core/plugins.zig` has a parallel `.event = .pre_tool_use` enum; leave it
  alone for this phase (plugins are a separate subsystem) but make `HookContext`
  use `hook_event.Event`.

**Approach.**
1. Delete `pub const HookEvent` (`hooks.zig:13-17`) and `toEngineEvent`
   (`:194-200`). Change `HookContext.event` and `HookSpec.event` to
   `hook_event.Event`.
2. Rewrite `eventName` to delegate to a kebab-case mapping for the file-hook
   filename path (only the 3 tool events have `.sh` files; for all others return
   the canonical name - they have no file form). Keep `filenameForEvent`
   restricted to the 3 events that have `.sh` files (file hooks remain
   tool-only by design; settings.json hooks cover the rest).
3. Update `list()` to still only scan `.sh` files for the 3 tool events (file
   hooks are unchanged), but make `runConfiguredUser` event-agnostic: it already
   takes `engine_event`; drop the `toEngineEvent` indirection and pass
   `ctx.event` directly.
4. Update `agent_tools.zig:777/829` to pass `.event = .pre_tool_use` /
   `.post_tool_use` (these enum names already match `hook_event.Event`).

**Acceptance criteria.**
- `zig build test` passes with the enum removed.
- Existing `hooks.zig` test (`renderList reports none`) still passes.
- New test: `run(ctx)` with `ctx.event = .session_start` and no hooks present
  returns `.ran == false` without error (proves non-tool events are now valid
  inputs to `run`).

**Test strategy.** Custom runner. Grep after the change:
`grep -rn "HookEvent" src/` should only match `hook_event.Event` references and
the plugins subsystem's own enum.

**Risk / footguns.**
- `agent_tools.zig` and any other importer of `hooks.HookEvent` will fail to
  compile until updated - that is the intended forcing function. Grep first:
  `grep -rn "hooks_mod.HookEvent\|hooks\.HookEvent" src/`.
- Do not delete `core/plugins.zig`'s own event enum; it is a distinct type.

**Size.** S-M.

---

### Task 3 - Add lifecycle dispatch points for the non-tool events

**Goal.** Actually fire SessionStart, UserPromptSubmit, Stop, SessionEnd,
PreCompact, PostCompact, Notification, SubagentStart, SubagentStop at their
lifecycle points. This is the core of hooks-01.

**Reference behavior + file:line.**
- `executeSessionStartHooks` (`utils/hooks.ts:3867`) - runs at session boot,
  injects `additionalContext` into the first turn.
- `executeUserPromptSubmitHooks` (`:3826`) - runs before the prompt is sent;
  can block (exit 2 / decision block) and inject `additionalContext`.
- `executeStopHooks` (`:3639`) - runs when the agent would stop; exit 2 forces
  continuation with `stopReason`.
- `executeSessionEndHooks` (`:4097`), `executePreCompactHooks` (`:3961`),
  `executePostCompactHooks` (`:4034`), `executeNotificationHooks` (`:3570`),
  SubagentStart/Stop. The reference wires these into the REPL/turn loop; e.g.
  `:3173` shows Stop hooks being run in `-p` mode.

**Target Zig files.**
- Edit `src/core/hooks.zig` - add a small set of context builders + a public
  `runEvent` entry that does not require tool fields.
- Edit `src/core/hook_io.zig` - add payload builders for non-tool events
  (SessionStart `source`, UserPromptSubmit `prompt`, Stop, SessionEnd `reason`,
  PreCompact `trigger`, Notification `message`/`title`). See Task 4 for the
  shared builder.
- Edit `src/agent_runtime.zig` - call the dispatch at:
  - session construction (`init`/`initFromSession`, around `:344/:440`) ->
    `session_start`.
  - `handlePromptDetailedWithModeAndReporter` (`:679`) start ->
    `user_prompt_submit` (before the model call); on block, short-circuit the
    turn and surface the reason; on success, prepend `additionalContext` to the
    prompt/context.
  - end of the turn loop, when the agent decides to stop -> `stop`; if blocked
    (exit 2 / decision block), continue the loop with the reason injected as a
    user message.
  - compaction path (`forceCompaction` `:2975`, and the auto-compaction trigger)
    -> `pre_compact` before, `post_compact` after.
  - session teardown (`deinit` `:473`, or an explicit end-of-session hook in the
    REPL exit path) -> `session_end`.
  - subagent activate/clear (`activateAgentByName` `:533`, `clearActiveAgent`
    `:555`) -> `subagent_start` / `subagent_stop`.
- Edit `src/cli/*` REPL exit path for `session_end` and `notification` (the
  notification event fires when zcode would post a desktop/terminal
  notification - reuse the existing notification trigger if one exists, else
  defer notification wiring to Out-of-scope).

**Approach.**
1. In `hooks.zig`, add:
   ```
   pub fn runEvent(allocator, ctx: HookContext) !HookRunResult
   ```
   Generalize the current `run` so non-tool events skip the `.sh` file scan
   (those files only exist for tool events) and only run `runConfiguredUser`.
   For tool events, keep the existing file-hook + configured path.
2. In `runConfiguredUser`, replace the hard `if (def.hook_type != .command)
   continue;` with a dispatch on `def.hook_type` (Task 6 fills in prompt/http/
   agent; until then, keep command working and route others to a stub that
   returns "not run"). For matcher selection, tool events use
   `hook_matcher.matchesTool`; non-tool events use `hook_matcher.matchesField`
   against the event's discriminating field (e.g. SessionStart `source`).
3. Build event-appropriate payloads (Task 4).
4. Wire the call sites listed above. Each site:
   - builds a `HookContext` with `event` + the event's fields,
   - calls `runEvent`,
   - acts on the result per the stdout contract (Task 5): block/continue,
     inject `additional_context`.
5. Keep each call site minimal: a helper in `agent_runtime.zig` like
   `fn fireLifecycleHook(self, event, payload_fields) !LifecycleOutcome` that
   centralizes result interpretation.

**Acceptance criteria.**
- Integration test (new file `src/core/hooks_lifecycle_test.zig`, registered in
  `main.zig` comptime block): write a temp `settings.json` with a
  `SessionStart` command hook that echoes
  `{"hookSpecificOutput":{"additionalContext":"INJECTED"}}` and a
  `UserPromptSubmit` command hook that exits 2 with a reason; drive `runEvent`
  for each and assert: SessionStart returns the additional context;
  UserPromptSubmit returns `blocked == true` with the reason.
- A `Stop` hook exiting 2 returns `blocked == true` (interpreted as
  "force continue" by the caller).
- Manual: with a real `~/.zcode/settings.json` SessionStart hook, launch
  `zcode` and confirm the injected context appears (see Verification).

**Test strategy.** Use `core/test_helpers.zig` `tmpDirCwd` to get a real
absolute cwd (CLAUDE.md: never pass `"."`). Write `settings.json` under a temp
`ZCODE_HOME`. Drive `runEvent` directly in the unit test; drive the full
agent_runtime path in an integration test that uses the mock provider.

**Risk / footguns.**
- `agent_runtime.zig` is large; keep changes surgical (CLAUDE.md rule 3). Add
  one helper, call it at the listed points, do not refactor the turn loop.
- Stop-hook recursion: a `Stop` hook that injects a prompt which itself triggers
  more tool calls could loop. Mirror the reference: bound stop-hook
  continuations (the reference relies on `preventContinuation` once). Add a
  per-turn "stop hook already forced continuation" guard so a misbehaving hook
  cannot infinite-loop.
- SessionStart timing: inject `additionalContext` into the *system/context*
  region, not as a visible user message, to match the reference.

**Size.** L.

---

### Task 4 - Per-event stdin payloads, including PostToolUse `tool_response` (hooks-10)

**Goal.** Build the correct stdin JSON for each event, and add the missing
`tool_response` field to PostToolUse / the failure fields to
PostToolUseFailure.

**Reference behavior + file:line.**
`hooksConfigManager.ts:41` (PostToolUse `response` field), `:50`
(PostToolUseFailure: `tool_input`, `tool_use_id`, `error`, `error_type`,
`is_interrupt`, `is_timeout`). Each event has a discriminating field
(SessionStart `source`, UserPromptSubmit `prompt`, Notification
`message`/`title`, PreCompact `trigger`, SessionEnd `reason`).

**Target Zig files.**
- Edit `src/core/hook_io.zig` (add builders + extend the tool builder).
- Edit `src/core/hooks.zig` call site (`:237`) to pass `tool_output` /
  `tool_success`.

**Approach.**
1. Extend `buildToolEventPayload` to accept an optional `tool_response`
   (`?[]const u8`) and `success: bool`; when present and the event is
   `post_tool_use` / `post_tool_use_failure`, embed `"tool_response": <json or
   string>` (reuse the existing `isValidJson` raw-vs-string logic) and, for the
   failure event, `"is_interrupt"`/`"is_timeout"` flags if known. Keep the old
   3-arg call working via a wrapper or default param.
2. Add `buildLifecycleEventPayload(allocator, event_name, fields)` where
   `fields` is a small struct of optional named values
   (`source`, `prompt`, `message`, `title`, `trigger`, `reason`, `cwd`). Emit
   only the fields relevant to the event (SessionStart -> `source`;
   UserPromptSubmit -> `prompt`; etc.), always including `hook_event_name` and
   `cwd`.
3. Update `hooks.zig:237` to call the extended tool builder with
   `ctx.tool_output` and `ctx.tool_success`.

**Acceptance criteria.**
- New `hook_io.zig` test: `buildToolEventPayload` for `PostToolUse` with a JSON
  `tool_response` round-trips with `tool_response` as a nested object; with a
  plain-string response it round-trips as a JSON string.
- New test: `buildLifecycleEventPayload` for `SessionStart` includes
  `hook_event_name:"SessionStart"` and `source` but not `tool_name`.

**Test strategy.** Custom runner; parse the produced JSON back with
`std.json.parseFromSlice` and assert fields (same pattern as the existing
`hook_io.zig` tests).

**Risk / footguns.**
- The existing `buildToolEventPayload` callers (and 2 tests) must keep
  compiling - add the response param with a default, or keep the 4-arg function
  and add a new 6-arg one.
- `std.json.fmt` is the safe escaper already used here; reuse it for string
  fields (matches the file's existing style at `:45-53`).

**Size.** S.

---

### Task 5 - Act on the full stdout JSON contract (hooks-04)

**Goal.** Make the runtime honor `continue:false` (+ `stopReason`),
`suppressOutput`, `systemMessage`, `decision: approve/block`, and inject
`additionalContext` - not just `deny`.

**Reference behavior + file:line.**
`types/hooks.ts:50-166` (`syncHookResponseSchema`): `continue` (default true,
stops Claude with `stopReason` when false), `suppressOutput`,
`stopReason`, `decision` approve/block, `systemMessage` (shown to user),
`hookSpecificOutput.{permissionDecision, permissionDecisionReason, updatedInput,
updatedMCPToolOutput, additionalContext, watchPaths, retry}`.

**Target Zig files.**
- Edit `src/core/hook_io.zig` (add the still-missing parsed fields:
  `stop_reason`, `system_message`, `permission_decision_reason`,
  `updated_input` (raw JSON slice), `updated_mcp_tool_output` (raw JSON slice),
  `retry` (bool)).
- Edit `src/core/hooks.zig` (`HookRunResult` gains the new outcome fields; the
  run loop populates them).
- Edit `src/agent_tools.zig` / `src/agent_runtime.zig` (consumers act on them).

**Approach.**
1. In `hook_io.zig` `Output`, add: `stop_reason: ?[]const u8`,
   `system_message: ?[]const u8`, `permission_decision_reason: ?[]const u8`,
   `updated_input: ?[]const u8` (raw object slice via re-serialize, since the
   parsed value is freed), `updated_mcp_tool_output: ?[]const u8`,
   `retry: ?bool`. Parse top-level `stopReason`, `systemMessage`, and the nested
   `hookSpecificOutput.{permissionDecisionReason, updatedInput,
   updatedMCPToolOutput, retry}`.
2. In `hooks.zig`, widen `HookRunResult` with: `continue_run: ?bool`,
   `suppress_output: bool`, `stop_reason: ?[]u8`, `system_message: ?[]u8`,
   `additional_context: ?[]u8`, `updated_input: ?[]u8`, `permission: enum {
   none, allow, deny, ask }`, `permission_reason: ?[]u8`, `retry: bool`. Own and
   free them in `deinit`.
3. In the run loop, copy parsed fields into the result. `decision == "block"`
   maps to `blocked = true` even at exit 0 (the reference treats
   `decision:block` as blocking independent of exit code).
4. Consumers:
   - `continue_run == false` at a tool/Stop point -> stop the turn with
     `stop_reason` surfaced.
   - `suppress_output` -> the caller hides the hook's stdout from the
     transcript (do not print `output`).
   - `system_message` -> print as a system/warning line to the user.
   - `additional_context` -> inject into the model context for the next turn
     (PreToolUse/PostToolUse/UserPromptSubmit/SessionStart all support it).
   - `updated_input` -> for PreToolUse, replace the tool args before execution
     (Task 8 / hooks-20 wiring).

**Acceptance criteria.**
- `hook_io.zig` tests for each new field (extend the existing
  "reads top-level decision/continue" test).
- `hooks.zig` test: a hook printing
  `{"decision":"block","reason":"nope"}` at exit 0 yields `blocked == true`
  with `output`/`stop_reason` == "nope".
- `hooks.zig` test: a hook printing `{"continue":false,"stopReason":"halt"}`
  yields `continue_run == false` and `stop_reason == "halt"`.
- Integration: a PreToolUse hook printing
  `{"hookSpecificOutput":{"additionalContext":"NOTE"}}` makes `NOTE` visible in
  the next model context (assert via agent_runtime integration test with mock
  provider capturing the assembled context).

**Test strategy.** Custom runner for the parse + result-mapping unit tests;
mock-provider integration test for the context-injection behavior.

**Risk / footguns.**
- `updated_input`/`updated_mcp_tool_output` need re-serialization (the parsed
  value is freed when `Result.deinit` runs). Allocate them on the result's
  allocator and free in `deinit`. This is the same borrowed-vs-owned hazard as
  Task 1.
- Do not over-engineer `watchPaths` here - FileChanged watching is deferred
  (see Out-of-scope). Parse `watchPaths` into a raw slice but treat it as a
  no-op for now; document the deferral.

**Size.** M.

---

### Task 6 - Execute prompt / http / agent hook types (hooks-02), with `$ARGUMENTS` substitution (hooks-16)

**Goal.** Stop `continue`-ing past non-command hooks; run them.

**Reference behavior + file:line.**
- `execPromptHook.ts:21` - substitute `$ARGUMENTS` (`:35`), query the small/fast
  model (or `hook.model`) with `outputFormat json_schema {ok, reason}`
  (`:62-100`), 30s default timeout (`:55`); `ok:false` -> blocking with reason.
- `execAgentHook.ts:36` - multi-turn agentic verifier, `$ARGUMENTS`
  substitution (`:60`), StructuredOutput enforcement, 60s default
  timeout (`:75`).
- `execHttpHook.ts:123` - POST the JSON input to the URL (Task 7).
- `hookHelpers.ts:30` `addArgumentsToPrompt` -> `substituteArguments`.

**Target Zig files.**
- New `src/core/hook_exec_prompt.zig` (prompt + agent share most of this;
  keep both here).
- Edit `src/core/hooks.zig` (`runConfiguredUser` dispatches by `hook_type`).
- Reuse `src/core/argument_substitution.zig` (`substituteArguments`,
  `:206`).
- Reuse the LLM query path. Confirm the right entry: `agent_runtime.zig` owns
  provider calls. Add a minimal "single-shot, no-stream, json-schema-constrained"
  helper to the provider layer (`src/providers/common.zig` already has
  `callHttpWithPolicy`/`callHttpJsonStreamWithCallback`); a non-streaming
  one-shot is preferable for prompt hooks. If a clean one-shot LLM call does not
  exist, add `queryModelOnce(allocator, model, system, user_json) ![]u8` near
  the provider adapter and register it.
- Register `hook_exec_prompt.zig` in `main.zig` comptime block.

**Approach.**
1. `hook_exec_prompt.zig`:
   - `pub fn runPromptHook(allocator, def, json_input, signal) !PromptOutcome`:
     substitute `$ARGUMENTS` via `argument_substitution.substituteArguments(def.body, json_input, false, &.{})`,
     build the system prompt verbatim from `execPromptHook.ts:65-69`, call the
     LLM with `def.model orelse small-fast-model`, parse `{ok, reason}`; map
     `ok:false` -> `.blocked` with reason, parse failure -> `.non_blocking_error`.
   - `pub fn runAgentHook(...)`: same shape but uses the agentic verifier prompt
     (`execAgentHook.ts`) and the StructuredOutput tool contract. For the first
     iteration, implementing it as a single-shot json-schema call (like prompt)
     is acceptable parity if a multi-turn tool loop is too heavy; note the
     simplification and defer full multi-turn to a follow-up.
2. In `hooks.zig` `runConfiguredUser`, replace the `continue` with:
   ```
   switch (def.hook_type) {
     .command => ... (existing path),
     .prompt  => hook_exec_prompt.runPromptHook(...),
     .agent   => hook_exec_prompt.runAgentHook(...),
     .http    => hook_exec_http.runHttpHook(...),  // Task 7
   }
   ```
   Map each outcome into `HookRunResult` (blocked/output/etc.).
3. The JSON input passed to substitution is the same payload built in Task 4.

**Acceptance criteria.**
- Unit test with the mock provider: a prompt hook whose model returns
  `{"ok":false,"reason":"missing tests"}` yields `blocked == true`, reason
  surfaced; `{"ok":true}` yields not blocked.
- Unit test: `$ARGUMENTS` in `def.body` is replaced by the full JSON input
  before the model call (assert the substituted prompt the mock provider
  receives).
- Agent hook smoke test (mock provider) returns a non-blocking success when the
  verifier returns `ok:true`.

**Test strategy.** Custom runner with the mock provider adapter (the repo
already has a mock provider per the roadmap). Inject the mock so no network is
hit.

**Risk / footguns.**
- Do not trigger UserPromptSubmit recursion: prompt hooks must NOT route through
  the normal prompt-submit path (reference comment `execPromptHook.ts:41`). Call
  the provider directly, bypassing `handlePrompt`.
- `substituteArguments` returns an owned slice (`argument_substitution.zig:215`
  duplicates content); free it.
- Timeouts (Task 8) apply here too: prompt 30s, agent 60s defaults.

**Size.** L.

---

### Task 7 - HTTP hook executor + SSRF guard + URL allowlist + env-var header interpolation (hooks-15, part of hooks-02)

**Goal.** Execute `http` hooks: POST the JSON input to the URL, gated by an
allowlist, routed through the SSRF guard, with allowlisted env-var
interpolation into headers.

**Reference behavior + file:line.**
`execHttpHook.ts:123-242`: enforce `allowedHttpHookUrls` patterns
(`:138-145`, `*` wildcard, `urlMatchesPattern` `:64`), default 10-min timeout
(`:12/147`), interpolate `$VAR`/`${VAR}` only for allowlisted env vars and strip
CR/LF/NUL (`interpolateEnvVars` `:89`, `sanitizeHeaderValue` `:76`),
`ssrfGuardedLookup` blocking private/link-local/CGNAT/metadata, loopback allowed
(`ssrfGuard.ts:42/216`).

**Target Zig files.**
- New `src/core/hook_exec_http.zig`.
- Reuse `src/core/ssrf_guard.zig` (`isBlockedAddress`, `hostnameIsBlocked` at
  `:140/:164`) and `src/core/egress.zig` (`checkUrl` `:64`, policy).
- Reuse `src/providers/common.zig` `callHttpWithPolicy` (`:250`) for the actual
  POST (it already refuses plaintext http to non-local and applies egress
  policy).
- Register `hook_exec_http.zig` in `main.zig` comptime block.

**Approach.**
1. `pub fn runHttpHook(allocator, def, json_input) !HttpOutcome`:
   - Read the URL allowlist from merged settings (Phase 1):
     `allowedHttpHookUrls` (undefined -> no restriction; `[]` -> block all;
     non-empty -> must match a `*`-glob pattern). Implement
     `urlMatchesPattern` with the existing glob in `permission_rules.globMatch`
     (the reference escapes regex then `*`->`.*`; our glob already does `*`).
   - Parse `def.headers_json` into a header map. For each value, interpolate
     `$VAR`/`${VAR}` only for names in `def.allowed_env_vars` (intersected with a
     policy `httpHookAllowedEnvVars` if Phase 1 provides one); replace
     non-allowlisted refs with empty string; strip `\r`, `\n`, `\x00`
     (`sanitizeHeaderValue`).
   - Resolve the URL host; if it is an IP literal or resolves to a blocked
     range (`ssrf_guard.isBlockedAddress` / `hostnameIsBlocked`), refuse with a
     clear error (loopback allowed). Pass the egress policy so the existing
     curl-based client also enforces it.
   - POST `json_input` with `Content-Type: application/json` plus the
     interpolated headers via `callHttpWithPolicy`; capture status + body.
   - Map: 2xx -> success (body is the hook stdout, parsed via `hook_io.parseOutput`
     for the contract); non-2xx -> non-blocking error.
2. Skip HTTP hooks for SessionStart/Setup (reference `utils/hooks.ts:1850-1859`
   deadlock guard) - just `continue` for those two events.

**Acceptance criteria.**
- Unit test: `urlMatchesPattern("https://api.example.com/x", "https://api.example.com/*")` is true; a non-matching pattern is false; empty allowlist blocks all.
- Unit test: `interpolateEnvVars` resolves an allowlisted var, blanks a
  non-allowlisted one, and strips a CRLF-injected value to a single line.
- Unit test (no network): a URL whose host is `169.254.169.254` is refused by
  the SSRF check before any POST; `127.0.0.1` is allowed past the SSRF check.
- The actual POST is covered by a loopback test only if CI permits binding a
  local server; otherwise assert the request-building path and gate the live
  POST behind a `// requires network` skip.

**Test strategy.** Custom runner. SSRF + allowlist + interpolation are pure and
fully unit-testable. For the POST, prefer a loopback echo server in the test if
the harness allows spawning one; otherwise unit-test up to the egress decision.

**Risk / footguns.**
- TOCTOU on DNS rebinding: the reference uses `ssrfGuardedLookup` so the
  validated IP is the one connected to. Our curl path resolves independently, so
  the strongest we can do is `--resolve host:port:ip` pinning or refuse hostnames
  that resolve to mixed public/blocked sets. Document this as a known weaker
  guarantee than the reference and pin the resolved IP via curl `--resolve`
  where feasible.
- `callHttpWithPolicy` already refuses plaintext `http://` to non-local
  (`providers/common.zig:260-265`); ensure the loopback dev-server case
  (`http://127.0.0.1`) is still allowed - it is, per the comment there.
- "`std.process.run`" curl invocation: `Child.Cwd` is a union, pass
  `.{ .path = ... }` (CLAUDE.md gotcha).

**Size.** M.

---

### Task 8 - Per-hook timeout enforcement (hooks-08)

**Goal.** Apply the parsed `timeout_s` (and the type-specific defaults) to every
hook execution so a hook cannot hang the agent.

**Reference behavior + file:line.**
`utils/hooks.ts:877-879` (command `hook.timeout * 1000` or
`TOOL_HOOK_EXECUTION_TIMEOUT_MS`), `execPromptHook.ts:55` (30s),
`execAgentHook.ts:75` (60s), `execHttpHook.ts:147` (10min).

**Target Zig files.**
- Edit `src/core/hooks.zig` (`runCommandWithStdin` `:264`, `runSingle` `:300`).
- Edit `src/core/hook_exec_prompt.zig` and `src/core/hook_exec_http.zig`
  (apply their defaults).

**Approach.**
1. Compute `timeout_ms` per type: command default =
   `TOOL_HOOK_EXECUTION_TIMEOUT_MS` (define a constant matching the reference;
   the reference uses 10 min), prompt 30_000, agent 60_000, http 600_000;
   `def.timeout_s != null` overrides with `timeout_s * 1000`.
2. Pass `.timeout` to `std.process.run` (mirror `tools/shell.zig` which already
   sets `.timeout`). `Io.Timeout.duration` wraps `Io.Clock.Duration {.raw,
   .clock}` (CLAUDE.md gotcha) - build it the same way `tools/shell.zig` does.
3. For prompt/http executors, thread the timeout into their LLM/HTTP calls
   (combined abort/timeout). For the curl path, curl's own `--max-time` (the
   provider layer likely already supports a timeout param).
4. On timeout: treat as a non-blocking error (operation continues), matching the
   reference's `cancelled`/abort outcome, and surface a clear message.

**Acceptance criteria.**
- Unit test: a command hook running `sleep 5` with `timeout_s = 1` returns
  within ~1-2s with a timeout/non-blocking-error outcome (not blocked).
- Unit test: default timeout constant is applied when `timeout_s` is null
  (assert the computed `timeout_ms` for each type via a small pure helper
  `computeTimeoutMs(hook_type, timeout_s)`).

**Test strategy.** Custom runner. Keep the `sleep` test's expected timeout small
(1s) and assert wall-clock via `clock.nowMillis()` deltas.

**Risk / footguns.**
- CLAUDE.md: `Child.kill(io)` reaps internally - do NOT `wait()` after a
  timeout-kill. The one-shot `std.process.run` with `.timeout` handles this; do
  not add a manual wait.
- Foreground `sleep` is blocked by the harness for the *agent's* bash; here we
  are spawning a child `sh -c sleep`, which is fine (it is the hook process, not
  a Monitor wait).

**Size.** M.

---

### Task 9 - permissionDecision allow/ask wiring + updatedInput (hooks-20)

**Goal.** Let PreToolUse / PermissionRequest hooks auto-approve (`allow`), force
a prompt (`ask`), or rewrite tool args (`updatedInput`) - not just block.

**Reference behavior + file:line.**
`types/hooks.ts:73-76` (PreToolUse `permissionDecision` /
`permissionDecisionReason` / `updatedInput`), `hooksConfigManager.ts:163-171`
(PermissionRequest allow/deny). The decision feeds the permission engine before
the tool runs.

**Target Zig files.**
- Edit `src/agent_tools.zig` (`runApprovedToolTrace` `:758-828`: the PreToolUse
  hook result already gates execution; extend it to honor allow/ask/updatedInput).
- Reuse the Phase 2 permission engine entry points.

**Approach.**
1. The PreToolUse hook currently runs *after* approval
   (`runApprovedToolTrace` runs hooks at `:777`). To let a hook auto-approve and
   skip the permission UI, the hook must run before/at the approval decision.
   Move the PreToolUse hook call to feed the approval step: if
   `permission == .allow`, skip the permission prompt entirely (the reference
   "auto-approve"); if `.ask`, force the prompt even if rules would auto-allow;
   if `.deny`, block (existing behavior). Use `permission_reason` for the
   user-facing message.
2. If `updated_input` is present (PreToolUse), replace the tool args with the
   rewritten JSON before dispatch (`req.args = updated_input`).
3. Keep the default (no decision) path identical to today.

**Acceptance criteria.**
- Integration test (mock approval callback that records whether it was asked):
  a PreToolUse hook returning
  `{"hookSpecificOutput":{"permissionDecision":"allow"}}` runs the tool WITHOUT
  invoking the approval callback; `"ask"` invokes it even for a normally
  auto-allowed tool; `"deny"` blocks (existing test still passes).
- Integration test: a PreToolUse hook returning `updatedInput` causes the tool
  to execute with the rewritten args (assert via the recorded tool trace args).

**Test strategy.** Custom runner with a stub `ask_user_fn` recording its calls,
driving `runApprovedToolTrace` (or the executeToolCall wrapper) with a mock
tool.

**Risk / footguns.**
- Reordering the PreToolUse hook relative to approval is the delicate part. Keep
  the existing block behavior bit-identical; only add the allow/ask branches.
  Surgical change (CLAUDE.md rule 3).
- Depends on Phase 2's approval surface; if its API differs, adapt the call but
  do not redesign the permission engine here.

**Size.** M.

---

### Task 10 - Matcher: regex + pipe-separated exact lists (hooks-11)

**Goal.** Match the reference matcher semantics: `^[a-zA-Z0-9_|]+$` is exact or
pipe-separated exact list; anything else is a regex tested against the tool
name.

**Reference behavior + file:line.**
`utils/hooks.ts:1346-1381` `matchesPattern`: `*`/empty -> all;
`/^[a-zA-Z0-9_|]+$/` -> pipe-split exact (or single exact); else compile as
RegExp and test the (legacy-normalized) tool name.

**Target Zig files.**
- Edit `src/core/hook_matcher.zig` (`matchesTool`).
- Need a regex engine. Check `grep -rn "regex\|Regex" src/` first; if none
  exists, add a minimal anchored-regex matcher `src/core/mini_regex.zig`
  supporting the operators the reference matchers use in practice
  (`^`, `$`, `.`, `*`, `+`, `?`, `()`, `|`, char classes `[...]`). Register it
  in `main.zig`.

**Approach.**
1. In `matchesTool`, before the `Tool(pattern)` branch, add: if the matcher
   contains no `(` (i.e. it is a name-only matcher), test:
   - `*`/empty -> true (already handled),
   - if matcher matches `^[A-Za-z0-9_|]+$`: split on `|`, exact-compare each to
     `tool_name` (apply the same legacy-name normalization our codebase uses, if
     any),
   - else: compile as regex and test against `tool_name` (and legacy names).
2. Keep `Tool(pattern)` glob-against-input behavior unchanged (that is a
   permission-rule form, orthogonal to the reference's tool-name matcher).
3. The minimal regex engine: anchored full-match by default is NOT what the
   reference does (`regex.test` is unanchored), so implement `test` semantics
   (substring match unless `^`/`$` anchor). Keep it small and well-tested; do
   not pull in a dependency.

**Acceptance criteria.**
- `matchesTool("Edit|Write", "Write", "x")` is true; `("Edit|Write", "Read", "x")`
  is false.
- `matchesTool("^Notebook.*", "NotebookEdit", "x")` is true;
  `("^Bash$", "Bash", "x")` true; `("^Bash$", "BashOutput", "x")` false.
- Existing `hook_matcher.zig` tests (glob + `Tool(pattern)`) still pass.
- `mini_regex.zig` has its own test block covering `^`, `$`, `.`, `*`, `+`,
  `?`, `|`, `[...]`, and an invalid-pattern -> false (no panic) case.

**Test strategy.** Custom runner. Add cases to `hook_matcher.zig` and a full
test block to `mini_regex.zig`.

**Risk / footguns.**
- An invalid regex must return false and log, never panic (reference
  `:1376-1380`). In Zig, surface a parse error from the engine and treat it as
  "no match".
- Do not over-build the regex engine (CLAUDE.md rule 2): support only what hook
  matchers realistically use. Document the supported subset.

**Size.** M.

---

### Task 11 - The `if` permission-rule pre-filter (hooks-05)

**Goal.** Skip spawning a hook when its `if` permission-rule does not match the
tool call.

**Reference behavior + file:line.**
`schemas/hooks.ts:19-27` (`IfConditionSchema`), `utils/hooks.ts:1390`
(`prepareIfConditionMatcher`), `:1822-1848` (filter). The `if` parses as
`Tool(content)`; it matches when the tool name equals the call's tool and the
content matches the prepared permission matcher. For non-tool events it cannot
be evaluated -> hook is skipped.

**Target Zig files.**
- Edit `src/core/hook_matcher.zig` (add `matchesIf`).
- Edit `src/core/hooks.zig` (`runConfiguredUser` applies it before exec).
- Reuse `src/core/permission_rules.zig` rule parsing (Phase 2).

**Approach.**
1. Add `pub fn matchesIf(if_cond, tool_name, tool_input) bool` to
   `hook_matcher.zig`: empty `if` -> true (no filter); parse `if_cond` as a
   permission rule (`Tool(content)`); require tool-name equality; if no content,
   true; else glob/permission-match the content against `tool_input` (reuse
   `matchesTool`'s `Tool(pattern)` logic - they are the same shape).
2. In `runConfiguredUser`, after the `matcher` check and before exec, for tool
   events call `matchesIf(def.if_cond, ctx.tool_name, ctx.tool_args)`; if false,
   `continue`. For non-tool events, if `def.if_cond.len > 0`, skip the hook
   (cannot evaluate) and log - matching `utils/hooks.ts:1835-1840`.

**Acceptance criteria.**
- `matchesIf("Bash(git *)", "Bash", "git status")` true;
  `("Bash(git *)", "Bash", "npm i")` false; `("Bash(git *)", "Read", "...")`
  false; `("", "Bash", "...")` true.
- `hooks.zig` integration: a PreToolUse command hook with `if: "Bash(git *)"`
  does NOT run for a `Read` call (assert `ran == false` for that hook) and DOES
  run for a matching `Bash(git ...)` call.
- A non-tool event hook with a non-empty `if` is skipped.

**Test strategy.** Custom runner; pure matcher tests in `hook_matcher.zig`, and
a `runConfiguredUser` integration test using a temp settings file.

**Risk / footguns.**
- `if` is also part of the dedup identity key (Task 13). Land Task 1 (which adds
  `if_cond`) before this.
- Distinct from `matcher`: `matcher` selects the hook group; `if` is a second,
  finer gate (survey note). Apply both.

**Size.** S.

---

### Task 12 - Async / asyncRewake background execution + pending registry (hooks-06)

**Goal.** Run `async:true` (and `asyncRewake`) hooks in the background without
blocking the turn, track them in a registry, and finalize/wake on completion.

**Reference behavior + file:line.**
`utils/hooks.ts:995` (`hook.async || hook.asyncRewake` -> background),
`:1117-1163` (first-line `{"async":true,"asyncTimeout":N}` stdout detection),
`AsyncHookRegistry.ts:30` (`registerPendingAsyncHook`), `:113`
(`checkForAsyncHookResponses`), `:281` (`finalizePendingAsyncHooks`). asyncRewake
wakes the model on exit code 2.

**Target Zig files.**
- New `src/core/async_hook_registry.zig`.
- Edit `src/core/hooks.zig` (background spawn + first-line detection).
- Edit `src/core/hook_io.zig` (detect the first-line async sentinel).
- Edit `src/agent_runtime.zig` (poll/finalize at turn boundaries; rewake on
  exit 2).
- Register `async_hook_registry.zig` in `main.zig`.

**Approach.**
1. `async_hook_registry.zig`: a process-global `std.AutoHashMap` of
   `PendingAsyncHook { process_handle, hook_id, event, command, start_ns,
   timeout_ns, response_sent }`. Provide `register`, `checkResponses` (poll
   completed children, parse the first JSON sync line of stdout into
   `hook_io.Output`), `finalizeAll`, `clear`. Guard with a mutex (background
   spawns may complete on another thread).
2. In `hooks.zig`: when `def.is_async or def.async_rewake`, spawn the child with
   `std.process.spawn` (long-lived; CLAUDE.md says use `spawn` for long-lived),
   write the payload to its stdin, register it, and return immediately as
   `.ran = true, .blocked = false` (no output yet).
3. First-line detection: for *sync* hooks, peek the first stdout line; if it is
   `{"async":true,...}`, transfer to background instead. Add a tiny helper in
   `hook_io.zig`: `pub fn detectAsyncFirstLine(line) ?u64` returning the
   asyncTimeout if present.
4. In `agent_runtime.zig`, at each turn boundary call
   `async_hook_registry.checkResponses`; deliver any finalized
   `additional_context` into the next turn; if a finalized `asyncRewake` hook
   exited 2, inject a continuation (wake the model) with the reason. On session
   end call `finalizeAll`.

**Acceptance criteria.**
- Unit test: registering a fast async hook (`sh -c 'echo {} ; exit 0'`),
  polling `checkResponses` after it completes, yields one response and empties
  the registry.
- Unit test: `detectAsyncFirstLine("{\"async\":true,\"asyncTimeout\":5000}")`
  returns 5000; a normal line returns null.
- Integration: an `async:true` hook does NOT block `runEvent` (the call returns
  before the child's `sleep` finishes; assert wall-clock).

**Test strategy.** Custom runner. Keep child sleeps short. Test the registry in
isolation first, then the non-blocking behavior.

**Risk / footguns.**
- `std.process.spawn(io, opts)` is the long-lived spawner; `std.process.run` is
  one-shot (CLAUDE.md). Use `spawn` here and manage the handle.
- Do not `wait()` after `kill(io)` on timeout (CLAUDE.md `Child.kill` reaps).
- Pipe reads: "for pipes use `readStreaming(io, ...)` since pread is ESPIPE on
  pipes" and "track offset across iterations" (CLAUDE.md). The registry's stdout
  drain must use `readStreaming`.
- This is the riskiest task (concurrency + process lifetime). Land it after the
  synchronous path is solid; keep async strictly opt-in so a bug cannot regress
  the common synchronous path.

**Size.** L.

---

### Task 13 - Dedup by (shell + command/prompt/url + if) within source context (hooks-19) and `once` self-removal (hooks-07)

**Goal.** Collapse identical hooks so duplicates run once; remove `once:true`
hooks after they run.

**Reference behavior + file:line.**
Dedup: `utils/hooks.ts:1735-1756` (a `Map` keyed by
`pluginRoot/skillRoot \0 (shell\0command\0if)`, last-wins). `once`:
`schemas/hooks.ts:51-54` ("runs once and is removed after execution").

**Target Zig files.**
- Edit `src/core/hooks.zig` (`runConfiguredUser`: dedup before exec; remove
  `once` hooks after).
- For `once` removal, edit the settings writer (Phase 1 should own settings
  writes; if not, add a minimal `removeHookFromSettings(allocator, settings_path,
  def)` helper here).

**Approach.**
1. Dedup: before the exec loop, build a `std.StringHashMap(void)` of dedup keys
   `"<shell|bash>\0<body>\0<if_cond>"` (settings hooks share the empty
   plugin-root prefix, so the key is just the content). Skip a def whose key was
   already seen. Since we have a single settings source for now (multi-scope
   merge is Phase 1 / hooks-03 deferred), this guards the duplicate-entries case
   the survey calls out.
2. `once`: after a `once:true` hook runs (any outcome), rewrite `settings.json`
   removing that specific hook entry from its event's array. Use the
   "`&parsed.value.object` by pointer" pattern (CLAUDE.md) to mutate and
   re-serialize. Be conservative: only remove an exact-match entry; never
   rewrite on parse failure.

**Acceptance criteria.**
- Unit test: two identical command defs (same body + shell + if) run once
  (assert the child ran a single time via a side-effect file count).
- Unit test: a `once:true` hook, after `runEvent`, is gone from the rewritten
  `settings.json` (parse the file back and assert the entry is absent); other
  hooks remain.

**Test strategy.** Custom runner with a temp `ZCODE_HOME`/`settings.json`.

**Risk / footguns.**
- Settings rewrite is destructive; do it via a temp file + atomic rename, never
  in place. macOS in-place overwrite footgun is about the binary, but
  temp+rename is the safe pattern for JSON too.
- Without multi-scope merge, dedup mostly matters for literal duplicate entries
  (survey note) - keep it simple, do not build cross-scope merging here.

**Size.** S.

---

### Task 14 - Policy gating + startup snapshot (hooks-12)

**Goal.** Honor `disableAllHooks` / `allowManagedHooksOnly` /
`strictPluginOnlyCustomization`, and capture a startup snapshot so mid-session
settings edits do not change hook behavior until explicitly refreshed.

**Reference behavior + file:line.**
`hooksConfigSnapshot.ts:18-53` (`getHooksFromAllowedSources`: disableAllHooks ->
{}, allowManagedHooksOnly -> managed only, strictPluginOnly -> block
user/project/local, non-managed disableAllHooks -> managed only),
`:95-124` (`captureHooksConfigSnapshot` / `updateHooksConfigSnapshot` /
`getHooksConfigFromSnapshot`).

**Target Zig files.**
- New `src/core/hooks_snapshot.zig` (snapshot + policy gate).
- Edit `src/core/hooks.zig` (`runConfiguredUser` reads from the snapshot, not a
  fresh disk read every call).
- Phase 1's config must expose `policySettings.{disableAllHooks,
  allowManagedHooksOnly}` and the strictPluginOnly policy. If Phase 1 lacks
  these fields, add them to the settings model as part of this task.
- Register `hooks_snapshot.zig` in `main.zig`.

**Approach.**
1. `hooks_snapshot.zig`: `pub fn capture(allocator)` reads merged settings once
   (managed + user + project + local per Phase 1), applies the policy gates, and
   stores the resulting `hook_config.Parsed`-equivalent in a process-global.
   `pub fn get()` returns it (lazily capturing on first call).
   `pub fn refresh()` re-reads (called when the user edits settings via `/hooks`
   or the file watcher fires).
2. Policy gates (port `getHooksFromAllowedSources` exactly):
   `policySettings.disableAllHooks` -> no hooks; `allowManagedHooksOnly` ->
   managed only; `strictPluginOnlyCustomization` -> drop user/project/local;
   non-managed `disableAllHooks` -> managed only.
3. `hooks.zig` `runConfiguredUser` calls `hooks_snapshot.get()` instead of
   reading `settings.json` fresh at `:220`.

**Acceptance criteria.**
- Unit test: with `policySettings.disableAllHooks = true`, the snapshot yields
  zero hooks even when user settings define some.
- Unit test: `allowManagedHooksOnly` yields only managed hooks.
- Unit test: editing the user settings file after `capture` does not change
  `get()`'s result until `refresh()` is called.

**Test strategy.** Custom runner with temp settings files for managed vs user
scope (depends on Phase 1's scope model; if managed-settings path is not yet
available, gate the managed-only assertions behind that and land the snapshot +
disableAllHooks first).

**Risk / footguns.**
- This is low-severity; do not block the high-severity tasks on it. If Phase 1's
  managed-settings surface is incomplete, implement `disableAllHooks` + snapshot
  now and note the managed/strict gates as a follow-up.
- Process-global mutable state needs the same install-once discipline as
  `rt.io`; reset it in tests via a `resetForTest()`.

**Size.** M.

---

### Task 15 - Session-scoped / frontmatter / skill hook registration (hooks-13)

**Goal.** Allow ephemeral in-memory hooks and agent/skill frontmatter hooks to
augment settings.json hooks at runtime.

**Reference behavior + file:line.**
`sessionHooks.ts:68/93` (`addSessionHook`/`addFunctionHook`),
`registerFrontmatterHooks.ts:18` (agent/skill frontmatter; converts
`Stop` -> `SubagentStop` for agents), `registerSkillHooks.ts`,
`hooksConfigManager.ts:322-362` (registered/plugin hooks via
`getRegisteredHooks`).

**Target Zig files.**
- New `src/core/session_hooks.zig` (in-memory registry of `HookDef`s, scoped to
  the session).
- Edit `src/core/hooks.zig` (merge session hooks with snapshot hooks at dispatch
  time).
- Edit the agent/skill frontmatter loaders to call
  `session_hooks.registerFrontmatter(...)`.
- Register `session_hooks.zig` in `main.zig`.

**Approach.**
1. `session_hooks.zig`: a session-scoped `std.ArrayList(HookDef)` (plus owned
   string storage). `pub fn add(def)`, `pub fn list(event) []HookDef`,
   `pub fn clearSession()`. Function/callback hooks (JS closures in the
   reference) cannot be ported literally - support only `command`/`prompt`/
   `http`/`agent` defs here; note the limitation.
2. Frontmatter: when an agent or skill defines `hooks` in its frontmatter,
   register them as session hooks. For agents, convert `Stop` -> `SubagentStop`
   (reference `registerFrontmatterHooks.ts`).
3. At dispatch, `runConfiguredUser` iterates snapshot hooks + session hooks for
   the event.

**Acceptance criteria.**
- Unit test: `session_hooks.add` a PreToolUse command def, then `runEvent`
  `.pre_tool_use` executes it alongside settings hooks.
- Unit test: an agent frontmatter `Stop` hook registers as `SubagentStop`.

**Test strategy.** Custom runner; in-memory only (no settings file needed for
the session-registry test).

**Risk / footguns.**
- Low severity and partly overlaps the plugins subsystem (which is separate).
  Keep this minimal; do not try to unify with plugins in this phase.
- Function hooks are out of scope (no JS runtime) - document explicitly.

**Size.** L (can be split; the session-registry core is M, frontmatter wiring
is the long tail).

---

### Task 16 - Hook-execution event broadcasting + statusMessage (hooks-14, hooks-18)

**Goal.** Emit started/progress/response events for hook execution (for the
transcript/SDK) and show each hook's `statusMessage` in the spinner while it
runs.

**Reference behavior + file:line.**
`hookEvents.ts:93/108/153` (`emitHookStarted/Progress/Response`), `:124`
(`startHookProgressInterval`), `:184` (`setAllHookEventsEnabled` for SDK
`includeHookEvents`). statusMessage: `schemas/hooks.ts:47-50/87/118/155`;
spinner update via `cli/repl_spinner.zig:304` `SpinnerState.update`.

**Target Zig files.**
- New `src/core/hook_events.zig` (a lightweight emitter: a registered callback +
  an `ALWAYS_EMITTED` set {SessionStart, Setup}).
- Edit `src/core/hooks.zig` (emit started/response around exec; pass
  `status_message` to the spinner callback).
- Edit `src/cli/repl_spinner.zig` consumers to render the status message during
  hook runs.
- Register `hook_events.zig` in `main.zig`.

**Approach.**
1. `hook_events.zig`: `pub const Listener = *const fn(ctx, Event) void`; a
   single registerable listener (set by the REPL/SDK). Events:
   `started{event, name, status_message}`, `progress{...}`, `response{...,
   exit_code, stdout, stderr}`. An `ALWAYS_EMITTED` set so SessionStart/Setup
   always emit even without SDK opt-in.
2. In `hooks.zig`, before/after each exec, emit started/response. If a
   `status_message` is set, pass it through the spinner callback (the
   `runHooksWithTrustPrompt` path already has access to UI callbacks via
   `ask_user_fn`/ctx - thread a spinner-update callback the same way, or push it
   through the listener).
3. SDK `includeHookEvents` toggles whether non-always events surface.

**Acceptance criteria.**
- Unit test: a registered listener receives one `started` and one `response`
  event for a single command hook run, with the parsed exit code.
- Unit test: a hook with `statusMessage` invokes the spinner-update callback
  with that message.
- SessionStart emits even when the SDK toggle is off.

**Test strategy.** Custom runner; install a test listener and assert the events
captured.

**Risk / footguns.**
- Lowest priority for a CLI (observability). Land last; do not let it gate the
  correctness tasks.
- Keep the emitter simple (single listener, not a pub/sub bus) - rule 2.

**Size.** M.

---

## Verification

Prove the whole phase is done:

1. **Build + test (debug):**
   ```
   /Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build test
   ```
   All hook tests pass under the custom runner (`tools/test_runner.zig`,
   which prints `RUN: <name>`). New test files (`hooks_lifecycle_test.zig`,
   `mini_regex.zig`, `async_hook_registry.zig`, `hook_exec_prompt.zig`,
   `hook_exec_http.zig`, `session_hooks.zig`, `hooks_snapshot.zig`,
   `hook_events.zig`) are all registered in the `main.zig` comptime block
   (`main.zig:41+`) so the runner discovers them.

2. **Release build + install (per CLAUDE.md):**
   ```
   /Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build -Doptimize=ReleaseFast
   rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode
   ```
   (`rm -f` first to avoid the macOS in-place-overwrite SIGKILL footgun.)
   Bump `.version` patch in `build.zig.zon` for the change.

3. **Manual lifecycle checks** (write to a temp `~/.zcode/settings.json`):
   - **SessionStart additionalContext:** a `SessionStart` command hook printing
     `{"hookSpecificOutput":{"additionalContext":"HELLO-FROM-HOOK"}}`; launch
     `zcode`, ask the model to repeat its injected context, confirm
     `HELLO-FROM-HOOK` is present.
   - **UserPromptSubmit block:** a `UserPromptSubmit` hook exiting 2 with a
     reason; submit a prompt and confirm the turn is blocked with the reason.
   - **Stop force-continue:** a `Stop` hook exiting 2; confirm the agent
     continues once with the injected reason and does not infinite-loop.
   - **PreToolUse allow auto-approve:** a `PreToolUse` hook for `Bash` returning
     `{"hookSpecificOutput":{"permissionDecision":"allow"}}`; confirm a bash
     command runs without the approval prompt.
   - **prompt hook:** a `prompt` hook with `{"ok":false,"reason":"..."}` from a
     (mock or real) small model blocks; `{"ok":true}` allows.
   - **http hook SSRF:** an `http` hook pointing at `http://169.254.169.254/...`
     is refused; one pointing at a local loopback echo server succeeds.
   - **timeout:** a `command` hook with `timeout: 1` running `sleep 5` aborts
     within ~1-2s and does not hang the turn.
   - **once:** a `once:true` hook disappears from `settings.json` after running.

4. **Regression grep:** `grep -rn "if (def.hook_type != .command) continue"
   src/` returns nothing (the hard skip is gone). `grep -rn "hooks.HookEvent"
   src/` returns only the plugins subsystem's own enum.

## Out-of-scope / deferred notes

- **hooks-03 (multi-scope hook merge: user/project/local + plugin/skill merge
  into one matched set).** Not in this phase's gap list. Tasks 13 (dedup) and 14
  (snapshot/policy) are written to work with a single settings source today and
  to extend cleanly once Phase 1 delivers full multi-scope merge. Cross-scope
  dedup and managed-vs-user precedence are deferred until then.
- **Function/callback hooks** (JS closures, `addFunctionHook`,
  `registerStructuredOutputEnforcement`): cannot be ported literally to a native
  binary - no embedded JS runtime. Task 15 supports only declarative
  command/prompt/http/agent session hooks.
- **FileChanged watching + `watchPaths`:** Task 5 parses `watchPaths` but treats
  it as a no-op. The `fileChangedWatcher.ts` filesystem-watch subsystem and the
  `CwdChanged`/`FileChanged` events that depend on it are deferred to a dedicated
  follow-up.
- **Events with no underlying subsystem yet:** `TeammateIdle`, `TaskCreated`,
  `TaskCompleted`, `WorktreeCreate`, `WorktreeRemove`, `Elicitation`,
  `ElicitationResult`, `ConfigChange`, `InstructionsLoaded`, `Setup`. The
  dispatch plumbing (Tasks 2-5) makes them all callable, but wiring each to its
  real lifecycle point depends on those subsystems existing. Wire the ones whose
  subsystems exist (worktree tools and task/team tools are listed as present in
  the roadmap) and defer the rest, firing them where the subsystem already has a
  natural hook point.
- **Full multi-turn agent-hook verifier:** Task 6 may implement the `agent` hook
  as a single-shot json-schema call for first parity; the reference's multi-turn
  StructuredOutput loop (`execAgentHook.ts`) is a follow-up refinement.
- **Output file path:** the orchestrator-provided path used a literal
  `undefined/` prefix (an unresolved variable). This plan was written to
  `/Users/example/Projects/zig-code/docs/cc-parity-plan/phase-05-lifecycle-hook-dispatch-fire-all-events-stdo.md`.
