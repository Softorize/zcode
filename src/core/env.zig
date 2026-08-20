const std = @import("std");
const rt = @import("zcode_runtime");

/// In-process environment override map (sdk-headless-13).
///
/// zcode reads the real environment via libc getenv (below), which cannot be
/// mutated portably (no setenv on the hot path; the parent environ block is
/// effectively read-only for our purposes). The SDK control protocol's
/// `update_environment_variables` stdin message needs to refresh values at
/// runtime (the reference use is auth-token refresh, e.g.
/// CLAUDE_CODE_SESSION_ACCESS_TOKEN) so the running process -- not just child
/// subprocesses -- sees the new value. We satisfy that by keeping an in-process
/// override map that every env lookup consults BEFORE falling back to libc
/// getenv. Setting an override shadows the real value for all callers that go
/// through env.getenv / env.getOwned; it never touches the real process
/// environment.
///
/// Mutation happens only on the single-threaded stdin dispatch path, but other
/// threads may read concurrently, so the map is guarded by an Io.Mutex
/// (std.Thread.Mutex does not exist in this std build; see the project wiki).
var override_map: std.StringHashMapUnmanaged([]u8) = .empty;
var override_mutex: std.Io.Mutex = .init;

/// Set (or replace) an in-process override for `name`. Both key and value are
/// duped into the process arena (the std heap allocator); a replaced value is
/// freed. After this returns, getenv("name") returns `value` until clearOverrides
/// runs. The allocator is the long-lived process allocator (rt.gpa); the map
/// outlives any single request.
pub fn setOverride(name: []const u8, value: []const u8) !void {
    override_mutex.lock(rt.io) catch {};
    defer override_mutex.unlock(rt.io);

    const gpa = rt.gpa;
    const gop = try override_map.getOrPut(gpa, name);
    if (gop.found_existing) {
        // Replace the value in place; the key is already owned.
        const new_value = try gpa.dupe(u8, value);
        gpa.free(gop.value_ptr.*);
        gop.value_ptr.* = new_value;
    } else {
        // New entry: own both key and value. Dupe the key only after the value
        // succeeds so a failed value dupe does not leave a dangling key.
        const new_value = try gpa.dupe(u8, value);
        errdefer gpa.free(new_value);
        const key_dup = try gpa.dupe(u8, name);
        gop.key_ptr.* = key_dup;
        gop.value_ptr.* = new_value;
    }
}

/// Read the override for `name`, or null if none. The returned slice borrows
/// the map's storage and must not be freed or retained across a clearOverrides.
pub fn getOverride(name: []const u8) ?[]const u8 {
    override_mutex.lock(rt.io) catch {};
    defer override_mutex.unlock(rt.io);
    return override_map.get(name);
}

/// Drop all overrides and free their storage. Tests call this to keep the
/// process-global map from leaking across cases; production rarely needs it.
pub fn clearOverrides() void {
    override_mutex.lock(rt.io) catch {};
    defer override_mutex.unlock(rt.io);
    const gpa = rt.gpa;
    var it = override_map.iterator();
    while (it.next()) |entry| {
        gpa.free(entry.key_ptr.*);
        gpa.free(entry.value_ptr.*);
    }
    override_map.clearAndFree(gpa);
}

/// Environment-variable truthy/falsy helpers ported from
/// claude-code-main/src/utils/envUtils.ts isEnvTruthy /
/// isEnvDefinedFalsy. Centralised so every call-site uses the same
/// vocabulary instead of each module re-deriving its own slightly
/// different list (e.g. one accepting "on", another not).
///
/// Truthy values (case-insensitive, trimmed): "1", "true", "yes", "on"
/// Falsy values  (case-insensitive, trimmed): "0", "false", "no", "off"
///
/// Anything else -- including unset, empty, or unrecognised words --
/// is neither truthy nor falsy. Callers decide the default.
/// Pure check on a possibly-null string slice. Returns true when the
/// value is one of the affirmative tokens after trimming whitespace and
/// lowercasing.
pub fn isTruthy(value: ?[]const u8) bool {
    const raw = value orelse return false;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return false;
    return matchToken(trimmed, &TRUTHY_TOKENS);
}

/// Pure check on a possibly-null string slice. Returns true when the
/// value is one of the negative tokens after trimming and lowercasing.
/// "Defined" because an unset value (null) returns false here too --
/// matching the reference's intent that the env var must be EXPLICITLY
/// set to a falsy word (so that an unset gate doesn't block the path).
pub fn isDefinedFalsy(value: ?[]const u8) bool {
    const raw = value orelse return false;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return false;
    return matchToken(trimmed, &FALSY_TOKENS);
}

/// std.posix.getenv was removed in Zig 0.16. Call libc directly (we
/// link libc). Returns null when unset; returns a slice borrowing
/// libc's static storage otherwise -- caller must NOT free it and
/// must not retain it across other env mutations.
pub fn getenv(name: []const u8) ?[]const u8 {
    // An in-process override (set via update_environment_variables) shadows the
    // real environment for all callers; consult it first. The borrowed slice is
    // stable for the lifetime of the override entry.
    if (getOverride(name)) |v| return v;

    // libc getenv needs a NUL-terminated key. Use a small stack buffer
    // to avoid an allocation on the hot path.
    var name_buf: [256]u8 = undefined;
    if (name.len >= name_buf.len) return null;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    const name_z: [*:0]const u8 = @ptrCast(&name_buf);
    const ptr = std.c.getenv(name_z) orelse return null;
    return std.mem.span(ptr);
}

