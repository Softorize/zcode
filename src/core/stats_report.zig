//! Cross-session statistics for `/stats` and `/insights`.
//!
//! Walks the session store directory and aggregates:
//!   - session count
//!   - total turns (role breakdown)
//!   - distinct days active
//!   - sessions touched in the last 7 days
//!   - per-day turn counts for the last 14 days (for /insights)
//!   - top label/tag frequencies (for /insights)
//!
//! The reference exposes richer analytics via its hosted telemetry
//! backend. zcode's stats live entirely on the local disk and
//! never phone home -- all the numbers come from the jsonl session
//! files in the configured sessions_dir.

const std = @import("std");
const std_io = @import("std_io.zig");
const clock = @import("clock.zig");
const session_store = @import("../session/store.zig");

pub const SessionSummary = struct {
    id: []u8,
    label: ?[]u8 = null,
    updated_ts: i64,
    turn_count: usize,
    user_turns: usize,
    assistant_turns: usize,
    tags: [][]u8 = &.{},
    size_bytes: u64 = 0,

    pub fn deinit(self: *SessionSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.label) |l| allocator.free(l);
        for (self.tags) |t| allocator.free(t);
        allocator.free(self.tags);
    }
};

pub fn freeSummaries(allocator: std.mem.Allocator, items: []SessionSummary) void {
    for (items) |*s| {
        var mut = s.*;
        mut.deinit(allocator);
    }
    allocator.free(items);
}

pub fn collect(
    allocator: std.mem.Allocator,
    store: *session_store.Store,
) ![]SessionSummary {
    const entries = try store.list();
    defer store.freeSessionEntries(entries);

    var out = std.array_list.Managed(SessionSummary).init(allocator);
    errdefer {
        freeSummaries(allocator, out.items);
        out.items.len = 0;
    }

    for (entries) |entry| {
        const counts = try store.countTurns(entry.id);
        const tags = try store.readTags(entry.id);

        const id_dup = try allocator.dupe(u8, entry.id);
        const label_dup: ?[]u8 = if (entry.label) |l| try allocator.dupe(u8, l) else null;
        try out.append(.{
            .id = id_dup,
            .label = label_dup,
            .updated_ts = entry.updated_ts,
            .turn_count = counts.total,
            .user_turns = counts.user,
            .assistant_turns = counts.assistant,
            .tags = tags,
            .size_bytes = counts.bytes,
        });
    }
    return out.toOwnedSlice();
}

pub fn renderStats(
    allocator: std.mem.Allocator,
    summaries: []const SessionSummary,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    if (summaries.len == 0) {
        try w.writeAll("no sessions on disk yet.\n");
        return out.toOwnedSlice();
    }

    var total_turns: usize = 0;
    var user_turns: usize = 0;
    var asst_turns: usize = 0;
    var total_bytes: u64 = 0;
    const now = clock.nowSeconds();
    const week_cutoff = now - 7 * 24 * 60 * 60;
    var last_week: usize = 0;
    for (summaries) |s| {
        total_turns += s.turn_count;
        user_turns += s.user_turns;
        asst_turns += s.assistant_turns;
        total_bytes += s.size_bytes;
        if (s.updated_ts >= week_cutoff) last_week += 1;
    }

    try w.print("sessions on disk:      {d}\n", .{summaries.len});
    try w.print("active in last 7d:     {d}\n", .{last_week});
    try w.print("total turns:           {d}\n", .{total_turns});
    try w.print("  user:                {d}\n", .{user_turns});
    try w.print("  assistant:           {d}\n", .{asst_turns});
    const avg_turns_x10: usize = if (summaries.len == 0) 0 else (total_turns * 10) / summaries.len;
    try w.print("avg turns / session:   {d}.{d}\n", .{ avg_turns_x10 / 10, avg_turns_x10 % 10 });
    try w.print("total bytes on disk:   {d}\n", .{total_bytes});

    return out.toOwnedSlice();
}

