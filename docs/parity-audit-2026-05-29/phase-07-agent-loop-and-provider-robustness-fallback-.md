# Phase 7: Agent loop and provider robustness: fallback swap, retry/backoff, header honoring, error classification, reactive compaction trigger

## Overview

**What.** This phase wires up the robustness machinery that already exists as pure,
tested helper modules in zcode but is currently dead code: model fallback on
overload, response-header-aware retry/backoff, max-tokens / context-overflow
auto-adjustment, reactive compaction on prompt-too-long, an auto-compaction
circuit breaker, SSL error classification, custom request headers, small-fast
routing, live model validation, and deprecation warnings. The single biggest
finding across the verified gaps is that `core/fallback_model.zig`,
`core/backoff.zig`, and `core/reactive_compaction.zig` are all complete and
tested but **never invoked from production code** -- they are registered in
`src/main.zig` only for test discovery. The dominant work here is integration,
not new algorithms.

**Why.** The reference (`claude-code-main`) treats provider failures as recoverable
events, not fatal turn-enders. When the API returns 529 (overloaded), it counts
consecutive overloads and swaps to a configured fallback model. When it returns
429 with a `retry-after` header, it waits exactly that long instead of guessing.
When it returns a 400 "prompt is too long" or a 413, it reactively reduces
history and retries the same turn. zcode currently surfaces all of these as
generic terminal errors, ending the turn and forcing the user to intervene. For
long autonomous runs this is the difference between a session that rides out a
capacity cascade and one that dies on the first 529.

**A note on the deliberate divergence.** `src/agent_history.zig:363-365` carries an
explicit architectural decision: "Never silently switch to a fallback model. If
the active model fails, surface the error so the user can diagnose and fix it or
switch manually." That decision was made *because the wiring did not exist*, not
as a considered rejection of the reference behavior. The reference's swap is
**gated and conservative** (3 consecutive 529s, only for non-custom Opus or when
`FALLBACK_FOR_ALL_PRIMARY_MODELS` is set, only when a fallback is configured) and
it **announces** the swap. This phase implements that gated, announced,
opt-in-via-config behavior -- it does not silently hot-swap. The user only gets a
swap if they configured `fallback_model`. That preserves the spirit of the
"surface the error" decision (no surprise behavior with default config) while
closing the parity gap for operators who opt in.

**Dependencies.** Phase 1 (foundational: response-header capture plumbing through
the curl layer, the `CurlResponseWithStatus` extension, and any shared
error-classification primitives Phase 1 establishes). Several tasks here build
directly on the header-capture work; if Phase 1 has not landed header capture,
Task 7.2 below specifies it as a prerequisite sub-step.

