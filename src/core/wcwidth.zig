const std = @import("std");

/// Approximate terminal cell width of a UTF-8 string. Iterates by
/// grapheme cluster so that the three multi-codepoint cases the
/// reference (`stringWidth.ts`) calls out are measured correctly:
/// regional-indicator pairs (flags) count as one width-2 glyph, ZWJ
/// emoji sequences collapse to one width-2 glyph instead of summing
/// each member, and keycap sequences (`digit [+ VS16] + U+20E3`) count
/// as width 2 while an incomplete keycap stays width 1. Everything
/// else falls through to the fast per-codepoint `codepointWidth`.
/// Invalid UTF-8 bytes count as width 1 so truncation never
/// undershoots.
///
/// This is an approximation — full wcwidth / Unicode East Asian Width
/// tables cover thousands of code points across many blocks and would
/// dwarf the rest of the module. Instead we cover the ranges that
/// actually show up in CLI output: ASCII, common Latin accents, the
/// CJK / Hangul blocks, emoji, wide-form punctuation, and the common
/// zero-width combining ranges. Edge-case Unicode (rarely-used
/// combining marks, Mongolian variation selectors, etc.) may be off
/// by a cell, which is the same accuracy real terminals exhibit.
pub fn displayWidth(s: []const u8) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const first = decodeAt(s, i);
        if (!first.valid) {
            // Invalid UTF-8: count one cell and skip one byte so we
            // never undershoot and never stall.
            total += 1;
            i += 1;
            continue;
        }

        // ASCII fast path: the overwhelmingly common case in prose and
        // source. The one multi-codepoint cluster an ASCII scalar can
        // head is a keycap (`digit`/`#`/`*` + optional VS16 + U+20E3),
        // which renders as a single width-2 glyph. An incomplete keycap
        // (the VS16 but no enclosing U+20E3) stays the base's own width.
        if (first.cp < 0x80) {
            if (isKeycapBase(first.cp)) {
                if (keycapCluster(s, first)) |kc| {
                    total += 2;
                    i = kc;
                    continue;
                }
            }
            total += codepointWidth(first.cp);
            i = first.next;
            continue;
        }

        const cluster = graphemeCluster(s, first);
        total += cluster.width;
        i = cluster.next;
    }
    return total;
}

const Decoded = struct {
    cp: u21,
    next: usize, // byte index just past this codepoint
    valid: bool,
};

/// Decode the codepoint at byte offset `i`. On any malformed sequence
/// returns `valid = false` with `next = i + 1` so callers advance one
/// byte and count it as a single cell.
fn decodeAt(s: []const u8, i: usize) Decoded {
    if (i >= s.len) {
        return .{ .cp = 0, .next = i, .valid = false };
    }
    const seq_len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
        return .{ .cp = 0, .next = i + 1, .valid = false };
    };
    if (i + seq_len > s.len) {
        return .{ .cp = 0, .next = i + 1, .valid = false };
    }
    const cp = std.unicode.utf8Decode(s[i .. i + seq_len]) catch {
        return .{ .cp = 0, .next = i + seq_len, .valid = false };
    };
    return .{ .cp = cp, .next = i + seq_len, .valid = true };
}

const Cluster = struct {
    width: usize,
    next: usize, // byte index just past the whole cluster
};

inline fn isRegionalIndicator(cp: u21) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

/// A keycap base is one of `0`..`9`, `#`, or `*`. When followed by an
/// optional VS16 then the combining enclosing keycap U+20E3, the whole
/// thing renders as one width-2 glyph.
inline fn isKeycapBase(cp: u21) bool {
    return (cp >= '0' and cp <= '9') or cp == '#' or cp == '*';
}

/// Given a keycap base already decoded as `first`, return the byte
/// index just past a complete keycap cluster (base [+ VS16] + U+20E3),
/// or `null` if the trailing U+20E3 is absent (incomplete keycap).
fn keycapCluster(s: []const u8, first: Decoded) ?usize {
    var idx = first.next;
    const maybe_vs = decodeAt(s, idx);
    if (maybe_vs.valid and maybe_vs.cp == 0xFE0F) {
        idx = maybe_vs.next;
    }
    const enclose = decodeAt(s, idx);
    if (enclose.valid and enclose.cp == 0x20E3) {
        return enclose.next;
    }
    return null;
}

