//! Outbound IDE MCP client (ide-integration-02).
//!
//! Given a `Lockfile` from Task 01 (ide_lockfile.zig), open an outbound
//! MCP connection to a running IDE extension, send the lockfile's
//! authToken in the WebSocket upgrade handshake, complete the MCP
//! `initialize` handshake, fire the `ide_connected` notification, and
//! expose a request/response RPC path (`callRpc`) plus a pull-based
//! notification drain (`pollNotifications`). Tasks 03/04/05 sit on top
//! of this connection layer.
//!
//! This is a thin specialization of the WebSocket MCP client primitive
//! that already lives in mcp/client.zig. We reuse:
//!   - `client.performWebSocketHandshake` (the RFC 6455 client upgrade,
//!     including `Authorization: Bearer <token>`),
//!   - `websocket.zig` frame read/write (`writeClientTextFrame`,
//!     `readFrameReader`, ping/pong handling),
//!   - `client.encodeJsonAlloc` for request bodies,
//!   - `core/egress.zig` `checkUrl` as the egress chokepoint.
//!
//! Reference (claude-code-main/src/utils/ide.ts, services/mcp/client.ts):
//!   :793  URL = ws://host:port (ws) else http://host:port/sse
//!   :829  maybeNotifyIDEConnected -> { method:"ide_connected", params:{pid} }
//!   :1353 detectHostIP(isIdeRunningInWindows, port) host matrix
//!   :2116 callIdeRpc -> MCP request to the connected IDE client
//!
//! Egress note: the WS handshake routes through `egress.checkUrl`, which
//! allows loopback `ws://` outright. The WSL gateway IP is RFC1918 (not
//! loopback) and would be denied by the default policy, so the IDE path
//! passes `allow_private_network_plaintext = true`. This is safe: the
//! token and target host are both derived from a local lockfile the user
//! already trusts, and the gateway is the user's own Windows host.

const std = @import("std");
const builtin = @import("builtin");
const rt = @import("zcode_runtime");
const client = @import("client.zig");
const websocket = @import("websocket.zig");
const egress = @import("../core/egress.zig");
const platform = @import("../core/platform.zig");
const ide_lockfile = @import("../core/ide_lockfile.zig");
const std_io = @import("../core/std_io.zig");

/// TCP connect timeout for the WSL gateway probe in detectHostIp.
/// Matches the reference's 500ms liveness check (utils/ide.ts:402).
const HOST_PROBE_TIMEOUT_MS: u64 = 500;

/// Loopback host used for the common (non-WSL) case.
const LOOPBACK: []const u8 = "127.0.0.1";

/// A JSON-RPC notification pushed by the IDE extension on the socket
/// (e.g. `selection_changed`, `at_mentioned`). Owned by the caller of
/// `pollNotifications`; free with `freeNotifications`.
pub const Notification = struct {
    method: []u8,
    params_json: []u8,

    pub fn deinit(self: *Notification, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        allocator.free(self.params_json);
    }
};

/// Free a slice of notifications returned by `pollNotifications`.
pub fn freeNotifications(allocator: std.mem.Allocator, list: []Notification) void {
    for (list) |*n| n.deinit(allocator);
    if (list.len > 0) allocator.free(list);
}

/// Cap on buffered inbound notifications; mirrors mcp/client.zig's
/// MAX_NOTIFICATION_EVENTS so a chatty extension cannot grow this
/// unbounded between drains.
const MAX_NOTIFICATIONS: usize = 256;

