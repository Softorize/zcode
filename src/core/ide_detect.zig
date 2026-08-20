//! Detect the parent IDE / editor from process env.
//!
//! Powers `/ide`. Mirrors the reference's `/ide` which inspects
//! well-known env vars set by terminal-embedded IDEs and reports
//! what it finds.

const std = @import("std");
const std_io = @import("std_io.zig");
const xdg = @import("xdg.zig");

pub const IdeKind = enum {
    vscode,
    cursor,
    windsurf,
    jetbrains,
    zed,
    warp,
    iterm,
    apple_terminal,
    wezterm,
    kitty,
    alacritty,
    ghostty,
    tmux,
    ssh,
    unknown,
};

pub const Detected = struct {
    kind: IdeKind,
    label: []u8,
    matched_env: []u8,

    pub fn deinit(self: *Detected, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.matched_env);
    }
};

const MatchMode = enum {
    /// Env var is present and non-empty -> match.
    presence,
    /// Env var value must equal label_or_pattern (case-insensitive).
    eq_ci,
    /// Env var value must contain label_or_pattern as a substring.
    contains,
};

const Rule = struct {
    env: []const u8,
    mode: MatchMode,
    /// For `eq_ci` / `contains`, the expected value. For `presence`
    /// this is ignored and the display label is taken from `label`.
    pattern: []const u8 = "",
    kind: IdeKind,
    label: []const u8,
};

/// Ordered most-specific first. The first rule that fires wins,
/// so e.g. Cursor must be checked before VS Code (Cursor is a
/// VS Code fork that still sets TERM_PROGRAM=vscode).
const rules = [_]Rule{
    .{ .env = "CURSOR_TRACE_ID", .mode = .presence, .kind = .cursor, .label = "Cursor" },
    .{ .env = "WINDSURF_IDE", .mode = .presence, .kind = .windsurf, .label = "Windsurf" },
    .{ .env = "TERM_PROGRAM", .mode = .eq_ci, .pattern = "vscode", .kind = .vscode, .label = "VS Code" },
    .{ .env = "TERM_PROGRAM", .mode = .eq_ci, .pattern = "iTerm.app", .kind = .iterm, .label = "iTerm2" },
    .{ .env = "TERM_PROGRAM", .mode = .eq_ci, .pattern = "Apple_Terminal", .kind = .apple_terminal, .label = "Apple Terminal" },
    .{ .env = "TERM_PROGRAM", .mode = .eq_ci, .pattern = "WezTerm", .kind = .wezterm, .label = "WezTerm" },
    .{ .env = "TERM_PROGRAM", .mode = .eq_ci, .pattern = "ghostty", .kind = .ghostty, .label = "Ghostty" },
    .{ .env = "TERM_PROGRAM", .mode = .eq_ci, .pattern = "WarpTerminal", .kind = .warp, .label = "Warp" },
    .{ .env = "TERMINAL_EMULATOR", .mode = .contains, .pattern = "JetBrains", .kind = .jetbrains, .label = "JetBrains IDE" },
    .{ .env = "ZED_TERM", .mode = .presence, .kind = .zed, .label = "Zed" },
    .{ .env = "KITTY_WINDOW_ID", .mode = .presence, .kind = .kitty, .label = "kitty" },
    .{ .env = "ALACRITTY_SOCKET", .mode = .presence, .kind = .alacritty, .label = "Alacritty" },
    .{ .env = "TMUX", .mode = .presence, .kind = .tmux, .label = "tmux session" },
    .{ .env = "SSH_CONNECTION", .mode = .presence, .kind = .ssh, .label = "SSH session" },
};

pub fn detect(allocator: std.mem.Allocator) !Detected {
    for (rules) |r| {
        const value_opt = xdg.getEnvOptional(allocator, r.env);
        defer if (value_opt) |v| allocator.free(v);
        const value = value_opt orelse continue;

        const matched = switch (r.mode) {
            .presence => value.len > 0,
            .eq_ci => std.ascii.eqlIgnoreCase(value, r.pattern),
            .contains => std.mem.indexOf(u8, value, r.pattern) != null,
        };
        if (!matched) continue;

        return .{
            .kind = r.kind,
            .label = try allocator.dupe(u8, r.label),
            .matched_env = try allocator.dupe(u8, r.env),
        };
    }
    return .{
        .kind = .unknown,
        .label = try allocator.dupe(u8, "unknown terminal"),
        .matched_env = try allocator.dupe(u8, ""),
    };
}

pub fn render(allocator: std.mem.Allocator) ![]u8 {
    var det = try detect(allocator);
    defer det.deinit(allocator);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.print("detected: {s}\n", .{det.label});
    if (det.matched_env.len > 0) {
        try w.print("  via env: {s}\n", .{det.matched_env});
    }

    switch (det.kind) {
        .vscode, .cursor, .windsurf => {
            try w.writeAll("\nthe packaged VS Code extension can pick up zcode sessions. see `docs/ide-extension.md`.\n");
        },
        .jetbrains => {
            try w.writeAll("\nJetBrains IDEs are not yet natively integrated. the JSON-lines API is available for plugin authors.\n");
        },
        .zed, .warp, .iterm, .apple_terminal, .wezterm, .kitty, .alacritty, .ghostty => {
            try w.writeAll("\nno IDE handshake needed. running in a pure terminal emulator.\n");
        },
        .tmux => try w.writeAll("\ntmux detected. truecolor requires `set -g default-terminal 'tmux-256color'` and `tmux -2`.\n"),
        .ssh => try w.writeAll("\nremote session over SSH. the remote daemon (`zcode daemon`) can expose sessions for browser handoff.\n"),
        .unknown => try w.writeAll("\nno recognised editor/terminal env vars set.\n"),
    }
    return out.toOwnedSlice();
}
