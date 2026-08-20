//! Static headers + dynamic `headersHelper` for remote MCP transports (mcp-04).
//!
//! A remote server config can carry a static `headers` map and an optional
//! `headersHelper` script. This module runs the helper (10s timeout, with
//! `CLAUDE_CODE_MCP_SERVER_NAME` / `_URL` in the child env, mirrored with
//! zcode-prefixed twins), validates that it returns a `string -> string` JSON
//! object, merges the dynamic headers over the static ones (dynamic wins), and
//! gates project/local helper execution behind a trust check.
//!
//! Mirrors the reference behavior described in the phase plan:
//!   - `headersHelper.ts:32-117` `getMcpHeadersFromHelper`: trust check for
//!     project/local scope unless non-interactive; run the helper with
//!     `shell: true`, `timeout: 10000`, and the server-context env vars;
//!     require exit 0 + non-empty stdout; parse JSON; require a top-level
//!     object whose values are all strings; on any error return null (do NOT
//!     block the connection).
//!   - `headersHelper.ts:125-138` `getMcpServerHeaders`: `{ ...static, ...dynamic }`.
//!
//! Key invariant: a helper failure (bad exit, malformed JSON, array/non-string
//! value, timeout, spawn error) NEVER aborts the connection. The function
//! falls back to the static headers in every failure path.

const std = @import("std");
const rt = @import("zcode_runtime");
const env = @import("../core/env.zig");
const mcp_config = @import("../core/mcp_config.zig");

const HeaderEntry = mcp_config.HeaderEntry;
const ServerConfig = mcp_config.ServerConfig;
const ConfigScope = mcp_config.ConfigScope;

/// Wall-clock bound on the helper child. Mirrors the reference's
/// `timeout: 10000`. A hung helper must not stall the MCP connect.
pub const HELPER_TIMEOUT_MS: u64 = 10_000;

/// Cap on the helper's stdout. A pathological helper that prints unbounded
/// output must not exhaust memory; we cap and treat overflow as a failure
/// (fall back to static).
const HELPER_STDOUT_LIMIT: usize = 1 * 1024 * 1024;

/// Test-injectable trust predicate: given a server name, returns true when the
/// workspace trust dialog has been accepted (so a project/local helper may
/// run). The default predicate denies trust, matching the safe default where a
/// project-supplied helper is not executed until trust is granted.
pub const TrustPredicate = *const fn (server_name: []const u8) bool;

fn defaultTrustDenied(server_name: []const u8) bool {
    _ = server_name;
    return false;
}

pub const Options = struct {
    /// Whether the session is interactive. The trust gate only applies in
    /// interactive mode; non-interactive (CI/automation) runs skip it,
    /// matching the reference's carve-out.
    interactive: bool = true,
    /// Trust signal. Consulted only for project/local-scope helpers in
    /// interactive mode. Defaults to "not accepted".
    trust_accepted: TrustPredicate = defaultTrustDenied,
};

/// Resolve the combined headers for a remote server: static `headers` overlaid
/// by the dynamic headers produced by `headers_helper` (dynamic wins on key
/// collision). The returned slice is freshly allocated and owned by the caller;
/// free each entry's key/value and the slice itself (or via
/// `freeHeaderEntries`).
///
/// When `headers_helper == null`, this returns a dup of the static headers.
/// When the helper is present but its execution is gated off (trust) or fails
/// in any way, this returns a dup of the static headers (never an error tied to
/// the helper).
pub fn getMcpServerHeaders(
    allocator: std.mem.Allocator,
    cfg: *const ServerConfig,
    opts: Options,
) ![]HeaderEntry {
    const helper = cfg.headers_helper orelse return dupHeaderEntries(allocator, cfg.headers);

    // Trust gate: a project/local helper is not run in interactive mode unless
    // trust has been accepted. Non-interactive runs skip the gate.
    if (helperGatedOff(cfg.name, cfg.scope, opts)) {
        return dupHeaderEntries(allocator, cfg.headers);
    }

    // Run the helper. Any failure falls back to static-only headers.
    const dynamic = runHelper(allocator, cfg, helper) catch {
        return dupHeaderEntries(allocator, cfg.headers);
    };
    if (dynamic == null) {
        return dupHeaderEntries(allocator, cfg.headers);
    }
    var dyn = dynamic.?;
    defer freeHeaderEntries(allocator, dyn.entries, dyn.len);

    return mergeHeaders(allocator, cfg.headers, dyn.entries[0..dyn.len]);
}

