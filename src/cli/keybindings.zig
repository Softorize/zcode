const std = @import("std");
const builtin = @import("builtin");
const std_io = @import("../core/std_io.zig");
const rt = @import("zcode_runtime");
const paths = @import("../core/paths.zig");

/// Actions that can be triggered by key combinations.
pub const KeyAction = enum {
    submit,
    newline,
    cancel,
    escape,
    tab,
    shift_tab,
    scroll_up,
    scroll_down,
    history_prev,
    history_next,
    backspace,
    clear_line,
    delete_prev_word,
};

/// A single key descriptor parsed from configuration.
/// Represents a key combination like "ctrl+c" or "enter".
pub const KeyDescriptor = struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    key: []const u8 = "",
};

/// Maps each action to one or more key descriptors.
/// Default values match the current hardcoded behavior in repl_input.zig.
pub const Keybindings = struct {
    submit: []const []const u8 = &.{ "enter", "ctrl+m" },
    newline: []const []const u8 = &.{"shift+enter"},
    cancel: []const []const u8 = &.{ "ctrl+c", "ctrl+d" },
    escape: []const []const u8 = &.{"escape"},
    tab: []const []const u8 = &.{"tab"},
    shift_tab: []const []const u8 = &.{"shift+tab"},
    scroll_up: []const []const u8 = &.{ "up", "ctrl+p" },
    scroll_down: []const []const u8 = &.{ "down", "ctrl+n" },
    history_prev: []const []const u8 = &.{"up"},
    history_next: []const []const u8 = &.{"down"},
    backspace: []const []const u8 = &.{"backspace"},
    clear_line: []const []const u8 = &.{"ctrl+u"},
    delete_prev_word: []const []const u8 = &.{ "ctrl+w", "alt+backspace" },

    // Allocated copies that must be freed (null when using comptime defaults).
    _alloc_submit: ?[][]u8 = null,
    _alloc_newline: ?[][]u8 = null,
    _alloc_cancel: ?[][]u8 = null,
    _alloc_escape: ?[][]u8 = null,
    _alloc_tab: ?[][]u8 = null,
    _alloc_shift_tab: ?[][]u8 = null,
    _alloc_scroll_up: ?[][]u8 = null,
    _alloc_scroll_down: ?[][]u8 = null,
    _alloc_history_prev: ?[][]u8 = null,
    _alloc_history_next: ?[][]u8 = null,
    _alloc_backspace: ?[][]u8 = null,
    _alloc_clear_line: ?[][]u8 = null,
    _alloc_delete_prev_word: ?[][]u8 = null,

    pub fn deinit(self: *Keybindings, allocator: std.mem.Allocator) void {
        const alloc_fields = .{
            "_alloc_submit",
            "_alloc_newline",
            "_alloc_cancel",
            "_alloc_escape",
            "_alloc_tab",
            "_alloc_shift_tab",
            "_alloc_scroll_up",
            "_alloc_scroll_down",
            "_alloc_history_prev",
            "_alloc_history_next",
            "_alloc_backspace",
            "_alloc_clear_line",
            "_alloc_delete_prev_word",
        };
        inline for (alloc_fields) |field| {
            if (@field(self, field)) |items| {
                for (items) |item| allocator.free(item);
                allocator.free(items);
            }
        }
    }
};

/// Resolves the keybindings config path: ~/.zcode/keybindings.json
pub fn keybindingsPath(allocator: std.mem.Allocator) ![]u8 {
    const home = try @import("../core/env.zig").getOwned(allocator, "HOME");
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, paths.PRIMARY_HOME_DIR, "keybindings.json" });
}

/// Load keybindings from ~/.zcode/keybindings.json.
/// Returns defaults if the file does not exist or cannot be parsed.
/// Emits std.log warnings for any binding that references a reserved
/// key (see ReservedShortcut). Warnings are non-fatal: the rest of the
/// config still loads so one bad binding doesn't blow away the whole
/// keybindings.json.
pub fn loadKeybindings(allocator: std.mem.Allocator) Keybindings {
    const path = keybindingsPath(allocator) catch return .{};
    defer allocator.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(64 * 1024)) catch return .{};
    defer allocator.free(bytes);

    const kb = parseKeybindings(allocator, bytes);
    warnReservedConflicts(allocator, &kb);
    return kb;
}

/// Parse keybindings JSON. Returns defaults on any parse failure.
pub fn parseKeybindings(allocator: std.mem.Allocator, bytes: []const u8) Keybindings {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return .{};
    defer parsed.deinit();

    if (parsed.value != .object) return .{};

    var kb = Keybindings{};

    const action_fields = .{
        .{ "submit", "submit", "_alloc_submit" },
        .{ "newline", "newline", "_alloc_newline" },
        .{ "cancel", "cancel", "_alloc_cancel" },
        .{ "escape", "escape", "_alloc_escape" },
        .{ "tab", "tab", "_alloc_tab" },
        .{ "shift_tab", "shift_tab", "_alloc_shift_tab" },
        .{ "scroll_up", "scroll_up", "_alloc_scroll_up" },
        .{ "scroll_down", "scroll_down", "_alloc_scroll_down" },
        .{ "history_prev", "history_prev", "_alloc_history_prev" },
        .{ "history_next", "history_next", "_alloc_history_next" },
        .{ "backspace", "backspace", "_alloc_backspace" },
        .{ "clear_line", "clear_line", "_alloc_clear_line" },
        .{ "delete_prev_word", "delete_prev_word", "_alloc_delete_prev_word" },
    };

    inline for (action_fields) |entry| {
        const json_key = entry[0];
        const field_name = entry[1];
        const alloc_field = entry[2];

        if (parsed.value.object.get(json_key)) |val| {
            if (extractStringArray(allocator, val)) |strings| {
                // Build a const slice view for the public field.
                const const_view = toConstSlice(strings);
                @field(kb, field_name) = const_view;
                @field(kb, alloc_field) = strings;
            }
        }
    }

    return kb;
}

/// Convert [][]u8 to []const []const u8 by reinterpreting.
fn toConstSlice(items: [][]u8) []const []const u8 {
    const ptr: [*]const []const u8 = @ptrCast(items.ptr);
    return ptr[0..items.len];
}

/// Extract an array of strings (or a single string) from a JSON value.
fn extractStringArray(allocator: std.mem.Allocator, val: std.json.Value) ?[][]u8 {
    switch (val) {
        .string => |s| {
            const arr = allocator.alloc([]u8, 1) catch return null;
            arr[0] = allocator.dupe(u8, s) catch {
                allocator.free(arr);
                return null;
            };
            return arr;
        },
        .array => |a| {
            if (a.items.len == 0) return null;
            var out = std.array_list.Managed([]u8).init(allocator);
            for (a.items) |item| {
                if (item == .string) {
                    const dup = allocator.dupe(u8, item.string) catch continue;
                    out.append(dup) catch {
                        allocator.free(dup);
                        continue;
                    };
                }
            }
            if (out.items.len == 0) {
                out.deinit();
                return null;
            }
            return out.toOwnedSlice() catch {
                for (out.items) |s| allocator.free(s);
                out.deinit();
                return null;
            };
        },
        else => return null,
    }
}

/// Parse a key descriptor string like "ctrl+shift+a" into its components.
pub fn parseKeyDescriptor(raw: []const u8) KeyDescriptor {
    var desc = KeyDescriptor{};
    var remaining = raw;

    // Process modifier prefixes.
    while (true) {
        if (startsWithCaseInsensitive(remaining, "ctrl+")) {
            desc.ctrl = true;
            remaining = remaining[5..];
        } else if (startsWithCaseInsensitive(remaining, "alt+")) {
            desc.alt = true;
            remaining = remaining[4..];
        } else if (startsWithCaseInsensitive(remaining, "shift+")) {
            desc.shift = true;
            remaining = remaining[6..];
        } else {
            break;
        }
    }

    desc.key = remaining;
    return desc;
}

fn startsWithCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    for (haystack[0..needle.len], needle) |h, n| {
        if (std.ascii.toLower(h) != std.ascii.toLower(n)) return false;
    }
    return true;
}

// ---- Reserved shortcuts ---------------------------------------------------

/// A key that cannot (or should not) be rebound because something upstream
/// already owns it. Ported from claude-code-main/src/keybindings/
/// reservedShortcuts.ts. Severity distinguishes hard conflicts (NON_REBINDABLE,
/// which the app cannot honor even if the user writes them in JSON) from
/// soft warnings (TERMINAL_RESERVED, where the keystroke is intercepted
/// before it ever reaches the app).
pub const ReservedShortcut = struct {
    key: []const u8,
    reason: []const u8,
    severity: Severity,
    /// When non-null, the key is still allowed in this specific action slot
    /// (e.g. ctrl+m is allowed in 'submit' because that IS Enter). Used by
    /// warnReservedConflicts to suppress warnings on the canonical binding
    /// while still flagging cross-slot overrides.
    canonical_action: ?[]const u8 = null,

    pub const Severity = enum { @"error", warning };
};

/// Keys zcode hardcodes for specific actions -- binding them anywhere else
/// would silently disable the hardcoded behaviour. ctrl+c and ctrl+d are
/// how the REPL cancels a running turn and exits; ctrl+m is what the
/// terminal sends for the Enter key, so binding it to anything but submit
/// makes Enter itself stop working.
pub const NON_REBINDABLE = [_]ReservedShortcut{
    .{
        .key = "ctrl+c",
        .reason = "Cannot be rebound -- used for interrupt/exit (hardcoded)",
        .severity = .@"error",
        .canonical_action = "cancel",
    },
    .{
        .key = "ctrl+d",
        .reason = "Cannot be rebound -- used for exit (hardcoded)",
        .severity = .@"error",
        .canonical_action = "cancel",
    },
    .{
        .key = "ctrl+m",
        .reason = "Cannot be rebound -- identical to Enter in terminals (both send CR)",
        .severity = .@"error",
        .canonical_action = "submit",
    },
};

/// Keys the terminal or OS intercepts before the app sees them. Binding
/// to these is probably a user mistake -- we warn but don't refuse them.
/// ctrl+s (XOFF) and ctrl+q (XON) are deliberately omitted: modern
/// terminals disable XON/XOFF flow control by default, matching the
/// reference file's note at src/keybindings/reservedShortcuts.ts:40.
pub const TERMINAL_RESERVED = [_]ReservedShortcut{
    .{
        .key = "ctrl+z",
        .reason = "Unix process suspend (SIGTSTP)",
        .severity = .warning,
    },
    .{
        .key = "ctrl+\\",
        .reason = "Terminal quit signal (SIGQUIT)",
        .severity = .@"error",
    },
};

/// macOS-specific shortcuts the OS intercepts before the app sees them.
/// Only scanned when running on macOS (see findReservedConflict). Ported
/// from reservedShortcuts.ts MACOS_RESERVED. All error severity because the
/// OS swallows them unconditionally.
pub const MACOS_RESERVED = [_]ReservedShortcut{
    .{ .key = "cmd+c", .reason = "macOS system copy", .severity = .@"error" },
    .{ .key = "cmd+v", .reason = "macOS system paste", .severity = .@"error" },
    .{ .key = "cmd+x", .reason = "macOS system cut", .severity = .@"error" },
    .{ .key = "cmd+q", .reason = "macOS quit application", .severity = .@"error" },
    .{ .key = "cmd+w", .reason = "macOS close window/tab", .severity = .@"error" },
    .{ .key = "cmd+tab", .reason = "macOS app switcher", .severity = .@"error" },
    .{ .key = "cmd+space", .reason = "macOS Spotlight", .severity = .@"error" },
};

