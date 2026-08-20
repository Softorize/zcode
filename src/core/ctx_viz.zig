//! Context-window visualiser for `/ctx-viz`.
//!
//! Renders a compact bar chart of current context-window usage:
//! history tokens, reserved output, reasoning reserve, free budget.
//! Numbers are sourced from the runtime's token status and config
//! so what the user sees matches what gets sent to the provider.
//!
//! Reference equivalent: `/ctx_viz` in claude-code-main. The
//! reference does a React/Ink render; zcode does plain ASCII so it
//! works anywhere the REPL does.

const std = @import("std");
const std_io = @import("std_io.zig");
const agent_runtime = @import("../agent_runtime.zig");

pub fn render(
    allocator: std.mem.Allocator,
    runtime: *agent_runtime.AgentRuntime,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    const window = runtime.cfg.model_context_window;
    const reserved_out = runtime.cfg.reserved_output_tokens;
    const reserved_reason = runtime.cfg.reserved_reasoning_tokens;
    const last_prompt = runtime.token_status.last_prompt_tokens;

    if (window == 0) {
        try w.writeAll("context window not configured (cfg.model_context_window = 0).\n");
        return out.toOwnedSlice();
    }

    const used_prompt = @min(last_prompt, window);
    const reserved_total = @min(reserved_out + reserved_reason, window);
    const free = if (used_prompt + reserved_total < window)
        window - used_prompt - reserved_total
    else
        0;

    try w.print("model         : {s}/{s}\n", .{ runtime.active_provider, runtime.active_model });
    try w.print("window        : {d} tokens\n", .{window});
    try w.print("last prompt   : {d} tokens ({d:.1}%)\n", .{ used_prompt, fraction_pct(used_prompt, window) });
    try w.print("reserved out  : {d} tokens\n", .{reserved_out});
    try w.print("reserved think: {d} tokens\n", .{reserved_reason});
    try w.print("free          : {d} tokens ({d:.1}%)\n", .{ free, fraction_pct(free, window) });

    try w.writeAll("\n");
    try w.writeAll("[");
    const bar_width: usize = 60;
    const prompt_blocks = cells(used_prompt, window, bar_width);
    const reserved_blocks = cells(reserved_total, window, bar_width);
    const free_blocks = if (prompt_blocks + reserved_blocks > bar_width)
        0
    else
        bar_width - prompt_blocks - reserved_blocks;

    var i: usize = 0;
    while (i < prompt_blocks) : (i += 1) try w.writeAll("#");
    i = 0;
    while (i < reserved_blocks) : (i += 1) try w.writeAll("=");
    i = 0;
    while (i < free_blocks) : (i += 1) try w.writeAll(".");
    try w.writeAll("]\n");
    try w.writeAll("# = prompt   = = reserved (output + thinking)   . = free\n");

    return out.toOwnedSlice();
}

fn cells(value: usize, total: usize, width: usize) usize {
    if (total == 0) return 0;
    return (value * width) / total;
}

fn fraction_pct(value: usize, total: usize) f64 {
    if (total == 0) return 0.0;
    return @as(f64, @floatFromInt(value)) * 100.0 / @as(f64, @floatFromInt(total));
}
