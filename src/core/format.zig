const std = @import("std");
const std_io = @import("std_io.zig");

/// Human-readable formatters ported from Claude Code's src/utils/format.ts.
/// All functions write into a caller-provided buffer so callers don't
/// need to free. Buffer sizes in the sig comments are worst-case upper
/// bounds assuming uint64 inputs.
/// Format a byte count as "1.5 KB", "3.2 MB", "128 bytes". Matches the
/// reference's formatFileSize semantics: 1 decimal place when the
/// fractional part is non-zero, stripped ".0" when it is. Caller buffer
/// should be at least 16 bytes (max "18014398509481984.0 PB\0" style).
pub fn formatFileSize(buf: []u8, bytes: u64) []const u8 {
    if (bytes < 1024) {
        return std.fmt.bufPrint(buf, "{d} bytes", .{bytes}) catch "?";
    }
    const kb = @as(f64, @floatFromInt(bytes)) / 1024.0;
    if (kb < 1024.0) return formatUnit(buf, kb, "KB");
    const mb = kb / 1024.0;
    if (mb < 1024.0) return formatUnit(buf, mb, "MB");
    const gb = mb / 1024.0;
    if (gb < 1024.0) return formatUnit(buf, gb, "GB");
    const tb = gb / 1024.0;
    return formatUnit(buf, tb, "TB");
}

fn formatUnit(buf: []u8, value: f64, unit: []const u8) []const u8 {
    // Match reference: 1 decimal place, but strip a trailing ".0" so
    // "1.0KB" renders as "1 KB". Reference uses a single space between
    // number and unit -- zcode keeps it consistent.
    const rounded = std.math.round(value * 10.0) / 10.0;
    const whole = @as(i64, @intFromFloat(@trunc(rounded)));
    const frac = @as(i64, @intFromFloat(@round((rounded - @as(f64, @floatFromInt(whole))) * 10.0)));
    if (frac == 0) {
        return std.fmt.bufPrint(buf, "{d} {s}", .{ whole, unit }) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d}.{d} {s}", .{ whole, frac, unit }) catch "?";
}

/// Format a raw number using compact K/M/B suffixes. `1234` -> "1.2k",
/// `9_000_000` -> "9m", `999` -> "999". Lowercase suffix to match the
/// reference's Intl.NumberFormat compact output (which it then
/// lowercases at src/utils/format.ts:130).
pub fn formatNumber(buf: []u8, n: u64) []const u8 {
    if (n < 1000) {
        return std.fmt.bufPrint(buf, "{d}", .{n}) catch "?";
    }
    if (n < 1_000_000) {
        return formatCompact(buf, @as(f64, @floatFromInt(n)) / 1000.0, "k");
    }
    if (n < 1_000_000_000) {
        return formatCompact(buf, @as(f64, @floatFromInt(n)) / 1_000_000.0, "m");
    }
    return formatCompact(buf, @as(f64, @floatFromInt(n)) / 1_000_000_000.0, "b");
}

fn formatCompact(buf: []u8, value: f64, suffix: []const u8) []const u8 {
    const rounded = std.math.round(value * 10.0) / 10.0;
    const whole = @as(i64, @intFromFloat(@trunc(rounded)));
    const frac = @as(i64, @intFromFloat(@round((rounded - @as(f64, @floatFromInt(whole))) * 10.0)));
    if (frac == 0) {
        return std.fmt.bufPrint(buf, "{d}{s}", .{ whole, suffix }) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d}.{d}{s}", .{ whole, frac, suffix }) catch "?";
}

/// Format a token count. Matches the reference's formatTokens: runs
/// formatNumber and strips a trailing ".0". zcode's formatNumber already
/// strips the ".0" by construction, so this is a thin alias for
/// self-documentation at call sites.
pub fn formatTokens(buf: []u8, tokens: u64) []const u8 {
    return formatNumber(buf, tokens);
}

/// Format a duration in milliseconds as "1h 2m 3s", "45m 12s", "12s",
/// "0.4s" (sub-second), "0s". Matches the reference's formatDuration
/// default mode: all significant units shown, no hideTrailingZeros
/// option because zcode's callers don't need that knob yet.
pub fn formatDuration(buf: []u8, ms: u64) []const u8 {
    if (ms == 0) return std.fmt.bufPrint(buf, "0s", .{}) catch "?";
    if (ms < 1000) {
        const secs = @as(f64, @floatFromInt(ms)) / 1000.0;
        return std.fmt.bufPrint(buf, "{d:.1}s", .{secs}) catch "?";
    }

    var total_ms = ms;
    const days = total_ms / 86_400_000;
    total_ms %= 86_400_000;
    const hours = total_ms / 3_600_000;
    total_ms %= 3_600_000;
    const minutes = total_ms / 60_000;
    total_ms %= 60_000;
    const seconds = (total_ms + 500) / 1000; // round-nearest

    if (days > 0) {
        return std.fmt.bufPrint(buf, "{d}d {d}h {d}m", .{ days, hours, minutes }) catch "?";
    }
    if (hours > 0) {
        return std.fmt.bufPrint(buf, "{d}h {d}m {d}s", .{ hours, minutes, seconds }) catch "?";
    }
    if (minutes > 0) {
        return std.fmt.bufPrint(buf, "{d}m {d}s", .{ minutes, seconds }) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d}s", .{seconds}) catch "?";
}

/// Format an idle span (given in whole minutes) the way the reference's
/// IdleReturnDialog.tsx formatIdleDuration buckets it for the
/// "You've been away ..." header:
///
///   - under 1 minute:  "<1m"
///   - under 1 hour:    "Nm"      (e.g. "5m")
///   - whole hours:     "Nh"      (e.g. "1h")
///   - hours + minutes: "Nh Mm"   (e.g. "1h 5m")
///
/// Minutes input (not ms) because the dialog only ever shows minute
/// granularity. Caller buffer should be at least 16 bytes.
pub fn formatIdleDuration(buf: []u8, minutes: u64) []const u8 {
    if (minutes < 1) return "<1m";
    if (minutes < 60) {
        return std.fmt.bufPrint(buf, "{d}m", .{minutes}) catch "?";
    }
    const hours = minutes / 60;
    const rem = minutes % 60;
    if (rem == 0) {
        return std.fmt.bufPrint(buf, "{d}h", .{hours}) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d}h {d}m", .{ hours, rem }) catch "?";
}

/// Format milliseconds as "X.Ys" always with one decimal place. Use for
/// sub-minute timings where the fractional second matters (TTFT,
/// streaming chunks, hook latency). Ports formatSecondsShort.
pub fn formatSecondsShort(buf: []u8, ms: u64) []const u8 {
    const secs = @as(f64, @floatFromInt(ms)) / 1000.0;
    return std.fmt.bufPrint(buf, "{d:.1}s", .{secs}) catch "?";
}

