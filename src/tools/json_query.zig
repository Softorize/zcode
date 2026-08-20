const std = @import("std");
const std_io = @import("../core/std_io.zig");
const rt = @import("zcode_runtime");
const helpers = @import("helpers.zig");
const normalizePath = helpers.normalizePath;

pub fn query(allocator: std.mem.Allocator, cwd: []const u8, inline_json: ?[]const u8, json_path: ?[]const u8, selector: []const u8) ![]u8 {
    var source_data: ?[]u8 = null;
    defer if (source_data) |buf| allocator.free(buf);

    const raw_json: []const u8 = blk: {
        if (json_path) |path| {
            const abs = try normalizePath(allocator, cwd, path);
            defer allocator.free(abs);
            const data = try std.Io.Dir.cwd().readFileAlloc(rt.io, abs, allocator, .limited(4 * 1024 * 1024));
            source_data = data;
            break :blk data;
        }
        const inline_value = inline_json orelse return allocator.dupe(u8, "json_query failed: provide json or path");
        break :blk inline_value;
    };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{}) catch |err| {
        return std.fmt.allocPrint(allocator, "json_query parse error: {s}", .{@errorName(err)});
    };
    defer parsed.deinit();

    var current = parsed.value;
    var parts = std.mem.splitScalar(u8, selector, '.');
    while (parts.next()) |segment_raw| {
        const segment = std.mem.trim(u8, segment_raw, " \t");
        if (segment.len == 0) continue;

        if (isDigits(segment)) {
            if (current != .array) return std.fmt.allocPrint(allocator, "json_query failed: '{s}' is not an array index target", .{segment});
            const idx = std.fmt.parseInt(usize, segment, 10) catch return std.fmt.allocPrint(allocator, "json_query failed: invalid index '{s}'", .{segment});
            if (idx >= current.array.items.len) return std.fmt.allocPrint(allocator, "json_query failed: index {d} out of bounds", .{idx});
            current = current.array.items[idx];
            continue;
        }

        if (current != .object) return std.fmt.allocPrint(allocator, "json_query failed: key '{s}' on non-object", .{segment});
        const next = current.object.get(segment) orelse return std.fmt.allocPrint(allocator, "json_query failed: key '{s}' not found", .{segment});
        current = next;
    }

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    try out.writer().print("{f}", .{std.json.fmt(current, .{})});
    return out.toOwnedSlice();
}

fn isDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

const testing = std.testing;

test "json query nested object" {
    const out = try query(testing.allocator, ".", "{\"a\":{\"b\":[1,2,3]}}", null, "a.b.1");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("2", std.mem.trim(u8, out, " \t\r\n"));
}
