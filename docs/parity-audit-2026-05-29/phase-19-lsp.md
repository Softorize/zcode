# Phase 19: LSP integration and diagnostics injection

## Overview

**What.** Claude Code's LSP subsystem is not just a request-response tool. It is a startup-initialized singleton (`LSPServerManager`) that owns long-lived language-server processes, drives them through full `textDocument` document-sync notifications, and -- this is the headline feature -- passively captures `textDocument/publishDiagnostics` notifications from every running server and auto-delivers them into the conversation as attachments. The model sees fresh compile/type errors after every edit **without ever calling a tool**. zcode today implements only the bottom slice: a stateless `LSP` tool (`src/tools/lsp.zig`) that spawns a fresh server per request, sends `initialize` + one request, reads stdout, and kills the child. There is no persistent server, no notification loop, no diagnostic registry, no passive injection, and no plugin-sourced config.

**Why.** Passive diagnostics injection is the single most impactful LSP behavior in the reference: it closes the edit-verify loop automatically. Today a zcode model has to remember to run a build or call the LSP tool to discover that an edit introduced a type error. The reference surfaces it for free on the next turn. Everything else in this phase exists to make that one feature possible: you cannot capture `publishDiagnostics` without a persistent server (lsp-02) that keeps stdin open and runs a read loop, and you cannot make a server emit fresh diagnostics after an edit without document-sync notifications (lsp-04).

**Dependencies on earlier phases.** This phase builds on already-shipped infrastructure rather than other roadmap phases:
- The MCP client (`src/mcp/client.zig`) already runs persistent stdio sessions with a notification dispatch callback (`Bridge.handle_notification`, line 149) and a 30s handshake timeout (`MCP_STDIO_TIMEOUT_MS`, line 15) -- this is the closest existing analogue to what the LSP manager needs and should be the structural template.
- `core/backoff.zig` already implements exponential backoff (`delayMs`: 500/1000/2000ms) -- exactly the schedule lsp-06 needs; wire it in, do not reinvent.
- The agent turn loop (`agent_runtime.zig:handlePromptDetailedWithModeAndReporter`, ~675) is where per-turn `<system-reminder>` context is appended via `appendHistoryTurn(.system, ...)`. That is the injection point for delivered diagnostics, mirroring how the reference threads them through `getAttachments`.
- `tools/file.zig` is where Write/Edit land; the reference calls `clearDeliveredDiagnosticsForFile()` from both FileWriteTool and FileEditTool (FileWriteTool.ts:311, FileEditTool.ts:497). The Zig edit path must do the same.
- The plugin manifest parser (`core/plugins.zig`, `PluginSpec` ~31-44) has no LSP fields -- lsp-07 extends it.

**Effort.** Large. The persistent server manager + notification loop + registry + passive injection (lsp-01..04) is the bulk of the work and is genuinely new architecture (a background reader, lifecycle state, cross-turn dedup). The remaining items (lsp-05..11) are incremental refinements on top. Realistic sizing: L for the core (lsp-01, lsp-02), M for registry/doc-sync/lifecycle/config (lsp-03, lsp-04, lsp-05, lsp-07), S for the retry/capabilities/reverse-request refinements (lsp-06, lsp-09, lsp-10, lsp-11), and lsp-08 is a deferred low-priority M.

## Scope split

| Item | Disposition | Reason |
|---|---|---|
| lsp-02 Persistent server manager singleton | **IN-SCOPE** | Prerequisite for the entire phase. Without a long-lived server + open stdin + read loop, no passive notification can ever arrive. This is the foundation. |
| lsp-01 Passive diagnostics injection into context | **IN-SCOPE** | The headline feature. The whole reason the phase exists. Auto-delivers compile/type errors as `<system-reminder>` attachments after edits. |
| lsp-03 Diagnostic registry (dedup, caps, cross-turn) | **IN-SCOPE** | Pure, testable, high-value. Without it the model gets flooded with duplicate diagnostics every turn. Caps (10/file, 30 total) and cross-turn LRU are essential for usability. |
| lsp-04 Document sync notifications (didOpen/Change/Save/Close) | **IN-SCOPE** | This is what *triggers* servers to emit fresh diagnostics after an edit. Without it, many servers (TS) never re-diagnose. Required for lsp-01 to actually fire. |
| lsp-05 Server lifecycle state machine + crash recovery + restart cap + startup timeout | **IN-SCOPE (reduced)** | Needed once servers are persistent: a crashed server must be detected and bounded-restarted, not left zombie. Reuse the MCP client's crash-recovery shape. Reduced: adopt a small state enum + `maxRestarts` cap, not the full reference class hierarchy. |
| lsp-06 ContentModified (-32801) retry with backoff | **IN-SCOPE** | Small, real-world impact (first hover/def on a fresh rust/large-TS project returns empty for us today). Backoff infra already exists. |
| lsp-07 Plugin-sourced server config | **IN-SCOPE (hybrid)** | Keep the hardcoded extension table as the default, but add an *optional* plugin-config override layer so vue-language-server-style `initializationOptions` and custom args/env become possible. Do not make plugins the *only* source like the reference -- that would regress our zero-config UX. |
| lsp-09 workspace/configuration reverse-request handler | **IN-SCOPE** | Falls out for free once lsp-02's read loop can parse server-initiated requests. Likely the cause of empty TS results today (best guess, unverified). One handler returning `[null...]`. |
| lsp-11 Rich client capabilities in initialize | **IN-SCOPE** | Small. Once a persistent init exists, advertise `workspaceFolders`, `positionEncoding: utf-16`, `publishDiagnostics.tagSupport/relatedInformation`, `definition.linkSupport`, hierarchical `documentSymbol`. Required for diagnostics tags and correct UTF-16 offsets. |
| lsp-10 Reinit on plugin refresh + clean shutdown | **IN-SCOPE (small)** | Once a singleton exists it must be torn down on exit and re-read on `/reload-plugins`. Cheap to add wiring; meaningless before lsp-02/lsp-07. |
| lsp-08 LSP plugin recommendation flow (prompt to install) | **OUT-OF-SCOPE (deferred)** | Low severity, depends on the plugin/marketplace subsystem AND plugin-sourced LSP config (lsp-07). Interactive yes/no/never/30s-dismiss UI is a separate UX surface. Document as a follow-up; build no stub beyond noting the hook point. |