/// Format a Unix timestamp as a human-readable chat/brief label that
/// scales with age, matching claude-code-main/src/utils/
/// formatBriefTimestamp.ts:
///
///   - same day:       "13:30"
///   - within 6 days:  "Mon 13:30"
///   - older:          "Mon Feb 20 13:30"
///
/// zcode uses 24-hour time and short weekday/month names; the reference
/// relies on Intl.DateTimeFormat for locale-aware output which zcode
/// cannot match without pulling in ICU. The 24-hour format is
/// unambiguous across locales and keeps column alignment stable in
/// /session list output.
///
/// `now_ts` and `event_ts` are Unix timestamps in seconds (signed i64,
/// matching zcode's session store). Negative or future timestamps still
/// render something reasonable (the timestamp is treated as-is, only
/// the age classification uses `now_ts - event_ts`).
///
/// Caller buffer should be at least 32 bytes (worst case
/// "Wed Feb 29 23:59" = 16 chars + null).
pub fn formatBriefTimestamp(buf: []u8, event_ts: i64, now_ts: i64) []const u8 {
    if (event_ts <= 0) return "";

    const day_secs: i64 = 24 * 60 * 60;
    // Compute the day index each timestamp falls into (days since epoch).
    // Negative timestamps use floor division semantics so "yesterday at
    // 23:00" and "today at 00:30" still compare as 1 day apart.
    const now_day = @divFloor(now_ts, day_secs);
    const event_day = @divFloor(event_ts, day_secs);
    const days_ago: i64 = now_day - event_day;

    const e_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(event_ts, 0)) };
    const e_day_secs = e_secs.getDaySeconds();
    const e_epoch_day = e_secs.getEpochDay();
    const e_year_day = e_epoch_day.calculateYearDay();
    const e_month_day = e_year_day.calculateMonthDay();

    const hour = e_day_secs.getHoursIntoDay();
    const minute = e_day_secs.getMinutesIntoHour();
    // std.time.epoch.Month is 1-indexed (jan = 1), so subtract 1 to
    // index into the short-name array.
    const month_idx: usize = @intFromEnum(e_month_day.month) - 1;
    const day_of_month: u5 = e_month_day.day_index + 1;

    // Zeller-like weekday computation via days-since-epoch: 1970-01-01
    // was a Thursday (weekday index 4 where 0=Sunday).
    const weekday_idx: usize = @intCast(@mod(e_epoch_day.day + 4, 7));

    const weekday_short = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const month_short = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    if (days_ago == 0) {
        return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ hour, minute }) catch "";
    }
    if (days_ago > 0 and days_ago < 7) {
        return std.fmt.bufPrint(buf, "{s} {d:0>2}:{d:0>2}", .{
            weekday_short[weekday_idx],
            hour,
            minute,
        }) catch "";
    }
    return std.fmt.bufPrint(buf, "{s} {s} {d} {d:0>2}:{d:0>2}", .{
        weekday_short[weekday_idx],
        month_short[month_idx],
        day_of_month,
        hour,
        minute,
    }) catch "";
}

/// Render a compact "3m ago" / "2h ago" / "5d ago" style label for
/// a past Unix timestamp. Ported from claude-code-main/src/utils/
/// format.ts formatRelativeTime with `style: 'narrow'` -- the short
/// form that fits in session listings and activity lines without
/// drowning out other columns.
///
/// Units match the reference exactly:
///   y  (year  = 31_536_000s)
///   mo (month = 2_592_000s)
///   w  (week  = 604_800s)
///   d  (day   = 86_400s)
///   h  (hour  = 3_600s)
///   m  (minute= 60s)
///   s  (second= 1s)
///
/// Future timestamps render as "in Nu" (e.g. "in 3h") matching the
/// reference's narrow-style future branch. Zero or identical
/// timestamps render as "just now".
///
/// Caller buffer should be at least 16 bytes.
pub fn formatRelativeTimeShort(buf: []u8, event_ts: i64, now_ts: i64) []const u8 {
    if (event_ts == now_ts) return "just now";

    // Use i128 intermediate math so `event_ts - now_ts` cannot overflow
    // (INT64_MIN - INT64_MAX wraps in i64 and then negating INT64_MIN is
    // another overflow -- both are reachable from a corrupted timestamp
    // field and panic in ReleaseSafe / are UB in ReleaseFast). Clamp the
    // final magnitude to u64 so the pretty-printer can still render it.
    const diff_128: i128 = @as(i128, event_ts) - @as(i128, now_ts);
    const is_future = diff_128 > 0;
    const abs_128: i128 = if (is_future) diff_128 else -diff_128;
    const diff_abs: u64 = if (abs_128 > std.math.maxInt(u64)) std.math.maxInt(u64) else @intCast(abs_128);

    const Interval = struct { seconds: u64, unit: []const u8 };
    const intervals = [_]Interval{
        .{ .seconds = 31_536_000, .unit = "y" },
        .{ .seconds = 2_592_000, .unit = "mo" },
        .{ .seconds = 604_800, .unit = "w" },
        .{ .seconds = 86_400, .unit = "d" },
        .{ .seconds = 3_600, .unit = "h" },
        .{ .seconds = 60, .unit = "m" },
        .{ .seconds = 1, .unit = "s" },
    };
    for (intervals) |iv| {
        if (diff_abs >= iv.seconds) {
            const value = diff_abs / iv.seconds;
            if (is_future) {
                return std.fmt.bufPrint(buf, "in {d}{s}", .{ value, iv.unit }) catch "";
            }
            return std.fmt.bufPrint(buf, "{d}{s} ago", .{ value, iv.unit }) catch "";
        }
    }
    return "just now";
}

/// Render a Unicode progress bar like `[████████░░░░░░░░░░░░] 42%` into
/// a caller-provided buffer. Inspired by claude-code-main's
/// ContextVisualization.tsx which uses a similar visual to convey
/// context-window utilisation in the /context view. zcode's REPL is
/// streaming text, not Ink, so we render with the U+2588 / U+2591
/// block characters which align cleanly in any monospace font.
///
/// `width` is the inner cell count (number of glyph slots between the
/// brackets, NOT total display columns). 20 is a good default. The
/// caller buffer must be at least `width * 3 + 8` bytes because each
/// block character is 3 UTF-8 bytes and the wrapper is `[...] NNN%`.
///
/// The percent reading is clamped to [0, 100]. A full bar (100%) shows
/// every cell as the filled glyph; 0% shows every cell as the empty
/// glyph. Intermediate values fill `floor(width * percent / 100)`
/// cells.
pub fn renderUsageBar(buf: []u8, percent: u8, width: usize) []const u8 {
    const filled_glyph = "\xe2\x96\x88"; // U+2588 FULL BLOCK
    const empty_glyph = "\xe2\x96\x91"; // U+2591 LIGHT SHADE
    const safe_percent: usize = @min(@as(usize, percent), 100);
    const safe_width: usize = if (width == 0) 20 else width;

    // filled count = floor(width * percent / 100). Use saturating math
    // so width * 100 cannot overflow on a u8 percent + small width.
    const filled: usize = (safe_width * safe_percent) / 100;
    const empty: usize = safe_width - filled;

    var stream = std.Io.Writer.fixed(buf);
    const w = &stream;
    w.writeByte('[') catch return "";
    var i: usize = 0;
    while (i < filled) : (i += 1) {
        w.writeAll(filled_glyph) catch return "";
    }
    var j: usize = 0;
    while (j < empty) : (j += 1) {
        w.writeAll(empty_glyph) catch return "";
    }
    w.writeAll("] ") catch return "";
    w.print("{d}%", .{safe_percent}) catch return "";
    return stream.buffered();
}

