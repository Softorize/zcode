const std = @import("std");
const rt = @import("zcode_runtime");
const clock = @import("../core/clock.zig");
const std_io = @import("../core/std_io.zig");
const format = @import("../core/format.zig");
const output_styles = @import("../core/output_styles.zig");
const ui_theme = @import("../core/ui_theme.zig");
const keybindings = @import("keybindings.zig");
const permission_decision = @import("../core/permission_decision.zig");
const permission_mode_cycle = @import("../core/permission_mode_cycle.zig");
const idle_return = @import("../core/idle_return.zig");
const repl_history = @import("repl_history.zig");
const repl_global_search = @import("repl_global_search.zig");
const repl_input = @import("repl_input.zig");
const repl_quick_open = @import("repl_quick_open.zig");
const repl_markdown = @import("repl_markdown.zig");
const repl_spinner_mod = @import("repl_spinner.zig");
const fuzzy = @import("../core/parse_helpers.zig");

// ── Overlay UI module ──
// Extracted from repl.zig: all fullscreen overlay UIs (approval prompt,
// ask-user prompt, plan review, model picker).

// ── Types ──

pub const ApprovalChoice = enum {
    approve,
    approve_always,
    deny,
    cancel,
};

pub const ApprovalNavEvent = enum {
    none,
    left,
    right,
    select,
    approve,
    approve_always,
    deny,
    cancel,
    // P3 (PRD #534): Shift+Tab (back-tab, ESC [ Z) cycles the permission mode
    // the pending decision is evaluated under, mirroring the reference's
    // confirm_cycle_mode shortcut.
    cycle_mode,
};

pub const PlanAction = enum {
    approve,
    discuss,
    cancel,
};

pub const ModelPickerItem = struct {
    id: []const u8,
    ctx: usize,
};

pub const ModelPickerData = struct {
    allocator: std.mem.Allocator,
    active_provider: []const u8,
    active_model: []const u8,
    items: []ModelPickerItem,

    pub fn deinit(self: *ModelPickerData) void {
        self.allocator.free(self.items);
    }
};

pub const HistorySearchData = struct {
    allocator: std.mem.Allocator,
    items: []repl_history.SearchItem,

    pub fn deinit(self: *HistorySearchData) void {
        repl_history.freeSearchItems(self.allocator, self.items);
    }
};

pub const QuickOpenData = repl_quick_open.Data;

pub const QuickOpenAction = enum {
    open_in_editor,
    mention_path,
    insert_path,
};

pub const QuickOpenResult = struct {
    item_index: usize,
    action: QuickOpenAction,
};

pub const GlobalSearchData = repl_global_search.Data;

pub const GlobalSearchAction = enum {
    open_in_editor,
    mention_reference,
    insert_reference,
};

pub const GlobalSearchResult = struct {
    path: []u8,
    line: usize,
    action: GlobalSearchAction,

    pub fn deinit(self: *GlobalSearchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const ThemePickerData = struct {
    current_setting: ui_theme.ThemeSetting,
    syntax_highlighting: bool,
};

pub const ThemePickerResult = struct {
    setting: ui_theme.ThemeSetting,
    syntax_highlighting: bool,
};

pub const TodoOverlayData = struct {
    title: []const u8 = "Tasks",
    text: []const u8,
    empty_text: []const u8 = "todos: none",
    close_hint: []const u8 = "Esc/Ctrl+T close",
};

pub const BackgroundTaskItem = struct {
    id: []u8,
    title: []u8,
    status: []u8,
    summary: []u8,
    command: []u8,
    owner: []u8,
    priority: []u8,
    detail: []u8,
    progress: u8,
    run_pid: i64,
    updated_ts: i64,

    pub fn deinit(self: *BackgroundTaskItem, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.status);
        allocator.free(self.summary);
        allocator.free(self.command);
        allocator.free(self.owner);
        allocator.free(self.priority);
        allocator.free(self.detail);
    }
};

pub const BackgroundTasksData = struct {
    allocator: std.mem.Allocator,
    items: []BackgroundTaskItem,
    initial_selection: usize = 0,

    pub fn deinit(self: *BackgroundTasksData) void {
        for (self.items) |*item| item.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

pub const BackgroundTasksAction = enum {
    view,
    stop,
    refresh,
};

pub const BackgroundTasksResult = struct {
    item_index: usize = 0,
    action: BackgroundTasksAction,
};

pub const TranscriptOverlayData = struct {
    allocator: std.mem.Allocator,
    text: []const u8,
};

pub const StylePickerData = struct {
    allocator: std.mem.Allocator,
    current_style: []const u8,
    items: []output_styles.OutputStyle,

    pub fn deinit(self: *StylePickerData) void {
        output_styles.freeList(self.allocator, self.items);
    }
};

pub const CommandPaletteItem = struct {
    id: []u8,
    title: []u8,
    detail: []u8,
    shortcut: []u8,
    category: []u8,
    state: []u8,

    pub fn deinit(self: *CommandPaletteItem, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.detail);
        allocator.free(self.shortcut);
        allocator.free(self.category);
        allocator.free(self.state);
    }
};

pub const CommandPaletteData = struct {
    allocator: std.mem.Allocator,
    title: []const u8 = "Command Palette",
    items: []CommandPaletteItem,
    initial_selection: usize = 0,

    pub fn deinit(self: *CommandPaletteData) void {
        for (self.items) |*item| item.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

pub const RuntimePanelData = CommandPaletteData;

pub const SessionSwitcherItem = struct {
    id: []u8,
    label: []u8,
    updated_summary: []u8,
    is_current: bool,

    pub fn deinit(self: *SessionSwitcherItem, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
        allocator.free(self.updated_summary);
    }
};

pub const SessionSwitcherData = struct {
    allocator: std.mem.Allocator,
    title: []const u8 = "Session Switcher",
    items: []SessionSwitcherItem,
    initial_selection: usize = 0,

    pub fn deinit(self: *SessionSwitcherData) void {
        for (self.items) |*item| item.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

pub const MessageSelectorItem = struct {
    history_index: usize,
    prompt: []u8,
};

pub const MessageSelectorData = struct {
    allocator: std.mem.Allocator,
    items: []MessageSelectorItem,
    initial_selection: usize = 0,

    pub fn deinit(self: *MessageSelectorData) void {
        for (self.items) |item| self.allocator.free(item.prompt);
        self.allocator.free(self.items);
    }
};

pub const MessageActionsItemKind = enum {
    user,
    assistant,
    section,
};

pub const MessageActionsItem = struct {
    kind: MessageActionsItemKind,
    label: []u8,
    content: []u8,
};

pub const MessageActionsData = struct {
    allocator: std.mem.Allocator,
    items: []MessageActionsItem,
    initial_selection: usize = 0,

    pub fn deinit(self: *MessageActionsData) void {
        for (self.items) |item| {
            self.allocator.free(item.label);
            self.allocator.free(item.content);
        }
        self.allocator.free(self.items);
    }
};

pub const MessageActionsAction = enum {
    primary,
    copy,
};

pub const MessageActionsResult = struct {
    item_index: usize,
    action: MessageActionsAction,
};

// ── Terminal helpers ──

// Terminal sizing lives in repl_spinner (the lowest-level UI module);
// repl.zig and repl_agent.zig already delegate to it. These thin
// wrappers keep the local call sites unchanged while removing the
// duplicate ioctl bodies, so resize/SIGWINCH behaviour has one home.
fn terminalRows() usize {
    return repl_spinner_mod.terminalRows();
}

fn terminalCols() usize {
    return repl_spinner_mod.terminalCols();
}

fn boundedBottomMarginRows(total_rows: usize, requested: usize) usize {
    return repl_spinner_mod.boundedBottomMarginRows(total_rows, requested);
}

// ── Buffer helpers ──

pub fn appendLiteral(buf: []u8, pos: *usize, literal: []const u8) void {
    const end = pos.* + literal.len;
    if (end > buf.len) return;
    @memcpy(buf[pos.*..end], literal);
    pos.* = end;
}

pub fn appendRepeatByte(buf: []u8, pos: *usize, unit: []const u8, count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        appendLiteral(buf, pos, unit);
    }
}

pub fn appendCursorTo(buf: []u8, pos: *usize, row: usize) void {
    var tmp: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "\x1b[{d};1H", .{row}) catch return;
    appendLiteral(buf, pos, s);
}

// Identical to repl_spinner.sanitizeText (strip ANSI/CSI, tabs -> 4
// spaces, drop other control bytes). Delegate so the rule has one home.
fn sanitizeText(input: []const u8, out: []u8) []const u8 {
    return repl_spinner_mod.sanitizeText(input, out);
}

fn readOneByte(fd: std.posix.fd_t) !u8 {
    var byte: [1]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &byte) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) return error.EndOfStream;
        logInputByte("overlay", byte[0]);
        return byte[0];
    }
}

/// ZCODE_DEBUG_INPUT instrumentation, mirrored from repl_input so
/// overlay reads show up in the same log file. Zero-cost when the
/// env var is unset.
var debug_log_overlay: ?std.Io.File = null;
var debug_log_overlay_checked: bool = false;

fn logInputByte(tag: []const u8, byte: u8) void {
    if (!debug_log_overlay_checked) {
        debug_log_overlay_checked = true;
        const path = @import("../core/env.zig").getenv("ZCODE_DEBUG_INPUT") orelse return;
        if (path.len == 0) return;
        const f = std.Io.Dir.cwd().createFile(rt.io, path, .{ .truncate = false }) catch return;
        // 0.16: no seek; writes go positional
        debug_log_overlay = f;
    }
    const log = debug_log_overlay orelse return;
    var buf: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[{s}] 0x{x:0>2} ({d})\n", .{ tag, byte, byte }) catch return;
    _ = log.writeStreamingAll(rt.io, line) catch {};
}

// ── Inline approval prompt (non-fullscreen) ──

pub fn runInlineApprovalPrompt(message: []const u8) !ApprovalChoice {
    const stdout = std_io.stdoutWriter();
    const stdin = std_io.stdinReader();

    try stdout.print("{s}\n", .{message});
    try stdout.writeAll("Select: 1) Approve  2) Always  3) Deny  4) Cancel [default: 3] > ");

    var buf: [16]u8 = undefined;
    var len: usize = 0;
    while (true) {
        const b = stdin.readByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (b == '\n' or b == '\r') break;
        if (len < buf.len) {
            buf[len] = b;
            len += 1;
        }
    }
    try stdout.writeByte('\n');

    const trimmed = std.mem.trim(u8, buf[0..len], " \t\r\n");
    if (trimmed.len == 0) return .deny;
    if (trimmed[0] == '1' or trimmed[0] == 'y' or trimmed[0] == 'Y') return .approve;
    if (trimmed[0] == '2' or trimmed[0] == 'a' or trimmed[0] == 'A') return .approve_always;
    if (trimmed[0] == '4' or trimmed[0] == 'c' or trimmed[0] == 'C') return .cancel;
    return .deny;
}

// ── Fullscreen approval overlay ──

/// Pure permission-mode cycle helper, factored out so the overlay state machine
/// is testable without driving the terminal. Applies getNext `n` times starting
/// from `initial`, mirroring N Shift+Tab presses inside the overlay (P3, PRD
/// #534).
pub fn applyModeCycles(initial: permission_decision.Mode, n: usize, bypass_available: bool) permission_decision.Mode {
    var mode = initial;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        mode = permission_mode_cycle.getNext(mode, bypass_available);
    }
    return mode;
}

pub fn runApprovalOverlayLoop(message: []const u8, bottom_margin_rows: usize) !ApprovalChoice {
    return runApprovalOverlayLoopWithMode(message, bottom_margin_rows, null, false);
}

/// Approval overlay loop with optional live permission-mode cycling. When
/// `mode` is non-null, Shift+Tab (back-tab) cycles it in place via
/// `permission_mode_cycle.getNext`, the header re-renders with the new mode's
/// short label, and the loop continues -- the selected button is unchanged so
/// the safety default (Deny) is preserved across cycles. The caller re-runs the
/// decision under the mutated mode after the overlay returns.
pub fn runApprovalOverlayLoopWithMode(
    message: []const u8,
    bottom_margin_rows: usize,
    mode: ?*permission_decision.Mode,
    bypass_available: bool,
) !ApprovalChoice {
    const fd = std.Io.File.stdin().handle;
    var selected: usize = 2; // default to Deny for safety (0=Approve, 1=Always, 2=Deny, 3=Cancel).

    while (true) {
        renderApprovalOverlay(message, selected, bottom_margin_rows, if (mode) |m| m.* else null);
        const nav = readApprovalNavEvent(fd) catch return .cancel;
        switch (nav) {
            .left => selected = if (selected == 0) 3 else selected - 1,
            .right => selected = (selected + 1) % 4,
            .cycle_mode => {
                // Cycle the permission mode in place; keep the selected button so
                // the Deny safety default is not disturbed. No-op when the caller
                // did not pass a mode pointer.
                if (mode) |m| m.* = permission_mode_cycle.getNext(m.*, bypass_available);
            },
            .select => {
                clearApprovalOverlay(bottom_margin_rows);
                return switch (selected) {
                    0 => .approve,
                    1 => .approve_always,
                    2 => .deny,
                    else => .cancel,
                };
            },
            .approve => {
                clearApprovalOverlay(bottom_margin_rows);
                return .approve;
            },
            .approve_always => {
                clearApprovalOverlay(bottom_margin_rows);
                return .approve_always;
            },
            .deny => {
                clearApprovalOverlay(bottom_margin_rows);
                return .deny;
            },
            .cancel => {
                clearApprovalOverlay(bottom_margin_rows);
                return .cancel;
            },
            .none => {},
        }
    }
}

fn renderApprovalOverlay(message: []const u8, selected: usize, bottom_margin_rows: usize, mode: ?permission_decision.Mode) void {
    const rows = terminalRows();
    const cols = terminalCols();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;
    const border_row = if (status_row > 3) status_row - 3 else 1;
    const options_row = if (border_row > 1) border_row - 1 else 1;
    const question_row = if (options_row > 1) options_row - 1 else 1;

    var safe_msg_buf: [240]u8 = undefined;
    const safe_msg = sanitizeText(std.mem.trim(u8, message, " \t\r\n"), safe_msg_buf[0..]);

    // Brand-accent rail (mint) + dim label + bright message. The user's
    // eye lands on the brand rail, reads the label quietly as metadata,
    // then locks on the actual risk description which is the decision
    // the user must make. "Permission" reads more human than the old
    // "approval needed" and matches Claude Code's own phrasing.
    //
    // When a live permission mode is supplied (P3, PRD #534), its short label
    // is shown as a dim trailing chip so the user sees Shift+Tab cycle the mode.
    var question_buf: [360]u8 = undefined;
    const question_full = if (mode) |m| std.fmt.bufPrint(
        &question_buf,
        "\x1b[38;2;95;212;160m\xe2\x94\x83\x1b[0m \x1b[2mPermission\x1b[0m  \x1b[1m{s}\x1b[0m  \x1b[2m[{s}]\x1b[0m",
        .{ safe_msg, permission_mode_cycle.shortLabel(m) },
    ) catch "Permission" else std.fmt.bufPrint(
        &question_buf,
        "\x1b[38;2;95;212;160m\xe2\x94\x83\x1b[0m \x1b[2mPermission\x1b[0m  \x1b[1m{s}\x1b[0m",
        .{safe_msg},
    ) catch "Permission";
    const draw_cols = if (cols > 1) cols - 1 else cols;
    const question = question_full[0..@min(question_full.len, draw_cols)];

    var options_buf: [240]u8 = undefined;
    const options_full = buildApprovalOptionsLine(&options_buf, selected);
    const options_line = options_full[0..@min(options_full.len, draw_cols)];

    var seq: [1024]u8 = undefined;
    const frame = std.fmt.bufPrint(
        &seq,
        "\x1b7\x1b[{d};1H\x1b[2K{s}\x1b[{d};1H\x1b[2K{s}\x1b8",
        .{ question_row, question, options_row, options_line },
    ) catch return;
    _ = std.c.write(std.Io.File.stdout().handle, (frame).ptr, (frame).len);
}

pub fn clearApprovalOverlay(bottom_margin_rows: usize) void {
    const rows = terminalRows();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;
    const border_row = if (status_row > 3) status_row - 3 else 1;
    const options_row = if (border_row > 1) border_row - 1 else 1;
    const question_row = if (options_row > 1) options_row - 1 else 1;

    var seq: [256]u8 = undefined;
    const clear = std.fmt.bufPrint(
        &seq,
        "\x1b7\x1b[{d};1H\x1b[2K\x1b[{d};1H\x1b[2K\x1b8",
        .{ question_row, options_row },
    ) catch return;
    _ = std.c.write(std.Io.File.stdout().handle, (clear).ptr, (clear).len);
}

pub fn buildApprovalOptionsLine(out: []u8, selected: usize) []const u8 {
    // Refactoring-UI hierarchy: the four choices are NOT equally
    // prominent. Approve is the primary action (brand mint, filled
    // when selected). Deny is a warning action (soft red, filled when
    // selected). Always / Cancel are tertiary (dim, outlined only
    // when selected). Selected buttons use inverse-video fill so the
    // current choice reads as a solid block at a glance -- no need to
    // hunt for a triangle marker. Unselected buttons are dim plain
    // text and stay out of the way.
    //
    // Grouping: "Approve  Always" sit tight as the "accept" pair,
    // then a wider gap before "Deny  Cancel" as the "reject" pair.
    // Keyboard hint is tertiary (dim) metadata.
    const accent_mint = "\x1b[48;2;95;212;160m\x1b[38;2;11;18;22m\x1b[1m";
    const accent_red = "\x1b[48;2;217;95;114m\x1b[38;2;11;18;22m\x1b[1m";
    const outline = "\x1b[38;2;200;210;220m\x1b[1m";
    const dim_btn = "\x1b[2m";
    const reset = "\x1b[0m";

    const approve = if (selected == 0)
        accent_mint ++ " Approve " ++ reset
    else
        dim_btn ++ " Approve " ++ reset;
    const always = if (selected == 1)
        outline ++ " Always " ++ reset
    else
        dim_btn ++ " Always " ++ reset;
    const deny = if (selected == 2)
        accent_red ++ " Deny " ++ reset
    else
        dim_btn ++ " Deny " ++ reset;
    const cancel = if (selected == 3)
        outline ++ " Cancel " ++ reset
    else
        dim_btn ++ " Cancel " ++ reset;

    const rail = "\x1b[38;2;95;212;160m\xe2\x94\x83\x1b[0m";
    // Keyboard hint groups: "←→ Enter" for nav + "Y/A/N Esc" for
    // direct keys. The soft arrows and slash separators read better
    // than a bare whitespace-delimited token list.
    return std.fmt.bufPrint(
        out,
        "{s} {s} {s}   {s} {s}   \x1b[2m\xe2\x86\x90\xe2\x86\x92 Enter  \xc2\xb7  Y/A/N/Esc\x1b[0m",
        .{ rail, approve, always, deny, cancel },
    ) catch "approval";
}

pub fn readApprovalNavEvent(fd: std.posix.fd_t) !ApprovalNavEvent {
    const ch = try readOneByte(fd);
    return switch (ch) {
        '\r', '\n' => .select,
        '\t' => .right,
        0x03, 0x04 => .cancel,
        'y', 'Y' => .approve,
        'a', 'A' => .approve_always,
        'n', 'N' => .deny,
        0x1b => parseApprovalEscape(fd),
        else => .none,
    };
}

fn parseApprovalEscape(fd: std.posix.fd_t) ApprovalNavEvent {
    // Check if more bytes follow within 30ms. If not, it's a bare Escape = cancel.
    var poll_fds = [1]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&poll_fds, 30) catch 0;
    if (ready == 0) return .cancel;

    const second = readOneByte(fd) catch return .cancel;
    if (second != '[') return .cancel;

    // Capture the CSI parameter bytes plus the final byte so we can recognise
    // both the legacy back-tab form (ESC [ Z) and the Kitty form
    // (ESC [ 9 ; <mods> u) for Shift+Tab. The parameter bytes were previously
    // discarded, which silently dropped Kitty Shift+Tab in this overlay.
    var seq: [32]u8 = undefined;
    var len: usize = 0;
    var final = readOneByte(fd) catch return .none;
    while (!(final >= 0x40 and final <= 0x7E)) {
        if (len < seq.len) {
            seq[len] = final;
            len += 1;
        }
        if (len >= seq.len) return .none;
        final = readOneByte(fd) catch return .none;
    }

    // Kitty keyboard protocol: CSI <codepoint>;<mods>u. Tab is codepoint 9;
    // mods > 1 means a modifier (Shift) was held -> Shift+Tab.
    if (final == 'u') {
        if (repl_input.parseKittyKeyPayload(seq[0..len])) |key| {
            if (key.codepoint == 9 and key.mods > 1) return .cycle_mode;
        }
        return .none;
    }

    return switch (final) {
        // Back-tab (Shift+Tab) cycles the permission mode rather than moving the
        // button selection left (P3, PRD #534).
        'Z' => .cycle_mode,
        'A', 'D' => .left,
        'B', 'C' => .right,
        else => .none,
    };
}

// ── Inline ask-user prompt (non-fullscreen) ──

pub fn runInlineAskUserPrompt(allocator: std.mem.Allocator, question: []const u8, choices: []const []const u8) ![]u8 {
    const stdout = std_io.stdoutWriter();
    const stdin = std_io.stdinReader();

    try stdout.print("question: {s}\n", .{question});
    for (choices, 0..) |choice, idx| {
        try stdout.print("  {d}) {s}\n", .{ idx + 1, choice });
    }
    try stdout.writeAll("Select option number [default: 1] > ");

    var buf: [64]u8 = undefined;
    var len: usize = 0;
    while (true) {
        const b = stdin.readByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (b == '\n' or b == '\r') break;
        if (len < buf.len) {
            buf[len] = b;
            len += 1;
        }
    }
    try stdout.writeByte('\n');

    const trimmed = std.mem.trim(u8, buf[0..len], " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, choices[0]);
    const idx = std.fmt.parseInt(usize, trimmed, 10) catch 0;
    if (idx >= 1 and idx <= choices.len) return allocator.dupe(u8, choices[idx - 1]);
    return allocator.dupe(u8, trimmed);
}

// ── Fullscreen ask-user overlay ──

pub fn runAskUserOverlayLoop(allocator: std.mem.Allocator, question: []const u8, choices: []const []const u8, bottom_margin_rows: usize) ![]u8 {
    const default_contexts = [_]keybindings.BindingContext{ .Confirmation, .Select };
    return runAskUserOverlayLoopWithBindings(allocator, question, choices, bottom_margin_rows, null, &default_contexts);
}

pub fn runAskUserOverlayLoopWithBindings(
    allocator: std.mem.Allocator,
    question: []const u8,
    choices: []const []const u8,
    bottom_margin_rows: usize,
    bindings: ?*const keybindings.RuntimeKeybindings,
    contexts: []const keybindings.BindingContext,
) ![]u8 {
    const fd = std.Io.File.stdin().handle;
    var selected: usize = 0;

    while (true) {
        renderAskUserOverlay(question, choices, selected, bottom_margin_rows);
        var chord_buf: [24]u8 = undefined;
        const key = readPickerKey(fd, &chord_buf) catch return allocator.dupe(u8, "cancel");
        const ev = resolvePickerBinding(bindings, contexts, key.chord, key.event);

        switch (ev) {
            .up => {
                if (choices.len > 0) selected = if (selected == 0) choices.len - 1 else selected - 1;
            },
            .down, .next, .tab, .shift_tab => {
                if (choices.len > 0) selected = (selected + 1) % choices.len;
            },
            .select, .toggle => {
                clearApprovalOverlay(bottom_margin_rows);
                if (choices.len == 0) return allocator.dupe(u8, "continue");
                return allocator.dupe(u8, choices[selected]);
            },
            .cancel => {
                clearApprovalOverlay(bottom_margin_rows);
                if (choices.len == 0) return allocator.dupe(u8, "cancel");
                const fallback = if (choices.len >= 2) choices[1] else choices[selected];
                return allocator.dupe(u8, fallback);
            },
            .char => {
                if ((key.char == 'q' or key.char == 'Q') and choices.len == 0) {
                    clearApprovalOverlay(bottom_margin_rows);
                    return allocator.dupe(u8, "cancel");
                }
            },
            .backspace, .none => {},
        }
    }
}

fn renderAskUserOverlay(question: []const u8, choices: []const []const u8, selected: usize, bottom_margin_rows: usize) void {
    const rows = terminalRows();
    const cols = terminalCols();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;
    const border_row = if (status_row > 3) status_row - 3 else 1;
    const options_row = if (border_row > 1) border_row - 1 else 1;
    const question_row = if (options_row > 1) options_row - 1 else 1;

    var safe_q_buf: [320]u8 = undefined;
    const safe_q = sanitizeText(std.mem.trim(u8, question, " \t\r\n"), safe_q_buf[0..]);

    var question_buf: [420]u8 = undefined;
    const question_full = std.fmt.bufPrint(&question_buf, "\xe2\x94\x82 \x1b[36mquestion:\x1b[0m {s}", .{safe_q}) catch "question";
    const draw_cols = if (cols > 1) cols - 1 else cols;
    const q_line = question_full[0..@min(question_full.len, draw_cols)];

    var options_buf: [640]u8 = undefined;
    const options_full = buildAskUserOptionsLine(&options_buf, choices, selected);
    const options_line = options_full[0..@min(options_full.len, draw_cols)];

    var seq: [1400]u8 = undefined;
    const frame = std.fmt.bufPrint(
        &seq,
        "\x1b7\x1b[{d};1H\x1b[2K{s}\x1b[{d};1H\x1b[2K{s}\x1b8",
        .{ question_row, q_line, options_row, options_line },
    ) catch return;
    _ = std.c.write(std.Io.File.stdout().handle, (frame).ptr, (frame).len);
}

pub fn buildAskUserOptionsLine(out: []u8, choices: []const []const u8, selected: usize) []const u8 {
    var fbs = std.Io.Writer.fixed(out);
    const w = &fbs;
    w.writeAll("\xe2\x94\x82 ") catch {}; // box char
    if (choices.len == 0) {
        w.writeAll("\x1b[2m(Press Enter to continue, Esc to cancel)\x1b[0m") catch {};
        return out[0..fbs.end];
    }
    for (choices, 0..) |choice, idx| {
        if (idx > 0) w.writeAll("  ") catch {};
        if (idx == selected) {
            w.print("\x1b[38;5;114m\x1b[1m\xe2\x96\xb8 {s}\x1b[0m", .{choice}) catch {};
        } else {
            w.print("  {s}", .{choice}) catch {};
        }
    }
    w.writeAll("  \x1b[2m(\xe2\x86\x90\xe2\x86\x92 navigate, Enter select, Esc cancel)\x1b[0m") catch {};
    return out[0..fbs.end];
}

// ── Trust-gate overlay (ui-dialogs-01) ──

/// Number of body lines the trust gate reserves above the title row. Capping the
/// rendered capability list keeps the overlay inside the bottom margin even when
/// a workspace enumerates many capabilities; the remainder are summarized with a
/// trailing "+N more" line.
const TRUST_GATE_MAX_BODY_ROWS: usize = 8;

/// Fullscreen trust-gate overlay (ui-dialogs-01). Renders a title, a list of the
/// detected dangerous-capability lines (NAMES / paths only -- the caller is
/// responsible for never passing secret values), and a two-choice Select. The
/// `choices` are typically `["No, exit", "Yes, proceed"]`. Returns the selected
/// index. Esc / Ctrl-C / Ctrl-D map to the FIRST choice ("No, exit"), so the
/// safe default on a stray keystroke is to decline trust, mirroring the
/// reference's `gracefulShutdownSync(1)` on decline.
pub fn runTrustGateOverlayLoop(
    title: []const u8,
    body_lines: []const []const u8,
    choices: []const []const u8,
    bottom_margin_rows: usize,
) !usize {
    const fd = std.Io.File.stdin().handle;
    var selected: usize = 0; // default to the first ("No, exit") for safety.

    while (true) {
        renderTrustGateOverlay(title, body_lines, choices, selected, bottom_margin_rows);
        var chord_buf: [24]u8 = undefined;
        const key = readPickerKey(fd, &chord_buf) catch {
            clearTrustGateOverlay(body_lines.len, bottom_margin_rows);
            return 0;
        };
        switch (key.event) {
            .up => {
                if (choices.len > 0) selected = if (selected == 0) choices.len - 1 else selected - 1;
            },
            .down, .next, .tab, .shift_tab => {
                if (choices.len > 0) selected = (selected + 1) % choices.len;
            },
            .select, .toggle => {
                clearTrustGateOverlay(body_lines.len, bottom_margin_rows);
                if (choices.len == 0) return 0;
                return selected;
            },
            .cancel => {
                clearTrustGateOverlay(body_lines.len, bottom_margin_rows);
                return 0;
            },
            .char, .backspace, .none => {},
        }
    }
}

/// ui-dialogs-05: the return-from-idle nudge. Reuses the trust-gate chrome
/// (same title/body/options layout) but returns an `idle_return.IdleAction`
/// so the three choices and Esc map onto the reference's
/// continue | clear | never | dismiss actions.
///
/// `header_line` is the "You've been away ... and this conversation is ...
/// tokens." line; `body_line` is the "If this is a new task ..." hint. The
/// three choices are Continue / "Send message as a new conversation" /
/// "Don't ask me again", matching IdleReturnDialog.tsx. Esc/cancel dismisses
/// (proceed normally, persist nothing).
pub fn runIdleReturnOverlayLoop(
    header_line: []const u8,
    body_line: []const u8,
    bottom_margin_rows: usize,
) !idle_return.IdleAction {
    const title = "Welcome back";
    const body_lines = [_][]const u8{ header_line, body_line };
    const choices = [_][]const u8{
        "Continue",
        "Send message as a new conversation",
        "Don't ask me again",
    };

    const fd = std.Io.File.stdin().handle;
    var selected: usize = 0; // default to Continue.

    while (true) {
        renderTrustGateOverlay(title, body_lines[0..], choices[0..], selected, bottom_margin_rows);
        var chord_buf: [24]u8 = undefined;
        const key = readPickerKey(fd, &chord_buf) catch {
            clearTrustGateOverlay(body_lines.len, bottom_margin_rows);
            return .dismiss;
        };
        switch (key.event) {
            .up => {
                selected = if (selected == 0) choices.len - 1 else selected - 1;
            },
            .down, .next, .tab, .shift_tab => {
                selected = (selected + 1) % choices.len;
            },
            .select, .toggle => {
                clearTrustGateOverlay(body_lines.len, bottom_margin_rows);
                return switch (selected) {
                    0 => .cont,
                    1 => .clear,
                    2 => .never,
                    else => .dismiss,
                };
            },
            .cancel => {
                clearTrustGateOverlay(body_lines.len, bottom_margin_rows);
                return .dismiss;
            },
            .char, .backspace, .none => {},
        }
    }
}

// ── Feedback survey overlay (ui-dialogs-07, local rating) ──

/// Max note bytes captured by the survey. Kept small: this is a one-liner, not
/// free-form prose; the GitHub-issue flow handles longer reports.
pub const FEEDBACK_NOTE_MAX: usize = 96;

/// Result of the local feedback survey. `note_buf[0..note_len]` is the typed
/// note (may be empty). The struct owns the note inline so the caller does not
/// have to manage an allocation for a short string.
pub const FeedbackSurveyResult = struct {
    rating: u8,
    note_buf: [FEEDBACK_NOTE_MAX]u8 = undefined,
    note_len: usize = 0,

    pub fn note(self: *const FeedbackSurveyResult) []const u8 {
        return self.note_buf[0..self.note_len];
    }
};

/// ui-dialogs-07 (PARTIAL): the local FeedbackSurvey. A two-phase overlay that
/// reuses the trust-gate chrome: phase 1 is a 1-5 rating Select (arrow + Enter,
/// or type a digit 1-5 to pick directly, mirroring the reference's
/// debounced-digit input); phase 2 is an optional one-line note (type then
/// Enter to submit, Esc to skip the note and submit with the rating only).
/// Returns the rating + note, or `null` when the user cancels the rating step
/// (Esc / Ctrl-C / Ctrl-D before choosing a rating).
///
/// The cloud transcript-share branch of FeedbackSurvey.tsx is intentionally
/// not ported (zcode does not phone home). The "Thanks!" confirmation line is
/// rendered by the caller after persistence.
pub fn runFeedbackSurveyOverlayLoop(bottom_margin_rows: usize) !?FeedbackSurveyResult {
    const fd = std.Io.File.stdin().handle;

    // ── Phase 1: rating ──
    const rating_title = "How would you rate zcode?";
    const rating_body = [_][]const u8{
        "Pick 1 (poor) to 5 (great). Your rating is stored locally only.",
    };
    const choices = [_][]const u8{ "1", "2", "3", "4", "5" };
    var selected: usize = 4; // default highlight on 5 (a happy default).

    const rating: u8 = while (true) {
        renderTrustGateOverlay(rating_title, rating_body[0..], choices[0..], selected, bottom_margin_rows);
        var chord_buf: [24]u8 = undefined;
        const key = readPickerKey(fd, &chord_buf) catch {
            clearTrustGateOverlay(rating_body.len, bottom_margin_rows);
            return null;
        };
        switch (key.event) {
            .up => selected = if (selected == 0) choices.len - 1 else selected - 1,
            .down, .next, .tab, .shift_tab => selected = (selected + 1) % choices.len,
            .select, .toggle => {
                clearTrustGateOverlay(rating_body.len, bottom_margin_rows);
                break @as(u8, @intCast(selected + 1));
            },
            .cancel => {
                clearTrustGateOverlay(rating_body.len, bottom_margin_rows);
                return null;
            },
            .char => {
                if (key.char >= '1' and key.char <= '5') {
                    clearTrustGateOverlay(rating_body.len, bottom_margin_rows);
                    break key.char - '0';
                }
            },
            .backspace, .none => {},
        }
    };

    // ── Phase 2: optional note ──
    var result = FeedbackSurveyResult{ .rating = rating };
    const note_title = "Add a note? (optional)";
    while (true) {
        var note_view_buf: [FEEDBACK_NOTE_MAX + 1]u8 = undefined;
        // Show the typed note with a trailing caret so the row reads as input.
        const shown = std.fmt.bufPrint(
            &note_view_buf,
            "{s}_",
            .{result.note_buf[0..result.note_len]},
        ) catch result.note_buf[0..result.note_len];
        const note_body = [_][]const u8{shown};
        renderTrustGateOverlay(note_title, note_body[0..], &.{}, 0, bottom_margin_rows);

        var chord_buf: [24]u8 = undefined;
        const key = readPickerKey(fd, &chord_buf) catch {
            clearTrustGateOverlay(1, bottom_margin_rows);
            return result; // submit with whatever note is typed so far.
        };
        switch (key.event) {
            .select, .toggle, .cancel => {
                clearTrustGateOverlay(1, bottom_margin_rows);
                return result;
            },
            .backspace => {
                if (result.note_len > 0) result.note_len -= 1;
            },
            .char => {
                if (key.char >= 0x20 and key.char < 0x7f and result.note_len < FEEDBACK_NOTE_MAX) {
                    result.note_buf[result.note_len] = key.char;
                    result.note_len += 1;
                }
            },
            .up, .down, .next, .tab, .shift_tab, .none => {},
        }
    }
}

/// Rows the trust gate occupies: the options row, the title row, plus one row
/// per (capped) body line. Used to compute the topmost row and to clear them.
fn trustGateBodyRows(body_count: usize) usize {
    return @min(body_count, TRUST_GATE_MAX_BODY_ROWS) + (if (body_count > TRUST_GATE_MAX_BODY_ROWS) @as(usize, 1) else 0);
}

fn renderTrustGateOverlay(
    title: []const u8,
    body_lines: []const []const u8,
    choices: []const []const u8,
    selected: usize,
    bottom_margin_rows: usize,
) void {
    const rows = terminalRows();
    const cols = terminalCols();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;
    const border_row = if (status_row > 3) status_row - 3 else 1;
    const options_row = if (border_row > 1) border_row - 1 else 1;

    const body_rows = trustGateBodyRows(body_lines.len);
    // Title sits one row above the first body line; body lines stack upward.
    const title_row = if (options_row > body_rows + 1) options_row - body_rows - 1 else 1;
    const draw_cols = if (cols > 1) cols - 1 else cols;

    var seq: [4096]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&seq);
    const w = &fbs;
    w.writeAll("\x1b7") catch {};

    // Title row (warning red rail + bold title).
    var safe_title_buf: [320]u8 = undefined;
    const safe_title = sanitizeText(std.mem.trim(u8, title, " \t\r\n"), safe_title_buf[0..]);
    var title_line_buf: [420]u8 = undefined;
    const title_full = std.fmt.bufPrint(
        &title_line_buf,
        "\x1b[38;2;217;95;114m\xe2\x94\x83\x1b[0m \x1b[1m{s}\x1b[0m",
        .{safe_title},
    ) catch "trust";
    w.print("\x1b[{d};1H\x1b[2K{s}", .{ title_row, title_full[0..@min(title_full.len, draw_cols)] }) catch {};

    // Body lines, one per row beneath the title.
    const shown = @min(body_lines.len, TRUST_GATE_MAX_BODY_ROWS);
    var i: usize = 0;
    while (i < shown) : (i += 1) {
        const row = title_row + 1 + i;
        var safe_buf: [320]u8 = undefined;
        const safe = sanitizeText(std.mem.trim(u8, body_lines[i], " \t\r\n"), safe_buf[0..]);
        var line_buf: [400]u8 = undefined;
        const line_full = std.fmt.bufPrint(&line_buf, "  \x1b[2m\xe2\x80\xa2\x1b[0m {s}", .{safe}) catch "  -";
        w.print("\x1b[{d};1H\x1b[2K{s}", .{ row, line_full[0..@min(line_full.len, draw_cols)] }) catch {};
    }
    if (body_lines.len > TRUST_GATE_MAX_BODY_ROWS) {
        const row = title_row + 1 + shown;
        var more_buf: [64]u8 = undefined;
        const more = std.fmt.bufPrint(&more_buf, "  \x1b[2m+{d} more\x1b[0m", .{body_lines.len - TRUST_GATE_MAX_BODY_ROWS}) catch "  +more";
        w.print("\x1b[{d};1H\x1b[2K{s}", .{ row, more }) catch {};
    }

    // Options row reuses the ask-user option line builder so the choices and
    // the keyboard hint match the rest of the overlay family.
    var options_buf: [640]u8 = undefined;
    const options_full = buildAskUserOptionsLine(&options_buf, choices, selected);
    w.print("\x1b[{d};1H\x1b[2K{s}", .{ options_row, options_full[0..@min(options_full.len, draw_cols)] }) catch {};

    w.writeAll("\x1b8") catch {};
    const frame = seq[0..fbs.end];
    _ = std.c.write(std.Io.File.stdout().handle, frame.ptr, frame.len);
}

