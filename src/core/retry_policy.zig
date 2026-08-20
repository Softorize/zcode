//! #571: retry_policy deep module.
//!
//! Maps a provider error (HTTP status code + error body signals) to a retry
//! decision: retry vs fail, backoff schedule (base, cap, jitter). Direct
//! port of the reference's retry logic from src/services/api/withRetry.ts
//! and src/services/api/errors.ts.
//!
//! Pure module: (status, body, attempt, headers) -> RetryDecision. No IO,
//! no sleeping, no actual retry loop. The agent runtime (#573) calls this
//! to decide whether to retry and how long to wait.
//!
//! Reference constants (withRetry.ts):
//!   BASE_DELAY_MS = 500
//!   DEFAULT_MAX_RETRIES = 10
//!   backoff = BASE_DELAY_MS * 2^(attempt-1), capped at 60_000 ms

const std = @import("std");

pub const BASE_DELAY_MS: u64 = 500;
pub const DEFAULT_MAX_RETRIES: u32 = 10;
pub const MAX_DELAY_MS: u64 = 60_000;

pub const RetryCategory = enum {
    aborted,
    api_timeout,
    repeated_529,
    capacity_off_switch,
    rate_limit, // 429
    server_overload, // 529 or overloaded_error
    prompt_too_long,
    pdf_too_large,
    pdf_password_protected,
    image_too_large,
    tool_use_error, // 400 with tool_use id mismatch
    max_tokens_context_overflow,
    auth_error, // 401/403 (non-CCR)
    client_error, // other 4xx
    unknown,
};

pub const RetryDecision = struct {
    should_retry: bool,
    category: RetryCategory,
    delay_ms: u64,
    attempt: u32,
    max_retries: u32,
};

/// Categorize an error from its HTTP status code and response body.
/// Direct port of reference classifyAPIError (errors.ts) + shouldRetry
/// (withRetry.ts). Body signals are checked because the SDK sometimes
/// fails to pass the 529 status during streaming, so the message must
/// be inspected.
pub fn categorize(status: u16, body: []const u8) RetryCategory {
    // Aborted/timeout: caller detects these before calling; body may be empty.
    if (std.mem.indexOf(u8, body, "Request was aborted") != null) return .aborted;
    if (std.mem.indexOf(u8, body, "timeout") != null) return .api_timeout;

    // Repeated 529
    if (std.mem.indexOf(u8, body, "Repeated 529 Overloaded errors") != null) return .repeated_529;

    // 429 rate limit
    if (status == 429) return .rate_limit;

    // 529 server overload, or overloaded_error in body (SDK streaming miss)
    if (status == 529 or std.mem.indexOf(u8, body, "\"type\":\"overloaded_error\"") != null) {
        return .server_overload;
    }

    // Prompt too long
    if (std.mem.indexOf(u8, body, "Prompt is too long") != null) return .prompt_too_long;

    // PDF errors
    if (std.mem.indexOf(u8, body, "password protected") != null) return .pdf_password_protected;

    // Image size errors (400)
    if (status == 400 and std.mem.indexOf(u8, body, "image exceeds") != null) return .image_too_large;

    // Tool use errors (400)
    if (status == 400 and std.mem.indexOf(u8, body, "tool_use") != null and std.mem.indexOf(u8, body, "tool_result") != null) {
        return .tool_use_error;
    }

    // Max tokens context overflow - retryable per shouldRetry
    if (std.mem.indexOf(u8, body, "max_tokens") != null and std.mem.indexOf(u8, body, "context") != null) {
        return .max_tokens_context_overflow;
    }

    // Auth errors (non-CCR; CCR mode retries these, but zcode is not CCR)
    if (status == 401 or status == 403) return .auth_error;

    // Other 4xx
    if (status >= 400 and status < 500) return .client_error;

    return .unknown;
}

