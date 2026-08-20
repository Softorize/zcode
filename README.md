# zcode

Enterprise-first coding agent CLI written in Zig.

`zcode` is a terminal-first coding agent for local development, CI, and repository automation. It is built around safe tool execution, strong session management, MCP interoperability, and a product surface that can be scripted as easily as it can be driven interactively.

## Requirements

- **Zig 0.16.0** ("Juicy Main") or newer. zcode uses `std.Io`, the redesigned I/O interface introduced in 0.16.

## Quick start

```bash
zig build -Doptimize=ReleaseSafe --prefix ~/.local
export OPENAI_API_KEY=...
~/.local/bin/zcode run "summarize this repository"
```

For deterministic local verification without API keys:

```bash
zig build run -- --provider mock --model mock-agent exec --json "check repo status"
```

## Current v1 foundation

- Hybrid interactive + CI command modes
- Provider adapters: OpenAI, OpenAI-compatible, DeepSeek, Anthropic, Gemini, Local (Ollama), Mock (for deterministic testing)
- Provider model discovery via provider APIs with fallback defaults
- Native HTTP transport for providers, MCP HTTP invoke, and control-plane audit sync
- Prompt orchestration pipeline with instruction discovery, context gathering, output styles, and task/subagent/verification playbooks
- Recursive instruction imports (`@path`) with cycle protection and depth controls
- Budget-aware context selection with git status + git diff + repo map + session memory
- Provider-aware token estimation for prompt budgeting
- Provider usage token parsing (OpenAI/DeepSeek/Anthropic/Gemini/Ollama payloads)
- Live token counters in fullscreen status line (last prompt/in/out + cumulative)
- Anthropic prompt cache directives (ephemeral cache blocks) when cache hints are present
- Markdown-aware terminal rendering (headings, emphasis, preserved paragraph spacing)
- Risk-tiered tool runtime (shell/file/git/MCP invoke) with approval + sandbox gates
- Session persistence with compaction snapshots
- Session export, checkpoint, checkpoint restore, share, import, undo alias, and fork commands for transcript/snapshot bundles
- Remote share daemon with web handoff URLs and URL-based session import
- MCP server registry commands
- MCP tool, resource, resource-template, prompt, completion, subscription, log-level, and notification flows (`zcode mcp tools|resources|templates|prompts|complete|subscribe|unsubscribe|log-level|notifications`)
- MCP stdio JSON-RPC, streamable HTTP, and custom WebSocket (`ws://` / `wss://`) transport support with persistent bidirectional sessions for long-lived stdio/WebSocket servers and dynamic MCP tool schemas in prompts
- MCP client capabilities for roots, server-initiated sampling, and elicitation, including nested `sampling/createMessage` and `elicitation/create` handling during tool/resource/prompt execution
- MCP auth lifecycle (`zcode mcp auth login|status|logout`) with refreshable auth persistence, HTTP header propagation, stdio env propagation, and automatic OAuth discovery/PKCE login for compatible HTTP-style MCP servers, including `ws://` / `wss://` transport probing via their HTTP equivalent
- Browser-assisted fallback MCP OAuth login via `zcode mcp auth login <server> oauth:<url>`
- Persistent custom agents from user and workspace scopes
- Builtin specialist agents for exploration, planning, verification, and review
- Session output styles from builtins or `~/.zcode` / workspace markdown files
- Session todo checklist tools for explicit multi-step tracking
- First-class review mode and `zcode review`
- Workspace/user hook lifecycle for pre/post tool execution
- Manifest-based plugin system from user/workspace scopes with lifecycle events
- Reusable prompt commands with CLI, REPL, and tool access
- Plugin and command marketplace catalogs with remote sources, SHA-256 verification, and install/update/uninstall flows into user scope
- Trusted-repo UX for gating workspace automation surfaces, plus interactive workspace-hook trust prompts
- JSON-lines stdio API surface for editor and automation integrations
- First-party VS Code extension with session picker, diff apply flow, and VSIX release packaging
- Session fork support for checkpoint-style branch workflows
- Interactive slash commands (`/status`, `/session`, `/session checkpoint`, `/session checkpoints`, `/session restore`, `/session fork`, `/marketplace`, `/agents`, `/agent`, `/hooks`, `/styles`, `/style`, `/plugins`, `/plugins marketplace`, `/plugin`, `/plugin install`, `/plugin uninstall`, `/plugin update`, `/commands`, `/commands marketplace`, `/command`, `/command install`, `/command uninstall`, `/command update`, `/trust`, `/review`, `/compact`, `/models`, `/model`, `/preprocessor`, `/mcp`, `/mcp tools`, `/mcp resources`, `/mcp templates`, `/mcp read`, `/mcp prompts`, `/mcp prompt`, `/mcp complete`, `/mcp subscribe`, `/mcp unsubscribe`, `/mcp log-level`, `/mcp notifications`, `/policy`)
- Official GitHub Action wrapper plus PR review, issue triage, scheduled review, and `@zcode` mention workflow examples
- GitHub App onboarding/rendering helpers plus app-authenticated branch/PR automation scripts
- Policy and audit logging baseline
- Structured model output protocol (`assistant` + `tool_calls` + `control`)
- Runtime enforcement for verification-before-done and background-task polling
- Strict CI gate support (`--strict` returns non-zero on denied/blocked tool actions)
- Benchmark command (`zcode benchmark run`)
- Provider fallback routing (`default_provider` -> `fallback_provider`)
- Optional control-plane audit sync hooks
- Optional control-plane policy bundle sync with SHA-256 verification
- Configurable runtime + UI behavior (fullscreen, prompt label, spinner, transcript limits, streaming, retries/timeouts)
- Persistent fullscreen status line with agent state hints (running vs waiting for input), runtime profile, and build version

