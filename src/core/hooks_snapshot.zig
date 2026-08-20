//! Startup hooks-config snapshot + policy gating (Task 14 / hooks-12).
//!
//! Ports the reference `getHooksFromAllowedSources` /
//! `captureHooksConfigSnapshot` family (hooksConfigSnapshot.ts:18-124). Two
//! concerns live here:
//!
//!  1. Policy gating. A small set of policy/scope flags decides which settings
//!     scopes are allowed to contribute hooks at all:
//!       - policy `disableAllHooks: true`               -> no hooks run.
//!       - policy `allowManagedHooksOnly: true`         -> policy scope only.
//!       - policy `strictPluginOnlyCustomization: true` -> policy scope only
//!         (user/project/local customization is blocked; only managed/plugin
//!         hooks survive).
//!       - any non-policy `disableAllHooks: true`       -> policy scope only.
//!       - else                                          -> all scopes run.
//!     In zcode's current single-merge-source model the "managed/plugin" scope
//!     maps onto the `policy` settings source, so every "managed only" gate
//!     collapses to "policy-scope only". Cross-scope/plugin merge is deferred
//!     to Phase 1's full multi-scope work (see the phase plan Out-of-scope).
//!
//!  2. Snapshot. The reference captures the resolved gate ONCE at session
//!     start so that mid-session edits to settings.json do not silently change
//!     hook behavior until an explicit refresh (a `/hooks` edit or a settings
//!     file-watch event). zcode mirrors that: the gate decision is computed on
//!     first `get()` and cached behind a mutex. `refresh()` re-reads; tests use
//!     `resetForTest()`.
//!
//! The snapshot intentionally caches only the *gate decision*, not the hook
//! defs themselves. Under the current architecture the per-event dispatch in
//! `hooks.zig` still reads the hook arrays fresh from disk each event; what a
//! mid-session edit could change about *whether hooks run at all* is exactly
//! the policy gate, and that is what we freeze. When Phase 1 lands full
//! multi-scope merge, the cached value can be widened to the merged def set
//! without changing this module's call contract.

const std = @import("std");
const rt = @import("zcode_runtime");
const settings_sources = @import("settings_sources.zig");

/// The resolved policy gate. `disable_all` short-circuits every hook;
/// `policy_scope_only` restricts the surviving scopes to the policy
/// (enterprise-managed) source. Both being false means "run all scopes".
pub const Gate = struct {
    disable_all: bool = false,
    policy_scope_only: bool = false,
};

var g_gate: ?Gate = null;
/// The workspace cwd the cached gate was captured for. A `get()` for a
/// different cwd is a different session (each process runs one session in
/// production; tests run many), so the gate is recaptured rather than serving a
/// gate resolved for an unrelated workspace. Within a single cwd the snapshot
/// still freezes mid-session edits until `refresh()`.
var g_gate_cwd: ?[]u8 = null;
var g_gate_cwd_buf: [4096]u8 = undefined;
var g_mutex: std.Io.Mutex = .init;

/// Compute the policy gate fresh from disk for the given workspace cwd. Pure
/// with respect to module state: it reads the five settings sources and folds
/// them into a `Gate` without touching the cached snapshot. Exposed so callers
/// (and tests) can evaluate the gate without installing it.
///
/// Precedence mirrors `getHooksFromAllowedSources` (hooksConfigSnapshot.ts:18-53):
///   - policy `disableAllHooks`               -> disable_all.
///   - policy `allowManagedHooksOnly`         -> policy_scope_only.
///   - policy `strictPluginOnlyCustomization` -> policy_scope_only.
///   - any non-policy `disableAllHooks`       -> policy_scope_only.
pub fn computeGate(allocator: std.mem.Allocator, cwd: []const u8) Gate {
    // policy disableAllHooks short-circuits everything else.
    if (settings_sources.sourceScalarBool(allocator, cwd, null, .policy, "disableAllHooks") orelse false) {
        return .{ .disable_all = true, .policy_scope_only = false };
    }

    const managed_only = settings_sources.sourceScalarBool(allocator, cwd, null, .policy, "allowManagedHooksOnly") orelse false;
    const strict_plugin_only = settings_sources.sourceScalarBool(allocator, cwd, null, .policy, "strictPluginOnlyCustomization") orelse false;

    // A non-policy disableAllHooks (project/local/user/flag) downgrades the run
    // to policy-scope only, the same as allowManagedHooksOnly.
    var nonpolicy_disable_all = false;
    for (settings_sources.sourceOrder()) |source| {
        if (source == .policy) continue;
        if (settings_sources.sourceScalarBool(allocator, cwd, null, source, "disableAllHooks") orelse false) {
            nonpolicy_disable_all = true;
            break;
        }
    }

    return .{
        .disable_all = false,
        .policy_scope_only = managed_only or strict_plugin_only or nonpolicy_disable_all,
    };
}

