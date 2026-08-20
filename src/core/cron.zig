const std = @import("std");
const std_io = @import("std_io.zig");
const rt = @import("zcode_runtime");
const rng = @import("rng.zig");
const clock = @import("clock.zig");
const paths = @import("paths.zig");
const json = std.json;

/// A scheduled task that fires at a cron-like interval.
pub const CronEntry = struct {
    id: []u8,
    /// Cron expression: "*/5 * * * *" = every 5 minutes.
    schedule: []u8,
    /// The prompt to enqueue at each fire time.
    prompt: []u8,
    /// True = fire repeatedly until deleted or expired. False = one-shot.
    recurring: bool,
    /// When the entry was created (unix timestamp).
    created_ts: i64,
    /// When the entry last fired (0 = never).
    last_run_ts: i64,
    /// When the entry should next fire (computed from schedule).
    next_run_ts: i64,
    /// True = persisted to disk. False = session-only.
    durable: bool,
    /// Project the task belongs to (absolute cwd). Empty = any project / global.
    cwd: []u8,

    pub fn deinit(self: *CronEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.schedule);
        allocator.free(self.prompt);
        allocator.free(self.cwd);
    }
};

/// In-memory cron store for session-only scheduled tasks.
pub const CronStore = struct {
    allocator: std.mem.Allocator,
    entries: std.array_list.Managed(CronEntry),

    pub fn init(allocator: std.mem.Allocator) CronStore {
        return .{
            .allocator = allocator,
            .entries = std.array_list.Managed(CronEntry).init(allocator),
        };
    }

    pub fn deinit(self: *CronStore) void {
        for (self.entries.items) |*e| e.deinit(self.allocator);
        self.entries.deinit();
    }

    pub fn add(self: *CronStore, schedule: []const u8, prompt: []const u8, recurring: bool) ![]const u8 {
        return self.addWithCwd(schedule, prompt, recurring, "");
    }

    pub fn addWithCwd(self: *CronStore, schedule: []const u8, prompt: []const u8, recurring: bool, cwd: []const u8) ![]const u8 {
        const now = clock.nowSeconds();
        var rand_buf: [8]u8 = undefined;
        rng.bytes(&rand_buf);
        var id_buf: [16]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{x}{x}{x}{x}{x}{x}{x}{x}", .{
            rand_buf[0], rand_buf[1], rand_buf[2], rand_buf[3],
            rand_buf[4], rand_buf[5], rand_buf[6], rand_buf[7],
        }) catch "00000000";

        try self.entries.ensureUnusedCapacity(1);
        const id = try self.allocator.dupe(u8, id_str);
        errdefer self.allocator.free(id);
        const sched = try self.allocator.dupe(u8, schedule);
        errdefer self.allocator.free(sched);
        const prm = try self.allocator.dupe(u8, prompt);
        errdefer self.allocator.free(prm);
        const cwd_dup = try self.allocator.dupe(u8, cwd);

        const next = computeNextFireTime(schedule, now);

        self.entries.appendAssumeCapacity(.{
            .id = id,
            .schedule = sched,
            .prompt = prm,
            .recurring = recurring,
            .created_ts = now,
            .last_run_ts = 0,
            .next_run_ts = next,
            .durable = false,
            .cwd = cwd_dup,
        });

        return self.entries.items[self.entries.items.len - 1].id;
    }

    pub fn remove(self: *CronStore, id: []const u8) bool {
        for (self.entries.items, 0..) |*entry, i| {
            if (std.mem.eql(u8, entry.id, id)) {
                entry.deinit(self.allocator);
                _ = self.entries.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn list(self: *const CronStore) []const CronEntry {
        return self.entries.items;
    }

    /// Check if any entries are due to fire. Returns the prompt of the
    /// first due entry and updates its last_run_ts / next_run_ts.
    /// For recurring entries, returns a borrowed slice (valid until
    /// next mutation). For one-shot entries, returns an owned dupe
    /// that the caller must free. One-shot entries are removed after
    /// firing. Returns null when no entries are due.
    pub fn pollDue(self: *CronStore) ?[]const u8 {
        const now = clock.nowSeconds();
        for (self.entries.items, 0..) |*entry, i| {
            if (entry.next_run_ts <= now) {
                entry.last_run_ts = now;

                if (!entry.recurring) {
                    // One-shot: dupe the prompt BEFORE freeing the entry
                    // so we return valid memory. Caller owns the dupe.
                    const prompt_dupe = self.allocator.dupe(u8, entry.prompt) catch return null;
                    entry.deinit(self.allocator);
                    _ = self.entries.orderedRemove(i);
                    return prompt_dupe;
                }

                // Recurring: compute next fire time
                entry.next_run_ts = computeNextFireTime(entry.schedule, now);

                // Auto-expire after 7 days
                const seven_days: i64 = 7 * 24 * 60 * 60;
                if (now - entry.created_ts > seven_days) {
                    entry.deinit(self.allocator);
                    _ = self.entries.orderedRemove(i);
                    return null;
                }

                return entry.prompt;
            }
        }
        return null;
    }

    /// Like pollDue, but only fires entries that belong to the given
    /// project (cwd). Global entries (cwd.len == 0) fire for everyone;
    /// tagged entries fire only when their cwd matches. Returns the
    /// prompt of the first due+matching entry and updates its
    /// last_run_ts / next_run_ts. One-shot entries are removed after
    /// firing and returned as an owned dupe the caller must free.
    /// Returns null when nothing is due for this project.
    pub fn pollDueForCwd(self: *CronStore, cwd: []const u8) ?[]const u8 {
        const now = clock.nowSeconds();
        for (self.entries.items, 0..) |*entry, i| {
            if (entry.cwd.len != 0 and !std.mem.eql(u8, entry.cwd, cwd)) continue;
            if (entry.next_run_ts <= now) {
                entry.last_run_ts = now;

                if (!entry.recurring) {
                    // One-shot: dupe the prompt BEFORE freeing the entry
                    // so we return valid memory. Caller owns the dupe.
                    const prompt_dupe = self.allocator.dupe(u8, entry.prompt) catch return null;
                    entry.deinit(self.allocator);
                    _ = self.entries.orderedRemove(i);
                    return prompt_dupe;
                }

                // Recurring: compute next fire time
                entry.next_run_ts = computeNextFireTime(entry.schedule, now);

                // Auto-expire after 7 days
                const seven_days: i64 = 7 * 24 * 60 * 60;
                if (now - entry.created_ts > seven_days) {
                    entry.deinit(self.allocator);
                    _ = self.entries.orderedRemove(i);
                    return null;
                }

                return entry.prompt;
            }
        }
        return null;
    }

    /// Save all durable entries to ~/.zcode/scheduled_tasks.json.
    pub fn saveDurable(self: *const CronStore) void {
        var resolved = paths.resolve(self.allocator) catch return;
        defer resolved.deinit(self.allocator);
        const dir = std.fs.path.dirname(resolved.user_config_path) orelse return;
        const save_path = std.fs.path.join(self.allocator, &.{ dir, "scheduled_tasks.json" }) catch return;
        defer self.allocator.free(save_path);

        var buf = std_io.StringBuilder.init(self.allocator);
        defer buf.deinit();
        const w = buf.writer();
        w.writeAll("[") catch return;
        var count: usize = 0;
        for (self.entries.items) |entry| {
            if (!entry.durable) continue;
            if (count > 0) w.writeAll(",") catch {};
            w.print("{{\"id\":\"{s}\",\"schedule\":\"{s}\",\"prompt\":", .{ entry.id, entry.schedule }) catch continue;
            w.print("{f}", .{json.fmt(entry.prompt, .{})}) catch continue;
            w.print(",\"recurring\":{},\"created_ts\":{d},\"cwd\":", .{ entry.recurring, entry.created_ts }) catch continue;
            w.print("{f}", .{json.fmt(entry.cwd, .{})}) catch continue;
            w.print("}}", .{}) catch continue;
            count += 1;
        }
        w.writeAll("]") catch return;

        paths.ensureDir(dir) catch return;
        // Atomic write: a SIGINT in the truncate->writeAll window
        // would leave scheduled_tasks.json at 0 bytes or with a
        // partial JSON document; loadDurable's parse-or-return-early
        // would then drop EVERY persisted cron schedule on next
        // start. Same discipline as the rest of the atomic-write
        // sweep (passes 64-90).
        writeCronFileAtomic(self.allocator, save_path, buf.items()) catch return;
    }

    /// Load durable entries from ~/.zcode/scheduled_tasks.json.
    pub fn loadDurable(self: *CronStore) void {
        var resolved = paths.resolve(self.allocator) catch return;
        defer resolved.deinit(self.allocator);
        const dir = std.fs.path.dirname(resolved.user_config_path) orelse return;
        const load_path = std.fs.path.join(self.allocator, &.{ dir, "scheduled_tasks.json" }) catch return;
        defer self.allocator.free(load_path);

        const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, load_path, self.allocator, .limited(256 * 1024)) catch return;
        defer self.allocator.free(bytes);

        var parsed = json.parseFromSlice(json.Value, self.allocator, bytes, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .array) return;

        const now = clock.nowSeconds();
        for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const id_val = item.object.get("id") orelse continue;
            const sched_val = item.object.get("schedule") orelse continue;
            const prompt_val = item.object.get("prompt") orelse continue;
            if (id_val != .string or sched_val != .string or prompt_val != .string) continue;

            const recurring = if (item.object.get("recurring")) |r| r == .bool and r.bool else true;
            const created_ts = if (item.object.get("created_ts")) |t| switch (t) {
                .integer => |i| @as(i64, i),
                else => now,
            } else now;
            const cwd_str = if (item.object.get("cwd")) |c| switch (c) {
                .string => |s| s,
                else => "",
            } else "";

            // Bound created_ts before the `now - created_ts` subtraction
            // below. A hand-edited or malformed scheduled_tasks.json
            // could carry created_ts = i64 min (or i64 max set in the
            // future), and the subsequent `now - created_ts` would
            // overflow i64 in ReleaseFast (UB, observed wrap-around)
            // or panic in safe builds. We treat anything outside a
            // generous +/- 100-year window around `now` as garbage
            // and fall through to "use current time" so the entry is
            // loaded and not silently dropped on a one-byte typo.
            const ONE_HUNDRED_YEARS: i64 = 100 * 365 * 24 * 60 * 60;
            const safe_created_ts = if (created_ts < now -| ONE_HUNDRED_YEARS or
                created_ts > now +| ONE_HUNDRED_YEARS) now else created_ts;

            // Skip expired entries (>7 days old). Saturating subtract
            // so even if the bounds check above wasn't tight enough
            // for a future datatype change, we still cannot overflow.
            if (now -| safe_created_ts > 7 * 24 * 60 * 60) continue;

            self.entries.ensureUnusedCapacity(1) catch continue;
            const id = self.allocator.dupe(u8, id_val.string) catch continue;
            const sched = self.allocator.dupe(u8, sched_val.string) catch {
                self.allocator.free(id);
                continue;
            };
            const prm = self.allocator.dupe(u8, prompt_val.string) catch {
                self.allocator.free(id);
                self.allocator.free(sched);
                continue;
            };
            const cwd_dup = self.allocator.dupe(u8, cwd_str) catch {
                self.allocator.free(id);
                self.allocator.free(sched);
                self.allocator.free(prm);
                continue;
            };

            self.entries.appendAssumeCapacity(.{
                .id = id,
                .schedule = sched,
                .prompt = prm,
                .recurring = recurring,
                .created_ts = created_ts,
                .last_run_ts = 0,
                .next_run_ts = computeNextFireTime(sched_val.string, now),
                .durable = true,
                .cwd = cwd_dup,
            });
        }
    }
};

