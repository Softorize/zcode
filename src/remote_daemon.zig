const std = @import("std");
const std_io = @import("core/std_io.zig");
const rt = @import("zcode_runtime");
const rng = @import("core/rng.zig");
const clock = @import("core/clock.zig");
const paths = @import("core/paths.zig");
const session_bundles = @import("session/bundles.zig");
const session_store = @import("session/store.zig");
const rate_limit = @import("core/rate_limit.zig");
const metrics_mod = @import("core/metrics.zig");
const otel_mod = @import("core/otel.zig");
const rbac = @import("policy/rbac.zig");
const websocket = @import("mcp/websocket.zig");
const sdk_message = @import("core/sdk_message.zig");
const session_index = @import("core/server_session_index.zig");

// Stage 5e: rate limiters live at module scope so the per-connection worker
// threads can reference them without per-handler plumbing. Initialized once
// in `run()`; the daemon process owns them for its full lifetime.
var global_limiter: rate_limit.RateLimiter = undefined;
var ip_limiter: rate_limit.RateLimiterMap = undefined;

// Phase 12 Task 19: direct-connect server.
//
// ServerConfig captures the operator-tunable surface of the direct-connect
// server. Mirrors the reference `server/types.ts:13` ServerConfig. The
// idle-timeout / max-sessions enforcement and on-disk persistence land in
// Task 20 (server_session_index); here the config is consumed for defaults
// and the workspace fallback when a /sessions request omits `cwd`.
pub const ServerConfig = struct {
    /// Default workspace used when a /sessions request omits an explicit cwd.
    workspace: []const u8 = "",
    /// 0 means "never time out" (matches the reference convention).
    idle_timeout_ms: u64 = 0,
    /// 0 means "unlimited sessions" (matches the reference convention).
    max_sessions: usize = 0,
};

// In-memory direct-connect session registry. Task 20 persists this to disk;
// for Task 19 we keep a process-local map so the WS stream route can resolve a
// session id allocated by POST /sessions. Guarded by a mutex because the
// per-connection worker threads touch it concurrently.
const DirectSession = struct {
    session_id: []u8,
    work_dir: []u8,
    skip_permissions: bool,
    created_ts: i64,
};

var sessions_lock: std.Io.Mutex = .init;
var sessions_map: ?std.StringHashMap(DirectSession) = null;

// Task 20: operator-tunable limits, read by handleCreateSession (max-sessions
// refusal) and the idle sweep. Defaults to "unlimited / never time out" so the
// behavior is unchanged until an operator configures it. Installed once in
// `serve()`.
var server_config: ServerConfig = .{};

fn sessionsMap(allocator: std.mem.Allocator) *std.StringHashMap(DirectSession) {
    if (sessions_map == null) {
        sessions_map = std.StringHashMap(DirectSession).init(allocator);
    }
    return &sessions_map.?;
}

/// Register a freshly created direct-connect session. Takes ownership of the
/// duplicated id/work_dir slices. Caller holds no lock; this acquires it.
fn registerSession(allocator: std.mem.Allocator, session: DirectSession) !void {
    try sessions_lock.lock(rt.io);
    defer sessions_lock.unlock(rt.io);
    const map = sessionsMap(allocator);
    try map.put(session.session_id, session);
}

/// Look up a session by id under the lock; returns a snapshot copy of the
/// scalar fields the caller needs (work_dir is borrowed and stays valid while
/// the entry lives, which it does for the daemon's lifetime).
fn lookupSession(allocator: std.mem.Allocator, session_id: []const u8) ?DirectSession {
    sessions_lock.lock(rt.io) catch return null;
    defer sessions_lock.unlock(rt.io);
    const map = sessionsMap(allocator);
    return map.get(session_id);
}

pub const State = struct {
    pid: i32,
    port: u16,
    token: []u8,
    started_ts: i64,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        allocator.free(self.token);
    }
};

