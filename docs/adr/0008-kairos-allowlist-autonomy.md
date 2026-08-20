# KAIROS autonomy is allowlist-driven, not full or plan-only

When KAIROS acts with no human present, it runs through a KAIROS-specific
`ApprovalHandler` layered over the existing approval gate: read-only tools are always
allowed, plus a user-extensible allowlist of mutating actions (e.g. run tests,
`git status`/`diff`, fmt). Anything outside the allowlist is NOT executed — it is recorded
as a **proposal** for the user to approve at their next interactive session.

We rejected full autonomy in a sandbox (too high a blast radius for an unattended agent
on the user's own repo) and plan-only (too weak — KAIROS could not even run tests). The
allowlist is the deliberate middle: useful enough to run scheduled work and safe checks,
safe enough that it cannot edit, commit, or run destructive shell unsupervised.

## Consequences

- The gate already auto-denies mutating tools when no handler is registered (the daemon
  path); KAIROS supplies a handler that turns those denials into recorded proposals
  instead of silent failures.
- The allowlist is configuration; getting it wrong (too permissive) is the main risk, so
  defaults stay conservative.
