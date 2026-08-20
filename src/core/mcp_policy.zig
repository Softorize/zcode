//! Enterprise allow/deny MCP server policy engine (mcp-05).
//!
//! Enforces `allowedMcpServers` / `deniedMcpServers` from settings against a
//! structured `mcp_config.ServerConfig`. Each policy entry matches by exactly
//! one of: server name, exact command-array (`[command, ...args]`), or URL
//! wildcard pattern. The precedence rules mirror the reference exactly:
//!
//!   - The denylist takes absolute precedence: a denied server is blocked even
//!     if it is also allowlisted (`config.ts:421-424`).
//!   - An undefined allowlist allows everything (`config.ts:427-429`).
//!   - An empty allowlist (present but zero entries) blocks everything
//!     (`config.ts:431-434`).
//!   - When any command entries exist, a stdio server MUST match one of them;
//!     when any URL entries exist, a remote server MUST match one of them;
//!     otherwise the match falls back to name-based allowance
//!     (`config.ts:436-508`).
//!   - `allowManagedMcpServersOnly` (read only from the managed/policy source)
//!     restricts the ALLOWLIST source to managed settings; the DENYLIST always
//!     merges from all sources so a user can always deny servers for themselves
//!     (`config.ts:341-355`).
//!
//! `filterMcpServersByPolicy` drops blocked servers and returns their names so
//! callers can warn; `sdk`-type servers are exempt (`config.ts:536-551`).
//!
//! References: `services/mcp/config.ts:320-551,667-679`,
//! `utils/settings/types.ts:115-204,1107-1130`.

const std = @import("std");
const rt = @import("zcode_runtime");
const mcp_config = @import("mcp_config.zig");
const permission_rules = @import("permission_rules.zig");
const settings_sources = @import("settings_sources.zig");

/// One allow/deny entry. Matches by exactly one of name / command-array /
/// url-pattern, mirroring `AllowedMcpServerEntrySchema` /
/// `DeniedMcpServerEntrySchema` (`utils/settings/types.ts:115-204`), where the
/// three are mutually exclusive (an entry with more than one is invalid and
/// dropped by `parseEntry`).
pub const McpServerEntry = union(enum) {
    /// `{ "serverName": "foo" }`
    name: []u8,
    /// `{ "serverCommand": ["node", "server.js"] }` - matched as the full
    /// `[command, ...args]` array, element-wise exact.
    command: [][]u8,
    /// `{ "serverUrl": "https://*.example.com/*" }` - `*`-wildcard pattern.
    url: []u8,

    pub fn deinit(self: *McpServerEntry, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .name => |s| allocator.free(s),
            .url => |s| allocator.free(s),
            .command => |arr| {
                for (arr) |a| allocator.free(a);
                if (arr.len > 0) allocator.free(arr);
            },
        }
        self.* = undefined;
    }
};

/// A fully-parsed policy: the allow and deny entry lists. A null list means
/// "the key was not present in any source" (undefined), which is semantically
/// distinct from an empty list (present but zero entries -> block all for the
/// allowlist). Owned by the caller; free with `deinit`.
pub const Policy = struct {
    allowed: ?[]McpServerEntry = null,
    denied: ?[]McpServerEntry = null,

    pub fn deinit(self: *Policy, allocator: std.mem.Allocator) void {
        if (self.allowed) |list| {
            for (list) |*e| e.deinit(allocator);
            if (list.len > 0) allocator.free(list);
        }
        if (self.denied) |list| {
            for (list) |*e| e.deinit(allocator);
            if (list.len > 0) allocator.free(list);
        }
        self.* = undefined;
    }
};

