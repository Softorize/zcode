//! misc-utils-13: synthetic transcript framing for the bare `!`-prefix bash
//! input fast-path.
//!
//! When the user types `!<cmd>` in the REPL, the command runs through the Bash
//! path (sandbox disabled) and the result is folded back into the transcript as
//! a synthetic context block so the next model turn sees both the command the
//! user ran and its output -- without the agent itself having issued the call.
//!
//! The reference (`processBashCommand.tsx:17-138`) frames this as a synthetic
//! "caveat" user message wrapping `<bash-input>`/`<bash-stdout>`/`<bash-stderr>`
//! tags. This module is the pure, allocation-only core of that framing so it can
//! be unit-tested without driving the interactive REPL loop.
//!
//! Deep module: a pure function of `(input, stdout, stderr)`. No IO, no env, no
//! `rt.io`.

const std = @import("std");

/// The synthetic caveat preamble. Attributing the block to the user (not the
/// agent) is load-bearing: it tells the model the human ran this command
/// directly, so the model treats the output as observed context rather than as
/// something it produced. Plain hyphens only (no em/en dashes) per project rule.
pub const caveat =
    "Caveat: The user ran the following bash command directly via the `!` input " ++
    "prefix. The output below is provided as context for the conversation; you " ++
    "did not run it.";

/// Build the synthetic transcript block for a `!`-prefixed bash command.
///
/// Always emits `<bash-input>` and `<bash-stdout>`; emits `<bash-stderr>` only
/// when `stderr` is non-empty (matches the reference, which omits the stderr
/// tag when there is nothing on stderr). The leading `caveat` line frames the
/// block as user-originated. Caller owns the returned slice.
pub fn buildBashInputFraming(
    allocator: std.mem.Allocator,
    input: []const u8,
    stdout: []const u8,
    stderr: []const u8,
) ![]u8 {
    const trimmed_input = std.mem.trim(u8, input, " \t\r\n");
    if (stderr.len > 0) {
        return std.fmt.allocPrint(
            allocator,
            "{s}\n<bash-input>{s}</bash-input>\n<bash-stdout>{s}</bash-stdout>\n<bash-stderr>{s}</bash-stderr>",
            .{ caveat, trimmed_input, stdout, stderr },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{s}\n<bash-input>{s}</bash-input>\n<bash-stdout>{s}</bash-stdout>",
        .{ caveat, trimmed_input, stdout },
    );
}

const testing = std.testing;

test "buildBashInputFraming wraps input and stdout" {
    const out = try buildBashInputFraming(testing.allocator, "echo hi", "hi\n", "");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "<bash-input>echo hi</bash-input>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<bash-stdout>hi\n</bash-stdout>") != null);
    // No stderr tag when stderr is empty.
    try testing.expect(std.mem.indexOf(u8, out, "<bash-stderr>") == null);
    // Attributed to the user via the caveat preamble.
    try testing.expect(std.mem.indexOf(u8, out, "did not run it.") != null);
}

test "buildBashInputFraming includes stderr when present" {
    const out = try buildBashInputFraming(testing.allocator, "ls /nope", "", "No such file\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "<bash-input>ls /nope</bash-input>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<bash-stdout></bash-stdout>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<bash-stderr>No such file\n</bash-stderr>") != null);
}

test "buildBashInputFraming trims surrounding whitespace from input" {
    const out = try buildBashInputFraming(testing.allocator, "  echo hi  ", "hi\n", "");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "<bash-input>echo hi</bash-input>") != null);
}

test "no em or en dashes in caveat" {
    try testing.expect(std.mem.indexOf(u8, caveat, "\u{2014}") == null);
    try testing.expect(std.mem.indexOf(u8, caveat, "\u{2013}") == null);
}
