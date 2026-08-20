const std = @import("std");
const std_io = @import("std_io.zig");
const types = @import("types.zig");
const parse_helpers = @import("parse_helpers.zig");

pub const TodoStatus = enum {
    pending,
    in_progress,
    completed,
};

const TodoItem = struct {
    content: []u8,
    /// Optional "present continuous" form shown while the item is
    /// in_progress. Ported from the reference TodoWrite schema's
    /// `activeForm` field (see claude-code-main/src/tools/
    /// TodoWriteTool/prompt.ts for "task descriptions must have
    /// two forms"). When set, `formatOpenItem` renders this
    /// instead of `content` for in_progress items -- the spinner
    /// thus shows "Running tests" while work is under way and
    /// flips back to "Run tests" when the item is later marked
    /// completed. Null for items that were created without an
    /// active form (e.g. plain string items from a checklist
    /// parse) -- those fall back to `content` unchanged.
    active_form: ?[]u8 = null,
    status: TodoStatus,

    fn deinit(self: *TodoItem, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        if (self.active_form) |af| allocator.free(af);
    }
};

pub fn read(allocator: std.mem.Allocator, snapshot: *const types.SessionSnapshot) ![]u8 {
    if (snapshot.open_tasks.len == 0) {
        return allocator.dupe(u8, "todos: none");
    }

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    try out.writer().print("todos ({d} open):\n", .{snapshot.open_tasks.len});
    for (snapshot.open_tasks) |item| {
        try out.writer().print("{s}\n", .{item});
    }

    return out.toOwnedSlice();
}

pub fn write(allocator: std.mem.Allocator, snapshot: *types.SessionSnapshot, items_raw: []const u8) ![]u8 {
    const parsed = try parseItems(allocator, items_raw);
    defer freeItems(allocator, parsed);

    // Enforce the reference's "at most one in_progress at a time"
    // rule. Ports claude-code-main/src/tools/TodoWriteTool/prompt.ts
    // which hammers this constraint into the system prompt and then
    // the tool itself hard-rejects any list that violates it.
    //
    // Why this matters: without the check, a model can mark every
    // task in_progress at once, which defeats the whole purpose of
    // having a checklist ("focus on one thing until it's done").
    // We've seen this in practice -- a model under time pressure
    // would flip 3 items to in_progress and then "complete" them
    // in a single pass, erasing the planning value. Now the tool
    // rejects the write with a clear error telling the model
    // exactly which items conflict.
    var in_progress_count: usize = 0;
    var first_in_progress_content: ?[]const u8 = null;
    for (parsed) |item| {
        if (item.status == .in_progress) {
            if (in_progress_count == 0) first_in_progress_content = item.content;
            in_progress_count += 1;
        }
    }
    if (in_progress_count > 1) {
        const first_label = first_in_progress_content orelse "(unknown)";
        return std.fmt.allocPrint(
            allocator,
            "todo write rejected: {d} items are marked in_progress at the same time. Only ONE task may be in_progress at any moment -- finish or pause the current active task ('{s}') before starting another. Mark the others as pending and flip them to in_progress one at a time as you work.",
            .{ in_progress_count, first_label },
        );
    }

    const open_count = countOpenItems(parsed);
    const completed_count = parsed.len - open_count;

    // Archive completed tasks (keep last 5)
    var archived = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (archived.items) |item| allocator.free(item);
        archived.deinit();
    }
    // Carry forward existing archived tasks
    for (snapshot.completed_tasks) |task| {
        const duped = try allocator.dupe(u8, task);
        archived.append(duped) catch |err| {
            allocator.free(duped);
            return err;
        };
    }
    // Add newly completed tasks
    for (parsed) |item| {
        if (item.status == .completed) {
            const formatted = try std.fmt.allocPrint(allocator, "[done] {s}", .{item.content});
            archived.append(formatted) catch |err| {
                allocator.free(formatted);
                return err;
            };
        }
    }
    // Cap at 5 most recent
    while (archived.items.len > 5) {
        allocator.free(archived.items[0]);
        _ = archived.orderedRemove(0);
    }
    // Replace completed_tasks in snapshot
    freeOpenTasks(allocator, snapshot.completed_tasks);
    snapshot.completed_tasks = try archived.toOwnedSlice();

    var next_open_list = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (next_open_list.items) |item| allocator.free(item);
        next_open_list.deinit();
    }
    for (parsed) |item| {
        if (item.status == .completed) continue;
        // Render with activeForm when provided and the item is
        // in_progress -- that way `/todos` and the spinner show
        // "Running tests" instead of "Run tests" while the work
        // is under way. Falls back to `content` for pending
        // items and for in_progress items that were created
        // without an activeForm.
        const display = if (item.status == .in_progress)
            item.active_form orelse item.content
        else
            item.content;
        try next_open_list.append(try formatOpenItem(allocator, item.status, display));
    }
    const next_open = try next_open_list.toOwnedSlice();

    freeOpenTasks(allocator, snapshot.open_tasks);
    snapshot.open_tasks = next_open;

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    try out.writer().print(
        "todos updated\nopen_count={d}\ncompleted_omitted={d}\n",
        .{ snapshot.open_tasks.len, completed_count },
    );
    if (snapshot.open_tasks.len == 0) {
        try out.writer().writeAll("todos: none");
    } else {
        try out.writer().writeAll("todos:\n");
        for (snapshot.open_tasks) |item| {
            try out.writer().print("{s}\n", .{item});
        }
    }

    return out.toOwnedSlice();
}