pub const IdeClient = struct {
    allocator: std.mem.Allocator,
    http_client: *std.http.Client,
    connection: *std.http.Client.Connection,
    /// Monotonic JSON-RPC request id (starts at 2; id 1 is the
    /// initialize handshake).
    next_id: i64,
    /// Buffered notifications drained by `pollNotifications`.
    notifications: std.array_list.Managed(Notification),
    /// Names of diff tabs we have opened, so Task 03's closeAllDiffTabs
    /// sweep is deterministic. Owned.
    open_tabs: std.array_list.Managed([]u8),

    /// Connect to the IDE extension described by `lockfile`, complete the
    /// MCP initialize handshake, and send the `ide_connected`
    /// notification. Caller owns the result; call `deinit`.
    pub fn connect(allocator: std.mem.Allocator, lockfile: ide_lockfile.Lockfile) !IdeClient {
        // The bundled extension speaks ws; the reference's `sse`
        // (streamable-HTTP GET stream at /sse) is not yet supported here.
        if (!lockfile.use_websocket) return error.UnsupportedTransport;

        const host = try detectHostIp(allocator, lockfile.running_in_windows, lockfile.port);
        defer allocator.free(host);

        const url = try std.fmt.allocPrint(allocator, "ws://{s}:{d}", .{ host, lockfile.port });
        defer allocator.free(url);

        return connectUrl(allocator, url, lockfile.auth_token);
    }

    /// Connect to an explicit `ws://host:port` URL with an optional
    /// auth token. Split out from `connect` so tests can dial a
    /// loopback server directly without synthesizing a Lockfile.
    pub fn connectUrl(allocator: std.mem.Allocator, url: []const u8, auth_token: ?[]const u8) !IdeClient {
        // Egress chokepoint. allow_private_network_plaintext = true so
        // a WSL gateway IP (RFC1918) is permitted; loopback is allowed
        // regardless. See the module-level egress note.
        switch (egress.checkUrl(allocator, url, .{ .allow_private_network_plaintext = true })) {
            .allow => {},
            .deny_scheme, .deny_ssrf, .deny_allowlist, .deny_denylist => return error.UrlPolicyDenied,
        }

        const uri = try std.Uri.parse(url);
        const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.UnsupportedTransport;

        const http_client = try allocator.create(std.http.Client);
        errdefer allocator.destroy(http_client);
        http_client.* = .{ .allocator = allocator, .io = rt.io };
        errdefer http_client.deinit();

        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = try uri.getHost(&host_buf);
        const port = uri.port orelse return error.MissingPort;
        const connection = try http_client.connectTcp(host, port, protocol);
        errdefer {
            connection.closing = true;
            http_client.connection_pool.release(connection, rt.io);
        }

        try client.performWebSocketHandshake(allocator, connection, uri, auth_token);

        var self = IdeClient{
            .allocator = allocator,
            .http_client = http_client,
            .connection = connection,
            .next_id = 2,
            .notifications = std.array_list.Managed(Notification).init(allocator),
            .open_tabs = std.array_list.Managed([]u8).init(allocator),
        };
        errdefer {
            self.notifications.deinit();
            self.open_tabs.deinit();
        }

        try self.sendInitialize();
        try self.sendIdeConnected();
        return self;
    }

    pub fn deinit(self: *IdeClient) void {
        websocket.writeClientCloseFrame(self.connection.writer()) catch {};
        self.connection.flush() catch {};
        self.connection.closing = true;
        self.http_client.connection_pool.release(self.connection, rt.io);
        self.http_client.deinit();
        self.allocator.destroy(self.http_client);

        for (self.notifications.items) |*n| n.deinit(self.allocator);
        self.notifications.deinit();
        for (self.open_tabs.items) |t| self.allocator.free(t);
        self.open_tabs.deinit();
    }

    /// Issue an MCP JSON-RPC request and return the raw `result` JSON.
    /// `params_json` is the already-serialized params object (e.g.
    /// `"{\"old_file_path\":\"...\"}"`); pass `"{}"` for none. Inbound
    /// notifications arriving before the matching response are buffered
    /// for `pollNotifications`. Caller owns the returned slice.
    pub fn callRpc(self: *IdeClient, method: []const u8, params_json: []const u8) ![]u8 {
        const id = self.nextId();
        // Build the body by hand rather than via the anytype encoder so
        // we can splice the pre-serialized `params_json` in raw.
        const body = try buildRequest(self.allocator, id, method, params_json);
        defer self.allocator.free(body);

        try websocket.writeClientTextFrame(self.connection.writer(), body);
        try self.connection.flush();

        return self.readResponseById(id);
    }

    /// Snapshot and clear the buffered inbound notifications. The REPL
    /// drains this each turn. Caller owns the result; free with
    /// `freeNotifications`.
    pub fn pollNotifications(self: *IdeClient) ![]Notification {
        const out = try self.notifications.toOwnedSlice();
        self.notifications = std.array_list.Managed(Notification).init(self.allocator);
        return out;
    }

    /// Record an open diff tab name so a later closeAllDiffTabs sweep
    /// knows which tabs to close (Task 03). Best-effort; dedupes.
    pub fn trackOpenTab(self: *IdeClient, tab_name: []const u8) !void {
        for (self.open_tabs.items) |t| {
            if (std.mem.eql(u8, t, tab_name)) return;
        }
        const owned = try self.allocator.dupe(u8, tab_name);
        errdefer self.allocator.free(owned);
        try self.open_tabs.append(owned);
    }

    /// Forget a tracked open tab (after it is closed). No-op if absent.
    pub fn untrackOpenTab(self: *IdeClient, tab_name: []const u8) void {
        var i: usize = 0;
        while (i < self.open_tabs.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.open_tabs.items[i], tab_name)) {
                const removed = self.open_tabs.orderedRemove(i);
                self.allocator.free(removed);
                return;
            }
        }
    }

    // -- internals --------------------------------------------------------

    fn nextId(self: *IdeClient) i64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn sendInitialize(self: *IdeClient) !void {
        const init_req = try client.encodeJsonAlloc(self.allocator, .{
            .jsonrpc = "2.0",
            .id = 1,
            .method = "initialize",
            .params = .{
                .protocolVersion = "2024-11-05",
                .capabilities = .{},
                .clientInfo = .{ .name = "zcode", .version = "ide" },
            },
        });
        defer self.allocator.free(init_req);

        try websocket.writeClientTextFrame(self.connection.writer(), init_req);
        try self.connection.flush();

        const resp = try self.readResponseById(1);
        self.allocator.free(resp);

        const initialized = try client.encodeJsonAlloc(self.allocator, .{
            .jsonrpc = "2.0",
            .method = "notifications/initialized",
            .params = .{},
        });
        defer self.allocator.free(initialized);
        try websocket.writeClientTextFrame(self.connection.writer(), initialized);
        try self.connection.flush();
    }

    /// Reference maybeNotifyIDEConnected (utils/ide.ts:829): notification
    /// { method:"ide_connected", params:{ pid: <our pid> } }.
    fn sendIdeConnected(self: *IdeClient) !void {
        const pid = getpid();
        const notif = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"ide_connected\",\"params\":{{\"pid\":{d}}}}}",
            .{pid},
        );
        defer self.allocator.free(notif);
        try websocket.writeClientTextFrame(self.connection.writer(), notif);
        try self.connection.flush();
    }

    /// Read WS frames until a JSON-RPC response with `expected_id`
    /// arrives. Inbound notifications (method present, no id) are
    /// buffered for pollNotifications; server->client requests are
    /// ignored (the IDE extension does not issue requests to us).
    fn readResponseById(self: *IdeClient, expected_id: i64) ![]u8 {
        var attempts: usize = 0;
        while (attempts < 64) : (attempts += 1) {
            const message = try self.readTextMessage();
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
            const obj = parsed.value.object;

            // A notification has a method and no id.
            if (obj.get("method")) |mv| {
                if (mv == .string and obj.get("id") == null) {
                    self.bufferNotification(obj, mv.string) catch {};
                }
                self.allocator.free(message);
                continue;
            }

            if (obj.get("id")) |idv| {
                if (idv == .integer and idv.integer == expected_id) {
                    const result = try extractResultJson(self.allocator, obj);
                    self.allocator.free(message);
                    return result;
                }
            }

            self.allocator.free(message);
        }
        return error.McpResponseTimeout;
    }

    fn bufferNotification(self: *IdeClient, obj: std.json.ObjectMap, method: []const u8) !void {
        const params_json = if (obj.get("params")) |p|
            try jsonValueToOwned(self.allocator, p)
        else
            try self.allocator.dupe(u8, "{}");
        errdefer self.allocator.free(params_json);

        const method_owned = try self.allocator.dupe(u8, method);
        errdefer self.allocator.free(method_owned);

        try self.notifications.append(.{ .method = method_owned, .params_json = params_json });
        while (self.notifications.items.len > MAX_NOTIFICATIONS) {
            var oldest = self.notifications.orderedRemove(0);
            oldest.deinit(self.allocator);
        }
    }

    /// Read one complete WS text message (reassembling fragments, handling
    /// ping/pong). Mirrors client.zig readWebSocketTextMessage.
    fn readTextMessage(self: *IdeClient) ![]u8 {
        var out = std_io.StringBuilder.init(self.allocator);
        errdefer out.deinit();
        var saw_text = false;

        while (true) {
            var frame = try websocket.readFrameReader(self.allocator, self.connection.reader(), .client);
            defer frame.deinit(self.allocator);

            switch (frame.opcode) {
                .ping => {
                    try websocket.writeClientPongFrame(self.connection.writer(), frame.payload);
                    try self.connection.flush();
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
                else => continue,
            }
        }
    }
};

