const std = @import("std");
const std_io = @import("../core/std_io.zig");
const rt = @import("zcode_runtime");
const rng = @import("../core/rng.zig");
const clock = @import("../core/clock.zig");
const http_common = @import("../providers/common.zig");
const egress = @import("../core/egress.zig");

const default_callback_port: u16 = 8765;
const default_timeout_seconds: i32 = 120;
const http_timeout_ms: u32 = 20_000;

pub const OAuthResult = struct {
    access_token: []u8,
    refresh_token: ?[]u8 = null,
    expires_ts: ?i64 = null,
    callback_url: []u8,
    auth_url: []u8,
    client_id: ?[]u8 = null,
    token_endpoint: ?[]u8 = null,

    pub fn deinit(self: *OAuthResult, allocator: std.mem.Allocator) void {
        allocator.free(self.access_token);
        if (self.refresh_token) |value| allocator.free(value);
        allocator.free(self.callback_url);
        allocator.free(self.auth_url);
        if (self.client_id) |value| allocator.free(value);
        if (self.token_endpoint) |value| allocator.free(value);
    }
};

pub const OAuthRefreshResult = struct {
    access_token: []u8,
    refresh_token: ?[]u8 = null,
    expires_ts: ?i64 = null,

    pub fn deinit(self: *OAuthRefreshResult, allocator: std.mem.Allocator) void {
        allocator.free(self.access_token);
        if (self.refresh_token) |value| allocator.free(value);
    }
};

pub const OAuthProviderFailure = struct {
    error_code: []u8,
    description: ?[]u8 = null,
    callback_url: []u8,
    auth_url: []u8,

    pub fn deinit(self: *OAuthProviderFailure, allocator: std.mem.Allocator) void {
        allocator.free(self.error_code);
        if (self.description) |value| allocator.free(value);
        allocator.free(self.callback_url);
        allocator.free(self.auth_url);
    }
};

pub const OAuthLoginOutcome = union(enum) {
    success: OAuthResult,
    provider_error: OAuthProviderFailure,

    pub fn deinit(self: *OAuthLoginOutcome, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .success => |*result| result.deinit(allocator),
            .provider_error => |*failure| failure.deinit(allocator),
        }
    }
};

const DiscoveryInfo = struct {
    resource_url: []u8,
    scope: []u8,
    authorization_endpoint: []u8,
    token_endpoint: []u8,
    registration_endpoint: ?[]u8 = null,

    fn deinit(self: *DiscoveryInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.resource_url);
        allocator.free(self.scope);
        allocator.free(self.authorization_endpoint);
        allocator.free(self.token_endpoint);
        if (self.registration_endpoint) |value| allocator.free(value);
    }
};

const ClientRegistration = struct {
    client_id: []u8,

    fn deinit(self: *ClientRegistration, allocator: std.mem.Allocator) void {
        allocator.free(self.client_id);
    }
};

const CallbackPayload = union(enum) {
    token_success: struct {
        access_token: []u8,
        refresh_token: ?[]u8 = null,
        expires_ts: ?i64 = null,
    },
    code_success: struct {
        code: []u8,
        state: []u8,
    },
    provider_error: struct {
        error_code: []u8,
        description: ?[]u8 = null,
    },

    fn deinit(self: *CallbackPayload, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .token_success => |*ok| {
                allocator.free(ok.access_token);
                if (ok.refresh_token) |value| allocator.free(value);
            },
            .code_success => |*ok| {
                allocator.free(ok.code);
                allocator.free(ok.state);
            },
            .provider_error => |*failure| {
                allocator.free(failure.error_code);
                if (failure.description) |value| allocator.free(value);
            },
        }
    }
};

