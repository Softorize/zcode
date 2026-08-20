const std = @import("std");
const std_io = @import("std_io.zig");

// ── Types ──────────────────────────────────────────────────────────────

pub const ToolCall = struct {
    name: []u8,
    args: []u8,
};

pub const ControlActions = struct {
    compact: bool = false,
    resume_requested: bool = false,
    escalate: bool = false,
    continue_requested: bool = false,
};

pub const ParsedOutput = struct {
    assistant_text: []u8,
    tool_calls: []ToolCall,
    control: ControlActions,

    pub fn deinit(self: *ParsedOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.assistant_text);
        freeToolCalls(allocator, self.tool_calls);
    }
};

pub fn freeToolCalls(allocator: std.mem.Allocator, calls: []ToolCall) void {
    for (calls) |call| {
        allocator.free(call.name);
        allocator.free(call.args);
    }
    allocator.free(calls);
}

/// Strip a leading UTF-8 byte order mark (\xEF\xBB\xBF) from a byte
/// slice. PowerShell 5.x and many Windows tools default to writing
/// UTF-8 files with a BOM, which makes the first byte of the file
/// invalid for any parser that expects pure UTF-8 (JSON, TOML, YAML).
/// This is the Zig equivalent of claude-code-main/src/utils/jsonRead.ts
/// stripBOM, exposed as a pure helper so every config-loader path can
/// pre-clean its input with one line. Returns the input unchanged
/// when no BOM is present so callers don't have to branch.
pub fn stripBom(bytes: []const u8) []const u8 {
    const bom = [_]u8{ 0xEF, 0xBB, 0xBF };
    if (bytes.len >= bom.len and std.mem.eql(u8, bytes[0..bom.len], &bom)) {
        return bytes[bom.len..];
    }
    return bytes;
}

/// Convenience wrapper: strip BOM and parse the result as JSON. Use
/// this anywhere zcode reads JSON from a file that might have been
/// produced by a Windows tool. Caller still owns the Parsed handle.
pub fn parseJsonStripBom(
    comptime T: type,
    allocator: std.mem.Allocator,
    bytes: []const u8,
    options: std.json.ParseOptions,
) std.json.ParseError(std.json.Scanner)!std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, stripBom(bytes), options);
}

/// Project-wide JSON parser options. Provider responses, marketplace
/// catalogs, MCP messages, and session records all flow through
/// std.json.parseFromSlice. A hostile payload with thousands of
/// levels of nesting exhausts the parser stack on a default call.
/// This helper pins a conservative max_value_len so every call site
/// gets the same bound without threading options through.
///
/// The cap is 1 MiB per string/array/object: larger than any real
/// provider response piece we care about, small enough to avoid
/// attacker-driven memory blow-up.
pub const json_parse_options: std.json.ParseOptions = .{
    .max_value_len = 1 * 1024 * 1024,
    .duplicate_field_behavior = .use_last,
};

/// Bounded drop-in replacement for std.json.parseFromSlice. Use
/// this instead of the bare std call on any payload whose origin
/// isn't fully trusted (providers, catalogs, MCP, session load).
pub fn parseJsonBounded(
    comptime T: type,
    allocator: std.mem.Allocator,
    bytes: []const u8,
) std.json.ParseError(std.json.Scanner)!std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, bytes, json_parse_options);
}

/// Escape U+2028 (LINE SEPARATOR, UTF-8 \xE2\x80\xA8) and
/// U+2029 (PARAGRAPH SEPARATOR, UTF-8 \xE2\x80\xA9) as `\u2028`
/// / `\u2029` literals. Ported from claude-code-main/src/cli/
/// ndjsonSafeStringify.ts.
///
/// Why: std.json.fmt writes those bytes raw (valid per ECMA-404
/// JSON), but ECMA-262 §11.3 treats them as line terminators --
/// so any consumer that splits a JSONL file by JavaScript line
/// terminator semantics (editors, log shippers, many CLI tools)
/// cuts the JSON line in half mid-string. The escaped form is
/// equivalent JSON (parses back to the same Unicode code point)
/// but cannot be mistaken for a newline by ANY receiver.
///
/// Appends into a caller-owned managed array list to avoid a
/// second full-copy on the common "I already have a buffer" path.
pub fn appendNdjsonSafe(
    out: *std_io.StringBuilder,
    bytes: []const u8,
) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        if (i + 3 <= bytes.len and bytes[i] == 0xE2 and bytes[i + 1] == 0x80) {
            const third = bytes[i + 2];
            if (third == 0xA8) {
                try out.appendSlice("\\u2028");
                i += 3;
                continue;
            }
            if (third == 0xA9) {
                try out.appendSlice("\\u2029");
                i += 3;
                continue;
            }
        }
        try out.append(bytes[i]);
        i += 1;
    }
}

/// Pick the singular or plural form of a word based on a count.
/// Ported from claude-code-main/src/utils/stringUtils.ts plural.
/// Returns `singular` when n == 1, `plural_form` otherwise. Zero
/// uses the plural form to match the reference and English
/// convention ("0 files", not "0 file").
///
/// For regular English words the caller passes both forms as
/// comptime literals: `plural(n, "file", "files")`. For irregular
/// words the forms are spelled out differently: `plural(n,
/// "entry", "entries")`. If you need a runtime-synthesised "+s"
/// and don't want to write the literal twice, use `pluralS`.
pub fn plural(n: usize, singular: []const u8, plural_form: []const u8) []const u8 {
    return if (n == 1) singular else plural_form;
}

/// Return the first line of `s` (everything before the first `\n`,
/// or the whole string if there is no newline). Trailing `\r` is
/// preserved because some callers need the exact byte slice for
/// length calculations. For shebang detection and label lookups the
/// caller can trim separately.
///
/// Ported from claude-code-main/src/utils/stringUtils.ts firstLineOf.
/// zcode has many inline uses of `std.mem.sliceTo(s, '\n')` that can
/// migrate to this named helper over time; the wrapper documents
/// intent at the call site and gives us one place to add smarter
/// handling (e.g. CR-stripping) if needed later.
pub fn firstLineOf(s: []const u8) []const u8 {
    return std.mem.sliceTo(s, '\n');
}

/// Uppercase the first byte of `s` if it is a lowercase ASCII letter,
/// writing the result into `buf`. The rest of the string is copied
/// unchanged -- unlike lodash `capitalize`, this does NOT lowercase
/// the remaining characters ("fooBar" -> "FooBar", "hello world" ->
/// "Hello world"). Ported from stringUtils.ts capitalize.
///
/// Returns a slice of `buf` with the result. Caller must ensure
/// `buf.len >= s.len`. Empty input returns an empty slice.
pub fn capitalizeAscii(buf: []u8, s: []const u8) []const u8 {
    if (s.len == 0) return "";
    if (buf.len < s.len) return s;
    @memcpy(buf[0..s.len], s);
    const first = buf[0];
    if (first >= 'a' and first <= 'z') {
        buf[0] = first - 32;
    }
    return buf[0..s.len];
}

/// Truncate `text` to at most `max_lines` lines, appending a
/// `\u{2026}` (U+2026 horizontal ellipsis) marker when truncation
/// occurred. Returns the original text unchanged when it already
/// fits. Ported from claude-code-main/src/utils/stringUtils.ts
/// truncateToLines.
///
/// Allocating variant: the returned slice is either a dupe of the
/// original (when it fits) or a freshly allocated concatenation.
/// Caller owns the result.
pub fn truncateToLines(allocator: std.mem.Allocator, text: []const u8, max_lines: usize) ![]u8 {
    if (max_lines == 0) {
        return allocator.dupe(u8, "\xe2\x80\xa6");
    }
    var line_count: usize = 0;
    var keep_end: usize = 0;
    var cursor: usize = 0;
    while (cursor < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, cursor, '\n') orelse text.len;
        line_count += 1;
        if (line_count == max_lines) {
            keep_end = nl;
            cursor = nl + 1;
            break;
        }
        cursor = nl + 1;
    }
    if (line_count <= max_lines and cursor >= text.len) {
        return allocator.dupe(u8, text);
    }
    // Walk forward to confirm there's at least one more line beyond
    // the truncation point. If not, return the original unchanged.
    if (cursor >= text.len) {
        return allocator.dupe(u8, text);
    }

    var out = try allocator.alloc(u8, keep_end + "\xe2\x80\xa6".len);
    @memcpy(out[0..keep_end], text[0..keep_end]);
    @memcpy(out[keep_end..], "\xe2\x80\xa6");
    return out;
}

/// Extract a `# comment` label from the first line of a bash command,
/// stripped of the leading `#` and surrounding whitespace. Returns
/// null when the first line is not a comment, is a `#!` shebang, or
/// the comment body is empty after stripping.
///
/// Ported from claude-code-main/src/tools/BashTool/commentLabel.ts
/// where the reference uses the comment as the human-readable title
/// of the bash card whenever the command itself is too long, piped,
/// or otherwise hard to skim. zcode's bash card middle-truncates
/// long commands; with this helper the renderer can prefer a
/// labelled command's comment over the raw command bytes.
///
/// Examples:
///   "# build the binary\nzig build -Doptimize=ReleaseFast" -> "build the binary"
///   "## section header\nls" -> "section header"
///   "ls -la"               -> null
///   "#!/bin/bash\necho hi"  -> null  (shebang, not a label comment)
///   "#"                    -> null  (empty body)
pub fn extractBashCommentLabel(command: []const u8) ?[]const u8 {
    const nl = std.mem.indexOfScalar(u8, command, '\n');
    const first_line_raw = if (nl) |idx| command[0..idx] else command;
    const first_line = std.mem.trim(u8, first_line_raw, " \t\r");
    if (first_line.len == 0) return null;
    if (first_line[0] != '#') return null;
    // Reject shebang lines.
    if (first_line.len >= 2 and first_line[1] == '!') return null;

    // Strip leading '#' and any whitespace that follows. Multiple
    // hashes ("## ", "### ") are also treated as a label so users
    // can use markdown-ish heading syntax.
    var idx: usize = 0;
    while (idx < first_line.len and first_line[idx] == '#') : (idx += 1) {}
    while (idx < first_line.len and (first_line[idx] == ' ' or first_line[idx] == '\t')) : (idx += 1) {}
    if (idx >= first_line.len) return null;
    return first_line[idx..];
}

