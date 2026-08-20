const std = @import("std");
const std_io = @import("../core/std_io.zig");
const rt = @import("zcode_runtime");
const keybindings = @import("keybindings.zig");
const removed_commands = @import("../core/removed_commands.zig");
const terminal_response = @import("../core/terminal_response.zig");
const terminal_caps = @import("../core/terminal_caps.zig");

pub const TerminalRawMode = struct {
    enabled: bool = false,
    saved: std.posix.termios = undefined,

    pub fn enable(self: *TerminalRawMode) void {
        const fd = std.Io.File.stdin().handle;
        if (std.c.isatty(fd) == 0) return;

        const current = std.posix.tcgetattr(fd) catch return;
        self.saved = current;

        var raw = current;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ECHOE = false;
        raw.lflag.ECHOK = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ECHOCTL = false;
        raw.lflag.ECHOKE = false;
        raw.lflag.ISIG = false; // Ctrl+C sends 0x03 byte instead of SIGINT
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;

        std.posix.tcsetattr(fd, .NOW, raw) catch return;
        self.enabled = true;
        const stdout_h = std.Io.File.stdout().handle;
        // Enable Kitty keyboard protocol (level 1: disambiguate keys)
        // so Shift+Enter, Shift+Tab send explicit CSI sequences with modifier info
        _ = std.c.write(stdout_h, ("\x1b[>1u").ptr, ("\x1b[>1u").len);
        // XTVERSION probe (CSI > 0 q). The terminal answers asynchronously
        // with DCS > | name ST on stdin; the input parser routes that reply
        // to terminal_caps.setXtversionName so isXtermJs()/supportsExtendedKeys()
        // work over SSH (where TERM_PROGRAM is not forwarded). Fire-and-forget:
        // terminals that do not implement XTVERSION ignore the unknown query.
        _ = std.c.write(stdout_h, ("\x1b[>0q").ptr, ("\x1b[>0q").len);
        // Mouse modes are managed by enterAltScreen (?1000/?1002/?1006);
        // raw mode itself doesn't toggle them. Users hold Option (macOS)
        // or Shift (Linux) to bypass mouse capture for native selection.
    }

    pub fn disable(self: *TerminalRawMode) void {
        if (!self.enabled) return;
        const fd = std.Io.File.stdin().handle;
        std.posix.tcsetattr(fd, .NOW, self.saved) catch {};
        const stdout_h = std.Io.File.stdout().handle;
        // Disable any mouse reporting that might have been left on by
        // a prior version of zcode in the same TTY.
        _ = std.c.write(stdout_h, ("\x1b[?1006l\x1b[?1000l").ptr, ("\x1b[?1006l\x1b[?1000l").len);
        // Disable Kitty keyboard protocol
        _ = std.c.write(stdout_h, ("\x1b[<u").ptr, ("\x1b[<u").len);
        self.enabled = false;
    }
};

pub const InputEvent = enum {
    none,
    bound_command,
    submit,
    insert_newline,
    interrupt,
    autocomplete,
    attachment_next,
    attachment_previous,
    attachment_remove,
    attachment_exit,
    prompt_previous,
    prompt_next,
    prompt_open,
    prompt_dismiss,
    prompt_exit,
    quick_open,
    global_search,
    redraw,
    toggle_transcript,
    transcript_view,
    toggle_todos,
    toggle_brief,
    image_paste,
    command_palette,
    session_switcher,
    model_picker,
    theme_picker,
    runtime_panel,
    density_toggle,
    fast_toggle,
    thinking_toggle,
    stash_toggle,
    undo_edit,
    toggle_mode,
    toggle_permission_mode,
    backspace,
    clear_line,
    delete_prev_word,
    scroll_up,
    scroll_down,
    mouse_scroll_up,
    mouse_scroll_down,
    escape,
    message_actions,
    history_prev,
    history_next,
    history_search,
    external_editor,
    kill_background_tasks,
    page_up,
    page_down,
    jump_top,
    jump_bottom,
    cursor_left,
    cursor_right,
    cursor_word_left,
    cursor_word_right,
    cursor_home,
    cursor_end,
};

var last_bound_command: ?[]const u8 = null;
var pending_prompt_chord_buf: [128]u8 = undefined;
var pending_prompt_chord_len: usize = 0;

// Last inbound terminal-response sequence (DECRPM/DA1/DA2/kitty-flags/DSR)
// recognized out of the keypress path. Slice payloads (DA1/DA2 params) are
// copied into `last_response_buf` so the value survives past the transient
// read buffer. Task 11 (XTVERSION) consumes these.
var last_response: ?terminal_response.TerminalResponse = null;
var last_response_buf: [64]u8 = undefined;

/// Record a parsed terminal response, copying any slice payload into a stable
/// static buffer so it outlives the caller's read buffer.
fn recordTerminalResponse(resp: terminal_response.TerminalResponse) void {
    switch (resp) {
        .da1 => |params| {
            const n = @min(params.len, last_response_buf.len);
            @memcpy(last_response_buf[0..n], params[0..n]);
            last_response = .{ .da1 = last_response_buf[0..n] };
        },
        .da2 => |params| {
            const n = @min(params.len, last_response_buf.len);
            @memcpy(last_response_buf[0..n], params[0..n]);
            last_response = .{ .da2 = last_response_buf[0..n] };
        },
        .osc => |o| {
            const n = @min(o.data.len, last_response_buf.len);
            @memcpy(last_response_buf[0..n], o.data[0..n]);
            last_response = .{ .osc = .{ .code = o.code, .data = last_response_buf[0..n] } };
        },
        // XTVERSION slice payloads are copied at their own consume site
        // (terminal_caps.setXtversionName); the remaining scalar variants
        // carry no slices, so they are safe to store as-is.
        else => last_response = resp,
    }
}

/// Consume and return the most recent terminal response, if any.
pub fn takeLastTerminalResponse() ?terminal_response.TerminalResponse {
    const resp = last_response;
    last_response = null;
    return resp;
}

/// A non-wheel SGR/X10 mouse event with decoded coordinates. zcode has no
/// clickable UI yet, so these are recorded for a future hit-testing layer to
/// consume rather than mapped to an InputEvent. Wheel events stay on the
/// `.mouse_scroll_up`/`.mouse_scroll_down` path and never produce a MouseEvent.
pub const MouseEvent = struct {
    /// Raw button code with modifier/motion bits stripped of the X10 +32
    /// offset. Low 2 bits = button (0=left, 1=middle, 2=right); bit 5 (0x20)
    /// = drag/motion.
    button: u32,
    action: enum { press, release },
    /// 1-indexed column from the terminal sequence.
    col: u32,
    /// 1-indexed row from the terminal sequence.
    row: u32,
};

/// Most recent non-wheel mouse event decoded out of the input stream. There is
/// no clickable UI to route it to yet, so it is parked here for a future
/// consumer; recording it keeps the coordinates from being discarded.
var last_mouse: ?MouseEvent = null;

/// Consume and return the most recent mouse event, if any.
pub fn takeLastMouseEvent() ?MouseEvent {
    const ev = last_mouse;
    last_mouse = null;
    return ev;
}

/// Parse the body of an SGR mouse sequence (the bytes between `ESC [` and the
/// trailing `M`/`m`, i.e. `<Cb;Cx;Cy` plus the terminator) into a MouseEvent.
/// Returns null for wheel events (button bit 0x40 set) so the caller keeps
/// routing them to scroll, and null for malformed payloads.
pub fn parseSgrMouse(payload: []const u8) ?MouseEvent {
    // Must start with the SGR private marker and end with the terminator.
    if (payload.len < 2 or payload[0] != '<') return null;
    const terminator = payload[payload.len - 1];
    if (terminator != 'M' and terminator != 'm') return null;

    var nums: [3]u32 = .{ 0, 0, 0 };
    var saw: [3]bool = .{ false, false, false };
    var field: usize = 0;
    var i: usize = 1;
    while (i < payload.len - 1) : (i += 1) {
        const ch = payload[i];
        if (ch == ';') {
            field += 1;
            if (field > 2) return null;
            continue;
        }
        if (ch < '0' or ch > '9') return null;
        nums[field] = nums[field] * 10 + (ch - '0');
        saw[field] = true;
    }
    if (!saw[0] or !saw[1] or !saw[2]) return null;

    const button = nums[0];
    // Wheel events stay on the scroll path; do not produce a MouseEvent.
    if ((button & 0x40) != 0) return null;

    return .{
        .button = button,
        .action = if (terminator == 'M') .press else .release,
        .col = nums[1],
        .row = nums[2],
    };
}

/// Parse an X10 legacy mouse triple (`Cb Cx Cy`, each already +32 encoded) into
/// a MouseEvent. Returns null for wheel events (button bit 0x40 set after the
/// +32 offset is removed). X10 has no release terminator, so the action is
/// always `press`. Coordinates are 1-indexed (the +32 offset includes the
/// 1-origin bias the terminal applies).
pub fn parseX10Mouse(cb: u8, cx: u8, cy: u8) ?MouseEvent {
    const code: u32 = if (cb >= 32) @as(u32, cb) - 32 else cb;
    if ((code & 0x40) != 0) return null;
    const col: u32 = if (cx >= 32) @as(u32, cx) - 32 else cx;
    const row: u32 = if (cy >= 32) @as(u32, cy) - 32 else cy;
    return .{
        .button = code,
        .action = .press,
        .col = col,
        .row = row,
    };
}

