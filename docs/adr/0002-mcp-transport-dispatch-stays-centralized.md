# MCP transport dispatch stays centralized, no Transport vtable

**Status:** accepted

An architecture review flagged `src/mcp/client.zig` (~3.5k lines) as braiding
transport with protocol across "five parallel `rpc*` branches" and recommended
extracting a polymorphic `Transport` interface (vtable) so HTTP / stdio /
WebSocket become swappable adapters.

On close inspection the transport dispatch is **already centralized** in one
place: `rpcRequestForServer` selects the transport (`isWebSocketTransport` /
`isHttpTransport` / stdio fallback, incl. the persistent-session variants) and
every protocol method (`tools/call`, `tools/list`, `resources/*`, `prompts/*`,
`ping`) routes through it. The `rpc*` functions are effectively transport
adapters already, dispatched from a single seam.

We delete the dead per-transport `invokeHttp` / `invokeStdio` /
`invokeWebSocket` helpers (no call sites; superseded by `rpcRequestForServer`)
and keep the centralized dispatch as-is.

## Why not the vtable

1. **Dispatch is already a single seam.** A `Transport` vtable would add
   polymorphism over an `if/else` that already lives in exactly one function;
   the locality win is marginal.
2. **High risk, hard to verify.** The MCP path cannot be exercised against live
   servers in local/CI runs (the suite mocks transports), so a large structural
   rewrite of session lifecycle + OAuth token refresh + notifications behind a
   new interface trades real regression risk for little gain.

## Consequence

Future reviews should not re-suggest a `Transport` vtable extraction. If a new
transport is added, give it an `rpc*` method and a branch in
`rpcRequestForServer`. Shared protocol concerns (retry, token refresh) can be
factored into helpers called by the `rpc*` methods without introducing a vtable.
