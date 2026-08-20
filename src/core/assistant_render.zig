//! Shared helpers that clean the model's user-facing text before
//! either the REPL transcript or the one-shot stdout writer emits
//! it. Local models (Qwen3.x, minimax, etc.) embed tool-call JSON
//! envelopes inline with narration - the protocol parser extracts
//! the tool_call for execution, but the raw JSON substring can
//! survive in the final assistant_text when the envelope shape
//! doesn't match any of the parser's fast paths.
//!
//! Three patterns we strip:
//!   1. Bare JSON objects or arrays that look like tool-call
//!      envelopes (`"tool_calls"`, `"tool_call"`, `"name"+"args"`,
//!      `"assistant"+"tool_calls"`). Balanced-bracket scan with
//!      string-aware depth tracking so embedded brackets inside
//!      JSON string values don't confuse the extractor.
//!   2. Markdown fenced blocks (```json / ```tool_call / ```) whose
//!      body matches the same envelope signatures.
//!   3. A post-strip "pure protocol" check: if the remaining
//!      content is a valid JSON object or array with no surrounding
//!      prose, return an empty string so the caller renders
//!      nothing. The tool card above already showed the interesting
//!      information.
//!
//! Reference project (Claude Code) doesn't need this because the
//! Anthropic API splits tool_use content blocks from text content
//! blocks before they reach the UI. We reconstruct the same clean
//! surface here for model backends that emit both in-line.

const std = @import("std");
const std_io = @import("std_io.zig");

/// Strip tool-call envelopes from `text`. Caller owns the returned
/// slice. When the input was pure protocol bytes with no prose, the
/// returned slice is empty (length 0) and callers should suppress
/// the output entirely.
pub fn cleanAssistantText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const stripped = try stripEnvelopes(allocator, text);
    errdefer allocator.free(stripped);

    const trimmed_right = std.mem.trimEnd(u8, stripped, "\r\n");
    const content = std.mem.trim(u8, trimmed_right, " \t\r\n");
    if (content.len == 0) {
        allocator.free(stripped);
        return allocator.alloc(u8, 0);
    }

    // Pure-protocol safety net: if what's left is a single valid
    // JSON object or array with no surrounding prose, the model
    // emitted only protocol bytes for this turn. Drop it.
    if (content[0] == '{' or content[0] == '[') {
        var probe = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
            // Not valid JSON - keep as-is.
            return stripped;
        };
        probe.deinit();
        allocator.free(stripped);
        return allocator.alloc(u8, 0);
    }
    return stripped;
}

