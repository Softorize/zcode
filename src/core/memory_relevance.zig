//! LLM relevance selection layer for persistent memory (memory-03).
//!
//! An OPTIONAL Sonnet-backed selector layered ON TOP OF the deterministic
//! keyword scorer in memory.zig (`renderRelevantForPrompt`). It never replaces
//! that scorer: the deterministic path stays the default for offline / mock
//! providers and air-gapped use, and this selector is best-effort behind
//! `policy.allow_network`. On any error or empty result the caller falls back
//! to the deterministic renderer.
//!
//! Ported from claude-code-main/src/memdir/findRelevantMemories.ts:39-141 and
//! memoryScan.ts:35-95:
//!   scanMemoryFiles / formatMemoryManifest  -> memory.zig (shared with Task 5)
//!   sideQuery selection over the manifest    -> selectRelevant below
//!   alreadySurfaced exclusion set            -> filterManifestHeaders below
//!   recently-used-tool exclusion heuristic   -> isRecentlyUsedToolDoc below
//!
//! Design note (why a callback, not a direct callModel import): the per-turn
//! prompt assembly path (prompt_engine.build) deliberately never fires a model
//! call -- see the comment at prompt_engine.zig:92-99 where the auto-compaction
//! summarizer is passed `null` for exactly the same latency reason. To keep
//! this selector usable from a place that DOES have a provider handle (the
//! agent runtime) without dragging an upward import into core/, the model call
//! is injected as a function pointer. That also makes the selector fully
//! unit-testable with a stub callback (no provider, no network) which is what
//! the acceptance tests below exercise.

const std = @import("std");
const memory = @import("memory.zig");
const std_io = @import("std_io.zig");

/// JSON schema for the structured response: an object with a single
/// `selected_memories` string array. Embedded verbatim into the request body
/// via providers/common.appendResponseSchemaToBody (or
/// types.ModelRequest.response_schema). additionalProperties:false keeps the
/// model from inventing extra keys.
pub const SELECTED_MEMORIES_SCHEMA =
    \\{"type":"object","properties":{"selected_memories":{"type":"array","items":{"type":"string"}}},"required":["selected_memories"],"additionalProperties":false}
;

/// The maximum number of memory files the selector returns. The reference
/// caps the side-query selection at 5; the deterministic fallback is raised
/// to 5 to match at the wiring site.
pub const MAX_SELECTED: usize = 5;

/// System prompt for the selection side-query. Ported in spirit from
/// SELECT_MEMORIES_SYSTEM_PROMPT. No long dashes (project rule).
pub const SELECT_MEMORIES_SYSTEM_PROMPT =
    "You are a memory relevance selector. You are given a user query and a list of available memory files, " ++
    "one per line, each with an optional [type] tag, a filename, an ISO timestamp, and a short description. " ++
    "Select ONLY the memory files whose content is directly relevant to answering the current query. " ++
    "Prefer warnings, gotchas, and durable preferences. Skip API reference docs for tools the user is not asking about. " ++
    "Return at most " ++ "5" ++ " filenames. " ++
    "Respond with strict JSON: an object {\"selected_memories\": [\"file-a.md\", \"file-b.md\"]} listing the chosen filenames. " ++
    "If nothing is relevant, return an empty array.";

/// The model-call callback injected by the caller. `ctx` is the caller's
/// opaque state (e.g. the AgentRuntime). The callback runs ONE structured
/// side-query: it receives the system prompt, the user message, and the
/// response JSON schema, and must return the model's textual response
/// (expected to be a JSON object matching the schema) allocated with
/// `allocator`. The selector frees the returned slice. The callback may
/// return any error; the selector treats every error as "fall back to the
/// deterministic path" and never panics.
pub const ModelCallFn = *const fn (
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    system_prompt: []const u8,
    user_message: []const u8,
    response_schema: []const u8,
) anyerror![]u8;

