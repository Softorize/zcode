# zcode SOC2 control mapping

Not an audit; this is a cross-reference so security reviewers can
locate the zcode feature that backs each common SOC2 Trust Services
Criteria control. zcode is a single-user CLI by default and does not
require application-level authentication for local use; API/OIDC controls
apply only when the API, IDE bridge, or daemon-like surfaces are exposed
beyond the local user boundary. Controls that rely on organizational policy
(incident response, background checks, change-management signoffs) are not
in scope for this document.

| TSC | Control area | zcode primitive | Location |
|---|---|---|---|
| CC6.1 | Logical access | Policy engine + RBAC | `src/policy/policy.zig`, `src/policy/rbac.zig` |
| CC6.2 | User registration | Optional HS256 + RS256/JWKS OIDC ID-token verification for API/IDE integrations | `src/core/oidc.zig`, `src/api_server.zig` |
| CC6.3 | Access modification | Managed config locks approval_mode | `src/core/config_parse.zig` |
| CC6.6 | Boundary protection | Sandbox profiles + egress chokepoint | `src/core/sandbox.zig`, `src/core/egress.zig` |
| CC6.7 | Data transmission | HTTPS-only + SSRF guard | `src/core/ssrf_guard.zig`, `src/update.zig` |
| CC6.8 | Malware / tamper | Cosign release signatures + SLSA3 | `.github/workflows/release.yml`, `docs/security/VERIFY_RELEASE.md` |
| CC7.1 | Monitoring | HMAC-chained audit log | `src/core/logger.zig`, `docs/security/AUDIT_LOG.md` |
| CC7.2 | Anomaly detection | Audit-log `zcode audit verify` + destructive-shell guard | `src/tools/bash_security.zig` |
| CC7.3 | Incident response | `SECURITY.md` disclosure policy | `SECURITY.md` |
| CC7.4 | Evidence | Tamper-evident audit log + SBOM | `src/core/logger.zig`, release SBOM |
| CC8.1 | Change management | CI gates (gitleaks, SAST, dep-pin, fuzz, CodeQL) | `.github/workflows/*.yml` |
| C1.1 | Confidentiality | Session-at-rest encryption + OS keychain for secrets + PII redaction | `src/session/store.zig`, `src/core/keychain.zig`, `src/core/logger.zig` |
| P1.1 | Privacy notice | `privacy_redact_prompt_bodies` config | `docs/compliance/GDPR_DPA.md` |
| P4.1 | Data retention | `session_retention_days` + `audit_retention_days` | `src/session/store.zig`, `src/core/logger.zig` |

## Gap notes

- **Third-party pen test**: annual cadence is policy (see below);
  engagement vendor and findings summary are published on
  completion.
- **Continuous monitoring**: CodeQL runs weekly + per-PR; fuzz
  harness runs nightly.
- **Access review**: default local CLI deployments inherit OS account
  access review. When zcode is deployed as an API or daemon, OIDC identity
  claims and the RBAC role table form the access-review substrate.

## Pen test cadence

- **Frequency**: annual.
- **Scope**: release binary, daemon HTTP surface, MCP client,
  sandbox escape attempts, supply-chain integrity.
- **Publication**: executive summary in `docs/compliance/pen-test/`
  dated-subdirectory, with critical findings tracked to closure
  before summary publication.
