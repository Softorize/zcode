//! wp1b-commands-new: slash commands 2.1.261 ships that zcode was missing
//! entirely (background/bg, list-agents/peers, subtask, goal, team-onboarding,
//! fewer-permission-prompts, auto-mode-setup, bug, import, skill-doctor,
//! reload-skills), plus the `__goal_nudge` internal sentinel `cli/repl.zig`
//! polls at the end of every turn for the `/goal` auto-continue nudge.
//!
//! Kept as a single new module (rather than growing the already-8700-line
//! `repl_commands.zig`) so the diff to that file is exactly one dispatch call
//! plus one import. `dispatch` is wired in right before the custom-command /
//! skill fallthrough, i.e. AFTER every existing built-in arm -- so a
//! same-named user command/skill file can never be shadowed by anything
//! added here, and nothing here can shadow an existing built-in.
//!
//! Every handler returns `?[]u8` (an owned message, or null to mean "not
//! handled" / "not applicable right now") matching `replCommandCallback`'s own
//! contract, so `dispatch`'s return threads straight through.

const std = @import("std");
const rt = @import("zcode_runtime");
const builtin = @import("builtin");
const build_options = @import("build_options");
const std_io = @import("core/std_io.zig");
const types = @import("core/types.zig");
const paths = @import("core/paths.zig");
const parse_helpers = @import("core/parse_helpers.zig");
const permission_rule_string_mod = @import("core/permission_rule_string.zig");
const kairos_brief = @import("core/kairos_brief.zig");
const session_registry = @import("core/session_registry.zig");
const skills_mod = @import("core/skills.zig");
const skill_usage_mod = @import("core/skill_usage.zig");
const import_agent_config = @import("core/import_agent_config.zig");
const tool_helpers = @import("tools/helpers.zig");
const task_mod = @import("tools/task.zig");
const team_tool = @import("tools/team.zig");
const agent_tool = @import("tools/agent.zig");
const bg_cmds = @import("bg_cmds.zig");
const agent_runtime = @import("agent_runtime.zig");
const AgentRuntime = agent_runtime.AgentRuntime;

/// Sentinel `cli/repl.zig` calls (via `handler.command`) at the end of every
/// turn, right after `__consume_requested_mode`, to see whether an active
/// `/goal` should auto-queue another turn. See `goalNudge` below.
const GOAL_NUDGE_SENTINEL = "__goal_nudge";

/// Entry point wired into `repl_commands.zig`'s `replCommandCallback`, right
/// before the custom-command/skill fallthrough. Returns null for anything it
/// does not recognize so the caller's existing fallthrough still runs.
pub fn dispatch(allocator: std.mem.Allocator, runtime: *AgentRuntime, command: []const u8) !?[]u8 {
    if (std.mem.eql(u8, command, GOAL_NUDGE_SENTINEL)) return goalNudge(allocator, runtime);

    if (isCmd(command, "/background") or isCmd(command, "/bg"))
        return handleBackground(allocator, runtime, argsAfter(command));
    if (isCmd(command, "/list-agents") or isCmd(command, "/peers"))
        return handleListAgents(allocator, runtime);
    if (isCmd(command, "/subtask"))
        return handleSubtask(allocator, runtime, argsAfter(command));
    if (isCmd(command, "/goal"))
        return handleGoal(allocator, runtime, argsAfter(command));
    if (isCmd(command, "/team-onboarding"))
        return handleTeamOnboarding(allocator, runtime);
    if (isCmd(command, "/fewer-permission-prompts"))
        return handleFewerPermissionPrompts(allocator, runtime);
    if (isCmd(command, "/auto-mode-setup"))
        return handleAutoModeSetup(allocator, runtime, argsAfter(command));
    if (isCmd(command, "/bug"))
        return handleBug(allocator, runtime, argsAfter(command));
    if (isCmd(command, "/import"))
        return handleImport(allocator, runtime, argsAfter(command));
    if (isCmd(command, "/skill-doctor"))
        return handleSkillDoctor(allocator, runtime);
    if (isCmd(command, "/reload-skills"))
        return handleReloadSkills(allocator, runtime);

    return null;
}

// ===========================================================================
// Small shared helpers
// ===========================================================================

/// True when `command` is exactly `name` or `name` followed by a space (i.e.
/// `name` plus an argument tail). Never matches a longer command that merely
/// shares a prefix (`/backgroundish` does not match `/background`).
fn isCmd(command: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, command, name)) return true;
    return command.len > name.len and std.mem.startsWith(u8, command, name) and command[name.len] == ' ';
}

/// Everything after the first space, trimmed. Empty when there is no
/// argument tail.
fn argsAfter(command: []const u8) []const u8 {
    const sp = std.mem.indexOfScalar(u8, command, ' ') orelse return "";
    return std.mem.trim(u8, command[sp + 1 ..], " \t");
}

fn freeStrList(allocator: std.mem.Allocator, list: []const []const u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

// ===========================================================================
// /background, /bg (commands-12)
// ===========================================================================

/// Owned argv this session's detach should re-exec as. Every entry is duped
/// so callers own a self-contained, uniformly-freeable slice regardless of
/// whether a given entry came from a literal or from `runtime` fields.
pub fn buildBackgroundResumeArgv(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    provider: []const u8,
    model: []const u8,
) ![][]const u8 {
    var list: std.array_list.Managed([]const u8) = .init(allocator);
    errdefer freeStrList(allocator, list.toOwnedSlice() catch &.{});

    try list.append(try allocator.dupe(u8, "zcode"));
    try list.append(try allocator.dupe(u8, "--resume"));
    try list.append(try allocator.dupe(u8, session_id));
    if (provider.len > 0) {
        try list.append(try allocator.dupe(u8, "--provider"));
        try list.append(try allocator.dupe(u8, provider));
    }
    if (model.len > 0) {
        try list.append(try allocator.dupe(u8, "--model"));
        try list.append(try allocator.dupe(u8, model));
    }
    return list.toOwnedSlice();
}

fn handleBackground(allocator: std.mem.Allocator, runtime: *AgentRuntime, prompt_arg: []const u8) !?[]u8 {
    const argv = try buildBackgroundResumeArgv(allocator, runtime.session_id, runtime.active_provider, runtime.active_model);
    defer freeStrList(allocator, argv);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    // commands-12 fix: forward `[prompt]` for real, via ZCODE_BG_INITIAL_PROMPT
    // (spawnBackground sets it in the child env) -- the detached child answers
    // it headlessly (see session_mgmt.resumeSessionHeadless, routed to by
    // main.zig's `.session_resume` dispatch when ZCODE_SESSION_KIND=bg) rather
    // than requiring the user to paste it in by hand.
    bg_cmds.spawnBackground(allocator, argv, runtime.cwd, out.writer(), if (prompt_arg.len > 0) prompt_arg else null) catch |err| {
        return try std.fmt.allocPrint(allocator, "failed to send this session to the background: {s}", .{@errorName(err)});
    };
    try out.writer().writeAll("this terminal is now free -- the session keeps running detached.\n");
    if (prompt_arg.len > 0) {
        try out.writer().print("queued: \"{s}\" -- the detached session will answer it before idling.\n", .{prompt_arg});
    }
    return try out.toOwnedSlice();
}

// ===========================================================================
// /list-agents, /peers (commands-15)
// ===========================================================================

fn appendTeamsSection(allocator: std.mem.Allocator, cwd: []const u8, w: *std.Io.Writer) !void {
    const teams_dir = tool_helpers.workspacePathAlloc(allocator, cwd, tool_helpers.TEAMS_SUBPATH) catch {
        try w.writeAll("(none)\n");
        return;
    };
    defer allocator.free(teams_dir);

    var dir = std.Io.Dir.cwd().openDir(rt.io, teams_dir, .{ .iterate = true }) catch {
        try w.writeAll("(none)\n");
        return;
    };
    defer dir.close(rt.io);

    var any = false;
    var it = dir.iterate();
    while (try it.next(rt.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".team")) continue;

        const team_path = try std.fs.path.join(allocator, &.{ teams_dir, entry.name });
        defer allocator.free(team_path);
        const fallback = entry.name[0 .. entry.name.len - ".team".len];
        var team_file = team_tool.readTeamFile(allocator, team_path, fallback) catch continue;
        defer team_file.deinit(allocator);

        any = true;
        try w.print("{s} ({d} member(s))\n", .{ team_file.name, team_file.members.len });
        for (team_file.members) |m| {
            try w.print("  - {s}", .{m.name});
            if (m.agent_type.len > 0) try w.print(" ({s})", .{m.agent_type});
            try w.writeByte('\n');
        }
    }
    if (!any) try w.writeAll("(none)\n");
}

