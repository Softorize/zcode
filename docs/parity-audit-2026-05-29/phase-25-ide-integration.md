# Phase 25: IDE integration

## Overview

**What.** This phase builds the *outbound* side of IDE integration: zcode acting as an MCP client that discovers a running IDE extension, connects to it, and exchanges editor-aware messages (open a native diff tab, receive editor selection and at-mention pushes, request diagnostics). Today zcode only has the *inbound* posture - the bundled VS Code extension drives zcode through `api_server.zig`, and `core/ide_detect.zig` reads env vars to print a read-only `/ide` diagnostic. The reference inverts this: Claude Code reads the extension's lockfile, dials the extension over `ws://` or `http://.../sse`, and the extension surfaces native UI (diff tabs, selection, "add to Claude").

**Why.** The single highest-value user-visible feature in this subsystem is diff-in-IDE: edits show up as a native diff tab the user can save, close, or reject inside their editor, instead of a terminal patch. Selection sync and at-mention let the user steer the agent from the editor. None of these can exist without the two foundation pieces - lockfile discovery (gap 01) and the outbound IDE MCP client (gap 02). Everything else in this phase is a leaf that hangs off those two.

**Dependencies on earlier phases.** This phase reuses, not rebuilds:
- The MCP WebSocket client primitive already exists in `src/mcp/client.zig` (`connectWebSocket` at :1389, `performWebSocketHandshake`, frame read/write at :2800, notification storage `NotificationEvent`/`MAX_NOTIFICATION_EVENTS` at :327, and the egress chokepoint at :1398 that already whitelists loopback `ws://`). The outbound IDE client is a thin specialization of this, not a new transport.
- Phase-era `core/platform.zig` (`detect()` returns `.wsl` via `/proc/version`) and `core/xdg.zig` (`getEnvOptional`) are reused for WSL gateway and host-IP logic.
- `core/display_tags.zig` already strips `<ide_selection>` / `<ide_opened_file>` (:99-100); this phase becomes the producer of those tags.
- The forked-agent primitive `runForkedSkill` (`agent_runtime.zig:2128`) is the closest thing to the reference `runForkedAgent` and is the reuse target for `/btw` (gap 11).

**Effort.** Medium-to-large overall. Two large foundation tasks (01, 02), one large dependent feature (03 diff-in-IDE), three medium leaves (04, 05, 06), and four small/documented items (07, 08, 09, 10, 11). The realistic in-scope build set is gaps 01, 02, 03, 04, 05, 07, and 11. Gaps 06, 08, 09, 10 are partially or fully documented deviations (see Scope split).

## Scope split

| Item | Decision | Reason |
|---|---|---|
| 01 lockfile discovery + stale cleanup | IN-SCOPE | Foundation for every outbound feature; pure filesystem + JSON + pid/port liveness, no UI. |
| 02 outbound IDE MCP client (ws/sse + authToken) | IN-SCOPE | Foundation; the WS primitive already exists in `mcp/client.zig`, this is a specialization. |
| 03 diff-in-IDE (openDiff + SAVED/CLOSED/REJECTED) | IN-SCOPE | Highest user-visible payoff of the phase; depends on 01+02. |
| 04 editor selection sync (selection_changed) | IN-SCOPE | Medium; once 02 has inbound notification handling, this is a schema + tag-producer. |
| 05 at-mention from IDE (at_mentioned, 0->1-based) | IN-SCOPE | Medium; same notification path as 04, plus a documented 0->1 line conversion. |
| 07 JetBrains/WSL path conversion (wslpath) | IN-SCOPE (small) | Required for correctness of openDiff under WSL+Windows IDE; small `wslpath` shell-out + `/mnt/<drive>` fallback. Cheap to do alongside 02/03. |
| 11 `/btw` side question (forked, tool-less, 1 turn) | IN-SCOPE | Listed under IDE scope but is really a conversation feature; `runForkedSkill` is the reuse primitive. Replaces a static stub with real behavior. |
| 06 mcp__ide__getDiagnostics / executeCode | OUT-OF-SCOPE (document) | zcode already has a standalone LSP tool (`tools/lsp.zig`) and `NotebookEdit`; the IDE-RPC variant is a non-1:1 alternative path, not a missing capability. Wire a thin optional bridge only if 02 lands cleanly. |
| 08 JetBrains plugin filesystem detection | OUT-OF-SCOPE (document + tiny stub) | zcode does not auto-install or natively integrate JetBrains; plugin-dir scanning only powers status/onboarding notices we are not building. Low value on the macOS dev box. |
| 09 IDE picker UI + auto-connect/onboarding dialogs | OUT-OF-SCOPE (document, partial) | Large interactive TUI surface (IDEScreen/RunningIDESelector/auto-connect dialogs). The data layer (01+02) is in scope; the React/Ink-equivalent picker is deferred. `/ide` stays a read diagnostic, extended to *list* discovered lockfiles. |
| 10 auto-install VS Code extension | OUT-OF-SCOPE (document) | zcode ships an extension that drives zcode (inbound), not the reverse; auto-install is a UX nicety, and `code --install-extension` shell-out duplicates the extension's own publish flow. |