/// Build a JSON-RPC request that splices already-serialized `params_json`
/// in raw (the anytype encoder cannot do that).
fn buildRequest(allocator: std.mem.Allocator, id: i64, method: []const u8, params_json: []const u8) ![]u8 {
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    const w = buf.writer();
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try w.print("{d}", .{id});
    try w.writeAll(",\"method\":");
    try w.print("{f}", .{std.json.fmt(method, .{})});
    try w.writeAll(",\"params\":");
    const trimmed = std.mem.trim(u8, params_json, " \t\r\n");
    if (trimmed.len > 0) {
        try w.writeAll(trimmed);
    } else {
        try w.writeAll("{}");
    }
    try w.writeByte('}');
    return buf.toOwnedSlice();
}

/// Serialize a json.Value subtree back to a fresh owned string.
fn jsonValueToOwned(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    try buf.writer().print("{f}", .{std.json.fmt(value, .{})});
    return buf.toOwnedSlice();
}

/// Extract the `result` member of a JSON-RPC response object as a fresh
/// owned JSON string. A JSON-RPC error object surfaces error.RpcError.
fn extractResultJson(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]u8 {
    if (obj.get("error") != null) return error.RpcError;
    const result = obj.get("result") orelse return allocator.dupe(u8, "null");
    return jsonValueToOwned(allocator, result);
}

