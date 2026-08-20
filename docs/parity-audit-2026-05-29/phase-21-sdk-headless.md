# Phase 21: SDK / headless control protocol and non-interactive output

## Overview

**What.** Claude Code can be driven entirely as a subprocess by an SDK host (the Python/TS Agent SDK, VS Code, CI scripts). The wire surface has four layers:

1. **Output selection** - `-p/--print` runs a single non-interactive turn; `--output-format text|json|stream-json` chooses how messages serialize; `--input-format text|stream-json` chooses how prompts and control messages arrive.
2. **SDK message schemas** - a `system:init` message and a typed `result` message (`num_turns`, `total_cost_usd`, `usage`, `modelUsage`, `permission_denials`, `structured_output`, `stop_reason`, `duration_api_ms`), defined as Zod in `coreSchemas.ts`.
3. **Bidirectional control protocol** - a `control_request`/`control_response`/`control_cancel_request` envelope where the CLI *originates* requests back to the host (`can_use_tool` permission relay), and the host originates requests into the CLI (`interrupt`, `set_permission_mode`, `set_model`, `set_max_thinking_tokens`, `initialize`, `hook_callback`, `elicitation`), keyed by `request_id` against a pending map.
4. **Robustness + refinements** - a stdout guard that diverts stray non-JSON lines to stderr, a streamlined output transform, partial `stream_event` messages, `keep_alive` / `update_environment_variables` stdin messages, and the public SDK type package.

**Why.** zcode today has a *different* non-interactive story: `run`/`exec` subcommands (one-shot, exit), a custom JSON-RPC server (`zcode api serve`) over jsonl-stdio, and a strictly local permission engine. None of these speak the SDK wire protocol, so no first-party SDK or editor host can drive zcode the way it drives Claude Code. The headline missing capability is the `can_use_tool` permission relay - the feature editor integrations depend on. The data for `result`/`system:init` (rounds, cost, tokens) already exists internally; the gap is the SDK-compatible serialized shape.

**Dependencies on earlier phases.** This phase rides on infrastructure that already exists and was covered by earlier phases:
- Permission engine + risk tiers + `ApprovalHandler` callback (the local side of `can_use_tool`).
- Hooks subsystem (`core/hooks.zig`, `core/hook_event.zig`) - the local side of `hook_callback`.
- MCP elicitation (`agent_history.zig`) - the local side of the `elicitation` relay.
- Cost/usage/metrics (`core/cost.zig`, `core/metrics.zig`, `AgentRuntime.token_status`) - the data behind the `result` message.
- The `api serve` jsonl-stdio loop (`api_server.zig`) - the closest existing stream plumbing, and a useful structural template (line cap, total cap, per-line dispatch) even though the protocol differs.

There is a hard internal ordering inside this phase: gap 03 (streaming stdin) and gap 02 (stream-json output) are the transport foundation; gaps 04/05/06/10/11 (the control protocol) cannot exist without them; gaps 09/12/13 are refinements on top.

**Effort.** Large. This is the single biggest behavioral surface in the parity effort. Realistic sequencing across multiple PRs: foundation (01/02/07) first, then transport (03) + control envelope (04), then the permission relay (05) and live-control subtypes (06), then the rest. Estimated total ~3-4 L items plus several M/S items.

## Scope split

| Item | Decision | Reason |
|---|---|---|
| sdk-headless-01 (`--print`/`-p` flag + gating) | IN-SCOPE | CLI-surface parity; small once we accept `exec`/`run` cover the execution. Resolve the `-p` collision deliberately. |
| sdk-headless-02 (`--output-format json\|stream-json`) | IN-SCOPE | Transport foundation. The SDK `result` shape and NDJSON streaming live here. |
| sdk-headless-03 (`--input-format stream-json`) | IN-SCOPE | Transport foundation. The whole control protocol rides on streaming stdin. |
| sdk-headless-04 (control envelope protocol) | IN-SCOPE | Core of the phase. Bidirectional `control_request`/`control_response`/`control_cancel_request`. |
| sdk-headless-05 (`can_use_tool` relay) | IN-SCOPE | Headline feature for editor/host integrations. |
| sdk-headless-06 (interrupt/set_permission_mode/set_model/set_max_thinking_tokens) | IN-SCOPE | Live session control; small per-subtype once 04 lands. |
| sdk-headless-07 (`system:init` + `result` schema) | IN-SCOPE | Data largely exists; we add the SDK-shaped serialization. |
| sdk-headless-10 (`initialize` handshake + init response) | IN-SCOPE | All bundled capabilities exist; only the handshake is missing. |
| sdk-headless-11 (`hook_callback` / `elicitation` relay) | IN-SCOPE | Local hooks + elicitation exist; add the relay path. |
| sdk-headless-08 (streamlined output transform) | IN-SCOPE (low priority) | Self-contained transform; ant-gated + env opt-in in reference. Build the categorizer + summary; gate behind env var. |
| sdk-headless-09 (stream-json stdout guard) | IN-SCOPE (low priority) | Small once stream-json exists. We already have the NDJSON-safe escaper half. |
| sdk-headless-12 (partial messages / include-partial / include-hook-events / replay) | IN-SCOPE (low priority) | Refinements on stream-json; flag-gated emission. |
| sdk-headless-13 (`keep_alive` / `update_environment_variables` stdin messages) | IN-SCOPE (small) | Cheap to parse; `keep_alive` is a no-op, env update is bounded scope. |
| sdk-headless-14 (`--permission-prompt-tool` / `--max-turns` / `--max-budget-usd` / `--json-schema` / `--fork-session` / `--thinking`) | IN-SCOPE except `--permission-prompt-tool` | Most map to existing internals (budget, max turns, structured output, fork). `--permission-prompt-tool` requires the `can_use_tool` relay; build it after gap 05. |
| sdk-headless-15 (public SDK type package: agentSdkTypes/coreSchemas/controlSchemas) | OUT-OF-SCOPE (document) | zcode is a standalone reimplementation, not a host for the first-party SDKs. Shipping an importable Zod/proto package has near-zero value. We will instead extend `zcode api schema` to document the wire shape. |