/// True for code points that can sit at the head of an emoji ZWJ
/// sequence or be promoted to width 2 by a following VS16. We reuse
/// the same broad emoji ranges `codepointWidth` already treats as
/// wide, which is the conservative behaviour real terminals exhibit.
inline fn isEmojiBase(cp: u21) bool {
    if (inRange(cp, 0x1F000, 0x1FFFF)) return true;
    if (inRange(cp, 0x2600, 0x26FF)) return true; // Misc Symbols
    if (inRange(cp, 0x2700, 0x27BF)) return true; // Dingbats
    return false;
}

/// Measure one grapheme cluster, given the already-decoded leading
/// codepoint `first`. Handles the regional-indicator pair and ZWJ
/// sequence cases (keycap clusters are headed by an ASCII base and so
/// are handled on `displayWidth`'s fast path); otherwise returns the
/// single leading codepoint with any trailing zero-width combining
/// marks folded in.
fn graphemeCluster(s: []const u8, first: Decoded) Cluster {
    // Regional-indicator pair -> one flag, width 2. A lone regional
    // indicator stays width 1 (codepointWidth maps it to 2 via the
    // 0x1F000.. range, so cap it to 1 here for the single case).
    if (isRegionalIndicator(first.cp)) {
        const second = decodeAt(s, first.next);
        if (second.valid and isRegionalIndicator(second.cp)) {
            return .{ .width = 2, .next = second.next };
        }
        return .{ .width = 1, .next = first.next };
    }

    if (isEmojiBase(first.cp)) {
        // An emoji base is width 2. Fold any run of {ZWJ + emoji} and
        // trailing variation selectors into the one cluster so the
        // joined sequence (e.g. family `👨‍👩‍👧`) collapses to a single
        // width-2 glyph instead of summing each member.
        var idx = first.next;
        while (true) {
            const nx = decodeAt(s, idx);
            if (!nx.valid) break;
            if (nx.cp == 0x200D) {
                // ZWJ: must be followed by another joinable scalar.
                const member = decodeAt(s, nx.next);
                if (!member.valid) break;
                idx = member.next;
                // Skip a trailing VS16 on the joined member.
                const vs = decodeAt(s, idx);
                if (vs.valid and vs.cp == 0xFE0F) idx = vs.next;
                continue;
            }
            if (nx.cp == 0xFE0F or nx.cp == 0xFE0E) {
                // Variation selector on the base: absorb, width stays 2.
                idx = nx.next;
                continue;
            }
            break;
        }
        return .{ .width = 2, .next = idx };
    }

    // Default: width of the leading codepoint plus any immediately
    // following zero-width combining marks / VS16 (which fold in).
    var width = codepointWidth(first.cp);
    var idx = first.next;
    while (true) {
        const nx = decodeAt(s, idx);
        if (!nx.valid) break;
        // VS16 promotes a default-narrow symbol to width 2.
        if (nx.cp == 0xFE0F and width == 1) {
            width = 2;
            idx = nx.next;
            continue;
        }
        if (codepointWidth(nx.cp) == 0 and isCombining(nx.cp)) {
            idx = nx.next;
            continue;
        }
        break;
    }
    return .{ .width = width, .next = idx };
}

/// True for the zero-width combining ranges (Mn / Me / VS / ZWJ) that
/// fold into the preceding base. Mirrors the zero-width arm of
/// `codepointWidth` but excludes control codes (which are not part of
/// a grapheme cluster).
fn isCombining(cp: u21) bool {
    if (inRange(cp, 0x0300, 0x036F)) return true;
    if (inRange(cp, 0x0483, 0x0489)) return true;
    if (inRange(cp, 0x0591, 0x05BD)) return true;
    if (cp == 0x05BF) return true;
    if (inRange(cp, 0x05C1, 0x05C2)) return true;
    if (inRange(cp, 0x05C4, 0x05C5)) return true;
    if (cp == 0x05C7) return true;
    if (inRange(cp, 0x0610, 0x061A)) return true;
    if (inRange(cp, 0x064B, 0x065F)) return true;
    if (cp == 0x0670) return true;
    if (inRange(cp, 0x06D6, 0x06DC)) return true;
    if (inRange(cp, 0x06DF, 0x06E4)) return true;
    if (inRange(cp, 0x06E7, 0x06E8)) return true;
    if (inRange(cp, 0x06EA, 0x06ED)) return true;
    if (inRange(cp, 0x1AB0, 0x1AFF)) return true;
    if (inRange(cp, 0x1DC0, 0x1DFF)) return true;
    if (cp == 0x200B or cp == 0x200C or cp == 0x200D) return true;
    if (inRange(cp, 0x20D0, 0x20FF)) return true;
    if (inRange(cp, 0xFE00, 0xFE0F)) return true;
    if (inRange(cp, 0xFE20, 0xFE2F)) return true;
    if (inRange(cp, 0xE0100, 0xE01EF)) return true;
    return false;
}

