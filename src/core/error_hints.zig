const std = @import("std");

/// Map a Zig error to a short user-facing remediation sentence. Returns
/// null when the error is not one we have targeted advice for, so the
/// caller can decide whether to fall through to `@errorName(err)` verbatim
/// or add its own context.
///
/// Keep messages ≤ 120 chars, no newlines, imperative voice. Paired with
/// the @errorName in the caller's format string so users get both the
/// machine-readable name AND actionable guidance in one line.
pub fn describeUiError(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.FileNotFound => "file not found — check the path, or run /ls to see the workspace",
        error.AccessDenied => "permission denied — check file ownership / chmod, or run from an allowed directory",
        error.IsDir => "path is a directory — use the directory-specific tool, or append a filename",
        error.NotDir => "path is not a directory — drop the trailing slash",
        error.PathAlreadyExists => "path already exists — delete it first or pick a different name",
        error.OutOfMemory => "out of memory — try /compact to trim history, or restart zcode",
        error.BrokenPipe => "pipe closed by the reader — expected when piping to `head` etc, usually safe to ignore",
        error.ConnectionRefused => "connection refused — is the server running? check base_url in config",
        error.ConnectionTimedOut, error.ConnectionTimeout => "connection timed out — check network, or raise provider_timeout_ms in config",
        error.NetworkUnreachable => "network unreachable — check VPN / connectivity",
        error.DnsResolutionFailed => "DNS lookup failed — check connectivity, or use an IP in base_url",
        error.SslError => "SSL/TLS error - behind a TLS proxy? set CURL_CA_BUNDLE or SSL_CERT_FILE to your CA bundle, or run /doctor",
        error.InvalidSessionKey => "ZCODE_SESSION_KEY is missing, wrong length, or all-zero — generate a fresh 32-byte key",
        error.SessionKeyRequired => "session encryption is on but ZCODE_SESSION_KEY is not set",
        error.RipgrepUnavailable => "ripgrep not on PATH — install `rg` or zcode will fall back to the in-process grep",
        error.MarketplaceSourceDenied => "marketplace source not in the allow-list — edit ~/.zcode/marketplace-policy.json",
        error.CircuitBreakerOpen => "provider circuit breaker is open — wait for the cooldown, or /model to switch",
        error.StreamTooLong => "request exceeded the per-line size cap",
        error.RequestTooLarge => "request exceeded the per-connection size cap",
        error.MaxTokensOverflow => "input + max_tokens exceed the model context limit - zcode lowers max_tokens and retries; /compact if it persists",
        else => null,
    };
}

/// Format an error for user display: `"<prefix>: <errorName> — <hint>"`.
/// The caller owns the returned slice. Falls back to `<prefix>: <errorName>`
/// when `describeUiError` returns null.
///
/// Use when you would otherwise write
///   `std.fmt.allocPrint(a, "{s}: {s}", .{prefix, @errorName(err)})`.
pub fn formatUiError(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    err: anyerror,
) std.mem.Allocator.Error![]u8 {
    if (describeUiError(err)) |hint| {
        return std.fmt.allocPrint(allocator, "{s}: {s} — {s}", .{ prefix, @errorName(err), hint });
    }
    return std.fmt.allocPrint(allocator, "{s}: {s}", .{ prefix, @errorName(err) });
}

const testing = std.testing;

test "describeUiError returns null for unknown errors" {
    try testing.expectEqual(@as(?[]const u8, null), describeUiError(error.Unexpected));
}

test "describeUiError covers core OS + network cases" {
    try testing.expect(describeUiError(error.FileNotFound) != null);
    try testing.expect(describeUiError(error.AccessDenied) != null);
    try testing.expect(describeUiError(error.OutOfMemory) != null);
    try testing.expect(describeUiError(error.ConnectionRefused) != null);
    // 413 request-too-large gets a non-null actionable hint.
    try testing.expect(describeUiError(error.RequestTooLarge) != null);
}

test "describeUiError surfaces a CA-bundle / proxy hint for SSL errors" {
    const hint = describeUiError(error.SslError) orelse return error.TestUnexpectedResult;
    // Mentions a CA bundle env var so the user can point curl at a corporate CA.
    try testing.expect(std.mem.indexOf(u8, hint, "CURL_CA_BUNDLE") != null or
        std.mem.indexOf(u8, hint, "SSL_CERT_FILE") != null);
}

test "formatUiError appends a hint when available" {
    const alloc = testing.allocator;
    const msg = try formatUiError(alloc, "load failed", error.FileNotFound);
    defer alloc.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "load failed") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "FileNotFound") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "file not found") != null);
}

test "formatUiError omits hint when error is unknown" {
    const alloc = testing.allocator;
    const msg = try formatUiError(alloc, "load failed", error.Unexpected);
    defer alloc.free(msg);
    // No em-dash between errorName and the hint when no hint exists.
    try testing.expect(std.mem.indexOf(u8, msg, " — ") == null);
}
