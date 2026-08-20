const std = @import("std");
const env = @import("env.zig");
const std_io = @import("std_io.zig");

/// Coordinator mode (ported from claude-code-main/src/swarm/coordinatorMode.ts).
///
/// Coordinator mode turns the top-level session into a pure orchestrator: it
/// stops doing engineering work itself and instead drives a fleet of worker
/// sub-agents (spawned with AgentRun), addresses them with SendMessage, and
/// halts them with TaskStop. It is gated entirely on the
/// CLAUDE_CODE_COORDINATOR_MODE environment variable so it never affects the
/// common single-session path.
///
/// This module is the pure decision/text layer:
///   - isCoordinatorMode()        reads the env gate
///   - coordinatorSystemPrompt()  the orchestrator persona (swaps the base
///                                system prompt)
///   - coordinatorUserContext()   the worker-tools + scratchpad block appended
///                                as user context
///   - matchSessionMode()         reconciles a resumed session's stored mode
///                                with the live env, flipping the env and
///                                returning a one-line warning when they differ
///
/// The side effects (prompt swap, user-context append, resume reconciliation)
/// live in core/system_prompt.zig, core/prompt_helpers.zig, and
/// session_cmds.zig respectively; this module stays unit-testable.
/// Environment variable that gates coordinator mode. Mirrors the reference's
/// CLAUDE_CODE_COORDINATOR_MODE.
pub const ENV_VAR: []const u8 = "CLAUDE_CODE_COORDINATOR_MODE";

/// The stored-session mode token used to persist that a session was running in
/// coordinator mode (so a later --resume can reconcile).
pub const MODE_COORDINATOR: []const u8 = "coordinator";

/// The stored-session mode token for an ordinary (non-coordinator) session.
pub const MODE_NORMAL: []const u8 = "normal";

/// Worker tools that the coordinator must NOT advertise to itself - they are
/// the internal plumbing a worker uses, not orchestration verbs. Mirrors
/// INTERNAL_WORKER_TOOLS at coordinatorMode.ts:29-34.
pub const INTERNAL_WORKER_TOOLS = [_][]const u8{
    "TaskCreate",
    "TaskUpdate",
    "TaskView",
    "TeamCreate",
};