fn clearTrustGateOverlay(body_count: usize, bottom_margin_rows: usize) void {
    const rows = terminalRows();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;
    const border_row = if (status_row > 3) status_row - 3 else 1;
    const options_row = if (border_row > 1) border_row - 1 else 1;
    const body_rows = trustGateBodyRows(body_count);
    const title_row = if (options_row > body_rows + 1) options_row - body_rows - 1 else 1;

    var seq: [2048]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&seq);
    const w = &fbs;
    w.writeAll("\x1b7") catch {};
    var row = title_row;
    while (row <= options_row) : (row += 1) {
        w.print("\x1b[{d};1H\x1b[2K", .{row}) catch {};
    }
    w.writeAll("\x1b8") catch {};
    const frame = seq[0..fbs.end];
    _ = std.c.write(std.Io.File.stdout().handle, frame.ptr, frame.len);
}

// ── Inline plan review prompt (non-fullscreen) ──

pub fn runInlinePlanReviewPrompt(plan_path: []const u8) !PlanAction {
    const stdout = std_io.stdoutWriter();
    const stdin = std_io.stdinReader();

    try stdout.print("plan saved: {s}\n", .{plan_path});
    try stdout.writeAll("Select: 1) Approve+Execute  2) Continue Discussion  3) Cancel [default: 2] > ");

    var buf: [24]u8 = undefined;
    var len: usize = 0;
    while (true) {
        const b = stdin.readByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (b == '\n' or b == '\r') break;
        if (len < buf.len) {
            buf[len] = b;
            len += 1;
        }
    }
    try stdout.writeByte('\n');

    const trimmed = std.mem.trim(u8, buf[0..len], " \t\r\n");
    if (trimmed.len == 0) return .discuss;

    return switch (trimmed[0]) {
        '1', 'y', 'Y', 'a', 'A' => .approve,
        '3', 'c', 'C' => .cancel,
        else => .discuss,
    };
}

// ── Fullscreen plan review overlay ──

pub fn runPlanReviewOverlayLoop(plan_path: []const u8, bottom_margin_rows: usize) !PlanAction {
    const fd = std.Io.File.stdin().handle;
    var selected: usize = 1; // default to continue discussion.

    while (true) {
        renderPlanReviewOverlay(plan_path, selected, bottom_margin_rows);
        const nav = readApprovalNavEvent(fd) catch return .cancel;
        switch (nav) {
            .left => selected = if (selected == 0) 2 else selected - 1,
            .right => selected = (selected + 1) % 3,
            .select => {
                clearPlanReviewOverlay(bottom_margin_rows);
                return switch (selected) {
                    0 => .approve,
                    1 => .discuss,
                    else => .cancel,
                };
            },
            .approve => {
                clearPlanReviewOverlay(bottom_margin_rows);
                return .approve;
            },
            .approve_always => {
                clearPlanReviewOverlay(bottom_margin_rows);
                return .approve;
            },
            .deny => {
                clearPlanReviewOverlay(bottom_margin_rows);
                return .discuss;
            },
            .cancel => {
                clearPlanReviewOverlay(bottom_margin_rows);
                return .cancel;
            },
            // The plan-review overlay has no permission mode to cycle.
            .cycle_mode, .none => {},
        }
    }
}

pub fn renderPlanReviewOverlay(_: []const u8, selected: usize, bottom_margin_rows: usize) void {
    const rows = terminalRows();
    const cols = terminalCols();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;

    // 7 rows: top border, spacer, approve, discuss, cancel, spacer, bottom border
    const row7 = if (status_row > 1) status_row - 1 else 1;
    const row6 = if (row7 > 1) row7 - 1 else 1;
    const row5 = if (row6 > 1) row6 - 1 else 1;
    const row4 = if (row5 > 1) row5 - 1 else 1;
    const row3 = if (row4 > 1) row4 - 1 else 1;
    const row2 = if (row3 > 1) row3 - 1 else 1;
    const row1 = if (row2 > 1) row2 - 1 else 1;

    // Dynamic width: min 38, max 50, clamped to terminal
    const box_w: usize = if (cols < 38) cols else if (cols < 50) cols else 50;
    // Inner width = box_w - 2 (for left/right border chars)
    const inner = if (box_w > 2) box_w - 2 else 1;

    // -- Build lines into a buffer --
    var seq: [4096]u8 = undefined;
    var pos: usize = 0;

    // Helper: append bytes
    const out = &seq;
    _ = out;

    // Save cursor
    appendLiteral(&seq, &pos, "\x1b7");

    // Refactoring UI hierarchy for the plan review dialog:
    // - Title "PLAN REVIEW" rendered in brand-accent mint so the eye
    //   finds the dialog and so it stops competing with the Approve
    //   button (previously both were green).
    // - Approve = primary action, mint inverse-video fill when selected.
    // - Continue Discussion = secondary, bright fg + triangle marker
    //   when selected, dim plain when not.
    // - Cancel = tertiary, dim even when selected (red background was
    //   wrong -- Cancel is not destructive, it's "don't proceed now").
    const accent_mint_fg = "\x1b[38;2;95;212;160m\x1b[1m";
    const accent_mint_fill = "\x1b[48;2;95;212;160m\x1b[38;2;11;18;22m\x1b[1m";
    const border_dim = "\x1b[38;5;245m";
    const outline_fg = "\x1b[38;2;200;210;220m\x1b[1m";
    const dim_fg = "\x1b[2m";
    const reset_seq = "\x1b[0m";

    // -- Row 1: top border with brand-accent title --
    appendCursorTo(&seq, &pos, row1);
    appendLiteral(&seq, &pos, "\x1b[2K");
    appendLiteral(&seq, &pos, border_dim);
    appendLiteral(&seq, &pos, "\xe2\x95\xad\xe2\x94\x80 ");
    appendLiteral(&seq, &pos, reset_seq);
    appendLiteral(&seq, &pos, accent_mint_fg);
    appendLiteral(&seq, &pos, "PLAN REVIEW");
    appendLiteral(&seq, &pos, reset_seq);
    appendLiteral(&seq, &pos, border_dim);
    appendLiteral(&seq, &pos, " ");
    const top_fill = if (inner > 15) inner - 15 else 0;
    appendRepeatByte(&seq, &pos, "\xe2\x94\x80", top_fill);
    appendLiteral(&seq, &pos, "\xe2\x95\xae");
    appendLiteral(&seq, &pos, reset_seq);

    // -- Row 2: empty spacer --
    appendCursorTo(&seq, &pos, row2);
    appendLiteral(&seq, &pos, "\x1b[2K");
    appendLiteral(&seq, &pos, border_dim);
    appendLiteral(&seq, &pos, "\xe2\x94\x82");
    appendRepeatByte(&seq, &pos, " ", inner);
    appendLiteral(&seq, &pos, "\xe2\x94\x82");
    appendLiteral(&seq, &pos, reset_seq);

    // -- Row 3: Approve option (primary action) --
    // Label width is the same whether selected or not so the row
    // always fills to `inner` columns cleanly.
    const approve_label = "  \xe2\x9c\x93  Approve + Execute    ";
    const approve_label_len: usize = 27;
    appendCursorTo(&seq, &pos, row3);
    appendLiteral(&seq, &pos, "\x1b[2K");
    appendLiteral(&seq, &pos, border_dim);
    appendLiteral(&seq, &pos, "\xe2\x94\x82");
    appendLiteral(&seq, &pos, reset_seq);
    if (selected == 0) {
        appendLiteral(&seq, &pos, accent_mint_fill);
        appendLiteral(&seq, &pos, approve_label);
        appendRepeatByte(&seq, &pos, " ", if (inner > approve_label_len) inner - approve_label_len else 0);
        appendLiteral(&seq, &pos, reset_seq);
    } else {
        appendLiteral(&seq, &pos, dim_fg);
        appendLiteral(&seq, &pos, approve_label);
        appendRepeatByte(&seq, &pos, " ", if (inner > approve_label_len) inner - approve_label_len else 0);
        appendLiteral(&seq, &pos, reset_seq);
    }
    appendLiteral(&seq, &pos, border_dim);
    appendLiteral(&seq, &pos, "\xe2\x94\x82");
    appendLiteral(&seq, &pos, reset_seq);

    // -- Row 4: Continue Discussion (secondary action) --
    const discuss_label = "  \xe2\x97\x87  Continue Discussion  ";
    const discuss_label_len: usize = 28;
    appendCursorTo(&seq, &pos, row4);
    appendLiteral(&seq, &pos, "\x1b[2K");
    appendLiteral(&seq, &pos, border_dim);
    appendLiteral(&seq, &pos, "\xe2\x94\x82");
    appendLiteral(&seq, &pos, reset_seq);
    if (selected == 1) {
        appendLiteral(&seq, &pos, outline_fg);
        appendLiteral(&seq, &pos, discuss_label);
        appendRepeatByte(&seq, &pos, " ", if (inner > discuss_label_len) inner - discuss_label_len else 0);
        appendLiteral(&seq, &pos, reset_seq);
    } else {
        appendLiteral(&seq, &pos, dim_fg);
        appendLiteral(&seq, &pos, discuss_label);
        appendRepeatByte(&seq, &pos, " ", if (inner > discuss_label_len) inner - discuss_label_len else 0);
        appendLiteral(&seq, &pos, reset_seq);
    }
    appendLiteral(&seq, &pos, border_dim);
    appendLiteral(&seq, &pos, "\xe2\x94\x82");
    appendLiteral(&seq, &pos, reset_seq);

    // -- Row 5: Cancel (tertiary action, not destructive) --
    const cancel_label = "  \xe2\x9c\x97  Cancel                ";
    const cancel_label_len: usize = 27;
    appendCursorTo(&seq, &pos, row5);
    appendLiteral(&seq, &pos, "\x1b[2K");
    appendLiteral(&seq, &pos, border_dim);
    appendLiteral(&seq, &pos, "\xe2\x94\x82");
    appendLiteral(&seq, &pos, reset_seq);
    if (selected == 2) {
        appendLiteral(&seq, &pos, outline_fg);
        appendLiteral(&seq, &pos, cancel_label);
        appendRepeatByte(&seq, &pos, " ", if (inner > cancel_label_len) inner - cancel_label_len else 0);
        appendLiteral(&seq, &pos, reset_seq);
    } else {
        appendLiteral(&seq, &pos, dim_fg);
        appendLiteral(&seq, &pos, cancel_label);
        appendRepeatByte(&seq, &pos, " ", if (inner > cancel_label_len) inner - cancel_label_len else 0);
        appendLiteral(&seq, &pos, reset_seq);
    }
    appendLiteral(&seq, &pos, border_dim);
    appendLiteral(&seq, &pos, "\xe2\x94\x82");
    appendLiteral(&seq, &pos, reset_seq);

    // -- Row 6: empty spacer --
    appendCursorTo(&seq, &pos, row6);
    appendLiteral(&seq, &pos, "\x1b[2K");
    appendLiteral(&seq, &pos, "\x1b[38;5;245m");
    appendLiteral(&seq, &pos, "\xe2\x94\x82"); // vertical
    appendRepeatByte(&seq, &pos, " ", inner);
    appendLiteral(&seq, &pos, "\xe2\x94\x82"); // vertical
    appendLiteral(&seq, &pos, "\x1b[0m");

    // -- Row 7: bottom border with hints --
    appendCursorTo(&seq, &pos, row7);
    appendLiteral(&seq, &pos, "\x1b[2K");
    appendLiteral(&seq, &pos, "\x1b[38;5;245m");
    appendLiteral(&seq, &pos, "\xe2\x95\xb0\xe2\x94\x80\xe2\x94\x80 "); // bottom-left
    appendLiteral(&seq, &pos, "\x1b[2m");
    appendLiteral(&seq, &pos, "\xe2\x86\x91\xe2\x86\x93 navigate \xc2\xb7 Enter \xc2\xb7 y/n/Esc");
    appendLiteral(&seq, &pos, "\x1b[0m\x1b[38;5;245m");
    appendLiteral(&seq, &pos, " ");
    const bot_fill = if (inner > 31) inner - 31 else 0;
    appendRepeatByte(&seq, &pos, "\xe2\x94\x80", bot_fill);
    appendLiteral(&seq, &pos, "\xe2\x95\xaf"); // bottom-right
    appendLiteral(&seq, &pos, "\x1b[0m");

    // Restore cursor
    appendLiteral(&seq, &pos, "\x1b8");

    _ = std.c.write(std.Io.File.stdout().handle, (seq[0..pos]).ptr, (seq[0..pos]).len);
}

pub fn clearPlanReviewOverlay(bottom_margin_rows: usize) void {
    const rows = terminalRows();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;
    // 7 rows to clear (matching renderPlanReviewOverlay)
    const row7 = if (status_row > 1) status_row - 1 else 1;
    const row6 = if (row7 > 1) row7 - 1 else 1;
    const row5 = if (row6 > 1) row6 - 1 else 1;
    const row4 = if (row5 > 1) row5 - 1 else 1;
    const row3 = if (row4 > 1) row4 - 1 else 1;
    const row2 = if (row3 > 1) row3 - 1 else 1;
    const row1 = if (row2 > 1) row2 - 1 else 1;

    var seq: [512]u8 = undefined;
    const clear = std.fmt.bufPrint(
        &seq,
        "\x1b7" ++
            "\x1b[{d};1H\x1b[2K" ++
            "\x1b[{d};1H\x1b[2K" ++
            "\x1b[{d};1H\x1b[2K" ++
            "\x1b[{d};1H\x1b[2K" ++
            "\x1b[{d};1H\x1b[2K" ++
            "\x1b[{d};1H\x1b[2K" ++
            "\x1b[{d};1H\x1b[2K" ++
            "\x1b8",
        .{ row1, row2, row3, row4, row5, row6, row7 },
    ) catch return;
    _ = std.c.write(std.Io.File.stdout().handle, (clear).ptr, (clear).len);
}

// ── Model picker overlay ──

pub fn parseModelPickerData(allocator: std.mem.Allocator, payload: []const u8) !ModelPickerData {
    var items = std.array_list.Managed(ModelPickerItem).init(allocator);
    errdefer items.deinit();

    var active_provider: []const u8 = "unknown";
    var active_model: []const u8 = "unknown";

    var line_it = std.mem.splitScalar(u8, payload, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "active_provider=")) {
            active_provider = line["active_provider=".len..];
            continue;
        }

        if (std.mem.startsWith(u8, line, "active_model=")) {
            active_model = line["active_model=".len..];
            continue;
        }

        if (std.mem.startsWith(u8, line, "item=")) {
            const raw_item = line["item=".len..];
            var split_idx = raw_item.len;
            for (raw_item, 0..) |ch, idx| {
                if (ch == '\t' or ch == ' ') {
                    split_idx = idx;
                    break;
                }
            }

            const id = raw_item[0..split_idx];
            if (id.len == 0) continue;

            var ctx_value: usize = 0;
            if (split_idx < raw_item.len) {
                const ctx_txt = std.mem.trim(u8, raw_item[split_idx + 1 ..], " \t");
                ctx_value = std.fmt.parseInt(usize, ctx_txt, 10) catch 0;
            }
            try items.append(.{ .id = id, .ctx = ctx_value });
        }
    }

    return .{
        .allocator = allocator,
        .active_provider = active_provider,
        .active_model = active_model,
        .items = try items.toOwnedSlice(),
    };
}

pub fn parseMessageSelectorData(allocator: std.mem.Allocator, payload: []const u8) !MessageSelectorData {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidMessageSelectorData;
    const root = parsed.value.object;
    const items_val = root.get("items") orelse return error.InvalidMessageSelectorData;
    if (items_val != .array) return error.InvalidMessageSelectorData;

    var items = std.array_list.Managed(MessageSelectorItem).init(allocator);
    errdefer {
        for (items.items) |item| allocator.free(item.prompt);
        items.deinit();
    }

    for (items_val.array.items) |item_val| {
        if (item_val != .object) continue;
        const history_index_val = item_val.object.get("history_index") orelse continue;
        const prompt_val = item_val.object.get("prompt") orelse continue;
        if (history_index_val != .integer or prompt_val != .string) continue;

        const history_index = std.math.cast(usize, history_index_val.integer) orelse continue;
        const prompt = try allocator.dupe(u8, prompt_val.string);
        try items.append(.{
            .history_index = history_index,
            .prompt = prompt,
        });
    }

    var initial_selection: usize = if (items.items.len > 0) items.items.len - 1 else 0;
    if (root.get("initial_selection")) |sel_val| {
        if (sel_val == .integer) {
            if (std.math.cast(usize, sel_val.integer)) |sel_idx| {
                if (items.items.len > 0) initial_selection = @min(sel_idx, items.items.len - 1);
            }
        }
    }

    return .{
        .allocator = allocator,
        .items = try items.toOwnedSlice(),
        .initial_selection = initial_selection,
    };
}

pub fn parseBackgroundTasksData(allocator: std.mem.Allocator, payload: []const u8) !BackgroundTasksData {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidTaskOverlayData;
    const root = parsed.value.object;
    const items_val = root.get("items") orelse return error.InvalidTaskOverlayData;
    if (items_val != .array) return error.InvalidTaskOverlayData;

    var items = std.array_list.Managed(BackgroundTaskItem).init(allocator);
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit();
    }

    for (items_val.array.items) |item_val| {
        if (item_val != .object) continue;

        const id_val = item_val.object.get("id") orelse continue;
        const title_val = item_val.object.get("title") orelse continue;
        const status_val = item_val.object.get("status") orelse continue;
        const summary_val = item_val.object.get("summary") orelse continue;
        const command_val = item_val.object.get("command") orelse continue;
        const owner_val = item_val.object.get("owner") orelse continue;
        const priority_val = item_val.object.get("priority") orelse continue;
        const detail_val = item_val.object.get("detail") orelse continue;
        const progress_val = item_val.object.get("progress") orelse continue;
        const run_pid_val = item_val.object.get("run_pid") orelse continue;
        const updated_ts_val = item_val.object.get("updated_ts") orelse continue;

        if (id_val != .string or title_val != .string or status_val != .string or summary_val != .string or
            command_val != .string or owner_val != .string or priority_val != .string or detail_val != .string or progress_val != .integer or
            run_pid_val != .integer or updated_ts_val != .integer)
        {
            continue;
        }

        try items.append(.{
            .id = try allocator.dupe(u8, id_val.string),
            .title = try allocator.dupe(u8, title_val.string),
            .status = try allocator.dupe(u8, status_val.string),
            .summary = try allocator.dupe(u8, summary_val.string),
            .command = try allocator.dupe(u8, command_val.string),
            .owner = try allocator.dupe(u8, owner_val.string),
            .priority = try allocator.dupe(u8, priority_val.string),
            .detail = try allocator.dupe(u8, detail_val.string),
            .progress = @intCast(@min(@as(i64, 100), @max(@as(i64, 0), progress_val.integer))),
            .run_pid = run_pid_val.integer,
            .updated_ts = updated_ts_val.integer,
        });
    }

    var initial_selection: usize = 0;
    if (root.get("initial_selection")) |sel_val| {
        if (sel_val == .integer) {
            if (std.math.cast(usize, sel_val.integer)) |sel_idx| {
                if (items.items.len > 0) initial_selection = @min(sel_idx, items.items.len - 1);
            }
        }
    }

    return .{
        .allocator = allocator,
        .items = try items.toOwnedSlice(),
        .initial_selection = initial_selection,
    };
}

pub fn parseSessionSwitcherData(allocator: std.mem.Allocator, payload: []const u8) !SessionSwitcherData {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidSessionSwitcherData;
    const root = parsed.value.object;
    const items_val = root.get("items") orelse return error.InvalidSessionSwitcherData;
    if (items_val != .array) return error.InvalidSessionSwitcherData;

    var items = std.array_list.Managed(SessionSwitcherItem).init(allocator);
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit();
    }

    var initial_selection: usize = 0;

    for (items_val.array.items, 0..) |item_val, idx| {
        if (item_val != .object) continue;
        const id_val = item_val.object.get("id") orelse continue;
        const label_val = item_val.object.get("label") orelse continue;
        const updated_val = item_val.object.get("updated_summary") orelse continue;
        const current_val = item_val.object.get("is_current") orelse continue;
        if (id_val != .string or label_val != .string or updated_val != .string or current_val != .bool) continue;

        try items.append(.{
            .id = try allocator.dupe(u8, id_val.string),
            .label = try allocator.dupe(u8, label_val.string),
            .updated_summary = try allocator.dupe(u8, updated_val.string),
            .is_current = current_val.bool,
        });
        if (current_val.bool) initial_selection = idx;
    }

    if (root.get("initial_selection")) |sel_val| {
        if (sel_val == .integer) {
            if (std.math.cast(usize, sel_val.integer)) |sel_idx| {
                if (items.items.len > 0) initial_selection = @min(sel_idx, items.items.len - 1);
            }
        }
    }

    return .{
        .allocator = allocator,
        .items = try items.toOwnedSlice(),
        .initial_selection = initial_selection,
    };
}

pub fn initialModelPickerSelection(data: ModelPickerData) usize {
    for (data.items, 0..) |item, idx| {
        if (std.mem.eql(u8, item.id, data.active_model)) return idx;
    }
    return 0;
}

fn modelPickerOverlayRows(item_count: usize) usize {
    const visible = @min(item_count, @as(usize, 8));
    return visible + 7; // +1 for search line
}

const PickerEvent = enum { up, down, next, toggle, select, tab, shift_tab, cancel, backspace, char, none };

const PickerKey = struct {
    event: PickerEvent,
    char: u8 = 0,
    chord: []const u8 = "",
};