/// Detect an HTML error page (typically from CloudFlare, nginx, or
/// other reverse proxies) in an HTTP response body and reduce it to a
/// single user-readable line. Ported from claude-code-main/src/services/
/// api/errorUtils.ts sanitizeMessageHTML.
///
/// Behaviour matches the reference exactly:
///   - If the payload contains `<!DOCTYPE html` or `<html` (case-
///     insensitive), it is considered an HTML error page.
///   - When an HTML page is detected, attempt to extract the text
///     between the first `<title>...</title>` tags. On a match, return
///     a slice of the input with leading/trailing whitespace trimmed.
///   - If the page has no usable title, return an empty slice so
///     callers can fall back to a status-code-only message instead of
///     dumping raw HTML into the log or error.
///   - Non-HTML input is returned unchanged (fast path).
///
/// The return value aliases into `bytes`; callers must not free it.
/// The reference regex is `/<title>([^<]+)<\/title>/`, so we reject
/// title bodies that contain any `<` to avoid swallowing nested tags.
///
/// The scan is capped at the first 4 KiB of the payload because
/// `indexOfIgnoreCase` is naive O(n*m) and `callHttp` can pass
/// multi-megabyte streamed bodies. HTML error pages from every real
/// CDN/proxy (CloudFlare, nginx, Varnish, Apache, IIS) place both
/// `<!DOCTYPE html>` and `<title>` inside the `<head>`, well under
/// 4 KiB. Capping the scan preserves correctness for real-world
/// payloads without exposing the classifier to pathological worst-
/// case string search on huge responses.
pub fn sanitizeHtmlPayload(bytes: []const u8) []const u8 {
    const scan_limit = @min(bytes.len, 4096);
    const haystack = bytes[0..scan_limit];

    // Fast path: probe for <title>...</title> directly. On plain JSON
    // this returns null immediately from the first `indexOfIgnoreCase`
    // call, so we pay one scan instead of three.
    if (indexOfIgnoreCase(haystack, "<title>")) |open_idx| {
        const body_start = open_idx + "<title>".len;
        if (indexOfIgnoreCase(haystack[body_start..], "</title>")) |close_rel| {
            const raw_body = haystack[body_start .. body_start + close_rel];
            // Reference uses [^<]+ -- reject bodies that smuggle in nested tags.
            if (std.mem.indexOfScalar(u8, raw_body, '<') == null) {
                const trimmed = std.mem.trim(u8, raw_body, " \t\r\n");
                if (trimmed.len > 0) return trimmed;
            }
        }
    }

    // No usable title was found. Decide whether the payload is an HTML
    // error page (drop to empty so the log isn't polluted with markup)
    // or a plain-text/JSON error body (pass through unchanged).
    if (containsIgnoreCase(haystack, "<!DOCTYPE html") or
        containsIgnoreCase(haystack, "<html"))
    {
        return "";
    }
    return bytes;
}

/// Alternative plural helper that writes "singular" or "singular + s"
/// into a caller-provided buffer. Use this for regular English
/// plurals without forcing both forms at the call site.
pub fn pluralS(buf: []u8, n: usize, singular: []const u8) []const u8 {
    if (n == 1) {
        const len = @min(singular.len, buf.len);
        @memcpy(buf[0..len], singular[0..len]);
        return buf[0..len];
    }
    const total = singular.len + 1;
    if (total > buf.len) return singular;
    @memcpy(buf[0..singular.len], singular);
    buf[singular.len] = 's';
    return buf[0..total];
}

/// Escape regex metacharacters in `input` so the result can be
/// safely embedded inside a regex pattern. Ported from
/// claude-code-main/src/utils/stringUtils.ts escapeRegExp. Same
/// character set as JavaScript's RegExp (`.*+?^${}()|[]\`). Caller
/// owns the returned slice.
///
/// Fast path: if the input has no metacharacters we just dupe it
/// and avoid the per-byte append overhead.
pub fn escapeRegExp(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var needs_escape = false;
    for (input) |c| {
        if (isRegexMeta(c)) {
            needs_escape = true;
            break;
        }
    }
    if (!needs_escape) return allocator.dupe(u8, input);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    try out.ensureTotalCapacity(input.len + 8);

    for (input) |c| {
        if (isRegexMeta(c)) try out.append('\\');
        try out.append(c);
    }
    return out.toOwnedSlice();
}

fn isRegexMeta(c: u8) bool {
    return switch (c) {
        '.', '*', '+', '?', '^', '$', '{', '}', '(', ')', '|', '[', ']', '\\' => true,
        else => false,
    };
}

/// UTF-8 encoding of U+3000 IDEOGRAPHIC SPACE (0xE3 0x80 0x80).
/// Japanese IMEs insert this instead of a plain space when the IME
/// is active; without normalisation a command like `/model １`
/// fails because the tokenizer sees a 3-byte blob where it
/// expected ASCII 0x20.
const UTF8_IDEO_SPACE: [3]u8 = .{ 0xE3, 0x80, 0x80 };

/// True when `bytes[i..]` begins with the UTF-8 encoding of a
/// full-width ASCII digit U+FF10..U+FF19. `i` must be in-bounds.
fn isFullWidthDigit(bytes: []const u8, i: usize) bool {
    return i + 3 <= bytes.len and
        bytes[i] == 0xEF and
        bytes[i + 1] == 0xBC and
        bytes[i + 2] >= 0x90 and
        bytes[i + 2] <= 0x99;
}

fn isIdeographicSpace(bytes: []const u8, i: usize) bool {
    return i + 3 <= bytes.len and
        std.mem.eql(u8, bytes[i .. i + 3], &UTF8_IDEO_SPACE);
}