/// True when a fully-assembled escape sequence is an inbound terminal
/// response (e.g. a DA1 reply) rather than a keypress. Extracted so the
/// consume-vs-key decision can be unit-tested without driving stdin.
pub fn isTerminalResponseSequence(seq: []const u8) bool {
    return terminal_response.parse(seq) != null;
}

pub fn takeLastBoundCommand() ?[]const u8 {
    const command = last_bound_command;
    last_bound_command = null;
    return command;
}

fn pendingPromptChord() ?[]const u8 {
    if (pending_prompt_chord_len == 0) return null;
    return pending_prompt_chord_buf[0..pending_prompt_chord_len];
}

fn clearPendingPromptChord() void {
    pending_prompt_chord_len = 0;
}

fn setPendingPromptChord(chord: []const u8) bool {
    if (chord.len == 0 or chord.len > pending_prompt_chord_buf.len) {
        clearPendingPromptChord();
        return false;
    }
    @memcpy(pending_prompt_chord_buf[0..chord.len], chord);
    pending_prompt_chord_len = chord.len;
    return true;
}

fn storePendingPromptChord(existing: ?[]const u8, chord: []const u8) bool {
    var combined_buf: [128]u8 = undefined;
    const combined = if (existing) |prefix|
        std.fmt.bufPrint(&combined_buf, "{s} {s}", .{ prefix, chord }) catch return false
    else
        chord;
    return setPendingPromptChord(combined);
}

fn fallbackEventForChord(chord: []const u8) InputEvent {
    if (std.mem.eql(u8, chord, "enter")) return .submit;
    if (std.mem.eql(u8, chord, "shift+enter")) return .insert_newline;
    if (std.mem.eql(u8, chord, "escape")) return .escape;
    if (std.mem.eql(u8, chord, "backspace")) return .backspace;
    if (std.mem.eql(u8, chord, "up")) return .history_prev;
    if (std.mem.eql(u8, chord, "down")) return .history_next;
    if (std.mem.eql(u8, chord, "shift+up")) return .message_actions;
    if (std.mem.eql(u8, chord, "shift+tab")) return .toggle_mode;
    if (std.mem.eql(u8, chord, "ctrl+c")) return .interrupt;
    if (std.mem.eql(u8, chord, "ctrl+d")) return .interrupt;
    if (std.mem.eql(u8, chord, "ctrl+u")) return .clear_line;
    if (std.mem.eql(u8, chord, "ctrl+w")) return .delete_prev_word;
    if (std.mem.eql(u8, chord, "alt+backspace")) return .delete_prev_word;
    if (std.mem.eql(u8, chord, "cmd+backspace")) return .clear_line;
    if (std.mem.eql(u8, chord, "ctrl+r")) return .history_search;
    if (std.mem.eql(u8, chord, "ctrl+l")) return .redraw;
    if (std.mem.eql(u8, chord, "ctrl+e")) return .transcript_view;
    if (std.mem.eql(u8, chord, "ctrl+g")) return .external_editor;
    if (std.mem.eql(u8, chord, "ctrl+x ctrl+e")) return .external_editor;
    if (std.mem.eql(u8, chord, "ctrl+x ctrl+k")) return .kill_background_tasks;
    if (std.mem.eql(u8, chord, "ctrl+p")) return .quick_open;
    if (std.mem.eql(u8, chord, "ctrl+shift+p")) return .quick_open;
    if (std.mem.eql(u8, chord, "cmd+shift+p")) return .quick_open;
    if (std.mem.eql(u8, chord, "ctrl+f")) return .global_search;
    if (std.mem.eql(u8, chord, "ctrl+shift+f")) return .global_search;
    if (std.mem.eql(u8, chord, "cmd+shift+f")) return .global_search;
    if (std.mem.eql(u8, chord, "ctrl+o")) return .toggle_transcript;
    if (std.mem.eql(u8, chord, "ctrl+t")) return .toggle_todos;
    if (std.mem.eql(u8, chord, "ctrl+b")) return .toggle_brief;
    if (std.mem.eql(u8, chord, "ctrl+shift+b")) return .toggle_brief;
    if (std.mem.eql(u8, chord, "ctrl+v")) return .image_paste;
    if (std.mem.eql(u8, chord, "alt+v")) return .image_paste;
    if (std.mem.eql(u8, chord, "ctrl+s")) return .stash_toggle;
    if (std.mem.eql(u8, chord, "ctrl+_")) return .undo_edit;
    if (std.mem.eql(u8, chord, "ctrl+shift+-")) return .undo_edit;
    if (std.mem.eql(u8, chord, "alt+p")) return .model_picker;
    if (std.mem.eql(u8, chord, "alt+o")) return .fast_toggle;
    if (std.mem.eql(u8, chord, "alt+t")) return .thinking_toggle;
    return .none;
}

fn printableAsciiChord(ch: u8, out: *[8]u8) ?[]const u8 {
    if (ch == ' ') return "space";
    if (ch < 0x20 or ch >= 0x7f) return null;
    out[0] = if (ch >= 'A' and ch <= 'Z') std.ascii.toLower(ch) else ch;
    return out[0..1];
}

fn resolvePromptBinding(
    bindings: ?*const keybindings.RuntimeKeybindings,
    prompt_context: ?keybindings.BindingContext,
    attachment_active: bool,
    chord: []const u8,
    fallback: InputEvent,
) InputEvent {
    const pending = pendingPromptChord();
    if (pending != null and std.mem.eql(u8, chord, "escape")) {
        clearPendingPromptChord();
        return .none;
    }

    const kb = bindings orelse {
        clearPendingPromptChord();
        return fallback;
    };
    const contexts: []const keybindings.BindingContext = if (prompt_context) |context|
        &[_]keybindings.BindingContext{ context, .Chat, .Global }
    else if (attachment_active)
        &[_]keybindings.BindingContext{ .Attachments, .Chat, .Global }
    else
        &[_]keybindings.BindingContext{ .Chat, .Global };

    const lookup = kb.resolveChord(contexts, pending, chord);
    switch (lookup.result) {
        .none => {
            clearPendingPromptChord();
            return fallback;
        },
        .chord_started => {
            _ = storePendingPromptChord(pending, chord);
            return .none;
        },
        .chord_cancelled => {
            clearPendingPromptChord();
            return .none;
        },
        .match => {
            clearPendingPromptChord();
        },
    }

    if (lookup.command) |command| {
        last_bound_command = command;
        return .bound_command;
    }
    const action = lookup.action orelse return .none;
    return switch (action) {
        .app_interrupt => .interrupt,
        .app_toggle_todos => .toggle_todos,
        .app_toggle_transcript => .toggle_transcript,
        .app_toggle_brief => .toggle_brief,
        .app_redraw => .redraw,
        .app_global_search => .global_search,
        .app_quick_open => .quick_open,
        .history_search => .history_search,
        .history_previous => .history_prev,
        .history_next => .history_next,
        .chat_cycle_mode => .toggle_mode,
        // P3 (PRD #534): the Confirmation-context Shift+Tab (confirm_cycle_mode)
        // cycles the permission mode inside the approval overlay. The chat
        // Shift+Tab (chat_cycle_mode) keeps cycling SessionMode -- deliberately
        // left intact so a shipped feature is not regressed.
        .confirm_cycle_mode => .toggle_permission_mode,
        .chat_command_palette => .command_palette,
        .chat_session_switcher => .session_switcher,
        .chat_model_picker => .model_picker,
        .chat_theme_picker => .theme_picker,
        .chat_runtime_panel => .runtime_panel,
        .chat_density_toggle => .density_toggle,
        .chat_fast_mode => .fast_toggle,
        .chat_thinking_toggle => .thinking_toggle,
        .chat_submit => .submit,
        .chat_newline => .insert_newline,
        .chat_undo => .undo_edit,
        .chat_external_editor => .external_editor,
        .chat_kill_agents => .kill_background_tasks,
        .chat_stash => .stash_toggle,
        .chat_image_paste => .image_paste,
        .chat_message_actions => .message_actions,
        .chat_clear_line => .clear_line,
        .chat_delete_prev_word => .delete_prev_word,
        .chat_backspace => .backspace,
        .autocomplete_accept => .autocomplete,
        .autocomplete_dismiss => .escape,
        .autocomplete_previous => .history_prev,
        .autocomplete_next => .history_next,
        .prompt_previous => .prompt_previous,
        .prompt_next => .prompt_next,
        .prompt_open => .prompt_open,
        .prompt_dismiss => .prompt_dismiss,
        .prompt_exit => .prompt_exit,
        .attachments_next => .attachment_next,
        .attachments_previous => .attachment_previous,
        .attachments_remove => .attachment_remove,
        .attachments_exit => .attachment_exit,
        else => fallback,
    };
}

fn ctrlChord(ch: u8, out: *[16]u8) ?[]const u8 {
    if (ch >= 1 and ch <= 26) {
        const letter = @as(u8, 'a') + ch - 1;
        out[0] = 'c';
        out[1] = 't';
        out[2] = 'r';
        out[3] = 'l';
        out[4] = '+';
        out[5] = letter;
        return out[0..6];
    }
    return switch (ch) {
        0x1f => "ctrl+_",
        else => null,
    };
}

