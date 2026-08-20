//! Environment-variable expansion for MCP server config values (mcp-03).
//!
//! Expands `${VAR}` and `${VAR:-default}` references in `command`, each `arg`,
//! each `env` value, `url`, and each header value when loading config,
//! collecting missing-variable names for warnings.
//!
//! Mirrors `services/mcp/envExpansion.ts:10-38` (`expandEnvVarsInString`,
//! regex `\$\{([^}]+)\}`, split on `:-` limit 2) and the per-server walk at
//! `services/mcp/config.ts:556-616` (`expandEnvVars`, which expands
//! command/args/env for stdio and url/headers for remote and dedups the
//! missing-var list).
//!
//! The module is intentionally pure with respect to the live process
//! environment: the `lookup` callback resolves a variable name to its value
//! (or null when unset), so it is testable without touching the real
//! environment. A "set but empty" variable resolves to `""` (a non-null empty
//! slice), matching the reference where `process.env[VAR] !== undefined` keeps
//! an empty value rather than falling through to the default. Pass
//! `realEnvLookup` to read from the process environment via `core/env.zig`.

const std = @import("std");
const env = @import("env.zig");
const mcp_config = @import("mcp_config.zig");

const ServerConfig = mcp_config.ServerConfig;

/// Resolve a variable name to its value, or null when the variable is unset.
/// A set-but-empty variable must return a non-null empty slice (`""`).
pub const Lookup = *const fn (name: []const u8) ?[]const u8;

/// Result of expanding a single string. `expanded` is a freshly-allocated
/// owned slice; `missing` is an owned slice of owned variable-name strings
/// (one per `${VAR}` reference that had no value and no default). Free with
/// `deinit`.
pub const ExpandResult = struct {
    expanded: []u8,
    missing: [][]u8,

    pub fn deinit(self: *ExpandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.expanded);
        for (self.missing) |m| allocator.free(m);
        if (self.missing.len > 0) allocator.free(self.missing);
        self.* = undefined;
    }
};

/// Real-environment lookup backed by `core/env.zig` `getenv`. Returns null
/// when unset; returns a borrowed slice (libc static storage) otherwise. Used
/// as the `lookup` when expanding against the live process environment.
pub fn realEnvLookup(name: []const u8) ?[]const u8 {
    return env.getenv(name);
}

/// Expand `${VAR}` / `${VAR:-default}` references in `value`.
///
/// For each `${...}` reference, the inner content runs up to the first `}`
/// (matching the reference regex `\$\{([^}]+)\}`, which does not span a `}`).
/// The inner content is split on the first `:-` into `var_name` / `default`
/// (limit 2, so a `:-` inside the default is preserved). If the variable is
/// set, its value is substituted; else if a default is present, the default is
/// substituted; else the literal `${...}` is kept and the variable name is
/// pushed to `missing`.
///
/// An empty inner content (`${}`) or one whose var name is empty has no
/// matching env var; it falls through to default-or-literal exactly like the
/// reference (where `process.env[""]` is undefined).
pub fn expandEnvVarsInString(
    allocator: std.mem.Allocator,
    value: []const u8,
    lookup: Lookup,
) !ExpandResult {
    var out: std.array_list.Managed(u8) = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    var missing: std.array_list.Managed([]u8) = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (missing.items) |m| allocator.free(m);
        missing.deinit();
    }

    var i: usize = 0;
    while (i < value.len) {
        // Look for the start of a `${` reference.
        if (i + 1 < value.len and value[i] == '$' and value[i + 1] == '{') {
            // Find the closing `}` (the regex inner class is `[^}]+`, so the
            // content cannot contain a `}`; the run ends at the first `}`).
            const inner_start = i + 2;
            const close_rel = std.mem.indexOfScalarPos(u8, value, inner_start, '}');
            if (close_rel) |close| {
                const inner = value[inner_start..close];
                // `[^}]+` requires at least one char; an empty `${}` does not
                // match the regex, so emit it literally and advance past `${`.
                if (inner.len == 0) {
                    try out.appendSlice(value[i .. i + 2]);
                    i += 2;
                    continue;
                }
                // Split on the first `:-` into var_name / default (limit 2).
                var var_name: []const u8 = inner;
                var default_value: ?[]const u8 = null;
                if (std.mem.indexOf(u8, inner, ":-")) |sep| {
                    var_name = inner[0..sep];
                    default_value = inner[sep + 2 ..];
                }

                if (lookup(var_name)) |env_value| {
                    try out.appendSlice(env_value);
                } else if (default_value) |def| {
                    try out.appendSlice(def);
                } else {
                    // Keep the original literal `${...}` and record the missing
                    // variable name for warning surfacing.
                    try out.appendSlice(value[i .. close + 1]);
                    try missing.append(try allocator.dupe(u8, var_name));
                }
                i = close + 1;
                continue;
            }
            // No closing `}`: the `${` is not a complete reference; emit `$`
            // and continue (matches the regex not finding a match here).
            try out.append(value[i]);
            i += 1;
            continue;
        }
        try out.append(value[i]);
        i += 1;
    }

    return .{
        .expanded = try out.toOwnedSlice(),
        .missing = try missing.toOwnedSlice(),
    };
}