fn writeCronFileAtomic(allocator: std.mem.Allocator, target: []const u8, bytes: []const u8) !void {
    var nonce: [8]u8 = undefined;
    rng.bytes(&nonce);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{x}{x}{x}{x}{x}{x}{x}{x}", .{
        target, nonce[0], nonce[1], nonce[2], nonce[3], nonce[4], nonce[5], nonce[6], nonce[7],
    });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, bytes);
        file.sync(rt.io) catch {};
    }
    try std.Io.Dir.renameAbsolute(tmp_path, target, rt.io);
}

/// Parse a simple cron expression and compute the next fire time after `now`.
/// Supports: */N for minutes (e.g. "*/5 * * * *" = every 5 minutes).
/// Returns a unix timestamp.
pub fn computeNextFireTime(schedule: []const u8, now: i64) i64 {
    // Parse the minute field for */N patterns
    var it = std.mem.tokenizeAny(u8, schedule, " \t");
    const minute_field = it.next() orelse return now + 60;

    // Bound every parsed cron interval to a year. Without this cap
    // a malformed schedule like `*/9223372036854775807 * * * *`
    // (operator-edited scheduled_tasks.json, or a /schedule call
    // the user was tricked into) parses to i64 max; the subsequent
    // `interval * 60` then overflows i64 in ReleaseFast (undefined
    // behavior, observed wrap-around to small/negative values),
    // which makes computeNextFireTime return a time in the past and
    // pegs the cron loop firing continuously. A minute-interval of
    // a year is past anything legitimate and easily stays inside
    // i64 when multiplied by 60 / 3600.
    const MAX_INTERVAL_MIN: i64 = 365 * 24 * 60;
    const MAX_INTERVAL_HOUR: i64 = 365 * 24;

    if (std.mem.startsWith(u8, minute_field, "*/")) {
        const raw = std.fmt.parseInt(i64, minute_field[2..], 10) catch 5;
        const interval = std.math.clamp(raw, 1, MAX_INTERVAL_MIN);
        const interval_secs = interval * 60;
        // Round up to next interval boundary
        return now + interval_secs - @mod(now, interval_secs);
    }

    // Fixed minute: "30 * * * *" means at :30 every hour
    if (std.fmt.parseInt(i64, minute_field, 10)) |minute| {
        const hour_field = it.next() orelse return now + 3600;

        if (std.mem.eql(u8, hour_field, "*")) {
            // Every hour at :minute
            const current_minute = @mod(@divTrunc(now, 60), 60);
            if (current_minute < minute) {
                return now + (minute - current_minute) * 60;
            }
            return now + (60 - current_minute + minute) * 60;
        }

        if (std.mem.startsWith(u8, hour_field, "*/")) {
            const raw_hour = std.fmt.parseInt(i64, hour_field[2..], 10) catch 1;
            const hour_interval = std.math.clamp(raw_hour, 1, MAX_INTERVAL_HOUR);
            return now + hour_interval * 3600;
        }

        // Specific hour
        if (std.fmt.parseInt(i64, hour_field, 10)) |_| {
            // Daily at specific time -- approximate as 24h from now
            return now + 24 * 3600;
        } else |_| {}
    } else |_| {}

    // Fallback: 5 minutes
    return now + 300;
}

