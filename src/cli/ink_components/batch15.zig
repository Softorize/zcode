//! #575: Ink component batch 15 - subdir components (permissions, memory, mcp, skills, tasks, teams, shell, ui, sandbox, misc dialogs).

const std = @import("std");
const ink_render = @import("../../core/ink_render.zig");

// === permissions/ ===

pub const PermissionPrompt = struct {
    tool: []const u8,
    risk: []const u8,
    summary: []const u8,
};

pub fn renderPermissionPrompt(allocator: std.mem.Allocator, p: PermissionPrompt) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "Allow {s} ({s} risk)? {s}\n  [y] yes [n] no [e] edit [a] always-allow", .{ p.tool, p.risk, p.summary }),
        .style = .{ .fg = .yellow, .bold = true },
    };
}

pub fn renderPermissionDialog(allocator: std.mem.Allocator, tool: []const u8, input: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "Permission required for {s}:\n  {s}", .{ tool, input }),
        .style = .{ .fg = .yellow },
    };
}

pub fn renderFallbackPermissionRequest(allocator: std.mem.Allocator, tool: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "Fallback permission request for {s}", .{tool}),
        .style = .{ .dim = true },
    };
}

pub fn renderPermissionExplanation(allocator: std.mem.Allocator, tool: []const u8, explanation: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ tool, explanation }),
        .style = .{ .dim = true },
    };
}

pub fn renderPermissionDecisionDebug(allocator: std.mem.Allocator, decision: []const u8, reason: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "[debug] {s}: {s}", .{ decision, reason }),
        .style = .{ .dim = true },
    };
}

// === memory/ ===

pub fn renderMemoryFileSelector(allocator: std.mem.Allocator, files: []const []const u8, selected: usize) !ink_render.RenderCommand {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    try buf.writer.writeAll("Select a memory file:\n");
    for (files, 0..) |f, i| {
        const prefix: []const u8 = if (i == selected) "› " else "  ";
        try buf.writer.print("{s}{s}\n", .{ prefix, f });
    }
    return .{ .node_id = 0, .text = try allocator.dupe(u8, buf.writer.buffered()), .style = .{} };
}

pub fn renderMemoryUpdateNotification(allocator: std.mem.Allocator, file: []const u8, added_lines: u32) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "Memory updated: {s} (+{d} lines)", .{ file, added_lines }),
        .style = .{ .fg = .green, .dim = true },
    };
}

// === mcp/ ===

pub fn renderCapabilitiesSection(allocator: std.mem.Allocator, caps: []const []const u8) !ink_render.RenderCommand {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    try buf.writer.writeAll("Capabilities:\n");
    for (caps) |c| try buf.writer.print("  - {s}\n", .{c});
    return .{ .node_id = 0, .text = try allocator.dupe(u8, buf.writer.buffered()), .style = .{ .dim = true } };
}

pub fn renderElicitationDialog(allocator: std.mem.Allocator, prompt: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "MCP server requests input:\n  {s}", .{prompt}),
        .style = .{ .fg = .cyan },
    };
}

pub fn renderMcpListPanel(allocator: std.mem.Allocator, servers: []const []const u8, connected: []const bool) !ink_render.RenderCommand {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    try buf.writer.writeAll("MCP servers:\n");
    for (servers, 0..) |s, i| {
        const status: []const u8 = if (i < connected.len and connected[i]) "connected" else "disconnected";
        try buf.writer.print("  {s}: {s}\n", .{ s, status });
    }
    return .{ .node_id = 0, .text = try allocator.dupe(u8, buf.writer.buffered()), .style = .{} };
}

pub fn renderMcpParsingWarnings(allocator: std.mem.Allocator, warnings: []const []const u8) !ink_render.RenderCommand {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    for (warnings) |w| try buf.writer.print("! {s}\n", .{w});
    return .{ .node_id = 0, .text = try allocator.dupe(u8, buf.writer.buffered()), .style = .{ .fg = .yellow } };
}

// === skills/ ===

pub fn renderSkillsMenu(allocator: std.mem.Allocator, skills: []const []const u8, selected: usize) !ink_render.RenderCommand {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    try buf.writer.writeAll("Skills:\n");
    for (skills, 0..) |s, i| {
        const prefix: []const u8 = if (i == selected) "› " else "  ";
        try buf.writer.print("{s}{s}\n", .{ prefix, s });
    }
    return .{ .node_id = 0, .text = try allocator.dupe(u8, buf.writer.buffered()), .style = .{} };
}

