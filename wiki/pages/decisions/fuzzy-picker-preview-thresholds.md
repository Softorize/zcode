---
title: FuzzyPicker preview-pane thresholds and history deviation
tags: [decision]
created: 2026-05-31
updated: 2026-05-31
sources:
  - docs/parity-audit-2026-05-29/phase-24-ui-dialogs.md
  - src/cli/repl_overlay.zig:5028 (previewSideThreshold / previewOnRight)
  - src/cli/repl_overlay.zig:5063 (langFromPath)
---

# FuzzyPicker preview-pane thresholds and history deviation

## Summary
Phase 24 Task 24.8 (ui-dialogs-09) aligned the shared fuzzy-picker preview layout with the reference. The side-vs-bottom decision is now a single pure helper `previewOnRight(kind, cols)` in `repl_overlay.zig`, keyed by picker: QuickOpen flips to a right-side preview at 120 columns, GlobalSearch at 140 (was 120), History at 100. File-preview lines in QuickOpen and GlobalSearch are now syntax-highlighted by language detected from the file extension.

## Key points
- `previewSideThreshold(.quick_open) == 120`, `.global_search == 140`, `.history == 100`. The only real numeric delta the audit found was GlobalSearch 120 -> 140; QuickOpen was already 120.
- Syntax highlighting reuses `repl_markdown.writeCodeLine` with a fixed `preview_render_options` (color on, code highlight on, theme defaults to `.dark`). It is gated by `shouldUseColor` which checks `isatty(stdout)`, so under the headless test runner no SGR escapes are emitted -- the colouring itself is a MANUAL check, not unit-tested.
- `langFromPath` uses an EXACT extension table, NOT `repl_markdown.parseCodeLang`. parseCodeLang is prefix-based for fence tags, so `"json"` prefix-matches `"js"` and wrongly returns `.javascript`. The exact table avoids that trap.

## Details
History search is a documented deviation: the History overlay lists previous *prompts* (text), not files, and has no file-content preview pane to place on the side or bottom. The `.history` threshold (100) is defined and unit-tested for completeness and future use, but the History overlay was NOT rebuilt into a dual-pane layout -- there is nothing to preview, so adding side/bottom rendering would be speculative chrome with no content. This follows the audit's own "verify the deltas are real before investing" warning.

Unit tests added in `repl_overlay.zig`: `previewSideThreshold matches the per-picker reference values`, `previewOnRight flips at the QuickOpen 120 / GlobalSearch 140 / History 100 thresholds`, `langFromPath maps extensions and ignores dotless or directory dots`, `appendHighlightedPreviewLine preserves content and passes plain through verbatim`.

## Related
- [[syntax-highlight-diff-gate]] - the other syntax-highlight toggle (diff content); same writeCodeLine family but a different gate (CLAUDE_CODE_SYNTAX_HIGHLIGHT env var)

## Sources
- docs/parity-audit-2026-05-29/phase-24-ui-dialogs.md - Task 24.8 spec
- src/cli/repl_overlay.zig - the helpers and the wired call sites