fn readPickerKey(fd: std.posix.fd_t, chord_buf: *[24]u8) !PickerKey {
    const ch = try readOneByte(fd);
    switch (ch) {
        '\r', '\n' => return .{ .event = .select, .chord = "enter" },
        '\t' => return .{ .event = .tab, .chord = "tab" },
        0x12 => return .{ .event = .next, .chord = "ctrl+r" },
        0x14 => return .{ .event = .toggle, .chord = "ctrl+t" },
        0x05 => return .{ .event = .toggle, .chord = "ctrl+e" },
        0x03 => return .{ .event = .cancel, .chord = "ctrl+c" },
        0x04 => return .{ .event = .cancel, .chord = "ctrl+d" },
        0x7f, 0x08 => return .{ .event = .backspace, .chord = "backspace" },
        0x1b => {
            var poll_fds = [1]std.posix.pollfd{.{
                .fd = fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const ready = std.posix.poll(&poll_fds, 30) catch 0;
            if (ready == 0) return .{ .event = .cancel, .chord = "escape" };

            const second = readOneByte(fd) catch return .{ .event = .cancel, .chord = "escape" };
            if (second != '[') return .{ .event = .cancel, .chord = "escape" };

            var seq: [32]u8 = undefined;
            seq[0] = readOneByte(fd) catch return .{ .event = .none };
            var len: usize = 1;
            while (len < seq.len) : (len += 1) {
                const byte = seq[len - 1];
                if (byte >= 0x40 and byte <= 0x7E) break;
                seq[len] = readOneByte(fd) catch return .{ .event = .none };
            }

            const final = seq[len - 1];
            if (final == 'u') {
                if (repl_input.parseKittyKeyPayload(seq[0 .. len - 1])) |key| {
                    const has_ctrl = (key.mods >= 5) and (((key.mods - 1) & 4) != 0);
                    if (has_ctrl and (key.codepoint == 114 or key.codepoint == 82 or key.codepoint == 18)) return .{ .event = .next, .chord = "ctrl+r" };
                    if (has_ctrl and (key.codepoint == 116 or key.codepoint == 84 or key.codepoint == 20)) return .{ .event = .toggle, .chord = "ctrl+t" };
                    if (key.codepoint == 13 or key.codepoint == 10) return .{ .event = .select, .chord = "enter" };
                    if (key.codepoint == 9) {
                        if (key.mods > 1) return .{ .event = .shift_tab, .chord = "shift+tab" };
                        return .{ .event = .tab, .chord = "tab" };
                    }
                    if (key.codepoint == 27) return .{ .event = .cancel, .chord = "escape" };
                    if (key.codepoint == 127 or key.codepoint == 8) return .{ .event = .backspace, .chord = "backspace" };
                    if (has_ctrl and (key.codepoint == 112 or key.codepoint == 80)) return .{ .event = .up, .chord = "ctrl+p" };
                    if (has_ctrl and (key.codepoint == 110 or key.codepoint == 78)) return .{ .event = .down, .chord = "ctrl+n" };
                }
            }

            const csi_mods = blk: {
                if (len <= 2 or seq[0] != '1' or seq[1] != ';') break :blk null;
                break :blk std.fmt.parseInt(usize, seq[2 .. len - 1], 10) catch null;
            };
            const arrow_up_chord = if (csi_mods == 5 or csi_mods == 6 or csi_mods == 7 or csi_mods == 8)
                "ctrl+up"
            else if (csi_mods == 2 or csi_mods == 4)
                "shift+up"
            else
                "up";
            const arrow_down_chord = if (csi_mods == 5 or csi_mods == 6 or csi_mods == 7 or csi_mods == 8)
                "ctrl+down"
            else if (csi_mods == 2 or csi_mods == 4)
                "shift+down"
            else
                "down";

            return switch (final) {
                'A' => .{ .event = .up, .chord = arrow_up_chord },
                'B' => .{ .event = .down, .chord = arrow_down_chord },
                'Z' => .{ .event = .shift_tab, .chord = "shift+tab" },
                else => .{ .event = .none },
            };
        },
        else => {
            if (ch >= 0x20 and ch < 0x7f) {
                chord_buf[0] = std.ascii.toLower(ch);
                return .{ .event = .char, .char = ch, .chord = chord_buf[0..1] };
            }
            return .{ .event = .none };
        },
    }
}

fn readPickerEvent(fd: std.posix.fd_t, char_out: *u8) !PickerEvent {
    var chord_buf: [24]u8 = undefined;
    const key = try readPickerKey(fd, &chord_buf);
    char_out.* = key.char;
    return key.event;
}

fn resolvePickerBinding(
    bindings: ?*const keybindings.RuntimeKeybindings,
    contexts: []const keybindings.BindingContext,
    chord: []const u8,
    fallback: PickerEvent,
) PickerEvent {
    const kb = bindings orelse return fallback;
    const lookup = kb.lookup(contexts, chord);
    if (!lookup.handled) return fallback;
    const action = lookup.action orelse return .none;
    return switch (action) {
        .select_previous, .message_selector_up, .message_actions_prev => .up,
        .select_next, .history_search_next, .message_selector_down, .message_actions_next => .down,
        .confirm_previous => .up,
        .confirm_next => .down,
        .select_accept, .history_search_accept, .history_search_execute, .message_selector_select, .message_actions_accept => .select,
        .confirm_yes => .select,
        .select_cancel, .history_search_cancel, .message_actions_cancel, .transcript_exit => .cancel,
        .confirm_no => .cancel,
        .theme_toggle_syntax, .transcript_toggle_show_all => .toggle,
        .message_actions_copy => .char,
        .message_actions_prev_user => .up,
        else => fallback,
    };
}

fn resolveTranscriptBinding(
    bindings: ?*const keybindings.RuntimeKeybindings,
    chord: []const u8,
    fallback: TranscriptNavEvent,
) TranscriptNavEvent {
    const kb = bindings orelse return fallback;
    const contexts = [_]keybindings.BindingContext{.Transcript};
    const lookup = kb.lookup(&contexts, chord);
    if (!lookup.handled) return fallback;
    const action = lookup.action orelse return .none;
    return switch (action) {
        .transcript_toggle_show_all => .toggle,
        .transcript_exit => .cancel,
        else => fallback,
    };
}

// ── Todo overlay ──

fn todoOverlayLineCount(text: []const u8) usize {
    const trimmed = std.mem.trimEnd(u8, text, "\r\n");
    if (trimmed.len == 0) return 0;

    var count: usize = 1;
    for (trimmed) |ch| {
        if (ch == '\n') count += 1;
    }
    return count;
}

fn todoOverlayVisibleRows(line_count: usize, rows: usize, bottom_margin_rows: usize) usize {
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;
    const bottom_row = if (status_row > 1) status_row - 1 else 1;
    const available_rows = @max(bottom_row, @as(usize, 1));
    const max_body_rows = if (available_rows > 5) @min(@as(usize, 10), available_rows - 4) else 1;
    const effective_lines = if (line_count == 0) @as(usize, 1) else line_count;
    return @min(effective_lines, max_body_rows);
}

fn todoOverlayRows(line_count: usize, rows: usize, bottom_margin_rows: usize) usize {
    return todoOverlayVisibleRows(line_count, rows, bottom_margin_rows) + 4;
}

pub fn runTodoOverlayLoop(data: TodoOverlayData, bottom_margin_rows: usize) !void {
    const default_contexts = [_]keybindings.BindingContext{.Select};
    return runTodoOverlayLoopWithBindings(data, bottom_margin_rows, null, &default_contexts);
}

pub fn runTodoOverlayLoopWithBindings(
    data: TodoOverlayData,
    bottom_margin_rows: usize,
    bindings: ?*const keybindings.RuntimeKeybindings,
    contexts: []const keybindings.BindingContext,
) !void {
    const fd = std.Io.File.stdin().handle;
    const total_lines = todoOverlayLineCount(data.text);
    var scroll_offset: usize = 0;

    while (true) {
        const visible_rows = todoOverlayVisibleRows(total_lines, terminalRows(), bottom_margin_rows);
        const effective_lines = if (total_lines == 0) @as(usize, 1) else total_lines;
        const max_scroll = if (effective_lines > visible_rows) effective_lines - visible_rows else 0;
        if (scroll_offset > max_scroll) scroll_offset = max_scroll;

        renderTodoOverlay(data, total_lines, scroll_offset, bottom_margin_rows);

        var chord_buf: [24]u8 = undefined;
        const key = readPickerKey(fd, &chord_buf) catch {
            clearTodoOverlay(total_lines, bottom_margin_rows);
            return;
        };
        const ev = resolvePickerBinding(bindings, contexts, key.chord, key.event);

        switch (ev) {
            .up => {
                if (scroll_offset > 0) scroll_offset -= 1;
            },
            .down, .next => {
                if (scroll_offset < max_scroll) scroll_offset += 1;
            },
            .select, .tab, .shift_tab, .toggle, .cancel => {
                clearTodoOverlay(total_lines, bottom_margin_rows);
                return;
            },
            .char => {
                if (key.char == 'q' or key.char == 'Q') {
                    clearTodoOverlay(total_lines, bottom_margin_rows);
                    return;
                }
            },
            .backspace, .none => {},
        }
    }
}

fn renderTodoOverlay(data: TodoOverlayData, total_lines: usize, scroll_offset: usize, bottom_margin_rows: usize) void {
    const rows = terminalRows();
    const cols = terminalCols();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;
    const bottom_row = if (status_row > 1) status_row - 1 else 1;

    const visible_rows = todoOverlayVisibleRows(total_lines, rows, bottom_margin_rows);
    const overlay_rows = todoOverlayRows(total_lines, rows, bottom_margin_rows);
    const top_row = if (bottom_row >= overlay_rows) bottom_row - overlay_rows + 1 else 1;

    var box_w: usize = if (cols < 56) cols else if (cols < 96) cols else 96;
    if (box_w < 4) box_w = 4;
    const inner = box_w - 2;

    const effective_lines = if (total_lines == 0) @as(usize, 1) else total_lines;
    const end_line = @min(scroll_offset + visible_rows, effective_lines);

    var seq: [8192]u8 = undefined;
    var pos: usize = 0;
    appendLiteral(&seq, &pos, "\x1b7");

    appendSimpleOverlayBorder(&seq, &pos, top_row, inner);
    var title_buf: [160]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, " {s}", .{data.title}) catch data.title;
    appendSimpleOverlayLine(&seq, &pos, top_row + 1, inner, title);

    var row_idx: usize = 0;
    while (row_idx < visible_rows) : (row_idx += 1) {
        const line_text = if (total_lines == 0)
            data.empty_text
        else
            previewLineAt(data.text, scroll_offset + row_idx);
        var sanitized_buf: [256]u8 = undefined;
        const sanitized = sanitizeText(line_text, &sanitized_buf);
        appendSimpleOverlayLine(&seq, &pos, top_row + 2 + row_idx, inner, sanitized);
    }

    var footer_buf: [160]u8 = undefined;
    const footer = if (effective_lines > visible_rows)
        std.fmt.bufPrint(&footer_buf, " {s}  •  ↑↓ scroll  •  {d}-{d} of {d}", .{ data.close_hint, scroll_offset + 1, end_line, effective_lines }) catch data.close_hint
    else
        data.close_hint;
    appendSimpleOverlayLine(&seq, &pos, top_row + 2 + visible_rows, inner, footer);
    appendSimpleOverlayBottomBorder(&seq, &pos, top_row + 3 + visible_rows, inner);

    appendLiteral(&seq, &pos, "\x1b8");
    _ = std.c.write(std.Io.File.stdout().handle, (seq[0..pos]).ptr, (seq[0..pos]).len);
}

fn clearTodoOverlay(total_lines: usize, bottom_margin_rows: usize) void {
    const rows = terminalRows();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;
    const bottom_row = if (status_row > 1) status_row - 1 else 1;
    const overlay_rows = todoOverlayRows(total_lines, rows, bottom_margin_rows);
    const top_row = if (bottom_row >= overlay_rows) bottom_row - overlay_rows + 1 else 1;

    var seq: [2048]u8 = undefined;
    var pos: usize = 0;
    appendLiteral(&seq, &pos, "\x1b7");
    var row: usize = 0;
    while (row < overlay_rows) : (row += 1) {
        appendCursorTo(&seq, &pos, top_row + row);
        appendLiteral(&seq, &pos, "\x1b[2K");
    }
    appendLiteral(&seq, &pos, "\x1b8");
    _ = std.c.write(std.Io.File.stdout().handle, (seq[0..pos]).ptr, (seq[0..pos]).len);
}

const BACKGROUND_TASK_LIST_ROWS: usize = 8;
const BACKGROUND_TASK_PREVIEW_ROWS: usize = 7;

fn backgroundTasksOverlayRows(item_count: usize) usize {
    const visible = if (item_count == 0) @as(usize, 1) else @min(item_count, BACKGROUND_TASK_LIST_ROWS);
    return visible + BACKGROUND_TASK_PREVIEW_ROWS + 6;
}

fn backgroundTaskIsActive(status: []const u8) bool {
    return std.mem.eql(u8, status, "running") or std.mem.eql(u8, status, "queued") or std.mem.eql(u8, status, "open");
}

fn backgroundTaskCanStop(status: []const u8) bool {
    return std.mem.eql(u8, status, "running") or std.mem.eql(u8, status, "queued");
}

pub fn runBackgroundTasksOverlayLoop(
    data: BackgroundTasksData,
    bottom_margin_rows: usize,
    bindings: ?*const keybindings.RuntimeKeybindings,
) !?BackgroundTasksResult {
    const fd = std.Io.File.stdin().handle;
    var selected: usize = if (data.items.len == 0) 0 else @min(data.initial_selection, data.items.len - 1);
    const contexts = [_]keybindings.BindingContext{ .Confirmation, .Select };
    defer clearBackgroundTasksOverlay(data.items.len, bottom_margin_rows);

    while (true) {
        renderBackgroundTasksOverlay(data, selected, bottom_margin_rows);

        var chord_buf: [24]u8 = undefined;
        const key = readPickerKey(fd, &chord_buf) catch return null;
        const ev = resolvePickerBinding(bindings, &contexts, key.chord, key.event);

        switch (ev) {
            .up => {
                if (data.items.len > 0) {
                    selected = if (selected == 0) data.items.len - 1 else selected - 1;
                }
            },
            .down, .next => {
                if (data.items.len > 0) {
                    selected = (selected + 1) % data.items.len;
                }
            },
            .select => {
                if (data.items.len == 0) continue;
                return .{ .item_index = selected, .action = .view };
            },
            .cancel => return null,
            .char => {
                if (key.char == 'q' or key.char == 'Q') return null;
                if (key.char == 'r' or key.char == 'R') {
                    return .{ .item_index = selected, .action = .refresh };
                }
                if (data.items.len == 0) continue;
                if (key.char == 'x' or key.char == 'X') {
                    if (backgroundTaskCanStop(data.items[selected].status)) {
                        return .{ .item_index = selected, .action = .stop };
                    }
                    continue;
                }
                if (key.char == 'o' or key.char == 'O' or key.char == 'v' or key.char == 'V' or key.char == 'e' or key.char == 'E') {
                    return .{ .item_index = selected, .action = .view };
                }
            },
            .tab, .shift_tab, .toggle, .backspace, .none => {},
        }
    }
}

fn renderBackgroundTasksOverlay(data: BackgroundTasksData, selected: usize, bottom_margin_rows: usize) void {
    const rows = terminalRows();
    const cols = terminalCols();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;
    const overlay_rows = backgroundTasksOverlayRows(data.items.len);
    const bottom_row = if (status_row > 1) status_row - 1 else 1;
    const top_row = if (bottom_row >= overlay_rows) bottom_row - overlay_rows + 1 else 1;

    var box_w: usize = if (cols < 72) cols else if (cols < 116) cols else 116;
    if (box_w < 4) box_w = 4;
    const inner = box_w - 2;
    const visible = if (data.items.len == 0) @as(usize, 1) else @min(data.items.len, BACKGROUND_TASK_LIST_ROWS);

    var active_count: usize = 0;
    for (data.items) |item| {
        if (backgroundTaskIsActive(item.status)) active_count += 1;
    }

    var start: usize = 0;
    if (data.items.len > visible and visible > 0) {
        const half = visible / 2;
        if (selected > half) start = selected - half;
        if (start + visible > data.items.len) start = data.items.len - visible;
    }

    var seq: [16384]u8 = undefined;
    var pos: usize = 0;
    appendLiteral(&seq, &pos, "\x1b7");

    var clear_row: usize = 0;
    while (clear_row < overlay_rows) : (clear_row += 1) {
        appendCursorTo(&seq, &pos, top_row + clear_row);
        appendLiteral(&seq, &pos, "\x1b[2K");
    }

    appendSimpleOverlayBorder(&seq, &pos, top_row, inner);

    var title_buf: [160]u8 = undefined;
    const title = std.fmt.bufPrint(
        &title_buf,
        " Background tasks  •  {d} active  •  {d} total",
        .{ active_count, data.items.len },
    ) catch " Background tasks";
    appendSimpleOverlayLine(&seq, &pos, top_row + 1, inner, title);

    var row: usize = 0;
    while (row < visible) : (row += 1) {
        if (data.items.len == 0) {
            appendSimpleOverlayLine(&seq, &pos, top_row + 2 + row, inner, " No managed background tasks found");
            continue;
        }

        const item = data.items[start + row];
        const label = if (std.mem.trim(u8, item.title, " \t").len > 0) item.title else item.id;
        var label_buf: [256]u8 = undefined;
        const label_summary = summarizePromptLine(label, &label_buf);
        const owner = std.mem.trim(u8, item.owner, " \t");
        const priority = std.mem.trim(u8, item.priority, " \t");
        var meta_buf: [96]u8 = undefined;
        const meta = if (owner.len > 0 and priority.len > 0)
            (std.fmt.bufPrint(&meta_buf, "{s}/{s}", .{ owner, priority }) catch item.status)
        else if (owner.len > 0)
            owner
        else if (priority.len > 0)
            priority
        else
            item.status;

        var line_buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(
            &line_buf,
            " {s} [{s}] {s} ({d}%)",
            .{
                if (start + row == selected) ">" else " ",
                meta,
                label_summary,
                item.progress,
            },
        ) catch label_summary;
        appendSimpleOverlayLine(&seq, &pos, top_row + 2 + row, inner, line);
    }

    const divider_row = top_row + 2 + visible;
    appendSimpleOverlayDivider(&seq, &pos, divider_row, inner);

    var preview_row: usize = 0;
    while (preview_row < BACKGROUND_TASK_PREVIEW_ROWS) : (preview_row += 1) {
        const line_text = if (data.items.len == 0)
            if (preview_row == 0) " Start a managed background task with TaskRun or a tool that uses it." else if (preview_row == 1) " Use r to refresh while waiting for tasks to appear." else ""
        else if (preview_row == 0) blk: {
            const item = data.items[selected];
            var meta_buf: [256]u8 = undefined;
            break :blk std.fmt.bufPrint(
                &meta_buf,
                " status={s}  owner={s}  priority={s}  pid={d}",
                .{
                    item.status,
                    if (item.owner.len > 0) item.owner else "-",
                    if (item.priority.len > 0) item.priority else "-",
                    item.run_pid,
                },
            ) catch item.status;
        } else previewLineAt(data.items[selected].detail, preview_row);
        appendSimpleOverlayLine(&seq, &pos, divider_row + 1 + preview_row, inner, line_text);
    }

    const footer_row = divider_row + 1 + BACKGROUND_TASK_PREVIEW_ROWS;
    const footer = blk: {
        if (data.items.len == 0) break :blk " R refresh  •  Esc close";
        if (backgroundTaskCanStop(data.items[selected].status)) {
            break :blk " Enter inspect  •  X stop  •  R refresh  •  Esc close";
        }
        break :blk " Enter inspect  •  R refresh  •  Esc close";
    };
    appendSimpleOverlayLine(&seq, &pos, footer_row, inner, footer);
    appendSimpleOverlayBottomBorder(&seq, &pos, footer_row + 1, inner);

    appendLiteral(&seq, &pos, "\x1b8");
    _ = std.c.write(std.Io.File.stdout().handle, (seq[0..pos]).ptr, (seq[0..pos]).len);
}

fn clearBackgroundTasksOverlay(item_count: usize, bottom_margin_rows: usize) void {
    const rows = terminalRows();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;
    const overlay_rows = backgroundTasksOverlayRows(item_count);
    const bottom_row = if (status_row > 1) status_row - 1 else 1;
    const top_row = if (bottom_row >= overlay_rows) bottom_row - overlay_rows + 1 else 1;

    var seq: [4096]u8 = undefined;
    var pos: usize = 0;
    appendLiteral(&seq, &pos, "\x1b7");
    var row: usize = 0;
    while (row < overlay_rows) : (row += 1) {
        appendCursorTo(&seq, &pos, top_row + row);
        appendLiteral(&seq, &pos, "\x1b[2K");
    }
    appendLiteral(&seq, &pos, "\x1b8");
    _ = std.c.write(std.Io.File.stdout().handle, (seq[0..pos]).ptr, (seq[0..pos]).len);
}

const TranscriptNavEvent = enum {
    up,
    down,
    page_up,
    page_down,
    top,
    bottom,
    next_match,
    prev_match,
    toggle,
    select,
    cancel,
    backspace,
    search,
    export_editor,
    dump_scrollback,
    char,
    none,
};

const TranscriptKey = struct {
    event: TranscriptNavEvent,
    char: u8 = 0,
    chord: []const u8 = "",
};

const TranscriptLineRange = struct {
    start: usize,
    end: usize,
};

fn transcriptOverlayVisibleRows(line_count: usize, rows: usize, bottom_margin_rows: usize, show_all: bool) usize {
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;
    const bottom_row = if (status_row > 1) status_row - 1 else 1;
    const available_rows = @max(bottom_row, @as(usize, 1));
    const body_budget = if (available_rows > 7) available_rows - 6 else 1;
    const max_body_rows = if (show_all) body_budget else @min(@as(usize, 10), body_budget);
    const effective_lines = if (line_count == 0) @as(usize, 1) else line_count;
    return @min(effective_lines, max_body_rows);
}

fn transcriptOverlayRows(line_count: usize, rows: usize, bottom_margin_rows: usize, show_all: bool) usize {
    return transcriptOverlayVisibleRows(line_count, rows, bottom_margin_rows, show_all) + 5;
}

fn buildTranscriptLineRanges(allocator: std.mem.Allocator, text: []const u8) ![]TranscriptLineRange {
    const trimmed = std.mem.trimEnd(u8, text, "\r\n");
    if (trimmed.len == 0) return allocator.alloc(TranscriptLineRange, 0);

    var lines = std.array_list.Managed(TranscriptLineRange).init(allocator);
    errdefer lines.deinit();

    var start: usize = 0;
    var i: usize = 0;
    while (i <= trimmed.len) : (i += 1) {
        if (i != trimmed.len and trimmed[i] != '\n') continue;
        try lines.append(.{ .start = start, .end = i });
        start = i + 1;
    }

    return try lines.toOwnedSlice();
}

fn transcriptLineAt(text: []const u8, lines: []const TranscriptLineRange, idx: usize) []const u8 {
    if (idx >= lines.len) return "";
    return text[lines[idx].start..lines[idx].end];
}

fn buildTranscriptMatches(
    allocator: std.mem.Allocator,
    text: []const u8,
    lines: []const TranscriptLineRange,
    query: []const u8,
) ![]usize {
    if (query.len == 0 or lines.len == 0) return allocator.alloc(usize, 0);

    var matches = std.array_list.Managed(usize).init(allocator);
    errdefer matches.deinit();

    for (lines, 0..) |line, idx| {
        const line_text = text[line.start..line.end];
        if (@import("../core/parse_helpers.zig").containsIgnoreCase(line_text, query)) {
            try matches.append(idx);
        }
    }

    return try matches.toOwnedSlice();
}

fn centerTranscriptScroll(target_line: usize, visible_rows: usize, line_count: usize) usize {
    if (line_count <= visible_rows) return 0;
    const half = visible_rows / 2;
    var start = if (target_line > half) target_line - half else 0;
    if (start + visible_rows > line_count) start = line_count - visible_rows;
    return start;
}

fn findCurrentTranscriptMatch(matches: []const usize, line_idx: usize) ?usize {
    for (matches, 0..) |match_line, idx| {
        if (match_line == line_idx) return idx;
    }
    return null;
}

fn pickTranscriptEditor() []const u8 {
    if (@import("../core/env.zig").getenv("VISUAL")) |value| {
        if (value.len > 0) return value;
    }
    if (@import("../core/env.zig").getenv("EDITOR")) |value| {
        if (value.len > 0) return value;
    }
    return "vi";
}

fn appendSingleQuotedShell(out: *std_io.StringBuilder, text: []const u8) !void {
    try out.append('\'');
    for (text) |ch| {
        if (ch == '\'') {
            try out.appendSlice("'\"'\"'");
        } else {
            try out.append(ch);
        }
    }
    try out.append('\'');
}

fn buildTranscriptEditorCommand(allocator: std.mem.Allocator, editor: []const u8, path: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    try out.appendSlice(editor);
    try out.append(' ');
    try appendSingleQuotedShell(&out, path);
    return try out.toOwnedSlice();
}

fn writeTranscriptToTempFile(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const tmp_dir = @import("../core/env.zig").getenv("TMPDIR") orelse "/tmp";

    var attempt: usize = 0;
    while (attempt < 8) : (attempt += 1) {
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/zcode-transcript-{d}-{d}.txt",
            .{ tmp_dir, clock.nowMillis(), attempt },
        );
        errdefer allocator.free(path);

        if (std.Io.Dir.cwd().createFile(rt.io, path, .{ .exclusive = true, .permissions = std.Io.File.Permissions.fromMode(0o600) })) |file| {
            defer file.close(rt.io);
            try file.writeStreamingAll(rt.io, text);
            return path;
        } else |err| switch (err) {
            error.PathAlreadyExists => allocator.free(path),
            else => return err,
        }
    }

    return error.PathAlreadyExists;
}

fn openTranscriptInExternalEditor(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const path = try writeTranscriptToTempFile(allocator, text);
    defer allocator.free(path);

    const editor = pickTranscriptEditor();
    const command = try buildTranscriptEditorCommand(allocator, editor, path);
    defer allocator.free(command);

    const result = try std.process.run(allocator, rt.io, .{
        .argv = &.{ "/bin/sh", "-lc", command },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return switch (result.term) {
        .exited => |code| if (code == 0)
            std.fmt.allocPrint(allocator, "transcript saved to {s} and opened in {s}", .{ path, editor })
        else
            std.fmt.allocPrint(allocator, "transcript saved to {s} (editor exited {d})", .{ path, code }),
        else => std.fmt.allocPrint(allocator, "transcript saved to {s} (editor terminated abnormally)", .{path}),
    };
}

fn dumpTranscriptToScrollback(text: []const u8) void {
    const stdout = std_io.stdoutWriter();
    stdout.writeAll("\n=== transcript dump ===\n") catch {};
    stdout.writeAll(text) catch {};
    if (text.len == 0 or text[text.len - 1] != '\n') stdout.writeByte('\n') catch {};
    stdout.writeAll("=== end transcript dump ===\n") catch {};
}

fn readTranscriptKey(fd: std.posix.fd_t, chord_buf: *[24]u8) !TranscriptKey {
    const ch = try readOneByte(fd);
    switch (ch) {
        '\r', '\n' => return .{ .event = .select, .chord = "enter" },
        0x03 => return .{ .event = .cancel, .chord = "ctrl+c" },
        0x04 => return .{ .event = .page_down, .chord = "ctrl+d" },
        0x05 => return .{ .event = .toggle, .chord = "ctrl+e" },
        0x15 => return .{ .event = .page_up, .chord = "ctrl+u" },
        0x7f, 0x08 => return .{ .event = .backspace, .chord = "backspace" },
        0x1b => {
            var poll_fds = [1]std.posix.pollfd{.{
                .fd = fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const ready = std.posix.poll(&poll_fds, 30) catch 0;
            if (ready == 0) return .{ .event = .cancel, .chord = "escape" };

            const second = readOneByte(fd) catch return .{ .event = .cancel, .chord = "escape" };
            if (second != '[') return .{ .event = .cancel, .chord = "escape" };

            var seq: [32]u8 = undefined;
            seq[0] = readOneByte(fd) catch return .{ .event = .none };
            var len: usize = 1;
            while (len < seq.len) : (len += 1) {
                const byte = seq[len - 1];
                if (byte >= 0x40 and byte <= 0x7E) break;
                seq[len] = readOneByte(fd) catch return .{ .event = .none };
            }

            const final = seq[len - 1];
            if (final == 'u') {
                if (repl_input.parseKittyKeyPayload(seq[0 .. len - 1])) |key| {
                    const has_ctrl = (key.mods >= 5) and (((key.mods - 1) & 4) != 0);
                    if (has_ctrl and (key.codepoint == 101 or key.codepoint == 69 or key.codepoint == 5)) return .{ .event = .toggle, .chord = "ctrl+e" };
                    if (has_ctrl and (key.codepoint == 117 or key.codepoint == 85 or key.codepoint == 21)) return .{ .event = .page_up, .chord = "ctrl+u" };
                    if (has_ctrl and (key.codepoint == 100 or key.codepoint == 68 or key.codepoint == 4)) return .{ .event = .page_down, .chord = "ctrl+d" };
                    if (key.codepoint == 13 or key.codepoint == 10) return .{ .event = .select, .chord = "enter" };
                    if (key.codepoint == 27) return .{ .event = .cancel, .chord = "escape" };
                    if (key.codepoint == 127 or key.codepoint == 8) return .{ .event = .backspace, .chord = "backspace" };
                }
            }

            return switch (final) {
                'A' => .{ .event = .up, .chord = "up" },
                'B' => .{ .event = .down, .chord = "down" },
                'H' => .{ .event = .top, .chord = "home" },
                'F' => .{ .event = .bottom, .chord = "end" },
                '~' => switch (seq[0]) {
                    '5' => .{ .event = .page_up, .chord = "pageup" },
                    '6' => .{ .event = .page_down, .chord = "pagedown" },
                    '1', '7' => .{ .event = .top, .chord = "home" },
                    '4', '8' => .{ .event = .bottom, .chord = "end" },
                    else => .{ .event = .none },
                },
                else => .{ .event = .none },
            };
        },
        else => {
            if (ch >= 0x20 and ch < 0x7f) {
                chord_buf[0] = std.ascii.toLower(ch);
                return switch (ch) {
                    '/' => .{ .event = .search, .char = ch, .chord = chord_buf[0..1] },
                    'v', 'V' => .{ .event = .export_editor, .char = ch, .chord = chord_buf[0..1] },
                    '[' => .{ .event = .dump_scrollback, .char = ch, .chord = chord_buf[0..1] },
                    'n' => .{ .event = .next_match, .char = ch, .chord = chord_buf[0..1] },
                    'N' => .{ .event = .prev_match, .char = ch, .chord = chord_buf[0..1] },
                    else => .{ .event = .char, .char = ch, .chord = chord_buf[0..1] },
                };
            }
            return .{ .event = .none };
        },
    }
}

pub fn runTranscriptOverlayLoop(
    data: TranscriptOverlayData,
    bottom_margin_rows: usize,
    bindings: ?*const keybindings.RuntimeKeybindings,
) !void {
    const fd = std.Io.File.stdin().handle;
    const line_ranges = try buildTranscriptLineRanges(data.allocator, data.text);
    defer data.allocator.free(line_ranges);

    var show_all = false;
    var scroll_offset: usize = 0;
    var query_buf: [256]u8 = undefined;
    var query_len: usize = 0;
    var previous_query_buf: [256]u8 = undefined;
    var previous_query_len: usize = 0;
    var search_open = false;
    var matches = try data.allocator.alloc(usize, 0);
    defer data.allocator.free(matches);
    var current_match: usize = 0;
    var status: ?[]u8 = null;
    defer if (status) |msg| data.allocator.free(msg);

    while (true) {
        const visible_rows = transcriptOverlayVisibleRows(line_ranges.len, terminalRows(), bottom_margin_rows, show_all);
        const effective_lines = if (line_ranges.len == 0) @as(usize, 1) else line_ranges.len;
        const max_scroll = if (effective_lines > visible_rows) effective_lines - visible_rows else 0;
        if (scroll_offset > max_scroll) scroll_offset = max_scroll;

        renderTranscriptOverlay(
            data.text,
            line_ranges,
            scroll_offset,
            show_all,
            query_buf[0..query_len],
            matches,
            current_match,
            search_open,
            status,
            bottom_margin_rows,
        );

        var chord_buf: [24]u8 = undefined;
        const key = readTranscriptKey(fd, &chord_buf) catch {
            clearTranscriptOverlay(line_ranges.len, terminalRows(), bottom_margin_rows, show_all);
            return;
        };
        const ev = resolveTranscriptBinding(bindings, key.chord, key.event);

        switch (ev) {
            .up => {
                if (scroll_offset > 0) scroll_offset -= 1;
                if (status) |msg| {
                    data.allocator.free(msg);
                    status = null;
                }
            },
            .down => {
                if (scroll_offset < max_scroll) scroll_offset += 1;
                if (status) |msg| {
                    data.allocator.free(msg);
                    status = null;
                }
            },
            .page_up => {
                const step = if (visible_rows > 0) visible_rows else 1;
                scroll_offset = if (scroll_offset > step) scroll_offset - step else 0;
                if (status) |msg| {
                    data.allocator.free(msg);
                    status = null;
                }
            },
            .page_down => {
                const step = if (visible_rows > 0) visible_rows else 1;
                scroll_offset = @min(scroll_offset + step, max_scroll);
                if (status) |msg| {
                    data.allocator.free(msg);
                    status = null;
                }
            },
            .top => {
                scroll_offset = 0;
                if (matches.len > 0) current_match = 0;
                if (status) |msg| {
                    data.allocator.free(msg);
                    status = null;
                }
            },
            .bottom => {
                scroll_offset = max_scroll;
                if (matches.len > 0) current_match = matches.len - 1;
                if (status) |msg| {
                    data.allocator.free(msg);
                    status = null;
                }
            },
            .next_match => {
                if (search_open) {
                    if (query_len < query_buf.len) {
                        query_buf[query_len] = 'n';
                        query_len += 1;
                        data.allocator.free(matches);
                        matches = try buildTranscriptMatches(data.allocator, data.text, line_ranges, query_buf[0..query_len]);
                        current_match = 0;
                        if (matches.len > 0) scroll_offset = centerTranscriptScroll(matches[current_match], visible_rows, line_ranges.len);
                    }
                } else if (matches.len > 0) {
                    current_match = (current_match + 1) % matches.len;
                    scroll_offset = centerTranscriptScroll(matches[current_match], visible_rows, line_ranges.len);
                }
                if (status) |msg| {
                    data.allocator.free(msg);
                    status = null;
                }
            },
            .prev_match => {
                if (search_open) {
                    if (query_len < query_buf.len) {
                        query_buf[query_len] = 'N';
                        query_len += 1;
                        data.allocator.free(matches);
                        matches = try buildTranscriptMatches(data.allocator, data.text, line_ranges, query_buf[0..query_len]);
                        current_match = 0;
                        if (matches.len > 0) scroll_offset = centerTranscriptScroll(matches[current_match], visible_rows, line_ranges.len);
                    }
                } else if (matches.len > 0) {
                    current_match = if (current_match == 0) matches.len - 1 else current_match - 1;
                    scroll_offset = centerTranscriptScroll(matches[current_match], visible_rows, line_ranges.len);
                }
                if (status) |msg| {
                    data.allocator.free(msg);
                    status = null;
                }
            },
            .toggle => {
                show_all = !show_all;
                if (matches.len > 0) {
                    scroll_offset = centerTranscriptScroll(matches[current_match], transcriptOverlayVisibleRows(line_ranges.len, terminalRows(), bottom_margin_rows, show_all), line_ranges.len);
                }
                if (status) |msg| {
                    data.allocator.free(msg);
                    status = null;
                }
            },
            .select => {
                if (search_open) search_open = false;
            },
            .cancel => {
                if (search_open) {
                    @memcpy(query_buf[0..previous_query_len], previous_query_buf[0..previous_query_len]);
                    query_len = previous_query_len;
                    data.allocator.free(matches);
                    matches = try buildTranscriptMatches(data.allocator, data.text, line_ranges, query_buf[0..query_len]);
                    current_match = 0;
                    if (matches.len > 0) scroll_offset = centerTranscriptScroll(matches[current_match], visible_rows, line_ranges.len);
                    search_open = false;
                    if (status) |msg| {
                        data.allocator.free(msg);
                        status = null;
                    }
                    continue;
                }
                clearTranscriptOverlay(line_ranges.len, terminalRows(), bottom_margin_rows, show_all);
                return;
            },
            .backspace => {
                if (search_open and query_len > 0) {
                    query_len -= 1;
                    data.allocator.free(matches);
                    matches = try buildTranscriptMatches(data.allocator, data.text, line_ranges, query_buf[0..query_len]);
                    current_match = 0;
                    if (matches.len > 0) {
                        scroll_offset = centerTranscriptScroll(matches[current_match], visible_rows, line_ranges.len);
                    }
                }
                if (status) |msg| {
                    data.allocator.free(msg);
                    status = null;
                }
            },
            .search => {
                if (!search_open) {
                    previous_query_len = query_len;
                    @memcpy(previous_query_buf[0..query_len], query_buf[0..query_len]);
                    search_open = true;
                } else if (query_len < query_buf.len) {
                    query_buf[query_len] = '/';
                    query_len += 1;
                    data.allocator.free(matches);
                    matches = try buildTranscriptMatches(data.allocator, data.text, line_ranges, query_buf[0..query_len]);
                    current_match = 0;
                    if (matches.len > 0) scroll_offset = centerTranscriptScroll(matches[current_match], visible_rows, line_ranges.len);
                }
                if (status) |msg| {
                    data.allocator.free(msg);
                    status = null;
                }
            },
            .export_editor => {
                if (!search_open) {
                    if (status) |msg| data.allocator.free(msg);
                    status = openTranscriptInExternalEditor(data.allocator, data.text) catch |err|
                        try std.fmt.allocPrint(data.allocator, "transcript export failed: {s}", .{@errorName(err)});
                } else if (query_len < query_buf.len) {
                    query_buf[query_len] = key.char;
                    query_len += 1;
                    data.allocator.free(matches);
                    matches = try buildTranscriptMatches(data.allocator, data.text, line_ranges, query_buf[0..query_len]);
                    current_match = 0;
                    if (matches.len > 0) scroll_offset = centerTranscriptScroll(matches[current_match], visible_rows, line_ranges.len);
                }
            },
            .dump_scrollback => {
                if (!search_open) {
                    clearTranscriptOverlay(line_ranges.len, terminalRows(), bottom_margin_rows, show_all);
                    dumpTranscriptToScrollback(data.text);
                    if (status) |msg| data.allocator.free(msg);
                    status = try data.allocator.dupe(u8, "transcript dumped to terminal scrollback");
                } else if (query_len < query_buf.len) {
                    query_buf[query_len] = '[';
                    query_len += 1;
                    data.allocator.free(matches);
                    matches = try buildTranscriptMatches(data.allocator, data.text, line_ranges, query_buf[0..query_len]);
                    current_match = 0;
                    if (matches.len > 0) scroll_offset = centerTranscriptScroll(matches[current_match], visible_rows, line_ranges.len);
                }
            },
            .char => {
                if (search_open) {
                    if (query_len < query_buf.len) {
                        query_buf[query_len] = key.char;
                        query_len += 1;
                        data.allocator.free(matches);
                        matches = try buildTranscriptMatches(data.allocator, data.text, line_ranges, query_buf[0..query_len]);
                        current_match = 0;
                        if (matches.len > 0) {
                            scroll_offset = centerTranscriptScroll(matches[current_match], visible_rows, line_ranges.len);
                        }
                    }
                    if (status) |msg| {
                        data.allocator.free(msg);
                        status = null;
                    }
                    continue;
                }

                switch (key.char) {
                    'q', 'Q' => {
                        clearTranscriptOverlay(line_ranges.len, terminalRows(), bottom_margin_rows, show_all);
                        return;
                    },
                    'j' => {
                        if (scroll_offset < max_scroll) scroll_offset += 1;
                    },
                    'k' => {
                        if (scroll_offset > 0) scroll_offset -= 1;
                    },
                    'g' => {
                        scroll_offset = 0;
                    },
                    'G' => {
                        scroll_offset = max_scroll;
                    },
                    else => {},
                }

                if (matches.len > 0) {
                    const focus_line = @min(scroll_offset, line_ranges.len - 1);
                    if (findCurrentTranscriptMatch(matches, focus_line)) |match_idx| current_match = match_idx;
                }
                if (status) |msg| {
                    data.allocator.free(msg);
                    status = null;
                }
            },
            .none => {},
        }
    }
}

fn renderTranscriptOverlay(
    text: []const u8,
    lines: []const TranscriptLineRange,
    scroll_offset: usize,
    show_all: bool,
    query: []const u8,
    matches: []const usize,
    current_match: usize,
    search_open: bool,
    status: ?[]const u8,
    bottom_margin_rows: usize,
) void {
    const rows = terminalRows();
    const cols = terminalCols();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;
    const bottom_row = if (status_row > 1) status_row - 1 else 1;

    const visible_rows = transcriptOverlayVisibleRows(lines.len, rows, bottom_margin_rows, show_all);
    const overlay_rows = transcriptOverlayRows(lines.len, rows, bottom_margin_rows, show_all);
    const top_row = if (bottom_row >= overlay_rows) bottom_row - overlay_rows + 1 else 1;

    var box_w: usize = if (cols < 72) cols else if (cols < 120) cols else 120;
    if (box_w < 4) box_w = 4;
    const inner = box_w - 2;

    var seq: [65536]u8 = undefined;
    var pos: usize = 0;
    appendLiteral(&seq, &pos, "\x1b7");

    appendCursorTo(&seq, &pos, top_row);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x8c");
    appendRepeatByte(&seq, &pos, "\xe2\x94\x80", inner);
    appendLiteral(&seq, &pos, "\xe2\x94\x90" ++ CLR_RESET);

    appendCursorTo(&seq, &pos, top_row + 1);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 " ++ CLR_HEADER ++ "TRANSCRIPT" ++ CLR_RESET);
    var title_meta_buf: [160]u8 = undefined;
    const title_meta = std.fmt.bufPrint(
        &title_meta_buf,
        "{s}{s}{s}  {d} lines",
        .{
            CLR_LABEL,
            if (show_all) "expanded" else "compact",
            CLR_VALUE,
            lines.len,
        },
    ) catch "";
    const title_meta_inner = if (inner > 12) inner - 11 else 0;
    appendLiteral(&seq, &pos, " ");
    if (title_meta_inner > 0) {
        const clipped_meta = clipAnsiByVisibleWidth(title_meta, title_meta_inner);
        appendLiteral(&seq, &pos, clipped_meta);
        const meta_visible = visibleLenAnsi(clipped_meta);
        if (title_meta_inner > meta_visible) appendRepeatByte(&seq, &pos, " ", title_meta_inner - meta_visible);
    }
    appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);

    appendCursorTo(&seq, &pos, top_row + 2);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 " ++ CLR_SEARCH ++ "search: " ++ CLR_RESET);
    const search_inner = if (inner > 10) inner - 9 else 0;
    if (query.len > 0 or search_open) {
        appendLiteral(&seq, &pos, CLR_VALUE);
        const clipped_query = if (query.len > search_inner) query[0..search_inner] else query;
        appendLiteral(&seq, &pos, clipped_query);
        appendLiteral(&seq, &pos, CLR_RESET);
        if (search_inner > clipped_query.len) appendRepeatByte(&seq, &pos, " ", search_inner - clipped_query.len);
    } else {
        const hint = CLR_HINT ++ "type / to search, n/N to jump matches" ++ CLR_RESET;
        const clipped_hint = clipAnsiByVisibleWidth(hint, search_inner);
        appendLiteral(&seq, &pos, clipped_hint);
        const hint_visible = visibleLenAnsi(clipped_hint);
        if (search_inner > hint_visible) appendRepeatByte(&seq, &pos, " ", search_inner - hint_visible);
    }
    appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);

    appendCursorTo(&seq, &pos, top_row + 3);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x9c");
    appendRepeatByte(&seq, &pos, "\xe2\x94\x80", inner);
    appendLiteral(&seq, &pos, "\xe2\x94\xa4" ++ CLR_RESET);

    var row_idx: usize = 0;
    while (row_idx < visible_rows) : (row_idx += 1) {
        appendCursorTo(&seq, &pos, top_row + 4 + row_idx);
        appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 " ++ CLR_RESET);

        const text_width = if (inner > 3) inner - 3 else 0;
        if (lines.len == 0) {
            appendLiteral(&seq, &pos, CLR_HINT ++ "transcript: empty" ++ CLR_RESET);
            if (text_width > 17) appendRepeatByte(&seq, &pos, " ", text_width - 17);
            appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);
            continue;
        }

        const line_idx = scroll_offset + row_idx;
        const line_text = transcriptLineAt(text, lines, line_idx);
        const is_current_match = matches.len > 0 and current_match < matches.len and matches[current_match] == line_idx;
        const is_match = query.len > 0 and @import("../core/parse_helpers.zig").containsIgnoreCase(line_text, query);

        if (is_current_match) {
            appendLiteral(&seq, &pos, CLR_ACTIVE ++ ">" ++ CLR_RESET ++ " ");
        } else if (is_match) {
            appendLiteral(&seq, &pos, CLR_SEARCH ++ "•" ++ CLR_RESET ++ " ");
        } else {
            appendLiteral(&seq, &pos, "  ");
        }

        var sanitized_buf: [1024]u8 = undefined;
        const sanitized = sanitizeText(line_text, sanitized_buf[0..]);
        const clipped = if (sanitized.len > text_width) sanitized[0..text_width] else sanitized;

        if (query.len > 0 and is_match) {
            var highlight_buf: [2048]u8 = undefined;
            var stream = std.Io.Writer.fixed(&highlight_buf);
            format.writeHighlightedMatch(&stream, clipped, query) catch {
                appendLiteral(&seq, &pos, CLR_VALUE);
                appendLiteral(&seq, &pos, clipped);
                appendLiteral(&seq, &pos, CLR_RESET);
                if (text_width > clipped.len) appendRepeatByte(&seq, &pos, " ", text_width - clipped.len);
                appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);
                continue;
            };
            appendLiteral(&seq, &pos, CLR_VALUE);
            appendLiteral(&seq, &pos, stream.buffered());
            appendLiteral(&seq, &pos, CLR_RESET);
        } else {
            appendLiteral(&seq, &pos, CLR_VALUE);
            appendLiteral(&seq, &pos, clipped);
            appendLiteral(&seq, &pos, CLR_RESET);
        }
        if (text_width > clipped.len) appendRepeatByte(&seq, &pos, " ", text_width - clipped.len);
        appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);
    }

    appendCursorTo(&seq, &pos, top_row + 4 + visible_rows);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 " ++ CLR_HINT);
    var footer_text: []const u8 = "";
    if (status) |msg| {
        footer_text = msg;
    } else if (search_open) {
        footer_text = "Enter keep  Esc restore  n/N move  q close";
    } else {
        var footer_buf: [256]u8 = undefined;
        footer_text = if (query.len > 0 and matches.len > 0)
            std.fmt.bufPrint(
                &footer_buf,
                "{d}/{d} matches  ·  / search  ·  n/N jump  ·  ctrl+e {s}  ·  v editor  ·  [ scrollback  ·  q close",
                .{ current_match + 1, matches.len, if (show_all) "collapse" else "expand" },
            ) catch "transcript"
        else
            std.fmt.bufPrint(
                &footer_buf,
                "/ search  ·  j/k or ↑↓ scroll  ·  g/G top/bottom  ·  ctrl+e {s}  ·  v editor  ·  [ scrollback  ·  q close",
                .{if (show_all) "collapse" else "expand"},
            ) catch "transcript";
    }
    const footer_inner = if (inner > 2) inner - 2 else 0;
    const clipped_footer = clipAnsiByVisibleWidth(footer_text, footer_inner);
    appendLiteral(&seq, &pos, clipped_footer);
    const footer_visible = visibleLenAnsi(clipped_footer);
    if (footer_inner > footer_visible) appendRepeatByte(&seq, &pos, " ", footer_inner - footer_visible);
    appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);

    appendCursorTo(&seq, &pos, top_row + 5 + visible_rows);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x94");
    appendRepeatByte(&seq, &pos, "\xe2\x94\x80", inner);
    appendLiteral(&seq, &pos, "\xe2\x94\x98" ++ CLR_RESET);

    appendLiteral(&seq, &pos, "\x1b8");
    _ = std.c.write(std.Io.File.stdout().handle, (seq[0..pos]).ptr, (seq[0..pos]).len);
}

