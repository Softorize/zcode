const std = @import("std");

/// Per-command exit-code interpretation, ported from
/// claude-code-main/src/tools/BashTool/commandSemantics.ts.
///
/// Several POSIX tools use exit codes to convey informational outcomes
/// rather than errors. The most common offenders:
///
///   grep / rg : exit 1 -> "no matches found" (NOT an error)
///   find      : exit 1 -> "some directories were inaccessible" (partial)
///   diff      : exit 1 -> "files differ" (the whole point of running diff!)
///   test / [  : exit 1 -> "condition is false" (the whole point of test!)
///
/// zcode's bash card renderer used to flag any non-zero exit as an
/// error, which produced a flood of red "tool reported an error" cards
/// on perfectly successful searches and conditionals. This module
/// classifies the exit code based on the command name extracted from
/// the bash trace, returning a tuple of (is_error, optional message).
///
/// Pure data + a couple of tiny string-prefix helpers; no allocator
/// required. Callers can call this from any rendering pass that has
/// the command line and exit code in hand.
pub const Result = struct {
    is_error: bool,
    /// Optional informational message that callers may append to a
    /// warning/info footer when the exit code was non-zero but not an
    /// error (e.g. "no matches found" for grep exit 1). Lives in
    /// rodata so callers do not need to free it.
    message: ?[]const u8,
};

pub fn interpret(command: []const u8, exit_code: i32) Result {
    const base = extractBaseCommand(command);
    if (base.len == 0) return defaultSemantic(exit_code);

    if (eql(base, "grep") or eql(base, "rg")) {
        return .{
            .is_error = exit_code >= 2,
            .message = if (exit_code == 1) "no matches found" else null,
        };
    }
    if (eql(base, "find")) {
        return .{
            .is_error = exit_code >= 2,
            .message = if (exit_code == 1) "some directories were inaccessible" else null,
        };
    }
    if (eql(base, "diff")) {
        return .{
            .is_error = exit_code >= 2,
            .message = if (exit_code == 1) "files differ" else null,
        };
    }
    if (eql(base, "test") or eql(base, "[")) {
        return .{
            .is_error = exit_code >= 2,
            .message = if (exit_code == 1) "condition is false" else null,
        };
    }

    return defaultSemantic(exit_code);
}

