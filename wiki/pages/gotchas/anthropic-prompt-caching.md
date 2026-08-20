---
title: Anthropic prompt-cache ordering and the static/dynamic split
tags: [gotcha]
created: 2026-05-23
updated: 2026-05-23
sources:
  - src/providers/anthropic.zig (system split at __SYSTEM_PROMPT_STATIC_BOUNDARY__)
  - src/core/prompt_engine.zig (boundary marker placement)
---

# Anthropic prompt-cache ordering and the static/dynamic split

## Summary
Anthropic prompt caching is prefix-based: a `cache_control` breakpoint caches the
cumulative request prefix up to that point (system, then tools, then messages, in
that order). If any per-turn-changing content sits inside the cached prefix, the
prefix differs every turn and the cache never hits. zcode used to cache the WHOLE
system as one block, so dynamic sections (env, memory, skill listing) busted the
system cache every turn. Fix: split the system at the static/dynamic boundary and
cache only the static prefix.

## Key points

- Request order is fixed: `system` blocks, then `tools`, then `messages`. A
  breakpoint caches everything before it.
- Cache the STATIC system prefix only. zcode emits a
  `__SYSTEM_PROMPT_STATIC_BOUNDARY__` marker (prompt_engine) between the static
  reminders and the per-turn dynamic sections; the Anthropic provider splits
  there and puts `cache_control` on the static block, leaving the dynamic tail
  as a separate uncached block.
- The static prefix must be byte-identical across turns or it won't hit. The
  verbatim Claude Code sections in `system_prompt.zig` are deliberately constant
  (a test asserts byte-stability).
- Tool-array caching (cache_control on the last tool) only fully helps when no
  per-turn dynamic content precedes the tools. Because zcode's dynamic system
  block currently sits in the `system` field (before `tools`), the tool-cache
  breakpoint's prefix still includes that dynamic block and can miss. Relocating
  the dynamic block into the message stream (as Claude Code does with a
  <system-reminder> in the first user message) would make tool caching fully
  effective. Not yet done.
- Anthropic allows up to 4 cache breakpoints per request; zcode uses static
  system + tools + a user-content breakpoint.

## Related
- [[ci-and-build]] - other provider/build footguns

## Sources
- src/providers/anthropic.zig - writeRequestBody system split + tool cache_control
- src/core/prompt_engine.zig - __SYSTEM_PROMPT_STATIC_BOUNDARY__ placement
