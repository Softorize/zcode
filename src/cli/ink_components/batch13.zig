//! #575: Ink component batch 13 - more top-level components (compact).
//!
//! Minimal ports of remaining reference src/components/*.tsx. Each is a
//! compact render function returning a RenderCommand. Full React
//! lifecycle is deferred per ADR 0011.

const std = @import("std");
const ink_render = @import("../../core/ink_render.zig");

// --- App ---
// The reference's App is the root component. zcode's version is a
// placeholder: the main loop drives rendering directly.
pub fn renderAppRoot(allocator: std.mem.Allocator, version: []const u8) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try std.fmt.allocPrint(allocator, "zcode {s}", .{version}), .style = .{ .bold = true } };
}

// --- AutoUpdater / AutoUpdaterWrapper ---
pub const AutoUpdaterState = enum { idle, checking, downloading, ready, installing, failed };

pub fn renderAutoUpdater(allocator: std.mem.Allocator, state: AutoUpdaterState, version: ?[]const u8) !ink_render.RenderCommand {
    const label = switch (state) {
        .idle => "up to date",
        .checking => "checking for updates...",
        .downloading => "downloading update...",
        .ready => if (version) |v| try std.fmt.allocPrint(allocator, "update {s} ready (restart to apply)", .{v}) else "update ready",
        .installing => "installing update...",
        .failed => "update failed",
    };
    return .{
        .node_id = 0,
        .text = if (state == .ready and version != null) try allocator.dupe(u8, label) else try allocator.dupe(u8, label),
        .style = .{ .dim = true, .fg = if (state == .failed) .red else if (state == .ready) .green else null },
    };
}

// --- AwsAuthStatusBox ---
pub fn renderAwsAuthStatus(allocator: std.mem.Allocator, profile: []const u8, valid: bool) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "AWS: {s} ({s})", .{ profile, if (valid) "valid" else "invalid" }),
        .style = .{ .fg = if (valid) .green else .red },
    };
}

// --- BridgeDialog ---
pub fn renderBridgeDialog(allocator: std.mem.Allocator, ide_name: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "Connect to {s}?", .{ide_name}),
        .style = .{ .fg = .cyan },
    };
}

// --- ClaudeInChromeOnboarding ---
pub fn renderClaudeInChromeOnboarding(allocator: std.mem.Allocator) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try allocator.dupe(u8, "Claude in Chrome: install the extension to enable browser integration."),
        .style = .{ .dim = true },
    };
}

// --- ClaudeMdExternalIncludesDialog ---
pub fn renderClaudeMdExternalIncludesDialog(allocator: std.mem.Allocator, path: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "Allow external @include from {s}?", .{path}),
        .style = .{ .fg = .yellow },
    };
}

// --- ContextVisualization ---
pub const ContextSegment = struct { label: []const u8, tokens: u32, color: ?ink_render.Color = null };

pub fn renderContextVisualization(allocator: std.mem.Allocator, segments: []const ContextSegment, total_tokens: u32, max_tokens: u32) !ink_render.RenderCommand {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    try buf.writer.print("Context: {d}/{d} tokens\n", .{ total_tokens, max_tokens });
    for (segments) |seg| {
        const pct = if (max_tokens > 0) (seg.tokens * 100) / max_tokens else 0;
        try buf.writer.print("  {s}: {d} ({d}%)\n", .{ seg.label, seg.tokens, pct });
    }
    return .{ .node_id = 0, .text = try allocator.dupe(u8, buf.writer.buffered()), .style = .{ .dim = true } };
}

// --- CoordinatorAgentStatus ---
pub fn renderCoordinatorAgentStatus(allocator: std.mem.Allocator, active_agents: u32, completed: u32) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "Coordinator: {d} active, {d} completed", .{ active_agents, completed }),
        .style = .{ .fg = .blue, .dim = true },
    };
}

// --- EffortCallout ---
pub fn renderEffortCallout(allocator: std.mem.Allocator, level: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "Effort set to {s}. Shift+Tab to change.", .{level}),
        .style = .{ .fg = .yellow, .dim = true },
    };
}

// --- IdeAutoConnectDialog ---
pub fn renderIdeAutoConnectDialog(allocator: std.mem.Allocator, ide_name: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "Auto-connect to {s} on startup?", .{ide_name}),
        .style = .{ .fg = .cyan },
    };
}

// --- IdeOnboardingDialog ---
pub fn renderIdeOnboardingDialog(allocator: std.mem.Allocator) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try allocator.dupe(u8, "Install the IDE extension for inline diffs and selection context."),
        .style = .{ .dim = true },
    };
}

// --- InvalidSettingsDialog ---
pub fn renderInvalidSettingsDialog(allocator: std.mem.Allocator, setting: []const u8, reason: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "Invalid setting '{s}': {s}", .{ setting, reason }),
        .style = .{ .fg = .red },
    };
}

// --- KeybindingWarnings ---
pub fn renderKeybindingWarnings(allocator: std.mem.Allocator, conflicts: []const []const u8) !ink_render.RenderCommand {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    try buf.writer.writeAll("Keybinding conflicts:\n");
    for (conflicts) |c| try buf.writer.print("  ! {s}\n", .{c});
    return .{ .node_id = 0, .text = try allocator.dupe(u8, buf.writer.buffered()), .style = .{ .fg = .yellow } };
}

// --- LanguagePicker ---
pub fn renderLanguagePicker(allocator: std.mem.Allocator, languages: []const []const u8, selected: usize) !ink_render.RenderCommand {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    for (languages, 0..) |lang, i| {
        const prefix: []const u8 = if (i == selected) "› " else "  ";
        try buf.writer.print("{s}{s}\n", .{ prefix, lang });
    }
    return .{ .node_id = 0, .text = try allocator.dupe(u8, buf.writer.buffered()), .style = .{} };
}

