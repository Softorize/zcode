//! Phase 11 / sessions-03: agentic (LLM-powered) session search.
//!
//! This is the deterministic, network-free core of the feature: a substring
//! pre-filter over each session's metadata + transcript (`logContainsQuery`), a
//! session-list prompt builder, and a tolerant index parser for the model's
//! reply. The actual fast-model call is a thin indirection (`Searcher`) the
//! runtime wires up, mirroring `compaction.Summarizer` so this deep `core/`
//! module never imports the providers tree.
//!
//! Pure pieces in, ranked indices out. The feature is opt-in and layered on top
//! of the deterministic fuzzy path (`core/session_search.zig`); when no provider
//! is available the caller degrades to fuzzy search and never blocks the offline
//! path. Mirrors the reference `utils/agenticSessionSearch.ts`.

const std = @import("std");
const std_io = @import("std_io.zig");
const types = @import("types.zig");
const parse_helpers = @import("parse_helpers.zig");

/// Max chars of transcript excerpt emitted per session (ref MAX_TRANSCRIPT_CHARS).
pub const max_transcript_chars: usize = 2000;
/// Max messages to scan from the start/end of a session (ref MAX_MESSAGES_TO_SCAN).
pub const max_messages_to_scan: usize = 100;
/// Max sessions sent to the model (ref MAX_SESSIONS_TO_SEARCH).
pub const max_sessions_to_search: usize = 100;
/// First-message preview cap in the prompt (ref `firstPrompt.slice(0, 300)`).
pub const max_first_message_chars: usize = 300;

/// The reference inclusive-bias system prompt verbatim (sans em/en dashes).
/// Mirrors `SESSION_SEARCH_SYSTEM_PROMPT` (agenticSessionSearch.ts:15-48).
pub const system_prompt =
    \\Your goal is to find relevant sessions based on a user's search query.
    \\
    \\You will be given a list of sessions with their metadata and a search query. Identify which sessions are most relevant to the query.
    \\
    \\Each session may include:
    \\- Title (display name or custom title)
    \\- Tag (user-assigned category, shown as [tag: name] - users tag sessions with /tag command to categorize them)
    \\- Branch (git branch name, shown as [branch: name])
    \\- Summary (AI-generated summary)
    \\- First message (beginning of the conversation)
    \\- Transcript (excerpt of conversation content)
    \\
    \\IMPORTANT: Tags are user-assigned labels that indicate the session's topic or category. If the query matches a tag exactly or partially, those sessions should be highly prioritized.
    \\
    \\For each session, consider (in order of priority):
    \\1. Exact tag matches (highest priority - user explicitly categorized this session)
    \\2. Partial tag matches or tag-related terms
    \\3. Title matches (custom titles or first message content)
    \\4. Branch name matches
    \\5. Summary and transcript content matches
    \\6. Semantic similarity and related concepts
    \\
    \\CRITICAL: Be VERY inclusive in your matching. Include sessions that:
    \\- Contain the query term anywhere in any field
    \\- Are semantically related to the query (e.g., "testing" matches sessions about "tests", "unit tests", "QA", etc.)
    \\- Discuss topics that could be related to the query
    \\- Have transcripts that mention the concept even in passing
    \\
    \\When in doubt, INCLUDE the session. It's better to return too many results than too few. The user can easily scan through results, but missing relevant sessions is frustrating.
    \\
    \\Return sessions ordered by relevance (most relevant first). If truly no sessions have ANY connection to the query, return an empty array - but this should be rare.
    \\
    \\Respond with ONLY the JSON object, no markdown formatting:
    \\{"relevant_indices": [2, 5, 0]}
;

/// One session's searchable metadata + transcript excerpt. The caller fills
/// this from the store (`readLabel`/`currentTitle`, `readTags`, sessions-07's
/// branch / first-prompt sidecars, `conversation_summary`, and a transcript
/// excerpt built via `extractTranscript`). All slices are borrowed; this struct
/// allocates nothing and is purely a view for the predicate + prompt builder.
pub const SessionMeta = struct {
    /// Display title (custom label, AI title, or id) shown first in the prompt.
    title: []const u8 = "",
    /// User-set custom title, if it differs from `title`. Empty = none.
    custom_title: []const u8 = "",
    /// First user tag, e.g. "refactor". Empty = untagged.
    tag: []const u8 = "",
    /// Git branch the session was started on (sessions-07). Empty = unknown.
    branch: []const u8 = "",
    /// AI/conversation summary. Empty = none.
    summary: []const u8 = "",
    /// First user prompt preview (sessions-07). Empty = none.
    first_prompt: []const u8 = "",
    /// Pre-extracted transcript excerpt (see `extractTranscript`). Empty = not
    /// loaded; the predicate then only searches metadata for this session.
    transcript: []const u8 = "",
};

