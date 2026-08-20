//! #568: McpAuth tool - starts the MCP server OAuth flow.
//!
//! Direct port of reference src/tools/McpAuthTool/McpAuthTool.ts.
//! In the reference, McpAuth is a pseudo-tool created dynamically per
//! unauthenticated MCP server. When called, it starts the OAuth flow
//! and returns the authorization URL for the user to open.
//!
//! zcode already has the OAuth flow in src/mcp/oauth.zig
//! (loginForMcpServer). This tool wraps it as a model-facing tool so
//! the agent can trigger MCP authentication on the user's behalf.

const std = @import("std");
const oauth = @import("../mcp/oauth.zig");
const arg_parse = @import("arg_parse.zig");

pub const McpAuthStatus = enum {
    auth_url,
    unsupported,
    error_state,
};

pub const McpAuthResult = struct {
    status: McpAuthStatus,
    message: []const u8,
    auth_url: ?[]const u8 = null,
};

/// Execute the McpAuth tool. Takes a server name and transport URL,
/// starts the OAuth flow, and returns the authorization URL.
pub fn execute(allocator: std.mem.Allocator, args: []const u8) ![]u8 {
    const server_name = arg_parse.getArg(args, "server") orelse {
        return allocator.dupe(u8, "McpAuth requires a 'server' argument (the MCP server name)");
    };
    const transport_url = arg_parse.getArg(args, "url") orelse {
        return std.fmt.allocPrint(
            allocator,
            "MCP server '{s}' requires a 'url' argument to start the OAuth flow.",
            .{server_name},
        );
    };

    // Start the OAuth flow. loginForMcpServer returns an OAuthLoginOutcome
    // (success with auth_url, or provider_error).
    var outcome = oauth.loginForMcpServer(allocator, transport_url) catch |err| {
        return std.fmt.allocPrint(
            allocator,
            "MCP auth failed for server '{s}': {s}",
            .{ server_name, @errorName(err) },
        );
    };
    defer outcome.deinit(allocator);

    switch (outcome) {
        .success => |result| {
            return std.fmt.allocPrint(
                allocator,
                "MCP server '{s}' requires authentication. Open this URL in your browser to authorize:\n{s}\n\nOnce authorized, the server's tools will become available automatically.",
                .{ server_name, result.auth_url },
            );
        },
        .provider_error => |failure| {
            const desc: []const u8 = failure.description orelse failure.error_code;
            return std.fmt.allocPrint(
                allocator,
                "MCP server '{s}' authentication failed: {s}",
                .{ server_name, desc },
            );
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "execute: missing 'server' arg returns guidance" {
    const result = try execute(testing.allocator, "");
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "requires a 'server' argument") != null);
}

test "execute: missing 'url' arg returns guidance with server name" {
    const result = try execute(testing.allocator, "server=myserver");
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "myserver") != null);
    try testing.expect(std.mem.indexOf(u8, result, "'url' argument") != null);
}
