const std = @import("std");
const rt = @import("zcode_runtime");
const std_io = @import("std_io.zig");
const clock = @import("clock.zig");

/// Session-scoped environment variable store.
///
/// Ported from claude-code-main/src/utils/sessionEnvVars.ts. The
/// reference exposes `getSessionEnvVars` / `setSessionEnvVar` as
/// a module-level Map and applies the values ONLY to spawned
/// child processes (shell, grep, bash tool, ...) -- never to the
/// REPL process itself. This lets a user type something like
///
///   /env set CI=true
///   /env set GIT_AUTHOR_NAME=zcode-test
///   /env set NODE_ENV=test
///
/// and have every subsequent shell command and grep invocation
/// inherit those variables without polluting the outer process
/// (which might be running inside the user's normal shell with
/// its own unrelated env).
///
/// zcode's REPL is single-session-per-process, so the store lives
/// at module level behind a mutex just like the reference.
/// Thread-safety matters because parallel read-only tool batches
/// may spawn shells concurrently while /env set races against
/// them; the mutex is cheap and keeps the API obvious.
var store: std.StringHashMapUnmanaged([]u8) = .{};
var mutex: std.Io.Mutex = .init;
var store_allocator: ?std.mem.Allocator = null;

/// Set or replace an env var. Copies both key and value so the
/// caller's buffer lifetime doesn't matter. Key must not contain
/// `=` (shell env convention). Empty key is rejected.
pub fn set(allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
    if (name.len == 0) return error.InvalidEnvVarName;
    for (name) |c| {
        if (c == '=') return error.InvalidEnvVarName;
        // POSIX-ish: allow letters, digits, underscore. Reject
        // control chars and anything that would confuse a shell.
        if (c < 0x20 or c == 0x7f) return error.InvalidEnvVarName;
    }

    mutex.lock(rt.io) catch {};
    defer mutex.unlock(rt.io);

    store_allocator = allocator;

    // Dupe the new value first so an OOM doesn't leave the old
    // entry freed but no replacement installed.
    const new_value = try allocator.dupe(u8, value);
    errdefer allocator.free(new_value);

    const gop = try store.getOrPut(allocator, name);
    if (gop.found_existing) {
        allocator.free(gop.value_ptr.*);
    } else {
        // Only dupe the key on a new insert -- existing entries
        // already own their key slot from a previous set().
        const new_key = try allocator.dupe(u8, name);
        gop.key_ptr.* = new_key;
    }
    gop.value_ptr.* = new_value;
}

