const std = @import("std");
const rt = @import("zcode_runtime");
const clock = @import("core/clock.zig");
const std_io = @import("core/std_io.zig");
const config_mod = @import("core/config.zig");
const logger_mod = @import("core/logger.zig");
const policy_mod = @import("policy/policy.zig");
const session_store = @import("session/store.zig");
const session_mgmt = @import("session_mgmt.zig");
const mcp_client = @import("mcp/client.zig");
const browser_bridge_mod = @import("mcp/browser_bridge.zig");
const agents_mod = @import("core/agents.zig");
const commands_mod = @import("core/commands.zig");
const plugins_mod = @import("core/plugins.zig");
const trust_mod = @import("core/trust.zig");
const remote_daemon = @import("remote_daemon.zig");
const git_tool = @import("tools/git.zig");
const rbac = @import("policy/rbac.zig");
const oidc = @import("core/oidc.zig");
const jwks_cache = @import("core/jwks_cache.zig");

const ApiCapabilityProfile = enum {
    read_only,
    editor,
    full,
};

const ApiCapabilities = struct {
    profile: ApiCapabilityProfile,
    role: ?rbac.Role = null,

    fn fromConfigAndEnvironment(cfg: *const config_mod.Config) ApiCapabilities {
        const profile_raw: ?[]const u8 = if (cfg.api_profile.len > 0)
            cfg.api_profile
        else if (!cfg.isManagedLocked("api_profile"))
            @import("core/env.zig").getenv("ZCODE_API_PROFILE")
        else
            null;
        const profile = if (profile_raw) |raw|
            parseApiCapabilityProfile(raw) orelse .read_only
        else
            .full;
        const role_raw: ?[]const u8 = if (cfg.api_role.len > 0)
            cfg.api_role
        else if (!cfg.isManagedLocked("api_role"))
            @import("core/env.zig").getenv("ZCODE_API_ROLE")
        else
            null;
        const role = if (role_raw) |raw|
            parseApiRole(raw)
        else
            null;
        return .{ .profile = profile, .role = role };
    }

    fn fromProfile(profile: ApiCapabilityProfile) ApiCapabilities {
        return .{ .profile = profile };
    }

    fn fromProfileAndRole(profile: ApiCapabilityProfile, role: rbac.Role) ApiCapabilities {
        return .{ .profile = profile, .role = role };
    }

    fn name(self: ApiCapabilities) []const u8 {
        return switch (self.profile) {
            .read_only => "read-only",
            .editor => "editor",
            .full => "full",
        };
    }

    fn allows(self: ApiCapabilities, method: []const u8) bool {
        const read_only_methods = [_][]const u8{
            "status",
            "agents.list",
            "plugins.list",
            "commands.list",
            "session.list",
        };
        const editor_methods = [_][]const u8{
            "status",
            "run",
            "review",
            "diff.apply",
            "agents.list",
            "plugins.list",
            "commands.list",
            "session.list",
            "session.share",
            "session.import",
            "session.handoff",
        };
        const full_methods = [_][]const u8{
            "status",
            "run",
            "review",
            "diff.apply",
            "agents.list",
            "plugins.list",
            "commands.list",
            "session.list",
            "session.export",
            "session.share",
            "session.import",
            "session.handoff",
        };
        const profile_allows = switch (self.profile) {
            .read_only => methodIn(method, &read_only_methods),
            .editor => methodIn(method, &editor_methods),
            .full => methodIn(method, &full_methods),
        };
        if (!profile_allows) return false;
        if (self.role) |role| {
            return role.atLeast(requiredRoleForApiMethod(method));
        }
        return true;
    }
};

