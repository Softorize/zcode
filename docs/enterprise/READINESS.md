# Enterprise readiness

This checklist describes the default enterprise posture for zcode as a
local, single-user CLI. Authentication is not required for that posture;
local access is governed by the operating system user/session boundary.
Bearer or OIDC authentication is only needed when exposing API, IDE bridge,
or daemon-like surfaces beyond the local user boundary.

## Required baseline

- Ship a managed config through MDM or configuration management.
- Lock `approval_mode = "strict"` for high-risk fleets.
- Use `sandbox = "workspace-write"` by default, or `sandbox = "no-network"`
  for teams that do not need networked tools.
- Set `privacy_redact_prompt_bodies = true`.
- Set `session_encryption_enabled = true`.
- Set `audit_retention_days` and `session_retention_days` to the fleet's
  evidence-retention period.
- Set `update_require_signature = true` and use `update_pinned_version`
  during staged rollouts.
- Set `egress_allowlist` to approved provider, update, marketplace, MCP,
  and control-plane hosts.
- Keep `cloud_telemetry_opt_in = false` unless remote audit shipping is
  explicitly deployed. If enabled, use an HTTPS `control_plane_url` or a
  loopback HTTP collector only.
- Ship SHA-256 sidecars for managed config and policy files.
- Managed-lock the critical fleet controls: `approval_mode`, `sandbox`,
  `egress_allowlist`, `egress_allow_private_network_plaintext`,
  `privacy_redact_prompt_bodies`, `session_encryption_enabled`,
  `session_retention_days`, `audit_retention_days`,
  `update_require_signature`, `update_pinned_version`, and
  `cloud_telemetry_opt_in`.

## Evidence and verification

- Run `zcode doctor enterprise --json` on managed machines and treat
  failures as deployment blockers.
- Run `zcode audit verify` during endpoint health checks or forensic
  collection.
- Archive release assets with checksums, cosign signatures, SLSA
  provenance, and SBOMs.
- Keep CI gates enabled for formatting, tests, integration tests, gitleaks,
  Zig SAST, dependency pin checks, workflow pin checks, reproducible builds,
  CodeQL, and fuzzing.

## Optional API/daemon auth

Use this only when zcode is exposed beyond a local interactive session:

```toml
api_auth_required = true
api_oidc_issuer = "https://idp.company.example"
api_oidc_audience = "zcode"
api_oidc_jwks_file = "/etc/zcode/oidc-jwks.json"
```

Prefer RS256 with a pinned JWKS distributed by the same fleet-management
system that ships managed config.

## Residual risks

- Trusted hooks and plugins run with the local user's privileges.
- Secret detection is pattern-based and can miss novel token formats.
- Shell sandboxing is a boundary-reduction control, not a complete host
  confidentiality boundary.
- Local audit logs are tamper-evident but still need remote collection for
  centralized SIEM retention.
