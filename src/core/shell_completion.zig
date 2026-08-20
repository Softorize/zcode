//! Shell tab-completion (bash-shell-06).
//!
//! Input-context-aware shell completion for the prompt input footer:
//! classifies the word under the cursor as a command, a file path, or a
//! variable reference, then shells out to the user's shell to expand it
//! (`compgen -c/-f/-v` for bash, `print -rl` builtins for zsh) with a 1s
//! timeout and a 15-suggestion cap.
//!
//! Ported (with simplifications) from claude-code-main
//! src/utils/bash/shellCompletion.ts:
//!   - parseInputContext (80-137): command vs file vs variable.
//!   - getBashCompletionCommand / zsh variants (142-179): compgen -c/-f/-v.
//!   - getShellCompletions (221-259): 1s timeout, 15-suggestion cap.
//!
//! The context parser (`parseInputContext`) is a pure function and is the
//! unit-tested core. The live expansion (`getShellCompletions`) is strictly
//! best-effort: it must never block the input loop (1s upper bound) and falls
//! back to null on any failure so the caller can use its PATH-scan command
//! list instead.

const std = @import("std");
const rt = @import("zcode_runtime");
const env = @import("env.zig");

/// Hard upper bound on how long the completion subprocess may run. The
/// reference uses a 1s timeout; we mirror it so the input loop never stalls.
const COMPLETION_TIMEOUT_NS: u64 = 1 * std.time.ns_per_s;

/// Maximum number of suggestions returned. Mirrors the reference 15-cap so a
/// noisy `compgen -f` in a huge directory cannot flood the footer.
pub const MAX_SUGGESTIONS: usize = 15;

/// Upper bound on the captured subprocess output. compgen can emit a lot of
/// lines; we only keep the first MAX_SUGGESTIONS, but bound the read anyway.
const OUTPUT_LIMIT: usize = 256 * 1024;

pub const InputContextKind = enum {
    command,
    file,
    variable,
};

pub const InputContext = struct {
    kind: InputContextKind,
    /// The substring under the cursor that we are completing (the "prefix"):
    /// for a variable this still includes the leading `$`; for a file it
    /// includes the path so far (`./sr`, `~/Doc`, `/usr/b`).
    prefix: []const u8,
};

/// Classify the word the cursor sits on inside `input`. `cursor` is a byte
/// offset into `input` (0..=input.len). Pure: the returned `prefix` is a slice
/// into `input`, so it borrows the caller's buffer and must not outlive it.
///
/// Rules (mirroring parseInputContext:80-137):
///   - The prefix is the run of "word" bytes ending at the cursor, where a
///     word boundary is unescaped whitespace, a pipe/operator, or the string
///     start. (We deliberately treat quotes simply; the live expander tolerates
///     a slightly-off prefix.)
///   - If the prefix begins with `$`, it is a variable.
///   - Else if the prefix looks like a path (starts with `/`, `./`, `../`,
///     `~`, or contains a `/`), it is a file.
///   - Else if there is a completed word before this one on the line (i.e.
///     this is not the first word), it is a file argument.
///   - Otherwise it is a command (the first word on the line).
pub fn parseInputContext(input: []const u8, cursor: usize) InputContext {
    const end = @min(cursor, input.len);

    // Walk backwards from the cursor to the start of the current word. A word
    // boundary is an unescaped space/tab or a shell separator we recognize.
    var start = end;
    while (start > 0) {
        const c = input[start - 1];
        if (isWordBoundary(c)) {
            // Respect a backslash-escaped boundary char (e.g. `foo\ bar` is one
            // word). If the boundary is escaped by an odd run of backslashes,
            // keep walking past it.
            if (c == ' ' or c == '\t') {
                var bs: usize = 0;
                var j = start - 1;
                while (j > 0 and input[j - 1] == '\\') : (j -= 1) bs += 1;
                if (bs % 2 == 1) {
                    // Escaped whitespace: step over the space and the escaping
                    // backslash, keep scanning the same word.
                    start -= 1;
                    continue;
                }
            }
            break;
        }
        start -= 1;
    }

    const prefix = input[start..end];

    // Variable: starts with `$`.
    if (prefix.len > 0 and prefix[0] == '$') {
        return .{ .kind = .variable, .prefix = prefix };
    }

    // File: an explicit path-looking prefix.
    if (looksLikePath(prefix)) {
        return .{ .kind = .file, .prefix = prefix };
    }

    // If there is a non-whitespace word before this one on the line, we are
    // completing an argument, which we treat as a file path. Scan the bytes
    // before `start` for any non-boundary content.
    if (hasPrecedingWord(input[0..start])) {
        return .{ .kind = .file, .prefix = prefix };
    }

    return .{ .kind = .command, .prefix = prefix };
}

