# KAIROS runs as a dedicated process, not bolted onto the remote daemon

KAIROS (the always-on autonomous agent) runs as a dedicated long-lived `zcode kairos`
process with its own state file (`~/.zcode/kairos.state`) and `start/stop/status`
lifecycle, reusing lifecycle helpers extracted from `remote_daemon.zig`. We rejected
adding the tick loop to the existing remote-access daemon because that would force
anyone running KAIROS to also run a network listener and would conflate two distinct
purposes (remote access vs. local autonomy), enlarging the attack surface. Crash-restart
is delegated to the OS supervisor (launchd `KeepAlive` / systemd) rather than a built-in
supervisor, keeping the process itself simple.

## Consequences

- Some lifecycle code in `remote_daemon.zig` must be factored into a shared helper so
  both daemons use one implementation of detached spawn + PID/state-file management.
- KAIROS has no network surface of its own; remote control (if ever wanted) is a
  separate, deliberate addition.