**Effort.** XL. Twelve gaps, four of them medium/high severity requiring real
integration into the hot retry path (`callWithAdapter`, `mapHttpStatusError`,
the agent loop's error handler), plus header-capture plumbing through the curl
chokepoint that touches the most security-sensitive code in the codebase.

## Gaps covered

| id | title | severity | size | our current state |
|---|---|---|---|---|
| agent-loop-04 | Fallback swap unwired | medium | M | Pure logic complete in `fallback_model.zig` (`triggerFromStatus`, `pick`); never called. `callModel` explicitly refuses to swap. |
| api-providers-01 | Model fallback on repeated overload disabled | medium | M | `MAX_CONSECUTIVE_529`/`shouldRetry` in `backoff.zig` exist, never invoked. Retry loops count attempts only, not consecutive 529s. No `FallbackTriggeredError` analog. |
| api-providers-02 | Retry-After / rate-limit-reset headers not honored | medium | M | Only status code captured from curl. Backoff is client-computed (linear `attempt*300ms` at agent level, exponential in circuit breaker). No header parsing. |
| api-providers-03 | x-should-retry not obeyed; 429 always non-retriable | low | M | 429 maps to `RateLimited` (non-retriable). No 408/409 handling. No `x-should-retry` parsing. |
| api-providers-04 | max_tokens / context-overflow auto-adjust on 400 | low | M | All 400s map to generic `HttpStatusCode`. No overflow parser, no `FLOOR_OUTPUT_TOKENS`, no token-lowering retry. |
| api-providers-05 | Prompt-too-long token parsing + reactive trigger | medium | M | `reactive_compaction.zig` has `isOverLimitStatus`/`reduce`, never called. No token-count parser. 413 maps to generic `HttpStatusCode`. |
| api-providers-09 | Model deprecation / retirement warnings | low | S | No `DEPRECATED_MODELS` table, no warning fn, no metadata in `ModelInfo`. |
| api-providers-11 | Live model validation + 3P fallback suggestion | low | S | Only bulk `/v1/models` discovery with 1hr cache. No per-model 1-token probe, no per-model cache, no `get3PFallbackSuggestion`. |
| api-providers-13 | Persistent / unattended retry mode | low | M | `backoff.zig` mirrors the persistent schedule but is unwired. Fixed linear retry, no env var, no heartbeat chunking, no reset awareness. |
| api-providers-14 | Connection/SSL error classification + hints | low | S | curl exit 28/7/6 classified; HTML sanitized (good parity). SSL-specific curl codes (35/51/53/58/60/etc.) all collapse to `HttpTransport` with no CA-bundle/proxy hint. |
| api-providers-15 | Custom headers, client-request-id, configurable timeout | low | S | Configurable timeout present (`provider_timeout_ms`). `ZCODE_ANTHROPIC_BETA` passthrough only. No generic custom-headers env, no session-id / request-id headers. |
| api-providers-16 | Small-fast (Haiku) model for background queries | low | S | `preprocessor_model` is a partial analog. No `ANTHROPIC_SMALL_FAST_MODEL` env, no unified small-fast abstraction, compaction uses `active_model`. |
| compaction-02 | Reactive compaction not wired to 413 / prompt-too-long | high | M | Pure transforms exist, orphaned. 413 not distinguished. Retry re-sends uncompacted history. |
| compaction-04 | Auto-compaction circuit breaker | low | S | No consecutive-failure counter in `AgentRuntime`. `llmCompact` failures swallowed, never tracked. |

## Implementation tasks

The tasks are ordered so that the shared infrastructure (header capture, error
classification) lands first, then the consumers. Tasks 7.1-7.3 are the
foundation; 7.4-7.8 build on them; 7.9-7.13 are mostly independent and can be
parallelized once 7.2/7.3 land.

---

### 7.1 Capture response headers from curl (shared infrastructure)

**Goal.** Extend the curl chokepoint so callers can read inbound response headers
(`retry-after`, `anthropic-ratelimit-unified-reset`, `x-should-retry`) instead of
only the HTTP status code.

**Reference behavior.** `withRetry.ts:519-548` (`getRetryAfter` reads the
`retry-after` header), `:803-822` (`getRetryAfterMs` + `getRateLimitResetDelayMs`
read `anthropic-ratelimit-unified-reset`), `:732` (`error.headers?.get('x-should-retry')`).
In the reference these come free from `fetch`'s `Response.headers`; in zcode we
shell out to curl and must dump headers explicitly.

**Target Zig files.**
- Edit `src/providers/common.zig` -- the non-streaming `callHttp` path (around
  lines 277-401). Add curl `-D <tmpfile>` (dump-header) to a private tempfile
  (NOT stdout: headers must not commingle with the body before the status
  marker; and NOT a fixed path -- reuse the `uniqueTempPath` 0600 pattern at
  `common.zig:128`). The comment at `common.zig:100` already anticipates
  `-D -` for header dumping, so this is a sanctioned extension point.
- Edit `src/providers/extractors.zig` -- extend `CurlResponseWithStatus`
  (lines 693-696) to carry an optional parsed-headers map, OR add a sibling
  struct `CurlResponseWithHeaders`. Prefer extending in place so existing
  callers keep working (add `headers: []const HeaderPair = &.{}` with a default).
- Edit `src/providers/extractors.zig` -- add `parseCurlHeaderDump(allocator, raw)`
  that parses the `-D` output (status line + `Name: Value` lines, blank-line
  terminated, handles multiple response blocks from redirects by taking the
  last block since we pass `-L`).

**Approach.**
1. Define `pub const HeaderPair = struct { name: []const u8, value: []const u8 };`
   in `extractors.zig`. Header names are lowercased on parse (HTTP headers are
   case-insensitive; the reference uses `Headers.get` which lowercases).
2. In `callHttp`, allocate a header-dump tempfile via `uniqueTempPath` (suffix
   `.hdr`), add `-D <path>` to the argv, and read+parse it after the curl run
   completes, before `secrets.cleanup`. Delete the header tempfile in the same
   `defer` discipline as the body/config tempfiles. Header data is far less
   sensitive than the body, but follow the same 0600 + delete pattern for
   consistency and because `set-cookie` / auth-echo headers can appear.
3. `parseCurlHeaderDump`: split on `\r\n` or `\n`; the first token of a line that
   contains `HTTP/` starts a new block; each subsequent `Name: Value` line is a
   pair; an empty line ends the block. With `-L` (follow redirects) there can be
   multiple blocks -- return the **last** block's headers (the final response).
   Cap total parsed headers (e.g. 200) and per-value length (e.g. 8 KiB) to
   bound memory against a hostile server.
4. Thread the parsed headers up so `mapHttpStatusError` and the retry loop can
   see them. The cleanest seam: have the internal `callHttp` produce a small
   `HttpResult { body, status_code, headers }` and keep the existing public
   `callHttp` returning `![]u8` as a thin wrapper for the many callers that do
   not care about headers. Add a new `callHttpWithHeaders(...) !HttpResult` for
   the retry path. Do the same for the streaming path only if Task 7.2 needs
   streaming headers (Anthropic streams 529s; see footgun below).
5. Add a helper `findHeader(headers, name_lowercased) ?[]const u8`.

**Acceptance criteria.**
- Write a test in `extractors.zig` that feeds a realistic curl `-D` dump
  (including a redirect block followed by the final block) into
  `parseCurlHeaderDump` and asserts the returned slice contains the final
  block's `retry-after`, `x-should-retry`, and `anthropic-ratelimit-unified-reset`
  values, lowercased, and does NOT contain the redirect block's headers.
- Write a test that a malformed dump (no blank line, truncated) returns an empty
  or partial slice without crashing.
- `zig build test` passes; existing `parseCurlResponseWithStatus` tests
  (`extractors.zig:714+`) still pass unchanged.

**Test strategy.** Unit tests in `extractors.zig`, run under
`tools/test_runner.zig` via `zig build test`. No live network. The header dump is
fed as a string literal so the parser is tested in isolation from curl.

**Risk / footguns.**
- 0.16: `readFileAlloc(.limited(N))` returns `error.StreamTooLong`, not
  `error.FileTooBig` -- handle that when reading the header tempfile.
- Do NOT use `-D -` (dump to stdout). It would interleave headers with the body
  ahead of the `__ZCODE_HTTP_STATUS__` marker and break
  `parseCurlResponseWithStatus`. Use a tempfile.
- The argv in `callHttp` uses a fixed-size `argv_storage: [12][]const u8`
  (`common.zig:309`). Adding `-D <path>` is two more entries -- bump the array
  size to `[14]` (or compute it) or the next append silently scribbles past the
  end. Verify the bound after editing.
- Header tempfile is created by curl, not by us, so it may not exist if curl
  failed before writing it (exit != 0 paths at `common.zig:358-378`). Guard the
  read with a missing-file fallback to empty headers.

**Size.** M.

---

### 7.2 Honor Retry-After and rate-limit-reset headers in the retry path (api-providers-02)

**Goal.** When the provider returns a `retry-after` header (or
`anthropic-ratelimit-unified-reset`), wait exactly that long instead of the
client-computed backoff.

**Reference behavior.** `withRetry.ts:530-548` (`getRetryDelay`: if `retry-after`
present, return `seconds*1000` and bypass exponential backoff), `:814-822`
(`getRateLimitResetDelayMs`: parse the unix-seconds reset header, compute
`reset*1000 - now`, clamp to the 6hr cap).

**Target Zig files.**
- Create `src/core/retry_after.zig` (new deep module; pure, no IO). Register it
  in the `src/main.zig` comptime block (after line 102, alongside
  `reactive_compaction`).
- Edit `src/agent_history.zig` -- `callWithAdapter` (lines 368-407) to consult the
  parsed headers and use the header-derived delay when present.
- Edit `src/providers/common.zig` -- the retry loop in `callHttpWithResilience`
  (lines 666-719) similarly, if header capture is plumbed there.

**Approach.**
1. `retry_after.zig` exposes pure functions over a `[]const HeaderPair`:
   - `parseRetryAfterMs(headers) ?u64` -- read `retry-after`, parse integer
     seconds, return `seconds * 1000`. (The reference only handles the
     integer-seconds form, not the HTTP-date form; match that.)
   - `parseRateLimitResetMs(headers, now_unix_ms) ?u64` -- read
     `anthropic-ratelimit-unified-reset`, parse as unix seconds (float-tolerant
     per reference `Number(...)`), compute `reset*1000 - now`, return null if
     <= 0, clamp to `PERSISTENT_RESET_CAP_MS` (6hr) -- reuse the constant from
     `backoff.zig` (add `PERSISTENT_RESET_CAP_MS` there if not present).
   - `effectiveDelayMs(headers, now_unix_ms, computed_fallback_ms) u64` --
     reset header wins, then retry-after, then the caller's computed fallback.
2. In `callWithAdapter`, when an error is retriable and we have headers, replace
   the `attempt*300` line (`agent_history.zig:400`) with
   `retry_after.effectiveDelayMs(headers, clock.nowMillis(), attempt*300)`.
   Cap the total wait so a hostile header cannot stall the turn unboundedly when
   NOT in persistent mode (clamp to, say, 60s in normal mode; Task 7.8 lifts the
   cap in persistent mode).
3. Use `clock.nowMillis()` (per `core/clock.zig`) for "now" -- never
   `std.time.*`.

**Acceptance criteria.**
- Write tests in `retry_after.zig`: `retry-after: 5` -> 5000ms;
  `retry-after: notanumber` -> null; reset header in the future -> correct
  positive delay; reset header in the past -> null; reset header far in the
  future -> clamped to 6hr; reset header beats retry-after when both present.
- Write a test (or extend an `agent_history` test) proving `effectiveDelayMs`
  prefers the header over the computed fallback.

**Test strategy.** Pure unit tests in `retry_after.zig`. The `callWithAdapter`
integration is hard to unit-test without a fake adapter; if a fake adapter
harness already exists in `agent_history.zig` tests, add an integration test
asserting the loop sleeps for the header-derived duration (inject a fake clock /
record the requested sleep rather than actually sleeping).

**Risk / footguns.**
- Do not actually `sleep` in tests. Factor the delay computation out of the
  sleep call so the computation is testable without wall-clock waits.
- `clock.nowMillis()` returns the wrapped `std.Io.Timestamp.now` value -- confirm
  its unit is ms (per CLAUDE.md `core/clock.zig` wraps it). The reset header is
  unix *seconds*; multiply by 1000 before subtracting.
- Streaming 529s: Anthropic returns the `overloaded_error` mid-stream, where the
  HTTP status is 200 and headers were already consumed. For those, headers may
  be absent -- fall back to computed backoff cleanly (null from the parsers).

**Size.** M.

---

### 7.3 Status-code error classification: 408, 409, 413, and x-should-retry (api-providers-03, api-providers-05 part 1)

**Goal.** Map 408/409 to retriable errors, distinguish 413 (request-too-large) as
its own error so reactive compaction can trigger, and obey the `x-should-retry`
header.

**Reference behavior.** `withRetry.ts:760` (408 -> retry), `:763` (409 -> retry),
`:732-751` (`x-should-retry` header: `true` -> retry for non-subscribers/
enterprise; `false` -> do-not-retry except ant 5xx), `errors.ts:659-664`
(413 -> request-too-large message). `errors.ts:62-118` is the prompt-too-long
classification handled in Task 7.5.

**Target Zig files.**
- Edit `src/providers/common.zig` -- `mapHttpStatusError` (lines 721-746): add
  `408 -> error.RequestTimeout` (or reuse `ConnectionTimeout`), `409 ->
  error.LockTimeout` (new) or map to `HttpTransport` (retriable), and `413 ->
  error.RequestTooLarge` (the error already exists per `error_hints.zig:30`).
- Edit `src/providers/common.zig` -- `shouldRetryHttpError` (lines 644-658) to
  retry the new 408/409 errors and to consult `x-should-retry` when headers are
  available.
- Edit `src/agent_history.zig` -- `isRetriableProviderError` (lines 551-561) to
  include 413's `RequestTooLarge` (so the agent-level loop retries it AFTER
  reactive reduction lands in Task 7.5; until then keep it non-retriable to
  avoid re-sending the same oversized request).