/// True when CLAUDE_CODE_COORDINATOR_MODE is set to a truthy token.
/// Unset / empty / falsy => false (so the gate is off by default).
pub fn isCoordinatorMode() bool {
    return env.isEnvTruthy(ENV_VAR);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Force the live coordinator-mode env gate on or off. Used by the resume
/// reconciliation so a session resumed with `--resume` re-enters the same mode
/// it was running in when it was saved.
pub fn setCoordinatorEnv(on: bool) void {
    // String literals in Zig are null-terminated arrays, so this coerces to
    // the [*:0]const u8 the libc setenv/unsetenv signatures want.
    const name_z: [*:0]const u8 = "CLAUDE_CODE_COORDINATOR_MODE";
    if (on) {
        _ = setenv(name_z, "1", 1);
    } else {
        _ = unsetenv(name_z);
    }
}

/// The coordinator persona. Ported from getCoordinatorSystemPrompt
/// (coordinatorMode.ts:111). Tool names are zcode's (AgentRun / SendMessage /
/// TaskStop). No long dashes (project rule).
pub const COORDINATOR_SYSTEM_PROMPT: []const u8 =
    "You are operating in COORDINATOR MODE. You are an orchestrator, not an implementer.\n\n" ++
    "Your job is to break the user's request into independent units of work, spawn worker sub-agents to do them, keep the workers coordinated, and report progress back to the user. You do NOT edit files, run builds, or do engineering work yourself. You delegate.\n\n" ++
    "Important: every message you send is to the user. The workers cannot see what you say to the user, and the user cannot see what the workers say to you. To talk to a worker you must use SendMessage; to read a worker's reply you must wait for it to be delivered back to you. Keep the user informed in your own messages.\n\n" ++
    "How to operate:\n" ++
    " - Use AgentRun to spawn a worker for each independent unit of work. Give each worker a short, addressable name and a clear, self-contained brief.\n" ++
    " - Use SendMessage(to=<name>) to address a specific worker, or to=* to broadcast to all workers. Use it to assign follow-up work, answer a worker's question, or request a graceful shutdown.\n" ++
    " - Use TaskStop to halt a worker that has finished or gone off track.\n" ++
    " - Watch for dependencies between units of work: do not let two workers double-claim the same task, and respect ordering when one unit blocks another.\n" ++
    " - When all the work is done, summarize the outcome for the user.\n\n" ++
    "Do not attempt to do the engineering work in your own turn. If you are tempted to read or edit code directly, spawn a worker instead.\n";

/// Return the coordinator persona. A function (not just the const) so callers
/// mirror the reference's getCoordinatorSystemPrompt() shape and so a future
/// version can interpolate workspace details.
pub fn coordinatorSystemPrompt() []const u8 {
    return COORDINATOR_SYSTEM_PROMPT;
}

/// Build the worker-tools + scratchpad user-context block appended to the
/// coordinator's context. Ported from getCoordinatorUserContext
/// (coordinatorMode.ts:80). The worker-tools list is the caller-supplied
/// async-agent allowed-tools set with the INTERNAL_WORKER_TOOLS filtered out.
/// Caller owns the returned slice.
pub fn coordinatorUserContext(
    allocator: std.mem.Allocator,
    worker_tools: []const []const u8,
    scratchpad_dir: []const u8,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll("# Coordinator context\n\n");
    try w.writeAll("Workers you spawn have access to the following tools:\n");

    var wrote_any = false;
    for (worker_tools) |tool| {
        if (isInternalWorkerTool(tool)) continue;
        try w.print(" - {s}\n", .{tool});
        wrote_any = true;
    }
    if (!wrote_any) {
        try w.writeAll(" (none)\n");
    }

    try w.print(
        "\nShared scratchpad directory: {s}\n" ++
            "Workers can read and write files under this directory to share intermediate state. Point a worker at a specific file there when you want it to pick up another worker's output.\n",
        .{scratchpad_dir},
    );

    return out.toOwnedSlice();
}

/// True when the tool name is one of the internal worker tools that the
/// coordinator should not advertise. Case-sensitive (tool names are canonical).
pub fn isInternalWorkerTool(name: []const u8) bool {
    for (INTERNAL_WORKER_TOOLS) |internal| {
        if (std.mem.eql(u8, name, internal)) return true;
    }
    return false;
}

/// Reconcile a resumed session's stored mode with the live env gate.
/// Ported from matchSessionMode (coordinatorMode.ts:49).
///
/// `stored` is the mode token persisted in the session record (MODE_COORDINATOR
/// or MODE_NORMAL / unknown). If the stored mode differs from the live env gate
/// this flips the env to match the stored session and returns a one-line
/// warning the caller surfaces to the user. When the modes already agree it
/// returns null (no change, no warning).
///
/// The returned warning is a static string slice (no allocation, no free).
pub fn matchSessionMode(stored: []const u8) ?[]const u8 {
    const stored_is_coordinator = std.mem.eql(u8, stored, MODE_COORDINATOR);
    const live_is_coordinator = isCoordinatorMode();

    if (stored_is_coordinator == live_is_coordinator) return null;

    if (stored_is_coordinator) {
        setCoordinatorEnv(true);
        return "Entered coordinator mode to match the resumed session.";
    } else {
        setCoordinatorEnv(false);
        return "Left coordinator mode to match the resumed session.";
    }
}

/// The mode token to persist for the current live session.
pub fn currentSessionMode() []const u8 {
    return if (isCoordinatorMode()) MODE_COORDINATOR else MODE_NORMAL;
}

const testing = std.testing;

// Tests mutate the process env gate; serialize through a single guard token so
// they cannot interleave with each other under a parallel test runner. The
// custom runner in tools/test_runner.zig runs tests sequentially, but keep the
// save/restore discipline regardless.
fn saveEnv() bool {
    return isCoordinatorMode();
}
fn restoreEnv(was_on: bool) void {
    setCoordinatorEnv(was_on);
}

test "isCoordinatorMode is false when the env var is unset" {
    const saved = saveEnv();
    defer restoreEnv(saved);
    setCoordinatorEnv(false);
    try testing.expect(!isCoordinatorMode());
}

test "isCoordinatorMode is true when the env var is set truthy" {
    const saved = saveEnv();
    defer restoreEnv(saved);
    setCoordinatorEnv(true);
    try testing.expect(isCoordinatorMode());
}

test "coordinatorSystemPrompt contains the every-message-is-to-the-user line" {
    const prompt = coordinatorSystemPrompt();
    try testing.expect(std.mem.indexOf(u8, prompt, "every message you send is to the user") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "COORDINATOR MODE") != null);
}

