# Phase 6: MCP depth: scoped config, structured stdio, env expansion, dynamic headers, content transform, timeouts, reconnect

## Overview

**What.** This phase rebuilds the MCP configuration and transport layer so it
matches the reference's depth. Today zcode stores MCP servers as a flat array
of `{name, transport}` tuples in a single hardcoded file
(`~/.zcode/mcp/servers.json`), spawns every server as `zsh -lc <transport>`
with a fresh empty environment, and uses hardcoded timeouts. The reference
reads servers from multiple scopes (`.mcp.json` project files with parent
traversal, user/local/enterprise settings, dynamic `--mcp-config`, plugins,
agent frontmatter), each carrying a structured config (type / command / args /
env / url / headers / headersHelper / oauth), with env-var expansion, an
allow/deny policy engine, per-project approval, dynamic header helpers,
content-block transformation (image resize, blob spill-to-disk, resource
inlining, schema inference), env-overridable timeouts, and a terminal-error /
session-expiry reconnection bridge.

**Why.** The flat registry is the single largest structural gap in the MCP
subsystem (mcp-01). It blocks every richer behavior: you cannot attach an env
map, headers, a headersHelper, or an oauth block to a `{name, transport}`
string; you cannot track scope for approval/policy; you cannot dedup
plugin-provided servers; you cannot inherit the parent environment correctly.
This phase introduces a `core/mcp_config.zig` deep module as the new structured
config model and migrates the client to it, then layers the remaining
behaviors on top.

**Dependencies.** Phases 1 and 2. This phase reuses the scoped-settings merge
pattern (user / workspace / local / managed) established for general config in
`core/config_parse.zig`, and the permission-rules conventions from
`core/permission_rules.zig`. It assumes the runtime singleton (`rt.io`,
`rt.gpa`) and the `core/std_io.zig` / `core/clock.zig` / `core/rng.zig` shims
are in place (they are).

**Effort.** XL. This is a structural rewrite of the MCP config model plus eight
feature layers. The recommended order is: mcp-01 (scoped config model) first
because everything else attaches to the `ServerConfig` struct it defines, then
mcp-02 / mcp-03 / mcp-12 (which extend that struct and its parser), then the
runtime-facing layers (mcp-04 headers, mcp-08 content transform, mcp-09
timeouts, mcp-13 reconnect) in parallel, then the policy/approval/source layers
(mcp-05, mcp-06, mcp-11), and mcp-07 last as it is mostly a host-bridge polish.

## Gaps covered

| id | title | severity | size | our current state |
|---|---|---|---|---|
| mcp-01 | Scoped MCP config (.mcp.json project/local/user/enterprise) vs flat registry | high | L | MISSING. Flat `{name, transport}` array in one hardcoded file; no scope, no .mcp.json, no parent traversal, no structured config. |
| mcp-02 | Structured stdio config (command/args/env) + parent-env inheritance | high | M | PARTIAL. Transport is one shell string; env is fresh + auth token only, no parent inheritance, no per-server env map. |
| mcp-03 | Env-var expansion `${VAR}` / `${VAR:-default}` in config | medium | M | MISSING. Transport string used verbatim everywhere; no expansion. |
| mcp-04 | Static headers + dynamic headersHelper for remote transports | medium | M | MISSING. Only hardcoded HTTP headers; no headers field, no helper, no trust gate. |
| mcp-05 | Enterprise allow/deny MCP server policy (name/command/URL) | medium | M | MISSING. No allow/deny fields, no policy engine, `mcp add` accepts anything. |
| mcp-06 | Per-project approval (approved/rejected/pending) + enable/disable | medium | M | MISSING. Every registered server implicitly trusted/enabled; no project scope to gate. |
| mcp-07 | Full interactive elicitation UI + completion notifications | medium | L | PARTIAL. form/url modes + field validation via host bridge exist; no completion-notification handling, no native form UI, no datetime/multiselect-checkbox. |
| mcp-08 | Content transform: image resize, blob spill, resource_link, schema inference | high | L | PARTIAL. text passthrough + JSON fallback; `shouldSpill` defined but dead; no resource.text inlining, image, audio, blob spill, resource_link, or schema. |
| mcp-09 | Configurable timeouts via MCP_TIMEOUT / MCP_TOOL_TIMEOUT | low | S | MISSING env override. Hardcoded 30s stdio / 20s HTTP; one budget for connect+call. |
| mcp-11 | Plugin-provided + agent-frontmatter MCP servers (signature dedup) | medium | M | MISSING. Servers only from flat registry; PluginSpec/AgentSpec have no mcpServers field; no dedup. |
| mcp-12 | Config parse-warning surfacing (structured severity, Windows npx) | low | M | PARTIAL. Top-level invalid-JSON + not-on-PATH warnings only; no per-server schema, no severity, no Windows wrapper. |
| mcp-13 | Terminal-error reconnect + session-expiry retry | low | M | PARTIAL. One retry per RPC with session clear; no consecutive-error counter, no -32001 detection, no force-close/pending rejection. |

Verification notes from reading the source: the survey's claims hold. The
`Server` struct at `src/mcp/client.zig:18-21` is exactly `{name, transport}`.
`spawnStdioSession` at `src/mcp/client.zig:295-316` builds a fresh
`Environ.Map` with only the auth token and runs `zsh -lc <transport>`.
`mcp_registry_path` at `src/core/paths.zig:75` is a single hardcoded join.
`shouldSpill` at `src/core/mcp_output_limits.zig:35` is defined and only
referenced by its own test (dead in the client). Timeouts are constants at
`src/mcp/client.zig:15-16`. None of `getMcpConfigs`, `ConfigScope`,
`expandEnvVars`, `headersHelper`, `allowedMcpServers`, `getProjectMcpServerStatus`,
`getMcpServerSignature`, or `-32001` appear anywhere in `src/`.

---

## Implementation tasks

### Task 1 (mcp-01): Structured scoped config model and `.mcp.json` loader

**Goal.** Replace the flat `{name, transport}` registry with a structured,
scoped server-config model loaded from `.mcp.json` (project, with parent
traversal), user/local settings, enterprise managed file, and dynamic
`--mcp-config`, merged by precedence plugin < user < project < local.

**Reference behavior + file:line.**
- `services/mcp/types.ts:10-21` `ConfigScopeSchema` (local, user, project,
  dynamic, enterprise, claudeai, managed); `types.ts:23-177` transport schemas
  + `McpJsonConfig` ({ mcpServers: Record<name, McpServerConfig> }).
- `config.ts:843-881` `getProjectMcpConfigsFromCwd` (no traversal, used by
  add/remove); `config.ts:888-1026` `getMcpConfigsByScope` (project case walks
  CWD to filesystem root, processes root-downward so closest wins; user/local
  read from settings; enterprise reads the managed file).
- `config.ts:1071-1251` `getClaudeCodeMcpConfigs` (enterprise-exclusive when
  the enterprise file exists; otherwise merge plugin < user < project < local,
  filter project by approval, dedup plugins, apply policy).
- `utils.ts:263-299` `describeMcpConfigFilePath` / `getScopeLabel`.

