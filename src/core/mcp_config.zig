//! Structured, scoped MCP server-config model and loaders (mcp-01).
//!
//! Replaces the flat `{name, transport}` registry with a structured config
//! model (`ServerConfig`) loaded from several scopes:
//!   - project `.mcp.json` files (with parent-directory traversal,
//!     closest-wins),
//!   - user / local settings,
//!   - an enterprise managed file (exclusive control when present),
//!   - dynamic `--mcp-config`.
//!
//! The reference reads servers from these scopes and merges them by
//! precedence plugin < user < project < local (later wins on key
//! collision); if an enterprise file exists it takes exclusive control.
//! See `services/mcp/config.ts:888-1251` and `services/mcp/types.ts:10-177`.
//!
//! This module is the new structured config model that the rest of the MCP
//! subsystem (env expansion, headers helper, policy, approval, plugins)
//! attaches to. It is intentionally pure with respect to the live process
//! environment: env-var expansion is wired in by a later task and takes an
//! injectable lookup, so these loaders/parsers are testable without the real
//! environment.

const std = @import("std");
const builtin = @import("builtin");
const rt = @import("zcode_runtime");
const std_io = @import("std_io.zig");
const paths = @import("paths.zig");
const mcp_env_expand = @import("mcp_env_expand.zig");
const mcp_policy = @import("mcp_policy.zig");
const mcp_approval = @import("mcp_approval.zig");

/// Cap on a single `.mcp.json` file. A pathological file must not be read
/// unbounded. `readFileAlloc(.limited(N))` returns `error.StreamTooLong`
/// (not `error.FileTooBig`) per the 0.16 migration notes; we map that to a
/// fatal parse error for the file rather than crashing.
const MAX_MCP_JSON_BYTES: usize = 4 * 1024 * 1024;

/// Scope an MCP server was sourced from. Mirrors `ConfigScopeSchema`
/// (`services/mcp/types.ts:10-21`). `claudeai` and `managed`/`dynamic` are
/// recognized for completeness; only a subset are loaded in this task.
pub const ConfigScope = enum {
    local,
    user,
    project,
    dynamic,
    enterprise,
    claudeai,
    managed,
};

/// Transport family. `sdk` is recognized so policy can exempt it later; no
/// SDK control transport is implemented in this phase.
pub const TransportType = enum {
    stdio,
    sse,
    http,
    ws,
    sdk,

    pub fn isRemote(self: TransportType) bool {
        return switch (self) {
            .sse, .http, .ws => true,
            .stdio, .sdk => false,
        };
    }
};

/// Ordered key/value pair. Stored as an ordered slice (not a hashmap) so
/// iteration is deterministic and ownership is trivial to free. Map
/// insertion order matters for env merge (per-server overrides parent).
pub const EnvEntry = struct {
    key: []u8,
    value: []u8,
};

pub const HeaderEntry = struct {
    key: []u8,
    value: []u8,
};

/// Optional oauth sub-block (clientId / callbackPort / authServerMetadataUrl).
pub const OAuthConfig = struct {
    client_id: ?[]u8 = null,
    callback_port: ?u16 = null,
    auth_server_metadata_url: ?[]u8 = null,

    pub fn deinit(self: *OAuthConfig, allocator: std.mem.Allocator) void {
        if (self.client_id) |s| allocator.free(s);
        if (self.auth_server_metadata_url) |s| allocator.free(s);
        self.* = undefined;
    }
};

/// Severity of a config validation problem. Mirrors `mcpErrorMetadata`
/// severity (`services/mcp/config.ts:1297-1468`). Task 11 (mcp-12) surfaces
/// these to the operator; this task collects them.
pub const Severity = enum { fatal, warning };

pub const ValidationError = struct {
    scope: ConfigScope,
    server_name: ?[]u8 = null,
    message: []u8,
    severity: Severity,

    pub fn deinit(self: *ValidationError, allocator: std.mem.Allocator) void {
        if (self.server_name) |s| allocator.free(s);
        allocator.free(self.message);
        self.* = undefined;
    }
};

/// Human-readable label for a config scope (mirrors `utils.ts:263-299`
/// `getScopeLabel`). Used in operator-facing warning lines.
pub fn scopeLabel(scope: ConfigScope) []const u8 {
    return switch (scope) {
        .local => "local",
        .user => "user",
        .project => "project (.mcp.json)",
        .dynamic => "dynamic (--mcp-config)",
        .enterprise => "enterprise (managed)",
        .claudeai => "claude.ai",
        .managed => "managed",
    };
}

/// Severity-prefixed, operator-facing prefix for a `ValidationError`.
/// `fatal` => `error: mcp:`, `warning` => `warning: mcp:`, matching the
/// existing stdout/stderr discipline in `cmdMcpAdd`.
fn severityPrefix(severity: Severity) []const u8 {
    return switch (severity) {
        .fatal => "error: mcp:",
        .warning => "warning: mcp:",
    };
}

/// Render collected `ValidationError`s to `writer` (one line each), severity-
/// prefixed and scope-tagged. The caller passes a stderr writer so stdout
/// stays clean for machine consumers (matches `cmdMcpAdd`'s discipline). The
/// `writer: anytype` shape lets tests pass a fixed buffer instead of stderr.
///
/// Mirrors the reference's `McpParsingWarnings` surfacing
/// (`components/mcp/McpParsingWarnings.tsx`) collapsed to one line per error.
pub fn renderValidationErrors(writer: anytype, errors: []const ValidationError) !void {
    for (errors) |e| {
        if (e.server_name) |name| {
            try writer.print(
                "{s} [{s}] {s}: {s}\n",
                .{ severityPrefix(e.severity), scopeLabel(e.scope), name, e.message },
            );
        } else {
            try writer.print(
                "{s} [{s}] {s}\n",
                .{ severityPrefix(e.severity), scopeLabel(e.scope), e.message },
            );
        }
    }
}

/// A fully-structured MCP server config. All owned slices are dup-owned and
/// freed by `deinit`.
pub const ServerConfig = struct {
    name: []u8,
    scope: ConfigScope,
    type: TransportType,

    // stdio
    command: ?[]u8 = null,
    args: [][]u8 = &.{},
    env: []EnvEntry = &.{},

    // remote
    url: ?[]u8 = null,
    headers: []HeaderEntry = &.{},
    headers_helper: ?[]u8 = null,

    oauth: ?OAuthConfig = null,

    disabled: bool = false,
    plugin_source: ?[]u8 = null,

    pub fn deinit(self: *ServerConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.command) |c| allocator.free(c);
        for (self.args) |a| allocator.free(a);
        if (self.args.len > 0) allocator.free(self.args);
        for (self.env) |*e| {
            allocator.free(e.key);
            allocator.free(e.value);
        }
        if (self.env.len > 0) allocator.free(self.env);
        if (self.url) |u| allocator.free(u);
        for (self.headers) |*h| {
            allocator.free(h.key);
            allocator.free(h.value);
        }
        if (self.headers.len > 0) allocator.free(self.headers);
        if (self.headers_helper) |h| allocator.free(h);
        if (self.oauth) |*o| o.deinit(allocator);
        if (self.plugin_source) |p| allocator.free(p);
        self.* = undefined;
    }
};

/// Result of parsing a `.mcp.json` body or a scope. `servers` and `errors`
/// are owned by the caller. Free with `deinit`.
pub const ParseResult = struct {
    servers: []ServerConfig,
    errors: []ValidationError,

    pub fn deinit(self: *ParseResult, allocator: std.mem.Allocator) void {
        for (self.servers) |*s| s.deinit(allocator);
        if (self.servers.len > 0) allocator.free(self.servers);
        for (self.errors) |*e| e.deinit(allocator);
        if (self.errors.len > 0) allocator.free(self.errors);
        self.* = undefined;
    }

    /// Free only the error slice (and the empty/consumed servers backing
    /// slice). Used when the servers have already been MOVED out into another
    /// accumulator.
    pub fn deinitErrorsOnly(self: *ParseResult, allocator: std.mem.Allocator) void {
        for (self.errors) |*e| e.deinit(allocator);
        if (self.errors.len > 0) allocator.free(self.errors);
        if (self.servers.len > 0) allocator.free(self.servers);
        self.* = undefined;
    }
};

/// Free a slice of `ServerConfig` and the slice itself.
pub fn freeServerConfigs(allocator: std.mem.Allocator, servers: []ServerConfig) void {
    for (servers) |*s| s.deinit(allocator);
    if (servers.len > 0) allocator.free(servers);
}