const ApiAuthSettings = struct {
    required: bool,
    bearer_token: []const u8,
    oidc_issuer: []const u8,
    oidc_audience: []const u8,
    oidc_hs256_secret: []const u8,
    oidc_jwks_json: []const u8,
    oidc_jwks_file: []const u8,
    oidc_jwks_url: []const u8,
    oidc_jwks_cache_ttl_seconds: u32,

    fn fromConfigAndEnvironment(cfg: *const config_mod.Config) ApiAuthSettings {
        return .{
            .required = cfg.api_auth_required or (!cfg.isManagedLocked("api_auth_required") and envTruthy("ZCODE_API_AUTH_REQUIRED")),
            .bearer_token = configOrEnvLocked(cfg, cfg.api_bearer_token, "api_bearer_token", "ZCODE_API_BEARER_TOKEN"),
            .oidc_issuer = configOrEnvLocked(cfg, cfg.api_oidc_issuer, "api_oidc_issuer", "ZCODE_API_OIDC_ISSUER"),
            .oidc_audience = configOrEnvLocked(cfg, cfg.api_oidc_audience, "api_oidc_audience", "ZCODE_API_OIDC_AUDIENCE"),
            .oidc_hs256_secret = configOrEnvLocked(cfg, cfg.api_oidc_hs256_secret, "api_oidc_hs256_secret", "ZCODE_API_OIDC_HS256_SECRET"),
            .oidc_jwks_json = configOrEnvLocked(cfg, cfg.api_oidc_jwks_json, "api_oidc_jwks_json", "ZCODE_API_OIDC_JWKS_JSON"),
            .oidc_jwks_file = configOrEnvLocked(cfg, cfg.api_oidc_jwks_file, "api_oidc_jwks_file", "ZCODE_API_OIDC_JWKS_FILE"),
            .oidc_jwks_url = configOrEnvLocked(cfg, cfg.api_oidc_jwks_url, "api_oidc_jwks_url", "ZCODE_API_OIDC_JWKS_URL"),
            .oidc_jwks_cache_ttl_seconds = configOrEnvU32Locked(
                cfg.api_oidc_jwks_cache_ttl_seconds,
                cfg.isManagedLocked("api_oidc_jwks_cache_ttl_seconds"),
                "ZCODE_API_OIDC_JWKS_CACHE_TTL_SECONDS",
            ),
        };
    }

    fn oidcConfigured(self: ApiAuthSettings) bool {
        return self.oidc_issuer.len > 0 and
            self.oidc_audience.len > 0 and
            (self.oidcHs256Configured() or self.oidcRs256Configured());
    }

    fn oidcHs256Configured(self: ApiAuthSettings) bool {
        return self.oidc_hs256_secret.len > 0;
    }

    fn oidcRs256Configured(self: ApiAuthSettings) bool {
        return self.oidc_jwks_json.len > 0 or self.oidc_jwks_file.len > 0 or self.oidc_jwks_url.len > 0;
    }
};

const ApiCredential = union(enum) {
    bearer: []const u8,
    id_token: []const u8,
};

fn configOrEnvLocked(cfg: *const config_mod.Config, config_value: []const u8, key: []const u8, env_name: []const u8) []const u8 {
    if (config_value.len > 0) return config_value;
    if (cfg.isManagedLocked(key)) return "";
    if (@import("core/env.zig").getenv(env_name)) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }
    return "";
}

fn configOrEnvU32Locked(config_value: u32, locked: bool, env_name: []const u8) u32 {
    if (!locked) {
        if (@import("core/env.zig").getenv(env_name)) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len > 0) {
                return std.fmt.parseInt(u32, trimmed, 10) catch config_value;
            }
        }
    }
    return config_value;
}

fn envTruthy(env_name: []const u8) bool {
    const raw = @import("core/env.zig").getenv(env_name) orelse return false;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return std.ascii.eqlIgnoreCase(trimmed, "1") or
        std.ascii.eqlIgnoreCase(trimmed, "true") or
        std.ascii.eqlIgnoreCase(trimmed, "yes") or
        std.ascii.eqlIgnoreCase(trimmed, "on");
}

fn methodIn(method: []const u8, methods: []const []const u8) bool {
    for (methods) |candidate| {
        if (std.mem.eql(u8, method, candidate)) return true;
    }
    return false;
}

fn parseApiCapabilityProfile(raw: []const u8) ?ApiCapabilityProfile {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "read-only") or std.ascii.eqlIgnoreCase(trimmed, "readonly")) return .read_only;
    if (std.ascii.eqlIgnoreCase(trimmed, "editor")) return .editor;
    if (std.ascii.eqlIgnoreCase(trimmed, "full")) return .full;
    return null;
}

fn parseApiRole(raw: []const u8) ?rbac.Role {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    const role = rbac.Role.fromString(trimmed);
    if (role == .none and !std.ascii.eqlIgnoreCase(trimmed, "none")) return null;
    return role;
}

