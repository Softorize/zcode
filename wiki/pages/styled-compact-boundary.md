# Styled compact-boundary message (Phase 15 Task 5, ui-render-05)

## What

The compaction boundary is shown to the user as a styled line matching the
reference `CompactBoundaryMessage.tsx`:

```
✻ Conversation compacted (ctrl+o for history)
```

instead of the old bare `compaction complete` / `Conversation compacted by
control action.` note.

## Where the pieces live

- **Data layer (Phase 8 / compaction-14):** the boundary is persisted in history
  as a structured `compact_boundary trigger=... pre_tokens=... tools=...` system
  turn (`core/compaction.zig` `serializeCompactBoundary` / `parseCompactBoundary`,
  `types.CompactBoundary`). The display string is NOT what gets stored; the
  structured marker is, so `/context` telemetry and `--resume` can still parse it.
- **Render unit:** `core/compaction.zig` `renderCompactBoundary(writer, use_color)`
  is the pure, IO-free, unit-tested helper. It emits `✻ Conversation compacted
  (ctrl+o for history)` using `figures.TEARDROP_ASTERISK` (the `✻` U+273B glyph
  byte sequence `\xe2\x9c\xbb`) wrapped in dim SGR (`\x1b[2m`...`\x1b[0m`) when
  `use_color`. Mirrors the `core/thinking_render.zig` pattern from Task 4
  (leaf core module, local ANSI constants, no cli dependency).
- **Wiring:** the `/compact` command handler (`repl_commands.zig`) returns the
  rendered boundary line as its user-facing result.

## Decision: color-agnostic at the runtime command layer

The `/compact` result is emitted with `use_color = false` (glyph + text, no SGR).
Reasons:

1. The runtime command layer (`repl_commands.zig`) does not own a color
   decision (no `Options`); deciding color there would be the wrong layer.
2. In fullscreen mode the REPL transcript sanitizer strips SGR regardless
   (see the `appendThinkingIndicator` comment in `cli/repl.zig`: "Color is
   stripped by the transcript sanitizer regardless").
3. In non-fullscreen mode the command result is passed through
   `writeStyledText` (the markdown renderer), which is not designed to receive
   raw SGR escape bytes mid-text; embedding them risks mangling.

The load-bearing visible change is the `✻` glyph + the new body + the
`ctrl+o for history` hint. The dim styling is available through
`renderCompactBoundary(writer, true)` for any future caller that owns a color
decision (e.g. a dedicated non-markdown display surface), and the dim path is
unit-tested.

## ctrl+o

`ctrl+o` is the default transcript toggle (`repl_input.zig` `.toggle_transcript`,
matching the reference's `app:toggleTranscript`). It is hardcoded in the hint;
if the toggle ever becomes rebindable, read the bound chord here (the reference
also falls back to the literal `ctrl+o`).

## Tests

- `core.compaction.test.renderCompactBoundary contains the glyph, body and ctrl+o history hint`
- `core.compaction.test.renderCompactBoundary with color off has text but no SGR escapes`
