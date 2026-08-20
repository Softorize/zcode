const std = @import("std");
const clock = @import("clock.zig");
const config_mod = @import("config.zig");
const types = @import("types.zig");
const prompt_engine = @import("prompt_engine.zig");
const policy_mod = @import("../policy/policy.zig");
const compaction = @import("compaction.zig");

pub const BenchmarkResult = struct {
    prompt_build_avg_us: u64,
    prompt_build_p95_us: u64,
    compaction_avg_us: u64,
    risk_classify_avg_ns: u64,
};

pub fn run(allocator: std.mem.Allocator, cwd: []const u8, cfg: *const config_mod.Config, policy: *const policy_mod.Policy) !BenchmarkResult {
    const history = [_]types.HistoryTurn{
        .{ .role = .user, .content = "Refactor src/main.zig and keep tests passing", .timestamp = 0 },
        .{ .role = .assistant, .content = "Acknowledged", .timestamp = 0 },
    };

    const tool_schemas = [_]types.ToolSchema{};
    const snapshot = types.SessionSnapshot{
        .facts = &.{},
        .decisions = &.{},
        .open_tasks = &.{},
        .file_focus = &.{},
        .recent_tool_outcomes = &.{},
        .handoff_summary = "",
    };

    var prompt_timings = try allocator.alloc(u64, 50);
    defer allocator.free(prompt_timings);

    var i: usize = 0;
    while (i < prompt_timings.len) : (i += 1) {
        // Use a monotonic Timer rather than clock.nowNanos()
        // (wall clock) so an NTP step between start and end cannot
        // produce a negative i128 that would panic in `@intCast`.
        var timer = clock.Timer.start() catch {
            prompt_timings[i] = 0;
            continue;
        };
        var built = try prompt_engine.build(
            allocator,
            cfg,
            policy,
            "Benchmark prompt",
            history[0..],
            tool_schemas[0..],
            cwd,
            &snapshot,
            null,
            cfg.output_style,
            "",
            "",
            null,
            0,
            null,
            "",
            .execution,
        );
        built.envelope.deinit();
        const elapsed_ns = timer.read();
        prompt_timings[i] = elapsed_ns / 1_000;
    }

    std.mem.sort(u64, prompt_timings, {}, lessThanU64);
    const p95_idx = (prompt_timings.len * 95) / 100;
    const prompt_p95 = prompt_timings[@min(p95_idx, prompt_timings.len - 1)];

    var prompt_total: u128 = 0;
    for (prompt_timings) |v| prompt_total += v;
    const prompt_avg: u64 = @intCast(@divTrunc(prompt_total, prompt_timings.len));

    const budget = types.BudgetPlan.init(cfg.model_context_window, cfg.reserved_output_tokens, cfg.reserved_reasoning_tokens);
    var comp_total_ns: u64 = 0;
    i = 0;
    while (i < 100) : (i += 1) {
        var timer = clock.Timer.start() catch continue;
        var c = try compaction.maybeCompact(allocator, history[0..], budget, null, "");
        c.deinit(allocator);
        comp_total_ns += timer.read();
    }
    const comp_avg_us: u64 = comp_total_ns / (100 * 1_000);

    var risk_total_ns: u64 = 0;
    i = 0;
    while (i < 10_000) : (i += 1) {
        var timer = clock.Timer.start() catch continue;
        _ = policy.classifyTool("shell", "command=ls");
        risk_total_ns += timer.read();
    }

    return .{
        .prompt_build_avg_us = prompt_avg,
        .prompt_build_p95_us = prompt_p95,
        .compaction_avg_us = comp_avg_us,
        .risk_classify_avg_ns = risk_total_ns / 10_000,
    };
}

fn lessThanU64(_: void, a: u64, b: u64) bool {
    return a < b;
}

const testing = std.testing;

test "benchmark runs" {
    const allocator = testing.allocator;
    var cfg = try config_mod.Config.init(allocator);
    defer cfg.deinit(allocator);

    var policy = try policy_mod.Policy.init(allocator);
    defer policy.deinit();

    const res = try run(allocator, ".", &cfg, &policy);
    try testing.expect(res.prompt_build_avg_us > 0);
}
