# Phase 1: Foundations: settings.json layering, tool-name normalization, model aliases

## Overview

**What.** This phase builds the configuration and naming foundations that every
later parity phase depends on:

1. A multi-source `settings.json` loader with an ordered precedence chain
   (managed/policy, flag, user, project, local) that other subsystems read from
   (permissions, hooks).
2. A `permissions.{allow,deny,ask}` array loader (`settingsJsonToRules`
   equivalent) layered over those sources, with `allowManagedPermissionRulesOnly`
   restriction.
3. Hook config loading from the project/local/policy settings.json scopes (not
   just the single `~/.zcode/settings.json`).
4. `CLAUDE_*` hook/plugin environment variables (alias set alongside our existing
   `ZCODE_*`) plus the `CLAUDE_ENV_FILE` export-injection mechanism.
5. MCP tool-name normalization to the canonical `mcp__server__tool` underscore
   scheme, with `normalizeNameForMCP` and claude.ai-prefix underscore collapsing.
6. Model alias resolution (`opus`/`sonnet`/`haiku`/`best`/`opusplan`) and the
   `[1m]` long-context suffix.
7. An `availableModels` allowlist enforcement gate (`isModelAllowed`).
8. Per-model context-window resolution that honors the `[1m]` suffix.
9. A startup config-key migration framework (rename/relocate deprecated keys
   idempotently).

**Why.** zcode currently uses a bespoke TOML config stack
(`config.toml` + `settings.local.toml` + managed `policy.toml`) and a flat
TSV permission file (`~/.zcode/permissions/rules.tsv`). The reference project
uses a JSON `settings.json` layered across five sources, and reads permissions,
hooks, model allowlists, and env from those layers. Without the JSON layering and
the canonical `mcp__server__tool` naming, every downstream parity feature
(permission rule matching, hook merge precedence, MCP permission rules, model
governance) is built on the wrong substrate. This phase establishes the substrate
so phases that build on it (permissions-02 consumers, hooks-03 consumers,
mcp-10 permission keying) line up with the reference.

**Design stance.** zcode keeps its TOML config stack as the source of truth for
zcode-native keys (provider settings, UI, enterprise controls). We ADD a parallel
`settings.json` layer so that Claude Code config artifacts (`.claude/settings.json`
permissions/hooks/env, `availableModels`) are honored. We do NOT migrate the
existing TOML to JSON. The two coexist: TOML drives zcode-native behavior,
settings.json drives the parity surface (permissions arrays, hooks blocks, env,
availableModels). This is a deliberate deviation recorded in the project wiki.

**Dependencies.** None. This is the base phase.

**Estimated effort.** L (largest single phase; it is the foundation four later
dimensions build on).

## Gaps covered

| id | title | severity | size | our current state |
|---|---|---|---|---|
| permissions-02 | settings.json `permissions.{allow,deny,ask}` arrays + multi-source precedence | high | L | Single TSV at `~/.zcode/permissions/rules.tsv` (`core/permission_rules.zig`); no JSON arrays, no source precedence |
| hooks-03 | project/local/policy settings.json scope for hooks | medium | M | `HookScope` has only user/workspace; JSON hooks read only from `~/.zcode/settings.json` (`core/hooks.zig:211-256`) |
| mcp-10 | `mcp__server__tool` tool-name normalization + claude.ai prefix collapse | medium | M | Colon format `mcp::server::tool` (`tools/tool_schemas.zig:508`, `tools/tool_dispatch.zig:1024-1053`); no `normalizeNameForMCP` |
| hooks-09 | standard `CLAUDE_*` hook env vars + `CLAUDE_ENV_FILE` | medium | M | `ZCODE_*` only (`core/hooks.zig:304-309`); no `CLAUDE_*`, no `CLAUDE_ENV_FILE` |
| api-providers-07 | model alias resolution + `[1m]` suffix | medium | M | Raw model names only; no aliases, no `[1m]` (`repl_commands.zig:4284`, `core/config.zig:137`) |
| api-providers-08 | `availableModels` allowlist enforcement | low | M | `available_models` field parsed but only feeds `/model` catalog; no `isModelAllowed` gate |
| compaction-13 | `[1m]` detection + per-model context-window resolution | low | S | Catalog-driven per-model window exists (`repl_commands.zig:3216`); no `[1m]` detection; all Anthropic models hardcoded 200k (`anthropic.zig:560`) |
| misc-utils-22 | config-key rename migrations framework | low | M | None; unknown keys logged as warnings (`config_parse.zig:463`), never migrated |

## Implementation tasks

The tasks are ordered so that shared infrastructure (the settings.json source
loader, Task 1) lands first; permissions (Task 2) and hooks (Task 4) both consume
it. Tasks 3, 5, 6, 7, 8, 9 are independent of each other and can be built in
parallel once Task 1 (for Task 2/4) and the standalone tasks are scheduled.

---

### Task 1: settings.json multi-source loader and precedence chain

**Goal.** Provide a single module that reads `settings.json` from each source in
the reference precedence order and exposes a merged + per-source view.

**Reference behavior + reference file:line.**
- `SETTING_SOURCES = [userSettings, projectSettings, localSettings, flagSettings, policySettings]`, "later sources override earlier ones" - `utils/settings/constants.ts:5-22`.
- `getSettingsForSource(source)` returns the parsed JSON for one source; `permissionsLoader.ts:140-145` and `hooksConfigSnapshot.ts:18-53` read per-source.
- The permission precedence list extends the settings sources with `cliArg`, `command`, `session`: `permissions.ts:109-114` `PERMISSION_RULE_SOURCES`.

Note the two distinct orderings in the reference:
- `SETTING_SOURCES` (constants.ts) lists user, project, local, flag, policy for
  *override* semantics (later wins on scalar merges).
- `PERMISSION_RULE_SOURCES` (permissions.ts) appends cliArg/command/session and
  is used for *rule collection* (all rules from all sources are gathered; deny
  beats allow at match time, not by list order). Keep these as two separate
  constants to match the reference exactly.

**Target Zig files.**
- Create `src/core/settings_sources.zig` (deep module; pure source resolution +
  JSON read, no business logic).