/// Real OS PID (mirrors ide_lockfile.zig getpid switch).
fn getpid() i32 {
    return switch (builtin.os.tag) {
        .linux => std.os.linux.getpid(),
        else => std.c.getpid(),
    };
}

/// Resolve the host the IDE extension is reachable on. Mirrors the
/// reference detectHostIP matrix (utils/ide.ts:1353):
///   1. CLAUDE_CODE_IDE_HOST_OVERRIDE wins outright.
///   2. Non-WSL, or IDE not running in Windows -> 127.0.0.1.
///   3. WSL + Windows IDE -> the default-route gateway IP from
///      /proc/net/route, if its `port` responds; else 127.0.0.1.
/// Returns an owned string.
pub fn detectHostIp(allocator: std.mem.Allocator, running_in_windows: bool, port: u16) ![]u8 {
    const xdg = @import("../core/xdg.zig");
    if (xdg.getEnvOptional(allocator, "CLAUDE_CODE_IDE_HOST_OVERRIDE")) |override| {
        if (override.len > 0) return override;
        allocator.free(override);
    }

    if (platform.detect() != .wsl or !running_in_windows) {
        return allocator.dupe(u8, LOOPBACK);
    }

    // WSL + Windows IDE: find the default-route gateway (the Windows
    // host) and use it iff the IDE port is reachable there.
    if (defaultRouteGateway(allocator)) |gw| {
        defer allocator.free(gw);
        if (portRespondsOn(gw, port)) return allocator.dupe(u8, gw);
    } else |_| {}

    return allocator.dupe(u8, LOOPBACK);
}

/// Parse /proc/net/route for the default route (Destination 00000000)
/// and return its Gateway as a dotted-quad string. The Gateway field is
/// a little-endian hex u32. Reading the proc file is more portable than
/// shelling out to `ip route` (CLAUDE.md prefers it).
fn defaultRouteGateway(allocator: std.mem.Allocator) ![]u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, "/proc/net/route", allocator, .limited(64 * 1024)) catch return error.NoGateway;
    defer allocator.free(bytes);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    _ = lines.next(); // header row
    while (lines.next()) |line| {
        // Columns: Iface Destination Gateway Flags ...
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        _ = fields.next() orelse continue; // Iface
        const dest = fields.next() orelse continue;
        const gateway = fields.next() orelse continue;
        if (!std.mem.eql(u8, dest, "00000000")) continue; // not default route
        const gw_le = std.fmt.parseInt(u32, gateway, 16) catch continue;
        if (gw_le == 0) continue;
        // The field is little-endian: byte 0 is the first octet.
        const b0: u8 = @truncate(gw_le);
        const b1: u8 = @truncate(gw_le >> 8);
        const b2: u8 = @truncate(gw_le >> 16);
        const b3: u8 = @truncate(gw_le >> 24);
        return std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{ b0, b1, b2, b3 });
    }
    return error.NoGateway;
}

