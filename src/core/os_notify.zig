const std = @import("std");
const builtin = @import("builtin");
const rt = @import("zcode_runtime");

/// OS-native desktop notifications for detached processes.
///
/// `core/notifier.zig` speaks the terminal's escape-sequence
/// vocabulary, which reaches a notification only because some
/// attached terminal emulator (iTerm2, kitty, ghostty) translates
/// the bytes. zcode's KAIROS background agent (see docs/KAIROS.md)
/// runs *detached* -- there is no terminal listening, so those
/// escape codes go nowhere. This module instead shells out to the
/// platform's native notification tool so a detached agent can
/// still surface "I'm done / I need you" to the user.
///
/// Design notes:
/// - This is a leaf that knows how to spawn the platform notifier,
///   not a policy gate. Callers decide *whether* to notify.
/// - `notify` is strictly best-effort: it swallows every error
///   (tool missing, spawn failure, non-zero exit). A background
///   agent must never crash or block because the desktop happens
///   to lack `notify-send` or `osascript`.
/// - argv is passed straight to the OS with no shell in between,
///   so on Linux we need no escaping at all. macOS is the only
///   place that needs escaping, and only at the AppleScript
///   string level (the script is one argv element to `osascript`).
/// True on platforms where we have a native notification backend.
/// macOS uses `osascript`; Linux uses `notify-send`. Everything
/// else (Windows, *BSD, WASI, ...) has no backend and is a no-op.
pub fn available() bool {
    return switch (builtin.os.tag) {
        .macos, .linux => true,
        else => false,
    };
}

/// Best-effort native notification. Never panics, never blocks on
/// output, swallows all errors. On platforms without a backend
/// (`available() == false`) this returns immediately.
pub fn notify(allocator: std.mem.Allocator, title: []const u8, body: []const u8) void {
    switch (builtin.os.tag) {
        .macos => notifyMacos(allocator, title, body),
        .linux => notifyLinux(allocator, title, body),
        else => {},
    }
}

/// macOS backend: `osascript -e 'display notification "<body>" with title "<title>"'`.
/// The whole AppleScript program is a single argv element, so the
/// only escaping that matters is AppleScript's own double-quoted
/// string syntax (backslash-escape `"` and `\`).
fn notifyMacos(allocator: std.mem.Allocator, title: []const u8, body: []const u8) void {
    const esc_title = escapeAppleScript(allocator, title) catch return;
    defer allocator.free(esc_title);
    const esc_body = escapeAppleScript(allocator, body) catch return;
    defer allocator.free(esc_body);

    const script = std.fmt.allocPrint(
        allocator,
        "display notification \"{s}\" with title \"{s}\"",
        .{ esc_body, esc_title },
    ) catch return;
    defer allocator.free(script);

    const argv = [_][]const u8{ "osascript", "-e", script };
    runBestEffort(allocator, &argv);
}

/// Linux backend: `notify-send <title> <body>`. argv elements are
/// passed literally (no shell), so neither title nor body needs
/// any escaping.
fn notifyLinux(allocator: std.mem.Allocator, title: []const u8, body: []const u8) void {
    const argv = [_][]const u8{ "notify-send", title, body };
    runBestEffort(allocator, &argv);
}

/// Spawn `argv` and discard its output. Caps stdout/stderr so a
/// chatty notifier can't balloon memory, frees whatever came back,
/// and swallows every error -- this is the single best-effort
/// chokepoint both backends funnel through.
fn runBestEffort(allocator: std.mem.Allocator, argv: []const []const u8) void {
    const result = std.process.run(allocator, rt.io, .{
        .argv = argv,
        .stdout_limit = .limited(4 * 1024),
        .stderr_limit = .limited(4 * 1024),
    }) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

/// Escape `s` for embedding inside an AppleScript double-quoted
/// string literal. AppleScript uses C-style backslash escaping
/// inside `"..."`, so the two characters that would otherwise break
/// the string -- `\` and `"` -- each get a leading backslash.
/// Pure function: allocates and returns an owned slice the caller
/// must free. Kept separate from the spawn path so it's testable
/// without firing a real notification.
fn escapeAppleScript(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        if (c == '"' or c == '\\') try out.append(allocator, '\\');
        try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

const testing = std.testing;

test "available matches the compiled-in OS backend" {
    const expected = switch (builtin.os.tag) {
        .macos, .linux => true,
        else => false,
    };
    try testing.expectEqual(expected, available());
}

test "escapeAppleScript escapes embedded double quotes" {
    const got = try escapeAppleScript(testing.allocator, "he said \"hi\"");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("he said \\\"hi\\\"", got);
}

test "escapeAppleScript escapes backslashes" {
    const got = try escapeAppleScript(testing.allocator, "a\\b");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("a\\\\b", got);
}

test "escapeAppleScript leaves a plain string unchanged" {
    const got = try escapeAppleScript(testing.allocator, "agent idle");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("agent idle", got);
}

test "escapeAppleScript handles an empty string" {
    const got = try escapeAppleScript(testing.allocator, "");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("", got);
}

test "escapeAppleScript escapes both quote and backslash together" {
    const got = try escapeAppleScript(testing.allocator, "\\\"");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("\\\\\\\"", got);
}