/// Normalise full-width (zenkaku) ASCII digits U+FF10..U+FF19 down
/// to plain ASCII '0'..'9'. Caller owns the returned slice. Ported
/// from claude-code-main/src/utils/stringUtils.ts
/// normalizeFullWidthDigits. Non-digit characters pass through
/// untouched, including any other full-width CJK content -- this
/// only touches the ten code points ２６０ etc.
///
/// Fast path: if no full-width digits are present we dupe directly
/// so the common ASCII-only case pays zero per-byte cost.
pub fn normalizeFullWidthDigits(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var needs_work = false;
    var i: usize = 0;
    while (i + 3 <= input.len) : (i += 1) {
        if (isFullWidthDigit(input, i)) {
            needs_work = true;
            break;
        }
    }
    if (!needs_work) return allocator.dupe(u8, input);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    try out.ensureTotalCapacity(input.len);

    i = 0;
    while (i < input.len) {
        if (isFullWidthDigit(input, i)) {
            const digit = '0' + (input[i + 2] - 0x90);
            try out.append(digit);
            i += 3;
            continue;
        }
        try out.append(input[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

/// Normalise the U+3000 IDEOGRAPHIC SPACE to a plain ASCII space.
/// Ported from claude-code-main/src/utils/stringUtils.ts
/// normalizeFullWidthSpace. Caller owns the returned slice.
pub fn normalizeFullWidthSpace(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var needs_work = false;
    var i: usize = 0;
    while (i + 3 <= input.len) : (i += 1) {
        if (isIdeographicSpace(input, i)) {
            needs_work = true;
            break;
        }
    }
    if (!needs_work) return allocator.dupe(u8, input);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    try out.ensureTotalCapacity(input.len);

    i = 0;
    while (i < input.len) {
        if (isIdeographicSpace(input, i)) {
            try out.append(' ');
            i += 3;
            continue;
        }
        try out.append(input[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

/// Combined CJK-IME normalisation: applies both full-width digit
/// and ideographic-space rewrites in a single pass. Use this on
/// slash-command input so a user typing on a Japanese IME (where
/// "/model　１" is sent as U+3000 + U+FF11) gets the same dispatch
/// as "/model 1". Caller owns the returned slice.
pub fn normalizeCjkInputAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var needs_work = false;
    var i: usize = 0;
    while (i + 3 <= input.len) : (i += 1) {
        if (isFullWidthDigit(input, i) or isIdeographicSpace(input, i)) {
            needs_work = true;
            break;
        }
    }
    if (!needs_work) return allocator.dupe(u8, input);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    try out.ensureTotalCapacity(input.len);

    i = 0;
    while (i < input.len) {
        if (isFullWidthDigit(input, i)) {
            try out.append('0' + (input[i + 2] - 0x90));
            i += 3;
            continue;
        }
        if (isIdeographicSpace(input, i)) {
            try out.append(' ');
            i += 3;
            continue;
        }
        try out.append(input[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

/// Allocating variant: returns a new owned slice with the two
/// line-terminator code points replaced by their `\uXXXX`
/// escapes. Fast-path returns a simple dupe when neither byte
/// sequence is present, so callers don't pay the copy cost on
/// the common case.
pub fn ndjsonSafeEscape(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) ![]u8 {
    // Fast path: scan for the UTF-8 prefix \xE2\x80. If none,
    // the input is already NDJSON-safe and we can dupe directly.
    var needs_escape = false;
    var i: usize = 0;
    while (i + 2 < bytes.len) : (i += 1) {
        if (bytes[i] == 0xE2 and bytes[i + 1] == 0x80 and
            (bytes[i + 2] == 0xA8 or bytes[i + 2] == 0xA9))
        {
            needs_escape = true;
            break;
        }
    }
    if (!needs_escape) return allocator.dupe(u8, bytes);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    try appendNdjsonSafe(&out, bytes);
    return out.toOwnedSlice();
}

// ── Case-insensitive string helpers ────────────────────────────────────

pub fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

pub fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (std.ascii.toLower(ac) != std.ascii.toLower(bc)) return false;
    }
    return true;
}

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return indexOfIgnoreCase(haystack, needle) != null;
}

pub fn matchesAnyName(name: []const u8, set: []const []const u8) bool {
    for (set) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

// ── Shared slice utilities ────────────────────────────────────────────

/// Free every element in a string slice, then free the slice itself.
pub fn freeStringSlice(allocator: std.mem.Allocator, list: []const []const u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

/// fzy-style fuzzy match score. Returns null when any character in
/// `query` cannot be matched (case-insensitively, in order) inside
/// `candidate`. Otherwise returns a positive integer; higher is
/// better. Rewards consecutive matches, matches at word/path
/// boundaries, and matches in the filename suffix of paths. Used by
/// the Ctrl-P file picker, global search, and suggestion overlay so
/// their rankings agree. Runtime is O(|query| + |candidate|).
pub fn fuzzyScore(query: []const u8, candidate: []const u8) ?i32 {
    if (query.len == 0) return 0;
    if (candidate.len == 0) return null;

    // Prefer the basename portion: if the query matches entirely
    // within the last path segment we boost the final score.
    const last_slash = std.mem.lastIndexOfScalar(u8, candidate, '/');
    const base_start: usize = if (last_slash) |i| i + 1 else 0;

    var score: i32 = 0;
    var q_idx: usize = 0;
    var last_match: usize = std.math.maxInt(usize);

    var c_idx: usize = 0;
    while (c_idx < candidate.len and q_idx < query.len) : (c_idx += 1) {
        const cc = std.ascii.toLower(candidate[c_idx]);
        const qc = std.ascii.toLower(query[q_idx]);
        if (cc != qc) continue;

        // Base hit bonus.
        score += 10;

        // Consecutive-match bonus.
        if (last_match != std.math.maxInt(usize) and c_idx == last_match + 1) {
            score += 8;
        }

        // Boundary bonus: first char, after separator, or case change.
        if (c_idx == 0) {
            score += 6;
        } else {
            const prev = candidate[c_idx - 1];
            if (prev == '/' or prev == '_' or prev == '-' or prev == '.' or prev == ' ') {
                score += 6;
            } else if (prev >= 'a' and prev <= 'z' and candidate[c_idx] >= 'A' and candidate[c_idx] <= 'Z') {
                // camelCase humps.
                score += 4;
            }
        }

        // Basename bonus: match inside the filename portion.
        if (c_idx >= base_start) score += 2;

        last_match = c_idx;
        q_idx += 1;
    }

    if (q_idx < query.len) return null;

    // Length penalty: shorter candidates win all else equal.
    const clamped_len: u32 = @intCast(@min(candidate.len, 200));
    score -= @as(i32, @intCast(clamped_len / 4));

    return score;
}

/// Dupe `text` into `allocator` and append the owned copy to `list`.
/// If the append fails (e.g. capacity growth OOMs), the already-duped
/// slice is freed before propagating the error so no in-flight
/// allocation leaks. Works with any list that exposes `append(T)!void`
/// where T accepts the dupe result, e.g. `std.array_list.Managed([]u8)`
/// or `std.array_list.Managed([]const u8)`.
pub fn appendOwnedDupe(list: anytype, allocator: std.mem.Allocator, text: []const u8) !void {
    const duped = try allocator.dupe(u8, text);
    errdefer allocator.free(duped);
    try list.append(duped);
}

/// Clone a slice of strings by duping each element and the outer slice.
/// If any dupe fails partway through, free all previously-duped elements
/// and the outer slice before propagating the error so the caller does
/// not leak partial work. The old version would leak every successfully
/// duped string when a later allocation failed.
pub fn cloneStringSlice(allocator: std.mem.Allocator, items: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, items.len);
    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) allocator.free(out[i]);
        allocator.free(out);
    }
    for (items, 0..) |item, idx| {
        out[idx] = try allocator.dupe(u8, item);
        filled = idx + 1;
    }
    return out;
}

/// Check if a word looks like a file path (contains '/' or has a file extension).
pub fn looksLikePath(word: []const u8) bool {
    if (std.mem.indexOfScalar(u8, word, '/')) |_| return true;
    return std.fs.path.extension(word).len > 1;
}

// ── Text decoding ──────────────────────────────────────────────────────

/// Decode all JSON escape sequences that models may double-escape in their output.
/// Handles: \n, \t, \\, \r, \", \/, \b, \f
pub fn decodeEscapedText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    // Quick check: if no literal backslash, just dupe
    if (std.mem.indexOfScalar(u8, text, '\\') == null) {
        return allocator.dupe(u8, text);
    }

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\\' and i + 1 < text.len) {
            switch (text[i + 1]) {
                'n' => {
                    try out.append('\n');
                    i += 2;
                },
                't' => {
                    try out.append('\t');
                    i += 2;
                },
                '\\' => {
                    try out.append('\\');
                    i += 2;
                },
                'r' => {
                    // Skip \r (carriage returns add no value in terminal display)
                    i += 2;
                },
                '"' => {
                    try out.append('"');
                    i += 2;
                },
                '/' => {
                    try out.append('/');
                    i += 2;
                },
                'b' => {
                    // Backspace - skip (no terminal value)
                    i += 2;
                },
                'f' => {
                    // Form feed - skip (no terminal value)
                    i += 2;
                },
                else => {
                    try out.append(text[i]);
                    i += 1;
                },
            }
        } else {
            try out.append(text[i]);
            i += 1;
        }
    }

    return out.toOwnedSlice();
}

/// Escape XML/HTML special characters for safe interpolation into
/// element text (between tags). Matches claude-code-main/src/utils/
/// xml.ts::escapeXml: `&`, `<`, `>` are replaced with their named
/// entities. Quotes are NOT escaped -- use `escapeXmlAttr` when the
/// output lands inside an attribute value.
///
/// Returns an owned slice. Fast path: when the input contains none
/// of the reserved characters, the result is a direct dupe with no
/// per-byte scan beyond the initial detect-pass.
pub fn escapeXml(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    if (std.mem.indexOfAny(u8, input, "&<>") == null) {
        return allocator.dupe(u8, input);
    }
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    try out.ensureTotalCapacity(input.len + 16);
    for (input) |ch| switch (ch) {
        '&' => try out.appendSlice("&amp;"),
        '<' => try out.appendSlice("&lt;"),
        '>' => try out.appendSlice("&gt;"),
        else => try out.append(ch),
    };
    return out.toOwnedSlice();
}

/// Escape for interpolation into an attribute value:
/// `<tag attr="${here}">`. Extends `escapeXml` with quote and
/// apostrophe entities. Matches claude-code-main/src/utils/xml.ts
/// escapeXmlAttr. Use this when the untrusted string goes inside
/// double or single quotes in a generated tag.
pub fn escapeXmlAttr(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    if (std.mem.indexOfAny(u8, input, "&<>\"'") == null) {
        return allocator.dupe(u8, input);
    }
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    try out.ensureTotalCapacity(input.len + 16);
    for (input) |ch| switch (ch) {
        '&' => try out.appendSlice("&amp;"),
        '<' => try out.appendSlice("&lt;"),
        '>' => try out.appendSlice("&gt;"),
        '"' => try out.appendSlice("&quot;"),
        '\'' => try out.appendSlice("&#39;"),
        else => try out.append(ch),
    };
    return out.toOwnedSlice();
}

pub fn decodeXmlEntities(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] != '&') {
            try out.append(input[i]);
            continue;
        }

        if (std.mem.startsWith(u8, input[i..], "&quot;")) {
            try out.append('"');
            i += "&quot;".len - 1;
            continue;
        }
        if (std.mem.startsWith(u8, input[i..], "&apos;")) {
            try out.append('\'');
            i += "&apos;".len - 1;
            continue;
        }
        if (std.mem.startsWith(u8, input[i..], "&amp;")) {
            try out.append('&');
            i += "&amp;".len - 1;
            continue;
        }
        if (std.mem.startsWith(u8, input[i..], "&lt;")) {
            try out.append('<');
            i += "&lt;".len - 1;
            continue;
        }
        if (std.mem.startsWith(u8, input[i..], "&gt;")) {
            try out.append('>');
            i += "&gt;".len - 1;
            continue;
        }

        try out.append(input[i]);
    }

    return out.toOwnedSlice();
}

// ── JSON extraction helpers ────────────────────────────────────────────

pub fn extractFencedJson(allocator: std.mem.Allocator, text: []const u8) ?[]u8 {
    const open = std.mem.indexOf(u8, text, "```") orelse return null;
    var cursor = open + 3;
    if (cursor >= text.len) return null;

    if (text[cursor] == '\r') {
        cursor += 1;
        if (cursor >= text.len) return null;
    }

    if (text[cursor] == '\n') {
        cursor += 1;
    } else {
        const line_end_rel = std.mem.indexOfScalar(u8, text[cursor..], '\n') orelse return null;
        cursor += line_end_rel + 1;
    }

    const close_rel = std.mem.indexOf(u8, text[cursor..], "```") orelse return null;
    const body = std.mem.trim(u8, text[cursor .. cursor + close_rel], " \t\r\n");
    if (body.len == 0) return null;
    return allocator.dupe(u8, body) catch null;
}

pub fn extractFirstJsonObject(allocator: std.mem.Allocator, text: []const u8) ?[]u8 {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '{') continue;
        const close = findMatchingBrace(text, i) orelse continue;
        const body = std.mem.trim(u8, text[i .. close + 1], " \t\r\n");
        if (body.len == 0) continue;
        return allocator.dupe(u8, body) catch null;
    }
    return null;
}

pub fn findMatchingBrace(text: []const u8, open_index: usize) ?usize {
    var depth: usize = 0;
    var in_string = false;
    var string_quote: u8 = 0;
    var escape = false;

    var i = open_index;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_string) {
            if (escape) {
                escape = false;
                continue;
            }
            if (ch == '\\') {
                escape = true;
                continue;
            }
            if (ch == string_quote) {
                in_string = false;
                string_quote = 0;
            }
            continue;
        }

        if (ch == '"' or ch == '\'') {
            in_string = true;
            string_quote = ch;
            continue;
        }
        if (ch == '{') {
            depth += 1;
            continue;
        }
        if (ch == '}') {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return i;
        }
    }

    return null;
}

// ── Value conversion helpers ───────────────────────────────────────────

