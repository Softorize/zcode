//! Pure scoring helpers for ToolSearch's keyword search path.
//!
//! Ported from claude-code-main/src/tools/ToolSearchTool/ToolSearchTool.ts:
//!  - parseToolName (:132-161): split a tool name into searchable lowercased
//!    parts, handling both MCP names (mcp__server__action) and CamelCase
//!    regular names.
//!  - the required/optional term partition (:218-232).
//!  - the pre-filter "matches ALL required terms" rule (:235-257).
//!  - scoreTool (:259-295): name-part exact (10/12) / partial (5/6) /
//!    full-name fallback (+3 only when score still 0) / search_hint (+4) /
//!    description (+2).
//!
//! Word-boundary matching: the reference uses `\b<term>\b` regexes for the
//! description and search_hint matches to avoid false positives (e.g. "cat"
//! inside "concatenate"). Zig std has no regex, so wordBoundaryMatch below is
//! a small hand-rolled equivalent: a hit must be flanked by a non-alphanumeric
//! byte (or a string edge) on both sides. All inputs are lowercased before
//! comparison so the match itself is case-insensitive.
//!
//! Everything here is allocation-light: parseToolName takes an arena from the
//! caller so the per-search part slices do not leak. The scoring functions
//! themselves allocate nothing.

const std = @import("std");
const types = @import("../core/types.zig");

/// MCP-score / regular-score weight pairs, mirroring the reference.
const SCORE_PART_EXACT_MCP: i32 = 12;
const SCORE_PART_EXACT_REGULAR: i32 = 10;
const SCORE_PART_PARTIAL_MCP: i32 = 6;
const SCORE_PART_PARTIAL_REGULAR: i32 = 5;
const SCORE_FULL_FALLBACK: i32 = 3;
const SCORE_HINT: i32 = 4;
const SCORE_DESC: i32 = 2;

pub const ParsedName = struct {
    /// Lowercased name fragments (CamelCase boundaries + `_`/`__` splits).
    parts: [][]const u8,
    /// `parts` joined by single spaces, lowercased.
    full: []const u8,
    is_mcp: bool,
};

/// Lowercase `s` into a freshly arena-allocated buffer.
fn lowerDup(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try arena.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

/// Split a tool name into searchable lowercased parts.
/// Mirrors parseToolName (ToolSearchTool.ts:132-161). `arena` owns all
/// returned slices.
pub fn parseToolName(arena: std.mem.Allocator, name: []const u8) !ParsedName {
    var parts: std.ArrayList([]const u8) = .empty;

    if (std.mem.startsWith(u8, name, "mcp__")) {
        const without_prefix = name["mcp__".len..];
        // Split on `__` first, then each chunk on `_`.
        var seg_it = std.mem.splitSequence(u8, without_prefix, "__");
        while (seg_it.next()) |seg| {
            var sub_it = std.mem.splitScalar(u8, seg, '_');
            while (sub_it.next()) |sub| {
                if (sub.len == 0) continue;
                try parts.append(arena, try lowerDup(arena, sub));
            }
        }
        const full = try std.mem.join(arena, " ", parts.items);
        return .{ .parts = try parts.toOwnedSlice(arena), .full = full, .is_mcp = true };
    }

    // Regular tool: split on CamelCase boundaries (lower->upper) and `_`.
    var current: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        const c = name[i];
        if (c == '_') {
            if (current.items.len > 0) {
                try parts.append(arena, try arena.dupe(u8, current.items));
                current.clearRetainingCapacity();
            }
            continue;
        }
        // CamelCase boundary: previous lower, current upper -> start a new part.
        if (i > 0 and std.ascii.isUpper(c) and std.ascii.isLower(name[i - 1]) and current.items.len > 0) {
            try parts.append(arena, try arena.dupe(u8, current.items));
            current.clearRetainingCapacity();
        }
        try current.append(arena, std.ascii.toLower(c));
    }
    if (current.items.len > 0) {
        try parts.append(arena, try arena.dupe(u8, current.items));
    }

    const full = try std.mem.join(arena, " ", parts.items);
    return .{ .parts = try parts.toOwnedSlice(arena), .full = full, .is_mcp = false };
}