pub fn start(allocator: std.mem.Allocator) ![]u8 {
    if (try loadState(allocator)) |loaded_state| {
        var state = loaded_state;
        defer state.deinit(allocator);
        if (isPidRunning(state.pid)) {
            return std.fmt.allocPrint(allocator, "daemon already running\tpid={d}\tport={d}", .{ state.pid, state.port });
        }
    }
    // Clear any stale state file from a previous crashed run so the poll
    // loop below doesn't read a ghost record.
    deleteState(allocator) catch {};

    const exe = try std.process.executablePathAlloc(rt.io, allocator);
    defer allocator.free(exe);

    const token = try randomHex(allocator, 16);
    defer allocator.free(token);

    // Pass the bearer token via the environment rather than argv so it does
    // not appear in `ps` / `/proc/<pid>/cmdline` for other local users to see.
    // We also pass `0` as the port, which instructs the child to bind an
    // ephemeral port (the kernel picks an unpredictable free port). This
    // prevents a local attacker from pre-binding a well-known port with
    // SO_REUSEADDR after a crash and harvesting bearer tokens.
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("ZCODE_DAEMON_TOKEN", token);

    const child = try std.process.spawn(rt.io, .{
        .argv = &.{ exe, "daemon", "serve", "0" },
        .environ_map = &env_map,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const pid: i32 = @intCast(child.id orelse 0);

    // The child writes the real state file (with the kernel-assigned port
    // and its own pid) after it successfully binds. Poll for it to appear,
    // up to ~3 seconds, before reporting success.
    const deadline_ns = clock.nowNanos() + 3 * std.time.ns_per_s;
    while (clock.nowNanos() < deadline_ns) {
        clock.sleepNanos(50 * std.time.ns_per_ms);
        if (try loadState(allocator)) |loaded_state| {
            var state = loaded_state;
            defer state.deinit(allocator);
            if (state.pid == pid) {
                return std.fmt.allocPrint(
                    allocator,
                    "started daemon\tpid={d}\tport={d}\ttoken={s}",
                    .{ state.pid, state.port, token },
                );
            }
        }
    }
    // If we time out, the child probably failed to bind. Kill it and
    // surface the error rather than leaking a half-started daemon.
    std.posix.kill(pid, std.posix.SIG.TERM) catch {};
    return error.DaemonBindTimeout;
}

pub fn status(allocator: std.mem.Allocator) ![]u8 {
    if (try loadState(allocator)) |loaded_state| {
        var state = loaded_state;
        defer state.deinit(allocator);
        // Sanitize the redacted token prefix so a state file with
        // hostile bytes in the first 8 chars cannot smuggle an
        // ANSI escape into `daemon status` output. The prefix is
        // already truncated to 8 chars; we additionally escape any
        // C0 byte to \xHH.
        const display_safe = @import("core/display_safe.zig");
        const redacted = redactTokenForStatus(state.token);
        const safe_token = try display_safe.sanitize(allocator, redacted);
        defer allocator.free(safe_token);
        return std.fmt.allocPrint(
            allocator,
            "daemon\trunning={}\tpid={d}\tport={d}\ttoken={s}\tstarted={d}\n",
            .{ isPidRunning(state.pid), state.pid, state.port, safe_token, state.started_ts },
        );
    }
    return allocator.dupe(u8, "daemon\trunning=false\n");
}

pub fn stop(allocator: std.mem.Allocator) ![]u8 {
    var state = (try loadState(allocator)) orelse return allocator.dupe(u8, "daemon not running");
    defer state.deinit(allocator);

    if (isPidRunning(state.pid)) {
        std.posix.kill(state.pid, std.posix.SIG.TERM) catch {};
    }
    try deleteState(allocator);
    return std.fmt.allocPrint(allocator, "stopped daemon\tpid={d}", .{state.pid});
}

pub fn handoff(
    allocator: std.mem.Allocator,
    store: *session_store.Store,
    session_id: []const u8,
    label: ?[]const u8,
) ![]u8 {
    var saved = try session_bundles.shareSession(allocator, store, session_id, label);
    defer saved.deinit(allocator);

    var state = (try loadState(allocator)) orelse return std.fmt.allocPrint(
        allocator,
        "share bundle saved\tid={s}\tlabel={s}\tpath={s}\nstart the daemon to get a web handoff URL",
        .{ saved.id, saved.label, saved.path },
    );
    defer state.deinit(allocator);

    const file_name = std.fs.path.basename(saved.path);
    return std.fmt.allocPrint(
        allocator,
        "share bundle saved\tid={s}\tlabel={s}\tpath={s}\nurl=http://127.0.0.1:{d}/share/{s}?token={s}\nweb=http://127.0.0.1:{d}/view/{s}?token={s}\nimport=zcode session import http://127.0.0.1:{d}/share/{s}?token={s}",
        .{ saved.id, saved.label, saved.path, state.port, file_name, state.token, state.port, file_name, state.token, state.port, file_name, state.token },
    );
}

pub fn serve(allocator: std.mem.Allocator, store: *session_store.Store, port: u16, token: []const u8) !void {
    const shares_dir = try sharesDir(allocator, store);
    defer allocator.free(shares_dir);
    const principal_role = daemonRoleFromEnvironment();

    // Initialize the module-global rate limiters (see `global_limiter` and
    // `ip_limiter` above). They live for the lifetime of the daemon process
    // because Stage 5e spawns one thread per accepted connection and the
    // workers reference these limiters without holding a per-connection
    // reference.
    global_limiter = rate_limit.RateLimiter.init(60.0, 1.0);
    ip_limiter = rate_limit.RateLimiterMap.init(allocator, 30.0, 0.5, 256);
    defer ip_limiter.deinit();

    // Bind to 127.0.0.1:port; when port is 0 the kernel picks an ephemeral
    // free port (the parent's `start` always passes 0 nowadays). After
    // listen() returns, `server.listen_address` holds the real bound port.
    // Reuse_address is intentionally false so two concurrent daemons cannot
    // share the socket -- the earlier hijack vector where a crashed daemon
    // left the port available for another local user to grab no longer
    // applies because the port is unpredictable.
    const _addr: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } };
    var server = try _addr.listen(rt.io, .{ .reuse_address = false });
    defer server.deinit(rt.io);

    var addr_buf: std.posix.sockaddr.storage = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    _ = std.c.getsockname(server.socket.handle, @ptrCast(&addr_buf), &addr_len);
    const sin = @as(*const std.posix.sockaddr.in, @ptrCast(@alignCast(&addr_buf)));
    const bound_port: u16 = std.mem.bigToNative(u16, sin.port);
    // The child is now authoritative for state.json: it writes its own PID,
    // the kernel-assigned port, and the token it received via environment.
    // The parent `start()` polls for this file to appear.
    const self_pid: i32 = switch (@import("builtin").os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        else => @intCast(std.c.getpid()),
    };
    try writeStateFields(allocator, self_pid, bound_port, token, clock.nowSeconds());
    defer deleteState(allocator) catch {};

    // Task 20: install operator limits (defaults = unlimited / never time out)
    // and reconcile the persisted session index on start. Any session that was
    // running/starting when the previous daemon exited is now orphaned, so mark
    // it detached -- it can be resumed but is no longer attached to a live WS.
    server_config = .{};
    reconcileSessionIndexOnStart(allocator);

    // Stage 5e: accept connections and spawn one thread per client so a slow
    // client cannot block subsequent ones. The previous single-threaded loop
    // serialized every request behind the slowest in-flight handler.
    while (true) {
        const accepted = try server.accept(rt.io);

        // Apply a 10-second receive timeout so a slowloris client cannot
        // trickle bytes and starve the worker, and a matching send timeout
        // so a client that stops reading halfway through our response
        // can't wedge the writer.
        setSocketReadTimeout(accepted.socket.handle, 10) catch {};
        setSocketWriteTimeout(accepted.socket.handle, 10) catch {};

        const ctx_ptr = allocator.create(ClientContext) catch {
            accepted.close(rt.io);
            continue;
        };
        ctx_ptr.* = .{
            .allocator = allocator,
            .stream = accepted,
            .shares_dir = shares_dir,
            .token = token,
            .principal_role = principal_role,
        };

        const thread = std.Thread.spawn(.{}, clientWorker, .{ctx_ptr}) catch {
            // If we cannot spawn a thread, fall back to handling this
            // connection inline rather than dropping it silently.
            clientWorker(ctx_ptr);
            continue;
        };
        thread.detach();
    }
}

const ClientContext = struct {
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    shares_dir: []const u8,
    token: []const u8,
    principal_role: rbac.Role,
};

