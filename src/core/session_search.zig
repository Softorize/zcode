//! P6 (PRD #534) session search. Ranks sessions by fuzzy match of a query
//! against each session's label and id, reusing the shared fuzzy scorer. Pure:
//! candidates + query in, a ranked subset out (caller owns the result slice).

const std = @import("std");
const fuzzy = @import("parse_helpers.zig");

pub const Candidate = struct {
    id: []const u8,
    label: []const u8 = "",
};

pub const Ranked = struct {
    candidate: Candidate,
    score: i32,
};

/// Score a candidate as the better of its label and id match. Null if neither
/// matches the query.
fn scoreCandidate(query: []const u8, c: Candidate) ?i32 {
    const by_label = if (c.label.len > 0) fuzzy.fuzzyScore(query, c.label) else null;
    const by_id = fuzzy.fuzzyScore(query, c.id);
    if (by_label == null and by_id == null) return null;
    const a = by_label orelse std.math.minInt(i32);
    const b = by_id orelse std.math.minInt(i32);
    return @max(a, b);
}

/// Smallest fuzzy score we treat as a real match for resume resolution.
/// fuzzyScore returns null for no match at all, but a 1-character query can
/// score a low positive against an unrelated id; require a modest floor so a
/// stray-character term does not silently resume an arbitrary session.
pub const min_resume_score: i32 = 12;

/// Outcome of resolving a `/resume <arg>` term against the session list.
/// Pure decision: the caller does the actual `store.load` on `.exact` /
/// `.single`. `multiple` and `none` borrow `.id` slices out of the input
/// candidates (no allocation); the caller must not free them.
pub const ResumeTarget = union(enum) {
    /// `arg` is exactly one candidate's id -- resume it (preserves the
    /// historical exact-UUID fast path so a literal id is never fuzzy-hijacked).
    exact: []const u8,
    /// Exactly one candidate matched fuzzily above the score floor.
    single: []const u8,
    /// More than one candidate matched -- ids borrowed from `candidates`,
    /// best score first. Caller frees the slice (not the elements). Capped.
    multiple: [][]const u8,
    /// No candidate matched.
    none,
};

/// Resolve a resume argument: exact id wins, then a single fuzzy match wins,
/// then multiple-match disambiguation, then none. `arg` is assumed already
/// trimmed and non-empty (the no-arg path opens the picker instead).
/// The `.multiple` slice is allocated; free it with `allocator.free` on the
/// returned slice. All other variants allocate nothing.
pub fn resolveResumeTarget(allocator: std.mem.Allocator, candidates: []const Candidate, arg: []const u8) !ResumeTarget {
    // Exact-id fast path first so a literal id never gets fuzzy-hijacked by a
    // label that happens to contain the same characters.
    for (candidates) |c| {
        if (std.mem.eql(u8, c.id, arg)) return .{ .exact = c.id };
    }

    const ranked = try search(allocator, candidates, arg);
    defer allocator.free(ranked);

    // Keep only matches above the score floor (search already drops non-matches).
    var matched: usize = 0;
    for (ranked) |r| {
        if (r.score >= min_resume_score) matched += 1;
    }
    if (matched == 0) return .none;
    if (matched == 1) {
        for (ranked) |r| {
            if (r.score >= min_resume_score) return .{ .single = r.candidate.id };
        }
    }

    const max_list = @min(matched, @as(usize, 5));
    var ids = try allocator.alloc([]const u8, max_list);
    errdefer allocator.free(ids);
    var n: usize = 0;
    for (ranked) |r| {
        if (n >= max_list) break;
        if (r.score >= min_resume_score) {
            ids[n] = r.candidate.id;
            n += 1;
        }
    }
    return .{ .multiple = ids };
}

/// Return candidates matching `query`, highest score first. An empty query
/// returns all candidates (score 0) in their original order. Caller frees.
pub fn search(allocator: std.mem.Allocator, candidates: []const Candidate, query: []const u8) ![]Ranked {
    var out: std.ArrayList(Ranked) = .empty;
    errdefer out.deinit(allocator);

    const q = std.mem.trim(u8, query, " \t");
    if (q.len == 0) {
        for (candidates) |c| try out.append(allocator, .{ .candidate = c, .score = 0 });
        return out.toOwnedSlice(allocator);
    }

    for (candidates) |c| {
        if (scoreCandidate(q, c)) |s| try out.append(allocator, .{ .candidate = c, .score = s });
    }
    std.mem.sort(Ranked, out.items, {}, struct {
        fn lt(_: void, a: Ranked, b: Ranked) bool {
            return a.score > b.score;
        }
    }.lt);
    return out.toOwnedSlice(allocator);
}

