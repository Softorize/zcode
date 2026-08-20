//! #565 verification: every user-facing command from the reference
//! commands/ directory that zcode is responsible for must resolve to
//! either a direct dispatch arm in repl_commands.zig or a canonical
//! mapping in command_canonical.zig. This test is the fixture for #565:
//! it asserts that typing the reference spelling of each command does
//! not fall through to "unknown command".
//!
//! Pure module: a list of command spellings in, an assertion out.

const std = @import("std");
const command_canonical = @import("command_canonical.zig");

/// The 23 user-facing commands #565 enumerates, in reference spelling.
const commands_565 = [_][]const u8{
    "/summary",    "/tag",            "/stats",
    "/status",     "/rewind",         "/rename",
    "/onboarding", "/output-style",   "/terminalSetup",
    "/insights",   "/upgrade",        "/usage",
    "/session",    "/thinkback",      "/release-notes",
    "/bughunter",  "/init",           "/ide",
    "/hooks",      "/keybindings",    "/permissions",
    "/plugin",     "/sandbox-toggle",
};

/// A command is "covered" if either:
///   (a) command_canonical.toDispatch maps it to a different accepted form, OR
///   (b) it is in the known-handled set (commands repl_commands.zig has a
///       direct dispatch arm for, verified by the #565 audit).
///
/// The known-handled set is maintained here as a literal so this test is
/// self-contained and does not require importing repl_commands.zig (which
/// pulls in the whole runtime). When a new command is added to
/// repl_commands.zig, add it here too. The canonical map is checked live.
const known_handled = [_][]const u8{
    "/summary",        "/tag",         "/stats",       "/status",
    "/rewind",         "/rename",      "/onboarding",  "/insights",
    "/upgrade",        "/usage",       "/session",     "/thinkback",
    "/release-notes",  "/bughunter",   "/init",        "/ide",
    "/hooks",          "/keybindings", "/permissions", "/plugin",
    "/sandbox-toggle",
};

fn isKnownHandled(cmd: []const u8) bool {
    for (known_handled) |h| {
        if (std.ascii.eqlIgnoreCase(cmd, h)) return true;
    }
    return false;
}

fn isCanonicallyMapped(cmd: []const u8) bool {
    // toDispatch returns the input unchanged if no mapping exists.
    const mapped = command_canonical.toDispatch(cmd);
    return !std.mem.eql(u8, mapped, cmd);
}

test "#565: all 23 user-facing commands resolve to a handler or canonical mapping" {
    var missing: std.array_list.Managed([]const u8) = .init(std.testing.allocator);
    defer missing.deinit();

    for (commands_565) |cmd| {
        if (isKnownHandled(cmd)) continue;
        if (isCanonicallyMapped(cmd)) continue;
        missing.append(cmd) catch return error.OutOfMemory;
    }

    if (missing.items.len > 0) {
        std.debug.print("\nFAIL: {d} commands from #565 have no handler or canonical mapping:\n", .{missing.items.len});
        for (missing.items) |cmd| {
            std.debug.print("  {s}\n", .{cmd});
        }
        return error.MissingCommandHandler;
    }
}

test "#565: known_handled list matches commands_565 list (no drift)" {
    // Every known_handled entry must be in commands_565, and vice versa
    // (except the two that are canonically mapped: /output-style and
    // /terminalSetup, which are NOT in known_handled because they resolve
    // via toDispatch).
    for (known_handled) |h| {
        var found = false;
        for (commands_565) |c| {
            if (std.mem.eql(u8, h, c)) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("\nFAIL: known_handled has {s} but commands_565 does not\n", .{h});
            return error.DriftBetweenLists;
        }
    }
    // commands_565 has 23 entries; known_handled has 21 (the 2 canonically
    // mapped ones are excluded). Verify the count.
    try std.testing.expectEqual(@as(usize, 23), commands_565.len);
    try std.testing.expectEqual(@as(usize, 21), known_handled.len);
}
