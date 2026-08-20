const std = @import("std");
const builtin = @import("builtin");

/// Terminal notification helpers ported in spirit from
/// claude-code-main/src/services/notifier.ts. zcode had no
/// notification surface at all: a long agent turn would finish
/// and the user, having tabbed away, would miss the "ready for
/// your next prompt" moment. The reference supports ESC-sequence
/// notifications on iTerm2, kitty, and ghostty plus a universal
/// terminal bell fallback; we port the three most common channels
/// here.
///
/// The functions in this module are pure emit-to-writer helpers:
/// caller passes in the writer, we emit the right escape sequence.
/// Detection of WHICH channel to use is kept in `pickChannel` so
/// call sites can respect $TERM_PROGRAM without having to re-check.
///
/// Design notes:
/// - Every call site should be isatty-gated by the CALLER, not
///   here. This module is a leaf that knows the terminal
///   vocabulary, not a policy gate. That matches zcode's pattern
///   for clearTerminalSequence in format.zig (pass 91).
/// - Each emitter is a plain writer-typed function so callers can
///   send to stdout, a log file, or a memory buffer for tests.
pub const Channel = enum {
    /// ESC[9; iTerm2's proprietary notification escape
    iterm2,
    /// iTerm2 OSC 9 followed by a terminal bell. The reference's
    /// `iterm2_with_bell` channel: some profiles silence the OSC-9
    /// system notification, so a bell guarantees an audible cue.
    iterm2_with_bell,
    /// OSC 99; payload format used by kitty terminal
    kitty,
    /// OSC 777 notify; ghostty honours the same byte sequence
    ghostty,
    /// Universal ASCII BEL (\x07) -- works on every TTY
    bell,
    /// No-op for non-TTY targets
    none,
};

/// Emit a notification through `channel` to `writer`. On an
/// unrecognised channel (or `.none`) this is a no-op so callers
/// can wire it up unconditionally and let the channel picker
/// decide whether to fire.
pub fn emit(writer: anytype, channel: Channel, title: []const u8, message: []const u8) !void {
    switch (channel) {
        .iterm2 => try emitIterm2(writer, message),
        .iterm2_with_bell => {
            try emitIterm2(writer, message);
            try emitBell(writer);
        },
        .kitty => try emitKitty(writer, title, message),
        .ghostty => try emitGhostty(writer, title, message),
        .bell => try emitBell(writer),
        .none => {},
    }
}

/// Build the escape-sequence bytes for `channel` into `buf` and
/// return the slice. Single source of truth for the OSC/BEL wire
/// format -- call sites that can't easily plumb a writer (e.g.
/// direct File.writeAll on stdout) use this and `writeAll` the
/// returned slice, without having to hardcode the escape bytes.
///
/// Returns an empty slice for `.none` or when `buf` is too small
/// for the chosen channel. The caller should treat an empty
/// result as "do nothing" rather than falling through to bell,
/// because the buffer-too-small case is a programming error and
/// bell would mask it.
pub fn buildBytes(
    buf: []u8,
    channel: Channel,
    title: []const u8,
    message: []const u8,
) []const u8 {
    return switch (channel) {
        .iterm2 => std.fmt.bufPrint(buf, "\x1b]9;{s}\x07", .{message}) catch "",
        // OSC-9 then a trailing BEL byte. bufPrint into the same buffer
        // keeps it a single contiguous slice the caller can writeAll.
        .iterm2_with_bell => std.fmt.bufPrint(buf, "\x1b]9;{s}\x07\x07", .{message}) catch "",
        .kitty => std.fmt.bufPrint(buf, "\x1b]99;i=zcode;{s}\x07", .{message}) catch "",
        .ghostty => std.fmt.bufPrint(buf, "\x1b]777;notify;{s};{s}\x07", .{ title, message }) catch "",
        .bell => blk: {
            if (buf.len == 0) break :blk "";
            buf[0] = 0x07;
            break :blk buf[0..1];
        },
        .none => "",
    };
}

/// iTerm2's notification OSC: ESC]9;<message>BEL. Shown as a
/// transient system notification on macOS when iTerm2's
/// Preferences -> Profiles -> Terminal -> "Silence bell" is
/// configured appropriately. Matches the reference's
/// notifyITerm2 path.
pub fn emitIterm2(writer: anytype, message: []const u8) !void {
    try writer.writeAll("\x1b]9;");
    try writer.writeAll(message);
    try writer.writeAll("\x07");
}

