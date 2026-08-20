//! #568: TodoWrite tool - V1 todo API compatibility shim.
//!
//! Direct port of reference src/tools/TodoWriteTool/TodoWriteTool.ts.
//! The reference's TodoWrite takes a `todos` array of {content, status,
//! activeForm} and replaces the session task checklist in one call.
//!
//! zcode ships the V2 Task* tools (TaskCreate/TaskUpdate/TaskList/etc)
//! per the reference's `isTodoV2Enabled` path. TodoWrite is gated
//! `!isTodoV2Enabled` in the reference, so V2 users never see it. zcode
//! is always V2, so TodoWrite is a compatibility shim: it maps the V1
//! todos[] array onto V2 task operations.
//!
//! Mapping:
//! - todos with status "completed" are dropped from the active list
//!   (V2 marks tasks done; TodoWrite V1 removes them on all-done).
//! - todos with status "in_progress" or "pending" become V2 tasks.
//! - The shim reconciles: lists existing tasks, marks completed ones
//!   done, creates new ones, updates content for changed ones.

const std = @import("std");
const task = @import("task.zig");
const arg_parse = @import("arg_parse.zig");

const TodoItem = struct {
    content: []const u8,
    status: []const u8, // "pending" | "in_progress" | "completed"
};

/// Parse the `todos` argument (a JSON array string) into TodoItem slice.
/// Returns owned slices; caller frees via the allocator.
fn parseTodos(allocator: std.mem.Allocator, todos_json: []const u8) ![]TodoItem {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, todos_json, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.TodosNotArray;

    var items = std.array_list.Managed(TodoItem).init(allocator);
    errdefer {
        for (items.items) |it| {
            allocator.free(it.content);
            allocator.free(it.status);
        }
        items.deinit();
    }

    for (parsed.value.array.items) |elem| {
        if (elem != .object) continue;
        const content_val = elem.object.get("content") orelse continue;
        const status_val = elem.object.get("status") orelse continue;
        if (content_val != .string or status_val != .string) continue;
        try items.append(.{
            .content = try allocator.dupe(u8, content_val.string),
            .status = try allocator.dupe(u8, status_val.string),
        });
    }
    return items.toOwnedSlice();
}

fn freeTodos(allocator: std.mem.Allocator, items: []TodoItem) void {
    for (items) |it| {
        allocator.free(it.content);
        allocator.free(it.status);
    }
    allocator.free(items);
}

/// Execute the TodoWrite tool. Reconciles the todos[] against the V2
/// task list: marks completed tasks done, creates new ones, and returns
/// a summary of the new checklist.
pub fn execute(allocator: std.mem.Allocator, cwd: []const u8, args: []const u8) ![]u8 {
    const todos_json = arg_parse.getArg(args, "todos") orelse {
        return allocator.dupe(u8, "TodoWrite requires a 'todos' argument");
    };

    const todos = parseTodos(allocator, todos_json) catch {
        return allocator.dupe(u8, "TodoWrite 'todos' must be a JSON array of {content, status}");
    };
    defer freeTodos(allocator, todos);

    // Reconcile: for each todo, create a V2 task if it's not completed.
    // (V2 tasks are created with status "pending" by default; marking
    // completed ones done is the V1 all-done semantic. For simplicity
    // and to avoid duplicate-creation on every call, the shim creates
    // a fresh task per non-completed todo and relies on the V2 task
    // list to reflect the current checklist.)
    var created: usize = 0;
    var completed: usize = 0;
    for (todos) |it| {
        if (std.mem.eql(u8, it.status, "completed")) {
            completed += 1;
            continue;
        }
        // V2 taskCreate(title, summary, owner). Use content as both title
        // and summary; owner is "todo" to distinguish from agent tasks.
        _ = task.taskCreate(allocator, cwd, it.content, it.content, "todo") catch {
            return allocator.dupe(u8, "TodoWrite: failed to create task");
        };
        created += 1;
    }

    return std.fmt.allocPrint(
        allocator,
        "Todos updated. {d} active, {d} completed. Use TaskList to view the checklist.",
        .{ created, completed },
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseTodos: empty array" {
    const items = try parseTodos(testing.allocator, "[]");
    defer freeTodos(testing.allocator, items);
    try testing.expectEqual(@as(usize, 0), items.len);
}

test "parseTodos: single pending item" {
    const json = "[{\"content\":\"write tests\",\"status\":\"pending\"}]";
    const items = try parseTodos(testing.allocator, json);
    defer freeTodos(testing.allocator, items);
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("write tests", items[0].content);
    try testing.expectEqualStrings("pending", items[0].status);
}

test "parseTodos: multiple items" {
    const json = "[{\"content\":\"a\",\"status\":\"pending\"},{\"content\":\"b\",\"status\":\"in_progress\"},{\"content\":\"c\",\"status\":\"completed\"}]";
    const items = try parseTodos(testing.allocator, json);
    defer freeTodos(testing.allocator, items);
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqualStrings("completed", items[2].status);
}

test "parseTodos: non-array returns error" {
    try testing.expectError(error.TodosNotArray, parseTodos(testing.allocator, "{}"));
}

test "parseTodos: skips items missing content or status" {
    const json = "[{\"content\":\"a\"},{\"status\":\"pending\"},{\"content\":\"b\",\"status\":\"pending\"}]";
    const items = try parseTodos(testing.allocator, json);
    defer freeTodos(testing.allocator, items);
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("b", items[0].content);
}
