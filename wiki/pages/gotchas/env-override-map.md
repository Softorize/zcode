---
title: In-process env override map shadows getenv
tags: [gotcha]
created: 2026-05-31
updated: 2026-05-31
sources:
  - src/core/env.zig:40 (getenv consults the override first)
  - src/sdk/structured_io.zig (applyEnvUpdates / EnvUpdateHandler)
---

# In-process env override map shadows getenv

## Summary
`core/env.zig` keeps a process-global override map (`std.StringHashMapUnmanaged([]u8)`)
that `getenv` consults BEFORE falling back to libc `getenv`. Setting an override
(`env.setOverride(name, value)`) shadows the real environment value for every
caller that goes through `env.getenv` / `env.getOwned` (~40 call sites). It never
mutates the real process environment (libc has no portable, hot-path setenv here).

## Key points
- The override exists to serve the SDK control protocol's
  `update_environment_variables` stdin message (sdk-headless-13), whose reference
  use is auth-token refresh (e.g. `CLAUDE_CODE_SESSION_ACCESS_TOKEN`) that the
  running process itself must read, not just child subprocesses.
- The map is guarded by `std.Io.Mutex` (NOT `std.Thread.Mutex`, which does not
  exist in this std build -- see [[io-mutex-not-thread-mutex]]). Mutation is on the
  single-threaded stdin dispatch path; reads can be concurrent.
- It depends on `rt.gpa` / `rt.io`, so it only works once the runtime singleton is
  installed (main, or `rt.installForTest` via the custom test runner).
- Tests that call `setOverride` MUST `defer env.clearOverrides()` because the map
  is process-global and would otherwise leak across cases and pollute later
  `getenv` lookups.

## Details
`update_environment_variables` is parsed in `src/sdk/structured_io.zig`
`applyEnvUpdates`: it reads the `variables` object (per `controlSchemas.ts:629`,
the field is `variables`, not `vars`), applies each string-valued entry via
`env.setOverride`, and logs only the applied key NAMES to stderr -- never the
values, which may be secrets (matches `structuredIO.ts:358`). Non-string entries
are skipped; a missing/non-object `variables` field is a tolerated no-op so a
malformed line cannot crash the read loop. `keep_alive` is a pure no-op.

## Related
- [[io-mutex-not-thread-mutex]] - why the guard is `std.Io.Mutex`

## Sources
- src/core/env.zig - override map + getenv fallthrough
- src/sdk/structured_io.zig - applyEnvUpdates / EnvUpdateHandler / keep_alive