/// Parse one settings entry object into an `McpServerEntry`. Returns null when
/// the entry is not an object, has none of the three keys, or has more than one
/// of them (the reference requires exactly one - `types.ts:141-157`). Caller
/// owns the returned entry's slices.
pub fn parseEntry(allocator: std.mem.Allocator, value: std.json.Value) !?McpServerEntry {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };

    var count: usize = 0;
    const name_v = obj.get("serverName");
    const cmd_v = obj.get("serverCommand");
    const url_v = obj.get("serverUrl");
    if (name_v != null and name_v.? == .string) count += 1;
    if (cmd_v != null and cmd_v.? == .array) count += 1;
    if (url_v != null and url_v.? == .string) count += 1;
    // Exactly one must be present (mutual exclusivity).
    if (count != 1) return null;

    if (name_v) |nv| {
        if (nv == .string) {
            return McpServerEntry{ .name = try allocator.dupe(u8, nv.string) };
        }
    }
    if (url_v) |uv| {
        if (uv == .string) {
            return McpServerEntry{ .url = try allocator.dupe(u8, uv.string) };
        }
    }
    if (cmd_v) |cv| {
        if (cv == .array) {
            // A command entry must have at least one element (the command).
            if (cv.array.items.len == 0) return null;
            var list = std.array_list.Managed([]u8).init(allocator);
            errdefer {
                for (list.items) |a| allocator.free(a);
                list.deinit();
            }
            for (cv.array.items) |item| {
                const s = switch (item) {
                    .string => |str| str,
                    else => return null, // non-string element invalidates the entry
                };
                try list.append(try allocator.dupe(u8, s));
            }
            return McpServerEntry{ .command = try list.toOwnedSlice() };
        }
    }
    return null;
}

/// Match a `*`-wildcard URL pattern against a URL, anchored at both ends
/// (`config.ts:320-334`: escape regex specials, `*` -> `.*`, `^...$`). Only
/// `*` is special. Reuses the project's single anchored glob matcher
/// (`permission_rules.globMatch`); a bare `"*"` matches everything.
pub fn urlMatchesPattern(url: []const u8, pattern: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    return permission_rules.globMatch(pattern, url);
}

