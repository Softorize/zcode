# Terminal-response parsing (terminal-01)

`src/core/terminal_response.zig` is a pure, no-IO parser that recognizes inbound
terminal-response escape sequences and routes them out of the keypress path so
they do not leak into the prompt as garbage bytes. Mirrors the reference
`parseTerminalResponse` in `src/ink/parse-keypress.ts`.

## What it parses (and what it does not, yet)

This task covers only the CSI-framed responses:
- DECRPM `CSI ? mode ; status $ y`
- DA1 `CSI ? params c`
- DA2 `CSI > params c`
- kitty keyboard flags `CSI ? flags u`
- DSR cursor position (private form) `CSI ? row ; col R`

The `TerminalResponse` union also declares `osc` and `xtversion` variants, but
their assembly and parsing are deferred to Task 11 (terminal-02 / XTVERSION).
Reason: the input reader in `repl_input.zig` assembles a CSI sequence up to a
final byte in `0x40..0x7E`, which does NOT cover the BEL / ST terminators that
OSC and DCS use. Teaching the reader to read past BEL / ST is Task 11's job.

## Non-obvious decisions / footguns

- **DSR vs modified-F3 disambiguation.** `CSI ? row;col R` (with the private `?`
  marker) is a cursor-position report; `CSI row;col R` WITHOUT the `?` is a
  genuine modified-F3 key (Shift+F3 = `CSI 1;2 R`, etc.). Only the `?` form is
  treated as a response. This is enforced in `parseCsi`: the `?`-prefixed branch
  is the only place `R` is accepted.

- **The assembler drops the leading `ESC [`.** In `repl_input.zig`, the `seq`
  buffer holds only the bytes AFTER `ESC [`. The wiring reconstructs the full
  sequence (`\x1b[` + `seq[0..len]`) into a stack buffer before calling
  `terminal_response.parse`, because `parse` expects the full framed sequence.

- **Slice payload lifetime.** `da1` / `da2` carry a `[]const u8` that points into
  the caller's read buffer (transient). `recordTerminalResponse` in
  `repl_input.zig` copies those into a static `last_response_buf` so the recorded
  value survives the next read. Scalar variants (decrpm/kitty/cursor) carry no
  slices and are stored by value.

- **Consume, do not act.** A recognized response returns `.none` from the input
  parser (responses are not user input). `takeLastTerminalResponse()` exposes the
  last one for Task 11 to consume.

## Tested

- `src/core/terminal_response.zig`: per-variant parse tests plus negative cases
  (plain key, modified-F3, non-CSI framing, empty/short, malformed DECRPM,
  garbage DA1 params).
- `src/cli/repl_input.zig`: `isTerminalResponseSequence` predicate test, and
  `recordTerminalResponse` round-trip tests (slice copy for DA1, scalar for
  DECRPM).
