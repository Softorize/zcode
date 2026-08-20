const std = @import("std");
const std_io = @import("std_io.zig");

/// Argument substitution for command and skill prompt templates.
/// Ported from claude-code-main/src/utils/argumentSubstitution.ts so
/// that command/skill .md files written for Claude Code work in
/// zcode without rewriting the placeholders.
///
/// Supported placeholders:
///   $ARGUMENTS         -- replaced with the full args string
///   $ARGUMENTS[0]      -- replaced with parsed_args[0] (or empty)
///   $ARGUMENTS[1]      -- replaced with parsed_args[1] (or empty)
///   $0, $1, ...        -- shorthand for $ARGUMENTS[0], $ARGUMENTS[1]
///   $foo, $bar         -- named args, indexed by frontmatter order
///
/// zcode's pre-existing {{args}} / {{arg1}} syntax is intentionally
/// NOT handled here -- callers chain both passes when they need
/// backward compatibility. Keeping the two systems separate lets
/// each one stay minimal and lets us delete the legacy syntax in
/// a future pass without a churny rewrite.
/// Parse an argument string into individual tokens, honouring
/// shell-style single and double quotes and backslash escapes.
/// Caller owns the returned slice and each inner slice; use
/// `freeParsed` for cleanup.
///
/// Examples:
///   "foo bar baz"             -> ["foo", "bar", "baz"]
///   "foo \"hello world\" baz" -> ["foo", "hello world", "baz"]
///   "foo 'a b c' baz"         -> ["foo", "a b c", "baz"]
///
/// On a malformed input (unclosed quote) we fall back to plain
/// whitespace splitting -- this matches the reference's
/// `tryParseShellCommand` failure path so user templates don't
/// blow up on a stray quote.
pub fn parseArguments(allocator: std.mem.Allocator, args: []const u8) ![][]u8 {
    if (args.len == 0) return allocator.alloc([]u8, 0);

    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) return allocator.alloc([]u8, 0);

    return parseShellTokens(allocator, args) catch return splitOnWhitespace(allocator, args);
}

/// Free the slice returned by `parseArguments`.
pub fn freeParsed(allocator: std.mem.Allocator, parsed: [][]u8) void {
    for (parsed) |t| allocator.free(t);
    allocator.free(parsed);
}

fn parseShellTokens(allocator: std.mem.Allocator, args: []const u8) ![][]u8 {
    var out = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (out.items) |t| allocator.free(t);
        out.deinit();
    }

    var current = std_io.StringBuilder.init(allocator);
    defer current.deinit();

    var i: usize = 0;
    var in_single = false;
    var in_double = false;

    while (i < args.len) : (i += 1) {
        const c = args[i];

        if (in_single) {
            if (c == '\'') {
                in_single = false;
            } else {
                try current.append(c);
            }
            continue;
        }

        if (in_double) {
            if (c == '"') {
                in_double = false;
            } else if (c == '\\' and i + 1 < args.len) {
                const next = args[i + 1];
                // Inside double quotes only specific chars are
                // escapable; everything else keeps the backslash.
                if (next == '"' or next == '\\' or next == '$' or next == '`') {
                    try current.append(next);
                    i += 1;
                } else {
                    try current.append(c);
                }
            } else {
                try current.append(c);
            }
            continue;
        }

        // Unquoted context.
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            if (current.items().len > 0) {
                // Reserve the out slot BEFORE taking ownership so the
                // subsequent append is infallible. Otherwise an OOM in
                // `out.append` would orphan the toOwnedSlice result.
                try out.ensureUnusedCapacity(1);
                const owned = try current.toOwnedSlice();
                out.appendAssumeCapacity(owned);
            }
            continue;
        }
        if (c == '\'') {
            in_single = true;
            continue;
        }
        if (c == '"') {
            in_double = true;
            continue;
        }
        if (c == '\\' and i + 1 < args.len) {
            try current.append(args[i + 1]);
            i += 1;
            continue;
        }
        try current.append(c);
    }

    if (in_single or in_double) return error.UnterminatedQuote;

    if (current.items().len > 0) {
        try out.ensureUnusedCapacity(1);
        const owned = try current.toOwnedSlice();
        out.appendAssumeCapacity(owned);
    }

    return out.toOwnedSlice();
}