/// True when a helper must NOT be executed for trust reasons: project/local
/// scope, interactive session, and trust not accepted.
fn helperGatedOff(server_name: []const u8, scope: ConfigScope, opts: Options) bool {
    const scoped = switch (scope) {
        .project, .local => true,
        else => false,
    };
    if (!scoped) return false;
    if (!opts.interactive) return false; // non-interactive carve-out
    return !opts.trust_accepted(server_name);
}

/// Merge static headers with dynamic headers (dynamic overrides a same-named
/// static key). Returns a freshly-allocated owned slice.
fn mergeHeaders(
    allocator: std.mem.Allocator,
    static: []const HeaderEntry,
    dynamic: []const HeaderEntry,
) ![]HeaderEntry {
    var list = std.array_list.Managed(HeaderEntry).init(allocator);
    errdefer {
        for (list.items) |*h| {
            allocator.free(h.key);
            allocator.free(h.value);
        }
        list.deinit();
    }

    // Start with the static headers that are NOT overridden by a dynamic key.
    for (static) |s| {
        if (findHeader(dynamic, s.key) != null) continue;
        try appendHeader(allocator, &list, s.key, s.value);
    }
    // Then all dynamic headers (these win on collision).
    for (dynamic) |d| {
        try appendHeader(allocator, &list, d.key, d.value);
    }
    return list.toOwnedSlice();
}

fn appendHeader(
    allocator: std.mem.Allocator,
    list: *std.array_list.Managed(HeaderEntry),
    key: []const u8,
    value: []const u8,
) !void {
    try list.ensureUnusedCapacity(1);
    const k = try allocator.dupe(u8, key);
    errdefer allocator.free(k);
    const v = try allocator.dupe(u8, value);
    list.appendAssumeCapacity(.{ .key = k, .value = v });
}

fn findHeader(headers: []const HeaderEntry, key: []const u8) ?usize {
    for (headers, 0..) |h, i| {
        if (std.ascii.eqlIgnoreCase(h.key, key)) return i;
    }
    return null;
}

fn dupHeaderEntries(allocator: std.mem.Allocator, src: []const HeaderEntry) ![]HeaderEntry {
    if (src.len == 0) return &.{};
    var list = std.array_list.Managed(HeaderEntry).init(allocator);
    errdefer {
        for (list.items) |*h| {
            allocator.free(h.key);
            allocator.free(h.value);
        }
        list.deinit();
    }
    for (src) |s| try appendHeader(allocator, &list, s.key, s.value);
    return list.toOwnedSlice();
}

/// Free an owned `[]HeaderEntry` (key + value of each entry, then the slice).
/// `len` may be less than `entries.len` (used when freeing a partially-filled
/// fixed buffer from the parser).
fn freeHeaderEntries(allocator: std.mem.Allocator, entries: []HeaderEntry, len: usize) void {
    for (entries[0..len]) |*h| {
        allocator.free(h.key);
        allocator.free(h.value);
    }
    allocator.free(entries);
}

/// Public free helper for the slice returned by `getMcpServerHeaders`.
pub fn freeHeaders(allocator: std.mem.Allocator, headers: []HeaderEntry) void {
    for (headers) |*h| {
        allocator.free(h.key);
        allocator.free(h.value);
    }
    if (headers.len > 0) allocator.free(headers);
}

const DynamicHeaders = struct {
    /// Backing array (capacity == number of object keys); only [0..len] are
    /// populated/valid.
    entries: []HeaderEntry,
    len: usize,
};