test "coordinatorSystemPrompt has no long dashes" {
    const prompt = coordinatorSystemPrompt();
    try testing.expect(std.mem.indexOf(u8, prompt, "\u{2014}") == null); // em dash
    try testing.expect(std.mem.indexOf(u8, prompt, "\u{2013}") == null); // en dash
}

test "matchSessionMode flips into coordinator mode and warns" {
    const saved = saveEnv();
    defer restoreEnv(saved);
    setCoordinatorEnv(false);

    const warning = matchSessionMode(MODE_COORDINATOR);
    try testing.expect(warning != null);
    try testing.expect(std.mem.indexOf(u8, warning.?, "Entered coordinator mode") != null);
    try testing.expect(isCoordinatorMode());
}

test "matchSessionMode flips out of coordinator mode and warns" {
    const saved = saveEnv();
    defer restoreEnv(saved);
    setCoordinatorEnv(true);

    const warning = matchSessionMode(MODE_NORMAL);
    try testing.expect(warning != null);
    try testing.expect(std.mem.indexOf(u8, warning.?, "Left coordinator mode") != null);
    try testing.expect(!isCoordinatorMode());
}

test "matchSessionMode returns null when modes already agree" {
    const saved = saveEnv();
    defer restoreEnv(saved);

    setCoordinatorEnv(true);
    try testing.expect(matchSessionMode(MODE_COORDINATOR) == null);
    try testing.expect(isCoordinatorMode());

    setCoordinatorEnv(false);
    try testing.expect(matchSessionMode(MODE_NORMAL) == null);
    try testing.expect(!isCoordinatorMode());
}

test "coordinatorUserContext lists worker tools and filters internal ones" {
    const saved = saveEnv();
    defer restoreEnv(saved);

    const tools = [_][]const u8{ "AgentRun", "Read", "TaskCreate", "Bash" };
    const ctx = try coordinatorUserContext(testing.allocator, &tools, "/tmp/scratch");
    defer testing.allocator.free(ctx);

    try testing.expect(std.mem.indexOf(u8, ctx, "AgentRun") != null);
    try testing.expect(std.mem.indexOf(u8, ctx, "Read") != null);
    try testing.expect(std.mem.indexOf(u8, ctx, "Bash") != null);
    // TaskCreate is an internal worker tool and must be filtered out.
    try testing.expect(std.mem.indexOf(u8, ctx, "TaskCreate") == null);
    try testing.expect(std.mem.indexOf(u8, ctx, "/tmp/scratch") != null);
}

test "isInternalWorkerTool classifies the internal set" {
    try testing.expect(isInternalWorkerTool("TaskCreate"));
    try testing.expect(isInternalWorkerTool("TeamCreate"));
    try testing.expect(!isInternalWorkerTool("AgentRun"));
    try testing.expect(!isInternalWorkerTool("SendMessage"));
}

test "currentSessionMode reflects the live env gate" {
    const saved = saveEnv();
    defer restoreEnv(saved);

    setCoordinatorEnv(true);
    try testing.expectEqualStrings(MODE_COORDINATOR, currentSessionMode());

    setCoordinatorEnv(false);
    try testing.expectEqualStrings(MODE_NORMAL, currentSessionMode());
}