## Gaps covered

| id | title | severity | size | our current state |
|---|---|---|---|---|
| lsp-01 | Passive diagnostics injection into agent context | high | L | Missing. `agent_runtime.zig:621 mcpBridgeHandleNotification` audits MCP notifications only; no LSP-specific capture or attachment into context. |
| lsp-02 | Persistent LSP server manager singleton with lifecycle | high | L | Missing. `tools/lsp.zig:131-157` spawns fresh server per request, writes init+request, kills child. No singleton, no extension map, no lazy-start. |
| lsp-03 | Diagnostic registry: dedup, volume caps, cross-turn tracking | high | M | Missing. No registry, dedup, caps, severity sort, LRU, or clear-on-edit anywhere in `src/`. |
| lsp-04 | Document sync notifications (didOpen/didChange/didSave/didClose) | medium | M | Missing. Stateless model sends no `textDocument/did*` notifications; relies on server reading from disk via `rootUri`. |
| lsp-05 | Server lifecycle: state machine, crash recovery, restart cap, startup timeout | medium | M | Partial. MCP client (`mcp/client.zig:1702-1723`) has 2-attempt retry + 30s timeout; LSP tool itself is fully stateless. No LSP state machine or configurable `maxRestarts`. |
| lsp-06 | ContentModified (-32801) transient-error retry with backoff | medium | S | Missing for LSP. `core/backoff.zig` exists but is not wired into `tools/lsp.zig`. `extractLspResult` never inspects the `error` field. |
| lsp-07 | Plugin-sourced server config (extensionToLanguage, args, env, init options) | medium | M | Missing. `detectLanguageServer()` (`tools/lsp.zig:56-71`) is a hardcoded ext->binary map; spawn uses `binary --stdio` only. `PluginSpec` has no LSP fields. |
| lsp-09 | workspace/configuration reverse-request handler | low | S | Missing. No bidirectional JSON-RPC loop; stdin closed after initial write (`tools/lsp.zig:141`); server-initiated requests ignored. |
| lsp-10 | Reinitialize on plugin refresh + clean shutdown | low | S | Partial-via-different-model. Ephemeral processes self-clean; `/reload-plugins` (`repl_commands.zig:5180`) is a filesystem rescan, not LSP reinit; `agent_runtime.zig:473 deinit` has no LSP shutdown hook. |
| lsp-11 | Rich client capabilities + initialization | low | S | Partial. `tools/lsp.zig:97-100` sends `capabilities:{}` with only `processId`+`rootUri`. No `workspaceFolders`, `positionEncoding`, diagnostic tag support, `linkSupport`, hierarchical symbols. |

## Implementation tasks

The clean way to build this is one new deep module that owns all persistent-LSP state, with the existing `tools/lsp.zig` re-pointed at it for the request-response operations. Proposed new modules (register in the `src/main.zig` comptime block so their tests run):

- `core/lsp/manager.zig` -- the singleton: extension->server map, lazy start, request routing, shutdown, reinit. (lsp-02, lsp-05, lsp-10)
- `core/lsp/server_instance.zig` -- one persistent server: spawn, init handshake, background read loop, notification/request dispatch, state machine, crash recovery, sendRequest with retry. (lsp-02, lsp-05, lsp-06, lsp-09, lsp-11)
- `core/lsp/registry.zig` -- pure diagnostic registry: dedup, caps, severity sort, cross-turn LRU, clear-on-edit, format-for-attachment. (lsp-03, lsp-01 formatting)
- `core/lsp/config.zig` -- merges the hardcoded default table with plugin-sourced overrides. (lsp-07)
- `core/lsp/protocol.zig` -- shared JSON-RPC framing/parse helpers (Content-Length read/write, find result/error/method), lifted out of the current `tools/lsp.zig` inline code.

All source imports use `@import("zcode_runtime")` for `rt.io`/`rt.gpa`; new modules are `core/` deep modules per project convention.

---

### Task lsp-02: Persistent LSP server manager singleton with lifecycle

**Goal.** A process-lifetime singleton that owns long-lived language-server child processes, keeps their stdin open, runs a background read loop per server, lazy-starts a server the first time a file of its extension is touched, routes requests by extension, and shuts everything down on exit. This is the substrate every other task hangs off.

**Reference behavior + file:line.** `manager.ts:145-208` (`initializeLspServerManager` -- idempotent singleton, async init, generation counter, `isLspConnected()`); `LSPServerManager.ts:59-148` (`createLSPServerManager`/`initialize` -- `servers` map, `extensionMap`, lazy `ensureServerStarted`, `getServerForFile`); `LSPServerManager.ts:157-185` (`shutdown` stops `running`/`error` servers, swallows per-server errors).

