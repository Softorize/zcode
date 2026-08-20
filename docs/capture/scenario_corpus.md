# Initial scenario corpus (Phase 0, issue #561)

Per ADR 0010, scenarios live under `scenarios/<scenario_name>/`. This
is the initial ~10-scenario corpus, one example per class. Each must
be capturable end-to-end by both the reference runner (#562) and the
zcode runner (#563).

| # | scenario_name | class | description |
|---|---|---|---|
| 1 | `command-commit-basic` | command | `/commit` in a clean git repo with one staged file. Covers: slash-command dispatch, git tool invocation, commit-message generation. |
| 2 | `command-doctor` | command | `/doctor` in a working repo. Covers: diagnostic output, environment probing. |
| 3 | `command-compact-empty` | command | `/compact` on a near-empty session. Covers: compaction entry point. |
| 4 | `tool-read-file` | tool | A single-turn prompt asking the agent to read a specific file. Covers: FileRead tool schema, tool-use round-trip, tool-result rendering. |
| 5 | `tool-bash-echo` | tool | A single-turn prompt asking the agent to run `echo hello`. Covers: Bash tool schema, permission prompt, stdout capture. |
| 6 | `runtime-stream-basic` | streaming | A single-turn prompt producing a short non-tool response. Covers: SSE event sequence (message_start, content_block_start, content_block_delta, content_block_stop, message_delta, message_stop). |
| 7 | `runtime-retry-429` | retry | A prompt where the first provider call returns HTTP 429 and the second succeeds. Covers: retry decision, backoff, eventual success. |
| 8 | `runtime-token-count` | runtime | A multi-turn conversation long enough to exercise the token-count path near the context-window threshold. Covers: token accounting, context-pressure behavior. |
| 9 | `ux-permission-prompt` | UX | A tool invocation that triggers an interactive permission prompt. Covers: dialog render, keystroke handling (y/n/e), accept/deny flow. |
| 10 | `ux-spinner-basic` | UX | A long-running tool call that renders a spinner during execution. Covers: spinner render frames, spinner stop on completion. |

## Notes

- The reference is the installed `claude` binary (see ADR 0010
  "Reference oracle"). The reference runner (#562) spawns `claude -p
  --output-format=stream-json --input-format=stream-json` over a PTY.
- Scenarios 6-8 require a working provider endpoint or a mock provider.
  The harness records whatever the CLI sends; if a mock is used, the
  `wire.jsonl` will contain the mock's responses, which is fine for
  format verification but not for behavioral parity claims.
- Scenarios 9-10 require a real PTY; both runners (reference and zcode)
  use the same PTY recorder.
- The corpus is intentionally small. Phase 1+ slices will expand it
  per feature.