- Register in `src/main.zig` comptime block: add
  `_ = @import("core/settings_sources.zig");` alongside the other `core/` entries
  (after `_ = @import("core/hook_config.zig");` at main.zig:98).
- Reuse `@import("zcode_runtime")` for `rt.io`, `core/paths.zig` for the
  `~/.zcode` home and workspace path helpers.

**Approach.**
1. Define `pub const Source = enum { policy, flag, user, project, local };` and
   `pub const PermissionRuleSource = enum { policy, flag, user, project, local, cli_arg, command, session };`.
   Give each a `displayName()` matching `getSettingSourceDisplayNameLowercase`
   (constants.ts:69-90): policy = "enterprise managed settings", user = "user
   settings", project = "shared project settings", local = "project local
   settings", flag = "command line arguments", cli_arg = "CLI argument", command
   = "command configuration", session = "session".
2. Define `sourceOrder()` returning the five sources in
   `[user, project, local, flag, policy]` order (matching `SETTING_SOURCES`),
   for scalar-override merges.
3. Resolve each source's file path:
   - `user` -> `{zcode_home}/settings.json`
   - `project` -> `{cwd}/.claude/settings.json`
   - `local` -> `{cwd}/.claude/settings.local.json`
   - `policy` -> managed settings path. Reuse our existing managed-config
     resolution. For Phase 1, the policy source reads
     `{zcode_home}/policy/settings.json` (a JSON sibling to the existing
     `policy/policy.toml`); the OS-level MDM plist/registry paths from the
     reference (`mdm` constants) are deferred (see Out-of-scope).
   - `flag` -> the path passed via a `--settings <path>` CLI flag; if absent the
     source is empty. Wire the flag in `src/cli/args.zig` as an optional
     `settings_path: ?[]const u8`.
4. `pub fn readSource(allocator, cwd, source, flag_path) !?std.json.Parsed(std.json.Value)`:
   read the file with `std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(256*1024))`,
   return `null` on `error.FileNotFound`, parse via the existing bounded JSON
   helper (`parse_helpers.parseJsonBounded` is used in providers; reuse the same
   bounded pattern to cap hostile payloads). Empty/whitespace file -> empty object.
5. `pub fn getString/getBool/getArray(value, key)` small accessors that tolerate
   missing keys and wrong types (return null), mirroring the reference's lenient
   read.
6. Provide `pub fn mergedScalarBool(allocator, cwd, flag_path, key) ?bool` and a
   generic merged getter that walks `sourceOrder()` and lets later sources win.
   This is the primitive Task 4 (hooks `disableAllHooks`) and Task 2
   (`allowManagedPermissionRulesOnly`) build on.

**Acceptance criteria.**
- Write a test that, given a tmp dir with `.claude/settings.json` containing
  `{"permissions":{"allow":["Read"]}}` and `.claude/settings.local.json`
  containing `{"permissions":{"allow":["Write"]}}`, `readSource` for `.project`
  and `.local` each return the right parsed object. Use
  `core/test_helpers.zig::tmpDirPath` for the cwd (do NOT pass `"."`).
- Write a test that a missing source file yields `null` (not an error).
- Write a test that `sourceOrder()` returns exactly
  `[user, project, local, flag, policy]` and that `displayName()` matches the
  reference strings.

**Test strategy.** Unit tests inside `settings_sources.zig`, run under
`tools/test_runner.zig`. The custom runner installs `rt.io`/`rt.gpa`, so file IO
works. Build the tmp tree with `testing.TmpDir` and resolve the absolute path via
`test_helpers.tmpDirPath`.

**Risk / footguns.**
- `readFileAlloc(.limited(N))` returns `error.StreamTooLong`, not
  `error.FileTooBig` (CLAUDE.md gotcha) - handle it as "treat as empty / log".
- Do NOT pass `"."` or relative cwd to the path builders - relative to the test
  process CWD, not the tmp dir (CLAUDE.md test_helpers note).
- JSON `ObjectMap` pointer invalidation: if you mutate a parsed object, take the
  object by pointer (`&parsed.value.object`) - but Phase 1 only reads, so this is
  mostly N/A.

**Size estimate.** M.

---

### Task 2: permissions.{allow,deny,ask} array loader over settings sources

**Goal.** Load permission rules from each source's
`permissions.{allow,deny,ask}` arrays and feed them into our existing
`permission_rules.Store`, with `allowManagedPermissionRulesOnly` restriction.

**Reference behavior + reference file:line.**
- `settingsJsonToRules(data, source)` iterates `['allow','deny','ask']` and emits
  one rule per string in each array, tagged with the source -
  `permissionsLoader.ts:91-114`.
- `loadAllPermissionRulesFromDisk()` short-circuits to policy-only when
  `shouldAllowManagedPermissionRulesOnly()` is true, otherwise concatenates rules
  from all enabled sources - `permissionsLoader.ts:120-133`.
- `shouldAllowManagedPermissionRulesOnly()` reads
  `policySettings.allowManagedPermissionRulesOnly === true` -
  `permissionsLoader.ts:31-44`.
- The rule string itself (e.g. `"Bash(git commit:*)"` or `"mcp__server__tool"`)
  is parsed by `permissionRuleValueFromString` into `{ toolName, ruleContent }`.
  zcode's `Rule` already splits tool + args (`permission_rules.zig:50-66`), so
  reuse that.

**Target Zig files.**
- Edit `src/core/permission_rules.zig`: add
  `pub fn loadFromSettingsJson(self: *Store, allocator, cwd, flag_path) !void`
  that calls into `settings_sources.zig`, walks the
  `PermissionRuleSource` order (policy/flag/user/project/local; cli_arg/command/session
  are populated at runtime, not from disk), parses each source's
  `permissions.{allow,deny,ask}` arrays, and `addRule`s each entry tagged with
  the source label.
- Edit `src/agent_runtime.zig:379-385`: after (or instead of) the TSV
  `loadFromFile`, call `loadFromSettingsJson`. Keep the TSV load for backward
  compatibility (zcode-native rules added via `/permissions`), then layer the
  JSON arrays on top.