fn splitOnWhitespace(allocator: std.mem.Allocator, args: []const u8) ![][]u8 {
    var out = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (out.items) |t| allocator.free(t);
        out.deinit();
    }

    var it = std.mem.tokenizeAny(u8, args, " \t\r\n");
    while (it.next()) |tok| {
        try out.append(try allocator.dupe(u8, tok));
    }
    return out.toOwnedSlice();
}

/// Parse argument names from frontmatter. Accepts a space-separated
/// string and returns each token. Numeric-only names ("0", "1") are
/// rejected because they would collide with the $0, $1 shorthand.
/// Caller owns the returned slice and each inner slice.
pub fn parseArgumentNames(allocator: std.mem.Allocator, names_str: []const u8) ![][]u8 {
    var out = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (out.items) |n| allocator.free(n);
        out.deinit();
    }

    var it = std.mem.tokenizeAny(u8, names_str, " \t\r\n");
    while (it.next()) |raw| {
        if (raw.len == 0) continue;
        if (isAllDigits(raw)) continue;
        try out.append(try allocator.dupe(u8, raw));
    }
    return out.toOwnedSlice();
}

fn isAllDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// Generate a hint string of the remaining unfilled named args.
/// "[arg2] [arg3]". Returns null when every name has been filled.
/// Caller owns the returned slice when non-null.
pub fn generateProgressiveArgumentHint(
    allocator: std.mem.Allocator,
    arg_names: []const []const u8,
    typed_args: []const []const u8,
) !?[]u8 {
    if (typed_args.len >= arg_names.len) return null;
    const remaining = arg_names[typed_args.len..];
    if (remaining.len == 0) return null;

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    for (remaining, 0..) |name, idx| {
        if (idx > 0) try out.append(' ');
        try out.append('[');
        try out.appendSlice(name);
        try out.append(']');
    }
    const owned = try out.toOwnedSlice();
    return owned;
}

/// Substitute placeholders in `content` with `args`. When the
/// content has no recognised placeholder AND `append_if_no_placeholder`
/// is true AND args is non-empty, appends a "\n\nARGUMENTS: <args>"
/// block so the model still sees what the user typed. Caller owns
/// the returned slice.
pub fn substituteArguments(
    allocator: std.mem.Allocator,
    content: []const u8,
    args: []const u8,
    append_if_no_placeholder: bool,
    argument_names: []const []const u8,
) ![]u8 {
    // Empty args: there's nothing to substitute and nothing to
    // append. Return the content untouched.
    if (args.len == 0) return allocator.dupe(u8, content);

    const parsed = try parseArguments(allocator, args);
    defer freeParsed(allocator, parsed);

    var current = try allocator.dupe(u8, content);
    errdefer allocator.free(current);

    // Order matters: $ARGUMENTS[N] must be replaced BEFORE
    // $ARGUMENTS so the prefix doesn't eat the indexed form.

    // Phase 1: named args ($foo, $bar).
    for (argument_names, 0..) |name, i| {
        if (name.len == 0) continue;
        const replacement = if (i < parsed.len) parsed[i] else "";
        const next = try replaceNamedArg(allocator, current, name, replacement);
        allocator.free(current);
        current = next;
    }

    // Phase 2: indexed $ARGUMENTS[N].
    {
        const next = try replaceArgumentsIndexed(allocator, current, parsed);
        allocator.free(current);
        current = next;
    }

    // Phase 3: shorthand $0, $1, ... (NOT inside a longer ident).
    {
        const next = try replaceShortIndexed(allocator, current, parsed);
        allocator.free(current);
        current = next;
    }

    // Phase 4: full $ARGUMENTS.
    {
        const next = try replaceLiteralAll(allocator, current, "$ARGUMENTS", args);
        allocator.free(current);
        current = next;
    }

    // Append fallback: only when nothing in this whole pipeline
    // touched the content.
    if (append_if_no_placeholder and std.mem.eql(u8, current, content)) {
        defer allocator.free(current);
        return std.fmt.allocPrint(allocator, "{s}\n\nARGUMENTS: {s}", .{ content, args });
    }
    return current;
}

