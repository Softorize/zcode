const std = @import("std");
const rng = @import("rng.zig");
const std_io = @import("std_io.zig");
const rt = @import("zcode_runtime");
const clock = @import("clock.zig");
const types = @import("types.zig");

const CACHE_TTL_SECONDS: i64 = 3600;

fn cachePath(allocator: std.mem.Allocator, provider_name: []const u8) ![]u8 {
    const home = try @import("env.zig").getOwned(allocator, "HOME");
    defer allocator.free(home);
    const filename = try std.fmt.allocPrint(allocator, "models_cache_{s}.json", .{provider_name});
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ home, ".zcode", filename });
}

/// Load cached models for a provider. Returns null on cache miss or if expired.
pub fn loadCached(allocator: std.mem.Allocator, provider_name: []const u8) ?[]types.ModelInfo {
    return loadCachedInner(allocator, provider_name) catch null;
}

fn loadCachedInner(allocator: std.mem.Allocator, provider_name: []const u8) ![]types.ModelInfo {
    const path = try cachePath(allocator, provider_name);
    defer allocator.free(path);

    const data = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidCache;

    // Check TTL
    const ts = parsed.value.object.get("ts") orelse return error.InvalidCache;
    if (ts != .integer) return error.InvalidCache;
    const age = clock.nowSeconds() - ts.integer;
    if (age > CACHE_TTL_SECONDS or age < 0) return error.StaleCache;

    const models_val = parsed.value.object.get("models") orelse return error.InvalidCache;
    if (models_val != .array) return error.InvalidCache;

    var out = std.array_list.Managed(types.ModelInfo).init(allocator);
    errdefer {
        for (out.items) |m| {
            allocator.free(m.id);
            allocator.free(m.provider);
        }
        out.deinit();
    }

    for (models_val.array.items) |item| {
        if (item != .object) continue;
        const id_val = item.object.get("id") orelse continue;
        const prov_val = item.object.get("provider") orelse continue;
        const cw_val = item.object.get("context_window") orelse continue;
        if (id_val != .string or prov_val != .string or cw_val != .integer) continue;
        if (cw_val.integer < 0) continue;

        try out.append(.{
            .id = try allocator.dupe(u8, id_val.string),
            .provider = try allocator.dupe(u8, prov_val.string),
            .context_window = @intCast(cw_val.integer),
        });
    }

    if (out.items.len == 0) return error.EmptyCache;
    return try out.toOwnedSlice();
}

/// Persist discovered models for a provider into its per-provider cache file.
pub fn saveCache(allocator: std.mem.Allocator, provider_name: []const u8, models: []const types.ModelInfo) void {
    saveCacheInner(allocator, provider_name, models) catch |err| {
        std.log.warn("model_cache: failed to save cache for {s}: {s}", .{ provider_name, @errorName(err) });
    };
}

fn saveCacheInner(allocator: std.mem.Allocator, provider_name: []const u8, models: []const types.ModelInfo) !void {
    const path = try cachePath(allocator, provider_name);
    defer allocator.free(path);

    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(rt.io, dir) catch {};
    }

    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();

    const w = buf.writer();
    try w.print("{{\"ts\":{d},\"models\":[", .{clock.nowSeconds()});
    for (models, 0..) |m, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"id\":{f},\"provider\":{f},\"context_window\":{d}}}", .{ std.json.fmt(m.id, .{}), std.json.fmt(m.provider, .{}), m.context_window });
    }
    try w.writeAll("]}");

    // Atomic write: temp file + rename. The nonce defends against two
    // concurrent zcode invocations writing the same cache in parallel
    // (e.g. a REPL + a scripted `zcode models list` in the background)
    // clobbering each other's .tmp file and leaving the final rename
    // to win a race on truncated content.
    const nonce = rng.int(u64);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{x}", .{ path, nonce });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};
    {
        const flags: std.posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
        const fd = try std_io.openFlagsAlloc(rt.gpa, tmp_path, flags, 0o600);
        const tmp = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
        defer tmp.close(rt.io);
        try tmp.writeStreamingAll(rt.io, buf.items());
        tmp.sync(rt.io) catch {};
    }
    try std.Io.Dir.renameAbsolute(tmp_path, path, rt.io);
}