pub fn loginViaBrowser(allocator: std.mem.Allocator, url_template: []const u8) !OAuthLoginOutcome {
    const callback_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/callback", .{default_callback_port});
    errdefer allocator.free(callback_url);
    const auth_url = if (std.mem.indexOf(u8, url_template, "{{callback_url}}") != null)
        try std.mem.replaceOwned(u8, allocator, url_template, "{{callback_url}}", callback_url)
    else
        try allocator.dupe(u8, url_template);
    errdefer allocator.free(auth_url);

    const _addr: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = default_callback_port } };
    var server = try _addr.listen(rt.io, .{ .reuse_address = true });
    defer server.deinit(rt.io);

    try openBrowserUrl(allocator, auth_url);

    const stream = try acceptWithTimeout(&server, default_timeout_seconds * 1000);
    defer stream.close(rt.io);

    const request = try readHttpRequest(allocator, stream);
    defer allocator.free(request);

    const query = requestQuery(request) orelse return error.McpOAuthMissingQuery;
    var payload = try parseCallbackPayload(allocator, query);
    errdefer payload.deinit(allocator);

    switch (payload) {
        .token_success => |ok| {
            try writeHttpResponse(stream, "zcode MCP auth completed. You can return to the terminal.");
            return .{ .success = .{
                .access_token = ok.access_token,
                .refresh_token = ok.refresh_token,
                .expires_ts = ok.expires_ts,
                .callback_url = callback_url,
                .auth_url = auth_url,
            } };
        },
        .provider_error => |failure| {
            try writeHttpResponse(stream, "zcode MCP auth failed. You can return to the terminal for details.");
            return .{ .provider_error = .{
                .error_code = failure.error_code,
                .description = failure.description,
                .callback_url = callback_url,
                .auth_url = auth_url,
            } };
        },
        .code_success => return error.McpOAuthMissingToken,
    }
}

pub fn loginForMcpServer(allocator: std.mem.Allocator, transport_url: []const u8) !OAuthLoginOutcome {
    var discovery = try discoverServerAuth(allocator, transport_url);
    defer discovery.deinit(allocator);

    var registration = try registerPublicClient(allocator, discovery.registration_endpoint orelse return error.McpOAuthRegistrationUnsupported);
    defer registration.deinit(allocator);

    const callback_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/callback", .{default_callback_port});
    errdefer allocator.free(callback_url);

    const state = try randomUrlToken(allocator, 24);
    defer allocator.free(state);
    const verifier = try randomUrlToken(allocator, 48);
    defer allocator.free(verifier);
    const challenge = try pkceChallenge(allocator, verifier);
    defer allocator.free(challenge);

    const auth_url = try buildAuthorizationUrl(
        allocator,
        discovery.authorization_endpoint,
        registration.client_id,
        callback_url,
        discovery.scope,
        state,
        challenge,
        discovery.resource_url,
    );
    errdefer allocator.free(auth_url);

    const _addr2: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = default_callback_port } };
    var server = try _addr2.listen(rt.io, .{ .reuse_address = true });
    defer server.deinit(rt.io);

    try openBrowserUrl(allocator, auth_url);

    const stream = try acceptWithTimeout(&server, default_timeout_seconds * 1000);
    defer stream.close(rt.io);

    const request = try readHttpRequest(allocator, stream);
    defer allocator.free(request);

    const query = requestQuery(request) orelse return error.McpOAuthMissingQuery;
    var payload = try parseCallbackPayload(allocator, query);
    errdefer payload.deinit(allocator);

    switch (payload) {
        .provider_error => |failure| {
            try writeHttpResponse(stream, "zcode MCP auth failed. You can return to the terminal for details.");
            return .{ .provider_error = .{
                .error_code = failure.error_code,
                .description = failure.description,
                .callback_url = callback_url,
                .auth_url = auth_url,
            } };
        },
        .code_success => |code_payload| {
            if (!std.mem.eql(u8, code_payload.state, state)) {
                try writeHttpResponse(stream, "zcode MCP auth failed. State mismatch.");
                return error.McpOAuthStateMismatch;
            }

            var exchanged = try exchangeAuthorizationCode(
                allocator,
                discovery.token_endpoint,
                registration.client_id,
                callback_url,
                code_payload.code,
                verifier,
            );
            defer exchanged.deinit(allocator);

            try writeHttpResponse(stream, "zcode MCP auth completed. You can return to the terminal.");
            return .{ .success = .{
                .access_token = try allocator.dupe(u8, exchanged.access_token),
                .refresh_token = if (exchanged.refresh_token) |value| try allocator.dupe(u8, value) else null,
                .expires_ts = exchanged.expires_ts,
                .callback_url = callback_url,
                .auth_url = auth_url,
                .client_id = try allocator.dupe(u8, registration.client_id),
                .token_endpoint = try allocator.dupe(u8, discovery.token_endpoint),
            } };
        },
        .token_success => return error.McpOAuthUnexpectedTokenFlow,
    }
}