fn stripEnvelopes(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < text.len) {
        // Markdown fenced code block wrapping a tool-call envelope.
        if (i + 3 <= text.len and std.mem.eql(u8, text[i..][0..3], "```")) {
            const close_search_start = i + 3;
            if (std.mem.indexOfPos(u8, text, close_search_start, "```")) |close_start| {
                const inside = text[close_search_start..close_start];
                const nl = std.mem.indexOfScalar(u8, inside, '\n') orelse inside.len;
                const lang = std.mem.trim(u8, inside[0..nl], " \t\r");
                const body_start = if (nl < inside.len) nl + 1 else inside.len;
                const body = std.mem.trim(u8, inside[body_start..], " \t\r\n");
                const lang_ok = std.mem.eql(u8, lang, "json") or
                    std.mem.eql(u8, lang, "tool_call") or
                    std.mem.eql(u8, lang, "tool") or
                    lang.len == 0;
                const body_is_envelope = (body.len > 0 and (body[0] == '{' or body[0] == '[')) and bodyLooksLikeEnvelope(body);
                if (lang_ok and body_is_envelope) {
                    i = close_start + 3;
                    if (i < text.len and text[i] == '\n') i += 1;
                    continue;
                }
            }
        }

        if (text[i] == '{' or text[i] == '[') {
            const probe_end = @min(text.len, i + 256);
            const probe = text[i..probe_end];
            if (probeLooksLikeEnvelope(probe)) {
                const open = text[i];
                const close: u8 = if (open == '{') '}' else ']';
                if (findBalancedEnd(text, i, open, close)) |end| {
                    i = end;
                    if (i < text.len and text[i] == '\n') i += 1;
                    continue;
                }
            }
        }
        try out.append(text[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

fn probeLooksLikeEnvelope(probe: []const u8) bool {
    if (std.mem.indexOf(u8, probe, "\"tool_calls\"") != null) return true;
    if (std.mem.indexOf(u8, probe, "\"tool_call\"") != null) return true;
    if (std.mem.indexOf(u8, probe, "\"assistant\"") != null and
        std.mem.indexOf(u8, probe, "\"tool_calls\"") != null) return true;
    if (std.mem.indexOf(u8, probe, "\"name\"") != null and
        std.mem.indexOf(u8, probe, "\"args\"") != null) return true;
    // Qwen "keep going" signal with no tool call:
    //   {"tool_calls":[],"control":{"continue":true}}
    if (std.mem.indexOf(u8, probe, "\"control\"") != null and
        std.mem.indexOf(u8, probe, "\"continue\"") != null) return true;
    return false;
}

fn bodyLooksLikeEnvelope(body: []const u8) bool {
    return probeLooksLikeEnvelope(body);
}

/// Generic balanced-bracket scan. `open`/`close` = `{`/`}` or
/// `[`/`]`. Strings honor backslash escapes so embedded brackets
/// inside JSON string values don't throw off the depth counter.
pub fn findBalancedEnd(text: []const u8, start: usize, open: u8, close: u8) ?usize {
    var depth: usize = 0;
    var in_string = false;
    var i = start;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string) {
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (c == '"') in_string = false;
            continue;
        }
        if (c == '"') {
            in_string = true;
            continue;
        }
        if (c == open) {
            depth += 1;
        } else if (c == close) {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return i + 1;
        }
    }
    return null;
}

// --- Tests ------------------------------------------------------------

const testing = std.testing;

test "cleanAssistantText strips {\"tool_calls\":...} envelope" {
    const input = "Sure, let me check.\n{\"tool_calls\":[{\"name\":\"Bash\",\"args\":\"echo hi\"}]}\nDone.";
    const out = try cleanAssistantText(testing.allocator, input);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "tool_calls") == null);
    try testing.expect(std.mem.indexOf(u8, out, "Sure, let me check.") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Done.") != null);
}

test "cleanAssistantText suppresses pure JSON bubbles" {
    const input = "  {\"tool_calls\":[{\"name\":\"Bash\",\"args\":\"ls\"}]}  ";
    const out = try cleanAssistantText(testing.allocator, input);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "cleanAssistantText strips markdown-fenced envelope" {
    const input = "Here you go:\n```json\n{\"tool_calls\":[{\"name\":\"X\",\"args\":\"y\"}]}\n```\nAll set.";
    const out = try cleanAssistantText(testing.allocator, input);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "tool_calls") == null);
    try testing.expect(std.mem.indexOf(u8, out, "Here you go:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "All set.") != null);
}

test "cleanAssistantText leaves ordinary prose intact" {
    const input = "The answer is 42.";
    const out = try cleanAssistantText(testing.allocator, input);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("The answer is 42.", out);
}

test "cleanAssistantText strips Qwen control:continue continuation" {
    // Qwen local models emit this to signal "keep going" with no
    // tool call. The tool_calls array is empty.
    const input = "I'll analyze the WiFi list.\n{\"tool_calls\":[],\"control\":{\"continue\":true}}\n";
    const out = try cleanAssistantText(testing.allocator, input);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "tool_calls") == null);
    try testing.expect(std.mem.indexOf(u8, out, "control") == null);
    try testing.expect(std.mem.indexOf(u8, out, "continue") == null);
    try testing.expect(std.mem.indexOf(u8, out, "I'll analyze") != null);
}
