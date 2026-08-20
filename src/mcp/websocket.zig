const std = @import("std");
const std_io = @import("../core/std_io.zig");
const rng = @import("../core/rng.zig");
const Io = std.Io;

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

/// Which side of the connection we are when reading a frame. Per RFC 6455 §5.1
/// a client MUST mask every frame it sends; a server MUST NOT mask frames it
/// sends. The reader enforces this based on the declared mode.
pub const FrameMode = enum { server, client };

pub const Frame = struct {
    opcode: Opcode,
    payload: []u8,
    fin: bool,

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
    }
};

const WS_GUID = "258EAFA5-E914-47DA-95CA-5AB5DC525C76";
const MAX_FRAME_PAYLOAD: u64 = 16 * 1024 * 1024;
const MAX_CONTROL_PAYLOAD: u64 = 125;

/// Validate per-frame header state against RFC 6455. Rejects:
///   - reserved opcodes (0x3-0x7, 0xB-0xF)
///   - control frames with FIN=0 or payload > 125 bytes (§5.5)
///   - non-minimal length encodings (§5.2)
///   - 64-bit length with the MSB set
///   - masking that does not match the declared mode (§5.1)
fn validateFrameHeader(
    opcode: Opcode,
    fin: bool,
    masked: bool,
    len7: u7,
    payload_len: u64,
    mode: FrameMode,
) !void {
    switch (@intFromEnum(opcode)) {
        0x0, 0x1, 0x2, 0x8, 0x9, 0xA => {},
        else => return error.InvalidOpcode,
    }

    const is_control = @intFromEnum(opcode) >= 0x8;
    if (is_control) {
        if (!fin) return error.FragmentedControlFrame;
        if (payload_len > MAX_CONTROL_PAYLOAD) return error.OversizedControlFrame;
    }

    switch (len7) {
        126 => if (payload_len < 126) return error.NonMinimalLength,
        127 => {
            if (payload_len <= 0xFFFF) return error.NonMinimalLength;
            if ((payload_len & (@as(u64, 1) << 63)) != 0) return error.InvalidPayloadLength;
        },
        else => {},
    }

    switch (mode) {
        .server => if (!masked) return error.UnmaskedClientFrame,
        .client => if (masked) return error.MaskedServerFrame,
    }
}

/// Read one WebSocket frame from a network stream. `mode` selects whether we
/// are acting as a server (client frames, must be masked) or a client (server
/// frames, must be unmasked).
pub fn readFrame(
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    timeout_ms: i32,
    mode: FrameMode,
) !Frame {
    var header: [2]u8 = undefined;
    try readExact(stream, &header, timeout_ms);

    const fin = (header[0] & 0x80) != 0;
    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(header[0] & 0x0F)));
    const masked = (header[1] & 0x80) != 0;
    const len7: u7 = @truncate(header[1] & 0x7F);

    const payload_len: u64 = switch (len7) {
        126 => blk: {
            var ext: [2]u8 = undefined;
            try readExact(stream, &ext, timeout_ms);
            break :blk std.mem.readInt(u16, &ext, .big);
        },
        127 => blk: {
            var ext: [8]u8 = undefined;
            try readExact(stream, &ext, timeout_ms);
            break :blk std.mem.readInt(u64, &ext, .big);
        },
        else => @as(u64, len7),
    };

    try validateFrameHeader(opcode, fin, masked, len7, payload_len, mode);
    if (payload_len > MAX_FRAME_PAYLOAD) return error.FrameTooLarge;

    var mask_key: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        try readExact(stream, &mask_key, timeout_ms);
    }

    const payload = try allocator.alloc(u8, @intCast(payload_len));
    errdefer allocator.free(payload);

    if (payload.len > 0) {
        try readExact(stream, payload, timeout_ms);
    }

    if (masked) {
        for (payload, 0..) |*b, i| {
            b.* ^= mask_key[i % 4];
        }
    }

    return .{
        .opcode = opcode,
        .payload = payload,
        .fin = fin,
    };
}