/// True when `query` (case-insensitive) appears in any searchable field of
/// `meta`. Checks the cheap metadata fields first and the transcript last, like
/// the reference `logContainsQuery` (agenticSessionSearch.ts:113-140). The query
/// is matched case-insensitively via `containsIgnoreCase`, so the caller need
/// not pre-lowercase. An empty query matches nothing (the caller guards the
/// empty-query path separately).
pub fn logContainsQuery(meta: SessionMeta, query: []const u8) bool {
    if (query.len == 0) return false;
    if (parse_helpers.containsIgnoreCase(meta.title, query)) return true;
    if (parse_helpers.containsIgnoreCase(meta.custom_title, query)) return true;
    if (parse_helpers.containsIgnoreCase(meta.tag, query)) return true;
    if (parse_helpers.containsIgnoreCase(meta.branch, query)) return true;
    if (parse_helpers.containsIgnoreCase(meta.summary, query)) return true;
    if (parse_helpers.containsIgnoreCase(meta.first_prompt, query)) return true;
    // Transcript is the most expensive (potentially long) field; check last.
    if (parse_helpers.containsIgnoreCase(meta.transcript, query)) return true;
    return false;
}

/// Build a transcript excerpt from a session's history for the prompt + the
/// predicate. Takes user/assistant turn text from the start and (for long
/// sessions) the end, joins with spaces, collapses runs of whitespace to a
/// single space, and truncates to `max_transcript_chars` (appending an ellipsis
/// byte sequence when truncated). Mirrors the reference `extractTranscript`
/// (agenticSessionSearch.ts:86-108). Pure; the returned slice is freshly
/// allocated and owned by the caller (empty string when there is no text).
pub fn extractTranscript(allocator: std.mem.Allocator, history: []const types.HistoryTurn) ![]u8 {
    if (history.len == 0) return allocator.dupe(u8, "");

    var sb = std_io.StringBuilder.init(allocator);
    defer sb.deinit();
    const w = sb.writer();

    // Track whether we have emitted any non-space char yet (for the joining
    // space) and whether the last byte written was a space (to collapse runs).
    var wrote_any = false;
    var last_was_space = false;

    const Emit = struct {
        fn turnText(
            wr: *std.Io.Writer,
            wrote_any_p: *bool,
            last_was_space_p: *bool,
            turn: types.HistoryTurn,
        ) !void {
            if (turn.role != .user and turn.role != .assistant) return;
            if (turn.content.len == 0) return;
            for (turn.content) |ch| {
                const is_space = ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
                if (is_space) {
                    // Collapse: only remember we saw a space; emit lazily.
                    if (wrote_any_p.*) last_was_space_p.* = true;
                    continue;
                }
                if (last_was_space_p.*) {
                    try wr.writeByte(' ');
                    last_was_space_p.* = false;
                }
                try wr.writeByte(ch);
                wrote_any_p.* = true;
            }
        }
    };

    if (history.len <= max_messages_to_scan) {
        for (history) |turn| try Emit.turnText(w, &wrote_any, &last_was_space, turn);
    } else {
        const half = max_messages_to_scan / 2;
        for (history[0..half]) |turn| try Emit.turnText(w, &wrote_any, &last_was_space, turn);
        for (history[history.len - half ..]) |turn| try Emit.turnText(w, &wrote_any, &last_was_space, turn);
    }

    const full = sb.items();
    if (full.len <= max_transcript_chars) return allocator.dupe(u8, full);

    // Truncate to the cap and append a plain "..." ellipsis (no Unicode
    // ellipsis to keep the prompt ASCII-clean).
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try out.writer().writeAll(full[0..max_transcript_chars]);
    try out.writer().writeAll("...");
    return out.toOwnedSlice();
}