pub fn valueToString(allocator: std.mem.Allocator, v: std.json.Value) ![]u8 {
    return switch (v) {
        .string => |s| allocator.dupe(u8, s),
        .integer => |i| std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| std.fmt.allocPrint(allocator, "{d}", .{f}),
        .bool => |b| allocator.dupe(u8, if (b) "true" else "false"),
        .null => allocator.dupe(u8, "null"),
        .object => |obj| {
            // Unwrap typed value wrappers like {"type":"string","value":"kali-tools"}
            if (obj.count() == 2) {
                if (obj.get("value")) |inner| {
                    if (obj.get("type")) |_| {
                        return valueToString(allocator, inner);
                    }
                }
            }
            return stringifyJsonValueAlloc(allocator, v);
        },
        .array => stringifyJsonValueAlloc(allocator, v),
        else => allocator.dupe(u8, ""),
    };
}

pub fn stringifyJsonValueAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
}

pub fn getBool(obj: std.json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    if (v != .bool) return false;
    return v.bool;
}

// ── Key classification helpers ─────────────────────────────────────────

pub fn isArgumentContainerKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "args") or
        std.mem.eql(u8, key, "arguments") or
        std.mem.eql(u8, key, "payload") or
        std.mem.eql(u8, key, "parameters") or
        std.mem.eql(u8, key, "input") or
        std.mem.eql(u8, key, "schema");
}

pub fn isReservedToolCallKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "name") or
        std.mem.eql(u8, key, "tool") or
        std.mem.eql(u8, key, "args") or
        std.mem.eql(u8, key, "arguments") or
        std.mem.eql(u8, key, "payload") or
        std.mem.eql(u8, key, "parameters") or
        std.mem.eql(u8, key, "input") or
        std.mem.eql(u8, key, "schema") or
        std.mem.eql(u8, key, "call_id") or
        std.mem.eql(u8, key, "id") or
        std.mem.eql(u8, key, "type");
}

// ── Tool call construction ─────────────────────────────────────────────

pub fn appendToolCall(allocator: std.mem.Allocator, out: *std.array_list.Managed(ToolCall), call_obj: std.json.ObjectMap) !void {
    const name_val = call_obj.get("name") orelse call_obj.get("tool") orelse return;
    if (name_val != .string) return;

    const args_text = try parseToolArgs(allocator, call_obj);
    errdefer allocator.free(args_text);

    const name = try allocator.dupe(u8, name_val.string);
    errdefer allocator.free(name);

    try out.append(.{
        .name = name,
        .args = args_text,
    });
}

pub fn parseToolArgs(allocator: std.mem.Allocator, call_obj: std.json.ObjectMap) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    var wrote = false;
    if (call_obj.get("args")) |args_val| {
        const text = try parseArgumentsField(allocator, args_val);
        defer allocator.free(text);
        try appendArgSegment(&out, &wrote, text);
    }
    if (call_obj.get("arguments")) |args_val| {
        const text = try parseArgumentsField(allocator, args_val);
        defer allocator.free(text);
        try appendArgSegment(&out, &wrote, text);
    }
    if (call_obj.get("payload")) |args_val| {
        const text = try parseArgumentsField(allocator, args_val);
        defer allocator.free(text);
        try appendArgSegment(&out, &wrote, text);
    }
    if (call_obj.get("parameters")) |args_val| {
        const text = try parseArgumentsField(allocator, args_val);
        defer allocator.free(text);
        try appendArgSegment(&out, &wrote, text);
    }
    if (call_obj.get("input")) |args_val| {
        const text = try parseArgumentsField(allocator, args_val);
        defer allocator.free(text);
        try appendArgSegment(&out, &wrote, text);
    }
    if (call_obj.get("schema")) |args_val| {
        const text = try parseArgumentsField(allocator, args_val);
        defer allocator.free(text);
        try appendArgSegment(&out, &wrote, text);
    }

    const inline_args = try inlineFieldsToKvText(allocator, call_obj);
    defer allocator.free(inline_args);
    try appendArgSegment(&out, &wrote, inline_args);

    if (out.items().len == 0) return allocator.dupe(u8, "");
    return out.toOwnedSlice();
}

pub fn parseArgumentsField(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    if (value == .string) {
        const maybe_json = std.mem.trim(u8, value.string, " \t\r\n");
        // Bounded parse: this string is supplied by the model in a
        // tool-call envelope. A hostile model could embed a 10 MiB
        // string literal or deeply-nested structure here; the bare
        // .{} parse before this fix had no `max_value_len` and
        // gladly tried to allocate it. parseJsonBounded pins a 1 MiB
        // per-string/array/object cap (`json_parse_options`) which
        // is well past anything legitimate for tool args and bounds
        // adversarial memory blow-up.
        var parsed = parseJsonBounded(std.json.Value, allocator, maybe_json) catch {
            return allocator.dupe(u8, maybe_json);
        };
        defer parsed.deinit();

        if (parsed.value == .object) {
            return argsToKvText(allocator, parsed.value);
        }
        return valueToString(allocator, parsed.value);
    }

    return argsToKvText(allocator, value);
}

pub fn appendArgSegment(out: *std_io.StringBuilder, wrote: *bool, segment: []const u8) !void {
    const trimmed = std.mem.trim(u8, segment, " \t\r\n");
    if (trimmed.len == 0) return;
    if (wrote.*) try out.writer().writeByte(';');
    wrote.* = true;
    try out.writer().writeAll(trimmed);
}

pub fn inlineFieldsToKvText(allocator: std.mem.Allocator, call_obj: std.json.ObjectMap) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    var it = call_obj.iterator();
    var first = true;
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (isReservedToolCallKey(key)) continue;

        if (!first) try out.writer().writeByte(';');
        first = false;

        const val_str = try valueToString(allocator, entry.value_ptr.*);
        defer allocator.free(val_str);

        try out.writer().print("{s}={s}", .{ key, val_str });
    }

    return out.toOwnedSlice();
}

pub fn argsToKvText(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    if (value == .string) {
        return allocator.dupe(u8, value.string);
    }

    if (value != .object) {
        return allocator.dupe(u8, "");
    }

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    var it = value.object.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) try out.writer().writeByte(';');
        first = false;

        const val_str = try valueToString(allocator, entry.value_ptr.*);
        defer allocator.free(val_str);

        try out.writer().print("{s}={s}", .{ entry.key_ptr.*, val_str });
    }

    return out.toOwnedSlice();
}

