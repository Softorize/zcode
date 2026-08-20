//! #575: Ink component batch 10 - tool-use message + misc components.
//!
//! Minimal ports of reference tool-use-related components and a few
//! misc ones.

const std = @import("std");
const ink_render = @import("../../core/ink_render.zig");

// --- ToolUseLoader ---
// Animated loader shown while a tool is running. The reference cycles
// frames; zcode's version returns the current frame (the caller drives
// the cycling).
pub const ToolUseLoader = struct {
    frame_index: u32 = 0,
    pub fn current(self: ToolUseLoader) []const u8 {
        const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸" };
        return frames[self.frame_index % frames.len];
    }
    pub fn advance(self: *ToolUseLoader) void {
        self.frame_index += 1;
    }
};

// --- FileEditToolDiff ---
// Renders a structured diff for a file edit.
pub const DiffLine = struct {
    kind: enum { context, added, removed },
    text: []const u8,
};

pub fn renderFileEditDiff(allocator: std.mem.Allocator, lines: []const DiffLine) !ink_render.RenderCommand {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    for (lines) |line| {
        const prefix: u8 = switch (line.kind) {
            .context => ' ',
            .added => '+',
            .removed => '-',
        };
        try buf.writer.writeByte(prefix);
        try buf.writer.writeAll(line.text);
        try buf.writer.writeByte('\n');
    }
    return .{
        .node_id = 0,
        .text = try allocator.dupe(u8, buf.writer.buffered()),
        .style = .{},
    };
}

// --- FileEditToolUpdatedMessage ---
pub fn renderFileEditUpdated(allocator: std.mem.Allocator, path: []const u8, additions: u32, deletions: u32) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "Updated {s} (+{d} -{d})", .{ path, additions, deletions }),
        .style = .{ .fg = .green },
    };
}

// --- FileEditToolUseRejectedMessage ---
pub fn renderFileEditRejected(allocator: std.mem.Allocator, path: []const u8, reason: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "Edit rejected for {s}: {s}", .{ path, reason }),
        .style = .{ .fg = .yellow },
    };
}

// --- FallbackToolUseErrorMessage ---
pub fn renderFallbackToolUseError(allocator: std.mem.Allocator, tool_name: []const u8, error_msg: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "{s} failed: {s}", .{ tool_name, error_msg }),
        .style = .{ .fg = .red },
    };
}

// --- FallbackToolUseRejectedMessage ---
pub fn renderFallbackToolUseRejected(allocator: std.mem.Allocator, tool_name: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "{s} rejected by user", .{tool_name}),
        .style = .{ .fg = .yellow },
    };
}

// --- NotebookEditToolUseRejectedMessage ---
pub fn renderNotebookEditRejected(allocator: std.mem.Allocator, notebook: []const u8, reason: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "Notebook edit rejected for {s}: {s}", .{ notebook, reason }),
        .style = .{ .fg = .yellow },
    };
}

// --- CompactSummary ---
// Renders the summary produced by context compaction.
pub fn renderCompactSummary(allocator: std.mem.Allocator, summary: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "[compacted] {s}", .{summary}),
        .style = .{ .dim = true, .italic = true },
    };
}

// --- InterruptedByUser ---
pub fn renderInterruptedByUser(allocator: std.mem.Allocator) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try allocator.dupe(u8, "[interrupted by user]"),
        .style = .{ .fg = .yellow, .dim = true },
    };
}

// --- ConfigurableShortcutHint ---
// Shows a keyboard shortcut hint.
pub fn renderShortcutHint(allocator: std.mem.Allocator, shortcut: []const u8, action: []const u8) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "[{s}] {s}", .{ shortcut, action }),
        .style = .{ .dim = true },
    };
}

// --- CtrlOToExpand ---
pub fn renderCtrlOToExpand(allocator: std.mem.Allocator) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try allocator.dupe(u8, "Ctrl+O to expand"),
        .style = .{ .dim = true },
    };
}

// --- ContextSuggestions ---
// Renders context suggestions (files the user might want to add).
pub fn renderContextSuggestions(allocator: std.mem.Allocator, suggestions: []const []const u8) !ink_render.RenderCommand {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    try buf.writer.writeAll("Suggested context:\n");
    for (suggestions) |s| {
        try buf.writer.writeAll("  ");
        try buf.writer.writeAll(s);
        try buf.writer.writeByte('\n');
    }
    return .{
        .node_id = 0,
        .text = try allocator.dupe(u8, buf.writer.buffered()),
        .style = .{ .dim = true },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "ToolUseLoader.current cycles frames" {
    var l = ToolUseLoader{};
    try testing.expect(l.current().len > 0);
    const first = l.current();
    l.advance();
    l.advance();
    l.advance();
    l.advance();
    try testing.expectEqualStrings(first, l.current()); // 4-frame cycle
}

test "renderFileEditDiff: prefixes lines with + - or space" {
    const lines = [_]DiffLine{
        .{ .kind = .context, .text = "same" },
        .{ .kind = .added, .text = "new" },
        .{ .kind = .removed, .text = "old" },
    };
    const cmd = try renderFileEditDiff(testing.allocator, &lines);
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, " same") != null);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "+new") != null);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "-old") != null);
}

test "renderFileEditUpdated: includes path + counts, green" {
    const cmd = try renderFileEditUpdated(testing.allocator, "a.zig", 5, 2);
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "a.zig") != null);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "+5") != null);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "-2") != null);
    try testing.expectEqual(ink_render.Color.green, cmd.style.fg.?);
}

test "renderFileEditRejected: yellow with reason" {
    const cmd = try renderFileEditRejected(testing.allocator, "a.zig", "permission denied");
    defer testing.allocator.free(cmd.text);
    try testing.expectEqual(ink_render.Color.yellow, cmd.style.fg.?);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "permission denied") != null);
}

test "renderFallbackToolUseError: red with tool + error" {
    const cmd = try renderFallbackToolUseError(testing.allocator, "Bash", "exit 1");
    defer testing.allocator.free(cmd.text);
    try testing.expectEqual(ink_render.Color.red, cmd.style.fg.?);
}

test "renderCompactSummary: [compacted] prefix, dim+italic" {
    const cmd = try renderCompactSummary(testing.allocator, "did stuff");
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "[compacted]") != null);
    try testing.expect(cmd.style.dim);
    try testing.expect(cmd.style.italic);
}

test "renderInterruptedByUser: yellow+dim" {
    const cmd = try renderInterruptedByUser(testing.allocator);
    defer testing.allocator.free(cmd.text);
    try testing.expectEqual(ink_render.Color.yellow, cmd.style.fg.?);
    try testing.expect(cmd.style.dim);
}

test "renderShortcutHint: includes shortcut + action, dim" {
    const cmd = try renderShortcutHint(testing.allocator, "Ctrl+R", "retry");
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "Ctrl+R") != null);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "retry") != null);
    try testing.expect(cmd.style.dim);
}

test "renderCtrlOToExpand: dim hint text" {
    const cmd = try renderCtrlOToExpand(testing.allocator);
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "Ctrl+O") != null);
    try testing.expect(cmd.style.dim);
}

test "renderContextSuggestions: lists each suggestion" {
    const sugs = [_][]const u8{ "a.zig", "b.zig" };
    const cmd = try renderContextSuggestions(testing.allocator, &sugs);
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "a.zig") != null);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "b.zig") != null);
}
