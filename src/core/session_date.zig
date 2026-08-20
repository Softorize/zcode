const std = @import("std");
const rt = @import("zcode_runtime");
const clock = @import("clock.zig");
const builtin = @import("builtin");

/// POSIX `struct tm` laid out verbatim so we can bind `localtime_r` from
/// libc without pulling a platform-specific header. Field order matches
/// glibc, musl, and macOS libSystem. The `tm_gmtoff`/`tm_zone` trailer is
/// a BSD/GNU extension but is present on the platforms zcode targets.
const c_tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};

extern "c" fn localtime_r(timep: *const std.c.time_t, result: *c_tm) ?*c_tm;

/// Cached YYYY-MM-DD for the current session. Captured on first call so
/// that repeated system-prompt builds during the same session emit a
/// stable date string -- otherwise we'd bust the upstream prompt cache
/// at every midnight rollover even when the conversation hasn't changed.
/// Ten ASCII bytes is enough for "YYYY-MM-DD".
var cached_date: [10]u8 = undefined;
var cached_date_initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var cache_mutex: std.Io.Mutex = .init;

/// Returns today's local date as `YYYY-MM-DD`, memoized for the lifetime
/// of the process. First call wins; subsequent calls return the same
/// bytes. Honours the `ZCODE_OVERRIDE_DATE` environment variable so tests
/// and reproducibility runs can pin the date without touching the system
/// clock. Falls back to UTC when libc `localtime_r` reports failure.
pub fn getSessionStartDate() []const u8 {
    if (cached_date_initialized.load(.acquire)) {
        return cached_date[0..10];
    }

    cache_mutex.lock(rt.io) catch {};
    defer cache_mutex.unlock(rt.io);

    if (cached_date_initialized.load(.acquire)) {
        return cached_date[0..10];
    }

    computeLocalDate(&cached_date);
    cached_date_initialized.store(true, .release);
    return cached_date[0..10];
}

/// Drop the memoized value so a subsequent `getSessionStartDate` call
/// re-reads the environment and clock. Unit tests rely on this to set
/// the override env var after the first call captured the real date.
pub fn resetCacheForTesting() void {
    cache_mutex.lock(rt.io) catch {};
    defer cache_mutex.unlock(rt.io);
    cached_date_initialized.store(false, .release);
}

fn computeLocalDate(buf: *[10]u8) void {
    if (@import("env.zig").getenv("ZCODE_OVERRIDE_DATE")) |override| {
        if (isValidIsoDate(override)) {
            @memcpy(buf[0..10], override[0..10]);
            return;
        }
    }
    if (@import("env.zig").getenv("CLAUDE_CODE_OVERRIDE_DATE")) |override| {
        if (isValidIsoDate(override)) {
            @memcpy(buf[0..10], override[0..10]);
            return;
        }
    }

    const now_secs: std.c.time_t = @intCast(clock.nowSeconds());

    if (builtin.os.tag != .windows) {
        var tm_time: c_tm = undefined;
        if (localtime_r(&now_secs, &tm_time) != null) {
            formatDate(buf, @intCast(tm_time.tm_year + 1900), @intCast(tm_time.tm_mon + 1), @intCast(tm_time.tm_mday));
            return;
        }
    }

    // Fallback: UTC via std.time.epoch. This is timezone-naive so it can
    // disagree with the wall clock by up to a day near the boundaries,
    // but it keeps the feature functional if libc is unavailable.
    const secs_u64: u64 = @intCast(@max(now_secs, 0));
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = secs_u64 };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    formatDate(
        buf,
        @intCast(year_day.year),
        @intCast(month_day.month.numeric()),
        @intCast(month_day.day_index + 1),
    );
}

fn formatDate(buf: *[10]u8, year: u32, month: u32, day: u32) void {
    _ = std.fmt.bufPrint(buf[0..10], "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, day }) catch {
        @memcpy(buf[0..10], "0000-00-00");
    };
}

/// Cheap syntactic check for a `YYYY-MM-DD` string. We don't validate
/// day-in-month semantics -- libc will ingest whatever string renders
/// back cleanly and we only use this to guard env overrides.
fn isValidIsoDate(s: []const u8) bool {
    if (s.len != 10) return false;
    if (s[4] != '-' or s[7] != '-') return false;
    for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9 }) |i| {
        if (s[i] < '0' or s[i] > '9') return false;
    }
    return true;
}

const testing = std.testing;

test "isValidIsoDate accepts well-formed dates" {
    try testing.expect(isValidIsoDate("2026-04-13"));
    try testing.expect(isValidIsoDate("1999-12-31"));
    try testing.expect(isValidIsoDate("2000-01-01"));
}

test "isValidIsoDate rejects malformed strings" {
    try testing.expect(!isValidIsoDate(""));
    try testing.expect(!isValidIsoDate("2026-4-13"));
    try testing.expect(!isValidIsoDate("2026/04/13"));
    try testing.expect(!isValidIsoDate("2026-04-1"));
    try testing.expect(!isValidIsoDate("abcd-ef-gh"));
    try testing.expect(!isValidIsoDate("2026-04-13T00:00:00Z"));
}

test "formatDate zero-pads month and day" {
    var buf: [10]u8 = undefined;
    formatDate(&buf, 2026, 4, 5);
    try testing.expectEqualStrings("2026-04-05", &buf);
    formatDate(&buf, 2026, 12, 31);
    try testing.expectEqualStrings("2026-12-31", &buf);
}

test "computeLocalDate produces a well-formed date" {
    var buf: [10]u8 = undefined;
    computeLocalDate(&buf);
    try testing.expect(isValidIsoDate(&buf));
    // Year should be somewhere within the plausible range -- guards
    // against a totally broken libc call that might return junk.
    const year = std.fmt.parseInt(u16, buf[0..4], 10) catch 0;
    try testing.expect(year >= 2000);
    try testing.expect(year <= 2100);
}

test "getSessionStartDate is stable across calls" {
    const first = getSessionStartDate();
    // Copy out; resetCacheForTesting below would otherwise be observable
    // as stale bytes via the returned slice.
    var first_copy: [10]u8 = undefined;
    @memcpy(&first_copy, first);

    const second = getSessionStartDate();
    try testing.expectEqualStrings(&first_copy, second);
}
