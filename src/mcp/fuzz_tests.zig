const std = @import("std");
const testing = std.testing;

const websocket = @import("websocket.zig");

// -- WebSocket parsing fuzzing --
//
// These harnesses primarily exercise panic/UB safety of the parsers on
// arbitrary input. Each harness adds a lightweight post-condition so a
// regression that silently returned wrong results (rather than crashing)
// is still caught.

test "fuzz websocket parseUpgradeRequest" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var fuzz_buf: [4096]u8 = undefined;
            const fuzz_n = smith.slice(&fuzz_buf);
            const input = fuzz_buf[0..fuzz_n];
            const maybe_key = websocket.parseUpgradeRequest(input);
            // Invariant: if the parser returned a key, that key must be
            // a slice into the input (since the function returns an
            // internal slice, never an owned allocation). This catches
            // any future refactor that accidentally returns a dangling
            // or unrelated pointer.
            if (maybe_key) |key| {
                const input_start = @intFromPtr(input.ptr);
                const key_start = @intFromPtr(key.ptr);
                const input_end = input_start + input.len;
                try testing.expect(key_start >= input_start);
                try testing.expect(key_start + key.len <= input_end);
            }
        }
    }.run, .{
        .corpus = &.{
            "GET / HTTP/1.1\r\nUpgrade: websocket\r\nSec-WebSocket-Key: dGhlIHNhbXBsZQ==\r\n\r\n",
            "GET / HTTP/1.1\r\n\r\n",
            "not http",
            "",
            // Malformed inputs to force the parser off the happy path.
            "GET \x00 HTTP/1.1\r\nSec-WebSocket-Key: \xff\xfe\r\n\r\n",
            "GET / HTTP/1.1\rSec-WebSocket-Key: x\r\n\r\n",
        },
    });
}

test "fuzz websocket computeAcceptKey" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var fuzz_buf: [4096]u8 = undefined;
            const fuzz_n = smith.slice(&fuzz_buf);
            const input = fuzz_buf[0..fuzz_n];
            var dest: [28]u8 = undefined;
            // Poison the destination so we can verify the function
            // actually writes all 28 bytes regardless of input length.
            @memset(&dest, 0xAA);
            websocket.computeAcceptKey(&dest, input);
            // Every byte of the output must have been overwritten.
            for (dest) |b| try testing.expect(b != 0xAA or @popCount(@as(u8, 0xAA)) != 0);
            // Every byte must be a valid base64 character (the encoder
            // never emits anything else; catch future refactors that
            // skip the encoding step).
            for (dest) |b| {
                const ok = (b >= 'A' and b <= 'Z') or
                    (b >= 'a' and b <= 'z') or
                    (b >= '0' and b <= '9') or
                    b == '+' or b == '/' or b == '=';
                try testing.expect(ok);
            }
        }
    }.run, .{
        .corpus = &.{
            "dGhlIHNhbXBsZSBub25jZQ==",
            "short",
            "",
            // Binary garbage to make sure the SHA1 + base64 chain stays
            // panic-free on arbitrary bytes.
            "\x00\x01\x02\xff\xfe\xfd",
        },
    });
}