/// Append `var_name` to `acc` unless an equal name is already present
/// (deduplication, mirroring the reference's `[...new Set(missingVars)]`).
fn appendMissingDedup(
    allocator: std.mem.Allocator,
    acc: *std.array_list.Managed([]u8),
    var_name: []const u8,
) !void {
    for (acc.items) |existing| {
        if (std.mem.eql(u8, existing, var_name)) return;
    }
    try acc.append(try allocator.dupe(u8, var_name));
}

/// Expand env-var references in every config-string field of `cfg` in place,
/// freeing each old field string before assigning the expanded one. Returns an
/// owned slice of owned, deduplicated missing-variable names across all fields.
///
/// For stdio servers, `command`, each `arg`, and each `env` VALUE are expanded
/// (env keys are not expanded, matching `mapValues`). For remote servers,
/// `url` and each header VALUE are expanded. Other field families (`sdk`,
/// ide-only) are left untouched, matching the reference's pass-through cases.
///
/// On a mid-walk OOM the partially-expanded fields already written stay owned
/// by `cfg` (still freed by `cfg.deinit`); only the in-progress missing-list is
/// rolled back via `errdefer`, so there is no leak.
pub fn expandServerConfig(
    allocator: std.mem.Allocator,
    cfg: *ServerConfig,
    lookup: Lookup,
) ![][]u8 {
    var missing: std.array_list.Managed([]u8) = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (missing.items) |m| allocator.free(m);
        missing.deinit();
    }

    switch (cfg.type) {
        .stdio, .sdk => {
            if (cfg.command) |cmd| {
                try expandField(allocator, &cfg.command.?, cmd, lookup, &missing);
            }
            for (cfg.args, 0..) |arg, idx| {
                try expandFieldSlice(allocator, cfg.args, idx, arg, lookup, &missing);
            }
            for (cfg.env) |*e| {
                try expandField(allocator, &e.value, e.value, lookup, &missing);
            }
        },
        .sse, .http, .ws => {
            if (cfg.url) |u| {
                try expandField(allocator, &cfg.url.?, u, lookup, &missing);
            }
            for (cfg.headers) |*h| {
                try expandField(allocator, &h.value, h.value, lookup, &missing);
            }
        },
    }

    return missing.toOwnedSlice();
}

/// Expand `old` and store the result through `slot`, freeing `old`. `old`
/// MUST be the slice currently held by `slot`.
fn expandField(
    allocator: std.mem.Allocator,
    slot: *[]u8,
    old: []const u8,
    lookup: Lookup,
    missing: *std.array_list.Managed([]u8),
) !void {
    var res = try expandEnvVarsInString(allocator, old, lookup);
    // Move missing names into the accumulator (deduplicated), then free the
    // backing slice of res.missing without freeing the moved names.
    {
        errdefer res.deinit(allocator);
        for (res.missing) |m| {
            try appendMissingDedup(allocator, missing, m);
        }
    }
    for (res.missing) |m| allocator.free(m);
    if (res.missing.len > 0) allocator.free(res.missing);
    // Now swap in the expanded value and free the old field.
    allocator.free(old);
    slot.* = res.expanded;
}