- Add new error members to the error set used by these functions (they are
  inferred error sets, so just `return error.LockTimeout` etc. is enough; add
  matching arms in `describeProviderError` at `common.zig:758` and
  `describeUiError` at `core/error_hints.zig:11`).

**Approach.**
1. In `mapHttpStatusError`, add before the generic `4xx -> HttpStatusCode` line:
   - `if (status_code == 408) return error.ConnectionTimeout;` (reuse existing,
     already retriable via `shouldRetryHttpError`).
   - `if (status_code == 409) return error.HttpTransport;` (retriable; a lock
     timeout is transient).
   - `if (status_code == 413) return error.RequestTooLarge;`
2. `x-should-retry`: add an overload `shouldRetryHttpErrorWithHeaders(err, headers)`
   that, when `x-should-retry: false` is present, returns false (except for 5xx,
   matching the ant carve-out -- but zcode has no ant/external distinction, so
   the simplest faithful behavior is: `false` header forces no-retry for non-5xx,
   allows the existing 5xx retry). When `x-should-retry: true`, returns true.
   Absent header -> existing status-based logic. Keep the old
   `shouldRetryHttpError(err)` as a header-less wrapper.
3. zcode has no subscriber concept, so the reference's
   `!isClaudeAISubscriber() || isEnterpriseSubscriber()` gate around 429 collapses
   to "retry 429 at the HTTP layer" -- but see Task 7.4: 429 retry is governed by
   the fallback path. For now, leave 429 -> `RateLimited` mapping as-is; Task 7.4
   decides whether to swap or retry.

**Acceptance criteria.**
- Write tests in `common.zig` for `mapHttpStatusError`: 408 -> ConnectionTimeout,
  409 -> HttpTransport, 413 -> RequestTooLarge, 429 -> RateLimited (unchanged),
  503/529 -> ServerOverloaded (unchanged), 400 -> HttpStatusCode (unchanged).
- Write tests for `shouldRetryHttpErrorWithHeaders`: `x-should-retry: false` on a
  404 -> false; `x-should-retry: true` on a 404 -> true; no header on a
  `ConnectionTimeout` -> true (unchanged).
- `describeProviderError(error.RequestTooLarge)` and `describeUiError` return a
  non-null actionable string.

**Test strategy.** Unit tests in `common.zig` and `core/error_hints.zig` under
`tools/test_runner.zig`.

**Risk / footguns.**
- Do not flip 413 to retriable at the agent level until Task 7.5 actually reduces
  history first -- otherwise the retry re-sends the identical oversized prompt and
  burns the retry budget for nothing (this is exactly the bug noted in
  compaction-02 evidence: `agent_history.zig` makes `HttpStatusCode` retriable but
  line 382 retries the same request).
- `RequestTooLarge` already exists in `error_hints.zig`; confirm it is not
  shadowed by a different inferred error set member of the same name elsewhere.

**Size.** M.

---

### 7.4 Wire fallback model swap on repeated overload (agent-loop-04, api-providers-01)

**Goal.** After `MAX_CONSECUTIVE_529` (3) consecutive overload errors, if a
`fallback_model` is configured, swap to it and continue -- announced, not silent.

**Reference behavior.** `withRetry.ts:326-365` (consecutive529 counting + throw
`FallbackTriggeredError(model, fallbackModel)` when `options.fallbackModel` set),
`:160-168` (`FallbackTriggeredError` carries original + fallback model so the
caller swaps). The caller in `query.ts:893-951` catches it and continues with the
fallback model.

**Target Zig files.**
- Edit `src/core/fallback_model.zig` -- it already has `triggerFromStatus` and
  `pick` (lines 11-27). No new pure logic needed; this gap is pure wiring.
- Edit `src/agent_history.zig` -- `callWithAdapter` (lines 368-407): track a
  `consecutive_529: u32` counter across retries; when an error is
  `ServerOverloaded`, increment; when `consecutive_529 >= backoff.MAX_CONSECUTIVE_529`
  and a fallback is configured and distinct, surface a sentinel
  `error.FallbackTriggered` plus the chosen model name.
- Edit `src/agent_runtime.zig` -- `callModel` (lines 2862-2874) to catch the
  fallback signal, apply the model override via the existing `applyModelOverride`
  (lines 2908-2949), announce it, and retry once with the new model.
- Edit `src/agent_history.zig` -- relax/replace the "never swap" comment at
  lines 363-365 with the new gated behavior (it is documentation of the OLD
  decision; update it to describe the gated swap).

**Approach.**
1. Because Zig errors cannot carry a payload, thread the chosen fallback model
   out via an out-parameter or a small result struct rather than the error value.
   Cleanest: add an optional `*?[]const u8 fallback_out` parameter to
   `callWithAdapter`/`callModel`, OR return a tagged union
   `CallOutcome { .ok: ModelResponse, .fallback: []const u8 }`. The out-parameter
   is the smaller, more surgical change given how many call sites `callModel` has.
2. In `callWithAdapter`, on each `ServerOverloaded`:
   `consecutive_529 += 1;` (reset to 0 on any non-overload error or success).
   When `consecutive_529 >= backoff.MAX_CONSECUTIVE_529`:
   - `const trig = fallback_model.triggerFromStatus(529);`
   - `if (fallback_model.pick(active_model, cfg.fallback_model, trig)) |fb| { fallback_out.* = fb; return error.FallbackTriggered; }`
   - Gate this on `cfg.fallback_model.len > 0` (the `pick` already returns null
     when empty/identical, so this is belt-and-suspenders). Mirror the reference's
     "only swap when configured" exactly -- no swap with default config.
3. In `agent_runtime.callModel`, catch `error.FallbackTriggered`, read the
   out-param, emit a progress line ("model X overloaded after 3 attempts;
   switching to fallback Y"), call `self.applyModelOverride(fb)` (or set
   `self.active_model` directly with the same staged-dupe discipline as
   `applyModelOverride`), and re-invoke `agent_history.callModel` once with the
   new model. Do NOT loop indefinitely -- one swap, then surface any further error.
