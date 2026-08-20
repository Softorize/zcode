const std = @import("std");

/// Ported from claude-code-main/src/utils/tokenBudget.ts.
///
/// Lets a user signal a per-turn token budget inline in their prompt:
///
///     +500k    -- shorthand at start or end of the message
///     use 2m tokens     -- verbose form, matches anywhere
///     spend 1.5k tokens -- verbose form
///
/// The budget is a positive integer (after multiplier expansion) and
/// drives upstream compaction / early-stop behaviour. This module only
/// implements the parser; consumers decide what to do with the value.
///
/// Multipliers are case-insensitive:
///   k = 1_000
///   m = 1_000_000
///   b = 1_000_000_000
///
/// The shorthand forms are deliberately anchored to the start or end of
/// the text so that "+500k" is detected but "the file is +500k bytes"
/// (mid-sentence) is not. The verbose form matches anywhere because
/// "please use 2m tokens" in the middle of a paragraph is unambiguous.
const MULT_K: u64 = 1_000;
const MULT_M: u64 = 1_000_000;
const MULT_B: u64 = 1_000_000_000;

/// Try to parse a budget from `text`. Returns null if no budget marker
/// is present. Tries the three forms in the reference's priority order:
/// shorthand-at-start, shorthand-at-end, verbose.
pub fn parseTokenBudget(text: []const u8) ?u64 {
    if (parseShorthandStart(text)) |n| return n;
    if (parseShorthandEnd(text)) |n| return n;
    if (parseVerbose(text)) |n| return n;
    return null;
}

/// Locate any budget markers in `text` and write their positions into
/// `out`. Returns the number written. The reference returns a list of
/// `{start, end}` objects; in Zig we take an output buffer to avoid a
/// heap allocation for a single-element list.
pub const Span = struct { start: usize, end: usize };

pub fn findTokenBudgetPositions(text: []const u8, out: []Span) usize {
    var count: usize = 0;
    var start_end: ?Span = null;

    if (findShorthandStart(text)) |span| {
        if (count < out.len) {
            out[count] = span;
            count += 1;
            start_end = span;
        }
    }
    if (findShorthandEnd(text)) |span| {
        // Avoid double-counting when input is just "+500k" -- in that
        // case the start and end regexes both match the same bytes.
        const already_covered = if (start_end) |s| span.start >= s.start and span.start < s.end else false;
        if (!already_covered and count < out.len) {
            out[count] = span;
            count += 1;
        }
    }
    // Verbose matches are enumerated globally.
    var cursor: usize = 0;
    while (cursor < text.len) {
        if (findVerboseFrom(text, cursor)) |span| {
            if (count < out.len) {
                out[count] = span;
                count += 1;
            }
            cursor = span.end;
        } else break;
    }
    return count;
}

// ---------------------------------------------------------------------
// Shorthand parsing: "+500k" at start or end of input.
// ---------------------------------------------------------------------

fn parseShorthandStart(text: []const u8) ?u64 {
    var i: usize = 0;
    while (i < text.len and isInlineSpace(text[i])) : (i += 1) {}
    if (i >= text.len or text[i] != '+') return null;
    i += 1;
    return parseNumberWithSuffix(text, i);
}

fn findShorthandStart(text: []const u8) ?Span {
    var i: usize = 0;
    const ws_end = blk: {
        while (i < text.len and isInlineSpace(text[i])) : (i += 1) {}
        break :blk i;
    };
    const payload_start = ws_end;
    if (payload_start >= text.len or text[payload_start] != '+') return null;
    const end = scanNumberWithSuffixEnd(text, payload_start + 1) orelse return null;
    // Ensure there's a word boundary after the suffix (either end or
    // a non-alnum). Matches the reference's \b after (k|m|b).
    if (end < text.len and isAlnum(text[end])) return null;
    return Span{ .start = payload_start, .end = end };
}