fn requiredRoleForApiMethod(method: []const u8) rbac.Role {
    if (std.mem.eql(u8, method, "status")) return .viewer;
    if (std.mem.eql(u8, method, "agents.list")) return .viewer;
    if (std.mem.eql(u8, method, "plugins.list")) return .viewer;
    if (std.mem.eql(u8, method, "commands.list")) return .viewer;
    if (std.mem.eql(u8, method, "session.list")) return .viewer;
    if (std.mem.eql(u8, method, "review")) return .viewer;
    if (std.mem.eql(u8, method, "session.export")) return .auditor;
    if (std.mem.eql(u8, method, "run")) return .editor;
    if (std.mem.eql(u8, method, "diff.apply")) return .editor;
    if (std.mem.eql(u8, method, "session.share")) return .editor;
    if (std.mem.eql(u8, method, "session.import")) return .editor;
    if (std.mem.eql(u8, method, "session.handoff")) return .editor;
    return .owner;
}

pub fn cmdApiSchema(writer: anytype) !void {
    try writer.print("{f}\n", .{std.json.fmt(.{
        .protocol = "zcode-api/v1",
        .transport = "jsonl-stdio",
        .capability_env = "ZCODE_API_PROFILE",
        .role_env = "ZCODE_API_ROLE",
        .capability_profiles = &.{ "read-only", "editor", "full" },
        .roles = &.{ "viewer", "auditor", "editor", "owner" },
        .request_shape = .{
            .id = "string|number",
            .method = "string",
            .params = "object",
            .auth = "optional object: {bearer:string} or {id_token:string}",
        },
        .notification_shape = .{
            .event = "string",
            .ts = "unix timestamp",
            .method = "string",
        },
        .methods = &.{
            "status",
            "run",
            "review",
            "diff.apply",
            "agents.list",
            "plugins.list",
            "commands.list",
            "session.list",
            "session.export",
            "session.share",
            "session.import",
            "session.handoff",
        },
    }, .{})});
}

pub fn cmdApiServe(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    cfg: *const config_mod.Config,
    policy: *policy_mod.Policy,
    audit: *logger_mod.AuditLogger,
    store: *session_store.Store,
    mcp: *mcp_client.Client,
    browser: ?*browser_bridge_mod.BrowserBridge,
    writer: anytype,
) !void {
    const stdin = std_io.stdinReader();
    var reader = stdin;
    const capabilities = ApiCapabilities.fromConfigAndEnvironment(cfg);
    const auth_settings = ApiAuthSettings.fromConfigAndEnvironment(cfg);

    // Per-line cap (1 MiB) keeps a single malformed JSON-RPC request
    // bounded; total_cap (10 MiB) caps the whole stream so a hostile
    // client cannot stream many max-sized lines to drive memory use
    // arbitrarily high. On cap hit we emit a terminating error
    // envelope and close the loop rather than silently accepting or
    // crashing.
    const LINE_CAP: usize = 1024 * 1024;
    const TOTAL_CAP: usize = 10 * 1024 * 1024;
    var total_bytes: usize = 0;

    while (true) {
        const line_opt = reader.readUntilDelimiterOrEofAlloc(allocator, '\n', LINE_CAP) catch |err| switch (err) {
            error.StreamTooLong => {
                try writer.writeAll("{\"error\":\"RequestTooLarge\",\"limit_bytes\":1048576}\n");
                break;
            },
            else => return err,
        };
        defer if (line_opt) |line| allocator.free(line);
        const line = line_opt orelse break;

        total_bytes += line.len + 1; // +1 for the delimiter
        if (total_bytes > TOTAL_CAP) {
            try writer.writeAll("{\"error\":\"RequestTooLarge\",\"reason\":\"per-connection total exceeded\",\"limit_bytes\":10485760}\n");
            break;
        }

        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;

        const event_method = requestMethodName(allocator, trimmed) catch null;
        defer if (event_method) |method_name| allocator.free(method_name);
        const response = try handleRequest(allocator, cwd, cfg, policy, audit, store, mcp, browser, capabilities, auth_settings, trimmed);
        defer allocator.free(response);
        try writer.writeAll(response);
        try writer.writeByte('\n');
        if (event_method) |method_name| {
            try writeApiEvent(writer, "request.completed", method_name);
        }
    }
}

fn writeApiEvent(writer: anytype, event: []const u8, method: []const u8) !void {
    try writer.print("{f}\n", .{std.json.fmt(.{
        .event = event,
        .protocol = "zcode-api/v1",
        .method = method,
        .ts = clock.nowSeconds(),
    }, .{})});
}

fn requestMethodName(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const method = getString(parsed.value.object, "method") orelse return null;
    const duped = try allocator.dupe(u8, method);
    return duped;
}

