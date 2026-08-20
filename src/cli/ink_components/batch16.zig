//! #575: Ink component batch 16 - final specialized dirs.
//!
//! Minimal ports covering design-system/, grove/, HelpV2/,
//! FeedbackSurvey/, DesktopUpsell/, ClaudeCodeHint/, PromptInput/,
//! StructuredDiff/, agents/, Settings/.

const std = @import("std");
const ink_render = @import("../../core/ink_render.zig");

// === design-system/ ===

pub fn renderByline(allocator: std.mem.Allocator, author: []const u8, ts: []const u8) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try std.fmt.allocPrint(allocator, "— {s} {s}", .{ author, ts }), .style = .{ .dim = true } };
}

pub fn renderDivider(allocator: std.mem.Allocator, width: u32) !ink_render.RenderCommand {
    // U+2500 (─) is 3 bytes in UTF-8: E2 94 80
    const dash = "─";
    const dash_len = dash.len;
    const buf = try allocator.alloc(u8, width * dash_len);
    var i: u32 = 0;
    while (i < width) : (i += 1) {
        @memcpy(buf[i * dash_len ..][0..dash_len], dash);
    }
    return .{ .node_id = 0, .text = buf, .style = .{ .dim = true } };
}

pub fn renderDialogFrame(allocator: std.mem.Allocator, title: []const u8, body: []const u8) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try std.fmt.allocPrint(allocator, "┌ {s} ┐\n{s}", .{ title, body }), .style = .{} };
}

// === grove/ ===

pub fn renderGrove(allocator: std.mem.Allocator, tree_count: u32) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try std.fmt.allocPrint(allocator, "🌳 Grove: {d} trees", .{tree_count}), .style = .{ .fg = .green, .dim = true } };
}

// === HelpV2/ ===

pub fn renderHelpGeneral(allocator: std.mem.Allocator) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try allocator.dupe(u8, "Type a prompt or /command. Ctrl+O for history, Ctrl+R to retry, Shift+Tab to change mode."),
        .style = .{ .dim = true },
    };
}

pub fn renderHelpCommands(allocator: std.mem.Allocator, commands: []const []const u8) !ink_render.RenderCommand {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    try buf.writer.writeAll("Commands:\n");
    for (commands) |c| try buf.writer.print("  /{s}\n", .{c});
    return .{ .node_id = 0, .text = try allocator.dupe(u8, buf.writer.buffered()), .style = .{} };
}

// === FeedbackSurvey/ ===

pub fn renderFeedbackSurvey(allocator: std.mem.Allocator) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try allocator.dupe(u8, "How was your experience? (1-5 stars, or skip)"),
        .style = .{ .fg = .cyan },
    };
}

pub fn renderTranscriptSharePrompt(allocator: std.mem.Allocator) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try allocator.dupe(u8, "Share your transcript for debugging? (y/n)"),
        .style = .{ .fg = .yellow, .dim = true },
    };
}

// === DesktopUpsell/ ===

pub fn renderDesktopUpsell(allocator: std.mem.Allocator) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try allocator.dupe(u8, "Get the Claude Desktop app for a richer experience."),
        .style = .{ .fg = .magenta, .dim = true },
    };
}

// === ClaudeCodeHint/ ===

pub fn renderPluginHintMenu(allocator: std.mem.Allocator, hints: []const []const u8) !ink_render.RenderCommand {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    try buf.writer.writeAll("Plugin hints:\n");
    for (hints) |h| try buf.writer.print("  • {s}\n", .{h});
    return .{ .node_id = 0, .text = try allocator.dupe(u8, buf.writer.buffered()), .style = .{ .dim = true } };
}

// === PromptInput/ ===

pub fn renderHistorySearchInput(allocator: std.mem.Allocator, query: []const u8) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try std.fmt.allocPrint(allocator, "search history: {s}", .{query}), .style = .{ .dim = true } };
}

pub fn renderIssueFlagBanner(allocator: std.mem.Allocator, issue: []const u8) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try std.fmt.allocPrint(allocator, "⚠ Issue: {s}", .{issue}), .style = .{ .fg = .red, .bold = true } };
}

// === StructuredDiff/ ===

pub const StructuredDiffLine = struct {
    kind: enum { added, removed, context },
    old_text: ?[]const u8 = null,
    new_text: ?[]const u8 = null,
};

pub fn renderStructuredDiff(allocator: std.mem.Allocator, lines: []const StructuredDiffLine) !ink_render.RenderCommand {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    for (lines) |line| {
        switch (line.kind) {
            .added => try buf.writer.print("+ {s}\n", .{line.new_text orelse ""}),
            .removed => try buf.writer.print("- {s}\n", .{line.old_text orelse ""}),
            .context => try buf.writer.print("  {s}\n", .{line.new_text orelse line.old_text orelse ""}),
        }
    }
    return .{ .node_id = 0, .text = try allocator.dupe(u8, buf.writer.buffered()), .style = .{} };
}