/// Normalize a key string so different spellings of the same chord
/// compare equal. Lowercases, rewrites aliases (control → ctrl,
/// option → alt, command → cmd), sorts modifiers, and preserves the
/// main key at the end: "CTRL+Shift+A" and "shift+ctrl+a" both become
/// "ctrl+shift+a". Ported from reservedShortcuts.ts normalizeStep.
fn normalizeKeystrokeForComparison(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    var modifiers = std.array_list.Managed([]const u8).init(allocator);
    defer modifiers.deinit();

    var main_key: []const u8 = "";
    var main_key_buf: [32]u8 = undefined;

    var parts = std.mem.splitScalar(u8, trimmed, '+');
    var lower_buf: [32]u8 = undefined;
    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t");
        if (part.len == 0 or part.len > lower_buf.len) {
            main_key = part;
            continue;
        }
        for (part, 0..) |ch, i| lower_buf[i] = std.ascii.toLower(ch);
        const lower = lower_buf[0..part.len];

        const canonical_modifier: ?[]const u8 = if (std.mem.eql(u8, lower, "ctrl") or std.mem.eql(u8, lower, "control"))
            "ctrl"
        else if (std.mem.eql(u8, lower, "alt") or std.mem.eql(u8, lower, "option") or std.mem.eql(u8, lower, "opt"))
            "alt"
        else if (std.mem.eql(u8, lower, "cmd") or std.mem.eql(u8, lower, "command") or std.mem.eql(u8, lower, "meta"))
            "cmd"
        else if (std.mem.eql(u8, lower, "shift"))
            "shift"
        else
            null;

        if (canonical_modifier) |m| {
            try modifiers.append(m);
        } else {
            // Not a modifier -- copy/lower it into a stable local buffer
            // so lower_buf reuse does not invalidate the slice.
            if (std.mem.eql(u8, lower, "esc")) {
                main_key = "escape";
            } else if (std.mem.eql(u8, lower, "return")) {
                main_key = "enter";
            } else if (std.mem.eql(u8, lower, "space")) {
                main_key = "space";
            } else {
                @memcpy(main_key_buf[0..lower.len], lower);
                main_key = main_key_buf[0..lower.len];
            }
        }
    }

    std.mem.sort([]const u8, modifiers.items, {}, modifierLessThan);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    for (modifiers.items, 0..) |m, i| {
        if (i > 0) try out.append('+');
        try out.appendSlice(m);
    }
    if (main_key.len > 0) {
        if (modifiers.items.len > 0) try out.append('+');
        try out.appendSlice(main_key);
    }
    return out.toOwnedSlice();
}

pub fn normalizeKeyForComparison(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return allocator.dupe(u8, "");

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
    var first = true;
    while (parts.next()) |part| {
        const normalized = try normalizeKeystrokeForComparison(allocator, part);
        defer allocator.free(normalized);
        if (!first) try out.append(' ');
        try out.appendSlice(normalized);
        first = false;
    }

    return out.toOwnedSlice();
}

fn modifierLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Platform selector for reserved-shortcut scanning. Lets tests exercise the
/// macOS branch deterministically regardless of the host OS.
pub const Platform = enum { macos, other };

/// Returns the ReservedShortcut that matches `key` (after normalisation),
/// or null if the key is not reserved. Checks NON_REBINDABLE first so that
/// harder conflicts take precedence over soft terminal warnings. The
/// MACOS_RESERVED table is only scanned when `platform == .macos`.
pub fn findReservedConflictForPlatform(allocator: std.mem.Allocator, platform: Platform, key: []const u8) !?ReservedShortcut {
    const normalized = try normalizeKeyForComparison(allocator, key);
    defer allocator.free(normalized);

    inline for (&[_][]const ReservedShortcut{ &NON_REBINDABLE, &TERMINAL_RESERVED }) |table| {
        for (table) |entry| {
            const entry_norm = try normalizeKeyForComparison(allocator, entry.key);
            defer allocator.free(entry_norm);
            if (std.mem.eql(u8, normalized, entry_norm)) return entry;
        }
    }

    if (platform == .macos) {
        for (MACOS_RESERVED) |entry| {
            const entry_norm = try normalizeKeyForComparison(allocator, entry.key);
            defer allocator.free(entry_norm);
            if (std.mem.eql(u8, normalized, entry_norm)) return entry;
        }
    }
    return null;
}

/// Returns the ReservedShortcut that matches `key` (after normalisation),
/// or null if the key is not reserved. Checks NON_REBINDABLE first so that
/// harder conflicts take precedence over soft terminal warnings. On macOS the
/// MACOS_RESERVED table is also scanned (comptime-selected -- no runtime
/// platform call needed).
pub fn findReservedConflict(allocator: std.mem.Allocator, key: []const u8) !?ReservedShortcut {
    const platform: Platform = if (builtin.os.tag == .macos) .macos else .other;
    return findReservedConflictForPlatform(allocator, platform, key);
}

/// Scan an already-parsed Keybindings for any user-overridden actions that
/// reference a reserved key, and log warnings. Pure-stderr side-effects --
/// we don't mutate the config; warnings let the user fix their JSON
/// without bricking the session. A NON_REBINDABLE key in its
/// `canonical_action` slot is silent (that's the expected binding);
/// appearing anywhere else raises an error-severity warning.
pub fn warnReservedConflicts(allocator: std.mem.Allocator, kb: *const Keybindings) void {
    const all_slots = [_]struct { name: []const u8, bindings: []const []const u8 }{
        .{ .name = "submit", .bindings = kb.submit },
        .{ .name = "newline", .bindings = kb.newline },
        .{ .name = "cancel", .bindings = kb.cancel },
        .{ .name = "escape", .bindings = kb.escape },
        .{ .name = "tab", .bindings = kb.tab },
        .{ .name = "shift_tab", .bindings = kb.shift_tab },
        .{ .name = "scroll_up", .bindings = kb.scroll_up },
        .{ .name = "scroll_down", .bindings = kb.scroll_down },
        .{ .name = "history_prev", .bindings = kb.history_prev },
        .{ .name = "history_next", .bindings = kb.history_next },
        .{ .name = "backspace", .bindings = kb.backspace },
        .{ .name = "clear_line", .bindings = kb.clear_line },
        .{ .name = "delete_prev_word", .bindings = kb.delete_prev_word },
    };

    for (all_slots) |slot| {
        for (slot.bindings) |key| {
            const conflict = findReservedConflict(allocator, key) catch continue;
            if (conflict) |c| {
                // Silent when the key is in its canonical slot.
                if (c.canonical_action) |canon| {
                    if (std.mem.eql(u8, canon, slot.name)) continue;
                }
                switch (c.severity) {
                    .@"error" => std.log.warn(
                        "keybindings: '{s}' bound to action '{s}' is non-rebindable ({s}); zcode will ignore the override",
                        .{ key, slot.name, c.reason },
                    ),
                    .warning => std.log.warn(
                        "keybindings: '{s}' bound to action '{s}' may be swallowed by the terminal ({s})",
                        .{ key, slot.name, c.reason },
                    ),
                }
            }
        }
    }
}

/// macOS Option+key emits special Unicode characters when the
/// terminal has "Use Option as Meta key" disabled (the default in
/// Terminal.app and iTerm2 out of the box). Instead of a proper
/// ESC-prefixed byte, the shell receives e.g. `π` for Option+P.
/// zcode's key-input path would otherwise treat those as normal
/// characters and insert them into the input buffer, silently
/// swallowing any Alt+X keybinding the user tried to trigger.
///
/// This helper maps the three special chars that the reference
/// (claude-code-main/src/utils/keyboardShortcuts.ts
/// MACOS_OPTION_SPECIAL_CHARS) tracks back to their alt+<letter>
/// keybinding names. Callers iterating over the input byte stream
/// can decode the UTF-8 codepoint and consult this helper to
/// distinguish "user typed a diaeresis" from "user hit Option+T".
///
/// Returns the canonical key name (e.g. "alt+t") on a match, or
/// null when the codepoint is not one we recognise. Adding new
/// entries is a one-line change.
pub fn isMacosOptionChar(codepoint: u21) ?[]const u8 {
    return switch (codepoint) {
        // † U+2020 DAGGER -- Option+T on US Mac layout, used by the
        // reference for the "thinking toggle" shortcut.
        0x2020 => "alt+t",
        // π U+03C0 GREEK SMALL LETTER PI -- Option+P, used for the
        // model picker shortcut.
        0x03C0 => "alt+p",
        // ø U+00F8 LATIN SMALL LETTER O WITH STROKE -- Option+O,
        // used for the fast-mode toggle.
        0x00F8 => "alt+o",
        else => null,
    };
}

pub const BindingContext = enum {
    Global,
    Chat,
    Autocomplete,
    PromptSuggestions,
    PromptQueue,
    PromptStash,
    PromptNotifications,
    Attachments,
    Footer,
    Confirmation,
    Transcript,
    HistorySearch,
    ThemePicker,
    ModelPicker,
    ThinkingDialog,
    AutoModeDialog,
    TeamsDialog,
    BridgeDialog,
    Select,
    MessageSelector,
    MessageActions,
};

pub const BindingAction = enum {
    app_interrupt,
    app_toggle_todos,
    app_toggle_transcript,
    app_toggle_brief,
    app_redraw,
    app_global_search,
    app_quick_open,
    history_search,
    history_previous,
    history_next,
    chat_cycle_mode,
    chat_command_palette,
    chat_session_switcher,
    chat_model_picker,
    chat_theme_picker,
    chat_runtime_panel,
    chat_density_toggle,
    chat_fast_mode,
    chat_thinking_toggle,
    chat_submit,
    chat_newline,
    chat_undo,
    chat_external_editor,
    chat_kill_agents,
    chat_stash,
    chat_image_paste,
    chat_message_actions,
    chat_clear_line,
    chat_delete_prev_word,
    chat_backspace,
    autocomplete_accept,
    autocomplete_dismiss,
    autocomplete_previous,
    autocomplete_next,
    prompt_previous,
    prompt_next,
    prompt_open,
    prompt_dismiss,
    prompt_exit,
    attachments_next,
    attachments_previous,
    attachments_remove,
    attachments_exit,
    footer_up,
    footer_down,
    footer_next,
    footer_previous,
    footer_open_selected,
    footer_clear_selection,
    footer_close,
    confirm_yes,
    confirm_no,
    confirm_previous,
    confirm_next,
    confirm_next_field,
    confirm_toggle,
    confirm_cycle_mode,
    confirm_toggle_explanation,
    permission_toggle_debug,
    transcript_toggle_show_all,
    transcript_exit,
    history_search_next,
    history_search_accept,
    history_search_cancel,
    history_search_execute,
    theme_toggle_syntax,
    select_previous,
    select_next,
    select_accept,
    select_cancel,
    message_selector_up,
    message_selector_down,
    message_selector_top,
    message_selector_bottom,
    message_selector_select,
    message_actions_prev,
    message_actions_next,
    message_actions_top,
    message_actions_bottom,
    message_actions_prev_user,
    message_actions_next_user,
    message_actions_cancel,
    message_actions_accept,
    message_actions_copy,
};

pub const RuntimeBinding = struct {
    context: BindingContext,
    key: []u8,
    action: ?BindingAction = null,
    command: ?[]u8 = null,
};

const DefaultBinding = struct {
    key: []const u8,
    action: BindingAction,
};

pub const RuntimeLookup = struct {
    handled: bool = false,
    action: ?BindingAction = null,
    command: ?[]const u8 = null,
};

pub const RuntimeChordLookup = struct {
    result: enum {
        none,
        match,
        chord_started,
        chord_cancelled,
    } = .none,
    action: ?BindingAction = null,
    command: ?[]const u8 = null,
};

pub const RuntimeLoadStatus = enum {
    loaded_file,
    defaults_missing_file,
    defaults_parse_error,
};

/// A structured validation issue found while loading a user keybindings file.
/// Mirrors the reference KeybindingWarning (validate.ts:16-34). Unlike the
/// reserved-conflict path (which only emits log lines), these are collected so
/// /doctor and the reload notice can show what was wrong with the config.
/// `message` is owned by the warning and freed on list deinit; `key`/`context`
/// are owned slices too (null when not applicable).
pub const KeybindingWarning = struct {
    kind: Kind,
    severity: Severity,
    message: []u8,
    key: ?[]u8 = null,
    context: ?[]u8 = null,

    pub const Kind = enum {
        parse_error,
        duplicate,
        invalid_context,
        invalid_action,
        reserved_conflict,
    };

    pub const Severity = enum { @"error", warning };

    fn deinit(self: *KeybindingWarning, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        if (self.key) |k| allocator.free(k);
        if (self.context) |c| allocator.free(c);
        self.* = undefined;
    }
};

