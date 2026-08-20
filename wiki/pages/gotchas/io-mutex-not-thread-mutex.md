# Gotcha: use `std.Io.Mutex`, not `std.Thread.Mutex` (Zig 0.16)

In Zig 0.16 the codebase uses `std.Io.Mutex` for all process-global locks, NOT
`std.Thread.Mutex` (which does not exist as a member in this std build -- a
`std.Thread.Mutex` reference fails to compile with "struct 'Thread' has no
member named 'Mutex'").

## Pattern

```zig
const rt = @import("zcode_runtime");

var mutex: std.Io.Mutex = .init;          // initializer is `.init`, not `.{}`

fn f() void {
    mutex.lock(rt.io) catch {};            // lock takes `io` and can error
    defer mutex.unlock(rt.io);             // unlock also takes `io`
    // ... critical section ...
}
```

Notes:
- Default-init is `.init` (not `.{}`).
- `lock(io)` returns an error union; existing call sites use `catch {}` and
  proceed (a lock failure is treated as best-effort, e.g. in
  `core/hooks_snapshot.zig`, `core/session_env.zig`, `core/platform.zig`).
- Both `lock` and `unlock` take `rt.io`.

Reference call sites: `core/error_log.zig`, `core/metrics.zig`,
`core/session_date.zig`, `agent_runtime.zig` (`background_threads_lock`).

Hit while adding the process-global leader-team binding mutex in
`core/task_list_id.zig` (Phase 12, swarm-tasks-05).

## `std.Io.Condition` has NO timed-wait

Same relocation applies to the condition variable: it is `std.Io.Condition`
(init `.init`), with `wait(io, mutex)`, `signal(io)`, `broadcast(io)`. There is
**no `timedWait`** variant. So a "block until delivered, but give up after a
deadline" pattern cannot use a condition variable directly. The codebase
solves this with a short poll loop instead: lock, check the shared state, unlock,
and if not ready `clock.sleepNanos(small_slice)` until `clock.nowMillisIo(io)`
passes the deadline. This mirrors the MCP client's `waitReadableWithDeadline`
polling. Hit while building the persistent LSP server inbox in
`core/lsp/server_instance.zig` (Phase 19, lsp-02): `sendRequest` registers a
request id, writes the framed request, then polls the mutex-guarded inbox for
the matching id (or `error.Timeout`). The background reader thread sets
`entry.body` (or marks all pending `failed` on EOF) under the same mutex.

## `std.ArrayListUnmanaged(T){}` empty-literal fails -- use `= .empty`

`var xs = std.ArrayListUnmanaged(T){};` fails to compile with
"missing struct field: items". The 0.16 idiom is a typed declaration with the
named `.empty` initializer:

```zig
var xs: std.ArrayListUnmanaged(T) = .empty;
```

Note this differs from `std.Io.Mutex`'s `.init`. (As a typed STRUCT FIELD,
`field: std.ArrayListUnmanaged(T) = .empty` also works; the bare `(T){}`
expression-literal form is the one that breaks.) Hit in
`core/lsp/manager.zig`'s `shutdown` (Phase 19, lsp-02).
