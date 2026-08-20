# Hermetic HOME override for settings.json source tests

When testing anything that reads the **user** or **policy** settings.json source
(`core/settings_sources.zig` `.user` / `.policy`, or `core/hooks.zig`
`runConfiguredFromSources`), those paths resolve through
`core/paths.zig::resolve`, which keys off the real `HOME` (libc `getenv`) and
falls back to `{HOME}/.zcode`. Pointing them at a tmp dir is the only way to make
such a test hermetic - the `cwd` argument only controls the project/local
sources (`{cwd}/.claude/settings.json` and `settings.local.json`), not user/policy.

## Technique

Set `HOME` to the tmp dir and clear `XDG_CONFIG_HOME` for the duration of the
test, then create `{HOME}/.zcode` so `paths.resolve` pins `zcode_home` there
(it prefers an existing `{HOME}/.zcode` over the XDG path). Restore both env
vars on `defer`.

- `paths.resolve` precedence: existing `{HOME}/.zcode` wins, else
  `$XDG_CONFIG_HOME/zcode`, else `{HOME}/.zcode`. Creating the dir is what makes
  it deterministic.
- Use libc `setenv`/`unsetenv` externs (same pattern as
  `tools/bash_security.zig`, `tools/file.zig`). `setenv` needs a NUL-terminated
  key/value - `allocator.dupeZ`. Tests run serially under
  `tools/test_runner.zig`, so a defer-restore env override is safe.
- The user source then lives at `{HOME}/.zcode/settings.json`, the policy source
  at `{HOME}/.zcode/policy/settings.json`, and the hook-trust store at
  `{HOME}/.zcode/trust/hooks.json` - all under the tmp tree.

See `HomeOverride` in `core/hooks.zig` tests for the reusable shape.

## Trust gate for project/local settings.json hooks

Project/local settings.json hooks are workspace-derived untrusted code. The
trust unit is the **settings.json file itself** (its command strings are what
execute), so `runConfiguredFromSources` calls
`security.isHookTrusted(allocator, cwd, settingsJsonPath, scopeName)`. To make a
project hook run in a test, call `security.allowHook(alloc, cwd, settingsJsonPath)`
first - it fingerprints the file and records trust. User/flag/policy sources are
trusted implicitly (own home / operator-supplied `--settings` flag / managed).

## Hook source gates (reference parity)

`runConfiguredFromSources` mirrors `getHooksFromAllowedSources`
(hooksConfigSnapshot.ts:18-53):
- policy `disableAllHooks: true` -> run nothing.
- policy `allowManagedHooksOnly: true` -> keep only policy-scope hooks.
- any non-policy `disableAllHooks: true` -> keep only policy-scope hooks.
- else -> run all sources merged.
