---
title: Architecture
tags: [architecture]
created: 2026-05-23
updated: 2026-05-23
sources:
  - src/agent_tools.zig
  - src/agent_history.zig
  - docs/adr/
---

# Architecture

## Summary
zcode is a Zig (0.16) reimplementation of a Claude Code-style CLI agent. The
agent loop, tool execution, providers, MCP, and session persistence are the
major subsystems. This page records intent and invariants; durable design
decisions live as ADRs in `docs/adr/` (committed with the code).

## Key points
- Three front-ends drive the same agent runtime: REPL (interactive),
  `api_server.zig`, `remote_daemon.zig`.
- Tool authorization is ONE ordered gate (see Tool execution below) -- after a
  2026-05 refactor it is no longer smeared across files.
- Conversation history is a sealed module, not a raw ArrayList.

## Components

### Tool execution (single gate)
`agent_tools.executeToolCall` is the one ordered authorization sequence:
active-agent policy -> sandbox -> `policy.classifyTool` (once) -> arg-repair ->
permission rules -> approval -> `runApprovedToolTrace` (pre-plugin, pre-hook,
`registry.applyExecutionGates` [empty-workspace + bash_security], then
`registry.dispatch`, post-plugin, post-hook). `registry.zig` is dispatch +
execution-gate helpers only. Approval is injected as one `ApprovalHandler`
{ctx, prompt}; REPL installs one, API/daemon leave it null (auto-deny).

### Conversation history
`agent_history.History` owns `{allocator, turns, store}` with a small interface:
`len`/`at`/`view` (reads) and `append`/`clearInMemory`/`truncateFrom`/`replaceWith`
(mutations). Content lifecycle and the (deliberately append-only) disk policy
live here, not at call sites. `.turns` is private.

### Providers
`types.ProviderAdapter` VTable; `providers/mod.createAdapter` selects by name.
Response parsing is intentionally polyphonic (try each shape) for
OpenAI-compatible/proxy robustness -- see ADR-0001.

### MCP
`mcp/client.zig`; transport dispatch is centralized in `rpcRequestForServer`
(HTTP / stdio / WebSocket + persistent variants) -- see ADR-0002.

### Sessions
Layered, not circular: `session/store.zig` (JSONL + encryption primitives) <-
`session/bundles.zig` (checkpoint/fork/share/undo) <- `session_cmds.zig` (CLI)
<- `session_mgmt.zig` (front-end orchestration) -- see ADR-0005.

### Prompt assembly
`core/prompt_engine.build()` orchestrates five independent modules (compaction,
instructions, context, prompt_helpers, local budget selection) in a clean linear
sequence -- see ADR-0004.

## Invariants
- Every tool call crosses the single gate; `classifyTool` runs exactly once.
- History `.content` strings are owned by `History` and freed exactly once.
- Disk session JSONL is append-only; in-memory clear/truncate/replace do not
  rewrite it (reload reconciles via snapshot).

## Related
- [[ci-and-build]] - building and getting CI green

## Sources
- docs/adr/0001..0006 - recorded architecture decisions from the 2026-05 audit