fn parseShorthandEnd(text: []const u8) ?u64 {
    const span = findShorthandEndInternal(text, true) orelse return null;
    const val_end = scanNumberWithSuffixEnd(text, span.start + 1) orelse return null;
    return parseNumberWithSuffix(text, span.start + 1) orelse scanValue(text, span.start + 1, val_end);
}

fn findShorthandEnd(text: []const u8) ?Span {
    return findShorthandEndInternal(text, true);
}

// Walk backwards from the end looking for:
//   \s+ N(.N)? (k|m|b) \s* [.!?]? \s* $
// where the `\s` before the `+` is mandatory so we don't collide with
// a mid-sentence "foo+500k" (which the reference's regex also rejects).
fn findShorthandEndInternal(text: []const u8, require_leading_space: bool) ?Span {
    if (text.len == 0) return null;

    var end = text.len;
    // Trim trailing whitespace.
    while (end > 0 and isInlineSpace(text[end - 1])) end -= 1;
    // Optional trailing punctuation (. ! ?).
    if (end > 0 and (text[end - 1] == '.' or text[end - 1] == '!' or text[end - 1] == '?')) end -= 1;
    // Trim any whitespace between the number and the punctuation.
    while (end > 0 and isInlineSpace(text[end - 1])) end -= 1;
    if (end == 0) return null;

    // Suffix must be k, m, or b.
    const suffix_ch = std.ascii.toLower(text[end - 1]);
    if (suffix_ch != 'k' and suffix_ch != 'm' and suffix_ch != 'b') return null;
    const number_end = end - 1;
    _ = number_end;
    // Walk back over digits and optional decimal.
    var saw_digit = false;
    var saw_dot = false;
    var idx: usize = end - 1;
    while (idx > 0) : (idx -= 1) {
        const c = text[idx - 1];
        if (c >= '0' and c <= '9') {
            saw_digit = true;
            continue;
        }
        if (c == '.' and !saw_dot) {
            saw_dot = true;
            continue;
        }
        break;
    }
    const number_start = idx;
    if (!saw_digit) return null;

    // Must be preceded by '+'.
    if (number_start == 0 or text[number_start - 1] != '+') return null;
    const plus_pos = number_start - 1;

    // Must be preceded by whitespace or start-of-string.
    if (require_leading_space) {
        if (plus_pos > 0 and !isInlineSpace(text[plus_pos - 1])) return null;
    }

    return Span{ .start = plus_pos, .end = end };
}

// ---------------------------------------------------------------------
// Verbose parsing: "use 2m tokens" / "spend 1.5k tokens".
// ---------------------------------------------------------------------

fn parseVerbose(text: []const u8) ?u64 {
    const span = findVerboseFrom(text, 0) orelse return null;
    // Span covers "use NN[.N]?[kmb] tokens[?s]?" -- re-parse the numeric
    // middle to extract the value. Find the first digit after the verb.
    var i = span.start;
    while (i < span.end and !isDigit(text[i])) i += 1;
    return parseNumberWithSuffix(text, i);
}

fn findVerboseFrom(text: []const u8, start: usize) ?Span {
    const verbs = [_][]const u8{ "use", "spend" };
    var i: usize = start;
    while (i < text.len) : (i += 1) {
        // Must be word-boundary before the verb.
        if (i > 0 and isWordChar(text[i - 1])) continue;

        for (verbs) |verb| {
            if (i + verb.len > text.len) continue;
            if (!std.ascii.eqlIgnoreCase(text[i .. i + verb.len], verb)) continue;
            if (i + verb.len < text.len and isWordChar(text[i + verb.len])) continue;
            // Skip required whitespace.
            var j = i + verb.len;
            const ws_start = j;
            while (j < text.len and isInlineSpace(text[j])) j += 1;
            if (j == ws_start) continue; // need at least one space
            // Parse number with suffix.
            const num_end = scanNumberWithSuffixEnd(text, j) orelse continue;
            // Optional whitespace, then "tokens" or "token".
            var k = num_end;
            while (k < text.len and isInlineSpace(text[k])) k += 1;
            const remaining = text[k..];
            const tok_len: usize = blk: {
                if (remaining.len >= 6 and std.ascii.eqlIgnoreCase(remaining[0..6], "tokens")) {
                    if (remaining.len == 6 or !isWordChar(remaining[6])) break :blk 6;
                }
                if (remaining.len >= 5 and std.ascii.eqlIgnoreCase(remaining[0..5], "token")) {
                    if (remaining.len == 5 or !isWordChar(remaining[5])) break :blk 5;
                }
                break :blk 0;
            };
            if (tok_len == 0) continue;
            return Span{ .start = i, .end = k + tok_len };
        }
    }
    return null;
}

