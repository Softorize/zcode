# zcode Remaining Gap Matrix

This file tracks the next product gaps after the first platform tranche.

Status:
- `done`: shipped in `zcode`
- `in_progress`: partially shipped or active implementation
- `todo`: not started yet

## Matrix

| Capability | Status | Notes |
|---|---|---|
| Full checkpoint restore | `done` | Git-backed and non-git workspace restore now ship, including backup checkpoints and runtime session switching |
| Hosted marketplace / distribution | `done` | Local catalogs, remote source registries, cache refresh, install/update/uninstall flows, and SHA-256 integrity enforcement are in-repo |
| Editor-native bundles | `done` | First-party VS Code extension ships with structured session picking, diff apply support, CI validation, and VSIX release packaging |
| GitHub App path | `done` | Renderable App manifest, onboarding helper, auth/token scripts, and safe branch/PR automation helpers now ship in-repo |
| Remote daemon / web session surface | `done` | Daemon lifecycle, handoff URLs, URL-based session import, and a browser handoff page now ship |
| MCP OAuth browser completion | `done` | Browser launch/callback flow, refreshable auth persistence, and debug/status UX now ship in the auth store and CLI |
| Trust / safety hardening | `done` | Hook fingerprint storage plus interactive trust prompts, marketplace allow/block policy, and secret scanning on write/edit/commit are live |
| Release packaging / distribution | `done` | Release workflow, checksums, manifest-driven updater, curl installer, and Homebrew formula/tap sync automation are now in-repo |

## Checklists

### 1. Full Checkpoint Restore
- [x] Store repo root and `HEAD` metadata in checkpoint bundles
- [x] Capture staged tracked changes separately from unstaged tracked changes
- [x] Capture untracked workspace files in checkpoint bundles
- [x] Add `zcode session restore <session_id> [checkpoint]`
- [x] Add `/session restore [checkpoint]` to the REPL
- [x] Verify repo root and `HEAD` before mutating the workspace
- [x] Auto-save a backup checkpoint before restore
- [x] Restore tracked staged state, tracked unstaged state, and untracked files
- [x] Add regression tests for successful restore and `HEAD` mismatch
- [x] Extend restore beyond git-backed workspaces

### 2. Hosted Marketplace / Distribution
- [x] Add remote registry sources for plugins and commands
- [x] Add `add/remove/update` flows for marketplace sources
- [x] Add uninstall and upgrade flows for installed entries
- [x] Add trust/signature policy for downloaded marketplace content

### 3. Editor-Native Bundles
- [x] Ship a first-party VS Code extension on top of the JSON-lines API
- [x] Add inline diff/apply UX inside the editor surface
- [x] Add editor auth/session handoff wiring
- [x] Add smoke coverage for editor <-> CLI protocol compatibility
- [x] Add release packaging for the VS Code extension bundle

### 4. GitHub App Path
- [x] Add GitHub App manifest/config scaffolding
- [x] Add App auth/token exchange helpers
- [x] Add branch write / PR creation flows under App auth
- [x] Add docs for App install and repo onboarding
- [x] Add manifest rendering/onboarding helpers for self-hosted App setup

### 5. Remote / Web Sessions
- [x] Define remote daemon protocol and auth model
- [x] Add daemon start/stop/status commands
- [x] Add browser/web handoff flow for active sessions
- [x] Add cross-device resume semantics

### 6. MCP OAuth Browser Completion
- [x] Add browser launch / callback handling for MCP auth flows
- [x] Persist refreshable auth state
- [x] Add auth debug UX for callback failures

### 7. Trust / Safety Hardening
- [x] Add hook fingerprint trust prompts/storage
- [x] Add marketplace allowlist/blocklist policy
- [x] Add secret scanning before writing/committing generated changes
- [x] Add clearer trust state surfacing in UI and CLI

### 8. Release Packaging / Distribution
- [x] Add release workflow that builds release binaries
- [x] Publish checksums and update manifests from CI
- [x] Add Homebrew distribution
- [x] Add curl/install script path

### 9. Command-surface parity with leaked Claude Code (2026-03-31 dump)
- [x] `/add-dir` -- register additional workspace roots (surfaced to the model as a context block)
- [x] `/stats` -- aggregate cross-session activity (distinct from per-session `/cost`)
- [x] `/insights` -- 14-day activity chart and tag frequency
- [x] `/tag add|remove|list` -- per-session tag sidecar
- [x] `/summary` -- condensed session summary without rewriting history
- [x] `/break-cache` -- one-shot prompt-cache bypass for the next model call
- [x] `/login`, `/logout` -- REPL-facing wrappers over `zcode provider`
- [x] `/ide` -- parent IDE / terminal detection
- [x] `/terminal-setup` -- capability probe (truecolor / UTF-8 / OSC-8 / 256-color)
- [x] `/heapdump` -- pid, cwd, RSS, token totals, session id snapshot
- [x] `/ctx-viz` -- context-window bar chart (prompt / reserved / free)
- [x] `/advisor` -- session-scoped read-only advisory mode (re-uses review gating)
- [x] `/chrome` -- chrome browser-bridge status and tool listing
- [x] `/autofix-pr` -- review-flow prompt that applies fixes and reports test status
