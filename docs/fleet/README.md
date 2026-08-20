# Fleet deployment

zcode supports fleet-wide configuration via a read-only managed config
file that an MDM, configuration-management tool, or group-policy
equivalent pushes to each macOS/Linux machine.

## Managed config files

Default path:

| OS | Path |
|---|---|
| Linux | `/etc/zcode/managed.toml` |
| macOS | `/Library/Application Support/zcode/managed.toml` |

Override for testing with `ZCODE_MANAGED_CONFIG=/path/to/managed.toml`.

The base file is TOML and uses the same key names as `~/.zcode/config.toml`.
Drop-ins can be added beside it under `managed.d/*.toml`:

| OS | Drop-in directory |
|---|---|
| Linux | `/etc/zcode/managed.d/` |
| macOS | `/Library/Application Support/zcode/managed.d/` |

Drop-ins are loaded in sorted filename order after the base file; later files
win. Values apply **after** user config, workspace config, local settings, env,
and CLI flags, so fleet policy gets final precedence.

Managed files are strict: an unknown key, control byte, unreadable file, or
bad `.sha256` sidecar fails closed instead of falling back to user config.
Each managed file may be accompanied by `<file>.sha256`.

## Common fleet overrides

```toml
# Require explicit approval for high-risk actions.
approval_mode = "strict"

# Keep tool execution inside the workspace by default. Use
# "no-network" for higher-security teams that do not need networked tools.
sandbox = "workspace-write"

# Force prompt-body redaction in the audit log.
privacy_redact_prompt_bodies = true

# Mandatory at-rest session encryption.
session_encryption_enabled = true

# Emergency kill switches for self-hosted feature control.
feature_kill_switches = "browser_bridge,preprocessor"

# 180-day session retention for compliance.
session_retention_days = 180

# 180-day tamper-evident audit-log retention.
audit_retention_days = 180

# Disable telemetry uploads to the control plane unless remote audit
# shipping is explicitly deployed.
cloud_telemetry_opt_in = false

# Restrict all zcode-managed outbound HTTP(S)/WS(S) calls to approved hosts.
# Supports exact hosts and wildcard suffixes.
egress_allowlist = "api.openai.com,api.anthropic.com,*.company.internal"

# Keep false unless local providers run on private LAN hosts. Loopback
# HTTP remains allowed for local dev without this opt-in.
egress_allow_private_network_plaintext = false

# Pin the control plane a fleet uses for policy + audit shipping.
control_plane_url = "https://zcode.internal.example.com"
control_plane_managed_settings_sync = true
control_plane_managed_settings_verify_hash = true
control_plane_policy_sync = true
control_plane_policy_verify_hash = true

# Hold a staged rollout until the deployment ring advances.
update_require_signature = true
update_pinned_version = "0.10.337"

# Block destructive shell operations fleet-wide (via policy).
# Policy itself lives in /etc/zcode/policy.toml and is synced
# separately via the control plane when control_plane_policy_sync
# is true.
```

Authentication is not required for the default local CLI deployment.
zcode relies on the OS user/session boundary for local use and records
evidence through local audit logs. Configure application-level auth only
when exposing the JSON-lines API, IDE bridge, or daemon-like surfaces beyond
the local user boundary:

```toml
api_auth_required = true
api_oidc_issuer = "https://idp.company.example"
api_oidc_audience = "zcode"
api_oidc_jwks_file = "/etc/zcode/oidc-jwks.json"
```

For public IdPs, prefer RS256 with a pinned JWKS distributed by MDM.

Inspect the effective gate state locally with `/features`.
Inspect fleet posture with `zcode doctor enterprise --json`.

The enterprise doctor expects managed deployments to lock the critical
fleet controls in managed config: `approval_mode`, `sandbox`,
`egress_allowlist`, `egress_allow_private_network_plaintext`,
`privacy_redact_prompt_bodies`, `session_encryption_enabled`,
`session_retention_days`, `audit_retention_days`,
`update_require_signature`, `update_pinned_version`, and
`cloud_telemetry_opt_in`.

## Remote managed settings

When `control_plane_managed_settings_sync = true`, startup fetches
`GET /v1/settings/managed` from `control_plane_url`, verifies the returned
SHA-256 when `control_plane_managed_settings_verify_hash = true`, writes the
managed TOML atomically to the platform managed config path, then merges it as
the highest-precedence config layer for the current run.

Expected JSON response:

```json
{
  "managed_toml": "privacy_redact_prompt_bodies = true\n",
  "sha256": "<sha256 of managed_toml>"
}
```

Sync failure is fail-open: zcode warns and continues with the cached/local
managed config if present, so an outage does not brick developer machines.

## Enforcement caveats

- Managed config is read-only by file permission, not by the binary.
  Operators should own files root/admin-only and avoid group/world write.
  Use `0644` only when the file has no secrets; use `0640`/`0600` when it
  contains bearer tokens, shared secrets, or control-plane tokens.
- `ZCODE_UPDATE_PINNED_VERSION`, `ZCODE_UPDATE_REQUIRE_SIGNATURE`, and
  other env-driven policies should be set in the user's environment
  by the MDM profile (launchd plist on macOS, systemd drop-in on Linux).
- Air-gapped environments should use the bundles produced by
  `scripts/release/airgap_bundle.sh`. The bundled installer now fails
  closed unless checksum, cosign, and SLSA verification succeed; use
  `ZCODE_AIRGAP_ALLOW_UNVERIFIED=1` only as an emergency break-glass
  override.

## Rollout playbooks

- [JAMF.md](JAMF.md) -- Jamf Pro configuration profile + policy
- [ANSIBLE.md](ANSIBLE.md) -- Linux via Ansible role
