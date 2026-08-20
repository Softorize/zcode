# Historical Parity Roadmap

Last updated: 2026-04-26

This file is retained only as historical context. It was based on an older
reverse-engineering pass and no longer reflects the active zcode surface.

Use `docs/PARITY_ROADMAP_V2.md` for the current source-verified quality plan.

Reason for superseding:

- It marked implemented tools and commands as missing.
- It used raw feature count as the main success measure.
- It did not distinguish reference stubs or feature-gated code from durable
  product requirements.
- It predates major zcode work on MCP, sessions, marketplace, plugins, IDE API,
  release engineering, and REPL UX.

The current roadmap prioritizes product quality systems instead:

- permission and safety depth
- diagnostics and onboarding
- managed settings and feature gates
- agent/background-work maturity
- IDE and remote integration
- cross-platform hardening