pub fn refreshAccessToken(
    allocator: std.mem.Allocator,
    refresh_token: []const u8,
    client_id: []const u8,
    token_endpoint: []const u8,
) !OAuthRefreshResult {
    const body = try buildRefreshBody(allocator, refresh_token, client_id);
    defer allocator.free(body);

    const raw = try http_common.callHttp(
        allocator,
        .POST,
        token_endpoint,
        &.{"Content-Type: application/x-www-form-urlencoded"},
        body,
        http_timeout_ms,
    );
    defer allocator.free(raw);

    return parseTokenResponse(allocator, raw);
}

fn discoverServerAuth(allocator: std.mem.Allocator, transport_url: []const u8) !DiscoveryInfo {
    var unauthorized = try requestUnauthorizedChallenge(allocator, transport_url);
    defer unauthorized.deinit(allocator);

    const prm_url = if (unauthorized.resource_metadata_url) |value|
        value
    else
        return error.McpOAuthMissingResourceMetadata;

    const protected_resource_raw = try http_common.callHttp(allocator, .GET, prm_url, &.{}, null, http_timeout_ms);
    defer allocator.free(protected_resource_raw);

    var prm = try parseProtectedResourceMetadata(allocator, protected_resource_raw);
    defer prm.deinit(allocator);

    const auth_metadata_url = if (unauthorized.authorization_metadata_url) |value|
        try allocator.dupe(u8, value)
    else if (prm.authorization_server) |server_base|
        try joinWellKnownAuthorizationServer(allocator, server_base)
    else
        return error.McpOAuthMissingAuthorizationServer;
    defer allocator.free(auth_metadata_url);

    const auth_metadata_raw = try http_common.callHttp(allocator, .GET, auth_metadata_url, &.{}, null, http_timeout_ms);
    defer allocator.free(auth_metadata_raw);

    var metadata = try parseAuthorizationServerMetadata(allocator, auth_metadata_raw);
    defer metadata.deinit(allocator);

    return .{
        .resource_url = if (prm.resource_url) |value| try allocator.dupe(u8, value) else try allocator.dupe(u8, transport_url),
        .scope = if (unauthorized.scope.len > 0) try allocator.dupe(u8, unauthorized.scope) else if (prm.scope.len > 0) try allocator.dupe(u8, prm.scope) else try allocator.dupe(u8, "mcp:connect"),
        .authorization_endpoint = try allocator.dupe(u8, metadata.authorization_endpoint),
        .token_endpoint = try allocator.dupe(u8, metadata.token_endpoint),
        .registration_endpoint = if (metadata.registration_endpoint) |value| try allocator.dupe(u8, value) else null,
    };
}

const UnauthorizedChallenge = struct {
    resource_metadata_url: ?[]u8 = null,
    authorization_metadata_url: ?[]u8 = null,
    scope: []u8,

    fn deinit(self: *UnauthorizedChallenge, allocator: std.mem.Allocator) void {
        if (self.resource_metadata_url) |value| allocator.free(value);
        if (self.authorization_metadata_url) |value| allocator.free(value);
        allocator.free(self.scope);
    }
};

const ProtectedResourceMetadata = struct {
    resource_url: ?[]u8 = null,
    authorization_server: ?[]u8 = null,
    scope: []u8,

    fn deinit(self: *ProtectedResourceMetadata, allocator: std.mem.Allocator) void {
        if (self.resource_url) |value| allocator.free(value);
        if (self.authorization_server) |value| allocator.free(value);
        allocator.free(self.scope);
    }
};

const AuthorizationServerMetadata = struct {
    authorization_endpoint: []u8,
    token_endpoint: []u8,
    registration_endpoint: ?[]u8 = null,

    fn deinit(self: *AuthorizationServerMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.authorization_endpoint);
        allocator.free(self.token_endpoint);
        if (self.registration_endpoint) |value| allocator.free(value);
    }
};

fn requestUnauthorizedChallenge(allocator: std.mem.Allocator, transport_url: []const u8) !UnauthorizedChallenge {
    const probe_url = try httpProbeUrlForTransport(allocator, transport_url);
    defer allocator.free(probe_url);
    const body =
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"zcode\",\"version\":\"dev\"}}}";
    var response = try callHttpWithHeaders(allocator, .POST, probe_url, &.{
        "Content-Type: application/json",
        "Accept: application/json, text/event-stream",
    }, body);
    defer response.deinit(allocator);

    if (response.status_code != 401 and response.status_code != 403) return error.McpOAuthDiscoveryFailed;
    const challenge = response.headerValue("WWW-Authenticate") orelse return error.McpOAuthMissingWwwAuthenticate;
    return parseBearerChallenge(allocator, challenge);
}