/// kitty's OSC 99 notification: ESC]99;i=<id>;<message>BEL.
/// kitty uses the `i=` token to namespace the notification so
/// a later emission with the same id replaces the earlier one;
/// we pick a stable "zcode" id so spammy emits don't pile up.
pub fn emitKitty(writer: anytype, title: []const u8, message: []const u8) !void {
    _ = title; // kitty folds title + message into one body
    try writer.writeAll("\x1b]99;i=zcode;");
    try writer.writeAll(message);
    try writer.writeAll("\x07");
}

/// ghostty's OSC 777 notify: ESC]777;notify;<title>;<body>BEL.
/// This is the xterm-compatible desktop notification sequence,
/// also honoured by some other terminals.
pub fn emitGhostty(writer: anytype, title: []const u8, message: []const u8) !void {
    try writer.writeAll("\x1b]777;notify;");
    try writer.writeAll(title);
    try writer.writeAll(";");
    try writer.writeAll(message);
    try writer.writeAll("\x07");
}

/// Universal terminal bell (ASCII 0x07). Works on every TTY
/// ever shipped but most modern terminal emulators either
/// mute it by default or make it visually flash rather than
/// audibly beep.
pub fn emitBell(writer: anytype) !void {
    try writer.writeAll("\x07");
}

/// Pick the best notification channel for the current terminal.
/// Reads $TERM_PROGRAM, $KITTY_WINDOW_ID, and $GHOSTTY_RESOURCES_DIR
/// to detect which emulator we're running under and returns the
/// most specific channel that terminal supports. Falls back to
/// .bell when nothing matches, and to .none when $TERM is
/// unset (likely a pipe or non-interactive shell).
pub fn pickChannel() Channel {
    if (builtin.os.tag == .windows) return .none;

    // $TERM unset -> not a terminal
    if (@import("env.zig").getenv("TERM") == null) return .none;

    if (@import("env.zig").getenv("TERM_PROGRAM")) |prog| {
        if (std.mem.eql(u8, prog, "iTerm.app")) return .iterm2;
        if (std.mem.eql(u8, prog, "ghostty")) return .ghostty;
    }

    // kitty exports KITTY_WINDOW_ID for every session.
    if (@import("env.zig").getenv("KITTY_WINDOW_ID") != null) return .kitty;

    // ghostty also exports GHOSTTY_RESOURCES_DIR as a belt-and-
    // braces check if TERM_PROGRAM wasn't set (some multiplexers
    // strip it).
    if (@import("env.zig").getenv("GHOSTTY_RESOURCES_DIR") != null) return .ghostty;

    return .bell;
}

/// Resolve a notification channel from the user's `preferred_notif_channel`
/// config string. Ported from claude-code-main/src/services/notifier.ts
/// `sendToChannel` (the string -> channel dispatch). Recognised values:
///
///   "auto"                  -> pickChannel(), with the Apple_Terminal bell
///                              probe applied (see sendAuto in the reference)
///   "iterm2"                -> .iterm2
///   "iterm2_with_bell"      -> .iterm2_with_bell
///   "kitty"                 -> .kitty
///   "ghostty"               -> .ghostty
///   "terminal_bell"         -> .bell
///   "notifications_disabled"-> .none
///   anything else           -> .none  (the reference's `default: return 'none'`)
///
/// `allocator` is only used by the Apple_Terminal probe on the "auto" path;
/// callers always pass it so the signature stays stable regardless of which
/// branch fires.
pub fn channelFromConfig(name: []const u8, allocator: std.mem.Allocator) Channel {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "auto")) {
        return resolveAuto(allocator);
    }
    if (std.mem.eql(u8, trimmed, "iterm2")) return .iterm2;
    if (std.mem.eql(u8, trimmed, "iterm2_with_bell")) return .iterm2_with_bell;
    if (std.mem.eql(u8, trimmed, "kitty")) return .kitty;
    if (std.mem.eql(u8, trimmed, "ghostty")) return .ghostty;
    if (std.mem.eql(u8, trimmed, "terminal_bell")) return .bell;
    if (std.mem.eql(u8, trimmed, "notifications_disabled")) return .none;
    // Unknown value: fall back to .none rather than guessing, matching the
    // reference's `default: return 'none'`. Documented in the task spec.
    return .none;
}

