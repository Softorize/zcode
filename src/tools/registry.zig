const std = @import("std");
const tool_dispatch = @import("tool_dispatch.zig");
const tool_schemas = @import("tool_schemas.zig");
const arg_parse = @import("arg_parse.zig");
const shell_tool = @import("shell.zig");
const bash_security = @import("bash_security.zig");

pub const ToolExecutionRequest = tool_dispatch.ToolExecutionRequest;

/// Pure dispatch entry point. The single tool gate
/// (`agent_tools.executeToolCall`) calls this after every gate passes.
pub const dispatch = tool_dispatch.dispatch;

pub const builtinSchemas = tool_schemas.builtinSchemas;
pub const collectSchemas = tool_schemas.collectSchemas;
pub const freeSchemas = tool_schemas.freeSchemas;
pub const maxResultSizeForTool = tool_schemas.maxResultSizeForTool;
pub const getArg = arg_parse.getArg;

/// The dispatch-adjacent execution gates that sit just before a tool
/// actually runs:
///   - empty-workspace exploration guard
///   - shell command structural validation (empty / null-byte / over-long)
///   - shell interactive / redirect-tool reroutes (skipped under
///     danger-full-access)
///
/// Returns a synthetic, model-readable block/reroute output when a gate
/// trips, or `null` to proceed to `dispatch`. Policy classification,
/// approval, sandbox, permission rules, plugins and hooks all live
/// upstream in the single tool gate (`agent_tools.executeToolCall`); this
/// is deliberately the dispatch-adjacent slice only, so the whole gate
/// sequence reads top-to-bottom in one place and `classifyTool` runs once.
///
/// Empty-workspace rationale: when the workspace has no source files,
/// inspection-only tools waste rounds and trip the empty-response stall
/// path. The dynamic system policy ASKS the model to skip them; some
/// models ignore the ask, so this ENFORCES it at dispatch time, steering
/// toward Write / WebFetch / AskUserQuestion.
pub fn applyExecutionGates(allocator: std.mem.Allocator, req: ToolExecutionRequest) !?[]u8 {
    if (shouldBlockOnEmptyWorkspace(req)) {
        return try renderEmptyWorkspaceBlock(allocator, req.name);
    }

    if (isShellToolName(req.name)) {
        const command = arg_parse.getArg(req.args, "command") orelse req.args;
        // validateCommandInput blocks empty / null-byte / over-long
        // commands; those are structural problems that SHOULD fire even
        // under danger-full-access (you never meant to run an empty
        // string), so we do NOT bypass this one.
        if (bash_security.validateCommandInput(command)) |reason| {
            return try shell_tool.formatInvalidCommand(allocator, command, reason);
        }

        // danger-full-access is the explicit user opt-in to unrestricted
        // operation, so skip the redirect-tool and interactive reroutes.
        // Mirrors the bypass in shell.zig::run so the agent can use
        // head/grep/find/ssh/etc. directly under the dangerous profile.
        if (!std.mem.eql(u8, req.sandbox_profile, "danger-full-access")) {
            const analysis = bash_security.analyzeCommand(command);
            switch (analysis.kind) {
                .interactive => return try shell_tool.formatInteractiveReroute(allocator, command, analysis.reason),
                .redirect_tool => return try shell_tool.formatToolRedirect(allocator, command, analysis.reason),
                else => {},
            }
        }
    }

    return null;
}

fn isShellToolName(name: []const u8) bool {
    return std.mem.eql(u8, name, "shell") or std.mem.eql(u8, name, "Bash") or std.mem.eql(u8, name, "bash");
}

/// Inspection-only tool names that produce no useful signal when the
/// workspace has no source files. Matches both snake_case primaries
/// and Claude-Code-style aliases.
fn isExplorationToolName(name: []const u8) bool {
    const names = [_][]const u8{
        "Grep",       "grep",
        "Glob",       "glob",
        "Read",       "read",
        "file_read",  "ListDir",
        "list_dir",   "Stat",
        "stat",       "GitStatus",
        "git_status", "GitDiff",
        "git_diff",   "GitLog",
        "git_log",
    };
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// True when the shell command is a file-discovery shape that adds
/// nothing on an empty workspace (ls/find/cat/grep/tree/stat/wc/du/
/// file/head/tail). The check is whitespace-tolerant prefix match
/// against the first command token.
fn isExplorationShellCommand(command: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, command, " \t");
    const prefixes = [_][]const u8{
        "ls ",    "ls\n",   "ls\t",   "ls",
        "find ",  "find\n", "find\t", "cat ",
        "cat\n",  "cat\t",  "grep ",  "grep\n",
        "grep\t", "rg ",    "rg\n",   "rg\t",
        "tree ",  "tree\n", "tree\t", "tree",
        "stat ",  "stat\n", "stat\t", "wc ",
        "wc\n",   "wc\t",   "du ",    "du\n",
        "du\t",   "file ",  "file\n", "file\t",
        "head ",  "head\n", "head\t", "tail ",
        "tail\n", "tail\t",
    };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, trimmed, p)) {
            // Bare "ls" / "tree" with no args also counts.
            const tail = trimmed[p.len - 1 ..];
            _ = tail;
            return true;
        }
    }
    if (std.mem.eql(u8, trimmed, "ls") or std.mem.eql(u8, trimmed, "tree")) return true;
    return false;
}

