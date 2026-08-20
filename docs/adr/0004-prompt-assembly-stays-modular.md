# Prompt assembly stays five modules, not one PromptAssembly

**Status:** accepted

An architecture review suggested consolidating prompt building -- spread across
`prompt_engine.zig`, `prompt_helpers.zig`, `instructions.zig`, `context.zig`,
and `compaction.zig` -- into one deep `PromptAssembly` module, on the grounds
that a caller must "bounce between five modules."

We keep the five modules.

## Why

1. **`prompt_engine.build()` is already a clean linear sequence**, not a tangle:
   `compaction.maybeCompact` → `instructions.discover` → `context.gather` →
   `prompt_helpers` rendering → local `selectBudgetedContextBlocks`. Each module
   is called 0-2 times in a straight data flow; there are no cycles.
2. **There is already a single entry point.** `agent_runtime` (and `benchmark`)
   call `prompt_engine.build()` once per turn. The other four modules are an
   internal implementation detail; no typical caller imports all five.
3. **The modules have zero cross-imports** and own genuinely distinct concerns
   (history summarization, instruction-file discovery + caching, git/repo state
   capture, stateless rendering helpers). `context.gather` is independently
   reused by the preprocessor.
4. **Deletion test fails.** Merging produces a single ~3.5k-line file that mixes
   LLM-compaction, file-walk caching, git capture, and rendering, and regresses
   testability (each subsystem currently has independent fixtures). Complexity
   moves; it does not shrink.

A doc comment on `build()` now maps the five-step flow, which addresses the real
concern (flow legibility) without the risky refactor.

## Consequence

Future reviews should not re-suggest a `PromptAssembly` merge. Keep the entry
point at `prompt_engine.build()` and the subsystems separate.
