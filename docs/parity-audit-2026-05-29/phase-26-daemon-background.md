# Phase 26: Daemon supervisor and detached background sessions

## Overview

**What.** Claude Code ships a family of process-level features under one fast-path dispatch layer in `entrypoints/cli.tsx`: a long-running daemon **supervisor** (`claude daemon`) that spawns lean per-kind **worker** children (`claude --daemon-worker <kind>`); a detached **background-session** surface (`claude ps|logs|attach|kill`, `--bg`/`--background`) backed by a cross-session **live-process registry** at `~/.claude/sessions/<pid>.json`; an isolated **tmux socket** so agent-issued tmux never touches the user's real sessions; and a handful of cloud/SDK backends (assistant worker, environment-runner, self-hosted-runner, remote-control bridge).

zcode already has three process-shaped subsystems, but none of them is this: `remote_daemon.zig` is a single local HTTP share server (threads per connection, not worker processes); `kairos.zig` is a per-project autonomous background agent; `session/store.zig` lists saved `.jsonl` transcripts, not live PIDs. There is no PID registry, no `ps/logs/attach/kill`, no `--bg`, no session-kind taxonomy, no tmux isolation, and no detach-instead-of-kill exit semantics.

**Why.** Today a user running several zcode REPLs in parallel has zero visibility into them, background work spawned via kairos/daemon writes to `.ignore` (unobservable), and an agent that runs `tmux kill-server` through Bash can kill the user's real session. The local-feasible slice of this phase delivers: a multi-session registry, a `zcode ps` view, per-session log capture + `zcode logs`, `zcode kill`, session-kind tagging, session naming at creation, and best-effort tmux socket isolation. The cloud-only pieces (assistant SDK worker, environment-runner, self-hosted-runner, remote-control bridge) are documented as deviations with their existing local analogs noted.

**Dependencies on earlier phases.** This phase is largely self-contained but reuses primitives already landed:
- Detached spawn pattern: `kairos.start` / `remote_daemon` use `std.process.spawn(rt.io, .{ .argv, .environ_map, .stdin/stdout/stderr = .ignore })`.
- PID liveness probe: `isPidRunning` (signal-0 via `std.c.kill(pid, @enumFromInt(0)) == 0`) exists in both `kairos.zig:504` and `remote_daemon.zig:687`.
- `getpid()` shim: `kairos.zig:497`.
- Path resolution: `core/paths.zig` (`resolve`, `ensureDir`, `PathSet.sessions_dir`).
- Session labels: `session/store.zig` `SessionEntry.label`, `setLabel`/`readLabel` sidecar files.
- Time formatting: `core/format.zig` `formatBriefTimestamp` / `formatRelativeTimeShort` (already used by `cmdSessionList`).
- Env registry: `core/env_registry.zig` (every new `ZCODE_*` env var must be registered here).

**Effort.** Roughly M-L total for the in-scope slice. The registry (gap-02) + ps (gap-09) + kill (part of gap-01) + session-kind (gap-04) + log capture + logs (gap-10) + naming (gap-11) form one coherent buildable unit. `attach` (part of gap-01), bg-exit-semantics (gap-05), tmux isolation (gap-06), and exec-into-tmux (gap-07) are gated on a pty/tmux host and are lower priority. All cloud backends (gaps 12-14) are out of scope.

## Scope split

