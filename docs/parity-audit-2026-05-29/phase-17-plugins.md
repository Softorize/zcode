# Phase 17: Plugins and marketplace lifecycle

## Overview

**What.** This phase closes the parity gap between zcode's plugin/marketplace subsystem and the reference (`claude-code-main`) implementation. zcode already ships a working install/uninstall/update/list/show flow, a sha256-pinned remote source registry, a workspace-trust gate, a bespoke 5-event subprocess plugin runner, and plugin-provided skills. What it lacks is the *lifecycle and policy* layer the reference treats as the core of the subsystem: per-plugin enable/disable persisted in settings, org-policy force-disable, transitive dependency resolution with reverse-dependent warnings, plugins contributing to the real hook engine, plugins contributing MCP servers and subagents, the human-readable trust disclaimer, delisting detection, background autoupdate, and git-SHA version derivation for cache keying.

**Why.** Today a zcode plugin's "enabled" state is derived purely from `trust_status.trusted` (user plugins always on, workspace plugins on only if the workspace is trusted). There is no way for a user to turn off a single plugin without uninstalling it, no way for an org to force-disable a plugin via managed settings, and no safety net when one plugin depends on another. The reference treats `settings.enabledPlugins` as the single source of truth and layers policy, dependency, hook, MCP, and agent integration on top of it. Reaching parity on the *control surface* (gaps 01, 06, 07) and the *capability surface* (gaps 02, 03, 04, 05) is what makes plugins a real extension point rather than a script runner.

**Dependencies on earlier phases.** This phase leans on infrastructure already present:
- Settings/config persistence: `core/config_parse.zig:persistUserConfigField` (gap 01, 07) and `Config.isManagedLocked` (gap 07).
- The hook engine: `core/hook_event.zig` (26-event `Event` enum), `core/hook_matcher.zig`, `core/hook_config.zig`, `core/hooks.zig` (gap 02).
- The MCP registry: `mcp/client.zig` `readServers`/`writeServers` (gap 03).
- The agent loader: `core/agents.zig:list` with its `appendFromDir` pattern (gap 04), mirroring the already-shipped `core/skills.zig:appendPluginSkills`.
- The marketplace catalog + source registry: `core/marketplace.zig` (gaps 05, 09, 10).
- Trust + security gating: `core/security.zig:ensureMarketplaceSourceAllowed`, `core/trust.zig` (gap 06).

No earlier *parity phase* is a hard blocker; the prerequisites are all merged subsystems.

**Effort.** Roughly 7 in-scope gaps. Estimated size: 2x L (gaps 03, 05), 4x M (gaps 01, 02, 04, 07), 1x S (gap 06), plus 1 partial M (gap 12 version derivation). Two gaps (08, 11) are documented deviations; gaps 09 and 10 are low-value lifecycle features kept in scope but deferred to the tail.

## Scope split

| Decision | Gap(s) | Reason |
|---|---|---|
| IN-SCOPE - build | plugins-01 | Per-plugin enable/disable is the single biggest functional gap; everything else (policy, dependency demotion, hot reload) keys off `enabledPlugins`. Highest severity. |
| IN-SCOPE - build | plugins-02 | Wiring plugin manifest hooks into the real `hook_event`/`hook_matcher` pipeline removes the duplicate bespoke runner and unlocks all 26 events. |
| IN-SCOPE - build | plugins-03 | Plugins providing MCP servers is a core extension point. The .mcpb/DXT *bundle download/extract* sub-feature is partly out of scope (see deviations); the manifest `mcpServers` merge is in scope. |
| IN-SCOPE - build | plugins-04 | Plugins providing subagents mirrors the already-shipped plugin-skills loader; small, self-contained. |
| IN-SCOPE - build | plugins-05 | Dependency resolution (closure, cycles, cross-marketplace block, reverse-dependent warning, demote-on-load) is a security boundary and correctness feature. |
| IN-SCOPE - build | plugins-06 | Trust disclaimer copy is trivial (S) and a real UX/compliance gap. |
| IN-SCOPE - build | plugins-07 | Managed-settings per-plugin force-disable is an enterprise control; zcode's enterprise-first posture makes this worth the M. |
| IN-SCOPE - build (tail) | plugins-09 | Delisting detection is security hygiene; cheap once gap 01 + a catalog `deleted` flag exist. Lower priority. |
| IN-SCOPE - build (tail) | plugins-10 | Background autoupdate + up-to-date detection; depends on version derivation (gap 12). Lower priority. |
| IN-SCOPE - partial | plugins-12 | Version derivation (git-SHA chain for cache keying) is the real gap; validation + headless install already exist. |
| OUT-OF-SCOPE - document | plugins-08 | Official Anthropic marketplace startup auto-install depends on an Anthropic-hosted GCS bucket + the `github.com/anthropics` official repo. Cloud-only first-party endpoint. A local stub seeding a default source row is low-value. |
| OUT-OF-SCOPE - document (partial) | plugins-11 | Interactive Ink browse/discover/manage TUIs and hosted install-counts/recommendation metrics. zcode is CLI-first with no Ink framework; install counts need a hosted metrics endpoint. The local browse/list parts already exist. |

## Gaps covered