/// Format a cron schedule as a human-readable string.
pub fn describeSchedule(schedule: []const u8, buf: []u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, schedule, " \t");
    const minute_field = it.next() orelse return "unknown";

    if (std.mem.startsWith(u8, minute_field, "*/")) {
        const interval = std.fmt.parseInt(u32, minute_field[2..], 10) catch 0;
        if (interval == 1) return "Every minute";
        if (interval < 60) {
            return std.fmt.bufPrint(buf, "Every {d} minutes", .{interval}) catch "every N minutes";
        }
        const hours = interval / 60;
        if (hours == 1) return "Every hour";
        return std.fmt.bufPrint(buf, "Every {d} hours", .{hours}) catch "every N hours";
    }

    return std.fmt.bufPrint(buf, "Cron: {s}", .{schedule}) catch "custom schedule";
}

// --- Tests ---

const testing = std.testing;

test "computeNextFireTime every 5 minutes" {
    const now: i64 = 1710541200; // some fixed time
    const next = computeNextFireTime("*/5 * * * *", now);
    try testing.expect(next > now);
    try testing.expect(next <= now + 300);
}

test "computeNextFireTime every 30 minutes" {
    const now: i64 = 1710541200;
    const next = computeNextFireTime("*/30 * * * *", now);
    try testing.expect(next > now);
    try testing.expect(next <= now + 1800);
}