## Gaps covered

| id | title | severity | size | our current state |
|---|---|---|---|---|
| sdk-headless-01 | `--print`/`-p` headless flag (+ `-p` collision) | medium | M | `run` (text) / `exec` (JSON) subcommands exist; no `--print`; `-p`=`--provider` (`args.zig:274`) |
| sdk-headless-02 | `--output-format json\|stream-json` | high | L | only `--json` bool + custom `encodeExecJson` blob (`ci_output.zig:14`); no format selector, no NDJSON streaming |
| sdk-headless-03 | `--input-format stream-json` | high | L | `zcode api serve` jsonl-stdio loop exists (`api_server.zig:286`) but no `--input-format` flag and a different protocol |
| sdk-headless-04 | control_request/response/cancel envelope | high | L | `api serve` is one-shot request/response only; CLI never originates a request back |
| sdk-headless-05 | `can_use_tool` permission relay | high | L | permission engine is strictly local (`agent_tools.zig:519`); non-interactive auto-denies |
| sdk-headless-06 | interrupt/set_permission_mode/set_model/set_max_thinking_tokens | high | L | interrupt only via SIGINT (`main.zig`); model/mode are config-time only |
| sdk-headless-07 | `system:init` + `result` schema | medium | M | `encodeExecJson` has session_id/provider/model/rounds/response/tool_calls; missing init msg, cost/usage/denials/stop_reason |
| sdk-headless-08 | streamlined output transform | low | M | absent; `--json` emits full tool traces |
| sdk-headless-09 | stream-json stdout guard | low | M | NDJSON-safe escaper exists (`parse_helpers.zig:106`); no runtime stdout interceptor |
| sdk-headless-10 | `initialize` handshake + init response | medium | L | config loaded at startup only; no per-session handshake; `api schema` lists 12 methods, none `initialize` |
| sdk-headless-11 | `hook_callback` / `elicitation` relay | medium | M | hooks are local subprocesses; elicitation is in-process; no relay path |
| sdk-headless-12 | partial messages / include-partial / include-hook-events / replay | low | M | `HookEvent` enum exists (`hook_event.zig`); no NDJSON streaming, no `stream_event` |
| sdk-headless-13 | `keep_alive` / `update_environment_variables` | low | S | env read once at startup (`core/env.zig`); no stdin message protocol |
| sdk-headless-14 | headless gating flags (`--max-turns`, `--max-budget-usd`, `--json-schema`, `--fork-session`, `--thinking`, `--permission-prompt-tool`) | medium | M | internals exist (budget_control, max_history_turns, /format json, session fork); none exposed as headless flags |

## Implementation tasks

> Convention reminders enforced throughout: new deep modules go under `src/core/` (or a new `src/sdk/` package for the protocol layer); every new module is registered in the `comptime { _ = @import(...); }` block in `src/main.zig` (currently lines 41+) so its tests run; all source imports use `@import("zcode_runtime")` for the runtime singleton, never relative paths to it; IO comes from `core/std_io.zig`, time from `core/clock.zig`, randomness from `core/rng.zig`. Bump `.version` in `build.zig.zon` per change.

---

### Task A - gap 01: `--print`/`-p` headless flag and `-p` collision resolution

**Goal.** Accept `--print` (and a non-colliding short flag) as a synonym path into the existing one-shot execution, so scripts written against Claude Code's flag surface work, and the `-p` ambiguity is resolved deterministically.

**Reference behavior + file:line.** `main.tsx:976` `.option('-p, --print', 'Print response and exit ...')`; `cli/print.ts:455` `runHeadless` entry. `-p`/`--print` gates all other headless flags.

**Target Zig files.** `src/cli/args.zig` (flag parsing at ~lines 219-276; `CommandKind` enum lines 5-108; `CliOptions` lines 110-191), `src/main.zig` (dispatch at lines 640-695).