/// Build the session-list block for one entry: `index: title [custom title: ..]
/// [tag: ..] [branch: ..] - Summary: .. - First message: .. - Transcript: ..`.
/// Omits absent fields. The first-message preview is capped at
/// `max_first_message_chars`. Mirrors the per-entry mapping in
/// `agenticSessionSearch.ts:204-245`. Writes into `w`; allocates nothing of its
/// own beyond what the writer needs.
fn writeSessionEntry(w: *std.Io.Writer, index: usize, meta: SessionMeta) !void {
    try w.print("{d}:", .{index});
    if (meta.title.len > 0) try w.print(" {s}", .{meta.title});
    if (meta.custom_title.len > 0 and !std.mem.eql(u8, meta.custom_title, meta.title)) {
        try w.print(" [custom title: {s}]", .{meta.custom_title});
    }
    if (meta.tag.len > 0) try w.print(" [tag: {s}]", .{meta.tag});
    if (meta.branch.len > 0) try w.print(" [branch: {s}]", .{meta.branch});
    if (meta.summary.len > 0) try w.print(" - Summary: {s}", .{meta.summary});
    if (meta.first_prompt.len > 0 and !std.mem.eql(u8, meta.first_prompt, "No prompt")) {
        const fp = if (meta.first_prompt.len > max_first_message_chars)
            meta.first_prompt[0..max_first_message_chars]
        else
            meta.first_prompt;
        try w.print(" - First message: {s}", .{fp});
    }
    if (meta.transcript.len > 0) try w.print(" - Transcript: {s}", .{meta.transcript});
}

/// Build the full user message for the agentic-search model call: a numbered
/// session list, the search query, and the find-relevant instruction. Mirrors
/// `agenticSessionSearch.ts:248-253`. Returned slice is freshly allocated and
/// owned by the caller.
pub fn buildPrompt(allocator: std.mem.Allocator, metas: []const SessionMeta, query: []const u8) ![]u8 {
    var sb = std_io.StringBuilder.init(allocator);
    defer sb.deinit();
    const w = sb.writer();

    try w.writeAll("Sessions:\n");
    for (metas, 0..) |meta, i| {
        try writeSessionEntry(w, i, meta);
        try w.writeByte('\n');
    }
    try w.print(
        \\
        \\Search query: "{s}"
        \\
        \\Find the sessions that are most relevant to this query.
    , .{query});

    return sb.toOwnedSlice();
}

/// Parse the model's reply into a deduped list of in-range session indices.
///
/// Tolerant of: a `{"relevant_indices": [2, 5, 0]}` JSON object, a bare JSON
/// array `[2, 5, 0]`, a comma/space-separated list `2, 5, 0`, and noisy text
/// with the JSON embedded (prose before/after, markdown fences). Indices >=
/// `count` are dropped (the reference clamps to range) and duplicates are
/// ignored, preserving the model's ordering. Mirrors the JSON-extraction in
/// `agenticSessionSearch.ts:283-295`. Returned slice is allocated; caller frees.
pub fn parseIndices(allocator: std.mem.Allocator, reply: []const u8, count: usize) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(allocator);

    // Extract the first {...} object span if present (the reference regex
    // `\{[\s\S]*\}`, greedy to the last brace). Fall back to the first [...]
    // array span, then to the raw reply (bare comma list).
    const span = firstSpan(reply, '{', '}') orelse
        firstSpan(reply, '[', ']') orelse
        reply;

    // Scan the span for unsigned integers. We deliberately do not require valid
    // JSON: numbers appear only as indices in every accepted form, so a plain
    // digit scan handles the JSON object, the array, and the bare comma list
    // uniformly, and shrugs off surrounding noise / a `"relevant_indices"` key
    // (a key has no digits to confuse the scan).
    var i: usize = 0;
    while (i < span.len) {
        if (!std.ascii.isDigit(span[i])) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < span.len and std.ascii.isDigit(span[j])) j += 1;
        const n = std.fmt.parseInt(usize, span[i..j], 10) catch {
            i = j;
            continue;
        };
        i = j;
        if (n >= count) continue; // clamp to range
        // Dedupe while preserving order.
        var seen = false;
        for (out.items) |existing| {
            if (existing == n) {
                seen = true;
                break;
            }
        }
        if (!seen) try out.append(allocator, n);
    }

    return out.toOwnedSlice(allocator);
}

/// Return the substring from the first `open` byte through the last `close`
/// byte (inclusive), or null if either is missing or out of order. Greedy to
/// the last `close` to match the reference `[\s\S]*` capture.
fn firstSpan(s: []const u8, open: u8, close: u8) ?[]const u8 {
    const start = std.mem.indexOfScalar(u8, s, open) orelse return null;
    const end = std.mem.lastIndexOfScalar(u8, s, close) orelse return null;
    if (end < start) return null;
    return s[start .. end + 1];
}