/// Write an unmasked text frame (server → client).
pub fn writeTextFrame(stream: std.Io.net.Stream, payload: []const u8) !void {
    try writeFrame(stream, .text, payload);
}

/// Write an unmasked close frame.
pub fn writeCloseFrame(stream: std.Io.net.Stream) !void {
    try writeFrame(stream, .close, &.{});
}

/// Write an unmasked pong frame (echo the ping payload).
pub fn writePongFrame(stream: std.Io.net.Stream, payload: []const u8) !void {
    try writeFrame(stream, .pong, payload);
}

/// Read one WebSocket frame from any buffered reader.
pub fn readFrameReader(allocator: std.mem.Allocator, reader: *Io.Reader, mode: FrameMode) !Frame {
    var header: [2]u8 = undefined;
    try reader.readSliceAll(&header);

    const fin = (header[0] & 0x80) != 0;
    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(header[0] & 0x0F)));
    const masked = (header[1] & 0x80) != 0;
    const len7: u7 = @truncate(header[1] & 0x7F);

    const payload_len: u64 = switch (len7) {
        126 => blk: {
            var ext: [2]u8 = undefined;
            try reader.readSliceAll(&ext);
            break :blk std.mem.readInt(u16, &ext, .big);
        },
        127 => blk: {
            var ext: [8]u8 = undefined;
            try reader.readSliceAll(&ext);
            break :blk std.mem.readInt(u64, &ext, .big);
        },
        else => @as(u64, len7),
    };

    try validateFrameHeader(opcode, fin, masked, len7, payload_len, mode);
    if (payload_len > MAX_FRAME_PAYLOAD) return error.FrameTooLarge;

    var mask_key: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        try reader.readSliceAll(&mask_key);
    }

    const payload = try allocator.alloc(u8, @intCast(payload_len));
    errdefer allocator.free(payload);
    if (payload.len > 0) {
        try reader.readSliceAll(payload);
    }

    if (masked) {
        for (payload, 0..) |*b, i| {
            b.* ^= mask_key[i % 4];
        }
    }

    return .{
        .opcode = opcode,
        .payload = payload,
        .fin = fin,
    };
}

/// Write a masked text frame (client -> server).
pub fn writeClientTextFrame(writer: *Io.Writer, payload: []const u8) !void {
    try writeFrameWriter(writer, .text, payload, true);
}

/// Write a masked close frame (client -> server).
pub fn writeClientCloseFrame(writer: *Io.Writer) !void {
    try writeFrameWriter(writer, .close, &.{}, true);
}

/// Write a masked pong frame (client -> server).
pub fn writeClientPongFrame(writer: *Io.Writer, payload: []const u8) !void {
    try writeFrameWriter(writer, .pong, payload, true);
}

fn writeFrame(stream: std.Io.net.Stream, opcode: Opcode, payload: []const u8) !void {
    var header_buf: [10]u8 = undefined;
    var header_len: usize = 2;

    header_buf[0] = 0x80 | @as(u8, @intFromEnum(opcode)); // FIN + opcode
    // Server frames are NOT masked (mask bit = 0)

    if (payload.len < 126) {
        header_buf[1] = @intCast(payload.len);
    } else if (payload.len <= 65535) {
        header_buf[1] = 126;
        std.mem.writeInt(u16, header_buf[2..4], @intCast(payload.len), .big);
        header_len = 4;
    } else {
        header_buf[1] = 127;
        std.mem.writeInt(u64, header_buf[2..10], @intCast(payload.len), .big);
        header_len = 10;
    }

    try std_io.streamWriteAll(stream, header_buf[0..header_len]);
    if (payload.len > 0) {
        try std_io.streamWriteAll(stream, payload);
    }
}