4. Honor the reference's model gate loosely: the reference only counts 529s for
   non-custom Opus unless `FALLBACK_FOR_ALL_PRIMARY_MODELS` is set. zcode has no
   Opus-specific gate and supports many providers, so the faithful adaptation is:
   count 529s for any model, but only swap when `fallback_model` is configured.
   Document this divergence inline.

**Acceptance criteria.**
- Write a test with a fake adapter that returns `ServerOverloaded` 3 times: with
  `cfg.fallback_model = ""`, the loop surfaces `ServerOverloaded` (no swap, current
  behavior preserved). With `cfg.fallback_model = "sonnet"` and active model
  `"opus"`, the loop surfaces `error.FallbackTriggered` and sets the out-param to
  `"sonnet"`.
- Write a test that a single 529 followed by a success does NOT trigger fallback
  (counter must reach 3).
- Write a test that an interleaved non-overload retriable error resets the
  consecutive counter (3 non-consecutive 529s do not trigger).
- `fallback_model.zig` existing tests still pass.

**Test strategy.** Fake-adapter unit tests in `agent_history.zig` driving
`callWithAdapter`. The agent-runtime catch+retry is integration-level; assert via
a fake adapter that records the model name on the second call equals the fallback.

**Risk / footguns.**
- This is the gap with the strongest "deliberate divergence" framing. Keep the
  swap **announced** and **config-gated** so default behavior is unchanged.
  Reviewers will check that no swap happens without `fallback_model` set.
- Out-param lifetime: the fallback model string is borrowed from `cfg.fallback_model`
  (config-owned, stable for the session). Do not dupe-and-leak it; just borrow.
  `applyModelOverride` already dupes into `self.active_model`.
- Resetting `consecutive_529`: a 529 then a 503 are both `ServerOverloaded` -- both
  should count toward the run (reference counts via `is529Error`, and 503 maps to
  overload in `triggerFromStatus`). Only reset on a *different* error class or
  success.

**Size.** M.

---

### 7.5 Reactive compaction on prompt-too-long / 413 (compaction-02, api-providers-05 part 2)

**Goal.** When the API rejects an over-budget prompt (HTTP 413, or a 400/anything
containing "prompt is too long: N tokens > M maximum"), reduce history and retry
the turn instead of failing it.

**Reference behavior.** `errors.ts:62-118` (`PROMPT_TOO_LONG_ERROR_MESSAGE`,
`isPromptTooLongMessage`, `parsePromptTooLongTokenCounts`, `getPromptTooLongTokenGap`),
`compact.ts:243-291` (`truncateHeadForPTLRetry`), `:450-491` (PTL retry loop),
`autoCompact.ts:189-223` (reactive-only fallback). `reactive_compaction.zig`
already has `isOverLimitStatus` and `reduce`; this gap is the token parser plus
the wiring.

**Target Zig files.**
- Edit `src/core/reactive_compaction.zig` -- add `isPromptTooLongMessage(text)` and
  `parsePromptTooLongTokenCounts(text) ?struct { actual: u64, limit: u64 }` and
  `promptTooLongGap(text) ?u64`. Mirror the lenient regex behavior with a hand
  parser (Zig std has no regex): find the case-insensitive substring "prompt is
  too long", then scan forward for the first run of digits (actual), then a `>`,
  then the next run of digits (limit). Return null if the shape doesn't match.
- Edit `src/providers/common.zig` -- `mapHttpStatusError`: detect the
  prompt-too-long body text and map to `error.RequestTooLarge` (or a distinct
  `error.PromptTooLong`) even on a 400, since the direct API returns 400 and
  Vertex returns 413 (per `errors.ts:560` comment).
- Edit `src/agent_history.zig` -- `callWithAdapter`: on `RequestTooLarge` /
  `PromptTooLong`, before retrying, invoke `reactive_compaction.reduce` on
  `request.history` (and rebuild the flat `request.prompt` if the adapter uses
  text mode), then retry with the reduced request. Use the parsed gap to choose
  `keep_last_n` more aggressively when the overflow is large.
- Possibly edit `src/agent_runtime.zig` -- if reduction must mutate the durable
  `self.history` (not just the per-call request), route the reduction through the
  runtime so the persisted history shrinks too. Decide based on whether
  `ModelRequest.history` is a borrowed view of `self.history.view()` (it is, per
  `agent_runtime.zig:1120`).

**Approach.**
1. Implement the token parser in `reactive_compaction.zig` with unit-testable
   pure functions. Handle casing ("Prompt is too long" from Vertex) by
   lowercasing the search.
2. In `mapHttpStatusError`, add (before the generic 400 fallthrough):
   `if (containsIgnoreCase(payload, "prompt is too long")) return error.RequestTooLarge;`
   and keep the `413 -> RequestTooLarge` from Task 7.3.
3. In `callWithAdapter`, special-case `RequestTooLarge`:
   - It is now agent-retriable, but the retry MUST reduce first. Compute
     `keep_last_n`: start from a default window (e.g. 8 turns), and if
     `promptTooLongGap` indicates a large overflow, drop more aggressively.
   - Call `reactive_compaction.reduce(allocator, request.history, keep_last_n)`,
     build a new `ModelRequest` with the reduced history (and regenerated flat
     prompt for text-mode providers), and retry. Cap reactive retries (e.g. 2)
     so a pathological model that always 413s does not loop forever.
   - If reduction cannot shrink further (already at minimum) and it still 413s,
     surface the error.
4. Decide the mutate-durable-history question: the safest first cut is to reduce
   only the **request** copy and retry; the durable `self.history` is then
   compacted by the existing proactive `forceCompaction` on the next turn. This
   keeps the change surgical. Document that reactive reduction is request-scoped.

**Acceptance criteria.**
- Write tests in `reactive_compaction.zig`: `parsePromptTooLongTokenCounts("prompt
  is too long: 137500 tokens > 135000 maximum")` -> `{actual:137500, limit:135000}`;
  case-insensitive variant parses; `promptTooLongGap` -> 2500; a non-PTL string
  -> null.
- Write a fake-adapter test in `agent_history.zig`: adapter 413s once then
  succeeds; assert the second call's `request.history` is shorter than the first
  (reduce was applied) and the turn ultimately succeeds.
- Write a test that an adapter that 413s on every call eventually surfaces the
  error after the reactive-retry cap (does not loop forever).
- `reactive_compaction.zig` existing `reduce` and `isOverLimitStatus` tests still
  pass.

**Test strategy.** Pure parser tests + fake-adapter integration tests under
`tools/test_runner.zig`.

**Risk / footguns.**
- `reduce` returns a borrowed slice (shallow copies of turns; comment at
  `reactive_compaction.zig:18-19`). The caller owns the *slice* but not the turn
  contents. Free the slice, not the turns. Watch for double-free if the rebuilt
  `ModelRequest` is also freed.
- Text-mode providers (`request.prompt` is the flattened conversation): reducing
  `request.history` alone will not shrink the prompt those providers actually
  send. Rebuild the flat prompt from the reduced history for those providers, or
  the retry sends the same oversized text. Check which adapters consume `prompt`
  vs `history` (per the `ModelRequest` doc at `core/types.zig:283-289`).
- This is the only HIGH-severity gap (compaction-02). Prioritize correctness of
  the wiring over the cleverness of the gap heuristic.

**Size.** M.

---

### 7.6 max_tokens / context-overflow auto-adjustment (api-providers-04)

**Goal.** On a 400 "input length and `max_tokens` exceed context limit: A + B > C"
error, lower `max_output_tokens` and retry instead of failing.