/// The "auto" channel: detect the terminal, but special-case Apple Terminal.
/// Apple Terminal has no OSC notification escape, so the only signal we can
/// raise is the bell -- and even that is pointless when the OS profile already
/// rings its own bell. Mirror the reference's `sendAuto` Apple_Terminal arm:
/// ring the bell ONLY when the profile's bell is disabled (so we provide the
/// cue the OS would not), otherwise stay silent (`no_method_available`).
fn resolveAuto(allocator: std.mem.Allocator) Channel {
    const base = pickChannel();
    if (base == .bell) {
        // pickChannel() falls back to .bell for unrecognised terminals,
        // including Apple Terminal. Apply the bell probe there.
        if (@import("env.zig").getenv("TERM_PROGRAM")) |prog| {
            if (std.mem.eql(u8, prog, "Apple_Terminal")) {
                return if (isAppleTerminalBellDisabled(allocator)) .bell else .none;
            }
        }
    }
    return base;
}

/// Probe whether Apple Terminal's current profile has its bell DISABLED.
/// Returns true only when we can positively confirm `Bell == false` for the
/// front window's current settings profile. Every error path returns false
/// (= "bell enabled / let the OS handle it"), matching the reference's
/// catch-all `return false`. macOS-only and gated behind
/// TERM_PROGRAM == "Apple_Terminal"; everywhere else this is a cheap false.
///
/// Reference: claude-code-main/src/services/notifier.ts isAppleTerminalBellDisabled.
/// We avoid a real plist parser (the reference lazy-loads a ~280KB dep); a
/// targeted byte scan of `defaults export com.apple.Terminal -` is enough to
/// find the profile block and its Bell boolean, and stays Simplicity-First.
fn isAppleTerminalBellDisabled(allocator: std.mem.Allocator) bool {
    if (builtin.os.tag != .macos) return false;

    const prog = @import("env.zig").getenv("TERM_PROGRAM") orelse return false;
    if (!std.mem.eql(u8, prog, "Apple_Terminal")) return false;

    const profile = currentTerminalProfile(allocator) orelse return false;
    defer allocator.free(profile);
    if (profile.len == 0) return false;

    const defaults_out = runCapture(allocator, &.{
        "defaults", "export", "com.apple.Terminal", "-",
    }) orelse return false;
    defer allocator.free(defaults_out);

    return profileBellDisabled(defaults_out, profile);
}

/// osascript the front window's current settings profile name. Returns an
/// owned, trimmed slice (caller frees) or null on any failure.
fn currentTerminalProfile(allocator: std.mem.Allocator) ?[]u8 {
    const out = runCapture(allocator, &.{
        "osascript",
        "-e",
        "tell application \"Terminal\" to name of current settings of front window",
    }) orelse return null;
    const trimmed = std.mem.trim(u8, out, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(out);
        return null;
    }
    // Re-dupe the trimmed portion so the returned slice owns exactly its bytes.
    const owned = allocator.dupe(u8, trimmed) catch {
        allocator.free(out);
        return null;
    };
    allocator.free(out);
    return owned;
}

/// One-shot capture of a command's trimmed stdout, or null when it cannot run
/// or exits non-zero. Conservative by design: the notify path must never throw.
fn runCapture(allocator: std.mem.Allocator, argv: []const []const u8) ?[]u8 {
    const result = std.process.run(allocator, @import("zcode_runtime").io, .{
        .argv = argv,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 16),
    }) catch return null;
    allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                allocator.free(result.stdout);
                return null;
            }
        },
        else => {
            allocator.free(result.stdout);
            return null;
        },
    }
    return result.stdout;
}

