const std = @import("std");

/// Longest matching prefix and suffix of two byte strings, returned as
/// byte offsets. The two pairs never overlap: if the shared prefix
/// covers the entire shorter string, the suffix is reported as zero so
/// callers never see the same bytes twice.
pub const Affixes = struct {
    prefix: usize,
    suffix: usize,
};

/// Find the longest shared prefix and suffix of `a` and `b` as byte
/// offsets, clamped so the regions do not overlap on either side.
/// Used by the word-level diff renderer to highlight only the middle
/// region that actually changed on a modified line.
pub fn commonAffixes(a: []const u8, b: []const u8) Affixes {
    var prefix: usize = 0;
    const min_len = @min(a.len, b.len);
    while (prefix < min_len and a[prefix] == b[prefix]) : (prefix += 1) {}

    var suffix: usize = 0;
    // Clamp so suffix + prefix never exceeds either side.
    const max_tail = min_len - prefix;
    while (suffix < max_tail and a[a.len - 1 - suffix] == b[b.len - 1 - suffix]) : (suffix += 1) {}

    return .{ .prefix = prefix, .suffix = suffix };
}

/// Break a byte range into tokens on word / non-word boundaries so a
/// word-level diff sees "fooBar" and "fooBaz" as sharing "fooBa" +
/// differing "r" / "z" rather than differing across the whole name.
pub const TokenKind = enum { word, nonword };
pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
};

pub const TokenIterator = struct {
    source: []const u8,
    pos: usize = 0,

    pub fn next(self: *TokenIterator) ?Token {
        if (self.pos >= self.source.len) return null;
        const start = self.pos;
        const first_word = isWordByte(self.source[start]);
        while (self.pos < self.source.len and isWordByte(self.source[self.pos]) == first_word) : (self.pos += 1) {}
        return .{
            .kind = if (first_word) .word else .nonword,
            .text = self.source[start..self.pos],
        };
    }
};

pub fn tokenize(source: []const u8) TokenIterator {
    return .{ .source = source };
}

/// Maximum tokens per side for the LCS-based word diff. Above this the
/// caller falls back to commonAffixes to avoid an O(n*m) blowup on
/// pathological (e.g. minified) lines. 128 keeps the rolling LCS rows
/// small enough to live comfortably on the stack.
pub const WORD_DIFF_TOKEN_CAP: usize = 128;

/// One contiguous run of the word diff. `text` slices point into the
/// caller-supplied `old`/`new` buffers, so it is only valid for as long
/// as those buffers live.
pub const Seg = struct {
    tag: enum { common, removed, added },
    text: []const u8,
};

/// Tokenise `src` into at most `cap` tokens. Returns the count, or null
/// if the source has more tokens than `cap`.
fn collectTokens(src: []const u8, out: []Token, cap: usize) ?usize {
    var it = tokenize(src);
    var n: usize = 0;
    while (it.next()) |tok| {
        if (n >= cap) return null;
        out[n] = tok;
        n += 1;
    }
    return n;
}