fn isWordBoundary(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '|', '&', ';', '(', ')', '<', '>' => true,
        else => false,
    };
}

fn looksLikePath(prefix: []const u8) bool {
    if (prefix.len == 0) return false;
    if (prefix[0] == '/' or prefix[0] == '~') return true;
    if (std.mem.startsWith(u8, prefix, "./")) return true;
    if (std.mem.startsWith(u8, prefix, "../")) return true;
    // A slash anywhere in the prefix means a path (e.g. `src/main`).
    if (std.mem.indexOfScalar(u8, prefix, '/') != null) return true;
    return false;
}

/// True if there is a completed command word before the current word *within
/// the same pipeline segment*. A command separator (`|`, `&`, `;`, `(`, `)`,
/// `<`, `>`) starts a new segment, so the word right after a pipe is itself a
/// command, not an argument. We therefore only scan back to the nearest such
/// separator and check for a non-whitespace word in that span.
fn hasPrecedingWord(before: []const u8) bool {
    // Find the last segment separator; only consider bytes after it.
    var seg_start: usize = 0;
    var i: usize = before.len;
    while (i > 0) : (i -= 1) {
        const c = before[i - 1];
        if (isSegmentSeparator(c)) {
            seg_start = i;
            break;
        }
    }
    for (before[seg_start..]) |c| {
        // Whitespace is the only intra-segment boundary that matters here.
        if (c != ' ' and c != '\t' and c != '\n') return true;
    }
    return false;
}

fn isSegmentSeparator(c: u8) bool {
    return switch (c) {
        '|', '&', ';', '(', ')', '<', '>' => true,
        else => false,
    };
}

const ShellKind = enum { bash, zsh, sh };

fn detectShellKind() ShellKind {
    const shell = env.getenv("SHELL") orelse return .sh;
    if (std.mem.indexOf(u8, shell, "zsh") != null) return .zsh;
    if (std.mem.indexOf(u8, shell, "bash") != null) return .bash;
    return .sh;
}

fn shellBinPath() []const u8 {
    return env.getenv("SHELL") orelse "/bin/sh";
}

/// Build the one-shot shell script that lists completions for `ctx`. The
/// prefix is single-quoted into the script so a prefix containing shell
/// metacharacters cannot inject (we control the surrounding script; the prefix
/// is user keystrokes). Returns an owned slice the caller frees.
fn buildCompletionScript(
    allocator: std.mem.Allocator,
    kind: ShellKind,
    ctx: InputContext,
) ![]u8 {
    const helpers = @import("../tools/helpers.zig");

    // For variables strip the leading `$` before handing the name to the
    // shell builtin (compgen -v / typeset wants the bare name).
    var lookup = ctx.prefix;
    if (ctx.kind == .variable and lookup.len > 0 and lookup[0] == '$') {
        lookup = lookup[1..];
    }

    const quoted = try helpers.shellQuoteAlloc(allocator, lookup);
    defer allocator.free(quoted);

    return switch (kind) {
        .bash, .sh => switch (ctx.kind) {
            // compgen exists in bash; for plain sh it may be absent, in which
            // case the subprocess exits non-zero and we fall back to null.
            .command => try std.fmt.allocPrint(allocator, "compgen -c -- {s} 2>/dev/null", .{quoted}),
            .file => try std.fmt.allocPrint(allocator, "compgen -f -- {s} 2>/dev/null", .{quoted}),
            .variable => try std.fmt.allocPrint(allocator, "compgen -v -- {s} 2>/dev/null", .{quoted}),
        },
        .zsh => switch (ctx.kind) {
            // zsh has no compgen; use native enumeration builtins.
            // print -rl -- ${(k)commands} lists hashed external commands;
            // append builtins/functions for command context.
            .command => try std.fmt.allocPrint(
                allocator,
                "print -rl -- ${{(ko)commands}} ${{(ko)builtins}} ${{(ko)functions}} 2>/dev/null | grep -i -- {s} 2>/dev/null",
                .{quoted},
            ),
            .file => try std.fmt.allocPrint(allocator, "print -rl -- {s}*(N) 2>/dev/null", .{quoted}),
            .variable => try std.fmt.allocPrint(allocator, "print -rl -- ${{(ko)parameters}} 2>/dev/null | grep -i -- {s} 2>/dev/null", .{quoted}),
        },
    };
}

