//! At-mention from the IDE (ide-integration-05).
//!
//! Handles the inbound `at_mentioned` notification the IDE extension pushes
//! over the outbound MCP client (mcp/ide_client.zig). The user clicks "Add to
//! Claude" (or selects a range) in the editor and the extension sends
//! `{ method:"at_mentioned", params:{ filePath, lineStart?, lineEnd? } }`. We
//! convert the editor's 0-based line numbers to 1-based, then build the same
//! prompt fragment the locally-typed `@path` produces by routing through
//! `core/at_file_refs.zig` -- so an IDE-pushed mention and a typed `@file`
//! are byte-for-byte identical in the request (single source of truth for the
//! file-block format). We also emit the `tengu_ext_at_mentioned` analytics
//! event so downstream parity tooling lines up with the reference.
//!
//! Reference (claude-code-main/src/hooks/useIdeAtMentioned.ts):
//!   :18    AtMentionedSchema =
//!            { method:"at_mentioned", params:{ filePath, lineStart?, lineEnd? } }
//!   :57-61 0->1-based conversion:
//!            lineStart = data.lineStart + 1 (when defined),
//!            lineEnd   = data.lineEnd   + 1 (when defined).
//!          A present-but-zero lineStart:0 becomes 1 (correct); an absent
//!          field stays absent (null).
//!   PromptInput.tsx:1284 logs `tengu_ext_at_mentioned`.

const std = @import("std");
const at_file_refs = @import("at_file_refs.zig");
const metrics = @import("metrics.zig");

/// Metric name for the at-mention analytics event. zcode models analytics as
/// Prometheus-style counters (core/metrics.zig); this mirrors the reference's
/// `tengu_ext_at_mentioned` event so parity tooling can correlate the two.
pub const EVENT_NAME = "tengu_ext_at_mentioned";

/// A parsed `at_mentioned` notification.
///
///   - `file_path`: the file the IDE wants mentioned (owned, freed by deinit).
///   - `line_start` / `line_end`: 1-based line numbers AFTER the 0->1
///     conversion, or null when the editor did not send them. A whole-file
///     mention (no range) carries both nulls.
pub const AtMention = struct {
    file_path: []u8,
    line_start: ?i64,
    line_end: ?i64,

    pub fn deinit(self: *AtMention, allocator: std.mem.Allocator) void {
        allocator.free(self.file_path);
    }
};

/// Parse an `at_mentioned` notification's `params` JSON into an `AtMention`,
/// applying the 0->1-based line conversion.
///
/// Returns `error.InvalidAtMention` on JSON parse failure or when `filePath`
/// is missing / not a string (the reference schema requires it). The +1
/// conversion is applied only to fields that are actually present -- an
/// absent `lineStart` stays null, a present `lineStart:0` becomes 1.
pub fn parseAtMentioned(
    allocator: std.mem.Allocator,
    params_json: []const u8,
) !AtMention {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, params_json, .{}) catch
        return error.InvalidAtMention;
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidAtMention;
    const params = parsed.value.object;

    const file_path = optString(params.get("filePath")) orelse return error.InvalidAtMention;

    return AtMention{
        .file_path = try allocator.dupe(u8, file_path),
        .line_start = plusOne(asInt(params.get("lineStart"))),
        .line_end = plusOne(asInt(params.get("lineEnd"))),
    };
}

/// Build the prompt fragment an `AtMention` injects, reusing the exact
/// `@path` expansion path so an IDE-pushed mention is identical to a typed
/// `@file`. `cwd` is the workspace root the mention's path is resolved
/// against (the same root the typed-`@file` path uses).
///
/// Returns an owned slice with the `<file path="...">...</file>` block
/// followed by the trailing `@path` marker, exactly as `at_file_refs.expand`
/// emits for the same reference. Returns null when the file does not resolve
/// inside the workspace or could not be read (mirrors `expand` skipping it),
/// so the caller falls back to the raw mention text.
///
/// Note: `at_file_refs` keys off the relative `@path` token. For an
/// absolute path the IDE sends, we hand the path to `expand` after the `@`
/// and let `expand`'s inside-workspace resolution decide -- absolute paths
/// outside `cwd` are dropped there, matching the typed-`@file` policy.
pub fn buildPromptFragment(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    mention: AtMention,
) !?[]u8 {
    // Prefix the mentioned path with `@` so it flows through the identical
    // collection + expansion logic the locally-typed `@file` uses. This is the
    // single source of truth for the file-block format -- we never re-render
    // file blocks here, avoiding two divergent formats.
    const prompt = try std.mem.concat(allocator, u8, &.{ "@", mention.file_path });
    defer allocator.free(prompt);

    var exp = try at_file_refs.expand(allocator, cwd, prompt);
    defer exp.deinit(allocator);

    if (exp.rewritten == null or exp.expanded_count == 0) return null;
    // `rewritten` is freed by `exp.deinit`, so hand back an owned copy.
    return try allocator.dupe(u8, exp.rewritten.?);
}

