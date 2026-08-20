---
title: Parsing curl -D header dumps (final-block-only)
tags: [gotcha]
created: 2026-05-30
sources:
  - src/providers/extractors.zig (parseCurlHeaderDump, freeHeaderDump, findHeader)
  - src/providers/common.zig (callHttpWithHeaders, HttpResult, readAndParseHeaderDump)
---

# Parsing curl -D header dumps (final-block-only)

## Summary
Phase 7 Task 7.1 added response-header capture to the non-streaming curl
chokepoint. curl writes inbound headers to a private 0600 `.hdr` tempfile via
`-D <path>` (NOT `-D -`, which would interleave headers with the body ahead of
the `__ZCODE_HTTP_STATUS__` marker and break `parseCurlResponseWithStatus`).
`extractors.parseCurlHeaderDump` parses that dump into `[]HeaderPair`.

## Key points
- With `-L` (follow redirects) curl emits one header block PER response in the
  redirect chain. We want only the FINAL block (the response the body belongs
  to). The parser resets its accumulator ONLY when it sees a new `HTTP/` status
  line, never on a blank line.
- Footgun hit during implementation: an early version also reset on the blank
  line that terminates a block. That blank line also terminates the FINAL block,
  so it wiped the headers we just parsed. Symptom: the redirect test failed with
  `TestExpectedEqual` because `findHeader` returned null for everything. Fix:
  blank lines are ignored; reset is driven purely by the next `HTTP/` line.
- Header names are lowercased on parse (HTTP headers are case-insensitive).
  `findHeader(headers, "retry-after")` expects a lowercase query.
- Pairs returned by `parseCurlHeaderDump` are SELF-OWNED (both name and value
  are heap copies) so they outlive the raw dump buffer, which the caller frees
  immediately. Free the whole slice with `freeHeaderDump` (frees name AND
  value). Do NOT call `freeHeaderDump` on `HeaderPair`s built from string
  literals (test fixtures own nothing).
- Memory bounds against a hostile server: `MAX_HEADERS = 200`,
  `MAX_VALUE_LEN = 8 KiB` per value.
- The header tempfile is created by curl, not us, so it may be absent if curl
  exited 0 without writing it. `readAndParseHeaderDump` swallows read/parse
  errors (incl. 0.16 `error.StreamTooLong` from `readFileAlloc(.limited(N))`)
  and returns empty headers rather than failing the request.
- `callHttp` stays a thin wrapper returning just `[]u8`; the new
  `callHttpWithHeaders` returns `HttpResult { body, status_code, headers }` for
  the retry path (Tasks 7.2/7.3 consume the headers). The non-streaming argv
  array was bumped `[12]` -> `[14]` to fit `-D <path>`.

## Related
- [[test-discovery]] - extractors.zig and common.zig are already registered

## Sources
- src/providers/extractors.zig - parseCurlHeaderDump / freeHeaderDump / findHeader
- src/providers/common.zig - callHttpWithHeaders / HttpResult / -D tempfile plumbing