/// Run the live shell completion for the word under the cursor. Returns an
/// owned slice of owned suggestion strings (caller frees via `freeCompletions`)
/// or null if completion is unavailable / failed / produced nothing.
///
/// This is best-effort and 1s-bounded; callers should fall back to their
/// PATH-scan command list when this returns null.
pub fn getShellCompletions(
    allocator: std.mem.Allocator,
    input: []const u8,
    cursor: usize,
) !?[][]u8 {
    const ctx = parseInputContext(input, cursor);
    return getCompletionsForContext(allocator, ctx);
}

/// Same as `getShellCompletions` but takes an already-parsed context. Split
/// out so tests can exercise the exec path with a synthetic context.
pub fn getCompletionsForContext(
    allocator: std.mem.Allocator,
    ctx: InputContext,
) !?[][]u8 {
    const kind = detectShellKind();

    const script = try buildCompletionScript(allocator, kind, ctx);
    defer allocator.free(script);

    const shell = shellBinPath();

    const result = std.process.run(allocator, rt.io, .{
        .argv = &[_][]const u8{ shell, "-c", script },
        .stdout_limit = .limited(OUTPUT_LIMIT),
        .stderr_limit = .limited(OUTPUT_LIMIT),
        .timeout = .{ .duration = .{ .raw = .{ .nanoseconds = COMPLETION_TIMEOUT_NS }, .clock = .awake } },
    }) catch {
        // Timeout, spawn failure, missing compgen, etc. -> no live completion.
        return null;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) return null;

    return try parseCompletionLines(allocator, result.stdout);
}

/// Split subprocess stdout into up to MAX_SUGGESTIONS deduplicated,
/// non-empty, owned lines. Returns null when there is nothing usable so the
/// caller can fall through to its fallback. Pure over `stdout`.
pub fn parseCompletionLines(allocator: std.mem.Allocator, stdout: []const u8) !?[][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var it = std.mem.tokenizeScalar(u8, stdout, '\n');
    while (it.next()) |raw| {
        if (list.items.len >= MAX_SUGGESTIONS) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (seen.contains(line)) continue;

        const owned = try allocator.dupe(u8, line);
        seen.put(owned, {}) catch {
            allocator.free(owned);
            continue;
        };
        try list.append(allocator, owned);
    }

    if (list.items.len == 0) {
        list.deinit(allocator);
        return null;
    }
    return try list.toOwnedSlice(allocator);
}

/// Free a slice returned by `getShellCompletions` / `parseCompletionLines`.
pub fn freeCompletions(allocator: std.mem.Allocator, completions: [][]u8) void {
    for (completions) |c| allocator.free(c);
    allocator.free(completions);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseInputContext: variable" {
    const ctx = parseInputContext("$HO", 3);
    try testing.expectEqual(InputContextKind.variable, ctx.kind);
    try testing.expectEqualStrings("$HO", ctx.prefix);
}

test "parseInputContext: file with explicit ./ path" {
    const input = "ls ./sr";
    const ctx = parseInputContext(input, input.len);
    try testing.expectEqual(InputContextKind.file, ctx.kind);
    try testing.expectEqualStrings("./sr", ctx.prefix);
}

test "parseInputContext: command as first word" {
    const ctx = parseInputContext("gi", 2);
    try testing.expectEqual(InputContextKind.command, ctx.kind);
    try testing.expectEqualStrings("gi", ctx.prefix);
}

test "parseInputContext: argument after a command word is a file" {
    // Second bare word, no slash -> treated as a file argument.
    const input = "git che";
    const ctx = parseInputContext(input, input.len);
    try testing.expectEqual(InputContextKind.file, ctx.kind);
    try testing.expectEqualStrings("che", ctx.prefix);
}

test "parseInputContext: absolute path is a file" {
    const input = "cat /usr/b";
    const ctx = parseInputContext(input, input.len);
    try testing.expectEqual(InputContextKind.file, ctx.kind);
    try testing.expectEqualStrings("/usr/b", ctx.prefix);
}

test "parseInputContext: tilde path is a file" {
    const input = "cd ~/Doc";
    const ctx = parseInputContext(input, input.len);
    try testing.expectEqual(InputContextKind.file, ctx.kind);
    try testing.expectEqualStrings("~/Doc", ctx.prefix);
}

test "parseInputContext: variable in argument position" {
    const input = "echo $HOM";
    const ctx = parseInputContext(input, input.len);
    try testing.expectEqual(InputContextKind.variable, ctx.kind);
    try testing.expectEqualStrings("$HOM", ctx.prefix);
}

