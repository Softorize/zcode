const std = @import("std");
const std_io = @import("std_io.zig");
const rt = @import("zcode_runtime");
const clock = @import("clock.zig");
const format = @import("format.zig");
const metrics = @import("metrics.zig");
const model_usage = @import("model_usage.zig");

/// Anthropic's published cache pricing multipliers relative to the input rate:
/// cache-read tokens are billed at 10% of input, cache-creation (write) tokens
/// at 125% of input. These multipliers are Anthropic-specific; other providers
/// either do not publish cache pricing or price differently, so for them we
/// default both cache rates to the plain input rate (graceful degradation --
/// no false discount, no false premium). See entryWithCache() below, which is
/// the single place these multipliers are applied so the table stays terse.
const ANTHROPIC_CACHE_READ_MULTIPLIER: f64 = 0.1;
const ANTHROPIC_CACHE_WRITE_MULTIPLIER: f64 = 1.25;

/// Per-million-token pricing: { input_cost, output_cost } in dollars.
/// cache_read_per_m / cache_write_per_m are filled in by entryWithCache() from
/// the input rate (Anthropic gets the discount/premium; everyone else mirrors
/// the input rate), so the literal table below only carries input/output.
const PriceEntry = struct {
    prefix: []const u8,
    provider: []const u8,
    input_per_m: f64,
    output_per_m: f64,
    cache_read_per_m: f64 = 0.0,
    cache_write_per_m: f64 = 0.0,
};

const price_table = [_]PriceEntry{
    // OpenAI
    .{ .prefix = "gpt-4.1-mini", .provider = "openai", .input_per_m = 0.40, .output_per_m = 1.60 },
    .{ .prefix = "gpt-4.1-nano", .provider = "openai", .input_per_m = 0.10, .output_per_m = 0.40 },
    .{ .prefix = "gpt-4.1", .provider = "openai", .input_per_m = 2.00, .output_per_m = 8.00 },
    .{ .prefix = "gpt-4o-mini", .provider = "openai", .input_per_m = 0.15, .output_per_m = 0.60 },
    .{ .prefix = "gpt-4o", .provider = "openai", .input_per_m = 2.50, .output_per_m = 10.00 },
    .{ .prefix = "o3-mini", .provider = "openai", .input_per_m = 1.10, .output_per_m = 4.40 },
    .{ .prefix = "o3", .provider = "openai", .input_per_m = 10.00, .output_per_m = 40.00 },
    .{ .prefix = "o4-mini", .provider = "openai", .input_per_m = 1.10, .output_per_m = 4.40 },

    // Anthropic
    .{ .prefix = "claude-opus-4", .provider = "anthropic", .input_per_m = 15.00, .output_per_m = 75.00 },
    .{ .prefix = "claude-sonnet-4", .provider = "anthropic", .input_per_m = 3.00, .output_per_m = 15.00 },
    .{ .prefix = "claude-3.5-sonnet", .provider = "anthropic", .input_per_m = 3.00, .output_per_m = 15.00 },
    .{ .prefix = "claude-3-haiku", .provider = "anthropic", .input_per_m = 0.25, .output_per_m = 1.25 },
    .{ .prefix = "claude-haiku-4", .provider = "anthropic", .input_per_m = 0.80, .output_per_m = 4.00 },

    // Gemini
    .{ .prefix = "gemini-2.5-pro", .provider = "gemini", .input_per_m = 1.25, .output_per_m = 10.00 },
    .{ .prefix = "gemini-2.5-flash", .provider = "gemini", .input_per_m = 0.15, .output_per_m = 0.60 },
    .{ .prefix = "gemini-2.0-flash", .provider = "gemini", .input_per_m = 0.10, .output_per_m = 0.40 },

    // DeepSeek
    .{ .prefix = "deepseek-chat", .provider = "deepseek", .input_per_m = 0.27, .output_per_m = 1.10 },
    .{ .prefix = "deepseek-reasoner", .provider = "deepseek", .input_per_m = 0.55, .output_per_m = 2.19 },

    // Groq
    .{ .prefix = "llama-3.3-70b", .provider = "groq", .input_per_m = 0.59, .output_per_m = 0.79 },
    .{ .prefix = "llama-3.1-8b", .provider = "groq", .input_per_m = 0.05, .output_per_m = 0.08 },
    .{ .prefix = "gemma2-9b", .provider = "groq", .input_per_m = 0.20, .output_per_m = 0.20 },
    .{ .prefix = "mixtral-8x7b", .provider = "groq", .input_per_m = 0.24, .output_per_m = 0.24 },
};

