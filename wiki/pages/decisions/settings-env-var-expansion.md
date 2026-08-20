# Decision: `${VAR}` expansion in `[env]` settings values (settings-06)

## Context
Phase 18 (settings depth) added a settings-sourced `[env]` block (settings-02).
settings-06 layers shell-style variable expansion on top so a config file can
write `PATH = "${HOME}/bin"` and have it resolved against the process
environment at load time.

## What was built
- `expandEnvVars(allocator, value) ![]u8` in `src/core/config_parse.zig`.
- Applied ONLY inside `applySettingsEnvLine` (the `[env]` routing path), right
  before `cfg.upsertSettingsEnv`. Scalar config keys are NOT expanded.

## Decisions (the non-obvious bits)
- **Scope is intentionally narrow.** Expansion runs for `[env]` values only.
  Expanding every scalar key would silently rewrite existing configs and
  surprise users (a literal `$` in, say, a model name or prompt label). The
  reference also scopes substitution to env/command values.
- **Undefined variable -> empty string + one-line stderr warning.** This
  mirrors POSIX shell with `set -u` off. The alternative (leave the reference
  literal) was rejected because a literal `${NOPE}` leaking into a child
  process env is more confusing than an empty value plus a visible warning.
- **Both `${NAME}` and `$NAME` forms** are supported. `$NAME` uses a
  conservative POSIX name charset (`[A-Za-z_][A-Za-z0-9_]*`); a bare `$`, `$`
  followed by a non-name byte (e.g. `$1`), or `${` with no closing brace are
  all left literal. This avoids eating the rest of the string on a stray `$`.
- **No double-expansion.** The expanded value is stored as-is; we do not
  re-scan it for further `${...}`.

## Ordering / ownership footguns
- `expandEnvVars` always returns a FRESH allocation (even when there is no
  reference), so the call site frees it unconditionally with `defer
  allocator.free(expanded)`. `upsertSettingsEnv` dupes internally, so the
  intermediate buffer is safe to free immediately after.
- The provider-managed strip guard runs on the KEY before expansion, so a
  stripped routing var (`ANTHROPIC_BASE_URL` when host owns routing) never
  pays the expansion cost.
- `env.getenv` borrows libc static storage; we copy into the StringBuilder
  immediately, so retaining it is fine here.

## Tests
`config_parse.zig`:
- `settings-06: expandEnvVars substitutes set vars and empties unset ones`
  (covers `${NAME}`, `$NAME`, undefined-empty, no-reference, literal-`$` cases).
- `settings-06: [env] value expands ${VAR} at merge time` (end-to-end through
  `mergeConfigBody` into `settings_env`).
