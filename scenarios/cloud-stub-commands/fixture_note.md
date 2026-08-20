# #567 fixture note: cloud-stub-commands

This scenario verifies that all 8 cloud-dependent commands are
recognized by zcode and return a labeled stub message.

## Why no wire.jsonl capture

The zcode runner (`zcode exec --json`) sends input as a user prompt to
the model, not as a slash command to the REPL dispatcher. Slash commands
like `/teleport` are handled in the REPL's command dispatcher, not in
the headless exec path. Capturing them via the harness would require a
PTY-based interactive capture (deferred per #562/#563 notes).

## The fixture IS the Zig test

The verification for #567 is the Zig test
`all 8 cloud-dependent commands are stubbed with dependency-explaining messages`
in `src/core/cc_stub_commands.zig`. It asserts:
1. All 8 commands (`/teleport`, `/remote-setup`, `/remote-env`,
   `/mobile`, `/desktop`, `/install-github-app`, `/install-slack-app`,
   `/oauth-refresh`) are recognized by `lookup()`.
2. Each stub message contains a dependency explanation (matches
   `requires`|`out of scope`|`does not run`|`does not bundle`).

## Running the fixture

```
zig build test   # runs the test, 3876 passed 2 skipped 0 failed as of this commit
```

## What changed for #567

- Added `/oauth-refresh` to the stub table (was missing - would have
  returned "unknown command").
- Added the verification test.