/// Return a copy of `entry` with cache_read_per_m / cache_write_per_m filled in.
/// The cache discount/premium is gated to the Anthropic provider so
/// OpenAI-compatible and other models are not mis-priced; non-Anthropic entries
/// mirror the input rate.
fn entryWithCache(entry: PriceEntry) PriceEntry {
    var e = entry;
    if (std.mem.eql(u8, entry.provider, "anthropic")) {
        e.cache_read_per_m = entry.input_per_m * ANTHROPIC_CACHE_READ_MULTIPLIER;
        e.cache_write_per_m = entry.input_per_m * ANTHROPIC_CACHE_WRITE_MULTIPLIER;
    } else {
        e.cache_read_per_m = entry.input_per_m;
        e.cache_write_per_m = entry.input_per_m;
    }
    return e;
}

/// Estimate the cost in dollars for a given provider, model, and token counts.
/// Thin wrapper over estimateCostWithCache with zero cache tokens, so existing
/// call sites keep their signature unchanged.
pub fn estimateCost(provider: []const u8, model: []const u8, input_tokens: usize, output_tokens: usize) f64 {
    return estimateCostWithCache(provider, model, input_tokens, output_tokens, 0, 0);
}

/// Estimate the cost in dollars including cache-read and cache-creation tokens.
/// cache_read tokens are billed at cache_read_per_m (10% of input for Anthropic),
/// cache_write (cache-creation) tokens at cache_write_per_m (125% of input for
/// Anthropic); other providers price both at the plain input rate.
pub fn estimateCostWithCache(
    provider: []const u8,
    model: []const u8,
    input_tokens: usize,
    output_tokens: usize,
    cache_read_tokens: usize,
    cache_write_tokens: usize,
) f64 {
    const base = findPriceEntry(provider, model) orelse return 0.0;
    const entry = entryWithCache(base);
    const input_cost = @as(f64, @floatFromInt(input_tokens)) * entry.input_per_m / 1_000_000.0;
    const output_cost = @as(f64, @floatFromInt(output_tokens)) * entry.output_per_m / 1_000_000.0;
    const cache_read_cost = @as(f64, @floatFromInt(cache_read_tokens)) * entry.cache_read_per_m / 1_000_000.0;
    const cache_write_cost = @as(f64, @floatFromInt(cache_write_tokens)) * entry.cache_write_per_m / 1_000_000.0;
    return input_cost + output_cost + cache_read_cost + cache_write_cost;
}

/// Whether the given provider+model has a known price entry. Used by
/// renderCostReport to flag that a /cost estimate may be inaccurate when a
/// model that produced tokens has no pricing data (cost-limits-04).
pub fn isKnownModel(provider: []const u8, model: []const u8) bool {
    return findPriceEntry(provider, model) != null;
}

fn findPriceEntry(provider: []const u8, model: []const u8) ?PriceEntry {
    // First try exact provider + prefix match
    for (price_table) |entry| {
        if (std.mem.eql(u8, entry.provider, provider) and std.mem.startsWith(u8, model, entry.prefix)) {
            return entry;
        }
    }
    // Fallback: match by prefix only for generic providers (openai-compatible, openrouter)
    for (price_table) |entry| {
        if (std.mem.startsWith(u8, model, entry.prefix) and
            (std.mem.eql(u8, provider, "openai-compatible") or
                std.mem.eql(u8, provider, "openrouter") or
                std.mem.eql(u8, provider, "ollama")))
        {
            return entry;
        }
    }
    return null;
}

