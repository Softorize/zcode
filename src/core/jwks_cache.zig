const std = @import("std");
const rt = @import("zcode_runtime");
const rng = @import("rng.zig");
const clock = @import("clock.zig");
const config_mod = @import("config.zig");
const paths = @import("paths.zig");
const http_common = @import("../providers/common.zig");

pub const max_jwks_bytes = 256 * 1024;

pub const LoadedJwks = struct {
    json: []const u8,
    owned: ?[]u8 = null,

    pub fn deinit(self: *LoadedJwks, allocator: std.mem.Allocator) void {
        if (self.owned) |owned| allocator.free(owned);
    }
};

pub const RefreshResult = struct {
    cache_path: []u8,
    key_count: usize,

    pub fn deinit(self: *RefreshResult, allocator: std.mem.Allocator) void {
        allocator.free(self.cache_path);
    }
};

pub fn loadEffective(
    allocator: std.mem.Allocator,
    jwks_json: []const u8,
    jwks_file: []const u8,
    jwks_url: []const u8,
    ttl_seconds: u32,
) !LoadedJwks {
    if (jwks_json.len > 0) {
        _ = try countKeys(allocator, jwks_json);
        return .{ .json = jwks_json };
    }
    if (jwks_file.len > 0) {
        const json = try readTrustedFileAlloc(allocator, jwks_file, max_jwks_bytes, error.UntrustedJwksFilePermissions);
        errdefer allocator.free(json);
        _ = try countKeys(allocator, json);
        return .{ .json = json, .owned = json };
    }
    if (jwks_url.len > 0) {
        return loadFromUrlCache(allocator, jwks_url, ttl_seconds);
    }
    return error.JwksUnavailable;
}

pub fn loadFromUrlCache(allocator: std.mem.Allocator, jwks_url: []const u8, ttl_seconds: u32) !LoadedJwks {
    const cache_path = try cacheFilePath(allocator);
    defer allocator.free(cache_path);

    if (try cacheFreshForUrl(allocator, cache_path, jwks_url, ttl_seconds)) {
        const cached = try readCachedJwks(allocator, cache_path);
        return .{ .json = cached, .owned = cached };
    }

    var refreshed = refreshUrl(allocator, jwks_url, ttl_seconds) catch |err| {
        const cached = readCachedJwks(allocator, cache_path) catch return err;
        std.log.warn("oidc jwks refresh failed ({s}); using last-good cached JWKS", .{@errorName(err)});
        return .{ .json = cached, .owned = cached };
    };
    defer refreshed.deinit(allocator);

    const cached = try readCachedJwks(allocator, cache_path);
    return .{ .json = cached, .owned = cached };
}

pub fn refreshFromConfig(allocator: std.mem.Allocator, cfg: *const config_mod.Config) !RefreshResult {
    if (cfg.api_oidc_jwks_url.len == 0) return error.MissingJwksUrl;
    return refreshUrl(allocator, cfg.api_oidc_jwks_url, cfg.api_oidc_jwks_cache_ttl_seconds);
}

pub fn cmdRefresh(allocator: std.mem.Allocator, cfg: *const config_mod.Config, writer: anytype) !void {
    var result = try refreshFromConfig(allocator, cfg);
    defer result.deinit(allocator);
    try writer.print(
        "JWKS cache refreshed: {d} keys\n  url: {s}\n  cache: {s}\n",
        .{ result.key_count, cfg.api_oidc_jwks_url, result.cache_path },
    );
}

pub fn refreshUrl(allocator: std.mem.Allocator, jwks_url: []const u8, ttl_seconds: u32) !RefreshResult {
    const headers = [_][]const u8{"Accept: application/json"};
    const body = try http_common.callHttpWithPolicy(
        allocator,
        .GET,
        jwks_url,
        &headers,
        null,
        5_000,
        .{},
    );
    defer allocator.free(body);

    if (body.len > max_jwks_bytes) return error.JwksTooLarge;
    const key_count = try countKeys(allocator, body);

    const cache_path = try cacheFilePath(allocator);
    errdefer allocator.free(cache_path);
    try writeCache(allocator, cache_path, jwks_url, ttl_seconds, body, key_count);

    return .{ .cache_path = cache_path, .key_count = key_count };
}

