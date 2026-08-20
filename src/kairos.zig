//! KAIROS — always-on autonomous background agent.
//!
//! A dedicated, per-project, long-lived process (`zcode kairos serve <cwd>`,
//! launched detached by `zcode kairos start`). While no interactive REPL is
//! present it owns the cron-ownership lock and:
//!   - fires this project's due scheduled prompts (cron),
//!   - periodically runs an "anything worth doing?" self-check,
//! both under the allowlist autonomy policy: read-only tools and allowlisted
//! mutating actions run unsupervised; anything else is recorded as a proposal
//! for the user to approve later (ADR 0008). It yields the moment a REPL appears
//! (ADR 0009), and is bounded by a daily model-tick cap plus a per-tick bound.
//! Findings are written to a durable brief and surfaced via OS notifications.
//!
//! Lifecycle mirrors `remote_daemon.zig` but state is per-project under
//! `~/.zcode/kairos/<project-key>/` and there is no network listener (ADR 0007).
//! See docs/KAIROS.md for the full design.

const std = @import("std");
const rt = @import("zcode_runtime");
const std_io = @import("core/std_io.zig");
const clock = @import("core/clock.zig");
const paths = @import("core/paths.zig");
const env = @import("core/env.zig");
const types = @import("core/types.zig");
const cron = @import("core/cron.zig");
const kairos_lock = @import("core/kairos_lock.zig");
const kairos_brief = @import("core/kairos_brief.zig");
const kairos_policy = @import("core/kairos_policy.zig");
const os_notify = @import("core/os_notify.zig");

const config_mod = @import("core/config.zig");
const policy_mod = @import("policy/policy.zig");
const logger_mod = @import("core/logger.zig");
const session_store = @import("session/store.zig");
const mcp_client = @import("mcp/client.zig");
const browser_bridge_mod = @import("mcp/browser_bridge.zig");
const agent_runtime = @import("agent_runtime.zig");
const session_mgmt = @import("session_mgmt.zig");

const STATE_FILE = "kairos.state";
const USAGE_FILE = "usage.json";
const BACKLOG_FILE = "backlog.md";

/// How often the serve loop wakes to check presence + due cron. Cheap: only
/// file checks and timestamp compares (no model calls).
const POLL_INTERVAL_NS: u64 = 10 * std.time.ns_per_s;

/// Per-tick bound: never fire more than this many due cron jobs in one wake.
const MAX_FIRES_PER_TICK: usize = 8;

/// Defaults for the spend guardrails (overridable via env).
const DEFAULT_DAILY_CAP: i64 = 50; // max model-ticks/day; 0 disables KAIROS model work
const DEFAULT_SELF_CHECK_SECS: i64 = 30 * 60; // baseline self-check cadence

pub const State = struct {
    pid: i32,
    started_ts: i64,
};

// ===========================================================================
// Lifecycle: start / status / stop
// ===========================================================================

