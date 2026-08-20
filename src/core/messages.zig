const std = @import("std");

/// Standard tool-use rejection / cancellation message strings ported
/// from claude-code-main/src/utils/messages.ts. The exact phrasings
/// matter: these are specific message shapes the model has been
/// trained to recognize and respond to consistently. Using a generic
/// "Cancelled by user." (zcode's previous default) leaves the model
/// to guess what to do next -- sometimes it retries the rejected
/// tool, sometimes it asks "should I continue?", sometimes it just
/// stops. Centralising on the reference vocabulary closes the gap.
/// Inserted into the assistant transcript when the user pressed
/// Ctrl-C / ESC during model streaming or before a tool call ran.
pub const INTERRUPT_MESSAGE = "[Request interrupted by user]";

/// Variant for the case where the interrupt landed mid-tool-call,
/// so the model knows the tool result will not arrive.
pub const INTERRUPT_MESSAGE_FOR_TOOL_USE = "[Request interrupted by user for tool use]";

/// Returned to the model when the user cancelled an interactive
/// approval prompt (chose "no" or pressed ESC). Tells the model to
/// stop the current plan and wait for further direction. The
/// imperative "STOP what you are doing" phrasing is load-bearing --
/// without it the model often retries the rejected tool with a
/// slightly different argument shape.
pub const CANCEL_MESSAGE = "The user doesn't want to take this action right now. STOP what you are doing and wait for the user to tell you how to proceed.";

/// Returned to the model when an approval was outright denied (not
/// just cancelled). Spells out that for an Edit, the new_string was
/// NOT written to the file -- the model can't assume the rejected
/// tool's side-effects happened.
pub const REJECT_MESSAGE = "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed.";

/// Same as REJECT_MESSAGE but with a trailing prefix where the
/// caller appends the user's free-text reason for the denial. The
/// model uses the reason verbatim to decide a workaround.
pub const REJECT_MESSAGE_WITH_REASON_PREFIX = "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). To tell you how to proceed, the user said:\n";

/// Variant returned to subagents (AgentRun children) when permission
/// was denied. Subagents can't escalate to the user, so the message
/// nudges them to try a different approach within the parent's
/// constraints rather than blocking on user input.
pub const SUBAGENT_REJECT_MESSAGE = "Permission for this tool use was denied. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). Try a different approach or report the limitation to complete your task.";

/// Subagent rejection with a free-text reason from the parent
/// approval policy.
pub const SUBAGENT_REJECT_MESSAGE_WITH_REASON_PREFIX = "Permission for this tool use was denied. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). The user said:\n";

/// Used when the user rejected a /plan in plan mode and chose to
/// stay in planning rather than execute. The full rejected plan is
/// appended after this prefix so the model can revise.
pub const PLAN_REJECTION_PREFIX = "The agent proposed a plan that was rejected by the user. The user chose to stay in plan mode rather than proceed with implementation.\n\nRejected plan:\n";

/// Workaround guidance attached to denial messages so the model
/// knows it can try alternate tools (e.g. head instead of cat) but
/// must not bypass the intent of the denial.
pub const DENIAL_WORKAROUND_GUIDANCE = "IMPORTANT: You *may* attempt to accomplish this action using other tools that might naturally be used to accomplish this goal, e.g. using head instead of cat. But you *should not* attempt to work around this denial in malicious ways, e.g. do not use your ability to run tests to execute non-test actions. You should only try to work around this restriction in reasonable ways that do not attempt to bypass the intent behind this denial. If you believe this capability is essential to complete the user's request, STOP and explain to the user what you were trying to do and why you need this permission. Let the user decide how to proceed.";

/// Synthetic tool_result content inserted when a tool_use block has
/// no matching tool_result (the executor crashed, the user killed
/// the process mid-call, etc). Used by the conversation-pairing
/// pass that reconstructs broken transcripts. Exported so any HFI
/// submission path can reject payloads containing it -- the
/// placeholder satisfies pairing structurally but its content is
/// fake.
pub const SYNTHETIC_TOOL_RESULT_PLACEHOLDER = "[Tool result missing due to internal error]";