/// Format cost as a string like "$0.0042" into the provided buffer.
pub fn formatCost(buf: []u8, dollars: f64) []const u8 {
    if (dollars < 0.01) {
        return std.fmt.bufPrint(buf, "${d:.4}", .{dollars}) catch "$?.??";
    }
    return std.fmt.bufPrint(buf, "${d:.2}", .{dollars}) catch "$?.??";
}

/// Render a full cost report string for the /cost command.
/// `per_model` is the optional per-model usage breakdown (cost-limits-01); when
/// non-null and non-empty a "Usage by model:" block is appended.
pub fn renderCostReport(
    allocator: std.mem.Allocator,
    provider: []const u8,
    model: []const u8,
    last_input: usize,
    last_output: usize,
    total_input: usize,
    total_output: usize,
    per_model: ?*const model_usage.ModelUsageMap,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    const last_cost = estimateCost(provider, model, last_input, last_output);
    const session_cost = estimateCost(provider, model, total_input, total_output);

    var buf1: [32]u8 = undefined;
    var buf2: [32]u8 = undefined;

    var tok_buf1: [32]u8 = undefined;
    var tok_buf2: [32]u8 = undefined;
    var tok_buf3: [32]u8 = undefined;
    var tok_buf4: [32]u8 = undefined;

    try w.print("provider={s}\n", .{provider});
    try w.print("model={s}\n", .{model});
    try w.print("last_turn_input_tokens={s} ({d})\n", .{
        format.formatTokens(&tok_buf1, last_input),
        last_input,
    });
    try w.print("last_turn_output_tokens={s} ({d})\n", .{
        format.formatTokens(&tok_buf2, last_output),
        last_output,
    });
    try w.print("last_turn_cost={s}\n", .{formatCost(&buf1, last_cost)});
    try w.print("session_input_tokens={s} ({d})\n", .{
        format.formatTokens(&tok_buf3, total_input),
        total_input,
    });
    try w.print("session_output_tokens={s} ({d})\n", .{
        format.formatTokens(&tok_buf4, total_output),
        total_output,
    });
    try w.print("session_cost={s}\n", .{formatCost(&buf2, session_cost)});

    // Surface running lines-added/-removed totals so /cost matches
    // Claude Code's "Total code changes: X lines added, Y lines removed"
    // line. Counter is process-scoped via metrics.globalMetrics.
    const lines_added = metrics.globalMetrics().getCounter(metrics.Names.lines_added_total);
    const lines_removed = metrics.globalMetrics().getCounter(metrics.Names.lines_removed_total);
    if (lines_added > 0 or lines_removed > 0) {
        try w.print("lines_added={d}\nlines_removed={d}\n", .{ lines_added, lines_removed });
    }

    // Duration lines: "Total duration (API)" + "Total duration (wall)"
    // from bootstrap/state.ts. API duration is the running counter
    // populated in providers/common.zig; wall duration is elapsed
    // since metrics.initSessionStart captured the start ns.
    const api_ms = metrics.globalMetrics().getCounter(metrics.Names.api_duration_ms_total);
    const wall_ms = metrics.getSessionWallDurationMs();
    var dur_buf1: [32]u8 = undefined;
    var dur_buf2: [32]u8 = undefined;
    try w.print("api_duration={s}\n", .{format.formatDuration(&dur_buf1, api_ms)});
    try w.print("wall_duration={s}\n", .{format.formatDuration(&dur_buf2, wall_ms)});

    // Per-model usage breakdown (cost-limits-01). renderInto is a no-op when
    // the map is empty, so a fresh session does not get a dangling header.
    if (per_model) |pm| {
        try pm.renderInto(w);
    }

    // Unknown-model cost warning (cost-limits-04). Only warn when tokens were
    // actually produced -- a fresh session with zero usage should not be
    // flagged as inaccurate. estimateCost silently returns $0 for unknown
    // models, so without this note the report would understate cost.
    if ((total_input + total_output) > 0 and !isKnownModel(provider, model)) {
        try w.print("cost_inaccurate=true\n", .{});
        try w.print("cost_inaccurate_note=costs may be inaccurate due to usage of unknown models\n", .{});
    }

    return out.toOwnedSlice();
}

