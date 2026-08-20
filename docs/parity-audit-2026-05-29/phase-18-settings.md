# Phase 18: Settings and config depth

## Overview

**What.** This phase closes the remaining gaps between zcode's TOML-based config layer and the reference project's settings subsystem (`src/utils/settings/*`, `src/services/remoteManagedSettings/*`, `src/utils/managedEnvConstants.ts`, `src/utils/settings/mdm/*`). The first audit pass treated config as "mostly done" because the four-layer merge (user -> workspace -> local -> managed), the SHA-256-verified managed.toml drop-in path, key locking, plaintext-secret warnings, and per-error validation hints all already exist and work. This Round-2 pass covers the depth the first pass under-reported: a settings-sourced `[env]` block, a dangerous-key approval gate for managed files, native OS policy sources (macOS plist / Windows registry), `--setting-sources` scope filtering, `${VAR}` expansion, per-rule permission salvage, command-helper settings, cloud sync, full per-key provenance, and a machine-readable schema export.

**Why.** The reference treats settings as a security boundary as much as a convenience layer: an admin-pushed file can carry shell-executing keys (`apiKeyHelper`, `statusLine`, hooks) and routing-hijacking env vars (`ANTHROPIC_BASE_URL`, `HTTP_PROXY`), so it gates those behind an accept/reject dialog and strips provider-managed env when the host owns routing. zcode already fails closed on unreadable managed files and verifies their SHA-256, but it silently applies whatever keys are present and has no settings-sourced env at all. The highest-value items here are the local `[env]` block (settings-02, common real-world need: per-project `ANTHROPIC_*` / proxy vars) and the dangerous-key approval gate for managed drop-ins (settings-03). The rest are lower-severity polish or out-of-scope cloud/OS integrations.

**Dependencies on earlier phases.** None hard-blocking. settings-02 (`[env]` block) is a clean prerequisite for settings-06 (`${VAR}` expansion makes sense only once there is an env block to expand into) and pairs with settings-03 (the dangerous-env classifier needs the env block to exist before it has anything to classify). settings-03's classifier reuses the same dangerous-key set that a future statusLine helper (settings-08, out of scope) would register. If a hooks subsystem audit (separate phase) lands a parsed hooks model, settings-03's hooks scanner can consult it; until then settings-03 scans for a `[hooks]` section textually.

**Effort.** Two M items worth building now (settings-02, settings-03), two S items worth building (settings-05 scope filter, settings-07 per-rule salvage), and a cluster of low-priority S/M items that can be deferred or documented. Total in-scope build effort: roughly M+M+S+S plus two optional S items.

## Scope split

| Decision | Gap id | Reason |
|---|---|---|
| IN-SCOPE (build) | settings-02 | Local `[env]` TOML table merged into spawned-tool environment with provider-managed strip guard. Common real-world need; fully local; no cloud dependency. |
| IN-SCOPE (build) | settings-03 | Local best-effort dangerous-key approval gate before applying `managed.toml` + `managed.d` drop-ins. Local managed path can already carry dangerous keys; security-relevant. Build after settings-02 so the env classifier has an env block to inspect. |
| IN-SCOPE (build) | settings-05 | `--setting-sources` (or `--config-sources`) flag gating the four `mergeFromFile`/managed loaders. Small, isolates config for headless/SDK use. policy+flag always forced on. |
| IN-SCOPE (build) | settings-07 | Per-rule permission salvage in `permission_rules.zig` `loadFromFile`: skip one malformed rule with a warning instead of rejecting the whole file. Small, robustness win. |
| IN-SCOPE (optional) | settings-06 | `${VAR}` expansion inside config values. Low value without settings-02; build only if settings-02 lands and time allows. Scoped to the `[env]` block + helper-command values, not every key. |
| IN-SCOPE (optional) | settings-11 | Full per-key provenance (which of user/workspace/local/managed/CLI set each key) for a `/config sources` view. Useful but low priority; only managed-layer provenance exists today. |
| IN-SCOPE (optional) | settings-12 | Machine-readable settings schema export (`zcode config schema`) for editor integration. Per-error hints already exist; this is the missing export. |
| OUT-OF-SCOPE (document) | settings-04 | Native macOS plist (`plutil`) / Windows HKLM/HKCU registry (`reg query`) reads. File-based `managed.toml` already covers the Linux/macOS local story; native OS-policy plumbing is heavy OS integration for low marginal value. Document the file-based equivalent; leave a Windows-path stub. |
| OUT-OF-SCOPE (document) | settings-08 | `apiKeyHelper` / `awsCredentialExport` / `gcpAuthRefresh` / `otelHeadersHelper` are auth-credential acquisition (auth subsystem, not settings). The `statusLine` shell-command variant is the only locally meaningful piece and is itself an optional small add tied to settings-03's classifier. |
| OUT-OF-SCOPE (document) | settings-09 | Cloud settings sync (upload/download user settings + memory via Anthropic API, OAuth-gated, keyed by repo hash). First-party Anthropic cloud + OAuth dependency; inherently remote; no meaningful local equivalent. zcode's `control_plane_managed_settings_sync` covers the self-hosted PULL story. |