fn httpProbeUrlForTransport(allocator: std.mem.Allocator, transport_url: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, transport_url, "ws://")) {
        return std.fmt.allocPrint(allocator, "http://{s}", .{transport_url["ws://".len..]});
    }
    if (std.mem.startsWith(u8, transport_url, "wss://")) {
        return std.fmt.allocPrint(allocator, "https://{s}", .{transport_url["wss://".len..]});
    }
    return allocator.dupe(u8, transport_url);
}

fn parseProtectedResourceMetadata(allocator: std.mem.Allocator, raw: []const u8) !ProtectedResourceMetadata {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidResponse;
    const authorization_servers = parsed.value.object.get("authorization_servers");
    const first_auth_server = if (authorization_servers) |servers|
        switch (servers) {
            .array => blk: {
                for (servers.array.items) |item| {
                    if (item == .string and item.string.len > 0) break :blk item.string;
                }
                break :blk null;
            },
            else => null,
        }
    else
        null;

    const scopes = if (parsed.value.object.get("scopes_supported")) |value|
        switch (value) {
            .array => blk: {
                for (value.array.items) |item| {
                    if (item == .string and item.string.len > 0) break :blk item.string;
                }
                break :blk "";
            },
            else => "",
        }
    else
        "";

    return .{
        .resource_url = if (getString(parsed.value.object, "resource")) |value| try allocator.dupe(u8, value) else null,
        .authorization_server = if (first_auth_server) |value| try allocator.dupe(u8, value) else null,
        .scope = try allocator.dupe(u8, scopes),
    };
}

fn parseAuthorizationServerMetadata(allocator: std.mem.Allocator, raw: []const u8) !AuthorizationServerMetadata {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidResponse;

    return .{
        .authorization_endpoint = try allocator.dupe(u8, getString(parsed.value.object, "authorization_endpoint") orelse return error.McpOAuthMissingAuthorizationEndpoint),
        .token_endpoint = try allocator.dupe(u8, getString(parsed.value.object, "token_endpoint") orelse return error.McpOAuthMissingTokenEndpoint),
        .registration_endpoint = if (getString(parsed.value.object, "registration_endpoint")) |value| try allocator.dupe(u8, value) else null,
    };
}

fn registerPublicClient(allocator: std.mem.Allocator, registration_endpoint: []const u8) !ClientRegistration {
    const body = try encodeJsonAlloc(allocator, .{
        .client_name = "zcode",
        .redirect_uris = &[_][]const u8{"http://127.0.0.1:8765/callback"},
        .grant_types = &[_][]const u8{ "authorization_code", "refresh_token" },
        .response_types = &[_][]const u8{"code"},
        .token_endpoint_auth_method = "none",
        .application_type = "native",
    });
    defer allocator.free(body);

    var response = try callHttpWithHeaders(allocator, .POST, registration_endpoint, &.{"Content-Type: application/json"}, body);
    defer response.deinit(allocator);

    if (response.status_code == 403) return error.McpOAuthRegistrationDenied;
    if (response.status_code >= 400) return error.McpOAuthRegistrationFailed;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;

    const client_id = getString(parsed.value.object, "client_id") orelse return error.McpOAuthMissingClientId;
    return .{ .client_id = try allocator.dupe(u8, client_id) };
}

fn buildAuthorizationUrl(
    allocator: std.mem.Allocator,
    authorization_endpoint: []const u8,
    client_id: []const u8,
    callback_url: []const u8,
    scope: []const u8,
    state: []const u8,
    challenge: []const u8,
    resource_url: []const u8,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    try out.appendSlice(authorization_endpoint);
    try out.append(if (std.mem.indexOfScalar(u8, authorization_endpoint, '?') == null) '?' else '&');
    try appendQueryParam(allocator, &out, "response_type", "code", false);
    try appendQueryParam(allocator, &out, "client_id", client_id, true);
    try appendQueryParam(allocator, &out, "redirect_uri", callback_url, true);
    try appendQueryParam(allocator, &out, "scope", scope, true);
    try appendQueryParam(allocator, &out, "state", state, true);
    try appendQueryParam(allocator, &out, "code_challenge", challenge, true);
    try appendQueryParam(allocator, &out, "code_challenge_method", "S256", true);
    try appendQueryParam(allocator, &out, "resource", resource_url, true);
    return out.toOwnedSlice();
}

