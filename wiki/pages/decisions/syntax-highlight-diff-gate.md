---
title: Diff-content syntax-highlight gate (CLAUDE_CODE_SYNTAX_HIGHLIGHT)
tags: [decision]
created: 2026-05-30
updated: 2026-05-30
sources:
  - src/cli/repl_edit.zig:7 (syntaxHighlightEnabled + writeCodeContent)
  - src/core/env_registry.zig (CLAUDE_CODE_SYNTAX_HIGHLIGHT entry)
  - docs/parity-audit-2026-05-29/phase-15-ui-rendering-and-terminal-layer-word-diff-th.md (Task 6, ui-render-07)
---

# Diff-content syntax-highlight gate (CLAUDE_CODE_SYNTAX_HIGHLIGHT)

## Summary

Phase 15 Task 6 (ui-render-07) added the `CLAUDE_CODE_SYNTAX_HIGHLIGHT` env
gate around diff-content syntax highlighting. zcode defaults the feature ON
(matching its pre-existing behaviour); the reference defaults it OFF. This is
a deliberate, documented deviation so it is not re-litigated.

## Key points

- The reference (`StructuredDiff/colorDiff.ts`) gates per-language diff
  highlighting OFF by default and only turns it on when
  `CLAUDE_CODE_SYNTAX_HIGHLIGHT` is set.
- zcode has ALWAYS highlighted diff context lines and solo +/- lines
  (`writeDiffCodeLine` -> `repl_markdown.writeCodeLine`). Matching the
  reference's default-off would be a visible regression for existing users.
- Decision: default ON. The env var is the OVERRIDE. A falsy value
  (`0`/`false`/`no`/`off`, via `core/env.isEnvDefinedFalsy`) turns it OFF;
  any truthy value or an unrecognised value or unset keeps it ON.
- The word-diff PAIR path (`writeDiffCodePair`) still skips language
  highlighting unconditionally -- that is a separate, kept design choice
  (layering the fzf-style intra-line accent on top of syntax colours is
  noisy). The gate only affects context + solo +/- lines.

## Details

- `syntaxHighlightEnabled()` returns
  `!env.isEnvDefinedFalsy("CLAUDE_CODE_SYNTAX_HIGHLIGHT")`. It is read ONCE
  per diff block (in `formatEditBlock` and `renderDiffSection`) and threaded
  down as a `syntax_on: bool` parameter to `writeDiffCodeLine`, so the
  per-line hot path never touches the environment.
- New helper `writeCodeContent(writer, display, lang, syntax_on)`: when
  `syntax_on` it routes through `repl_markdown.writeCodeLine` (which itself is
  still gated by `shouldUseColor` / isatty / NO_COLOR); when off it writes the
  already-clipped text verbatim so only the caller's tone colour applies.
- Footgun for tests: `repl_markdown.writeCodeLine` keyword SGR
  (`\x1b[38;5;176m`, `ANSI_CODE_KEYWORD`) is suppressed when stdout is not a
  TTY (`shouldUseColor` calls `isatty`). So the unit tests assert the OFF path
  hard (raw bytes, no keyword SGR) and the env-gate logic precisely; the ON
  path SGR is only observable on a real TTY.

## Related

- [[styled-compact-boundary]] - sibling Phase 15 UI-render parity task
- [[cc-parity-audit-2026-05]] - the audit that produced Phase 15

## Sources

- src/cli/repl_edit.zig:7 - syntaxHighlightEnabled, writeCodeContent, threaded syntax_on
- src/core/env_registry.zig - CLAUDE_CODE_SYNTAX_HIGHLIGHT registry entry