## Gaps covered

| id | title | severity | size | our current state |
|---|---|---|---|---|
| settings-02 | settings `env` block | high | M | No `[env]` field in `Config`; `config_parse.zig` ignores `[env]` (and all `[...]` sections); only `/env set` session vars reach spawned tools via `session_env.applyToEnvMap`. |
| settings-03 | managed-settings dangerous-key approval gate | medium | M | No dangerous-key classifier. `mergeManagedConfigSet` applies managed keys silently after SHA-256 verify; no `DANGEROUS_SHELL_SETTINGS`/`SAFE_ENV_VARS`/hooks scan, no accept/reject prompt, no `exit(1)` on reject. |
| settings-04 | MDM / OS-native policy sources | low | M | File-based managed TOML on Linux (`/etc/zcode/managed.toml`) and macOS (`/Library/Application Support/zcode/managed.toml`) with first-source-wins + key locking. No macOS plist read, no Windows registry, no Windows path (`resolveManagedConfigPath` returns null for `else`). |
| settings-05 | scope filtering via `--setting-sources` | low | S | No flag; no `CliOptions` field; `config_parse.load` merges user->workspace->local->managed unconditionally; `user_config_found`/`workspace_config_found` are report-only. |
| settings-06 | `${VAR}` expansion in settings values | low | S | None. The only `${VAR}` reference is a comment in `warnIfPlaintextSecret` exempting placeholders; no expansion performed. |
| settings-07 | per-rule permission-rule salvage | low | S | `parseLine` returns `error.InvalidPermissionRule` on the first bad rule; `loadFromFile` uses `try`, so one bad rule rejects the whole file. No per-rule warning, no salvage. |
| settings-08 | command-helper settings (statusLine/apiKeyHelper/...) | low | M | Segment-based status line via `ui_status_show_*` booleans + runtime provider callbacks; no shell-command helper keys; `applyKeyValue` does direct assignments only, zero process execution. |
| settings-09 | cloud settings sync | low | M | Only `control_plane_managed_settings_sync` (self-hosted PULL of admin settings). No OAuth Anthropic user-settings upload/download. |
| settings-11 | per-key settings provenance | low | M | Aggregate managed-file source CSV in `managed_config_sources` only; no per-key source mapping across the user/workspace/local layers. |
| settings-12 | validation tips + JSON-schema export | low | S | Per-error hints present (`main.zig:418-486`, `error_hints.zig`); plaintext-secret remediation present. No `zcode config schema` export, no schema URL. |

## Implementation tasks (in-scope gaps)

### settings-02 - Local `[env]` block merged into spawned-tool environment

**Goal.** A `[env]` table in any config layer (user/workspace/local/managed) sets environment variables that are applied to spawned tools (shell, grep, etc.), with the same precedence as the rest of config (managed wins). Provider-managed routing vars are stripped from settings-sourced env when the host owns routing (`CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST` truthy), mirroring the reference.