fn appendQueryParam(
    allocator: std.mem.Allocator,
    out: *std_io.StringBuilder,
    key: []const u8,
    value: []const u8,
    prefix_amp: bool,
) !void {
    if (prefix_amp) try out.append('&');
    try out.appendSlice(key);
    try out.append('=');
    const encoded = try urlEncodeAlloc(allocator, value);
    defer allocator.free(encoded);
    try out.appendSlice(encoded);
}

fn exchangeAuthorizationCode(
    allocator: std.mem.Allocator,
    token_endpoint: []const u8,
    client_id: []const u8,
    callback_url: []const u8,
    code: []const u8,
    code_verifier: []const u8,
) !OAuthRefreshResult {
    const body = try buildAuthorizationCodeBody(allocator, token_endpoint, client_id, callback_url, code, code_verifier);
    defer allocator.free(body);

    const raw = try http_common.callHttp(
        allocator,
        .POST,
        token_endpoint,
        &.{"Content-Type: application/x-www-form-urlencoded"},
        body,
        http_timeout_ms,
    );
    defer allocator.free(raw);

    return parseTokenResponse(allocator, raw);
}

fn buildAuthorizationCodeBody(
    allocator: std.mem.Allocator,
    _: []const u8,
    client_id: []const u8,
    callback_url: []const u8,
    code: []const u8,
    code_verifier: []const u8,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try appendFormParam(allocator, &out, "grant_type", "authorization_code", false);
    try appendFormParam(allocator, &out, "client_id", client_id, true);
    try appendFormParam(allocator, &out, "code", code, true);
    try appendFormParam(allocator, &out, "redirect_uri", callback_url, true);
    try appendFormParam(allocator, &out, "code_verifier", code_verifier, true);
    return out.toOwnedSlice();
}

fn buildRefreshBody(allocator: std.mem.Allocator, refresh_token: []const u8, client_id: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try appendFormParam(allocator, &out, "grant_type", "refresh_token", false);
    try appendFormParam(allocator, &out, "refresh_token", refresh_token, true);
    try appendFormParam(allocator, &out, "client_id", client_id, true);
    return out.toOwnedSlice();
}

fn appendFormParam(allocator: std.mem.Allocator, out: *std_io.StringBuilder, key: []const u8, value: []const u8, prefix_amp: bool) !void {
    if (prefix_amp) try out.append('&');
    try out.appendSlice(key);
    try out.append('=');
    const encoded = try urlEncodeAlloc(allocator, value);
    defer allocator.free(encoded);
    try out.appendSlice(encoded);
}

fn parseTokenResponse(allocator: std.mem.Allocator, raw: []const u8) !OAuthRefreshResult {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;

    const access_token = getString(parsed.value.object, "access_token") orelse return error.McpOAuthMissingToken;
    const refresh_token = getString(parsed.value.object, "refresh_token");
    const expires_ts = if (getIntField(parsed.value.object, "expires_in")) |seconds|
        clock.nowSeconds() + seconds
    else
        null;

    return .{
        .access_token = try allocator.dupe(u8, access_token),
        .refresh_token = if (refresh_token) |value| try allocator.dupe(u8, value) else null,
        .expires_ts = expires_ts,
    };
}

fn joinWellKnownAuthorizationServer(allocator: std.mem.Allocator, base: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, base, "/");
    return std.fmt.allocPrint(allocator, "{s}/.well-known/oauth-authorization-server", .{trimmed});
}

const HttpMethod = enum {
    GET,
    POST,
};

const HttpResponse = struct {
    status_code: u16,
    headers: []u8,
    body: []u8,

    fn deinit(self: *HttpResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.headers);
        allocator.free(self.body);
    }

    fn headerValue(self: *const HttpResponse, name: []const u8) ?[]const u8 {
        var lines = std.mem.splitScalar(u8, self.headers, '\n');
        _ = lines.next() orelse return null;
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const key = std.mem.trim(u8, line[0..colon], " \t");
            if (!std.ascii.eqlIgnoreCase(key, name)) continue;
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
        return null;
    }
};