fn parseItems(allocator: std.mem.Allocator, raw: []const u8) ![]TodoItem {
    // Strip a possible UTF-8 BOM before whitespace-trim so a notepad-
    // saved todos file (which leads with \xEF\xBB\xBF) still routes
    // through the JSON branch instead of being interpreted as a
    // checklist with a garbage first character.
    const debommed = parse_helpers.stripBom(raw);
    const trimmed = std.mem.trim(u8, debommed, " \t\r\n");
    if (trimmed.len == 0) return allocator.alloc(TodoItem, 0);

    if (trimmed[0] == '[') {
        return parseItemsJson(allocator, trimmed);
    }
    return parseItemsChecklist(allocator, trimmed);
}

fn parseItemsJson(allocator: std.mem.Allocator, raw: []const u8) ![]TodoItem {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    if (parsed.value != .array) return error.InvalidTodoItems;

    var items = std.array_list.Managed(TodoItem).init(allocator);
    errdefer freeItems(allocator, items.items);

    for (parsed.value.array.items) |value| {
        switch (value) {
            .string => |text| try appendItem(&items, allocator, text, .pending, null),
            .object => |obj| {
                const content = getString(obj, "content") orelse
                    getString(obj, "text") orelse
                    getString(obj, "title") orelse
                    continue;
                const status = parseStatus(
                    getString(obj, "status") orelse
                        getString(obj, "state") orelse
                        if (getBool(obj, "completed") orelse false) "completed" else "",
                );
                // Accept both the reference's camelCase `activeForm`
                // and the snake_case `active_form` variant that
                // models trained on Python-style schemas tend to
                // emit. Either surfaces the same field.
                const active_form = getString(obj, "activeForm") orelse getString(obj, "active_form");
                try appendItem(&items, allocator, content, status, active_form);
            },
            else => {},
        }
    }

    return items.toOwnedSlice();
}