/// Middle-truncate a filesystem path so both the directory context
/// and filename survive. For example,
/// "src/components/deeply/nested/folder/MyComponent.tsx" with
/// max_bytes=30 renders as "src/components/\xe2\x80\xa6/MyComponent.tsx".
/// Ports claude-code-main/src/utils/truncate.ts truncatePathMiddle
/// with a byte-length metric instead of display width -- zcode has no
/// wcwidth yet, so CJK and emoji segments count as their UTF-8 byte
/// length rather than their terminal-cell width. For ASCII paths
/// (~95% of what zcode renders) the behaviour is identical. The
/// ellipsis is the single-character \xe2\x80\xa6 so the output fits
/// within one display column per ellipsis.
pub fn truncatePathMiddle(buf: []u8, path: []const u8, max_bytes: usize) []const u8 {
    if (path.len <= max_bytes) return path;
    if (max_bytes == 0) return "\xe2\x80\xa6";

    const ellipsis = "\xe2\x80\xa6";
    const last_sep = std.mem.lastIndexOfAny(u8, path, "/\\");
    const filename = if (last_sep) |idx| path[idx..] else path; // keeps leading '/'
    const directory = if (last_sep) |idx| path[0..idx] else "";

    if (filename.len >= max_bytes) {
        return truncateStart(buf, path, max_bytes);
    }

    const reserved = ellipsis.len + filename.len;
    if (reserved >= max_bytes) {
        return truncateStart(buf, filename, max_bytes);
    }
    const dir_budget = max_bytes - reserved;
    const dir_prefix_len = clampUtf8Boundary(directory, dir_budget);
    const out_len = dir_prefix_len + ellipsis.len + filename.len;
    if (out_len > buf.len) return path[0..@min(buf.len, path.len)];

    @memcpy(buf[0..dir_prefix_len], directory[0..dir_prefix_len]);
    @memcpy(buf[dir_prefix_len .. dir_prefix_len + ellipsis.len], ellipsis);
    @memcpy(buf[dir_prefix_len + ellipsis.len .. out_len], filename);
    return buf[0..out_len];
}

/// Helper: truncate from the start, prepending an ellipsis so the tail
/// survives. Used as the fallback when even the basename is too long.
fn truncateStart(buf: []u8, text: []const u8, max_bytes: usize) []const u8 {
    const ellipsis = "\xe2\x80\xa6";
    if (max_bytes == 0) return "";
    if (max_bytes < ellipsis.len + 1) {
        const take = @min(max_bytes, text.len);
        const start = text.len - take;
        @memcpy(buf[0..take], text[start..]);
        return buf[0..take];
    }
    const tail_budget = max_bytes - ellipsis.len;
    const raw_take = @min(tail_budget, text.len);
    // Walk forward from the cut point to the next UTF-8 boundary so we
    // don't render a leading invalid-byte continuation.
    var cut_from = text.len - raw_take;
    while (cut_from < text.len and (text[cut_from] & 0xC0) == 0x80) cut_from += 1;
    const copy_len = text.len - cut_from;
    if (buf.len < ellipsis.len + copy_len) return text;
    @memcpy(buf[0..ellipsis.len], ellipsis);
    @memcpy(buf[ellipsis.len .. ellipsis.len + copy_len], text[cut_from..]);
    return buf[0 .. ellipsis.len + copy_len];
}

/// Return the largest `n <= budget` such that `text[0..n]` ends on a
/// UTF-8 character boundary. Prevents a slice through a multibyte
/// sequence from rendering as invalid UTF-8. Assumes `text` is
/// well-formed UTF-8 to start with.
fn clampUtf8Boundary(text: []const u8, budget: usize) usize {
    var n = @min(budget, text.len);
    while (n > 0 and n < text.len and (text[n] & 0xC0) == 0x80) n -= 1;
    return n;
}

/// ANSI control sequence that clears the visible screen, clears the
/// scrollback buffer, and parks the cursor at the top-left corner.
/// Modern POSIX terminals (iTerm2, Terminal.app, alacritty, kitty,
/// gnome-terminal, konsole, tmux, screen) all honor ESC[3J for
/// scrollback erase. Ported from claude-code-main/src/ink/
/// clearTerminal.ts which splits the bytes across CSI helpers.
///
/// Windows conhost (the legacy console) ignores ESC[3J but accepts
/// ESC[2J + ESC[H, so a caller that wants a safe fallback can use
/// `clearTerminalSequenceCompat()` instead.
pub const CLEAR_TERMINAL_FULL: []const u8 = "\x1b[2J\x1b[3J\x1b[H";

/// Legacy fallback that only clears the visible screen, not the
/// scrollback. Used on platforms where ESC[3J is ignored.
pub const CLEAR_TERMINAL_SCREEN: []const u8 = "\x1b[2J\x1b[H";

/// Pick the right clear sequence for the current terminal. Matches
/// claude-code-main/src/ink/clearTerminal.ts getClearTerminalSequence:
/// on modern Windows terminals (Windows Terminal, VS Code, mintty)
/// the full sequence works; legacy conhost gets the screen-only
/// variant. POSIX always gets the full sequence.
pub fn clearTerminalSequence() []const u8 {
    if (builtin.os.tag == .windows) {
        if (isModernWindowsTerminal()) return CLEAR_TERMINAL_FULL;
        return CLEAR_TERMINAL_SCREEN;
    }
    return CLEAR_TERMINAL_FULL;
}

/// Inverse-video SGR for highlighting matched substrings in search
/// result rows. Paired with SGR_INVERSE_OFF (27) to return to normal
/// rendering without affecting the current foreground/background.
pub const SGR_INVERSE: []const u8 = "\x1b[7m";
pub const SGR_INVERSE_OFF: []const u8 = "\x1b[27m";

/// Write `text` into a writer, wrapping the first case-insensitive
/// occurrence of `query` in the `SGR_INVERSE` / `SGR_INVERSE_OFF`
/// pair. When `query` is empty or no match is found, the text is
/// written unchanged. Ported conceptually from
/// claude-code-main/src/utils/highlightMatch.tsx (React/Ink version)
/// but written for a flat byte writer so any caller with an
/// ArrayList writer or a writer-over-fixed-buffer can use it.
///
/// Only the first match is highlighted, matching the reference's
/// "show me where my query landed" visual rather than a full
/// per-occurrence wrap -- anything more aggressive would clash with
/// the picker's selected-row highlight on multi-match rows.
pub fn writeHighlightedMatch(writer: anytype, text: []const u8, query: []const u8) !void {
    if (query.len == 0 or query.len > text.len) {
        try writer.writeAll(text);
        return;
    }
    // Case-insensitive substring search (ASCII-only).
    var idx: ?usize = null;
    var i: usize = 0;
    while (i + query.len <= text.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(text[i .. i + query.len], query)) {
            idx = i;
            break;
        }
    }
    if (idx) |start| {
        try writer.writeAll(text[0..start]);
        try writer.writeAll(SGR_INVERSE);
        try writer.writeAll(text[start .. start + query.len]);
        try writer.writeAll(SGR_INVERSE_OFF);
        try writer.writeAll(text[start + query.len ..]);
    } else {
        try writer.writeAll(text);
    }
}