/// Build the user message for the side-query: the query, the filtered
/// manifest, and (when present) the recently-used-tools line. Caller owns the
/// returned slice.
pub fn buildUserMessage(
    allocator: std.mem.Allocator,
    query: []const u8,
    manifest: []const u8,
    recently_used_tools: []const []const u8,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    try out.writer().print("Query: {s}\n\nAvailable memories:\n{s}", .{ query, manifest });

    if (recently_used_tools.len > 0) {
        try out.writer().writeAll("\nRecently used tools: ");
        for (recently_used_tools, 0..) |tool, idx| {
            if (idx > 0) try out.writer().writeAll(", ");
            try out.writer().writeAll(tool);
        }
        try out.writer().writeByte('\n');
    }

    return out.toOwnedSlice();
}

/// Filter scanned headers before formatting the manifest:
///   1. Drop any header in `already_surfaced` (a set of filenames already
///      injected this session -- the reference's alreadySurfaced set).
///   2. Drop reference/API-doc shaped headers that merely name a
///      recently-used tool, UNLESS the description carries warning/gotcha
///      words (those are kept regardless).
/// Returns an owned slice of borrowed header copies (the MemoryHeader fields
/// still alias the input headers' allocations -- caller must keep the input
/// alive; only the outer slice is owned and freed by the caller).
pub fn filterManifestHeaders(
    allocator: std.mem.Allocator,
    headers: []const memory.MemoryHeader,
    already_surfaced: *const std.StringHashMap(void),
    recently_used_tools: []const []const u8,
) ![]memory.MemoryHeader {
    var kept = std.array_list.Managed(memory.MemoryHeader).init(allocator);
    errdefer kept.deinit();

    for (headers) |h| {
        if (already_surfaced.contains(h.filename)) continue;
        if (isRecentlyUsedToolDoc(h, recently_used_tools)) continue;
        try kept.append(h);
    }

    return kept.toOwnedSlice();
}

/// Heuristic for the recently-used-tool exclusion. Returns true when the
/// header is a reference/API-doc shaped memory naming a recently-used tool
/// AND it does NOT carry warning/gotcha words. Minimal port of the
/// reference's richer telemetry-driven signal (see the phase plan's deferred
/// note): the only "type" we treat as API-doc-shaped is `reference`.
pub fn isRecentlyUsedToolDoc(
    header: memory.MemoryHeader,
    recently_used_tools: []const []const u8,
) bool {
    if (recently_used_tools.len == 0) return false;
    // Only reference-typed docs are eligible for tool-doc exclusion.
    if (!std.ascii.eqlIgnoreCase(header.mem_type, "reference")) return false;

    // Warnings/gotchas are always kept regardless of tool naming.
    if (containsAnyIgnoreCase(header.description, &.{ "warning", "gotcha", "footgun", "caveat", "pitfall", "do not", "avoid" })) {
        return false;
    }

    // Drop only when the filename or description names a recently-used tool.
    for (recently_used_tools) |tool| {
        if (tool.len == 0) continue;
        if (containsIgnoreCase(header.filename, tool) or containsIgnoreCase(header.description, tool)) {
            return true;
        }
    }
    return false;
}

/// Run the selection side-query and return up to MAX_SELECTED filenames that
/// the model chose AND that exist in `headers`. Best-effort: returns an empty
/// slice (never an error) when the callback errors, the JSON is malformed, or
/// nothing matched -- the caller then falls back to the deterministic
/// renderer. Caller owns the returned slice and each filename in it.
pub fn selectRelevant(
    allocator: std.mem.Allocator,
    ctx: *anyopaque,
    call: ModelCallFn,
    query: []const u8,
    headers: []const memory.MemoryHeader,
    already_surfaced: *const std.StringHashMap(void),
    recently_used_tools: []const []const u8,
) ![][]u8 {
    if (headers.len == 0) return allocator.alloc([]u8, 0);

    const filtered = try filterManifestHeaders(allocator, headers, already_surfaced, recently_used_tools);
    defer allocator.free(filtered);
    if (filtered.len == 0) return allocator.alloc([]u8, 0);

    const manifest = try memory.formatMemoryManifest(allocator, filtered);
    defer allocator.free(manifest);

    const user_message = try buildUserMessage(allocator, query, manifest, recently_used_tools);
    defer allocator.free(user_message);

    // Best-effort model call: any error means "use the deterministic path".
    const response = call(ctx, allocator, SELECT_MEMORIES_SYSTEM_PROMPT, user_message, SELECTED_MEMORIES_SCHEMA) catch {
        return allocator.alloc([]u8, 0);
    };
    defer allocator.free(response);

    return parseSelection(allocator, response, filtered);
}

