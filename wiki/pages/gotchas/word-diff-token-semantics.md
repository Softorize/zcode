# Word-diff token semantics (ui-render-02 / change ratio)

`src/core/word_diff.zig` now has two layers:

- `commonAffixes` - one shared prefix + one shared suffix, single contiguous
  changed middle. Used as the OVER-CAP fallback only.
- `wordDiffSegments(old, new, out)` - a real multi-segment token diff. It
  tokenises both sides via the existing `tokenize` iterator (word vs non-word
  runs, where `_` and alphanumerics are "word" bytes), runs a no-alloc LCS over
  token-text equality on a fixed `[129][129]u16` stack table, backtracks, and
  merges adjacent same-tag contiguous-slice segments. Returns `null` (caller
  falls back to `commonAffixes`) when either side exceeds
  `WORD_DIFF_TOKEN_CAP` (128) tokens.

`Seg.text` slices point INTO the caller's `old`/`new` buffers. In
`writeDiffCodePair` those are the clipped `old_buf`/`new_buf` stack arrays which
live for the whole function, so it is safe - but never let a `Seg` outlive the
source buffers.

## The non-obvious correctness change to `changeRatioPercent`

`changeRatioPercent` was rewritten to sum the changed-segment lengths from
`wordDiffSegments` (matching the reference's `diffWordsWithSpace` +
`changedLength`), keeping the affix-based proxy only as the over-cap fallback.

Footgun this exposed: an underscore-joined identifier like `foo_bar_baz` is a
SINGLE token (underscore is a word byte). So `foo_bar_baz -> foo_quux_baz` is a
near-total change at the TOKEN level (ratio ~100), NOT a "small shared
prefix/suffix middle" as the old affix proxy reported. This is reference-accurate:
the `diff` library's `diffWordsWithSpace` also treats it as one word. A Task-1-era
test asserting that pair was "well under threshold" had to be re-pointed at a
genuinely word-separated example (`the quick brown fox -> the quick brave fox`,
one of four words changed). If you write a change-ratio test, use
whitespace-separated words, not snake_case identifiers, when you want a small ratio.
