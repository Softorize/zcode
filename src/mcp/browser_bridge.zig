const std = @import("std");
const clock = @import("../core/clock.zig");
const std_io = @import("../core/std_io.zig");
const rt = @import("zcode_runtime");
const build_options = @import("build_options");
const websocket = @import("websocket.zig");
const mcp_client = @import("client.zig");

const WS_RESPONSE_TIMEOUT_MS: i32 = 30_000;
const UPGRADE_BUF_SIZE: usize = 4096;

pub const BrowserBridge = struct {
    allocator: std.mem.Allocator,
    port: u16,
    server: ?std.Io.net.Server,
    conn: ?std.Io.net.Stream,
    conn_mutex: std.Io.Mutex,
    accept_thread: ?std.Thread,
    shutdown: std.atomic.Value(bool),
    initialized: bool,
    next_id: i64,

    pub fn init(allocator: std.mem.Allocator, port: u16) BrowserBridge {
        return .{
            .allocator = allocator,
            .port = port,
            .server = null,
            .conn = null,
            .conn_mutex = .init,
            .accept_thread = null,
            .shutdown = std.atomic.Value(bool).init(false),
            .initialized = false,
            .next_id = 10,
        };
    }

    pub fn deinit(self: *BrowserBridge) void {
        self.stop();
    }

    /// Bind TCP on 127.0.0.1:port and spawn the accept thread.
    pub fn start(self: *BrowserBridge) !void {
        const address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = self.port } };
        self.server = address.listen(rt.io, .{ .reuse_address = true }) catch |err| {
            std.log.err("Chrome bridge: failed to listen on port {d}: {s}", .{ self.port, @errorName(err) });
            return err;
        };
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    /// Signal shutdown, close server socket, join accept thread.
    pub fn stop(self: *BrowserBridge) void {
        self.shutdown.store(true, .release);

        // Close any active connection
        self.conn_mutex.lock(rt.io) catch {};
        if (self.conn) |conn| {
            websocket.writeCloseFrame(conn) catch {};
            conn.close(rt.io);
            self.conn = null;
            self.initialized = false;
        }
        self.conn_mutex.unlock(rt.io);

        self.wakeAcceptLoop();

        // Join the accept thread
        if (self.accept_thread) |thread| {
            thread.join();
            self.accept_thread = null;
        }

        if (self.server) |*server| {
            server.deinit(rt.io);
            self.server = null;
        }
    }

    pub fn isConnected(self: *BrowserBridge) bool {
        self.conn_mutex.lock(rt.io) catch {};
        defer self.conn_mutex.unlock(rt.io);
        return self.conn != null and self.initialized;
    }

    /// Discover tools from the Chrome extension via MCP tools/list.
    pub fn listTools(self: *BrowserBridge) ![]mcp_client.ToolInfo {
        self.conn_mutex.lock(rt.io) catch {};
        defer self.conn_mutex.unlock(rt.io);

        const conn = self.conn orelse return error.NotConnected;
        if (!self.initialized) return error.NotInitialized;

        const id = self.nextId();
        const req_json = try mcp_client.encodeJsonAlloc(self.allocator, .{
            .jsonrpc = "2.0",
            .id = id,
            .method = "tools/list",
            .params = .{},
        });
        defer self.allocator.free(req_json);

        websocket.writeTextFrame(conn, req_json) catch |err| {
            self.resetConnection();
            return err;
        };

        const resp = self.readJsonResponse(conn, id) catch |err| {
            self.resetConnection();
            return err;
        };
        defer self.allocator.free(resp);

        return mcp_client.parseToolsResponse(self.allocator, resp);
    }

    /// Invoke a tool on the Chrome extension via MCP tools/call.
    pub fn invoke(self: *BrowserBridge, tool_name: []const u8, args_json: []const u8) ![]u8 {
        self.conn_mutex.lock(rt.io) catch {};
        defer self.conn_mutex.unlock(rt.io);

        const conn = self.conn orelse return self.allocator.dupe(u8, "Chrome bridge: not connected");
        if (!self.initialized) return self.allocator.dupe(u8, "Chrome bridge: not initialized");

        const id = self.nextId();

        // Build the JSON-RPC request with raw arguments
        var buf = std_io.StringBuilder.init(self.allocator);
        defer buf.deinit();
        const writer = buf.writer();
        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try writer.print("{d}", .{id});
        try writer.writeAll(",\"method\":\"tools/call\",\"params\":{\"name\":\"");
        try writer.writeAll(tool_name);
        try writer.writeAll("\",\"arguments\":");
        if (args_json.len > 0 and args_json[0] == '{') {
            try writer.writeAll(args_json);
        } else {
            try writer.writeAll("{}");
        }
        try writer.writeAll("}}");

        websocket.writeTextFrame(conn, buf.items()) catch |err| {
            self.resetConnection();
            return std.fmt.allocPrint(self.allocator, "Chrome bridge: write error: {s}", .{@errorName(err)});
        };

        const resp = self.readJsonResponse(conn, id) catch |err| {
            self.resetConnection();
            return std.fmt.allocPrint(self.allocator, "Chrome bridge: read error: {s}", .{@errorName(err)});
        };
        defer self.allocator.free(resp);

        return mcp_client.extractToolCallResultText(self.allocator, resp);
    }

    // --- Private methods ---

    fn nextId(self: *BrowserBridge) i64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    /// Reset connection state (caller must hold conn_mutex).
    fn resetConnection(self: *BrowserBridge) void {
        if (self.conn) |conn| {
            conn.close(rt.io);
        }
        self.conn = null;
        self.initialized = false;
    }

    fn wakeAcceptLoop(self: *BrowserBridge) void {
        if (self.server == null or self.accept_thread == null) return;
        const address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = self.port } };
        const stream = std.Io.net.IpAddress.connect(&address, rt.io, .{ .mode = .stream }) catch return;
        stream.close(rt.io);
    }

    /// Read one complete WebSocket text message from a connected client, handling
    /// fragmentation per RFC 6455 §5.4 and interleaved control frames. Caller owns
    /// the returned buffer. The full reassembled payload is validated as UTF-8
    /// per RFC 6455 §8.1; invalid sequences fail the read with InvalidUtf8.
    fn readTextMessage(self: *BrowserBridge, conn: std.Io.net.Stream, timeout_ms: i32) ![]u8 {
        var out = std_io.StringBuilder.init(self.allocator);
        errdefer out.deinit();
        var saw_text = false;

        while (true) {
            var frame = try websocket.readFrame(self.allocator, conn, timeout_ms, .server);
            defer frame.deinit(self.allocator);

            switch (frame.opcode) {
                .ping => {
                    websocket.writePongFrame(conn, frame.payload) catch {};
                    continue;
                },
                .pong => continue,
                .close => return error.ConnectionClosed,
                .text => {
                    if (saw_text) return error.InterleavedDataFrame;
                    saw_text = true;
                    try out.appendSlice(frame.payload);
                    if (frame.fin) {
                        if (!std.unicode.utf8ValidateSlice(out.items())) return error.InvalidUtf8;
                        return out.toOwnedSlice();
                    }
                },
                .binary => {
                    // We don't consume binary messages here; drain and ignore.
                    if (frame.fin) continue;
                    // Enter "dropping" mode until FIN arrives.
                    while (true) {
                        var next = try websocket.readFrame(self.allocator, conn, timeout_ms, .server);
                        defer next.deinit(self.allocator);
                        if (next.opcode == .continuation and next.fin) break;
                        if (next.opcode == .close) return error.ConnectionClosed;
                    }
                    continue;
                },
                .continuation => {
                    if (!saw_text) return error.UnexpectedContinuationFrame;
                    try out.appendSlice(frame.payload);
                    if (frame.fin) {
                        if (!std.unicode.utf8ValidateSlice(out.items())) return error.InvalidUtf8;
                        return out.toOwnedSlice();
                    }
                },
                else => return error.InvalidOpcode,
            }
        }
    }

    /// Read WebSocket frames until we find a JSON-RPC response with the expected ID.
    /// Handles ping frames and fragmented messages automatically.
    fn readJsonResponse(self: *BrowserBridge, conn: std.Io.net.Stream, expected_id: i64) ![]u8 {
        var attempts: usize = 0;
        while (attempts < 32) : (attempts += 1) {
            const payload = try self.readTextMessage(conn, WS_RESPONSE_TIMEOUT_MS);
            var release = true;
            defer if (release) self.allocator.free(payload);

            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{}) catch continue;
            defer parsed.deinit();

            if (parsed.value == .object) {
                if (parsed.value.object.get("id")) |idv| {
                    if (idv == .integer and idv.integer == expected_id) {
                        release = false;
                        return payload;
                    }
                }
            }
        }

        return error.ResponseTimeout;
    }

    /// Background thread: accept incoming connections and perform WS + MCP handshake.
    fn acceptLoop(self: *BrowserBridge) void {
        while (!self.shutdown.load(.acquire)) {
            var server = self.server orelse break;

            var poll_fds = [_]std.posix.pollfd{.{
                .fd = server.socket.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const ready = std.posix.poll(&poll_fds, 250) catch |err| {
                if (self.shutdown.load(.acquire)) break;
                std.log.warn("Chrome bridge: poll error: {s}", .{@errorName(err)});
                clock.sleepNanos(250 * std.time.ns_per_ms);
                continue;
            };
            if (ready == 0) continue;

            const conn_result = server.accept(rt.io);
            const accepted = conn_result catch |err| {
                if (self.shutdown.load(.acquire)) break;
                std.log.warn("Chrome bridge: accept error: {s}", .{@errorName(err)});
                // Backoff to prevent spinning on persistent errors
                clock.sleepNanos(500 * std.time.ns_per_ms);
                continue;
            };

            if (self.shutdown.load(.acquire)) {
                accepted.close(rt.io);
                break;
            }

            // Close any existing connection first
            self.conn_mutex.lock(rt.io) catch {};
            if (self.conn) |old_conn| {
                websocket.writeCloseFrame(old_conn) catch {};
                old_conn.close(rt.io);
            }
            self.conn = null;
            self.initialized = false;
            self.conn_mutex.unlock(rt.io);

            // Perform WebSocket upgrade handshake
            const stream = accepted;
            var upgrade_buf: [UPGRADE_BUF_SIZE]u8 = undefined;
            var total: usize = 0;

            // Read the HTTP upgrade request
            const upgrade_ok = blk: {
                while (total < UPGRADE_BUF_SIZE) {
                    const n = std_io.streamRead(stream, upgrade_buf[total..]) catch break :blk false;
                    if (n == 0) break :blk false;
                    total += n;
                    if (std.mem.indexOf(u8, upgrade_buf[0..total], "\r\n\r\n") != null) break;
                }

                const ws_key = websocket.parseUpgradeRequest(upgrade_buf[0..total]) orelse break :blk false;
                websocket.sendUpgradeResponse(stream, ws_key) catch break :blk false;
                break :blk true;
            };

            if (!upgrade_ok) {
                stream.close(rt.io);
                continue;
            }

            // Perform MCP initialize handshake over WebSocket
            const mcp_ok = self.performMcpHandshake(stream);

            self.conn_mutex.lock(rt.io) catch {};
            if (mcp_ok) {
                self.conn = stream;
                self.initialized = true;
            } else {
                stream.close(rt.io);
                std.log.warn("Chrome bridge: MCP handshake failed", .{});
            }
            self.conn_mutex.unlock(rt.io);
        }
    }

    /// Send MCP initialize request and read the response, then send initialized notification.
    fn performMcpHandshake(self: *BrowserBridge, stream: std.Io.net.Stream) bool {
        const init_req = mcp_client.encodeJsonAlloc(self.allocator, .{
            .jsonrpc = "2.0",
            .id = 1,
            .method = "initialize",
            .params = .{
                .protocolVersion = "2024-11-05",
                .capabilities = .{},
                .clientInfo = .{ .name = "zcode", .version = build_options.app_version },
            },
        }) catch return false;
        defer self.allocator.free(init_req);

        websocket.writeTextFrame(stream, init_req) catch return false;

        // Read response (with shorter timeout for handshake)
        var attempts: usize = 0;
        while (attempts < 8) : (attempts += 1) {
            const payload = self.readTextMessage(stream, 10_000) catch return false;
            defer self.allocator.free(payload);

            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{}) catch continue;
            defer parsed.deinit();

            if (parsed.value == .object) {
                if (parsed.value.object.get("id")) |idv| {
                    if (idv == .integer and idv.integer == 1) {
                        // Got initialize response, send initialized notification
                        const notif = mcp_client.encodeJsonAlloc(self.allocator, .{
                            .jsonrpc = "2.0",
                            .method = "notifications/initialized",
                            .params = .{},
                        }) catch return false;
                        defer self.allocator.free(notif);
                        websocket.writeTextFrame(stream, notif) catch return false;
                        return true;
                    }
                }
            }
        }

        return false;
    }
};

const testing = std.testing;

test "BrowserBridge init and deinit" {
    var bridge = BrowserBridge.init(testing.allocator, 19333);
    bridge.deinit();
}

test "BrowserBridge start and stop" {
    var bridge = BrowserBridge.init(testing.allocator, 19335);
    try bridge.start();
    bridge.stop();
}

test "BrowserBridge not connected returns error" {
    var bridge = BrowserBridge.init(testing.allocator, 19334);
    defer bridge.deinit();

    try testing.expect(!bridge.isConnected());
    try testing.expectError(error.NotConnected, bridge.listTools());
}