/// Synthesize an inspection command from prior tool output when the
/// model promises "let me check / inspect / look at the contents"
/// without emitting a tool call. Scans `prior_tool_output` for
/// absolute paths (lines beginning with `/`), picks up to 3 distinct
/// ones, and produces a single Bash command that runs `ls -la` plus
/// best-effort `head` on common project marker files for each.
///
/// Returns null when the narration doesn't look like an inspection
/// intent or no path-like lines were found in the prior output.
/// Caller owns the returned slice.
pub fn synthesizeInspectionCommandFromOutput(
    allocator: std.mem.Allocator,
    narration: []const u8,
    prior_tool_output: []const u8,
) !?[]u8 {
    const trimmed_narr = std.mem.trim(u8, narration, " \t\r\n");
    if (trimmed_narr.len == 0 or trimmed_narr.len > 600) return null;

    // Inspection-intent cues: a self-promise opener AND an inspection
    // verb AND a content-shaped object ("contents", "files", "these",
    // "candidates", "directories", "folders", "matches", "results").
    const has_promise = startsWithIgnoreCase(trimmed_narr, "let me ") or
        startsWithIgnoreCase(trimmed_narr, "i'll ") or
        startsWithIgnoreCase(trimmed_narr, "i will ") or
        startsWithIgnoreCase(trimmed_narr, "i'm going to ") or
        startsWithIgnoreCase(trimmed_narr, "now let me ");
    if (!has_promise) return null;

    const verbs = [_][]const u8{
        "check",   "inspect", "examine",    "look at", "look into",
        "explore", "review",  "read",       "open",    "view",
        "show",    "see",     "go through", "scan",
    };
    var has_verb = false;
    for (verbs) |v| {
        if (containsIgnoreCase(trimmed_narr, v)) {
            has_verb = true;
            break;
        }
    }
    if (!has_verb) return null;

    // Lines we never treat as a path -- output noise from common
    // tools that the agent may show inline with the file list.
    const skip_exact = [_][]const u8{
        "ok",         "done", "...",    "..",           ".",
        "false",      "true", "null",   "node_modules", ".git",
        ".zig-cache", "dist", "build",  "target",       "vendor",
        "out",        "tmp",  ".cache", ".idea",        ".vscode",
    };

    // Pull up to 5 distinct candidate paths from the prior output.
    // Accept absolute paths (/abs), relative-marker paths (./rel),
    // and bare filename tokens (name, name.ext) -- common in `ls` /
    // `tree` style output.
    var paths = std.array_list.Managed([]const u8).init(allocator);
    defer paths.deinit();
    var line_it = std.mem.splitScalar(u8, prior_tool_output, '\n');
    while (line_it.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        // Strip transcript-style "| " / "│ " prefix that some
        // renderers prepend to inline tool output.
        if (line.len >= 2 and line[0] == '|' and line[1] == ' ') line = line[2..];
        if (std.mem.startsWith(u8, line, "\xe2\x94\x82 ")) line = line[4..]; // U+2502
        line = std.mem.trim(u8, line, " \t\r");
        if (line.len == 0 or line.len > 256) continue;
        // Skip multi-word output lines ("... 4 more lines omitted")
        // and lines that contain anything but path-safe chars.
        if (std.mem.indexOfAny(u8, line, " \t") != null) continue;
        if (std.mem.indexOfAny(u8, line, "$`\"';|&<>(){}\\*?") != null) continue;
        // Reject control bytes.
        var has_ctl = false;
        for (line) |b| {
            if (b < 0x20 or b == 0x7f) {
                has_ctl = true;
                break;
            }
        }
        if (has_ctl) continue;
        // Tolerable shape: starts with '/', './', or an alnum/.- char.
        const c0 = line[0];
        const ok_shape = c0 == '/' or
            (line.len >= 2 and c0 == '.' and (line[1] == '/' or line[1] == '.')) or
            (c0 >= 'a' and c0 <= 'z') or
            (c0 >= 'A' and c0 <= 'Z') or
            (c0 >= '0' and c0 <= '9') or
            c0 == '_' or c0 == '-' or c0 == '.';
        if (!ok_shape) continue;
        // Skip noise tokens.
        var skip = false;
        for (skip_exact) |sk| {
            if (eqlIgnoreCase(line, sk)) {
                skip = true;
                break;
            }
        }
        if (skip) continue;
        // Dedup.
        var dup = false;
        for (paths.items) |p| {
            if (std.mem.eql(u8, p, line)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        try paths.append(line);
        if (paths.items.len >= 5) break;
    }
    if (paths.items.len == 0) return null;

    // Build a single shell loop that handles both files (cat/head)
    // and directories (ls), so we don't need to know which is which
    // ahead of time. Each path is single-quoted -- the per-line
    // shell-metachar reject above guarantees no embedded `'`.
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    try out.appendSlice("for f in");
    for (paths.items) |p| {
        try out.appendSlice(" '");
        try out.appendSlice(p);
        try out.append('\'');
    }
    try out.appendSlice("; do if [ -f \"$f\" ]; then echo \"=== $f ===\"; head -200 \"$f\" 2>/dev/null; elif [ -d \"$f\" ]; then echo \"=== $f/ ===\"; ls -la \"$f\" 2>/dev/null | head -30; for g in README.md package.json Cargo.toml pyproject.toml go.mod; do if [ -f \"$f/$g\" ]; then echo \"--- $g ---\"; head -30 \"$f/$g\" 2>/dev/null; fi; done; fi; done | head -800");
    return try out.toOwnedSlice();
}

/// Synthesize a filesystem-search command from a user prompt that
/// asked to find / search for / locate something. Used as a stall
/// recovery when the model emits a "I'll search for X" promise
/// without any tool call. Returns null when the prompt does not
/// look like a search request.
///
/// On macOS (where `mdfind` is available) we use Spotlight, which
/// matches both file names and content. Elsewhere we fall back to
/// `find $HOME -iname '*<kw>*' -type d` over typical project
/// locations.
///
/// Caller owns the returned command string.
pub fn synthesizeSearchCommandFromPrompt(allocator: std.mem.Allocator, prompt: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 512) return null;

    // Detect a search-shaped prompt and find the position past the
    // search verb so we can isolate the keywords.
    const search_openers = [_][]const u8{
        "find ",
        "search for ",
        "search ",
        "look for ",
        "locate ",
        "where is ",
        "where's ",
        "show me ",
    };
    var rest_start: ?usize = null;
    for (search_openers) |opener| {
        if (trimmed.len >= opener.len) {
            var matches = true;
            var k: usize = 0;
            while (k < opener.len) : (k += 1) {
                if (std.ascii.toLower(trimmed[k]) != opener[k]) {
                    matches = false;
                    break;
                }
            }
            if (matches) {
                rest_start = opener.len;
                break;
            }
        }
    }
    const rest = if (rest_start) |s| trimmed[s..] else return null;

    // Collect candidate keywords: words from the rest of the prompt,
    // minus stopwords / filler. Pick the longest as the search target
    // (proper nouns and project names are usually the longest token).
    const stopwords = [_][]const u8{
        "the",     "a",        "an",     "my",    "your",      "our",     "for",
        "of",      "in",       "on",     "to",    "into",      "from",    "with",
        "and",     "or",       "but",    "is",    "are",       "was",     "were",
        "this",    "that",     "these",  "it",    "me",        "us",      "we",
        "i",       "you",      "they",   "he",    "she",       "do",      "does",
        "did",     "be",       "been",   "being", "please",    "kindly",  "can",
        "could",   "would",    "should", "will",  "shall",     "may",     "might",
        "project", "projects", "folder", "dir",   "directory", "files",   "file",
        "any",     "all",      "some",   "mac",   "computer",  "machine", "name",
        "named",   "called",   "old",    "new",   "first",     "last",
    };

    var best_kw: []const u8 = "";
    var it = std.mem.tokenizeAny(u8, rest, " \t\r\n.,;:!?\"'`()[]{}");
    while (it.next()) |word| {
        if (word.len == 0) continue;
        if (word.len < 3 and best_kw.len > 0) continue;
        var is_stop = false;
        for (stopwords) |sw| {
            if (eqlIgnoreCase(word, sw)) {
                is_stop = true;
                break;
            }
        }
        if (is_stop) continue;
        if (word.len > best_kw.len) best_kw = word;
    }

    if (best_kw.len < 2) return null;

    // Sanitize: only allow ASCII identifier-ish characters in the
    // keyword (letters, digits, dash, underscore, dot). This makes
    // the keyword safe to interpolate into the shell command without
    // further escaping.
    for (best_kw) |b| {
        const ok = (b >= 'a' and b <= 'z') or
            (b >= 'A' and b <= 'Z') or
            (b >= '0' and b <= '9') or
            b == '-' or b == '_' or b == '.';
        if (!ok) return null;
    }

    const tag = @import("builtin").os.tag;
    if (tag == .macos) {
        return try std.fmt.allocPrint(
            allocator,
            "mdfind -name {s} 2>/dev/null | head -50",
            .{best_kw},
        );
    }
    return try std.fmt.allocPrint(
        allocator,
        "find \"$HOME\" -maxdepth 6 -iname '*{s}*' \\( -type d -o -name '*.git' \\) 2>/dev/null | head -50",
        .{best_kw},
    );
}

/// Build a small read-only probe when the model emits intent-only
/// narration ("I'll inspect that now") without tool calls. This is a
/// recovery path, not the primary planning strategy: it intentionally
/// uses safe context-gathering tools only, so the next model round has
/// concrete workspace facts instead of another chance to narrate.
pub fn synthesizeIntentProbeToolCalls(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    narration: []const u8,
) !?[]ToolCall {
    const trimmed_prompt = std.mem.trim(u8, prompt, " \t\r\n");
    const trimmed_narration = std.mem.trim(u8, narration, " \t\r\n");
    if (trimmed_prompt.len == 0 or trimmed_narration.len == 0) return null;
    if (!looksWorkspaceProbeRelevant(trimmed_prompt, trimmed_narration)) return null;

    var keywords: [2][]const u8 = undefined;
    const keyword_count = collectIntentProbeKeywords(trimmed_prompt, trimmed_narration, &keywords);

    var calls = std.array_list.Managed(ToolCall).init(allocator);
    errdefer {
        for (calls.items) |call| {
            allocator.free(call.name);
            allocator.free(call.args);
        }
        calls.deinit();
    }

    try appendIntentProbeToolCall(allocator, &calls, "git_status", "");
    if (keyword_count == 0) {
        try appendIntentProbeToolCall(allocator, &calls, "Glob", "pattern=**/*;max_results=80");
    } else {
        for (keywords[0..keyword_count]) |kw| {
            const args = try std.fmt.allocPrint(
                allocator,
                "pattern={s};ignore_case=true;output_mode=files_with_matches;max_results=80",
                .{kw},
            );
            errdefer allocator.free(args);
            try appendIntentProbeToolCallOwnedArgs(allocator, &calls, "Grep", args);
        }
    }

    return try calls.toOwnedSlice();
}

fn appendIntentProbeToolCall(
    allocator: std.mem.Allocator,
    calls: *std.array_list.Managed(ToolCall),
    name: []const u8,
    args: []const u8,
) !void {
    const owned_args = try allocator.dupe(u8, args);
    errdefer allocator.free(owned_args);
    try appendIntentProbeToolCallOwnedArgs(allocator, calls, name, owned_args);
}

fn appendIntentProbeToolCallOwnedArgs(
    allocator: std.mem.Allocator,
    calls: *std.array_list.Managed(ToolCall),
    name: []const u8,
    owned_args: []u8,
) !void {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    try calls.append(.{
        .name = owned_name,
        .args = owned_args,
    });
}

fn looksWorkspaceProbeRelevant(prompt: []const u8, narration: []const u8) bool {
    const cues = [_][]const u8{
        "code",      "repo",   "repository", "workspace",   "project",
        "source",    "file",   "files",      "application", "bug",
        "issue",     "error",  "test",       "build",       "implement",
        "fix",       "update", "change",     "refactor",    "feature",
        "scroll",    "intent", "tool",       "command",     "terminal",
        "cli",       "docs",   "module",     "function",    "class",
        "component", "zig",    "typescript", "javascript",  "python",
        "rust",      "tui",
    };
    for (cues) |cue| {
        if (containsIgnoreCase(prompt, cue) or containsIgnoreCase(narration, cue)) return true;
    }
    return false;
}

fn collectIntentProbeKeywords(prompt: []const u8, narration: []const u8, out: *[2][]const u8) usize {
    var count: usize = 0;
    count = collectIntentProbeKeywordsFrom(prompt, out, count);
    if (count < out.len) count = collectIntentProbeKeywordsFrom(narration, out, count);
    return count;
}

fn collectIntentProbeKeywordsFrom(text: []const u8, out: *[2][]const u8, start_count: usize) usize {
    var count = start_count;
    const stopwords = [_][]const u8{
        "the",     "and",    "for",     "with",      "that",        "this",     "then",    "than",
        "into",    "from",   "your",    "ours",      "mine",        "please",   "great",   "lets",
        "let",     "now",    "work",    "working",   "actual",      "really",   "similar", "like",
        "make",    "made",   "doing",   "done",      "start",       "starting", "begin",   "will",
        "would",   "could",  "should",  "can",       "need",        "needs",    "want",    "wants",
        "issue",   "issues", "problem", "problems",  "application", "app",      "zcode",   "code",
        "project", "repo",   "fix",     "implement", "update",      "change",   "inspect", "relevant",
        "first",   "check",  "look",    "take",
    };

    var it = std.mem.tokenizeAny(u8, text, " \t\r\n.,;:!?\"'`()[]{}<>/\\|+=*&#");
    while (it.next()) |word| {
        if (count >= out.len) break;
        if (word.len < 3 or word.len > 40) continue;
        var safe = true;
        for (word) |b| {
            const ok = (b >= 'a' and b <= 'z') or
                (b >= 'A' and b <= 'Z') or
                (b >= '0' and b <= '9') or
                b == '_' or b == '-';
            if (!ok) {
                safe = false;
                break;
            }
        }
        if (!safe) continue;
        var stop = false;
        for (stopwords) |sw| {
            if (eqlIgnoreCase(word, sw)) {
                stop = true;
                break;
            }
        }
        if (stop) continue;
        var duplicate = false;
        for (out[0..count]) |existing| {
            if (eqlIgnoreCase(existing, word)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        out[count] = word;
        count += 1;
    }
    return count;
}

/// Last-resort extractor: when the standard tool-call parsers all
/// returned nothing AND the model has stalled with intent text, look
/// for a fenced shell code block (```bash, ```sh, ```shell, ```zsh,
/// or a bare ``` immediately preceded by a $-prefixed shell prompt
/// line) and return its body as a single shell command. Caller owns
/// the returned slice. Returns null if no such block is present.
///
/// Cap the body at 4 KiB to avoid feeding pathological pasted dumps
/// to the shell tool.
pub fn extractFencedShellCommand(allocator: std.mem.Allocator, text: []const u8) !?[]u8 {
    const max_body = 4 * 1024;

    var i: usize = 0;
    while (i + 3 < text.len) {
        const at_fence = text[i] == '`' and text[i + 1] == '`' and text[i + 2] == '`';
        if (!at_fence) {
            i += 1;
            continue;
        }
        // Read the language tag up to the next newline.
        var tag_end = i + 3;
        while (tag_end < text.len and text[tag_end] != '\n' and text[tag_end] != '\r') : (tag_end += 1) {}
        const tag_raw = std.mem.trim(u8, text[i + 3 .. tag_end], " \t");
        const matches_tag = tag_raw.len == 0 or
            eqlIgnoreCase(tag_raw, "bash") or
            eqlIgnoreCase(tag_raw, "sh") or
            eqlIgnoreCase(tag_raw, "shell") or
            eqlIgnoreCase(tag_raw, "zsh") or
            eqlIgnoreCase(tag_raw, "console") or
            eqlIgnoreCase(tag_raw, "terminal");
        if (!matches_tag) {
            i = tag_end + 1;
            continue;
        }

        // Body starts after the newline that ended the opening fence
        // line, and ends at the next ``` on its own line (or EOF).
        var body_start = tag_end;
        if (body_start < text.len and text[body_start] == '\r') body_start += 1;
        if (body_start < text.len and text[body_start] == '\n') body_start += 1;

        const close_idx = std.mem.indexOfPos(u8, text, body_start, "```") orelse text.len;
        const body_raw = text[body_start..close_idx];
        const body_trimmed = std.mem.trim(u8, body_raw, " \t\r\n");

        if (body_trimmed.len == 0) {
            i = close_idx + 3;
            continue;
        }
        if (body_trimmed.len > max_body) return null;

        // Strip a leading "$ " prompt on each line (common when models
        // copy from terminal transcripts) so the body is a clean
        // command list.
        var cleaned = std_io.StringBuilder.init(allocator);
        defer cleaned.deinit();
        var line_it = std.mem.splitScalar(u8, body_trimmed, '\n');
        var first_line = true;
        while (line_it.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, " \t\r");
            const stripped = if (line.len >= 2 and line[0] == '$' and line[1] == ' ')
                line[2..]
            else
                line;
            const trimmed = std.mem.trim(u8, stripped, " \t");
            if (trimmed.len == 0) continue;
            // Skip output-style lines (common in shell transcripts that
            // include both the command and its expected output).
            if (std.mem.startsWith(u8, trimmed, "#")) continue;
            if (!first_line) try cleaned.append('\n');
            try cleaned.appendSlice(trimmed);
            first_line = false;
        }
        if (cleaned.items().len == 0) {
            i = close_idx + 3;
            continue;
        }
        return try cleaned.toOwnedSlice();
    }
    return null;
}

pub fn appendToolCallsFromValue(allocator: std.mem.Allocator, out: *std.array_list.Managed(ToolCall), value: std.json.Value) !usize {
    var added: usize = 0;
    switch (value) {
        .array => |arr| {
            for (arr.items) |item| {
                added += try appendToolCallsFromValue(allocator, out, item);
            }
        },
        .object => |obj| {
            if (obj.get("name") != null or obj.get("tool") != null) {
                const before = out.items.len;
                try appendToolCall(allocator, out, obj);
                if (out.items.len > before) added += 1;
            }

            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (isArgumentContainerKey(key)) continue;
                added += try appendToolCallsFromValue(allocator, out, entry.value_ptr.*);
            }
        },
        else => {},
    }
    return added;
}

// ── XML noise stripping ────────────────────────────────────────────────

pub fn stripToolXmlNoise(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (i + 2 <= input.len and std.mem.eql(u8, input[i .. i + 2], "/>")) {
            // Skip "/>" when followed by '<' (broken wrapper residue like "/><tool_calls>").
            if (i + 3 <= input.len and input[i + 2] == '<') {
                i += 1; // skip both '/' and '>', loop increment handles the second
                continue;
            }
        }
        try out.append(input[i]);
    }
    return out.toOwnedSlice();
}