/// Exact element-wise equality of two command arrays (`config.ts:149-154`).
pub fn commandArraysMatch(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

/// The `[command, ...args]` array for a stdio server, or null for a non-stdio
/// server (`config.ts:137-144`). The returned slice is owned by the caller and
/// must be freed (the slice itself, not its elements which borrow from `srv`).
fn serverCommandArray(allocator: std.mem.Allocator, srv: *const mcp_config.ServerConfig) !?[]const []const u8 {
    // Non-stdio servers don't have commands. (`sdk` is exempt elsewhere.)
    if (srv.type != .stdio) return null;
    const command = srv.command orelse return null;
    var list = std.array_list.Managed([]const u8).init(allocator);
    errdefer list.deinit();
    try list.append(command);
    for (srv.args) |a| try list.append(a);
    return try list.toOwnedSlice();
}

/// The remote URL of a server, or null for a stdio/sdk server.
fn serverUrl(srv: *const mcp_config.ServerConfig) ?[]const u8 {
    return srv.url;
}

/// Whether a server is denied by policy. Name match, exact command-array match
/// (stdio only), or URL pattern match (remote only). Mirrors
/// `isMcpServerDenied` (`config.ts:364-408`).
pub fn isMcpServerDenied(
    allocator: std.mem.Allocator,
    policy: *const Policy,
    srv: *const mcp_config.ServerConfig,
) !bool {
    const denied = policy.denied orelse return false; // no restrictions

    // Name-based denial.
    for (denied) |entry| {
        switch (entry) {
            .name => |n| if (std.mem.eql(u8, n, srv.name)) return true,
            else => {},
        }
    }

    // Command-based denial (stdio servers only).
    const cmd = try serverCommandArray(allocator, srv);
    defer if (cmd) |c| {
        if (c.len > 0) allocator.free(c);
    };
    if (cmd) |c| {
        for (denied) |entry| {
            switch (entry) {
                .command => |dc| if (commandArraysMatch(dc, c)) return true,
                else => {},
            }
        }
    }

    // URL-based denial (remote servers only).
    if (serverUrl(srv)) |u| {
        for (denied) |entry| {
            switch (entry) {
                .url => |pat| if (urlMatchesPattern(u, pat)) return true,
                else => {},
            }
        }
    }

    return false;
}

fn anyCommandEntries(entries: []const McpServerEntry) bool {
    for (entries) |e| {
        if (e == .command) return true;
    }
    return false;
}

fn anyUrlEntries(entries: []const McpServerEntry) bool {
    for (entries) |e| {
        if (e == .url) return true;
    }
    return false;
}

fn nameAllowed(entries: []const McpServerEntry, name: []const u8) bool {
    for (entries) |e| {
        switch (e) {
            .name => |n| if (std.mem.eql(u8, n, name)) return true,
            else => {},
        }
    }
    return false;
}

/// Whether a server is allowed by policy. Denylist wins; undefined allowlist
/// allows all; empty allowlist blocks all; otherwise command/URL entries gate
/// stdio/remote servers respectively, falling back to name-based allowance.
/// Mirrors `isMcpServerAllowedByPolicy` (`config.ts:417-508`).
pub fn isMcpServerAllowedByPolicy(
    allocator: std.mem.Allocator,
    policy: *const Policy,
    srv: *const mcp_config.ServerConfig,
) !bool {
    // Denylist takes absolute precedence.
    if (try isMcpServerDenied(allocator, policy, srv)) return false;

    const allowed = policy.allowed orelse return true; // undefined -> allow all
    if (allowed.len == 0) return false; // empty -> block all

    const has_command_entries = anyCommandEntries(allowed);
    const has_url_entries = anyUrlEntries(allowed);

    const cmd = try serverCommandArray(allocator, srv);
    defer if (cmd) |c| {
        if (c.len > 0) allocator.free(c);
    };

    if (cmd) |c| {
        // stdio server.
        if (has_command_entries) {
            // Any command entries exist -> stdio MUST match one.
            for (allowed) |entry| {
                switch (entry) {
                    .command => |ac| if (commandArraysMatch(ac, c)) return true,
                    else => {},
                }
            }
            return false;
        }
        // No command entries -> name-based allowance.
        return nameAllowed(allowed, srv.name);
    }

    if (serverUrl(srv)) |u| {
        // remote server.
        if (has_url_entries) {
            // Any URL entries exist -> remote MUST match one.
            for (allowed) |entry| {
                switch (entry) {
                    .url => |pat| if (urlMatchesPattern(u, pat)) return true,
                    else => {},
                }
            }
            return false;
        }
        return nameAllowed(allowed, srv.name);
    }

    // Unknown server type -> name-based allowance only.
    return nameAllowed(allowed, srv.name);
}

/// Result of filtering a server list by policy. `blocked` names are owned by
/// the caller (duplicated from the dropped servers).
pub const FilterResult = struct {
    blocked: [][]u8,

    pub fn deinit(self: *FilterResult, allocator: std.mem.Allocator) void {
        for (self.blocked) |b| allocator.free(b);
        if (self.blocked.len > 0) allocator.free(self.blocked);
        self.* = undefined;
    }
};

/// Filter `servers` by policy: policy-blocked servers are dropped (each dropped
/// `ServerConfig` is freed here) and `servers.*` is replaced with a freshly
/// allocated slice of the survivors. The original backing buffer is freed.
/// `sdk`-type servers are exempt (`config.ts:544`). Returns the dropped names
/// so callers can warn.
///
/// Ownership: after the call the caller owns ONLY the new `servers.*` slice
/// (and the returned `FilterResult.blocked`). The old backing buffer is gone.
/// When nothing is blocked, `servers.*` is rebuilt anyway so the rule "caller
/// owns the new slice" holds uniformly.
pub fn filterMcpServersByPolicy(
    allocator: std.mem.Allocator,
    policy: *const Policy,
    servers: *[]mcp_config.ServerConfig,
) !FilterResult {
    var blocked = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (blocked.items) |b| allocator.free(b);
        blocked.deinit();
    }

    var survivors = std.array_list.Managed(mcp_config.ServerConfig).init(allocator);
    errdefer {
        // On the error path survivors hold configs moved out of `slice`; free
        // them so they do not leak. (Un-iterated `slice` tail may still leak on
        // OOM, which is acceptable for a fatal allocation failure.)
        for (survivors.items) |*s| s.deinit(allocator);
        survivors.deinit();
    }

    const slice = servers.*;
    for (slice) |srv| {
        const exempt = srv.type == .sdk;
        const allow = exempt or (try isMcpServerAllowedByPolicy(allocator, policy, &srv));
        if (allow) {
            try survivors.append(srv);
        } else {
            const name_copy = try allocator.dupe(u8, srv.name);
            errdefer allocator.free(name_copy);
            try blocked.append(name_copy);
            var dropped = srv;
            dropped.deinit(allocator);
        }
    }
    // Free the original backing buffer (its elements were moved into survivors
    // or already freed as dropped above).
    if (slice.len > 0) allocator.free(slice);
    servers.* = try survivors.toOwnedSlice();
    return .{ .blocked = try blocked.toOwnedSlice() };
}