fn parseItemsChecklist(allocator: std.mem.Allocator, raw: []const u8) ![]TodoItem {
    var items = std.array_list.Managed(TodoItem).init(allocator);
    errdefer freeItems(allocator, items.items);

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;

        if (std.mem.startsWith(u8, trimmed, "- [ ] ")) {
            try appendItem(&items, allocator, trimmed["- [ ] ".len..], .pending, null);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "- [-] ") or std.mem.startsWith(u8, trimmed, "- [~] ")) {
            const offset = if (trimmed[3] == '-') "- [-] ".len else "- [~] ".len;
            try appendItem(&items, allocator, trimmed[offset..], .in_progress, null);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "- [x] ") or std.mem.startsWith(u8, trimmed, "- [X] ")) {
            try appendItem(&items, allocator, trimmed["- [x] ".len..], .completed, null);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "- ")) {
            try appendItem(&items, allocator, trimmed[2..], .pending, null);
            continue;
        }

        try appendItem(&items, allocator, trimmed, .pending, null);
    }

    return items.toOwnedSlice();
}

fn appendItem(
    items: *std.array_list.Managed(TodoItem),
    allocator: std.mem.Allocator,
    raw_content: []const u8,
    status: TodoStatus,
    raw_active_form: ?[]const u8,
) !void {
    const content = std.mem.trim(u8, raw_content, " \t\r\n");
    if (content.len == 0) return;
    // Reserve the slot first so the final append is infallible. This
    // prevents both content_owned and active_form_owned from leaking
    // when items.append OOMs.
    try items.ensureUnusedCapacity(1);
    const content_owned = try allocator.dupe(u8, content);
    errdefer allocator.free(content_owned);
    // Dup the active form if present and non-empty. A blank or
    // whitespace-only activeForm field is treated as absent.
    var active_form_owned: ?[]u8 = null;
    if (raw_active_form) |af| {
        const trimmed_af = std.mem.trim(u8, af, " \t\r\n");
        if (trimmed_af.len > 0) {
            active_form_owned = try allocator.dupe(u8, trimmed_af);
        }
    }
    items.appendAssumeCapacity(.{
        .content = content_owned,
        .active_form = active_form_owned,
        .status = status,
    });
}

fn parseStatus(raw: []const u8) TodoStatus {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return .pending;
    if (eqlIgnoreCase(trimmed, "in_progress") or eqlIgnoreCase(trimmed, "in-progress") or eqlIgnoreCase(trimmed, "active") or eqlIgnoreCase(trimmed, "doing")) {
        return .in_progress;
    }
    if (eqlIgnoreCase(trimmed, "completed") or eqlIgnoreCase(trimmed, "done") or eqlIgnoreCase(trimmed, "finished")) {
        return .completed;
    }
    return .pending;
}

fn formatOpenItem(allocator: std.mem.Allocator, status: TodoStatus, content: []const u8) ![]u8 {
    return switch (status) {
        .pending => std.fmt.allocPrint(allocator, "- [ ] {s}", .{content}),
        .in_progress => std.fmt.allocPrint(allocator, "- [-] {s}", .{content}),
        .completed => allocator.dupe(u8, ""),
    };
}

fn countOpenItems(items: []const TodoItem) usize {
    var count: usize = 0;
    for (items) |item| {
        if (item.status != .completed) count += 1;
    }
    return count;
}

const freeOpenTasks = parse_helpers.freeStringSlice;

fn freeItems(allocator: std.mem.Allocator, items: []TodoItem) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

const eqlIgnoreCase = parse_helpers.eqlIgnoreCase;

const testing = std.testing;

test "write stores only open todo items from json payload" {
    var snapshot = types.SessionSnapshot{
        .facts = &.{},
        .decisions = &.{},
        .open_tasks = try testing.allocator.alloc([]const u8, 0),
        .file_focus = &.{},
        .recent_tool_outcomes = &.{},
        .handoff_summary = try testing.allocator.dupe(u8, ""),
        .pinned_facts = &.{},
        .completed_tasks = try testing.allocator.alloc([]const u8, 0),
    };
    defer {
        freeOpenTasks(testing.allocator, snapshot.open_tasks);
        freeOpenTasks(testing.allocator, snapshot.completed_tasks);
        testing.allocator.free(snapshot.handoff_summary);
    }

    const output = try write(
        testing.allocator,
        &snapshot,
        "[{\"content\":\"Inspect runtime loop\",\"status\":\"completed\"},{\"content\":\"Add todo tool\",\"status\":\"in_progress\"},{\"content\":\"Add tests\",\"status\":\"pending\"}]",
    );
    defer testing.allocator.free(output);

    try testing.expectEqual(@as(usize, 2), snapshot.open_tasks.len);
    try testing.expectEqualStrings("- [-] Add todo tool", snapshot.open_tasks[0]);
    try testing.expectEqualStrings("- [ ] Add tests", snapshot.open_tasks[1]);
    try testing.expect(std.mem.indexOf(u8, output, "completed_omitted=1") != null);
}

