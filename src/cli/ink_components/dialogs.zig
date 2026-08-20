//! #575: Dialog components - confirmation/choice dialogs.
//!
//! Minimal ports of reference src/components/*Dialog.tsx components.
//! All share the pattern: a Dialog frame (bordered box) with a prompt
//! text and a Select (list of choices). zcode's version captures the
//! dialog state (prompt, choices, selected index, confirmed action)
//! and renders via the ink_render module.

const std = @import("std");
const ink_render = @import("../../core/ink_render.zig");
const ink_layout = @import("../../core/ink_layout.zig");

pub const Dialog = struct {
    title: []const u8,
    body: []const u8,
    choices: []const []const u8,
    selected_index: usize = 0,
    confirmed: bool = false,
    cancelled: bool = false,

    pub fn currentChoice(self: Dialog) ?[]const u8 {
        if (self.choices.len == 0) return null;
        return self.choices[self.selected_index];
    }

    pub fn selectNext(self: *Dialog) void {
        if (self.choices.len == 0) return;
        self.selected_index = (self.selected_index + 1) % self.choices.len;
    }

    pub fn selectPrev(self: *Dialog) void {
        if (self.choices.len == 0) return;
        self.selected_index = if (self.selected_index == 0) self.choices.len - 1 else self.selected_index - 1;
    }

    pub fn confirm(self: *Dialog) void {
        self.confirmed = true;
    }

    pub fn cancel(self: *Dialog) void {
        self.cancelled = true;
    }
};

/// Render a Dialog as a sequence of RenderCommands (title, body, each
/// choice with the selected one highlighted via inverse video).
pub fn renderDialog(allocator: std.mem.Allocator, dialog: Dialog) ![]ink_render.RenderCommand {
    var cmds = std.array_list.Managed(ink_render.RenderCommand).init(allocator);
    errdefer {
        for (cmds.items) |c| allocator.free(c.text);
        cmds.deinit();
    }

    // Title (bold)
    try cmds.append(.{
        .node_id = 0,
        .text = try allocator.dupe(u8, dialog.title),
        .style = .{ .bold = true },
    });

    // Body (dim)
    try cmds.append(.{
        .node_id = 1,
        .text = try allocator.dupe(u8, dialog.body),
        .style = .{ .dim = true },
    });

    // Choices (selected = inverse + bold)
    for (dialog.choices, 0..) |choice, i| {
        const is_selected = i == dialog.selected_index;
        const prefix: []const u8 = if (is_selected) "› " else "  ";
        const text = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, choice });
        try cmds.append(.{
            .node_id = @intCast(2 + i),
            .text = text,
            .style = .{ .inverse = is_selected, .bold = is_selected },
        });
    }

    return cmds.toOwnedSlice();
}

pub fn freeDialogCommands(allocator: std.mem.Allocator, cmds: []ink_render.RenderCommand) void {
    for (cmds) |c| allocator.free(c.text);
    allocator.free(cmds);
}

// --- Specific dialogs ---

/// CostThresholdDialog: warns when spend crosses a threshold.
pub const COST_THRESHOLD_BODY = "You've reached the cost threshold. Continue or pause?";

pub fn costThresholdDialog() Dialog {
    return .{
        .title = "Cost threshold reached",
        .body = COST_THRESHOLD_BODY,
        .choices = &.{ "Continue", "Pause and review" },
    };
}

/// AutoModeOptInDialog: prompts the user to opt into auto mode.
pub const AUTO_MODE_DESCRIPTION = "Auto mode lets the agent handle permission prompts automatically - it checks each tool call for risky actions and prompt injection before executing. Actions it identifies as safe are executed; risky ones are blocked. Ideal for long-running tasks. Shift+Tab to change mode.";

pub fn autoModeOptInDialog(decline_exits: bool) Dialog {
    return .{
        .title = "Enable auto mode?",
        .body = AUTO_MODE_DESCRIPTION,
        .choices = if (decline_exits)
            &.{ "Yes, enable auto mode", "No, exit" }
        else
            &.{ "Yes, enable auto mode", "No, keep default mode" },
    };
}

/// BypassPermissionsModeDialog: warns about bypassing all permission checks.
pub const BYPASS_PERMISSIONS_BODY = "Bypass permissions mode skips ALL permission checks. Only use in fully isolated environments. Any tool call will execute without confirmation.";

