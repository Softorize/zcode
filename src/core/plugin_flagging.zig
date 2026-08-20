//! Flagged-plugin tracking for delisting detection (plugins-09).
//!
//! When a marketplace source opts into `force_remove_deleted` and a plugin it
//! shipped is later marked deleted in the refreshed catalog, `marketplace.zig`
//! auto-uninstalls that plugin and records it here. The flagged store is a
//! durable note of what was removed-on-our-behalf, so a later session can tell
//! the user "we removed X because its marketplace delisted it" rather than the
//! plugin silently vanishing.
//!
//! On-disk format mirrors the reference (`utils/plugins/pluginFlagging.ts`):
//!   <zcode_home>/plugins/flagged.json
//! shaped `{"plugins": {"<id>": {"flaggedAt": "<iso8601>"}}}`. The id is the
//! plugin's `name@marketplace` identity (locally-installed plugins use the
//! `@local` sentinel, matching `plugin_settings.pluginId`).
//!
//! Writes are atomic (tmp + rename, 0o600) so a crash mid-write cannot leave a
//! half-written or empty store. A missing/malformed file degrades to "nothing
//! flagged" rather than throwing, so a corrupt store never breaks refresh.

const std = @import("std");
const rt = @import("zcode_runtime");
const paths = @import("paths.zig");
const clock = @import("clock.zig");
const std_io = @import("std_io.zig");
const parse_helpers = @import("parse_helpers.zig");

const flagged_file_name = "flagged.json";
const plugins_key = "plugins";
const flagged_at_key = "flaggedAt";

/// Cap for the flagged store on disk. A real flagged map is a handful of short
/// ids; 1 MiB is far larger than legitimate and guards a hand-edited monster
/// file. readFileAlloc(.limited) yields error.StreamTooLong when exceeded (0.16
/// footgun: NOT error.FileTooBig), which we treat as "nothing flagged".
const max_flagged_bytes: usize = 1 * 1024 * 1024;

/// Resolve `<zcode_home>/plugins/flagged.json`. Caller owns the returned slice.
fn flaggedPath(allocator: std.mem.Allocator) ![]u8 {
    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);
    return std.fs.path.join(allocator, &.{ resolved.zcode_home, "plugins", flagged_file_name });
}

/// True when `plugin_id` is already recorded in the flagged store. A missing or
/// malformed file reports false (nothing is flagged yet).
pub fn isFlagged(allocator: std.mem.Allocator, plugin_id: []const u8) !bool {
    const path = try flaggedPath(allocator);
    defer allocator.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(max_flagged_bytes)) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.StreamTooLong => return false,
        else => return err,
    };
    defer allocator.free(bytes);

    var parsed = parse_helpers.parseJsonBounded(std.json.Value, allocator, parse_helpers.stripBom(bytes)) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;

    const plugins_obj = parsed.value.object.get(plugins_key) orelse return false;
    if (plugins_obj != .object) return false;
    return plugins_obj.object.get(plugin_id) != null;
}

/// List every flagged plugin id. Caller owns the returned slice and each string.
/// A missing or malformed store yields an empty (still owned) slice.
pub fn listFlagged(allocator: std.mem.Allocator) ![]const []const u8 {
    const path = try flaggedPath(allocator);
    defer allocator.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(max_flagged_bytes)) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc([]const u8, 0),
        error.StreamTooLong => return allocator.alloc([]const u8, 0),
        else => return err,
    };
    defer allocator.free(bytes);

    var parsed = parse_helpers.parseJsonBounded(std.json.Value, allocator, parse_helpers.stripBom(bytes)) catch return allocator.alloc([]const u8, 0);
    defer parsed.deinit();

    var out = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit();
    }
    if (parsed.value != .object) return out.toOwnedSlice();
    const plugins_obj = parsed.value.object.get(plugins_key) orelse return out.toOwnedSlice();
    if (plugins_obj != .object) return out.toOwnedSlice();

    var it = plugins_obj.object.iterator();
    while (it.next()) |kv| {
        try out.append(try allocator.dupe(u8, kv.key_ptr.*));
    }
    return out.toOwnedSlice();
}