**Reference behavior.** `withRetry.ts:550-595` (`parseMaxTokensContextOverflowError`
extracts A=input, B=max_tokens, C=context_limit), `:384-427` (adjustment:
`availableContext = C - A - safetyBuffer(1000)`; new max =
`max(FLOOR_OUTPUT_TOKENS=3000, availableContext, thinkingBudget+1)`; retry),
`:53` `FLOOR_OUTPUT_TOKENS = 3000`.

**Target Zig files.**
- Edit `src/core/reactive_compaction.zig` OR create
  `src/core/max_tokens_overflow.zig` (new pure module; register in `main.zig`
  comptime block). Prefer a new module since this is conceptually distinct from
  history reduction.
- Edit `src/providers/common.zig` -- `mapHttpStatusError`: detect the
  "input length and `max_tokens` exceed context limit" message and map to a
  distinct `error.MaxTokensOverflow` (so the retry loop can adjust rather than
  reduce history).
- Edit `src/agent_history.zig` -- `callWithAdapter`: on `MaxTokensOverflow`,
  parse A/B/C from the error payload, compute the adjusted max, set
  `request.max_output_tokens`, and retry.

**Approach.**
1. `parseMaxTokensContextOverflow(text) ?struct { input: u64, max_tokens: u64, context_limit: u64 }`:
   find the literal "exceed context limit:" then parse `A + B > C` (three digit
   runs separated by `+` and `>`). Match the reference's exact substring guard.
2. `adjustMaxTokens(parsed, thinking_budget) ?u64`:
   `const FLOOR = 3000; const SAFETY = 1000;`
   `const available = if (context_limit > input + SAFETY) context_limit - input - SAFETY else 0;`
   `if (available < FLOOR) return null;` (signals "cannot recover, surface error")
   `return @max(FLOOR, available, thinking_budget + 1);`
3. In `callWithAdapter`, on `MaxTokensOverflow`: parse; if `adjustMaxTokens`
   returns a value, set `request.max_output_tokens` and retry; if null, surface
   the error.
4. The payload string must reach `callWithAdapter`. Since `mapHttpStatusError`
   currently discards the payload, capture the overflow numbers at mapping time
   into a thread-local or pass the error body up alongside the error (an
   out-param similar to Task 7.4). The simplest seam: have the parser run in
   `callWithAdapter` on the same payload the adapter already has, OR store the
   last error body. Given how the adapters call `callHttp`, the cleanest is to
   parse inside the adapter's error path -- but to keep it provider-agnostic,
   prefer threading the body up via the header/result struct from Task 7.1
   (which already carries the body).

**Acceptance criteria.**
- Write tests in the new module: parse the example
  "input length and `max_tokens` exceed context limit: 188059 + 20000 > 200000"
  -> `{188059, 20000, 200000}`; `adjustMaxTokens` with thinking_budget 0 ->
  `max(3000, 200000-188059-1000=10941, 1)` = 10941; a case where available < 3000
  -> null; a non-matching string -> null for the parser.
- Write a fake-adapter test: adapter returns MaxTokensOverflow once then succeeds;
  assert the retry's `request.max_output_tokens` equals the adjusted value.

**Test strategy.** Pure parser/adjuster unit tests + fake-adapter integration test
under `tools/test_runner.zig`.

**Risk / footguns.**
- Reference notes this 400 should not occur with the extended-context beta (the
  API now returns a `model_context_window_exceeded` stop_reason instead). This is
  lower priority and kept for backward compat. Do not over-invest; the parser +
  one retry is sufficient.
- zcode already does proactive token budgeting (`reserved_output_tokens`,
  `model_context_window`), so this is mostly a safety net. Keep it minimal.

**Size.** M.

---

### 7.7 Auto-compaction circuit breaker (compaction-04)

**Goal.** Stop retrying auto-compaction after
`MAX_CONSECUTIVE_AUTOCOMPACT_FAILURES` (3) consecutive failures for the session.

**Reference behavior.** `autoCompact.ts:67-70` (constant), `:257-265`
(consecutiveFailures check before attempting), `:334-350` (increment + trip on
failure).

**Target Zig files.**
- Edit `src/agent_runtime.zig` -- the `WorkingContextState` struct
  (lines 164-179, which already tracks `consecutive_read_only_stall_rounds` and
  `action_reprompt_attempts`) OR a dedicated field on `AgentRuntime`. The counter
  must persist across turns (the whole session), so it belongs on `AgentRuntime`
  itself, not on the per-turn `WorkingContextState`.
- Edit `src/agent_runtime.zig` -- `forceCompaction` (lines 2975-2997) and any
  `maybeCompact` path: check the counter before attempting, increment on
  `llmCompact` failure, reset on success.
- Add `MAX_CONSECUTIVE_AUTOCOMPACT_FAILURES = 3` as a const near the runtime.

**Approach.**
1. Add `compaction_consecutive_failures: u8 = 0` to `AgentRuntime` (init to 0 in
   the constructor near line 3268 where other counters init).
2. In `forceCompaction`, guard the LLM-compaction attempt:
   `if (self.compaction_consecutive_failures >= MAX_CONSECUTIVE_AUTOCOMPACT_FAILURES) { /* skip LLM compaction, fall through to rule-based */ }`.
   Note: the rule-based `agent_history.forceCompaction` at line 2996 cannot
   "fail" an API call (no model call), so the breaker should gate only the
   *LLM* compaction (`llmCompact` at 2988), not the rule-based fallback. This
   matches the reference, where the breaker protects the API-calling path.
3. On `llmCompact` returning null (current swallow at 2988-2995), increment the
   counter. On a non-null summary, reset to 0.

**Acceptance criteria.**
- Write a test (or extend an `AgentRuntime` test harness) that simulates 3
  consecutive `llmCompact` failures and asserts the 4th `forceCompaction` call
  skips the LLM attempt (e.g. by counting adapter creations or via a test hook).
- Write a test that a success between failures resets the counter.

**Test strategy.** This requires an `AgentRuntime` test seam. If `forceCompaction`
can be exercised with a fake adapter that always fails `llmCompact`, assert the
breaker trips. If no such seam exists, extract the breaker decision into a tiny
pure helper (`fn shouldAttemptLlmCompaction(failures: u8) bool`) and unit-test
that, plus a code-review check that the increment/reset are wired.

**Risk / footguns.**
- Low priority per the gap notes: zcode's compaction is mostly rule-based and
  "cannot fail" today, so this matters mainly once LLM summarization (compaction-01,
  not in this phase) and reactive compaction (Task 7.5) are exercised. Keep the
  change minimal -- a counter and two guards.
- Do not gate the rule-based fallback behind the breaker, or a tripped breaker
  would disable compaction entirely and let context grow unbounded.

**Size.** S.

---

### 7.8 Persistent / unattended retry mode (api-providers-13)

**Goal.** `ZCODE_CODE_UNATTENDED_RETRY` (zcode-namespaced analog of
`CLAUDE_CODE_UNATTENDED_RETRY`) enables indefinite 429/529 retries with backoff up
to 5 min, capped at 6 hr, honoring the reset header, chunking long sleeps into
30s heartbeat yields.

