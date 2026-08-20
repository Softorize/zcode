//! P4 (PRD #534) fallback model selection. Claude Code swaps to a configured
//! fallback model when the primary is overloaded/rate-limited. Pure: inputs in,
//! a model name (or null) out. No allocation, no IO.

const std = @import("std");

pub const Trigger = enum { none, overload, rate_limit };

/// Classify an HTTP status into a fallback trigger. 529 (overloaded) and 503 ->
/// overload; 429 -> rate_limit; everything else -> none.
pub fn triggerFromStatus(status: u16) Trigger {
    return switch (status) {
        529, 503 => .overload,
        429 => .rate_limit,
        else => .none,
    };
}

/// Pick the model to retry with. Returns `fallback` when the trigger warrants a
/// swap and `fallback` is non-empty and differs from `current`; otherwise null
/// (keep the current model / don't swap).
pub fn pick(current: []const u8, fallback: []const u8, trigger: Trigger) ?[]const u8 {
    if (trigger == .none) return null;
    if (fallback.len == 0) return null;
    if (std.mem.eql(u8, fallback, current)) return null;
    return fallback;
}

/// agent-loop-deep-03: format the persisted swap notice. The reference appends a
/// "Switched to <fallback> due to high demand" system message to the
/// conversation (query.ts:893-951) so the model and the transcript see why the
/// model changed mid-turn. zcode mirrors that phrasing and also names the model
/// that was overloaded so a saved transcript explains the swap. Caller owns the
/// returned slice.
pub fn announceSwap(allocator: std.mem.Allocator, original: []const u8, fallback: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "Switched to {s} due to high demand for {s}",
        .{ fallback, original },
    );
}

const testing = std.testing;

test "triggerFromStatus maps overload and rate-limit" {
    try testing.expectEqual(Trigger.overload, triggerFromStatus(529));
    try testing.expectEqual(Trigger.overload, triggerFromStatus(503));
    try testing.expectEqual(Trigger.rate_limit, triggerFromStatus(429));
    try testing.expectEqual(Trigger.none, triggerFromStatus(200));
    try testing.expectEqual(Trigger.none, triggerFromStatus(400));
}

test "pick swaps only on a real trigger with a distinct fallback" {
    try testing.expectEqualStrings("haiku", pick("opus", "haiku", .overload).?);
    try testing.expectEqualStrings("haiku", pick("opus", "haiku", .rate_limit).?);
    try testing.expect(pick("opus", "haiku", .none) == null);
    try testing.expect(pick("opus", "", .overload) == null);
    try testing.expect(pick("opus", "opus", .overload) == null);
}

test "announceSwap uses the reference 'due to high demand' phrasing" {
    const msg = try announceSwap(testing.allocator, "opus", "haiku");
    defer testing.allocator.free(msg);
    try testing.expectEqualStrings("Switched to haiku due to high demand for opus", msg);
}