// ── Settings-backed policy loading ──────────────────────────────────────

/// Read `allowManagedMcpServersOnly` from the managed/policy source ONLY
/// (`config.ts:342`, `shouldAllowManagedMcpServersOnly`). When true, the
/// allowlist is sourced from managed settings exclusively.
fn shouldAllowManagedMcpServersOnly(allocator: std.mem.Allocator, cwd: []const u8) bool {
    return settings_sources.sourceScalarBool(allocator, cwd, null, .policy, "allowManagedMcpServersOnly") orelse false;
}

/// Merge the `deniedMcpServers` entry list across ALL disk sources (the
/// denylist always merges - users can always deny for themselves,
/// `config.ts:353-355`). Later sources append (deny is a collection, not an
/// override).
fn loadDenied(allocator: std.mem.Allocator, cwd: []const u8) !?[]McpServerEntry {
    var list = std.array_list.Managed(McpServerEntry).init(allocator);
    errdefer {
        for (list.items) |*e| e.deinit(allocator);
        list.deinit();
    }
    var any = false;
    for (settings_sources.sourceOrder()) |source| {
        var parsed = (settings_sources.readSource(allocator, cwd, source, null) catch null) orelse continue;
        defer parsed.deinit();
        const arr = settings_sources.getArray(parsed.value, "deniedMcpServers") orelse continue;
        any = true;
        for (arr) |item| {
            if (try parseEntry(allocator, item)) |entry| try list.append(entry);
        }
    }
    if (!any) {
        list.deinit();
        return null;
    }
    return try list.toOwnedSlice();
}

/// Load the `allowedMcpServers` list. When `allowManagedMcpServersOnly` is set
/// in the managed/policy source, the allowlist is read ONLY from that source
/// (`config.ts:341-346`). Otherwise it merges across all sources. A key that is
/// absent from every consulted source yields null (undefined -> allow all).
fn loadAllowed(allocator: std.mem.Allocator, cwd: []const u8) !?[]McpServerEntry {
    const managed_only = shouldAllowManagedMcpServersOnly(allocator, cwd);

    var list = std.array_list.Managed(McpServerEntry).init(allocator);
    errdefer {
        for (list.items) |*e| e.deinit(allocator);
        list.deinit();
    }
    var any = false;

    if (managed_only) {
        var parsed = (settings_sources.readSource(allocator, cwd, .policy, null) catch null);
        if (parsed) |*p| {
            defer p.deinit();
            if (settings_sources.getArray(p.value, "allowedMcpServers")) |arr| {
                any = true;
                for (arr) |item| {
                    if (try parseEntry(allocator, item)) |entry| try list.append(entry);
                }
            }
        }
    } else {
        for (settings_sources.sourceOrder()) |source| {
            var parsed = (settings_sources.readSource(allocator, cwd, source, null) catch null) orelse continue;
            defer parsed.deinit();
            const arr = settings_sources.getArray(parsed.value, "allowedMcpServers") orelse continue;
            any = true;
            for (arr) |item| {
                if (try parseEntry(allocator, item)) |entry| try list.append(entry);
            }
        }
    }

    if (!any) {
        list.deinit();
        return null;
    }
    return try list.toOwnedSlice();
}

