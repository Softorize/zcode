const std = @import("std");
const rt = @import("zcode_runtime");
const rng = @import("../core/rng.zig");
const clock = @import("../core/clock.zig");
const std_io = @import("../core/std_io.zig");
const backoff = @import("../core/backoff.zig");
const task_list_id = @import("../core/task_list_id.zig");
const hooks = @import("../core/hooks.zig");
const helpers = @import("helpers.zig");

const TASKS_SUBPATH = helpers.TASKS_SUBPATH;
const TASK_RUNS_SUBPATH = helpers.TASK_RUNS_SUBPATH;
const TASK_NOTIFICATIONS_SUBPATH = helpers.TASK_NOTIFICATIONS_SUBPATH;

const TaskRecord = struct {
    id: []u8,
    title: []u8,
    summary: []u8,
    status: []u8,
    output: []u8,
    owner: []u8,
    command: []u8,
    priority: []u8,
    deps: []u8,
    // Dependency graph edges (swarm-tasks-01). `blocks` are the ids this task
    // blocks; `blocked_by` are the ids that must complete before this task can
    // be claimed. Each is an owned slice of owned id slices.
    blocks: [][]u8,
    blocked_by: [][]u8,
    // Present-continuous spinner label (swarm-tasks-03), e.g. "Running tests".
    active_form: []u8,
    // Arbitrary task metadata (swarm-tasks-04), stored as an opaque raw JSON
    // object string so we do not need to maintain a recursive value clone.
    // Empty string means "no metadata" and serializes as {}.
    metadata_json: []u8,
    run_pid: i64,
    output_path: []u8,
    exit_path: []u8,
    started_ts: i64,
    finished_ts: i64,
    progress: u8,
    created_ts: i64,
    updated_ts: i64,

    fn init(allocator: std.mem.Allocator) !TaskRecord {
        const now = clock.nowSeconds();
        return .{
            .id = try allocator.dupe(u8, ""),
            .title = try allocator.dupe(u8, ""),
            .summary = try allocator.dupe(u8, ""),
            .status = try allocator.dupe(u8, "open"),
            .output = try allocator.dupe(u8, ""),
            .owner = try allocator.dupe(u8, ""),
            .command = try allocator.dupe(u8, ""),
            .priority = try allocator.dupe(u8, "normal"),
            .deps = try allocator.dupe(u8, ""),
            .blocks = try allocator.alloc([]u8, 0),
            .blocked_by = try allocator.alloc([]u8, 0),
            .active_form = try allocator.dupe(u8, ""),
            .metadata_json = try allocator.dupe(u8, ""),
            .run_pid = 0,
            .output_path = try allocator.dupe(u8, ""),
            .exit_path = try allocator.dupe(u8, ""),
            .started_ts = 0,
            .finished_ts = 0,
            .progress = 0,
            .created_ts = now,
            .updated_ts = now,
        };
    }

    fn deinit(self: *TaskRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.summary);
        allocator.free(self.status);
        allocator.free(self.output);
        allocator.free(self.owner);
        allocator.free(self.command);
        allocator.free(self.priority);
        allocator.free(self.deps);
        freeStringList(allocator, self.blocks);
        freeStringList(allocator, self.blocked_by);
        allocator.free(self.active_form);
        allocator.free(self.metadata_json);
        allocator.free(self.output_path);
        allocator.free(self.exit_path);
    }
};

fn freeStringList(allocator: std.mem.Allocator, list: [][]u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

fn dupeStringList(allocator: std.mem.Allocator, list: []const []const u8) ![][]u8 {
    const out = try allocator.alloc([]u8, list.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |item| allocator.free(item);
        allocator.free(out);
    }
    for (list, 0..) |item, idx| {
        out[idx] = try allocator.dupe(u8, item);
        initialized += 1;
    }
    return out;
}

pub const TaskSnapshot = struct {
    id: []u8,
    title: []u8,
    summary: []u8,
    status: []u8,
    output: []u8,
    owner: []u8,
    command: []u8,
    priority: []u8,
    deps: []u8,
    blocks: [][]u8,
    blocked_by: [][]u8,
    active_form: []u8,
    metadata_json: []u8,
    run_pid: i64,
    output_path: []u8,
    exit_path: []u8,
    started_ts: i64,
    finished_ts: i64,
    progress: u8,
    created_ts: i64,
    updated_ts: i64,

    fn fromRecord(allocator: std.mem.Allocator, rec: *const TaskRecord) !TaskSnapshot {
        return .{
            .id = try allocator.dupe(u8, rec.id),
            .title = try allocator.dupe(u8, rec.title),
            .summary = try allocator.dupe(u8, rec.summary),
            .status = try allocator.dupe(u8, rec.status),
            .output = try allocator.dupe(u8, rec.output),
            .owner = try allocator.dupe(u8, rec.owner),
            .command = try allocator.dupe(u8, rec.command),
            .priority = try allocator.dupe(u8, rec.priority),
            .deps = try allocator.dupe(u8, rec.deps),
            .blocks = try dupeStringList(allocator, rec.blocks),
            .blocked_by = try dupeStringList(allocator, rec.blocked_by),
            .active_form = try allocator.dupe(u8, rec.active_form),
            .metadata_json = try allocator.dupe(u8, rec.metadata_json),
            .run_pid = rec.run_pid,
            .output_path = try allocator.dupe(u8, rec.output_path),
            .exit_path = try allocator.dupe(u8, rec.exit_path),
            .started_ts = rec.started_ts,
            .finished_ts = rec.finished_ts,
            .progress = rec.progress,
            .created_ts = rec.created_ts,
            .updated_ts = rec.updated_ts,
        };
    }

    pub fn deinit(self: *TaskSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.summary);
        allocator.free(self.status);
        allocator.free(self.output);
        allocator.free(self.owner);
        allocator.free(self.command);
        allocator.free(self.priority);
        allocator.free(self.deps);
        freeStringList(allocator, self.blocks);
        freeStringList(allocator, self.blocked_by);
        allocator.free(self.active_form);
        allocator.free(self.metadata_json);
        allocator.free(self.output_path);
        allocator.free(self.exit_path);
    }
};

pub fn freeTaskSnapshots(allocator: std.mem.Allocator, items: []TaskSnapshot) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

pub fn taskCreate(allocator: std.mem.Allocator, cwd: []const u8, title: []const u8, summary: []const u8, owner: []const u8) ![]u8 {
    return taskCreateWithOptions(allocator, cwd, title, summary, owner, "normal", "", null, "", "");
}

// Validate that `metadata_json` is a JSON object (or empty). The reference task
// schema (tasks.ts:86) types `metadata` as `Record<string, unknown>`, so a
// non-object payload (array, scalar) is rejected. Returns the canonical raw
// object string to store (empty when no metadata) or `error.InvalidTaskMetadata`.
fn validateMetadata(allocator: std.mem.Allocator, metadata_json: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, metadata_json, " \t\r\n");
    if (trimmed.len == 0) return "";
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return error.InvalidTaskMetadata;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidTaskMetadata;
    return trimmed;
}

pub fn taskCreateWithOptions(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    title: []const u8,
    summary: []const u8,
    owner: []const u8,
    priority: []const u8,
    deps: []const u8,
    command: ?[]const u8,
    active_form: []const u8,
    metadata_json: []const u8,
) ![]u8 {
    // Validate metadata before any filesystem side effects so a bad payload
    // fails cleanly without leaving a partial `.task` file behind.
    const metadata_to_store = try validateMetadata(allocator, metadata_json);

    const tasks_rel = try tasksRelAlloc(allocator);
    defer allocator.free(tasks_rel);
    const tasks_dir = try helpers.ensureWorkspaceDirPath(allocator, cwd, tasks_rel);
    defer allocator.free(tasks_dir);

    var rec = try TaskRecord.init(allocator);
    defer rec.deinit(allocator);

    const now = clock.nowSeconds();
    rec.created_ts = now;
    rec.updated_ts = now;
    // Number tasks from 1 within the list directory, mirroring the reference's
    // per-list `getTaskPath(listId, id)` numbering (tasks.ts). The next number
    // is `max(existing .task numbers, .highwatermark) + 1`, so a reset that
    // bumps the high-water-mark prevents id reuse (swarm-tasks-05). Legacy
    // `task-<ts>-<hex>` ids that may linger in a list dir are ignored by the
    // numeric scan and still load via `taskPathAlloc` (back-compat).
    const next_num = try nextTaskNumber(allocator, tasks_dir);
    const id = try std.fmt.allocPrint(allocator, "{d}", .{next_num});
    allocator.free(rec.id);
    rec.id = id;
    try helpers.replaceOwned(allocator, &rec.title, title);
    try helpers.replaceOwned(allocator, &rec.summary, summary);
    try helpers.replaceOwned(allocator, &rec.owner, owner);
    try helpers.replaceOwned(allocator, &rec.priority, if (priority.len > 0) priority else "normal");
    try helpers.replaceOwned(allocator, &rec.deps, deps);
    // activeForm is the present-continuous spinner label; falls back to the
    // subject/title when omitted (TaskCreateTool.ts:22-31, tasks.ts:81).
    const active_trimmed = std.mem.trim(u8, active_form, " \t\r\n");
    try helpers.replaceOwned(allocator, &rec.active_form, if (active_trimmed.len > 0) active_trimmed else title);
    try helpers.replaceOwned(allocator, &rec.metadata_json, metadata_to_store);
    if (command) |cmd| {
        try helpers.replaceOwned(allocator, &rec.command, cmd);
        try helpers.replaceOwned(allocator, &rec.status, "queued");
    }

    const task_path = try std.fmt.allocPrint(allocator, "{s}/{s}.task", .{ tasks_dir, rec.id });
    defer allocator.free(task_path);
    try writeTaskRecord(allocator, task_path, &rec);

    // TaskCreated blocking-hook gate (swarm-tasks-15). The hook runs *after* the
    // task is written so it sees the fully-formed task (mirroring the reference's
    // create-then-maybe-delete ordering, TaskCreateTool.ts:92-113). A blocking
    // outcome (exit 2 / decision:"block") deletes the just-created task --
    // including the cross-task edge cascade -- and returns the hook's message.
    var hook_res = try hooks.runTaskCreatedHook(allocator, cwd, rec.id, rec.title);
    defer hook_res.deinit(allocator);
    if (hook_res.blocked) {
        const del = taskDelete(allocator, cwd, rec.id) catch null;
        if (del) |d| allocator.free(d);
        const msg = if (hook_res.message.len > 0) hook_res.message else rec.title;
        return std.fmt.allocPrint(allocator, "task creation blocked by TaskCreated hook\nreason={s}", .{msg});
    }

    try appendTaskNotification(allocator, cwd, rec.id, "created", rec.status, rec.title);

    return std.fmt.allocPrint(
        allocator,
        "task created\nid={s}\nstatus={s}\npriority={s}\ntitle={s}",
        .{ rec.id, rec.status, rec.priority, rec.title },
    );
}

pub fn taskGet(allocator: std.mem.Allocator, cwd: []const u8, id: []const u8) ![]u8 {
    const task_path = try taskPathAlloc(allocator, cwd, id);
    defer allocator.free(task_path);
    var rec = readTaskRecord(allocator, task_path) catch return allocator.dupe(u8, "task not found");
    defer rec.deinit(allocator);
    _ = try refreshTaskRuntimeState(allocator, cwd, task_path, &rec);
    return formatTaskRecord(allocator, &rec);
}