/// Scan `defaults export` plist text for `<key>Window Settings</key>` ->
/// `<key>{profile}</key>` -> the profile's dict, and decide whether that dict
/// declares `Bell` as `<false/>`. Pure string scan so it is unit-testable
/// without a real Terminal.app. Returns false when the profile or Bell key is
/// not found (conservative: treat unknown as "bell enabled").
fn profileBellDisabled(plist: []const u8, profile: []const u8) bool {
    // Find the "Window Settings" dict.
    const ws_marker = "<key>Window Settings</key>";
    const ws_at = std.mem.indexOf(u8, plist, ws_marker) orelse return false;
    const after_ws = plist[ws_at + ws_marker.len ..];

    // Locate the profile key within Window Settings.
    var prof_key_buf: [256]u8 = undefined;
    const prof_key = std.fmt.bufPrint(&prof_key_buf, "<key>{s}</key>", .{profile}) catch return false;
    const prof_at_rel = std.mem.indexOf(u8, after_ws, prof_key) orelse return false;
    const after_prof = after_ws[prof_at_rel + prof_key.len ..];

    // The profile's dict opens with the next <dict>. Find its matching
    // </dict> by depth-counting so we only inspect this profile's block.
    const dict_open = std.mem.indexOf(u8, after_prof, "<dict>") orelse return false;
    var i: usize = dict_open + "<dict>".len;
    var depth: usize = 1;
    const block_start = i;
    while (i < after_prof.len and depth > 0) {
        if (std.mem.startsWith(u8, after_prof[i..], "<dict>")) {
            depth += 1;
            i += "<dict>".len;
        } else if (std.mem.startsWith(u8, after_prof[i..], "</dict>")) {
            depth -= 1;
            if (depth == 0) break;
            i += "</dict>".len;
        } else {
            i += 1;
        }
    }
    if (depth != 0) return false;
    const block = after_prof[block_start..i];

    // Within this profile's dict, find <key>Bell</key> and inspect the next
    // boolean tag. Skip whitespace between the key and its value.
    const bell_key = "<key>Bell</key>";
    const bell_at = std.mem.indexOf(u8, block, bell_key) orelse return false;
    const after_bell = std.mem.trimStart(u8, block[bell_at + bell_key.len ..], " \t\r\n");
    return std.mem.startsWith(u8, after_bell, "<false/>");
}

const testing = std.testing;

test "emitBell writes a single \\x07 byte" {
    var buf: [16]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try emitBell(&fbs);
    try testing.expectEqualStrings("\x07", fbs.buffered());
}

test "emitIterm2 wraps the message in OSC 9" {
    var buf: [128]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try emitIterm2(&fbs, "turn complete");
    try testing.expectEqualStrings("\x1b]9;turn complete\x07", fbs.buffered());
}

test "emitKitty embeds id=zcode and the message body" {
    var buf: [128]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try emitKitty(&fbs, "zcode", "done");
    try testing.expectEqualStrings("\x1b]99;i=zcode;done\x07", fbs.buffered());
}

test "emitGhostty uses OSC 777 with title;body" {
    var buf: [128]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try emitGhostty(&fbs, "zcode", "agent idle");
    try testing.expectEqualStrings("\x1b]777;notify;zcode;agent idle\x07", fbs.buffered());
}

test "emit dispatches to the right channel" {
    var buf: [128]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);

    try emit(&fbs, .bell, "zcode", "hi");
    try testing.expectEqualStrings("\x07", fbs.buffered());

    fbs.end = 0;
    try emit(&fbs, .iterm2, "zcode", "hi");
    try testing.expect(std.mem.startsWith(u8, fbs.buffered(), "\x1b]9;"));
    try testing.expect(std.mem.endsWith(u8, fbs.buffered(), "\x07"));

    fbs.end = 0;
    try emit(&fbs, .none, "zcode", "hi");
    try testing.expectEqualStrings("", fbs.buffered());
}

test "pickChannel returns a defined value without crashing" {
    const got = pickChannel();
    try testing.expect(got == .iterm2 or got == .kitty or got == .ghostty or got == .bell or got == .none);
}

test "buildBytes iterm2 produces OSC 9" {
    var buf: [128]u8 = undefined;
    const got = buildBytes(&buf, .iterm2, "zcode", "done");
    try testing.expectEqualStrings("\x1b]9;done\x07", got);
}

test "buildBytes kitty uses id=zcode namespace" {
    var buf: [128]u8 = undefined;
    const got = buildBytes(&buf, .kitty, "zcode", "done");
    try testing.expectEqualStrings("\x1b]99;i=zcode;done\x07", got);
}

test "buildBytes ghostty includes both title and body" {
    var buf: [128]u8 = undefined;
    const got = buildBytes(&buf, .ghostty, "zcode", "agent idle");
    try testing.expectEqualStrings("\x1b]777;notify;zcode;agent idle\x07", got);
}

test "buildBytes bell returns single 0x07 byte" {
    var buf: [128]u8 = undefined;
    const got = buildBytes(&buf, .bell, "ignored", "ignored");
    try testing.expectEqualSlices(u8, &.{0x07}, got);
}