/// Parse the `{ "selected_memories": [...] }` JSON, keep only names that
/// match a header in `valid_headers`, cap at MAX_SELECTED. Tolerates a
/// plain-text JSON blob with surrounding noise by scanning for the first
/// `{`. Never errors on malformed input -- returns an empty slice instead.
fn parseSelection(
    allocator: std.mem.Allocator,
    response: []const u8,
    valid_headers: []const memory.MemoryHeader,
) ![][]u8 {
    const json_start = std.mem.indexOfScalar(u8, response, '{') orelse return allocator.alloc([]u8, 0);
    // Extract just the balanced top-level object so trailing prose after the
    // closing brace ("...} thanks") does not trip the strict end-of-document
    // check. Brace counting ignores braces inside JSON strings (and escaped
    // quotes). If we cannot find a balanced object, fall back to the rest of
    // the buffer and let the parser reject it.
    const json_text = extractFirstJsonObject(response[json_start..]) orelse response[json_start..];

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch {
        return allocator.alloc([]u8, 0);
    };
    defer parsed.deinit();

    if (parsed.value != .object) return allocator.alloc([]u8, 0);
    const sel = parsed.value.object.get("selected_memories") orelse return allocator.alloc([]u8, 0);
    if (sel != .array) return allocator.alloc([]u8, 0);

    var out = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit();
    }

    for (sel.array.items) |item| {
        if (out.items.len >= MAX_SELECTED) break;
        if (item != .string) continue;
        const name = item.string;
        // Only accept names that correspond to a real scanned header, so a
        // hallucinated filename never reaches the prompt or a file read.
        if (!headerExists(valid_headers, name)) continue;
        // Dedupe.
        if (containsName(out.items, name)) continue;
        try out.append(try allocator.dupe(u8, name));
    }

    return out.toOwnedSlice();
}

/// Return the substring spanning the first balanced top-level `{...}` object
/// in `s` (which must begin at or before the first `{`), or null if no
/// balanced object closes. Braces inside JSON strings are ignored, with
/// backslash escapes honored so a `}` or `"` inside a string value does not
/// throw off the count.
fn extractFirstJsonObject(s: []const u8) ?[]const u8 {
    const start = std.mem.indexOfScalar(u8, s, '{') orelse return null;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    var i = start;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return s[start .. i + 1];
            },
            else => {},
        }
    }
    return null;
}

fn headerExists(headers: []const memory.MemoryHeader, name: []const u8) bool {
    for (headers) |h| {
        if (std.mem.eql(u8, h.filename, name)) return true;
    }
    return false;
}