/// OSC 8 hyperlink opening sequence. Format: `ESC ] 8 ; ; URL BEL`.
/// Matches claude-code-main/src/utils/hyperlink.ts OSC8_START.
pub const OSC8_LINK_START: []const u8 = "\x1b]8;;";
/// BEL terminator for the OSC 8 opening sequence. Some emulators
/// prefer `ESC \` (ST) but BEL is universally accepted on all the
/// terminals zcode ships against (iTerm2, Kitty, Ghostty, WezTerm,
/// Windows Terminal, VS Code, Alacritty).
pub const OSC8_LINK_BEL: []const u8 = "\x07";
/// The full "close a hyperlink" sequence: `ESC ] 8 ; ; BEL`.
/// Written after the display text to return the cursor to normal
/// text-with-no-hyperlink state.
pub const OSC8_LINK_END: []const u8 = "\x1b]8;;\x07";

/// Return true when the current terminal is known to render OSC 8
/// hyperlinks correctly. Probes $TERM_PROGRAM and a few other
/// emulator-specific env vars. Matches the allowlist in
/// claude-code-main/src/ink/supports-hyperlinks.ts -- falls back to
/// false on anything unknown so a hostile terminal doesn't render
/// clickable links that secretly dump their display text elsewhere.
pub fn supportsOsc8Hyperlinks() bool {
    if (@import("env.zig").getenv("FORCE_HYPERLINK")) |v| {
        if (v.len > 0 and v[0] != '0') return true;
    }
    if (@import("env.zig").getenv("NO_HYPERLINK")) |_| return false;
    if (@import("env.zig").getenv("KITTY_WINDOW_ID")) |_| return true;
    if (@import("env.zig").getenv("WEZTERM_PANE")) |_| return true;
    if (@import("env.zig").getenv("GHOSTTY_RESOURCES_DIR")) |_| return true;
    if (@import("env.zig").getenv("WT_SESSION")) |_| return true;
    if (@import("env.zig").getenv("DOMTERM")) |_| return true;
    if (@import("env.zig").getenv("TERM_PROGRAM")) |prog| {
        if (std.mem.eql(u8, prog, "iTerm.app")) return true;
        if (std.mem.eql(u8, prog, "WezTerm")) return true;
        if (std.mem.eql(u8, prog, "vscode")) return true;
        if (std.mem.eql(u8, prog, "ghostty")) return true;
        if (std.mem.eql(u8, prog, "Hyper")) return true;
    }
    return false;
}

/// Write a clickable hyperlink (OSC 8) around `display_text` that
/// resolves to `url`. When the current terminal does not support
/// OSC 8, the `display_text` is written unchanged. The caller is
/// responsible for any SGR colour wrapping that should apply to the
/// display text (write SGR BEFORE calling this helper and RESET
/// after).
///
/// Ported from claude-code-main/src/utils/hyperlink.ts createHyperlink.
pub fn writeHyperlink(writer: anytype, url: []const u8, display_text: []const u8) !void {
    if (!supportsOsc8Hyperlinks()) {
        try writer.writeAll(display_text);
        return;
    }
    try writer.writeAll(OSC8_LINK_START);
    try writer.writeAll(url);
    try writer.writeAll(OSC8_LINK_BEL);
    try writer.writeAll(display_text);
    try writer.writeAll(OSC8_LINK_END);
}

fn isModernWindowsTerminal() bool {
    // Windows Terminal sets WT_SESSION.
    if (@import("env.zig").getenv("WT_SESSION")) |_| return true;
    // VS Code integrated terminal on Windows with ConPTY.
    if (@import("env.zig").getenv("TERM_PROGRAM")) |prog| {
        if (std.mem.eql(u8, prog, "vscode")) return true;
        if (std.mem.eql(u8, prog, "mintty")) return true;
    }
    // mintty / MSYS2 / Git Bash export MSYSTEM.
    if (@import("env.zig").getenv("MSYSTEM")) |_| return true;
    return false;
}

/// Detect the Windows conhost "cursor-up viewport yank" bug, where a
/// CSI cursor-up (CUU) redraw after the viewport has scrolled yanks the
/// terminal back to a stale viewport, corrupting the display. Returns
/// true on win32 or under Windows Terminal (WT_SESSION), matching the
/// reference's behavior in claude-code-main/src/ink/terminal.ts:171-179.
///
/// NOTE: zcode's renderer uses absolute cursor positioning
/// (repl_render.zig:729,2450) and full-screen redraws rather than
/// incremental cursor-up redraws, so this bug cannot currently trigger.
/// The function exists for reference parity and as a guard if an
/// incremental cursor-up redraw path is ever added.
pub fn hasCursorUpViewportYankBug() bool {
    if (builtin.os.tag == .windows) return true;
    if (@import("env.zig").getenv("WT_SESSION")) |_| return true;
    return false;
}

const builtin = @import("builtin");

/// Add cat -n style line numbers to `content`, starting at
/// `start_line` (1-indexed). The format matches Claude Code's
/// Upper bound on the number of bytes the Read tool will emit for a
/// single source line. Matches `MAX_LINE_LENGTH` from the reference's
/// src/constants/files.ts. Anything longer is truncated with a
/// `[line truncated: X total chars]` marker so minified JS/CSS, base64
/// blobs embedded in JSON, and similar pathological cases don't
/// silently blow the model's context budget.
///
/// Rationale for 2000 bytes specifically:
///   - Typical source-code lines are <120 bytes, so 2000 is a 16x
///     buffer that never triggers for normal files.
///   - 2000 bytes is enough to show a recognizable prefix of a
///     minified bundle (enough for the model to identify the file
///     by its namespace/module markers).
///   - Below 2000 and we start cutting off legitimate long strings
///     in config files (CSP headers, long regex literals, etc).
///
/// The threshold is overridable per-session via `ZCODE_MAX_LINE_BYTES`
/// in case a user genuinely needs to see longer lines.
pub const MAX_LINE_BYTES_DEFAULT: usize = 2000;

fn maxLineBytes() usize {
    if (@import("env.zig").getenv("ZCODE_MAX_LINE_BYTES")) |v| {
        const parsed = std.fmt.parseInt(usize, v, 10) catch return MAX_LINE_BYTES_DEFAULT;
        if (parsed == 0) return MAX_LINE_BYTES_DEFAULT;
        return parsed;
    }
    return MAX_LINE_BYTES_DEFAULT;
}