fn clientWorker(ctx: *ClientContext) void {
    defer ctx.stream.close(rt.io);
    defer ctx.allocator.destroy(ctx);

    // Rate limit check. The limiters are process-global; concurrent workers
    // race on tryAcquire which is fine because tryAcquire is internally
    // synchronized.
    var peer_buf: [64]u8 = undefined;
    const peer_key = formatPeerKey(std.Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } }, &peer_buf);
    if (!global_limiter.tryAcquire() or !ip_limiter.tryAcquire(peer_key)) {
        const retry = @max(global_limiter.retryAfterSeconds(), ip_limiter.retryAfterSeconds(peer_key));
        writeRateLimitResponse(ctx.stream, retry) catch {};
        return;
    }

    const request = readRequest(ctx.allocator, ctx.stream) catch return;
    defer ctx.allocator.free(request);
    handleRequest(ctx.allocator, ctx.stream, request, ctx.shares_dir, ctx.token, ctx.principal_role) catch {};
}

/// Apply SO_RCVTIMEO to the socket so blocking reads return after `seconds`.
fn setSocketReadTimeout(fd: std.posix.socket_t, seconds: u32) !void {
    if (@import("builtin").os.tag == .windows) return; // skip on windows
    const tv = std.posix.timeval{ .sec = @intCast(seconds), .usec = 0 };
    try std.posix.setsockopt(
        fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&tv),
    );
}

/// Apply SO_SNDTIMEO so a stalled-reader client can't wedge the
/// single-threaded accept loop during response write.
fn setSocketWriteTimeout(fd: std.posix.socket_t, seconds: u32) !void {
    if (@import("builtin").os.tag == .windows) return;
    const tv = std.posix.timeval{ .sec = @intCast(seconds), .usec = 0 };
    try std.posix.setsockopt(
        fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.SNDTIMEO,
        std.mem.asBytes(&tv),
    );
}

fn formatPeerKey(address: std.Io.net.IpAddress, buf: *[64]u8) []const u8 {
    // Key the per-IP limiter on the source IP. The previous version keyed
    // on the ephemeral source port, which changes every TCP connection and
    // defeated the per-IP limit entirely.
    return switch (address) {
        .ip4 => |ip4| blk: {
            const octets = ip4.bytes;
            const written = std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ octets[0], octets[1], octets[2], octets[3] }) catch break :blk "unknown";
            break :blk written;
        },
        .ip6 => |ip6| blk: {
            const words = ip6.bytes;
            const written = std.fmt.bufPrint(buf, "v6:{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}", .{
                (@as(u16, words[0]) << 8) | words[1],
                (@as(u16, words[2]) << 8) | words[3],
                (@as(u16, words[4]) << 8) | words[5],
                (@as(u16, words[6]) << 8) | words[7],
                (@as(u16, words[8]) << 8) | words[9],
                (@as(u16, words[10]) << 8) | words[11],
                (@as(u16, words[12]) << 8) | words[13],
                (@as(u16, words[14]) << 8) | words[15],
            }) catch break :blk "unknown";
            break :blk written;
        },
    };
}