fn clearTranscriptOverlay(line_count: usize, rows: usize, bottom_margin_rows: usize, show_all: bool) void {
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;
    const bottom_row = if (status_row > 1) status_row - 1 else 1;
    const overlay_rows = transcriptOverlayRows(line_count, rows, bottom_margin_rows, show_all);
    const top_row = if (bottom_row >= overlay_rows) bottom_row - overlay_rows + 1 else 1;

    var seq: [4096]u8 = undefined;
    var pos: usize = 0;
    appendLiteral(&seq, &pos, "\x1b7");
    var row: usize = 0;
    while (row < overlay_rows) : (row += 1) {
        appendCursorTo(&seq, &pos, top_row + row);
        appendLiteral(&seq, &pos, "\x1b[2K");
    }
    appendLiteral(&seq, &pos, "\x1b8");
    _ = std.c.write(std.Io.File.stdout().handle, (seq[0..pos]).ptr, (seq[0..pos]).len);
}

fn visibleLenAnsi(text: []const u8) usize {
    var len: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != 0x1b) {
            len += 1;
            continue;
        }
        if (i + 1 < text.len and text[i + 1] == '[') {
            i += 2;
            while (i < text.len and !(text[i] >= 0x40 and text[i] <= 0x7e)) : (i += 1) {}
        }
    }
    return len;
}

fn clipAnsiByVisibleWidth(text: []const u8, width: usize) []const u8 {
    if (width == 0 or text.len == 0) return "";

    var visible: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '[') {
            i += 2;
            while (i < text.len and !(text[i] >= 0x40 and text[i] <= 0x7e)) : (i += 1) {}
            if (i < text.len) i += 1;
            continue;
        }
        if (visible == width) break;
        visible += 1;
        i += 1;
    }
    return text[0..@min(i, text.len)];
}

// ── Output style picker ──

fn styleScopeLabel(scope: output_styles.StyleScope) []const u8 {
    return switch (scope) {
        .builtin => "builtin",
        .plugin => "plugin",
        .user => "user",
        .workspace => "workspace",
    };
}

fn stylePickerOverlayRows(item_count: usize) usize {
    const visible = @min(if (item_count == 0) @as(usize, 1) else item_count, @as(usize, 10));
    return visible + 7;
}

fn initialStylePickerSelection(data: StylePickerData) usize {
    for (data.items, 0..) |item, idx| {
        if (std.ascii.eqlIgnoreCase(item.name, data.current_style)) return idx;
    }
    return 0;
}

pub fn runStylePickerOverlayLoop(
    data: StylePickerData,
    bottom_margin_rows: usize,
    bindings: ?*const keybindings.RuntimeKeybindings,
) !?usize {
    if (data.items.len == 0) return null;

    const fd = std.Io.File.stdin().handle;
    var filter_buf: [64]u8 = undefined;
    var filter_len: usize = 0;
    var selected: usize = initialStylePickerSelection(data);
    const contexts = [_]keybindings.BindingContext{.Select};

    while (true) {
        var filtered_indices: [64]usize = undefined;
        var filtered_count: usize = 0;
        for (data.items, 0..) |item, idx| {
            if (filter_len == 0 or
                containsFilter(item.name, filter_buf[0..filter_len]) or
                containsFilter(item.description, filter_buf[0..filter_len]))
            {
                if (filtered_count < filtered_indices.len) {
                    filtered_indices[filtered_count] = idx;
                    filtered_count += 1;
                }
            }
        }

        if (filtered_count > 0 and selected >= filtered_count) selected = filtered_count - 1;

        renderStylePickerOverlay(data, filtered_indices[0..filtered_count], selected, filter_buf[0..filter_len], bottom_margin_rows);

        var chord_buf: [24]u8 = undefined;
        const key = readPickerKey(fd, &chord_buf) catch {
            clearStylePickerOverlay(data.items.len, bottom_margin_rows);
            return null;
        };
        const ev = resolvePickerBinding(bindings, &contexts, key.chord, key.event);

        switch (ev) {
            .up => selected = if (filtered_count == 0) 0 else if (selected == 0) filtered_count - 1 else selected - 1,
            .down, .next => selected = if (filtered_count == 0) 0 else (selected + 1) % filtered_count,
            .select => {
                clearStylePickerOverlay(data.items.len, bottom_margin_rows);
                if (filtered_count == 0) return null;
                return filtered_indices[selected];
            },
            .cancel => {
                clearStylePickerOverlay(data.items.len, bottom_margin_rows);
                return null;
            },
            .backspace => {
                if (filter_len > 0) {
                    filter_len -= 1;
                    selected = 0;
                }
            },
            .char => {
                if (key.char >= 0x20 and key.char < 0x7f and filter_len < filter_buf.len) {
                    filter_buf[filter_len] = key.char;
                    filter_len += 1;
                    selected = 0;
                }
            },
            .tab, .shift_tab, .toggle, .none => {},
        }
    }
}

fn renderStylePickerOverlay(data: StylePickerData, filtered: []const usize, selected: usize, filter: []const u8, bottom_margin_rows: usize) void {
    const rows = terminalRows();
    const cols = terminalCols();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;

    const visible = @min(filtered.len, @as(usize, 10));
    const overlay_rows = stylePickerOverlayRows(data.items.len);
    const bottom_row = if (status_row > 1) status_row - 1 else 1;
    const top_row = if (bottom_row >= overlay_rows) bottom_row - overlay_rows + 1 else 1;

    var box_w: usize = if (cols < 64) cols else if (cols < 104) cols else 104;
    if (box_w < 4) box_w = 4;
    const inner = box_w - 2;

    var start: usize = 0;
    if (filtered.len > visible) {
        const half = visible / 2;
        if (selected > half) start = selected - half;
        if (start + visible > filtered.len) start = filtered.len - visible;
    }

    var seq: [12288]u8 = undefined;
    var pos: usize = 0;
    appendLiteral(&seq, &pos, "\x1b7");

    var clear_row: usize = 0;
    while (clear_row < overlay_rows) : (clear_row += 1) {
        appendCursorTo(&seq, &pos, top_row + clear_row);
        appendLiteral(&seq, &pos, "\x1b[2K");
    }

    appendSimpleOverlayBorder(&seq, &pos, top_row, inner);

    var title_buf: [160]u8 = undefined;
    const title = if (filter.len == 0)
        std.fmt.bufPrint(&title_buf, " Preferred output style  •  current: {s}", .{data.current_style}) catch " Preferred output style"
    else
        std.fmt.bufPrint(&title_buf, " Preferred output style  •  filter: {s}", .{filter}) catch " Preferred output style";
    appendSimpleOverlayLine(&seq, &pos, top_row + 1, inner, title);

    var row: usize = 0;
    while (row < visible) : (row += 1) {
        const item = data.items[filtered[start + row]];
        var line_buf: [512]u8 = undefined;
        const current_marker = if (std.ascii.eqlIgnoreCase(item.name, data.current_style)) "*" else " ";
        const select_marker = if (start + row == selected) ">" else " ";
        const line = std.fmt.bufPrint(
            &line_buf,
            " {s}{s} {s} [{s}] - {s}",
            .{ select_marker, current_marker, item.name, styleScopeLabel(item.scope), item.description },
        ) catch item.name;
        appendSimpleOverlayLine(&seq, &pos, top_row + 2 + row, inner, line);
    }

    const empty_row = top_row + 2 + visible;
    if (visible == 0) {
        appendSimpleOverlayLine(&seq, &pos, top_row + 2, inner, " No output styles matched this filter");
    }

    const footer_row = if (visible == 0) top_row + 3 else empty_row;
    const footer_text = if (filtered.len > visible)
        " Enter select  •  Esc cancel  •  Type to filter"
    else
        " Enter select  •  Esc cancel";
    appendSimpleOverlayLine(&seq, &pos, footer_row, inner, footer_text);
    appendSimpleOverlayBottomBorder(&seq, &pos, footer_row + 1, inner);

    appendLiteral(&seq, &pos, "\x1b8");
    _ = std.c.write(std.Io.File.stdout().handle, (seq[0..pos]).ptr, (seq[0..pos]).len);
}

fn clearStylePickerOverlay(item_count: usize, bottom_margin_rows: usize) void {
    const rows = terminalRows();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;
    const overlay_rows = stylePickerOverlayRows(item_count);
    const bottom_row = if (status_row > 1) status_row - 1 else 1;
    const top_row = if (bottom_row >= overlay_rows) bottom_row - overlay_rows + 1 else 1;

    var seq: [2048]u8 = undefined;
    var pos: usize = 0;
    appendLiteral(&seq, &pos, "\x1b7");
    var row: usize = 0;
    while (row < overlay_rows) : (row += 1) {
        appendCursorTo(&seq, &pos, top_row + row);
        appendLiteral(&seq, &pos, "\x1b[2K");
    }
    appendLiteral(&seq, &pos, "\x1b8");
    _ = std.c.write(std.Io.File.stdout().handle, (seq[0..pos]).ptr, (seq[0..pos]).len);
}

// ── Command palette --------------------------------------------------------

fn commandPaletteOverlayRows(item_count: usize) usize {
    const visible = @min(if (item_count == 0) @as(usize, 1) else item_count, @as(usize, 8));
    return 7 + (visible * 2);
}

pub fn runCommandPaletteOverlayLoop(
    data: CommandPaletteData,
    bottom_margin_rows: usize,
    bindings: ?*const keybindings.RuntimeKeybindings,
) !?usize {
    if (data.items.len == 0) return null;

    const fd = std.Io.File.stdin().handle;
    var filter_buf: [72]u8 = undefined;
    var filter_len: usize = 0;
    var selected = @min(data.initial_selection, data.items.len - 1);
    const contexts = [_]keybindings.BindingContext{.Select};

    while (true) {
        var filtered_indices: [96]usize = undefined;
        var filtered_count: usize = 0;
        for (data.items, 0..) |item, idx| {
            if (filter_len == 0 or
                containsFilter(item.title, filter_buf[0..filter_len]) or
                containsFilter(item.detail, filter_buf[0..filter_len]) or
                containsFilter(item.shortcut, filter_buf[0..filter_len]) or
                containsFilter(item.category, filter_buf[0..filter_len]) or
                containsFilter(item.state, filter_buf[0..filter_len]))
            {
                if (filtered_count < filtered_indices.len) {
                    filtered_indices[filtered_count] = idx;
                    filtered_count += 1;
                }
            }
        }

        if (filtered_count > 0 and selected >= filtered_count) selected = filtered_count - 1;
        renderCommandPaletteOverlay(data, filtered_indices[0..filtered_count], selected, filter_buf[0..filter_len], bottom_margin_rows);

        var chord_buf: [24]u8 = undefined;
        const key = readPickerKey(fd, &chord_buf) catch {
            clearCommandPaletteOverlay(data.items.len, bottom_margin_rows);
            return null;
        };
        const ev = resolvePickerBinding(bindings, &contexts, key.chord, key.event);

        switch (ev) {
            .up => selected = if (filtered_count == 0) 0 else if (selected == 0) filtered_count - 1 else selected - 1,
            .down, .next => selected = if (filtered_count == 0) 0 else (selected + 1) % filtered_count,
            .select => {
                clearCommandPaletteOverlay(data.items.len, bottom_margin_rows);
                if (filtered_count == 0) return null;
                return filtered_indices[selected];
            },
            .cancel => {
                clearCommandPaletteOverlay(data.items.len, bottom_margin_rows);
                return null;
            },
            .backspace => {
                if (filter_len > 0) {
                    filter_len -= 1;
                    selected = 0;
                }
            },
            .char => {
                if (key.char >= 0x20 and key.char < 0x7f and filter_len < filter_buf.len) {
                    filter_buf[filter_len] = key.char;
                    filter_len += 1;
                    selected = 0;
                }
            },
            .tab, .shift_tab, .toggle, .none => {},
        }
    }
}

fn renderCommandPaletteOverlay(
    data: CommandPaletteData,
    filtered: []const usize,
    selected: usize,
    filter: []const u8,
    bottom_margin_rows: usize,
) void {
    const rows = terminalRows();
    const cols = terminalCols();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;

    const visible = @min(filtered.len, @as(usize, 8));
    const overlay_rows = commandPaletteOverlayRows(data.items.len);
    const bottom_row = if (status_row > 1) status_row - 1 else 1;
    const top_row = if (bottom_row >= overlay_rows) bottom_row - overlay_rows + 1 else 1;

    var box_w: usize = if (cols < 72) cols else if (cols < 108) cols else 108;
    if (box_w < 8) box_w = 8;
    const inner = box_w - 2;

    var start: usize = 0;
    if (filtered.len > visible) {
        const half = visible / 2;
        if (selected > half) start = selected - half;
        if (start + visible > filtered.len) start = filtered.len - visible;
    }

    var seq: [24576]u8 = undefined;
    var pos: usize = 0;
    appendLiteral(&seq, &pos, "\x1b7");

    var clear_row: usize = 0;
    while (clear_row < overlay_rows) : (clear_row += 1) {
        appendCursorTo(&seq, &pos, top_row + clear_row);
        appendLiteral(&seq, &pos, "\x1b[2K");
    }

    appendSimpleOverlayBorder(&seq, &pos, top_row, inner);

    var title_buf: [192]u8 = undefined;
    const title = if (filter.len == 0)
        std.fmt.bufPrint(&title_buf, " {s}", .{data.title}) catch data.title
    else
        std.fmt.bufPrint(&title_buf, " {s}  •  filter: {s}", .{ data.title, filter }) catch data.title;
    appendSimpleOverlayLine(&seq, &pos, top_row + 1, inner, title);
    appendSimpleOverlayLine(&seq, &pos, top_row + 2, inner, " Type to filter  •  Enter open  •  Esc cancel");
    appendSimpleOverlayDivider(&seq, &pos, top_row + 3, inner);

    if (visible == 0) {
        appendSimpleOverlayLine(&seq, &pos, top_row + 4, inner, " No commands matched this filter");
    } else {
        var row: usize = 0;
        while (row < visible) : (row += 1) {
            const item = data.items[filtered[start + row]];
            const row_selected = start + row == selected;

            var line_buf: [512]u8 = undefined;
            const category = if (item.category.len > 0)
                std.fmt.bufPrint(&line_buf, " {s} [{s}] {s}", .{
                    if (row_selected) ">" else " ",
                    item.category,
                    item.title,
                }) catch item.title
            else
                std.fmt.bufPrint(&line_buf, " {s} {s}", .{
                    if (row_selected) ">" else " ",
                    item.title,
                }) catch item.title;
            appendSimpleOverlayLine(&seq, &pos, top_row + 4 + (row * 2), inner, category);

            var detail_buf: [512]u8 = undefined;
            const detail = if (item.shortcut.len > 0 and item.state.len > 0)
                std.fmt.bufPrint(&detail_buf, "   {s}  •  {s}  •  {s}", .{ item.detail, item.shortcut, item.state }) catch item.detail
            else if (item.shortcut.len > 0)
                std.fmt.bufPrint(&detail_buf, "   {s}  •  {s}", .{ item.detail, item.shortcut }) catch item.detail
            else if (item.state.len > 0)
                std.fmt.bufPrint(&detail_buf, "   {s}  •  {s}", .{ item.detail, item.state }) catch item.detail
            else
                std.fmt.bufPrint(&detail_buf, "   {s}", .{item.detail}) catch item.detail;
            appendSimpleOverlayLine(&seq, &pos, top_row + 5 + (row * 2), inner, detail);
        }
    }

    const footer_row = top_row + overlay_rows - 3;
    appendSimpleOverlayDivider(&seq, &pos, footer_row, inner);
    appendSimpleOverlayLine(&seq, &pos, footer_row + 1, inner, " Leader opens primary actions  •  Search / session / display controls live here");
    appendSimpleOverlayBottomBorder(&seq, &pos, footer_row + 2, inner);

    appendLiteral(&seq, &pos, "\x1b8");
    _ = std.c.write(std.Io.File.stdout().handle, (seq[0..pos]).ptr, (seq[0..pos]).len);
}

fn clearCommandPaletteOverlay(item_count: usize, bottom_margin_rows: usize) void {
    const rows = terminalRows();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;
    const overlay_rows = commandPaletteOverlayRows(item_count);
    const bottom_row = if (status_row > 1) status_row - 1 else 1;
    const top_row = if (bottom_row >= overlay_rows) bottom_row - overlay_rows + 1 else 1;

    var seq: [4096]u8 = undefined;
    var pos: usize = 0;
    appendLiteral(&seq, &pos, "\x1b7");
    var row: usize = 0;
    while (row < overlay_rows) : (row += 1) {
        appendCursorTo(&seq, &pos, top_row + row);
        appendLiteral(&seq, &pos, "\x1b[2K");
    }
    appendLiteral(&seq, &pos, "\x1b8");
    _ = std.c.write(std.Io.File.stdout().handle, (seq[0..pos]).ptr, (seq[0..pos]).len);
}

fn runtimePanelOverlayRows(item_count: usize) usize {
    const visible = @min(if (item_count == 0) @as(usize, 1) else item_count, @as(usize, 6));
    return 7 + (visible * 2);
}

pub fn runRuntimePanelOverlayLoop(
    data: RuntimePanelData,
    bottom_margin_rows: usize,
    bindings: ?*const keybindings.RuntimeKeybindings,
) !?usize {
    if (data.items.len == 0) return null;

    const fd = std.Io.File.stdin().handle;
    var filter_buf: [72]u8 = undefined;
    var filter_len: usize = 0;
    var selected = @min(data.initial_selection, data.items.len - 1);
    const contexts = [_]keybindings.BindingContext{.Select};

    while (true) {
        var filtered_indices: [64]usize = undefined;
        var filtered_count: usize = 0;
        for (data.items, 0..) |item, idx| {
            if (filter_len == 0 or
                containsFilter(item.title, filter_buf[0..filter_len]) or
                containsFilter(item.detail, filter_buf[0..filter_len]) or
                containsFilter(item.shortcut, filter_buf[0..filter_len]) or
                containsFilter(item.category, filter_buf[0..filter_len]) or
                containsFilter(item.state, filter_buf[0..filter_len]))
            {
                if (filtered_count < filtered_indices.len) {
                    filtered_indices[filtered_count] = idx;
                    filtered_count += 1;
                }
            }
        }

        if (filtered_count > 0 and selected >= filtered_count) selected = filtered_count - 1;
        renderRuntimePanelOverlay(data, filtered_indices[0..filtered_count], selected, filter_buf[0..filter_len], bottom_margin_rows);

        var chord_buf: [24]u8 = undefined;
        const key = readPickerKey(fd, &chord_buf) catch {
            clearRuntimePanelOverlay(data.items.len, bottom_margin_rows);
            return null;
        };
        const ev = resolvePickerBinding(bindings, &contexts, key.chord, key.event);

        switch (ev) {
            .up => selected = if (filtered_count == 0) 0 else if (selected == 0) filtered_count - 1 else selected - 1,
            .down, .next => selected = if (filtered_count == 0) 0 else (selected + 1) % filtered_count,
            .select => {
                clearRuntimePanelOverlay(data.items.len, bottom_margin_rows);
                if (filtered_count == 0) return null;
                return filtered_indices[selected];
            },
            .cancel => {
                clearRuntimePanelOverlay(data.items.len, bottom_margin_rows);
                return null;
            },
            .backspace => {
                if (filter_len > 0) {
                    filter_len -= 1;
                    selected = 0;
                }
            },
            .char => {
                if (key.char >= 0x20 and key.char < 0x7f and filter_len < filter_buf.len) {
                    filter_buf[filter_len] = key.char;
                    filter_len += 1;
                    selected = 0;
                }
            },
            .tab, .shift_tab, .toggle, .none => {},
        }
    }
}

fn renderRuntimePanelOverlay(
    data: RuntimePanelData,
    filtered: []const usize,
    selected: usize,
    filter: []const u8,
    bottom_margin_rows: usize,
) void {
    const rows = terminalRows();
    const cols = terminalCols();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;

    const visible = @min(filtered.len, @as(usize, 6));
    const overlay_rows = runtimePanelOverlayRows(data.items.len);
    const bottom_row = if (status_row > 1) status_row - 1 else 1;
    const top_row = if (bottom_row >= overlay_rows) bottom_row - overlay_rows + 1 else 1;

    var box_w: usize = if (cols < 76) cols else if (cols < 112) cols else 112;
    if (box_w < 8) box_w = 8;
    const inner = box_w - 2;

    var start: usize = 0;
    if (filtered.len > visible) {
        const half = visible / 2;
        if (selected > half) start = selected - half;
        if (start + visible > filtered.len) start = filtered.len - visible;
    }

    var seq: [24576]u8 = undefined;
    var pos: usize = 0;
    appendLiteral(&seq, &pos, "\x1b7");

    var clear_row: usize = 0;
    while (clear_row < overlay_rows) : (clear_row += 1) {
        appendCursorTo(&seq, &pos, top_row + clear_row);
        appendLiteral(&seq, &pos, "\x1b[2K");
    }

    appendSimpleOverlayBorder(&seq, &pos, top_row, inner);

    var title_buf: [192]u8 = undefined;
    const title = if (filter.len == 0)
        std.fmt.bufPrint(&title_buf, " {s}", .{data.title}) catch data.title
    else
        std.fmt.bufPrint(&title_buf, " {s}  •  filter: {s}", .{ data.title, filter }) catch data.title;
    appendSimpleOverlayLine(&seq, &pos, top_row + 1, inner, title);
    appendSimpleOverlayLine(&seq, &pos, top_row + 2, inner, " Enter open  •  Esc cancel  •  Tasks, model, approvals, and automation controls");
    appendSimpleOverlayDivider(&seq, &pos, top_row + 3, inner);

    if (visible == 0) {
        appendSimpleOverlayLine(&seq, &pos, top_row + 4, inner, " No runtime controls matched this filter");
    } else {
        var row: usize = 0;
        while (row < visible) : (row += 1) {
            const item = data.items[filtered[start + row]];
            const row_selected = start + row == selected;

            var title_line_buf: [512]u8 = undefined;
            const title_line = if (item.state.len > 0)
                std.fmt.bufPrint(
                    &title_line_buf,
                    " {s} [{s}] {s}  •  {s}",
                    .{ if (row_selected) ">" else " ", item.category, item.title, item.state },
                ) catch item.title
            else
                std.fmt.bufPrint(
                    &title_line_buf,
                    " {s} [{s}] {s}",
                    .{ if (row_selected) ">" else " ", item.category, item.title },
                ) catch item.title;
            appendSimpleOverlayLine(&seq, &pos, top_row + 4 + (row * 2), inner, title_line);

            var detail_line_buf: [512]u8 = undefined;
            const detail_line = if (item.shortcut.len > 0)
                std.fmt.bufPrint(&detail_line_buf, "   {s}  •  {s}", .{ item.detail, item.shortcut }) catch item.detail
            else
                std.fmt.bufPrint(&detail_line_buf, "   {s}", .{item.detail}) catch item.detail;
            appendSimpleOverlayLine(&seq, &pos, top_row + 5 + (row * 2), inner, detail_line);
        }
    }

    const footer_row = top_row + overlay_rows - 3;
    appendSimpleOverlayDivider(&seq, &pos, footer_row, inner);
    appendSimpleOverlayLine(&seq, &pos, footer_row + 1, inner, " Runtime panel  •  Enter open  •  Esc close  •  Type to filter");
    appendSimpleOverlayBottomBorder(&seq, &pos, footer_row + 2, inner);

    appendLiteral(&seq, &pos, "\x1b8");
    _ = std.c.write(std.Io.File.stdout().handle, (seq[0..pos]).ptr, (seq[0..pos]).len);
}