/// Produce an ordered, multi-segment word-token diff of `old` vs `new`.
///
/// Both sides are tokenised into word / non-word runs, a longest common
/// subsequence is computed over token-text equality, and segments are
/// emitted in order: tokens on the LCS are `common`; tokens only in
/// `old` are `removed`; tokens only in `new` are `added`. Adjacent
/// segments with the same tag are merged so the caller sees one span per
/// changed run. The returned slice is backed by `out`; `Seg.text` slices
/// point into `old`/`new`.
///
/// Returns null if either side exceeds `WORD_DIFF_TOKEN_CAP` tokens or if
/// `out` is too small to hold the result, so the caller can fall back to
/// the single-affix `commonAffixes` path. No allocation.
pub fn wordDiffSegments(old: []const u8, new: []const u8, out: []Seg) ?[]Seg {
    const cap = WORD_DIFF_TOKEN_CAP;
    var old_toks: [WORD_DIFF_TOKEN_CAP]Token = undefined;
    var new_toks: [WORD_DIFF_TOKEN_CAP]Token = undefined;
    const n = collectTokens(old, &old_toks, cap) orelse return null;
    const m = collectTokens(new, &new_toks, cap) orelse return null;

    // LCS length table, rolling two-row form would suffice for the
    // length, but a full table is needed to backtrack the alignment.
    // (cap+1) rows of (cap+1) u16 = 129*129*2 ~= 33KB on the stack.
    var table: [WORD_DIFF_TOKEN_CAP + 1][WORD_DIFF_TOKEN_CAP + 1]u16 = undefined;
    var i: usize = n;
    while (true) {
        var j: usize = m;
        while (true) {
            if (i == n or j == m) {
                table[i][j] = 0;
            } else if (std.mem.eql(u8, old_toks[i].text, new_toks[j].text)) {
                table[i][j] = table[i + 1][j + 1] + 1;
            } else {
                table[i][j] = @max(table[i + 1][j], table[i][j + 1]);
            }
            if (j == 0) break;
            j -= 1;
        }
        if (i == 0) break;
        i -= 1;
    }

    // Backtrack, appending segments and merging same-tag runs.
    var count: usize = 0;
    i = 0;
    var j: usize = 0;
    while (i < n or j < m) {
        if (i < n and j < m and std.mem.eql(u8, old_toks[i].text, new_toks[j].text)) {
            if (!appendSeg(out, &count, .common, old_toks[i].text)) return null;
            i += 1;
            j += 1;
        } else if (j == m or (i < n and table[i + 1][j] >= table[i][j + 1])) {
            if (!appendSeg(out, &count, .removed, old_toks[i].text)) return null;
            i += 1;
        } else {
            if (!appendSeg(out, &count, .added, new_toks[j].text)) return null;
            j += 1;
        }
    }
    return out[0..count];
}

/// Append a segment, merging it into the previous one when both the tag
/// and the buffer adjacency line up (the two token slices are contiguous
/// in the same source). Returns false if `out` is full.
fn appendSeg(out: []Seg, count: *usize, tag: @FieldType(Seg, "tag"), text: []const u8) bool {
    if (count.* > 0) {
        const prev = &out[count.* - 1];
        if (prev.tag == tag and
            prev.text.ptr + prev.text.len == text.ptr)
        {
            prev.text = prev.text.ptr[0 .. prev.text.len + text.len];
            return true;
        }
    }
    if (count.* >= out.len) return false;
    out[count.*] = .{ .tag = tag, .text = text };
    count.* += 1;
    return true;
}

/// CHANGE_THRESHOLD (0.4) from the reference, expressed as an integer
/// percentage so callers compare without floats.
pub const CHANGE_THRESHOLD_PERCENT: usize = 40;

/// changedLength/totalLength. Returns the percentage 0..100 (integer)
/// so callers compare against CHANGE_THRESHOLD_PERCENT without floats.
///
/// When the real multi-segment token diff fits within the token cap, the
/// changed length is summed over the removed/added segments so it matches
/// the reference's multi-segment changedLength. Above the cap it falls
/// back to the conservative single-affix middle as the changed-length
/// proxy.
pub fn changeRatioPercent(old: []const u8, new: []const u8) usize {
    const total = old.len + new.len;
    if (total == 0) return 0;

    var seg_buf: [2 * WORD_DIFF_TOKEN_CAP]Seg = undefined;
    if (wordDiffSegments(old, new, &seg_buf)) |segs| {
        var changed: usize = 0;
        for (segs) |seg| {
            if (seg.tag != .common) changed += seg.text.len;
        }
        return changed * 100 / total;
    }

    // Over the token cap: affix-based proxy.
    const af = commonAffixes(old, new);
    const old_changed = old.len - af.prefix - af.suffix;
    const new_changed = new.len - af.prefix - af.suffix;
    const changed = old_changed + new_changed;
    return changed * 100 / total;
}