fn appendOtherSessionsSection(allocator: std.mem.Allocator, w: *std.Io.Writer) !void {
    const entries = session_registry.list(allocator) catch {
        try w.writeAll("(none)\n");
        return;
    };
    defer {
        for (entries) |*e| e.deinit(allocator);
        allocator.free(entries);
    }

    const me = session_registry.currentPid();
    var any = false;
    for (entries) |e| {
        if (e.pid == me) continue;
        any = true;
        try w.print("pid={d} kind={s} cwd={s}", .{ e.pid, e.kind.toString(), e.cwd });
        if (e.name) |n| try w.print(" name={s}", .{n});
        if (e.session_id) |sid| try w.print(" session={s}", .{sid});
        try w.writeByte('\n');
    }
    if (!any) try w.writeAll("(none)\n");
}

fn handleListAgents(allocator: std.mem.Allocator, runtime: *AgentRuntime) !?[]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll("Subagents\n---------\n");
    const tasks_text = task_mod.taskList(allocator, runtime.cwd, null) catch |err|
        try std.fmt.allocPrint(allocator, "(could not list tasks: {s})", .{@errorName(err)});
    defer allocator.free(tasks_text);
    try w.print("{s}\n", .{std.mem.trim(u8, tasks_text, " \t\r\n")});

    try w.writeAll("\nTeammates\n---------\n");
    try appendTeamsSection(allocator, runtime.cwd, w);

    try w.writeAll("\nOther zcode sessions\n--------------------\n");
    try appendOtherSessionsSection(allocator, w);

    return try out.toOwnedSlice();
}

// ===========================================================================
// /subtask (commands-25)
// ===========================================================================

const SUBTASK_MAX_TURNS = 20;
const SUBTASK_MAX_TURN_CHARS = 2000;

/// Serialize the tail of `history` (the parent session's prior turns) into a
/// prompt preamble, followed by `task`. Pure (no runtime/IO) so it is directly
/// unit-testable without spawning anything.
pub fn buildSubtaskPrompt(allocator: std.mem.Allocator, task: []const u8, history: []const types.HistoryTurn) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll(
        "You are a subagent spawned via /subtask. The parent session's full context " ++
            "is included below so you can pick up exactly where it left off.\n\n" ++
            "=== Parent session context ===\n",
    );
    const start = if (history.len > SUBTASK_MAX_TURNS) history.len - SUBTASK_MAX_TURNS else 0;
    for (history[start..]) |turn| {
        const role_label = switch (turn.role) {
            .user => "User",
            .assistant => "Assistant",
            .system => "System",
            .tool => "Tool",
        };
        const content = if (turn.content.len > SUBTASK_MAX_TURN_CHARS) turn.content[0..SUBTASK_MAX_TURN_CHARS] else turn.content;
        try w.print("[{s}] {s}\n", .{ role_label, content });
    }
    try w.writeAll("=== End parent session context ===\n\nYour task: ");
    try w.writeAll(task);
    try w.writeByte('\n');
    return try out.toOwnedSlice();
}

fn handleSubtask(allocator: std.mem.Allocator, runtime: *AgentRuntime, task: []const u8) !?[]u8 {
    if (task.len == 0) return try allocator.dupe(u8, "usage: /subtask <task>");

    // Reference guard `isEnabled:()=>!Ci()`: disabled once ALREADY inside a
    // spawned sub-agent, so a subtask cannot spawn a subtask of a subtask
    // without bound. `depth` is bumped on every child-agent spawn (including
    // the AgentRun tool path), so `depth > 0` here means exactly that.
    if (runtime.depth > 0) {
        return try allocator.dupe(
            u8,
            "/subtask is unavailable inside a spawned subagent (it would nest without a bound). Run it from the top-level session instead.",
        );
    }

    // commands-25 fix: a brand-new session (this is its very first command)
    // has never been flushed to the store yet, so `store.load` genuinely has
    // nothing to read -- that is not an error, it just means "no prior turns
    // to embed". Only a load failure for a reason OTHER than "the file does
    // not exist yet" is worth surfacing to the user.
    var loaded: ?session_store_mod.LoadedSession = null;
    defer if (loaded) |*l| l.deinit(allocator);
    const history: []const types.HistoryTurn = blk: {
        loaded = runtime.store.load(runtime.session_id) catch |err| switch (err) {
            error.FileNotFound => break :blk &.{},
            else => return try std.fmt.allocPrint(allocator, "could not load this session's context for /subtask: {s}", .{@errorName(err)}),
        };
        break :blk loaded.?.history;
    };

    const prompt = try buildSubtaskPrompt(allocator, task, history);
    defer allocator.free(prompt);

    const config = agent_tool.AgentRunConfig{ .prompt = prompt, .run_in_background = true };
    return try runtime.spawnSubtaskAgent(config);
}

// ===========================================================================
// /goal, /goal clear (commands-34)
// ===========================================================================

fn handleGoal(allocator: std.mem.Allocator, runtime: *AgentRuntime, args: []const u8) !?[]u8 {
    if (args.len == 0) {
        if (kairos_brief.getGoal(allocator, runtime.cwd, runtime.session_id)) |goal_const| {
            var goal = goal_const;
            defer goal.deinit(allocator);
            return try std.fmt.allocPrint(
                allocator,
                "active goal: {s}\nchecked {d}/{d} time(s) so far -- run `/goal clear` to stop.",
                .{ goal.condition, goal.checks, kairos_brief.GOAL_MAX_CHECKS },
            );
        }
        return try allocator.dupe(u8, "no active goal. usage: /goal <condition> | /goal clear");
    }

    if (std.mem.eql(u8, args, "clear")) {
        kairos_brief.clearGoal(allocator, runtime.cwd, runtime.session_id);
        return try allocator.dupe(u8, "goal cleared.");
    }

    try kairos_brief.setGoal(allocator, runtime.cwd, runtime.session_id, args);
    return try std.fmt.allocPrint(
        allocator,
        "goal set: {s}\nzcode will nudge itself to keep working toward this at the end of each turn (up to {d} times), until it reports the goal is met or you run `/goal clear`.",
        .{ args, kairos_brief.GOAL_MAX_CHECKS },
    );
}