fn defaultSemantic(exit_code: i32) Result {
    return .{
        .is_error = exit_code != 0,
        .message = null,
    };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Heuristically extract the base command name from a possibly
/// piped or chained shell command line. The reference uses a full
/// splitCommand_DEPRECATED parser; zcode uses a simpler "last
/// segment after | / && / ; , and then the first word" because the
/// pipe-end command is the one whose exit code the shell returns.
///
/// Examples:
///   "grep foo file.txt"           -> "grep"
///   "cat foo.txt | grep bar"      -> "grep"
///   "ls && diff a b"              -> "diff"
///   "ls; rm -rf /tmp"             -> "rm"
///
/// Limitations:
///   - Quoted segments containing pipes (e.g. `echo "a|b" | grep`) are
///     handled correctly because we honour single/double quotes.
///   - Subshell exits (`(cmd1; cmd2)`) defer to whatever's at the end
///     of the outer command line, which is still the right answer for
///     the visible exit code.
pub fn extractBaseCommand(command: []const u8) []const u8 {
    if (command.len == 0) return "";

    // Find the last unquoted segment separator. Walk forward so we can
    // handle quotes correctly; the last separator we see wins.
    var i: usize = 0;
    var last_break: usize = 0;
    var in_single = false;
    var in_double = false;
    while (i < command.len) : (i += 1) {
        const c = command[i];
        if (in_single) {
            if (c == '\'') in_single = false;
            continue;
        }
        if (in_double) {
            if (c == '"' and (i == 0 or command[i - 1] != '\\')) in_double = false;
            continue;
        }
        switch (c) {
            '\'' => in_single = true,
            '"' => in_double = true,
            '|' => {
                // Skip || (logical or)
                if (i + 1 < command.len and command[i + 1] == '|') {
                    last_break = i + 2;
                    i += 1;
                } else {
                    last_break = i + 1;
                }
            },
            ';' => last_break = i + 1,
            '&' => {
                // && counts; single & is background which we still want to follow
                if (i + 1 < command.len and command[i + 1] == '&') {
                    last_break = i + 2;
                    i += 1;
                }
            },
            else => {},
        }
    }

    // Skip leading whitespace and pull the first word.
    var start = last_break;
    while (start < command.len and (command[start] == ' ' or command[start] == '\t')) : (start += 1) {}
    var end = start;
    while (end < command.len and command[end] != ' ' and command[end] != '\t' and command[end] != '\n') : (end += 1) {}
    if (end <= start) return "";
    return command[start..end];
}

const testing = std.testing;

test "extractBaseCommand returns first word of simple command" {
    try testing.expectEqualStrings("grep", extractBaseCommand("grep foo bar"));
    try testing.expectEqualStrings("ls", extractBaseCommand("ls -la"));
    try testing.expectEqualStrings("git", extractBaseCommand("git status"));
}

test "extractBaseCommand follows pipes to final segment" {
    try testing.expectEqualStrings("grep", extractBaseCommand("cat file.txt | grep foo"));
    try testing.expectEqualStrings("wc", extractBaseCommand("ls -la | grep src | wc -l"));
}

test "extractBaseCommand follows && / ; chains" {
    try testing.expectEqualStrings("diff", extractBaseCommand("ls && diff a b"));
    try testing.expectEqualStrings("rm", extractBaseCommand("ls; rm -rf /tmp"));
}

test "extractBaseCommand respects quoted pipes" {
    try testing.expectEqualStrings("echo", extractBaseCommand("echo \"a|b\""));
    try testing.expectEqualStrings("echo", extractBaseCommand("echo 'a|b|c'"));
}

test "extractBaseCommand returns empty for empty or whitespace input" {
    try testing.expectEqualStrings("", extractBaseCommand(""));
    try testing.expectEqualStrings("", extractBaseCommand("   "));
}

test "interpret grep exit 1 is not an error" {
    const r = interpret("grep foo *.zig", 1);
    try testing.expect(!r.is_error);
    try testing.expect(r.message != null);
    try testing.expectEqualStrings("no matches found", r.message.?);
}

test "interpret rg exit 1 is not an error" {
    const r = interpret("rg --type zig foo", 1);
    try testing.expect(!r.is_error);
    try testing.expectEqualStrings("no matches found", r.message.?);
}

test "interpret grep exit 2 IS an error" {
    const r = interpret("grep foo missing.txt", 2);
    try testing.expect(r.is_error);
    try testing.expect(r.message == null);
}

test "interpret diff exit 1 means files differ" {
    const r = interpret("diff a.txt b.txt", 1);
    try testing.expect(!r.is_error);
    try testing.expectEqualStrings("files differ", r.message.?);
}

test "interpret find exit 1 is partial success" {
    const r = interpret("find / -name foo", 1);
    try testing.expect(!r.is_error);
    try testing.expect(std.mem.indexOf(u8, r.message.?, "inaccessible") != null);
}

test "interpret test exit 1 is condition false" {
    const r = interpret("test -f foo.txt", 1);
    try testing.expect(!r.is_error);
    try testing.expectEqualStrings("condition is false", r.message.?);
}

test "interpret unknown command falls back to default" {
    const r = interpret("kubectl get pods", 1);
    try testing.expect(r.is_error);
    try testing.expect(r.message == null);
}

test "interpret zero exit is never an error" {
    try testing.expect(!interpret("anything", 0).is_error);
    try testing.expect(!interpret("grep foo bar", 0).is_error);
    try testing.expect(!interpret("diff a b", 0).is_error);
}

test "interpret follows pipes to last command" {
    // Even though grep's exit is 1, the pipeline's exit code is wc's.
    // wc's default semantic treats 1 as error. Confirms we route by the
    // final command, not the first.
    const r = interpret("grep foo bar | wc -l", 1);
    try testing.expect(r.is_error);
}