fn handleRequest(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    cfg: *const config_mod.Config,
    policy: *policy_mod.Policy,
    audit: *logger_mod.AuditLogger,
    store: *session_store.Store,
    mcp: *mcp_client.Client,
    browser: ?*browser_bridge_mod.BrowserBridge,
    capabilities: ApiCapabilities,
    auth_settings: ApiAuthSettings,
    raw: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return encodeErrorResponse(allocator, "0", "invalid request object");

    const obj = parsed.value.object;
    const id_value = obj.get("id");
    const method = getString(obj, "method") orelse return encodeErrorResponse(allocator, "0", "missing method");
    const params = obj.get("params");

    const id = switch (id_value orelse .null) {
        .string => |s| s,
        .integer => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
        else => "0",
    };
    defer if (id_value != null and id_value.? == .integer) allocator.free(id);

    var effective_capabilities = capabilities;
    const principal_role = authenticateApiRequest(allocator, auth_settings, obj) catch {
        logApiSecurityEvent(allocator, audit, "api.auth.denied", method, capabilities, null, "unauthorized");
        return encodeErrorResponse(allocator, id, "unauthorized");
    };
    if (principal_role) |role| effective_capabilities.role = role;

    if (!effective_capabilities.allows(method)) {
        logApiSecurityEvent(allocator, audit, "api.method.denied", method, effective_capabilities, effective_capabilities.role, "capability_or_role_denied");
        const message = try std.fmt.allocPrint(allocator, "method not allowed by API capability profile '{s}'", .{effective_capabilities.name()});
        defer allocator.free(message);
        return encodeErrorResponse(allocator, id, message);
    }

    if (std.mem.eql(u8, method, "status")) {
        var trust_status = try trust_mod.status(allocator, cwd);
        defer trust_status.deinit(allocator);
        return encodeSuccessResponse(allocator, id, .{
            .cwd = cwd,
            .provider = cfg.default_provider,
            .model = cfg.default_model,
            .approval_mode = cfg.approval_mode,
            .sandbox = cfg.sandbox,
            .trusted = trust_status.trusted,
            .trust_source = trust_mod.sourceName(trust_status.source),
        });
    }

    if (std.mem.eql(u8, method, "run")) {
        const prompt = getParamString(params, "prompt") orelse return encodeErrorResponse(allocator, id, "missing prompt");
        const agent = getParamString(params, "agent");
        const json_mode = getParamBool(params, "json") orelse false;
        const one_shot = try session_mgmt.runOneShot(allocator, cwd, cfg, policy, audit, store, mcp, browser, prompt, json_mode, false, false, false, agent);
        defer allocator.free(one_shot.body);
        return encodeSuccessResponse(allocator, id, .{
            .output = one_shot.body,
            .strict_violation = one_shot.strict_violation,
        });
    }

    if (std.mem.eql(u8, method, "review")) {
        var out = std_io.StringBuilder.init(allocator);
        defer out.deinit();
        try session_mgmt.cmdReview(
            allocator,
            cwd,
            cfg,
            policy,
            audit,
            store,
            mcp,
            browser,
            getParamString(params, "target"),
            out.writer(),
            false,
            false,
            false,
            getParamString(params, "agent"),
        );
        return encodeSuccessResponse(allocator, id, .{ .output = out.items() });
    }

    if (std.mem.eql(u8, method, "diff.apply")) {
        const patch = getParamString(params, "patch") orelse return encodeErrorResponse(allocator, id, "missing patch");
        const output = try git_tool.applyPatch(allocator, cwd, patch);
        defer allocator.free(output);
        return encodeSuccessResponse(allocator, id, .{ .output = output });
    }

    if (std.mem.eql(u8, method, "agents.list")) {
        const rendered = try agents_mod.renderList(allocator, cwd, null);
        defer allocator.free(rendered);
        return encodeSuccessResponse(allocator, id, .{ .output = rendered });
    }

    if (std.mem.eql(u8, method, "plugins.list")) {
        const rendered = try plugins_mod.renderList(allocator, cwd);
        defer allocator.free(rendered);
        return encodeSuccessResponse(allocator, id, .{ .output = rendered });
    }

    if (std.mem.eql(u8, method, "commands.list")) {
        const rendered = try commands_mod.renderList(allocator, cwd);
        defer allocator.free(rendered);
        return encodeSuccessResponse(allocator, id, .{ .output = rendered });
    }

    if (std.mem.eql(u8, method, "session.list")) {
        const sessions = try store.list();
        defer store.freeSessionEntries(sessions);
        var out = std_io.StringBuilder.init(allocator);
        defer out.deinit();
        if (sessions.len == 0) {
            try out.writer().writeAll("no sessions\n");
        } else {
            for (sessions) |entry| {
                try out.writer().print("{s}\tupdated={d}\n", .{ entry.id, entry.updated_ts });
            }
        }
        return encodeSuccessResponse(allocator, id, .{
            .output = out.items(),
            .sessions = sessions,
        });
    }

    if (std.mem.eql(u8, method, "session.export")) {
        const session_id = getParamString(params, "session_id") orelse return encodeErrorResponse(allocator, id, "missing session_id");
        var out = std_io.StringBuilder.init(allocator);
        defer out.deinit();
        try session_mgmt.cmdSessionExport(allocator, store, session_id, false, out.writer());
        return encodeSuccessResponse(allocator, id, .{ .output = out.items() });
    }

    if (std.mem.eql(u8, method, "session.share")) {
        const session_id = getParamString(params, "session_id") orelse return encodeErrorResponse(allocator, id, "missing session_id");
        const label = getParamString(params, "label");
        var out = std_io.StringBuilder.init(allocator);
        defer out.deinit();
        try session_mgmt.cmdSessionShare(allocator, store, session_id, label, out.writer());
        return encodeSuccessResponse(allocator, id, .{ .output = out.items() });
    }

    if (std.mem.eql(u8, method, "session.import")) {
        const bundle = getParamString(params, "bundle") orelse return encodeErrorResponse(allocator, id, "missing bundle");
        var out = std_io.StringBuilder.init(allocator);
        defer out.deinit();
        try session_mgmt.cmdSessionImport(allocator, store, bundle, out.writer());
        return encodeSuccessResponse(allocator, id, .{ .output = out.items() });
    }

    if (std.mem.eql(u8, method, "session.handoff")) {
        const session_id = getParamString(params, "session_id") orelse return encodeErrorResponse(allocator, id, "missing session_id");
        const label = getParamString(params, "label");
        const output = try remote_daemon.handoff(allocator, store, session_id, label);
        defer allocator.free(output);
        return encodeSuccessResponse(allocator, id, .{ .output = output });
    }

    return encodeErrorResponse(allocator, id, "unknown method");
}