/// Owned list of KeybindingWarning. Frees each warning's strings on deinit.
pub const KeybindingWarnings = struct {
    items: []KeybindingWarning = &.{},

    pub fn deinit(self: *KeybindingWarnings, allocator: std.mem.Allocator) void {
        for (self.items) |*w| w.deinit(allocator);
        allocator.free(self.items);
        self.* = .{};
    }

    fn append(self: *KeybindingWarnings, allocator: std.mem.Allocator, w: KeybindingWarning) !void {
        const next_len = self.items.len + 1;
        self.items = try allocator.realloc(self.items, next_len);
        self.items[next_len - 1] = w;
    }

    pub fn errorCount(self: *const KeybindingWarnings) usize {
        var n: usize = 0;
        for (self.items) |w| {
            if (w.severity == .@"error") n += 1;
        }
        return n;
    }
};

pub const RuntimeLoadReport = struct {
    keybindings: RuntimeKeybindings,
    status: RuntimeLoadStatus,
    warning_count: usize = 0,
    /// Structured validation warnings (parse_error / duplicate /
    /// invalid_context / invalid_action). Empty for defaults / parse-failure
    /// statuses. Owned -- caller must call `deinit`.
    warnings: KeybindingWarnings = .{},

    pub fn deinit(self: *RuntimeLoadReport, allocator: std.mem.Allocator) void {
        self.warnings.deinit(allocator);
        self.keybindings.deinit(allocator);
    }
};

pub const RuntimeKeybindings = struct {
    entries: []RuntimeBinding = &.{},
    owned: bool = false,

    pub fn deinit(self: *RuntimeKeybindings, allocator: std.mem.Allocator) void {
        if (!self.owned) return;
        for (self.entries) |entry| {
            allocator.free(entry.key);
            if (entry.command) |command| allocator.free(command);
        }
        allocator.free(self.entries);
        self.* = .{};
    }

    pub fn lookup(self: *const RuntimeKeybindings, contexts: []const BindingContext, chord: []const u8) RuntimeLookup {
        if (lookupRuntimeBindingWithContexts(self.entries, contexts, chord)) |binding| {
            return .{ .handled = true, .action = binding.action, .command = binding.command };
        }
        if (self.entries.len == 0) {
            for (contexts) |context| {
                if (defaultActionFor(context, chord)) |action| {
                    return .{ .handled = true, .action = action };
                }
            }
        }
        return .{};
    }

    pub fn resolveChord(
        self: *const RuntimeKeybindings,
        contexts: []const BindingContext,
        pending: ?[]const u8,
        chord: []const u8,
    ) RuntimeChordLookup {
        var combined_buf: [256]u8 = undefined;
        const test_chord = if (pending) |prefix|
            std.fmt.bufPrint(&combined_buf, "{s} {s}", .{ prefix, chord }) catch
                return .{ .result = .chord_cancelled }
        else
            chord;

        if (hasLongerChordPrefix(self.entries, contexts, test_chord)) {
            return .{ .result = .chord_started };
        }

        if (lookupRuntimeBindingWithContexts(self.entries, contexts, test_chord)) |binding| {
            return .{
                .result = .match,
                .action = binding.action,
                .command = binding.command,
            };
        }

        if (self.entries.len == 0) {
            for (contexts) |context| {
                if (defaultActionFor(context, test_chord)) |action| {
                    return .{
                        .result = .match,
                        .action = action,
                    };
                }
            }
        }

        return if (pending != null)
            .{ .result = .chord_cancelled }
        else
            .{};
    }
};

pub fn loadRuntimeKeybindings(allocator: std.mem.Allocator) RuntimeKeybindings {
    var report = loadRuntimeKeybindingsReport(allocator);
    // Caller only wants the bindings; free the validation warnings the report
    // owns so they do not leak. The keybindings are moved out, not freed.
    report.warnings.deinit(allocator);
    return report.keybindings;
}

pub fn loadRuntimeKeybindingsReport(allocator: std.mem.Allocator) RuntimeLoadReport {
    const path = keybindingsPath(allocator) catch {
        return .{
            .keybindings = defaultRuntimeKeybindings(allocator) catch .{},
            .status = .defaults_missing_file,
            .warning_count = 0,
        };
    };
    defer allocator.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(64 * 1024)) catch {
        return .{
            .keybindings = defaultRuntimeKeybindings(allocator) catch .{},
            .status = .defaults_missing_file,
            .warning_count = 0,
        };
    };
    defer allocator.free(bytes);

    var parsed_check = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        return .{
            .keybindings = defaultRuntimeKeybindings(allocator) catch .{},
            .status = .defaults_parse_error,
            .warning_count = 0,
        };
    };
    parsed_check.deinit();

    const kb = parseRuntimeKeybindings(allocator, bytes) catch {
        return .{
            .keybindings = defaultRuntimeKeybindings(allocator) catch .{},
            .status = .defaults_parse_error,
            .warning_count = 0,
        };
    };
    const warning_count = warnRuntimeReservedConflicts(allocator, &kb);
    // Collect structured validation warnings (parse_error / duplicate /
    // invalid_context / invalid_action) over the same bytes. Best-effort:
    // an OOM here must not fail the load, so fall back to an empty list.
    const warnings = collectKeybindingWarnings(allocator, bytes) catch KeybindingWarnings{};
    return .{
        .keybindings = kb,
        .status = .loaded_file,
        .warning_count = warning_count,
        .warnings = warnings,
    };
}

pub fn parseRuntimeKeybindings(allocator: std.mem.Allocator, bytes: []const u8) !RuntimeKeybindings {
    var out = try defaultRuntimeKeybindings(allocator);
    errdefer out.deinit(allocator);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return out;
    defer parsed.deinit();

    if (parsed.value != .object) return out;
    const root = parsed.value.object;
    const bindings_val = root.get("bindings") orelse return out;
    if (bindings_val != .array) return out;

    for (bindings_val.array.items) |block_val| {
        if (block_val != .object) continue;
        const context_val = block_val.object.get("context") orelse continue;
        const map_val = block_val.object.get("bindings") orelse continue;
        if (context_val != .string or map_val != .object) continue;

        const context = parseBindingContext(context_val.string) orelse continue;
        var it = map_val.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            if (value == .null) {
                try addOrReplaceRuntimeBinding(&out, allocator, context, key, null, null);
                continue;
            }
            if (value != .string) continue;
            if (parseCommandBinding(context, value.string)) |command| {
                try addOrReplaceRuntimeBinding(&out, allocator, context, key, null, command);
                continue;
            }
            const action = parseBindingAction(context, value.string) orelse continue;
            try addOrReplaceRuntimeBinding(&out, allocator, context, key, action, null);
        }
    }

    return out;
}

/// Validate a user keybindings file and collect structured warnings.
///
/// Ported from the reference validate.ts (validateUserConfig / validateBlock /
/// checkDuplicateKeysInJson). The zcode runtime parser
/// (`parseRuntimeKeybindings`) deliberately skips anything it does not
/// understand so a bad entry never crashes the REPL; this pass re-walks the
/// same bytes and records *why* an entry was skipped so /doctor and the reload
/// notice can surface it. The two passes share no state on purpose: validation
/// is allowed to allocate freely and report everything, while the runtime
/// parser stays allocation-frugal and silent.
///
/// Caller owns the returned list and must call `deinit`.
pub fn collectKeybindingWarnings(allocator: std.mem.Allocator, bytes: []const u8) !KeybindingWarnings {
    var warnings = KeybindingWarnings{};
    errdefer warnings.deinit(allocator);

    // Run the raw-text duplicate scan FIRST so it works even when std.json
    // rejects the file. std.json's default duplicate_field_behavior is
    // `.@"error"`, so a repeated key makes parseFromSlice fail outright --
    // exactly the case where the user most needs the duplicate warning. The
    // raw scan does not depend on a successful parse.
    try collectDuplicateKeyWarnings(&warnings, allocator, bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        // A hard parse failure is reported by RuntimeLoadStatus.defaults_parse_error;
        // collecting per-binding warnings on unparseable JSON is not meaningful
        // beyond the duplicate scan above.
        return warnings;
    };
    defer parsed.deinit();

    if (parsed.value != .object) return warnings;
    const root = parsed.value.object;
    const bindings_val = root.get("bindings") orelse return warnings;
    if (bindings_val != .array) return warnings;

    for (bindings_val.array.items, 0..) |block_val, block_index| {
        if (block_val != .object) {
            try appendWarning(&warnings, allocator, .{
                .kind = .parse_error,
                .severity = .@"error",
                .message_fmt = "keybinding block {d} is not an object",
                .message_args = .{block_index + 1},
            });
            continue;
        }

        // Resolve and validate the context up front so binding warnings can
        // carry it.
        var context_name: ?[]const u8 = null;
        const context_val = block_val.object.get("context");
        if (context_val == null or context_val.? != .string) {
            try appendWarning(&warnings, allocator, .{
                .kind = .parse_error,
                .severity = .@"error",
                .message_fmt = "keybinding block {d} missing \"context\" field",
                .message_args = .{block_index + 1},
            });
        } else if (parseBindingContext(context_val.?.string) == null) {
            try appendWarning(&warnings, allocator, .{
                .kind = .invalid_context,
                .severity = .@"error",
                .message_fmt = "unknown context \"{s}\"",
                .message_args = .{context_val.?.string},
                .context = context_val.?.string,
            });
        } else {
            context_name = context_val.?.string;
        }

        const map_val = block_val.object.get("bindings");
        if (map_val == null or map_val.? != .object) {
            try appendWarning(&warnings, allocator, .{
                .kind = .parse_error,
                .severity = .@"error",
                .message_fmt = "keybinding block {d} missing \"bindings\" field",
                .message_args = .{block_index + 1},
            });
            continue;
        }

        // Resolve the context enum once for action validation (only when the
        // context was valid; otherwise we already reported invalid_context and
        // skip per-binding action checks for this block).
        const ctx_enum: ?BindingContext = if (context_name) |cn| parseBindingContext(cn) else null;

        var it = map_val.?.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;

            // null = unbind; always valid.
            if (value == .null) continue;

            if (value != .string) {
                try appendWarning(&warnings, allocator, .{
                    .kind = .invalid_action,
                    .severity = .@"error",
                    .message_fmt = "invalid action for \"{s}\": must be a string or null",
                    .message_args = .{key},
                    .key = key,
                    .context = context_name,
                });
                continue;
            }

            // Skip action resolution when the context itself was invalid: the
            // user's real problem is the context, not the action.
            const ctx = ctx_enum orelse continue;

            if (parseCommandBinding(ctx, value.string) != null) continue;
            // A "command:" prefix in a non-Chat context (or malformed command
            // name) returns null from parseCommandBinding; flag it distinctly.
            if (std.mem.startsWith(u8, value.string, "command:")) {
                try appendWarning(&warnings, allocator, .{
                    .kind = .invalid_action,
                    .severity = .warning,
                    .message_fmt = "invalid command binding \"{s}\" for \"{s}\" in context \"{s}\"",
                    .message_args = .{ value.string, key, context_name.? },
                    .key = key,
                    .context = context_name,
                });
                continue;
            }
            if (parseBindingAction(ctx, value.string) == null) {
                try appendWarning(&warnings, allocator, .{
                    .kind = .invalid_action,
                    .severity = .@"error",
                    .message_fmt = "unknown action \"{s}\" for \"{s}\" in context \"{s}\"",
                    .message_args = .{ value.string, key, context_name.? },
                    .key = key,
                    .context = context_name,
                });
            }
        }
    }

    return warnings;
}

/// Normalize a slice spec field that may be either `[]const u8` or
/// `?[]const u8` into `?[]const u8` so callers can pass either form.
fn optionalSlice(value: anytype) ?[]const u8 {
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => value,
        else => @as([]const u8, value),
    };
}

