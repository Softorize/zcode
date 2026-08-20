//! Per-model usage accumulation (cost-limits-01).
//!
//! Mirrors the reference's `cost-tracker.ts` per-model breakdown
//! (`addToTotalModelUsage` at lines 250-276, `formatModelUsage` at 181-226):
//! each model that produced tokens gets one accumulated `ModelUsage` record,
//! and `/cost` renders a "Usage by model:" block listing every model with its
//! input/output/cache/web-search token counts and accumulated dollar cost.
//!
//! The map is keyed by model name. Keys are OWNED (duped on first insert, freed
//! on deinit) so a borrowed `active_model` slice that is later freed/replaced
//! cannot dangle the key (per the 0.16 StringHashMap footgun).
const std = @import("std");
const std_io = @import("std_io.zig");
const format = @import("format.zig");
const cost = @import("cost.zig");

/// One model's accumulated usage over a session.
pub const ModelUsage = struct {
    input_tokens: usize = 0,
    output_tokens: usize = 0,
    cache_read_tokens: usize = 0,
    cache_write_tokens: usize = 0,
    web_search_requests: usize = 0,
    cost_usd: f64 = 0.0,
};

/// Accumulates `ModelUsage` keyed by model name. Backed by a StringHashMap with
/// owned string keys.
pub const ModelUsageMap = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(ModelUsage),

    pub fn init(allocator: std.mem.Allocator) ModelUsageMap {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(ModelUsage).init(allocator),
        };
    }

    pub fn deinit(self: *ModelUsageMap) void {
        var it = self.map.keyIterator();
        while (it.next()) |key_ptr| {
            self.allocator.free(key_ptr.*);
        }
        self.map.deinit();
    }

    /// Add a usage delta for `model`. The first time a model is seen its name is
    /// duped so the map owns the key. Subsequent adds accumulate in place.
    pub fn add(self: *ModelUsageMap, model: []const u8, usage: ModelUsage) !void {
        const gop = try self.map.getOrPut(model);
        if (!gop.found_existing) {
            // Dupe the key only on first insert. getOrPut stored a pointer to the
            // borrowed `model` slice; replace it with an owned copy so a later
            // free of the caller's slice cannot dangle the key. On dupe failure,
            // roll back the just-inserted entry so the map stays consistent.
            const owned = self.allocator.dupe(u8, model) catch |err| {
                _ = self.map.remove(model);
                return err;
            };
            gop.key_ptr.* = owned;
            gop.value_ptr.* = .{};
        }
        // Re-fetch nothing: getOrPut returned stable pointers for THIS call and
        // we have not inserted again since, so value_ptr is valid here.
        gop.value_ptr.input_tokens += usage.input_tokens;
        gop.value_ptr.output_tokens += usage.output_tokens;
        gop.value_ptr.cache_read_tokens += usage.cache_read_tokens;
        gop.value_ptr.cache_write_tokens += usage.cache_write_tokens;
        gop.value_ptr.web_search_requests += usage.web_search_requests;
        gop.value_ptr.cost_usd += usage.cost_usd;
    }

    /// Convenience: accumulate from raw token counts plus a provider/model so the
    /// per-model cost is computed the same way the session totals are. Cache and
    /// web-search counts default to zero (not yet plumbed through ModelResponse).
    pub fn addTokens(
        self: *ModelUsageMap,
        provider: []const u8,
        model: []const u8,
        input_tokens: usize,
        output_tokens: usize,
    ) !void {
        const usd = cost.estimateCost(provider, model, input_tokens, output_tokens);
        try self.add(model, .{
            .input_tokens = input_tokens,
            .output_tokens = output_tokens,
            .cost_usd = usd,
        });
    }

    pub fn count(self: *const ModelUsageMap) usize {
        return self.map.count();
    }

    pub fn iterator(self: *const ModelUsageMap) std.StringHashMap(ModelUsage).Iterator {
        return self.map.iterator();
    }

    /// Render a "Usage by model:" block into `w`. No-op when the map is empty so
    /// callers can unconditionally invoke it. Each line:
    ///   <model>: N input, N output[, N cache read][, N cache write][, N web search] ($cost)
    pub fn renderInto(self: *const ModelUsageMap, w: anytype) !void {
        if (self.map.count() == 0) return;
        try w.print("Usage by model:\n", .{});
        var it = self.map.iterator();
        while (it.next()) |entry| {
            const u = entry.value_ptr.*;
            var in_buf: [32]u8 = undefined;
            var out_buf: [32]u8 = undefined;
            var cr_buf: [32]u8 = undefined;
            var cw_buf: [32]u8 = undefined;
            var ws_buf: [32]u8 = undefined;
            var cost_buf: [32]u8 = undefined;
            try w.print("  {s}: {s} input, {s} output", .{
                entry.key_ptr.*,
                format.formatTokens(&in_buf, u.input_tokens),
                format.formatTokens(&out_buf, u.output_tokens),
            });
            if (u.cache_read_tokens > 0) {
                try w.print(", {s} cache read", .{format.formatTokens(&cr_buf, u.cache_read_tokens)});
            }
            if (u.cache_write_tokens > 0) {
                try w.print(", {s} cache write", .{format.formatTokens(&cw_buf, u.cache_write_tokens)});
            }
            if (u.web_search_requests > 0) {
                try w.print(", {s} web search", .{format.formatTokens(&ws_buf, u.web_search_requests)});
            }
            try w.print(" ({s})\n", .{cost.formatCost(&cost_buf, u.cost_usd)});
        }
    }
};

