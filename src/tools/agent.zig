const std = @import("std");
const types = @import("../core/types.zig");
const arg_parse = @import("arg_parse.zig");
const agent_isolation = @import("../core/agent_isolation.zig");

/// Maximum sub-agent nesting depth. Prevents recursive agent loops.
pub const MAX_DEPTH: u8 = 2;

/// Configuration for a sub-agent invocation.
pub const AgentRunConfig = struct {
    prompt: []const u8,
    agent: ?[]const u8 = null,
    model: ?[]const u8 = null,
    max_rounds: ?usize = null,
    retry_on_failure: bool = false,
    /// When true, the agent runs in a background thread and reports
    /// results via the task notification file. The parent returns
    /// immediately with a "spawned in background" message.
    run_in_background: bool = false,
    /// Per-agent isolation mode (swarm-tasks-11). When `"worktree"`, the spawn
    /// path creates a fresh git worktree and runs the agent there. Mutually
    /// exclusive with `cwd_override`. Cloud "remote" isolation is out of scope.
    isolation: ?[]const u8 = null,
    /// Absolute working directory the agent should run in (swarm-tasks-11).
    /// Mutually exclusive with `isolation`.
    cwd_override: ?[]const u8 = null,
    /// Team-addressable name for this agent, distinct from `agent` (the
    /// specialist type). Used as the registry key for SendMessage(to=name)
    /// routing (swarm-tasks-10) and the teammate binding (swarm-tasks-13).
    /// Mirrors the `name` field of the reference multiAgentInputSchema
    /// (`AgentTool.tsx:82-105`).
    name: ?[]const u8 = null,
    /// Name of the team this agent belongs to (tools-14). Threaded into the
    /// teammate binding (swarm-tasks-13).
    team_name: ?[]const u8 = null,
    /// Session mode override for the child (tools-14). Raw string; maps to the
    /// existing `AgentMode` via `core/agents.zig` parse semantics at spawn.
    mode: ?[]const u8 = null,
    /// Short (3-5 word) human-facing description of the agent's task (tools-14).
    description: ?[]const u8 = null,
};

/// Parse AgentRun tool arguments into a config.
///
/// `isolation` and `cwd` are mutually exclusive (swarm-tasks-11); supplying
/// both, an unsupported isolation value, or a non-absolute cwd is rejected via
/// `agent_isolation.classify`.
pub fn parseArgs(args: []const u8) !AgentRunConfig {
    const prompt = arg_parse.getArg(args, "prompt") orelse return error.MissingToolArg;
    const isolation = arg_parse.getArg(args, "isolation");
    const cwd_override = arg_parse.getArg(args, "cwd");
    // Validate the isolation/cwd pair up front so callers get a clean error
    // before any spawn machinery runs. The result kind is recomputed at spawn
    // time; here we only need the validation side effect.
    _ = try agent_isolation.classify(isolation, cwd_override);
    return .{
        .prompt = prompt,
        // `agent` (specialist type) and `name` (team-addressable registry key)
        // are distinct fields per the reference; do not conflate them (tools-14).
        .agent = arg_parse.getArg(args, "agent"),
        .model = arg_parse.getArg(args, "model"),
        .max_rounds = if (arg_parse.getArg(args, "max_rounds")) |v|
            std.fmt.parseInt(usize, v, 10) catch null
        else
            null,
        .retry_on_failure = if (arg_parse.getArg(args, "retry_on_failure")) |v|
            std.mem.eql(u8, v, "true")
        else
            false,
        .run_in_background = if (arg_parse.getArg(args, "run_in_background")) |v|
            std.mem.eql(u8, v, "true")
        else
            false,
        .isolation = isolation,
        .cwd_override = cwd_override,
        .name = arg_parse.getArg(args, "name"),
        .team_name = arg_parse.getArg(args, "team_name"),
        .mode = arg_parse.getArg(args, "mode"),
        .description = arg_parse.getArg(args, "description"),
    };
}