test "computeNextFireTime clamps pathological intervals" {
    // i64-max minute interval used to overflow the `* 60`
    // multiplication in ReleaseFast and produce a fire-time in the
    // past, pegging the cron loop. The clamp now caps at one year so
    // the result is bounded and strictly after `now`.
    const now: i64 = 1710541200;
    const max = "*/9223372036854775807 * * * *";
    const next = computeNextFireTime(max, now);
    try testing.expect(next > now);
    try testing.expect(next - now <= 365 * 24 * 60 * 60);

    // Same test for hour-position pathological interval.
    const max_hour = "0 */9223372036854775807 * * *";
    const next_hour = computeNextFireTime(max_hour, now);
    try testing.expect(next_hour > now);
    try testing.expect(next_hour - now <= 365 * 24 * 3600);
}

test "CronStore add and list" {
    var store = CronStore.init(testing.allocator);
    defer store.deinit();

    const id = try store.add("*/5 * * * *", "check status", true);
    try testing.expect(id.len > 0);
    try testing.expectEqual(@as(usize, 1), store.list().len);
}

test "CronStore remove" {
    var store = CronStore.init(testing.allocator);
    defer store.deinit();

    const id = try store.add("*/5 * * * *", "test", true);
    const id_copy = try testing.allocator.dupe(u8, id);
    defer testing.allocator.free(id_copy);

    try testing.expect(store.remove(id_copy));
    try testing.expectEqual(@as(usize, 0), store.list().len);
}