fn isWordByte(b: u8) bool {
    return (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z') or (b >= '0' and b <= '9') or b == '_';
}

/// ANSI colour codes used by renderInlineDiff. Callers can supply a
/// custom set via renderInlineDiffWith when they want themed colours.
pub const DiffStyle = struct {
    remove_open: []const u8 = "\x1b[41;37m", // red background, white fg
    remove_close: []const u8 = "\x1b[0m",
    add_open: []const u8 = "\x1b[42;30m", // green background, black fg
    add_close: []const u8 = "\x1b[0m",
};

/// Write two lines (old, new) where the shared prefix and suffix are
/// emitted plain and the differing middle is wrapped in the supplied
/// ANSI style. Each line is prefixed with "- " / "+ " respectively to
/// match standard unified-diff presentation. Does NOT append a trailing
/// newline -- caller composes line separation.
pub fn renderInlineDiff(writer: anytype, old: []const u8, new: []const u8) !void {
    return renderInlineDiffWith(writer, old, new, .{});
}

pub fn renderInlineDiffWith(
    writer: anytype,
    old: []const u8,
    new: []const u8,
    style: DiffStyle,
) !void {
    const af = commonAffixes(old, new);
    const old_middle_end = old.len - af.suffix;
    const new_middle_end = new.len - af.suffix;

    // Old line.
    try writer.writeAll("- ");
    try writer.writeAll(old[0..af.prefix]);
    if (old_middle_end > af.prefix) {
        try writer.writeAll(style.remove_open);
        try writer.writeAll(old[af.prefix..old_middle_end]);
        try writer.writeAll(style.remove_close);
    }
    try writer.writeAll(old[old_middle_end..]);
    try writer.writeAll("\n");

    // New line.
    try writer.writeAll("+ ");
    try writer.writeAll(new[0..af.prefix]);
    if (new_middle_end > af.prefix) {
        try writer.writeAll(style.add_open);
        try writer.writeAll(new[af.prefix..new_middle_end]);
        try writer.writeAll(style.add_close);
    }
    try writer.writeAll(new[new_middle_end..]);
}

const testing = std.testing;

test "commonAffixes: identical strings" {
    const af = commonAffixes("hello", "hello");
    try testing.expectEqual(@as(usize, 5), af.prefix);
    try testing.expectEqual(@as(usize, 0), af.suffix);
}

test "commonAffixes: shared prefix and suffix" {
    const af = commonAffixes("foo_bar_baz", "foo_quux_baz");
    try testing.expectEqual(@as(usize, 4), af.prefix); // "foo_"
    try testing.expectEqual(@as(usize, 4), af.suffix); // "_baz"
}

test "commonAffixes: completely different" {
    const af = commonAffixes("abc", "xyz");
    try testing.expectEqual(@as(usize, 0), af.prefix);
    try testing.expectEqual(@as(usize, 0), af.suffix);
}

test "commonAffixes: prefix engulfs one side" {
    const af = commonAffixes("hello", "hello world");
    try testing.expectEqual(@as(usize, 5), af.prefix);
    try testing.expectEqual(@as(usize, 0), af.suffix);
}

test "commonAffixes: empty input" {
    const af = commonAffixes("", "anything");
    try testing.expectEqual(@as(usize, 0), af.prefix);
    try testing.expectEqual(@as(usize, 0), af.suffix);
}

test "renderInlineDiff highlights only the differing middle" {
    var buf: [256]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try renderInlineDiff(&fbs, "foo_bar_baz", "foo_quux_baz");
    const rendered = fbs.buffered();
    // Shared prefix "foo_" and suffix "_baz" are outside the ANSI spans.
    try testing.expect(std.mem.indexOf(u8, rendered, "foo_\x1b[") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "\x1b[0m_baz") != null);
    // The differing middles appear inside the spans.
    try testing.expect(std.mem.indexOf(u8, rendered, "bar") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "quux") != null);
    // Both - and + prefixes are emitted.
    try testing.expect(std.mem.indexOf(u8, rendered, "- foo_") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "+ foo_") != null);
}

test "changeRatioPercent: small token change is well under threshold" {
    // One changed word out of four. The token diff (matching the
    // reference's diffWordsWithSpace) counts only "brown"/"brave" as
    // changed, so the ratio stays well under the threshold.
    // Note: an underscore-joined identifier like "foo_bar_baz" is a
    // SINGLE token (underscore is a word byte), so the token diff
    // correctly reports it as a near-total change rather than a small
    // middle - that is the reference-accurate behavior.
    const pct = changeRatioPercent("the quick brown fox", "the quick brave fox");
    try testing.expect(pct < CHANGE_THRESHOLD_PERCENT);
}