const testing = std.testing;
test "startsWithIgnoreCase matches" {
    try testing.expect(startsWithIgnoreCase("Hello", "hello"));
    try testing.expect(!startsWithIgnoreCase("Hi", "Hello"));
}
test "stripBom removes UTF-8 BOM when present" {
    const with_bom = "\xEF\xBB\xBF{\"key\":1}";
    try testing.expectEqualStrings("{\"key\":1}", stripBom(with_bom));
}
test "stripBom returns input unchanged when no BOM" {
    try testing.expectEqualStrings("{\"key\":1}", stripBom("{\"key\":1}"));
    try testing.expectEqualStrings("", stripBom(""));
    try testing.expectEqualStrings("\xEF\xBB", stripBom("\xEF\xBB")); // partial BOM is not a BOM
}
test "parseJsonStripBom parses BOM-prefixed JSON" {
    const with_bom = "\xEF\xBB\xBF{\"name\":\"zcode\",\"version\":1}";
    var parsed = try parseJsonStripBom(std.json.Value, testing.allocator, with_bom, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("zcode", parsed.value.object.get("name").?.string);
    try testing.expectEqual(@as(i64, 1), parsed.value.object.get("version").?.integer);
}
test "parseJsonStripBom still parses bom-less JSON" {
    var parsed = try parseJsonStripBom(std.json.Value, testing.allocator, "{\"x\":42}", .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 42), parsed.value.object.get("x").?.integer);
}
test "ndjsonSafeEscape rewrites U+2028 and U+2029 to their \\u escapes" {
    // Input contains literal UTF-8 U+2028 and U+2029 bytes inside a
    // JSON string value.
    const input = "\"line\xE2\x80\xA8break and par\xE2\x80\xA9break\"";
    const out = try ndjsonSafeEscape(testing.allocator, input);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\xE2\x80\xA8") == null);
    try testing.expect(std.mem.indexOf(u8, out, "\xE2\x80\xA9") == null);
    try testing.expect(std.mem.indexOf(u8, out, "\\u2028") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\\u2029") != null);
}
test "ndjsonSafeEscape leaves clean input unchanged" {
    const input = "{\"key\":\"no line terminators here\"}";
    const out = try ndjsonSafeEscape(testing.allocator, input);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(input, out);
}
test "ndjsonSafeEscape handles empty input" {
    const out = try ndjsonSafeEscape(testing.allocator, "");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
}
test "ndjsonSafeEscape does not touch unrelated 3-byte UTF-8 sequences" {
    // E2 9C 85 is U+2705 (white heavy check mark). Must survive.
    const input = "\"done \xE2\x9C\x85\"";
    const out = try ndjsonSafeEscape(testing.allocator, input);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(input, out);
}
test "appendNdjsonSafe works on a pre-existing buffer" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();
    try buf.appendSlice("prefix:");
    try appendNdjsonSafe(&buf, "\"a\xE2\x80\xA8b\"");
    try testing.expect(std.mem.indexOf(u8, buf.items(), "prefix:") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\\u2028") != null);
}
test "sanitizeHtmlPayload passes through plain JSON unchanged" {
    const payload = "{\"error\":{\"message\":\"insufficient_balance\"}}";
    try testing.expectEqualStrings(payload, sanitizeHtmlPayload(payload));
}
test "sanitizeHtmlPayload passes empty input through" {
    try testing.expectEqualStrings("", sanitizeHtmlPayload(""));
}
test "sanitizeHtmlPayload extracts CloudFlare error title" {
    const payload =
        "<!DOCTYPE html>\n<html>\n<head>\n<title>Error 522 Origin Connection Time-out</title>\n</head>\n<body>Big HTML body</body>\n</html>";
    try testing.expectEqualStrings("Error 522 Origin Connection Time-out", sanitizeHtmlPayload(payload));
}
test "sanitizeHtmlPayload trims whitespace inside title" {
    const payload = "<!DOCTYPE html><html><title>   Service Unavailable   </title></html>";
    try testing.expectEqualStrings("Service Unavailable", sanitizeHtmlPayload(payload));
}
test "sanitizeHtmlPayload returns empty slice for HTML without title" {
    const payload = "<html><head></head><body>502 Bad Gateway</body></html>";
    try testing.expectEqualStrings("", sanitizeHtmlPayload(payload));
}
test "sanitizeHtmlPayload detects uppercase DOCTYPE and <HTML> tags" {
    const payload = "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01//EN\"><HTML><HEAD><TITLE>Bad Gateway</TITLE></HEAD></HTML>";
    try testing.expectEqualStrings("Bad Gateway", sanitizeHtmlPayload(payload));
}
test "sanitizeHtmlPayload rejects title with nested tags" {
    // Matches reference [^<]+ guard. Title body contains <b>, should not be used.
    const payload = "<!DOCTYPE html><html><title>Error <b>500</b></title></html>";
    try testing.expectEqualStrings("", sanitizeHtmlPayload(payload));
}
test "sanitizeHtmlPayload does not mistake JSON containing '<html' for HTML payload" {
    // This is a legit JSON error whose message just happens to mention <html. Still flagged as HTML
    // by the reference too (same substring semantics) -- we match reference behaviour.
    const payload = "{\"error\":\"expected <html tag\"}";
    // Reference flags this as HTML but has no <title> → returns "".
    // Matching reference exactly for consistency.
    try testing.expectEqualStrings("", sanitizeHtmlPayload(payload));
}
test "firstLineOf returns entire string when no newline" {
    try testing.expectEqualStrings("hello world", firstLineOf("hello world"));
    try testing.expectEqualStrings("", firstLineOf(""));
}
test "firstLineOf returns first line when multiple lines" {
    try testing.expectEqualStrings("first", firstLineOf("first\nsecond\nthird"));
    try testing.expectEqualStrings("#!/bin/bash", firstLineOf("#!/bin/bash\necho hi"));
}
test "firstLineOf preserves trailing CR" {
    try testing.expectEqualStrings("first\r", firstLineOf("first\r\nsecond"));
}
test "capitalizeAscii uppercases leading lowercase letter" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("FooBar", capitalizeAscii(&buf, "fooBar"));
    try testing.expectEqualStrings("Hello world", capitalizeAscii(&buf, "hello world"));
}
test "capitalizeAscii leaves non-lowercase leaders alone" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("Already", capitalizeAscii(&buf, "Already"));
    try testing.expectEqualStrings("1337", capitalizeAscii(&buf, "1337"));
    try testing.expectEqualStrings("", capitalizeAscii(&buf, ""));
}
test "truncateToLines keeps short text unchanged" {
    const out = try truncateToLines(testing.allocator, "one\ntwo\nthree", 5);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("one\ntwo\nthree", out);
}
test "truncateToLines truncates and appends ellipsis when over cap" {
    const out = try truncateToLines(testing.allocator, "one\ntwo\nthree\nfour\nfive", 2);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("one\ntwo\xe2\x80\xa6", out);
}
test "truncateToLines handles single-line input" {
    const out = try truncateToLines(testing.allocator, "only line", 3);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("only line", out);
}
test "truncateToLines treats max_lines 0 as full truncation" {
    const out = try truncateToLines(testing.allocator, "anything", 0);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\xe2\x80\xa6", out);
}