## Gaps covered

| id | title | severity | size | our current state |
|---|---|---|---|---|
| ide-integration-01 | IDE lockfile discovery + stale cleanup | high | M | No lockfile reading at all; `ide_detect.zig` is env-var only. |
| ide-integration-02 | Outbound IDE MCP client (ws/sse + authToken) | high | L | INBOUND only (`browser_bridge.zig` server, `api_server.zig`). WS primitive exists in `mcp/client.zig`. |
| ide-integration-03 | Diff-in-IDE (openDiff + SAVED/CLOSED/REJECTED) | high | L | `diff.apply` API applies git patches; `word_diff.zig` is terminal-only. No openDiff RPC. |
| ide-integration-04 | Editor selection sync (selection_changed) | medium | M | Can strip `<ide_selection>` tags but never produces them; no selection listener. |
| ide-integration-05 | At-mention from IDE (at_mentioned, 0->1-based) | medium | M | Local typed `@file` only (`autocomplete.zig`, `at_file_refs.zig`); no IDE push. |
| ide-integration-06 | mcp__ide__getDiagnostics / executeCode | medium | M | Standalone LSP tool + NotebookEdit exist; no IDE-RPC bridge. (OUT-OF-SCOPE) |
| ide-integration-07 | JetBrains/WSL path conversion (wslpath) | low | S | WSL + JetBrains detected; no path conversion before sending paths to IDE. |
| ide-integration-08 | JetBrains plugin filesystem detection | low | M | TERMINAL_EMULATOR env detection only; no plugin-dir scan. (OUT-OF-SCOPE) |
| ide-integration-09 | IDE picker UI + auto-connect/onboarding | medium | L | `/ide` is read-only env diagnostic; no picker/connect/dialogs. (PARTIAL / OUT-OF-SCOPE) |
| ide-integration-10 | Auto-install VS Code extension | low | M | Manual install instructions only. (OUT-OF-SCOPE) |
| ide-integration-11 | `/btw` side question (forked, tool-less, 1 turn) | medium | M | Static easter-egg stub in `cc_stub_commands.zig:14`. |

## Implementation tasks

### Task 01 - IDE lockfile discovery + stale cleanup

**Goal.** Read `~/.claude/ide/*.lock` JSON files, parse the lockfile schema, rank candidates by mtime (newest first), and prune lockfiles whose owning pid is dead or whose port is unresponsive. Produce a typed list of candidate IDE endpoints for Task 02 to dial.