**Reference behavior + file:line.**
- `src/utils/settings/types.ts:333-335` - `env` key (EnvironmentVariablesSchema) on user/project/policy settings.
- `src/utils/managedEnvConstants.ts:14-70` - `PROVIDER_MANAGED_ENV_VARS` set + `VERTEX_REGION_CLAUDE_` prefix; `isProviderManagedEnvVar` strips them from settings-sourced env when host-managed.
- Reference applies settings env + session env to spawned children, never to the REPL process itself (matches zcode's existing `session_env` invariant).

**Target Zig files.**
- `src/core/config.zig` - add a `settings_env` store to `Config` (an ordered list of key/value pairs; do NOT reuse a generic map field that would desync ownership). Initialize empty in `Config.init`, free in `Config.deinit`.
- `src/core/config_parse.zig` - parse a `[env]` section: track current section in `mergeLineWithMode` (currently `[` lines are skipped wholesale at line 416). When inside `[env]`, route `KEY = "value"` into `cfg.settings_env` instead of `applyKeyValue`. Apply the provider-managed strip at merge time.
- New module `src/core/managed_env.zig` - port `PROVIDER_MANAGED_ENV_VARS` + the `VERTEX_REGION_CLAUDE_` prefix; expose `isProviderManagedEnvVar(key) bool`. Register it in the `src/main.zig` comptime block (`_ = @import("core/managed_env.zig");`). Use `@import("zcode_runtime")` only if it needs `rt.io`; it does not, so plain `const std`.
- `src/tools/shell.zig` - in `applySessionEnvToPlan` (line 550), also apply `cfg.settings_env` to the plan's `env_map`. Session vars (`/env set`) must still win over settings-sourced env (apply settings env first, then session env), matching the reference precedence where session overrides settings.

**Approach.**
1. Add `settings_env: []EnvPair` (or two parallel owned-slice lists) to `Config`; `EnvPair = struct { name: []u8, value: []u8 }`. Free each pair in `deinit`.
2. In `config_parse.zig`, thread a `current_section: ?[]const u8` through the body-merge loop. On a `[name]` line, set `current_section`. When `current_section` equals `"env"`, treat the line as `KEY = value`: validate the key (reuse the POSIX-name check from `session_env.set` - reject `=`, control bytes, empty), then upsert into `cfg.settings_env` (later layers override earlier, same as scalar keys). Outside `[env]`, keep the existing skip behavior for sections.
3. At the point a settings env pair is about to be stored, if `managed_env.isProviderManagedEnvVar(key)` AND the spawn env has `CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST` truthy (`env.isEnvTruthy`), drop it and emit a one-line stderr note. Keep the flag itself un-overridable.
4. In `shell.zig`, extend `applySessionEnvToPlan` to first merge `cfg.settings_env` into the plan env_map, then `session_env.applyToEnvMap` on top. Plumb `cfg` (or just the env pairs) to the call site; if the plan builder does not currently see `cfg`, pass the `settings_env` slice into the plan-build call.
5. Reject control bytes in env values exactly like the existing scalar-value guard (`mergeLineWithMode:435-450`).

**Acceptance criteria (write a test, make it pass).**
- A `config_parse` test: a config body with `[env]\nFOO = "bar"\nBAZ = "qux"` populates `cfg.settings_env` with two entries; a later layer setting `FOO = "override"` wins.
- A test that a settings env pair named `ANTHROPIC_BASE_URL` is stripped when `CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST=1` is in the environment and retained when it is not. (Set the env via the test process; `env.getenv` reads libc.)
- A `shell` test (or a `session_env`-style unit test on the merge helper): given `settings_env` `FOO=settings` and session `FOO=session`, the resulting plan env_map has `FOO=session` (session wins), and `BAZ=settings` passes through.
- A `managed_env` unit test: `isProviderManagedEnvVar("anthropic_base_url")` is true (case-insensitive), `isProviderManagedEnvVar("VERTEX_REGION_CLAUDE_4_5_SONNET")` is true (prefix), `isProviderManagedEnvVar("MY_VAR")` is false.

**Test strategy.** Standard `test "..."` blocks in `config_parse.zig`, `managed_env.zig`, and `session_env.zig`/`shell.zig`, run under `tools/test_runner.zig` (it installs `rt.io`/`rt.gpa`). Use `testing.allocator`. For env-var-dependent tests, set/unset the process env around the assertion; do not rely on ambient values.

**Risk + 0.16 footguns.**
- `std.process.Environ.Map.put` borrows the key/value slices; `settings_env` strings must outlive the env_map (they live on `Config`, which outlives the plan), so this is fine - but do not pass freed temporaries.
- Ownership: when a later layer overrides an env key, free the old value before replacing (mirror `session_env.set`'s OOM-safe ordering: dupe new first, then free old).
- Do not reuse `Config.setOwnedString` machinery for the pair list; it is built for single fields and a value-copy of the list could desync on realloc (see the ObjectMap footgun in CLAUDE.md).

**Size.** M.

### settings-03 - Dangerous-key approval gate for managed files

**Goal.** Before applying `managed.toml` + `managed.d` drop-ins, scan the about-to-be-applied managed keys for the dangerous class (command-helper keys, non-safe env vars, a `[hooks]` section). If anything dangerous is present AND changed versus a cached snapshot, block startup with an accept/reject prompt in interactive mode; on reject `exit(1)`. In non-interactive mode, skip the prompt (consistent with the reference's trust-dialog behavior).

**Reference behavior + file:line.**
- `src/services/remoteManagedSettings/securityCheck.tsx:22-73` - `checkManagedSettingsSecurity` returns `approved`/`rejected`/`no_check_needed`; `handleSecurityCheckResult` calls `gracefulShutdownSync(1)` on reject; non-interactive returns `no_check_needed`.
- `src/components/ManagedSettingsSecurityDialog/utils.ts:24-117` - `extractDangerousSettings` (shell settings via `DANGEROUS_SHELL_SETTINGS`, env vars NOT in `SAFE_ENV_VARS`, hooks present), `hasDangerousSettings`, `hasDangerousSettingsChanged` (JSON-compare against cached), `formatDangerousSettingsList` (names only, never values).
- `src/utils/managedEnvConstants.ts:75-191` - `DANGEROUS_SHELL_SETTINGS` (6 keys) + `SAFE_ENV_VARS` (the authoritative safe list).

**Target Zig files.**
- New module `src/core/managed_security.zig` - port `DANGEROUS_SHELL_SETTINGS`, `SAFE_ENV_VARS` (reuse the `managed_env.zig` lists where they overlap), and the extract/has/hasChanged logic adapted to zcode's TOML key model. Register in `src/main.zig` comptime block. Uses `@import("zcode_runtime")` for stderr/stdin if it owns the prompt; or keep it pure and let `main.zig` own the I/O.
- `src/core/config_parse.zig` - `mergeManagedConfigSet` is the hook point. Before applying (or after collecting the merged managed-key set), build a "dangerous summary"; if changed vs cache, return a signal up to the caller. Prefer: collect the managed body's dangerous keys during the existing key-scan loop (`mergeManagedFileInto:201-208` already iterates lines for lockable keys) rather than re-parsing.
- `src/main.zig` - own the interactive prompt and the `exit(1)` on reject, since `main.zig` already owns startup flow and `config_parse.load` is called there. Add the prompt between config load and REPL start.
- Cache file: store the last-approved dangerous summary (hash or sorted name list) under the user state dir (reuse `paths`), so an unchanged managed file does not re-prompt every launch (matches `hasDangerousSettingsChanged`).

**Approach.**
1. Define `DANGEROUS_SHELL_SETTINGS` for zcode's namespace. zcode has no `apiKeyHelper`/`statusLine` keys today, so this list is forward-looking; include the names so that if settings-08's statusLine helper ever lands it is automatically gated. Also flag any `[hooks]` section in a managed file and any settings-env key (settings-02) not in `SAFE_ENV_VARS`.
2. During managed-file ingestion, accumulate a `DangerousSummary { shell_helpers: [], unsafe_env: [], has_hooks: bool }` from the merged managed set (base + drop-ins).
3. After ingestion, compute a stable fingerprint (sorted names + a flag for hooks; never include values). Compare to the cached fingerprint. If `hasDangerous` and `changed`, prompt.
4. Prompt only when interactive (zcode already knows interactivity from CLI flags / TTY detection - reuse the same check `main.zig` uses for other startup dialogs). Print the dangerous names (NOT values), accept/reject. On accept, write the new fingerprint to cache and continue. On reject, `exit(1)`.
5. In non-interactive/headless mode, skip and continue (do not block automation), matching the reference.

**Acceptance criteria (write a test, make it pass).**
- A `managed_security` unit test: `extractDangerous` on a managed key set containing `[hooks]` returns `has_hooks = true`; on an env block with `HTTP_PROXY` (not in `SAFE_ENV_VARS`) flags it; on an env block with only `ANTHROPIC_MODEL` (in `SAFE_ENV_VARS`) flags nothing.
- A test that `hasChanged` returns false when the cached fingerprint equals the new one, true when a new dangerous key appears.
- A test that `formatDangerousList` emits names only and never the values (assert the value string does not appear in the output).
- Wiring test (integration-style): a non-interactive load of a managed file with a dangerous key proceeds without prompting and without `exit`.

**Test strategy.** Pure-logic tests in `managed_security.zig` under `tools/test_runner.zig`. The interactive-prompt path is hard to unit-test; keep the prompt thin in `main.zig` and put all classification/fingerprint logic in the testable module. Use `core/test_helpers.zig` `tmpDirPath` for the cache-file round-trip test (never pass `"."`).

**Risk + 0.16 footguns.**
- This is a security gate; failing OPEN (skipping the prompt on a logic bug) is the safe-for-availability but unsafe-for-security choice. Match the reference: skip only in genuinely non-interactive mode; otherwise prompt. Document the decision in the wiki.
- Do not log values. The reference is explicit that only names are shown.
- The cache file must be written atomically (reuse the atomic-write helper pattern in `permission_rules.zig writeFileAtomic`) so a crash mid-write does not corrupt it.
- Reading stdin for the prompt: use `core/std_io.zig` (the only place that builds readers), not raw `std.fs`.

**Size.** M.

### settings-05 - Scope filtering via `--setting-sources`

**Goal.** A `--setting-sources user,project,local` flag (and `=`-joined form) restricts which non-forced layers load. `policy` (managed) and `flag` (CLI) are always forced on, matching `getEnabledSettingSources`.

**Reference behavior + file:line.** `src/utils/settings/constants.ts:124-177` - `parseSettingSourcesFlag` (maps `user`->userSettings, `project`->projectSettings, `local`->localSettings; rejects unknown), `getEnabledSettingSources` (always adds policy + flag), `isSettingSourceEnabled` gates each loader.

**Target Zig files.**
- `src/cli/args.zig` - add `setting_sources: ?[]const u8 = null` (or a parsed bitset) to `CliOptions`; parse `--setting-sources`/`--setting-sources=` in the flag loop (around line 252, alongside `--log-level`) using the existing `parseFlagValue` helper. Validate tokens (`user|project|local`); reject unknown with a targeted error.
- `src/core/config_parse.zig` - in `load`, gate `mergeFromFile(user)`, `mergeFromFile(workspace)`, and the local-layer merge on the parsed set. Managed + CLI always apply. When `opts.setting_sources == null`, behave exactly as today (all on).

**Approach.**
1. Parse the flag into a small struct `{ user: bool, project: bool, local: bool }`. Default (flag absent) = all true.
2. In `load`, wrap each of the three file merges in `if (sources.user) ...` etc. Keep the `FileNotFound -> false` handling.
3. Leave `applyCliOverrides` and the managed block unconditional.

**Acceptance criteria (write a test, make it pass).**
- An `args` test: `--setting-sources user,project` parses to `{user:true, project:true, local:false}`; `--setting-sources=local` parses local-only; an unknown token returns an error.
- A `config_parse` test using `tmpDirPath`: with sources restricted to `user`, a workspace `config.toml` that sets a key does NOT affect the loaded config, while the user file does; managed still applies.

**Test strategy.** `args.zig` parse tests + a `config_parse.zig` integration test with real tmp files (use `core/test_helpers.zig` to get absolute tmp paths; the loader walks the filesystem so relative `"."` would point at the test process CWD).

**Risk + 0.16 footguns.** Low. Keep default behavior byte-identical when the flag is absent. `parseFlagValue` already handles both `--flag value` and `--flag=value`.

**Size.** S.

### settings-07 - Per-rule permission-rule salvage

**Goal.** A single malformed permission rule is skipped with a per-rule warning (line number + reason) and the rest of the file still loads, instead of one bad rule rejecting the entire file.

**Reference behavior + file:line.** `src/utils/settings/validation.ts:224-265` - `filterInvalidPermissionRules` strips non-string and syntactically-invalid `allow`/`deny`/`ask` entries with a per-rule warning, keeps valid ones; `permissionValidation.ts` `validatePermissionRule` does the syntax check.

**Target Zig files.** `src/core/permission_rules.zig` - `loadFromFile` (lines 99-114) and `parseLine` (191-208).

**Approach.**
1. In `loadFromFile`, change `try self.parseLine(...)` to a `catch` that, on `error.InvalidPermissionRule` (and the related parse errors from `parseScope`/`Action.parse`/`validateField`), emits a one-line stderr warning naming the file + line number + the offending content, then `continue`s to the next line. Propagate only genuinely fatal errors (OOM, read errors).
2. Keep `parseLine` returning the error; the salvage happens at the call site so the inner function stays simple and testable.
3. Match the reference's "skipped, not failed" wording in the warning.

**Acceptance criteria (write a test, make it pass).**
- A `permission_rules` test using `tmpDirPath`: a rules file with three lines where the middle line is malformed (wrong field count or bad scope) loads successfully, the store contains the two valid rules, and the bad one is absent. Reuse the file format from `saveToFile` for the valid lines.
- A test that a file of all-invalid rules loads to an empty store without returning an error.

**Test strategy.** `permission_rules.zig` test blocks with a real temp file via `core/test_helpers.zig`. Capturing the warning text is optional; asserting the surviving rule count is the core check.

**Risk + 0.16 footguns.** Low. Ensure the partial `Rule` allocated in `addRule` is properly `errdefer`-freed on the bad path (it already is). Do not leak the `readFileAlloc` buffer (the existing `defer self.allocator.free(bytes)` covers it).

**Size.** S.

### settings-06 - `${VAR}` expansion (optional, build only after settings-02)

**Goal.** Shell-style `${VAR}` (and `$VAR`) references inside `[env]` values and any helper-command value are expanded against the process environment at load time, so a managed file can write `PATH = "${HOME}/bin:..."`.

**Reference behavior + file:line.** Implied by `src/utils/settings/types.ts` env/command schemas and `managedEnvConstants.ts` provider-managed handling; the reference substitutes value placeholders. zcode currently only has the placeholder-aware comment in `warnIfPlaintextSecret`.

**Target Zig files.** `src/core/config_parse.zig` (a new `expandEnvVars(allocator, value) ![]u8` helper applied to `[env]` values from settings-02); reuse `core/env.zig getenv`.

**Approach.**
1. Add `expandEnvVars` that scans for `${NAME}` (and optionally `$NAME` with a conservative name charset), looks each up via `env.getenv`, and substitutes; an undefined var expands to empty (match POSIX) with a one-line warning, or is left literal - pick one and document it. Recommend: undefined -> empty, with a warning, to match shell `set -u` off behavior.
2. Apply ONLY to `[env]` values (and future helper-command values), not to every scalar key, to avoid surprising existing configs.

**Acceptance criteria (write a test, make it pass).** A `config_parse` test: with `HOME=/u/test` in the process env, an `[env]` value `"${HOME}/bin"` expands to `/u/test/bin`; an undefined `${NOPE}` expands to empty (or literal, per the documented choice).

**Test strategy.** Set/unset env around the test; `testing.allocator`. Pure string function, easy to unit-test in isolation.

**Risk + 0.16 footguns.** Scope creep - keep it to the env block. Avoid double-expansion. Free intermediate buffers.

**Size.** S.

### settings-11 / settings-12 (optional)

These are low-priority polish; build only if the four core items land with time to spare.

- **settings-11 (per-key provenance, M):** add an optional `source_of_key: StringHashMap([]const u8)` populated in `mergeLineWithMode` (tagging each applied key with its layer: `user`/`workspace`/`local`/`managed`/`cli`). Surface via a `/config sources` view reusing `config.zig renderAll` (line 460) formatting. Acceptance: a test that loading a key in the workspace layer and overriding it in managed reports the source as `managed`.
- **settings-12 (schema export, S):** add a `zcode config schema` subcommand that emits a JSON Schema enumerating every key in `applyKeyValue` (type per parser: bool/int/string, plus enum hints already in `main.zig:418-486`). No external URL/schemastore registration. Acceptance: a test that the emitted schema is valid JSON and contains every key name `applyKeyValue` accepts (keep the two in sync via a comptime list if practical).

## Documented deviations (out-of-scope)

**settings-04 - Native OS policy sources.** zcode reads managed policy from a file (`/etc/zcode/managed.toml`, `/Library/Application Support/zcode/managed.toml`, or `ZCODE_MANAGED_CONFIG`) with first-source-wins, key locking, SHA-256 sidecar verification, and a `managed.d` drop-in dir. The reference additionally reads macOS `/Library/Managed Preferences/<user>/com.anthropic.claudecode.plist` via `plutil` and Windows `HKLM\SOFTWARE\Policies\ClaudeCode` + `HKCU` via `reg query` (`mdm/settings.ts:1-273`, `mdm/constants.ts`). These are heavy OS-integration subprocess reads for low marginal value over the file path (the reference itself falls back to a file on Linux). **Local stub worth doing:** define the Windows managed path in `resolveManagedConfigPath` (currently returns null for `else`) so Windows at least gets the file-based managed.toml path; the native registry/plist reads stay deferred. Document in the wiki that fleet operators on macOS/Windows should deploy `managed.toml` via their MDM's file-push mechanism (Jamf/Intune file payloads) rather than expecting plist/registry reads.

**settings-08 - Command-helper settings.** `apiKeyHelper`, `awsCredentialExport`, `gcpAuthRefresh`, `otelHeadersHelper` are credential-acquisition helpers belonging to the auth subsystem, not settings; out of scope here. The `statusLine` shell-command variant is the only locally meaningful piece: zcode renders a segment-based status line from `ui_status_show_*` booleans + runtime provider callbacks, with no shell execution. **Local stub worth doing (optional):** a `statusLine` config key that runs a command and renders its stdout could be a small add, but it MUST be registered in settings-03's `DANGEROUS_SHELL_SETTINGS` so it is gated. Defer until settings-03 lands.

**settings-09 - Cloud settings sync.** Upload/download of user settings + memory via the first-party Anthropic API, OAuth-gated, keyed by project repo hash (`settingsSync/index.ts:60-120`). Inherently a remote first-party feature with an OAuth dependency; no meaningful local equivalent. zcode's `control_plane_managed_settings_sync` already covers the self-hosted admin-settings PULL story. `cc_stub_commands.zig` already documents the missing Anthropic cloud session sync. No work; keep documented as a deliberate non-goal.

## Verification

Per CLAUDE.md, after each in-scope item:

1. Bump `.version` patch in `build.zig.zon`.
2. Build release: `zig build -Doptimize=ReleaseFast`.
3. Install with a fresh inode (macOS signature footgun): `rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode`.
4. Run the full test suite under the custom runner: `zig build test` (watch for `RUN: <name>` lines and any hang).

Manual checks:
- **settings-02:** create a workspace `config.toml` with `[env]\nFOO = "bar"`, run a shell tool (e.g. `echo $FOO`) and confirm `bar`; export `CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST=1` and add `[env]\nANTHROPIC_BASE_URL = "http://evil"` and confirm it is stripped with a stderr note.
- **settings-03:** deploy a `managed.toml` containing a `[hooks]` section (with a valid SHA-256 sidecar), run interactively, confirm the accept/reject prompt appears showing names only; reject and confirm `exit 1`; accept, re-run, confirm no re-prompt (fingerprint cached); run with `--quiet`/non-interactive and confirm no prompt.
- **settings-05:** `zcode --setting-sources user config show` (or `config path`) and confirm a workspace-only key is absent; confirm managed keys still apply.
- **settings-07:** write a permission rules file with one malformed line, start zcode, confirm a per-rule warning on stderr and that valid rules still load (`/permissions` list or a rules-dependent action).
- **settings-06 (if built):** `[env]\nP = "${HOME}/x"` resolves in a spawned shell.

Confirm `zig build` (default) still compiles, and re-run `zcode version` after install to verify the binary is not SIGKILLed (the in-place-overwrite signature footgun).
