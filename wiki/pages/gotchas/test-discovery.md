---
title: Test discovery needs explicit registration
tags: [gotcha]
created: 2026-05-23
updated: 2026-05-30
sources:
  - src/main.zig:41 (comptime reachability registry)
  - build.zig:52 (main_tests root = src/main.zig)
  - src/remote_daemon.zig (used-but-undiscovered case, Phase 12 Task 19)
---

# Test discovery needs explicit registration

## Summary
`zig build test` does NOT run a file's `test {}` blocks just because the file is
transitively imported from the test root (`src/main.zig`). Many modules are only
reached through function-body `@import`s, which the test root does not analyze, so
their tests are silently skipped. zcode works around this with a comptime
reachability registry in `src/main.zig`. If you add a module with tests, register
it there or the tests never run (and you will think they pass).

## Key points

- The registry is a `comptime { _ = @import("..."); ... }` block near the top of
  `src/main.zig` (around line 41). Paths are relative to `src/`.
- Symptom of the trap: `zig build test` reports all-green, but
  `zig build test 2>&1 | grep -i yourmodule` returns nothing -- the tests were
  never compiled in, not passed.
- This bit KAIROS: `core/cron.zig` is only reached via
  `tool_dispatch.getCronStore` (a function-body path), so its tests had been
  dormant for a long time. Registering `core/cron.zig` surfaced ~6 pre-existing
  tests that had never run.
- A top-level `const x = @import("file.zig")` that is genuinely USED at runtime
  (e.g. `const remote_daemon = @import("remote_daemon.zig")` in `src/main.zig`,
  called from the daemon serve path) is STILL not enough for test discovery: the
  test root analyzes referenced decls, not `test {}` blocks, so the file's tests
  remain silently skipped until it is added to the comptime `_ = @import(...)`
  block. Discovered during Phase 12 Task 19 (direct-connect server): `remote_daemon.zig`
  had 6 pre-existing tests that had never run; registering it surfaced them.
- Verify a new module's tests actually execute:
  `zig build test 2>&1 | grep -i <module-or-test-name>` and confirm `RUN:` lines
  appear. Do not trust the pass count alone.
- There are two test targets (`main_tests` rooted at `src/main.zig`, and
  `integration_tests` at `tests/integration_test.zig`); the combined `test` step
  prints a summary line per target.

## Related
- [[ci-and-build]] - other build/CI footguns

## Sources
- src/main.zig:41 - the comptime registry block, with per-module rationale comments
- build.zig:52 - addTest root is src/main.zig
