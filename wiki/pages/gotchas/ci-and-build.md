---
title: CI and build gotchas
tags: [gotcha, runbook]
created: 2026-05-23
updated: 2026-05-29
sources:
  - src/providers/common.zig:83 (linux SIG enum)
  - src/core/config_migrations.zig (trimStart usage)
  - .github/workflows/ci.yml
---

# CI and build gotchas

## Summary
Hard-won facts about building and getting CI green on zcode. Several CI checks
are red for reasons unrelated to your change; know which ones to trust.

## Key points

- **Build with the pinned 0.16 binary**, not homebrew zig:
  `/Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig`. Homebrew is 0.15.x and
  will not compile this repo.
- **Run `zig fmt --check build.zig src tests` before every push.** CI's
  `build-and-test` runs it as the FIRST step and fails fast (~40s) on any drift.
  Hand-edited files frequently drift (e.g. `zig fmt` reflows a labelled-block
  `blk: {` onto its own line). This cost a CI round-trip; check locally first.
- **`build-and-test (macOS)` runs the full suite; trust it.** `reproducible build`
  does the `x86_64-linux ReleaseSafe` cross-compile; trust it for "does it build
  on Linux." Verify both locally:
  `zig build -Doptimize=ReleaseFast` and
  `zig build -Dtarget=x86_64-linux -Doptimize=ReleaseSafe`.
- **`build-and-test (ubuntu)` is expected RED** due to a pre-existing Linux-only
  test hang in `api_server.test "api security audit event excludes credential
  material"` (tracked in GitHub issue #527). It was latent until the Linux build
  was fixed (the build never compiled before, so Linux tests never ran). macOS
  runs the same test fine. Do not block merges on it.
- **The `review` check is a secret-dependent self-review action** (`zcode-pr-review.yml`,
  runs zcode against the branch with an OpenAI key). It fails on *every* PR
  including dependabot when the build/secret isn't right. Not a meaningful merge
  gate. When it does pass it means the build + key were both fine.
- **"CI green" for merging = the deterministic checks**: `build-and-test (macOS)`,
  `reproducible build`, both `CodeQL`, `security scan` (and `review` when it
  cooperates). Ignore `build-and-test (ubuntu)` until #527 is fixed.
- **No branch protection** (private free-tier repo), so `gh pr merge --squash`
  works even with the ubuntu check red.

- **macOS: `rm -f` the install target before `cp`.** Overwriting the existing
  `~/.local/bin/zcode` in place can invalidate the binary's ad-hoc code
  signature, so the next run is SIGKILLed ("Killed: 9", exit 137) with ZERO
  output -- even `zcode version`. It is intermittent (some installs survive),
  which makes it look like a runtime crash in whatever you just changed. It is
  not: run the binary from `zig-out/bin/zcode` directly to confirm it is fine,
  then `rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode`.
  `cmp zig-out/bin/zcode ~/.local/bin/zcode` reporting "differ" right after a cp
  is the tell.

## Details

The 0.16 `std.os.linux.kill` signature change is a recurring footgun: it now
takes a `SIG` enum, so `std.os.linux.kill(pid, 15)` fails to compile *on Linux
only* (the branch is comptime-pruned on macOS). Use `.TERM`. This is the kind of
bug that passes local macOS builds but breaks the Linux cross-compile.

`std.mem.trimLeft` / `std.mem.trimRight` were renamed in 0.16 to
`std.mem.trimStart` / `std.mem.trimEnd`. `std.mem.trim` (both sides) is
unchanged. Old code (and habits) using `trimLeft` fail with "struct 'mem' has
no member named 'trimLeft'".

## Related
- [[architecture]] - overall system shape

## Sources
- src/providers/common.zig:83 - the linux kill SIG fix
- GitHub issue #527 - the ubuntu api_server test hang