fn containsName(names: []const []u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

const containsIgnoreCase = @import("parse_helpers.zig").containsIgnoreCase;

fn containsAnyIgnoreCase(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (containsIgnoreCase(haystack, needle)) return true;
    }
    return false;
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

// A stub ModelCallFn that returns a canned JSON response.
const CannedCtx = struct {
    response: []const u8,
};

fn cannedCall(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    system_prompt: []const u8,
    user_message: []const u8,
    response_schema: []const u8,
) anyerror![]u8 {
    _ = system_prompt;
    _ = user_message;
    _ = response_schema;
    const self: *CannedCtx = @ptrCast(@alignCast(ctx));
    return allocator.dupe(u8, self.response);
}

// A stub ModelCallFn that always errors (simulates a failing provider).
fn failingCall(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    system_prompt: []const u8,
    user_message: []const u8,
    response_schema: []const u8,
) anyerror![]u8 {
    _ = ctx;
    _ = allocator;
    _ = system_prompt;
    _ = user_message;
    _ = response_schema;
    return error.ProviderUnavailable;
}

fn makeHeader(
    allocator: std.mem.Allocator,
    filename: []const u8,
    mem_type: []const u8,
    description: []const u8,
) !memory.MemoryHeader {
    return .{
        .filename = try allocator.dupe(u8, filename),
        .mem_type = try allocator.dupe(u8, mem_type),
        .description = try allocator.dupe(u8, description),
        .mtime_ns = 0,
    };
}

fn freeHeaders(allocator: std.mem.Allocator, headers: []memory.MemoryHeader) void {
    for (headers) |*h| h.deinit(allocator);
}

test "buildUserMessage includes the query, manifest, and recent tools" {
    const a = testing.allocator;
    const msg = try buildUserMessage(a, "how do I build", "- foo.md (ts): bar\n", &.{ "Read", "Bash" });
    defer a.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "Query: how do I build") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "Available memories:") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "- foo.md (ts): bar") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "Recently used tools: Read, Bash") != null);
}

test "selectRelevant returns the model's chosen, validated filenames" {
    const a = testing.allocator;
    var headers = [_]memory.MemoryHeader{
        try makeHeader(a, "style.md", "feedback", "writing style"),
        try makeHeader(a, "runtime.md", "project", "the agent runtime"),
    };
    defer freeHeaders(a, &headers);

    var surfaced = std.StringHashMap(void).init(a);
    defer surfaced.deinit();

    // The model picks runtime.md and a hallucinated name (must be dropped).
    var ctx = CannedCtx{ .response = "{\"selected_memories\":[\"runtime.md\",\"does-not-exist.md\"]}" };
    const selected = try selectRelevant(a, &ctx, cannedCall, "fix the runtime", &headers, &surfaced, &.{});
    defer {
        for (selected) |s| a.free(s);
        a.free(selected);
    }

    try testing.expectEqual(@as(usize, 1), selected.len);
    try testing.expectEqualStrings("runtime.md", selected[0]);
}

test "selectRelevant falls back (empty result) when the model call errors" {
    const a = testing.allocator;
    var headers = [_]memory.MemoryHeader{
        try makeHeader(a, "style.md", "feedback", "writing style"),
    };
    defer freeHeaders(a, &headers);

    var surfaced = std.StringHashMap(void).init(a);
    defer surfaced.deinit();

    var dummy: u8 = 0;
    const selected = try selectRelevant(a, @ptrCast(&dummy), failingCall, "anything", &headers, &surfaced, &.{});
    defer a.free(selected);

    // Never panics; returns empty so the caller uses the deterministic path.
    try testing.expectEqual(@as(usize, 0), selected.len);
}

test "selectRelevant tolerates malformed JSON and surrounding noise" {
    const a = testing.allocator;
    var headers = [_]memory.MemoryHeader{
        try makeHeader(a, "runtime.md", "project", "the agent runtime"),
    };
    defer freeHeaders(a, &headers);

    var surfaced = std.StringHashMap(void).init(a);
    defer surfaced.deinit();

    // Leading prose before the JSON object is tolerated (scan to first '{').
    var ctx = CannedCtx{ .response = "Here you go: {\"selected_memories\":[\"runtime.md\"]} thanks" };
    const selected = try selectRelevant(a, &ctx, cannedCall, "runtime", &headers, &surfaced, &.{});
    defer {
        for (selected) |s| a.free(s);
        a.free(selected);
    }
    try testing.expectEqual(@as(usize, 1), selected.len);
    try testing.expectEqualStrings("runtime.md", selected[0]);

    // Pure garbage -> empty, no panic.
    var bad = CannedCtx{ .response = "not json at all" };
    const empty = try selectRelevant(a, &bad, cannedCall, "x", &headers, &surfaced, &.{});
    defer a.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}