pub fn renderStructuredDiffFallback(allocator: std.mem.Allocator, raw: []const u8) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try allocator.dupe(u8, raw), .style = .{ .dim = true } };
}

// === agents/ ===

pub fn renderAgentDetail(allocator: std.mem.Allocator, name: []const u8, description: []const u8) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ name, description }), .style = .{ .bold = true } };
}

pub fn renderAgentEditor(allocator: std.mem.Allocator, name: []const u8) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try std.fmt.allocPrint(allocator, "Editing agent: {s}", .{name}), .style = .{ .fg = .cyan } };
}

pub fn renderAgentNavigationFooter(allocator: std.mem.Allocator, current: u32, total: u32) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try std.fmt.allocPrint(allocator, "[{d}/{d}] ← → to navigate, Esc to exit", .{ current, total }), .style = .{ .dim = true } };
}

// === Settings/ ===

pub fn renderSettings(allocator: std.mem.Allocator, keys: []const []const u8, values: []const []const u8) !ink_render.RenderCommand {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    try buf.writer.writeAll("Settings:\n");
    for (keys, 0..) |k, i| {
        const v: []const u8 = if (i < values.len) values[i] else "";
        try buf.writer.print("  {s} = {s}\n", .{ k, v });
    }
    return .{ .node_id = 0, .text = try allocator.dupe(u8, buf.writer.buffered()), .style = .{} };
}

pub fn renderConfig(allocator: std.mem.Allocator, path: []const u8) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try std.fmt.allocPrint(allocator, "Config: {s}", .{path}), .style = .{ .dim = true } };
}

pub fn renderUsage(allocator: std.mem.Allocator, tokens_used: u64, tokens_limit: u64) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try std.fmt.allocPrint(allocator, "Usage: {d}/{d} tokens", .{ tokens_used, tokens_limit }), .style = .{ .fg = .yellow, .dim = true } };
}

pub fn renderStatus(allocator: std.mem.Allocator, status: []const u8) !ink_render.RenderCommand {
    return .{ .node_id = 0, .text = try std.fmt.allocPrint(allocator, "Status: {s}", .{status}), .style = .{ .fg = .green, .dim = true } };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "renderByline: includes author + ts, dim" {
    const cmd = try renderByline(testing.allocator, "alice", "12:00");
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "alice") != null);
    try testing.expect(cmd.style.dim);
}

test "renderDivider: produces a line of the given width" {
    const cmd = try renderDivider(testing.allocator, 5);
    defer testing.allocator.free(cmd.text);
    // U+2500 is 3 bytes; 5 dashes = 15 bytes
    try testing.expectEqual(@as(usize, 15), cmd.text.len);
}

test "renderGrove: includes tree count" {
    const cmd = try renderGrove(testing.allocator, 3);
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "3 trees") != null);
}

test "renderHelpCommands: lists commands" {
    const cmds = [_][]const u8{ "commit", "review" };
    const cmd = try renderHelpCommands(testing.allocator, &cmds);
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "/commit") != null);
}

test "renderStructuredDiff: prefixes added/removed/context" {
    const lines = [_]StructuredDiffLine{
        .{ .kind = .context, .new_text = "same" },
        .{ .kind = .added, .new_text = "new" },
        .{ .kind = .removed, .old_text = "old" },
    };
    const cmd = try renderStructuredDiff(testing.allocator, &lines);
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "  same") != null);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "+ new") != null);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "- old") != null);
}

test "renderAgentDetail: bold with name + description" {
    const cmd = try renderAgentDetail(testing.allocator, "reviewer", "reviews code");
    defer testing.allocator.free(cmd.text);
    try testing.expect(cmd.style.bold);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "reviewer") != null);
}

test "renderUsage: includes tokens used + limit" {
    const cmd = try renderUsage(testing.allocator, 500, 1000);
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "500/1000") != null);
}

test "renderIssueFlagBanner: red+bold" {
    const cmd = try renderIssueFlagBanner(testing.allocator, "build broke");
    defer testing.allocator.free(cmd.text);
    try testing.expectEqual(ink_render.Color.red, cmd.style.fg.?);
    try testing.expect(cmd.style.bold);
}

test "renderSettings: lists key=value pairs" {
    const keys = [_][]const u8{ "model", "theme" };
    const vals = [_][]const u8{ "opus", "dark" };
    const cmd = try renderSettings(testing.allocator, &keys, &vals);
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "model = opus") != null);
}
