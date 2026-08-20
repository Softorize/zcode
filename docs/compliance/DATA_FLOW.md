# zcode data flow

Describes every path user data takes inside a zcode process. Useful
as the technical backbone of a GDPR / DPA discussion or a vendor
security review.

The default deployment is a local single-user CLI. It does not require
application-level authentication because access is scoped by the operating
system user/session boundary. Bearer/OIDC authentication applies only when
operators expose the API, IDE bridge, or daemon-like surfaces beyond that
local boundary.

```
+---------------------+       +-----------------------+
|    User keyboard    |-----> |  Terminal input       |
+---------------------+       +-----------+-----------+
                                          |
                                          v
                            +--------------------------+
                            |   REPL / one-shot run    |
                            | (src/cli/repl.zig,       |
                            |  src/agent_runtime.zig)  |
                            +---+----------------------+
                                |
        +-----------------------+-----------------------+
        |                       |                       |
        v                       v                       v
+---------------+      +------------------+    +---------------+
| Session store |      | Provider adapter |    |  Tool dispatch|
| (encrypted at |      | (HTTPS to LLM    |    |  (sandbox +   |
|  rest if key  |      |  provider)       |    |   policy)     |
|  present)     |      +----+-------------+    +-------+-------+
+-------+-------+           |                          |
        |                   |                          v
        v                   v                  +-------+-------+
+---------------+  +-----------------+         |  Shell / Git  |
|  Audit log    |  | Cloud telemetry |         |  / FS / HTTP  |
| (HMAC chain,  |  | (opt-in,        |         |  + SSRF guard |
|  rotates 90d) |  |  control_plane) |         +---------------+
+---------------+  +-----------------+
```

## Trust boundaries

1. **User ↔ zcode process**: local. No trust issue beyond normal
   OS process isolation.
2. **zcode ↔ provider endpoint**: HTTPS, provider's TLS certificate
   chain. SSRF guard refuses private / link-local hosts.
3. **zcode ↔ control plane**: HTTPS + bearer token. Only engaged
   when `control_plane_url` + `cloud_telemetry_opt_in = true`.
4. **zcode ↔ tool processes**: sandboxed via `sandbox-exec` /
   `bwrap`; kernel-level isolation in roadmap
   (`docs/security/SANDBOXING.md`).

## Data at rest

| Item | Path | Encryption |
|---|---|---|
| Session history | `~/.zcode/sessions/*.jsonl` | AES-256-GCM when `session_encryption_enabled=true` (default on) |
| Audit log | `~/.zcode/logs/audit-*.jsonl` | Plaintext + HMAC chain |
| HMAC key | `~/.zcode/logs/hmac.key` | Plaintext, mode 0600 |
| Session key | OS keychain (`zcode:__session_key__`) | Delegated to OS keychain |
| Provider API keys | OS keychain (`zcode:<provider>`) | Delegated to OS keychain |
| Config | `~/.zcode/config.toml` | Plaintext, mode 0600 |
| Policy | `~/.zcode/policy/policy.toml` | Plaintext |

## Data in transit

| Path | Scheme | Notes |
|---|---|---|
| LLM provider | HTTPS | Provider's TLS |
| Control plane | HTTPS | Bearer token |
| MCP server | stdio / HTTPS / SSE | OAuth where supported |
| Update fetch | HTTPS | cosign signature + SHA-256 |

## Retention

- Sessions: operator-configurable (default kept indefinitely).
- Audit: 90 days, rotated daily.
- Provider logs: per provider's own policy (out of scope).
- Cloud telemetry: per operator's control-plane deployment (out of
  scope).