test "alreadySurfaced filters a header out before the model sees it" {
    const a = testing.allocator;
    var headers = [_]memory.MemoryHeader{
        try makeHeader(a, "style.md", "feedback", "writing style"),
        try makeHeader(a, "runtime.md", "project", "the agent runtime"),
    };
    defer freeHeaders(a, &headers);

    var surfaced = std.StringHashMap(void).init(a);
    defer surfaced.deinit();
    try surfaced.put("runtime.md", {});

    const filtered = try filterManifestHeaders(a, &headers, &surfaced, &.{});
    defer a.free(filtered);

    try testing.expectEqual(@as(usize, 1), filtered.len);
    try testing.expectEqualStrings("style.md", filtered[0].filename);

    // And even if the model returns the surfaced name, selectRelevant must not
    // include it (it was removed from the manifest / valid set).
    var ctx = CannedCtx{ .response = "{\"selected_memories\":[\"runtime.md\",\"style.md\"]}" };
    const selected = try selectRelevant(a, &ctx, cannedCall, "anything", &headers, &surfaced, &.{});
    defer {
        for (selected) |s| a.free(s);
        a.free(selected);
    }
    try testing.expectEqual(@as(usize, 1), selected.len);
    try testing.expectEqualStrings("style.md", selected[0]);
}

test "recently-used-tool reference docs are dropped unless they warn" {
    const a = testing.allocator;
    var plain_doc = try makeHeader(a, "bash-api.md", "reference", "how to use the Bash tool");
    defer plain_doc.deinit(a);
    var warn_doc = try makeHeader(a, "bash-gotcha.md", "reference", "Bash gotcha: kill reaps the child");
    defer warn_doc.deinit(a);
    var feedback_doc = try makeHeader(a, "prefs.md", "feedback", "prefers Bash over make");
    defer feedback_doc.deinit(a);

    const recent = [_][]const u8{"Bash"};

    // Plain reference doc naming a recently-used tool -> dropped.
    try testing.expect(isRecentlyUsedToolDoc(plain_doc, &recent));
    // Warning/gotcha reference doc -> kept even though it names the tool.
    try testing.expect(!isRecentlyUsedToolDoc(warn_doc, &recent));
    // Non-reference (feedback) doc -> always kept.
    try testing.expect(!isRecentlyUsedToolDoc(feedback_doc, &recent));
    // No recent tools -> nothing dropped.
    try testing.expect(!isRecentlyUsedToolDoc(plain_doc, &.{}));
}

test "selectRelevant caps at MAX_SELECTED" {
    const a = testing.allocator;
    var headers = [_]memory.MemoryHeader{
        try makeHeader(a, "a.md", "user", "a"),
        try makeHeader(a, "b.md", "user", "b"),
        try makeHeader(a, "c.md", "user", "c"),
        try makeHeader(a, "d.md", "user", "d"),
        try makeHeader(a, "e.md", "user", "e"),
        try makeHeader(a, "f.md", "user", "f"),
    };
    defer freeHeaders(a, &headers);

    var surfaced = std.StringHashMap(void).init(a);
    defer surfaced.deinit();

    var ctx = CannedCtx{ .response = "{\"selected_memories\":[\"a.md\",\"b.md\",\"c.md\",\"d.md\",\"e.md\",\"f.md\"]}" };
    const selected = try selectRelevant(a, &ctx, cannedCall, "all", &headers, &surfaced, &.{});
    defer {
        for (selected) |s| a.free(s);
        a.free(selected);
    }
    try testing.expectEqual(MAX_SELECTED, selected.len);
}