## Build

```bash
zig build
zig build test
```

## Install

Install a release-safe build into your user-local bin directory:

```bash
zig build -Doptimize=ReleaseSafe --prefix ~/.local
~/.local/bin/zcode version
```

If `~/.local/bin` is already on your `PATH`, the installed command is simply:

```bash
zcode version
```

## Platform support

- Tested in CI on macOS and Linux
- Release binaries currently ship for macOS (`x86_64`, `aarch64`) and Linux (`x86_64`, `aarch64`)
- macOS release workflow supports Developer ID signing and notarization when Apple credentials are configured

## Community

- Contribution guide: [CONTRIBUTING.md](CONTRIBUTING.md)
- Governance: [GOVERNANCE.md](GOVERNANCE.md)
- Community support: [SUPPORT.md](SUPPORT.md)
- Security reporting: [SECURITY.md](SECURITY.md)
- Enterprise readiness: [docs/enterprise/READINESS.md](docs/enterprise/READINESS.md)
- Project conduct expectations: [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)
- Release history: [CHANGELOG.md](CHANGELOG.md)
- Product quality roadmap: [docs/PARITY_ROADMAP_V2.md](docs/PARITY_ROADMAP_V2.md)
- License: [Apache-2.0](LICENSE)

`zcode` is now licensed under Apache-2.0.

> **Open-source release status:** publication remains gated on the source
> provenance review documented in [PROVENANCE.md](PROVENANCE.md). The presence
> of an Apache-2.0 license is not a substitute for clearing third-party source
> provenance.

## Run

