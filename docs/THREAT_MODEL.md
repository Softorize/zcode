# Threat Model -- zcode

**Last updated:** 2026-04-01
**Version:** 0.6.37

---

## Overview

zcode is a terminal-first AI coding agent that executes tool calls (file I/O, shell commands, git operations, HTTP requests) on behalf of an AI model. The default deployment is a local single-user CLI and does not require application-level authentication; it relies on the operating system's user/session boundary. Bearer/OIDC authentication is an optional control for API, IDE bridge, and daemon-like surfaces that cross that local boundary. This document maps trust boundaries, attack surfaces, mitigations, and residual risks.

---

## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| **User -> CLI** | User provides prompts, config, and approval decisions inside the OS-authenticated local session. Trusted. |
| **CLI -> AI Provider** | Network call to external API. Model responses are untrusted input. |
| **CLI -> MCP Server** | Network/stdio call to external tools. Responses are untrusted input. |
| **CLI -> Local Filesystem** | File reads/writes within workspace. Sandbox-enforced boundary. |
| **CLI -> Shell** | Subprocess execution. Highest-risk boundary. |
| **CLI -> Remote Daemon** | HTTP server for session handoff. Network-exposed boundary. |
| **CLI -> Control Plane** | Policy sync and audit event upload. Network-exposed boundary. |
| **Plugin/Hook -> CLI** | Third-party code executes in the CLI lifecycle. Partially trusted. |

---

## Attack Surfaces

### 1. AI Model Response Injection

**Threat:** A malicious or compromised AI model returns responses containing:
- Prompt injection attempting to override system instructions
- Tool calls with malicious arguments (e.g., `rm -rf /`, exfiltration commands)
- Malformed JSON/XML designed to exploit parser vulnerabilities

**Mitigations:**
- Risk-tiered approval gates (LOW/MEDIUM/HIGH/BLOCKED) with user confirmation for high-risk actions
- Sandbox profiles (read-only, workspace-write, no-network) restrict tool capabilities
- Shell tool execution uses an enforced backend when sandboxed:
  - macOS: `sandbox-exec`
  - Linux: `bwrap`
- Policy-based tool blocking and shell pattern blocking still run before execution for fast rejection and better error messages
- Destructive shell command detection (`rm -rf`, `mkfs`, `dd if=`, etc.)
- Workspace path containment with symlink escape protection

**Residual risk:** Shell isolation now fails closed when no supported backend is available unless `ZCODE_ALLOW_UNISOLATED_SHELL=1` is explicitly set. The enforced shell sandbox primarily protects write and network boundaries; it is not a complete confidentiality boundary for arbitrary host reads outside the workspace.

### 2. Parser Exploitation

**Threat:** Malformed model responses or MCP messages exploit parser bugs to cause:
- Denial of service (infinite loops, memory exhaustion)
- Logic errors leading to unintended tool execution

**Mitigations:**
- All parsers use bounded input sizes (16KB headers, 4MB files, 16MB HTTP responses)
- Fuzz testing covers all 48 parser functions
- Zig's safety checks (bounds checking, integer overflow detection in debug/ReleaseSafe)

**Residual risk:** ReleaseFast builds disable safety checks for performance. CI tests run in ReleaseSafe mode.

### 3. Secret Leakage

**Threat:** API keys, tokens, or credentials leak through:
- Accidental inclusion in files written by the agent
- Exposure in audit logs
- Transmission to AI providers in prompts
- Inclusion in session exports or shared bundles

**Mitigations:**
- Secret scanning before file write, edit, and git commit operations
- Secret redaction in audit logs (known prefixes + high-entropy detection)
- Gitleaks configuration for repository-level scanning
- Session encryption (AES-256-GCM) for at-rest protection

**Residual risk:** Secret detection is pattern-based. Novel token formats or low-entropy secrets may not be detected. Base64-encoded secrets without mixed case may bypass the high-entropy heuristic.

### 4. Remote Daemon Exposure

**Threat:** The remote session daemon is an HTTP server that could be:
- Accessed by unauthorized users on the same network
- Subject to denial-of-service attacks
- Used for session hijacking if tokens are compromised

**Mitigations:**
- Binds to 127.0.0.1 only (localhost) by default
- Bearer token authentication required for all requests
- Rate limiting per IP and globally
- 128-bit cryptographically random tokens
- Security headers (CSP, X-Content-Type-Options, Referrer-Policy)

**Residual risk:** No TLS - traffic is plaintext on localhost. For non-localhost deployment, a reverse proxy with TLS termination is required (documented in daemon help).

### 5. Plugin and Hook Supply Chain

**Threat:** Malicious plugins or hooks execute arbitrary code in the CLI lifecycle.

**Mitigations:**
- Hook fingerprinting with SHA-256 and interactive trust prompts
- Marketplace allow/block policy for plugin sources
- SHA-256 integrity verification for marketplace downloads
- User-scope hooks are auto-trusted; workspace hooks require explicit trust

**Residual risk:** Once a hook is trusted, it runs with full CLI privileges. A compromised marketplace source could serve malicious updates between trust checks.

### 6. MCP Server Compromise

**Threat:** A malicious MCP server returns crafted responses to:
- Inject tool calls or override agent behavior
- Exfiltrate workspace data through tool arguments
- Exploit MCP message parsers

**Mitigations:**
- MCP tool calls go through the same approval/sandbox gates as built-in tools
- OAuth authentication with PKCE flow for authenticated MCP servers
- Bounded message parsing with size limits

**Residual risk:** MCP servers with broad tool permissions could still perform authorized but unintended actions.

### 7. Control Plane Trust

**Threat:** A compromised control plane could push:
- Malicious policy bundles that weaken security settings
- False audit events that mask real activity

**Mitigations:**
- SHA-256 hash verification for policy bundles
- Policy file permissions restricted to 0o600
- Policy validation rejects unknown keys and invalid values
- Audit sync failures are logged but do not block operations

**Residual risk:** If both the control plane and the hash are compromised, a malicious policy could be accepted.

---

## Data Flow Summary

```
User Input --> CLI Parser --> Config/Policy Loading --> Provider Selection
                                                            |
                                                     AI Model API
                                                            |
                                                    Response Parsing
                                                            |
                                              Tool Call Extraction
                                                            |
                                    Risk Classification + Approval Gate
                                                            |
                                              Sandbox Enforcement
                                                            |
                                         Tool Execution (file/shell/git/MCP)
                                                            |
                                              Audit Logging
```

---

## Recommendations for Enterprise Deployment

1. **Use `workspace-write` or `no-network` sandbox profiles** for untrusted or experimental models
2. **Enable session encryption** via `ZCODE_SESSION_KEY` for sensitive workspaces
3. **Configure control plane policy sync** for centralized security policy management
4. **Deploy remote daemon behind a TLS-terminating reverse proxy** if exposing beyond localhost
5. **Require bearer/OIDC auth only for API, IDE bridge, or daemon deployments that cross the local user boundary**
6. **Review and trust hooks explicitly** before allowing workspace-level hooks
7. **Set `block_destructive_shell = true`** in policy (enabled by default)
8. **Monitor audit logs** and integrate with SIEM via the control plane sync endpoint
9. **Use `strict` approval mode** for high-security environments