/// 500ms TCP connect probe to host:port. Best-effort; never throws.
fn portRespondsOn(host: []const u8, port: u16) bool {
    if (port == 0) return false;
    const addr = std.Io.net.IpAddress.parse(host, port) catch return false;
    const stream = std.Io.net.IpAddress.connect(&addr, rt.io, .{
        .mode = .stream,
        .timeout = .{ .duration = .{
            .raw = .{ .nanoseconds = HOST_PROBE_TIMEOUT_MS * std.time.ns_per_ms },
            .clock = .awake,
        } },
    }) catch return false;
    stream.close(rt.io);
    return true;
}

// -- Tests ----------------------------------------------------------------

const testing = std.testing;
const env = @import("../core/env.zig");
const test_helpers = @import("../core/test_helpers.zig");

test "detectHostIp honors CLAUDE_CODE_IDE_HOST_OVERRIDE regardless of platform" {
    try env.setOverride("CLAUDE_CODE_IDE_HOST_OVERRIDE", "10.0.0.5");
    defer env.clearOverrides();

    const host = try detectHostIp(testing.allocator, true, 1234);
    defer testing.allocator.free(host);
    try testing.expectEqualStrings("10.0.0.5", host);
}

test "detectHostIp returns loopback when not WSL even with Windows IDE flag" {
    // The dev/CI host is macOS or plain Linux, so platform.detect() is
    // not .wsl. The non-WSL branch must short-circuit to loopback before
    // any gateway probe.
    if (platform.detect() == .wsl) return error.SkipZigTest;
    const host = try detectHostIp(testing.allocator, true, 1234);
    defer testing.allocator.free(host);
    try testing.expectEqualStrings("127.0.0.1", host);
}

test "buildRequest splices raw params and a present id" {
    const body = try buildRequest(testing.allocator, 7, "openDiff", "{\"k\":1}");
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"openDiff\",\"params\":{\"k\":1}}",
        body,
    );
}

test "buildRequest defaults empty params to an empty object" {
    const body = try buildRequest(testing.allocator, 3, "ping", "");
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\",\"params\":{}}",
        body,
    );
}

test "extractResultJson returns the result subtree and flags rpc errors" {
    const allocator = testing.allocator;
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":1,\"result\":{\"ok\":true}}", .{});
        defer parsed.deinit();
        const out = try extractResultJson(allocator, parsed.value.object);
        defer allocator.free(out);
        try testing.expectEqualStrings("{\"ok\":true}", out);
    }
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"id\":1,\"error\":{\"code\":-32000}}", .{});
        defer parsed.deinit();
        try testing.expectError(error.RpcError, extractResultJson(allocator, parsed.value.object));
    }
}

