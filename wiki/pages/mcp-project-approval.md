# MCP per-project approval (mcp-06)

`src/core/mcp_approval.zig` decides whether a project-scope (`.mcp.json`) MCP
server may be connected. Project servers are NOT implicitly trusted.

## Status precedence (getProjectMcpServerStatus)

Evaluated in this exact order; first match wins:

1. name in `disabledMcpjsonServers` -> `rejected`
2. name in `enabledMcpjsonServers` -> `approved`
3. `enableAllProjectMcpServers` set -> `approved`
4. bypass-permissions mode AND project MCP enabled AND bypass came from a
   non-project source -> `approved`
5. non-interactive run AND project MCP enabled -> `approved`
6. otherwise -> `pending` (not connected in headless runs)

## The subtle bug to never reintroduce: bypass self-approval

A project ships its own `.claude/settings.json`. If that project file sets
`bypassPermissions` / `defaultMode: bypassPermissions`, it must NOT be able to
auto-approve its own `.mcp.json` servers. That would let any cloned repo run
arbitrary MCP servers silently.

So the bypass signal is read ONLY from user / local / flag / policy sources,
never from project settings. In the pure decision function this is encoded as
`ProjectApprovalSettings.bypass_from_non_project` (the disk loader
`bypassFromNonProject` excludes `.project`). A test locks this:
"bypass via project settings does NOT approve".

## Toggles (any scope)

`isMcpServerDisabled` / `setMcpServerEnabled` gate ANY server via
`disabledMcpServers` / `enabledMcpServers`. A `default_disabled` builtin is
disabled unless explicitly in `enabledMcpServers` (opt-in). zcode currently has
no builtin default-off MCP servers, so `filterProjectServers` passes
`default_disabled = false`.

## Wiring

`mcp_config.mergeScopes` takes an optional `ApprovalFilter` (project settings +
toggles + run mode). When supplied it runs `filterProjectServers` after the
enterprise policy filter, dropping unapproved project servers and disabled
servers, appending a `warning` ValidationError per drop. As of this task no
loader supplies it yet (the client still uses the legacy flat `{name,
transport}` registry); the hook is in place for when the client is migrated to
the scoped model.

## Name normalization gap

The reference normalizes names (`normalizeNameForMCP`) before comparison. zcode
compares raw, so `My-Server` vs `my_server` will not match. Documented
limitation, not yet fixed.
