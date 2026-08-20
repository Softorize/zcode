//! #575: Ink component batch 8 - status/indicator components.
//!
//! Minimal ports of reference src/components/* status indicators.

const std = @import("std");
const ink_render = @import("../../core/ink_render.zig");
const ink_layout = @import("../../core/ink_layout.zig");

// --- AgentProgressLine ---
// Shows the current agent's progress: agent type, description, tool-use
// count, tokens. The reference renders a single line with these fields.
pub const AgentProgressLineProps = struct {
    agent_type: []const u8,
    description: ?[]const u8 = null,
    name: ?[]const u8 = null,
    tool_use_count: u32 = 0,
    tokens: ?u64 = null,
    is_last: bool = false,
};

pub fn renderAgentProgressLine(allocator: std.mem.Allocator, props: AgentProgressLineProps) !ink_render.RenderCommand {
    const desc: []const u8 = props.description orelse "";
    const name_part: []const u8 = props.name orelse props.agent_type;
    if (props.tokens) |tokens| {
        return .{
            .node_id = 0,
            .text = try std.fmt.allocPrint(allocator, "{s}: {s} (tools: {d}, tokens: {d})", .{ name_part, desc, props.tool_use_count, tokens }),
            .style = .{ .fg = .cyan },
        };
    }
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "{s}: {s} (tools: {d})", .{ name_part, desc, props.tool_use_count }),
        .style = .{ .fg = .cyan },
    };
}

// --- BashModeProgress ---
// Shows bash command progress. The reference renders the input + a
// progress spinner/state. zcode's version is a styled line with the
// command and an optional progress label.
pub const BashModeProgressProps = struct {
    input: []const u8,
    progress_label: ?[]const u8 = null,
};

pub fn renderBashModeProgress(allocator: std.mem.Allocator, props: BashModeProgressProps) !ink_render.RenderCommand {
    if (props.progress_label) |label| {
        return .{
            .node_id = 0,
            .text = try std.fmt.allocPrint(allocator, "$ {s} [{s}]", .{ props.input, label }),
            .style = .{ .dim = true },
        };
    }
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "$ {s}", .{props.input}),
        .style = .{ .dim = true },
    };
}

// --- EffortIndicator ---
// Shows the current effort level (low/medium/high) as a small badge.
pub const EffortLevel = enum { low, medium, high };

pub fn effortLabel(level: EffortLevel) []const u8 {
    return switch (level) {
        .low => "low",
        .medium => "medium",
        .high => "high",
    };
}

pub fn renderEffortIndicator(level: EffortLevel, allocator: std.mem.Allocator) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "effort: {s}", .{effortLabel(level)}),
        .style = .{ .fg = .yellow, .dim = true },
    };
}

// --- IdeStatusIndicator ---
// Shows the IDE connection status (connected/disconnected + selection).
pub const IdeStatus = struct {
    connected: bool = false,
    ide_name: ?[]const u8 = null,
    selection_file: ?[]const u8 = null,
};

pub fn renderIdeStatus(allocator: std.mem.Allocator, status: IdeStatus) !ink_render.RenderCommand {
    if (!status.connected) {
        return .{
            .node_id = 0,
            .text = try allocator.dupe(u8, "IDE: disconnected"),
            .style = .{ .dim = true },
        };
    }
    const ide: []const u8 = status.ide_name orelse "IDE";
    if (status.selection_file) |file| {
        return .{
            .node_id = 0,
            .text = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ ide, file }),
            .style = .{ .fg = .green },
        };
    }
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "{s}: connected", .{ide}),
        .style = .{ .fg = .green },
    };
}

// --- DiagnosticsDisplay ---
// Shows compiler/linter diagnostics. The reference renders a list of
// diagnostic entries; zcode's version formats them as a single text block.
pub const Diagnostic = struct {
    severity: []const u8, // "error", "warning", "info"
    file: []const u8,
    line: u32,
    message: []const u8,
};

pub fn renderDiagnostics(allocator: std.mem.Allocator, diags: []const Diagnostic) !ink_render.RenderCommand {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    for (diags, 0..) |d, i| {
        if (i > 0) try buf.writer.writeByte('\n');
        try buf.writer.print("{s}: {s}:{d}: {s}", .{ d.severity, d.file, d.line, d.message });
    }
    return .{
        .node_id = 0,
        .text = try allocator.dupe(u8, buf.writer.buffered()),
        .style = .{},
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "renderAgentProgressLine: includes name, description, tool count" {
    const cmd = try renderAgentProgressLine(testing.allocator, .{
        .agent_type = "coder",
        .name = "Alice",
        .description = "writing tests",
        .tool_use_count = 3,
    });
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "Alice") != null);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "writing tests") != null);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "tools: 3") != null);
}

test "renderAgentProgressLine: includes tokens when provided" {
    const cmd = try renderAgentProgressLine(testing.allocator, .{
        .agent_type = "coder",
        .tool_use_count = 1,
        .tokens = 5000,
    });
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "tokens: 5000") != null);
}

test "renderBashModeProgress: includes the command" {
    const cmd = try renderBashModeProgress(testing.allocator, .{ .input = "ls -la" });
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "ls -la") != null);
}

test "renderBashModeProgress: includes progress label when provided" {
    const cmd = try renderBashModeProgress(testing.allocator, .{ .input = "make", .progress_label = "running" });
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "running") != null);
}

test "effortLabel returns the level name" {
    try testing.expectEqualStrings("low", effortLabel(.low));
    try testing.expectEqualStrings("medium", effortLabel(.medium));
    try testing.expectEqualStrings("high", effortLabel(.high));
}

test "renderEffortIndicator: yellow + dim" {
    const cmd = try renderEffortIndicator(.high, testing.allocator);
    defer testing.allocator.free(cmd.text);
    try testing.expectEqual(ink_render.Color.yellow, cmd.style.fg.?);
    try testing.expect(cmd.style.dim);
}

test "renderIdeStatus: disconnected is dim" {
    const cmd = try renderIdeStatus(testing.allocator, .{ .connected = false });
    defer testing.allocator.free(cmd.text);
    try testing.expect(cmd.style.dim);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "disconnected") != null);
}

test "renderIdeStatus: connected with selection is green" {
    const cmd = try renderIdeStatus(testing.allocator, .{
        .connected = true,
        .ide_name = "VSCode",
        .selection_file = "src/main.zig",
    });
    defer testing.allocator.free(cmd.text);
    try testing.expectEqual(ink_render.Color.green, cmd.style.fg.?);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "src/main.zig") != null);
}

test "renderDiagnostics: formats each diagnostic on a line" {
    const diags = [_]Diagnostic{
        .{ .severity = "error", .file = "a.zig", .line = 10, .message = "bad" },
        .{ .severity = "warning", .file = "b.zig", .line = 20, .message = "meh" },
    };
    const cmd = try renderDiagnostics(testing.allocator, &diags);
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "error: a.zig:10: bad") != null);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "warning: b.zig:20: meh") != null);
}