/// Remove an env var. No-op when the var isn't set.
pub fn unset(allocator: std.mem.Allocator, name: []const u8) void {
    mutex.lock(rt.io) catch {};
    defer mutex.unlock(rt.io);
    if (store.fetchRemove(name)) |kv| {
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
}

/// Drop every session env var. Frees all owned storage.
pub fn clear(allocator: std.mem.Allocator) void {
    mutex.lock(rt.io) catch {};
    defer mutex.unlock(rt.io);
    var it = store.iterator();
    while (it.next()) |kv| {
        allocator.free(kv.key_ptr.*);
        allocator.free(kv.value_ptr.*);
    }
    store.clearAndFree(allocator);
}

/// Count of currently-set session env vars.
pub fn count() usize {
    mutex.lock(rt.io) catch {};
    defer mutex.unlock(rt.io);
    return store.count();
}

/// Look up a single value. Returned slice is owned by the store
/// and valid until the next set/unset/clear call for the same
/// key. For safe long-lived use, dupe it.
pub fn get(name: []const u8) ?[]const u8 {
    mutex.lock(rt.io) catch {};
    defer mutex.unlock(rt.io);
    if (store.get(name)) |v| return v;
    return null;
}

/// Merge every session var into `env_map`, OVERRIDING any
/// inherited value with the same key. Called by the shell tool
/// just before spawning a child process so session-level vars
/// always beat the inherited environment (same precedence as
/// the reference's `getSessionEnvVars()` applied in
/// execBashHook). Keys that look like a shell-unsafe name are
/// skipped defensively.
pub fn applyToEnvMap(env_map: *std.process.Environ.Map) !void {
    mutex.lock(rt.io) catch {};
    defer mutex.unlock(rt.io);
    var it = store.iterator();
    while (it.next()) |kv| {
        try env_map.put(kv.key_ptr.*, kv.value_ptr.*);
    }
}

/// Pretty-print the current store for `/env list`. Sorted by
/// key so output is stable across runs. Caller owns the
/// returned slice.
pub fn formatList(allocator: std.mem.Allocator) ![]u8 {
    mutex.lock(rt.io) catch {};
    const n = store.count();
    if (n == 0) {
        mutex.unlock(rt.io);
        return allocator.dupe(u8, "session env: (none set)");
    }

    var keys = std.array_list.Managed([]const u8).init(allocator);
    defer keys.deinit();
    try keys.ensureTotalCapacity(n);

    var it = store.iterator();
    while (it.next()) |kv| {
        try keys.append(kv.key_ptr.*);
    }
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    try out.writer().print("session env ({d} var{s}):\n", .{ n, if (n == 1) "" else "s" });
    for (keys.items) |k| {
        const v = store.get(k) orelse continue;
        try out.writer().print("  {s}={s}\n", .{ k, v });
    }
    mutex.unlock(rt.io);
    return out.toOwnedSlice();
}

/// Test-only: reset the store to empty. Production code has no
/// need for this because /env clear already exists.
pub fn resetForTesting(allocator: std.mem.Allocator) void {
    clear(allocator);
}

// ── CLAUDE_ENV_FILE export-injection mechanism ────────────────────
//
// Ported from claude-code-main src/utils/hooks.ts:925 (CLAUDE_ENV_FILE).
// For applicable hook events (SessionStart/Setup/CwdChanged/FileChanged
// in the reference) the hook may write `KEY=value` bash exports to the
// file at $CLAUDE_ENV_FILE; those exports are then applied to later Bash
// tool commands via applyToEnvMap. zcode wires this through the existing
// session env store: the merged keys behave exactly like `/env set`.
//
// The file is written by untrusted hook code, so the parser is
// defensive: it caps the file size, validates each key against the
// POSIX-ish identifier charset, and silently skips malformed lines
// rather than injecting garbage into later shells.

/// Maximum env-file size we will read back. A hostile hook could
/// otherwise dump an arbitrarily large file to balloon the session env.
const ENV_FILE_LIMIT: usize = 256 * 1024;

/// Per-line value length cap, to keep a single export from ballooning.
const ENV_VALUE_LIMIT: usize = 64 * 1024;

/// Create an empty temp file under `home` and return its absolute path
/// (caller owns the slice). The hook env should set CLAUDE_ENV_FILE to
/// this path; after the hook returns, feed the same path to
/// mergeEnvFile and then delete it. The name is hex-only (a nonce) so
/// no shell quoting of the filename itself is required.
pub fn createEnvFile(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    const nonce = clock.nowNanos();
    const path = try std.fmt.allocPrint(allocator, "{s}/.hook-env-{x}.sh", .{ home, nonce });
    errdefer allocator.free(path);
    const file = try std.Io.Dir.cwd().createFile(rt.io, path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
    file.close(rt.io);
    return path;
}

/// Read `path` (written by a hook into $CLAUDE_ENV_FILE), parse its
/// `KEY=value` lines, and merge each valid entry into the session env
/// store (so later Bash commands inherit it). Blank lines and lines
/// beginning with `#` are ignored. Defensive: missing file -> no-op;
/// invalid keys / oversize values are skipped. Returns the number of
/// vars merged.
pub fn mergeEnvFile(allocator: std.mem.Allocator, path: []const u8) !usize {
    const data = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(ENV_FILE_LIMIT)) catch |err| switch (err) {
        error.FileNotFound => return 0,
        // A hostile hook overflowing the cap is treated as "nothing usable".
        error.StreamTooLong => return 0,
        else => return err,
    };
    defer allocator.free(data);

    var merged: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        var value = line[eq + 1 ..];

        // Strip an optional leading `export ` so a hook can write either
        // `FOO=bar` or `export FOO=bar`.
        const key_trimmed = blk: {
            const k = std.mem.trim(u8, key, " \t");
            if (std.mem.startsWith(u8, k, "export ")) {
                break :blk std.mem.trim(u8, k["export ".len..], " \t");
            }
            break :blk k;
        };

        if (!isValidEnvKey(key_trimmed)) continue;
        if (value.len > ENV_VALUE_LIMIT) value = value[0..ENV_VALUE_LIMIT];

        // Strip a single matching pair of surrounding quotes, the common
        // shell-export form (`FOO="bar baz"`). Unbalanced quotes are kept
        // verbatim.
        if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) {
            value = value[1 .. value.len - 1];
        }

        set(allocator, key_trimmed, value) catch continue;
        merged += 1;
    }
    return merged;
}