| Gap | Disposition | Reason |
|-----|-------------|--------|
| daemon-background-02 (live-process registry) | IN-SCOPE | Pure local file registry; all primitives already exist (spawn, isPidRunning, paths). Prerequisite for everything else. |
| daemon-background-04 (session-kind taxonomy + env wiring) | IN-SCOPE | Small enabling primitive; makes a future `ps` honest. |
| daemon-background-09 (`zcode ps` live view) | IN-SCOPE | Presentation layer over the registry; we already have a transcript lister. |
| daemon-background-01 (`ps`/`logs`/`kill` + `--bg`) | IN-SCOPE (ps/logs/kill + `--bg` spawn); `attach` DEFERRED | logs/ps/kill are doable without a pty. `attach` needs a tmux/pty host (gap-06) to re-attach an interactive REPL. |
| daemon-background-10 (per-session log capture + `zcode logs`) | IN-SCOPE | Cheap once `--bg` exists: redirect detached child stdout/stderr to a file, record path in registry. |
| daemon-background-11 (`-n`/`--name` session label at creation) | IN-SCOPE | Small; complements registry + ps. Live update already exists via `/rename`. |
| daemon-background-05 (detach-instead-of-kill exit) | DEFERRED (in-scope but blocked) | Only meaningful once a detached interactive host (tmux) exists. Stub the `isBgSession()` check now; wire detach later. |
| daemon-background-06 (isolated tmux socket) | IN-SCOPE (best-effort safety) | Safety feature independent of full bg. Set `TMUX`/`-L zcode-<pid>` when shelling out and tmux is present. Foundation for `attach`. |
| daemon-background-07 (exec-into-tmux worktree) | OUT-OF-SCOPE (deferred) | Niche convenience; depends on tmux host (gap-06). Document, do not build now. |
| daemon-background-03 (daemon supervisor + worker registry) | OUT-OF-SCOPE | Reference daemon exists primarily to host the Agent SDK assistant (cloud). Name collides with our local HTTP daemon. No local driving use case. |
| daemon-background-08 (coordinator mode) | OUT-OF-SCOPE here | Belongs to the agent-orchestration phase (AgentRun/TaskStop/SendMessage already exist). Confirm with that auditor to avoid double-counting. |
| daemon-background-12 (cloud/SDK assistant worker) | OUT-OF-SCOPE | OAuth + remote bridge + SSE; locked-out backends. Local analog: kairos. |
| daemon-background-13 (environment-runner / self-hosted-runner) | OUT-OF-SCOPE | Cloud-only managed compute against Anthropic's worker service. No local equivalent. |
| daemon-background-14 (remote-control / bridge) | OUT-OF-SCOPE | Cloud daemon (OAuth + GrowthBook + SSE). Local analog already exists: `remote_daemon` share daemon. |

## Gaps covered

| id | title | severity | size | our current state |
|----|-------|----------|------|-------------------|
| daemon-background-02 | Cross-session live-process registry (`~/.zcode/sessions/<pid>.json`) | high | M | Missing. Only singleton `daemon/state.json` and per-project `kairos.state`; `store.list()` reads `.jsonl` files, not PIDs. |
| daemon-background-04 | Session-kind taxonomy + `ZCODE_SESSION_KIND` env wiring | medium | S | Partial. `CommandKind` + `AgentRuntime.interactive` distinguish modes; no unified kind enum or kind env passed to children. |
| daemon-background-09 | `zcode ps` live-session view (status/waitingFor/name/cwd/kind) | medium | M | Partial. `session list` shows saved-file metadata only; no live activity, no `ps`. |
| daemon-background-01 | Detached background surface: `ps`/`logs`/`kill` + `--bg` (attach DEFERRED) | high | L | Not implemented. No `ps/logs/attach/kill` commands, no `--bg`/`--background`. |
| daemon-background-10 | Per-session log capture + `zcode logs <id>` | low | S | Missing. Detached children spawn with `.stdout=.ignore`,`.stderr=.ignore`. No `ZCODE_SESSION_LOG`, no `logs`. |
| daemon-background-11 | `-n`/`--name` session label at creation | low | S | Partial. `/rename` sets labels post-hoc via sidecar; no creation-time `-n`/`--name` flag. |
| daemon-background-06 | Isolated tmux socket for agent-issued tmux | medium | M | Missing. Only read-only TMUX/TMUX_PANE detection; no `-L` socket isolation, no Tmux tool. |
| daemon-background-05 | Background-session exit semantics (detach not kill) | low | S | Missing (deferred). All exit paths `return;` and terminate the process. |

## Implementation tasks

Tasks are ordered by dependency. Build 26.1 -> 26.2 -> 26.3 -> 26.4 -> 26.5 first (the coherent local slice), then 26.6 (best-effort safety) and 26.7 (deferred wiring) as a second wave.

---

### Task 26.1 - Cross-session live-process registry (gap-02)

**Goal.** A new deep module `core/session_registry.zig` that writes a per-process JSON file `~/.zcode/sessions/registry/<pid>.json` on startup of every top-level session, updates it live (name/status/waitingFor/sessionId), cleans it up on exit, and sweeps stale PID files when enumerated.

