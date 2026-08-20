const std = @import("std");
const std_io = @import("std_io.zig");
const xdg = @import("xdg.zig");

/// Per-project cache directory layout. Ported in spirit from
/// claude-code-main/src/utils/cachePaths.ts. The reference nests
/// everything under `<XDG_CACHE>/claude-cli/<sanitized-cwd>/...`
/// so log files, mcp output captures, and error dumps stay
/// separated per-project instead of blending across workspaces.
///
/// zcode's version uses `core/xdg.getZcodeCacheDir` as the root
/// (`<XDG_CACHE_HOME>/zcode`) and mirrors the three subdirectory
/// types the reference uses today:
///
///   <zcode-cache>/<sanitized-cwd>/errors     -- crash logs, stack dumps
///   <zcode-cache>/<sanitized-cwd>/messages   -- message archive / replay
///   <zcode-cache>/<sanitized-cwd>/mcp-logs-<server>  -- per-server MCP stdio captures
///
/// Sanitization strips every non-alphanumeric character to `-`
/// so a cwd like `/Users/example/Documents/zig-code` becomes
/// `-Users-Toto-Documents-zig-code`. If the sanitized form is
/// longer than MAX_SANITIZED_LENGTH we truncate and append a
/// stable hash suffix so two different long paths don't collide.
pub const MAX_SANITIZED_LENGTH: usize = 200;

/// Replace every non-alphanumeric byte with `-`. Long names get
/// a Wyhash suffix so two cwds that differ only after the cap
/// still map to distinct directories. Caller owns the returned
/// slice.
///
/// Example:
///   "/Users/example/Documents/zig-code" -> "-Users-Toto-Documents-zig-code"
///
/// Stable across runs: Wyhash with seed 0 is deterministic, so
/// the same input always produces the same output and upgrades
/// don't orphan existing cache data.
pub fn sanitizePath(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    // First pass: build the naive sanitized form.
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    try out.ensureTotalCapacity(name.len);
    for (name) |c| {
        if (isAlphanumeric(c)) {
            try out.append(c);
        } else {
            try out.append('-');
        }
    }

    if (out.items().len <= MAX_SANITIZED_LENGTH) {
        return out.toOwnedSlice();
    }

    // Overflow: truncate and append a stable hash of the ORIGINAL
    // name. The hash distinguishes two long paths whose prefix
    // happens to match after sanitization.
    const hash = std.hash.Wyhash.hash(0, name);
    var suffix_buf: [24]u8 = undefined;
    const suffix = std.fmt.bufPrint(&suffix_buf, "-{x}", .{hash}) catch "";

    // Budget = MAX_SANITIZED_LENGTH minus suffix length, so the
    // combined result fits inside the cap.
    const budget = if (MAX_SANITIZED_LENGTH > suffix.len)
        MAX_SANITIZED_LENGTH - suffix.len
    else
        0;

    var truncated = std_io.StringBuilder.init(allocator);
    errdefer truncated.deinit();
    try truncated.ensureTotalCapacity(MAX_SANITIZED_LENGTH);
    const take = @min(out.items().len, budget);
    try truncated.appendSlice(out.items()[0..take]);
    try truncated.appendSlice(suffix);

    out.deinit();
    return truncated.toOwnedSlice();
}

/// `<XDG_CACHE>/zcode/<sanitized-cwd>` -- the root for every
/// per-project cache file zcode writes. Caller owns the returned
/// slice.
pub fn baseLogsDir(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const cache_root = try xdg.getZcodeCacheDir(allocator);
    defer allocator.free(cache_root);

    const sanitized = try sanitizePath(allocator, cwd);
    defer allocator.free(sanitized);

    return std.fs.path.join(allocator, &.{ cache_root, sanitized });
}

/// `<baseLogsDir>/errors` -- crash reports, panic dumps, stack traces.
pub fn errorsDir(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const base = try baseLogsDir(allocator, cwd);
    defer allocator.free(base);
    return std.fs.path.join(allocator, &.{ base, "errors" });
}

/// `<baseLogsDir>/messages` -- conversation replay / export dumps.
pub fn messagesDir(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const base = try baseLogsDir(allocator, cwd);
    defer allocator.free(base);
    return std.fs.path.join(allocator, &.{ base, "messages" });
}

/// `<baseLogsDir>/mcp-logs-<sanitized-server>` -- per-server MCP
/// stdio captures. Reference sanitizes the server name because
/// Windows drive-letter colons (`:`) are invalid path characters
/// and some servers embed URLs / hosts in their names.
pub fn mcpLogsDir(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    server_name: []const u8,
) ![]u8 {
    const base = try baseLogsDir(allocator, cwd);
    defer allocator.free(base);

    const safe_server = try sanitizePath(allocator, server_name);
    defer allocator.free(safe_server);

    const subdir = try std.fmt.allocPrint(allocator, "mcp-logs-{s}", .{safe_server});
    defer allocator.free(subdir);

    return std.fs.path.join(allocator, &.{ base, subdir });
}