fn replaceNamedArg(
    allocator: std.mem.Allocator,
    content: []const u8,
    name: []const u8,
    replacement: []const u8,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < content.len) {
        if (content[i] == '$' and i + 1 + name.len <= content.len and
            std.mem.eql(u8, content[i + 1 .. i + 1 + name.len], name))
        {
            // The char after the name must NOT be '[' or a word
            // char. This prevents $foo from matching $foobar or
            // $foo[0]. Reference regex: `\\$${name}(?![\\[\\w])`.
            const after_idx = i + 1 + name.len;
            const after_ok = after_idx >= content.len or
                (content[after_idx] != '[' and !isWordChar(content[after_idx]));
            if (after_ok) {
                try out.appendSlice(replacement);
                i = after_idx;
                continue;
            }
        }
        try out.append(content[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

fn replaceArgumentsIndexed(
    allocator: std.mem.Allocator,
    content: []const u8,
    parsed: [][]u8,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    const prefix = "$ARGUMENTS[";
    var i: usize = 0;
    while (i < content.len) {
        if (i + prefix.len <= content.len and
            std.mem.eql(u8, content[i .. i + prefix.len], prefix))
        {
            var j: usize = i + prefix.len;
            const digit_start = j;
            while (j < content.len and content[j] >= '0' and content[j] <= '9') : (j += 1) {}
            if (j > digit_start and j < content.len and content[j] == ']') {
                const idx_str = content[digit_start..j];
                if (std.fmt.parseInt(usize, idx_str, 10)) |idx| {
                    const replacement: []const u8 = if (idx < parsed.len) parsed[idx] else "";
                    try out.appendSlice(replacement);
                    i = j + 1;
                    continue;
                } else |_| {}
            }
        }
        try out.append(content[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

fn replaceShortIndexed(
    allocator: std.mem.Allocator,
    content: []const u8,
    parsed: [][]u8,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < content.len) {
        if (content[i] == '$' and i + 1 < content.len and
            content[i + 1] >= '0' and content[i + 1] <= '9')
        {
            var j: usize = i + 1;
            while (j < content.len and content[j] >= '0' and content[j] <= '9') : (j += 1) {}
            // Reference regex `\\$(\\d+)(?!\\w)` -- the char after
            // the digits must not be a word char. Otherwise $0foo
            // shouldn't replace $0.
            const after_ok = j >= content.len or !isWordChar(content[j]);
            if (after_ok) {
                const idx_str = content[i + 1 .. j];
                if (std.fmt.parseInt(usize, idx_str, 10)) |idx| {
                    const replacement: []const u8 = if (idx < parsed.len) parsed[idx] else "";
                    try out.appendSlice(replacement);
                    i = j;
                    continue;
                } else |_| {}
            }
        }
        try out.append(content[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

fn replaceLiteralAll(
    allocator: std.mem.Allocator,
    content: []const u8,
    needle: []const u8,
    replacement: []const u8,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, content, cursor, needle)) |idx| {
        try out.appendSlice(content[cursor..idx]);
        try out.appendSlice(replacement);
        cursor = idx + needle.len;
    }
    try out.appendSlice(content[cursor..]);
    return out.toOwnedSlice();
}

fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_';
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "parseArguments splits whitespace-separated tokens" {
    const parsed = try parseArguments(testing.allocator, "foo bar baz");
    defer freeParsed(testing.allocator, parsed);
    try testing.expectEqual(@as(usize, 3), parsed.len);
    try testing.expectEqualStrings("foo", parsed[0]);
    try testing.expectEqualStrings("bar", parsed[1]);
    try testing.expectEqualStrings("baz", parsed[2]);
}

test "parseArguments respects double-quoted strings" {
    const parsed = try parseArguments(testing.allocator, "foo \"hello world\" baz");
    defer freeParsed(testing.allocator, parsed);
    try testing.expectEqual(@as(usize, 3), parsed.len);
    try testing.expectEqualStrings("foo", parsed[0]);
    try testing.expectEqualStrings("hello world", parsed[1]);
    try testing.expectEqualStrings("baz", parsed[2]);
}

test "parseArguments respects single-quoted strings" {
    const parsed = try parseArguments(testing.allocator, "foo 'a b c' baz");
    defer freeParsed(testing.allocator, parsed);
    try testing.expectEqual(@as(usize, 3), parsed.len);
    try testing.expectEqualStrings("a b c", parsed[1]);
}

test "parseArguments handles backslash escapes" {
    const parsed = try parseArguments(testing.allocator, "a\\ b c");
    defer freeParsed(testing.allocator, parsed);
    try testing.expectEqual(@as(usize, 2), parsed.len);
    try testing.expectEqualStrings("a b", parsed[0]);
    try testing.expectEqualStrings("c", parsed[1]);
}

test "parseArguments returns empty for whitespace-only input" {
    const parsed = try parseArguments(testing.allocator, "   \t\n");
    defer freeParsed(testing.allocator, parsed);
    try testing.expectEqual(@as(usize, 0), parsed.len);
}

test "parseArguments falls back to whitespace split on unterminated quote" {
    const parsed = try parseArguments(testing.allocator, "foo \"unterminated bar");
    defer freeParsed(testing.allocator, parsed);
    try testing.expect(parsed.len >= 2);
    try testing.expectEqualStrings("foo", parsed[0]);
}

test "parseArgumentNames drops numeric-only names" {
    const names = try parseArgumentNames(testing.allocator, "foo 0 bar 1 baz");
    defer freeParsed(testing.allocator, names);
    try testing.expectEqual(@as(usize, 3), names.len);
    try testing.expectEqualStrings("foo", names[0]);
    try testing.expectEqualStrings("bar", names[1]);
    try testing.expectEqualStrings("baz", names[2]);
}

test "generateProgressiveArgumentHint shows remaining slots" {
    const arg_names = [_][]const u8{ "first", "second", "third" };
    const typed = [_][]const u8{"alpha"};
    const hint = (try generateProgressiveArgumentHint(testing.allocator, &arg_names, &typed)) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(hint);
    try testing.expectEqualStrings("[second] [third]", hint);
}

test "generateProgressiveArgumentHint returns null when all filled" {
    const arg_names = [_][]const u8{ "a", "b" };
    const typed = [_][]const u8{ "x", "y" };
    try testing.expect((try generateProgressiveArgumentHint(testing.allocator, &arg_names, &typed)) == null);
}

test "substituteArguments replaces full $ARGUMENTS" {
    const out = try substituteArguments(testing.allocator, "Run: $ARGUMENTS now", "foo bar", true, &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Run: foo bar now", out);
}

test "substituteArguments replaces $ARGUMENTS[N] indexed form" {
    const out = try substituteArguments(testing.allocator, "first=$ARGUMENTS[0] second=$ARGUMENTS[1]", "foo bar baz", false, &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("first=foo second=bar", out);
}

test "substituteArguments replaces shorthand $0 $1" {
    const out = try substituteArguments(testing.allocator, "first=$0 second=$1", "alpha beta", false, &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("first=alpha second=beta", out);
}

test "substituteArguments leaves $0foo alone (word boundary)" {
    const out = try substituteArguments(testing.allocator, "literal $0foo here", "alpha beta", false, &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("literal $0foo here", out);
}

test "substituteArguments replaces named args from frontmatter" {
    const names = [_][]const u8{ "target", "mode" };
    const out = try substituteArguments(testing.allocator, "Review $target in $mode mode.", "src/main.zig fast", false, &names);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Review src/main.zig in fast mode.", out);
}

test "substituteArguments leaves $foobar alone when only $foo is named" {
    const names = [_][]const u8{"foo"};
    const out = try substituteArguments(testing.allocator, "match $foo nope $foobar", "alpha", false, &names);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("match alpha nope $foobar", out);
}

test "substituteArguments fills missing positional slots with empty" {
    const out = try substituteArguments(testing.allocator, "a=$ARGUMENTS[0] b=$ARGUMENTS[1] c=$ARGUMENTS[2]", "only-one", false, &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a=only-one b= c=", out);
}

test "substituteArguments appends ARGUMENTS line when no placeholder and append=true" {
    const out = try substituteArguments(testing.allocator, "Static template", "extra context", true, &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Static template\n\nARGUMENTS: extra context", out);
}

test "substituteArguments does NOT append when append=false" {
    const out = try substituteArguments(testing.allocator, "Static template", "extra context", false, &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Static template", out);
}

test "substituteArguments does NOT append when a placeholder already substituted" {
    const out = try substituteArguments(testing.allocator, "got: $ARGUMENTS", "the args", true, &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("got: the args", out);
}

test "substituteArguments does nothing when args is empty" {
    const out = try substituteArguments(testing.allocator, "got: $ARGUMENTS", "", true, &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("got: $ARGUMENTS", out);
}

test "substituteArguments respects $ARGUMENTS[N] before $ARGUMENTS prefix collision" {
    // If we replaced $ARGUMENTS first the [0] would be left dangling.
    const out = try substituteArguments(testing.allocator, "$ARGUMENTS[0]/$ARGUMENTS", "first second", false, &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("first/first second", out);
}