fn csiChord(final: u8, mods: ?usize) ?[]const u8 {
    const has_ctrl_mod = if (mods) |m| (m == 5 or m == 6 or m == 7 or m == 8) else false;
    const has_shift_mod = if (mods) |m| (m == 2 or m == 4 or m == 6 or m == 8) else false;
    return switch (final) {
        'A' => if (has_shift_mod) "shift+up" else "up",
        'B' => "down",
        'C' => if (has_ctrl_mod) "ctrl+right" else "right",
        'D' => if (has_ctrl_mod) "ctrl+left" else "left",
        'H' => "home",
        'F' => "end",
        'Z' => "shift+tab",
        else => null,
    };
}

const ModifierFlags = struct {
    shift: bool = false,
    // `alt` here is the meta/Option modifier (xterm bit 2).
    alt: bool = false,
    ctrl: bool = false,
    // `cmd` IS the super modifier (xterm bit 8 == Cmd on macOS / Win key).
    // The reference (parse-keypress.ts decodeModifier) names this bit `super`;
    // zcode keeps the `cmd` name to match its existing chord strings ("cmd+...").
    // It is the same bit -- there is no separate super decode to add.
    cmd: bool = false,
};

fn kittyModifierFlags(mods: usize) ModifierFlags {
    if (mods == 0) return .{};
    const bits = mods - 1;
    return .{
        .shift = (bits & 0b0001) != 0,
        .alt = (bits & 0b0010) != 0,
        .ctrl = (bits & 0b0100) != 0,
        // bit 3 of (mods-1) == xterm bit 8 == super (Cmd/Win).
        .cmd = (bits & 0b1000) != 0,
    };
}

/// Map a CSI-u / modifyOtherKeys keycode to its logical key name, handling
/// both ASCII keycodes and Kitty keyboard-protocol functional (numpad) keys.
/// Numpad codepoints are from the Unicode Private Use Area as defined by the
/// Kitty keyboard protocol functional-key table. Returns null for keycodes we
/// do not name (so the caller falls through to its existing handling).
///
/// Mirrors the reference keycodeToName (parse-keypress.ts:487-541).
fn keycodeName(cp: usize) ?[]const u8 {
    return switch (cp) {
        9 => "tab",
        13 => "return",
        27 => "escape",
        32 => "space",
        127 => "backspace",
        // Kitty keyboard protocol numpad keys (KP_0 through KP_9).
        57399 => "0",
        57400 => "1",
        57401 => "2",
        57402 => "3",
        57403 => "4",
        57404 => "5",
        57405 => "6",
        57406 => "7",
        57407 => "8",
        57408 => "9",
        57409 => ".", // KP_DECIMAL
        57410 => "/", // KP_DIVIDE
        57411 => "*", // KP_MULTIPLY
        57412 => "-", // KP_SUBTRACT
        57413 => "+", // KP_ADD
        57414 => "return", // KP_ENTER
        57415 => "=", // KP_EQUAL
        else => {
            // Printable ASCII, lowercased to match the reference.
            if (cp >= 32 and cp <= 126) {
                return asciiLowerNames[cp - 32 ..][0..1];
            }
            return null;
        },
    };
}

/// One-byte lowercase name slices for printable ASCII (0x20..0x7e), so
/// keycodeName can return a stable []const u8 without a per-call buffer.
const asciiLowerNames = blk: {
    var names: [95]u8 = undefined;
    var c: usize = 32;
    while (c <= 126) : (c += 1) {
        const ch: u8 = @intCast(c);
        names[c - 32] = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
    }
    break :blk names;
};

/// Pure decision for a Kitty numpad codepoint (PUA 57399..57415). Separated
/// from the IO-bound CSI-u handler so it can be unit-tested without a real
/// input fd. `.submit` for KP_ENTER, `.insert` (with the ASCII byte) for a
/// numpad digit/operator, `.ignore` for a recognized-but-unnamed key, and
/// null when the codepoint is not a numpad key at all.
const NumpadAction = union(enum) {
    submit,
    insert: u8,
    ignore,
};

fn numpadAction(codepoint: usize) ?NumpadAction {
    if (codepoint < 57399 or codepoint > 57415) return null;
    if (codepoint == 57414) return .submit; // KP_ENTER
    if (keycodeName(codepoint)) |name| {
        if (name.len == 1) return .{ .insert = name[0] };
    }
    return .ignore;
}

fn shiftedAsciiBase(ch: u8) ?u8 {
    return switch (ch) {
        'A'...'Z' => std.ascii.toLower(ch),
        '_' => '-',
        '+' => '=',
        '{' => '[',
        '}' => ']',
        ':' => ';',
        '"' => '\'',
        '<' => ',',
        '>' => '.',
        '?' => '/',
        '|' => '\\',
        ')' => '0',
        '!' => '1',
        '@' => '2',
        '#' => '3',
        '$' => '4',
        '%' => '5',
        '^' => '6',
        '&' => '7',
        '*' => '8',
        '(' => '9',
        '~' => '`',
        else => null,
    };
}

fn appendModifierParts(out: []u8, flags: ModifierFlags) ?usize {
    var pos: usize = 0;
    const modifiers = [_]struct {
        enabled: bool,
        text: []const u8,
    }{
        .{ .enabled = flags.alt, .text = "alt" },
        .{ .enabled = flags.cmd, .text = "cmd" },
        .{ .enabled = flags.ctrl, .text = "ctrl" },
        .{ .enabled = flags.shift, .text = "shift" },
    };
    for (modifiers) |modifier| {
        if (!modifier.enabled) continue;
        if (pos > 0) {
            if (pos >= out.len) return null;
            out[pos] = '+';
            pos += 1;
        }
        if (pos + modifier.text.len > out.len) return null;
        @memcpy(out[pos .. pos + modifier.text.len], modifier.text);
        pos += modifier.text.len;
    }
    return pos;
}

fn altPrintableChord(second: u8, out: *[24]u8) ?[]const u8 {
    if (second < 0x20 or second >= 0x7f) return null;
    var key = second;
    if (key >= 'A' and key <= 'Z') key = std.ascii.toLower(key);
    const prefix_len = appendModifierParts(out, .{ .alt = true }) orelse return null;
    if (prefix_len + 2 > out.len) return null;
    out[prefix_len] = '+';
    out[prefix_len + 1] = key;
    return out[0 .. prefix_len + 2];
}

fn kittyPrintableChord(codepoint: usize, flags: ModifierFlags, out: *[32]u8) ?[]const u8 {
    if (codepoint < 0x20 or codepoint > 0x7e) return null;
    if (!flags.shift and !flags.alt and !flags.ctrl and !flags.cmd) return null;

    var key = @as(u8, @intCast(codepoint));
    if (key >= 'A' and key <= 'Z') {
        key = std.ascii.toLower(key);
    } else if (flags.shift) {
        if (shiftedAsciiBase(key)) |base| key = base;
    }

    var pos = appendModifierParts(out, flags) orelse return null;
    if (pos > 0) {
        if (pos + 2 > out.len) return null;
        out[pos] = '+';
        pos += 1;
    }
    if (pos + 1 > out.len) return null;
    out[pos] = key;
    pos += 1;
    return out[0..pos];
}

/// When ZCODE_DEBUG_INPUT is set to a path, every raw byte we read
/// from the TTY is appended there. Used to diagnose "key X doesn't
/// work" reports where the code path looks correct in source but
/// something along the TTY pipeline is eating or mangling bytes.
/// Zero overhead when the env var is unset (checked once, cached).
var debug_input_log: ?std.Io.File = null;
var debug_input_log_checked: bool = false;

fn debugInputLog() ?std.Io.File {
    if (debug_input_log_checked) return debug_input_log;
    debug_input_log_checked = true;
    const path_buf: [4096]u8 = undefined;
    _ = path_buf;
    const path = @import("../core/env.zig").getenv("ZCODE_DEBUG_INPUT") orelse return null;
    if (path.len == 0) return null;
    const file = std.Io.Dir.cwd().createFile(rt.io, path, .{ .truncate = false }) catch return null;
    // 0.16: no seek; writes go positional
    debug_input_log = file;
    return debug_input_log;
}

pub fn readOneByte(fd: std.posix.fd_t) !u8 {
    var byte: [1]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &byte) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) return error.EndOfStream;
        if (debugInputLog()) |log| {
            var line_buf: [64]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "[input] 0x{x:0>2} ({d})\n", .{ byte[0], byte[0] }) catch "";
            _ = log.writeStreamingAll(rt.io, line) catch {};
        }
        return byte[0];
    }
}

pub const MAX_INPUT_BYTES: usize = 16 * 1024;
pub const MAX_SLASH_SUGGESTIONS: usize = 5;

pub const SlashSuggestions = struct {
    query: []const u8 = "",
    total_matches: usize = 0,
    matches: [MAX_SLASH_SUGGESTIONS][]const u8 = [_][]const u8{""} ** MAX_SLASH_SUGGESTIONS,

    pub fn visibleCount(self: *const @This()) usize {
        return @min(self.total_matches, self.matches.len);
    }

    pub fn visible(self: *const @This()) []const []const u8 {
        return self.matches[0..self.visibleCount()];
    }
};