/// Decide whether to retry and how long to wait. Direct port of reference
/// shouldRetry (withRetry.ts) + exponential backoff.
pub fn decide(status: u16, body: []const u8, attempt: u32, max_retries: u32) RetryDecision {
    const category = categorize(status, body);

    // Categories that never retry.
    const never_retry = switch (category) {
        .aborted,
        .api_timeout,
        .prompt_too_long,
        .pdf_too_large,
        .pdf_password_protected,
        .image_too_large,
        .tool_use_error,
        .auth_error,
        .client_error,
        .repeated_529,
        .capacity_off_switch,
        => true,
        else => false,
    };

    if (never_retry) {
        return .{
            .should_retry = false,
            .category = category,
            .delay_ms = 0,
            .attempt = attempt,
            .max_retries = max_retries,
        };
    }

    // Categories that retry: rate_limit, server_overload, max_tokens_context_overflow, unknown (5xx).
    if (attempt >= max_retries) {
        return .{
            .should_retry = false,
            .category = category,
            .delay_ms = 0,
            .attempt = attempt,
            .max_retries = max_retries,
        };
    }

    // Exponential backoff: BASE_DELAY_MS * 2^(attempt-1), capped at MAX_DELAY_MS.
    // attempt starts at 1; first retry uses BASE_DELAY_MS * 2^0 = 500ms.
    const exp: u6 = @intCast(@min(attempt - 1, 20)); // clamp to avoid overflow
    const raw_delay: u64 = BASE_DELAY_MS * (@as(u64, 1) << exp);
    const delay_ms = @min(raw_delay, MAX_DELAY_MS);

    return .{
        .should_retry = true,
        .category = category,
        .delay_ms = delay_ms,
        .attempt = attempt,
        .max_retries = max_retries,
    };
}

/// Adapter: map a zcode typed error (from providers/common.zig
/// mapHttpStatusError) to a RetryCategory. Used by the agent runtime
/// (#573) to route typed errors through the centralized categorization
/// without having to plumb the raw status code everywhere.
pub fn categorizeError(err: anyerror) RetryCategory {
    return switch (err) {
        error.ConnectionTimeout => .api_timeout,
        error.RateLimited => .rate_limit,
        error.ServerOverloaded => .server_overload,
        error.RequestTooLarge => .prompt_too_long,
        error.MaxTokensOverflow => .max_tokens_context_overflow,
        error.AuthenticationFailed => .auth_error,
        error.HttpTransport => .unknown, // transient transport error, retryable
        else => .client_error,
    };
}

/// Decide retry from a zcode typed error. Convenience wrapper around
/// decide() for when the runtime has a typed error but not a raw status.
pub fn decideError(err: anyerror, attempt: u32, max_retries: u32) RetryDecision {
    const category = categorizeError(err);
    const never_retry = switch (category) {
        .aborted, .api_timeout, .prompt_too_long, .auth_error, .client_error, .repeated_529, .capacity_off_switch => true,
        else => false,
    };
    if (never_retry or attempt >= max_retries) {
        return .{ .should_retry = false, .category = category, .delay_ms = 0, .attempt = attempt, .max_retries = max_retries };
    }
    const exp: u6 = @intCast(@min(attempt - 1, 20));
    const raw_delay: u64 = BASE_DELAY_MS * (@as(u64, 1) << exp);
    return .{ .should_retry = true, .category = category, .delay_ms = @min(raw_delay, MAX_DELAY_MS), .attempt = attempt, .max_retries = max_retries };
}

// ---------------------------------------------------------------------------
// Tests: for each status code in the reference's retry table, assert the
// same retry decision (retry vs fail, backoff schedule).
// ---------------------------------------------------------------------------

const testing = std.testing;

test "429 rate_limit retries with exponential backoff" {
    const d = decide(429, "", 1, DEFAULT_MAX_RETRIES);
    try testing.expect(d.should_retry);
    try testing.expectEqual(RetryCategory.rate_limit, d.category);
    try testing.expectEqual(@as(u64, 500), d.delay_ms); // 500 * 2^0

    const d2 = decide(429, "", 2, DEFAULT_MAX_RETRIES);
    try testing.expect(d2.should_retry);
    try testing.expectEqual(@as(u64, 1000), d2.delay_ms); // 500 * 2^1

    const d3 = decide(429, "", 3, DEFAULT_MAX_RETRIES);
    try testing.expectEqual(@as(u64, 2000), d3.delay_ms); // 500 * 2^2
}

test "529 server_overload retries (matches reference shouldRetry)" {
    const d = decide(529, "", 1, DEFAULT_MAX_RETRIES);
    try testing.expect(d.should_retry);
    try testing.expectEqual(RetryCategory.server_overload, d.category);
}

test "overloaded_error in body triggers server_overload even without 529 status" {
    // The SDK sometimes fails to pass 529 during streaming; the body must be inspected.
    const d = decide(500, "\"type\":\"overloaded_error\"", 1, DEFAULT_MAX_RETRIES);
    try testing.expect(d.should_retry);
    try testing.expectEqual(RetryCategory.server_overload, d.category);
}

test "401 auth_error does not retry (non-CCR mode)" {
    const d = decide(401, "", 1, DEFAULT_MAX_RETRIES);
    try testing.expect(!d.should_retry);
    try testing.expectEqual(RetryCategory.auth_error, d.category);
}

