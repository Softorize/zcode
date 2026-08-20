const std = @import("std");
const rt = @import("zcode_runtime");

pub const SidecarStatus = enum {
    absent,
    verified,
};

pub fn verifySha256Sidecar(allocator: std.mem.Allocator, path: []const u8) !SidecarStatus {
    const sidecar_path = try sidecarPath(allocator, path);
    defer allocator.free(sidecar_path);

    const expected_raw = std.Io.Dir.cwd().readFileAlloc(rt.io, sidecar_path, allocator, .limited(4096)) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        else => return err,
    };
    defer allocator.free(expected_raw);
    try rejectGroupWorldWritable(sidecar_path);

    const body = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(body);

    return verifySha256SidecarForBytesFromRaw(allocator, path, body, expected_raw);
}

pub fn verifySha256SidecarForBytes(allocator: std.mem.Allocator, path: []const u8, body: []const u8) !SidecarStatus {
    const sidecar_path = try sidecarPath(allocator, path);
    defer allocator.free(sidecar_path);

    const expected_raw = std.Io.Dir.cwd().readFileAlloc(rt.io, sidecar_path, allocator, .limited(4096)) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        else => return err,
    };
    defer allocator.free(expected_raw);
    try rejectGroupWorldWritable(sidecar_path);

    return verifySha256SidecarForBytesFromRaw(allocator, path, body, expected_raw);
}

fn verifySha256SidecarForBytesFromRaw(
    allocator: std.mem.Allocator,
    path: []const u8,
    body: []const u8,
    expected_raw: []const u8,
) !SidecarStatus {
    _ = path;
    const expected = firstSha256Token(expected_raw) orelse return error.InvalidSha256Sidecar;
    if (expected.len != 64 or !isHex(expected)) return error.InvalidSha256Sidecar;

    const actual = try sha256Hex(allocator, body);
    defer allocator.free(actual);

    if (!constantTimeHexEqlIgnoreCase(actual, expected)) return error.Sha256SidecarMismatch;
    return .verified;
}

pub fn sidecarPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.sha256", .{path});
}

fn rejectGroupWorldWritable(path: []const u8) !void {
    const stat = try std.Io.Dir.cwd().statFile(rt.io, path, .{});
    if ((stat.permissions.toMode() & 0o022) != 0) return error.UntrustedSha256SidecarPermissions;
}

fn firstSha256Token(raw: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
    return it.next();
}

fn isHex(value: []const u8) bool {
    for (value) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

pub fn sha256Hex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

    const out = try allocator.alloc(u8, digest.len * 2);
    for (digest, 0..) |byte, idx| {
        out[idx * 2] = nibbleToHex(@intCast((byte >> 4) & 0x0f));
        out[idx * 2 + 1] = nibbleToHex(@intCast(byte & 0x0f));
    }
    return out;
}

fn nibbleToHex(n: u4) u8 {
    return if (n < 10) @as(u8, '0') + n else @as(u8, 'a') + (n - 10);
}

pub fn constantTimeHexEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |ac, bc| {
        const an: u8 = if (ac >= 'A' and ac <= 'Z') ac + 32 else ac;
        const bn: u8 = if (bc >= 'A' and bc <= 'Z') bc + 32 else bc;
        diff |= an ^ bn;
    }
    return diff == 0;
}

const testing = std.testing;

test "sha256 sidecar verifies checksum file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "managed.toml", .data = "api_auth_required = true\n" });
    const root = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(root);
    const target = try std.fs.path.join(testing.allocator, &.{ root, "managed.toml" });
    defer testing.allocator.free(target);

    const digest = try sha256Hex(testing.allocator, "api_auth_required = true\n");
    defer testing.allocator.free(digest);
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "managed.toml.sha256", .data = digest });

    try testing.expectEqual(SidecarStatus.verified, try verifySha256Sidecar(testing.allocator, target));
}

test "sha256 sidecar mismatch fails closed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "policy.toml", .data = "allow = true\n" });
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "policy.toml.sha256", .data = "0000000000000000000000000000000000000000000000000000000000000000\n" });
    const root = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(root);
    const target = try std.fs.path.join(testing.allocator, &.{ root, "policy.toml" });
    defer testing.allocator.free(target);

    try testing.expectError(error.Sha256SidecarMismatch, verifySha256Sidecar(testing.allocator, target));
}

test "sha256 sidecar rejects group or world writable checksum file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "managed.toml", .data = "api_auth_required = true\n" });
    const digest = try sha256Hex(testing.allocator, "api_auth_required = true\n");
    defer testing.allocator.free(digest);
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "managed.toml.sha256", .data = digest });
    {
        const file = try tmp.dir.openFile(rt.io, "managed.toml.sha256", .{});
        defer file.close(rt.io);
        try file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o666)); // sast: allow - test fixture for permission rejection
    }

    const root = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(root);
    const target = try std.fs.path.join(testing.allocator, &.{ root, "managed.toml" });
    defer testing.allocator.free(target);

    try testing.expectError(error.UntrustedSha256SidecarPermissions, verifySha256Sidecar(testing.allocator, target));
}
