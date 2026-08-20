const std = @import("std");
const testing = std.testing;

const arg_parse = @import("arg_parse.zig");

// -- Argument parsing fuzzing --

test "fuzz arg_parse getArg" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var fuzz_buf: [4096]u8 = undefined;
            const fuzz_n = smith.slice(&fuzz_buf);
            const input = fuzz_buf[0..fuzz_n];
            _ = arg_parse.getArg(input, "path");
            _ = arg_parse.getArg(input, "command");
            _ = arg_parse.getArg(input, "content");
        }
    }.run, .{ .corpus = &.{
        "path=/tmp/file.txt;content=hello",
        "command=echo hi",
        "path=\"quoted value\";key=val",
        "nested=[{\"a\":1}];x=y",
        "",
    } });
}

test "fuzz arg_parse parseBool" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var fuzz_buf: [4096]u8 = undefined;
            const fuzz_n = smith.slice(&fuzz_buf);
            const input = fuzz_buf[0..fuzz_n];
            _ = arg_parse.parseBool(input);
        }
    }.run, .{ .corpus = &.{ "true", "false", "1", "0", "yes", "no", "" } });
}