**Target Zig files.**
- Create `src/core/mcp_config.zig` (deep module): the `ServerConfig` struct,
  `ConfigScope` enum, transport-type enum, `.mcp.json` parser, scope loaders,
  and the merge function. Register it in the `comptime` block in
  `src/main.zig` (after `_ = @import("core/mcp_output_limits.zig");` on line
  103) so the custom test runner discovers its tests.
- Edit `src/core/paths.zig`: add helpers `enterpriseMcpPath(allocator)` and
  `mcpJsonName` (`.mcp.json`); keep `mcp_registry_path` for the legacy
  user-scope `mcp add` writer (it becomes the "user scope" backing file, see
  Task 5 of this list / mcp-06 toggles).
- Edit `src/mcp/client.zig`: change `Server` to hold a
  `mcp_config.ServerConfig` (or embed scope + structured fields); update
  `readServers`/`writeServers` and the RPC dispatch to read structured fields.
- Edit `src/mcp_cmds.zig`: `cmdMcpAdd`/`cmdMcpList`/`cmdMcpRemove` to carry
  scope and structured fields.
- Use `@import("zcode_runtime")` for `rt.io`/`rt.gpa` in the new module; use
  `core/std_io.zig` for any stderr diagnostics.

**Approach.**
1. Define in `mcp_config.zig`:
   ```
   pub const ConfigScope = enum { local, user, project, dynamic, enterprise, claudeai, managed };
   pub const TransportType = enum { stdio, sse, http, ws, sdk };
   pub const ServerConfig = struct {
       name: []u8,
       scope: ConfigScope,
       type: TransportType,
       // stdio
       command: ?[]u8 = null,
       args: [][]u8 = &.{},
       env: []EnvEntry = &.{}, // ordered key/value list, dup-owned
       // remote
       url: ?[]u8 = null,
       headers: []HeaderEntry = &.{},
       headers_helper: ?[]u8 = null,
       // oauth (clientId/callbackPort/authServerMetadataUrl) - optional sub-struct
       oauth: ?OAuthConfig = null,
       disabled: bool = false,
       plugin_source: ?[]u8 = null,
       pub fn deinit(self: *ServerConfig, allocator) void { ... }
   };
   ```
   Store `env` and `headers` as ordered slices (not a hashmap) so iteration is
   deterministic and ownership is trivial to free. Map insertion order matters
   for env merge (per-server overrides parent).
2. Write `parseMcpJson(allocator, bytes, scope, expand_vars) -> ParseResult`
   that parses `{ "mcpServers": { name: { type, command, args, env, url,
   headers, headersHelper, oauth } } }`. Infer `type = .stdio` when `command`
   is present and `type` is absent (backwards compat per `types.ts:30`). Infer
   remote type from explicit `type` field; default unknown to a warning (see
   mcp-12). Validate `command` non-empty for stdio, `url` present for remote.
3. Write `loadProjectScope(allocator, cwd) -> { servers, errors }`: collect
   ancestor dirs from `cwd` up to the filesystem root, then process them
   root-downward (reverse) so a `.mcp.json` closer to CWD overrides a parent's
   (closest-wins). Use `std.fs.path.dirname` in a loop; stop when
   `dirname == null` or unchanged. Missing `.mcp.json` is not an error; a
   malformed one is surfaced (mcp-12).
4. Write `loadUserScope` / `loadLocalScope` reading the structured
   `mcpServers` block from the user/local TOML settings (extend
   `core/config_parse.zig` or read a sidecar JSON; prefer reusing the existing
   settings merge so user/local already have a home). Write
   `loadEnterpriseScope` reading `paths.enterpriseMcpPath`.
5. Write `mergeScopes(allocator, opts) -> { servers, errors }`: if the
   enterprise file exists, return ONLY enterprise servers (filtered by policy
   in mcp-05) - enterprise has exclusive control (`config.ts:1084`). Otherwise
   merge in precedence order plugin < user < project < local (later wins on
   key collision), matching `config.ts:1231-1238`. Return a
   `StringArrayHashMap`-style ordered result keyed by server name.
6. Migrate `src/mcp/client.zig`: `Client.init` takes the merged
   `[]ServerConfig` (or a resolver callback) instead of just `registry_path`.
   `serverByName` looks up the struct; the RPC dispatch reads `command`/`args`
   for stdio and `url`/`headers` for remote.