**Reference behavior.** `withRetry.ts:91-104` (`isPersistentRetryEnabled`,
`PERSISTENT_MAX_BACKOFF_MS=5min`, `PERSISTENT_RESET_CAP_MS=6hr`,
`HEARTBEAT_INTERVAL_MS=30s`), `:433-512` (persistent backoff + chunked heartbeat
sleeps). `backoff.zig` was written to mirror this (its PRD #534 header) but is
unwired.

**Target Zig files.**
- Edit `src/core/backoff.zig` -- it has `delayMs`, `shouldRetry`,
  `MAX_CONSECUTIVE_529`. Add `PERSISTENT_MAX_BACKOFF_MS`, `PERSISTENT_RESET_CAP_MS`,
  `HEARTBEAT_INTERVAL_MS` constants (some may already exist; reconcile with
  Task 7.2 which referenced `PERSISTENT_RESET_CAP_MS`).
- Edit `src/agent_history.zig` -- `callWithAdapter`: when persistent mode is on
  and the error is `RateLimited`/`ServerOverloaded`, do not give up at
  `provider_retry_count`; instead loop with `backoff.delayMs` (capped at 5 min),
  honoring the reset header from Task 7.2, and chunk the sleep into 30s pieces
  checking cancellation between chunks.
- Edit `src/core/env.zig` (or wherever env reads live) -- read the env var once.

**Approach.**
1. Add an `unattended: bool` flag derived from the env var, read once at startup
   or per-call via `core/env.zig`'s `getenv`. Truthy check ("1", "true", etc.) --
   reuse any existing env-truthy helper.
2. In `callWithAdapter`, branch the retry decision: in normal mode keep
   `attempt >= cfg.provider_retry_count` termination; in persistent mode, for
   `RateLimited`/`ServerOverloaded` only, keep retrying with
   `backoff.delayMs(persistent_attempt, BASE, PERSISTENT_MAX_BACKOFF_MS)` capped,
   preferring the reset/retry-after header (Task 7.2). Use a separate
   `persistent_attempt` counter so the normal `attempt` cap is not the gate.
3. Chunk the sleep: loop `while (remaining > 0)`, sleep `min(remaining, 30s)`
   via `clock.sleepNanos`, decrement, and call `common.checkCancelled()` between
   chunks so ESC still works during a long wait. Emit a progress line on each
   chunk so the host/TUI sees activity (mirrors the reference's
   `createSystemAPIErrorMessage` yields).
4. Still respect the `consecutive_529` -> fallback path from Task 7.4: persistent
   mode should not block a configured fallback swap. Decide precedence: the
   reference's persistent mode bypasses the subscriber gates but the fallback
   throw still happens at 3x529. Match that -- fallback (if configured) wins over
   indefinite retry.

**Acceptance criteria.**
- Write a test that `backoff.delayMs` schedule with `PERSISTENT_MAX_BACKOFF_MS`
  caps at 5 min (extend existing `backoff.zig` tests).
- Write a pure test for the env-truthy parsing of the unattended flag.
- Write a fake-adapter test (with an injected fake clock / recorded sleeps, not
  real waits) that in persistent mode the loop keeps retrying a `RateLimited`
  adapter past `provider_retry_count`, and that a cancel between chunks breaks the
  loop.

**Test strategy.** Pure tests in `backoff.zig` + fake-adapter/fake-clock
integration test in `agent_history.zig`. Never sleep for real in tests -- inject
the sleep so it is observable and instant.

**Risk / footguns.**
- Niche feature for AFK sessions. Do not let persistent mode become the default;
  it must be strictly env-gated.
- The chunked sleep MUST check cancellation between chunks or ESC during a 5-min
  wait does nothing -- a serious UX regression. The existing
  `common.checkCancelled()` and `shouldRetryHttpError`'s cancel short-circuit at
  `common.zig:652` are the patterns to follow.
- Do not actually call `clock.sleepNanos` in unit tests; factor sleeps behind an
  injectable function or a test flag.

**Size.** M.

---

### 7.9 SSL / connection error classification and hints (api-providers-14)

**Goal.** Recognize curl's SSL/TLS exit codes and surface a CA-bundle / corporate-
proxy hint, matching the reference's `getSSLErrorHint` guidance.

**Reference behavior.** `errorUtils.ts:5-29` (`SSL_ERROR_CODES`), `:94-100`
(`getSSLErrorHint`: suggest `NODE_EXTRA_CA_CERTS` / allowlist), `:200-260`
(`formatAPIError` SSL switch). HTML sanitization is already at parity
(`core/parse_helpers.zig:285-313`).

**Target Zig files.**
- Edit `src/providers/common.zig` -- the curl exit-code classification block
  (lines 358-378). Add recognition of curl's TLS exit codes and map them to a new
  `error.SslError` (or `error.TlsHandshakeFailed`).
- Edit `src/providers/common.zig` -- `describeProviderError` (line 758) and
  `src/core/error_hints.zig` -- `describeUiError` (line 11): add an arm for the
  SSL error with the CA-bundle / proxy hint (mention `CURL_CA_BUNDLE` /
  `SSL_CERT_FILE`, the curl-native analogs of `NODE_EXTRA_CA_CERTS`).

**Approach.**
1. curl SSL/TLS exit codes (from `man curl`): 35 (SSL connect error / handshake),
   51 (peer cert/fingerprint failed verification), 53 (no SSL crypto engine),
   54 (cannot set SSL crypto engine default), 58 (problem with local client cert),
   59 (cannot use specified SSL cipher), 60 (peer cert cannot be authenticated
   with known CA certs -- the classic corporate-proxy case), 64 (requested SSL
   level failed), 66 (SSL engine init failed), 77 (CA cert problem -- bad file/dir
   perms), 82 (could not load CRL file), 83 (issuer check failed), 90/91 (SSL
   pinning failures). Map this set to `error.SslError`.
2. Add the mapping in the exit-code block at `common.zig:358`:
   `if (code == 35 or code == 51 or code == 53 or ... ) return error.SslError;`
   plus a stderr substring fallback (`containsIgnoreCase(stderr, "ssl")` /
   `"certificate"`) like the existing timeout/refused/DNS fallbacks.
3. The hint text (kept <= the 120-char style of `error_hints.zig`):
   "SSL/TLS error reaching the API. Behind a corporate proxy or TLS-intercepting
   firewall? Set CURL_CA_BUNDLE or SSL_CERT_FILE to your CA bundle, or ask IT to
   allowlist the provider host. Run /doctor."

**Acceptance criteria.**
- Write a test (or extend `common.zig` tests) that the exit-code -> error mapping
  returns `SslError` for codes 35/51/60/77 and `HttpTransport` for an unrelated
  code (e.g. 22).
- `describeProviderError(error.SslError)` and `describeUiError(error.SslError)`
  return a non-null string mentioning a CA bundle / proxy.

**Test strategy.** Unit tests in `common.zig` and `core/error_hints.zig`. The
exit-code mapping is currently inline in `callHttp`; consider extracting a tiny
pure `classifyCurlExit(code, stderr) anyerror` so it is unit-testable without
spawning curl.

**Risk / footguns.**
- Low impact: curl already surfaces TLS failures as a distinct exit code, so unlike
  Node (which buried them in a cause chain) zcode just needs to recognize the
  codes. The HTML-sanitization half of this gap is already at parity -- do not
  re-implement it.
- Do not over-enumerate codes that are not TLS-related. Keep the set to the
  documented SSL/cert/cipher codes.

**Size.** S.

---

### 7.10 Custom request headers, client-request-id, session-id (api-providers-15)

**Goal.** Parse a generic custom-headers env var, inject a per-request
`x-client-request-id` UUID and a session-id correlation header, alongside the
existing configurable timeout.

**Reference behavior.** `client.ts:330-389` (`getCustomHeaders` parses
`ANTHROPIC_CUSTOM_HEADERS` as newline-separated `Name: Value`; `buildFetch`
injects per-request `x-client-request-id` UUID, first-party only),
`:101-152` (`x-app:cli`, `X-Claude-Code-Session-Id`, `User-Agent`, timeout from
`API_TIMEOUT_MS`).

**Target Zig files.**
- Edit `src/core/types.zig` -- `ModelRequest` (lines 264-313): add
  `session_id: []const u8 = ""`, `request_id: []const u8 = ""`, and optionally
  `custom_headers: []const []const u8 = &.{}` so these can be threaded to the
  provider layer.
- Edit `src/providers/anthropic.zig` (and the shared header-building helper if one
  exists) -- inject the headers when set. The HTTP layer already accepts an
  arbitrary headers array (`common.zig:447-451`), so this is about populating it.
- Edit `src/agent_runtime.zig` -- populate `request.session_id` from the existing
  `self.session_id` (the value exists at `agent_runtime.zig:227` but never reaches
  `ModelRequest` per the gap evidence) and generate a `request_id` via
  `core/rng.zig`.
- Create `src/core/custom_headers.zig` (pure parser; register in `main.zig`) for
  the `ZCODE_CUSTOM_HEADERS` env var (zcode-namespaced) -> `[]HeaderPair`.

**Approach.**
1. `custom_headers.zig`: `parse(allocator, raw) ![]HeaderPair` -- split on `\n`,
   trim, skip blanks, split each on the first `:`, trim name/value. Reject lines
   without a colon. Reuse `HeaderPair` from Task 7.1's `extractors.zig` (or define
   it once in a shared spot and import).