/// Deep-copy a `ServerConfig`. All owned slices are duplicated so the copy can
/// be freed independently with `deinit`. Used by callers (e.g. `agents.clone`)
/// that need an independent owned copy of a spec carrying MCP servers.
pub fn cloneServerConfig(allocator: std.mem.Allocator, src: *const ServerConfig) !ServerConfig {
    var out = ServerConfig{
        .name = try allocator.dupe(u8, src.name),
        .scope = src.scope,
        .type = src.type,
        .disabled = src.disabled,
    };
    errdefer out.deinit(allocator);

    if (src.command) |c| out.command = try allocator.dupe(u8, c);
    if (src.args.len > 0) {
        const args = try allocator.alloc([]u8, src.args.len);
        var filled: usize = 0;
        errdefer {
            for (args[0..filled]) |a| allocator.free(a);
            allocator.free(args);
        }
        for (src.args, 0..) |a, i| {
            args[i] = try allocator.dupe(u8, a);
            filled = i + 1;
        }
        out.args = args;
    }
    if (src.env.len > 0) {
        var env_list = std.array_list.Managed(EnvEntry).init(allocator);
        errdefer {
            for (env_list.items) |*e| {
                allocator.free(e.key);
                allocator.free(e.value);
            }
            env_list.deinit();
        }
        for (src.env) |e| {
            const k = try allocator.dupe(u8, e.key);
            errdefer allocator.free(k);
            const val = try allocator.dupe(u8, e.value);
            try env_list.append(.{ .key = k, .value = val });
        }
        out.env = try env_list.toOwnedSlice();
    }
    if (src.url) |u| out.url = try allocator.dupe(u8, u);
    if (src.headers.len > 0) {
        var hdr_list = std.array_list.Managed(HeaderEntry).init(allocator);
        errdefer {
            for (hdr_list.items) |*h| {
                allocator.free(h.key);
                allocator.free(h.value);
            }
            hdr_list.deinit();
        }
        for (src.headers) |h| {
            const k = try allocator.dupe(u8, h.key);
            errdefer allocator.free(k);
            const val = try allocator.dupe(u8, h.value);
            try hdr_list.append(.{ .key = k, .value = val });
        }
        out.headers = try hdr_list.toOwnedSlice();
    }
    if (src.headers_helper) |h| out.headers_helper = try allocator.dupe(u8, h);
    if (src.oauth) |o| {
        var oc = OAuthConfig{ .callback_port = o.callback_port };
        if (o.client_id) |s| oc.client_id = try allocator.dupe(u8, s);
        if (o.auth_server_metadata_url) |s| oc.auth_server_metadata_url = try allocator.dupe(u8, s);
        out.oauth = oc;
    }
    if (src.plugin_source) |p| out.plugin_source = try allocator.dupe(u8, p);
    return out;
}

/// Deep-copy a slice of `ServerConfig`. The returned slice is owned and must be
/// freed with `freeServerConfigs`.
pub fn cloneServerConfigs(allocator: std.mem.Allocator, src: []const ServerConfig) ![]ServerConfig {
    if (src.len == 0) return &.{};
    const out = try allocator.alloc(ServerConfig, src.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |*s| s.deinit(allocator);
        allocator.free(out);
    }
    for (src, 0..) |*s, i| {
        out[i] = try cloneServerConfig(allocator, s);
        filled = i + 1;
    }
    return out;
}

fn freeValidationErrors(allocator: std.mem.Allocator, errors: []ValidationError) void {
    for (errors) |*e| e.deinit(allocator);
    if (errors.len > 0) allocator.free(errors);
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Map an explicit `type` string to `TransportType`. Returns null for an
/// unknown value (caller emits a warning per mcp-12). Mirrors
/// `services/mcp/types.ts:23-177`.
fn transportTypeFromString(s: []const u8) ?TransportType {
    if (std.mem.eql(u8, s, "stdio")) return .stdio;
    if (std.mem.eql(u8, s, "sse")) return .sse;
    if (std.mem.eql(u8, s, "http")) return .http;
    // The reference treats "sse-ide"/"ws-ide" as remote variants; we collapse
    // the websocket family to .ws.
    if (std.mem.eql(u8, s, "ws") or std.mem.eql(u8, s, "websocket")) return .ws;
    if (std.mem.eql(u8, s, "sdk")) return .sdk;
    return null;
}

const Accum = struct {
    servers: std.array_list.Managed(ServerConfig),
    errors: std.array_list.Managed(ValidationError),

    fn init(allocator: std.mem.Allocator) Accum {
        return .{
            .servers = std.array_list.Managed(ServerConfig).init(allocator),
            .errors = std.array_list.Managed(ValidationError).init(allocator),
        };
    }

    fn deinitFree(self: *Accum, allocator: std.mem.Allocator) void {
        for (self.servers.items) |*s| s.deinit(allocator);
        self.servers.deinit();
        for (self.errors.items) |*e| e.deinit(allocator);
        self.errors.deinit();
    }

    fn addError(
        self: *Accum,
        allocator: std.mem.Allocator,
        scope: ConfigScope,
        server_name: ?[]const u8,
        severity: Severity,
        comptime fmt: []const u8,
        fmt_args: anytype,
    ) !void {
        const msg = try std.fmt.allocPrint(allocator, fmt, fmt_args);
        errdefer allocator.free(msg);
        const owned_name = if (server_name) |n| try allocator.dupe(u8, n) else null;
        errdefer if (owned_name) |n| allocator.free(n);
        try self.errors.append(.{
            .scope = scope,
            .server_name = owned_name,
            .message = msg,
            .severity = severity,
        });
    }

    fn finish(self: *Accum) !ParseResult {
        const servers = try self.servers.toOwnedSlice();
        const errors = try self.errors.toOwnedSlice();
        return .{ .servers = servers, .errors = errors };
    }
};

fn dupEnvEntries(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]EnvEntry {
    if (obj.count() == 0) return &.{};
    var list = std.array_list.Managed(EnvEntry).init(allocator);
    errdefer {
        for (list.items) |*e| {
            allocator.free(e.key);
            allocator.free(e.value);
        }
        list.deinit();
    }
    var it = obj.iterator();
    while (it.next()) |entry| {
        const val = switch (entry.value_ptr.*) {
            .string => |s| s,
            else => continue, // non-string env values are ignored
        };
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key);
        const value = try allocator.dupe(u8, val);
        try list.append(.{ .key = key, .value = value });
    }
    return list.toOwnedSlice();
}

fn dupHeaderEntries(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]HeaderEntry {
    if (obj.count() == 0) return &.{};
    var list = std.array_list.Managed(HeaderEntry).init(allocator);
    errdefer {
        for (list.items) |*h| {
            allocator.free(h.key);
            allocator.free(h.value);
        }
        list.deinit();
    }
    var it = obj.iterator();
    while (it.next()) |entry| {
        const val = switch (entry.value_ptr.*) {
            .string => |s| s,
            else => continue,
        };
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key);
        const value = try allocator.dupe(u8, val);
        try list.append(.{ .key = key, .value = value });
    }
    return list.toOwnedSlice();
}

fn dupArgs(allocator: std.mem.Allocator, arr: std.json.Array) ![][]u8 {
    if (arr.items.len == 0) return &.{};
    var list = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (list.items) |a| allocator.free(a);
        list.deinit();
    }
    for (arr.items) |item| {
        const s = switch (item) {
            .string => |str| str,
            else => continue,
        };
        try list.append(try allocator.dupe(u8, s));
    }
    return list.toOwnedSlice();
}

