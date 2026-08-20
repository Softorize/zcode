//! P9 (PRD #534) reference-command coverage. Claude Code has a number of niche,
//! easter-egg, and cloud-dependent slash commands that zcode lacked, so typing
//! them returned "unknown command". This module recognizes them and returns an
//! appropriate response: a real answer for easter eggs, or a clearly-labeled
//! stub for features that need an external runtime / Anthropic backend we don't
//! run (documented deviations per the PRD). Pure: a command in, a message out.

const std = @import("std");

const Entry = struct { name: []const u8, message: []const u8 };

const entries = [_]Entry{
    // Easter eggs / fun
    // NOTE: /btw is NOT a stub. Phase 23 Task 06 gave it a real handler that
    // runs a non-interrupting side question against the model. It is dispatched
    // in repl_commands.zig (not here) so it must NOT be listed in this table.
    // NOTE: /good-claude is NOT a stub. #566 gave it a real handler in
    // repl_commands.zig that acknowledges positive feedback.
    // NOTE: /stickers is NOT a stub. #566 gave it a real handler in
    // repl_commands.zig that opens the sticker order page in a browser.
    // Cloud / external-dependency stubs (best-effort: command recognized, feature unavailable locally)
    .{ .name = "/voice", .message = "Voice input is unavailable in zcode: it needs microphone capture + a speech-to-text service this build does not bundle. Type your prompt instead." },
    .{ .name = "/teleport", .message = "Session teleport requires Anthropic cloud session sync, which zcode does not run. Use /export and /resume to move sessions locally." },
    .{ .name = "/remote-setup", .message = "Remote setup connects to Anthropic's remote-agent service, which zcode does not run. zcode operates fully locally against your configured provider." },
    .{ .name = "/remote-env", .message = "Remote environment management requires the remote-agent service zcode does not run." },
    .{ .name = "/mobile", .message = "Mobile pairing requires the Anthropic mobile bridge zcode does not run." },
    .{ .name = "/desktop", .message = "Desktop app handoff requires the Claude desktop app integration zcode does not run." },
    .{ .name = "/install-github-app", .message = "GitHub app install is an account-linking flow (authentication), which is out of scope for zcode. Use a GITHUB_TOKEN env var with the git/PR tooling instead." },
    .{ .name = "/install-slack-app", .message = "Slack app install is an account-linking flow (authentication), which is out of scope for zcode." },
    .{ .name = "/oauth-refresh", .message = "OAuth token refresh requires Anthropic's OAuth infrastructure, which zcode does not run. zcode uses provider API keys directly (see /config or `zcode keychain set`)." },
    // Diagnostics / limits (local stubs pointing at the nearest zcode feature)
    .{ .name = "/ant-trace", .message = "Internal request tracing is an Anthropic-internal diagnostic; use /debug-tool-call and ZCODE_VERBOSE=1 for zcode's local tracing." },
    .{ .name = "/passes", .message = "The compiler-passes view is Anthropic-internal and not applicable to zcode." },
    .{ .name = "/perf-issue", .message = "Use /feedback to file an issue; attach /stats output for performance context." },
    .{ .name = "/mock-limits", .message = "Rate-limit mocking is a testing-only command; not applicable to zcode's local provider config." },
    .{ .name = "/extra-usage", .message = "Extended usage/billing breakdown requires Anthropic account data; see /usage and /cost for zcode's local token/cost tracking." },
    .{ .name = "/privacy-settings", .message = "Privacy/telemetry is local-only in zcode (no phone-home). See /config for the telemetry and audit settings." },
    .{ .name = "/rate-limit-options", .message = "Rate-limit tuning is provider-side; configure provider_base_url / timeouts via /config." },
    .{ .name = "/reset-limits", .message = "Rate limits are enforced by your provider; zcode has nothing local to reset." },
    .{ .name = "/backfill-sessions", .message = "Session backfill imports cloud history; zcode sessions are local. Use /resume to pick an existing local session." },
    .{ .name = "/thinkback-play", .message = "Reasoning replay animation is unavailable; /thinkback shows recent reasoning traces as text." },
};

/// Return the response for a recognized reference command, or null if this
/// module does not handle it (the caller continues normal dispatch).
pub fn lookup(command: []const u8) ?[]const u8 {
    const head = blk: {
        const sp = std.mem.indexOfScalar(u8, command, ' ');
        break :blk if (sp) |i| command[0..i] else command;
    };
    for (entries) |e| {
        if (std.ascii.eqlIgnoreCase(head, e.name)) return e.message;
    }
    return null;
}

const testing = std.testing;

test "recognizes easter eggs and stubs" {
    // #566: /good-claude and /stickers moved from stubs to real handlers.
    try testing.expect(lookup("/good-claude") == null);
    try testing.expect(lookup("/stickers") == null);
    try testing.expect(lookup("/voice") != null);
    try testing.expect(lookup("/teleport") != null);
    try testing.expect(std.mem.indexOf(u8, lookup("/voice").?, "Voice") != null);
}

test "all 8 cloud-dependent commands are stubbed with dependency-explaining messages" {
    // #567: every cloud-dependent command must be recognized and its
    // message must explain the external dependency.
    const cloud_cmds = [_][]const u8{
        "/teleport", "/remote-setup",       "/remote-env",        "/mobile",
        "/desktop",  "/install-github-app", "/install-slack-app", "/oauth-refresh",
    };
    for (cloud_cmds) |cmd| {
        const msg = lookup(cmd) orelse {
            std.debug.print("\nFAIL: {s} not recognized as a stub\n", .{cmd});
            return error.MissingStub;
        };
        // Message must mention an external dependency, not just say "unavailable".
        const has_reason = std.mem.indexOf(u8, msg, "requires") != null or
            std.mem.indexOf(u8, msg, "out of scope") != null or
            std.mem.indexOf(u8, msg, "does not run") != null or
            std.mem.indexOf(u8, msg, "does not bundle") != null;
        if (!has_reason) {
            std.debug.print("\nFAIL: {s} stub message lacks dependency explanation: {s}\n", .{ cmd, msg });
            return error.MissingDependencyExplanation;
        }
    }
}

test "/btw is no longer a stub (real side-question handler)" {
    try testing.expect(lookup("/btw") == null);
    try testing.expect(lookup("/btw what is 2+2") == null);
}

test "matches the leading word and is case-insensitive" {
    try testing.expect(lookup("/REMOTE-SETUP") != null);
    try testing.expect(lookup("/mobile now") != null); // ignores args
}

test "returns null for unhandled commands" {
    try testing.expect(lookup("/model") == null);
    try testing.expect(lookup("/commit") == null);
    try testing.expect(lookup("not-a-command") == null);
}
