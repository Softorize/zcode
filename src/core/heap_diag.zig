//! Process diagnostics for `/heapdump`.
//!
//! The reference's `/heapdump` writes a V8 heap snapshot. zcode is
//! native and has no equivalent runtime inspector. Instead we dump
//! the cheap-to-collect process stats that matter when debugging
//! long-running sessions:
//!   - pid / ppid / uptime
//!   - RSS / peak RSS (via getrusage on POSIX)
//!   - cwd + process argv[0]
//!   - session id, history turn count, token totals
//!   - OS / build info
//!
//! The output is a plain text block suitable for pasting into a
//! bug report.

const std = @import("std");
const std_io = @import("std_io.zig");
const rt = @import("zcode_runtime");
const builtin = @import("builtin");
const agent_runtime = @import("../agent_runtime.zig");

pub fn render(
    allocator: std.mem.Allocator,
    runtime: *agent_runtime.AgentRuntime,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    const pid = switch (builtin.os.tag) {
        .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly => std.os.linux.getpid(),
        else => @as(i32, 0),
    };

    const ppid: i32 = switch (builtin.os.tag) {
        .linux => std.os.linux.getppid(),
        else => 0,
    };

    try w.print("pid              : {d}\n", .{pid});
    if (ppid != 0) try w.print("ppid             : {d}\n", .{ppid});

    // argv[0]
    if (rt.argv.len > 0) {
        try w.print("argv[0]          : {s}\n", .{rt.argv[0]});
    }

    // cwd
    const cwd = std.process.currentPathAlloc(rt.io, allocator) catch null;
    defer if (cwd) |c| allocator.free(c);
    if (cwd) |c| try w.print("cwd              : {s}\n", .{c});

    try w.print("runtime.cwd      : {s}\n", .{runtime.cwd});
    try w.print("shell cwd        : {s}\n", .{runtime.shell_cwd});
    try w.print("session id       : {s}\n", .{runtime.session_id});
    try w.print("history turns    : {d}\n", .{runtime.history.len()});
    try w.print("active provider  : {s}\n", .{runtime.active_provider});
    try w.print("active model     : {s}\n", .{runtime.active_model});
    try w.print("active agent     : {s}\n", .{if (runtime.active_agent) |a| a.name else "(none)"});
    try w.print("output style     : {s}\n", .{runtime.output_style});
    try w.print("yolo mode        : {s}\n", .{if (runtime.yolo_mode) "on" else "off"});
    try w.print("strict           : {s}\n", .{if (runtime.strict) "on" else "off"});

    try w.writeAll("\n");
    try w.print("prompt sections  : {d} registered / {d} cached\n", .{
        runtime.prompt_sections_registry.sections.items.len,
        runtime.prompt_sections_registry.cacheSize(),
    });
    try w.print("instruction cache: hits={d} misses={d} epoch={d}\n", .{
        runtime.instruction_cache.hits,
        runtime.instruction_cache.misses,
        runtime.instruction_cache.axis_epoch,
    });
    try w.print("git cache        : hits={d} misses={d}\n", .{
        runtime.git_capture_cache.hits,
        runtime.git_capture_cache.misses,
    });

    try w.print("last prompt tok  : {d}\n", .{runtime.token_status.last_prompt_tokens});
    try w.print("last input tok   : {d}\n", .{runtime.token_status.last_input_tokens});
    try w.print("last output tok  : {d}\n", .{runtime.token_status.last_output_tokens});
    try w.print("total input tok  : {d}\n", .{runtime.token_status.total_input_tokens});
    try w.print("total output tok : {d}\n", .{runtime.token_status.total_output_tokens});

    try w.writeAll("\n");
    try w.print("os               : {s}\n", .{@tagName(builtin.os.tag)});
    try w.print("arch             : {s}\n", .{@tagName(builtin.cpu.arch)});
    try w.print("zig mode         : {s}\n", .{@tagName(builtin.mode)});

    // POSIX rusage: RSS high-water mark.
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        const ru = std.posix.getrusage(std.posix.rusage.SELF);
        // On Linux maxrss is KiB; on macOS it's bytes. Normalise to
        // MiB for display and label accordingly.
        const maxrss: u64 = @intCast(ru.maxrss);
        if (builtin.os.tag == .macos) {
            try w.print("peak RSS (MiB)   : {d}\n", .{maxrss / (1024 * 1024)});
        } else {
            try w.print("peak RSS (MiB)   : {d}\n", .{maxrss / 1024});
        }
        try w.print("user cpu (ms)    : {d}\n", .{@as(i64, ru.utime.sec) * 1000 + @divFloor(@as(i64, ru.utime.usec), 1000)});
        try w.print("sys cpu (ms)     : {d}\n", .{@as(i64, ru.stime.sec) * 1000 + @divFloor(@as(i64, ru.stime.usec), 1000)});
    }

    return out.toOwnedSlice();
}