/// Return the cached gate, computing and installing it on first call
/// (lazy capture, like the reference's snapshot-on-first-read). Subsequent
/// calls return the same frozen value until `refresh()` or `resetForTest()`.
pub fn get(allocator: std.mem.Allocator, cwd: []const u8) Gate {
    g_mutex.lock(rt.io) catch {};
    defer g_mutex.unlock(rt.io);

    if (g_gate) |g| {
        if (g_gate_cwd) |c| {
            if (std.mem.eql(u8, c, cwd)) return g;
        }
    }
    const gate = computeGate(allocator, cwd);
    g_gate = gate;
    rememberCwd(cwd);
    return gate;
}

/// Stash the captured cwd in a fixed buffer (no allocator: the snapshot is a
/// process-global with no deinit hook). Paths longer than the buffer fall back
/// to "no cwd remembered", which simply means the next `get()` recaptures - a
/// safe, slightly-less-cached degradation.
fn rememberCwd(cwd: []const u8) void {
    if (cwd.len > g_gate_cwd_buf.len) {
        g_gate_cwd = null;
        return;
    }
    @memcpy(g_gate_cwd_buf[0..cwd.len], cwd);
    g_gate_cwd = g_gate_cwd_buf[0..cwd.len];
}

/// Re-read the gate from disk and replace the cached snapshot. Called when the
/// user edits settings via `/hooks` or a settings file-watch fires. Returns the
/// freshly computed gate.
pub fn refresh(allocator: std.mem.Allocator, cwd: []const u8) Gate {
    g_mutex.lock(rt.io) catch {};
    defer g_mutex.unlock(rt.io);

    const gate = computeGate(allocator, cwd);
    g_gate = gate;
    rememberCwd(cwd);
    return gate;
}

/// Test-only: drop the cached snapshot so the next `get()` recaptures. The
/// process-global mutable state needs the same install-once discipline as
/// `rt.io`; tests must reset it between cases to stay independent.
pub fn resetForTest() void {
    g_mutex.lock(rt.io) catch {};
    defer g_mutex.unlock(rt.io);
    g_gate = null;
    g_gate_cwd = null;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const test_helpers = @import("test_helpers.zig");

test "computeGate: no settings yields an open gate" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirPath(testing.allocator, &tmp, ".");
    defer testing.allocator.free(cwd);

    const gate = computeGate(testing.allocator, cwd);
    try testing.expect(!gate.disable_all);
    try testing.expect(!gate.policy_scope_only);
}

test "computeGate: non-policy disableAllHooks downgrades to policy-scope only" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".claude");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".claude/settings.json",
        .data = "{\"disableAllHooks\":true}",
    });

    const cwd = try test_helpers.tmpDirPath(testing.allocator, &tmp, ".");
    defer testing.allocator.free(cwd);

    const gate = computeGate(testing.allocator, cwd);
    // A project-scope disableAllHooks is NOT a full disable: it restricts the
    // run to the policy (managed) scope, mirroring the reference.
    try testing.expect(!gate.disable_all);
    try testing.expect(gate.policy_scope_only);
}

test "get caches and refresh recaptures the gate" {
    resetForTest();
    defer resetForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirPath(testing.allocator, &tmp, ".");
    defer testing.allocator.free(cwd);

    // First capture: no settings -> open gate.
    const first = get(testing.allocator, cwd);
    try testing.expect(!first.policy_scope_only);

    // Edit the settings AFTER the snapshot was taken. get() must keep returning
    // the frozen value (a mid-session edit does not change behavior).
    try tmp.dir.createDirPath(rt.io, ".claude");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".claude/settings.json",
        .data = "{\"disableAllHooks\":true}",
    });
    const still_cached = get(testing.allocator, cwd);
    try testing.expect(!still_cached.policy_scope_only);

    // Only an explicit refresh picks up the edit.
    const refreshed = refresh(testing.allocator, cwd);
    try testing.expect(refreshed.policy_scope_only);
    const after = get(testing.allocator, cwd);
    try testing.expect(after.policy_scope_only);
}
