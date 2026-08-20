//! #575: Ink context components - state containers that React Context
//! provides in the reference.
//!
//! Direct port of reference src/ink/components/{AppContext,StdinContext,
//! TerminalSizeContext,ClockContext,CursorDeclarationContext,
//! TerminalFocusContext}.ts. In the reference these are React Context
//! providers; zcode maps them to plain state structs passed by pointer
//! through the render call graph.

const std = @import("std");

/// AppContext: exposes an exit method (unmount the app). zcode's version
/// carries an exit_requested flag the main loop checks.
pub const AppContext = struct {
    exit_requested: bool = false,
    exit_error: ?[]const u8 = null,

    pub fn requestExit(self: *AppContext, error_msg: ?[]const u8) void {
        self.exit_requested = true;
        self.exit_error = error_msg;
    }
};

/// StdinContext: stdin stream + raw mode support. zcode's version carries
/// the raw-mode state and whether the terminal supports it.
pub const StdinContext = struct {
    is_raw_mode_supported: bool = true,
    is_raw_mode_enabled: bool = false,
    exit_on_ctrl_c: bool = true,

    pub fn setRawMode(self: *StdinContext, enabled: bool) void {
        if (!self.is_raw_mode_supported) return;
        self.is_raw_mode_enabled = enabled;
    }
};

/// TerminalSizeContext: terminal dimensions.
pub const TerminalSizeContext = struct {
    columns: u32 = 80,
    rows: u32 = 24,
};

/// ClockContext: timestamp source for components that need a clock.
pub const ClockContext = struct {
    now_ms: i64 = 0,
};

/// CursorDeclaration: the position of the cursor within a declared node.
pub const CursorDeclaration = struct {
    relative_x: i32 = 0,
    relative_y: i32 = 0,
    node_id: u32 = 0,
};

/// CursorDeclarationContext: setter + current declaration.
pub const CursorDeclarationContext = struct {
    declaration: ?CursorDeclaration = null,

    pub fn set(self: *CursorDeclarationContext, decl: CursorDeclaration) void {
        self.declaration = decl;
    }

    pub fn clear(self: *CursorDeclarationContext) void {
        self.declaration = null;
    }

    pub fn clearIfNode(self: *CursorDeclarationContext, node_id: u32) void {
        if (self.declaration) |d| {
            if (d.node_id == node_id) self.declaration = null;
        }
    }
};

/// TerminalFocusContext: which node has focus.
pub const TerminalFocusContext = struct {
    focused_node_id: ?u32 = null,

    pub fn focus(self: *TerminalFocusContext, node_id: u32) void {
        self.focused_node_id = node_id;
    }

    pub fn blur(self: *TerminalFocusContext) void {
        self.focused_node_id = null;
    }

    pub fn isFocused(self: TerminalFocusContext, node_id: u32) bool {
        return self.focused_node_id != null and self.focused_node_id.? == node_id;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "AppContext.requestExit sets flag and error" {
    var ctx = AppContext{};
    ctx.requestExit("boom");
    try testing.expect(ctx.exit_requested);
    try testing.expectEqualStrings("boom", ctx.exit_error.?);
}

test "StdinContext.setRawMode toggles only when supported" {
    var ctx = StdinContext{ .is_raw_mode_supported = false };
    ctx.setRawMode(true);
    try testing.expect(!ctx.is_raw_mode_enabled);

    var ctx2 = StdinContext{ .is_raw_mode_supported = true };
    ctx2.setRawMode(true);
    try testing.expect(ctx2.is_raw_mode_enabled);
}

test "TerminalSizeContext defaults to 80x24" {
    const ctx = TerminalSizeContext{};
    try testing.expectEqual(@as(u32, 80), ctx.columns);
    try testing.expectEqual(@as(u32, 24), ctx.rows);
}

test "CursorDeclarationContext.set/clear/clearIfNode" {
    var ctx = CursorDeclarationContext{};
    ctx.set(.{ .relative_x = 5, .relative_y = 2, .node_id = 1 });
    try testing.expect(ctx.declaration != null);
    ctx.clearIfNode(99); // different node, no-op
    try testing.expect(ctx.declaration != null);
    ctx.clearIfNode(1); // matches, clears
    try testing.expect(ctx.declaration == null);
}

test "TerminalFocusContext.focus/blur/isFocused" {
    var ctx = TerminalFocusContext{};
    try testing.expect(!ctx.isFocused(1));
    ctx.focus(1);
    try testing.expect(ctx.isFocused(1));
    try testing.expect(!ctx.isFocused(2));
    ctx.blur();
    try testing.expect(!ctx.isFocused(1));
}