test "buildBytes none returns empty" {
    var buf: [128]u8 = undefined;
    const got = buildBytes(&buf, .none, "zcode", "done");
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "buildBytes refuses to overflow a too-small buffer" {
    // Message is longer than the buffer; bufPrint returns
    // NoSpaceLeft which buildBytes catches into an empty slice.
    var buf: [4]u8 = undefined;
    const got = buildBytes(&buf, .iterm2, "zcode", "this message is far too long for the 4-byte buffer");
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "buildBytes emits bell even with a 1-byte buffer" {
    var buf: [1]u8 = undefined;
    const got = buildBytes(&buf, .bell, "", "");
    try testing.expectEqualSlices(u8, &.{0x07}, got);
}

test "buildBytes matches emit output byte-for-byte for each channel" {
    // Both paths should produce identical bytes so tests written
    // against emit() keep working after callers switch to buildBytes.
    var build_buf: [128]u8 = undefined;
    var emit_buf: [128]u8 = undefined;

    const channels = [_]Channel{ .iterm2, .iterm2_with_bell, .kitty, .ghostty, .bell };
    for (channels) |channel| {
        var emit_stream = std.Io.Writer.fixed(&emit_buf);
        try emit(&emit_stream, channel, "zcode", "hi");
        const emit_got = emit_stream.buffered();

        const build_got = buildBytes(&build_buf, channel, "zcode", "hi");
        try testing.expectEqualStrings(emit_got, build_got);
    }
}

test "channelFromConfig maps explicit channel names" {
    try testing.expectEqual(Channel.iterm2, channelFromConfig("iterm2", testing.allocator));
    try testing.expectEqual(Channel.iterm2_with_bell, channelFromConfig("iterm2_with_bell", testing.allocator));
    try testing.expectEqual(Channel.kitty, channelFromConfig("kitty", testing.allocator));
    try testing.expectEqual(Channel.ghostty, channelFromConfig("ghostty", testing.allocator));
    try testing.expectEqual(Channel.bell, channelFromConfig("terminal_bell", testing.allocator));
}

test "channelFromConfig disabled maps to none" {
    try testing.expectEqual(Channel.none, channelFromConfig("notifications_disabled", testing.allocator));
}

test "channelFromConfig unknown value falls back to none" {
    // Matches the reference's `default: return 'none'`. We deliberately do
    // NOT fall back to auto-detection for a garbage value so a typo'd config
    // fails closed (silent) rather than surprising the user with a bell.
    try testing.expectEqual(Channel.none, channelFromConfig("nonsense-value", testing.allocator));
}

test "channelFromConfig auto resolves to a defined channel" {
    // "auto" runs detection; the exact result depends on the test terminal,
    // but it must be one of the known variants and must not crash.
    const got = channelFromConfig("auto", testing.allocator);
    try testing.expect(got == .iterm2 or got == .kitty or got == .ghostty or got == .bell or got == .none);
    // Empty / whitespace string is treated as "auto" too.
    const got_empty = channelFromConfig("   ", testing.allocator);
    try testing.expect(got_empty == .iterm2 or got_empty == .kitty or got_empty == .ghostty or got_empty == .bell or got_empty == .none);
}

test "buildBytes iterm2_with_bell appends a trailing bell to the OSC-9 sequence" {
    var buf: [128]u8 = undefined;
    const got = buildBytes(&buf, .iterm2_with_bell, "zcode", "done");
    try testing.expectEqualStrings("\x1b]9;done\x07\x07", got);
    // Last byte is the bell.
    try testing.expectEqual(@as(u8, 0x07), got[got.len - 1]);
}

test "isAppleTerminalBellDisabled is conservative off Apple Terminal" {
    // Without TERM_PROGRAM == Apple_Terminal (the test harness env), the probe
    // must short-circuit to false (= bell enabled / let the OS handle it) and
    // never spawn osascript/defaults. Just assert it returns a bool quietly.
    const got = isAppleTerminalBellDisabled(testing.allocator);
    try testing.expectEqual(false, got);
}

test "profileBellDisabled detects Bell false in the current profile" {
    const plist =
        \\<dict>
        \\<key>Window Settings</key>
        \\<dict>
        \\<key>Basic</key>
        \\<dict>
        \\<key>Bell</key>
        \\<true/>
        \\</dict>
        \\<key>Pro</key>
        \\<dict>
        \\<key>Bell</key>
        \\<false/>
        \\</dict>
        \\</dict>
        \\</dict>
    ;
    try testing.expect(profileBellDisabled(plist, "Pro"));
    try testing.expect(!profileBellDisabled(plist, "Basic"));
    // Unknown profile -> conservative false (bell enabled).
    try testing.expect(!profileBellDisabled(plist, "Nope"));
}

test "profileBellDisabled returns false when Window Settings is missing" {
    try testing.expect(!profileBellDisabled("<dict></dict>", "Basic"));
}