pub fn taskList(allocator: std.mem.Allocator, cwd: []const u8, status_filter: ?[]const u8) ![]u8 {
    const tasks_rel = try tasksRelAlloc(allocator);
    defer allocator.free(tasks_rel);
    const tasks_dir = try helpers.workspacePathAlloc(allocator, cwd, tasks_rel);
    defer allocator.free(tasks_dir);

    var dir = std.Io.Dir.cwd().openDir(rt.io, tasks_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, "no tasks"),
        else => return err,
    };
    defer dir.close(rt.io);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();
    try w.writeAll("tasks:\n");

    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next(rt.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".task")) continue;

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tasks_dir, entry.name });
        defer allocator.free(full_path);

        var rec = readTaskRecord(allocator, full_path) catch continue;
        defer rec.deinit(allocator);
        _ = refreshTaskRuntimeState(allocator, cwd, full_path, &rec) catch |err| {
            std.log.debug("task: refreshRuntimeState failed for {s}: {}", .{ entry.name, err });
        };
        if (status_filter) |filter| {
            if (!std.mem.eql(u8, rec.status, filter)) continue;
        }
        if (rec.run_pid > 0) {
            try w.print("- {s} [{s}] {s} (pid={d}, progress={d}%)\n", .{ rec.id, rec.status, rec.title, rec.run_pid, rec.progress });
        } else {
            try w.print("- {s} [{s}] {s} (progress={d}%)\n", .{ rec.id, rec.status, rec.title, rec.progress });
        }
        count += 1;
    }

    if (count == 0) try w.writeAll("no matching tasks\n");
    return out.toOwnedSlice();
}

pub fn listTaskSnapshots(allocator: std.mem.Allocator, cwd: []const u8, status_filter: ?[]const u8) ![]TaskSnapshot {
    const tasks_rel = try tasksRelAlloc(allocator);
    defer allocator.free(tasks_rel);
    const tasks_dir = try helpers.workspacePathAlloc(allocator, cwd, tasks_rel);
    defer allocator.free(tasks_dir);

    var dir = std.Io.Dir.cwd().openDir(rt.io, tasks_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(TaskSnapshot, 0),
        else => return err,
    };
    defer dir.close(rt.io);

    var out = std.array_list.Managed(TaskSnapshot).init(allocator);
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit();
    }

    var it = dir.iterate();
    while (try it.next(rt.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".task")) continue;

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tasks_dir, entry.name });
        defer allocator.free(full_path);

        var rec = readTaskRecord(allocator, full_path) catch continue;
        defer rec.deinit(allocator);
        _ = refreshTaskRuntimeState(allocator, cwd, full_path, &rec) catch |err| {
            std.log.debug("task: refreshRuntimeState failed for {s}: {}", .{ entry.name, err });
        };
        if (status_filter) |filter| {
            if (!std.mem.eql(u8, rec.status, filter)) continue;
        }

        try out.append(try TaskSnapshot.fromRecord(allocator, &rec));
    }

    sortTaskSnapshots(out.items);
    return out.toOwnedSlice();
}

pub fn taskUpdate(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    id: []const u8,
    title: ?[]const u8,
    summary: ?[]const u8,
    status: ?[]const u8,
    output: ?[]const u8,
    owner: ?[]const u8,
) ![]u8 {
    const task_path = try taskPathAlloc(allocator, cwd, id);
    defer allocator.free(task_path);
    var rec = readTaskRecord(allocator, task_path) catch return allocator.dupe(u8, "task not found");
    defer rec.deinit(allocator);

    if (title) |v| try helpers.replaceOwned(allocator, &rec.title, v);
    if (summary) |v| try helpers.replaceOwned(allocator, &rec.summary, v);
    if (status) |v| {
        try helpers.replaceOwned(allocator, &rec.status, v);
        if (std.mem.eql(u8, v, "done")) rec.progress = 100;
    }
    if (output) |v| try helpers.replaceOwned(allocator, &rec.output, v);
    if (owner) |v| try helpers.replaceOwned(allocator, &rec.owner, v);
    rec.updated_ts = clock.nowSeconds();

    try writeTaskRecord(allocator, task_path, &rec);
    try appendTaskNotification(allocator, cwd, rec.id, "updated", rec.status, rec.title);
    return formatTaskRecord(allocator, &rec);
}

pub fn taskStop(allocator: std.mem.Allocator, cwd: []const u8, id: []const u8) ![]u8 {
    const task_path = try taskPathAlloc(allocator, cwd, id);
    defer allocator.free(task_path);
    var rec = readTaskRecord(allocator, task_path) catch return allocator.dupe(u8, "task not found");
    defer rec.deinit(allocator);

    if (rec.run_pid > 0) {
        _ = try killProcessByPid(allocator, cwd, rec.run_pid);
        rec.run_pid = 0;
    }
    rec.finished_ts = clock.nowSeconds();
    rec.progress = if (rec.progress > 95) rec.progress else 95;
    try helpers.replaceOwned(allocator, &rec.status, "stopped");
    rec.updated_ts = clock.nowSeconds();
    try writeTaskRecord(allocator, task_path, &rec);
    try appendTaskNotification(allocator, cwd, rec.id, "stopped", rec.status, rec.title);
    return formatTaskRecord(allocator, &rec);
}

pub fn taskOutput(allocator: std.mem.Allocator, cwd: []const u8, id: []const u8, new_output: ?[]const u8) ![]u8 {
    if (new_output) |out| return taskUpdate(allocator, cwd, id, null, null, "done", out, null);
    const task_path = try taskPathAlloc(allocator, cwd, id);
    defer allocator.free(task_path);
    var rec = readTaskRecord(allocator, task_path) catch return allocator.dupe(u8, "task not found");
    defer rec.deinit(allocator);
    _ = try refreshTaskRuntimeState(allocator, cwd, task_path, &rec);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const formatted = try formatTaskRecord(allocator, &rec);
    defer allocator.free(formatted);
    try out.appendSlice(formatted);
    if (rec.output_path.len > 0) {
        const tail = helpers.readFileTailAlloc(allocator, cwd, rec.output_path, 16 * 1024) catch null;
        if (tail) |chunk| {
            defer allocator.free(chunk);
            try out.writer().writeAll("\n\noutput_tail:\n");
            try out.appendSlice(chunk);
        }
    }
    return out.toOwnedSlice();
}

pub fn taskRun(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    id: ?[]const u8,
    title: []const u8,
    command: []const u8,
    summary: []const u8,
    owner: []const u8,
    priority: []const u8,
    deps: []const u8,
) ![]u8 {
    var task_id_owned: ?[]u8 = null;
    defer {
        if (task_id_owned) |buf| allocator.free(buf);
    }

    if (id) |existing_id| {
        task_id_owned = try allocator.dupe(u8, existing_id);
    } else {
        const create_result = try taskCreateWithOptions(allocator, cwd, title, summary, owner, priority, deps, command, "", "");
        defer allocator.free(create_result);
        const parsed_id = extractFieldValue(create_result, "id") orelse return allocator.dupe(u8, "failed to create task");
        task_id_owned = try allocator.dupe(u8, parsed_id);
    }

    const task_id = task_id_owned orelse return error.Unexpected;
    const task_path = try taskPathAlloc(allocator, cwd, task_id);
    defer allocator.free(task_path);

    var rec = readTaskRecord(allocator, task_path) catch return allocator.dupe(u8, "task not found");
    defer rec.deinit(allocator);

    if (rec.run_pid > 0 and isProcessRunning(allocator, cwd, rec.run_pid)) {
        return std.fmt.allocPrint(allocator, "task already running\nid={s}\npid={d}", .{ rec.id, rec.run_pid });
    }

    if (command.len > 0) try helpers.replaceOwned(allocator, &rec.command, command);
    if (summary.len > 0) try helpers.replaceOwned(allocator, &rec.summary, summary);
    if (owner.len > 0) try helpers.replaceOwned(allocator, &rec.owner, owner);
    if (priority.len > 0) try helpers.replaceOwned(allocator, &rec.priority, priority);
    if (deps.len > 0) try helpers.replaceOwned(allocator, &rec.deps, deps);

    if (rec.command.len == 0) return allocator.dupe(u8, "task command is empty");

    const run_dir = try helpers.ensureWorkspaceDirPath(allocator, cwd, TASK_RUNS_SUBPATH);
    defer allocator.free(run_dir);

    const output_file = try std.fmt.allocPrint(allocator, "{s}/{s}.log", .{ run_dir, rec.id });
    defer allocator.free(output_file);
    const exit_file = try std.fmt.allocPrint(allocator, "{s}/{s}.exit", .{ run_dir, rec.id });
    defer allocator.free(exit_file);
    const script_file = try std.fmt.allocPrint(allocator, "{s}/{s}.sh", .{ run_dir, rec.id });
    defer allocator.free(script_file);

    try writeTaskScript(allocator, cwd, script_file, exit_file, rec.command);
    const pid = try spawnDetachedScript(allocator, cwd, script_file, output_file);

    try helpers.replaceOwned(allocator, &rec.output_path, output_file);
    try helpers.replaceOwned(allocator, &rec.exit_path, exit_file);
    rec.run_pid = pid;
    rec.started_ts = clock.nowSeconds();
    rec.finished_ts = 0;
    rec.progress = if (rec.progress < 5) 5 else rec.progress;
    try helpers.replaceOwned(allocator, &rec.status, "running");
    rec.updated_ts = rec.started_ts;

    try writeTaskRecord(allocator, task_path, &rec);
    try appendTaskNotification(allocator, cwd, rec.id, "started", rec.status, rec.title);

    return std.fmt.allocPrint(
        allocator,
        "task started\nid={s}\npid={d}\nstatus={s}\noutput={s}",
        .{ rec.id, rec.run_pid, rec.status, rec.output_path },
    );
}

pub fn taskPoll(allocator: std.mem.Allocator, cwd: []const u8, id: []const u8) ![]u8 {
    const task_path = try taskPathAlloc(allocator, cwd, id);
    defer allocator.free(task_path);

    var rec = readTaskRecord(allocator, task_path) catch return allocator.dupe(u8, "task not found");
    defer rec.deinit(allocator);
    _ = try refreshTaskRuntimeState(allocator, cwd, task_path, &rec);
    return formatTaskRecord(allocator, &rec);
}

// --- Dependency graph (swarm-tasks-01) ---

// Record a dependency edge from both sides: `from_id` blocks `to_id`, so
// `to_id` is blocked_by `from_id`. Mirrors the reference `blockTask`
// (tasks.ts:458-486) which updates `from.blocks` and `to.blockedBy`. Idempotent:
// re-calling with the same pair is a no-op (no duplicate entries). Returns a
// short status string for the caller.
pub fn blockTask(allocator: std.mem.Allocator, cwd: []const u8, from_id: []const u8, to_id: []const u8) ![]u8 {
    const from_path = try taskPathAlloc(allocator, cwd, from_id);
    defer allocator.free(from_path);
    const to_path = try taskPathAlloc(allocator, cwd, to_id);
    defer allocator.free(to_path);

    var from_rec = readTaskRecord(allocator, from_path) catch return allocator.dupe(u8, "task not found");
    defer from_rec.deinit(allocator);
    var to_rec = readTaskRecord(allocator, to_path) catch return allocator.dupe(u8, "task not found");
    defer to_rec.deinit(allocator);

    // `from.id`/`to.id` are the canonical ids stored in the records; use those
    // so the edge survives id-normalization on either side.
    const changed_from = try appendIdIfMissing(allocator, &from_rec.blocks, to_rec.id);
    const changed_to = try appendIdIfMissing(allocator, &to_rec.blocked_by, from_rec.id);

    if (changed_from) {
        from_rec.updated_ts = clock.nowSeconds();
        try writeTaskRecord(allocator, from_path, &from_rec);
    }
    if (changed_to) {
        to_rec.updated_ts = clock.nowSeconds();
        try writeTaskRecord(allocator, to_path, &to_rec);
    }

    return std.fmt.allocPrint(allocator, "blocked\nfrom={s}\nto={s}", .{ from_rec.id, to_rec.id });
}

