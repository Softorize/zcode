const std = @import("std");
const rt = @import("zcode_runtime");
const commands_mod = @import("../core/commands.zig");
const skills_mod = @import("../core/skills.zig");

pub fn askUserQuestion(allocator: std.mem.Allocator, question: []const u8, choices: []const u8) ![]u8 {
    if (choices.len == 0) return std.fmt.allocPrint(allocator, "user question: {s}", .{question});
    return std.fmt.allocPrint(allocator, "user question: {s}\nchoices: {s}", .{ question, choices });
}

pub fn skillAction(allocator: std.mem.Allocator, cwd: []const u8, action: []const u8, name: ?[]const u8, args: ?[]const u8) ![]u8 {
    if (std.mem.eql(u8, action, "list")) {
        return skills_mod.renderList(allocator, cwd);
    }

    if (std.mem.eql(u8, action, "read")) {
        const skill_name = name orelse return allocator.dupe(u8, "missing skill name");
        return skills_mod.renderDetail(allocator, cwd, skill_name);
    }

    if (std.mem.eql(u8, action, "run")) {
        const skill_name = name orelse return allocator.dupe(u8, "missing skill name");
        // The model-invoked `Skill action=run` is intercepted upstream by
        // agent_runtime.tryExecuteSkillRun (which threads the live session id);
        // this generic-dispatch fallback has no session plumbing, so
        // ${CLAUDE_SESSION_ID} renders empty here (skills-03).
        return skills_mod.renderRun(allocator, cwd, skill_name, args orelse "", "");
    }

    return allocator.dupe(u8, "unsupported skill action (use list|read|run)");
}

pub fn commandAction(allocator: std.mem.Allocator, cwd: []const u8, action: []const u8, name: ?[]const u8, args: ?[]const u8) ![]u8 {
    if (std.mem.eql(u8, action, "list")) {
        return commands_mod.renderList(allocator, cwd);
    }
    if (std.mem.eql(u8, action, "read")) {
        const command_name = name orelse return allocator.dupe(u8, "missing command name");
        return commands_mod.renderDetail(allocator, cwd, command_name);
    }
    if (std.mem.eql(u8, action, "run")) {
        const command_name = name orelse return allocator.dupe(u8, "missing command name");
        return commands_mod.renderRun(allocator, cwd, command_name, args orelse "");
    }
    return allocator.dupe(u8, "unsupported command action (use list|read|run)");
}

pub fn enterPlanMode(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    _ = cwd;
    return allocator.dupe(u8, "planning mode requested");
}

pub fn exitPlanMode(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    _ = cwd;
    return allocator.dupe(u8, "plan approval requested");
}

const testing = std.testing;
test "askUserQuestion formats" {
    const alloc = testing.allocator;
    const r = try askUserQuestion(alloc, "Q?", "a,b");
    defer alloc.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "Q?") != null);
}

test "skillAction list delegates to skills module" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".zcode/skills/local-debug");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/skills/local-debug/SKILL.md",
        .data =
        \\# Local Debug
        \\
        \\Follow the local debug workflow.
        ,
    });

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const rendered = try skillAction(testing.allocator, cwd, "list", null, null);
    defer testing.allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "local-debug") != null);
}