test "addWithCwd tags entry" {
    var store = CronStore.init(testing.allocator);
    defer store.deinit();

    const id = try store.addWithCwd("*/1 * * * *", "build repoA", true, "/tmp/repoA");
    try testing.expect(id.len > 0);
    try testing.expectEqual(@as(usize, 1), store.list().len);
    try testing.expectEqualStrings("/tmp/repoA", store.list()[0].cwd);
}

test "pollDueForCwd filters by project" {
    var store = CronStore.init(testing.allocator);
    defer store.deinit();

    // One global task (any project) and one tagged to /tmp/repoA.
    _ = try store.addWithCwd("*/1 * * * *", "global task", true, "");
    _ = try store.addWithCwd("*/1 * * * *", "repoA task", true, "/tmp/repoA");

    // Force both immediately due regardless of wall-clock.
    for (store.entries.items) |*e| e.next_run_ts = 0;

    // Polling from repoB must NOT fire repoA's task, only the global one.
    const due = store.pollDueForCwd("/tmp/repoB");
    try testing.expect(due != null);
    try testing.expectEqualStrings("global task", due.?);
}

test "describeSchedule formats common patterns" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Every 5 minutes", describeSchedule("*/5 * * * *", &buf));
    try testing.expectEqualStrings("Every 30 minutes", describeSchedule("*/30 * * * *", &buf));
    try testing.expectEqualStrings("Every hour", describeSchedule("*/60 * * * *", &buf));
}
