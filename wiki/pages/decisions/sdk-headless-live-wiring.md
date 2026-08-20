# SDK / headless live dispatch wiring (Phase 21)

The Phase-21 SDK/headless deep modules (`src/sdk/output.zig`, `messages.zig`,
`structured_io.zig`, `control.zig`, `stdout_guard.zig`) were built + unit-tested
but NOT wired into the live process. `--print --output-format json|stream-json`
still routed to the legacy `runOneShot`/`encodeExecJson` blob. This page records
how the live wiring closed that gap.

## The wiring (file:line)

- `src/sdk/headless.zig` (new) is the single live entry. `resolve(output_fmt,
  input_fmt)` -> `Transport`; `isSdkShaped` is the switch main.zig keys off.
- `src/main.zig` `runHeadlessDispatch(...)` is called at the top of the `.run`
  and `.exec` arms. It returns `true` when it handled an SDK transport (caller
  returns), `false` when no transport flag is set (caller keeps the legacy
  text/encodeExecJson path). So legacy `run "x"` / `--print "x"` are byte-for-byte
  unchanged; only `--output-format`/`--input-format` divert.
- Registered in the `src/main.zig` comptime block (`_ = @import("sdk/headless.zig");`).

## Three live paths

1. `--output-format json` (text input): `runOutput(.json)` runs one turn and
   emits a single SDK `result` object (type:"result", num_turns, usage,
   total_cost_usd estimate, permission_denials[], session_id). NOT the legacy blob.
2. `--output-format stream-json` (text input): requires `--verbose`
   (`sdk_output.validateVerboseGate`, exit 2 otherwise). Emits `system:init`
   first (tool list from `tool_schemas.ALWAYS_LOADED_TOOL_NAMES`, version,
   model, cwd) then the `result`, each line through the stdout guard so stray
   non-JSON writes go to stderr tagged `[stdout-guard]`.
3. `--input-format stream-json`: `StreamSession(Reader, Writer)` drives
   `structured_io.runDispatchLoop` over stdin NDJSON. Each `user` line runs a
   turn on a PERSISTENT runtime (so set_model / set_permission_mode / interrupt
   persist across turns). `system:init` is emitted once before the first result.

## can_use_tool relay (the headline feature)

- The session installs `runtime.sdk_relay = .{ .ctx=self, .prompt=relayPromptCb }`.
  `agent_tools.effectiveApproval` already prefers `sdk_relay` over everything
  (even non-interactive), so no turn-loop change was needed.
- `relayPromptCb` runs ON THE SAME THREAD inside the gate while the turn is
  paused. It writes a `can_use_tool` control_request, then BLOCK-READS stdin
  (`awaitDecision`) until a `control_response` whose `response.request_id`
  matches arrives, dispatching any interleaved control_request along the way.
  EOF before a decision = fail-safe deny. This is the synchronous-one-turn
  concurrency model the control modules were designed around (no fibers).
- GOTCHA: the gate only passes `message` (human-readable "shell [MEDIUM]: echo
  hi") to the ApprovalPromptFn; the structured tool_name/input are NOT threaded
  through the gate. So the emitted `can_use_tool` request carries the message as
  `decision_reason` and an empty `tool_name`. Threading the structured fields
  would require rewriting the turn loop (out of scope, deferred).

## Live control subtypes

`handleControlRequest` routes host->CLI control_requests: `initialize` ->
`structured_io.dispatchInitialize` (pid via portable `currentPid()`, double-init
-> "Already initialized"); `interrupt`/`set_permission_mode`/`set_model`/
`set_max_thinking_tokens` -> `control.dispatchLiveControl` backed by a
`LiveControlMutator` wired to `runtime.requestInterrupt/setApprovalMode/
setActiveModel/setReasoningTokens`. `update_environment_variables` ->
`structured_io.applyEnvUpdates`.

## Test gotchas hit

- The headless test config defaults to `approval_mode = "tiered-auto"`, which
  AUTO-APPROVES a MEDIUM-risk shell call without ever reaching the relay. The
  can_use_tool integration tests must force `cfg.approval_mode = "manual"` so the
  gate prompts.
- In a bare tmp cwd (not a git repo) the mock's default `git_status` tool is
  filtered out by the runtime's `isGitRepo` gate, so it may not reach the
  permission gate. Set `ZCODE_MOCK_RESPONSE` to a `shell` call (always-loaded,
  MEDIUM risk) to reliably trigger the gate. The env override goes through
  `env.setOverride` (consulted by `getenv`/`getOwned` first) -- `defer
  env.clearOverrides()`.
- A custom test reader fed into `structured_io.runDispatchLoop` must declare its
  error set to INCLUDE `error{StreamTooLong}` (the loop switches on it), e.g.
  `(std.mem.Allocator.Error || error{StreamTooLong})!?[]u8`, or the inferred set
  mismatches the switch.
- Duck-typed writer methods passed through generic helpers (the stdout-guard
  adapter in main.zig, the ScriptedHost) must be `pub`.

## Deferred / not done

- Structured tool_name/input in the `can_use_tool` request (needs turn-loop
  threading).
- `hook_callback` / `elicitation` host relays are built in `control.zig` but not
  invoked from the live session loop (they need the local hook/elicitation call
  sites to consult a host channel; surgical follow-on).
- `--permission-prompt-tool`, streamlined transform, partial `stream_event`
  emission: modules exist, not wired into this dispatch.
- A python SDK-host smoke test deadlocks on pipe buffering (host block-reads
  stdout while the relay block-reads stdin); use non-blocking I/O on the host
  side. The Zig in-memory ScriptedHost test proves the round-trip deterministically.