fn authenticateApiRequest(
    allocator: std.mem.Allocator,
    settings: ApiAuthSettings,
    obj: std.json.ObjectMap,
) !?rbac.Role {
    const credential = extractApiCredential(obj);
    if (credential == null) {
        if (settings.required) return error.ApiUnauthorized;
        return null;
    }

    switch (credential.?) {
        .bearer => |token| {
            if (settings.bearer_token.len > 0 and constantTimeBytesEql(token, settings.bearer_token)) {
                return null;
            }
            if (settings.oidcConfigured()) {
                return verifyOidcRole(allocator, settings, token) catch error.ApiUnauthorized;
            }
            return error.ApiUnauthorized;
        },
        .id_token => |token| {
            if (!settings.oidcConfigured()) return error.ApiUnauthorized;
            return verifyOidcRole(allocator, settings, token) catch error.ApiUnauthorized;
        },
    }
}

fn verifyOidcRole(
    allocator: std.mem.Allocator,
    settings: ApiAuthSettings,
    token: []const u8,
) !rbac.Role {
    const expect = oidc.Expectation{
        .issuer = settings.oidc_issuer,
        .audience = settings.oidc_audience,
        .now_unix = clock.nowSeconds(),
    };

    const hs_role: ?rbac.Role = hs: {
        if (!settings.oidcHs256Configured()) break :hs null;
        var claims = oidc.verifyHS256(allocator, token, expect, settings.oidc_hs256_secret) catch |err| switch (err) {
            error.UnsupportedAlg => break :hs null,
            else => return err,
        };
        defer claims.deinit(allocator);
        break :hs claims.role;
    };
    if (hs_role) |role| return role;

    if (settings.oidcRs256Configured()) {
        var jwks = try jwks_cache.loadEffective(
            allocator,
            settings.oidc_jwks_json,
            settings.oidc_jwks_file,
            settings.oidc_jwks_url,
            settings.oidc_jwks_cache_ttl_seconds,
        );
        defer jwks.deinit(allocator);
        var claims = try oidc.verifyRS256(allocator, token, expect, jwks.json);
        defer claims.deinit(allocator);
        return claims.role;
    }

    return error.ApiUnauthorized;
}