fn callHttpWithHeaders(
    allocator: std.mem.Allocator,
    method: HttpMethod,
    url: []const u8,
    headers: []const []const u8,
    body: ?[]const u8,
) !HttpResponse {
    // Route through the central egress chokepoint BEFORE we build
    // headers (which may carry the Bearer credential) or write the
    // request-body tempfile. OAuth refresh requests carry the most
    // secret-heavy payloads zcode produces -- client_secret +
    // refresh_token in the body, and the response carries
    // access_token. A misconfigured authorization endpoint URL of
    // http://attacker.example.com/oauth/token would leak the entire
    // OAuth handshake in plaintext; https://169.254.169.254/... would
    // let the OAuth path reach cloud-metadata.
    switch (egress.checkUrl(allocator, url, .{})) {
        .allow => {},
        .deny_scheme, .deny_ssrf, .deny_allowlist, .deny_denylist => return error.UrlPolicyDenied,
    }

    // OAuth refresh payloads contain client_secret + refresh_token and
    // response bodies contain access tokens; headers may carry a Bearer
    // credential. Everything goes through a 0600 curl config file so
    // `ps`/`/proc` can't see them. Mirrors the argv-hygiene fix in
    // providers/common.zig::callHttp.
    const method_name: []const u8 = if (method == .GET) "GET" else "POST";
    const curl_method: http_common.HttpMethod = if (method == .GET) .GET else .POST;
    const secrets = try http_common.writeCurlRequestFiles(
        allocator,
        method_name,
        url,
        headers,
        body,
        curl_method,
    );
    defer secrets.cleanup(allocator);

    const status_marker = "\n__ZCODE_HTTP_STATUS__:";
    var timeout_buf: [16]u8 = undefined;
    const timeout_str = std.fmt.bufPrint(&timeout_buf, "{d}", .{(http_timeout_ms + 999) / 1000}) catch "20";

    const argv = [_][]const u8{
        "curl",
        "-sS",
        "-D",
        "-",
        "--max-time",
        timeout_str,
        "--write-out",
        status_marker ++ "%{http_code}",
        "-K",
        secrets.config_path,
    };

    const result = std.process.run(allocator, rt.io, .{
        .argv = &argv,
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(8 * 1024 * 1024),
    }) catch return error.HttpTransport;
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    if (!(result.term == .exited and result.term.exited == 0)) return error.HttpTransport;
    const parsed = parseCurlEnvelope(result.stdout, status_marker) orelse return error.HttpTransport;
    return .{
        .status_code = parsed.status_code,
        .headers = try allocator.dupe(u8, parsed.headers),
        .body = try allocator.dupe(u8, parsed.body),
    };
}

const ParsedCurlEnvelope = struct {
    status_code: u16,
    headers: []const u8,
    body: []const u8,
};

fn parseCurlEnvelope(raw: []const u8, marker: []const u8) ?ParsedCurlEnvelope {
    const marker_idx = std.mem.lastIndexOf(u8, raw, marker) orelse return null;
    const status_slice = std.mem.trim(u8, raw[marker_idx + marker.len ..], " \t\r\n");
    const status_code = std.fmt.parseInt(u16, status_slice, 10) catch return null;
    const prelude = raw[0..marker_idx];
    const header_end = if (std.mem.indexOf(u8, prelude, "\r\n\r\n")) |idx| idx + 4 else if (std.mem.indexOf(u8, prelude, "\n\n")) |idx| idx + 2 else return null;
    return .{
        .status_code = status_code,
        .headers = prelude[0..header_end],
        .body = prelude[header_end..],
    };
}

fn parseBearerChallenge(allocator: std.mem.Allocator, header: []const u8) !UnauthorizedChallenge {
    if (!std.ascii.startsWithIgnoreCase(header, "Bearer")) return error.McpOAuthUnsupportedChallenge;
    const params = std.mem.trim(u8, header["Bearer".len..], " \t");

    var out: UnauthorizedChallenge = .{
        .scope = try allocator.dupe(u8, ""),
    };
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < params.len) {
        while (i < params.len and (params[i] == ',' or params[i] == ' ' or params[i] == '\t')) : (i += 1) {}
        if (i >= params.len) break;
        const key_start = i;
        while (i < params.len and params[i] != '=') : (i += 1) {}
        if (i >= params.len) break;
        const key = std.mem.trim(u8, params[key_start..i], " \t");
        i += 1;
        if (i >= params.len) break;

        var value: []const u8 = "";
        if (params[i] == '"') {
            i += 1;
            const value_start = i;
            while (i < params.len and params[i] != '"') : (i += 1) {}
            value = params[value_start..@min(i, params.len)];
            if (i < params.len and params[i] == '"') i += 1;
        } else {
            const value_start = i;
            while (i < params.len and params[i] != ',') : (i += 1) {}
            value = std.mem.trim(u8, params[value_start..i], " \t");
        }

        if (std.mem.eql(u8, key, "resource_metadata")) {
            if (out.resource_metadata_url) |existing| allocator.free(existing);
            out.resource_metadata_url = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "authorization_uri")) {
            if (out.authorization_metadata_url) |existing| allocator.free(existing);
            out.authorization_metadata_url = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "scope")) {
            allocator.free(out.scope);
            out.scope = try allocator.dupe(u8, value);
        }
    }

    return out;
}