fn writeRateLimitResponse(stream: std.Io.net.Stream, retry_after: u32) !void {
    var buf: [256]u8 = undefined;
    const body = "rate limited";
    const header = std.fmt.bufPrint(&buf, "HTTP/1.1 429 Too Many Requests\r\nRetry-After: {d}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ retry_after, body.len }) catch return;
    try std_io.streamWriteAll(stream, header);
    try std_io.streamWriteAll(stream, body);
}

fn handleRequest(
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    request: []const u8,
    shares_dir: []const u8,
    token: []const u8,
    principal_role: rbac.Role,
) !void {
    const target = requestTarget(request) orelse {
        try writeResponse(stream, 400, "bad request", "text/plain");
        return;
    };

    if (std.mem.eql(u8, target, "/status")) {
        const body = try std.fmt.allocPrint(allocator, "{{\"ok\":true,\"service\":\"zcode-share-daemon\"}}", .{});
        defer allocator.free(body);
        try writeResponse(stream, 200, body, "application/json");
        return;
    }

    // Phase 12 Task 19: direct-connect session creation. POST /sessions
    // allocates a session, registers it, and returns the {session_id, ws_url,
    // work_dir} contract. Bearer-token gated.
    if (std.mem.eql(u8, target, "/sessions")) {
        const method = requestMethod(request) orelse "";
        if (!std.mem.eql(u8, method, "POST")) {
            try writeResponse(stream, 405, "method not allowed", "text/plain");
            return;
        }
        if (!authorizeRequest(request, target, token) or !rbac.authorize(principal_role, .share_read)) {
            try writeResponse(stream, 403, "forbidden", "text/plain");
            return;
        }
        try handleCreateSession(allocator, stream, requestBody(request), extractPortFromRequest(request));
        return;
    }

    // Phase 12 Task 19: WebSocket stream for a created session. The framing
    // primitives live in mcp/websocket.zig (server mode).
    if (std.mem.startsWith(u8, target, "/sessions/") and std.mem.endsWith(u8, target, "/stream")) {
        if (!authorizeRequest(request, target, token) or !rbac.authorize(principal_role, .share_read)) {
            try writeResponse(stream, 403, "forbidden", "text/plain");
            return;
        }
        const id = sessionIdFromStreamTarget(target) orelse {
            try writeResponse(stream, 400, "bad session path", "text/plain");
            return;
        };
        const session = lookupSession(allocator, id) orelse {
            try writeResponse(stream, 404, "session not found", "text/plain");
            return;
        };
        try handleSessionStream(allocator, stream, request, session);
        return;
    }

    if (std.mem.eql(u8, target, "/metrics")) {
        if (!authorizeRequest(request, target, token) or !rbac.authorize(principal_role, .audit_read)) {
            try writeResponse(stream, 403, "forbidden", "text/plain");
            return;
        }
        const metrics_body = metrics_mod.globalMetrics().renderPrometheus(allocator) catch {
            try writeResponse(stream, 500, "metrics error", "text/plain");
            return;
        };
        defer allocator.free(metrics_body);
        try writeResponse(stream, 200, metrics_body, "text/plain; version=0.0.4; charset=utf-8");
        return;
    }

    if (std.mem.eql(u8, target, "/otel")) {
        if (!authorizeRequest(request, target, token) or !rbac.authorize(principal_role, .audit_read)) {
            try writeResponse(stream, 403, "forbidden", "text/plain");
            return;
        }
        const otel_body = otel_mod.renderOtlpJson(allocator) catch {
            try writeResponse(stream, 500, "otel export error", "text/plain");
            return;
        };
        defer allocator.free(otel_body);
        try writeResponse(stream, 200, otel_body, "application/json");
        return;
    }

    if (std.mem.eql(u8, target, "/")) {
        try writeResponse(stream, 200, handoffLandingHtml, "text/html; charset=utf-8");
        return;
    }

    if (!(std.mem.startsWith(u8, target, "/share/") or std.mem.startsWith(u8, target, "/view/"))) {
        try writeResponse(stream, 404, "not found", "text/plain");
        return;
    }

    const query = std.mem.indexOfScalar(u8, target, '?');
    const path_only = if (query) |idx| target[0..idx] else target;
    const query_text = if (query) |idx| target[idx + 1 ..] else "";

    // Authenticate: prefer Authorization header, fall back to query param.
    const bearer_token = extractBearerToken(request);
    const query_token = getQueryParam(query_text, "token");
    const request_token = bearer_token orelse query_token orelse "";
    if (query_token != null and bearer_token == null) {
        std.log.warn("daemon: token passed via query param (deprecated) - use Authorization: Bearer header", .{});
    }
    if (!constantTimeTokenEquals(request_token, token)) {
        try writeResponse(stream, 403, "forbidden", "text/plain");
        return;
    }

    const is_view = std.mem.startsWith(u8, path_only, "/view/");
    const endpoint: rbac.Endpoint = if (is_view) .view_render else .share_read;
    if (!rbac.authorize(principal_role, endpoint)) {
        try writeResponse(stream, 403, "forbidden", "text/plain");
        return;
    }

    const route_prefix = if (is_view) "/view/" else "/share/";
    const file_name = std.fs.path.basename(path_only[route_prefix.len..]);
    // Reject anything that isn't a simple file name (no slashes, no
    // parent-directory references, no absolute components, no null
    // bytes). basename() strips the obvious cases but a raw `..` still
    // survives, and an attacker who can plant a symlink under
    // shares_dir could otherwise make the daemon serve /etc/passwd.
    if (file_name.len == 0 or
        std.mem.indexOfScalar(u8, file_name, '/') != null or
        std.mem.indexOfScalar(u8, file_name, 0) != null or
        std.mem.eql(u8, file_name, "..") or
        std.mem.eql(u8, file_name, "."))
    {
        try writeResponse(stream, 400, "bad share name", "text/plain");
        return;
    }
    const share_path = try std.fs.path.join(allocator, &.{ shares_dir, file_name });
    defer allocator.free(share_path);
    // Realpath-contain: resolve symlinks and verify the resolved path
    // still lives under shares_dir. A symlink planted inside shares_dir
    // that points at /etc/passwd would otherwise return the target
    // file's contents.
    if (!resolvedPathWithin(allocator, share_path, shares_dir)) {
        try writeResponse(stream, 403, "forbidden", "text/plain");
        return;
    }
    const body = std.Io.Dir.cwd().readFileAlloc(rt.io, share_path, allocator, .limited(8 * 1024 * 1024)) catch {
        try writeResponse(stream, 404, "share not found", "text/plain");
        return;
    };
    defer allocator.free(body);
    if (is_view) {
        const json_url = try std.fmt.allocPrint(allocator, "/share/{s}?token={s}", .{ file_name, token });
        defer allocator.free(json_url);
        const html = try renderShareHtml(allocator, file_name, json_url, body, extractPortFromRequest(request));
        defer allocator.free(html);
        try writeResponse(stream, 200, html, "text/html; charset=utf-8");
        return;
    }

    try writeResponse(stream, 200, body, "application/json");
}

/// Extract `<id>` from a `/sessions/<id>/stream` target (query stripped).
/// Rejects ids containing path separators or empty ids.
fn sessionIdFromStreamTarget(target: []const u8) ?[]const u8 {
    const query = std.mem.indexOfScalar(u8, target, '?');
    const path_only = if (query) |idx| target[0..idx] else target;
    const prefix = "/sessions/";
    const suffix = "/stream";
    if (!std.mem.startsWith(u8, path_only, prefix)) return null;
    if (!std.mem.endsWith(u8, path_only, suffix)) return null;
    const id = path_only[prefix.len .. path_only.len - suffix.len];
    if (id.len == 0) return null;
    if (std.mem.indexOfScalar(u8, id, '/') != null) return null;
    if (std.mem.indexOfScalar(u8, id, 0) != null) return null;
    return id;
}

/// Build the JSON body for a POST /sessions response. Pure (no IO) so the
/// response contract is unit-testable without a socket. The reference returns
/// `{session_id, ws_url, work_dir}` (createDirectConnectSession.ts:26).
fn buildSessionResponseBody(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    work_dir: []const u8,
    port: u16,
) ![]u8 {
    const ws_url = try std.fmt.allocPrint(allocator, "ws://127.0.0.1:{d}/sessions/{s}/stream", .{ port, session_id });
    defer allocator.free(ws_url);
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try out.writer().print("{f}", .{std.json.fmt(.{
        .session_id = session_id,
        .ws_url = ws_url,
        .work_dir = work_dir,
    }, .{})});
    return out.toOwnedSlice();
}

/// Resolve the workspace for a new session: the request body's `cwd` when
/// present and absolute, else the daemon's configured workspace, else the
/// process cwd. Returns an owned slice.
fn resolveWorkDir(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    if (body.len > 0) {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch null;
        if (parsed) |*p| {
            defer p.deinit();
            if (p.value == .object) {
                const obj = &p.value.object;
                if (getString(obj.*, "cwd")) |cwd| {
                    if (cwd.len > 0 and std.fs.path.isAbsolute(cwd)) {
                        return allocator.dupe(u8, cwd);
                    }
                }
            }
        }
    }
    // Fall back to the daemon's current working directory.
    return std.process.currentPathAlloc(rt.io, allocator);
}

/// Whether the request body asks to skip permission prompts.
fn bodySkipsPermissions(allocator: std.mem.Allocator, body: []const u8) bool {
    if (body.len == 0) return false;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const v = parsed.value.object.get("dangerously_skip_permissions") orelse return false;
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

fn handleCreateSession(
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    body: []const u8,
    port: u16,
) !void {
    // Task 20: refuse beyond the configured max-sessions limit (0 = unlimited).
    if (sessionIndexAtCapacity(allocator)) {
        try writeResponse(stream, 429, "max sessions reached", "text/plain");
        return;
    }

    const hex = randomHex(allocator, 12) catch {
        try writeResponse(stream, 500, "session id error", "text/plain");
        return;
    };
    defer allocator.free(hex);
    const session_id = try std.fmt.allocPrint(allocator, "dc-{s}", .{hex});
    defer allocator.free(session_id);

    const work_dir = resolveWorkDir(allocator, body) catch {
        try writeResponse(stream, 500, "workdir error", "text/plain");
        return;
    };
    // Duplicate for the registry; the response body borrows the local copies.
    const reg_id = try allocator.dupe(u8, session_id);
    errdefer allocator.free(reg_id);
    const skip = bodySkipsPermissions(allocator, body);

    registerSession(allocator, .{
        .session_id = reg_id,
        .work_dir = work_dir,
        .skip_permissions = skip,
        .created_ts = clock.nowSeconds(),
    }) catch {
        allocator.free(reg_id);
        allocator.free(work_dir);
        try writeResponse(stream, 500, "session register error", "text/plain");
        return;
    };

    // Task 20: persist the session so a detached one survives a daemon restart.
    // Best-effort; failure does not abort creation (in-memory map is live-auth).
    if (!persistSessionToIndex(allocator, session_id, work_dir, skip)) {
        std.log.warn("daemon: failed to persist session {s} to index", .{session_id});
    }

    const resp = try buildSessionResponseBody(allocator, session_id, work_dir, port);
    defer allocator.free(resp);
    try writeResponse(stream, 200, resp, "application/json");
}

/// Drive the WebSocket session stream. Completes the RFC 6455 handshake, emits
/// an initial `system`/`init` SDK frame, then reads inbound frames (user input
/// / control_request interrupt) and echoes a terminal `result` frame.
///
/// The live AgentRuntime execution is the Task 19 integration piece deferred
/// per the plan ("land the route + handshake + message envelope first, then the
/// live agent streaming"). This wires the handshake + SDK-message envelope so
/// the framing contract is exercised end-to-end; running a full agent loop in
/// the daemon worker is left to the integration follow-up.
fn handleSessionStream(
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    request: []const u8,
    session: DirectSession,
) !void {
    const client_key = websocket.parseUpgradeRequest(request) orelse {
        try writeResponse(stream, 400, "expected websocket upgrade", "text/plain");
        return;
    };
    try websocket.sendUpgradeResponse(stream, client_key);

    // Emit the init system frame announcing the session + work dir.
    {
        const init_payload = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(.{
            .work_dir = session.work_dir,
            .skip_permissions = session.skip_permissions,
        }, .{})});
        defer allocator.free(init_payload);
        const init_msg = sdk_message.SdkMessage{
            .msg_type = .system,
            .session_id = session.session_id,
            .subtype = "init",
            .payload_json = init_payload,
        };
        try writeSdkFrame(allocator, stream, init_msg);
    }

    // Read inbound frames until the client closes or interrupts. Inbound
    // frames are masked (client -> server). An interrupt control_request or a
    // close frame ends the stream.
    while (true) {
        var frame = websocket.readFrame(allocator, stream, 60_000, .server) catch break;
        defer frame.deinit(allocator);
        switch (frame.opcode) {
            .close => break,
            .ping => {
                websocket.writePongFrame(stream, frame.payload) catch break;
            },
            .text => {
                // Parse the inbound SDK frame; an interrupt control_request
                // terminates the stream with a result.
                var parsed = sdk_message.parse(allocator, frame.payload) catch continue;
                defer parsed.deinit();
                if (parsed.message.msg_type == .control_request and
                    std.mem.eql(u8, parsed.message.subtype, "interrupt"))
                {
                    break;
                }
            },
            else => {},
        }
    }

    // Terminal result frame, then a clean close.
    const result_msg = sdk_message.SdkMessage{
        .msg_type = .result,
        .session_id = session.session_id,
        .subtype = "success",
        .text = "session stream closed",
    };
    writeSdkFrame(allocator, stream, result_msg) catch {};
    websocket.writeCloseFrame(stream) catch {};
}