fn parseOAuth(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !?OAuthConfig {
    var cfg = OAuthConfig{};
    errdefer cfg.deinit(allocator);
    var any = false;
    if (getString(obj, "clientId")) |s| {
        cfg.client_id = try allocator.dupe(u8, s);
        any = true;
    }
    if (getString(obj, "authServerMetadataUrl")) |s| {
        cfg.auth_server_metadata_url = try allocator.dupe(u8, s);
        any = true;
    }
    if (obj.get("callbackPort")) |v| {
        switch (v) {
            .integer => |n| {
                if (n >= 0 and n <= std.math.maxInt(u16)) {
                    cfg.callback_port = @intCast(n);
                    any = true;
                }
            },
            else => {},
        }
    }
    if (!any) {
        cfg.deinit(allocator);
        return null;
    }
    return cfg;
}

/// Parse one server object into a `ServerConfig`, appending to `acc`. A
/// per-server fatal problem (missing required field) records a fatal error
/// and skips the server, matching the reference's per-server granularity.
fn parseServerObject(
    allocator: std.mem.Allocator,
    acc: *Accum,
    scope: ConfigScope,
    name: []const u8,
    obj: std.json.ObjectMap,
) !void {
    // Determine transport type. Explicit `type` wins; otherwise infer .stdio
    // when `command` is present (backwards compat per types.ts:30); otherwise
    // infer .http when `url` is present. An unknown explicit `type` emits a
    // warning and falls back to the same inference.
    var ttype: TransportType = undefined;
    if (getString(obj, "type")) |type_str| {
        if (transportTypeFromString(type_str)) |known| {
            ttype = known;
        } else {
            try acc.addError(
                allocator,
                scope,
                name,
                .warning,
                "unknown transport type '{s}' for server '{s}'",
                .{ type_str, name },
            );
            ttype = inferTransportType(obj) orelse {
                try acc.addError(
                    allocator,
                    scope,
                    name,
                    .fatal,
                    "server '{s}' has unknown type and neither command nor url",
                    .{name},
                );
                return;
            };
        }
    } else {
        ttype = inferTransportType(obj) orelse {
            try acc.addError(
                allocator,
                scope,
                name,
                .fatal,
                "server '{s}' is missing both command and url",
                .{name},
            );
            return;
        };
    }
    return finalizeServer(allocator, acc, scope, name, obj, ttype);
}

/// Infer the transport type from presence of `command` (stdio) or `url`
/// (http). Returns null when neither is present.
fn inferTransportType(obj: std.json.ObjectMap) ?TransportType {
    if (getString(obj, "command") != null) return .stdio;
    if (getString(obj, "url") != null) return .http;
    return null;
}

/// Windows-specific footgun: on Windows, `npx` must be invoked through
/// `cmd /c npx ...` (a bare `npx` resolves to a `.cmd` shim that the raw
/// CreateProcess path will not find). Mirrors the reference's
/// `config.ts:1350-1369` warning. This is a pure predicate so it can be
/// asserted directly in a test on any platform; the warning is only emitted
/// when this build targets Windows (matching the reference's
/// platform-conditional emit).
///
/// Returns true when `command` is exactly `npx` (case-insensitive) and the
/// command/args do NOT already wrap it in `cmd /c`.
fn npxNeedsCmdWrapper(command: []const u8, args: []const []const u8) bool {
    // Already wrapped as `cmd /c ...`? Then no warning.
    if (std.ascii.eqlIgnoreCase(command, "cmd")) return false;
    if (!std.ascii.eqlIgnoreCase(command, "npx")) return false;
    // A defensive belt-and-suspenders: if the first arg is `npx` under a
    // `cmd`/`cmd.exe` command we already returned above; here `command` is
    // `npx` itself, so any args are npx args, not a wrapper. Warn.
    _ = args;
    return true;
}

fn finalizeServer(
    allocator: std.mem.Allocator,
    acc: *Accum,
    scope: ConfigScope,
    name: []const u8,
    obj: std.json.ObjectMap,
    ttype: TransportType,
) !void {
    // Validate required fields per transport family.
    if (ttype == .stdio or ttype == .sdk) {
        const cmd = getString(obj, "command");
        if (cmd == null or cmd.?.len == 0) {
            try acc.addError(
                allocator,
                scope,
                name,
                .fatal,
                "stdio server '{s}' is missing a non-empty command",
                .{name},
            );
            return;
        }
    } else {
        const url = getString(obj, "url");
        if (url == null or url.?.len == 0) {
            try acc.addError(
                allocator,
                scope,
                name,
                .fatal,
                "remote server '{s}' is missing a url",
                .{name},
            );
            return;
        }
    }

    var cfg = ServerConfig{
        .name = try allocator.dupe(u8, name),
        .scope = scope,
        .type = ttype,
    };
    errdefer cfg.deinit(allocator);

    if (getString(obj, "command")) |cmd| {
        cfg.command = try allocator.dupe(u8, cmd);
    }
    if (obj.get("args")) |args_v| {
        if (args_v == .array) cfg.args = try dupArgs(allocator, args_v.array);
    }
    if (obj.get("env")) |env_v| {
        if (env_v == .object) cfg.env = try dupEnvEntries(allocator, env_v.object);
    }
    if (getString(obj, "url")) |url| {
        cfg.url = try allocator.dupe(u8, url);
    }
    if (obj.get("headers")) |hdr_v| {
        if (hdr_v == .object) cfg.headers = try dupHeaderEntries(allocator, hdr_v.object);
    }
    if (getString(obj, "headersHelper")) |hh| {
        cfg.headers_helper = try allocator.dupe(u8, hh);
    }
    if (obj.get("oauth")) |oauth_v| {
        if (oauth_v == .object) cfg.oauth = try parseOAuth(allocator, oauth_v.object);
    }

    // Windows npx footgun (mcp-12): only emit when this build targets Windows,
    // mirroring the reference's platform-conditional warning. `cfg` is already
    // appended-shape, so reference its owned command/args.
    if (builtin.os.tag == .windows and (ttype == .stdio or ttype == .sdk)) {
        if (cfg.command) |cmd| {
            if (npxNeedsCmdWrapper(cmd, cfg.args)) {
                try acc.addError(
                    allocator,
                    scope,
                    name,
                    .warning,
                    "server '{s}' runs 'npx' directly on Windows; wrap it as `cmd /c npx ...` so the npx shim resolves",
                    .{name},
                );
            }
        }
    }

    try acc.servers.append(cfg);
}

/// Parse a `.mcp.json` body: `{ "mcpServers": { name: { ... } } }`. When
/// `expand_vars` is true, `${VAR}` / `${VAR:-default}` references in each
/// server's command/args/env/url/header values are expanded against the live
/// process environment and any missing-variable references are surfaced as
/// `warning`-severity `ValidationError`s (mcp-03, mirroring
/// `parseMcpConfigFromFilePath({ expandVars: true })`).
pub fn parseMcpJson(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    scope: ConfigScope,
    expand_vars: bool,
) !ParseResult {
    return parseMcpJsonWithLookup(allocator, bytes, scope, expand_vars, mcp_env_expand.realEnvLookup);
}

/// Same as `parseMcpJson` but with an injectable env lookup so the expansion
/// wiring is testable without touching the real process environment. The
/// `lookup` is only consulted when `expand_vars` is true.
pub fn parseMcpJsonWithLookup(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    scope: ConfigScope,
    expand_vars: bool,
    lookup: mcp_env_expand.Lookup,
) !ParseResult {
    var acc = Accum.init(allocator);
    errdefer acc.deinitFree(allocator);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| switch (err) {
        error.SyntaxError, error.UnexpectedToken, error.InvalidCharacter, error.UnexpectedEndOfInput => {
            try acc.addError(
                allocator,
                scope,
                null,
                .fatal,
                "config is not valid JSON ({s})",
                .{@errorName(err)},
            );
            return acc.finish();
        },
        else => return err,
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        try acc.addError(allocator, scope, null, .fatal, "config root is not a JSON object", .{});
        return acc.finish();
    }
    const root = parsed.value.object;
    const servers_v = root.get("mcpServers") orelse {
        // No mcpServers block -> no servers, not an error.
        return acc.finish();
    };
    if (servers_v != .object) {
        try acc.addError(allocator, scope, null, .fatal, "mcpServers is not a JSON object", .{});
        return acc.finish();
    }

    var it = servers_v.object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (entry.value_ptr.* != .object) {
            try acc.addError(
                allocator,
                scope,
                name,
                .fatal,
                "server '{s}' is not a JSON object",
                .{name},
            );
            continue;
        }
        try parseServerObject(allocator, &acc, scope, name, entry.value_ptr.*.object);
    }

    if (expand_vars) {
        try expandAccumServers(allocator, &acc, scope, lookup);
    }

    return acc.finish();
}

/// Expand env-var references in every parsed server (in place) and append a
/// `warning` for each distinct missing variable, tagged with the server name.
/// Mirrors `config.ts:1330-1345` surfacing of missing-var warnings.
fn expandAccumServers(
    allocator: std.mem.Allocator,
    acc: *Accum,
    scope: ConfigScope,
    lookup: mcp_env_expand.Lookup,
) !void {
    for (acc.servers.items) |*srv| {
        const missing = try mcp_env_expand.expandServerConfig(allocator, srv, lookup);
        defer {
            for (missing) |m| allocator.free(m);
            if (missing.len > 0) allocator.free(missing);
        }
        for (missing) |var_name| {
            try acc.addError(
                allocator,
                scope,
                srv.name,
                .warning,
                "missing environment variable '{s}' referenced in server '{s}'",
                .{ var_name, srv.name },
            );
        }
    }
}

/// Read and parse a single `.mcp.json` file at `path`. A missing file is not
/// an error (returns an empty result). A malformed one is surfaced as a fatal
/// `ValidationError`.
fn loadMcpJsonFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    scope: ConfigScope,
    expand_vars: bool,
) !ParseResult {
    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(MAX_MCP_JSON_BYTES)) catch |err| switch (err) {
        error.FileNotFound => {
            return .{ .servers = &.{}, .errors = &.{} };
        },
        error.StreamTooLong => {
            var acc = Accum.init(allocator);
            errdefer acc.deinitFree(allocator);
            try acc.addError(
                allocator,
                scope,
                null,
                .fatal,
                "config file is too large to load: {s}",
                .{path},
            );
            return acc.finish();
        },
        else => return err,
    };
    defer allocator.free(bytes);
    return parseMcpJson(allocator, bytes, scope, expand_vars);
}