/// Description of a warning to format and append. message_args is an anytype
/// tuple matching message_fmt; key/context are borrowed and duped on append.
fn appendWarning(
    warnings: *KeybindingWarnings,
    allocator: std.mem.Allocator,
    spec: anytype,
) !void {
    const message = try std.fmt.allocPrint(allocator, spec.message_fmt, spec.message_args);
    errdefer allocator.free(message);

    var key_copy: ?[]u8 = null;
    if (@hasField(@TypeOf(spec), "key")) {
        if (optionalSlice(@field(spec, "key"))) |k| key_copy = try allocator.dupe(u8, k);
    }
    errdefer if (key_copy) |k| allocator.free(k);

    var context_copy: ?[]u8 = null;
    if (@hasField(@TypeOf(spec), "context")) {
        if (optionalSlice(@field(spec, "context"))) |c| context_copy = try allocator.dupe(u8, c);
    }
    errdefer if (context_copy) |c| allocator.free(c);

    try warnings.append(allocator, .{
        .kind = spec.kind,
        .severity = spec.severity,
        .message = message,
        .key = key_copy,
        .context = context_copy,
    });
}

/// Scan the raw JSON text for keys that appear more than once inside a single
/// `"bindings": { ... }` block. JSON parsers keep only the last value for a
/// duplicated key, so the parsed map cannot detect this -- only a raw-text scan
/// can. Ported from validate.ts:258-307 (checkDuplicateKeysInJson). The
/// reference uses a balanced-brace regex; we do a simple bracket walk that
/// stays inside the immediate bindings object and skips nested braces.
fn collectDuplicateKeyWarnings(
    warnings: *KeybindingWarnings,
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !void {
    const needle = "\"bindings\"";
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, search_from, needle)) |hit| {
        // Find the '{' that opens this bindings object (skipping the ':' and
        // whitespace). If we hit a non-'{' first, this is the top-level
        // "bindings": [ array, not a block object -- skip it.
        var i = hit + needle.len;
        while (i < bytes.len and (bytes[i] == ' ' or bytes[i] == '\t' or bytes[i] == '\n' or bytes[i] == '\r' or bytes[i] == ':')) : (i += 1) {}
        if (i >= bytes.len or bytes[i] != '{') {
            search_from = hit + needle.len;
            continue;
        }
        const block_start = i + 1;

        // Walk to the matching close brace, tracking depth and skipping
        // string contents so braces inside quoted values do not confuse us.
        var depth: usize = 1;
        var j = block_start;
        var in_string = false;
        var escaped = false;
        var block_end = bytes.len;
        while (j < bytes.len) : (j += 1) {
            const ch = bytes[j];
            if (in_string) {
                if (escaped) {
                    escaped = false;
                } else if (ch == '\\') {
                    escaped = true;
                } else if (ch == '"') {
                    in_string = false;
                }
                continue;
            }
            switch (ch) {
                '"' => in_string = true,
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) {
                        block_end = j;
                        break;
                    }
                },
                else => {},
            }
        }

        const context_name = findEnclosingContext(bytes, hit);
        try scanBlockForDuplicateKeys(warnings, allocator, bytes[block_start..block_end], context_name);
        search_from = block_end + 1;
    }
}

/// Look backwards from `before` for the most recent `"context": "<name>"`
/// declaration so a duplicate warning can name the affected context. Returns
/// "unknown" when no context precedes the block.
fn findEnclosingContext(bytes: []const u8, before: usize) []const u8 {
    const slice = bytes[0..before];
    const ctx_needle = "\"context\"";
    var last: ?usize = null;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, slice, from, ctx_needle)) |hit| {
        last = hit;
        from = hit + ctx_needle.len;
    }
    const ctx_hit = last orelse return "unknown";
    var i = ctx_hit + ctx_needle.len;
    while (i < slice.len and (slice[i] == ' ' or slice[i] == '\t' or slice[i] == ':')) : (i += 1) {}
    if (i >= slice.len or slice[i] != '"') return "unknown";
    const val_start = i + 1;
    const val_end = std.mem.indexOfScalarPos(u8, slice, val_start, '"') orelse return "unknown";
    return slice[val_start..val_end];
}

/// Find keys that appear more than once at the top level of a single bindings
/// block (one warning per duplicated key, on the second occurrence). Skips
/// keys inside nested objects so only direct key collisions count.
fn scanBlockForDuplicateKeys(
    warnings: *KeybindingWarnings,
    allocator: std.mem.Allocator,
    block: []const u8,
    context_name: []const u8,
) !void {
    // Track seen keys (owned dupes) so we warn exactly once per repeat.
    var seen = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (seen.items) |s| allocator.free(s);
        seen.deinit();
    }

    var i: usize = 0;
    var depth: usize = 0;
    while (i < block.len) {
        const ch = block[i];
        if (ch == '{' or ch == '[') {
            depth += 1;
            i += 1;
            continue;
        }
        if (ch == '}' or ch == ']') {
            if (depth > 0) depth -= 1;
            i += 1;
            continue;
        }
        if (ch != '"') {
            i += 1;
            continue;
        }

        // Parse a quoted token.
        const key_start = i + 1;
        var j = key_start;
        var escaped = false;
        while (j < block.len) : (j += 1) {
            if (escaped) {
                escaped = false;
            } else if (block[j] == '\\') {
                escaped = true;
            } else if (block[j] == '"') {
                break;
            }
        }
        const token = block[key_start..j];
        i = j + 1;

        // Only a token immediately followed by ':' at depth 0 is a binding key.
        var k = i;
        while (k < block.len and (block[k] == ' ' or block[k] == '\t' or block[k] == '\n' or block[k] == '\r')) : (k += 1) {}
        const is_key = k < block.len and block[k] == ':';
        if (depth != 0 or !is_key) continue;

        var already_seen = false;
        for (seen.items) |s| {
            if (std.mem.eql(u8, s, token)) {
                already_seen = true;
                break;
            }
        }
        if (already_seen) {
            try appendWarning(warnings, allocator, .{
                .kind = .duplicate,
                .severity = .warning,
                .message_fmt = "duplicate key \"{s}\" in {s} bindings",
                .message_args = .{ token, context_name },
                .key = token,
                .context = context_name,
            });
        } else {
            try seen.append(try allocator.dupe(u8, token));
        }
    }
}