7. Keep `mcp add` writing to the user scope by default (a structured
   `mcpServers` object), matching the reference's `local` default for `claude
   mcp add` is actually `local`, but our single-user CLI default of "user" is
   acceptable; expose `--scope` later. For this task, preserve the existing
   `servers.json` read path as a one-time legacy importer: on first load, if
   `servers.json` exists, convert each `{name, transport}` into a structured
   stdio/remote `ServerConfig` (URL prefix => remote, else stdio with
   `command = transport`) so existing users do not lose registered servers.

**Acceptance criteria.**
- Write a test in `mcp_config.zig`: a `.mcp.json` with a stdio server (command
  + args + env) and an http server (url + headers) parses into two
  `ServerConfig`s with the right `type`, fields, and `scope == .project`.
- Write a test: two `.mcp.json` files in `parent/` and `parent/child/` (both
  via `core/test_helpers.zig` `tmpDirPath`) where both define server `foo`;
  loading from `child` yields the child's `foo` (closest-wins).
- Write a test: when an enterprise file exists, `mergeScopes` returns only
  enterprise servers even if user/project define others.
- Write a test: legacy `servers.json` with `{name, transport}` entries is
  imported into structured `ServerConfig`s (URL => remote, else stdio).
- `zcode mcp list` still lists previously-added servers after the migration.

**Test strategy.** Tests in `src/core/mcp_config.zig` run under
`tools/test_runner.zig`. Use `core/test_helpers.zig` `tmpDirPath`/`tmpDirCwd`
for any filesystem walking - never pass `"."` or a relative path to the parent
traversal (per CLAUDE.md: relative is resolved against the test process CWD).

**Risk / footguns.**
- `std.fs.path.relative` now takes 5 args `(gpa, cwd, environ_map, from, to)`
  (CLAUDE.md). The parent traversal needs only `dirname`, so avoid `relative`.
- After `parseFromSlice`, take `&parsed.value.object` by pointer if you mutate
  it; a value copy desyncs the entries pointer on realloc (CLAUDE.md).
- `readFileAlloc(.limited(N))` returns `error.StreamTooLong`, not
  `error.FileTooBig` (CLAUDE.md). A pathological `.mcp.json` should be capped.
- This is the biggest blast radius. Land the model + parser + tests first,
  then migrate the client in a follow-up edit within the same task so the
  build stays green at each step.

**Size.** L.

---

### Task 2 (mcp-02): Structured stdio spawn with parent-env inheritance and per-server env

**Goal.** Spawn stdio servers from the structured `command` + `args` with the
parent process environment inherited and the per-server `env` map merged on
top, instead of `zsh -lc <transport-string>` with a fresh empty environment.

**Reference behavior + file:line.**
- `types.ts:28-35` `{ command, args (default []), env }`.
- `client.ts:944-958`: `StdioClientTransport` runs `command` with `args` and
  `env: { ...subprocessEnv(), ...serverRef.env }` (parent env merged, then
  per-server env overrides).

**Target Zig files.**
- Edit `src/mcp/client.zig`: rewrite `spawnStdioSession` to take
  `command: []const u8, args: []const []const u8, env: []EnvEntry` instead of
  one `transport` string.
- Reuse `init.environ_map` via the runtime singleton, OR build a parent-env
  snapshot. Check `core/env.zig` for an existing accessor; if none returns a
  full map, add `pub fn parentEnvMap(allocator) !std.process.Environ.Map` there.

**Approach.**
1. Build a `std.process.Environ.Map` starting from the parent environment.
   `std.process.getEnvMap` is gone in 0.16 (CLAUDE.md); use
   `std.process.Environ.Map.init(alloc)` then populate from `init.environ_map`
   (threaded from main) or from an accessor in `core/env.zig`. The runtime
   singleton does not currently hold the full environ map - decide whether to
   thread `init.environ_map` into `Client` or add a `core/env.zig`
   `parentEnvMap` helper. Prefer the helper to avoid widening the Client
   constructor.
2. Layer the per-server `env` entries on top with `put` (override wins).
3. Keep the auth-token injection (`MCP_AUTH_TOKEN`, `ZCODE_MCP_AUTH_TOKEN`)
   that exists today.
4. Spawn with `argv = command ++ args` directly (not via `zsh -lc`). For
   backwards compatibility with legacy `{name, transport}` entries that were a
   shell string, the legacy importer in Task 1 should tokenize on whitespace
   into `command`+`args`; if the transport contained shell metacharacters
   (pipes, `&&`, env-prefix `FOO=bar cmd`), fall back to `["zsh","-lc",transport]`
   so existing shell-style entries keep working.

**Acceptance criteria.**
- Write a test that builds a `ServerConfig` with `command = "/bin/sh"`,
  `args = ["-c", "echo $FROM_PARENT:$FROM_SERVER"]`, sets `FROM_PARENT` in the
  parent env, and `env = [{FROM_SERVER, "v"}]`; assert the spawned process sees
  both (capture stdout). Gate on a Unix-only test if needed.
- Write a test that per-server `env` overrides a parent var of the same name.

**Test strategy.** Tests in `src/mcp/client.zig` (or a focused helper) run
under `tools/test_runner.zig`. Use a trivial `/bin/sh -c` echo so the test does
not need a real MCP server.

**Risk / footguns.**
- `Child.kill(io)` reaps internally; do not `wait()` after (CLAUDE.md). The
  existing `terminateChild` already follows this.
- For pipes, `readPositionalAll`/pread is ESPIPE; use `readStreaming(io,...)`
  (CLAUDE.md). The existing read path already does this for the session.
- `Environ.Map.remove` is gone; use `swapRemove` if you ever need to drop a key
  (CLAUDE.md).
- Do not regress the auth-token injection.

**Size.** M.

---

### Task 3 (mcp-03): Environment-variable expansion in config values

**Goal.** Expand `${VAR}` and `${VAR:-default}` in `command`, each `arg`, each
`env` value, `url`, and each header value when loading config, collecting
missing-variable names for warnings.

**Reference behavior + file:line.**
- `envExpansion.ts:10-38` `expandEnvVarsInString`: regex `\$\{([^}]+)\}`, split
  on `:-` (limit 2), substitute env value, else default, else keep the literal
  `${VAR}` and record the missing var.
- `config.ts:556-616` `expandEnvVars` walks command/args/env/url/headers.
- `config.ts:1330-1345` surfaces missing-var warnings.

**Target Zig files.**
- Create `src/core/mcp_env_expand.zig` (small deep module): pure
  `expandEnvVarsInString(allocator, value, lookup) -> { expanded, missing }`
  and `expandServerConfig(allocator, *ServerConfig, lookup) -> []const u8
  missing`. Register in the `src/main.zig` `comptime` block. Keep it pure: take
  a `lookup: *const fn([]const u8) ?[]const u8` so it is testable without
  touching the real environment.
- Wire it into `mcp_config.zig`'s parser (only when `expand_vars == true`,
  matching `parseMcpConfigFromFilePath({ expandVars: true })`).

**Approach.**
1. Implement the scanner: walk the string, on `${`, find the closing `}`, split
   the inner content on the first `:-` into `var_name` / `default`. Look up
   `var_name`; if found, emit it; else if a default exists, emit the default;
   else emit the literal `${...}` and push `var_name` to `missing`.
2. `expandServerConfig` rewrites each field in place (free old, set new) and
   accumulates `missing` across all fields.
3. The real `lookup` reads from `init.environ_map` / `core/env.zig`. Pass it
   from the config loader.

**Acceptance criteria.**
- Write tests: `${FOO}` with `FOO=bar` => `bar`; `${MISSING}` => literal
  `${MISSING}` + `missing == ["MISSING"]`; `${MISSING:-def}` => `def`, no
  missing; `${X:-a:-b}` => default is `a:-b` (split limited to 2, preserving
  `:-` in the default, per `envExpansion.ts:18`); a string with two refs
  expands both.
- Write a test that `expandServerConfig` rewrites `url` and a header value and
  reports a missing var found only in `command`.

**Test strategy.** Tests in `src/core/mcp_env_expand.zig` with an in-test
`lookup` closure - no real env access - run under `tools/test_runner.zig`.

**Risk / footguns.**
- Split-on-`:-` must be limited to 2 parts so a `:-` inside the default value
  is preserved (the reference uses `split(':-', 2)`).
- Free the old field string before assigning the expanded one; on OOM mid-walk
  use `errdefer` to avoid leaking partially-expanded copies.

**Size.** M.

---

### Task 4 (mcp-04): Static headers + dynamic headersHelper for remote transports

**Goal.** Support a static `headers` map and an optional `headersHelper` script
for sse/http/ws servers; run the helper (10s timeout, with
`CLAUDE_CODE_MCP_SERVER_NAME`/`_URL` in env - mirror with a zcode-prefixed
variant too), validate it returns a `string->string` JSON object, merge dynamic
over static, and gate project/local helper execution behind a trust check.

**Reference behavior + file:line.**
- `headersHelper.ts:32-117` `getMcpHeadersFromHelper`: trust check for
  project/local scope unless non-interactive; `execFileNoThrowWithCwd(helper,
  [], { shell: true, timeout: 10000, env: { ...process.env,
  CLAUDE_CODE_MCP_SERVER_NAME, CLAUDE_CODE_MCP_SERVER_URL } })`; require exit 0
  + stdout; parse JSON; require object (not array/null) with all string values;
  on any error return null (do not block the connection).
- `headersHelper.ts:125-138` `getMcpServerHeaders`: `{ ...static, ...dynamic }`.
- `client.ts:624,741,805` applies `combinedHeaders` to the transport.

**Target Zig files.**
- Create `src/mcp/headers_helper.zig`: `getMcpServerHeaders(allocator, *Client,
  *const ServerConfig) -> []HeaderEntry` and the internal helper runner.
  Register in `src/main.zig` `comptime`.
- Edit `src/mcp/client.zig` `postHttpRpc` (around lines 1520-1555) and the
  WebSocket connect path to apply combined headers on top of the hardcoded
  `Content-Type`/`Accept`/`Authorization`/`Mcp-Session-Id`/
  `MCP-Protocol-Version` set (dynamic/static override the defaults where keys
  collide, except never override the live `Mcp-Session-Id`).
- Reuse the trust signal: check `core/config.zig` or the workspace-trust state
  used elsewhere; if a `checkHasTrustDialogAccepted` analog does not exist, gate
  on the existing trust/onboarding state.

**Approach.**
1. If `headers_helper == null`, return a dup of the static `headers`.
2. Trust gate: if scope is `project` or `local` and the session is interactive
   and trust is not accepted, log and return static-only (do not run the
   script). In non-interactive mode, skip the gate (matches the reference's
   CI/automation carve-out).
3. Run the helper via `std.process.run(allocator, rt.io, .{ .argv =
   ["zsh","-lc",helper], .environ_map = env_with_context })` with a 10s
   timeout. `std.process.Child.init` is gone; use `run` (one-shot) per
   CLAUDE.md. Add `CLAUDE_CODE_MCP_SERVER_NAME`, `CLAUDE_CODE_MCP_SERVER_URL`
   (and zcode-prefixed twins) to a parent-env-derived map.
4. Require exit 0 and non-empty stdout; parse stdout as JSON; require a
   top-level object whose values are all strings; on any failure log and return
   static-only (never throw - do not block connect).
5. Merge: start from static, then overlay dynamic (dynamic wins).

**Acceptance criteria.**
- Write a test with `headers_helper = "echo '{\"X-Token\":\"abc\"}'"` and a
  static header `X-Static: s`; assert combined headers contain both, and that a
  helper key overrides a same-named static key.
- Write a test that a helper returning a JSON array or a non-string value is
  rejected and static-only headers are returned (no error propagated).
- Write a test that a project-scope helper is NOT executed when trust is not
  accepted in interactive mode (assert dynamic headers absent).

**Test strategy.** Tests in `src/mcp/headers_helper.zig` using `echo` scripts
as the helper, run under `tools/test_runner.zig`. Stub the trust signal via a
test-injectable predicate so the trust-gate test does not need real onboarding
state.

**Risk / footguns.**
- The 10s timeout must actually bound the child. Use
  `Io.Timeout`/`Io.Clock.Duration` `{ .raw, .clock }` fields correctly
  (CLAUDE.md) or kill-after-deadline; do not block the connect indefinitely.
- `Child.Cwd` is a union (`.{ .path = "..." }`) if you set cwd (CLAUDE.md).
- Never let a helper failure abort the connection - return null/static.

**Size.** M.

---

### Task 5 (mcp-05): Enterprise allow/deny MCP server policy

**Goal.** Enforce `allowedMcpServers` / `deniedMcpServers` (name, exact
command-array, or URL wildcard) from settings: denylist beats allowlist, empty
allowlist blocks all, `allowManagedMcpServersOnly` restricts the allowlist
source to managed settings; `mcp add` and the merge filter reject blocked
servers.

**Reference behavior + file:line.**
- `config.ts:320-334` `urlPatternToRegex` (escape regex specials except `*`,
  `*` => `.*`, anchored `^...$`).
- `config.ts:364-408` `isMcpServerDenied` (name, command-array, URL match).
- `config.ts:417-508` `isMcpServerAllowedByPolicy` (deny wins; undefined
  allowlist => allow all; empty => block all; if any command entries exist
  stdio MUST match one; if any URL entries exist remote MUST match one; else
  name-based).
- `config.ts:536-551` `filterMcpServersByPolicy` (sdk type exempt).
- `config.ts:667-679` `addMcpConfig` rejects blocked servers.

**Target Zig files.**
- Create `src/core/mcp_policy.zig`: the `AllowEntry`/`DenyEntry` union (name |
  command-array | url-pattern), `urlMatchesPattern`, `commandArraysMatch`,
  `isMcpServerDenied`, `isMcpServerAllowedByPolicy`, `filterMcpServersByPolicy`.
  Register in `src/main.zig` `comptime`.
- Edit `src/core/config.zig` (or the settings model): add `allowedMcpServers`,
  `deniedMcpServers`, `allowManagedMcpServersOnly` fields parsed from settings.
- Edit `src/core/mcp_config.zig` `mergeScopes` to call
  `filterMcpServersByPolicy` at the end (and enterprise-exclusive filter).
- Edit `src/mcp_cmds.zig` `cmdMcpAdd` to reject a server blocked by policy
  before writing it.

**Approach.**
1. Parse settings entries: a name entry `{ serverName }`, a command entry
   `{ serverCommand: [...] }`, a URL entry `{ serverUrl: "https://*..." }`.
2. `urlMatchesPattern`: build a regex-free matcher. Zig std has no regex; write
   a glob matcher that treats `*` as "match any run of chars" and matches the
   whole string (anchored). A simple recursive/iterative wildcard matcher
   suffices (no other metachars are meaningful in these patterns).
3. `commandArraysMatch`: exact element-wise equality of the command array
   (command + args), per `commandArraysMatch`.
4. Implement `isMcpServerDenied` then `isMcpServerAllowedByPolicy` exactly per
   the reference precedence. For `allowManagedMcpServersOnly`, source the
   allowlist from managed settings only; the denylist always merges from all
   sources.
5. `filterMcpServersByPolicy`: drop blocked, return blocked names so callers
   warn. Exempt `type == .sdk`.

**Acceptance criteria.**
- Write tests: undefined allowlist => allowed; empty allowlist => blocked;
  denylist name match => blocked even if also allowlisted; URL pattern
  `https://*.example.com/*` matches `https://api.example.com/x` and not
  `https://evil.com`; command-array entry blocks/allows a stdio server by exact
  args; when any command entries exist, a stdio server with no matching command
  is blocked.