fn logApiSecurityEvent(
    allocator: std.mem.Allocator,
    audit: *logger_mod.AuditLogger,
    event: []const u8,
    method: []const u8,
    capabilities: ApiCapabilities,
    role: ?rbac.Role,
    reason: []const u8,
) void {
    const role_name = if (role) |r| r.toString() else "none";
    const payload = std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(.{
        .protocol = "zcode-api/v1",
        .method = method,
        .profile = capabilities.name(),
        .role = role_name,
        .reason = reason,
    }, .{})}) catch return;
    defer allocator.free(payload);
    audit.log(event, payload) catch |err| {
        std.log.warn("api audit event failed: {s}", .{@errorName(err)});
    };
}

fn extractApiCredential(obj: std.json.ObjectMap) ?ApiCredential {
    if (obj.get("auth")) |auth_value| {
        if (auth_value == .object) {
            if (getString(auth_value.object, "bearer")) |token| {
                return .{ .bearer = token };
            }
            if (getString(auth_value.object, "id_token")) |token| {
                return .{ .id_token = token };
            }
        }
    }
    if (getString(obj, "authorization")) |header| {
        const trimmed = std.mem.trim(u8, header, " \t\r\n");
        if (std.ascii.startsWithIgnoreCase(trimmed, "Bearer ")) {
            return .{ .bearer = std.mem.trim(u8, trimmed["Bearer ".len..], " \t\r\n") };
        }
    }
    if (getString(obj, "id_token")) |token| {
        return .{ .id_token = token };
    }
    return null;
}

fn constantTimeBytesEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

fn encodeSuccessResponse(allocator: std.mem.Allocator, id: []const u8, result: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(.{
        .id = id,
        .ok = true,
        .result = result,
    }, .{})});
}

fn encodeErrorResponse(allocator: std.mem.Allocator, id: []const u8, message: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(.{
        .id = id,
        .ok = false,
        .@"error" = message,
    }, .{})});
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getParamString(params: ?std.json.Value, key: []const u8) ?[]const u8 {
    const obj = params orelse return null;
    if (obj != .object) return null;
    return getString(obj.object, key);
}