/// Build the active policy from settings.json sources rooted at `cwd`. Caller
/// owns the result; free with `Policy.deinit`.
pub fn loadPolicy(allocator: std.mem.Allocator, cwd: []const u8) !Policy {
    var policy = Policy{};
    errdefer policy.deinit(allocator);
    policy.denied = try loadDenied(allocator, cwd);
    policy.allowed = try loadAllowed(allocator, cwd);
    return policy;
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

fn makeStdio(allocator: std.mem.Allocator, name: []const u8, command: []const u8, args: []const []const u8) !mcp_config.ServerConfig {
    var srv = mcp_config.ServerConfig{
        .name = try allocator.dupe(u8, name),
        .scope = .user,
        .type = .stdio,
    };
    errdefer srv.deinit(allocator);
    srv.command = try allocator.dupe(u8, command);
    if (args.len > 0) {
        var list = std.array_list.Managed([]u8).init(allocator);
        errdefer {
            for (list.items) |a| allocator.free(a);
            list.deinit();
        }
        for (args) |a| try list.append(try allocator.dupe(u8, a));
        srv.args = try list.toOwnedSlice();
    }
    return srv;
}

fn makeRemote(allocator: std.mem.Allocator, name: []const u8, url: []const u8) !mcp_config.ServerConfig {
    var srv = mcp_config.ServerConfig{
        .name = try allocator.dupe(u8, name),
        .scope = .user,
        .type = .http,
    };
    errdefer srv.deinit(allocator);
    srv.url = try allocator.dupe(u8, url);
    return srv;
}

fn nameEntry(allocator: std.mem.Allocator, name: []const u8) !McpServerEntry {
    return McpServerEntry{ .name = try allocator.dupe(u8, name) };
}

fn urlEntry(allocator: std.mem.Allocator, pat: []const u8) !McpServerEntry {
    return McpServerEntry{ .url = try allocator.dupe(u8, pat) };
}

fn commandEntry(allocator: std.mem.Allocator, parts: []const []const u8) !McpServerEntry {
    var list = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (list.items) |a| allocator.free(a);
        list.deinit();
    }
    for (parts) |p| try list.append(try allocator.dupe(u8, p));
    return McpServerEntry{ .command = try list.toOwnedSlice() };
}

test "urlMatchesPattern: anchored wildcard, both ends" {
    try testing.expect(urlMatchesPattern("https://api.example.com/x", "https://*.example.com/*"));
    try testing.expect(!urlMatchesPattern("https://evil.com", "https://*.example.com/*"));
    // Anchored at the end: a longer URL than a non-* pattern does not match.
    try testing.expect(urlMatchesPattern("https://x.test/h", "https://x.test/h"));
    try testing.expect(!urlMatchesPattern("https://x.test/h2", "https://x.test/h"));
    // Bare "*" matches everything.
    try testing.expect(urlMatchesPattern("anything://here", "*"));
    // Trailing "*" matches any suffix incl. empty.
    try testing.expect(urlMatchesPattern("https://example.com/", "https://example.com/*"));
    try testing.expect(urlMatchesPattern("https://example.com/api/v1", "https://example.com/*"));
}

test "commandArraysMatch: exact element-wise equality" {
    try testing.expect(commandArraysMatch(&.{ "node", "s.js" }, &.{ "node", "s.js" }));
    try testing.expect(!commandArraysMatch(&.{ "node", "s.js" }, &.{ "node", "other.js" }));
    try testing.expect(!commandArraysMatch(&.{"node"}, &.{ "node", "s.js" }));
}

test "policy: undefined allowlist allows all" {
    const allocator = testing.allocator;
    var policy = Policy{}; // allowed=null, denied=null
    var srv = try makeStdio(allocator, "foo", "node", &.{});
    defer srv.deinit(allocator);
    try testing.expect(try isMcpServerAllowedByPolicy(allocator, &policy, &srv));
}

test "policy: empty allowlist blocks all" {
    const allocator = testing.allocator;
    const allowed = try allocator.alloc(McpServerEntry, 0);
    var policy = Policy{ .allowed = allowed };
    defer policy.deinit(allocator);
    var srv = try makeStdio(allocator, "foo", "node", &.{});
    defer srv.deinit(allocator);
    try testing.expect(!(try isMcpServerAllowedByPolicy(allocator, &policy, &srv)));
}