/// Free a slice returned by `listFlagged`.
pub fn freeFlagged(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

/// Record `plugin_id` as flagged with the current timestamp. Read-modify-write:
/// every existing entry is copied forward and the target id inserted (or its
/// `flaggedAt` refreshed). Rebuilding the map sidesteps the 0.16 ObjectMap
/// pointer-after-parse footgun (a value copy desyncs the entries pointer on the
/// next realloc -- CLAUDE.md) by never mutating the parsed map in place. The
/// write is atomic (tmp + rename).
pub fn addFlagged(allocator: std.mem.Allocator, plugin_id: []const u8) !void {
    const path = try flaggedPath(allocator);
    defer allocator.free(path);

    try paths.ensureDir(std.fs.path.dirname(path) orelse return error.InvalidPath);

    const existing = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(max_flagged_bytes)) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        // A truncated/oversized store is treated as empty so a corrupt file
        // degrades to a fresh document rather than blocking the flag write.
        error.StreamTooLong => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(existing);

    // Parse the existing doc (if any). The parsed arena owns the strings copied
    // forward, so it is held alive until the new document is rendered.
    var parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed) |*p| p.deinit();
    if (existing.len > 0) {
        if (parse_helpers.parseJsonBounded(std.json.Value, allocator, parse_helpers.stripBom(existing))) |p| {
            parsed = p;
        } else |_| {}
    }

    // ISO-8601 UTC timestamp for the flaggedAt field. Stored on the stack and
    // referenced by the rendered JSON (Stringify only reads it).
    var ts_buf: [32]u8 = undefined;
    const ts = isoTimestamp(&ts_buf, clock.nowSeconds());

    var plugins_map: std.json.ObjectMap = .empty;
    defer {
        // Each value is a fresh nested ObjectMap built below; deinit them.
        var vit = plugins_map.iterator();
        while (vit.next()) |kv| {
            if (kv.value_ptr.* == .object) kv.value_ptr.object.deinit(allocator);
        }
        plugins_map.deinit(allocator);
    }

    // Copy every existing flagged entry forward, except the target (re-inserted
    // below with a refreshed timestamp). std.json.ObjectMap is unmanaged in
    // 0.16: construct via `.empty`, mutate via `put(allocator, ...)`.
    if (parsed) |p| {
        if (p.value == .object) {
            if (p.value.object.get(plugins_key)) |pl| {
                if (pl == .object) {
                    var it = pl.object.iterator();
                    while (it.next()) |kv| {
                        if (std.mem.eql(u8, kv.key_ptr.*, plugin_id)) continue;
                        // Carry the original value through verbatim (it is a
                        // borrow from the parsed arena, which outlives render).
                        try plugins_map.put(allocator, kv.key_ptr.*, kv.value_ptr.*);
                    }
                }
            }
        }
    }

    var entry_map: std.json.ObjectMap = .empty;
    // entry_map is moved into plugins_map below; its deinit happens via the
    // plugins_map cleanup loop above (which deinits nested .object values).
    try entry_map.put(allocator, flagged_at_key, .{ .string = ts });
    try plugins_map.put(allocator, plugin_id, .{ .object = entry_map });

    var root_map: std.json.ObjectMap = .empty;
    defer root_map.deinit(allocator);
    try root_map.put(allocator, plugins_key, .{ .object = plugins_map });

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(std.json.Value{ .object = root_map }, .{ .whitespace = .indent_2 }, out.writer());
    try out.writer().writeByte('\n');

    try writeAtomic(allocator, path, out.items());
}

/// Format `unix_seconds` as a minimal ISO-8601 UTC timestamp `YYYY-MM-DDTHH:MM:SSZ`.
/// The exact value is never parsed back by zcode (it is display/audit only), so
/// a compact representation is sufficient.
fn isoTimestamp(buf: []u8, unix_seconds: i64) []const u8 {
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(unix_seconds, 0)) };
    const day_secs = epoch_secs.getDaySeconds();
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch buf[0..0];
}

fn writeAtomic(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ path, clock.nowNanos() });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, data);
        file.sync(rt.io) catch {};
        file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o600)) catch {};
    }
    try std.Io.Dir.renameAbsolute(tmp_path, path, rt.io);
}

const testing = std.testing;
const test_helpers = @import("test_helpers.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const HomeRestore = struct {
    prev_home: ?[]u8,
    prev_xdg: ?[]u8,

    fn deinit(self: HomeRestore, allocator: std.mem.Allocator) void {
        if (self.prev_home) |h| {
            const z = allocator.dupeZ(u8, h) catch null;
            if (z) |zz| {
                _ = setenv("HOME", zz, 1);
                allocator.free(zz);
            }
            allocator.free(h);
        } else _ = unsetenv("HOME");
        if (self.prev_xdg) |x| {
            const z = allocator.dupeZ(u8, x) catch null;
            if (z) |zz| {
                _ = setenv("XDG_CONFIG_HOME", zz, 1);
                allocator.free(zz);
            }
            allocator.free(x);
        } else _ = unsetenv("XDG_CONFIG_HOME");
    }
};

fn pinHome(allocator: std.mem.Allocator, home: []const u8) !HomeRestore {
    const env = @import("env.zig");
    const prev_home = env.getOwned(allocator, "HOME") catch null;
    const prev_xdg = env.getOwned(allocator, "XDG_CONFIG_HOME") catch null;
    const home_z = try allocator.dupeZ(u8, home);
    defer allocator.free(home_z);
    _ = setenv("HOME", home_z, 1);
    _ = unsetenv("XDG_CONFIG_HOME");
    return .{ .prev_home = prev_home, .prev_xdg = prev_xdg };
}

test "addFlagged then isFlagged round-trips and persists" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(home);
    const restore = try pinHome(allocator, home);
    defer restore.deinit(allocator);

    try testing.expect(!(try isFlagged(allocator, "evil@market")));
    try addFlagged(allocator, "evil@market");
    try testing.expect(try isFlagged(allocator, "evil@market"));

    // A second add keeps exactly one entry (no duplication on re-write).
    try addFlagged(allocator, "evil@market");
    const ids = try listFlagged(allocator);
    defer freeFlagged(allocator, ids);
    try testing.expectEqual(@as(usize, 1), ids.len);
    try testing.expectEqualStrings("evil@market", ids[0]);

    // The store has the documented shape on disk.
    const path = try flaggedPath(allocator);
    defer allocator.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(max_flagged_bytes));
    defer allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"plugins\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"flaggedAt\"") != null);
}

test "listFlagged on a missing store is empty" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(home);
    const restore = try pinHome(allocator, home);
    defer restore.deinit(allocator);

    const ids = try listFlagged(allocator);
    defer freeFlagged(allocator, ids);
    try testing.expectEqual(@as(usize, 0), ids.len);
    try testing.expect(!(try isFlagged(allocator, "anything@local")));
}