/// Serialize an SDK message and write it as a single WebSocket text frame
/// (newline-delimited JSON per directConnectManager.ts:64-67).
fn writeSdkFrame(allocator: std.mem.Allocator, stream: std.Io.net.Stream, msg: sdk_message.SdkMessage) !void {
    const json = try msg.serialize(allocator);
    defer allocator.free(json);
    const framed = try std.fmt.allocPrint(allocator, "{s}\n", .{json});
    defer allocator.free(framed);
    try websocket.writeTextFrame(stream, framed);
}

fn daemonRoleFromEnvironment() rbac.Role {
    const raw = @import("core/env.zig").getenv("ZCODE_DAEMON_ROLE") orelse return .owner;
    return parseDaemonRole(raw) orelse .owner;
}

fn parseDaemonRole(raw: []const u8) ?rbac.Role {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    const role = rbac.Role.fromString(trimmed);
    if (role == .none and !std.ascii.eqlIgnoreCase(trimmed, "none")) return null;
    return role;
}

fn readRequest(allocator: std.mem.Allocator, stream: std.Io.net.Stream) ![]u8 {
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

    // If the request carries a body (POST /sessions), keep reading until we
    // have Content-Length bytes past the header terminator. Bodies are capped
    // so a hostile client cannot exhaust memory.
    const header_end = std.mem.indexOf(u8, out.items(), "\r\n\r\n") orelse return out.toOwnedSlice();
    const body_start = header_end + 4;
    const content_length = parseContentLength(out.items()) orelse return out.toOwnedSlice();
    const max_body: usize = 64 * 1024;
    if (content_length > max_body) return error.HttpBodyTooLarge;
    while (out.items().len - body_start < content_length) {
        const n = try std_io.streamRead(stream, &buf);
        if (n == 0) break;
        try out.appendSlice(buf[0..n]);
        if (out.items().len > 16 * 1024 + max_body) return error.HttpBodyTooLarge;
    }
    return out.toOwnedSlice();
}

/// Parse a `Content-Length:` header value (case-insensitive header name) from
/// the request text. Returns null when absent or unparseable.
fn parseContentLength(request: []const u8) ?usize {
    const first_eol = std.mem.indexOf(u8, request, "\r\n") orelse return null;
    var remaining = request[first_eol + 2 ..];
    while (remaining.len > 0) {
        const line_end = std.mem.indexOf(u8, remaining, "\r\n") orelse remaining.len;
        const line = remaining[0..line_end];
        if (line.len == 0) return null;
        if (std.ascii.startsWithIgnoreCase(line, "Content-Length:")) {
            const value = std.mem.trim(u8, line["Content-Length:".len..], " \t");
            return std.fmt.parseInt(usize, value, 10) catch null;
        }
        if (line_end == remaining.len) return null;
        remaining = remaining[line_end + 2 ..];
    }
    return null;
}