/// Run the headers helper script and parse its stdout into a header list.
/// Returns null when the helper produced no usable headers (empty object).
/// Returns an error for any failure that should fall back to static-only
/// headers (the caller maps the error to static-only; it never propagates).
fn runHelper(
    allocator: std.mem.Allocator,
    cfg: *const ServerConfig,
    helper: []const u8,
) !?DynamicHeaders {
    var env_map = try env.parentEnvMap(allocator);
    defer env_map.deinit();

    // Server context, both the reference's `CLAUDE_CODE_*` names and the
    // zcode-prefixed twins.
    try env_map.put("CLAUDE_CODE_MCP_SERVER_NAME", cfg.name);
    try env_map.put("ZCODE_MCP_SERVER_NAME", cfg.name);
    if (cfg.url) |url| {
        try env_map.put("CLAUDE_CODE_MCP_SERVER_URL", url);
        try env_map.put("ZCODE_MCP_SERVER_URL", url);
    }

    // The reference runs the helper with `shell: true`, so a `headersHelper`
    // string is a shell command line, not an argv. Mirror with `zsh -lc`.
    // `std.process.Child.init` is gone in 0.16; use the one-shot `run`.
    const result = std.process.run(allocator, rt.io, .{
        .argv = &.{ "zsh", "-lc", helper },
        .environ_map = &env_map,
        .stdout_limit = .limited(HELPER_STDOUT_LIMIT),
        .stderr_limit = .limited(HELPER_STDOUT_LIMIT),
        .timeout = .{ .duration = .{ .raw = .{ .nanoseconds = HELPER_TIMEOUT_MS * std.time.ns_per_ms }, .clock = .awake } },
    }) catch {
        // Timeout / spawn failure / stream-too-long: fall back to static.
        return error.HelperFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Require exit 0.
    const exited_ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!exited_ok) return error.HelperFailed;

    return parseHelperOutput(allocator, result.stdout);
}

/// Parse the helper's stdout as a JSON object whose values are all strings.
/// Any deviation (non-object, array, null, non-string value, empty stdout,
/// invalid JSON) is a failure -> error (caller falls back to static). An empty
/// object is a success with no headers (returns null so the caller keeps the
/// static set unchanged).
fn parseHelperOutput(allocator: std.mem.Allocator, stdout: []const u8) !?DynamicHeaders {
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    if (trimmed.len == 0) return error.HelperFailed;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
        return error.HelperFailed;
    };
    defer parsed.deinit();

    // Must be a top-level object (not an array, string, number, bool, null).
    if (parsed.value != .object) return error.HelperFailed;
    const obj = parsed.value.object;
    if (obj.count() == 0) return null;

    // Every value must be a string.
    var it = obj.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) return error.HelperFailed;
    }

    // Build the owned header list.
    var entries = try allocator.alloc(HeaderEntry, obj.count());
    errdefer allocator.free(entries);
    var len: usize = 0;
    errdefer {
        for (entries[0..len]) |*h| {
            allocator.free(h.key);
            allocator.free(h.value);
        }
    }

    var it2 = obj.iterator();
    while (it2.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key);
        const value = try allocator.dupe(u8, entry.value_ptr.*.string);
        entries[len] = .{ .key = key, .value = value };
        len += 1;
    }

    return .{ .entries = entries, .len = len };
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

fn makeRemoteConfig(
    allocator: std.mem.Allocator,
    scope: ConfigScope,
    url: []const u8,
    helper: ?[]const u8,
    static: []const [2][]const u8,
) !ServerConfig {
    var cfg = ServerConfig{
        .name = try allocator.dupe(u8, "remote"),
        .scope = scope,
        .type = .http,
        .url = try allocator.dupe(u8, url),
    };
    errdefer cfg.deinit(allocator);
    if (helper) |h| cfg.headers_helper = try allocator.dupe(u8, h);
    if (static.len > 0) {
        var hs = try allocator.alloc(HeaderEntry, static.len);
        errdefer allocator.free(hs);
        for (static, 0..) |pair, i| {
            hs[i] = .{
                .key = try allocator.dupe(u8, pair[0]),
                .value = try allocator.dupe(u8, pair[1]),
            };
        }
        cfg.headers = hs;
    }
    return cfg;
}