/// Append one session cost record to ~/.zcode/cost_log.jsonl.
/// Each line is a self-contained JSON object for easy post-processing with jq.
/// Errors are swallowed -- cost logging is best-effort and must never crash the CLI.
pub fn appendSessionCostLog(
    allocator: std.mem.Allocator,
    provider: []const u8,
    model: []const u8,
    input_tokens: usize,
    output_tokens: usize,
) void {
    appendSessionCostLogInner(allocator, provider, model, input_tokens, output_tokens) catch {};
}

fn appendSessionCostLogInner(
    allocator: std.mem.Allocator,
    provider: []const u8,
    model: []const u8,
    input_tokens: usize,
    output_tokens: usize,
) !void {
    const home = try @import("env.zig").getOwned(allocator, "HOME");
    defer allocator.free(home);

    const dir_path = try std.fs.path.join(allocator, &.{ home, ".zcode" });
    defer allocator.free(dir_path);
    std.Io.Dir.cwd().createDirPath(rt.io, dir_path) catch {};

    const log_path = try std.fs.path.join(allocator, &.{ dir_path, "cost_log.jsonl" });
    defer allocator.free(log_path);

    const flags: std.posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
    const fd = try std_io.openFlagsAlloc(rt.gpa, log_path, flags, 0o600);
    const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(rt.io);

    const cost = estimateCost(provider, model, input_tokens, output_tokens);
    var line_buf: [1024]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buf, "{{\"ts\":{d},\"provider\":\"{s}\",\"model\":\"{s}\",\"input_tokens\":{d},\"output_tokens\":{d},\"cost_usd\":{d:.6}}}\n", .{ clock.nowSeconds(), provider, model, input_tokens, output_tokens, cost });
    try file.writeStreamingAll(rt.io, line);
}

// ---------------------------------------------------------------------------
// Cross-session cost restore (cost-limits-03).
//
// Mirrors the reference cost-tracker.ts saveCurrentSessionCosts /
// restoreCostStateForSession (lines 87-175): the accumulated per-session token
// totals are persisted keyed on the session id so that a later /resume of the
// same session restores the running totals into the live counters. We store a
// small per-session sidecar at <home>/.zcode/session_cost/<session_id>.json
// (alongside the append-only cost_log.jsonl). Keying strictly on session id is
// what keeps two unrelated sessions from cross-contaminating each other's
// totals (the reference's lastSessionId guard).
//
// Both save and load are best-effort: cost accounting must never crash the CLI
// (matching the appendSessionCostLog contract above). The save returns void and
// swallows errors; the load returns null on any error or a missing/corrupt
// sidecar.
// ---------------------------------------------------------------------------

/// The restorable per-session running totals.
pub const SessionCostTotals = struct {
    total_input_tokens: usize = 0,
    total_output_tokens: usize = 0,
};

/// Reject session ids that could escape the session_cost directory when used as
/// a filename. Session ids minted by the store are `<seconds>-<32 hex>`, but a
/// resumed id is read from disk and must not be trusted blindly as a path
/// component. Empty, separator-bearing, or dot-traversal ids are rejected.
fn isSafeSessionId(session_id: []const u8) bool {
    if (session_id.len == 0) return false;
    if (std.mem.eql(u8, session_id, ".") or std.mem.eql(u8, session_id, "..")) return false;
    for (session_id) |c| {
        if (c == '/' or c == '\\' or c == 0) return false;
    }
    if (std.mem.indexOf(u8, session_id, "..") != null) return false;
    return true;
}