// Delete a task and strip its id from every other task's `blocks`/`blocked_by`
// edges (cascade cleanup). Mirrors the reference `deleteTask`
// (tasks.ts:420-434). Records that fail to parse are skipped so a single
// corrupt file does not abort the whole delete.
pub fn taskDelete(allocator: std.mem.Allocator, cwd: []const u8, id: []const u8) ![]u8 {
    const task_path = try taskPathAlloc(allocator, cwd, id);
    defer allocator.free(task_path);

    // Resolve the canonical id from the record before unlinking so the cascade
    // strips the exact stored id, then unlink the file.
    var deleted_id_buf: ?[]u8 = null;
    defer if (deleted_id_buf) |b| allocator.free(b);
    if (readTaskRecord(allocator, task_path)) |loaded| {
        var rec = loaded;
        defer rec.deinit(allocator);
        deleted_id_buf = try allocator.dupe(u8, rec.id);
    } else |_| {
        // Record missing or unreadable; still attempt to unlink and cascade by
        // the requested id.
        deleted_id_buf = try allocator.dupe(u8, std.mem.trim(u8, id, " \t\r\n"));
    }
    const deleted_id = deleted_id_buf.?;

    std.Io.Dir.cwd().deleteFile(rt.io, task_path) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, "task not found"),
        else => return err,
    };

    try cascadeRemoveId(allocator, cwd, deleted_id);
    try appendTaskNotification(allocator, cwd, deleted_id, "deleted", "deleted", deleted_id);

    return std.fmt.allocPrint(allocator, "deleted\nid={s}", .{deleted_id});
}

// Strip `deleted_id` from every task's `blocks`/`blocked_by` arrays, rewriting
// only the records that actually changed. Tolerant of unparseable records.
fn cascadeRemoveId(allocator: std.mem.Allocator, cwd: []const u8, deleted_id: []const u8) !void {
    const tasks_rel = try tasksRelAlloc(allocator);
    defer allocator.free(tasks_rel);
    const tasks_dir = try helpers.workspacePathAlloc(allocator, cwd, tasks_rel);
    defer allocator.free(tasks_dir);

    var dir = std.Io.Dir.cwd().openDir(rt.io, tasks_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(rt.io);

    var it = dir.iterate();
    while (try it.next(rt.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".task")) continue;

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tasks_dir, entry.name });
        defer allocator.free(full_path);

        var rec = readTaskRecord(allocator, full_path) catch continue;
        defer rec.deinit(allocator);

        const changed_blocks = removeIdFromList(allocator, &rec.blocks, deleted_id);
        const changed_blocked = removeIdFromList(allocator, &rec.blocked_by, deleted_id);
        if (changed_blocks or changed_blocked) {
            rec.updated_ts = clock.nowSeconds();
            writeTaskRecord(allocator, full_path, &rec) catch |err| {
                std.log.debug("task: cascade rewrite failed for {s}: {}", .{ entry.name, err });
            };
        }
    }
}

// Return the ids in `rec.blocked_by` whose tasks are not yet resolved
// (status not `done`/`completed`). Used by the claim path (Task 3). Caller owns
// the returned slice-of-slices (free each element then the array).
pub fn unresolvedBlockers(allocator: std.mem.Allocator, cwd: []const u8, rec: *const TaskRecord) ![][]u8 {
    var out = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit();
    }
    for (rec.blocked_by) |blocker_id| {
        const blocker_path = taskPathAlloc(allocator, cwd, blocker_id) catch continue;
        defer allocator.free(blocker_path);
        var blocker = readTaskRecord(allocator, blocker_path) catch {
            // A blocker whose record is missing is treated as resolved (it was
            // deleted); the cascade should have already stripped it, but be
            // defensive and do not block on a phantom.
            continue;
        };
        defer blocker.deinit(allocator);
        if (isResolvedStatus(blocker.status)) continue;
        try out.append(try allocator.dupe(u8, blocker_id));
    }
    return out.toOwnedSlice();
}

fn isResolvedStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "done") or std.mem.eql(u8, status, "completed");
}

// Append `id` to `list` if not already present, reallocating the slice.
// Returns true if the list changed. The list owns its element slices.
fn appendIdIfMissing(allocator: std.mem.Allocator, list: *[][]u8, id: []const u8) !bool {
    for (list.*) |existing| {
        if (std.mem.eql(u8, existing, id)) return false;
    }
    const next = try allocator.realloc(list.*, list.len + 1);
    list.* = next;
    next[next.len - 1] = try allocator.dupe(u8, id);
    return true;
}

// Remove every occurrence of `id` from `list`, freeing the dropped element
// slices and compacting in place (the array length shrinks). Returns true if
// anything was removed.
fn removeIdFromList(allocator: std.mem.Allocator, list: *[][]u8, id: []const u8) bool {
    var write_idx: usize = 0;
    var removed = false;
    for (list.*) |item| {
        if (std.mem.eql(u8, item, id)) {
            allocator.free(item);
            removed = true;
            continue;
        }
        list.*[write_idx] = item;
        write_idx += 1;
    }
    if (removed) {
        // Shrink the backing slice to the compacted length. The freed element
        // slices above are already released; this just trims the array.
        list.* = allocator.realloc(list.*, write_idx) catch list.*[0..write_idx];
    }
    return removed;
}

// --- Atomic claim flow (swarm-tasks-02) ---

// Why a claim task can be rejected. Mirrors the reference `ClaimTaskResult`
// reasons (tasks.ts:541-692): a task may already be owned by a different agent,
// already resolved, blocked by unresolved blockers, or the claimant may already
// be busy with another open task. `ok` means the owner was assigned.
pub const ClaimReason = enum {
    ok,
    task_not_found,
    already_claimed,
    already_resolved,
    blocked,
    agent_busy,
};

// Result of a `claimTask` call. `blocked_by` is populated only for `.blocked`
// (the unresolved blocker ids); `busy_with` is populated only for `.agent_busy`
// (the claimant's other open task ids). The caller owns both slices and must
// free them via `deinit`.
pub const ClaimResult = struct {
    reason: ClaimReason,
    blocked_by: [][]u8 = &.{},
    busy_with: [][]u8 = &.{},

    pub fn deinit(self: *ClaimResult, allocator: std.mem.Allocator) void {
        freeStringList(allocator, self.blocked_by);
        freeStringList(allocator, self.busy_with);
        self.blocked_by = &.{};
        self.busy_with = &.{};
    }
};

// Atomically claim `id` for `claimant`. Refuses if owned by a different agent,
// if already resolved, or if blocked by unresolved blockers; when `check_busy`
// is set, also refuses if the claimant already owns another unresolved task.
// On success the task's `owner` is set to `claimant` and persisted.
//
// Serializes against concurrent claimers with a per-task-list lock file (O_EXCL
// create + bounded backoff retry); cross-process safety rides on that lock.
// Mirrors the reference `claimTask` / `claimTaskWithBusyCheck`
// (tasks.ts:541-692).
pub fn claimTask(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    id: []const u8,
    claimant: []const u8,
    check_busy: bool,
) !ClaimResult {
    const task_path = taskPathAlloc(allocator, cwd, id) catch return .{ .reason = .task_not_found };
    defer allocator.free(task_path);

    // Existence check before locking: a missing task is a clean
    // `task_not_found`, matching the reference which probes before lock.
    {
        var probe = readTaskRecord(allocator, task_path) catch return .{ .reason = .task_not_found };
        probe.deinit(allocator);
    }

    const release = try acquireTaskListLock(allocator, cwd);
    defer releaseTaskListLock(allocator, release);

    var rec = readTaskRecord(allocator, task_path) catch return .{ .reason = .task_not_found };
    defer rec.deinit(allocator);

    // Already claimed by a different agent.
    if (rec.owner.len > 0 and !std.mem.eql(u8, rec.owner, claimant)) {
        return .{ .reason = .already_claimed };
    }
    // Already resolved (done/completed).
    if (isResolvedStatus(rec.status)) {
        return .{ .reason = .already_resolved };
    }
    // Blocked by unresolved blockers.
    const unresolved = try unresolvedBlockers(allocator, cwd, &rec);
    if (unresolved.len > 0) {
        return .{ .reason = .blocked, .blocked_by = unresolved };
    }
    freeStringList(allocator, unresolved);

    // Busy check: the claimant already owns another unresolved task.
    if (check_busy) {
        const busy = try ownedUnresolvedTaskIds(allocator, cwd, claimant, rec.id);
        if (busy.len > 0) {
            return .{ .reason = .agent_busy, .busy_with = busy };
        }
        freeStringList(allocator, busy);
    }

    try helpers.replaceOwned(allocator, &rec.owner, claimant);
    rec.updated_ts = clock.nowSeconds();
    try writeTaskRecord(allocator, task_path, &rec);
    try appendTaskNotification(allocator, cwd, rec.id, "claimed", rec.status, rec.title);
    return .{ .reason = .ok };
}

// Return the ids of every unresolved task owned by `owner`, excluding
// `exclude_id`. Caller owns the returned slice-of-slices.
fn ownedUnresolvedTaskIds(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    owner: []const u8,
    exclude_id: []const u8,
) ![][]u8 {
    const snapshots = try listTaskSnapshots(allocator, cwd, null);
    defer freeTaskSnapshots(allocator, snapshots);

    var out = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit();
    }
    for (snapshots) |snap| {
        if (isResolvedStatus(snap.status)) continue;
        if (snap.owner.len == 0 or !std.mem.eql(u8, snap.owner, owner)) continue;
        if (std.mem.eql(u8, snap.id, exclude_id)) continue;
        try out.append(try allocator.dupe(u8, snap.id));
    }
    return out.toOwnedSlice();
}

// A single agent's idle/busy status derived from task ownership.
pub const AgentStatus = struct {
    name: []u8,
    busy: bool,
    current_tasks: [][]u8,

    pub fn deinit(self: *AgentStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        freeStringList(allocator, self.current_tasks);
    }
};

pub fn freeAgentStatuses(allocator: std.mem.Allocator, items: []AgentStatus) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

// Bucket the workspace's unresolved tasks by owner and report each distinct
// owner as idle (no open tasks -- never appears) or busy with its owned task
// ids. Mirrors the reference `getAgentStatuses` (tasks.ts:763-798), which
// groups unresolved tasks by owner; structured team-member enumeration (the
// reference's `readTeamMembers`) lands with the structured-membership task, so
// here we derive the status set straight from task ownership. Caller owns the
// returned slice via `freeAgentStatuses`.
pub fn getAgentStatuses(allocator: std.mem.Allocator, cwd: []const u8) ![]AgentStatus {
    const snapshots = try listTaskSnapshots(allocator, cwd, null);
    defer freeTaskSnapshots(allocator, snapshots);

    var out = std.array_list.Managed(AgentStatus).init(allocator);
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit();
    }

    for (snapshots) |snap| {
        if (isResolvedStatus(snap.status)) continue;
        if (snap.owner.len == 0) continue;

        // Find or create the owner's bucket.
        var bucket: ?*AgentStatus = null;
        for (out.items) |*existing| {
            if (std.mem.eql(u8, existing.name, snap.owner)) {
                bucket = existing;
                break;
            }
        }
        if (bucket == null) {
            try out.append(.{
                .name = try allocator.dupe(u8, snap.owner),
                .busy = true,
                .current_tasks = try allocator.alloc([]u8, 0),
            });
            bucket = &out.items[out.items.len - 1];
        }
        _ = try appendIdIfMissing(allocator, &bucket.?.current_tasks, snap.id);
    }

    return out.toOwnedSlice();
}