```bash
zig build run
zig build run -- run "fix failing tests in src/core/context.zig"
zig build run -- exec --json "summarize repository"
zig build run -- --provider mock --model mock-agent --output-style investigative exec --json "implement the fix, keep a todo checklist, and verify before finishing"
zig build run -- version
zig build run -- --strict exec --json "apply fix with hard policy gates"
zig build run -- benchmark run
zig build run -- agents list
zig build run -- hooks list
zig build run -- plugins list
zig build run -- plugins marketplace
zig build run -- marketplace sources
zig build run -- marketplace add official https://example.com/catalog.json <sha256>
zig build run -- plugins install review-plus
zig build run -- plugins update review-plus
zig build run -- plugins uninstall review-plus
zig build run -- commands list
zig build run -- commands marketplace
zig build run -- commands install triage
zig build run -- commands update triage
zig build run -- commands uninstall triage
zig build run -- commands run review src/main.zig fast
zig build run -- trust status
zig build run -- trust allow
zig build run -- api schema
zig build run -- review working
zig build run -- session export <session_id>
zig build run -- session checkpoint <session_id> "pre-release"
zig build run -- session restore <session_id> pre-release
zig build run -- session share <session_id> handoff
zig build run -- session undo <session_id>
zig build run -- session fork <session_id> release-candidate
zig build run -- session import http://127.0.0.1:8766/share/<bundle>.json?token=...
zig build run -- daemon start
zig build run -- daemon handoff <session_id> editor-handoff
zig build run -- mcp tools <server>
zig build run -- mcp resources <server>
zig build run -- mcp templates <server>
zig build run -- mcp read <server> <uri>
zig build run -- mcp prompts <server>
zig build run -- mcp prompt <server> <name> '{"nodeId":"123"}'
zig build run -- mcp complete <server> '{"type":"ref/prompt","name":"code_review"}' language py
zig build run -- mcp subscribe <server> <uri>
zig build run -- mcp notifications <server>
zig build run -- mcp unsubscribe <server> <uri>
zig build run -- mcp log-level <server> info
zig build run -- mcp auth status
zig build run -- mcp auth login <server>
zig build run -- mcp auth login <server> oauth:https://example.com/auth?redirect_uri={{callback_url}}
zig build run -- mcp add figma ws://127.0.0.1:8765/mcp
zig build run -- mcp add figma https://mcp.figma.com/mcp
zig build run -- --preprocessor --preprocessor-model gemini/gemini-2.5-flash run "audit the repo"
zig build run -- --preprocessor-provider openrouter --preprocessor-model anthropic/claude-sonnet-4 run "summarize context"
zig build run -- --output-style investigative run "audit the repo and distinguish evidence from inference"
zig build run -- --agent reviewer run "analyze the latest changes"
zig build run -- --no-fullscreen --no-spinner run "quick one-shot without TUI"
zig build run -- --prompt-label "zc>" --transcript-max-lines 1500
```

## Provider keys

```bash
export OPENAI_API_KEY=...
export OPENAI_COMPAT_API_KEY=...
export DEEPSEEK_API_KEY=...
export ANTHROPIC_API_KEY=...
export GEMINI_API_KEY=...
```

Optional custom endpoints:

```bash
export OPENAI_BASE_URL=https://api.openai.com
export OPENAI_COMPAT_BASE_URL=https://your-gateway.example.com
export DEEPSEEK_BASE_URL=https://api.deepseek.com
export ANTHROPIC_BASE_URL=https://api.anthropic.com
export GEMINI_BASE_URL=https://generativelanguage.googleapis.com/v1beta
export OLLAMA_BASE_URL=http://127.0.0.1:11434
```

For deterministic local testing without API keys:

```bash
zig build run -- --provider mock --model mock-agent exec --json "check repo status"
```

## Versioning

- The base semantic version lives in `build.zig.zon`.
- `zcode version` prints the exact build version.
- Source builds format the version as `base+<git_short_hash>` and add `.dirty` when the workspace has uncommitted changes at build time.
- GitHub release binaries can report the plain base version without a git suffix when built outside a git checkout.
- The fullscreen REPL status line always shows this version so you can verify you are on the latest binary.

## Config files

- User config: `~/.zcode/config.toml`
- Workspace config: `.zcode/config.toml`
- Workspace agents: `.zcode/agents/*.json`
- Workspace hooks: `.zcode/hooks/*.sh`
- Workspace plugins: `.zcode/plugins/*/plugin.json`
- Workspace commands: `.zcode/commands/*.md`
- User output styles: `~/.zcode/output-styles/*.md`
- Workspace output styles: `.zcode/output-styles/*.md`
- Marketplace catalogs: `~/.zcode/marketplace.json`, `.zcode/marketplace.json`
- Marketplace source registry: `~/.zcode/marketplace/sources.json`
- Marketplace source cache: `~/.zcode/marketplace/cache/*.json`
- Policy: `~/.zcode/policy/policy.toml`
- Sessions: `~/.zcode/sessions/*.jsonl`
- Checkpoints: `~/.zcode/checkpoints/<session_id>/*.json`
- Share bundles: `~/.zcode/shares/*.json`
- Remote daemon state: `~/.zcode/daemon/state.json`
- MCP auth store: `~/.zcode/mcp/auth.json`
- Trust store: `~/.zcode/trust/repos.json`
- Logs: `~/.zcode/logs/audit-*.jsonl`

