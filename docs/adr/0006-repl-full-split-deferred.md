# REPL god-module: dedup shared helpers, defer the full split

**Status:** accepted

An architecture review flagged `cli/repl.zig` (~8k lines) and
`cli/repl_overlay.zig` (~6k lines) as god-modules and proposed extracting
internal seams (`InputState` / `ViewState` / `SessionState`), a shared
`ModalRender`, and a `terminal_utils` module, plus deduping `sanitizeText`.

We take the safe sub-win now and defer the large structural split.

## What we did

- **Deduped terminal sizing and `sanitizeText` in `repl_overlay.zig`.** The
  review claimed 4× / 5× duplication, but on inspection `repl.zig` and
  `repl_agent.zig` already delegate to the public helpers in `repl_spinner.zig`.
  The only real duplicate copies were in `repl_overlay.zig`; those now delegate
  to `repl_spinner` too (verified byte-identical first). Terminal sizing and
  text sanitization now have one home, which is where resize/SIGWINCH handling
  should live.

## What we deferred and why

- **The `run()` internal-seam split (`InputState`/`ViewState`/`SessionState`)
  and the `ModalRender` extraction are not done.** They are large, touch the
  most interactive surface in the app, and carry real regression risk that the
  test suite cannot fully cover (terminal rendering, input handling, and the
  spinner thread are exercised by hand, not in CI). The review itself rated the
  full split "Speculative." The dedup captures the concrete, verifiable win;
  the structural split would be a multi-pass effort better done deliberately,
  not as part of an audit sweep.

## Consequence

The terminal/sanitize dedup is complete. A future, dedicated effort can revisit
the `run()` decomposition and `ModalRender` if the REPL needs further work; it
should be scoped and tested on its own, not bundled with unrelated changes.