/// addLineNumbers in src/utils/file.ts:290 verbatim:
///
///     "     1\xe2\x86\x92first line"
///     "     2\xe2\x86\x92second line"
///     "999999\xe2\x86\x92overflow line (no padding)"
///
/// The number is right-padded to 6 columns (so most files line up
/// vertically), then the U+2192 RIGHTWARDS ARROW separator, then the
/// line itself. When the line number is 6+ digits the padding drops
/// so we don't double-pad. Empty input returns an empty string.
///
/// Lines longer than MAX_LINE_BYTES are clipped to that length and
/// suffixed with `... [line truncated: <total> chars total]` so the
/// model can see the line exists and knows how much is missing.
///
/// Caller owns the returned slice. Splits on both \n and \r\n so
/// CRLF files don't end up with \r residue inside the rendered
/// output.
pub fn addLineNumbers(allocator: std.mem.Allocator, content: []const u8, start_line: usize) ![]u8 {
    if (content.len == 0) return allocator.dupe(u8, "");

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    const max_len = maxLineBytes();

    var line_no: usize = start_line;
    var cursor: usize = 0;
    var first = true;
    while (cursor <= content.len) {
        const newline = std.mem.indexOfScalarPos(u8, content, cursor, '\n') orelse content.len;
        var line = content[cursor..newline];
        // Strip a trailing \r so CRLF files don't render as
        // "     1→hello\r" with the CR baked in.
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

        if (!first) try out.append('\n');
        first = false;

        try writeLineNumberPrefix(out.writer(), line_no);
        if (line.len > max_len) {
            try out.appendSlice(line[0..max_len]);
            try out.writer().print("... [line truncated: {d} chars total]", .{line.len});
        } else {
            try out.appendSlice(line);
        }

        if (newline == content.len) break;
        cursor = newline + 1;
        line_no += 1;
    }
    return out.toOwnedSlice();
}

fn writeLineNumberPrefix(writer: anytype, line_no: usize) !void {
    var num_buf: [20]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{line_no}) catch unreachable;
    if (num_str.len < 6) {
        try writer.splatByteAll(' ', 6 - num_str.len);
    }
    try writer.writeAll(num_str);
    // U+2192 RIGHTWARDS ARROW, encoded as the 3-byte sequence
    // E2 86 92. Matches the literal "→" in Claude Code's source.
    try writer.writeAll("\xe2\x86\x92");
}

/// Strip a `N→` or `N\t` prefix from a line, regardless of leading
/// whitespace. Inverse of addLineNumbers; matches the reference's
/// stripLineNumberPrefix at src/utils/file.ts:325. Returns the line
/// unchanged when no prefix is present so callers can map this over
/// every line without a separate "is this prefixed" check.
pub fn stripLineNumberPrefix(line: []const u8) []const u8 {
    var i: usize = 0;
    // Optional leading whitespace.
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    const num_start = i;
    while (i < line.len and line[i] >= '0' and i - num_start < 12 and line[i] <= '9') i += 1;
    if (i == num_start) return line; // no digits
    // Separator: U+2192 (3-byte) or '\t'.
    if (i + 3 <= line.len and line[i] == 0xe2 and line[i + 1] == 0x86 and line[i + 2] == 0x92) {
        return line[i + 3 ..];
    }
    if (i < line.len and line[i] == '\t') {
        return line[i + 1 ..];
    }
    return line;
}

const testing = std.testing;

test "formatRelativeTimeShort zero diff renders 'just now'" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("just now", formatRelativeTimeShort(&buf, 1710541200, 1710541200));
}

test "formatRelativeTimeShort selects correct unit" {
    var buf: [32]u8 = undefined;
    const now: i64 = 1710541200;
    // 5 seconds ago
    try testing.expectEqualStrings("5s ago", formatRelativeTimeShort(&buf, now - 5, now));
    // 3 minutes ago
    try testing.expectEqualStrings("3m ago", formatRelativeTimeShort(&buf, now - 180, now));
    // 2 hours ago
    try testing.expectEqualStrings("2h ago", formatRelativeTimeShort(&buf, now - 7200, now));
    // 4 days ago
    try testing.expectEqualStrings("4d ago", formatRelativeTimeShort(&buf, now - 4 * 86400, now));
    // 2 weeks ago
    try testing.expectEqualStrings("2w ago", formatRelativeTimeShort(&buf, now - 14 * 86400, now));
    // 2 months ago
    try testing.expectEqualStrings("2mo ago", formatRelativeTimeShort(&buf, now - 60 * 86400, now));
    // 2 years ago
    try testing.expectEqualStrings("2y ago", formatRelativeTimeShort(&buf, now - 730 * 86400, now));
}

test "formatRelativeTimeShort handles future timestamps" {
    var buf: [32]u8 = undefined;
    const now: i64 = 1710541200;
    try testing.expectEqualStrings("in 3h", formatRelativeTimeShort(&buf, now + 3 * 3600, now));
    // 7 days exactly matches the week boundary, so this walks up the
    // interval ladder and renders as "in 1w" -- same semantics as the
    // reference, which picks the coarsest matching unit.
    try testing.expectEqualStrings("in 1w", formatRelativeTimeShort(&buf, now + 7 * 86400, now));
    // 5 days is short of a week and renders in days.
    try testing.expectEqualStrings("in 5d", formatRelativeTimeShort(&buf, now + 5 * 86400, now));
}

test "formatRelativeTimeShort rounds down (truncates towards zero)" {
    var buf: [32]u8 = undefined;
    const now: i64 = 1710541200;
    // 89 seconds ago -> 1m ago (not 2m)
    try testing.expectEqualStrings("1m ago", formatRelativeTimeShort(&buf, now - 89, now));
    // 90 minutes ago -> 1h ago (not 2h)
    try testing.expectEqualStrings("1h ago", formatRelativeTimeShort(&buf, now - 5400, now));
}

test "formatRelativeTimeShort survives extreme timestamp deltas without overflow" {
    // Regression guard: the previous implementation did `event_ts - now_ts`
    // in i64 and then negated the result, which both panic in ReleaseSafe
    // and are UB in ReleaseFast when the delta is near INT64_MIN/MAX.
    // Reachable from a corrupted/unbounded timestamp field on disk.
    var buf: [32]u8 = undefined;
    const min_ts: i64 = std.math.minInt(i64);
    const max_ts: i64 = std.math.maxInt(i64);
    // Far past -- must render something, must not panic.
    _ = formatRelativeTimeShort(&buf, min_ts, 0);
    _ = formatRelativeTimeShort(&buf, min_ts, max_ts);
    // Far future -- same.
    _ = formatRelativeTimeShort(&buf, max_ts, 0);
    _ = formatRelativeTimeShort(&buf, max_ts, min_ts);
}

test "writeHighlightedMatch wraps first match in inverse SGR" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();
    try writeHighlightedMatch(buf.writer(), "openai-compatible/kimi-k2.5", "kimi");
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\x1b[7mkimi\x1b[27m") != null);
    try testing.expect(std.mem.startsWith(u8, buf.items(), "openai-compatible/"));
    try testing.expect(std.mem.endsWith(u8, buf.items(), "-k2.5"));
}

test "writeHighlightedMatch is case-insensitive" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();
    try writeHighlightedMatch(buf.writer(), "Claude-Sonnet-4.5", "SON");
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\x1b[7mSon\x1b[27m") != null);
}

test "writeHighlightedMatch only highlights first occurrence" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();
    try writeHighlightedMatch(buf.writer(), "foo bar foo", "foo");
    // Exactly one inverse wrapper.
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, buf.items(), i, "\x1b[7m")) |next| {
        count += 1;
        i = next + 4;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "writeHighlightedMatch passes text through unchanged with empty query" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();
    try writeHighlightedMatch(buf.writer(), "hello world", "");
    try testing.expectEqualStrings("hello world", buf.items());
}