/// Prefix used to mark classifier-denial messages so the UI can
/// render them concisely instead of dumping the whole rejection
/// message into the transcript.
pub const AUTO_MODE_REJECTION_PREFIX = "Permission for this action has been denied. Reason: ";

/// Build "Permission to use <tool> has been denied. <guidance>".
/// Returns an allocated string the caller owns. Mirrors the
/// reference's AUTO_REJECT_MESSAGE function at messages.ts:234.
pub fn buildAutoRejectMessage(allocator: std.mem.Allocator, tool_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "Permission to use {s} has been denied. {s}",
        .{ tool_name, DENIAL_WORKAROUND_GUIDANCE },
    );
}

/// Build the "don't ask mode" variant. Same shape as
/// buildAutoRejectMessage but with an extra clause explaining
/// the global mode setting so the model doesn't retry.
pub fn buildDontAskRejectMessage(allocator: std.mem.Allocator, tool_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "Permission to use {s} has been denied because zcode is running in don't ask mode. {s}",
        .{ tool_name, DENIAL_WORKAROUND_GUIDANCE },
    );
}

/// Build a rejection message with the user's free-text reason
/// appended. Returns an allocated copy.
pub fn buildRejectWithReason(allocator: std.mem.Allocator, reason: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ REJECT_MESSAGE_WITH_REASON_PREFIX, reason });
}

/// Cheap classifier-denial check used by the transcript renderer to
/// fold long rejection messages into a one-line summary.
pub fn isClassifierDenial(content: []const u8) bool {
    return std.mem.startsWith(u8, content, AUTO_MODE_REJECTION_PREFIX);
}

const testing = std.testing;

test "INTERRUPT_MESSAGE matches reference verbatim" {
    try testing.expectEqualStrings("[Request interrupted by user]", INTERRUPT_MESSAGE);
    try testing.expectEqualStrings("[Request interrupted by user for tool use]", INTERRUPT_MESSAGE_FOR_TOOL_USE);
}

test "CANCEL_MESSAGE contains the load-bearing STOP directive" {
    try testing.expect(std.mem.indexOf(u8, CANCEL_MESSAGE, "STOP what you are doing") != null);
    try testing.expect(std.mem.indexOf(u8, CANCEL_MESSAGE, "wait for the user") != null);
}

test "REJECT_MESSAGE warns that side-effects did not happen" {
    try testing.expect(std.mem.indexOf(u8, REJECT_MESSAGE, "NOT written to the file") != null);
    try testing.expect(std.mem.indexOf(u8, REJECT_MESSAGE, "STOP") != null);
}

test "buildAutoRejectMessage interpolates the tool name" {
    const msg = try buildAutoRejectMessage(testing.allocator, "Bash");
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "Permission to use Bash has been denied") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "head instead of cat") != null);
}

test "buildDontAskRejectMessage mentions zcode by name" {
    const msg = try buildDontAskRejectMessage(testing.allocator, "WebFetch");
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "Permission to use WebFetch") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "zcode is running in don't ask mode") != null);
}

test "buildRejectWithReason appends the user's reason" {
    const msg = try buildRejectWithReason(testing.allocator, "I want to review it manually first");
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, REJECT_MESSAGE_WITH_REASON_PREFIX) != null);
    try testing.expect(std.mem.indexOf(u8, msg, "review it manually") != null);
}

test "isClassifierDenial detects the auto-mode prefix" {
    try testing.expect(isClassifierDenial("Permission for this action has been denied. Reason: dangerous"));
    try testing.expect(!isClassifierDenial("Permission to use Bash has been denied."));
    try testing.expect(!isClassifierDenial(""));
}