// === tasks/ ===

pub fn renderBackgroundTaskStatus(allocator: std.mem.Allocator, task_id: []const u8, status: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "[{s}] {s}", .{ task_id, status }),
        .style = .{ .dim = true },
    };
}

pub fn renderBackgroundTasksDialog(allocator: std.mem.Allocator, tasks: []const []const u8) !ink_render.RenderCommand {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    try buf.writer.writeAll("Background tasks:\n");
    for (tasks) |t| try buf.writer.print("  - {s}\n", .{t});
    return .{ .node_id = 0, .text = try allocator.dupe(u8, buf.writer.buffered()), .style = .{} };
}

pub fn renderAsyncAgentDetail(allocator: std.mem.Allocator, agent: []const u8, progress: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "Agent {s}: {s}", .{ agent, progress }),
        .style = .{ .fg = .blue, .dim = true },
    };
}

pub fn renderDreamDetailDialog(allocator: std.mem.Allocator, summary: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "[dream] {s}", .{summary}),
        .style = .{ .fg = .magenta, .italic = true },
    };
}

// === teams/ ===

pub fn renderTeamStatus(allocator: std.mem.Allocator, members: []const []const u8, active: u32) !ink_render.RenderCommand {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    try buf.writer.print("Team ({d} active):\n", .{active});
    for (members) |m| try buf.writer.print("  - {s}\n", .{m});
    return .{ .node_id = 0, .text = try allocator.dupe(u8, buf.writer.buffered()), .style = .{ .fg = .blue, .dim = true } };
}

pub fn renderTeamsDialog(allocator: std.mem.Allocator) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try allocator.dupe(u8, "Manage teams: create, invite, or switch."), .style = .{ .fg = .cyan } };
}

// === shell/ ===

pub fn renderOutputLine(allocator: std.mem.Allocator, line: []const u8, is_stderr: bool) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try allocator.dupe(u8, line),
        .style = .{ .fg = if (is_stderr) .red else null },
    };
}

pub fn renderShellProgressMessage(allocator: std.mem.Allocator, command: []const u8, elapsed_ms: u32) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "$ {s} ({d}ms)", .{ command, elapsed_ms }),
        .style = .{ .dim = true },
    };
}

pub fn renderShellTimeDisplay(allocator: std.mem.Allocator, elapsed_ms: u32) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try std.fmt.allocPrint(allocator, "{d}ms", .{elapsed_ms}), .style = .{ .dim = true } };
}

pub fn renderExpandShellOutputContext(allocator: std.mem.Allocator, line_count: u32) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "... ({d} more lines, press to expand)", .{line_count}),
        .style = .{ .dim = true },
    };
}

// === ui/ ===

pub fn renderOrderedList(allocator: std.mem.Allocator, items: []const []const u8) !ink_render.RenderCommand {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    for (items, 0..) |item, i| {
        try buf.writer.print("{d}. {s}\n", .{ i + 1, item });
    }
    return .{ .node_id = 0, .text = try allocator.dupe(u8, buf.writer.buffered()), .style = .{} };
}

pub fn renderTreeSelect(allocator: std.mem.Allocator, nodes: []const []const u8, depth: []const u32, selected: usize) !ink_render.RenderCommand {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    for (nodes, 0..) |n, i| {
        const d: u32 = if (i < depth.len) depth[i] else 0;
        var k: u32 = 0;
        while (k < d) : (k += 1) try buf.writer.writeAll("  ");
        const prefix: []const u8 = if (i == selected) "› " else "  ";
        try buf.writer.print("{s}{s}\n", .{ prefix, n });
    }
    return .{ .node_id = 0, .text = try allocator.dupe(u8, buf.writer.buffered()), .style = .{} };
}

// === sandbox/ ===

pub fn renderSandboxSettings(allocator: std.mem.Allocator, enabled: bool, level: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "Sandbox: {s} (level: {s})", .{ if (enabled) "enabled" else "disabled", level }),
        .style = .{ .fg = if (enabled) .green else .yellow },
    };
}

pub fn renderSandboxDoctorSection(allocator: std.mem.Allocator, healthy: bool, detail: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "Sandbox: {s} - {s}", .{ if (healthy) "OK" else "issue", detail }),
        .style = .{ .fg = if (healthy) .green else .red },
    };
}

// === TrustDialog/ ===