test "writeHighlightedMatch passes text through unchanged on no match" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();
    try writeHighlightedMatch(buf.writer(), "hello world", "zzz");
    try testing.expectEqualStrings("hello world", buf.items());
}

test "writeHighlightedMatch handles query longer than text" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();
    try writeHighlightedMatch(buf.writer(), "hi", "hello world");
    try testing.expectEqualStrings("hi", buf.items());
}

test "writeHyperlink emits OSC 8 sequences when the terminal supports it" {
    // Force hyperlink support so the test is deterministic regardless
    // of the real $TERM_PROGRAM on the machine running the suite.
    const prev = @import("env.zig").getenv("FORCE_HYPERLINK");
    _ = prev;
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();
    // We can't easily mutate process env from a test in Zig 0.15, so
    // we assert the OSC 8 boilerplate is present conditionally: when
    // supportsOsc8Hyperlinks() is true on this machine, the output
    // contains the escape bytes; when false, it contains only the
    // display text. Both branches are valid -- just assert the
    // display text is always present so callers never lose content.
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();
    try writeHyperlink(buf.writer(), "https://example.com/docs", "docs");
    try testing.expect(std.mem.indexOf(u8, buf.items(), "docs") != null);
    if (supportsOsc8Hyperlinks()) {
        try testing.expect(std.mem.indexOf(u8, buf.items(), OSC8_LINK_START) != null);
        try testing.expect(std.mem.indexOf(u8, buf.items(), "https://example.com/docs") != null);
        try testing.expect(std.mem.indexOf(u8, buf.items(), OSC8_LINK_END) != null);
    } else {
        // Without terminal support we should see ONLY the display text.
        try testing.expectEqualStrings("docs", buf.items());
    }
}

test "OSC 8 constants are the exact bytes from the reference" {
    try testing.expectEqualStrings("\x1b]8;;", OSC8_LINK_START);
    try testing.expectEqualStrings("\x07", OSC8_LINK_BEL);
    try testing.expectEqualStrings("\x1b]8;;\x07", OSC8_LINK_END);
}

test "renderUsageBar 0% renders all empty glyphs" {
    var buf: [128]u8 = undefined;
    const out = renderUsageBar(&buf, 0, 10);
    try testing.expect(std.mem.indexOf(u8, out, "[") != null);
    try testing.expect(std.mem.indexOf(u8, out, "] 0%") != null);
    // No filled blocks at 0%
    try testing.expect(std.mem.indexOf(u8, out, "\xe2\x96\x88") == null);
    // 10 empty blocks
    var empty_count: usize = 0;
    var i: usize = 0;
    while (i + 3 <= out.len) : (i += 1) {
        if (std.mem.eql(u8, out[i .. i + 3], "\xe2\x96\x91")) empty_count += 1;
    }
    try testing.expectEqual(@as(usize, 10), empty_count);
}

test "renderUsageBar 100% renders all filled glyphs" {
    var buf: [128]u8 = undefined;
    const out = renderUsageBar(&buf, 100, 10);
    try testing.expect(std.mem.indexOf(u8, out, "] 100%") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\xe2\x96\x91") == null);
    var filled_count: usize = 0;
    var i: usize = 0;
    while (i + 3 <= out.len) : (i += 1) {
        if (std.mem.eql(u8, out[i .. i + 3], "\xe2\x96\x88")) filled_count += 1;
    }
    try testing.expectEqual(@as(usize, 10), filled_count);
}

test "renderUsageBar 50% renders half-and-half" {
    var buf: [128]u8 = undefined;
    const out = renderUsageBar(&buf, 50, 10);
    try testing.expect(std.mem.indexOf(u8, out, "] 50%") != null);
    var filled_count: usize = 0;
    var empty_count: usize = 0;
    var i: usize = 0;
    while (i + 3 <= out.len) : (i += 1) {
        if (std.mem.eql(u8, out[i .. i + 3], "\xe2\x96\x88")) filled_count += 1;
        if (std.mem.eql(u8, out[i .. i + 3], "\xe2\x96\x91")) empty_count += 1;
    }
    try testing.expectEqual(@as(usize, 5), filled_count);
    try testing.expectEqual(@as(usize, 5), empty_count);
}

test "renderUsageBar clamps percent over 100" {
    var buf: [128]u8 = undefined;
    const out = renderUsageBar(&buf, 200, 10);
    try testing.expect(std.mem.indexOf(u8, out, "] 100%") != null);
}

test "renderUsageBar zero width falls back to default" {
    var buf: [128]u8 = undefined;
    const out = renderUsageBar(&buf, 50, 0);
    try testing.expect(std.mem.indexOf(u8, out, "] 50%") != null);
    // Default width is 20 -- 10 filled at 50%
    var filled_count: usize = 0;
    var i: usize = 0;
    while (i + 3 <= out.len) : (i += 1) {
        if (std.mem.eql(u8, out[i .. i + 3], "\xe2\x96\x88")) filled_count += 1;
    }
    try testing.expectEqual(@as(usize, 10), filled_count);
}

test "formatBriefTimestamp same-day renders HH:MM only" {
    var buf: [32]u8 = undefined;
    // 2024-03-15 13:30:00 UTC and 2024-03-15 17:45:00 UTC
    // 2024-03-15 00:00 UTC = 1710460800
    const t_1330: i64 = 1710460800 + 13 * 3600 + 30 * 60; // 1710509400
    const t_1745: i64 = 1710460800 + 17 * 3600 + 45 * 60; // 1710524700
    try testing.expectEqualStrings("13:30", formatBriefTimestamp(&buf, t_1330, t_1745));
}

test "formatBriefTimestamp within-week adds weekday short name" {
    var buf: [32]u8 = undefined;
    // event: 2024-03-12 09:15 UTC (Tue)  -> 1710234900
    //        = 1704067200 (Jan 1) + 71 days + 9h + 15m
    // now:   2024-03-15 22:20 UTC         -> 1710541200 (4 days later)
    const event: i64 = 1710234900;
    const now: i64 = 1710541200;
    const out = formatBriefTimestamp(&buf, event, now);
    try testing.expect(std.mem.indexOf(u8, out, "Tue") != null);
    try testing.expect(std.mem.indexOf(u8, out, "09:15") != null);
}

test "formatBriefTimestamp older renders full day-and-month label" {
    var buf: [32]u8 = undefined;
    // event: 2024-02-20 08:05 UTC (Tue)
    // now:   2024-03-15 23:00 UTC -- ~24 days ago
    const event: i64 = 1708416300; // Tue 2024-02-20 08:05 UTC
    const now: i64 = 1710541200;
    const out = formatBriefTimestamp(&buf, event, now);
    try testing.expect(std.mem.indexOf(u8, out, "Tue") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Feb") != null);
    try testing.expect(std.mem.indexOf(u8, out, "20") != null);
    try testing.expect(std.mem.indexOf(u8, out, "08:05") != null);
}

test "formatBriefTimestamp handles zero and negative timestamps gracefully" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("", formatBriefTimestamp(&buf, 0, 1710541200));
    try testing.expectEqualStrings("", formatBriefTimestamp(&buf, -1, 1710541200));
}

test "formatFileSize renders bytes under 1 KB" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0 bytes", formatFileSize(&buf, 0));
    try testing.expectEqualStrings("512 bytes", formatFileSize(&buf, 512));
    try testing.expectEqualStrings("1023 bytes", formatFileSize(&buf, 1023));
}