- Write a test that `cmdMcpAdd` returns an error for a denied server.

**Test strategy.** Pure-function tests in `src/core/mcp_policy.zig` plus one
integration test through `cmdMcpAdd`, under `tools/test_runner.zig`.

**Risk / footguns.**
- The wildcard matcher must anchor both ends (reference uses `^...$`) and must
  escape nothing else - only `*` is special. Watch the empty-pattern and
  trailing-`*` cases.
- Deny-before-allow ordering is load-bearing; a test must lock it.

**Size.** M.

---

### Task 6 (mcp-06): Per-project approval + enable/disable toggles

**Goal.** Project (`.mcp.json`) servers require approval before connecting:
`approved` / `rejected` / `pending` based on
`enabledMcpjsonServers` / `disabledMcpjsonServers` / `enableAllProjectMcpServers`
plus non-interactive/bypass auto-approve; `isMcpServerDisabled` /
`setMcpServerEnabled` toggle servers via `disabledMcpServers` /
`enabledMcpServers`.

**Reference behavior + file:line.**
- `utils.ts:351-406` `getProjectMcpServerStatus`: rejected if in
  `disabledMcpjsonServers`; approved if in `enabledMcpjsonServers` or
  `enableAllProjectMcpServers`; approved in bypass mode (only when
  projectSettings enabled, and NOT via projectSettings-sourced bypass);
  approved in non-interactive mode when projectSettings enabled; else pending.