pub fn renderTrustDialog(allocator: std.mem.Allocator, path: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "Trust folder '{s}'? (y/n)", .{path}),
        .style = .{ .fg = .yellow, .bold = true },
    };
}

// === LspRecommendation/ ===

pub fn renderLspRecommendation(allocator: std.mem.Allocator, language: []const u8, server: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "Recommend LSP server '{s}' for {s}?", .{ server, language }),
        .style = .{ .fg = .cyan, .dim = true },
    };
}

// === ManagedSettingsSecurityDialog/ ===

pub fn renderManagedSettingsSecurityDialog(allocator: std.mem.Allocator, source: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "Managed settings from {s} override local config.", .{source}),
        .style = .{ .fg = .yellow },
    };
}

// === LogoV2/ ===

pub fn renderLogo(allocator: std.mem.Allocator, version: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "zcode {s}", .{version}),
        .style = .{ .bold = true, .fg = .cyan },
    };
}

// === wizard/ ===

pub fn renderWizardStep(allocator: std.mem.Allocator, step: u32, total: u32, title: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "[{d}/{d}] {s}", .{ step, total, title }),
        .style = .{ .fg = .cyan, .bold = true },
    };
}

// === Passes/ ===

pub fn renderPassesView(allocator: std.mem.Allocator, pass_count: u32) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "Compiler passes: {d}", .{pass_count}),
        .style = .{ .dim = true },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "renderPermissionPrompt: includes tool + risk + choices" {
    const cmd = try renderPermissionPrompt(testing.allocator, .{ .tool = "Bash", .risk = "high", .summary = "rm -rf" });
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "Bash") != null);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "[y]") != null);
}

test "renderMemoryFileSelector: marks selected" {
    const files = [_][]const u8{ "a.md", "b.md" };
    const cmd = try renderMemoryFileSelector(testing.allocator, &files, 1);
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "› b.md") != null);
}

test "renderMcpListPanel: shows connected status" {
    const servers = [_][]const u8{ "a", "b" };
    const connected = [_]bool{ true, false };
    const cmd = try renderMcpListPanel(testing.allocator, &servers, &connected);
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "connected") != null);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "disconnected") != null);
}

test "renderSkillsMenu: lists skills" {
    const skills = [_][]const u8{ "commit", "review" };
    const cmd = try renderSkillsMenu(testing.allocator, &skills, 0);
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "commit") != null);
}

test "renderBackgroundTaskStatus: includes id + status" {
    const cmd = try renderBackgroundTaskStatus(testing.allocator, "T-1", "running");
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "T-1") != null);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "running") != null);
}

test "renderTeamStatus: includes active count" {
    const members = [_][]const u8{ "alice", "bob" };
    const cmd = try renderTeamStatus(testing.allocator, &members, 2);
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "2 active") != null);
}

test "renderOutputLine: stderr is red" {
    const cmd = try renderOutputLine(testing.allocator, "error", true);
    defer testing.allocator.free(cmd.text);
    try testing.expectEqual(ink_render.Color.red, cmd.style.fg.?);
}

test "renderOrderedList: numbers items" {
    const items = [_][]const u8{ "a", "b", "c" };
    const cmd = try renderOrderedList(testing.allocator, &items);
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "1. a") != null);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "3. c") != null);
}

test "renderTreeSelect: indents by depth" {
    const nodes = [_][]const u8{ "root", "child" };
    const depth = [_]u32{ 0, 1 };
    const cmd = try renderTreeSelect(testing.allocator, &nodes, &depth, 1);
    defer testing.allocator.free(cmd.text);
    // depth 1 = 2 spaces indent + selected prefix "› " + "child"
    try testing.expect(std.mem.indexOf(u8, cmd.text, "  › child") != null);
}

test "renderSandboxSettings: enabled is green" {
    const cmd = try renderSandboxSettings(testing.allocator, true, "strict");
    defer testing.allocator.free(cmd.text);
    try testing.expectEqual(ink_render.Color.green, cmd.style.fg.?);
}

test "renderTrustDialog: yellow+bold" {
    const cmd = try renderTrustDialog(testing.allocator, "/path");
    defer testing.allocator.free(cmd.text);
    try testing.expect(cmd.style.bold);
    try testing.expectEqual(ink_render.Color.yellow, cmd.style.fg.?);
}

test "renderWizardStep: includes step/total + title" {
    const cmd = try renderWizardStep(testing.allocator, 2, 5, "config");
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "[2/5]") != null);
}