pub fn cacheFilePath(allocator: std.mem.Allocator) ![]u8 {
    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);
    return std.fs.path.join(allocator, &.{ resolved.zcode_home, "cache", "api-oidc-jwks.json" });
}

pub fn countKeys(allocator: std.mem.Allocator, jwks_json: []const u8) !usize {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, jwks_json, .{}) catch return error.InvalidJwks;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJwks;
    const keys = parsed.value.object.get("keys") orelse return error.InvalidJwks;
    if (keys != .array) return error.InvalidJwks;
    return keys.array.items.len;
}

fn cacheFreshForUrl(allocator: std.mem.Allocator, cache_path: []const u8, jwks_url: []const u8, ttl_seconds: u32) !bool {
    if (ttl_seconds == 0) return false;
    const meta_path = try metaPath(allocator, cache_path);
    defer allocator.free(meta_path);

    const raw = readTrustedFileAlloc(allocator, meta_path, 16 * 1024, error.UntrustedJwksCacheMetaPermissions) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.UntrustedJwksCacheMetaPermissions => return false,
        else => return err,
    };
    defer allocator.free(raw);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const obj = parsed.value.object;
    const url_val = obj.get("url") orelse return false;
    const fetched_val = obj.get("fetched_at") orelse return false;
    if (url_val != .string or fetched_val != .integer) return false;
    if (!std.mem.eql(u8, url_val.string, jwks_url)) return false;
    const age = clock.nowSeconds() - fetched_val.integer;
    return age >= 0 and age <= @as(i64, @intCast(ttl_seconds));
}

fn readCachedJwks(allocator: std.mem.Allocator, cache_path: []const u8) ![]u8 {
    const cached = try readTrustedFileAlloc(allocator, cache_path, max_jwks_bytes, error.UntrustedJwksCachePermissions);
    errdefer allocator.free(cached);
    _ = try countKeys(allocator, cached);
    return cached;
}

pub fn cacheFileTrusted(cache_path: []const u8) !bool {
    rejectUntrustedFileAtPath(cache_path, error.UntrustedJwksCachePermissions) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

pub fn cacheMetadataTrusted(allocator: std.mem.Allocator, cache_path: []const u8) !bool {
    const meta_path_value = try metaPath(allocator, cache_path);
    defer allocator.free(meta_path_value);
    rejectUntrustedFileAtPath(meta_path_value, error.UntrustedJwksCacheMetaPermissions) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

pub fn sourceFileTrusted(jwks_file: []const u8) !bool {
    rejectUntrustedFileAtPath(jwks_file, error.UntrustedJwksFilePermissions) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn readTrustedFileAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
    comptime permissions_error: anyerror,
) ![]u8 {
    var file = try openFileForRead(path);
    defer file.close(rt.io);
    try rejectUntrustedOpenFile(file, permissions_error);
    return blk: {
        const _sz = file.length(rt.io) catch break :blk error.ReadFailed;
        const _max = @min(_sz, max_bytes);
        const _buf = try allocator.alloc(u8, _max);
        errdefer allocator.free(_buf);
        _ = file.readPositionalAll(rt.io, _buf, 0) catch break :blk error.ReadFailed;
        break :blk _buf;
    };
}

fn rejectUntrustedFileAtPath(path: []const u8, comptime permissions_error: anyerror) !void {
    var file = try openFileForRead(path);
    defer file.close(rt.io);
    try rejectUntrustedOpenFile(file, permissions_error);
}

fn openFileForRead(path: []const u8) !std.Io.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.openFileAbsolute(rt.io, path, .{});
    }
    return std.Io.Dir.cwd().openFile(rt.io, path, .{});
}

