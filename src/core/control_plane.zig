const std = @import("std");
const std_io = @import("std_io.zig");
const rt = @import("zcode_runtime");
const rng = @import("rng.zig");
const clock = @import("clock.zig");
const http_common = @import("../providers/common.zig");

fn tokenTransportAllowed(control_plane_url: []const u8) bool {
    return std.mem.startsWith(u8, control_plane_url, "https://") or
        std.mem.startsWith(u8, control_plane_url, "http://localhost") or
        std.mem.startsWith(u8, control_plane_url, "http://127.0.0.1");
}

pub fn syncAuditEvent(
    allocator: std.mem.Allocator,
    control_plane_url: []const u8,
    token: []const u8,
    event: []const u8,
    payload: []const u8,
) !void {
    if (control_plane_url.len == 0) return;

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/v1/audit/events", .{control_plane_url});
    defer allocator.free(endpoint);

    var headers = std.array_list.Managed([]const u8).init(allocator);
    defer headers.deinit();

    if (token.len > 0) {
        if (!tokenTransportAllowed(control_plane_url)) {
            std.log.warn("control_plane: refusing to send auth token over insecure connection", .{});
            return;
        }
        const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{token});
        try headers.append(auth);
    }
    defer {
        for (headers.items) |h| allocator.free(h);
    }

    var body_buf = std_io.StringBuilder.init(allocator);
    defer body_buf.deinit();

    try body_buf.writer().print("{f}", .{std.json.fmt(.{
        .event = event,
        .payload = payload,
        .ts = clock.nowSeconds(),
    }, .{})});

    const response = http_common.callHttpJson(
        allocator,
        endpoint,
        headers.items,
        body_buf.items(),
        2_000,
    ) catch |err| {
        std.log.warn("control_plane: audit sync failed: {s}", .{@errorName(err)});
        return;
    };
    allocator.free(response);
}

pub fn syncPolicyBundle(
    allocator: std.mem.Allocator,
    control_plane_url: []const u8,
    token: []const u8,
    policy_path: []const u8,
    verify_hash: bool,
) !bool {
    if (control_plane_url.len == 0) return false;

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/v1/policy/bundle", .{control_plane_url});
    defer allocator.free(endpoint);

    var headers = std.array_list.Managed([]const u8).init(allocator);
    defer headers.deinit();

    if (token.len > 0) {
        if (!tokenTransportAllowed(control_plane_url)) {
            return error.InsecureControlPlaneTokenTransport;
        }
        const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{token});
        try headers.append(auth);
    }
    defer {
        for (headers.items) |h| allocator.free(h);
    }

    const raw = try http_common.callHttp(allocator, .GET, endpoint, headers.items, null, 5_000);
    defer allocator.free(raw);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return error.InvalidPolicyBundle;
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidPolicyBundle;
    const obj = parsed.value.object;

    const policy_val = obj.get("policy_toml") orelse obj.get("policy") orelse return error.MissingPolicyText;
    if (policy_val != .string) return error.InvalidPolicyBundle;
    const policy_text = policy_val.string;

    if (verify_hash) {
        const hash_val = obj.get("sha256") orelse return error.MissingPolicyHash;
        if (hash_val != .string) return error.InvalidPolicyBundle;
        const expected = std.mem.trim(u8, hash_val.string, " \t\r\n");

        const digest = sha256Hex(allocator, policy_text) catch return error.PolicyHashMismatch;
        defer allocator.free(digest);

        // Constant-time, case-insensitive compare. The previous
        // std.ascii.eqlIgnoreCase call short-circuits on the first
        // byte mismatch, which is a timing side-channel for an
        // attacker who can measure server response times and forge
        // policy bundles byte-by-byte.
        if (!constantTimeHexEqlIgnoreCase(digest, expected)) {
            return error.PolicyHashMismatch;
        }
    }

    const dir = std.fs.path.dirname(policy_path) orelse return error.InvalidPolicyPath;
    std.Io.Dir.cwd().createDirPath(rt.io, dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Atomic write: a SIGINT/crash between createFile (which
    // truncates to 0 bytes) and writeAll would discard the
    // SHA256-verified trusted policy we just authenticated, leaving
    // an empty policy file. Next start would fail to parse it (or
    // read as empty -> no policies enforced), turning a network
    // hiccup into a security-control regression. Same discipline as
    // src/core/keychain.zig (pass 64) and src/core/logger.zig (pass 65).
    try writePolicyFileAtomic(allocator, policy_path, policy_text);
    return true;
}

pub fn syncManagedSettings(
    allocator: std.mem.Allocator,
    control_plane_url: []const u8,
    token: []const u8,
    managed_config_path: []const u8,
    verify_hash: bool,
) !bool {
    if (control_plane_url.len == 0) return false;

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/v1/settings/managed", .{control_plane_url});
    defer allocator.free(endpoint);

    var headers = std.array_list.Managed([]const u8).init(allocator);
    defer headers.deinit();

    if (token.len > 0) {
        if (!tokenTransportAllowed(control_plane_url)) {
            return error.InsecureControlPlaneTokenTransport;
        }
        const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{token});
        try headers.append(auth);
    }
    defer {
        for (headers.items) |h| allocator.free(h);
    }

    const raw = try http_common.callHttp(allocator, .GET, endpoint, headers.items, null, 5_000);
    defer allocator.free(raw);

    try applyManagedSettingsBundle(allocator, raw, managed_config_path, verify_hash);
    return true;
}

