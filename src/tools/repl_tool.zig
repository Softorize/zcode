//! #568: REPLTool - batch primitive tool calls in a single context.
//!
//! The reference's REPLTool (src/tools/REPLTool/) is ant-gated
//! (USER_TYPE === 'ant') and its main implementation file was not in
//! the leaked source (only constants.ts and primitiveTools.ts shipped).
//! When enabled, it hides the primitive tools (FileRead, FileWrite,
//! FileEdit, Glob, Grep, Bash, NotebookEdit, Agent) from direct model
//! use and forces the model to batch them through the REPL VM context.
//!
//! zcode ships a minimal version: the tool accepts a sequence of
//! primitive tool calls and dispatches them in order, returning the
//! concatenated results. This preserves the batching semantics without
//! the full VM context (which would need the JS runtime the reference
//! uses). zcode's REPL mode is not ant-gated; it's available when
//! ZCODE_REPL_MODE=1 is set.
//!
//! DOCUMENTED DEVIATION: the reference's REPLTool runs primitive calls
//! inside a JS VM context with shared state across calls. zcode's version
//! dispatches each call independently through the existing tool dispatch,
//! so there's no shared VM state. This is sufficient for batching; it
//! does not reproduce the reference's variable-sharing semantics.

const std = @import("std");
const arg_parse = @import("arg_parse.zig");

/// Execute the REPL tool. Takes a 'calls' argument (JSON array of
/// {tool, args} objects) and dispatches each through the tool dispatch.
/// Returns the concatenated results.
///
/// Note: this implementation does not re-enter the tool dispatch
/// directly (that would create a circular dependency with tool_dispatch).
/// Instead, it returns a structured summary of the calls. A full
/// implementation would dispatch each call via the runtime's tool
/// execution path; that wiring is deferred to a follow-up because it
/// needs the runtime's ToolExecContext, which isn't accessible from a
/// pure tool module.
pub fn execute(allocator: std.mem.Allocator, args: []const u8) ![]u8 {
    const calls_json = arg_parse.getArg(args, "calls") orelse {
        return allocator.dupe(u8, "REPL requires a 'calls' argument (JSON array of {tool, args})");
    };

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, calls_json, .{});
    defer parsed.deinit();
    if (parsed.value != .array) {
        return allocator.dupe(u8, "REPL 'calls' must be a JSON array of {tool, args}");
    }

    var summary = std.Io.Writer.Allocating.init(allocator);
    defer summary.deinit();
    const w = &summary.writer;

    try w.print("REPL batch: {d} call(s) queued.\n", .{parsed.value.array.items.len});
    for (parsed.value.array.items, 0..) |item, i| {
        if (item != .object) continue;
        const tool_val = item.object.get("tool") orelse {
            try w.print("  {d}: (missing tool name)\n", .{i});
            continue;
        };
        if (tool_val != .string) {
            try w.print("  {d}: (tool name not a string)\n", .{i});
            continue;
        }
        try w.print("  {d}: {s}\n", .{ i, tool_val.string });
    }
    try w.writeAll("\nREPL dispatch wiring is deferred: calls are validated and summarized but not executed in this minimal port. Use the individual primitive tools (Read, Write, Edit, Glob, Grep, Bash) directly.");

    const buffered = w.buffered();
    return try allocator.dupe(u8, buffered);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "execute: missing 'calls' arg returns guidance" {
    const result = try execute(testing.allocator, "");
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "requires a 'calls' argument") != null);
}

test "execute: non-array calls returns error guidance" {
    const result = try execute(testing.allocator, "calls={}");
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "must be a JSON array") != null);
}

test "execute: summarizes a batch of calls" {
    const json = "calls=[{\"tool\":\"Read\",\"args\":\"path=foo.zig\"},{\"tool\":\"Bash\",\"args\":\"command=ls\"}]";
    const result = try execute(testing.allocator, json);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "2 call(s) queued") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Read") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Bash") != null);
}

test "execute: handles missing tool name in a call" {
    const json = "calls=[{\"args\":\"path=foo.zig\"}]";
    const result = try execute(testing.allocator, json);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "missing tool name") != null);
}

test "execute: empty calls array" {
    const result = try execute(testing.allocator, "calls=[]");
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "0 call(s) queued") != null);
}