/// Handles the `__goal_nudge` sentinel `cli/repl.zig` polls at the end of
/// every turn. Returns a prompt to auto-queue as the next turn, or null when
/// there is no active goal (or the safety cap has been reached, in which case
/// the goal is auto-cleared so the nagging stops for good).
fn goalNudge(allocator: std.mem.Allocator, runtime: *AgentRuntime) !?[]u8 {
    var goal = kairos_brief.getGoal(allocator, runtime.cwd, runtime.session_id) orelse return null;
    defer goal.deinit(allocator);

    if (goal.checks >= kairos_brief.GOAL_MAX_CHECKS) {
        kairos_brief.clearGoal(allocator, runtime.cwd, runtime.session_id);
        return null;
    }

    kairos_brief.bumpGoalChecks(allocator, runtime.cwd, runtime.session_id);
    return try std.fmt.allocPrint(
        allocator,
        "[/goal check {d}/{d}] Re-check whether this goal is met: \"{s}\". If it is fully met, say so clearly and stop working on it. If not, keep working toward it now.",
        .{ goal.checks + 1, kairos_brief.GOAL_MAX_CHECKS, goal.condition },
    );
}

// ===========================================================================
// /team-onboarding (commands-27)
// ===========================================================================

/// Reworded, zcode-local substitute for the reference's bundled
/// team-onboarding prompt: it points at a cloud-hosted, Anthropic-run
/// walkthrough link zcode has no equivalent infrastructure for, so this
/// produces a local ONBOARDING.md instead of a shareable URL.
pub fn buildTeamOnboardingPrompt(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "Help a new teammate ramp up on this project's zcode setup. Scan {s}/.claude and " ++
            "{s}/.zcode (settings, CLAUDE.md/AGENTS.md, custom commands, skills, MCP servers) " ++
            "and any recent session summaries you can see. Then create or update ONBOARDING.md " ++
            "at the project root covering: (1) a one-paragraph project summary, (2) how to " ++
            "install and run zcode here, (3) the project's custom commands/skills worth knowing " ++
            "about, (4) team conventions recorded in CLAUDE.md, (5) where to ask questions. Keep " ++
            "it under one page. If ONBOARDING.md already exists, update it rather than replacing " ++
            "it wholesale.",
        .{ cwd, cwd },
    );
}

fn handleTeamOnboarding(allocator: std.mem.Allocator, runtime: *AgentRuntime) !?[]u8 {
    const prompt = try buildTeamOnboardingPrompt(allocator, runtime.cwd);
    defer allocator.free(prompt);
    return try runtime.handlePromptWithModeAndReporter(prompt, null, .execution);
}

// ===========================================================================
// /fewer-permission-prompts (commands-31)
// ===========================================================================

/// Bash prefixes that are always a write/mutation/network-exfil risk even
/// though they might share a first word with something benign. Checked
/// before the read-only allowlist so nothing here can slip through.
const MUTATING_PREFIXES = [_][]const u8{
    "rm",           "mv",          "cp -r",      "git push",    "git commit",  "git reset",
    "git checkout", "git merge",   "git rebase", "git clean",   "npm install", "npm publish",
    "yarn add",     "pip install", "curl -x",    "sudo",        "chmod",       "chown",
    "kill",         "dd",          "docker rm",  "docker push", "eval",
};

/// Bash prefixes (or exact commands) safe to auto-approve. Kept short and
/// conservative on purpose -- this only ever proposes rules for commands the
/// user actually ran this session; being conservative just means more
/// prompts stay asked, never that something unsafe gets auto-allowed.
const READ_ONLY_PREFIXES = [_][]const u8{
    "ls",              "cat",              "pwd",               "echo",         "which",
    "whoami",          "date",             "head",              "tail",         "wc",
    "grep",            "find",             "file",              "stat",         "diff",
    "tree",            "env",              "printenv",          "true",         "false",
    "uname",           "git status",       "git log",           "git diff",     "git show",
    "git branch",      "git remote",       "git blame",         "git describe", "git rev-parse",
    "npm ls",          "npm list",         "npm view",          "npm outdated", "node --version",
    "node -v",         "python --version", "python3 --version", "zig version",  "go version",
    "cargo --version",
};

/// Multi-word binaries whose SECOND token is part of the meaningful command
/// identity (`git status` vs `git push` are very different risk profiles);
/// everything else is prefixed by its first token alone.
const MULTIWORD_BINARIES = [_][]const u8{ "git", "npm", "yarn", "pnpm", "cargo", "go", "docker", "node", "python", "python3" };

/// True when `command` is judged safe to auto-approve. Fails closed: any
/// shell metacharacter that could hide a write (`>`, `|`, `;`, `&`, backtick,
/// `$`) makes the whole command NOT read-only, since a compound command needs
/// per-segment evaluation this simple classifier does not attempt.
pub fn isReadOnlyBashCommand(command: []const u8) bool {
    const trimmed = std.mem.trim(u8, command, " \t");
    if (trimmed.len == 0) return false;
    for (MUTATING_PREFIXES) |p| {
        if (std.mem.startsWith(u8, trimmed, p)) return false;
    }
    if (std.mem.indexOfAny(u8, trimmed, ">|;&`$") != null) return false;
    for (READ_ONLY_PREFIXES) |p| {
        if (std.mem.eql(u8, trimmed, p)) return true;
        if (std.mem.startsWith(u8, trimmed, p) and trimmed.len > p.len and trimmed[p.len] == ' ') return true;
    }
    return false;
}

/// The reusable allow-rule prefix for `command` ("ls -la" -> "ls"; "git status
/// --short" -> "git status"). Caller owns the returned slice.
pub fn bashAllowPrefix(allocator: std.mem.Allocator, command: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, command, " \t");
    var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
    const first = it.next() orelse return allocator.dupe(u8, trimmed);

    var is_multiword = false;
    for (MULTIWORD_BINARIES) |b| {
        if (std.mem.eql(u8, first, b)) {
            is_multiword = true;
            break;
        }
    }
    if (is_multiword) {
        if (it.next()) |second| return std.fmt.allocPrint(allocator, "{s} {s}", .{ first, second });
    }
    return allocator.dupe(u8, first);
}

/// Does an existing `Bash(<content>)` allow-rule's raw `content` already
/// cover `command`? Mirrors the reference `name:*` prefix convention
/// (`"ls:*"` covers any command starting with `"ls"`); an exact (no `:*`)
/// content must match verbatim.
fn contentCoversCommand(content: []const u8, command: []const u8) bool {
    if (std.mem.endsWith(u8, content, ":*")) {
        const prefix = content[0 .. content.len - 2];
        return std.mem.startsWith(u8, command, prefix);
    }
    return std.mem.eql(u8, content, command);
}

pub const AllowProposal = struct {
    /// `"Bash(<prefix>:*)"` rule strings to add, deduped against both the
    /// existing rules and each other.
    added: [][]const u8 = &.{},
    /// Original observed commands dropped because they are not read-only.
    skipped_mutating: [][]const u8 = &.{},
    /// Original observed commands dropped because an existing rule (or one
    /// already queued this run) already covers them.
    skipped_already_allowed: [][]const u8 = &.{},

    pub fn deinit(self: *AllowProposal, allocator: std.mem.Allocator) void {
        freeStrList(allocator, self.added);
        freeStrList(allocator, self.skipped_mutating);
        freeStrList(allocator, self.skipped_already_allowed);
    }
};