| id | title | severity | size | our current state |
|---|---|---|---|---|
| plugins-01 | Per-plugin enable/disable persisted in settings | high | M | `enabled` derived only from trust_status; no enable/disable verbs; no `enabledPlugins` map. |
| plugins-02 | Plugins provide hooks to the running session | medium | M | Bespoke 5-event subprocess runner in `plugins.zig`; not wired into the 26-event `hook_event`/`hook_matcher` engine. |
| plugins-03 | Plugins provide MCP servers (+ .mcpb/DXT, user config) | medium | L | No `mcpServers` manifest field; MCP and plugins are fully separate systems. |
| plugins-04 | Plugins provide subagents/agents | medium | M | Plugin skills supported; no plugin agents loader; `PluginSpec` has no `agents`. |
| plugins-05 | Dependency resolution (closure, cycles, cross-mkt block, reverse-dependent) | medium | L | No `dependencies` field anywhere; install is single-entry; uninstall warns nothing. |
| plugins-06 | Plugin trust warning text before install/update/use | low | S | Policy gating + sha256 + workspace trust present; no human-readable disclaimer copy. |
| plugins-07 | Plugin policy: managed-settings force-disable | low | M | URL-prefix marketplace policy present; no per-plugin-id `policySettings.enabledPlugins[id]===false` chokepoint. |
| plugins-09 | Plugin delisting detection + auto-uninstall | low | M | `refreshSources` caches catalogs; no installed-vs-catalog comparison, no flagging. |
| plugins-10 | Background plugin autoupdate | low | M | Manual `update` (uninstall+reinstall); no `autoUpdate` flag, no version compare, no scheduler. |
| plugins-12 | Version calculation (git-SHA chain) | low | M | Single `"0.1.0"` fallback; validation + headless install already present. Only git-SHA derivation missing. |

## Implementation tasks

> Conventions for every task below: new logic lives in `core/` as deep modules; every new `.zig` file MUST be registered in the `src/main.zig` comptime `_ = @import(...)` block (see lines 42-118 for the `core/` cluster) so its tests compile; all source imports use `@import("zcode_runtime")` for `rt.io`/`rt.gpa`, never relative runtime paths; use `core/std_io.zig` `StringBuilder` for output, `core/clock.zig` for time, never `std.time.*`; tests run under `tools/test_runner.zig` and may use `core/test_helpers.zig` `tmpDirCwd`/`tmpDirPath` (never pass `"."`).

---

### Task 17.1 - Per-plugin enable/disable persisted in settings (plugins-01)

**Goal.** Add `enable`, `disable`, and `disable-all` operations that persist a `name@marketplace -> bool` map at user/workspace scope, and make `plugins.zig:list` consult that map instead of deriving `enabled` purely from trust.

**Reference behavior.**
- `services/plugins/pluginCliCommands.ts:195-293` - `enablePlugin`/`disablePlugin`/`disableAllPlugins` CLI verbs accept `plugin` (name or `name@marketplace`) and optional `scope`, calling the underlying ops and logging telemetry.
- `utils/plugins/dependencyResolver.ts:275-283` - `getEnabledPluginIdsForScope` reads `getSettingsForSource(scope).enabledPlugins`, treating both `=== true` and array (version-constraint) values as enabled.
- `plugins/builtinPlugins.ts:71-77` - builtin plugins read the same `enabledPlugins` map.

**Target Zig files.**
- New: `core/plugin_settings.zig` (deep module: read/write the `enabledPlugins` map at user + workspace scope, resolve effective enabled state).
- Edit: `core/plugins.zig` - `PluginSpec.enabled` becomes a function of the settings map *and* trust, not trust alone.
- Edit: `cli/args.zig` - add `plugins_enable`, `plugins_disable`, `plugins_disable_all` to `CommandKind` (lines 44-49 cluster) and parse the verbs + optional `--scope`.
- Edit: `session_cmds.zig` and/or `repl_commands.zig` - dispatch the new verbs (mirror `plugins_install`/`plugins_uninstall`).
- Register `core/plugin_settings.zig` in `src/main.zig` comptime block.

**Approach.**
1. Decide the on-disk format. zcode persists user config as TOML lines via `config_parse.zig:persistUserConfigField`, which is key=value and cannot hold a nested map. The clean fit is a dedicated JSON file per scope: `~/.zcode/plugin_settings.json` (user) and `<workspace>/.zcode/plugin_settings.json` (workspace), shaped `{"enabledPlugins": {"foo@local": true, "bar@market": false}}`. This matches the reference's per-source `enabledPlugins` and avoids overloading the TOML config. Use `paths.resolve` for the user path and `paths.workspacePathAlloc(allocator, cwd, "plugin_settings.json")` for workspace.
2. In `plugin_settings.zig`, implement:
   - `pub fn effectiveEnabled(allocator, cwd, plugin_id: []const u8, scope: PluginScope, trust_default: bool) !bool` - workspace scope overrides user scope; `true`/array => enabled, `false` => disabled, absent => fall back to `trust_default` (preserve current behavior for un-toggled plugins).
   - `pub fn setEnabled(allocator, scope, plugin_id, enabled: bool) !void` - read-modify-write the scope's JSON via `parse_helpers.parseJsonBounded`, mutate `&parsed.value.object` *by pointer* (0.16 footgun: a value copy desyncs the entries pointer on realloc - see CLAUDE.md), atomically write via tmp+rename (mirror `persistUserConfigField:976`).
   - `pub fn disableAll(allocator, cwd, scope) !usize` - enumerate installed plugins via `plugins.list`, set each to `false`, return count.
3. In `plugins.zig:parseManifestFile` and `appendPluginsFromRoot`, replace the raw `enabled` parameter with a call to `plugin_settings.effectiveEnabled(..., trust_default = enabled)` keyed on the plugin's `name@marketplace` id. Marketplace name derivation: for a user/workspace plugin installed locally with no marketplace, use `name@local` (matches reference `@inline` sentinel intent); for plugins installed from a remote source, key on `name@<source-name>`. Store the derived id on `PluginSpec` as a new `plugin_id` field so dependency resolution (Task 17.5) and policy (Task 17.7) reuse it.
4. Wire the three CLI verbs. `disable-all` calls `disableAll`. `enable`/`disable` resolve scope (default: workspace if a workspace `.zcode` exists, else user - mirror "most specific scope" from the reference docstring).

