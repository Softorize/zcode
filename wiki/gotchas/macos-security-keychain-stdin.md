# macOS `security add-generic-password`: secret on stdin, not argv

`src/core/keychain.zig` `setMacos` feeds the secret to `/usr/bin/security
add-generic-password` via stdin, not via `-w <value>` on argv. Two reasons:

- A secret on argv is visible to any process that can read `/proc`-equivalent
  argv (other users' `ps`, process monitors). stdin is private to the child.
- `add-generic-password -w` with NO following value reads the password from
  stdin. When stdin is a pipe it does not prompt (it only prompts twice when
  stdin is a tty). This mirrors the Linux `secret-tool store` stdin path in the
  same file.

The `-X` (hex) flag was rejected: it still puts the (hex-encoded) secret on
argv, so it does not solve the observability problem.

## Locked keychain = exit 36

`security` exits 36 when the target keychain is locked. We map that to a
distinct `Error.KeychainLocked` (constant `macos_keychain_locked_exit = 36`)
in both `setMacos` and `getMacos`, and `get` propagates it rather than masking
it behind the file-store fallback (a locked keychain is actionable: unlock and
retry, not "backend missing"). `keychain.keychain_locked_hint` is the
user-facing remedy string; `provider_cmds.zig` prints it on the keychain
set/get commands.

The reference's 30s TTL read-dedup cache is deliberately NOT ported: zcode
reads credentials once at startup, so the per-frame read-storm the cache solves
does not exist here.