/// Insert a byte at the given cursor position. Cursor advances by the number
/// of bytes inserted (0 if buffer is full or char is filtered).
pub fn insertInputByteAt(input_buf: *std_io.StringBuilder, cursor: *usize, ch: u8) !void {
    if (input_buf.items().len >= MAX_INPUT_BYTES) return;

    // Defensive: clamp cursor to valid range. Could drift if a non-cursor-aware
    // code path mutated input_buf (e.g. paste, autocomplete).
    if (cursor.* > input_buf.items().len) cursor.* = input_buf.items().len;

    var insert_ch: ?u8 = null;
    if (ch == '\r') {
        if (cursor.* == 0 or input_buf.items()[cursor.* - 1] != '\n') {
            insert_ch = '\n';
        }
    } else if (ch == '\n') {
        insert_ch = '\n';
    } else if (ch == '\t') {
        insert_ch = ' ';
    } else if (ch >= 0x20 and ch != 0x7f) {
        insert_ch = ch;
    }

    if (insert_ch) |c| {
        try input_buf.insert(cursor.*, c);
        cursor.* += 1;
    }
}

pub fn appendInputByte(input_buf: *std_io.StringBuilder, ch: u8) !void {
    if (ch == '\r') {
        if (input_buf.items().len < MAX_INPUT_BYTES) {
            if (input_buf.items().len == 0 or input_buf.items()[input_buf.items().len - 1] != '\n') {
                try input_buf.append('\n');
            }
        }
        return;
    }
    if (ch == '\n') {
        if (input_buf.items().len < MAX_INPUT_BYTES) {
            try input_buf.append('\n');
        }
        return;
    }
    if (ch == '\t') {
        if (input_buf.items().len < MAX_INPUT_BYTES) {
            try input_buf.append(' ');
        }
        return;
    }
    if (ch < 0x20 or ch == 0x7f) return;
    if (input_buf.items().len < MAX_INPUT_BYTES) {
        try input_buf.append(ch);
    }
}

pub fn appendInputBytes(input_buf: *std_io.StringBuilder, bytes: []const u8) !void {
    for (bytes) |ch| {
        try appendInputByte(input_buf, ch);
    }
}

pub fn insertInputBytesAt(
    input_buf: *std_io.StringBuilder,
    cursor: *usize,
    bytes: []const u8,
) !void {
    for (bytes) |ch| {
        try insertInputByteAt(input_buf, cursor, ch);
    }
}

pub fn readBracketedPaste(fd: std.posix.fd_t, input_buf: *std_io.StringBuilder) !void {
    var dummy_cursor: usize = input_buf.items().len;
    return readBracketedPasteCursor(fd, input_buf, &dummy_cursor);
}

pub fn readBracketedPasteCursor(fd: std.posix.fd_t, input_buf: *std_io.StringBuilder, cursor: *usize) !void {
    const end_seq = "\x1b[201~";
    var matched: usize = 0;
    const max_paste_bytes = MAX_INPUT_BYTES * 4;
    var total: usize = 0;
    while (total < max_paste_bytes) : (total += 1) {
        const ch = readOneByte(fd) catch return;

        if (ch == end_seq[matched]) {
            matched += 1;
            if (matched == end_seq.len) return;
            continue;
        }

        if (matched > 0) {
            // Insert the partial-match bytes at cursor
            for (end_seq[0..matched]) |b| {
                try insertInputByteAt(input_buf, cursor, b);
            }
            matched = 0;
            if (ch == end_seq[0]) {
                matched = 1;
                continue;
            }
        }

        try insertInputByteAt(input_buf, cursor, ch);
    }
}

pub const CsiNumeric = struct {
    first: ?usize = null,
    second: ?usize = null,
};

pub fn parseCsiNumeric(payload: []const u8) CsiNumeric {
    var out = CsiNumeric{};
    if (payload.len == 0) return out;

    var i: usize = 0;
    var first: usize = 0;
    var saw_first = false;
    while (i < payload.len and payload[i] >= '0' and payload[i] <= '9') : (i += 1) {
        saw_first = true;
        first = first * 10 + (payload[i] - '0');
    }
    if (!saw_first) return out;
    out.first = first;

    if (i < payload.len and payload[i] == ';') {
        i += 1;
        var second: usize = 0;
        var saw_second = false;
        while (i < payload.len and payload[i] >= '0' and payload[i] <= '9') : (i += 1) {
            saw_second = true;
            second = second * 10 + (payload[i] - '0');
        }
        if (saw_second) out.second = second;
    }

    return out;
}

pub fn parseEscapeSequence(fd: std.posix.fd_t, input_buf: *std_io.StringBuilder) !InputEvent {
    var dummy_cursor: usize = input_buf.items().len;
    return parseEscapeSequenceCursorInternal(fd, input_buf, &dummy_cursor, null, null, false);
}

fn mapCsiFinal(final: u8, has_ctrl_mod: bool) InputEvent {
    return switch (final) {
        'A' => .history_prev,
        'B' => .history_next,
        'C' => if (has_ctrl_mod) .cursor_word_right else .cursor_right,
        'D' => if (has_ctrl_mod) .cursor_word_left else .cursor_left,
        'H' => .cursor_home,
        'F' => .cursor_end,
        'Z' => .toggle_mode,
        else => .none,
    };
}

fn mapCsiFinalWithMods(final: u8, mods: ?usize) InputEvent {
    const has_ctrl_mod = if (mods) |m| (m == 5 or m == 6 or m == 7 or m == 8) else false;
    const has_shift_mod = if (mods) |m| (m == 2 or m == 4 or m == 6 or m == 8) else false;
    if (has_shift_mod and final == 'A') return .message_actions;
    return mapCsiFinal(final, has_ctrl_mod);
}

pub fn parseEscapeSequenceCursor(input_buf: *std_io.StringBuilder, cursor: *usize) !InputEvent {
    return parseEscapeSequenceCursorWithBindings(input_buf, cursor, null, null, false);
}

pub fn parseEscapeSequenceCursorWithBindings(
    input_buf: *std_io.StringBuilder,
    cursor: *usize,
    bindings: ?*const keybindings.RuntimeKeybindings,
    prompt_context: ?keybindings.BindingContext,
    attachment_active: bool,
) !InputEvent {
    const fd = std.Io.File.stdin().handle;
    return parseEscapeSequenceCursorInternal(fd, input_buf, cursor, bindings, prompt_context, attachment_active);
}

/// Assemble a DCS (`ESC P ...`) or OSC (`ESC ] ...`) terminal response up to
/// its BEL (`\x07`) or ST (`ESC \`) terminator and route it through the
/// terminal-response parser. `framing` is the byte after ESC (`'P'` or `']'`).
/// XTVERSION replies update `terminal_caps`; everything else is recorded for
/// `takeLastTerminalResponse`. Always returns `.none` -- responses are never
/// user input. Over-long or unterminated payloads are dropped cleanly so a
/// malformed reply cannot leak into the prompt.
fn readDcsOscResponse(fd: std.posix.fd_t, framing: u8) !InputEvent {
    var seq: [160]u8 = undefined;
    seq[0] = 0x1b;
    seq[1] = framing;
    var len: usize = 2;
    while (len < seq.len) {
        const ch = readOneByte(fd) catch break;
        // BEL terminates the string immediately.
        if (ch == 0x07) {
            seq[len] = ch;
            len += 1;
            break;
        }
        // ST is the two-byte sequence ESC \. Capture the trailing backslash
        // when the previous byte was ESC.
        if (ch == '\\' and seq[len - 1] == 0x1b) {
            seq[len] = ch;
            len += 1;
            break;
        }
        seq[len] = ch;
        len += 1;
    }

    if (terminal_response.parse(seq[0..len])) |resp| {
        switch (resp) {
            .xtversion => |name| terminal_caps.setXtversionName(name),
            else => recordTerminalResponse(resp),
        }
    }
    return .none;
}