- `config.ts:1164-1170` filters project servers to approved before merge.
- `config.ts:1528-1578` `isMcpServerDisabled` / `setMcpServerEnabled`
  (default-disabled builtin requires explicit opt-in).

**Target Zig files.**
- Create `src/core/mcp_approval.zig`: `ProjectServerStatus` enum,
  `getProjectMcpServerStatus(name, settings, mode)`, `isMcpServerDisabled`,
  `setMcpServerEnabled`. Register in `src/main.zig` `comptime`.
- Edit `src/core/config.zig`: add `enabledMcpjsonServers`,
  `disabledMcpjsonServers`, `enableAllProjectMcpServers`, `disabledMcpServers`,
  `enabledMcpServers` settings fields.
- Edit `src/core/mcp_config.zig` `mergeScopes`: filter project servers by
  `getProjectMcpServerStatus(...) == .approved`; drop disabled servers
  (`isMcpServerDisabled`).
- Edit `src/mcp_cmds.zig`: add `mcp enable <name>` / `mcp disable <name>`
  subcommands writing the toggle, and surface approval status in `mcp list`.

**Approach.**
1. Normalize names for comparison the same way the reference does
   (`normalizeNameForMCP`) - check if zcode has a normalizer; if not, compare
   raw names but document the limitation.
2. `getProjectMcpServerStatus` implements the exact precedence: disabled-list
   => rejected; enabled-list or enable-all => approved; bypass-mode +
   project-enabled => approved (read bypass from user/local/flag/policy, NOT
   project settings, per the SECURITY note at `utils.ts:379-385`);
   non-interactive + project-enabled => approved; else pending.
3. In a non-interactive (headless) zcode run, pending project servers are not
   connected (matches reference). Interactive approval UI is out of scope for
   this phase (note in deferred); the toggles + auto-approve paths are the
   parity-critical part.

**Acceptance criteria.**
- Write tests for each branch of `getProjectMcpServerStatus`: disabled-list =>
  rejected; enabled-list => approved; enable-all => approved; non-interactive +
  project-enabled => approved; bypass via project settings does NOT approve;
  default => pending.
- Write a test that `mergeScopes` drops a pending project server and keeps an
  approved one.
- Write a test that `setMcpServerEnabled(false)` then `isMcpServerDisabled`
  round-trips through settings.

**Test strategy.** Pure-function tests in `src/core/mcp_approval.zig` with
in-test settings structs; one merge integration test, under
`tools/test_runner.zig`.

**Risk / footguns.**
- The bypass-mode security carve-out (project settings must NOT be able to
  self-approve via bypass) is the subtle bug; a test must encode it.
- Without a name normalizer, `My-Server` vs `my_server` will not match the
  reference; verify whether normalization exists before relying on raw compare.

**Size.** M.

---

### Task 7 (mcp-08): MCP tool-result content transformation

**Goal.** Transform each MCP result content block: text passthrough; image =>
base64 image block (resize/downsample best-effort); audio/binary resource =>
spill the blob to disk and emit a small text block; resource with text =>
inline with a provenance prefix; resource_link => formatted text;
`structuredContent` => JSON string + a compact inferred schema; `toolResult` =>
stringified. Wire the 100KB spill cap (`shouldSpill`).

**Reference behavior + file:line.**
- `client.ts:2478-2591` `transformResultContent` (text/audio/image/resource/
  resource_link).
- `client.ts:2598-2627` `persistBlobToTextBlock` (write file, return a
  `getBinaryBlobSavedMessage` text block; on write error return a text block
  noting the failure).
- `client.ts:2644-2660` `inferCompactSchema` (recursive, depth 2, first 10
  keys, `, ...` suffix, arrays as `[elemtype]`).
- `client.ts:2662-2706` `transformMCPResult` (toolResult => string;
  structuredContent => json + schema; content array => transform each + flat).
- `core/mcp_output_limits.zig` already defines `shouldSpill` (100KB) and
  `truncateDescription`.

**Target Zig files.**
- Edit `src/mcp/parsers.zig` `flattenContentValue` (lines 67-98) to handle the
  block types. Split into a typed transform that returns a list of content
  blocks (text and/or image), not a single flattened string, so images survive.
- Create `src/core/mcp_blob_spill.zig`: `persistBlob(allocator, bytes,
  mime_type, server_name) -> { filepath, size } | error`; uses a spill
  directory under `paths.zcode_home` (e.g. `mcp-blobs/`). Register in
  `src/main.zig` `comptime`.
- Add `inferCompactSchema(allocator, json.Value, depth) -> []u8` to
  `parsers.zig` (or `mcp_output_limits.zig`).
- Wire `shouldSpill` into the result handler in `src/mcp/client.zig` (currently
  only `truncateDescription` is used at line 935).

**Approach.**
1. Define `pub const ContentBlock = union(enum) { text: []u8, image: struct {
   data_base64: []u8, media_type: []u8 } };` and make the transform produce
   `[]ContentBlock`.
2. Block handling:
   - `text` => one text block.
   - `resource` with `text` => text block prefixed
     `[Resource from <server> at <uri>] ` (this is the MISSING inlining today -
     `parsers.zig:86-90` only emits a `resource: <uri> <mime>` stub).
   - `resource` with `blob`: if `mimeType` is an image type => image block
     (with optional prefix text block); else => spill via
     `mcp_blob_spill.persistBlob` and emit a text block with the saved path.
   - `audio` => spill (base64 decode) + text block.
   - `image` => base64 image block. Resizing/downsampling is best-effort:
     zcode has no image library; emit the image as-is but enforce the
     spill/size cap so a giant image does not blow context. Note the
     downsampling shortfall in deferred.
   - `resource_link` => `[Resource link: <name>] <uri> (<description>)`.
3. `structuredContent` => `jsonStringify` + `inferCompactSchema`. Emit the
   schema as a leading text line (the reference attaches it to the result;
   surface it so the model gets the type hint).
4. `toolResult` => `String(...)`.
5. After assembling the textual portion of a result, if the serialized text
   exceeds `MAX_RESULT_INLINE` (and the content is not an image), spill the
   whole result to disk and emit a pointer text block (matches the reference's
   image-aware spill at `client.ts:2713-2718` - images use truncation, not
   spill).

**Acceptance criteria.**
- Write a test: a result content array with a `resource` that has a `text`
  field => the output text block contains the resource text and the
  `[Resource from ... at ...]` prefix (today this is a stub - the test must
  fail before the change).
- Write a test: a `resource_link` block => formatted `[Resource link: ...]`
  text.
- Write a test: `inferCompactSchema` on `{title:"x", items:[{id:1}]}` =>
  `{title: string, items: [{id: number}]}`; an object with >10 keys ends in
  `, ...`; depth cutoff yields `{...}`.
- Write a test: a binary `resource` blob => `persistBlob` writes a file under
  the spill dir and the emitted text block names the path and byte size.
