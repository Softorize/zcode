---
title: "#"-prefix memory-capture input mode
tags: [decision, domain]
created: 2026-05-30
updated: 2026-05-30
sources:
  - src/core/memory.zig (appendUserMemory, isMemoryCapture, projectMemoryFilePath)
  - src/core/memory_messages.zig
  - src/cli/repl.zig (submit-path fast-path, after the `!` bash block)
  - docs/parity-audit-2026-05-29/phase-15-ui-rendering-and-terminal-layer-word-diff-th.md (Task 3, ui-render-03)
---

# "#"-prefix memory-capture input mode

## Summary
Phase 15 Task 3 (ui-render-03). Typing a line whose first non-space byte is `#`
with a non-empty remainder appends that remainder to the project instruction
file and acknowledges with a randomized confirmation. No model turn is started.
This mirrors the reference's leading-`#` memory mode
(`UserMemoryInputMessage.tsx`) and `getSavingMessage()`.

## Key points
- `memory.isMemoryCapture(prompt)` is the unit-tested predicate: trimmed, first
  byte `#`, and a non-empty remainder after the `#`. A bare `#` is NOT a capture.
- Persistence target: `memory.projectMemoryFilePath(alloc, workspace)` prefers an
  existing `ZCODE.md` (zcode's primary instruction filename, precedence 100 in
  `instructions.zig`), then an existing `CLAUDE.md`, and otherwise DEFAULTS to
  creating `CLAUDE.md` for reference parity. `workspace` is the REPL's
  `options.status_workspace` (project-root cwd).
- `memory.appendUserMemory` writes the line as a bullet under a stable
  `## User Memories` section, creating the file/section if absent. It is
  read-modify-atomic-write (read existing, build new, temp-file + rename) rather
  than an O_APPEND seek, because the instruction file is small and this sidesteps
  the 0.16 positional-read/seek footguns. The file is written **0o644** (ordinary
  project file, often in VCS), NOT the 0o600 used for `~/.zcode/memory/*.md`.
- Confirmation: `memory_messages.savingMessage(pick)` returns one of
  `Got it.` / `Good to know.` / `Noted.` (`pick % 3`). The REPL picks `pick`
  from one `rng.bytes()` byte -- never `std.crypto.random.*`.
- The `<user-memory-input>` tag from the reference is NOT persisted to zcode's
  model history; memory is re-read from the instruction file next session, so the
  load-bearing behavior is just the file append + confirmation echo.

## Gotchas
- `std.Io.Dir.renameAbsolute` ASSERTS both paths are absolute and panics on a
  relative path. The project file path can be relative (`workspace == "."`), so
  `appendUserMemory` uses `cwd().rename(tmp, cwd, target, io)`, which handles both
  absolute and relative forms. `memory.zig`'s older `writeMemoryFileAtomic` only
  works because the memory-dir path is always the absolute `~/.zcode/...`.
- The submit-path fast-path lives right after the `!` bash-input block in
  `repl.zig` and mirrors it exactly (early `continue`, no dispatch, fullscreen vs
  plain echo). It must stay before the `/`-slash-command dispatch, which is fine
  because `#` never collides with `/` or `!`.

## Related
- [[memory-fork-pattern]] - the other memory subsystem (auto-extraction/session
  summarizer); unrelated to `#`-capture but shares the `core/memory.zig` module.