test "policy: denylist name match blocks even if allowlisted" {
    const allocator = testing.allocator;
    var allowed = try allocator.alloc(McpServerEntry, 1);
    allowed[0] = try nameEntry(allocator, "foo");
    var denied = try allocator.alloc(McpServerEntry, 1);
    denied[0] = try nameEntry(allocator, "foo");
    var policy = Policy{ .allowed = allowed, .denied = denied };
    defer policy.deinit(allocator);

    var srv = try makeStdio(allocator, "foo", "node", &.{});
    defer srv.deinit(allocator);
    try testing.expect(try isMcpServerDenied(allocator, &policy, &srv));
    try testing.expect(!(try isMcpServerAllowedByPolicy(allocator, &policy, &srv)));
}

test "policy: URL pattern matches subdomain path and rejects other host" {
    const allocator = testing.allocator;
    var allowed = try allocator.alloc(McpServerEntry, 1);
    allowed[0] = try urlEntry(allocator, "https://*.example.com/*");
    var policy = Policy{ .allowed = allowed };
    defer policy.deinit(allocator);

    var good = try makeRemote(allocator, "good", "https://api.example.com/x");
    defer good.deinit(allocator);
    var bad = try makeRemote(allocator, "bad", "https://evil.com");
    defer bad.deinit(allocator);

    try testing.expect(try isMcpServerAllowedByPolicy(allocator, &policy, &good));
    try testing.expect(!(try isMcpServerAllowedByPolicy(allocator, &policy, &bad)));
}

test "policy: command-array entry allows exact match, blocks others" {
    const allocator = testing.allocator;
    var allowed = try allocator.alloc(McpServerEntry, 1);
    allowed[0] = try commandEntry(allocator, &.{ "node", "server.js" });
    var policy = Policy{ .allowed = allowed };
    defer policy.deinit(allocator);

    var match = try makeStdio(allocator, "m", "node", &.{"server.js"});
    defer match.deinit(allocator);
    var nomatch = try makeStdio(allocator, "n", "node", &.{"other.js"});
    defer nomatch.deinit(allocator);

    try testing.expect(try isMcpServerAllowedByPolicy(allocator, &policy, &match));
    try testing.expect(!(try isMcpServerAllowedByPolicy(allocator, &policy, &nomatch)));
}

test "policy: command entries present blocks stdio with no matching command" {
    const allocator = testing.allocator;
    // Allowlist has a command entry AND a name entry that names the server.
    // Because a command entry exists, the stdio server MUST match a command
    // entry; the name entry does not rescue it.
    var allowed = try allocator.alloc(McpServerEntry, 2);
    allowed[0] = try commandEntry(allocator, &.{ "node", "server.js" });
    allowed[1] = try nameEntry(allocator, "foo");
    var policy = Policy{ .allowed = allowed };
    defer policy.deinit(allocator);

    var srv = try makeStdio(allocator, "foo", "python", &.{"-m"});
    defer srv.deinit(allocator);
    try testing.expect(!(try isMcpServerAllowedByPolicy(allocator, &policy, &srv)));
}

test "policy: url entries present does not block stdio (falls to name)" {
    const allocator = testing.allocator;
    // Only URL entries exist. A stdio server has no command entry to match, so
    // it falls back to name-based allowance. With no name entry it is blocked.
    var allowed = try allocator.alloc(McpServerEntry, 1);
    allowed[0] = try urlEntry(allocator, "https://*.example.com/*");
    var policy = Policy{ .allowed = allowed };
    defer policy.deinit(allocator);

    var srv = try makeStdio(allocator, "foo", "node", &.{});
    defer srv.deinit(allocator);
    try testing.expect(!(try isMcpServerAllowedByPolicy(allocator, &policy, &srv)));
}

test "policy: name allowance when no command/url entries" {
    const allocator = testing.allocator;
    var allowed = try allocator.alloc(McpServerEntry, 1);
    allowed[0] = try nameEntry(allocator, "foo");
    var policy = Policy{ .allowed = allowed };
    defer policy.deinit(allocator);

    var foo = try makeStdio(allocator, "foo", "node", &.{});
    defer foo.deinit(allocator);
    var bar = try makeStdio(allocator, "bar", "node", &.{});
    defer bar.deinit(allocator);

    try testing.expect(try isMcpServerAllowedByPolicy(allocator, &policy, &foo));
    try testing.expect(!(try isMcpServerAllowedByPolicy(allocator, &policy, &bar)));
}