Instruction discovery follows a layered stack:
- Search `ZCODE.md`, `AGENTS.md`, `CLAUDE.md`, `GEMINI.md` from current directory up to repo root
- Optionally include home-level files for user-global defaults
- Resolve `@relative/or/absolute/path.md` imports recursively (configurable, depth-limited, cycle-safe)

## Examples

Workspace config (`.zcode/config.toml`):

```toml
default_provider = "openai"
default_model = "gpt-4.1"
available_models = "openai/gpt-4.1,openai/gpt-4.1-mini,deepseek/deepseek-chat,local/qwen2.5-coder:32768"
fallback_provider = "local"
fallback_model = "qwen2.5-coder"
provider_api_key = ""
provider_base_url = ""
local_base_url = "http://127.0.0.1:11434"
fallback_provider_api_key = ""
fallback_provider_base_url = ""
provider_timeout_ms = 60000
provider_retry_count = 2
profile = "default"
approval_mode = "tiered-auto"
sandbox = "workspace-write"
interactive_streaming = true
intent_reprompt_enabled = true
ui_fullscreen = true
ui_alt_screen = true
ui_spinner = true
ui_thinking_summary = true
ui_prompt_label = ">"
ui_transcript_max_lines = 20000
ui_show_scroll_hint = true
ui_bottom_margin_rows = 2
ui_line_spacing = 1
ui_color_enabled = true
ui_highlight_links = true
ui_highlight_paths = true
ui_color_lists = true
ui_highlight_code_blocks = true
ui_status_show_workspace = true
ui_status_show_model = true
ui_status_show_safety = true
ui_status_show_tokens = true
ui_status_show_hint = true
session_encryption_enabled = true
model_context_window = 128000
reserved_output_tokens = 16384
reserved_reasoning_tokens = 2048
instruction_file_cap_bytes = 65536
instruction_total_cap_bytes = 262144
instruction_imports_enabled = true
instruction_import_max_depth = 6
prompt_cache_hints_enabled = true
feature_kill_switches = ""
append_system_prompt = ""
max_history_turns = 24
max_tool_rounds = 12
tool_output_artifact_threshold_bytes = 65536
mcp_tool_bridge_enabled = true
browser_bridge_enabled = false
browser_bridge_port = 9333
control_plane_url = ""
control_plane_token = ""
control_plane_policy_sync = false
control_plane_policy_verify_hash = true
control_plane_managed_settings_sync = false
control_plane_managed_settings_verify_hash = true
cloud_telemetry_opt_in = false
egress_allowlist = ""
egress_allow_private_network_plaintext = false
api_oidc_issuer = ""
api_oidc_audience = ""
api_oidc_hs256_secret = ""
api_oidc_jwks_json = ""
api_oidc_jwks_file = ""
api_oidc_jwks_url = ""
api_oidc_jwks_cache_ttl_seconds = 3600
audit_retention_days = 90
preprocessor_enabled = false
preprocessor_provider = ""
preprocessor_model = ""
preprocessor_base_url = ""
preprocessor_max_output_tokens = 300
preprocessor_api_key = ""
```

### Session preprocessor selection

- Use `--preprocessor` to enable the preprocessor for a run when provider/model are already configured.
- Use `--preprocessor-model <provider/id>` to choose a preprocessor model directly for a one-shot or REPL startup.
- Use `--preprocessor-provider <name>` plus `--preprocessor-model <id>` for providers like `openrouter` where model IDs often contain `/`.
- In the REPL, use `/preprocessor`, `/preprocessor list [provider]`, `/preprocessor on`, `/preprocessor off`, or `/preprocessor <id|provider/id>`.

### Session encryption