2. Generate `x-client-request-id` per request: a UUID-ish value from
   `rng.secureBytes` formatted as hex (no need for strict UUID v4 layout unless a
   test demands it; the reference uses `crypto.randomUUID`). Use `core/rng.zig`
   (`rng.secureBytes`), never `std.crypto.random.*` per CLAUDE.md.
3. Inject `X-Zcode-Session-Id: <session_id>` (zcode-namespaced analog of
   `X-Claude-Code-Session-Id`) when non-empty.
4. Honor the existing timeout (`provider_timeout_ms`) -- already present, no change.
5. Thread custom headers from config/env down through the adapter's header array.
   Keep first-party-only injection of `x-client-request-id` if there is a notion
   of first-party (Anthropic) vs third-party in zcode; otherwise inject for all
   and document the divergence.

**Acceptance criteria.**
- Write tests in `custom_headers.zig`: multi-line input parses into the right
  pairs; a line with no colon is rejected/skipped; CRLF handled; leading/trailing
  whitespace trimmed.
- Write a test that a `ModelRequest` with `session_id` set causes the anthropic
  adapter's header array to include the session-id header (assert on the built
  header list, not a live call).
- Write a test that the generated request-id is non-empty and differs across two
  generations.

**Test strategy.** Pure parser tests + adapter header-building tests under
`tools/test_runner.zig`. No live network.

**Risk / footguns.**
- Custom header values can contain secrets; they ride the existing curl `-K`
  config-file path (`writeCurlRequestFiles`) so they stay out of argv. Verify the
  new headers go through that same path, not raw argv.
- Do not let a malformed `ZCODE_CUSTOM_HEADERS` crash startup -- skip bad lines.
- `ModelRequest` is constructed in many places; adding fields with defaults
  (`= ""`, `= &.{}`) keeps all existing constructions compiling. Verify no
  positional-init sites exist that would break.

**Size.** S.

---

### 7.11 Small-fast model routing for background work (api-providers-16)

**Goal.** Support a `ZCODE_SMALL_FAST_MODEL` env var (analog of
`ANTHROPIC_SMALL_FAST_MODEL`) and route cheap background work (compaction
summaries, titles, classifiers) to it.

**Reference behavior.** `model.ts:36-38` (`getSmallFastModel` returns
`ANTHROPIC_SMALL_FAST_MODEL` or default Haiku); used for titles, summaries,
classifiers, model validation. zcode's `preprocessor_model` is a partial analog.

**Target Zig files.**
- Edit `src/core/config.zig` -- add a `small_fast_model: []u8` field (and
  provider) OR reuse `preprocessor_model`/`preprocessor_provider` (lines 111-112)
  as the small-fast model. Decide: the cleanest minimal change is to treat
  `preprocessor_model` as the small-fast model and add a `ZCODE_SMALL_FAST_MODEL`
  env override that populates it when set.
- Edit `src/core/config_parse.zig` -- read the env var.
- Edit `src/agent_runtime.zig` -- `forceCompaction` (line 2988): route `llmCompact`
  to the small-fast model when configured, instead of `active_model`.

**Approach.**
1. Add a resolver `smallFastModel(cfg) struct { provider, model }` that returns
   `preprocessor_*` if set, else `ZCODE_SMALL_FAST_MODEL` env, else the active
   model (so behavior is unchanged when nothing is configured).
2. In `forceCompaction`, when a small-fast model is configured, build the adapter
   for it and pass its model name to `llmCompact` instead of `active_model`.
3. Document that zcode applies small-fast only to compaction summaries for now
   (the reference also uses it for titles/classifiers, which zcode either lacks
   or handles via the preprocessor); broader routing is deferred.

**Acceptance criteria.**
- Write a pure test for `smallFastModel`: env set -> returns env model; env unset
  but `preprocessor_model` set -> returns preprocessor; both unset -> returns
  active model.
- Code-review check that `forceCompaction` uses the resolved small-fast model.

**Test strategy.** Pure resolver unit test under `tools/test_runner.zig`. The
`forceCompaction` routing is integration-level; assert via the resolver test plus
review.

**Risk / footguns.**
- No Bedrock `ANTHROPIC_SMALL_FAST_MODEL_AWS_REGION` analog -- zcode does not
  support Bedrock region overrides; explicitly out of scope (note it).
- Reusing `preprocessor_model` overloads its meaning. If that is too surprising,
  add a dedicated `small_fast_model` field. Prefer the dedicated field if the
  preprocessor is used for a semantically different purpose (intent extraction)
  elsewhere -- check `config/preprocessor.zig` before deciding.

**Size.** S.

---

### 7.12 Model deprecation / retirement warnings (api-providers-09)

**Goal.** Show a "model will be retired on <date>" warning when a user selects or
lists a deprecated model.

**Reference behavior.** `deprecation.ts:33-101` (`DEPRECATED_MODELS` table keyed by
model-id substrings, per-provider retirement dates; `getModelDeprecationWarning`
returns the warning string).

**Target Zig files.**
- Create `src/core/deprecation.zig` (pure; register in `main.zig` comptime block).
- Edit the model-switch / model-list command paths -- `src/repl_commands.zig`
  `switchReplModel` (~lines 4284-4356) and `renderReplModels` (~3487-3511) per the
  gap evidence -- to call `getModelDeprecationWarning` and print the warning.

**Approach.**
1. `deprecation.zig`: a comptime table of entries
   `{ key: []const u8, model_name: []const u8, retirement_dates: { firstParty, bedrock, vertex, foundry } }`,
   seeded from the reference table (`claude-3-opus`, `claude-3-7-sonnet`,
   `claude-3-5-haiku`). `getModelDeprecationWarning(model_id, provider) ?[]const u8`
   does a case-insensitive substring match on `key`, looks up the date for the
   provider, and formats "<model_name> will be retired on <date>. Consider
   switching to a newer model." Use a plain "warning:" prefix (NOT the unicode
   warning glyph; keep ASCII and no long dashes per project rules).
2. Call it from the model-switch and model-list paths; print to stderr/the REPL
   output. Avoid building dynamic strings that allocate on a hot path -- the
   warning is rare.

**Acceptance criteria.**
- Write tests in `deprecation.zig`: a deprecated model id substring + matching
  provider -> non-null warning containing the date; a non-deprecated model ->
  null; a deprecated model id for a provider with `null` retirement date -> null.
- Code-review check that the model-switch path surfaces the warning.

**Test strategy.** Pure unit tests under `tools/test_runner.zig`.

**Risk / footguns.**
- Purely informational UX. Lowest priority. The dates rot over time -- keep the
  table small and document that it mirrors the reference's
  `deprecation.ts` snapshot.