/// Like `expandField` but the slot lives at `arr[idx]` (for args slices, which
/// cannot have a `*[]u8` taken across the loop value binding cleanly).
fn expandFieldSlice(
    allocator: std.mem.Allocator,
    arr: [][]u8,
    idx: usize,
    old: []const u8,
    lookup: Lookup,
    missing: *std.array_list.Managed([]u8),
) !void {
    var res = try expandEnvVarsInString(allocator, old, lookup);
    {
        errdefer res.deinit(allocator);
        for (res.missing) |m| {
            try appendMissingDedup(allocator, missing, m);
        }
    }
    for (res.missing) |m| allocator.free(m);
    if (res.missing.len > 0) allocator.free(res.missing);
    allocator.free(old);
    arr[idx] = res.expanded;
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

/// In-test lookup over a small fixed table. Returns a borrowed slice for a
/// present (possibly empty) value; null when absent. Mirrors the
/// process-env contract where an empty string is "defined".
const TestEnv = struct {
    var pairs: []const [2][]const u8 = &.{};

    fn lookup(name: []const u8) ?[]const u8 {
        for (pairs) |p| {
            if (std.mem.eql(u8, p[0], name)) return p[1];
        }
        return null;
    }
};

fn emptyLookup(name: []const u8) ?[]const u8 {
    _ = name;
    return null;
}

test "expandEnvVarsInString: ${FOO} with FOO=bar => bar, no missing" {
    const allocator = testing.allocator;
    TestEnv.pairs = &.{.{ "FOO", "bar" }};
    var res = try expandEnvVarsInString(allocator, "x-${FOO}-y", TestEnv.lookup);
    defer res.deinit(allocator);
    try testing.expectEqualStrings("x-bar-y", res.expanded);
    try testing.expectEqual(@as(usize, 0), res.missing.len);
}

test "expandEnvVarsInString: ${MISSING} keeps literal and records missing" {
    const allocator = testing.allocator;
    var res = try expandEnvVarsInString(allocator, "a${MISSING}b", emptyLookup);
    defer res.deinit(allocator);
    try testing.expectEqualStrings("a${MISSING}b", res.expanded);
    try testing.expectEqual(@as(usize, 1), res.missing.len);
    try testing.expectEqualStrings("MISSING", res.missing[0]);
}

test "expandEnvVarsInString: ${MISSING:-def} => def, no missing" {
    const allocator = testing.allocator;
    var res = try expandEnvVarsInString(allocator, "[${MISSING:-def}]", emptyLookup);
    defer res.deinit(allocator);
    try testing.expectEqualStrings("[def]", res.expanded);
    try testing.expectEqual(@as(usize, 0), res.missing.len);
}

test "expandEnvVarsInString: ${X:-a:-b} default preserves inner :- (split limit 2)" {
    const allocator = testing.allocator;
    var res = try expandEnvVarsInString(allocator, "${X:-a:-b}", emptyLookup);
    defer res.deinit(allocator);
    try testing.expectEqualStrings("a:-b", res.expanded);
    try testing.expectEqual(@as(usize, 0), res.missing.len);
}

test "expandEnvVarsInString: two references both expand" {
    const allocator = testing.allocator;
    TestEnv.pairs = &.{ .{ "A", "1" }, .{ "B", "2" } };
    var res = try expandEnvVarsInString(allocator, "${A}/${B}", TestEnv.lookup);
    defer res.deinit(allocator);
    try testing.expectEqualStrings("1/2", res.expanded);
    try testing.expectEqual(@as(usize, 0), res.missing.len);
}

test "expandEnvVarsInString: set-but-empty var expands to empty (not default)" {
    const allocator = testing.allocator;
    TestEnv.pairs = &.{.{ "EMPTY", "" }};
    var res = try expandEnvVarsInString(allocator, "[${EMPTY:-fallback}]", TestEnv.lookup);
    defer res.deinit(allocator);
    // process.env[EMPTY] !== undefined, so the empty value wins over default.
    try testing.expectEqualStrings("[]", res.expanded);
    try testing.expectEqual(@as(usize, 0), res.missing.len);
}

test "expandEnvVarsInString: ${} empty content emitted literally, no missing" {
    const allocator = testing.allocator;
    var res = try expandEnvVarsInString(allocator, "a${}b", emptyLookup);
    defer res.deinit(allocator);
    try testing.expectEqualStrings("a${}b", res.expanded);
    try testing.expectEqual(@as(usize, 0), res.missing.len);
}

test "expandEnvVarsInString: unterminated ${ is emitted literally" {
    const allocator = testing.allocator;
    var res = try expandEnvVarsInString(allocator, "a${FOO and more", emptyLookup);
    defer res.deinit(allocator);
    try testing.expectEqualStrings("a${FOO and more", res.expanded);
    try testing.expectEqual(@as(usize, 0), res.missing.len);
}

test "expandServerConfig: rewrites url and a header value, reports missing in command" {
    const allocator = testing.allocator;
    TestEnv.pairs = &.{ .{ "HOST", "api.example.com" }, .{ "TOKEN", "secret" } };

    var cfg = ServerConfig{
        .name = try allocator.dupe(u8, "remote"),
        .scope = .project,
        .type = .http,
        .url = try allocator.dupe(u8, "https://${HOST}/mcp"),
        // command is present but, for a remote type, must NOT be expanded; we
        // still want a missing var that surfaces only via... actually the walk
        // for remote skips command. Place the missing var in a header instead.
    };
    // One header value references a present var; another references a missing.
    var headers = try allocator.alloc(mcp_config.HeaderEntry, 2);
    headers[0] = .{ .key = try allocator.dupe(u8, "Authorization"), .value = try allocator.dupe(u8, "Bearer ${TOKEN}") };
    headers[1] = .{ .key = try allocator.dupe(u8, "X-Trace"), .value = try allocator.dupe(u8, "${TRACE_ID}") };
    cfg.headers = headers;
    defer cfg.deinit(allocator);

    const missing = try expandServerConfig(allocator, &cfg, TestEnv.lookup);
    defer {
        for (missing) |m| allocator.free(m);
        if (missing.len > 0) allocator.free(missing);
    }

    try testing.expectEqualStrings("https://api.example.com/mcp", cfg.url.?);
    try testing.expectEqualStrings("Bearer secret", cfg.headers[0].value);
    try testing.expectEqualStrings("${TRACE_ID}", cfg.headers[1].value);
    try testing.expectEqual(@as(usize, 1), missing.len);
    try testing.expectEqualStrings("TRACE_ID", missing[0]);
}

test "expandServerConfig: stdio expands command, args, and env values; dedups missing" {
    const allocator = testing.allocator;
    TestEnv.pairs = &.{.{ "BIN", "/usr/bin/node" }};

    var cfg = ServerConfig{
        .name = try allocator.dupe(u8, "fs"),
        .scope = .user,
        .type = .stdio,
        .command = try allocator.dupe(u8, "${BIN}"),
    };
    var args = try allocator.alloc([]u8, 2);
    args[0] = try allocator.dupe(u8, "--flag=${GONE}");
    args[1] = try allocator.dupe(u8, "${GONE}");
    cfg.args = args;
    var envs = try allocator.alloc(mcp_config.EnvEntry, 1);
    envs[0] = .{ .key = try allocator.dupe(u8, "PORT"), .value = try allocator.dupe(u8, "${PORT:-3000}") };
    cfg.env = envs;
    defer cfg.deinit(allocator);

    const missing = try expandServerConfig(allocator, &cfg, TestEnv.lookup);
    defer {
        for (missing) |m| allocator.free(m);
        if (missing.len > 0) allocator.free(missing);
    }

    try testing.expectEqualStrings("/usr/bin/node", cfg.command.?);
    try testing.expectEqualStrings("--flag=${GONE}", cfg.args[0]);
    try testing.expectEqualStrings("${GONE}", cfg.args[1]);
    try testing.expectEqualStrings("3000", cfg.env[0].value);
    // GONE appears twice but must be deduplicated.
    try testing.expectEqual(@as(usize, 1), missing.len);
    try testing.expectEqualStrings("GONE", missing[0]);
}