fn getParamBool(params: ?std.json.Value, key: []const u8) ?bool {
    const obj = params orelse return null;
    if (obj != .object) return null;
    const value = obj.object.get(key) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

const testing = std.testing;

test "api schema includes review diff apply and session handoff methods" {
    var out = std_io.StringBuilder.init(testing.allocator);
    defer out.deinit();

    try cmdApiSchema(out.writer());
    try testing.expect(std.mem.indexOf(u8, out.items(), "run") != null);
    try testing.expect(std.mem.indexOf(u8, out.items(), "review") != null);
    try testing.expect(std.mem.indexOf(u8, out.items(), "diff.apply") != null);
    try testing.expect(std.mem.indexOf(u8, out.items(), "session.import") != null);
    try testing.expect(std.mem.indexOf(u8, out.items(), "session.handoff") != null);
    try testing.expect(std.mem.indexOf(u8, out.items(), "notification_shape") != null);
    try testing.expect(std.mem.indexOf(u8, out.items(), "ZCODE_API_PROFILE") != null);
}

test "requestMethodName extracts json rpc method for event stream" {
    const method = (try requestMethodName(testing.allocator, "{\"id\":1,\"method\":\"status\",\"params\":{}}")).?;
    defer testing.allocator.free(method);
    try testing.expectEqualStrings("status", method);
    try testing.expect((try requestMethodName(testing.allocator, "not-json")) == null);
}

test "api capability profiles restrict high-risk methods" {
    const read_only = ApiCapabilities.fromProfile(.read_only);
    try testing.expect(read_only.allows("status"));
    try testing.expect(read_only.allows("session.list"));
    try testing.expect(!read_only.allows("run"));
    try testing.expect(!read_only.allows("diff.apply"));
    try testing.expect(!read_only.allows("session.handoff"));

    const editor = ApiCapabilities.fromProfile(.editor);
    try testing.expect(editor.allows("run"));
    try testing.expect(editor.allows("diff.apply"));
    try testing.expect(editor.allows("session.handoff"));
    try testing.expect(!editor.allows("session.export"));

    const full = ApiCapabilities.fromProfile(.full);
    try testing.expect(full.allows("session.export"));
}

test "api capability profile parser accepts aliases" {
    try testing.expect(parseApiCapabilityProfile("read-only") == .read_only);
    try testing.expect(parseApiCapabilityProfile("readonly") == .read_only);
    try testing.expect(parseApiCapabilityProfile("EDITOR") == .editor);
    try testing.expect(parseApiCapabilityProfile("full") == .full);
    try testing.expect(parseApiCapabilityProfile("unknown") == null);
}

test "api role parser accepts known roles only" {
    try testing.expectEqual(rbac.Role.viewer, parseApiRole("viewer").?);
    try testing.expectEqual(rbac.Role.auditor, parseApiRole("AUDITOR").?);
    try testing.expectEqual(rbac.Role.none, parseApiRole("none").?);
    try testing.expect(parseApiRole("unknown") == null);
}

test "api role gates methods after profile allows them" {
    const viewer = ApiCapabilities.fromProfileAndRole(.full, .viewer);
    try testing.expect(viewer.allows("status"));
    try testing.expect(viewer.allows("review"));
    try testing.expect(!viewer.allows("run"));
    try testing.expect(!viewer.allows("session.export"));

    const auditor = ApiCapabilities.fromProfileAndRole(.full, .auditor);
    try testing.expect(auditor.allows("session.export"));
    try testing.expect(!auditor.allows("diff.apply"));

    const editor = ApiCapabilities.fromProfileAndRole(.editor, .editor);
    try testing.expect(editor.allows("run"));
    try testing.expect(editor.allows("session.share"));
    try testing.expect(!editor.allows("session.export"));

    const role_allows_but_profile_denies = ApiCapabilities.fromProfileAndRole(.read_only, .owner);
    try testing.expect(!role_allows_but_profile_denies.allows("run"));
}

test "api auth accepts configured bearer token and rejects missing credentials" {
    const settings = ApiAuthSettings{
        .required = true,
        .bearer_token = "secret-token",
        .oidc_issuer = "",
        .oidc_audience = "",
        .oidc_hs256_secret = "",
        .oidc_jwks_json = "",
        .oidc_jwks_file = "",
        .oidc_jwks_url = "",
        .oidc_jwks_cache_ttl_seconds = 3600,
    };

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"id":1,"method":"status","auth":{"bearer":"secret-token"}}
    , .{});
    defer parsed.deinit();
    try testing.expect((try authenticateApiRequest(testing.allocator, settings, parsed.value.object)) == null);

    var missing = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"id":1,"method":"status"}
    , .{});
    defer missing.deinit();
    try testing.expectError(error.ApiUnauthorized, authenticateApiRequest(testing.allocator, settings, missing.value.object));
}

test "api auth derives role from HS256 OIDC token" {
    const token = try makeTestHS256Jwt(testing.allocator,
        \\{"sub":"alice","iss":"https://issuer.example","aud":"zcode","exp":9999999999,"role":"viewer"}
    , "shared-secret");
    defer testing.allocator.free(token);

    const request = try std.fmt.allocPrint(testing.allocator,
        \\{{"id":1,"method":"status","auth":{{"id_token":"{s}"}}}}
    , .{token});
    defer testing.allocator.free(request);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, request, .{});
    defer parsed.deinit();

    const role = try authenticateApiRequest(testing.allocator, .{
        .required = true,
        .bearer_token = "",
        .oidc_issuer = "https://issuer.example",
        .oidc_audience = "zcode",
        .oidc_hs256_secret = "shared-secret", // sast: allow - test fixture, not a real credential
        .oidc_jwks_json = "",
        .oidc_jwks_file = "",
        .oidc_jwks_url = "",
        .oidc_jwks_cache_ttl_seconds = 3600,
    }, parsed.value.object);
    try testing.expectEqual(rbac.Role.viewer, role.?);
}

test "api auth derives role from RS256 OIDC token" {
    const request = try std.fmt.allocPrint(testing.allocator,
        \\{{"id":1,"method":"status","auth":{{"id_token":"{s}"}}}}
    , .{staticRS256Jwt()});
    defer testing.allocator.free(request);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, request, .{});
    defer parsed.deinit();

    const role = try authenticateApiRequest(testing.allocator, .{
        .required = true,
        .bearer_token = "",
        .oidc_issuer = "https://issuer.example",
        .oidc_audience = "zcode",
        .oidc_hs256_secret = "",
        .oidc_jwks_json = staticRS256Jwks(),
        .oidc_jwks_file = "",
        .oidc_jwks_url = "",
        .oidc_jwks_cache_ttl_seconds = 3600,
    }, parsed.value.object);
    try testing.expectEqual(rbac.Role.owner, role.?);
}