// Clear `owner` and reset the status to `open` on every unresolved task owned
// by `teammate_id` or `teammate_name`. Mirrors the reference
// `unassignTeammateTasks` (tasks.ts:818-860). `reason` is `terminated` or
// `shutdown` and shapes the returned notification string (caller frees it).
pub fn unassignTeammateTasks(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    teammate_id: []const u8,
    teammate_name: []const u8,
    reason: []const u8,
) ![]u8 {
    const snapshots = try listTaskSnapshots(allocator, cwd, null);
    defer freeTaskSnapshots(allocator, snapshots);

    var unassigned = std_io.StringBuilder.init(allocator);
    defer unassigned.deinit();
    var count: usize = 0;

    for (snapshots) |snap| {
        if (isResolvedStatus(snap.status)) continue;
        const owned = (teammate_id.len > 0 and std.mem.eql(u8, snap.owner, teammate_id)) or
            (teammate_name.len > 0 and std.mem.eql(u8, snap.owner, teammate_name));
        if (!owned) continue;

        const task_path = taskPathAlloc(allocator, cwd, snap.id) catch continue;
        defer allocator.free(task_path);
        var rec = readTaskRecord(allocator, task_path) catch continue;
        defer rec.deinit(allocator);
        try helpers.replaceOwned(allocator, &rec.owner, "");
        try helpers.replaceOwned(allocator, &rec.status, "open");
        rec.updated_ts = clock.nowSeconds();
        writeTaskRecord(allocator, task_path, &rec) catch continue;

        if (count != 0) try unassigned.appendSlice(", ");
        try unassigned.writer().print("#{s} \"{s}\"", .{ snap.id, snap.title });
        count += 1;
    }

    const action_verb = if (std.mem.eql(u8, reason, "terminated")) "was terminated" else "has shut down";
    if (count == 0) {
        return std.fmt.allocPrint(allocator, "{s} {s}.", .{ teammate_name, action_verb });
    }
    return std.fmt.allocPrint(
        allocator,
        "{s} {s}. {d} task(s) were unassigned: {s}. Use TaskList to check availability and TaskUpdate with owner to reassign them to idle teammates.",
        .{ teammate_name, action_verb, count, unassigned.items() },
    );
}

// --- Task-list lock file ---

const LOCK_FILENAME = ".claim.lock";
const LOCK_MAX_ATTEMPTS: u32 = 10;

// Acquire the per-task-list lock by O_EXCL-creating a sentinel file in the
// tasks dir. Retries with bounded exponential backoff (core/backoff.zig) when
// the lock is held. Returns the owned absolute lock path on success; the caller
// must release it via `releaseTaskListLock`. The lock is the only TOCTOU
// defense for cross-process claimers, mirroring the reference's proper-lockfile
// + LOCK_OPTIONS retry budget.
fn acquireTaskListLock(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const tasks_rel = try tasksRelAlloc(allocator);
    defer allocator.free(tasks_rel);
    const tasks_dir = try helpers.ensureWorkspaceDirPath(allocator, cwd, tasks_rel);
    defer allocator.free(tasks_dir);
    const lock_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tasks_dir, LOCK_FILENAME });
    errdefer allocator.free(lock_path);

    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        const file = std.Io.Dir.cwd().createFile(rt.io, lock_path, .{ .exclusive = true, .truncate = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                if (attempt + 1 >= LOCK_MAX_ATTEMPTS) return error.TaskListLockTimeout;
                const wait_ms = backoff.delayMs(attempt, 5, 200);
                clock.sleepNanos(wait_ms * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        file.close(rt.io);
        return lock_path;
    }
}

// Release a lock acquired by `acquireTaskListLock`: unlink the sentinel and
// free the owned path. Best-effort unlink so a vanished lock file is not fatal.
fn releaseTaskListLock(allocator: std.mem.Allocator, lock_path: []u8) void {
    std.Io.Dir.cwd().deleteFile(rt.io, lock_path) catch {};
    allocator.free(lock_path);
}

// --- Per-list numbering + reset (swarm-tasks-05) ---

const HIGHWATERMARK_FILENAME = ".highwatermark";

// Compute the next task number for a list directory: one past the maximum of
// (a) every existing `.task` file whose stem is a plain integer and (b) the
// persisted `.highwatermark`. Numbering starts at 1 for a fresh list. The
// high-water-mark survives a reset (which deletes the `.task` files) so a
// reset never recycles a previously used id.
fn nextTaskNumber(allocator: std.mem.Allocator, tasks_dir: []const u8) !u64 {
    var max_num: u64 = 0;

    const hwm = try readHighWaterMark(allocator, tasks_dir);
    if (hwm > max_num) max_num = hwm;

    var dir = std.Io.Dir.cwd().openDir(rt.io, tasks_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return max_num + 1,
        else => return err,
    };
    defer dir.close(rt.io);

    var it = dir.iterate();
    while (try it.next(rt.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".task")) continue;
        const stem = entry.name[0 .. entry.name.len - ".task".len];
        const n = std.fmt.parseInt(u64, stem, 10) catch continue;
        if (n > max_num) max_num = n;
    }
    return max_num + 1;
}

// Absolute path to a list dir's high-water-mark file. Caller frees.
fn highWaterMarkPath(allocator: std.mem.Allocator, tasks_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ tasks_dir, HIGHWATERMARK_FILENAME });
}

// Read the persisted high-water-mark integer; 0 when the file is absent or
// unparseable.
fn readHighWaterMark(allocator: std.mem.Allocator, tasks_dir: []const u8) !u64 {
    const path = try highWaterMarkPath(allocator, tasks_dir);
    defer allocator.free(path);
    const raw = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(64)) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer allocator.free(raw);
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len == 0) return 0;
    return std.fmt.parseInt(u64, text, 10) catch 0;
}

// Persist `value` as the list dir's high-water-mark (atomic write).
fn writeHighWaterMark(allocator: std.mem.Allocator, tasks_dir: []const u8, value: u64) !void {
    const path = try highWaterMarkPath(allocator, tasks_dir);
    defer allocator.free(path);
    const body = try std.fmt.allocPrint(allocator, "{d}\n", .{value});
    defer allocator.free(body);
    try writeTaskRecordAtomic(allocator, path, body);
}

// Reset a task list: record the current maximum task number into the
// high-water-mark, then delete every `.task` file in the list dir. The next
// create resumes numbering past the high-water-mark, so ids never repeat
// across a reset. Mirrors the reference `resetTaskList` (tasks.ts:147-188).
// The list dir is created when missing so a reset on a brand-new team is a
// clean no-op that still establishes the directory.
pub fn resetTaskList(allocator: std.mem.Allocator, cwd: []const u8, list_id: []const u8) !void {
    const tasks_dir = try helpers.tasksDirForList(allocator, cwd, list_id);
    defer allocator.free(tasks_dir);

    // Current max = highest of existing .task numbers and the stored hwm. We
    // reuse nextTaskNumber (which returns max+1) minus 1 to get the max.
    const next = try nextTaskNumber(allocator, tasks_dir);
    const current_max = next - 1;

    var dir = std.Io.Dir.cwd().openDir(rt.io, tasks_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try writeHighWaterMark(allocator, tasks_dir, current_max);
            return;
        },
        else => return err,
    };
    defer dir.close(rt.io);

    var it = dir.iterate();
    while (try it.next(rt.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".task")) continue;
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tasks_dir, entry.name });
        defer allocator.free(full_path);
        std.Io.Dir.cwd().deleteFile(rt.io, full_path) catch |err| {
            std.log.debug("task: resetTaskList failed to delete {s}: {}", .{ entry.name, err });
        };
    }

    try writeHighWaterMark(allocator, tasks_dir, current_max);
}

// --- Private helpers ---

// Workspace-relative subpath for the active task list's directory
// (`state/tasks/<listid>`). The list id resolves from
// `core/task_list_id.zig` (env override -> bound leader team -> default), so a
// team's tasks live in their own renumber-from-1 directory and an un-teamed
// session keeps the single default list (swarm-tasks-05). Caller frees.
fn tasksRelAlloc(allocator: std.mem.Allocator) ![]u8 {
    const list_id = try task_list_id.resolveAlloc(allocator);
    defer allocator.free(list_id);
    return helpers.tasksSubpathForListAlloc(allocator, list_id);
}

fn taskPathAlloc(allocator: std.mem.Allocator, cwd: []const u8, id: []const u8) ![]u8 {
    const safe_id = std.mem.trim(u8, id, " \t\r\n");
    if (!helpers.isSafeIdentifier(safe_id)) return error.InvalidTaskId;

    const tasks_rel = try tasksRelAlloc(allocator);
    defer allocator.free(tasks_rel);
    const filename = try std.fmt.allocPrint(allocator, "{s}.task", .{safe_id});
    defer allocator.free(filename);
    const rel = try std.fs.path.join(allocator, &.{ tasks_rel, filename });
    defer allocator.free(rel);
    return helpers.workspacePathAlloc(allocator, cwd, rel);
}