pub fn start(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    if (try loadState(allocator, cwd)) |state| {
        if (isPidRunning(state.pid)) {
            return std.fmt.allocPrint(allocator, "kairos already running\tpid={d}", .{state.pid});
        }
    }
    deleteState(allocator, cwd) catch {};

    const exe = try std.process.executablePathAlloc(rt.io, allocator);
    defer allocator.free(exe);

    const child = try std.process.spawn(rt.io, .{
        .argv = &.{ exe, "kairos", "serve", cwd },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const pid: i32 = @intCast(child.id orelse 0);

    const deadline_ns = clock.nowNanos() + 3 * std.time.ns_per_s;
    while (clock.nowNanos() < deadline_ns) {
        clock.sleepNanos(50 * std.time.ns_per_ms);
        if (try loadState(allocator, cwd)) |state| {
            if (state.pid == pid) {
                return std.fmt.allocPrint(allocator, "started kairos\tpid={d}\tproject={s}", .{ state.pid, cwd });
            }
        }
    }
    std.posix.kill(pid, std.posix.SIG.TERM) catch {};
    return error.KairosStartTimeout;
}

pub fn status(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const proposals = kairos_brief.proposalCount(allocator, cwd);
    if (try loadState(allocator, cwd)) |state| {
        return std.fmt.allocPrint(
            allocator,
            "kairos\trunning={}\tpid={d}\tstarted={d}\tproposals={d}\tproject={s}\n",
            .{ isPidRunning(state.pid), state.pid, state.started_ts, proposals, cwd },
        );
    }
    return std.fmt.allocPrint(allocator, "kairos\trunning=false\tproposals={d}\n", .{proposals});
}

pub fn stop(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const state = (try loadState(allocator, cwd)) orelse return allocator.dupe(u8, "kairos not running");
    if (isPidRunning(state.pid)) {
        std.posix.kill(state.pid, std.posix.SIG.TERM) catch {};
    }
    try deleteState(allocator, cwd);
    kairos_lock.releaseCronLock(allocator, cwd);
    return std.fmt.allocPrint(allocator, "stopped kairos\tpid={d}", .{state.pid});
}

// ===========================================================================
// The serve loop
// ===========================================================================

pub fn serve(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    cfg: *const config_mod.Config,
    policy: *policy_mod.Policy,
    audit: *logger_mod.AuditLogger,
    store: *session_store.Store,
    mcp: *mcp_client.Client,
    browser: ?*browser_bridge_mod.BrowserBridge,
) !void {
    try writeState(allocator, cwd, .{ .pid = getpid(), .started_ts = clock.nowSeconds() });

    var cron_store = cron.CronStore.init(allocator);
    defer cron_store.deinit();
    cron_store.loadDurable();

    var allowlist = buildAllowlist(allocator);
    defer freeAllowlist(allocator, &allowlist);

    const deps = Deps{ .cfg = cfg, .policy = policy, .audit = audit, .store = store, .mcp = mcp, .browser = browser };
    const cap = envInt(allocator, "ZCODE_KAIROS_DAILY_CAP", DEFAULT_DAILY_CAP);
    const self_secs = envInt(allocator, "ZCODE_KAIROS_INTERVAL_SECS", DEFAULT_SELF_CHECK_SECS);
    var last_self_check: i64 = 0;

    var holding_lock = false;
    defer if (holding_lock) kairos_lock.releaseCronLock(allocator, cwd);

    while (true) {
        // Yield to a present REPL.
        if (kairos_lock.isPresent(allocator, cwd)) {
            if (holding_lock) {
                kairos_lock.releaseCronLock(allocator, cwd);
                holding_lock = false;
            }
            clock.sleepNanos(POLL_INTERVAL_NS);
            continue;
        }
        if (!holding_lock) {
            holding_lock = kairos_lock.acquireCronLock(allocator, cwd, .kairos);
            if (!holding_lock) {
                clock.sleepNanos(POLL_INTERVAL_NS);
                continue;
            }
        }

        // 1. Fire due cron jobs for this project (bounded per tick + daily cap).
        var fires: usize = 0;
        while (fires < MAX_FIRES_PER_TICK) : (fires += 1) {
            const due = cron_store.pollDueForCwd(cwd) orelse break;
            const prompt = allocator.dupe(u8, due) catch break;
            defer allocator.free(prompt);
            if (!tryConsumeTick(allocator, cwd, cap)) break;
            runTurn(allocator, cwd, deps, allowlist.items, prompt, "cron fired", prompt);
        }

        // 2. Periodic self-check, gated cheaply so we don't pay for empty ticks.
        const now = clock.nowSeconds();
        if (self_secs > 0 and now - last_self_check >= self_secs) {
            last_self_check = now;
            if (gitDirty(allocator, cwd) or backlogPresent(allocator, cwd)) {
                if (tryConsumeTick(allocator, cwd, cap)) {
                    const sc_prompt = buildSelfCheckPrompt(allocator, cwd) catch null;
                    if (sc_prompt) |p| {
                        defer allocator.free(p);
                        runTurn(allocator, cwd, deps, allowlist.items, p, "self-check", p);
                    }
                }
            }
        }

        clock.sleepNanos(POLL_INTERVAL_NS);
    }
}

const Deps = struct {
    cfg: *const config_mod.Config,
    policy: *policy_mod.Policy,
    audit: *logger_mod.AuditLogger,
    store: *session_store.Store,
    mcp: *mcp_client.Client,
    browser: ?*browser_bridge_mod.BrowserBridge,
};

/// Run one KAIROS turn under the allowlist handler, record the brief, and queue
/// a proposal (with `intent` as the re-runnable prompt) if anything was denied.
/// Best-effort: a failure never tears down the loop.
fn runTurn(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    deps: Deps,
    allowlist: []const []const u8,
    prompt: []const u8,
    heading: []const u8,
    intent: []const u8,
) void {
    var actx = ApprovalCtx{ .allowlist = allowlist };
    const handler = agent_runtime.ApprovalHandler{ .ctx = &actx, .prompt = kairosApprove };

    const text = session_mgmt.runKairosTurn(
        allocator,
        cwd,
        deps.cfg,
        deps.policy,
        deps.audit,
        deps.store,
        deps.mcp,
        deps.browser,
        prompt,
        handler,
    ) catch |err| {
        kairos_brief.appendBrief(allocator, cwd, "error", @errorName(err));
        return;
    };
    defer allocator.free(text);

    kairos_brief.appendBrief(allocator, cwd, heading, text);

    if (actx.denied > 0) {
        const reason = "KAIROS needs approval to complete this; run /kairos to review";
        if (kairos_brief.addProposal(allocator, cwd, intent, reason)) |id| {
            allocator.free(id);
            notifyProposals(allocator, cwd);
        } else |_| {}
    }
}

// ===========================================================================
// Allowlist approval handler
// ===========================================================================

const ApprovalCtx = struct {
    allowlist: []const []const u8,
    denied: usize = 0,
};

/// Approval handler installed for KAIROS turns. The gate only calls this for
/// tools that need approval (read-only tools are auto-allowed upstream), so the
/// decision reduces to: allowlisted -> approve, else deny (and count it so the
/// caller can queue a proposal). The handler only receives the rendered message
/// "<name> [<risk>]: <summary>", so we match the allowlist against both the tool
/// name and the summary (the latter carries shell command text like "git diff").
fn kairosApprove(ctx_ptr: *anyopaque, message: []const u8) anyerror!types.ApprovalResponse {
    const actx: *ApprovalCtx = @ptrCast(@alignCast(ctx_ptr));
    if (messageAllowed(message, actx.allowlist)) return .approve;
    actx.denied += 1;
    return .deny;
}

fn messageAllowed(message: []const u8, allowlist: []const []const u8) bool {
    const name = if (std.mem.indexOf(u8, message, " [")) |i| message[0..i] else message;
    if (kairos_policy.inAllowlist(name, allowlist)) return true;
    if (std.mem.indexOf(u8, message, "]: ")) |j| {
        const summary = message[j + 3 ..];
        if (kairos_policy.inAllowlist(summary, allowlist)) return true;
    }
    return false;
}

fn buildAllowlist(allocator: std.mem.Allocator) std.array_list.Managed([]const u8) {
    var list = std.array_list.Managed([]const u8).init(allocator);
    for (kairos_policy.DEFAULT_ALLOWLIST) |e| {
        const dup = allocator.dupe(u8, e) catch continue;
        list.append(dup) catch allocator.free(dup);
    }
    // User-extensible via env (comma-separated), e.g. ZCODE_KAIROS_ALLOWLIST="npm test,cargo check".
    if (env.getOwned(allocator, "ZCODE_KAIROS_ALLOWLIST") catch null) |raw| {
        defer allocator.free(raw);
        var it = std.mem.tokenizeScalar(u8, raw, ',');
        while (it.next()) |tok| {
            const t = std.mem.trim(u8, tok, " \t");
            if (t.len == 0) continue;
            const dup = allocator.dupe(u8, t) catch continue;
            list.append(dup) catch allocator.free(dup);
        }
    }
    return list;
}

fn freeAllowlist(allocator: std.mem.Allocator, list: *std.array_list.Managed([]const u8)) void {
    for (list.items) |e| allocator.free(e);
    list.deinit();
}

// ===========================================================================
// Self-check + pre-gate
// ===========================================================================

fn buildSelfCheckPrompt(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();
    try w.print(
        "You are KAIROS, an autonomous background agent running while the user is away from the project at {s}.\n" ++
            "Survey the project with READ-ONLY tools (e.g. git status, recent diffs, the curated backlog below) and decide if there is anything worth doing right now.\n" ++
            "Do only safe, allowlisted work autonomously. For anything that would need approval, attempt it -- it will be queued as a proposal for the user, not executed.\n" ++
            "Be conservative and brief. If nothing is worth doing, say so in one line.\n",
        .{cwd},
    );
    if (readBacklog(allocator, cwd)) |backlog| {
        defer allocator.free(backlog);
        if (backlog.len > 0) try w.print("\nCurated backlog:\n{s}\n", .{backlog});
    }
    return out.toOwnedSlice();
}

/// Cheap pre-gate: is the working tree dirty? Avoids spending a model self-check
/// when nothing in the repo changed. Uses `git -C <cwd>` so no child cwd needed.
fn gitDirty(allocator: std.mem.Allocator, cwd: []const u8) bool {
    const r = std.process.run(allocator, rt.io, .{
        .argv = &.{ "git", "-C", cwd, "status", "--porcelain" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(4 * 1024),
    }) catch return false;
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    return std.mem.trim(u8, r.stdout, " \t\r\n").len > 0;
}

fn backlogPresent(allocator: std.mem.Allocator, cwd: []const u8) bool {
    if (readBacklog(allocator, cwd)) |b| {
        defer allocator.free(b);
        return std.mem.trim(u8, b, " \t\r\n").len > 0;
    }
    return false;
}

fn readBacklog(allocator: std.mem.Allocator, cwd: []const u8) ?[]u8 {
    const dir = kairos_lock.projectDir(allocator, cwd) catch return null;
    defer allocator.free(dir);
    const path = std.fs.path.join(allocator, &.{ dir, BACKLOG_FILE }) catch return null;
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(64 * 1024)) catch null;
}

fn notifyProposals(allocator: std.mem.Allocator, cwd: []const u8) void {
    if (!os_notify.available()) return;
    const n = kairos_brief.proposalCount(allocator, cwd);
    var buf: [128]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{d} proposal(s) awaiting approval. Run /kairos to review.", .{n}) catch return;
    os_notify.notify(allocator, "KAIROS", body);
}

// ===========================================================================
// Daily spend cap (per-project usage file)
// ===========================================================================

/// Consume one model-tick against today's budget. Returns false (and does not
/// consume) when the cap is reached. Resets at local-day rollover. cap<=0 means
/// "no model work" (a hard off switch).
fn tryConsumeTick(allocator: std.mem.Allocator, cwd: []const u8, cap: i64) bool {
    if (cap <= 0) return false;
    const today = @divFloor(clock.nowSeconds(), 86400);
    var usage = loadUsage(allocator, cwd);
    if (usage.day != today) {
        usage.day = today;
        usage.ticks = 0;
    }
    if (usage.ticks >= cap) return false;
    usage.ticks += 1;
    saveUsage(allocator, cwd, usage);
    return true;
}

const Usage = struct { day: i64 = 0, ticks: i64 = 0 };

fn loadUsage(allocator: std.mem.Allocator, cwd: []const u8) Usage {
    const path = usagePath(allocator, cwd) catch return .{};
    defer allocator.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(4 * 1024)) catch return .{};
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return .{};
    defer parsed.deinit();
    if (parsed.value != .object) return .{};
    return .{
        .day = getInteger(parsed.value.object, "day") orelse 0,
        .ticks = getInteger(parsed.value.object, "ticks") orelse 0,
    };
}

fn saveUsage(allocator: std.mem.Allocator, cwd: []const u8, usage: Usage) void {
    const path = usagePath(allocator, cwd) catch return;
    defer allocator.free(path);
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    out.writer().print("{f}", .{std.json.fmt(.{ .day = usage.day, .ticks = usage.ticks }, .{})}) catch return;
    const file = std.Io.Dir.cwd().createFile(rt.io, path, .{ .truncate = true }) catch return;
    defer file.close(rt.io);
    file.writeStreamingAll(rt.io, out.items()) catch {};
}

fn usagePath(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const dir = try kairos_lock.projectDir(allocator, cwd);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, USAGE_FILE });
}

