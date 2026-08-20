const std = @import("std");
const rt = @import("zcode_runtime");
const http_common = @import("../providers/common.zig");
const egress = @import("../core/egress.zig");

pub fn request(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    method: []const u8,
    url: []const u8,
    headers: ?[]const u8,
    body: ?[]const u8,
    timeout_seconds: usize,
    max_bytes: usize,
) ![]u8 {
    // Route through the central egress chokepoint. Refuses plaintext
    // http:// to non-loopback hosts (which would otherwise let a
    // prompt-injected model exfiltrate the response of the previous
    // tool call to an attacker-controlled HTTP host) and any URL
    // resolving to a cloud-metadata / RFC1918 / link-local range.
    switch (egress.checkUrl(allocator, url, .{})) {
        .allow => {},
        .deny_scheme => return allocator.dupe(u8, "http_request failed: URL must use https:// (or http:// to a loopback address). Plaintext HTTP to remote hosts is blocked so a network observer cannot read the response body."),
        .deny_ssrf => return allocator.dupe(u8, "http_request failed: URL resolves to a blocked address (cloud metadata endpoint, link-local, or private IP range). This is an SSRF defense."),
        .deny_allowlist => return allocator.dupe(u8, "http_request failed: host is not in the managed-config egress allowlist."),
        .deny_denylist => return allocator.dupe(u8, "http_request failed: host is on the managed-config egress deny list."),
    }

    const status_marker = "\n__ZCODE_TOOL_HTTP_STATUS__:";

    const timeout = try std.fmt.allocPrint(allocator, "{d}", .{@min(@max(@as(usize, 1), timeout_seconds), 300)});
    defer allocator.free(timeout);

    // Parse user headers into a flat list so we can pass them to the shared
    // curl-config-file builder. The whole reason we route through a config
    // file (and never through argv) is so LLM-supplied Authorization /
    // X-API-Key headers and request bodies don't leak to other same-UID
    // processes via `ps auxww` / /proc. Matches the fix in providers/common.zig.
    var owned_headers = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (owned_headers.items) |header| allocator.free(header);
        owned_headers.deinit();
    }
    if (headers) |header_line| {
        try parseHeadersInto(allocator, &owned_headers, header_line);
    }

    var header_slices = try allocator.alloc([]const u8, owned_headers.items.len);
    defer allocator.free(header_slices);
    for (owned_headers.items, 0..) |h, i| header_slices[i] = h;

    // Treat GET/HEAD/OPTIONS as bodyless (http_common.HttpMethod.GET), every
    // other verb (POST/PUT/PATCH/DELETE/...) gets auto-Content-Type and the
    // empty-body tempfile if no body was given. This matches curl's own
    // defaults for non-GET verbs.
    const is_readlike = std.ascii.eqlIgnoreCase(method, "GET") or
        std.ascii.eqlIgnoreCase(method, "HEAD") or
        std.ascii.eqlIgnoreCase(method, "OPTIONS");
    const curl_method: http_common.HttpMethod = if (is_readlike) .GET else .POST;
    const secrets = try http_common.writeCurlRequestFiles(
        allocator,
        method,
        url,
        header_slices,
        body,
        curl_method,
    );
    defer secrets.cleanup(allocator);

    const argv = [_][]const u8{
        "curl",
        "-sS",
        "-L",
        // egress.checkUrl above already validated the initial scheme
        // (https:// for any host, or http:// for loopback only). Pin
        // redirect targets to https so a 3xx into file:// / gopher://
        // / dict:// or a plaintext exfiltration host is refused at
        // the curl layer too.
        "--proto-redir",
        "=https",
        "--max-time",
        timeout,
        "--write-out",
        status_marker ++ "%{http_code}",
        "-K",
        secrets.config_path,
    };

    const collect_cap = @max(@as(usize, 1024), max_bytes + status_marker.len + 8);
    const result = std.process.run(allocator, rt.io, .{
        .argv = &argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(collect_cap),
        .stderr_limit = .limited(collect_cap),
    }) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, "http_request unavailable: curl is not installed"),
        else => return std.fmt.allocPrint(allocator, "http_request failed: {s}", .{@errorName(err)}),
    };
    const stdout_items = result.stdout;
    defer allocator.free(stdout_items);
    const stderr_items = result.stderr;
    defer allocator.free(stderr_items);
    const term = result.term;

    if (http_common.isCancelRequested()) {
        return allocator.dupe(u8, "http_request cancelled by user");
    }

    if (term == .exited and term.exited == 0) {
        const parsed = parseCurlResponseWithStatus(stdout_items, status_marker) orelse {
            return allocator.dupe(u8, "http_request failed: malformed curl response");
        };

        if (parsed.status_code >= 400) {
            const clipped_body = parsed.body[0..@min(parsed.body.len, max_bytes)];
            return std.fmt.allocPrint(
                allocator,
                "http_request failed (status={d}): {s}",
                .{ parsed.status_code, clipped_body },
            );
        }

        const take_len = @min(parsed.body.len, max_bytes);
        return allocator.dupe(u8, parsed.body[0..take_len]);
    }

    const exit_code: u32 = if (term == .exited) term.exited else 0;
    return std.fmt.allocPrint(allocator, "http_request failed (curl exit={d}): {s}", .{ exit_code, stderr_items });
}

