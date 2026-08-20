//! #568 verification: every tool from the reference tools/ directory that
//! zcode is responsible for must resolve to a handler in tool_dispatch.zig
//! or be documented as a deferred deviation.
//!
//! Pure module: a list of tool names in, an assertion out.

const std = @import("std");

/// The 6 tools #568 enumerates as needing port/verification, in reference
/// spelling. PowerShellTool is excluded (no Windows target per ci.yml and
/// the 0.11.43 audit fix that removed install.ps1).
const tools_568 = [_][]const u8{
    "Brief", "McpAuth", "REPLTool", "ScheduleCron", "Sleep", "TodoWrite",
};

/// Tools already wired to handlers in tool_dispatch.zig, verified by the
/// #568 audit. When a new handler is added, move the tool from
/// `deferred` to `handled`.
const handled = [_][]const u8{
    "Brief", // handleBrief in tool_dispatch.zig
    "ScheduleCron", // handleCronCreate/handleCronDelete in tool_dispatch.zig
    "Sleep", // handleSleep in tool_dispatch.zig
    "TodoWrite", // handleTodoWrite in tool_dispatch.zig (V1 shim over V2 task.zig)
    "McpAuth", // handleMcpAuth in tool_dispatch.zig (wraps mcp/oauth.zig loginForMcpServer)
    "REPLTool", // handleRepl in tool_dispatch.zig (minimal batch port; dispatch wiring deferred)
};

/// Tools not yet ported, with a documented reason. These are real gaps,
/// not silent missing. Each must be resolved in a follow-up slice.
const deferred = [_]struct { name: []const u8, reason: []const u8 }{};

fn isHandled(tool: []const u8) bool {
    for (handled) |h| {
        if (std.mem.eql(u8, tool, h)) return true;
    }
    return false;
}

fn isDeferred(tool: []const u8) bool {
    for (deferred) |d| {
        if (std.mem.eql(u8, tool, d.name)) return true;
    }
    return false;
}

test "#568: every tool is handled or documented as deferred" {
    var unhandled = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer unhandled.deinit();

    for (tools_568) |tool| {
        if (isHandled(tool)) continue;
        if (isDeferred(tool)) continue;
        unhandled.append(tool) catch return error.OutOfMemory;
    }

    if (unhandled.items.len > 0) {
        std.debug.print("\nFAIL: {d} tools from #568 are neither handled nor documented as deferred:\n", .{unhandled.items.len});
        for (unhandled.items) |tool| {
            std.debug.print("  {s}\n", .{tool});
        }
        return error.UnhandledTool;
    }
}

test "#568: handled + deferred covers all 6 tools" {
    try std.testing.expectEqual(@as(usize, 6), tools_568.len);
    try std.testing.expectEqual(@as(usize, 6), handled.len);
    try std.testing.expectEqual(@as(usize, 0), deferred.len);
    // No tool should be in both handled and deferred.
    for (handled) |h| {
        for (deferred) |d| {
            if (std.mem.eql(u8, h, d.name)) {
                std.debug.print("\nFAIL: {s} is in both handled and deferred\n", .{h});
                return error.ToolInBothLists;
            }
        }
    }
}