fn headerValue(headers: []const HeaderEntry, key: []const u8) ?[]const u8 {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.key, key)) return h.value;
    }
    return null;
}

fn trustAlways(name: []const u8) bool {
    _ = name;
    return true;
}

test "getMcpServerHeaders: no helper returns a dup of the static headers" {
    const allocator = testing.allocator;
    var cfg = try makeRemoteConfig(allocator, .user, "https://x.example/mcp", null, &.{
        .{ "X-Static", "s" },
    });
    defer cfg.deinit(allocator);

    const headers = try getMcpServerHeaders(allocator, &cfg, .{});
    defer freeHeaders(allocator, headers);

    try testing.expectEqual(@as(usize, 1), headers.len);
    try testing.expectEqualStrings("s", headerValue(headers, "X-Static").?);
}

test "getMcpServerHeaders: helper output merges over static; helper key overrides static" {
    const allocator = testing.allocator;
    // Helper emits X-Token (new) and X-Static (overrides the static value).
    var cfg = try makeRemoteConfig(
        allocator,
        .user, // user scope is never trust-gated
        "https://x.example/mcp",
        "echo '{\"X-Token\":\"abc\",\"X-Static\":\"from-helper\"}'",
        &.{.{ "X-Static", "s" }},
    );
    defer cfg.deinit(allocator);

    const headers = try getMcpServerHeaders(allocator, &cfg, .{});
    defer freeHeaders(allocator, headers);

    try testing.expectEqualStrings("abc", headerValue(headers, "X-Token").?);
    // dynamic wins over the static "s".
    try testing.expectEqualStrings("from-helper", headerValue(headers, "X-Static").?);
}

test "getMcpServerHeaders: helper returning a JSON array is rejected, static-only" {
    const allocator = testing.allocator;
    var cfg = try makeRemoteConfig(
        allocator,
        .user,
        "https://x.example/mcp",
        "echo '[\"not\",\"an\",\"object\"]'",
        &.{.{ "X-Static", "s" }},
    );
    defer cfg.deinit(allocator);

    const headers = try getMcpServerHeaders(allocator, &cfg, .{});
    defer freeHeaders(allocator, headers);

    // Only the static header survives; no error propagated.
    try testing.expectEqual(@as(usize, 1), headers.len);
    try testing.expectEqualStrings("s", headerValue(headers, "X-Static").?);
}

test "getMcpServerHeaders: helper with a non-string value is rejected, static-only" {
    const allocator = testing.allocator;
    var cfg = try makeRemoteConfig(
        allocator,
        .user,
        "https://x.example/mcp",
        "echo '{\"X-Token\":123}'",
        &.{.{ "X-Static", "s" }},
    );
    defer cfg.deinit(allocator);

    const headers = try getMcpServerHeaders(allocator, &cfg, .{});
    defer freeHeaders(allocator, headers);

    try testing.expectEqual(@as(usize, 1), headers.len);
    try testing.expect(headerValue(headers, "X-Token") == null);
    try testing.expectEqualStrings("s", headerValue(headers, "X-Static").?);
}

test "getMcpServerHeaders: project helper NOT executed when trust not accepted (interactive)" {
    const allocator = testing.allocator;
    var cfg = try makeRemoteConfig(
        allocator,
        .project, // project scope IS trust-gated
        "https://x.example/mcp",
        "echo '{\"X-Token\":\"abc\"}'",
        &.{.{ "X-Static", "s" }},
    );
    defer cfg.deinit(allocator);

    // Interactive + default (denied) trust => helper does not run.
    const headers = try getMcpServerHeaders(allocator, &cfg, .{ .interactive = true });
    defer freeHeaders(allocator, headers);

    try testing.expect(headerValue(headers, "X-Token") == null);
    try testing.expectEqualStrings("s", headerValue(headers, "X-Static").?);
}