fn isProcessRunning(allocator: std.mem.Allocator, cwd: []const u8, pid: i64) bool {
    if (pid <= 0) return false;
    const cmd = std.fmt.allocPrint(allocator, "kill -0 {d} >/dev/null 2>&1", .{pid}) catch return false;
    defer allocator.free(cmd);
    const argv = [_][]const u8{ "/bin/sh", "-lc", cmd };
    const result = std.process.run(allocator, rt.io, .{
        .argv = &argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

fn killProcessByPid(allocator: std.mem.Allocator, cwd: []const u8, pid: i64) !bool {
    if (pid <= 0) return false;
    const cmd = try std.fmt.allocPrint(allocator, "kill {d} >/dev/null 2>&1", .{pid});
    defer allocator.free(cmd);
    const argv = [_][]const u8{ "/bin/sh", "-lc", cmd };
    const result = try std.process.run(allocator, rt.io, .{
        .argv = &argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

fn appendTaskNotification(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    task_id: []const u8,
    event: []const u8,
    status: []const u8,
    message: []const u8,
) !void {
    const note_path = try helpers.workspacePathAlloc(allocator, cwd, TASK_NOTIFICATIONS_SUBPATH);
    defer allocator.free(note_path);
    const parent = std.fs.path.dirname(note_path) orelse cwd;
    std.Io.Dir.cwd().createDirPath(rt.io, parent) catch |err| {
        std.log.warn("task: failed to create notification dir: {s}", .{@errorName(err)});
    };

    const escaped_message = try helpers.escapeTextAlloc(allocator, message);
    defer allocator.free(escaped_message);
    const escaped_status = try helpers.escapeTextAlloc(allocator, status);
    defer allocator.free(escaped_status);

    const file = try std.Io.Dir.cwd().createFile(rt.io, note_path, .{ .truncate = false, .read = true });
    defer file.close(rt.io);
    // 0.16: no seek; subsequent writes go positional
    try std_io.fileWriter(file).print(
        "ts={d};task_id={s};event={s};status={s};message={s}\n",
        .{ clock.nowSeconds(), task_id, event, escaped_status, escaped_message },
    );
}

/// True for shell exit codes that represent a deliberate kill rather than a
/// command failure, whose failure notification the reference suppresses for
/// shell-backed tasks (stopTask.ts:70-95). 137 == 128 + 9 (SIGKILL).
fn isSuppressedShellExit(exit_code: i32) bool {
    return exit_code == 137;
}

fn refreshTaskRuntimeState(allocator: std.mem.Allocator, cwd: []const u8, task_path: []const u8, rec: *TaskRecord) !bool {
    if (!std.mem.eql(u8, rec.status, "running")) return false;
    if (rec.exit_path.len == 0) {
        if (rec.run_pid > 0 and !isProcessRunning(allocator, cwd, rec.run_pid)) {
            rec.finished_ts = clock.nowSeconds();
            rec.updated_ts = rec.finished_ts;
            rec.run_pid = 0;
            rec.progress = 100;
            try helpers.replaceOwned(allocator, &rec.status, "failed");
            try appendTaskNotification(allocator, cwd, rec.id, "failed", rec.status, "task process exited without exit file");
            try writeTaskRecord(allocator, task_path, rec);
            return true;
        }
        return false;
    }

    const exit_abs = try helpers.resolvePathAlloc(allocator, cwd, rec.exit_path);
    defer allocator.free(exit_abs);
    const exit_raw = std.Io.Dir.cwd().readFileAlloc(rt.io, exit_abs, allocator, .limited(256)) catch return false;
    defer allocator.free(exit_raw);

    const code_text = std.mem.trim(u8, exit_raw, " \t\r\n");
    if (code_text.len == 0) return false;
    const exit_code = std.fmt.parseInt(i32, code_text, 10) catch return false;

    rec.finished_ts = clock.nowSeconds();
    rec.updated_ts = rec.finished_ts;
    rec.run_pid = 0;
    rec.progress = 100;
    if (exit_code == 0) {
        try helpers.replaceOwned(allocator, &rec.status, "done");
        try appendTaskNotification(allocator, cwd, rec.id, "completed", rec.status, rec.title);
    } else if (isSuppressedShellExit(exit_code)) {
        // Exit 137 == 128 + SIGKILL: the shell task was killed (e.g. via TaskStop
        // / interrupt), not a genuine command failure. The reference suppresses
        // the exit-137 failure notification for shell-backed tasks
        // (stopTask.ts:70-95) so a deliberate stop does not read as a failure. The
        // task is still moved to a terminal `stopped` status.
        try helpers.replaceOwned(allocator, &rec.status, "stopped");
    } else {
        try helpers.replaceOwned(allocator, &rec.status, "failed");
        const failure_msg = try std.fmt.allocPrint(allocator, "{s} (exit={d})", .{ rec.title, exit_code });
        defer allocator.free(failure_msg);
        try appendTaskNotification(allocator, cwd, rec.id, "failed", rec.status, failure_msg);
    }

    if (rec.output_path.len > 0) {
        const tail = helpers.readFileTailAlloc(allocator, cwd, rec.output_path, 4 * 1024) catch null;
        if (tail) |chunk| {
            defer allocator.free(chunk);
            if (chunk.len > 0) try helpers.replaceOwned(allocator, &rec.output, chunk);
        }
    }
    try writeTaskRecord(allocator, task_path, rec);
    return true;
}

fn extractFieldValue(text: []const u8, field: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.mem.eql(u8, key, field)) continue;
        return std.mem.trim(u8, line[eq + 1 ..], " \t");
    }
    return null;
}

fn taskStatusRank(status: []const u8) u8 {
    if (std.mem.eql(u8, status, "running")) return 0;
    if (std.mem.eql(u8, status, "queued")) return 1;
    if (std.mem.eql(u8, status, "open")) return 2;
    if (std.mem.eql(u8, status, "stopped")) return 3;
    if (std.mem.eql(u8, status, "failed")) return 4;
    if (std.mem.eql(u8, status, "done")) return 5;
    return 6;
}

fn snapshotBefore(a: *const TaskSnapshot, b: *const TaskSnapshot) bool {
    const a_rank = taskStatusRank(a.status);
    const b_rank = taskStatusRank(b.status);
    if (a_rank != b_rank) return a_rank < b_rank;
    if (a.updated_ts != b.updated_ts) return a.updated_ts > b.updated_ts;
    return std.mem.lessThan(u8, a.id, b.id);
}

fn sortTaskSnapshots(items: []TaskSnapshot) void {
    if (items.len < 2) return;

    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and snapshotBefore(&items[j], &items[j - 1])) : (j -= 1) {
            const tmp = items[j - 1];
            items[j - 1] = items[j];
            items[j] = tmp;
        }
    }
}

fn writeTaskRecord(allocator: std.mem.Allocator, path: []const u8, rec: *const TaskRecord) !void {
    // Render the record as a JSON document. JSON can carry the array fields
    // (`blocks`/`blocked_by`) and the nested `metadata` object that the old
    // line-based key=value format could not represent (swarm-tasks-01/04).
    //
    // Render into a buffer first so the on-disk write is atomic.
    // writeTaskRecord runs on every TaskCreate / TaskUpdate /
    // TaskStop / status transition; a SIGINT mid-write used to
    // leave the per-task state file truncated, and readTaskRecord
    // would either fail to parse or surface stale fields, so
    // background-task tracking lost coherence on a single Ctrl+C.
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    const w = buf.writer();

    try w.writeAll("{\n  ");
    try writeJsonStringField(w, "id", rec.id);
    try w.writeAll(",\n  ");
    try writeJsonStringField(w, "title", rec.title);
    try w.writeAll(",\n  ");
    try writeJsonStringField(w, "summary", rec.summary);
    try w.writeAll(",\n  ");
    try writeJsonStringField(w, "status", rec.status);
    try w.writeAll(",\n  ");
    try writeJsonStringField(w, "output", rec.output);
    try w.writeAll(",\n  ");
    try writeJsonStringField(w, "owner", rec.owner);
    try w.writeAll(",\n  ");
    try writeJsonStringField(w, "command", rec.command);
    try w.writeAll(",\n  ");
    try writeJsonStringField(w, "priority", rec.priority);
    try w.writeAll(",\n  ");
    try writeJsonStringField(w, "deps", rec.deps);
    try w.writeAll(",\n  ");
    try writeJsonStringField(w, "active_form", rec.active_form);
    try w.writeAll(",\n  ");
    try writeJsonStringArrayField(w, "blocks", rec.blocks);
    try w.writeAll(",\n  ");
    try writeJsonStringArrayField(w, "blocked_by", rec.blocked_by);
    try w.writeAll(",\n  ");
    try writeJsonMetadataField(w, "metadata", rec.metadata_json);
    try w.writeAll(",\n  ");
    try w.print("\"run_pid\": {d}", .{rec.run_pid});
    try w.writeAll(",\n  ");
    try writeJsonStringField(w, "output_path", rec.output_path);
    try w.writeAll(",\n  ");
    try writeJsonStringField(w, "exit_path", rec.exit_path);
    try w.writeAll(",\n  ");
    try w.print("\"started_ts\": {d}", .{rec.started_ts});
    try w.writeAll(",\n  ");
    try w.print("\"finished_ts\": {d}", .{rec.finished_ts});
    try w.writeAll(",\n  ");
    try w.print("\"progress\": {d}", .{rec.progress});
    try w.writeAll(",\n  ");
    try w.print("\"created_ts\": {d}", .{rec.created_ts});
    try w.writeAll(",\n  ");
    try w.print("\"updated_ts\": {d}", .{rec.updated_ts});
    try w.writeAll("\n}\n");

    try writeTaskRecordAtomic(allocator, path, buf.items());
}

fn writeJsonStringField(w: anytype, key: []const u8, value: []const u8) !void {
    try w.print("\"{s}\": ", .{key});
    try std.json.Stringify.value(value, .{}, w);
}

fn writeJsonStringArrayField(w: anytype, key: []const u8, list: []const []u8) !void {
    try w.print("\"{s}\": [", .{key});
    for (list, 0..) |item, idx| {
        if (idx != 0) try w.writeAll(", ");
        try std.json.Stringify.value(item, .{}, w);
    }
    try w.writeByte(']');
}

// Emit the metadata as a nested object. The stored value is an opaque raw JSON
// object string; if empty (no metadata) emit `{}`.
fn writeJsonMetadataField(w: anytype, key: []const u8, metadata_json: []const u8) !void {
    try w.print("\"{s}\": ", .{key});
    const trimmed = std.mem.trim(u8, metadata_json, " \t\r\n");
    if (trimmed.len == 0) {
        try w.writeAll("{}");
    } else {
        try w.writeAll(trimmed);
    }
}

fn writeTaskRecordAtomic(allocator: std.mem.Allocator, target: []const u8, bytes: []const u8) !void {
    var nonce: [8]u8 = undefined;
    rng.bytes(&nonce);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{x}{x}{x}{x}{x}{x}{x}{x}", .{
        target, nonce[0], nonce[1], nonce[2], nonce[3], nonce[4], nonce[5], nonce[6], nonce[7],
    });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, bytes);
        file.sync(rt.io) catch {};
    }
    try std.Io.Dir.renameAbsolute(tmp_path, target, rt.io);
}

fn readTaskRecord(allocator: std.mem.Allocator, path: []const u8) !TaskRecord {
    const data = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(data);

    return parseTaskRecordBytes(allocator, data);
}

// Parse a `.task` file body. JSON documents (begin with `{`) carry the full
// field set including arrays + metadata; anything else is treated as the legacy
// `key=value` format so existing `.task` files still load (back-compat).
fn parseTaskRecordBytes(allocator: std.mem.Allocator, data: []const u8) !TaskRecord {
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    if (trimmed.len > 0 and trimmed[0] == '{') {
        return parseJsonTaskRecord(allocator, trimmed);
    }
    return parseLegacyTaskRecord(allocator, data);
}

fn parseJsonTaskRecord(allocator: std.mem.Allocator, data: []const u8) !TaskRecord {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidTaskRecord;
    // CLAUDE.md ObjectMap rule: take the object by pointer; do not value-copy it
    // (a copy desyncs the entries pointer if anything reallocates).
    const obj = &parsed.value.object;

    var rec = try TaskRecord.init(allocator);
    errdefer rec.deinit(allocator);

    if (jsonGetString(obj, "id")) |v| try helpers.replaceOwned(allocator, &rec.id, v);
    if (jsonGetString(obj, "title")) |v| try helpers.replaceOwned(allocator, &rec.title, v);
    if (jsonGetString(obj, "summary")) |v| try helpers.replaceOwned(allocator, &rec.summary, v);
    if (jsonGetString(obj, "status")) |v| try helpers.replaceOwned(allocator, &rec.status, v);
    if (jsonGetString(obj, "output")) |v| try helpers.replaceOwned(allocator, &rec.output, v);
    if (jsonGetString(obj, "owner")) |v| try helpers.replaceOwned(allocator, &rec.owner, v);
    if (jsonGetString(obj, "command")) |v| try helpers.replaceOwned(allocator, &rec.command, v);
    if (jsonGetString(obj, "priority")) |v| try helpers.replaceOwned(allocator, &rec.priority, v);
    if (jsonGetString(obj, "deps")) |v| try helpers.replaceOwned(allocator, &rec.deps, v);
    if (jsonGetString(obj, "active_form")) |v| try helpers.replaceOwned(allocator, &rec.active_form, v);
    if (jsonGetString(obj, "output_path")) |v| try helpers.replaceOwned(allocator, &rec.output_path, v);
    if (jsonGetString(obj, "exit_path")) |v| try helpers.replaceOwned(allocator, &rec.exit_path, v);

    if (obj.get("blocks")) |v| {
        freeStringList(allocator, rec.blocks);
        rec.blocks = try jsonStringArray(allocator, v);
    }
    if (obj.get("blocked_by")) |v| {
        freeStringList(allocator, rec.blocked_by);
        rec.blocked_by = try jsonStringArray(allocator, v);
    }
    if (obj.get("metadata")) |v| {
        if (v == .object and v.object.count() > 0) {
            var meta_buf = std_io.StringBuilder.init(allocator);
            defer meta_buf.deinit();
            try std.json.Stringify.value(v, .{}, meta_buf.writer());
            try helpers.replaceOwned(allocator, &rec.metadata_json, meta_buf.items());
        }
    }

    if (jsonGetInt(obj, "run_pid")) |n| rec.run_pid = n;
    if (jsonGetInt(obj, "started_ts")) |n| rec.started_ts = n;
    if (jsonGetInt(obj, "finished_ts")) |n| rec.finished_ts = n;
    if (jsonGetInt(obj, "created_ts")) |n| rec.created_ts = n;
    if (jsonGetInt(obj, "updated_ts")) |n| rec.updated_ts = n;
    if (jsonGetInt(obj, "progress")) |n| {
        const clamped = @min(@as(i64, 100), @max(@as(i64, 0), n));
        rec.progress = @intCast(clamped);
    }

    return rec;
}

fn jsonGetString(obj: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn jsonGetInt(obj: *const std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        .string => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t\r\n"), 10) catch null,
        else => null,
    };
}

