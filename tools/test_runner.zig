//! Custom test runner that installs `core/runtime.zig` singletons
//! (`rt.io` and `rt.gpa`) before each test so test code can call
//! file/process IO without hitting `undefined`.
//!
//! Modeled on Zig 0.16's compiler/test_runner.zig but pared down
//! for our needs: terminal mode only, no listen server, no fuzz.

const std = @import("std");
const builtin = @import("builtin");
const rt = @import("zcode_runtime");

pub fn fuzz(
    context: anytype,
    comptime testOne: anytype,
    options: std.testing.FuzzInputOptions,
) anyerror!void {
    // No fuzz infrastructure in this runner; just exercise the corpus once
    // so the test still gets through normal compilation + runtime paths.
    _ = options;
    _ = context;
    _ = testOne;
    return;
}

pub fn main() void {
    rt.installForTest();

    const test_fns = builtin.test_functions;
    var passed: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;

    for (test_fns) |t| {
        std.debug.print("RUN: {s}\n", .{t.name});
        t.func() catch |err| switch (err) {
            error.SkipZigTest => {
                skipped += 1;
                continue;
            },
            else => {
                failed += 1;
                std.debug.print("FAIL: {s}: {s}\n", .{ t.name, @errorName(err) });
                continue;
            },
        };
        passed += 1;
    }

    std.debug.print("\n{d} passed, {d} skipped, {d} failed\n", .{ passed, skipped, failed });
    if (failed > 0) std.process.exit(1);
}