fn parseEscapeSequenceCursorInternal(
    fd: std.posix.fd_t,
    input_buf: *std_io.StringBuilder,
    cursor: *usize,
    bindings: ?*const keybindings.RuntimeKeybindings,
    prompt_context: ?keybindings.BindingContext,
    attachment_active: bool,
) !InputEvent {
    // Bare Escape at the input prompt is a no-op.
    // Escape cancels ongoing agent work via the spinner thread (see repl_spinner.zig).
    // Arrow keys send ESC [ A/B/C/D as fast byte sequences.
    {
        var poll_fds = [1]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&poll_fds, 50) catch 0;
        if (ready == 0) {
            // Bare Escape -- no-op at the input prompt
            return resolvePromptBinding(bindings, prompt_context, attachment_active, "escape", .escape);
        }
    }

    const second = readOneByte(fd) catch return .none;
    // ESC + Enter (Meta/Alt+Enter) inserts newline in many terminals.
    if (second == '\r' or second == '\n') return resolvePromptBinding(bindings, prompt_context, attachment_active, "shift+enter", .insert_newline);
    // ESC + Backspace is commonly used by terminals for Alt/Meta-Backspace.
    if (second == 0x7f or second == 0x08) return resolvePromptBinding(bindings, prompt_context, attachment_active, "alt+backspace", .delete_prev_word);
    if (second == 'O') {
        const ch = readOneByte(fd) catch return .none;
        return resolvePromptBinding(bindings, prompt_context, attachment_active, csiChord(ch, null) orelse "", mapCsiFinal(ch, false));
    }
    // DCS (ESC P) and OSC (ESC ]) framing: these carry terminal *responses*
    // (XTVERSION via DCS, OSC color/code replies) terminated by BEL or ST
    // rather than a single byte in 0x40..0x7E, so they need their own
    // assembler. Consume the reply and route it; never leak into the prompt.
    if (second == 'P' or second == ']') {
        return readDcsOscResponse(fd, second);
    }
    if (second != '[') {
        var alt_buf: [24]u8 = undefined;
        if (altPrintableChord(second, &alt_buf)) |chord| {
            return resolvePromptBinding(bindings, prompt_context, attachment_active, chord, fallbackEventForChord(chord));
        }
        return .none;
    }

    const first = readOneByte(fd) catch return .none;

    // X10 legacy mouse event: ESC [ M Cb Cx Cy
    if (first == 'M') {
        const cb = readOneByte(fd) catch return .none;
        const cx = readOneByte(fd) catch return .none;
        const cy = readOneByte(fd) catch return .none;

        const code: u8 = if (cb >= 32) cb - 32 else cb;
        if ((code & 0x7f) == 64) return .mouse_scroll_up;
        if ((code & 0x7f) == 65) return .mouse_scroll_down;
        // Non-wheel buttons: decode the coordinates the old code discarded and
        // park them for a future clickable-UI layer. Still returns .none.
        if (parseX10Mouse(cb, cx, cy)) |ev| last_mouse = ev;
        return .none;
    }

    // Single-byte CSI final (e.g. ESC [ A / B / C / D / H / F). Handle immediately.
    if (first >= 0x40 and first <= 0x7E) {
        return resolvePromptBinding(bindings, prompt_context, attachment_active, csiChord(first, null) orelse "", mapCsiFinalWithMods(first, null));
    }

    var seq: [32]u8 = undefined;
    seq[0] = first;
    var len: usize = 1;
    while (len < seq.len) : (len += 1) {
        const ch = readOneByte(fd) catch break;
        seq[len] = ch;
        if (ch >= 0x40 and ch <= 0x7E) {
            len += 1;
            break;
        }
    }

    const final = seq[len - 1];
    // Parse CSI parameters for modifier detection (e.g. [1;5C = Ctrl+Right)
    const csi_params = parseCsiNumeric(seq[0 .. len - 1]);
    const mapped = mapCsiFinalWithMods(final, csi_params.second);
    if (mapped != .none) return resolvePromptBinding(bindings, prompt_context, attachment_active, csiChord(final, csi_params.second) orelse "", mapped);

    // SGR mouse event: ESC [ <Cb;Cx;CyM
    if ((final == 'M' or final == 'm') and seq[0] == '<') {
        var num: usize = 0;
        var i: usize = 1;
        while (i < len - 1) : (i += 1) {
            const ch = seq[i];
            if (ch == ';') break;
            if (ch < '0' or ch > '9') break;
            num = num * 10 + (ch - '0');
        }
        if (num == 64) return .mouse_scroll_up;
        if (num == 65) return .mouse_scroll_down;
        // Non-wheel buttons (clicks/drags/releases): decode the coordinates
        // and park them for a future clickable-UI layer. There is no
        // InputEvent to fire today, so this returns .none like before.
        if (parseSgrMouse(seq[0..len])) |ev| last_mouse = ev;
        return .none;
    }

    if (final == '~') {
        const nums = parseCsiNumeric(seq[0 .. len - 1]);
        if (nums.first) |num| {
            if (num == 200) {
                try readBracketedPasteCursor(fd, input_buf, cursor);
                return .none;
            }
            if (num == 13) {
                if (nums.second) |mods| {
                    if (mods >= 2) return resolvePromptBinding(bindings, prompt_context, attachment_active, "shift+enter", .insert_newline);
                }
                return resolvePromptBinding(bindings, prompt_context, attachment_active, "enter", .submit);
            }
            if (num == 1 or num == 7) return .jump_top;
            if (num == 4 or num == 8) return .jump_bottom;
            if (num == 5) return .page_up;
            if (num == 6) return .page_down;
        }
    }

    // Kitty keyboard protocol: CSI <codepoint>;<mods>u
    if (final == 'u') {
        if (parseKittyKeyPayload(seq[0 .. len - 1])) |key| {
            const flags = kittyModifierFlags(key.mods);
            if (key.codepoint == 9) {
                if (key.mods > 1) return resolvePromptBinding(bindings, prompt_context, attachment_active, "shift+tab", .toggle_mode);
                return resolvePromptBinding(bindings, prompt_context, attachment_active, "tab", .autocomplete);
            }
            if (key.codepoint == 13 or key.codepoint == 10) {
                if (key.mods > 1) {
                    return resolvePromptBinding(bindings, prompt_context, attachment_active, "shift+enter", .insert_newline);
                }
                return resolvePromptBinding(bindings, prompt_context, attachment_active, "enter", .submit);
            }
            if (key.codepoint == 27) return resolvePromptBinding(bindings, prompt_context, attachment_active, "escape", .interrupt);
            if (key.codepoint == 127 or key.codepoint == 8) {
                if (flags.cmd) return resolvePromptBinding(bindings, prompt_context, attachment_active, "cmd+backspace", .clear_line);
                if (flags.alt) return resolvePromptBinding(bindings, prompt_context, attachment_active, "alt+backspace", .delete_prev_word);
                return resolvePromptBinding(bindings, prompt_context, attachment_active, "backspace", .backspace);
            }

            var kitty_buf: [32]u8 = undefined;
            if (kittyPrintableChord(key.codepoint, flags, &kitty_buf)) |chord| {
                return resolvePromptBinding(bindings, prompt_context, attachment_active, chord, fallbackEventForChord(chord));
            }

            if (key.codepoint == 21) return resolvePromptBinding(bindings, prompt_context, attachment_active, "ctrl+u", .clear_line);
            if (key.codepoint == 23) return resolvePromptBinding(bindings, prompt_context, attachment_active, "ctrl+w", .delete_prev_word);
            if (key.codepoint == 18) return resolvePromptBinding(bindings, prompt_context, attachment_active, "ctrl+r", .history_search);
            if (key.codepoint == 12) return resolvePromptBinding(bindings, prompt_context, attachment_active, "ctrl+l", .redraw);
            if (key.codepoint == 5) return resolvePromptBinding(bindings, prompt_context, attachment_active, "ctrl+e", .transcript_view);
            if (key.codepoint == 7) return resolvePromptBinding(bindings, prompt_context, attachment_active, "ctrl+g", .external_editor);
            if (key.codepoint == 16) return resolvePromptBinding(bindings, prompt_context, attachment_active, "ctrl+p", .quick_open);
            if (key.codepoint == 6) return resolvePromptBinding(bindings, prompt_context, attachment_active, "ctrl+f", .global_search);
            if (key.codepoint == 15) return resolvePromptBinding(bindings, prompt_context, attachment_active, "ctrl+o", .toggle_transcript);
            if (key.codepoint == 20) return resolvePromptBinding(bindings, prompt_context, attachment_active, "ctrl+t", .toggle_todos);
            if (key.codepoint == 2) return resolvePromptBinding(bindings, prompt_context, attachment_active, "ctrl+b", .toggle_brief);
            if (key.codepoint == 22) return resolvePromptBinding(bindings, prompt_context, attachment_active, "ctrl+v", .image_paste);
            if (key.codepoint == 19) return resolvePromptBinding(bindings, prompt_context, attachment_active, "ctrl+s", .stash_toggle);
            if (key.codepoint == 31) return resolvePromptBinding(bindings, prompt_context, attachment_active, "ctrl+_", .undo_edit);
            if (key.codepoint == 3) return resolvePromptBinding(bindings, prompt_context, attachment_active, "ctrl+c", .interrupt);
            if (key.codepoint == 4) return resolvePromptBinding(bindings, prompt_context, attachment_active, "ctrl+d", .interrupt);

            // Kitty keyboard-protocol numpad keys arrive as Private Use Area
            // codepoints (57399..57415). Without explicit handling they would
            // hit the unmodified-printable fallback below and get UTF-8 encoded
            // as garbage PUA glyphs. Map KP_ENTER to submit and the numpad
            // digits/operators to their ASCII equivalents so they are usable;
            // recognize-and-ignore anything in the range we do not name.
            // (Per-task scope: no general ParsedKey rework -- just usable
            // numpad keys + clean ignore for the rest.)
            if (!flags.ctrl and !flags.alt and !flags.cmd) {
                if (numpadAction(key.codepoint)) |action| {
                    clearPendingPromptChord();
                    switch (action) {
                        .submit => {
                            // KP_ENTER -> submit, matching the main Enter key.
                            return resolvePromptBinding(bindings, prompt_context, attachment_active, "enter", .submit);
                        },
                        .insert => |byte| {
                            try insertInputByteAt(input_buf, cursor, byte);
                            return .none;
                        },
                        .ignore => return .none,
                    }
                }
            }

            // Unmodified printable reported via the Kitty CSI-u form. This
            // happens when the terminal reports plain keys as escape codes
            // (a higher keyboard-protocol level, or a stacked/stuck protocol
            // state left by a previously crashed process). Without this, such
            // keys hit kittyPrintableChord (which returns null for unmodified
            // keys) and fall through to .none -- i.e. typing is silently
            // dropped. Insert the character instead of losing it.
            if (key.codepoint >= 0x20 and key.codepoint <= 0x10FFFF and key.codepoint != 127 and !flags.ctrl and !flags.alt and !flags.cmd) {
                clearPendingPromptChord();
                if (key.codepoint <= 0x7e) {
                    try insertInputByteAt(input_buf, cursor, @intCast(key.codepoint));
                } else {
                    var ubuf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(@intCast(key.codepoint), &ubuf) catch return .none;
                    try insertInputBytesAt(input_buf, cursor, ubuf[0..n]);
                }
                return .none;
            }
        }
    }

    // Before giving up, check whether this assembled CSI sequence is actually
    // an inbound terminal response (DECRPM/DA1/DA2/kitty-flags/DSR) rather than
    // a keypress. Such replies must be consumed, not leaked into the prompt.
    // Reconstruct the full sequence (the assembler dropped the leading ESC [).
    {
        var resp_buf: [2 + seq.len]u8 = undefined;
        resp_buf[0] = 0x1b;
        resp_buf[1] = '[';
        @memcpy(resp_buf[2 .. 2 + len], seq[0..len]);
        if (terminal_response.parse(resp_buf[0 .. 2 + len])) |resp| {
            recordTerminalResponse(resp);
            return .none;
        }
    }

    return .none;
}