fn clearRuntimePanelOverlay(item_count: usize, bottom_margin_rows: usize) void {
    const rows = terminalRows();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;
    const overlay_rows = runtimePanelOverlayRows(item_count);
    const bottom_row = if (status_row > 1) status_row - 1 else 1;
    const top_row = if (bottom_row >= overlay_rows) bottom_row - overlay_rows + 1 else 1;

    var seq: [4096]u8 = undefined;
    var pos: usize = 0;
    appendLiteral(&seq, &pos, "\x1b7");
    var row: usize = 0;
    while (row < overlay_rows) : (row += 1) {
        appendCursorTo(&seq, &pos, top_row + row);
        appendLiteral(&seq, &pos, "\x1b[2K");
    }
    appendLiteral(&seq, &pos, "\x1b8");
    _ = std.c.write(std.Io.File.stdout().handle, (seq[0..pos]).ptr, (seq[0..pos]).len);
}

fn sessionSwitcherOverlayRows(item_count: usize) usize {
    const visible = @min(if (item_count == 0) @as(usize, 1) else item_count, @as(usize, 8));
    return 7 + (visible * 2);
}

pub fn runSessionSwitcherOverlayLoop(
    data: SessionSwitcherData,
    bottom_margin_rows: usize,
    bindings: ?*const keybindings.RuntimeKeybindings,
) !?usize {
    if (data.items.len == 0) return null;

    const fd = std.Io.File.stdin().handle;
    var filter_buf: [72]u8 = undefined;
    var filter_len: usize = 0;
    var selected = @min(data.initial_selection, data.items.len - 1);
    const contexts = [_]keybindings.BindingContext{.Select};

    while (true) {
        var filtered_indices: [96]usize = undefined;
        var filtered_count: usize = 0;
        const filter = filter_buf[0..filter_len];
        if (filter_len == 0) {
            // Empty filter: keep original order (newest-first as supplied).
            for (data.items, 0..) |_, idx| {
                if (filtered_count < filtered_indices.len) {
                    filtered_indices[filtered_count] = idx;
                    filtered_count += 1;
                }
            }
        } else {
            // Fuzzy-rank: best fuzzyScore across id/label/summary, with a
            // substring match as a low-score fallback so anything the old
            // containsFilter would have surfaced still appears. Then stable
            // insertion-sort by score descending (small N, fixed buffer).
            var scores: [96]i32 = undefined;
            for (data.items, 0..) |item, idx| {
                if (filtered_count >= filtered_indices.len) break;
                const score = bestSessionFuzzyScore(item, filter);
                if (score) |s| {
                    filtered_indices[filtered_count] = idx;
                    scores[filtered_count] = s;
                    filtered_count += 1;
                }
            }
            // Stable insertion sort: higher score first; ties keep input order.
            var i: usize = 1;
            while (i < filtered_count) : (i += 1) {
                const idx_v = filtered_indices[i];
                const score_v = scores[i];
                var j: usize = i;
                while (j > 0 and scores[j - 1] < score_v) : (j -= 1) {
                    filtered_indices[j] = filtered_indices[j - 1];
                    scores[j] = scores[j - 1];
                }
                filtered_indices[j] = idx_v;
                scores[j] = score_v;
            }
        }

        if (filtered_count > 0 and selected >= filtered_count) selected = filtered_count - 1;
        renderSessionSwitcherOverlay(data, filtered_indices[0..filtered_count], selected, filter_buf[0..filter_len], bottom_margin_rows);

        var chord_buf: [24]u8 = undefined;
        const key = readPickerKey(fd, &chord_buf) catch {
            clearSessionSwitcherOverlay(data.items.len, bottom_margin_rows);
            return null;
        };
        const ev = resolvePickerBinding(bindings, &contexts, key.chord, key.event);

        switch (ev) {
            .up => selected = if (filtered_count == 0) 0 else if (selected == 0) filtered_count - 1 else selected - 1,
            .down, .next => selected = if (filtered_count == 0) 0 else (selected + 1) % filtered_count,
            .select => {
                clearSessionSwitcherOverlay(data.items.len, bottom_margin_rows);
                if (filtered_count == 0) return null;
                return filtered_indices[selected];
            },
            .cancel => {
                clearSessionSwitcherOverlay(data.items.len, bottom_margin_rows);
                return null;
            },
            .backspace => {
                if (filter_len > 0) {
                    filter_len -= 1;
                    selected = 0;
                }
            },
            .char => {
                if (key.char >= 0x20 and key.char < 0x7f and filter_len < filter_buf.len) {
                    filter_buf[filter_len] = key.char;
                    filter_len += 1;
                    selected = 0;
                }
            },
            .tab, .shift_tab, .toggle, .none => {},
        }
    }
}

fn renderSessionSwitcherOverlay(
    data: SessionSwitcherData,
    filtered: []const usize,
    selected: usize,
    filter: []const u8,
    bottom_margin_rows: usize,
) void {
    const rows = terminalRows();
    const cols = terminalCols();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;

    const visible = @min(filtered.len, @as(usize, 8));
    const overlay_rows = sessionSwitcherOverlayRows(data.items.len);
    const bottom_row = if (status_row > 1) status_row - 1 else 1;
    const top_row = if (bottom_row >= overlay_rows) bottom_row - overlay_rows + 1 else 1;

    var box_w: usize = if (cols < 72) cols else if (cols < 110) cols else 110;
    if (box_w < 8) box_w = 8;
    const inner = box_w - 2;

    var start: usize = 0;
    if (filtered.len > visible) {
        const half = visible / 2;
        if (selected > half) start = selected - half;
        if (start + visible > filtered.len) start = filtered.len - visible;
    }

    var seq: [24576]u8 = undefined;
    var pos: usize = 0;
    appendLiteral(&seq, &pos, "\x1b7");

    var clear_row: usize = 0;
    while (clear_row < overlay_rows) : (clear_row += 1) {
        appendCursorTo(&seq, &pos, top_row + clear_row);
        appendLiteral(&seq, &pos, "\x1b[2K");
    }

    appendSimpleOverlayBorder(&seq, &pos, top_row, inner);

    var title_buf: [192]u8 = undefined;
    const title = if (filter.len == 0)
        std.fmt.bufPrint(&title_buf, " {s}", .{data.title}) catch data.title
    else
        std.fmt.bufPrint(&title_buf, " {s}  •  filter: {s}", .{ data.title, filter }) catch data.title;
    appendSimpleOverlayLine(&seq, &pos, top_row + 1, inner, title);
    appendSimpleOverlayLine(&seq, &pos, top_row + 2, inner, " Enter resume  •  Esc cancel  •  Type to filter by label or id");
    appendSimpleOverlayDivider(&seq, &pos, top_row + 3, inner);

    if (visible == 0) {
        appendSimpleOverlayLine(&seq, &pos, top_row + 4, inner, " No saved sessions matched this filter");
    } else {
        var row: usize = 0;
        while (row < visible) : (row += 1) {
            const item = data.items[filtered[start + row]];
            const row_selected = start + row == selected;
            const title_text = if (item.label.len > 0) item.label else item.id;

            var line_one_buf: [512]u8 = undefined;
            const line_one = if (item.is_current)
                std.fmt.bufPrint(&line_one_buf, " {s} {s}  •  current", .{ if (row_selected) ">" else " ", title_text }) catch title_text
            else
                std.fmt.bufPrint(&line_one_buf, " {s} {s}", .{ if (row_selected) ">" else " ", title_text }) catch title_text;
            appendSimpleOverlayLine(&seq, &pos, top_row + 4 + (row * 2), inner, line_one);

            var line_two_buf: [512]u8 = undefined;
            const line_two = std.fmt.bufPrint(
                &line_two_buf,
                "   {s}  •  {s}",
                .{ item.id, item.updated_summary },
            ) catch item.id;
            appendSimpleOverlayLine(&seq, &pos, top_row + 5 + (row * 2), inner, line_two);
        }
    }

    const footer_row = top_row + overlay_rows - 3;
    appendSimpleOverlayDivider(&seq, &pos, footer_row, inner);
    appendSimpleOverlayLine(&seq, &pos, footer_row + 1, inner, " Session switcher  •  Enter resume  •  Esc close");
    appendSimpleOverlayBottomBorder(&seq, &pos, footer_row + 2, inner);

    appendLiteral(&seq, &pos, "\x1b8");
    _ = std.c.write(std.Io.File.stdout().handle, (seq[0..pos]).ptr, (seq[0..pos]).len);
}

fn clearSessionSwitcherOverlay(item_count: usize, bottom_margin_rows: usize) void {
    const rows = terminalRows();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;
    const overlay_rows = sessionSwitcherOverlayRows(item_count);
    const bottom_row = if (status_row > 1) status_row - 1 else 1;
    const top_row = if (bottom_row >= overlay_rows) bottom_row - overlay_rows + 1 else 1;

    var seq: [4096]u8 = undefined;
    var pos: usize = 0;
    appendLiteral(&seq, &pos, "\x1b7");
    var row: usize = 0;
    while (row < overlay_rows) : (row += 1) {
        appendCursorTo(&seq, &pos, top_row + row);
        appendLiteral(&seq, &pos, "\x1b[2K");
    }
    appendLiteral(&seq, &pos, "\x1b8");
    _ = std.c.write(std.Io.File.stdout().handle, (seq[0..pos]).ptr, (seq[0..pos]).len);
}

const ThemePickerEntry = struct {
    setting: ui_theme.ThemeSetting,
    label: []const u8,
    desc: []const u8,
};

const theme_picker_entries = [_]ThemePickerEntry{
    .{ .setting = .auto, .label = "Auto", .desc = "Follow terminal" },
    .{ .setting = .dark, .label = "Dark", .desc = "Default" },
    .{ .setting = .light, .label = "Light", .desc = "Bright" },
    .{ .setting = .dark_daltonized, .label = "Dark Daltonized", .desc = "Colorblind-friendly" },
    .{ .setting = .light_daltonized, .label = "Light Daltonized", .desc = "Colorblind-friendly" },
    .{ .setting = .dark_ansi, .label = "Dark ANSI", .desc = "16-color" },
    .{ .setting = .light_ansi, .label = "Light ANSI", .desc = "16-color" },
};

fn initialThemePickerSelection(data: ThemePickerData) usize {
    for (theme_picker_entries, 0..) |entry, idx| {
        if (entry.setting == data.current_setting) return idx;
    }
    return 1;
}

fn themePickerOverlayRows() usize {
    return 20;
}

pub fn runThemePickerOverlayLoop(
    data: ThemePickerData,
    bottom_margin_rows: usize,
    bindings: ?*const keybindings.RuntimeKeybindings,
) !?ThemePickerResult {
    const fd = std.Io.File.stdin().handle;
    var selected = initialThemePickerSelection(data);
    var syntax_highlighting = data.syntax_highlighting;
    const contexts = [_]keybindings.BindingContext{ .ThemePicker, .Select };

    while (true) {
        renderThemePickerOverlay(data, selected, syntax_highlighting, bottom_margin_rows);

        var chord_buf: [24]u8 = undefined;
        const key = readPickerKey(fd, &chord_buf) catch {
            clearThemePickerOverlay(bottom_margin_rows);
            return null;
        };
        const ev = resolvePickerBinding(bindings, &contexts, key.chord, key.event);

        switch (ev) {
            .up => selected = if (selected == 0) theme_picker_entries.len - 1 else selected - 1,
            .down, .next => selected = (selected + 1) % theme_picker_entries.len,
            .toggle => syntax_highlighting = !syntax_highlighting,
            .select => {
                clearThemePickerOverlay(bottom_margin_rows);
                return .{
                    .setting = theme_picker_entries[selected].setting,
                    .syntax_highlighting = syntax_highlighting,
                };
            },
            .cancel => {
                clearThemePickerOverlay(bottom_margin_rows);
                return null;
            },
            .tab, .shift_tab, .backspace, .char, .none => {},
        }
    }
}

fn renderThemePickerOverlay(data: ThemePickerData, selected: usize, syntax_highlighting: bool, bottom_margin_rows: usize) void {
    const rows = terminalRows();
    const cols = terminalCols();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;
    const overlay_rows = themePickerOverlayRows();
    const bottom_row = if (status_row > 1) status_row - 1 else 1;
    const top_row = if (bottom_row >= overlay_rows) bottom_row - overlay_rows + 1 else 1;

    var box_w: usize = if (cols < 60) cols else if (cols < 96) cols else 96;
    if (box_w < 8) box_w = 8;
    const inner = box_w - 2;

    const preview_theme = ui_theme.resolveSetting(theme_picker_entries[selected].setting);
    const current_resolved = ui_theme.resolveSetting(data.current_setting);

    const border = ui_theme.ansi(preview_theme, .overlay_border);
    const header = ui_theme.ansi(preview_theme, .overlay_header);
    const label = ui_theme.ansi(preview_theme, .overlay_label);
    const value = ui_theme.ansi(preview_theme, .overlay_value);
    const active = ui_theme.ansi(preview_theme, .overlay_active);
    const sel_bg = ui_theme.ansi(preview_theme, .overlay_selection_bg);
    const sel_fg = ui_theme.ansi(preview_theme, .overlay_selection_fg);
    const hint = ui_theme.ansi(preview_theme, .overlay_hint);
    const search = ui_theme.ansi(preview_theme, .overlay_search);
    const reset = ui_theme.ansi(preview_theme, .reset);

    var seq: [32768]u8 = undefined;
    var pos: usize = 0;

    appendLiteral(&seq, &pos, "\x1b7");

    appendCursorTo(&seq, &pos, top_row);
    appendLiteral(&seq, &pos, "\x1b[2K");
    appendLiteral(&seq, &pos, border);
    appendLiteral(&seq, &pos, "\xe2\x94\x8c");
    appendRepeatStr(&seq, &pos, "\xe2\x94\x80", inner);
    appendLiteral(&seq, &pos, "\xe2\x94\x90");
    appendLiteral(&seq, &pos, reset);

    appendCursorTo(&seq, &pos, top_row + 1);
    appendLiteral(&seq, &pos, "\x1b[2K");
    appendLiteral(&seq, &pos, border);
    appendLiteral(&seq, &pos, "\xe2\x94\x82 ");
    appendLiteral(&seq, &pos, header);
    appendLiteral(&seq, &pos, "THEME PICKER");
    appendLiteral(&seq, &pos, reset);
    padToWidth(&seq, &pos, 12, inner);
    appendLiteral(&seq, &pos, border);
    appendLiteral(&seq, &pos, "\xe2\x94\x82");
    appendLiteral(&seq, &pos, reset);

    appendCursorTo(&seq, &pos, top_row + 2);
    appendLiteral(&seq, &pos, "\x1b[2K");
    appendLiteral(&seq, &pos, border);
    appendLiteral(&seq, &pos, "\xe2\x94\x82 ");
    appendLiteral(&seq, &pos, label);
    appendLiteral(&seq, &pos, "current: ");
    appendLiteral(&seq, &pos, value);
    appendLiteral(&seq, &pos, ui_theme.formatThemeSetting(data.current_setting));
    if (data.current_setting == .auto) {
        appendLiteral(&seq, &pos, hint);
        appendLiteral(&seq, &pos, " -> ");
        appendLiteral(&seq, &pos, value);
        appendLiteral(&seq, &pos, ui_theme.formatThemeName(current_resolved));
    }
    appendLiteral(&seq, &pos, reset);
    appendLiteral(&seq, &pos, hint);
    appendLiteral(&seq, &pos, "  |  ");
    appendLiteral(&seq, &pos, label);
    appendLiteral(&seq, &pos, "syntax: ");
    appendLiteral(&seq, &pos, if (syntax_highlighting) active else hint);
    appendLiteral(&seq, &pos, if (syntax_highlighting) "on" else "off");
    appendLiteral(&seq, &pos, reset);
    padToWidth(&seq, &pos, 48, inner);
    appendLiteral(&seq, &pos, border);
    appendLiteral(&seq, &pos, "\xe2\x94\x82");
    appendLiteral(&seq, &pos, reset);

    appendCursorTo(&seq, &pos, top_row + 3);
    appendLiteral(&seq, &pos, "\x1b[2K");
    appendLiteral(&seq, &pos, border);
    appendLiteral(&seq, &pos, "\xe2\x94\x9c");
    appendRepeatStr(&seq, &pos, "\xe2\x94\x80", inner);
    appendLiteral(&seq, &pos, "\xe2\x94\xa4");
    appendLiteral(&seq, &pos, reset);

    for (theme_picker_entries, 0..) |entry, row_idx| {
        appendCursorTo(&seq, &pos, top_row + 4 + row_idx);
        appendLiteral(&seq, &pos, "\x1b[2K");
        appendLiteral(&seq, &pos, border);
        appendLiteral(&seq, &pos, "\xe2\x94\x82 ");

        const is_selected = row_idx == selected;
        if (is_selected) {
            appendLiteral(&seq, &pos, sel_bg);
            appendLiteral(&seq, &pos, sel_fg);
            appendLiteral(&seq, &pos, " \xe2\x96\xb6 ");
        } else {
            appendLiteral(&seq, &pos, reset);
            appendLiteral(&seq, &pos, "   ");
        }

        appendLiteral(&seq, &pos, if (is_selected) sel_fg else value);
        appendLiteral(&seq, &pos, entry.label);
        appendLiteral(&seq, &pos, reset);
        appendLiteral(&seq, &pos, hint);
        appendLiteral(&seq, &pos, "  ");
        appendLiteral(&seq, &pos, entry.desc);
        if (entry.setting == data.current_setting) {
            appendLiteral(&seq, &pos, active);
            appendLiteral(&seq, &pos, "  \xe2\x9c\x93 current");
        }
        appendLiteral(&seq, &pos, reset);
        padToWidth(&seq, &pos, 44, inner);
        appendLiteral(&seq, &pos, border);
        appendLiteral(&seq, &pos, "\xe2\x94\x82");
        appendLiteral(&seq, &pos, reset);
    }

    appendCursorTo(&seq, &pos, top_row + 11);
    appendLiteral(&seq, &pos, "\x1b[2K");
    appendLiteral(&seq, &pos, border);
    appendLiteral(&seq, &pos, "\xe2\x94\x9c");
    appendRepeatStr(&seq, &pos, "\xe2\x94\x80", inner);
    appendLiteral(&seq, &pos, "\xe2\x94\xa4");
    appendLiteral(&seq, &pos, reset);

    var preview_row: usize = 0;
    while (preview_row < 5) : (preview_row += 1) {
        appendCursorTo(&seq, &pos, top_row + 12 + preview_row);
        appendLiteral(&seq, &pos, "\x1b[2K");
        appendLiteral(&seq, &pos, border);
        appendLiteral(&seq, &pos, "\xe2\x94\x82 ");
        appendThemePreviewLine(&seq, &pos, preview_theme, syntax_highlighting, preview_row, theme_picker_entries[selected].setting);
        appendLiteral(&seq, &pos, reset);
        padToWidth(&seq, &pos, 42, inner);
        appendLiteral(&seq, &pos, border);
        appendLiteral(&seq, &pos, "\xe2\x94\x82");
        appendLiteral(&seq, &pos, reset);
    }

    appendCursorTo(&seq, &pos, top_row + 17);
    appendLiteral(&seq, &pos, "\x1b[2K");
    appendLiteral(&seq, &pos, border);
    appendLiteral(&seq, &pos, "\xe2\x94\x9c");
    appendRepeatStr(&seq, &pos, "\xe2\x94\x80", inner);
    appendLiteral(&seq, &pos, "\xe2\x94\xa4");
    appendLiteral(&seq, &pos, reset);

    appendCursorTo(&seq, &pos, top_row + 18);
    appendLiteral(&seq, &pos, "\x1b[2K");
    appendLiteral(&seq, &pos, border);
    appendLiteral(&seq, &pos, "\xe2\x94\x82 ");
    appendLiteral(&seq, &pos, hint);
    appendLiteral(&seq, &pos, "Enter select  ");
    appendLiteral(&seq, &pos, label);
    appendLiteral(&seq, &pos, "Esc");
    appendLiteral(&seq, &pos, hint);
    appendLiteral(&seq, &pos, " cancel  ");
    appendLiteral(&seq, &pos, search);
    appendLiteral(&seq, &pos, "Ctrl+T");
    appendLiteral(&seq, &pos, hint);
    appendLiteral(&seq, &pos, " syntax preview");
    appendLiteral(&seq, &pos, reset);
    padToWidth(&seq, &pos, 43, inner);
    appendLiteral(&seq, &pos, border);
    appendLiteral(&seq, &pos, "\xe2\x94\x82");
    appendLiteral(&seq, &pos, reset);

    appendCursorTo(&seq, &pos, top_row + 19);
    appendLiteral(&seq, &pos, "\x1b[2K");
    appendLiteral(&seq, &pos, border);
    appendLiteral(&seq, &pos, "\xe2\x94\x94");
    appendRepeatStr(&seq, &pos, "\xe2\x94\x80", inner);
    appendLiteral(&seq, &pos, "\xe2\x94\x98");
    appendLiteral(&seq, &pos, reset);

    appendLiteral(&seq, &pos, "\x1b8");
    _ = std.c.write(std.Io.File.stdout().handle, (seq[0..pos]).ptr, (seq[0..pos]).len);
}

fn appendThemePreviewLine(
    seq: []u8,
    pos: *usize,
    theme: ui_theme.ThemeName,
    syntax_highlighting: bool,
    row_idx: usize,
    selected_setting: ui_theme.ThemeSetting,
) void {
    const reset = ui_theme.ansi(theme, .reset);
    switch (row_idx) {
        0 => {
            appendLiteral(seq, pos, ui_theme.ansi(theme, .overlay_label));
            appendLiteral(seq, pos, "preview: ");
            appendLiteral(seq, pos, ui_theme.ansi(theme, .overlay_value));
            appendLiteral(seq, pos, ui_theme.formatThemeSetting(selected_setting));
            if (selected_setting == .auto) {
                appendLiteral(seq, pos, ui_theme.ansi(theme, .overlay_hint));
                appendLiteral(seq, pos, " -> ");
                appendLiteral(seq, pos, ui_theme.ansi(theme, .overlay_value));
                appendLiteral(seq, pos, ui_theme.formatThemeName(theme));
            }
        },
        1 => {
            appendLiteral(seq, pos, ui_theme.ansi(theme, .prompt));
            appendLiteral(seq, pos, ">");
            appendLiteral(seq, pos, reset);
            appendLiteral(seq, pos, " /theme ");
            appendLiteral(seq, pos, ui_theme.formatThemeSetting(selected_setting));
        },
        2 => {
            appendLiteral(seq, pos, ui_theme.ansi(theme, .heading1));
            appendLiteral(seq, pos, "Heading");
            appendLiteral(seq, pos, reset);
            appendLiteral(seq, pos, "  ");
            appendLiteral(seq, pos, ui_theme.ansi(theme, .heading2));
            appendLiteral(seq, pos, "Section");
        },
        3 => {
            appendLiteral(seq, pos, ui_theme.ansi(theme, .link));
            appendLiteral(seq, pos, "https://example.com");
            appendLiteral(seq, pos, reset);
            appendLiteral(seq, pos, "  ");
            appendLiteral(seq, pos, ui_theme.ansi(theme, .path));
            appendLiteral(seq, pos, "src/main.zig");
        },
        4 => {
            appendLiteral(seq, pos, ui_theme.ansi(theme, .status_bg));
            appendLiteral(seq, pos, " theme ");
            appendLiteral(seq, pos, ui_theme.formatThemeName(theme));
            appendLiteral(seq, pos, " ");
            appendLiteral(seq, pos, reset);
            appendLiteral(seq, pos, "  ");
            if (syntax_highlighting) {
                appendLiteral(seq, pos, ui_theme.ansi(theme, .code_keyword));
                appendLiteral(seq, pos, "fn");
                appendLiteral(seq, pos, reset);
                appendLiteral(seq, pos, " greet() { return ");
                appendLiteral(seq, pos, ui_theme.ansi(theme, .code_number));
                appendLiteral(seq, pos, "42");
                appendLiteral(seq, pos, reset);
                appendLiteral(seq, pos, "; }");
            } else {
                appendLiteral(seq, pos, ui_theme.ansi(theme, .overlay_hint));
                appendLiteral(seq, pos, "syntax highlighting disabled");
            }
        },
        else => {},
    }
}

fn clearThemePickerOverlay(bottom_margin_rows: usize) void {
    const rows = terminalRows();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;
    const overlay_rows = themePickerOverlayRows();
    const bottom_row = if (status_row > 1) status_row - 1 else 1;
    const top_row = if (bottom_row >= overlay_rows) bottom_row - overlay_rows + 1 else 1;

    var seq: [1024]u8 = undefined;
    var pos: usize = 0;
    appendLiteral(&seq, &pos, "\x1b7");
    var row: usize = 0;
    while (row < overlay_rows) : (row += 1) {
        appendCursorTo(&seq, &pos, top_row + row);
        appendLiteral(&seq, &pos, "\x1b[2K");
    }
    appendLiteral(&seq, &pos, "\x1b8");
    _ = std.c.write(std.Io.File.stdout().handle, (seq[0..pos]).ptr, (seq[0..pos]).len);
}

pub fn runModelPickerOverlayLoop(
    data: ModelPickerData,
    bottom_margin_rows: usize,
    bindings: ?*const keybindings.RuntimeKeybindings,
) !?usize {
    if (data.items.len == 0) return null;

    const fd = std.Io.File.stdin().handle;
    var filter_buf: [64]u8 = undefined;
    var filter_len: usize = 0;
    var selected: usize = initialModelPickerSelection(data);
    const contexts = [_]keybindings.BindingContext{ .ModelPicker, .Select };

    while (true) {
        // Build filtered index list
        var filtered_indices: [256]usize = undefined;
        var filtered_count: usize = 0;
        for (data.items, 0..) |item, idx| {
            if (filter_len == 0 or containsFilter(item.id, filter_buf[0..filter_len])) {
                if (filtered_count < 256) {
                    filtered_indices[filtered_count] = idx;
                    filtered_count += 1;
                }
            }
        }

        // Clamp selection
        if (filtered_count > 0 and selected >= filtered_count) selected = filtered_count - 1;

        renderModelPickerOverlay(data, filtered_indices[0..filtered_count], selected, filter_buf[0..filter_len], bottom_margin_rows);

        var chord_buf: [24]u8 = undefined;
        const key = readPickerKey(fd, &chord_buf) catch {
            clearModelPickerOverlay(data.items.len, bottom_margin_rows);
            return null;
        };
        const ev = resolvePickerBinding(bindings, &contexts, key.chord, key.event);

        switch (ev) {
            .up => selected = if (filtered_count == 0) 0 else if (selected == 0) filtered_count - 1 else selected - 1,
            .down, .next => selected = if (filtered_count == 0) 0 else (selected + 1) % filtered_count,
            .select => {
                clearModelPickerOverlay(data.items.len, bottom_margin_rows);
                if (filtered_count == 0) return null;
                return filtered_indices[selected]; // Return original index
            },
            .cancel => {
                clearModelPickerOverlay(data.items.len, bottom_margin_rows);
                return null;
            },
            .backspace => {
                if (filter_len > 0) {
                    filter_len -= 1;
                    selected = 0;
                }
            },
            .char => {
                if (filter_len < filter_buf.len) {
                    filter_buf[filter_len] = key.char;
                    filter_len += 1;
                    selected = 0;
                }
            },
            .tab, .shift_tab, .toggle => {},
            .none => {},
        }
    }
}

/// Rank a session-switcher item against `filter`. Returns the best
/// fuzzyScore across id/label/summary, or a low fallback score for a
/// substring-only match (so anything the old containsFilter surfaced still
/// appears, just ranked below true fuzzy hits). Null when nothing matches.
fn bestSessionFuzzyScore(item: SessionSwitcherItem, filter: []const u8) ?i32 {
    var best: ?i32 = null;
    const fields = [_][]const u8{ item.label, item.id, item.updated_summary };
    for (fields) |f| {
        if (f.len == 0) continue;
        if (fuzzy.fuzzyScore(filter, f)) |s| {
            if (best == null or s > best.?) best = s;
        }
    }
    if (best) |s| return s;
    // Substring fallback: fuzzyScore failed but a literal substring matches.
    if (containsFilter(item.id, filter) or
        containsFilter(item.label, filter) or
        containsFilter(item.updated_summary, filter))
    {
        return 1;
    }
    return null;
}

fn containsFilter(haystack: []const u8, filter: []const u8) bool {
    if (filter.len == 0) return true;
    if (haystack.len < filter.len) return false;
    var i: usize = 0;
    while (i + filter.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + filter.len], filter)) return true;
    }
    return false;
}

/// Inverse-highlight the first case-insensitive occurrence of
/// `query` in `text`, writing into the overlay's shared buffer.
/// Delegates to core/format.zig writeHighlightedMatch for the SGR
/// wrapping so the semantics match other renderers, but uses the
/// existing append* helpers because repl_overlay.zig writes into a
/// fixed-size byte buffer rather than a std writer.
fn writeHighlightedMatchToBuf(buf: []u8, pos: *usize, text: []const u8, query: []const u8) void {
    if (query.len == 0 or query.len > text.len) {
        appendLiteral(buf, pos, text);
        return;
    }
    var match_start: ?usize = null;
    var i: usize = 0;
    while (i + query.len <= text.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(text[i .. i + query.len], query)) {
            match_start = i;
            break;
        }
    }
    if (match_start) |start| {
        if (start > 0) appendLiteral(buf, pos, text[0..start]);
        appendLiteral(buf, pos, "\x1b[7m");
        appendLiteral(buf, pos, text[start .. start + query.len]);
        appendLiteral(buf, pos, "\x1b[27m");
        const tail_start = start + query.len;
        if (tail_start < text.len) appendLiteral(buf, pos, text[tail_start..]);
    } else {
        appendLiteral(buf, pos, text);
    }
}

// ANSI color constants for model picker
const CLR_RESET = "\x1b[0m";
const CLR_BOLD = "\x1b[1m";
const CLR_DIM = "\x1b[2m";
const CLR_BORDER = "\x1b[38;5;240m"; // dark gray
const CLR_HEADER = "\x1b[38;5;75m\x1b[1m"; // bright blue bold
const CLR_LABEL = "\x1b[38;5;245m"; // gray
const CLR_VALUE = "\x1b[38;5;252m"; // bright white
const CLR_ACTIVE = "\x1b[38;5;220m"; // yellow
const CLR_CTX = "\x1b[38;5;245m"; // dim gray
const CLR_SEL_BG = "\x1b[48;5;24m"; // dark blue bg
const CLR_SEL_FG = "\x1b[38;5;15m\x1b[1m"; // white bold
const CLR_SEARCH = "\x1b[38;5;114m"; // green
const CLR_HINT = "\x1b[38;5;240m\x1b[3m"; // dim italic