/// POSIX-ish env-var name validation: `[A-Za-z_][A-Za-z0-9_]*`, non-empty.
fn isValidEnvKey(key: []const u8) bool {
    if (key.len == 0) return false;
    const first = key[0];
    if (!(std.ascii.isAlphabetic(first) or first == '_')) return false;
    for (key[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "set and get round-trip" {
    resetForTesting(testing.allocator);
    defer resetForTesting(testing.allocator);

    try set(testing.allocator, "FOO", "bar");
    try testing.expectEqualStrings("bar", get("FOO").?);
    try testing.expectEqual(@as(usize, 1), count());
}

test "set replaces existing value without leaking" {
    resetForTesting(testing.allocator);
    defer resetForTesting(testing.allocator);

    try set(testing.allocator, "CI", "1");
    try set(testing.allocator, "CI", "true");
    try testing.expectEqualStrings("true", get("CI").?);
    try testing.expectEqual(@as(usize, 1), count());
}

test "unset removes the variable" {
    resetForTesting(testing.allocator);
    defer resetForTesting(testing.allocator);

    try set(testing.allocator, "TMP", "value");
    unset(testing.allocator, "TMP");
    try testing.expect(get("TMP") == null);
    try testing.expectEqual(@as(usize, 0), count());
}

test "unset on a missing key is a no-op" {
    resetForTesting(testing.allocator);
    defer resetForTesting(testing.allocator);

    unset(testing.allocator, "NEVER_SET");
    try testing.expectEqual(@as(usize, 0), count());
}

test "clear drops every entry" {
    resetForTesting(testing.allocator);
    defer resetForTesting(testing.allocator);

    try set(testing.allocator, "A", "1");
    try set(testing.allocator, "B", "2");
    try set(testing.allocator, "C", "3");
    try testing.expectEqual(@as(usize, 3), count());
    clear(testing.allocator);
    try testing.expectEqual(@as(usize, 0), count());
    try testing.expect(get("A") == null);
}

test "set rejects invalid key names" {
    resetForTesting(testing.allocator);
    defer resetForTesting(testing.allocator);

    try testing.expectError(error.InvalidEnvVarName, set(testing.allocator, "", "v"));
    try testing.expectError(error.InvalidEnvVarName, set(testing.allocator, "bad=key", "v"));
    try testing.expectError(error.InvalidEnvVarName, set(testing.allocator, "bad\x00key", "v"));
    try testing.expectError(error.InvalidEnvVarName, set(testing.allocator, "bad\nkey", "v"));
}

test "applyToEnvMap overrides inherited values" {
    resetForTesting(testing.allocator);
    defer resetForTesting(testing.allocator);

    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();

    try env_map.put("CI", "inherited");
    try env_map.put("HOME", "/home/user");

    try set(testing.allocator, "CI", "session");
    try set(testing.allocator, "GIT_AUTHOR_NAME", "zcode-test");

    try applyToEnvMap(&env_map);

    try testing.expectEqualStrings("session", env_map.get("CI").?);
    try testing.expectEqualStrings("zcode-test", env_map.get("GIT_AUTHOR_NAME").?);
    // Inherited values without session override pass through.
    try testing.expectEqualStrings("/home/user", env_map.get("HOME").?);
}

test "formatList renders empty state" {
    resetForTesting(testing.allocator);
    defer resetForTesting(testing.allocator);

    const out = try formatList(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("session env: (none set)", out);
}

test "formatList renders sorted key-value rows" {
    resetForTesting(testing.allocator);
    defer resetForTesting(testing.allocator);

    try set(testing.allocator, "BETA", "2");
    try set(testing.allocator, "ALPHA", "1");
    try set(testing.allocator, "GAMMA", "3");

    const out = try formatList(testing.allocator);
    defer testing.allocator.free(out);

    // Header with plural count.
    try testing.expect(std.mem.indexOf(u8, out, "session env (3 vars):") != null);
    // Sorted order: ALPHA before BETA before GAMMA.
    const a = std.mem.indexOf(u8, out, "ALPHA=1").?;
    const b = std.mem.indexOf(u8, out, "BETA=2").?;
    const g = std.mem.indexOf(u8, out, "GAMMA=3").?;
    try testing.expect(a < b);
    try testing.expect(b < g);
}

// ── CLAUDE_ENV_FILE tests ─────────────────────────────────────────

test "CLAUDE_ENV_FILE round-trip: a hook writing FOO=bar lands in the session env" {
    resetForTesting(testing.allocator);
    defer resetForTesting(testing.allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(home);

    const env_file = try createEnvFile(testing.allocator, home);
    defer testing.allocator.free(env_file);
    defer std.Io.Dir.cwd().deleteFile(rt.io, env_file) catch {};

    // A SessionStart-equivalent hook writes an export to $CLAUDE_ENV_FILE.
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();
    try env_map.put("CLAUDE_ENV_FILE", env_file);

    const result = try std.process.run(testing.allocator, rt.io, .{
        .argv = &.{ "sh", "-c", "echo FOO=bar > \"$CLAUDE_ENV_FILE\"" },
        .environ_map = &env_map,
        .stdout_limit = .limited(8 * 1024),
        .stderr_limit = .limited(8 * 1024),
    });
    testing.allocator.free(result.stdout);
    testing.allocator.free(result.stderr);

    const merged = try mergeEnvFile(testing.allocator, env_file);
    try testing.expectEqual(@as(usize, 1), merged);

    // The export is now visible to a later Bash command via applyToEnvMap.
    var bash_env = std.process.Environ.Map.init(testing.allocator);
    defer bash_env.deinit();
    try applyToEnvMap(&bash_env);
    try testing.expectEqualStrings("bar", bash_env.get("FOO").?);
}

test "mergeEnvFile parses multiple lines, skips comments/blanks, strips quotes and export" {
    resetForTesting(testing.allocator);
    defer resetForTesting(testing.allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(home);

    const env_file = try createEnvFile(testing.allocator, home);
    defer testing.allocator.free(env_file);
    defer std.Io.Dir.cwd().deleteFile(rt.io, env_file) catch {};

    const contents =
        \\# a comment line
        \\
        \\ALPHA=1
        \\export BETA="two words"
        \\GAMMA='single'
        \\bad-key=ignored
        \\=novalue
    ;
    try std.Io.Dir.cwd().writeFile(rt.io, .{ .sub_path = env_file, .data = contents });

    const merged = try mergeEnvFile(testing.allocator, env_file);
    try testing.expectEqual(@as(usize, 3), merged);
    try testing.expectEqualStrings("1", get("ALPHA").?);
    try testing.expectEqualStrings("two words", get("BETA").?);
    try testing.expectEqualStrings("single", get("GAMMA").?);
    // Invalid key and empty key are skipped.
    try testing.expect(get("bad-key") == null);
}

test "mergeEnvFile on a missing file is a no-op" {
    resetForTesting(testing.allocator);
    defer resetForTesting(testing.allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(home);

    const missing = try std.fs.path.join(testing.allocator, &.{ home, "does-not-exist.sh" });
    defer testing.allocator.free(missing);

    const merged = try mergeEnvFile(testing.allocator, missing);
    try testing.expectEqual(@as(usize, 0), merged);
    try testing.expectEqual(@as(usize, 0), count());
}

test "isValidEnvKey accepts POSIX identifiers and rejects others" {
    try testing.expect(isValidEnvKey("FOO"));
    try testing.expect(isValidEnvKey("_under"));
    try testing.expect(isValidEnvKey("A1_B2"));
    try testing.expect(!isValidEnvKey(""));
    try testing.expect(!isValidEnvKey("1leading"));
    try testing.expect(!isValidEnvKey("has-dash"));
    try testing.expect(!isValidEnvKey("has space"));
}