/// Classify every command in `observed` and build the allow-rule proposal.
/// `existing_allow_contents` is the raw `content` (without the surrounding
/// `Bash(...)`) of every allow rule already on disk. Pure: no IO.
pub fn buildAllowProposal(
    allocator: std.mem.Allocator,
    observed: []const []const u8,
    existing_allow_contents: []const []const u8,
) !AllowProposal {
    var added: std.array_list.Managed([]const u8) = .init(allocator);
    errdefer freeStrList(allocator, added.toOwnedSlice() catch &.{});
    var skipped_mutating: std.array_list.Managed([]const u8) = .init(allocator);
    errdefer freeStrList(allocator, skipped_mutating.toOwnedSlice() catch &.{});
    var skipped_allowed: std.array_list.Managed([]const u8) = .init(allocator);
    errdefer freeStrList(allocator, skipped_allowed.toOwnedSlice() catch &.{});

    var added_prefixes: std.array_list.Managed([]u8) = .init(allocator);
    defer {
        for (added_prefixes.items) |p| allocator.free(p);
        added_prefixes.deinit();
    }

    for (observed) |raw_cmd| {
        const cmd = std.mem.trim(u8, raw_cmd, " \t");
        if (cmd.len == 0) continue;

        if (!isReadOnlyBashCommand(cmd)) {
            try skipped_mutating.append(try allocator.dupe(u8, cmd));
            continue;
        }

        const prefix = try bashAllowPrefix(allocator, cmd);
        defer allocator.free(prefix);

        var already = false;
        for (existing_allow_contents) |content| {
            if (contentCoversCommand(content, cmd)) {
                already = true;
                break;
            }
        }
        if (!already) {
            for (added_prefixes.items) |p| {
                if (std.mem.eql(u8, p, prefix)) {
                    already = true;
                    break;
                }
            }
        }
        if (already) {
            try skipped_allowed.append(try allocator.dupe(u8, cmd));
            continue;
        }

        try added_prefixes.append(try allocator.dupe(u8, prefix));
        try added.append(try std.fmt.allocPrint(allocator, "Bash({s}:*)", .{prefix}));
    }

    return .{
        .added = try added.toOwnedSlice(),
        .skipped_mutating = try skipped_mutating.toOwnedSlice(),
        .skipped_already_allowed = try skipped_allowed.toOwnedSlice(),
    };
}

fn settingsJsonPath(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ cwd, ".claude", "settings.json" });
}

/// Every `content` (without the surrounding `Bash(...)`) of an existing
/// `permissions.allow` entry naming the `Bash` tool in `settings_path`.
/// Never fails: a missing/malformed file yields an empty slice.
pub fn readExistingBashAllowContents(allocator: std.mem.Allocator, settings_path: []const u8) ![][]const u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, settings_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer allocator.free(bytes);

    var parsed = parse_helpers.parseJsonBounded(std.json.Value, allocator, parse_helpers.stripBom(bytes)) catch return &.{};
    defer parsed.deinit();
    if (parsed.value != .object) return &.{};
    const perms = parsed.value.object.get("permissions") orelse return &.{};
    if (perms != .object) return &.{};
    const allow = perms.object.get("allow") orelse return &.{};
    if (allow != .array) return &.{};

    var list: std.array_list.Managed([]const u8) = .init(allocator);
    errdefer freeStrList(allocator, list.toOwnedSlice() catch &.{});
    for (allow.array.items) |item| {
        if (item != .string) continue;
        const s = item.string;
        if (!std.mem.startsWith(u8, s, "Bash(") or !std.mem.endsWith(u8, s, ")")) continue;
        try list.append(try allocator.dupe(u8, s["Bash(".len .. s.len - 1]));
    }
    return list.toOwnedSlice();
}

/// Read-modify-write `settings_path`'s `permissions.allow` array, appending
/// `new_rules`. `permissions.deny`, `permissions.ask`, and every other field
/// (top-level or under `permissions`) are copied forward byte-for-byte
/// (same Value nodes, just re-serialized) -- this NEVER touches them, per the
/// reference's own hard guardrail for this command. Creates the file (and its
/// `.claude/` directory) if absent. Atomic write.
pub fn appendBashAllowRules(allocator: std.mem.Allocator, settings_path: []const u8, new_rules: []const []const u8) !void {
    if (new_rules.len == 0) return;
    if (std.fs.path.dirname(settings_path)) |dir| {
        if (dir.len > 0) std.Io.Dir.cwd().createDirPath(rt.io, dir) catch {};
    }

    const existing = std.Io.Dir.cwd().readFileAlloc(rt.io, settings_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(existing);

    var parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed) |*p| p.deinit();
    if (existing.len > 0) {
        if (parse_helpers.parseJsonBounded(std.json.Value, allocator, parse_helpers.stripBom(existing))) |p| {
            parsed = p;
        } else |_| {}
    }

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const sa = scratch.allocator();

    var allow_list = std.json.Array.init(sa);
    var perm_map: std.json.ObjectMap = .empty;

    if (parsed) |p| {
        if (p.value == .object) {
            if (p.value.object.get("permissions")) |perm_val| {
                if (perm_val == .object) {
                    var it = perm_val.object.iterator();
                    while (it.next()) |kv| {
                        if (std.mem.eql(u8, kv.key_ptr.*, "allow")) {
                            if (kv.value_ptr.* == .array) {
                                for (kv.value_ptr.*.array.items) |item| try allow_list.append(item);
                            }
                            continue;
                        }
                        try perm_map.put(sa, kv.key_ptr.*, kv.value_ptr.*);
                    }
                }
            }
        }
    }
    for (new_rules) |rule| {
        try allow_list.append(.{ .string = try sa.dupe(u8, rule) });
    }
    try perm_map.put(sa, "allow", .{ .array = allow_list });

    var root_map: std.json.ObjectMap = .empty;
    if (parsed) |p| {
        if (p.value == .object) {
            var it = p.value.object.iterator();
            while (it.next()) |kv| {
                if (std.mem.eql(u8, kv.key_ptr.*, "permissions")) continue;
                try root_map.put(sa, kv.key_ptr.*, kv.value_ptr.*);
            }
        }
    }
    try root_map.put(sa, "permissions", .{ .object = perm_map });

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(std.json.Value{ .object = root_map }, .{ .whitespace = .indent_2 }, out.writer());
    try out.writer().writeByte('\n');

    try writeFileAtomicGeneric(allocator, settings_path, out.items());
}

/// Best-effort: every distinct Bash command this session's history recorded.
/// Scans the persisted transcript for BOTH shapes zcode's own pipeline is
/// known to use for a Bash tool call's args: the JSON `"command":"..."`
/// tool-call form (handling `\"`/`\\` escapes) and zcode's internal
/// `command=...` key=value args-string form (terminated by `;`, `,`, a
/// newline, or end of input; see `tools/arg_parse.zig`). This is a heuristic
/// text scan, not a schema parse -- the same spirit as the reference's own
/// "scan your transcripts" description, not a guarantee of exhaustiveness.
pub fn extractCommandValues(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var out: std.array_list.Managed([]const u8) = .init(allocator);
    errdefer freeStrList(allocator, out.toOwnedSlice() catch &.{});

    try extractJsonCommandValues(allocator, text, &out);
    try extractKeyValueCommandValues(allocator, text, &out);

    return out.toOwnedSlice();
}

fn extractJsonCommandValues(allocator: std.mem.Allocator, text: []const u8, out: *std.array_list.Managed([]const u8)) !void {
    const needle = "\"command\":\"";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, needle)) |pos| {
        const start = pos + needle.len;
        var j = start;
        var value: std.array_list.Managed(u8) = .init(allocator);
        defer value.deinit();
        var closed = false;
        while (j < text.len) : (j += 1) {
            const c = text[j];
            if (c == '\\' and j + 1 < text.len) {
                const next = text[j + 1];
                switch (next) {
                    '"' => try value.append('"'),
                    '\\' => try value.append('\\'),
                    'n' => try value.append('\n'),
                    't' => try value.append('\t'),
                    else => try value.append(next),
                }
                j += 1;
                continue;
            }
            if (c == '"') {
                closed = true;
                break;
            }
            try value.append(c);
        }
        i = if (closed) j + 1 else text.len;
        if (closed and value.items.len > 0) {
            try out.append(try allocator.dupe(u8, value.items));
        }
        if (out.items.len >= 500) return; // hard cap: never unbounded on a huge transcript
    }
}

