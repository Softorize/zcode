# KAIROS and the REPL coexist via a single-owner cron-ownership lock

The interactive REPL already fires cron between turns (`cli/repl.zig:5257`). To prevent
KAIROS double-firing the shared cron store, exactly one driver owns cron firing at a time,
arbitrated by a **cron-ownership lock**. An active REPL holds the lock (KAIROS stays
dormant, doing only memory/dream work); when no REPL is present, KAIROS takes the lock and
does proactive work. KAIROS **yields** — pauses mid-task and releases the lock — the
instant a REPL appears, detected via a REPL-maintained presence heartbeat.

This yield-on-presence behavior is our re-mapping of the upstream "15-second blocking
guard": a detached agent has no interactive user to block, so the meaningful guarantee is
that KAIROS never fights a returning user for the repo.

## Consequences

- The REPL must maintain a presence heartbeat and acquire/hold the lock while active.
- Cron firing now depends on *some* owner being alive; if neither a REPL nor KAIROS is
  running, scheduled tasks simply wait (acceptable — they are per-project and durable).