/// Collect ancestor directories of `cwd` from `cwd` up to the filesystem
/// root, returned root-first (so the caller can process root-downward,
/// closest-wins). `cwd` must be absolute.
fn ancestorDirs(allocator: std.mem.Allocator, cwd: []const u8) ![][]u8 {
    var list = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (list.items) |d| allocator.free(d);
        list.deinit();
    }
    var current: []const u8 = cwd;
    while (true) {
        try list.append(try allocator.dupe(u8, current));
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = parent;
    }
    // list is cwd-first; reverse to root-first.
    std.mem.reverse([]u8, list.items);
    return list.toOwnedSlice();
}

/// Load all project-scope `.mcp.json` files by walking from `cwd` up to the
/// filesystem root, processing root-downward so a `.mcp.json` closer to CWD
/// overrides a parent's (closest-wins). `cwd` must be an absolute path.
/// Mirrors `getMcpConfigsByScope` project case (`config.ts:888-1026`).
pub fn loadProjectScope(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    expand_vars: bool,
) !ParseResult {
    var acc = Accum.init(allocator);
    errdefer acc.deinitFree(allocator);

    const dirs = try ancestorDirs(allocator, cwd);
    defer {
        for (dirs) |d| allocator.free(d);
        allocator.free(dirs);
    }

    // ordered map: server name -> index into acc.servers (closest-wins via
    // replace). Process root-downward so closer dirs overwrite parents.
    var index = std.StringHashMap(usize).init(allocator);
    defer index.deinit();

    for (dirs) |dir| {
        const json_path = try std.fs.path.join(allocator, &.{ dir, paths.mcpJsonName });
        defer allocator.free(json_path);

        const result = try loadMcpJsonFile(allocator, json_path, .project, expand_vars);
        // The server STRUCTS are moved into acc.servers; the backing slices
        // (result.servers / result.errors) are freed here. Errors are moved
        // element-wise into acc.errors.
        defer {
            if (result.servers.len > 0) allocator.free(result.servers);
            if (result.errors.len > 0) allocator.free(result.errors);
        }

        for (result.errors) |err| {
            try acc.errors.append(err);
        }

        for (result.servers) |srv| {
            if (index.get(srv.name)) |existing_idx| {
                // Replace the parent's entry with the closer one.
                acc.servers.items[existing_idx].deinit(allocator);
                acc.servers.items[existing_idx] = srv;
            } else {
                const key = srv.name; // stable: ServerConfig.name lives in acc
                try acc.servers.append(srv);
                try index.put(key, acc.servers.items.len - 1);
            }
        }
    }

    return acc.finish();
}

/// Load the enterprise managed `.mcp.json` (if present). When this returns a
/// non-empty result, enterprise takes exclusive control in `mergeScopes`.
/// Mirrors `config.ts:1071-1084`.
pub fn loadEnterpriseScope(allocator: std.mem.Allocator, expand_vars: bool) !ParseResult {
    const path = paths.enterpriseMcpPath(allocator) catch |err| switch (err) {
        else => return err,
    };
    defer allocator.free(path);
    return loadMcpJsonFile(allocator, path, .enterprise, expand_vars);
}

/// Whether an enterprise managed MCP file exists on disk. When true,
/// `mergeScopes` returns only enterprise servers (exclusive control).
pub fn enterpriseFileExists(allocator: std.mem.Allocator) bool {
    const path = paths.enterpriseMcpPath(allocator) catch return false;
    defer allocator.free(path);
    const cwd = std.Io.Dir.cwd();
    cwd.access(rt.io, path, .{}) catch return false;
    return true;
}

/// Inputs to the scope merge. A scope's servers and errors are MOVED into the
/// merged result; the caller must NOT free the input slices afterward (the
/// returned `ParseResult.deinit` owns everything). Pass `&.{}` for an absent
/// scope. Precedence: plugin < user < project < local (later wins).
pub const MergeInput = struct {
    enterprise: []ServerConfig = &.{},
    plugin: []ServerConfig = &.{},
    user: []ServerConfig = &.{},
    project: []ServerConfig = &.{},
    local: []ServerConfig = &.{},
    /// Errors collected during loading (moved into the merged result).
    errors: []ValidationError = &.{},
    /// When true, return only the enterprise servers (exclusive control),
    /// even if other scopes define servers. Set from `enterpriseFileExists`.
    enterprise_exclusive: bool = false,
    /// Optional enterprise allow/deny policy (mcp-05). When non-null, the merged
    /// servers are filtered through `mcp_policy.filterMcpServersByPolicy` after
    /// the precedence merge: policy-blocked servers are dropped and a
    /// `warning`-severity `ValidationError` is appended for each (matching
    /// `config.ts`'s post-merge policy filter). `sdk`-type servers are exempt.
    policy: ?*const mcp_policy.Policy = null,
    /// Optional per-project approval + enable/disable filter (mcp-06). When
    /// non-null, after the precedence merge (and after the policy filter)
    /// project-scope servers that are not `approved` are dropped, and any
    /// server (any scope) that `isMcpServerDisabled` reports disabled is
    /// dropped, with a `warning`-severity `ValidationError` appended for each.
    /// Mirrors the project-approval filter at `config.ts:1164-1170`.
    approval: ?ApprovalFilter = null,
    /// Plugin-provided MCP server dedup (mcp-11). When true, before the
    /// precedence merge the `plugin` servers are deduped against the combined
    /// manual servers (enterprise/user/project/local) and earlier-loaded plugin
    /// servers via `getMcpServerSignature`: a plugin server whose stdio-argv or
    /// url signature duplicates a manual or earlier-plugin server is dropped and
    /// reported as a `warning`-severity `ValidationError`. Manual servers always
    /// win; between two plugins the first-loaded wins. Mirrors
    /// `dedupPluginMcpServers` (`services/mcp/config.ts:223-266`).
    dedup_plugins: bool = false,
};

/// Inputs for the post-merge approval/disable filter (mcp-06). Borrows the
/// project-approval and toggle settings (no ownership transfer); valid for the
/// duration of the `mergeScopes` call.
pub const ApprovalFilter = struct {
    project_settings: *const mcp_approval.ProjectApprovalSettings,
    toggles: *const mcp_approval.ToggleSettings,
    mode: mcp_approval.RunMode,
};

/// Merge scopes by precedence. If `enterprise_exclusive`, return only the
/// enterprise servers (and free everything else). Otherwise merge
/// plugin < user < project < local (later wins on key collision). Mirrors
/// `config.ts:1231-1238` and the enterprise carve-out at `config.ts:1084`.
///
/// Ownership: every `ServerConfig` in the inputs is either moved into the
/// returned result or freed here. The caller frees the returned
/// `ParseResult` only.
pub fn mergeScopes(allocator: std.mem.Allocator, input: MergeInput) !ParseResult {
    var acc = Accum.init(allocator);
    errdefer acc.deinitFree(allocator);

    // Move all collected errors into the result.
    for (input.errors) |e| try acc.errors.append(e);
    if (input.errors.len > 0) allocator.free(input.errors);

    // ordered name -> index for later-wins replace.
    var index = std.StringHashMap(usize).init(allocator);
    defer index.deinit();

    const mergeOne = struct {
        fn run(
            a: std.mem.Allocator,
            ac: *Accum,
            idx: *std.StringHashMap(usize),
            scope_servers: []ServerConfig,
        ) !void {
            for (scope_servers) |srv| {
                if (idx.get(srv.name)) |existing| {
                    var old = ac.servers.items[existing];
                    old.deinit(a);
                    ac.servers.items[existing] = srv;
                } else {
                    try ac.servers.append(srv);
                    try idx.put(srv.name, ac.servers.items.len - 1);
                }
            }
            if (scope_servers.len > 0) a.free(scope_servers);
        }
    }.run;

    if (input.enterprise_exclusive) {
        // Enterprise exclusive: keep only enterprise, free the rest.
        try mergeOne(allocator, &acc, &index, input.enterprise);
        freeServerConfigs(allocator, input.plugin);
        freeServerConfigs(allocator, input.user);
        freeServerConfigs(allocator, input.project);
        freeServerConfigs(allocator, input.local);
        return finishMerged(allocator, &acc, input);
    }

    // Plugin dedup (mcp-11): drop plugin servers whose signature duplicates a
    // manual (enterprise/user/project/local) or earlier-plugin server. Runs
    // before the precedence merge so the surviving plugin servers are merged at
    // the lowest precedence below. Each suppression is surfaced as a warning.
    var plugin_servers = input.plugin;
    if (input.dedup_plugins and input.plugin.len > 0) {
        const manual = try concatManual(allocator, input);
        defer allocator.free(manual);
        const dedup = try dedupPluginMcpServers(allocator, input.plugin, manual);
        // `servers` are moved into the merge below; only `suppressed` is freed
        // here (after we have emitted a warning per suppressed server).
        defer {
            for (dedup.suppressed) |*s| s.deinit(allocator);
            if (dedup.suppressed.len > 0) allocator.free(dedup.suppressed);
        }
        for (dedup.suppressed) |s| {
            try acc.addError(
                allocator,
                .dynamic,
                s.name,
                .warning,
                "plugin mcp server '{s}' suppressed (duplicate of '{s}')",
                .{ s.name, s.duplicate_of },
            );
        }
        plugin_servers = dedup.servers;
    }

    // Enterprise (when not exclusive) is still merged first if non-empty, then
    // the precedence chain plugin < user < project < local.
    try mergeOne(allocator, &acc, &index, input.enterprise);
    try mergeOne(allocator, &acc, &index, plugin_servers);
    try mergeOne(allocator, &acc, &index, input.user);
    try mergeOne(allocator, &acc, &index, input.project);
    try mergeOne(allocator, &acc, &index, input.local);

    return finishMerged(allocator, &acc, input);
}