/// Width of one Unicode scalar in terminal cells. 0 for combining
/// marks and control codes, 1 for "narrow" / ASCII / Latin, 2 for
/// "wide" (CJK, emoji, full-width forms).
pub fn codepointWidth(cp: u21) usize {
    // C0 / C1 control codes.
    if (cp < 0x20 or (cp >= 0x7F and cp < 0xA0)) return 0;

    // Common combining marks (Mn / Me). The subset below covers
    // every mark zcode realistically renders from markdown source
    // plus Latin diacritics that modern editors produce.
    if (inRange(cp, 0x0300, 0x036F)) return 0; // Combining Diacritical Marks
    if (inRange(cp, 0x0483, 0x0489)) return 0; // Cyrillic combining
    if (inRange(cp, 0x0591, 0x05BD)) return 0; // Hebrew points
    if (cp == 0x05BF) return 0;
    if (inRange(cp, 0x05C1, 0x05C2)) return 0;
    if (inRange(cp, 0x05C4, 0x05C5)) return 0;
    if (cp == 0x05C7) return 0;
    if (inRange(cp, 0x0610, 0x061A)) return 0;
    if (inRange(cp, 0x064B, 0x065F)) return 0; // Arabic harakat
    if (cp == 0x0670) return 0;
    if (inRange(cp, 0x06D6, 0x06DC)) return 0;
    if (inRange(cp, 0x06DF, 0x06E4)) return 0;
    if (inRange(cp, 0x06E7, 0x06E8)) return 0;
    if (inRange(cp, 0x06EA, 0x06ED)) return 0;
    if (inRange(cp, 0x1AB0, 0x1AFF)) return 0; // Combining Marks Extended
    if (inRange(cp, 0x1DC0, 0x1DFF)) return 0; // Combining Marks Supplement
    if (cp == 0x200B or cp == 0x200C or cp == 0x200D) return 0; // ZWSP/ZWNJ/ZWJ
    if (inRange(cp, 0x20D0, 0x20FF)) return 0; // Combining Marks for Symbols
    if (inRange(cp, 0xFE00, 0xFE0F)) return 0; // Variation selectors
    if (inRange(cp, 0xFE20, 0xFE2F)) return 0; // Combining Half Marks
    if (inRange(cp, 0xE0100, 0xE01EF)) return 0; // Variation Selectors Supplement

    // East Asian Wide / Fullwidth (W and F categories).
    if (inRange(cp, 0x1100, 0x115F)) return 2; // Hangul Jamo
    if (inRange(cp, 0x2329, 0x232A)) return 2;
    if (inRange(cp, 0x2E80, 0x303E)) return 2; // CJK Radicals / Kangxi
    if (inRange(cp, 0x3041, 0x33FF)) return 2; // Hiragana, Katakana, Bopomofo
    if (inRange(cp, 0x3400, 0x4DBF)) return 2; // CJK Extension A
    if (inRange(cp, 0x4E00, 0x9FFF)) return 2; // CJK Unified Ideographs
    if (inRange(cp, 0xA000, 0xA4CF)) return 2; // Yi
    if (inRange(cp, 0xAC00, 0xD7A3)) return 2; // Hangul Syllables
    if (inRange(cp, 0xF900, 0xFAFF)) return 2; // CJK Compatibility Ideographs
    if (inRange(cp, 0xFE30, 0xFE4F)) return 2; // CJK Compatibility Forms
    if (inRange(cp, 0xFE68, 0xFE6B)) return 2; // Small Form Variants (partial)
    if (inRange(cp, 0xFF00, 0xFF60)) return 2; // Fullwidth Forms
    if (inRange(cp, 0xFFE0, 0xFFE6)) return 2; // Fullwidth Signs

    // Emoji — broad heuristic. Most user-visible emoji live in these
    // ranges; we accept a tiny number of false positives in symbol
    // blocks that terminals also render as wide, so this is
    // conservatively correct.
    if (inRange(cp, 0x1F000, 0x1FFFF)) return 2;
    if (inRange(cp, 0x20000, 0x2FFFD)) return 2; // CJK Extensions B-F
    if (inRange(cp, 0x30000, 0x3FFFD)) return 2; // CJK Extension G
    if (inRange(cp, 0x2600, 0x26FF)) return 2; // Misc Symbols (some emoji)
    if (inRange(cp, 0x2700, 0x27BF)) return 2; // Dingbats (some emoji)

    return 1;
}

