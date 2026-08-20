//! Best-effort isolated tmux socket (phase-26 daemon-background-06).
//!
//! Threat model (mirrors the reference utils/tmuxSocket.ts module doc): an
//! agent running `tmux kill-server` / `tmux kill-session` / `tmux send-keys`
//! through the Bash tool would otherwise reach into the USER's real tmux
//! sessions, because the child shell inherits the user's `TMUX` env var. That
//! is a data-loss footgun -- the agent could tear down the very session the
//! user is working in.
//!
//! Defense: when zcode shells out and `tmux` is present on PATH, we point the
//! child's `TMUX` at an isolated socket named `zcode-<pid>` (via tmux's `-L`
//! socket selection). Any tmux command the agent issues then talks to OUR
//! private server, never the user's. The isolated server is torn down with a
//! best-effort `kill-server` on graceful shutdown.
//!
//! Everything here is best-effort and lazy:
//!   - If `tmux` is not on PATH, `tmuxEnvValue` returns null and `TMUX` is left
//!     EXACTLY as the user set it (the reference's "null means do not override"
//!     contract). We never want to break a shell that does not use tmux.
//!   - Init never blocks startup: the socket server is started on first use, and
//!     any failure just yields null (the child keeps the inherited env).
//!
//! The `TMUX` env value format is `<socket_path>,<server_pid>,<session_index>`,
//! matching the reference `getClaudeTmuxEnv` and the fixtures already baked into
//! color_level.zig / terminal_caps.zig (e.g. `/tmp/tmux-501/default,12345,0`).
//! We query the live value straight from tmux via `display-message` so the
//! socket path and server pid are whatever tmux actually chose, rather than
//! guessing the `/tmp/tmux-<uid>/` layout (which varies with `TMUX_TMPDIR`).

const std = @import("std");
const rt = @import("zcode_runtime");
const which = @import("which.zig");

const session_registry = @import("session_registry.zig");

/// Cheap "is tmux on PATH" probe (a PATH walk, no subprocess). Callers use this
/// to decide whether the more expensive `tmuxEnvValue` lazy-init is worth
/// attempting at all -- when tmux is absent there is nothing to isolate and the
/// child must keep the user's inherited env untouched.
pub fn tmuxAvailable(allocator: std.mem.Allocator) bool {
    return which.exists(allocator, "tmux");
}

/// The isolated socket name: `zcode-<pid>`. Caller owns the returned slice.
/// Mirrors the reference `getClaudeSocketName` (`claude-<PID>`). Tied to the
/// process pid so two concurrent zcode REPLs never share a private tmux server.
pub fn socketName(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "zcode-{d}", .{session_registry.currentPid()});
}

/// Build the `TMUX` env value for the isolated socket, lazily starting the
/// private tmux server on first use. Returns null (and applies NO override)
/// when tmux is not on PATH or when starting/querying the server fails -- in
/// that case the child must keep the user's inherited env untouched.
///
/// Caller owns the returned slice (free with `allocator.free`).
pub fn tmuxEnvValue(allocator: std.mem.Allocator) ?[]u8 {
    // Probe PATH first. No tmux -> no override (preserve the user's env).
    if (!which.exists(allocator, "tmux")) return null;

    const name = socketName(allocator) catch return null;
    defer allocator.free(name);

    // Lazy init: start the private server on this socket. `start-server` is
    // idempotent -- a second call against an already-running socket is a no-op,
    // so this is safe to call on every shell-out. Best-effort: ignore failure
    // here and let the display-message query below decide if we have a usable
    // server.
    {
        const start = std.process.run(allocator, rt.io, .{
            .argv = &.{ "tmux", "-L", name, "start-server" },
            .stdout_limit = .limited(4 * 1024),
            .stderr_limit = .limited(4 * 1024),
        }) catch return null;
        allocator.free(start.stdout);
        allocator.free(start.stderr);
    }

    // Ask tmux for the real socket_path + server pid so the TMUX value matches
    // exactly what tmux itself uses (it honors TMUX_TMPDIR etc). Format string
    // is tmux's own #{...} substitution; we request the canonical 3-field TMUX
    // shape `<socket_path>,<pid>,<session_index>`.
    const result = std.process.run(allocator, rt.io, .{
        .argv = &.{ "tmux", "-L", name, "display-message", "-p", "#{socket_path},#{pid},0" },
        .stdout_limit = .limited(4 * 1024),
        .stderr_limit = .limited(4 * 1024),
    }) catch return null;
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        return null;
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    // A well-formed value has at least the two commas of the 3-field shape and
    // a leading socket path. Reject empty / malformed output rather than
    // poisoning the child env with garbage.
    if (trimmed.len == 0 or std.mem.indexOfScalar(u8, trimmed, ',') == null) {
        allocator.free(result.stdout);
        return null;
    }

    // dupe the trimmed slice so the caller owns a tight allocation independent
    // of the larger stdout buffer.
    const value = allocator.dupe(u8, trimmed) catch {
        allocator.free(result.stdout);
        return null;
    };
    allocator.free(result.stdout);
    return value;
}