/// Build a borrowed view (a freshly-allocated slice of borrowed `ServerConfig`
/// values) over all manual servers (enterprise + user + project + local), used
/// as the dedup seed. The returned slice's elements are NOT owned (they alias
/// the input scopes, which `mergeScopes` still owns and merges); free only the
/// backing slice with `allocator.free`.
fn concatManual(allocator: std.mem.Allocator, input: MergeInput) ![]ServerConfig {
    const total = input.enterprise.len + input.user.len + input.project.len + input.local.len;
    var out = try allocator.alloc(ServerConfig, total);
    var i: usize = 0;
    for (input.enterprise) |s| {
        out[i] = s;
        i += 1;
    }
    for (input.user) |s| {
        out[i] = s;
        i += 1;
    }
    for (input.project) |s| {
        out[i] = s;
        i += 1;
    }
    for (input.local) |s| {
        out[i] = s;
        i += 1;
    }
    return out;
}

/// Finalize the accumulator, applying the enterprise allow/deny policy and the
/// per-project approval/disable filter when supplied. Blocked or unapproved
/// servers are removed from the merged result and a `warning`-severity
/// `ValidationError` is appended for each, naming the dropped server.
fn finishMerged(
    allocator: std.mem.Allocator,
    acc: *Accum,
    input: MergeInput,
) !ParseResult {
    var result = try acc.finish();
    errdefer result.deinit(allocator);

    // 1. Enterprise allow/deny policy (mcp-05).
    if (input.policy) |pol| {
        var filtered = try mcp_policy.filterMcpServersByPolicy(allocator, pol, &result.servers);
        defer filtered.deinit(allocator);
        try appendDropWarnings(
            allocator,
            &result,
            .enterprise,
            filtered.blocked,
            "mcp server '{s}' blocked by enterprise policy",
        );
    }

    // 2. Per-project approval + enable/disable filter (mcp-06).
    if (input.approval) |ap| {
        var drop = try mcp_approval.filterProjectServers(
            allocator,
            &result.servers,
            ap.project_settings,
            ap.toggles,
            ap.mode,
        );
        defer drop.deinit(allocator);
        try appendDropWarnings(
            allocator,
            &result,
            .project,
            drop.dropped,
            "mcp server '{s}' not approved or disabled; not connecting",
        );
    }

    return result;
}

/// Append one `warning`-severity `ValidationError` per dropped server name,
/// growing `result.errors` in place. The old errors backing slice is freed and
/// replaced with the larger one.
fn appendDropWarnings(
    allocator: std.mem.Allocator,
    result: *ParseResult,
    scope: ConfigScope,
    dropped: []const []const u8,
    comptime fmt: []const u8,
) !void {
    if (dropped.len == 0) return;

    var errs = std.array_list.Managed(ValidationError).init(allocator);
    errdefer {
        for (errs.items) |*e| e.deinit(allocator);
        errs.deinit();
    }
    for (result.errors) |e| try errs.append(e);
    for (dropped) |name| {
        const msg = try std.fmt.allocPrint(allocator, fmt, .{name});
        errdefer allocator.free(msg);
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        try errs.append(.{
            .scope = scope,
            .server_name = owned_name,
            .message = msg,
            .severity = .warning,
        });
    }
    // The old errors backing slice has been element-wise moved into `errs`.
    if (result.errors.len > 0) allocator.free(result.errors);
    result.errors = try errs.toOwnedSlice();
}

/// Convert a single legacy `{name, transport}` entry into a structured
/// `ServerConfig` at the given scope. A transport beginning with a URL scheme
/// (http/https/ws/wss) becomes a remote server; anything else becomes stdio
/// with `command = transport` (whitespace tokenization into command+args is
/// the spawn layer's job in Task 2, so here we keep the whole transport in
/// `command`). Mirrors the legacy-import note in the plan.
pub fn legacyServerToConfig(
    allocator: std.mem.Allocator,
    name: []const u8,
    transport: []const u8,
    scope: ConfigScope,
) !ServerConfig {
    const is_http = std.mem.startsWith(u8, transport, "http://") or
        std.mem.startsWith(u8, transport, "https://");
    const is_ws = std.mem.startsWith(u8, transport, "ws://") or
        std.mem.startsWith(u8, transport, "wss://");

    var cfg = ServerConfig{
        .name = try allocator.dupe(u8, name),
        .scope = scope,
        .type = if (is_ws) .ws else if (is_http) .http else .stdio,
    };
    errdefer cfg.deinit(allocator);

    if (is_http or is_ws) {
        cfg.url = try allocator.dupe(u8, transport);
    } else {
        cfg.command = try allocator.dupe(u8, transport);
    }
    return cfg;
}

/// Import a legacy registry body (`[{name, transport}, ...]`) into structured
/// `ServerConfig`s at the user scope. Used as a one-time bridge so existing
/// `mcp add`-registered servers are not lost. A malformed registry yields a
/// fatal error and no servers.
pub fn importLegacyRegistry(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    scope: ConfigScope,
) !ParseResult {
    var acc = Accum.init(allocator);
    errdefer acc.deinitFree(allocator);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| switch (err) {
        error.SyntaxError, error.UnexpectedToken, error.InvalidCharacter, error.UnexpectedEndOfInput => {
            try acc.addError(allocator, scope, null, .fatal, "legacy registry is not valid JSON ({s})", .{@errorName(err)});
            return acc.finish();
        },
        else => return err,
    };
    defer parsed.deinit();

    if (parsed.value != .array) return acc.finish();

    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const name = getString(item.object, "name") orelse continue;
        const transport = getString(item.object, "transport") orelse continue;
        const cfg = try legacyServerToConfig(allocator, name, transport, scope);
        try acc.servers.append(cfg);
    }

    return acc.finish();
}

// ----------------------------------------------------------------------------
// Plugin / agent-frontmatter server dedup (mcp-11)
// ----------------------------------------------------------------------------

/// Compute a dedup signature for a server config. A stdio server signs as
/// `stdio:` followed by the JSON array `[command, ...args]`; a remote server
/// signs as `url:` followed by its url; an `sdk` server has no signature
/// (returns null). The caller owns the returned slice. Mirrors
/// `getMcpServerSignature` (`services/mcp/config.ts:202-212`).
///
/// Note: the reference unwraps a CCR-proxy URL before signing. zcode has no
/// such proxy, so the url is used verbatim (a minor, documented divergence).
pub fn getMcpServerSignature(allocator: std.mem.Allocator, cfg: *const ServerConfig) !?[]u8 {
    switch (cfg.type) {
        .sdk => return null,
        .stdio => {
            // Build `[command, ...args]` and JSON-encode it so two servers with
            // the same argv string-match identically regardless of map order.
            var argv = std.array_list.Managed([]const u8).init(allocator);
            defer argv.deinit();
            try argv.append(cfg.command orelse "");
            for (cfg.args) |a| try argv.append(a);

            var buf = std_io.StringBuilder.init(allocator);
            defer buf.deinit();
            try buf.writer().writeAll("stdio:");
            try std.json.Stringify.value(argv.items, .{}, buf.writer());
            return try buf.toOwnedSlice();
        },
        .sse, .http, .ws => {
            const url = cfg.url orelse "";
            return try std.fmt.allocPrint(allocator, "url:{s}", .{url});
        },
    }
}

