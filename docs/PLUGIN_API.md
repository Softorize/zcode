# zcode Plugin API v1

`zcode` loads plugins from two scopes:

- User: `~/.zcode/plugins/<plugin-name>/plugin.json`
- Workspace: `.zcode/plugins/<plugin-name>/plugin.json`

Workspace plugins are intended for trusted repos. Use `zcode trust allow` before enabling repo-local automation.

## Manifest

Each plugin directory must contain a `plugin.json` manifest.

```json
{
  "name": "review-plus",
  "version": "0.1.0",
  "description": "Extra review heuristics",
  "entrypoint": "plugin.sh",
  "compatibility": "zcode-plugin-api/v1",
  "isolation": "subprocess",
  "permissions": ["git", "read"],
  "events": ["pre-tool-use", "post-tool-use", "session-start", "session-end", "review-start"],
  "commands": [
    { "name": "review-plus.quick", "description": "Fast review template" }
  ]
}
```

## Supported fields

- `name`: stable plugin id.
- `version`: plugin version string.
- `description`: short user-facing summary.
- `entrypoint`: relative or absolute executable path.
- `compatibility`: currently `zcode-plugin-api/v1`.
- `isolation`: metadata field. Current runtime model is `subprocess`.
- `permissions`: declared capabilities. Current runtime exposes these for review and policy, not hard enforcement.
- `events`: lifecycle events the plugin wants to receive.
- `commands`: optional user-facing command metadata exposed by the manifest.
- `lspServers`: optional array of language-server configs (see below).

## LSP servers (`lspServers`)

A plugin may declare one or more language servers in an optional `lspServers`
array. This is an OVERRIDE layer, not the only source: `zcode` ships a built-in
default table (zls for `.zig`, pyright for `.py`, gopls for `.go`, etc.) that
works with zero configuration. A plugin entry is merged over those defaults and
WINS on an extension collision, so a plugin can either add a server for a new
extension or fully replace a built-in for an extension it cares about. (This is
a deliberate divergence from Claude Code, which sources LSP servers only from
plugins; the built-in defaults preserve zcode's zero-config UX.)

```json
{
  "lspServers": [
    {
      "name": "vue-language-server",
      "command": "vue-language-server",
      "args": ["--stdio"],
      "env": { "NODE_ENV": "production" },
      "workspaceFolder": "/abs/project",
      "extensionToLanguage": { ".vue": "vue" },
      "initializationOptions": { "typescript": { "tsdk": "/usr/lib/tsdk" } },
      "startupTimeout": 45000,
      "maxRestarts": 5
    }
  ]
}
```

- `name` (required): server identity; an entry with no `name` is skipped.
- `command`: binary to spawn (defaults to `name`).
- `args`: argv after the command (defaults to `["--stdio"]`).
- `env`: extra `KEY: value` environment overrides.
- `workspaceFolder`: explicit workspace root; absent uses the session cwd.
- `extensionToLanguage`: ext -> languageId map; drives routing + `didOpen`.
- `initializationOptions`: opaque JSON spliced into the `initialize` params
  (required by some servers such as vue-language-server).
- `startupTimeout`: handshake timeout in ms (default 30000).
- `maxRestarts`: crash-recovery cap (default 3).

A malformed or absent `lspServers` is ignored (backward compatible).

## Lifecycle events

- `pre-tool-use`
- `post-tool-use`
- `session-start`
- `session-end`
- `review-start`

Current runtime execution:

- `pre-tool-use`: fired before tool execution and may block by exiting non-zero.
- `post-tool-use`: fired after tool execution.
- `session-start`: fired when interactive or one-shot sessions start.
- `review-start`: fired before `zcode review` and `/review`.
- `session-end`: reserved in the manifest/event vocabulary for compatibility and future expansion.

## Runtime model

- Plugins are executed as subprocesses.
- `entrypoint` should be an executable file.
- Non-zero exit status blocks `pre-tool-use` and may annotate later lifecycle calls.
- Plugin stdout is treated as the primary status/output channel.

## Environment

`zcode` exposes these variables to plugin subprocesses:

- `ZCODE_PLUGIN_NAME`
- `ZCODE_PLUGIN_VERSION`
- `ZCODE_PLUGIN_SCOPE`
- `ZCODE_PLUGIN_EVENT`
- `ZCODE_PLUGIN_PERMISSIONS`
- `ZCODE_CWD`
- `ZCODE_TOOL_NAME`
- `ZCODE_TOOL_ARGS`
- `ZCODE_TOOL_OUTPUT`
- `ZCODE_TOOL_SUCCESS`

## Compatibility goals

- Keep manifest parsing backward compatible inside `zcode-plugin-api/v1`.
- Allow simple shell-script plugins first, without requiring a separate SDK.
- Preserve user-scope plugins across workspaces.
- Keep workspace plugins visible but tied to trusted repos.
- Expand from lifecycle hooks to richer command/marketplace surfaces without breaking existing manifests.