fn openBrowserUrl(allocator: std.mem.Allocator, url: []const u8) !void {
    const argv = switch (@import("builtin").os.tag) {
        .macos => [_][]const u8{ "open", url },
        .linux => [_][]const u8{ "xdg-open", url },
        .windows => [_][]const u8{ "rundll32", "url.dll,FileProtocolHandler", url },
        else => return error.UnsupportedPlatform,
    };
    const result = try std.process.run(allocator, rt.io, .{
        .argv = &argv,
        .stdout_limit = .limited(8 * 1024),
        .stderr_limit = .limited(8 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!(result.term == .exited and result.term.exited == 0)) return error.McpOAuthBrowserOpenFailed;
}

fn acceptWithTimeout(server: *std.Io.net.Server, timeout_ms: i32) !std.Io.net.Stream {
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = server.socket.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try std.posix.poll(&poll_fds, timeout_ms);
    if (ready <= 0) return error.McpOAuthTimeout;
    const accepted = try server.accept(rt.io);
    return accepted;
}

fn readHttpRequest(allocator: std.mem.Allocator, stream: std.Io.net.Stream) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    var buf: [1024]u8 = undefined;
    while (true) {
        const n = try std_io.streamRead(stream, &buf);
        if (n == 0) break;
        try out.appendSlice(buf[0..n]);
        if (std.mem.indexOf(u8, out.items(), "\r\n\r\n") != null) break;
        if (out.items().len > 16 * 1024) return error.HttpHeaderTooLarge;
    }
    return out.toOwnedSlice();
}

fn requestQuery(request: []const u8) ?[]const u8 {
    const first_line_end = std.mem.indexOf(u8, request, "\r\n") orelse request.len;
    const first_line = request[0..first_line_end];
    const first_space = std.mem.indexOfScalar(u8, first_line, ' ') orelse return null;
    const second_space = std.mem.lastIndexOfScalar(u8, first_line, ' ') orelse return null;
    if (second_space <= first_space) return null;
    const target = first_line[first_space + 1 .. second_space];
    const query_idx = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    return target[query_idx + 1 ..];
}

fn getQueryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

fn parseCallbackPayload(allocator: std.mem.Allocator, query: []const u8) !CallbackPayload {
    if (getQueryParam(query, "error")) |value| {
        return .{ .provider_error = .{
            .error_code = try percentDecodeAlloc(allocator, value),
            .description = if (getQueryParam(query, "error_description")) |desc| try percentDecodeAlloc(allocator, desc) else null,
        } };
    }

    if (getQueryParam(query, "code")) |code| {
        const code_decoded = try percentDecodeAlloc(allocator, code);
        errdefer allocator.free(code_decoded);
        const state_raw = getQueryParam(query, "state") orelse return error.McpOAuthMissingState;
        const state_decoded = try percentDecodeAlloc(allocator, state_raw);
        return .{ .code_success = .{
            .code = code_decoded,
            .state = state_decoded,
        } };
    }

    const access_token = try percentDecodeAlloc(
        allocator,
        getQueryParam(query, "access_token") orelse getQueryParam(query, "token") orelse return error.McpOAuthMissingToken,
    );
    errdefer allocator.free(access_token);
    const refresh_token = if (getQueryParam(query, "refresh_token")) |value| try percentDecodeAlloc(allocator, value) else null;
    errdefer if (refresh_token) |value| allocator.free(value);

    const expires_ts = if (getQueryParam(query, "expires_in")) |value| blk: {
        const decoded = try percentDecodeAlloc(allocator, value);
        defer allocator.free(decoded);
        const seconds = std.fmt.parseInt(i64, decoded, 10) catch break :blk null;
        break :blk clock.nowSeconds() + seconds;
    } else null;

    return .{ .token_success = .{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_ts = expires_ts,
    } };
}

fn percentDecodeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = std.fmt.charToDigit(input[i + 1], 16) catch {
                try out.append(input[i]);
                continue;
            };
            const lo = std.fmt.charToDigit(input[i + 2], 16) catch {
                try out.append(input[i]);
                continue;
            };
            try out.append(@as(u8, @intCast((hi << 4) | lo)));
            i += 2;
            continue;
        }
        if (input[i] == '+') {
            try out.append(' ');
            continue;
        }
        try out.append(input[i]);
    }

    return out.toOwnedSlice();
}

