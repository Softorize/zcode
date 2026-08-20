//! MCP tool-name normalization to the canonical `mcp__<server>__<tool>` scheme.
//!
//! Ported from the reference project's `normalization.ts` and `mcpStringUtils.ts`.
//! Pure: no dependencies beyond std. Builders allocate; the parser returns
//! slices into its input (no allocation).
//!
//! Reference behavior:
//! - `normalizeNameForMCP(name)`: replace every char NOT in `[a-zA-Z0-9_-]` with
//!   `_`. For names starting with `"claude.ai "` additionally collapse runs of
//!   `_` to a single `_` and strip leading/trailing `_` (normalization.ts:17-23).
//! - `getMcpPrefix(server)` = `mcp__{normalize(server)}__` (mcpStringUtils.ts:19-25).
//! - `buildMcpToolName(server, tool)` = prefix + `normalize(tool)` (mcpStringUtils.ts:31-37).
//! - `mcpInfoFromString(s)` splits on `__`, requires first token `mcp` and a
//!   non-empty server, rejoins the remainder (preserving `__` in tool names) as
//!   the tool (mcpStringUtils.ts:43-52).

const std = @import("std");

const CLAUDE_AI_PREFIX = "claude.ai ";

/// Returns true if `c` is an allowed MCP name character: `[a-zA-Z0-9_-]`.
fn isAllowedMcpChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_' or
        c == '-';
}

/// Normalize an MCP server/tool name: replace every char not in `[a-zA-Z0-9_-]`
/// with `_`. For names starting with `"claude.ai "` additionally collapse runs
/// of `_` to a single `_` and strip leading/trailing `_`.
///
/// Caller owns the returned slice.
pub fn normalizeNameForMCP(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    // First pass: char-by-char substitution.
    var replaced = try allocator.alloc(u8, name.len);
    errdefer allocator.free(replaced);
    for (name, 0..) |c, i| {
        replaced[i] = if (isAllowedMcpChar(c)) c else '_';
    }

    // The reference applies the collapse pass only when the ORIGINAL name starts
    // with the "claude.ai " literal prefix.
    if (!std.mem.startsWith(u8, name, CLAUDE_AI_PREFIX)) {
        return replaced;
    }

    // Second pass: collapse runs of `_` to a single `_`, then trim
    // leading/trailing `_`. Build into a fresh buffer and free the first.
    defer allocator.free(replaced);
    var collapsed = std.array_list.Managed(u8).init(allocator);
    errdefer collapsed.deinit();
    var prev_underscore = false;
    for (replaced) |c| {
        if (c == '_') {
            if (prev_underscore) continue;
            prev_underscore = true;
        } else {
            prev_underscore = false;
        }
        try collapsed.append(c);
    }
    var result = try collapsed.toOwnedSlice();
    // Trim leading/trailing `_`.
    const trimmed = std.mem.trim(u8, result, "_");
    if (trimmed.len == result.len) return result;
    // Shift the trimmed content to the front and resize.
    std.mem.copyForwards(u8, result[0..trimmed.len], trimmed);
    return allocator.realloc(result, trimmed.len);
}

/// Returns the MCP prefix for a server: `mcp__{normalize(server)}__`.
/// Caller owns the returned slice.
pub fn getMcpPrefix(allocator: std.mem.Allocator, server: []const u8) ![]u8 {
    const norm = try normalizeNameForMCP(allocator, server);
    defer allocator.free(norm);
    return std.fmt.allocPrint(allocator, "mcp__{s}__", .{norm});
}

/// Builds the canonical MCP tool name `mcp__{normalize(server)}__{normalize(tool)}`.
/// Caller owns the returned slice.
pub fn buildMcpToolName(allocator: std.mem.Allocator, server: []const u8, tool: []const u8) ![]u8 {
    const norm_server = try normalizeNameForMCP(allocator, server);
    defer allocator.free(norm_server);
    const norm_tool = try normalizeNameForMCP(allocator, tool);
    defer allocator.free(norm_tool);
    return std.fmt.allocPrint(allocator, "mcp__{s}__{s}", .{ norm_server, norm_tool });
}

