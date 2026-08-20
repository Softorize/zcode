//! Resource limits for spawned tool processes.
//!
//! Applies POSIX `setrlimit` caps inside the child after fork() and
//! before exec() so a runaway tool cannot exhaust host memory, FDs,
//! or CPU time. zcode's enterprise runtime targets macOS and Linux;
//! unsupported platforms do not get an isolation claim.
//!
//! Defaults err on the conservative side: most CLI tools complete
//! well within these limits, and an operator can raise them via
//! config. A tool that's hitting the cap is almost always a bug or
//! a prompt-injected denial-of-service.

const std = @import("std");
const builtin = @import("builtin");

pub const Limits = struct {
    /// Maximum resident memory in bytes (RLIMIT_AS on Linux,
    /// RLIMIT_DATA on others that don't implement AS accurately).
    /// 0 = no cap.
    memory_bytes: u64 = 2 * 1024 * 1024 * 1024, // 2 GiB
    /// Wall-clock CPU seconds (RLIMIT_CPU). 0 = no cap.
    cpu_seconds: u64 = 300, // 5 minutes
    /// Maximum number of open file descriptors (RLIMIT_NOFILE).
    /// 0 = no cap.
    max_files: u64 = 1024,
    /// Maximum number of child processes (RLIMIT_NPROC). 0 = no cap.
    max_procs: u64 = 64,
    /// Core dumps disabled by default (RLIMIT_CORE = 0) so aborted
    /// tool processes don't leak process memory to disk.
    allow_core: bool = false,
};

/// Apply parent-side caps that are safe for the long-running zcode
/// REPL itself AND propagate via fork() inheritance to every spawned
/// tool. These are the resource-exhaustion knobs we WANT enforced
/// across the whole process tree -- a prompt-injected `:(){:|:&};:`
/// fork bomb, an FD-leak loop, or a runaway core-dump-on-segv pattern
/// would otherwise take down the host.
///
/// Avoided here: RLIMIT_AS / DATA (parent vmem patterns vary across
/// platforms, and children that legitimately need >2 GiB vmem like
/// long contexts would break) and RLIMIT_CPU (per-process CPU time
/// is cumulative; a long REPL session over many hours can legit hit
/// it). Tool subprocesses already have wall-clock timeouts in
/// shell.zig, which is a tighter knob for "I want this ONE command
/// to die after N seconds."
///
/// Failures are swallowed: a host with already-tight rlimits
/// (e.g. systemd unit, container) might reject a setrlimit if the
/// new max exceeds the existing hard cap. We only LOWER, so on a
/// strict host the existing cap stays in effect anyway.
pub fn applyParentLimits() void {
    if (builtin.os.tag == .windows) return;

    // Cap open FDs. Bounded so we never accidentally raise (would
    // EPERM on most hosts) or lower below the current soft cap
    // (would shrink the in-flight operating envelope). 4096 is the
    // upper bound; if the host already permits more, leave it be.
    setBoundedSoft(std.posix.rlimit_resource.NOFILE, 4096) catch {};

    // Disable core dumps for the whole process tree. A core from a
    // tool that crashed mid-call to an LLM provider can leak API
    // keys, prompt content, or session secrets to disk.
    setOne(std.posix.rlimit_resource.CORE, 0) catch {};

    // RLIMIT_NPROC is intentionally NOT applied here. It is per-uid
    // on Linux/macOS and the kernel checks `current_uid_count + 1 >
    // rlim_cur` at every fork. On a typical desktop the user
    // already has 200-1000 processes (browser, IDE, daemons), so
    // any value low enough to bound a fork bomb (~256-512) breaks
    // legitimate forks in zcode's subtree with EAGAIN. Fork-bomb
    // defense is left to per-tool wall-clock timeouts in
    // tools/shell.zig, which kill the offending subtree directly.
}

fn setBoundedSoft(resource: std.posix.rlimit_resource, target: u64) !void {
    const cur = try std.posix.getrlimit(resource);
    // Never raise above the existing hard cap (would EPERM) and
    // never lower below the existing soft cap (would shrink an
    // operating envelope already in active use).
    const desired = @max(cur.cur, target);
    const new_soft = @min(desired, cur.max);
    if (new_soft == cur.cur) return;
    try std.posix.setrlimit(resource, .{ .cur = new_soft, .max = cur.max });
}

/// Apply limits to the current process. Must be called from the
/// child between fork() and exec(), OR from the parent before
/// `std.process.Child.spawn()` if caller wants the caps to propagate
/// to the child via inheritance. On macOS, inheritance-via-parent is
/// unreliable; prefer the child-side hook when the consumer owns
/// both sides of the spawn.
pub fn apply(limits: Limits) !void {
    if (builtin.os.tag == .windows) {
        // Unsupported target: do not claim equivalent resource
        // isolation on platforms outside the macOS/Linux support set.
        return;
    }

    if (limits.memory_bytes > 0) {
        setOne(RLIMIT_AS_or_DATA(), limits.memory_bytes) catch {};
    }
    if (limits.cpu_seconds > 0) {
        setOne(std.posix.rlimit_resource.CPU, limits.cpu_seconds) catch {};
    }
    if (limits.max_files > 0) {
        setOne(std.posix.rlimit_resource.NOFILE, limits.max_files) catch {};
    }
    if (limits.max_procs > 0) {
        // RLIMIT_NPROC not present on every POSIX; guarded via
        // conditional use.
        if (comptime @hasField(std.posix.rlimit_resource, "NPROC")) {
            setOne(std.posix.rlimit_resource.NPROC, limits.max_procs) catch {};
        }
    }
    if (!limits.allow_core) {
        setOne(std.posix.rlimit_resource.CORE, 0) catch {};
    }
}

fn setOne(resource: std.posix.rlimit_resource, value: u64) !void {
    const lim = std.posix.rlimit{
        .cur = value,
        .max = value,
    };
    try std.posix.setrlimit(resource, lim);
}

fn RLIMIT_AS_or_DATA() std.posix.rlimit_resource {
    // Linux: AS (address space) is the right knob - caps total
    // virtual memory. macOS: RLIMIT_AS exists but behaves as a soft
    // advisory; RLIMIT_DATA gives more accurate enforcement for
    // common allocation patterns.
    return if (comptime builtin.os.tag == .linux)
        std.posix.rlimit_resource.AS
    else
        std.posix.rlimit_resource.DATA;
}

// --- Tests ------------------------------------------------------------

const testing = std.testing;

test "apply with all-zero limits is a no-op" {
    // A fully zeroed limits struct should apply no caps and never
    // error - this lets opt-out call sites pass `.{}` of a derived
    // type with fields set to 0 without surprising failures.
    try apply(.{
        .memory_bytes = 0,
        .cpu_seconds = 0,
        .max_files = 0,
        .max_procs = 0,
        .allow_core = true,
    });
}

// applyParentLimits is intentionally NOT exercised in the unit test
// suite: calling it in-process would lower NPROC/NOFILE/CORE for the
// rest of the test process and cause downstream spawn-heavy tests
// (integration tests that fork zcode subprocesses) to fail. The
// function is small and deterministic; behavior is verified via the
// installed binary in scripts/ci/cli_smoke.sh and by direct
// `getrlimit` checks on a freshly-launched zcode.