pub fn bypassPermissionsModeDialog() Dialog {
    return .{
        .title = "Bypass permissions mode",
        .body = BYPASS_PERMISSIONS_BODY,
        .choices = &.{ "I understand, enable bypass", "Cancel" },
    };
}

/// ApproveApiKey: confirms a custom API key.
pub fn approveApiKeyDialog(truncated_key: []const u8, allocator: std.mem.Allocator) !Dialog {
    return .{
        .title = "Approve API key",
        .body = try std.fmt.allocPrint(allocator, "Approve this custom API key ({s}...) for use?", .{truncated_key}),
        .choices = &.{ "Approve", "Reject" },
    };
}

/// IdleReturnDialog: prompts when the user returns after being idle.
pub fn idleReturnDialog(allocator: std.mem.Allocator, idle_minutes: u32, total_input_tokens: u64) !Dialog {
    return .{
        .title = "Welcome back",
        .body = try std.fmt.allocPrint(allocator, "You were idle for {d} minutes. Tokens used so far: {d}.", .{ idle_minutes, total_input_tokens }),
        .choices = &.{ "Continue session", "Clear and start fresh", "Dismiss", "Never show this again" },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Dialog.selectNext cycles through choices" {
    var d = Dialog{ .title = "t", .body = "b", .choices = &.{ "a", "b", "c" } };
    try testing.expectEqualStrings("a", d.currentChoice().?);
    d.selectNext();
    try testing.expectEqualStrings("b", d.currentChoice().?);
    d.selectNext();
    try testing.expectEqualStrings("c", d.currentChoice().?);
    d.selectNext();
    try testing.expectEqualStrings("a", d.currentChoice().?); // wraps
}

test "Dialog.selectPrev cycles backward" {
    var d = Dialog{ .title = "t", .body = "b", .choices = &.{ "a", "b", "c" }, .selected_index = 0 };
    d.selectPrev();
    try testing.expectEqualStrings("c", d.currentChoice().?); // wraps to last
}

test "Dialog.confirm/cancel set flags" {
    var d = Dialog{ .title = "t", .body = "b", .choices = &.{"a"} };
    d.confirm();
    try testing.expect(d.confirmed);
    try testing.expect(!d.cancelled);
    d.cancel();
    try testing.expect(d.cancelled);
}

test "renderDialog: title + body + choices with selected highlighted" {
    const d = Dialog{ .title = "Pick", .body = "Choose one", .choices = &.{ "yes", "no" }, .selected_index = 0 };
    const cmds = try renderDialog(testing.allocator, d);
    defer freeDialogCommands(testing.allocator, cmds);
    try testing.expectEqual(@as(usize, 4), cmds.len); // title + body + 2 choices
    try testing.expect(cmds[0].style.bold); // title is bold
    try testing.expect(cmds[2].style.inverse); // first choice selected
    try testing.expect(!cmds[3].style.inverse); // second not selected
    try testing.expect(std.mem.indexOf(u8, cmds[2].text, "›") != null); // selected prefix
}

test "costThresholdDialog has 2 choices" {
    const d = costThresholdDialog();
    try testing.expectEqual(@as(usize, 2), d.choices.len);
}

test "autoModeOptInDialog: decline_exits changes the second choice" {
    const d1 = autoModeOptInDialog(true);
    try testing.expect(std.mem.indexOf(u8, d1.choices[1], "exit") != null);
    const d2 = autoModeOptInDialog(false);
    try testing.expect(std.mem.indexOf(u8, d2.choices[1], "keep default") != null);
}

test "bypassPermissionsModeDialog has Cancel as second choice" {
    const d = bypassPermissionsModeDialog();
    try testing.expectEqualStrings("Cancel", d.choices[1]);
}

test "approveApiKeyDialog includes the truncated key in the body" {
    const d = try approveApiKeyDialog("sk-abc123", testing.allocator);
    defer testing.allocator.free(d.body);
    try testing.expect(std.mem.indexOf(u8, d.body, "sk-abc123") != null);
}

test "idleReturnDialog includes idle minutes and tokens in the body" {
    const d = try idleReturnDialog(testing.allocator, 30, 5000);
    defer testing.allocator.free(d.body);
    try testing.expect(std.mem.indexOf(u8, d.body, "30") != null);
    try testing.expect(std.mem.indexOf(u8, d.body, "5000") != null);
}