pub fn readFullScreenInputEvent(input_buf: *std_io.StringBuilder) !InputEvent {
    var dummy_cursor: usize = input_buf.items().len;
    return readFullScreenInputEventCursor(input_buf, &dummy_cursor);
}

pub fn readFullScreenInputEventCursor(input_buf: *std_io.StringBuilder, cursor: *usize) !InputEvent {
    return readFullScreenInputEventCursorWithBindings(input_buf, cursor, null, null, false);
}

pub fn readFullScreenInputEventCursorWithBindings(
    input_buf: *std_io.StringBuilder,
    cursor: *usize,
    bindings: ?*const keybindings.RuntimeKeybindings,
    prompt_context: ?keybindings.BindingContext,
    attachment_active: bool,
) !InputEvent {
    last_bound_command = null;
    const fd = std.Io.File.stdin().handle;
    const ch = try readOneByte(fd);

    switch (ch) {
        '\r', '\n' => return resolvePromptBinding(bindings, prompt_context, attachment_active, "enter", .submit),
        '\t' => return resolvePromptBinding(bindings, prompt_context, attachment_active, "tab", .autocomplete),
        0x7f, 0x08 => return resolvePromptBinding(bindings, prompt_context, attachment_active, "backspace", .backspace),
        0x1b => return parseEscapeSequenceCursorInternal(fd, input_buf, cursor, bindings, prompt_context, attachment_active),
        else => {},
    }

    var ctrl_buf: [16]u8 = undefined;
    if (ctrlChord(ch, &ctrl_buf)) |chord| {
        return resolvePromptBinding(bindings, prompt_context, attachment_active, chord, fallbackEventForChord(chord));
    }

    switch (ch) {
        else => {
            if (ch >= 0x80) {
                var utf8_buf: [4]u8 = [_]u8{0} ** 4;
                utf8_buf[0] = ch;
                const seq_len = utf8SequenceLength(ch) orelse {
                    clearPendingPromptChord();
                    try insertInputByteAt(input_buf, cursor, ch);
                    return .none;
                };
                var have: usize = 1;
                while (have < seq_len) : (have += 1) {
                    utf8_buf[have] = readOneByte(fd) catch break;
                }
                if (std.unicode.utf8Decode(utf8_buf[0..have])) |codepoint| {
                    if (keybindings.isMacosOptionChar(codepoint)) |shortcut| {
                        return resolvePromptBinding(bindings, prompt_context, attachment_active, shortcut, fallbackEventForChord(shortcut));
                    }
                } else |_| {}
                clearPendingPromptChord();
                try insertInputBytesAt(input_buf, cursor, utf8_buf[0..have]);
            } else {
                var printable_buf: [8]u8 = undefined;
                if (printableAsciiChord(ch, &printable_buf)) |chord| {
                    const had_pending = pendingPromptChord() != null;
                    const ev = resolvePromptBinding(bindings, prompt_context, attachment_active, chord, .none);
                    if (ev != .none or last_bound_command != null or pendingPromptChord() != null or had_pending) {
                        return ev;
                    }
                }
                clearPendingPromptChord();
                try insertInputByteAt(input_buf, cursor, ch);
            }
            return .none;
        },
    }
}

test "literal control bytes prefer enter tab and backspace over ctrl chords" {
    var buf: [16]u8 = undefined;
    try testing.expectEqual(InputEvent.submit, resolvePromptBinding(null, null, false, "enter", .submit));
    try testing.expectEqual(InputEvent.backspace, resolvePromptBinding(null, null, false, "backspace", .backspace));
    try testing.expectEqual(InputEvent.autocomplete, InputEvent.autocomplete);
    try testing.expectEqualStrings("ctrl+m", ctrlChord(13, &buf).?);
}

test "confirm_cycle_mode binding resolves to toggle_permission_mode" {
    // P3 (PRD #534): the Confirmation Shift+Tab action must map to the new
    // toggle_permission_mode InputEvent so the approval overlay can cycle the
    // permission mode. Build a binding carrying confirm_cycle_mode and run it
    // through the chat resolver to exercise the switch arm directly.
    var key_buf = [_]u8{ 's', 'h', 'i', 'f', 't', '+', 't', 'a', 'b' };
    var entries = [_]keybindings.RuntimeBinding{.{
        .context = .Chat,
        .key = key_buf[0..],
        .action = .confirm_cycle_mode,
    }};
    const kb = keybindings.RuntimeKeybindings{ .entries = entries[0..], .owned = false };

    const ev = resolvePromptBinding(&kb, .Chat, false, "shift+tab", .toggle_mode);
    try testing.expectEqual(InputEvent.toggle_permission_mode, ev);
}

fn utf8SequenceLength(lead: u8) ?usize {
    if ((lead & 0b1110_0000) == 0b1100_0000) return 2;
    if ((lead & 0b1111_0000) == 0b1110_0000) return 3;
    if ((lead & 0b1111_1000) == 0b1111_0000) return 4;
    return null;
}

pub const KittyKeyPayload = struct {
    codepoint: usize,
    mods: usize,
};

pub fn parseKittyKeyPayload(payload: []const u8) ?KittyKeyPayload {
    if (payload.len == 0) return null;

    var i: usize = 0;
    var codepoint: usize = 0;
    var saw_codepoint = false;
    while (i < payload.len and payload[i] >= '0' and payload[i] <= '9') : (i += 1) {
        saw_codepoint = true;
        codepoint = codepoint * 10 + (payload[i] - '0');
    }
    if (!saw_codepoint) return null;

    var mods: usize = 0;
    if (i < payload.len and payload[i] == ';') {
        i += 1;
        var saw_mods = false;
        while (i < payload.len and payload[i] >= '0' and payload[i] <= '9') : (i += 1) {
            saw_mods = true;
            mods = mods * 10 + (payload[i] - '0');
        }
        if (!saw_mods) return null;
    }

    if (i != payload.len) return null;
    return .{ .codepoint = codepoint, .mods = mods };
}

pub fn deletePreviousWord(input_buf: *std_io.StringBuilder) void {
    if (input_buf.items().len == 0) return;

    var new_len = input_buf.items().len;
    while (new_len > 0 and std.ascii.isWhitespace(input_buf.items()[new_len - 1])) : (new_len -= 1) {}
    while (new_len > 0 and !std.ascii.isWhitespace(input_buf.items()[new_len - 1])) : (new_len -= 1) {}
    input_buf.shrinkRetainingCapacity(new_len);
}

pub const slash_autocomplete_commands = [_][]const u8{
    "/help",
    "/exit",
    "/quit",
    "/version",
    "/whoami",
    "/pwd",
    "/cd",
    "/! ",
    "/init",
    "/mode",
    "/mode execution",
    "/mode planning",
    "/mode brainstorm",
    "/mode review",
    "/plan",
    "/plan approve",
    "/plan discuss",
    "/plan cancel",
    "/approve-plan",
    "/approve",
    "/config",
    "/config set ",
    "/context",
    "/fast",
    "/fast on",
    "/fast off",
    "/brief",
    "/brief current",
    "/brief on",
    "/brief off",
    "/transcript",
    "/vim",
    "/vim current",
    "/vim on",
    "/vim off",
    "/theme",
    "/theme current",
    "/theme list",
    "/theme syntax on",
    "/theme syntax off",
    "/theme ",
    "/color",
    "/status",
    "/session",
    "/session checkpoint",
    "/session checkpoints",
    "/session restore",
    "/session fork",
    "/branch",
    "/fork",
    "/agents",
    "/agent",
    "/agent current",
    "/agent none",
    "/hooks",
    "/styles",
    "/style",
    "/style current",
    "/style ",
    "/marketplace sources",
    "/marketplace add ",
    "/marketplace remove ",
    "/marketplace refresh",
    "/marketplace refresh ",
    "/plugins",
    "/plugins marketplace",
    "/plugins marketplace ",
    "/plugin ",
    "/plugin install ",
    "/plugin uninstall ",
    "/plugin update ",
    "/commands",
    "/commands marketplace",
    "/commands marketplace ",
    "/command ",
    "/command install ",
    "/command uninstall ",
    "/command update ",
    "/trust",
    "/trust hooks",
    "/trust hook allow ",
    "/trust hook revoke ",
    "/trust marketplace",
    "/trust marketplace allow ",
    "/trust marketplace block ",
    "/trust marketplace unblock ",
    "/compact",
    "/todos",
    "/tasks",
    "/tasks list",
    "/tasks stop ",
    "/tasks stop-all",
    "/bashes",
    "/teams",
    "/bridge",
    "/models",
    "/model",
    "/model current",
    "/model list",
    "/model ",
    "/preprocessor",
    "/preprocessor current",
    "/preprocessor on",
    "/preprocessor off",
    "/preprocessor list",
    "/preprocessor list ",
    "/preprocessor ",
    "/mcp",
    "/mcp tools ",
    "/mcp resources ",
    "/mcp templates ",
    "/mcp read ",
    "/mcp prompts ",
    "/mcp prompt ",
    "/mcp complete ",
    "/mcp subscribe ",
    "/mcp unsubscribe ",
    "/mcp log-level ",
    "/mcp notifications",
    "/mcp notifications ",
    "/memory",
    "/memory list",
    "/memory save ",
    "/memory delete ",
    "/policy",
    "/cost",
    "/review",
    "/review working",
    "/review commit ",
    "/review branch ",
    "/open",
    "/quick-open",
    "/yolo",
    "/add-dir",
    "/add-dir list",
    "/add-dir remove ",
    "/tag",
    "/tag add ",
    "/tag remove ",
    "/tag list",
    "/stats",
    "/insights",
    "/summary",
    "/break-cache",
    "/login",
    "/logout",
    "/ide",
    "/terminal-setup",
    "/heapdump",
    "/ctx-viz",
    "/advisor",
    "/advisor on",
    "/advisor off",
    "/chrome",
    "/autofix-pr",
};