/// A plugin server suppressed by dedup, with the name of the manual or earlier
/// plugin server it duplicates. Both names are owned by the caller.
pub const SuppressedServer = struct {
    name: []u8,
    duplicate_of: []u8,

    pub fn deinit(self: *SuppressedServer, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.duplicate_of);
        self.* = undefined;
    }
};

/// Result of `dedupPluginMcpServers`. `servers` are the kept plugin servers
/// (MOVED out of the input slice); `suppressed` is the list of dropped plugin
/// servers with their duplicate-of attribution. The caller owns and frees both.
pub const DedupResult = struct {
    servers: []ServerConfig,
    suppressed: []SuppressedServer,

    pub fn deinit(self: *DedupResult, allocator: std.mem.Allocator) void {
        freeServerConfigs(allocator, self.servers);
        for (self.suppressed) |*s| s.deinit(allocator);
        if (self.suppressed.len > 0) allocator.free(self.suppressed);
        self.* = undefined;
    }
};

/// Drop plugin-provided servers whose signature duplicates a manual server or
/// an earlier-kept plugin server. Manual servers always win; between two
/// plugins the first-loaded wins. Suppressed servers are freed (not returned in
/// `servers`) and reported in `suppressed`. The input `plugin_servers` slice is
/// consumed: kept entries are moved into the result, dropped entries are freed,
/// and the backing slice is freed. The `manual_servers` slice is borrowed (not
/// modified or freed). Mirrors `dedupPluginMcpServers`
/// (`services/mcp/config.ts:223-266`).
pub fn dedupPluginMcpServers(
    allocator: std.mem.Allocator,
    plugin_servers: []ServerConfig,
    manual_servers: []const ServerConfig,
) !DedupResult {
    // Map signature -> owning server name. First-wins, so manual signatures are
    // inserted first and never overwritten; earlier plugins also win over later.
    var seen = std.StringHashMap([]const u8).init(allocator);
    // The signature keys are owned by `owned_sigs` and freed at the end.
    var owned_sigs = std.array_list.Managed([]u8).init(allocator);
    defer {
        seen.deinit();
        for (owned_sigs.items) |s| allocator.free(s);
        owned_sigs.deinit();
    }

    // Seed with manual servers (manual wins).
    for (manual_servers) |*m| {
        const sig = (try getMcpServerSignature(allocator, m)) orelse continue;
        if (seen.contains(sig)) {
            allocator.free(sig);
            continue;
        }
        try owned_sigs.append(sig);
        try seen.put(sig, m.name);
    }

    var kept = std.array_list.Managed(ServerConfig).init(allocator);
    errdefer {
        for (kept.items) |*s| s.deinit(allocator);
        kept.deinit();
    }
    var suppressed = std.array_list.Managed(SuppressedServer).init(allocator);
    errdefer {
        for (suppressed.items) |*s| s.deinit(allocator);
        suppressed.deinit();
    }

    for (plugin_servers) |srv| {
        var moved = srv;
        const sig = getMcpServerSignature(allocator, &moved) catch |err| {
            moved.deinit(allocator);
            return err;
        };
        if (sig) |s| {
            if (seen.get(s)) |dup_of| {
                // Duplicate: suppress this plugin server.
                allocator.free(s);
                const dup_name = allocator.dupe(u8, moved.name) catch |err| {
                    moved.deinit(allocator);
                    return err;
                };
                const dup_of_name = allocator.dupe(u8, dup_of) catch |err| {
                    allocator.free(dup_name);
                    moved.deinit(allocator);
                    return err;
                };
                suppressed.append(.{ .name = dup_name, .duplicate_of = dup_of_name }) catch |err| {
                    allocator.free(dup_name);
                    allocator.free(dup_of_name);
                    moved.deinit(allocator);
                    return err;
                };
                moved.deinit(allocator);
                continue;
            }
            // Keep: record its signature so later plugins dedup against it.
            try owned_sigs.append(s);
            try seen.put(s, moved.name);
        }
        kept.append(moved) catch |err| {
            moved.deinit(allocator);
            return err;
        };
    }

    if (plugin_servers.len > 0) allocator.free(plugin_servers);

    return .{
        .servers = try kept.toOwnedSlice(),
        .suppressed = try suppressed.toOwnedSlice(),
    };
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

fn findServer(servers: []ServerConfig, name: []const u8) ?*ServerConfig {
    for (servers) |*s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

test "parseMcpJson: stdio + http servers parse with right type, fields, scope" {
    const allocator = testing.allocator;
    const body =
        \\{
        \\  "mcpServers": {
        \\    "fs": {
        \\      "command": "node",
        \\      "args": ["server.js", "--port", "3000"],
        \\      "env": { "TOKEN": "abc" }
        \\    },
        \\    "api": {
        \\      "type": "http",
        \\      "url": "https://api.example.com/mcp",
        \\      "headers": { "X-Key": "v" }
        \\    }
        \\  }
        \\}
    ;
    var result = try parseMcpJson(allocator, body, .project, false);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
    try testing.expectEqual(@as(usize, 2), result.servers.len);

    const fs = findServer(result.servers, "fs").?;
    try testing.expectEqual(TransportType.stdio, fs.type);
    try testing.expectEqual(ConfigScope.project, fs.scope);
    try testing.expectEqualStrings("node", fs.command.?);
    try testing.expectEqual(@as(usize, 3), fs.args.len);
    try testing.expectEqualStrings("--port", fs.args[1]);
    try testing.expectEqual(@as(usize, 1), fs.env.len);
    try testing.expectEqualStrings("TOKEN", fs.env[0].key);
    try testing.expectEqualStrings("abc", fs.env[0].value);

    const api = findServer(result.servers, "api").?;
    try testing.expectEqual(TransportType.http, api.type);
    try testing.expectEqualStrings("https://api.example.com/mcp", api.url.?);
    try testing.expectEqual(@as(usize, 1), api.headers.len);
    try testing.expectEqualStrings("X-Key", api.headers[0].key);
}

test "parseMcpJson: infers stdio from command when type absent" {
    const allocator = testing.allocator;
    const body =
        \\{ "mcpServers": { "x": { "command": "/bin/echo" } } }
    ;
    var result = try parseMcpJson(allocator, body, .user, false);
    defer result.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), result.servers.len);
    try testing.expectEqual(TransportType.stdio, result.servers[0].type);
}

test "parseMcpJson: stdio missing command is a fatal error and skipped" {
    const allocator = testing.allocator;
    const body =
        \\{ "mcpServers": { "bad": { "type": "stdio" } } }
    ;
    var result = try parseMcpJson(allocator, body, .project, false);
    defer result.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), result.servers.len);
    try testing.expectEqual(@as(usize, 1), result.errors.len);
    try testing.expectEqual(Severity.fatal, result.errors[0].severity);
}

test "loadProjectScope: closest .mcp.json wins (child overrides parent)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // parent/.mcp.json and parent/child/.mcp.json both define "foo".
    try tmp.dir.createDirPath(rt.io, "child");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".mcp.json",
        .data =
        \\{ "mcpServers": { "foo": { "command": "parent-cmd" } } }
        ,
    });
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "child/.mcp.json",
        .data =
        \\{ "mcpServers": { "foo": { "command": "child-cmd" } } }
        ,
    });

    const child_path = try @import("test_helpers.zig").tmpDirPath(allocator, &tmp, "child");
    defer allocator.free(child_path);

    var result = try loadProjectScope(allocator, child_path, false);
    defer result.deinit(allocator);

    const foo = findServer(result.servers, "foo").?;
    try testing.expectEqualStrings("child-cmd", foo.command.?);
}

test "mergeScopes: enterprise exclusive returns only enterprise servers" {
    const allocator = testing.allocator;

    var ent = try parseMcpJson(allocator,
        \\{ "mcpServers": { "ent": { "command": "e" } } }
    , .enterprise, false);
    var usr = try parseMcpJson(allocator,
        \\{ "mcpServers": { "u": { "command": "u" } } }
    , .user, false);
    var proj = try parseMcpJson(allocator,
        \\{ "mcpServers": { "p": { "command": "p" } } }
    , .project, false);

    // mergeScopes consumes the slices; clear errors first (they are empty).
    ent.errors = &.{};
    usr.errors = &.{};
    proj.errors = &.{};

    var merged = try mergeScopes(allocator, .{
        .enterprise = ent.servers,
        .user = usr.servers,
        .project = proj.servers,
        .enterprise_exclusive = true,
    });
    defer merged.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), merged.servers.len);
    try testing.expectEqualStrings("ent", merged.servers[0].name);
}

