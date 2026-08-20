const std = @import("std");
const clock = @import("../core/clock.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const mcp_client = @import("../mcp/client.zig");

/// Maximum number of concurrent threads for parallel tool execution.
const MAX_CONCURRENT_THREADS: usize = 6;

/// Context passed to each tool execution thread.
const ThreadContext = struct {
    name: []const u8,
    args: []const u8,
    cwd: []const u8,
    sandbox_profile: []const u8,
    mcp: ?*mcp_client.Client,
    arena: std.heap.ArenaAllocator,
    // Results (written by thread, read after join)
    output: ?[]u8 = null,
    err_msg: ?[]u8 = null,
    duration_ms: i64 = 0,
};

/// Result of a concurrent tool batch execution.
pub const BatchResult = struct {
    outputs: []ToolOutput,

    pub const ToolOutput = struct {
        name: []const u8,
        args: []const u8,
        output: []u8,
        duration_ms: i64,
        success: bool,
    };

    pub fn deinit(self: *BatchResult, allocator: std.mem.Allocator) void {
        for (self.outputs) |o| {
            allocator.free(o.output);
        }
        allocator.free(self.outputs);
    }
};

/// Execute multiple read-only tool calls in parallel using a rolling
/// thread pool. Each task gets its own ArenaAllocator to avoid contention,
/// and the pool keeps up to MAX_CONCURRENT_THREADS tasks in flight at any
/// time. A slow task does NOT block the next wave: as soon as any pool
/// worker becomes free it picks up the next queued job.
pub fn executeParallel(
    allocator: std.mem.Allocator,
    calls: []const ToolCall,
    cwd: []const u8,
    sandbox_profile: []const u8,
    mcp: ?*mcp_client.Client,
) !BatchResult {
    if (calls.len == 0) {
        return .{ .outputs = try allocator.alloc(BatchResult.ToolOutput, 0) };
    }

    // Cap parallelism at both the call count and the configured maximum.
    const thread_count = @min(calls.len, MAX_CONCURRENT_THREADS);

    // Per-call contexts with their own arena allocators.
    var contexts = try allocator.alloc(ThreadContext, calls.len);
    defer allocator.free(contexts);

    for (calls, 0..) |call, i| {
        contexts[i] = .{
            .name = call.name,
            .args = call.args,
            .cwd = cwd,
            .sandbox_profile = sandbox_profile,
            .mcp = mcp,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }
    defer for (contexts) |*ctx| ctx.arena.deinit();

    // Stage 5g (Zig 0.16): drive each call on its own std.Thread, capped at
    // MAX_CONCURRENT_THREADS by waiting in chunks. We dropped std.Thread.Pool
    // because Zig 0.16 retired Pool/WaitGroup; spawning per call avoids
    // re-introducing pool state and keeps cleanup linear.
    var threads = try allocator.alloc(?std.Thread, calls.len);
    defer allocator.free(threads);
    @memset(threads, null);

    var batch_start: usize = 0;
    while (batch_start < contexts.len) {
        const batch_end = @min(batch_start + thread_count, contexts.len);
        var k: usize = batch_start;
        while (k < batch_end) : (k += 1) {
            threads[k] = std.Thread.spawn(.{}, executeToolThread, .{&contexts[k]}) catch null;
            if (threads[k] == null) executeToolThread(&contexts[k]);
        }
        var j: usize = batch_start;
        while (j < batch_end) : (j += 1) {
            if (threads[j]) |t| t.join();
        }
        batch_start = batch_end;
    }

    // Collect results after all workers have finished.
    var outputs = try allocator.alloc(BatchResult.ToolOutput, calls.len);
    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) allocator.free(outputs[i].output);
        allocator.free(outputs);
    }
    for (contexts, 0..) |ctx, i| {
        const output_text = if (ctx.output) |o|
            try allocator.dupe(u8, o)
        else if (ctx.err_msg) |e|
            try allocator.dupe(u8, e)
        else
            try allocator.dupe(u8, "tool returned no output");

        outputs[i] = .{
            .name = calls[i].name,
            .args = calls[i].args,
            .output = output_text,
            .duration_ms = ctx.duration_ms,
            .success = ctx.output != null,
        };
        filled = i + 1;
    }

    return .{ .outputs = outputs };
}

fn executeToolThread(ctx: *ThreadContext) void {
    // Use millisecond-resolution timing. The previous version used
    // clock.nowSeconds() which returns whole seconds, so every sub-second
    // tool reported duration_ms == 0 and anything crossing a second boundary
    // jumped to 1000, making the "concurrent execution is faster" telemetry
    // meaningless.
    const start = clock.nowMillis();
    const thread_allocator = ctx.arena.allocator();

    const req = tool_dispatch.ToolExecutionRequest{
        .name = ctx.name,
        .args = ctx.args,
        .cwd = ctx.cwd,
        .sandbox_profile = ctx.sandbox_profile,
    };

    const result = tool_dispatch.dispatch(thread_allocator, ctx.mcp, req) catch |err| {
        ctx.err_msg = std.fmt.allocPrint(thread_allocator, "tool error: {s}", .{@errorName(err)}) catch null;
        ctx.duration_ms = @intCast(@max(@as(i64, 0), clock.nowMillis() - start));
        return;
    };

    ctx.output = result;
    ctx.duration_ms = @intCast(@max(@as(i64, 0), clock.nowMillis() - start));
}

pub const ToolCall = struct {
    name: []const u8,
    args: []const u8,
};

// --- Tests ---

const testing = std.testing;

test "executeParallel handles empty call list" {
    var result = try executeParallel(testing.allocator, &.{}, ".", "danger-full-access", null);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), result.outputs.len);
}
