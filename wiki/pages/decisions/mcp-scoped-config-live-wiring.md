# MCP scoped config: how it reaches live connections

Phase 6 (PRD #534) built the structured scoped-config MODULES (`core/mcp_config.zig`,
`mcp/headers_helper.zig`, `core/mcp_policy.zig`, `core/mcp_approval.zig`) but left
the live `mcp/client.zig` still driving every connection from the flat legacy
`Server = {name, transport}` registry. This page records how that gap was closed
without a full `Server -> ServerConfig` type rewrite.

## The wiring (the minimal path that was taken)

The live `Client` (`src/mcp/client.zig`) gained a lazily-loaded, cached merged
`ServerConfig` set instead of rewriting `Server`:

- `Client.scoped_servers: []ServerConfig` + `scoped_loaded` + `scoped_enabled` +
  `scoped_cwd`. `main.zig` calls `mcp.enableScopedConfig()` once after
  construction; **unit tests never call it, so they stay hermetic** (no real CWD,
  no real connections).
- `ensureScopedConfig()` -> `loadScopedConfig()` merges, by precedence
  plugin < user < project < local:
  - legacy `servers.json` registry imported at **user** scope (so `mcp add`
    servers keep connecting) via `importLegacyRegistry`,
  - project `.mcp.json` parent-traversal (closest-wins, `${VAR}` expanded) via
    `loadProjectScope(cwd, true)`,
  - enterprise managed file (exclusive control when present),
  - filtered by `mcp_policy.loadPolicy` + `mcp_approval` (loaded from settings
    rooted at cwd), with `mode = .non_interactive` so a headless connect
    auto-approves project servers (interactive approval TUI is deferred).
  Collected `ValidationError`s render to stderr on load (mcp-12).
- `serverConfigFor(name)` lazily loads the set and returns the structured config.
  `rpcRequestForServer` consults it FIRST: stdio -> `rpcStdioPersistentStructured`
  (spawn `command ++ args` with parent env + per-server env, no `zsh -lc`);
  http/sse -> `rpcHttpStructured`; ws -> the ws path. Legacy transport-string
  dispatch is the fallback when no structured config exists.
- `list()` returns the merged set rendered back to `{name, transport}` when
  scoped config is active; otherwise the raw legacy registry.

## Header wiring (mcp-04, was the deferred Task 4)

`getMcpServerHeaders` resolution was built but never reached the live HTTP path:
`postHttpRpc` called `postHttpRpcWithHeaders(&.{})` (empty). Fix:
- `rpcHttpStructured` resolves headers via `headers_helper.getMcpServerHeaders`
  (`.interactive = false` -> bypasses the project/local helper trust gate, CI
  carve-out), stashes them in `Client.http_extra_headers` for the duration of the
  call, and runs the normal `rpcHttp` path.
- `postHttpRpc` now passes `self.http_extra_headers` (empty for legacy calls).
  This is a **transient per-call field**, not threading the param through 6
  signatures (`rpcHttp`/`ensureHttpInitialized`/`initializeHttpInfo`/`postHttpRpc`
  + the SSE reply path). Safe because MCP I/O is synchronous per-RPC (see the
  `isConnected` concurrency note in client.zig). It covers BOTH the init
  handshake and the tool-call RPC.
- The header-line assembly was extracted to a pure file-scope
  `buildHttpHeaderLines(...)` so the overlay is unit-testable without spawning
  curl.

## Gotchas hit

- `mergeScopes` **consumes** every input server slice (moves or frees them). After
  calling it you MUST clear the moved-out `.servers` handles (`ent.servers = &.{}`
  etc.) or the errdefers double-free. Same for `.errors` -> use the
  `concatValidationErrors` helper which moves elements then frees backing slices.
- The approval filter (`filterProjectServers`) gates **project-scope** servers
  only; user-scope (legacy-imported) servers pass through ungated.
- `loadProjectScope` walks ancestors to the FS root, so a stray `.mcp.json` in a
  tmp-dir ancestor could leak into a test. macOS `/var/folders` tmp dirs are deep
  enough that this hasn't bitten, but keep it in mind.

## Deliberately deferred (still flat-registry / module-only)

- No `Server -> ServerConfig` type rewrite. `Server` stays `{name, transport}`;
  the structured config is a parallel cache consulted at dispatch time. This is
  the internal-cleanup deferral; the user-facing parity (scoped config drives
  connections, headers apply) is fully wired.
- `mcp list` does NOT add a scope/approval-status column (would change the
  machine-readable TSV row arity). Status is ENFORCED (unapproved/disabled
  servers don't appear/connect); the cosmetic column is deferred.
- `--mcp-config` (dynamic scope) CLI plumbing, plugin/agent-frontmatter server
  sourcing into the live merge, interactive trust/approval TUI.