- No new module to register; both files are already in the build.

**Approach.**
1. Add a `Source` field mapping: extend `permission_rules.zig`'s
   `source_label`/`source_path` to carry the settings source name. The existing
   `addRule(action, scope, tool, args_contains, source_path, source_line, source_label)`
   signature already accepts a label - pass e.g. `"user settings"` /
   `"shared project settings"` (from `settings_sources.displayName`).
2. Map JSON arrays to `Action`: `allow` -> `.allow`, `deny` -> `.deny`,
   `ask` -> `.ask`.
3. Parse each rule string into tool + args_contains: reference rule format is
   `ToolName` or `ToolName(content)`. Split on the first `(`; if present, the
   inside (minus trailing `)`) is the `args_contains` content, else empty. This
   matches how zcode's TSV already stores `tool` + `args_contains`.
4. For MCP rules (`mcp__server__tool` strings), store the whole normalized name
   as `tool` (no args split) - Task 3 produces these names so matching lines up.
5. Implement `allowManagedPermissionRulesOnly`: read the bool from the policy
   source via `settings_sources.mergedScalarBool` restricted to the policy
   source. If true, clear all non-policy rules (load only policy-source arrays).
6. Scope: settings.json rules are not workspace-scoped the way the TSV is. Map
   project/local sources to `.workspace = cwd`, user/policy/flag to `.global`.
   This preserves zcode's existing scope semantics while honoring source origin.

**Acceptance criteria.**
- Write a test: tmp cwd with `.claude/settings.json`
  `{"permissions":{"deny":["Bash(rm -rf:*)"],"allow":["Read"]}}`; after
  `loadFromSettingsJson` the Store contains a deny rule with tool `Bash` and
  args_contains `rm -rf:*`, and an allow rule with tool `Read`.
- Write a test: policy source with `{"allowManagedPermissionRulesOnly":true}` and
  a project allow rule -> after load the project rule is absent (only policy
  rules survive).
- Write a test: an MCP rule string `mcp__github__create_issue` loads as a single
  tool with empty args_contains.
- Existing `permission_rules.zig` tests still pass (TSV path unchanged).

**Test strategy.** Unit tests in `permission_rules.zig` using `tmpDirPath`. Run
the full `zig build test` under `tools/test_runner.zig` to confirm no regression
in the existing TSV tests and the agent_runtime load path.

**Risk / footguns.**
- Deny-beats-allow is resolved at match time, not load time. Do NOT dedupe or
  reorder; just collect all rules. The existing matcher in `permission_rules.zig`
  already evaluates deny precedence - verify it still does after JSON rules are
  mixed in.
- The reference does NOT validate rule strings strictly when reading for
  execution; tolerate malformed entries (skip, log) rather than failing the whole
  load.
- `is_test` guard: `agent_runtime.zig:382` skips the disk load under test. Keep
  the JSON load behind the same guard so tests stay hermetic, and test
  `loadFromSettingsJson` directly in the unit test (not via runtime init).

**Size estimate.** L.

---

### Task 3: MCP tool-name normalization (mcp__server__tool) + claude.ai collapse

**Goal.** Canonicalize MCP tool/server names to `mcp__<server>__<tool>` with
character normalization, and parse them back, so permission rules and the API
tool-name pattern line up with the reference.

**Reference behavior + reference file:line.**
- `normalizeNameForMCP(name)` replaces every char not in `[a-zA-Z0-9_-]` with
  `_`; for names starting with `"claude.ai "` it additionally collapses runs of
  `_` to a single `_` and strips leading/trailing `_` - `normalization.ts:17-23`.
- `getMcpPrefix(server)` = `mcp__{normalize(server)}__`; `buildMcpToolName(server,tool)`
  = prefix + `normalize(tool)`; `mcpInfoFromString(s)` splits on `__`, requires
  first part `mcp` and a non-empty server, rejoins the remainder as tool -
  `mcpStringUtils.ts:19-52`.
- `getToolNameForPermissionCheck(tool)` returns the `mcp__server__tool` form for
  MCP tools so deny rules on builtins (e.g. `Write`) do not collide with MCP
  tools that share a display name - `mcpStringUtils.ts:60-67`.

**Target Zig files.**
- Create `src/core/mcp_name.zig` (pure, no deps beyond std) with
  `normalizeNameForMCP`, `buildMcpToolName`, `mcpInfoFromString`, `getMcpPrefix`.
- Register in `src/main.zig` comptime block.
- Edit `src/tools/tool_schemas.zig:508` (and any other `mcp::` builders) to use
  `mcp_name.buildMcpToolName(server, tool.name)`.
- Edit `src/tools/tool_dispatch.zig:1045-1053` `parseMcpToolName` to delegate to
  `mcp_name.mcpInfoFromString` (handle the `mcp__` prefix). Keep accepting the
  old `mcp::` form for one release as a fallback so in-flight sessions / saved
  registries do not break (log a deprecation note).

**Approach.**
1. `pub fn normalizeNameForMCP(allocator, name) ![]u8`: allocate a buffer; for
   each byte, if it is `a-z A-Z 0-9 _ -` keep it, else write `_`. If
   `std.mem.startsWith(u8, name, "claude.ai ")`, run a second pass collapsing
   consecutive `_` to one and trimming leading/trailing `_`.