fn applyManagedSettingsBundle(
    allocator: std.mem.Allocator,
    raw: []const u8,
    managed_config_path: []const u8,
    verify_hash: bool,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return error.InvalidManagedSettingsBundle;
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidManagedSettingsBundle;
    const obj = parsed.value.object;

    const settings_val = obj.get("managed_toml") orelse obj.get("settings_toml") orelse obj.get("config_toml") orelse return error.MissingManagedSettingsText;
    if (settings_val != .string) return error.InvalidManagedSettingsBundle;
    const settings_text = settings_val.string;

    var digest: ?[]u8 = null;
    defer if (digest) |d| allocator.free(d);

    if (verify_hash) {
        const hash_val = obj.get("sha256") orelse return error.MissingManagedSettingsHash;
        if (hash_val != .string) return error.InvalidManagedSettingsBundle;
        const expected = std.mem.trim(u8, hash_val.string, " \t\r\n");

        digest = sha256Hex(allocator, settings_text) catch return error.ManagedSettingsHashMismatch;
        if (!constantTimeHexEqlIgnoreCase(digest.?, expected)) {
            return error.ManagedSettingsHashMismatch;
        }
    } else {
        digest = try sha256Hex(allocator, settings_text);
    }

    const dir = std.fs.path.dirname(managed_config_path) orelse return error.InvalidManagedSettingsPath;
    std.Io.Dir.cwd().createDirPath(rt.io, dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    try writePolicyFileAtomic(allocator, managed_config_path, settings_text);

    const meta_path = try std.fmt.allocPrint(allocator, "{s}.meta.json", .{managed_config_path});
    defer allocator.free(meta_path);
    const meta = try std.fmt.allocPrint(
        allocator,
        "{f}\n",
        .{std.json.fmt(.{
            .schema_version = @as(u8, 1),
            .fetched_at = clock.nowSeconds(),
            .sha256 = digest orelse "",
        }, .{})},
    );
    defer allocator.free(meta);
    try writePolicyFileAtomic(allocator, meta_path, meta);
}

fn writePolicyFileAtomic(allocator: std.mem.Allocator, target: []const u8, bytes: []const u8) !void {
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
        file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o600)) catch |err| {
            std.log.warn("control_plane: chmod failed for policy tmp file: {s}", .{@errorName(err)});
        };
    }
    try std.Io.Dir.renameAbsolute(tmp_path, target, rt.io);
}

fn sha256Hex(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});

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

/// Case-insensitive byte-by-byte compare in constant time. Does not
/// short-circuit on mismatch, so timing cannot reveal where the two
/// strings diverge. Used for SHA-256 hex compare of policy bundles.
fn constantTimeHexEqlIgnoreCase(a: []const u8, b: []const u8) bool {
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

test "control plane token transport requires https or loopback" {
    try testing.expect(tokenTransportAllowed("https://control.example.com"));
    try testing.expect(tokenTransportAllowed("http://localhost:8080"));
    try testing.expect(tokenTransportAllowed("http://127.0.0.1:8080"));
    try testing.expect(!tokenTransportAllowed("http://control.example.com"));
}

test "sha256 hex helper stable" {
    const allocator = testing.allocator;
    const digest = try sha256Hex(allocator, "abc");
    defer allocator.free(digest);
    try testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", digest);
}

test "constantTimeHexEqlIgnoreCase handles case and mismatch" {
    try testing.expect(constantTimeHexEqlIgnoreCase("abc123", "ABC123"));
    try testing.expect(constantTimeHexEqlIgnoreCase("ba7816bf", "BA7816BF"));
    try testing.expect(!constantTimeHexEqlIgnoreCase("abc123", "abc124"));
    try testing.expect(!constantTimeHexEqlIgnoreCase("abc", "abcd"));
    try testing.expect(constantTimeHexEqlIgnoreCase("", ""));
}

test "applyManagedSettingsBundle verifies hash and writes metadata" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(dir_path);
    const managed_path = try std.fs.path.join(testing.allocator, &.{ dir_path, "managed.toml" });
    defer testing.allocator.free(managed_path);

    const body = "default_provider = \"openai\"\n";
    const digest = try sha256Hex(testing.allocator, body);
    defer testing.allocator.free(digest);
    const bundle = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"managed_toml\":\"default_provider = \\\"openai\\\"\\n\",\"sha256\":\"{s}\"}}",
        .{digest},
    );
    defer testing.allocator.free(bundle);

    try applyManagedSettingsBundle(testing.allocator, bundle, managed_path, true);

    const loaded = try std.Io.Dir.cwd().readFileAlloc(rt.io, managed_path, testing.allocator, .limited(1024));
    defer testing.allocator.free(loaded);
    try testing.expectEqualStrings(body, loaded);

    const meta_path = try std.fmt.allocPrint(testing.allocator, "{s}.meta.json", .{managed_path});
    defer testing.allocator.free(meta_path);
    const meta = try std.Io.Dir.cwd().readFileAlloc(rt.io, meta_path, testing.allocator, .limited(1024));
    defer testing.allocator.free(meta);
    try testing.expect(std.mem.indexOf(u8, meta, digest) != null);
}
