# Zig 0.16 migration notes

zcode runs on Zig 0.16.0 ("Juicy Main"). This page captures the load-bearing
design choices made during the 0.15 → 0.16 migration so future contributors
do not relitigate them.

## Boot pattern

```zig
pub fn main(init: std.process.Init) !void {
    rt.install(init);           // io + gpa singletons
    rt.setArgv(argv);           // captured once for diag tools
    // ... normal main body
}
```

The first parameter is the new `std.process.Init`. It carries:
- `init.io` — the platform's selected `std.Io` backend (threaded on macOS, threaded or io_uring on Linux).
- `init.gpa` — a default general-purpose allocator with leak checking in Debug.
- `init.environ_map` — environment variables already parsed.
- `init.minimal.args.vector` — argv as a sentinel-terminated pointer vector.
- `init.arena` — process-lifetime arena.

## Runtime singleton

`src/core/runtime.zig` exposes `pub var io: std.Io` and `pub var gpa: Allocator`
as package-globals. Every shim (`core/clock.zig`, `core/rng.zig`,
`core/std_io.zig`) pulls from `rt.io` so we did not have to thread the `io`
parameter through ~1285 call sites in the migration PR.

This is **deliberate technical debt**. Stage 4 of the migration plan retires
it by passing `io` explicitly. Until then, the singleton is the only way
zcode threads I/O.

The module is exposed in `build.zig` as a named module `zcode_runtime`. All
source imports use `@import("zcode_runtime")`, not relative paths, so the
custom test runner (in `tools/test_runner.zig`) can also import it.

## Custom test runner

`zig test` ships a runner that takes `std.process.Init.Minimal` (no `io`). Our
tests need `rt.io` to be valid, so we configure a custom runner in `build.zig`:

```zig
.test_runner = .{ .path = b.path("tools/test_runner.zig"), .mode = .simple },
```

`tools/test_runner.zig` calls `rt.installForTest()` (which lazily builds a
`std.Io.Threaded` backend from `std.heap.smp_allocator`) before iterating
`builtin.test_functions`. It also prints `RUN: <name>` before each test so a
hang or panic identifies itself.

The runner also stubs out `std.testing.fuzz` to a no-op so `core/fuzz_tests.zig`
and friends compile against the new `Smith`-based signature without needing the
fuzz subsystem.

## Reuse points (do not reinvent)

| Module | Replaces | API |
|--------|----------|-----|
| `core/std_io.zig` | `File.deprecatedWriter/Reader` | `StderrWriter`, `StdoutWriter`, `StdinReader`, `StringBuilder` |
| `core/clock.zig` | `std.time.*` | `nowNanos() i128`, `nowMillis() i64`, `nowSeconds() i64`, `Timer` |
| `core/rng.zig` | `std.crypto.random.*` | `bytes()`, `secureBytes()`, `intRangeAtMost`, `uintLessThanBiased` |
| `core/test_helpers.zig` | `tmp.dir.realpathAlloc` | `tmpDirCwd(alloc, &tmp)`, `tmpDirPath(alloc, &tmp, sub)` |

## 0.16 gotchas hit during migration

- **`Child.kill(io)` reaps internally.** Do not call `wait()` after — it asserts
  `id != null` and panics. (Old 0.15 code commonly did `kill(); _ = wait();`.)
- **`readFileAlloc(.limited(N))` returns `error.StreamTooLong`**, not
  `error.FileTooBig`. Catch the right one.
- **`readPositionalAll(file, io, buf, 0)` in a loop reads byte 0 forever.**
  Track offset across iterations. For pipes use `readStreaming` since pread is
  `ESPIPE` on pipes.
- **`std.process.Child.init` is gone.** Use `std.process.run(allocator, io, opts)`
  for one-shot, `std.process.spawn(io, opts)` for long-lived.
- **`std.process.getEnvMap(alloc)` is gone.** Use
  `std.process.Environ.Map.init(alloc)` for an empty map, or
  `init.environ_map` from main.
- **`Environ.Map.remove` is gone.** Use `swapRemove`.
- **`Child.Cwd` is a union.** Pass `.{ .path = "..." }`, not a raw string.
- **`Io.Timeout.duration`** wraps `Io.Clock.Duration` which has
  `{ .raw, .clock }` fields. Spell it out:
  `.{ .duration = .{ .raw = .{ .nanoseconds = N }, .clock = .awake } }`.
- **`std.fs.path.relative` now takes 5 args:** `(gpa, cwd, environ_map, from, to)`.
- **`std.json.ObjectMap.put` after parseFromSlice:** take
  `&parsed.value.object` by pointer. A value copy desyncs the entries pointer
  on realloc and crashes `Stringify`.
- **`File.updateTimes` is gone.** Use `file.setTimestamps(io, .{ .access_timestamp = ..., .modify_timestamp = ... })`.
  `Io.Timestamp.nanoseconds` is `i96`, so cast from `i128` with `@intCast`.
- **`File.Stat.mode` is gone.** Use `stat.permissions.toMode()`.
- **`std.process.Init.Minimal` test-runner default has no `io`.** Tests that
  use `rt.io` must go through our custom runner (`tools/test_runner.zig`).
- **`std.Io.Dir.realPathFileAbsolute` asserts the path is absolute.** Branch
  on `std.fs.path.isAbsolute(path)` and use `Dir.cwd().realPathFile` for
  relative paths.
- **`pub fn main` test_runner mode `.simple`** is required so the runner gets
  no init parameter (otherwise `start.zig`'s `wrapMain` complains).

## Stage 5g: concurrent tool execution

`std.Thread.Pool` / `WaitGroup` were removed in 0.16. `tools/concurrent_executor.zig`
no longer uses them; it spawns up to `MAX_CONCURRENT_THREADS` threads per batch
via `std.Thread.spawn`, joins them, then advances to the next batch. The pool
abstraction is gone; per-call spawn keeps cleanup linear.

## Stage 5 async stage status

All Stage 5 stages are functionally complete on the threaded `std.Io`
backend. Each stage's poll/thread loop is the correct shape for the
threaded backend; the plan's "collapse onto std.Io futures" rewrite is a
no-op when futures themselves resolve to thread spawn.

| Stage | File | Status |
|-------|------|--------|
| 5a | shell.zig | std.process.run with timeout (replaces collectWithTimeout) |
| 5b | providers/common.zig | readStreaming on child stdout (no separate pump thread) |
| 5c | browser_bridge.zig | accept thread + posix.poll shutdown timeout |
| 5d | mcp/oauth.zig | acceptWithTimeout already a single-threaded posix.poll |
| 5e | remote_daemon.zig | Per-connection worker thread spawn (was serialized) |
| 5f | cli/repl_spinner.zig | posix.poll non-blocking stdin reads |
| 5g | tools/concurrent_executor.zig | std.Thread.spawn batches up to MAX_CONCURRENT_THREADS |

## Stage 4: explicit-io API

`core/clock.zig` and `core/rng.zig` now expose `*Io` variants of every
public function that take `io: std.Io` explicitly:

- `clock.nowSecondsIo(io)`, `clock.nowMillisIo(io)`, `clock.nowNanosIo(io)`
- `rng.secureBytesIo(io, dst)`, `rng.bytesIo(io, dst)`

The singleton-backed wrappers (`clock.nowSeconds()`, `rng.bytes(dst)`,
etc.) delegate to the `*Io` variants. New code that has `io` in scope
can call the explicit variants directly; legacy callers continue to use
the singleton.

Full deletion of `core/runtime.zig` is deferred because it cascades through
~1285 call sites without changing behavior. The `*Io` variants give an
incremental path forward.