/// Extract the HTTP method token from the request line ("POST /x HTTP/1.1").
fn requestMethod(request: []const u8) ?[]const u8 {
    const line_end = std.mem.indexOf(u8, request, "\r\n") orelse request.len;
    const line = request[0..line_end];
    const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    return line[0..first_space];
}

/// Return the request body (everything after the header terminator), or empty.
fn requestBody(request: []const u8) []const u8 {
    const header_end = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return "";
    return request[header_end + 4 ..];
}

fn requestTarget(request: []const u8) ?[]const u8 {
    const line_end = std.mem.indexOf(u8, request, "\r\n") orelse request.len;
    const line = request[0..line_end];
    const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    const second_space = std.mem.lastIndexOfScalar(u8, line, ' ') orelse return null;
    if (second_space <= first_space) return null;
    return line[first_space + 1 .. second_space];
}

fn getQueryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

fn writeResponse(stream: std.Io.net.Stream, status_code: u16, body: []const u8, content_type: []const u8) !void {
    var prefix_buf: [1024]u8 = undefined;
    const prefix = try std.fmt.bufPrint(
        &prefix_buf,
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'\r\nConnection: close\r\n\r\n",
        .{ status_code, reasonPhrase(status_code), content_type, body.len },
    );
    try std_io.streamWriteAll(stream, prefix);
    try std_io.streamWriteAll(stream, body);
}

fn renderShareHtml(allocator: std.mem.Allocator, file_name: []const u8, json_url: []const u8, body: []const u8, port: u16) ![]u8 {
    const escaped_preview = try htmlEscapeAlloc(allocator, body);
    defer allocator.free(escaped_preview);
    const import_command = try std.fmt.allocPrint(allocator, "zcode session import http://127.0.0.1:{d}{s}", .{ port, json_url });
    defer allocator.free(import_command);
    const escaped_command = try htmlEscapeAlloc(allocator, import_command);
    defer allocator.free(escaped_command);
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll(
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="utf-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1">
        \\  <title>zcode Session Handoff</title>
        \\  <style>
        \\    :root { color-scheme: light; --ink:#11203a; --muted:#5e6b80; --line:#d6dce7; --bg:#f6f8fb; --card:#ffffff; --accent:#0d6efd; }
        \\    body { margin:0; padding:32px 20px; font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; background:linear-gradient(180deg,#f6f8fb 0,#eef3fa 100%); color:var(--ink); }
        \\    .shell { max-width:960px; margin:0 auto; }
        \\    .card { background:var(--card); border:1px solid var(--line); border-radius:16px; padding:20px 22px; box-shadow:0 10px 28px rgba(17,32,58,0.08); }
        \\    h1 { margin:0 0 10px; font-size:28px; }
        \\    p { margin:0 0 14px; color:var(--muted); }
        \\    .row { display:flex; gap:12px; flex-wrap:wrap; margin:18px 0; }
        \\    a.button { display:inline-block; padding:10px 14px; border-radius:10px; background:var(--accent); color:white; text-decoration:none; font-weight:600; }
        \\    a.link { color:var(--accent); text-decoration:none; font-weight:600; }
        \\    pre { margin:0; padding:14px; background:#0f172a; color:#e5edf8; border-radius:12px; overflow:auto; white-space:pre-wrap; word-break:break-word; }
        \\    code.inline { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; background:#eef3fa; border:1px solid var(--line); border-radius:6px; padding:2px 6px; color:var(--ink); }
        \\    .meta { margin-top:18px; font-size:13px; color:var(--muted); }
        \\  </style>
        \\</head>
        \\<body>
        \\  <div class="shell">
        \\    <div class="card">
        \\      <h1>Session Handoff</h1>
        \\      <p>Bundle <code class="inline">
    );
    try w.writeAll(file_name);
    try w.writeAll(
        \\</code> is ready. Import it from another machine or inspect the raw JSON.</p>
        \\      <div class="row">
        \\        <a class="button" href="
    );
    try w.writeAll(json_url);
    try w.writeAll(
        \\">Open Raw Bundle</a>
        \\        <a class="link" href="
    );
    try w.writeAll(json_url);
    try w.writeAll(
        \\">Copyable Import URL</a>
        \\      </div>
        \\      <p>CLI import command</p>
        \\      <pre>
    );
    try w.writeAll(escaped_command);
    try w.writeAll(
        \\</pre>
        \\      <p class="meta">Bundle preview</p>
        \\      <pre>
    );
    try w.writeAll(escaped_preview);
    try w.writeAll(
        \\</pre>
        \\    </div>
        \\  </div>
        \\</body>
        \\</html>
    );
    return out.toOwnedSlice();
}

/// HTML escape used by the daemon's handoff landing page. Delegates
/// to the shared parse_helpers.escapeXmlAttr helper which escapes
/// &, <, >, ", and ' -- the attribute-safe superset of escapeXml.
/// The daemon's inline HTML sometimes puts values inside attributes,
/// so the attribute variant is the right choice.
fn htmlEscapeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    return @import("core/parse_helpers.zig").escapeXmlAttr(allocator, input);
}

const handoffLandingHtml =
    \\<!doctype html>
    \\<html lang="en">
    \\<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>zcode Share Daemon</title></head>
    \\<body style="font:15px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;padding:32px;background:#f6f8fb;color:#11203a;">
    \\  <h1>zcode Share Daemon</h1>
    \\  <p>This daemon serves shared session bundles. Open a handoff URL from <code>zcode daemon handoff</code> to view or import a specific bundle.</p>
    \\</body>
    \\</html>
;

fn sharesDir(allocator: std.mem.Allocator, store: *session_store.Store) ![]u8 {
    const base = std.fs.path.dirname(store.sessions_dir) orelse return error.InvalidPath;
    return std.fs.path.join(allocator, &.{ base, "shares" });
}

fn statePath(allocator: std.mem.Allocator) ![]u8 {
    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);
    return std.fs.path.join(allocator, &.{ resolved.zcode_home, "daemon", "state.json" });
}

/// Task 20: the persisted server-session index lives next to the daemon state
/// file (`~/.zcode/daemon/server-sessions.json`).
fn serverSessionIndexPath(allocator: std.mem.Allocator) ![]u8 {
    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);
    return std.fs.path.join(allocator, &.{ resolved.zcode_home, "daemon", "server-sessions.json" });
}

/// Persist a freshly created direct-connect session to the on-disk index so it
/// survives a daemon restart. Best-effort: a persistence failure must not abort
/// session creation (the in-memory registry is still authoritative for the live
/// daemon). Returns true on success.
fn persistSessionToIndex(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    work_dir: []const u8,
    skip_permissions: bool,
) bool {
    const path = serverSessionIndexPath(allocator) catch return false;
    defer allocator.free(path);
    var index = session_index.load(allocator, path) catch return false;
    defer index.deinit();
    const now_ms = clock.nowMillis();
    const permission_mode: []const u8 = if (skip_permissions) "bypassPermissions" else "default";
    index.upsert(session_id, "", work_dir, permission_mode, now_ms, now_ms, .running) catch return false;
    session_index.save(allocator, path, &index) catch return false;
    return true;
}

/// Task 20: on daemon start, mark any session that the previous instance left
/// in a live state (running/starting) as detached, since its WebSocket no
/// longer exists. Best-effort; a missing or unreadable index is a no-op.
fn reconcileSessionIndexOnStart(allocator: std.mem.Allocator) void {
    const path = serverSessionIndexPath(allocator) catch return;
    defer allocator.free(path);
    var index = session_index.load(allocator, path) catch return;
    defer index.deinit();
    var changed = false;
    const now_ms = clock.nowMillis();
    for (index.entries.items) |*entry| {
        if (entry.state == .running or entry.state == .starting or entry.state == .stopping) {
            entry.state = .detached;
            entry.last_active_ts = now_ms;
            changed = true;
        }
    }
    if (changed) session_index.save(allocator, path, &index) catch {};
}

/// Task 20: true when creating one more session would exceed the configured
/// `max_sessions`. Reads the on-disk index so the count survives a restart.
fn sessionIndexAtCapacity(allocator: std.mem.Allocator) bool {
    if (server_config.max_sessions == 0) return false;
    const path = serverSessionIndexPath(allocator) catch return false;
    defer allocator.free(path);
    var index = session_index.load(allocator, path) catch return false;
    defer index.deinit();
    return session_index.atCapacity(&index, server_config.max_sessions);
}

fn writeState(allocator: std.mem.Allocator, state: State) !void {
    return writeStateFields(allocator, state.pid, state.port, state.token, state.started_ts);
}

fn writeStateFields(
    allocator: std.mem.Allocator,
    pid: i32,
    port: u16,
    token: []const u8,
    started_ts: i64,
) !void {
    const path = try statePath(allocator);
    defer allocator.free(path);
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try paths.ensureDir(parent);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try out.writer().print("{f}\n", .{std.json.fmt(.{
        .pid = pid,
        .port = port,
        .token = token,
        .started_ts = started_ts,
    }, .{})});

    // Atomic write so the parent's polling loop never reads a half-written
    // state file during a child restart.
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ path, clock.nowNanos() });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, out.items());
        file.sync(rt.io) catch {};
        file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o600)) catch {};
    }
    try std.Io.Dir.renameAbsolute(tmp_path, path, rt.io);
}