**Approach.**
1. Add `--print` handling in `args.zig`. When seen, set `options.command = .run` if no `--output-format` is given, or route to the output-format dispatcher (Task B). `--print` with a trailing positional sets `options.prompt`.
2. Resolve the `-p` collision explicitly. zcode already binds `-p` to `--provider` (the survey notes `args.zig:274` for `--provider`; verify whether a literal `-p` short alias exists). Decision to encode in the plan: keep `-p` = `--provider` for backward compat (zcode users rely on it) and document that `--print` has **no short alias** in zcode, with a one-line help note explaining the deliberate divergence. This is the surgical choice - it does not silently break existing `-p` users.
3. Make `--print` imply the headless gate (Task B's `headless` bool on `CliOptions`) so `--output-format`, `--input-format`, `--max-turns` etc. are only honored under `--print` (or under `run`/`exec`), matching the reference gating.

**Acceptance criteria.** Write a test in `args.zig` that parses `["--print", "hello"]` and asserts `command == .run` and `prompt == "hello"`; parses `["-p", "openai", "exec", "hi"]` and asserts `provider == "openai"` (no collision); parses `["--print", "--output-format", "json", "hi"]` and asserts the headless gate is set and format is json.

**Test strategy.** Pure parser tests under `tools/test_runner.zig` - no IO. Add to the existing `args.zig` test block.

**Risk + 0.16 footguns.** Low. The only real risk is silently changing `-p` semantics; the plan keeps it stable. Watch the `--` separator logic already in `args.zig` (line ~203) so `--print -- --literally-a-prompt` still works.

**Size.** M.

---

### Task B - gap 02: `--output-format text|json|stream-json` + NDJSON serialization

**Goal.** Add a format selector that produces (a) `text` = current human text, (b) `json` = a single SDK `result` message, (c) `stream-json` = realtime NDJSON of every SDK message (requires `--verbose`, like the reference).

**Reference behavior + file:line.** `main.tsx:976` `Option('--output-format <format>').choices(['text','json','stream-json'])`; `cli/print.ts:917` `switch(options.outputFormat)`; `print.ts:787` requires `--verbose` for stream-json.

**Target Zig files.** New `src/sdk/output.zig` (deep module: format enum + serializer); `src/cli/args.zig` (add `output_format: ?[]const u8` to `CliOptions`, parse `--output-format`/`--output-format=`); `src/main.zig` (dispatch; register `src/sdk/output.zig` in the comptime block); reuse `src/core/ci_output.zig` and `src/core/parse_helpers.zig:appendNdjsonSafe`.

**Approach.**
1. Define `pub const OutputFormat = enum { text, json, stream_json };` with a parser that rejects unknown values (return a usage error matching `args.zig`'s `reportUsageError` style).
2. For `text`: route to the existing `run` rendering path (`main.zig:645-670`).
3. For `json`: emit the **SDK `result` message** from Task D (gap 07), not the current `encodeExecJson` blob. The current blob can remain the wire shape for `zcode api serve`'s `run` method, but `--output-format json` must emit the `type:"result"` shape.
4. For `stream-json`: require `--verbose` (error otherwise, matching reference). Emit one NDJSON line per SDK message: `system:init` first (Task G), then assistant/tool messages, then the final `result`. Each line must be NDJSON-safe (`parse_helpers.zig:appendNdjsonSafe`) and newline-terminated, written via `core/std_io.zig` stdout writer.
5. Gate the whole selector behind the headless gate (only honored under `--print`/`run`/`exec`).

**Acceptance criteria.** Write a test that calls the json serializer for a synthetic `TurnResult` and asserts the parsed object has `type=="result"`, `subtype=="success"`, and `num_turns` present. Write a test that the stream-json serializer emits a `system:init` line first and a `result` line last, and that each line independently `std.json.parseFromSlice`-parses. Write a test that `--output-format stream-json` without `--verbose` returns a usage error.

**Test strategy.** Serializer tests in `src/sdk/output.zig` (no live model). Drive `runOneShot` against the `mock` provider for an end-to-end NDJSON test if the test harness allows it; otherwise unit-test the serializer with a hand-built result struct.

**Risk + 0.16 footguns.** `std.json.fmt(...)` with `{f}` formatting is the established pattern (see `ci_output.zig:27`, `api_server.zig:240`). When building NDJSON lines, do not let `std.json.fmt` emit raw U+2028/U+2029 - route string fields through `appendNdjsonSafe` or confirm the encoder escapes them. `StringBuilder` (the `std_io.zig` facade over `std.Io.Writer.Allocating`) is the right buffer; remember `toOwnedSlice` ownership.

**Size.** L.

---

### Task C - gap 03: `--input-format stream-json` streaming stdin

**Goal.** Read `SDKUserMessage` and `control_request` lines from stdin as an async NDJSON stream, enabling multi-turn and live control over a running process. This is the transport the control protocol rides on.

**Reference behavior + file:line.** `main.tsx:976` `Option('--input-format <format>').choices(['text','stream-json'])`; `cli/structuredIO.ts` `read()`/`processLine()` parse the `StdinMessage` union; `controlSchemas.ts:655` `StdinMessageSchema` = `SDKUserMessage | SDKControlRequest | SDKControlResponse | keep_alive | update_environment_variables`.

**Target Zig files.** New `src/sdk/structured_io.zig` (the stdin reader + line dispatcher); `src/cli/args.zig` (add `input_format`, parse `--input-format`); `src/main.zig` (dispatch + register module). Structural template: `api_server.zig:286-331` (the line-cap / total-cap / `readUntilDelimiterOrEofAlloc` loop) - reuse the bounded-read discipline, not the protocol.

**Approach.**
1. Add `pub const InputFormat = enum { text, stream_json };` with a parser.
2. Build the read loop modeled on `api_server.zig:286-331`: per-line cap (1 MiB), per-connection total cap (10 MiB), skip blank lines, emit a terminating error envelope on cap hit.
3. Parse each line as the `StdinMessage` union (Task E defines the envelope structs). Dispatch by `type`: `user` -> enqueue a turn; `control_request` -> route to the control dispatcher (Task F); `control_response` -> resolve a pending CLI-originated request (Task E pending map); `keep_alive` -> no-op (Task L); `update_environment_variables` -> apply (Task L).
4. Multi-turn: after a `result`, loop back to read the next stdin message rather than exiting (this is the key behavioral difference from `run`/`exec` one-shot).
5. Gate behind the headless gate.

**Acceptance criteria.** Write a test that feeds a fixed NDJSON buffer (one `user` message) through the dispatcher and asserts a turn is enqueued; feeds a malformed line and asserts it is diverted/errored without crashing; feeds two `user` messages and asserts both turns run (multi-turn). Use the `mock` provider so the turn is deterministic.

**Test strategy.** The dispatcher must take a reader and a writer as parameters (not hardcode `std_io.stdinReader()`) so tests can feed a fixed-buffer reader. Tests run under `tools/test_runner.zig` which installs `rt.io`.

**Risk + 0.16 footguns.** Per the project CLAUDE.md: `readUntilDelimiterOrEofAlloc` here is fine (it's the same call `api_server.zig` uses), but for any pipe reads use `readStreaming(io, &.{&buf})` since `pread` is ESPIPE on pipes; track offset across iterations to avoid re-reading byte 0. `std.json.parseFromSlice` returns a `Parsed(T)` whose `.deinit()` must be called; do not retain slices into `parsed.value` past `deinit`.

**Size.** L.

---

### Task D - gap 04: control_request / control_response / control_cancel_request envelope

**Goal.** A typed bidirectional envelope: `{type:"control_request", request_id, request:{subtype,...}}`, `{type:"control_response", response:{subtype:"success"|"error", request_id, response?|error, pending_permission_requests?}}`, and `{type:"control_cancel_request", request_id}`, with a per-`request_id` pending map so the CLI can originate requests to the host and await responses.

**Reference behavior + file:line.** `controlSchemas.ts:578` `SDKControlRequestSchema`, `:605` `SDKControlResponseSchema`, `:612` `SDKControlCancelRequestSchema`, `:594` `ControlErrorResponseSchema` (carries `pending_permission_requests`); `structuredIO.ts:469` `sendRequest` (enqueue + pending map + abort -> `control_cancel_request`); `print.ts:2830` dispatch.

**Target Zig files.** New `src/sdk/control.zig` (envelope encode/decode + subtype tagged union); `src/sdk/structured_io.zig` (pending map: `std.StringHashMap` keyed by `request_id`); register both in `main.zig` comptime block.

**Approach.**
1. Define the inner request as a Zig tagged union over subtypes: `interrupt`, `can_use_tool`, `initialize`, `set_permission_mode`, `set_model`, `set_max_thinking_tokens`, `hook_callback`, `elicitation` (others stubbed/unsupported -> error response). Decode from `std.json.Value` by reading `request.subtype`.
2. `sendRequest(subtype, payload)` -> generate a `request_id` via `core/rng.zig`, encode the envelope, write it to stdout (NDJSON), insert a pending entry, and block the originating fiber until a matching `control_response` arrives or a `control_cancel_request` is emitted.
3. `handleControlResponse(value)` -> look up `request_id` in the pending map, resolve it, free the entry. Orphan/duplicate responses (no pending entry) are logged and ignored (matches reference dedup intent).
4. Error responses carry `pending_permission_requests` (an array of the still-open `can_use_tool` envelopes) - implement the array even if usually empty.
5. Cancel: on abort, emit `control_cancel_request` and reject the pending promise immediately without waiting for host ack (reference `structuredIO.ts:490`).

**Acceptance criteria.** Write a round-trip test: encode a `control_request` of each supported subtype, parse it back, assert the subtype and payload survive. Write a test that `handleControlResponse` resolves a matching pending entry and that an orphan response is a no-op (no crash, pending map unchanged). Write a test that the error response shape serializes with a `pending_permission_requests` array.

**Test strategy.** Pure encode/decode + pending-map tests. The blocking `sendRequest` needs the fiber/async story - if zcode's runtime does not expose cooperative fibers, model `sendRequest` as a state object (`Pending`/`Resolved`/`Cancelled`) the dispatcher drives, and test the state transitions synchronously by feeding a response line. Confirm against `core/runtime.zig` whether `std.Io` async is wired; the survey shows the codebase is mid-migration (Stage 4 threads `io` explicitly), so prefer the explicit state-machine model over assuming green-thread blocking.

**Risk + 0.16 footguns.** The biggest risk is the concurrency model. zcode is synchronous one-turn today; `can_use_tool` requires pausing tool execution mid-turn while awaiting a host response. Model this as a callback-driven state machine, not blocking IO, to avoid fighting the runtime. `std.StringHashMap` keys must be owned (dupe the `request_id`); free on removal. `ObjectMap.put` after parse needs a pointer to the object (project footgun: a value copy desyncs the entries pointer on realloc).

**Size.** L.

---

### Task E - gap 05: `can_use_tool` permission relay

**Goal.** When a tool needs permission and the session is host-driven, emit a `can_use_tool` `control_request` (with `tool_name`, `input`, `permission_suggestions`, `blocked_path`, `decision_reason`, `tool_use_id`, `agent_id`) and await the host's `control_response` decision, instead of the local stdin prompt or auto-deny.

**Reference behavior + file:line.** `controlSchemas.ts:106` `SDKControlPermissionRequestSchema`; `structuredIO.ts:533` `createCanUseTool()` -> `Promise.race(hookPromise, sdkPromise)`; `resolvedToolUseIds` dedup; `structuredIO.ts:178` orphan dedup.

**Target Zig files.** `src/sdk/structured_io.zig` (the relay approver); `src/agent_tools.zig` (`effectiveApproval` at line 519 - add a third approver source: SDK relay, ahead of stdin); `src/agent_runtime.zig` (`ApprovalHandler` plumbing).

**Approach.**
1. Add an `ApprovalHandler` variant whose callback packages a `can_use_tool` request and calls `control.sendRequest` (Task D), then maps the host's `control_response` decision to `types.ApprovalResponse`.
2. In `effectiveApproval` (`agent_tools.zig:519`), prefer the SDK relay handler when the session is host-driven (input-format stream-json), then the installed REPL handler, then stdin, then auto-deny. Surgical: only add a branch; do not rewrite the existing precedence.
3. Carry the reference fields. Map zcode's risk tier / decision reason into `decision_reason`; `permission_suggestions` from the local permission engine's suggestion output if available, else empty array.
4. Dedup: track resolved `tool_use_id`s (bounded set, like reference `MAX_RESOLVED_TOOL_USE_IDS`) so a late/duplicate host response is ignored.
5. Optional hook race (reference runs `PermissionRequest` hooks concurrently): only if the hook subsystem already supports `PermissionRequest` - the survey notes `hook_event.zig:12` defines `permission_request` but it is **never invoked**. Defer the race; do the SDK relay first, and note the hook race as a follow-on.

**Acceptance criteria.** Write a test that the relay approver, given a stubbed dispatcher that returns an `allow` `control_response` for a `can_use_tool` request, yields `ApprovalResponse.approved`; a `deny` response yields denied; a duplicate `tool_use_id` response is ignored. Write a test that `effectiveApproval` selects the SDK relay when host-driven and falls back to stdin otherwise.

**Test strategy.** Use a stub dispatcher (fixed-buffer) feeding pre-canned `control_response` lines, since there is no live host. The mock provider supplies a deterministic tool call that triggers a permission prompt.

**Risk + 0.16 footguns.** Same concurrency caveat as Task D - the approver must not deadlock the turn loop. Ensure the `tool_use_id` is generated/threaded consistently between the request and the dedup set. Free duped JSON `input` after encoding.

**Size.** L.

---

### Task F - gap 06: live-control subtypes (interrupt, set_permission_mode, set_model, set_max_thinking_tokens)

**Goal.** Let a host interrupt the running turn, switch permission mode, change model, and set max thinking tokens mid-session via `control_request` subtypes.

**Reference behavior + file:line.** `controlSchemas.ts:97/124/137/146`; `print.ts:2831` (interrupt -> `abortController.abort()`), `:2918` (set_permission_mode), `:2933` (set_model), `:2945` (set_max_thinking_tokens); `QueryEngine.ts:1158` `interrupt()`, `:1174` `setModel()`.

**Target Zig files.** `src/sdk/control.zig` (subtype dispatch); `src/agent_runtime.zig` (expose runtime mutators: an abort flag the turn loop checks; `setActiveModel`; `setApprovalMode`; `setReasoningTokens`). Reuse the existing interrupt machinery in `main.zig:146-201` but route a cooperative cancel into the turn loop rather than a process-killing signal.

**Approach.**
1. `interrupt`: set a cooperative abort flag on `AgentRuntime` that the tool-round loop checks between rounds; respond `success`. (Do not `std.process.exit` - that is the SIGINT path; the SDK interrupt must leave the process alive for the next turn.)
2. `set_permission_mode`: mutate `runtime.approval_mode` for subsequent tool calls; respond `success`. zcode already has `/policy` semantics in the REPL - reuse the same mode parser.
3. `set_model`: mutate `runtime.active_model` (and provider if the model string implies one) for subsequent turns; respond `success`. zcode has `/model` in the REPL - reuse its resolution.
4. `set_max_thinking_tokens`: map to `reserved_reasoning_tokens` (config field) on the runtime; `null` clears, `0` disables; respond `success`.

**Acceptance criteria.** Write a test that dispatching a `set_model` control_request mutates `runtime.active_model` and produces a `success` control_response with the matching `request_id`; same for `set_permission_mode`. Write a test that an `interrupt` request sets the runtime abort flag (and that a tool loop honoring the flag exits the round early).

**Test strategy.** Unit tests against an `AgentRuntime` built for the mock provider; assert field mutations and response envelopes. The interrupt-mid-loop test drives a multi-round mock prompt and asserts the loop stops after the flag is set.

**Risk + 0.16 footguns.** The cooperative-abort flag must be checked at safe points (between rounds, between tool calls) not mid-syscall. Avoid touching the SIGINT handlers (`main.zig:146-201`) - they own terminal restore; add an independent abort flag.

**Size.** L (but each subtype is small once Task D lands).

---

### Task G - gap 07: `system:init` + SDK `result` message schema

**Goal.** Emit a `system:init` message (tools, mcp_servers, model, permissionMode, slash_commands, skills, plugins, cwd, version) at session start, and a typed `result` message (`subtype` success/error, `num_turns`, `total_cost_usd`, `usage`, `modelUsage`, `duration_ms`, `duration_api_ms`, `permission_denials`, `structured_output`, `stop_reason`, `is_error`, `session_id`).

**Reference behavior + file:line.** `coreSchemas.ts:1457` `SDKSystemMessageSchema`, `:1407` `SDKResultSuccessSchema`, `:1428` `SDKResultErrorSchema`, `:1399` `SDKPermissionDenialSchema`.

**Target Zig files.** New `src/sdk/messages.zig` (init + result serializers); reuse `core/cost.zig:estimateCost`, `AgentRuntime.token_status` (`agent_runtime.zig:100-101`, `:251`), `core/metrics.zig`. Register in comptime block. Keep `core/ci_output.zig:encodeExecJson` for the legacy `api serve` shape (do not break it).

**Approach.**
1. `result` success message: map `result.rounds` -> `num_turns`; `result.final_text` -> `result`; `cost.estimateCost(provider, model, in, out)` -> `total_cost_usd`; `token_status.total_input_tokens/total_output_tokens` -> `usage`; a single-entry `modelUsage` keyed by the active model; `duration_ms` from `clock.nowMillis()` deltas; `duration_api_ms` from accumulated provider call time if tracked (else `duration_ms`); `permission_denials` from a new denial tracker (Task E surfaces denied tool calls); `structured_output` from the `/format json` schema path if active; `stop_reason` from the turn outcome; `session_id` from `runtime.session_id`.
2. `result` error message: `subtype` in `{error_during_execution, error_max_turns, error_max_budget_usd, error_max_structured_output_retries}` driven by Task K's limit flags.
3. `system:init`: gather tools (tool registry), mcp_servers (mcp client status), model/permissionMode/cwd/version, slash_commands/skills/plugins from their registries. Emit it as the first NDJSON line in stream-json mode and as the first element where the reference would emit it.

**Acceptance criteria.** Write a test that the result serializer for a synthetic `TurnResult` parses to an object with `type=="result"`, `subtype=="success"`, `num_turns`, `total_cost_usd`, `usage.input_tokens`, `usage.output_tokens`, `permission_denials` (array), and `session_id`. Write a test that the init serializer parses to `type=="system"`, `subtype=="init"`, and contains `tools`, `model`, `cwd`, `claude_code_version`.

**Test strategy.** Serializer unit tests with hand-built inputs; one mock-provider end-to-end test asserting the emitted result has nonzero `num_turns`.

**Risk + 0.16 footguns.** `duration_api_ms` may not be tracked separately today - if so, set it equal to `duration_ms` and note the approximation rather than inventing a number (project rule: do not state guesses as facts; here, do not emit a fabricated metric). Cost is an *estimate* (`estimateCost`) - the field name `total_cost_usd` is parity-correct but document that it is an estimate, not a billed figure.

**Size.** M.

---

### Task H - gap 10: `initialize` control_request + init response

**Goal.** Handle an `initialize` `control_request` that configures hooks, sdkMcpServers, jsonSchema, systemPrompt, appendSystemPrompt, agents, promptSuggestions; reply with `commands`, `agents`, `output_style`, `available_output_styles`, `models`, `account`, `pid`, `fast_mode_state`.

**Reference behavior + file:line.** `controlSchemas.ts:57` `SDKControlInitializeRequestSchema`, `:77` `SDKControlInitializeResponseSchema`; `print.ts:2863` initialize dispatch; `print.ts:4339` `handleInitializeRequest` (rejects double-init with "Already initialized").

**Target Zig files.** `src/sdk/control.zig` (initialize subtype); `src/sdk/structured_io.zig` (one-time `initialized` flag); reuse `core/agents.zig`, `core/commands.zig`, `core/plugins.zig`, model registry, and the existing `--append-system-prompt` plumbing (`args.zig:145`).

**Approach.**
1. On `initialize`: if already initialized, respond error `"Already initialized"` (match reference). Otherwise apply: `systemPrompt`/`appendSystemPrompt` override (reuse existing append-system-prompt fields), register `agents` definitions, register `sdkMcpServers` placeholders, store `jsonSchema` as the structured-output schema, set `promptSuggestions`.
2. Build the init response by calling the existing list renderers (commands/agents/models) and `pid` via `std.os` / the process API; `output_style` and `available_output_styles` from the output-style registry; `account` minimally populated.
3. Set `initialized = true`; drain any pre-enqueued command (reference behavior).

**Acceptance criteria.** Write a test that dispatching an `initialize` request with an `appendSystemPrompt` applies it to the runtime and returns a `success` response containing `commands`, `agents`, and `models` arrays. Write a test that a second `initialize` returns an error response with message `"Already initialized"`.

**Test strategy.** Unit tests against a runtime + stub dispatcher; assert state mutation and response shape.

**Risk + 0.16 footguns.** Account/`fast_mode_state` are ant-specific - emit minimal/empty objects rather than fabricating fields. Agent/MCP registration must not double-free if the same names already exist from CLI flags (reference preserves SDK-provided agents).

**Size.** L.

---

### Task I - gap 11: `hook_callback` / `elicitation` relay

**Goal.** Invoke SDK-registered hooks by emitting a `hook_callback` `control_request` to the host, and relay MCP elicitation to the host via an `elicitation` `control_request`, resolving both by `control_response`.

**Reference behavior + file:line.** `controlSchemas.ts:363` `SDKHookCallbackRequestSchema`, `:522/:538` elicitation request/response; `structuredIO.ts:661` `createHookCallback()`, `:694` `handleElicitation()`.

**Target Zig files.** `src/sdk/control.zig` (both subtypes); `src/core/hooks.zig` (add an SDK-relay hook source alongside the local-subprocess source at `hooks.zig:132-331`); `src/agent_history.zig` (elicitation at `:902-930` - add a relay branch).

**Approach.**
1. `hook_callback`: when a hook is registered as an SDK callback (via `initialize`), instead of spawning a local subprocess, emit a `hook_callback` request with `callback_id`, `input` (the `HookInput`), `tool_use_id`; map the host's `control_response` back to the hook decision (`HookJSONOutput` analogue).
2. `elicitation`: when MCP elicitation fires and the session is host-driven, emit an `elicitation` request (`mcp_server_name`, `message`, `mode`, `url`, `elicitation_id`, `requested_schema`) and resolve from the host's `{action: accept|decline|cancel, content?}` response, instead of the in-process prompt.
3. Both are no-ops on the local code path (preserve current behavior when not host-driven).

**Acceptance criteria.** Write a test that a registered SDK hook, when fired, emits a `hook_callback` request and resolves from a stubbed `control_response`. Write a test that an elicitation, when host-driven, emits an `elicitation` request and maps an `accept` response to the same result the in-process path would produce.

**Test strategy.** Stub dispatcher with pre-canned responses; assert request emission and decision mapping. Local-path tests assert no relay occurs.

**Risk + 0.16 footguns.** Concurrency again - both relays pause local flow awaiting the host. Use the same state-machine model as Task D. Keep the local subprocess hook path untouched when no SDK callbacks are registered (surgical).

**Size.** M.

---

### Task J - gap 13: `keep_alive` / `update_environment_variables` stdin messages

**Goal.** Accept `keep_alive` (silently ignored) and `update_environment_variables` (apply key/values at runtime, for auth-token refresh) as stdin message types.

**Reference behavior + file:line.** `controlSchemas.ts:621/:629`; `structuredIO.ts:344` (keep_alive no-op), `:348` (apply env vars, log applied keys).

**Target Zig files.** `src/sdk/structured_io.zig` (dispatch); a small runtime env-override map (zcode reads env once via `core/env.zig:40-50` libc getenv, which cannot be mutated, so maintain an in-process override map consulted ahead of getenv).

**Approach.**
1. `keep_alive`: no-op (just continue the read loop).
2. `update_environment_variables`: store key/values in an in-process override map; have the env lookup path consult the override map first. Scope it to auth-relevant keys (the reference use is auth-token refresh) and log the applied key *names* only (never values), matching `structuredIO.ts:358`.

**Acceptance criteria.** Write a test that a `keep_alive` line is consumed without effect. Write a test that an `update_environment_variables` line updates the override map and a subsequent lookup returns the new value; assert the log line contains the key name but not the value.

**Test strategy.** Dispatcher unit tests with fixed-buffer input.

**Risk + 0.16 footguns.** `core/env.zig` uses libc `getenv` and cannot mutate the real environment portably; the override-map approach avoids `setenv` entirely. Do not log secret values (project security discipline + the reference logs key names only).

**Size.** S.

---

### Task K - gap 14: headless gating flags (`--max-turns`, `--max-budget-usd`, `--json-schema`, `--fork-session`, `--thinking`/`--max-thinking-tokens`)

**Goal.** Expose existing internals as headless CLI flags: cap turns, cap budget, request structured output against a schema, fork a session, and set thinking tokens. (`--permission-prompt-tool` is split out below, dependent on Task E.)

**Reference behavior + file:line.** `main.tsx:976/988` option defs; `coreSchemas.ts` error subtypes `error_max_turns`/`error_max_budget_usd`/`error_max_structured_output_retries`; `print.ts:4312` permission-prompt-tool resolution.

**Target Zig files.** `src/cli/args.zig` (`CliOptions` + parsing); `src/session_mgmt.zig` (`runOneShot` - thread the new caps through to `AgentRuntime`); reuse `core/budget_control.zig`, `max_history_turns` (`config.zig:77`), the `/format json` schema path (`repl_commands.zig:1045`), and `session fork` (`args.zig:629`).

**Approach.**
1. `--max-turns N`: thread into `AgentRuntime.max_tool_rounds_override` (already exists, `agent_runtime.zig:269`); on exceed, produce the `error_max_turns` result subtype (Task G).
2. `--max-budget-usd X`: wire to `budget_control.zig`; on exceed, `error_max_budget_usd`.
3. `--json-schema <schema|@file>`: set the structured-output schema (the `/format json` internal path, `agent_runtime.zig:287` `pending_response_schema`); populate `structured_output` in the result; on repeated parse failure, `error_max_structured_output_retries`.
4. `--fork-session`: reuse the `session fork` subcommand logic as a flag on the headless path.
5. `--thinking` / `--max-thinking-tokens N`: map to `reserved_reasoning_tokens`.
6. All gated behind the headless gate (Task A).

**Acceptance criteria.** Write parser tests for each flag (value parsed into the right `CliOptions` field; `--max-turns abc` errors). Write a runtime test that `--max-turns 1` against a multi-round mock prompt produces an `error_max_turns` result. Write a test that `--json-schema '{...}'` sets `pending_response_schema`.

**Test strategy.** Parser tests + mock-provider runtime tests under `tools/test_runner.zig`.

**Risk + 0.16 footguns.** `--json-schema @file` reading: `readFileAlloc(.limited(N))` returns `error.StreamTooLong` (not `FileTooBig`) - handle it with a clear usage error. Keep budget/turn enforcement in the runtime loop, not in args parsing.

**Size.** M.

---

### Task K2 - gap 14 (`--permission-prompt-tool`)

**Goal.** Route permission prompts to a named MCP tool. Depends on Task E (the `can_use_tool` relay infrastructure) and on MCP tool invocation.

**Approach.** After Task E lands, add `--permission-prompt-tool <name>` that, instead of relaying `can_use_tool` to the host, calls the named MCP tool with the permission request payload and maps its result to the decision (reference `print.ts:4312`). Gate behind the headless gate.

**Acceptance criteria.** Write a test that with `--permission-prompt-tool foo`, a permission request invokes MCP tool `foo` (stubbed) and maps its `allow`/`deny` result. 

**Size.** S (given Task E).

---

### Task L - gap 09: stream-json stdout guard

**Goal.** Wrap stdout writes so stray non-JSON lines are buffered to newline, JSON-parsed, forwarded if valid, and diverted to stderr tagged `[stdout-guard]` if not - so the client's NDJSON parser never breaks.

**Reference behavior + file:line.** `utils/streamJsonStdoutGuard.ts` (`STDOUT_GUARD_MARKER = '[stdout-guard]'`, buffer-to-newline, `JSON.parse` per line, divert non-JSON); `print.ts:594` `installStreamJsonStdoutGuard()` when `outputFormat === 'stream-json'`.

**Target Zig files.** New `src/sdk/stdout_guard.zig` (a `std.Io.Writer` wrapper); install it in the stream-json dispatch (Task B). Reuse `parse_helpers.zig` for parse checks.

**Approach.**
1. Implement a writer that buffers into an internal `ArrayList` until `\n`, then for each complete line: empty -> pass through; `std.json.parseFromSlice` succeeds -> forward to real stdout; fails -> write `"[stdout-guard] " ++ line ++ "\n"` to stderr.
2. Install only when `--output-format stream-json`; the blessed JSON path (Task B serializers) always emits valid NDJSON so it passes straight through.

**Acceptance criteria.** Write a test that feeding `"{\"a\":1}\nplain text\n"` through the guard forwards the JSON line to the captured stdout and diverts `plain text` to the captured stderr with the `[stdout-guard]` marker.

**Test strategy.** Guard takes stdout and stderr writers as parameters so a test can capture both into `StringBuilder`s.

**Risk + 0.16 footguns.** `std.Io.Writer` interface shape in 0.16 - model the guard as a thin wrapper that the dispatcher writes through, not a global `process.stdout.write` monkeypatch (no such hook in Zig). Partial-line buffering: flush the residual buffer (if any) on close.

**Size.** M.

---

### Task M - gap 08: streamlined output transform

**Goal.** Collapse tool calls into cumulative category counts ("searched N patterns, read N files, wrote N files, ran N commands"), keep text, drop thinking/init detail; opt-in via `CLAUDE_CODE_STREAMLINED_OUTPUT`.

**Reference behavior + file:line.** `utils/streamlinedTransform.ts` `createStreamlinedTransformer` (categorize tool names into searches/reads/writes/commands/other, `getToolSummaryText`); `print.ts:860` `transformToStreamlined`.

**Target Zig files.** New `src/sdk/streamlined.zig` (categorizer + summary + transformer); plug into Task B's stream-json emission when the env var is set; reuse `core/parse_helpers.zig:plural`/`pluralS`/`capitalizeAscii`.

**Approach.**
1. Port the tool categories (search: Grep/Glob/WebSearch/LSP; read: Read/ListMcpResources; write: Write/Edit/NotebookEdit; command: Bash/shell/Tmux/TaskStop) using zcode's tool names (cross-check `core/tool_name_map.zig`).
2. Accumulate counts across an assistant turn; emit a `streamlined_tool_use_summary` message in place of tool_use blocks; emit `streamlined_text` for text; reset counts when text appears.
3. Strip tool list / model from init in streamlined mode.
4. Gate behind `CLAUDE_CODE_STREAMLINED_OUTPUT` (env opt-in) + stream-json.

**Acceptance criteria.** Write a test that the categorizer maps zcode tool names to the right buckets, and that `getToolSummaryText({searches:2, reads:1})` -> `"Searched 2 patterns, read 1 file"`. Write a test that the transformer collapses three tool calls into one summary message and preserves an intervening text message.

**Test strategy.** Pure transformer unit tests.

**Risk + 0.16 footguns.** Tool-name parity - zcode names may differ from reference (`Read` vs `FILE_READ_TOOL_NAME`); use `core/tool_name_map.zig` to normalize. Lowest priority within scope; build last.

**Size.** M.

---

### Task N - gap 12: partial messages + `--include-partial-messages` / `--include-hook-events` / `--replay-user-messages`

**Goal.** In stream-json, optionally emit `stream_event` token chunks (`--include-partial-messages`), hook lifecycle system events (`--include-hook-events`), and re-emit user messages for ack (`--replay-user-messages`).

**Reference behavior + file:line.** `coreSchemas.ts:1496` `SDKPartialAssistantMessageSchema`; `main.tsx:976/988` the three options; `print.ts:628` `registerHookEventHandler` when stream-json+verbose.

**Target Zig files.** `src/cli/args.zig` (three bool flags); `src/sdk/output.zig` / `src/sdk/messages.zig` (emit `stream_event`, hook-event system messages, user replay); reuse `core/hook_event.zig` (the `HookEvent` enum already exists).

**Approach.**
1. `--include-partial-messages`: emit `{type:"stream_event", event:..., parent_tool_use_id, uuid, session_id}` per streaming chunk if the provider adapter exposes token deltas (zcode has `--no-stream`, so a streaming path exists - hook into it).
2. `--include-hook-events`: subscribe to `HookEvent` lifecycle and emit system events to stdout.
3. `--replay-user-messages`: re-emit each accepted `SDKUserMessage` as a `user` NDJSON line for ack.
4. All require stream-json (+ verbose where the reference does).

**Acceptance criteria.** Write parser tests for the three flags. Write a test that with `--replay-user-messages`, a fed `user` stdin message is re-emitted on stdout. Write a test that `--include-hook-events` emits a system event when a hook fires (mock).

**Test strategy.** Parser + dispatcher tests; mock provider for partials.

**Risk + 0.16 footguns.** Partial emission depends on the streaming adapter exposing deltas - verify against the provider layer before promising token-by-token; if deltas are coarse, emit coarse `stream_event`s and document the granularity rather than faking per-token chunks.

**Size.** M.

## Documented deviations

**sdk-headless-15 - public SDK type surface package (agentSdkTypes / coreSchemas / controlSchemas).**
- **What.** The reference ships a generated public SDK API plus Zod control/core schemas consumed by the Python/TS SDKs to validate the wire protocol.
- **Why out of scope.** zcode is a standalone reimplementation, not a host the first-party Anthropic SDKs are meant to drive. Shipping an importable Zod/proto schema package has near-zero local value and would add a TypeScript/proto build surface that contradicts zcode's small-native-binary posture. The wire protocol itself (Tasks B-N) is what matters; a separate schema *package* is not.
- **Local stub worth doing.** Extend the existing `zcode api schema` command (`api_server.zig:239` `cmdApiSchema`) to also document the SDK control-protocol wire shape: add a `control_protocol` section enumerating the supported `control_request` subtypes, the `control_response` shape (success/error with `pending_permission_requests`), `control_cancel_request`, and the `system:init` / `result` / `stream_event` message shapes. This gives external integrators a machine-readable description of the wire format without shipping a typed package. Keep the existing `zcode-api/v1` jsonl-stdio block intact and add the SDK shape alongside it.

**`-p` short-flag divergence (within gap 01).** zcode keeps `-p` = `--provider` for backward compatibility; `--print` has no short alias, deliberately diverging from Claude Code's `-p, --print`. This must be documented in `--help` and the parity notes so anyone scripting against `-p` understands the difference.

**`duration_api_ms` / `total_cost_usd` approximations (within gap 07).** If per-API-call timing is not separately tracked, `duration_api_ms` is set equal to `duration_ms` and documented as an approximation; `total_cost_usd` is an *estimate* from `cost.estimateCost`, not a billed figure. These are labeled as such rather than presented as exact.

## Verification

Per project CLAUDE.md, build the release binary and reinstall after every change (fresh inode to preserve the ad-hoc code signature):

```
/Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build -Doptimize=ReleaseFast
rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode
```

Run the test suite under the custom runner:

```
/Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build test
```

Manual checks (using the `mock` provider so no live model is required):

1. **Print flag / output format.** `zcode --print --output-format json "hello"` emits a single `type:"result"` object that `jq .` parses; `--output-format json` is not the legacy `encodeExecJson` blob. `zcode --print --output-format stream-json --verbose "hello"` emits a `system:init` NDJSON line first and a `result` line last, each independently parseable.
2. **Stream-json input.** Pipe two NDJSON `user` messages into `zcode --print --input-format stream-json --output-format stream-json --verbose` and confirm two `result` messages come back (multi-turn).
3. **can_use_tool relay.** Feed a prompt that triggers a tool needing permission over stream-json input; confirm a `control_request` with `subtype:"can_use_tool"` appears on stdout, and that feeding a `control_response` with an allow decision lets the tool run.
4. **Live control.** Over stream-json, send `{type:"control_request", request_id:"r1", request:{subtype:"set_model", model:"..."}}` and confirm a matching `control_response` success; send `subtype:"interrupt"` mid-turn and confirm the turn aborts without the process exiting.
5. **Stdout guard.** With `--output-format stream-json`, confirm any stray non-JSON line is rerouted to stderr tagged `[stdout-guard]` and stdout stays valid NDJSON.
6. **Schema doc.** `zcode api schema | jq .control_protocol` shows the documented SDK wire shape (deviation stub).

Bump `.version` in `build.zig.zon` for each change so the user-facing version reflects every step.