test "mergeScopes: precedence plugin < user < project < local (later wins)" {
    const allocator = testing.allocator;

    var plugin = try parseMcpJson(allocator,
        \\{ "mcpServers": { "shared": { "command": "from-plugin" }, "ponly": { "command": "p" } } }
    , .user, false);
    var local = try parseMcpJson(allocator,
        \\{ "mcpServers": { "shared": { "command": "from-local" } } }
    , .local, false);
    plugin.errors = &.{};
    local.errors = &.{};

    var merged = try mergeScopes(allocator, .{
        .plugin = plugin.servers,
        .local = local.servers,
    });
    defer merged.deinit(allocator);

    const shared = findServer(merged.servers, "shared").?;
    try testing.expectEqualStrings("from-local", shared.command.?);
    try testing.expect(findServer(merged.servers, "ponly") != null);
}

test "mergeScopes: policy filter drops blocked server and warns" {
    const allocator = testing.allocator;

    var user = try parseMcpJson(allocator,
        \\{ "mcpServers": { "keep": { "command": "k" }, "drop": { "command": "d" } } }
    , .user, false);
    user.errors = &.{};

    // Allowlist names only "keep"; "drop" is blocked by the (non-empty,
    // command-entry-free) allowlist via name-based allowance.
    var allowed = try allocator.alloc(mcp_policy.McpServerEntry, 1);
    allowed[0] = mcp_policy.McpServerEntry{ .name = try allocator.dupe(u8, "keep") };
    var policy = mcp_policy.Policy{ .allowed = allowed };
    defer policy.deinit(allocator);

    var merged = try mergeScopes(allocator, .{
        .user = user.servers,
        .policy = &policy,
    });
    defer merged.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), merged.servers.len);
    try testing.expectEqualStrings("keep", merged.servers[0].name);

    // One warning naming the dropped server.
    try testing.expectEqual(@as(usize, 1), merged.errors.len);
    try testing.expectEqual(Severity.warning, merged.errors[0].severity);
    try testing.expectEqualStrings("drop", merged.errors[0].server_name.?);
}

test "mergeScopes: approval filter drops pending project server, keeps approved" {
    const allocator = testing.allocator;

    // Two project servers ("approved" enabled, "pending" not), plus a
    // user-scope server that approval never gates.
    var project = try parseMcpJson(allocator,
        \\{ "mcpServers": { "approved": { "command": "a" }, "pending": { "command": "p" } } }
    , .project, false);
    var user = try parseMcpJson(allocator,
        \\{ "mcpServers": { "u": { "command": "u" } } }
    , .user, false);
    project.errors = &.{};
    user.errors = &.{};

    const project_settings = mcp_approval.ProjectApprovalSettings{
        .enabled_mcpjson_servers = &.{"approved"},
    };
    const toggles = mcp_approval.ToggleSettings{};

    var merged = try mergeScopes(allocator, .{
        .project = project.servers,
        .user = user.servers,
        .approval = .{
            .project_settings = &project_settings,
            .toggles = &toggles,
            .mode = .interactive,
        },
    });
    defer merged.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), merged.servers.len);
    try testing.expect(findServer(merged.servers, "approved") != null);
    try testing.expect(findServer(merged.servers, "u") != null);
    try testing.expect(findServer(merged.servers, "pending") == null);

    // A warning naming the dropped project server.
    try testing.expectEqual(@as(usize, 1), merged.errors.len);
    try testing.expectEqual(Severity.warning, merged.errors[0].severity);
    try testing.expectEqualStrings("pending", merged.errors[0].server_name.?);
}

test "importLegacyRegistry: {name, transport} -> structured (url => remote, else stdio)" {
    const allocator = testing.allocator;
    const body =
        \\[
        \\  {"name":"local","transport":"python -m server"},
        \\  {"name":"remote","transport":"https://mcp.example.com/sse"}
        \\]
    ;
    var result = try importLegacyRegistry(allocator, body, .user);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), result.servers.len);

    const local = findServer(result.servers, "local").?;
    try testing.expectEqual(TransportType.stdio, local.type);
    try testing.expectEqualStrings("python -m server", local.command.?);
    try testing.expect(local.url == null);

    const remote = findServer(result.servers, "remote").?;
    try testing.expectEqual(TransportType.http, remote.type);
    try testing.expectEqualStrings("https://mcp.example.com/sse", remote.url.?);
    try testing.expect(remote.command == null);
}

const ExpandTestEnv = struct {
    var pairs: []const [2][]const u8 = &.{};

    fn lookup(name: []const u8) ?[]const u8 {
        for (pairs) |p| {
            if (std.mem.eql(u8, p[0], name)) return p[1];
        }
        return null;
    }
};

test "parseMcpJson: expand_vars rewrites fields and warns on a missing var" {
    const allocator = testing.allocator;
    ExpandTestEnv.pairs = &.{ .{ "HOST", "api.example.com" }, .{ "PORT", "8080" } };
    const body =
        \\{
        \\  "mcpServers": {
        \\    "api": {
        \\      "type": "http",
        \\      "url": "https://${HOST}:${PORT}/mcp",
        \\      "headers": { "Authorization": "Bearer ${MISSING_TOKEN}" }
        \\    }
        \\  }
        \\}
    ;
    var result = try parseMcpJsonWithLookup(allocator, body, .project, true, ExpandTestEnv.lookup);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.servers.len);
    const api = result.servers[0];
    try testing.expectEqualStrings("https://api.example.com:8080/mcp", api.url.?);
    try testing.expectEqualStrings("Bearer ${MISSING_TOKEN}", api.headers[0].value);

    // One warning for the missing var.
    try testing.expectEqual(@as(usize, 1), result.errors.len);
    try testing.expectEqual(Severity.warning, result.errors[0].severity);
}

test "parseMcpJson: expand_vars=false leaves ${VAR} literal (no expansion)" {
    const allocator = testing.allocator;
    ExpandTestEnv.pairs = &.{.{ "HOST", "api.example.com" }};
    const body =
        \\{ "mcpServers": { "api": { "type": "http", "url": "https://${HOST}/mcp" } } }
    ;
    var result = try parseMcpJsonWithLookup(allocator, body, .project, false, ExpandTestEnv.lookup);
    defer result.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), result.servers.len);
    try testing.expectEqualStrings("https://${HOST}/mcp", result.servers[0].url.?);
    try testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "ServerConfig deinit frees all owned fields (no leak)" {
    const allocator = testing.allocator;
    var result = try parseMcpJson(allocator,
        \\{ "mcpServers": { "full": {
        \\  "type": "http",
        \\  "url": "https://x.example/mcp",
        \\  "headers": { "A": "1", "B": "2" },
        \\  "headersHelper": "echo {}",
        \\  "oauth": { "clientId": "cid", "callbackPort": 9090 }
        \\} } }
    , .project, false);
    defer result.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), result.servers.len);
    const s = result.servers[0];
    try testing.expectEqualStrings("cid", s.oauth.?.client_id.?);
    try testing.expectEqual(@as(u16, 9090), s.oauth.?.callback_port.?);
    try testing.expectEqual(@as(usize, 2), s.headers.len);
}

// ---- Task 10 (mcp-11): signature + plugin dedup -------------------------

test "getMcpServerSignature: stdio json-argv, url, null for sdk" {
    const allocator = testing.allocator;

    // stdio: signature is `stdio:` + JSON of [command, ...args].
    var stdio = try parseMcpJson(allocator,
        \\{ "mcpServers": { "x": { "command": "npx", "args": ["-y", "x"] } } }
    , .project, false);
    defer stdio.deinit(allocator);
    const sig_stdio = (try getMcpServerSignature(allocator, &stdio.servers[0])).?;
    defer allocator.free(sig_stdio);
    try testing.expectEqualStrings("stdio:[\"npx\",\"-y\",\"x\"]", sig_stdio);

    // remote: signature is `url:` + url.
    var remote = try parseMcpJson(allocator,
        \\{ "mcpServers": { "y": { "type": "http", "url": "https://api.example.com/mcp" } } }
    , .project, false);
    defer remote.deinit(allocator);
    const sig_url = (try getMcpServerSignature(allocator, &remote.servers[0])).?;
    defer allocator.free(sig_url);
    try testing.expectEqualStrings("url:https://api.example.com/mcp", sig_url);

    // sdk: no signature.
    var sdk = ServerConfig{
        .name = try allocator.dupe(u8, "s"),
        .scope = .user,
        .type = .sdk,
        .command = try allocator.dupe(u8, "irrelevant"),
    };
    defer sdk.deinit(allocator);
    try testing.expect((try getMcpServerSignature(allocator, &sdk)) == null);
}