fn defaultRuntimeKeybindings(allocator: std.mem.Allocator) !RuntimeKeybindings {
    var out = RuntimeKeybindings{
        .entries = try allocator.alloc(RuntimeBinding, 0),
        .owned = true,
    };
    errdefer out.deinit(allocator);

    const defaults = [_]struct {
        context: BindingContext,
        key: []const u8,
        action: BindingAction,
    }{
        .{ .context = .Global, .key = "ctrl+r", .action = .history_search },
        .{ .context = .Global, .key = "ctrl+o", .action = .app_toggle_transcript },
        .{ .context = .Global, .key = "ctrl+t", .action = .app_toggle_todos },
        .{ .context = .Global, .key = "ctrl+b", .action = .app_toggle_brief },
        .{ .context = .Global, .key = "ctrl+shift+b", .action = .app_toggle_brief },
        .{ .context = .Global, .key = "ctrl+l", .action = .app_redraw },
        .{ .context = .Global, .key = "ctrl+f", .action = .app_global_search },
        .{ .context = .Global, .key = "ctrl+shift+f", .action = .app_global_search },
        .{ .context = .Global, .key = "cmd+shift+f", .action = .app_global_search },
        .{ .context = .Global, .key = "ctrl+p", .action = .app_quick_open },
        .{ .context = .Global, .key = "ctrl+shift+p", .action = .app_quick_open },
        .{ .context = .Global, .key = "cmd+shift+p", .action = .app_quick_open },
        .{ .context = .Chat, .key = "enter", .action = .chat_submit },
        .{ .context = .Chat, .key = "shift+enter", .action = .chat_newline },
        .{ .context = .Chat, .key = "shift+tab", .action = .chat_cycle_mode },
        .{ .context = .Chat, .key = "tab tab", .action = .chat_density_toggle },
        .{ .context = .Chat, .key = "up", .action = .history_previous },
        .{ .context = .Chat, .key = "down", .action = .history_next },
        .{ .context = .Chat, .key = "ctrl+x ctrl+e", .action = .chat_external_editor },
        .{ .context = .Chat, .key = "ctrl+x ctrl+k", .action = .chat_kill_agents },
        .{ .context = .Chat, .key = "ctrl+g", .action = .chat_external_editor },
        .{ .context = .Chat, .key = "ctrl+s", .action = .chat_stash },
        .{ .context = .Chat, .key = "ctrl+v", .action = .chat_image_paste },
        .{ .context = .Chat, .key = "shift+up", .action = .chat_message_actions },
        .{ .context = .Chat, .key = "alt+p", .action = .chat_model_picker },
        .{ .context = .Chat, .key = "alt+o", .action = .chat_fast_mode },
        .{ .context = .Chat, .key = "alt+t", .action = .chat_thinking_toggle },
        .{ .context = .Chat, .key = "ctrl+_", .action = .chat_undo },
        .{ .context = .Chat, .key = "ctrl+shift+-", .action = .chat_undo },
        .{ .context = .Chat, .key = "ctrl+u", .action = .chat_clear_line },
        .{ .context = .Chat, .key = "cmd+backspace", .action = .chat_clear_line },
        .{ .context = .Chat, .key = "ctrl+w", .action = .chat_delete_prev_word },
        .{ .context = .Chat, .key = "alt+backspace", .action = .chat_delete_prev_word },
        .{ .context = .Chat, .key = "backspace", .action = .chat_backspace },
        .{ .context = .Autocomplete, .key = "tab", .action = .autocomplete_accept },
        .{ .context = .Autocomplete, .key = "escape", .action = .autocomplete_dismiss },
        .{ .context = .Autocomplete, .key = "up", .action = .autocomplete_previous },
        .{ .context = .Autocomplete, .key = "down", .action = .autocomplete_next },
        .{ .context = .PromptSuggestions, .key = "up", .action = .prompt_previous },
        .{ .context = .PromptSuggestions, .key = "down", .action = .prompt_next },
        .{ .context = .PromptSuggestions, .key = "ctrl+p", .action = .prompt_previous },
        .{ .context = .PromptSuggestions, .key = "ctrl+n", .action = .prompt_next },
        .{ .context = .PromptSuggestions, .key = "enter", .action = .prompt_open },
        .{ .context = .PromptSuggestions, .key = "tab", .action = .prompt_open },
        .{ .context = .PromptSuggestions, .key = "right", .action = .prompt_open },
        .{ .context = .PromptSuggestions, .key = "escape", .action = .prompt_exit },
        .{ .context = .PromptQueue, .key = "up", .action = .prompt_previous },
        .{ .context = .PromptQueue, .key = "down", .action = .prompt_next },
        .{ .context = .PromptQueue, .key = "ctrl+p", .action = .prompt_previous },
        .{ .context = .PromptQueue, .key = "ctrl+n", .action = .prompt_next },
        .{ .context = .PromptQueue, .key = "enter", .action = .prompt_open },
        .{ .context = .PromptQueue, .key = "backspace", .action = .prompt_dismiss },
        .{ .context = .PromptQueue, .key = "x", .action = .prompt_dismiss },
        .{ .context = .PromptQueue, .key = "escape", .action = .prompt_exit },
        .{ .context = .PromptStash, .key = "up", .action = .prompt_previous },
        .{ .context = .PromptStash, .key = "down", .action = .prompt_next },
        .{ .context = .PromptStash, .key = "ctrl+p", .action = .prompt_previous },
        .{ .context = .PromptStash, .key = "ctrl+n", .action = .prompt_next },
        .{ .context = .PromptStash, .key = "enter", .action = .prompt_open },
        .{ .context = .PromptStash, .key = "backspace", .action = .prompt_dismiss },
        .{ .context = .PromptStash, .key = "x", .action = .prompt_dismiss },
        .{ .context = .PromptStash, .key = "escape", .action = .prompt_exit },
        .{ .context = .PromptNotifications, .key = "up", .action = .prompt_previous },
        .{ .context = .PromptNotifications, .key = "down", .action = .prompt_next },
        .{ .context = .PromptNotifications, .key = "ctrl+p", .action = .prompt_previous },
        .{ .context = .PromptNotifications, .key = "ctrl+n", .action = .prompt_next },
        .{ .context = .PromptNotifications, .key = "enter", .action = .prompt_open },
        .{ .context = .PromptNotifications, .key = "backspace", .action = .prompt_dismiss },
        .{ .context = .PromptNotifications, .key = "x", .action = .prompt_dismiss },
        .{ .context = .PromptNotifications, .key = "escape", .action = .prompt_exit },
        .{ .context = .Attachments, .key = "right", .action = .attachments_next },
        .{ .context = .Attachments, .key = "left", .action = .attachments_previous },
        .{ .context = .Attachments, .key = "backspace", .action = .attachments_remove },
        .{ .context = .Attachments, .key = "escape", .action = .attachments_exit },
        .{ .context = .Attachments, .key = "down", .action = .attachments_exit },
        .{ .context = .Confirmation, .key = "y", .action = .confirm_yes },
        .{ .context = .Confirmation, .key = "n", .action = .confirm_no },
        .{ .context = .Confirmation, .key = "enter", .action = .confirm_yes },
        .{ .context = .Confirmation, .key = "escape", .action = .confirm_no },
        .{ .context = .Confirmation, .key = "up", .action = .confirm_previous },
        .{ .context = .Confirmation, .key = "down", .action = .confirm_next },
        .{ .context = .Confirmation, .key = "tab", .action = .confirm_next_field },
        .{ .context = .Confirmation, .key = "space", .action = .confirm_toggle },
        .{ .context = .Confirmation, .key = "shift+tab", .action = .confirm_cycle_mode },
        .{ .context = .Confirmation, .key = "ctrl+e", .action = .confirm_toggle_explanation },
        .{ .context = .Confirmation, .key = "ctrl+d", .action = .permission_toggle_debug },
        .{ .context = .Transcript, .key = "ctrl+e", .action = .transcript_toggle_show_all },
        .{ .context = .Transcript, .key = "ctrl+c", .action = .transcript_exit },
        .{ .context = .Transcript, .key = "escape", .action = .transcript_exit },
        .{ .context = .Transcript, .key = "q", .action = .transcript_exit },
        .{ .context = .HistorySearch, .key = "ctrl+r", .action = .history_search_next },
        .{ .context = .HistorySearch, .key = "escape", .action = .history_search_accept },
        .{ .context = .HistorySearch, .key = "tab", .action = .history_search_accept },
        .{ .context = .HistorySearch, .key = "ctrl+c", .action = .history_search_cancel },
        .{ .context = .HistorySearch, .key = "enter", .action = .history_search_execute },
        .{ .context = .ThemePicker, .key = "ctrl+t", .action = .theme_toggle_syntax },
        .{ .context = .ThinkingDialog, .key = "y", .action = .confirm_yes },
        .{ .context = .ThinkingDialog, .key = "n", .action = .confirm_no },
        .{ .context = .ThinkingDialog, .key = "enter", .action = .confirm_yes },
        .{ .context = .ThinkingDialog, .key = "escape", .action = .confirm_no },
        .{ .context = .ThinkingDialog, .key = "up", .action = .confirm_previous },
        .{ .context = .ThinkingDialog, .key = "down", .action = .confirm_next },
        .{ .context = .AutoModeDialog, .key = "y", .action = .confirm_yes },
        .{ .context = .AutoModeDialog, .key = "n", .action = .confirm_no },
        .{ .context = .AutoModeDialog, .key = "enter", .action = .confirm_yes },
        .{ .context = .AutoModeDialog, .key = "escape", .action = .confirm_no },
        .{ .context = .AutoModeDialog, .key = "up", .action = .confirm_previous },
        .{ .context = .AutoModeDialog, .key = "down", .action = .confirm_next },
        .{ .context = .TeamsDialog, .key = "up", .action = .select_previous },
        .{ .context = .TeamsDialog, .key = "down", .action = .select_next },
        .{ .context = .TeamsDialog, .key = "k", .action = .select_previous },
        .{ .context = .TeamsDialog, .key = "j", .action = .select_next },
        .{ .context = .TeamsDialog, .key = "ctrl+p", .action = .select_previous },
        .{ .context = .TeamsDialog, .key = "ctrl+n", .action = .select_next },
        .{ .context = .TeamsDialog, .key = "enter", .action = .select_accept },
        .{ .context = .TeamsDialog, .key = "escape", .action = .select_cancel },
        .{ .context = .BridgeDialog, .key = "up", .action = .select_previous },
        .{ .context = .BridgeDialog, .key = "down", .action = .select_next },
        .{ .context = .BridgeDialog, .key = "k", .action = .select_previous },
        .{ .context = .BridgeDialog, .key = "j", .action = .select_next },
        .{ .context = .BridgeDialog, .key = "ctrl+p", .action = .select_previous },
        .{ .context = .BridgeDialog, .key = "ctrl+n", .action = .select_next },
        .{ .context = .BridgeDialog, .key = "enter", .action = .select_accept },
        .{ .context = .BridgeDialog, .key = "escape", .action = .select_cancel },
        .{ .context = .Select, .key = "up", .action = .select_previous },
        .{ .context = .Select, .key = "down", .action = .select_next },
        .{ .context = .Select, .key = "k", .action = .select_previous },
        .{ .context = .Select, .key = "j", .action = .select_next },
        .{ .context = .Select, .key = "ctrl+p", .action = .select_previous },
        .{ .context = .Select, .key = "ctrl+n", .action = .select_next },
        .{ .context = .Select, .key = "enter", .action = .select_accept },
        .{ .context = .Select, .key = "escape", .action = .select_cancel },
        .{ .context = .MessageSelector, .key = "up", .action = .message_selector_up },
        .{ .context = .MessageSelector, .key = "down", .action = .message_selector_down },
        .{ .context = .MessageSelector, .key = "k", .action = .message_selector_up },
        .{ .context = .MessageSelector, .key = "j", .action = .message_selector_down },
        .{ .context = .MessageSelector, .key = "ctrl+p", .action = .message_selector_up },
        .{ .context = .MessageSelector, .key = "ctrl+n", .action = .message_selector_down },
        .{ .context = .MessageSelector, .key = "ctrl+up", .action = .message_selector_top },
        .{ .context = .MessageSelector, .key = "ctrl+down", .action = .message_selector_bottom },
        .{ .context = .MessageSelector, .key = "shift+up", .action = .message_selector_top },
        .{ .context = .MessageSelector, .key = "shift+down", .action = .message_selector_bottom },
        .{ .context = .MessageSelector, .key = "enter", .action = .message_selector_select },
        .{ .context = .MessageActions, .key = "up", .action = .message_actions_prev },
        .{ .context = .MessageActions, .key = "down", .action = .message_actions_next },
        .{ .context = .MessageActions, .key = "k", .action = .message_actions_prev },
        .{ .context = .MessageActions, .key = "j", .action = .message_actions_next },
        .{ .context = .MessageActions, .key = "ctrl+up", .action = .message_actions_top },
        .{ .context = .MessageActions, .key = "ctrl+down", .action = .message_actions_bottom },
        .{ .context = .MessageActions, .key = "shift+up", .action = .message_actions_prev_user },
        .{ .context = .MessageActions, .key = "shift+down", .action = .message_actions_next_user },
        .{ .context = .MessageActions, .key = "escape", .action = .message_actions_cancel },
        .{ .context = .MessageActions, .key = "enter", .action = .message_actions_accept },
        .{ .context = .MessageActions, .key = "c", .action = .message_actions_copy },
    };

    for (defaults) |entry| {
        try addOrReplaceRuntimeBinding(&out, allocator, entry.context, entry.key, entry.action, null);
    }
    return out;
}

pub fn installLeaderKeyDefaults(
    allocator: std.mem.Allocator,
    keybindings: *RuntimeKeybindings,
    leader_key: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, leader_key, " \t\r\n");
    if (trimmed.len == 0) return;

    const defaults = [_]struct {
        suffix: []const u8,
        action: BindingAction,
    }{
        .{ .suffix = "h", .action = .chat_command_palette },
        .{ .suffix = "s", .action = .chat_session_switcher },
        .{ .suffix = "m", .action = .chat_model_picker },
        .{ .suffix = "t", .action = .app_toggle_todos },
        .{ .suffix = "f", .action = .app_quick_open },
        .{ .suffix = "g", .action = .app_global_search },
        .{ .suffix = "p", .action = .chat_theme_picker },
        .{ .suffix = "b", .action = .chat_density_toggle },
        .{ .suffix = "a", .action = .chat_runtime_panel },
    };

    for (defaults) |entry| {
        var key_buf: [64]u8 = undefined;
        const chord = std.fmt.bufPrint(&key_buf, "{s} {s}", .{ trimmed, entry.suffix }) catch continue;
        try addOrReplaceRuntimeBinding(keybindings, allocator, .Chat, chord, entry.action, null);
    }
}

fn parseCommandBinding(context: BindingContext, raw: []const u8) ?[]const u8 {
    if (context != .Chat) return null;
    if (!std.mem.startsWith(u8, raw, "command:")) return null;
    const name = raw["command:".len..];
    if (name.len == 0) return null;
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != ':' and ch != '-' and ch != '_') return null;
    }
    return name;
}

fn parseBindingContext(raw: []const u8) ?BindingContext {
    if (std.mem.eql(u8, raw, "Global")) return .Global;
    if (std.mem.eql(u8, raw, "Chat")) return .Chat;
    if (std.mem.eql(u8, raw, "Autocomplete")) return .Autocomplete;
    if (std.mem.eql(u8, raw, "PromptSuggestions")) return .PromptSuggestions;
    if (std.mem.eql(u8, raw, "PromptQueue")) return .PromptQueue;
    if (std.mem.eql(u8, raw, "PromptStash")) return .PromptStash;
    if (std.mem.eql(u8, raw, "PromptNotifications")) return .PromptNotifications;
    if (std.mem.eql(u8, raw, "Attachments")) return .Attachments;
    if (std.mem.eql(u8, raw, "Footer")) return .Footer;
    if (std.mem.eql(u8, raw, "Confirmation")) return .Confirmation;
    if (std.mem.eql(u8, raw, "Transcript")) return .Transcript;
    if (std.mem.eql(u8, raw, "HistorySearch")) return .HistorySearch;
    if (std.mem.eql(u8, raw, "ThemePicker")) return .ThemePicker;
    if (std.mem.eql(u8, raw, "ModelPicker")) return .ModelPicker;
    if (std.mem.eql(u8, raw, "ThinkingDialog")) return .ThinkingDialog;
    if (std.mem.eql(u8, raw, "AutoModeDialog")) return .AutoModeDialog;
    if (std.mem.eql(u8, raw, "TeamsDialog")) return .TeamsDialog;
    if (std.mem.eql(u8, raw, "BridgeDialog")) return .BridgeDialog;
    if (std.mem.eql(u8, raw, "Select")) return .Select;
    if (std.mem.eql(u8, raw, "MessageSelector")) return .MessageSelector;
    if (std.mem.eql(u8, raw, "MessageActions")) return .MessageActions;
    return null;
}