- Write a test: a >100KB text result triggers `shouldSpill` and emits a pointer
  block instead of inlining (assert the wiring, currently dead).

**Test strategy.** Tests in `src/mcp/parsers.zig`, `src/core/mcp_blob_spill.zig`
(use `tmpDirPath` for the spill dir), and `src/core/mcp_output_limits.zig`,
under `tools/test_runner.zig`.

**Risk / footguns.**
- Image resize/downsample is genuinely out of reach without an image codec;
  scope it to "emit as-is + cap", not pixel resizing. State this clearly so the
  acceptance bar is honest (do not claim parity on resize).
- Base64 decode of large blobs: bound the allocation; spill rather than holding
  decoded + base64 + file copies simultaneously.
- `flattenContentValue` is called from existing call sites expecting a string;
  changing its signature touches callers - update them or add a new typed
  function and keep the old as a thin adapter to avoid a wide diff.

**Size.** L.

---

### Task 8 (mcp-09): Configurable timeouts via MCP_TIMEOUT / MCP_TOOL_TIMEOUT

**Goal.** Read `MCP_TIMEOUT` (connection, default 30000ms) and
`MCP_TOOL_TIMEOUT` (tool call, default ~27.8h = 100_000_000ms) so connect and
tool-call budgets are separate and env-overridable.

**Reference behavior + file:line.**
- `client.ts:456-458` `getConnectionTimeoutMs` = `MCP_TIMEOUT || 30000`.
- `client.ts:209-229` `DEFAULT_MCP_TOOL_TIMEOUT_MS = 100_000_000`;
  `getMcpToolTimeoutMs` = `parseInt(MCP_TOOL_TIMEOUT) || default`.

**Target Zig files.**
- Edit `src/mcp/client.zig`: replace the constants at lines 15-16 with
  functions `connectionTimeoutMs()` (reads `MCP_TIMEOUT`, default 30000) and
  `toolTimeoutMs()` (reads `MCP_TOOL_TIMEOUT`, default 100_000_000), reading
  env via `core/env.zig`. Apply `connectionTimeoutMs` to handshake/connect and
  `toolTimeoutMs` to `tools/call` RPCs specifically. Also bump the legacy
  hardcoded 8000ms HTTP path to use `connectionTimeoutMs`.

**Approach.**
1. Add the two functions; parse the env var with `std.fmt.parseInt`, fall back
   to the default on missing/invalid/<=0 (the reference's `|| default` treats
   `0`/NaN as unset).
2. Thread the tool-call timeout into the RPC path used by `tools/call`. Keep
   connect-phase RPCs on the connection timeout.

**Acceptance criteria.**
- Write tests for the parsers: unset => default; `MCP_TIMEOUT=5000` => 5000;
  `MCP_TIMEOUT=abc` => default; `MCP_TIMEOUT=0` => default; `MCP_TOOL_TIMEOUT`
  large value honored.
- Manual: a tool call that runs longer than 30s but under the new default no
  longer times out at 30s.

**Test strategy.** Pure parser tests with an injectable env lookup (do not
mutate the process env in tests), under `tools/test_runner.zig`.

**Risk / footguns.**
- The default tool timeout (100_000_000ms) is effectively infinite; make sure
  the underlying read loop honors a very large timeout without integer
  overflow when converted to `Io.Clock.Duration` (`{ .raw, .clock }` fields,
  CLAUDE.md).
- Do not regress the connect timeout to infinite - keep connect at 30s default.

**Size.** S.

---

### Task 9 (mcp-13): Terminal-error reconnect + session-expiry retry

**Goal.** Track consecutive terminal connection errors and force-close after
`MAX_ERRORS_BEFORE_RECONNECT` (3), rejecting pending calls cleanly; detect HTTP
404 + JSON-RPC `-32001` (session-not-found) and retry the tool call with a
fresh session up to `MAX_SESSION_RETRIES`.

**Reference behavior + file:line.**
- `client.ts:200-206` `isMcpSessionExpiredError`: message contains
  `"code":-32001` or `"code": -32001`.
- `client.ts:1249-1365` `isTerminalConnectionError` (ECONNRESET/ETIMEDOUT/
  EPIPE/EHOSTUNREACH/ECONNREFUSED/Body Timeout/terminated/SSE disconnect) +
  `consecutiveConnectionErrors` counter + `MAX_ERRORS_BEFORE_RECONNECT = 3` +
  `closeTransportAndRejectPending`.
- `client.ts:1911-1922` session-expiry retry loop (`MAX_SESSION_RETRIES`).
- `client.ts:2137-2156` `reconnectMcpServerImpl` / `clearServerCache`.

**Target Zig files.**
- Edit `src/mcp/client.zig`: add a per-session consecutive-error counter and
  `MAX_ERRORS_BEFORE_RECONNECT`; in `rpcStdioPersistent` (1702),
  `rpcWebSocketPersistent` (1799), and `rpcHttp` (1449), increment on terminal
  errors and force-close (clear session) when the threshold is reached, instead
  of the current single-retry. Extract the JSON-RPC `code` field in
  `src/mcp/parsers.zig` (lines 609-615 parse the message but not the code) and
  add `isSessionExpired(http_status, rpc_code)` => `status == 404 and rpc_code
  == -32001`. Add an explicit `reconnect(server_name)` method that clears the
  session cache.

**Approach.**
1. In `parsers.zig`, when parsing an error object, also extract the integer
   `code`. Expose it on the parsed error so the client can branch on `-32001`.
2. Add a `terminal_error_count` to each persistent session struct
   (`StdioSession`, `HttpSession`, `PersistentWebSocketSession`). On a terminal
   error, increment; at >= 3, clear the session (force reconnect on next call)
   and reset the counter. On a non-terminal error, reset to 0.
3. Session-expiry retry: in `rpcHttp`, on HTTP 404 + rpc code `-32001`, clear
   the HTTP session and retry the tool call up to `MAX_SESSION_RETRIES` (2)
   with a fresh init. The existing 404/409 re-init at line 1462 is close;
   tighten it to require the `-32001` code (currently it does not extract the
   code at all).
4. Add `pub fn reconnect(self: *Client, name) void` that clears all three
   session caches for a server (the explicit `/mcp reconnect` analog;
   `clearStdioSession`/`clearHttpSession`/`clearWebSocketSession` already
   exist - wrap them).
5. "Pending call rejection": our model is synchronous per-RPC (no async pending
   queue), so a force-close simply makes the in-flight `tools/call` return a
   clean transport error rather than hanging. Document that the reference's
   pending-promise rejection maps to "return the RPC error" here.

**Acceptance criteria.**
- Write a test for `isSessionExpired`: 404 + code `-32001` => true; 404 + other
  code => false; 200 + `-32001` => false (reference keys on 404).
- Write a test that `parsers` extracts the `code` from
  `{"error":{"code":-32001,"message":"Session not found"}}`.
- Write a test that three consecutive terminal errors clear the session
  (assert the session map no longer contains the entry after the third).
- Write a test that `reconnect(name)` clears any cached sessions for that name.