fn urlEncodeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    for (input) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try out.append(ch);
        } else {
            try out.writer().print("%{X:0>2}", .{ch});
        }
    }
    return out.toOwnedSlice();
}

fn randomUrlToken(allocator: std.mem.Allocator, byte_len: usize) ![]u8 {
    const bytes = try allocator.alloc(u8, byte_len);
    defer allocator.free(bytes);
    rng.secureBytes(bytes);
    return base64UrlNoPadAlloc(allocator, bytes);
}

fn pkceChallenge(allocator: std.mem.Allocator, verifier: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    return base64UrlNoPadAlloc(allocator, &digest);
}

fn base64UrlNoPadAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoded_len = std.base64.url_safe.Encoder.calcSize(bytes.len);
    const buf = try allocator.alloc(u8, encoded_len);
    errdefer allocator.free(buf);
    const written = std.base64.url_safe.Encoder.encode(buf, bytes);
    var unpadded_len = written.len;
    while (unpadded_len > 0 and buf[unpadded_len - 1] == '=') unpadded_len -= 1;
    return allocator.realloc(buf, unpadded_len);
}

fn writeHttpResponse(stream: std.Io.net.Stream, body: []const u8) !void {
    var header: [256]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&header, "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len});
    try std_io.streamWriteAll(stream, prefix);
    try std_io.streamWriteAll(stream, body);
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getIntField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |n| n,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn encodeJsonAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    try buf.writer().print("{f}", .{std.json.fmt(value, .{})});
    return buf.toOwnedSlice();
}

const testing = std.testing;

test "requestQuery extracts query string" {
    const query = requestQuery("GET /callback?token=abc&refresh_token=def HTTP/1.1\r\nHost: localhost\r\n\r\n") orelse return error.TestFailed;
    try testing.expectEqualStrings("token=abc&refresh_token=def", query);
}

test "percentDecodeAlloc decodes urlencoded values" {
    const decoded = try percentDecodeAlloc(testing.allocator, "abc%20123");
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings("abc 123", decoded);
}

test "parse bearer challenge extracts metadata urls" {
    var parsed = try parseBearerChallenge(
        testing.allocator,
        "Bearer resource_metadata=\"https://mcp.figma.com/.well-known/oauth-protected-resource\",scope=\"mcp:connect\",authorization_uri=\"https://api.figma.com/.well-known/oauth-authorization-server\"",
    );
    defer parsed.deinit(testing.allocator);
    try testing.expectEqualStrings("https://mcp.figma.com/.well-known/oauth-protected-resource", parsed.resource_metadata_url.?);
    try testing.expectEqualStrings("https://api.figma.com/.well-known/oauth-authorization-server", parsed.authorization_metadata_url.?);
    try testing.expectEqualStrings("mcp:connect", parsed.scope);
}

test "parse callback payload handles authorization code" {
    var payload = try parseCallbackPayload(testing.allocator, "code=abc123&state=xyz");
    defer payload.deinit(testing.allocator);
    try testing.expect(payload == .code_success);
    try testing.expectEqualStrings("abc123", payload.code_success.code);
    try testing.expectEqualStrings("xyz", payload.code_success.state);
}

test "http probe URL normalizes websocket transports" {
    const allocator = testing.allocator;

    const ws = try httpProbeUrlForTransport(allocator, "ws://127.0.0.1:8765/mcp");
    defer allocator.free(ws);
    try testing.expectEqualStrings("http://127.0.0.1:8765/mcp", ws);

    const wss = try httpProbeUrlForTransport(allocator, "wss://example.com/mcp");
    defer allocator.free(wss);
    try testing.expectEqualStrings("https://example.com/mcp", wss);
}