// ---------------------------------------------------------------------
// Number + suffix helpers.
// ---------------------------------------------------------------------

fn parseNumberWithSuffix(text: []const u8, start: usize) ?u64 {
    const end = scanNumberWithSuffixEnd(text, start) orelse return null;
    return scanValue(text, start, end);
}

fn scanNumberWithSuffixEnd(text: []const u8, start: usize) ?usize {
    var i: usize = start;
    var saw_digit = false;
    while (i < text.len and isDigit(text[i])) : (i += 1) saw_digit = true;
    if (i < text.len and text[i] == '.') {
        i += 1;
        while (i < text.len and isDigit(text[i])) : (i += 1) saw_digit = true;
    }
    if (!saw_digit) return null;
    // Optional whitespace between the number and the suffix.
    while (i < text.len and isInlineSpace(text[i])) : (i += 1) {}
    if (i >= text.len) return null;
    const suffix = std.ascii.toLower(text[i]);
    if (suffix != 'k' and suffix != 'm' and suffix != 'b') return null;
    return i + 1;
}

fn scanValue(text: []const u8, start: usize, end: usize) ?u64 {
    // end is the index just past the suffix character. Walk back to
    // find the number boundaries.
    if (end == 0 or end <= start) return null;
    const suffix = std.ascii.toLower(text[end - 1]);
    const multiplier: u64 = switch (suffix) {
        'k' => MULT_K,
        'm' => MULT_M,
        'b' => MULT_B,
        else => return null,
    };

    // Skip whitespace between number and suffix.
    var num_end = end - 1;
    while (num_end > start and isInlineSpace(text[num_end - 1])) num_end -= 1;
    const num_slice = text[start..num_end];
    if (num_slice.len == 0) return null;

    const dot_idx = std.mem.indexOfScalar(u8, num_slice, '.');
    if (dot_idx) |idx| {
        const whole = std.fmt.parseInt(u64, num_slice[0..idx], 10) catch return null;
        const frac_str = num_slice[idx + 1 ..];
        if (frac_str.len == 0) {
            return std.math.mul(u64, whole, multiplier) catch return null;
        }
        const frac = std.fmt.parseInt(u64, frac_str, 10) catch return null;
        // Cap fractional digits at 9: any precision beyond nanoseconds-per-billion
        // is noise for token budgets and would overflow u64 on denom *= 10.
        if (frac_str.len > 9) return null;
        // Scale frac so 1.5k -> 1500: value = whole*mult + frac*(mult/10^digits)
        var denom: u64 = 1;
        for (0..frac_str.len) |_| denom *= 10;
        const whole_part = std.math.mul(u64, whole, multiplier) catch return null;
        const frac_scaled = std.math.mul(u64, frac, multiplier) catch return null;
        return std.math.add(u64, whole_part, frac_scaled / denom) catch return null;
    }
    const whole = std.fmt.parseInt(u64, num_slice, 10) catch return null;
    return std.math.mul(u64, whole, multiplier) catch return null;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isAlnum(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isWordChar(c: u8) bool {
    return isAlnum(c) or c == '_';
}

fn isInlineSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

const testing = std.testing;

test "parseTokenBudget handles shorthand at start" {
    try testing.expectEqual(@as(u64, 500_000), parseTokenBudget("+500k fix the thing").?);
    try testing.expectEqual(@as(u64, 2_000_000), parseTokenBudget("+2m refactor").?);
    try testing.expectEqual(@as(u64, 1_500_000), parseTokenBudget("+1.5m detailed review").?);
}

test "parseTokenBudget handles shorthand at end" {
    try testing.expectEqual(@as(u64, 500_000), parseTokenBudget("fix the thing +500k").?);
    try testing.expectEqual(@as(u64, 500_000), parseTokenBudget("fix the thing +500k.").?);
    try testing.expectEqual(@as(u64, 2_500_000), parseTokenBudget("big refactor +2.5m!").?);
}

test "parseTokenBudget handles bare shorthand" {
    try testing.expectEqual(@as(u64, 500_000), parseTokenBudget("+500k").?);
    try testing.expectEqual(@as(u64, 1_000_000_000), parseTokenBudget("+1b").?);
}

test "parseTokenBudget handles verbose form" {
    try testing.expectEqual(@as(u64, 2_000_000), parseTokenBudget("please use 2m tokens").?);
    try testing.expectEqual(@as(u64, 500_000), parseTokenBudget("spend 500k tokens on this").?);
    try testing.expectEqual(@as(u64, 1_500), parseTokenBudget("use 1.5k tokens").?);
    try testing.expectEqual(@as(u64, 1_000), parseTokenBudget("use 1k token").?); // singular "token" also accepted
}

test "parseTokenBudget rejects mid-sentence shorthand" {
    // "+500k" only counts when it's at start or end, not buried mid-sentence.
    try testing.expectEqual(@as(?u64, null), parseTokenBudget("the file is +500k bytes long"));
    try testing.expectEqual(@as(?u64, null), parseTokenBudget("budget foo+500k bar"));
}

test "parseTokenBudget returns null on no marker" {
    try testing.expectEqual(@as(?u64, null), parseTokenBudget("just a normal prompt"));
    try testing.expectEqual(@as(?u64, null), parseTokenBudget(""));
}

test "parseTokenBudget is case insensitive on suffix and verb" {
    try testing.expectEqual(@as(u64, 500_000), parseTokenBudget("+500K").?);
    try testing.expectEqual(@as(u64, 2_000_000), parseTokenBudget("+2M").?);
    try testing.expectEqual(@as(u64, 1_000), parseTokenBudget("USE 1k tokens").?);
    try testing.expectEqual(@as(u64, 1_000), parseTokenBudget("Spend 1K Tokens").?);
}

test "findTokenBudgetPositions reports span of start shorthand" {
    var spans: [4]Span = undefined;
    const count = findTokenBudgetPositions("+500k go", &spans);
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqual(@as(usize, 0), spans[0].start);
    try testing.expectEqual(@as(usize, 5), spans[0].end);
}

test "findTokenBudgetPositions does not double-count bare shorthand" {
    var spans: [4]Span = undefined;
    const count = findTokenBudgetPositions("+500k", &spans);
    // Bare "+500k" matches both start and end regexes in the reference,
    // but the ported helper dedupes so we only see it once.
    try testing.expectEqual(@as(usize, 1), count);
}

test "findTokenBudgetPositions handles verbose form" {
    var spans: [4]Span = undefined;
    const count = findTokenBudgetPositions("please use 2m tokens for this", &spans);
    try testing.expectEqual(@as(usize, 1), count);
    const got = spans[0];
    // Verify the span covers "use 2m tokens".
    try testing.expectEqualStrings("use 2m tokens", "please use 2m tokens for this"[got.start..got.end]);
}

test "parseTokenBudget accepts whitespace between number and suffix" {
    // Reference's regex allows "\d+\s*(k|m|b)" -- "500 k" is a valid match.
    try testing.expectEqual(@as(u64, 500_000), parseTokenBudget("+500 k fix").?);
}
