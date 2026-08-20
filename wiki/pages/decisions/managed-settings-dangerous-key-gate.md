# Decision: managed-settings dangerous-key approval gate (settings-03)

## What

Before applying an admin-pushed `managed.toml` (+ `managed.d` drop-ins) for real,
zcode scans the about-to-be-applied keys for a dangerous class and, if that set
changed since the last approval, prompts the interactive user to accept/reject.
On reject it `exit(1)`s. Non-interactive runs never prompt.

Dangerous class (ported from `managedEnvConstants.ts` + `ManagedSettingsSecurityDialog/utils.ts`):
- command-helper keys (`statusLine`, `apiKeyHelper`, `awsAuthRefresh`,
  `awsCredentialExport`, `gcpAuthRefresh`, `otelHeadersHelper`) - case-sensitive camelCase,
- any `[env]` key NOT on `SAFE_ENV_VARS` (case-insensitive) - e.g. `HTTP_PROXY`, `ANTHROPIC_BASE_URL`,
- presence of a `[hooks]` section.

## Where

- `src/core/managed_security.zig` - pure classification + fingerprint + cache I/O (all unit-tested).
- `src/core/config_parse.zig` `mergeManagedFileInto` - accumulates the `DangerousSummary`
  during the existing single line-scan (the one that also collects lockable keys),
  tracking the current `[section]`. `mergeManagedConfigSet` returns `?DangerousSummary`
  (it used to return `bool`; callers/tests had to switch to `.?` + `summary.deinit()`).
- `src/core/config.zig` `LoadedConfig.managed_dangerous` carries it out of `load`; freed in `deinit`.
- `src/main.zig` `maybeGateManagedDangerousSettings` owns the interactivity check, the prompt I/O,
  and the `exit(1)`. Kept thin on purpose: the prompt path is not unit-testable.

## Why these choices

- **Fail-open in non-interactive, fail-closed only on explicit reject.** Matches the reference's
  `no_check_needed` for non-interactive. Blocking automation on a managed file would break headless/CI.
  Security is enforced where a human can answer; availability is preserved where none can.
- **Names only, never values.** The prompt and the fingerprint never include env values or helper
  command strings (the reference is explicit). `DangerousSummary.formatDangerousList` /
  `.fingerprint` carry names only.
- **Order-stable fingerprint.** Sorted names + a `hooks` marker joined with newlines, so reordering
  drop-ins does not re-prompt. The reference JSON-compares; we sort to be ingestion-order-independent.
- **Cache** lives at `<zcode_home>/managed_approval.fingerprint`, written atomically (tmp+rename, 0600).
  A corrupt/unreadable cache reads as null -> re-prompt (the security-safe direction).

## Gotcha: `[hooks]` body would fail closed before the gate

zcode's managed parser is strict: an unknown scalar key in a managed file is
`error.UnknownManagedConfigKey` and fails closed. A `[hooks]` section's body lines
(`PreToolUse = "..."`) are not recognized scalar keys, so a managed file carrying hooks
used to fail to load entirely - before the approval gate could ever run. Fix:
`mergeLineWithMode` now SKIPS body lines inside a `[hooks]` section (recognized-but-not-applied,
same shape as `[env]` but without applying), because zcode has no parsed hooks model yet.
The dangerous scan still flags the section's presence. Revisit when a real hooks subsystem lands.

## Interactivity definition used

`opts.command == .repl AND !quiet AND !json AND isatty(stderr) AND isatty(stdin)`. This is the
local stand-in for the reference's `getIsInteractive()` at the post-config-validate point in main.