fn parseBindingAction(context: BindingContext, raw: []const u8) ?BindingAction {
    return switch (context) {
        .Global => blk: {
            if (std.mem.eql(u8, raw, "app:interrupt")) break :blk .app_interrupt;
            if (std.mem.eql(u8, raw, "app:toggleTodos")) break :blk .app_toggle_todos;
            if (std.mem.eql(u8, raw, "app:toggleTranscript")) break :blk .app_toggle_transcript;
            if (std.mem.eql(u8, raw, "app:toggleBrief")) break :blk .app_toggle_brief;
            if (std.mem.eql(u8, raw, "app:redraw")) break :blk .app_redraw;
            if (std.mem.eql(u8, raw, "app:globalSearch")) break :blk .app_global_search;
            if (std.mem.eql(u8, raw, "app:quickOpen")) break :blk .app_quick_open;
            if (std.mem.eql(u8, raw, "history:search")) break :blk .history_search;
            break :blk null;
        },
        .Chat => blk: {
            if (std.mem.eql(u8, raw, "history:previous")) break :blk .history_previous;
            if (std.mem.eql(u8, raw, "history:next")) break :blk .history_next;
            if (std.mem.eql(u8, raw, "chat:cycleMode")) break :blk .chat_cycle_mode;
            if (std.mem.eql(u8, raw, "chat:commandPalette")) break :blk .chat_command_palette;
            if (std.mem.eql(u8, raw, "chat:sessionSwitcher")) break :blk .chat_session_switcher;
            if (std.mem.eql(u8, raw, "chat:modelPicker")) break :blk .chat_model_picker;
            if (std.mem.eql(u8, raw, "chat:themePicker")) break :blk .chat_theme_picker;
            if (std.mem.eql(u8, raw, "chat:runtimePanel")) break :blk .chat_runtime_panel;
            if (std.mem.eql(u8, raw, "chat:densityToggle")) break :blk .chat_density_toggle;
            if (std.mem.eql(u8, raw, "chat:fastMode")) break :blk .chat_fast_mode;
            if (std.mem.eql(u8, raw, "chat:thinkingToggle")) break :blk .chat_thinking_toggle;
            if (std.mem.eql(u8, raw, "chat:submit")) break :blk .chat_submit;
            if (std.mem.eql(u8, raw, "chat:newline")) break :blk .chat_newline;
            if (std.mem.eql(u8, raw, "chat:undo")) break :blk .chat_undo;
            if (std.mem.eql(u8, raw, "chat:externalEditor")) break :blk .chat_external_editor;
            if (std.mem.eql(u8, raw, "chat:killAgents")) break :blk .chat_kill_agents;
            if (std.mem.eql(u8, raw, "chat:stash")) break :blk .chat_stash;
            if (std.mem.eql(u8, raw, "chat:imagePaste")) break :blk .chat_image_paste;
            if (std.mem.eql(u8, raw, "chat:messageActions")) break :blk .chat_message_actions;
            if (std.mem.eql(u8, raw, "chat:clearLine")) break :blk .chat_clear_line;
            if (std.mem.eql(u8, raw, "chat:deletePrevWord")) break :blk .chat_delete_prev_word;
            if (std.mem.eql(u8, raw, "chat:backspace")) break :blk .chat_backspace;
            break :blk null;
        },
        .Autocomplete => blk: {
            if (std.mem.eql(u8, raw, "autocomplete:accept")) break :blk .autocomplete_accept;
            if (std.mem.eql(u8, raw, "autocomplete:dismiss")) break :blk .autocomplete_dismiss;
            if (std.mem.eql(u8, raw, "autocomplete:previous")) break :blk .autocomplete_previous;
            if (std.mem.eql(u8, raw, "autocomplete:next")) break :blk .autocomplete_next;
            break :blk null;
        },
        .PromptSuggestions, .PromptQueue, .PromptStash, .PromptNotifications => blk: {
            if (std.mem.eql(u8, raw, "prompt:previous")) break :blk .prompt_previous;
            if (std.mem.eql(u8, raw, "prompt:next")) break :blk .prompt_next;
            if (std.mem.eql(u8, raw, "prompt:open")) break :blk .prompt_open;
            if (std.mem.eql(u8, raw, "prompt:dismiss")) break :blk .prompt_dismiss;
            if (std.mem.eql(u8, raw, "prompt:exit")) break :blk .prompt_exit;
            break :blk null;
        },
        .Attachments => blk: {
            if (std.mem.eql(u8, raw, "attachments:next")) break :blk .attachments_next;
            if (std.mem.eql(u8, raw, "attachments:previous")) break :blk .attachments_previous;
            if (std.mem.eql(u8, raw, "attachments:remove")) break :blk .attachments_remove;
            if (std.mem.eql(u8, raw, "attachments:exit")) break :blk .attachments_exit;
            break :blk null;
        },
        .Footer => blk: {
            if (std.mem.eql(u8, raw, "footer:up")) break :blk .footer_up;
            if (std.mem.eql(u8, raw, "footer:down")) break :blk .footer_down;
            if (std.mem.eql(u8, raw, "footer:next")) break :blk .footer_next;
            if (std.mem.eql(u8, raw, "footer:previous")) break :blk .footer_previous;
            if (std.mem.eql(u8, raw, "footer:openSelected")) break :blk .footer_open_selected;
            if (std.mem.eql(u8, raw, "footer:clearSelection")) break :blk .footer_clear_selection;
            if (std.mem.eql(u8, raw, "footer:close")) break :blk .footer_close;
            break :blk null;
        },
        .Confirmation, .ThinkingDialog, .AutoModeDialog => blk: {
            if (std.mem.eql(u8, raw, "confirm:yes")) break :blk .confirm_yes;
            if (std.mem.eql(u8, raw, "confirm:no")) break :blk .confirm_no;
            if (std.mem.eql(u8, raw, "confirm:previous")) break :blk .confirm_previous;
            if (std.mem.eql(u8, raw, "confirm:next")) break :blk .confirm_next;
            if (std.mem.eql(u8, raw, "confirm:nextField")) break :blk .confirm_next_field;
            if (std.mem.eql(u8, raw, "confirm:toggle")) break :blk .confirm_toggle;
            if (std.mem.eql(u8, raw, "confirm:cycleMode")) break :blk .confirm_cycle_mode;
            if (std.mem.eql(u8, raw, "confirm:toggleExplanation")) break :blk .confirm_toggle_explanation;
            if (std.mem.eql(u8, raw, "permission:toggleDebug")) break :blk .permission_toggle_debug;
            break :blk null;
        },
        .Transcript => blk: {
            if (std.mem.eql(u8, raw, "transcript:toggleShowAll")) break :blk .transcript_toggle_show_all;
            if (std.mem.eql(u8, raw, "transcript:exit")) break :blk .transcript_exit;
            break :blk null;
        },
        .HistorySearch => blk: {
            if (std.mem.eql(u8, raw, "historySearch:next")) break :blk .history_search_next;
            if (std.mem.eql(u8, raw, "historySearch:accept")) break :blk .history_search_accept;
            if (std.mem.eql(u8, raw, "historySearch:cancel")) break :blk .history_search_cancel;
            if (std.mem.eql(u8, raw, "historySearch:execute")) break :blk .history_search_execute;
            break :blk null;
        },
        .ThemePicker => if (std.mem.eql(u8, raw, "theme:toggleSyntaxHighlighting")) .theme_toggle_syntax else null,
        .ModelPicker, .TeamsDialog, .BridgeDialog, .Select => blk: {
            if (std.mem.eql(u8, raw, "select:previous")) break :blk .select_previous;
            if (std.mem.eql(u8, raw, "select:next")) break :blk .select_next;
            if (std.mem.eql(u8, raw, "select:accept")) break :blk .select_accept;
            if (std.mem.eql(u8, raw, "select:cancel")) break :blk .select_cancel;
            break :blk null;
        },
        .MessageSelector => blk: {
            if (std.mem.eql(u8, raw, "messageSelector:up")) break :blk .message_selector_up;
            if (std.mem.eql(u8, raw, "messageSelector:down")) break :blk .message_selector_down;
            if (std.mem.eql(u8, raw, "messageSelector:top")) break :blk .message_selector_top;
            if (std.mem.eql(u8, raw, "messageSelector:bottom")) break :blk .message_selector_bottom;
            if (std.mem.eql(u8, raw, "messageSelector:select")) break :blk .message_selector_select;
            break :blk null;
        },
        .MessageActions => blk: {
            if (std.mem.eql(u8, raw, "messageActions:prev")) break :blk .message_actions_prev;
            if (std.mem.eql(u8, raw, "messageActions:next")) break :blk .message_actions_next;
            if (std.mem.eql(u8, raw, "messageActions:top")) break :blk .message_actions_top;
            if (std.mem.eql(u8, raw, "messageActions:bottom")) break :blk .message_actions_bottom;
            if (std.mem.eql(u8, raw, "messageActions:prevUser")) break :blk .message_actions_prev_user;
            if (std.mem.eql(u8, raw, "messageActions:nextUser")) break :blk .message_actions_next_user;
            if (std.mem.eql(u8, raw, "messageActions:escape")) break :blk .message_actions_cancel;
            if (std.mem.eql(u8, raw, "messageActions:ctrlc")) break :blk .message_actions_cancel;
            if (std.mem.eql(u8, raw, "messageActions:enter")) break :blk .message_actions_accept;
            if (std.mem.eql(u8, raw, "messageActions:c")) break :blk .message_actions_copy;
            break :blk null;
        },
    };
}

fn addOrReplaceRuntimeBinding(
    out: *RuntimeKeybindings,
    allocator: std.mem.Allocator,
    context: BindingContext,
    raw_key: []const u8,
    action: ?BindingAction,
    command: ?[]const u8,
) !void {
    const normalized = try normalizeKeyForComparison(allocator, raw_key);
    errdefer allocator.free(normalized);
    const command_copy = if (command) |cmd| try allocator.dupe(u8, cmd) else null;
    errdefer if (command_copy) |cmd| allocator.free(cmd);

    for (out.entries, 0..) |entry, idx| {
        if (entry.context == context and std.mem.eql(u8, entry.key, normalized)) {
            allocator.free(entry.key);
            if (entry.command) |existing_command| allocator.free(existing_command);
            if (action != null or command_copy != null) {
                out.entries[idx].key = normalized;
                out.entries[idx].action = action;
                out.entries[idx].command = command_copy;
            } else {
                if (idx + 1 < out.entries.len) {
                    std.mem.copyForwards(RuntimeBinding, out.entries[idx .. out.entries.len - 1], out.entries[idx + 1 ..]);
                }
                out.entries = try allocator.realloc(out.entries, out.entries.len - 1);
                allocator.free(normalized);
            }
            return;
        }
    }

    if (action != null or command_copy != null) {
        const next_len = out.entries.len + 1;
        out.entries = try allocator.realloc(out.entries, next_len);
        out.entries[next_len - 1] = .{
            .context = context,
            .key = normalized,
            .action = action,
            .command = command_copy,
        };
        return;
    }
}

fn lookupRuntimeBinding(entries: []const RuntimeBinding, context: BindingContext, chord: []const u8) ?RuntimeBinding {
    var idx = entries.len;
    while (idx > 0) {
        idx -= 1;
        const entry = entries[idx];
        if (entry.context == context and std.mem.eql(u8, entry.key, chord)) return entry;
    }
    return null;
}

fn lookupRuntimeBindingWithContexts(
    entries: []const RuntimeBinding,
    contexts: []const BindingContext,
    chord: []const u8,
) ?RuntimeBinding {
    for (contexts) |context| {
        if (lookupRuntimeBinding(entries, context, chord)) |binding| return binding;
    }
    return null;
}

fn hasLongerChordPrefix(
    entries: []const RuntimeBinding,
    contexts: []const BindingContext,
    prefix: []const u8,
) bool {
    for (entries) |entry| {
        if (!contextSliceContains(contexts, entry.context)) continue;
        if (entry.key.len <= prefix.len) continue;
        if (!std.mem.startsWith(u8, entry.key, prefix)) continue;
        if (entry.key[prefix.len] == ' ') return true;
    }
    return false;
}

fn contextSliceContains(contexts: []const BindingContext, needle: BindingContext) bool {
    for (contexts) |context| {
        if (context == needle) return true;
    }
    return false;
}

