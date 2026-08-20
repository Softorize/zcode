# Path-safety guard: bypass-immune ordering invariant

`core/path_safety.zig` (pure verdict) protects auto-edits/writes to
dangerous dirs (`.git`, `.vscode`, `.idea`, `.claude`, `.zcode`),
dangerous files (`.bashrc`, `.gitconfig`, `.mcp.json`, `.claude.json`,
`.claude.toml`, ...), and suspicious patterns (trailing dot/space, DOS
device suffix, 8.3 `~N` short names, three-dot components, UNC/long-path
prefixes). Ported from the reference `filesystem.ts`
(`isDangerousFilePathToAutoEdit`, `hasSuspiciousWindowsPathPattern`).

## Load-bearing invariants (do not break)

1. **The gate in `agent_tools.zig:executeToolCall` runs BEFORE the
   `sandbox_mod.authorizeToolYolo` yolo short-circuit.** This is the
   only place yolo does NOT win. If you move `pathSafetyGate(...)` below
   the yolo check, the guard becomes useless because yolo would already
   have approved the edit. Mirrors reference step 1g where safetyCheck
   is surfaced as an `ask` that survives bypass mode.

2. **`.claude/worktrees/` structural exception.** A `.claude` segment
   immediately followed by `worktrees` is skipped (that is where
   zcode/Claude store git worktrees, not user config). Without it,
   legitimate worktree edits break. A nested `.claude` deeper inside the
   worktree is still blocked.

3. **Pattern DETECTION, not normalization.** We never canonicalize 8.3
   short names / long-path prefixes (the reference explains why:
   TOCTOU + new-file-does-not-exist problems). We detect and require
   approval. Checks run on ALL platforms because NTFS can mount on
   macOS/Linux.

4. **No per-segment lowercase allocation.** Hot path on every edit. Use
   `std.ascii.eqlIgnoreCase`, never an allocated lowercased copy.

## Two layers of enforcement (both kept on purpose)

- **Tool-level floor** (`tools/file.zig` `write()`/`edit()`): always
  blocks (returns a model-readable refusal string, same convention as
  the binary-edit refusal). Defense-in-depth for direct callers that
  bypass the agent gate. Also re-checks the symlink-resolved realpath
  via `checkPathSafetyResolved` so a symlink to a dangerous target
  cannot slip past.
- **Gate-level guard** (`agent_tools.zig` `pathSafetyGate`): adds the
  "prompt even in yolo" behavior. Non-interactive runs block (cannot
  prompt). Interactive runs prompt the user with `yolo_mode = false`
  passed deliberately to `approval_mod.evaluate` so the gate is
  bypass-immune.

The reference treats safetyCheck as `ask` (promptable), not hard-deny;
the file-tool floor is the zcode hard-block addition.