/// Build the absolute sidecar path `<home>/.zcode/session_cost/<session_id>.json`
/// and ensure the parent directory exists. Caller owns the returned slice.
fn sessionCostSidecarPath(allocator: std.mem.Allocator, home_dir: []const u8, session_id: []const u8) ![]u8 {
    const dir_path = try std.fs.path.join(allocator, &.{ home_dir, ".zcode", "session_cost" });
    defer allocator.free(dir_path);
    std.Io.Dir.cwd().createDirPath(rt.io, dir_path) catch {};

    const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{session_id});
    defer allocator.free(file_name);

    return std.fs.path.join(allocator, &.{ dir_path, file_name });
}

/// Persist the running totals for `session_id` under `home_dir`. Best-effort.
pub fn saveSessionCostTotals(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    session_id: []const u8,
    totals: SessionCostTotals,
) void {
    saveSessionCostTotalsInner(allocator, home_dir, session_id, totals) catch {};
}

fn saveSessionCostTotalsInner(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    session_id: []const u8,
    totals: SessionCostTotals,
) !void {
    if (!isSafeSessionId(session_id)) return error.UnsafeSessionId;

    const path = try sessionCostSidecarPath(allocator, home_dir, session_id);
    defer allocator.free(path);

    const flags: std.posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    const fd = try std_io.openFlagsAlloc(rt.gpa, path, flags, 0o600);
    const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(rt.io);

    var line_buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buf, "{{\"session_id\":\"{s}\",\"ts\":{d},\"total_input_tokens\":{d},\"total_output_tokens\":{d}}}\n", .{
        session_id,
        clock.nowSeconds(),
        totals.total_input_tokens,
        totals.total_output_tokens,
    });
    try file.writeStreamingAll(rt.io, line);
}

/// Restore the running totals for `session_id` from its sidecar under
/// `home_dir`. Returns null when there is no sidecar, it is unreadable, or it
/// does not match the requested session id (the strict session-id guard that
/// prevents cross-session contamination).
pub fn loadSessionCostTotals(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    session_id: []const u8,
) ?SessionCostTotals {
    return loadSessionCostTotalsInner(allocator, home_dir, session_id) catch null;
}

fn loadSessionCostTotalsInner(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    session_id: []const u8,
) !?SessionCostTotals {
    if (!isSafeSessionId(session_id)) return null;

    const path = try sessionCostSidecarPath(allocator, home_dir, session_id);
    defer allocator.free(path);

    const data = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(8192)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(data);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return null;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };

    // Strict session-id match: a sidecar whose recorded id does not equal the
    // requested one is ignored so an unrelated session cannot be restored.
    const stored_id = switch (obj.get("session_id") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    if (!std.mem.eql(u8, stored_id, session_id)) return null;

    return .{
        .total_input_tokens = jsonNonNegInt(obj.get("total_input_tokens")),
        .total_output_tokens = jsonNonNegInt(obj.get("total_output_tokens")),
    };
}

/// Read a JSON integer field as a non-negative usize, treating any missing,
/// non-integer, or negative value as 0.
fn jsonNonNegInt(value: ?std.json.Value) usize {
    const v = value orelse return 0;
    return switch (v) {
        .integer => |i| if (i > 0) @intCast(i) else 0,
        else => 0,
    };
}

const testing = std.testing;

test "estimateCost known model" {
    const cost = estimateCost("openai", "gpt-4.1", 1_000_000, 1_000_000);
    try testing.expect(cost > 0.0);
    // gpt-4.1: $2/M input + $8/M output = $10 for 1M each
    try testing.expectApproxEqAbs(@as(f64, 10.0), cost, 0.01);
}

test "estimateCost unknown model returns zero" {
    const cost = estimateCost("unknown", "nonexistent-model", 1000, 1000);
    try testing.expectApproxEqAbs(@as(f64, 0.0), cost, 0.001);
}

test "estimateCost anthropic model" {
    const cost = estimateCost("anthropic", "claude-sonnet-4-20250514", 100_000, 50_000);
    // claude-sonnet-4: $3/M input, $15/M output
    // 100k input = $0.30, 50k output = $0.75, total = $1.05
    try testing.expect(cost > 0.0);
    try testing.expectApproxEqAbs(@as(f64, 1.05), cost, 0.01);
}