2. `pub fn getMcpPrefix(allocator, server) ![]u8` -> `mcp__{norm}__`.
3. `pub fn buildMcpToolName(allocator, server, tool) ![]u8` -> prefix + norm(tool).
4. `pub const McpInfo = struct { server: []const u8, tool: ?[]const u8 };`
   `pub fn mcpInfoFromString(name) ?McpInfo`: split on `__`; require first token
   `mcp` and a non-empty second token; rejoin remaining tokens with `__` for the
   tool (preserving the reference's double-underscore-in-tool behavior). These
   return slices into the input (no alloc) for parsing; builders alloc.
5. Update the chrome bridge builder at `tool_schemas.zig:508` from
   `mcp::chrome::{name}` to `buildMcpToolName(allocator, "chrome", tool.name)`.
6. Update `tool_dispatch.zig` dispatch: try `mcp_name.mcpInfoFromString` first;
   if null, fall back to the legacy `mcp::` parser for one release.
7. Ensure the chrome special-case (`std.mem.eql(parsed.server, "chrome")`) still
   works with the normalized server name.

**Acceptance criteria.**
- Write tests in `mcp_name.zig`:
  - `normalizeNameForMCP("git hub.io")` == `"git_hub_io"`.
  - `normalizeNameForMCP("claude.ai My Server")` collapses to `"claude_ai_My_Server"`
    (no doubled `_`, no leading/trailing `_`).
  - `buildMcpToolName("github", "create issue")` == `"mcp__github__create_issue"`.
  - `mcpInfoFromString("mcp__github__create_issue")` -> server `github`, tool
    `create_issue`.
  - `mcpInfoFromString("mcp__my__server__tool")` -> server `my`, tool
    `server__tool` (documented known limitation; match the reference exactly).
  - `mcpInfoFromString("Write")` -> null.
- Build passes and the chrome bridge round-trips: a `mcp__chrome__navigate` name
  dispatches to the chrome bridge.

**Test strategy.** Unit tests in `mcp_name.zig`. Plus a dispatch test in
`tool_dispatch.zig` confirming a `mcp__chrome__...` name routes to the bridge and
a legacy `mcp::chrome::...` name still routes (fallback). Run under
`tools/test_runner.zig`.

**Risk / footguns.**
- Saved MCP registries and any persisted tool names use the old `mcp::` form -
  the one-release fallback prevents breaking existing sessions. Note it in the
  wiki.
- The `__` split limitation (server names containing `__`) is intentional in the
  reference; replicate it, do not "fix" it (Surgical Changes - match the spec).
- Permission rule matching (Task 2) must key on the SAME normalized name. Wire
  Task 2's MCP-rule handling to call `buildMcpToolName` when constructing the
  match key so the two agree.

**Size estimate.** M.

---

### Task 4: hooks from project/local/policy settings.json scopes

**Goal.** Extend hook loading beyond `~/.zcode/settings.json` to merge hooks from
the project, local, and policy settings.json sources, with the managed-only and
disable-all gates.

**Reference behavior + reference file:line.**
- `getHooksFromAllowedSources()` merges hooks from all sources;
  `policySettings.disableAllHooks` -> none; `policySettings.allowManagedHooksOnly`
  -> only managed; non-managed `disableAllHooks` -> only managed hooks still run -
  `hooksConfigSnapshot.ts:18-53`.

**Target Zig files.**
- Edit `src/core/hooks.zig`:
  - Extend `HookScope` (hooks.zig:19-22) to
    `{ user, workspace, project, local, policy }`. Add `scopeName` arms
    (hooks.zig:68-73).
  - Generalize `runConfiguredUser` (hooks.zig:211-256) into
    `runConfiguredFromSources` that, instead of hardcoding
    `{zcode_home}/settings.json` (hooks.zig:217), iterates the settings sources
    from `settings_sources.zig` and parses each via the existing
    `hook_config.parse` (hooks.zig:223). Keep the existing user-scope behavior as
    one of the sources.
- Reuse `src/core/hook_config.zig` (`parse` returns `Parsed.defs`) - no change to
  the parser; it already extracts command/prompt/http/agent defs.
- Reuse Task 1 `settings_sources.zig` for paths + the `disableAllHooks` /
  `allowManagedHooksOnly` scalar reads.

**Approach.**
1. Replace the single `settings_path` build (hooks.zig:217) with a loop over
   `settings_sources.sourceOrder()`. For each source, read the file, parse with
   `hook_config.parse`, and collect defs tagged with the source scope.
2. Apply the gates BEFORE running:
   - If policy source has `disableAllHooks: true` -> run nothing.
   - Else if policy source has `allowManagedHooksOnly: true` -> keep only
     policy-scope defs.
   - Else if any non-policy source has `disableAllHooks: true` -> keep only
     policy-scope defs.
   - Else run all (merged).
   Read these booleans via `settings_sources.mergedScalarBool` /
   per-source bool reads.
3. Trust gating: project/local hooks come from the workspace and MUST go through
   the same trust gate as the workspace `.sh` hooks
   (`security.isHookTrusted`, hooks.zig:142). User and policy sources are trusted
   (user's own home / managed). Apply `isHookTrusted` for project/local scopes.
4. Preserve the existing `.sh` file-hook path (hooks.zig:79-103) unchanged - that
   is a separate mechanism and still valid.

**Acceptance criteria.**
- Write a test: tmp cwd with `.claude/settings.json` containing a `PreToolUse`
  command hook; after `run` for a matching tool the hook executes (subject to
  trust gate - test with the workspace marked trusted).
- Write a test: policy source with `{"disableAllHooks":true}` plus a project hook
  -> no hooks run.
- Write a test: policy source with `{"allowManagedHooksOnly":true}` plus a
  project hook and a policy hook -> only the policy hook runs.
- Existing user-scope hook tests still pass.

**Test strategy.** Unit tests in `hooks.zig` using `tmpDirPath`. The hook command
runs `sh -c`; keep the test hook a trivial `echo`-style script. Run under
`tools/test_runner.zig`. Mark the workspace trusted in the test via the same
mechanism `security.zig` uses (or test the gate separately and the merge logic
with user-scope hooks which need no trust gate).

**Risk / footguns.**
- The hook command runner writes a temp payload file and runs
  `sh -c "<cmd> < '<tmp>'"` (hooks.zig:264-298). Project/local hook commands are
  untrusted code - the trust gate is mandatory, do not skip it for workspace
  sources.
- `std.process.run` reaping: do not call `wait()` after a one-shot run
  (CLAUDE.md `Child.kill` gotcha) - the existing code already uses the one-shot
  runner, keep it.
- Keep error degradation: a failing/missing source must degrade to "did not run"
  (existing `notRanResult` pattern, hooks.zig:207-209), never crash startup.

**Size estimate.** M.

---

### Task 5: CLAUDE_* hook/plugin env vars + CLAUDE_ENV_FILE

**Goal.** Expose the standard `CLAUDE_*` environment variables to command hooks
and plugin hooks (as an alias set alongside the existing `ZCODE_*`), and implement
the `CLAUDE_ENV_FILE` export-injection mechanism.

**Reference behavior + reference file:line.**
- `CLAUDE_PROJECT_DIR` (stable repo root) - `utils/hooks.ts:884`.
- `CLAUDE_PLUGIN_ROOT` :890, `CLAUDE_PLUGIN_DATA` :892,
  `CLAUDE_PLUGIN_OPTION_*` :904.
- `CLAUDE_ENV_FILE` :925 - for SessionStart/Setup/CwdChanged/FileChanged the hook
  may write `KEY=value` bash exports to this file; those are then applied to
  later Bash tool commands.

**Target Zig files.**
- Edit `src/core/hooks.zig:300-309` (`runSingle`) and `:283-285`
  (`runCommandWithStdin`): in addition to the existing `ZCODE_*` puts, add the
  `CLAUDE_*` equivalents:
  - `CLAUDE_PROJECT_DIR` = repo root (reuse the workspace/git-root resolver; fall
    back to `ctx.cwd`).
  - For tool-context vars, mirror `ZCODE_TOOL_*` to the reference names where they
    exist (the reference passes hook payload on stdin as JSON, so the tool-context
    env vars are a zcode extension - keep `ZCODE_*` and ALSO set `CLAUDE_*`
    aliases for `CLAUDE_PROJECT_DIR` at minimum).
- Edit `src/core/plugins.zig:413-422`: add `CLAUDE_PLUGIN_ROOT`,
  `CLAUDE_PLUGIN_DATA`, `CLAUDE_PLUGIN_OPTION_*` alongside the `ZCODE_PLUGIN_*`
  vars.
- Edit `src/core/session_env.zig`: add `CLAUDE_ENV_FILE` support - allocate a temp
  env file per applicable hook event, set `CLAUDE_ENV_FILE` to its path in the
  hook env, and after the hook runs read it back and merge `KEY=value` lines into
  the session env applied to later Bash commands (`applyToEnvMap`).

**Approach.**
1. Hook env (hooks.zig:300-309): after the `ZCODE_*` puts, add
   `env_map.put("CLAUDE_PROJECT_DIR", project_dir)`. Resolve `project_dir` via the
   existing workspace/git-root helper; if none, use `ctx.cwd`.
2. Plugin env (plugins.zig:413-422): map `ZCODE_PLUGIN_*` to `CLAUDE_PLUGIN_ROOT`
   (the plugin's install dir), `CLAUDE_PLUGIN_DATA` (its data dir), and for each
   plugin option emit `CLAUDE_PLUGIN_OPTION_<NAME>`.
3. CLAUDE_ENV_FILE (session_env.zig + hooks.zig):
   - For the applicable events (SessionStart/Setup/CwdChanged/FileChanged - map to
     our event enum; for Phase 1 wire it for the events we already emit), create a
     temp file under `{zcode_home}` with a hex nonce name (same pattern as
     hooks.zig:266), set `CLAUDE_ENV_FILE` to its path in the hook env.
   - After the hook returns, read the file, parse `KEY=value` lines (ignore blank /
     `#` comment lines), and merge into the session env store
     (`session_env.applyToEnvMap`'s backing map). Delete the temp file.
   - Validate keys: only `[A-Za-z_][A-Za-z0-9_]*` keys, reject anything with a
     newline in the value beyond the line itself (the file is line-oriented).
4. Keep `ZCODE_*` vars in place (do not remove) - additive only (Surgical
   Changes).

**Acceptance criteria.**
- Write a test: a command hook can read `$CLAUDE_PROJECT_DIR` and it equals the
  resolved repo root (or cwd when not a repo).
- Write a test: a SessionStart-equivalent hook that writes `FOO=bar` to
  `$CLAUDE_ENV_FILE` results in `FOO=bar` being present in the session env applied
  to a subsequent Bash command (assert via `session_env.applyToEnvMap`).
- Write a test: a plugin hook sees `CLAUDE_PLUGIN_ROOT` set to the plugin dir.
- Existing hook env tests (ZCODE_* still present) pass.

**Test strategy.** Unit tests in `hooks.zig`, `plugins.zig`, `session_env.zig`.
For the CLAUDE_ENV_FILE round-trip, run a real `sh -c 'echo FOO=bar >
"$CLAUDE_ENV_FILE"'` hook and assert the merge. Run under `tools/test_runner.zig`.

**Risk / footguns.**
- `Environ.Map.remove` is gone - use `swapRemove` if you need to drop a key
  (CLAUDE.md gotcha).
- The env file is written by untrusted hook code - parse defensively
  (length cap, key charset validation) to avoid injecting garbage or huge values
  into later Bash commands.
- Do not leak the temp file: `defer deleteFile catch {}` (hooks.zig:273 pattern).
- `std.process.run` env: pass `&env_map` (pointer) per the existing call shape;
  do not re-derive the environment.

**Size estimate.** M.

---

### Task 6: model alias resolution + [1m] suffix

**Goal.** Resolve bare aliases (`opus`/`sonnet`/`haiku`/`best`/`opusplan`) and the
`[1m]` suffix into concrete model IDs at the point the user specifies a model.

**Reference behavior + reference file:line.**
- `MODEL_ALIASES = [sonnet, opus, haiku, best, sonnet[1m], opus[1m], opusplan]` -
  `aliases.ts:1-14`.
- `parseUserSpecifiedModel`: trim + lowercase, detect `[1m]` via
  `has1mContext`, strip it to get the base, switch on the alias
  (`opusplan`->sonnet default, `sonnet`->sonnet default, `haiku`->haiku default,
  `opus`->opus default, `best`->opus/best), re-append `[1m]` where the family
  supports it; non-alias custom names pass through preserving case -
  `model.ts:445-506`.
- `MODEL_FAMILY_ALIASES = [sonnet, opus, haiku]` for allowlist wildcards -
  `aliases.ts:21-25`.

**Target Zig files.**
- Create `src/core/model_alias.zig` (pure; the default-model strings are zcode's
  current defaults).
- Register in `src/main.zig` comptime block.
- Edit `src/repl_commands.zig:4284` (`switchReplModel`) and the `/model` command
  entry (repl_commands.zig:1010-1026) to run the input through
  `model_alias.resolve` before storing/validating.

**Approach.**
1. Define the alias set and family-alias set as comptime arrays.
2. `pub const Resolved = struct { model: []u8, one_m: bool };`
   `pub fn resolve(allocator, input) !Resolved`:
   - trim, lowercase a copy for matching;
   - detect `[1m]` suffix (case-insensitive `\[1m\]$`), strip to base;
   - switch base:
     - `opus` -> `getDefaultOpusModel()` (currently `"claude-opus-4-6"`,
       matching config.zig:137);
     - `sonnet` -> `getDefaultSonnetModel()` (`"claude-sonnet-4-6"`);
     - `haiku` -> `getDefaultHaikuModel()` (`"claude-haiku-4-5"`);
     - `best` -> opus default (reference maps best->opus);
     - `opusplan` -> sonnet default (Opus is swapped in only inside plan mode;
       Phase 1 resolves the base to sonnet; plan-mode swap is deferred/out-of-scope
       and noted);
   - non-alias: return the ORIGINAL (case-preserved) input as the model;
   - carry `[1m]` into `one_m` and, for sonnet/opus families, append `[1m]` back
     onto the returned model string so downstream context-window detection
     (Task 8) sees it. For `haiku`/`best`/custom-with-no-1m-support, set
     `one_m=false` and do not append (reference: haiku has no 1M variant).
3. Centralize the default-model strings in one place so Task 7/8 reuse them. The
   `getDefault*Model` functions can read from the model catalog if available, else
   fall back to the hardcoded defaults.
4. Wire into `/model`: in `switchReplModel`, call `resolve` and store
   `resolved.model` as `active_model` (repl_commands.zig:4286,4325) instead of the
   raw input.

**Acceptance criteria.**
- Write tests in `model_alias.zig`:
  - `resolve("opus")` -> `claude-opus-4-6`, one_m false.
  - `resolve("sonnet[1m]")` -> `claude-sonnet-4-6[1m]`, one_m true.
  - `resolve("haiku[1m]")` -> base `claude-haiku-4-5`, one_m false (haiku has no
    1M; the suffix is dropped) - match the reference's family-support carry rule.
  - `resolve("best")` -> opus default.
  - `resolve("opusplan")` -> sonnet default.
  - `resolve("claude-opus-4-6")` (full id) -> unchanged.
  - `resolve("MyAzureDeployment")` -> case preserved, unchanged.
- A `/model opus` in the REPL stores `claude-opus-4-6` as the active model
  (verify via the existing model-switch path).

**Test strategy.** Unit tests in `model_alias.zig`. Plus one repl_commands test
asserting `switchReplModel` stores the resolved id. Run under
`tools/test_runner.zig`.

**Risk / footguns.**
- Case handling: lowercase ONLY for alias matching; return custom names with
  original case (Azure Foundry deployment IDs are case-sensitive) -
  model.ts:500-505.
- Do not hardcode the defaults in three places - one module owns them.
- `opusplan` plan-mode behavior is more than alias resolution
  (`getRuntimeMainLoopModel`, model.ts:145-167). Phase 1 only does the base
  resolution; the plan-mode Opus swap is deferred (note it).

**Size estimate.** M.

---

### Task 7: availableModels allowlist enforcement gate

**Goal.** Gate user-specified models against the `availableModels` allowlist with
the three matching tiers before any API call.

**Reference behavior + reference file:line.**
- `isModelAllowed(model)`: no allowlist -> allow all; empty allowlist -> block
  all; family aliases (opus/sonnet/haiku) as wildcards UNLESS narrowed by specific
  entries; version prefixes (`opus-4-5`, `claude-opus-4-5`) match any build at a
  segment boundary; full IDs exact match - `modelAllowlist.ts:100-170`.
- The allowlist check runs before any API call - `validateModel.ts:31-36`.

**Target Zig files.**
- Create `src/core/model_allowlist.zig` (pure; depends on `model_alias.zig` for
  alias resolution and family-alias detection).
- Register in `src/main.zig` comptime block.
- Edit `src/repl_commands.zig` (`/model` switch path, ~1010-1026 / 4284) to call
  `model_allowlist.isAllowed` and refuse the switch with a clear message when
  disallowed.
- Edit `src/agent_history.zig:337` (the `callModel` entry) to gate the active
  model before the first API call - fail closed with a clear error if the active
  model is not allowed.

**Approach.**
1. The allowlist source: zcode stores `available_models` as a single string
   (`config.zig:15`, comma/space separated, parsed at config_parse.zig:478). Parse
   it into a slice of entries (split on comma, trim).
2. `pub fn isAllowed(allocator, model, allowlist_entries) bool`:
   - if `allowlist_entries` is null/unset -> true (no restriction);
   - if it has zero entries (explicitly empty) -> false (block all). Distinguish
     "unset" from "set-but-empty": treat an empty `available_models` string as
     UNSET (no restriction) to preserve current zcode behavior, and add a separate
     explicit "empty allowlist blocks all" only if the admin sets a sentinel.
     (Record this deviation: zcode's empty string historically means "no
     allowlist", so we keep that and document the difference from the reference's
     `length === 0` semantics.)
   - resolve the model via `model_alias.resolve` (strip `[1m]`), lowercase;
   - lowercase + trim each allowlist entry;
   - Tier 1 direct match (but skip a family alias that has been narrowed by a
     specific same-family entry);
   - Tier 2 family-alias wildcard (`opus` allows any opus, unless narrowed);
   - bidirectional alias resolution (input alias -> resolved in list; list alias
     -> resolves to input);
   - Tier 3 version-prefix segment-boundary match (`opus-4-5` matches
     `claude-opus-4-5-20251101`).
   Mirror `modelAllowlist.ts` tier order exactly.
3. Helper functions: `isModelFamilyAlias`, `familyHasSpecificEntries`,
   `modelBelongsToFamily`, `modelMatchesVersionPrefix` - port from the reference.
4. Wire the gate: `/model` switch rejects with
   `"model '<x>' is not in the availableModels allowlist"`; `callModel` fails
   closed for the active model.

**Acceptance criteria.**
- Write tests in `model_allowlist.zig`:
  - unset/empty `available_models` -> any model allowed.
  - `["opus"]` -> `claude-opus-4-6` allowed, `claude-sonnet-4-6` denied.
  - `["opus","opus-4-5"]` -> `claude-opus-4-6` denied (family narrowed), a
    `claude-opus-4-5-*` allowed.
  - `["claude-opus-4-6-20251101"]` (full id) -> exact match only.
  - version prefix `["opus-4-6"]` matches `claude-opus-4-6-20251101`.
- A `/model` switch to a disallowed model is refused with a clear message and the
  active model is unchanged.

**Test strategy.** Unit tests in `model_allowlist.zig`. Plus a repl_commands test
for the refusal path. Run under `tools/test_runner.zig`.

**Risk / footguns.**
- Segment-boundary matching: `opus-4-5` must NOT match `opus-4-50`; split on `-`
  and compare segment runs, do not use raw `startsWith`.
- The empty-allowlist semantics deviation (above) must be documented in the wiki
  and the corrected_status note acknowledges severity low - do not over-engineer.
- `callModel` gate must fail closed but with a helpful message, not a panic.

**Size estimate.** M.

---

### Task 8: per-model context-window resolution honoring [1m]

**Goal.** When resolving a model's context window, honor the `[1m]` suffix
(1,000,000 tokens) over the catalog/hardcoded default.

**Reference behavior + reference file:line.**
- `getContextWindowForModel`: env override (ant-only) wins; then `[1m]` suffix ->
  1,000,000; then model capability `max_input_tokens`; then beta-header / exp;
  else default - `utils/context.ts:51-98`.
- `has1mContext` = `[1m]` present and not disabled; `modelSupports1M` matches
  `claude-sonnet-4` / `opus-4-6` - `context.ts:35-49`.

**Target Zig files.**
- Edit `src/repl_commands.zig:3216-3227` (`updateContextWindowForModel`): before
  the catalog lookup, check for a `[1m]` suffix on `runtime.active_model` (or the
  resolved model) and set `model_context_window = 1_000_000`.
- Optionally add the small helpers to `src/core/model_alias.zig` (it already owns
  `[1m]` detection from Task 6) - `pub fn has1mContext(model) bool` and
  `pub fn modelSupports1M(model) bool`.
- Honor a `CLAUDE_CODE_DISABLE_1M_CONTEXT` env var (reuse `core/env.zig`
  getters) - when truthy, `has1mContext` returns false.

**Approach.**
1. Add `has1mContext(model)`: returns false if `CLAUDE_CODE_DISABLE_1M_CONTEXT`
   is truthy; else returns whether the model string ends with `[1m]`
   (case-insensitive).
2. Add `modelSupports1M(model)`: canonical name contains `claude-sonnet-4` or
   `opus-4-6` (port the reference pattern; update when new models land).
3. In `updateContextWindowForModel`: if `has1mContext(active_model)` set the
   window to 1,000,000 and return (before the catalog loop). Else keep the
   existing catalog-driven behavior unchanged.
4. Do NOT change the hardcoded 200k in `anthropic.zig:560` - that is the
   capability default for non-`[1m]` models and is correct. The `[1m]` override
   happens at window-resolution time, layered on top.

**Acceptance criteria.**
- Write a test (in repl_commands or a small helper test): active model
  `claude-sonnet-4-6[1m]` -> resolved window 1,000,000.
- Active model `claude-sonnet-4-6` (no suffix) -> resolved window from catalog
  (200,000) unchanged.
- With `CLAUDE_CODE_DISABLE_1M_CONTEXT=1`, `claude-sonnet-4-6[1m]` -> window falls
  back to catalog/default (200,000).

**Test strategy.** Unit tests for `has1mContext`/`modelSupports1M` in
`model_alias.zig`, plus a `updateContextWindowForModel` test in repl_commands.
Run under `tools/test_runner.zig`. For the env-var test, set the env in-process
via the test runner's environment handling.

**Risk / footguns.**
- This depends on Task 6 carrying the `[1m]` suffix through into `active_model`.
  Verify the suffix survives the `/model` resolution (Task 6 appends it for
  sonnet/opus).
- Severity is low / size S - resist adding beta-header or experiment detection
  (that is reference ant-only plumbing, out-of-scope).

**Size estimate.** S.

---

### Task 9: startup config-key migration framework

**Goal.** Add an idempotent startup pass that renames/relocates deprecated config
keys, with the reference migrations ported where they map to zcode.

**Reference behavior + reference file:line.**
- `migrateReplBridgeEnabledToRemoteControlAtStartup`: copy old key to new, delete
  old, idempotent - `migrations/migrateReplBridgeEnabledToRemoteControlAtStartup.ts`.
- `migrateAutoUpdatesToSettings`: `autoUpdates:false` -> `DISABLE_AUTOUPDATER` env
  in settings - `migrations/migrateAutoUpdatesToSettings.ts`.
- `migrateBypassPermissionsAcceptedToSettings`,
  `migrateEnableAllProjectMcpServersToSettings` (dedup-merge into local settings)
  - respective files. All run once at startup, all idempotent.

**Target Zig files.**
- Create `src/core/config_migrations.zig` (deep module): a list of migration
  functions over the parsed config + settings sources, each idempotent.
- Register in `src/main.zig` comptime block.
- Call `config_migrations.runAll(allocator, cwd)` once at startup, in the config
  load sequence (after the TOML config and settings.json sources are read, before
  the runtime is built). Wire the call in `src/core/config_parse.zig::load`
  (config_parse.zig:13) or in `src/main.zig` right after config load.

**Approach.**
1. Define `const Migration = struct { name: []const u8, run: *const fn(allocator, cwd) anyerror!bool };`
   where `run` returns true if it changed anything (for logging).
2. Build a generic "rename TOML key" helper: read the user `config.toml`, if it
   contains `old_key` and not `new_key`, rewrite the file with the key renamed.
   Idempotent: no-op if `old_key` absent or `new_key` already present. Use atomic
   write (the existing `writeFileAtomic` pattern in permission_rules.zig:137).
3. Port the migrations that map to zcode:
   - The general framework + at least one concrete migration so old configs
     upgrade cleanly. The Claude-specific keys (`replBridgeEnabled`,
     `autoUpdates`, `bypassPermissionsModeAccepted`, MCP-approval) do not all have
     zcode equivalents - implement the framework and the migrations that DO map,
     and leave clearly-marked stubs/notes for the ones that do not (per the gap's
     `notes`: "the framework ... does not exist" is the in-scope deliverable).
   - Concrete zcode candidate: if any zcode config key has been renamed historically
     (grep the config_parse keys for deprecated aliases). If none exists yet, ship
     the framework with a single example migration covered by a test that creates a
     config with the old key and asserts the new key after `runAll`.
4. Guard against double-run: migrations are inherently idempotent (they check for
   the old key's presence), so re-running on every startup is safe. No persisted
   "migrations applied" ledger is required for Phase 1.

**Acceptance criteria.**
- Write a test: a `config.toml` containing `old_example_key = true` and no
  `new_example_key` -> after `runAll`, the file has `new_example_key = true` and no
  `old_example_key`.
- Write a test: running `runAll` twice is a no-op the second time (idempotent).
- Write a test: a config that already has the new key is left unchanged (old key,
  if present, still removed; new value preserved).

**Test strategy.** Unit tests in `config_migrations.zig` using `tmpDirPath` to
build a fake `config.toml`. Run under `tools/test_runner.zig`.

**Risk / footguns.**
- TOML rewriting must preserve comments and unrelated keys - do a line-oriented
  key rename, not a full parse-and-serialize that would drop formatting. Match
  existing style (Surgical Changes).
- Atomic write to avoid a torn config on crash (reuse `writeFileAtomic`).
- Do NOT migrate keys the user might still be using intentionally without the
  presence check - idempotency hinges on "old present AND new absent".
- File write under test: use `tmpDirPath`, never the real `~/.zcode`.

**Size estimate.** M.

## Verification

Whole-phase proof:

1. **Tests pass.** `zig build test` (runs under `tools/test_runner.zig`) - all new
   unit tests in `settings_sources.zig`, `permission_rules.zig`, `mcp_name.zig`,
   `hooks.zig`, `plugins.zig`, `session_env.zig`, `model_alias.zig`,
   `model_allowlist.zig`, `config_migrations.zig`, and the repl_commands tests
   pass; no regression in existing tests. Confirm each new module appears in the
   `main.zig` comptime block (test discovery rule) - a module not referenced there
   does not get its tests run.

2. **Release build + install** (per CLAUDE.md):
   ```
   zig build -Doptimize=ReleaseFast
   rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode
   ```
   (rm-first to avoid the macOS ad-hoc code-signature SIGKILL footgun.)

3. **Version bump.** Bump `.version` patch in `build.zig.zon` before building.

4. **Manual checks.**
   - Create `<repo>/.claude/settings.json` with
     `{"permissions":{"deny":["Bash(rm -rf:*)"]}}`; start zcode in that repo and
     confirm a `rm -rf` bash attempt is denied with the source attributed to
     "shared project settings".
   - Create a `.claude/settings.json` `PreToolUse` hook and confirm it runs
     (after trusting the workspace).
   - In a hook script, echo `$CLAUDE_PROJECT_DIR` and confirm it is the repo root;
     write `FOO=bar` to `$CLAUDE_ENV_FILE` in a SessionStart-equivalent hook and
     confirm a later Bash command sees `FOO`.
   - `zcode` then `/model opus` -> active model becomes `claude-opus-4-6`;
     `/model sonnet[1m]` -> active model `claude-sonnet-4-6[1m]` and the status bar
     context window reads ~1M.
   - Set `available_models = opus` in config and try `/model sonnet` -> refused.
   - Confirm an MCP tool is exposed as `mcp__<server>__<tool>` (check
     `/mcp` / tool list) and a `mcp__<server>__<tool>` deny rule blocks it.
   - Put `old_example_key = true` in `~/.zcode/config.toml`, restart, confirm it
     was migrated.

## Out-of-scope / deferred notes

- **OS-level MDM settings sources** (macOS plist via `plutil`, Windows registry)
  from the reference `mdm` modules. Phase 1's policy source reads a JSON file
  under `{zcode_home}/policy/`. Native MDM integration is a separate, later effort.
- **`opusplan` plan-mode Opus swap** (`getRuntimeMainLoopModel`, model.ts:145-167):
  Phase 1 resolves `opusplan` to the sonnet base only. The dynamic "use Opus while
  in plan mode" behavior depends on plan-mode plumbing and is deferred.
- **Beta-header / experiment-driven 1M detection** (`getSonnet1mExpTreatmentEnabled`,
  CONTEXT_1M_BETA_HEADER): ant-only experiment plumbing; Phase 1 honors only the
  explicit `[1m]` suffix and the env disable switch.
- **Empty-allowlist-blocks-all semantics deviation**: zcode keeps "empty
  `available_models` string = no restriction" rather than the reference's
  `length===0 = block all`, to preserve existing behavior. Documented, not a bug.
- **`mcp::` legacy format fallback** is retained for one release; a follow-up
  should remove it once saved registries/sessions have rotated.
- **Reference-specific migrations** (`DISABLE_AUTOUPDATER`, `replBridgeEnabled`,
  MCP-approval) that have no zcode key equivalent: the migration FRAMEWORK is
  delivered; the specific Claude-only key migrations are implemented only where a
  zcode key actually maps. Adding zcode-native key renames later reuses the
  framework.
- **`cliArg`/`command`/`session` permission rule sources** are enumerated in the
  precedence chain but populated at runtime by later phases (CLI flags, slash
  commands, in-session approvals); Phase 1 only loads the disk-backed sources
  (policy/flag/user/project/local).