test "api security audit event excludes credential material" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const log_dir = try @import("core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(log_dir);

    var audit = try logger_mod.AuditLogger.initWithRetention(testing.allocator, log_dir, 90);
    defer audit.deinit();

    logApiSecurityEvent(
        testing.allocator,
        &audit,
        "api.auth.denied",
        "run",
        ApiCapabilities.fromProfile(.editor),
        null,
        "unauthorized",
    );

    const bucket = @divTrunc(clock.nowSeconds(), 86_400);
    const filename = try std.fmt.allocPrint(testing.allocator, "audit-{d}.jsonl", .{bucket});
    defer testing.allocator.free(filename);
    const log_path = try std.fs.path.join(testing.allocator, &.{ log_dir, filename });
    defer testing.allocator.free(log_path);
    const raw = try std.Io.Dir.cwd().readFileAlloc(rt.io, log_path, testing.allocator, .limited(16 * 1024));
    defer testing.allocator.free(raw);

    try testing.expect(std.mem.indexOf(u8, raw, "api.auth.denied") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "zcode-api/v1") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "unauthorized") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "secret-token") == null);
    try testing.expect(std.mem.indexOf(u8, raw, "id_token") == null);
}

fn staticRS256Jwt() []const u8 {
    return "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InRlc3QtcnNhLTEifQ." ++
        "eyJzdWIiOiJhbGljZSIsImlzcyI6Imh0dHBzOi8vaXNzdWVyLmV4YW1wbGUiLCJhdWQiOlsib3RoZXIiLCJ6Y29kZSJdLCJleHAiOjk5OTk5OTk5OTksInJvbGUiOiJvd25lciJ9." ++
        "Nz_xtHSCJNyW0aU_EhwrjgXzdzwfYfNUI8rgCNMDPy-COCx264fIrErGWr8X0VvS8o1zXyclRyKLfQBvp79-gDlDCjyBc2He6qxDPBb4DE6QuZ6jPqPfUjdJDIPMST1I9DL5dNXFj4DFCH6nTsmyJf5Dsn_uyvQDMFDt9Ih0Hn21dkBlOtZ1U2abEwE85VhsGCFkWSCPf9zSN0D1w4elVYoTeyLATpQDgBGnF4fu7JGDPt6RVPxu5CwYd94Fvee3JMZ65AFzp9QWX7RX31MVOMfsud_zqiFx15hZloEjf1F2g3A3HvBpc4wwraytBrQ3E5tD-ZG5T5VCxojLKJSqWQ";
}

fn staticRS256Jwks() []const u8 {
    return "{\"keys\":[{\"kty\":\"RSA\",\"kid\":\"test-rsa-1\",\"use\":\"sig\",\"alg\":\"RS256\",\"n\":\"vD2-3dYzJz5dDz_daBKq3MZw_QFbYzIWVkCp7mdly6O8xFMUxM0br6GkL33RZYRzm0GKSs3wGT0PVAaH1MGvv09hQvyWvEWvj4k4Sd6weuTXpvgNN1i28_2ARE7qoLe8ZYZijtwg7Lz2EBNOj8zgeuFyKU65ITGRaIO0JhMHKKlAJfrbwWF8X42KrjFz-K-r0I8CtLbFBWe9NpvLHFsqnBiZ_5KS_36Xygv7tgVo_gWhUaTz3zFvP_Ng_Q2tQ4wNUS5g1PFgheQTIU5hi54f-JvAM55NHKMjBSco9ZR_4y-4YHOpeI9STaWmb0PejOjlXPKDe6oFV4c7wgSe3-FPWw\",\"e\":\"AQAB\"}]}";
}

fn makeTestHS256Jwt(allocator: std.mem.Allocator, payload_json: []const u8, secret: []const u8) ![]u8 {
    const header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    const header_b = try testBase64UrlEncode(allocator, header);
    defer allocator.free(header_b);
    const payload_b = try testBase64UrlEncode(allocator, payload_json);
    defer allocator.free(payload_b);
    const signing_input = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header_b, payload_b });
    defer allocator.free(signing_input);

    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var sig: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&sig, signing_input, secret);
    const sig_b = try testBase64UrlEncode(allocator, &sig);
    defer allocator.free(sig_b);
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ signing_input, sig_b });
}

fn testBase64UrlEncode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const encoded_len = encoder.calcSize(input.len);
    const out = try allocator.alloc(u8, encoded_len);
    _ = encoder.encode(out, input);
    return out;
}