inline fn inRange(cp: u21, lo: u21, hi: u21) bool {
    return cp >= lo and cp <= hi;
}

/// Truncate `s` so that its `displayWidth` is at most `max_cells`,
/// stopping at codepoint boundaries (no torn UTF-8). Returns the
/// longest prefix that fits.
pub fn truncateToWidth(s: []const u8, max_cells: usize) []const u8 {
    var used: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const end = @min(s.len, i + seq_len);
        const cp = std.unicode.utf8Decode(s[i..end]) catch {
            if (used + 1 > max_cells) return s[0..i];
            used += 1;
            i = end;
            continue;
        };
        const w = codepointWidth(cp);
        if (used + w > max_cells) return s[0..i];
        used += w;
        i = end;
    }
    return s;
}

const testing = std.testing;

test "ASCII width matches byte length" {
    try testing.expectEqual(@as(usize, 5), displayWidth("hello"));
    try testing.expectEqual(@as(usize, 0), displayWidth(""));
}

test "CJK codepoints count as two cells" {
    try testing.expectEqual(@as(usize, 2), displayWidth("中"));
    try testing.expectEqual(@as(usize, 4), displayWidth("中国"));
    // 中(2) + space(1) + o(1) + k(1) = 5.
    try testing.expectEqual(@as(usize, 5), displayWidth("中 ok"));
}

test "combining marks contribute zero" {
    // "é" as e + combining acute accent (U+0301).
    try testing.expectEqual(@as(usize, 1), displayWidth("e\u{0301}"));
}

test "ZWJ and variation selectors are zero-width" {
    try testing.expectEqual(@as(usize, 0), displayWidth("\u{200D}"));
    try testing.expectEqual(@as(usize, 0), displayWidth("\u{FE0F}"));
}

test "emoji count as two cells" {
    try testing.expectEqual(@as(usize, 2), displayWidth("\u{1F600}")); // grinning face
    try testing.expectEqual(@as(usize, 2), displayWidth("\u{1F4BB}")); // laptop
}

test "truncateToWidth stops at codepoint boundaries" {
    const cjk = "中国abc";
    // 中 = 2, 国 = 2, a = 1, b = 1, c = 1 -> total 7.
    // max_cells=5: 中(2) + 国(2) + a(1) = 5 exactly; b would overflow.
    try testing.expectEqualStrings("中国a", truncateToWidth(cjk, 5));
    try testing.expectEqualStrings("中国abc", truncateToWidth(cjk, 7));
    try testing.expectEqualStrings("中国abc", truncateToWidth(cjk, 10));
    // max_cells=3: 中(2) fits; 国 would overflow (2+2 > 3).
    try testing.expectEqualStrings("中", truncateToWidth(cjk, 3));
}

test "invalid UTF-8 counts as one cell" {
    const bad = "\xff\xfe";
    try testing.expectEqual(@as(usize, 2), displayWidth(bad));
}

test "regional-indicator pair is one width-2 flag" {
    // U+1F1FA U+1F1F8 -> flag of the United States.
    try testing.expectEqual(@as(usize, 2), displayWidth("\u{1F1FA}\u{1F1F8}"));
    // Two complete flags side by side -> 4, not 8.
    try testing.expectEqual(@as(usize, 4), displayWidth("\u{1F1FA}\u{1F1F8}\u{1F1EF}\u{1F1F5}"));
}

test "single regional indicator is width 1" {
    try testing.expectEqual(@as(usize, 1), displayWidth("\u{1F1FA}"));
}

test "ZWJ emoji sequence collapses to one glyph" {
    // Family: man + ZWJ + woman + ZWJ + girl -> one width-2 glyph.
    try testing.expectEqual(@as(usize, 2), displayWidth("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"));
}

test "keycap sequence is width 2, incomplete keycap is width 1" {
    // 1 + VS16 + U+20E3 (keycap digit one).
    try testing.expectEqual(@as(usize, 2), displayWidth("1\u{FE0F}\u{20E3}"));
    // Incomplete keycap: base + VS16 with no enclosing keycap.
    try testing.expectEqual(@as(usize, 1), displayWidth("1\u{FE0F}"));
    // Keycap without the VS16 still completes via U+20E3.
    try testing.expectEqual(@as(usize, 2), displayWidth("#\u{20E3}"));
}

test "keycap embedded in surrounding text measures correctly" {
    // "a" (1) + keycap (2) + "b" (1) = 4.
    try testing.expectEqual(@as(usize, 4), displayWidth("a1\u{FE0F}\u{20E3}b"));
}