test "getMcpServerHeaders: project helper DOES run when trust accepted (interactive)" {
    const allocator = testing.allocator;
    var cfg = try makeRemoteConfig(
        allocator,
        .project,
        "https://x.example/mcp",
        "echo '{\"X-Token\":\"abc\"}'",
        &.{.{ "X-Static", "s" }},
    );
    defer cfg.deinit(allocator);

    const headers = try getMcpServerHeaders(allocator, &cfg, .{
        .interactive = true,
        .trust_accepted = trustAlways,
    });
    defer freeHeaders(allocator, headers);

    try testing.expectEqualStrings("abc", headerValue(headers, "X-Token").?);
}

test "getMcpServerHeaders: project helper runs non-interactively even without trust" {
    const allocator = testing.allocator;
    var cfg = try makeRemoteConfig(
        allocator,
        .project,
        "https://x.example/mcp",
        "echo '{\"X-Token\":\"abc\"}'",
        &.{},
    );
    defer cfg.deinit(allocator);

    // Non-interactive bypasses the trust gate (CI/automation carve-out).
    const headers = try getMcpServerHeaders(allocator, &cfg, .{ .interactive = false });
    defer freeHeaders(allocator, headers);

    try testing.expectEqualStrings("abc", headerValue(headers, "X-Token").?);
}

test "getMcpServerHeaders: non-zero helper exit falls back to static-only" {
    const allocator = testing.allocator;
    var cfg = try makeRemoteConfig(
        allocator,
        .user,
        "https://x.example/mcp",
        "echo 'oops' >&2; exit 7",
        &.{.{ "X-Static", "s" }},
    );
    defer cfg.deinit(allocator);

    const headers = try getMcpServerHeaders(allocator, &cfg, .{});
    defer freeHeaders(allocator, headers);

    try testing.expectEqual(@as(usize, 1), headers.len);
    try testing.expectEqualStrings("s", headerValue(headers, "X-Static").?);
}

test "getMcpServerHeaders: empty-object helper keeps the static set unchanged" {
    const allocator = testing.allocator;
    var cfg = try makeRemoteConfig(
        allocator,
        .user,
        "https://x.example/mcp",
        "echo '{}'",
        &.{.{ "X-Static", "s" }},
    );
    defer cfg.deinit(allocator);

    const headers = try getMcpServerHeaders(allocator, &cfg, .{});
    defer freeHeaders(allocator, headers);

    try testing.expectEqual(@as(usize, 1), headers.len);
    try testing.expectEqualStrings("s", headerValue(headers, "X-Static").?);
}

test "getMcpServerHeaders: helper sees the server-context env vars" {
    const allocator = testing.allocator;
    // The helper echoes the server name back as a header value, proving the
    // CLAUDE_CODE_MCP_SERVER_NAME context var reached the child env.
    var cfg = try makeRemoteConfig(
        allocator,
        .user,
        "https://x.example/mcp",
        "printf '{\"X-Name\":\"%s\"}' \"$CLAUDE_CODE_MCP_SERVER_NAME\"",
        &.{},
    );
    defer cfg.deinit(allocator);

    const headers = try getMcpServerHeaders(allocator, &cfg, .{});
    defer freeHeaders(allocator, headers);

    try testing.expectEqualStrings("remote", headerValue(headers, "X-Name").?);
}

test "mergeHeaders: dynamic overrides static case-insensitively, preserves others" {
    const allocator = testing.allocator;
    const static = [_]HeaderEntry{
        .{ .key = @constCast("X-Static"), .value = @constCast("s") },
        .{ .key = @constCast("Authorization"), .value = @constCast("static-auth") },
    };
    const dynamic = [_]HeaderEntry{
        .{ .key = @constCast("authorization"), .value = @constCast("dyn-auth") },
    };
    const merged = try mergeHeaders(allocator, &static, &dynamic);
    defer freeHeaders(allocator, merged);

    // X-Static survives untouched.
    try testing.expectEqualStrings("s", headerValue(merged, "X-Static").?);
    // Authorization is overridden by the dynamic (case-insensitive) entry.
    try testing.expectEqualStrings("dyn-auth", headerValue(merged, "Authorization").?);
    // No duplicate Authorization entries.
    var count: usize = 0;
    for (merged) |h| {
        if (std.ascii.eqlIgnoreCase(h.key, "authorization")) count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}