test "estimateCostWithCache anthropic cache-read priced at 10% of input" {
    // claude-sonnet-4: $3/M input -> cache-read at $0.30/M.
    // 1M cache-read tokens, no input/output -> exactly $0.30.
    const cost = estimateCostWithCache("anthropic", "claude-sonnet-4-20250514", 0, 0, 1_000_000, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.30), cost, 0.0001);
}

test "estimateCostWithCache anthropic cache-write priced at 125% of input" {
    // claude-sonnet-4: $3/M input -> cache-write at $3.75/M.
    const cost = estimateCostWithCache("anthropic", "claude-sonnet-4-20250514", 0, 0, 0, 1_000_000);
    try testing.expectApproxEqAbs(@as(f64, 3.75), cost, 0.0001);
}

test "estimateCostWithCache zero cache equals estimateCost" {
    const a = estimateCostWithCache("anthropic", "claude-sonnet-4-20250514", 100_000, 50_000, 0, 0);
    const b = estimateCost("anthropic", "claude-sonnet-4-20250514", 100_000, 50_000);
    try testing.expectApproxEqAbs(b, a, 0.000001);
}

test "estimateCostWithCache non-anthropic prices cache at input rate" {
    // gpt-4.1: $2/M input, no published cache discount -> cache-read at input rate.
    // 1M cache-read tokens -> $2.00 (not a 10% discount).
    const cost = estimateCostWithCache("openai", "gpt-4.1", 0, 0, 1_000_000, 0);
    try testing.expectApproxEqAbs(@as(f64, 2.00), cost, 0.0001);
}

test "estimateCostWithCache unknown model returns zero" {
    const cost = estimateCostWithCache("unknown", "nonexistent-model", 1000, 1000, 1000, 1000);
    try testing.expectApproxEqAbs(@as(f64, 0.0), cost, 0.001);
}

test "formatCost small value" {
    var buf: [32]u8 = undefined;
    const formatted = formatCost(&buf, 0.0042);
    try testing.expect(formatted.len > 0);
    try testing.expect(formatted[0] == '$');
}

test "formatCost large value" {
    var buf: [32]u8 = undefined;
    const formatted = formatCost(&buf, 1.50);
    try testing.expect(formatted.len > 0);
    try testing.expect(formatted[0] == '$');
}

test "renderCostReport includes Usage by model when map non-empty" {
    var pm = model_usage.ModelUsageMap.init(testing.allocator);
    defer pm.deinit();
    try pm.addTokens("openai", "gpt-4.1", 1000, 200);

    const report = try renderCostReport(testing.allocator, "openai", "gpt-4.1", 1000, 200, 1000, 200, &pm);
    defer testing.allocator.free(report);

    try testing.expect(std.mem.indexOf(u8, report, "Usage by model:") != null);
    try testing.expect(std.mem.indexOf(u8, report, "gpt-4.1") != null);
}

test "renderCostReport omits Usage by model when map empty or null" {
    var pm = model_usage.ModelUsageMap.init(testing.allocator);
    defer pm.deinit();

    const with_empty = try renderCostReport(testing.allocator, "openai", "gpt-4.1", 1000, 200, 1000, 200, &pm);
    defer testing.allocator.free(with_empty);
    try testing.expect(std.mem.indexOf(u8, with_empty, "Usage by model:") == null);

    const with_null = try renderCostReport(testing.allocator, "openai", "gpt-4.1", 1000, 200, 1000, 200, null);
    defer testing.allocator.free(with_null);
    try testing.expect(std.mem.indexOf(u8, with_null, "Usage by model:") == null);
}

test "isKnownModel" {
    try testing.expect(isKnownModel("openai", "gpt-4.1"));
    try testing.expect(isKnownModel("anthropic", "claude-sonnet-4-20250514"));
    try testing.expect(!isKnownModel("unknown", "nonexistent-model"));
}