test "write accepts checklist markdown" {
    var snapshot = types.SessionSnapshot{
        .facts = &.{},
        .decisions = &.{},
        .open_tasks = try testing.allocator.alloc([]const u8, 0),
        .file_focus = &.{},
        .recent_tool_outcomes = &.{},
        .handoff_summary = try testing.allocator.dupe(u8, ""),
        .pinned_facts = &.{},
        .completed_tasks = try testing.allocator.alloc([]const u8, 0),
    };
    defer {
        freeOpenTasks(testing.allocator, snapshot.open_tasks);
        freeOpenTasks(testing.allocator, snapshot.completed_tasks);
        testing.allocator.free(snapshot.handoff_summary);
    }

    const output = try write(
        testing.allocator,
        &snapshot,
        "- [ ] Review prompt stack\n- [-] Implement builtin agents\n- [x] Ship docs\n",
    );
    defer testing.allocator.free(output);

    try testing.expectEqual(@as(usize, 2), snapshot.open_tasks.len);
    try testing.expect(std.mem.indexOf(u8, output, "open_count=2") != null);
}

test "read renders open todos" {
    const open_tasks = try testing.allocator.alloc([]const u8, 2);
    open_tasks[0] = try testing.allocator.dupe(u8, "- [ ] Inspect runtime");
    open_tasks[1] = try testing.allocator.dupe(u8, "- [-] Run tests");
    var snapshot = types.SessionSnapshot{
        .facts = &.{},
        .decisions = &.{},
        .open_tasks = open_tasks,
        .file_focus = &.{},
        .recent_tool_outcomes = &.{},
        .handoff_summary = try testing.allocator.dupe(u8, ""),
        .pinned_facts = &.{},
        .completed_tasks = &.{},
    };
    defer {
        freeOpenTasks(testing.allocator, snapshot.open_tasks);
        testing.allocator.free(snapshot.handoff_summary);
    }

    const output = try read(testing.allocator, &snapshot);
    defer testing.allocator.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "todos (2 open)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Inspect runtime") != null);
}

test "write renders activeForm for in_progress items" {
    var snapshot = types.SessionSnapshot{
        .facts = &.{},
        .decisions = &.{},
        .open_tasks = try testing.allocator.alloc([]const u8, 0),
        .file_focus = &.{},
        .recent_tool_outcomes = &.{},
        .handoff_summary = try testing.allocator.dupe(u8, ""),
        .pinned_facts = &.{},
        .completed_tasks = try testing.allocator.alloc([]const u8, 0),
    };
    defer {
        freeOpenTasks(testing.allocator, snapshot.open_tasks);
        freeOpenTasks(testing.allocator, snapshot.completed_tasks);
        testing.allocator.free(snapshot.handoff_summary);
    }

    const payload =
        "[{\"content\":\"Run tests\",\"activeForm\":\"Running tests\",\"status\":\"in_progress\"}," ++
        "{\"content\":\"Ship docs\",\"activeForm\":\"Shipping docs\",\"status\":\"pending\"}]";
    const output = try write(testing.allocator, &snapshot, payload);
    defer testing.allocator.free(output);

    try testing.expectEqual(@as(usize, 2), snapshot.open_tasks.len);
    // In_progress line should show the active form.
    try testing.expectEqualStrings("- [-] Running tests", snapshot.open_tasks[0]);
    // Pending line should show the imperative form.
    try testing.expectEqualStrings("- [ ] Ship docs", snapshot.open_tasks[1]);
}