/// True if `term` appears in `haystack` flanked by word boundaries on both
/// sides (string edge or a non-alphanumeric byte). Both arguments must already
/// be lowercased; matching is then exact. Equivalent to JS `\b<term>\b`.
pub fn wordBoundaryMatch(haystack: []const u8, term: []const u8) bool {
    if (term.len == 0) return false;
    if (term.len > haystack.len) return false;
    var i: usize = 0;
    while (i + term.len <= haystack.len) : (i += 1) {
        if (!std.mem.eql(u8, haystack[i .. i + term.len], term)) continue;
        const left_ok = i == 0 or !isWordByte(haystack[i - 1]);
        const right_idx = i + term.len;
        const right_ok = right_idx == haystack.len or !isWordByte(haystack[right_idx]);
        if (left_ok and right_ok) return true;
    }
    return false;
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// True when every part in `parsed.parts` is checked and `term` either equals a
/// part exactly or is a substring of one. (`term` already lowercased.)
fn partsContainExact(parsed: ParsedName, term: []const u8) bool {
    for (parsed.parts) |part| {
        if (std.mem.eql(u8, part, term)) return true;
    }
    return false;
}

fn partsContainPartial(parsed: ParsedName, term: []const u8) bool {
    for (parsed.parts) |part| {
        if (std.mem.indexOf(u8, part, term) != null) return true;
    }
    return false;
}

/// Required-term pre-filter rule (ToolSearchTool.ts:244-252): a tool survives
/// the filter only if EVERY required term matches a name part (exact or
/// partial), the description (word boundary), or the search_hint (word
/// boundary). `required_terms` are lowercased; `parsed` is the parsed tool
/// name; `desc_lower` / `hint_lower` are the lowercased description / hint.
pub fn matchesAllRequired(
    parsed: ParsedName,
    desc_lower: []const u8,
    hint_lower: []const u8,
    required_terms: []const []const u8,
) bool {
    for (required_terms) |term| {
        const ok = partsContainExact(parsed, term) or
            partsContainPartial(parsed, term) or
            wordBoundaryMatch(desc_lower, term) or
            (hint_lower.len > 0 and wordBoundaryMatch(hint_lower, term));
        if (!ok) return false;
    }
    return true;
}

/// Score a single tool over `scoring_terms` using the reference weights.
/// `parsed` is the parsed tool name; `desc_lower` / `hint_lower` are the
/// lowercased description / search_hint; `scoring_terms` are lowercased.
pub fn scoreTool(
    parsed: ParsedName,
    desc_lower: []const u8,
    hint_lower: []const u8,
    scoring_terms: []const []const u8,
) i32 {
    var score: i32 = 0;
    for (scoring_terms) |term| {
        if (partsContainExact(parsed, term)) {
            score += if (parsed.is_mcp) SCORE_PART_EXACT_MCP else SCORE_PART_EXACT_REGULAR;
        } else if (partsContainPartial(parsed, term)) {
            score += if (parsed.is_mcp) SCORE_PART_PARTIAL_MCP else SCORE_PART_PARTIAL_REGULAR;
        }

        // Full-name fallback: only when nothing else has scored yet.
        if (score == 0 and std.mem.indexOf(u8, parsed.full, term) != null) {
            score += SCORE_FULL_FALLBACK;
        }

        if (hint_lower.len > 0 and wordBoundaryMatch(hint_lower, term)) {
            score += SCORE_HINT;
        }
        if (wordBoundaryMatch(desc_lower, term)) {
            score += SCORE_DESC;
        }
    }
    return score;
}

/// Result of splitting a lowercased query into required (`+term`) and optional
/// terms. The slices borrow from `query_lower` (no copy).
pub const Terms = struct {
    required: [][]const u8,
    optional: [][]const u8,
    /// required ++ optional when there are required terms, else == optional
    /// (i.e. all terms). Backed by `storage`.
    scoring: [][]const u8,
    storage: [][]const u8,

    pub fn deinit(self: *Terms, allocator: std.mem.Allocator) void {
        allocator.free(self.required);
        allocator.free(self.optional);
        allocator.free(self.scoring);
        allocator.free(self.storage);
    }
};

/// Partition a lowercased, trimmed query into required/optional/scoring terms.
/// Mirrors ToolSearchTool.ts:218-232. Whitespace-split; a leading `+` (with at
/// least one more char) marks a required term, the `+` is sliced off. Slices
/// borrow from `query_lower`.
pub fn partitionTerms(allocator: std.mem.Allocator, query_lower: []const u8) !Terms {
    var storage: std.ArrayList([]const u8) = .empty;
    errdefer storage.deinit(allocator);
    var required: std.ArrayList([]const u8) = .empty;
    errdefer required.deinit(allocator);
    var optional: std.ArrayList([]const u8) = .empty;
    errdefer optional.deinit(allocator);

    var it = std.mem.tokenizeAny(u8, query_lower, " \t\r\n");
    while (it.next()) |term| {
        try storage.append(allocator, term);
        if (term.len > 1 and term[0] == '+') {
            try required.append(allocator, term[1..]);
        } else {
            try optional.append(allocator, term);
        }
    }

    var scoring: std.ArrayList([]const u8) = .empty;
    errdefer scoring.deinit(allocator);
    if (required.items.len > 0) {
        try scoring.appendSlice(allocator, required.items);
        try scoring.appendSlice(allocator, optional.items);
    } else {
        // No required terms -> score over every query term (matches reference
        // `queryTerms`, which keeps the raw split including any stray tokens).
        try scoring.appendSlice(allocator, storage.items);
    }

    return .{
        .required = try required.toOwnedSlice(allocator),
        .optional = try optional.toOwnedSlice(allocator),
        .scoring = try scoring.toOwnedSlice(allocator),
        .storage = try storage.toOwnedSlice(allocator),
    };
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "parseToolName splits CamelCase regular names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parseToolName(arena.allocator(), "WebFetch");
    try testing.expect(!p.is_mcp);
    try testing.expectEqual(@as(usize, 2), p.parts.len);
    try testing.expectEqualStrings("web", p.parts[0]);
    try testing.expectEqualStrings("fetch", p.parts[1]);
    try testing.expectEqualStrings("web fetch", p.full);
}

test "parseToolName splits MCP names on __ and _" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parseToolName(arena.allocator(), "mcp__slack__send_message");
    try testing.expect(p.is_mcp);
    try testing.expectEqual(@as(usize, 3), p.parts.len);
    try testing.expectEqualStrings("slack", p.parts[0]);
    try testing.expectEqualStrings("send", p.parts[1]);
    try testing.expectEqualStrings("message", p.parts[2]);
    try testing.expectEqualStrings("slack send message", p.full);
}