**Test strategy.** Tests in `src/mcp/parsers.zig` (code extraction,
`isSessionExpired`) and `src/mcp/client.zig` (counter/clear behavior via a fake
session inserted into the maps), under `tools/test_runner.zig`.

**Risk / footguns.**
- The terminal-error string matching must cover the same substrings; in Zig use
  `std.mem.indexOf` on the error name / message. Zig error sets are not strings
  - map the spawn/IO errors (e.g. `error.ConnectionResetByPeer`,
  `error.BrokenPipe`, timeouts) to the "terminal" category by error tag, not by
  substring, where possible; fall back to message substring for transport
  payloads.
- Do not double-clear a session (re-entrancy): the reference guards with
  `hasTriggeredClose`. Mirror with an idempotent clear.

**Size.** M.

---

### Task 10 (mcp-11): Plugin-provided and agent-frontmatter MCP servers with signature dedup

**Goal.** Surface MCP servers declared in plugin manifests (namespaced
`plugin:<name>:<server>`) and in agent frontmatter into the merged config, and
drop plugin servers whose stdio-command or URL signature duplicates a manual or
earlier-plugin server.

**Reference behavior + file:line.**
- `config.ts:202-212` `getMcpServerSignature` (`stdio:<jsonArgs>` or
  `url:<unwrapped>`; null for sdk).
- `config.ts:223-266` `dedupPluginMcpServers` (manual wins; between plugins
  first-loaded wins; report suppressed).
- `config.ts:1114-1229` plugin server loading + dedup (namespaced keys, merged
  after dedup).
- `utils.ts:466-553` `extractAgentMcpServers`.

**Target Zig files.**
- Edit `src/core/plugins.zig`: add `mcp_servers: []mcp_config.ServerConfig` to
  `PluginSpec` (line 31) and parse a `mcpServers` object in
  `parseManifestFile` (line 269); namespace keys `plugin:<plugin-name>:<server>`
  and stamp `plugin_source`.
- Edit `src/core/agents.zig`: add `mcp_servers` to `AgentSpec` (line 23) and
  parse `mcpServers` in `loadFile` (line 357). (Agent frontmatter here is the
  agent JSON definition.)
- Edit `src/core/mcp_config.zig`: add `getMcpServerSignature(*const
  ServerConfig) -> ?[]u8` and `dedupPluginMcpServers(plugin, manual) ->
  { servers, suppressed }`; call it in `mergeScopes` before the precedence
  merge, with plugin servers at the lowest precedence.

**Approach.**
1. Signature: stdio => `stdio:` + JSON of `[command, ...args]`; remote =>
   `url:` + url (no CCR-proxy unwrap needed for zcode unless we add one - note
   the minor divergence). null for sdk.
2. Build a `manualSigs` map (first-wins), then walk plugin servers: if a
   signature matches a manual server, suppress (record `{name, duplicateOf}`);
   else if it matches an earlier plugin signature, suppress; else keep.
3. Merge order: deduped-plugin < user < project < local, matching
   `config.ts:1231-1238`.
4. Agent-frontmatter servers: extract from the active agent's spec when an
   agent is selected; merge them in (the reference adds them as a scope-tagged
   source). Keep this minimal - tag them with an appropriate scope and run them
   through the same dedup/policy.

**Acceptance criteria.**
- Write a test: a plugin manifest with `mcpServers` produces namespaced
  `ServerConfig`s with `plugin_source` set.
- Write a test: `getMcpServerSignature` returns `stdio:["npx","-y","x"]`-shaped
  and `url:https://...`, null for sdk.
- Write a test: a plugin server whose command matches a manual server is
  suppressed and reported; between two plugins with the same signature, the
  first is kept.
- Write a test: an agent definition with `mcpServers` surfaces those servers.

**Test strategy.** Tests in `plugins.zig`, `agents.zig`, and `mcp_config.zig`
using `tmpDirPath` for manifest/agent files, under `tools/test_runner.zig`.

**Risk / footguns.**
- Adding fields to `PluginSpec`/`AgentSpec` requires updating their `deinit`,
  `clone`, and `freeList` to own/free the new slices, or you leak/double-free.
- Namespacing keys must be consistent everywhere they are looked up (dedup,
  policy, approval) so `plugin:x:y` does not collide with a manual `y`.

**Size.** M.

---

### Task 11 (mcp-12): Structured config parse-warning surfacing

**Goal.** Produce structured, severity-tagged validation results (fatal vs
warning) for schema violations, invalid JSON, missing env vars, and a
Windows-specific warning when `command` is `npx` without a `cmd /c` wrapper.

**Reference behavior + file:line.**
- `config.ts:1297-1468` `parseMcpConfig` / `parseMcpConfigFromFilePath` with
  `mcpErrorMetadata` severity (fatal/warning).
- `config.ts:1350-1369` Windows `npx` + `cmd /c` warning.
- `components/mcp/McpParsingWarnings.tsx` renders them.

**Target Zig files.**
- Edit `src/core/mcp_config.zig`: define `pub const ValidationError = struct {
  scope: ConfigScope, server_name: ?[]u8, message: []u8, severity: enum {
  fatal, warning } };` and have the parser collect these instead of only
  printing to stderr. Return them from `parseMcpJson` / `loadProjectScope` /
  `mergeScopes`.
- Edit `src/mcp_cmds.zig`: render collected warnings in `mcp list` / on load
  (stderr) with the severity prefix.

**Approach.**
1. Replace ad-hoc stderr prints with appended `ValidationError`s: invalid JSON
   => fatal; missing required field (`command` for stdio, `url` for remote) =>
   fatal for that server (skip it); unknown `type` => warning; missing env var
   (from mcp-03) => warning; Windows + `command == "npx"` and not wrapped in
   `cmd /c` => warning.
2. The Windows npx check: detect OS via `@import("builtin").os.tag == .windows`
   (not a runtime shell check - the reference is platform-conditional). Since
   zcode currently spawns via `zsh -lc`, this warning is informational on
   non-Windows and active only when building/running on Windows.
3. Surface the collected warnings to the operator (stderr, prefixed `warning:`
   / `error: mcp:`); keep stdout clean for machine consumers (matches the
   existing discipline in `cmdMcpAdd`).

**Acceptance criteria.**
- Write tests: a server missing `command` yields a fatal `ValidationError` and
  is skipped; an unknown `type` yields a warning but the server is kept where
  possible; a missing `${VAR}` (no default) yields a warning carrying the var
  name; on Windows-tagged build, `command:"npx"` without `cmd /c` yields a
  warning.
- Write a test that `mergeScopes` accumulates warnings across scopes.

**Test strategy.** Pure parser tests in `src/core/mcp_config.zig`, under
`tools/test_runner.zig`. Gate the Windows test on `builtin.os.tag` or assert
the predicate directly so it runs on macOS.

**Risk / footguns.**
- A fatal error for one server must not abort the whole load - skip the bad
  server, keep the rest (matches reference per-server granularity).
- Do not print warnings to stdout.

**Size.** M.

---

### Task 12 (mcp-07): Elicitation completion notifications + field-validation polish