test "parseInputContext: cursor mid-line stops at cursor" {
    // Cursor after "gi" in "git status" -> prefix is "gi", command context.
    const ctx = parseInputContext("git status", 2);
    try testing.expectEqual(InputContextKind.command, ctx.kind);
    try testing.expectEqualStrings("gi", ctx.prefix);
}

test "parseInputContext: word after a pipe is a command" {
    const input = "cat x | gr";
    const ctx = parseInputContext(input, input.len);
    try testing.expectEqual(InputContextKind.command, ctx.kind);
    try testing.expectEqualStrings("gr", ctx.prefix);
}

test "parseInputContext: escaped space keeps one word" {
    // `ls foo\ ba` -> the escaped space does not split the file prefix.
    const input = "ls foo\\ ba";
    const ctx = parseInputContext(input, input.len);
    // No slash and there is a preceding word -> file argument.
    try testing.expectEqual(InputContextKind.file, ctx.kind);
    try testing.expectEqualStrings("foo\\ ba", ctx.prefix);
}

test "parseInputContext: empty prefix at trailing space is a file arg" {
    const input = "git ";
    const ctx = parseInputContext(input, input.len);
    try testing.expectEqual(InputContextKind.file, ctx.kind);
    try testing.expectEqualStrings("", ctx.prefix);
}

test "parseCompletionLines: dedup, trim, cap" {
    const stdout = "git\ngit-lfs\n\ngit\n  gh  \n";
    const res = (try parseCompletionLines(testing.allocator, stdout)).?;
    defer freeCompletions(testing.allocator, res);
    try testing.expectEqual(@as(usize, 3), res.len);
    try testing.expectEqualStrings("git", res[0]);
    try testing.expectEqualStrings("git-lfs", res[1]);
    try testing.expectEqualStrings("gh", res[2]);
}

test "parseCompletionLines: respects MAX_SUGGESTIONS cap" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var i: usize = 0;
    while (i < MAX_SUGGESTIONS + 10) : (i += 1) {
        const line = try std.fmt.allocPrint(testing.allocator, "entry{d}\n", .{i});
        defer testing.allocator.free(line);
        try buf.appendSlice(testing.allocator, line);
    }
    const res = (try parseCompletionLines(testing.allocator, buf.items)).?;
    defer freeCompletions(testing.allocator, res);
    try testing.expectEqual(MAX_SUGGESTIONS, res.len);
}

test "parseCompletionLines: empty input yields null" {
    try testing.expect((try parseCompletionLines(testing.allocator, "")) == null);
    try testing.expect((try parseCompletionLines(testing.allocator, "\n  \n\t\n")) == null);
}

test "buildCompletionScript: bash command uses compgen -c" {
    const ctx = InputContext{ .kind = .command, .prefix = "gi" };
    const script = try buildCompletionScript(testing.allocator, .bash, ctx);
    defer testing.allocator.free(script);
    try testing.expect(std.mem.indexOf(u8, script, "compgen -c") != null);
    try testing.expect(std.mem.indexOf(u8, script, "gi") != null);
}

test "buildCompletionScript: bash file uses compgen -f" {
    const ctx = InputContext{ .kind = .file, .prefix = "./sr" };
    const script = try buildCompletionScript(testing.allocator, .bash, ctx);
    defer testing.allocator.free(script);
    try testing.expect(std.mem.indexOf(u8, script, "compgen -f") != null);
}

test "buildCompletionScript: variable strips leading dollar for compgen -v" {
    const ctx = InputContext{ .kind = .variable, .prefix = "$HO" };
    const script = try buildCompletionScript(testing.allocator, .bash, ctx);
    defer testing.allocator.free(script);
    try testing.expect(std.mem.indexOf(u8, script, "compgen -v") != null);
    // The `$` must not be passed to compgen -v (it wants the bare name).
    try testing.expect(std.mem.indexOf(u8, script, "'HO'") != null);
    try testing.expect(std.mem.indexOf(u8, script, "$HO") == null);
}

test "buildCompletionScript: zsh command uses print -rl commands" {
    const ctx = InputContext{ .kind = .command, .prefix = "gi" };
    const script = try buildCompletionScript(testing.allocator, .zsh, ctx);
    defer testing.allocator.free(script);
    try testing.expect(std.mem.indexOf(u8, script, "print -rl") != null);
    try testing.expect(std.mem.indexOf(u8, script, "commands") != null);
}