/// Indirection that lets the runtime supply the fast-model call without this
/// deep module importing the providers tree (mirrors `compaction.Summarizer`).
/// `call` sends `system_prompt` + the `buildPrompt` user message to the small/
/// fast model and returns the raw reply text (caller frees) or null on failure
/// / no provider. The caller then runs `parseIndices` over the reply.
pub const Searcher = struct {
    ctx: *anyopaque,
    /// Returns raw model reply text (allocated with `allocator`, caller frees)
    /// or null when offline / the call failed. `system` is `system_prompt`;
    /// `user_message` is the `buildPrompt` output.
    call: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        system: []const u8,
        user_message: []const u8,
    ) ?[]u8,
};

/// Run the full agentic search: build the prompt, invoke the model via
/// `searcher`, and parse the reply into in-range indices. Returns null when the
/// model call yields no reply (offline / failure) so the caller degrades to the
/// deterministic fuzzy path. On success the returned `[]usize` is allocated and
/// owned by the caller. Pre-filtering / session-count capping is the caller's
/// responsibility (it owns `store.list()` and the lazy transcript loads); this
/// function takes the already-selected `metas` slice.
pub fn run(
    allocator: std.mem.Allocator,
    searcher: Searcher,
    metas: []const SessionMeta,
    query: []const u8,
) !?[]usize {
    if (query.len == 0 or metas.len == 0) return null;
    const prompt = try buildPrompt(allocator, metas, query);
    defer allocator.free(prompt);
    const reply = searcher.call(searcher.ctx, allocator, system_prompt, prompt) orelse return null;
    defer allocator.free(reply);
    return try parseIndices(allocator, reply, metas.len);
}

const testing = std.testing;

test "logContainsQuery matches label, tag, branch, summary, first prompt, transcript" {
    const meta = SessionMeta{
        .title = "Refactor the parser",
        .tag = "cleanup",
        .branch = "feat/lexer",
        .summary = "Reworked tokenizer dispatch",
        .first_prompt = "please rename the AST nodes",
        .transcript = "user wants to split the visitor pass",
    };
    try testing.expect(logContainsQuery(meta, "parser")); // title
    try testing.expect(logContainsQuery(meta, "CLEAN")); // tag, case-insensitive
    try testing.expect(logContainsQuery(meta, "lexer")); // branch
    try testing.expect(logContainsQuery(meta, "tokenizer")); // summary
    try testing.expect(logContainsQuery(meta, "rename")); // first prompt
    try testing.expect(logContainsQuery(meta, "visitor")); // transcript
}

test "logContainsQuery misses when no field contains the query" {
    const meta = SessionMeta{
        .title = "Fix the login button",
        .tag = "ui",
        .summary = "Adjusted the form layout",
    };
    try testing.expect(!logContainsQuery(meta, "kubernetes"));
    // Empty query matches nothing (the caller guards the empty-query path).
    try testing.expect(!logContainsQuery(meta, ""));
}

test "logContainsQuery only matches custom title when set" {
    const meta = SessionMeta{ .title = "abc", .custom_title = "my deploy notes" };
    try testing.expect(logContainsQuery(meta, "deploy"));
    const bare = SessionMeta{ .title = "abc" };
    try testing.expect(!logContainsQuery(bare, "deploy"));
}

test "buildPrompt includes index, title, tag, branch, first message, transcript" {
    const metas = [_]SessionMeta{
        .{
            .title = "Refactor parser",
            .tag = "cleanup",
            .branch = "feat/lexer",
            .summary = "Reworked tokenizer",
            .first_prompt = "rename the AST nodes",
            .transcript = "split the visitor pass",
        },
        .{ .title = "Fix login" },
    };
    const prompt = try buildPrompt(testing.allocator, &metas, "parser");
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "0: Refactor parser") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "[tag: cleanup]") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "[branch: feat/lexer]") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "- Summary: Reworked tokenizer") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "- First message: rename the AST nodes") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "- Transcript: split the visitor pass") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "1: Fix login") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Search query: \"parser\"") != null);
}

test "buildPrompt caps the first-message preview at max_first_message_chars" {
    const long = "x" ** (max_first_message_chars + 50);
    const metas = [_]SessionMeta{.{ .title = "t", .first_prompt = long }};
    const prompt = try buildPrompt(testing.allocator, &metas, "q");
    defer testing.allocator.free(prompt);

    const marker = "- First message: ";
    const at = std.mem.indexOf(u8, prompt, marker).?;
    const after = prompt[at + marker.len ..];
    // The preview region ends at the next " - " separator or end-of-entry; here
    // there is no transcript, so it runs to the trailing newline.
    const nl = std.mem.indexOfScalar(u8, after, '\n').?;
    try testing.expectEqual(max_first_message_chars, nl);
}

