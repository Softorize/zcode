const std = @import("std");

/// Validate a bounded-integer environment variable. Ported from
/// claude-code-main/src/utils/envValidation.ts validateBoundedIntEnvVar.
///
/// The reference uses this to sanitize env-driven config knobs
/// (output size limits, token budgets, retry counts) so a bad
/// user value can't propagate into the rest of the program:
///
///   - Missing / empty env var -> use `default_value`
///   - Not an integer -> use `default_value`, tagged `.invalid`
///   - Integer but > `upper_limit` -> cap at `upper_limit`, tagged `.capped`
///   - Integer in-range -> pass through, tagged `.valid`
///
/// zcode has several call sites that currently parse env ints by
/// hand (provider retry counts, tool result caps, spinner delays).
/// Consolidating them through this helper gives us a single place
/// to enforce the "reject garbage, cap runaway values" policy and
/// lets /doctor surface misconfigured env vars via the tagged
/// status field.
pub const Status = enum {
    /// Value parsed cleanly and fits the bound. Use `effective` as-is.
    valid,
    /// Value parsed but exceeded `upper_limit`. `effective` is the cap.
    capped,
    /// Value was missing, empty, non-numeric, or <= 0. `effective` is the default.
    invalid,
};

pub const Result = struct {
    /// The integer the caller should actually use.
    effective: usize,
    /// Classification of the input. `valid` means no tampering.
    status: Status,
    /// Optional human-readable message -- non-empty for `.capped`
    /// and `.invalid` so callers can surface the warning in
    /// /doctor or logs. Caller owns the slice; free with
    /// `freeResult` or by calling `allocator.free(result.message)`
    /// directly when message.len > 0.
    message: []u8,
};

/// Convenience wrapper: free the `message` if it was populated.
pub fn freeResult(allocator: std.mem.Allocator, result: Result) void {
    if (result.message.len > 0) allocator.free(result.message);
}

/// Parse `raw_value` as a bounded positive integer. The reference
/// signature takes the env-var NAME purely for logging; zcode
/// follows the same convention so call sites read naturally.
///
/// Callers typically invoke as:
///
///     const raw = @import("env.zig").getenv("ZCODE_FOO");
///     const r = env_validation.validateBoundedInt(
///         allocator, "ZCODE_FOO", raw, 32, 4096);
///     defer env_validation.freeResult(allocator, r);
///     use(r.effective);
pub fn validateBoundedInt(
    allocator: std.mem.Allocator,
    name: []const u8,
    raw_value: ?[]const u8,
    default_value: usize,
    upper_limit: usize,
) !Result {
    if (raw_value == null or raw_value.?.len == 0) {
        return .{ .effective = default_value, .status = .valid, .message = &.{} };
    }
    const trimmed = std.mem.trim(u8, raw_value.?, " \t\r\n");
    if (trimmed.len == 0) {
        return .{ .effective = default_value, .status = .valid, .message = &.{} };
    }

    const parsed = std.fmt.parseInt(usize, trimmed, 10) catch {
        const msg = try std.fmt.allocPrint(
            allocator,
            "{s}: invalid value \"{s}\" (using default: {d})",
            .{ name, trimmed, default_value },
        );
        return .{ .effective = default_value, .status = .invalid, .message = msg };
    };

    // Reference rejects <= 0 via `isNaN(parsed) || parsed <= 0`.
    // Our parseInt already catches non-numeric; we need to
    // explicitly reject zero because the reference does.
    if (parsed == 0) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "{s}: invalid value \"{s}\" (using default: {d})",
            .{ name, trimmed, default_value },
        );
        return .{ .effective = default_value, .status = .invalid, .message = msg };
    }

    if (parsed > upper_limit) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "{s}: capped from {d} to {d}",
            .{ name, parsed, upper_limit },
        );
        return .{ .effective = upper_limit, .status = .capped, .message = msg };
    }

    return .{ .effective = parsed, .status = .valid, .message = &.{} };
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "validateBoundedInt returns default for null input" {
    const alloc = testing.allocator;
    const r = try validateBoundedInt(alloc, "FOO", null, 10, 100);
    defer freeResult(alloc, r);
    try testing.expectEqual(@as(usize, 10), r.effective);
    try testing.expectEqual(Status.valid, r.status);
    try testing.expectEqual(@as(usize, 0), r.message.len);
}