fn jsonStringArray(allocator: std.mem.Allocator, value: std.json.Value) ![][]u8 {
    if (value != .array) return allocator.alloc([]u8, 0);
    var out = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit();
    }
    for (value.array.items) |item| {
        if (item != .string) continue;
        try out.append(try allocator.dupe(u8, item.string));
    }
    return out.toOwnedSlice();
}

fn parseLegacyTaskRecord(allocator: std.mem.Allocator, data: []const u8) !TaskRecord {
    var rec = try TaskRecord.init(allocator);
    errdefer rec.deinit(allocator);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value_enc = std.mem.trim(u8, line[eq + 1 ..], " \t");
        const value = try helpers.unescapeTextAlloc(allocator, value_enc);
        defer allocator.free(value);

        if (std.mem.eql(u8, key, "id")) {
            try helpers.replaceOwned(allocator, &rec.id, value);
        } else if (std.mem.eql(u8, key, "title")) {
            try helpers.replaceOwned(allocator, &rec.title, value);
        } else if (std.mem.eql(u8, key, "summary")) {
            try helpers.replaceOwned(allocator, &rec.summary, value);
        } else if (std.mem.eql(u8, key, "status")) {
            try helpers.replaceOwned(allocator, &rec.status, value);
        } else if (std.mem.eql(u8, key, "output")) {
            try helpers.replaceOwned(allocator, &rec.output, value);
        } else if (std.mem.eql(u8, key, "owner")) {
            try helpers.replaceOwned(allocator, &rec.owner, value);
        } else if (std.mem.eql(u8, key, "command")) {
            try helpers.replaceOwned(allocator, &rec.command, value);
        } else if (std.mem.eql(u8, key, "priority")) {
            try helpers.replaceOwned(allocator, &rec.priority, value);
        } else if (std.mem.eql(u8, key, "deps")) {
            try helpers.replaceOwned(allocator, &rec.deps, value);
        } else if (std.mem.eql(u8, key, "output_path")) {
            try helpers.replaceOwned(allocator, &rec.output_path, value);
        } else if (std.mem.eql(u8, key, "exit_path")) {
            try helpers.replaceOwned(allocator, &rec.exit_path, value);
        } else if (std.mem.eql(u8, key, "run_pid")) {
            rec.run_pid = std.fmt.parseInt(i64, value, 10) catch 0;
        } else if (std.mem.eql(u8, key, "started_ts")) {
            rec.started_ts = std.fmt.parseInt(i64, value, 10) catch rec.started_ts;
        } else if (std.mem.eql(u8, key, "finished_ts")) {
            rec.finished_ts = std.fmt.parseInt(i64, value, 10) catch rec.finished_ts;
        } else if (std.mem.eql(u8, key, "progress")) {
            const parsed = std.fmt.parseInt(u16, value, 10) catch rec.progress;
            rec.progress = @intCast(@min(@as(u16, 100), parsed));
        } else if (std.mem.eql(u8, key, "created_ts")) {
            rec.created_ts = std.fmt.parseInt(i64, value, 10) catch rec.created_ts;
        } else if (std.mem.eql(u8, key, "updated_ts")) {
            rec.updated_ts = std.fmt.parseInt(i64, value, 10) catch rec.updated_ts;
        }
    }
    return rec;
}

fn formatTaskRecord(allocator: std.mem.Allocator, rec: *const TaskRecord) ![]u8 {
    const blocks = try joinIdsAlloc(allocator, rec.blocks);
    defer allocator.free(blocks);
    const blocked_by = try joinIdsAlloc(allocator, rec.blocked_by);
    defer allocator.free(blocked_by);
    const metadata = if (std.mem.trim(u8, rec.metadata_json, " \t\r\n").len == 0) "{}" else rec.metadata_json;

    return std.fmt.allocPrint(
        allocator,
        "task\nid={s}\nstatus={s}\npriority={s}\nprogress={d}\ntitle={s}\nsummary={s}\nactive_form={s}\nowner={s}\ncommand={s}\ndeps={s}\nblocks={s}\nblocked_by={s}\nmetadata={s}\nrun_pid={d}\noutput_path={s}\nexit_path={s}\nstarted_ts={d}\nfinished_ts={d}\ncreated_ts={d}\nupdated_ts={d}\noutput={s}",
        .{
            rec.id,
            rec.status,
            rec.priority,
            rec.progress,
            rec.title,
            rec.summary,
            rec.active_form,
            rec.owner,
            rec.command,
            rec.deps,
            blocks,
            blocked_by,
            metadata,
            rec.run_pid,
            rec.output_path,
            rec.exit_path,
            rec.started_ts,
            rec.finished_ts,
            rec.created_ts,
            rec.updated_ts,
            rec.output,
        },
    );
}

fn joinIdsAlloc(allocator: std.mem.Allocator, list: []const []u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    for (list, 0..) |item, idx| {
        if (idx != 0) try out.append(',');
        try out.appendSlice(item);
    }
    return out.toOwnedSlice();
}

fn writeTaskScript(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    script_path: []const u8,
    exit_path: []const u8,
    command: []const u8,
) !void {
    const cwd_q = try helpers.shellQuoteAlloc(allocator, cwd);
    defer allocator.free(cwd_q);
    const exit_q = try helpers.shellQuoteAlloc(allocator, exit_path);
    defer allocator.free(exit_q);

    const body = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\ncd {s} || exit 1\n{s}\ncode=$?\nprintf \"%s\" \"$code\" > {s}\nexit \"$code\"\n",
        .{ cwd_q, command, exit_q },
    );
    defer allocator.free(body);

    // Atomic + 0o600. Two defects in one site:
    //   (a) The previous direct createFile(truncate=true) used the
    //       default 0o666 & ~umask which on macOS / Linux desktops is
    //       typically 0o644 -- world-readable. The script body is
    //       the agent's command verbatim, which may include paths
    //       to secrets, args with sensitive flags, or env-pulled
    //       tokens after shell expansion. Any same-host local user
    //       could cat the script while the task runs.
    //   (b) SIGINT in the truncate->writeAll window left a truncated
    //       script (e.g. shebang + `cd $cwd` plus half a command);
    //       spawnDetachedScript fires immediately after, so the
    //       partial script may actually run and do something the
    //       user did not intend.
    // Stage into sibling .tmp.<hex-nonce>, fsync, chmod 0o600,
    // rename -- script is private to the agent's UID and either
    // fully present or untouched.
    try writeScriptAtomic(allocator, script_path, body);
}

fn writeScriptAtomic(allocator: std.mem.Allocator, target: []const u8, bytes: []const u8) !void {
    var nonce: [8]u8 = undefined;
    rng.bytes(&nonce);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{x}{x}{x}{x}{x}{x}{x}{x}", .{
        target, nonce[0], nonce[1], nonce[2], nonce[3], nonce[4], nonce[5], nonce[6], nonce[7],
    });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, bytes);
        file.sync(rt.io) catch {};
        file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o600)) catch {};
    }
    try std.Io.Dir.renameAbsolute(tmp_path, target, rt.io);
}

fn spawnDetachedScript(allocator: std.mem.Allocator, cwd: []const u8, script_path: []const u8, output_path: []const u8) !i64 {
    const script_q = try helpers.shellQuoteAlloc(allocator, script_path);
    defer allocator.free(script_q);
    const output_q = try helpers.shellQuoteAlloc(allocator, output_path);
    defer allocator.free(output_q);
    const launch = try std.fmt.allocPrint(
        allocator,
        "nohup /bin/sh {s} > {s} 2>&1 & echo $!",
        .{ script_q, output_q },
    );
    defer allocator.free(launch);

    const argv = [_][]const u8{ "/bin/sh", "-lc", launch };
    const result = try std.process.run(allocator, rt.io, .{
        .argv = &argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(8 * 1024),
        .stderr_limit = .limited(8 * 1024),
    });
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    if (!(result.term == .exited and result.term.exited == 0)) return error.Unexpected;

    const pid_text = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (pid_text.len == 0) return error.Unexpected;
    return std.fmt.parseInt(i64, pid_text, 10) catch error.Unexpected;
}

const testing = std.testing;

test "taskPathAlloc rejects invalid task id" {
    try testing.expectError(error.InvalidTaskId, taskPathAlloc(testing.allocator, "/repo", "../etc/passwd"));
}

test "sortTaskSnapshots prioritizes active and recently updated tasks" {
    var items = [_]TaskSnapshot{
        .{
            .id = try testing.allocator.dupe(u8, "task-done"),
            .title = try testing.allocator.dupe(u8, "done"),
            .summary = try testing.allocator.dupe(u8, ""),
            .status = try testing.allocator.dupe(u8, "done"),
            .output = try testing.allocator.dupe(u8, ""),
            .owner = try testing.allocator.dupe(u8, ""),
            .command = try testing.allocator.dupe(u8, ""),
            .priority = try testing.allocator.dupe(u8, ""),
            .deps = try testing.allocator.dupe(u8, ""),
            .blocks = try testing.allocator.alloc([]u8, 0),
            .blocked_by = try testing.allocator.alloc([]u8, 0),
            .active_form = try testing.allocator.dupe(u8, ""),
            .metadata_json = try testing.allocator.dupe(u8, ""),
            .run_pid = 0,
            .output_path = try testing.allocator.dupe(u8, ""),
            .exit_path = try testing.allocator.dupe(u8, ""),
            .started_ts = 0,
            .finished_ts = 0,
            .progress = 100,
            .created_ts = 1,
            .updated_ts = 1,
        },
        .{
            .id = try testing.allocator.dupe(u8, "task-running-new"),
            .title = try testing.allocator.dupe(u8, "running new"),
            .summary = try testing.allocator.dupe(u8, ""),
            .status = try testing.allocator.dupe(u8, "running"),
            .output = try testing.allocator.dupe(u8, ""),
            .owner = try testing.allocator.dupe(u8, ""),
            .command = try testing.allocator.dupe(u8, ""),
            .priority = try testing.allocator.dupe(u8, ""),
            .deps = try testing.allocator.dupe(u8, ""),
            .blocks = try testing.allocator.alloc([]u8, 0),
            .blocked_by = try testing.allocator.alloc([]u8, 0),
            .active_form = try testing.allocator.dupe(u8, ""),
            .metadata_json = try testing.allocator.dupe(u8, ""),
            .run_pid = 42,
            .output_path = try testing.allocator.dupe(u8, ""),
            .exit_path = try testing.allocator.dupe(u8, ""),
            .started_ts = 0,
            .finished_ts = 0,
            .progress = 20,
            .created_ts = 2,
            .updated_ts = 50,
        },
        .{
            .id = try testing.allocator.dupe(u8, "task-running-old"),
            .title = try testing.allocator.dupe(u8, "running old"),
            .summary = try testing.allocator.dupe(u8, ""),
            .status = try testing.allocator.dupe(u8, "running"),
            .output = try testing.allocator.dupe(u8, ""),
            .owner = try testing.allocator.dupe(u8, ""),
            .command = try testing.allocator.dupe(u8, ""),
            .priority = try testing.allocator.dupe(u8, ""),
            .deps = try testing.allocator.dupe(u8, ""),
            .blocks = try testing.allocator.alloc([]u8, 0),
            .blocked_by = try testing.allocator.alloc([]u8, 0),
            .active_form = try testing.allocator.dupe(u8, ""),
            .metadata_json = try testing.allocator.dupe(u8, ""),
            .run_pid = 24,
            .output_path = try testing.allocator.dupe(u8, ""),
            .exit_path = try testing.allocator.dupe(u8, ""),
            .started_ts = 0,
            .finished_ts = 0,
            .progress = 10,
            .created_ts = 2,
            .updated_ts = 10,
        },
    };
    defer for (&items) |*item| item.deinit(testing.allocator);

    sortTaskSnapshots(items[0..]);

    try testing.expectEqualStrings("task-running-new", items[0].id);
    try testing.expectEqualStrings("task-running-old", items[1].id);
    try testing.expectEqualStrings("task-done", items[2].id);
}

