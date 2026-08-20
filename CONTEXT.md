# zcode

The ubiquitous language for zcode, a Zig 0.16 reimplementation of a Claude Code-style AI coding agent CLI. This glossary defines terms specific to this project so they are used consistently in code, docs, and conversation.

## Language

### KAIROS

**KAIROS**:
zcode's always-on autonomous background agent: a long-lived process that ticks on its own with no user present, runs an "anything worth doing right now?" self-check, executes work under a safety policy, and reaches the user proactively. Distinct from a one-shot run or an interactive REPL session, which are user-initiated and reactive.
_Avoid_: "background mode" (ambiguous with the daemon's remote-access role), "assistant mode".

**Tick**:
A single autonomous wake-up of KAIROS where it evaluates whether there is anything worth doing and, if so, acts. Not the same as a **cron fire** (a scheduled prompt coming due).
_Avoid_: "poll" (reserved for the existing REPL-side cron check), "heartbeat".

**Cron fire**:
The moment a scheduled task's `next_run_ts` comes due and its prompt is enqueued for execution. Driven today by REPL polling; under KAIROS it is driven by the tick loop.
_Avoid_: "trigger", "job run".

**Allowlist**:
The set of tools/actions KAIROS may execute unsupervised. Always includes read-only tools; user-extensible for mutating actions (e.g. run tests, `git status/diff`, fmt). Enforced by a KAIROS-specific `ApprovalHandler` over the existing approval gate.
_Avoid_: "whitelist", "permissions" (reserved for the RBAC/policy layer).

**Proposal**:
A mutating action KAIROS wanted to take but is off the **allowlist**, so it is recorded (in the **brief**) for the user to approve at their next interactive session, not executed.
_Avoid_: "suggestion", "pending action".

**Brief**:
The proactive message KAIROS surfaces to the user: what it did, what it found, and any **proposals** awaiting approval. Always written to a durable file (surfaced on next REPL start and via `zcode kairos status`); time-sensitive items also fire an OS-native notification. Distinct from the existing `/brief` REPL command, which is only a transcript-density UI mode (a naming collision to resolve before shipping).
_Avoid_: reusing "/brief" for both meanings.

**Cron-ownership lock**:
The single-owner lock deciding who fires cron at any moment. An active REPL holds it (and KAIROS stays dormant); when no REPL is present KAIROS takes it. Prevents double-firing the shared cron store.
_Avoid_: confusing with the dream consolidation lock (`.dream_lock`), a separate lock.

**Presence**:
Whether an interactive REPL is currently active, signalled by a REPL-maintained heartbeat. KAIROS only does actionable proactive work when the user is **away** (no presence), and **yields** (pauses mid-task, releases the **cron-ownership lock**) the instant a REPL appears.
_Avoid_: "active", "online".