fn defaultActionFor(context: BindingContext, chord: []const u8) ?BindingAction {
    const defaults: []const DefaultBinding = switch (context) {
        .Global => &[_]DefaultBinding{
            .{ .key = "ctrl+r", .action = .history_search },
            .{ .key = "ctrl+o", .action = .app_toggle_transcript },
            .{ .key = "ctrl+t", .action = .app_toggle_todos },
            .{ .key = "ctrl+b", .action = .app_toggle_brief },
            .{ .key = "ctrl+shift+b", .action = .app_toggle_brief },
            .{ .key = "ctrl+l", .action = .app_redraw },
            .{ .key = "ctrl+f", .action = .app_global_search },
            .{ .key = "ctrl+shift+f", .action = .app_global_search },
            .{ .key = "cmd+shift+f", .action = .app_global_search },
            .{ .key = "ctrl+p", .action = .app_quick_open },
            .{ .key = "ctrl+shift+p", .action = .app_quick_open },
            .{ .key = "cmd+shift+p", .action = .app_quick_open },
        },
        .Chat => &[_]DefaultBinding{
            .{ .key = "enter", .action = .chat_submit },
            .{ .key = "shift+enter", .action = .chat_newline },
            .{ .key = "shift+tab", .action = .chat_cycle_mode },
            .{ .key = "tab tab", .action = .chat_density_toggle },
            .{ .key = "up", .action = .history_previous },
            .{ .key = "down", .action = .history_next },
            .{ .key = "ctrl+x h", .action = .chat_command_palette },
            .{ .key = "ctrl+x s", .action = .chat_session_switcher },
            .{ .key = "ctrl+x ctrl+e", .action = .chat_external_editor },
            .{ .key = "ctrl+x ctrl+k", .action = .chat_kill_agents },
            .{ .key = "ctrl+x m", .action = .chat_model_picker },
            .{ .key = "ctrl+x t", .action = .app_toggle_todos },
            .{ .key = "ctrl+x f", .action = .app_quick_open },
            .{ .key = "ctrl+x g", .action = .app_global_search },
            .{ .key = "ctrl+x p", .action = .chat_theme_picker },
            .{ .key = "ctrl+x b", .action = .chat_density_toggle },
            .{ .key = "ctrl+x a", .action = .chat_runtime_panel },
            .{ .key = "ctrl+g", .action = .chat_external_editor },
            .{ .key = "ctrl+s", .action = .chat_stash },
            .{ .key = "ctrl+v", .action = .chat_image_paste },
            .{ .key = "shift+up", .action = .chat_message_actions },
            .{ .key = "alt+p", .action = .chat_model_picker },
            .{ .key = "alt+o", .action = .chat_fast_mode },
            .{ .key = "alt+t", .action = .chat_thinking_toggle },
            .{ .key = "ctrl+_", .action = .chat_undo },
            .{ .key = "ctrl+shift+-", .action = .chat_undo },
            .{ .key = "ctrl+u", .action = .chat_clear_line },
            .{ .key = "cmd+backspace", .action = .chat_clear_line },
            .{ .key = "ctrl+w", .action = .chat_delete_prev_word },
            .{ .key = "alt+backspace", .action = .chat_delete_prev_word },
            .{ .key = "backspace", .action = .chat_backspace },
        },
        .Autocomplete => &[_]DefaultBinding{
            .{ .key = "tab", .action = .autocomplete_accept },
            .{ .key = "escape", .action = .autocomplete_dismiss },
            .{ .key = "up", .action = .autocomplete_previous },
            .{ .key = "down", .action = .autocomplete_next },
        },
        .PromptSuggestions => &[_]DefaultBinding{
            .{ .key = "up", .action = .prompt_previous },
            .{ .key = "down", .action = .prompt_next },
            .{ .key = "ctrl+p", .action = .prompt_previous },
            .{ .key = "ctrl+n", .action = .prompt_next },
            .{ .key = "enter", .action = .prompt_open },
            .{ .key = "tab", .action = .prompt_open },
            .{ .key = "right", .action = .prompt_open },
            .{ .key = "escape", .action = .prompt_exit },
        },
        .PromptQueue, .PromptStash, .PromptNotifications => &[_]DefaultBinding{
            .{ .key = "up", .action = .prompt_previous },
            .{ .key = "down", .action = .prompt_next },
            .{ .key = "ctrl+p", .action = .prompt_previous },
            .{ .key = "ctrl+n", .action = .prompt_next },
            .{ .key = "enter", .action = .prompt_open },
            .{ .key = "backspace", .action = .prompt_dismiss },
            .{ .key = "x", .action = .prompt_dismiss },
            .{ .key = "escape", .action = .prompt_exit },
        },
        .Attachments => &[_]DefaultBinding{
            .{ .key = "right", .action = .attachments_next },
            .{ .key = "left", .action = .attachments_previous },
            .{ .key = "backspace", .action = .attachments_remove },
            .{ .key = "down", .action = .attachments_exit },
            .{ .key = "escape", .action = .attachments_exit },
        },
        .Footer => &[_]DefaultBinding{},
        .Confirmation, .ThinkingDialog, .AutoModeDialog => &[_]DefaultBinding{
            .{ .key = "y", .action = .confirm_yes },
            .{ .key = "n", .action = .confirm_no },
            .{ .key = "enter", .action = .confirm_yes },
            .{ .key = "escape", .action = .confirm_no },
            .{ .key = "up", .action = .confirm_previous },
            .{ .key = "down", .action = .confirm_next },
            .{ .key = "tab", .action = .confirm_next_field },
            .{ .key = "space", .action = .confirm_toggle },
            .{ .key = "shift+tab", .action = .confirm_cycle_mode },
            .{ .key = "ctrl+e", .action = .confirm_toggle_explanation },
            .{ .key = "ctrl+d", .action = .permission_toggle_debug },
        },
        .Transcript => &[_]DefaultBinding{
            .{ .key = "ctrl+e", .action = .transcript_toggle_show_all },
            .{ .key = "ctrl+c", .action = .transcript_exit },
            .{ .key = "escape", .action = .transcript_exit },
            .{ .key = "q", .action = .transcript_exit },
        },
        .HistorySearch => &[_]DefaultBinding{
            .{ .key = "ctrl+r", .action = .history_search_next },
            .{ .key = "escape", .action = .history_search_accept },
            .{ .key = "tab", .action = .history_search_accept },
            .{ .key = "ctrl+c", .action = .history_search_cancel },
            .{ .key = "enter", .action = .history_search_execute },
        },
        .ThemePicker => &[_]DefaultBinding{
            .{ .key = "ctrl+t", .action = .theme_toggle_syntax },
        },
        .ModelPicker, .TeamsDialog, .BridgeDialog, .Select => &[_]DefaultBinding{
            .{ .key = "up", .action = .select_previous },
            .{ .key = "down", .action = .select_next },
            .{ .key = "k", .action = .select_previous },
            .{ .key = "j", .action = .select_next },
            .{ .key = "ctrl+p", .action = .select_previous },
            .{ .key = "ctrl+n", .action = .select_next },
            .{ .key = "enter", .action = .select_accept },
            .{ .key = "escape", .action = .select_cancel },
        },
        .MessageSelector => &[_]DefaultBinding{
            .{ .key = "up", .action = .message_selector_up },
            .{ .key = "down", .action = .message_selector_down },
            .{ .key = "k", .action = .message_selector_up },
            .{ .key = "j", .action = .message_selector_down },
            .{ .key = "ctrl+p", .action = .message_selector_up },
            .{ .key = "ctrl+n", .action = .message_selector_down },
            .{ .key = "ctrl+up", .action = .message_selector_top },
            .{ .key = "ctrl+down", .action = .message_selector_bottom },
            .{ .key = "shift+up", .action = .message_selector_top },
            .{ .key = "shift+down", .action = .message_selector_bottom },
            .{ .key = "enter", .action = .message_selector_select },
        },
        .MessageActions => &[_]DefaultBinding{
            .{ .key = "up", .action = .message_actions_prev },
            .{ .key = "down", .action = .message_actions_next },
            .{ .key = "k", .action = .message_actions_prev },
            .{ .key = "j", .action = .message_actions_next },
            .{ .key = "ctrl+up", .action = .message_actions_top },
            .{ .key = "ctrl+down", .action = .message_actions_bottom },
            .{ .key = "shift+up", .action = .message_actions_prev_user },
            .{ .key = "shift+down", .action = .message_actions_next_user },
            .{ .key = "escape", .action = .message_actions_cancel },
            .{ .key = "enter", .action = .message_actions_accept },
            .{ .key = "c", .action = .message_actions_copy },
        },
    };

    for (defaults) |entry| {
        if (std.mem.eql(u8, entry.key, chord)) return entry.action;
    }
    return null;
}

fn warnRuntimeReservedConflicts(allocator: std.mem.Allocator, kb: *const RuntimeKeybindings) usize {
    var count: usize = 0;
    for (kb.entries) |entry| {
        const conflict = findReservedConflict(allocator, entry.key) catch continue;
        if (conflict) |c| {
            if (c.canonical_action != null) continue;
            count += 1;
            switch (c.severity) {
                .@"error" => std.log.warn(
                    "keybindings: '{s}' in context '{s}' is non-rebindable ({s}); zcode will ignore the override",
                    .{ entry.key, @tagName(entry.context), c.reason },
                ),
                .warning => std.log.warn(
                    "keybindings: '{s}' in context '{s}' may be swallowed by the terminal ({s})",
                    .{ entry.key, @tagName(entry.context), c.reason },
                ),
            }
        }
    }
    return count;
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

test "isMacosOptionChar maps known Option+key codepoints" {
    try testing.expectEqualStrings("alt+t", isMacosOptionChar(0x2020).?); // †
    try testing.expectEqualStrings("alt+p", isMacosOptionChar(0x03C0).?); // π
    try testing.expectEqualStrings("alt+o", isMacosOptionChar(0x00F8).?); // ø
}

test "isMacosOptionChar returns null for unrelated codepoints" {
    try testing.expectEqual(@as(?[]const u8, null), isMacosOptionChar('a'));
    try testing.expectEqual(@as(?[]const u8, null), isMacosOptionChar(0x1F389)); // 🎉
    try testing.expectEqual(@as(?[]const u8, null), isMacosOptionChar(0x00E9)); // é
    try testing.expectEqual(@as(?[]const u8, null), isMacosOptionChar(0));
}

test "default keybindings have expected values" {
    var kb = Keybindings{};
    try testing.expectEqual(@as(usize, 2), kb.submit.len);
    try testing.expectEqualStrings("enter", kb.submit[0]);
    try testing.expectEqualStrings("ctrl+m", kb.submit[1]);
    try testing.expectEqual(@as(usize, 1), kb.newline.len);
    try testing.expectEqualStrings("shift+enter", kb.newline[0]);
    try testing.expectEqual(@as(usize, 2), kb.cancel.len);
    try testing.expectEqualStrings("ctrl+c", kb.cancel[0]);
    kb.deinit(testing.allocator); // no-op for defaults
}

test "default chat runtime bindings expose session switcher and density toggle chords" {
    var kb = try defaultRuntimeKeybindings(testing.allocator);
    defer kb.deinit(testing.allocator);
    try installLeaderKeyDefaults(testing.allocator, &kb, "ctrl+x");

    const contexts = [_]BindingContext{.Chat};

    const leader_started = kb.resolveChord(&contexts, null, "ctrl+x");
    try testing.expect(leader_started.result == .chord_started);

    const leader_match = kb.resolveChord(&contexts, "ctrl+x", "s");
    try testing.expect(leader_match.result == .match);
    try testing.expectEqual(@as(?BindingAction, .chat_session_switcher), leader_match.action);

    const density_started = kb.resolveChord(&contexts, null, "tab");
    try testing.expect(density_started.result == .chord_started);

    const density_match = kb.resolveChord(&contexts, "tab", "tab");
    try testing.expect(density_match.result == .match);
    try testing.expectEqual(@as(?BindingAction, .chat_density_toggle), density_match.action);
}

test "parseKeybindings overrides specific actions" {
    const json =
        \\{
        \\  "submit": ["ctrl+enter"],
        \\  "cancel": ["ctrl+c", "ctrl+q"]
        \\}
    ;
    var kb = parseKeybindings(testing.allocator, json);
    defer kb.deinit(testing.allocator);

    // Overridden fields.
    try testing.expectEqual(@as(usize, 1), kb.submit.len);
    try testing.expectEqualStrings("ctrl+enter", kb.submit[0]);
    try testing.expectEqual(@as(usize, 2), kb.cancel.len);
    try testing.expectEqualStrings("ctrl+c", kb.cancel[0]);
    try testing.expectEqualStrings("ctrl+q", kb.cancel[1]);

    // Non-overridden field keeps default.
    try testing.expectEqual(@as(usize, 1), kb.tab.len);
    try testing.expectEqualStrings("tab", kb.tab[0]);
}

test "parseKeybindings handles single string value" {
    const json =
        \\{ "escape": "ctrl+[" }
    ;
    var kb = parseKeybindings(testing.allocator, json);
    defer kb.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), kb.escape.len);
    try testing.expectEqualStrings("ctrl+[", kb.escape[0]);
}

test "parseKeybindings returns defaults on invalid JSON" {
    var kb = parseKeybindings(testing.allocator, "not json");
    defer kb.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), kb.submit.len);
}

test "parseKeyDescriptor parses modifiers" {
    const d = parseKeyDescriptor("ctrl+shift+a");
    try testing.expect(d.ctrl);
    try testing.expect(d.shift);
    try testing.expect(!d.alt);
    try testing.expectEqualStrings("a", d.key);
}