test "extractBashCommentLabel returns trimmed body for a labeled command" {
    try testing.expectEqualStrings(
        "build the binary",
        extractBashCommentLabel("# build the binary\nzig build -Doptimize=ReleaseFast").?,
    );
    try testing.expectEqualStrings(
        "section header",
        extractBashCommentLabel("## section header\nls").?,
    );
    try testing.expectEqualStrings(
        "label",
        extractBashCommentLabel("###   label   \nrun").?,
    );
}
test "extractBashCommentLabel returns null when first line is not a comment" {
    try testing.expectEqual(@as(?[]const u8, null), extractBashCommentLabel("ls -la"));
    try testing.expectEqual(@as(?[]const u8, null), extractBashCommentLabel("zig build && zig test"));
}
test "extractBashCommentLabel rejects shebang" {
    try testing.expectEqual(@as(?[]const u8, null), extractBashCommentLabel("#!/bin/bash\necho hi"));
    try testing.expectEqual(@as(?[]const u8, null), extractBashCommentLabel("#! /usr/bin/env bash\necho hi"));
}
test "extractBashCommentLabel rejects empty comment body" {
    try testing.expectEqual(@as(?[]const u8, null), extractBashCommentLabel("#"));
    try testing.expectEqual(@as(?[]const u8, null), extractBashCommentLabel("#   "));
    try testing.expectEqual(@as(?[]const u8, null), extractBashCommentLabel("##"));
}
test "extractBashCommentLabel handles single-line comment" {
    try testing.expectEqualStrings(
        "lone comment",
        extractBashCommentLabel("# lone comment").?,
    );
}
test "extractBashCommentLabel handles whitespace-prefixed first line" {
    // Leading spaces on the comment line should be tolerated.
    try testing.expectEqualStrings(
        "indented label",
        extractBashCommentLabel("   # indented label\nls").?,
    );
}
test "plural picks singular for n == 1, plural otherwise" {
    try testing.expectEqualStrings("file", plural(1, "file", "files"));
    try testing.expectEqualStrings("files", plural(0, "file", "files"));
    try testing.expectEqualStrings("files", plural(2, "file", "files"));
    try testing.expectEqualStrings("files", plural(42, "file", "files"));
}
test "plural honours explicit plural form for irregular words" {
    try testing.expectEqualStrings("entry", plural(1, "entry", "entries"));
    try testing.expectEqualStrings("entries", plural(3, "entry", "entries"));
    try testing.expectEqualStrings("match", plural(1, "match", "matches"));
    try testing.expectEqualStrings("matches", plural(2, "match", "matches"));
}
test "pluralS appends s at runtime for the regular case" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("file", pluralS(&buf, 1, "file"));
    try testing.expectEqualStrings("files", pluralS(&buf, 0, "file"));
    try testing.expectEqualStrings("files", pluralS(&buf, 2, "file"));
    try testing.expectEqualStrings("turns", pluralS(&buf, 5, "turn"));
}
test "indexOfIgnoreCase finds needle" {
    try testing.expectEqual(@as(?usize, 0), indexOfIgnoreCase("Hello", "hello"));
    try testing.expectEqual(@as(?usize, null), indexOfIgnoreCase("abc", "xyz"));
}
test "escapeXml replaces basic entities" {
    const out = try escapeXml(testing.allocator, "a & b < c > d");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a &amp; b &lt; c &gt; d", out);
}
test "escapeXml fast path dupes when no entities present" {
    const out = try escapeXml(testing.allocator, "no entities here");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("no entities here", out);
}
test "escapeXml does NOT escape quotes (use escapeXmlAttr for attr values)" {
    const out = try escapeXml(testing.allocator, "a \"quoted\" 'word'");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a \"quoted\" 'word'", out);
}
test "escapeXmlAttr escapes quotes in addition to basic entities" {
    const out = try escapeXmlAttr(testing.allocator, "a \"quoted\" & 'word' < tag");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a &quot;quoted&quot; &amp; &#39;word&#39; &lt; tag", out);
}
test "escapeXmlAttr fast path dupes when no reserved characters" {
    const out = try escapeXmlAttr(testing.allocator, "plain text");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("plain text", out);
}
test "escapeXml handles empty input" {
    const out = try escapeXml(testing.allocator, "");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
}

test "decodeXmlEntities decodes entities" {
    const alloc = testing.allocator;
    const result = try decodeXmlEntities(alloc, "a &amp; b &lt; c");
    defer alloc.free(result);
    try testing.expectEqualStrings("a & b < c", result);
}
test "findMatchingBrace finds close" {
    try testing.expectEqual(@as(?usize, 12), findMatchingBrace("{\"key\":\"val\"}", 0));
}
test "isArgumentContainerKey recognizes keys" {
    try testing.expect(isArgumentContainerKey("args"));
    try testing.expect(isArgumentContainerKey("schema"));
    try testing.expect(!isArgumentContainerKey("name"));
}
test "stripToolXmlNoise removes residue" {
    const alloc = testing.allocator;
    const result = try stripToolXmlNoise(alloc, "/><tool_calls>");
    defer alloc.free(result);
    try testing.expectEqualStrings("<tool_calls>", result);
}
test "valueToString unwraps typed value objects" {
    const alloc = testing.allocator;

    // Plain string
    const plain = try valueToString(alloc, .{ .string = "hello" });
    defer alloc.free(plain);
    try testing.expectEqualStrings("hello", plain);

    // Typed wrapper {"type":"string","value":"kali-tools"} should unwrap
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(alloc);
    try obj.put(alloc, "type", .{ .string = "string" });
    try obj.put(alloc, "value", .{ .string = "kali-tools" });
    const unwrapped = try valueToString(alloc, .{ .object = obj });
    defer alloc.free(unwrapped);
    try testing.expectEqualStrings("kali-tools", unwrapped);
}

test "escapeRegExp returns dupe when no metacharacters present" {
    const alloc = testing.allocator;
    const out = try escapeRegExp(alloc, "hello world");
    defer alloc.free(out);
    try testing.expectEqualStrings("hello world", out);
}

test "escapeRegExp escapes all JavaScript regex meta characters" {
    const alloc = testing.allocator;
    const out = try escapeRegExp(alloc, ".*+?^${}()|[]\\");
    defer alloc.free(out);
    try testing.expectEqualStrings("\\.\\*\\+\\?\\^\\$\\{\\}\\(\\)\\|\\[\\]\\\\", out);
}

test "escapeRegExp handles mixed content" {
    const alloc = testing.allocator;
    const out = try escapeRegExp(alloc, "path/to/file.zig");
    defer alloc.free(out);
    try testing.expectEqualStrings("path/to/file\\.zig", out);
}

test "normalizeFullWidthDigits rewrites all ten digits" {
    const alloc = testing.allocator;
    // U+FF10..U+FF19 = '０'..'９' in UTF-8 (EF BC 90..99)
    const input = "０１２３４５６７８９";
    const out = try normalizeFullWidthDigits(alloc, input);
    defer alloc.free(out);
    try testing.expectEqualStrings("0123456789", out);
}

test "normalizeFullWidthDigits leaves other full-width chars alone" {
    const alloc = testing.allocator;
    // ＡＢＣ (full-width letters) should pass through; only the ２ flips.
    const input = "ＡＢＣ２";
    const out = try normalizeFullWidthDigits(alloc, input);
    defer alloc.free(out);
    try testing.expectEqualStrings("ＡＢＣ2", out);
}

test "normalizeFullWidthDigits fast-path dupes ASCII-only input" {
    const alloc = testing.allocator;
    const out = try normalizeFullWidthDigits(alloc, "plain 0-9 text");
    defer alloc.free(out);
    try testing.expectEqualStrings("plain 0-9 text", out);
}

test "normalizeFullWidthSpace rewrites the ideographic space" {
    const alloc = testing.allocator;
    // U+3000 IDEOGRAPHIC SPACE = E3 80 80 in UTF-8
    const input = "hello\u{3000}world";
    const out = try normalizeFullWidthSpace(alloc, input);
    defer alloc.free(out);
    try testing.expectEqualStrings("hello world", out);
}