**Goal.** Close the remaining elicitation gaps: handle `elicitation/complete`
(URL-mode completion) notifications, add datetime (`format: date-time`)
validation and multiselect (`enum` array) handling, and confirm the cancel
default. Native rich-form UI remains delegated to the host bridge (documented).

**Reference behavior + file:line.**
- `elicitationHandler.ts:173-207` `ElicitationCompleteNotificationSchema`
  handler (sets `completed: true` on the matching queued URL elicitation;
  ignores unknown ids; fires a notification hook).
- `ElicitationDialog.tsx:1-60` enum/multiselect/datetime helpers + form/url
  params + URL phase-2 waiting state.
- `client.ts:1191-1197` default cancel handler.

**Target Zig files.**
- Edit `src/agent_runtime.zig` (around lines 616-617 where `elicitation/create`
  is routed): add a route for the `notifications/elicitation/complete` method
  (or the spec's exact method string) that records completion against the
  pending URL elicitation id.
- Edit `src/agent_history.zig` `promptForElicitationField` (981-1105): add
  `format: date-time` validation (parse ISO-8601, retry up to 3) and treat an
  `enum`-array schema as a multiselect (accept a comma-separated subset
  restricted to the enum values, validating each against the enum).
- Edit `src/mcp/client.zig:2299` capability block only if a completion
  capability flag is needed; otherwise leave the advertised
  `elicitation:{form:{},url:{}}` as-is.

**Approach.**
1. Add a completion-notification handler: parse `params.elicitationId`, mark
   the matching pending URL elicitation complete (our model is synchronous via
   the host bridge, so this primarily means: stop waiting / accept). If the id
   is unknown, log and ignore (matches reference).
2. Datetime: when a string field carries `format: "date-time"`, validate the
   answer parses as ISO-8601 (reuse any existing time parser in
   `core/clock.zig` or add a minimal validator); reject + retry on failure.
3. Multiselect: when an array field's items are an `enum`, parse the
   comma-separated answer, trim each, and require every value be in the enum;
   reject + retry otherwise. (Full checkbox UI stays bridge-delegated.)
4. Confirm the default action on cancel/abort is `{"action":"cancel"}` (matches
   `client.ts:1191-1197`).

**Acceptance criteria.**
- Write a test that a completion notification for a known URL elicitation id is
  routed and recorded; an unknown id is ignored without error.
- Write a test that a `date-time` field rejects `not-a-date` and accepts
  `2026-05-29T12:00:00Z`.
- Write a test that an enum-array multiselect rejects a value not in the enum
  and accepts a valid comma-separated subset.

**Test strategy.** Tests in `src/agent_history.zig` (field validation via a
scripted `ask_user_fn` that returns canned answers and asserts retry behavior)
and `src/agent_runtime.zig` (notification routing), under
`tools/test_runner.zig`.

**Risk / footguns.**
- This gap is genuinely PARTIAL today (form/url + most field types already
  exist via the host bridge). Do not over-build a native form UI - the parity
  shortfall is the completion notification and the two missing field types.
  State clearly that the rich 1200-line dialog is intentionally bridge-delegated.

**Size.** L (mostly because elicitation wiring is spread across runtime +
history; the actual new code is moderate).

---

## Verification

Whole-phase done means all of the following pass.

1. **Build and install** (per CLAUDE.md, every change):
   ```
   /Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build -Doptimize=ReleaseFast
   rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode
   ```
   Use `rm -f` before `cp` so a fresh inode gets a valid ad-hoc signature
   (macOS in-place overwrite SIGKILLs the next run).

2. **Tests** (custom runner): `zig build test` is green; every new module
   (`core/mcp_config.zig`, `core/mcp_env_expand.zig`, `core/mcp_policy.zig`,
   `core/mcp_approval.zig`, `core/mcp_blob_spill.zig`, `mcp/headers_helper.zig`)
   is registered in the `src/main.zig` `comptime` block (line 41 onward) so its
   `test` blocks are discovered, and each prints `RUN: <name>`.

3. **Version bump**: patch number bumped in `build.zig.zon` (`.version =
   "X.Y.Z"`); the git short-hash is appended automatically by `build.zig`.

4. **Manual checks** (run by the assistant, not handed to the user):
   - Create a `.mcp.json` in a tmp project with a stdio server (command/args/
     env) and a parent `.mcp.json` overriding it; run `zcode mcp list` from the
     child dir and confirm closest-wins.
   - Set `FOO` in the env and a server `args: ["${FOO}"]`; confirm expansion in
     the spawned command (debug log) and a missing-var warning for `${BAR}`.
   - Add an `allowedMcpServers: []` (empty) to settings; confirm all servers are
     blocked and `mcp add` of a denied server errors.
   - Set `MCP_TIMEOUT=5000` and `MCP_TOOL_TIMEOUT=120000`; confirm the connect
     budget is 5s and a >30s tool call is no longer cut off at 30s.
   - Configure a remote server with `headersHelper: "echo '{...}'"`; confirm
     the dynamic header reaches the request (via `ZCODE_DEBUG_LLM`-style raw
     logging or a local echo endpoint).
   - Call a tool that returns a `resource` with text and a binary blob; confirm
     the text is inlined with the provenance prefix and the blob is written to
     the spill dir with a path/size text block.

## Out-of-scope / deferred notes

- **Image resize/downsample** (part of mcp-08): zcode has no image codec, so
  this phase emits images as-is + size-cap rather than pixel-resizing. True
  `maybeResizeAndDownsampleImageBuffer` parity is deferred (would need an image
  library or a sidecar).
- **Rich native elicitation form UI** (mcp-07): the ~1200-line `ElicitationDialog`
  with live checkbox multiselect and datetime pickers stays delegated to the
  host bridge. This phase adds completion-notification handling and the two
  missing validation paths only.
- **claude.ai connector discovery** (`claudeai` scope, `claudeai.ts`,
  `dedupClaudeAiMcpServers`): the scope enum value is included for completeness
  but fetching connectors from claude.ai is out of scope here (network + auth
  surface belongs with the broader claude.ai integration work).
- **SDK / sse-ide / ws-ide transports** (`McpSdkServerConfigSchema`,
  IDE-only schemas): the `sdk` type is recognized for policy-exemption purposes
  but no SDK control transport is implemented; IDE-extension transports are out
  of scope.
- **`--mcp-config` (dynamic scope) CLI plumbing**: the `dynamic` scope is in the
  enum and the merge accepts dynamic servers, but wiring the `--mcp-config`
  flag end-to-end (arg parsing, JSON-string-or-file) can land in a follow-up if
  it is not already covered by the args layer; confirm against `cli/args.zig`
  before closing the phase.
- **`enableAllProjectMcpServers` settings migration** (reference
  `migrations/migrateEnableAllProjectMcpServersToSettings.ts`): zcode does not
  carry the same legacy config, so no migration is needed; the field is read
  directly.
- **Interactive project-server approval dialog** (`MCPServerApprovalDialog.tsx`):
  this phase implements the status computation and the enable/disable toggles;
  the interactive "approve this project server?" TUI prompt is deferred. In
  headless/non-interactive runs the auto-approve rules already cover the
  parity-critical behavior.
