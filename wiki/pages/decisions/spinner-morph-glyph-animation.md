# Decision: animated spinner morph-glyph (gated)

Phase 15 Task 8 (ui-render-06 / terminal-11). Reintroduced the reference's
animated leading spinner glyph after a prior simplification had collapsed it
to a single static `●`.

## Context

The reference (`Spinner/SpinnerGlyph.tsx`) cycles a 6-glyph morph set
`·✢✳✶✻✽` forward then reversed (12 frames). An earlier zcode change
collapsed the leading status glyph to a static `●` because the old breathing
cycle "felt like the text was moving" -- the user only wanted the braille
*pulse bar* (`buildActivityPulse`) to animate, not the leading glyph.

## What we did

- New pure module `src/core/spinner_glyph.zig`: `defaultCharacters(term,
  is_darwin)` (ghostty -> `✽`->`*`; non-darwin -> `✳`->`*`), `frameGlyph`
  over the 12-frame forward-then-reversed sequence, `interpolateRgb`
  (rounded integer lerp), `reducedMotionDim` (2s cycle, 1s lit / 1s dim),
  `stalledIntensityPercent`, and `ERROR_RED = (171,43,63)`.
- Wired into `src/cli/repl_spinner.zig` `spinnerMain`: the leading glyph now
  cycles the morph set; when the turn stalls (>=5s waiting on the model, no
  tool activity) the glyph color drifts from the accent toward error red;
  reduced motion renders a calm flashing `●` instead of suppressing the
  spinner.

## Gates / escape hatches

- `ZCODE_STATIC_SPINNER_GLYPH=1` -> revert to the static `●` leading glyph
  (honors the prior "text feels like it's moving" feedback without a code
  change). Default: animated.
- Reduced motion: `REDUCE_MOTION` or `ZCODE_REDUCE_MOTION` (any non-empty
  value) now shows the calm flashing dot (reference behavior) rather than
  fully suppressing the spinner thread. `ZCODE_REDUCE_MOTION=hard` keeps the
  old full-suppression behavior for users who want zero animation while
  preserving token accounting + spinner-gated cancel hints.

## The braille pulse bar is separate

`buildActivityPulse` (the in-place braille spinner) was left untouched -- it
is the deliberate "one point of motion" indicator and is not the leading
glyph. Only the leading status glyph was re-animated.