const testing = std.testing;

test "ModelUsageMap two adds for same model accumulate" {
    var m = ModelUsageMap.init(testing.allocator);
    defer m.deinit();

    try m.add("claude-sonnet-4", .{ .input_tokens = 100, .output_tokens = 20, .cost_usd = 0.5 });
    try m.add("claude-sonnet-4", .{ .input_tokens = 50, .output_tokens = 10, .cost_usd = 0.25 });

    try testing.expectEqual(@as(usize, 1), m.count());
    const u = m.map.get("claude-sonnet-4").?;
    try testing.expectEqual(@as(usize, 150), u.input_tokens);
    try testing.expectEqual(@as(usize, 30), u.output_tokens);
    try testing.expectApproxEqAbs(@as(f64, 0.75), u.cost_usd, 0.0001);
}

test "ModelUsageMap two different models produce two entries" {
    var m = ModelUsageMap.init(testing.allocator);
    defer m.deinit();

    try m.add("claude-sonnet-4", .{ .input_tokens = 100, .output_tokens = 20 });
    try m.add("gpt-4.1", .{ .input_tokens = 200, .output_tokens = 40 });

    try testing.expectEqual(@as(usize, 2), m.count());
    try testing.expect(m.map.get("claude-sonnet-4") != null);
    try testing.expect(m.map.get("gpt-4.1") != null);
}

test "ModelUsageMap addTokens computes cost" {
    var m = ModelUsageMap.init(testing.allocator);
    defer m.deinit();

    // gpt-4.1: $2/M input, $8/M output -> 1M each = $10.
    try m.addTokens("openai", "gpt-4.1", 1_000_000, 1_000_000);
    const u = m.map.get("gpt-4.1").?;
    try testing.expectApproxEqAbs(@as(f64, 10.0), u.cost_usd, 0.01);
}

test "ModelUsageMap renderInto contains both models and per-model cost" {
    var m = ModelUsageMap.init(testing.allocator);
    defer m.deinit();

    try m.add("claude-sonnet-4", .{ .input_tokens = 100, .output_tokens = 20, .cost_usd = 0.5 });
    try m.add("gpt-4.1", .{ .input_tokens = 200, .output_tokens = 40, .cost_usd = 1.0 });

    var out = std_io.StringBuilder.init(testing.allocator);
    defer out.deinit();
    try m.renderInto(out.writer());

    const s = out.items();
    try testing.expect(std.mem.indexOf(u8, s, "Usage by model:") != null);
    try testing.expect(std.mem.indexOf(u8, s, "claude-sonnet-4") != null);
    try testing.expect(std.mem.indexOf(u8, s, "gpt-4.1") != null);
    // Per-model cost is rendered as a $ figure.
    try testing.expect(std.mem.indexOf(u8, s, "$") != null);
}

test "ModelUsageMap renderInto on empty map is a no-op" {
    var m = ModelUsageMap.init(testing.allocator);
    defer m.deinit();

    var out = std_io.StringBuilder.init(testing.allocator);
    defer out.deinit();
    try m.renderInto(out.writer());
    try testing.expectEqual(@as(usize, 0), out.items().len);
}

test "ModelUsageMap renderInto includes cache and web-search lines when present" {
    var m = ModelUsageMap.init(testing.allocator);
    defer m.deinit();

    try m.add("claude-sonnet-4", .{
        .input_tokens = 100,
        .output_tokens = 20,
        .cache_read_tokens = 40,
        .cache_write_tokens = 8,
        .web_search_requests = 3,
        .cost_usd = 0.5,
    });

    var out = std_io.StringBuilder.init(testing.allocator);
    defer out.deinit();
    try m.renderInto(out.writer());

    const s = out.items();
    try testing.expect(std.mem.indexOf(u8, s, "cache read") != null);
    try testing.expect(std.mem.indexOf(u8, s, "cache write") != null);
    try testing.expect(std.mem.indexOf(u8, s, "web search") != null);
}