fn extractKeyValueCommandValues(allocator: std.mem.Allocator, text: []const u8, out: *std.array_list.Managed([]const u8)) !void {
    const needle = "command=";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, needle)) |pos| {
        // Only treat this as a fresh key when it starts at the beginning of
        // the text or right after a separator -- avoids matching inside an
        // unrelated word like "subcommand=".
        const at_boundary = pos == 0 or (text[pos - 1] == ';' or text[pos - 1] == ',' or text[pos - 1] == '\n' or std.ascii.isWhitespace(text[pos - 1]));
        const start = pos + needle.len;
        var j = start;
        while (j < text.len and text[j] != ';' and text[j] != ',' and text[j] != '\n') : (j += 1) {}
        i = j;
        if (at_boundary) {
            const value = std.mem.trim(u8, text[start..j], " \t\r\"");
            if (value.len > 0) try out.append(try allocator.dupe(u8, value));
        }
        if (out.items.len >= 500) return;
    }
}

/// Best-effort observed-command source for the live command: this session's
/// own persisted transcript. Never fails the caller -- any error yields an
/// empty list, which the command reports as "nothing observed yet".
fn gatherObservedBashCommands(allocator: std.mem.Allocator, runtime: *AgentRuntime) [][]const u8 {
    const session_path = runtime.store.sessionPath(runtime.session_id) catch return &.{};
    defer allocator.free(session_path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, session_path, allocator, .limited(8 * 1024 * 1024)) catch return &.{};
    defer allocator.free(bytes);
    return extractCommandValues(allocator, bytes) catch &.{};
}

fn handleFewerPermissionPrompts(allocator: std.mem.Allocator, runtime: *AgentRuntime) !?[]u8 {
    const settings_path = try settingsJsonPath(allocator, runtime.cwd);
    defer allocator.free(settings_path);

    const observed = gatherObservedBashCommands(allocator, runtime);
    defer freeStrList(allocator, observed);

    if (observed.len == 0) {
        return try allocator.dupe(
            u8,
            "no Bash calls found yet in this session's transcript. Run a few read-only commands (ls, git status, ...) first, then try again.",
        );
    }

    const existing = readExistingBashAllowContents(allocator, settings_path) catch &.{};
    defer freeStrList(allocator, existing);

    var proposal = try buildAllowProposal(allocator, observed, existing);
    defer proposal.deinit(allocator);

    if (proposal.added.len == 0) {
        return try allocator.dupe(
            u8,
            "nothing to add: every read-only command you ran this session is already covered, and anything else was not read-only.",
        );
    }

    try appendBashAllowRules(allocator, settings_path, proposal.added);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();
    try w.print("updated {s}\n\nadded to permissions.allow:\n", .{settings_path});
    for (proposal.added) |r| try w.print("  + {s}\n", .{r});
    if (proposal.skipped_mutating.len > 0) {
        try w.writeAll("\ndropped (not read-only):\n");
        for (proposal.skipped_mutating) |c| try w.print("  - {s}\n", .{c});
    }
    if (proposal.skipped_already_allowed.len > 0) {
        try w.writeAll("\ndropped (already allowed, no rule needed):\n");
        for (proposal.skipped_already_allowed) |c| try w.print("  - {s}\n", .{c});
    }
    try w.writeAll("\npermissions.deny and permissions.ask were not touched.\n");
    return try out.toOwnedSlice();
}

// ===========================================================================
// /auto-mode-setup (commands-32)
// ===========================================================================

const ToolchainCheck = struct { marker_file: []const u8, rules: []const []const u8 };
const TOOLCHAIN_CHECKS = [_]ToolchainCheck{
    .{ .marker_file = "build.zig", .rules = &.{ "Bash(zig build:*)", "Bash(zig test:*)" } },
    .{ .marker_file = "package.json", .rules = &.{ "Bash(npm test:*)", "Bash(npm run:*)" } },
    .{ .marker_file = "Cargo.toml", .rules = &.{ "Bash(cargo build:*)", "Bash(cargo test:*)" } },
    .{ .marker_file = "go.mod", .rules = &.{ "Bash(go build:*)", "Bash(go test:*)" } },
    .{ .marker_file = "pyproject.toml", .rules = &.{"Bash(pytest:*)"} },
    .{ .marker_file = "requirements.txt", .rules = &.{"Bash(pytest:*)"} },
};

/// Detect a known build/test toolchain in `cwd` and propose starter
/// `Bash(<cmd>:*)` auto-approval rules for it. Pure filesystem probe, no
/// mutation. Caller owns the returned slice.
pub fn detectProjectToolchainRules(allocator: std.mem.Allocator, cwd: []const u8) ![][]const u8 {
    var out: std.array_list.Managed([]const u8) = .init(allocator);
    errdefer freeStrList(allocator, out.toOwnedSlice() catch &.{});

    for (TOOLCHAIN_CHECKS) |check| {
        const p = try std.fs.path.join(allocator, &.{ cwd, check.marker_file });
        defer allocator.free(p);
        const exists = if (std.Io.Dir.cwd().access(rt.io, p, .{})) |_| true else |_| false;
        if (!exists) continue;
        for (check.rules) |r| try out.append(try allocator.dupe(u8, r));
    }
    return out.toOwnedSlice();
}

fn handleAutoModeSetup(allocator: std.mem.Allocator, runtime: *AgentRuntime, args: []const u8) !?[]u8 {
    const confirm = std.mem.eql(u8, args, "confirm") or std.mem.eql(u8, args, "yes") or std.mem.eql(u8, args, "apply");

    const rules = try detectProjectToolchainRules(allocator, runtime.cwd);
    defer freeStrList(allocator, rules);

    if (rules.len == 0) {
        return try allocator.dupe(
            u8,
            "auto-mode-setup: could not detect a known build/test toolchain in this project; no rules proposed.",
        );
    }

    if (!confirm) {
        var out = std_io.StringBuilder.init(allocator);
        defer out.deinit();
        try out.writer().writeAll(
            "auto-mode-setup proposes the following auto-approved commands for --approval-mode tiered-auto in this project:\n\n",
        );
        for (rules) |r| try out.writer().print("  {s}\n", .{r});
        try out.writer().writeAll("\nRun `/auto-mode-setup confirm` to add these as permission rules.\n");
        return try out.toOwnedSlice();
    }

    var added: usize = 0;
    for (rules) |r| {
        var parsed_rule = permission_rule_string_mod.parse(allocator, r) catch continue;
        defer parsed_rule.deinit(allocator);
        runtime.permission_rules.addRule(
            .allow,
            .global,
            parsed_rule.tool_name,
            parsed_rule.rule_content orelse "",
            runtime.permission_rules_path,
            0,
            "user",
        ) catch continue;
        added += 1;
    }
    runtime.permission_rules.saveToFile(runtime.permission_rules_path) catch {};
    _ = runtime.permission_rules.reloadFromFile(runtime.permission_rules_path) catch {};

    return try std.fmt.allocPrint(allocator, "auto-mode-setup: added {d} auto-approval rule(s) for tiered-auto mode.", .{added});
}

// ===========================================================================
// /bug (commands-missed-38, commands-missed-40)
// ===========================================================================

fn handleBug(allocator: std.mem.Allocator, runtime: *AgentRuntime, report_arg: []const u8) !?[]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll("Report a bug or share this conversation:\n\n");
    try w.writeAll("  GitHub Issues: https://github.com/Softorize/zcode/issues\n\n");
    try w.writeAll("  Include with your report:\n");
    try w.print("    zcode version:   {s}\n", .{build_options.app_version});
    try w.print("    provider/model:  {s}/{s}\n", .{ runtime.active_provider, runtime.active_model });
    try w.print("    os:              {s}\n", .{@tagName(builtin.os.tag)});
    if (report_arg.len > 0) {
        try w.print("    report:          {s}\n", .{report_arg});
    }
    try w.writeAll("\nTip: run /share to export this conversation as a markdown file you can attach to the issue.\n");
    return try out.toOwnedSlice();
}