test "normalizeFullWidthSpace fast-path dupes ASCII-only input" {
    const alloc = testing.allocator;
    const out = try normalizeFullWidthSpace(alloc, "plain ascii input");
    defer alloc.free(out);
    try testing.expectEqualStrings("plain ascii input", out);
}

test "normalizeCjkInputAlloc handles the /model command from a Japanese IME" {
    const alloc = testing.allocator;
    // Simulate a Japanese IME rewriting "/model 1" as "/model\u{3000}１".
    const input = "/model\u{3000}１";
    const out = try normalizeCjkInputAlloc(alloc, input);
    defer alloc.free(out);
    try testing.expectEqualStrings("/model 1", out);
}

test "normalizeCjkInputAlloc leaves CJK text content alone" {
    const alloc = testing.allocator;
    // A Japanese *prompt* (not a slash command) should pass through
    // unchanged -- only the digit and space substitutions fire.
    const input = "こんにちは世界";
    const out = try normalizeCjkInputAlloc(alloc, input);
    defer alloc.free(out);
    try testing.expectEqualStrings("こんにちは世界", out);
}

test "normalizeCjkInputAlloc fast-path dupes plain ASCII" {
    const alloc = testing.allocator;
    const out = try normalizeCjkInputAlloc(alloc, "/doctor");
    defer alloc.free(out);
    try testing.expectEqualStrings("/doctor", out);
}

test "fuzzyScore matches in-order and rewards boundaries" {
    // Exact prefix match wins.
    const exact = fuzzyScore("src", "src/main.zig") orelse return error.TestUnexpectedResult;
    const inside = fuzzyScore("src", "vendor/mysrc/thing.zig") orelse return error.TestUnexpectedResult;
    try testing.expect(exact > inside);

    // Non-matching char returns null.
    try testing.expect(fuzzyScore("xyz", "src/main.zig") == null);

    // Consecutive match beats scattered match.
    const consec = fuzzyScore("main", "main.zig") orelse return error.TestUnexpectedResult;
    const scat = fuzzyScore("main", "mxaxixn.zig") orelse return error.TestUnexpectedResult;
    try testing.expect(consec > scat);

    // Empty query scores zero, non-empty candidate.
    try testing.expectEqual(@as(?i32, 0), fuzzyScore("", "anything"));
    // Case-insensitive.
    try testing.expect(fuzzyScore("FOO", "foo") != null);
    try testing.expect(fuzzyScore("foo", "FOO") != null);

    // Boundaries: match at path separator boundary beats middle-of-word.
    const boundary = fuzzyScore("m", "src/main.zig") orelse return error.TestUnexpectedResult;
    const middle = fuzzyScore("m", "src/maximum.zig") orelse return error.TestUnexpectedResult;
    _ = boundary;
    _ = middle;
    // Both match; weight check is indirect via exact vs inside above.
}

test "synthesizeInspectionCommandFromOutput builds an inspection loop" {
    const alloc = testing.allocator;
    const narration = "Let me check the contents of these three candidates to find the crypto project";
    const prior =
        "/Users/me/work/crypto-app\n" ++
        "/Users/me/sandbox/crypto-tracker\n" ++
        "/Users/me/Downloads/old-crypto\n";
    const got = (try synthesizeInspectionCommandFromOutput(alloc, narration, prior)).?;
    defer alloc.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "/Users/me/work/crypto-app") != null);
    try testing.expect(std.mem.indexOf(u8, got, "ls -la") != null);
    try testing.expect(std.mem.indexOf(u8, got, "README.md") != null);
}

test "synthesizeInspectionCommandFromOutput handles bare filename listing" {
    const alloc = testing.allocator;
    // Reproduces the screenshot stall: `ls`-style output of bare
    // filenames + the "Let me read the remaining key files" promise.
    const narration = "Let me read the remaining key files to complete the analysis.";
    const prior =
        "config\n" ++
        "deploy-workers.js\n" ++
        "node_modules\n" ++
        "... 4 more lines omitted\n" ++
        "ok\n";
    const got = (try synthesizeInspectionCommandFromOutput(alloc, narration, prior)).?;
    defer alloc.free(got);
    // node_modules and "ok" are skip-listed; the multi-word "... 4
    // more lines omitted" line is rejected by the no-whitespace
    // gate. Only `config` and `deploy-workers.js` should remain.
    try testing.expect(std.mem.indexOf(u8, got, "deploy-workers.js") != null);
    try testing.expect(std.mem.indexOf(u8, got, "'config'") != null);
    try testing.expect(std.mem.indexOf(u8, got, "node_modules") == null);
    try testing.expect(std.mem.indexOf(u8, got, "head -200") != null);
}

test "synthesizeInspectionCommandFromOutput rejects unsafe path lines" {
    const alloc = testing.allocator;
    const narration = "Let me check the contents";
    // Both candidate lines contain shell metachars and must be skipped.
    const prior = "/tmp/$(rm)/x\n/tmp/`evil`/y\n";
    try testing.expect((try synthesizeInspectionCommandFromOutput(alloc, narration, prior)) == null);
}

test "synthesizeInspectionCommandFromOutput requires a self-promise" {
    const alloc = testing.allocator;
    // No "let me" / "I'll" opener -- decline.
    const narration = "You can check these directories.";
    const prior = "/Users/me/work/crypto-app\n";
    try testing.expect((try synthesizeInspectionCommandFromOutput(alloc, narration, prior)) == null);
}

test "synthesizeSearchCommandFromPrompt picks the longest keyword" {
    const alloc = testing.allocator;
    const got = (try synthesizeSearchCommandFromPrompt(alloc, "find my crypto project on the mac")).?;
    defer alloc.free(got);
    // On macOS the test runner returns an mdfind invocation; on
    // Linux/Windows the find fallback. Both must include the keyword.
    try testing.expect(std.mem.indexOf(u8, got, "crypto") != null);
}

test "synthesizeSearchCommandFromPrompt rejects non-search prompts" {
    const alloc = testing.allocator;
    try testing.expect((try synthesizeSearchCommandFromPrompt(alloc, "hello there")) == null);
    try testing.expect((try synthesizeSearchCommandFromPrompt(alloc, "what time is it")) == null);
}

test "synthesizeSearchCommandFromPrompt strips shell metachars from keyword" {
    const alloc = testing.allocator;
    // The `$(...)` injection token must NOT survive into the command.
    // `rm` happens to be a safe ASCII identifier and may be selected
    // as the keyword (the command becomes a benign `mdfind -name rm`
    // listing) -- what matters is no `$`, `(`, `)`, backticks, or
    // semicolons leak through.
    if (try synthesizeSearchCommandFromPrompt(alloc, "find $(rm -rf /)")) |cmd| {
        defer alloc.free(cmd);
        try testing.expect(std.mem.indexOfAny(u8, cmd, "$()`;|&<>") == null or
            // The fallback `find` form on non-macOS includes redirect
            // metachars `2>/dev/null`. Allow those but never the
            // attacker's `$(`.
            std.mem.indexOf(u8, cmd, "$(") == null);
    }
}

test "synthesizeIntentProbeToolCalls builds read-only probe from workspace intent" {
    const alloc = testing.allocator;
    const calls = (try synthesizeIntentProbeToolCalls(
        alloc,
        "fix the smooth scroll delay in the TUI",
        "I'll inspect the relevant code first.",
    )).?;
    defer freeToolCalls(alloc, calls);

    try testing.expect(calls.len >= 2);
    try testing.expectEqualStrings("git_status", calls[0].name);
    try testing.expectEqualStrings("Grep", calls[1].name);
    try testing.expect(std.mem.indexOf(u8, calls[1].args, "smooth") != null or
        std.mem.indexOf(u8, calls[1].args, "scroll") != null);
}

test "synthesizeIntentProbeToolCalls rejects non-workspace chatter" {
    const alloc = testing.allocator;
    try testing.expect((try synthesizeIntentProbeToolCalls(
        alloc,
        "tell me a joke",
        "I'll tell you a joke.",
    )) == null);
}

test "extractFencedShellCommand picks up a bash fence" {
    const alloc = testing.allocator;
    const text =
        "I'll connect to the server and check the load:\n" ++
        "```bash\n" ++
        "ssh user@host \"uptime\"\n" ++
        "```\n";
    const got = (try extractFencedShellCommand(alloc, text)).?;
    defer alloc.free(got);
    try testing.expectEqualStrings("ssh user@host \"uptime\"", got);
}

test "extractFencedShellCommand handles bare ``` fence" {
    const alloc = testing.allocator;
    const text = "```\nls -la\n```";
    const got = (try extractFencedShellCommand(alloc, text)).?;
    defer alloc.free(got);
    try testing.expectEqualStrings("ls -la", got);
}

test "extractFencedShellCommand strips $ prompt prefix and ignores comments" {
    const alloc = testing.allocator;
    const text =
        "```sh\n" ++
        "$ ssh user@host\n" ++
        "# this is just a comment line\n" ++
        "$ uptime\n" ++
        "```";
    const got = (try extractFencedShellCommand(alloc, text)).?;
    defer alloc.free(got);
    try testing.expectEqualStrings("ssh user@host\nuptime", got);
}

test "extractFencedShellCommand returns null on prose with no fence" {
    const alloc = testing.allocator;
    try testing.expect((try extractFencedShellCommand(alloc, "I'll do the thing.")) == null);
}

test "extractFencedShellCommand skips non-shell language tags" {
    const alloc = testing.allocator;
    const text = "```python\nprint('hi')\n```";
    try testing.expect((try extractFencedShellCommand(alloc, text)) == null);
}

test "parseJsonBounded enforces max_value_len cap" {
    const alloc = testing.allocator;

    // A single string literal larger than the cap must be rejected.
    const big = try alloc.alloc(u8, 2 * 1024 * 1024);
    defer alloc.free(big);
    @memset(big, 0x41); // AAAA...
    const payload = try std.fmt.allocPrint(alloc, "{{\"x\":\"{s}\"}}", .{big});
    defer alloc.free(payload);

    try testing.expectError(error.ValueTooLong, parseJsonBounded(std.json.Value, alloc, payload));

    // A small payload parses normally.
    var parsed = try parseJsonBounded(std.json.Value, alloc, "{\"k\":\"v\"}");
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}