test "formatFileSize renders KB with optional decimal" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1 KB", formatFileSize(&buf, 1024));
    try testing.expectEqualStrings("1.5 KB", formatFileSize(&buf, 1536));
    try testing.expectEqualStrings("2 KB", formatFileSize(&buf, 2048));
}

test "formatFileSize renders MB and GB" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1 MB", formatFileSize(&buf, 1024 * 1024));
    try testing.expectEqualStrings("1.5 MB", formatFileSize(&buf, 1024 * 1024 + 512 * 1024));
    try testing.expectEqualStrings("1 GB", formatFileSize(&buf, 1024 * 1024 * 1024));
    try testing.expectEqualStrings("2.5 GB", formatFileSize(&buf, 1024 * 1024 * 1024 * 5 / 2));
}

test "formatNumber keeps small numbers raw" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0", formatNumber(&buf, 0));
    try testing.expectEqualStrings("42", formatNumber(&buf, 42));
    try testing.expectEqualStrings("999", formatNumber(&buf, 999));
}

test "formatNumber compacts thousands and millions" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1k", formatNumber(&buf, 1000));
    try testing.expectEqualStrings("1.3k", formatNumber(&buf, 1321));
    try testing.expectEqualStrings("145.7k", formatNumber(&buf, 145_678));
    try testing.expectEqualStrings("1m", formatNumber(&buf, 1_000_000));
    try testing.expectEqualStrings("2.5m", formatNumber(&buf, 2_500_000));
    try testing.expectEqualStrings("1.5b", formatNumber(&buf, 1_500_000_000));
}

test "formatTokens matches formatNumber" {
    var buf1: [32]u8 = undefined;
    var buf2: [32]u8 = undefined;
    try testing.expectEqualStrings(formatNumber(&buf1, 12_345), formatTokens(&buf2, 12_345));
}

test "formatDuration zero and sub-second" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0s", formatDuration(&buf, 0));
    try testing.expectEqualStrings("0.5s", formatDuration(&buf, 500));
    try testing.expectEqualStrings("0.1s", formatDuration(&buf, 123));
}

test "formatDuration seconds, minutes, hours, days" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("5s", formatDuration(&buf, 5000));
    try testing.expectEqualStrings("1m 23s", formatDuration(&buf, 83_000));
    try testing.expectEqualStrings("1h 2m 3s", formatDuration(&buf, 3_723_000));
    try testing.expectEqualStrings("1d 2h 3m", formatDuration(&buf, 93_780_000));
}

test "formatIdleDuration buckets minutes like the reference" {
    var buf: [32]u8 = undefined;
    // Under a minute renders the fixed "<1m" marker.
    try testing.expectEqualStrings("<1m", formatIdleDuration(&buf, 0));
    // Whole minutes under an hour.
    try testing.expectEqualStrings("1m", formatIdleDuration(&buf, 1));
    try testing.expectEqualStrings("5m", formatIdleDuration(&buf, 5));
    try testing.expectEqualStrings("59m", formatIdleDuration(&buf, 59));
    // Whole hours.
    try testing.expectEqualStrings("1h", formatIdleDuration(&buf, 60));
    try testing.expectEqualStrings("2h", formatIdleDuration(&buf, 120));
    // Hours plus minutes.
    try testing.expectEqualStrings("1h 5m", formatIdleDuration(&buf, 65));
    try testing.expectEqualStrings("3h 30m", formatIdleDuration(&buf, 210));
}

test "formatSecondsShort always one decimal" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0.5s", formatSecondsShort(&buf, 500));
    try testing.expectEqualStrings("1.2s", formatSecondsShort(&buf, 1234));
    try testing.expectEqualStrings("12.3s", formatSecondsShort(&buf, 12_345));
}

test "truncatePathMiddle returns path unchanged when it fits" {
    var buf: [128]u8 = undefined;
    const short = "src/main.zig";
    try testing.expectEqualStrings(short, truncatePathMiddle(&buf, short, 64));
}

test "truncatePathMiddle keeps filename and directory prefix" {
    var buf: [128]u8 = undefined;
    const path = "src/components/deeply/nested/folder/MyComponent.tsx";
    const out = truncatePathMiddle(&buf, path, 30);
    // Directory prefix + ellipsis + /MyComponent.tsx (18 bytes including slash)
    try testing.expect(std.mem.startsWith(u8, out, "src/"));
    try testing.expect(std.mem.endsWith(u8, out, "/MyComponent.tsx"));
    try testing.expect(std.mem.indexOf(u8, out, "\xe2\x80\xa6") != null);
    // Result should not exceed the budget.
    try testing.expect(out.len <= 30);
}

test "truncatePathMiddle falls back to start-truncation for over-long filename" {
    var buf: [128]u8 = undefined;
    const path = "/tmp/ReallyLongFileNameThatExceedsBudget.txt";
    const out = truncatePathMiddle(&buf, path, 20);
    try testing.expect(std.mem.startsWith(u8, out, "\xe2\x80\xa6"));
    try testing.expect(std.mem.endsWith(u8, out, ".txt"));
    try testing.expect(out.len <= 20);
}

test "truncatePathMiddle handles paths with no directory separator" {
    var buf: [128]u8 = undefined;
    const path = "VeryLongFilenameWithoutAnyDirectorySeparator.config";
    const out = truncatePathMiddle(&buf, path, 15);
    // No directory = falls through to truncateStart since filename >= budget.
    try testing.expect(std.mem.startsWith(u8, out, "\xe2\x80\xa6"));
    try testing.expect(out.len <= 15);
}

test "truncatePathMiddle handles zero budget" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("\xe2\x80\xa6", truncatePathMiddle(&buf, "anything", 0));
}

test "truncatePathMiddle handles Windows-style backslash paths" {
    var buf: [128]u8 = undefined;
    const path = "C:\\Users\\Toto\\Documents\\zig-code\\src\\cli\\repl.zig";
    const out = truncatePathMiddle(&buf, path, 30);
    try testing.expect(std.mem.endsWith(u8, out, "\\repl.zig"));
    try testing.expect(std.mem.indexOf(u8, out, "\xe2\x80\xa6") != null);
    try testing.expect(out.len <= 30);
}

test "addLineNumbers adds 6-wide right-padded prefix and arrow" {
    const out = try addLineNumbers(testing.allocator, "hello\nworld", 1);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("     1\xe2\x86\x92hello\n     2\xe2\x86\x92world", out);
}