const testing = std.testing;

test "empty query returns all in order" {
    const cands = [_]Candidate{
        .{ .id = "1", .label = "alpha" },
        .{ .id = "2", .label = "beta" },
    };
    const r = try search(testing.allocator, &cands, "");
    defer testing.allocator.free(r);
    try testing.expectEqual(@as(usize, 2), r.len);
    try testing.expectEqualStrings("1", r[0].candidate.id);
}

test "ranks matches and drops non-matches" {
    const cands = [_]Candidate{
        .{ .id = "s1", .label = "refactor parser" },
        .{ .id = "s2", .label = "fix login bug" },
        .{ .id = "s3", .label = "parser cleanup" },
    };
    const r = try search(testing.allocator, &cands, "parser");
    defer testing.allocator.free(r);
    // both parser sessions match; the login one does not
    try testing.expectEqual(@as(usize, 2), r.len);
    for (r) |row| try testing.expect(!std.mem.eql(u8, row.candidate.id, "s2"));
}

test "matches against id when label is empty" {
    const cands = [_]Candidate{.{ .id = "deadbeef-session", .label = "" }};
    const r = try search(testing.allocator, &cands, "deadbeef");
    defer testing.allocator.free(r);
    try testing.expectEqual(@as(usize, 1), r.len);
}

test "search ranks parser query with parser sessions first" {
    const cands = [_]Candidate{
        .{ .id = "s1", .label = "fix login bug" },
        .{ .id = "s2", .label = "refactor parser internals" },
        .{ .id = "s3", .label = "parser cleanup" },
    };
    const r = try search(testing.allocator, &cands, "parser");
    defer testing.allocator.free(r);
    try testing.expectEqual(@as(usize, 2), r.len);
    // Both parser sessions come back; neither is the login one, and the
    // highest-scoring is first.
    for (r) |row| try testing.expect(!std.mem.eql(u8, row.candidate.id, "s1"));
    try testing.expect(r[0].score >= r[1].score);
}

test "resolveResumeTarget: exact id wins over fuzzy" {
    const cands = [_]Candidate{
        .{ .id = "parser", .label = "some label" },
        .{ .id = "s2", .label = "parser cleanup" },
    };
    const t = try resolveResumeTarget(testing.allocator, &cands, "parser");
    switch (t) {
        .exact => |id| try testing.expectEqualStrings("parser", id),
        else => return error.TestUnexpectedResult,
    }
}

test "resolveResumeTarget: single fuzzy match" {
    const cands = [_]Candidate{
        .{ .id = "s1", .label = "fix login bug" },
        .{ .id = "s2", .label = "refactor parser internals" },
    };
    const t = try resolveResumeTarget(testing.allocator, &cands, "parser");
    switch (t) {
        .single => |id| try testing.expectEqualStrings("s2", id),
        else => return error.TestUnexpectedResult,
    }
}

test "resolveResumeTarget: multiple matches" {
    const cands = [_]Candidate{
        .{ .id = "s1", .label = "refactor parser internals" },
        .{ .id = "s2", .label = "fix login bug" },
        .{ .id = "s3", .label = "parser cleanup" },
    };
    const t = try resolveResumeTarget(testing.allocator, &cands, "parser");
    switch (t) {
        .multiple => |ids| {
            defer testing.allocator.free(ids);
            try testing.expectEqual(@as(usize, 2), ids.len);
            for (ids) |id| try testing.expect(!std.mem.eql(u8, id, "s2"));
        },
        else => return error.TestUnexpectedResult,
    }
}

test "resolveResumeTarget: no match" {
    const cands = [_]Candidate{
        .{ .id = "s1", .label = "fix login bug" },
        .{ .id = "s2", .label = "deploy pipeline" },
    };
    const t = try resolveResumeTarget(testing.allocator, &cands, "zzqqxx");
    try testing.expect(t == .none);
}