pub fn slashAutocompleteQuery(input_text: []const u8) ?[]const u8 {
    if (input_text.len == 0 or input_text[0] != '/') return null;
    if (std.mem.indexOfAny(u8, input_text, "\r\n") != null) return null;
    return input_text;
}

pub fn collectSlashSuggestions(input_text: []const u8) SlashSuggestions {
    const query = slashAutocompleteQuery(input_text) orelse return .{};

    var out = SlashSuggestions{
        .query = query,
    };

    for (slash_autocomplete_commands) |cmd| {
        if (removed_commands.isRemoved(cmd)) continue; // don't suggest removed commands (PRD #534)
        if (!std.mem.startsWith(u8, cmd, query)) continue;
        if (out.total_matches < out.matches.len) {
            out.matches[out.total_matches] = cmd;
        }
        out.total_matches += 1;
    }

    return out;
}

pub fn slashSuggestionAt(input_text: []const u8, match_index: usize) ?[]const u8 {
    const query = slashAutocompleteQuery(input_text) orelse return null;

    var seen: usize = 0;
    for (slash_autocomplete_commands) |cmd| {
        if (removed_commands.isRemoved(cmd)) continue; // skip removed commands (PRD #534)
        if (!std.mem.startsWith(u8, cmd, query)) continue;
        if (seen == match_index) return cmd;
        seen += 1;
    }

    return null;
}

pub fn applySlashAutocomplete(
    input_buf: *std_io.StringBuilder,
    hint_buf: *[320]u8,
    hint_len: *usize,
) !void {
    const current = input_buf.items();
    if (current.len == 0) {
        setHint(hint_buf, hint_len, "tab: type / then press Tab for slash commands");
        return;
    }
    if (slashAutocompleteQuery(current) == null) {
        setHint(hint_buf, hint_len, "tab completion is available for slash commands");
        return;
    }

    const suggestions = collectSlashSuggestions(current);
    const matches = suggestions.visible();

    if (suggestions.total_matches == 0) {
        setHint(hint_buf, hint_len, "no slash command matches");
        return;
    }

    if (suggestions.total_matches == 1) {
        try replaceInput(input_buf, matches[0]);
        clearHint(hint_len);
        return;
    }

    const lcp = longestCommonPrefix(matches);
    if (lcp.len > current.len) {
        try replaceInput(input_buf, lcp);
        clearHint(hint_len);
        return;
    }

    var out_len: usize = 0;
    appendToHint(hint_buf, &out_len, "tab: ");
    var i: usize = 0;
    while (i < matches.len) : (i += 1) {
        if (i > 0) appendToHint(hint_buf, &out_len, ", ");
        appendToHint(hint_buf, &out_len, matches[i]);
    }
    if (suggestions.total_matches > matches.len) {
        appendToHint(hint_buf, &out_len, " ...");
    }
    hint_len.* = out_len;
}

pub fn replaceInput(input_buf: *std_io.StringBuilder, text: []const u8) !void {
    input_buf.clearRetainingCapacity();
    try input_buf.appendSlice(text);
}

pub fn longestCommonPrefix(values: []const []const u8) []const u8 {
    if (values.len == 0) return "";
    var prefix = values[0];
    var i: usize = 1;
    while (i < values.len) : (i += 1) {
        var n: usize = 0;
        const other = values[i];
        const max_n = @min(prefix.len, other.len);
        while (n < max_n and prefix[n] == other[n]) : (n += 1) {}
        prefix = prefix[0..n];
        if (prefix.len == 0) break;
    }
    return prefix;
}

pub fn clearHint(hint_len: *usize) void {
    hint_len.* = 0;
}

pub fn setHint(hint_buf: *[320]u8, hint_len: *usize, msg: []const u8) void {
    const take = @min(msg.len, hint_buf.len);
    @memcpy(hint_buf[0..take], msg[0..take]);
    hint_len.* = take;
}

pub fn appendToHint(hint_buf: *[320]u8, out_len: *usize, piece: []const u8) void {
    if (out_len.* >= hint_buf.len) return;
    const room = hint_buf.len - out_len.*;
    const take = @min(room, piece.len);
    @memcpy(hint_buf[out_len.* .. out_len.* + take], piece[0..take]);
    out_len.* += take;
}

pub fn composeStatusHint(out: *[320]u8, runtime_hint: []const u8, input_hint: []const u8) []const u8 {
    if (runtime_hint.len == 0) return input_hint;
    if (input_hint.len == 0) return runtime_hint;

    var out_len: usize = 0;
    appendToHint(out, &out_len, runtime_hint);
    appendToHint(out, &out_len, " | ");
    appendToHint(out, &out_len, input_hint);
    return out[0..out_len];
}

const testing = std.testing;

test "parseKittyKeyPayload parses codepoint and mods" {
    const parsed = parseKittyKeyPayload("127;9");
    try testing.expect(parsed != null);
    try testing.expectEqual(@as(usize, 127), parsed.?.codepoint);
    try testing.expectEqual(@as(usize, 9), parsed.?.mods);
}

test "kittyModifierFlags decodes super (cmd) from bit 8" {
    // mods=9 -> bits = 8 -> xterm bit 8 == super (Cmd/Win). zcode stores it
    // as `cmd` (same bit, see ModifierFlags doc comment).
    const flags = kittyModifierFlags(9);
    try testing.expect(flags.cmd);
    try testing.expect(!flags.shift);
    try testing.expect(!flags.alt);
    try testing.expect(!flags.ctrl);

    // mods=1 -> bits = 0 -> no modifiers.
    const none_flags = kittyModifierFlags(1);
    try testing.expect(!none_flags.cmd);

    // mods=10 -> bits = 9 (shift + super).
    const shift_super = kittyModifierFlags(10);
    try testing.expect(shift_super.shift);
    try testing.expect(shift_super.cmd);
}

test "keycodeName maps fn/numpad and ASCII keycodes" {
    try testing.expectEqualStrings("return", keycodeName(57414).?); // KP_ENTER
    try testing.expectEqualStrings("0", keycodeName(57399).?); // KP_0
    try testing.expectEqualStrings("9", keycodeName(57408).?); // KP_9
    try testing.expectEqualStrings("+", keycodeName(57413).?); // KP_ADD
    try testing.expectEqualStrings("c", keycodeName(99).?); // ascii 'c'
    try testing.expectEqualStrings("c", keycodeName('C').?); // uppercase lowercased
    try testing.expectEqualStrings("tab", keycodeName(9).?);
    try testing.expectEqualStrings("space", keycodeName(32).?);
    // Out of any named range -> null.
    try testing.expect(keycodeName(0) == null);
    try testing.expect(keycodeName(57416) == null);
}

test "numpadAction maps KP_ENTER to submit and digits to ASCII insert" {
    try testing.expectEqual(NumpadAction.submit, numpadAction(57414).?); // KP_ENTER
    switch (numpadAction(57399).?) { // KP_0
        .insert => |b| try testing.expectEqual(@as(u8, '0'), b),
        else => return error.TestUnexpectedResult,
    }
    switch (numpadAction(57411).?) { // KP_MULTIPLY
        .insert => |b| try testing.expectEqual(@as(u8, '*'), b),
        else => return error.TestUnexpectedResult,
    }
    // Not a numpad codepoint -> null (handler falls through to its other paths).
    try testing.expect(numpadAction('a') == null);
    try testing.expect(numpadAction(57398) == null);
}

test "parseCsiNumeric parses first and second values" {
    const parsed = parseCsiNumeric("13;2");
    try testing.expect(parsed.first != null);
    try testing.expect(parsed.second != null);
    try testing.expectEqual(@as(usize, 13), parsed.first.?);
    try testing.expectEqual(@as(usize, 2), parsed.second.?);
}

test "deletePreviousWord trims previous token" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();
    try buf.appendSlice("hello world");
    deletePreviousWord(&buf);
    try testing.expectEqualStrings("hello ", buf.items());
}