fn parseHeadersInto(
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed([]u8),
    raw_headers: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, raw_headers, " \t\r\n");
    if (trimmed.len == 0) return;

    if (trimmed[0] == '{') {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch null;
        defer if (parsed) |*value| value.deinit();

        if (parsed) |value| {
            if (value.value == .object) {
                var it = value.value.object.iterator();
                while (it.next()) |entry| {
                    const header_value = switch (entry.value_ptr.*) {
                        .string => |v| v,
                        .integer => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
                        .bool => |v| if (v) "true" else "false",
                        else => continue,
                    };
                    defer if (entry.value_ptr.* == .integer) allocator.free(header_value);

                    const header = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ entry.key_ptr.*, header_value });
                    try out.append(header);
                }
                return;
            }
        }
    }

    var it = std.mem.tokenizeAny(u8, trimmed, "|\r\n");
    while (it.next()) |header| {
        const line = std.mem.trim(u8, header, " \t");
        if (line.len == 0) continue;
        const duped = try allocator.dupe(u8, line);
        out.append(duped) catch |err| {
            allocator.free(duped);
            return err;
        };
    }
}

const CurlResponseWithStatus = struct {
    body: []const u8,
    status_code: u16,
};

fn parseCurlResponseWithStatus(raw: []const u8, marker: []const u8) ?CurlResponseWithStatus {
    const marker_idx = std.mem.lastIndexOf(u8, raw, marker) orelse return null;
    const status_slice = std.mem.trim(u8, raw[marker_idx + marker.len ..], " \t\r\n");
    if (status_slice.len == 0) return null;

    const status_code = std.fmt.parseInt(u16, status_slice, 10) catch return null;
    return .{
        .body = raw[0..marker_idx],
        .status_code = status_code,
    };
}

const testing = std.testing;

test "parseCurlResponseWithStatus splits body and code" {
    const parsed = parseCurlResponseWithStatus(
        "{\"ok\":true}\n__ZCODE_TOOL_HTTP_STATUS__:200",
        "\n__ZCODE_TOOL_HTTP_STATUS__:",
    ) orelse return error.TestUnexpectedResult;

    try testing.expectEqual(@as(u16, 200), parsed.status_code);
    try testing.expectEqualStrings("{\"ok\":true}", parsed.body);
}

test "parseHeadersInto supports json objects" {
    var owned_headers = std.array_list.Managed([]u8).init(testing.allocator);
    defer {
        for (owned_headers.items) |header| testing.allocator.free(header);
        owned_headers.deinit();
    }

    try parseHeadersInto(
        testing.allocator,
        &owned_headers,
        "{\"Authorization\":\"Bearer token\",\"X-Retry\":3}",
    );

    try testing.expectEqual(@as(usize, 2), owned_headers.items.len);
    try testing.expectEqualStrings("Authorization: Bearer token", owned_headers.items[0]);
    try testing.expectEqualStrings("X-Retry: 3", owned_headers.items[1]);
}

test "parseHeadersInto supports newline separated values" {
    var owned_headers = std.array_list.Managed([]u8).init(testing.allocator);
    defer {
        for (owned_headers.items) |header| testing.allocator.free(header);
        owned_headers.deinit();
    }

    try parseHeadersInto(
        testing.allocator,
        &owned_headers,
        "Authorization: Bearer token\nX-Test: yes",
    );

    try testing.expectEqual(@as(usize, 2), owned_headers.items.len);
    try testing.expectEqualStrings("Authorization: Bearer token", owned_headers.items[0]);
    try testing.expectEqualStrings("X-Test: yes", owned_headers.items[1]);
}