- Provider naming: zcode uses `"anthropic"`, the reference uses `"firstParty"`.
  Map zcode provider strings to the reference's provider keys inside the lookup.

**Size.** S.

---

### 7.13 Live model validation + 3P fallback suggestion (api-providers-11)

**Goal.** A dedicated "probe this exact model with a 1-token request" validator
with a per-model validity cache, and a NotFound -> suggest-newer-model hint.

**Reference behavior.** `validateModel.ts:20-159` (`validateModel`: minimal
`max_tokens:1, maxRetries:0` side-query, caches valid models; on `NotFoundError`
suggests a 3P fallback via `get3PFallbackSuggestion`: opus-4-6 -> opus41, etc.).

**Target Zig files.**
- Create `src/core/model_fallback_suggestion.zig` (pure; register in `main.zig`).
- Edit `src/provider_cmds.zig` -- `cmdModelsTest` (~lines 50-70) which already
  makes a request with `max_output_tokens=64`; lower the probe to a minimal
  request and add per-model caching, OR keep it and just add the suggestion on
  `ModelNotFound`.
- Edit the `ModelNotFound` user-facing message path in `src/main.zig` (per gap
  evidence the message currently says "check that the model id is correct / Run
  `zcode models list`") to append a 3P fallback suggestion when applicable.

**Approach.**
1. `model_fallback_suggestion.zig`: `suggest(model, provider) ?[]const u8`,
   mirroring `get3PFallbackSuggestion`/`get3PModelFallbackSuggestion`
   (`errors.ts:940-959`): only suggest for non-first-party providers; if the
   model id contains `opus-4-6`/`opus_4_6` -> suggest the opus41 string; sonnet-4-6
   -> sonnet45; sonnet-4-5 -> sonnet40. Use the model-id strings zcode already
   knows (check the static model tables in the adapters). Return the suggested
   id, owned by no one (static strings).
2. Validator: extend `cmdModelsTest` to send a minimal probe (1-token max,
   retry_count 0 so it does not retry a genuinely-missing model). Cache the result
   in a small per-process set/map keyed by `provider/model`. The reference caches
   only positive results (`validModelCache.set(..., true)`); match that.
3. Wire the suggestion into the `ModelNotFound` message in `main.zig` and into
   `cmdModelsTest`'s failure output.

**Acceptance criteria.**
- Write tests in `model_fallback_suggestion.zig`: `suggest("claude-opus-4-6", "openrouter")`
  -> the opus41 string; `suggest("claude-opus-4-6", "anthropic")` -> null
  (first-party); a model with no known successor -> null.
- Code-review check that `ModelNotFound` surfaces the suggestion when non-null.

**Test strategy.** Pure suggestion-mapping unit tests. The live-probe validator is
hard to unit-test without network; cover the caching logic with a pure test if the
cache is extracted into a testable helper, and otherwise rely on `cmdModelsTest`'s
existing manual exercise.

**Risk / footguns.**
- Lowest priority. zcode already validates implicitly via `/v1/models` discovery
  and by attempting the request. The dedicated 1-token probe is a nicety; do not
  let it add a startup-latency regression -- only probe on explicit `models test`
  / model switch, never on every send.
- The suggestion strings must reference real model ids zcode supports; pull them
  from the adapters' static model tables, not hardcoded guesses.

**Size.** S.

---

## Verification

1. **Build and install per CLAUDE.md.** Bump the patch version in
   `build.zig.zon` (`.version = "X.Y.Z"`), then:
   ```
   /Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build -Doptimize=ReleaseFast
   rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode
   ```
   (The `rm -f` first is mandatory on macOS: overwriting the binary in place
   invalidates the ad-hoc signature and the next run is SIGKILLed.)
2. **Full test suite.** `zig build test` must pass. Every new pure module
   (`retry_after.zig`, `max_tokens_overflow.zig`, `custom_headers.zig`,
   `deprecation.zig`, `model_fallback_suggestion.zig`) and the extended modules
   (`fallback_model.zig`, `backoff.zig`, `reactive_compaction.zig`,
   `extractors.zig`, `common.zig`, `error_hints.zig`) must have new `test` blocks
   that run under `tools/test_runner.zig`. Confirm each new module is registered
   in the `src/main.zig` comptime block (lines 90+) so the custom runner discovers
   its tests.
3. **No dead-code regression.** After this phase, grep must show real call sites:
   `grep -rn "fallback_model.pick\|backoff.shouldRetry\|backoff.delayMs\|reactive_compaction.reduce\|retry_after\." src --include=*.zig | grep -v "_test\|test \""` should return production (non-test) hits, unlike today where these helpers are only referenced from `main.zig`'s test-discovery block.
4. **Manual checks (live, optional but recommended for the medium/high gaps).**
   - Fallback swap (7.4): set `fallback_model` in config, point `provider_base_url`
     at a mock that returns 529 three times then succeeds, confirm zcode announces
     the swap and continues. With `fallback_model` unset, confirm it surfaces the
     overload error unchanged.
   - Reactive compaction (7.5): drive a turn whose history exceeds the model's
     limit against a mock returning a 400 "prompt is too long: N > M", confirm the
     turn retries with reduced history and succeeds rather than failing.
   - Retry-After (7.2): mock a 429 with `retry-after: 2`, confirm the wait is ~2s
     (header-driven), not the linear `attempt*300ms`.
   - SSL hint (7.9): point `provider_base_url` at an https host with a self-signed
     cert, confirm the error message includes the CA-bundle / proxy hint.
5. **Diff hygiene.** The "never swap" comment at `agent_history.zig:363-365` should
   be updated (not just deleted) to document the new gated swap. Confirm default
   config (no `fallback_model`) produces byte-identical behavior to today on
   overload, so the deliberate-divergence note holds.

## Out-of-scope / deferred notes

- **Fast-mode (Claude fast/priority tier) handling** (`withRetry.ts:261-314`):
  zcode has no fast-mode concept. The overage-disabled-reason header, fast-mode
  cooldown, and fast-mode rejection paths are out of scope.
- **OAuth / Bedrock / Vertex auth-error retry branches** (`withRetry.ts:218-251`,
  `:631-694`): 401/403 token-refresh, AWS/GCP credential cache clearing. zcode's
  auth model differs; covered (if at all) by the auth/credentials phase, not here.
- **Mock rate-limit injection** (`/mock-limits`, `rateLimitMocking.ts`): an
  ant-internal test affordance, not a parity requirement.
- **Rich rate-limit messaging from `anthropic-ratelimit-unified-*` headers**
  (`errors.ts:465-558`: five_hour / seven_day / overage status messages): this
  phase honors the `reset` header for timing (Task 7.2) but does not build the
  full quota-message UX. Deferred unless a later phase targets the rate-limit UX.
- **Bedrock `ANTHROPIC_SMALL_FAST_MODEL_AWS_REGION`** (api-providers-16): zcode
  has no Bedrock region override; out of scope.
- **LLM-summarization compaction (compaction-01)** and **token-budget /
  Stop-hooks wiring (agent-loop-06/07)**: referenced in the agent-loop-04 notes
  but tracked in their own gaps/phases. The compaction circuit breaker (Task 7.7)
  is built here so it is ready when compaction-01 lands, but the LLM
  summarization itself is not in this phase.
- **HTTP-date form of `retry-after`** (`Retry-After: <http-date>`): the reference
  only parses integer seconds; this phase matches that and does not handle the
  date form.
- **First-party vs third-party distinction for `x-client-request-id`** (7.10): if
  zcode has no clean first-party flag, the header is injected for all providers
  and the divergence is documented rather than gated.