**Target Zig files.**
- New `core/lsp/manager.zig`: `Manager` struct holding `servers: std.StringHashMapUnmanaged(*ServerInstance)`, `extension_map: std.StringHashMapUnmanaged([]const u8)` (ext -> server-name), an `init_state` enum (`not_started`/`pending`/`success`/`failed`), and an `allocator`/`io`. Public: `initialize`, `getServerForFile`, `ensureServerStarted`, `sendRequest`, `getAllServers`, `shutdown`, `isConnected`.
- New `core/lsp/server_instance.zig`: `ServerInstance` (see lsp-05 for lifecycle detail). Owns the `std.process.Child`, the reader thread handle, and a thread-safe inbox for responses keyed by request id.
- `src/main.zig` comptime block: add `_ = @import("core/lsp/manager.zig");` and the sibling modules so their tests are discovered.
- A global singleton accessor (module-level `var instance: ?*Manager = null` + `pub fn get()`/`pub fn installForTest()`), mirroring how `core/runtime.zig` exposes a transitional singleton. Initialize it from `agent_runtime.zig` setup (next to `bindMcpBridge`) so it is available for the turn loop; skip init in `--bare`/headless `-p` mode (reference `manager.ts:148` `isBareMode()` guard).

**Approach step-by-step.**
1. Lift the JSON-RPC framing helpers out of the current `tools/lsp.zig` (`Content-Length` writer, the `{"jsonrpc"` scanner in `extractLspResult`) into `core/lsp/protocol.zig` so both the persistent path and any fallback share them.
2. `ServerInstance.start()`: `std.process.spawn(rt.io, .{ .argv = ..., .stdin = .pipe, .stdout = .pipe, .stderr = .ignore })`. **Do not** close stdin (the current bug at `tools/lsp.zig:141` is what makes the model stateless). Send `initialize` then `initialized` notification.
3. Spawn one background reader thread per server (`std.Thread.spawn`) that loops on `stdout.readStreaming`, frames messages by `Content-Length`, and dispatches each: responses (have `id` + `result`/`error`) go to a mutex-guarded inbox map keyed by id; server requests (have `id` + `method`) go to the request handler (lsp-09); notifications (have `method`, no `id`) go to the notification handler (lsp-01). This is the structural analogue of the MCP client's persistent stdio session read path.
4. `sendRequest(method, params)`: allocate the next request id, write the framed request to stdin, then block (with timeout) on the inbox condition variable until the reader thread delivers a matching id. Reuse the `MCP_STDIO_TIMEOUT_MS` 30s pattern.
5. `Manager.getServerForFile`: `std.fs.path.extension` -> `extension_map` -> `servers`. `ensureServerStarted`: if the instance state is `stopped`/`error`, call `start()` (bounded by lsp-05's restart cap).
6. `shutdown`: send `shutdown` request + `exit` notification to each `running` server, then `child.kill(rt.io)` as a fallback. **Footgun:** per the project CLAUDE.md, `Child.kill(io)` reaps internally -- do **not** call `wait()` after kill. Swallow all errors (reference swallows on exit).
7. `isConnected`: true if at least one server is in `running` state -- backs the LSP tool's "available" check.

**Acceptance criteria.**
- Write a test that installs a fake echo "language server" (a tiny Zig binary or a `cat`-style script invoked through a shim) as a server-instance command, calls `Manager.ensureServerStarted` twice for the same extension, and asserts the **same** child pid is reused on the second call (proves persistence, not per-request spawn).
- Write a test that calls `sendRequest` for two different methods on one started instance and gets two correctly id-matched responses back from the background reader.
- Write a test that `shutdown()` transitions all servers out of `running` and leaves `getAllServers().count() == 0`, and that calling `shutdown()` again is a no-op (idempotent).
- Write a test that `isConnected()` is false before any server starts and true after one starts.

**Test strategy (`tools/test_runner.zig`).** Tests run under the custom runner which installs `rt.io`/`rt.gpa`. Use a deterministic stub server: ship a tiny test fixture program (or reuse `/bin/cat` framed via a wrapper that the test writes into a `testing.TmpDir`). Resolve the tmp dir to a real absolute path with `core/test_helpers.zig:tmpDirPath` -- never pass `"."` as cwd. Print-before-test (`RUN:`) helps if the read loop hangs.

**Risk + 0.16 footguns.**
- Background threads + a shared inbox need a mutex + condition; get the teardown order right (join the reader thread before freeing the inbox, or the reader writes into freed memory).
- `readStreaming(io, &.{&buf})` for pipes (pread is ESPIPE on pipes -- documented project footgun). Track offset is irrelevant for streaming, but do not switch to `readPositionalAll` here.
- `Child.kill(io)` reaps; no `wait()` after (panic risk).
- The transitional global singleton races with sub-agent threads the same way the MCP session maps do (`mcp/client.zig:452` note) -- guard the maps with a mutex from day one since the reader threads mutate concurrently.

**Size.** L.

---

### Task lsp-01: Passive diagnostics injection into agent context

**Goal.** Diagnostics that arrive via `textDocument/publishDiagnostics` from any running server are captured passively by the reader loop, stored in the registry, and auto-delivered into the next turn as a `<system-reminder>` attachment -- no tool call required.

**Reference behavior + file:line.** `passiveFeedback.ts:125-328` (`registerLSPNotificationHandlers` registers an `onNotification('textDocument/publishDiagnostics', ...)` handler on every server; validates params have `uri`+`diagnostics`; calls `formatDiagnosticsForAttachment` then `registerPendingLSPDiagnostic`); `passiveFeedback.ts:18-100` (`mapLSPSeverity` 1=Error..4=Hint, `formatDiagnosticsForAttachment` -> `DiagnosticFile[]`); `manager.ts:189-191` (handlers registered on init success); consumption: `attachments.ts:959 getLSPDiagnosticAttachments` calls `checkForLSPDiagnostics()` and turns the result into conversation attachments each turn.

**Target Zig files.**
- `core/lsp/server_instance.zig`: in the reader-thread dispatch (lsp-02 step 3), when `method == "textDocument/publishDiagnostics"`, parse `{uri, diagnostics:[{message,severity,range,source,code}]}` and call `registry.registerPending(server_name, uri, diags)`.
- `core/lsp/registry.zig`: `registerPending` (storage) + `formatForAttachment` (severity mapping + text rendering). Severity map mirrors `mapLSPSeverity` (1->Error, 2->Warning, 3->Info, 4->Hint, default Error).
- `agent_runtime.zig`: at the top of `handlePromptDetailedWithModeAndReporter` (~675, right after `at_file_refs` expansion, before the main tool loop), call `registry.checkForDiagnostics()` (lsp-03), and if non-empty `appendHistoryTurn(.system, <rendered system-reminder>)`. This is the exact analogue of the reference's per-turn `getAttachments`.

**Approach step-by-step.**
1. Define the diagnostic rendering: a `<system-reminder name="lsp-diagnostics">` block listing, per file URI (converted `file://` -> path), each diagnostic as `severity path:line:col: message [source/code]`. Keep it compact -- this consumes context every turn.
2. The reader thread (already running from lsp-02) calls into the registry on a `publishDiagnostics` notification. Validate the params shape first (reference rejects params missing `uri`/`diagnostics`); on malformed params, log and drop -- never crash the reader loop.
3. Skip empty diagnostic sets (reference `passiveFeedback.ts:196-205` skips when `diagnostics.length === 0`) -- an empty publish means "this file is now clean", which the registry uses to drop stale entries for that URI rather than emitting noise.
4. In the turn loop, only inject when there is something new to deliver (registry dedup decides this -- lsp-03).

**Acceptance criteria.**
- Write a test that feeds a synthetic `publishDiagnostics` notification (one Error in `foo.zig`) through the reader-dispatch path into the registry, calls `checkForDiagnostics`, and asserts the rendered attachment contains `Error` and `foo.zig` and the message.
- Write a test that an empty `publishDiagnostics` for a URI clears any pending diagnostics for that URI and `checkForDiagnostics` returns empty.
- Write a test (integration, with the stub server from lsp-02) that the manager started, a notification flowed end to end, and a subsequent `checkForDiagnostics` is non-empty.

**Test strategy.** The reader-thread -> registry path is the hard part to test deterministically. Expose `registry.registerPending` and the notification-dispatch function as plain functions so a unit test can call them directly with a hand-built params JSON, decoupling the assertion from thread timing. Keep one slower end-to-end test behind the stub server.

**Risk + 0.16 footguns.**
- Concurrency: the reader thread writes the registry while the turn loop reads it. The registry must be mutex-guarded (it is shared singleton state, like the reference's module-level maps).
- Context budget: injecting every turn can bloat the prompt. The caps (lsp-03) are not optional polish -- they are required for this to be safe.
- `std.json.parseFromSlice` arena lifetime: the parsed `uri`/messages must be `dupe`d into the registry's allocator before the arena is freed (mirror the documented "value copy desyncs" footgun for object maps).

**Size.** L (shares the reader loop with lsp-02; the net-new is the registry wiring + turn injection).

---

### Task lsp-03: Diagnostic registry -- dedup, volume caps, cross-turn tracking

**Goal.** A pure registry that dedups diagnostics within a batch and across turns (LRU keyed by URI), sorts by severity, caps at 10/file and 30 total, and clears per-file tracking when that file is edited.

**Reference behavior + file:line.** `LSPDiagnosticRegistry.ts:42-43` (`MAX_DIAGNOSTICS_PER_FILE=10`, `MAX_TOTAL_DIAGNOSTICS=30`, `MAX_DELIVERED_FILES=500`); `:65-85 registerPendingLSPDiagnostic`; `:136-184 deduplicateDiagnosticFiles` (within-batch + cross-turn via `deliveredDiagnostics` LRU, key = `{message,severity,range,source,code}`); `:256-312 checkForLSPDiagnostics` (severity sort `Error=1..Hint=4`, per-file cap, total cap, then record delivered keys); `:372-379 clearDeliveredDiagnosticsForFile` (clear on edit).

**Target Zig files.**
- New `core/lsp/registry.zig`. Pure module (no IO, no threads of its own; the caller holds the lock). Structs: `Diagnostic { message, severity: Severity, range, source, code }`, `DiagnosticFile { uri, diagnostics: []Diagnostic }`, `PendingEntry`. State: `pending: std.ArrayListUnmanaged(PendingEntry)`, `delivered: bounded LRU map uri -> set of content-keys`.
- Reuse a small LRU: if none exists, implement a simple bounded `std.StringHashMapUnmanaged` + insertion-order ring capped at 500 entries (`MAX_DELIVERED_FILES`). Keep it minimal -- this is single-use.

**Approach step-by-step.**
1. `contentKey(diag)`: stable string of `message|severity|startLine:startCol-endLine:endCol|source|code`. Used for both within-batch and cross-turn dedup (reference uses `jsonStringify`; a deterministic concatenation is fine and cheaper).
2. `registerPending(server, uri, diags)`: dupe into registry allocator, append a `PendingEntry`.
3. `checkForDiagnostics()`: collect un-sent pending entries, dedup within batch (skip keys already in this batch's seen-set or in `delivered[uri]`), sort each file's diagnostics by severity ascending (Error first), cap per-file to 10, cap running total to 30, drop emptied files, record surviving keys into `delivered[uri]`, mark entries sent + remove from pending. Return the rendered set (or empty).
4. `clearDeliveredForFile(uri)`: remove the URI from the `delivered` map so a re-edit re-shows previously-seen diagnostics.
5. `resetAll()`: clear both maps (session reset).

**Acceptance criteria.**
- Write a test that registers the same diagnostic twice in one batch and asserts `checkForDiagnostics` returns it once.
- Write a test that delivers a diagnostic, then registers the identical diagnostic again next turn, and asserts the second `checkForDiagnostics` returns empty (cross-turn dedup).
- Write a test that after `clearDeliveredForFile(uri)` the previously-delivered diagnostic is delivered again.
- Write a test that 15 errors in one file are capped to 10, and that 40 total across files are capped to 30.
- Write a test that mixed severities come out Error-first.

**Test strategy.** Entirely pure unit tests under the custom runner -- no IO, no threads, no stub server. This is the easiest task to TDD; write the tests first.

**Risk + 0.16 footguns.**
- Bounded-LRU eviction must free the evicted key + set (no leak in long sessions; the reference relies on `lru-cache` GC -- we manage memory manually).
- Allocator discipline: every stored string is owned by the registry; free on overwrite/eviction/reset.

**Size.** M.

---

### Task lsp-04: Document sync notifications (didOpen/didChange/didSave/didClose)

**Goal.** The manager tracks which files are open on which server and sends `textDocument/didOpen` / `didChange` / `didSave` / `didClose`, which is what makes servers emit fresh diagnostics after edits.

**Reference behavior + file:line.** `LSPServerManager.ts:270-405` (`openFile`/`changeFile`/`saveFile`/`closeFile` + `openedFiles: Map<uri, serverName>`; `didOpen` sends `{uri, languageId, version, text}`; `didChange` requires prior `didOpen`; `saveFile` triggers diagnostics; `isFileOpen`).

**Target Zig files.**
- `core/lsp/manager.zig`: add `opened_files: std.StringHashMapUnmanaged([]const u8)` (uri -> server-name) and methods `openFile(path, content)`, `changeFile(path, content)`, `saveFile(path)`, `closeFile(path)`, `isFileOpen(path)`. `languageId` comes from `config.zig` (lsp-07) extension->language map, default `plaintext`.
- `tools/file.zig`: after a successful Write (`writeFileImpl` path, ~1110+) and Edit, call `manager.get().?.saveFile(abs)` (and `changeFile` with the new content) so the server re-diagnoses. Also call `registry.clearDeliveredForFile("file://"++abs)` here -- this mirrors the reference calling `clearDeliveredDiagnosticsForFile` from both FileWriteTool.ts:311 and FileEditTool.ts:497. Guard with `if (manager.get()) |m|` so the stateless/`--bare` path is unaffected.

**Approach step-by-step.**
1. `openFile`: `ensureServerStarted`, skip if `opened_files[uri] == server.name`, send `didOpen` with file content + `languageId` + `version:1`, record in `opened_files`.
2. `changeFile`: if not yet open, fall back to `openFile`; else send `didChange` with `contentChanges:[{text}]` (full-document sync -- simplest, matches reference which sends the whole text).
3. `saveFile`: send `didSave` (no content). This is the notification that most reliably triggers a fresh diagnostics publish.
4. `closeFile`: send `didClose`, remove from `opened_files`.
5. Wire the edit hooks in `tools/file.zig` defensively (no-op when no manager).

**Acceptance criteria.**
- Write a test that `openFile` then `changeFile` on the same path sends one `didOpen` followed by one `didChange` (capture frames written to the stub server's stdin), and that a `changeFile` on a never-opened file is promoted to `didOpen`.
- Write a test that a Write through `tools/file.zig` (with a manager installed) results in a `didSave` frame to the server **and** a `clearDeliveredForFile` call.
- Write a test that `isFileOpen` reflects open/close transitions.

**Test strategy.** Stub server records every frame it receives on stdin to a file in the tmp dir; the test reads it back and asserts the method sequence. Use `core/test_helpers.zig:tmpDirPath` for absolute paths.

**Risk + 0.16 footguns.**
- `file://` URI construction must match between open and the diagnostic publish, or cross-referencing breaks. Normalize once (reference uses `pathToFileURL(path.resolve(...))`).
- Sending content for large files inflates the stdin write -- this is acceptable (servers need it) but keep the streaming write robust.
- The edit hook runs in the main thread while the reader thread may be mid-publish for the same URI -- registry lock covers the `clearDeliveredForFile` race.

**Size.** M.

---

### Task lsp-05: Server lifecycle -- state machine, crash recovery, restart cap, startup timeout

**Goal.** Each server tracks a state, detects crashes via the reader loop hitting EOF / the child exiting, bounds crash recovery to `maxRestarts` (default 3), and enforces a startup timeout on the init handshake.

**Reference behavior + file:line.** `LSPServerInstance.ts:113-264` (`state: stopped|starting|running|stopping|error`, `crashRecoveryCount`, `maxRestarts ?? 3` cap, `withTimeout` on init); `LSPClient.ts:156-167` (process `exit` -> `onCrash` callback sets state `error`, increments crash count).

**Target Zig files.**
- `core/lsp/server_instance.zig`: add `state: enum { stopped, starting, running, stopping, error_state }`, `crash_recovery_count: u32`, `restart_count: u32`, `start_time`, `last_error`. `start()` enforces `if (state == .error_state and crash_recovery_count > max_restarts) return error.MaxRestartsExceeded;`.

**Approach step-by-step.**
1. State transitions: `stopped -> starting -> running`; `running -> stopping -> stopped`; any -> `error_state` on failure; `error_state -> starting` on retry.
2. Crash detection: when the reader thread sees EOF on stdout or `child.wait` reports exit while state is `running`, set `state = .error_state`, `crash_recovery_count += 1` (mirror the `onCrash` callback in `LSPClient.ts:156-167`). Wake any blocked `sendRequest` waiters with an error.
3. `ensureServerStarted` (manager) restarts an `error_state` server on next use, bounded by the cap. A persistently crashing server stops being restarted after `maxRestarts`.
4. Startup timeout: wrap the init-handshake wait in a deadline using `Io.Timeout`/`clock.nowMillis()`; reuse the 30s default (or `config.startupTimeout` from lsp-07). On timeout, `child.kill` and set `error_state`.

**Acceptance criteria.**
- Write a test that a stub server which exits immediately after init flips the instance to `error_state` and increments `crash_recovery_count`.
- Write a test that `start()` refuses after `maxRestarts` crash recoveries (returns `error.MaxRestartsExceeded`).
- Write a test that a stub server that never replies to `initialize` causes `start()` to fail with a timeout (use a short test-injected timeout so the test is fast).
- Write a test that state goes `stopped -> running -> stopped` over a clean start/shutdown.

**Test strategy.** Stub servers with controllable behavior: one that exits, one that hangs, one well-behaved. Inject a small `startup_timeout_ms` via config for the timeout test so it does not block the suite for 30s.

**Risk + 0.16 footguns.**
- `Io.Timeout.duration` wraps `Io.Clock.Duration` with `{ .raw, .clock }` fields (documented footgun) -- construct it correctly.
- Reaping: after `child.kill(io)`, no `wait()`. For the natural-exit crash path, `child.wait(io)` is fine but only call it once.
- Waking blocked `sendRequest` callers on crash requires the inbox condition to be signaled with an error sentinel, or callers hang until timeout.

**Size.** M.

---

### Task lsp-06: ContentModified (-32801) transient-error retry with backoff

**Goal.** When a server returns ContentModified (`-32801`, e.g. rust-analyzer still indexing), retry the request up to 3 times with exponential backoff (500/1000/2000ms).

**Reference behavior + file:line.** `LSPServerInstance.ts:17-28` (`LSP_ERROR_CONTENT_MODIFIED = -32801`, `MAX_RETRIES_FOR_TRANSIENT_ERRORS = 3`, `RETRY_BASE_DELAY_MS = 500`); `:355-410` (retry loop: parse `error.code`, if `-32801` and attempts remain, `sleep(500 * 2^attempt)` then retry).

**Target Zig files.**
- `core/lsp/server_instance.zig`: in `sendRequest`, after parsing the response, if it carries `error.code == -32801` and attempts remain, sleep `backoff.delayMs(attempt, 500, ...)` and retry. Import `core/backoff.zig` (already in the comptime registry) -- do not reinvent the schedule.
- `core/lsp/protocol.zig`: extend the response parser to surface the JSON-RPC `error` object (`code`, `message`) -- today `extractLspResult` in `tools/lsp.zig:181-209` only looks for `result` and silently ignores errors.

**Approach step-by-step.**
1. Parse both `result` and `error` from the framed response.
2. Loop `attempt` 0..3: send, read; on `error.code == -32801` and `attempt < 3`, `clock`-based sleep `backoff.delayMs(attempt, backoff.BASE_DELAY_MS, ...)` (= 500/1000/2000) and continue; otherwise return.
3. On exhaustion, return the last error wrapped with context.

**Acceptance criteria.**
- Write a test (pure, against the protocol parser) that a response with `"error":{"code":-32801}` is classified as retryable and a `-32600` is not.
- Write a test (stub server) that returns `-32801` twice then a `result`, and assert `sendRequest` ultimately returns the result after 2 retries.
- Write a test asserting the backoff delays are 500/1000/2000 by spying on `backoff.delayMs` outputs (the function is already unit-tested in `core/backoff.zig`).

**Test strategy.** Pure classifier test + one stub-server integration test. For the timing assertion, do not actually sleep 3.5s in CI -- assert the computed delay values, not wall-clock sleeps (inject a no-op sleeper or assert against `backoff.delayMs`).

**Risk + 0.16 footguns.** Use `clock.nowMillis()` / the runtime sleep shim, not `std.time.sleep` (project convention). Keep the retry inside the persistent instance so the open file/server is reused across attempts (the whole point -- a fresh spawn per attempt would re-trigger indexing).

**Size.** S.

---

### Task lsp-07: Plugin-sourced server config (hybrid)

**Goal.** Keep the hardcoded extension->binary table as the zero-config default, and add an optional override layer so plugin manifests can supply `command`, `args`, `env`, `workspaceFolder`, `extensionToLanguage`, `initializationOptions`, `startupTimeout`, and `maxRestarts`.

**Reference behavior + file:line.** `config.ts:15-79` (`getAllLspServers` merges per-plugin configs); `LSPServerInstance.ts:158-174` (uses `config.command`/`args`/`env`/`workspaceFolder`/`initializationOptions`). Note the reference is plugins-only; we deliberately diverge by keeping built-in defaults (documented deviation).

**Target Zig files.**
- New `core/lsp/config.zig`: `ServerConfig { name, command, args, env, workspace_folder, extension_to_language: map, initialization_options_json, startup_timeout_ms, max_restarts }`. `getAllServers(allocator)` returns the built-in defaults (the current `detectLanguageServer` table, promoted to full configs with `extensionToLanguage`) merged with plugin-sourced configs (plugins win on collision, matching reference `Object.assign` precedence).
- `core/plugins.zig`: extend `PluginSpec` (~31-44) with an optional `lsp_servers` field parsed from the manifest (`core/plugins.zig:269-322`). Empty/absent -> no change (backward compatible).

**Approach step-by-step.**
1. Promote the hardcoded table (`tools/lsp.zig:56-71`) into `config.zig` as default `ServerConfig`s with their natural `extensionToLanguage` maps (`.zig->zig`, `.py->python`, `.ts->typescript`, etc.) and `command + ["--stdio"]` args.
2. Parse an optional `lspServers` array from plugin manifests in `core/plugins.zig`; map each into a `ServerConfig`.
3. `getAllServers` merges; the manager builds its `extension_map` from `extension_to_language` keys (reference `LSPServerManager.ts:106-117`).
4. `server_instance.start()` uses `config.args`/`config.env`/`config.workspace_folder` and passes `initializationOptions` into the `initialize` params (required by vue-language-server).

**Acceptance criteria.**
- Write a test that with no plugins, `getAllServers` yields the built-in defaults and `.zig` maps to `zls`.
- Write a test that a plugin manifest supplying an `lspServers` entry for `.vue` is merged in and its `initializationOptions` reach the `initialize` params (assert via the stub server capturing the init frame).
- Write a test that a plugin server with the same extension as a built-in overrides it (plugin wins).

**Test strategy.** Parse a fixture manifest in a tmp dir; assert the merged config. For the init-options assertion, reuse the stub server that records its init frame.

**Risk + 0.16 footguns.** `initializationOptions` is opaque JSON -- store it as a validated JSON string and splice it into the init params, escaping correctly (the current init string-builds JSON manually; prefer building params via `std.json` to avoid injection from untrusted plugin values). `Environ.Map` for `env` -- use `Environ.Map.init` / `swapRemove` (no `remove`), per project footgun list.

**Size.** M.

---

### Task lsp-09: workspace/configuration reverse-request handler

**Goal.** Respond to server-initiated `workspace/configuration` requests with `[null, null, ...]` (one null per requested item) so servers like TypeScript do not stall waiting for a reply.

**Reference behavior + file:line.** `LSPServerManager.ts:123-135` (`instance.onRequest('workspace/configuration', params => params.items.map(() => null))`).

**Target Zig files.** `core/lsp/server_instance.zig`: in the reader-thread dispatch, when an inbound message has both `id` and `method == "workspace/configuration"`, build a response `{jsonrpc, id, result: [null x params.items.len]}` and write it back to stdin. Generic enough that other reverse-requests can be added later (default: respond with `result: null` to any unknown server request so nothing stalls).

**Approach step-by-step.**
1. In dispatch, branch on "has id + has method" = server request.
2. For `workspace/configuration`, count `params.items` and emit a `null` array of that length.
3. For any other server request, reply with `null` (do not leave it unanswered -- an unanswered request is the stall).

**Acceptance criteria.**
- Write a test that feeds a `workspace/configuration` request with 3 items through dispatch and asserts the written response is `result:[null,null,null]` with the matching id.
- Write a test that an unknown server request gets a `result:null` reply (no stall).

**Test strategy.** Pure dispatch unit test: call the dispatch function with a hand-built request frame and capture the response frame it would write. No live server needed.

**Risk + 0.16 footguns.** The response must go out on the same stdin the reader thread does not own -- serialize writes to stdin with a mutex (the main thread's `sendRequest` also writes there). This is the same write-serialization concern as lsp-02.

**Size.** S.

---

### Task lsp-11: Rich client capabilities + initialization

**Goal.** The `initialize` request advertises a realistic capability set so servers behave correctly: `workspaceFolders` + `rootPath` + `rootUri`, `positionEncodings: ["utf-16"]`, `publishDiagnostics` with `relatedInformation` + `tagSupport`, `hover` markdown, `definition.linkSupport`, hierarchical `documentSymbol`, `callHierarchy`.

**Reference behavior + file:line.** `LSPServerInstance.ts:167-237` (the full `InitializeParams` capability block).

**Target Zig files.** `core/lsp/server_instance.zig`: replace the `capabilities:{}` (current `tools/lsp.zig:98`) with the structured capability set. Build it via `std.json` rather than the current manual string interpolation to keep escaping safe. Also send the `initialized` notification after the init response (the reference's client does this; some servers withhold diagnostics until they receive it).

**Approach step-by-step.**
1. Construct `InitializeParams` with `processId`, `workspaceFolders:[{uri,name}]`, `rootPath`, `rootUri`, `initializationOptions` (from lsp-07), and the capability tree from `LSPServerInstance.ts:189-236`. Critically advertise `workspace.configuration: false` (we *handle* it via lsp-09, but declaring false matches the reference and minimizes config requests) and `general.positionEncodings: ["utf-16"]`.
2. Send `initialized` notification after init.

**Acceptance criteria.**
- Write a test that captures the init frame the instance sends and asserts it contains `workspaceFolders`, `positionEncodings`, `publishDiagnostics`, `tagSupport`, and `linkSupport`.
- Write a test that an `initialized` notification is sent after the init response is received.

**Test strategy.** Stub server captures the init + initialized frames; the test parses them and asserts the capability keys are present.

**Risk + 0.16 footguns.** UTF-16 position encoding: our line/character offsets (and the user-facing 1-based conversion in `tools/lsp.zig:36-38`) must be consistent with the declared encoding, otherwise hover/def land on the wrong column for files with non-ASCII. This is a correctness, not cosmetic, concern. Build JSON with `std.json` to avoid the current hand-rolled interpolation breaking on paths with quotes.

**Size.** S.

---

### Task lsp-10: Reinitialize on plugin refresh + clean shutdown

**Goal.** Tear down all servers on process exit, and re-read plugin LSP configs (rebuild the manager) on `/reload-plugins`.

**Reference behavior + file:line.** `manager.ts:226-289` (`reinitializeLspServerManager` shuts down the old instance and re-inits after plugin refresh -- fixes issue #15521; `shutdownLspServerManager` stops all servers on exit, swallowing errors).

**Target Zig files.**
- `agent_runtime.zig:deinit` (~473): add `if (lsp_manager.get()) |m| m.shutdown();` so servers are killed on exit. Currently no LSP hook exists because the model was ephemeral.
- `repl_commands.zig` `/reload-plugins` handler (~5180): after the plugin rescan, call `lsp_manager.reinitialize()` (best-effort shutdown of the old instance, rebuild from the new plugin configs).

**Approach step-by-step.**
1. `Manager.shutdown` already exists from lsp-02; call it from `deinit`.
2. `Manager.reinitialize`: best-effort `shutdown()` of running servers, clear `init_state` to `not_started`, re-run `initialize` reading fresh `config.getAllServers`. Idempotent and safe with zero servers (the common case).
3. Wire into `/reload-plugins` after the existing rescan.

**Acceptance criteria.**
- Write a test that `deinit` after starting a server leaves no child running (`getAllServers().count() == 0`).
- Write a test that `reinitialize` picks up a config that changed between calls (e.g. a new extension mapping is present after reinit).

**Test strategy.** Use the stub server + a mutable in-memory config provider so the test can change configs between `initialize` and `reinitialize`.

**Risk + 0.16 footguns.** `/reload-plugins` runs on the main thread while reader threads are live -- `reinitialize` must join/stop reader threads before freeing instance memory. Swallow shutdown errors during reinit (reference fire-and-forgets).

**Size.** S.

## Documented deviations

**lsp-08 LSP plugin recommendation flow -- OUT-OF-SCOPE (deferred).**
- **What.** On opening a file whose extension matches an LSP plugin whose binary is already installed, the reference prompts the user (yes/no/never/disable, 30s auto-dismiss, stop after 5 ignores) to install that plugin (`LspRecommendationMenu.tsx:11-87`, `lspRecommendation.ts:1-44`, `MAX_IGNORED_COUNT=5`).
- **Why out of scope.** Low severity; depends on both the marketplace subsystem and plugin-sourced LSP config (lsp-07) being mature. It is an interactive TUI surface (a new menu with timed auto-dismiss and per-extension ignore-count persistence) that is orthogonal to the diagnostics value this phase delivers. zcode already extracts and logs hints (`tools/shell.zig:353-374`) and has marketplace install plumbing (`core/marketplace.zig`); only the interactive prompt + ignore-tracking is missing.
- **Local stub worth doing.** None beyond a one-line code comment at the hint-logging site (`tools/shell.zig` ~366) noting "future: surface as install recommendation (parity lsp-08)" so the integration point is discoverable. Do not build dead ignore-count persistence.

**lsp-07 plugins-only config -- INTENTIONAL DIVERGENCE.**
- The reference sources LSP servers *exclusively* from plugins. zcode keeps a built-in default table and treats plugin config as an *override*. Rationale: our zero-config UX (zls/pyright/gopls/etc. just work out of the box) is a strength worth preserving; forcing every user to install a plugin to get Zig LSP would be a regression. Document this in the LSP module header and `docs/PLUGIN_API.md`.

**Stateless fallback -- PRESERVED.**
- When no manager is installed (`--bare`, headless `-p`), the existing stateless `tools/lsp.zig` request-response path remains the implementation for the `LSP` tool's explicit operations. The persistent manager is additive, not a replacement, so headless scripted calls keep working with no background threads. This mirrors the reference's `isBareMode()` skip in `manager.ts:148`.

## Verification

Per project CLAUDE.md, build and install after every change:

1. Build release: `zig build -Doptimize=ReleaseFast` (uses Zig 0.16.0 at `/Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig`).
2. Install with fresh inode (avoids the macOS ad-hoc code-signature SIGKILL footgun): `rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode`.
3. Bump `.version` patch in `build.zig.zon` (build appends git short-hash automatically).
4. Run the suite: `zig build test` (runs under `tools/test_runner.zig`, which installs `rt.io`/`rt.gpa` and prints `RUN:` per test -- watch for a hang on the reader-thread tests, which would indicate a missing inbox signal).

Manual checks (require real language servers installed):
- With `zls` installed, open a `.zig` file, introduce a deliberate type error via Edit, and confirm the **next** turn's prompt contains an `<system-reminder name="lsp-diagnostics">` block naming the file and the error -- without the model calling the LSP tool. Inspect via `/prompt inspect` to see the injected reminder packet.
- With `rust-analyzer` on a fresh large project, run `hover`/`goToDefinition` immediately after open and confirm the ContentModified retry (lsp-06) now returns a real result where it previously returned empty.
- Confirm `/reload-plugins` does not leak language-server child processes (`ps` before/after; reinit should kill the old set).
- Confirm clean exit kills all servers (no orphan `zls`/`gopls`/`pyright` processes after quitting the REPL).
- Confirm `--bare`/`-p` headless mode starts no background reader threads and the `LSP` tool still answers explicit operations via the stateless fallback.

Note: the survey is accurate for this subsystem -- nothing was found already-covered that the gaps claimed missing. The only correction is that `core/backoff.zig` (lsp-06) and the MCP client's persistent-session + notification-dispatch shape (lsp-02 template) already exist and should be reused rather than rebuilt.