test "changeRatioPercent: total rewrite is 100" {
    try testing.expectEqual(@as(usize, 100), changeRatioPercent("abc", "xyz"));
}

test "changeRatioPercent: empty/empty is 0" {
    try testing.expectEqual(@as(usize, 0), changeRatioPercent("", ""));
}

test "tokenize splits on word / non-word boundaries" {
    var it = tokenize("foo_bar baz(42)");
    const t1 = it.next().?;
    try testing.expect(t1.kind == .word);
    try testing.expectEqualStrings("foo_bar", t1.text);
    const t2 = it.next().?;
    try testing.expect(t2.kind == .nonword);
    try testing.expectEqualStrings(" ", t2.text);
    const t3 = it.next().?;
    try testing.expectEqualStrings("baz", t3.text);
    const t4 = it.next().?;
    try testing.expectEqualStrings("(", t4.text);
    const t5 = it.next().?;
    try testing.expectEqualStrings("42", t5.text);
    const t6 = it.next().?;
    try testing.expectEqualStrings(")", t6.text);
    try testing.expect(it.next() == null);
}

test "wordDiffSegments: two separated edits leave the middle common" {
    var buf: [64]Seg = undefined;
    const segs = wordDiffSegments("rename foo to bar", "rename baz to qux", &buf).?;

    // Old side: common "rename ", removed "foo", common " to ", removed "bar".
    // New side: common "rename ", added  "baz", common " to ", added  "qux".
    // The unchanged " to " in the middle must NOT be highlighted.
    // Walk the segments collecting old-side and new-side reconstructions.
    var old_recon = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer old_recon.deinit(testing.allocator);
    var new_recon = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer new_recon.deinit(testing.allocator);

    var saw_common_to = false;
    var removed_runs: usize = 0;
    var added_runs: usize = 0;
    for (segs) |seg| {
        switch (seg.tag) {
            .common => {
                try old_recon.appendSlice(testing.allocator, seg.text);
                try new_recon.appendSlice(testing.allocator, seg.text);
                if (std.mem.eql(u8, seg.text, " to ")) saw_common_to = true;
            },
            .removed => {
                try old_recon.appendSlice(testing.allocator, seg.text);
                removed_runs += 1;
            },
            .added => {
                try new_recon.appendSlice(testing.allocator, seg.text);
                added_runs += 1;
            },
        }
    }
    try testing.expectEqualStrings("rename foo to bar", old_recon.items);
    try testing.expectEqualStrings("rename baz to qux", new_recon.items);
    // The shared interior " to " is reported common, not part of any edit.
    try testing.expect(saw_common_to);
    // Two disjoint removed runs and two disjoint added runs.
    try testing.expectEqual(@as(usize, 2), removed_runs);
    try testing.expectEqual(@as(usize, 2), added_runs);
}

test "wordDiffSegments: identical input is all common" {
    var buf: [64]Seg = undefined;
    const segs = wordDiffSegments("foo bar baz", "foo bar baz", &buf).?;
    for (segs) |seg| try testing.expect(seg.tag == .common);
}

test "wordDiffSegments: over-cap input falls back to null" {
    // Build a string with more than WORD_DIFF_TOKEN_CAP tokens (alternating
    // word / nonword runs). Each "a " contributes two tokens.
    var src: [4096]u8 = undefined;
    var n: usize = 0;
    var k: usize = 0;
    while (k < WORD_DIFF_TOKEN_CAP) : (k += 1) {
        src[n] = 'a';
        src[n + 1] = ' ';
        n += 2;
    }
    const big = src[0..n];
    var buf: [4]Seg = undefined;
    try testing.expect(wordDiffSegments(big, big, &buf) == null);
}

test "changeRatioPercent: multi-segment changed length sums both edits" {
    // Two small edits on a long shared line: the ratio stays well under
    // the threshold because the shared " to " in the middle is not counted.
    const pct = changeRatioPercent("rename foo to bar", "rename baz to qux");
    try testing.expect(pct < CHANGE_THRESHOLD_PERCENT);
}
