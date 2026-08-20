# Project Instructions

## Toolchain
**Zig 0.16.0 ("Juicy Main") required** (`minimum_zig_version = "0.16.0"` in `build.zig.zon`). The current working zig binary on this machine: `/Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig`. Stock homebrew `zig` is still 0.15.x and will fail to compile.

## Boot pattern (0.16)
`src/main.zig` uses Juicy Main: `pub fn main(init: std.process.Init) !void`. `init.io`, `init.gpa`, `init.environ_map`, and `init.minimal.args.vector` are all available without re-deriving from the process.

## Runtime singleton (transitional)
`src/core/runtime.zig` exposes `pub var io: std.Io` and `pub var gpa: Allocator`, installed once from main via `rt.install(init)`. Tests call `rt.installForTest()` from `tools/test_runner.zig` (custom test runner wired in `build.zig`) so file/process IO works without going through `main`.

The runtime is exposed as a named module `zcode_runtime` so the test runner (in `tools/`) can import it without crossing module paths. **All source imports use `@import("zcode_runtime")`, not relative paths.**

Stage 4 of the 0.16 migration plan will retire this singleton by threading `io` explicitly through ~1285 call sites — until then, every shim (`core/clock.zig`, `core/rng.zig`, `core/std_io.zig`) reads from `rt.io`.

## Reuse points (do not reinvent)
- `core/std_io.zig` — the only place that builds `std.Io.Writer/Reader` from stdout/stderr/stdin. Includes the `StringBuilder` facade backed by `std.Io.Writer.Allocating`.
- `core/clock.zig` — wraps `std.Io.Timestamp.now`. Use `clock.nowNanos()` / `clock.nowMillis()` instead of `std.time.*`.
- `core/rng.zig` — wraps `std.Io.random / randomSecure`. Use `rng.bytes()` / `rng.secureBytes()` instead of `std.crypto.random.*`.
- `core/test_helpers.zig` — `tmpDirCwd` / `tmpDirPath` resolve a `testing.TmpDir` to a real absolute path. **Do not pass `"."` or `"repo"` as cwd to code that walks the filesystem — it's relative to the test process CWD, not the tmp dir.**

## Custom test runner
Tests run under `tools/test_runner.zig` (configured via `build.zig` `test_runner` option). It installs `rt.io`/`rt.gpa`, prints `RUN: <name>` before each test for hang diagnostics, and stubs out `testing.fuzz` to a corpus-skip no-op.

## 0.16 gotchas hit during migration
- `Child.kill(io)` reaps the child internally. Do **not** call `wait()` after — it asserts `id != null` and panics.
- `readFileAlloc(.limited(N))` returns `error.StreamTooLong`, not `error.FileTooBig`.
- `readPositionalAll(file, io, buf, 0)` in a loop reads byte 0 forever. Track offset across iterations. For pipes use `readStreaming(io, &.{&buf})` since pread is ESPIPE on pipes.
- `std.process.Child.init` is gone; use `std.process.run(allocator, io, opts)` (one-shot) or `std.process.spawn(io, opts)` (long-lived).
- `std.process.getEnvMap(alloc)` is gone; use `std.process.Environ.Map.init(alloc)` (empty) or accept `init.environ_map`.
- `Environ.Map.remove` is gone; use `swapRemove`.
- `Child.Cwd` is a union: pass `.{ .path = "..." }`, not a raw string.
- `Io.Timeout.duration` wraps `Io.Clock.Duration` which has `{ .raw, .clock }` fields.
- `std.fs.path.relative` now takes `(gpa, cwd, environ_map, from, to)` — 5 args.
- File ObjectMap.put after parse: take `&parsed.value.object` by pointer (a value copy desyncs entries pointer on realloc).

## Version Bumping
**Bump the patch number in `build.zig.zon` (`.version = "X.Y.Z"`) for every change.** `build.zig` reads that value and appends the git short-hash automatically, so the user-facing version is always `X.Y.Z+<hash>` with no manual hash work. Do not edit the `computeVersionString` function in `build.zig` directly -- it just reads the manifest.

## Install After Build
**ALWAYS build the release binary and install it on the user's machine after every change:**
``` 
zig build -Doptimize=ReleaseFast
rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode
```
The user expects the latest version to be running locally after every task.

**macOS footgun:** `cp` overwriting the existing binary IN PLACE can invalidate its ad-hoc code signature, so the next run is SIGKILLed ("Killed: 9", exit 137) with zero output -- even for `zcode version`. Always `rm -f` the destination first (or install via a temp file + `mv`) so a fresh inode gets the valid signature.