test "parseKeyDescriptor handles plain key" {
    const d = parseKeyDescriptor("enter");
    try testing.expect(!d.ctrl);
    try testing.expect(!d.alt);
    try testing.expect(!d.shift);
    try testing.expectEqualStrings("enter", d.key);
}

test "parseKeyDescriptor handles alt modifier" {
    const d = parseKeyDescriptor("alt+backspace");
    try testing.expect(!d.ctrl);
    try testing.expect(d.alt);
    try testing.expect(!d.shift);
    try testing.expectEqualStrings("backspace", d.key);
}

test "normalizeKeyForComparison canonicalises modifier order and aliases" {
    const cases = [_]struct { raw: []const u8, expected: []const u8 }{
        .{ .raw = "CTRL+C", .expected = "ctrl+c" },
        .{ .raw = "Shift+Ctrl+A", .expected = "ctrl+shift+a" },
        .{ .raw = "control+m", .expected = "ctrl+m" },
        .{ .raw = "option+backspace", .expected = "alt+backspace" },
        .{ .raw = "command+v", .expected = "cmd+v" },
        .{ .raw = "Meta+X", .expected = "cmd+x" },
        .{ .raw = "ctrl+x ctrl+e", .expected = "ctrl+x ctrl+e" },
        .{ .raw = " Control+X   Shift+Control+E ", .expected = "ctrl+x ctrl+shift+e" },
        .{ .raw = "Command+Shift+F", .expected = "cmd+shift+f" },
        .{ .raw = "Ctrl+Shift+-", .expected = "ctrl+shift+-" },
        .{ .raw = "Esc", .expected = "escape" },
        .{ .raw = "Return", .expected = "enter" },
        .{ .raw = "Space", .expected = "space" },
    };
    for (cases) |case| {
        const got = try normalizeKeyForComparison(testing.allocator, case.raw);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(case.expected, got);
    }
}

test "runtime keybindings allow unbinding default shortcuts" {
    const json =
        \\{
        \\  "bindings": [
        \\    {
        \\      "context": "Chat",
        \\      "bindings": {
        \\        "ctrl+g": null
        \\      }
        \\    }
        \\  ]
        \\}
    ;
    var kb = try parseRuntimeKeybindings(testing.allocator, json);
    defer kb.deinit(testing.allocator);

    const contexts = [_]BindingContext{.Chat};
    const lookup = kb.lookup(&contexts, "ctrl+g");
    try testing.expect(!lookup.handled);
}

test "runtime keybindings resolve multi-step chords" {
    const json =
        \\{
        \\  "bindings": [
        \\    {
        \\      "context": "Chat",
        \\      "bindings": {
        \\        "ctrl+x ctrl+k": "command:kill-agents"
        \\      }
        \\    }
        \\  ]
        \\}
    ;
    var kb = try parseRuntimeKeybindings(testing.allocator, json);
    defer kb.deinit(testing.allocator);

    const contexts = [_]BindingContext{.Chat};
    const started = kb.resolveChord(&contexts, null, "ctrl+x");
    try testing.expect(started.result == .chord_started);

    const matched = kb.resolveChord(&contexts, "ctrl+x", "ctrl+k");
    try testing.expect(matched.result == .match);
    try testing.expectEqualStrings("kill-agents", matched.command.?);
}

test "findReservedConflict flags NON_REBINDABLE keys as errors" {
    for ([_][]const u8{ "ctrl+c", "CTRL+C", "ctrl+d", "ctrl+m" }) |key| {
        const conflict = (try findReservedConflict(testing.allocator, key)).?;
        try testing.expectEqual(conflict.severity, .@"error");
        try testing.expect(std.mem.indexOf(u8, conflict.reason, "hardcoded") != null or
            std.mem.indexOf(u8, conflict.reason, "Enter") != null);
    }
}

test "findReservedConflict flags terminal-reserved keys as warnings" {
    const conflict = (try findReservedConflict(testing.allocator, "ctrl+z")).?;
    try testing.expectEqual(conflict.severity, .warning);
    try testing.expect(std.mem.indexOf(u8, conflict.reason, "SIGTSTP") != null);
}

test "findReservedConflict returns null for unreserved keys" {
    try testing.expectEqual(@as(?ReservedShortcut, null), try findReservedConflict(testing.allocator, "ctrl+shift+a"));
    try testing.expectEqual(@as(?ReservedShortcut, null), try findReservedConflict(testing.allocator, "f5"));
    try testing.expectEqual(@as(?ReservedShortcut, null), try findReservedConflict(testing.allocator, "alt+enter"));
}

test "findReservedConflictForPlatform flags macOS-reserved keys only on macOS" {
    // cmd+c is reserved by macOS but unreserved on other platforms.
    const mac_conflict = (try findReservedConflictForPlatform(testing.allocator, .macos, "cmd+c")).?;
    try testing.expectEqual(mac_conflict.severity, .@"error");
    try testing.expect(std.mem.indexOf(u8, mac_conflict.reason, "macOS") != null);

    // Same key on a non-macOS platform must not be flagged.
    try testing.expectEqual(
        @as(?ReservedShortcut, null),
        try findReservedConflictForPlatform(testing.allocator, .other, "cmd+c"),
    );

    // All seven entries resolve on macOS and none of them on other platforms.
    for ([_][]const u8{ "cmd+c", "cmd+v", "cmd+x", "cmd+q", "cmd+w", "cmd+tab", "cmd+space" }) |key| {
        try testing.expect((try findReservedConflictForPlatform(testing.allocator, .macos, key)) != null);
        try testing.expectEqual(
            @as(?ReservedShortcut, null),
            try findReservedConflictForPlatform(testing.allocator, .other, key),
        );
    }

    // Alias spellings (command/meta) normalise to cmd and still match.
    try testing.expect((try findReservedConflictForPlatform(testing.allocator, .macos, "command+space")) != null);
    try testing.expect((try findReservedConflictForPlatform(testing.allocator, .macos, "meta+q")) != null);

    // NON_REBINDABLE / TERMINAL_RESERVED still resolve regardless of platform.
    try testing.expect((try findReservedConflictForPlatform(testing.allocator, .other, "ctrl+c")) != null);
}

test "warnReservedConflicts is silent on default bindings (canonical slots)" {
    // The defaults bind ctrl+c to cancel and ctrl+m to submit, both
    // their canonical slots. The scanner must not warn about either.
    // We don't assert on stderr here (stderr mocking is noisy in Zig
    // test runs); the guarantee this test encodes is that we don't
    // hit an allocator leak or logic bug on the default config.
    const kb = Keybindings{};
    warnReservedConflicts(testing.allocator, &kb);
}

test "canonical_action suppresses conflict in its own slot" {
    // ctrl+m in submit should be silent (canonical), but ctrl+m in any
    // other slot should still be flagged. findReservedConflict itself
    // doesn't know about slots, but canonical_action on the returned
    // struct lets warnReservedConflicts filter.
    const conflict = (try findReservedConflict(testing.allocator, "ctrl+m")).?;
    try testing.expectEqualStrings("submit", conflict.canonical_action.?);

    const cancel_conflict = (try findReservedConflict(testing.allocator, "ctrl+c")).?;
    try testing.expectEqualStrings("cancel", cancel_conflict.canonical_action.?);
}

fn countWarnings(warnings: *const KeybindingWarnings, kind: KeybindingWarning.Kind) usize {
    var n: usize = 0;
    for (warnings.items) |w| {
        if (w.kind == kind) n += 1;
    }
    return n;
}

test "collectKeybindingWarnings flags an unknown context" {
    const json =
        \\{ "bindings": [
        \\  { "context": "Bogus", "bindings": { "ctrl+y": "app:redraw" } }
        \\] }
    ;
    var warnings = try collectKeybindingWarnings(testing.allocator, json);
    defer warnings.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), countWarnings(&warnings, .invalid_context));
    // No spurious action warnings: the block is short-circuited on the bad context.
    try testing.expectEqual(@as(usize, 0), countWarnings(&warnings, .invalid_action));
}

test "collectKeybindingWarnings flags a non-string action" {
    const json =
        \\{ "bindings": [
        \\  { "context": "Global", "bindings": { "ctrl+y": 42 } }
        \\] }
    ;
    var warnings = try collectKeybindingWarnings(testing.allocator, json);
    defer warnings.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), countWarnings(&warnings, .invalid_action));
    try testing.expect(warnings.items[0].severity == .@"error");
    try testing.expectEqualStrings("ctrl+y", warnings.items[0].key.?);
    try testing.expectEqualStrings("Global", warnings.items[0].context.?);
}

test "collectKeybindingWarnings flags an unknown action string" {
    const json =
        \\{ "bindings": [
        \\  { "context": "Global", "bindings": { "ctrl+y": "app:notARealAction" } }
        \\] }
    ;
    var warnings = try collectKeybindingWarnings(testing.allocator, json);
    defer warnings.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), countWarnings(&warnings, .invalid_action));
}

test "collectKeybindingWarnings flags a duplicate key in one block" {
    // JSON.parse keeps only the last value for a repeated key, so this
    // duplicate is invisible to the parsed map -- only the raw-text scan
    // catches it.
    const json =
        \\{ "bindings": [
        \\  { "context": "Global", "bindings": {
        \\      "ctrl+y": "app:redraw",
        \\      "ctrl+y": "app:toggleTodos"
        \\  } }
        \\] }
    ;
    var warnings = try collectKeybindingWarnings(testing.allocator, json);
    defer warnings.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), countWarnings(&warnings, .duplicate));
    // Find the duplicate warning and check its key/context.
    for (warnings.items) |w| {
        if (w.kind == .duplicate) {
            try testing.expectEqualStrings("ctrl+y", w.key.?);
            try testing.expectEqualStrings("Global", w.context.?);
            try testing.expect(w.severity == .warning);
        }
    }
}

test "collectKeybindingWarnings allows the same key in different contexts" {
    // "enter" in both Chat and Confirmation is legitimate; the duplicate
    // scan must stay scoped to a single bindings block.
    const json =
        \\{ "bindings": [
        \\  { "context": "Chat", "bindings": { "enter": "chat:submit" } },
        \\  { "context": "Confirmation", "bindings": { "enter": "confirm:yes" } }
        \\] }
    ;
    var warnings = try collectKeybindingWarnings(testing.allocator, json);
    defer warnings.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), warnings.items.len);
}

test "collectKeybindingWarnings is silent on a valid config" {
    const json =
        \\{ "bindings": [
        \\  { "context": "Global", "bindings": {
        \\      "ctrl+o": "app:toggleTranscript",
        \\      "ctrl+t": "app:toggleTodos"
        \\  } },
        \\  { "context": "Chat", "bindings": {
        \\      "ctrl+u": "chat:clearLine",
        \\      "ctrl+g": "command:reload"
        \\  } }
        \\] }
    ;
    var warnings = try collectKeybindingWarnings(testing.allocator, json);
    defer warnings.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), warnings.items.len);
}

test "collectKeybindingWarnings flags a command binding outside Chat" {
    // command: prefixes are only valid in Chat; elsewhere parseCommandBinding
    // returns null and we surface a warning rather than dropping it silently.
    const json =
        \\{ "bindings": [
        \\  { "context": "Global", "bindings": { "ctrl+y": "command:reload" } }
        \\] }
    ;
    var warnings = try collectKeybindingWarnings(testing.allocator, json);
    defer warnings.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), countWarnings(&warnings, .invalid_action));
    try testing.expect(warnings.items[0].severity == .warning);
}

test "collectKeybindingWarnings flags a non-object block as parse_error" {
    const json =
        \\{ "bindings": [ "not an object" ] }
    ;
    var warnings = try collectKeybindingWarnings(testing.allocator, json);
    defer warnings.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), countWarnings(&warnings, .parse_error));
}

test "loadRuntimeKeybindings frees report warnings without leaking" {
    // Exercises the wrapper path so the leak-checking test allocator would
    // catch a missed deinit of report.warnings. It returns defaults when no
    // file is present, which is fine -- the point is the free path runs.
    var kb = loadRuntimeKeybindings(testing.allocator);
    kb.deinit(testing.allocator);
}
