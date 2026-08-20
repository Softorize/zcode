# zcode sandboxing model

zcode runs tool processes (`shell`, `bash`, `fs_extra`, subagents)
under increasing layers of isolation. This doc maps what's in place
today and what the roadmap toward kernel-level privilege separation
looks like.

## Layers in effect today

1. **Policy engine** (`src/policy/policy.zig`). Classifies every
   tool call into one of four risk tiers (LOW, MEDIUM, HIGH,
   BLOCKED). BLOCKED calls never reach a process. HIGH requires
   interactive approval unless `--approve-high` / `yolo` is set.
2. **Sandbox profile** (`src/core/sandbox.zig`). A config-level
   mode: `read-only`, `workspace-write`, `no-network`,
   `danger-full-access`. Applied by wrapping the child command
   in `sandbox-exec` (macOS) or `bwrap` (Linux) with a profile
   derived from the mode.
3. **Destructive-shell guard** (`src/tools/bash_security.zig`).
   Pattern-blocks `rm -rf /`, `:(){:|:&};:`, `mkfs`, pipe-to-shell
   installers, etc., before the child ever spawns.
4. **SSRF guard** (`src/core/ssrf_guard.zig`). URL-level check
   that refuses RFC1918, link-local, loopback (where not allowed),
   and AWS/GCP metadata endpoints.
5. **Egress chokepoint** (`src/core/egress.zig`). Central policy
   decision combining scheme checks, SSRF defense, managed-config
   allowlists, and private-LAN plaintext opt-in.
6. **Resource caps** (`src/core/resource_limits.zig`). `setrlimit`
   wrapper that caps memory, CPU seconds, file descriptors, and
   child process count for spawned tools on macOS/Linux.

## Known gaps (D14 roadmap)

### Linux: seccomp-bpf + Landlock

Today's `bwrap` profile isolates filesystem and network namespaces
but doesn't filter syscalls. A compromised tool that breaks out of
a chroot or accesses `/proc` via a clever path can still invoke
arbitrary syscalls.

Plan:
- Compile-time-gated `src/core/sandbox_linux.zig` that installs a
  seccomp-bpf allowlist in the child right before exec().
- Baseline allowlist covers: read/write/close, mmap/munmap,
  open*/fstat/getdents, rt_sigprocmask, exit_group, brk, futex.
- Add Landlock (kernel 5.13+) as a second layer for FS scoping,
  falling back silently on older kernels.

### macOS: tighter sandbox-exec profile

Current profile is coarse. Refinement plan:
- Start from Apple's `(version 1)(deny default)` and add only the
  minimum required operations per tier.
- Investigate direct `sandbox_init` via `@extern` so we can ship a
  profile not expressible in sandbox-exec's DSL.

## Why this order

- Kernel-level isolation matters most when the tool is high-risk
  and the user hasn't had a chance to review. The order above
  puts the cheapest, highest-leverage checks first (policy,
  destructive-shell) and defers the OS-specific work to the end
  because its value compounds only after everything above is
  already in place.
- Egress allowlists are process-wide managed policy; include every
  provider, update, MCP, marketplace, and internal control-plane host
  needed by the fleet before enforcing a non-empty list.

## For operators

- Prefer `--sandbox no-network` for untrusted prompts.
- Lock `approval_mode = "strict"` in managed config for fleet
  deployments.
- Ship an egress allowlist via managed config once the provider
  endpoints you need are known.
- Watch `~/.zcode/logs/audit-*.jsonl` for policy-deny events; a
  spike usually indicates prompt-injection attempts.