**Acceptance criteria.**
- Write a test that installs a plugin into a tmp `.zcode/plugins/demo`, calls `setEnabled(.user, "demo@local", false)`, then asserts `plugins.list` returns `demo` with `enabled == false`, and `renderList` shows `status=disabled`.
- Write a test that `setEnabled(.user, ..., false)` then `setEnabled(.user, ..., true)` round-trips, and the JSON file contains exactly one entry (no duplication on re-write).
- Write a test that a workspace `false` overrides a user `true` for the same id.
- Write a test that an untoggled plugin still honors `trust_default` (user plugin enabled, untrusted-workspace plugin disabled).
- Write a test that `disableAll` flips every installed plugin and `enable` re-enables a single one.

**Test strategy.** Pure-tmpdir tests under `tools/test_runner.zig` using `test_helpers.tmpDirCwd`. No subprocess needed. Assert JSON file contents with `std.json` round-trip.

**Risk + 0.16 footguns.** ObjectMap pointer-vs-value after parse (take `&parsed.value.object`). `readFileAlloc(.limited(N))` returns `error.StreamTooLong` not `FileTooBig`. Atomic write must `errdefer deleteFile(tmp)`. Scope-precedence ordering must match the reference (workspace beats user) or dependency demotion later reads the wrong set.

**Size.** M.

---

### Task 17.2 - Plugins provide hooks to the running session (plugins-02)

**Goal.** Convert an enabled plugin's manifest hook definitions into `hook_matcher`-style matchers across the full `hook_event.Event` enum and merge them into the engine, retiring the bespoke 5-event subprocess runner as the *only* plugin-event path.

**Reference behavior.** `utils/plugins/loadPluginHooks.ts:28-90` - `convertPluginHooksToMatchers` builds a `Record<HookEvent, PluginHookMatcher[]>` from `plugin.hooksConfig`, stamping each matcher with `pluginRoot`/`pluginName`/`pluginId` context, then `loadPluginHooks` merges across all enabled plugins and does an atomic `clearRegisteredPluginHooks()` + `registerHookCallbacks()`. `schemas.ts:323-372` defines the manifest `hooks` shape (events -> matchers -> hooks).

**Target Zig files.**
- Edit: `core/plugins.zig` - extend manifest parse to read an optional `hooks` object (the reference shape) in addition to the existing flat `events` array. Keep `events` working for back-compat.
- New: `core/plugin_hooks.zig` - `pub fn collect(allocator, cwd) ![]hook_matcher.PluginMatcher` returning matchers stamped with plugin context, gated on `enabled`.
- Edit: `core/hooks.zig` - in `run` (line 132), after the existing user/workspace hooks and `runConfiguredUser`, fold in `plugin_hooks.collect` matchers for the requested event via the existing `hook_matcher` matching logic. Reuse `toEngineEvent` (line 194) to map the live tool event to `hook_event.Event`.
- Register `core/plugin_hooks.zig` in `src/main.zig`.

**Approach.**
1. Decide the manifest shape. Reference uses a `hooks` object keyed by event name, each value an array of `{matcher, hooks:[...]}`. zcode's manifest currently has a flat `events: ["pre-tool-use", ...]` array driving the subprocess runner. Keep both: parse `hooks` if present into a `[]PluginHookMatcher` (event + optional tool matcher + command/entrypoint), and keep `events` for the legacy subprocess path. Map event names through a `parseHookEvent` that covers the full `hook_event.Event` enum (26 events), not just the 5 in `PluginEvent`.
2. In `plugin_hooks.zig:collect`, iterate `plugins.list`, skip `!enabled`, and for each plugin emit matchers carrying `plugin_root`, `plugin_name`, `plugin_id`. The command to run is resolved relative to `plugin.root_path` with the same traversal guard as `resolveEntrypoint` (`plugins.zig:450`).
3. In `hooks.zig:run`, for the current `ctx.event`, after running file/config hooks, run matching plugin matchers via subprocess using the *same hardened env-map allowlist* as `plugins.zig:runSingle:390-422` (this is a security invariant - do not forward provider API keys). Honor `blocked` exit codes identically.
4. Keep `plugins.zig:run` as a thin compatibility shim for the 5 legacy events its call sites use (`agent_tools.zig:758,819`, `session_mgmt.zig:193`, `repl_commands.zig:1319`), but have it delegate to the unified matcher path so there is one execution engine, not two.

**Acceptance criteria.**
- Write a test that a plugin manifest with `"hooks": {"PreToolUse": [{"matcher":"Bash","hooks":[{"command":"./h.sh"}]}]}` produces exactly one matcher from `plugin_hooks.collect` for the `pre_tool_use` event with a `Bash` tool matcher, and zero for other tools.
- Write a test that a disabled plugin contributes zero matchers.
- Write a test that the plugin hook subprocess receives the hardened env map (no `ANTHROPIC_API_KEY`) by having the script echo the env and asserting the key is absent. (Reuse the pattern from existing plugin runSingle tests.)
- Write a test that a non-zero exit from a plugin `PreToolUse` hook surfaces as `blocked == true` through `hooks.run`.

**Test strategy.** tmpdir + a small shell entrypoint written into the plugin dir; run via `std.process.run`. For env-leak assertion, write a script that prints `${ANTHROPIC_API_KEY:-MISSING}` and assert `MISSING`.