test "loopback IDE client connects, calls rpc, and surfaces a pushed notification" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Minimal in-process MCP-over-WS server (Python): complete the
    // initialize handshake, ignore notifications/initialized and
    // ide_connected, push a selection_changed notification, then echo a
    // canned result for the next request id.
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "ide_ws.py", .data =
        \\import base64, hashlib, json, socket, struct
        \\GUID = "258EAFA5-E914-47DA-95CA-5AB5DC525C76"
        \\def recv_exact(c, n):
        \\    d = b""
        \\    while len(d) < n:
        \\        ch = c.recv(n - len(d))
        \\        if not ch: raise EOFError()
        \\        d += ch
        \\    return d
        \\def read_http(c):
        \\    d = b""
        \\    while b"\r\n\r\n" not in d:
        \\        ch = c.recv(4096)
        \\        if not ch: raise EOFError()
        \\        d += ch
        \\    return d
        \\def write_frame(c, op, payload=b"", fin=True):
        \\    if isinstance(payload, str): payload = payload.encode("utf-8")
        \\    first = (0x80 if fin else 0) | op
        \\    h = bytes([first])
        \\    n = len(payload)
        \\    if n < 126: h += bytes([n])
        \\    elif n < 65536: h += bytes([126]) + struct.pack(">H", n)
        \\    else: h += bytes([127]) + struct.pack(">Q", n)
        \\    c.sendall(h + payload)
        \\def read_frame(c):
        \\    head = recv_exact(c, 2)
        \\    b1, b2 = head[0], head[1]
        \\    fin = bool(b1 & 0x80); op = b1 & 0x0F
        \\    masked = bool(b2 & 0x80); size = b2 & 0x7F
        \\    if size == 126: size = struct.unpack(">H", recv_exact(c, 2))[0]
        \\    elif size == 127: size = struct.unpack(">Q", recv_exact(c, 8))[0]
        \\    mask = recv_exact(c, 4) if masked else b""
        \\    payload = bytearray(recv_exact(c, size))
        \\    if masked:
        \\        for i in range(size): payload[i] ^= mask[i % 4]
        \\    return fin, op, bytes(payload)
        \\def read_text(c):
        \\    out = bytearray(); started = False
        \\    while True:
        \\        fin, op, payload = read_frame(c)
        \\        if op == 0x9:
        \\            write_frame(c, 0xA, payload); continue
        \\        if op == 0x8: return None
        \\        if op == 0x1:
        \\            started = True; out.extend(payload)
        \\            if fin: return out.decode("utf-8")
        \\        elif op == 0x0 and started:
        \\            out.extend(payload)
        \\            if fin: return out.decode("utf-8")
        \\def serve(server):
        \\    conn, _ = server.accept()
        \\    with conn:
        \\        req = read_http(conn).decode("utf-8", "replace")
        \\        key = ""
        \\        for line in req.split("\r\n"):
        \\            if line.lower().startswith("sec-websocket-key:"):
        \\                key = line.split(":", 1)[1].strip()
        \\        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        \\        conn.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n").encode())
        \\        while True:
        \\            text = read_text(conn)
        \\            if text is None: break
        \\            msg = json.loads(text)
        \\            method = msg.get("method")
        \\            if method == "initialize":
        \\                write_frame(conn, 0x1, json.dumps({"jsonrpc":"2.0","id":msg["id"],"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"ide-mock","version":"0.1"}}}))
        \\            elif method == "notifications/initialized":
        \\                pass
        \\            elif method == "ide_connected":
        \\                write_frame(conn, 0x1, json.dumps({"jsonrpc":"2.0","method":"selection_changed","params":{"text":"hi"}}))
        \\            elif method == "ping":
        \\                write_frame(conn, 0x1, json.dumps({"jsonrpc":"2.0","id":msg["id"],"result":{"pong":True}}))
        \\                break
        \\s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        \\s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        \\s.bind(("127.0.0.1", 0)); s.listen(5)
        \\print(s.getsockname()[1], flush=True)
        \\serve(s)
    });

    const script = try test_helpers.tmpDirPath(allocator, &tmp, "ide_ws.py");
    defer allocator.free(script);

    var child = std.process.spawn(rt.io, .{
        .argv = &[_][]const u8{ "python3", script },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return error.SkipZigTest;
    defer {
        // 0.16: child.kill internally waits and reaps; do not wait() after.
        child.kill(rt.io);
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

    const url = try std.fmt.allocPrint(allocator, "ws://127.0.0.1:{d}", .{port});
    defer allocator.free(url);

    var ide = try IdeClient.connectUrl(allocator, url, null);
    defer ide.deinit();

    const result = try ide.callRpc("ping", "{}");
    defer allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "pong") != null);

    // The server pushed selection_changed between handshake and the ping
    // response; readResponseById buffered it. Drain it.
    const notifs = try ide.pollNotifications();
    defer freeNotifications(allocator, notifs);
    var saw_selection = false;
    for (notifs) |n| {
        if (std.mem.eql(u8, n.method, "selection_changed")) saw_selection = true;
    }
    try testing.expect(saw_selection);
}