/// Run a sub-agent with the given configuration.
/// This function is called from the tool execution path in main.zig.
/// The caller provides `run_fn` which creates an isolated AgentRuntime
/// and executes the prompt, returning the final text output.
///
/// `depth` tracks nesting level. If depth >= MAX_DEPTH, the call is rejected.
/// `max_tool_rounds` is the parent's configured max rounds (used to compute default).
pub fn runSubAgent(
    allocator: std.mem.Allocator,
    config: AgentRunConfig,
    depth: u8,
    max_tool_rounds: usize,
    run_fn: *const fn (allocator: std.mem.Allocator, prompt: []const u8, model: ?[]const u8, max_rounds: usize) anyerror![]u8,
) ![]u8 {
    if (depth >= MAX_DEPTH) {
        return allocator.dupe(u8, "Error: maximum sub-agent nesting depth reached. Sub-agents cannot spawn further sub-agents beyond depth 2.");
    }

    const effective_max_rounds = config.max_rounds orelse (max_tool_rounds / 2);
    const clamped_rounds = @max(@as(usize, 1), @min(effective_max_rounds, max_tool_rounds));

    return run_fn(allocator, config.prompt, config.model, clamped_rounds);
}

const testing = std.testing;

test "parseArgs extracts prompt" {
    const config = try parseArgs("prompt=hello world");
    try testing.expectEqualStrings("hello world", config.prompt);
    try testing.expect(config.agent == null);
    try testing.expect(config.model == null);
    try testing.expect(config.max_rounds == null);
}

test "parseArgs with all fields" {
    const config = try parseArgs("prompt=do stuff,agent=verify,model=gpt-4.1,max_rounds=5");
    try testing.expectEqualStrings("do stuff", config.prompt);
    try testing.expectEqualStrings("verify", config.agent.?);
    try testing.expectEqualStrings("gpt-4.1", config.model.?);
    try testing.expectEqual(@as(usize, 5), config.max_rounds.?);
}

test "parseArgs missing prompt" {
    const result = parseArgs("model=gpt-4.1");
    try testing.expect(result == error.MissingToolArg);
}

test "parseArgs isolation and cwd together is rejected" {
    const result = parseArgs("prompt=x,isolation=worktree,cwd=/abs/path");
    try testing.expectError(agent_isolation.Error.IsolationCwdConflict, result);
}

test "parseArgs cwd override sets cwd_override" {
    const config = try parseArgs("prompt=x,cwd=/tmp/x");
    try testing.expectEqualStrings("/tmp/x", config.cwd_override.?);
    try testing.expect(config.isolation == null);
}

test "parseArgs isolation worktree sets isolation" {
    const config = try parseArgs("prompt=x,isolation=worktree");
    try testing.expectEqualStrings("worktree", config.isolation.?);
    try testing.expect(config.cwd_override == null);
}

test "parseArgs without isolation leaves fields null" {
    const config = try parseArgs("prompt=x");
    try testing.expect(config.isolation == null);
    try testing.expect(config.cwd_override == null);
}

test "parseArgs extracts multi-agent fields" {
    const config = try parseArgs("prompt=x,name=worker,team_name=alpha,mode=planning,description=fix auth");
    try testing.expectEqualStrings("x", config.prompt);
    try testing.expectEqualStrings("worker", config.name.?);
    try testing.expectEqualStrings("alpha", config.team_name.?);
    try testing.expectEqualStrings("planning", config.mode.?);
    try testing.expectEqualStrings("fix auth", config.description.?);
}

test "parseArgs leaves multi-agent fields null when omitted" {
    const config = try parseArgs("prompt=x");
    try testing.expect(config.name == null);
    try testing.expect(config.team_name == null);
    try testing.expect(config.mode == null);
    try testing.expect(config.description == null);
}

test "parseArgs does not conflate agent and name" {
    // `name` (registry key) must not populate `agent` (specialist type).
    const config = try parseArgs("prompt=x,name=worker");
    try testing.expect(config.agent == null);
    try testing.expectEqualStrings("worker", config.name.?);

    // And `agent` must not populate `name`.
    const config2 = try parseArgs("prompt=x,agent=verify");
    try testing.expectEqualStrings("verify", config2.agent.?);
    try testing.expect(config2.name == null);
}

test "parseArgs relative cwd override is rejected" {
    const result = parseArgs("prompt=x,cwd=relative/dir");
    try testing.expectError(agent_isolation.Error.CwdNotAbsolute, result);
}

test "depth guard rejects deep nesting" {
    const config = AgentRunConfig{ .prompt = "test" };
    // At MAX_DEPTH, should return error message
    const result = try runSubAgent(testing.allocator, config, MAX_DEPTH, 10, dummyRunFn);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "maximum sub-agent nesting depth") != null);
}

fn dummyRunFn(_: std.mem.Allocator, _: []const u8, _: ?[]const u8, _: usize) anyerror![]u8 {
    return error.NotImplemented;
}