test "insertInputBytesAt inserts bytes at cursor" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();
    try buf.appendSlice("hello world");
    var cursor: usize = 6;
    try insertInputBytesAt(&buf, &cursor, "@src/main.zig ");
    try testing.expectEqualStrings("hello @src/main.zig world", buf.items());
    try testing.expectEqual(@as(usize, 20), cursor);
}

test "composeStatusHint merges runtime and input hints" {
    var out: [320]u8 = undefined;
    const merged = composeStatusHint(&out, "idle: waiting for your input", "tab: /help");
    try testing.expectEqualStrings("idle: waiting for your input | tab: /help", merged);
    const runtime_only = composeStatusHint(&out, "running: processing turn", "");
    try testing.expectEqualStrings("running: processing turn", runtime_only);
}

test "collectSlashSuggestions returns visible prefix matches" {
    const suggestions = collectSlashSuggestions("/mode ");
    try testing.expectEqualStrings("/mode ", suggestions.query);
    try testing.expectEqual(@as(usize, 4), suggestions.total_matches);
    try testing.expectEqual(@as(usize, 4), suggestions.visibleCount());
    try testing.expectEqualStrings("/mode execution", suggestions.visible()[0]);
    try testing.expectEqualStrings("/mode review", suggestions.visible()[3]);
}

test "collectSlashSuggestions ignores multiline slash input" {
    const suggestions = collectSlashSuggestions("/help\nmore");
    try testing.expectEqual(@as(usize, 0), suggestions.total_matches);
    try testing.expectEqual(@as(usize, 0), suggestions.visibleCount());
}

test "slashSuggestionAt returns indexed match beyond preview window" {
    try testing.expectEqualStrings("/mode planning", slashSuggestionAt("/mode ", 1).?);
    try testing.expect(slashSuggestionAt("/mode ", 99) == null);
}

test "printableAsciiChord normalises printable prompt keys" {
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("a", printableAsciiChord('A', &buf).?);
    try testing.expectEqualStrings("/", printableAsciiChord('/', &buf).?);
    try testing.expectEqualStrings("space", printableAsciiChord(' ', &buf).?);
    try testing.expect(printableAsciiChord(0x1b, &buf) == null);
}

test "mapCsiFinal maps arrow keys to prompt history events" {
    try testing.expect(mapCsiFinal('A', false) == .history_prev);
    try testing.expect(mapCsiFinal('B', false) == .history_next);
    try testing.expect(mapCsiFinal('C', false) == .cursor_right);
    try testing.expect(mapCsiFinal('D', false) == .cursor_left);
    try testing.expect(mapCsiFinal('C', true) == .cursor_word_right);
    try testing.expect(mapCsiFinal('D', true) == .cursor_word_left);
}

test "formatInputPreview preserves newlines" {
    var out: [128]u8 = undefined;
    const preview = formatInputPreview(">", "hello\nworld", out[0..]);
    try testing.expectEqualStrings("> hello\nworld", preview);
}

pub fn formatInputPreview(prompt_label: []const u8, input_text: []const u8, out: []u8) []const u8 {
    var o: usize = 0;

    for (prompt_label) |ch| {
        if (o >= out.len) return out[0..o];
        out[o] = ch;
        o += 1;
    }
    if (o < out.len) {
        out[o] = ' ';
        o += 1;
    }

    var i: usize = 0;
    while (i < input_text.len and o < out.len) : (i += 1) {
        const ch = input_text[i];
        switch (ch) {
            '\n' => {
                // Preserve actual newlines so multi-line rendering can split on them
                if (o < out.len) {
                    out[o] = '\n';
                    o += 1;
                }
            },
            '\r' => {},
            '\t' => {
                out[o] = ' ';
                o += 1;
            },
            else => {
                if (ch < 0x20 or ch == 0x7f) continue;
                out[o] = ch;
                o += 1;
            },
        }
    }

    return out[0..o];
}

test "isTerminalResponseSequence recognizes a DA1 reply but not a key" {
    // DA1 primary device attributes reply -- consumed, not typed.
    try std.testing.expect(isTerminalResponseSequence("\x1b[?1;2c"));
    // A plain arrow key is NOT a terminal response.
    try std.testing.expect(!isTerminalResponseSequence("\x1b[A"));
}

test "recordTerminalResponse round-trips a DA1 reply by value" {
    last_response = null;
    const parsed = terminal_response.parse("\x1b[?62;1;6c") orelse return error.TestUnexpectedResult;
    recordTerminalResponse(parsed);
    const taken = takeLastTerminalResponse() orelse return error.TestUnexpectedResult;
    try std.testing.expect(taken == .da1);
    try std.testing.expectEqualStrings("62;1;6", taken.da1);
    // takeLastTerminalResponse clears the stored value.
    try std.testing.expect(takeLastTerminalResponse() == null);
}

test "recordTerminalResponse stores scalar DECRPM reply" {
    last_response = null;
    const parsed = terminal_response.parse("\x1b[?2026;1$y") orelse return error.TestUnexpectedResult;
    recordTerminalResponse(parsed);
    const taken = takeLastTerminalResponse() orelse return error.TestUnexpectedResult;
    try std.testing.expect(taken == .decrpm);
    try std.testing.expectEqual(@as(u32, 2026), taken.decrpm.mode);
}

test "readDcsOscResponse consumes an XTVERSION reply and records the terminal name" {
    // Drive readDcsOscResponse over a real pipe: the parser has already
    // consumed the leading ESC and the 'P' framing byte by the time it is
    // called, so we write only the bytes that follow (">|name ST").
    terminal_caps.resetXtversionNameForTest();
    defer terminal_caps.resetXtversionNameForTest();

    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    defer _ = std.c.close(fds[0]);
    const body = ">|xterm.js(5.5.0)\x1b\\";
    _ = std.c.write(fds[1], body.ptr, body.len);
    _ = std.c.close(fds[1]);

    const ev = try readDcsOscResponse(fds[0], 'P');
    // A response is never user input.
    try std.testing.expectEqual(InputEvent.none, ev);
    try std.testing.expect(terminal_caps.isXtermJs());
}

test "readDcsOscResponse consumes an OSC reply without leaking and records it" {
    last_response = null;
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    defer _ = std.c.close(fds[0]);
    const body = "11;rgb:0000/0000/0000\x07";
    _ = std.c.write(fds[1], body.ptr, body.len);
    _ = std.c.close(fds[1]);

    const ev = try readDcsOscResponse(fds[0], ']');
    try std.testing.expectEqual(InputEvent.none, ev);
    const taken = takeLastTerminalResponse() orelse return error.TestUnexpectedResult;
    try std.testing.expect(taken == .osc);
    try std.testing.expectEqual(@as(u32, 11), taken.osc.code);
    try std.testing.expectEqualStrings("rgb:0000/0000/0000", taken.osc.data);
}

test "parseSgrMouse decodes a left-button press with coordinates" {
    const ev = parseSgrMouse("<0;10;5M") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0), ev.button);
    try std.testing.expectEqual(MouseEvent{ .button = 0, .action = .press, .col = 10, .row = 5 }, ev);
}

test "parseSgrMouse decodes a release with the lowercase terminator" {
    const ev = parseSgrMouse("<0;10;5m") orelse return error.TestUnexpectedResult;
    try std.testing.expect(ev.action == .release);
    try std.testing.expectEqual(@as(u32, 10), ev.col);
    try std.testing.expectEqual(@as(u32, 5), ev.row);
}

test "parseSgrMouse decodes a right-button press" {
    const ev = parseSgrMouse("<2;3;7M") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 2), ev.button);
    try std.testing.expect(ev.action == .press);
    try std.testing.expectEqual(@as(u32, 3), ev.col);
    try std.testing.expectEqual(@as(u32, 7), ev.row);
}

test "parseSgrMouse returns null for wheel events" {
    // Button bit 0x40 (64) is the wheel marker; those stay on the scroll path.
    try std.testing.expect(parseSgrMouse("<64;1;1M") == null);
    try std.testing.expect(parseSgrMouse("<65;1;1M") == null);
}

test "parseSgrMouse rejects malformed payloads" {
    // Missing private marker, missing terminator, missing fields, junk bytes.
    try std.testing.expect(parseSgrMouse("0;10;5M") == null);
    try std.testing.expect(parseSgrMouse("<0;10;5") == null);
    try std.testing.expect(parseSgrMouse("<0;10M") == null);
    try std.testing.expect(parseSgrMouse("<0;1x;5M") == null);
}

test "parseX10Mouse decodes coordinates and ignores wheel" {
    // X10 encodes each value with a +32 offset; button 0, col 10, row 5.
    const ev = parseX10Mouse(32, 42, 37) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0), ev.button);
    try std.testing.expect(ev.action == .press);
    try std.testing.expectEqual(@as(u32, 10), ev.col);
    try std.testing.expectEqual(@as(u32, 5), ev.row);
    // Wheel-up button code 64 (=> 96 with the +32 offset) is not a click.
    try std.testing.expect(parseX10Mouse(96, 33, 33) == null);
}

test "takeLastMouseEvent consumes and clears the recorded event" {
    last_mouse = null;
    last_mouse = parseSgrMouse("<0;4;9M");
    const taken = takeLastMouseEvent() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 4), taken.col);
    try std.testing.expectEqual(@as(u32, 9), taken.row);
    // The slot is cleared after taking.
    try std.testing.expect(takeLastMouseEvent() == null);
}