test "parseToolName handles underscore-only and acronym runs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = try parseToolName(arena.allocator(), "tool_search");
    try testing.expectEqual(@as(usize, 2), a.parts.len);
    try testing.expectEqualStrings("tool", a.parts[0]);
    try testing.expectEqualStrings("search", a.parts[1]);

    // Acronym run: lower-to-upper boundary split only, so "LSP" stays one part.
    const b = try parseToolName(arena.allocator(), "LSP");
    try testing.expectEqual(@as(usize, 1), b.parts.len);
    try testing.expectEqualStrings("lsp", b.parts[0]);

    // "HttpRequest" -> "http" "request".
    const c = try parseToolName(arena.allocator(), "HttpRequest");
    try testing.expectEqual(@as(usize, 2), c.parts.len);
    try testing.expectEqualStrings("http", c.parts[0]);
    try testing.expectEqualStrings("request", c.parts[1]);
}

test "wordBoundaryMatch respects boundaries" {
    try testing.expect(wordBoundaryMatch("search the web", "web"));
    try testing.expect(wordBoundaryMatch("web", "web"));
    try testing.expect(wordBoundaryMatch("the web.", "web"));
    // "cat" must not match inside "concatenate".
    try testing.expect(!wordBoundaryMatch("concatenate files", "cat"));
    try testing.expect(!wordBoundaryMatch("website", "web"));
}

