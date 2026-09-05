//! hooks-permissions-11: per-tool permission-rule content validation.
//!
//! Mirrors the reference's `customValidation` map (consulted whenever a rule
//! is added via `/permissions`, `--allowedTools`/`--disallowedTools`, or
//! settings.json) for the two tools it validates: WebFetch (must use a
//! `domain:` prefix, not a URL) and WebSearch (no glob wildcards -- it is a
//! free-text query, not a path pattern). Every other tool has no content
//! validator here, matching the reference's exact two-entry map.
//!
//! Pure module: a string in, an optional static error message out. No
//! allocation, no IO.

const std = @import("std");

pub const ValidationError = struct {
    /// User-facing rejection message, including a corrective suggestion.
    message: []const u8,
};

/// Validate `content` (the `(...)` part of a `Tool(content)` rule, "" for a
/// tool-wide rule) for `tool`. Returns null when the content is acceptable
/// (including every tool this module does not special-case). Only WebFetch
/// and WebSearch are validated, matching the reference's `customValidation`
/// map exactly (verified against the bundle: exactly these two entries).
pub fn validate(tool: []const u8, content: []const u8) ?ValidationError {
    if (std.mem.eql(u8, tool, "WebFetch")) {
        if (content.len == 0) return null; // tool-wide rule: no content to check.
        if (std.mem.indexOf(u8, content, "://") != null or std.mem.startsWith(u8, content, "http")) {
            return .{ .message = "WebFetch permissions use domain format, not URLs. Use WebFetch(domain:example.com) instead of a full URL." };
        }
        if (!std.mem.startsWith(u8, content, "domain:")) {
            return .{ .message = "WebFetch permissions must use a \"domain:\" prefix, e.g. WebFetch(domain:example.com) or WebFetch(domain:*.google.com)." };
        }
        return null;
    }
    if (std.mem.eql(u8, tool, "WebSearch")) {
        if (std.mem.indexOfScalar(u8, content, '*') != null or std.mem.indexOfScalar(u8, content, '?') != null) {
            return .{ .message = "WebSearch does not support wildcards. Use plain text, e.g. WebSearch(claude ai)." };
        }
        return null;
    }
    return null;
}

const testing = std.testing;

test "WebFetch rejects a full URL with a domain: suggestion" {
    const err = validate("WebFetch", "https://example.com").?;
    try testing.expect(std.mem.indexOf(u8, err.message, "domain:example.com") != null or std.mem.indexOf(u8, err.message, "URLs") != null);
}

test "WebFetch rejects content missing the domain: prefix" {
    const err = validate("WebFetch", "example.com").?;
    try testing.expect(std.mem.indexOf(u8, err.message, "domain:") != null);
}

test "WebFetch accepts a well-formed domain rule, including globs and tool-wide" {
    try testing.expect(validate("WebFetch", "domain:example.com") == null);
    try testing.expect(validate("WebFetch", "domain:*.google.com") == null);
    try testing.expect(validate("WebFetch", "") == null);
}

test "WebSearch rejects wildcards but accepts plain text" {
    try testing.expect(validate("WebSearch", "claude*") != null);
    try testing.expect(validate("WebSearch", "clau?e") != null);
    try testing.expect(validate("WebSearch", "claude ai") == null);
    try testing.expect(validate("WebSearch", "") == null);
}

test "every other tool is unvalidated" {
    try testing.expect(validate("Bash", "anything(goes)") == null);
    try testing.expect(validate("Read", "~/.zshrc") == null);
    try testing.expect(validate("*", "") == null);
}