**Reference behavior + file:line.**
- `utils/concurrentSessions.ts:59-109` `registerSession()` writes `sessions/<pid>.json` with `{pid, sessionId, cwd, startedAt, kind, name, logPath, ...}`, registers cleanup-on-exit, re-writes `sessionId` on `/resume`.
- `:116-161` `updatePidFile`/`updateSessionName`/`updateSessionActivity` (live `{status, waitingFor, updatedAt}` patches).
- `:168-204` `countConcurrentSessions` enumerates `sessions/`, sweeps stale PIDs with the strict `^\d+\.json$` guard (avoids parseInt prefix-matching `2026-03-14_notes.md` as PID 2026, a real data-loss bug, anthropics/claude-code#34210), skips the sweep on WSL.

**Target Zig files.**
- New: `src/core/session_registry.zig` (deep module). Register in `src/main.zig` comptime block (`_ = @import("core/session_registry.zig");`) alongside the kairos imports near line 118.
- Use `@import("zcode_runtime")` for `rt.io`/`rt.gpa`; import `core/paths.zig`, `core/clock.zig`, `core/std_io.zig` (StringBuilder), `core/env.zig`.
- Add a `registry_dir` to `core/paths.zig` `PathSet` (`~/.zcode/sessions/registry`), kept separate from `sessions_dir` so it never collides with `.jsonl` transcript files. Keeping it in a dedicated subdir also makes the strict-filename guard unnecessary for collision (but keep it anyway for crash robustness).

**Approach step-by-step.**
1. Define `pub const Entry = struct { pid: i32, session_id: ?[]const u8, cwd: []const u8, started_ts: i64, updated_ts: i64, kind: SessionKind, name: ?[]const u8 = null, log_path: ?[]const u8 = null, status: SessionStatus = .idle, waiting_for: ?[]const u8 = null };` (SessionKind/SessionStatus from task 26.2; for ordering, define those enums in `session_registry.zig` itself and have 26.2 re-export them).
2. `pub fn register(allocator, opts: RegisterOpts) !void`: resolve `registry_dir`, `ensureDir` it (mode 0o700 via `std.Io.Dir.makePath` + best-effort chmod), build `<pid>.json` path from `getpid()`, write the JSON via `std.json.fmt` into a `StringBuilder` then atomic write (temp file + rename) to avoid a half-written file being read by a concurrent `ps`.
3. `pub fn update(allocator, patch: Patch) void`: read-modify-write the current process's file. Best-effort: log to debug, never throw (mirrors reference fire-and-forget). Because Zig has no GC finalizers, do the read via `readFileAlloc(.limited(64*1024))` (note: `error.StreamTooLong`, not `FileTooBig`), parse, merge fields, re-serialize.
4. `pub fn unregister(allocator) void`: delete the current process's file (ignore ENOENT). Call from a `defer` at the top of `main`/`runInteractive` rather than relying on signal handlers (we cannot guarantee atexit on SIGKILL anyway; the stale sweep covers crashes).
5. `pub fn list(allocator) ![]Entry`: iterate `registry_dir`, accept only `^\d+\.json$` filenames, parse each, probe liveness with `isPidRunning`. For dead PIDs that are not us, delete the file (skip deletion when `core/ide_detect.zig`/env indicates WSL - reuse the existing detection rather than reinventing). Return only live entries.
6. Reuse `isPidRunning`/`getpid` - extract them into `session_registry.zig` as `pub fn` and have `kairos.zig`/`remote_daemon.zig` keep their private copies (do not refactor those now; surgical-change rule). Or, cleaner: put `pub fn isPidRunning`/`pub fn currentPid` here and leave the duplicates as pre-existing (mention but do not touch).

**Acceptance criteria (write a test that... make it pass).**
- Test: `register` then `list` returns one entry whose `pid == currentPid()`, `kind == .interactive`, fields round-trip. Use `core/test_helpers.zig` `tmpDirPath` and point `registry_dir` at it (add a test-only override param or env, e.g. honor `ZCODE_SESSIONS_DIR` if set).
- Test: a `<pid>.json` file containing a dead PID (e.g. PID 999999) is swept by `list()` and removed from disk; a file named `notes.md` or `2026-03-14_x.json`-style non-`^\d+\.json$` name is left untouched (regression for the parseInt prefix bug).
- Test: `update({ .status = .busy, .waiting_for = "tool" })` then `list()` reflects the patch and `updated_ts` advanced.
- Test: `unregister` removes the file; a second `unregister` is a no-op (no error).

**Test strategy.** Standard `test "..."` blocks in `session_registry.zig`, run by `tools/test_runner.zig` (installs `rt.io`/`rt.gpa`). Use a tmp registry dir per test. Assert via `std.testing`. The runner prints `RUN: <name>` so a hang on file IO is diagnosable.

**Risk + 0.16 footguns.**
- `readFileAlloc(.limited(N))` -> `error.StreamTooLong` (not `FileTooBig`).
- File ObjectMap.put-after-parse desync: take `&parsed.value.object` by pointer when merging patches (a value copy desyncs the entries pointer on realloc) - per CLAUDE.md 0.16 gotcha.
- Concurrent writers (two REPLs) only ever write their own `<pid>.json`, so no cross-process lock needed; atomic temp+rename avoids torn reads.
- `std.Io.Dir.cwd().openDir(rt.io, dir, .{ .iterate = true })` for enumeration; close with `dir.close(rt.io)`.

**Size.** M.

---

### Task 26.2 - Session-kind taxonomy + `ZCODE_SESSION_KIND` wiring (gap-04)

**Goal.** A `SessionKind` enum (`interactive | bg | daemon | daemon_worker`) and `SessionStatus` enum (`busy | idle | waiting`) used by the registry; a `ZCODE_SESSION_KIND` env var that a spawner sets so the child self-registers with the right kind.

**Reference behavior + file:line.** `utils/concurrentSessions.ts:18-19` `SessionKind`/`SessionStatus`; `:31-46` `envSessionKind()` reads `CLAUDE_CODE_SESSION_KIND`, defaults to `interactive`; `:62` kind defaulting.

**Target Zig files.**
- Define both enums in `core/session_registry.zig` (task 26.1) with a `pub fn fromEnv(allocator) SessionKind` reading `ZCODE_SESSION_KIND` (values `bg`/`daemon`/`daemon-worker`), defaulting to `.interactive`.
- Register `ZCODE_SESSION_KIND` in `core/env_registry.zig` (the entry table around line 60-90, `category = .zcode_config`, `sensitive = false`) and in the exported-name lists near lines 205/236. This is mandatory - unregistered `ZCODE_*` vars are a project convention violation.

**Approach.**
1. `pub const SessionKind = enum { interactive, bg, daemon, daemon_worker };` with `jsonStringify`/`fromEnv` helpers. Use kebab `daemon-worker` in the env string but snake in Zig.
2. `register()` calls `SessionKind.fromEnv(allocator)` when the caller does not pass an explicit kind, matching the reference's "spawner sets env, child self-registers for free" pattern.
3. Wire it at the two top-level entry points only: `session_mgmt.runInteractive` (kind `.interactive` unless env overrides) and the `--bg` spawn path (task 26.3 sets `ZCODE_SESSION_KIND=bg` in the child env). Do not retrofit kairos/daemon registration in this task - they are separate lifecycles; optionally tag them in a follow-up.

**Acceptance criteria.**
- Test: `SessionKind.fromEnv` returns `.bg` when `ZCODE_SESSION_KIND=bg` is set (set via the env shim used in `env.zig` tests), `.interactive` when unset, `.interactive` for a garbage value.
- Test: `env_registry` listing includes `ZCODE_SESSION_KIND` (extend the existing `test` that asserts `ZCODE_SESSION_KEY` is present).

**Test strategy.** Unit tests in `session_registry.zig` + extend the env_registry test at `core/env_registry.zig:264`.

**Risk + 0.16 footguns.** `std.process.Environ.Map` for child env (not `getEnvMap`); `.put` a kebab string. Enum-from-string: compare with `std.mem.eql`, do not rely on `std.meta.stringToEnum` for the kebab variant.

**Size.** S.

---

### Task 26.3 - `zcode ps` / `kill` / `--bg` + log capture (gaps 01, 09, 10)

**Goal.** New `CommandKind` variants `ps`, `kill`, and a `--bg`/`--background` flag. `ps` renders the live registry; `kill <id|pid>` SIGTERMs a registered session and removes its file; `--bg` spawns the requested run detached, redirecting stdout/stderr to a per-session log file recorded in the registry. (`attach` and `logs` covered in 26.4/this task respectively.)

**Reference behavior + file:line.**
- Dispatch: `entrypoints/cli.tsx:182-208` switches `ps/logs/attach/kill` and `--bg/--background` to `cli/bg.js`.
- `ps` presentation: `concurrentSessions.ts:19,150-161` status/waitingFor; `psHandler` renders name/cwd/kind/status + transcript-tail sparkline.
- Log capture: `:89-95` registry stores `logPath = CLAUDE_CODE_SESSION_LOG`; `cli.tsx:197` `logs -> bg.logsHandler(args[1])`.

**Target Zig files.**
- `src/cli/args.zig`: add `ps`, `kill`, `logs` to `CommandKind`; parse top-level `ps`/`kill <id>`/`logs <id>` subcommands (mirror the `daemon`/`kairos` blocks at lines 671-759); add `--bg`/`--background` bool to `CliOptions` (mirror existing bool flags around line 122-176).
- New: `src/bg_cmds.zig` (top-level, like `session_cmds.zig`): `cmdPs`, `cmdKill`, `cmdLogs`, and `spawnBackground`. Register in main.zig comptime block + `dispatch` switch (around `daemon_*` at lines 991-1007).
- Reuse `core/format.zig` time formatters and `core/display_safe.zig` `sanitize` for untrusted name/cwd (the `cmdSessionList` pattern at `session_cmds.zig:60-66` is the template - registry name/cwd are equally untrusted).

**Approach.**
1. **`ps`**: call `session_registry.list(allocator)`, print a TSV-ish table: `pid  kind  status  name  cwd  started(rel)`. Sanitize `name`/`cwd`/`waiting_for` via `display_safe.sanitize` before printing (defends against a hostile registry file smuggling ANSI). Defer the sparkline (it needs transcript-tail reads keyed by `session_id`; note as a follow-up, not a blocker). If empty, print `no live sessions\n` (match `cmdSessionList`'s `no sessions\n` voice).
2. **`kill <id|pid>`**: resolve the arg to a registry entry (accept either the numeric PID or a session_id), `std.posix.kill(pid, SIG.TERM)` (reuse the exact pattern from `kairos.stop`/`remote_daemon.stop`), then delete its registry file. Print `killed pid=<n>` or `no such session`.
3. **`--bg`**: in the early dispatch (before entering the REPL), when `opts.bg` is set: compute a log path `~/.zcode/sessions/logs/<id>.log`, `ensureDir`, open it for writing, then `std.process.spawn(rt.io, .{ .argv = <self re-invocation without --bg>, .environ_map = {ZCODE_SESSION_KIND=bg, ZCODE_SESSION_LOG=<path>}, .stdin=.ignore, .stdout=<file>, .stderr=<file> })`. The child's `register()` (task 26.1) picks up kind+log_path from env. Print the spawned `pid` and `zcode logs <id>` / `zcode kill <pid>` hint, then return (do not enter the REPL in the parent). This is the local stand-in for the reference's tmux-hosted detach; full re-attach is deferred to 26.4.
4. **`logs <id>`** (gap-10): resolve the entry's `log_path`, tail the file (read last N KB; for a simple first cut, dump the whole file or last 64 KB). If no `log_path`, print `no log for session <id>`.

**Acceptance criteria.**
- Test: with two registry entries written (one for current pid, one synthetic-but-live by reusing currentPid twice with different filenames is not possible, so write the current pid plus a fabricated entry and stub `isPidRunning` via a live pid), `cmdPs` output contains both pids, the kind column, and a sanitized name (inject `name = "a\x1b[31mb"` and assert the escape is neutralized).
- Test: `cmdKill` on a fabricated entry whose pid is a just-spawned `sleep`-like child (or a self-pipe helper) removes the registry file and the process is gone (`isPidRunning` returns false after).
- Test: `args.zig` parses `zcode ps` -> `.ps`, `zcode kill 1234` -> `.kill` with `subject == "1234"`, `zcode logs abc` -> `.logs subject==abc`, and `--bg` sets `opts.bg == true`.
- Test: `--bg` spawn writes a log file and the child entry's `log_path` is non-null; `cmdLogs` reads it back.

**Test strategy.** Parser tests in `args.zig` test blocks (there are existing parse tests). `bg_cmds.zig` tests use `tmpDirPath` for the registry/log dirs and a captured `StringBuilder` writer. For the kill/spawn integration test, spawn `zig`'s own binary or a short-lived `sleep` via `std.process.spawn` and assert liveness transitions - keep it gated/skippable if the platform lacks the helper.

**Risk + 0.16 footguns.**
- `std.process.spawn(io, opts)` (not `Child.init`). `Cwd` is a union: `.{ .path = "..." }`.
- After `kill`, do NOT call `wait()` if you used `Child.kill(io)` - it reaps internally and asserts. Here we use raw `std.posix.kill` (signal to a foreign pid), so there is no Child to wait on; just probe with `isPidRunning`.
- Redirecting child stdout/stderr to a file: pass an open `std.Io.File` handle in the spawn opts; ensure the parent closes its copy after spawn so the child owns it.
- Sanitize every registry-sourced string before terminal output (matches `cmdSessionList` / daemon-status hardening).

**Size.** L.

---

### Task 26.4 - `-n`/`--name` session label at creation (gap-11)

**Goal.** A `-n`/`--name <name>` CLI flag that seeds the session's display name, written into the registry entry (`name` field) and usable as the initial `/rename` label.

**Reference behavior + file:line.** `concurrentSessions.ts:91` `name = CLAUDE_CODE_SESSION_NAME`; `:131-136` `updateSessionName`; `main.tsx:1000` `-n, --name <name>` option doc.

**Target Zig files.**
- `src/cli/args.zig`: add `name: ?[]const u8 = null` to `CliOptions`; parse `-n`/`--name <value>` (mirror the existing `--model`/`--provider` value-flag handling).
- `src/session_mgmt.zig`: thread `name` into `runInteractive`/`runOneShot` and pass it as the registry `register()` opts (kind + name). Also set it as the session label via the existing `store.setLabel` so `session list` shows it too.
- Register `ZCODE_SESSION_NAME` in `env_registry.zig` (the `--bg` spawn passes it through env so the detached child names itself; mirrors `ZCODE_SESSION_KIND`).

**Approach.**
1. Parse `-n foo` and `--name foo` and `--name=foo`. Reject empty.
2. On session start, `register(.{ .kind, .name })`; if `name != null`, also `store.setLabel(session_id, name)` so it surfaces in both `ps` and `session list`.
3. `--bg` path forwards `ZCODE_SESSION_NAME` to the child env (the child reads it in `register`).

**Acceptance criteria.**
- Test: `args.zig` parses `-n foo`/`--name foo`/`--name=foo` into `opts.name == "foo"`; empty `--name=` errors.
- Test: a registered session with `name = "build-x"` shows that name in `cmdPs` output.

**Test strategy.** Parser tests + a registry round-trip test asserting the `name` field.

**Risk + 0.16 footguns.** Ownership: if `--name=foo` slices argv, the registry write dupes the string before persisting (StringBuilder + JSON handles this). Register the env var or the env_registry listing test fails.

**Size.** S.

---

### Task 26.5 - Best-effort isolated tmux socket (gap-06)

**Goal.** When zcode shells out (Bash tool) and `tmux` is present, route tmux through an isolated socket `zcode-<pid>` via `-L` and a `TMUX` env override, so an agent running `tmux kill-server`/`tmux kill-session` cannot touch the user's real tmux. Killed on graceful shutdown.

**Reference behavior + file:line.** `utils/tmuxSocket.ts:1-24` module doc (the explicit threat: `tmux kill-session` via Bash kills the user's session); `:91-140` `getClaudeSocketName` (`claude-<PID>`) / `getClaudeTmuxEnv` (`socket_path,server_pid,pane_index`); `:208-345` lazy init; `:252-266` `killTmuxServer` on shutdown.

**Target Zig files.**
- New: `src/core/tmux_socket.zig` (deep module). Register in main.zig comptime block.
- Hook into the Bash/shell tool's child-env construction. Find the single place that builds the child `Environ.Map` for shell execution (the Bash tool dispatch); set `TMUX` to the isolated value there, mirroring `getClaudeTmuxEnv`.

**Approach.**
1. `pub fn socketName(allocator) ![]u8` -> `zcode-<pid>`.
2. `pub fn tmuxEnvValue(allocator) ?[]u8`: lazy-init the socket on first use. Init = best-effort `tmux -L zcode-<pid> start-server` (or just rely on `-L` autostart). If `tmux` is absent (probe `PATH`), return null and leave `TMUX` untouched (preserve the user's env exactly - matching the reference's "null means do not override").
3. Set `TMUX=<socket_path>,<server_pid>,0` in the shell child env when initialized.
4. On graceful shutdown, best-effort `tmux -L zcode-<pid> kill-server` (register in the existing exit/cleanup path used by the REPL).

**Acceptance criteria.**
- Test: `socketName` returns `zcode-<currentPid>`.
- Test: when `tmux` is not on PATH (simulate via a controlled PATH or a probe shim), `tmuxEnvValue` returns null and no `TMUX` override is applied.
- Manual: from inside a real tmux session, run zcode, have the agent run `tmux kill-server` via Bash, confirm the user's outer tmux session survives (it hits the isolated socket).

**Test strategy.** Unit-test the pure parts (name, env-value formatting, null-when-absent). The kill-server safety is a manual check (documented under Verification) since CI has no tmux.

**Risk + 0.16 footguns.** `std.process.run` for the one-shot `tmux` probe (`Child.init` is gone). Do not block startup on tmux init - lazy + best-effort only. WSL pinning (reference does interop pinning) is out of scope; document.

**Size.** M.

---

### Task 26.6 (deferred wiring) - bg-exit stub + `attach` placeholder (gaps 05, 01-attach)

**Goal.** Land the `isBgSession()` check and an `attach` command that currently reports "not yet supported on this platform" rather than silently missing, so the surface is complete and the detach-on-exit hook has a home. Full implementation is gated on a pty/tmux REPL host.

**Reference behavior + file:line.** `concurrentSessions.ts:39-46` `isBgSession()` ("exit paths should detach the attached client instead of killing"); `cli.tsx:195` `attach -> bg.attachHandler(args[1])`.

**Target Zig files.** `src/cli/repl.zig` exit paths (`/exit` at ~6991-6998, Ctrl+C at ~6928-6935): guard with `if (session_registry.isBgSession()) { detach(); } else { return; }`. For now `isBgSession()` returns `ZCODE_SESSION_KIND == bg`, and `detach()` is a TODO that falls through to normal exit with a debug log (we have no pty host yet, so there is nothing to detach from). Add `attach` to `CommandKind`; `cmdAttach` prints a clear "attach requires a tmux/pty host (Phase 26 follow-up); use `zcode session resume <id>` to reload state" message and exits non-zero.

**Acceptance criteria.** Test: `isBgSession()` true under `ZCODE_SESSION_KIND=bg`. Test: `attach` parses and `cmdAttach` emits the not-yet-supported message + non-zero exit. No behavior change to the default (non-bg) exit path.

**Test strategy.** Parser test + a small unit test for `isBgSession`.

**Risk.** Keep the default exit path byte-for-byte unchanged (surgical-change rule). Only add a guarded branch.

**Size.** S.

---

## Documented deviations (out of scope)

**daemon-background-03 - Daemon supervisor + worker registry.** The reference `claude daemon` runs `daemon/main.js daemonMain` and spawns `claude --daemon-worker <kind>` children via `daemon/workerRegistry.js`. Its principal purpose is to host the Agent SDK assistant (a cloud/SDK integration). zcode's `daemon` is a different thing entirely (a local HTTP session-share server, `remote_daemon.zig`), and our background autonomy is `kairos`. Building a typed-worker supervisor with no local driving use case is unwarranted, and the name collision would confuse users. **Local analogs to document:** `remote_daemon.zig` (the local "daemon"), `kairos.zig` (the local detached worker). No stub.

**daemon-background-07 - exec-into-tmux worktree fast path (`--worktree --tmux`).** `entrypoints/cli.tsx:247-274` execs into a tmux session before loading the CLI. Niche convenience, gated on the tmux host (gap-06). Deferred - revisit only if full bg/attach is pursued. No stub now; gap-06 lays the socket foundation it would build on.

**daemon-background-08 - Coordinator mode.** `coordinator/coordinatorMode.ts` turns the main session into an async-worker orchestrator. zcode already has AgentRun (`tools/agent.zig`, `agent_runtime.zig:2368/2999`), TaskStop, SendMessage, and parallel read-only tool execution. The only daemon-relevant slice is that reference workers are async and appear in the session registry, whereas ours are in-process. This belongs to the agent-orchestration phase, not here - **confirm with that auditor to avoid double-counting.** No stub in this phase.

**daemon-background-12 - Cloud/SDK assistant worker.** Agent-SDK/cloud-bridge integration (OAuth + remote bridge + SSE, all locked-out backends). zcode is Zig-only with no SDK layer. **Local analog already exists:** `kairos.zig` (per-project, no network). Document kairos as the local autonomous-agent equivalent; build nothing.

**daemon-background-13 - environment-runner / self-hosted-runner.** Cloud/BYOC headless runners that register and poll against Anthropic's `SelfHostedRunnerWorkerService`. Only meaningful against the cloud worker service. No local equivalent worth stubbing.

**daemon-background-14 - remote-control / bridge.** Cloud daemon with OAuth + GrowthBook gating + SSE session bridging + `bridgeSessionId` dedup. **Local analog already exists and is intentional:** `remote_daemon.zig` serves session bundles over a loopback token-auth HTTP daemon with handoff URLs - our deliberate local-only stand-in for remote handoff. Document as an intentional deviation, not a gap.

---

## Verification

**Per-task.** After each task: `RUN`-prefixed test output from `tools/test_runner.zig` must show the new tests passing, with no regressions in `session_cmds`, `session/store`, `kairos`, `remote_daemon`, `env_registry`, or `args` test blocks.

**Build + install (per CLAUDE.md, mandatory after every change).**
```
zig build -Doptimize=ReleaseFast
rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode
```
(`rm -f` first to avoid the macOS in-place-overwrite code-signature invalidation footgun that SIGKILLs the next run.) Bump `.version` in `build.zig.zon` for the change.

**Manual checks.**
1. `zcode ps` with no sessions prints `no live sessions`. Start an interactive `zcode` in another terminal, then `zcode ps` lists it with `kind=interactive`, its cwd, and a relative start time.
2. `zcode --bg "do a small task"` (or `--background`) returns immediately with a pid + `zcode logs <id>` / `zcode kill <pid>` hint; `zcode ps` shows it with `kind=bg`; `zcode logs <id>` shows its captured output (no longer `.ignore`d); `zcode kill <pid>` terminates it and it disappears from `ps`.
3. `zcode -n build-x ...` shows `build-x` in both `zcode ps` and `zcode session list`.
4. Stale sweep: kill a `--bg` session with `kill -9`, then `zcode ps` no longer lists it and the `<pid>.json` file is gone from `~/.zcode/sessions/registry/`. Confirm a non-`<pid>.json` file in that dir is left untouched.
5. Injection check: hand-write a registry file with `"name":"a\u001b[31mEVIL"` and confirm `zcode ps` renders it neutralized (no raw ANSI), matching the daemon-status/`session list` hardening.
6. tmux safety (task 26.5): from inside a real tmux session, start zcode, have the agent run `tmux kill-server` via Bash, confirm the outer user session survives.
7. `zcode attach <id>` prints the documented "requires tmux/pty host" message and exits non-zero (deferred surface is honest, not silently missing).

**Roadmap alignment.** Match `docs/PARITY_ROADMAP_V2.md` phase formatting; record the new env vars (`ZCODE_SESSION_KIND`, `ZCODE_SESSION_NAME`, `ZCODE_SESSION_LOG`) in `core/env_registry.zig` and the wiki. Note in the wiki the two-meanings-of-"daemon" collision and the deliberate local-only deviations (gaps 03, 12-14) so a future audit pass does not re-flag them.