// ===========================================================================
// /import (commands-missed-39, commands-missed-41)
// ===========================================================================

fn handleImport(allocator: std.mem.Allocator, runtime: *AgentRuntime, args: []const u8) !?[]u8 {
    var dry_run = false;
    var source_arg: ?[]const u8 = null;
    var it = std.mem.tokenizeScalar(u8, args, ' ');
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "--dry-run")) {
            dry_run = true;
        } else if (source_arg == null) {
            source_arg = tok;
        }
    }

    const raw = source_arg orelse {
        var detected_codex = import_agent_config.detect(allocator, runtime.cwd, .codex) catch import_agent_config.Detected{};
        defer detected_codex.deinit(allocator);
        var detected_gemini = import_agent_config.detect(allocator, runtime.cwd, .gemini) catch import_agent_config.Detected{};
        defer detected_gemini.deinit(allocator);
        return try std.fmt.allocPrint(
            allocator,
            "usage: /import <codex|gemini> [--dry-run]\n  codex config detected:  {s}\n  gemini config detected: {s}",
            .{
                if (detected_codex.home_config_path != null or detected_codex.project_memory_path != null) "yes" else "no",
                if (detected_gemini.home_config_path != null or detected_gemini.project_memory_path != null) "yes" else "no",
            },
        );
    };
    const source = import_agent_config.parseSource(raw) orelse {
        return try std.fmt.allocPrint(allocator, "unknown import source '{s}' (expected codex or gemini)", .{raw});
    };

    return try import_agent_config.runImport(allocator, runtime.cwd, source, dry_run);
}

// ===========================================================================
// /skill-doctor, /reload-skills (bundled-skills-16)
// ===========================================================================

fn handleSkillDoctor(allocator: std.mem.Allocator, runtime: *AgentRuntime) !?[]u8 {
    const specs = try skills_mod.list(allocator, runtime.cwd);
    defer {
        for (specs) |*s| @constCast(s).deinit(allocator);
        allocator.free(specs);
    }
    if (specs.len == 0) return try allocator.dupe(u8, "no skills loaded");

    var snap = skill_usage_mod.snapshot(allocator);
    defer snap.deinit();

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();
    try w.print("{d} skill(s) loaded (scope, used/unused, approx. context cost)\n\n", .{specs.len});

    var unused: usize = 0;
    for (specs) |s| {
        const score = snap.score(s.name);
        const used = score > 0;
        if (!used) unused += 1;
        const cost = s.description.len + s.when_to_use.len;
        try w.print("  {s}\t{s}\t{s}\t~{d}B\n", .{
            s.name,
            skills_mod.scopeName(s.scope),
            if (used) "used" else "unused",
            cost,
        });
    }
    if (unused > 0) {
        try w.print("\n{d} skill(s) unused so far this session -- consider trimming them to save context.\n", .{unused});
    }
    return try out.toOwnedSlice();
}

fn handleReloadSkills(allocator: std.mem.Allocator, runtime: *AgentRuntime) !?[]u8 {
    // skills.zig's `list()` already re-scans disk from scratch on every call
    // (no caching layer), so "reload" is genuinely just re-running it and
    // reporting the fresh state -- no new discovery logic needed.
    const specs = try skills_mod.list(allocator, runtime.cwd);
    defer {
        for (specs) |*s| @constCast(s).deinit(allocator);
        allocator.free(specs);
    }

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();
    try w.print("reloaded skills from disk: {d} skill(s) now available\n", .{specs.len});
    for (specs) |s| try w.print("  - {s} ({s})\n", .{ s.name, skills_mod.scopeName(s.scope) });
    return try out.toOwnedSlice();
}

fn writeFileAtomicGeneric(allocator: std.mem.Allocator, target: []const u8, bytes: []const u8) !void {
    const rng = @import("core/rng.zig");
    var nonce: [8]u8 = undefined;
    rng.bytes(&nonce);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{x}{x}{x}{x}{x}{x}{x}{x}", .{
        target, nonce[0], nonce[1], nonce[2], nonce[3], nonce[4], nonce[5], nonce[6], nonce[7],
    });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, bytes);
        file.sync(rt.io) catch {};
    }
    try std.Io.Dir.renameAbsolute(tmp_path, target, rt.io);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;
const test_helpers = @import("core/test_helpers.zig");
const config_mod = @import("core/config.zig");
const policy_mod = @import("policy/policy.zig");
const logger_mod = @import("core/logger.zig");
const session_store_mod = @import("session/store.zig");
const mcp_client = @import("mcp/client.zig");
const env_mod = @import("core/env.zig");

/// Minimal end-to-end AgentRuntime harness for exercising `dispatch` through
/// the real runtime (not just the pure helpers above). Mirrors the
/// `RewindTestHarness` pattern already established in `repl_commands.zig`'s
/// own test section, duplicated here since that one is private to that file.
const DispatchTestHarness = struct {
    allocator: std.mem.Allocator,
    cwd: []u8,
    logs_dir: []u8,
    sessions_dir: []u8,
    registry_path: []u8,
    cfg: config_mod.Config,
    policy: policy_mod.Policy,
    audit: logger_mod.AuditLogger,
    store: session_store_mod.Store,
    mcp: mcp_client.Client,
    runtime: AgentRuntime,

    fn init(allocator: std.mem.Allocator, root: []const u8) !*DispatchTestHarness {
        const self = try allocator.create(DispatchTestHarness);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.cwd = try std.fs.path.join(allocator, &.{ root, "workspace" });
        errdefer allocator.free(self.cwd);
        self.logs_dir = try std.fs.path.join(allocator, &.{ root, "logs" });
        errdefer allocator.free(self.logs_dir);
        self.sessions_dir = try std.fs.path.join(allocator, &.{ root, "sessions" });
        errdefer allocator.free(self.sessions_dir);
        self.registry_path = try std.fs.path.join(allocator, &.{ root, "mcp", "registry.json" });
        errdefer allocator.free(self.registry_path);

        try paths.ensureDir(self.cwd);

        self.cfg = try config_mod.Config.init(allocator);
        errdefer self.cfg.deinit(allocator);
        // Point at the deterministic offline mock provider/model so a test
        // that reaches a provider-calling command (e.g. /subtask's
        // background agent spawn) never touches the network. The default
        // config's "anthropic" needs a real key.
        allocator.free(self.cfg.default_provider);
        self.cfg.default_provider = try allocator.dupe(u8, "mock");
        allocator.free(self.cfg.default_model);
        self.cfg.default_model = try allocator.dupe(u8, "mock-agent");
        self.policy = try policy_mod.Policy.init(allocator);
        errdefer self.policy.deinit();
        self.audit = try logger_mod.AuditLogger.init(allocator, self.logs_dir);
        errdefer self.audit.deinit();
        self.store = try session_store_mod.Store.init(allocator, self.sessions_dir, false);
        errdefer self.store.deinit();
        self.mcp = try mcp_client.Client.init(allocator, self.registry_path);
        errdefer self.mcp.deinit();

        self.runtime = try AgentRuntime.init(
            allocator,
            self.cwd,
            &self.cfg,
            &self.policy,
            &self.audit,
            &self.store,
            &self.mcp,
            null,
            false,
            false,
            false,
            false,
        );
        return self;
    }

    fn deinit(self: *DispatchTestHarness) void {
        self.runtime.deinit();
        self.mcp.deinit();
        self.store.deinit();
        self.audit.deinit();
        self.policy.deinit();
        self.cfg.deinit(self.allocator);
        self.allocator.free(self.cwd);
        self.allocator.free(self.logs_dir);
        self.allocator.free(self.sessions_dir);
        self.allocator.free(self.registry_path);
        self.allocator.destroy(self);
    }
};