fn renderModelPickerOverlay(data: ModelPickerData, filtered: []const usize, selected: usize, filter: []const u8, bottom_margin_rows: usize) void {
    const rows = terminalRows();
    const cols = terminalCols();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;

    const visible = @min(filtered.len, @as(usize, 8));
    const overlay_rows = modelPickerOverlayRows(data.items.len);
    const bottom_row = if (status_row > 1) status_row - 1 else 1;
    const top_row = if (bottom_row >= overlay_rows) bottom_row - overlay_rows + 1 else 1;

    var box_w: usize = if (cols < 48) cols else if (cols < 88) cols else 88;
    if (box_w < 4) box_w = 4;
    const inner = box_w - 2;

    var start: usize = 0;
    if (filtered.len > visible) {
        const half = visible / 2;
        if (selected > half) start = selected - half;
        if (start + visible > filtered.len) start = filtered.len - visible;
    }

    var seq: [16384]u8 = undefined;
    var pos: usize = 0;

    appendLiteral(&seq, &pos, "\x1b7");

    // Top border
    appendCursorTo(&seq, &pos, top_row);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x8c"); // top-left corner
    appendRepeatStr(&seq, &pos, "\xe2\x94\x80", inner); // horizontal line
    appendLiteral(&seq, &pos, "\xe2\x94\x90" ++ CLR_RESET); // top-right corner

    // Header: MODEL PICKER
    appendCursorTo(&seq, &pos, top_row + 1);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 " ++ CLR_HEADER ++ "MODEL PICKER");
    appendLiteral(&seq, &pos, CLR_RESET);
    padToWidth(&seq, &pos, 14, inner);
    appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);

    // Provider line
    appendCursorTo(&seq, &pos, top_row + 2);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 " ++ CLR_LABEL ++ "provider: " ++ CLR_VALUE);
    appendLiteral(&seq, &pos, data.active_provider);
    appendLiteral(&seq, &pos, CLR_RESET);
    padToWidth(&seq, &pos, 10 + data.active_provider.len, inner);
    appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);

    // Search line
    appendCursorTo(&seq, &pos, top_row + 3);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 " ++ CLR_SEARCH ++ "search: ");
    if (filter.len > 0) {
        appendLiteral(&seq, &pos, CLR_VALUE);
        // `inner` is derived from the terminal width (cols - 2). When the
        // user shrinks the terminal to < 14 cols the prior `inner - 12`
        // subtraction underflows usize to a huge value and, if the filter
        // string is long enough, slices out-of-bounds. Guard with a
        // saturating subtraction so we simply render nothing when there
        // is no room for even a single character.
        const available = if (inner > 12) inner - 12 else 0;
        const clipped_filter = if (filter.len > available) filter[0..available] else filter;
        appendLiteral(&seq, &pos, clipped_filter);
        appendLiteral(&seq, &pos, CLR_DIM ++ "\xe2\x96\x8e"); // cursor block
    } else {
        appendLiteral(&seq, &pos, CLR_HINT ++ "type to filter...");
    }
    appendLiteral(&seq, &pos, CLR_RESET);
    const search_content_len = 8 + if (filter.len > 0) filter.len + 1 else 17;
    padToWidth(&seq, &pos, search_content_len, inner);
    appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);

    // Separator
    appendCursorTo(&seq, &pos, top_row + 4);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x9c"); // left T
    appendRepeatStr(&seq, &pos, "\xe2\x94\x80", inner);
    appendLiteral(&seq, &pos, "\xe2\x94\xa4" ++ CLR_RESET); // right T

    // Model items
    var row_idx: usize = 0;
    while (row_idx < @min(visible, @as(usize, 8))) : (row_idx += 1) {
        const filt_idx = start + row_idx;
        if (filt_idx >= filtered.len) break;
        const item_idx = filtered[filt_idx];
        const item = data.items[item_idx];
        const is_selected = filt_idx == selected;
        const is_active = std.mem.eql(u8, item.id, data.active_model);

        appendCursorTo(&seq, &pos, top_row + 5 + row_idx);
        appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 ");

        if (is_selected) {
            appendLiteral(&seq, &pos, CLR_SEL_BG ++ CLR_SEL_FG ++ " \xe2\x96\xb6 "); // selected arrow
        } else {
            appendLiteral(&seq, &pos, CLR_RESET ++ "   ");
        }

        // Model name
        if (is_active and !is_selected) {
            appendLiteral(&seq, &pos, CLR_ACTIVE);
        } else if (!is_selected) {
            appendLiteral(&seq, &pos, CLR_VALUE);
        }
        const name_max = if (inner > 30) inner - 22 else 10;
        const clipped_name = if (item.id.len > name_max) item.id[0..name_max] else item.id;
        // Inverse-highlight the matched filter substring so users
        // see where their query hit. Only applied to non-selected
        // rows -- the selected row already has its own inverse-bg
        // styling and a second inverse would cancel it out visually.
        if (filter.len > 0 and !is_selected) {
            writeHighlightedMatchToBuf(&seq, &pos, clipped_name, filter);
        } else {
            appendLiteral(&seq, &pos, clipped_name);
        }

        // Context window
        if (is_selected) {
            appendLiteral(&seq, &pos, CLR_RESET ++ CLR_SEL_BG ++ "  ");
        } else {
            appendLiteral(&seq, &pos, CLR_RESET ++ "  " ++ CLR_CTX);
        }
        var ctx_buf: [32]u8 = undefined;
        const ctx_str = std.fmt.bufPrint(&ctx_buf, "{d}k", .{item.ctx / 1000}) catch "?";
        appendLiteral(&seq, &pos, ctx_str);

        // Active badge
        if (is_active) {
            if (is_selected) {
                appendLiteral(&seq, &pos, " \xe2\x9c\x93"); // checkmark
            } else {
                appendLiteral(&seq, &pos, CLR_ACTIVE ++ " \xe2\x9c\x93" ++ CLR_RESET);
            }
        }

        appendLiteral(&seq, &pos, CLR_RESET);
        // Pad remaining space
        const content_used = 3 + clipped_name.len + 2 + ctx_str.len + if (is_active) @as(usize, 2) else 0;
        padToWidth(&seq, &pos, content_used, inner);
        appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);
    }

    // Empty state if no matches
    if (visible == 0) {
        appendCursorTo(&seq, &pos, top_row + 5);
        appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 " ++ CLR_HINT ++ "  no matching models");
        appendLiteral(&seq, &pos, CLR_RESET);
        padToWidth(&seq, &pos, 20, inner);
        appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);
    }

    // Footer hint
    const footer_row = top_row + 5 + @max(visible, 1);
    appendCursorTo(&seq, &pos, footer_row);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 " ++ CLR_HINT);
    var count_buf: [64]u8 = undefined;
    const count_str = std.fmt.bufPrint(&count_buf, "{d}/{d} models  \xe2\x86\x91\xe2\x86\x93 navigate  \xe2\x86\xb5 select  esc cancel", .{ filtered.len, data.items.len }) catch "navigate + enter";
    appendLiteral(&seq, &pos, count_str);
    appendLiteral(&seq, &pos, CLR_RESET);
    padToWidth(&seq, &pos, count_str.len, inner);
    appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);

    // Bottom border
    appendCursorTo(&seq, &pos, footer_row + 1);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x94");
    appendRepeatStr(&seq, &pos, "\xe2\x94\x80", inner);
    appendLiteral(&seq, &pos, "\xe2\x94\x98" ++ CLR_RESET);

    appendLiteral(&seq, &pos, "\x1b8");
    _ = std.c.write(std.Io.File.stdout().handle, (seq[0..pos]).ptr, (seq[0..pos]).len);
}

fn padToWidth(buf: []u8, pos: *usize, content_len: usize, inner: usize) void {
    const target = if (inner > 2) inner - 2 else 0;
    if (content_len < target) appendRepeatByte(buf, pos, " ", target - content_len);
}

fn appendRepeatStr(buf: []u8, pos: *usize, s: []const u8, count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (pos.* + s.len <= buf.len) {
            @memcpy(buf[pos.* .. pos.* + s.len], s);
            pos.* += s.len;
        }
    }
}

fn clearModelPickerOverlay(item_count: usize, bottom_margin_rows: usize) void {
    const rows = terminalRows();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;

    const overlay_rows = modelPickerOverlayRows(item_count);
    const bottom_row = if (status_row > 1) status_row - 1 else 1;
    const top_row = if (bottom_row >= overlay_rows) bottom_row - overlay_rows + 1 else 1;

    var seq: [2048]u8 = undefined;
    var pos: usize = 0;
    appendLiteral(&seq, &pos, "\x1b7");
    var i: usize = 0;
    while (i < overlay_rows) : (i += 1) {
        appendCursorTo(&seq, &pos, top_row + i);
        appendLiteral(&seq, &pos, "\x1b[2K");
    }
    appendLiteral(&seq, &pos, "\x1b8");
    _ = std.c.write(std.Io.File.stdout().handle, (seq[0..pos]).ptr, (seq[0..pos]).len);
}

// ── History search overlay ──

fn historySearchOverlayRows(item_count: usize) usize {
    const visible = @min(item_count, @as(usize, 8));
    return visible + 7;
}

pub fn runHistorySearchOverlayLoop(
    data: HistorySearchData,
    bottom_margin_rows: usize,
    bindings: ?*const keybindings.RuntimeKeybindings,
) !?usize {
    if (data.items.len == 0) return null;

    const fd = std.Io.File.stdin().handle;
    var filter_buf: [96]u8 = undefined;
    var filter_len: usize = 0;
    var selected: usize = 0;
    const contexts = [_]keybindings.BindingContext{ .HistorySearch, .Select };

    while (true) {
        var filtered_indices: [256]usize = undefined;
        var filtered_count: usize = 0;
        for (data.items, 0..) |item, idx| {
            if (filter_len == 0 or containsFilter(item.prompt, filter_buf[0..filter_len])) {
                if (filtered_count < filtered_indices.len) {
                    filtered_indices[filtered_count] = idx;
                    filtered_count += 1;
                }
            }
        }

        if (filtered_count > 0 and selected >= filtered_count) selected = filtered_count - 1;

        renderHistorySearchOverlay(data, filtered_indices[0..filtered_count], selected, filter_buf[0..filter_len], bottom_margin_rows);

        var chord_buf: [24]u8 = undefined;
        const key = readPickerKey(fd, &chord_buf) catch {
            clearHistorySearchOverlay(data.items.len, bottom_margin_rows);
            return null;
        };
        const ev = resolvePickerBinding(bindings, &contexts, key.chord, key.event);

        switch (ev) {
            .up => selected = if (filtered_count == 0) 0 else if (selected == 0) filtered_count - 1 else selected - 1,
            .down, .next => selected = if (filtered_count == 0) 0 else (selected + 1) % filtered_count,
            .select => {
                clearHistorySearchOverlay(data.items.len, bottom_margin_rows);
                if (filtered_count == 0) return null;
                return filtered_indices[selected];
            },
            .cancel => {
                clearHistorySearchOverlay(data.items.len, bottom_margin_rows);
                return null;
            },
            .backspace => {
                if (filter_len == 0) {
                    clearHistorySearchOverlay(data.items.len, bottom_margin_rows);
                    return null;
                }
                filter_len -= 1;
                selected = 0;
            },
            .char => {
                if (key.char >= 0x20 and key.char < 0x7f and filter_len < filter_buf.len) {
                    filter_buf[filter_len] = key.char;
                    filter_len += 1;
                    selected = 0;
                }
            },
            .tab, .shift_tab, .toggle => {},
            .none => {},
        }
    }
}

fn renderHistorySearchOverlay(data: HistorySearchData, filtered: []const usize, selected: usize, filter: []const u8, bottom_margin_rows: usize) void {
    const rows = terminalRows();
    const cols = terminalCols();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;

    const visible = @min(filtered.len, @as(usize, 8));
    const overlay_rows = historySearchOverlayRows(data.items.len);
    const bottom_row = if (status_row > 1) status_row - 1 else 1;
    const top_row = if (bottom_row >= overlay_rows) bottom_row - overlay_rows + 1 else 1;

    var box_w: usize = if (cols < 56) cols else if (cols < 96) cols else 96;
    if (box_w < 4) box_w = 4;
    const inner = box_w - 2;

    var start: usize = 0;
    if (filtered.len > visible) {
        const half = visible / 2;
        if (selected > half) start = selected - half;
        if (start + visible > filtered.len) start = filtered.len - visible;
    }

    var seq: [16384]u8 = undefined;
    var pos: usize = 0;

    appendLiteral(&seq, &pos, "\x1b7");

    appendCursorTo(&seq, &pos, top_row);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x8c");
    appendRepeatStr(&seq, &pos, "\xe2\x94\x80", inner);
    appendLiteral(&seq, &pos, "\xe2\x94\x90" ++ CLR_RESET);

    appendCursorTo(&seq, &pos, top_row + 1);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 " ++ CLR_HEADER ++ "HISTORY SEARCH");
    appendLiteral(&seq, &pos, CLR_RESET);
    padToWidth(&seq, &pos, 14, inner);
    appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);

    appendCursorTo(&seq, &pos, top_row + 2);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 " ++ CLR_LABEL ++ "scope: " ++ CLR_VALUE ++ "current workspace");
    appendLiteral(&seq, &pos, CLR_RESET);
    padToWidth(&seq, &pos, 24, inner);
    appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);

    appendCursorTo(&seq, &pos, top_row + 3);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 " ++ CLR_SEARCH ++ "search: ");
    if (filter.len > 0) {
        appendLiteral(&seq, &pos, CLR_VALUE);
        const available = if (inner > 12) inner - 12 else 0;
        const clipped_filter = if (filter.len > available) filter[0..available] else filter;
        appendLiteral(&seq, &pos, clipped_filter);
        appendLiteral(&seq, &pos, CLR_DIM ++ "\xe2\x96\x8e");
    } else {
        appendLiteral(&seq, &pos, CLR_HINT ++ "type to filter previous prompts...");
    }
    appendLiteral(&seq, &pos, CLR_RESET);
    const search_content_len = 8 + if (filter.len > 0) filter.len + 1 else 33;
    padToWidth(&seq, &pos, search_content_len, inner);
    appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);

    appendCursorTo(&seq, &pos, top_row + 4);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x9c");
    appendRepeatStr(&seq, &pos, "\xe2\x94\x80", inner);
    appendLiteral(&seq, &pos, "\xe2\x94\xa4" ++ CLR_RESET);

    var row_idx: usize = 0;
    while (row_idx < @min(visible, @as(usize, 8))) : (row_idx += 1) {
        const filt_idx = start + row_idx;
        if (filt_idx >= filtered.len) break;
        const item_idx = filtered[filt_idx];
        const item = data.items[item_idx];
        const is_selected = filt_idx == selected;

        appendCursorTo(&seq, &pos, top_row + 5 + row_idx);
        appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 ");

        if (is_selected) {
            appendLiteral(&seq, &pos, CLR_SEL_BG ++ CLR_SEL_FG ++ " \xe2\x96\xb6 ");
        } else {
            appendLiteral(&seq, &pos, CLR_RESET ++ "   ");
        }

        var preview_buf: [256]u8 = undefined;
        const preview = historySearchPreview(preview_buf[0..], item.prompt);
        var age_buf: [24]u8 = undefined;
        const age = if (item.timestamp > 0)
            format.formatRelativeTimeShort(&age_buf, item.timestamp, clock.nowSeconds())
        else
            "";
        const age_len = if (age.len > 0) age.len + 2 else 0;
        const preview_max = if (inner > 10 + age_len) inner - 10 - age_len else 8;
        const clipped_preview = if (preview.len > preview_max) preview[0..preview_max] else preview;

        if (!is_selected) appendLiteral(&seq, &pos, CLR_VALUE);
        if (filter.len > 0 and !is_selected) {
            writeHighlightedMatchToBuf(&seq, &pos, clipped_preview, filter);
        } else {
            appendLiteral(&seq, &pos, clipped_preview);
        }

        if (age.len > 0) {
            if (is_selected) {
                appendLiteral(&seq, &pos, CLR_RESET ++ CLR_SEL_BG ++ "  ");
            } else {
                appendLiteral(&seq, &pos, CLR_RESET ++ "  " ++ CLR_CTX);
            }
            appendLiteral(&seq, &pos, age);
        }

        appendLiteral(&seq, &pos, CLR_RESET);
        const content_used = 3 + clipped_preview.len + age_len;
        padToWidth(&seq, &pos, content_used, inner);
        appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);
    }

    if (visible == 0) {
        appendCursorTo(&seq, &pos, top_row + 5);
        appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 " ++ CLR_HINT ++ "  no matching prompts");
        appendLiteral(&seq, &pos, CLR_RESET);
        padToWidth(&seq, &pos, 21, inner);
        appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);
    }

    const footer_row = top_row + 5 + @max(visible, 1);
    appendCursorTo(&seq, &pos, footer_row);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 " ++ CLR_HINT);
    var count_buf: [96]u8 = undefined;
    const count_str = std.fmt.bufPrint(&count_buf, "{d}/{d} prompts  ctrl+r next  \xe2\x86\x91\xe2\x86\x93 move  \xe2\x86\xb5 insert  esc cancel", .{ filtered.len, data.items.len }) catch "history search";
    appendLiteral(&seq, &pos, count_str);
    appendLiteral(&seq, &pos, CLR_RESET);
    padToWidth(&seq, &pos, count_str.len, inner);
    appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);

    appendCursorTo(&seq, &pos, footer_row + 1);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x94");
    appendRepeatStr(&seq, &pos, "\xe2\x94\x80", inner);
    appendLiteral(&seq, &pos, "\xe2\x94\x98" ++ CLR_RESET);

    appendLiteral(&seq, &pos, "\x1b8");
    _ = std.c.write(std.Io.File.stdout().handle, (seq[0..pos]).ptr, (seq[0..pos]).len);
}

fn clearHistorySearchOverlay(item_count: usize, bottom_margin_rows: usize) void {
    const rows = terminalRows();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;

    const overlay_rows = historySearchOverlayRows(item_count);
    const bottom_row = if (status_row > 1) status_row - 1 else 1;
    const top_row = if (bottom_row >= overlay_rows) bottom_row - overlay_rows + 1 else 1;

    var seq: [2048]u8 = undefined;
    var pos: usize = 0;
    appendLiteral(&seq, &pos, "\x1b7");
    var i: usize = 0;
    while (i < overlay_rows) : (i += 1) {
        appendCursorTo(&seq, &pos, top_row + i);
        appendLiteral(&seq, &pos, "\x1b[2K");
    }
    appendLiteral(&seq, &pos, "\x1b8");
    _ = std.c.write(std.Io.File.stdout().handle, (seq[0..pos]).ptr, (seq[0..pos]).len);
}

fn historySearchPreview(out: []u8, prompt: []const u8) []const u8 {
    var pos: usize = 0;
    var last_space = false;

    for (prompt) |ch| {
        switch (ch) {
            '\r' => {},
            '\n' => {
                const replacement = " \xe2\x8f\x8e ";
                if (pos + replacement.len > out.len) return std.mem.trim(u8, out[0..pos], " ");
                @memcpy(out[pos .. pos + replacement.len], replacement);
                pos += replacement.len;
                last_space = false;
            },
            '\t', ' ' => {
                if (!last_space and pos < out.len) {
                    out[pos] = ' ';
                    pos += 1;
                    last_space = true;
                }
            },
            else => {
                if (ch < 0x20 or ch == 0x7f) continue;
                if (pos >= out.len) return std.mem.trim(u8, out[0..pos], " ");
                out[pos] = ch;
                pos += 1;
                last_space = false;
            },
        }
    }

    return std.mem.trim(u8, out[0..pos], " ");
}

const MESSAGE_ACTIONS_LIST_ROWS: usize = 8;
const MESSAGE_ACTIONS_PREVIEW_ROWS: usize = 5;

fn messageActionKindLabel(kind: MessageActionsItemKind) []const u8 {
    return switch (kind) {
        .user => "You",
        .assistant => "Assistant",
        .section => "Section",
    };
}

fn primaryActionLabel(kind: MessageActionsItemKind) []const u8 {
    return switch (kind) {
        .user => "recall",
        .assistant, .section => "copy",
    };
}

fn messageSelectorOverlayRows(item_count: usize) usize {
    const visible = @min(if (item_count == 0) @as(usize, 1) else item_count, @as(usize, 8));
    return visible + 5;
}

fn summarizePromptLine(prompt: []const u8, out: []u8) []const u8 {
    var pos: usize = 0;
    var saw_content = false;
    var last_space = false;
    var i: usize = 0;
    while (i < prompt.len and pos < out.len) : (i += 1) {
        const ch = prompt[i];
        if (ch == '\n' or ch == '\r' or ch == '\t' or ch == ' ') {
            if (saw_content and !last_space and pos < out.len) {
                out[pos] = ' ';
                pos += 1;
                last_space = true;
            }
            continue;
        }
        if (ch < 0x20 or ch == 0x7f) continue;
        out[pos] = ch;
        pos += 1;
        saw_content = true;
        last_space = false;
    }

    while (pos > 0 and out[pos - 1] == ' ') pos -= 1;
    if (pos == 0) {
        const empty = "<empty prompt>";
        const len = @min(empty.len, out.len);
        @memcpy(out[0..len], empty[0..len]);
        pos = len;
    } else if (i < prompt.len and out.len >= 3 and pos >= 3) {
        out[pos - 3] = '.';
        out[pos - 2] = '.';
        out[pos - 1] = '.';
    }
    return out[0..pos];
}

pub fn runMessageSelectorOverlayLoop(
    data: MessageSelectorData,
    bottom_margin_rows: usize,
    bindings: ?*const keybindings.RuntimeKeybindings,
) !?usize {
    if (data.items.len == 0) return null;

    const fd = std.Io.File.stdin().handle;
    var filter_buf: [96]u8 = undefined;
    var filter_len: usize = 0;
    var selected = @min(data.initial_selection, data.items.len - 1);
    const contexts = [_]keybindings.BindingContext{ .MessageSelector, .Select };

    while (true) {
        var filtered_indices: [256]usize = undefined;
        var filtered_count: usize = 0;
        for (data.items, 0..) |item, idx| {
            if (filter_len == 0 or containsFilter(item.prompt, filter_buf[0..filter_len])) {
                if (filtered_count < filtered_indices.len) {
                    filtered_indices[filtered_count] = idx;
                    filtered_count += 1;
                }
            }
        }

        if (filtered_count > 0 and selected >= filtered_count) selected = filtered_count - 1;

        renderMessageSelectorOverlay(data, filtered_indices[0..filtered_count], selected, filter_buf[0..filter_len], bottom_margin_rows);

        var chord_buf: [24]u8 = undefined;
        const key = readPickerKey(fd, &chord_buf) catch {
            clearMessageSelectorOverlay(data.items.len, bottom_margin_rows);
            return null;
        };

        if (bindings) |kb| {
            const lookup = kb.lookup(&contexts, key.chord);
            if (lookup.handled) {
                if (lookup.action) |action| {
                    switch (action) {
                        .message_selector_top => {
                            selected = 0;
                            continue;
                        },
                        .message_selector_bottom => {
                            selected = if (filtered_count == 0) 0 else filtered_count - 1;
                            continue;
                        },
                        else => {},
                    }
                } else {
                    continue;
                }
            }
        }

        const ev = resolvePickerBinding(bindings, &contexts, key.chord, key.event);
        switch (ev) {
            .up => selected = if (filtered_count == 0) 0 else if (selected == 0) filtered_count - 1 else selected - 1,
            .down, .next => selected = if (filtered_count == 0) 0 else (selected + 1) % filtered_count,
            .select => {
                clearMessageSelectorOverlay(data.items.len, bottom_margin_rows);
                if (filtered_count == 0) return null;
                return filtered_indices[selected];
            },
            .cancel => {
                clearMessageSelectorOverlay(data.items.len, bottom_margin_rows);
                return null;
            },
            .backspace => {
                if (filter_len > 0) {
                    filter_len -= 1;
                    selected = 0;
                }
            },
            .char => {
                if (key.char >= 0x20 and key.char < 0x7f and filter_len < filter_buf.len) {
                    filter_buf[filter_len] = key.char;
                    filter_len += 1;
                    selected = 0;
                }
            },
            .tab, .shift_tab, .toggle, .none => {},
        }
    }
}

fn renderMessageSelectorOverlay(
    data: MessageSelectorData,
    filtered: []const usize,
    selected: usize,
    filter: []const u8,
    bottom_margin_rows: usize,
) void {
    const rows = terminalRows();
    const cols = terminalCols();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;
    const visible = @min(filtered.len, @as(usize, 8));
    const overlay_rows = messageSelectorOverlayRows(data.items.len);
    const bottom_row = if (status_row > 1) status_row - 1 else 1;
    const top_row = if (bottom_row >= overlay_rows) bottom_row - overlay_rows + 1 else 1;

    var box_w: usize = if (cols < 72) cols else if (cols < 112) cols else 112;
    if (box_w < 4) box_w = 4;
    const inner = box_w - 2;

    var start: usize = 0;
    if (filtered.len > visible) {
        const half = visible / 2;
        if (selected > half) start = selected - half;
        if (start + visible > filtered.len) start = filtered.len - visible;
    }

    var seq: [12288]u8 = undefined;
    var pos: usize = 0;
    appendLiteral(&seq, &pos, "\x1b7");

    var clear_row: usize = 0;
    while (clear_row < overlay_rows) : (clear_row += 1) {
        appendCursorTo(&seq, &pos, top_row + clear_row);
        appendLiteral(&seq, &pos, "\x1b[2K");
    }

    appendSimpleOverlayBorder(&seq, &pos, top_row, inner);

    var title_buf: [160]u8 = undefined;
    const title = if (filter.len == 0)
        std.fmt.bufPrint(&title_buf, " Rewind conversation  •  {d} prior prompts", .{data.items.len}) catch " Rewind conversation"
    else
        std.fmt.bufPrint(&title_buf, " Rewind conversation  •  filter: {s}", .{filter}) catch " Rewind conversation";
    appendSimpleOverlayLine(&seq, &pos, top_row + 1, inner, title);

    var row: usize = 0;
    while (row < visible) : (row += 1) {
        const item_idx = filtered[start + row];
        const item = data.items[item_idx];
        var summary_buf: [320]u8 = undefined;
        const summary = summarizePromptLine(item.prompt, &summary_buf);
        var line_buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(
            &line_buf,
            " {s} [{d}] {s}",
            .{
                if (start + row == selected) ">" else " ",
                item_idx + 1,
                summary,
            },
        ) catch summary;
        appendSimpleOverlayLine(&seq, &pos, top_row + 2 + row, inner, line);
    }

    if (visible == 0) {
        appendSimpleOverlayLine(&seq, &pos, top_row + 2, inner, " No previous prompts matched this filter");
    }

    const footer_row = if (visible == 0) top_row + 3 else top_row + 2 + visible;
    appendSimpleOverlayLine(&seq, &pos, footer_row, inner, " Enter rewind  •  Esc cancel  •  Type to filter");
    appendSimpleOverlayBottomBorder(&seq, &pos, footer_row + 1, inner);

    appendLiteral(&seq, &pos, "\x1b8");
    _ = std.c.write(std.Io.File.stdout().handle, (seq[0..pos]).ptr, (seq[0..pos]).len);
}

fn clearMessageSelectorOverlay(item_count: usize, bottom_margin_rows: usize) void {
    const rows = terminalRows();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;
    const overlay_rows = messageSelectorOverlayRows(item_count);
    const bottom_row = if (status_row > 1) status_row - 1 else 1;
    const top_row = if (bottom_row >= overlay_rows) bottom_row - overlay_rows + 1 else 1;

    var seq: [2048]u8 = undefined;
    var pos: usize = 0;
    appendLiteral(&seq, &pos, "\x1b7");
    var row: usize = 0;
    while (row < overlay_rows) : (row += 1) {
        appendCursorTo(&seq, &pos, top_row + row);
        appendLiteral(&seq, &pos, "\x1b[2K");
    }
    appendLiteral(&seq, &pos, "\x1b8");
    _ = std.c.write(std.Io.File.stdout().handle, (seq[0..pos]).ptr, (seq[0..pos]).len);
}

fn messageActionsOverlayRows(item_count: usize) usize {
    const visible = @min(item_count, MESSAGE_ACTIONS_LIST_ROWS);
    return visible + MESSAGE_ACTIONS_PREVIEW_ROWS + 6;
}

fn previousUserMessageIndex(items: []const MessageActionsItem, start: usize) usize {
    if (items.len == 0) return 0;
    var offset: usize = 1;
    while (offset <= items.len) : (offset += 1) {
        const idx = (start + items.len - (offset % items.len)) % items.len;
        if (items[idx].kind == .user) return idx;
    }
    return start;
}

fn nextUserMessageIndex(items: []const MessageActionsItem, start: usize) usize {
    if (items.len == 0) return 0;
    var offset: usize = 1;
    while (offset <= items.len) : (offset += 1) {
        const idx = (start + offset) % items.len;
        if (items[idx].kind == .user) return idx;
    }
    return start;
}

pub fn runMessageActionsOverlayLoop(
    data: MessageActionsData,
    bottom_margin_rows: usize,
    bindings: ?*const keybindings.RuntimeKeybindings,
) !?MessageActionsResult {
    if (data.items.len == 0) return null;

    const fd = std.Io.File.stdin().handle;
    var selected = @min(data.initial_selection, data.items.len - 1);
    const contexts = [_]keybindings.BindingContext{.MessageActions};
    defer clearMessageActionsOverlay(data.items.len, bottom_margin_rows);

    while (true) {
        renderMessageActionsOverlay(data, selected, bottom_margin_rows);

        var chord_buf: [24]u8 = undefined;
        const key = readPickerKey(fd, &chord_buf) catch return null;
        const lookup = if (bindings) |kb| kb.lookup(&contexts, key.chord) else keybindings.RuntimeLookup{};

        if (lookup.handled) {
            const action = lookup.action orelse continue;
            switch (action) {
                .message_actions_prev => {
                    selected = if (selected == 0) data.items.len - 1 else selected - 1;
                    continue;
                },
                .message_actions_next => {
                    selected = (selected + 1) % data.items.len;
                    continue;
                },
                .message_actions_top => {
                    selected = 0;
                    continue;
                },
                .message_actions_bottom => {
                    selected = data.items.len - 1;
                    continue;
                },
                .message_actions_prev_user => {
                    selected = previousUserMessageIndex(data.items, selected);
                    continue;
                },
                .message_actions_next_user => {
                    selected = nextUserMessageIndex(data.items, selected);
                    continue;
                },
                .message_actions_cancel => return null,
                .message_actions_accept => return .{ .item_index = selected, .action = .primary },
                .message_actions_copy => return .{ .item_index = selected, .action = .copy },
                else => {},
            }
        }

        switch (key.event) {
            .up => selected = if (selected == 0) data.items.len - 1 else selected - 1,
            .down, .next => selected = (selected + 1) % data.items.len,
            .select => return .{ .item_index = selected, .action = .primary },
            .cancel => return null,
            .char => {
                if (key.char == 'c' or key.char == 'C') {
                    return .{ .item_index = selected, .action = .copy };
                }
                if (key.char == 'e' or key.char == 'E') {
                    return .{ .item_index = selected, .action = .primary };
                }
            },
            .tab, .shift_tab, .toggle, .backspace, .none => {},
        }
    }
}

/// After a rewind target is chosen, ask whether to ALSO roll the
/// working tree back (code restore) or rewind the conversation only.
/// Claude Code's /rewind restores "the code and/or conversation"; the
/// code half is destructive (reverts tracked files, drops untracked),
/// so the default is conversation-only and the user must press y/Y to
/// opt into code restore. Returns true only on an explicit yes; Enter,
/// Esc, n/N, Ctrl+C and EOF all mean "conversation only".
///
/// Raw mode is already active (this is reached from the fullscreen
/// rewind selector), so we read a single key with readOneByte.
pub fn runRewindCodeRestoreConfirm() !bool {
    const stdout = std_io.stdoutWriter();
    try stdout.writeAll(
        "\r\n\x1b[2mAlso restore CODE (revert working tree to the last checkpoint)? [y/N] \x1b[0m",
    );

    const fd = std.Io.File.stdin().handle;
    const b = readOneByte(fd) catch return false;
    return b == 'y' or b == 'Y';
}