test "validateBoundedInt returns default for empty string" {
    const alloc = testing.allocator;
    const r = try validateBoundedInt(alloc, "FOO", "", 10, 100);
    defer freeResult(alloc, r);
    try testing.expectEqual(@as(usize, 10), r.effective);
    try testing.expectEqual(Status.valid, r.status);
}

test "validateBoundedInt returns default for whitespace-only string" {
    const alloc = testing.allocator;
    const r = try validateBoundedInt(alloc, "FOO", "   ", 10, 100);
    defer freeResult(alloc, r);
    try testing.expectEqual(@as(usize, 10), r.effective);
    try testing.expectEqual(Status.valid, r.status);
}

test "validateBoundedInt passes through in-range values" {
    const alloc = testing.allocator;
    const r = try validateBoundedInt(alloc, "FOO", "42", 10, 100);
    defer freeResult(alloc, r);
    try testing.expectEqual(@as(usize, 42), r.effective);
    try testing.expectEqual(Status.valid, r.status);
}

test "validateBoundedInt caps values above the upper limit" {
    const alloc = testing.allocator;
    const r = try validateBoundedInt(alloc, "ZCODE_TOKENS", "5000", 100, 1000);
    defer freeResult(alloc, r);
    try testing.expectEqual(@as(usize, 1000), r.effective);
    try testing.expectEqual(Status.capped, r.status);
    try testing.expect(std.mem.indexOf(u8, r.message, "ZCODE_TOKENS") != null);
    try testing.expect(std.mem.indexOf(u8, r.message, "5000") != null);
    try testing.expect(std.mem.indexOf(u8, r.message, "1000") != null);
}

test "validateBoundedInt flags non-numeric values as invalid" {
    const alloc = testing.allocator;
    const r = try validateBoundedInt(alloc, "ZCODE_BUDGET", "five hundred", 100, 1000);
    defer freeResult(alloc, r);
    try testing.expectEqual(@as(usize, 100), r.effective);
    try testing.expectEqual(Status.invalid, r.status);
    try testing.expect(std.mem.indexOf(u8, r.message, "ZCODE_BUDGET") != null);
    try testing.expect(std.mem.indexOf(u8, r.message, "invalid") != null);
}

test "validateBoundedInt flags zero as invalid" {
    const alloc = testing.allocator;
    const r = try validateBoundedInt(alloc, "FOO", "0", 10, 100);
    defer freeResult(alloc, r);
    try testing.expectEqual(@as(usize, 10), r.effective);
    try testing.expectEqual(Status.invalid, r.status);
}

test "validateBoundedInt trims whitespace before parsing" {
    const alloc = testing.allocator;
    const r = try validateBoundedInt(alloc, "FOO", "  42  ", 10, 100);
    defer freeResult(alloc, r);
    try testing.expectEqual(@as(usize, 42), r.effective);
    try testing.expectEqual(Status.valid, r.status);
}

test "validateBoundedInt at exactly upper_limit is valid not capped" {
    const alloc = testing.allocator;
    const r = try validateBoundedInt(alloc, "FOO", "100", 10, 100);
    defer freeResult(alloc, r);
    try testing.expectEqual(@as(usize, 100), r.effective);
    try testing.expectEqual(Status.valid, r.status);
}

test "validateBoundedInt at upper_limit + 1 is capped" {
    const alloc = testing.allocator;
    const r = try validateBoundedInt(alloc, "FOO", "101", 10, 100);
    defer freeResult(alloc, r);
    try testing.expectEqual(@as(usize, 100), r.effective);
    try testing.expectEqual(Status.capped, r.status);
}
