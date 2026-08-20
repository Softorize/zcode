# zcode Gap Matrix

This file tracks the capability gaps identified against Claude Code, Google Gemini CLI, Factory Droid, and OpenCode.

Status:
- `done`: shipped in `zcode`
- `in_progress`: foundation exists or active implementation
- `todo`: not implemented yet

## Matrix

| Capability | Claude Code | Gemini CLI | Factory Droid | OpenCode | zcode | Status | Notes |
|---|---|---|---|---|---|---|---|
| Multi-provider terminal agent | Yes | Gemini-native | Mixed models | Multi-model | Yes | `done` | Core engine is already competitive |
| MCP integration | Yes | Yes | Yes | Yes | Yes | `done` | `mcp list/tools/invoke` shipped |
| Session persistence/resume | Yes | Yes | Yes | Yes | Yes | `done` | Resume/export/compact shipped |
| Custom agents/subagents | Yes | Partial/extensible | Yes | Yes | Yes | `done` | Persistent agent definitions, activation, overrides, and isolated sub-agent execution ship |
| Per-agent tool restrictions | Yes | Partial | Yes | Yes | Yes | `done` | Agent-level tool allowlists are enforced at schema and execution layers |
| First-class code review workflow | Yes | Via prompt/action | Yes | Yes | Yes | `done` | Dedicated review mode and CLI/REPL review flows ship |
| Hook lifecycle | Yes | Extensions/custom commands | Yes | Yes | Yes | `done` | Pre/post tool hooks, hook trust, and block paths ship |
| Plugin/extension ecosystem | Yes | Yes | Yes | Yes | Yes | `done` | Manifest/event plugins, marketplace sources, install/update/uninstall, and policy controls ship |
| GitHub automation surface | Yes | Yes | Yes | Yes | Yes | `done` | Official Action wrapper, mention flows, App onboarding, and app-auth helper scripts ship |
| IDE integration | Yes | Yes | Yes | Yes | Yes | `done` | JSON-lines API plus packaged first-party VS Code extension ship |
| Desktop/web/remote sessions | Yes | Partial | Partial | Yes | Yes | `done` | Remote daemon, handoff URLs, browser page, share/import, and cross-device resume ship |
| MCP OAuth/auth UX | Yes | Partial | Partial | Yes | Yes | `done` | Browser callback, refreshable auth persistence, and debug/status UX ship |
| Trusted folders / repo trust UX | Yes | Yes | Partial | Partial | Yes | `done` | Repo trust, hook fingerprint trust, marketplace policy, and secret scanning ship |
| Undo/checkpoint/fork/share | Yes | Yes | Partial | Yes | Yes | `done` | Checkpoint/share/import/undo/fork shipped across CLI and REPL |
| Skills/custom reusable commands | Yes | Yes | Yes | Yes | Yes | `done` | Reusable commands plus remote marketplace distribution and install flows ship |

## Checklists

### 1. Custom Agents
- [x] Add in-repo gap tracking
- [x] Support persistent user and workspace agent definitions
- [x] Add CLI commands to list and inspect agents
- [x] Add REPL commands to list, activate, inspect, and clear agents
- [x] Inject active agent system prompt into model requests
- [x] Enforce per-agent tool restrictions at schema and execution layers
- [x] Support agent model override behavior
- [x] Add tests for parsing, precedence, activation, and restrictions

### 2. Review Workflow
- [x] Add dedicated review mode with read-only enforcement
- [x] Add `/review` REPL command
- [x] Add `zcode review ...` CLI entrypoint
- [x] Support at least: uncommitted changes, commit review, base-branch review
- [x] Add review-specific prompting and findings-first output contract
- [x] Add tests for parsing and prompt generation

### 3. Hooks Foundation
- [x] Define hook discovery locations for workspace and user scope
- [x] Add pre-tool-use hook execution
- [x] Add post-tool-use hook execution
- [x] Add hook inspection command(s)
- [x] Pass structured context through environment variables
- [x] Allow pre-tool hooks to block execution
- [x] Add tests for discovery/listing

### 4. Plugin System
- [x] Define plugin manifest format
- [x] Define lifecycle/event API
- [x] Define plugin isolation/security model
- [x] Load plugins from workspace and user scopes
- [x] Document plugin compatibility goals
- [x] Add local marketplace catalog format for plugins and commands
- [x] Add CLI install flows for marketplace entries
- [x] Add REPL discovery/install flows for marketplace entries
- [x] Add tests and smoke coverage for install behavior

### 5. GitHub Automation
- [x] Add official GitHub Action wrapper
- [x] Add review workflow examples
- [x] Add issue/PR comment automation entrypoints
- [x] Add scheduled workflow examples
- [x] Add `@zcode` or `/zcode` mention responder workflow

### 6. IDE / Desktop / Remote
- [x] Add IDE protocol/API surface
- [x] Add inline diff review integration targets
- [x] Add remote/session handoff concept

### 7. Trust / Auth / Checkpoints
- [x] Add trusted-folder or trusted-repo UX
- [x] Add MCP auth lifecycle (`login/status/logout`)
- [x] Add checkpoint/savepoint support
- [x] Add undo/revert helper flow
- [x] Add share/export links or richer session bundles
- [x] Add session fork flow in CLI and REPL

### 8. Remaining Gaps
- [x] Add a hosted marketplace/distribution story for plugins and commands
- [x] Add a GitHub App or installation flow beyond Actions-based mention handling
- [x] Ship editor-native bundles on top of the JSON-lines API
- [x] Add remote daemon/web session surface for cross-device continuation
- [x] Complete MCP OAuth/browser-auth finish flows
