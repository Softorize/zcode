# Best Practicies

Last updated: 2026-04-01

## Summary

On March 30-31, 2026, Anthropic accidentally published a Claude Code npm package build that exposed a JavaScript source map in `@anthropic-ai/claude-code` version `2.1.88`. Public reporting and downstream analysis indicate that the exposed artifact made large portions of the Claude Code client bundle inspectable. Anthropic replaced that release with `2.1.89` on March 31, 2026.

This document records what appears to have been exposed from public artifacts, what remains unverified, and what clean-room lessons are worth applying to `zcode`.

## Primary Sources Checked

- Axios incident report:
  - https://www.axios.com/2026/03/31/anthropic-leaked-source-code-ai
- npm registry metadata:
  - https://registry.npmjs.org/%40anthropic-ai%2Fclaude-code
- Current fixed tarball checked during investigation:
  - https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-2.1.89.tgz
- Public prompt/tool extraction repo:
  - https://github.com/Piebald-AI/claude-code-system-prompts
- Public Claude Code documentation:
  - https://code.claude.com/docs/en/overview
  - https://code.claude.com/docs/en/sub-agents
  - https://code.claude.com/docs/en/settings
  - https://code.claude.com/docs/en/output-styles
- Public feature/version tracker:
  - https://www.turboai.dev/blog/claude-code-versions

## What Is Confirmed

### 1. Prompt and Tool Orchestration Patterns

Confirmed from public extracted artifacts.

Public analysis repos derived from the leaked package expose:

- large prompt inventories
- builtin tool descriptions
- prompt segments for planning, exploration, verification, compaction, and memory handling
- prompt text that shapes how the agent is expected to use tools and continue work

This means prompt architecture and tool-use guidance were materially exposed.

### 2. Client-Side Agent Loop Behavior

Confirmed at the orchestration level.

Public extracted prompts and official docs together show:

- explicit task tracking behavior
- subagent usage patterns
- compaction behavior
- continuation/verification reminders
- independent subagent contexts and permissions
- background/concurrent work patterns

What is still not independently reconstructed here is the exact full JavaScript control-flow implementation. But the client-side orchestration model itself is clearly exposed well enough to study.

### 3. Feature Flags and Roadmap Hints

Confirmed.

Public reporting and independent package tracking show:

- undocumented feature gates
- experimental/unfinished features
- emerging architecture directions
- product surface hints not yet fully shipped

This is consistent with client bundle leakage and with reporting that unshipped flags were present.

### 4. Subagents, Memory, Hooks, Plugins, and Output Styles

Confirmed.

Official Claude Code docs already document:

- specialized subagents
- separate context windows and permissions per subagent
- plugin packaging that can include skills, agents, hooks, and MCP servers
- output styles that modify the system prompt
- persistent memory behavior

The leaked client artifact appears to have exposed additional implementation detail around these surfaces, but the existence and general structure of these systems is no longer speculative.

## What Is Reported But Not Independently Verified Here

### Internal Performance / Evaluation Metadata

Axios reports that internal model performance data was among the exposed material. I did not independently confirm the actual contents of those metrics from a primary artifact during this investigation, so this item should be treated as media-reported rather than directly verified from the leaked package itself.

## What Does Not Appear To Have Leaked

No public artifact reviewed here indicates leakage of:

- model weights
- training data
- post-training / RL recipes
- server-side routing or ranking systems
- inference infrastructure
- customer prompts, customer repositories, or customer data
- long-lived credentials

This appears to have been a client/package exposure, not a backend compromise.

## Clean-Room Lessons For `zcode`

The highest-value lessons are product patterns, not proprietary text.

### Worth Implementing

- styleable system prompts that remain execution-first
- stronger task tracking for multi-step work
- clearer orchestration rules for when to use subagents
- stronger verification-before-done behavior
- better compaction/task/memory coordination
- richer tool-specific guidance that local models can follow reliably

### Not Worth Copying

- leaked proprietary prompt text
- leaked hidden feature names
- any code or behavior that would require direct derivation from non-public source

## Repository Changes Triggered By This Investigation

This investigation directly motivated:

- release artifact auditing for source maps and source files
- VS Code extension packaging hardening
- prompt-style support in the agent prompt stack
- stronger orchestration guidance around tasks, subagents, and verification

## Notes

- npm registry metadata shows `2.1.88` published on 2026-03-30 UTC and `2.1.89` published on 2026-03-31 UTC.
- The `2.1.89` tarball checked during this investigation no longer included the leaked source map file.