test "task record JSON round-trips arrays, active_form, and metadata" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(dir);

    const path = try std.fmt.allocPrint(allocator, "{s}/roundtrip.task", .{dir});
    defer allocator.free(path);

    var rec = try TaskRecord.init(allocator);
    defer rec.deinit(allocator);
    try helpers.replaceOwned(allocator, &rec.id, "task-1");
    try helpers.replaceOwned(allocator, &rec.title, "Build feature");
    try helpers.replaceOwned(allocator, &rec.active_form, "Building feature");
    try helpers.replaceOwned(allocator, &rec.metadata_json, "{\"k\":\"v\"}");
    freeStringList(allocator, rec.blocks);
    rec.blocks = try dupeStringList(allocator, &.{ "task-2", "task-3" });
    freeStringList(allocator, rec.blocked_by);
    rec.blocked_by = try dupeStringList(allocator, &.{ "task-4", "task-5" });
    rec.run_pid = 1234;
    rec.progress = 42;

    try writeTaskRecord(allocator, path, &rec);

    var loaded = try readTaskRecord(allocator, path);
    defer loaded.deinit(allocator);

    try testing.expectEqualStrings("task-1", loaded.id);
    try testing.expectEqualStrings("Build feature", loaded.title);
    try testing.expectEqualStrings("Building feature", loaded.active_form);
    try testing.expectEqualStrings("{\"k\":\"v\"}", loaded.metadata_json);
    try testing.expectEqual(@as(usize, 2), loaded.blocks.len);
    try testing.expectEqualStrings("task-2", loaded.blocks[0]);
    try testing.expectEqualStrings("task-3", loaded.blocks[1]);
    try testing.expectEqual(@as(usize, 2), loaded.blocked_by.len);
    try testing.expectEqualStrings("task-4", loaded.blocked_by[0]);
    try testing.expectEqualStrings("task-5", loaded.blocked_by[1]);
    try testing.expectEqual(@as(i64, 1234), loaded.run_pid);
    try testing.expectEqual(@as(u8, 42), loaded.progress);
}

test "legacy key=value task record still parses with empty arrays" {
    const allocator = testing.allocator;
    const legacy =
        "id=task-legacy\ntitle=Old task\nsummary= summary text\nstatus=running\n" ++
        "output=\nowner=alice\ncommand=echo hi\npriority=high\ndeps=task-x\n" ++
        "run_pid=99\noutput_path=\nexit_path=\nstarted_ts=10\nfinished_ts=0\n" ++
        "progress=55\ncreated_ts=5\nupdated_ts=8\n";

    var rec = try parseTaskRecordBytes(allocator, legacy);
    defer rec.deinit(allocator);

    try testing.expectEqualStrings("task-legacy", rec.id);
    try testing.expectEqualStrings("Old task", rec.title);
    try testing.expectEqualStrings("summary text", rec.summary);
    try testing.expectEqualStrings("running", rec.status);
    try testing.expectEqualStrings("alice", rec.owner);
    try testing.expectEqualStrings("echo hi", rec.command);
    try testing.expectEqualStrings("high", rec.priority);
    try testing.expectEqualStrings("task-x", rec.deps);
    try testing.expectEqual(@as(i64, 99), rec.run_pid);
    try testing.expectEqual(@as(u8, 55), rec.progress);
    // New JSON-only fields default empty for legacy records.
    try testing.expectEqual(@as(usize, 0), rec.blocks.len);
    try testing.expectEqual(@as(usize, 0), rec.blocked_by.len);
    try testing.expectEqualStrings("", rec.active_form);
    try testing.expectEqualStrings("", rec.metadata_json);
}

// Create a task in `cwd` and return its owned id slice (caller frees).
fn createTaskForTest(allocator: std.mem.Allocator, cwd: []const u8, title: []const u8) ![]u8 {
    const result = try taskCreate(allocator, cwd, title, "", "");
    defer allocator.free(result);
    const id = extractFieldValue(result, "id") orelse return error.Unexpected;
    return allocator.dupe(u8, id);
}

// Read back the persisted record for the id contained in a `taskCreate*`
// result string. Caller deinits the returned record.
fn readCreatedRecordForTest(allocator: std.mem.Allocator, cwd: []const u8, create_result: []const u8) !TaskRecord {
    const id = extractFieldValue(create_result, "id") orelse return error.Unexpected;
    const path = try taskPathAlloc(allocator, cwd, id);
    defer allocator.free(path);
    return readTaskRecord(allocator, path);
}

test "taskCreateWithOptions persists an explicit active_form" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const result = try taskCreateWithOptions(allocator, cwd, "Run the tests", "", "", "normal", "", null, "Running tests", "");
    defer allocator.free(result);

    var rec = try readCreatedRecordForTest(allocator, cwd, result);
    defer rec.deinit(allocator);
    try testing.expectEqualStrings("Running tests", rec.active_form);
}

test "taskCreateWithOptions defaults active_form to the title when empty" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const result = try taskCreateWithOptions(allocator, cwd, "Fix auth bug", "", "", "normal", "", null, "", "");
    defer allocator.free(result);

    var rec = try readCreatedRecordForTest(allocator, cwd, result);
    defer rec.deinit(allocator);
    try testing.expectEqualStrings("Fix auth bug", rec.active_form);
}

test "taskCreateWithOptions round-trips object metadata and rejects non-object" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    // A JSON object round-trips into the stored metadata.
    {
        const result = try taskCreateWithOptions(allocator, cwd, "Track PR", "", "", "normal", "", null, "", "{\"pr\":42}");
        defer allocator.free(result);

        var rec = try readCreatedRecordForTest(allocator, cwd, result);
        defer rec.deinit(allocator);
        try testing.expectEqualStrings("{\"pr\":42}", rec.metadata_json);
    }

    // A JSON array is not an object and is rejected.
    try testing.expectError(
        error.InvalidTaskMetadata,
        taskCreateWithOptions(allocator, cwd, "Bad meta", "", "", "normal", "", null, "", "[1,2]"),
    );
}

test "blockTask records the edge from both sides and is idempotent" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const id_a = try createTaskForTest(allocator, cwd, "Task A");
    defer allocator.free(id_a);
    const id_b = try createTaskForTest(allocator, cwd, "Task B");
    defer allocator.free(id_b);

    const first = try blockTask(allocator, cwd, id_a, id_b);
    allocator.free(first);

    {
        const path_a = try taskPathAlloc(allocator, cwd, id_a);
        defer allocator.free(path_a);
        var rec_a = try readTaskRecord(allocator, path_a);
        defer rec_a.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), rec_a.blocks.len);
        try testing.expectEqualStrings(id_b, rec_a.blocks[0]);
        try testing.expectEqual(@as(usize, 0), rec_a.blocked_by.len);

        const path_b = try taskPathAlloc(allocator, cwd, id_b);
        defer allocator.free(path_b);
        var rec_b = try readTaskRecord(allocator, path_b);
        defer rec_b.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), rec_b.blocked_by.len);
        try testing.expectEqualStrings(id_a, rec_b.blocked_by[0]);
        try testing.expectEqual(@as(usize, 0), rec_b.blocks.len);
    }

    // Idempotent: re-calling does not duplicate the edge.
    const second = try blockTask(allocator, cwd, id_a, id_b);
    allocator.free(second);

    {
        const path_a = try taskPathAlloc(allocator, cwd, id_a);
        defer allocator.free(path_a);
        var rec_a = try readTaskRecord(allocator, path_a);
        defer rec_a.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), rec_a.blocks.len);

        const path_b = try taskPathAlloc(allocator, cwd, id_b);
        defer allocator.free(path_b);
        var rec_b = try readTaskRecord(allocator, path_b);
        defer rec_b.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), rec_b.blocked_by.len);
    }
}

test "taskDelete cascades and clears the deleted id from other edges" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const id_a = try createTaskForTest(allocator, cwd, "Task A");
    defer allocator.free(id_a);
    const id_b = try createTaskForTest(allocator, cwd, "Task B");
    defer allocator.free(id_b);

    // A blocks B: B.blocked_by == [A].
    const edge = try blockTask(allocator, cwd, id_a, id_b);
    allocator.free(edge);

    const del = try taskDelete(allocator, cwd, id_a);
    allocator.free(del);

    // A's file is gone.
    {
        const path_a = try taskPathAlloc(allocator, cwd, id_a);
        defer allocator.free(path_a);
        try testing.expectError(error.FileNotFound, readTaskRecord(allocator, path_a));
    }

    // B's blocked_by no longer references the deleted A.
    {
        const path_b = try taskPathAlloc(allocator, cwd, id_b);
        defer allocator.free(path_b);
        var rec_b = try readTaskRecord(allocator, path_b);
        defer rec_b.deinit(allocator);
        try testing.expectEqual(@as(usize, 0), rec_b.blocked_by.len);
    }
}

test "unresolvedBlockers returns open blockers and skips resolved ones" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const id_a = try createTaskForTest(allocator, cwd, "Task A");
    defer allocator.free(id_a);
    const id_b = try createTaskForTest(allocator, cwd, "Task B");
    defer allocator.free(id_b);

    // A blocks B, so B is blocked_by A (A still open).
    const edge = try blockTask(allocator, cwd, id_a, id_b);
    allocator.free(edge);

    {
        const path_b = try taskPathAlloc(allocator, cwd, id_b);
        defer allocator.free(path_b);
        var rec_b = try readTaskRecord(allocator, path_b);
        defer rec_b.deinit(allocator);

        const open = try unresolvedBlockers(allocator, cwd, &rec_b);
        defer freeStringList(allocator, open);
        try testing.expectEqual(@as(usize, 1), open.len);
        try testing.expectEqualStrings(id_a, open[0]);
    }

    // Mark A done; B should now have no unresolved blockers.
    {
        const upd = try taskUpdate(allocator, cwd, id_a, null, null, "done", null, null);
        allocator.free(upd);

        const path_b = try taskPathAlloc(allocator, cwd, id_b);
        defer allocator.free(path_b);
        var rec_b = try readTaskRecord(allocator, path_b);
        defer rec_b.deinit(allocator);

        const open = try unresolvedBlockers(allocator, cwd, &rec_b);
        defer freeStringList(allocator, open);
        try testing.expectEqual(@as(usize, 0), open.len);
    }
}

// Read the persisted owner for a task id (caller frees).
fn readOwnerForTest(allocator: std.mem.Allocator, cwd: []const u8, id: []const u8) ![]u8 {
    const path = try taskPathAlloc(allocator, cwd, id);
    defer allocator.free(path);
    var rec = try readTaskRecord(allocator, path);
    defer rec.deinit(allocator);
    return allocator.dupe(u8, rec.owner);
}

test "claimTask assigns owner and rejects a second claimant" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const id = try createTaskForTest(allocator, cwd, "Claimable task");
    defer allocator.free(id);

    // First claim by agent-a succeeds and persists the owner.
    {
        var res = try claimTask(allocator, cwd, id, "agent-a", false);
        defer res.deinit(allocator);
        try testing.expectEqual(ClaimReason.ok, res.reason);

        const owner = try readOwnerForTest(allocator, cwd, id);
        defer allocator.free(owner);
        try testing.expectEqualStrings("agent-a", owner);
    }

    // Second claim by agent-b is rejected as already_claimed.
    {
        var res = try claimTask(allocator, cwd, id, "agent-b", false);
        defer res.deinit(allocator);
        try testing.expectEqual(ClaimReason.already_claimed, res.reason);
    }

    // Re-claiming as the same agent is allowed (no conflict).
    {
        var res = try claimTask(allocator, cwd, id, "agent-a", false);
        defer res.deinit(allocator);
        try testing.expectEqual(ClaimReason.ok, res.reason);
    }
}

