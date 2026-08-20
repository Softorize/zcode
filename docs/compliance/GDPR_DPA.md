# GDPR Data Processing Addendum (zcode)

zcode is a desktop/CLI tool executed on the user's machine. It does
not, by default, process personal data on behalf of a controller
other than the user themselves. Enterprise deployments that ship
zcode to end users may, however, need to document its data handling
as part of a broader DPA.

This file is a template. Negotiate the final contractual terms with
your legal team; the technical facts below are accurate for zcode as
shipped and referenced by version in the header.

## 1. Definitions

"Controller", "Processor", "Data Subject", "Personal Data",
"Processing", "Sub-processor", and "Supervisory Authority" carry the
meanings assigned in Article 4 of the EU General Data Protection
Regulation (Regulation 2016/679) and in equivalent UK GDPR.

## 2. Categories of data

zcode processes the following categories of data **on the user's own
machine**:

- **Prompts and responses** entered by the user into the model.
- **Session metadata**: session IDs, timestamps, tool call names,
  tool outcomes (success/failure), token counts.
- **Audit-log entries**: event types, timestamps, redacted payloads
  (see `docs/security/AUDIT_LOG.md`).
- **Environment data**: OS name and version, terminal capabilities,
  zcode version, git commit of zcode binary.

zcode **does NOT** collect: user names, email addresses, machine
identifiers beyond what the OS exposes to any local process, IP
addresses, geolocation, or behavioral telemetry - unless the
operator configures a `control_plane_url` and opts in via
`cloud_telemetry_opt_in = true`.

## 3. Where data is stored

- **On-device**: `~/.zcode/` (sessions, audit, keychain fallback).
  Encrypted at rest when `session_encryption_enabled = true`.
- **Remote**: only when `control_plane_url` is configured. The
  endpoint, retention, and DPIA for that surface are the
  deploying organization's responsibility.
- **Third-party model providers**: prompts sent to the configured
  LLM provider traverse their TLS endpoints. The provider is a
  sub-processor under this framing; the deploying organization is
  responsible for selecting providers compliant with their
  residency requirements.

## 4. Retention

- Sessions: `session_retention_days` default 0 (kept indefinitely);
  configurable up to 3650 days.
- Audit log: 90 days default rotation.
- Keychain secrets: no automatic expiry; rotate via
  `zcode session rotate-key` / OS keychain tools.

## 5. Data subject rights

Because zcode data lives on the user's device and (optionally)
their configured control plane:

- **Access**: `zcode session export <id>`, `zcode audit verify`, or
  direct inspection of `~/.zcode/`.
- **Rectification**: edit session files directly (keep HMAC chain
  integrity in mind).
- **Erasure**: `rm -rf ~/.zcode/sessions/<id>.jsonl` or
  `zcode session delete <id>` (when available).
- **Portability**: `zcode session export <id>` emits JSONL.
- **Objection / restriction**: disable `cloud_telemetry_opt_in` and
  `control_plane_policy_sync`.

## 6. Security of processing

See `docs/security/VERIFY_RELEASE.md`, `docs/security/AUDIT_LOG.md`,
and `docs/security/SANDBOXING.md` for the technical and
organizational measures applied at supply chain, audit, and
isolation layers.

## 7. Sub-processors

Sub-processors vary per deployment because the LLM provider and
control-plane endpoint are operator-selected. Maintain your own
list of engaged sub-processors; zcode publishes its own vendor list
(currently: GitHub for code hosting, Sigstore for signing, Apple
for notarization).

## 8. Breach notification

Report suspected breaches via the channel in `SECURITY.md`.