**Risk + 0.16 footguns.** `Child.kill(io)` reaps internally - do not `wait()` after. Tool-args env cap (16 KB) and stdout/stderr limits must match `runSingle`. The atomic clear-then-register concern from the reference (gh-29767) is N/A here because zcode re-reads matchers on every `hooks.run` call (no persistent registry), which sidesteps the stale-hook bug entirely - note this as a deliberate simplification.

**Size.** M.

---

### Task 17.3 - Plugins provide MCP servers (plugins-03)

**Goal.** Let an enabled plugin declare `mcpServers` in its manifest and merge those into the MCP server set the session sees, so a plugin can ship a stdio/HTTP MCP server without a separate `mcp add`.

**Reference behavior.** `utils/plugins/mcpPluginIntegration.ts:1-90` merges `plugin.mcpServers` into the session, expanding env vars and substituting plugin/user-config variables. `utils/plugins/mcpbHandler.ts` (31 KB) downloads/extracts `.mcpb` DXT bundles and prompts for user config via `/plugin`.

**Scope note.** In scope: manifest `mcpServers` merge for stdio/HTTP servers whose command/args are already on disk in the plugin root. Out of scope (documented): `.mcpb`/DXT bundle *download + extraction* and interactive user-config prompting (those need the Ink `/plugin` menu and a hosted bundle format). zcode will *parse and reject* `.mcpb` sources with a clear "not supported" message rather than silently ignoring them.

**Target Zig files.**
- Edit: `core/plugins.zig` - parse an optional `mcpServers` object into a new `[]PluginMcpServer` field on `PluginSpec` (`{name, transport, command, args, url, env}`), with the same path-traversal guard for any `command` resolved against `root_path`.
- New: `core/plugin_mcp.zig` - `pub fn collect(allocator, cwd) ![]mcp.Server` returning servers from all enabled plugins, namespaced as `<plugin_name>__<server_name>` to avoid clobbering user-registered servers.
- Edit: `mcp/client.zig` - where `readServers` loads the registry (around line 1987-2035), fold in `plugin_mcp.collect` so listing/connecting sees plugin servers. Keep them session-only (do not write them into the persisted registry file).
- Register `core/plugin_mcp.zig` in `src/main.zig`.

**Approach.**
1. Parse `mcpServers` from the manifest. Reuse the existing `getString`/array-parse helpers; gracefully skip malformed entries (consistent with `parseCommands:362`).
2. Resolve any stdio `command` against `plugin.root_path` with `resolveEntrypoint`-style guards; absolute commands on `$PATH` (e.g. `node`, `python`) are allowed but a relative path containing `..` is rejected.
3. In `plugin_mcp.collect`, skip `!enabled` plugins, namespace server names, and dedupe against user-registered names (user-registered wins; log a debug line on conflict).
4. Splice into the server set at read time, not persistence time, so uninstalling/disabling a plugin removes its servers with no registry mutation. Plugins with `.mcpb` sources: emit a one-time stderr notice `mcp: plugin '<name>' ships an .mcpb bundle, which is not supported; declare an mcpServers stdio/http entry instead` and skip.

**Acceptance criteria.**
- Write a test that a plugin manifest with `"mcpServers": {"db": {"transport":"stdio","command":"./srv.sh"}}` makes `plugin_mcp.collect` return one server named `demo__db` with command resolved under the plugin root.
- Write a test that a disabled plugin contributes zero servers.
- Write a test that a plugin server name colliding with a user-registered server does not override the user entry.
- Write a test that an `mcpServers` entry with `command: "../escape.sh"` is rejected (returns `error.InvalidPluginEntrypoint` or is skipped, your choice - assert it does not appear).

**Test strategy.** tmpdir plugin dir + a stub registry file; call `plugin_mcp.collect` and the splice point in `mcp/client.zig` directly. No live MCP connection needed - assert on the parsed `Server` structs.

**Risk + 0.16 footguns.** ObjectMap pointer after parse. Env-var expansion: if you support `${VAR}` in server env, gate it behind the same allowlist mentality (do not blindly expand from the full parent env). Namespacing collision with the existing tool-name-map (`core/tool_name_map.zig`) - confirm the `__` separator does not break MCP tool routing.

**Size.** L.

---

### Task 17.4 - Plugins provide subagents/agents (plugins-04)

**Goal.** Load agent definitions from an enabled plugin's `agents/` subdirectory, exactly mirroring the already-shipped `skills.zig:appendPluginSkills` pattern.

**Reference behavior.** `utils/plugins/loadPluginAgents.ts` walks a plugin's `agents/` dir (and/or a manifest `agents` reference) via `walkPluginMarkdown`, parsing frontmatter into `AgentDefinition`s stamped with plugin context. `schemas.ts:458-470` defines the manifest `agents` field.

**Target Zig files.**
- Edit: `core/agents.zig` - add `appendPluginAgents(allocator, &out, cwd)` and call it from `list` (line 86-102) after `appendFromDir(workspace)`, then re-sort. This is the direct analog of `skills.zig:193-203`.
- Edit: `core/plugins.zig` - no new manifest field strictly required if agents are discovered by directory (`agents/*.md`); add an optional manifest `agents` path override only if the reference's directory default is insufficient (it is not - directory discovery covers the common case).
- No new file needed; reuse `agents.zig` `appendFromDir` machinery.