- Set `session_encryption_enabled = true` in config to encrypt session records at rest.
- Provide a 32-byte key via `ZCODE_SESSION_KEY`.
- Supported key formats:
  - raw hex (64 hex chars)
  - `hex:<64-hex-chars>`
  - base64 (44 chars for 32 bytes)
  - `base64:<value>`

If encryption is enabled and no valid key is provided, zcode fails fast instead of writing plaintext session data.

### Update integrity checks

- `zcode update` now verifies downloaded release binaries against release checksum manifests when available.
- If checksum verification cannot be completed, update is blocked by default.
- Override only for emergency/manual testing with `ZCODE_ALLOW_UNSIGNED_UPDATE=1`.
- Release automation can sign and notarize macOS assets when `APPLE_*` signing and notary secrets are configured.

### Shell isolation

- Sandbox profiles now require a real shell isolation backend for shell tool execution: `sandbox-exec` on macOS or `bwrap` on Linux.
- When no supported backend is available, shell execution in `read-only`, `workspace-write`, and `no-network` fails closed by default.
- `ZCODE_ALLOW_UNISOLATED_SHELL=1` enables the legacy unsafe fallback only for manual compatibility testing.

### Trusted repos, plugins, and reusable commands

- Mark the current repo trusted with `zcode trust allow`.
- Inspect trust state with `zcode trust status`.
- Inspect workspace hook trust with `zcode trust hooks`.
- Trust or revoke a workspace hook fingerprint with `zcode trust hook-allow <path>` and `zcode trust hook-revoke <path>`.
- Inspect or modify marketplace source policy with `zcode trust marketplace`, `zcode trust marketplace-allow <prefix>`, `zcode trust marketplace-block <prefix>`, and `zcode trust marketplace-unblock <prefix>`.
- Workspace plugins are loaded from `.zcode/plugins/*/plugin.json`.
- Workspace reusable commands are loaded from `.zcode/commands/*.md`.
- See plugin manifest and event details in `docs/PLUGIN_API.md`.
- See the JSON-lines machine API in `docs/IDE_PROTOCOL.md`.
- See the VS Code extension in `extensions/vscode/README.md`.

Example plugin manifest:

```json
{
  "name": "review-plus",
  "version": "0.1.0",
  "description": "Extra review heuristics",
  "entrypoint": "plugin.sh",
  "compatibility": "zcode-plugin-api/v1",
  "isolation": "subprocess",
  "permissions": ["git", "read"],
  "events": ["pre-tool-use", "post-tool-use", "review-start"],
  "commands": [
    { "name": "review-plus.quick", "description": "Fast review template" }
  ]
}
```

Example reusable command:

```md
# Review Focus

Review these files with extra attention on `{{arg1}}`.

Context:
{{args}}
```

Run it with `zcode commands run review-focus src/main.zig regression-risk`.

### GitHub automation

- Composite action: `.github/actions/zcode/action.yml`
- PR review example: `.github/workflows/zcode-pr-review.yml`
- Issue triage example: `.github/workflows/zcode-issue-triage.yml`
- Scheduled review example: `.github/workflows/zcode-scheduled-review.yml`
- GitHub App bootstrap docs: `docs/GITHUB_APP.md`
- Release packaging docs: `docs/RELEASES.md`

These workflows expect the provider API key in repository secrets, for example `OPENAI_API_KEY`.

Policy (`~/.zcode/policy/policy.toml`):

```toml
default_approval_mode = "tiered-auto"
allow_network = true
block_destructive_shell = true
blocked_tool = "network"
blocked_shell_pattern = "curl | sh"
```

Policy parsing is strict: unknown keys, invalid booleans, empty blocks, and
control bytes fail closed with a targeted startup error.

### Structured tool-call protocol

By default zcode asks models to return strict JSON with this shape:

```json
{
  "assistant": "Short status message",
  "tool_calls": [
    { "name": "git_status", "args": {} },
    { "name": "shell", "args": { "command": "rg TODO src" } }
  ],
  "control": {
    "compact": false,
    "resume": false,
    "escalate": false
  }
}
```

Non-JSON model text is still supported and treated as plain assistant output.