test "renderCostReport warns for unknown model with tokens" {
    const report = try renderCostReport(testing.allocator, "unknown", "nonexistent-model", 1000, 200, 1000, 200, null);
    defer testing.allocator.free(report);
    try testing.expect(std.mem.indexOf(u8, report, "cost_inaccurate=true") != null);
    try testing.expect(std.mem.indexOf(u8, report, "costs may be inaccurate due to usage of unknown models") != null);
}

test "renderCostReport no warning for known model" {
    const report = try renderCostReport(testing.allocator, "openai", "gpt-4.1", 1000, 200, 1000, 200, null);
    defer testing.allocator.free(report);
    try testing.expect(std.mem.indexOf(u8, report, "cost_inaccurate=true") == null);
}

test "renderCostReport no warning for unknown model with zero tokens" {
    // Only warn when tokens were actually produced; a fresh session with zero
    // usage should not be flagged even for an unknown model.
    const report = try renderCostReport(testing.allocator, "unknown", "nonexistent-model", 0, 0, 0, 0, null);
    defer testing.allocator.free(report);
    try testing.expect(std.mem.indexOf(u8, report, "cost_inaccurate=true") == null);
}

test "session cost sidecar round-trips totals for the same session id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(home);

    saveSessionCostTotals(testing.allocator, home, "abc", .{
        .total_input_tokens = 1234,
        .total_output_tokens = 567,
    });

    const restored = loadSessionCostTotals(testing.allocator, home, "abc");
    try testing.expect(restored != null);
    try testing.expectEqual(@as(usize, 1234), restored.?.total_input_tokens);
    try testing.expectEqual(@as(usize, 567), restored.?.total_output_tokens);
}

test "session cost sidecar does not restore a different session id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(home);

    saveSessionCostTotals(testing.allocator, home, "abc", .{
        .total_input_tokens = 1234,
        .total_output_tokens = 567,
    });

    // A different session id has no sidecar of its own, so nothing is restored.
    const restored = loadSessionCostTotals(testing.allocator, home, "xyz");
    try testing.expect(restored == null);
}

test "session cost sidecar returns null when none exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(home);

    const restored = loadSessionCostTotals(testing.allocator, home, "never-written");
    try testing.expect(restored == null);
}

test "session cost sidecar latest write wins on re-save" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(home);

    saveSessionCostTotals(testing.allocator, home, "abc", .{ .total_input_tokens = 10, .total_output_tokens = 5 });
    saveSessionCostTotals(testing.allocator, home, "abc", .{ .total_input_tokens = 99, .total_output_tokens = 88 });

    const restored = loadSessionCostTotals(testing.allocator, home, "abc");
    try testing.expect(restored != null);
    try testing.expectEqual(@as(usize, 99), restored.?.total_input_tokens);
    try testing.expectEqual(@as(usize, 88), restored.?.total_output_tokens);
}

test "session cost sidecar rejects unsafe session ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(home);

    // Traversal / separator-bearing ids must not write or read anything.
    saveSessionCostTotals(testing.allocator, home, "../escape", .{ .total_input_tokens = 1, .total_output_tokens = 1 });
    try testing.expect(loadSessionCostTotals(testing.allocator, home, "../escape") == null);
    try testing.expect(loadSessionCostTotals(testing.allocator, home, "a/b") == null);
    try testing.expect(loadSessionCostTotals(testing.allocator, home, "") == null);
}

test "isSafeSessionId accepts store-minted ids and rejects traversal" {
    try testing.expect(isSafeSessionId("1700000000-0123456789abcdef0123456789abcdef"));
    try testing.expect(!isSafeSessionId(""));
    try testing.expect(!isSafeSessionId("."));
    try testing.expect(!isSafeSessionId(".."));
    try testing.expect(!isSafeSessionId("a/b"));
    try testing.expect(!isSafeSessionId("a..b"));
    try testing.expect(!isSafeSessionId("a\\b"));
}