test "filterMcpServersByPolicy: drops blocked, keeps allowed, exempts sdk" {
    const allocator = testing.allocator;
    var allowed = try allocator.alloc(McpServerEntry, 1);
    allowed[0] = try nameEntry(allocator, "keep");
    var policy = Policy{ .allowed = allowed };
    defer policy.deinit(allocator);

    var list = try allocator.alloc(mcp_config.ServerConfig, 3);
    list[0] = try makeStdio(allocator, "keep", "node", &.{});
    list[1] = try makeStdio(allocator, "drop", "node", &.{});
    // sdk server is exempt even though not named in allowlist.
    list[2] = try makeStdio(allocator, "sdksrv", "node", &.{});
    list[2].type = .sdk;

    var servers: []mcp_config.ServerConfig = list;
    var result = try filterMcpServersByPolicy(allocator, &policy, &servers);
    defer result.deinit(allocator);

    // survivors: keep + sdksrv (2); dropped: drop (1). The original `list`
    // backing buffer was freed by the filter; `servers` is the new slice.
    try testing.expectEqual(@as(usize, 2), servers.len);
    try testing.expectEqual(@as(usize, 1), result.blocked.len);
    try testing.expectEqualStrings("drop", result.blocked[0]);

    // Free the survivors and the new backing buffer.
    for (servers) |*s| s.deinit(allocator);
    if (servers.len > 0) allocator.free(servers);
}

test "parseEntry: rejects multi-field and zero-field entries" {
    const allocator = testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\[
        \\  { "serverName": "ok" },
        \\  { "serverName": "x", "serverUrl": "https://y" },
        \\  { },
        \\  { "serverCommand": ["node", "s.js"] },
        \\  { "serverCommand": [] },
        \\  { "serverUrl": "https://*.test/*" }
        \\]
    , .{});
    defer parsed.deinit();
    const arr = parsed.value.array.items;

    const e0 = try parseEntry(allocator, arr[0]);
    try testing.expect(e0 != null);
    var v0 = e0.?;
    defer v0.deinit(allocator);
    try testing.expectEqualStrings("ok", v0.name);

    try testing.expect((try parseEntry(allocator, arr[1])) == null); // multi-field
    try testing.expect((try parseEntry(allocator, arr[2])) == null); // zero-field

    const e3 = try parseEntry(allocator, arr[3]);
    try testing.expect(e3 != null);
    var v3 = e3.?;
    defer v3.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), v3.command.len);

    try testing.expect((try parseEntry(allocator, arr[4])) == null); // empty command

    const e5 = try parseEntry(allocator, arr[5]);
    try testing.expect(e5 != null);
    var v5 = e5.?;
    defer v5.deinit(allocator);
    try testing.expectEqualStrings("https://*.test/*", v5.url);
}

test "loadPolicy: reads allow/deny from settings.json, denylist wins" {
    const allocator = testing.allocator;
    const test_helpers = @import("test_helpers.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".claude");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".claude/settings.json",
        .data =
        \\{
        \\  "allowedMcpServers": [ { "serverName": "foo" }, { "serverName": "bar" } ],
        \\  "deniedMcpServers": [ { "serverName": "bar" } ]
        \\}
        ,
    });

    const cwd = try test_helpers.tmpDirPath(allocator, &tmp, ".");
    defer allocator.free(cwd);

    var policy = try loadPolicy(allocator, cwd);
    defer policy.deinit(allocator);

    try testing.expect(policy.allowed != null);
    try testing.expectEqual(@as(usize, 2), policy.allowed.?.len);
    try testing.expect(policy.denied != null);
    try testing.expectEqual(@as(usize, 1), policy.denied.?.len);

    var foo = try makeStdio(allocator, "foo", "node", &.{});
    defer foo.deinit(allocator);
    var bar = try makeStdio(allocator, "bar", "node", &.{});
    defer bar.deinit(allocator);

    try testing.expect(try isMcpServerAllowedByPolicy(allocator, &policy, &foo));
    // bar is allowlisted AND denylisted -> deny wins.
    try testing.expect(!(try isMcpServerAllowedByPolicy(allocator, &policy, &bar)));
}