fn isAlphanumeric(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9');
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "sanitizePath strips non-alphanumeric characters" {
    const alloc = testing.allocator;
    const out = try sanitizePath(alloc, "/Users/example/Documents/zig-code");
    defer alloc.free(out);
    try testing.expectEqualStrings("-Users-example-Documents-zig-code", out);
}

test "sanitizePath preserves alphanumeric content" {
    const alloc = testing.allocator;
    const out = try sanitizePath(alloc, "plain123identifier");
    defer alloc.free(out);
    try testing.expectEqualStrings("plain123identifier", out);
}

test "sanitizePath collapses dots and spaces to dashes" {
    const alloc = testing.allocator;
    const out = try sanitizePath(alloc, "foo.bar baz");
    defer alloc.free(out);
    try testing.expectEqualStrings("foo-bar-baz", out);
}

test "sanitizePath handles Windows-style drive colons" {
    const alloc = testing.allocator;
    const out = try sanitizePath(alloc, "C:\\Users\\Toto");
    defer alloc.free(out);
    try testing.expectEqualStrings("C--Users-Toto", out);
}

test "sanitizePath truncates long names with stable hash suffix" {
    const alloc = testing.allocator;
    // 250 'a' characters -- well over the 200 cap
    const long_name = "a" ** 250;
    const out = try sanitizePath(alloc, long_name);
    defer alloc.free(out);

    try testing.expect(out.len <= MAX_SANITIZED_LENGTH);
    try testing.expect(out.len > 180); // most of the budget used
    // Must contain a hash suffix starting with '-'
    try testing.expect(std.mem.indexOf(u8, out, "-") != null);

    // Same input -> same output (stability across runs).
    const out2 = try sanitizePath(alloc, long_name);
    defer alloc.free(out2);
    try testing.expectEqualStrings(out, out2);
}

test "sanitizePath distinguishes long paths with different suffixes" {
    const alloc = testing.allocator;
    // Same 200-char prefix, different trailing bytes -- naive
    // truncate-only would collide, the hash suffix must separate them.
    const prefix = "a" ** 200;
    const a = prefix ++ "-alpha";
    const b = prefix ++ "-beta";

    const out_a = try sanitizePath(alloc, a);
    defer alloc.free(out_a);
    const out_b = try sanitizePath(alloc, b);
    defer alloc.free(out_b);

    try testing.expect(!std.mem.eql(u8, out_a, out_b));
}

test "baseLogsDir joins XDG cache root with sanitized cwd" {
    if (@import("builtin").os.tag == .windows) return;
    const alloc = testing.allocator;
    const out = try baseLogsDir(alloc, "/tmp/zcode-test-project");
    defer alloc.free(out);

    try testing.expect(std.fs.path.isAbsolute(out));
    try testing.expect(std.mem.indexOf(u8, out, "zcode") != null);
    try testing.expect(std.mem.indexOf(u8, out, "-tmp-zcode-test-project") != null);
}

test "errorsDir is a subdirectory of baseLogsDir" {
    if (@import("builtin").os.tag == .windows) return;
    const alloc = testing.allocator;
    const base = try baseLogsDir(alloc, "/tmp/zcode-test-project");
    defer alloc.free(base);
    const errors = try errorsDir(alloc, "/tmp/zcode-test-project");
    defer alloc.free(errors);

    try testing.expect(std.mem.startsWith(u8, errors, base));
    try testing.expect(std.mem.endsWith(u8, errors, "/errors"));
}

test "messagesDir is a subdirectory of baseLogsDir" {
    if (@import("builtin").os.tag == .windows) return;
    const alloc = testing.allocator;
    const base = try baseLogsDir(alloc, "/tmp/zcode-test-project");
    defer alloc.free(base);
    const messages = try messagesDir(alloc, "/tmp/zcode-test-project");
    defer alloc.free(messages);

    try testing.expect(std.mem.startsWith(u8, messages, base));
    try testing.expect(std.mem.endsWith(u8, messages, "/messages"));
}

test "mcpLogsDir sanitizes the server name" {
    if (@import("builtin").os.tag == .windows) return;
    const alloc = testing.allocator;
    const out = try mcpLogsDir(alloc, "/tmp/zcode-test-project", "my.server:8080");
    defer alloc.free(out);
    // Both non-alnum chars get flattened to dashes, then prefixed by "mcp-logs-"
    try testing.expect(std.mem.indexOf(u8, out, "mcp-logs-my-server-8080") != null);
}

test "mcpLogsDir for a plain server name keeps it intact" {
    if (@import("builtin").os.tag == .windows) return;
    const alloc = testing.allocator;
    const out = try mcpLogsDir(alloc, "/tmp/zcode-test-project", "filesystem");
    defer alloc.free(out);
    try testing.expect(std.mem.endsWith(u8, out, "/mcp-logs-filesystem"));
}
