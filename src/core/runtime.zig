//! Process-wide singletons for std.Io + general-purpose allocator,
//! initialised once from main() via `std.process.Init`.
//!
//! This is a deliberate technical-debt vehicle introduced by the Zig
//! 0.16 migration. The old code (0.15) never had to pass `io` anywhere
//! because every fs / process / sync call was self-contained. In 0.16
//! every such call requires an `io: std.Io` parameter. Threading it
//! through ~200 files in one PR would balloon the migration diff to
//! the point of being unreviewable, so instead we expose `runtime.io`
//! and `runtime.gpa` as package-globals that core shims (clock, rng,
//! std_io) pull from.
//!
//! Stage 4 of the migration plan retires this file: every caller will
//! take `io` explicitly, the singleton will be deleted, and the
//! compiler will be the worklist.

const std = @import("std");
const builtin = @import("builtin");

/// Set once in main() from init.io. All shims read this.
pub var io: std.Io = undefined;

/// Test-only IO backend. zig-test binaries skip main(); call this
/// from a test that needs file/process IO before touching rt.io.
var test_threaded: std.Io.Threaded = undefined;
var test_initialized: bool = false;
pub fn installForTest() void {
    if (!test_initialized) {
        test_threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        io = test_threaded.io();
        gpa = std.heap.smp_allocator;
        test_initialized = true;
    }
}

/// Set once in main() from init.gpa. Available for code paths that
/// today reach for a thread-local allocator.
pub var gpa: std.mem.Allocator = undefined;

/// Process argv captured at startup. Cached so diagnostic code paths
/// (heap_diag, error reporters) don't need to thread `init` everywhere.
pub var argv: []const []const u8 = &.{};

pub fn install(init: std.process.Init) void {
    io = init.io;
    gpa = init.gpa;
}

pub fn setArgv(argv_slice: []const []const u8) void {
    argv = argv_slice;
}