/// Heap-allocated copy of the env var (caller owns memory). Returns
/// EnvironmentVariableNotFound (kept stable for callers porting from
/// @import("env.zig").getOwned in 0.15). Empty values are treated as
/// present and returned as an empty slice.
pub fn getOwned(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const raw = getenv(name) orelse return error.EnvironmentVariableMissing;
    return allocator.dupe(u8, raw);
}

/// Convenience wrapper: read `name` via getenv and feed it
/// through isTruthy. Use this for one-shot checks where the caller
/// doesn't need the raw value.
pub fn isEnvTruthy(name: []const u8) bool {
    return isTruthy(getenv(name));
}

/// Convenience wrapper for the falsy variant.
pub fn isEnvDefinedFalsy(name: []const u8) bool {
    return isDefinedFalsy(getenv(name));
}

/// Snapshot of the full parent process environment as an owned
/// std.process.Environ.Map. std.process.getEnvMap was removed in Zig 0.16,
/// so read the libc `environ` pointer directly (we link libc) -- the same
/// pattern used by core/shell_snapshot.zig's inheritEnviron. Callers own the
/// returned map and must `deinit` it.
///
/// Centralised here so MCP stdio spawn (and any future subprocess that needs
/// the user's real PATH/HOME/etc.) inherits the parent env instead of running
/// with a fresh empty environment.
pub fn parentEnvMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const span = std.mem.span(entry);
        const eq = std.mem.indexOfScalar(u8, span, '=') orelse continue;
        const key = span[0..eq];
        const value = span[eq + 1 ..];
        try map.put(key, value);
    }
    return map;
}

const TRUTHY_TOKENS = [_][]const u8{ "1", "true", "yes", "on" };
const FALSY_TOKENS = [_][]const u8{ "0", "false", "no", "off" };

fn matchToken(value: []const u8, tokens: []const []const u8) bool {
    var buf: [16]u8 = undefined;
    if (value.len > buf.len) return false;
    for (value, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const lower = buf[0..value.len];
    for (tokens) |tok| {
        if (std.mem.eql(u8, lower, tok)) return true;
    }
    return false;
}

const testing = std.testing;

test "isTruthy accepts the standard affirmative tokens" {
    try testing.expect(isTruthy("1"));
    try testing.expect(isTruthy("true"));
    try testing.expect(isTruthy("yes"));
    try testing.expect(isTruthy("on"));
}

test "isTruthy is case-insensitive and trims whitespace" {
    try testing.expect(isTruthy("TRUE"));
    try testing.expect(isTruthy("Yes"));
    try testing.expect(isTruthy("  on  "));
    try testing.expect(isTruthy("\tTrue\n"));
}

test "isTruthy rejects falsy and unknown values" {
    try testing.expect(!isTruthy("0"));
    try testing.expect(!isTruthy("false"));
    try testing.expect(!isTruthy("no"));
    try testing.expect(!isTruthy("off"));
    try testing.expect(!isTruthy("maybe"));
    try testing.expect(!isTruthy(""));
    try testing.expect(!isTruthy("   "));
    try testing.expect(!isTruthy(null));
}

test "isDefinedFalsy accepts the standard negative tokens" {
    try testing.expect(isDefinedFalsy("0"));
    try testing.expect(isDefinedFalsy("false"));
    try testing.expect(isDefinedFalsy("no"));
    try testing.expect(isDefinedFalsy("off"));
    try testing.expect(isDefinedFalsy("FALSE"));
    try testing.expect(isDefinedFalsy("  off  "));
}

test "isDefinedFalsy rejects truthy and unset values" {
    try testing.expect(!isDefinedFalsy("1"));
    try testing.expect(!isDefinedFalsy("true"));
    try testing.expect(!isDefinedFalsy(""));
    try testing.expect(!isDefinedFalsy(null));
    try testing.expect(!isDefinedFalsy("maybe"));
}

test "matchToken bails out for over-long values without crashing" {
    // Defends against a 32+ byte env var sneaking through (the
    // reference's regex equivalent would just fail to match -- the
    // ported buf-based matcher must do the same, not overflow buf).
    const long = "a" ** 64;
    try testing.expect(!isTruthy(long));
    try testing.expect(!isDefinedFalsy(long));
}

test "parentEnvMap snapshots the live process environment (PATH present)" {
    var map = try parentEnvMap(testing.allocator);
    defer map.deinit();
    // PATH is essentially always set in any shell-spawned test process; use
    // it as a sentinel that the snapshot actually read the real environ.
    try testing.expect(map.get("PATH") != null);
}

test "setOverride shadows getenv and clearOverrides restores the real value" {
    defer clearOverrides();
    // A name that is essentially never set in the environment.
    const key = "ZCODE_TEST_ENV_OVERRIDE_KEY";
    try testing.expect(getenv(key) == null);

    try setOverride(key, "first-token");
    try testing.expectEqualStrings("first-token", getenv(key).?);
    try testing.expectEqualStrings("first-token", getOverride(key).?);

    // A second set for the same key replaces the value (auth-token refresh).
    try setOverride(key, "second-token");
    try testing.expectEqualStrings("second-token", getenv(key).?);

    clearOverrides();
    try testing.expect(getenv(key) == null);
    try testing.expect(getOverride(key) == null);
}

test "getOwned picks up an override" {
    defer clearOverrides();
    const key = "ZCODE_TEST_ENV_OVERRIDE_OWNED";
    try setOverride(key, "owned-value");
    const owned = try getOwned(testing.allocator, key);
    defer testing.allocator.free(owned);
    try testing.expectEqualStrings("owned-value", owned);
}