test "dedupPluginMcpServers: manual wins, first-plugin wins, suppression reported" {
    const allocator = testing.allocator;

    // A manual server with the same stdio argv as a plugin server.
    var manual = try parseMcpJson(allocator,
        \\{ "mcpServers": { "manual": { "command": "npx", "args": ["-y", "shared"] } } }
    , .user, false);
    defer manual.deinit(allocator);

    // Three plugin servers: "dup-of-manual" duplicates the manual argv;
    // "first" and "second" share an argv (first kept, second suppressed);
    // "unique" survives.
    const plugins_parsed = try parseMcpJson(allocator,
        \\{ "mcpServers": {
        \\  "dup-of-manual": { "command": "npx", "args": ["-y", "shared"] },
        \\  "first": { "command": "node", "args": ["a.js"] },
        \\  "second": { "command": "node", "args": ["a.js"] },
        \\  "unique": { "command": "node", "args": ["b.js"] }
        \\} }
    , .dynamic, false);
    // dedup consumes the servers slice; take it out first and free only the
    // (empty) errors slice so we don't free or poison the servers we hand off.
    const plugin_servers = plugins_parsed.servers;
    if (plugins_parsed.errors.len > 0) allocator.free(plugins_parsed.errors);

    var dedup = try dedupPluginMcpServers(allocator, plugin_servers, manual.servers);
    defer dedup.deinit(allocator);

    // "dup-of-manual" and "second" suppressed; "first" + "unique" kept.
    try testing.expectEqual(@as(usize, 2), dedup.servers.len);
    try testing.expect(findServer(dedup.servers, "first") != null);
    try testing.expect(findServer(dedup.servers, "unique") != null);
    try testing.expect(findServer(dedup.servers, "dup-of-manual") == null);
    try testing.expect(findServer(dedup.servers, "second") == null);

    try testing.expectEqual(@as(usize, 2), dedup.suppressed.len);
    // Attribution: dup-of-manual -> manual; second -> first.
    var saw_manual = false;
    var saw_first = false;
    for (dedup.suppressed) |s| {
        if (std.mem.eql(u8, s.name, "dup-of-manual")) {
            try testing.expectEqualStrings("manual", s.duplicate_of);
            saw_manual = true;
        }
        if (std.mem.eql(u8, s.name, "second")) {
            try testing.expectEqualStrings("first", s.duplicate_of);
            saw_first = true;
        }
    }
    try testing.expect(saw_manual and saw_first);
}

test "mergeScopes: dedup_plugins drops plugin server duplicating a manual one" {
    const allocator = testing.allocator;

    var plugin = try parseMcpJson(allocator,
        \\{ "mcpServers": { "plugin:p:dup": { "command": "node", "args": ["x.js"] } } }
    , .dynamic, false);
    var user = try parseMcpJson(allocator,
        \\{ "mcpServers": { "manual": { "command": "node", "args": ["x.js"] } } }
    , .user, false);
    plugin.errors = &.{};
    user.errors = &.{};

    var merged = try mergeScopes(allocator, .{
        .plugin = plugin.servers,
        .user = user.servers,
        .dedup_plugins = true,
    });
    defer merged.deinit(allocator);

    // Only the manual server survives; the plugin duplicate is suppressed.
    try testing.expectEqual(@as(usize, 1), merged.servers.len);
    try testing.expectEqualStrings("manual", merged.servers[0].name);

    // One warning naming the suppressed plugin server.
    try testing.expectEqual(@as(usize, 1), merged.errors.len);
    try testing.expectEqual(Severity.warning, merged.errors[0].severity);
    try testing.expectEqualStrings("plugin:p:dup", merged.errors[0].server_name.?);
}

// --- Task 11 (mcp-12): structured parse-warning surfacing ---

test "parseMcpJson: unknown type is a warning but the server is kept (inferred)" {
    const allocator = testing.allocator;
    // Unknown explicit type, but a command is present so the type can be
    // inferred to stdio: the server must be kept and a warning emitted.
    const body =
        \\{ "mcpServers": { "weird": { "type": "telnet", "command": "/bin/echo" } } }
    ;
    var result = try parseMcpJson(allocator, body, .project, false);
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.servers.len);
    try testing.expectEqual(TransportType.stdio, result.servers[0].type);

    // Exactly one warning, naming the unknown type, at warning severity.
    try testing.expectEqual(@as(usize, 1), result.errors.len);
    try testing.expectEqual(Severity.warning, result.errors[0].severity);
    try testing.expect(std.mem.indexOf(u8, result.errors[0].message, "telnet") != null);
    try testing.expectEqualStrings("weird", result.errors[0].server_name.?);
}

test "npxNeedsCmdWrapper: bare npx warns, cmd-wrapped does not" {
    // Asserted directly so the predicate is covered on macOS (the emit itself
    // is gated on builtin.os.tag == .windows). Mirrors config.ts:1350-1369.
    try testing.expect(npxNeedsCmdWrapper("npx", &.{ "-y", "some-pkg" }));
    try testing.expect(npxNeedsCmdWrapper("NPX", &.{})); // case-insensitive
    // Already wrapped as `cmd /c npx ...` -> command is "cmd", no warning.
    try testing.expect(!npxNeedsCmdWrapper("cmd", &.{ "/c", "npx", "-y", "x" }));
    // A non-npx command never warns.
    try testing.expect(!npxNeedsCmdWrapper("node", &.{"server.js"}));
}

test "parseMcpJson: npx warning only emitted on Windows builds" {
    const allocator = testing.allocator;
    const body =
        \\{ "mcpServers": { "n": { "command": "npx", "args": ["-y", "x"] } } }
    ;
    var result = try parseMcpJson(allocator, body, .project, false);
    defer result.deinit(allocator);

    // Server kept regardless of platform.
    try testing.expectEqual(@as(usize, 1), result.servers.len);

    if (builtin.os.tag == .windows) {
        // On Windows the npx footgun warning is present.
        try testing.expectEqual(@as(usize, 1), result.errors.len);
        try testing.expectEqual(Severity.warning, result.errors[0].severity);
        try testing.expect(std.mem.indexOf(u8, result.errors[0].message, "npx") != null);
    } else {
        // On non-Windows builds no npx warning is emitted.
        try testing.expectEqual(@as(usize, 0), result.errors.len);
    }
}

test "mergeScopes: accumulates warnings across scopes" {
    const allocator = testing.allocator;

    // User scope contributes an unknown-type warning; project scope contributes
    // its own unknown-type warning. After merge, both warnings survive.
    var user = try parseMcpJson(allocator,
        \\{ "mcpServers": { "u": { "type": "bogus", "command": "/bin/echo" } } }
    , .user, false);
    var project = try parseMcpJson(allocator,
        \\{ "mcpServers": { "p": { "type": "nonsense", "command": "/bin/echo" } } }
    , .project, false);

    // Both scopes each produced exactly one warning before the merge.
    try testing.expectEqual(@as(usize, 1), user.errors.len);
    try testing.expectEqual(@as(usize, 1), project.errors.len);

    // mergeScopes moves each scope's errors into the result. Concatenate the two
    // scopes' error slices into one input slice (mergeScopes owns it afterward).
    const combined = try allocator.alloc(ValidationError, user.errors.len + project.errors.len);
    @memcpy(combined[0..user.errors.len], user.errors);
    @memcpy(combined[user.errors.len..], project.errors);
    // The element structs were moved; free only the now-empty backing slices.
    if (user.errors.len > 0) allocator.free(user.errors);
    if (project.errors.len > 0) allocator.free(project.errors);
    user.errors = &.{};
    project.errors = &.{};

    var merged = try mergeScopes(allocator, .{
        .user = user.servers,
        .project = project.servers,
        .errors = combined,
    });
    defer merged.deinit(allocator);

    // Both servers kept and both warnings accumulated.
    try testing.expectEqual(@as(usize, 2), merged.servers.len);
    try testing.expectEqual(@as(usize, 2), merged.errors.len);

    var saw_user = false;
    var saw_project = false;
    for (merged.errors) |e| {
        try testing.expectEqual(Severity.warning, e.severity);
        if (e.scope == .user) saw_user = true;
        if (e.scope == .project) saw_project = true;
    }
    try testing.expect(saw_user and saw_project);
}

test "renderValidationErrors: severity + scope prefixed, server name when present" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    const errs = [_]ValidationError{
        .{ .scope = .project, .server_name = @constCast("foo"), .message = @constCast("missing command"), .severity = .fatal },
        .{ .scope = .user, .server_name = null, .message = @constCast("config root is not a JSON object"), .severity = .warning },
    };
    try renderValidationErrors(&w, &errs);

    const out = w.buffered();
    // Fatal line: error prefix, scope label, server name, message.
    try testing.expect(std.mem.indexOf(u8, out, "error: mcp:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "project (.mcp.json)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "foo: missing command") != null);
    // Warning line without a server name.
    try testing.expect(std.mem.indexOf(u8, out, "warning: mcp:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[user] config root is not a JSON object") != null);
}