test "extractTranscript joins user/assistant text, skips tool/system, collapses whitespace" {
    const hist = [_]types.HistoryTurn{
        .{ .role = .user, .content = "hello   world", .timestamp = 0 },
        .{ .role = .tool, .content = "TOOL OUTPUT NOISE", .timestamp = 0 },
        .{ .role = .assistant, .content = "  goodbye\n\nmoon  ", .timestamp = 0 },
        .{ .role = .system, .content = "system noise", .timestamp = 0 },
    };
    const t = try extractTranscript(testing.allocator, &hist);
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("hello world goodbye moon", t);
}

test "extractTranscript truncates at the char cap" {
    var buf: [max_transcript_chars + 100]u8 = undefined;
    @memset(&buf, 'a');
    const hist = [_]types.HistoryTurn{
        .{ .role = .user, .content = &buf, .timestamp = 0 },
    };
    const t = try extractTranscript(testing.allocator, &hist);
    defer testing.allocator.free(t);
    try testing.expectEqual(max_transcript_chars + "...".len, t.len);
    try testing.expect(std.mem.endsWith(u8, t, "..."));
}

test "parseIndices: JSON object form" {
    const r = try parseIndices(testing.allocator, "{\"relevant_indices\": [2, 5, 0]}", 10);
    defer testing.allocator.free(r);
    try testing.expectEqualSlices(usize, &[_]usize{ 2, 5, 0 }, r);
}

test "parseIndices: bare JSON array" {
    const r = try parseIndices(testing.allocator, "[0, 2, 5]", 10);
    defer testing.allocator.free(r);
    try testing.expectEqualSlices(usize, &[_]usize{ 0, 2, 5 }, r);
}

test "parseIndices: comma-separated list" {
    const r = try parseIndices(testing.allocator, "0, 2, 5", 10);
    defer testing.allocator.free(r);
    try testing.expectEqualSlices(usize, &[_]usize{ 0, 2, 5 }, r);
}

test "parseIndices: noisy model output with prose and fences" {
    const reply =
        \\Sure! Here are the relevant ones:
        \\```json
        \\{"relevant_indices": [3, 1]}
        \\```
        \\Hope that helps.
    ;
    const r = try parseIndices(testing.allocator, reply, 10);
    defer testing.allocator.free(r);
    try testing.expectEqualSlices(usize, &[_]usize{ 3, 1 }, r);
}

test "parseIndices: drops out-of-range and dedupes preserving order" {
    const r = try parseIndices(testing.allocator, "[2, 9, 2, 4, 1]", 5);
    defer testing.allocator.free(r);
    // 9 is out of range (count=5); the second 2 is a dup.
    try testing.expectEqualSlices(usize, &[_]usize{ 2, 4, 1 }, r);
}

test "parseIndices: empty array yields empty slice" {
    const r = try parseIndices(testing.allocator, "{\"relevant_indices\": []}", 5);
    defer testing.allocator.free(r);
    try testing.expectEqual(@as(usize, 0), r.len);
}

test "run returns null when the searcher reports no provider" {
    const NoProvider = struct {
        fn call(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) ?[]u8 {
            return null;
        }
    };
    var ctx: u8 = 0;
    const searcher = Searcher{ .ctx = &ctx, .call = NoProvider.call };
    const metas = [_]SessionMeta{.{ .title = "a" }};
    const res = try run(testing.allocator, searcher, &metas, "a");
    try testing.expect(res == null);
}

test "run feeds the prompt to the searcher and parses the reply" {
    const Stub = struct {
        fn call(ctx: *anyopaque, allocator: std.mem.Allocator, system: []const u8, user_message: []const u8) ?[]u8 {
            const saw = @as(*bool, @ptrCast(ctx));
            // The system prompt is the inclusive-bias instruction.
            std.debug.assert(std.mem.indexOf(u8, system, "VERY inclusive") != null);
            // The user message carries the numbered session list + query.
            if (std.mem.indexOf(u8, user_message, "1: second") != null and
                std.mem.indexOf(u8, user_message, "Search query: \"x\"") != null)
            {
                saw.* = true;
            }
            return allocator.dupe(u8, "{\"relevant_indices\": [1, 0]}") catch null;
        }
    };
    var saw = false;
    const searcher = Searcher{ .ctx = &saw, .call = Stub.call };
    const metas = [_]SessionMeta{ .{ .title = "first" }, .{ .title = "second" } };
    const res = (try run(testing.allocator, searcher, &metas, "x")).?;
    defer testing.allocator.free(res);
    try testing.expect(saw);
    try testing.expectEqualSlices(usize, &[_]usize{ 1, 0 }, res);
}