test "write accepts snake_case active_form alias" {
    var snapshot = types.SessionSnapshot{
        .facts = &.{},
        .decisions = &.{},
        .open_tasks = try testing.allocator.alloc([]const u8, 0),
        .file_focus = &.{},
        .recent_tool_outcomes = &.{},
        .handoff_summary = try testing.allocator.dupe(u8, ""),
        .pinned_facts = &.{},
        .completed_tasks = try testing.allocator.alloc([]const u8, 0),
    };
    defer {
        freeOpenTasks(testing.allocator, snapshot.open_tasks);
        freeOpenTasks(testing.allocator, snapshot.completed_tasks);
        testing.allocator.free(snapshot.handoff_summary);
    }

    const output = try write(
        testing.allocator,
        &snapshot,
        "[{\"content\":\"Run tests\",\"active_form\":\"Running tests\",\"status\":\"in_progress\"}]",
    );
    defer testing.allocator.free(output);

    try testing.expectEqualStrings("- [-] Running tests", snapshot.open_tasks[0]);
}

test "write falls back to content when activeForm is missing or blank" {
    var snapshot = types.SessionSnapshot{
        .facts = &.{},
        .decisions = &.{},
        .open_tasks = try testing.allocator.alloc([]const u8, 0),
        .file_focus = &.{},
        .recent_tool_outcomes = &.{},
        .handoff_summary = try testing.allocator.dupe(u8, ""),
        .pinned_facts = &.{},
        .completed_tasks = try testing.allocator.alloc([]const u8, 0),
    };
    defer {
        freeOpenTasks(testing.allocator, snapshot.open_tasks);
        freeOpenTasks(testing.allocator, snapshot.completed_tasks);
        testing.allocator.free(snapshot.handoff_summary);
    }

    const payload =
        "[{\"content\":\"Run tests\",\"status\":\"in_progress\"}," ++
        "{\"content\":\"Ship docs\",\"activeForm\":\"   \",\"status\":\"pending\"}]";
    const output = try write(testing.allocator, &snapshot, payload);
    defer testing.allocator.free(output);

    try testing.expectEqual(@as(usize, 2), snapshot.open_tasks.len);
    // First item falls back to content because activeForm was absent.
    // Second item falls back because activeForm was whitespace-only
    // -- but it's pending, so it would render as content anyway.
    // The point is the whitespace-only string doesn't leak through.
    try testing.expectEqualStrings("- [-] Run tests", snapshot.open_tasks[0]);
    try testing.expectEqualStrings("- [ ] Ship docs", snapshot.open_tasks[1]);
}

test "write rejects multiple in_progress items" {
    // Reference's TodoWrite tool enforces "only one task in_progress
    // at a time" as a hard rule. Flipping several items to active
    // must fail loudly so the model is forced to pick one.
    var snapshot = types.SessionSnapshot{
        .facts = &.{},
        .decisions = &.{},
        .open_tasks = try testing.allocator.alloc([]const u8, 0),
        .file_focus = &.{},
        .recent_tool_outcomes = &.{},
        .handoff_summary = try testing.allocator.dupe(u8, ""),
        .pinned_facts = &.{},
        .completed_tasks = try testing.allocator.alloc([]const u8, 0),
    };
    defer {
        freeOpenTasks(testing.allocator, snapshot.open_tasks);
        freeOpenTasks(testing.allocator, snapshot.completed_tasks);
        testing.allocator.free(snapshot.handoff_summary);
    }

    const payload =
        "[{\"content\":\"Step one\",\"status\":\"in_progress\"}," ++
        "{\"content\":\"Step two\",\"status\":\"in_progress\"}," ++
        "{\"content\":\"Step three\",\"status\":\"pending\"}]";
    const output = try write(testing.allocator, &snapshot, payload);
    defer testing.allocator.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "rejected") != null);
    try testing.expect(std.mem.indexOf(u8, output, "2 items") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Step one") != null);

    // Snapshot must be untouched: the rejected write doesn't
    // overwrite the existing open_tasks.
    try testing.expectEqual(@as(usize, 0), snapshot.open_tasks.len);
}