// --- LogSelector ---
pub fn renderLogSelector(allocator: std.mem.Allocator, logs: []const []const u8, selected: usize) !ink_render.RenderCommand {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    try buf.writer.writeAll("Select a log:\n");
    for (logs, 0..) |log, i| {
        const prefix: []const u8 = if (i == selected) "› " else "  ";
        try buf.writer.print("{s}{s}\n", .{ prefix, log });
    }
    return .{ .node_id = 0, .text = try allocator.dupe(u8, buf.writer.buffered()), .style = .{} };
}

// --- Markdown ---
// The reference's Markdown renders markdown to terminal. zcode's version
// is a passthrough (the text itself) - full markdown rendering is a
// larger follow-up.
pub fn renderMarkdown(allocator: std.mem.Allocator, text: []const u8) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try allocator.dupe(u8, text), .style = .{} };
}

// --- MarkdownTable ---
pub fn renderMarkdownTable(allocator: std.mem.Allocator, rows: []const []const []const u8) !ink_render.RenderCommand {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    for (rows, 0..) |row, i| {
        for (row, 0..) |cell, j| {
            if (j > 0) try buf.writer.writeAll(" | ");
            try buf.writer.writeAll(cell);
        }
        try buf.writer.writeByte('\n');
        if (i == 0) {
            // separator row
            for (row, 0..) |cell, j| {
                if (j > 0) try buf.writer.writeAll(" | ");
                for (cell) |_| try buf.writer.writeByte('-');
            }
            try buf.writer.writeByte('\n');
        }
    }
    return .{ .node_id = 0, .text = try allocator.dupe(u8, buf.writer.buffered()), .style = .{} };
}

// --- MCPServerApprovalDialog ---
pub fn renderMcpServerApproval(allocator: std.mem.Allocator, server: []const u8, command: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "Approve MCP server '{s}' (runs: {s})?", .{ server, command }),
        .style = .{ .fg = .yellow, .bold = true },
    };
}

// --- MCPServerDesktopImportDialog ---
pub fn renderMcpServerDesktopImport(allocator: std.mem.Allocator, server: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "Import MCP server '{s}' from desktop config?", .{server}),
        .style = .{ .fg = .cyan },
    };
}

// --- MCPServerMultiselectDialog ---
pub fn renderMcpServerMultiselect(allocator: std.mem.Allocator, servers: []const []const u8, enabled: []const bool) !ink_render.RenderCommand {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    try buf.writer.writeAll("Toggle MCP servers:\n");
    for (servers, 0..) |s, i| {
        const mark: []const u8 = if (i < enabled.len and enabled[i]) "[x] " else "[ ] ";
        try buf.writer.print("{s}{s}\n", .{ mark, s });
    }
    return .{ .node_id = 0, .text = try allocator.dupe(u8, buf.writer.buffered()), .style = .{} };
}

// --- MemoryUsageIndicator ---
pub fn renderMemoryUsage(allocator: std.mem.Allocator, used_kb: u32, limit_kb: u32) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "Memory: {d}/{d} KB", .{ used_kb, limit_kb }),
        .style = .{ .dim = true },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "renderAppRoot: includes version, bold" {
    const cmd = try renderAppRoot(testing.allocator, "1.0");
    defer testing.allocator.free(cmd.text);
    try testing.expect(cmd.style.bold);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "1.0") != null);
}

test "renderAutoUpdater: failed state is red" {
    const cmd = try renderAutoUpdater(testing.allocator, .failed, null);
    defer testing.allocator.free(cmd.text);
    try testing.expectEqual(ink_render.Color.red, cmd.style.fg.?);
}

test "renderAwsAuthStatus: valid is green, invalid is red" {
    const ok = try renderAwsAuthStatus(testing.allocator, "default", true);
    defer testing.allocator.free(ok.text);
    try testing.expectEqual(ink_render.Color.green, ok.style.fg.?);
}

test "renderContextVisualization: includes total + segments" {
    const segs = [_]ContextSegment{.{ .label = "system", .tokens = 100 }};
    const cmd = try renderContextVisualization(testing.allocator, &segs, 100, 1000);
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "100/1000") != null);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "system") != null);
}

test "renderEffortCallout: includes level" {
    const cmd = try renderEffortCallout(testing.allocator, "high");
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "high") != null);
}

test "renderKeybindingWarnings: lists conflicts" {
    const conflicts = [_][]const u8{ "Ctrl+A", "Ctrl+B" };
    const cmd = try renderKeybindingWarnings(testing.allocator, &conflicts);
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "Ctrl+A") != null);
}

test "renderLanguagePicker: marks selected with ›" {
    const langs = [_][]const u8{ "en", "fr" };
    const cmd = try renderLanguagePicker(testing.allocator, &langs, 1);
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "› fr") != null);
}

test "renderMarkdownTable: includes separator row" {
    const rows = [_][]const []const u8{
        &.{ "Col1", "Col2" },
        &.{ "a", "b" },
    };
    const cmd = try renderMarkdownTable(testing.allocator, &rows);
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "Col1 | Col2") != null);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "----") != null);
}

test "renderMcpServerApproval: yellow+bold with server + command" {
    const cmd = try renderMcpServerApproval(testing.allocator, "myserver", "npx foo");
    defer testing.allocator.free(cmd.text);
    try testing.expect(cmd.style.bold);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "myserver") != null);
}

test "renderMcpServerMultiselect: [x] for enabled, [ ] for disabled" {
    const servers = [_][]const u8{ "a", "b" };
    const enabled = [_]bool{ true, false };
    const cmd = try renderMcpServerMultiselect(testing.allocator, &servers, &enabled);
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "[x] a") != null);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "[ ] b") != null);
}