fn shouldBlockOnEmptyWorkspace(req: ToolExecutionRequest) bool {
    const prompt_helpers = @import("../core/prompt_helpers.zig");
    if (!prompt_helpers.workspaceIsEffectivelyEmpty(req.cwd)) return false;
    if (isExplorationToolName(req.name)) return true;
    if (isShellToolName(req.name)) {
        const command = arg_parse.getArg(req.args, "command") orelse req.args;
        return isExplorationShellCommand(command);
    }
    return false;
}

fn renderEmptyWorkspaceBlock(allocator: std.mem.Allocator, tool_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "[BLOCKED] tool={s} cannot run: the workspace has no source files. " ++
            "Exploration tools (Grep / Glob / Read / ListDir / Stat / Git* / ls / find / cat / tree) " ++
            "are blocked at dispatch on an empty workspace because they cannot return useful results " ++
            "and waste tool rounds.\n\n" ++
            "Next step -- choose one and emit a different tool_call:\n" ++
            "  (a) Write -- create the first source file (manifest + entry point) NOW.\n" ++
            "  (b) WebFetch / WebSearch -- read the docs for any external API named in the prompt.\n" ++
            "  (c) AskUserQuestion ONCE -- only if a required design choice is genuinely missing.\n" ++
            "Do NOT call another exploration tool on this turn.",
        .{tool_name},
    );
}

// Force inclusion of sub-modules for the test runner.
comptime {
    _ = tool_dispatch;
    _ = tool_schemas;
    _ = arg_parse;
}

const testing = std.testing;

test "parse key value args" {
    try testing.expectEqualStrings("src/main.zig", getArg("path=src/main.zig;append=false", "path").?);
    try testing.expectEqualStrings("[\"Approve\",\"Discuss\"]", getArg("question=\"Continue?\",choices=[\"Approve\",\"Discuss\"]", "choices").?);
    try testing.expectEqualStrings("README.md", getArg("\"path\":\"README.md\", \"max_bytes\":1024", "path").?);
    try testing.expect(getArg("x=1", "missing") == null);
}

test "isExplorationToolName covers both snake and Pascal names" {
    try testing.expect(isExplorationToolName("Grep"));
    try testing.expect(isExplorationToolName("Glob"));
    try testing.expect(isExplorationToolName("Read"));
    try testing.expect(isExplorationToolName("file_read"));
    try testing.expect(isExplorationToolName("GitStatus"));
    try testing.expect(isExplorationToolName("git_status"));
    try testing.expect(isExplorationToolName("ListDir"));
    try testing.expect(!isExplorationToolName("Write"));
    try testing.expect(!isExplorationToolName("WebFetch"));
    try testing.expect(!isExplorationToolName("Bash"));
}

test "isExplorationShellCommand catches file-discovery shapes" {
    try testing.expect(isExplorationShellCommand("ls -la"));
    try testing.expect(isExplorationShellCommand("ls"));
    try testing.expect(isExplorationShellCommand("find . -name '*.zig'"));
    try testing.expect(isExplorationShellCommand("cat README.md"));
    try testing.expect(isExplorationShellCommand("tree"));
    try testing.expect(isExplorationShellCommand("  grep -r foo ."));
    try testing.expect(!isExplorationShellCommand("mkdir -p src"));
    try testing.expect(!isExplorationShellCommand("mix new myapp"));
    try testing.expect(!isExplorationShellCommand("npm init -y"));
    try testing.expect(!isExplorationShellCommand("git init"));
}

test "renderEmptyWorkspaceBlock surfaces the tool name and three next steps" {
    const allocator = testing.allocator;
    const out = try renderEmptyWorkspaceBlock(allocator, "Grep");
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "tool=Grep cannot run") != null);
    try testing.expect(std.mem.indexOf(u8, out, "(a) Write") != null);
    try testing.expect(std.mem.indexOf(u8, out, "(b) WebFetch") != null);
    try testing.expect(std.mem.indexOf(u8, out, "(c) AskUserQuestion") != null);
}