test "403 auth_error does not retry (non-CCR mode)" {
    const d = decide(403, "", 1, DEFAULT_MAX_RETRIES);
    try testing.expect(!d.should_retry);
    try testing.expectEqual(RetryCategory.auth_error, d.category);
}

test "400 prompt_too_long does not retry" {
    const d = decide(400, "Prompt is too long: 137500 tokens > 135000 maximum", 1, DEFAULT_MAX_RETRIES);
    try testing.expect(!d.should_retry);
    try testing.expectEqual(RetryCategory.prompt_too_long, d.category);
}

test "400 tool_use error does not retry" {
    const d = decide(400, "`tool_use` ids were found without `tool_result` blocks", 1, DEFAULT_MAX_RETRIES);
    try testing.expect(!d.should_retry);
    try testing.expectEqual(RetryCategory.tool_use_error, d.category);
}

test "400 image_too_large does not retry" {
    const d = decide(400, "image exceeds maximum size", 1, DEFAULT_MAX_RETRIES);
    try testing.expect(!d.should_retry);
    try testing.expectEqual(RetryCategory.image_too_large, d.category);
}

test "repeated_529 does not retry" {
    const d = decide(529, "Repeated 529 Overloaded errors", 1, DEFAULT_MAX_RETRIES);
    try testing.expect(!d.should_retry);
    try testing.expectEqual(RetryCategory.repeated_529, d.category);
}

test "backoff caps at MAX_DELAY_MS (60s)" {
    // attempt 8: 500 * 2^7 = 64000 > 60000 -> capped
    const d = decide(429, "", 8, DEFAULT_MAX_RETRIES);
    try testing.expect(d.should_retry);
    try testing.expectEqual(MAX_DELAY_MS, d.delay_ms);
}

test "retry stops after max_retries" {
    const d = decide(429, "", DEFAULT_MAX_RETRIES, DEFAULT_MAX_RETRIES);
    try testing.expect(!d.should_retry);
    try testing.expectEqual(@as(u64, 0), d.delay_ms);
}

test "unknown 5xx retries (falls through to retryable)" {
    const d = decide(503, "", 1, DEFAULT_MAX_RETRIES);
    try testing.expect(d.should_retry);
    try testing.expectEqual(RetryCategory.unknown, d.category);
}

test "max_tokens context overflow retries" {
    const d = decide(400, "max_tokens context overflow", 1, DEFAULT_MAX_RETRIES);
    try testing.expect(d.should_retry);
    try testing.expectEqual(RetryCategory.max_tokens_context_overflow, d.category);
}

// #573 integration tests: categorizeError / decideError bridge zcode's
// typed errors (from providers/common.zig mapHttpStatusError) to the
// centralized retry_policy categorization.

test "categorizeError maps zcode typed errors to categories" {
    try testing.expectEqual(RetryCategory.api_timeout, categorizeError(error.ConnectionTimeout));
    try testing.expectEqual(RetryCategory.rate_limit, categorizeError(error.RateLimited));
    try testing.expectEqual(RetryCategory.server_overload, categorizeError(error.ServerOverloaded));
    try testing.expectEqual(RetryCategory.prompt_too_long, categorizeError(error.RequestTooLarge));
    try testing.expectEqual(RetryCategory.max_tokens_context_overflow, categorizeError(error.MaxTokensOverflow));
    try testing.expectEqual(RetryCategory.auth_error, categorizeError(error.AuthenticationFailed));
    try testing.expectEqual(RetryCategory.unknown, categorizeError(error.HttpTransport));
}

test "decideError retries RateLimited with backoff" {
    const d = decideError(error.RateLimited, 1, DEFAULT_MAX_RETRIES);
    try testing.expect(d.should_retry);
    try testing.expectEqual(RetryCategory.rate_limit, d.category);
    try testing.expectEqual(@as(u64, 500), d.delay_ms);
}

test "decideError does not retry AuthenticationFailed" {
    const d = decideError(error.AuthenticationFailed, 1, DEFAULT_MAX_RETRIES);
    try testing.expect(!d.should_retry);
    try testing.expectEqual(RetryCategory.auth_error, d.category);
}

test "decideError does not retry RequestTooLarge (prompt_too_long)" {
    const d = decideError(error.RequestTooLarge, 1, DEFAULT_MAX_RETRIES);
    try testing.expect(!d.should_retry);
    try testing.expectEqual(RetryCategory.prompt_too_long, d.category);
}

test "decideError retries HttpTransport (transient)" {
    const d = decideError(error.HttpTransport, 1, DEFAULT_MAX_RETRIES);
    try testing.expect(d.should_retry);
    try testing.expectEqual(RetryCategory.unknown, d.category);
}