fn writeFrameWriter(writer: *Io.Writer, opcode: Opcode, payload: []const u8, masked: bool) !void {
    var header_buf: [14]u8 = undefined;
    var header_len: usize = 2;

    header_buf[0] = 0x80 | @as(u8, @intFromEnum(opcode));

    if (payload.len < 126) {
        header_buf[1] = @intCast(payload.len);
    } else if (payload.len <= 65535) {
        header_buf[1] = 126;
        std.mem.writeInt(u16, header_buf[2..4], @intCast(payload.len), .big);
        header_len = 4;
    } else {
        header_buf[1] = 127;
        std.mem.writeInt(u64, header_buf[2..10], @intCast(payload.len), .big);
        header_len = 10;
    }

    var mask_key: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        header_buf[1] |= 0x80;
        rng.secureBytes(&mask_key);
        @memcpy(header_buf[header_len .. header_len + mask_key.len], &mask_key);
        header_len += mask_key.len;
    }

    try writer.writeAll(header_buf[0..header_len]);
    if (!masked or payload.len == 0) {
        if (payload.len > 0) try writer.writeAll(payload);
        return;
    }

    var chunk_buf: [1024]u8 = undefined;
    var offset: usize = 0;
    while (offset < payload.len) {
        const remaining = payload.len - offset;
        const chunk_len = @min(chunk_buf.len, remaining);
        for (chunk_buf[0..chunk_len], 0..) |*b, i| {
            b.* = payload[offset + i] ^ mask_key[(offset + i) % 4];
        }
        try writer.writeAll(chunk_buf[0..chunk_len]);
        offset += chunk_len;
    }
}

/// Compute the Sec-WebSocket-Accept value from the client's key.
/// Returns a base64-encoded SHA-1 hash.
pub fn computeAcceptKey(dest: *[28]u8, client_key: []const u8) void {
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(client_key);
    hasher.update(WS_GUID);
    var digest: [20]u8 = undefined;
    hasher.final(&digest);
    _ = std.base64.standard.Encoder.encode(dest, &digest);
}

/// Parse an HTTP upgrade request and extract the Sec-WebSocket-Key.
/// Returns a slice pointing into the input data, or null if not a valid upgrade.
pub fn parseUpgradeRequest(data: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, data, "\r\n");
    // Skip the request line (e.g., "GET / HTTP/1.1")
    _ = lines.next() orelse return null;

    while (lines.next()) |line| {
        if (line.len == 0) break;
        // Case-insensitive match for "Sec-WebSocket-Key:"
        if (matchHeaderIgnoreCase(line, "Sec-WebSocket-Key:")) |value| {
            return std.mem.trim(u8, value, " \t");
        }
    }
    return null;
}

/// Send the HTTP 101 Switching Protocols response to complete the WS handshake.
pub fn sendUpgradeResponse(stream: std.Io.net.Stream, client_key: []const u8) !void {
    var accept_key: [28]u8 = undefined;
    computeAcceptKey(&accept_key, client_key);

    try std_io.streamWriteAll(stream, "HTTP/1.1 101 Switching Protocols\r\n");
    try std_io.streamWriteAll(stream, "Upgrade: websocket\r\n");
    try std_io.streamWriteAll(stream, "Connection: Upgrade\r\n");
    try std_io.streamWriteAll(stream, "Sec-WebSocket-Accept: ");
    try std_io.streamWriteAll(stream, &accept_key);
    try std_io.streamWriteAll(stream, "\r\n\r\n");
}

// --- Internal helpers ---

fn readExact(stream: std.Io.net.Stream, buf: []u8, timeout_ms: i32) !void {
    var filled: usize = 0;
    while (filled < buf.len) {
        try waitReadable(stream, timeout_ms);
        const n = std_io.streamRead(stream, buf[filled..]) catch return error.ReadFailed;
        if (n == 0) return error.ConnectionClosed;
        filled += n;
    }
}

fn waitReadable(stream: std.Io.net.Stream, timeout_ms: i32) !void {
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = stream.socket.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const n = std.posix.poll(&poll_fds, timeout_ms) catch return error.PollFailed;
    if (n <= 0) return error.Timeout;
}

fn matchHeaderIgnoreCase(line: []const u8, prefix: []const u8) ?[]const u8 {
    if (line.len < prefix.len) return null;
    for (line[0..prefix.len], prefix) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return null;
    }
    return line[prefix.len..];
}

// --- Tests ---

const testing = std.testing;