fn renderMessageActionsOverlay(data: MessageActionsData, selected: usize, bottom_margin_rows: usize) void {
    const rows = terminalRows();
    const cols = terminalCols();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;
    const overlay_rows = messageActionsOverlayRows(data.items.len);
    const bottom_row = if (status_row > 1) status_row - 1 else 1;
    const top_row = if (bottom_row >= overlay_rows) bottom_row - overlay_rows + 1 else 1;
    const inner = if (cols > 2) cols - 2 else 1;
    const visible = @min(data.items.len, MESSAGE_ACTIONS_LIST_ROWS);
    const preview_rows = MESSAGE_ACTIONS_PREVIEW_ROWS;

    var seq: [16384]u8 = undefined;
    var pos: usize = 0;
    appendLiteral(&seq, &pos, "\x1b7");

    appendCursorTo(&seq, &pos, top_row);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x95\xad");
    appendRepeatStr(&seq, &pos, "\xe2\x94\x80", inner);
    appendLiteral(&seq, &pos, "\xe2\x95\xae" ++ CLR_RESET);

    appendCursorTo(&seq, &pos, top_row + 1);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 " ++ CLR_HEADER ++ "Message Actions" ++ CLR_RESET);
    padToWidth(&seq, &pos, "Message Actions".len, inner);
    appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);

    const selected_item = data.items[selected];
    appendCursorTo(&seq, &pos, top_row + 2);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 " ++ CLR_HINT);
    var action_buf: [160]u8 = undefined;
    const action_line = std.fmt.bufPrint(
        &action_buf,
        "\xe2\x86\x91\xe2\x86\x93 move  \xe2\x86\xb5 {s}  c copy  esc close",
        .{primaryActionLabel(selected_item.kind)},
    ) catch "message actions";
    appendLiteral(&seq, &pos, action_line);
    appendLiteral(&seq, &pos, CLR_RESET);
    padToWidth(&seq, &pos, action_line.len, inner);
    appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);

    var start: usize = 0;
    if (visible > 0) {
        const half = visible / 2;
        if (selected > half) start = selected - half;
        if (start + visible > data.items.len) start = data.items.len - visible;
    }

    var row_idx: usize = 0;
    while (row_idx < MESSAGE_ACTIONS_LIST_ROWS) : (row_idx += 1) {
        appendCursorTo(&seq, &pos, top_row + 3 + row_idx);
        appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 " ++ CLR_RESET);

        if (row_idx < visible) {
            const item_idx = start + row_idx;
            const item = data.items[item_idx];
            const is_selected = item_idx == selected;
            const marker = if (is_selected) "> " else "  ";
            appendLiteral(&seq, &pos, if (is_selected) CLR_SEL_BG ++ CLR_SEL_FG else CLR_RESET);
            appendLiteral(&seq, &pos, marker);
            appendLiteral(&seq, &pos, CLR_RESET);

            appendLiteral(&seq, &pos, CLR_LABEL);
            appendLiteral(&seq, &pos, messageActionKindLabel(item.kind));
            appendLiteral(&seq, &pos, CLR_RESET);
            appendLiteral(&seq, &pos, "  ");

            const preview = previewLineAt(item.content, 0);
            const preview_budget = if (inner > 18) inner - 18 else 0;
            const clipped_preview = if (preview.len > preview_budget) preview[0..preview_budget] else preview;
            appendLiteral(&seq, &pos, if (is_selected) CLR_SEL_FG else CLR_VALUE);
            appendLiteral(&seq, &pos, clipped_preview);
            appendLiteral(&seq, &pos, CLR_RESET);

            const content_used = marker.len + messageActionKindLabel(item.kind).len + 2 + clipped_preview.len;
            padToWidth(&seq, &pos, content_used, inner);
        } else {
            padToWidth(&seq, &pos, 0, inner);
        }

        appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);
    }

    appendCursorTo(&seq, &pos, top_row + 3 + MESSAGE_ACTIONS_LIST_ROWS);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 " ++ CLR_HEADER);
    var preview_header_buf: [160]u8 = undefined;
    const preview_header = std.fmt.bufPrint(
        &preview_header_buf,
        "Preview \xe2\x80\xa2 {s}",
        .{selected_item.label},
    ) catch "Preview";
    appendLiteral(&seq, &pos, preview_header);
    appendLiteral(&seq, &pos, CLR_RESET);
    padToWidth(&seq, &pos, preview_header.len, inner);
    appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);

    row_idx = 0;
    while (row_idx < preview_rows) : (row_idx += 1) {
        appendCursorTo(&seq, &pos, top_row + 4 + MESSAGE_ACTIONS_LIST_ROWS + row_idx);
        appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 " ++ CLR_VALUE);
        const line = previewLineAt(selected_item.content, row_idx);
        const preview_budget = if (inner > 2) inner - 2 else 0;
        const clipped = if (line.len > preview_budget) line[0..preview_budget] else line;
        appendLiteral(&seq, &pos, clipped);
        appendLiteral(&seq, &pos, CLR_RESET);
        padToWidth(&seq, &pos, clipped.len, inner);
        appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);
    }

    appendCursorTo(&seq, &pos, top_row + overlay_rows - 2);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 " ++ CLR_HINT);
    var footer_buf: [128]u8 = undefined;
    const footer = std.fmt.bufPrint(&footer_buf, "{d}/{d} messages", .{ selected + 1, data.items.len }) catch "messages";
    appendLiteral(&seq, &pos, footer);
    appendLiteral(&seq, &pos, CLR_RESET);
    padToWidth(&seq, &pos, footer.len, inner);
    appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);

    appendCursorTo(&seq, &pos, top_row + overlay_rows - 1);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x95\xb0");
    appendRepeatStr(&seq, &pos, "\xe2\x94\x80", inner);
    appendLiteral(&seq, &pos, "\xe2\x95\xaf" ++ CLR_RESET);

    appendLiteral(&seq, &pos, "\x1b8");
    _ = std.c.write(std.Io.File.stdout().handle, (seq[0..pos]).ptr, (seq[0..pos]).len);
}

fn clearMessageActionsOverlay(item_count: usize, bottom_margin_rows: usize) void {
    const rows = terminalRows();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;
    const overlay_rows = messageActionsOverlayRows(item_count);
    const bottom_row = if (status_row > 1) status_row - 1 else 1;
    const top_row = if (bottom_row >= overlay_rows) bottom_row - overlay_rows + 1 else 1;

    var seq: [2048]u8 = undefined;
    var pos: usize = 0;
    appendLiteral(&seq, &pos, "\x1b7");
    var i: usize = 0;
    while (i < overlay_rows) : (i += 1) {
        appendCursorTo(&seq, &pos, top_row + i);
        appendLiteral(&seq, &pos, "\x1b[2K");
    }
    appendLiteral(&seq, &pos, "\x1b8");
    _ = std.c.write(std.Io.File.stdout().handle, (seq[0..pos]).ptr, (seq[0..pos]).len);
}

// ── Fuzzy-picker preview layout ──
//
// Shared side-vs-bottom decision for the file/preview pickers. The
// reference (FuzzyPicker) switches a preview pane from the bottom to
// the right side once the terminal is wide enough, and the threshold
// differs per picker: QuickOpen flips at 120 columns, GlobalSearch at
// 140, and History at 100. Extracted as a pure helper so the thresholds
// are unit-testable and live in exactly one place.

pub const PreviewKind = enum {
    quick_open,
    global_search,
    history,
};

/// Column threshold at or above which the given picker shows its
/// preview pane on the right (side layout) instead of the bottom.
pub fn previewSideThreshold(kind: PreviewKind) usize {
    return switch (kind) {
        .quick_open => 120,
        .global_search => 140,
        .history => 100,
    };
}

/// True when the picker should render the preview on the right (wide
/// side-by-side layout) for the given terminal column count.
pub fn previewOnRight(kind: PreviewKind, cols: usize) bool {
    return cols >= previewSideThreshold(kind);
}

/// Render-options used to syntax-highlight file-preview lines. Mirrors
/// repl_edit's render_options: color on, code highlighting on. No
/// `theme` field, so ui_theme defaults to .dark to match the overlay's
/// hardcoded ANSI constants.
const preview_render_options = .{
    .color_enabled = true,
    .highlight_code_blocks = true,
};

/// Map a file path to a markdown CodeLang by its extension. Uses an
/// exact-extension table rather than repl_markdown.parseCodeLang because
/// that helper is prefix-based for fence tags (e.g. "json" prefix-matches
/// "js" -> javascript), which is wrong for file extensions.
fn langFromPath(path: []const u8) repl_markdown.CodeLang {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return .plain;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    if (slash) |s| {
        if (dot < s) return .plain; // the dot is in a directory name
    }
    const ext = path[dot + 1 ..];
    const Pair = struct { ext: []const u8, lang: repl_markdown.CodeLang };
    const table = [_]Pair{
        .{ .ext = "zig", .lang = .zig },
        .{ .ext = "go", .lang = .go },
        .{ .ext = "ts", .lang = .typescript },
        .{ .ext = "tsx", .lang = .typescript },
        .{ .ext = "js", .lang = .javascript },
        .{ .ext = "jsx", .lang = .javascript },
        .{ .ext = "mjs", .lang = .javascript },
        .{ .ext = "cjs", .lang = .javascript },
        .{ .ext = "json", .lang = .json },
        .{ .ext = "sh", .lang = .bash },
        .{ .ext = "bash", .lang = .bash },
        .{ .ext = "zsh", .lang = .bash },
        .{ .ext = "py", .lang = .python },
        .{ .ext = "yaml", .lang = .yaml },
        .{ .ext = "yml", .lang = .yaml },
        .{ .ext = "toml", .lang = .toml },
    };
    for (table) |pair| {
        if (std.ascii.eqlIgnoreCase(ext, pair.ext)) return pair.lang;
    }
    return .plain;
}

/// Write a single preview line into the overlay byte buffer with syntax
/// highlighting for the detected language. Falls back to a plain copy if
/// highlighting overflows the scratch buffer. The text is already clipped
/// to the cell width by the caller.
fn appendHighlightedPreviewLine(
    buf: []u8,
    pos: *usize,
    line: []const u8,
    lang: repl_markdown.CodeLang,
) void {
    if (lang == .plain) {
        appendLiteral(buf, pos, line);
        return;
    }
    var hl_buf: [1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&hl_buf);
    repl_markdown.writeCodeLine(&stream, line, lang, preview_render_options) catch {
        appendLiteral(buf, pos, line);
        return;
    };
    appendLiteral(buf, pos, stream.buffered());
}

// ── Quick open overlay ──

const QUICK_OPEN_MATCH_LIMIT: usize = 64;
const QUICK_OPEN_WIDE_BODY_ROWS: usize = 8;
const QUICK_OPEN_NARROW_LIST_ROWS: usize = 5;
const QUICK_OPEN_NARROW_PREVIEW_ROWS: usize = 4;

fn quickOpenOverlayRows(cols: usize) usize {
    return if (previewOnRight(.quick_open, cols)) 15 else 18;
}

pub fn runQuickOpenOverlayLoop(
    data: QuickOpenData,
    bottom_margin_rows: usize,
    bindings: ?*const keybindings.RuntimeKeybindings,
) !?QuickOpenResult {
    if (data.items.len == 0) return null;

    const fd = std.Io.File.stdin().handle;
    var filter_buf: [96]u8 = undefined;
    var filter_len: usize = 0;
    var selected: usize = 0;

    var preview_item_index: ?usize = null;
    var preview_text: ?[]u8 = null;
    defer if (preview_text) |text| data.allocator.free(text);
    const contexts = [_]keybindings.BindingContext{.Select};

    while (true) {
        var filtered_indices: [QUICK_OPEN_MATCH_LIMIT]usize = undefined;
        var filtered_scores: [QUICK_OPEN_MATCH_LIMIT]usize = undefined;
        const match_summary = collectQuickOpenMatches(
            data,
            filter_buf[0..filter_len],
            &filtered_indices,
            &filtered_scores,
        );
        const filtered_count = match_summary.count;
        const filtered_total = match_summary.total;

        if (filtered_count == 0) {
            selected = 0;
            preview_item_index = null;
            if (preview_text) |text| {
                data.allocator.free(text);
                preview_text = null;
            }
        } else {
            if (selected >= filtered_count) selected = filtered_count - 1;
            const item_index = filtered_indices[selected];
            const preview_lines = if (previewOnRight(.quick_open, terminalCols()))
                QUICK_OPEN_WIDE_BODY_ROWS - 1
            else
                QUICK_OPEN_NARROW_PREVIEW_ROWS;
            if (preview_item_index == null or preview_item_index.? != item_index) {
                if (preview_text) |text| {
                    data.allocator.free(text);
                    preview_text = null;
                }
                preview_text = repl_quick_open.loadPreview(
                    data.allocator,
                    data.workspace,
                    data.items[item_index].path,
                    preview_lines,
                ) catch try data.allocator.dupe(u8, "(preview unavailable)");
                preview_item_index = item_index;
            }
        }

        renderQuickOpenOverlay(
            data,
            filtered_indices[0..filtered_count],
            filtered_total,
            selected,
            filter_buf[0..filter_len],
            preview_text,
            bottom_margin_rows,
        );

        var chord_buf: [24]u8 = undefined;
        const key = readPickerKey(fd, &chord_buf) catch {
            clearQuickOpenOverlay(bottom_margin_rows);
            return null;
        };
        const ev = resolvePickerBinding(bindings, &contexts, key.chord, key.event);

        switch (ev) {
            .up => selected = if (filtered_count == 0) 0 else if (selected == 0) filtered_count - 1 else selected - 1,
            .down, .next => selected = if (filtered_count == 0) 0 else (selected + 1) % filtered_count,
            .select => {
                clearQuickOpenOverlay(bottom_margin_rows);
                if (filtered_count == 0) return null;
                return .{
                    .item_index = filtered_indices[selected],
                    .action = .open_in_editor,
                };
            },
            .tab => {
                clearQuickOpenOverlay(bottom_margin_rows);
                if (filtered_count == 0) return null;
                return .{
                    .item_index = filtered_indices[selected],
                    .action = .mention_path,
                };
            },
            .shift_tab => {
                clearQuickOpenOverlay(bottom_margin_rows);
                if (filtered_count == 0) return null;
                return .{
                    .item_index = filtered_indices[selected],
                    .action = .insert_path,
                };
            },
            .cancel => {
                clearQuickOpenOverlay(bottom_margin_rows);
                return null;
            },
            .backspace => {
                if (filter_len == 0) {
                    clearQuickOpenOverlay(bottom_margin_rows);
                    return null;
                }
                filter_len -= 1;
                selected = 0;
            },
            .char => {
                if (key.char >= 0x20 and key.char < 0x7f and filter_len < filter_buf.len) {
                    filter_buf[filter_len] = key.char;
                    filter_len += 1;
                    selected = 0;
                }
            },
            .toggle, .none => {},
        }
    }
}

const QuickOpenMatchSummary = struct {
    count: usize,
    total: usize,
};

fn collectQuickOpenMatches(
    data: QuickOpenData,
    query: []const u8,
    indices_out: *[QUICK_OPEN_MATCH_LIMIT]usize,
    scores_out: *[QUICK_OPEN_MATCH_LIMIT]usize,
) QuickOpenMatchSummary {
    if (query.len == 0) return .{ .count = 0, .total = 0 };

    var count: usize = 0;
    var total: usize = 0;
    for (data.items, 0..) |item, idx| {
        const score = quickOpenScore(item.path, query) orelse continue;
        total += 1;
        insertQuickOpenMatch(indices_out, scores_out, &count, idx, score);
    }

    return .{
        .count = count,
        .total = total,
    };
}

fn insertQuickOpenMatch(
    indices_out: *[QUICK_OPEN_MATCH_LIMIT]usize,
    scores_out: *[QUICK_OPEN_MATCH_LIMIT]usize,
    count: *usize,
    item_index: usize,
    score: usize,
) void {
    var insert_at = count.*;
    if (insert_at >= QUICK_OPEN_MATCH_LIMIT and score >= scores_out[QUICK_OPEN_MATCH_LIMIT - 1]) return;

    if (insert_at >= QUICK_OPEN_MATCH_LIMIT) insert_at = QUICK_OPEN_MATCH_LIMIT - 1;
    while (insert_at > 0 and scores_out[insert_at - 1] > score) : (insert_at -= 1) {}

    if (count.* < QUICK_OPEN_MATCH_LIMIT) count.* += 1;
    var i = count.*;
    while (i > insert_at + 1) : (i -= 1) {
        indices_out[i - 1] = indices_out[i - 2];
        scores_out[i - 1] = scores_out[i - 2];
    }
    indices_out[insert_at] = item_index;
    scores_out[insert_at] = score;
}

fn quickOpenScore(path: []const u8, query: []const u8) ?usize {
    if (query.len == 0) return null;
    const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx|
        path[idx + 1 ..]
    else
        path;

    if (indexOfIgnoreCase(basename, query)) |idx| {
        return idx * 2 + (basename.len - query.len);
    }
    if (indexOfIgnoreCase(path, query)) |idx| {
        return 100 + idx * 2 + (path.len - query.len);
    }
    if (fuzzySubsequenceScore(basename, query)) |score| return 250 + score;
    if (fuzzySubsequenceScore(path, query)) |score| return 500 + score;
    return null;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn fuzzySubsequenceScore(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;

    var matched: usize = 0;
    var first_match: usize = 0;
    var last_match: usize = 0;
    var gap_penalty: usize = 0;

    for (haystack, 0..) |ch, idx| {
        if (std.ascii.toLower(ch) != std.ascii.toLower(needle[matched])) continue;
        if (matched == 0) {
            first_match = idx;
        } else if (idx > last_match + 1) {
            gap_penalty += (idx - last_match - 1) * 4;
        }
        last_match = idx;
        matched += 1;
        if (matched == needle.len) {
            const span = last_match - first_match + 1;
            return gap_penalty + span + first_match;
        }
    }

    return null;
}

fn renderQuickOpenOverlay(
    data: QuickOpenData,
    filtered: []const usize,
    filtered_total: usize,
    selected: usize,
    filter: []const u8,
    preview_text: ?[]const u8,
    bottom_margin_rows: usize,
) void {
    const rows = terminalRows();
    const cols = terminalCols();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;
    const overlay_rows = quickOpenOverlayRows(cols);
    const bottom_row = if (status_row > 1) status_row - 1 else 1;
    const top_row = if (bottom_row >= overlay_rows) bottom_row - overlay_rows + 1 else 1;
    const wide = previewOnRight(.quick_open, cols);

    var box_w: usize = if (wide)
        @min(cols, @as(usize, 118))
    else if (cols < 64)
        cols
    else
        96;
    if (box_w < 4) box_w = 4;
    const inner = box_w - 2;

    var seq: [32768]u8 = undefined;
    var pos: usize = 0;
    appendLiteral(&seq, &pos, "\x1b7");

    appendCursorTo(&seq, &pos, top_row);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x8c");
    appendRepeatStr(&seq, &pos, "\xe2\x94\x80", inner);
    appendLiteral(&seq, &pos, "\xe2\x94\x90" ++ CLR_RESET);

    appendCursorTo(&seq, &pos, top_row + 1);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 " ++ CLR_HEADER ++ "QUICK OPEN");
    appendLiteral(&seq, &pos, CLR_RESET);
    padToWidth(&seq, &pos, 11, inner);
    appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);

    appendCursorTo(&seq, &pos, top_row + 2);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 " ++ CLR_LABEL ++ "scope: " ++ CLR_VALUE ++ "current workspace");
    appendLiteral(&seq, &pos, CLR_RESET);
    padToWidth(&seq, &pos, 24, inner);
    appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);

    appendCursorTo(&seq, &pos, top_row + 3);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 " ++ CLR_SEARCH ++ "search: ");
    if (filter.len > 0) {
        appendLiteral(&seq, &pos, CLR_VALUE);
        const available = if (inner > 12) inner - 12 else 0;
        const clipped_filter = if (filter.len > available) filter[0..available] else filter;
        appendLiteral(&seq, &pos, clipped_filter);
        appendLiteral(&seq, &pos, CLR_DIM ++ "\xe2\x96\x8e");
    } else {
        appendLiteral(&seq, &pos, CLR_HINT ++ "type to search files...");
    }
    appendLiteral(&seq, &pos, CLR_RESET);
    const search_content_len = 8 + if (filter.len > 0) filter.len + 1 else 23;
    padToWidth(&seq, &pos, search_content_len, inner);
    appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);

    if (wide) {
        renderQuickOpenWideBody(&seq, &pos, top_row, inner, data, filtered, selected, filter, preview_text);
    } else {
        renderQuickOpenNarrowBody(&seq, &pos, top_row, inner, data, filtered, selected, filter, preview_text);
    }

    const footer_row = if (wide) top_row + 13 else top_row + 16;
    appendCursorTo(&seq, &pos, footer_row);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 " ++ CLR_HINT);
    var count_buf: [128]u8 = undefined;
    const count_str = std.fmt.bufPrint(
        &count_buf,
        "{d}/{d} files  \xe2\x86\xb5 open  tab mention  shift+tab path  esc cancel",
        .{ filtered_total, data.items.len },
    ) catch "quick open";
    appendLiteral(&seq, &pos, count_str);
    appendLiteral(&seq, &pos, CLR_RESET);
    padToWidth(&seq, &pos, count_str.len, inner);
    appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);

    appendCursorTo(&seq, &pos, footer_row + 1);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x94");
    appendRepeatStr(&seq, &pos, "\xe2\x94\x80", inner);
    appendLiteral(&seq, &pos, "\xe2\x94\x98" ++ CLR_RESET);

    appendLiteral(&seq, &pos, "\x1b8");
    _ = std.c.write(std.Io.File.stdout().handle, (seq[0..pos]).ptr, (seq[0..pos]).len);
}