/// Emit the `tengu_ext_at_mentioned` analytics event. zcode has no GrowthBook
/// / event pipeline like the reference; analytics are Prometheus counters
/// (core/metrics.zig), so this increments a named counter. Safe to call from
/// any thread.
pub fn logAtMentionedEvent() void {
    metrics.globalMetrics().increment(EVENT_NAME);
}

// -- helpers ----------------------------------------------------------------

fn optString(v: ?std.json.Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// Coerce a JSON number to i64 (integer or float). Null if absent / not
/// numeric.
fn asInt(v: ?std.json.Value) ?i64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

/// Apply the reference's 0->1-based conversion: defined -> +1, absent -> null.
fn plusOne(v: ?i64) ?i64 {
    const n = v orelse return null;
    return n + 1;
}

// -- Tests ------------------------------------------------------------------

const testing = std.testing;

test "parseAtMentioned converts 0-based lines to 1-based" {
    const json = "{\"filePath\":\"a.zig\",\"lineStart\":4,\"lineEnd\":9}";
    var m = try parseAtMentioned(testing.allocator, json);
    defer m.deinit(testing.allocator);
    try testing.expectEqualStrings("a.zig", m.file_path);
    try testing.expectEqual(@as(?i64, 5), m.line_start);
    try testing.expectEqual(@as(?i64, 10), m.line_end);
}

test "parseAtMentioned preserves nulls when line numbers absent" {
    const json = "{\"filePath\":\"a.zig\"}";
    var m = try parseAtMentioned(testing.allocator, json);
    defer m.deinit(testing.allocator);
    try testing.expectEqualStrings("a.zig", m.file_path);
    try testing.expectEqual(@as(?i64, null), m.line_start);
    try testing.expectEqual(@as(?i64, null), m.line_end);
}

test "parseAtMentioned: present-but-zero lineStart becomes 1" {
    const json = "{\"filePath\":\"a.zig\",\"lineStart\":0}";
    var m = try parseAtMentioned(testing.allocator, json);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(?i64, 1), m.line_start);
    try testing.expectEqual(@as(?i64, null), m.line_end);
}

test "parseAtMentioned requires filePath" {
    try testing.expectError(
        error.InvalidAtMention,
        parseAtMentioned(testing.allocator, "{\"lineStart\":1}"),
    );
}

test "parseAtMentioned surfaces InvalidAtMention on bad JSON" {
    try testing.expectError(
        error.InvalidAtMention,
        parseAtMentioned(testing.allocator, "not json"),
    );
}

test "buildPromptFragment matches at_file_refs expansion for the same @path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rt = @import("zcode_runtime");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "mention.zig",
        .data = "pub fn main() void {}\n",
    });
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // The fragment an at-mention builds for "mention.zig"...
    var mention = AtMention{
        .file_path = try testing.allocator.dupe(u8, "mention.zig"),
        .line_start = null,
        .line_end = null,
    };
    defer mention.deinit(testing.allocator);
    const frag = (try buildPromptFragment(testing.allocator, cwd, mention)).?;
    defer testing.allocator.free(frag);

    // ...must equal what the locally-typed `@mention.zig` produces.
    var exp = try at_file_refs.expand(testing.allocator, cwd, "@mention.zig");
    defer exp.deinit(testing.allocator);
    try testing.expectEqualStrings(exp.rewritten.?, frag);
    // And it must actually inline the file contents.
    try testing.expect(std.mem.indexOf(u8, frag, "pub fn main") != null);
    try testing.expect(std.mem.indexOf(u8, frag, "<file path=\"mention.zig\">") != null);
}

test "buildPromptFragment returns null for a file outside the workspace" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    var mention = AtMention{
        .file_path = try testing.allocator.dupe(u8, "does-not-exist.zig"),
        .line_start = null,
        .line_end = null,
    };
    defer mention.deinit(testing.allocator);
    const frag = try buildPromptFragment(testing.allocator, cwd, mention);
    try testing.expect(frag == null);
}

test "logAtMentionedEvent increments the tengu_ext_at_mentioned counter" {
    const before = metrics.globalMetrics().getCounter(EVENT_NAME);
    logAtMentionedEvent();
    const after = metrics.globalMetrics().getCounter(EVENT_NAME);
    try testing.expectEqual(before + 1, after);
}