test "write accepts exactly one in_progress item" {
    // Sanity: the happy path still works. One in_progress + any
    // number of pending is fine.
    var snapshot = types.SessionSnapshot{
        .facts = &.{},
        .decisions = &.{},
        .open_tasks = try testing.allocator.alloc([]const u8, 0),
        .file_focus = &.{},
        .recent_tool_outcomes = &.{},
        .handoff_summary = try testing.allocator.dupe(u8, ""),
        .pinned_facts = &.{},
        .completed_tasks = try testing.allocator.alloc([]const u8, 0),
    };
    defer {
        freeOpenTasks(testing.allocator, snapshot.open_tasks);
        freeOpenTasks(testing.allocator, snapshot.completed_tasks);
        testing.allocator.free(snapshot.handoff_summary);
    }

    const payload =
        "[{\"content\":\"Active task\",\"status\":\"in_progress\"}," ++
        "{\"content\":\"Queued task A\",\"status\":\"pending\"}," ++
        "{\"content\":\"Queued task B\",\"status\":\"pending\"}]";
    const output = try write(testing.allocator, &snapshot, payload);
    defer testing.allocator.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "rejected") == null);
    try testing.expectEqual(@as(usize, 3), snapshot.open_tasks.len);
}

test "write accepts zero in_progress items" {
    // An all-pending list is also valid -- the model hasn't started
    // work yet. Only >1 in_progress is rejected.
    var snapshot = types.SessionSnapshot{
        .facts = &.{},
        .decisions = &.{},
        .open_tasks = try testing.allocator.alloc([]const u8, 0),
        .file_focus = &.{},
        .recent_tool_outcomes = &.{},
        .handoff_summary = try testing.allocator.dupe(u8, ""),
        .pinned_facts = &.{},
        .completed_tasks = try testing.allocator.alloc([]const u8, 0),
    };
    defer {
        freeOpenTasks(testing.allocator, snapshot.open_tasks);
        freeOpenTasks(testing.allocator, snapshot.completed_tasks);
        testing.allocator.free(snapshot.handoff_summary);
    }

    const payload = "[{\"content\":\"A\",\"status\":\"pending\"},{\"content\":\"B\",\"status\":\"pending\"}]";
    const output = try write(testing.allocator, &snapshot, payload);
    defer testing.allocator.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "rejected") == null);
    try testing.expectEqual(@as(usize, 2), snapshot.open_tasks.len);
}

test "write ignores activeForm on pending items" {
    // The activeForm field is only meaningful while in_progress.
    // A pending item should render with its imperative content even
    // when the model optimistically supplied an activeForm.
    var snapshot = types.SessionSnapshot{
        .facts = &.{},
        .decisions = &.{},
        .open_tasks = try testing.allocator.alloc([]const u8, 0),
        .file_focus = &.{},
        .recent_tool_outcomes = &.{},
        .handoff_summary = try testing.allocator.dupe(u8, ""),
        .pinned_facts = &.{},
        .completed_tasks = try testing.allocator.alloc([]const u8, 0),
    };
    defer {
        freeOpenTasks(testing.allocator, snapshot.open_tasks);
        freeOpenTasks(testing.allocator, snapshot.completed_tasks);
        testing.allocator.free(snapshot.handoff_summary);
    }

    const output = try write(
        testing.allocator,
        &snapshot,
        "[{\"content\":\"Run tests\",\"activeForm\":\"Running tests\",\"status\":\"pending\"}]",
    );
    defer testing.allocator.free(output);

    try testing.expectEqualStrings("- [ ] Run tests", snapshot.open_tasks[0]);
}