fn rejectUntrustedOpenFile(file: std.Io.File, comptime permissions_error: anyerror) !void {
    const stat = try file.stat(rt.io);
    if ((stat.permissions.toMode() & 0o022) != 0) return permissions_error;
}

fn writeCache(
    allocator: std.mem.Allocator,
    cache_path: []const u8,
    jwks_url: []const u8,
    ttl_seconds: u32,
    body: []const u8,
    key_count: usize,
) !void {
    const dir = std.fs.path.dirname(cache_path) orelse return error.InvalidJwksCachePath;
    try paths.ensureDir(dir);

    try writeFileAtomic(allocator, cache_path, body);

    const meta_path_value = try metaPath(allocator, cache_path);
    defer allocator.free(meta_path_value);
    const meta = try std.fmt.allocPrint(allocator, "{f}\n", .{std.json.fmt(.{
        .schema_version = @as(u8, 1),
        .url = jwks_url,
        .fetched_at = clock.nowSeconds(),
        .ttl_seconds = ttl_seconds,
        .key_count = key_count,
    }, .{})});
    defer allocator.free(meta);
    try writeFileAtomic(allocator, meta_path_value, meta);
}

fn metaPath(allocator: std.mem.Allocator, cache_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.meta.json", .{cache_path});
}

fn writeFileAtomic(allocator: std.mem.Allocator, target: []const u8, bytes: []const u8) !void {
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
        file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o600)) catch {};
    }
    try std.Io.Dir.renameAbsolute(tmp_path, target, rt.io);
}

const testing = std.testing;

test "countKeys validates JWKS shape" {
    try testing.expectEqual(@as(usize, 2), try countKeys(testing.allocator,
        \\{"keys":[{"kid":"one"},{"kid":"two"}]}
    ));
    try testing.expectError(error.InvalidJwks, countKeys(testing.allocator, "{\"not_keys\":[]}"));
}

test "loadEffective prefers inline JWKS" {
    var loaded = try loadEffective(testing.allocator, "{\"keys\":[]}", "", "", 60);
    defer loaded.deinit(testing.allocator);
    try testing.expectEqualStrings("{\"keys\":[]}", loaded.json);
}

test "JWKS cache rejects group or world writable cache file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "jwks.json", .data = "{\"keys\":[]}" });
    {
        const file = try tmp.dir.openFile(rt.io, "jwks.json", .{});
        defer file.close(rt.io);
        try file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o666)); // sast: allow - test fixture for permission rejection
    }

    const root = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(root);
    const cache_path = try std.fs.path.join(testing.allocator, &.{ root, "jwks.json" });
    defer testing.allocator.free(cache_path);

    try testing.expectError(error.UntrustedJwksCachePermissions, readCachedJwks(testing.allocator, cache_path));
}

test "JWKS cache metadata trust rejects group or world writable meta file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "jwks.json.meta.json", .data = "{\"url\":\"https://idp.example/jwks\",\"fetched_at\":1}" });
    {
        const file = try tmp.dir.openFile(rt.io, "jwks.json.meta.json", .{});
        defer file.close(rt.io);
        try file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o666)); // sast: allow - test fixture for permission rejection
    }

    const root = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(root);
    const cache_path = try std.fs.path.join(testing.allocator, &.{ root, "jwks.json" });
    defer testing.allocator.free(cache_path);

    try testing.expectError(error.UntrustedJwksCacheMetaPermissions, cacheMetadataTrusted(testing.allocator, cache_path));
}

test "loadEffective rejects group or world writable JWKS file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "jwks.json", .data = "{\"keys\":[]}" });
    {
        const file = try tmp.dir.openFile(rt.io, "jwks.json", .{});
        defer file.close(rt.io);
        try file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o666)); // sast: allow - test fixture for permission rejection
    }

    const root = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(root);
    const jwks_file = try std.fs.path.join(testing.allocator, &.{ root, "jwks.json" });
    defer testing.allocator.free(jwks_file);

    try testing.expectError(error.UntrustedJwksFilePermissions, loadEffective(testing.allocator, "", jwks_file, "", 60));
}
