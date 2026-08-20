//! #574: ink_focus deep module - focus and input management.
//!
//! Tracks focus state across a node tree, dispatches keyboard input to
//! the focused node, handles focus traversal (tab/shift-tab).
//!
//! DOCUMENTED DEVIATION: full Ink focus (focus groups, focus trapping,
//! pointer events, the reconciler's focus diffing) is multi-month.
//! This module implements the core: a focus ring of node IDs, tab to
//! advance, shift-tab to reverse, direct focus(id) to set explicitly.
//!
//! Pure module: state in, state out. No IO.

const std = @import("std");

pub const FocusState = struct {
    focusable_ids: []const u32,
    focused_index: usize = 0,

    pub fn current(self: FocusState) ?u32 {
        if (self.focusable_ids.len == 0) return null;
        return self.focusable_ids[self.focused_index];
    }

    /// Advance focus to the next focusable node (Tab key).
    pub fn advance(self: *FocusState) void {
        if (self.focusable_ids.len == 0) return;
        self.focused_index = (self.focused_index + 1) % self.focusable_ids.len;
    }

    /// Reverse focus to the previous focusable node (Shift+Tab).
    pub fn reverse(self: *FocusState) void {
        if (self.focusable_ids.len == 0) return;
        self.focused_index = if (self.focused_index == 0)
            self.focusable_ids.len - 1
        else
            self.focused_index - 1;
    }

    /// Focus a specific node by id. Returns true if the id is focusable.
    pub fn focus(self: *FocusState, id: u32) bool {
        for (self.focusable_ids, 0..) |fid, i| {
            if (fid == id) {
                self.focused_index = i;
                return true;
            }
        }
        return false;
    }

    /// Returns true if the given id is currently focused.
    pub fn isFocused(self: FocusState, id: u32) bool {
        if (self.current()) |cur| return cur == id;
        return false;
    }
};

pub const KeyAction = enum {
    tab,
    shift_tab,
    enter,
    escape,
    other,
};

/// Parse a raw key byte sequence into a KeyAction. Minimal: only handles
/// Tab (\t), Shift+Tab (\x1b[Z), Enter (\r or \n), Escape (\x1b).
pub fn parseKey(bytes: []const u8) KeyAction {
    if (bytes.len == 0) return .other;
    if (std.mem.eql(u8, bytes, "\t")) return .tab;
    if (std.mem.eql(u8, bytes, "\x1b[Z")) return .shift_tab;
    if (std.mem.eql(u8, bytes, "\r") or std.mem.eql(u8, bytes, "\n")) return .enter;
    if (std.mem.eql(u8, bytes, "\x1b")) return .escape;
    return .other;
}

/// Apply a key action to focus state. Returns the key action for the
/// caller to also dispatch to the focused node's content handler.
pub fn handleKey(state: *FocusState, action: KeyAction) KeyAction {
    switch (action) {
        .tab => state.advance(),
        .shift_tab => state.reverse(),
        else => {},
    }
    return action;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "FocusState.current returns null for empty focus ring" {
    const state = FocusState{ .focusable_ids = &.{} };
    try testing.expect(state.current() == null);
}

test "FocusState.current returns first id by default" {
    const ids = [_]u32{ 1, 2, 3 };
    const state = FocusState{ .focusable_ids = &ids };
    try testing.expectEqual(@as(u32, 1), state.current().?);
}

test "advance moves focus forward" {
    const ids = [_]u32{ 1, 2, 3 };
    var state = FocusState{ .focusable_ids = &ids };
    state.advance();
    try testing.expectEqual(@as(u32, 2), state.current().?);
    state.advance();
    try testing.expectEqual(@as(u32, 3), state.current().?);
}

test "advance wraps from last to first" {
    const ids = [_]u32{ 1, 2, 3 };
    var state = FocusState{ .focusable_ids = &ids, .focused_index = 2 };
    state.advance();
    try testing.expectEqual(@as(u32, 1), state.current().?);
}

test "reverse moves focus backward" {
    const ids = [_]u32{ 1, 2, 3 };
    var state = FocusState{ .focusable_ids = &ids, .focused_index = 2 };
    state.reverse();
    try testing.expectEqual(@as(u32, 2), state.current().?);
}

test "reverse wraps from first to last" {
    const ids = [_]u32{ 1, 2, 3 };
    var state = FocusState{ .focusable_ids = &ids, .focused_index = 0 };
    state.reverse();
    try testing.expectEqual(@as(u32, 3), state.current().?);
}

test "focus(id) sets focus explicitly" {
    const ids = [_]u32{ 1, 2, 3 };
    var state = FocusState{ .focusable_ids = &ids };
    try testing.expect(state.focus(3));
    try testing.expectEqual(@as(u32, 3), state.current().?);
}

test "focus(id) returns false for non-focusable id" {
    const ids = [_]u32{ 1, 2, 3 };
    var state = FocusState{ .focusable_ids = &ids };
    try testing.expect(!state.focus(99));
}

test "isFocused returns true for current, false for others" {
    const ids = [_]u32{ 1, 2, 3 };
    var state = FocusState{ .focusable_ids = &ids };
    try testing.expect(state.focus(2));
    try testing.expect(state.isFocused(2));
    try testing.expect(!state.isFocused(1));
    try testing.expect(!state.isFocused(3));
}

test "parseKey: Tab" {
    try testing.expectEqual(KeyAction.tab, parseKey("\t"));
}

test "parseKey: Shift+Tab" {
    try testing.expectEqual(KeyAction.shift_tab, parseKey("\x1b[Z"));
}

test "parseKey: Enter (\\r and \\n)" {
    try testing.expectEqual(KeyAction.enter, parseKey("\r"));
    try testing.expectEqual(KeyAction.enter, parseKey("\n"));
}

test "parseKey: Escape" {
    try testing.expectEqual(KeyAction.escape, parseKey("\x1b"));
}

test "parseKey: other for unrecognized" {
    try testing.expectEqual(KeyAction.other, parseKey("a"));
    try testing.expectEqual(KeyAction.other, parseKey(""));
}

test "handleKey: tab advances focus" {
    const ids = [_]u32{ 1, 2, 3 };
    var state = FocusState{ .focusable_ids = &ids };
    _ = handleKey(&state, .tab);
    try testing.expectEqual(@as(u32, 2), state.current().?);
}

test "handleKey: shift_tab reverses focus" {
    const ids = [_]u32{ 1, 2, 3 };
    var state = FocusState{ .focusable_ids = &ids, .focused_index = 2 };
    _ = handleKey(&state, .shift_tab);
    try testing.expectEqual(@as(u32, 2), state.current().?);
}

test "handleKey: enter does not change focus" {
    const ids = [_]u32{ 1, 2, 3 };
    var state = FocusState{ .focusable_ids = &ids };
    _ = handleKey(&state, .enter);
    try testing.expectEqual(@as(u32, 1), state.current().?);
}