test "computeAcceptKey known vector" {
    // Verified against Python hashlib.sha1 + base64 and system shasum
    var result: [28]u8 = undefined;
    computeAcceptKey(&result, "dGhlIHNhbXBsZSBub25jZQ==");
    try testing.expectEqualStrings("msZWndP7GZ1Uj7JuJBNzwNcPzRs=", &result);
}

test "parseUpgradeRequest extracts key" {
    const request =
        "GET / HTTP/1.1\r\n" ++
        "Host: 127.0.0.1:9333\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";
    const key = parseUpgradeRequest(request).?;
    try testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", key);
}

test "parseUpgradeRequest returns null on missing key" {
    const request = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
    try testing.expect(parseUpgradeRequest(request) == null);
}

test "matchHeaderIgnoreCase" {
    const result = matchHeaderIgnoreCase("sec-websocket-key: abc", "Sec-WebSocket-Key:").?;
    try testing.expectEqualStrings(" abc", result);
    try testing.expect(matchHeaderIgnoreCase("Content-Type: json", "Sec-WebSocket-Key:") == null);
}

test "client frame writer masks payload and reader unmasks" {
    const allocator = testing.allocator;
    var storage: [256]u8 = undefined;
    var writer = Io.Writer.fixed(&storage);
    try writeClientTextFrame(&writer, "hello");

    var reader = Io.Reader.fixed(writer.buffered());
    var frame = try readFrameReader(allocator, &reader, .server);
    defer frame.deinit(allocator);

    try testing.expect(frame.fin);
    try testing.expectEqual(.text, frame.opcode);
    try testing.expectEqualStrings("hello", frame.payload);
}

test "server mode rejects unmasked client frame" {
    const allocator = testing.allocator;
    // Unmasked FIN+text frame with 5-byte payload "hello"
    const bytes = [_]u8{ 0x81, 0x05, 'h', 'e', 'l', 'l', 'o' };
    var reader = Io.Reader.fixed(&bytes);
    try testing.expectError(error.UnmaskedClientFrame, readFrameReader(allocator, &reader, .server));
}

test "client mode rejects masked server frame" {
    const allocator = testing.allocator;
    var storage: [64]u8 = undefined;
    var writer = Io.Writer.fixed(&storage);
    // writeClientTextFrame writes a masked frame (client-to-server direction)
    try writeClientTextFrame(&writer, "hello");

    var reader = Io.Reader.fixed(writer.buffered());
    try testing.expectError(error.MaskedServerFrame, readFrameReader(allocator, &reader, .client));
}

test "non-minimal length encoding is rejected" {
    const allocator = testing.allocator;
    // len7=126 with actual value 5 (must be >=126) + unmasked
    const bytes = [_]u8{ 0x81, 126, 0x00, 0x05, 'h', 'e', 'l', 'l', 'o' };
    var reader = Io.Reader.fixed(&bytes);
    try testing.expectError(error.NonMinimalLength, readFrameReader(allocator, &reader, .client));
}

test "reserved opcode is rejected" {
    const allocator = testing.allocator;
    const bytes = [_]u8{ 0x83, 0x00 }; // FIN + reserved opcode 3
    var reader = Io.Reader.fixed(&bytes);
    try testing.expectError(error.InvalidOpcode, readFrameReader(allocator, &reader, .client));
}

test "fragmented control frame is rejected" {
    const allocator = testing.allocator;
    const bytes = [_]u8{ 0x09, 0x00 }; // FIN=0 + ping, payload 0
    var reader = Io.Reader.fixed(&bytes);
    try testing.expectError(error.FragmentedControlFrame, readFrameReader(allocator, &reader, .client));
}

test "oversized control frame is rejected" {
    const allocator = testing.allocator;
    // FIN + ping, len7=126 (extended 16-bit), actual 126
    const bytes = [_]u8{ 0x89, 126, 0x00, 0x7E };
    var reader = Io.Reader.fixed(&bytes);
    try testing.expectError(error.OversizedControlFrame, readFrameReader(allocator, &reader, .client));
}