pub fn renderInsights(
    allocator: std.mem.Allocator,
    summaries: []const SessionSummary,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    if (summaries.len == 0) {
        try w.writeAll("no sessions on disk yet.\n");
        return out.toOwnedSlice();
    }

    // Per-day activity for the last 14 days.
    const now = clock.nowSeconds();
    const day: i64 = 24 * 60 * 60;
    const days_back: usize = 14;
    var day_counts = [_]usize{0} ** days_back;
    for (summaries) |s| {
        const age_s = now - s.updated_ts;
        if (age_s < 0) continue;
        const age_days: usize = @intCast(@divFloor(age_s, day));
        if (age_days < days_back) day_counts[age_days] += 1;
    }

    try w.writeAll("sessions updated per day (last 14):\n");
    var day_idx: usize = 0;
    while (day_idx < days_back) : (day_idx += 1) {
        const d = days_back - 1 - day_idx;
        const count = day_counts[d];
        const bar_len = @min(count, 40);
        try w.print("  -{d: >2}d  ", .{d});
        var bar_i: usize = 0;
        while (bar_i < bar_len) : (bar_i += 1) try w.writeAll("#");
        try w.print(" {d}\n", .{count});
    }

    // Tag frequency. StringHashMap keeps this O(N) rather than
    // the O(N^2) linear-probe implementation we shipped first.
    try w.writeAll("\ntag frequency:\n");
    var tag_map = std.StringHashMap(usize).init(allocator);
    defer tag_map.deinit();
    for (summaries) |s| {
        for (s.tags) |tag| {
            const gop = try tag_map.getOrPut(tag);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
    }

    if (tag_map.count() == 0) {
        try w.writeAll("  (none -- set tags with `/tag add <name>`)\n");
        return out.toOwnedSlice();
    }

    const TagCount = struct { name: []const u8, count: usize };
    var tag_counts = std.array_list.Managed(TagCount).init(allocator);
    defer tag_counts.deinit();
    var it = tag_map.iterator();
    while (it.next()) |e| try tag_counts.append(.{ .name = e.key_ptr.*, .count = e.value_ptr.* });

    std.mem.sort(TagCount, tag_counts.items, {}, struct {
        fn lessThan(_: void, a: TagCount, b: TagCount) bool {
            return a.count > b.count;
        }
    }.lessThan);
    for (tag_counts.items) |tc| {
        try w.print("  {d: >4}x  {s}\n", .{ tc.count, tc.name });
    }

    return out.toOwnedSlice();
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

fn makeSummary(
    allocator: std.mem.Allocator,
    id: []const u8,
    updated_ts: i64,
    user: usize,
    asst: usize,
    bytes: u64,
    tags: []const []const u8,
) !SessionSummary {
    var owned_tags = try allocator.alloc([]u8, tags.len);
    errdefer allocator.free(owned_tags);
    var done: usize = 0;
    errdefer {
        for (owned_tags[0..done]) |t| allocator.free(t);
    }
    for (tags, 0..) |t, i| {
        owned_tags[i] = try allocator.dupe(u8, t);
        done = i + 1;
    }
    return .{
        .id = try allocator.dupe(u8, id),
        .label = null,
        .updated_ts = updated_ts,
        .turn_count = user + asst,
        .user_turns = user,
        .assistant_turns = asst,
        .tags = owned_tags,
        .size_bytes = bytes,
    };
}

test "renderStats on empty summaries shows an explanatory line" {
    const out = try renderStats(testing.allocator, &.{});
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "no sessions on disk") != null);
}

test "renderStats aggregates turn counts and averages" {
    var items: [3]SessionSummary = undefined;
    items[0] = try makeSummary(testing.allocator, "a", clock.nowSeconds(), 4, 6, 1024, &.{});
    items[1] = try makeSummary(testing.allocator, "b", clock.nowSeconds() - 10 * 24 * 60 * 60, 2, 4, 2048, &.{});
    items[2] = try makeSummary(testing.allocator, "c", clock.nowSeconds() - 1, 0, 0, 0, &.{});
    defer freeSummaries(testing.allocator, testing.allocator.dupe(SessionSummary, &items) catch unreachable);

    const out = try renderStats(testing.allocator, &items);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "sessions on disk:      3") != null);
    try testing.expect(std.mem.indexOf(u8, out, "total turns:           16") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  user:                6") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  assistant:           10") != null);
    // 16 turns / 3 sessions = 5.3
    try testing.expect(std.mem.indexOf(u8, out, "avg turns / session:   5.3") != null);
}

test "renderStats counts only last-7-days sessions as active" {
    const now = clock.nowSeconds();
    const day: i64 = 24 * 60 * 60;
    var items: [3]SessionSummary = undefined;
    items[0] = try makeSummary(testing.allocator, "recent", now - 1 * day, 1, 1, 0, &.{});
    items[1] = try makeSummary(testing.allocator, "older", now - 30 * day, 1, 1, 0, &.{});
    items[2] = try makeSummary(testing.allocator, "edge", now - 6 * day, 1, 1, 0, &.{});
    defer freeSummaries(testing.allocator, testing.allocator.dupe(SessionSummary, &items) catch unreachable);

    const out = try renderStats(testing.allocator, &items);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "active in last 7d:     2") != null);
}

test "renderInsights shows no-sessions message when list is empty" {
    const out = try renderInsights(testing.allocator, &.{});
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "no sessions on disk") != null);
}

test "renderInsights tallies tag frequency sorted by count desc" {
    var items: [3]SessionSummary = undefined;
    items[0] = try makeSummary(testing.allocator, "a", clock.nowSeconds(), 1, 1, 0, &.{ "deploy", "backend" });
    items[1] = try makeSummary(testing.allocator, "b", clock.nowSeconds(), 1, 1, 0, &.{"deploy"});
    items[2] = try makeSummary(testing.allocator, "c", clock.nowSeconds(), 1, 1, 0, &.{"frontend"});
    defer freeSummaries(testing.allocator, testing.allocator.dupe(SessionSummary, &items) catch unreachable);

    const out = try renderInsights(testing.allocator, &items);
    defer testing.allocator.free(out);

    const deploy_idx = std.mem.indexOf(u8, out, "deploy") orelse return error.TestUnexpectedResult;
    const backend_idx = std.mem.indexOf(u8, out, "backend") orelse return error.TestUnexpectedResult;
    const frontend_idx = std.mem.indexOf(u8, out, "frontend") orelse return error.TestUnexpectedResult;
    // deploy (count=2) must appear before the count=1 tags.
    try testing.expect(deploy_idx < backend_idx);
    try testing.expect(deploy_idx < frontend_idx);
    try testing.expect(std.mem.indexOf(u8, out, "   2x  deploy") != null);
}

test "renderInsights reports no-tags hint when every session is untagged" {
    var items: [2]SessionSummary = undefined;
    items[0] = try makeSummary(testing.allocator, "a", clock.nowSeconds(), 1, 1, 0, &.{});
    items[1] = try makeSummary(testing.allocator, "b", clock.nowSeconds(), 1, 1, 0, &.{});
    defer freeSummaries(testing.allocator, testing.allocator.dupe(SessionSummary, &items) catch unreachable);

    const out = try renderInsights(testing.allocator, &items);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "(none -- set tags") != null);
}
