# ADR 0010: Capture fixture format

**Status:** Accepted
**Date:** 2026-06-22
**Parent:** PRD #560 — zcode strict-spec + pixel parity with Claude Code

## Context

Issue #561 (Phase 0, HITL) requires a fixture format that the entire
parity-verification system will use. The format must capture three
streams in one artifact:

1. API request/response JSON (wire-level messages between zcode or the
   reference and the model provider).
2. Rendered terminal frames (ANSI capture from a pseudo-terminal).
3. Slash-command input/output (command in, structured response out).

The format shapes every downstream slice (#562 reference runner, #563
zcode runner, #564 comparison runner, and every parity task after). It
must be stable before those runners are built against it.

## Decision

The fixture format is a directory, not a single file. One directory per
scenario, named after the scenario. Inside the directory:

```
scenarios/<scenario_name>/
  meta.json              # scenario metadata
  wire.jsonl             # newline-delimited JSON, one record per wire event
  frames.bin             # length-prefixed binary stream of ANSI frames
  commands.jsonl         # newline-delimited JSON, one record per command I/O
  reference/             # captures from the reference (#562)
    wire.jsonl
    frames.bin
    commands.jsonl
  zcode/                 # captures from zcode (#563)
    wire.jsonl
    frames.bin
    commands.jsonl
  diff.json              # produced by #564, absent until the comparison runs
```

### meta.json

```json
{
  "scenario_name": "slash-commit-basic",
  "scenario_class": "command",
  "description": "Run /commit in a clean git repo with one staged file",
  "seed": {
    "cwd": "/tmp/zcode-fixtures/repo-clean-staged",
    "env_denylist": ["ANTHROPIC_API_KEY", "OPENAI_API_KEY"],
    "env_fixed": { "TZ": "UTC", "LC_ALL": "C" },
    "terminal_size": { "cols": 80, "rows": 24 }
  },
  "inputs": [
    { "type": "command", "value": "/commit" },
    { "type": "keystroke", "value": "Enter" }
  ],
  "timeout_ms": 30000
}
```

### wire.jsonl (one JSON object per line)

Each record is a wire event captured between the CLI and the provider.
The shape is provider-agnostic enough to diff but preserves the raw
payload:

```json
{"ts_ms": 1719038400000, "direction": "request", "method": "POST", "path": "/v1/messages", "headers": {"content-type": "application/json"}, "body": <raw JSON>}
{"ts_ms": 1719038401234, "direction": "response", "status": 200, "headers": {"content-type": "application/json"}, "body": <raw JSON>}
```

For streaming responses, each SSE event is its own record with
`"stream_event": "content_block_delta"` (or whatever the event type is)
and the event payload as `body`.

### frames.bin (length-prefixed binary)

A sequence of terminal snapshots. Each frame is:

```
[4 bytes: uint32 big-endian timestamp_ms]
[4 bytes: uint32 big-endian frame_len]
[frame_len bytes: ANSI-encoded terminal content for one render]
```

Frames are captured at every visible render boundary (not on every
byte). The first frame is the initial blank/ready state; the last frame
is the terminal state at scenario completion.

### commands.jsonl (one JSON object per line)

```json
{"ts_ms": 1719038400000, "command": "/commit", "args": "", "stdout": "...", "stderr": "...", "exit_code": 0, "rendered_frames": [0, 1, 2]}
```

`rendered_frames` is an index list into `frames.bin` showing which
frames were emitted while this command was active. This lets the
comparison runner correlate command output with on-screen renders.

### diff.json (produced by #564, not authored)

```json
{
  "scenario_name": "slash-commit-basic",
  "wire_diff": {"records_matched": 4, "records_differed": 1, "diffs": [...]},
  "frame_diff": {"frames_matched": 12, "frames_differed": 3, "diffs": [...]},
  "command_diff": {"commands_matched": 1, "commands_differed": 0}
}
```

## Reference oracle

The reference is the **installed `claude` binary** on the machine
(`/Users/example/.local/bin/claude`, version 2.1.185 or later), driven
over a PTY for capture. The leaked TS source at
`~/Downloads/claude-code-main/` is a **spec reference only** - it is
read to understand what to implement (direct-port per PRD #560), but
is not run, because it lacks `package.json`/`node_modules` and imports
Anthropic-internal packages not available on npm.

The installed binary is the authoritative behavioral oracle. It
supports `-p --output-format=stream-json --input-format=stream-json`
for machine-readable wire-level I/O, which maps directly to
`wire.jsonl`.

## Consequences

- Directory-per-scenario is heavier than a single file, but it lets the
  runners stream large wire/frame logs without holding everything in
  memory.
- JSONL for wire and commands gives structural diffing without a custom
  parser.
- Binary for frames is necessary because ANSI content is not line-safe.
- The `reference/` vs `zcode/` split means the comparison runner (#564)
  gets two paths and emits `diff.json`; the runner does not need to know
  which side is which.
- The `env_denylist` in meta.json prevents accidental capture of real
  API keys. Runners must refuse to start if any denylisted env var is
  set.
- `terminal_size` is fixed per scenario so frame dimensions are
  deterministic. The comparison runner will not attempt to rescale
  frames.
- The reference is a moving target (the installed binary auto-updates).
  Fixtures must record the reference version in `meta.json` so drift is
  detectable. Re-capture is a recurring cost, not a one-time event.
