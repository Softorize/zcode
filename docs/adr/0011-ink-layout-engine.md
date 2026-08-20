# ADR 0011: Ink layout engine in Zig

**Status:** Accepted
**Date:** 2026-06-22
**Parent:** PRD #560 — zcode strict-spec + pixel parity with Claude Code

## Context

Issue #574 (Phase 4, HITL) requires building `core/ink_layout`,
`core/ink_render`, and `core/ink_focus` as the foundation for
pixel-parity with the reference's React+Ink TUI. The reference uses
Facebook's Yoga (C++ flexbox engine via WASM bindings) in
`src/ink/layout/yoga.ts`.

## Decision

Build a **minimal flexbox subset** in pure Zig, not a full Yoga port.

### What's in v2 (this slice + the two-pass upgrade)

- `LayoutNode` tree: id, flex_direction, width/height, min/max constraints,
  padding/margin/border (per-edge Edges), flex_grow/flex_shrink/flex_basis,
  justify_content, align_items, flex_wrap, text content, children.
- `layout()` two-pass: measure children (intrinsic), distribute free space
  via flex_grow/shrink along main axis, position per justify_content
  (flex-start/center/flex-end/space-between/space-around) and align_items
  (flex-start/center/flex-end/stretch), flex-wrap (nowrap/wrap with
  line breaking).
- `measureText()`: terminal-cell measurement (1 char = 1 column).
- `ink_render`: ANSI byte buffer with CSI positioning + SGR styles
  (bold/dim/italic/underline/inverse/strikethrough + 16 colors).
- `ink_focus`: focus ring, tab/shift-tab traversal, KeyAction parsing.

### What's still deferred (v3+)

- absolute positioning
- align-content (multi-line cross distribution)
- measure functions for dynamic content
- text wrapping and truncation
- color management (256-color, truecolor)
- the reconciler diffing loop (Ink's incremental re-render)
- pointer/mouse events
- focus groups, focus trapping

### Why minimal, not full Yoga

1. Full Yoga is multi-month work and would block every Phase 4 slice.
2. The minimal subset unblocks #575 component work for basic
   components (text, boxes, simple lists).
3. Each deferred property lands incrementally as a component needs it,
   with its own test. This avoids speculative generality.
4. Pure Zig (no WASM bindings) keeps the build self-contained.

## Consequences

- Pixel-parity with Ink is substantially closer with v2: the core
  flexbox layout (grow/shrink, justify, align, wrap, margins, borders,
  min/max) now matches Yoga's behavior for the common cases.
- Remaining gaps (absolute positioning, align-content, measure
  functions, text wrapping/truncation, the reconciler) are tracked
  above. Each lands incrementally as a component needs it.
- The reference's Ink reconciler (incremental DOM diffing) is not
  reproduced; zcode re-renders fully. Acceptable because terminal
  output is cheap; becomes a perf concern only for very large trees.