fn renderQuickOpenWideBody(
    seq: []u8,
    pos: *usize,
    top_row: usize,
    inner: usize,
    data: QuickOpenData,
    filtered: []const usize,
    selected: usize,
    filter: []const u8,
    preview_text: ?[]const u8,
) void {
    appendCursorTo(seq, pos, top_row + 4);
    appendLiteral(seq, pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x9c");
    appendRepeatStr(seq, pos, "\xe2\x94\x80", inner);
    appendLiteral(seq, pos, "\xe2\x94\xa4" ++ CLR_RESET);

    var left_w: usize = if (inner > 72) 36 else inner / 2;
    if (left_w < 24) left_w = 24;
    if (left_w + 9 > inner) left_w = inner / 2;
    const right_w = if (inner > left_w + 1) inner - left_w - 1 else 0;

    var start: usize = 0;
    if (filtered.len > QUICK_OPEN_WIDE_BODY_ROWS) {
        const half = QUICK_OPEN_WIDE_BODY_ROWS / 2;
        if (selected > half) start = selected - half;
        if (start + QUICK_OPEN_WIDE_BODY_ROWS > filtered.len) start = filtered.len - QUICK_OPEN_WIDE_BODY_ROWS;
    }

    var row_idx: usize = 0;
    while (row_idx < QUICK_OPEN_WIDE_BODY_ROWS) : (row_idx += 1) {
        appendCursorTo(seq, pos, top_row + 5 + row_idx);
        appendLiteral(seq, pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82");

        const match_idx = start + row_idx;
        const left_used = appendQuickOpenListCell(seq, pos, left_w, data, filtered, selected, match_idx, filter);
        padCellToWidth(seq, pos, left_used, left_w);

        appendLiteral(seq, pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);
        const right_used = appendQuickOpenPreviewWideCell(seq, pos, right_w, data, filtered, selected, row_idx, filter, preview_text);
        padCellToWidth(seq, pos, right_used, right_w);
        appendLiteral(seq, pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);
    }
}

fn renderQuickOpenNarrowBody(
    seq: []u8,
    pos: *usize,
    top_row: usize,
    inner: usize,
    data: QuickOpenData,
    filtered: []const usize,
    selected: usize,
    filter: []const u8,
    preview_text: ?[]const u8,
) void {
    appendCursorTo(seq, pos, top_row + 4);
    appendLiteral(seq, pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x9c");
    appendRepeatStr(seq, pos, "\xe2\x94\x80", inner);
    appendLiteral(seq, pos, "\xe2\x94\xa4" ++ CLR_RESET);

    var start: usize = 0;
    if (filtered.len > QUICK_OPEN_NARROW_LIST_ROWS) {
        const half = QUICK_OPEN_NARROW_LIST_ROWS / 2;
        if (selected > half) start = selected - half;
        if (start + QUICK_OPEN_NARROW_LIST_ROWS > filtered.len) start = filtered.len - QUICK_OPEN_NARROW_LIST_ROWS;
    }

    var row_idx: usize = 0;
    while (row_idx < QUICK_OPEN_NARROW_LIST_ROWS) : (row_idx += 1) {
        appendCursorTo(seq, pos, top_row + 5 + row_idx);
        appendLiteral(seq, pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82");
        const match_idx = start + row_idx;
        const used = appendQuickOpenListCell(seq, pos, inner, data, filtered, selected, match_idx, filter);
        padCellToWidth(seq, pos, used, inner);
        appendLiteral(seq, pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);
    }

    appendCursorTo(seq, pos, top_row + 10);
    appendLiteral(seq, pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x9c");
    appendRepeatStr(seq, pos, "\xe2\x94\x80", inner);
    appendLiteral(seq, pos, "\xe2\x94\xa4" ++ CLR_RESET);

    appendCursorTo(seq, pos, top_row + 11);
    appendLiteral(seq, pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82");
    const header_used = appendQuickOpenPreviewHeader(seq, pos, inner, data, filtered, selected);
    padCellToWidth(seq, pos, header_used, inner);
    appendLiteral(seq, pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);

    const narrow_lang = if (selected < filtered.len)
        langFromPath(data.items[filtered[selected]].path)
    else
        repl_markdown.CodeLang.plain;
    row_idx = 0;
    while (row_idx < QUICK_OPEN_NARROW_PREVIEW_ROWS) : (row_idx += 1) {
        appendCursorTo(seq, pos, top_row + 12 + row_idx);
        appendLiteral(seq, pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82");
        const used = appendQuickOpenPreviewLineCell(seq, pos, inner, preview_text, row_idx, filter, narrow_lang);
        padCellToWidth(seq, pos, used, inner);
        appendLiteral(seq, pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);
    }
}

fn appendQuickOpenListCell(
    seq: []u8,
    pos: *usize,
    width: usize,
    data: QuickOpenData,
    filtered: []const usize,
    selected: usize,
    row_idx: usize,
    filter: []const u8,
) usize {
    if (width == 0) return 0;

    const left_pad: usize = if (width > 0) 1 else 0;
    if (left_pad > 0) appendLiteral(seq, pos, " ");

    if (filter.len == 0 and row_idx == 0) {
        appendLiteral(seq, pos, CLR_HINT ++ "start typing to search" ++ CLR_RESET);
        return left_pad + 22;
    }

    if (row_idx >= filtered.len) {
        if (filtered.len == 0 and row_idx == 0) {
            appendLiteral(seq, pos, CLR_HINT ++ "no matching files" ++ CLR_RESET);
            return left_pad + 17;
        }
        return left_pad;
    }

    const item = data.items[filtered[row_idx]];
    const is_selected = row_idx == selected;

    if (is_selected) {
        appendLiteral(seq, pos, CLR_SEL_BG ++ CLR_SEL_FG ++ " \xe2\x96\xb6 ");
    } else {
        appendLiteral(seq, pos, CLR_RESET ++ "   ");
    }

    var path_buf: [256]u8 = undefined;
    const name_budget = if (width > 6) width - 6 else 0;
    const clipped = format.truncatePathMiddle(&path_buf, item.path, name_budget);
    if (!is_selected) appendLiteral(seq, pos, CLR_VALUE);
    if (filter.len > 0 and !is_selected) {
        writeHighlightedMatchToBuf(seq, pos, clipped, filter);
    } else {
        appendLiteral(seq, pos, clipped);
    }
    appendLiteral(seq, pos, CLR_RESET);
    return left_pad + 3 + clipped.len;
}

fn appendQuickOpenPreviewWideCell(
    seq: []u8,
    pos: *usize,
    width: usize,
    data: QuickOpenData,
    filtered: []const usize,
    selected: usize,
    row_idx: usize,
    filter: []const u8,
    preview_text: ?[]const u8,
) usize {
    if (width == 0) return 0;

    if (row_idx == 0) {
        return appendQuickOpenPreviewHeader(seq, pos, width, data, filtered, selected);
    }

    const lang = if (selected < filtered.len)
        langFromPath(data.items[filtered[selected]].path)
    else
        repl_markdown.CodeLang.plain;
    return appendQuickOpenPreviewLineCell(seq, pos, width, preview_text, row_idx - 1, filter, lang);
}

fn appendQuickOpenPreviewHeader(
    seq: []u8,
    pos: *usize,
    width: usize,
    data: QuickOpenData,
    filtered: []const usize,
    selected: usize,
) usize {
    if (width == 0) return 0;
    appendLiteral(seq, pos, " ");

    if (filtered.len == 0) {
        appendLiteral(seq, pos, CLR_HINT ++ "preview" ++ CLR_RESET);
        return 8;
    }

    var path_buf: [256]u8 = undefined;
    const path = data.items[filtered[selected]].path;
    const clipped = format.truncatePathMiddle(&path_buf, path, if (width > 1) width - 1 else 0);
    appendLiteral(seq, pos, CLR_LABEL);
    appendLiteral(seq, pos, clipped);
    appendLiteral(seq, pos, CLR_RESET);
    return 1 + clipped.len;
}

fn appendQuickOpenPreviewLineCell(
    seq: []u8,
    pos: *usize,
    width: usize,
    preview_text: ?[]const u8,
    line_idx: usize,
    filter: []const u8,
    lang: repl_markdown.CodeLang,
) usize {
    if (width == 0) return 0;
    appendLiteral(seq, pos, " ");

    const text = preview_text orelse "";
    const line = previewLineAt(text, line_idx);
    if (line.len == 0) {
        if (line_idx == 0 and text.len == 0) {
            appendLiteral(seq, pos, CLR_HINT ++ "type to search files..." ++ CLR_RESET);
            return 24;
        }
        return 1;
    }

    const budget = if (width > 1) width - 1 else 0;
    const clipped = if (line.len > budget) line[0..budget] else line;
    if (filter.len > 0) {
        appendLiteral(seq, pos, CLR_VALUE);
        writeHighlightedMatchToBuf(seq, pos, clipped, filter);
    } else {
        appendHighlightedPreviewLine(seq, pos, clipped, lang);
    }
    appendLiteral(seq, pos, CLR_RESET);
    return 1 + clipped.len;
}

// ── Global search overlay ──

const GLOBAL_SEARCH_WIDE_BODY_ROWS: usize = 8;
const GLOBAL_SEARCH_NARROW_LIST_ROWS: usize = 5;
const GLOBAL_SEARCH_NARROW_PREVIEW_ROWS: usize = 4;

fn globalSearchOverlayRows(cols: usize) usize {
    return if (previewOnRight(.global_search, cols)) 15 else 18;
}

fn emptyGlobalSearchResults(allocator: std.mem.Allocator) !repl_global_search.Results {
    return .{
        .allocator = allocator,
        .items = try allocator.alloc(repl_global_search.Match, 0),
        .truncated = false,
    };
}

pub fn runGlobalSearchOverlayLoop(
    data: GlobalSearchData,
    bottom_margin_rows: usize,
    bindings: ?*const keybindings.RuntimeKeybindings,
) !?GlobalSearchResult {
    const fd = std.Io.File.stdin().handle;
    var filter_buf: [96]u8 = undefined;
    var filter_len: usize = 0;
    var selected: usize = 0;

    var have_last_filter = false;
    var last_filter_buf: [96]u8 = undefined;
    var last_filter_len: usize = 0;

    var results = try emptyGlobalSearchResults(data.allocator);
    defer results.deinit();

    var search_error: ?[]u8 = null;
    defer if (search_error) |msg| data.allocator.free(msg);

    var preview_selected: ?usize = null;
    var preview_text: ?[]u8 = null;
    defer if (preview_text) |text| data.allocator.free(text);
    const contexts = [_]keybindings.BindingContext{.Select};

    while (true) {
        const query_changed = !have_last_filter or
            last_filter_len != filter_len or
            !std.mem.eql(u8, last_filter_buf[0..last_filter_len], filter_buf[0..filter_len]);

        if (query_changed) {
            results.deinit();
            results = try emptyGlobalSearchResults(data.allocator);

            if (search_error) |msg| {
                data.allocator.free(msg);
                search_error = null;
            }
            if (preview_text) |text| {
                data.allocator.free(text);
                preview_text = null;
            }
            preview_selected = null;
            selected = 0;

            if (filter_len > 0) {
                results = repl_global_search.search(
                    data.allocator,
                    data.workspace,
                    filter_buf[0..filter_len],
                    repl_global_search.MAX_TOTAL_MATCHES_DEFAULT,
                ) catch |err| blk: {
                    search_error = try std.fmt.allocPrint(data.allocator, "global search unavailable: {s}", .{@errorName(err)});
                    break :blk try emptyGlobalSearchResults(data.allocator);
                };
            }

            @memcpy(last_filter_buf[0..filter_len], filter_buf[0..filter_len]);
            last_filter_len = filter_len;
            have_last_filter = true;
        }

        if (results.items.len == 0) {
            selected = 0;
            preview_selected = null;
            if (preview_text) |text| {
                data.allocator.free(text);
                preview_text = null;
            }
        } else {
            if (selected >= results.items.len) selected = results.items.len - 1;
            if (preview_selected == null or preview_selected.? != selected) {
                if (preview_text) |text| {
                    data.allocator.free(text);
                    preview_text = null;
                }
                const item = results.items[selected];
                preview_text = repl_global_search.loadPreview(
                    data.allocator,
                    data.workspace,
                    item.path,
                    item.line,
                    repl_global_search.PREVIEW_CONTEXT_LINES,
                ) catch try data.allocator.dupe(u8, "(preview unavailable)");
                preview_selected = selected;
            }
        }

        renderGlobalSearchOverlay(
            results,
            selected,
            filter_buf[0..filter_len],
            search_error,
            preview_text,
            bottom_margin_rows,
        );

        var chord_buf: [24]u8 = undefined;
        const key = readPickerKey(fd, &chord_buf) catch {
            clearGlobalSearchOverlay(bottom_margin_rows);
            return null;
        };
        const ev = resolvePickerBinding(bindings, &contexts, key.chord, key.event);

        switch (ev) {
            .up => selected = if (results.items.len == 0) 0 else if (selected == 0) results.items.len - 1 else selected - 1,
            .down, .next => selected = if (results.items.len == 0) 0 else (selected + 1) % results.items.len,
            .select => {
                clearGlobalSearchOverlay(bottom_margin_rows);
                if (results.items.len == 0) return null;
                const item = results.items[selected];
                return .{
                    .path = try data.allocator.dupe(u8, item.path),
                    .line = item.line,
                    .action = .open_in_editor,
                };
            },
            .tab => {
                clearGlobalSearchOverlay(bottom_margin_rows);
                if (results.items.len == 0) return null;
                const item = results.items[selected];
                return .{
                    .path = try data.allocator.dupe(u8, item.path),
                    .line = item.line,
                    .action = .mention_reference,
                };
            },
            .shift_tab => {
                clearGlobalSearchOverlay(bottom_margin_rows);
                if (results.items.len == 0) return null;
                const item = results.items[selected];
                return .{
                    .path = try data.allocator.dupe(u8, item.path),
                    .line = item.line,
                    .action = .insert_reference,
                };
            },
            .cancel => {
                clearGlobalSearchOverlay(bottom_margin_rows);
                return null;
            },
            .backspace => {
                if (filter_len == 0) {
                    clearGlobalSearchOverlay(bottom_margin_rows);
                    return null;
                }
                filter_len -= 1;
            },
            .char => {
                if (key.char >= 0x20 and key.char < 0x7f and filter_len < filter_buf.len) {
                    filter_buf[filter_len] = key.char;
                    filter_len += 1;
                }
            },
            .toggle, .none => {},
        }
    }
}

fn renderGlobalSearchOverlay(
    results: repl_global_search.Results,
    selected: usize,
    filter: []const u8,
    search_error: ?[]const u8,
    preview_text: ?[]const u8,
    bottom_margin_rows: usize,
) void {
    const rows = terminalRows();
    const cols = terminalCols();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;
    const overlay_rows = globalSearchOverlayRows(cols);
    const bottom_row = if (status_row > 1) status_row - 1 else 1;
    const top_row = if (bottom_row >= overlay_rows) bottom_row - overlay_rows + 1 else 1;
    const wide = previewOnRight(.global_search, cols);

    var box_w: usize = if (wide)
        @min(cols, @as(usize, 118))
    else if (cols < 64)
        cols
    else
        96;
    if (box_w < 4) box_w = 4;
    const inner = box_w - 2;

    var seq: [32768]u8 = undefined;
    var pos: usize = 0;
    appendLiteral(&seq, &pos, "\x1b7");

    appendCursorTo(&seq, &pos, top_row);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x8c");
    appendRepeatStr(&seq, &pos, "\xe2\x94\x80", inner);
    appendLiteral(&seq, &pos, "\xe2\x94\x90" ++ CLR_RESET);

    appendCursorTo(&seq, &pos, top_row + 1);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 " ++ CLR_HEADER ++ "GLOBAL SEARCH");
    appendLiteral(&seq, &pos, CLR_RESET);
    padToWidth(&seq, &pos, 13, inner);
    appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);

    appendCursorTo(&seq, &pos, top_row + 2);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 " ++ CLR_LABEL ++ "scope: " ++ CLR_VALUE ++ "current workspace");
    appendLiteral(&seq, &pos, CLR_RESET);
    padToWidth(&seq, &pos, 24, inner);
    appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);

    appendCursorTo(&seq, &pos, top_row + 3);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 " ++ CLR_SEARCH ++ "search: ");
    if (filter.len > 0) {
        appendLiteral(&seq, &pos, CLR_VALUE);
        const available = if (inner > 12) inner - 12 else 0;
        const clipped_filter = if (filter.len > available) filter[0..available] else filter;
        appendLiteral(&seq, &pos, clipped_filter);
        appendLiteral(&seq, &pos, CLR_DIM ++ "\xe2\x96\x8e");
    } else {
        appendLiteral(&seq, &pos, CLR_HINT ++ "type to search the workspace...");
    }
    appendLiteral(&seq, &pos, CLR_RESET);
    const search_content_len = 8 + if (filter.len > 0) filter.len + 1 else 29;
    padToWidth(&seq, &pos, search_content_len, inner);
    appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);

    if (wide) {
        renderGlobalSearchWideBody(&seq, &pos, top_row, inner, results, selected, filter, search_error, preview_text);
    } else {
        renderGlobalSearchNarrowBody(&seq, &pos, top_row, inner, results, selected, filter, search_error, preview_text);
    }

    const footer_row = if (wide) top_row + 13 else top_row + 16;
    appendCursorTo(&seq, &pos, footer_row);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 " ++ CLR_HINT);
    var count_buf: [160]u8 = undefined;
    const plus = if (results.truncated) "+" else "";
    const count_str = std.fmt.bufPrint(
        &count_buf,
        "{d}{s} matches  \xe2\x86\xb5 open  tab mention  shift+tab path:line  esc cancel",
        .{ results.items.len, plus },
    ) catch "global search";
    appendLiteral(&seq, &pos, count_str);
    appendLiteral(&seq, &pos, CLR_RESET);
    padToWidth(&seq, &pos, count_str.len, inner);
    appendLiteral(&seq, &pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);

    appendCursorTo(&seq, &pos, footer_row + 1);
    appendLiteral(&seq, &pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x94");
    appendRepeatStr(&seq, &pos, "\xe2\x94\x80", inner);
    appendLiteral(&seq, &pos, "\xe2\x94\x98" ++ CLR_RESET);

    appendLiteral(&seq, &pos, "\x1b8");
    _ = std.c.write(std.Io.File.stdout().handle, (seq[0..pos]).ptr, (seq[0..pos]).len);
}

fn renderGlobalSearchWideBody(
    seq: []u8,
    pos: *usize,
    top_row: usize,
    inner: usize,
    results: repl_global_search.Results,
    selected: usize,
    filter: []const u8,
    search_error: ?[]const u8,
    preview_text: ?[]const u8,
) void {
    appendCursorTo(seq, pos, top_row + 4);
    appendLiteral(seq, pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x9c");
    appendRepeatStr(seq, pos, "\xe2\x94\x80", inner);
    appendLiteral(seq, pos, "\xe2\x94\xa4" ++ CLR_RESET);

    var left_w: usize = if (inner > 72) 44 else inner / 2;
    if (left_w < 28) left_w = 28;
    if (left_w + 9 > inner) left_w = inner / 2;
    const right_w = if (inner > left_w + 1) inner - left_w - 1 else 0;

    var start: usize = 0;
    if (results.items.len > GLOBAL_SEARCH_WIDE_BODY_ROWS) {
        const half = GLOBAL_SEARCH_WIDE_BODY_ROWS / 2;
        if (selected > half) start = selected - half;
        if (start + GLOBAL_SEARCH_WIDE_BODY_ROWS > results.items.len) start = results.items.len - GLOBAL_SEARCH_WIDE_BODY_ROWS;
    }

    var row_idx: usize = 0;
    while (row_idx < GLOBAL_SEARCH_WIDE_BODY_ROWS) : (row_idx += 1) {
        appendCursorTo(seq, pos, top_row + 5 + row_idx);
        appendLiteral(seq, pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82");

        const match_idx = start + row_idx;
        const left_used = appendGlobalSearchListCell(seq, pos, left_w, results, selected, match_idx, filter, search_error);
        padCellToWidth(seq, pos, left_used, left_w);

        appendLiteral(seq, pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);
        const right_used = appendGlobalSearchPreviewWideCell(seq, pos, right_w, results, selected, row_idx, filter, preview_text);
        padCellToWidth(seq, pos, right_used, right_w);
        appendLiteral(seq, pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);
    }
}

fn renderGlobalSearchNarrowBody(
    seq: []u8,
    pos: *usize,
    top_row: usize,
    inner: usize,
    results: repl_global_search.Results,
    selected: usize,
    filter: []const u8,
    search_error: ?[]const u8,
    preview_text: ?[]const u8,
) void {
    appendCursorTo(seq, pos, top_row + 4);
    appendLiteral(seq, pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x9c");
    appendRepeatStr(seq, pos, "\xe2\x94\x80", inner);
    appendLiteral(seq, pos, "\xe2\x94\xa4" ++ CLR_RESET);

    var start: usize = 0;
    if (results.items.len > GLOBAL_SEARCH_NARROW_LIST_ROWS) {
        const half = GLOBAL_SEARCH_NARROW_LIST_ROWS / 2;
        if (selected > half) start = selected - half;
        if (start + GLOBAL_SEARCH_NARROW_LIST_ROWS > results.items.len) start = results.items.len - GLOBAL_SEARCH_NARROW_LIST_ROWS;
    }

    var row_idx: usize = 0;
    while (row_idx < GLOBAL_SEARCH_NARROW_LIST_ROWS) : (row_idx += 1) {
        appendCursorTo(seq, pos, top_row + 5 + row_idx);
        appendLiteral(seq, pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82");
        const match_idx = start + row_idx;
        const used = appendGlobalSearchListCell(seq, pos, inner, results, selected, match_idx, filter, search_error);
        padCellToWidth(seq, pos, used, inner);
        appendLiteral(seq, pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);
    }

    appendCursorTo(seq, pos, top_row + 10);
    appendLiteral(seq, pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x9c");
    appendRepeatStr(seq, pos, "\xe2\x94\x80", inner);
    appendLiteral(seq, pos, "\xe2\x94\xa4" ++ CLR_RESET);

    appendCursorTo(seq, pos, top_row + 11);
    appendLiteral(seq, pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82");
    const header_used = appendGlobalSearchPreviewHeader(seq, pos, inner, results, selected);
    padCellToWidth(seq, pos, header_used, inner);
    appendLiteral(seq, pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);

    const narrow_lang = if (selected < results.items.len)
        langFromPath(results.items[selected].path)
    else
        repl_markdown.CodeLang.plain;
    row_idx = 0;
    while (row_idx < GLOBAL_SEARCH_NARROW_PREVIEW_ROWS) : (row_idx += 1) {
        appendCursorTo(seq, pos, top_row + 12 + row_idx);
        appendLiteral(seq, pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82");
        const used = appendGlobalSearchPreviewLineCell(seq, pos, inner, preview_text, row_idx, filter, narrow_lang);
        padCellToWidth(seq, pos, used, inner);
        appendLiteral(seq, pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);
    }
}

fn appendGlobalSearchListCell(
    seq: []u8,
    pos: *usize,
    width: usize,
    results: repl_global_search.Results,
    selected: usize,
    row_idx: usize,
    filter: []const u8,
    search_error: ?[]const u8,
) usize {
    if (width == 0) return 0;

    const left_pad: usize = 1;
    appendLiteral(seq, pos, " ");

    if (filter.len == 0 and row_idx == 0) {
        appendLiteral(seq, pos, CLR_HINT ++ "type to search the workspace" ++ CLR_RESET);
        return left_pad + 28;
    }

    if (row_idx >= results.items.len) {
        if (results.items.len == 0 and row_idx == 0) {
            if (search_error) |msg| {
                appendLiteral(seq, pos, CLR_ACTIVE);
                const budget = if (width > left_pad) width - left_pad else 0;
                const clipped = if (msg.len > budget) msg[0..budget] else msg;
                appendLiteral(seq, pos, clipped);
                appendLiteral(seq, pos, CLR_RESET);
                return left_pad + clipped.len;
            }
            appendLiteral(seq, pos, CLR_HINT ++ "no matches" ++ CLR_RESET);
            return left_pad + 10;
        }
        return left_pad;
    }

    const item = results.items[row_idx];
    const is_selected = row_idx == selected;

    if (is_selected) {
        appendLiteral(seq, pos, CLR_SEL_BG ++ CLR_SEL_FG ++ " \xe2\x96\xb6 ");
    } else {
        appendLiteral(seq, pos, CLR_RESET ++ "   ");
    }

    var location_buf: [320]u8 = undefined;
    const location = std.fmt.bufPrint(&location_buf, "{s}:{d}", .{ item.path, item.line }) catch item.path;
    var path_buf: [256]u8 = undefined;
    const location_budget = if (width > 20) @max(@as(usize, 16), width / 2) else if (width > 8) width - 8 else 0;
    const clipped_location = format.truncatePathMiddle(&path_buf, location, location_budget);
    const snippet_budget = if (width > 7 + clipped_location.len) width - 7 - clipped_location.len else 0;
    const clipped_text = if (item.text.len > snippet_budget) item.text[0..snippet_budget] else item.text;

    if (is_selected) {
        appendLiteral(seq, pos, clipped_location);
        if (clipped_text.len > 0) {
            appendLiteral(seq, pos, "  ");
            appendLiteral(seq, pos, clipped_text);
        }
    } else {
        appendLiteral(seq, pos, CLR_VALUE);
        if (filter.len > 0) {
            writeHighlightedMatchToBuf(seq, pos, clipped_location, filter);
        } else {
            appendLiteral(seq, pos, clipped_location);
        }
        if (clipped_text.len > 0) {
            appendLiteral(seq, pos, CLR_RESET ++ "  " ++ CLR_CTX);
            if (filter.len > 0) {
                writeHighlightedMatchToBuf(seq, pos, clipped_text, filter);
            } else {
                appendLiteral(seq, pos, clipped_text);
            }
        }
    }

    appendLiteral(seq, pos, CLR_RESET);
    return left_pad + 3 + clipped_location.len + if (clipped_text.len > 0) @as(usize, 2 + clipped_text.len) else 0;
}

fn appendGlobalSearchPreviewWideCell(
    seq: []u8,
    pos: *usize,
    width: usize,
    results: repl_global_search.Results,
    selected: usize,
    row_idx: usize,
    filter: []const u8,
    preview_text: ?[]const u8,
) usize {
    if (width == 0) return 0;
    if (row_idx == 0) return appendGlobalSearchPreviewHeader(seq, pos, width, results, selected);
    const lang = if (selected < results.items.len)
        langFromPath(results.items[selected].path)
    else
        repl_markdown.CodeLang.plain;
    return appendGlobalSearchPreviewLineCell(seq, pos, width, preview_text, row_idx - 1, filter, lang);
}

fn appendGlobalSearchPreviewHeader(
    seq: []u8,
    pos: *usize,
    width: usize,
    results: repl_global_search.Results,
    selected: usize,
) usize {
    if (width == 0) return 0;
    appendLiteral(seq, pos, " ");

    if (results.items.len == 0) {
        appendLiteral(seq, pos, CLR_HINT ++ "preview" ++ CLR_RESET);
        return 8;
    }

    const item = results.items[selected];
    var location_buf: [320]u8 = undefined;
    const location = std.fmt.bufPrint(&location_buf, "{s}:{d}", .{ item.path, item.line }) catch item.path;
    var path_buf: [256]u8 = undefined;
    const clipped = format.truncatePathMiddle(&path_buf, location, if (width > 1) width - 1 else 0);
    appendLiteral(seq, pos, CLR_LABEL);
    appendLiteral(seq, pos, clipped);
    appendLiteral(seq, pos, CLR_RESET);
    return 1 + clipped.len;
}

fn appendGlobalSearchPreviewLineCell(
    seq: []u8,
    pos: *usize,
    width: usize,
    preview_text: ?[]const u8,
    line_idx: usize,
    filter: []const u8,
    lang: repl_markdown.CodeLang,
) usize {
    if (width == 0) return 0;
    appendLiteral(seq, pos, " ");

    const text = preview_text orelse "";
    const line = previewLineAt(text, line_idx);
    if (line.len == 0) {
        if (line_idx == 0 and text.len == 0) {
            appendLiteral(seq, pos, CLR_HINT ++ "select a match to preview" ++ CLR_RESET);
            return 27;
        }
        return 1;
    }

    const budget = if (width > 1) width - 1 else 0;
    const clipped = if (line.len > budget) line[0..budget] else line;
    if (filter.len > 0) {
        appendLiteral(seq, pos, CLR_VALUE);
        writeHighlightedMatchToBuf(seq, pos, clipped, filter);
    } else {
        appendHighlightedPreviewLine(seq, pos, clipped, lang);
    }
    appendLiteral(seq, pos, CLR_RESET);
    return 1 + clipped.len;
}

fn clearGlobalSearchOverlay(bottom_margin_rows: usize) void {
    const rows = terminalRows();
    const cols = terminalCols();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;

    const overlay_rows = globalSearchOverlayRows(cols);
    const bottom_row = if (status_row > 1) status_row - 1 else 1;
    const top_row = if (bottom_row >= overlay_rows) bottom_row - overlay_rows + 1 else 1;

    var seq: [4096]u8 = undefined;
    var pos: usize = 0;
    appendLiteral(&seq, &pos, "\x1b7");
    var i: usize = 0;
    while (i < overlay_rows) : (i += 1) {
        appendCursorTo(&seq, &pos, top_row + i);
        appendLiteral(&seq, &pos, "\x1b[2K");
    }
    appendLiteral(&seq, &pos, "\x1b8");
    _ = std.c.write(std.Io.File.stdout().handle, (seq[0..pos]).ptr, (seq[0..pos]).len);
}

fn previewLineAt(text: []const u8, wanted: usize) []const u8 {
    var current: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i == text.len or text[i] == '\n') {
            if (current == wanted) return std.mem.trimEnd(u8, text[start..i], "\r");
            current += 1;
            start = i + 1;
        }
    }
    return "";
}

fn padCellToWidth(buf: []u8, pos: *usize, content_len: usize, width: usize) void {
    if (content_len < width) appendRepeatByte(buf, pos, " ", width - content_len);
}

fn clearQuickOpenOverlay(bottom_margin_rows: usize) void {
    const rows = terminalRows();
    const cols = terminalCols();
    const margin = boundedBottomMarginRows(rows, bottom_margin_rows);
    const status_row = if (rows > margin) rows - margin else 1;

    const overlay_rows = quickOpenOverlayRows(cols);
    const bottom_row = if (status_row > 1) status_row - 1 else 1;
    const top_row = if (bottom_row >= overlay_rows) bottom_row - overlay_rows + 1 else 1;

    var seq: [4096]u8 = undefined;
    var pos: usize = 0;
    appendLiteral(&seq, &pos, "\x1b7");
    var i: usize = 0;
    while (i < overlay_rows) : (i += 1) {
        appendCursorTo(&seq, &pos, top_row + i);
        appendLiteral(&seq, &pos, "\x1b[2K");
    }
    appendLiteral(&seq, &pos, "\x1b8");
    _ = std.c.write(std.Io.File.stdout().handle, (seq[0..pos]).ptr, (seq[0..pos]).len);
}
fn appendSimpleOverlayBorder(buf: []u8, pos: *usize, row: usize, inner: usize) void {
    appendCursorTo(buf, pos, row);
    appendLiteral(buf, pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x8c");
    appendRepeatStr(buf, pos, "\xe2\x94\x80", inner);
    appendLiteral(buf, pos, "\xe2\x94\x90" ++ CLR_RESET);
}

fn appendSimpleOverlayDivider(buf: []u8, pos: *usize, row: usize, inner: usize) void {
    appendCursorTo(buf, pos, row);
    appendLiteral(buf, pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x9c");
    appendRepeatStr(buf, pos, "\xe2\x94\x80", inner);
    appendLiteral(buf, pos, "\xe2\x94\xa4" ++ CLR_RESET);
}

fn appendSimpleOverlayBottomBorder(buf: []u8, pos: *usize, row: usize, inner: usize) void {
    appendCursorTo(buf, pos, row);
    appendLiteral(buf, pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x94");
    appendRepeatStr(buf, pos, "\xe2\x94\x80", inner);
    appendLiteral(buf, pos, "\xe2\x94\x98" ++ CLR_RESET);
}

fn appendSimpleOverlayLine(buf: []u8, pos: *usize, row: usize, inner: usize, content: []const u8) void {
    appendCursorTo(buf, pos, row);
    appendLiteral(buf, pos, "\x1b[2K" ++ CLR_BORDER ++ "\xe2\x94\x82 " ++ CLR_RESET);

    const inner_content = if (inner > 2) inner - 2 else 0;
    const clipped = if (content.len > inner_content) content[0..inner_content] else content;
    appendLiteral(buf, pos, CLR_VALUE);
    appendLiteral(buf, pos, clipped);
    appendLiteral(buf, pos, CLR_RESET);
    if (inner_content > clipped.len) appendRepeatByte(buf, pos, " ", inner_content - clipped.len);

    appendLiteral(buf, pos, CLR_BORDER ++ "\xe2\x94\x82" ++ CLR_RESET);
}

// ── Plan action helpers ──

pub fn parsePlanAction(text: []const u8) ?PlanAction {
    if (std.mem.eql(u8, text, "approve")) return .approve;
    if (std.mem.eql(u8, text, "discuss")) return .discuss;
    if (std.mem.eql(u8, text, "continue")) return .discuss;
    if (std.mem.eql(u8, text, "cancel")) return .cancel;
    return null;
}

// ── Tests ──

const testing = std.testing;

test "applyModeCycles equals getNext applied N times" {
    // P3 (PRD #534): N Shift+Tab presses inside the approval overlay must land
    // on the same mode as getNext composed N times.
    // Normal cycle (bypass unavailable): default -> acceptEdits -> plan -> default
    try testing.expectEqual(permission_decision.Mode.default, applyModeCycles(.default, 0, false));
    try testing.expectEqual(permission_decision.Mode.acceptEdits, applyModeCycles(.default, 1, false));
    try testing.expectEqual(permission_decision.Mode.plan, applyModeCycles(.default, 2, false));
    try testing.expectEqual(permission_decision.Mode.default, applyModeCycles(.default, 3, false));
    try testing.expectEqual(permission_decision.Mode.acceptEdits, applyModeCycles(.default, 4, false));

    // With bypass available the cycle gains a step:
    // default -> acceptEdits -> plan -> bypassPermissions -> default
    try testing.expectEqual(permission_decision.Mode.bypassPermissions, applyModeCycles(.default, 3, true));
    try testing.expectEqual(permission_decision.Mode.default, applyModeCycles(.default, 4, true));

    // Cross-check against an explicit composition of getNext.
    var expected = permission_decision.Mode.acceptEdits;
    var i: usize = 0;
    while (i < 7) : (i += 1) {
        expected = permission_mode_cycle.getNext(expected, false);
    }
    try testing.expectEqual(expected, applyModeCycles(.acceptEdits, 7, false));
}

test "buildApprovalOptionsLine highlights selected choice" {
    var out: [512]u8 = undefined;
    // selected index 1 = "Always" (inverse-video outline background)
    const line = buildApprovalOptionsLine(&out, 1);
    try testing.expect(std.mem.indexOf(u8, line, "Deny") != null);
    // Always label is present and rendered with the outline accent
    // escape (C8D2DC). Approve (idx 0) is unselected so it should
    // carry the dim escape (\x1b[2m) rather than the mint fill.
    try testing.expect(std.mem.indexOf(u8, line, "Always") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\x1b[38;2;200;210;220m") != null);
}

test "buildApprovalOptionsLine marks approve as primary when selected" {
    var out: [512]u8 = undefined;
    const line = buildApprovalOptionsLine(&out, 0);
    // Approve at index 0 should carry the brand-accent mint background.
    try testing.expect(std.mem.indexOf(u8, line, "Approve") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\x1b[48;2;95;212;160m") != null);
    // Deny at index 2 is unselected, so no red fill should be present.
    try testing.expect(std.mem.indexOf(u8, line, "\x1b[48;2;217;95;114m") == null);
}

test "plan review overlay functions exist" {
    try testing.expect(@TypeOf(clearPlanReviewOverlay) == @TypeOf(clearPlanReviewOverlay));
    try testing.expect(@TypeOf(renderPlanReviewOverlay) == @TypeOf(renderPlanReviewOverlay));
}

test "parseModelPickerData parses active model and items" {
    const payload =
        \\active_provider=openai-compatible
        \\active_model=kimi-k2.5
        \\item=gpt-4.1 128000
        \\item=gpt-4.1-mini 128000
    ;

    var parsed = try parseModelPickerData(testing.allocator, payload);
    defer parsed.deinit();

    try testing.expectEqualStrings("openai-compatible", parsed.active_provider);
    try testing.expectEqualStrings("kimi-k2.5", parsed.active_model);
    try testing.expectEqual(@as(usize, 2), parsed.items.len);
    try testing.expectEqualStrings("gpt-4.1", parsed.items[0].id);
    try testing.expectEqual(@as(usize, 128000), parsed.items[0].ctx);
}

test "initialModelPickerSelection returns active index when present" {
    const payload =
        \\active_provider=openai-compatible
        \\active_model=gpt-4.1-mini
        \\item=gpt-4.1 128000
        \\item=gpt-4.1-mini 128000
    ;

    var parsed = try parseModelPickerData(testing.allocator, payload);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 1), initialModelPickerSelection(parsed));
}

test "parseBackgroundTasksData parses task overlay payload" {
    const payload =
        \\{
        \\  "initial_selection": 1,
        \\  "items": [
        \\    {
        \\      "id": "task-1",
        \\      "title": "run tests",
        \\      "status": "running",
        \\      "summary": "integration tests",
        \\      "command": "zig build test",
        \\      "owner": "shell",
        \\      "priority": "high",
        \\      "detail": "task started",
        \\      "progress": 25,
        \\      "run_pid": 123,
        \\      "updated_ts": 999
        \\    },
        \\    {
        \\      "id": "task-2",
        \\      "title": "lint",
        \\      "status": "done",
        \\      "summary": "",
        \\      "command": "zig fmt",
        \\      "owner": "agent",
        \\      "priority": "normal",
        \\      "detail": "task done",
        \\      "progress": 100,
        \\      "run_pid": 0,
        \\      "updated_ts": 1000
        \\    }
        \\  ]
        \\}
    ;

    var parsed = try parseBackgroundTasksData(testing.allocator, payload);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 2), parsed.items.len);
    try testing.expectEqual(@as(usize, 1), parsed.initial_selection);
    try testing.expectEqualStrings("task-1", parsed.items[0].id);
    try testing.expectEqualStrings("running", parsed.items[0].status);
    try testing.expectEqualStrings("shell", parsed.items[0].owner);
    try testing.expectEqualStrings("high", parsed.items[0].priority);
    try testing.expectEqual(@as(u8, 25), parsed.items[0].progress);
    try testing.expectEqual(@as(i64, 123), parsed.items[0].run_pid);
}

test "parseSessionSwitcherData parses items and clamps initial selection" {
    const payload =
        \\{
        \\  "initial_selection": 99,
        \\  "items": [
        \\    {
        \\      "id": "session-current",
        \\      "label": "Current workspace",
        \\      "updated_summary": "just now",
        \\      "is_current": true
        \\    },
        \\    {
        \\      "id": "session-old",
        \\      "label": "Earlier run",
        \\      "updated_summary": "2h ago",
        \\      "is_current": false
        \\    }
        \\  ]
        \\}
    ;

    var parsed = try parseSessionSwitcherData(testing.allocator, payload);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 2), parsed.items.len);
    try testing.expectEqualStrings("session-current", parsed.items[0].id);
    try testing.expectEqualStrings("Current workspace", parsed.items[0].label);
    try testing.expectEqualStrings("just now", parsed.items[0].updated_summary);
    try testing.expect(parsed.items[0].is_current);
    try testing.expectEqual(@as(usize, 1), parsed.initial_selection);
}

test "bestSessionFuzzyScore ranks parser sessions ahead of unrelated ones" {
    const parser_a = SessionSwitcherItem{
        .id = @constCast("s1"),
        .label = @constCast("refactor parser internals"),
        .updated_summary = @constCast("1h ago"),
        .is_current = false,
    };
    const parser_b = SessionSwitcherItem{
        .id = @constCast("s3"),
        .label = @constCast("parser cleanup"),
        .updated_summary = @constCast("2h ago"),
        .is_current = false,
    };
    const login = SessionSwitcherItem{
        .id = @constCast("s2"),
        .label = @constCast("fix login bug"),
        .updated_summary = @constCast("3h ago"),
        .is_current = false,
    };

    const score_a = bestSessionFuzzyScore(parser_a, "parser");
    const score_b = bestSessionFuzzyScore(parser_b, "parser");
    const score_login = bestSessionFuzzyScore(login, "parser");

    try testing.expect(score_a != null);
    try testing.expect(score_b != null);
    // The login session has no "parser" subsequence and should not match.
    try testing.expect(score_login == null);
    // The parser sessions outscore any substring-only fallback (score 1).
    try testing.expect(score_a.? > 1);
    try testing.expect(score_b.? > 1);
}

test "parsePlanAction recognizes supported aliases" {
    try testing.expect(parsePlanAction("approve").? == .approve);
    try testing.expect(parsePlanAction("discuss").? == .discuss);
    try testing.expect(parsePlanAction("continue").? == .discuss);
    try testing.expect(parsePlanAction("cancel").? == .cancel);
    try testing.expect(parsePlanAction("unknown") == null);
}

test "buildAskUserOptionsLine highlights selected choice" {
    var out: [512]u8 = undefined;
    const choices = [_][]const u8{ "Approve", "Discuss", "Cancel" };
    const line = buildAskUserOptionsLine(out[0..], choices[0..], 1);
    try testing.expect(std.mem.indexOf(u8, line, "Discuss") != null);
    try testing.expect(std.mem.indexOf(u8, line, "navigate") != null);
}

test "previewSideThreshold matches the per-picker reference values" {
    try testing.expectEqual(@as(usize, 120), previewSideThreshold(.quick_open));
    try testing.expectEqual(@as(usize, 140), previewSideThreshold(.global_search));
    try testing.expectEqual(@as(usize, 100), previewSideThreshold(.history));
}

test "previewOnRight flips at the QuickOpen 120 / GlobalSearch 140 / History 100 thresholds" {
    // Quick open: side at >= 120, bottom below.
    try testing.expect(!previewOnRight(.quick_open, 119));
    try testing.expect(previewOnRight(.quick_open, 120));
    try testing.expect(previewOnRight(.quick_open, 130));

    // Global search: side only at >= 140 (the 120 -> 140 fix). At 130 it
    // must now be bottom, where it used to be on the right.
    try testing.expect(!previewOnRight(.global_search, 130));
    try testing.expect(!previewOnRight(.global_search, 139));
    try testing.expect(previewOnRight(.global_search, 140));
    try testing.expect(previewOnRight(.global_search, 150));

    // History: side at >= 100.
    try testing.expect(!previewOnRight(.history, 99));
    try testing.expect(previewOnRight(.history, 100));
}

test "langFromPath maps extensions and ignores dotless or directory dots" {
    try testing.expect(langFromPath("src/main.zig") == .zig);
    try testing.expect(langFromPath("pkg/server.go") == .go);
    try testing.expect(langFromPath("app/index.ts") == .typescript);
    try testing.expect(langFromPath("app/index.js") == .javascript);
    // "json" must resolve to .json, not .javascript (the prefix-match
    // trap in parseCodeLang that langFromPath deliberately avoids).
    try testing.expect(langFromPath("config.json") == .json);
    try testing.expect(langFromPath("scripts/build.sh") == .bash);
    try testing.expect(langFromPath("tool.py") == .python);
    try testing.expect(langFromPath("ci.yaml") == .yaml);
    try testing.expect(langFromPath("ci.yml") == .yaml);
    try testing.expect(langFromPath("build.zig.zon") == .plain); // .zon is not a known lang
    try testing.expect(langFromPath("Makefile") == .plain); // no extension
    try testing.expect(langFromPath("some.dir/Dockerfile") == .plain); // dot is in the directory
}

test "appendHighlightedPreviewLine preserves content and passes plain through verbatim" {
    var buf: [256]u8 = undefined;

    // Plain language is copied verbatim with no transformation.
    var pos_plain: usize = 0;
    appendHighlightedPreviewLine(&buf, &pos_plain, "pub fn main() void {}", .plain);
    try testing.expectEqualStrings("pub fn main() void {}", buf[0..pos_plain]);

    // A highlighted language never drops the source identifiers. (Whether
    // SGR escapes are emitted depends on shouldUseColor / isatty, which is
    // false under the headless test runner, so the actual colouring is a
    // manual check; here we only assert content preservation.)
    var pos_zig: usize = 0;
    appendHighlightedPreviewLine(&buf, &pos_zig, "pub fn greet() void {}", .zig);
    try testing.expect(std.mem.indexOf(u8, buf[0..pos_zig], "greet") != null);
}