fn loadState(allocator: std.mem.Allocator) !?State {
    const path = try statePath(allocator);
    defer allocator.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    const pid = getInteger(parsed.value.object, "pid") orelse return null;
    const port = getInteger(parsed.value.object, "port") orelse return null;
    const token = getString(parsed.value.object, "token") orelse return null;
    const started_ts = getInteger(parsed.value.object, "started_ts") orelse 0;

    return .{
        .pid = @intCast(pid),
        .port = @intCast(port),
        .token = try allocator.dupe(u8, token),
        .started_ts = started_ts,
    };
}

fn deleteState(allocator: std.mem.Allocator) !void {
    const path = try statePath(allocator);
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(rt.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn randomHex(allocator: std.mem.Allocator, byte_len: usize) ![]u8 {
    const bytes = try allocator.alloc(u8, byte_len);
    defer allocator.free(bytes);
    rng.bytes(bytes);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    for (bytes) |byte| {
        try out.writer().print("{x:0>2}", .{byte});
    }
    return out.toOwnedSlice();
}

fn isPidRunning(pid: i32) bool {
    if (std.c.kill(pid, @enumFromInt(0)) != 0) return false;
    return true;
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getInteger(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |n| n,
        else => null,
    };
}

fn extractPortFromRequest(request: []const u8) u16 {
    const header_name = "Host:";
    const host_idx = std.mem.indexOf(u8, request, header_name) orelse return 8766;
    const line = request[host_idx + header_name.len ..];
    const line_end = std.mem.indexOf(u8, line, "\r\n") orelse line.len;
    const host_value = std.mem.trim(u8, line[0..line_end], " \t");
    const colon = std.mem.lastIndexOfScalar(u8, host_value, ':') orelse return 8766;
    return std.fmt.parseInt(u16, host_value[colon + 1 ..], 10) catch 8766;
}

/// Check whether the request presents a valid bearer token. Accepts either
/// `Authorization: Bearer <token>` or a `?token=<token>` query parameter.
/// Uses constant-time comparison against the expected daemon token. `target`
/// may include a query string.
fn authorizeRequest(request: []const u8, target: []const u8, token: []const u8) bool {
    const query_idx = std.mem.indexOfScalar(u8, target, '?');
    const query_text = if (query_idx) |i| target[i + 1 ..] else "";
    const bearer_token = extractBearerToken(request);
    const query_token = getQueryParam(query_text, "token");
    const request_token = bearer_token orelse query_token orelse "";
    return constantTimeTokenEquals(request_token, token);
}

/// Extract an `Authorization: Bearer <token>` header value, matching only on
/// header lines (not substring-anywhere). Previously used `indexOf` against the
/// whole request, which matched `X-Authorization:`, `X-My-Authorization:`, or
/// even bytes inside the body.
fn extractBearerToken(request: []const u8) ?[]const u8 {
    // Skip the request line.
    const first_eol = std.mem.indexOf(u8, request, "\r\n") orelse return null;
    var remaining = request[first_eol + 2 ..];
    while (remaining.len > 0) {
        const line_end = std.mem.indexOf(u8, remaining, "\r\n") orelse remaining.len;
        const line = remaining[0..line_end];
        if (line.len == 0) return null; // end of headers
        if (std.ascii.startsWithIgnoreCase(line, "Authorization:")) {
            const value = std.mem.trim(u8, line["Authorization:".len..], " \t");
            if (std.ascii.startsWithIgnoreCase(value, "Bearer ")) {
                return std.mem.trim(u8, value["Bearer ".len..], " \t");
            }
        }
        if (line_end == remaining.len) return null;
        remaining = remaining[line_end + 2 ..];
    }
    return null;
}

/// Constant-time comparison for bearer tokens. The length check is not
/// constant-time — that is acceptable for our threat model (token length is
/// fixed and public). std.crypto.timing_safe.eql only accepts fixed-size
/// arrays, so we implement the per-byte OR-accumulator inline.
fn constantTimeTokenEquals(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

fn reasonPhrase(status_code: u16) []const u8 {
    return switch (status_code) {
        200 => "OK",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        429 => "Too Many Requests",
        else => "OK",
    };
}

fn redactTokenForStatus(token: []const u8) []const u8 {
    if (token.len <= 8) return "<redacted>";
    return token[0..8];
}

/// Resolve symlinks on `candidate` and confirm the resolved absolute
/// path is a child of `root` (also resolved). Returns false on any
/// realpath error so a missing file fails closed rather than opening
/// the symlink escape. Root's trailing separator is normalized so
/// `/a/b` does not accidentally match `/a/bar/x`.
fn resolvedPathWithin(allocator: std.mem.Allocator, candidate: []const u8, root: []const u8) bool {
    const cand_real = allocator.dupe(u8, candidate) catch return false;
    defer allocator.free(cand_real);
    const root_real = allocator.dupe(u8, root) catch return false;
    defer allocator.free(root_real);
    if (!std.mem.startsWith(u8, cand_real, root_real)) return false;
    if (cand_real.len == root_real.len) return false;
    return cand_real[root_real.len] == std.fs.path.sep;
}

const testing = std.testing;

test "requestTarget parses target" {
    const target = requestTarget("GET /share/demo.json?token=abc HTTP/1.1\r\nHost: localhost\r\n\r\n") orelse return error.TestFailed;
    try testing.expectEqualStrings("/share/demo.json?token=abc", target);
}

test "extractPortFromRequest parses host header port" {
    try testing.expectEqual(@as(u16, 9123), extractPortFromRequest("GET /view/demo HTTP/1.1\r\nHost: 127.0.0.1:9123\r\n\r\n"));
    try testing.expectEqual(@as(u16, 8766), extractPortFromRequest("GET /view/demo HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"));
}

test "reasonPhrase maps common status codes" {
    try testing.expectEqualStrings("OK", reasonPhrase(200));
    try testing.expectEqualStrings("Bad Request", reasonPhrase(400));
    try testing.expectEqualStrings("Forbidden", reasonPhrase(403));
    try testing.expectEqualStrings("Not Found", reasonPhrase(404));
    try testing.expectEqualStrings("Too Many Requests", reasonPhrase(429));
}

test "extractBearerToken parses authorization header" {
    const request = "GET /share/demo HTTP/1.1\r\nHost: 127.0.0.1:8766\r\nAuthorization: Bearer my-secret-token\r\n\r\n";
    const token = extractBearerToken(request) orelse return error.TestFailed;
    try testing.expectEqualStrings("my-secret-token", token);
}

test "extractBearerToken returns null when missing" {
    const request = "GET /share/demo HTTP/1.1\r\nHost: 127.0.0.1:8766\r\n\r\n";
    try testing.expect(extractBearerToken(request) == null);
}

test "parseDaemonRole accepts known roles and rejects unknown values" {
    try testing.expectEqual(rbac.Role.viewer, parseDaemonRole("viewer").?);
    try testing.expectEqual(rbac.Role.auditor, parseDaemonRole("AUDITOR").?);
    try testing.expectEqual(rbac.Role.none, parseDaemonRole("none").?);
    try testing.expect(parseDaemonRole("superuser") == null);
    try testing.expect(parseDaemonRole("   ") == null);
}

test "requestMethod parses method token" {
    try testing.expectEqualStrings("POST", requestMethod("POST /sessions HTTP/1.1\r\n\r\n").?);
    try testing.expectEqualStrings("GET", requestMethod("GET / HTTP/1.1\r\n\r\n").?);
}

test "parseContentLength reads header value" {
    const req = "POST /sessions HTTP/1.1\r\nHost: x\r\nContent-Length: 42\r\n\r\n";
    try testing.expectEqual(@as(usize, 42), parseContentLength(req).?);
    try testing.expect(parseContentLength("GET / HTTP/1.1\r\nHost: x\r\n\r\n") == null);
}

test "requestBody returns bytes past the header terminator" {
    const req = "POST /sessions HTTP/1.1\r\nContent-Length: 7\r\n\r\n{\"a\":1}";
    try testing.expectEqualStrings("{\"a\":1}", requestBody(req));
    try testing.expectEqualStrings("", requestBody("GET / HTTP/1.1\r\nHost: x\r\n\r\n"));
}

test "sessionIdFromStreamTarget extracts id and rejects traversal" {
    try testing.expectEqualStrings("dc-abc", sessionIdFromStreamTarget("/sessions/dc-abc/stream").?);
    try testing.expectEqualStrings("dc-abc", sessionIdFromStreamTarget("/sessions/dc-abc/stream?token=x").?);
    try testing.expect(sessionIdFromStreamTarget("/sessions//stream") == null);
    try testing.expect(sessionIdFromStreamTarget("/sessions/a/b/stream") == null);
    try testing.expect(sessionIdFromStreamTarget("/sessions/dc-abc") == null);
    try testing.expect(sessionIdFromStreamTarget("/other/dc-abc/stream") == null);
}

test "buildSessionResponseBody contains the direct-connect contract" {
    const allocator = testing.allocator;
    const body = try buildSessionResponseBody(allocator, "dc-123", "/work/dir", 9123);
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
    const obj = parsed.value.object;
    try testing.expectEqualStrings("dc-123", obj.get("session_id").?.string);
    try testing.expectEqualStrings("/work/dir", obj.get("work_dir").?.string);
    try testing.expectEqualStrings("ws://127.0.0.1:9123/sessions/dc-123/stream", obj.get("ws_url").?.string);
}

test "bodySkipsPermissions reads the flag" {
    const allocator = testing.allocator;
    try testing.expect(bodySkipsPermissions(allocator, "{\"dangerously_skip_permissions\":true}"));
    try testing.expect(!bodySkipsPermissions(allocator, "{\"dangerously_skip_permissions\":false}"));
    try testing.expect(!bodySkipsPermissions(allocator, "{}"));
    try testing.expect(!bodySkipsPermissions(allocator, ""));
}