test "claimTask rejects a task blocked by an open blocker" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const id_a = try createTaskForTest(allocator, cwd, "Task A");
    defer allocator.free(id_a);
    const id_b = try createTaskForTest(allocator, cwd, "Task B");
    defer allocator.free(id_b);

    // A blocks B, so B.blocked_by == [A] and A is still open.
    const edge = try blockTask(allocator, cwd, id_a, id_b);
    allocator.free(edge);

    var res = try claimTask(allocator, cwd, id_b, "agent-a", false);
    defer res.deinit(allocator);
    try testing.expectEqual(ClaimReason.blocked, res.reason);
    try testing.expectEqual(@as(usize, 1), res.blocked_by.len);
    try testing.expectEqualStrings(id_a, res.blocked_by[0]);

    // Resolving A unblocks B.
    {
        const upd = try taskUpdate(allocator, cwd, id_a, null, null, "done", null, null);
        allocator.free(upd);

        var res2 = try claimTask(allocator, cwd, id_b, "agent-a", false);
        defer res2.deinit(allocator);
        try testing.expectEqual(ClaimReason.ok, res2.reason);
    }
}

test "claimTask with busy check rejects an agent that already owns an open task" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const id1 = try createTaskForTest(allocator, cwd, "Task 1");
    defer allocator.free(id1);
    const id2 = try createTaskForTest(allocator, cwd, "Task 2");
    defer allocator.free(id2);

    // agent-a claims T1 (now busy).
    {
        var res = try claimTask(allocator, cwd, id1, "agent-a", false);
        defer res.deinit(allocator);
        try testing.expectEqual(ClaimReason.ok, res.reason);
    }

    // With the busy check, claiming T2 is rejected and reports T1.
    {
        var res = try claimTask(allocator, cwd, id2, "agent-a", true);
        defer res.deinit(allocator);
        try testing.expectEqual(ClaimReason.agent_busy, res.reason);
        try testing.expectEqual(@as(usize, 1), res.busy_with.len);
        try testing.expectEqualStrings(id1, res.busy_with[0]);
    }

    // Without the busy check the second claim still succeeds.
    {
        var res = try claimTask(allocator, cwd, id2, "agent-a", false);
        defer res.deinit(allocator);
        try testing.expectEqual(ClaimReason.ok, res.reason);
    }
}

test "getAgentStatuses buckets unresolved tasks by owner" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const id1 = try createTaskForTest(allocator, cwd, "Task 1");
    defer allocator.free(id1);
    const id2 = try createTaskForTest(allocator, cwd, "Task 2");
    defer allocator.free(id2);

    {
        const r1 = try claimTask(allocator, cwd, id1, "agent-a", false);
        var rr1 = r1;
        rr1.deinit(allocator);
        const r2 = try claimTask(allocator, cwd, id2, "agent-a", false);
        var rr2 = r2;
        rr2.deinit(allocator);
    }

    const statuses = try getAgentStatuses(allocator, cwd);
    defer freeAgentStatuses(allocator, statuses);

    try testing.expectEqual(@as(usize, 1), statuses.len);
    try testing.expectEqualStrings("agent-a", statuses[0].name);
    try testing.expect(statuses[0].busy);
    try testing.expectEqual(@as(usize, 2), statuses[0].current_tasks.len);
}

test "unassignTeammateTasks clears owner and resets status" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const id = try createTaskForTest(allocator, cwd, "Owned task");
    defer allocator.free(id);

    {
        var res = try claimTask(allocator, cwd, id, "agent-a", false);
        defer res.deinit(allocator);
        try testing.expectEqual(ClaimReason.ok, res.reason);
    }

    const note = try unassignTeammateTasks(allocator, cwd, "agent-a", "agent-a", "shutdown");
    defer allocator.free(note);
    // Notification mentions the teammate and the unassigned task.
    try testing.expect(std.mem.indexOf(u8, note, "agent-a") != null);
    try testing.expect(std.mem.indexOf(u8, note, id) != null);

    // Owner is cleared and status reset to open.
    const path = try taskPathAlloc(allocator, cwd, id);
    defer allocator.free(path);
    var rec = try readTaskRecord(allocator, path);
    defer rec.deinit(allocator);
    try testing.expectEqualStrings("", rec.owner);
    try testing.expectEqualStrings("open", rec.status);
}

// ── Task 14 (swarm-tasks-15): TaskCreated blocking-hook gate + exit-137
// suppression ─────────────────────────────────────────────────────────────
//
// These tests point HOME at the tmp dir so the user/policy hook sources resolve
// into a hermetic tree, and write the TaskCreated hook as a *project*-scope
// settings.json (trusted via security.allowHook). The cwd lives in a distinct
// `proj` subdir so the project source is found there.

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const TaskHomeOverride = struct {
    prev_home: ?[]u8,
    prev_xdg: ?[]u8,
    allocator: std.mem.Allocator,

    fn install(allocator: std.mem.Allocator, home: []const u8) !TaskHomeOverride {
        const env = @import("../core/env.zig");
        const prev_home = if (env.getOwned(allocator, "HOME")) |v| v else |_| null;
        const prev_xdg = if (env.getOwned(allocator, "XDG_CONFIG_HOME")) |v| v else |_| null;

        const home_z = try allocator.dupeZ(u8, home);
        defer allocator.free(home_z);
        _ = setenv("HOME", home_z, 1);
        _ = unsetenv("XDG_CONFIG_HOME");

        const paths = @import("../core/paths.zig");
        const zcode_home = try std.fs.path.join(allocator, &.{ home, ".zcode" });
        defer allocator.free(zcode_home);
        try paths.ensureDir(zcode_home);

        return .{ .prev_home = prev_home, .prev_xdg = prev_xdg, .allocator = allocator };
    }

    fn deinit(self: *TaskHomeOverride) void {
        if (self.prev_home) |h| {
            const z = self.allocator.dupeZ(u8, h) catch return;
            defer self.allocator.free(z);
            _ = setenv("HOME", z, 1);
            self.allocator.free(h);
        } else {
            _ = unsetenv("HOME");
        }
        if (self.prev_xdg) |x| {
            const z = self.allocator.dupeZ(u8, x) catch return;
            defer self.allocator.free(z);
            _ = setenv("XDG_CONFIG_HOME", z, 1);
            self.allocator.free(x);
        } else {
            _ = unsetenv("XDG_CONFIG_HOME");
        }
    }
};

// Write a project settings.json with a single TaskCreated command hook and trust
// it (project/local hooks are untrusted until the settings.json is allowed). The
// command is `sh -c <body>` so `exit N` controls the disposition.
fn writeTrustedTaskCreatedHook(allocator: std.mem.Allocator, tmp: *testing.TmpDir, cwd: []const u8, body: []const u8) !void {
    const security = @import("../core/security.zig");
    const settings = try std.fmt.allocPrint(
        allocator,
        "{{\"hooks\":{{\"TaskCreated\":[{{\"matcher\":\"*\",\"hooks\":[{{\"type\":\"command\",\"command\":\"{s}\"}}]}}]}}}}",
        .{body},
    );
    defer allocator.free(settings);
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "proj/.claude/settings.json", .data = settings });

    const settings_path = try std.fs.path.join(allocator, &.{ cwd, ".claude", "settings.json" });
    defer allocator.free(settings_path);
    const msg = try security.allowHook(allocator, cwd, settings_path);
    allocator.free(msg);
}

test "Task 14: TaskCreated hook exiting 2 blocks creation and deletes the task" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(root);

    var home_ov = try TaskHomeOverride.install(allocator, root);
    defer home_ov.deinit();

    try tmp.dir.createDirPath(rt.io, "proj/.claude");
    const cwd = try test_helpers.tmpDirPath(allocator, &tmp, "proj");
    defer allocator.free(cwd);

    // exit 2 is the blocking disposition for blocking-capable events.
    try writeTrustedTaskCreatedHook(allocator, &tmp, cwd, "echo task vetoed; exit 2");

    const result = try taskCreateWithOptions(allocator, cwd, "Risky task", "", "", "normal", "", null, "", "");
    defer allocator.free(result);

    // Creation reports the block, not a normal "task created".
    try testing.expect(std.mem.indexOf(u8, result, "blocked by TaskCreated hook") != null);

    // The just-created task id is gone from disk (the cascade-aware delete ran).
    const id = extractFieldValue(result, "id");
    try testing.expect(id == null);

    // No `.task` file survived: the list dir is empty (or absent).
    const tasks_rel = try tasksRelAlloc(allocator);
    defer allocator.free(tasks_rel);
    const tasks_dir = try helpers.workspacePathAlloc(allocator, cwd, tasks_rel);
    defer allocator.free(tasks_dir);
    var count: usize = 0;
    if (std.Io.Dir.cwd().openDir(rt.io, tasks_dir, .{ .iterate = true })) |*opened| {
        var dir = opened.*;
        defer dir.close(rt.io);
        var it = dir.iterate();
        while (try it.next(rt.io)) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".task")) count += 1;
        }
    } else |_| {}
    try testing.expectEqual(@as(usize, 0), count);
}

test "Task 14: TaskCreated hook exiting 0 lets the task persist" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(root);

    var home_ov = try TaskHomeOverride.install(allocator, root);
    defer home_ov.deinit();

    try tmp.dir.createDirPath(rt.io, "proj/.claude");
    const cwd = try test_helpers.tmpDirPath(allocator, &tmp, "proj");
    defer allocator.free(cwd);

    try writeTrustedTaskCreatedHook(allocator, &tmp, cwd, "echo ok; exit 0");

    const result = try taskCreateWithOptions(allocator, cwd, "Allowed task", "", "", "normal", "", null, "", "");
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "task created") != null);

    // The record persisted and reads back with its title.
    var rec = try readCreatedRecordForTest(allocator, cwd, result);
    defer rec.deinit(allocator);
    try testing.expectEqualStrings("Allowed task", rec.title);
}

test "Task 14: a 137 (SIGKILL) shell exit is marked stopped with no failure notification" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    // Create a task, then drive it into a "running" state with an exit file
    // holding 137 (128 + SIGKILL), as a killed shell task leaves behind.
    const id = try createTaskForTest(allocator, cwd, "Killed task");
    defer allocator.free(id);

    // taskRun stores the exit file as an absolute path (ensureWorkspaceDirPath
    // returns absolute), so mirror that here.
    const run_dir = try helpers.ensureWorkspaceDirPath(allocator, cwd, TASK_RUNS_SUBPATH);
    defer allocator.free(run_dir);
    const exit_abs = try std.fmt.allocPrint(allocator, "{s}/{s}.exit", .{ run_dir, id });
    defer allocator.free(exit_abs);
    try std.Io.Dir.cwd().writeFile(rt.io, .{ .sub_path = exit_abs, .data = "137\n" });

    const path = try taskPathAlloc(allocator, cwd, id);
    defer allocator.free(path);
    {
        var rec = try readTaskRecord(allocator, path);
        defer rec.deinit(allocator);
        try helpers.replaceOwned(allocator, &rec.status, "running");
        try helpers.replaceOwned(allocator, &rec.exit_path, exit_abs);
        rec.run_pid = 0;
        try writeTaskRecord(allocator, path, &rec);
    }

    // Poll drives refreshTaskRuntimeState, which sees the 137 exit.
    const polled = try taskPoll(allocator, cwd, id);
    defer allocator.free(polled);

    var rec = try readTaskRecord(allocator, path);
    defer rec.deinit(allocator);
    // Terminal state is `stopped`, not `failed`.
    try testing.expectEqualStrings("stopped", rec.status);

    // The notification log carries no "failed" line for this task.
    const note_abs = try helpers.workspacePathAlloc(allocator, cwd, TASK_NOTIFICATIONS_SUBPATH);
    defer allocator.free(note_abs);
    const log = std.Io.Dir.cwd().readFileAlloc(rt.io, note_abs, allocator, .limited(64 * 1024)) catch try allocator.dupe(u8, "");
    defer allocator.free(log);
    try testing.expect(std.mem.indexOf(u8, log, "event=failed") == null);
}