/// Set `TMUX` in `env_map` to the isolated socket value, if tmux is available.
/// No-op (leaving any inherited/explicit `TMUX` untouched) when tmux is absent
/// or init fails. This is the single hook the shell tool calls so an agent's
/// tmux can never reach the user's real session.
pub fn applyToEnvMap(allocator: std.mem.Allocator, env_map: *std.process.Environ.Map) void {
    const value = tmuxEnvValue(allocator) orelse return;
    defer allocator.free(value);
    // put() copies key/value into the map's own arena, so freeing `value` after
    // is safe.
    env_map.put("TMUX", value) catch {};
}

/// Tear down the isolated tmux server on graceful shutdown. Best-effort: if the
/// server was never started (no tmux command ever ran) `kill-server` simply
/// fails to connect and we ignore it. Never touches the user's real server
/// because we only ever address our private `-L zcode-<pid>` socket.
pub fn killServer(allocator: std.mem.Allocator) void {
    if (!which.exists(allocator, "tmux")) return;
    const name = socketName(allocator) catch return;
    defer allocator.free(name);
    const result = std.process.run(allocator, rt.io, .{
        .argv = &.{ "tmux", "-L", name, "kill-server" },
        .stdout_limit = .limited(4 * 1024),
        .stderr_limit = .limited(4 * 1024),
    }) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "socketName returns zcode-<currentPid>" {
    const name = try socketName(testing.allocator);
    defer testing.allocator.free(name);

    const expected = try std.fmt.allocPrint(testing.allocator, "zcode-{d}", .{session_registry.currentPid()});
    defer testing.allocator.free(expected);

    try testing.expectEqualStrings(expected, name);
    try testing.expect(std.mem.startsWith(u8, name, "zcode-"));
}

test "tmuxEnvValue returns null when tmux is not on PATH" {
    const env = @import("env.zig");
    // Point PATH at a dir that cannot contain tmux so the `which` probe fails
    // deterministically regardless of the host. The override is process-local
    // (env.setOverride) so it does not affect the real environment.
    try env.setOverride("PATH", "/nonexistent-zcode-tmux-test-dir");
    defer env.clearOverrides();

    const value = tmuxEnvValue(testing.allocator);
    if (value) |v| {
        defer testing.allocator.free(v);
        try testing.expect(false); // should have been null
    }
    try testing.expectEqual(@as(?[]u8, null), value);
}

test "applyToEnvMap leaves TMUX untouched when tmux is absent" {
    const env = @import("env.zig");
    try env.setOverride("PATH", "/nonexistent-zcode-tmux-test-dir");
    defer env.clearOverrides();

    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();
    // Seed an inherited TMUX value; the no-op path must preserve it exactly.
    try env_map.put("TMUX", "/tmp/tmux-501/user-session,999,0");

    applyToEnvMap(testing.allocator, &env_map);

    const got = env_map.get("TMUX");
    try testing.expect(got != null);
    try testing.expectEqualStrings("/tmp/tmux-501/user-session,999,0", got.?);
}

test "killServer is a safe no-op when tmux is absent" {
    const env = @import("env.zig");
    try env.setOverride("PATH", "/nonexistent-zcode-tmux-test-dir");
    defer env.clearOverrides();
    // Must not crash or error when tmux cannot be found.
    killServer(testing.allocator);
}