test "partitionTerms splits required and optional" {
    var t = try partitionTerms(testing.allocator, "+slack send message");
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), t.required.len);
    try testing.expectEqualStrings("slack", t.required[0]);
    try testing.expectEqual(@as(usize, 2), t.optional.len);
    try testing.expectEqualStrings("send", t.optional[0]);
    try testing.expectEqualStrings("message", t.optional[1]);
    // scoring = required ++ optional
    try testing.expectEqual(@as(usize, 3), t.scoring.len);
    try testing.expectEqualStrings("slack", t.scoring[0]);
}

test "partitionTerms with no required scores all terms" {
    var t = try partitionTerms(testing.allocator, "fetch web");
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), t.required.len);
    try testing.expectEqual(@as(usize, 2), t.scoring.len);
    try testing.expectEqualStrings("fetch", t.scoring[0]);
    try testing.expectEqualStrings("web", t.scoring[1]);
}

test "scoreTool ranks name-part match above description-only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // WebFetch: "web" and "fetch" are name parts.
    const web_fetch = try parseToolName(a, "WebFetch");
    const wf_desc = "fetch and read web content";
    const wf_hint = "fetch and extract content from a url";

    // A tool that only mentions "web" in its description, not its name.
    const other = try parseToolName(a, "Brief");
    const other_desc = "summarize a file but also mentions web fetch in passing";
    const other_hint = "";

    const terms = [_][]const u8{ "fetch", "web" };
    const wf_score = scoreTool(web_fetch, wf_desc, wf_hint, &terms);
    const other_score = scoreTool(other, other_desc, other_hint, &terms);
    try testing.expect(wf_score > other_score);
}

test "search_hint match contributes more than description-only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try parseToolName(a, "Brief");

    const term = [_][]const u8{"summarize"};
    // Hint contains the term (word boundary) -> +4; description does not.
    const with_hint = scoreTool(parsed, "reads a file", "summarize a file quickly", &term);
    // Description contains the term -> +2; no hint.
    const with_desc = scoreTool(parsed, "summarize a file quickly", "", &term);
    try testing.expectEqual(@as(i32, 4), with_hint);
    try testing.expectEqual(@as(i32, 2), with_desc);
    try testing.expect(with_hint > with_desc);
}

test "matchesAllRequired requires every required term" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try parseToolName(a, "mcp__slack__send_message");

    const ok = [_][]const u8{"slack"};
    try testing.expect(matchesAllRequired(parsed, "send a message", "", &ok));

    // "github" is not in name/desc/hint -> filtered out.
    const bad = [_][]const u8{ "slack", "github" };
    try testing.expect(!matchesAllRequired(parsed, "send a message", "", &bad));
}

test "scoreTool uses real builtin_schemas WebFetch entry" {
    const tool_schemas = @import("tool_schemas.zig");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var web_fetch: ?types.ToolSchema = null;
    for (tool_schemas.builtin_schemas) |s| {
        if (std.mem.eql(u8, s.name, "WebFetch")) {
            web_fetch = s;
            break;
        }
    }
    try testing.expect(web_fetch != null);
    const wf = web_fetch.?;
    try testing.expect(wf.search_hint.len > 0);

    const parsed = try parseToolName(a, wf.name);
    const desc_lower = try lowerDup(a, wf.description);
    const hint_lower = try lowerDup(a, wf.search_hint);
    const terms = [_][]const u8{ "fetch", "web" };
    const score = scoreTool(parsed, desc_lower, hint_lower, &terms);
    // "web" + "fetch" are both name parts -> at least 2*10 = 20.
    try testing.expect(score >= 20);
}