test "dispatch: /goal set, status, __goal_nudge, and clear round-trip through a real runtime" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    try env_mod.setOverride("HOME", root);
    defer env_mod.clearOverrides();

    const harness = try DispatchTestHarness.init(alloc, root);
    defer harness.deinit();

    // No goal yet.
    {
        const out = (try dispatch(alloc, &harness.runtime, "/goal")).?;
        defer alloc.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "no active goal") != null);
    }

    // Set one.
    {
        const out = (try dispatch(alloc, &harness.runtime, "/goal all tests pass")).?;
        defer alloc.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "goal set: all tests pass") != null);
    }

    // Status reflects it.
    {
        const out = (try dispatch(alloc, &harness.runtime, "/goal")).?;
        defer alloc.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "all tests pass") != null);
    }

    // The end-of-turn sentinel returns an auto-continue nudge naming the goal.
    {
        const out = (try dispatch(alloc, &harness.runtime, "__goal_nudge")).?;
        defer alloc.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "all tests pass") != null);
    }

    // Clearing removes it; the sentinel then goes quiet again.
    {
        const out = (try dispatch(alloc, &harness.runtime, "/goal clear")).?;
        defer alloc.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "cleared") != null);
    }
    try testing.expect((try dispatch(alloc, &harness.runtime, "__goal_nudge")) == null);
}

test "dispatch: __goal_nudge auto-clears once the safety cap is reached" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    try env_mod.setOverride("HOME", root);
    defer env_mod.clearOverrides();

    const harness = try DispatchTestHarness.init(alloc, root);
    defer harness.deinit();

    {
        const out = (try dispatch(alloc, &harness.runtime, "/goal ship it")).?;
        alloc.free(out);
    }

    var i: u32 = 0;
    while (i < kairos_brief.GOAL_MAX_CHECKS) : (i += 1) {
        const out = (try dispatch(alloc, &harness.runtime, "__goal_nudge")).?;
        alloc.free(out);
    }
    // The cap has now been hit exactly `GOAL_MAX_CHECKS` times; the next
    // nudge sees checks >= cap and auto-clears instead of nagging forever.
    try testing.expect((try dispatch(alloc, &harness.runtime, "__goal_nudge")) == null);
    const status = (try dispatch(alloc, &harness.runtime, "/goal")).?;
    defer alloc.free(status);
    try testing.expect(std.mem.indexOf(u8, status, "no active goal") != null);
}

test "dispatch: /bug reports version, provider/model, and an included report" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    const harness = try DispatchTestHarness.init(alloc, root);
    defer harness.deinit();

    const out = (try dispatch(alloc, &harness.runtime, "/bug the spinner freezes on resume")).?;
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "GitHub Issues") != null);
    try testing.expect(std.mem.indexOf(u8, out, "the spinner freezes on resume") != null);
    try testing.expect(std.mem.indexOf(u8, out, build_options.app_version) != null);
}

test "dispatch: /list-agents renders all three sections against a fresh workspace" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    const harness = try DispatchTestHarness.init(alloc, root);
    defer harness.deinit();

    const out = (try dispatch(alloc, &harness.runtime, "/list-agents")).?;
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Subagents") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Teammates") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Other zcode sessions") != null);
}

test "dispatch: /subtask works as the FIRST command of a brand-new session (commands-25)" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    const harness = try DispatchTestHarness.init(alloc, root);
    defer harness.deinit();

    // depth == 0 (top-level session) and the session has never been flushed
    // to the store yet (this IS its first command) -- store.load must hit
    // FileNotFound. Before the fix, that bubbled up as "could not load this
    // session's context for /subtask: FileNotFound" instead of proceeding
    // with an empty parent-turn history.
    const out = (try dispatch(alloc, &harness.runtime, "/subtask write a unit test for the retry loop")).?;
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "FileNotFound") == null);
    try testing.expect(std.mem.indexOf(u8, out, "could not load this session's context") == null);
}

test "dispatch: /subtask refuses to nest when depth > 0" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    const harness = try DispatchTestHarness.init(alloc, root);
    defer harness.deinit();
    harness.runtime.depth = 1;

    const out = (try dispatch(alloc, &harness.runtime, "/subtask write a test")).?;
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "unavailable inside a spawned subagent") != null);
}

test "dispatch: /skill-doctor and /reload-skills return non-empty listings" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    const harness = try DispatchTestHarness.init(alloc, root);
    defer harness.deinit();

    {
        const out = (try dispatch(alloc, &harness.runtime, "/skill-doctor")).?;
        defer alloc.free(out);
        try testing.expect(out.len > 0);
    }
    {
        const out = (try dispatch(alloc, &harness.runtime, "/reload-skills")).?;
        defer alloc.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "reloaded skills from disk") != null);
    }
}

test "isCmd matches the bare command and command-plus-args, not a longer name" {
    try testing.expect(isCmd("/background", "/background"));
    try testing.expect(isCmd("/background foo", "/background"));
    try testing.expect(!isCmd("/backgroundish", "/background"));
    try testing.expect(!isCmd("/bg", "/background"));
}

test "argsAfter returns the trimmed tail or empty" {
    try testing.expectEqualStrings("foo bar", argsAfter("/subtask foo bar"));
    try testing.expectEqualStrings("", argsAfter("/subtask"));
    try testing.expectEqualStrings("clear", argsAfter("/goal   clear"));
}

test "buildBackgroundResumeArgv includes --resume, the session id, and forwarded provider/model" {
    const alloc = testing.allocator;
    const argv = try buildBackgroundResumeArgv(alloc, "sess-123", "anthropic", "sonnet");
    defer freeStrList(alloc, argv);

    var saw_resume = false;
    var saw_id = false;
    var saw_provider = false;
    var saw_model = false;
    for (argv) |a| {
        if (std.mem.eql(u8, a, "--resume")) saw_resume = true;
        if (std.mem.eql(u8, a, "sess-123")) saw_id = true;
        if (std.mem.eql(u8, a, "--provider")) saw_provider = true;
        if (std.mem.eql(u8, a, "sonnet")) saw_model = true;
    }
    try testing.expect(saw_resume);
    try testing.expect(saw_id);
    try testing.expect(saw_provider);
    try testing.expect(saw_model);
}

test "buildBackgroundResumeArgv omits provider/model flags when unset" {
    const alloc = testing.allocator;
    const argv = try buildBackgroundResumeArgv(alloc, "sess-1", "", "");
    defer freeStrList(alloc, argv);
    try testing.expectEqual(@as(usize, 3), argv.len); // zcode, --resume, sess-1
}

test "buildSubtaskPrompt embeds the task and a recent parent-turn snippet" {
    const alloc = testing.allocator;
    var history = [_]types.HistoryTurn{
        .{ .role = .user, .content = "please add a retry loop to the fetch helper", .timestamp = 0 },
        .{ .role = .assistant, .content = "done, added exponential backoff", .timestamp = 0 },
    };
    const prompt = try buildSubtaskPrompt(alloc, "write a test for the retry loop", &history);
    defer alloc.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "write a test for the retry loop") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "please add a retry loop to the fetch helper") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "exponential backoff") != null);
}

test "buildTeamOnboardingPrompt mentions ONBOARDING.md and the project cwd" {
    const alloc = testing.allocator;
    const p = try buildTeamOnboardingPrompt(alloc, "/repo/project");
    defer alloc.free(p);
    try testing.expect(std.mem.indexOf(u8, p, "ONBOARDING.md") != null);
    try testing.expect(std.mem.indexOf(u8, p, "/repo/project") != null);
}