pub const McpInfo = struct {
    /// Slice into the input name.
    server: []const u8,
    /// Slice into the input name; null when the name is just `mcp__server`
    /// (no tool component). Non-null tools may themselves contain `__` because
    /// the reference rejoins all trailing tokens.
    tool: ?[]const u8,
};

/// Parses a canonical `mcp__server__tool` name back into its parts. Splits on
/// `__`, requires the first token to be exactly `mcp` and a non-empty server.
/// The remaining tokens are rejoined with `__` for the tool (preserving the
/// reference's double-underscore-in-tool behavior). Returns slices into `name`;
/// no allocation. Returns null for non-MCP names.
pub fn mcpInfoFromString(name: []const u8) ?McpInfo {
    if (!std.mem.startsWith(u8, name, "mcp__")) return null;
    // After the literal "mcp__" prefix, the next token is the server. The
    // server ends at the next "__"; everything after that is the tool (which
    // may itself contain "__").
    const rest = name["mcp__".len..];
    const sep = std.mem.indexOf(u8, rest, "__");
    if (sep) |s| {
        const server = rest[0..s];
        if (server.len == 0) return null;
        const tool = rest[s + 2 ..];
        return .{ .server = server, .tool = if (tool.len == 0) null else tool };
    }
    // No further "__": the whole remainder is the server, no tool.
    if (rest.len == 0) return null;
    return .{ .server = rest, .tool = null };
}

const testing = std.testing;

test "normalizeNameForMCP replaces disallowed chars with underscore" {
    const out = try normalizeNameForMCP(testing.allocator, "git hub.io");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("git_hub_io", out);
}

test "normalizeNameForMCP keeps allowed chars" {
    const out = try normalizeNameForMCP(testing.allocator, "create_issue-v2");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("create_issue-v2", out);
}

test "normalizeNameForMCP collapses underscores for claude.ai prefix" {
    const out = try normalizeNameForMCP(testing.allocator, "claude.ai My Server");
    defer testing.allocator.free(out);
    // "claude.ai My Server" -> char pass -> "claude_ai_My_Server" (the ".ai " run
    // becomes "_ai_"), then collapse runs and trim -> no doubled `_`, no
    // leading/trailing `_`.
    try testing.expectEqualStrings("claude_ai_My_Server", out);
}

test "normalizeNameForMCP collapses and trims edges for claude.ai prefix" {
    // Trailing/leading disallowed chars become `_`, then trimmed.
    const out = try normalizeNameForMCP(testing.allocator, "claude.ai  Foo!!  ");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("claude_ai_Foo", out);
}

test "buildMcpToolName produces canonical name" {
    const out = try buildMcpToolName(testing.allocator, "github", "create issue");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("mcp__github__create_issue", out);
}

test "getMcpPrefix produces mcp__server__" {
    const out = try getMcpPrefix(testing.allocator, "github");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("mcp__github__", out);
}

test "mcpInfoFromString splits server and tool" {
    const info = mcpInfoFromString("mcp__github__create_issue").?;
    try testing.expectEqualStrings("github", info.server);
    try testing.expectEqualStrings("create_issue", info.tool.?);
}

test "mcpInfoFromString rejoins double-underscore tool (known limitation)" {
    const info = mcpInfoFromString("mcp__my__server__tool").?;
    try testing.expectEqualStrings("my", info.server);
    try testing.expectEqualStrings("server__tool", info.tool.?);
}

test "mcpInfoFromString rejects non-mcp names" {
    try testing.expect(mcpInfoFromString("Write") == null);
    try testing.expect(mcpInfoFromString("mcp__") == null);
}

test "mcpInfoFromString server only yields null tool" {
    const info = mcpInfoFromString("mcp__github").?;
    try testing.expectEqualStrings("github", info.server);
    try testing.expect(info.tool == null);
}