**Reference behavior + file:line.**
- `utils/ide.ts:73` `LockfileJsonContent` = `{ workspaceFolders?, pid?, ideName?, transport?: 'ws'|'sse', runningInWindows?, authToken? }`.
- `utils/ide.ts:298` `getSortedIdeLockfiles` - readdir each candidate dir, filter `.lock`, stat for mtime, flatten, sort newest-first.
- `utils/ide.ts:346` `readIdeLockfile` - parse JSON; on parse failure fall back to "older format - newline-separated workspace paths"; **derive the port from the filename** (`12345.lock` -> `12345`), not from JSON.
- `utils/ide.ts:462` `getIdeLockfilesPaths` - base dir `join(getClaudeConfigHomeDir(), 'ide')`; on WSL also probe `/mnt/c/Users/<user>/.claude/ide` skipping `Public/Default/Default User/All Users`.
- `utils/ide.ts:522` `cleanupStaleIdeLockfiles` - unreadable lockfile -> unlink; pid set and not running -> delete (on WSL also require port not responding before deleting); no pid -> delete if port not responding.
- `utils/ide.ts:402` `checkIdeConnection` - TCP connect with 500ms timeout = liveness.
- `utils/envUtils.ts:7` config dir = `CLAUDE_CONFIG_DIR ?? ~/.claude` (note: zcode's own config tree is `~/.zcode/`, but the *IDE lockfile* dir the extension writes is `~/.claude/ide` - match the reference path so a real Claude Code extension is discoverable; gate on a `ZCODE_IDE_LOCKFILE_DIR` override for tests).

**Target Zig files.**
- New deep module `src/core/ide_lockfile.zig`. Imports: `std`, `@import("zcode_runtime")` (for `rt.io`), `core/xdg.zig` (`getEnvOptional`), `core/platform.zig` (`detect()`). Register in `src/main.zig` comptime block (`_ = @import("core/ide_lockfile.zig");`).
- Public surface: `pub const Lockfile = struct { port: u16, workspace_folders: [][]u8, pid: ?i32, ide_name: ?[]u8, use_websocket: bool, running_in_windows: bool, auth_token: ?[]u8, mtime_ns: i128, path: []u8, pub fn deinit(...) }`.
- `pub fn discover(allocator) ![]Lockfile` (sorted newest-first), `pub fn readOne(allocator, path) !?Lockfile`, `pub fn cleanupStale(allocator) !void`.

**Approach (step by step).**
1. `lockfileDir(allocator)` - honor `ZCODE_IDE_LOCKFILE_DIR`, else `CLAUDE_CONFIG_DIR/ide`, else `$HOME/.claude/ide`. Return owned absolute path.
2. `discover` - open the dir via `std.Io.Dir`; on ENOENT return empty slice (not an error). Iterate entries, keep `*.lock`, `stat` each for `mtime`, collect `{path, mtime}`, sort descending by mtime, then `readOne` each.
3. `readOne` - read the file (`readFileAlloc(.limited(64 * 1024))`; remember `error.StreamTooLong` not `error.FileTooBig` per CLAUDE.md). `std.json.parseFromSlice` into the lockfile struct; on parse failure treat the body as newline-separated workspace folders (older format). Parse the port from the *basename* with `.lock` stripped; if that fails to parse as `u16`, return null.
4. `cleanupStale` - for each discovered path: if `readOne` returns null, unlink. Else compute liveness: `pidAlive(pid)` via `std.posix.kill(pid, 0)` returning false on `error.ProcessNotFound`/ESRCH; `portResponds(host, port)` via a 500ms TCP connect to `127.0.0.1:port` (use `std.Io.net` connect with a timeout). Apply the reference delete matrix exactly (pid-dead deletes on non-WSL; on WSL require port-dead too; no-pid deletes if port-dead).
5. WSL path probing (`getIdeLockfilesPaths` equivalent) is only needed when `platform.detect() == .wsl`; implement the `/mnt/c/Users/*` scan but keep it behind the WSL branch so the macOS path stays a single dir.

**Acceptance criteria (test-first).**
- Write a test that creates a `testing.TmpDir`, sets `ZCODE_IDE_LOCKFILE_DIR` to its absolute path (use `core/test_helpers.zig` `tmpDirPath`), writes `40145.lock` with `{"transport":"ws","pid":<getpid()>,"ideName":"VS Code","workspaceFolders":["/a"],"authToken":"t"}`, and asserts `discover` returns one `Lockfile` with `port == 40145`, `use_websocket == true`, `auth_token == "t"`, and `pid` equal to the current process pid. Make it pass.
- Write a test that writes two lockfiles with different mtimes and asserts `discover` returns them newest-first.
- Write a test that writes `99999.lock` with `{"pid":2147480000}` (a pid that is not running), runs `cleanupStale`, and asserts the file no longer exists; and a second lockfile with the live pid survives.
- Write a test that writes a non-JSON body (`"/ws/one\n/ws/two"`) and asserts the older-format fallback yields `workspace_folders.len == 2` and the port is taken from the filename.

**Test strategy.** Pure unit tests under `tools/test_runner.zig`. No network needed for discover/parse; `cleanupStale` pid path uses `std.os.linux.getpid()`/`std.posix.getpid()` for the live case. Avoid binding a real port in CI - test the pid-dead branch (deterministic) and gate the port-responds branch behind a locally-bound listener only if trivially stable, otherwise leave port-liveness to manual verification.

**Risk + 0.16 footguns.** `readFileAlloc(.limited(N))` returns `error.StreamTooLong`. Do not pass `"."`/relative cwd to dir walks - use the tmp dir absolute path. `std.posix.kill(pid, 0)` for liveness: signal 0 probes existence; map `error.PermissionDenied` to "alive" (process exists, owned by someone else). Sorting by `mtime`: `std.Io` stat returns nanosecond timestamps; store as `i128` to avoid overflow when sorting.

**Size.** M.

---

### Task 02 - Outbound IDE MCP client (ws / sse + authToken, WSL host detection)

**Goal.** Given a `Lockfile` from Task 01, open an outbound MCP connection to the IDE extension (`ws://host:port` or `http://host:port/sse`), send the `authToken`, complete the MCP `initialize` handshake, fire the `ide_connected` notification, register inbound notification handlers, and expose a `callIdeRpc(method, params)` request path. This is the connection layer that Tasks 03/04/05 sit on.

**Reference behavior + file:line.**
- `utils/ide.ts:793-798` URL: `ws://${host}:${port}` when `transport==='ws'`, else `http://${host}:${port}/sse`.
- `utils/ide.ts:829` `maybeNotifyIDEConnected` - sends notification `{ method: 'ide_connected', params: { pid: process.pid } }`.
- `utils/ide.ts:1353` `detectHostIP(isIdeRunningInWindows, port)` - honor `CLAUDE_CODE_IDE_HOST_OVERRIDE`; non-WSL or IDE-not-on-Windows -> `127.0.0.1`; WSL+Windows IDE -> parse `ip route show ... default via <gw>` and use the gateway IP if the port responds, else `127.0.0.1`.
- `services/mcp/client.ts:2116` `callIdeRpc` - issues an MCP `tools/call`-style request to the connected IDE client.

**Target Zig files.**
- New module `src/mcp/ide_client.zig` (lives next to `browser_bridge.zig`, both are MCP peers). Imports: `client.zig` (reuse `connectWebSocket`, `performWebSocketHandshake`, frame read/write, `egress`), `websocket.zig`, `core/platform.zig`, `core/ide_lockfile.zig`, `@import("zcode_runtime")`. Register in `src/main.zig` comptime block.
- Public surface: `pub const IdeClient = struct { ... pub fn connect(allocator, lockfile) !IdeClient; pub fn callRpc(self, method, params_json) ![]u8; pub fn pollNotifications(self) ![]Notification; pub fn deinit(self) void; }`.
- `pub fn detectHostIp(allocator, running_in_windows: bool, port: u16) ![]u8`.

**Approach.**
1. `detectHostIp` - exactly mirror the reference matrix. `CLAUDE_CODE_IDE_HOST_OVERRIDE` first; non-WSL/non-Windows -> `"127.0.0.1"`; WSL+Windows -> `std.process.run` (`zsh -lc "ip route show | grep -i default"` or read `/proc/net/route`), regex-free parse for `default via <ip>`, verify with a 500ms TCP probe (reuse Task 01 `portResponds`), fall back to `127.0.0.1`.
2. `connect` - build URL from `lockfile.use_websocket` + host + port. For `ws` reuse `client.connectWebSocket(url, lockfile.auth_token)` and `performWebSocketHandshake`. For `sse` the reference uses streamable HTTP at `/sse`; if the zcode HTTP-MCP path does not yet support the SSE GET-stream variant, support `ws` first (the bundled extension uses ws) and return `error.UnsupportedTransport` for `sse`, documented. Pass `authToken` as the `Authorization: Bearer` header in the handshake (the WS handshake already accepts `auth_token`).
3. After handshake, send MCP `initialize`, then send the `ide_connected` notification (`{"jsonrpc":"2.0","method":"ide_connected","params":{"pid":<getpid()>}}`).
4. Inbound notifications - the extension pushes `selection_changed` / `at_mentioned` as JSON-RPC notifications on the same socket. Reuse the existing `NotificationEvent` storage pattern from `mcp/client.zig:327`; expose `pollNotifications` returning a snapshot the REPL drains each turn. Keep it pull-based (poll), not callback-based, to match zcode's existing notification model and avoid threading a callback through the agent loop.
5. `callRpc` - frame a JSON-RPC request with a monotonically increasing id, write the WS frame, read frames until the matching id response arrives, return the raw `result` JSON. This is the primitive Task 03 calls with `"openDiff"`.

**Acceptance criteria (test-first).**
- Write a test for `detectHostIp` that sets `CLAUDE_CODE_IDE_HOST_OVERRIDE=10.0.0.5` and asserts the result is `"10.0.0.5"` regardless of platform.
- Write a test that, with `platform.resetCacheForTesting()` forced to non-WSL, asserts `detectHostIp(true, 1234) == "127.0.0.1"`.
- Write a loopback integration test: stand up a minimal in-process WS server (reuse `browser_bridge.zig`/`websocket.zig` test scaffolding) that completes the MCP handshake and echoes a canned `result` for one request id; assert `IdeClient.connect` succeeds, `callRpc("ping", "{}")` returns the canned result, and that a server-pushed `selection_changed` notification appears in `pollNotifications`.

**Test strategy.** `tools/test_runner.zig`. The loopback test mirrors how `browser_bridge.zig` is already exercised - bind `127.0.0.1:0`, accept one connection on a thread, speak just enough MCP. Keep the wire assertions tight to the frame shapes Tasks 03/04 depend on.

**Risk + 0.16 footguns.** WS handshake already routes through `egress.checkUrl` which only allows loopback `ws://` - the IDE endpoint is always `127.0.0.1` (or WSL gateway), so loopback policy holds; the WSL-gateway IP is non-loopback and will be *denied* by egress - add an explicit allow for the detected gateway host or bypass egress for the IDE-client path (document the decision; the token only ever goes to a host derived from a local lockfile). `std.process.run` for `ip route`: use `std.process.run(allocator, io, opts)` (one-shot), not the removed `Child.init`. Reading `/proc/net/route` is the more portable alternative to shelling out. For `Child.kill(io)` do not `wait()` after.

**Size.** L.

---

### Task 03 - Diff-in-IDE (openDiff RPC + SAVED / CLOSED / REJECTED)

**Goal.** When an edit would be applied and a connected IDE client exists, push the proposed change as a native diff tab via `callIdeRpc('openDiff', {...})`, then resolve the final file contents from the user's IDE action: `FILE_SAVED` (take edited contents), `TAB_CLOSED` (take proposed contents), `DIFF_REJECTED` (keep original). Clean up tabs via `close_tab` and a `closeAllDiffTabs` sweep.

**Reference behavior + file:line.**
- `hooks/useDiffInIDE.ts:284` `callIdeRpc('openDiff', { old_file_path, new_file_path, new_file_contents, tab_name })`.
- `:299-317` response handling: `isSaveMessage` -> `{ oldContent, newContent: data[1].text }`; `isClosedMessage` (`TAB_CLOSED` at :346) -> keep updated; `isRejectedMessage` (`DIFF_REJECTED` at :358) -> revert to old.
- `:339` `close_tab` cleanup; `utils/ide.ts:1270` `closeOpenDiffs` -> `closeAllDiffTabs`; `REPL.tsx:2670` closes diffs on exit.
- `:271-282` path conversion before send (depends on Task 07).

**Target Zig files.**
- New module `src/core/ide_diff.zig`. Imports: `mcp/ide_client.zig`, `core/ide_path_conv.zig` (Task 07), `@import("zcode_runtime")`. Register in `src/main.zig` comptime block.
- Public: `pub const DiffOutcome = enum { saved, closed, rejected }; pub const DiffResult = struct { outcome, new_contents: []u8 }; pub fn openDiff(allocator, ide: *IdeClient, old_path, new_contents, tab_name) !DiffResult; pub fn closeTab(...); pub fn closeAllDiffTabs(...);`
- Wire-in point: the Write/Edit apply path that currently writes directly. Gate behind "is there a connected IDE client" so terminal-only sessions are unaffected.

**Approach.**
1. Convert `old_path` through Task 07 (`toIdePath`) only when WSL + IDE-on-Windows; otherwise pass through.
2. Build params `{ old_file_path, new_file_path (same as old for in-place edits), new_file_contents, tab_name }`; call `ide.callRpc("openDiff", params)`.
3. Parse the result array shape: a leading `{type:"text", text:"FILE_SAVED"|"TAB_CLOSED"|"DIFF_REJECTED"}` element plus, for save, `data[1].text` = the user-edited contents. Map to `DiffOutcome` and resolved contents per the reference.
4. On any terminal outcome, fire `close_tab {tab_name}` (best-effort, swallow errors). Add `closeAllDiffTabs` for REPL teardown.
5. Track open tab names in the `IdeClient` so the sweep is deterministic.

**Acceptance criteria (test-first).**
- Write a test with a fake `IdeClient` (a small test double exposing `callRpc` that returns a scripted JSON array) asserting: `FILE_SAVED` returns `.saved` with `data[1].text`; `TAB_CLOSED` returns `.closed` with the proposed contents; `DIFF_REJECTED` returns `.rejected` with the original contents.
- Write a test asserting that a result matching none of the three shapes returns `error.NotAccepted` (matching the reference `throw new Error('Not accepted')`).
- Write a test asserting `closeTab` swallows a `callRpc` error and does not propagate.

**Test strategy.** Pure unit tests with a scripted `IdeClient` double - no live socket needed because the response shapes are fully specified. The double can be a comptime-injected interface or a thin struct with a function pointer matching `callRpc`'s signature.

**Risk + 0.16 footguns.** The reference uses `old_file_path == new_file_path` for in-place edits - preserve that. JSON result is an array of content blocks; index carefully and bounds-check `data[1]` before reading `.text` (a malformed `FILE_SAVED` with no second element must not panic - treat as `error.NotAccepted`). Memory: the resolved `new_contents` must be duped into the caller's allocator since the parsed JSON arena is freed.

**Size.** L.

---

### Task 04 - Editor selection sync (selection_changed)

**Goal.** Handle the inbound `selection_changed` notification from the IDE client, compute `lineCount`/`lineStart`, and surface the current editor selection (text, filePath, range) into the next prompt as an `<ide_selection>` block (which `display_tags.zig` already knows how to strip from display/resubmit).

**Reference behavior + file:line.**
- `hooks/useIdeSelection.ts:32` `SelectionChangedSchema` = `{ method:'selection_changed', params:{ selection:{start:{line,character},end:{line,character}}|null, text?, filePath? } }`.
- `:91-108` `selectionChangeHandler`: `lineCount = end.line - start.line + 1`; **if `end.character === 0`, `lineCount--`** (do not count a line whose selection ends at column 0); produce `{ lineCount, lineStart: start.line, text, filePath }`.

**Target Zig files.**
- New module `src/core/ide_selection.zig`. Imports: `std`, `core/display_tags.zig` (for the tag name constants), `@import("zcode_runtime")`.
- Public: `pub const Selection = struct { line_count: i64, line_start: ?i64, text: ?[]u8, file_path: ?[]u8 }; pub fn parseSelectionChanged(allocator, params_json) !?Selection; pub fn renderTag(allocator, sel) ![]u8;`
- Consumer: the REPL prompt-build path drains `IdeClient.pollNotifications`, parses `selection_changed` events, stores the latest `Selection`, and prepends `renderTag` output (an `<ide_selection>...</ide_selection>` block) to the user prompt.

**Approach.**
1. `parseSelectionChanged` - parse params; if `selection` present, apply the `lineCount` formula including the `end.character == 0` decrement; if `selection` null but `text` present, treat as cleared selection.
2. `renderTag` - emit `<ide_selection>` with file path, line range, and selected text matching what `display_tags.zig:99-100` already strips on resubmit, so the round-trip is symmetric.
3. Keep a "latest selection" slot on the REPL; reset it when the IDE client disconnects (mirror the hook's reset-on-client-change at `useIdeSelection.ts:73-83`).

**Acceptance criteria (test-first).**
- Write a test: params with `start={line:3,character:2}`, `end={line:7,character:5}` -> `line_count == 5`, `line_start == 3`.
- Write a test for the column-0 edge: `end={line:7,character:0}` -> `line_count` is one less (4 for start line 3).
- Write a test: `selection:null, text:""` parses to a cleared selection (no error).
- Write a test asserting `renderTag` output is exactly stripped to empty by `display_tags.stripIdeContextTags` (round-trip symmetry).

**Test strategy.** Pure unit tests on the parse/format functions; the round-trip test ties this to the existing `display_tags.zig` behavior so producer and consumer cannot drift.

**Risk + 0.16 footguns.** Off-by-one in `lineCount` is the whole point of the reference's column-0 special case - the round-trip and edge tests guard it. Selection text can be large; cap the embedded text length to avoid bloating the prompt (the reference relies on the IDE sending bounded selections, but defend with a cap and document it).

**Size.** M.

---

### Task 05 - At-mention from IDE (at_mentioned, 0->1-based)

**Goal.** Handle the inbound `at_mentioned` notification (`{filePath, lineStart?, lineEnd?}`), convert 0-based line numbers to 1-based, and inject the referenced file/range into the prompt, reusing the existing local `@file` expansion path. Emit the `tengu_ext_at_mentioned` analytics event.

**Reference behavior + file:line.**
- `hooks/useIdeAtMentioned.ts:18` `AtMentionedSchema` = `{ method:'at_mentioned', params:{ filePath, lineStart?, lineEnd? } }`.
- `:57-61` **0->1-based conversion**: `lineStart = data.lineStart + 1`, `lineEnd = data.lineEnd + 1` when defined.
- `PromptInput.tsx:1284` logs `tengu_ext_at_mentioned`.

**Target Zig files.**
- New module `src/core/ide_at_mention.zig`. Imports: `core/at_file_refs.zig` (reuse the existing `@path` -> file-block expansion), analytics/logging module, `@import("zcode_runtime")`.
- Public: `pub const AtMention = struct { file_path: []u8, line_start: ?i64, line_end: ?i64 }; pub fn parseAtMentioned(allocator, params_json) !AtMention;` plus a helper that turns it into the same prompt fragment the local typed `@file` produces.

**Approach.**
1. Parse params; apply the +1 conversion to `lineStart`/`lineEnd` only when present (keep null as null).
2. Build the injected reference using the existing `at_file_refs.zig` expansion so an IDE-pushed mention and a typed `@path` produce identical prompt content (single source of truth for file-block rendering).
3. Log `tengu_ext_at_mentioned` through zcode's existing analytics/event sink (match the event name the reference uses so any downstream parity tooling lines up).
4. The REPL drains this from `IdeClient.pollNotifications` alongside `selection_changed`.

**Acceptance criteria (test-first).**
- Write a test: params `{filePath:"a.zig", lineStart:4, lineEnd:9}` -> `line_start == 5`, `line_end == 10` (1-based), `file_path == "a.zig"`.
- Write a test: params with no line numbers -> both nulls preserved, no conversion.
- Write a test asserting the prompt fragment built from an `AtMention` for an existing temp file matches the fragment `at_file_refs` produces for the same `@path` (shared-path parity).

**Test strategy.** `tools/test_runner.zig`; use `core/test_helpers.zig` `tmpDirPath` for the file-existence parity test so the path is absolute, never `"."`.

**Risk + 0.16 footguns.** The +1 conversion must skip when the field is absent (a present-but-zero `lineStart:0` becomes `1`, which is correct; absent stays absent). Reuse `at_file_refs.zig` rather than re-rendering file blocks to avoid two divergent formats.

**Size.** M.

---

### Task 07 - JetBrains / Windows-WSL IDE path conversion (wslpath)

**Goal.** Convert WSL paths to Windows IDE paths (`toIdePath`) and Windows paths to WSL (`toLocalPath`) using `wslpath`, with a manual `/mnt/<drive>` fallback and WSL UNC distro matching, applied before sending paths in `openDiff` (Task 03) and after reading `workspaceFolders` (Task 01).

**Reference behavior + file:line.**
- `utils/idePathConversion.ts:25` `WindowsToWSLConverter`.
- `:28-56` `toLocalPath`: if UNC `\\wsl$\<distro>` or `\\wsl.localhost\<distro>` for a *different* distro, return unchanged; else `wslpath -u <path>`, fallback to backslash->slash + `^([A-Z]):` -> `/mnt/<lower>`.
- `:58-73` `toIDEPath`: `wslpath -w <path>`, fallback returns original.
- `:79-90` `checkWSLDistroMatch` - UNC distro equality test.

**Target Zig files.**
- New module `src/core/ide_path_conv.zig`. Imports: `std`, `core/platform.zig`, `@import("zcode_runtime")` (for `std.process.run`). Register in `src/main.zig` comptime block.
- Public: `pub fn toLocalPath(allocator, wsl_distro: ?[]const u8, windows_path) ![]u8; pub fn toIdePath(allocator, wsl_path) ![]u8; pub fn checkWslDistroMatch(windows_path, wsl_distro) bool;`

**Approach.**
1. `checkWslDistroMatch` - parse `\\wsl$\<d>\...` and `\\wsl.localhost\<d>\...` prefixes; return true if not a UNC path or if the distro matches.
2. `toLocalPath` - early-return for empty; if UNC with mismatched distro, return unchanged; try `std.process.run(allocator, io, .{.argv = &.{"wslpath","-u",windows_path}})`, trim stdout on success; on failure do the manual transform (`\`->`/`, `C:` -> `/mnt/c`).
3. `toIdePath` - `wslpath -w`; on failure return the original path.
4. Manual fallback must be exercisable without a real `wslpath` (the macOS dev box has none), so factor the string transform into a pure `manualWindowsToWsl(path)` that tests can hit directly.

**Acceptance criteria (test-first).**
- Write a test on the pure fallback: `manualWindowsToWsl("C:\\Users\\me\\x.zig") == "/mnt/c/Users/me/x.zig"`.
- Write a test: `checkWslDistroMatch("\\\\wsl$\\Ubuntu\\home", "Ubuntu") == true` and `... "Debian") == false`, and a non-UNC path returns `true`.
- Write a test: `toLocalPath` with a mismatched UNC distro returns the input unchanged (no shell-out attempted).

**Test strategy.** Pure unit tests for the fallback and distro logic (no `wslpath` dependency). The live `wslpath` path is left to manual verification on a WSL box, documented in the deviation note.

**Risk + 0.16 footguns.** `std.process.run` one-shot, not `Child.init`. `wslpath` is absent on macOS/Linux dev boxes - never let its absence error the path; always fall back. Keep this module pure-fallback-testable so CI on macOS exercises the logic that matters most.

**Size.** S.

---

### Task 11 - `/btw` side question (forked agent, tool-less, single turn)

**Goal.** Replace the static `/btw` easter-egg stub with a real forked side question: fork the parent context, ask a one-shot tool-less question that shares the prompt cache, return the answer without disturbing the main loop.

**Reference behavior + file:line.**
- `utils/sideQuestion.ts:53` `runSideQuestion` - wraps the question in a system-reminder ("separate lightweight agent, NO tools, one-off response"), `maxTurns: 1`, `canUseTool` always denies, `skipCacheWrite: true`, does NOT override thinking config (preserves cache key).
- `:16` `BTW_PATTERN = /^\/btw\b/gi`; `:22` `findBtwTriggerPositions`.
- `:125` `extractSideQuestionResponse` - flatten assistant content blocks across per-block messages; if a tool_use slipped through, return a friendly "tried to call a tool" message; if API error, surface it.

**Target Zig files.**
- Remove the `/btw` entry from `core/cc_stub_commands.zig:14` (surgical: delete only that line; leave the other stubs). The removed line is the only orphan this change creates.
- New routing in `src/repl_commands.zig` (or a small `core/side_question.zig` helper) that recognizes `/btw <question>` before the `cc_stub_commands.lookup` fallback at `repl_commands.zig:168`, and calls a new `agent_runtime.zig` entry point.
- New `agent_runtime.zig` method `runSideQuestion(question) ![]u8` modeled on `runForkedSkill` (`:2128`): fork a child runtime (`AgentRuntime.init` with the same store/mcp/policy), set `max_tool_rounds_override = 0` (deny all tools), inject the tool-less system-reminder prefix verbatim-equivalent to the reference, cap at one turn, and return the assistant text.

**Approach.**
1. Detect `/btw` at input start (mirror `BTW_PATTERN`, case-insensitive, word boundary); strip the trigger to get the question text. Empty question -> a short usage message.
2. Build the wrapped prompt with the reference's system-reminder (adapted to zcode wording, no em dashes): "separate lightweight agent, the main agent is not interrupted, NO tools available, one-off response, answer from context only."
3. Fork via the `runForkedSkill` pattern but with tools fully denied (`max_tool_rounds_override = 0`) and a single model turn; do not change reasoning effort/model so the prompt cache key is preserved (reference rationale at `sideQuestion.ts:82-84`).
4. Extract the assistant text; if the fork produced only a tool_use or an error, return the friendly fallback message (mirror `extractSideQuestionResponse`).

**Acceptance criteria (test-first).**
- Write a test that `/btw` trigger detection: `"/btw why is the sky blue"` -> question text `"why is the sky blue"`; `"/btweird"` -> not a trigger (word boundary); case-insensitive `"/BTW x"` -> trigger.
- Write a test that an empty `/btw` returns the usage message, not a fork attempt.
- Behavior test with the mock provider: `/btw <q>` returns the mock's text response and does NOT mutate the main session store (assert session message count is unchanged after the side question).

**Test strategy.** Trigger-parsing is a pure unit test. The fork behavior uses the existing mock provider path that `runForkedSkill` tests already rely on; assert the side answer comes back and the parent session is untouched.

**Risk + 0.16 footguns.** The forked child must share the parent's allocator-lifetime carefully - mirror `runForkedSkill`'s `child.deinit()` defer. Denying tools by `max_tool_rounds_override = 0` is the simplest tool-less gate; verify the agent loop treats 0 as "no tool rounds" and still produces a text turn. Do not write cache entries for the fork (reference `skipCacheWrite`); if zcode has no cache-write toggle this is a no-op, document it.

**Size.** M.

## Documented deviations

**06 - mcp__ide__getDiagnostics / executeCode.** Out of scope as a 1:1 feature. zcode already obtains diagnostics through its own standalone LSP tool (`tools/lsp.zig`, dispatched at `tool_dispatch.zig:1059`) and edits notebooks via `NotebookEdit` (`notebook.zig`). The reference's `mcp__ide__*` tools route those through the IDE's language server instead of a directly-spawned one. If Task 02 lands cleanly, a thin optional bridge that exposes `callIdeRpc('getDiagnostics')` behind a feature gate is a small follow-up, but it is not required for parity of *capability*. Local stub worth doing: none - the LSP tool already covers the user need.

**08 - JetBrains plugin filesystem detection.** Out of scope. The reference scans platform JetBrains config dirs for `claude-code-jetbrains-plugin` (`utils/jetbrains.ts`) solely to power status notices and onboarding - surfaces we are not building (09, 10). zcode detects a JetBrains *terminal* via `TERMINAL_EMULATOR` (`ide_detect.zig:71`) which is sufficient for the `/ide` diagnostic. Local stub worth doing: keep the existing `ide_detect.zig:123` notice ("JetBrains IDEs are not yet natively integrated") accurate; optionally extend the `/ide` text once Task 01/02 can actually connect.

**09 - IDE picker UI + auto-connect / onboarding dialogs.** Partial / out of scope. The *data layer* (lockfile discovery 01, outbound client 02) is in scope; the interactive picker (`IDEScreen`/`RunningIDESelector`/`IdeAutoConnectDialog`, `IDE_CONNECTION_TIMEOUT_MS=35s`) is a large React/Ink-equivalent TUI surface deferred. Local stub worth doing: extend `core/ide_detect.zig` `render` so `/ide` *lists discovered lockfiles* (port, ideName, workspaceFolders, valid/stale) from Task 01 - a read-only enrichment that gives most of the picker's informational value without the interactive connect/disconnect machinery. `formatWorkspaceFolders` (basename + count) is a cheap helper to port for that listing.

**10 - Auto-install VS Code extension.** Out of scope. zcode ships an extension that drives zcode (inbound, via `api_server.zig`), the inverse of the reference's model where the CLI installs and drives the IDE. Auto-running `code --install-extension` on startup (respecting `CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL` and `autoInstallIdeExtension`) duplicates the extension's own marketplace publish path and adds a startup shell-out we would rather not own. Local stub worth doing: keep `/doctor` (`repl_commands.zig:2829`) and `enterprise_doctor.zig:489-497` accurate about manual install; no behavior change.

## Verification

1. **Build + install (per CLAUDE.md):**
```
zig build -Doptimize=ReleaseFast
rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode
```
Use `rm -f` first to avoid the macOS in-place-overwrite ad-hoc-signature SIGKILL footgun. Bump `.version` in `build.zig.zon` before building.

2. **Tests:** `zig build test` - all new module tests under `tools/test_runner.zig` pass (lockfile discover/parse/cleanup, host-IP matrix, openDiff outcome mapping, selection line-count edge cases, at-mention 0->1 conversion, path-conversion fallback, `/btw` trigger + no-mutation).

3. **Manual - lockfile discovery (macOS):** create `~/.claude/ide/40145.lock` with a `ws` transport, current pid, and a workspace folder, then run `zcode` and `/ide` - confirm the enriched `/ide` listing shows the discovered lockfile (port, ideName, workspace, valid). Kill the pid, re-run, confirm `cleanupStale` removes it.

4. **Manual - outbound connect (loopback):** with a local WS server speaking minimal MCP on the lockfile port, confirm `IdeClient.connect` succeeds and `ide_connected` is sent (observe on the server side). Confirm a server-pushed `selection_changed` shows up as an `<ide_selection>` block in the next prompt, and an `at_mentioned` injects the file with 1-based lines.

5. **Manual - diff-in-IDE:** with the connected client, trigger an edit and confirm `openDiff` is called and the three outcomes (save/close/reject) resolve to the correct final contents.

6. **Manual - `/btw`:** in a live session, run `/btw what file am I editing` and confirm a one-shot answer returns, no tools run, and the main session transcript is unchanged afterward.

7. **WSL path conversion** is verified only by the pure-fallback unit tests on the macOS dev box; full `wslpath` round-trip is a documented manual check on a WSL+Windows-IDE host.