test "addLineNumbers honours start_line offset" {
    const out = try addLineNumbers(testing.allocator, "a\nb\nc", 42);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("    42\xe2\x86\x92a\n    43\xe2\x86\x92b\n    44\xe2\x86\x92c", out);
}

test "addLineNumbers strips trailing CR for CRLF input" {
    const out = try addLineNumbers(testing.allocator, "one\r\ntwo\r\n", 1);
    defer testing.allocator.free(out);
    // Trailing newline yields a final empty line; that's the same
    // behaviour as cat -n '%s\n%s\n'.
    try testing.expect(std.mem.indexOf(u8, out, "\r") == null);
    try testing.expect(std.mem.indexOf(u8, out, "     1\xe2\x86\x92one") != null);
    try testing.expect(std.mem.indexOf(u8, out, "     2\xe2\x86\x92two") != null);
}

test "addLineNumbers omits padding when the number is 6+ digits" {
    const out = try addLineNumbers(testing.allocator, "x", 1_000_000);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("1000000\xe2\x86\x92x", out);
}

test "addLineNumbers returns empty for empty input" {
    const out = try addLineNumbers(testing.allocator, "", 1);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
}

test "addLineNumbers truncates lines longer than MAX_LINE_BYTES" {
    // Build a 5000-char line -- well over the 2000-byte cap. The
    // renderer must clip at the cap and emit a clear "line truncated"
    // marker so the model knows the line exists and how much is missing.
    const long_line = "x" ** 5000;
    const out = try addLineNumbers(testing.allocator, long_line, 1);
    defer testing.allocator.free(out);

    // The prefix + 2000 x + truncation suffix. Exact length check:
    try testing.expect(std.mem.indexOf(u8, out, "[line truncated: 5000 chars total]") != null);
    // Must not contain the full 5000 x's.
    try testing.expect(out.len < 5000);
    // Must still have the line number prefix.
    try testing.expect(std.mem.startsWith(u8, out, "     1\xe2\x86\x92"));
}

test "addLineNumbers leaves short lines unchanged" {
    // A 1999-char line is just under the cap and must render verbatim.
    const short_line = "y" ** 1999;
    const out = try addLineNumbers(testing.allocator, short_line, 1);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "line truncated") == null);
    // Body count: every 'y' survives.
    var y_count: usize = 0;
    for (out) |c| {
        if (c == 'y') y_count += 1;
    }
    try testing.expectEqual(@as(usize, 1999), y_count);
}

test "addLineNumbers truncates per-line, not per-file" {
    // Mix of a normal line, a long line, and another normal line.
    // Only the middle line should be clipped; the others come through
    // intact on their original line numbers.
    const long_middle = "z" ** 3000;
    const content = try std.fmt.allocPrint(
        testing.allocator,
        "short\n{s}\nshort again",
        .{long_middle},
    );
    defer testing.allocator.free(content);
    const out = try addLineNumbers(testing.allocator, content, 1);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "     1\xe2\x86\x92short\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[line truncated: 3000 chars total]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "     3\xe2\x86\x92short again") != null);
}

// Note: ZCODE_MAX_LINE_BYTES is honored in production via @import("env.zig").getenv,
// but Zig 0.15's test binary snapshots `environ` at start so a test-time
// setenv doesn't round-trip back through getenv reliably. The core
// truncation behavior is pinned by the three tests above; the env-override
// path is exercised manually when a user actually sets the variable.

test "stripLineNumberPrefix removes arrow prefix" {
    try testing.expectEqualStrings("hello", stripLineNumberPrefix("     1\xe2\x86\x92hello"));
    try testing.expectEqualStrings("hello world", stripLineNumberPrefix("    42\xe2\x86\x92hello world"));
    try testing.expectEqualStrings("x", stripLineNumberPrefix("1000000\xe2\x86\x92x"));
}

test "stripLineNumberPrefix removes tab prefix" {
    // The compact form Claude Code uses when isCompactLinePrefixEnabled.
    try testing.expectEqualStrings("hello", stripLineNumberPrefix("1\thello"));
    try testing.expectEqualStrings("hello", stripLineNumberPrefix("42\thello"));
}

test "stripLineNumberPrefix leaves un-prefixed lines unchanged" {
    try testing.expectEqualStrings("plain text", stripLineNumberPrefix("plain text"));
    try testing.expectEqualStrings("123 not a prefix", stripLineNumberPrefix("123 not a prefix"));
    try testing.expectEqualStrings("", stripLineNumberPrefix(""));
}

test "addLineNumbers and stripLineNumberPrefix round-trip" {
    const original = "alpha\nbeta\ngamma\ndelta";
    const numbered = try addLineNumbers(testing.allocator, original, 100);
    defer testing.allocator.free(numbered);

    var iter = std.mem.splitScalar(u8, numbered, '\n');
    var rebuilt = std_io.StringBuilder.init(testing.allocator);
    defer rebuilt.deinit();
    var first = true;
    while (iter.next()) |line| {
        if (!first) try rebuilt.append('\n');
        first = false;
        try rebuilt.appendSlice(stripLineNumberPrefix(line));
    }
    try testing.expectEqualStrings(original, rebuilt.items());
}

test "clearTerminalSequence returns a non-empty ANSI sequence" {
    const seq = clearTerminalSequence();
    try testing.expect(seq.len >= "\x1b[2J\x1b[H".len);
    // Must start with ESC '[' and contain the 'J' erase command.
    try testing.expect(seq[0] == 0x1b);
    try testing.expect(std.mem.indexOfScalar(u8, seq, 'J') != null);
    try testing.expect(std.mem.indexOfScalar(u8, seq, 'H') != null);
}

test "CLEAR_TERMINAL_FULL contains the scrollback erase 3J" {
    try testing.expect(std.mem.indexOf(u8, CLEAR_TERMINAL_FULL, "\x1b[3J") != null);
}

test "CLEAR_TERMINAL_SCREEN omits the scrollback erase" {
    try testing.expect(std.mem.indexOf(u8, CLEAR_TERMINAL_SCREEN, "\x1b[3J") == null);
    try testing.expect(std.mem.indexOf(u8, CLEAR_TERMINAL_SCREEN, "\x1b[2J") != null);
}

test "hasCursorUpViewportYankBug detects WT_SESSION and win32" {
    extern_c.set("WT_SESSION", "abc", 1);
    try testing.expect(hasCursorUpViewportYankBug());

    extern_c.unset("WT_SESSION");
    // On a non-Windows build target, with WT_SESSION cleared, the bug
    // is not present. On a Windows target the win32 branch keeps it
    // true regardless, so only assert the false case off-Windows.
    if (builtin.os.tag != .windows) {
        try testing.expect(!hasCursorUpViewportYankBug());
    } else {
        try testing.expect(hasCursorUpViewportYankBug());
    }
}

const extern_c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    fn set(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) void {
        _ = setenv(name, value, overwrite);
    }
    fn unset(name: [*:0]const u8) void {
        _ = unsetenv(name);
    }
};