**Approach.**
1. In `agents.zig:appendPluginAgents`, iterate `plugins.list(allocator, cwd)`, skip `!enabled`, join `plugin.root_path` + `"agents"`, and call the existing `appendFromDir(allocator, &out, agents_dir, .plugin)`. This requires adding a `.plugin` variant to the agent `Scope` enum (mirror `SkillScope.plugin`).
2. Stamp each loaded agent with plugin provenance in its source label so `agents show` reveals which plugin provided it.
3. De-dup against builtin/user/workspace agents by name with the existing precedence (later scopes do not override earlier - or match the reference's namespacing if `agents.zig` already namespaces).

**Acceptance criteria.**
- Write a test that a plugin with `agents/reviewer.md` (valid frontmatter) makes `agents.list` include `reviewer` with scope `.plugin`.
- Write a test that a disabled plugin's agents are absent from `agents.list`.
- Write a test that a plugin agent name colliding with a builtin does not crash and honors the documented precedence.

**Test strategy.** tmpdir plugin dir with an `agents/*.md` file; call `agents.list` and assert membership + scope. Reuse the existing agents test scaffolding.

**Risk + 0.16 footguns.** `openDir` on a missing `agents/` dir must be tolerated (return on `FileNotFound`/`NotDir`/`AccessDenied`, exactly as `skills.zig:appendFromRoot:211-216`). Re-sorting after append must keep `lessThan` stable.

**Size.** M.

---

### Task 17.5 - Dependency resolution (plugins-05)

**Goal.** Add a `dependencies` concept to plugin manifests and marketplace entries, with an install-time transitive-closure walk (DFS + cycle detection + cross-marketplace block), a load-time fixed-point demotion check, and a reverse-dependent warning on uninstall/disable.

**Reference behavior.** `utils/plugins/dependencyResolver.ts:38-306`:
- `qualifyDependency` (38-46) normalizes bare deps to `name@marketplace`, inheriting the declaring plugin's marketplace.
- `resolveDependencyClosure` (95-159) DFS, skips already-enabled deps (never the root), blocks cross-marketplace unless allowlisted, returns `cycle`/`not-found`/`cross-marketplace` errors.
- `verifyAndDemote` (177-234) load-time fixed-point loop demoting plugins with unsatisfied deps.
- `findReverseDependents` (244-263) lists enabled plugins that depend on a target.

**Target Zig files.**
- New: `core/plugin_deps.zig` - pure functions, no I/O, direct port: `qualifyDependency`, `resolveDependencyClosure`, `verifyAndDemote`, `findReverseDependents`. Take a `lookup` callback (fn pointer or vtable) so tests can stub the marketplace.
- Edit: `core/plugins.zig` - add `dependencies: []const []const u8` to `PluginSpec`, parsed from a manifest `dependencies` array (reuse `parseStringArray:324`).
- Edit: `core/marketplace.zig` - add `dependencies` to `Entry` (parse in `appendCatalogEntriesFromBytes:496-532`); make `install:186` resolve the closure and install each member; make `uninstall:215` call `findReverseDependents` and append the warning suffix to its result string.
- Edit: `core/plugins.zig:list` - after building the list, run `verifyAndDemote` and clear `enabled` on demoted plugins (session-local, do NOT write settings - matches reference docstring at dependencyResolver.ts:11).
- Register `core/plugin_deps.zig` in `src/main.zig`.

**Approach.**
1. Port the four pure functions first (no marketplace coupling). Represent `PluginId` as a `[]const u8` `name@marketplace` string; reuse the `plugin_id` field added in Task 17.1.
2. `resolveDependencyClosure`: implement the DFS with an explicit `visited` set, a `stack` for cycle detection (`stack.includes(id)` => cycle), and the cross-marketplace block running *after* the already-enabled check (security ordering matters - line 117-132). Cross-marketplace allowlist comes from the *root* marketplace only (no transitive trust).
3. `verifyAndDemote`: fixed-point `while (changed)` loop; track `enabledByName` as a multiset for bare-dep (`@local`/inline) matching.
4. Wire into `marketplace.install`: resolve closure against the catalog (`lookup` = find entry by id), install each member, and append `formatDependencyCountSuffix` to the success message.
5. Wire into `marketplace.uninstall` and the `disable` op (Task 17.1): call `findReverseDependents` against the enabled set and append `warning: required by X, Y` (use plain hyphens in the copy, not the em-dash style the reference uses - CLAUDE.md rule).

**Acceptance criteria.**
- Write a test for `resolveDependencyClosure`: A depends on B depends on C, none enabled => closure `[C, B, A]` (post-order).
- Write a test: A -> B -> A cycle => `cycle` result with the chain.
- Write a test: A (mkt1) depends on B (mkt2), not allowlisted => `cross-marketplace` error; with mkt2 in the root's allowlist => resolves.
- Write a test: already-enabled dep is skipped but the root is never skipped.
- Write a test for `verifyAndDemote`: enabling A whose dep B is disabled demotes A; a fixed-point case where demoting A cascades to demote C-depends-on-A.
- Write a test for `findReverseDependents`: uninstalling B returns `[A]` when A depends on B; the uninstall result string contains `required by A`.

**Test strategy.** Pure unit tests for the four functions with stubbed `lookup` (an in-memory map). Integration test for the install/uninstall wiring using a tmpdir catalog.

**Risk + 0.16 footguns.** Recursion depth on adversarial deep chains - the reference uses recursion; cap depth or use an explicit stack to avoid stack overflow on a malicious manifest. Cross-marketplace ordering bug (block must run after already-enabled). Demotion must be session-local (no settings write) or it fights Task 17.1.

**Size.** L.

---

### Task 17.6 - Plugin trust warning text before install/update/use (plugins-06)

**Goal.** Render the fixed legal disclaimer (plus optional policy-supplied custom message) before a plugin install/update completes.

**Reference behavior.** `commands/plugin/PluginTrustWarning.tsx:25` renders fixed copy ("Make sure you trust a plugin ... Anthropic does not control what MCP servers ...") plus an optional custom message from `utils/plugins/marketplaceHelpers.ts getPluginTrustMessage`.

**Target Zig files.**
- New (or fold into `core/marketplace.zig`): `pub fn trustWarning(allocator, custom: ?[]const u8) ![]u8` returning the disclaimer text.
- Edit: `core/marketplace.zig:install:186` and `update:204` - prepend/print the warning before performing the install (gate behind a `--yes`/non-interactive skip so headless/CI installs are not blocked; mirror that the reference shows it interactively).

**Approach.**
1. Author the fixed copy with plain hyphens only (no em/en dashes - CLAUDE.md). Keep it provider-neutral but faithful in intent: warn that plugins run code and MCP servers locally, that zcode does not vet third-party plugin/MCP behavior, and that the user is responsible for trusting the source.
2. Source the optional custom message from the marketplace source registry (add an optional `trust_message` to a source row if present) or leave the hook for later.
3. Print to stderr (so it does not pollute stdout JSON) before install side effects. In a TTY, this is a visible warning; in `--yes`/non-interactive mode, print once and proceed.

**Acceptance criteria.**
- Write a test that `trustWarning(null)` contains the key phrases ("trust", "MCP", "runs code" or equivalent) and contains no `\u2014`/`\u2013`.
- Write a test that `trustWarning("ORG: only approved plugins")` includes the custom message.
- Write a test that `install` of a tmpdir plugin emits the warning to stderr exactly once.

**Test strategy.** String-content unit tests; capture stderr in the install path test via the existing stderr-capture helpers if present, else assert the function output and that install calls it.

**Risk + 0.16 footguns.** Do not block headless installs on the warning (would break CI). Scan the copy for long dashes before committing (CLAUDE.md).

**Size.** S.

---

### Task 17.7 - Plugin policy: managed-settings force-disable (plugins-07)

**Goal.** Honor an org-managed `policySettings.enabledPlugins[id] === false` that blocks install and enable at every scope, and expose the set of managed plugin names.

**Reference behavior.** `utils/plugins/pluginPolicy.ts:17-20` - `isPluginBlockedByPolicy(id)` returns true when `policySettings.enabledPlugins[id] === false`. `utils/plugins/managedPlugins.ts:8-31` - `getManagedPluginNames` returns the set of `name@marketplace` boolean-keyed names.

**Target Zig files.**
- New: `core/plugin_policy.zig` - `pub fn isBlockedByPolicy(allocator, plugin_id) !bool` and `pub fn managedPluginNames(allocator) ![]const []const u8`, reading a managed policy file.
- Edit: `core/config.zig` / managed settings source - zcode already has `managed_locked_keys` and `isManagedLocked` (config.zig:441) and `managed_config_sources`. Decide the managed source: read an `enabledPlugins` map from the managed-settings JSON the control plane already syncs (`control_plane_managed_settings_sync`). If no managed-plugins concept exists in the managed file yet, add an `enabledPlugins` section there.
- Edit: `core/marketplace.zig:install` (chokepoint) and the `enable` op (Task 17.1) - call `isBlockedByPolicy` first and refuse with `error.PluginBlockedByPolicy` if `false`.
- Register `core/plugin_policy.zig` in `src/main.zig`.

**Approach.**
1. Locate where zcode loads managed settings (the same source feeding `managed_locked_keys`). Read `enabledPlugins` from it. A plugin id mapping to `false` => blocked; mapping to `true` => managed-protected (cannot be disabled by the user, parallels reference's protected names).
2. `managedPluginNames` returns only boolean-keyed `name@marketplace` ids (skip array/legacy forms - managedPlugins.ts:18).
3. Gate: `marketplace.install` and `enable` consult `isBlockedByPolicy` before any side effect; `disable` consults `managedPluginNames` and refuses to disable a managed-protected plugin.
4. `plugins.zig:list` should mark policy-blocked plugins as `enabled == false` regardless of the user's `enabledPlugins` map (policy wins over user/workspace scope).

**Acceptance criteria.**
- Write a test that with a managed settings file containing `{"enabledPlugins":{"evil@market":false}}`, `isBlockedByPolicy("evil@market")` is true and `install` of it returns `error.PluginBlockedByPolicy`.
- Write a test that the user `enable`-ing a policy-blocked plugin is refused.
- Write a test that `managedPluginNames` returns `{evil}` (name only) and ignores array-form entries.
- Write a test that a policy-blocked plugin shows `enabled == false` in `plugins.list` even when the user's `enabledPlugins` has it `true`.

**Test strategy.** tmpdir with a managed-settings JSON pointed at via the managed source mechanism; call the policy functions and the install/enable chokepoints. Use `test_helpers.tmpDirCwd`.

**Risk + 0.16 footguns.** Precedence: policy must beat both user and workspace `enabledPlugins`. Do not confuse `managed_locked_keys` (config-key locking) with per-plugin policy - they are separate mechanisms that happen to share a file. ObjectMap pointer after parse.

**Size.** M.

---

### Task 17.8 - Version derivation for cache keying (plugins-12, partial)

**Goal.** Replace the single `"0.1.0"` manifest fallback with the reference's priority chain: manifest version > marketplace-provided version > git short-SHA (with git-subdir path hash) > `unknown`, so cache keys differ across versions.

**Reference behavior.** `utils/plugins/pluginVersioning.ts:36-158` - `calculatePluginVersion` priority chain; `getVersionFromPath`/`isVersionedPath` parse `.../cache/<mkt>/<plugin>/<version>/`.

**Target Zig files.**
- New: `core/plugin_version.zig` - `calculateVersion(allocator, manifest_version, provided_version, install_path, git_sha) ![]u8` and `versionFromPath(install_path) ?[]const u8`.
- Edit: `core/plugins.zig:parseManifestFile:301` - call into the chain instead of `orelse "0.1.0"`.
- Edit: `core/marketplace.zig` install path - key the cache dir on the derived version.
- Register in `src/main.zig`.

**Approach.**
1. Port the chain. For git SHA, shell `git -C <dir> rev-parse HEAD` via `std.process.run` (mirror existing git helpers); take first 12 chars. For git-subdir, append `-<sha256(normPath)[0..8]>` with the exact normalization the reference documents (backslash->slash, strip leading `./`, strip trailing `/`).
2. Use `core/rng.zig` only if needed; sha256 comes from `std.crypto.hash.sha2.Sha256`.

**Acceptance criteria.**
- Write a test that manifest version wins over provided version.
- Write a test that with no manifest/provided version and a git dir, the 12-char short SHA is returned.
- Write a test that git-subdir produces `<sha>-<8hexpathhash>` with the documented normalization (assert against a known input).
- Write a test that `versionFromPath(".../cache/m/p/1.2.3/")` returns `1.2.3` and a non-versioned path returns null.

**Test strategy.** Pure unit tests; for the git-SHA branch, init a tmp git repo via `std.process.run` and assert the prefix length, or stub `git_sha`.

**Risk + 0.16 footguns.** `std.process.run` for git: `Child.init` is gone - use `std.process.run`. Normalization must match byte-for-byte or cache keys diverge from any future official squashfs. Keep `"0.1.0"` only as the final pre-`unknown` fallback if you want to preserve current display, but prefer `unknown` to match the reference.

**Size.** M.

---

### Task 17.9 - Delisting detection + auto-uninstall (plugins-09, tail)

**Goal.** On `refreshSources`, compare installed user-scope plugins against the refreshed catalogs; when a source's catalog marks an entry deleted (or it vanishes) and the source opts into `forceRemoveDeletedPlugins`, auto-uninstall and record it flagged.

**Reference behavior.** `utils/plugins/pluginBlocklist.ts:34-127` - `detectAndUninstallDelistedPlugins`; `pluginFlagging.ts` records flags.

**Target Zig files.**
- New: `core/plugin_flagging.zig` - persist a `flagged` list (`~/.zcode/plugins/flagged.json`).
- Edit: `core/marketplace.zig:refreshSources:350` - after refreshing, run detection; add an optional `force_remove_deleted` flag to a source row and a `deleted: true` per-entry catalog flag.
- Register in `src/main.zig`.

**Approach.** After `refreshOneSource`, list installed plugins (`plugins.list`), and for each whose source advertises deletion (entry absent or `deleted:true`) and whose source has `force_remove_deleted`, call `marketplace.uninstall` and append to the flagged store. Print a notice.

**Acceptance criteria.**
- Write a test that an installed plugin whose refreshed catalog marks it `deleted:true` under a `force_remove_deleted` source is uninstalled and appears in `flagged.json`.
- Write a test that without `force_remove_deleted` the plugin is *not* removed (only flagged or left alone - match reference).

**Test strategy.** tmpdir source + catalog + installed plugin dir; mutate the catalog to mark deleted; call `refreshSources`; assert the plugin dir is gone and the flag persisted.

**Risk + 0.16 footguns.** `deleteTree` on missing target returns `FileNotFound` or `NotDir` per platform (already handled in `uninstall:229`). Never auto-remove workspace-scope plugins (user-managed). Be conservative: only user-scope, only when explicitly opted in.

**Size.** M.

---

### Task 17.10 - Background plugin autoupdate (plugins-10, tail)

**Goal.** Add an `autoUpdate` flag to marketplace entries/sources, version-compare installed vs catalog, and update in the background where opted in, with an up-to-date short-circuit.

**Reference behavior.** `utils/plugins/pluginAutoupdate.ts:45-150` updates from `autoUpdate`-enabled marketplaces, fires notifications, tracks updated names; `pluginVersioning.ts` provides the `alreadyUpToDate` short-circuit.

**Target Zig files.**
- Edit: `core/marketplace.zig:Entry` - add `auto_update: bool`; parse in catalog reader.
- New: `core/plugin_autoupdate.zig` - `checkAndApply(allocator, cwd) ![]const []const u8` returning updated names; uses `plugin_version` (Task 17.8) to compare.
- Edit: integrate into the existing background agent (`kairos.zig`) self-check loop *only if* policy allows (`kairos_policy.zig` DEFAULT_ALLOWLIST currently excludes plugin updates - add an opt-in entry, gated, not default-on).
- Register in `src/main.zig`.

**Approach.** For each installed plugin from an `autoUpdate` source, compare installed version (`versionFromPath` or manifest) to the catalog version; if newer, run `marketplace.update`; collect names; short-circuit when equal. Emit an `os_notify` (`core/os_notify.zig`) notification listing updated names. Keep it opt-in and off by default to match zcode's conservative posture.

**Acceptance criteria.**
- Write a test that an installed plugin at v1 with an `auto_update` catalog entry at v2 is updated and its name returned; at v2==v2 it is skipped (up-to-date short-circuit).
- Write a test that a non-`auto_update` source is never touched.

**Test strategy.** tmpdir source/catalog with version fields; call `checkAndApply`; assert update happened and the returned name list.

**Risk + 0.16 footguns.** Background scheduling must not run in tests (gate behind explicit call). Version comparison must be careful with `unknown`/non-semver values - treat unknown as "do not auto-update". Do not enable in `kairos` default allowlist without explicit user opt-in.

**Size.** M.

---

## Documented deviations

### plugins-08 - Official Anthropic marketplace startup auto-install (OUT OF SCOPE)

`checkAndInstallOfficialMarketplace` (`utils/plugins/officialMarketplaceStartupCheck.ts:147-439`) fires on startup, checks policy/git availability, tries a GCS mirror then a git fallback to the `github.com/anthropics` official repo, with exponential-backoff retry state in `GlobalConfig` and a `CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL` opt-out.

**Why out of scope.** It depends on an Anthropic-hosted GCS bucket and the first-party `anthropics` GitHub repo - cloud-only endpoints zcode does not and should not assume. zcode's marketplace is intentionally user-managed (`marketplace add <name> <url> <sha256>`) with mandatory sha256 integrity, which is a *stronger* trust posture for remote sources than a silent first-party auto-install.

**Local stub worth doing.** None of real value. Optionally document in `wiki/` that zcode deliberately has no auto-seeded official source and that operators add their own. Do not seed a default source row pointing at a hypothetical endpoint - it would be dead config. Keep `core/backoff.zig` available for any future opt-in remote refresh, but do not wire it here.

### plugins-11 - Interactive browse/discover/manage TUIs + install counts/recommendations (PARTIAL, mostly OUT OF SCOPE)

The reference ships large Ink TUIs (`BrowseMarketplace.tsx` 119 KB, `DiscoverPlugins.tsx` 106 KB, `ManagePlugins.tsx` 321 KB) plus install-count and hint/LSP recommendation engines.

**Why out of scope.** zcode is CLI-first and has no Ink framework (explicitly noted in `repl_commands.zig`). Install counts and recommendation ranking lean on a hosted metrics endpoint zcode does not run.

**What is already covered / worth doing locally.** Non-interactive browse/list/show already exist (`marketplace.zig:renderList/renderDetail`, the `/marketplace` and `/plugins` REPL commands) with `featured` metadata and sha256-verified badges. Hint extraction exists (`core/hint_protocol.zig`). The legitimate small local gap is plain-text **pagination** for long catalogs (offset/limit on `renderList`) - worth a tiny follow-up if catalogs grow, but not required for parity. Document that the interactive TUI and hosted metrics are intentionally omitted.

## Verification

Per `CLAUDE.md` (project), after each task and at phase end:

1. Bump the patch version in `build.zig.zon` (`.version = "X.Y.Z"`) for the change set. `build.zig` appends the git short-hash automatically - do not edit `computeVersionString`.
2. Build and run the full test suite (custom runner prints `RUN: <name>`):
   ```
   /Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build test
   ```
   Confirm all new `core/plugin_*.zig` tests pass and no regression in `plugins.zig`/`marketplace.zig`/`hooks.zig`/`agents.zig`/`skills.zig`.
3. Build the release binary and install it (fresh inode to preserve the ad-hoc signature - the macOS in-place `cp` footgun):
   ```
   /Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build -Doptimize=ReleaseFast
   rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode
   ```
4. Manual checks against the installed binary:
   - `zcode plugins list` shows `status=enabled/disabled` reflecting the new `enabledPlugins` map (Task 17.1).
   - `zcode plugins disable <name>` then `zcode plugins list` shows it disabled; `zcode plugins enable <name>` re-enables; `zcode plugins disable-all` flips all.
   - With a managed-settings file mapping a plugin id to `false`, `zcode plugins install <id>` is refused with a policy error (Task 17.7).
   - `zcode plugins install <id>` of a plugin with dependencies installs the closure and prints the `(+ N dependencies)` suffix; `zcode plugins uninstall <dep>` prints the `warning: required by ...` suffix (Task 17.5).
   - A plugin shipping `agents/*.md` shows up in `zcode agents list` with plugin scope (Task 17.4); a plugin `mcpServers` entry shows up in `zcode mcp list` namespaced (Task 17.3).
   - Installing a plugin prints the trust disclaimer to stderr with no em/en dashes (Task 17.6).
5. Scan all new copy strings and commit messages for `\u2014`/`\u2013` and replace with plain hyphens before committing (CLAUDE.md).
6. Update `wiki/` with the deviation decisions for plugins-08 and plugins-11 and any non-obvious footguns hit (ObjectMap pointer-after-parse, env-map allowlist invariant for plugin/hook subprocesses, session-local demotion not writing settings).

**Relevant files (absolute paths):**
- `/Users/example/Projects/zig-code/src/core/plugins.zig`
- `/Users/example/Projects/zig-code/src/core/marketplace.zig`
- `/Users/example/Projects/zig-code/src/core/hooks.zig`, `/Users/example/Projects/zig-code/src/core/hook_event.zig`, `/Users/example/Projects/zig-code/src/core/hook_matcher.zig`
- `/Users/example/Projects/zig-code/src/core/agents.zig`, `/Users/example/Projects/zig-code/src/core/skills.zig`
- `/Users/example/Projects/zig-code/src/core/config.zig`, `/Users/example/Projects/zig-code/src/core/config_parse.zig`
- `/Users/example/Projects/zig-code/src/mcp/client.zig`
- `/Users/example/Projects/zig-code/src/cli/args.zig`, `/Users/example/Projects/zig-code/src/session_cmds.zig`, `/Users/example/Projects/zig-code/src/repl_commands.zig`, `/Users/example/Projects/zig-code/src/session_mgmt.zig`, `/Users/example/Projects/zig-code/src/agent_tools.zig`
- `/Users/example/Projects/zig-code/src/main.zig` (comptime import block)
- New: `core/plugin_settings.zig`, `core/plugin_hooks.zig`, `core/plugin_mcp.zig`, `core/plugin_deps.zig`, `core/plugin_policy.zig`, `core/plugin_version.zig`, `core/plugin_flagging.zig`, `core/plugin_autoupdate.zig`
