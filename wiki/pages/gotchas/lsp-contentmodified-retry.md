# LSP ContentModified (-32801) retry (parity lsp-06)

Implemented in `src/core/lsp/server_instance.zig` `sendRequest` and
`src/core/lsp/protocol.zig`.

## What it does
When a language server replies to a request with JSON-RPC error code
`-32801` (ContentModified, e.g. rust-analyzer still indexing on the first
hover/definition of a fresh large project), `sendRequest` retries up to
`protocol.MAX_RETRIES_FOR_TRANSIENT_ERRORS` (3) times with exponential backoff
(500/1000/2000ms via `backoff.delayMs(attempt, backoff.BASE_DELAY_MS,
backoff.MAX_DELAY_MS)`).

## Non-obvious decisions
- Retry stays INSIDE the persistent `ServerInstance`. The whole point is to
  reuse the same open server and any didOpen'd files across attempts. A fresh
  spawn per attempt would re-trigger indexing and never converge.
- Each retry sends a FRESH request id (`next_id++`), not the same id. A late
  response from a prior attempt can then never be mismatched against a new
  waiter. `next_id` is never reset across restarts/retries for the same reason.
- On exhaustion, the LAST (error-bearing) response body is returned, not an
  error. `sendRequest`'s return type is `![]u8` and the existing extract path
  (`extractLspResult`) just looks for `result` and ignores `error`, so returning
  the body is consistent and lets the caller surface the failure text. The plan
  said "wrap with context"; returning the raw body is the simpler equivalent.
- Sleep routes through `clock.sleepNanos(delay_ms * std.time.ns_per_ms)`, NOT
  `std.time.sleep` (project convention; 0.16 dropped the std helpers anyway).

## Already-existing infra reused
- `protocol.Message.error_code` and `protocol.classify` already parsed the
  JSON-RPC `error.code` (added when lsp-02 lifted the framing helpers), so the
  "extend the response parser" step was a no-op. Only the pure classifiers
  `isRetryableErrorCode`/`responseErrorCode` and the `LSP_ERROR_CONTENT_MODIFIED`
  constant were net-new in protocol.zig.
- `core/backoff.zig` `delayMs(attempt, base, max)` already gives 500/1000/2000;
  do not reinvent the schedule.

## Testing the retry without a real server
The integration test ships a Python stub that returns `-32801` for the first
two non-initialize requests and a result on the third. The retry-count state
lives in the stub process because the SAME persistent process is reused across
attempts -- which is exactly the behavior under test. CI-guarded (`getenv("CI")`)
and skipped if python3 is absent.