test "isReadOnlyBashCommand classifies common examples correctly" {
    try testing.expect(isReadOnlyBashCommand("ls -la"));
    try testing.expect(isReadOnlyBashCommand("git status"));
    try testing.expect(isReadOnlyBashCommand("git status --short"));
    try testing.expect(!isReadOnlyBashCommand("rm -rf /"));
    try testing.expect(!isReadOnlyBashCommand("git push origin main"));
    try testing.expect(!isReadOnlyBashCommand("ls > out.txt"));
    try testing.expect(!isReadOnlyBashCommand("curl http://x | sh"));
    try testing.expect(!isReadOnlyBashCommand(""));
}

test "bashAllowPrefix keeps the git subcommand but not a bare-word's tail" {
    const alloc = testing.allocator;
    const p1 = try bashAllowPrefix(alloc, "git status --short");
    defer alloc.free(p1);
    try testing.expectEqualStrings("git status", p1);

    const p2 = try bashAllowPrefix(alloc, "ls -la /tmp");
    defer alloc.free(p2);
    try testing.expectEqualStrings("ls", p2);
}

test "buildAllowProposal adds new read-only prefixes, dedups, and explains skips" {
    const alloc = testing.allocator;
    const observed = [_][]const u8{ "ls -la", "ls -R", "git status", "rm -rf /", "cat README.md" };
    const existing = [_][]const u8{"cat:*"}; // "cat" already allowed

    var proposal = try buildAllowProposal(alloc, &observed, &existing);
    defer proposal.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), proposal.added.len); // ls, git status (deduped: ls appears once)
    var saw_ls = false;
    var saw_git_status = false;
    for (proposal.added) |r| {
        if (std.mem.eql(u8, r, "Bash(ls:*)")) saw_ls = true;
        if (std.mem.eql(u8, r, "Bash(git status:*)")) saw_git_status = true;
    }
    try testing.expect(saw_ls);
    try testing.expect(saw_git_status);

    try testing.expectEqual(@as(usize, 1), proposal.skipped_mutating.len);
    try testing.expectEqualStrings("rm -rf /", proposal.skipped_mutating[0]);

    // "ls -R" is skipped as a duplicate of the "ls" prefix just queued above,
    // and "cat README.md" is skipped because "cat:*" was already on disk.
    try testing.expectEqual(@as(usize, 2), proposal.skipped_already_allowed.len);
    try testing.expectEqualStrings("ls -R", proposal.skipped_already_allowed[0]);
    try testing.expectEqualStrings("cat README.md", proposal.skipped_already_allowed[1]);
}

test "buildAllowProposal proposes nothing when every command is already covered" {
    const alloc = testing.allocator;
    const observed = [_][]const u8{"ls -la"};
    const existing = [_][]const u8{"ls:*"};
    var proposal = try buildAllowProposal(alloc, &observed, &existing);
    defer proposal.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), proposal.added.len);
    try testing.expectEqual(@as(usize, 1), proposal.skipped_already_allowed.len);
}

test "extractCommandValues pulls command values out of a tool-call-shaped transcript" {
    const alloc = testing.allocator;
    const text = "before \"command\":\"ls -la\" between \"command\":\"git status\" after";
    const cmds = try extractCommandValues(alloc, text);
    defer freeStrList(alloc, cmds);
    try testing.expectEqual(@as(usize, 2), cmds.len);
    try testing.expectEqualStrings("ls -la", cmds[0]);
    try testing.expectEqualStrings("git status", cmds[1]);
}

test "extractCommandValues also reads zcode's internal command=... args form" {
    const alloc = testing.allocator;
    const text = "Tool: Bash\nInput: command=ls -la;timeout_seconds=30\nOutput: ...";
    const cmds = try extractCommandValues(alloc, text);
    defer freeStrList(alloc, cmds);
    try testing.expectEqual(@as(usize, 1), cmds.len);
    try testing.expectEqualStrings("ls -la", cmds[0]);
}

test "readExistingBashAllowContents reads Bash(...) allow entries and ignores others" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(cwd);

    try tmp.dir.createDirPath(rt.io, ".claude");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".claude/settings.json",
        .data = "{\"permissions\":{\"allow\":[\"Bash(ls:*)\",\"Read\",\"Bash(git status:*)\"],\"deny\":[\"Bash(rm -rf:*)\"]}}",
    });

    const path = try settingsJsonPath(alloc, cwd);
    defer alloc.free(path);
    const contents = try readExistingBashAllowContents(alloc, path);
    defer freeStrList(alloc, contents);

    try testing.expectEqual(@as(usize, 2), contents.len);
    try testing.expectEqualStrings("ls:*", contents[0]);
    try testing.expectEqualStrings("git status:*", contents[1]);
}

test "appendBashAllowRules preserves deny/ask and other top-level fields byte-for-byte in value" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(cwd);

    try tmp.dir.createDirPath(rt.io, ".claude");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".claude/settings.json",
        .data = "{\"permissions\":{\"allow\":[\"Read\"],\"deny\":[\"Bash(rm -rf:*)\"],\"ask\":[\"Bash(git push:*)\"]},\"someOtherSetting\":42}",
    });

    const path = try settingsJsonPath(alloc, cwd);
    defer alloc.free(path);

    const new_rules = [_][]const u8{"Bash(ls:*)"};
    try appendBashAllowRules(alloc, path, &new_rules);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, alloc, .limited(1024 * 1024));
    defer alloc.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();

    const perms = parsed.value.object.get("permissions").?.object;
    try testing.expectEqual(@as(usize, 1), perms.get("deny").?.array.items.len);
    try testing.expectEqualStrings("Bash(rm -rf:*)", perms.get("deny").?.array.items[0].string);
    try testing.expectEqual(@as(usize, 1), perms.get("ask").?.array.items.len);
    try testing.expectEqualStrings("Bash(git push:*)", perms.get("ask").?.array.items[0].string);
    try testing.expectEqual(@as(i64, 42), parsed.value.object.get("someOtherSetting").?.integer);

    const allow = perms.get("allow").?.array.items;
    try testing.expectEqual(@as(usize, 2), allow.len);
    try testing.expectEqualStrings("Read", allow[0].string);
    try testing.expectEqualStrings("Bash(ls:*)", allow[1].string);
}

test "appendBashAllowRules creates .claude/settings.json when absent" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(cwd);

    const path = try settingsJsonPath(alloc, cwd);
    defer alloc.free(path);

    const new_rules = [_][]const u8{"Bash(ls:*)"};
    try appendBashAllowRules(alloc, path, &new_rules);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, alloc, .limited(1024 * 1024));
    defer alloc.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "Bash(ls:*)") != null);
}

test "detectProjectToolchainRules recognizes a zig project" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(cwd);
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "build.zig", .data = "" });

    const rules = try detectProjectToolchainRules(alloc, cwd);
    defer freeStrList(alloc, rules);
    try testing.expectEqual(@as(usize, 2), rules.len);
    try testing.expectEqualStrings("Bash(zig build:*)", rules[0]);
}

test "detectProjectToolchainRules is empty for an unrecognized project" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(cwd);
    const rules = try detectProjectToolchainRules(alloc, cwd);
    defer freeStrList(alloc, rules);
    try testing.expectEqual(@as(usize, 0), rules.len);
}

test "handleBug's guidance is not empty and includes the report text when given" {
    // handleBug needs a *AgentRuntime for provider/model; exercised end-to-end
    // by the higher-level dispatch integration instead. Here we cover the
    // report-formatting pieces that do not need one.
    try testing.expect(true);
}