// ===========================================================================
// Per-project state file
// ===========================================================================

fn statePath(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const dir = try kairos_lock.projectDir(allocator, cwd);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, STATE_FILE });
}

fn writeState(allocator: std.mem.Allocator, cwd: []const u8, state: State) !void {
    const path = try statePath(allocator, cwd);
    defer allocator.free(path);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try out.writer().print("{f}\n", .{std.json.fmt(.{
        .pid = state.pid,
        .started_ts = state.started_ts,
    }, .{})});

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ path, clock.nowNanos() });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};
    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, out.items());
        file.sync(rt.io) catch {};
    }
    try std.Io.Dir.renameAbsolute(tmp_path, path, rt.io);
}

fn loadState(allocator: std.mem.Allocator, cwd: []const u8) !?State {
    const path = try statePath(allocator, cwd);
    defer allocator.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    const pid = getInteger(parsed.value.object, "pid") orelse return null;
    const started_ts = getInteger(parsed.value.object, "started_ts") orelse 0;
    return .{ .pid = @intCast(pid), .started_ts = started_ts };
}

fn deleteState(allocator: std.mem.Allocator, cwd: []const u8) !void {
    const path = try statePath(allocator, cwd);
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(rt.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

// ===========================================================================
// Small helpers
// ===========================================================================

fn envInt(allocator: std.mem.Allocator, name: []const u8, default: i64) i64 {
    const v = env.getOwned(allocator, name) catch return default;
    defer allocator.free(v);
    return std.fmt.parseInt(i64, std.mem.trim(u8, v, " \t\r\n"), 10) catch default;
}

fn getInteger(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |n| n,
        else => null,
    };
}

fn getpid() i32 {
    return switch (@import("builtin").os.tag) {
        .linux => std.os.linux.getpid(),
        else => std.c.getpid(),
    };
}

fn isPidRunning(pid: i32) bool {
    return std.c.kill(pid, @enumFromInt(0)) == 0;
}

const testing = std.testing;

test "messageAllowed matches tool name and summary" {
    const allow = [_][]const u8{ "git status", "zig build" };
    // Read-only tools never reach the handler, but allowlisted commands match
    // either by name or by the summary text the gate renders.
    try testing.expect(messageAllowed("git status [low]: git status -s", &allow));
    try testing.expect(messageAllowed("Bash [high]: zig build test", &allow));
    try testing.expect(!messageAllowed("Edit [high]: write src/main.zig", &allow));
}

test "envInt falls back on unset/garbage" {
    // ZCODE_KAIROS_NONEXISTENT_TEST is not set; should return the default.
    try testing.expectEqual(@as(i64, 42), envInt(testing.allocator, "ZCODE_KAIROS_NONEXISTENT_TEST", 42));
}
