# Security Policy

## Supported versions

`zcode` is currently pre-`1.0`. Security fixes are targeted at:

- `main`
- the latest tagged release

Older tags are not guaranteed to receive backports.

## Reporting a vulnerability

Do not open a public GitHub issue for security reports.

Use [GitHub private vulnerability reporting](https://github.com/Softorize/zcode/security/advisories/new).
If that form is unavailable, contact the maintainers through the
[Softorize organization profile](https://github.com/Softorize) without
including vulnerability details in a public issue.

Include:

- affected version or commit
- operating system
- reproduction steps
- impact assessment
- whether the issue requires credentials, local access, or repository access

## CVE / CNA

zcode is not yet a GitHub CNA, so CVE IDs are requested via MITRE
when a disclosure is coordinated. We publish a `CVE-ID` field in the
GitHub Security Advisory once issued.

## Response expectations

- We will acknowledge valid reports as quickly as practical.
- We will aim to reproduce, triage, and fix high-impact issues first.
- Coordinated disclosure is preferred until a fix or mitigation is available.

## Supply-chain and assurance docs

- [docs/security/VERIFY_RELEASE.md](docs/security/VERIFY_RELEASE.md) -- cosign / SLSA verification steps for every release.
- [docs/security/AUDIT_LOG.md](docs/security/AUDIT_LOG.md) -- audit log format, retention, and chain verification.
- [docs/security/SANDBOXING.md](docs/security/SANDBOXING.md) -- tool-process isolation layers and roadmap.
- [docs/compliance/](docs/compliance/) -- SOC2 mapping, GDPR DPA template, data-flow diagram.
- [docs/fleet/](docs/fleet/) -- Intune / Jamf / Ansible deployment playbooks.
